<#
    Engine.Update.ps1 - unit U4.6 (build brief flag 16, the advisories item)

    Pure functions. No clock, no filesystem, no registry, no network. The fetch
    lives in SimRig.Probe.ps1; everything that decides what the user is told is
    here, where it can be tested without a web server.

    What this is for. A build can be pulled after release - a restore path that
    puts back the wrong value, a fix that bricks a wheel base. The site carries
    'site/data/advisories.json', and the About screen reads it so a user running a
    pulled build is told so in the app rather than finding out on a forum.

    Three rules the brief sets, and they shape every decision below:

    - Note only. This never downloads and never installs. It shows a sentence.
    - An advisory outranks 'up to date'. Being on the newest build is no comfort
      if the newest build is the one that was pulled.
    - Silence is not 'fine'. No document, a document this app cannot read, or a
      version string that will not compare is 'Unknown' with a reason - never
      'you are up to date', which is a claim this app would not have earned.
#>

Set-StrictMode -Version 3.0

$script:SimRigAdvisorySchema = 'simrig.advisories/1'

function Get-SimRigAdvisorySchemaId {
    <#
        .SYNOPSIS
        The advisories document schema this app reads.

        .DESCRIPTION
        One place, so the reader, the tests and any future writer cannot drift.

        .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return $script:SimRigAdvisorySchema
}

function Get-SimRigVersionOrder {
    <#
        .SYNOPSIS
        Compares two dotted version strings: -1, 0, 1, or $null when they cannot
        be compared.

        .DESCRIPTION
        Numeric, part by part, with the shorter side padded - '4.2' and '4.2.0' are
        the same version. A pre-release suffix ('4.2.0-beta2') compares on its
        numeric part, because a beta of 4.2.0 is 4.2.0 as far as an advisory about
        4.2.0 is concerned.

        $null means unanswerable, and callers must treat it as unanswerable rather
        than as 'equal'. A string comparison would call '4.10.0' older than
        '4.9.0', and an advisory aimed at one build would then miss it.

        Pure.

        .OUTPUTS
        [nullable[int]]
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $Left,
        [AllowNull()] [AllowEmptyString()] [string] $Right
    )

    $leftPart = Get-SimRigVersionPart -Version $Left
    $rightPart = Get-SimRigVersionPart -Version $Right
    if ($null -eq $leftPart -or $null -eq $rightPart) { return $null }

    $count = [Math]::Max($leftPart.Count, $rightPart.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $l = if ($i -lt $leftPart.Count) { $leftPart[$i] } else { 0 }
        $r = if ($i -lt $rightPart.Count) { $rightPart[$i] } else { 0 }
        if ($l -lt $r) { return -1 }
        if ($l -gt $r) { return 1 }
    }
    return 0
}

function Get-SimRigVersionPart {
    <#
        .SYNOPSIS
        The numeric parts of a version string, or $null when it is not a version.

        .DESCRIPTION
        'unknown' is what the About screen shows when VERSIONS.md was not read, and
        it reaches this code as a version. It is not one, and saying so is the
        whole point of the null.

        Pure.

        .OUTPUTS
        [int[]] or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()] [AllowEmptyString()] [string] $Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }

    $text = ([string]$Version).Trim()
    if ($text.StartsWith('v') -or $text.StartsWith('V')) { $text = $text.Substring(1) }
    # A pre-release or build suffix is dropped, not rejected: '4.2.0-beta2' is a
    # 4.2.0 build and an advisory about 4.2.0 must still reach it.
    $text = ($text -split '[-+ ]', 2)[0]
    if ($text -notmatch '^\d+(\.\d+)*$') { return $null }

    $numbers = [System.Collections.Generic.List[int]]::new()
    foreach ($piece in ($text -split '\.')) {
        [int] $value = 0
        if (-not [int]::TryParse($piece, [ref] $value)) { return $null }
        $numbers.Add($value)
    }
    return $numbers.ToArray()
}

function Get-SimRigAdvisoryMatch {
    <#
        .SYNOPSIS
        The advisories in a document that apply to one installed version.

        .DESCRIPTION
        An advisory row matches when either:

        - 'version' equals the installed version, or
        - 'before' is set and the installed version is older than it.

        A row with neither, or with an unreadable version, is skipped rather than
        matched. A malformed row that matched everything would tell every user
        their build was pulled, and the next real advisory would be ignored.

        Pure.

        .OUTPUTS
        [object[]] the matching rows, in document order.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()] $Document,
        [AllowNull()] [AllowEmptyString()] [string] $Installed
    )

    if ($null -eq $Document) { return @() }
    if ($null -eq (Get-SimRigVersionPart -Version $Installed)) { return @() }

    $rows = Get-SimRigUpdateField -Document $Document -Name 'advisories'
    if ($null -eq $rows) { return @() }

    $hit = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($rows)) {
        if ($null -eq $row) { continue }
        $exact = Get-SimRigUpdateField -Document $row -Name 'version'
        $before = Get-SimRigUpdateField -Document $row -Name 'before'
        $matched = $false
        if (-not [string]::IsNullOrWhiteSpace([string]$exact)) {
            $matched = (0 -eq (Get-SimRigVersionOrder -Left $Installed -Right ([string]$exact)))
        }
        if (-not $matched -and -not [string]::IsNullOrWhiteSpace([string]$before)) {
            $matched = (-1 -eq (Get-SimRigVersionOrder -Left $Installed -Right ([string]$before)))
        }
        if ($matched) { $hit.Add($row) }
    }
    return @($hit)
}

