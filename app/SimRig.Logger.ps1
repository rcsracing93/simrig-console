# SimRig.Logger.ps1 - SimRig Console v4.2, unit U3.10: the 1 Hz counter logger.
#
# READ-ONLY. Same rule as SimRig.Probe.ps1: this file never changes a Windows
# setting. No Set-*, Stop-*, Start-*, Enable-*, Disable-*, New-Item, Remove-*,
# sc.exe, reg.exe add/delete, schtasks /change. If a reading cannot be taken
# without changing something, it is not taken - it is recorded Unavailable
# with a Reason instead.
#
# WHAT IT SAMPLES, AND AT WHAT RATE
#   Once per second (1 Hz):
#     - total CPU utilization (\Processor(_Total)\% Processor Time)
#     - available system memory in MB (Win32_OperatingSystem.FreePhysicalMemory)
#     - the frequency-CCD park state on a dual-CCD machine, from the
#       documented Windows "Processor Information\Parking Status" performance
#       counter (per logical CPU), summarized against the frequency-CCD core
#       list SimRig.Engine's topology detection already produced. This is the
#       one thing a 1 Hz sample is genuinely good for here: whether Windows
#       has the frequency CCD parked is a state that holds for seconds to
#       minutes, not one that flips inside a frame.
#
# THE HONESTY LABEL - READ BEFORE TRUSTING THIS CSV FOR A STUTTER
#   Sampling once a second cannot see anything shorter than a second. A 48 ms
#   frame-time stall is 1/20th of one sample interval and will not show up
#   here at all - the CPU% and memory columns will look completely normal
#   across the second it happened in. Get-SimRigLoggerStallVisibilityNotice
#   below returns the exact sentence used for this, and it is written to:
#     - the console, once, when logging starts (Write-Warning)
#     - the CSV file itself, as a "#"-prefixed line before the header row
#     - this file's own comment-based help (Start-SimRigLogger .NOTES)
#   Use a frame-time capture (e.g. CapFrameX) to see a stall this short; this
#   log is only good for slow or sustained conditions.
#
# "Parking Status" is a documented Windows Processor Information perfmon
# counter, not something confirmed against a fixture in this project - there
# is no dual-CCD capture in the repo fixtures to check it against. See
# NOTES.md ("unconfirmed tokens") and the ask for a real dual-CCD capture.

Set-StrictMode -Version 3.0

function Get-SimRigLoggerStallVisibilityNotice {
    <#
        .SYNOPSIS
        The exact wording that labels this logger as unable to see a stall
        shorter than its sample interval. Read by the console banner, the CSV
        header comment, and this file's own help - one string, one place.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'SimRig.Logger samples once per second (1 Hz). It cannot see anything shorter than one second: a 48 ms frame-time stall is invisible to this CSV and every column will read normal across the second it happened in. For a stall this short, use a frame-time capture (e.g. CapFrameX), not this log.'
}

function Get-SimRigLoggerCsvColumn {
    <#
        .SYNOPSIS
        The fixed, ordered CSV column list this logger writes.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return , @('TimestampUtc', 'CpuPercent', 'AvailableMemoryMB', 'CcdParkState', 'CcdParkReason')
}

function Get-SimRigLoggerCsvNoticeLine {
    <#
        .SYNOPSIS
        The "#"-prefixed line this logger writes as the first line of every
        CSV it produces, carrying the stall-visibility notice into the file
        itself so a reader of the CSV alone still sees it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return '# ' + (Get-SimRigLoggerStallVisibilityNotice)
}

function Get-SimRigParkedCoreSet {
    <#
        .SYNOPSIS
        Turns a set of raw "Parking Status" counter samples into a
        core-number -> IsParked lookup.
        .DESCRIPTION
        Pure transform - takes objects shaped like Get-Counter's
        CounterSamples (InstanceName = the logical CPU index as a string,
        CookedValue = 1 for parked / 0 for unparked, per the documented
        counter), never calls Get-Counter itself. A sample whose CookedValue
        is neither 0 nor 1, or whose InstanceName is not an integer, is
        skipped rather than guessed at.
        .PARAMETER Sample
        Objects with InstanceName and CookedValue properties (or a hashtable
        with those keys) - one per logical CPU.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Sample)
    $result = @{}
    foreach ($s in $Sample) {
        $instance = $null
        $cooked = $null
        if ($s -is [System.Collections.IDictionary]) {
            $instance = $s['InstanceName']
            $cooked = $s['CookedValue']
        } else {
            if ($s.PSObject.Properties.Match('InstanceName').Count -gt 0) { $instance = $s.InstanceName }
            if ($s.PSObject.Properties.Match('CookedValue').Count -gt 0) { $cooked = $s.CookedValue }
        }
        $core = 0
        if ($null -eq $instance -or -not [int]::TryParse([string]$instance, [ref] $core)) { continue }
        if ($null -eq $cooked) { continue }
        $value = [double]$cooked
        if ($value -eq 0) { $result[$core] = $false }
        elseif ($value -eq 1) { $result[$core] = $true }
        # else: not a clean 0/1 reading - left out rather than guessed at.
    }
    return $result
}

