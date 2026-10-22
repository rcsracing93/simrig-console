# Engine.Settings.ps1 - unit U3.7 (Phase 3): simrig.settings/1
#
# Pure functions only: no Get-Date, no Test-Path, no Get-Content, no $env:,
# no registry, no process calls. Every read (does the settings file exist,
# what is in it, is a folder reachable/writable, how much free space is left)
# is done by the caller (Discover/the console) and handed in as a parameter.
# That is what makes this testable on Linux with Pester (CONTRACT.md).
#
# Scope (job brief): spec 11a save paths (Session/Report/Bundle, the
# OneDrive-redirect default, the "Copy to" folder and its preflight, the
# "Copy now" action, the 5 GB Warns), and the settings-file shape of the
# spec 11b Tools card (which tools are on in simrig.settings/1 - the
# discovery/versioning of installed tools themselves is Engine.Software.ps1,
# unit U3.3, not this file). Contract shape: simrig.settings/1.
#
# Confidence vocabulary (CONTRACT.md, fixed six values): Read, Read
# (derived), Inferred, Warn, Manual, Unknown.

Set-StrictMode -Version 3.0

# ==========================================================================
# Constants (as functions - no top-level state; SimRig.Engine.ps1 allows
# function definitions only at top level once this file is folded in)
# ==========================================================================

function Get-SimRigSettingsCurrentSchemaVersion {
    <#
        .SYNOPSIS
        The schema version this build of the app writes and fully
        understands. simrig.settings/2 -> 2. Version 2 adds DisplayLayout: the
        layout the user confirmed, which a version-1 file does not have.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return 2
}

function Get-SimRigFreeSpaceWarnThresholdByteCount {
    <#
        .SYNOPSIS
        5 GB, the free-space-remaining floor below which the Tools card
        Warns (job brief: "Warn when free space drops under 5 GB"). Uses
        the binary GiB the way Windows' own free-space figures are reported
        (Get-Volume / volumes.csv, both binary), not a decimal GB.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param()
    return 5GB
}

function Get-SimRigSessionSizeWarnThresholdByteCount {
    <#
        .SYNOPSIS
        5 GB, the session-folder-total-size ceiling above which spec 11a
        says "the My PC screen shows a Warn with the size and an Open
        folder button." The app never deletes the session either way.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param()
    return 5GB
}

# ==========================================================================
# Save paths (spec 11a)
# ==========================================================================

