# SimRig.Probe.ps1 - SimRig Console v4.0 read-only system reads
#
# This file READS Windows state and never changes it. It exists because the
# reads needed a home: the Engine is pure (no registry, no services, no files),
# SimRig.Actions.ps1 is the only writer, and the console shell holds no logic.
# The console (unelevated) and the elevated child both dot-source it.
#
# Rule for this file: no Set-*, Stop-*, Start-*, Enable-*, Disable-*, New-Item,
# Remove-*, sc.exe, reg.exe add/delete, schtasks /change. Probe.Tests.ps1 checks.
#
# Every function returns $null (or a record with $null fields) when a reading
# is not available, and never throws for a missing item: a service that is not
# installed or a task that is not registered is Exists=$false.

Set-StrictMode -Version 3.0

function ConvertTo-ProbeStartType {
    <#
        .SYNOPSIS
        Win32_Service StartMode (+ DelayedAutoStart) to the one start-type vocabulary.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [string] $StartMode, [AllowNull()] [object] $DelayedAutoStart)
    switch ($StartMode) {
        'Auto' { if ($DelayedAutoStart -eq $true) { return 'AutomaticDelayed' } return 'Automatic' }
        'Manual' { return 'Manual' }
        'Disabled' { return 'Disabled' }
        'Boot' { return 'Boot' }
        'System' { return 'System' }
        default { return $null }
    }
}

function ConvertTo-ProbeServiceState {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [string] $State)
    switch ($State) {
        'Running' { return 'Running' }
        'Stopped' { return 'Stopped' }
        'Start Pending' { return 'StartPending' }
        'Stop Pending' { return 'StopPending' }
        'Paused' { return 'Paused' }
        default { return 'Unknown' }
    }
}

function Get-ProbeEmptyState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [string] $Id, [Parameter(Mandatory)] [string] $Kind)
    return [pscustomobject]@{
        Id = $Id; Kind = $Kind; Exists = $false
        StartType = $null; State = $null; Enabled = $null; TaskState = $null
        KeyExists = $null; ValueExists = $null; Data = $null
        RealtimeOn = $null; Running = $null
    }
}

function Get-SimRigItemState {
    <#
        .SYNOPSIS
        Reads the real current state of every quiet-list item (ItemState shape,
        CONTRACT.md). Used for the snapshot, the read-back and the verdict.
        Registry, Defender and Process items always have Exists=$true: their
        "missing" cases are KeyExists/ValueExists and Running.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [object[]] $QuietItem)

    # v4.0.4: one Win32_Service query and one Get-ScheduledTask call for the whole
    # list. One query per item took 18-36 s on the rig (2026-09-19). Each batch
    # call has a timeout; if it fails, that kind falls back to one query per item.
    $svcByName = $null
    if (@($QuietItem | Where-Object { $_.Kind -eq 'Service' }).Count -gt 0) {
        try {
            $svcByName = @{}
            foreach ($w in @(Get-CimInstance -ClassName Win32_Service -OperationTimeoutSec 60 -ErrorAction Stop)) { $svcByName[[string]$w.Name] = $w }
        }
        catch { Write-Verbose ("batch service read failed, reading one by one: {0}" -f $_.Exception.Message); $svcByName = $null }
    }
    $taskByUri = $null
    if (@($QuietItem | Where-Object { $_.Kind -eq 'Task' }).Count -gt 0) {
        try {
            $taskByUri = @{}
            foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) { $taskByUri[[string]$t.TaskPath + [string]$t.TaskName] = $t }
        }
        catch { Write-Verbose ("batch task read failed, reading one by one: {0}" -f $_.Exception.Message); $taskByUri = $null }
    }

    $states = foreach ($qi in $QuietItem) {
        $s = Get-ProbeEmptyState -Id $qi.Id -Kind $qi.Kind
        switch ($qi.Kind) {
            'Service' {
                # Win32_Service, not Get-Service: Get-Service's StartType has been
                # unreliable for Disabled on some builds (diagnostics-v1 note).
                $svc = if ($null -ne $svcByName) { $svcByName[[string]$qi.Name] }
                else { Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $qi.Name) -OperationTimeoutSec 30 -ErrorAction SilentlyContinue }
                if ($null -ne $svc) {
                    $s.Exists = $true
                    $s.StartType = ConvertTo-ProbeStartType -StartMode $svc.StartMode -DelayedAutoStart $svc.DelayedAutoStart
                    $s.State = ConvertTo-ProbeServiceState -State $svc.State
                }
            }
            'Task' {
                $task = if ($null -ne $taskByUri) { $taskByUri[[string]$qi.Path + [string]$qi.Name] }
                else { Get-ScheduledTask -TaskPath $qi.Path -TaskName $qi.Name -ErrorAction SilentlyContinue }
                if ($null -ne $task) {
                    $s.Exists = $true
                    $s.Enabled = [bool]$task.Settings.Enabled
                    $s.TaskState = [string]$task.State
                }
            }
            'Registry' {
                $s.Exists = $true
                $s.KeyExists = Test-Path -LiteralPath $qi.Path
                $s.ValueExists = $false
                if ($s.KeyExists) {
                    $key = Get-Item -LiteralPath $qi.Path -ErrorAction SilentlyContinue
                    if ($null -ne $key -and @($key.GetValueNames()) -contains $qi.Value) {
                        $s.ValueExists = $true
                        $s.Data = $key.GetValue($qi.Value)
                    }
                }
            }
            'Defender' {
                $s.Exists = $true
                try {
                    $mp = Get-MpPreference -ErrorAction Stop
                    $s.RealtimeOn = -not [bool]$mp.DisableRealtimeMonitoring
                }
                catch {
                    Write-Verbose ("Defender state not readable: {0}" -f $_.Exception.Message)
                }
            }
            'Process' {
                $s.Exists = $true
                $s.Running = ($null -ne (Get-Process -Name $qi.Name -ErrorAction SilentlyContinue))
            }
        }
        $s
    }
    return , @($states)
}

function Get-SimRigGpuAffinity {
    <#
        .SYNOPSIS
        GPU interrupt steering for every PRESENT NVIDIA PCI function. Ghost
        instances (old slots, removed devices) stay in Enum\PCI but are not
        present, so they are left out - a ghost has no policy and would fail
        preflight for a device that does not exist.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [string] $VendorId)

    $devices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -like ('PCI\{0}*' -f $VendorId) })
    $rows = foreach ($d in $devices) {
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Enum\{0}\Device Parameters\Interrupt Management\Affinity Policy' -f $d.InstanceId
        $policy = $null
        $mask = $null
        if (Test-Path -LiteralPath $base) {
            $key = Get-Item -LiteralPath $base
            if (@($key.GetValueNames()) -contains 'DevicePolicy') { $policy = [int]$key.GetValue('DevicePolicy') }
            if (@($key.GetValueNames()) -contains 'AssignmentSetOverride') {
                $bytes = [byte[]]$key.GetValue('AssignmentSetOverride')
                $buf = [byte[]]::new(8)
                [Array]::Copy($bytes, $buf, [Math]::Min(8, $bytes.Length))
                $mask = [BitConverter]::ToUInt64($buf, 0)
            }
        }
        $devId = if ($d.InstanceId -match '(DEV_[0-9A-Fa-f]{4})') { $Matches[1].ToUpperInvariant() } else { $null }
        # v4.0.6: where the device sits, for diagnosis. The instance ID changed at
        # every boot on 2026-09-19 evening; the location path shows why.
        $location = $null; $parent = $null
        try {
            foreach ($p in @(Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_LocationPaths', 'DEVPKEY_Device_Parent' -ErrorAction Stop)) {
                if ($p.KeyName -eq 'DEVPKEY_Device_LocationPaths') { $location = (@($p.Data) | Select-Object -First 1) }
                if ($p.KeyName -eq 'DEVPKEY_Device_Parent') { $parent = [string]$p.Data }
            }
        }
        catch { Write-Verbose ("device properties not readable: {0}" -f $_.Exception.Message) }
        # Class and FriendlyName come through for flag 7: the public default steers
        # the Display function only, and a decision that cannot see the class cannot
        # make that distinction. Absent on a reading that did not carry them, which
        # the scope selector treats as unknown rather than as Display.
        $class = if ($d.PSObject.Properties.Match('Class').Count -gt 0) { [string]$d.Class } else { $null }
        $friendly = if ($d.PSObject.Properties.Match('FriendlyName').Count -gt 0) { [string]$d.FriendlyName } else { $null }
        [pscustomobject]@{ InstanceId = $d.InstanceId; DeviceId = $devId; DevicePolicy = $policy; AssignmentSetOverride = $mask
            LocationPath = $location; Parent = $parent; Class = $class; FriendlyName = $friendly }
    }
    return , @($rows)
}

