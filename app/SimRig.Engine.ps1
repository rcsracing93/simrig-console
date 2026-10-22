<#
    SimRig.Engine.ps1 - SimRig Console v4.0 engine

    PURE functions only: parsers, snapshot diff, quiet and restore plans,
    preflight grading, the "Windows healthy" verdict, the watch-event
    classifier, the report builder, the bundle integrity gate, the elevation
    result contract and the screen text. No clock, no filesystem, no registry,
    no processes, no environment: every input is a parameter. That is what
    lets all of it be tested with Pester on Linux against the real rig
    captures.

    Sections (built as separate parts, folded into this one file at
    integration on 2026-09-19):
      Data       quiet-list / known-good validation, ids, time format, paths
      Parsers    sc qc, sc query, schtasks XML, 7040/7036, TaskScheduler, ini, VERSIONS.md
      Preflight  read-back grading (flags 5 and 6)
      Report     v4-report.json schema (flag 8) and the bundle integrity gate (TODO 2.5b)
      State      snapshot, quiet/restore plans, verdict (flags 2 and 3), watch events, LatencyMon validator
      Result     the elevated child's result contract and exit codes (flag 4)
      ViewModel  rows, banners and text the console shows
#>
Set-StrictMode -Version 3.0

# ==========================================================================
# Data
# ==========================================================================

# Engine.Data.ps1 - SimRig Console v4.0 (subagent 1)
# Pure functions only: no Get-Date, no filesystem, no registry, no $env:.
# Concatenated into SimRig.Engine.ps1 at integration - no top-level code here
# except function definitions (CONTRACT.md).

function Format-SimRigTime {
    <#
        .SYNOPSIS
        Formats a DateTime as the ISO-8601 string every timestamp leaving the
        Engine must use: yyyy-MM-ddTHH:mm:ss plus a zzz offset when the
        DateTime's Kind is Local or Utc, and no offset when Unspecified.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [datetime]$Time
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $stamp = $Time.ToString('yyyy-MM-ddTHH:mm:ss', $culture)
    switch ($Time.Kind) {
        'Local' { return $stamp + $Time.ToString('zzz', $culture) }
        'Utc'   { return $stamp + $Time.ToString('zzz', $culture) }
        default { return $stamp }
    }
}

function Get-QuietItemId {
    <#
        .SYNOPSIS
        Builds a quiet item's unique Id from its Kind (CONTRACT.md "Item
        identity"):
          Service  -> Service:<Name>
          Task     -> Task:<Path><Name>
          Registry -> Registry:<Path>\<Value>
          Defender -> Defender:<Name>
          Process  -> Process:<Name>
        Accepts a hashtable (raw psd1 item) or a pscustomobject (a converted
        item, or an ItemState record).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $Item
    )

    $kind = $Item.Kind
    switch ($kind) {
        'Service'  { return "Service:{0}" -f $Item.Name }
        'Task'     { return "Task:{0}{1}" -f $Item.Path, $Item.Name }
        'Registry' { return "Registry:{0}\{1}" -f $Item.Path, $Item.Value }
        'Defender' { return "Defender:{0}" -f $Item.Name }
        'Process'  { return "Process:{0}" -f $Item.Name }
        default    { throw "Get-QuietItemId: unrecognised Kind '$kind'" }
    }
}

function Test-QuietListData {
    <#
        .SYNOPSIS
        Validates a raw quiet-list.psd1 hashtable (as Import-PowerShellDataFile
        returns it) against the simrig.quiet-list/1 schema. Returns an array
        of error strings - empty means valid. Never throws on bad data; that
        is the point of the function.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Data
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    $validKinds = @('Service', 'Task', 'Registry', 'Defender', 'Process')
    $validActionsByKind = @{
        Service  = @('Disable', 'Stop')
        Task     = @('Disable')
        Registry = @('Set')
        Defender = @('Off')
        Process  = @('Close')
    }

    if (-not $Data.ContainsKey('Schema') -or $Data['Schema'] -ne 'simrig.quiet-list/1') {
        $errors.Add("Schema must be 'simrig.quiet-list/1'")
    }

    if (-not $Data.ContainsKey('Items') -or -not $Data['Items'] -or @($Data['Items']).Count -eq 0) {
        $errors.Add('Items is required and must be a non-empty array')
        return , $errors.ToArray()
    }

    $seenIds = @{}
    $itemIndex = 0
    foreach ($raw in @($Data['Items'])) {
        $itemIndex++

        if ($raw -isnot [hashtable]) {
            $errors.Add("Items[$itemIndex]: item must be a hashtable")
            continue
        }

        $kind = $raw['Kind']
        if ([string]::IsNullOrEmpty($kind) -or $kind -notin $validKinds) {
            $errors.Add("Items[$itemIndex]: Kind '$kind' is not valid - must be one of $($validKinds -join ', ')")
            continue
        }

        $label = "Items[$itemIndex] ($kind, $($raw['Name'])$($raw['Path']))"

        if ([string]::IsNullOrWhiteSpace([string]$raw['Reason'])) {
            $errors.Add("$label`: Reason is required")
        }
        if ([string]::IsNullOrWhiteSpace([string]$raw['Evidence'])) {
            $errors.Add("$label`: Evidence is required")
        }

        if (-not $raw.ContainsKey('Order')) {
            $errors.Add("$label`: Order is required")
        } elseif ($raw['Order'] -isnot [int]) {
            $errors.Add("$label`: Order must be an integer")
        }

        $action = $raw['Action']
        $validActions = $validActionsByKind[$kind]
        if ([string]::IsNullOrEmpty($action) -or $action -notin $validActions) {
            $errors.Add("$label`: Action '$action' is not valid for Kind '$kind' - must be one of $($validActions -join ', ')")
        }

        if ($raw.ContainsKey('Absent') -and $kind -ne 'Registry') {
            $errors.Add("$label`: Absent is only valid for Kind 'Registry'")
        }

        try {
            $id = Get-QuietItemId -Item $raw
            if ($seenIds.ContainsKey($id)) {
                $errors.Add("$label`: duplicate Id '$id'")
            } else {
                $seenIds[$id] = $true
            }
        } catch {
            $errors.Add("$label`: could not compute Id - $($_.Exception.Message)")
        }
    }

    return , $errors.ToArray()
}

function ConvertTo-QuietItem {
    <#
        .SYNOPSIS
        Converts a validated quiet-list.psd1 hashtable into the pscustomobject
        array the rest of the engine works with, sorted ascending by Order.
        Verdict defaults to 'Required' for every Kind except Process, which
        defaults to 'None'. Task items also carry Uri = Path + Name.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Data
    )

    $converted = foreach ($raw in @($Data['Items'])) {
        $kind = $raw['Kind']

        $verdict = if ($raw.ContainsKey('Verdict')) {
            $raw['Verdict']
        } elseif ($kind -eq 'Process') {
            'None'
        } else {
            'Required'
        }

        $uri = if ($kind -eq 'Task') { "{0}{1}" -f $raw['Path'], $raw['Name'] } else { $null }

        [pscustomobject]@{
            Id        = Get-QuietItemId -Item $raw
            Kind      = $kind
            Name      = $raw['Name']
            Path      = $raw['Path']
            Value     = $raw['Value']
            Data      = $raw['Data']
            RegType   = $raw['RegType']
            Order     = $raw['Order']
            Group     = $raw['Group']
            Action    = $raw['Action']
            Absent    = $raw['Absent']
            Reason    = $raw['Reason']
            Evidence  = $raw['Evidence']
            RestoreTo = $raw['RestoreTo']
            Fallback  = $raw['Fallback']
            Verdict   = $verdict
            Uri       = $uri
            # Carried through, not dropped. Unit U3.8 put AppliesTo on nine items
            # and the conversion discarded it, so every one of them was inert in
            # the real Quiet action - see Select-QuietItemForMachine.
            AppliesTo = $(if ($raw.Contains('AppliesTo')) { $raw['AppliesTo'] } else { $null })
        }
    }

    return , @($converted | Sort-Object -Property Order)
}

# --------------------------------------------------------------------------
# Schema version tolerance (flag 16) and the one place that turns an error into
# something a person can act on.
#
# Flag 16 asks that every snapshot, marker and result file carry a schema version,
# and that a newer app either restores an older one or refuses with a reason. The
# refusal matters more than the acceptance: a snapshot is the only record of the
# machine's prior state, so an app that reads a shape it does not understand and
# restores anyway is worse than one that stops and says so.
#
# These live here rather than in a part file because SimRig.Share.ps1 and
# SimRig.Actions.ps1 both need them and neither loads the other's parts.
# --------------------------------------------------------------------------

function Get-SimRigSchemaVerdict {
    <#
        .SYNOPSIS
        Whether this app can use a document it just read: Ok, Note (older, still
        readable) or Refuse, with a sentence saying why.

        .DESCRIPTION
        A schema id is '<name>/<version>' - 'simrig.snapshot/1'. The decision:

        - same name, same version: Ok.
        - same name, older version listed in -AlsoRead: Note. The caller carries
          on and the note travels with the result, because a restore from an older
          snapshot is a fact worth recording rather than a silent success.
        - same name, older version not listed: Refuse. Being older is not by itself
          a promise that this app understands it.
        - newer version: Refuse. A newer file was written by a newer app, and
          guessing at a shape from the future is how a restore puts back the wrong
          value.
        - a different name, a missing version, or no schema at all: Refuse. A file
          with no version is a file from before versions, and there is no way to
          tell which.

        Refusals name both versions, because the sentence is what the user sees and
        'schema mismatch' tells them nothing they can act on.

        .OUTPUTS
        [pscustomobject] Ok, Verdict (Ok|Note|Refuse), Found, Expected, Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [string] $Found,
        [Parameter(Mandatory)] [string] $Expected,
        [AllowNull()] [AllowEmptyCollection()] [string[]] $AlsoRead = @()
    )

    $expectedName, $expectedVersion = ([string]$Expected -split '/', 2)

    if ([string]::IsNullOrWhiteSpace($Found)) {
        return [pscustomobject]@{
            Ok = $false; Verdict = 'Refuse'; Found = $null; Expected = $Expected
            Reason = ("This file carries no schema version, so there is no way to tell what wrote it. {0} was expected." -f $Expected)
        }
    }

    if ($Found -eq $Expected) {
        return [pscustomobject]@{ Ok = $true; Verdict = 'Ok'; Found = $Found; Expected = $Expected; Reason = $null }
    }

    $foundName, $foundVersion = ([string]$Found -split '/', 2)

    if ($foundName -ne $expectedName) {
        return [pscustomobject]@{
            Ok = $false; Verdict = 'Refuse'; Found = $Found; Expected = $Expected
            Reason = ("This is a {0} file, not a {1} file." -f $foundName, $expectedName)
        }
    }

    if (@($AlsoRead) -contains $Found) {
        return [pscustomobject]@{
            Ok = $true; Verdict = 'Note'; Found = $Found; Expected = $Expected
            Reason = ("Written by an older version of this app ({0}); read as {1}." -f $Found, $Expected)
        }
    }

    $foundNumber = 0
    $expectedNumber = 0
    $foundParsed = [int]::TryParse([string]$foundVersion, [ref] $foundNumber)
    $expectedParsed = [int]::TryParse([string]$expectedVersion, [ref] $expectedNumber)

    if ($foundParsed -and $expectedParsed -and $foundNumber -gt $expectedNumber) {
        return [pscustomobject]@{
            Ok = $false; Verdict = 'Refuse'; Found = $Found; Expected = $Expected
            Reason = ("This file was written by a newer version of this app ({0}); this one reads {1}. Update the app rather than letting it guess." -f $Found, $Expected)
        }
    }

    return [pscustomobject]@{
        Ok = $false; Verdict = 'Refuse'; Found = $Found; Expected = $Expected
        Reason = ("This app does not read {0}; it reads {1}." -f $Found, $Expected)
    }
}

function Get-SimRigErrorMessage {
    <#
        .SYNOPSIS
        What the window shows when something fails: a sentence, a line for the log,
        and which recovery buttons belong on screen (flag 16, spec 16).

        .DESCRIPTION
        No stack trace reaches the screen. A trace tells a user nothing and it can
        carry a path, a user name or a value from the failure - so it goes to the
        log, where it is useful, and the screen gets a sentence.

        The recovery offer is the point of this function rather than a nicety.
        Where a session is still quiet, the machine is in a changed state and the
        user needs Restore; where tuning has been applied, they need Undo. Those
        are the two states this app can leave a machine in, and a failure is
        exactly when they are hardest to find.

        Pure: the caller reads the two files and passes what it found.

        .OUTPUTS
        [pscustomobject] Title, Text, LogLine, OfferRestore, OfferUndo.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $What,
        [AllowNull()] [string] $Message,
        [AllowNull()] [string] $Detail,
        [AllowNull()] [object] $Line,
        [bool] $SessionOpen = $false,
        [bool] $TuningApplied = $false
    )

    $plain = if ([string]::IsNullOrWhiteSpace($Message)) { 'No message was reported.' } else { [string]$Message }

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($plain)
    if ($SessionOpen) {
        $parts.Add('Windows is still in its session state. Restore puts it back from this session snapshot.')
    }
    if ($TuningApplied) {
        # Text 54 of PUSH2-TEXTS-FOR-RICK-2026-10-03.md (Rick's "Yes").
        $parts.Add('Undo tuning puts back the values that Apply tuning wrote.')
    }
    if (-not $SessionOpen -and -not $TuningApplied) {
        $parts.Add('Nothing on this PC was left changed.')
    }

    $logLine = ('{0}: {1}{2}{3}' -f $What, $plain,
        $(if ($null -ne $Line -and [string]$Line -ne '') { ' (line {0})' -f $Line } else { '' }),
        $(if (-not [string]::IsNullOrWhiteSpace($Detail)) { " | " + ([string]$Detail -replace '\s+', ' ') } else { '' }))

    return [pscustomobject]@{
        Title        = ('{0} failed' -f $What)
        Text         = ($parts -join ' ')
        LogLine      = $logLine
        OfferRestore = $SessionOpen
        OfferUndo    = $TuningApplied
    }
}

function Test-KnownGoodData {
    <#
        .SYNOPSIS
        Validates a raw known-good.psd1 hashtable against the
        simrig.known-good/1 schema. Returns an array of error strings - empty
        means valid.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Data
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    if (-not $Data.ContainsKey('Schema') -or $Data['Schema'] -ne 'simrig.known-good/1') {
        $errors.Add("Schema must be 'simrig.known-good/1'")
    }

    $requiredKeys = @(
        'GpuSteering', 'Registry', 'PowerScheme', 'TimerResolution',
        'Services', 'Tasks', 'Ini', 'FreeSpace', 'GpuPreference', 'Backblaze', 'Manual'
    )
    foreach ($key in $requiredKeys) {
        if (-not $Data.ContainsKey($key)) {
            $errors.Add("Missing required key '$key'")
        }
    }

    if ($Data.ContainsKey('GpuSteering') -and $Data['GpuSteering'] -is [hashtable]) {
        $gpuSteering = $Data['GpuSteering']
        foreach ($key in @('VendorId', 'ExpectedInstanceCount', 'Default')) {
            if (-not $gpuSteering.ContainsKey($key)) {
                $errors.Add("GpuSteering missing required key '$key'")
            }
        }
    } elseif ($Data.ContainsKey('GpuSteering')) {
        $errors.Add('GpuSteering must be a hashtable')
    }

    if ($Data.ContainsKey('Services') -and $Data['Services'] -isnot [hashtable]) {
        $errors.Add('Services must be a hashtable keyed by service Name')
    }
    if ($Data.ContainsKey('Tasks') -and $Data['Tasks'] -isnot [hashtable]) {
        $errors.Add('Tasks must be a hashtable keyed by task Path+Name')
    }
    if ($Data.ContainsKey('Ini') -and $Data['Ini'] -isnot [array] -and $Data['Ini'] -isnot [object[]]) {
        $errors.Add('Ini must be an array')
    }

    # Preference is optional (v4.1). When it is there it is validated here, so
    # one call still answers "is this data file usable".
    if ($Data.ContainsKey('Preference')) {
        $prefErrors = Test-PreferenceData -Data $Data['Preference']
        foreach ($e in @($prefErrors)) { if ($e) { $errors.Add($e) } }
    }

    return , $errors.ToArray()
}

function Get-SimRigPath {
    <#
        .SYNOPSIS
        Builds the rig's session file paths from a root directory. Pure:
        joins strings with '\' only (never Join-Path, which uses the host
        platform's separator - this engine's paths are always Windows paths,
        even when the tests run this on Linux).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    $root = $Root.TrimEnd('\')
    $scripts = "$root\Scripts\v4"
    $logs = "$root\Logs\v4"
    $results = "$logs\results"
    $sessions = "$logs\sessions"
    $activeMarker = "$logs\active-session.json"
    # The settings file lives at the install root, not under Logs: it survives an
    # upgrade and it is the user's, not a log.
    $settings = "$root\settings.json"
    $consoleLogPattern = "$logs\console_{0}.log"
    # One line per console start, for the steering question (U4.25). A history,
    # so it is append-only and it outlives any one session folder.
    $steeringHistory = "$logs\steering-history.jsonl"
    # Push 2 of the unit tune, step 5: the record of the tuning that is applied, beside the
    # session marker (design section 5). It names the snapshot of record.
    $tuningMarker = "$logs\tuning-applied.json"
    # Step 6: the copy of UNDO-BY-HAND.txt beside the marker, so that text 52 is true also when the
    # marker cannot be read (the Cowork note of 2026-10-04, point 1).
    $tuningUndoByHand = "$logs\UNDO-BY-HAND.txt"

    [pscustomobject]@{
        Root              = $root
        Scripts           = $scripts
        Logs              = $logs
        Results           = $results
        Sessions          = $sessions
        ActiveMarker      = $activeMarker
        Settings          = $settings
        ConsoleLogPattern = $consoleLogPattern
        SteeringHistory   = $steeringHistory
        TuningMarker      = $tuningMarker
        TuningUndoByHand  = $tuningUndoByHand
    }
}

# ==========================================================================
# Parsers
# ==========================================================================

# Engine.Parsers.ps1 - SimRig Console v4.0
#
# Pure text/record parsers. No Get-Date, no filesystem, no registry, no
# $env:, no processes. Every token below comes from the real rig captures
# under /home/claude/fixtures (see CONTRACT.md and the subagent-2 report for
# exactly which lines proved which token).
#
# This file is dot-sourced together with the other engine\Engine.*.ps1 parts
# by SimRig.Engine.ps1 - it does not set Set-StrictMode itself and it does
# NOT define Format-SimRigTime (that lives in Engine.Data.ps1, another
# subagent's file), even though two functions below call it.

function Get-SimRigEventValue {
    <#
        Private helper. Reads one named value off an event record that may
        be a Hashtable (tests) or a PSCustomObject (Import-Csv / Get-WinEvent
        selection). Missing property -> $null, never a strict-mode error.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        $Record,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains($Name)) { return $Record[$Name] }
        return $null
    }

    $prop = $Record.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-SimRigEventTime {
    <#
        Private helper. TimeCreated may already be a [datetime] (live
        Get-WinEvent) or the fixture string form '9/19/2026 8:36:17 AM'
        (en-US, InvariantCulture). A bare 24h string 'M/d/yyyy H:mm:ss' is
        tolerated too. Never throws on a value it cannot parse - it returns
        $null so the caller can skip the event instead of failing the batch.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        $TimeCreated
    )

    if ($null -eq $TimeCreated) { return $null }
    if ($TimeCreated -is [datetime]) { return $TimeCreated }

    $formats = @('M/d/yyyy h:mm:ss tt', 'M/d/yyyy H:mm:ss')
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::None
    $parsed = [datetime]::MinValue
    foreach ($fmt in $formats) {
        if ([datetime]::TryParseExact([string]$TimeCreated, $fmt, $culture, $styles, [ref]$parsed)) {
            return $parsed
        }
    }
    return $null
}

function ConvertFrom-ScQc {
    <#
        Parses the output of `sc.exe qc <name>` as captured by the rig
        script, one block per service, wrapped by the capture script in
        "=== <Name> ===" header lines (every block in both 2026-09-19_0838
        and known-good-2026-09-19_0857 has one, including the first).
        Text carries a UTF-8 BOM and CRLF line endings; both are tolerated.

        A missing service (TabletInputService in both fixtures) prints
        "[SC] OpenService FAILED 1060:" instead of a SERVICE_NAME block -
        that block comes back Exists=$false, StartType=$null,
        DisplayName=$null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    if ([string]::IsNullOrEmpty($Text)) { return , @($results.ToArray()) }

    $normalized = $Text.TrimStart([char]0xFEFF) -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = $normalized -split "`n"

    $headerPattern = '^===\s*(?<name>.+?)\s*===\s*$'
    $startTypePattern = 'START_TYPE\s*:\s*\d+\s+(?<token>\S+)(?<delayed>\s+\(DELAYED\))?'
    $displayNamePattern = 'DISPLAY_NAME\s*:\s*(?<value>.*)$'

    $current = $null
    foreach ($line in $lines) {
        $headerMatch = [regex]::Match($line, $headerPattern)
        if ($headerMatch.Success) {
            if ($current) { $results.Add([pscustomobject]$current) }
            $current = [ordered]@{
                Name        = $headerMatch.Groups['name'].Value
                StartType   = $null
                DisplayName = $null
                Exists      = $false
            }
            continue
        }
        if (-not $current) { continue }

        if ($line -match 'SERVICE_NAME\s*:') {
            $current.Exists = $true
            continue
        }

        $startTypeMatch = [regex]::Match($line, $startTypePattern)
        if ($startTypeMatch.Success) {
            $token = $startTypeMatch.Groups['token'].Value
            $delayed = $startTypeMatch.Groups['delayed'].Success
            $current.StartType = switch ($token) {
                'AUTO_START' { if ($delayed) { 'AutomaticDelayed' } else { 'Automatic' } }
                'DEMAND_START' { 'Manual' }
                'DISABLED' { 'Disabled' }
                'BOOT_START' { 'Boot' }
                'SYSTEM_START' { 'System' }
                default { $token }
            }
            continue
        }

        $displayNameMatch = [regex]::Match($line, $displayNamePattern)
        if ($displayNameMatch.Success) {
            $current.DisplayName = $displayNameMatch.Groups['value'].Value.TrimEnd()
        }
    }
    if ($current) { $results.Add([pscustomobject]$current) }

    return , @($results.ToArray())
}

function ConvertFrom-ScQuery {
    <#
        Parses the output of `sc.exe query <name>`, one block per service.
        Unlike sc qc, this capture has no "=== Name ===" wrapper (see
        fixtures/2026-09-19_0838/sc-query.txt) so a failed lookup
        ("[SC] EnumQueryServicesStatus:OpenService FAILED 1060:") cannot be
        attributed to a name from the text alone - it comes back with
        Name=$null, State=$null, Exists=$false, in stream order.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    if ([string]::IsNullOrEmpty($Text)) { return , @($results.ToArray()) }

    $normalized = $Text.TrimStart([char]0xFEFF) -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = $normalized -split "`n"

    $namePattern = '^SERVICE_NAME\s*:\s*(?<name>\S+)'
    $statePattern = 'STATE\s*:\s*\d+\s+(?<token>\S+)'
    $failedPattern = '\[SC\].*OpenService FAILED\s+\d+'

    $current = $null
    foreach ($line in $lines) {
        if ($line -match $failedPattern) {
            if ($current) { $results.Add([pscustomobject]$current) }
            $current = $null
            $results.Add([pscustomobject][ordered]@{ Name = $null; State = $null; Exists = $false })
            continue
        }

        $nameMatch = [regex]::Match($line, $namePattern)
        if ($nameMatch.Success) {
            if ($current) { $results.Add([pscustomobject]$current) }
            $current = [ordered]@{
                Name   = $nameMatch.Groups['name'].Value
                State  = $null
                Exists = $true
            }
            continue
        }
        if (-not $current) { continue }

        $stateMatch = [regex]::Match($line, $statePattern)
        if ($stateMatch.Success) {
            $token = $stateMatch.Groups['token'].Value
            $current.State = switch ($token) {
                'RUNNING' { 'Running' }
                'STOPPED' { 'Stopped' }
                'START_PENDING' { 'StartPending' }
                'STOP_PENDING' { 'StopPending' }
                'PAUSED' { 'Paused' }
                default { 'Unknown' }
            }
        }
    }
    if ($current) { $results.Add([pscustomobject]$current) }

    return , @($results.ToArray())
}

function ConvertFrom-SchtasksXml {
    <#
        schtasks-all.xml is not one XML document - it is many <Task>
        documents (each its own xmlns) concatenated under a <Tasks> wrapper,
        each preceded by a "<!-- \Uri -->" comment, with blank lines between
        and a UTF-8 BOM / CRLF at the top of the stream. This pulls each
        <Task>...</Task> fragment out with its preceding comment and parses
        it as its own namespace-aware XML document.

        Enabled lives at Task/Settings/Enabled; a Task can also carry a
        per-trigger Enabled (e.g. Triggers/LogonTrigger/Enabled) at deeper
        indentation - only the Settings one is the task's own state, so this
        is read by an explicit namespace-aware path, never a text scan.
        Absent Settings/Enabled means the task is enabled (confirmed against
        \D3DGearRawFrameCaptureTask in the fixture, which has a <Settings>
        block with no <Enabled> at all).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    if ([string]::IsNullOrEmpty($Text)) { return , @($results.ToArray()) }

    $normalized = $Text.TrimStart([char]0xFEFF) -replace "`r`n", "`n" -replace "`r", "`n"

    $taskPattern = '(?s)(?:<!--\s*(?<comment>.*?)\s*-->\s*)?<Task\b(?<attrs>[^>]*)>(?<body>.*?)</Task>'
    $taskMatches = [regex]::Matches($normalized, $taskPattern)

    foreach ($taskMatch in $taskMatches) {
        $fragment = '<Task' + $taskMatch.Groups['attrs'].Value + '>' + $taskMatch.Groups['body'].Value + '</Task>'
        try {
            $xmlDoc = [xml]$fragment
        } catch {
            throw "ConvertFrom-SchtasksXml: could not parse a <Task> fragment as XML: $($_.Exception.Message)"
        }

        $nsManager = [System.Xml.XmlNamespaceManager]::new($xmlDoc.NameTable)
        $nsUri = $xmlDoc.DocumentElement.NamespaceURI
        $prefix = ''
        if ($nsUri) {
            $nsManager.AddNamespace('t', $nsUri)
            $prefix = 't:'
        }

        $uriNode = $xmlDoc.SelectSingleNode("/${prefix}Task/${prefix}RegistrationInfo/${prefix}URI", $nsManager)
        $uri = $null
        if ($uriNode) {
            $uri = $uriNode.InnerText.Trim()
        } elseif ($taskMatch.Groups['comment'].Success -and $taskMatch.Groups['comment'].Value) {
            $uri = $taskMatch.Groups['comment'].Value.Trim()
        }

        $enabledNode = $xmlDoc.SelectSingleNode("/${prefix}Task/${prefix}Settings/${prefix}Enabled", $nsManager)
        $enabled = $true
        if ($enabledNode) {
            $enabledText = $enabledNode.InnerText.Trim()
            $parsedBool = $false
            if ([bool]::TryParse($enabledText, [ref]$parsedBool)) { $enabled = $parsedBool }
        }

        $path = $null
        $name = $null
        if ($uri) {
            $lastSlash = $uri.LastIndexOf('\')
            if ($lastSlash -ge 0) {
                $path = $uri.Substring(0, $lastSlash + 1)
                $name = $uri.Substring($lastSlash + 1)
            } else {
                $path = '\'
                $name = $uri
            }
        }

        $results.Add([pscustomobject][ordered]@{
            Uri     = $uri
            Path    = $path
            Name    = $name
            Enabled = $enabled
        })
    }

    return , @($results.ToArray())
}

function ConvertFrom-ServiceControlEvent {
    <#
        Turns System log 7040/7036 event records into watch-ready rows.
        -Event is an array of records shaped {TimeCreated; Id; Message} -
        Hashtable or PSCustomObject, e.g. an Import-Csv row.

        7040: "The start type of the <DisplayName> service was changed from
        <x> to <y>." Only 'auto start', 'demand start' and 'disabled' are
        fixture-backed tokens (system-services-session2.csv,
        system-7040-7036.csv); 'boot start'/'system start' are handled from
        the documented SCM vocabulary but are NOT fixture-backed.

        7036: "The <DisplayName> service entered the <state> state." Some
        rows (provider VfpExt) have an empty DisplayName - "The  service
        entered the Driver load complete state." - those come back with
        ServiceName $null and State exactly as printed; they never throw.

        DisplayNameMap lookups are case-insensitive; an unmapped display
        name comes back with ServiceName $null and DisplayName kept.
        A message that matches neither shape is skipped, not thrown.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'Param name -Event is fixed by CONTRACT.md Engine API (ConvertFrom-ServiceControlEvent -Event ...); other subagents'' code and tests build against this exact name.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Event,

        [Parameter(Mandatory)]
        [hashtable]$DisplayNameMap
    )

    $caseInsensitiveMap = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $DisplayNameMap.Keys) {
        $caseInsensitiveMap[[string]$key] = [string]$DisplayNameMap[$key]
    }

    $startTypePattern = '^The start type of the (?<display>.+) service was changed from (?<from>[a-z ]+) to (?<to>[a-z ]+)\.$'
    $statePattern = '^The (?<display>.*) service entered the (?<state>.+) state\.$'

    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($record in $Event) {
        $message = [string](Get-SimRigEventValue -Record $record -Name 'Message')
        $timeRaw = Get-SimRigEventValue -Record $record -Name 'TimeCreated'
        $eventId = Get-SimRigEventValue -Record $record -Name 'Id'
        $time = Get-SimRigEventTime -TimeCreated $timeRaw
        if ($null -eq $time) { continue }

        $startTypeMatch = [regex]::Match($message, $startTypePattern)
        if ($startTypeMatch.Success) {
            $display = $startTypeMatch.Groups['display'].Value
            $serviceName = $null
            if ($caseInsensitiveMap.ContainsKey($display)) { $serviceName = $caseInsensitiveMap[$display] }
            $results.Add([pscustomobject][ordered]@{
                Time        = Format-SimRigTime -Time $time
                EventId     = $eventId
                Kind        = 'StartTypeChange'
                ServiceName = $serviceName
                DisplayName = $display
                From        = ConvertTo-SimRigStartTypeWord -Word $startTypeMatch.Groups['from'].Value
                To          = ConvertTo-SimRigStartTypeWord -Word $startTypeMatch.Groups['to'].Value
                State       = $null
            })
            continue
        }

        $stateMatch = [regex]::Match($message, $statePattern)
        if ($stateMatch.Success) {
            $display = $stateMatch.Groups['display'].Value
            $serviceName = $null
            if ($display -and $caseInsensitiveMap.ContainsKey($display)) { $serviceName = $caseInsensitiveMap[$display] }
            $rawState = $stateMatch.Groups['state'].Value
            $state = switch ($rawState.ToLowerInvariant()) {
                'running' { 'Running' }
                'stopped' { 'Stopped' }
                default { $rawState }
            }
            $results.Add([pscustomobject][ordered]@{
                Time        = Format-SimRigTime -Time $time
                EventId     = $eventId
                Kind        = 'StateChange'
                ServiceName = $serviceName
                DisplayName = $display
                From        = $null
                To          = $null
                State       = $state
            })
            continue
        }
        # Message shape not recognised (neither 7040 nor 7036 form) - skip,
        # never throw: a bad or foreign event must not fail the whole batch.
    }

    return , @($results.ToArray())
}

function ConvertTo-SimRigStartTypeWord {
    <#
        Private helper. Maps the lowercase SCM wording used inside 7040
        messages to the CONTRACT start-type vocabulary. 'auto start',
        'demand start' and 'disabled' are fixture-backed (every 7040 row in
        system-7040-7036.csv and system-services-session2.csv uses one of
        these three). 'boot start' / 'system start' follow the documented
        SCM wording but are NOT fixture-backed - no capture here shows a
        boot- or system-start driver flip.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Word
    )

    switch ($Word.Trim()) {
        'auto start' { return 'Automatic' }
        'demand start' { return 'Manual' }
        'disabled' { return 'Disabled' }
        'boot start' { return 'Boot' }
        'system start' { return 'System' }
        default { return $Word.Trim() }
    }
}

