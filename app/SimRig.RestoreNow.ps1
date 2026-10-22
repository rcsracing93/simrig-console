<#
    SimRig.RestoreNow.ps1 - SimRig Console v4.2, the standalone restore (blocker 2, push A)

    What it does: puts Windows back with no console, no WPF and no finished install. RESTORE-NOW.cmd
    starts it with no elevation. It checks the files of a copy of the app against SHA256SUMS, reads the
    session marker and the tuning marker under C:\SimRacer\Logs\v4, and starts the elevated child
    SimRig.Actions.ps1 one time (one Windows prompt) for Restore and UndoTuning. It prints one line for
    each step of each result file, and it checks that each marker is gone after a green run.
    A session marker that cannot be read counts as no marker: S14, and no Restore with no typed word
    (APPROVALS-RICK-2026-10-09-0450). With no marker it prints that there is nothing to restore. In both
    cases a person who knows that Windows is still
    quiet can type DEFAULTS: the count comes from a dry run of the same Restore (amendment 10, design
    question D3), and then the child Restore runs with no marker (the quiet-list defaults of this PC,
    the same branch as Restore (b) of blocker 7).

    How to run: double-click RESTORE-NOW.cmd, in the folder of the zip or in C:\Program Files\SimRig.
    By hand: pwsh -NoProfile -ExecutionPolicy Bypass -File SimRig.RestoreNow.ps1

    What it changes: this script changes nothing in Windows. Only the child changes Windows, and only
    the child is elevated (design question D2). This script writes one file, restore-now.log in the log
    folder, with no elevation. The texts it prints are the texts S1 to S13, W1 to W4 and E1 with Rick's
    "Yes" (APPROVALS-RICK-2026-10-08-1325), S14 (APPROVALS-RICK-2026-10-09-0450), the texts of
    TEXTS-blocker2-open-2026-10-09.md (APPROVALS-RICK-2026-10-09-1745: W3 and S14 changed, S4b, W2b, W5 and E2
    new), and the lines of the result files of the child as they are.

    The SHA256SUMS check is a check for a damaged or half-extracted copy. It is not a defence against a
    program that can write the folder, because that program can write SHA256SUMS also (the Cowork answer
    of 2026-10-03, point 2).