function Get-SimRigRegistryValue {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Value)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $key -or @($key.GetValueNames()) -notcontains $Value) { return $null }
    return $key.GetValue($Value)
}

function Get-SimRigPowerScheme {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    try {
        $line = (& powercfg.exe /getactivescheme 2>$null) -join ' '
        if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+\((.+)\)') {
            return [pscustomobject]@{ Guid = $Matches[1].ToLowerInvariant(); Name = $Matches[2].Trim() }
        }
    }
    catch {
        Write-Verbose ("powercfg not readable: {0}" -f $_.Exception.Message)
    }
    return $null
}

function Get-SimRigTimerResolution {
    <#
        .SYNOPSIS
        Current system timer resolution in ms, from NtQueryTimerResolution
        (read-only; 100 ns units).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()
    try {
        if (-not ('SimRigV4.NtTimer' -as [type])) {
            Add-Type -Namespace SimRigV4 -Name NtTimer -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("ntdll.dll")]
public static extern int NtQueryTimerResolution(out uint MinimumResolution, out uint MaximumResolution, out uint CurrentResolution);
'@
        }
        [uint32]$min = 0; [uint32]$max = 0; [uint32]$cur = 0
        $status = [SimRigV4.NtTimer]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$cur)
        if ($status -ne 0) { return $null }
        return [Math]::Round($cur / 10000.0, 3)
    }
    catch {
        Write-Verbose ("Timer resolution not readable: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Read-SimRigTextFile {
    <#
        .SYNOPSIS
        Reads a text file that another program may hold open (iRacing keeps
        its ini files open), or returns $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $fs = [System.IO.FileStream]::new($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = [System.IO.StreamReader]::new($fs, $true)
            try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
        }
        finally { $fs.Dispose() }
    }
    catch {
        Write-Verbose ("Could not read {0}: {1}" -f $Path, $_.Exception.Message)
        return $null
    }
}

function Read-SimRigJson {
    <#
        .SYNOPSIS
        Reads a JSON file with dates kept as strings (-DateKind String), so an
        ISO time read back stays the string the Engine wrote. Returns $null
        when the file is missing or does not parse.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)] [string] $Path)
    $text = Read-SimRigTextFile -Path $Path
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return ($text | ConvertFrom-Json -DateKind String -Depth 50) }
    catch {
        Write-Verbose ("JSON did not parse: {0}: {1}" -f $Path, $_.Exception.Message)
        return $null
    }
}

function Get-SimRigHashFileName {
    <#
        .SYNOPSIS
        Every file whose SHA-256 the preflight checks, derived from the ship list
        so the two cannot drift.

        .DESCRIPTION
        This exists because they did drift, and it cost Rick an evening on
        2026-09-28. The console built its own list, and the self-test carried a
        separate literal of eight file names that nobody had touched since v4.0.
        VERSIONS.md, meanwhile, is generated from the ship list and carries every
        shipped file.

        So when the self-test ran the preflight, it hashed 8 files and compared
        them against 45, and the other 37 came out as "missing from file hash" -
        36 red preflight rows and a failed "Installed files match VERSIONS.md" on
        a machine where every file was correct and present. A wall of red pointing
        at nothing.

        One list now: what the installer copies is what gets hashed. SHA256SUMS and
        VERSIONS.md are left out because they hold the hashes - a file cannot carry
        its own.

        The directories are read from disk rather than listed, so a part file added
        later is hashed the day it ships. That read is why this lives in the probe
        and not beside Get-SimRigShipItem: engine/Engine.Install.ps1 is pure, and
        A-INST-05 fails the build if anything in it touches the filesystem.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $ScriptDir)

    $ship = Get-SimRigShipItem
    $generated = @('SHA256SUMS', 'VERSIONS.md')
    $names = [System.Collections.Generic.List[string]]::new()

    foreach ($file in @($ship.File)) {
        if ($generated -contains $file) { continue }
        $names.Add([string]$file)
    }

    foreach ($dir in @($ship.Directory)) {
        $path = Join-Path -Path $ScriptDir -ChildPath $dir
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $found = @(Get-ChildItem -LiteralPath $path -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)
        foreach ($item in $found) {
            if (@('.ps1', '.psd1') -notcontains $item.Extension) { continue }
            $names.Add(('{0}/{1}' -f $dir, $item.Name))
        }
    }

    return , @($names.ToArray())
}

function Get-SimRigFileHash {
    <#
        .SYNOPSIS
        SHA-256 of each v4 script and data file, keyed by file name.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $ScriptDir, [Parameter(Mandatory)] [string[]] $FileName)
    $h = @{}
    foreach ($f in $FileName) {
        $p = Join-Path -Path $ScriptDir -ChildPath $f
        $h[$f] = if (Test-Path -LiteralPath $p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToUpperInvariant() } else { 'MISSING' }
    }
    return $h
}

function Get-SimRigBackblazeLastBackup {
    <#
        .SYNOPSIS
        Time of Backblaze's last completed backup, or $null.
    .NOTES
        NOT fixture-backed: no rig capture holds Backblaze's status files. The
        candidates below are Backblaze's documented bzdata locations; TEST-PLAN
        step 1 confirms which one exists on the rig. $null makes the verdict
        WARN "last backup time not readable" (flag 3), never red.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([string] $ProgramData = 'C:\ProgramData')
    $xml = '{0}\Backblaze\bzdata\bzreports\bzstat_lastbackupcompleted.xml' -f $ProgramData.TrimEnd('\')
    $text = Read-SimRigTextFile -Path $xml
    if ($text -and $text -match 'gmt_millis="(\d+)"') {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Matches[1]).LocalDateTime
    }
    if (Test-Path -LiteralPath $xml) { return (Get-Item -LiteralPath $xml).LastWriteTime }
    return $null
}

function Get-SimRigServiceDisplayNameMap {
    <#
        .SYNOPSIS
        DisplayName -> Name for every service. System event 7040/7036 name
        services by display name only.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $map = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($s in @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)) {
        if ($s.DisplayName -and -not $map.ContainsKey($s.DisplayName)) { $map[$s.DisplayName] = $s.Name }
    }
    return $map
}

