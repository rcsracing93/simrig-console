# Engine.Score.ps1 - SimRig Console v4.2 (unit U3.5: the stutter score)
#
# Pure functions only: no Get-Date, no filesystem, no registry, no processes,
# no $env:. Every input arrives as a parameter (CONTRACT.md). This file reads
# a CapFrameX capture and produces the numbers spec section 7 names: average
# FPS, 1% low, 0.1% low, worst frame, stalls over 25 ms per 100 s, stalls
# over 40 ms per 100 s, and the capture length.
#
# The integrity gate (Test-BundleFile / Test-BundleIntegrity, already in
# SimRig.Engine.ps1) runs BEFORE any score is computed - Get-CaptureScore
# below is the seam that enforces that order. A truncated or malformed
# CapFrameX file is refused there, so a partial capture can never produce a
# score that looks real.
#
# Formulas match tc-session-analyzer's ingest_session.py (skill v2.1)
# exactly, so a real rig capture scores the same on both sides - that
# agreement is the test (A-SCORE-01). See _wip/U3.5/NOTES.md for the three
# captures compared and the numbers from each side.
#
# Set-StrictMode is applied once by the concatenated SimRig.Engine.ps1 / by
# each test file - this part does not set it itself.

function ConvertFrom-CapFrameXCapture {
    <#
        .SYNOPSIS
        Extracts the per-frame time series (ms) from a parsed CapFrameX
        capture. Pure text-in, records-out: no file access happens here, the
        caller (Probe) already read the bytes into $Text.

        .DESCRIPTION
        Mirrors tc-session-analyzer's extract_frame_series(): the frame
        series lives at Runs[0].CaptureData.MsBetweenPresents when a "Runs"
        array is present, or at CaptureData.MsBetweenPresents (or the
        document root) otherwise. This function is called only after the
        integrity gate (Test-BundleFile) has already passed the same text,
        so a missing or mismatched MsBetweenPresents here is treated as a
        genuine parse failure, not a truncation case.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    try {
        $data = ConvertFrom-Json -InputObject $Text -ErrorAction Stop
    } catch {
        throw "ConvertFrom-CapFrameXCapture: could not parse CapFrameX JSON - $($_.Exception.Message)"
    }

    $run = $data
    $runs = Get-KnownGoodField -Entry $data -Name 'Runs'
    if ($null -ne $runs -and @($runs).Count -gt 0) {
        $run = @($runs)[0]
    }

    $capture = Get-KnownGoodField -Entry $run -Name 'CaptureData'
    if ($null -eq $capture) { $capture = $run }

    $frameTimes = Get-KnownGoodField -Entry $capture -Name 'MsBetweenPresents'
    if ($null -eq $frameTimes) {
        $frameTimes = Get-KnownGoodField -Entry $capture -Name 'FrameTimes'
    }
    if ($null -eq $frameTimes) {
        throw 'ConvertFrom-CapFrameXCapture: no MsBetweenPresents (or FrameTimes) series in this capture - check the export format.'
    }

    return [pscustomobject]@{
        FrameTimesMs = [double[]] @($frameTimes)
    }
}

function Get-StutterScore {
    <#
        .SYNOPSIS
        The stutter score (spec section 7): average FPS, 1% low, 0.1% low,
        worst frame, stalls over 25 ms per 100 s, stalls over 40 ms per
        100 s, and the capture length - from an already-parsed frame-time
        series.

        .DESCRIPTION
        Formulas, matched to tc-session-analyzer's analyze_frametimes():
          DurationSeconds    = sum(FrameTimesMs) / 1000            (NOT wall clock - the sum of the frame times themselves, same as the analyzer)
          AvgFps             = 1000 / (sum(FrameTimesMs) / n)
          OnePctLowFps       = 1000 / (mean of the slowest ceil-free 1% of frames, by ms)   [see NOTES.md: max(1, floor(n*0.01)) frames]
          PointOnePctLowFps  = same, slowest 0.1% of frames
          WorstFrameMs       = max(FrameTimesMs)
          StallRate25Per100s = count(frame > 25 ms) / DurationSeconds * 100
          StallRate40Per100s = count(frame > 40 ms) / DurationSeconds * 100
        The two stall rates are the fair metric across sessions of different
        length (tc-session-analyzer, Step 3) - a raw count is never compared
        across captures.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [double[]] $FrameTimesMs
    )

    $n = $FrameTimesMs.Count
    if ($n -eq 0) {
        throw 'Get-StutterScore: the capture has zero frames (empty MsBetweenPresents) - nothing to score.'
    }

    $sum = 0.0
    foreach ($ft in $FrameTimesMs) { $sum += $ft }
    $durationSeconds = $sum / 1000.0
    $avgMs = $sum / $n
    $avgFps = 1000.0 / $avgMs

    $sorted = @($FrameTimesMs | Sort-Object)

    # int(n * 0.01) in Python truncates toward zero for a positive value,
    # same as a plain [int] cast in PowerShell here.
    $onePctN = [Math]::Max(1, [int][Math]::Truncate($n * 0.01))
    $pointOnePctN = [Math]::Max(1, [int][Math]::Truncate($n * 0.001))

    $onePctSlowest = $sorted[($sorted.Count - $onePctN)..($sorted.Count - 1)]
    $onePctSum = 0.0
    foreach ($v in $onePctSlowest) { $onePctSum += $v }
    $onePctLowFps = 1000.0 / ($onePctSum / $onePctN)

    $pointOnePctSlowest = $sorted[($sorted.Count - $pointOnePctN)..($sorted.Count - 1)]
    $pointOnePctSum = 0.0
    foreach ($v in $pointOnePctSlowest) { $pointOnePctSum += $v }
    $pointOnePctLowFps = 1000.0 / ($pointOnePctSum / $pointOnePctN)

    $worstFrameMs = $sorted[$sorted.Count - 1]

    $stallCount25 = 0
    $stallCount40 = 0
    foreach ($ft in $FrameTimesMs) {
        if ($ft -gt 25.0) { $stallCount25++ }
        if ($ft -gt 40.0) { $stallCount40++ }
    }

    $stallRate25Per100s = if ($durationSeconds -gt 0) { $stallCount25 / $durationSeconds * 100 } else { 0.0 }
    $stallRate40Per100s = if ($durationSeconds -gt 0) { $stallCount40 / $durationSeconds * 100 } else { 0.0 }

    return [pscustomobject]@{
        Frames             = $n
        DurationSeconds    = $durationSeconds
        AvgFps             = $avgFps
        OnePctLowFps       = $onePctLowFps
        PointOnePctLowFps  = $pointOnePctLowFps
        WorstFrameMs       = $worstFrameMs
        StallCount25       = $stallCount25
        StallRate25Per100s = $stallRate25Per100s
        StallCount40       = $stallCount40
        StallRate40Per100s = $stallRate40Per100s
    }
}

