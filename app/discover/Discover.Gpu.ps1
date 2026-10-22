<#
    Discover.Gpu.ps1 - unit U3.2

    Part of the new SimRig.Discover.ps1 (V4.2-SPEC section 4). Fills the
    `Gpu` block of `simrig.machine-profile/1` (CONTRACT.md).

    Read-only. Every value this file returns comes from a parameter the
    caller supplies (Get-PnpDevice, registry reads, Get-PnpDeviceProperty) -
    this file never calls those cmdlets itself, so it runs and is tested the
    same way on Linux as on Windows (honesty rule: parser tokens come from
    real files, never from memory).

    Build brief flag 7 binding rule: the public build steers PnP class
    Display functions only, and records - but never touches - the audio and
    USB functions the same GPU exposes. Get-SimRigGpuFunction reads the PnP
    Class of every present NVIDIA function and marks each one's Role, so the
    Fix (owned elsewhere) can select on Role -eq 'Display' and nothing else.

    Flag 7 also binds: "Discovery records GPU PCIe link width and speed,
    current and max. Info only." Get-SimRigGpuFunction records both pairs
    when the caller supplies them; it never grades them; a rules file (not
    owned by this unit) is what would ever turn them into a Pass/Fail row.

    No real capture of MSI support, driver version or PCIe link width/speed
    exists anywhere in the fixtures (see NOTES.md). Those fields are read
    when the caller supplies a value and recorded as Confidence 'Unknown'
    (never invented) when it does not.
#>

Set-StrictMode -Version 3.0

function Get-SimRigGpuFunction {
    <#
        .SYNOPSIS
        Shapes present NVIDIA PCI functions plus their interrupt policy,
        MSI support, driver version and PCIe link reading into one record
        per function.

        .PARAMETER PnpDevice
        One record per present PCI function (Get-PnpDevice -PresentOnly
        shape): InstanceId, LocationPath (DEVPKEY_Device_LocationPaths,
        first PCIROOT entry - the identity that survives a re-enumeration,
        see engine/Engine.GpuSteering.ps1), DeviceId ('DEV_xxxx'), Class (the PnP class
        Windows assigns the function - 'Display', 'MEDIA' for the HD Audio
        function, 'USB' for a USB-C/VirtualLink function on some cards),
        FriendlyName.

        .PARAMETER AffinityPolicy
        Hashtable InstanceId -> @{ DevicePolicy; AssignmentSetOverride;
        MsiSupported; MsiMessageLimit }. Read from
        'Enum\<InstanceId>\Device Parameters\Interrupt Management\Affinity
        Policy' (DevicePolicy, AssignmentSetOverride) and
        '...\Interrupt Management\MessageSignaledInterruptProperties'
        (MSISupported, MessageNumberLimit). Any key may be absent.

        .PARAMETER DriverVersion
        Hashtable InstanceId -> driver version string
        (DEVPKEY_Device_DriverVersion). May be absent for an instance.

        .PARAMETER LinkInfo
        Hashtable InstanceId -> @{ WidthCurrent; WidthMax; SpeedCurrentGTs;
        SpeedMaxGTs } (DEVPKEY_PciDevice_Current/MaxLinkWidth,
        DEVPKEY_PciDevice_Current/MaxLinkSpeed). Info only - never graded
        here. May be absent for an instance.

        .PARAMETER VendorId
        PCI vendor id prefix to keep, default 'VEN_10DE' (NVIDIA).

        .OUTPUTS
        [pscustomobject[]] one per present function of the vendor: InstanceId
        DeviceId Class Role(Display|Audio|USB|Other) Steerable(bool)
        FriendlyName DevicePolicy AssignmentSetOverride MsiSupported
        MsiMessageLimit DriverVersion LinkWidth(Current,Max)
        LinkSpeed(Current,Max) Confidence (hashtable, one entry per field
        above that can be Read or Unknown).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $PnpDevice,
        [hashtable] $AffinityPolicy = @{},
        [hashtable] $DriverVersion = @{},
        [hashtable] $LinkInfo = @{},
        [string] $VendorId = 'VEN_10DE'
    )

    $matching = @($PnpDevice | Where-Object { $_.InstanceId -like ('PCI\{0}*' -f $VendorId) })

    $rows = foreach ($d in $matching) {
        $class = if ($d.PSObject.Properties.Match('Class').Count -gt 0) { $d.Class } else { $null }
        $role = switch -Regex ($class) {
            '^Display$' { 'Display'; break }
            '^MEDIA$'   { 'Audio'; break }
            '^USB$'     { 'USB'; break }
            default     { 'Other' }
        }
        $steerable = ($role -eq 'Display')

        $policy = $null; $mask = $null; $msiOn = $null; $msiLimit = $null
        if ($AffinityPolicy.ContainsKey($d.InstanceId)) {
            $entry = $AffinityPolicy[$d.InstanceId]
            if ($entry.ContainsKey('DevicePolicy')) { $policy = $entry.DevicePolicy }
            if ($entry.ContainsKey('AssignmentSetOverride')) { $mask = $entry.AssignmentSetOverride }
            if ($entry.ContainsKey('MsiSupported')) { $msiOn = $entry.MsiSupported }
            if ($entry.ContainsKey('MsiMessageLimit')) { $msiLimit = $entry.MsiMessageLimit }
        }

        $driver = if ($DriverVersion.ContainsKey($d.InstanceId)) { $DriverVersion[$d.InstanceId] } else { $null }

        $widthCurrent = $null; $widthMax = $null; $speedCurrent = $null; $speedMax = $null
        if ($LinkInfo.ContainsKey($d.InstanceId)) {
            $link = $LinkInfo[$d.InstanceId]
            if ($link.ContainsKey('WidthCurrent')) { $widthCurrent = $link.WidthCurrent }
            if ($link.ContainsKey('WidthMax')) { $widthMax = $link.WidthMax }
            if ($link.ContainsKey('SpeedCurrentGTs')) { $speedCurrent = $link.SpeedCurrentGTs }
            if ($link.ContainsKey('SpeedMaxGTs')) { $speedMax = $link.SpeedMaxGTs }
        }

        $locationPath = if ($d.PSObject.Properties.Match('LocationPath').Count -gt 0) { $d.LocationPath } else { $null }

        $confidence = [ordered]@{
            Class                  = if ($class) { 'Read' } else { 'Unknown' }
            LocationPath           = if (-not [string]::IsNullOrWhiteSpace($locationPath)) { 'Read' } else { 'Unknown' }
            DevicePolicy           = if ($null -ne $policy) { 'Read' } else { 'Unknown' }
            AssignmentSetOverride  = if ($null -ne $mask) { 'Read' } else { 'Unknown' }
            MsiSupported           = if ($null -ne $msiOn) { 'Read' } else { 'Unknown' }
            DriverVersion          = if ($null -ne $driver) { 'Read' } else { 'Unknown' }
            LinkWidth              = if ($null -ne $widthCurrent -or $null -ne $widthMax) { 'Read' } else { 'Unknown' }
            LinkSpeed              = if ($null -ne $speedCurrent -or $null -ne $speedMax) { 'Read' } else { 'Unknown' }
        }

        [pscustomobject]@{
            InstanceId             = $d.InstanceId
            LocationPath           = $locationPath
            DeviceId               = $d.DeviceId
            Class                  = $class
            Role                   = $role
            Steerable              = $steerable
            FriendlyName           = if ($d.PSObject.Properties.Match('FriendlyName').Count -gt 0) { $d.FriendlyName } else { $null }
            DevicePolicy           = $policy
            AssignmentSetOverride  = $mask
            MsiSupported           = $msiOn
            MsiMessageLimit        = $msiLimit
            DriverVersion          = $driver
            LinkWidth              = [pscustomobject]@{ Current = $widthCurrent; Max = $widthMax }
            LinkSpeed              = [pscustomobject]@{ Current = $speedCurrent; Max = $speedMax }
            Confidence             = $confidence
        }
    }

    return , @($rows)
}