function Get-SimRigEventRecord {
    <#
        .SYNOPSIS
        Race watch read: System 7040/7036 and TaskScheduler/Operational since a
        time. Event-log reads only - no counters, no sampling (spec 7, T.7).
        Returns records with TimeCreated, Id, Message for the Engine parsers.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [datetime] $Since, [datetime] $Until = [datetime]::MaxValue)
    $svc = @()
    $task = @()
    try {
        $svc = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7040, 7036; StartTime = $Since } -ErrorAction Stop |
                Where-Object { $_.TimeCreated -le $Until } |
                ForEach-Object { [pscustomobject]@{ TimeCreated = $_.TimeCreated; Id = $_.Id; Message = $_.Message } })
    }
    catch [System.Exception] {
        # Get-WinEvent throws when no event matches; that is an empty window.
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { Write-Verbose ("System log read failed: {0}" -f $_.Exception.Message) }
    }
    try {
        $task = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TaskScheduler/Operational'; StartTime = $Since } -ErrorAction Stop |
                Where-Object { $_.TimeCreated -le $Until } |
                ForEach-Object { [pscustomobject]@{ TimeCreated = $_.TimeCreated; Id = $_.Id; Message = $_.Message } })
    }
    catch [System.Exception] {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { Write-Verbose ("TaskScheduler log read failed: {0}" -f $_.Exception.Message) }
    }
    return @{ Service = $svc; Task = $task }
}

function Test-SimRigTaskLogEnabled {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $log = Get-WinEvent -ListLog 'Microsoft-Windows-TaskScheduler/Operational' -ErrorAction Stop
        return [bool]$log.IsEnabled
    }
    catch {
        Write-Verbose ("Task log state not readable: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Test-SimRigAdmin {
    <#
        .NOTES
        Off Windows (the Linux test harness only) there is no Windows identity.
        There, and only there, SIMRIG_TEST_ASSUME_ADMIN=1 stands in for an
        elevated token. On the rig the variable is ignored.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return ($env:SIMRIG_TEST_ASSUME_ADMIN -eq '1') }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-SimRigFolderWritable {
    <#
        .SYNOPSIS
        True when the folder exists and the current user can make a file in it.

        .DESCRIPTION
        It makes one empty file with a random name and removes it. Reading the ACL
        would be a guess about what Windows will allow; this asks Windows.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] [AllowEmptyString()] [string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $trial = Join-Path -Path $Path -ChildPath ('simrig-write-test-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllBytes($trial, [byte[]]@())
        [System.IO.File]::Delete($trial)
        return $true
    }
    catch {
        Write-Verbose ("folder not writable: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Get-SimRigPreflightFact {
    <#
        .SYNOPSIS
        Collects every preflight reading into the Facts hashtable (CONTRACT.md).
        Read-only. Runs unelevated in the console.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [object[]] $QuietItem,
        [Parameter(Mandatory)] [hashtable] $KnownGood,
        [Parameter(Mandatory)] [string] $ScriptDir,
        [Parameter(Mandatory)] [string[]] $HashFile,
        [string] $IRacingInstallDir = 'C:\Program Files (x86)\iRacing',
        # Where iRacing keeps app.ini, core.ini and the renderer ini. This is a
        # machine fact, not a known-good value: it is one user's Documents folder, and
        # known-good.psd1 ships to everybody. The caller passes the profile's IniDir
        # (discovery fills it for a machine with no profile of its own). Rick's
        # decision, 2026-09-27, after the export gate found his user name in the file.
        [AllowNull()] [AllowEmptyString()] [string] $IniDir
    )

    $registry = @{}
    foreach ($r in @($KnownGood.Registry)) {
        $registry[('{0}\{1}' -f $r.Path, $r.Value)] = Get-SimRigRegistryValue -Path $r.Path -Value $r.Value
    }

    # No folder is a normal state, not an error: a PC with no iRacing install, or a
    # first run before discovery has filled it in. The ini readings stay null and every
    # rule that needs one reports Unknown, which is what Test-RuleApplies already does
    # with an unread field. Join-Path on a null root would throw and take the whole
    # preflight with it.
    $iniDirectory = if (-not [string]::IsNullOrWhiteSpace($IniDir)) { $IniDir } else { $null }
    $ini = @{ App = $null; Core = $null; Renderer = $null }
    if ($null -ne $iniDirectory) {
        foreach ($k in @('App', 'Core', 'Renderer')) {
            $text = Read-SimRigTextFile -Path (Join-Path $iniDirectory $KnownGood.IniFile[$k])
            if ($null -ne $text) { $ini[$k] = ConvertFrom-IniText -Text $text }
        }
    }

    $volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } |
            ForEach-Object { [pscustomobject]@{ Drive = [string]$_.DriveLetter; FreeBytes = [int64]$_.SizeRemaining } })

    $gpuPref = Get-SimRigRegistryValue -Path 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Value $KnownGood.GpuPreference.Exe

    $overlayNames = @('RTSS', 'MSIAfterburner', 'Discord', 'Overwolf', 'GameBar', 'Steam', 'NVIDIA Overlay', 'obs64')
    $overlay = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $overlayNames -contains $_.ProcessName } |
            Select-Object -ExpandProperty ProcessName -Unique)

    $serviceItems = @($QuietItem | Where-Object { $_.Kind -eq 'Service' })
    $taskItems = @($QuietItem | Where-Object { $_.Kind -eq 'Task' })
    $defItem = @($QuietItem | Where-Object { $_.Kind -eq 'Defender' })
    $defState = if ($defItem.Count -gt 0) { (Get-SimRigItemState -QuietItem $defItem)[0] } else { $null }

    return @{
        GpuAffinity         = Get-SimRigGpuAffinity -VendorId $KnownGood.GpuSteering.VendorId
        Registry            = $registry
        PowerScheme         = Get-SimRigPowerScheme
        TimerResolutionMs   = Get-SimRigTimerResolution
        Services            = if ($serviceItems.Count) { Get-SimRigItemState -QuietItem $serviceItems } else { @() }
        Tasks               = if ($taskItems.Count) { Get-SimRigItemState -QuietItem $taskItems } else { @() }
        Ini                 = $ini
        Volumes             = $volumes
        IRacingInstallDrive = $IRacingInstallDir.Substring(0, 1)
        DocumentsDrive      = $(if ($null -ne $iniDirectory) { $iniDirectory.Substring(0, 1) } else { $null })
        GpuPreference       = $gpuPref
        FileHash            = Get-SimRigFileHash -ScriptDir $ScriptDir -FileName $HashFile
        VersionsText        = Read-SimRigTextFile -Path (Join-Path $ScriptDir 'VERSIONS.md')
        Overlay             = $overlay
        PendingReboot       = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        Defender            = if ($null -ne $defState) { [pscustomobject]@{ RealtimeOn = $defState.RealtimeOn } } else { $null }
    }
}

function Import-SimRigRule {
    <#
        .SYNOPSIS
        Loads the rules files named by a profile's RuleSet from a folder, in
        that order. The Engine is pure, so file reading lives here.

        .DESCRIPTION
        Import-PowerShellDataFile reads a .psd1 in PowerShell's restricted
        language: no code runs from a rules file. A missing file is an error
        with the path in it, not a silent empty rule set.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $Folder,
        [Parameter(Mandatory)] [string[]] $Area
    )

    $documents = foreach ($area in @($Area)) {
        $path = Join-Path -Path $Folder -ChildPath ('{0}.psd1' -f $area)
        if (-not (Test-Path -LiteralPath $path)) { throw "Rules file missing: $path" }
        Import-PowerShellDataFile -LiteralPath $path
    }
    return , @($documents)
}

function Import-SimRigProfile {
    <#
        .SYNOPSIS
        Loads every profile in a folder. Returns an empty list when the folder
        is not there, so a fresh install still starts.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [string] $Folder)

    if (-not (Test-Path -LiteralPath $Folder)) { return , @() }
    $documents = foreach ($file in @(Get-ChildItem -LiteralPath $Folder -Filter '*.psd1' -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
        Import-PowerShellDataFile -LiteralPath $file.FullName
    }
    return , @($documents)
}

