<#
    engine/Engine.Software.ps1 - SimRig Console v4.2, unit U3.3 (Phase 3, wave 3a)

    PURE classification functions for the Software area of discovery: Windows
    build/edition/laptop, Game Mode, Game Bar version, chipset/GPU driver
    versions, iRacing paths and the live renderer ini, peripherals, overlays,
    other tuning tools and the Tools card (spec 11b). No clock, no filesystem,
    no registry, no processes, no $env: (CONTRACT.md coding rules). Every raw
    read is a parameter; discover/Discover.Software.ps1 is the only file that
    touches the real system.

    Sources for every fixed string and registry path used below are named on
    the function that uses them; see NOTES.md (_wip/U3.3) for what is
    confirmed by a real capture, what is Microsoft/AMD documentation, and
    what is recorded but unconfirmed (honesty rule, OPUS build brief).
#>
Set-StrictMode -Version 3.0

# ==========================================================================
# Windows: laptop, Game Mode, build/edition
# ==========================================================================

function Test-SoftwareLaptop {
    <#
        .SYNOPSIS
        True when the PC is a laptop (OPUS-BUILD-BRIEF-v4.2-2026-09-19.md
        section 2: Windows 10 and laptops run read-only).

        .DESCRIPTION
        Primary signal: a Win32_Battery instance is present (discovery method
        table, FABLE-REVIEW-v4.2-2026-09-19.md question 4: "Laptop |
        Win32_Battery, chassis type | Read"). Secondary signal: the chassis
        type reported by Win32_SystemEnclosure is one of the mobile codes
        defined by the DMTF SMBIOS System Enclosure Types table (Microsoft
        exposes the same codes on Win32_SystemEnclosure.ChassisTypes):
        8 Portable, 9 Laptop, 10 Notebook, 11 Hand Held, 14 Sub Notebook,
        30 Tablet, 31 Convertible, 32 Detachable.

        Either signal alone marks the machine a laptop: a laptop with its
        battery removed or reporting no battery instance still has a mobile
        chassis code, and a desktop tower never reports a battery. Chassis
        code 12 (Docking Station) is deliberately NOT treated as a laptop
        signal on its own - a docked laptop with the battery hidden behind
        the dock would still carry a mobile chassis code from the laptop
        itself, and treating "docked" as "laptop" would falsely mark some
        desktops with docking-style enclosures as laptops.

        .NOTES
        Cost of a false positive (a desktop misread as a laptop): every
        opt-in fix is refused and the app tells Rick's kind of user, wrongly,
        that persistent tuning is unavailable on their hardware - annoying,
        recoverable, never destructive.
        Cost of a false negative (a laptop misread as a desktop): the app
        offers writes (quiet list, persistent tuning) on hybrid-graphics,
        battery-plan hardware the spec explicitly keeps read-only (section 2)
        - this is the risk that matters, so both signals are OR'd rather than
        requiring agreement.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [bool] $HasBattery,
        [AllowNull()] [AllowEmptyCollection()] [int[]] $ChassisType
    )
    $mobileCodes = @(8, 9, 10, 11, 14, 30, 31, 32)
    if ($HasBattery) { return $true }
    if ($null -eq $ChassisType) { return $false }
    foreach ($code in $ChassisType) {
        if ($mobileCodes -contains $code) { return $true }
    }
    return $false
}

function ConvertTo-GameModeState {
    <#
        .SYNOPSIS
        Reads Game Mode the right way round (OPUS-BUILD-BRIEF-v4.2 flag 6,
        section 3 binding on this unit): the registry value is often absent,
        and absent means ON.

        .DESCRIPTION
        Source: HKCU:\Software\Microsoft\GameBar, value AutoGameModeEnabled.
        That path and value name are already shipped in quiet-list.psd1 (item
        "Game Mode AutoGameModeEnabled") and rules/windows.psd1 (rule
        W-GAMEMODE-AUTOMODE) - confirmed by existing code, not invented here.
        The pre-quiet VALUE at that key has no known-good capture yet
        (rules/windows.psd1 W-GAMEMODE-AUTOMODE: "Expected = $null ... no
        known-good capture", TODO 3b.5), so this function classifies whatever
        Discover reads; it does not assume a value.

        A value of 0 means the user turned Game Mode off in Settings. Any
        other present value, or no value at all, means Game Mode is on
        (Windows' own default-on behaviour).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [bool] $ValueExists,
        [AllowNull()] [Nullable[int]] $Value
    )
    if (-not $ValueExists) { return 'On' }
    if ($Value -eq 0) { return 'Off' }
    return 'On'
}

function Test-SoftwareDualCcdGameModeSafe {
    <#
        .SYNOPSIS
        Dual-CCD guard (OPUS-BUILD-BRIEF-v4.2 flag 6): Game Mode must stay ON
        on dual-CCD hardware, because AMD's CCD driver needs it. Returns
        $false only when Ccd is 2 and GameMode is 'Off' - the one combination
        the app must never produce and must always flag.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [int] $Ccd,
        [Parameter(Mandatory)] [ValidateSet('On', 'Off')] [string] $GameMode
    )
    if ($Ccd -eq 2 -and $GameMode -eq 'Off') { return $false }
    return $true
}