function Get-CaptureScore {
    <#
        .SYNOPSIS
        The one entry point the console/report code calls: runs the bundle
        integrity gate FIRST, and only computes a score when the file
        passes it (spec section 7, R-S2 / A-SCORE-02).

        .DESCRIPTION
        Ordering is the point of this function: Test-BundleFile (the
        integrity gate already built for the bundle screen) is called
        before ConvertFrom-CapFrameXCapture / Get-StutterScore ever run, so
        a truncated or malformed CapFrameX file - the 6/8 MiB mid-copy cut,
        a length mismatch between MsBetweenPresents and a sibling series -
        is refused before any number exists to look real.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int64] $Length,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text
    )

    $bundleCheck = Test-BundleFile -Name $Name -Length $Length -Text $Text

    if (-not $bundleCheck.Pass) {
        return [pscustomobject]@{
            Pass        = $false
            BundleCheck = $bundleCheck
            Score       = $null
        }
    }

    $capture = ConvertFrom-CapFrameXCapture -Text $Text
    $score = Get-StutterScore -FrameTimesMs $capture.FrameTimesMs

    return [pscustomobject]@{
        Pass        = $true
        BundleCheck = $bundleCheck
        Score       = $score
    }
}

function Get-ScoreSummary {
    <#
        .SYNOPSIS
        The line the Share screen shows (spec section 7 / R-S3): no
        CapFrameX capture, or a capture that failed the integrity gate,
        means no score - and the screen says so, never a blank or a
        fabricated number.

        .DESCRIPTION
        Wording is bound by build-brief flag 13: never "stutter-free",
        "eliminates stutter" or "fixes stutter", and the number always
        traces back to one capture on one track.
    #>
    [CmdletBinding()]
    param(
        # The result of Get-CaptureScore, or $null when no CapFrameX capture
        # was found for this session at all (R-S3).
        $CaptureScore
    )

    if ($null -eq $CaptureScore) {
        return [pscustomobject]@{
            Available = $false
            Line      = 'No CapFrameX capture found for this session - stutter score unavailable.'
            Score     = $null
        }
    }

    if (-not $CaptureScore.Pass) {
        $reason = 'the capture failed the integrity check'
        $bundleCheck = Get-KnownGoodField -Entry $CaptureScore -Name 'BundleCheck'
        if ($null -ne $bundleCheck) {
            $reasons = @(Get-KnownGoodField -Entry $bundleCheck -Name 'Reasons')
            if ($reasons.Count -gt 0) { $reason = $reasons -join '; ' }
        }
        return [pscustomobject]@{
            Available = $false
            Line      = "CapFrameX capture failed the integrity check - stutter score unavailable ($reason)."
            Score     = $null
        }
    }

    $score = $CaptureScore.Score
    return [pscustomobject]@{
        Available = $true
        Line      = ('One session, one track: {0:N1} FPS avg, worst frame {1:N1} ms, {2:N2} stalls over 25 ms per 100 s.' -f $score.AvgFps, $score.WorstFrameMs, $score.StallRate25Per100s)
        Score     = $score
    }
}

function Select-NewestCapture {
    <#
        .SYNOPSIS
        Picks the newest CapFrameX capture record whose modified time is
        after the launch stamp (spec section 7 / R-S4). $null when none
        qualifies. Pure: the file list and the stamp both arrive as
        parameters, nothing is read from disk here.
    #>
    [CmdletBinding()]
    param(
        # Records with at least Name and ModifiedAt (a [datetime]).
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $File,
        [Parameter(Mandatory)]
        [datetime] $After
    )

    $candidates = @($File | Where-Object { $_.ModifiedAt -gt $After })
    if ($candidates.Count -eq 0) { return $null }

    return ($candidates | Sort-Object -Property ModifiedAt -Descending | Select-Object -First 1)
}
