<#
    Engine.MyApps.ps1 - the user's own quiet extras (simrig.my-apps/1).

    Spec 6 and 6a G-3/G-4. v4.0 closed OneDrive, Chrome and Claude and stopped
    Backblaze on every machine, because that is what Rick's rig wanted. For a
    stranger those are wrong by default: Chrome may be running the overlay, the
    SimHub dashboard or the race stream, and most users have no Backblaze at all.

    So the public list ships without them and this file carries the user's own
    picks instead. Items is empty by default for every profile. Suggestions is an
    inert catalog the picker reads; nothing in it is acted on until the user moves
    an entry into Items.

    Pure. No reads, no writes, no clock.
#>

function Test-MyAppsData {
    <#
        .SYNOPSIS
        Validates a raw my-apps.psd1 hashtable against simrig.my-apps/1. Returns
        an array of error strings - empty means valid.

        .DESCRIPTION
        Never throws on bad data. A user edits this file by hand, or the picker
        writes it, and a typo must produce a sentence the user can act on rather
        than a stack trace at startup.

        Kind is limited to Service and Process. A my-apps entry is something the
        user recognizes as a program of theirs; a registry value or a scheduled
        task is not, and letting one in here would put an untracked write outside
        the reviewed public list.

        .OUTPUTS
        [string[]] One line per problem, empty when the data is valid.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [hashtable] $Data)

    $errors = [System.Collections.Generic.List[string]]::new()
    $validKinds = @('Service', 'Process')

    if (-not $Data.ContainsKey('Schema') -or $Data['Schema'] -ne 'simrig.my-apps/1') {
        $errors.Add("Schema must be 'simrig.my-apps/1' - found '$($Data['Schema'])'")
    }

    foreach ($section in 'Items', 'Suggestions') {
        if (-not $Data.ContainsKey($section)) {
            $errors.Add("$section is missing - an empty array is how this file says 'nothing'")
            continue
        }
        $index = -1
        foreach ($raw in @($Data[$section])) {
            $index++
            if ($raw -isnot [hashtable]) {
                $errors.Add("${section}[$index]: not a hashtable")
                continue
            }
            $kind = [string]$raw['Kind']
            if ($kind -notin $validKinds) {
                $errors.Add("${section}[$index]: Kind '$kind' is not valid - must be one of $($validKinds -join ', ')")
            }
            foreach ($field in 'Name', 'Label', 'Reason') {
                if ([string]::IsNullOrWhiteSpace([string]$raw[$field])) {
                    $errors.Add("${section}[$index] ($kind $($raw['Name'])): $field is empty")
                }
            }
            if ($section -eq 'Suggestions') {
                if ($null -eq $raw['Detect']) {
                    $errors.Add("Suggestions[$index] ($($raw['Name'])): Detect is missing - the picker must be able to tell whether this is even installed")
                }
                if ($raw['DefaultChecked'] -isnot [bool]) {
                    $errors.Add("Suggestions[$index] ($($raw['Name'])): DefaultChecked must be `$true or `$false")
                }
                elseif ($raw['DefaultChecked']) {
                    # G-4: the picker may not arrive pre-ticked. A tick is the user's.
                    $errors.Add("Suggestions[$index] ($($raw['Name'])): DefaultChecked must be `$false - a suggestion is never ticked for the user")
                }
            }
        }
    }

    # Never ', @()' on an empty result: that returns a one-element array holding an
    # empty array, and every caller then sees one bogus item. This shape has cost
    # this build seven times now.
    if ($errors.Count -eq 0) { return @() }
    return , @($errors)
}

function ConvertTo-MyAppItem {
    <#
        .SYNOPSIS
        Turns the user's my-apps Items into quiet items of exactly the shape
        ConvertTo-QuietItem produces, so the action layer cannot tell them apart.

        .DESCRIPTION
        Order is assigned from StartOrder upward, in file order. The default of
        900 puts every user extra after the whole public list: the reviewed items
        run first, and a user's own pick can never reorder them.

        Verdict is left to ConvertTo-QuietItem's own rule - Required for a
        service, None for a process - because a service this app stopped must be
        proved back on at restore, and a process it closed must not be started
        again on the user's behalf.

        Pure.

        .OUTPUTS
        [object[]] Quiet items, or an empty array when the user has picked none.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [hashtable] $Data,
        [int] $StartOrder = 900
    )

    $order = $StartOrder - 1
    $shaped = foreach ($raw in @($Data['Items'])) {
        if ($raw -isnot [hashtable]) { continue }
        $order++
        $copy = @{}
        foreach ($e in $raw.GetEnumerator()) { $copy[$e.Key] = $e.Value }
        $copy['Order'] = $order
        $copy['Group'] = 'My apps'
        if (-not $copy.ContainsKey('Action')) {
            $copy['Action'] = if ([string]$copy['Kind'] -eq 'Process') { 'Close' } else { 'Stop' }
        }
        if (-not $copy.ContainsKey('Evidence')) {
            $copy['Evidence'] = 'my-apps.psd1 - the user picked this item'
        }
        $copy
    }

    $shaped = @($shaped)
    if ($shaped.Count -eq 0) { return @() }
    # Assign first: ConvertTo-QuietItem returns ', @(...)' and wrapping that call in
    # '@()' would nest the whole array inside one element.
    $items = ConvertTo-QuietItem -Data @{ Items = $shaped }
    return , @($items)
}

function Get-MyAppSuggestion {
    <#
        .SYNOPSIS
        The picker rows: every suggestion, marked with whether it is present on
        this machine, and never pre-ticked.

        .DESCRIPTION
        Present comes from the caller's own reads - the running-process list and
        the installed-service list - because this file does no reading. A
        suggestion that is not present is still returned, marked absent, so the
        picker can say "not installed" rather than silently dropping a row the
        user may be looking for.

        Chosen is true only for an item already in Items. Nothing else arrives
        ticked (G-4).

        Pure.

        .OUTPUTS
        [object[]] Kind, Name, Label, Reason, Present, Chosen.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [hashtable] $Data,
        [AllowNull()] [AllowEmptyCollection()] [string[]] $RunningProcess = @(),
        [AllowNull()] [AllowEmptyCollection()] [string[]] $InstalledService = @()
    )

    $chosen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in @($Data['Items'])) {
        if ($raw -is [hashtable]) { [void]$chosen.Add(('{0}:{1}' -f $raw['Kind'], $raw['Name'])) }
    }

    $running = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($RunningProcess | Where-Object { $_ })) { [void]$running.Add([string]$p) }
    $services = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($s in @($InstalledService | Where-Object { $_ })) { [void]$services.Add([string]$s) }

    $rows = foreach ($raw in @($Data['Suggestions'])) {
        if ($raw -isnot [hashtable]) { continue }
        $kind = [string]$raw['Kind']
        $name = [string]$raw['Name']
        $present = if ($kind -eq 'Process') { $running.Contains($name) } else { $services.Contains($name) }
        [pscustomobject]@{
            Kind    = $kind
            Name    = $name
            Label   = [string]$raw['Label']
            Reason  = [string]$raw['Reason']
            Present = $present
            Chosen  = $chosen.Contains(('{0}:{1}' -f $kind, $name))
        }
    }

    $rows = @($rows)
    if ($rows.Count -eq 0) { return @() }
    return , @($rows)
}