function ConvertFrom-TaskSchedulerEvent {
    <#
        Turns Microsoft-Windows-TaskScheduler/Operational event records into
        watch-ready rows. -Event is an array of records shaped
        {TimeCreated; Id; Message}.

        Event id -> Kind, confirmed against tasksched-operational.csv,
        tasksched-session2.csv and tasksched-after-race.csv:
          100 Started, 129 Launched, 200 ActionStarted, 201 ActionCompleted,
          102 Completed, 140 Updated, 322 LaunchIgnored.
        106 (Registered) and 141 (Deleted) are in the CONTRACT vocabulary
        but do not appear in any fixture - handled from the documented
        message shape, NOT fixture-backed. Ids 107 and 119 (both seen firing
        for "Schedule Work" and other tasks in tasksched-session2.csv) are
        not in the CONTRACT's named list and come back as Other, with
        TaskUri still pulled from the message when a "\...." path is present.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'Param name -Event is fixed by CONTRACT.md Engine API (ConvertFrom-TaskSchedulerEvent -Event ...); other subagents'' code and tests build against this exact name.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Event
    )

    $patterns = @{
        100 = @{ Kind = 'Started'; Regex = 'Task Scheduler started "(?<inst>[^"]+)" instance of the "(?<uri>[^"]+)" task' }
        129 = @{ Kind = 'Launched'; Regex = 'Task Scheduler launch task "(?<uri>[^"]+)"\s*,\s*instance "(?<inst>[^"]+)"' }
        200 = @{ Kind = 'ActionStarted'; Regex = 'Task Scheduler launched action "(?<action>[^"]+)" in instance "(?<inst>[^"]+)" of task "(?<uri>[^"]+)"' }
        201 = @{ Kind = 'ActionCompleted'; Regex = 'Task Scheduler successfully completed task "(?<uri>[^"]+)"\s*,\s*instance "(?<inst>[^"]+)"\s*,\s*action "(?<action>[^"]+)"' }
        102 = @{ Kind = 'Completed'; Regex = 'Task Scheduler successfully finished "(?<inst>[^"]+)" instance of the "(?<uri>[^"]+)" task' }
        140 = @{ Kind = 'Updated'; Regex = 'updated Task Scheduler task "(?<uri>[^"]+)"' }
        322 = @{ Kind = 'LaunchIgnored'; Regex = 'Task Scheduler did not launch task "(?<uri>[^"]+)"\s*because instance "(?<inst>[^"]+)"' }
        106 = @{ Kind = 'Registered'; Regex = 'Task Scheduler registered task "(?<uri>[^"]+)"' }
        141 = @{ Kind = 'Deleted'; Regex = 'Task Scheduler deleted task "(?<uri>[^"]+)"' }
    }
    $fallbackUriPattern = '"(?<uri>\\[^"]+)"'

    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($record in $Event) {
        $message = [string](Get-SimRigEventValue -Record $record -Name 'Message')
        $timeRaw = Get-SimRigEventValue -Record $record -Name 'TimeCreated'
        $eventIdRaw = Get-SimRigEventValue -Record $record -Name 'Id'
        $time = Get-SimRigEventTime -TimeCreated $timeRaw
        if ($null -eq $time) { continue }

        $eventId = 0
        $hasId = [int]::TryParse([string]$eventIdRaw, [ref]$eventId)

        $kind = 'Other'
        $uri = $null
        $inst = $null
        $action = $null

        if ($hasId -and $patterns.ContainsKey($eventId)) {
            $spec = $patterns[$eventId]
            $match = [regex]::Match($message, $spec.Regex)
            if ($match.Success) {
                $kind = $spec.Kind
                if ($match.Groups['uri'].Success) { $uri = $match.Groups['uri'].Value }
                if ($match.Groups['inst'].Success) { $inst = $match.Groups['inst'].Value }
                if ($match.Groups['action'].Success) { $action = $match.Groups['action'].Value }
            }
        }

        if ($kind -eq 'Other') {
            $fallbackMatch = [regex]::Match($message, $fallbackUriPattern)
            if ($fallbackMatch.Success) { $uri = $fallbackMatch.Groups['uri'].Value }
        }

        $results.Add([pscustomobject][ordered]@{
            Time       = Format-SimRigTime -Time $time
            EventId    = $eventIdRaw
            Kind        = $kind
            TaskUri    = $uri
            InstanceId = $inst
            ActionName = $action
        })
    }

    return , @($results.ToArray())
}

function Test-TaskRanEvent {
    <#
        True for a Task Scheduler watch event whose Kind means the task's
        action actually ran: Launched, Started, ActionStarted. Everything
        else (Completed, Updated, LaunchIgnored, Other, ...) is false.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'Param name -Event is fixed by CONTRACT.md Engine API (Test-TaskRanEvent -Event ...); other subagents'' code and tests build against this exact name.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        $Event
    )

    $kind = Get-SimRigEventValue -Record $Event -Name 'Kind'
    return [bool]($kind -in @('Launched', 'Started', 'ActionStarted'))
}

function ConvertFrom-IniText {
    <#
        Parses an iRacing-style INI file (app.ini / core.ini /
        rendererDX11.ini): "[Section]" headers, "key=value" lines, values
        often padded with spaces/tabs then a "; comment" (see core.ini's
        "logging_enabled=1 <TAB>; Create log ..."). A trailing comment is
        stripped only when it is preceded by whitespace - a value that
        legitimately contains ';' with no whitespace before it (none seen in
        the fixtures, but the rule is explicit in CONTRACT) is left alone.
        Keys are case-insensitive (last write wins on a duplicate key,
        neither behaviour is fixture-backed - no fixture file has a
        duplicate key - but both are required by CONTRACT and covered by a
        synthetic test). Returns an ordered hashtable of section name ->
        ordered hashtable of key -> value, both using an
        OrdinalIgnoreCase-keyed dictionary.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $result = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ([string]::IsNullOrEmpty($Text)) { return $result }

    $normalized = $Text.TrimStart([char]0xFEFF) -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = $normalized -split "`n"

    $sectionPattern = '^\s*\[(?<name>[^\]]+)\]\s*$'
    $commentPattern = '(?<value>.*?)[ \t]+;.*$'
    $kvPattern = '^(?<key>[^=]+)=(?<value>.*)$'

    $currentSection = $null
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.TrimStart().StartsWith(';')) { continue }

        $sectionMatch = [regex]::Match($line, $sectionPattern)
        if ($sectionMatch.Success) {
            $sectionName = $sectionMatch.Groups['name'].Value
            if (-not $result.Contains($sectionName)) {
                $result[$sectionName] = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
            $currentSection = $result[$sectionName]
            continue
        }

        if (-not $currentSection) { continue }

        $kvMatch = [regex]::Match($line, $kvPattern)
        if (-not $kvMatch.Success) { continue }

        $key = $kvMatch.Groups['key'].Value.Trim()
        $rawValue = $kvMatch.Groups['value'].Value

        $commentMatch = [regex]::Match($rawValue, $commentPattern)
        $value = if ($commentMatch.Success) { $commentMatch.Groups['value'].Value } else { $rawValue }
        $value = $value.Trim()

        $currentSection[$key] = $value
    }

    return $result
}

function ConvertFrom-VersionsText {
    <#
        Parses a sha256sum-style VERSIONS.md/VERSIONS.txt body: lines shaped
        "<64 hex chars><spaces><file name>". Any other line (blank, a
        heading, a shell transcript line, ...) is ignored rather than
        thrown on. Hex is upper-cased on the way out.

        NOTE: fixtures/versions.txt is a captured PowerShell transcript
        (installing pwsh, running dotnet --list-runtimes), not a sha256sum
        file - it has no lines in this shape, so this function has NO
        fixture-backed golden case. It is tested against a synthetic
        sha256sum-style string built to match CONTRACT's documented format.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $result = @{}
    if ([string]::IsNullOrEmpty($Text)) { return $result }

    $normalized = $Text.TrimStart([char]0xFEFF) -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = $normalized -split "`n"

    $linePattern = '^(?<hash>[0-9A-Fa-f]{64})\s+(?<file>.+?)\s*$'
    foreach ($line in $lines) {
        $match = [regex]::Match($line, $linePattern)
        if (-not $match.Success) { continue }
        $result[$match.Groups['file'].Value] = $match.Groups['hash'].Value.ToUpperInvariant()
    }

    return $result
}

# ==========================================================================
# Preflight
# ==========================================================================

# Engine.Preflight.ps1 - SimRig Console v4.0
# Pure functions. No clock, no filesystem, no registry, no $env:. See CONTRACT.md.
#
# Get-PreflightCheck grades the rig's current state (Fact) against the
# recorded-good state (KnownGood) and the quiet list (QuietItem), one row per
# check: Name Expected Found Verdict(Pass|Fail|Warn|Manual|Info) Source
# Provisional(bool) Detail.
#
# flag 5 (build brief): preflight runs BEFORE the quiet. "Expected" for every
# service and task below is the known-good ENABLED state from KnownGood, never
# the state the quiet step will put it in - a service already sitting at its
# quiet target (e.g. Disabled) when preflight runs is a FAIL, because that
# means something quieted it outside of v4 and it never got restored. See the
# "flag 5" Pester test.
#
# flag 6: GPU steering targets are DATA (KnownGood.GpuSteering), not code, so
# re-grading a Pass/Fail after S.1 closes is a known-good.psd1 edit, never a
# code change. While KnownGood.GpuSteering.Provisional is $true, a Pass on
# that check is reported Provisional=$true with the reason in Detail.

function Build-PreflightRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        $Expected,
        $Found,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Fail', 'Warn', 'Manual', 'Info')][string] $Verdict,
        [Parameter(Mandatory)][string] $Source,
        [bool] $Provisional = $false,
        [string] $Detail = $null
    )
    return [pscustomobject]@{
        Name        = $Name
        Expected    = $Expected
        Found       = $Found
        Verdict     = $Verdict
        Source      = $Source
        Provisional = $Provisional
        Detail      = $Detail
    }
}

function Get-KnownGoodField {
    <# An optional key of a known-good entry (hashtable or object); $null when absent. Safe under strict mode. #>
    [CmdletBinding()]
    param($Entry, [Parameter(Mandatory)][string] $Name)
    if ($null -eq $Entry) { return $null }
    if ($Entry -is [System.Collections.IDictionary]) { if ($Entry.Contains($Name)) { return $Entry[$Name] } return $null }
    if ($Entry.PSObject.Properties[$Name]) { return $Entry.$Name }
    return $null
}

function Test-ProfileTuningAllowed {
    <#
        True only when the profile has Values.TuningFromKnownGood with the boolean $true
        (blocker 4, push 1 of the unit tune: only the profile of the rig has it). The one read
        of the key for the console, the elevated step and the self-test. The number 1 and the
        text "true" are not allowed, as in Get-SimRigTuningAllowed of the view. Safe under
        strict mode; no profile, no Values and no key are each "not allowed".
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] $RigProfile)
    $value = Get-KnownGoodField -Entry (Get-KnownGoodField -Entry $RigProfile -Name 'Values') -Name 'TuningFromKnownGood'
    return ($value -is [bool] -and $value)
}

function Get-SimRigTuningSupport {
    <#
        Push 2 of the unit tune, step 1 (amendments 8 and 9, scope A). Pure. The tuning state of
        this PC: Rig (the profile that Test-ProfileTuningAllowed allows), Supported (an AMD X3D CPU,
        a present NVIDIA display function, Windows build 22000 or higher, not a laptop) or
        NotSupported with the first reason, in that order. A reading that is not known is never
        Supported. The reasons are texts 35 to 40 of PUSH2-TEXTS-FOR-RICK-2026-10-03.md (Rick's
        "Yes"). Machine is the result of Build-MachineProfile.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()] $Machine, [AllowNull()] $RigProfile)

    if (Test-ProfileTuningAllowed -RigProfile $RigProfile) { return [pscustomobject]@{ State = 'Rig'; Reason = $null } }
    $notRead = 'The app could not read this part of the PC: {0}.'
    $reason = $null
    $unavailable = @(Get-KnownGoodField -Entry $Machine -Name 'Unavailable')

    $cpu = Get-KnownGoodField -Entry $Machine -Name 'Cpu'
    $vendor = Get-KnownGoodField -Entry $cpu -Name 'Vendor'
    $x3d = Get-KnownGoodField -Entry $cpu -Name 'X3D'
    if ($null -eq $Machine -or $unavailable -contains 'Cpu' -or $null -eq $vendor) { $reason = $notRead -f 'the CPU' }
    elseif ([string]$vendor -ne 'AMD') { $reason = 'The CPU is not an AMD CPU.' }
    elseif ($x3d -isnot [bool]) { $reason = $notRead -f 'the CPU' }
    elseif (-not $x3d) { $reason = 'The CPU is not an X3D CPU.' }

    if ($null -eq $reason) {
        $gpu = Get-KnownGoodField -Entry $Machine -Name 'Gpu'
        if ($unavailable -contains 'Gpu' -or $null -eq $gpu) { $reason = $notRead -f 'the graphics card' }
        else {
            $display = @(@(Get-KnownGoodField -Entry $gpu -Name 'Functions') | Where-Object {
                    $null -ne $_ -and [string](Get-KnownGoodField -Entry $_ -Name 'Role') -eq 'Display' -and
                    [string](Get-KnownGoodField -Entry $_ -Name 'InstanceId') -like 'PCI\VEN_10DE*'
                })
            if ($display.Count -eq 0) { $reason = 'The app found no NVIDIA graphics card that Windows uses for a display.' }
        }
    }

    if ($null -eq $reason) {
        $windows = Get-KnownGoodField -Entry $Machine -Name 'Windows'
        $build = [string](Get-KnownGoodField -Entry $windows -Name 'Build')
        $laptop = Get-KnownGoodField -Entry $windows -Name 'Laptop'
        if ($unavailable -contains 'Windows' -or $null -eq $windows) { $reason = $notRead -f 'the Windows version' }
        elseif ($build -notmatch '^(\d+)(\.\d+)?$' -or [int]$Matches[1] -lt 22000) { $reason = 'This version needs Windows 11, and the app did not find Windows 11 on this PC.' }
        elseif ($laptop -isnot [bool]) { $reason = $notRead -f 'whether this PC is a laptop' }
        elseif ($laptop) { $reason = 'This PC is a laptop.' }
    }

    if ($null -ne $reason) { return [pscustomobject]@{ State = 'NotSupported'; Reason = $reason } }
    return [pscustomobject]@{ State = 'Supported'; Reason = $null }
}

function Test-SelfSwitchStartType {
    <#
        True when known-good Services[Name].SelfSwitches lists both start types:
        Windows moves that service between them by itself, so the difference is
        not a v4 change. False for every other service.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] $KnownGood, [Parameter(Mandatory)] [string] $Name, [AllowNull()] [string] $Expected, [AllowNull()] [string] $Actual)
    if ($null -eq $KnownGood -or -not ($KnownGood -is [System.Collections.IDictionary]) -or -not $KnownGood.Contains('Services')) { return $false }
    $entry = $KnownGood['Services'][$Name]
    $set = @(Get-KnownGoodField -Entry $entry -Name 'SelfSwitches')
    if ($set.Count -eq 0 -or $null -eq $set[0]) { return $false }
    return (($set -contains $Expected) -and ($set -contains $Actual))
}

function Get-PreflightCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Fact,
        [Parameter(Mandatory)][hashtable] $KnownGood,
        $QuietItem,
        # The assembled simrig.machine-profile/1, when discovery has run. Optional:
        # a grading rule that needs it says so, and every other row grades the same
        # with or without it, so an older caller keeps working.
        [AllowNull()] $Machine = $null,
        # Push 2 of the unit tune, step 3. Supported or NotSupported (Get-SimRigTuningSupport):
        # the tuning rows of a PC that is not the rig, with texts 41 to 45 of
        # PUSH2-TEXTS-FOR-RICK-2026-10-03.md. $null and Rig: each row as before.
        [AllowNull()] [string] $TuningState = $null
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $items = @($QuietItem)
    $notRig = @('Supported', 'NotSupported') -contains $TuningState

    # --- GPU interrupt steering (spec section 5, flag 6) ---------------------------
    $steer = $KnownGood.GpuSteering
    $gpuInstances = @($Fact.GpuAffinity)
    if ($steer) {
        foreach ($inst in $gpuInstances) {
            $override = @($steer.Overrides) | Where-Object { $_.DeviceId -eq $inst.DeviceId } | Select-Object -First 1
            if ($override) {
                $expPolicy = Get-KnownGoodField -Entry $override -Name 'DevicePolicy'
                $expMask = Get-KnownGoodField -Entry $override -Name 'AssignmentSetOverride'
            } else {
                $expPolicy = Get-KnownGoodField -Entry $steer.Default -Name 'DevicePolicy'
                $expMask = Get-KnownGoodField -Entry $steer.Default -Name 'AssignmentSetOverride'
            }
            $instLabel = if ($inst.InstanceId) { $inst.InstanceId } else { $inst.DeviceId }
            $foundNow = if ($null -eq (Get-KnownGoodField -Entry $inst -Name 'DevicePolicy')) {
                'no policy set'
            } else {
                'DevicePolicy={0}, AssignmentSetOverride=0x{1:X}' -f $inst.DevicePolicy, [uint64](Get-KnownGoodField -Entry $inst -Name 'AssignmentSetOverride')
            }

            # A PC that is not the rig: this version does not change steering there
            # (amendment 9), so the row is Manual and shows what Windows has now (texts 41, 42).
            if ($notRig) {
                $rows.Add((Build-PreflightRow -Name 'GPU interrupt steering' -Expected 'not changed by this version' -Found $foundNow `
                            -Verdict 'Manual' -Source 'registry, PCI VEN_10DE' -Provisional $false `
                            -Detail ('Instance {0} ({1}). This version does not change GPU interrupt steering on this PC: the project has no tested target for this CPU, and Undo cannot put steering back. The value shown is what Windows has now.' -f $instLabel, $inst.DeviceId)))
                continue
            }

            # No target, no verdict. The public profile deliberately carries no
            # steering mask: CONTRACT.md says a single-CCD target is a measured
            # value the profile supplies and discovery never synthesizes one. A
            # missing or zero mask used to compute an expected value of 0x0 and
            # grade Fail, which told a stranger their GPU was wrong and that the
            # fix was to steer every interrupt at no CPU. 0x0 is not a target,
            # it is the absence of one, so the row is Manual - the same rule the
            # contract already gives for equal L3 - and it still shows what the
            # machine actually has, because that is the useful half.
            if ($null -eq $expMask -or [uint64]$expMask -eq 0) {
                $rows.Add((Build-PreflightRow -Name 'GPU interrupt steering' `
                            -Expected 'a core you choose, on this PC' -Found $foundNow `
                            -Verdict 'Manual' -Source 'registry, PCI VEN_10DE' -Provisional $false `
                            -Detail "Instance $instLabel ($($inst.DeviceId)) - this profile names no steering target, so nothing can grade it. Pick the core you measured, or run the rig profile that holds it."))
                continue
            }

            $expectedText = 'DevicePolicy={0}, AssignmentSetOverride=0x{1:X}' -f $expPolicy, [uint64]$expMask

            if ($null -eq (Get-KnownGoodField -Entry $inst -Name 'DevicePolicy')) {
                $rows.Add((Build-PreflightRow -Name 'GPU interrupt steering' -Expected $expectedText -Found 'no policy set' `
                            -Verdict 'Fail' -Source 'registry, PCI VEN_10DE' -Provisional $false `
                            -Detail "Instance $instLabel ($($inst.DeviceId)) has no Affinity Policy"))
                continue
            }

            $foundText = $foundNow
            $match = ($inst.DevicePolicy -eq $expPolicy) -and ([uint64](Get-KnownGoodField -Entry $inst -Name 'AssignmentSetOverride') -eq [uint64]$expMask)

            if ($match) {
                $provisional = [bool]$steer.Provisional
                $detail = "Instance $instLabel ($($inst.DeviceId))"
                if ($provisional) { $detail = '{0} - provisional: {1}' -f $detail, $steer.ProvisionalReason }
                $rows.Add((Build-PreflightRow -Name 'GPU interrupt steering' -Expected $expectedText -Found $foundText `
                            -Verdict 'Pass' -Source 'registry, PCI VEN_10DE' -Provisional $provisional -Detail $detail))
            } else {
                $rows.Add((Build-PreflightRow -Name 'GPU interrupt steering' -Expected $expectedText -Found $foundText `
                            -Verdict 'Fail' -Source 'registry, PCI VEN_10DE' -Provisional $false `
                            -Detail "Instance $instLabel ($($inst.DeviceId)) does not match"))
            }
        }

        # On a PC that is not the rig the count row is Manual, with the steering rows (Cowork
        # answer to the push 2 texts, answer 4): the profile has no count for this PC.
        $countVerdict = if ($notRig) { 'Manual' } elseif ($gpuInstances.Count -eq $steer.ExpectedInstanceCount) { 'Pass' } else { 'Fail' }
        $rows.Add((Build-PreflightRow -Name 'GPU interrupt steering count' -Expected $steer.ExpectedInstanceCount `
                    -Found $gpuInstances.Count -Verdict $countVerdict -Source 'registry, PCI VEN_10DE' -Provisional $false))
    }

    # --- known-good registry entries ----------------------------------------
    foreach ($entry in @($KnownGood.Registry)) {
        $key = '{0}\{1}' -f $entry.Path, $entry.Value
        $found = $Fact.Registry[$key]
        if ($null -eq $entry.Expected) {
            $rows.Add((Build-PreflightRow -Name $entry.Name -Expected $null -Found $found -Verdict 'Info' `
                        -Source 'registry' -Detail 'recorded'))
        } else {
            $verdict = if ($found -eq $entry.Expected) { 'Pass' } else { 'Fail' }
            # Text 45 on a PC that is not the rig: there the value is not a known-good value of the rig.
            $differs = if ($notRig) { 'the value differs from the value that the app expects' } else { 'value differs from known-good' }
            $detail = if ($null -eq $found) { 'not readable' } elseif ($verdict -eq 'Fail') { $differs } else { $null }
            $rows.Add((Build-PreflightRow -Name $entry.Name -Expected $entry.Expected -Found $found -Verdict $verdict `
                        -Source 'registry' -Detail $detail))
        }
    }

    # --- power plan -----------------------------------------------------------
    if ($KnownGood.PowerScheme) {
        # Four shapes, because one GUID compared by equality was wrong in both
        # directions for a public build (G-8, and flag 6).
        #
        #   Guid      one plan, graded Pass or Fail. The rig profile.
        #   Accept    several plans, any of which is fine. A stranger on Windows
        #             Balanced and a stranger on AMD Ryzen Balanced both pass;
        #             telling somebody their plan is wrong because it is not the
        #             one this rig uses is a false alarm, and a false alarm in
        #             preflight is how people learn to ignore preflight.
        #   Note      not wrong, but worth saying. High Performance parks no
        #             cores; that is a fact the user should see, not a verdict.
        #   NoParking plans that park no cores. On a dual-CCD machine that is a
        #             Fail (flag 6): the AMD driver needs parking to keep work on
        #             the V-Cache die. On single-CCD the same plan is only a Note.
        $ps = $KnownGood.PowerScheme
        $found = $Fact.PowerScheme
        $accept = @()
        if ($null -ne (Get-KnownGoodField -Entry $ps -Name 'Guid')) { $accept += [string]$ps.Guid }
        foreach ($g in @(Get-KnownGoodField -Entry $ps -Name 'Accept')) { if ($g) { $accept += [string]$g } }
        $noteList = @(@(Get-KnownGoodField -Entry $ps -Name 'Note') | Where-Object { $_ })
        $noParking = @(@(Get-KnownGoodField -Entry $ps -Name 'NoParking') | Where-Object { $_ })
        $expectedText = if ($accept.Count -gt 1) { 'any of: ' + ($accept -join ', ') } elseif ($accept.Count -eq 1) { $accept[0] } else { 'a plan this profile accepts' }

        if ($null -eq $found) {
            $rows.Add((Build-PreflightRow -Name 'Power plan' -Expected $expectedText -Found $null `
                        -Verdict 'Fail' -Source 'powercfg /getactivescheme' -Detail 'not readable'))
        } else {
            $foundGuid = [string](Get-KnownGoodField -Entry $found -Name 'Guid')
            $foundText = '{0} ({1})' -f $foundGuid, (Get-KnownGoodField -Entry $found -Name 'Name')
            $dualCcd = $false
            if ($null -ne $Machine) {
                $ccd = Get-KnownGoodField -Entry $Machine -Name 'Ccd'
                if ($null -eq $ccd) {
                    $cpuBlock = Get-KnownGoodField -Entry $Machine -Name 'Cpu'
                    if ($null -ne $cpuBlock) { $ccd = Get-KnownGoodField -Entry $cpuBlock -Name 'Ccd' }
                }
                $dualCcd = ($null -ne $ccd -and [int]$ccd -ge 2)
            }

            $detail = $null
            if ($dualCcd -and $noParking -contains $foundGuid) {
                $verdict = 'Fail'
                # Text 44 on a supported PC, where Apply tuning offers the change (Get-SimRigTuningOffer).
                # On each other PC the text stays as it was: Apply tuning does not change it there.
                $detail = if ($TuningState -eq 'Supported') {
                    'This plan parks no cores, and this PC has two CCDs. The AMD driver needs core parking to keep the game on the V-Cache die, so a no-parking plan costs more than it gains here. Apply tuning can change it to Windows Balanced.'
                } else {
                    'This plan parks no cores, and this PC has two CCDs. The AMD driver needs core parking to keep the game on the V-Cache die, so a no-parking plan costs more than it gains here (flag 6).'
                }
            } elseif ($accept -contains $foundGuid) {
                $verdict = 'Pass'
            } elseif ($noteList -contains $foundGuid) {
                $verdict = 'Info'
                $detail = 'Not a problem, and not what this profile would pick. This plan parks no cores, so it is recorded rather than graded.'
            } elseif ($notRig) {
                # Text 43: a plan that the app does not know is not a reason for a write, and a
                # Fail with no reason and no repair is a false alarm (Cowork answer 2 on the texts).
                $verdict = 'Manual'
                $detail = 'The app does not know this plan, so it does not grade it and does not change it.'
            } else {
                $verdict = 'Fail'
            }

            $rows.Add((Build-PreflightRow -Name 'Power plan' -Expected $expectedText -Found $foundText `
                        -Verdict $verdict -Source 'powercfg /getactivescheme' -Detail $detail))
        }
    }

    # --- timer resolution -------------------------------------------------
    if ($KnownGood.TimerResolution) {
        $foundMs = $Fact.TimerResolutionMs
        $maxMs = $KnownGood.TimerResolution.MaxMs + $KnownGood.TimerResolution.ToleranceMs
        if ($null -eq $foundMs) {
            $rows.Add((Build-PreflightRow -Name 'Timer resolution' -Expected $KnownGood.TimerResolution.MaxMs -Found $null `
                        -Verdict 'Fail' -Source 'NtQueryTimerResolution' -Detail 'not readable'))
        } elseif ($KnownGood.TimerResolution.ContainsKey('Grade') -and $KnownGood.TimerResolution.Grade -eq $false) {
            # Before the race nothing requests 0.5 ms; iRacing does once it runs.
            $rows.Add((Build-PreflightRow -Name 'Timer resolution' -Expected $KnownGood.TimerResolution.MaxMs -Found $foundMs `
                        -Verdict 'Info' -Source 'NtQueryTimerResolution' -Detail 'recorded - iRacing requests its own resolution when it runs'))
        } else {
            $verdict = if ($foundMs -le $maxMs) { 'Pass' } else { 'Fail' }
            $rows.Add((Build-PreflightRow -Name 'Timer resolution' -Expected $KnownGood.TimerResolution.MaxMs -Found $foundMs `
                        -Verdict $verdict -Source 'NtQueryTimerResolution'))
        }
    }

    # --- services (flag 5: expected is the known-good ENABLED state) --------
    foreach ($qi in ($items | Where-Object { $_.Kind -eq 'Service' })) {
        $svcEntry = $KnownGood.Services[$qi.Name]
        $expected = if ($svcEntry) { $svcEntry.StartType } else { $null }
        $state = @($Fact.Services) | Where-Object { $_.Id -eq $qi.Id } | Select-Object -First 1
        if (-not $state -or -not $state.Exists) {
            $rows.Add((Build-PreflightRow -Name "Service: $($qi.Name)" -Expected $expected -Found $null `
                        -Verdict 'Info' -Source 'SCM' -Detail 'not installed'))
        } else {
            # AlsoAccept: other start types Windows sets by itself. Never list the
            # quiet target there - flag 5 needs a service found quiet to fail.
            $also = @(Get-KnownGoodField -Entry $svcEntry -Name 'AlsoAccept')
            $verdict = if ($state.StartType -eq $expected -or $also -contains $state.StartType) { 'Pass' } else { 'Fail' }
            $detail = if ($state.StartType -ne $expected -and $verdict -eq 'Pass') { 'Windows sets this by itself - accepted' } else { $null }
            $rows.Add((Build-PreflightRow -Name "Service: $($qi.Name)" -Expected $expected -Found $state.StartType `
                        -Verdict $verdict -Source 'SCM' -Detail $detail))
        }
    }

    # --- tasks --------------------------------------------------------------
    foreach ($qi in ($items | Where-Object { $_.Kind -eq 'Task' })) {
        $uri = $qi.Uri
        $taskEntry = $KnownGood.Tasks[$uri]
        $expected = if ($taskEntry) { $taskEntry.Enabled } else { $null }
        $state = @($Fact.Tasks) | Where-Object { $_.Id -eq $qi.Id } | Select-Object -First 1
        if (-not $state -or -not $state.Exists) {
            $rows.Add((Build-PreflightRow -Name "Task: $uri" -Expected $expected -Found $null `
                        -Verdict 'Info' -Source 'Task Scheduler' -Detail 'not installed'))
        } else {
            $managed = [bool](Get-KnownGoodField -Entry $taskEntry -Name 'WindowsManaged')
            $verdict = if ($state.Enabled -eq $expected) { 'Pass' } elseif ($managed) { 'Info' } else { 'Fail' }
            $detail = if ($verdict -eq 'Info') { 'Windows changes this by itself - recorded, not graded; restore puts back what the snapshot saw' } else { $null }
            $rows.Add((Build-PreflightRow -Name "Task: $uri" -Expected $expected -Found $state.Enabled `
                        -Verdict $verdict -Source 'Task Scheduler' -Detail $detail))
        }
    }

    # --- iRacing ini entries -------------------------------------------------
    foreach ($entry in @($KnownGood.Ini)) {
        $bucket = $Fact.Ini[$entry.File]
        $found = $null
        if ($bucket -and $bucket[$entry.Section]) { $found = $bucket[$entry.Section][$entry.Key] }
        # Expected $null = recorded, not graded (same rule as the registry rows).
        $verdict = if ($null -eq $entry.Expected) { 'Info' } elseif ($null -eq $found) { 'Fail' } elseif ($found -eq $entry.Expected) { 'Pass' } else { 'Fail' }
        $detail = if ($null -eq $found) { 'not readable' } elseif ($null -eq $entry.Expected) { 'recorded' } else { $null }
        $rows.Add((Build-PreflightRow -Name "iRacing ini: $($entry.File)/$($entry.Key)" -Expected $entry.Expected -Found $found `
                    -Verdict $verdict -Source 'ini read-back' -Detail $detail))
    }

    # --- preferred values (v4.1) ----------------------------------------------
    # One row per Preference entry, in the same shape, so the gap table and the
    # golden compare see one row per setting and not two.
    foreach ($row in (Get-PreferenceCheck -Fact $Fact -KnownGood $KnownGood)) { $rows.Add($row) }

    # --- free space -----------------------------------------------------------
    if ($KnownGood.FreeSpace) {
        $minBytes = [int64]$KnownGood.FreeSpace.MinGB * 1GB
        $pairs = @(
            @{ Label = 'install drive'; Drive = $Fact.IRacingInstallDrive }
            @{ Label = 'documents drive'; Drive = $Fact.DocumentsDrive }
        )
        foreach ($pair in $pairs) {
            $vol = @($Fact.Volumes) | Where-Object { $_.Drive -eq $pair.Drive } | Select-Object -First 1
            $name = "Free space ($($pair.Label))"
            if (-not $vol) {
                $rows.Add((Build-PreflightRow -Name $name -Expected "$($KnownGood.FreeSpace.MinGB) GB" -Found $null `
                            -Verdict 'Fail' -Source 'Get-Volume' -Detail "drive $($pair.Drive) not found"))
            } else {
                $foundGb = [math]::Round($vol.FreeBytes / 1GB, 1)
                $verdict = if ($vol.FreeBytes -ge $minBytes) { 'Pass' } else { 'Fail' }
                $rows.Add((Build-PreflightRow -Name $name -Expected "$($KnownGood.FreeSpace.MinGB) GB" -Found "$foundGb GB" `
                            -Verdict $verdict -Source 'Get-Volume'))
            }
        }
    }

    # --- GPU preference -------------------------------------------------------
    if ($KnownGood.GpuPreference) {
        $found = $Fact.GpuPreference
        $verdict = if ($found -eq $KnownGood.GpuPreference.Expected) { 'Pass' } else { 'Fail' }
        $rows.Add((Build-PreflightRow -Name 'GPU preference' -Expected $KnownGood.GpuPreference.Expected -Found $found `
                    -Verdict $verdict -Source 'registry'))
    }

    # --- script integrity ------------------------------------------------------
    $versions = ConvertFrom-VersionsText -Text $Fact.VersionsText
    $fileHash = $Fact.FileHash
    if ($null -eq $fileHash) { $fileHash = @{} }
    if ($null -eq $versions) { $versions = @{} }
    # Sort-Object, not Select-Object: a hashtable hands back its keys in an
    # unpredictable order, so the Script integrity rows used to appear in a
    # different order on every run. The rows were always the same rows; only
    # their order moved. v4.1 sorts them, which makes the whole preflight
    # output reproducible and is the first deliberate G0-to-G1 change.
    $allFiles = @($fileHash.Keys) + @($versions.Keys) | Sort-Object -Unique
    foreach ($file in $allFiles) {
        $expectedHash = $versions[$file]
        $foundHash = $fileHash[$file]
        if (-not $expectedHash -or -not $foundHash) {
            $missingSide = if (-not $foundHash) { 'file hash' } else { 'VERSIONS.md' }
            $rows.Add((Build-PreflightRow -Name 'Script integrity' -Expected $expectedHash -Found $foundHash `
                        -Verdict 'Fail' -Source 'file hash' -Detail "$file missing from $missingSide"))
        } elseif ($foundHash -ne $expectedHash) {
            $rows.Add((Build-PreflightRow -Name 'Script integrity' -Expected $expectedHash -Found $foundHash `
                        -Verdict 'Fail' -Source 'file hash' -Detail "$file hash mismatch"))
        } else {
            $rows.Add((Build-PreflightRow -Name 'Script integrity' -Expected $expectedHash -Found $foundHash `
                        -Verdict 'Pass' -Source 'file hash' -Detail $file))
        }
    }

    # --- pending reboot ---------------------------------------------------------
    $pendingVerdict = if ($Fact.PendingReboot) { 'Warn' } else { 'Pass' }
    $rows.Add((Build-PreflightRow -Name 'Pending reboot' -Expected $false -Found $Fact.PendingReboot `
                -Verdict $pendingVerdict -Source 'registry'))

    # --- overlays running (list only) --------------------------------------------
    $overlayText = if (@($Fact.Overlay).Count -gt 0) { (@($Fact.Overlay) -join ', ') } else { 'none' }
    $rows.Add((Build-PreflightRow -Name 'Overlays running' -Expected $null -Found $overlayText `
                -Verdict 'Info' -Source 'process list'))

    # --- Defender real-time (expected ON before the quiet) -----------------------
    if ($null -eq $Fact.Defender) {
        $rows.Add((Build-PreflightRow -Name 'Defender real-time monitoring' -Expected $true -Found $null `
                    -Verdict 'Fail' -Source 'Get-MpComputerStatus' -Detail 'not readable'))
    } else {
        $verdict = if ($Fact.Defender.RealtimeOn) { 'Pass' } else { 'Fail' }
        $rows.Add((Build-PreflightRow -Name 'Defender real-time monitoring' -Expected $true -Found $Fact.Defender.RealtimeOn `
                    -Verdict $verdict -Source 'Get-MpComputerStatus'))
    }

    # --- manual entries (never Pass) ---------------------------------------------
    foreach ($manual in @($KnownGood.Manual)) {
        $rows.Add((Build-PreflightRow -Name $manual.Name -Expected 'manual check' -Found $null `
                    -Verdict 'Manual' -Source $manual.Source))
    }

    return , @($rows.ToArray())
}