#>
[CmdletBinding()]
param(
    # The data root of the child, the console and Setup (C:\SimRacer). Tests give a temporary folder.
    [string] $Root = 'C:\SimRacer',
    # The program folder of Setup. Empty: %ProgramFiles%\SimRig.
    [string] $InstallDir = '',
    # Tests only: define the functions, run nothing.
    [switch] $DefineOnly
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# The exit codes of Get-ActionExitCode (the engine is loaded after the copy check, so the table is here
# also; a test compares the two).
$script:RestoreNowCode = @{ Done = 0; StepFailed = 1; BadArgument = 2; Refused = 3; Fatal = 4 }
# The folder name of Get-SimRigInstallFolderName, for the same reason (a test compares the two).
$script:RestoreNowInstallFolderName = 'SimRig'
# Tests set this to SilentlyContinue, so that the lines do not fill the test output.
$script:RestoreNowInformationAction = 'Continue'
$script:RestoreNowLines = [System.Collections.Generic.List[string]]::new()
$script:RestoreNowLog = [System.Collections.Generic.List[string]]::new()

function Get-RestoreNowText {
    <#
        The texts that this script prints, with Rick's "Yes" (APPROVALS-RICK-2026-10-08-1325, the sheet
        QUESTIONS-blocker2-texts-2026-10-08.md). S5 is printed by RESTORE-NOW.cmd; its generator reads it
        here. S10 is the verdict line of the result file as it is. No other text is printed by this
        script, apart from the lines of the result files.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        S1  = 'SimRig RESTORE-NOW {0}, run from {1}.'
        S2  = 'The installed copy in {0} is complete. RESTORE-NOW uses it.'
        S3  = 'RESTORE-NOW uses this copy in {0}, because the installed copy is missing or not complete.'
        S4  = 'Stopped: {0} does not match SHA256SUMS. This copy is damaged or not completely extracted. Nothing was changed. Extract the zip again, and run RESTORE-NOW.cmd again.'
        S5  = 'PowerShell 7 (pwsh.exe) was not found, and RESTORE-NOW needs it. Install PowerShell 7 from https://aka.ms/powershell. To undo the tuning with no PowerShell 7, use the commands in C:\SimRacer\Logs\v4\UNDO-BY-HAND.txt.'
        S6  = 'An open session was found ({0}, quiet at {1}). RESTORE-NOW now puts back the values of its snapshot. Windows asks for administrator rights one time.'
        S7  = 'Applied tuning was found. RESTORE-NOW now puts back the values from before the tuning.'
        S8  = 'The Windows prompt was declined. Nothing was changed.'
        S9  = '{0}  {1}  {2}'
        S10 = '{0}'
        S11 = 'The elevated step wrote no valid result ({0}). Nothing more is known. See C:\SimRacer\Logs\v4\actions.log.'
        S12 = 'NOT FINISHED: the restore says green, but the marker {0} is still there. Run RESTORE-NOW.cmd again, or open SimRig Console.'
        S13 = 'Done. Windows is back to the values from before the session.'
        S14 = 'SimRig cannot read the record of the last session, so RESTORE-NOW does not put back the values of that session. If RESTORE-NOW then asks for DEFAULTS, you can type DEFAULTS to put back the Windows default values instead.'
        W1 = 'No open session and no applied tuning were found. Nothing to restore.'
        W2  = 'If you know that Windows is still quiet (for example, the app stopped and its record was lost), type DEFAULTS and press Enter. RESTORE-NOW then sets {0} items of this PC''s list to their Windows defaults. These are the Windows defaults, not the values that this PC had before Quiet. Press Enter with no word to close with no change.'
        W3  = 'RESTORE-NOW now sets {0} items to their Windows defaults. The result below can give a higher count, because it also counts the items that need no change. Windows asks for administrator rights one time.'
        W4  = 'No change was made.'
        E1  = 'The log of this run is in C:\SimRacer\Logs\v4\restore-now.log.'
        # TEXTS-blocker2-open-2026-10-09.md rows 6, 26, 5 and 19 (APPROVALS-RICK-2026-10-09-1745). The key names
        # are names in the code only.
        S4b = 'Stopped: SHA256SUMS is missing in {0}, or it lists no file. This copy is damaged or not completely extracted. Nothing was changed. Extract the zip again, and run RESTORE-NOW.cmd again.'
        W2b = 'If you know that Windows is still quiet (for example, the app stopped and its record was lost), type DEFAULTS and press Enter. RESTORE-NOW then sets {0} items of this PC''s list to their Windows defaults. These are the Windows defaults, not the values that this PC had before Quiet. Press Enter with no word to undo only the tuning.'
        W5  = 'RESTORE-NOW could not count the items, because its dry run gave no valid result. No change was made. The reason is in C:\SimRacer\Logs\v4\restore-now.log.'
        E2  = 'The log of this run could not be written to C:\SimRacer\Logs\v4\restore-now.log.'
    }
}

