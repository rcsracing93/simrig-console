<#
    SimRig.Actions.Defender.ps1 - SimRig Console v4.2

    Flag 15: the Defender-off code lives in its own file, dot-sourced only when the
    user has opted in. It is separated for two reasons that both matter.

    Defender itself flags tools that switch off real-time monitoring, which is
    reasonable of it - that is what a lot of malware does first. Keeping the code in
    one named file means the behaviour can be pointed at, reviewed and explained,
    rather than being one line buried in a five-thousand-line action script.

    And a user who has not asked for this should not be running a build that can do
    it at all. The console loads this file only when a Defender step is actually in
    the plan, and a step only reaches the plan when the selected profile opted in.
    The public profile does not.

    Turning real-time scanning off during a race came from the v3.9 pre-race batch
    file, where it was measured: scanning iRacing, CapFrameX and Trophi.ai file I/O
    mid-race is a stutter source. It is restored from the session snapshot
    afterwards, like every other quieted item, and the restore is read back and
    verified rather than assumed.
#>

function Set-SimRigDefenderRealtime {
    <#
        .SYNOPSIS
        Turns Defender real-time monitoring on or off, and proves it took.

        .DESCRIPTION
        Tamper Protection can refuse this silently - the call returns without error
        and the setting does not change. So the value is read back before the step
        claims success, and a mismatch throws with the likely reason rather than
        letting the session continue believing Windows is quiet when it is not.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [bool] $On)
    $word = if ($On) { 'on' } else { 'off' }
    if (-not $PSCmdlet.ShouldProcess('Defender real-time monitoring', "turn $word")) { return 'WhatIf' }
    Set-MpPreference -DisableRealtimeMonitoring (-not $On) -ErrorAction Stop
    # Tamper Protection can refuse silently. Read it back before claiming Done.
    Start-Sleep -Seconds 2
    $now = -not [bool](Get-MpPreference).DisableRealtimeMonitoring
    if ($now -ne $On) { throw "Defender real-time monitoring is still $(if ($now) { 'on' } else { 'off' }) - Tamper Protection may block this" }
    return 'Done'
}
