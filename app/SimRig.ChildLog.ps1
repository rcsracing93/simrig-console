#requires -Version 7.0
<#
    SimRig.ChildLog.ps1 - the append of the log file of one run of the elevated child to actions.log.

    What it is: one function, Add-ConsoleChildLog, for the two parts of the app that are not elevated and start the
    child: the window (SimRigConsole.ps1) and RESTORE-NOW (SimRig.RestoreNow.ps1). Since blocker 7 (commit 6, O3) the
    child writes its log lines to Logs\v4\results\<Operation>-<RequestId>.log, and the part that started it appends
    them to actions.log. Design question D1 of blocker 2 (ANSWERS-blocker2-design-cowork-2026-10-08.md) put the
    function in a file of its own that both load; APPROVALS-RICK-2026-10-11-1950 item 1.
    Not in SimRig.Engine.ps1: the engine is pure (no file, clock or process call; Boundaries.Tests and RF-1a), and
    this function reads, writes and removes files. Not in a file of the child: the child does not append its own log.
    How to load: dot-source it after SimRig.Engine.ps1 (it calls Get-ActionChildLogPath and Get-ActionResultPath).
    What it changes: actions.log (append) and the log file of the run (removed after the append).
#>

function Add-ConsoleChildLog {
    <#
        Blocker 7, commit 6 (O3; NOTE-blocker7-commit5-6-cowork-2026-10-08.md, the addendum of 11:50). This window is
        not elevated, so a link at actions.log gives only the rights of the user. Appends the log file of one run of
        the child (<Operation>-<RequestId>.log in the results folder) to actions.log, and then removes it. When the
        run has no result file, the run did not finish, and one line says so. Returns $null, or the text of the
        fault; the caller writes it in the console log.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ResultDir,
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)] [string] $RequestId,
        [Parameter(Mandatory)] [string] $ActionsLog,
        # The sweep at the start of the window: one line before the lines names the operation and its RequestId (the
        # condition of Cowork, COWORK-LATEST.md of 12:15).
        [switch] $FromSweep
    )
    try {
        $pathOf = $ExecutionContext.SessionState.Path
        $logPath = $pathOf.GetUnresolvedProviderPathFromPSPath((Get-ActionChildLogPath -ResultDir $ResultDir -Operation $Operation -RequestId $RequestId))
        if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { return $null }
        $finished = Test-Path -LiteralPath (Get-ActionResultPath -ResultDir $ResultDir -Operation $Operation -RequestId $RequestId)
        # ReadWrite: a child that did not finish can still hold the file open.
        $stream = [System.IO.FileStream]::new($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $text = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false)).ReadToEnd() }
        finally { $stream.Dispose() }
        if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += [Environment]::NewLine }
        if ($FromSweep) {
            $text = ('{0} [{1} {2}] the lines below are of the run {1} {3}; the window added them at its start' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Operation, $RequestId.Substring(0, 8), $RequestId) + [Environment]::NewLine + $text
        }
        if (-not $finished) {
            $text += ('{0} [{1} {2}] elevated step did not finish; lines above are all that it wrote' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Operation, $RequestId.Substring(0, 8)) + [Environment]::NewLine
        }
        [System.IO.File]::AppendAllText($pathOf.GetUnresolvedProviderPathFromPSPath($ActionsLog), $text)
        [System.IO.File]::Delete($logPath)
        return $null
    }
    catch {
        return ('the log of {0} {1} was not added to actions.log: {2}' -f $Operation, $RequestId, $_.Exception.Message)
    }
}