function Get-PreflightSummary {
    [CmdletBinding()]
    param($Check)

    $rows = @($Check)
    $pass = @($rows | Where-Object { $_.Verdict -eq 'Pass' }).Count
    $fail = @($rows | Where-Object { $_.Verdict -eq 'Fail' })
    $warn = @($rows | Where-Object { $_.Verdict -eq 'Warn' }).Count
    $manual = @($rows | Where-Object { $_.Verdict -eq 'Manual' }).Count
    $info = @($rows | Where-Object { $_.Verdict -eq 'Info' }).Count
    $ready = $fail.Count -eq 0

    if ($ready) {
        $line = 'READY - {0} checks: {1} pass, {2} fail, {3} warn, {4} manual, {5} info' -f `
            $rows.Count, $pass, $fail.Count, $warn, $manual, $info
    } else {
        $names = @($fail | Select-Object -ExpandProperty Name -Unique)
        $line = 'NOT READY - {0} fail: {1}' -f $fail.Count, ($names -join ', ')
    }

    return [pscustomobject]@{
        Ready  = $ready
        Line   = $line
        Pass   = $pass
        Fail   = $fail.Count
        Warn   = $warn
        Manual = $manual
        Info   = $info
    }
}

# --------------------------------------------------------------------------
# Preferred values (v4.1, unit U1.1 folded in at integration)
#
# Rick's decision 2026-09-19, confirmed 2026-09-20: NvReflexMode, the FPS cap
# and MSAA get a preferred value. The preferred value is DATA in
# known-good.psd1's Preference array, never code here, so a change of mind is
# a data edit. A Preference entry with no Preferred value stays Info, exactly
# as v4.0 recorded NvReflexMode.
# --------------------------------------------------------------------------

function Test-PreferenceData {
    <#
        .SYNOPSIS
        Validates a raw KnownGood.Preference array (simrig.known-good/1,
        Preference key, v4.1). Returns an array of error strings - empty
        means valid. Never throws on bad data; that is the point.

        .DESCRIPTION
        Each entry needs Key, File, Section, IniKey, Allowed (a non-empty
        list of legal ini values) and Reason. Preferred is optional: $null
        (or absent) means "no preference chosen yet" and is not an error.
        When Preferred is set, it must be one of the Allowed values.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        $Data
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $entries = @($Data)

    if ($entries.Count -eq 0 -or $null -eq $entries[0]) {
        return , $errors.ToArray()
    }

    $seenKeys = @{}
    $entryIndex = 0
    foreach ($entry in $entries) {
        $entryIndex++

        $key = Get-KnownGoodField -Entry $entry -Name 'Key'
        $label = if ([string]::IsNullOrEmpty($key)) { "Preference[$entryIndex]" } else { "Preference[$entryIndex] ($key)" }

        foreach ($field in 'Key', 'File', 'Section', 'IniKey', 'Reason') {
            $val = Get-KnownGoodField -Entry $entry -Name $field
            if ($null -eq $val -or ($val -is [string] -and [string]::IsNullOrWhiteSpace($val))) {
                $errors.Add("$label`: $field is required")
            }
        }

        if (-not [string]::IsNullOrEmpty($key)) {
            if ($seenKeys.ContainsKey($key)) {
                $errors.Add("$label`: duplicate Key '$key'")
            } else {
                $seenKeys[$key] = $true
            }
        }

        $allowed = @(Get-KnownGoodField -Entry $entry -Name 'Allowed')
        $allowed = @($allowed | Where-Object { $null -ne $_ })
        if ($allowed.Count -eq 0) {
            $errors.Add("$label`: Allowed is required and must list at least one value")
        }

        $preferred = Get-KnownGoodField -Entry $entry -Name 'Preferred'
        if ($null -ne $preferred -and $allowed.Count -gt 0 -and $allowed -notcontains $preferred) {
            $errors.Add("$label`: Preferred '$preferred' is not in Allowed ($($allowed -join ', '))")
        }
    }

    return , $errors.ToArray()
}

function Get-PreferenceCheck {
    <#
        .SYNOPSIS
        Grades the rig's current iRacing ini values against Rick's preferred
        value for each KnownGood.Preference entry (v4.1, R-G7). Returns
        Build-PreflightRow rows: Name Expected Found Verdict Source
        Provisional Detail - the same shape Get-PreflightCheck returns, so
        these rows fold into one gap table and one golden compare (flag 2).

        .DESCRIPTION
        Preferred = $null: the row is Info, "recorded - no preferred value
        chosen" - unchanged from v4.0's NvReflexMode behaviour.
        Preferred set and not in Allowed: a known-good.psd1 data error. The
        row grades Fail and names the problem, rather than throwing, so a bad
        data edit still produces a comparable row (flag 2) instead of an
        exception that would stop the whole preflight.
        Otherwise: Pass when the ini value read back equals Preferred, Fail
        when it differs or is not readable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Fact,

        [Parameter(Mandatory)]
        $KnownGood
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $source = 'ini read-back'

    foreach ($entry in @(Get-KnownGoodField -Entry $KnownGood -Name 'Preference')) {
        if ($null -eq $entry) { continue }

        $file = $entry.File
        $section = $entry.Section
        $iniKey = $entry.IniKey
        $name = "iRacing ini: $file/$iniKey"

        $bucket = $Fact.Ini[$file]
        $found = $null
        if ($bucket -and $bucket[$section]) { $found = $bucket[$section][$iniKey] }

        $allowed = @(Get-KnownGoodField -Entry $entry -Name 'Allowed') | Where-Object { $null -ne $_ }
        $preferred = Get-KnownGoodField -Entry $entry -Name 'Preferred'

        if ($null -eq $preferred) {
            $rows.Add((Build-PreflightRow -Name $name -Expected $null -Found $found -Verdict 'Info' `
                        -Source $source -Detail 'recorded - no preferred value chosen'))
            continue
        }

        if ($allowed.Count -gt 0 -and $allowed -notcontains $preferred) {
            $rows.Add((Build-PreflightRow -Name $name -Expected $preferred -Found $found -Verdict 'Fail' `
                        -Source $source -Detail "known-good.psd1 error: Preferred '$preferred' is not in Allowed ($($allowed -join ', '))"))
            continue
        }

        if ($null -eq $found) {
            $rows.Add((Build-PreflightRow -Name $name -Expected $preferred -Found $null -Verdict 'Fail' `
                        -Source $source -Detail 'not readable'))
        } elseif ($found -eq $preferred) {
            $rows.Add((Build-PreflightRow -Name $name -Expected $preferred -Found $found -Verdict 'Pass' -Source $source))
        } else {
            $rows.Add((Build-PreflightRow -Name $name -Expected $preferred -Found $found -Verdict 'Fail' `
                        -Source $source -Detail 'value differs from the preferred value'))
        }
    }

    return , @($rows.ToArray())
}

# --------------------------------------------------------------------------
# Apply tuning (v4.1)
#
# v4.0 read the persistent tuning settings and graded them. v4.1 can write
# them, one opt-in operation, with a snapshot and an Undo (spec D2, flag 7).
# Four items only: GPU interrupt steering, MPO, HAGS and the power plan.
#
# Every target value is DATA from known-good.psd1 (flag 6 of v4.0: steering
# targets are data, so a change of target is a data edit). These functions are
# pure: they build a plan and a snapshot, and SimRig.Actions.ps1 does the
# writing.
# --------------------------------------------------------------------------

function Get-TuningItem {
    <#
        .SYNOPSIS
        The four tuning items, built from known-good.psd1. Id, what it is, how
        it is written, and whether Windows needs a restart before the new value
        takes effect.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $KnownGood)

    $items = [System.Collections.Generic.List[object]]::new()

    $registryByName = @{}
    foreach ($r in @($KnownGood.Registry)) { $registryByName[[string]$r.Name] = $r }

    foreach ($pair in @(
            @{ Id = 'Mpo'; KnownGoodName = 'MPO'; Label = 'MPO (Multiplane Overlay)'; RestartNeeded = $false },
            @{ Id = 'Hags'; KnownGoodName = 'HAGS'; Label = 'HAGS (hardware-accelerated GPU scheduling)'; RestartNeeded = $true }
        )) {
        $entry = $registryByName[$pair.KnownGoodName]
        if ($null -eq $entry) { continue }
        if ($null -eq (Get-KnownGoodField -Entry $entry -Name 'Expected')) { continue }
        $items.Add([pscustomobject]@{
                Id            = $pair.Id
                Name          = $pair.Label
                Kind          = 'Registry'
                Path          = [string]$entry.Path
                Value         = [string]$entry.Value
                Target        = $entry.Expected
                RegType       = 'DWord'
                RestartNeeded = $pair.RestartNeeded
            })
    }

    if ($KnownGood.ContainsKey('PowerScheme') -and $KnownGood.PowerScheme) {
        $items.Add([pscustomobject]@{
                Id            = 'PowerPlan'
                Name          = 'Power plan'
                Kind          = 'PowerPlan'
                Path          = $null
                Value         = $null
                Target        = [string]$KnownGood.PowerScheme.Guid
                RegType       = $null
                RestartNeeded = $false
            })
    }

    if ($KnownGood.ContainsKey('GpuSteering') -and $KnownGood.GpuSteering) {
        # beta1-fix D-A (APPROVALS-RICK-2026-10-13-1905 item 1): the value of each device with an override (DeviceId ->
        # text), as Get-GpuSteeringTarget gives it to the writer. A device with none has the Target (the Default).
        $deviceTarget = @{}
        foreach ($o in @($KnownGood.GpuSteering.Overrides)) {
            if ($null -eq $o) { continue }
            $deviceTarget[[string]$o.DeviceId] = ('DevicePolicy={0}, AssignmentSetOverride=0x{1:X}' -f $o.DevicePolicy, [uint64]$o.AssignmentSetOverride)
        }
        $items.Add([pscustomobject]@{
                Id            = 'GpuSteering'
                Name          = 'GPU interrupt steering'
                Kind          = 'GpuSteering'
                Path          = $null
                Value         = $null
                Target        = ('DevicePolicy={0}, AssignmentSetOverride=0x{1:X}' -f $KnownGood.GpuSteering.Default.DevicePolicy, [uint64]$KnownGood.GpuSteering.Default.AssignmentSetOverride)
                RegType       = $null
                RestartNeeded = $true
                DeviceTarget  = $deviceTarget
            })
    }

    return , @($items.ToArray())
}

function Get-TuningNowValue {
    <#
        .SYNOPSIS
        What a tuning item reads as right now, as text for the screen and for
        the snapshot. $null means "not set" or "not readable".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Item,
        [Parameter(Mandatory)] [hashtable] $Fact
    )

    switch ($Item.Kind) {
        'Registry' {
            $key = '{0}\{1}' -f $Item.Path, $Item.Value
            if ($Fact.Registry -and $Fact.Registry.Contains($key)) { return $Fact.Registry[$key] }
            return $null
        }
        'PowerPlan' {
            if ($null -eq $Fact.PowerScheme) { return $null }
            return [string]$Fact.PowerScheme.Guid
        }
        'GpuSteering' {
            # Get-KnownGoodField, not direct member access: a reading from a
            # machine with no policy has no DevicePolicy property at all, and
            # strict mode throws on that.
            # beta1-fix D-A: only the functions that the writer steers (Get-GpuSteeringScope, the scope of the
            # fact, Display when the fact has none: the scope of the Apply child). Before, the first function
            # of the reading was read; on the rig that was the audio function 22BA, out of scope, at 0x40,
            # and the read-back of a correct Apply was a FAIL (beta.1 rig run, 2026-10-13).
            $scope = if ($Fact.ContainsKey('GpuScope') -and $Fact['GpuScope']) { [string]$Fact['GpuScope'] } else { 'Display' }
            $present = @(@($Fact.GpuAffinity) | Where-Object { $null -ne $_ -and (Get-GpuSteeringScope -Function $_ -Scope $scope).InScope })
            if ($present.Count -eq 0) { return $null }
            $policy = foreach ($p in $present) { Get-KnownGoodField -Entry $p -Name 'DevicePolicy' }
            $missing = @(@($policy) | Where-Object { $null -eq $_ })
            if ($missing.Count -eq $present.Count) { return 'no policy on any device' }
            if ($missing.Count -gt 0) { return ('no policy on {0} of {1} devices' -f $missing.Count, $present.Count) }
            # beta1-fix D-A (APPROVALS-RICK-2026-10-13-1905 items 1 and 2): each device in scope against its own value
            # (DeviceTarget of the item, else the Target). All at their value: the Target, so that each caller that
            # compares with the Target sees "at target". Else each device that is not, with what it has.
            $deviceTarget = Get-KnownGoodField -Entry $Item -Name 'DeviceTarget'
            $off = foreach ($p in $present) {
                $devId = [string](Get-KnownGoodField -Entry $p -Name 'DeviceId')
                $now = 'DevicePolicy={0}, AssignmentSetOverride=0x{1:X}' -f (Get-KnownGoodField -Entry $p -Name 'DevicePolicy'), [uint64](Get-KnownGoodField -Entry $p -Name 'AssignmentSetOverride')
                $own = if ($null -ne $deviceTarget -and $devId) { Get-KnownGoodField -Entry $deviceTarget -Name $devId } else { $null }
                $want = if ($null -ne $own) { [string]$own } else { [string](Get-KnownGoodField -Entry $Item -Name 'Target') }
                if ($now -ne $want) { '{0} {1}' -f $devId, $now }
            }
            if (@($off).Count -eq 0) { return [string](Get-KnownGoodField -Entry $Item -Name 'Target') }
            return (@($off) -join '; ')
        }
        default { return $null }
    }
}

function Get-SimRigTuningOffer {
    <#
        Push 2 of the unit tune, step 2 (amendments 8 and 9, scope A, design section 3). Pure. The
        tuning items that this PC is offered, each with Now (Get-TuningNowValue) and Offer: Write, or
        NoChange when the value now is one that the app accepts.

        Rig: the items of known-good.psd1 (Get-TuningItem), as before.
        Supported: MPO and HAGS from the rules W-MPO and W-HAGS; the power plan only in one case, a
        PC with two or more CCDs on a plan of the NoParking list of the profile, with Windows Balanced
        as the target; a plan on the Accept or the Note list is NoChange; a plan that is not read or
        not in a list is not offered (a plan that the app does not know is not a reason for a write).
        GPU steering is not offered: the project has no target for this PC, and Undo cannot put it
        back (amendment 9).
        NotSupported: no item.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] $Support,
        [AllowNull()] $Machine,
        [AllowNull()] [object[]] $Rule,
        [AllowNull()] $ProfileValues,
        [AllowNull()] [hashtable] $KnownGood,
        [Parameter(Mandatory)] [hashtable] $Fact
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $state = [string](Get-KnownGoodField -Entry $Support -Name 'State')

    if ($state -eq 'Rig') {
        if ($null -eq $KnownGood) { return , @() }
        $rigItems = Get-TuningItem -KnownGood $KnownGood
        foreach ($item in @($rigItems)) {
            $now = Get-TuningNowValue -Item $item -Fact $Fact
            $offer = if ($null -ne $now -and [string]$now -eq [string]$item.Target) { 'NoChange' } else { 'Write' }
            $item | Add-Member -NotePropertyName Now -NotePropertyValue $now
            $item | Add-Member -NotePropertyName Offer -NotePropertyValue $offer
            $items.Add($item)
        }
        return , @($items.ToArray())
    }
    if ($state -ne 'Supported') { return , @() }

    foreach ($pair in @(
            @{ RuleId = 'W-MPO'; Id = 'Mpo'; Label = 'MPO (Multiplane Overlay)'; RestartNeeded = $false },
            @{ RuleId = 'W-HAGS'; Id = 'Hags'; Label = 'HAGS (hardware-accelerated GPU scheduling)'; RestartNeeded = $true }
        )) {
        $wanted = $pair.RuleId
        $found = @(@($Rule) | Where-Object { $null -ne $_ -and [string](Get-KnownGoodField -Entry $_ -Name 'Id') -eq $wanted })
        if ($found.Count -ne 1) { continue }
        $target = Get-KnownGoodField -Entry $found[0] -Name 'Target'
        $expected = Get-KnownGoodField -Entry $found[0] -Name 'Expected'
        if ($null -eq $target -or $null -eq $expected) { continue }
        $item = [pscustomobject]@{
            Id            = $pair.Id
            Name          = $pair.Label
            Kind          = 'Registry'
            Path          = [string](Get-KnownGoodField -Entry $target -Name 'Path')
            Value         = [string](Get-KnownGoodField -Entry $target -Name 'Value')
            Target        = $expected
            RegType       = 'DWord'
            RestartNeeded = $pair.RestartNeeded
        }
        $now = Get-TuningNowValue -Item $item -Fact $Fact
        $offer = if ($null -ne $now -and [string]$now -eq [string]$expected) { 'NoChange' } else { 'Write' }
        $item | Add-Member -NotePropertyName Now -NotePropertyValue $now
        $item | Add-Member -NotePropertyName Offer -NotePropertyValue $offer
        $items.Add($item)
    }

    $plans = Get-KnownGoodField -Entry $ProfileValues -Name 'PowerScheme'
    $planNow = Get-KnownGoodField -Entry (Get-KnownGoodField -Entry $Fact -Name 'PowerScheme') -Name 'Guid'
    if ($null -ne $plans -and -not [string]::IsNullOrWhiteSpace([string]$planNow)) {
        $accept = @(@(Get-KnownGoodField -Entry $plans -Name 'Accept') | Where-Object { $_ })
        $noteList = @(@(Get-KnownGoodField -Entry $plans -Name 'Note') | Where-Object { $_ })
        $noParking = @(@(Get-KnownGoodField -Entry $plans -Name 'NoParking') | Where-Object { $_ })
        # The same test of two CCDs as the power plan row of Get-PreflightCheck.
        $ccd = Get-KnownGoodField -Entry $Machine -Name 'Ccd'
        if ($null -eq $ccd) { $ccd = Get-KnownGoodField -Entry (Get-KnownGoodField -Entry $Machine -Name 'Cpu') -Name 'Ccd' }
        $dualCcd = ($null -ne $ccd -and [int]$ccd -ge 2)
        $offer = $null
        if ($dualCcd -and $noParking -contains [string]$planNow) { $offer = 'Write' }
        elseif ($accept -contains [string]$planNow -or $noteList -contains [string]$planNow) { $offer = 'NoChange' }
        if ($null -ne $offer) {
            $items.Add([pscustomobject]@{
                    Id            = 'PowerPlan'
                    Name          = 'Power plan'
                    Kind          = 'PowerPlan'
                    Path          = $null
                    Value         = $null
                    # Windows Balanced: a Microsoft constant on each Windows 11 PC (design section 3).
                    Target        = $(if ($offer -eq 'Write') { '381b4222-f694-41f0-9685-ff5bb260df2e' } else { [string]$planNow })
                    RegType       = $null
                    RestartNeeded = $false
                    Now           = [string]$planNow
                    Offer         = $offer
                })
        }
    }

    return , @($items.ToArray())
}

function Select-SimRigTuningRequest {
    <#
        Push 2 of the unit tune, step 4 (design section 6, amendment 8 condition 4). Pure. What the
        elevated child does with an ApplyTuning request, decided from its own state and its own offer:
        - NotSupported, or no state: refused, with the text of amendment 7b.
        - Rig: allowed, on the path of known-good.psd1 (Item is $null; the child makes the rig items).
        - Supported: a list of ticked ids is needed; each id must be an item of this PC with Offer
          Write (Get-SimRigTuningOffer); then Item is those items of the offer, with the values that
          the child made itself. Each refusal is before any write.
        Texts A and B: Rick's typed "Yes", 2026-10-04 ("yes to text A and B").
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] $Support,
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Offer,
        [AllowNull()] [AllowEmptyCollection()] [string[]] $Only
    )

    $state = [string](Get-KnownGoodField -Entry $Support -Name 'State')
    if ($state -eq 'Rig') { return [pscustomobject]@{ Allowed = $true; Error = $null; Item = $null } }
    if ($state -ne 'Supported') {
        return [pscustomobject]@{ Allowed = $false; Error = 'Refused: This version does not change tuning settings on this PC.'; Item = $null }
    }
    $ids = @(@($Only) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($ids.Count -eq 0) {
        return [pscustomobject]@{ Allowed = $false; Error = 'Refused: Apply tuning on this PC needs the list of the items that you ticked. Nothing was changed.'; Item = $null }
    }
    $chosen = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $ids) {
        $wanted = [string]$id
        $match = @(@($Offer) | Where-Object { $null -ne $_ -and [string](Get-KnownGoodField -Entry $_ -Name 'Id') -eq $wanted })
        if ($match.Count -ne 1 -or [string](Get-KnownGoodField -Entry $match[0] -Name 'Offer') -ne 'Write') {
            $name = if ($match.Count -ge 1) { [string](Get-KnownGoodField -Entry $match[0] -Name 'Name') } elseif ($wanted -eq 'GpuSteering') { 'GPU interrupt steering' } else { $wanted }
            return [pscustomobject]@{ Allowed = $false; Error = ('Refused: the app does not offer {0} on this PC, so it does not write it. Nothing was changed.' -f $name); Item = $null }
        }
        $chosen.Add($match[0])
    }
    return [pscustomobject]@{ Allowed = $true; Error = $null; Item = @($chosen.ToArray()) }
}

function Get-TuningPlan {
    <#
        .SYNOPSIS
        The ordered plan for ApplyTuning: one step per item, Skip when the item
        already reads as its target. -Only limits it to named Ids.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Item,
        [Parameter(Mandatory)] [hashtable] $Fact,
        [string[]] $Only,
        # -Force writes a value that already reads as its target. The self-test
        # uses it for the MPO round trip: write the value that is already there,
        # then undo it, and prove the pair works on real Windows.
        [switch] $Force
    )

    $wanted = @($Item)
    if ($Only) { $wanted = @($wanted | Where-Object { $Only -contains $_.Id }) }

    $seq = 0
    $steps = foreach ($it in $wanted) {
        $seq++
        $now = Get-TuningNowValue -Item $it -Fact $Fact
        $op = switch ($it.Kind) {
            'Registry' { 'SetRegistryValue' }
            'PowerPlan' { 'SetPowerPlan' }
            'GpuSteering' { 'SetGpuAffinity' }
            default { 'Unknown' }
        }
        $atTarget = if ($Force) { $false } else { switch ($it.Kind) {
            'Registry' { ($null -ne $now) -and ([string]$now -eq [string]$it.Target) }
            'PowerPlan' { ($null -ne $now) -and ($now -eq $it.Target) }
            'GpuSteering' { ($null -ne $now) -and ($now -eq $it.Target) }
            default { $false }
        } }
        [pscustomobject]@{
            Seq           = $seq
            Id            = $it.Id
            Name          = $it.Name
            Kind          = $it.Kind
            Op            = $(if ($atTarget) { 'Skip' } else { $op })
            Arg           = @{ Path = $it.Path; Value = $it.Value; Data = $it.Target; RegType = $it.RegType }
            Now           = $now
            Target        = $it.Target
            RestartNeeded = $it.RestartNeeded
            Reason        = $(if ($atTarget) { 'already at the target value' } else { 'writes the known-good value' })
        }
    }

    return , @($steps)
}

function Build-TuningSnapshot {
    <#
        .SYNOPSIS
        The simrig.tuning-snapshot/1 document: what every tuning item read as
        before the first write. UndoTuning replays it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Item,
        [Parameter(Mandatory)] [hashtable] $Fact,
        [Parameter(Mandatory)] [datetime] $TakenAt,
        [Parameter(Mandatory)] [string] $SessionId
    )

    # Name: for text 50 of an Undo (push 2 of the unit tune, step 5). Wrote: the value that an
    # Apply wrote, $null until a step of an Apply is Done (Set-SimRigTuningWrote).
    $rows = foreach ($it in @($Item)) {
        [pscustomobject]@{
            Id      = $it.Id
            Name    = $it.Name
            Kind    = $it.Kind
            Path    = $it.Path
            Value   = $it.Value
            RegType = $it.RegType
            Was     = Get-TuningNowValue -Item $it -Fact $Fact
            Wrote   = $null
        }
    }

    return [ordered]@{
        Schema    = 'simrig.tuning-snapshot/1'
        SessionId = $SessionId
        TakenAt   = Format-SimRigTime -Time $TakenAt
        Items     = @($rows)
    }
}

function Merge-SimRigTuningSnapshot {
    <#
        Push 2 of the unit tune, step 5 (design section 5). Pure. The snapshot of record: each row
        that an Apply wrote stays; a later Apply adds the items that are not in it yet and replaces the
        rows that no Apply wrote yet, so Undo puts back the values from before the first write of each
        item. With no record, the new snapshot is the record.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Record, [Parameter(Mandatory)] $New)

    if ($null -eq $Record) { return $New }
    # The design change of section 5 after the REVIEW at 20405c6 (finding 18; Rick's "Yes",
    # 2026-10-04): a row of the record that no Apply wrote yet (Wrote $null) takes the row of the new
    # snapshot, so Was is the value from before the first write of that item. A row that an Apply wrote
    # stays as it is.
    $newById = @{}
    foreach ($row in @(Get-KnownGoodField -Entry $New -Name 'Items')) { $newById[[string](Get-KnownGoodField -Entry $row -Name 'Id')] = $row }
    $kept = foreach ($row in @(Get-KnownGoodField -Entry $Record -Name 'Items')) {
        $id = [string](Get-KnownGoodField -Entry $row -Name 'Id')
        if ($null -eq (Get-KnownGoodField -Entry $row -Name 'Wrote') -and $newById.ContainsKey($id)) { $newById[$id] } else { $row }
    }
    $have = @(@(Get-KnownGoodField -Entry $Record -Name 'Items') | ForEach-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Id') })
    $added = @(@(Get-KnownGoodField -Entry $New -Name 'Items') | Where-Object { $have -notcontains [string](Get-KnownGoodField -Entry $_ -Name 'Id') })
    return [ordered]@{
        Schema    = 'simrig.tuning-snapshot/1'
        SessionId = Get-KnownGoodField -Entry $Record -Name 'SessionId'
        TakenAt   = Get-KnownGoodField -Entry $Record -Name 'TakenAt'
        Items     = @(@($kept) + $added)
    }
}

function Set-SimRigTuningWrote {
    <#
        Push 2 of the unit tune, step 5. Pure: returns a new snapshot and changes no state. Each row whose
        Id is in DoneId gets Wrote, the target of its item: the value that the Apply wrote. Undo writes an
        item only when its value now is that value (Get-TuningUndoPlan).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure: builds a new document, changes no system state')]
    param([Parameter(Mandatory)] $Snapshot, [AllowEmptyCollection()] [object[]] $Item, [AllowEmptyCollection()] [string[]] $DoneId)

    $targetById = @{}
    foreach ($it in @($Item)) { if ($null -ne $it) { $targetById[[string](Get-KnownGoodField -Entry $it -Name 'Id')] = Get-KnownGoodField -Entry $it -Name 'Target' } }
    $rows = foreach ($row in @(Get-KnownGoodField -Entry $Snapshot -Name 'Items')) {
        $id = [string](Get-KnownGoodField -Entry $row -Name 'Id')
        $wrote = Get-KnownGoodField -Entry $row -Name 'Wrote'
        if (@($DoneId) -contains $id -and $targetById.ContainsKey($id)) { $wrote = $targetById[$id] }
        [pscustomobject]@{
            Id = $id; Name = Get-KnownGoodField -Entry $row -Name 'Name'; Kind = Get-KnownGoodField -Entry $row -Name 'Kind'
            Path = Get-KnownGoodField -Entry $row -Name 'Path'; Value = Get-KnownGoodField -Entry $row -Name 'Value'
            RegType = Get-KnownGoodField -Entry $row -Name 'RegType'; Was = Get-KnownGoodField -Entry $row -Name 'Was'; Wrote = $wrote
        }
    }
    return [ordered]@{
        Schema    = 'simrig.tuning-snapshot/1'
        SessionId = Get-KnownGoodField -Entry $Snapshot -Name 'SessionId'
        TakenAt   = Get-KnownGoodField -Entry $Snapshot -Name 'TakenAt'
        Items     = @($rows)
    }
}

function Build-SimRigTuningMarker {
    <#
        Push 2 of the unit tune, step 5 (design section 5). Pure. The marker tuning-applied.json: the
        path of the snapshot of record and the time of the first Apply. The console reads it at start, and
        the child reads it for an Undo with no session folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SnapshotPath, [Parameter(Mandatory)] [datetime] $AppliedAt)
    return [ordered]@{
        Schema       = 'simrig.tuning-marker/1'
        SnapshotPath = $SnapshotPath
        AppliedAt    = Format-SimRigTime -Time $AppliedAt
    }
}

function Get-SimRigActionOutcome {
    <#
        beta1-fix D-B. Pure. What a run of Apply tuning, Undo tuning or Fix GPU steering did, for its banner:
        - Failed: a failure text of the window (Get-ActionFailureText), no result, or an exit that is not 0. Text:
          the failure text, else the errors of the run.
        - NothingWritten: exit 0 and no step with the status Done.
        - Written: exit 0 and one or more steps with the status Done.
        Before, exit 1 (StepFailed) had no failure text, and the window showed the success banner (beta.1 rig run,
        2026-10-13: "Tuning applied. Written and read back" on exit 1 with no value written).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()] $Result, [AllowNull()] [string] $Failure)

    $exit = if ($null -ne $Result) { Get-KnownGoodField -Entry $Result -Name 'ExitCode' } else { $null }
    if ($Failure -or $null -eq $Result -or $null -eq $exit -or [int]$exit -ne (Get-ActionExitCode).Done) {
        $text = if ($Failure) { $Failure } elseif ($null -ne $Result) { (@(Get-KnownGoodField -Entry $Result -Name 'Errors') | Where-Object { $_ }) -join ' ' } else { '' }
        return [pscustomobject]@{ State = 'Failed'; Text = [string]$text }
    }
    $done = @(@(Get-KnownGoodField -Entry $Result -Name 'Steps') | Where-Object { $null -ne $_ -and [string](Get-KnownGoodField -Entry $_ -Name 'Status') -eq 'Done' })
    return [pscustomobject]@{ State = $(if ($done.Count -gt 0) { 'Written' } else { 'NothingWritten' }); Text = '' }
}