function Join-SimRigSettingsPath {
    <#
        .SYNOPSIS
        String-only path join (no filesystem I/O - not Join-Path's cmdlet
        semantics, just concatenation with exactly one separator). Accepts
        either \ or / as the root's trailing separator and always emits \,
        since every real path in the fixtures is a Windows path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Child
    )
    $trimmedRoot = $Root.TrimEnd('\', '/')
    $trimmedChild = $Child.TrimStart('\', '/')
    return ('{0}\{1}' -f $trimmedRoot, $trimmedChild)
}

function Get-SimRigDefaultSessionRoot {
    <#
        .SYNOPSIS
        The default Session save-path root (spec 11a table): normally
        Documents\SimRig\Sessions\, or %USERPROFILE%\SimRig\Sessions\ when
        Documents is redirected to OneDrive ("OneDrive can sync large
        CapFrameX files, and v4 closes OneDrive for the session - a local
        folder avoids a sync burst at restore").

        .DESCRIPTION
        Returns the ROOT folder only - never the dated
        <yyyy-MM-dd_HHmm> session subfolder, because building that name
        needs the clock, and this file may not call Get-Date. The caller
        (which does own the clock) appends the timestamped subfolder when
        it actually saves a session.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $DocumentsPath,
        [Parameter(Mandatory)] [bool] $IsOneDriveRedirected,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $UserProfilePath
    )
    if ($IsOneDriveRedirected) {
        if ([string]::IsNullOrEmpty($UserProfilePath)) {
            return [pscustomobject]@{
                Value = $null; Confidence = 'Unknown'
                Reason = 'Documents is OneDrive-redirected but no %USERPROFILE% path was supplied'
            }
        }
        return [pscustomobject]@{
            Value = Join-SimRigSettingsPath -Root $UserProfilePath -Child 'SimRig\Sessions'
            Confidence = 'Inferred'
            Reason = 'Documents is OneDrive-redirected; spec 11a default moves off OneDrive to %USERPROFILE%\SimRig\Sessions\'
        }
    }
    if ([string]::IsNullOrEmpty($DocumentsPath)) {
        return [pscustomobject]@{
            Value = $null; Confidence = 'Unknown'
            Reason = 'no Documents path was supplied'
        }
    }
    return [pscustomobject]@{
        Value = Join-SimRigSettingsPath -Root $DocumentsPath -Child 'SimRig\Sessions'
        Confidence = 'Inferred'
        Reason = 'spec 11a default: Documents\SimRig\Sessions\'
    }
}

function Get-SimRigDefaultSavePath {
    <#
        .SYNOPSIS
        Builds the default SavePath.{Session,Report,Bundle} block for a
        first run / a field missing after migration (spec 11a).

        .DESCRIPTION
        Session gets the OneDrive-aware default above. Report and Bundle
        have no default of their own in spec 11a - the table only defines
        a Session default - so both default to $null, meaning "write next
        to the session" (the reading of "Save and share... Make support
        bundle (one zip)" as living inside the session folder unless the
        user sets an override). This is a judgement call - see NOTES.md.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $DocumentsPath,
        [Parameter(Mandatory)] [bool] $IsOneDriveRedirected,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $UserProfilePath
    )
    $session = Get-SimRigDefaultSessionRoot -DocumentsPath $DocumentsPath `
        -IsOneDriveRedirected $IsOneDriveRedirected -UserProfilePath $UserProfilePath
    return [pscustomobject]@{
        Session = $session
        Report  = [pscustomobject]@{
            Value = $null; Confidence = 'Inferred'
            Reason = 'spec 11a defines no separate Report default; $null means "use the session folder"'
        }
        Bundle  = [pscustomobject]@{
            Value = $null; Confidence = 'Inferred'
            Reason = 'spec 11a defines no separate Bundle default; $null means "use the session folder"'
        }
    }
}

function Set-SimRigSettingsDisplayLayout {
    <#
        .SYNOPSIS
        Records the layout the user confirmed, returning a new settings object.

        .DESCRIPTION
        The layout the app shows is an inference, and Get-SimRigDisplayLayout says so
        in its own Reason: Surround cannot be told apart from one wide monitor without
        the EDID count, and that count is not always readable. So the user is asked,
        and their answer is worth more than the inference - it is the only reading here
        that is not a guess.

        A layout outside the set throws rather than being written: a settings file
        holding a layout nothing grades against is worse than one holding none.

        Pure. It returns a new object; the caller writes the file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [ValidateSet('Single', 'Multi', 'Surround')] [string] $Layout,
        [Parameter(Mandatory)] [datetime] $ConfirmedAt
    )

    $out = [ordered]@{}
    foreach ($prop in $Settings.PSObject.Properties) { $out[$prop.Name] = $prop.Value }
    $out['DisplayLayout'] = [pscustomobject]@{
        Layout      = $Layout
        ConfirmedAt = Format-SimRigTime -Time $ConfirmedAt
    }
    return [pscustomobject]$out
}

function Get-SimRigEffectiveDisplayLayout {
    <#
        .SYNOPSIS
        The layout to grade against: what the user confirmed, or what discovery
        inferred.

        .DESCRIPTION
        A confirmed layout wins. It is the user telling the app about their own desk,
        and Confidence becomes 'Manual' - the vocabulary's word for a value a person
        supplied, which is exactly what it is.

        Where nothing is confirmed the discovered layout comes through unchanged,
        inference and all, so nothing here can turn a guess into a fact.

        Pure.

        .OUTPUTS
        [pscustomobject] Layout, Confidence, Source, Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] $Discovered,
        [AllowNull()] $Settings
    )

    $confirmed = Get-KnownGoodField -Entry $Settings -Name 'DisplayLayout'
    $confirmedLayout = [string](Get-KnownGoodField -Entry $confirmed -Name 'Layout')

    if (-not [string]::IsNullOrWhiteSpace($confirmedLayout)) {
        $at = [string](Get-KnownGoodField -Entry $confirmed -Name 'ConfirmedAt')
        return [pscustomobject]@{
            Layout     = $confirmedLayout
            Confidence = 'Manual'
            Source     = 'confirmed'
            Reason     = ('Confirmed by the user{0}.' -f $(if ($at) { ' on ' + $at } else { '' }))
        }
    }

    return [pscustomobject]@{
        Layout     = [string](Get-KnownGoodField -Entry $Discovered -Name 'Layout')
        Confidence = [string](Get-KnownGoodField -Entry $Discovered -Name 'Confidence')
        Source     = 'discovered'
        Reason     = [string](Get-KnownGoodField -Entry $Discovered -Name 'Reason')
    }
}

# ==========================================================================
# Copy-to preflight and Copy now (spec 11a)
# ==========================================================================

function Get-SimRigCopyToStatus {
    <#
        .SYNOPSIS
        Grades the optional "Copy to" folder (spec 11a: "Preflight checks
        the Copy to folder: reachable and writable. A failure is Warn,
        never Fail. The session still saves locally, and Save and share
        offers Copy now later.").

        .DESCRIPTION
        $Reachable/$Writable are readings the caller already took (UNC
        ping, a test-write); this function only grades them. With no
        "Copy to" path configured at all there is nothing to grade.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [string] $Path,
        [AllowNull()] [Nullable[bool]] $Reachable,
        [AllowNull()] [Nullable[bool]] $Writable
    )
    if ([string]::IsNullOrEmpty($Path)) {
        return [pscustomobject]@{
            Verdict = 'Ok'; Reason = 'no Copy to folder is configured'
        }
    }
    if ($Reachable -ne $true) {
        return [pscustomobject]@{
            Verdict = 'Warn'
            Reason = "Copy to folder '$Path' is not reachable. The session still saves locally; use Copy now once it is back."
        }
    }
    if ($Writable -ne $true) {
        return [pscustomobject]@{
            Verdict = 'Warn'
            Reason = "Copy to folder '$Path' is reachable but not writable. The session still saves locally; use Copy now once it is fixed."
        }
    }
    return [pscustomobject]@{ Verdict = 'Ok'; Reason = $null }
}

function Get-SimRigCopyNowPlan {
    <#
        .SYNOPSIS
        The "Copy now" action (spec 11a step-5 button, and the settings
        screen after a save-path change): decides which files still need
        copying from $SourcePath to $DestinationPath.

        .DESCRIPTION
        Pure diff: the caller lists what already exists at each end
        ($SourceFile / $DestinationFile, each RelativePath + Size). A file
        missing at the destination, or present with a different size, is
        queued to copy. A file already at the destination with a matching
        size is skipped - Copy now is safe to press twice.

        The app never deletes a session (spec 11a), so this plan never
        removes anything at the source, whether or not the save path just
        changed: files at an old path are left in place, not orphaned,
        because they still exist and Copy now can always be pressed again.
        (The job brief's "moves existing files when a path changes" is
        read as "does not orphan them", i.e. copies them forward, not as
        a literal delete-the-original move - see NOTES.md.)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $DestinationPath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $SourceFile,       # RelativePath, Size
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $DestinationFile   # RelativePath, Size
    )
    if ($SourcePath -eq $DestinationPath) {
        return [pscustomobject]@{ Action = @(); SkippedCount = 0; Note = 'source and destination are the same path; nothing to copy' }
    }
    $destByPath = @{}
    foreach ($d in $DestinationFile) { $destByPath[$d.RelativePath] = $d.Size }

    $skipped = 0
    $actionList = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $SourceFile) {
        $already = $destByPath.ContainsKey($s.RelativePath) -and $destByPath[$s.RelativePath] -eq $s.Size
        if ($already) {
            $skipped++
            continue
        }
        $actionList.Add([pscustomobject]@{
            RelativePath = $s.RelativePath
            SourcePath      = Join-SimRigSettingsPath -Root $SourcePath -Child $s.RelativePath
            DestinationPath = Join-SimRigSettingsPath -Root $DestinationPath -Child $s.RelativePath
            Reason = if ($destByPath.ContainsKey($s.RelativePath)) { 'exists at destination with a different size' } else { 'missing at destination' }
        })
    }
    return [pscustomobject]@{
        Action = $actionList.ToArray()
        SkippedCount = $skipped
        Note = 'source files are left in place; the app never deletes a session'
    }
}

# ==========================================================================
# 5 GB Warns (spec 11a and the job brief)
# ==========================================================================

function Get-SimRigFreeSpaceStatus {
    <#
        .SYNOPSIS
        Warn when the volume a save path lives on has less than 5 GB free
        (job brief). $FreeBytes is the caller's own volume-free-space
        reading (e.g. Get-Volume / the fixture's volumes.csv SizeRemaining
        column) - this function only grades the number.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [long] $FreeBytes,
        [long] $ThresholdBytes = (Get-SimRigFreeSpaceWarnThresholdByteCount)
    )
    if ($FreeBytes -lt 0) {
        return [pscustomobject]@{ Verdict = 'Unknown'; FreeBytes = $FreeBytes; ThresholdBytes = $ThresholdBytes
            Reason = 'free space reading is negative; treating as unreadable' }
    }
    if ($FreeBytes -lt $ThresholdBytes) {
        return [pscustomobject]@{
            Verdict = 'Warn'; FreeBytes = $FreeBytes; ThresholdBytes = $ThresholdBytes
            Reason = "only $FreeBytes bytes free, under the $ThresholdBytes byte floor"
        }
    }
    return [pscustomobject]@{ Verdict = 'Ok'; FreeBytes = $FreeBytes; ThresholdBytes = $ThresholdBytes; Reason = $null }
}

function Get-SimRigSessionSizeStatus {
    <#
        .SYNOPSIS
        Warn when a session folder's total size is over 5 GB (spec 11a:
        "the app never deletes a session. When the session folder is over
        5 GB, the My PC screen shows a Warn with the size and an Open
        folder button."). $TotalBytes is the caller's own folder-size sum.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [long] $TotalBytes,
        [long] $ThresholdBytes = (Get-SimRigSessionSizeWarnThresholdByteCount)
    )
    if ($TotalBytes -gt $ThresholdBytes) {
        return [pscustomobject]@{
            Verdict = 'Warn'; TotalBytes = $TotalBytes; ThresholdBytes = $ThresholdBytes
            Reason = "session folder is $TotalBytes bytes, over the $ThresholdBytes byte floor. The app never deletes it - use Open folder to clean up by hand."
        }
    }
    return [pscustomobject]@{ Verdict = 'Ok'; TotalBytes = $TotalBytes; ThresholdBytes = $ThresholdBytes; Reason = $null }
}

# ==========================================================================
# Load, validate, migrate (simrig.settings/1, flag 16)
# ==========================================================================

function Test-SimRigSettingsData {
    <#
        .SYNOPSIS
        Validates a normalized settings hashtable against simrig.settings/1
        shape. Returns string[] problems; empty means valid. Mirrors the
        Test-RuleData pattern (CONTRACT.md engine API).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [hashtable] $Data
    )
    $problems = [System.Collections.Generic.List[string]]::new()

    if (-not $Data.ContainsKey('Schema') -or [string]::IsNullOrEmpty($Data.Schema)) {
        $problems.Add('Schema is missing')
    }
    elseif ($Data.Schema -notmatch '^simrig\.settings/\d+$') {
        $problems.Add("Schema '$($Data.Schema)' is not simrig.settings/<n>")
    }

    if (-not $Data.ContainsKey('Version')) {
        $problems.Add('Version is missing')
    }
    elseif ($Data.Version -isnot [int] -or $Data.Version -lt 1) {
        $problems.Add('Version must be a positive integer')
    }

    if (-not $Data.ContainsKey('SavePath') -or $Data.SavePath -isnot [hashtable]) {
        $problems.Add('SavePath is missing or not an object')
    }
    else {
        if (-not $Data.SavePath.ContainsKey('Session') -or [string]::IsNullOrEmpty($Data.SavePath.Session)) {
            $problems.Add('SavePath.Session is missing (the session folder must always be set)')
        }
        foreach ($key in @('Report', 'Bundle')) {
            if ($Data.SavePath.ContainsKey($key)) {
                $v = $Data.SavePath[$key]
                if ($null -ne $v -and $v -isnot [string]) {
                    $problems.Add("SavePath.$key must be a string path or `$null")
                }
            }
        }
    }

    if ($Data.ContainsKey('ProfileId') -and $null -ne $Data.ProfileId -and $Data.ProfileId -isnot [string]) {
        $problems.Add('ProfileId must be a string or $null')
    }

    if ($Data.ContainsKey('UpdateCheck') -and $Data.UpdateCheck -isnot [bool]) {
        $problems.Add('UpdateCheck must be a boolean')
    }

    if ($Data.ContainsKey('Tools')) {
        if ($Data.Tools -isnot [hashtable]) {
            $problems.Add('Tools must be an object')
        }
        else {
            foreach ($toolKey in $Data.Tools.Keys) {
                if ($Data.Tools[$toolKey] -isnot [bool]) {
                    $problems.Add("Tools.$toolKey must be a boolean")
                }
            }
        }
    }

    return ,@($problems.ToArray())
}