function Write-RestoreNowLine {
    <# One line for the person: to the screen and to the log of this run. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $script:RestoreNowLines.Add($Text)
    $script:RestoreNowLog.Add(('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text))
    Write-Information -MessageData $Text -InformationAction $script:RestoreNowInformationAction
}

function Add-RestoreNowLogLine {
    <# One line for the log only: what ran, and why a run stopped. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $script:RestoreNowLog.Add(('{0} [log] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text))
}

function Get-RestoreNowLogPath {
    <# restore-now.log in the log folder of Get-SimRigPath (a test compares the two). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Root)
    return ('{0}\Logs\v4\restore-now.log' -f $Root.TrimEnd('\'))
}

function Save-RestoreNowLog {
    <#
        Appends the lines of this run to restore-now.log, with no elevation. A log that cannot be written stops
        nothing. Returns $true when the lines were written, $false when not (E1 or E2, TEXTS row 19).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Root)
    $path = Get-RestoreNowLogPath -Root $Root
    try {
        $folder = Split-Path -Path $path -Parent
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
        Add-Content -LiteralPath $path -Value @($script:RestoreNowLog) -Encoding UTF8
        return $true
    }
    catch {
        Write-Verbose ('restore-now.log not written: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Get-RestoreNowVersion {
    <# The version line of VERSIONS.md beside this script; 'unknown' when there is none, as the About screen says. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Dir)
    $path = Join-Path -Path $Dir -ChildPath 'VERSIONS.md'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $path)) {
            if ([string]$line -match '^\s*Version:\s*(\S+)') { return $Matches[1] }
        }
    }
    return 'unknown'
}

function Get-RestoreNowLoadedName {
    <#
        The files that the child SimRig.Actions.ps1 loads or reads by name from its own folder, and the
        folders that it loads or reads whole. A test compares this list with the names in SimRig.Actions.ps1,
        so a new file of the child that is not here fails a test.
        Required (REVIEW-night-blocker2-fe1cff2.md finding 6, REVIEW-night-open-limits-499cd69.md finding 4): the files
        that the copy must have, whether or not they are there: the child, and each file that this script loads
        itself (Invoke-RestoreNow): SimRig.Engine.ps1, SimRig.Probe.ps1, SimRig.ChildLog.ps1 and each file of the
        engine folder (named one by one, because a folder cannot be required by its name: a copy with no engine
        folder, or with a file of it gone with its SHA256SUMS line, is refused, not loaded). A copy from before a
        file is refused, not loaded. A new file that this script loads from the copy goes here; a test compares
        this list with the load lines of Invoke-RestoreNow and with the engine folder.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    return [pscustomobject]@{
        File     = @('SimRig.Actions.ps1', 'SimRig.Actions.Defender.ps1', 'SimRig.Engine.ps1', 'SimRig.Probe.ps1',
            'quiet-list.psd1', 'known-good.psd1', 'my-apps.psd1')
        Folder   = @('engine', 'discover', 'rules', 'profiles')
        Required = @('SimRig.Actions.ps1', 'SimRig.Engine.ps1', 'SimRig.Probe.ps1', 'SimRig.ChildLog.ps1',
            'engine/Engine.Anon.ps1', 'engine/Engine.Export.ps1', 'engine/Engine.GpuSteering.ps1', 'engine/Engine.HardFault.ps1',
            'engine/Engine.Install.ps1', 'engine/Engine.Layout.ps1', 'engine/Engine.MachineProfile.ps1', 'engine/Engine.MyApps.ps1',
            'engine/Engine.Peripheral.ps1', 'engine/Engine.Publish.ps1', 'engine/Engine.Score.ps1', 'engine/Engine.SessionEnd.ps1',
            'engine/Engine.Settings.ps1', 'engine/Engine.Software.ps1', 'engine/Engine.Topology.ps1', 'engine/Engine.Update.ps1')
    }
}

function Get-RestoreNowCopyCheck {
    <#
        Is this copy of the app complete? Each line of SHA256SUMS names a file that is there and has that
        hash; each required file (Get-RestoreNowLoadedName, Required) is on the list, a file that is not there
        too; and each file that the child loads by name or by a folder
        loop (the top-level files below, and each file in engine, discover, rules and profiles) is on the
        list. The last rule finds a file that an older zip left in a folder of the child, which the child
        would load. Self-contained: it runs before any file of the copy is loaded.
        Bad is the first file that fails, or the folder when SHA256SUMS is not there or lists no file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [string] $Dir)
    $fail = { param($what) [pscustomobject]@{ Complete = $false; Bad = $what } }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return (& $fail $Dir) }
    $manifest = Join-Path -Path $Dir -ChildPath 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return (& $fail $Dir) }
    $listed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in @(Get-Content -LiteralPath $manifest)) {
        $found = [regex]::Match([string]$line, '^([0-9A-Fa-f]{64})[ \t]+\*?(.+?)\s*$')
        if (-not $found.Success) { continue }
        $relative = $found.Groups[2].Value.Replace('\', '/')
        if ($relative -ieq 'SHA256SUMS') { continue }
        [void]$listed.Add($relative)
        $full = Join-Path -Path $Dir -ChildPath $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return (& $fail $relative) }
        $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        if (-not [string]::Equals($hash, $found.Groups[1].Value, [System.StringComparison]::OrdinalIgnoreCase)) { return (& $fail $relative) }
    }
    if ($listed.Count -eq 0) { return (& $fail $Dir) }
    $loaded = [System.Collections.Generic.List[string]]::new()
    $childLoads = Get-RestoreNowLoadedName
    foreach ($name in @(@($childLoads.File) + @($childLoads.Required) | Select-Object -Unique)) {
        if (@($childLoads.Required) -contains $name -or (Test-Path -LiteralPath (Join-Path -Path $Dir -ChildPath $name) -PathType Leaf)) { $loaded.Add($name) }
    }
    foreach ($folder in @($childLoads.Folder)) {
        $path = Join-Path -Path $Dir -ChildPath $folder
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $path -File | Sort-Object -Property Name)) { $loaded.Add(('{0}/{1}' -f $folder, $file.Name)) }
    }
    foreach ($name in $loaded) {
        if (-not $listed.Contains($name)) { return (& $fail $name) }
    }
    return [pscustomobject]@{ Complete = $true; Bad = $null }
}