function Get-SimRigTuningListText {
    <#
        Pure. The {list} of a banner about tuning items: the name of each id, joined with a comma; with more
        than three, the count (the rule of the unit rf3: the rows of the window have the names). Before
        beta1-fix, Get-SimRigTuningDoneText had this table; texts D3 and D4 use it too.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()] [string[]] $Id)

    $label = @{
        Mpo = 'MPO (Multiplane Overlay)'; Hags = 'HAGS (hardware-accelerated GPU scheduling)'
        PowerPlan = 'Power plan'; GpuSteering = 'GPU interrupt steering'
    }
    $names = @(@($Id) | Where-Object { $_ } | ForEach-Object { if ($label.ContainsKey($_)) { $label[$_] } else { $_ } })
    if ($names.Count -gt 3) { return ('{0} items' -f $names.Count) }
    return ($names -join ', ')
}

function Select-SimRigReadBackStep {
    <#
        beta1-fix, the repair of REVIEW-beta1-fix-da52408.md findings 1 and 2 (APPROVALS-RICK-2026-10-14-1545 item 1).
        Pure. The steps of Step that have a read-back row in Result that matches: a step of the FixGpu writer
        (SetGpuAffinity) by its own id (Gpu:...), each other step by Tuning:<Id>. An item counts as written or put back
        only when it has a Done step AND reads back: a Done write that something changed before the read-back does not
        read back, and Undo leaves such an item (Get-TuningUndoPlan, text 50).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowNull()] $Result, [AllowNull()] [AllowEmptyCollection()] [object[]] $Step)

    $matched = @(@(Get-KnownGoodField -Entry $Result -Name 'ReadBack') | Where-Object { $null -ne $_ -and (Get-KnownGoodField -Entry $_ -Name 'Match') -eq $true } |
            ForEach-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Id') })
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($one in @($Step)) {
        if ($null -eq $one) { continue }
        $id = [string](Get-KnownGoodField -Entry $one -Name 'Id')
        $rowId = if ([string](Get-KnownGoodField -Entry $one -Name 'Op') -eq 'SetGpuAffinity') { $id } else { 'Tuning:{0}' -f $id }
        if ($matched -contains $rowId) { $kept.Add($one) }
    }
    return , $kept.ToArray()
}

function Test-SimRigTuningRecordHoldsRun {
    <#
        beta1-fix, text D3 (APPROVALS-RICK-2026-10-14-0530 item 2, the T1 lesson). Pure. True only when the
        record that the marker names is the snapshot of this run, and each item that this run wrote (a step of
        the source tuning with the status Done) has a row in it whose Wrote is the value of this run (the
        Expected of its read-back row). Undo writes an item from Wrote only (Get-TuningUndoPlan), so "Undo tuning
        puts them back" is true only then. A record that the child did not write again after the steps (a fatal
        error between the steps and the write) still has the Wrote of an earlier Apply, or none.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] $Marker, [AllowNull()] $Record, [AllowNull()] $Result)

    $path = [string](Get-KnownGoodField -Entry $Marker -Name 'SnapshotPath')
    if (-not $path -or $path -ne [string](Get-KnownGoodField -Entry $Result -Name 'SnapshotPath')) { return $false }
    $rows = @(@(Get-KnownGoodField -Entry $Record -Name 'Items') | Where-Object { $null -ne $_ })
    $readBack = @(@(Get-KnownGoodField -Entry $Result -Name 'ReadBack') | Where-Object { $null -ne $_ })
    $doneId = @(@(Get-KnownGoodField -Entry $Result -Name 'Steps') | Where-Object { $null -ne $_ -and [string](Get-KnownGoodField -Entry $_ -Name 'Source') -eq 'tuning' -and [string](Get-KnownGoodField -Entry $_ -Name 'Status') -eq 'Done' } |
            ForEach-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Id') })
    if ($doneId.Count -eq 0) { return $false }
    foreach ($id in $doneId) {
        $row = @($rows | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Id') -eq $id })
        if ($row.Count -ne 1) { return $false }
        $wrote = Get-KnownGoodField -Entry $row[0] -Name 'Wrote'
        if ($null -eq $wrote) { return $false }
        $rb = @($readBack | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Id') -eq ('Tuning:{0}' -f $id) })
        if ($rb.Count -ne 1 -or [string]$wrote -ne [string](Get-KnownGoodField -Entry $rb[0] -Name 'Expected')) { return $false }
        # REVIEW-beta1-fix-da52408.md finding 1: Undo puts an item back only when its value now is Wrote.
        if ((Get-KnownGoodField -Entry $rb[0] -Name 'Match') -ne $true) { return $false }
    }
    return $true
}

function Get-SimRigActionFailText {
    <#
        beta1-fix, texts D2, D3 and D4 of REQUEST-beta1-fix-fd79445.md (APPROVALS-RICK-2026-10-14-0530 item 2,
        Rick's "yes 0530"). Pure. The red banner of a run of Apply tuning, Undo tuning or Fix GPU steering that
        took the failure path (Get-SimRigActionOutcome). Each text only on a path where each of its sentences is
        true:
        - A failure text of the window (no usable result, a refusal, a fatal error): the title and that text, as
          before. A refusal keeps its own text.
        - D2: no step with the status Done, no step that Failed or was Refused (a failed step can leave a part of
          a write: a new key, or DevicePolicy with no mask), no error text of the child, and one or more rows.
        - D3 (Apply): one or more values written (a Done step that is not a device restart). "Undo tuning puts
          them back." only when the marker is there after the run, the record holds the values of this run
          (Test-SimRigTuningRecordHoldsRun), and GPU steering is not one of them. The steering sentence only
          when GPU steering is the only value written. The error text of the child follows.
        - D4 (Undo): one or more values put back, and the marker is there after the run (Undo can be run again).
          The error text of the child follows.
        - Each other path: the title and the error text of the child, as before.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateSet('Apply', 'Undo', 'FixGpu')] [string] $Operation,
        [AllowNull()] $Result,
        [AllowNull()] [string] $Failure,
        [bool] $MarkerPresent,
        [AllowNull()] $Marker,
        [AllowNull()] $Record
    )

    $title = @{ Apply = 'Tuning not applied'; Undo = 'Tuning not undone'; FixGpu = 'GPU steering not fixed' }[$Operation]
    $outcome = Get-SimRigActionOutcome -Result $Result -Failure $Failure
    $childText = [string]$outcome.Text
    $plain = [pscustomobject]@{ Title = $title; Text = $childText }
    if ($outcome.State -ne 'Failed' -or $Failure -or $null -eq $Result) { return $plain }

    $steps =@(@(Get-KnownGoodField -Entry $Result -Name 'Steps') | Where-Object { $null -ne $_ })
    $source = if ($Operation -eq 'Undo') { 'tuning-undo' } else { $null }
    $doneStep = @($steps | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Status') -eq 'Done' -and [string](Get-KnownGoodField -Entry $_ -Name 'Op') -ne 'RestartDevice' -and
            (-not $source -or [string](Get-KnownGoodField -Entry $_ -Name 'Source') -eq $source) })
    # REVIEW-beta1-fix-da52408.md findings 1 and 2: written or put back = a Done step AND a read-back row that matches.
    $written = Select-SimRigReadBackStep -Result $Result -Step $doneStep

    if ($doneStep.Count -gt 0 -and $written.Count -eq 0) { return $plain }
    if ($written.Count -eq 0) {
        $badStep = @($steps | Where-Object { @('Failed', 'Refused') -contains [string](Get-KnownGoodField -Entry $_ -Name 'Status') })
        $rows = @(@(Get-KnownGoodField -Entry $Result -Name 'ReadBack') | Where-Object { $null -ne $_ })
        # Text D2.
        if ($badStep.Count -eq 0 -and -not $childText -and $rows.Count -gt 0) { return [pscustomobject]@{ Title = $title; Text = 'Nothing was changed. The rows above show each check.' } }
        return $plain
    }
    if ($Operation -eq 'FixGpu') { return $plain }

    $id = [System.Collections.Generic.List[string]]::new()
    foreach ($step in $written) {
        $one = if ([string](Get-KnownGoodField -Entry $step -Name 'Op') -eq 'SetGpuAffinity') { 'GpuSteering' } else { [string](Get-KnownGoodField -Entry $step -Name 'Id') }
        if (-not $id.Contains($one)) { $id.Add($one) }
    }
    $list = Get-SimRigTuningListText -Id $id.ToArray()
    $parts = [System.Collections.Generic.List[string]]::new()

    if ($Operation -eq 'Undo') {
        if (-not $MarkerPresent) { return $plain }
        # REVIEW-beta1-fix-da52408.md finding 2: an item that the plan left with text 50 has no read-back row, so "The
        # rows above show what is not back." would be false.
        if (@($steps | Where-Object { ([string](Get-KnownGoodField -Entry $_ -Name 'Message')).StartsWith('Not put back: ') }).Count -gt 0) { return $plain }
        # Text D4.
        $parts.Add(('Put back: {0}. The rows above show what is not back. Undo tuning can be run again.' -f $list))
        if ($childText) { $parts.Add($childText) }
        return [pscustomobject]@{ Title = 'Tuning undone in part'; Text = ($parts -join ' ') }
    }

    # Text D3.
    $tuningDone = @($written | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Source') -eq 'tuning' })
    $steeringDone = @($written | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Op') -eq 'SetGpuAffinity' })
    $parts.Add(('Some values were changed: {0}. The rows above show each one.' -f $list))
    if ($tuningDone.Count -gt 0 -and $steeringDone.Count -eq 0 -and $MarkerPresent -and (Test-SimRigTuningRecordHoldsRun -Marker $Marker -Record $Record -Result $Result)) {
        $parts.Add('Undo tuning puts them back.')
    }
    elseif ($tuningDone.Count -eq 0 -and $steeringDone.Count -gt 0) {
        $parts.Add('Undo tuning does not put GPU interrupt steering back.')
    }
    if ($childText) { $parts.Add($childText) }
    return [pscustomobject]@{ Title = 'Tuning applied in part'; Text = ($parts -join ' ') }
}

function Get-SimRigTuningDoneText {
    <#
        Push 2 of the unit tune, step 7c. Pure. The banner of a green Apply tuning (text 18) or Undo
        tuning (text 20), made from the result of the run (the rule of the unit qfilter: a text about a
        run comes from that run):
        - {list}: the items of the read-back that match, by the names of the tuning items; with more
          than three, the count, and the rows of the window have the names (the rule of the unit rf3).
        - Apply: text 18; the restart sentence when HAGS is in the list; text 7 when GPU steering is in
          the list (the rig), because "Undo tuning puts these values back" is not true for steering.
        - Undo: text 20; text 50 for each step of the run that left an item (the child wrote it); text
          51 when HAGS was put back; text 7 when the run has a step for GPU steering (the rig).
        HandFile: the path of UNDO-BY-HAND.txt beside the snapshot, for a row and the log, never for the
        banner (the Cowork answer to the texts of push 2).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [ValidateSet('Apply', 'Undo')] [string] $Operation, [AllowNull()] $Result)

    # beta1-fix, text D1: the rows of the tuning items only. The Apply on the rig also has a row for each NVIDIA
    # function (Gpu:...), from the FixGpu writer; those are not tuning items, and their ids are not names.
    $ids = @(@(Get-KnownGoodField -Entry $Result -Name 'ReadBack') | Where-Object { $null -ne $_ -and (Get-KnownGoodField -Entry $_ -Name 'Match') -eq $true -and ([string](Get-KnownGoodField -Entry $_ -Name 'Id')).StartsWith('Tuning:') } |
            ForEach-Object { ([string](Get-KnownGoodField -Entry $_ -Name 'Id')) -replace '^Tuning:', '' })
    $names = @($ids)
    $list = Get-SimRigTuningListText -Id $ids
    $steps = @(@(Get-KnownGoodField -Entry $Result -Name 'Steps') | Where-Object { $null -ne $_ })
    $noSteering = 'Undo tuning does not put GPU interrupt steering back.'
    $parts = [System.Collections.Generic.List[string]]::new()

    if ($Operation -eq 'Apply') {
        if ($names.Count -gt 0) { $parts.Add(('Written and read back: {0}.' -f $list)) }
        if ($ids -contains 'Hags') { $parts.Add(('Restart Windows before this change takes effect: {0}.' -f (Get-SimRigTuningListText -Id @('Hags')))) }
        # beta1-fix, text D1 (APPROVALS-RICK-2026-10-14-0530 item 2): the two sentences about Undo only when the run
        # wrote an item that Undo puts back (a step of the source tuning with the status Done). A run that wrote GPU
        # steering only writes no marker, and Undo does not put steering back (Limit 1 of the unit).
        # REVIEW-beta1-fix-da52408.md finding 1, the same class: the Done step must also read back.
        $undoable = Select-SimRigReadBackStep -Result $Result -Step @($steps | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Source') -eq 'tuning' -and [string](Get-KnownGoodField -Entry $_ -Name 'Status') -eq 'Done' })
        if ($undoable.Count -gt 0) { $parts.Add('Undo tuning puts these values back. The file UNDO-BY-HAND.txt, beside the snapshot, has the commands to undo them by hand.') }
        if ($ids -contains 'GpuSteering') { $parts.Add($noSteering) }
        $snapshot = [string](Get-KnownGoodField -Entry $Result -Name 'SnapshotPath')
        $handFile = if ($snapshot -and $snapshot.Contains('\')) { $snapshot.Substring(0, $snapshot.LastIndexOf('\')) + '\UNDO-BY-HAND.txt' } else { $null }
        return [pscustomobject]@{ Title = 'Tuning applied'; Text = ($parts -join ' '); HandFile = $handFile }
    }

    if ($names.Count -gt 0) { $parts.Add(('Put back and read back: {0}.' -f $list)) }
    foreach ($step in $steps) {
        $message = [string](Get-KnownGoodField -Entry $step -Name 'Message')
        if ($message.StartsWith('Not put back: ')) { $parts.Add($message) }
    }
    if ($ids -contains 'Hags') { $parts.Add('Restart Windows before HAGS is back at its old value.') }
    if (@($steps | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Id') -eq 'GpuSteering' }).Count -gt 0) { $parts.Add($noSteering) }
    return [pscustomobject]@{ Title = 'Tuning undone'; Text = ($parts -join ' '); HandFile = $null }
}

function Get-SimRigUndoTuningStart {
    <#
        Push 2 of the unit tune, step 7 (design section 5). Pure. What the window does when Undo tuning is
        pressed, from the marker file, so that Undo works also after the app was closed:
        - no marker file: text 19, and no elevated step;
        - a marker that cannot be read (not JSON, no SnapshotPath, or an AppliedAt that is not the time that
          Build-SimRigTuningMarker writes): text 52 with the path of the marker, and no elevated step;
        - else the elevated step, with text 49 as the subtitle. The child reads the marker again and
          decides; a snapshot of record that it cannot read gives text 52 there.
        The texts are rows 19, 49 and 52 of PUSH2-TEXTS-FOR-RICK-2026-10-03.md (Rick's "Yes").
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [bool] $MarkerPresent,
        [AllowNull()] $Marker,
        [Parameter(Mandatory)] [string] $MarkerPath
    )

    if (-not $MarkerPresent) {
        return [pscustomobject]@{
            Start = $false; Kind = 'Warn'; Title = 'Nothing to undo'; Subtitle = $null
            # Text 19, changed by beta1-texts (draft T19, Rick's "yes 1300", 2026-10-15): after an Apply that wrote GPU
            # steering only there is no marker, and Undo does not put steering back (text 7).
            Text  = 'This app has no record of tuning that Undo tuning can put back, so there is nothing to undo. Undo tuning does not put GPU interrupt steering back.'
        }
    }
    $snapshotPath = [string](Get-KnownGoodField -Entry $Marker -Name 'SnapshotPath')
    $appliedAt = [string](Get-KnownGoodField -Entry $Marker -Name 'AppliedAt')
    if ([string]::IsNullOrWhiteSpace($snapshotPath) -or $appliedAt -notmatch '^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}):\d{2}') {
        return [pscustomobject]@{
            Start = $false; Kind = 'Bad'; Title = 'Tuning not undone'; Subtitle = $null
            # Text 52; its last sentence changed by blocker 6, open row O6 (Rick's "Yes", 2026-10-07).
            Text  = ('Undo tuning cannot read the record of the last Apply ({0}). Nothing was changed. The file UNDO-BY-HAND.txt in the same folder has the commands to undo it by hand. Read each line before you run it: another program can change that file.' -f $MarkerPath)
        }
    }
    return [pscustomobject]@{
        Start = $true; Kind = $null; Title = $null; Text = $null
        Subtitle = ('Putting back the values from before Apply tuning on {0} {1}. Approve the Windows prompt.' -f $Matches[1], $Matches[2])
    }
}

function Build-SimRigUndoByHandText {
    <#
        Push 2 of the unit tune, step 6 (design section 5, texts 57 to 61 of PUSH2-TEXTS-FOR-RICK-2026-10-03.md).
        Pure. The text of UNDO-BY-HAND.txt: the commands that put back each item that an Apply wrote, or
        is about to write (-WriteId), from the snapshot of record. Only a Registry or a PowerPlan row has a
        line, so GPU steering has none: Undo does not put it back. A registry item that is not an HKLM DWORD throws, so that the Apply writes nothing
        when the file cannot say how to undo an item. Lines end with CRLF: the file is for a Command Prompt.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Snapshot,
        [Parameter(Mandatory)] [string] $SnapshotPath,
        [Parameter(Mandatory)] [datetime] $WrittenAt,
        [AllowEmptyCollection()] [string[]] $WriteId
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    # Text 57.
    $lines.Add('REM SimRig Console - undo tuning by hand.')
    $lines.Add(('REM Written {0} by Apply tuning. Snapshot: {1}.' -f (Format-SimRigTime -Time $WrittenAt), $SnapshotPath))
    $lines.Add('REM Use these commands only when the app does not start. In the app, use Undo tuning.')
    $lines.Add('REM Open a Command Prompt as administrator, then run each line below.')
    foreach ($row in @(Get-KnownGoodField -Entry $Snapshot -Name 'Items')) {
        $id = [string](Get-KnownGoodField -Entry $row -Name 'Id')
        $kind = [string](Get-KnownGoodField -Entry $row -Name 'Kind')
        if ($null -eq (Get-KnownGoodField -Entry $row -Name 'Wrote') -and @($WriteId) -notcontains $id) { continue }
        $name = Get-KnownGoodField -Entry $row -Name 'Name'
        if (-not $name) { $name = $id }
        $was = Get-KnownGoodField -Entry $row -Name 'Was'
        if ($kind -eq 'Registry') {
            $path = [string](Get-KnownGoodField -Entry $row -Name 'Path')
            $type = [string](Get-KnownGoodField -Entry $row -Name 'RegType')
            if (-not $path.StartsWith('HKLM:\') -or $type -ne 'DWord') {
                throw ('UNDO-BY-HAND.txt has no command for {0}: {1} is not an HKLM DWORD value.' -f $id, $path)
            }
            $regPath = 'HKLM\' + $path.Substring(6)
            $value = [string](Get-KnownGoodField -Entry $row -Name 'Value')
            if ($null -eq $was) {
                # Text 59.
                $lines.Add(('REM {0}: the value was not set before, so remove it.' -f $name))
                $lines.Add(('reg delete "{0}" /v {1} /f' -f $regPath, $value))
            }
            else {
                # Text 58.
                $lines.Add(('REM {0}: put back the old value {1}.' -f $name, [string]$was))
                $lines.Add(('reg add "{0}" /v {1} /t REG_DWORD /d {2} /f' -f $regPath, $value, [string]$was))
            }
            # Text 60.
            if ($id -eq 'Hags') { $lines.Add('REM Restart Windows after this line, so that HAGS is back.') }
        }
        elseif ($kind -eq 'PowerPlan') {
            # No old plan was read: Undo has no plan to put back either.
            if ($null -eq $was) { continue }
            # Text 61.
            $lines.Add('REM Power plan: put back the old plan.')
            $lines.Add(('powercfg /setactive {0}' -f [string]$was))
        }
    }
    return (($lines -join "`r`n") + "`r`n")
}

function Get-TuningUndoPlan {
    <#
        .SYNOPSIS
        The plan that puts every tuning item back to its snapshot value. An
        item whose snapshot value is $null was not set before, so Undo removes
        the value rather than writing a zero.

        Push 2 of the unit tune, step 5: a row with the field Wrote is from this version. Wrote $null:
        no Apply wrote the item, so there is no step. With -Fact, an item whose value now is not the
        value that Apply wrote is left as it is, with text 50: the person or Windows changed it after
        the Apply (design section 5). A row with no field Wrote (a snapshot of v4.1) is put back as
        before.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Snapshot,
        [string[]] $Only,
        [AllowNull()] [hashtable] $Fact
    )

    $rows = @($Snapshot.Items)
    if ($Only) { $rows = @($rows | Where-Object { $Only -contains $_.Id }) }

    $seq = 0
    $steps = foreach ($row in $rows) {
        $hasWrote = if ($row -is [System.Collections.IDictionary]) { $row.Contains('Wrote') } else { $null -ne $row.PSObject.Properties['Wrote'] }
        if ($hasWrote) {
            $wrote = Get-KnownGoodField -Entry $row -Name 'Wrote'
            # GPU steering keeps its Skip step, so that the run says that Undo does not put it back.
            if ($null -eq $wrote -and $row.Kind -ne 'GpuSteering') { continue }
            if ($null -ne $Fact -and $row.Kind -ne 'GpuSteering') {
                $now = Get-TuningNowValue -Item $row -Fact $Fact
                if ([string]$now -ne [string]$wrote) {
                    $seq++
                    [pscustomobject]@{
                        Seq    = $seq
                        Id     = $row.Id
                        Kind   = $row.Kind
                        Op     = 'Skip'
                        Arg    = @{ Path = $row.Path; Value = $row.Value; Data = $row.Was; RegType = $row.RegType }
                        Target = $row.Was
                        # Text 50 of PUSH2-TEXTS-FOR-RICK-2026-10-03.md.
                        Reason = ('Not put back: {0}. Its value is now {1}, not the value that Apply wrote ({2}). Something changed it after Apply.' -f `
                                $(if ($row.Name) { $row.Name } else { $row.Id }), $(if ($null -eq $now) { 'not set' } else { [string]$now }), [string]$wrote)
                        ChangedAfterApply = $true
                    }
                    continue
                }
            }
        }
        $seq++
        $op = switch ($row.Kind) {
            'Registry' { if ($null -eq $row.Was) { 'RemoveRegistryValue' } else { 'SetRegistryValue' } }
            'PowerPlan' { 'SetPowerPlan' }
            'GpuSteering' { 'Skip' }
            default { 'Unknown' }
        }
        $reason = switch ($row.Kind) {
            # Text 53 of PUSH2-TEXTS-FOR-RICK-2026-10-03.md (Rick's "Yes").
            'GpuSteering' { 'Undo does not put GPU interrupt steering back.' }
            default { $(if ($null -eq $row.Was) { 'the value was not set before, so it is removed' } else { 'writes the snapshot value back' }) }
        }
        [pscustomobject]@{
            Seq    = $seq
            Id     = $row.Id
            Kind   = $row.Kind
            Op     = $op
            Arg    = @{ Path = $row.Path; Value = $row.Value; Data = $row.Was; RegType = $row.RegType }
            Target = $row.Was
            Reason = $reason
        }
    }

    return , @($steps)
}

function Test-SimRigTuningRecordPath {
    <#
        Blocker 6 (work list step 5c; VERDICT-tune-835d7e0.md, answer 3). Pure. True when Path is a
        tuning-snapshot.json in the sessions folder of the app, or in folders under it, each with a plain
        name. The elevated Apply and Undo read and write the record at this path, and a marker or a
        -SessionDir names it, so the elevated step decides (amendment 7a). Both separators are read as
        one, as Windows does.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $Path,
        # Commit 8 of the unit (REVIEW-blocker6-994c5a7.md, finding 1; Rick's "Yes", 2026-10-07): the fixed
        # roots, each in the data folder of the app. The child gives the sessions folder and Logs\v4\selftest,
        # where the self-test keeps its tuning dry run and its round trip. A path is accepted under one of them.
        [Parameter(Mandatory)] [string[]] $Sessions,
        # Blocker 7 (O2), Restore: the snapshot of a quiet session is snapshot.json. The tuning record is the default.
        [ValidateSet('tuning-snapshot.json', 'snapshot.json')] [string] $FileName = 'tuning-snapshot.json'
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.Replace('/', '\')
    foreach ($root in @($Sessions)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $s = $root.Replace('/', '\').TrimEnd('\') + '\'
        if (-not $p.StartsWith($s, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $part = @($p.Substring($s.Length).Split('\'))
        if ($part[-1] -cne $FileName) { return $false }
        foreach ($name in @($part | Select-Object -SkipLast 1)) {
            # No empty name, no . or .., no name that Windows trims (a dot or a space at the end).
            if ($name -notmatch '^[A-Za-z0-9_-][A-Za-z0-9_. -]*$' -or $name -match '[. ]$') { return $false }
        }
        return $true
    }
    return $false
}

function Find-SimRigTuningRecordBadRow {
    <#
        Blocker 6 (work list step 5c; VERDICT-tune-835d7e0.md, answer 3). Pure. The number (from 1) of
        the first row of a tuning record that the app does not write on this PC, or 0 when each row is
        one that it writes. Known is the registry items that the app writes, made by the elevated child
        from known-good.psd1 and the rules in the program folder (condition A of 2026-10-07).
        - Registry: Id, Kind, Path, Value and RegType of a known item; Was and Wrote a DWORD number or
          not set.
        - PowerPlan: the Id PowerPlan, no Path, Value or RegType; Was and Wrote a GUID or not set.
        - GpuSteering: the Id GpuSteering. Undo does not write it (text 53).
        Any other row fails. The caller checks each row before the first write.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)] $Record, [AllowEmptyCollection()] [object[]] $Known)

    $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $n = 0
    foreach ($row in @(Get-KnownGoodField -Entry $Record -Name 'Items')) {
        $n++
        if ($null -eq $row) { return $n }
        $id = [string](Get-KnownGoodField -Entry $row -Name 'Id')
        $kind = [string](Get-KnownGoodField -Entry $row -Name 'Kind')
        $data = @((Get-KnownGoodField -Entry $row -Name 'Was'), (Get-KnownGoodField -Entry $row -Name 'Wrote'))
        $path = Get-KnownGoodField -Entry $row -Name 'Path'
        $value = Get-KnownGoodField -Entry $row -Name 'Value'
        $regType = Get-KnownGoodField -Entry $row -Name 'RegType'
        $ok = $false
        if ($kind -eq 'Registry') {
            $match = @(@($Known) | Where-Object {
                    $null -ne $_ -and [string]$_.Kind -eq 'Registry' -and [string]$_.Id -eq $id -and
                    [string]$_.Path -eq [string]$path -and [string]$_.Value -eq [string]$value -and [string]$_.RegType -eq [string]$regType
                })
            $ok = ($match.Count -ge 1)
            foreach ($d in $data) {
                if ($null -eq $d) { continue }
                if (-not ($d -is [int] -or $d -is [long]) -or [long]$d -lt 0 -or [long]$d -gt 4294967295) { $ok = $false }
            }
        }
        elseif ($kind -eq 'PowerPlan') {
            $ok = ($id -eq 'PowerPlan' -and $null -eq $path -and $null -eq $value -and $null -eq $regType)
            foreach ($d in $data) { if ($null -ne $d -and ([string]$d -notmatch $guid -or $d -isnot [string])) { $ok = $false } }
        }
        elseif ($kind -eq 'GpuSteering') {
            $ok = ($id -eq 'GpuSteering')
        }
        if (-not $ok) { return $n }
    }
    return 0
}

function Build-SimRigSteeringRecord {
    <#
        .SYNOPSIS
        One line of the steering history: what every present NVIDIA function's
        interrupt steering looked like at this console start, and on which boot.

        .DESCRIPTION
        This settles a question the build has been designing around without
        evidence. On 2026-09-20 Fable's F.3 finding 1 said the NVIDIA PCI instance
        ids change at every boot on this rig, so a written policy is orphaned by
        the next restart. The console has applied the fix at every start since,
        which costs a confirm dialog and a Windows prompt before the racer has
        clicked anything, on every boot.

        It was one observation. The self-test of 2026-09-28 20:19, taken after a
        reboot, found both functions steered on instances 4&1BABDF5B&0&0009 and
        ...&0109. That does not fit. Either the ids are stable now, or they move
        only after a Windows Update, or the orphan check is wrong - and those need
        three different fixes.

        So the record keeps the INSTANCE ID, not only the policy. An id that moved
        and a policy that was cleared look identical from the outside and call for
        opposite answers.

        Pure: the caller reads the affinity rows and the boot time and appends what
        this returns.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Affinity,
        [Parameter(Mandatory)] [datetime] $TakenAt,
        [AllowNull()] [object] $BootAt,
        [string] $Scope = '',
        [bool] $Orphaned = $false
    )

    $function = foreach ($row in @($Affinity | Where-Object { $null -ne $_ })) {
        $mask = Get-KnownGoodField -Entry $row -Name 'AssignmentSetOverride'
        [ordered]@{
            InstanceId = [string](Get-KnownGoodField -Entry $row -Name 'InstanceId')
            DeviceId   = [string](Get-KnownGoodField -Entry $row -Name 'DeviceId')
            Policy     = Get-KnownGoodField -Entry $row -Name 'DevicePolicy'
            Mask       = $(if ($null -eq $mask) { $null } else { ('0x{0:X}' -f [uint64]$mask) })
        }
    }

    $bootText = ''
    if ($BootAt -is [datetime]) { $bootText = $BootAt.ToString('o') }
    elseif ($null -ne $BootAt) { $bootText = [string]$BootAt }

    return [ordered]@{
        Schema   = 'simrig.steering-history/1'
        TakenAt  = $TakenAt.ToString('o')
        BootAt   = $bootText
        Scope    = $Scope
        Orphaned = $Orphaned
        Function = @($function)
    }
}

function Get-SimRigSteeringHistoryVerdict {
    <#
        .SYNOPSIS
        What the history says in one sentence: the ids move between boots, the
        policy is cleared, or neither - in which case the orphan check is wrong.

        .DESCRIPTION
        Pure, so the self-test can print the answer with no rig present. It needs
        two DIFFERENT boots before it will say anything: two console starts on one
        boot prove nothing about what a restart does.

        Each boot is judged by its FIRST start. A later start on the same boot sees
        the work the console itself did, and reading that as evidence would prove
        steering always survives - which is the app marking its own homework.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()] [AllowEmptyCollection()] [object[]] $Record)

    $rows = @($Record | Where-Object { $null -ne $_ })
    $boots = @($rows | ForEach-Object { [string](Get-KnownGoodField -Entry $_ -Name 'BootAt') } |
            Where-Object { $_ } | Sort-Object -Unique)

    if ($boots.Count -lt 2) {
        return [pscustomobject]@{
            Verdict = 'NotEnough'
            Boots   = $boots.Count
            Line    = ('{0} boot(s) recorded. Two different boots are needed before this says anything.' -f $boots.Count)
        }
    }

    $firstPerBoot = foreach ($boot in $boots) {
        $onThisBoot = @($rows | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'BootAt') -eq $boot })
        $sorted = @($onThisBoot | Sort-Object -Property { [string](Get-KnownGoodField -Entry $_ -Name 'TakenAt') })
        $sorted[0]
    }

    $idSets = foreach ($row in @($firstPerBoot)) {
        $ids = @(@(Get-KnownGoodField -Entry $row -Name 'Function') |
                ForEach-Object { [string](Get-KnownGoodField -Entry $_ -Name 'InstanceId') } | Sort-Object)
        ($ids -join '|')
    }
    $idsMove = (@($idSets | Sort-Object -Unique).Count -gt 1)

    $everyBootSteered = $true
    foreach ($row in @($firstPerBoot)) {
        foreach ($item in @(Get-KnownGoodField -Entry $row -Name 'Function')) {
            $policy = Get-KnownGoodField -Entry $item -Name 'Policy'
            $mask = [string](Get-KnownGoodField -Entry $item -Name 'Mask')
            if ([string]$policy -ne '4' -or [string]::IsNullOrWhiteSpace($mask)) { $everyBootSteered = $false }
        }
    }

    if ($idsMove) {
        return [pscustomobject]@{
            Verdict = 'IdsMove'
            Boots   = $boots.Count
            Line    = ('The instance ids differ between boots ({0} recorded). A written policy cannot survive that: the registry key is named after the device instance, so re-applying at start is the only way.' -f $boots.Count)
        }
    }
    if ($everyBootSteered) {
        return [pscustomobject]@{
            Verdict = 'Survives'
            Boots   = $boots.Count
            Line    = ('Same instance ids, and the policy was already set on every recorded boot ({0}). Steering survives restarts on this machine, so the fix at every start is not needed.' -f $boots.Count)
        }
    }
    return [pscustomobject]@{
        Verdict = 'PolicyCleared'
        Boots   = $boots.Count
        Line    = ('Same instance ids, but the policy was missing on at least one boot of {0}. Something clears the value itself - a driver service or Windows - rather than re-enumerating the device.' -f $boots.Count)
    }
}

function Test-GpuSteeringOrphaned {
    <#
        .SYNOPSIS
        True when the preflight rows say the GPU interrupt steering is missing
        or different on at least one present device.

        .DESCRIPTION
        v4.1, Rick's decision 2026-09-20 (Fable F.3 finding 1): the NVIDIA PCI
        instance IDs changed at every boot on the rig after a Windows Update, so
        a written policy is orphaned by the next restart and the rig raced
        unsteered until someone clicked Fix. The console asks this question at
        start and applies the fix itself.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [object[]] $Check)

    $rows = @(@($Check) | Where-Object { $_.Name -eq 'GPU interrupt steering' -and $_.Verdict -eq 'Fail' })
    return ($rows.Count -gt 0)
}

function Get-TuningConfirmView {
    <#
        .SYNOPSIS
        The facts the second-confirmation dialog needs (A-FIX-02, spec 6):
        how many values will change, which ones, and whether any of them needs a
        Windows restart.

        .DESCRIPTION
        Spec 6 asks twice before a persistent write, and the second ask must name
        the reboot need. The dialog's text was fixed in the XAML, so it could not:
        it said the same thing whether the plan changed one value or four, and
        whether or not a restart was coming. A confirmation that cannot describe
        what it is confirming teaches people to click through it.

        A skipped item is not a change, so it is counted apart and it never raises
        RestartNeeded - nothing is being written, so nothing needs a restart. When
        every item is already at its target CanApply is false, and the caller
        should say so rather than ask a second time about nothing.

        This returns facts, not sentences. Every user-visible string lives in
        SimRig.Strings.ps1 (G-19), so the caller composes the text from these
        counts and names.

        Push 2 of the unit tune, step 7b (design section 4, the Cowork note of the layout of 7b): the
        facts come from the offer of this PC (Get-SimRigTuningOffer) and the ids that the person
        ticked. A change is an item of the offer with Offer Write whose id is ticked, in the order of
        the offer; an id that is not such an item is not a change (the child refuses it with text B).
        A skip is an item of the offer with Offer NoChange (texts 9 and 10). CanOffer: the offer has an
        item to write, so the first ask opens; with none, the window shows text 13.

        Pure.

        .OUTPUTS
        [pscustomobject] ChangeCount, ChangeItem, ChangeName, SkipCount, RestartName,
        RestartNeeded, HagsTicked, SteeringTicked, CanApply, CanOffer.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Offer,
        [AllowNull()] [AllowEmptyCollection()] [string[]] $Ticked
    )

    $items = @(@($Offer) | Where-Object { $null -ne $_ })
    $writes = @($items | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Offer') -eq 'Write' })
    $tickedIds = @(@($Ticked) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $changing = @($writes | Where-Object { $tickedIds -contains [string]$_.Id })
    $restarting = @($changing | Where-Object { $_.RestartNeeded })

    return [pscustomobject]@{
        ChangeCount    = $changing.Count
        ChangeItem     = $changing
        ChangeName     = @($changing | ForEach-Object { [string]$_.Name })
        SkipCount      = @($items | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Offer') -eq 'NoChange' }).Count
        RestartName    = @($restarting | ForEach-Object { [string]$_.Name })
        RestartNeeded  = ($restarting.Count -gt 0)
        HagsTicked     = (@($changing | Where-Object { [string]$_.Id -eq 'Hags' }).Count -gt 0)
        SteeringTicked = (@($changing | Where-Object { [string]$_.Id -eq 'GpuSteering' }).Count -gt 0)
        CanApply       = ($changing.Count -gt 0)
        CanOffer       = ($writes.Count -gt 0)
    }
}

function ConvertTo-TuningViewRow {
    <#
        .SYNOPSIS
        One screen row per tuning step: Name, Detail, Value ("now -> new") and
        Verdict, the shape SimRigConsole.View.ps1 already renders.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Step)

    $rows = foreach ($s in @($Step)) {
        $now = if ($null -eq $s.Now) { 'not set' } else { Format-ViewValue $s.Now }
        $value = if ($s.Op -eq 'Skip') { $now } else { '{0} -> {1}' -f $now, (Format-ViewValue $s.Target) }
        $verdict = if ($s.Op -eq 'Skip') { 'Pass' } elseif ($s.RestartNeeded) { 'Warn' } else { 'Info' }
        [pscustomobject]@{
            Name    = $s.Name
            Detail  = $s.Reason
            Value   = $value
            Verdict = $verdict
        }
    }

    return , @($rows)
}

# --------------------------------------------------------------------------
# Rules and profiles (v4.2, Phase 2)
#
# v4.0 and v4.1 kept every expected value in known-good.psd1, which is one
# machine: Rick's rig. v4.2 grades other people's machines, so the authoring
# moves into rules (what to check and how to grade it) and profiles (whose
# values to use).
#
# How the grading stays proven. These functions do NOT re-implement the row
# text. They resolve each rule against a profile, drop the rules that do not
# apply to this machine, and build the internal known-good shape that
# Get-PreflightCheck already grades. That is deliberate: duplicating three
# hundred lines of row formatting into new branches is how a refactor starts
# disagreeing with its golden. G1 proves the result byte for byte (A-GAP-09).
#
# What this means for later phases, said plainly rather than implied: the
# per-kind row builders are still inside Get-PreflightCheck. Phase 3 extracts
# them, because the public gap rules (G-1 to G-19) need branches v4.0 has no
# equivalent for. known-good.psd1 stops being an authoring file at the end of
# Phase 2; its shape survives as the internal one these functions build.
#
# Pure: no clock, no filesystem, no registry, no $env:. SimRig.Probe.ps1 reads
# the files and hands the documents in.
# --------------------------------------------------------------------------

function Test-RuleData {
    <#
        .SYNOPSIS
        Validates one simrig.rule/1 document. Returns an array of error
        strings - empty means valid. Never throws on bad data.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param($Data)

    $errors = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Data -or -not ($Data -is [System.Collections.IDictionary])) {
        $errors.Add('A rules file must be a hashtable')
        return , $errors.ToArray()
    }
    if (-not $Data.Contains('Schema') -or $Data['Schema'] -ne 'simrig.rule/1') {
        $errors.Add("Schema must be 'simrig.rule/1'")
    }
    if (-not $Data.Contains('Area') -or [string]::IsNullOrWhiteSpace([string]$Data['Area'])) {
        $errors.Add('Area is required')
    }

    $known = @('GpuSteering', 'GpuSteeringCount', 'Registry', 'PowerScheme', 'TimerResolution',
        'Service', 'Task', 'Ini', 'Preference', 'FreeSpace', 'GpuPreference', 'ScriptIntegrity',
        'PendingReboot', 'Overlay', 'Defender', 'Manual')
    $severities = @('Fail', 'Warn', 'Info', 'Manual')
    $seen = @{}
    $index = 0
    foreach ($rule in @($Data['Rules'])) {
        $index++
        if ($null -eq $rule) { continue }
        $id = Get-KnownGoodField -Entry $rule -Name 'Id'
        $label = if ([string]::IsNullOrEmpty($id)) { "$($Data['Area'])[$index]" } else { "$($Data['Area'])/$id" }

        foreach ($field in 'Id', 'Order', 'Name', 'Kind', 'Source', 'Reason', 'Evidence') {
            $value = Get-KnownGoodField -Entry $rule -Name $field
            if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
                $errors.Add("$label`: $field is required")
            }
        }
        if (-not [string]::IsNullOrEmpty($id)) {
            if ($seen.ContainsKey($id)) { $errors.Add("$label`: duplicate Id '$id'") } else { $seen[$id] = $true }
        }
        $kind = [string](Get-KnownGoodField -Entry $rule -Name 'Kind')
        if ($kind -and $known -notcontains $kind) {
            $errors.Add("$label`: Kind '$kind' is not in the contract list")
        }
        $severity = Get-KnownGoodField -Entry $rule -Name 'Severity'
        if ($null -ne $severity -and $severities -notcontains [string]$severity) {
            $errors.Add("$label`: Severity '$severity' is not Fail, Warn, Info or Manual")
        }
        $order = Get-KnownGoodField -Entry $rule -Name 'Order'
        if ($null -ne $order -and -not ($order -is [int] -or $order -is [long] -or $order -is [double])) {
            $errors.Add("$label`: Order must be a number")
        }
    }
    return , $errors.ToArray()
}

function Test-ProfileData {
    <#
        .SYNOPSIS
        Validates one simrig.profile/1 document. Returns an array of error
        strings - empty means valid.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param($Data)

    $errors = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Data -or -not ($Data -is [System.Collections.IDictionary])) {
        $errors.Add('A profile must be a hashtable')
        return , $errors.ToArray()
    }
    if (-not $Data.Contains('Schema') -or $Data['Schema'] -ne 'simrig.profile/1') {
        $errors.Add("Schema must be 'simrig.profile/1'")
    }
    foreach ($field in 'Id', 'Name', 'RuleSet', 'Values') {
        if (-not $Data.Contains($field)) { $errors.Add("Missing required key '$field'") }
    }
    if ($Data.Contains('RuleSet') -and @($Data['RuleSet']).Count -eq 0) {
        $errors.Add('RuleSet must name at least one rules area')
    }
    if ($Data.Contains('Values') -and -not ($Data['Values'] -is [System.Collections.IDictionary])) {
        $errors.Add('Values must be a hashtable')
    }
    return , $errors.ToArray()
}

function Test-RuleApplies {
    <#
        .SYNOPSIS
        True when a rule's AppliesTo matches this machine. Every AppliesTo key
        defaults to 'any', and a machine field the discovery has not filled
        matches 'any' only.

        .DESCRIPTION
        The keys are read from AppliesTo itself, so a new key is data and not a
        code change. 'any' always matches. A list matches when the machine
        value is in it. Comparison is case-insensitive on text and exact on a
        number, so Ccd = 2 does not match a single-CCD machine.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = '"Applies" is the verb of the question this function answers, not a plural noun. The name is fixed by CONTRACT.md.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Rule,
        $Machine
    )

    $applies = Get-KnownGoodField -Entry $Rule -Name 'AppliesTo'
    if ($null -eq $applies) { return $true }

    foreach ($key in @($applies.Keys)) {
        $want = $applies[$key]
        if ($null -eq $want) { continue }
        $wanted = @($want)
        if ($wanted.Count -eq 1 -and [string]$wanted[0] -eq 'any') { continue }

        $have = $null
        if ($null -ne $Machine) {
            $have = Get-KnownGoodField -Entry $Machine -Name $key
            if ($null -eq $have -and $null -ne (Get-KnownGoodField -Entry $Machine -Name 'Cpu')) {
                $have = Get-KnownGoodField -Entry (Get-KnownGoodField -Entry $Machine -Name 'Cpu') -Name $key
            }
        }
        if ($null -eq $have) { return $false }

        $match = $false
        foreach ($candidate in $wanted) {
            if ($candidate -is [string] -or $have -is [string]) {
                if ([string]$candidate -eq [string]$have) { $match = $true }
            } elseif ($candidate -eq $have) {
                $match = $true
            }
        }
        if (-not $match) { return $false }
    }
    return $true
}

function Select-SimRigProfile {
    <#
        .SYNOPSIS
        Picks the profile for this machine: the one the user chose by Id, else
        the first whose Match matches, else the default. Returns $null when
        there is no profile at all, and when no profile matches and none has the
        Id default: "no profile", not the first profile, so a folder with only the
        rig profile never gives a stranger the rig (amendment 8, condition 8).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [Alias('Profile')] [object[]] $RigProfile,
        $Machine,
        [string] $ProfileId
    )

    $all = @($RigProfile | Where-Object { $null -ne $_ })
    if ($all.Count -eq 0) { return $null }

    if ($ProfileId) {
        $chosen = @($all | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Id') -eq $ProfileId })
        if ($chosen.Count -gt 0) { return $chosen[0] }
    }

    foreach ($candidate in $all) {
        $match = Get-KnownGoodField -Entry $candidate -Name 'Match'
        if ($null -eq $match -or @($match.Keys).Count -eq 0) { continue }
        $ok = $true
        foreach ($key in @($match.Keys)) {
            $have = if ($null -ne $Machine) { Get-KnownGoodField -Entry $Machine -Name $key } else { $null }
            if ([string]$have -ne [string]$match[$key]) { $ok = $false }
        }
        if ($ok) { return $candidate }
    }

    $default = @($all | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Id') -eq 'default' })
    if ($default.Count -gt 0) { return $default[0] }
    return $null
}

function Get-RuleVersion {
    <#
        .SYNOPSIS
        A stable sha256 over the rules that were loaded, so a report says which
        rules graded it. Ids and Orders only: a comment or a reworded Reason
        does not change the version, a changed check does.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Document)

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($doc in @($Document | Where-Object { $null -ne $_ })) {
        $area = [string](Get-KnownGoodField -Entry $doc -Name 'Area')
        foreach ($rule in @($doc['Rules'])) {
            if ($null -eq $rule) { continue }
            $parts.Add(('{0}|{1}|{2}|{3}|{4}|{5}' -f $area,
                    (Get-KnownGoodField -Entry $rule -Name 'Id'),
                    (Get-KnownGoodField -Entry $rule -Name 'Order'),
                    (Get-KnownGoodField -Entry $rule -Name 'Kind'),
                    (Get-KnownGoodField -Entry $rule -Name 'Name'),
                    (Get-KnownGoodField -Entry $rule -Name 'Expected')))
        }
    }
    $text = (@($parts.ToArray()) | Sort-Object -CaseSensitive) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
        return (-join ($bytes | ForEach-Object { $_.ToString('x2', [System.Globalization.CultureInfo]::InvariantCulture) }))
    }
    finally { $sha.Dispose() }
}

function Convert-RuleToKnownGood {
    <#
        .SYNOPSIS
        Builds the internal known-good shape from the rules that apply to this
        machine, with every value resolved from the profile. This is the seam
        that keeps one grading path: Get-RuleCheck hands the result to
        Get-PreflightCheck, so the row text cannot drift from the golden.

        .DESCRIPTION
        A rule names a value; the profile holds it. `ValueKey` says which key of
        Profile.Values to read, and `Expected` in the rule is used only when the
        rule carries the value itself (a public rule with a fixed expectation).
        Rules are sorted by Order, stable, so the row order matches G1.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rule,
        # Not $Profile: that is a PowerShell automatic variable.
        [Parameter(Mandatory)] [Alias('Profile')] $RigProfile,
        $Machine
    )

    $values = Get-KnownGoodField -Entry $RigProfile -Name 'Values'
    if ($null -eq $values) { $values = @{} }

    $resolve = {
        param($TheRule, $Fallback)
        $key = Get-KnownGoodField -Entry $TheRule -Name 'ValueKey'
        if ($key -and $values.Contains([string]$key)) { return $values[[string]$key] }
        return $Fallback
    }

    # -Rule takes either the loaded documents or a flat list of rules. Flatten
    # here, so a caller that hands over what Import-SimRigRule returned works.
    $flat = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in @($Rule | Where-Object { $null -ne $_ })) {
        if ($candidate -is [System.Collections.IDictionary] -and $candidate.Contains('Rules')) {
            foreach ($inner in @($candidate['Rules'])) { if ($null -ne $inner) { $flat.Add($inner) } }
        } else {
            $flat.Add($candidate)
        }
    }

    # NOTE, and it cost four units a run each: the loop variable below must not
    # be called $rule. PowerShell variable names are case-insensitive, so $rule
    # and the [object[]] parameter $Rule are one slot. Assigning a hashtable to
    # it re-wraps the hashtable in a one-element array to satisfy the parameter
    # type, and every Get-KnownGoodField read then returns $null in silence.
    $applied = @(@($flat.ToArray()) | Where-Object { Test-RuleApplies -Rule $_ -Machine $Machine })
    $sorted = @($applied | Sort-Object -Property @{ Expression = { [double](Get-KnownGoodField -Entry $_ -Name 'Order') } } -Stable)

    $kg = @{
        Schema          = 'simrig.known-good/1'
        # Get-PreflightCheck reads these five without asking whether they exist,
        # and strict mode throws on a missing key. One area's rules file sets
        # only some of them, so they all start as $null.
        GpuSteering     = $null
        PowerScheme     = $null
        TimerResolution = $null
        FreeSpace       = $null
        GpuPreference   = $null
        Registry        = [System.Collections.Generic.List[object]]::new()
        Ini             = [System.Collections.Generic.List[object]]::new()
        Preference      = [System.Collections.Generic.List[object]]::new()
        Manual          = [System.Collections.Generic.List[object]]::new()
        Services        = @{}
        Tasks           = @{}
    }

    foreach ($entry in $sorted) {
        $kind = [string](Get-KnownGoodField -Entry $entry -Name 'Kind')
        $target = Get-KnownGoodField -Entry $entry -Name 'Target'
        $expected = & $resolve $entry (Get-KnownGoodField -Entry $entry -Name 'Expected')

        switch ($kind) {
            'GpuSteering' { $kg['GpuSteering'] = $expected }
            'GpuSteeringCount' { }   # the count row comes with the steering block
            'Registry' {
                $kg['Registry'].Add(@{
                        Name = [string](Get-KnownGoodField -Entry $entry -Name 'Name')
                        Path = [string]$target.Path
                        Value = [string]$target.Value
                        Expected = $expected
                        Source = [string](Get-KnownGoodField -Entry $entry -Name 'Source')
                        Note = Get-KnownGoodField -Entry $entry -Name 'Reason'
                    })
            }
            'PowerScheme' { $kg['PowerScheme'] = $expected }
            'TimerResolution' { $kg['TimerResolution'] = $expected }
            'Service' {
                if ($null -ne $expected) { $kg['Services'] = $expected }
            }
            'Task' {
                if ($null -ne $expected) { $kg['Tasks'] = $expected }
            }
            'Ini' {
                $kg['Ini'].Add(@{
                        File = [string]$target.File
                        Section = [string]$target.Section
                        Key = [string]$target.Key
                        Expected = $expected
                        Note = Get-KnownGoodField -Entry $entry -Name 'Reason'
                    })
            }
            'Preference' {
                if ($null -ne $expected) { foreach ($p in @($expected)) { $kg['Preference'].Add($p) } }
            }
            'FreeSpace' { $kg['FreeSpace'] = $expected }
            'GpuPreference' { $kg['GpuPreference'] = $expected }
            'ScriptIntegrity' { }    # the facts carry both sides of this check
            'PendingReboot' { }      # always graded, no data needed
            'Overlay' { }            # always recorded, no data needed
            'Defender' { }           # always graded, no data needed
            'Manual' {
                $kg['Manual'].Add(@{
                        Name = [string](Get-KnownGoodField -Entry $entry -Name 'Name')
                        Source = [string](Get-KnownGoodField -Entry $entry -Name 'Source')
                    })
            }
            default { }
        }
    }

    # The profile carries the two ini locations and the Backblaze rule; they are
    # machine facts rather than checks, so no rule names them.
    foreach ($key in @('IniDir', 'IniFile', 'NasRoot', 'Backblaze', 'Startup')) {
        $fromProfile = Get-KnownGoodField -Entry $RigProfile -Name $key
        if ($null -eq $fromProfile -and $values.Contains($key)) { $fromProfile = $values[$key] }
        if ($null -ne $fromProfile) { $kg[$key] = $fromProfile }
    }

    foreach ($key in @('Registry', 'Ini', 'Preference', 'Manual')) { $kg[$key] = @($kg[$key].ToArray()) }
    return $kg
}

function Get-RuleCheck {
    <#
        .SYNOPSIS
        The preflight rows for this machine, from rules and a profile instead of
        known-good.psd1. Same rows, same order, same text: G1 is the test
        (A-GAP-09).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rule,
        [Parameter(Mandatory)] [Alias('Profile')] $RigProfile,
        [Parameter(Mandatory)] [hashtable] $Fact,
        $Machine,
        $QuietItem
    )

    $kg = Convert-RuleToKnownGood -Rule $Rule -RigProfile $RigProfile -Machine $Machine
    $rows = Get-PreflightCheck -Fact $Fact -KnownGood $kg -QuietItem $QuietItem
    return , @($rows)
}

function Get-SimRigPreflightValue {
    <#
        Push 2 of the unit tune, step 3 (design section 3; Cowork answer section 4). Pure. The values
        that the preflight of the console grades with. On the rig (and with no state): known-good.psd1,
        as before. On a PC that is not the rig: known-good.psd1 with its four tuning entries - the
        registry entries MPO and HAGS, PowerScheme and GpuSteering - taken from the rules and the
        selected profile of this PC (Convert-RuleToKnownGood). Each other row is graded as before.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable] $KnownGood,
        [AllowNull()] $Support,
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Rule,
        [AllowNull()] $RigProfile,
        [AllowNull()] $Machine
    )

    $state = [string](Get-KnownGoodField -Entry $Support -Name 'State')
    if (@('Supported', 'NotSupported') -notcontains $state) { return $KnownGood }

    $fromRules = Convert-RuleToKnownGood -Rule @($Rule | Where-Object { $null -ne $_ }) -RigProfile $RigProfile -Machine $Machine
    $values = $KnownGood.Clone()
    $values['GpuSteering'] = $fromRules['GpuSteering']
    $values['PowerScheme'] = $fromRules['PowerScheme']
    $tuningNames = @('MPO', 'HAGS')
    $registry = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($KnownGood['Registry'])) {
        $name = [string](Get-KnownGoodField -Entry $entry -Name 'Name')
        if ($tuningNames -notcontains $name) { $registry.Add($entry); continue }
        $fromRule = @(@($fromRules['Registry']) | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Name') -eq $name })
        if ($fromRule.Count -gt 0) { $registry.Add($fromRule[0]) }
    }
    $values['Registry'] = @($registry.ToArray())
    return $values
}

# ==========================================================================
# Report
# ==========================================================================

# Engine.Report.ps1 - SimRig Console v4.0
# Pure functions. No clock, no filesystem, no registry, no $env:. See CONTRACT.md.
#
# Build-SessionReport assembles v4-report.json, schema 'simrig.v4-report/1'.
# Field names below are stable and documented here because tc-session-analyzer
# (NOT updated in this build - build brief flag 8) joins on them later:
#
#   Schema                    'simrig.v4-report/1'
#   Session.Id                session id
#   Session.Stamp             ISO-8601 session start (Format-SimRigTime)
#   Session.Rig               rig/machine label
#   Session.StartedAnyway     bool - Rick started while preflight said NOT READY
#   Session.Versions          version string per file (from VERSIONS.md)
#   Session.FileHash          SHA-256 per file at session start
#   Preflight.Check           Get-PreflightCheck rows
#   Preflight.Summary         Get-PreflightSummary result
#   Snapshot                  Build-Snapshot result (Engine.State)
#   Quiet                     quiet-operation result (simrig.result/1)
#   WatchEvent[]               every race-watch event; EVERY element carries an
#                              ISO-8601 Time - Test-SessionReport fails the report
#                              when any event lacks Time or Time does not parse as
#                              ISO-8601 (flag 8: this is what the analyzer joins on)
#   Restore                   restore-operation result (simrig.result/1)
#   Verdict                   Get-HealthyVerdict result (Engine.State)
#   Capture.Name               CapFrameX bundle file name, or $null
#   Capture.Found               bool - whether a capture file was found this session
#   LatencyMon                 LatencyMon report file name, or $null
#   BundleCheck                Test-BundleIntegrity result
#
# Capture/LatencyMon absence is a WARNING elsewhere (console/report reader), not
# a report-validation failure - Test-SessionReport does not require them.

function Build-SessionReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Session,
        [Parameter(Mandatory)] $Preflight,
        $Snapshot,
        $QuietResult,
        $WatchEvent,
        $RestoreResult,
        $Verdict,
        $Capture,
        $BundleCheck,
        # Additive to the CONTRACT signature: the report needs a LatencyMon
        # field (spec section 9) and there is nowhere else for it to come from.
        $LatencyMon
    )

    $summary = Get-PreflightSummary -Check $Preflight

    $captureName = $null
    $captureFound = $false
    if ($Capture) {
        $captureName = $Capture.Name
        $captureFound = [bool]$Capture.Found
    }

    $report = [ordered]@{
        Schema    = 'simrig.v4-report/1'
        Session   = [ordered]@{
            Id            = $Session.Id
            Stamp         = $Session.Stamp
            Rig           = $Session.Rig
            StartedAnyway = [bool]$Session.StartedAnyway
            Versions      = $Session.Versions
            FileHash      = $Session.FileHash
        }
        Preflight = [ordered]@{
            Check   = @($Preflight)
            Summary = $summary
        }
        Snapshot    = $Snapshot
        Quiet       = $QuietResult
        WatchEvent  = @($WatchEvent)
        Restore     = $RestoreResult
        Verdict     = $Verdict
        Capture     = [ordered]@{
            Name  = $captureName
            Found = $captureFound
        }
        LatencyMon  = $LatencyMon
        BundleCheck = $BundleCheck
    }

    return $report
}