function Get-SimRigNewestFile {
    <#
        .SYNOPSIS
        Newest file matching a filter in a folder, written after a time, or $null.
        Used for the CapFrameX capture (CapFrameX-*.json in C:\SimRacer\Logs).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)] [string] $Directory, [Parameter(Mandatory)] [string] $Filter, [Parameter(Mandatory)] [datetime] $Since)
    if (-not (Test-Path -LiteralPath $Directory)) { return $null }
    return Get-ChildItem -LiteralPath $Directory -Filter $Filter -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $Since } |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -First 1
}

# --------------------------------------------------------------------------
# Background call (v4.0.3): run a read in a second runspace so the window
# can show at once. The caller polls Test-/Receive- from a DispatcherTimer.
# --------------------------------------------------------------------------

function Start-SimRigBackgroundCall {
    <#
        Dot-sources -ScriptFile into a new runspace and calls -Command with
        -Parameter there. Returns a handle for Test-/Receive-SimRigBackgroundCall.
        Only reads belong here: the runspace runs unelevated, like the console.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string[]] $ScriptFile,
        [Parameter(Mandatory)] [string] $Command,
        [hashtable] $Parameter = @{}
    )
    if (-not $PSCmdlet.ShouldProcess($Command, 'start background runspace')) { return $null }
    $ps = [System.Management.Automation.PowerShell]::Create()
    $body = @'
param([string[]] $ScriptFile, [string] $Command, [hashtable] $Parameter)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
foreach ($f in $ScriptFile) { . $f }
& $Command @Parameter
'@
    [void]$ps.AddScript($body).AddParameter('ScriptFile', $ScriptFile).AddParameter('Command', $Command).AddParameter('Parameter', $Parameter)
    $handle = $ps.BeginInvoke()
    return [pscustomobject]@{ PowerShell = $ps; Handle = $handle; Command = $Command; Started = (Get-Date) }
}

function Test-SimRigBackgroundCall {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] $Call)
    return [bool]$Call.Handle.IsCompleted
}

function Receive-SimRigBackgroundCall {
    <#
        Ends the call and returns its last output object (unwrapped). A
        terminating error in the runspace is thrown here, with the command name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Call)
    try {
        $out = $Call.PowerShell.EndInvoke($Call.Handle)
        if ($Call.PowerShell.Streams.Error.Count -gt 0 -and $out.Count -eq 0) {
            throw $Call.PowerShell.Streams.Error[0].Exception
        }
        if ($out.Count -eq 0) { return $null }
        $last = $out[$out.Count - 1]
        if ($null -eq $last) { return $null }
        return $last.PSObject.BaseObject
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        throw ('{0} failed in the background: {1}' -f $Call.Command, $inner.Message)
    }
    finally { $Call.PowerShell.Dispose() }
}

# ==========================================================================
# v4.2 loaders and the machine reading (lead, 2026-09-26)
#
# These read. Every decision they feed is made by a pure function in the engine
# or in an engine/ part file, which is why they live here and not there.
#
# They exist because SimRigConsole.ps1 called no v4.2 function at all: the rules,
# the profiles, the discovery and the machine profile were written, tested and
# wired to nothing. Unit U3.12 found that while reading the tree to write the
# documentation, after nine hundred unit tests had gone green around it.
# ==========================================================================

