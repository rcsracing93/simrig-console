<#
    Engine.MachineProfile.ps1 - lead, 2026-09-26.

    Assembles simrig.machine-profile/1 from the blocks units U3.1 to U3.3 read,
    and gives the Quiet path a way to honour AppliesTo.

    Why this exists. Unit U3.8 wrote AppliesTo onto nine quiet-list items and
    nineteen public gap rules, proved each one correct against Test-RuleApplies,
    and then had to skip ten of its own tests because nothing joined the
    discovery blocks into a machine, ConvertTo-QuietItem dropped AppliesTo, and
    Get-QuietPlan took no machine. AppliesTo decides whether a stranger's
    Bluetooth gets switched off during a race, so inert is the one thing it
    cannot be.

    Pure. No clock, no filesystem, no registry, no process, no environment read.
#>

Set-StrictMode -Version Latest

function Get-MachineProfileConfidenceValue {
    <#
        .SYNOPSIS
        The six Confidence values CONTRACT.md fixes, and no others.

        .DESCRIPTION
        Spec section 4 names only the first three. The contract example uses
        Warn. Two units read the two documents and reached different vocabularies
        in wave 3a, which is why the list now lives in one function that the
        assembler checks against.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return , @('Read', 'Read (derived)', 'Inferred', 'Warn', 'Manual', 'Unknown')
}

function Build-MachineProfile {
    <#
        .SYNOPSIS
        Joins the discovery blocks into simrig.machine-profile/1.

        .DESCRIPTION
        The Cpu block keeps its eight fixed keys and gains nothing: it is
        compared whole, and adding a key would shift every machine-profile
        golden. The steering fields live in the CpuSteering sibling block the
        contract added for them.

        Network, Bluetooth and Profile are repeated at the top level because
        Test-RuleApplies looks a key up at the top level and then falls back to
        Cpu only. A key that lives anywhere else reads as "never filled", which
        matches 'any' and nothing else - so a rule limited to WiFi would quietly
        never fire instead of failing loudly. Profile is the selected profile's
        id, which nothing was merging in, so AppliesTo.Profile could not work at
        all.

        A block that was not read is $null, is listed in Unavailable, and is not
        invented. TakenAt comes from the caller: this file is the pure half.

        .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary] simrig.machine-profile/1
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [datetime] $TakenAt,
        # Named MachineName, not ComputerName: PSScriptAnalyzer flags a literal
        # passed to a ComputerName parameter, because in a cmdlet call that means
        # a hardcoded remote host. Here it is just this PC's name. The contract
        # field it fills is still called ComputerName.
        [AllowNull()] [string] $MachineName,
        [AllowNull()] $Cpu,
        [AllowNull()] $CpuSteering,
        [AllowNull()] $Gpu,
        [AllowNull()] $Windows,
        [AllowNull()] $Display,
        [AllowNull()] $IRacing,
        [AllowNull()] [string] $ProfileId,
        # The names are the ones AppliesTo asks for in quiet-list.psd1 and the
        # public rules - NetworkAdapter, not Network. A near-miss here reads as
        # "never filled", which matches 'any' and nothing else, so a rule would
        # silently never fire instead of failing loudly.
        [AllowNull()] [string] $NetworkAdapter,
        [AllowNull()] [object] $BluetoothConnected,
        # Flag 15. The quiet list's Defender item is gated on this, and it comes from
        # the selected profile rather than from discovery: switching off somebody's
        # virus scanner is a choice they make, not a fact about their PC. Absent
        # means not opted in, which is why it is only set when it is true - an absent
        # key matches 'any' and nothing else, so the item simply does not apply.
        [AllowNull()] [object] $DefenderOptIn,
        [hashtable] $Confidence = @{},
        [hashtable] $ConfidenceReason = @{}
    )

    $allowed = Get-MachineProfileConfidenceValue
    foreach ($key in @($Confidence.Keys)) {
        $value = $Confidence[$key]
        if ($null -eq $value) { continue }
        if ($allowed -notcontains [string]$value) {
            throw ("Confidence '{0}' for field '{1}' is not one of the six values CONTRACT.md fixes: {2}." -f $value, $key, ($allowed -join ', '))
        }
    }

    $unavailable = [System.Collections.Generic.List[string]]::new()
    foreach ($pair in @(
            @{ Name = 'Cpu'; Value = $Cpu }
            @{ Name = 'CpuSteering'; Value = $CpuSteering }
            @{ Name = 'Gpu'; Value = $Gpu }
            @{ Name = 'Windows'; Value = $Windows }
            @{ Name = 'Display'; Value = $Display }
            @{ Name = 'IRacing'; Value = $IRacing }
        )) {
        if ($null -eq $pair.Value) { $unavailable.Add([string]$pair.Name) }
    }

    # The eight fixed keys, in the contract's own order, and nothing else. A key
    # the reader did not supply is present and $null rather than absent, because
    # strict mode throws on an absent property and a grading rule should read a
    # gap as a gap instead of crashing.
    $cpuBlock = [ordered]@{}
    foreach ($key in @('Name', 'Vendor', 'X3D', 'Ccd', 'L3GroupCount', 'FrequencyCcd', 'TargetCpu', 'SmtOn')) {
        $cpuBlock[$key] = if ($null -ne $Cpu) { Get-KnownGoodField -Entry $Cpu -Name $key } else { $null }
    }

    $machine = [ordered]@{
        Schema           = 'simrig.machine-profile/1'
        TakenAt          = Format-SimRigTime -Time $TakenAt
        ComputerName     = $MachineName
        Cpu              = $cpuBlock
        CpuSteering      = $CpuSteering
        Gpu              = $Gpu
        Windows          = $Windows
        Display          = $Display
        IRacing          = $IRacing
        Confidence       = $Confidence
        ConfidenceReason = $ConfidenceReason
        Unavailable      = @($unavailable.ToArray())
    }

    # Flattened for Test-RuleApplies. Only set when actually read: an absent key
    # matches 'any' and nothing else, which is the honest answer for a field
    # nobody looked at.
    if (-not [string]::IsNullOrWhiteSpace($ProfileId)) { $machine['Profile'] = $ProfileId }
    if (-not [string]::IsNullOrWhiteSpace($NetworkAdapter)) { $machine['NetworkAdapter'] = $NetworkAdapter }
    if ($null -ne $BluetoothConnected) { $machine['BluetoothConnected'] = [bool]$BluetoothConnected }
    if ($null -ne $DefenderOptIn -and [bool]$DefenderOptIn) { $machine['DefenderOptIn'] = $true }
    if ($null -ne $Gpu) {
        $vendor = Get-KnownGoodField -Entry $Gpu -Name 'Vendor'
        if ($null -ne $vendor) { $machine['Gpu'] = $Gpu; $machine['GpuVendor'] = $vendor }
    }

    return $machine
}