function Format-SoftwareWindowsBuild {
    <#
        .SYNOPSIS
        Win32_OperatingSystem BuildNumber plus the UBR (update build revision,
        HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\UBR) as one string,
        e.g. "26100.4652". UBR is $null-safe: a build with no UBR reading
        still returns the bare build number.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [int] $Build,
        [AllowNull()] [Nullable[int]] $Ubr
    )
    if ($null -eq $Ubr) { return [string]$Build }
    return ('{0}.{1}' -f $Build, $Ubr)
}

# ==========================================================================
# iRacing paths and the live renderer ini
# ==========================================================================

function Resolve-SoftwarePath {
    <#
        .SYNOPSIS
        Picks the first candidate path that exists, in the caller's order.
        Used for both the iRacing install directory and the documents/ini
        directory: on some PCs the ini directory sits under OneDrive
        (C:\Users\<name>\OneDrive\Equipment\iRacing - confirmed on the
        reference rig in the 2026-09-19_0838 capture session log), which most
        PCs will not have, so the reader tries a list of candidates rather
        than assuming one path (job brief).

        .DESCRIPTION
        Pure: Discover does every Test-Path/Exists check and hands the
        results here as a list. This function does no filesystem I/O itself.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Candidate,   # Path, Exists, Source
        [Parameter(Mandatory)] [string] $FieldName
    )
    foreach ($c in $Candidate) {
        if ($c.Exists) {
            return [pscustomobject]@{
                Field = $FieldName; Value = [string]$c.Path; Source = [string]$c.Source
                Confidence = 'Read'
            }
        }
    }
    return [pscustomobject]@{
        Field = $FieldName; Value = $null; Source = $null; Confidence = 'Unknown'
    }
}