function Get-RestoreNowCurrentSid {
    <# The SID of the person who started this script, read with no elevation (G-12). #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-SimRigUserSid)
}

function Get-RestoreNowSid {
    <#
        The SID for the child. A marker /2 has the SID of the Quiet (the Cowork answer of 2026-10-03,
        point 6): its SID, or none when the Quiet had none (the deadman and the self-test). A marker /1, a
        marker that cannot be read, a /2 SID that is not a user SID, or no marker: the SID of the person
        who started this script.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [object] $Marker, [AllowNull()] [string] $CurrentSid)
    $current = if (Test-SimRigUserSid -Sid $CurrentSid) { $CurrentSid } else { $null }
    if ($null -eq $Marker) { return $current }
    if ([string](Get-KnownGoodField -Entry $Marker -Name 'Schema') -ne 'simrig.active-session/2') { return $current }
    $sid = [string](Get-KnownGoodField -Entry $Marker -Name 'UserSid')
    if ([string]::IsNullOrEmpty($sid)) { return $null }
    if (Test-SimRigUserSid -Sid $sid) { return $sid }
    return $current
}

function New-RestoreNowCall {
    <# One run of the child: the operation, its request id, the file, the root, the SID, and dry run or not. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateSet('Restore', 'UndoTuning')] [string] $Operation,
        [Parameter(Mandatory)] [string] $ActionsScript,
        [Parameter(Mandatory)] [string] $Root,
        [AllowNull()] [string] $UserSid,
        [switch] $WhatIfRun
    )
    return [pscustomobject]@{
        Operation     = $Operation
        RequestId     = [guid]::NewGuid().ToString()
        ActionsScript = $ActionsScript
        Root          = $Root
        UserSid       = $(if ([string]::IsNullOrEmpty($UserSid)) { $null } else { $UserSid })
        WhatIf        = [bool]$WhatIfRun
    }
}

function ConvertTo-RestoreNowQuoted {
    <# A PowerShell single-quoted text. Each of the four single quote characters of PowerShell is doubled. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    return ("'" + [regex]::Replace($Text, "(['\u2018\u2019\u201A\u201B])", '$1$1') + "'")
}

