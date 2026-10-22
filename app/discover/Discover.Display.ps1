<#
    Discover.Display.ps1 - unit U3.2

    Part of the new SimRig.Discover.ps1 (V4.2-SPEC section 4). Reads the
    connected displays for the `Display` block of `simrig.machine-profile/1`
    (CONTRACT.md).

    QueryDisplayConfig cannot run on Linux, so this file never calls it (or
    any live cmdlet) itself. It takes the raw path/mode records as a
    parameter and shapes them - the same split Engine.Parsers.ps1 uses for
    ConvertFrom-ScQc and friends, so the parser is testable without Windows
    (honesty rule). The live P/Invoke call that fills these records is owned
    by SimRig.Probe.ps1, not by this file.

    The record shape mirrors QueryDisplayConfig's real, documented Win32
    fields: an active DISPLAYCONFIG_PATH_INFO has a source position
    (DISPLAYCONFIG_SOURCE_MODE.position, PositionX/PositionY here) and an
    active size and refresh rate (DISPLAYCONFIG_TARGET_MODE video signal
    info, Width/Height/RefreshRateHz here). No field here is invented; see
    NOTES.md for the one field this build has no real capture of
    (VRR/G-Sync, spec section 4: "not readable without NVAPI. Manual" - left
    out of this file entirely, not guessed).
#>

Set-StrictMode -Version 3.0

function ConvertFrom-DisplayConfig {
    <#
        .SYNOPSIS
        Shapes raw QueryDisplayConfig path/mode records into display
        readings.

        .PARAMETER Path
        One record per display path Windows returns: Active (bool),
        PositionX, PositionY (source mode position, pixels),
        Width, Height (target mode active size, pixels),
        RefreshRateHz (target mode refresh rate as a double - Windows
        reports this as a rational Numerator/Denominator; the caller divides
        before this function sees it, so no rounding choice is hidden here).
        An inactive path (Active = $false) is kept, never dropped, so a
        caller can see a display that is connected but off.

        .OUTPUTS
        [pscustomobject[]] Active PositionX PositionY Width Height
        RefreshRateHz - the same field names Engine.Layout.ps1's
        Get-SimRigDisplayLayout takes as -Path.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Path
    )

    $rows = foreach ($p in $Path) {
        [pscustomobject]@{
            Active        = [bool]$p.Active
            PositionX     = [int]$p.PositionX
            PositionY     = [int]$p.PositionY
            Width         = [int]$p.Width
            Height        = [int]$p.Height
            RefreshRateHz = [double]$p.RefreshRateHz
        }
    }

    return , @($rows)
}

function Get-SimRigDisplayDiscovery {
    <#
        .SYNOPSIS
        Builds the `Display` block of `simrig.machine-profile/1` from a
        shaped path reading and the physical monitor count. Does not decide
        the layout - that is Engine.Layout.ps1's Get-SimRigDisplayLayout,
        called by the caller (Probe/Discover integration), not from here, so
        this file stays a plain reader and the layout inference stays in one
        pure place.

        .PARAMETER Path
        Shaped path records - ConvertFrom-DisplayConfig's output, or
        anything with the same fields.

        .PARAMETER MonitorCount
        Active physical monitor count (WmiMonitorBasicDisplayParams,
        root\wmi). $null when that reading failed or was not taken.

        .OUTPUTS
        [pscustomobject] Count (active paths) Refresh (primary path's
        refresh rate) Paths (the shaped records, for the layout inference)
        MonitorCount Confidence (hashtable: Count/Refresh 'Read' when at
        least one active path exists, else 'Unknown'; MonitorCount 'Read'
        when supplied, else 'Unknown').
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Path,
        [AllowNull()] [Nullable[int]] $MonitorCount
    )

    $active = @($Path | Where-Object { $_.Active })
    $primary = $active | Where-Object { $_.PositionX -eq 0 -and $_.PositionY -eq 0 } | Select-Object -First 1
    if (-not $primary) { $primary = $active | Select-Object -First 1 }

    $confidence = [ordered]@{
        Count        = if ($active.Count -gt 0) { 'Read' } else { 'Unknown' }
        Refresh      = if ($primary) { 'Read' } else { 'Unknown' }
        MonitorCount = if ($null -ne $MonitorCount) { 'Read' } else { 'Unknown' }
    }

    return [pscustomobject]@{
        Count        = $active.Count
        Refresh      = if ($primary) { $primary.RefreshRateHz } else { $null }
        Paths        = @($Path)
        MonitorCount = $MonitorCount
        Confidence   = $confidence
    }
}