function Test-SessionReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Report)

    $errors = [System.Collections.Generic.List[string]]::new()
    $isoFormats = [string[]]@('yyyy-MM-ddTHH:mm:sszzz', 'yyyy-MM-ddTHH:mm:ss')

    if ($null -eq $Report -or $null -eq $Report.Schema -or $Report.Schema -ne 'simrig.v4-report/1') {
        $errors.Add("Schema missing or unexpected: '$($Report.Schema)'")
    }

    if ($null -eq $Report.Session) {
        $errors.Add('Session missing')
    } elseif ($Report.Session.StartedAnyway -isnot [bool]) {
        $errors.Add('Session.StartedAnyway is not a bool')
    }

    $events = @($Report.WatchEvent)
    for ($i = 0; $i -lt $events.Count; $i++) {
        $time = $events[$i].Time
        if ($null -eq $time -or ($time -is [string] -and [string]::IsNullOrEmpty($time))) {
            $errors.Add("WatchEvent[$i] missing Time")
            continue
        }
        if ($time -is [datetime]) {
            # A round trip through ConvertFrom-Json coerces an ISO-8601-looking
            # string into a [datetime] automatically - already a valid time.
            continue
        }
        $parsed = [datetime]::MinValue
        $ok = [datetime]::TryParseExact(
            [string] $time, $isoFormats, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref] $parsed)
        if (-not $ok) {
            $errors.Add("WatchEvent[$i] Time not ISO-8601: '$time'")
        }
    }

    return , @($errors.ToArray())
}

function Test-BundleFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int64] $Length,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text
    )

    $reasons = [System.Collections.Generic.List[string]]::new()

    # Exactly 6 or 8 MiB is the size Windows leaves behind on a mid-copy cut -
    # flag it as truncated regardless of whether the JSON happens to parse.
    $truncated = ($Length -eq 6291456) -or ($Length -eq 8388608)
    if ($truncated) {
        $mib = if ($Length -eq 6291456) { 6 } else { 8 }
        $reasons.Add("size is exactly $mib MiB - likely truncated")
    }

    $parseOk = $false
    $frameCount = $null
    $mismatch = $false
    $doc = $null
    try {
        # System.Text.Json default JsonDocumentOptions: comments disallowed,
        # trailing commas disallowed - strict, unlike ConvertFrom-Json.
        $doc = [System.Text.Json.JsonDocument]::Parse($Text)
        $parseOk = $true
    } catch [System.Text.Json.JsonException] {
        $reasons.Add("JSON parse failed: $($_.Exception.Message)")
    } catch {
        $reasons.Add("JSON parse failed: $($_.Exception.Message)")
    }

    if ($parseOk) {
        try {
            $root = $doc.RootElement
            $runsEl = New-Object System.Text.Json.JsonElement
            if ($root.ValueKind -eq [System.Text.Json.JsonValueKind]::Object -and $root.TryGetProperty('Runs', [ref] $runsEl)) {
                if ($runsEl.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                    foreach ($run in $runsEl.EnumerateArray()) {
                        $captureDataEl = New-Object System.Text.Json.JsonElement
                        if (-not $run.TryGetProperty('CaptureData', [ref] $captureDataEl)) { continue }
                        if ($captureDataEl.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { continue }

                        # Frame count is defined by CaptureData.MsBetweenPresents'
                        # length - present in every real CapFrameX bundle and the
                        # array PresentMon writes one entry to per captured frame.
                        $mbpEl = New-Object System.Text.Json.JsonElement
                        if (-not $captureDataEl.TryGetProperty('MsBetweenPresents', [ref] $mbpEl)) { continue }
                        if ($mbpEl.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { continue }

                        $runFrameCount = $mbpEl.GetArrayLength()
                        if ($null -eq $frameCount) { $frameCount = $runFrameCount }

                        foreach ($prop in $captureDataEl.EnumerateObject()) {
                            if ($prop.Value.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { continue }
                            $len = $prop.Value.GetArrayLength()
                            if ($len -ne $runFrameCount) {
                                $mismatch = $true
                                $reasons.Add("CaptureData.$($prop.Name) length $len does not match frame count $runFrameCount (from MsBetweenPresents)")
                            }
                        }
                    }
                }
            }
        } finally {
            $doc.Dispose()
        }
    }

    $pass = $parseOk -and (-not $truncated) -and (-not $mismatch)

    return [pscustomobject]@{
        Name       = $Name
        Pass       = $pass
        Truncated  = $truncated
        ParseOk    = $parseOk
        FrameCount = $frameCount
        Mismatch   = $mismatch
        Reasons    = @($reasons.ToArray())
    }
}

function Test-BundleIntegrity {
    [CmdletBinding()]
    param($File)

    $results = @(foreach ($f in @($File)) { Test-BundleFile -Name $f.Name -Length $f.Length -Text $f.Text })
    $failed = @($results | Where-Object { -not $_.Pass })
    $pass = $failed.Count -eq 0

    if ($pass) {
        $line = 'Bundle OK - {0} file(s)' -f $results.Count
    } else {
        $failNames = @($failed | Select-Object -ExpandProperty Name)
        $line = 'Bundle FAIL - {0} file(s): {1}' -f $failed.Count, ($failNames -join ', ')
    }

    return [pscustomobject]@{
        Pass  = $pass
        Files = $results
        Line  = $line
    }
}

# ==========================================================================
# State
# ==========================================================================

# Engine.State.ps1 - SimRig Console v4.0 (subagent 4: snapshot, plans, verdict, watch, clipboard)
#
# Pure functions only. No Get-Date, no filesystem, no registry, no $env:, no
# processes. Time and all other inputs arrive as parameters. See
# /home/claude/v4/CONTRACT.md for the binding shapes this file implements.
#
# Set-StrictMode is applied once by the concatenated SimRig.Engine.ps1 /
# by each test file - this part does not set it itself.

function Build-Snapshot {
    <#
        .SYNOPSIS
        Builds the simrig.snapshot/1 document: the real current state of
        every quiet-list item, taken right before the quiet is applied.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $QuietItem,
        [Parameter(Mandatory)] [object[]] $State,
        [Parameter(Mandatory)] [datetime] $TakenAt,
        [Parameter(Mandatory)] [string] $SessionId
    )

    $stateById = @{}
    foreach ($s in $State) { $stateById[$s.Id] = $s }

    $items = foreach ($qi in $QuietItem) {
        $st = $stateById[$qi.Id]
        if ($null -eq $st) {
            [pscustomobject]@{
                Id = $qi.Id; Kind = $qi.Kind; Exists = $false
                StartType = $null; State = $null; Enabled = $null; TaskState = $null
                KeyExists = $null; ValueExists = $null; Data = $null
                RealtimeOn = $null; Running = $null
            }
        } else {
            $st
        }
    }

    return [ordered]@{
        Schema    = 'simrig.snapshot/1'
        SessionId = $SessionId
        TakenAt   = Format-SimRigTime -Time $TakenAt
        Items     = @($items)
    }
}

function Get-QuietTarget {
    <#
        .SYNOPSIS
        The ItemState each quiet-list item must read back as once the quiet
        plan has run against it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $QuietItem
    )

    $targets = foreach ($qi in $QuietItem) {
        $t = [pscustomobject]@{
            Id = $qi.Id; Kind = $qi.Kind; Exists = $true
            StartType = $null; State = $null; Enabled = $null; TaskState = $null
            KeyExists = $null; ValueExists = $null; Data = $null
            RealtimeOn = $null; Running = $null
        }
        switch ($qi.Kind) {
            'Service' {
                if ($qi.Action -eq 'Disable') { $t.StartType = 'Disabled'; $t.State = 'Stopped' }
                elseif ($qi.Action -eq 'Stop') { $t.State = 'Stopped' }
            }
            'Task' { $t.Enabled = $false }
            'Registry' { $t.Data = $qi.Data }
            'Defender' { $t.RealtimeOn = $false }
            'Process' { $t.Running = $false }
        }
        $t
    }

    return @($targets)
}