function Get-RestoreNowChildCommand {
    <#
        The PowerShell text that the started process runs: each call of the child in order, then the
        highest exit code. One process for each run, so the person sees one Windows prompt when both
        markers are there. Each value is checked or quoted: the operation is one of two words, the request
        id has the form of the child, the SID has the form of a user SID.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [object[]] $Call)
    $text = [System.Collections.Generic.List[string]]::new()
    $text.Add('$simrigCode = 0')
    foreach ($c in $Call) {
        if (@('Restore', 'UndoTuning') -notcontains [string]$c.Operation) { throw ('Not an operation of RESTORE-NOW: {0}' -f $c.Operation) }
        if ([string]$c.RequestId -notmatch '^[0-9a-fA-F-]{8,64}$') { throw ('Not a request id: {0}' -f $c.RequestId) }
        $line = '& {0} -Operation {1} -RequestId {2} -Root {3}' -f (ConvertTo-RestoreNowQuoted -Text ([string]$c.ActionsScript)), $c.Operation, $c.RequestId, (ConvertTo-RestoreNowQuoted -Text ([string]$c.Root))
        if ($c.UserSid) {
            if (-not (Test-SimRigUserSid -Sid ([string]$c.UserSid))) { throw ('Not a user SID: {0}' -f $c.UserSid) }
            $line += (' -UserSid {0}' -f $c.UserSid)
        }
        if ($c.WhatIf) { $line += ' -WhatIf' }
        $text.Add($line)
        $text.Add('if ($LASTEXITCODE -gt $simrigCode) { $simrigCode = $LASTEXITCODE }')
    }
    $text.Add('exit $simrigCode')
    return ($text -join "`n")
}

function Test-RestoreNowDeclined {
    <# True when Start-Process failed because the person declined the Windows prompt (Win32 error 1223). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [System.Exception] $Exception)
    $e = $Exception
    while ($null -ne $e) {
        if ($e -is [System.ComponentModel.Win32Exception] -and $e.NativeErrorCode -eq 1223) { return $true }
        $e = $e.InnerException
    }
    return $false
}

function Start-RestoreNowChild {
    <#
        Starts one pwsh with -NoProfile that runs the calls, and waits. Elevated: one Windows prompt
        (-Verb RunAs); the dry run is not elevated. Returns the exit code, or $null when the person
        declined the prompt. The text is given encoded, so that no character of a path can change it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Call, [switch] $Elevated)
    $command = Get-RestoreNowChildCommand -Call $Call
    Add-RestoreNowLogLine -Text ('start (elevated={0}): {1}' -f [bool]$Elevated, ($command -replace "`n", '; '))
    $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
    $splat = @{
        FilePath     = (Get-Process -Id $PID).Path
        ArgumentList = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {0}' -f $encoded)
        Wait         = $true
        PassThru     = $true
        WindowStyle  = 'Hidden'
    }
    if ($Elevated) { $splat['Verb'] = 'RunAs' }
    try {
        $process = Start-Process @splat
    }
    catch {
        if ($Elevated -and (Test-RestoreNowDeclined -Exception $_.Exception)) { return $null }
        throw
    }
    return $process.ExitCode
}

function Read-RestoreNowWord {
    <# The word that the person types after W2. Input that cannot be read is no word. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try { return ([string](Read-Host)).Trim() }
    catch { return '' }
}

function Read-RestoreNowResult {
    <#
        The result file of one call, and the reasons why it is not valid (Test-ActionResult). First it appends the log
        file of the run of the child to actions.log, as the window does (D1 of blocker 2; APPROVALS-RICK-2026-10-11-1950
        item 1): since blocker 7 the child writes its lines to its own log file, and S11 sends the person to
        actions.log. RESTORE-NOW is not elevated, so the append has the rights of the person, as in the window.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [object] $Call)
    $paths = Get-SimRigPath -Root $Call.Root
    $logFault = Add-ConsoleChildLog -ResultDir $paths.Results -Operation $Call.Operation -RequestId $Call.RequestId -ActionsLog ($paths.Logs + '\actions.log')
    if ($logFault) { Add-RestoreNowLogLine -Text $logFault }
    $path = Get-ActionResultPath -ResultDir $paths.Results -Operation $Call.Operation -RequestId $Call.RequestId
    $result = Read-SimRigJson -Path $path
    [string[]]$invalid = Test-ActionResult -Result $result -RequestId $Call.RequestId -Operation $Call.Operation
    if ($null -ne $result -and @($invalid).Count -eq 0 -and [bool]$result.WhatIf -ne [bool]$Call.WhatIf) {
        $invalid = @(('the result is {0}a dry run' -f $(if ($result.WhatIf) { '' } else { 'not ' })))
    }
    return [pscustomobject]@{ Path = $path; Result = $result; Invalid = @($invalid | Where-Object { $_ }) }
}