function Resolve-IRacingLiveIni {
    <#
        .SYNOPSIS
        Chooses which renderer ini iRacing is actually using -
        rendererDX11Monitor.ini or rendererDX11.ini (discovery method table,
        FABLE-REVIEW question 4, R-D5: "which file iRacing uses depends on
        its display mode - Inferred").

        .DESCRIPTION
        iRacing keeps one renderer ini per display mode and only the active
        one is written when in-sim graphics settings change, so the file
        with the newer LastWriteTime is the one iRacing is reading from. That
        is a file-system fact (Inferred, not Read: nothing in the registry or
        an ini key states which file is live - confirmed absent from every
        fixture in 2026-09-19_0838 and known-good-2026-09-19_0857; grep found
        no "renderer"/"displayMode" selector key in app.ini or core.ini).

        Falls back to the confirmed display layout (from U3.2's discovery)
        only when both files are missing a reliable timestamp (for example a
        fresh OneDrive sync that touches both files at once): Surround or
        triple counts as Monitor mode, everything else as single-file mode.
        With neither signal, the result is Unknown and the caller must ask.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [Nullable[datetime]] $MonitorWriteTime,
        [AllowNull()] [Nullable[datetime]] $StandardWriteTime,
        [AllowNull()] [Nullable[bool]] $SurroundConfirmed
    )
    if ($null -ne $MonitorWriteTime -and $null -ne $StandardWriteTime) {
        if ($MonitorWriteTime -eq $StandardWriteTime) {
            # Tied timestamps (e.g. a bulk OneDrive sync) carry no signal - fall through.
        }
        elseif ($MonitorWriteTime -gt $StandardWriteTime) {
            return [pscustomobject]@{ File = 'rendererDX11Monitor.ini'; Confidence = 'Inferred'
                Reason = 'newer LastWriteTime than rendererDX11.ini' }
        }
        else {
            return [pscustomobject]@{ File = 'rendererDX11.ini'; Confidence = 'Inferred'
                Reason = 'newer LastWriteTime than rendererDX11Monitor.ini' }
        }
    }
    elseif ($null -ne $MonitorWriteTime) {
        return [pscustomobject]@{ File = 'rendererDX11Monitor.ini'; Confidence = 'Inferred'
            Reason = 'only file with a LastWriteTime reading' }
    }
    elseif ($null -ne $StandardWriteTime) {
        return [pscustomobject]@{ File = 'rendererDX11.ini'; Confidence = 'Inferred'
            Reason = 'only file with a LastWriteTime reading' }
    }
    if ($null -ne $SurroundConfirmed) {
        if ($SurroundConfirmed) {
            return [pscustomobject]@{ File = 'rendererDX11Monitor.ini'; Confidence = 'Inferred'
                Reason = 'no LastWriteTime signal; confirmed Surround/triple display layout' }
        }
        return [pscustomobject]@{ File = 'rendererDX11.ini'; Confidence = 'Inferred'
            Reason = 'no LastWriteTime signal; confirmed single/non-Surround display layout' }
    }
    return [pscustomobject]@{ File = $null; Confidence = 'Unknown'
        Reason = 'no LastWriteTime signal and no confirmed display layout' }
}

# ==========================================================================
# Tools card (spec 11b), other tuning tools (G-17), overlays, peripherals
# ==========================================================================

function Compare-SoftwareVersion {
    <#
        .SYNOPSIS
        True when $Found is at least $Minimum. Both are dotted-numeric
        version strings ("1.2.3"); a $Found that does not parse as a
        [version] returns $false with no throw (an unparsable version string
        is a real, if odd, discovery reading, never a script error).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Found,
        [Parameter(Mandatory)] [string] $Minimum
    )
    try {
        $foundVersion = [version]$Found
        $minVersion = [version]$Minimum
    }
    catch {
        Write-Verbose ("Compare-SoftwareVersion: unparsable version, treating as below minimum: {0}" -f $_.Exception.Message)
        return $false
    }
    return ($foundVersion -ge $minVersion)
}

function Get-SoftwareToolState {
    <#
        .SYNOPSIS
        One Tools-card row (spec 11b: "For each tool, it shows the state
        (installed and its version, missing, or too old)"). $Present is
        separate from $DetectedVersion so a tool found only by a running
        process (no Uninstall entry to read a version from - a portable
        install) still grades Installed, with an unknown version, and never
        Missing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Level,          # Required | Recommended | Optional | Advanced | Checked | Other
        [Parameter(Mandatory)] [bool] $Present,
        [AllowNull()] [string] $DetectedVersion,
        [AllowNull()] [string] $MinVersion,
        [AllowNull()] [string] $WingetId
    )
    if (-not $Present) {
        return [pscustomobject]@{
            Name = $Name; Level = $Level; State = 'Missing'; Version = $null
            WingetId = $WingetId
        }
    }
    if ([string]::IsNullOrEmpty($DetectedVersion)) {
        return [pscustomobject]@{
            Name = $Name; Level = $Level; State = 'Installed'; Version = $null
            WingetId = $WingetId
        }
    }
    if (-not [string]::IsNullOrEmpty($MinVersion) -and -not (Compare-SoftwareVersion -Found $DetectedVersion -Minimum $MinVersion)) {
        return [pscustomobject]@{
            Name = $Name; Level = $Level; State = 'TooOld'; Version = $DetectedVersion
            WingetId = $WingetId
        }
    }
    return [pscustomobject]@{
        Name = $Name; Level = $Level; State = 'Installed'; Version = $DetectedVersion
        WingetId = $WingetId
    }
}