function Get-SimRigRuleDocument {
    <#
        .SYNOPSIS
        Every rules/*.psd1, sorted by name.

        .DESCRIPTION
        Sorted rather than a hand-written list, because a hand-written list is how
        rules/public-manual.psd1 ended up outside every golden in wave 3b - a rule
        file nobody loads is a rule file nobody notices breaking.

        A file that does not parse is reported, not skipped: grading with a rules
        file silently missing would give a clean preflight for the wrong reason.

        .OUTPUTS
        [pscustomobject] Document (the loaded rule hashtables), Error (one string
        per file that would not load), Path (the files that did load).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Directory
    )

    $document = [System.Collections.Generic.List[object]]::new()
    $errorText = [System.Collections.Generic.List[string]]::new()
    $loaded = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $Directory)) {
        $errorText.Add(('The rules folder is missing: {0}' -f $Directory))
        return [pscustomobject]@{ Document = @(); Error = @($errorText.ToArray()); Path = @() }
    }

    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter *.psd1 -File | Sort-Object -Property Name) {
        try {
            $data = Import-PowerShellDataFile -LiteralPath $file.FullName
            $ruleErrors = @(Test-RuleData -Data $data | Where-Object { $_ })
            if ($ruleErrors.Count -gt 0) {
                foreach ($e in $ruleErrors) { $errorText.Add(('{0}: {1}' -f $file.Name, $e)) }
            } else {
                $document.Add($data)
                $loaded.Add($file.Name)
            }
        }
        catch {
            $errorText.Add(('{0}: {1}' -f $file.Name, ($_.Exception.Message -replace '\s+', ' ').Trim()))
        }
    }

    return [pscustomobject]@{
        Document = @($document.ToArray())
        Error    = @($errorText.ToArray())
        Path     = @($loaded.ToArray())
    }
}

function Get-SimRigProfileDocument {
    <#
        .SYNOPSIS
        Every profiles/*.psd1, sorted by name.

        .DESCRIPTION
        Same rule as the rules loader: a profile that will not load is an error,
        never a silent omission. If the only profile that loads is the public one,
        a grading run would quietly compare this rig against a stranger's
        expectations, which looks like a rig that has gone wrong.

        .OUTPUTS
        [pscustomobject] Document, Error, Path
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Directory
    )

    $document = [System.Collections.Generic.List[object]]::new()
    $errorText = [System.Collections.Generic.List[string]]::new()
    $loaded = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $Directory)) {
        $errorText.Add(('The profiles folder is missing: {0}' -f $Directory))
        return [pscustomobject]@{ Document = @(); Error = @($errorText.ToArray()); Path = @() }
    }

    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter *.psd1 -File | Sort-Object -Property Name) {
        try {
            $data = Import-PowerShellDataFile -LiteralPath $file.FullName
            $profileErrors = @(Test-ProfileData -Data $data | Where-Object { $_ })
            if ($profileErrors.Count -gt 0) {
                foreach ($e in $profileErrors) { $errorText.Add(('{0}: {1}' -f $file.Name, $e)) }
            } else {
                $document.Add($data)
                $loaded.Add($file.Name)
            }
        }
        catch {
            $errorText.Add(('{0}: {1}' -f $file.Name, ($_.Exception.Message -replace '\s+', ' ').Trim()))
        }
    }

    return [pscustomobject]@{
        Document = @($document.ToArray())
        Error    = @($errorText.ToArray())
        Path     = @($loaded.ToArray())
    }
}

function Get-SimRigMachineReading {
    <#
        .SYNOPSIS
        Reads this PC and returns the blocks Build-MachineProfile joins.

        .DESCRIPTION
        Windows-only, and the one function in the v4.2 discovery path that cannot
        be tested on Linux. It is deliberately thin for that reason: it gathers,
        hands each reading to a pure function, and returns what those return. Every
        decision - what X3D means, which core the target is, how a layout is
        classified - is made in engine/ and tested there.

        A reading that fails is $null and is named in Unavailable. Nothing here
        throws: a PC that refuses one read still gets a preflight, with that row
        reading Unknown rather than the console falling over before a race.

        Three blocks have no live reader anywhere in the tree yet, and they are
        reported as unavailable instead of being guessed:

          Display            - engine/Engine.Layout.ps1 grades a display-path
                               reading, and nothing calls QueryDisplayConfig to
                               produce one. Unit U3.2 left the live call to the
                               probe by design and it was never written.
          NetworkAdapter     - quiet-list.psd1 gates WlanSvc on it (G-1) and no
                               reader exists.
          BluetoothConnected - the three Bluetooth services are gated on it (G-2)
                               and no reader exists.

        Missing is the safe direction for all three: Test-RuleApplies treats an
        unread field as matching 'any' and nothing else, so WlanSvc and the
        Bluetooth services are simply not offered. Nobody's wireless gets switched
        off on the strength of a field this function could not read.

        .OUTPUTS
        [pscustomobject] Cpu CpuSteering Gpu Windows Display IRacing NetworkAdapter
        BluetoothConnected Confidence ConfidenceReason Unavailable Note
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] $ProfileValues,
        [switch] $IncludeBuffer,
        # The layout the user confirmed, from settings. Given, it replaces the
        # inferred one and its confidence becomes Manual - a person said so, which is
        # worth more than the inference Surround cannot settle on its own.
        [AllowNull()] $Settings
    )

    $unavailable = [System.Collections.Generic.List[string]]::new()
    $note = [System.Collections.Generic.List[string]]::new()
    $confidence = [ordered]@{}
    $confidenceReason = [ordered]@{}

    # --- CPU topology and the steering target ------------------------------
    $cpuBlock = $null
    $steerBlock = $null
    try {
        $reading = if ($IncludeBuffer) { Get-CpuTopologyReading -IncludeBuffer -CaptureTakenAt (Get-Date) } else { Get-CpuTopologyReading }
        # The single-CCD steering target is a profile value and discovery never
        # synthesizes one (CONTRACT.md). Passing it in is what makes the mask check
        # possible; without it the target stays $null at Confidence Unknown.
        $target = $null
        if ($null -ne $ProfileValues) {
            $steer = Get-KnownGoodField -Entry $ProfileValues -Name 'GpuSteering'
            if ($null -ne $steer) {
                $default = Get-KnownGoodField -Entry $steer -Name 'Default'
                if ($null -ne $default) { $target = Get-KnownGoodField -Entry $default -Name 'Cpu' }
            }
        }
        $topology = if ($null -ne $target) { Get-CpuTopology -Reading $reading -ProfileTargetCpu $target } else { Get-CpuTopology -Reading $reading }
        $cpuBlock = Get-KnownGoodField -Entry $topology -Name 'Cpu'
        $steerBlock = Get-KnownGoodField -Entry $topology -Name 'CpuSteering'
        $topConfidence = Get-KnownGoodField -Entry $topology -Name 'Confidence'
        if ($null -ne $topConfidence) { foreach ($key in @($topConfidence.Keys)) { $confidence[$key] = $topConfidence[$key] } }
        $topReason = Get-KnownGoodField -Entry $topology -Name 'ConfidenceReason'
        if ($null -ne $topReason) { foreach ($key in @($topReason.Keys)) { $confidenceReason[$key] = $topReason[$key] } }
        foreach ($n in @(Get-KnownGoodField -Entry $topology -Name 'Note')) { if ($n) { $note.Add([string]$n) } }
    }
    catch {
        $unavailable.Add('Cpu')
        $note.Add(('The CPU topology could not be read: {0}' -f ($_.Exception.Message -replace '\s+', ' ').Trim()))
    }

    # --- GPU functions and their steering policy ---------------------------
    $gpuBlock = $null
    try {
        $pnp = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.InstanceId -like 'PCI\VEN_10DE*' })
        $policy = @{}
        # Assign, then wrap. Wrapping the call itself handed this loop one item that
        # was the whole device array, so InstanceId read as $null and the policy map
        # stayed empty on every machine.
        # -VendorId is mandatory. Without it the console stopped at a prompt for it
        # that no window shows, which is what "the launcher didn't launch" was on
        # 2026-09-28. NVIDIA here, because the block above reads NVIDIA functions.
        $affinityRows = Get-SimRigGpuAffinity -VendorId 'VEN_10DE'
        foreach ($row in @($affinityRows)) {
            $instance = Get-KnownGoodField -Entry $row -Name 'InstanceId'
            if ($instance) {
                $policy[$instance] = @{
                    DevicePolicy          = Get-KnownGoodField -Entry $row -Name 'DevicePolicy'
                    AssignmentSetOverride = Get-KnownGoodField -Entry $row -Name 'AssignmentSetOverride'
                }
            }
        }
        $driver = @{}
        $version = Get-GpuDriverVersionReading
        if ($version) { foreach ($d in $pnp) { $driver[$d.InstanceId] = $version } }
        $gpuBlock = Get-SimRigGpuDiscovery -PnpDevice $pnp -AffinityPolicy $policy -DriverVersion $driver
    }
    catch {
        $unavailable.Add('Gpu')
        $note.Add(('The GPU could not be read: {0}' -f ($_.Exception.Message -replace '\s+', ' ').Trim()))
    }

    # --- Windows and iRacing ------------------------------------------------
    $windowsBlock = $null
    $iracingBlock = $null
    try {
        $os = Get-SoftwareOperatingSystem
        $buildText = $null
        $buildNumber = Get-KnownGoodField -Entry $os -Name 'Build'
        if ($null -ne $buildNumber) {
            $buildText = Format-SoftwareWindowsBuild -Build ([int]$buildNumber) -Ubr (Get-KnownGoodField -Entry $os -Name 'Ubr')
        }
        $gameModeRaw = Get-SoftwareGameModeRaw
        $gameMode = ConvertTo-GameModeState -ValueExists ([bool](Get-KnownGoodField -Entry $gameModeRaw -Name 'Exists')) `
            -Value (Get-KnownGoodField -Entry $gameModeRaw -Name 'Value')
        $laptop = Test-SoftwareLaptop -HasBattery ([bool](Get-SoftwareBatteryPresence)) -ChassisType @(Get-SoftwareChassisType)
        # Both candidate lists come back in the comma form, so they are assigned first.
        # Wrapped in place, Resolve-SoftwarePath received one candidate that was the
        # list, matched nothing in it, and reported the path as not found.
        $installCandidate = Get-SoftwareIRacingPathCandidate
        $iniCandidate = Get-SoftwareIRacingDocumentsCandidate
        $install = Resolve-SoftwarePath -Candidate @($installCandidate) -FieldName 'InstallDir'
        $ini = Resolve-SoftwarePath -Candidate @($iniCandidate) -FieldName 'IniDir'
        $software = Build-SoftwareMachineProfile -Build $buildText -Edition (Get-KnownGoodField -Entry $os -Name 'Edition') `
            -Laptop $laptop -GameMode $gameMode -GameBarVersion (Get-SoftwareGameBarVersion) `
            -InstallDir (Get-KnownGoodField -Entry $install -Name 'Value') -IniDir (Get-KnownGoodField -Entry $ini -Name 'Value')
        $windowsBlock = Get-KnownGoodField -Entry $software -Name 'Windows'
        $iracingBlock = Get-KnownGoodField -Entry $software -Name 'IRacing'
    }
    catch {
        $unavailable.Add('Windows')
        $unavailable.Add('IRacing')
        $note.Add(('Windows and iRacing details could not be read: {0}' -f ($_.Exception.Message -replace '\s+', ' ').Trim()))
    }

    # --- Display, network adapter, Bluetooth --------------------------------
    $displayBlock = $null
    try {
        $screenReading = Get-SimRigScreenReading
        if (@($screenReading.Screen).Count -eq 0) {
            $unavailable.Add('Display')
            $note.Add('No display was read, so the layout is Unknown.')
            if ($screenReading.Note) { $note.Add([string]$screenReading.Note) }
        } else {
            $records = ConvertTo-DisplayPathRecord -Screen $screenReading.Screen -RefreshRateHz $screenReading.RefreshRateHz
            $layout = Get-SimRigDisplayLayout -Path $records -MonitorCount @($screenReading.Screen).Count
            $displayBlock = @{
                Layout  = Get-KnownGoodField -Entry $layout -Name 'Layout'
                Count   = Get-KnownGoodField -Entry $layout -Name 'Count'
                Refresh = Get-KnownGoodField -Entry $layout -Name 'Refresh'
            }
            # A confirmed layout wins over the inference (spec 11a, and
            # Get-SimRigDisplayLayout's own Reason says why it cannot settle Surround).
            $effective = Get-SimRigEffectiveDisplayLayout -Discovered $layout -Settings $Settings
            $displayBlock['Layout'] = $effective.Layout
            $confidence['Layout'] = [string]$effective.Confidence
            if ($effective.Source -eq 'confirmed') { $confidenceReason['Layout'] = [string]$effective.Reason }
            if ($screenReading.Note) { $note.Add([string]$screenReading.Note) }
            if ($null -eq $screenReading.RefreshRateHz) {
                $confidence['Refresh'] = 'Unknown'
                $confidenceReason['Refresh'] = 'The refresh rate was not read, so it shows as 0 rather than a number this app made up.'
            }
        }
    }
    catch {
        $unavailable.Add('Display')
        $note.Add(('The display layout could not be read: {0}' -f ($_.Exception.Message -replace '\s+', ' ').Trim()))
    }

    $adapterKind = $null
    $adapterResult = Resolve-NetworkAdapterKind -PhysicalMediaType (Get-SimRigNetworkAdapterReading)
    if ($adapterResult.Kind -eq 'Unknown') {
        $unavailable.Add('NetworkAdapter')
        if ($adapterResult.Reason) { $note.Add([string]$adapterResult.Reason) }
    } else {
        $adapterKind = [string]$adapterResult.Kind
    }
    $confidence['NetworkAdapter'] = [string]$adapterResult.Confidence
    if ($adapterResult.Reason) { $confidenceReason['NetworkAdapter'] = [string]$adapterResult.Reason }

    $bluetooth = $null
    $btResult = Resolve-BluetoothConnected -Device (Get-SimRigBluetoothDeviceReading)
    if ($btResult.Confidence -eq 'Unknown') {
        $unavailable.Add('BluetoothConnected')
        $note.Add([string]$btResult.Reason)
    } else {
        $bluetooth = [bool]$btResult.Connected
    }
    $confidence['BluetoothConnected'] = [string]$btResult.Confidence
    $confidenceReason['BluetoothConnected'] = [string]$btResult.Reason

    return [pscustomobject]@{
        Cpu                = $cpuBlock
        CpuSteering        = $steerBlock
        Gpu                = $gpuBlock
        Windows            = $windowsBlock
        Display            = $displayBlock
        IRacing            = $iracingBlock
        NetworkAdapter     = $adapterKind
        BluetoothConnected = $bluetooth
        Confidence         = $confidence
        ConfidenceReason   = $confidenceReason
        Unavailable        = @($unavailable.ToArray())
        Note               = @($note.ToArray())
    }
}

function Get-SimRigMachineContext {
    <#
        .SYNOPSIS
        Reads this PC, selects its profile, and returns the machine profile that
        Select-QuietItemForMachine and the rules read.

        .DESCRIPTION
        One function for the console and for the elevated child (blocker 5,
        2026-10-02). The console had these steps inline and the child had none, so the
        window showed the quiet items of this PC and the child wrote the full list. A
        filter that is only in the window is not a filter: the process that writes
        decides, and it decides with this function and not with a copy.

        Two readings, because neither can be skipped: the profile is selected from the
        first, and the second gets the steering target of that profile.

        A reading that fails is $null and is named in Unavailable. Test-RuleApplies
        reads a field that was not read as "matches 'any' only", so an item that asks
        for a value of that field does not apply. The profile is never $null when a
        profile file loaded, so Machine.Profile is set and an item for another profile
        does not apply.

        .OUTPUTS
        [pscustomobject] Machine, RigProfile, Reading
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ProfileDocument,
        [AllowNull()] [string] $MachineName,
        [AllowNull()] $Settings
    )

    $reading = Get-SimRigMachineReading -Settings $Settings
    $firstPass = Build-MachineProfile -TakenAt (Get-Date) -MachineName $MachineName `
        -Cpu $reading.Cpu -CpuSteering $reading.CpuSteering `
        -Gpu $reading.Gpu -Windows $reading.Windows `
        -Display $reading.Display -IRacing $reading.IRacing `
        -NetworkAdapter $reading.NetworkAdapter -BluetoothConnected $reading.BluetoothConnected `
        -Confidence $reading.Confidence -ConfidenceReason $reading.ConfidenceReason

    $rigProfile = Select-SimRigProfile -RigProfile $ProfileDocument -Machine $firstPass
    $values = $null
    if ($null -ne $rigProfile) {
        $values = Get-KnownGoodField -Entry $rigProfile -Name 'Values'
        $reading = Get-SimRigMachineReading -ProfileValues $values -Settings $Settings
    }

    $machine = Build-MachineProfile -TakenAt (Get-Date) -MachineName $MachineName `
        -Cpu $reading.Cpu -CpuSteering $reading.CpuSteering `
        -Gpu $reading.Gpu -Windows $reading.Windows `
        -Display $reading.Display -IRacing $reading.IRacing `
        -ProfileId $(if ($null -ne $rigProfile) { [string](Get-KnownGoodField -Entry $rigProfile -Name 'Id') } else { $null }) `
        -NetworkAdapter $reading.NetworkAdapter -BluetoothConnected $reading.BluetoothConnected `
        -DefenderOptIn $(if ($null -ne $values) { Get-KnownGoodField -Entry $values -Name 'DefenderOptIn' } else { $null }) `
        -Confidence $reading.Confidence -ConfidenceReason $reading.ConfidenceReason

    return [pscustomobject]@{
        Machine    = $machine
        RigProfile = $rigProfile
        Reading    = $reading
    }
}

function Get-SimRigNetworkAdapterReading {
    <#
        .SYNOPSIS
        The PhysicalMediaType of the adapter carrying the default route.

        .DESCRIPTION
        The adapter that matters is the one traffic actually leaves by, not the
        first one Windows lists: a rig with a cable plugged in and Wi-Fi also
        enabled is wired, and a rule that looked at the wrong adapter would switch
        off the radio the session depends on.

        So it follows the default route to an interface index and reads that
        adapter. A machine with no default route - no network at all - returns
        $null, which the engine reads as Unknown.

        Windows-only. Every decision on the string it returns is in
        engine/Engine.Peripheral.ps1 and tested there.

        .OUTPUTS
        [string] the PhysicalMediaType, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object -Property RouteMetric |
            Select-Object -First 1
        if ($null -eq $route) { return $null }
        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop
        if ($null -eq $adapter) { return $null }
        return [string]$adapter.PhysicalMediaType
    }
    catch {
        Write-Verbose ('Get-SimRigNetworkAdapterReading: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Get-SimRigBluetoothDeviceReading {
    <#
        .SYNOPSIS
        The present Bluetooth PnP device nodes.

        .DESCRIPTION
        Returns the nodes; Resolve-BluetoothConnected decides what they mean. A
        failed read returns $null, which that function reads as Unknown rather than
        as "nothing connected" - the two are not the same and the G-2 guard must
        not fire on the first.

        Windows-only.

        .OUTPUTS
        [object[]] InstanceId and Status per node, or $null.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    try {
        $devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $_.InstanceId -match '^(BTHENUM|BTHLEDEVICE)\\' } |
            ForEach-Object { [pscustomobject]@{ InstanceId = [string]$_.InstanceId; Status = [string]$_.Status } })
        return , @($devices)
    }
    catch {
        Write-Verbose ('Get-SimRigBluetoothDeviceReading: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Get-SimRigScreenReading {
    <#
        .SYNOPSIS
        The active display rectangles and the primary refresh rate.

        .DESCRIPTION
        Uses System.Windows.Forms.Screen for the rectangles, which the app already
        has available - it is a WPF application and requires the Windows Desktop
        runtime - and Win32_VideoController for the refresh rate, which Screen does
        not carry. This is a documented pair of reads rather than a
        QueryDisplayConfig P/Invoke, which is what engine/Engine.Layout.ps1 was
        written against; the record shape is the same either way, and the P/Invoke
        can replace this later without touching the grading.

        Windows-only. A failed read returns an empty screen list, and the layout
        then grades Unknown rather than the console falling over before a race.

        .OUTPUTS
        [pscustomobject] Screen (X, Y, Width, Height, Primary per display),
        RefreshRateHz, Note.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $note = $null
    $screens = @()
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $screens = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
                [pscustomobject]@{
                    X       = [int]$_.Bounds.X
                    Y       = [int]$_.Bounds.Y
                    Width   = [int]$_.Bounds.Width
                    Height  = [int]$_.Bounds.Height
                    Primary = [bool]$_.Primary
                }
            })
    }
    catch {
        $note = ('The display rectangles could not be read: {0}' -f ($_.Exception.Message -replace '\s+', ' ').Trim())
    }

    $refresh = $null
    try {
        $controller = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.CurrentRefreshRate } | Select-Object -First 1
        if ($null -ne $controller) { $refresh = [double]$controller.CurrentRefreshRate }
    }
    catch {
        $note = (@($note, ('The refresh rate could not be read: {0}' -f ($_.Exception.Message -replace '\s+', ' ').Trim())) | Where-Object { $_ }) -join ' '
    }

    return [pscustomobject]@{ Screen = $screens; RefreshRateHz = $refresh; Note = $note }
}

function Get-SimRigInstallRootAcl {
    <#
        .SYNOPSIS
        The access rules on a folder, shaped for Get-SimRigInstallAclVerdict.

        .DESCRIPTION
        Flag 3: the console runs its own code elevated, so a folder a standard user
        can write to is a folder where a standard user can choose what runs as
        administrator. This reads the folder's ACL; the installer's own rule decides
        whether it is safe, so there is one rule rather than two that can disagree.

        A read that fails returns an empty list, which that rule grades as unsafe.
        That is the right way round: a folder whose permissions cannot be read is
        not a folder to run elevated code from.

        Windows-only.

        .OUTPUTS
        [object[]] Identity, Rights, Type per access rule.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $rules = @($acl.Access | ForEach-Object {
                [pscustomobject]@{
                    Identity = [string]$_.IdentityReference
                    Rights   = [string]$_.FileSystemRights
                    Type     = [string]$_.AccessControlType
                }
            })
        return , @($rules)
    }
    catch {
        Write-Verbose ('Get-SimRigInstallRootAcl: {0}' -f $_.Exception.Message)
        return , @()
    }
}

function Get-SimRigToolReading {
    <#
        .SYNOPSIS
        The Tools-card rows for the real machine (spec 11b): what is installed,
        what is missing, and what is too old.

        .DESCRIPTION
        Two reads and one pure call. It exists because the three parts of this
        chain - the Uninstall entries, the running processes, and the inventory
        that grades them - were all written and nothing joined them, so the Tools
        card was built and never filled.

        Each read is guarded on its own. A machine where the Uninstall hive cannot
        be read still gets rows from the process list, marked Installed with an
        unknown version rather than Missing, because a running process is real
        evidence that a tool is there.

        .OUTPUTS
        [object[]] The Get-SoftwareToolInventory rows.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    # Both of these return the comma form. Assigned, then wrapped: wrapping the call
    # gave the tool inventory one entry that was the whole list, so nothing matched.
    $uninstall = @()
    try { $uninstallRaw = Get-SoftwareUninstallEntry; $uninstall = @($uninstallRaw) }
    catch { Write-Verbose ("Get-SimRigToolReading: Uninstall entries unreadable: {0}" -f $_.Exception.Message) }

    $running = @()
    try { $runningRaw = Get-SoftwareRunningProcessName; $running = @($runningRaw) }
    catch { Write-Verbose ("Get-SimRigToolReading: process list unreadable: {0}" -f $_.Exception.Message) }

    $detected = Get-SoftwareDetectedToolVersion -UninstallEntry $uninstall -RunningProcess $running
    $rows = Get-SoftwareToolInventory -Detected $detected
    return , @($rows)
}

function Get-SimRigUserSid {
    <#
        .SYNOPSIS
        The SID of the user this process is running as (G-12). $null when it cannot
        be read.

        .DESCRIPTION
        Read in the unelevated console, before it elevates, and passed to the child
        - which may be running as somebody else entirely, because a standard user
        can type an administrator's credentials at the prompt. The child cannot read
        this for itself: by then the answer is the administrator's.

        Returns $null rather than throwing. Without a SID the child writes HKCU as
        the data files say, which is correct whenever the racer is the one
        elevating; the child logs which of the two it did.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -eq $identity -or $null -eq $identity.User) { return $null }
        return [string]$identity.User.Value
    }
    catch {
        Write-Verbose ("Get-SimRigUserSid: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-SimRigLastBootTime {
    <#
        .SYNOPSIS
        When this Windows install last started, or $null. Used to tell one boot's
        console starts apart from the next boot's.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($null -eq $os) { return $null }
        return $os.LastBootUpTime
    }
    catch {
        Write-Verbose ('Get-SimRigLastBootTime: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Get-SimRigShareDenyReading {
    <#
        .SYNOPSIS
        The private values on this machine, for the report denylist (flag 8). One
        record; every field is $null or empty when the reading failed.

        .DESCRIPTION
        The denylist is what turns this machine's own strings into placeholders
        before a report leaves the PC. The regex rules in the anonymizer catch the
        shapes (a path, a mail address, an IP); the denylist catches the values -
        this rig's name, this racer's name, this NAS.

        Every read is on its own: a machine with no domain, no mapped drive or no
        readable disk serial still gets every other value. A failed read is left
        out, never turned into an empty string, because an empty denylist entry
        would match everything.

        Windows-only. It reads; it decides nothing. Get-ShareDenyArgument in
        SimRig.Share.ps1 turns this into the denylist arguments, and is tested
        there.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $reading = [ordered]@{
        UserName          = $null
        FullName          = $null
        ComputerName      = $null
        Domain            = $null
        Sid               = @()
        IpAddress         = @()
        MacAddress        = @()
        VolumeLabel       = @()
        VolumeSerial      = @()
        DiskSerial        = @()
        MappedDriveTarget = @()
    }

    try { $reading['UserName'] = [string][System.Environment]::UserName } catch { Write-Verbose ('deny reading UserName: {0}' -f $_.Exception.Message) }
    try { $reading['ComputerName'] = [string][System.Environment]::MachineName } catch { Write-Verbose ('deny reading ComputerName: {0}' -f $_.Exception.Message) }

    $sid = Get-SimRigUserSid
    if ($sid) { $reading['Sid'] = @([string]$sid) }

    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($null -ne $system) { $reading['Domain'] = [string]$system.Domain }
    }
    catch { Write-Verbose ('deny reading Domain: {0}' -f $_.Exception.Message) }

    try {
        $account = Get-CimInstance -ClassName Win32_UserAccount -Filter ('Name = "{0}"' -f [string]$reading['UserName']) -ErrorAction Stop |
            Select-Object -First 1
        if ($null -ne $account) { $reading['FullName'] = [string]$account.FullName }
    }
    catch { Write-Verbose ('deny reading FullName: {0}' -f $_.Exception.Message) }

    try {
        $reading['IpAddress'] = @(Get-NetIPAddress -ErrorAction Stop |
                Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^(127\.|::1$|169\.254\.|fe80:)' } |
                ForEach-Object { [string]$_.IPAddress } | Sort-Object -Unique)
    }
    catch { Write-Verbose ('deny reading IpAddress: {0}' -f $_.Exception.Message) }

    try {
        $reading['MacAddress'] = @(Get-NetAdapter -ErrorAction Stop |
                Where-Object { $_.MacAddress } | ForEach-Object { [string]$_.MacAddress } | Sort-Object -Unique)
    }
    catch { Write-Verbose ('deny reading MacAddress: {0}' -f $_.Exception.Message) }

    try {
        $disk = @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop)
        $reading['VolumeLabel'] = @($disk | ForEach-Object { [string]$_.VolumeName } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $reading['VolumeSerial'] = @($disk | ForEach-Object { [string]$_.VolumeSerialNumber } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }
    catch { Write-Verbose ('deny reading volumes: {0}' -f $_.Exception.Message) }

    try {
        $reading['DiskSerial'] = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop |
                ForEach-Object { [string]$_.SerialNumber } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }
    catch { Write-Verbose ('deny reading DiskSerial: {0}' -f $_.Exception.Message) }

    try {
        $reading['MappedDriveTarget'] = @(Get-CimInstance -ClassName Win32_MappedLogicalDisk -ErrorAction Stop |
                ForEach-Object { [string]$_.ProviderName } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }
    catch { Write-Verbose ('deny reading MappedDriveTarget: {0}' -f $_.Exception.Message) }

    return [pscustomobject]$reading
}

function Test-SimRigUserHiveMounted {
    <#
        .SYNOPSIS
        True when the racer's registry hive is loaded, so HKEY_USERS\<sid> can be
        written (flag 4).

        .DESCRIPTION
        The deadman runs as SYSTEM at the racer's sign-in. Task Scheduler can start
        it before the profile is fully mounted, and it can also be started by hand
        while the racer is not signed in at all. In both cases
        HKEY_USERS\<sid> is simply absent, and a write there would either fail or
        create a stray key that nothing ever reads.

        So the caller asks first, and skips the user items rather than guessing.
        $false on any error, because "cannot tell" and "not there" lead to the same
        safe decision.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $UserSid)

    try {
        return [bool](Test-Path -LiteralPath ('Registry::HKEY_USERS\{0}' -f $UserSid))
    }
    catch {
        Write-Verbose ("Test-SimRigUserHiveMounted: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Get-SimRigSettingsRaw {
    <#
        .SYNOPSIS
        The settings file as a hashtable, or $null when there is none (spec 11a,
        flag 16).

        .DESCRIPTION
        -AsHashtable on purpose: Repair-SimRigSettings checks keys with ContainsKey,
        which a PSCustomObject does not have, and under strict mode a missing property
        throws rather than returning $null.

        $null for a missing file, which is the first run and not a fault. $null for an
        unreadable or invalid one too, with a verbose line - Repair then treats it as a
        first run and says every value is a default, which is the honest reading: a file
        this app cannot parse tells it nothing.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
    }
    catch {
        Write-Verbose ("Get-SimRigSettingsRaw: {0} is not readable as JSON: {1}" -f $Path, $_.Exception.Message)
        return $null
    }
}

function Save-SimRigSettingsFile {
    <#
        .SYNOPSIS
        Writes the settings file, via a temporary file and a move, so a crash
        mid-write cannot leave a half-written settings file behind.

        .DESCRIPTION
        The same pattern the elevated child uses for its own documents. It matters
        more here than it looks: a truncated settings file is refused on the next
        start (flag 16), and the user would have lost their save paths to a power cut.

        Returns the path written. Throws on failure - the caller says so rather than
        reporting a save that did not happen.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Settings
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'write settings')) { return $Path }
    $json = $Settings | ConvertTo-Json -Depth 8
    $temp = '{0}.tmp' -f $Path
    Set-Content -LiteralPath $temp -Value $json -Encoding UTF8 -ErrorAction Stop
    Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop
    return $Path
}

function Get-SimRigAdvisoryUrl {
    <#
        .SYNOPSIS
        Where the advisories document lives.

        .DESCRIPTION
        One constant, next to the probe that fetches it. The site is the public
        repo's Pages site, and the file is published by the site unit (U4.4).

        .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return 'https://rcsracing93.github.io/iracing-stutter-fix/data/advisories.json'
}

function Get-SimRigAdvisoryDocument {
    <#
        .SYNOPSIS
        Fetches and parses the advisories document. $null on any failure.

        .DESCRIPTION
        The only outbound request this app makes that the user did not ask for by
        name, so it is worth being exact about what it is: a plain GET of one public
        static file. Nothing about the PC is sent - no query string, no headers
        beyond what the HTTP client adds, no body. The caller checks the
        UpdateCheck setting first, and this is never reached when it is off.

        Failure is $null, not an exception. No internet at the rig is the normal
        case, not an error the user should see a stack trace for, and
        Get-SimRigUpdateVerdict turns $null into a sentence that says the list could
        not be reached and that nothing was sent.

        Not covered by tier A: it is the network boundary. Tier B exercises it.

        .OUTPUTS
        [object] the parsed document, or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [string] $Url = (Get-SimRigAdvisoryUrl),
        [int] $TimeoutSec = 5
    )

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        if ($null -eq $response -or [string]::IsNullOrWhiteSpace([string]$response.Content)) { return $null }
        return ([string]$response.Content | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        Write-Verbose ('Get-SimRigAdvisoryDocument: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Find-SimRigPathLink {
    <#
        Blocker 6, rule 5 (Rick's "Yes", 2026-10-07). The first item from Root down to Path, Path
        included, that is a link (a reparse point: a junction or a symbolic link), or $null. An item
        that is not there is not a link. Root is the data folder of the app (C:\SimRacer). The race
        between this read and the write is a limit (the record of the unit). It reads the file system,
        so it is not in the engine. The attributes are read as text, as on Windows and the Mac.
        Blocker 7, commit 9: moved here from SimRig.Actions.ps1 with no change, because the window also
        calls it (question 1 of REQUEST-night-o2-4e3b9e5.md). The child loads this file.

        From Root down, each item is read from the list of its parent folder, which gives the item
        itself and does not follow a link (also a link to a place that is not there). Fail closed: a
        folder whose list cannot be read gives the item in it, so the caller refuses. A list that is
        read and has no item of that name means that the path part is not there, and then nothing
        under it is there: no link.

        Commit 4 of the unit (text 5, Rick's "Yes" to the form of Cowork, 2026-10-07): the result names
        the cause, so that the caller gives the text of that cause. Cause Link: the item is a link.
        Cause NotRead: the item is in a folder whose list cannot be read, or the path is not under Root.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [string] $Root, [Parameter(Mandatory)] [string] $Path)

    $rootNorm = $Root.Replace('/', '\').TrimEnd('\')
    $pathNorm = $Path.Replace('/', '\').TrimEnd('\')
    if ($pathNorm -ine $rootNorm -and -not $pathNorm.StartsWith($rootNorm + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Item = $Path; Cause = 'NotRead' }
    }
    $parts = @($pathNorm.Substring($rootNorm.Length).Split('\') | Where-Object { $_ })
    $folder = Split-Path -Path $Root -Parent
    $name = Split-Path -Path $Root -Leaf
    $index = 0
    while ($true) {
        $item = Join-Path -Path $folder -ChildPath $name
        try { $entry = @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop | Where-Object { $_.Name -ieq $name }) }
        catch { return [pscustomobject]@{ Item = [string]$item; Cause = 'NotRead' } }
        if ($entry.Count -eq 0) { return $null }
        if ([string]$entry[0].Attributes -match '\bReparsePoint\b') { return [pscustomobject]@{ Item = [string]$item; Cause = 'Link' } }
        if ($index -ge $parts.Count) { return $null }
        $folder = $item
        $name = $parts[$index]
        $index++
    }
}