function Repair-SimRigSettings {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Settings is the contract schema word (simrig.settings/1) and names the whole document. Repair-SimRigSetting would read as repairing one setting.')]
    <#
        .SYNOPSIS
        Loads, validates and migrates a raw settings hashtable into a clean
        simrig.settings/1 object, or refuses with a reason (CONTRACT.md
        flag 16: "a newer app reads an older settings file, or refuses
        with a reason. Never silently discard a field it does not
        recognize.").

        .DESCRIPTION
        $RawData is $null on first run (no settings file yet - Manual
        confidence everywhere, all values are the shipped defaults) or the
        hashtable the caller got back from parsing the JSON on disk
        (ConvertFrom-Json -AsHashtable, so nested objects are hashtables
        too, never PSCustomObjects - Set-StrictMode-safe key checks with
        ContainsKey).

        Every known field missing from $RawData is filled from
        $DefaultSavePath / $DefaultProfileId with Confidence 'Inferred' (a
        rule-computed default) or 'Manual' (nothing to compute from) and a
        Warning line. Every field present and readable is Confidence
        'Read'. Every top-level key this app version does not recognize is
        preserved verbatim under .Extra rather than dropped (flag 16).

        A settings file whose schema version is NEWER than this app
        understands is refused outright (Refused = $true) rather than
        guessed at, since silently trimming a newer shape back down could
        corrupt it if this older app then re-saves the file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [hashtable] $RawData,
        [Parameter(Mandatory)] [pscustomobject] $DefaultSavePath,   # Get-SimRigDefaultSavePath's return
        [AllowNull()] [string] $DefaultProfileId
    )
    $currentVersion = Get-SimRigSettingsCurrentSchemaVersion
    $warning = [System.Collections.Generic.List[string]]::new()
    $confidence = @{}

    # ---- first run: no settings file at all -----------------------------
    if ($null -eq $RawData) {
        $confidence.Schema = 'Manual'; $confidence.Version = 'Manual'
        $confidence.ProfileId = 'Manual'; $confidence.UpdateCheck = 'Manual'; $confidence.Tools = 'Manual'
        # Unknown, not Manual: on a first run nobody has confirmed a layout, and
        # Manual would claim a person answered.
        $confidence.DisplayLayout = 'Unknown'
        $confidence.SavePathSession = $DefaultSavePath.Session.Confidence
        $confidence.SavePathReport = $DefaultSavePath.Report.Confidence
        $confidence.SavePathBundle = $DefaultSavePath.Bundle.Confidence
        $warning.Add('no settings file found; using shipped defaults (first run)')
        return [pscustomobject]@{
            Refused = $false; RefusedReason = $null
            Settings = [pscustomobject]@{
                Schema = "simrig.settings/$currentVersion"
                Version = $currentVersion
                SavePath = [pscustomobject]@{
                    Session = $DefaultSavePath.Session.Value
                    Report  = $DefaultSavePath.Report.Value
                    Bundle  = $DefaultSavePath.Bundle.Value
                }
                ProfileId = $DefaultProfileId
                UpdateCheck = $true
                Tools = @{}
                DisplayLayout = $null
                Extra = @{}
            }
            FieldConfidence = $confidence
            Warning = $warning.ToArray()
        }
    }

    # ---- schema/version gate ---------------------------------------------
    $fileVersion = if ($RawData.ContainsKey('Version') -and $RawData.Version -is [int]) { $RawData.Version }
        elseif ($RawData.ContainsKey('Schema') -and $RawData.Schema -match '^simrig\.settings/(\d+)$') { [int]$Matches[1] }
        else { $null }

    if ($null -eq $fileVersion) {
        return [pscustomobject]@{
            Refused = $true
            RefusedReason = 'settings file has no readable Schema or Version; refusing rather than guessing at its shape'
            Settings = $null; FieldConfidence = @{}; Warning = @()
        }
    }
    if ($fileVersion -gt $currentVersion) {
        return [pscustomobject]@{
            Refused = $true
            RefusedReason = "settings file is schema version $fileVersion; this app understands up to $currentVersion. Refusing to load rather than risk corrupting a newer settings file."
            Settings = $null; FieldConfidence = @{}; Warning = @()
        }
    }
    if ($fileVersion -lt $currentVersion) {
        $warning.Add("settings file is schema version $fileVersion; migrating forward to $currentVersion")
        # No migration steps exist yet (only version 1 has ever shipped).
        # A version-2+ reader adds its step here, one 'if ($fileVersion -lt N)' block per step, applied in order.
    }

    # ---- known fields: Read when present, Inferred/Manual when filled ---
    $schema = if ($RawData.ContainsKey('Schema') -and -not [string]::IsNullOrEmpty($RawData.Schema)) {
        $confidence.Schema = 'Read'; $RawData.Schema
    } else {
        $confidence.Schema = 'Inferred'; $warning.Add('Schema missing; set from Version')
        "simrig.settings/$fileVersion"
    }
    $confidence.Version = 'Read'

    $rawSavePath = if ($RawData.ContainsKey('SavePath') -and $RawData.SavePath -is [hashtable]) { $RawData.SavePath } else { @{} }
    if (-not $RawData.ContainsKey('SavePath')) { $warning.Add('SavePath block missing entirely; using defaults') }

    $session = if ($rawSavePath.ContainsKey('Session') -and -not [string]::IsNullOrEmpty($rawSavePath.Session)) {
        $confidence.SavePathSession = 'Read'; $rawSavePath.Session
    } else {
        $confidence.SavePathSession = $DefaultSavePath.Session.Confidence
        $warning.Add('SavePath.Session missing; using the default session folder')
        $DefaultSavePath.Session.Value
    }
    $report = if ($rawSavePath.ContainsKey('Report')) {
        $confidence.SavePathReport = 'Read'; $rawSavePath.Report
    } else {
        $confidence.SavePathReport = $DefaultSavePath.Report.Confidence
        $DefaultSavePath.Report.Value
    }
    $bundle = if ($rawSavePath.ContainsKey('Bundle')) {
        $confidence.SavePathBundle = 'Read'; $rawSavePath.Bundle
    } else {
        $confidence.SavePathBundle = $DefaultSavePath.Bundle.Confidence
        $DefaultSavePath.Bundle.Value
    }
    # flag 16: an unrecognized key inside SavePath is kept, not dropped.
    $savePathExtra = @{}
    foreach ($k in $rawSavePath.Keys) {
        if (@('Session', 'Report', 'Bundle') -notcontains $k) {
            $savePathExtra[$k] = $rawSavePath[$k]
            $warning.Add("SavePath.$k is not understood by this app version; kept as-is")
        }
    }

    $profileId = if ($RawData.ContainsKey('ProfileId')) {
        $confidence.ProfileId = 'Read'; $RawData.ProfileId
    } else {
        $confidence.ProfileId = 'Manual'; $DefaultProfileId
    }
    $updateCheck = if ($RawData.ContainsKey('UpdateCheck') -and $RawData.UpdateCheck -is [bool]) {
        $confidence.UpdateCheck = 'Read'; $RawData.UpdateCheck
    } else {
        $confidence.UpdateCheck = 'Manual'; $warning.Add('UpdateCheck missing or invalid; defaulting to on')
        $true
    }
    $tools = if ($RawData.ContainsKey('Tools') -and $RawData.Tools -is [hashtable]) {
        $confidence.Tools = 'Read'; $RawData.Tools
    } else {
        $confidence.Tools = 'Manual'; @{}
    }

    # Version 2. The layout the user confirmed, and when. Absent is the normal case
    # and not a fault: it means nobody has confirmed anything yet, and the app goes on
    # using what discovery inferred. Confidence 'Unknown' rather than 'Manual' says
    # that plainly - Manual here would claim a person answered.
    $displayLayout = $null
    if ($RawData.ContainsKey('DisplayLayout') -and $RawData.DisplayLayout -is [hashtable] -and
        -not [string]::IsNullOrWhiteSpace([string]$RawData.DisplayLayout['Layout'])) {
        $confidence.DisplayLayout = 'Read'
        $displayLayout = [pscustomobject]@{
            Layout      = [string]$RawData.DisplayLayout['Layout']
            ConfirmedAt = [string]$RawData.DisplayLayout['ConfirmedAt']
        }
    }
    else {
        $confidence.DisplayLayout = 'Unknown'
        if ($fileVersion -lt 2) { $warning.Add('settings file predates DisplayLayout; the display layout stays as discovery infers it until it is confirmed') }
    }

    # flag 16: any top-level key this version does not recognize is kept.
    $known = @('Schema', 'Version', 'SavePath', 'ProfileId', 'UpdateCheck', 'Tools', 'DisplayLayout')
    $extra = @{}
    foreach ($k in $RawData.Keys) {
        if ($known -notcontains $k) {
            $extra[$k] = $RawData[$k]
            $warning.Add("top-level field '$k' is not understood by this app version; kept as-is")
        }
    }

    $settings = [pscustomobject]@{
        Schema = $schema
        Version = $currentVersion
        SavePath = [pscustomobject]@{ Session = $session; Report = $report; Bundle = $bundle; Extra = $savePathExtra }
        ProfileId = $profileId
        UpdateCheck = $updateCheck
        Tools = $tools
        DisplayLayout = $displayLayout
        Extra = $extra
    }
    return [pscustomobject]@{
        Refused = $false; RefusedReason = $null
        Settings = $settings
        FieldConfidence = $confidence
        Warning = $warning.ToArray()
    }
}