function Get-SimRigGpuDiscovery {
    <#
        .SYNOPSIS
        Builds the `Gpu` block of `simrig.machine-profile/1` from present
        NVIDIA PCI functions.

        .DESCRIPTION
        Calls Get-SimRigGpuFunction for the per-function detail, then rolls
        the Display-class function's own readings up to the block's flat
        Model/DriverVersion/LinkWidth/LinkSpeed fields (CONTRACT.md:
        `Gpu = @{ Vendor; Model; DriverVersion; LinkWidth; LinkSpeed;
        Functions = @() }`). A card with no present Display-class function
        (steering already lost, or a non-NVIDIA machine) leaves those four
        fields $null; Functions still lists whatever is present.

        .OUTPUTS
        [pscustomobject] Vendor Model DriverVersion LinkWidth LinkSpeed
        Functions Confidence (hashtable, block-level fields only - each
        function carries its own Confidence).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $PnpDevice,
        [hashtable] $AffinityPolicy = @{},
        [hashtable] $DriverVersion = @{},
        [hashtable] $LinkInfo = @{},
        [string] $VendorId = 'VEN_10DE'
    )

    $functions = Get-SimRigGpuFunction -PnpDevice $PnpDevice -AffinityPolicy $AffinityPolicy `
        -DriverVersion $DriverVersion -LinkInfo $LinkInfo -VendorId $VendorId

    $display = $functions | Where-Object { $_.Role -eq 'Display' } | Select-Object -First 1

    $vendor = if ($VendorId -eq 'VEN_10DE') { 'NVIDIA' } else { $VendorId }

    $confidence = [ordered]@{
        Model         = if ($display -and $display.FriendlyName) { 'Read' } else { 'Unknown' }
        DriverVersion = if ($display -and $null -ne $display.DriverVersion) { 'Read' } else { 'Unknown' }
        LinkWidth     = if ($display -and $display.Confidence.LinkWidth -eq 'Read') { 'Read' } else { 'Unknown' }
        LinkSpeed     = if ($display -and $display.Confidence.LinkSpeed -eq 'Read') { 'Read' } else { 'Unknown' }
    }

    return [pscustomobject]@{
        Vendor        = $vendor
        Model         = if ($display) { $display.FriendlyName } else { $null }
        DriverVersion = if ($display) { $display.DriverVersion } else { $null }
        LinkWidth     = if ($display) { $display.LinkWidth } else { [pscustomobject]@{ Current = $null; Max = $null } }
        LinkSpeed     = if ($display) { $display.LinkSpeed } else { [pscustomobject]@{ Current = $null; Max = $null } }
        Functions     = $functions
        Confidence    = $confidence
    }
}
