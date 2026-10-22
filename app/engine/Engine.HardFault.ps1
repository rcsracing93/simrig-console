# engine/Engine.HardFault.ps1 - SimRig Console v4.2, unit U3.10 (xperf hard-fault
# report parser).
#
# PURE. No clock, no filesystem, no registry, no processes, no $env:. Every
# input is a string or an array of strings handed in by the caller; this file
# only turns that text into objects. It never reads the report from disk - the
# HardFaultTrace action is the one that runs xperf and reads the file; the
# argument lists it needs are built by the pure functions at the end of this
# file, so what gets run is testable without running it.
#
# Written so it stays valid when concatenated into SimRig.Engine.ps1: function
# definitions only, no top-level code, strict-mode clean (Set-StrictMode
# -Version 3.0 is set once in the final file).
#
# THE FIXTURE PROBLEM, SOLVED (2026-09-27):
#   This parser was written against a GUESS. There was no real xperf hard-fault
#   report anywhere in the project, so the shape modeled here - a title line,
#   then TimeStamp / Process / FileName / ByteOffset columns, one row per fault
#   - was taken from the documented trace action, not from a capture.
#
#   Rick ran one on the rig on 2026-09-27. The guess was wrong in every way
#   that mattered, and the real report is this, in full:
#
#     NumFaults,   TotalBytes,     Process Name ( PID), FileName
#             1,         4096,           System (   4), "\Device\HarddiskVolume3\$Extend\$UsnJrnl:$J"
#
#   What that changed:
#     - There is no TimeStamp column, and no ByteOffset column. xperf's
#       hard-fault report carries no time information at all, so TimeSpanSeconds
#       is always $null here and the old code REQUIRED a column that never
#       exists - it rejected every real report outright.
#     - The rows are pre-aggregated: one row per process-and-file pair, with
#       the fault count in NumFaults. The old code counted ROWS, so a machine
#       with 400 faults across three files would have been reported as 3.
#     - Fields are padded with leading spaces, the process column carries the
#       PID inside it, and the file name is quoted.
#     - The file is CRLF and ends with one, which left a trailing empty line
#       that was passed to a mandatory parameter and threw.
#
#   The sample above is a test in Advanced.Tests.ps1, byte for byte, so this
#   cannot drift back into invention. The LatencyMon summary-line helper at the
#   end of this file is unrelated and was always real.

# Set-StrictMode is applied once by the concatenated SimRig.Engine.ps1 / by
# the test that dot-sources this file directly - this fragment holds function
# definitions only, so it folds cleanly into that file.

function Get-SimRigHardFaultKnownColumn {
    <#
        .SYNOPSIS
        The column-name tokens this parser recognizes in an xperf hard-fault
        report header row, matched case-insensitively.
        .DESCRIPTION
        Confirmed against a real capture taken on the rig, 2026-09-27: the header is
        "NumFaults,   TotalBytes,     Process Name ( PID), FileName". The extra
        spellings are tolerance for other xperf builds, not invention - each one
        is a formatting variant of a column that capture proved exists.
        TimeStamp is listed because a header that happens to carry one should
        map rather than be ignored; no real report has yet had one.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        NumFaults  = @('NumFaults', 'Num Faults', 'Fault Count', 'Count')
        TotalBytes = @('TotalBytes', 'Total Bytes', 'Bytes')
        Process    = @('Process Name ( PID)', 'Process Name (PID)', 'Process Name', 'Process', 'ProcessName')
        FileName   = @('FileName', 'File Name')
        TimeStamp  = @('TimeStamp', 'TimeStamp (s)', 'Time Stamp')
    }
}

function Get-SimRigHardFaultTitleToken {
    <#
        .SYNOPSIS
        Kept for callers that still ask, and for a title line some xperf builds
        may print before the header.
        .DESCRIPTION
        The real 2026-09-27 capture has NO title line - it starts at the header
        row. Nothing in the parser requires this token; the header search skips
        whatever precedes the header.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'Hard Fault Report'
}

function Split-SimRigReportLine {
    <#
        .SYNOPSIS
        Splits report text into lines, accepting either a single block of
        text or an already-split array - never touches a file.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()] [string] $Text,
        [AllowNull()] [string[]] $Line
    )
    if ($null -ne $Line) { return , @($Line) }
    if ([string]::IsNullOrEmpty($Text)) { return , @() }
    return , @($Text -split "`r`n|`r|`n")
}