function Select-QuietItemForMachine {
    <#
        .SYNOPSIS
        The quiet items that apply to this machine, in Order.

        .DESCRIPTION
        An item with no AppliesTo applies everywhere, which is what the great
        majority of the list is. An item with one is kept only when
        Test-RuleApplies agrees.

        With no machine at all every item is kept. The alternative - quieting
        nothing because discovery has not run - would turn a discovery failure
        into a silent no-op right before a race, and a pre-race script that
        quietly does nothing is worse than one that fails.

        Order is preserved. The quiet sequence is not arbitrary; items in the
        same group depend on the ones before them.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $QuietItem,
        [AllowNull()] $Machine
    )

    $items = @($QuietItem | Where-Object { $null -ne $_ })
    if ($null -eq $Machine) { return , @($items | Sort-Object -Property Order) }

    $kept = foreach ($item in $items) {
        $applies = Get-KnownGoodField -Entry $item -Name 'AppliesTo'
        if ($null -eq $applies) { $item; continue }
        if (Test-RuleApplies -Rule @{ AppliesTo = $applies } -Machine $Machine) { $item }
    }

    return , @(@($kept | Where-Object { $null -ne $_ }) | Sort-Object -Property Order)
}

function Get-QuietAppliesToKey {
    <#
        .SYNOPSIS
        The AppliesTo keys of the quiet list, in two lists. The one place for them.

        .DESCRIPTION
        Profile: a key whose value comes from the selected profile. It is known when the
        profile files load, at quiet time and at restore time the same.
        Reading: a key whose value comes from a reading of the machine. A reading can
        fail, or differ between quiet time and restore time.

        Select-QuietItemForProfile reads the Profile keys and no Reading key. A key of
        quiet-list.psd1 that is in neither list fails a test (QuietFilter.Tests.ps1): a
        new key needs a decision, and cannot pass in silence as a reading.

        Pure.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        Profile = @('Profile', 'DefenderOptIn')
        Reading = @('Ccd', 'BluetoothConnected', 'NetworkAdapter')
    }
}