function Get-SoftwareToolInventory {
    <#
        .SYNOPSIS
        Builds every Tools-card row (spec 11b) from a fixed tool list and
        whatever Discover found running/installed. Returns ,@(rows).

        .DESCRIPTION
        Tool set and winget ids are the ones spec 11b names for the app's own
        prerequisites and recommended tools (PowerShell, .NET Desktop
        Runtime, CapFrameX, LatencyMon), plus the "other tuning tools" the
        G-17 audit (V4.2-SPEC-2026-09-19.md section 6a) requires discovery to
        find and name so the report can warn about them: OBS, Process Lasso,
        MSI Afterburner, RTSS. Process Lasso is the one of these five
        confirmed present by a real capture (2026-09-19_0838 tasks-state.csv:
        "Process Lasso Core Engine Only", "Process Lasso Management Console
        (GUI)", "Session agent for Process Lasso", all Running) - see
        NOTES.md for which of the others are unconfirmed by any capture in
        this fixture set.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [hashtable] $Detected   # tool name -> version string, or $null/absent if not found
    )
    $tools = @(
        [pscustomobject]@{ Name = 'CapFrameX'; Level = 'Recommended'; MinVersion = $null; WingetId = 'CXWorld.CapFrameX' }
        [pscustomobject]@{ Name = 'LatencyMon'; Level = 'Optional'; MinVersion = $null; WingetId = 'Resplendence.LatencyMon' }
        [pscustomobject]@{ Name = 'OBS'; Level = 'Other'; MinVersion = $null; WingetId = $null }
        [pscustomobject]@{ Name = 'Process Lasso'; Level = 'Other'; MinVersion = $null; WingetId = $null }
        [pscustomobject]@{ Name = 'MSI Afterburner'; Level = 'Other'; MinVersion = $null; WingetId = $null }
        [pscustomobject]@{ Name = 'RTSS'; Level = 'Other'; MinVersion = $null; WingetId = $null }
    )
    $rows = foreach ($t in $tools) {
        $present = $Detected.ContainsKey($t.Name)
        $version = if ($present) { $Detected[$t.Name] } else { $null }
        Get-SoftwareToolState -Name $t.Name -Level $t.Level -Present $present -DetectedVersion $version -MinVersion $t.MinVersion -WingetId $t.WingetId
    }
    return ,@($rows)
}

function ConvertTo-ToolViewRow {
    <#
        .SYNOPSIS
        One Tools-card screen row per tool (A-TOOL-01 for the state, A-TOOL-02 for
        the Install button): Name, Detail, Value, and the button's label, tag and
        visibility.

        .DESCRIPTION
        The Install button appears only where Get-ToolInstallRequest says it can
        do something, and its Tag carries the winget id that the click handler
        passes straight to winget. One decision, made once, in a pure function:
        the alternative is a button handler that decides for itself, and a handler
        cannot be tested on Linux.

        Level tells the user why a tool is listed. The 'Other' tools are the ones
        the G-17 audit makes discovery find and name so the report can warn about
        them - this app never installs those, and the row says so rather than
        showing a button that would.

        Pure.

        .OUTPUTS
        [object[]] Name, Detail, Value, InstallLabel, InstallAutomationName,
        Source, InstallVisibility.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Tool)

    $detailByLevel = @{
        Required    = 'needed to run this app'
        Recommended = 'recommended: it measures the frametimes this app scores'
        Optional    = 'optional'
        Advanced    = 'advanced'
        Checked     = 'checked only'
        Other       = 'found on this PC - this app reports it, and never changes or installs it'
    }

    $rows = foreach ($t in @($Tool | Where-Object { $null -ne $_ })) {
        $state = [string](Get-KnownGoodField -Entry $t -Name 'State')
        $version = Get-KnownGoodField -Entry $t -Name 'Version'
        $level = [string](Get-KnownGoodField -Entry $t -Name 'Level')
        $value = switch ($state) {
            'Missing' { 'not installed' }
            'TooOld' { if ($version) { 'installed, version {0} - below the version this app needs' -f $version } else { 'installed, too old' } }
            default { if ($version) { 'installed, version {0}' -f $version } else { 'installed, version unknown' } }
        }
        $request = Get-ToolInstallRequest -Row $t
        [pscustomobject]@{
            Name                  = [string](Get-KnownGoodField -Entry $t -Name 'Name')
            Detail                = $(if ($detailByLevel.ContainsKey($level)) { $detailByLevel[$level] } else { $level })
            Value                 = $value
            InstallLabel          = $(if ($request.CanInstall) { if ($state -eq 'TooOld') { 'Update' } else { 'Install' } } else { $null })
            InstallAutomationName = $(if ($request.CanInstall) { '{0} {1}' -f $(if ($state -eq 'TooOld') { 'Update' } else { 'Install' }), (Get-KnownGoodField -Entry $t -Name 'Name') } else { $null })
            Source                = $request.PackageId
            InstallVisibility     = $(if ($request.CanInstall) { 'Visible' } else { 'Collapsed' })
        }
    }

    $rows = @($rows)
    if ($rows.Count -eq 0) { return @() }
    return , @($rows)
}