function Get-SimRigUpdateField {
    <#
        .SYNOPSIS
        One named field from a parsed JSON object, whether it arrived as a
        hashtable or as a pscustomobject.

        .DESCRIPTION
        ConvertFrom-Json gives a pscustomobject; -AsHashtable gives a hashtable;
        the tests build both. Reading a missing property under Set-StrictMode
        throws, so every read goes through here and a missing field is $null.

        Pure.

        .OUTPUTS
        [object] or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()] $Document,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $Document) { return $null }
    if ($Document -is [System.Collections.IDictionary]) {
        foreach ($key in $Document.Keys) {
            if ([string]$key -eq $Name) { return $Document[$key] }
        }
        return $null
    }
    $property = $Document.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-SimRigUpdateVerdict {
    <#
        .SYNOPSIS
        What the About screen says about updates: a status, a string key, and the
        values that key formats.

        .DESCRIPTION
        The order of the decisions is the requirement:

        1. The check is off in settings - say so, and never mention a version. A
           user who turned it off is not told anything that implies it ran.
        2. No document, or one this app cannot read (schema refused) - Unknown,
           with the reason. Not 'up to date'.
        3. An advisory matches this build - Problem, whatever the latest version
           is. This is the sentence the whole unit exists for.
        4. A newer version is offered - Available.
        5. Otherwise Current.

        The text itself stays in SimRig.Strings.ps1 (G-19): this returns the key
        and the values, so the app can be translated by replacing one file.

        Pure.

        .OUTPUTS
        [pscustomobject] Status (Off|Unknown|Problem|Available|Current),
        StringKey, Detail [object[]], Confidence, Advisory [object[]], Latest.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $Installed,
        [AllowNull()] $Document,
        [bool] $CheckEnabled = $true
    )

    if (-not $CheckEnabled) {
        return [pscustomobject]@{
            Status = 'Off'; StringKey = 'About_UpdateOff'; Detail = @()
            Confidence = 'Manual'; Advisory = @(); Latest = $null
        }
    }

    if ($null -eq $Document) {
        return [pscustomobject]@{
            Status = 'Unknown'; StringKey = 'About_UpdateNoAnswer'; Detail = @()
            Confidence = 'Unknown'; Advisory = @(); Latest = $null
        }
    }

    $schema = [string](Get-SimRigUpdateField -Document $Document -Name 'schema')
    $schemaVerdict = Get-SimRigSchemaVerdict -Found $schema -Expected (Get-SimRigAdvisorySchemaId)
    if (-not $schemaVerdict.Ok) {
        return [pscustomobject]@{
            Status = 'Unknown'; StringKey = 'About_UpdateUnreadable'; Detail = @($schemaVerdict.Reason)
            Confidence = 'Unknown'; Advisory = @(); Latest = $null
        }
    }

    if ($null -eq (Get-SimRigVersionPart -Version $Installed)) {
        # The About screen shows 'unknown' when VERSIONS.md was not read. Comparing
        # that against a real version would be guessing at which side is newer.
        return [pscustomobject]@{
            Status = 'Unknown'; StringKey = 'About_UpdateNoVersion'; Detail = @()
            Confidence = 'Unknown'; Advisory = @(); Latest = $null
        }
    }

    $latestBlock = Get-SimRigUpdateField -Document $Document -Name 'latest'
    $latest = [string](Get-SimRigUpdateField -Document $latestBlock -Name 'version')
    $advisory = @(Get-SimRigAdvisoryMatch -Document $Document -Installed $Installed)

    if ($advisory.Count -gt 0) {
        $note = [string](Get-SimRigUpdateField -Document $advisory[0] -Name 'note')
        $fixedIn = [string](Get-SimRigUpdateField -Document $advisory[0] -Name 'fixedIn')
        if ([string]::IsNullOrWhiteSpace($fixedIn)) {
            # Fall back to the newest build only when it is actually newer than this
            # one. An advisory against the newest build with no fix named must not
            # point the user at the build that has the problem.
            if (-1 -eq (Get-SimRigVersionOrder -Left $Installed -Right $latest)) { $fixedIn = $latest }
            else { $fixedIn = '' }
        }
        if ([string]::IsNullOrWhiteSpace($note)) { $note = '(no detail given)' }
        $key = if ([string]::IsNullOrWhiteSpace($fixedIn)) { 'About_UpdateProblemNoFix' } else { 'About_UpdateProblem' }
        $detail = if ([string]::IsNullOrWhiteSpace($fixedIn)) { @($note) } else { @($note, $fixedIn) }
        return [pscustomobject]@{
            Status = 'Problem'; StringKey = $key; Detail = $detail
            Confidence = 'Read'; Advisory = $advisory; Latest = $latest
        }
    }

    $order = Get-SimRigVersionOrder -Left $Installed -Right $latest
    if ($null -eq $order) {
        return [pscustomobject]@{
            Status = 'Unknown'; StringKey = 'About_UpdateNoLatest'; Detail = @()
            Confidence = 'Unknown'; Advisory = @(); Latest = $null
        }
    }

    if ($order -lt 0) {
        return [pscustomobject]@{
            Status = 'Available'; StringKey = 'About_UpdateAvailable'; Detail = @($latest, $Installed)
            Confidence = 'Read'; Advisory = @(); Latest = $latest
        }
    }

    return [pscustomobject]@{
        Status = 'Current'; StringKey = 'About_UpdateCurrent'; Detail = @($Installed)
        Confidence = 'Read'; Advisory = @(); Latest = $latest
    }
}