function Get-QuietPlan {
    <#
        .SYNOPSIS
        Builds the ordered (ascending Order) plan of steps that apply the
        quiet list, given the real current state of every item.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $QuietItem,
        [Parameter(Mandatory)] [object[]] $Current
    )

    $currentById = @{}
    foreach ($c in $Current) { $currentById[$c.Id] = $c }

    $sorted = $QuietItem | Sort-Object -Property Order
    $seq = 0

    $steps = foreach ($qi in $sorted) {
        $cur = $currentById[$qi.Id]
        if ($null -eq $cur -or $cur.Exists -eq $false) {
            $seq++
            [pscustomobject]@{
                Seq = $seq; Id = $qi.Id; Kind = $qi.Kind; Op = 'Skip'
                Arg = @{ Why = 'not on this Windows build' }
                Source = 'quiet'; Reason = $qi.Reason
            }
            continue
        }

        switch ($qi.Kind) {
            'Service' {
                if ($qi.Action -eq 'Disable') {
                    $seq++
                    [pscustomobject]@{
                        Seq = $seq; Id = $qi.Id; Kind = 'Service'; Op = 'SetStartType'
                        Arg = @{ StartType = 'Disabled' }; Source = 'quiet'; Reason = $qi.Reason
                    }
                    $seq++
                    [pscustomobject]@{
                        Seq = $seq; Id = $qi.Id; Kind = 'Service'; Op = 'StopService'
                        Arg = @{}; Source = 'quiet'; Reason = $qi.Reason
                    }
                } elseif ($qi.Action -eq 'Stop') {
                    $seq++
                    if ($cur.State -eq 'Running') {
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Service'; Op = 'StopService'
                            Arg = @{}; Source = 'quiet'; Reason = $qi.Reason
                        }
                    } else {
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Service'; Op = 'Skip'
                            Arg = @{ Why = 'already stopped' }; Source = 'quiet'; Reason = $qi.Reason
                        }
                    }
                }
            }
            'Task' {
                $seq++
                [pscustomobject]@{
                    Seq = $seq; Id = $qi.Id; Kind = 'Task'; Op = 'DisableTask'
                    Arg = @{}; Source = 'quiet'; Reason = $qi.Reason
                }
            }
            'Registry' {
                $seq++
                if (-not $cur.KeyExists) {
                    if ($qi.Absent -eq 'skip') {
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Registry'; Op = 'Skip'
                            Arg = @{ Why = 'registry key absent' }; Source = 'quiet'; Reason = $qi.Reason
                        }
                    } else {
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Registry'; Op = 'SetRegistryValue'
                            Arg = @{ Path = $qi.Path; Value = $qi.Value; Data = $qi.Data; RegType = $qi.RegType; CreateKey = $true }
                            Source = 'quiet'; Reason = $qi.Reason
                        }
                    }
                } else {
                    [pscustomobject]@{
                        Seq = $seq; Id = $qi.Id; Kind = 'Registry'; Op = 'SetRegistryValue'
                        Arg = @{ Path = $qi.Path; Value = $qi.Value; Data = $qi.Data; RegType = $qi.RegType; CreateKey = $false }
                        Source = 'quiet'; Reason = $qi.Reason
                    }
                }
            }
            'Defender' {
                $seq++
                [pscustomobject]@{
                    Seq = $seq; Id = $qi.Id; Kind = 'Defender'; Op = 'SetDefenderRealtime'
                    Arg = @{ On = $false }; Source = 'quiet'; Reason = $qi.Reason
                }
            }
            'Process' {
                $seq++
                if ($cur.Running -eq $true) {
                    [pscustomobject]@{
                        Seq = $seq; Id = $qi.Id; Kind = 'Process'; Op = 'CloseProcess'
                        Arg = @{ Name = $qi.Name }; Source = 'quiet'; Reason = $qi.Reason
                    }
                } else {
                    [pscustomobject]@{
                        Seq = $seq; Id = $qi.Id; Kind = 'Process'; Op = 'Skip'
                        Arg = @{ Why = 'not running' }; Source = 'quiet'; Reason = $qi.Reason
                    }
                }
            }
        }
    }

    return ,@($steps)
}

function Get-RestorePlan {
    <#
        .SYNOPSIS
        Builds the ordered (descending Order, WaaSMedicSvc last) plan that
        replays the snapshot exactly, falling back to Fallback data only
        when there is no snapshot entry for an item.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $QuietItem,
        [AllowNull()] [object] $Snapshot,
        [Parameter(Mandatory)] [object[]] $Current,
        [string[]] $Only
    )

    $currentById = @{}
    foreach ($c in $Current) { $currentById[$c.Id] = $c }

    $snapById = @{}
    if ($null -ne $Snapshot) {
        foreach ($s in $Snapshot.Items) { $snapById[$s.Id] = $s }
    }

    $items = $QuietItem
    if ($Only) { $items = $items | Where-Object { $Only -contains $_.Id } }
    $sorted = $items | Sort-Object -Property Order -Descending

    $seq = 0

    $steps = foreach ($qi in $sorted) {
        if ($qi.Kind -eq 'Process') { continue }

        $cur = $currentById[$qi.Id]
        if ($null -eq $cur -or $cur.Exists -eq $false) {
            $seq++
            [pscustomobject]@{
                Seq = $seq; Id = $qi.Id; Kind = $qi.Kind; Op = 'Skip'
                Arg = @{ Why = 'not on this Windows build' }
                Source = 'quiet'; Reason = $qi.Reason
            }
            continue
        }

        $snap = $snapById[$qi.Id]
        $useFallback = ($null -eq $snap)
        $source = if ($useFallback) { 'fallback' } else { 'snapshot' }
        $fb = $qi.Fallback
        $hasFb = ($null -ne $fb)

        switch ($qi.Kind) {
            'Service' {
                if ($useFallback) {
                    $emitted = $false
                    if ($hasFb -and $fb.ContainsKey('StartType')) {
                        $seq++
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Service'; Op = 'SetStartType'
                            Arg = @{ StartType = $fb.StartType }; Source = $source; Reason = $qi.Reason
                        }
                        $emitted = $true
                    }
                    if ($hasFb -and $fb.ContainsKey('State') -and $fb.State -eq 'Running') {
                        $seq++
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Service'; Op = 'StartService'
                            Arg = @{}; Source = $source; Reason = $qi.Reason
                        }
                        $emitted = $true
                    }
                    if (-not $emitted) {
                        $seq++
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Service'; Op = 'Skip'
                            Arg = @{ Why = 'no fallback data' }; Source = $source; Reason = $qi.Reason
                        }
                    }
                } else {
                    $seq++
                    [pscustomobject]@{
                        Seq = $seq; Id = $qi.Id; Kind = 'Service'; Op = 'SetStartType'
                        Arg = @{ StartType = $snap.StartType }; Source = $source; Reason = $qi.Reason
                    }
                    if ($snap.State -eq 'Running') {
                        $seq++
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Service'; Op = 'StartService'
                            Arg = @{}; Source = $source; Reason = $qi.Reason
                        }
                    }
                }
            }
            'Task' {
                if ($useFallback) {
                    if ($hasFb -and $fb.ContainsKey('Enabled') -and $fb.Enabled -eq $true) {
                        $seq++
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Task'; Op = 'EnableTask'
                            Arg = @{}; Source = $source; Reason = $qi.Reason
                        }
                    } else {
                        $seq++
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Task'; Op = 'Skip'
                            Arg = @{ Why = 'no fallback data' }; Source = $source; Reason = $qi.Reason
                        }
                    }
                } else {
                    $seq++
                    if ($snap.Enabled -eq $true) {
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Task'; Op = 'EnableTask'
                            Arg = @{}; Source = $source; Reason = $qi.Reason
                        }
                    } else {
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Task'; Op = 'Skip'
                            Arg = @{ Why = 'was not enabled before' }; Source = $source; Reason = $qi.Reason
                        }
                    }
                }
            }
            'Registry' {
                if ($useFallback) {
                    if ($hasFb -and $fb.ContainsKey('Data')) {
                        $seq++
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Registry'; Op = 'SetRegistryValue'
                            Arg = @{ Path = $qi.Path; Value = $qi.Value; Data = $fb.Data; RegType = $qi.RegType; CreateKey = $false }
                            Source = $source; Reason = $qi.Reason
                        }
                    } elseif ($hasFb -and $fb.ContainsKey('Delete') -and $fb.Delete -eq $true) {
                        $seq++
                        if ($qi.Absent -eq 'create-then-delete') {
                            [pscustomobject]@{
                                Seq = $seq; Id = $qi.Id; Kind = 'Registry'; Op = 'DeleteRegistryKey'
                                Arg = @{ Path = $qi.Path }; Source = $source; Reason = $qi.Reason
                            }
                        } else {
                            [pscustomobject]@{
                                Seq = $seq; Id = $qi.Id; Kind = 'Registry'; Op = 'DeleteRegistryValue'
                                Arg = @{ Path = $qi.Path; Value = $qi.Value }; Source = $source; Reason = $qi.Reason
                            }
                        }
                    } else {
                        $seq++
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Registry'; Op = 'Skip'
                            Arg = @{ Why = 'no fallback data' }; Source = $source; Reason = $qi.Reason
                        }
                    }
                } else {
                    $seq++
                    if ((-not $snap.KeyExists) -and $qi.Absent -eq 'create-then-delete') {
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Registry'; Op = 'DeleteRegistryKey'
                            Arg = @{ Path = $qi.Path }; Source = $source; Reason = $qi.Reason
                        }
                    } elseif ($snap.ValueExists) {
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Registry'; Op = 'SetRegistryValue'
                            Arg = @{ Path = $qi.Path; Value = $qi.Value; Data = $snap.Data; RegType = $qi.RegType; CreateKey = $false }
                            Source = $source; Reason = $qi.Reason
                        }
                    } elseif ($snap.KeyExists) {
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Registry'; Op = 'DeleteRegistryValue'
                            Arg = @{ Path = $qi.Path; Value = $qi.Value }; Source = $source; Reason = $qi.Reason
                        }
                    } else {
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Registry'; Op = 'Skip'
                            Arg = @{ Why = 'key was not present before, skip policy' }; Source = $source; Reason = $qi.Reason
                        }
                    }
                }
            }
            'Defender' {
                if ($useFallback) {
                    if ($hasFb -and $fb.ContainsKey('On')) {
                        $seq++
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Defender'; Op = 'SetDefenderRealtime'
                            Arg = @{ On = $fb.On }; Source = $source; Reason = $qi.Reason
                        }
                    } else {
                        $seq++
                        [pscustomobject]@{
                            Seq = $seq; Id = $qi.Id; Kind = 'Defender'; Op = 'Skip'
                            Arg = @{ Why = 'no fallback data' }; Source = $source; Reason = $qi.Reason
                        }
                    }
                } else {
                    $seq++
                    [pscustomobject]@{
                        Seq = $seq; Id = $qi.Id; Kind = 'Defender'; Op = 'SetDefenderRealtime'
                        Arg = @{ On = $snap.RealtimeOn }; Source = $source; Reason = $qi.Reason
                    }
                }
            }
        }
    }

    return ,@($steps)
}

function Compare-ItemState {
    <#
        .SYNOPSIS
        Per item and field, Expected vs Actual. Only compares fields that
        are non-null on the Expected side. Items missing on both sides
        (Exists $false) count as matching.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $QuietItem,
        [Parameter(Mandatory)] [object[]] $Expected,
        [Parameter(Mandatory)] [object[]] $Actual
    )

    $orderById = @{}
    foreach ($qi in $QuietItem) { $orderById[$qi.Id] = $qi.Order }

    $actualById = @{}
    foreach ($a in $Actual) { $actualById[$a.Id] = $a }

    $fields = @('StartType', 'State', 'Enabled', 'TaskState', 'KeyExists', 'ValueExists', 'Data', 'RealtimeOn', 'Running')

    $sortedExpected = $Expected | Sort-Object -Property { $orderById[$_.Id] }

    $rows = foreach ($exp in $sortedExpected) {
        $act = $actualById[$exp.Id]

        if ($exp.Exists -eq $false) {
            $actExists = if ($null -ne $act) { $act.Exists } else { $false }
            [pscustomobject]@{ Id = $exp.Id; Field = 'Exists'; Expected = $false; Actual = $actExists; Match = ($actExists -eq $false) }
            continue
        }

        foreach ($f in $fields) {
            $expVal = $exp.$f
            if ($null -eq $expVal) { continue }
            $actVal = if ($null -ne $act) { $act.$f } else { $null }
            [pscustomobject]@{ Id = $exp.Id; Field = $f; Expected = $expVal; Actual = $actVal; Match = ($expVal -eq $actVal) }
        }
    }

    return @($rows)
}

function Get-SimRigStepStatus {
    <#
        .SYNOPSIS
        The step statuses, as data, so the child, the console and the quiet
        record cannot drift.

        .DESCRIPTION
        Done        Windows accepted the change, and where the op has a read-back,
                    the value was read back.
        DidNotTake  Windows accepted the change with no error, and the value that
                    was read back is not the value that was set (RF-2).
        Refused     Windows returned a refusal (access denied, dependent services).
        Failed      The change threw another error.
        Skipped     Nothing to do for this item.
        WhatIf      A dry run.

        Pure.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return , @('Done', 'WhatIf', 'Skipped', 'Failed', 'Refused', 'DidNotTake')
}

function Compare-StepReadBack {
    <#
        .SYNOPSIS
        RF-2. Compares each Done step with the state that was read back after all
        steps, and gives the steps with their confirmed status.

        .DESCRIPTION
        A writer returns Done when Windows returned no error. On the rig on
        2026-09-30 EnableTask returned no error and the task was still disabled.
        So Done is not known until the item is read back. The operation reads each
        item one time after all steps (one batch read: a read for each item took 18
        to 36 s on the rig). This function uses that read.

        A Done step whose value is in the state stays Done and is counted as
        confirmed. A Done step whose value is not there gets the status DidNotTake
        and a message with the value that was read. A Done step with an op that has
        no rule here, or for an item that is not in the state, stays Done and is
        counted as not read back, by its op name: the log must not imply that it was
        confirmed. Each other status is not changed and not counted.

        Pure.

        .OUTPUTS
        [pscustomobject] Steps, Confirmed, NotSet (the steps that became
        DidNotTake), NotReadBack (a count), NotReadBackText ('Op xN, ...').
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Step,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $State,
        [AllowNull()] [object] $KnownGood,
        # The plan that the steps came from. A step record has no Arg (the result
        # JSON does not carry it), so the value that was set is taken from the plan
        # step with the same Seq, Id and Op. A step that has its own Arg uses that.
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Plan
    )

    $stateById = @{}
    foreach ($s in @($State | Where-Object { $null -ne $_ })) { $stateById[[string]$s.Id] = $s }
    $argByKey = @{}
    foreach ($p in @($Plan | Where-Object { $null -ne $_ })) {
        $argByKey[('{0}|{1}|{2}' -f $p.Seq, $p.Id, $p.Op)] = Get-KnownGoodField -Entry $p -Name 'Arg'
    }

    $confirmed = 0
    $notSet = [System.Collections.Generic.List[object]]::new()
    $notRead = [System.Collections.Generic.List[string]]::new()

    # The loop variable must not have the name of the parameter $Step: variable names
    # have no letter case, the parameter has the type [object[]], and each element
    # would become an array of one.
    $out = foreach ($one in @($Step | Where-Object { $null -ne $_ })) {
        if ([string]$one.Status -ne 'Done') { $one; continue }

        $op = [string]$one.Op
        $st = $stateById[[string]$one.Id]
        $arg = Get-KnownGoodField -Entry $one -Name 'Arg'
        if ($null -eq $arg) { $arg = $argByKey[('{0}|{1}|{2}' -f $one.Seq, $one.Id, $one.Op)] }
        # An op that sets a value cannot be confirmed with no record of the value.
        $needsArg = $op -in @('SetStartType', 'SetRegistryValue', 'SetDefenderRealtime')
        $field = $null
        $wanted = $null
        $read = $null
        $ok = $null

        if ($null -ne $st -and -not ($needsArg -and $null -eq $arg)) {
            switch ($op) {
                'SetStartType' {
                    $field = 'StartType'; $wanted = [string](Get-KnownGoodField -Entry $arg -Name 'StartType'); $read = [string]$st.StartType
                    $name = ([string]$one.Id) -replace '^Service:', ''
                    $ok = ($read -eq $wanted) -or (Test-SelfSwitchStartType -KnownGood $KnownGood -Name $name -Expected $wanted -Actual $read)
                }
                'StopService' { $field = 'State'; $wanted = 'Stopped'; $read = [string]$st.State; $ok = ($read -eq $wanted) }
                'StartService' { $field = 'State'; $wanted = 'Running'; $read = [string]$st.State; $ok = ($read -eq $wanted) }
                'DisableTask' { $field = 'Enabled'; $wanted = 'False'; $read = [string]$st.Enabled; $ok = ($st.Enabled -eq $false) }
                'EnableTask' { $field = 'Enabled'; $wanted = 'True'; $read = [string]$st.Enabled; $ok = ($st.Enabled -eq $true) }
                'SetRegistryValue' {
                    $field = 'Data'; $data = Get-KnownGoodField -Entry $arg -Name 'Data'; $wanted = [string]$data
                    $read = if ($st.ValueExists -eq $true) { [string]$st.Data } else { 'absent' }
                    $ok = ($st.ValueExists -eq $true) -and ($st.Data -eq $data)
                }
                { $_ -in @('DeleteRegistryValue', 'DeleteRegistryKey') } {
                    # DeleteRegistryKey keeps the key on purpose when Windows put other data
                    # in it, so the effect that must be there is: the value is gone.
                    $field = 'Data'; $wanted = 'absent'
                    $read = if ($st.ValueExists -eq $true) { [string]$st.Data } else { 'absent' }
                    $ok = ($st.ValueExists -ne $true)
                }
                'SetDefenderRealtime' {
                    $field = 'RealtimeOn'; $on = [bool](Get-KnownGoodField -Entry $arg -Name 'On'); $wanted = [string]$on
                    $read = [string]$st.RealtimeOn; $ok = ($st.RealtimeOn -eq $on)
                }
            }
        }

        if ($null -eq $ok) {
            $notRead.Add($op)
            $one
        }
        elseif ($ok) {
            $confirmed++
            $one
        }
        else {
            # A new object, so the step that the caller gave is not changed.
            $copy = [ordered]@{}
            foreach ($p in $one.PSObject.Properties) { $copy[$p.Name] = $p.Value }
            $copy['Status'] = 'DidNotTake'
            $copy['Message'] = ('did not take: {0} reads {1}, wanted {2}' -f $field, $read, $wanted)
            $changed = [pscustomobject]$copy
            $notSet.Add($changed)
            $changed
        }
    }

    $text = @($notRead | Group-Object | Sort-Object -Property Name | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count }) -join ', '

    return [pscustomobject]@{
        Steps           = @($out)
        Confirmed       = $confirmed
        NotSet          = $notSet.ToArray()
        NotReadBack     = $notRead.Count
        NotReadBackText = $text
    }
}

function Build-QuietRecord {
    <#
        .SYNOPSIS
        RF-1. The record of each write that this session made to an item between
        the snapshot and the restore: simrig.quiet-record/1.

        .DESCRIPTION
        The restore verdict must know if the app changed an item, or if Windows
        refused the change. The quiet result file is written at the end of the
        Quiet process and the marker does not name it, so a later restore cannot
        find it. This record is in the session folder, which the marker names.

        A run is appended and never replaces an earlier run. If the first run
        changed an item and a later run was refused on it, a record with only the
        later run says "the app did not change it" for an item that the app
        changed. When a file is there and cannot be read as a record of this
        session, the new record is marked Untrusted, and the reader then gives no
        record: an earlier write can be lost, so no item can be called refused.

        Pure. The caller reads and writes the file.

        .OUTPUTS
        [ordered] Schema, SessionId, Runs (Operation, RequestId, WrittenAt, Steps),
        and Untrusted (a reason) when an earlier record could not be read.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [datetime] $WrittenAt,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Step,
        # The text of the record file that is there now, or $null when no file is there.
        # Not typed [string]: that type makes $null an empty string, and an empty
        # file is not the same as no file.
        [AllowNull()] [object] $ExistingText
    )

    $steps = @($Step | Where-Object { $null -ne $_ } | ForEach-Object {
            [ordered]@{ Seq = $_.Seq; Id = [string]$_.Id; Op = [string]$_.Op; Status = [string]$_.Status; Message = $_.Message }
        })
    $run = [ordered]@{
        Operation = $Operation
        RequestId = $RequestId
        WrittenAt = Format-SimRigTime -Time $WrittenAt
        Steps     = $steps
    }

    $record = [ordered]@{ Schema = 'simrig.quiet-record/1'; SessionId = $SessionId }
    $runs = [System.Collections.Generic.List[object]]::new()

    if ($null -ne $ExistingText) {
        $old = ConvertFrom-QuietRecordText -Text ([string]$ExistingText) -SessionId $SessionId
        if ($old.Usable) {
            foreach ($r in @($old.Runs)) { $runs.Add($r) }
        }
        else {
            $record['Untrusted'] = ('an earlier record of this session could not be used ({0})' -f $old.Reason)
        }
    }
    $runs.Add($run)
    $record['Runs'] = $runs.ToArray()
    return $record
}

function ConvertFrom-QuietRecordText {
    <#
        .SYNOPSIS
        RF-1. Reads the text of a quiet record. A record that cannot be trusted is
        no record.

        .DESCRIPTION
        Usable only when: the text is JSON of one object, the schema is
        simrig.quiet-record/1, the SessionId is the session of the marker, the
        record is not marked Untrusted, it has one or more runs, the runs have one
        or more steps in total, and each step has an Id and a status that this app
        knows. In each other case Usable is false, Reason says why, and Steps is
        empty. Then the verdict has no third state: an item that differs from the
        snapshot is not healthy.

        Pure.

        .OUTPUTS
        [pscustomobject] Usable, Reason, Steps (each step of each run, in order),
        Runs.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [string] $SessionId
    )

    $no = { param($why) [pscustomobject]@{ Usable = $false; Reason = [string]$why; Steps = @(); Runs = @() } }

    if ([string]::IsNullOrWhiteSpace($Text)) { return (& $no 'no quiet record file, or an empty one') }
    $data = $null
    try { $data = $Text | ConvertFrom-Json -ErrorAction Stop }
    catch { return (& $no 'the quiet record is not valid JSON') }
    if ($null -eq $data -or $data -is [array] -or $data -isnot [pscustomobject]) { return (& $no 'the quiet record is not one JSON object') }

    $names = @($data.PSObject.Properties.Name)
    if ($names -notcontains 'Schema' -or [string]$data.Schema -ne 'simrig.quiet-record/1') {
        return (& $no ('the quiet record has the schema "{0}", not simrig.quiet-record/1' -f $(if ($names -contains 'Schema') { $data.Schema } else { '' })))
    }
    if ($names -notcontains 'SessionId' -or [string]$data.SessionId -ne $SessionId) {
        return (& $no 'the quiet record is for another session')
    }
    if ($names -contains 'Untrusted' -and $data.Untrusted) {
        return (& $no ('the quiet record is marked not trusted: {0}' -f $data.Untrusted))
    }
    $runs = @()
    if ($names -contains 'Runs') { $runs = @($data.Runs | Where-Object { $null -ne $_ }) }
    if ($runs.Count -eq 0) { return (& $no 'the quiet record has no run') }

    $known = Get-SimRigStepStatus
    $steps = [System.Collections.Generic.List[object]]::new()
    foreach ($run in $runs) {
        $runNames = @($run.PSObject.Properties.Name)
        if ($runNames -notcontains 'Steps') { return (& $no 'a run of the quiet record has no Steps') }
        foreach ($s in @($run.Steps | Where-Object { $null -ne $_ })) {
            $sn = @($s.PSObject.Properties.Name)
            if ($sn -notcontains 'Id' -or [string]::IsNullOrWhiteSpace([string]$s.Id)) { return (& $no 'a step of the quiet record has no Id') }
            if ($sn -notcontains 'Status' -or $known -notcontains [string]$s.Status) {
                return (& $no ('a step of the quiet record has the status "{0}", which this app does not know' -f $(if ($sn -contains 'Status') { $s.Status } else { '' })))
            }
            $steps.Add($s)
        }
    }
    if ($steps.Count -eq 0) { return (& $no 'the quiet record has no step') }

    return [pscustomobject]@{ Usable = $true; Reason = $null; Steps = $steps.ToArray(); Runs = $runs }
}

function Get-RefusedByWindowsId {
    <#
        .SYNOPSIS
        RF-1. The ids of the items that Windows refused at quiet time and that the
        app did not change.

        .DESCRIPTION
        An id is in the list only when the quiet record has one or more Refused
        steps for it and no Done, DidNotTake or Failed step for it. With a Done
        step the app changed a part of the item. With DidNotTake or Failed it may
        have. A Skipped step changes nothing, and it is no refusal either.

        "Refused" comes only from the recorded status of a step of this session. It
        never comes from "the item differs and could not be changed".

        Pure.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()] [AllowEmptyCollection()] [object[]] $QuietStep)

    $refused = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $changed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($s in @($QuietStep | Where-Object { $null -ne $_ })) {
        $id = [string]$s.Id
        switch ([string]$s.Status) {
            'Refused' { [void]$refused.Add($id) }
            { $_ -in @('Done', 'DidNotTake', 'Failed') } { [void]$changed.Add($id) }
        }
    }
    return , @($refused | Where-Object { -not $changed.Contains($_) })
}

function Test-SimRigVerdictItemRefused {
    <#
        .SYNOPSIS
        RF-1. True when a verdict item is in the third state: it differs from the
        snapshot, and Windows refused the change at quiet time.

        .DESCRIPTION
        The field Refused is on a refused item only, and a verdict from before RF-1
        has no such field. So the field is not read directly: under strict mode
        that throws for each other item.

        Pure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] [object] $Item)
    if ($null -eq $Item) { return $false }
    if ($Item -is [System.Collections.IDictionary]) { return ($Item.Contains('Refused') -and [bool]$Item['Refused']) }
    return (($Item.PSObject.Properties.Match('Refused').Count -gt 0) -and [bool]$Item.Refused)
}

function Get-HealthyVerdict {
    <#
        .SYNOPSIS
        The "Windows healthy" verdict: every Required quiet-list item back
        at its snapshot value, plus the Backblaze last-backup grading
        (flags 2 and 3). Iterates the list; no hardcoded item names.

        .DESCRIPTION
        RF-1. An item that differs from the snapshot is a restore failure, with one
        exception: Windows refused the change at quiet time and the app did not
        change the item (Get-RefusedByWindowsId, from the quiet record of this
        session). Such an item is not a pass and not a failure. The verdict stays
        green, and the line names each one and says that the app did not change it.

        -QuietStep is the list of steps of the quiet record. $null means that the
        session has no usable record: then no item is refused, and a warning says
        so when an item differs. A caller that does not give the parameter at all
        gets the verdict of before RF-1, with no warning.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $QuietItem,
        [AllowNull()] [object] $Snapshot,
        [Parameter(Mandatory)] [object[]] $Current,
        [Parameter(Mandatory)] [hashtable] $Backblaze,
        [Parameter(Mandatory)] [object] $KnownGood,
        [Parameter(Mandatory)] [datetime] $Now,
        [AllowNull()] [AllowEmptyCollection()] [object[]] $QuietStep
    )

    $recordAsked = $PSBoundParameters.ContainsKey('QuietStep')
    $refusedIds = @()
    # No third state with no snapshot. With no snapshot the restore writes the
    # Fallback data of the quiet list, and a restore step is not in the quiet record.
    # So "SimRig did not change it" is not known to be true, and "differs from the
    # snapshot" has no meaning. Found by the reviewer at e8ff3f1.
    if ($recordAsked -and $null -ne $QuietStep -and $null -ne $Snapshot) { $refusedIds = Get-RefusedByWindowsId -QuietStep $QuietStep }

    $currentById = @{}
    foreach ($c in $Current) { $currentById[$c.Id] = $c }

    $snapById = @{}
    if ($null -ne $Snapshot) {
        foreach ($s in $Snapshot.Items) { $snapById[$s.Id] = $s }
    }

    $required = $QuietItem | Where-Object { $_.Verdict -eq 'Required' } | Sort-Object -Property Order

    $items = foreach ($qi in $required) {
        $snap = $snapById[$qi.Id]
        $cur = $currentById[$qi.Id]
        $pass = $false
        $expectedText = $null
        $foundText = $null
        $message = $null

        if ($null -eq $snap) {
            $pass = $false
            $expectedText = 'unknown (no snapshot)'
            $foundText = 'unknown (no snapshot)'
            $message = '{0} (no snapshot to compare against)' -f $qi.Id
        } elseif ($snap.Exists -eq $false) {
            $curExists = if ($null -ne $cur) { $cur.Exists } else { $false }
            $pass = ($curExists -eq $false)
            $expectedText = 'not on this build'
            $foundText = if ($pass) { 'not on this build' } else { 'now present' }
            if (-not $pass) { $message = '{0} (now present, expected not on this build)' -f $qi.Id }
        } else {
            switch ($qi.Kind) {
                'Service' {
                    # State is graded only where it is stable: the service was Running
                    # before AND it starts on its own (Automatic/AutomaticDelayed), or it
                    # is a Stop-only item that was Running. A demand-start service
                    # (wuauserv, BITS, DoSvc on this rig) starts and stops by itself
                    # minutes after restore, so its state at verdict time is noise -
                    # grading it would put a false red line on a healthy machine.
                    # Its start type is still graded exactly.
                    # SelfSwitches (known-good): Windows moves this service between these
                    # start types by itself (BITS, rig 2026-09-19) - any of them matches,
                    # and its state is not graded.
                    $selfSwitch = ($null -ne $cur) -and (Test-SelfSwitchStartType -KnownGood $KnownGood -Name $qi.Name -Expected $snap.StartType -Actual $cur.StartType)
                    $gradeState = (-not $selfSwitch) -and ($snap.State -eq 'Running') -and (
                        ($snap.StartType -in @('Automatic', 'AutomaticDelayed')) -or ($qi.Action -eq 'Stop'))
                    $expectedText = if ($gradeState) { '{0}, {1}' -f $snap.StartType, $snap.State } else { '{0}, any state' -f $snap.StartType }
                    $foundText = if ($null -ne $cur) { '{0}, {1}' -f $cur.StartType, $cur.State } else { 'unknown' }
                    $startTypeOk = ($null -ne $cur) -and (($cur.StartType -eq $snap.StartType) -or $selfSwitch)
                    $pass = $startTypeOk -and ((-not $gradeState) -or ($cur.State -eq $snap.State))
                    if (-not $pass) {
                        if ($startTypeOk) {
                            $foundShort = if ($null -ne $cur) { $cur.State } else { 'unknown' }
                            $message = '{0} ({1}, expected {2})' -f $qi.Id, $foundShort, $snap.State
                        } else {
                            $message = '{0} ({1}, expected {2})' -f $qi.Id, $foundText, $expectedText
                        }
                    }
                }
                'Task' {
                    $expectedText = [string]$snap.Enabled
                    $foundText = if ($null -ne $cur) { [string]$cur.Enabled } else { 'unknown' }
                    $pass = ($null -ne $cur) -and ($cur.Enabled -eq $snap.Enabled)
                    if (-not $pass) { $message = '{0} (Enabled={1}, expected {2})' -f $qi.Id, $foundText, $expectedText }
                }
                'Registry' {
                    if ($snap.ValueExists) {
                        $expectedText = [string]$snap.Data
                        $foundText = if ($null -ne $cur -and $cur.ValueExists) { [string]$cur.Data } elseif ($null -ne $cur) { 'absent' } else { 'unknown' }
                        $pass = ($null -ne $cur) -and ($cur.ValueExists -eq $true) -and ($cur.Data -eq $snap.Data)
                    } else {
                        $expectedText = 'absent'
                        $foundText = if ($null -ne $cur -and -not $cur.ValueExists) { 'absent' } elseif ($null -ne $cur) { [string]$cur.Data } else { 'unknown' }
                        $pass = ($null -ne $cur) -and ($cur.ValueExists -eq $false)
                    }
                    if (-not $pass) { $message = '{0} ({1}, expected {2})' -f $qi.Id, $foundText, $expectedText }
                }
                'Defender' {
                    $expectedText = [string]$snap.RealtimeOn
                    $foundText = if ($null -ne $cur) { [string]$cur.RealtimeOn } else { 'unknown' }
                    $pass = ($null -ne $cur) -and ($cur.RealtimeOn -eq $snap.RealtimeOn)
                    if (-not $pass) { $message = '{0} (RealtimeOn={1}, expected {2})' -f $qi.Id, $foundText, $expectedText }
                }
                default {
                    $pass = $true
                }
            }
        }

        # RF-1. Not a pass, and the quiet record says that Windows refused the change
        # and the app changed nothing on the item: the third state.
        # The field Refused is on a refused item only. An item that is a pass or a
        # failure has the shape of before RF-1, so the frozen output G1-healthy.golden
        # does not move. A reader asks Test-SimRigVerdictItemRefused.
        # Not for an item with no row in the snapshot: the restore wrote the Fallback
        # data to it, so "SimRig did not change it" is not known to be true. A
        # snapshot with a good schema and no row for the item is such a case (a
        # damaged file). Found by the reviewer at f6013e6.
        $isRefused = (-not $pass) -and ($null -ne $snap) -and ($refusedIds -contains [string]$qi.Id)
        $row = [pscustomobject]@{ Id = $qi.Id; Pass = $pass; Expected = $expectedText; Found = $foundText; Message = $message }
        if ($isRefused) { $row | Add-Member -NotePropertyName Refused -NotePropertyValue $true }
        $row
    }

    $items = @($items)
    $total = $items.Count
    $passCount = @($items | Where-Object { $_.Pass }).Count
    $refused = @($items | Where-Object { Test-SimRigVerdictItemRefused -Item $_ })
    $failed = @($items | Where-Object { -not $_.Pass -and -not (Test-SimRigVerdictItemRefused -Item $_) })
    $green = ($failed.Count -eq 0)

    if ($green) {
        $line = 'Windows healthy - {0} of {1} items match the snapshot' -f $passCount, $total
    } else {
        $names = ($failed | ForEach-Object { $_.Message }) -join ', '
        $line = 'NOT healthy - {0} items: {1}' -f $failed.Count, $names
    }
    if ($refused.Count -gt 0) {
        # A green line must not hide them: each one is named, in the same line.
        $refusedNames = ($refused | ForEach-Object { $_.Message }) -join ', '
        $one = ($refused.Count -eq 1)
        $more = if ($green) { '' } else { 'more ' }
        $line = '{0}. {1} {2}{3}, and SimRig did not change {4}: Windows refused the change at quiet time. {5}' -f $line, $refused.Count, $more,
            $(if ($one) { 'item differs' } else { 'items differ' }), $(if ($one) { 'it' } else { 'them' }), $refusedNames
    }

    $before = $Backblaze.BeforeLastBackup
    $after = $Backblaze.AfterLastBackup
    $warnHours = $KnownGood.Backblaze.WarnIfLastBackupOlderThanHours

    $beforeIso = if ($null -ne $before) { Format-SimRigTime -Time $before } else { $null }
    $afterIso = if ($null -ne $after) { Format-SimRigTime -Time $after } else { $null }

    $warnings = @()
    if ($recordAsked -and $null -eq $QuietStep -and $failed.Count -gt 0) {
        $warnings += 'No quiet record for this session: each item that differs from the snapshot is counted as not restored'
    }
    if ($null -eq $before) {
        $warnings += 'Backblaze: last backup time not readable'
    } else {
        $ageHours = ($Now - $before).TotalHours
        if ($ageHours -gt $warnHours) {
            $warnings += ('Backblaze: last backup {0:N1} h old (older than {1} h)' -f $ageHours, $warnHours)
        }
    }

    $backblazeOut = [pscustomobject]@{ BeforeLastBackup = $beforeIso; AfterLastBackup = $afterIso }

    return [pscustomobject]@{
        Green     = $green
        Line      = $line
        Items     = $items
        Warnings  = @($warnings)
        Backblaze = $backblazeOut
    }
}

