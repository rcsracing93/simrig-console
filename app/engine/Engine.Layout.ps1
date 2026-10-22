<#
    Engine.Layout.ps1 - unit U3.2

    Pure function. No clock, no filesystem, no registry, no processes, no
    Get-Date, no $env:. Inputs are parameters only (CONTRACT.md coding rules).

    Works out the display layout - Single, Multi, or Surround - from display
    readings shaped like Discover.Display.ps1's output (CONTRACT.md
    simrig.machine-profile/1, the Display block).

    Windows never reports "Surround" directly. NVIDIA Surround (or an NVIDIA
    Mosaic span) shows Windows one merged display path whose width is the sum
    of the physical monitors, while the physical-monitor count (EDIDs, from
    WmiMonitorBasicDisplayParams) still shows every real screen. Surround is
    therefore inferred from "fewer active display paths than physical
    monitors", never from width alone - a single wide monitor (32:9,
    5120x1440 or 7680x2160) has the same width shape as a three-wide span but
    only one EDID, so a width-only test misclassifies it (build brief flag 7
    background; FABLE-REVIEW-v4.2-2026-09-19.md question 4).
#>

Set-StrictMode -Version 3.0

function Get-SimRigDisplayLayout {
    <#
        .SYNOPSIS
        Infers the display layout from display path readings and the
        physical monitor count.

        .PARAMETER Path
        One record per display path Windows reports (shaped like
        Discover.Display.ps1's ConvertFrom-DisplayConfig output - the fields
        mirror QueryDisplayConfig's DISPLAYCONFIG_PATH_INFO / mode info):
        Active (bool), PositionX, PositionY, Width, Height, RefreshRateHz.

        .PARAMETER MonitorCount
        The count of active physical monitors (EDIDs), read separately from
        WmiMonitorBasicDisplayParams (root\wmi). $null when that reading is
        not available - the function still returns a layout, but never
        Surround, because Surround cannot be told apart from a single wide
        monitor without this count.

        .OUTPUTS
        [pscustomobject] Layout (Single|Multi|Surround|Unknown), Confidence
        (Read|Inferred|Unknown), Count (active display paths), Refresh (the
        primary path's refresh rate, $null if none), Reason (one line,
        states the evidence and, for Surround, the inference's limits).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Path,
        [AllowNull()] [Nullable[int]] $MonitorCount
    )

    $activePath = @($Path | Where-Object { $_.Active })
    $activeCount = $activePath.Count

    if ($activeCount -eq 0) {
        return [pscustomobject]@{
            Layout     = 'Unknown'
            Confidence = 'Unknown'
            Count      = 0
            Refresh    = $null
            Reason     = 'No active display path was reported.'
        }
    }

    # The primary path is the one at the Windows origin (0,0); every layout
    # Windows can produce has exactly one path there. Fall back to the first
    # path if none sits at the origin (a malformed reading).
    $primary = $activePath | Where-Object { $_.PositionX -eq 0 -and $_.PositionY -eq 0 } | Select-Object -First 1
    if (-not $primary) { $primary = $activePath[0] }
    $refresh = $primary.RefreshRateHz

    if ($null -eq $MonitorCount) {
        if ($activeCount -eq 1) {
            $aspect = if ($primary.Height -gt 0) { $primary.Width / $primary.Height } else { 0 }
            if ($aspect -ge 2.9) {
                return [pscustomobject]@{
                    Layout     = 'Unknown'
                    Confidence = 'Unknown'
                    Count      = 1
                    Refresh    = $refresh
                    Reason     = ('One active display path at {0}x{1}, aspect {2:N2}:1. This matches both a Surround span and a single ultra-wide monitor (32:9). No physical monitor count was supplied, so the two cannot be told apart.' -f $primary.Width, $primary.Height, $aspect)
                }
            }
            return [pscustomobject]@{
                Layout     = 'Single'
                Confidence = 'Read'
                Count      = 1
                Refresh    = $refresh
                Reason     = 'One active display path, standard aspect ratio.'
            }
        }
        return [pscustomobject]@{
            Layout     = 'Multi'
            Confidence = 'Inferred'
            Count      = $activeCount
            Refresh    = $refresh
            Reason     = ("$activeCount active display paths. No physical monitor count was supplied, so a Surround span spread over fewer paths than monitors cannot be ruled out for any single path; each path here is read as its own screen.")
        }
    }

    if ($activeCount -eq $MonitorCount) {
        if ($activeCount -le 1) {
            return [pscustomobject]@{
                Layout     = 'Single'
                Confidence = 'Read'
                Count      = 1
                Refresh    = $refresh
                Reason     = 'One active display path and one physical monitor.'
            }
        }
        return [pscustomobject]@{
            Layout     = 'Multi'
            Confidence = 'Read'
            Count      = $activeCount
            Refresh    = $refresh
            Reason     = ("$activeCount active display paths and $MonitorCount physical monitors - each monitor has its own path, not a span.")
        }
    }

    if ($activeCount -lt $MonitorCount) {
        return [pscustomobject]@{
            Layout     = 'Surround'
            Confidence = 'Inferred'
            Count      = $activeCount
            Refresh    = $refresh
            Reason     = ("$MonitorCount physical monitors but only $activeCount active display path(s) - Windows is showing a merged span. Surround is inferred, not reported: this fails if NVIDIA Mosaic bezel correction changes the merged width, if a monitor is duplicating another (mirrored, not spanned) rather than spanning, or if one of the '$MonitorCount' EDIDs is a non-display device that answers the WMI query. The user confirms the layout before grading uses it (spec section 4).")
        }
    }

    return [pscustomobject]@{
        Layout     = 'Unknown'
        Confidence = 'Unknown'
        Count      = $activeCount
        Refresh    = $refresh
        Reason     = ("$activeCount active display paths but only $MonitorCount physical monitor(s) reported - more paths than monitors is not a layout this function classifies (for example a wireless or virtual display with no EDID). Recorded as Unknown, not guessed.")
    }
}