function Get-SimRigFrequencyCcdParkSummary {
    <#
        .SYNOPSIS
        Summarizes whether the frequency CCD is parked, from a per-core
        parked-set and the frequency-CCD's own core list.
        .DESCRIPTION
        This is the one thing a 1 Hz sample is good for on a dual-CCD chip:
        the park state does not flip inside a frame. States:
          Unparked  - every frequency-CCD core reads unparked
          Parked    - every frequency-CCD core reads parked
          Mixed     - some parked, some not (reported, not resolved further)
          Unavailable - no frequency CCD (single-CCD machine, or topology
                         detection could not name one), or none of its cores
                         had a usable reading
        Never throws; a machine with no frequency CCD is a normal case, not
        an error.
        .PARAMETER ParkedCore
        Hashtable of core number -> IsParked, from Get-SimRigParkedCoreSet.
        .PARAMETER FrequencyCcdCore
        The logical CPU numbers that belong to the frequency CCD (from the
        engine's CPU topology detection, e.g. Get-CpuTopology's per-CCD core
        list). $null or empty means there is no frequency CCD to report on.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [hashtable] $ParkedCore,
        [AllowNull()] [int[]] $FrequencyCcdCore
    )
    if ($null -eq $FrequencyCcdCore -or @($FrequencyCcdCore).Count -eq 0) {
        return [pscustomobject]@{
            State  = 'Unavailable'
            Reason = 'no frequency CCD on this machine (single-CCD, or topology detection did not name one)'
        }
    }
    $reading = @()
    foreach ($core in $FrequencyCcdCore) {
        if ($ParkedCore.ContainsKey($core)) { $reading += [bool]$ParkedCore[$core] }
    }
    if (@($reading).Count -eq 0) {
        return [pscustomobject]@{
            State  = 'Unavailable'
            Reason = 'Parking Status counter had no usable reading for any frequency-CCD core this sample'
        }
    }
    $parkedCount = @($reading | Where-Object { $_ }).Count
    if ($parkedCount -eq $reading.Count) {
        return [pscustomobject]@{ State = 'Parked'; Reason = $null }
    }
    if ($parkedCount -eq 0) {
        return [pscustomobject]@{ State = 'Unparked'; Reason = $null }
    }
    return [pscustomobject]@{
        State  = 'Mixed'
        Reason = "$parkedCount of $($reading.Count) frequency-CCD cores read parked, the rest unparked"
    }
}

function New-SimRigLoggerRow {
    <#
        .SYNOPSIS
        Builds one CSV row (as an object) from already-taken readings. Pure -
        does not sample anything itself; Start-SimRigLogger below is the only
        caller that touches real counters.
        .PARAMETER CpuPercent
        Total CPU utilization for this sample, or $null when unavailable.
        .PARAMETER AvailableMemoryMB
        Free physical memory in MB for this sample, or $null when unavailable.
        .PARAMETER CcdParkSummary
        The object from Get-SimRigFrequencyCcdParkSummary.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory object only - no system, file or setting is touched.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [datetime] $TimestampUtc,
        [AllowNull()] [Nullable[double]] $CpuPercent,
        [AllowNull()] [Nullable[double]] $AvailableMemoryMB,
        [Parameter(Mandatory)] [pscustomobject] $CcdParkSummary
    )
    return [pscustomobject]@{
        TimestampUtc      = $TimestampUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        CpuPercent        = $CpuPercent
        AvailableMemoryMB = $AvailableMemoryMB
        CcdParkState      = $CcdParkSummary.State
        CcdParkReason     = $CcdParkSummary.Reason
    }
}