function Get-WatchEvent {
    <#
        .SYNOPSIS
        Classifies parsed service-control and task-scheduler events into
        the stable watch-event shape (flag 8). Takes no action - it only
        classifies what already happened.
    #>
    [CmdletBinding()]
    param(
        [object[]] $ServiceEvent,
        [object[]] $TaskEvent,
        [Parameter(Mandatory)] [object[]] $QuietItem
    )

    $serviceItemByName = @{}
    $taskItemByUri = @{}
    foreach ($qi in $QuietItem) {
        if ($qi.Kind -eq 'Service') { $serviceItemByName[$qi.Name] = $qi }
        elseif ($qi.Kind -eq 'Task') { $taskItemByUri[$qi.Uri] = $qi }
    }

    $events = New-Object System.Collections.Generic.List[object]

    foreach ($ev in @($ServiceEvent)) {
        if ($null -eq $ev) { continue }
        # Unmapped display names and the nameless VfpExt 7036 rows have no
        # ServiceName: they are never on the list (and $null is not a key).
        $qi = if ($ev.ServiceName) { $serviceItemByName[$ev.ServiceName] } else { $null }
        $onList = ($null -ne $qi)
        $itemId = if ($onList) { $qi.Id } else { $null }
        $timeVal = if ($ev.Time -is [datetime]) { $ev.Time } else { [datetime]$ev.Time }
        $isoTime = Format-SimRigTime -Time $timeVal

        if ($ev.Kind -eq 'StartTypeChange') {
            $severity = if ($onList) { 'Revert' } else { 'Note' }
            $message = if ($onList) {
                '{0} start type changed to {1} (was {2})' -f $ev.ServiceName, $ev.To, $ev.From
            } else {
                '{0} (not on the quiet list) start type changed to {1} (was {2})' -f $ev.ServiceName, $ev.To, $ev.From
            }
            $events.Add([pscustomobject]@{
                    Time = $isoTime; Source = 'SCM'; EventId = $ev.EventId; Kind = 'StartTypeChange'
                    Name = $ev.ServiceName; ItemId = $itemId; OnList = $onList
                    From = $ev.From; To = $ev.To; Severity = $severity; Message = $message
                })
        } elseif ($ev.Kind -eq 'StateChange') {
            $isRevert = ($onList -and $ev.State -eq 'Running')
            $severity = if ($isRevert) { 'Revert' } else { 'Info' }
            $message = if ($isRevert) {
                '{0} entered Running while quieted' -f $ev.ServiceName
            } else {
                '{0} state changed to {1}' -f $ev.ServiceName, $ev.State
            }
            $events.Add([pscustomobject]@{
                    Time = $isoTime; Source = 'SCM'; EventId = $ev.EventId; Kind = 'StateChange'
                    Name = $ev.ServiceName; ItemId = $itemId; OnList = $onList
                    From = $ev.From; To = $ev.To; Severity = $severity; Message = $message
                })
        }
    }

    foreach ($ev in @($TaskEvent)) {
        if ($null -eq $ev) { continue }
        $qi = if ($ev.TaskUri) { $taskItemByUri[$ev.TaskUri] } else { $null }
        $onList = ($null -ne $qi)
        $itemId = if ($onList) { $qi.Id } else { $null }
        $timeVal = if ($ev.Time -is [datetime]) { $ev.Time } else { [datetime]$ev.Time }
        $isoTime = Format-SimRigTime -Time $timeVal
        $ran = @('Launched', 'Started', 'ActionStarted') -contains $ev.Kind

        if ($ran) {
            $severity = if ($onList) { 'Revert' } else { 'Note' }
            $kindOut = 'TaskRan'
            $message = if ($onList) {
                '{0} ran while quieted' -f $ev.TaskUri
            } else {
                '{0} (not on the quiet list) ran' -f $ev.TaskUri
            }
        } else {
            $severity = 'Info'
            $kindOut = 'TaskOther'
            $message = '{0} {1}' -f $ev.TaskUri, $ev.Kind
        }

        $events.Add([pscustomobject]@{
                Time = $isoTime; Source = 'TaskScheduler'; EventId = $ev.EventId; Kind = $kindOut
                Name = $ev.TaskUri; ItemId = $itemId; OnList = $onList
                From = $null; To = $null; Severity = $severity; Message = $message
            })
    }

    return @($events | Sort-Object -Property Time)
}

function Test-LatencyMonReport {
    <#
        .SYNOPSIS
        Validates clipboard text as a real LatencyMon "Copy Report Text"
        export: the report header plus both the DPC and ISR sections. The
        console saves nothing when this is not valid.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text
    )

    $reasons = New-Object System.Collections.Generic.List[string]

    $hasHeader = $Text -match 'LatencyMon has been analyzing your system for'
    $hasDpc = $Text -match 'REPORTED DPCs'
    $hasIsr = $Text -match 'REPORTED ISRs'

    if (-not $hasHeader) { $reasons.Add('not a LatencyMon report: header missing') }
    if (-not $hasDpc) { $reasons.Add('DPC section missing') }
    if (-not $hasIsr) { $reasons.Add('ISR section missing') }

    $isValid = ($hasHeader -and $hasDpc -and $hasIsr)

    return [pscustomobject]@{ IsValid = $isValid; Reasons = @($reasons) }
}

function Get-LatencyMonFileName {
    <#
        .SYNOPSIS
        The saved LatencyMon report's file name for a given time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [datetime] $Time
    )

    return 'latencymon_{0}.txt' -f $Time.ToString('yyyy-MM-dd_HHmm')
}

# ==========================================================================
# Result
# ==========================================================================

# Engine.Result.ps1 - SimRig Console v4.0 (Opus: the elevation result contract, flag 4)
#
# The console runs unelevated so the mapped Z: drive stays visible. Every state
# change runs in ONE elevated child (SimRig.Actions.ps1). The child writes a
# result JSON to C:\SimRacer\Logs\v4\results\<Operation>-<RequestId>.json and
# exits with a code. The console waits on the process and reads that JSON.
# Nothing is ever read from the child's stdout across the elevation boundary.
#
# Exit codes (one table, used by both sides):
#   0  done, every step ok
#   1  done, one or more steps failed (the result names them)
#   2  bad arguments
#   3  refused (an unrestored session exists, or not elevated)
#   4  fatal exception (the result JSON is still written if at all possible)
#
# Pure functions only.

function Get-ActionExitCode {
    <#
        .SYNOPSIS
        The exit-code table as data, so the console and the child cannot drift.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{ Done = 0; StepFailed = 1; BadArgument = 2; Refused = 3; Fatal = 4 }
}

function Get-ActionOperation {
    <#
        .SYNOPSIS
        The operations the elevated child accepts.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return , @('Quiet', 'Restore', 'Undo', 'Fix', 'Deadman', 'SelfTest', 'FixGpu', 'ApplyTuning', 'UndoTuning')
}

function Get-ActionResultPath {
    <#
        .SYNOPSIS
        Where the child writes its result. Windows path joined with '\' so the
        tests on Linux produce the rig path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ResultDir,
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)] [string] $RequestId
    )
    if ($RequestId -notmatch '^[0-9a-fA-F-]{8,64}$') {
        throw "RequestId '$RequestId' is not a guid-like token - refusing to build a path from it"
    }
    return ('{0}\{1}-{2}.json' -f $ResultDir.TrimEnd('\'), $Operation, $RequestId)
}

function Get-ActionChildLogPath {
    <#
        .SYNOPSIS
        Blocker 7, commit 6 (O3): the log file of one run of the child, beside its result file. The child writes its
        log lines there, and the parent, which is not elevated, appends them to actions.log.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ResultDir,
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)] [string] $RequestId
    )
    if ($RequestId -notmatch '^[0-9a-fA-F-]{8,64}$') {
        throw "RequestId '$RequestId' is not a guid-like token - refusing to build a path from it"
    }
    return ('{0}\{1}-{2}.log' -f $ResultDir.TrimEnd('\'), $Operation, $RequestId)
}

function Test-SimRigUserSid {
    <#
        .SYNOPSIS
        True for a well-formed Windows user SID (G-12).

        .DESCRIPTION
        The SID travels from the unelevated console to the elevated child on a
        command line, and it is then pasted into a registry path. So it is checked
        before it is used: S-1-5-21 and four to five more numeric parts, nothing
        else. A value that is not a SID would otherwise build a path that either
        fails or, worse, lands somewhere real.

        Pure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()] [string] $Sid)

    if ([string]::IsNullOrWhiteSpace($Sid)) { return $false }
    return [bool]($Sid -match '^S-1-5-21(-\d+){4,5}$')
}

function Resolve-SimRigUserHivePath {
    <#
        .SYNOPSIS
        Rewrites an HKCU path to the racer's own hive (G-12). Every other path is
        returned unchanged.

        .DESCRIPTION
        The problem this exists for, from the 2026-09-19 audit: a standard user
        types an administrator's credentials at the elevation prompt, so the
        elevated child runs as a DIFFERENT user. Its HKCU is the administrator's
        profile. Every Game Bar, GameDVR and Auto HDR item would then be written to
        the wrong profile - and it would look like it worked, because the write
        succeeds. The racer's own settings stay exactly as they were, the read-back
        passes against the hive that was written, and nobody finds out.

        So the console reads its own SID before elevating and the child writes
        HKEY_USERS\<sid> instead. The provider form is used rather than an HKU:
        drive, because PowerShell ships HKLM: and HKCU: only and a script that
        assumes HKU: exists works on the author's machine and nowhere else.

        With no SID the path is returned unchanged, which is right for the deadman:
        it runs as the racer at their own sign-in, so its HKCU is already theirs.

        Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] [string] $Path,
        [AllowNull()] [string] $UserSid
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if (-not (Test-SimRigUserSid -Sid $UserSid)) { return $Path }
    if ($Path -notmatch '^(HKCU:|HKEY_CURRENT_USER)\\') { return $Path }

    $tail = $Path -replace '^(HKCU:|HKEY_CURRENT_USER)\\', ''
    return ('Registry::HKEY_USERS\{0}\{1}' -f $UserSid, $tail)
}

function Set-SimRigItemUserHive {
    <#
        .SYNOPSIS
        Rewrites the Path of every HKCU item to the racer's hive, leaving the Id
        alone (G-12).

        .DESCRIPTION
        The Id must not change. It is how the snapshot, the plan, the read-back and
        the console's own rows find each other, and it is built from the path the
        data file carries. Rewriting it here would give the child a set of ids the
        console has never heard of, and every read-back comparison would fail
        against a row it could not match.

        So identity stays with the data file and only the write target moves.

        Pure.

        .OUTPUTS
        [object[]] The same items, with HKCU paths pointed at the racer's hive.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Item,
        [AllowNull()] [string] $UserSid
    )

    $items = @($Item | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { return @() }
    if (-not (Test-SimRigUserSid -Sid $UserSid)) { return , @($items) }

    $out = foreach ($i in $items) {
        $path = [string](Get-KnownGoodField -Entry $i -Name 'Path')
        $moved = Resolve-SimRigUserHivePath -Path $path -UserSid $UserSid
        if ($moved -eq $path) { $i; continue }
        $copy = $i.PSObject.Copy()
        $copy.Path = $moved
        $copy
    }

    return , @($out)
}

function Get-SimRigUserHiveCount {
    <#
        .SYNOPSIS
        How many items in a set point at a user hive, and how many still point at
        HKCU. For the child's log line, so a run says which it did.

        Pure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Item)

    $paths = @(@($Item | Where-Object { $null -ne $_ }) | ForEach-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Path') })
    return [pscustomobject]@{
        UserHive = @($paths | Where-Object { $_ -like 'Registry::HKEY_USERS\*' }).Count
        CurrentUser = @($paths | Where-Object { $_ -match '^(HKCU:|HKEY_CURRENT_USER)\\' }).Count
    }
}

function Get-ActionArgument {
    <#
        .SYNOPSIS
        The argument list for pwsh.exe that starts the elevated child. Every
        value is quoted, so a path with spaces survives Start-Process.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ActionsScript,
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [string] $SessionDir,
        [string[]] $Only,
        [switch] $WhatIfRun,
        # ApplyTuning only: write a value that already reads as its target.
        [switch] $Force,
        # G-12: the racer's own SID, so the child writes their hive and not the
        # administrator's whose credentials were typed at the prompt.
        [AllowNull()] [string] $UserSid,
        # Flag 7: which GPU functions a steering Fix may write. Passed only when the
        # profile asks for more than the Display default, so the absence of the
        # argument is the safe case.
        [AllowNull()] [string] $GpuScope
    )
    if ((Get-ActionOperation) -notcontains $Operation) { throw "Unknown operation '$Operation'" }
    foreach ($v in @($ActionsScript, $SessionDir) + @($Only)) {
        if ($null -ne $v -and $v.Contains('"')) { throw "Argument contains a double quote: $v" }
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add('-NoProfile')
    $parts.Add('-ExecutionPolicy Bypass')
    $parts.Add(('-File "{0}"' -f $ActionsScript))
    $parts.Add(('-Operation {0}' -f $Operation))
    $parts.Add(('-RequestId {0}' -f $RequestId))
    $parts.Add(('-SessionDir "{0}"' -f $SessionDir.TrimEnd('\')))
    if ($Only -and $Only.Count -gt 0) {
        # One comma-joined value: pwsh -File binds it to [string] and Actions splits it.
        $parts.Add(('-OnlyId "{0}"' -f ($Only -join '|')))
    }
    if ($Force) { $parts.Add('-Force') }
    if ($WhatIfRun) { $parts.Add('-WhatIf') }
    if ($UserSid) {
        # Validated here rather than trusted: this value ends up inside a registry
        # path in an elevated process.
        if (-not (Test-SimRigUserSid -Sid $UserSid)) { throw "Not a user SID: $UserSid" }
        $parts.Add(('-UserSid {0}' -f $UserSid))
    }
    if ($GpuScope) {
        if ($GpuScope -notin @('Display', 'All')) { throw "Unknown GPU scope '$GpuScope'" }
        $parts.Add(('-GpuScope {0}' -f $GpuScope))
    }
    return ($parts -join ' ')
}

function Build-ActionResult {
    <#
        .SYNOPSIS
        Builds the simrig.result/1 document the elevated child writes.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)] [bool] $WhatIfRun,
        [Parameter(Mandatory)] [datetime] $StartedAt,
        [Parameter(Mandatory)] [datetime] $FinishedAt,
        [Parameter(Mandatory)] [int] $ExitCode,
        [AllowNull()] [string] $SessionDir,
        [AllowNull()] [string] $SnapshotPath,
        [AllowNull()] [object[]] $Step,
        [AllowNull()] [object[]] $ReadBack,
        [AllowNull()] [object] $Verdict,
        [AllowNull()] [string[]] $ErrorText
    )
    $steps = @($Step | Where-Object { $null -ne $_ })
    $failed = @($steps | Where-Object { $_.Status -eq 'Failed' })
    $readBackRows = @($ReadBack | Where-Object { $null -ne $_ })
    $errors = @($ErrorText | Where-Object { $_ })

    # Ok has to mean what the verdict means. The verdict grades a service's
    # State only where it is stable: a demand-start service starts and stops by
    # itself minutes after a restore, so the verdict says "Manual, any state"
    # and passes it. The read-back rows compare State unconditionally, so those
    # same items come back Expected Stopped / Actual Running. On both T.9 race
    # sessions (2026-09-20) that alone held Ok false next to a green verdict
    # reading "71 of 71 items match" - WaaSMedicSvc and XblAuthManager. A gate
    # that trusted Ok would have read every clean session as a failure.
    #
    # So the tolerance lives in one place. Where a verdict is present it
    # decides, for the items it covers: a non-matching read-back row for an item
    # the verdict passed is not an Ok failure. A row the verdict never mentions
    # still fails, and a red verdict fails Ok even when nothing else is wrong -
    # which it did not do before. Where there is no verdict (Quiet, tuning undo)
    # the strict read-back governs, unchanged.
    $verdictPassed = @{}
    $verdictKnown = $false
    if ($null -ne $Verdict) {
        $verdictKnown = $true
        foreach ($item in @($Verdict.Items)) {
            if ($null -ne $item -and $item.PSObject.Properties.Match('Id').Count -gt 0) {
                if ($item.Pass) { $verdictPassed[[string]$item.Id] = $true }
                # RF-1. An item that Windows refused at quiet time differs from the
                # snapshot, and the verdict says that the app did not change it. Its
                # read-back row does not match, and that is not an Ok failure.
                if (Test-SimRigVerdictItemRefused -Item $item) { $verdictPassed[[string]$item.Id] = $true }
            }
        }
    }

    $readBackFail = @($readBackRows | Where-Object {
        (-not $_.Match) -and -not ($verdictKnown -and $verdictPassed.ContainsKey([string]$_.Id))
    })

    $verdictOk = $true
    if ($verdictKnown -and $Verdict.PSObject.Properties.Match('Green').Count -gt 0) {
        $verdictOk = [bool]$Verdict.Green
    }
    return [ordered]@{
        Schema       = 'simrig.result/1'
        RequestId    = $RequestId
        Operation    = $Operation
        WhatIf       = $WhatIfRun
        StartedAt    = Format-SimRigTime -Time $StartedAt
        FinishedAt   = Format-SimRigTime -Time $FinishedAt
        ExitCode     = $ExitCode
        Ok           = ($ExitCode -eq 0 -and $failed.Count -eq 0 -and $readBackFail.Count -eq 0 -and $errors.Count -eq 0 -and $verdictOk)
        SessionDir   = $SessionDir
        SnapshotPath = $SnapshotPath
        Steps        = $steps
        ReadBack     = $readBackRows
        Verdict      = $Verdict
        Errors       = $errors
    }
}

function Test-ActionResult {
    <#
        .SYNOPSIS
        Validates a result read back by the console. An invalid result is a
        failure whatever the exit code said.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()] [object] $Result,
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [string] $Operation
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Result) {
        $errors.Add('no result JSON was written')
        return , $errors.ToArray()
    }
    $names = @($Result.PSObject.Properties.Name)
    if ($Result -is [System.Collections.IDictionary]) { $names = @($Result.Keys) }
    foreach ($field in 'Schema', 'RequestId', 'Operation', 'WhatIf', 'StartedAt', 'FinishedAt', 'ExitCode', 'Ok', 'Steps', 'ReadBack', 'Errors') {
        if ($names -notcontains $field) { $errors.Add("field '$field' missing") }
    }
    if ($errors.Count -gt 0) { return , $errors.ToArray() }
    if ($Result.Schema -ne 'simrig.result/1') { $errors.Add("schema '$($Result.Schema)' is not simrig.result/1") }
    if ($Result.RequestId -ne $RequestId) { $errors.Add("result is for request '$($Result.RequestId)', expected '$RequestId'") }
    if ($Result.Operation -ne $Operation) { $errors.Add("result is for operation '$($Result.Operation)', expected '$Operation'") }
    foreach ($s in @($Result.Steps)) {
        if ($null -eq $s) { continue }
        if ((Get-SimRigStepStatus) -notcontains $s.Status) {
            $errors.Add("step $($s.Seq) has status '$($s.Status)'")
        }
    }
    return , $errors.ToArray()
}

function Build-ActiveMarker {
    <#
        .SYNOPSIS
        The active-session marker: a quiet ran and no restore has finished yet.
        Quiet refuses to run while one exists (the snapshot in it is the only
        record of the real prior state).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $SessionDir,
        [Parameter(Mandatory)] [string] $SnapshotPath,
        [Parameter(Mandatory)] [datetime] $QuietAt,
        # Blocker 2, push A (the Cowork answer of 2026-10-03, point 6): the SID of the racer, from -UserSid of the Quiet,
        # so that the standalone restore and the deadman use it and not the SID of the person who runs them. /2 adds
        # this field only; a /1 marker reads as before. The field is there with no SID also.
        [string] $UserSid
    )
    return [ordered]@{
        Schema       = 'simrig.active-session/2'
        SessionId    = $SessionId
        SessionDir   = $SessionDir
        SnapshotPath = $SnapshotPath
        QuietAt      = Format-SimRigTime -Time $QuietAt
        UserSid      = $(if ([string]::IsNullOrEmpty($UserSid)) { $null } else { $UserSid })
    }
}

function Get-SessionStamp {
    <#
        .SYNOPSIS
        Session folder name and id from a time: yyyy-MM-dd_HHmm.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [datetime] $Time)
    return $Time.ToString('yyyy-MM-dd_HHmm', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Select-ReadBackItem {
    <#
        .SYNOPSIS
        Drops quiet targets for items that are not on this build, so a missing
        item reads back as skipped rather than as a failed quiet.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object[]] $Target,
        [Parameter(Mandatory)] [object[]] $Current
    )
    $present = @{}
    foreach ($c in $Current) { if ($c.Exists) { $present[$c.Id] = $true } }
    return , @($Target | Where-Object { $present.ContainsKey($_.Id) -and $_.Kind -ne 'Process' })
}

# ==========================================================================
# ViewModel
# ==========================================================================

# Engine.ViewModel.ps1 - SimRig Console v4.0 (Opus: what the screens show)
#
# Pure functions that turn engine results into the rows, banner text and
# button mode the WPF view displays. They live in the Engine, not the shell,
# so the shell stays thin (spec 3: "binds to the engine, no logic") and every
# word on the screen is testable on Linux.

function Format-ViewValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [object] $Value)
    if ($null -eq $Value) { return '-' }
    if ($Value -is [bool]) { if ($Value) { return 'on' } return 'off' }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { return (@($Value) -join ', ') }
    return [string]$Value
}

function ConvertTo-MachineCardRow {
    <#
        .SYNOPSIS
        One card's worth of rows for the My PC screen.

        .DESCRIPTION
        Turns a machine-profile block into Name / Value / Badge / Detail rows. The
        badge is the field's Confidence, which is the honest thing to show: a
        number this app read from Windows and a number it worked out from other
        numbers are not the same claim, and a field it could not read at all should
        say so rather than show a blank that reads as zero.

        A field whose Confidence is anything but Read carries its reason in Detail,
        because a Warn with no reason is just an unexplained yellow mark.

        Rows come out in the block's own key order, not sorted: the Cpu block's
        order is fixed by the contract and reordering it on screen would make the
        screen disagree with the golden.

        Pure. Nothing here reads the machine; it formats what discovery already
        returned.

        .OUTPUTS
        [object[]] rows of Name, Value, Badge, Detail.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()] $Block,
        [hashtable] $Confidence = @{},
        [hashtable] $ConfidenceReason = @{}
    )

    if ($null -eq $Block) {
        return , @([pscustomobject]@{
                Name   = 'Not read'
                Value  = '-'
                Badge  = 'Unknown'
                Detail = 'This part of the PC was not read, so nothing here is graded. The session log says why.'
            })
    }

    $keys = if ($Block -is [System.Collections.IDictionary]) { @($Block.Keys) } else { @($Block.PSObject.Properties.Name) }

    $rows = foreach ($key in $keys) {
        $value = Get-KnownGoodField -Entry $Block -Name $key
        $badge = if ($Confidence.ContainsKey($key)) { [string]$Confidence[$key] } elseif ($null -eq $value) { 'Unknown' } else { 'Read' }
        $detail = $null
        if ($badge -ne 'Read' -and $ConfidenceReason.ContainsKey($key)) { $detail = [string]$ConfidenceReason[$key] }
        [pscustomobject]@{
            Name   = [string]$key
            Value  = Format-ViewValue -Value $value
            Badge  = $badge
            Detail = $detail
        }
    }

    return , @($rows | Where-Object { $null -ne $_ })
}

function ConvertTo-PeripheralCardRow {
    <#
        .SYNOPSIS
        The Peripherals card rows: the active network adapter and whether a
        Bluetooth device is connected, with the confidence of each reading.

        .DESCRIPTION
        These two are on this card because they are the two the quiet list guards
        on (G-1 and G-2): the Wi-Fi item is never offered on a Wi-Fi-only PC, and
        the Bluetooth items are never offered while a BT device is connected. A user
        who cannot see what the app read cannot tell why an item was not offered.

        A reading the discovery did not get says Unknown rather than guessing. For
        the adapter that matters: an unrecognized media type read as Ethernet would
        let the app stop WlanSvc on a laptop racing over Wi-Fi.

        Wheels, pedals and shifters are not here. No VID/PID in this build's fixture
        set has been confirmed for any brand, so the app would be labelling guesses.
        The row says so rather than leaving the card looking broken.

        Pure.

        .OUTPUTS
        [object[]] Name, Detail, Value, Verdict - the shape the card renders.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowNull()] $Machine)

    $adapter = [string](Get-KnownGoodField -Entry $Machine -Name 'NetworkAdapter')
    $bt = Get-KnownGoodField -Entry $Machine -Name 'BluetoothConnected'
    $confidence = Get-KnownGoodField -Entry $Machine -Name 'Confidence'

    $adapterConfidence = [string](Get-KnownGoodField -Entry $confidence -Name 'NetworkAdapter')
    $btConfidence = [string](Get-KnownGoodField -Entry $confidence -Name 'BluetoothConnected')

    $rows = [System.Collections.Generic.List[object]]::new()

    $rows.Add([pscustomobject]@{
            Name    = 'Active network adapter'
            Detail  = 'the Wi-Fi quiet item is never offered on a Wi-Fi-only PC (G-1)'
            Value   = $(if ([string]::IsNullOrWhiteSpace($adapter)) { 'Unknown' } else { $adapter })
            Verdict = $(if ([string]::IsNullOrWhiteSpace($adapter)) { 'Warn' } else { 'Info' })
        })

    $btValue = if ($null -eq $bt) { 'Unknown' } elseif ([bool]$bt) { 'A device is connected' } else { 'Nothing connected' }
    $rows.Add([pscustomobject]@{
            Name    = 'Bluetooth'
            Detail  = 'the Bluetooth quiet items are never offered while a device is connected (G-2)'
            Value   = $btValue
            Verdict = $(if ($null -eq $bt) { 'Warn' } else { 'Info' })
        })

    $rows.Add([pscustomobject]@{
            Name    = 'Wheel, pedals, shifter'
            Detail  = 'not identified: no VID/PID for any brand is confirmed by a capture in this build'
            Value   = 'Not read'
            Verdict = 'Info'
        })

    if ($adapterConfidence) { $rows[0].Detail = '{0} ({1})' -f $rows[0].Detail, $adapterConfidence }
    if ($btConfidence) { $rows[1].Detail = '{0} ({1})' -f $rows[1].Detail, $btConfidence }

    return , @($rows)
}

function ConvertTo-ScoreViewRow {
    <#
        .SYNOPSIS
        One side of the Score screen, before or after.

        .DESCRIPTION
        Formats a stutter score into Name / Value rows. A $null score is not an
        empty card: it says which run is missing, because "no score yet" and "a
        score of zero" mean opposite things and a blank card reads as the second.

        Pure.

        .OUTPUTS
        [object[]] rows of Name, Value.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()] $Score
    )

    if ($null -eq $Score) {
        return , @([pscustomobject]@{ Name = 'No capture yet'; Value = '-' })
    }

    $keys = if ($Score -is [System.Collections.IDictionary]) { @($Score.Keys) } else { @($Score.PSObject.Properties.Name) }
    $rows = foreach ($key in $keys) {
        [pscustomobject]@{ Name = [string]$key; Value = Format-ViewValue -Value (Get-KnownGoodField -Entry $Score -Name $key) }
    }
    return , @($rows | Where-Object { $null -ne $_ })
}

function ConvertTo-PreflightViewRow {
    <#
        .SYNOPSIS
        Preflight rows for the check list, failures first, then warnings,
        manual, info, passes. A provisional Pass says so in its detail (flag 6).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Check)
    $rank = @{ Fail = 0; Warn = 1; Manual = 2; Info = 3; Pass = 4 }
    $rows = foreach ($c in $Check) {
        $detailParts = @($c.Detail, $c.Source) | Where-Object { $_ }
        if ($c.Provisional -and $c.Verdict -eq 'Pass') { $detailParts = @('provisional (S.1 open)') + $detailParts }
        $badge = if ($c.Verdict -eq 'Manual') { 'Manual' } else { [string]$c.Verdict }
        [pscustomobject]@{
            Name    = [string]$c.Name
            Detail  = ($detailParts -join ' - ')
            Value   = Format-ViewValue -Value $c.Found
            Source  = [string]$c.Source
            Verdict = $badge
            Rank    = $rank[[string]$c.Verdict]
        }
    }
    return , @($rows | Sort-Object -Property Rank, Name)
}