function Select-SoftwareOverlay {
    <#
        .SYNOPSIS
        The list-only running-overlay reading (CONTRACT.md Facts shape,
        Overlay = list of names). Discovery method table: "Background |
        overlays and utilities running ... | process list, list only".
        Returns ,@(names) in $RunningProcess order, matched case-insensitively.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $RunningProcess,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $KnownOverlay
    )
    # Not $matches: that is the automatic variable any regex operation
    # overwrites. Nothing here uses a regex today, which is exactly why this
    # would have sat quietly until someone added one.
    $found = foreach ($p in $RunningProcess) {
        if ($KnownOverlay -icontains $p) { $p }
    }
    return ,@($found)
}

function Select-SoftwarePeripheral {
    <#
        .SYNOPSIS
        Matches present USB devices against a known VID/PID -> label map
        (discovery method table: "Peripherals | USB VID/PID in PnP | Read
        (presence); model Inferred"). Returns ,@(rows): Vid, Pid, Label
        (Inferred) or $null (Unknown, presence only).

        .NOTES
        No VID/PID has been confirmed by a capture in this fixture set for
        any wheel base, pedal set or shifter brand (Simagic, Fanatec, Moza,
        Simucube, VRS, Thrustmaster, Logitech, Heusinkveld - the brand list
        the discovery table names). $KnownDevice is empty until a real or
        vendor-documented VID/PID is confirmed; every device is then Unknown
        (presence only) rather than a guessed label. See NOTES.md.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $UsbDevice,   # VendorId, ProductId, Description
        [Parameter(Mandatory)] [AllowNull()] [hashtable] $KnownDevice           # "VID:PID" -> label
    )
    $rows = foreach ($d in $UsbDevice) {
        $key = '{0}:{1}' -f $d.VendorId, $d.ProductId
        if ($null -ne $KnownDevice -and $KnownDevice.ContainsKey($key)) {
            [pscustomobject]@{ VendorId = $d.VendorId; ProductId = $d.ProductId; Description = $d.Description
                Label = $KnownDevice[$key]; Confidence = 'Inferred' }
        }
        else {
            [pscustomobject]@{ VendorId = $d.VendorId; ProductId = $d.ProductId; Description = $d.Description
                Label = $null; Confidence = 'Unknown' }
        }
    }
    return ,@($rows)
}

function Get-SoftwareOtherToolWarning {
    <#
        .SYNOPSIS
        G-17 (V4.2-SPEC-2026-09-19.md section 6a): "no other tuning tool on
        the PC" was a v4.0 assumption for other users. v4.2 default: discovery
        lists them and warns. Filters a Tools-card row set (from
        Get-SoftwareToolInventory) down to the 'Other' rows that are Installed
        or TooOld - the ones worth naming in the report - and returns ,@(rows).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ToolRow
    )
    $warn = foreach ($r in $ToolRow) {
        if ($r.Level -eq 'Other' -and $r.State -in @('Installed', 'TooOld')) { $r }
    }
    return ,@($warn)
}

# ==========================================================================
# machine-profile assembly (CONTRACT.md simrig.machine-profile/1, Windows + IRacing blocks)
# ==========================================================================

function Build-SoftwareMachineProfile {
    <#
        .SYNOPSIS
        Assembles the Windows and IRacing blocks of simrig.machine-profile/1
        (CONTRACT.md) from already-classified Software fields. Pure: every
        input is a value this file's other functions (or Discover) already
        produced.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()] [string] $Build,
        [AllowNull()] [string] $Edition,
        [Parameter(Mandatory)] [bool] $Laptop,
        [AllowNull()] [string] $GameMode,
        [AllowNull()] [string] $GameBarVersion,
        [AllowNull()] [string] $InstallDir,
        [AllowNull()] [string] $IniDir
    )
    return @{
        Windows = @{
            Build = $Build; Edition = $Edition; Laptop = $Laptop
            GameMode = $GameMode; GameBarVersion = $GameBarVersion
        }
        IRacing = @{
            InstallDir = $InstallDir; IniDir = $IniDir
        }
    }
}

