<#
    Engine.GpuSteering.ps1 - lead, 2026-09-25.

    Stable identity for a GPU PCI function, and a comparison of two function
    sets across a re-enumeration.

    Why. The two T.9 race sessions on 2026-09-20, one hour apart with no
    hardware change and no driver install, read different PnP instance ids for
    the same two NVIDIA functions (4&1BABDF5B&... became 4&285F7309&...). The
    instance id is the registry WRITE address - the policy lives at
    Enum\<InstanceId>\Device Parameters\Interrupt Management\... - but it is not
    an identity that survives a boot. The location path is.

    v4.0.6 is not broken by this: it grades on DeviceId plus an expected count,
    so both sessions passed (count 2 of 2). This file exists so that the public
    GPU Fix rules and the "did steering survive the driver update" comparison,
    which wave 3b is about to build, are never written against the instance id
    in the first place.

    Pure. No Windows calls. Runs on Linux under Pester.
#>

Set-StrictMode -Version Latest

function Get-GpuSteeringIdentity {
    <#
        .SYNOPSIS
        The stable identity of one GPU PCI function.

        .DESCRIPTION
        Prefers the location path, which survives a re-enumeration. Falls back
        to the instance id when no location path was read, and says so through
        Source and Confidence so a caller never mistakes the fallback for a
        stable key.

        .OUTPUTS
        [pscustomobject] Key Source WriteAddress Confidence Reason
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Function
    )

    $loc = $null
    if ($Function.PSObject.Properties.Match('LocationPath').Count -gt 0) {
        $loc = $Function.LocationPath
    }

    $instance = $null
    if ($Function.PSObject.Properties.Match('InstanceId').Count -gt 0) {
        $instance = $Function.InstanceId
    }

    if (-not [string]::IsNullOrWhiteSpace($loc)) {
        return [pscustomobject]@{
            Key          = $loc
            Source       = 'location-path'
            WriteAddress = $instance
            Confidence   = 'Read'
            Reason       = $null
        }
    }

    return [pscustomobject]@{
        Key          = $instance
        Source       = 'instance-id'
        WriteAddress = $instance
        Confidence   = 'Inferred'
        Reason       = 'No location path was read, so the instance id is standing in. It changes when Windows re-enumerates the device, so do not store this key across boots.'
    }
}

function Compare-GpuFunctionSet {
    <#
        .SYNOPSIS
        Compares an expected set of GPU functions with what was found, by
        stable identity.

        .DESCRIPTION
        Matched, Missing and Added are decided on the identity key, so a pure
        re-enumeration reports Reenumerated with Changed false. A matched
        function that lost its DevicePolicy or its AssignmentSetOverride is
        reported in PolicyLost and does set Changed.

        CountOk answers the "GPU interrupt steering count" check: it is met when
        the matched count reaches ExpectedCount, whatever the instance ids did.
        With no ExpectedCount it falls back to the expected set's own size.

        .OUTPUTS
        [pscustomobject] MatchedCount Missing Added PolicyLost Reenumerated
        Changed CountOk Identity
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Expected,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Found,
        [int] $ExpectedCount = 0
    )

    $expectedById = [ordered]@{}
    foreach ($fn in $Expected) {
        $id = Get-GpuSteeringIdentity -Function $fn
        if ($id.Key) { $expectedById[$id.Key] = $fn }
    }

    $foundById = [ordered]@{}
    $identity = [ordered]@{}
    foreach ($fn in $Found) {
        $id = Get-GpuSteeringIdentity -Function $fn
        if ($id.Key) {
            $foundById[$id.Key] = $fn
            $identity[$id.Key] = $id
        }
    }

    $matched = @($expectedById.Keys | Where-Object { $foundById.Contains($_) })
    $missing = @($expectedById.Keys | Where-Object { -not $foundById.Contains($_) })
    $added = @($foundById.Keys | Where-Object { -not $expectedById.Contains($_) })

    $policyLost = foreach ($key in $matched) {
        $was = $expectedById[$key]
        $now = $foundById[$key]
        $hadPolicy = (Get-GpuSteeringField -Function $was -Name 'DevicePolicy')
        $hasPolicy = (Get-GpuSteeringField -Function $now -Name 'DevicePolicy')
        $hadMask = (Get-GpuSteeringField -Function $was -Name 'AssignmentSetOverride')
        $hasMask = (Get-GpuSteeringField -Function $now -Name 'AssignmentSetOverride')
        if (($null -ne $hadPolicy -and $null -eq $hasPolicy) -or
            ($null -ne $hadMask -and $null -eq $hasMask)) { $key }
    }
    $policyLost = @($policyLost)

    # A re-enumeration: every function matched by identity, and at least one
    # write address moved.
    $addressMoved = $false
    foreach ($key in $matched) {
        $wasId = Get-GpuSteeringIdentity -Function $expectedById[$key]
        $nowId = Get-GpuSteeringIdentity -Function $foundById[$key]
        if ($wasId.WriteAddress -ne $nowId.WriteAddress) { $addressMoved = $true }
    }
    $reenumerated = ($addressMoved -and $missing.Count -eq 0)

    $want = if ($ExpectedCount -gt 0) { $ExpectedCount } else { $expectedById.Count }

    return [pscustomobject]@{
        MatchedCount = $matched.Count
        Missing      = $missing
        Added        = $added
        PolicyLost   = $policyLost
        Reenumerated = $reenumerated
        Changed      = (($missing.Count -gt 0) -or ($added.Count -gt 0) -or ($policyLost.Count -gt 0))
        CountOk      = ($matched.Count -ge $want)
        Identity     = $identity
    }
}

function Get-GpuSteeringField {
    <#
        .SYNOPSIS
        Reads one field off a function object, or $null when it is absent.

        .DESCRIPTION
        Strict mode throws on a property that is not there, and a function
        reading from an older schema may be missing any of these.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [object] $Function,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($Function.PSObject.Properties.Match($Name).Count -eq 0) { return $null }
    return $Function.$Name
}