function ConvertTo-SimRigInvariantDouble {
    <#
        .SYNOPSIS
        Parses a number using InvariantCulture only, never the thread's
        current culture (flag 5: xperf output is localized, and a German
        Windows writes "1.234,5" where an English one writes "1,234.5").
        .DESCRIPTION
        Returns $null on failure instead of throwing - a field that will not
        parse is reported as unparsed, not a crash.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([AllowNull()] [string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $styles = [System.Globalization.NumberStyles]::Float -bor [System.Globalization.NumberStyles]::AllowThousands
    $result = [double]0
    $ok = [double]::TryParse(
        $Value.Trim(),
        $styles,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref] $result)
    if ($ok) { return $result }
    return $null
}

function Split-SimRigCsvField {
    <#
        .SYNOPSIS
        A minimal comma-split that respects double-quoted fields (a file name
        can legitimately contain a comma). Not a general CSV parser - this
        report has no embedded newlines or escaped quotes to worry about.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Line)
    $field = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $inQuotes = $false
    foreach ($ch in $Line.ToCharArray()) {
        if ($ch -eq '"') { $inQuotes = -not $inQuotes; continue }
        if ($ch -eq ',' -and -not $inQuotes) {
            $field.Add($current.ToString())
            [void]$current.Clear()
            continue
        }
        [void]$current.Append($ch)
    }
    $field.Add($current.ToString())
    return , @($field.ToArray() | ForEach-Object { $_.Trim() })
}

function Find-SimRigHardFaultHeaderIndex {
    <#
        .SYNOPSIS
        Finds the header-row index in the first few non-blank lines: a line
        whose fields include at least two of the known column tokens.
        .DESCRIPTION
        Returns -1 when no header is found within the first 10 non-blank
        lines - past that point this is not treated as a hard-fault report at
        all (truncated or nonsense input, per CONTRACT: never throw, never
        report a plausible-looking zero).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Line)
    # AllowEmptyString is not decoration. The real report is CRLF and ends with
    # one, so the split leaves a trailing empty line, and a mandatory [string[]]
    # refuses an array carrying an empty element - the parser threw on every
    # genuine file before anything was even read.
    $known = (Get-SimRigHardFaultKnownColumn).Values | ForEach-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() }
    $checked = 0
    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ([string]::IsNullOrWhiteSpace($Line[$i])) { continue }
        $checked++
        if ($checked -gt 10) { return -1 }
        $field = Split-SimRigCsvField -Line $Line[$i]
        $hit = 0
        foreach ($f in $field) {
            if ($known -contains $f.ToLowerInvariant()) { $hit++ }
        }
        if ($hit -ge 2) { return $i }
    }
    return -1
}

function Get-SimRigHardFaultColumnMap {
    <#
        .SYNOPSIS
        Maps each recognized role (TimeStamp, Process, FileName, ByteOffset)
        to its field index in a header row, or $null when that role's column
        is absent.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string[]] $HeaderField)
    $known = Get-SimRigHardFaultKnownColumn
    $map = @{}
    foreach ($role in $known.Keys) {
        $index = $null
        for ($i = 0; $i -lt $HeaderField.Count; $i++) {
            if ($known[$role] -icontains $HeaderField[$i]) { $index = $i; break }
        }
        $map[$role] = $index
    }
    return $map
}

function ConvertTo-SimRigProcessNamePid {
    <#
        .SYNOPSIS
        Splits a "Name.exe ( 1234)" style process field into Name and PID.
        Returns the whole field as Name and a $null PID when no "(number)"
        is present - this is the common case for xperf's "Process Name" and
        the bare "Process" column alike.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()] [string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [pscustomobject]@{ Name = $null; Pid = $null }
    }
    $trimmed = $Value.Trim()
    $match = [regex]::Match($trimmed, '^(?<name>.*?)\s*\(\s*(?<pid>\d+)\s*\)\s*$')
    if ($match.Success) {
        return [pscustomobject]@{
            Name = $match.Groups['name'].Value.Trim()
            Pid  = [int]$match.Groups['pid'].Value
        }
    }
    return [pscustomobject]@{ Name = $trimmed; Pid = $null }
}

