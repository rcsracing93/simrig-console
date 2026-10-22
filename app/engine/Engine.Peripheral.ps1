<#
    Engine.Peripheral.ps1 - lead, 2026-09-26.

    The pure half of three readings the v4.2 wiring found missing: which kind of
    network adapter carries the default route, whether a Bluetooth device is
    connected, and the display-path records Engine.Layout.ps1 grades.

    quiet-list.psd1 gates WlanSvc on the first (G-1) and the three Bluetooth
    services on the second (G-2). Both guards were dead until now, because an
    unread field matches nothing, so the services were never offered at all.

    Every Windows call lives in SimRig.Probe.ps1. This file makes the decisions on
    what those calls return, which is where the mistakes live. Pure: no clock,
    filesystem, registry, process or environment read.
#>

Set-StrictMode -Version Latest

function Resolve-NetworkAdapterKind {
    <#
        .SYNOPSIS
        Ethernet, Wi-Fi, Other or Unknown, from a PhysicalMediaType string.

        .DESCRIPTION
        The values are Microsoft's documented PhysicalMediaType names. A string
        this function does not recognize is Unknown, never Ethernet - and that
        matters more than it looks. The G-1 guard only offers WlanSvc on a wired
        machine, so a wrong Ethernet answer would switch off the wireless on a
        laptop racing over Wi-Fi, which is the single worst thing this app could do
        to a stranger. Unknown fails the guard and the service is left alone.

        .OUTPUTS
        [pscustomobject] Kind Confidence Reason
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $PhysicalMediaType
    )

    if ([string]::IsNullOrWhiteSpace($PhysicalMediaType)) {
        return [pscustomobject]@{
            Kind = 'Unknown'; Confidence = 'Unknown'
            Reason = 'No PhysicalMediaType was read, so the adapter kind is unknown and any rule that depends on it will not apply.'
        }
    }

    $text = $PhysicalMediaType.Trim()
    $wired = @('802.3', 'Ethernet')
    $wireless = @('Native 802.11', 'Wireless WAN', 'Wireless LAN')

    foreach ($candidate in $wired) {
        if ([string]::Equals($text, $candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Kind = 'Ethernet'; Confidence = 'Read'; Reason = $null }
        }
    }
    foreach ($candidate in $wireless) {
        if ([string]::Equals($text, $candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Kind = 'Wi-Fi'; Confidence = 'Read'; Reason = $null }
        }
    }
    # Bluetooth personal-area networking lands here rather than in Wi-Fi: it is
    # neither, and calling it wireless would make the WlanSvc guard reason about
    # the wrong radio.
    foreach ($candidate in @('BlueTooth', 'Infrared', 'USB')) {
        if ([string]::Equals($text, $candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Kind = 'Other'; Confidence = 'Read'; Reason = $null }
        }
    }

    return [pscustomobject]@{
        Kind = 'Unknown'; Confidence = 'Unknown'
        Reason = ("PhysicalMediaType '{0}' is not one this build recognizes, so the adapter kind is unknown rather than guessed." -f $text)
    }
}

function Resolve-BluetoothConnected {
    <#
        .SYNOPSIS
        Whether a Bluetooth device is connected, from a PnP device list.

        .DESCRIPTION
        A heuristic, and disclosed as one. Windows enumerates a connected Bluetooth
        device as a child node under the BTHENUM enumerator, or BTHLEDEVICE for
        Bluetooth Low Energy. Counting those nodes with status OK is the closest
        thing to "something is connected" that a plain PnP read gives.

        The radio itself is deliberately not counted. A PC with Bluetooth switched
        on and nothing paired still enumerates its adapter, and counting that would
        stop the Bluetooth services ever being offered on any machine that has
        Bluetooth hardware - which is most of them.

        A $null list is Unknown, not false. False means the read happened and found
        nothing; Unknown means the read did not happen, and the G-2 guard must not
        fire on it.

        .OUTPUTS
        [pscustomobject] Connected Count Confidence Reason
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Device
    )

    $reason = 'Heuristic: a connected device appears as a child node under the BTHENUM or BTHLEDEVICE enumerator. The radio itself is not counted, because an adapter with nothing paired enumerates too.'

    if ($null -eq $Device) {
        return [pscustomobject]@{ Connected = $null; Count = $null; Confidence = 'Unknown'; Reason = ('The Bluetooth device list could not be read, so this is unknown rather than false. ' + $reason) }
    }

    $count = 0
    foreach ($d in @($Device)) {
        if ($null -eq $d) { continue }
        $id = Get-KnownGoodField -Entry $d -Name 'InstanceId'
        $status = Get-KnownGoodField -Entry $d -Name 'Status'
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if (-not [string]::Equals([string]$status, 'OK', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($id -match '^(BTHENUM|BTHLEDEVICE)\\') { $count++ }
    }

    return [pscustomobject]@{
        Connected  = ($count -gt 0)
        Count      = $count
        Confidence = 'Read'
        Reason     = $reason
    }
}

function ConvertTo-DisplayPathRecord {
    <#
        .SYNOPSIS
        Display-path records in the shape Engine.Layout.ps1 grades.

        .DESCRIPTION
        Takes screen rectangles - X, Y, Width, Height, Primary - and a refresh
        rate, and produces the Active / PositionX / PositionY / Width / Height /
        RefreshRateHz records ConvertFrom-DisplayConfig defines. Every screen the
        list carries is active by definition: an inactive display is not in it.

        A refresh rate that was not read is 0, not 60. A number this app invented
        would be graded as if it had been measured, and a zero is visibly a gap.

        .OUTPUTS
        [object[]] Active PositionX PositionY Width Height RefreshRateHz
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Screen,
        [AllowNull()] $RefreshRateHz
    )

    $rate = if ($null -eq $RefreshRateHz) { [double]0 } else { [double]$RefreshRateHz }

    $records = foreach ($s in @($Screen)) {
        if ($null -eq $s) { continue }
        [pscustomobject]@{
            Active        = $true
            PositionX     = [int](Get-KnownGoodField -Entry $s -Name 'X')
            PositionY     = [int](Get-KnownGoodField -Entry $s -Name 'Y')
            Width         = [int](Get-KnownGoodField -Entry $s -Name 'Width')
            Height        = [int](Get-KnownGoodField -Entry $s -Name 'Height')
            RefreshRateHz = $rate
        }
    }

    return , @(@($records | Where-Object { $null -ne $_ }) | Sort-Object -Property PositionX)
}