function Find-SoftwareOtherTool {
    <#
        .SYNOPSIS
        G-17 (V4.2-SPEC-2026-09-19.md section 6a): matches a list of observed
        names (process names AND/OR scheduled-task display names - a real
        capture of a tool can appear as either, e.g. Process Lasso registers
        scheduled tasks named "Process Lasso Core Engine Only" rather than a
        plain process name match) against a map of tool name -> substring
        pattern. Returns ,@(matched tool names), case-insensitive substring
        match (a display name commonly carries a suffix, so exact match is
        too strict - confirmed by the 2026-09-19_0838 tasks-state.csv rows
        for Process Lasso, none of which equal the bare string "Process
        Lasso").
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Name,
        [Parameter(Mandatory)] [hashtable] $Pattern   # tool name -> substring to match, case-insensitive
    )
    $found = foreach ($toolName in $Pattern.Keys) {
        $needle = [string]$Pattern[$toolName]
        $hit = $false
        foreach ($n in $Name) {
            if ($n -and $n.ToLowerInvariant().Contains($needle.ToLowerInvariant())) { $hit = $true; break }
        }
        if ($hit) { $toolName }
    }
    return ,@($found)
}

function Get-SimRigIniDirChoice {
    <#
        .SYNOPSIS
        Which iRacing ini folder the console uses, where it came from, and whether
        the two sources disagree.

        .DESCRIPTION
        Two sources, and they answer different questions. The profile holds a path
        somebody wrote down; discovery reads the folder the machine reports today.

        The profile wins. It is the value a person checked, and a discovery reader
        that picks the wrong candidate would silently grade the wrong file - the rig
        holds two renderer inis, and only one of them is live.

        But a written-down path goes stale the moment the folder moves, and then the
        app grades a file nobody edits any more and reports everything as a match.
        So when both sources answer and they differ, that is recorded as a mismatch
        with a sentence naming both. Nothing is changed by it: the caller logs it,
        and a human decides which one is wrong.

        No source at all is a normal state, not an error - a PC with no iRacing
        install. Source is 'None' and the caller reads no ini files.

        Pure.

        .OUTPUTS
        [pscustomobject] Path, Source (Profile|Discovered|None), Mismatch, Note.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $FromProfile,
        [AllowNull()] [AllowEmptyString()] [string] $Discovered
    )

    $profilePath = if ([string]::IsNullOrWhiteSpace($FromProfile)) { $null } else { $FromProfile.Trim() }
    $foundPath = if ([string]::IsNullOrWhiteSpace($Discovered)) { $null } else { $Discovered.Trim() }

    # Same folder written two ways is not a disagreement: Windows paths are
    # case-insensitive and a trailing separator means nothing.
    $same = $false
    if ($null -ne $profilePath -and $null -ne $foundPath) {
        $same = ($profilePath.TrimEnd('\', '/') -ieq $foundPath.TrimEnd('\', '/'))
    }

    if ($null -ne $profilePath -and $null -ne $foundPath -and -not $same) {
        return [pscustomobject]@{
            Path = $profilePath; Source = 'Profile'; Mismatch = $true
            Note = ("The profile says {0}; discovery found {1}. The profile wins. If the folder moved, update the profile - the app is grading the file at the first path." -f $profilePath, $foundPath)
        }
    }

    if ($null -ne $profilePath) {
        $note = if ($same) { 'The profile and discovery agree.' } else { 'From the profile; discovery found nothing to compare.' }
        return [pscustomobject]@{ Path = $profilePath; Source = 'Profile'; Mismatch = $false; Note = $note }
    }

    if ($null -ne $foundPath) {
        return [pscustomobject]@{ Path = $foundPath; Source = 'Discovered'; Mismatch = $false; Note = 'Found on this PC; no profile value.' }
    }

    return [pscustomobject]@{
        Path = $null; Source = 'None'; Mismatch = $false
        Note = 'No iRacing ini folder was found and none is set, so the ini settings are not graded.'
    }
}