function Get-SimRigHardFaultReport {
    <#
        .SYNOPSIS
        Parses an xperf hard-fault report into a summary object. Pure: takes
        text or lines, returns objects, never throws.
        .DESCRIPTION
        A truncated, empty or nonsense report comes back with IsValid=$false
        and a Reason, and TotalHardFaults is $null (never a plausible-looking
        zero that would read as "no hard faults"). A report that parses but
        has some unparsable rows still comes back IsValid=$true with those
        rows counted in SkippedRowCount and named in Warning.
        .PARAMETER Text
        The whole report as one string (lines split on CRLF/CR/LF).
        .PARAMETER Line
        The report as an already-split array of lines. Takes precedence over
        -Text when both are given.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [string] $Text,
        [AllowNull()] [string[]] $Line
    )

    $allLine = Split-SimRigReportLine -Text $Text -Line $Line

    $emptyResult = {
        param($reason)
        [pscustomobject]@{
            IsValid          = $false
            Reason           = $reason
            SourceFormat     = 'xperf-hardfaults (confirmed against the 2026-09-27 rig capture)'
            TotalHardFaults  = $null
            TotalBytes       = $null
            TimeSpanSeconds  = $null
            SkippedRowCount  = $null
            ByProcess        = @()
            ByFile           = @()
            Warning          = @()
        }
    }

    if ($allLine.Count -eq 0 -or (@($allLine | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })).Count -eq 0) {
        return (& $emptyResult 'empty input: no non-blank lines')
    }

    $headerIndex = Find-SimRigHardFaultHeaderIndex -Line $allLine
    if ($headerIndex -lt 0) {
        return (& $emptyResult 'no recognizable header row in the first 10 non-blank lines (truncated or not a hard-fault report)')
    }

    $headerField = Split-SimRigCsvField -Line $allLine[$headerIndex]
    $columnMap = Get-SimRigHardFaultColumnMap -HeaderField $headerField

    if ($null -eq $columnMap['Process']) {
        return (& $emptyResult 'header row has no process column')
    }
    # NumFaults is what makes this a real xperf report. The old code required a
    # TimeStamp column instead, which no real report has, so it rejected every
    # genuine capture. A report with a process column but no count is still
    # readable - each row then counts as one fault, and the result says so.
    $countIndex = $columnMap['NumFaults']
    $bytesIndex = $columnMap['TotalBytes']
    $fileIndex = $columnMap['FileName']

    $dataLine = @()
    for ($i = $headerIndex + 1; $i -lt $allLine.Count; $i++) {
        if (-not [string]::IsNullOrWhiteSpace($allLine[$i])) { $dataLine += $allLine[$i] }
    }

    if ($dataLine.Count -eq 0) {
        # Not an error worth hiding behind IsValid=$false: xperf writes the
        # header and no rows when a trace genuinely had no hard faults, and
        # "none" is the answer we most expect on a warmed rig. It is reported
        # as a valid report of zero, with the reason stated.
        return [pscustomobject]@{
            IsValid         = $true
            Reason          = 'header row with no data rows: the trace recorded no hard faults'
            SourceFormat    = 'xperf-hardfaults (confirmed against the 2026-09-27 rig capture)'
            TotalHardFaults = 0
            TotalBytes      = 0
            TimeSpanSeconds = $null
            SkippedRowCount = 0
            ByProcess       = @()
            ByFile          = @()
            Warning         = @()
        }
    }

    $processFault = [System.Collections.Generic.Dictionary[string, long]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $processBytes = [System.Collections.Generic.Dictionary[string, long]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $processPid = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $fileFault = [System.Collections.Generic.Dictionary[string, long]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $fileBytes = [System.Collections.Generic.Dictionary[string, long]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $warning = [System.Collections.Generic.List[string]]::new()
    $parsedRowCount = 0
    $skippedRowCount = 0
    [long]$totalFault = 0
    [long]$totalBytes = 0

    if ($null -eq $countIndex) {
        $warning.Add('no NumFaults column in this report: each row is counted as one fault')
    }

    foreach ($row in $dataLine) {
        $field = Split-SimRigCsvField -Line $row
        if ($field.Count -le $columnMap['Process']) {
            $skippedRowCount++
            continue
        }
        $procInfo = ConvertTo-SimRigProcessNamePid -Value $field[$columnMap['Process']]
        if ([string]::IsNullOrWhiteSpace($procInfo.Name)) {
            $skippedRowCount++
            continue
        }

        # Each row is a process-and-file pair with its own count, not one fault.
        [long]$faults = 1
        if ($null -ne $countIndex -and $field.Count -gt $countIndex) {
            $parsed = ConvertTo-SimRigInvariantDouble -Value $field[$countIndex]
            if ($null -eq $parsed) {
                $skippedRowCount++
                continue
            }
            $faults = [long]$parsed
        }

        [long]$bytes = 0
        if ($null -ne $bytesIndex -and $field.Count -gt $bytesIndex) {
            $parsedBytes = ConvertTo-SimRigInvariantDouble -Value $field[$bytesIndex]
            if ($null -ne $parsedBytes) { $bytes = [long]$parsedBytes }
        }

        $parsedRowCount++
        $totalFault += $faults
        $totalBytes += $bytes

        $procKey = $procInfo.Name
        if (-not $processFault.ContainsKey($procKey)) {
            $processFault[$procKey] = 0
            $processBytes[$procKey] = 0
            $processPid[$procKey] = $procInfo.Pid
        }
        $processFault[$procKey] = $processFault[$procKey] + $faults
        $processBytes[$procKey] = $processBytes[$procKey] + $bytes

        if ($null -ne $fileIndex -and $field.Count -gt $fileIndex) {
            $fileKey = $field[$fileIndex]
            if (-not [string]::IsNullOrWhiteSpace($fileKey)) {
                if (-not $fileFault.ContainsKey($fileKey)) {
                    $fileFault[$fileKey] = 0
                    $fileBytes[$fileKey] = 0
                }
                $fileFault[$fileKey] = $fileFault[$fileKey] + $faults
                $fileBytes[$fileKey] = $fileBytes[$fileKey] + $bytes
            }
        }
    }

    if ($parsedRowCount -eq 0) {
        return (& $emptyResult 'no data row could be parsed (nonsense report)')
    }

    if ($skippedRowCount -gt 0) {
        $warning.Add("$skippedRowCount of $($dataLine.Count) data row(s) could not be parsed and were skipped")
    }

    $byProcess = @($processFault.Keys | ForEach-Object {
            [pscustomobject]@{
                Process = $_
                Pid     = $processPid[$_]
                Faults  = $processFault[$_]
                Bytes   = $processBytes[$_]
            }
        } | Sort-Object -Property Faults -Descending)
    $byFile = @($fileFault.Keys | ForEach-Object {
            [pscustomobject]@{
                FileName = $_
                Faults   = $fileFault[$_]
                Bytes    = $fileBytes[$_]
            }
        } | Sort-Object -Property Faults -Descending)

    return [pscustomobject]@{
        IsValid         = $true
        Reason          = $null
        SourceFormat    = 'xperf-hardfaults (confirmed against the 2026-09-27 rig capture)'
        TotalHardFaults = $totalFault
        TotalBytes      = $totalBytes
        # Always $null: the report carries no timestamps. Kept so callers that
        # read the field get an honest "not available" rather than a made-up 0.
        TimeSpanSeconds = $null
        SkippedRowCount = $skippedRowCount
        ByProcess       = $byProcess
        ByFile          = $byFile
        Warning         = @($warning.ToArray())
    }
}

function Test-SimRigHardFaultSummaryLine {
    <#
        .SYNOPSIS
        Parses the one REAL hard-fault line this project has a fixture for:
        LatencyMon's "Total number of hard pagefaults" summary line (not
        xperf - LatencyMon's own report format).
        .DESCRIPTION
        Real fixture: ~/build/fixtures/v4-prep/latencymon-sample.txt, line
        "Total number of hard pagefaults                       13599". This
        is a narrow, separate helper - it does not feed Get-SimRigHardFault
        Report, which is xperf-shaped. Returns $null when the line does not
        match (never throws).
        .PARAMETER Line
        A single line of LatencyMon report text.
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[long]])]
    param([AllowNull()] [string] $Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $match = [regex]::Match($Line, '(?i)Total number of hard pagefaults\s+(?<count>[\d.,]+)\s*$')
    if (-not $match.Success) { return $null }
    $value = ConvertTo-SimRigInvariantDouble -Value ($match.Groups['count'].Value -replace ',', '')
    if ($null -eq $value) { return $null }
    return [long]$value
}


# ---------------------------------------------------------------------------
# Running the trace. Pure: these build paths and argument lists, they never
# start a process. What they encode was learned the hard way on 2026-09-27.
# ---------------------------------------------------------------------------

function Get-SimRigXperfCandidatePath {
    <#
        .SYNOPSIS
        Where xperf.exe lives, in the order worth looking.
        .DESCRIPTION
        It is not on the PATH on the rig - `where xperf` finds nothing - and it
        is not under Program Files (x86) either, which is where the first
        version of the rig sheet looked. The confirmed location on the rig is
        the 64-bit Program Files. UIforETW is listed because it bundles xperf
        and the rig's own ETW notes assume it.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()] [string] $ProgramFiles, [AllowNull()] [string] $ProgramFilesX86, [AllowNull()] [string] $UserProfile)
    $pf = if ([string]::IsNullOrWhiteSpace($ProgramFiles)) { 'C:\Program Files' } else { $ProgramFiles.TrimEnd('\') }
    $pf86 = if ([string]::IsNullOrWhiteSpace($ProgramFilesX86)) { 'C:\Program Files (x86)' } else { $ProgramFilesX86.TrimEnd('\') }
    $home86 = if ([string]::IsNullOrWhiteSpace($UserProfile)) { 'C:\Users\Default' } else { $UserProfile.TrimEnd('\') }
    $list = @(
        ('{0}\Windows Kits\10\Windows Performance Toolkit\xperf.exe' -f $pf),
        ('{0}\Windows Kits\10\Windows Performance Toolkit\xperf.exe' -f $pf86),
        ('{0}\Downloads\UIforETW\bin\xperf.exe' -f $home86),
        ('{0}\Desktop\UIforETW\bin\xperf.exe' -f $home86)
    )
    return , @($list)
}

function Get-SimRigHardFaultKernelFlag {
    <#
        .SYNOPSIS
        The kernel flags and stackwalk the hard-fault trace needs.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        Flags     = 'PROC_THREAD+LOADER+HARD_FAULTS+FILENAME+FILE_IO+FILE_IO_INIT'
        StackWalk = 'HardFault'
    }
}

function Get-SimRigHardFaultCommand {
    <#
        .SYNOPSIS
        The exact argument list for one phase of the trace: Start, Stop or
        Convert. Returns the arguments only - the caller supplies the exe.
        .DESCRIPTION
        Start ALWAYS passes -f. That is the whole lesson of 2026-09-27: the
        trace was started without it, something took the kernel logger back
        about a minute into a fifteen-minute stint, and the stop failed with
        0x1069 because the session no longer existed. The only reason any data
        survived is that xperf falls back to C:\kernel.etl and had been
        streaming there all along. With -f the stream goes where we chose, so
        an interrupted trace still leaves everything up to the interruption.

        Stop does not pass -d. A stop that also dumps has to name a session
        that may be gone; stopping and then converting the file we already have
        cannot fail that way.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [ValidateSet('Start', 'Stop', 'Convert')] [string] $Phase,
        [AllowNull()] [string] $EtlPath,
        [AllowNull()] [string] $CsvPath,
        [int] $BufferSizeKb = 1024,
        [int] $MinBuffers = 64,
        [int] $MaxBuffers = 256
    )
    $kernel = Get-SimRigHardFaultKernelFlag
    switch ($Phase) {
        'Start' {
            $argument = @(
                '-on', $kernel.Flags,
                '-stackwalk', $kernel.StackWalk,
                '-BufferSize', [string]$BufferSizeKb,
                '-MinBuffers', [string]$MinBuffers,
                '-MaxBuffers', [string]$MaxBuffers
            )
            if (-not [string]::IsNullOrWhiteSpace($EtlPath)) { $argument += @('-f', $EtlPath) }
            return , @($argument)
        }
        'Stop' { return , @('-stop') }
        'Convert' {
            return , @('-i', [string]$EtlPath, '-o', [string]$CsvPath, '-a', 'hardfault')
        }
    }
}

function Get-SimRigHardFaultStartVerdict {
    <#
        .SYNOPSIS
        Whether it is safe to start the trace, given what a kernel logger check
        found. Pure: the caller does the checking and hands in what it saw.
        .DESCRIPTION
        Three answers, and each one names what the user should do:
          Ready    - nothing holds the kernel logger, start it.
          Occupied - something holds it. Stopping it is the caller's decision,
                     not a silent act: it dumps whatever that session recorded
                     and may break the tool that owns it.
          Blocked  - no xperf found; there is nothing to run.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [string] $XperfPath,
        [bool] $KernelLoggerRunning,
        [AllowNull()] [string] $OwnerHint
    )
    if ([string]::IsNullOrWhiteSpace($XperfPath)) {
        return [pscustomobject]@{
            Verdict   = 'Blocked'
            StringKey = 'HardFaultNoXperf'
            Detail    = 'xperf.exe was not found. It ships with the Windows Performance Toolkit, and UIforETW carries a copy.'
        }
    }
    if ($KernelLoggerRunning) {
        $who = if ([string]::IsNullOrWhiteSpace($OwnerHint)) { 'another tool' } else { $OwnerHint }
        return [pscustomobject]@{
            Verdict   = 'Occupied'
            StringKey = 'HardFaultLoggerBusy'
            Detail    = ('The kernel logger is already running, held by {0}. Stopping it writes out whatever that session recorded and may stop it collecting.' -f $who)
        }
    }
    return [pscustomobject]@{
        Verdict   = 'Ready'
        StringKey = 'HardFaultReady'
        Detail    = $null
    }
}
