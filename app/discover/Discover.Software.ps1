<#
    discover/Discover.Software.ps1 - SimRig Console v4.2, unit U3.3 (Phase 3, wave 3a)

    READ-ONLY reads of Windows state for the Software area of discovery:
    Windows build/edition/laptop, Game Mode, Game Bar version, the AMD
    chipset driver package version, the GPU driver version, the iRacing
    install and documents/ini directories and the live renderer ini,
    peripherals, overlays and other tuning tools, and the Tools card state
    (spec 11b). Every function here only reads; engine/Engine.Software.ps1
    (pure) does the classifying. Same rule as SimRig.Probe.ps1: no Set-*,
    Stop-*, Start-*, Enable-*, Disable-*, New-Item, Remove-*, sc.exe,
    reg.exe add/delete, schtasks /change.

    This runs unelevated, from the console (spec: "iRacing, CapFrameX and
    LatencyMon start only from the unelevated console, never from the
    [elevated] child" - OPUS-BUILD-BRIEF-v4.2 flag 4; FABLE-REVIEW question 4:
    "Game Bar version | Get-AppxPackage Microsoft.XboxGamingOverlay, in the
    unelevated console"). Flag 4's HKCU:/Get-AppxPackage ban is on
    SimRig.Actions.ps1, the elevated child, not on this file.

    Every function returns $null (or a record with $null fields) when a
    reading is not available, and never throws for a missing item - the same
    contract SimRig.Probe.ps1 uses.
#>

Set-StrictMode -Version 3.0

function Get-SoftwareBatteryPresence {
    <#
        .SYNOPSIS
        Whether a battery is present (Win32_Battery). Primary laptop signal
        (Engine's Test-SoftwareLaptop). Never throws: no CIM class, no
        instance and an access failure all mean "no battery found".
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $battery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
        return ($battery.Count -gt 0)
    }
    catch {
        Write-Verbose ("Get-SoftwareBatteryPresence: Win32_Battery read failed, treating as absent: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Get-SoftwareChassisType {
    <#
        .SYNOPSIS
        Win32_SystemEnclosure.ChassisTypes, the secondary laptop signal.
        Returns $null when the class or property cannot be read.
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param()
    try {
        $enclosure = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $enclosure -or $null -eq $enclosure.ChassisTypes) { return $null }
        return [int[]]$enclosure.ChassisTypes
    }
    catch {
        Write-Verbose ("Get-SoftwareChassisType: Win32_SystemEnclosure read failed: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-SoftwareOperatingSystem {
    <#
        .SYNOPSIS
        Windows build, UBR and edition. Build/Caption from Win32_OperatingSystem
        (FABLE-REVIEW question 4: "CPU model, cores, threads | Win32_Processor"
        sibling row "Windows | edition, build ... | registry, powercfg,
        NtQueryTimerResolution"). UBR from the registry, the standard extra
        digit Microsoft documents alongside BuildNumber
        (HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion, value UBR).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $build = $null; $edition = $null; $ubr = $null
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $os) {
            if ($os.BuildNumber) { $build = [int]$os.BuildNumber }
            $edition = [string]$os.Caption
        }
    }
    catch {
        Write-Verbose ("Get-SoftwareOperatingSystem: Win32_OperatingSystem read failed: {0}" -f $_.Exception.Message)
    }
    try {
        $ubrValue = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'UBR' -ErrorAction Stop
        if ($null -ne $ubrValue.UBR) { $ubr = [int]$ubrValue.UBR }
    }
    catch {
        Write-Verbose ("Get-SoftwareOperatingSystem: UBR registry read failed: {0}" -f $_.Exception.Message)
    }
    return [pscustomobject]@{ Build = $build; Ubr = $ubr; Edition = $edition }
}

function Get-SoftwareGameModeRaw {
    <#
        .SYNOPSIS
        The raw AutoGameModeEnabled reading, ValueExists + Value, for
        Engine's ConvertTo-GameModeState (absent means on - flag 6). Path and
        value name are the ones already shipped in quiet-list.psd1 and
        rules/windows.psd1 (rule W-GAMEMODE-AUTOMODE).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    try {
        $item = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -ErrorAction Stop
        return [pscustomobject]@{ ValueExists = $true; Value = [int]$item.AutoGameModeEnabled }
    }
    catch {
        Write-Verbose ("Get-SoftwareGameModeRaw: AutoGameModeEnabled absent or unreadable, Game Mode reads ON: {0}" -f $_.Exception.Message)
        return [pscustomobject]@{ ValueExists = $false; Value = $null }
    }
}

function Get-SoftwareGameBarVersion {
    <#
        .SYNOPSIS
        Xbox Game Bar package version (FABLE-REVIEW question 4: "Game Bar
        version | Get-AppxPackage Microsoft.XboxGamingOverlay, in the
        unelevated console | Read"). $null when the package is not installed
        or the read fails - never an error (some Windows installs, and every
        Windows Server image tier B runs on, have no Xbox apps at all).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        $pkg = Get-AppxPackage -Name 'Microsoft.XboxGamingOverlay' -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $pkg) { return $null }
        return [string]$pkg.Version
    }
    catch {
        Write-Verbose ("Get-SoftwareGameBarVersion: Get-AppxPackage failed, treating as not installed: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-SoftwareUninstallEntry {
    <#
        .SYNOPSIS
        Every DisplayName/DisplayVersion/Publisher row under the 32-bit and
        64-bit Uninstall registry hives, both HKLM and HKCU (a per-user
        install, e.g. some CapFrameX/OBS builds, only registers under HKCU).
        Read once and reused for the chipset driver lookup and the Tools-card
        lookup rather than querying per tool. Never throws: a hive that does
        not exist on this build (32-bit Windows has no Wow6432Node) yields no
        rows from that branch, not an error.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $rows = foreach ($p in $paths) {
        try {
            Get-ItemProperty -Path $p -ErrorAction Stop |
                Where-Object { $_.DisplayName } |
                Select-Object DisplayName, DisplayVersion, Publisher
        }
        catch {
            Write-Verbose ("Get-SoftwareUninstallEntry: '{0}' unreadable: {1}" -f $p, $_.Exception.Message)
        }
    }
    return ,@($rows)
}

function Get-SoftwareChipsetDriverVersion {
    <#
        .SYNOPSIS
        The AMD chipset driver package DisplayVersion from the Uninstall
        keys (FABLE-REVIEW question 4: "AMD chipset package | DisplayVersion
        in the Uninstall keys | Read"). $null when no matching entry exists.

        .NOTES
        UNCONFIRMED: the review names the source (Uninstall DisplayVersion)
        but not the exact DisplayName string AMD's installer registers, and
        no capture in this build's fixture set includes an Uninstall-key
        dump to confirm one. Matched here by a DisplayName that contains
        "AMD Chipset" (the commonly documented name of AMD's chipset
        software package) - see NOTES.md. A rig capture that confirms the
        exact string should replace this substring match.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $UninstallEntry
    )
    $match = $UninstallEntry | Where-Object { $_.DisplayName -and $_.DisplayName -match 'AMD Chipset' } | Select-Object -First 1
    if ($null -eq $match) { return $null }
    return [string]$match.DisplayVersion
}

function Get-GpuDriverVersionReading {
    <#
        .SYNOPSIS
        The NVIDIA display driver version from the PnP device property
        (FABLE-REVIEW question 4: "Driver versions | Get-PnpDeviceProperty
        DEVPKEY_Device_DriverVersion on the device. Avoid
        Win32_PnPSignedDriver (10-30 s) | Read"). Reads the first present
        Display-class NVIDIA instance; $null when none is present.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        $gpu = Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
            Where-Object { $_.InstanceId -match '^PCI\\VEN_10DE' } | Select-Object -First 1
        if ($null -eq $gpu) { return $null }
        $prop = Get-PnpDeviceProperty -InstanceId $gpu.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction Stop
        if ($null -eq $prop -or $null -eq $prop.Data) { return $null }
        return [string]$prop.Data
    }
    catch {
        Write-Verbose ("Get-GpuDriverVersionReading: PnP driver-version read failed: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-SoftwareIRacingPathCandidate {
    <#
        .SYNOPSIS
        Ordered install-directory candidates with an Exists flag, for
        Engine's Resolve-SoftwarePath. The reader does not assume a path
        (job brief); it checks the registry Uninstall entry first (the one
        iRacing's own installer writes), then the well-known default.

        .NOTES
        'C:\Program Files (x86)\iRacing' is confirmed by the
        2026-09-19_0838 capture (gpu-prefs.txt: the GPU-preference registry
        row names 'C:\Program Files (x86)\iRacing\iRacingSim64DX11.exe', and
        known-good.psd1's GpuPreference.Exe already ships the same path) -
        it is a fallback candidate here, checked with Test-Path like every
        other candidate, never assumed present.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $candidate = New-Object System.Collections.Generic.List[object]
    try {
        $entry = Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction Stop |
            Where-Object { $_.DisplayName -eq 'iRacing' } | Select-Object -First 1
        if ($null -ne $entry -and $entry.InstallLocation) {
            $candidate.Add([pscustomobject]@{ Path = $entry.InstallLocation; Exists = (Test-Path -LiteralPath $entry.InstallLocation); Source = 'registry Uninstall InstallLocation' })
        }
    }
    catch {
        Write-Verbose ("Get-SoftwareIRacingPathCandidate: Uninstall registry read failed: {0}" -f $_.Exception.Message)
    }
    $default = 'C:\Program Files (x86)\iRacing'
    $candidate.Add([pscustomobject]@{ Path = $default; Exists = (Test-Path -LiteralPath $default); Source = 'default install path' })
    return ,@($candidate.ToArray())
}

function Get-SoftwareIRacingDocumentsCandidate {
    <#
        .SYNOPSIS
        Ordered iRacing documents/ini-directory candidates with an Exists
        flag. Starts from the real Documents folder (the 'Personal' shell
        folder, expanded - this follows an OneDrive redirect automatically,
        which is how Rick's rig ends up under OneDrive), then also tries the
        plain, non-redirected Documents path, since a public PC will not
        have Rick's OneDrive redirect (job brief).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $candidate = New-Object System.Collections.Generic.List[object]
    $personal = $null
    try {
        $item = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Name 'Personal' -ErrorAction Stop
        if ($item.Personal) { $personal = [System.Environment]::ExpandEnvironmentVariables($item.Personal) }
    }
    catch {
        Write-Verbose ("Get-SoftwareIRacingDocumentsCandidate: 'Personal' shell folder read failed: {0}" -f $_.Exception.Message)
    }
    if ($personal) {
        $redirected = Join-Path -Path $personal -ChildPath 'iRacing'
        $candidate.Add([pscustomobject]@{ Path = $redirected; Exists = (Test-Path -LiteralPath $redirected); Source = 'User Shell Folders Personal (follows OneDrive redirect)' })
    }
    $plain = Join-Path -Path ([System.Environment]::GetFolderPath('MyDocuments')) -ChildPath 'iRacing'
    $candidate.Add([pscustomobject]@{ Path = $plain; Exists = (Test-Path -LiteralPath $plain); Source = '[Environment]::GetFolderPath(MyDocuments)' })
    return ,@($candidate.ToArray())
}

function Get-SoftwareIniLastWriteTime {
    <#
        .SYNOPSIS
        LastWriteTime of rendererDX11Monitor.ini and rendererDX11.ini in the
        resolved ini directory, for Engine's Resolve-IRacingLiveIni. Either
        or both may be $null when a file is absent.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $IniDir
    )
    $monitor = $null; $standard = $null
    $monitorPath = Join-Path -Path $IniDir -ChildPath 'rendererDX11Monitor.ini'
    $standardPath = Join-Path -Path $IniDir -ChildPath 'rendererDX11.ini'
    if (Test-Path -LiteralPath $monitorPath) {
        try { $monitor = (Get-Item -LiteralPath $monitorPath -ErrorAction Stop).LastWriteTime }
        catch { Write-Verbose ("Get-SoftwareIniLastWriteTime: rendererDX11Monitor.ini unreadable: {0}" -f $_.Exception.Message) }
    }
    if (Test-Path -LiteralPath $standardPath) {
        try { $standard = (Get-Item -LiteralPath $standardPath -ErrorAction Stop).LastWriteTime }
        catch { Write-Verbose ("Get-SoftwareIniLastWriteTime: rendererDX11.ini unreadable: {0}" -f $_.Exception.Message) }
    }
    return [pscustomobject]@{ MonitorWriteTime = $monitor; StandardWriteTime = $standard }
}

function Get-SoftwareRunningProcessName {
    <#
        .SYNOPSIS
        The running process name list (base name, no extension), for
        overlay detection and the 'my-apps' running list. List only - never
        used to touch a process (anti-cheat rule, OPUS-BUILD-BRIEF section 2:
        no access to the iRacing process).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    try {
        $names = Get-Process -ErrorAction Stop | Select-Object -ExpandProperty ProcessName -Unique
        return ,@($names)
    }
    catch {
        Write-Verbose ("Get-SoftwareRunningProcessName: Get-Process failed: {0}" -f $_.Exception.Message)
        return ,@()
    }
}

function Get-SoftwareUsbDevice {
    <#
        .SYNOPSIS
        Present USB PnP devices as VendorId/ProductId/Description, for
        Engine's Select-SoftwarePeripheral (presence only - see that
        function's NOTES on why no brand is guessed here).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    try {
        $devices = Get-PnpDevice -Class 'USB', 'HIDClass' -PresentOnly -ErrorAction Stop
        $rows = foreach ($d in $devices) {
            if ($d.InstanceId -match 'VID_(?<vid>[0-9A-Fa-f]{4})&PID_(?<pid>[0-9A-Fa-f]{4})') {
                [pscustomobject]@{ VendorId = $Matches.vid; ProductId = $Matches.pid; Description = [string]$d.FriendlyName }
            }
        }
        return ,@($rows)
    }
    catch {
        Write-Verbose ("Get-SoftwareUsbDevice: Get-PnpDevice failed: {0}" -f $_.Exception.Message)
        return ,@()
    }
}

function Get-SoftwareDetectedToolVersion {
    <#
        .SYNOPSIS
        Builds the Detected hashtable Engine's Get-SoftwareToolInventory
        needs (tool name -> version, or absent when not found), from the
        Uninstall entries and the running process list. A tool detected only
        by a running process (no Uninstall entry, e.g. a portable RTSS/OBS
        install) gets version $null - Installed, version Unknown, never
        Missing, since the process is real evidence of presence.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $UninstallEntry,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $RunningProcess
    )
    # Name -> (Uninstall DisplayName match pattern, process names to also check)
    $map = @{
        'CapFrameX'       = @{ NamePattern = 'CapFrameX'; Process = @('CapFrameX') }
        'LatencyMon'      = @{ NamePattern = 'LatencyMon'; Process = @('LatencyMon') }
        'OBS'             = @{ NamePattern = 'OBS Studio'; Process = @('obs64', 'obs32', 'obs') }
        'Process Lasso'   = @{ NamePattern = 'Process Lasso'; Process = @('ProcessLasso') }
        'MSI Afterburner' = @{ NamePattern = 'MSI Afterburner'; Process = @('MSIAfterburner') }
        'RTSS'            = @{ NamePattern = 'RivaTuner Statistics Server'; Process = @('RTSS') }
    }
    $detected = @{}
    foreach ($name in $map.Keys) {
        $entry = $UninstallEntry | Where-Object { $_.DisplayName -and $_.DisplayName -match [regex]::Escape($map[$name].NamePattern) } | Select-Object -First 1
        if ($null -ne $entry) {
            $detected[$name] = [string]$entry.DisplayVersion
            continue
        }
        $running = $false
        foreach ($p in $map[$name].Process) {
            if ($RunningProcess -icontains $p) { $running = $true; break }
        }
        if ($running) { $detected[$name] = $null }
    }
    return $detected
}