function Get-PreflightBanner {
    <#
        .SYNOPSIS
        Banner kind, title and text for the preflight screen. NOT-READY never
        blocks: the text says Rick can start anyway. The text says how many
        checks failed and names none: the rows of the check list name them.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [object] $Summary, [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Check)
    $failed = @($Check | Where-Object { $_.Verdict -eq 'Fail' })
    $manual = @($Check | Where-Object { $_.Verdict -eq 'Manual' }).Count
    if ($Summary.Ready) {
        $text = '{0} of {1} checks pass.' -f @($Check | Where-Object { $_.Verdict -eq 'Pass' }).Count, @($Check).Count
        if ($manual -gt 0) { $text += (' {0} check(s) need you to confirm by eye.' -f $manual) }
        return [pscustomobject]@{ Kind = 'Ok'; Title = 'Race-ready'; Text = $text; Mode = 'Preflight' }
    }
    $names = @($failed | ForEach-Object { $_.Name } | Select-Object -Unique)
    # RF-3 (Rick, 2026-10-02): a banner says a count, and the rows say the names. The
    # check list has the failed rows first (ConvertTo-PreflightViewRow). Until then the
    # text was 'Failed: <each name>.', which was 32 names on the first screen of a
    # stock PC. The count is the count of the failed rows, as in the subtitle.
    $text = if ($failed.Count -eq 1) { '1 check failed. It is the first row of the list below.' }
    else { '{0} checks failed. The list below starts with them.' -f $failed.Count }
    # v4.0.4: GPU steering has its own fix (Rick 2026-09-19, after Windows Update
    # re-enumerated the NVIDIA PCI IDs and the policy was gone).
    $gpuFail = @($names | Where-Object { $_ -eq 'GPU interrupt steering' }).Count -gt 0
    if ($gpuFail) {
        $text += ' GPU steering is missing: click Fix GPU steering (the screen goes black for a few seconds; no restart).'
    }
    # RF-3d. Until 2026-10-02 a failed MPO, HAGS, power plan or timer check added
    # "Other tuning is read-only in v4.0: run launch_pre_iracing.bat (v3.9), then
    # Re-check." That was not true in v4.2, and a stranger has no such file. It is
    # removed, and no instruction is put in its place: what Apply tuning does on a PC
    # that is not the rig is blocker 4 (OPEN-ITEMS.md).
    $text += ' You can start anyway - the report records that you did.'
    return [pscustomobject]@{ Kind = 'Bad'; Title = 'Not race-ready'; Text = $text; Mode = $(if ($gpuFail) { 'NotReadyGpu' } else { 'NotReady' }) }
}

function Get-PreflightSubtitle {
    <#
        .SYNOPSIS
        RF-3c. The heading subtitle of the preflight screen: one short line.

        .DESCRIPTION
        READY: the summary line, which has counts and no names. NOT READY: how many
        checks failed of how many, and no names. Summary.Line has each name and
        stays as it is for the console log and the startup report.

        Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [object] $Summary)

    if ($Summary.Ready) { return [string]$Summary.Line }
    $total = [int]$Summary.Pass + [int]$Summary.Fail + [int]$Summary.Warn + [int]$Summary.Manual + [int]$Summary.Info
    $verb = if ([int]$Summary.Fail -eq 1) { 'fails' } else { 'fail' }
    return ('NOT READY - {0} of {1} checks {2}' -f [int]$Summary.Fail, $total, $verb)
}

function Get-RestoreBannerText {
    <#
        .SYNOPSIS
        RF-3, requirement R1. The text of the banner and of the side card after a
        restore. No more than three item names.

        .DESCRIPTION
        Rick, 2026-10-02: a banner says a count, and the rows say the names. The
        verdict line (Verdict.Line) names each item that differs, and with 26
        refused items it is a run-on. The line is not touched: the log and the
        result file keep it in full. This function gives the short text.

        The count of names is the failed items and the refused items together.

        Green:
          no refused item, or 1 to 3    the verdict line, not changed
          more than 3                   the counts, and "The list below names each one."
        Red, no refused item:
          'NOT healthy - 1 item was not restored: <a>'
          'NOT healthy - 3 items were not restored: <a>, <b>, <c>'
          'NOT healthy - 5 items were not restored. The list below starts with them.'
        Red, with refused items: the first sentence, then the count of the refused
        items, never their names:
          'NOT healthy - 1 item was not restored: <a>. 1 more item differs, and
          SimRig did not change it: Windows refused the change at quiet time. The
          list below names each one.'
          'NOT healthy - 2 items were not restored. 2 more items differ, and SimRig
          did not change them: Windows refused the change at quiet time. The list
          below names each one.'
        The first sentence has the names of the failed items when the failed and
        the refused items together are three or fewer.

        The restore rows have the failed items first, then the refused items
        (ConvertTo-RestoreViewRow), so "starts with them" is true for the failed.

        Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [object] $Verdict)

    $items = @(Get-KnownGoodField -Entry $Verdict -Name 'Items') | Where-Object { $null -ne $_ }
    $items = @($items)
    $refused = @($items | Where-Object { Test-SimRigVerdictItemRefused -Item $_ })
    $failed = @($items | Where-Object { -not $_.Pass -and -not (Test-SimRigVerdictItemRefused -Item $_) })
    $line = [string](Get-KnownGoodField -Entry $Verdict -Name 'Line')
    $names = $failed.Count + $refused.Count
    $refusedOne = ($refused.Count -eq 1)

    if ($failed.Count -eq 0) {
        if ($refused.Count -le 3) { return $line }
        $passCount = @($items | Where-Object { $_.Pass }).Count
        return ('Windows healthy - {0} of {1} items match the snapshot. {2} items differ, and SimRig did not change them: Windows refused the change at quiet time. The list below names each one.' -f $passCount, $items.Count, $refused.Count)
    }

    # The first sentence: the failed items. Their names are in it when the failed
    # and the refused items together are three or fewer.
    $what = if ($failed.Count -eq 1) { '1 item was not restored' } else { '{0} items were not restored' -f $failed.Count }
    $first = if ($names -le 3) { 'NOT healthy - {0}: {1}' -f $what, (($failed | ForEach-Object { [string]$_.Message }) -join ', ') }
    else { 'NOT healthy - {0}' -f $what }
    if ($refused.Count -eq 0) {
        # No full stop after the names: the text of before RF-3 had none.
        if ($names -le 3) { return $first }
        return ('{0}. The list below starts with them.' -f $first)
    }
    # With refused items: their count, and never their names. The rows name them
    # (Cowork answer to the push 2 texts, C1: "the same first sentence, then the
    # refused sentence").
    return ('{0}. {1} more {2}, and SimRig did not change {3}: Windows refused the change at quiet time. The list below names each one.' -f $first,
        $refused.Count, $(if ($refusedOne) { 'item differs' } else { 'items differ' }), $(if ($refusedOne) { 'it' } else { 'them' }))
}

function Get-QuietBannerText {
    <#
        .SYNOPSIS
        RF-3, requirement R1. The text of the banner "Quiet applied with failures".
        No more than three item names.

        .DESCRIPTION
        With 1 to 3 names the text is the text of before: it names them. With more,
        it says the count, and the rows below name each one.

        Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Name)

    $unique = @($Name | Where-Object { $_ } | Select-Object -Unique)
    if ($unique.Count -le 3) {
        return ('Not quiet: {0}. Race watch still records. Restore puts everything back.' -f ($unique -join ', '))
    }
    return ('{0} items are not quiet. The list below names each one. Race watch still records. Restore puts everything back.' -f $unique.Count)
}

# The name of a summary row's group, as a reader sees it. It used to be built as
# ('{0}s' -f $kind), which reads fine for Services and Tasks and gives "Registrys",
# "Processs" and "Defenders" for the other three. Five entries, written out, because
# English plurals are not a format string (beta.1 review, section 8).
$script:SimRigQuietGroupName = @{
    Service  = 'Services'
    Task     = 'Tasks'
    Registry = 'Registry values'
    Defender = 'Defender'
    Process  = 'Processes'
}

function Get-SimRigQuietGroupName {
    <#
        .SYNOPSIS
        The display name for one quiet-item kind. Unknown kinds come back unchanged
        rather than throwing: a kind added later shows its own name until somebody
        gives it one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Kind)

    if ($script:SimRigQuietGroupName.ContainsKey($Kind)) { return [string]$script:SimRigQuietGroupName[$Kind] }
    return $Kind
}

function ConvertTo-QuietViewRow {
    <#
        .SYNOPSIS
        Quiet result as rows: every failed step and read-back first, then one
        summary row per kind.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [object] $Result)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @($Result.Steps | Where-Object { $_.Status -eq 'Failed' })) {
        $rows.Add([pscustomobject]@{ Name = [string]$s.Id; Detail = ('{0} failed: {1}' -f $s.Op, $s.Message); Value = '-'; Source = 'elevated child'; Verdict = 'Fail' })
    }
    foreach ($r in @($Result.ReadBack | Where-Object { -not $_.Match })) {
        $rows.Add([pscustomobject]@{ Name = [string]$r.Id; Detail = ('read back {0}: expected {1}' -f $r.Field, (Format-ViewValue $r.Expected)); Value = (Format-ViewValue $r.Actual); Source = 'read-back'; Verdict = 'Fail' })
    }
    foreach ($kind in 'Service', 'Task', 'Registry', 'Defender', 'Process') {
        $steps = @($Result.Steps | Where-Object { $_.Id -like "$kind`:*" })
        if ($steps.Count -eq 0) { continue }
        $ids = @($steps | Select-Object -ExpandProperty Id -Unique)
        $skipped = @($steps | Where-Object { $_.Status -eq 'Skipped' } | Select-Object -ExpandProperty Id -Unique).Count
        $bad = @($steps | Where-Object { $_.Status -eq 'Failed' } | Select-Object -ExpandProperty Id -Unique).Count
        $refused = @($steps | Where-Object { $_.Status -eq 'Refused' } | Select-Object -ExpandProperty Id -Unique).Count
        $verdict = if ($bad -gt 0) { 'Fail' } elseif ($Result.WhatIf) { 'Info' } else { 'OK' }
        $rows.Add([pscustomobject]@{
                Name = (Get-SimRigQuietGroupName -Kind $kind); Detail = ('{0} items, {1} skipped (not on this build or nothing to do), {2} refused by Windows (protected)' -f $ids.Count, $skipped, $refused)
                Value = ('{0} / {1}' -f ($ids.Count - $bad - $refused), $ids.Count); Source = 'quiet-list.psd1'; Verdict = $verdict
            })
    }
    return , $rows.ToArray()
}

function ConvertTo-RestoreViewRow {
    <#
        .SYNOPSIS
        Restore rows: each red verdict item by name (spec 8.5), then one Match
        row per kind, then the deadman line.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [object] $Result)
    $rows = [System.Collections.Generic.List[object]]::new()
    $verdict = $Result.Verdict
    if ($null -eq $verdict) { return , $rows.ToArray() }
    # RF-1. A verdict from before RF-1 has no Refused field: then no item is refused.
    $isRefused = { param($i) Test-SimRigVerdictItemRefused -Item $i }
    foreach ($i in @($verdict.Items | Where-Object { -not $_.Pass -and -not (& $isRefused $_) })) {
        $rows.Add([pscustomobject]@{ Name = [string]$i.Id; Detail = [string]$i.Message; Value = [string]$i.Found; Source = 'snapshot'; Verdict = 'Fail' })
    }
    foreach ($i in @($verdict.Items | Where-Object { & $isRefused $_ })) {
        $rows.Add([pscustomobject]@{
                Name = [string]$i.Id; Detail = 'differs from the snapshot; SimRig did not change it (Windows refused the change at quiet time)'
                Value = [string]$i.Found; Source = 'quiet record'; Verdict = 'Info'
            })
    }
    foreach ($kind in 'Service', 'Task', 'Registry', 'Defender') {
        $items = @($verdict.Items | Where-Object { $_.Id -like "$kind`:*" })
        if ($items.Count -eq 0) { continue }
        $ok = @($items | Where-Object { $_.Pass }).Count
        $bad = @($items | Where-Object { -not $_.Pass -and -not (& $isRefused $_) }).Count
        $ref = @($items | Where-Object { & $isRefused $_ }).Count
        $v = if ($bad -gt 0) { 'Fail' } elseif ($ref -gt 0) { 'Info' } else { 'Match' }
        if ($ref -gt 0) {
            # RF-1. The row must not say "restored to their snapshot values" for a kind
            # that has an item which differs. It says how many were restored and how
            # many differ, and the badge is Info, not Match.
            $differ = if ($ref -eq 1) { '1 differs' } else { '{0} differ' -f $ref }
            # A kind with a restore failure also: the failure is named, so the counts
            # in the text add up to the count of the kind.
            $notRestored = if ($bad -gt 0) { ' {0} not restored;' -f $bad } else { '' }
            $rows.Add([pscustomobject]@{
                    Name = (Get-SimRigQuietGroupName -Kind $kind)
                    Detail = ('{0} restored to their snapshot values;{1} {2}, refused by Windows at quiet time' -f $ok, $notRestored, $differ)
                    Value = ('{0} / {1}' -f $ok, $items.Count); Source = 'snapshot'; Verdict = $v
                })
            continue
        }
        $rows.Add([pscustomobject]@{ Name = (Get-SimRigQuietGroupName -Kind $kind); Detail = 'restored to their snapshot values'; Value = ('{0} / {1}' -f $ok, $items.Count); Source = 'snapshot'; Verdict = $v })
    }
    foreach ($w in @($verdict.Warnings)) {
        $rows.Add([pscustomobject]@{ Name = 'Warning'; Detail = [string]$w; Value = '-'; Source = 'verdict'; Verdict = 'Warn' })
    }
    $deadmanText = if ($verdict.Green) { 'sign-in task removed' } else { 'kept - it runs again at next sign-in' }
    $deadmanBadge = if ($verdict.Green) { 'OK' } else { 'Warn' }
    $rows.Add([pscustomobject]@{ Name = 'Deadman restore'; Detail = $deadmanText; Value = '-'; Source = 'Task Scheduler'; Verdict = $deadmanBadge })
    return , $rows.ToArray()
}

function Get-ActionFailureText {
    <#
        .SYNOPSIS
        One line for a result that is missing, invalid, refused or fatal.
        Returns $null when the result is usable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [object] $Result, [AllowEmptyCollection()] [string[]] $ValidationError, [AllowNull()] [object] $ExitCode)
    if (@($ValidationError).Count -gt 0) {
        return ('The elevated step gave no usable result ({0}). Exit code {1}. Nothing is assumed done.' -f (@($ValidationError) -join '; '), (Format-ViewValue $ExitCode))
    }
    $codes = Get-ActionExitCode
    if ($Result.ExitCode -eq $codes.Refused -or $Result.ExitCode -eq $codes.BadArgument -or $Result.ExitCode -eq $codes.Fatal) {
        return (@($Result.Errors) -join ' ')
    }
    return $null
}

function Select-SelfTestRevertService {
    <#
        .SYNOPSIS
        RF-1. The service that the elevated self-test sets to Manual on purpose, to
        see that the race watch reports a revert. $null when no service qualifies.

        .DESCRIPTION
        The self-test changes that service by a direct call of the writer, which is
        no step. So the service must be one that the quiet changed: then the last
        check of the self-test can never call it "not changed by SimRig".

        A service qualifies when all three are true: its Action is Disable, each of
        its quiet read-back rows matches (and it has one or more), and the quiet has
        a SetStartType step for it with the status Done. The last one that
        qualifies is taken, as before RF-1.

        Pure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Item,
        [AllowNull()] [AllowEmptyCollection()] [object[]] $ReadBack,
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Step
    )

    $okIds = @(@($ReadBack | Where-Object { $null -ne $_ }) | Group-Object -Property Id |
            Where-Object { @($_.Group | Where-Object { -not $_.Match }).Count -eq 0 } | ForEach-Object { [string]$_.Name })
    $doneIds = @(@($Step | Where-Object { $null -ne $_ }) | Where-Object {
            [string](Get-KnownGoodField -Entry $_ -Name 'Source') -eq 'quiet' -and [string]$_.Op -eq 'SetStartType' -and [string]$_.Status -eq 'Done'
        } | ForEach-Object { [string]$_.Id })
    $pick = @($Item | Where-Object {
            $null -ne $_ -and $_.Kind -eq 'Service' -and $_.Action -eq 'Disable' -and $okIds -contains [string]$_.Id -and $doneIds -contains [string]$_.Id
        } | Select-Object -Last 1)
    if ($pick.Count -eq 0) { return $null }
    return $pick[0]
}

function Get-SelfTestLeftAsFoundCheck {
    <#
        .SYNOPSIS
        RF-1. The last check of the elevated self-test: "Windows left exactly as
        found". Pass, and the detail text.

        .DESCRIPTION
        The self-test runs a quiet and a restore and then compares each item with
        its state at the start. If Windows changes an item in those minutes that it
        refused to let the app change, the check said FAIL for a change that the
        app did not make. That is the fault of RF-1 in a second place.

        An item that differs fails the check, with one exception: the quiet steps
        of this self-test run have a Refused step for it and no Done, DidNotTake or
        Failed step (Get-RefusedByWindowsId). Such an item does not fail the check,
        and the detail names it and says that the app did not change it.

        Pure.

        .OUTPUTS
        [pscustomobject] Pass, Detail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # The rows of Compare-ItemState that do not match (Id, Field, Expected, Actual).
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Diff,
        [Parameter(Mandatory)] [int] $Compared,
        # Each step of this self-test run: the quiets and the restores. The function
        # chooses the steps itself, by their source, so that the tests of this
        # function cover the choice.
        #   'quiet'     a quiet step. Done, DidNotTake or Failed is a change by the app.
        #   'snapshot'  a restore step that writes the value of the snapshot, which is
        #               the start value. It cannot make an item differ from the start,
        #               so it is not counted as a change by the app.
        #   'fallback'  a restore step that writes the Fallback data of the quiet list,
        #               because the snapshot could not be read. That is not the start
        #               value, so Done, DidNotTake or Failed is a change by the app.
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Step
    )

    $all = @($Step | Where-Object { $null -ne $_ })
    $quietStep = @($all | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Source') -eq 'quiet' })
    $fallbackIds = @($all | Where-Object {
            [string](Get-KnownGoodField -Entry $_ -Name 'Source') -eq 'fallback' -and [string]$_.Status -in @('Done', 'DidNotTake', 'Failed')
        } | ForEach-Object { [string]$_.Id })
    # Assign, then filter: the function returns ', @(...)', and a pipe on the call
    # gives one element that holds the whole array.
    $refusedAll = Get-RefusedByWindowsId -QuietStep $quietStep
    $refusedIds = @(@($refusedAll) | Where-Object { $fallbackIds -notcontains $_ })
    $rows = @($Diff | Where-Object { $null -ne $_ })
    $mine = @($rows | Where-Object { $refusedIds -notcontains [string]$_.Id })
    $theirs = @($rows | Where-Object { $refusedIds -contains [string]$_.Id })
    $text = { param($r) '{0} {1}: was {2}, now {3}' -f $r.Id, $r.Field, $r.Expected, $r.Actual }

    $refusedText = $null
    if ($theirs.Count -gt 0) {
        $ids = @($theirs | ForEach-Object { [string]$_.Id } | Select-Object -Unique).Count
        $refusedText = '{0}, and SimRig did not change {1} (Windows refused the change): {2}' -f `
            $(if ($ids -eq 1) { '1 differs' } else { '{0} differ' -f $ids }), $(if ($ids -eq 1) { 'it' } else { 'them' }),
            (@($theirs | ForEach-Object { & $text $_ }) -join '; ')
    }

    if ($mine.Count -gt 0) {
        $detail = (@($mine | ForEach-Object { & $text $_ }) -join '; ')
        if ($refusedText) { $detail = '{0}. Also {1}' -f $detail, $refusedText }
        return [pscustomobject]@{ Pass = $false; Detail = $detail }
    }
    if ($refusedText) {
        return [pscustomobject]@{ Pass = $true; Detail = ('{0} items compared; {1}' -f $Compared, $refusedText) }
    }
    return [pscustomobject]@{ Pass = $true; Detail = ('{0} items compared' -f $Compared) }
}

function Get-RestoreDoneText {
    <#
        .SYNOPSIS
        RF-1. The three texts that the console shows after a green restore: the
        step text, the heading subtitle and the banner title.

        .DESCRIPTION
        With no refused item the texts are the ones of before RF-1: the restore is
        verified. With one or more refused items the verdict line says that an item
        differs, so the console must not say "verified" beside it. Then the texts
        say what is true: the app put back each item that it changed, and how many
        items differ that Windows did not let the app change.

        Pure.

        .OUTPUTS
        [pscustomobject] StepText, Subtitle, BannerTitle, RefusedCount.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()] [object] $Verdict)

    # The texts say "SimRig put back each item that it changed". That is true for a
    # green verdict only, so a red one is refused here and not by the caller alone.
    # Get-KnownGoodField reads a field of an object or of a hashtable. Only a verdict
    # whose Green is the boolean true gets the texts. No verdict, no Green field, a
    # false one and a text such as 'False' are each refused: 'verified' must not be
    # the answer to a verdict that is not known to be green.
    $greenValue = Get-KnownGoodField -Entry $Verdict -Name 'Green'
    if (-not ($greenValue -is [bool] -and $greenValue)) {
        throw 'Get-RestoreDoneText is for a green verdict only. This verdict is not known to be green.'
    }
    $count = @(@(Get-KnownGoodField -Entry $Verdict -Name 'Items') | Where-Object { Test-SimRigVerdictItemRefused -Item $_ }).Count
    if ($count -eq 0) {
        return [pscustomobject]@{
            StepText     = 'verified'
            Subtitle     = 'Windows restored and verified. Push the bundle to the NAS.'
            BannerTitle  = 'Restore verified'
            RefusedCount = 0
        }
    }
    $differ = if ($count -eq 1) { '1 item differs' } else { '{0} items differ' -f $count }
    return [pscustomobject]@{
        StepText     = 'restored'
        Subtitle     = ('SimRig put back each item that it changed. {0} that Windows did not let SimRig change. Push the bundle to the NAS.' -f $differ)
        BannerTitle  = ('Restored - {0}, refused by Windows' -f $differ)
        RefusedCount = $count
    }
}

function Get-FailedVerdictId {
    <# The Ids the Fix button sends to the elevated child. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()] [object] $Verdict)
    if ($null -eq $Verdict) { return , @() }
    # RF-1. A refused item is not sent: the app did not change it, and a Fix would
    # try again what Windows refused.
    return , @($Verdict.Items | Where-Object { -not $_.Pass -and -not (Test-SimRigVerdictItemRefused -Item $_) } |
            ForEach-Object { [string]$_.Id })
}

function ConvertTo-TimelineViewRow {
    <# Watch events as timeline entries: HH:mm:ss, message, severity badge. #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $WatchEvent)
    $rows = foreach ($e in $WatchEvent) {
        $t = [string]$e.Time
        $clock = if ($t.Length -ge 19) { $t.Substring(11, 8) } else { $t }
        [pscustomobject]@{ Time = $clock; Message = [string]$e.Message; Severity = [string]$e.Severity }
    }
    return , @($rows)
}

function Get-WatchSummary {
    <# Counts for the race-watch side panel. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $WatchEvent)
    return [pscustomobject]@{
        Reverts    = @($WatchEvent | Where-Object { $_.Severity -eq 'Revert' }).Count
        TasksFired = @($WatchEvent | Where-Object { $_.Kind -eq 'TaskRan' }).Count
        Notes      = @($WatchEvent | Where-Object { $_.Severity -eq 'Note' }).Count
    }
}

function Get-VersionsHeader {
    <#
        .SYNOPSIS
        Version and commit lines from VERSIONS.md ("Version: 4.0.0", "Commit: abc1234").
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()] [string] $Text)
    $version = $null
    $commit = $null
    if ($Text) {
        foreach ($line in ($Text -split "`r?`n")) {
            if ($line -match '^\s*Version:\s*(\S+)') { $version = $Matches[1] }
            elseif ($line -match '^\s*Commit:\s*([0-9a-fA-F]{7,40})') { $commit = $Matches[1] }
        }
    }
    return [pscustomobject]@{ Version = $version; Commit = $commit }
}

function Get-NasBundlePath {
    <# Where Push copies a session: <share>\session-data\<stamp>_v4. The share comes
       from the profile or -NasRoot; this decides only the folder under it. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $NasRoot, [Parameter(Mandatory)] [string] $SessionStamp)
    return ('{0}\session-data\{1}_v4' -f $NasRoot.TrimEnd('\'), $SessionStamp)
}

# ==========================================================================
# Launch and startup (v4.0.3)
# ==========================================================================

function Get-LaunchToolList {
    <#
        The programs a start button opens, in order. iRacing opens last so it
        is the window in front. 'IRacing' = iRacing only; 'Tools' adds the two
        capture tools (Rick, 2026-09-19: one start with only iRacing, one with
        the capture tools).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [ValidateSet('IRacing', 'Tools')] [string] $Mode)
    if ($Mode -eq 'Tools') { return , @('CapFrameX', 'LatencyMon', 'IRacingUi') }
    return , @('IRacingUi')
}

function Get-StartupTiming {
    <#
        Seconds from process start to each named startup mark, in mark order.
        -Mark is an ordered dictionary of name -> [datetime].
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [datetime] $ProcessStart,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Mark
    )
    $out = [ordered]@{}
    foreach ($k in $Mark.Keys) { $out[$k] = [Math]::Round((([datetime]$Mark[$k]) - $ProcessStart).TotalSeconds, 2) }
    return $out
}

function Get-StartupVerdict {
    <#
        Grades a console startup. Window = seconds until the window was on
        screen; Preflight = seconds until the preflight result was shown.
        Limits come from known-good.psd1 Startup, with these defaults.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] $Timing,
        [AllowNull()] $Limit
    )
    $winMax = 3.0; $pfMax = 20.0
    if ($Limit) {
        if ($Limit -is [System.Collections.IDictionary]) {
            if ($Limit.Contains('WindowMaxSeconds')) { $winMax = [double]$Limit['WindowMaxSeconds'] }
            if ($Limit.Contains('PreflightMaxSeconds')) { $pfMax = [double]$Limit['PreflightMaxSeconds'] }
        }
    }
    $win = $null; $pf = $null
    if ($Timing -is [System.Collections.IDictionary]) {
        if ($Timing.Contains('WindowShown')) { $win = $Timing['WindowShown'] }
        if ($Timing.Contains('PreflightShown')) { $pf = $Timing['PreflightShown'] }
    }
    elseif ($null -ne $Timing) {
        if ($Timing.PSObject.Properties['WindowShown']) { $win = $Timing.WindowShown }
        if ($Timing.PSObject.Properties['PreflightShown']) { $pf = $Timing.PreflightShown }
    }
    if ($null -eq $win) {
        return [pscustomobject]@{ Pass = $false; Warn = $false; Line = 'no startup timing recorded' }
    }
    $winOk = ([double]$win -le $winMax)
    $pfOk = ($null -ne $pf -and [double]$pf -le $pfMax)
    $line = 'window on screen after {0:N1} s (limit {1:N0} s); preflight shown after {2} (limit {3:N0} s)' -f [double]$win, $winMax, $(if ($null -eq $pf) { 'never' } else { '{0:N1} s' -f [double]$pf }), $pfMax
    return [pscustomobject]@{ Pass = $winOk; Warn = ($winOk -and -not $pfOk); Line = $line }
}

function Get-StartupPictureRefusal {
    <#
        .SYNOPSIS
        Why a -StartupPicture request is refused, or $null when it is accepted or
        when no picture was asked for.

        .DESCRIPTION
        -StartupPicture is for the build only: a test run opens the real console,
        the console saves one PNG of its own window, and a person looks at it. It is
        not a feature. No button, no setting, no shortcut and no installer step
        gives it, and with no path the console does what it did before the switch
        existed - that is the first line of this function.

        It invents no path. The caller names a .png file in a folder that is there
        and that the current user can write. It works only with -StartupReport,
        because that is the run that closes itself; a picture from a console that
        stays open has no moment to be taken at.

        Pure. The caller reads the folder and passes what it found.

        .OUTPUTS
        [string] the reason, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $Path,
        [AllowNull()] [AllowEmptyString()] [string] $StartupReport,
        [bool] $FolderExists = $false,
        [bool] $FolderWritable = $false
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([string]::IsNullOrWhiteSpace($StartupReport)) {
        return '-StartupPicture works only together with -StartupReport. No picture is saved.'
    }
    if ($Path -notmatch '(?i)\.png$') {
        return ('-StartupPicture must name a .png file. This is not one: {0}' -f $Path)
    }
    if (-not $FolderExists) {
        return ('-StartupPicture names a folder that does not exist, and the console does not make one: {0}' -f $Path)
    }
    if (-not $FolderWritable) {
        return ('-StartupPicture names a folder that this user cannot write to: {0}' -f $Path)
    }
    return $null
}

# ==========================================================================
# GPU steering fix (v4.0.4)
# ==========================================================================

function Get-GpuSteeringScope {
    <#
        .SYNOPSIS
        Whether one GPU PCI function is in scope for a steering write (flag 7).

        .DESCRIPTION
        The public default steers the Display function only. The audio and USB-C
        functions of the same card are recorded and left alone.

        The reason is not caution for its own sake. Rick's CPU6 rule for his
        DEV_22BA audio function is a value measured on his rig, on his card, with
        his chipset - and steering an audio function's interrupts to a chosen core
        on somebody else's machine is a change this build has no evidence for. It
        would also be invisible: a wrong audio steering does not announce itself,
        it just makes something slightly worse somewhere nobody is looking.

        So the public scope writes what the evidence covers, and everything else is
        reported instead. Rick's profile asks for All and keeps his rig's behaviour.

        A function whose class was not read is out of scope for Display. "Unknown"
        is not "Display": guessing here writes the audio function on a card whose
        class the reading missed.

        Pure.

        .OUTPUTS
        [pscustomobject] InScope, Why.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Function,
        [ValidateSet('Display', 'All')] [string] $Scope = 'Display'
    )

    if ($Scope -eq 'All') {
        return [pscustomobject]@{ InScope = $true; Why = 'the profile steers every function of this card' }
    }

    $class = [string](Get-KnownGoodField -Entry $Function -Name 'Class')
    if ([string]::IsNullOrWhiteSpace($class)) {
        return [pscustomobject]@{ InScope = $false; Why = 'the device class was not read, so this is recorded rather than written' }
    }
    if ($class -eq 'Display') {
        return [pscustomobject]@{ InScope = $true; Why = 'the display function' }
    }
    return [pscustomobject]@{ InScope = $false
        Why = ('a {0} function - recorded, and left alone: no capture on this build measures steering it' -f $class) }
}

function Get-GpuSteeringTarget {
    <#
        The known-good Affinity Policy for every present NVIDIA function, with
        what is there now. -Affinity is Get-SimRigGpuAffinity output. Mask is the
        CPU bit mask; Bytes is the same mask as the 8-byte REG_BINARY Windows
        stores (little-endian). NeedsWrite is true when policy or mask differ AND
        the function is in scope (flag 7): out of scope, the row still comes back,
        with InScope false and a reason, so the caller reports it rather than
        dropping it.

        -Scope defaults to Display, which is the safe default for a machine this
        build has never seen. A caller that wants Rick's behaviour asks for it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $KnownGood,
        [AllowEmptyCollection()] [object[]] $Affinity,
        [ValidateSet('Display', 'All')] [string] $Scope = 'Display'
    )
    $steer = $KnownGood['GpuSteering']
    $out = foreach ($inst in @($Affinity)) {
        $override = @($steer.Overrides) | Where-Object { $_.DeviceId -eq $inst.DeviceId } | Select-Object -First 1
        $src = if ($override) { $override } else { $steer.Default }
        $mask = [uint64]$src.AssignmentSetOverride
        $needs = ($null -eq $inst.DevicePolicy) -or ([int]$inst.DevicePolicy -ne [int]$src.DevicePolicy) -or
            ($null -eq $inst.AssignmentSetOverride) -or ([uint64]$inst.AssignmentSetOverride -ne $mask)
        $scopeVerdict = Get-GpuSteeringScope -Function $inst -Scope $Scope
        [pscustomobject]@{
            InstanceId = [string]$inst.InstanceId; DeviceId = [string]$inst.DeviceId
            Class = [string](Get-KnownGoodField -Entry $inst -Name 'Class')
            DevicePolicy = [int]$src.DevicePolicy; Mask = $mask; Bytes = [byte[]][BitConverter]::GetBytes($mask)
            CurrentPolicy = $inst.DevicePolicy; CurrentMask = $inst.AssignmentSetOverride
            NeedsWrite = [bool]($needs -and $scopeVerdict.InScope)
            InScope = [bool]$scopeVerdict.InScope; ScopeWhy = [string]$scopeVerdict.Why
            KeyPath = ('HKLM:\SYSTEM\CurrentControlSet\Enum\{0}\Device Parameters\Interrupt Management\Affinity Policy' -f $inst.InstanceId)
        }
    }
    return , @($out)
}