function Start-SimRigLogger {
    <#
        .SYNOPSIS
        Runs the 1 Hz counter logger and writes CSV rows to -Path.
        .DESCRIPTION
        Read-only: samples \Processor(_Total)\% Processor Time,
        Win32_OperatingSystem.FreePhysicalMemory, and the per-core "Parking
        Status" counter, and never writes to the registry, a service or a
        scheduled task. Every reading that fails is recorded as $null /
        Unavailable with a reason rather than throwing the whole logger down.
        .NOTES
        CANNOT SEE A SHORT STALL: this samples once a second (1 Hz), so it
        cannot observe anything shorter than that - a 48 ms frame-time stall
        will not appear here. See Get-SimRigLoggerStallVisibilityNotice. This
        notice is also printed to the console once at start and written as
        the first line of the CSV file.
        .PARAMETER Path
        Output CSV file path.
        .PARAMETER FrequencyCcdCore
        The frequency-CCD's logical CPU numbers, from topology detection
        (Get-CpuTopology). Pass $null on a single-CCD machine.
        .PARAMETER SampleCount
        Number of 1 Hz samples to take before returning. Default runs until
        the caller stops it (Ctrl+C / job cancellation).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Read-only sampler that writes only its own -Path output file - it never changes a Windows setting, service or task (see the file header).')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [AllowNull()] [int[]] $FrequencyCcdCore,
        [int] $SampleCount = 0
    )

    Write-Warning (Get-SimRigLoggerStallVisibilityNotice)

    $header = (Get-SimRigLoggerCsvColumn) -join ','
    Set-Content -LiteralPath $Path -Value (Get-SimRigLoggerCsvNoticeLine) -Encoding utf8
    Add-Content -LiteralPath $Path -Value $header -Encoding utf8

    $taken = 0
    while ($SampleCount -le 0 -or $taken -lt $SampleCount) {
        $cpuPercent = $null
        try {
            $sample = Get-Counter -Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop
            $cpuPercent = [double]$sample.CounterSamples[0].CookedValue
        } catch {
            Write-Verbose "CPU% read failed: $($_.Exception.Message)"
        }

        $availableMb = $null
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $availableMb = [double]$os.FreePhysicalMemory / 1024.0
        } catch {
            Write-Verbose "Available-memory read failed: $($_.Exception.Message)"
        }

        $parkSummary = $null
        try {
            $parkRaw = Get-Counter -Counter '\Processor Information(*)\Parking Status' -ErrorAction Stop
            $parkedCore = Get-SimRigParkedCoreSet -Sample @($parkRaw.CounterSamples)
            $parkSummary = Get-SimRigFrequencyCcdParkSummary -ParkedCore $parkedCore -FrequencyCcdCore $FrequencyCcdCore
        } catch {
            $parkSummary = [pscustomobject]@{ State = 'Unavailable'; Reason = "Parking Status counter read failed: $($_.Exception.Message)" }
        }

        $row = New-SimRigLoggerRow -TimestampUtc ([datetime]::UtcNow) -CpuPercent $cpuPercent -AvailableMemoryMB $availableMb -CcdParkSummary $parkSummary
        $line = (Get-SimRigLoggerCsvColumn | ForEach-Object { [string]$row.$_ }) -join ','
        Add-Content -LiteralPath $Path -Value $line -Encoding utf8

        $taken++
        if ($SampleCount -gt 0 -and $taken -ge $SampleCount) { break }
        Start-Sleep -Seconds 1
    }
}

function Add-SimRigSteeringRecord {
    <#
        .SYNOPSIS
        Appends one steering-history line. Never throws: a history that cannot be
        written is not a reason to stop the console opening.

        It lives here, with the logger, and not in the probe: the probe is
        read-only by contract, and the boundaries test in Integration.Tests.ps1
        fails the build the moment it calls New-Item or Add-Content. The history
        is a log the console owns, which is exactly this file's job.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Record
    )

    try {
        if (-not $PSCmdlet.ShouldProcess($Path, 'Append the steering record')) { return $false }
        # No New-Item here. This file has a read-only guard of its own, and making
        # a directory is the kind of thing it exists to keep out. The Logs folder
        # is already there by the time a console start writes a history line - the
        # console log went into it moments earlier - and if it somehow is not, an
        # unwritten history line is not worth a directory nobody asked for.
        $dir = Split-Path -Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { return $false }
        $line = $Record | ConvertTo-Json -Depth 6 -Compress
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
        return $true
    }
    catch {
        Write-Verbose ('Add-SimRigSteeringRecord: {0}' -f $_.Exception.Message)
        return $false
    }
}

function Get-SimRigSteeringRecord {
    <#
        .SYNOPSIS
        Reads the steering history back. An unreadable or absent file is an empty
        history, not an error.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [string] $Path)

    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path)) { return , @($rows.ToArray()) }
    try {
        foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $rows.Add(($line | ConvertFrom-Json)) } catch { continue }
        }
    }
    catch { Write-Verbose ('Get-SimRigSteeringRecord: {0}' -f $_.Exception.Message) }
    return , @($rows.ToArray())
}