function Select-QuietItemForProfile {
    <#
        .SYNOPSIS
        Each quiet item that a quiet on a PC with this profile could have changed, in
        Order. For a restore that has no snapshot (blocker 5, Cowork rulings 2026-10-02).

        .DESCRIPTION
        A key whose value comes from the selected profile takes an item out. A key whose
        value comes from a reading of the machine does not: a reading can fail at restore
        time, or differ from quiet time, and an item that was quieted and is not put back
        is the larger harm. The two lists of keys are in Get-QuietAppliesToKey.

        Quiet takes the narrow list (Select-QuietItemForMachine), because an item in
        doubt is not written. Restore takes this wide list, because an item in doubt is
        put back. A restore that writes a setting which no quiet on this PC could have
        changed is a write that the app did not tell the user about, so the Defender
        item is out when the profile has no opt-in.

        With no profile id (the profiles did not load) the items that name a profile are
        out and each other item stays, the Defender item also: on the rig a quiet can
        have turned Defender off, and "on" is the safe direction. The restore does not
        stop.

        Pure.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $QuietItem,
        [AllowNull()] [AllowEmptyString()] [string] $ProfileId,
        # The DefenderOptIn value of the selected profile. Not read when no profile id is given.
        [bool] $DefenderOptIn = $false
    )

    $profileKey = @((Get-QuietAppliesToKey).Profile)
    $loaded = -not [string]::IsNullOrWhiteSpace($ProfileId)
    # The same shape as the machine profile: DefenderOptIn is there only when it is true.
    $profileMachine = @{}
    if ($loaded) {
        $profileMachine['Profile'] = $ProfileId
        if ($DefenderOptIn) { $profileMachine['DefenderOptIn'] = $true }
    }

    $kept = foreach ($item in @($QuietItem | Where-Object { $null -ne $_ })) {
        $applies = Get-KnownGoodField -Entry $item -Name 'AppliesTo'
        if ($null -eq $applies) { $item; continue }
        $subset = @{}
        foreach ($key in @($applies.Keys)) {
            if ($profileKey -notcontains [string]$key) { continue }
            if (-not $loaded -and [string]$key -ne 'Profile') { continue }
            $subset[[string]$key] = $applies[$key]
        }
        if ($subset.Count -eq 0) { $item; continue }
        if (Test-RuleApplies -Rule @{ AppliesTo = $subset } -Machine $profileMachine) { $item }
    }

    return , @(@($kept | Where-Object { $null -ne $_ }) | Sort-Object -Property Order)
}

function Select-TickedQuietItem {
    <#
        .SYNOPSIS
        The items the user actually ticked. Spec 6: no write without a tick.

        .DESCRIPTION
        A tick set of $null means the caller passed no selection at all, and every
        item is returned - that is the deadman and the self-test, which act on the
        whole list by definition.

        A tick set that is present but empty returns nothing. That distinction is
        the whole point of this function: an empty selection must mean "write
        nothing", never "write everything". Treating the two the same is how a
        tickless run quiets a stranger's machine, and it is one line of code apart
        from the correct behaviour.

        An id in the tick set that matches no item is ignored rather than fatal.
        The list shrinks between versions and a stale id in a saved selection must
        not stop a session.

        Pure.

        .OUTPUTS
        [object[]] The selected items, in their original order.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $QuietItem,
        [AllowNull()] [AllowEmptyCollection()] [string[]] $Ticked
    )

    if ($null -eq $Ticked) { return , @($QuietItem) }

    $want = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($t in @($Ticked | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) { [void]$want.Add([string]$t) }
    if ($want.Count -eq 0) { return @() }

    $hit = @($QuietItem | Where-Object { $null -ne $_ -and $want.Contains([string]$_.Id) })
    if ($hit.Count -eq 0) { return @() }
    return , @($hit)
}
