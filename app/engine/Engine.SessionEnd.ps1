# engine/Engine.SessionEnd.ps1 - SimRig Console v4.2, unit U4.13.
#
# When is a session over?
#
# Until now the console answered that with one line: the sim process is gone,
# so end the watch and restore Windows. That is wrong, and Rick found it by
# racing. Going back to the iRacing selection menu EXITS iRacingSim64DX11.exe
# while the iRacing UI stays open - so practice, back to the menu, then qualify
# is three sims in one evening, and the console tore the session down after the
# first one. Windows came out of quiet, the watch stopped, and the bundle was
# never pushed, all while he was still sitting at the rig picking the next
# session.
#
# PURE. No clock, no processes: the caller reads the machine and hands in what
# it saw, this file decides what it means.

function Get-SimRigSessionEndVerdict {
    <#
        .SYNOPSIS
        What the sim and UI processes mean for the session: still racing,
        between sessions, or finished.
        .DESCRIPTION
        Three verdicts:

          Racing           the sim is running. Nothing to decide.
          BetweenSessions  the sim is gone but the iRacing UI is still open, so
                           he is at the selection menu choosing what to do next.
                           The session stays open and Windows stays quiet. This
                           is the case that used to end the evening.
          Ended            the sim is gone and the UI is gone, and has been for
                           longer than the grace period. Only now is the session
                           over.

        The grace period exists because closing the sim and the UI takes a few
        seconds and they do not exit in a fixed order; without it, a blink
        between the two would read as the end.

        Leaving Windows quiet while he is at the menu is deliberate and is not
        the same as leaving it quiet forever: the deadman task still restores at
        the next logon (flag 4), and the console's End session button is always
        there for "I am done now".
        .PARAMETER SimRunning
        Is iRacingSim64DX11.exe running.
        .PARAMETER UiRunning
        Is the iRacing UI running.
        .PARAMETER SimSeen
        Has the sim been seen at all this session. Before it has, nothing is
        over - the racer may still be loading it.
        .PARAMETER QuietSecondsSoFar
        How long both have been absent, in seconds.
        .PARAMETER GraceSeconds
        How long both must be absent before the session ends. Default 120.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [bool] $SimRunning,
        [bool] $UiRunning,
        [bool] $SimSeen,
        [double] $QuietSecondsSoFar = 0,
        [double] $GraceSeconds = 120
    )

    if ($SimRunning) {
        return [pscustomobject]@{
            Verdict = 'Racing'; StringKey = 'Session_Racing'
            Detail = $null; SecondsLeft = $null
        }
    }

    if (-not $SimSeen) {
        # The sim has not started yet. A session that has never seen the sim is
        # not one that has finished it.
        return [pscustomobject]@{
            Verdict = 'Racing'; StringKey = 'Session_WaitingForSim'
            Detail = $null; SecondsLeft = $null
        }
    }

    if ($UiRunning) {
        return [pscustomobject]@{
            Verdict = 'BetweenSessions'; StringKey = 'Session_BetweenSessions'
            Detail = 'The sim closed but iRacing is still open, so this is the selection menu, not the end of the night.'
            SecondsLeft = $null
        }
    }

    $left = [Math]::Max(0, $GraceSeconds - $QuietSecondsSoFar)
    if ($left -gt 0) {
        return [pscustomobject]@{
            Verdict = 'Ending'; StringKey = 'Session_Ending'
            Detail = 'iRacing has closed. Ending the session shortly unless it comes back.'
            SecondsLeft = [int][Math]::Ceiling($left)
        }
    }

    return [pscustomobject]@{
        Verdict = 'Ended'; StringKey = 'Session_Ended'
        Detail = 'iRacing and its UI are both closed.'
        SecondsLeft = 0
    }
}