function Get-RestoreNowDefaultsCount {
    <#
        The count of W2 and W3, from the plan of the dry run: the items that have a step that writes (a
        Skip step writes nothing, and a service can have two steps).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] [object] $Result)
    return @(@($Result.Steps) | Where-Object { $null -ne $_ -and [string]$_.Op -ne 'Skip' } | ForEach-Object { [string]$_.Id } | Sort-Object -Unique).Count
}

function Get-RestoreNowResultLine {
    <# The lines of one result file: one for each step (S9), the error texts of the child as they are, and the verdict line (S10). #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [object] $Result)
    $text = Get-RestoreNowText
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($step in @($Result.Steps)) {
        if ($null -eq $step) { continue }
        $lines.Add(($text.S9 -f [string]$step.Status, [string]$step.Id, [string]$step.Message))
    }
    foreach ($e in @($Result.Errors)) { if ($e) { $lines.Add([string]$e) } }
    $verdict = Get-KnownGoodField -Entry $Result -Name 'Verdict'
    if ($null -ne $verdict) {
        $verdictLine = [string](Get-KnownGoodField -Entry $verdict -Name 'Line')
        if ($verdictLine) { $lines.Add(($text.S10 -f $verdictLine)) }
    }
    return , $lines.ToArray()
}

function Invoke-RestoreNow {
    <#
        The run, in order: S1; the copy (S2, or S3 and the check of this copy, S4 or S4b); the markers (S6, or
        S14 for a session marker that cannot be read; S7); with no marker W1 (not after S14), the dry run (W5
        when it gives no valid result and no call is left), W2 (W2b when the tuning undo runs) and the typed
        word (W3 or W4); the one elevated start (S8);
        the lines of each result (S9, S10, S11); the check of the markers after (S12, S13); the write of the
        log, then E1 (or E2 when the write failed). Returns the exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $ScriptDir,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $InstallDir,
        [Parameter(Mandatory)] [string] $Root
    )
    $text = Get-RestoreNowText
    $code = $script:RestoreNowCode
    $exit = $code.Done
    try {
        Write-RestoreNowLine -Text ($text.S1 -f (Get-RestoreNowVersion -Dir $ScriptDir), $ScriptDir)

        # The installed copy first (the Cowork answer of 2026-10-03, point 2): a standard user cannot write it.
        $installed = if ($InstallDir) { Get-RestoreNowCopyCheck -Dir $InstallDir } else { [pscustomobject]@{ Complete = $false; Bad = '' } }
        if ($installed.Complete) {
            Write-RestoreNowLine -Text ($text.S2 -f $InstallDir)
            $appDir = $InstallDir
        }
        else {
            Write-RestoreNowLine -Text ($text.S3 -f $ScriptDir)
            $own = Get-RestoreNowCopyCheck -Dir $ScriptDir
            if (-not $own.Complete) {
                # Bad is the folder when SHA256SUMS is not there or lists no file: S4b (TEXTS row 6). Else the file: S4.
                if ([string]$own.Bad -eq $ScriptDir) { Write-RestoreNowLine -Text ($text.S4b -f $own.Bad) }
                else { Write-RestoreNowLine -Text ($text.S4 -f $own.Bad) }
                return $code.Refused
            }
            $appDir = $ScriptDir
        }

        # The files of the checked copy. No file of the console and no WPF.
        . (Join-Path -Path $appDir -ChildPath 'SimRig.Engine.ps1')
        . (Join-Path -Path $appDir -ChildPath 'SimRig.Probe.ps1')
        # Add-ConsoleChildLog, for the append of the log of each call (D1; Read-RestoreNowResult).
        . (Join-Path -Path $appDir -ChildPath 'SimRig.ChildLog.ps1')
        foreach ($enginePart in @(Get-ChildItem -LiteralPath (Join-Path -Path $appDir -ChildPath 'engine') -Filter *.ps1 -File | Sort-Object -Property Name)) {
            . $enginePart.FullName
        }

        $paths = Get-SimRigPath -Root $Root
        $actions = Join-Path -Path $appDir -ChildPath 'SimRig.Actions.ps1'
        $currentSid = Get-RestoreNowCurrentSid
        $call = [System.Collections.Generic.List[object]]::new()
        $sid = Get-RestoreNowSid -Marker $null -CurrentSid $currentSid
        # A session marker that cannot be read counts as no marker: no automatic write (amendment 10,
        # APPROVALS-RICK-2026-10-09-0450 item 1). S14 says so, and the way of DEFAULTS follows.
        $sessionUnreadable = $false

        if (Test-Path -LiteralPath $paths.ActiveMarker) {
            $marker = Read-SimRigJson -Path $paths.ActiveMarker
            if ($null -eq $marker) {
                $sessionUnreadable = $true
                Add-RestoreNowLogLine -Text ('the session marker cannot be read: {0}' -f $paths.ActiveMarker)
                Write-RestoreNowLine -Text $text.S14
            }
            else {
                $sid = Get-RestoreNowSid -Marker $marker -CurrentSid $currentSid
                $sessionId = if (Get-KnownGoodField -Entry $marker -Name 'SessionId') { [string](Get-KnownGoodField -Entry $marker -Name 'SessionId') } else { 'unknown' }
                $quietAt = if (Get-KnownGoodField -Entry $marker -Name 'QuietAt') { [string](Get-KnownGoodField -Entry $marker -Name 'QuietAt') } else { 'unknown' }
                Write-RestoreNowLine -Text ($text.S6 -f $sessionId, $quietAt)
                $call.Add((New-RestoreNowCall -Operation Restore -ActionsScript $actions -Root $Root -UserSid $sid))
            }
        }
        if (Test-Path -LiteralPath $paths.TuningMarker) {
            Write-RestoreNowLine -Text $text.S7
            $call.Add((New-RestoreNowCall -Operation UndoTuning -ActionsScript $actions -Root $Root -UserSid $sid))
        }

        if ($call.Count -eq 0 -or $sessionUnreadable) {
            # W1 is not true when a marker is there and cannot be read.
            if (-not $sessionUnreadable) { Write-RestoreNowLine -Text $text.W1 }
            # Amendment 10: the count is from a dry run of the same Restore, with no elevation.
            $dry = New-RestoreNowCall -Operation Restore -ActionsScript $actions -Root $Root -UserSid $sid -WhatIfRun
            [void](Start-RestoreNowChild -Call @($dry))
            $dryRead = Read-RestoreNowResult -Call $dry
            if (@($dryRead.Invalid).Count -gt 0) {
                Add-RestoreNowLogLine -Text ('the dry run gave no valid result: {0} ({1})' -f (@($dryRead.Invalid) -join '; '), $dryRead.Path)
                if ($call.Count -eq 0) {
                    # W5 in place of W4 (TEXTS row 5): the count could not be made.
                    Write-RestoreNowLine -Text $text.W5
                    return $code.Fatal
                }
                # The tuning undo still runs; the run is not green.
                $exit = $code.Fatal
            }
            else {
                $count = Get-RestoreNowDefaultsCount -Result $dryRead.Result
                # A call here is the tuning undo after a session marker that cannot be read: Enter with no word
                # still runs it, so W2b says so (TEXTS row 26).
                if ($call.Count -gt 0) { Write-RestoreNowLine -Text ($text.W2b -f $count) }
                else { Write-RestoreNowLine -Text ($text.W2 -f $count) }
                $word = Read-RestoreNowWord
                if ($word -ceq 'DEFAULTS') {
                    Write-RestoreNowLine -Text ($text.W3 -f $count)
                    # The Restore first, as with a marker.
                    $call.Insert(0, (New-RestoreNowCall -Operation Restore -ActionsScript $actions -Root $Root -UserSid $sid))
                }
                elseif ($call.Count -eq 0) {
                    Write-RestoreNowLine -Text $text.W4
                    return $code.Done
                }
            }
        }

        $started = Start-RestoreNowChild -Call $call.ToArray() -Elevated
        if ($null -eq $started) {
            Write-RestoreNowLine -Text $text.S8
            return $code.Refused
        }
        Add-RestoreNowLogLine -Text ('the elevated step exited {0}' -f $started)

        $allValid = $true
        $allOk = $true
        $finished = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $call) {
            $read = Read-RestoreNowResult -Call $c
            if (@($read.Invalid).Count -gt 0) {
                $allValid = $false
                Add-RestoreNowLogLine -Text ('no valid result for {0}: {1}' -f $read.Path, (@($read.Invalid) -join '; '))
                Write-RestoreNowLine -Text ($text.S11 -f (@($read.Invalid) -join '; '))
                $exit = [Math]::Max($exit, $code.Fatal)
                continue
            }
            foreach ($line in (Get-RestoreNowResultLine -Result $read.Result)) { Write-RestoreNowLine -Text $line }
            $exit = [Math]::Max($exit, [int]$read.Result.ExitCode)
            if (-not $read.Result.Ok) { $allOk = $false }
            $finished.Add([pscustomobject]@{ Call = $c; Result = $read.Result })
        }

        # The design, 5.6: a green run with a marker still there is not finished.
        $notFinished = $false
        foreach ($f in $finished) {
            if ($f.Call.Operation -eq 'Restore') {
                $verdict = Get-KnownGoodField -Entry $f.Result -Name 'Verdict'
                $green = ($null -ne $verdict -and [bool](Get-KnownGoodField -Entry $verdict -Name 'Green'))
                $markerPath = $paths.ActiveMarker
            }
            else {
                $green = ([int]$f.Result.ExitCode -eq $code.Done)
                $markerPath = $paths.TuningMarker
            }
            if ($green -and (Test-Path -LiteralPath $markerPath)) {
                Write-RestoreNowLine -Text ($text.S12 -f $markerPath)
                $notFinished = $true
            }
        }
        if ($notFinished) {
            $exit = [Math]::Max($exit, $code.StepFailed)
        }
        elseif ($allValid -and $allOk -and $exit -eq $code.Done -and -not (Test-Path -LiteralPath $paths.ActiveMarker) -and -not (Test-Path -LiteralPath $paths.TuningMarker)) {
            Write-RestoreNowLine -Text $text.S13
        }
        return $exit
    }
    finally {
        # TEXTS row 19 (COWORK-LATEST 2026-10-09 18:50, choice 2): E1 goes into the log before the write, so the
        # log has it. After the write the screen gets E1, or E2 when the write failed. E2 is not in the log.
        Add-RestoreNowLogLine -Text $text.E1
        $logWritten = Save-RestoreNowLog -Root $Root
        $lastLine = if ($logWritten) { $text.E1 } else { $text.E2 }
        $script:RestoreNowLines.Add($lastLine)
        Write-Information -MessageData $lastLine -InformationAction $script:RestoreNowInformationAction
    }
}

if ($DefineOnly) { return }

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $programFiles = [System.Environment]::GetFolderPath('ProgramFiles')
    $InstallDir = if ($programFiles) { Join-Path -Path $programFiles -ChildPath $script:RestoreNowInstallFolderName } else { '' }
}
$restoreNowExit = Invoke-RestoreNow -ScriptDir $PSScriptRoot -InstallDir $InstallDir -Root $Root
exit $restoreNowExit
