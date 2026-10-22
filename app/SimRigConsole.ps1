<#
    SimRigConsole.ps1 - SimRig Console v4.0

    One window, five steps: Preflight, Quiet, Race watch, Restore, Push.
    Start it from the shortcut:
      pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File "C:\Program Files\SimRig\SimRigConsole.ps1"
    Program files moved there in v4.2; the data root stays C:\SimRacer.

    This file is the shell. It runs UNELEVATED (the mapped Z: drive is only
    visible to the unelevated session). It reads through SimRig.Probe.ps1,
    decides nothing itself (SimRig.Engine.ps1 does), and never changes Windows:
    every state change is one elevated SimRig.Actions.ps1 child, whose result it
    reads from a JSON file (flag 4). The only files it writes are its own log
    and the session files under C:\SimRacer\Logs\v4.

    Race watch takes no action during the race. It reads the System and
    TaskScheduler event logs every 15 s and records. No counters, no sampling.
#>
[CmdletBinding()]
param(
    [string] $Root = 'C:\SimRacer',
    # No default share. This used to be one person's mapped drive, shipped to every
    # user as this script's default (Rick's decision, 2026-09-27, after the export
    # gate found it). The rig's own path lives in its profile; a user who wants Push
    # passes -NasRoot or sets one in their profile, and until then Push says so and
    # copies nothing.
    [string] $NasRoot = '',
    # Self-test only: write startup timings to this JSON file and close once the preflight is shown.
    [string] $StartupReport = '',
    # Build only, and only with -StartupReport: save one PNG of this window to this
    # path before it closes. No default path, no button, no setting. Left out, the
    # console does what it did before this switch existed.
    [string] $StartupPicture = ''
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# WPF needs a single-threaded apartment. The shortcut passes -STA; this covers
# a start without it.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    & (Get-Process -Id $PID).Path -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -Root $Root -NasRoot $NasRoot -StartupReport $StartupReport -StartupPicture $StartupPicture
    exit $LASTEXITCODE
}

# Startup timing (v4.0.3): seconds from process start to each mark, in the console log.
$script:ProcessStart = (Get-Process -Id $PID).StartTime
$script:StartupMark = [ordered]@{ ScriptStart = (Get-Date) }
$script:StartupDone = $false
# v4.1: the console applies the GPU interrupt steering itself when the policy is
# orphaned, once per start (Rick 2026-09-20, Fable F.3 finding 1).
$script:GpuAutoFixDone = $false
$script:PreflightCall = $null
$script:PreflightTimer = $null

. (Join-Path -Path $PSScriptRoot -ChildPath 'SimRig.Engine.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'SimRig.Probe.ps1')
# The append of the log of the child (Add-ConsoleChildLog), shared with RESTORE-NOW (D1 of blocker 2).
. (Join-Path -Path $PSScriptRoot -ChildPath 'SimRig.ChildLog.ps1')

# -StartupPicture is refused here, before a window exists, when the request is not
# complete. With no path given the refusal is $null and nothing below runs.
if ($StartupPicture) {
    $pictureFolder = Split-Path -Path $StartupPicture -Parent
    $pictureRefusal = Get-StartupPictureRefusal -Path $StartupPicture -StartupReport $StartupReport `
        -FolderExists ((-not [string]::IsNullOrWhiteSpace($pictureFolder)) -and (Test-Path -LiteralPath $pictureFolder -PathType Container)) `
        -FolderWritable (Test-SimRigFolderWritable -Path $pictureFolder)
    if ($pictureRefusal) {
        Write-Output $pictureRefusal
        exit 2
    }
}

$viewPart = Join-Path -Path $PSScriptRoot -ChildPath 'SimRigConsole.View.ps1'
if (Test-Path -LiteralPath $viewPart) { . $viewPart }

# v4.2 part files. Strings first, because every screen asks it for a caption
# (G-19: no user-visible literal lives in the view or here). Then the engine and
# discover halves, sorted so a run is reproducible; they hold function
# definitions only, so load order among them does not matter.
foreach ($part in @('SimRig.Strings.ps1', 'SimRig.Share.ps1', 'SimRig.Logger.ps1')) {
    $partPath = Join-Path -Path $PSScriptRoot -ChildPath $part
    if (Test-Path -LiteralPath $partPath) { . $partPath }
}
foreach ($dir in @('engine', 'discover')) {
    $dirPath = Join-Path -Path $PSScriptRoot -ChildPath $dir
    if (Test-Path -LiteralPath $dirPath) {
        foreach ($file in Get-ChildItem -LiteralPath $dirPath -Filter *.ps1 -File | Sort-Object -Property Name) {
            . $file.FullName
        }
    }
}

# Files whose SHA-256 must match VERSIONS.md (preflight "Script integrity").
# One list, derived from what the installer ships - see Get-SimRigHashFileName.
# This used to be a literal here and a different, older literal in the self-test.
$script:HashFile = Get-SimRigHashFileName -ScriptDir $PSScriptRoot

$script:Paths = Get-SimRigPath -Root $Root
# G-12. Read once, at load, while this process is still the racer's.
$script:UserSid = Get-SimRigUserSid
$script:ActionsScript = Join-Path -Path $PSScriptRoot -ChildPath 'SimRig.Actions.ps1'
$script:Pwsh = (Get-Process -Id $PID).Path
$script:Codes = Get-ActionExitCode
$script:ToolCandidate = @{
    IRacingUi  = @('C:\Program Files (x86)\iRacing\ui\iRacingUI.exe')
    CapFrameX  = @('C:\Program Files (x86)\CapFrameX\CapFrameX.exe', 'C:\Program Files\CapFrameX\CapFrameX.exe')
    LatencyMon = @('C:\Program Files\LatencyMon\LatMon.exe', 'C:\Program Files (x86)\LatencyMon\LatMon.exe')
}
$script:SimProcessName = 'iRacingSim64DX11'
# The UI is a separate process, and that difference is the whole of U4.13:
# going back to the selection menu exits the sim and leaves this one running.
$script:SimUiProcessName = 'iRacingUI'
$script:Pending = $null
$script:DryRunMode = 'Preflight'

# One mutable session record. Everything the report needs is kept here.
$script:S = @{
    Stamp = $null; SessionDir = $null; SessionStart = $null; StartedAnyway = $false
    Fact = $null; Check = @(); Summary = $null
    QuietResult = $null; RestoreResult = $null; Verdict = $null
    Watch = [System.Collections.Generic.List[object]]::new(); WatchKey = [System.Collections.Generic.HashSet[string]]::new()
    Since = $null; SimSeenAt = $null; WatchTimer = $null; DisplayNameMap = $null
    # When the sim AND the UI were both last absent, for the end-of-session grace.
    SimGoneAt = $null; SessionPhase = 'Racing'
    LatencyMonFile = $null; PushedTo = $null; BundleCheck = $null; Busy = $false
    LaunchMode = 'IRacing'; PreMode = 'Preflight'
    TuningDir = $null
    # The hard-fault trace runs across a whole stint, so the console has to
    # remember that one is going rather than infer it.
    TraceRunning = $false
    # Which flow is waiting on the second confirmation dialog (flag 7). Two flows
    # share that dialog now, and the Apply button has to know whose Apply it is.
    PendingConfirm = $null
    # Push 2 of the unit tune, step 7b: the ids that the second ask of Apply tuning lists.
    TuningTicked = $null
    # Causes row 21: the banner (and the row) of a green Apply or Undo, for the check that it starts.
    RunBanner = $null
    # The last update check's verdict, so re-opening About shows the answer instead
    # of fetching again (flag 16: note only, and only when the user asks).
    UpdateVerdict = $null
}

# --------------------------------------------------------------------------
# Own files: log and session JSON
# --------------------------------------------------------------------------

function Write-ConsoleLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Message)
    try {
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        [System.IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine)
    }
    catch { Write-Warning ("console log not writable: {0}" -f $_.Exception.Message) }
}

function Get-ConsoleRefusalLinkText {
    <#
        Blocker 7, commit 9 (question 1 of REQUEST-night-o2-4e3b9e5.md; APPROVALS-RICK-2026-10-09-2125 item B.2, "Yes
        0725"). A child that finds a link on the path of its result file, or a folder at its name, refuses with text 5,
        exits with the code of a refusal and writes no result file; its text goes only to its warning stream, which
        the window cannot read (Start-Process -Verb RunAs). So the window makes the same check, with the same function,
        and gives text 5 for the item that it finds. $null when it finds no link and no folder: the caller keeps its
        text. The window is not elevated, and this function only reads.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Root, [Parameter(Mandatory)] [string] $ResultPath)
    $item = $null
    $link = Find-SimRigPathLink -Root $Root -Path $ResultPath
    if ($null -ne $link -and $link.Cause -eq 'Link') { $item = [string]$link.Item }
    elseif ([System.IO.Directory]::Exists($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultPath))) { $item = $ResultPath }
    if ($null -eq $item) { return $null }
    # Text 5 (APPROVALS-RICK-2026-10-09-2125 item B.2), the same words as the child.
    return ('Refused: {0} is a link or a folder. Nothing was changed. Remove it and try again.' -f $item)
}

function Complete-ConsoleChildLogSweep {
    <#
        Blocker 7, commit 6 (O3): at the start of the window, each log file of the child that is still in the results
        folder (a run that did not finish, a run of the deadman or of the self-test, which have no parent that is not
        elevated) goes to actions.log by Add-ConsoleChildLog. Only that folder. Returns the texts of the faults.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $ResultDir, [Parameter(Mandatory)] [string] $ActionsLog)
    $faults = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $ResultDir -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime)) {
        if ($file.Name -notmatch '^(?<op>[A-Za-z]+)-(?<rid>[0-9a-fA-F-]{8,64})\.log$') { continue }
        $fault = Add-ConsoleChildLog -ResultDir $ResultDir -Operation $Matches['op'] -RequestId $Matches['rid'] -ActionsLog $ActionsLog -FromSweep
        if ($fault) { $faults.Add($fault) }
    }
    return , $faults.ToArray()
}

function Write-SessionJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [object] $InputObject)
    $path = Join-Path -Path $script:S.SessionDir -ChildPath $Name
    [System.IO.File]::WriteAllText($path, ($InputObject | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Show-SimRigFailure {
    <#
        The one place a failure reaches the screen (spec 16, the top-level error
        handler). It logs the message and the stack, shows the sentence without the
        stack, and puts Restore or Undo in front of the user when the machine is in
        a state that needs one - which is exactly when those two are hardest to
        find.

        A stack trace tells a user nothing and can carry a path, a user name or a
        value from the failure, so it goes to the log and not the window.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $What,
        [AllowNull()] [string] $Message,
        [AllowNull()] [string] $Detail,
        [AllowNull()] [object] $Line
    )

    $sessionOpen = $false
    $tuningApplied = $false
    try { $sessionOpen = Test-Path -LiteralPath $script:Paths.ActiveMarker } catch { $sessionOpen = $false }
    # Push 2 of the unit tune, step 7: the marker on disk, so that an Apply of an earlier run of the app
    # counts also (text 55 is true only then).
    try { $tuningApplied = Test-Path -LiteralPath $script:Paths.TuningMarker } catch { $tuningApplied = $false }

    $shown = Get-SimRigErrorMessage -What $What -Message $Message -Detail $Detail -Line $Line `
        -SessionOpen $sessionOpen -TuningApplied $tuningApplied

    Write-ConsoleLog ('[FAIL] ' + $shown.LogLine)
    Show-Banner -Kind Bad -Title $shown.Title -Text $shown.Text
    if ($shown.OfferRestore) { Show-ButtonSet -Mode RestoredRed }
    $script:S.Busy = $false
}

function Invoke-UiSafe {
    <# Every button and timer handler runs through this: an error is logged and shown, never a crash. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [scriptblock] $Action, [string] $What = 'action')
    try { & $Action }
    catch {
        Show-SimRigFailure -What $What -Message $_.Exception.Message -Detail $_.ScriptStackTrace `
            -Line $_.InvocationInfo.ScriptLineNumber
    }
}

# --------------------------------------------------------------------------
# The one elevated child per state change (flag 4)
# --------------------------------------------------------------------------

function Invoke-ElevatedStep {
    <#
        Starts SimRig.Actions.ps1 (elevated unless -WhatIfRun), waits without
        freezing the window, reads the result JSON, validates it, and calls
        -OnDone with (result, failureText). stdout is never read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)] [string] $SessionDir,
        [string[]] $OnlyId,
        [switch] $WhatIfRun,
        [Parameter(Mandatory)] [scriptblock] $OnDone,
        [Parameter(Mandatory)] [string] $ModeOnCancel,
        [AllowNull()] [string] $GpuScope
    )
    $rid = [guid]::NewGuid().ToString()
    # G-12: this console is unelevated and runs as the racer, so its SID is the one
    # the child must write. Read here rather than in the child, where the answer
    # would be whoever's credentials were typed at the prompt.
    $argLine = Get-ActionArgument -ActionsScript $script:ActionsScript -Operation $Operation -RequestId $rid `
        -SessionDir $SessionDir -Only $OnlyId -WhatIfRun:$WhatIfRun -UserSid $script:UserSid -GpuScope $GpuScope
    $resultPath = Get-ActionResultPath -ResultDir $script:Paths.Results -Operation $Operation -RequestId $rid
    Write-ConsoleLog ("{0} -> {1} {2}" -f $Operation, $script:Pwsh, $argLine)
    $splat = @{ FilePath = $script:Pwsh; ArgumentList = $argLine; PassThru = $true; WindowStyle = 'Hidden' }
    if (-not $WhatIfRun) { $splat['Verb'] = 'RunAs' }
    try { $proc = Start-Process @splat }
    catch {
        Write-ConsoleLog ("[FAIL] {0} not started: {1}" -f $Operation, $_.Exception.Message)
        Show-Banner -Kind Bad -Title 'Nothing changed' -Text ('The elevated step did not start ({0}). If you pressed No on the Windows prompt, that is why.' -f $_.Exception.Message)
        Show-ButtonSet -Mode $ModeOnCancel
        $script:S.Busy = $false
        return
    }
    $script:S.Busy = $true
    Show-ButtonSet -Mode Busy
    # One elevated step at a time (Busy). Its state lives in $script:Pending, not in a
    # closure: a GetNewClosure() scriptblock cannot see this script's functions.
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:Pending = @{ Proc = $proc; Timer = $timer; Started = (Get-Date); ResultPath = $resultPath; RequestId = $rid; Operation = $Operation; OnDone = $OnDone }
    $timer.Add_Tick({ Invoke-UiSafe -What 'elevated step' -Action { Complete-ElevatedStep } })
    $timer.Start()
}

function Complete-ElevatedStep {
    <# Timer tick: when the child has exited, read and validate its result JSON, then hand it on. #>
    [CmdletBinding()]
    param()
    $p = $script:Pending
    if ($null -eq $p) { return }
    $timedOut = ((Get-Date) - $p.Started).TotalMinutes -gt 10
    if (-not $p.Proc.HasExited -and -not $timedOut) { return }
    $p.Timer.Stop()
    $script:Pending = $null
    $code = if ($p.Proc.HasExited) { $p.Proc.ExitCode } else { 'timeout after 10 min' }
    $result = Read-SimRigJson -Path $p.ResultPath
    $logFault = Add-ConsoleChildLog -ResultDir $script:Paths.Results -Operation $p.Operation -RequestId $p.RequestId -ActionsLog (Join-Path -Path $script:Paths.Logs -ChildPath 'actions.log')
    if ($logFault) { Write-ConsoleLog ('[WARN] {0}' -f $logFault) }
    [string[]]$invalid = Test-ActionResult -Result $result -RequestId $p.RequestId -Operation $p.Operation
    $failure = Get-ActionFailureText -Result $result -ValidationError $invalid -ExitCode $code
    # Blocker 7, commit 9 (Q1): a refusal with no result file. When the window finds the link or the folder on the path
    # of the result file, it shows text 5 in place of the text for a missing result.
    if ($null -eq $result -and $code -eq (Get-ActionExitCode).Refused) {
        $linkText = Get-ConsoleRefusalLinkText -Root $script:Paths.Root -ResultPath $p.ResultPath
        if ($linkText) { $failure = $linkText }
    }
    Write-ConsoleLog ("{0} finished: exit {1}{2}" -f $p.Operation, $code, $(if ($failure) { " - $failure" } else { '' }))
    $script:S.Busy = $false
    & $p.OnDone $result $failure
}

# --------------------------------------------------------------------------
# Step 1: preflight
# --------------------------------------------------------------------------

function Invoke-PreflightRun {
    <#
        Starts the preflight reads in a second runspace and returns at once, so
        the window stays live. A 250 ms timer picks up the result and calls
        Complete-PreflightRun. (v4.0.2 and earlier ran the reads before the window
        showed: about 10 s of a blank console, rig 2026-09-19.)
    #>
    [CmdletBinding()]
    param()
    if ($null -ne $script:PreflightCall) { return }
    Show-Heading -Title 'Preflight' -Subtitle 'Checking Windows - reading every setting back...'
    Show-StepState -Step 1 -State Current -Text 'reading'
    Show-Banner -Kind Info -Title 'Checking Windows' -Text 'Reading services, tasks, registry, GPU policy and iRacing files. This takes a few seconds.'
    Show-ButtonSet -Mode Busy
    $files = @((Join-Path $PSScriptRoot 'SimRig.Engine.ps1'), (Join-Path $PSScriptRoot 'SimRig.Probe.ps1'))
    $script:PreflightCall = Start-SimRigBackgroundCall -ScriptFile $files -Command 'Get-SimRigPreflightFact' -Parameter @{
        QuietItem = $script:Items; KnownGood = $script:KnownGood; ScriptDir = $PSScriptRoot; HashFile = $script:HashFile
        # From the active profile, not from known-good.psd1: the ini folder is a
        # machine fact and no longer ships in the data file.
        IniDir = $script:IniDir
    }
    $script:PreflightTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:PreflightTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:PreflightTimer.Add_Tick({ Invoke-UiSafe -What 'Preflight' -Action { Receive-PreflightRun } })
    $script:PreflightTimer.Start()
}

function Receive-PreflightRun {
    <# Timer tick: when the background reads are done, grade and show them. #>
    [CmdletBinding()]
    param()
    $call = $script:PreflightCall
    if ($null -eq $call) { $script:PreflightTimer.Stop(); return }
    if (-not (Test-SimRigBackgroundCall -Call $call)) { return }
    $script:PreflightTimer.Stop()
    $script:PreflightCall = $null
    try { $fact = Receive-SimRigBackgroundCall -Call $call }
    catch {
        # Causes row 21: the banner of a run is for the check that it started, not for a later one.
        $script:S.RunBanner = $null
        Show-ButtonSet -Mode NotReady
        if (-not $script:StartupDone) { Complete-Startup -Failure $_.Exception.Message }
        throw
    }
    if (-not $script:StartupDone) { $script:StartupMark['FactsRead'] = Get-Date }
    Complete-PreflightRun -Fact $fact
}

function Complete-PreflightRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Fact)
    $script:S.Fact = $Fact
    $script:S.Check = Get-PreflightCheck -Fact $script:S.Fact -KnownGood $script:PreflightValue -QuietItem $script:Items -Machine $script:Machine `
        -TuningState $script:TuningSupport.State
    $script:S.Summary = Get-PreflightSummary -Check $script:S.Check
    $banner = Get-PreflightBanner -Summary $script:S.Summary -Check $script:S.Check
    Write-ConsoleLog ("preflight: {0}" -f $script:S.Summary.Line)

    $title = if ($script:S.Summary.Ready) { 'Ready to race' } else { 'Not ready' }
    # RF-3c: the subtitle says the count. The log line above and the startup report
    # have Summary.Line, which names each failed check.
    Show-Heading -Title $title -Subtitle (Get-PreflightSubtitle -Summary $script:S.Summary)
    Show-StepState -Step 1 -State $(if ($script:S.Summary.Ready) { 'Current' } else { 'Failed' }) -Text $(if ($script:S.Summary.Ready) { 'READY' } else { 'NOT READY' })
    foreach ($n in 2..5) { Show-StepState -Step $n -State Waiting -Text '' }
    # Causes row 21 (the Cowork note of 2026-10-04, three conditions; Rick's "go for row 21"): after
    # the check that a green Apply or Undo started, the banner of that run shows again, and after an
    # Apply the row with the path of UNDO-BY-HAND.txt is the first row. The heading and the step state
    # keep the result of the check. Only this one check: the run banner is taken and cleared here.
    $runBanner = $script:S.RunBanner
    $script:S.RunBanner = $null
    # Assign, then wrap: the function returns the comma form.
    $checkRows = ConvertTo-PreflightViewRow -Check $script:S.Check
    if ($null -ne $runBanner) {
        Show-Banner -Kind Ok -Title $runBanner.Title -Text $runBanner.Text
        if ($null -ne $runBanner.Row) { $checkRows = @($runBanner.Row) + @($checkRows) }
    }
    else { Show-Banner -Kind $banner.Kind -Title $banner.Title -Text $banner.Text }
    Show-CheckRow -Title 'Checks' -Row @($checkRows)
    Show-SideKey -Title 'This session' -Row @(
        [pscustomobject]@{ Key = 'Quiet list'; Value = ('{0} items' -f @($script:Items).Count) }
        [pscustomobject]@{ Key = 'Snapshot'; Value = 'taken before the quiet' }
        [pscustomobject]@{ Key = 'Restore'; Value = 'at session end, or at next sign-in' }
        [pscustomobject]@{ Key = 'Race watch'; Value = 'event logs every 15 s, no action' }
        [pscustomobject]@{ Key = 'Report'; Value = 'v4-report.json' }
    )
    Show-Verdict -Text '' -Green $null
    Show-StatusLine
    $script:S.PreMode = $banner.Mode
    Show-ButtonSet -Mode $banner.Mode
    if (-not $script:StartupDone) { Complete-Startup }
    Write-SteeringRecord
    Invoke-GpuSteeringAutoFix
}

function Write-SteeringRecord {
    <#
        .SYNOPSIS
        One line in the steering history per console start, BEFORE the auto-fix
        runs, so the line says what the boot left behind rather than what this
        console just wrote.

        .DESCRIPTION
        The question it settles (U4.25, Rick 2026-09-29): the console has
        re-applied GPU interrupt steering at every start since 2026-09-20, on the
        strength of one observation that the NVIDIA instance ids change at every
        boot. That costs a confirm dialog and a Windows prompt before the racer has
        clicked anything, every boot. The self-test of 2026-09-28 found the
        steering already in place after a restart, which does not fit.

        So the history records the INSTANCE IDS as well as the policy. Ids that
        move between boots mean re-applying is the only option. Ids that hold with
        the policy intact mean the fix at every start is unnecessary. Ids that hold
        with the policy gone mean something clears the value, which is a third
        thing again.

        Best effort, and never in the startup-report run: the timing check must
        measure the console, not a file write.
    #>
    [CmdletBinding()]
    param()

    if ($StartupReport) { return }
    try {
        $affinity = @($(if ($script:S.Fact) { $script:S.Fact.GpuAffinity } else { @() }))
        $record = Build-SimRigSteeringRecord -Affinity $affinity -TakenAt (Get-Date) `
            -BootAt (Get-SimRigLastBootTime) -Scope (Get-GpuFixScope) `
            -Orphaned (Test-GpuSteeringOrphaned -Check $script:S.Check)
        [void](Add-SimRigSteeringRecord -Path $script:Paths.SteeringHistory -Record $record)
    }
    catch {
        Write-ConsoleLog ('[WARN] steering history not written: {0}' -f $_.Exception.Message)
    }
}

function Complete-Startup {
    <# Logs the startup timing once. In self-test mode, writes it and closes the window. #>
    [CmdletBinding()]
    param([string] $Failure = '')
    $script:StartupDone = $true
    if (-not $Failure) { $script:StartupMark['PreflightShown'] = Get-Date }
    $timing = Get-StartupTiming -ProcessStart $script:ProcessStart -Mark $script:StartupMark
    Write-ConsoleLog ('startup seconds: {0}' -f (($timing.Keys | ForEach-Object { '{0}={1}' -f $_, $timing[$_] }) -join ' '))
    if ($StartupReport) {
        $doc = [ordered]@{ Schema = 'simrig.startup/1'; Rig = $env:COMPUTERNAME; ProcessStart = (Format-SimRigTime -Time $script:ProcessStart); Seconds = $timing; Preflight = $(if ($Failure) { "failed: $Failure" } elseif ($script:S.Summary) { $script:S.Summary.Line } else { 'not run (unfinished session or bad data)' }) }
        # Only when a picture was asked for. Without -StartupPicture the report has
        # the same five fields it always had, and the self-test reads the same file.
        if ($StartupPicture) {
            $doc['Picture'] = Save-StartupPicture -Path $StartupPicture
            # RF-3. The sizes that the window has now, after the layout pass of the
            # picture. A script cannot read a picture, so the build run checks these
            # numbers and a person looks at the picture.
            $doc['Layout'] = Get-StartupLayout
        }
        [System.IO.File]::WriteAllText($StartupReport, ($doc | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
        $window.Close()
    }
}

function Get-StartupLayoutAncestor {
    <#
        .SYNOPSIS
        The nearest visual parent of an element that is a ScrollViewer, or $null.
        The search stops at -Stop when one is given. Build only.
    #>
    [CmdletBinding()]
    param([AllowNull()] [object] $Element, [AllowNull()] [object] $Stop)

    $node = $Element
    while ($null -ne $node) {
        $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
        if ($null -eq $node) { return $null }
        if ($node -is [System.Windows.Controls.ScrollViewer]) { return $node }
        if ($null -ne $Stop -and [object]::ReferenceEquals($node, $Stop)) { return $null }
    }
    return $null
}

function Test-StartupTextCut {
    <#
        .SYNOPSIS
        True when a one-line text block shows less than its full text: the text is
        wider than the space that the block got. Build only.

        .DESCRIPTION
        It measures a second text block with the same text and the same font, with
        no width limit, and compares that width with the width that the parent gave
        the block on the screen (its layout slot). The block on the screen is not
        measured again, so the layout of the window does not change.

        Not ActualWidth. A text block with no wrapping and no trimming is arranged
        at the full width of its text and then clipped by its parent, so its
        ActualWidth is the width of the text also when a part is not seen. The
        first form of this function compared with ActualWidth and could never say
        true for such a block (REVIEW of the unit rf3 at 4c80f8e).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [object] $Element)

    $probe = [System.Windows.Controls.TextBlock]::new()
    $probe.Text = $Element.Text
    $probe.FontFamily = $Element.FontFamily
    $probe.FontSize = $Element.FontSize
    $probe.FontWeight = $Element.FontWeight
    $probe.FontStyle = $Element.FontStyle
    $probe.FontStretch = $Element.FontStretch
    $probe.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $slot = [System.Windows.Controls.Primitives.LayoutInformation]::GetLayoutSlot($Element)
    $room = $slot.Width - $Element.Margin.Left - $Element.Margin.Right
    return [bool]($probe.DesiredSize.Width -gt ($room + 1.0))
}

function Get-StartupLayout {
    <#
        .SYNOPSIS
        The measured sizes of the window as it is on the screen now. Build only.

        .DESCRIPTION
        RF-3. Called from one place, Complete-Startup, and only when -StartupPicture
        was given. The tier B job reads these numbers and is red when the banner
        hides the check rows, when the banner text has a narrow column, or when a
        text is cut. It changes nothing in the window.

        It never throws. A value that could not be measured is the text
        'failed: reason' in place of the number, and the build run fails on that.

        .OUTPUTS
        An ordered dictionary:
          WindowWidth, WindowHeight   the content of the window
          BannerHeight                the banner
          BodyHeight                  the scroll area of the check list
          BannerTextWidth             the text block of the banner
          BannerTitleTrimmed          the banner title shows less than its text
          BannerTextScrolls           the banner text is higher than its scroll area
          SubtitleTrimmed             the heading subtitle shows less than its text
          BannerButtons               the visible buttons of the banner
          BannerButtonsInView         those that are in full inside the window
          CheckRows                   the rows of the check list
          CheckRowsInView             those that are in full inside the scroll area
    #>
    [CmdletBinding()]
    param()

    $layout = [ordered]@{}
    $measure = {
        param([string] $Name, [scriptblock] $Read)
        try { $layout[$Name] = & $Read }
        catch { $layout[$Name] = ('failed: {0}' -f $_.Exception.Message) }
    }
    $round = { param($Value) [Math]::Round([double]$Value, 1) }

    $root = if ($null -ne $window.Content) { $window.Content } else { $window }
    $banner = Get-SimRigViewElement -Name 'Banner'
    $bannerTitle = Get-SimRigViewElement -Name 'BannerTitle'
    $bannerText = Get-SimRigViewElement -Name 'BannerText'
    $subtitle = Get-SimRigViewElement -Name 'TxtSubtitle'
    $list = Get-SimRigViewElement -Name 'CheckList'
    $anyButton = Get-SimRigViewElement -Name 'BtnOpenLog'

    & $measure 'WindowWidth' { & $round $root.ActualWidth }
    & $measure 'WindowHeight' { & $round $root.ActualHeight }
    & $measure 'BannerHeight' { & $round $banner.ActualHeight }
    & $measure 'BodyHeight' {
        $scroll = Get-StartupLayoutAncestor -Element $list -Stop $null
        if ($null -eq $scroll) { throw 'the check list has no scroll area' }
        & $round $scroll.ActualHeight
    }
    & $measure 'BannerTextWidth' { & $round $bannerText.ActualWidth }
    & $measure 'BannerTitleTrimmed' { Test-StartupTextCut -Element $bannerTitle }
    & $measure 'BannerTextScrolls' {
        $scroll = Get-StartupLayoutAncestor -Element $bannerText -Stop $banner
        if ($null -eq $scroll) { $false } else { [bool]($scroll.ExtentHeight -gt ($scroll.ViewportHeight + 1.0)) }
    }
    & $measure 'SubtitleTrimmed' { Test-StartupTextCut -Element $subtitle }

    # A list that the two blocks below share. The first block fills it. It is not
    # assigned again, because a block runs in a scope of its own.
    $buttons = [System.Collections.Generic.List[object]]::new()
    & $measure 'BannerButtons' {
        $panel = [System.Windows.Media.VisualTreeHelper]::GetParent($anyButton)
        if ($null -eq $panel) { throw 'the buttons have no panel' }
        foreach ($child in $panel.Children) {
            if ($child -is [System.Windows.Controls.Button] -and $child.Visibility -eq [System.Windows.Visibility]::Visible) { $buttons.Add($child) }
        }
        $buttons.Count
    }
    & $measure 'BannerButtonsInView' {
        $inView = 0
        foreach ($button in $buttons) {
            $box = $button.TransformToAncestor($root).TransformBounds([System.Windows.Rect]::new(0, 0, $button.ActualWidth, $button.ActualHeight))
            if ($box.Height -gt 0 -and $box.Width -gt 0 -and $box.Left -ge -1.0 -and $box.Top -ge -1.0 -and
                $box.Right -le ($root.ActualWidth + 1.0) -and $box.Bottom -le ($root.ActualHeight + 1.0)) { $inView++ }
        }
        $inView
    }
    & $measure 'CheckRows' { [int]$list.Items.Count }
    & $measure 'CheckRowsInView' {
        $scroll = Get-StartupLayoutAncestor -Element $list -Stop $null
        if ($null -eq $scroll) { throw 'the check list has no scroll area' }
        $inView = 0
        if ($scroll.ActualHeight -ge 1) {
            foreach ($index in 0..([Math]::Max(0, $list.Items.Count - 1))) {
                $row = $list.ItemContainerGenerator.ContainerFromIndex($index)
                if ($null -eq $row -or $row.ActualHeight -le 0) { continue }
                $box = $row.TransformToAncestor($scroll).TransformBounds([System.Windows.Rect]::new(0, 0, $row.ActualWidth, $row.ActualHeight))
                if ($box.Top -ge -1.0 -and $box.Bottom -le ($scroll.ViewportHeight + 1.0)) { $inView++ }
            }
        }
        $inView
    }

    Write-ConsoleLog ('startup layout: {0}' -f (($layout.Keys | ForEach-Object { '{0}={1}' -f $_, $layout[$_] }) -join ' '))
    return $layout
}

function Save-StartupPicture {
    <#
        .SYNOPSIS
        Saves one PNG of this window's content, as it is on screen now. Build only.

        .DESCRIPTION
        Called from one place, Complete-Startup, and only when -StartupPicture was
        given. It exists so that a person can look at what the real console shows on
        a machine that is not the author's: the real startup, the real rows.

        The dispatcher is let run to idle first. The rows were set a moment ago in
        the same handler, and a render before the layout pass is a picture of the
        window as it was.

        It never throws. A picture that could not be saved is written in the report
        as 'failed: ...', and the caller of the build run fails on that.

        .OUTPUTS
        [string] 'saved: W x H' or 'failed: reason'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)

    try {
        $window.UpdateLayout()
        $window.Dispatcher.Invoke([Action] { }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $target = if ($null -ne $window.Content) { $window.Content } else { $window }
        $width = [int][Math]::Ceiling($target.ActualWidth)
        $height = [int][Math]::Ceiling($target.ActualHeight)
        if ($width -lt 1 -or $height -lt 1) { throw 'the window has no size' }
        $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($target)
        $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
        [void]$encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [System.IO.File]::Create($Path)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
        Write-ConsoleLog ('startup picture saved: {0} ({1} x {2})' -f $Path, $width, $height)
        return ('saved: {0} x {1}' -f $width, $height)
    }
    catch {
        Write-ConsoleLog ('[WARN] startup picture not saved: {0}' -f $_.Exception.Message)
        return ('failed: {0}' -f $_.Exception.Message)
    }
}

function Show-StatusLine {
    [CmdletBinding()]
    param()
    $header = Get-VersionsHeader -Text $(if ($script:S.Fact) { $script:S.Fact.VersionsText } else { $null })
    $integrity = @($script:S.Check | Where-Object { $_.Name -eq 'Script integrity' })
    $hashText = if ($integrity.Count -eq 0) { 'hash not checked' }
    elseif (@($integrity | Where-Object { $_.Verdict -ne 'Pass' }).Count -eq 0) { 'hash matches VERSIONS.md' }
    else { 'hash DOES NOT match VERSIONS.md' }
    $left = 'v{0} - commit {1} - {2}' -f (Format-ViewValue $header.Version), (Format-ViewValue $header.Commit), $hashText
    Show-StatusBar -Left $left -Right ('Log: {0}' -f $script:LogPath)
}

# --------------------------------------------------------------------------
# Step 2: quiet, then launch
# --------------------------------------------------------------------------

function Initialize-Session {
    [CmdletBinding()]
    param([switch] $Anyway, [ValidateSet('IRacing', 'Tools')] [string] $Mode = 'IRacing')
    $script:S.LaunchMode = $Mode
    $script:S.SessionStart = Get-Date
    $script:S.Stamp = Get-SessionStamp -Time $script:S.SessionStart
    $script:S.SessionDir = Join-Path -Path $script:Paths.Sessions -ChildPath $script:S.Stamp
    [void](New-Item -ItemType Directory -Path $script:S.SessionDir -Force)
    $script:S.StartedAnyway = [bool]$Anyway
    $script:S.Watch.Clear(); $script:S.WatchKey.Clear()
    $script:S.QuietResult = $null; $script:S.RestoreResult = $null; $script:S.Verdict = $null
    $script:S.LatencyMonFile = $null; $script:S.PushedTo = $null; $script:S.BundleCheck = $null; $script:S.SimSeenAt = $null
    $script:S.SimGoneAt = $null; $script:S.SessionPhase = 'Racing'
    [void](Write-SessionJson -Name 'preflight.json' -InputObject ([ordered]@{ Check = $script:S.Check; Summary = $script:S.Summary; StartedAnyway = $script:S.StartedAnyway }))
    Show-HeaderMeta -Rig $env:COMPUTERNAME -Session ($script:S.SessionStart.ToString('yyyy-MM-dd HH:mm'))
    Write-ConsoleLog ("session {0} (started anyway: {1}, launch: {2})" -f $script:S.Stamp, $script:S.StartedAnyway, $script:S.LaunchMode)
}

function Invoke-StartSession {
    [CmdletBinding()]
    param([switch] $Anyway, [ValidateSet('IRacing', 'Tools')] [string] $Mode = 'IRacing')
    if ($script:S.Busy) { return }
    Initialize-Session -Anyway:$Anyway -Mode $Mode
    Show-StepState -Step 1 -State Done -Text $(if ($Anyway) { 'started anyway' } else { 'READY' })
    Show-StepState -Step 2 -State Current -Text 'quieting'
    Show-Heading -Title 'Quiet' -Subtitle 'Snapshot, deadman task, then the quiet list in order. Approve the Windows prompt.'
    Invoke-ElevatedStep -Operation Quiet -SessionDir $script:S.SessionDir -ModeOnCancel $script:S.PreMode -OnDone {
        param($Result, $Failure)
        Complete-Quiet -Result $Result -Failure $Failure
    }
}

function Complete-Quiet {
    [CmdletBinding()]
    param([AllowNull()] [object] $Result, [AllowNull()] [string] $Failure)
    $script:S.QuietResult = $Result
    if ($Failure) {
        Show-StepState -Step 2 -State Failed -Text 'did not run'
        Show-Banner -Kind Bad -Title 'Quiet did not run' -Text $Failure
        if ($null -ne $Result) { Show-CheckRow -Title 'Quiet' -Row (ConvertTo-QuietViewRow -Result $Result) }
        Show-ButtonSet -Mode RestoredRed
        return
    }
    $rows = ConvertTo-QuietViewRow -Result $Result
    Show-CheckRow -Title 'Quiet read-back' -Row $rows
    # The per-item failures, not the group summaries. This used to test the row NAME
    # for a trailing 's', which is a guess about English that stopped being true the
    # moment the groups were named properly ("Registry values", "Defender"). The
    # summary rows are the ones the quiet list produced, so ask that instead.
    $bad = @($rows | Where-Object { $_.Verdict -eq 'Fail' -and $_.Source -ne 'quiet-list.psd1' })
    if ($bad.Count -gt 0) {
        Show-StepState -Step 2 -State Failed -Text ('{0} not quiet' -f $bad.Count)
        Show-Banner -Kind Warn -Title 'Quiet applied with failures' -Text (Get-QuietBannerText -Name @($bad | ForEach-Object { [string]$_.Name }))
    }
    else {
        Show-StepState -Step 2 -State Done -Text 'snapshot saved'
    }
    Invoke-ToolLaunch
    Start-RaceWatch
}

function Invoke-ToolLaunch {
    <# Opens iRacing, plus CapFrameX and LatencyMon in Tools mode. Starting and stopping captures stays manual (Rick, 2026-09-16). #>
    [CmdletBinding()]
    param()
    [string[]]$tools = Get-LaunchToolList -Mode $script:S.LaunchMode
    foreach ($tool in $tools) {
        $exe = @($script:ToolCandidate[$tool] | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
        if (-not $exe) { Write-ConsoleLog ("[WARN] {0} not found at {1}" -f $tool, ($script:ToolCandidate[$tool] -join '; ')); continue }
        $name = [System.IO.Path]::GetFileNameWithoutExtension($exe)
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { continue }
        try { [void](Start-Process -FilePath $exe -PassThru); Write-ConsoleLog ("[OK] opened {0}" -f $exe) }
        catch { Write-ConsoleLog ("[WARN] could not open {0}: {1}" -f $exe, $_.Exception.Message) }
    }
}

# --------------------------------------------------------------------------
# Step 3: race watch (log only)
# --------------------------------------------------------------------------

function Start-RaceWatch {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess('race watch', 'start timer')) { return }
    $finished = $null
    if ($null -ne $script:S.QuietResult -and $script:S.QuietResult.FinishedAt) {
        $finished = [datetime]::Parse([string]$script:S.QuietResult.FinishedAt, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    # Events from the quiet itself are before FinishedAt and are not reverts.
    $script:S.Since = if ($finished) { $finished.AddSeconds(1) } else { Get-Date }
    $script:S.DisplayNameMap = Get-SimRigServiceDisplayNameMap
    Show-StepState -Step 3 -State Current -Text 'watching'
    Show-Heading -Title 'Race watch' -Subtitle 'Watching for anything Windows turns back on. No action during the race.'
    Show-Banner -Kind Info -Title ('Watching {0} items' -f @($script:Items | Where-Object { $_.Kind -ne 'Process' }).Count) `
        -Text $(if ($script:S.LaunchMode -eq 'Tools') { 'Start the CapFrameX capture yourself. You can minimize this window. End session when you are done. It also ends by itself about two minutes after you close iRacing completely. Going back to the selection menu between runs does not end it.' } else { 'You can minimize this window. End session when you are done. It also ends by itself about two minutes after you close iRacing completely. Going back to the selection menu between runs does not end it.' })
    Show-CheckRow -Title 'Quiet read-back' -Row (ConvertTo-QuietViewRow -Result $script:S.QuietResult)
    Add-TimelineEntry -Time ((Get-Date).ToString('HH:mm:ss')) -Message 'Watch started - snapshot saved' -Severity OK
    Show-ButtonSet -Mode Watching
    $script:S.WatchTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:S.WatchTimer.Interval = [TimeSpan]::FromSeconds(15)
    $script:S.WatchTimer.Add_Tick({ Invoke-UiSafe -What 'race watch' -Action { Invoke-WatchTick } })
    $script:S.WatchTimer.Start()
}

function Invoke-WatchTick {
    [CmdletBinding()]
    param([switch] $Final)
    $rec = Get-SimRigEventRecord -Since $script:S.Since
    $svc = @($rec.Service); $tsk = @($rec.Task)
    $svcEv = if ($svc.Count) { ConvertFrom-ServiceControlEvent -Event $svc -DisplayNameMap $script:S.DisplayNameMap } else { @() }
    $tskEv = if ($tsk.Count) { ConvertFrom-TaskSchedulerEvent -Event $tsk } else { @() }
    $events = Get-WatchEvent -ServiceEvent $svcEv -TaskEvent $tskEv -QuietItem $script:Items
    $jsonl = Join-Path -Path $script:S.SessionDir -ChildPath 'watch-events.jsonl'
    foreach ($e in @($events)) {
        if ($null -eq $e) { continue }
        $key = '{0}|{1}|{2}|{3}' -f $e.Time, $e.EventId, $e.Name, $e.Message
        if (-not $script:S.WatchKey.Add($key)) { continue }
        $script:S.Watch.Add($e)
        [System.IO.File]::AppendAllText($jsonl, ($e | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine)
        if ($e.Severity -ne 'Info') {
            $row = (ConvertTo-TimelineViewRow -WatchEvent @($e))[0]
            Add-TimelineEntry -Time $row.Time -Message $row.Message -Severity $row.Severity
        }
    }
    $all = @($svc) + @($tsk)
    if ($all.Count) {
        $latest = ($all | Measure-Object -Property TimeCreated -Maximum).Maximum
        if ($latest -gt $script:S.Since) { $script:S.Since = $latest }
    }
    $running = [bool](Get-Process -Name $script:SimProcessName -ErrorAction SilentlyContinue)
    $uiRunning = [bool](Get-Process -Name $script:SimUiProcessName -ErrorAction SilentlyContinue)
    if ($running -and $null -eq $script:S.SimSeenAt) {
        $script:S.SimSeenAt = Get-Date
        Add-TimelineEntry -Time ($script:S.SimSeenAt.ToString('HH:mm:ss')) -Message 'iRacing sim started' -Severity OK
    }
    # The grace clock runs only while BOTH are gone; either one coming back
    # clears it.
    if ($running -or $uiRunning) { $script:S.SimGoneAt = $null }
    elseif ($null -eq $script:S.SimGoneAt) { $script:S.SimGoneAt = Get-Date }
    $goneFor = if ($null -eq $script:S.SimGoneAt) { 0 } else { ((Get-Date) - $script:S.SimGoneAt).TotalSeconds }
    $phase = Get-SimRigSessionEndVerdict -SimRunning $running -UiRunning $uiRunning `
        -SimSeen ($null -ne $script:S.SimSeenAt) -QuietSecondsSoFar $goneFor
    $sum = Get-WatchSummary -WatchEvent $script:S.Watch.ToArray()
    $elapsed = (Get-Date) - $script:S.SessionStart
    Show-SideKey -Title 'Session' -Row @(
        [pscustomobject]@{ Key = 'Elapsed'; Value = ('{0:hh\:mm\:ss}' -f $elapsed) }
        [pscustomobject]@{ Key = 'Reverts'; Value = ('{0}, logged' -f $sum.Reverts) }
        [pscustomobject]@{ Key = 'Tasks fired'; Value = [string]$sum.TasksFired }
        [pscustomobject]@{ Key = 'Notes'; Value = [string]$sum.Notes }
        [pscustomobject]@{ Key = 'iRacing sim'; Value = $(if ($running) { 'running' } elseif ($script:S.SimSeenAt) { 'closed' } else { 'not started yet' }) }
        [pscustomobject]@{ Key = 'Session'; Value = (Get-SimRigString -Key $phase.StringKey) }
        [pscustomobject]@{ Key = 'CapFrameX'; Value = 'start the capture yourself' }
    )
    Show-StepState -Step 3 -State Current -Text ('{0:mm\:ss} - {1} reverts' -f $elapsed, $sum.Reverts)
    # U4.13. This used to read: sim gone, so end the session. Back to the
    # selection menu exits the sim and keeps the UI, so one practice run ended
    # the evening - Windows came out of quiet and the bundle was never pushed
    # while Rick was still at the rig choosing the next session. Now only the
    # verdict ends it, and only when iRacing itself is gone.
    if ($phase.Verdict -ne $script:S.SessionPhase) {
        $script:S.SessionPhase = $phase.Verdict
        if ($phase.Verdict -eq 'BetweenSessions') {
            Add-TimelineEntry -Time ((Get-Date).ToString('HH:mm:ss')) -Message 'sim closed, iRacing still open - between sessions, Windows stays quiet' -Severity OK
            Write-ConsoleLog 'sim closed but the iRacing UI is running - staying in session'
        }
        elseif ($phase.Verdict -eq 'Racing' -and $running) {
            Add-TimelineEntry -Time ((Get-Date).ToString('HH:mm:ss')) -Message 'sim running again - next session started' -Severity OK
        }
    }
    if (-not $Final -and $phase.Verdict -eq 'Ended') {
        Write-ConsoleLog 'iRacing and its UI are both closed - ending the watch'
        Stop-RaceWatch
    }
}

function Stop-RaceWatch {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess('race watch', 'stop')) { return }
    if ($null -ne $script:S.WatchTimer) { $script:S.WatchTimer.Stop() }
    Invoke-WatchTick -Final
    $sum = Get-WatchSummary -WatchEvent $script:S.Watch.ToArray()
    Show-StepState -Step 3 -State Done -Text ('{0} reverts logged' -f $sum.Reverts)
    Write-ConsoleLog ("watch ended: {0} events, {1} reverts" -f $script:S.Watch.Count, $sum.Reverts)
    Invoke-RestoreRun -Operation Restore
}

# --------------------------------------------------------------------------
# Step 4: restore and the "Windows healthy" verdict
# --------------------------------------------------------------------------

function Invoke-RestoreRun {
    [CmdletBinding()]
    param([ValidateSet('Restore', 'Undo', 'Fix')] [string] $Operation = 'Restore', [string[]] $OnlyId)
    if ($script:S.Busy) { return }
    Show-StepState -Step 4 -State Current -Text 'restoring'
    Show-Heading -Title 'Restore' -Subtitle 'Replaying the snapshot, then reading every item back. Approve the Windows prompt.'
    # The banner too, not only the heading. Without this the banner still read
    # "Watching 87 items" all through the restore - the loudest text on the screen
    # describing the state the app has just left (beta.1 review, section 9).
    $restoreBanner = switch ($Operation) {
        'Undo' { @{ Title = 'Undoing every change'; Text = 'Putting back everything this app has ever changed on this PC, then reading each item back. Approve the Windows prompt.' } }
        'Fix' { @{ Title = 'Fixing the items that did not match'; Text = 'Replaying the snapshot for those items only, then reading them back. Approve the Windows prompt.' } }
        default { @{ Title = 'Putting Windows back'; Text = 'Replaying this session''s snapshot, then reading every item back. Approve the Windows prompt.' } }
    }
    Show-Banner -Kind Info -Title $restoreBanner.Title -Text $restoreBanner.Text
    $dir = if ($script:S.SessionDir) { $script:S.SessionDir } else { $script:Paths.Sessions }
    Invoke-ElevatedStep -Operation $Operation -SessionDir $dir -OnlyId $OnlyId -ModeOnCancel RestoredRed -OnDone {
        param($Result, $Failure)
        Complete-Restore -Result $Result -Failure $Failure
    }
}

function Complete-Restore {
    [CmdletBinding()]
    param([AllowNull()] [object] $Result, [AllowNull()] [string] $Failure)
    if ($Failure) {
        Show-StepState -Step 4 -State Failed -Text 'did not run'
        Show-Banner -Kind Bad -Title 'Restore did not run' -Text $Failure
        Show-ButtonSet -Mode RestoredRed
        return
    }
    $script:S.RestoreResult = $Result
    if ($null -eq $Result.Verdict) {
        # Undo with nothing to undo.
        Show-Banner -Kind Info -Title 'Nothing to restore' -Text (@($Result.Errors) -join ' ')
        Invoke-PreflightRun
        return
    }
    $script:S.Verdict = $Result.Verdict
    Show-CheckRow -Title 'Restore' -Row (ConvertTo-RestoreViewRow -Result $Result)
    # RF-3, R1: the banner and the side card have one short text, with no more than
    # three item names. The rows above name each item. Verdict.Line, with each name,
    # is in the action log and in the result file.
    $verdictText = Get-RestoreBannerText -Verdict $Result.Verdict
    Show-Verdict -Text $verdictText -Green ([bool]$Result.Verdict.Green)
    foreach ($e in @($Result.Errors)) { Add-TimelineEntry -Time ((Get-Date).ToString('HH:mm:ss')) -Message $e -Severity Note }
    if ($Result.Verdict.Green) {
        # RF-1: with an item that Windows refused at quiet time, the verdict line says
        # that an item differs, so the texts do not say "verified" beside it.
        $done = Get-RestoreDoneText -Verdict $Result.Verdict
        Show-StepState -Step 4 -State Done -Text $done.StepText
        Show-Heading -Title 'Session complete' -Subtitle $done.Subtitle
        Show-Banner -Kind Ok -Title $done.BannerTitle -Text $verdictText
        Show-ButtonSet -Mode Restored
    }
    else {
        Show-StepState -Step 4 -State Failed -Text 'NOT healthy'
        Show-Heading -Title 'Restore needs you' -Subtitle 'Some items did not go back. Fix tries them again; the deadman task retries at next sign-in.'
        Show-Banner -Kind Bad -Title 'Windows is NOT healthy' -Text $verdictText
        Show-ButtonSet -Mode RestoredRed
    }
    if ($script:S.SessionDir) { Invoke-ReportWrite }
}

# --------------------------------------------------------------------------
# Report, push, LatencyMon
# --------------------------------------------------------------------------

function Invoke-ReportWrite {
    [CmdletBinding()]
    param()
    $capture = $null
    if ($script:S.SessionStart) {
        # CapFrameX saves its captures in C:\SimRacer\Logs (the launcher's Collect & Push reads the same place).
        $file = Get-SimRigNewestFile -Directory ($script:Paths.Root + '\Logs') -Filter 'CapFrameX-*.json' -Since $script:S.SessionStart
        $capture = [pscustomobject]@{ Name = $(if ($file) { $file.Name } else { $null }); Found = [bool]$file; Path = $(if ($file) { $file.FullName } else { $null }) }
    }
    $snapshot = $null
    if ($script:S.QuietResult -and $script:S.QuietResult.SnapshotPath) { $snapshot = Read-SimRigJson -Path $script:S.QuietResult.SnapshotPath }
    $versions = Get-VersionsHeader -Text $(if ($script:S.Fact) { $script:S.Fact.VersionsText } else { $null })
    $report = Build-SessionReport -Session @{
        Id = $script:S.Stamp; Stamp = (Format-SimRigTime -Time $script:S.SessionStart); Rig = $env:COMPUTERNAME
        StartedAnyway = $script:S.StartedAnyway; Versions = $versions; FileHash = $(if ($script:S.Fact) { $script:S.Fact.FileHash } else { $null })
    } -Preflight $script:S.Check -Snapshot $snapshot -QuietResult $script:S.QuietResult -WatchEvent $script:S.Watch.ToArray() `
        -RestoreResult $script:S.RestoreResult -Verdict $script:S.Verdict -Capture $capture -BundleCheck $script:S.BundleCheck -LatencyMon $script:S.LatencyMonFile
    # T.7 load check, automated: the console's own CPU time and wall time for the session.
    $me = Get-Process -Id $PID
    $report['LaunchMode'] = $script:S.LaunchMode
    $report['ConsoleLoad'] = [ordered]@{ CpuSeconds = [Math]::Round($me.TotalProcessorTime.TotalSeconds, 1); WallSeconds = [Math]::Round(((Get-Date) - $script:S.SessionStart).TotalSeconds, 0) }
    [string[]]$problems = Test-SessionReport -Report $report
    foreach ($p in @($problems | Where-Object { $_ })) { Write-ConsoleLog ("[WARN] report: {0}" -f $p) }
    $path = Write-SessionJson -Name 'v4-report.json' -InputObject $report
    Write-ConsoleLog ("report -> {0}" -f $path)
    if (-not $capture.Found -and $script:S.LaunchMode -eq 'Tools') {
        Add-TimelineEntry -Time ((Get-Date).ToString('HH:mm:ss')) -Message 'No CapFrameX capture newer than this session was found (warning, not a failure)' -Severity Note
    }
    return $capture
}

function Invoke-Push {
    [CmdletBinding()]
    param()
    # An unset share is not an error, and the reachability check below throws on an
    # empty string, so the unset case is answered first.
    if ([string]::IsNullOrWhiteSpace($script:NasRoot)) {
        Show-Banner -Kind Info -Title 'No share set up' -Text 'Push copies a session to a folder on your network, and none is set. Start the console with -NasRoot "<folder>", or add NasRoot to your profile. Nothing was copied, and the session files are still in your sessions folder.'
        return
    }
    if (-not (Test-Path -LiteralPath $script:NasRoot)) {
        Show-Banner -Kind Bad -Title 'Share not visible' -Text ('{0} is not reachable from this session. Nothing was copied. Map the drive and try Push again.' -f $script:NasRoot)
        return
    }
    $capture = Invoke-ReportWrite
    $dest = Get-NasBundlePath -NasRoot $script:NasRoot -SessionStamp $script:S.Stamp
    [void](New-Item -ItemType Directory -Path $dest -Force)
    $copied = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @(Get-ChildItem -LiteralPath $script:S.SessionDir -File)) {
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        $copied.Add($f.Name)
    }
    if ($capture -and $capture.Found) { Copy-Item -LiteralPath $capture.Path -Destination $dest -Force; $copied.Add($capture.Name) }

    # Bundle integrity gate (TODO 2.5b): strict parse, frame counts, 6/8 MiB flag - on the COPIES.
    $files = foreach ($j in @(Get-ChildItem -LiteralPath $dest -File -Filter '*.json')) {
        [pscustomobject]@{ Name = $j.Name; Length = $j.Length; Text = [System.IO.File]::ReadAllText($j.FullName) }
    }
    $script:S.BundleCheck = Test-BundleIntegrity -File @($files)
    [void](Invoke-ReportWrite)
    Copy-Item -LiteralPath (Join-Path $script:S.SessionDir 'v4-report.json') -Destination $dest -Force
    $script:S.PushedTo = $dest
    Write-ConsoleLog ("pushed {0} files to {1}; bundle gate: {2}" -f $copied.Count, $dest, $script:S.BundleCheck.Line)

    $rows = foreach ($r in @($script:S.BundleCheck.Files)) {
        [pscustomobject]@{ Name = [string]$r.Name; Detail = $(if ($r.Pass) { 'parses strictly' } else { (@($r.Reasons) -join '; ') }); Value = ('{0:N1} MB' -f ($r.Length / 1MB)); Source = 'bundle gate'; Verdict = $(if ($r.Pass) { 'Pass' } else { 'Fail' }) }
    }
    $lm = if ($script:S.LatencyMonFile) { [pscustomobject]@{ Name = 'LatencyMon report'; Detail = $script:S.LatencyMonFile; Value = '-'; Source = 'clipboard'; Verdict = 'OK' } }
    else { [pscustomobject]@{ Name = 'LatencyMon report'; Detail = 'Copy it in LatencyMon (Edit > Copy Report Text), then Save here'; Value = 'waiting'; Source = 'clipboard'; Verdict = 'Waiting' } }
    Show-CheckRow -Title ('Pushed to {0}' -f $dest) -Row (@($rows) + @($lm))
    Show-StepState -Step 5 -State $(if ($script:S.BundleCheck.Pass) { 'Done' } else { 'Failed' }) -Text ('{0} files' -f $copied.Count)
    Show-Banner -Kind $(if ($script:S.BundleCheck.Pass) { 'Ok' } else { 'Warn' }) -Title 'Pushed to the NAS' -Text ('{0} files copied to {1}. {2}' -f $copied.Count, $dest, $script:S.BundleCheck.Line)
    Show-ButtonSet -Mode Pushed
}

function Invoke-LatencyMonSave {
    <# Validates the clipboard text first. Saves NOTHING when it is not a LatencyMon report, and says why. #>
    [CmdletBinding()]
    param()
    $text = Get-Clipboard -Raw
    $check = Test-LatencyMonReport -Text $(if ($null -eq $text) { '' } else { $text })
    if (-not $check.IsValid) {
        Show-Banner -Kind Warn -Title 'Nothing saved' -Text ('The clipboard does not hold a LatencyMon report: {0}. In LatencyMon: Stop, then Edit > Copy Report Text to Clipboard.' -f (@($check.Reasons) -join '; '))
        Write-ConsoleLog ("[WARN] LatencyMon save refused: {0}" -f (@($check.Reasons) -join '; '))
        return
    }
    $dir = if ($script:S.SessionDir) { $script:S.SessionDir } else { $script:Paths.Logs }
    $name = Get-LatencyMonFileName -Time (Get-Date)
    $path = Join-Path -Path $dir -ChildPath $name
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
    $script:S.LatencyMonFile = $name
    Write-ConsoleLog ("LatencyMon report saved: {0}" -f $path)
    if ($script:S.SessionDir) { [void](Invoke-ReportWrite) }
    if ($script:S.PushedTo -and (Test-Path -LiteralPath $script:S.PushedTo)) {
        Copy-Item -LiteralPath $path -Destination $script:S.PushedTo -Force
        Copy-Item -LiteralPath (Join-Path $script:S.SessionDir 'v4-report.json') -Destination $script:S.PushedTo -Force
    }
    Show-Banner -Kind Ok -Title 'LatencyMon report saved' -Text $name
}

# --------------------------------------------------------------------------
# Fix GPU steering (v4.0.4)
# --------------------------------------------------------------------------

function Get-GpuFixScope {
    <#
        Flag 7. The public default steers the Display function only. A profile that
        asks for All keeps the behaviour its values were measured with - which is
        Rick's rig and his DEV_22BA audio rule, and nobody else's.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $values = Get-KnownGoodField -Entry $script:RigProfile -Name 'Values'
    $asked = [string](Get-KnownGoodField -Entry $values -Name 'GpuSteeringScope')
    if ($asked -eq 'All') { return 'All' }
    return 'Display'
}

function Invoke-FixGpu {
    <#
        One elevated FixGpu step: writes the known-good steering to the present
        NVIDIA devices and reads it back.

        Flag 7 asks twice, and the second ask is not a formality: applying this
        restarts the graphics device, so the screens go black for a few seconds and a
        program using the GPU can reset. Somebody who does not know that will think
        the PC crashed.
    #>
    [CmdletBinding()]
    param([switch] $Confirmed)
    if ($script:S.Busy) { return }

    if (-not $Confirmed) {
        $scope = Get-GpuFixScope
        Show-TuningConfirm -Visible $true -Title (Get-SimRigString -Key 'GpuFix_ConfirmTitle') `
            -Text ((Get-SimRigString -Key 'GpuFix_ConfirmText') -f $(if ($scope -eq 'All') { Get-SimRigString -Key 'GpuFix_ScopeAll' } else { Get-SimRigString -Key 'GpuFix_ScopeDisplay' }))
        $script:S.PendingConfirm = 'FixGpu'
        return
    }
    Show-TuningConfirm -Visible $false

    $dir = Join-Path -Path $script:Paths.Sessions -ChildPath ((Get-SessionStamp -Time (Get-Date)) + '_gpufix')
    [void](New-Item -ItemType Directory -Path $dir -Force)
    # Text 21 of PUSH2-TEXTS-FOR-RICK-2026-10-03.md (Rick's "Yes").
    Show-Heading -Title 'Fix GPU steering' -Subtitle 'Writing the GPU interrupt steering of this rig. Approve the Windows prompt.'
    Invoke-ElevatedStep -Operation FixGpu -SessionDir $dir -ModeOnCancel $script:S.PreMode -GpuScope (Get-GpuFixScope) -OnDone {
        param($Result, $Failure)
        $rows = foreach ($r in @($(if ($Result) { $Result.ReadBack } else { @() }))) {
            [pscustomobject]@{ Name = [string]$r.Id; Detail = ('expected {0}' -f $r.Expected); Value = [string]$r.Actual; Source = 'registry read-back'; Verdict = $(if ($r.Match) { 'Pass' } else { 'Fail' }) }
        }
        Show-CheckRow -Title 'GPU steering read-back' -Row @($rows)
        # beta1-fix D-B: exit 1 takes the failure path too.
        $outcome = Get-SimRigActionOutcome -Result $Result -Failure $Failure
        if ($outcome.State -eq 'Failed') {
            Write-ConsoleLog ('GPU steering not fixed: {0}' -f $outcome.Text)
            # beta1-fix, text D2.
            $fail = Get-SimRigActionFailText -Operation FixGpu -Result $Result -Failure $Failure -MarkerPresent $false
            Show-Banner -Kind Bad -Title $fail.Title -Text $fail.Text
            Show-ButtonSet -Mode $script:S.PreMode
            return
        }
        if ($outcome.State -eq 'NothingWritten') {
            # beta1-fix, text D5 (Limit 3): exit 0 and no value written, so no device was restarted.
            Write-ConsoleLog 'GPU steering: exit 0, no value written'
            Show-Banner -Kind Ok -Title 'GPU steering applied' -Text 'Each NVIDIA device already reads back at the policy of this rig. Nothing was written.'
            Invoke-PreflightRun
            return
        }
        Write-ConsoleLog 'GPU steering written, devices restarted, read back'
        # Text 22 of PUSH2-TEXTS-FOR-RICK-2026-10-03.md (Rick's "Yes").
        Show-Banner -Kind Ok -Title 'GPU steering applied' -Text 'Each NVIDIA device reads back at the policy of this rig, and was restarted, so the policy is active now. On this rig Windows gives the GPU a new device ID at each restart, so the console checks again at each start. Undo tuning does not put this policy back.'
        Invoke-PreflightRun
    }
}

function Get-ConsoleTuningOffer {
    <#
        Push 2 of the unit tune, step 7b. The offer of this PC, made from the last preflight reading
        with the same function as the elevated child (Get-SimRigTuningOffer): the rules and the
        profile on a supported PC, known-good.psd1 on the rig. It is made again at each press of
        Apply tuning, so after an Apply the list has the values of the new reading (the Cowork note
        of the layout of 7b, point 4).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $fact = @{
        Registry    = $(if ($script:S.Fact) { $script:S.Fact.Registry } else { @{} })
        PowerScheme = $(if ($script:S.Fact) { $script:S.Fact.PowerScheme } else { $null })
        GpuAffinity = @($(if ($script:S.Fact) { $script:S.Fact.GpuAffinity } else { @() }))
    }
    $rules = foreach ($doc in @($script:RuleDocument)) { @(Get-KnownGoodField -Entry $doc -Name 'Rules') }
    # Assign, then wrap: the function returns the comma form.
    $offer = Get-SimRigTuningOffer -Support $script:TuningSupport -Machine $script:Machine -Rule @($rules) `
        -ProfileValues (Get-KnownGoodField -Entry $script:RigProfile -Name 'Values') -KnownGood $script:KnownGood -Fact $fact
    return , @($offer)
}

function Invoke-ApplyTuningFlow {
    <#
        v4.1. The Apply tuning button. The console asks once here, the dialog
        asks a second time, and only then does the elevated child write
        (flag 7). It refuses while iRacing, a CapFrameX capture or OBS runs,
        and the child refuses again on its own.

        Push 2 of the unit tune, step 7b (design section 4, the Cowork note of the layout of 7b): the
        first ask is the tick list in the dialog (no -Ticked, no -Confirmed); Apply there gives
        -Ticked, the second ask with only the ticked items; Apply there gives -Confirmed, and the
        child gets the ticked ids (-OnlyId). With no item to write, no dialog opens: text 13.
        Cancel at each ask writes nothing. The rig gets the same dialog, with the items of
        known-good.psd1.
    #>
    [CmdletBinding()]
    param([switch] $Ticked, [switch] $Confirmed)

    if ($script:S.Busy) { return }
    # Assign, then wrap: the function returns the comma form.
    $offer = Get-ConsoleTuningOffer
    $planName = if ($script:S.Fact -and $script:S.Fact.PowerScheme) { [string](Get-KnownGoodField -Entry $script:S.Fact.PowerScheme -Name 'Name') } else { $null }

    if (-not $Ticked -and -not $Confirmed) {
        # A-FIX-02: with nothing to write there is no ask - confirming nothing twice
        # is how a dialog becomes furniture.
        $confirm = Get-TuningConfirmView -Offer @($offer) -Ticked @()
        if (-not $confirm.CanOffer) {
            Show-Banner -Kind Ok -Title (Get-SimRigString -Key 'Tuning_NothingTitle') -Text (Get-SimRigString -Key 'Tuning_NothingText')
            Show-ButtonSet -Mode $script:S.PreMode
            return
        }
        $rows = Get-TuningTickRow -Offer @($offer) -State ([string]$script:TuningSupport.State) -PlanName $planName
        $script:S.TuningTicked = $null
        Show-TuningConfirm -Visible $true -Title (Get-SimRigString -Key 'Tuning_TickTitle') -Text (Get-SimRigString -Key 'Tuning_TickText') -TickRow @($rows)
        $script:S.PendingConfirm = 'TuningTick'
        return
    }
    if ($Ticked) {
        # Assign, then wrap: the function returns the comma form.
        $ids = Get-TuningTickedId
        $confirm = Get-TuningConfirmView -Offer @($offer) -Ticked @($ids)
        # Apply is not active with no tick; if it is pressed, the first ask stays.
        if (-not $confirm.CanApply) { $script:S.PendingConfirm = 'TuningTick'; return }
        $script:S.TuningTicked = @($confirm.ChangeItem | ForEach-Object { [string]$_.Id })
        $message = Get-TuningConfirmMessage -View $confirm -PlanName $planName
        Show-TuningConfirm -Visible $true -Title $message.Title -Text $message.Text
        $script:S.PendingConfirm = 'ApplyTuning'
        return
    }
    Show-TuningConfirm -Visible $false
    # Not $ticked: a local with the name of the switch -Ticked is that switch (names do not depend on case).
    $tickedIds = @($script:S.TuningTicked | Where-Object { $_ })
    $script:S.TuningTicked = $null
    if ($tickedIds.Count -eq 0) { return }

    $dir = Join-Path -Path $script:Paths.Sessions -ChildPath ((Get-SessionStamp -Time (Get-Date)) + '_tuning')
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $script:S.TuningDir = $dir
    Show-Heading -Title 'Apply tuning' -Subtitle (Get-SimRigString -Key 'Tuning_ApplySubtitle')
    Invoke-ElevatedStep -Operation ApplyTuning -SessionDir $dir -OnlyId $tickedIds -ModeOnCancel $script:S.PreMode -OnDone {
        param($Result, $Failure)
        # Step 7b: an Apply can write the marker, also when it fails after a write.
        $script:TuningMarkerPresent = Test-Path -LiteralPath $script:Paths.TuningMarker
        $rows = foreach ($r in @($(if ($Result) { $Result.ReadBack } else { @() }))) {
            [pscustomobject]@{ Name = [string]$r.Id; Detail = ('expected {0}' -f $r.Expected); Value = [string]$r.Actual; Source = 'read-back'; Verdict = $(if ($r.Match) { 'Pass' } else { 'Fail' }) }
        }
        # Step 7c: text 18 from the result of this run; the path of UNDO-BY-HAND.txt is in a row and in
        # the log, not in the banner.
        $done = Get-SimRigTuningDoneText -Operation Apply -Result $Result
        # beta1-fix D-B: the success banner only for exit 0 with a value written.
        $outcome = Get-SimRigActionOutcome -Result $Result -Failure $Failure
        $handRow = $null
        # beta1-fix D-C: the child keeps the two files UNDO-BY-HAND.txt only when the marker is there after the run
        # (a marker from before, or one that this run wrote). A run that wrote GPU steering only writes no marker:
        # Undo does not put steering back.
        # REVIEW-beta1-fix-8a947a0.md finding 2: also for a run that wrote a value and then failed a step.
        $wroteStep = @(@($(if ($Result) { $Result.Steps } else { @() })) | Where-Object { $null -ne $_ -and [string]$_.Status -eq 'Done' }).Count -gt 0
        if ($wroteStep -and $script:TuningMarkerPresent -and $done.HandFile) {
            $handRow = [pscustomobject]@{ Name = 'UNDO-BY-HAND.txt'; Detail = $done.HandFile; Value = '-'; Source = 'Apply tuning'; Verdict = 'Info'; Rank = 3 }
            $rows = @($rows) + @($handRow)
        }
        Show-CheckRow -Title 'Tuning read-back' -Row @($rows)
        if ($outcome.State -eq 'Failed') {
            Write-ConsoleLog ('tuning not applied: {0}' -f $outcome.Text)
            # beta1-fix, texts D2 and D3: the record that the marker names, only when it is the snapshot of this run.
            $marker = if ($script:TuningMarkerPresent) { Read-SimRigJson -Path $script:Paths.TuningMarker } else { $null }
            $recordPath = [string](Get-KnownGoodField -Entry $marker -Name 'SnapshotPath')
            $record = if ($recordPath -and $Result -and $recordPath -eq [string](Get-KnownGoodField -Entry $Result -Name 'SnapshotPath')) { Read-SimRigJson -Path $recordPath } else { $null }
            $fail = Get-SimRigActionFailText -Operation Apply -Result $Result -Failure $Failure -MarkerPresent $script:TuningMarkerPresent -Marker $marker -Record $record
            Show-Banner -Kind Bad -Title $fail.Title -Text $fail.Text
            Show-ButtonSet -Mode $script:S.PreMode
            return
        }
        if ($outcome.State -eq 'NothingWritten') {
            # Text 13: each value already had a value that the app accepts.
            Write-ConsoleLog 'tuning: exit 0, no value written'
            $nothing = @{ Title = (Get-SimRigString -Key 'Tuning_NothingTitle'); Text = (Get-SimRigString -Key 'Tuning_NothingText'); Row = $null }
            Show-Banner -Kind Ok -Title $nothing.Title -Text $nothing.Text
            $script:S.RunBanner = $nothing
            Invoke-PreflightRun
            return
        }
        # beta1-fix2 (REVIEW-beta1-fix2-18b72eb.md finding 1): after a steering-only Apply the child removed the file, so
        # the log names it only with the row (the child keeps the file).
        # REVIEW-beta1-fix2-e95d182.md finding 2: the text says only what the window did, so it is true on each path.
        $handLog = if ($handRow) { $done.HandFile } else { 'none (the window shows no UNDO-BY-HAND.txt row)' }
        Write-ConsoleLog ('tuning applied, snapshot {0}, UNDO-BY-HAND.txt {1}' -f $Result.SnapshotPath, $handLog)
        Show-Banner -Kind Ok -Title $done.Title -Text $done.Text
        # Causes row 21: the check below shows this banner and the row again when it is done.
        $script:S.RunBanner = @{ Title = $done.Title; Text = $done.Text; Row = $handRow }
        Invoke-PreflightRun
    }
}

function Invoke-UndoTuningFlow {
    <#
        v4.1. The Undo tuning button: replays the snapshot of record. Push 2 of the unit tune, step 7:
        it reads the marker on disk, not the session of this window, so Undo works also after the app
        was closed (design section 5). Get-SimRigUndoTuningStart decides; the child reads the marker
        again.
    #>
    [CmdletBinding()]
    param()
    if ($script:S.Busy) { return }
    $markerPresent = Test-Path -LiteralPath $script:Paths.TuningMarker
    $marker = if ($markerPresent) { Read-SimRigJson -Path $script:Paths.TuningMarker } else { $null }
    $start = Get-SimRigUndoTuningStart -MarkerPresent $markerPresent -Marker $marker -MarkerPath $script:Paths.TuningMarker
    if (-not $start.Start) {
        Write-ConsoleLog ('undo tuning not started: {0}' -f $start.Text)
        Show-Banner -Kind $start.Kind -Title $start.Title -Text $start.Text
        return
    }
    Show-Heading -Title 'Undo tuning' -Subtitle $start.Subtitle
    $dir = if ($script:S.TuningDir) { $script:S.TuningDir } else { $script:Paths.Sessions }
    Invoke-ElevatedStep -Operation UndoTuning -SessionDir $dir -ModeOnCancel $script:S.PreMode -OnDone {
        param($Result, $Failure)
        # Step 7b: a green Undo removes the marker.
        $script:TuningMarkerPresent = Test-Path -LiteralPath $script:Paths.TuningMarker
        $rows = foreach ($r in @($(if ($Result) { $Result.ReadBack } else { @() }))) {
            [pscustomobject]@{ Name = [string]$r.Id; Detail = ('expected {0}' -f $r.Expected); Value = [string]$r.Actual; Source = 'read-back'; Verdict = $(if ($r.Match) { 'Pass' } else { 'Fail' }) }
        }
        Show-CheckRow -Title 'Tuning read-back' -Row @($rows)
        # beta1-fix D-B: exit 1 takes the failure path too.
        $outcome = Get-SimRigActionOutcome -Result $Result -Failure $Failure
        if ($outcome.State -eq 'Failed') {
            Write-ConsoleLog ('tuning not undone: {0}' -f $outcome.Text)
            # beta1-fix, texts D2 and D4.
            $fail = Get-SimRigActionFailText -Operation Undo -Result $Result -Failure $Failure -MarkerPresent $script:TuningMarkerPresent
            Show-Banner -Kind Bad -Title $fail.Title -Text $fail.Text
            Show-ButtonSet -Mode $script:S.PreMode
            return
        }
        # Step 7c: text 20, with texts 50, 51 and 7, from the result of this run.
        $done = Get-SimRigTuningDoneText -Operation Undo -Result $Result
        Write-ConsoleLog ('tuning undone from the snapshot: {0}' -f $done.Text)
        Show-Banner -Kind Ok -Title $done.Title -Text $done.Text
        # Causes row 21: the check below shows this banner again when it is done.
        $script:S.RunBanner = @{ Title = $done.Title; Text = $done.Text; Row = $null }
        Invoke-PreflightRun
    }
}

function Invoke-GpuSteeringAutoFix {
    <#
        v4.1, Rick 2026-09-20 (Fable F.3 finding 1). The NVIDIA instance IDs
        change at every boot on this rig, so a written policy is orphaned by
        the next restart. The console now opens the ask of Fix GPU steering
        itself, once per start, instead of waiting for a click on the button.
        It writes nothing before the user says yes to the ask and to the
        Windows prompt (beta1-fix2 E-3), and FixGpu refuses while iRacing runs.
    #>
    [CmdletBinding()]
    param()
    if ($script:GpuAutoFixDone) { return }
    # Blocker 4: the fix writes the steering of the rig, so it runs on the rig only.
    # Get-SimRigTuningAllowed: a rule that is not set is "not allowed", not an error in
    # strict mode (REVIEW at 6125ee8, finding C).
    if (-not (Get-SimRigTuningAllowed)) { return }
    if ($StartupReport) { return }
    if ($script:S.Busy) { return }
    if (-not $script:S.Check) { return }
    if (-not (Test-GpuSteeringOrphaned -Check $script:S.Check)) { return }
    $script:GpuAutoFixDone = $true
    # beta1-fix2 E-3: Invoke-FixGpu with no -Confirmed opens the ask (flag 7) and writes nothing before the user says yes.
    Write-ConsoleLog 'GPU steering is missing or different - opening the ask of Fix GPU steering (v4.1)'
    # Text 23 of PUSH2-TEXTS-FOR-RICK-2026-10-03.md (Rick's "Yes"): the reading shows only "missing or different".
    # Its second sentence changed by beta1-texts (Rick's "T23 box", 2026-10-15): the start writes nothing, it opens the
    # box of Invoke-FixGpu, whose title is GpuFix_ConfirmTitle in SimRig.Strings.ps1.
    Show-Banner -Kind Warn -Title 'GPU steering needs writing' -Text 'The GPU interrupt steering of this rig is missing or different. Answer the box "Confirm the GPU steering fix" to write it again, then approve the Windows prompt.'
    Invoke-FixGpu
}

# --------------------------------------------------------------------------
# Dry run
# --------------------------------------------------------------------------

function Invoke-DryRun {
    [CmdletBinding()]
    param()
    if ($script:S.Busy) { return }
    $stamp = (Get-SessionStamp -Time (Get-Date)) + '_dryrun'
    $dir = Join-Path -Path $script:Paths.Sessions -ChildPath $stamp
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $script:DryRunMode = $script:S.PreMode
    Invoke-ElevatedStep -Operation Quiet -SessionDir $dir -WhatIfRun -ModeOnCancel $script:DryRunMode -OnDone {
        param($Result, $Failure)
        $mode = $script:DryRunMode
        if ($Failure) { Show-Banner -Kind Bad -Title 'Dry run failed' -Text $Failure; Show-ButtonSet -Mode $mode; return }
        $planned = @($Result.Steps | Where-Object { $_.Status -eq 'WhatIf' }).Count
        $changed = @($Result.ReadBack | Where-Object { -not $_.Match }).Count
        Show-CheckRow -Title 'Dry run - what Quiet would do' -Row (ConvertTo-QuietViewRow -Result $Result)
        $kind = if ($changed -eq 0) { 'Info' } else { 'Bad' }
        Show-Banner -Kind $kind -Title 'Dry run' -Text ('{0} changes planned. Machine state after the dry run: {1}.' -f $planned, $(if ($changed -eq 0) { 'unchanged' } else { "$changed items CHANGED - report this" }))
        Show-ButtonSet -Mode $mode
    }
}

# --------------------------------------------------------------------------
# Start
# --------------------------------------------------------------------------

foreach ($d in @($script:Paths.Logs, $script:Paths.Results, $script:Paths.Sessions)) {
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
}
$script:LogPath = $script:Paths.ConsoleLogPattern -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
Write-ConsoleLog ('SimRig Console start ({0}, pwsh {1})' -f $PSCommandPath, $PSVersionTable.PSVersion)
# Assign, then loop: the function returns its list with a comma (A-LINT-02).
$logFaults = Complete-ConsoleChildLogSweep -ResultDir $script:Paths.Results -ActionsLog (Join-Path -Path $script:Paths.Logs -ChildPath 'actions.log')
foreach ($logFault in $logFaults) {
    Write-ConsoleLog ('[WARN] {0}' -f $logFault)
}

$listData = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'quiet-list.psd1')
$script:KnownGood = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'known-good.psd1')
[string[]]$listErrors = Test-QuietListData -Data $listData
[string[]]$kgErrors = Test-KnownGoodData -Data $script:KnownGood
$dataErrors = @($listErrors | Where-Object { $_ }) + @($kgErrors | Where-Object { $_ })
$script:AllItems = ConvertTo-QuietItem -Data $listData

# --------------------------------------------------------------------------
# v4.2: rules, profiles, discovery (lead, 2026-09-26)
#
# None of this was here. The rules, the profiles, the discovery readers, the
# machine profile and the six screens were all written and tested, and the
# controller called none of them - so the app graded every PC against Rick's own
# measured values and the new screens were unreachable. Unit U3.12 found it while
# reading the tree to write the documentation, after nine hundred unit tests had
# gone green around the gap. tests/Wiring.Tests.ps1 now fails if this comes apart
# again.
#
# Order matters here. The profile has to be chosen before discovery runs, because
# the single-CCD steering target is a profile value that discovery is forbidden to
# synthesize; the machine profile has to exist before grading, because the dual-CCD
# guards and the power-plan rule read it; and the quiet list has to be filtered
# before any plan is built, because that filter is the only thing standing between
# a stranger and having their Bluetooth switched off mid-race.
# --------------------------------------------------------------------------
# Flag 3, and it runs before anything else loads. The console asks for elevation
# and then runs the code in this folder as administrator. If a standard user can
# write here, they choose what Windows runs elevated, and the app would be shipping
# a local privilege escalation as a feature. The installer sets an ACL that prevents
# it; this notices when something else has undone that - a hand-copied install, an
# extract to the Desktop, a folder someone loosened to get past a permissions error.
#
# The rule is the installer's own (engine/Engine.Install.ps1), not a second copy:
# two rules that can disagree about what is safe is worse than one.
$script:InstallRootAcl = Get-SimRigInstallRootAcl -Path $PSScriptRoot
$script:InstallRootVerdict = Get-SimRigInstallAclVerdict -Ace $script:InstallRootAcl
if (-not $script:InstallRootVerdict.IsSafe) {
    $offenderText = if (@($script:InstallRootVerdict.Offender).Count -gt 0) {
        @($script:InstallRootVerdict.Offender) -join ', '
    } else {
        'the folder permissions could not be read'
    }
    $installRootMessage = ('SimRig Console will not run from this folder: {0}. It is writable by {1}, and the console runs its own code as administrator - so anyone who can change these files can choose what runs elevated. Re-install with Setup.cmd, which sets the permissions, and do not copy the folder by hand.' -f $PSScriptRoot, $offenderText)
    Write-ConsoleLog ('Install root refused: {0}' -f $installRootMessage)
    $dataErrors = @($dataErrors) + @($installRootMessage)
}

$ruleLoad = Get-SimRigRuleDocument -Directory (Join-Path $PSScriptRoot 'rules')
$profileLoad = Get-SimRigProfileDocument -Directory (Join-Path $PSScriptRoot 'profiles')
$dataErrors = @($dataErrors) + @($ruleLoad.Error) + @($profileLoad.Error)
$script:RuleDocument = $ruleLoad.Document
$script:RuleVersion = Get-RuleVersion -Document $script:RuleDocument

# Read the machine, then pick the profile it matches, then read again with that
# profile's steering target so the target can be checked against the real L3 mask.
# Two passes rather than one because neither half can be skipped: discovery cannot
# invent the target, and profile selection needs a machine to match against.
# Settings (spec 11a, flag 16). Read before discovery, because a confirmed display
# layout changes what discovery reports. A file this app cannot read is refused rather
# than guessed at, and the refusal is a banner, not a silent default.
$script:SettingsRaw = Get-SimRigSettingsRaw -Path $script:Paths.Settings
$script:SettingsLoad = Repair-SimRigSettings -RawData $script:SettingsRaw `
    -DefaultSavePath (Get-SimRigDefaultSavePath -DocumentsPath ([string]$env:USERPROFILE + '\Documents') `
        -IsOneDriveRedirected $false -UserProfilePath ([string]$env:USERPROFILE)) `
    -DefaultProfileId $null
$script:Settings = $script:SettingsLoad.Settings
if ($script:SettingsLoad.Refused) {
    Write-ConsoleLog ('[WARN] settings not loaded: {0}' -f $script:SettingsLoad.RefusedReason)
}
foreach ($settingsNote in @($script:SettingsLoad.Warning)) { Write-ConsoleLog ('  settings: {0}' -f $settingsNote) }

# Blocker 5 (2026-10-02): the steps are in Get-SimRigMachineContext, and the elevated
# child calls the same function. The child decides what it writes; this window shows it.
$machineContext = Get-SimRigMachineContext -ProfileDocument @($profileLoad.Document) -MachineName $env:COMPUTERNAME -Settings $script:Settings
$script:MachineReading = $machineContext.Reading
$script:RigProfile = $machineContext.RigProfile
$script:Machine = $machineContext.Machine
# Blocker 4, push 1 of the unit tune: the tuning buttons and the automatic steering
# fix write the values of known-good.psd1, so they are only for a profile with the key
# Values.TuningFromKnownGood. The elevated child refuses the same three operations
# with the same key (Test-ActionTuningAllowed).
$script:TuningAllowed = Test-ProfileTuningAllowed -RigProfile $script:RigProfile
if (-not $script:TuningAllowed) { Write-ConsoleLog '  tuning: This version does not change tuning settings on this PC.' }
# Push 2 of the unit tune, step 3: on a PC that is not the rig the four tuning rows of the
# preflight are graded from the rules and the profile of this PC, not from the values of the rig.
$script:TuningSupport = Get-SimRigTuningSupport -Machine $script:Machine -RigProfile $script:RigProfile
# Step 7b: Apply tuning and Undo tuning on the rig and on a supported PC (the child decides again),
# and Undo tuning also where the marker of an earlier Apply is there.
$script:TuningOffered = @('Rig', 'Supported') -contains [string]$script:TuningSupport.State
$script:TuningMarkerPresent = Test-Path -LiteralPath $script:Paths.TuningMarker
if ($script:TuningMarkerPresent) { Write-ConsoleLog ('  tuning: the marker of an Apply is there: {0}' -f $script:Paths.TuningMarker) }
$script:PreflightValue = Get-SimRigPreflightValue -KnownGood $script:KnownGood -Support $script:TuningSupport `
    -Rule @($script:RuleDocument) -RigProfile $script:RigProfile -Machine $script:Machine

# The Tools card (spec 11b). Read once at load, like the machine profile: the
# card is on the My PC screen and a re-read on every screen change would walk the
# Uninstall hive for no reason.
$script:Tools = @()
# Assign, then wrap: Get-SimRigToolReading returns the comma form, and wrapping the
# call left the Tools card with one row that was the whole inventory.
try { $toolRows = Get-SimRigToolReading; $script:Tools = @($toolRows) }
catch { Write-ConsoleLog ('[WARN] tool inventory unreadable: {0}' -f $_.Exception.Message) }

# Two paths that used to ship as values in files every user gets: the iRacing ini
# folder (in known-good.psd1, with the author's Windows user name in it) and the NAS
# share (this script's own default). Rick's decisions, 2026-09-27. Both are facts
# about one PC, so both come from the active profile, with discovery's reading as the
# fallback for a machine that has no profile of its own. Nothing here invents a path:
# unset stays unset, and each feature that needs one says so rather than guessing.
# Both sources are asked, every start. The profile wins - it is a value a person
# checked, and a discovery reader that picked the wrong candidate would silently grade
# the wrong file. The compare is logged anyway, because a written-down path goes stale
# the moment the folder moves, and because this is how we learn whether discovery finds
# an OneDrive-redirected Documents folder on a rig that has one (Rick's choice,
# 2026-09-27).
$script:IniDirChoice = Get-SimRigIniDirChoice `
    -FromProfile ([string](Get-KnownGoodField -Entry $script:RigProfile -Name 'IniDir')) `
    -Discovered ([string](Get-KnownGoodField -Entry (Get-KnownGoodField -Entry $script:Machine -Name 'IRacing') -Name 'IniDir'))
$script:IniDir = [string]$script:IniDirChoice.Path
Write-ConsoleLog ('ini folder: {0} (from {1}). {2}' -f `
        $(if ($script:IniDir) { $script:IniDir } else { 'none' }), $script:IniDirChoice.Source, $script:IniDirChoice.Note)
if ($script:IniDirChoice.Mismatch) { Write-ConsoleLog ('[WARN] ini folder mismatch. {0}' -f $script:IniDirChoice.Note) }
# One seam for both callers: the self-test asks the same function, so the console and
# the self-test cannot disagree about where a report goes.
$script:ShareChoice = Get-SimRigShareRoot -Given $NasRoot -RigProfile $script:RigProfile
$script:NasRoot = [string]$script:ShareChoice.Path
Write-ConsoleLog ('share: {0} (from the {1})' -f `
        $(if ($script:NasRoot) { $script:NasRoot } else { 'none set' }), $script:ShareChoice.Source.ToLowerInvariant())

$script:Items = Select-QuietItemForMachine -QuietItem $script:AllItems -Machine $script:Machine
Write-ConsoleLog ('v4.2 load: {0} rule file(s), profile {1}, {2} of {3} quiet items apply, machine reads unavailable: {4}' -f `
    @($ruleLoad.Path).Count,
    $(if ($null -ne $script:RigProfile) { $script:RigProfile.Id } else { 'none' }),
    @($script:Items).Count, @($script:AllItems).Count,
    $(if (@($script:MachineReading.Unavailable).Count -gt 0) { @($script:MachineReading.Unavailable) -join ', ' } else { 'none' }))
foreach ($machineNote in @($script:MachineReading.Note)) { Write-ConsoleLog ('  discovery: {0}' -f $machineNote) }
$script:StartupMark['Loaded'] = Get-Date

$window = Initialize-ConsoleView -Xaml $script:ConsoleXaml
$script:StartupMark['WindowBuilt'] = Get-Date
Show-HeaderMeta -Rig $env:COMPUTERNAME -Session '-'

$script:View['BtnRecheck'].Add_Click({ Invoke-UiSafe -What 'Re-check' -Action { Invoke-PreflightRun } })
$script:View['BtnConfirmDisplayLayout'].Add_Click({ Invoke-UiSafe -What 'Confirm display layout' -Action { Invoke-ConfirmDisplayLayout } })

# The Tools card's Install buttons live inside a DataTemplate, so they have no
# name to bind to here. The click bubbles to the list, and the sender's Tag
# carries that row's winget id (A-TOOL-02).
function Invoke-ToolListClick {
    <#
        The bubbled handler for the Tools card. A RoutedEventHandler is handed the
        list it is attached to and the event; only the event is needed, because the
        row's own button carries the id.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'EventSender',
        Justification = 'RoutedEventHandler fixes the signature: the sender is the list, and the id comes from the clicked button in the event args OriginalSource.')]
    [CmdletBinding()]
    # Not $EventArgs: that is an automatic variable. Sixth name collision of this
    # build - $matches, $profile, $args and now this.
    param($EventSender, $RoutedArgs)

    $packageId = [string]$RoutedArgs.OriginalSource.Tag
    Invoke-UiSafe -What 'Install tool' -Action { Invoke-ToolInstall -PackageId $packageId }
}

$script:View['ToolsList'].AddHandler(
    [System.Windows.Controls.Button]::ClickEvent,
    [System.Windows.RoutedEventHandler] ${function:Invoke-ToolListClick})

# --------------------------------------------------------------------------
# v4.2 screens. The view builds them and holds every caption (G-19); the
# controller decides when they show and what rows go in them. Each Show-* call
# takes rows a pure engine function produced, so nothing here formats a value.
# --------------------------------------------------------------------------
function Show-MyPcScreen {
    Show-Screen -Name 'ScreenMyPc'
    # 'Windows' is not one of the cards the view has, and passing it threw on the
    # ValidateSet - so opening this screen failed with a banner and showed nothing.
    # The Windows facts are graded on the Gaps screen, which is where they belong;
    # what was missing here was a card, not the data. Screens.Tests.ps1 now checks
    # that every name this loop passes is one the view accepts.
    foreach ($card in @('Cpu', 'Gpu', 'Display', 'IRacing')) {
        $block = Get-KnownGoodField -Entry $script:Machine -Name $card
        Show-MyPcCard -Card $card -Row (ConvertTo-MachineCardRow -Block $block -Confidence $script:Machine.Confidence -ConfidenceReason $script:Machine.ConfidenceReason)
    }
    Show-MyPcCard -Card 'Peripherals' -Row (ConvertTo-PeripheralCardRow -Machine $script:Machine)
    Show-ToolsList -Row (ConvertTo-ToolViewRow -Tool $script:Tools)
    # The trace card's state depends on whether a session is open, which changes
    # while this screen is not on show.
    Update-HardFaultTraceCard
}

function Invoke-ToolInstall {
    <#
        A-TOOL-02. The Tools card's Install button. The winget id comes from the
        clicked button's Tag, which ConvertTo-ToolViewRow put there, and the
        argument list from Get-SimRigWingetArgument - the one place in this build
        that decides what winget is passed. Nothing is added, so the user sees and
        accepts whatever winget asks.

        Nothing runs until a click: this function is only ever reached from the
        handler below.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowNull()] [string] $PackageId)

    if ([string]::IsNullOrWhiteSpace($PackageId)) {
        Write-ConsoleLog '[WARN] Install clicked with no winget id - nothing run'
        return
    }
    $argument = Get-SimRigWingetArgument -PackageId $PackageId
    Write-ConsoleLog ('tool install: {0}' -f (Get-SimRigWingetCommandLine -PackageId $PackageId))
    Start-Process -FilePath 'winget' -ArgumentList $argument
}

function Invoke-ConfirmDisplayLayout {
    <#
        Spec 11a. The layout on the My PC card is an inference - Surround cannot be
        told apart from one wide monitor without an EDID count that is not always
        readable, and Get-SimRigDisplayLayout says so in its own Reason. This button
        is the user settling it: the answer is written to settings, discovery is read
        again with it, and the rules then grade against what the user said rather than
        against a guess.

        It confirms what is on screen. Correcting a layout the app read wrongly needs
        a picker, which is the settings screen and is not built yet - so a wrong
        reading is still wrong after this, and the button does not pretend otherwise.
    #>
    [CmdletBinding()]
    param()
    if ($script:S.Busy) { return }

    $layout = [string](Get-KnownGoodField -Entry (Get-KnownGoodField -Entry $script:Machine -Name 'Display') -Name 'Layout')
    if ($layout -notin @('Single', 'Multi', 'Surround')) {
        Show-Banner -Kind Warn -Title (Get-SimRigString -Key 'MyPc_ConfirmDisplayNoneTitle') `
            -Text (Get-SimRigString -Key 'MyPc_ConfirmDisplayNoneText')
        return
    }

    $updated = Set-SimRigSettingsDisplayLayout -Settings $script:Settings -Layout $layout -ConfirmedAt (Get-Date)
    try {
        [void](Save-SimRigSettingsFile -Path $script:Paths.Settings -Settings $updated)
    }
    catch {
        Show-SimRigFailure -What 'Confirm display layout' -Message $_.Exception.Message -Detail $_.ScriptStackTrace `
            -Line $_.InvocationInfo.ScriptLineNumber
        return
    }
    $script:Settings = $updated
    Write-ConsoleLog ('display layout confirmed as {0}' -f $layout)

    # Read again with the confirmation in hand, so every screen and every rule sees
    # the same answer. Without this the card would say confirmed and the grading
    # would still be using the inference.
    $script:MachineReading = Get-SimRigMachineReading -ProfileValues (Get-KnownGoodField -Entry $script:RigProfile -Name 'Values') -Settings $script:Settings
    $script:Machine = Build-MachineProfile -TakenAt (Get-Date) -MachineName $env:COMPUTERNAME `
        -Cpu $script:MachineReading.Cpu -CpuSteering $script:MachineReading.CpuSteering `
        -Gpu $script:MachineReading.Gpu -Windows $script:MachineReading.Windows `
        -Display $script:MachineReading.Display -IRacing $script:MachineReading.IRacing `
        -ProfileId $(if ($null -ne $script:RigProfile) { [string]$script:RigProfile.Id } else { $null }) `
        -NetworkAdapter $script:MachineReading.NetworkAdapter -BluetoothConnected $script:MachineReading.BluetoothConnected `
        -DefenderOptIn $(if ($null -ne $script:RigProfile) { Get-KnownGoodField -Entry (Get-KnownGoodField -Entry $script:RigProfile -Name 'Values') -Name 'DefenderOptIn' } else { $null }) `
        -Confidence $script:MachineReading.Confidence -ConfidenceReason $script:MachineReading.ConfidenceReason

    Show-Banner -Kind Ok -Title (Get-SimRigString -Key 'MyPc_ConfirmDisplayDoneTitle') `
        -Text ((Get-SimRigString -Key 'MyPc_ConfirmDisplayDoneText') -f $layout)
    Show-MyPcScreen
}

function Invoke-UninstallFlow {
    <#
        Spec 16. Two things this app does can outlive it: a quiet session and applied
        persistent tuning. Each one stops the uninstall and names the button to press
        first, and the dialog is not shown at all - a confirmation for something that
        cannot proceed teaches people to click through confirmations.

        The removal itself belongs to Setup.cmd, which already does it elevated and is
        tested (U3.11). Re-implementing it here would give this build two answers to
        "what does uninstall remove".
    #>
    [CmdletBinding()]
    param()
    if ($script:S.Busy) { return }

    $sessionActive = $false
    try { $sessionActive = Test-Path -LiteralPath $script:Paths.ActiveMarker } catch { $sessionActive = $false }
    # Push 2 of the unit tune, step 7: the marker, not each tuning-snapshot.json under the sessions
    # folder. A green Undo removes the marker and keeps the snapshot, so the old test blocked the
    # uninstall after each Undo (the Cowork answer to the texts of push 2, answer 5).
    $tuningApplied = $false
    try { $tuningApplied = Test-Path -LiteralPath $script:Paths.TuningMarker } catch { $tuningApplied = $false }

    $readiness = Get-SimRigUninstallReadiness -IsSessionActive $sessionActive -IsTuningApplied $tuningApplied
    if (-not $readiness.Ready) {
        Show-Banner -Kind Warn -Title (Get-SimRigString -Key 'Uninstall_BlockedTitle') -Text $readiness.Reason
        if ($readiness.OfferRestore) { Show-ButtonSet -Mode RestoredRed }
        Write-ConsoleLog ('uninstall refused: {0}' -f $readiness.Reason)
        return
    }
    Show-UninstallDialog -Visible $true
}

function Invoke-UninstallConfirmed {
    <#
        Starts Setup.cmd /uninstall elevated and closes the window. The window has to
        go: the program folder is about to be removed from under it, and a console
        still running from a folder that no longer exists is how a confusing error
        report gets written.
    #>
    [CmdletBinding()]
    param()
    Show-UninstallDialog -Visible $false

    $setup = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Setup.cmd'
    if (-not (Test-Path -LiteralPath $setup)) {
        $setup = Join-Path -Path $PSScriptRoot -ChildPath 'Setup.cmd'
    }
    if (-not (Test-Path -LiteralPath $setup)) {
        Show-Banner -Kind Bad -Title (Get-SimRigString -Key 'Uninstall_NoSetupTitle') -Text (Get-SimRigString -Key 'Uninstall_NoSetupText')
        Write-ConsoleLog '[WARN] uninstall: Setup.cmd not found beside the app'
        return
    }

    Write-ConsoleLog ('uninstall: starting {0} /uninstall' -f $setup)
    Show-Banner -Kind Ok -Title (Get-SimRigString -Key 'Uninstall_StartedTitle') -Text (Get-SimRigString -Key 'Uninstall_StartedText')
    Start-Process -FilePath $setup -ArgumentList '/uninstall' -Verb RunAs
    # $window is the script-scope variable Initialize-ConsoleView returned; this
    # function only ever runs from a click, long after it is assigned.
    $window.Close()
}

function Show-GapsScreen {
    Show-Screen -Name 'ScreenGaps'
    $rows = Get-RuleCheck -Rule $script:RuleDocument -RigProfile $script:RigProfile `
        -Fact $script:S.Fact -Machine $script:Machine -QuietItem $script:Items
    Show-GapsList -Row (ConvertTo-PreflightViewRow -Check $rows)
}

function Show-ScoreScreen {
    Show-Screen -Name 'ScreenScore'
    # $script:Score is filled by the capture flow and is absent until a capture has
    # been read. ConvertTo-ScoreViewRow turns $null into a row that says "no capture
    # yet" rather than an empty card, because a blank card reads as a score of zero.
    $score = if (Get-Variable -Name 'Score' -Scope Script -ErrorAction SilentlyContinue) { $script:Score } else { $null }
    foreach ($side in @('Before', 'After')) {
        Show-ScoreCard -Side $side -Row (ConvertTo-ScoreViewRow -Score (Get-KnownGoodField -Entry $score -Name $side))
    }
}

function Get-CurrentRigReport {
    <#
        .SYNOPSIS
        The rig report document: what the Share screen shows, what Save report
        writes, and what the gate reads.

        .DESCRIPTION
        One function for all three, so the file cannot differ from the preview. The
        screen's promise is 'this is exactly what would be shared', and two call
        sites building the report separately is how that promise quietly stops being
        true.

        Every call here was wrong until 2026-09-28: -Machine on Get-ShareDenyList,
        which has no such parameter and requires -Salt; -Score and -Salt on
        Build-RigReport, which has neither and requires -AppVersion; and
        Get-RigReportString, which flattens a document into strings for the gate and
        is not the json writer. The Share screen threw on all four. A-LINT-08 now
        reads every call in the app against the function it names.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $salt = Get-ShareSalt
    $denyArgument = Get-ShareDenyArgument -Salt $salt -Reading (Get-SimRigShareDenyReading) `
        -Machine $script:Machine -SharePath @($script:NasRoot)
    $deny = Get-ShareDenyList @denyArgument

    # $script:Score is absent until a capture has been read, and a report without a
    # score is a valid report: the gap table is the part the forum asks for.
    $score = if (Get-Variable -Name 'Score' -Scope Script -ErrorAction SilentlyContinue) { $script:Score } else { $null }

    return (Build-RigReport -Machine $script:Machine -Gap $script:S.Check `
            -ScoreBefore (Get-KnownGoodField -Entry $score -Name 'Before') `
            -ScoreAfter (Get-KnownGoodField -Entry $score -Name 'After') `
            -AppVersion (Get-InstalledVersion) `
            -ProfileId $(if ($null -ne $script:RigProfile) { [string]$script:RigProfile.Id } else { '' }) `
            -RuleVersion $script:RuleVersion -Deny $deny -TakenAt (Get-Date) `
            -Rule $script:RuleDocument)
}

function Get-CurrentRigReportString {
    <#
        .SYNOPSIS
        That same report as the json text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (ConvertTo-RigReportJson -Report (Get-CurrentRigReport))
}

function Show-ShareScreen {
    Show-Screen -Name 'ScreenShare'
    Show-SharePreview -Json (Get-CurrentRigReportString)
}

function Invoke-SaveRigReport {
    <#
        .SYNOPSIS
        Writes the rig report next to the results, and says where it went.

        .DESCRIPTION
        The Save report button was on screen and wired to nothing. It saves the same
        JSON the preview showed - byte for byte, because both ask
        Get-CurrentRigReport - and it sends nothing anywhere. Sharing is the
        separate button that opens GitHub.

        It writes with Export-RigReportFile, which runs Test-RigReport first and
        writes nothing when the report does not pass. Writing the text straight to
        the path skipped the last gate before a file leaves the PC, which is what
        flag 8 is.
    #>
    [CmdletBinding()]
    param()

    $name = 'rig-report-{0}.json' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    $path = Join-Path -Path $script:Paths.Results -ChildPath $name
    $written = Export-RigReportFile -Report (Get-CurrentRigReport) -Path $path
    Write-ConsoleLog ('rig report -> {0}' -f $written)
    Show-Banner -Kind Info -Title 'Report saved' -Text $written
}

function Open-SessionFolder {
    <#
        .SYNOPSIS
        Opens the sessions folder in Explorer.

        .DESCRIPTION
        The My PC button that did nothing. It opens the folder the sessions are
        written to, which is the one the user is looking for when a capture is
        missing.
    #>
    [CmdletBinding()]
    param()

    $folder = $script:Paths.Sessions
    if (-not (Test-Path -LiteralPath $folder)) {
        Write-ConsoleLog ('[WARN] sessions folder not there yet: {0}' -f $folder)
        return
    }
    [void](Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder) -PassThru)
}

function Show-AboutScreen {
    Show-Screen -Name 'ScreenAbout'
    # The version and commit come from VERSIONS.md through the preflight fact, the
    # same place the Push report reads them, rather than a constant in here that
    # would drift from the file the integrity check compares against.
    $versions = Get-VersionsHeader -Text $(if ($script:S.Fact) { $script:S.Fact.VersionsText } else { $null })
    $integrity = @(if ($script:S.Fact) { $script:S.Fact.ScriptIntegrity } else { @() })
    # -UpdateStatus is mandatory on Show-AboutInfo and was not being passed: the About
    # screen threw every time it opened. Six chains in this build were written, tested
    # and wired to nothing or wired wrong; this was the seventh. The test below the fix
    # is the one that matters - it opens the screen rather than checking the function.
    Show-AboutInfo -Version $(if ($versions.Version) { $versions.Version } else { 'unknown' }) `
        -Commit $(if ($versions.Commit) { $versions.Commit } else { 'unknown' }) `
        -Hash $(if ($integrity.Count -gt 0) { 'checked' } else { 'not checked' }) `
        -UpdateStatus (Get-UpdateStatusText)
}

function Get-InstalledVersion {
    <#
        .SYNOPSIS
        The version this build says it is, or 'unknown'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $versions = Get-VersionsHeader -Text $(if ($script:S.Fact) { $script:S.Fact.VersionsText } else { $null })
    if ($versions.Version) { return [string]$versions.Version }
    return 'unknown'
}

function Get-UpdateStatusText {
    <#
        .SYNOPSIS
        The About screen's update line: the last check's answer, or an invitation to
        run one.

        .DESCRIPTION
        Opening About does not fetch anything. The check is a button, so the only
        outbound request this app makes on its own is one the user pressed - and when
        the setting is off, the line says so and no check is offered as pending.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $enabled = $true
    if ($null -ne $script:Settings) { $enabled = [bool]$script:Settings.UpdateCheck }
    if (-not $enabled) { return (Get-SimRigString -Key 'About_UpdateOff') }
    if ($null -eq $script:S.UpdateVerdict) { return (Get-SimRigString -Key 'About_UpdateNotChecked') }
    return (Get-UpdateVerdictText -Verdict $script:S.UpdateVerdict)
}

function Get-UpdateVerdictText {
    <#
        .SYNOPSIS
        One update verdict as the sentence the user reads.

        .DESCRIPTION
        The engine returns a string key and the values it formats (G-19: no
        user-visible literal outside SimRig.Strings.ps1). This joins the two, and
        nothing else in the app formats an update sentence.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Verdict)

    $text = Get-SimRigString -Key ([string]$Verdict.StringKey)
    $detail = @($Verdict.Detail)
    if ($detail.Count -eq 0) { return $text }
    return ($text -f $detail)
}

function Invoke-CheckUpdate {
    <#
        .SYNOPSIS
        Checks the advisories list and shows what it says.

        .DESCRIPTION
        Note only (flag 16): this never downloads a build and never installs one. A
        pulled version is the case that matters, and it outranks 'you are up to
        date' - being on the newest build is no comfort if the newest build is the
        one that was pulled.
    #>
    [CmdletBinding()]
    param()

    $enabled = $true
    if ($null -ne $script:Settings) { $enabled = [bool]$script:Settings.UpdateCheck }
    if (-not $enabled) {
        # The setting is off, so nothing is fetched. The verdict function says the
        # same thing, and it is asked rather than assumed.
        $script:S.UpdateVerdict = Get-SimRigUpdateVerdict -Installed (Get-InstalledVersion) -Document $null -CheckEnabled $false
        Show-AboutScreen
        return
    }

    Show-AboutInfoUpdateStatus -Text (Get-SimRigString -Key 'About_UpdateChecking')
    $document = Get-SimRigAdvisoryDocument
    $script:S.UpdateVerdict = Get-SimRigUpdateVerdict -Installed (Get-InstalledVersion) -Document $document -CheckEnabled $true
    Write-ConsoleLog ('update check: {0} ({1})' -f $script:S.UpdateVerdict.Status, $script:S.UpdateVerdict.Confidence)
    Show-AboutInfoUpdateStatus -Text (Get-UpdateVerdictText -Verdict $script:S.UpdateVerdict)
}

function Update-HardFaultTraceCard {
    <# The card's two lines and its button label, from one place. #>
    [CmdletBinding()]
    param()
    if (-not $script:View.ContainsKey('BtnHardFaultTrace')) { return }
    $running = [bool]$script:S.TraceRunning
    $script:View['BtnHardFaultTrace'].Content = Get-SimRigString -Key $(if ($running) { 'MyPc_HardFaultStop' } else { 'MyPc_HardFaultStart' })
    $state = if ($running) { 'MyPc_HardFaultRunning' } elseif (-not $script:S.SessionDir) { 'MyPc_HardFaultNoSession' } else { 'MyPc_HardFaultIdle' }
    $script:View['TxtHardFaultTraceState'].Text = Get-SimRigString -Key $state
    $script:View['BtnHardFaultTrace'].IsEnabled = ($running -or [bool]$script:S.SessionDir)
}

function Invoke-HardFaultTrace {
    <#
        One button, two states. Start before the stint, stop after it.

        The console never decides to steal the kernel logger: the elevated child
        refuses when something else holds it and says so, and that refusal lands
        here as a banner rather than as a silent failure. That is the 2026-09-27
        lesson - a trace that looks started and is not costs a whole stint.
    #>
    [CmdletBinding()]
    param()
    if ($script:S.Busy) { return }
    if (-not $script:S.SessionDir) {
        Show-Banner -Kind Warn -Title 'No session yet' -Text (Get-SimRigString -Key 'MyPc_HardFaultNoSession')
        return
    }
    $operation = if ($script:S.TraceRunning) { 'TraceStop' } else { 'TraceStart' }
    Invoke-ElevatedStep -Operation $operation -SessionDir $script:S.SessionDir -ModeOnCancel $script:S.PreMode -OnDone {
        param($result)
        Complete-HardFaultTrace -Result $result
    }
}

function Complete-HardFaultTrace {
    <# Reads the child's result and says, in one line, what happened. #>
    [CmdletBinding()]
    param([AllowNull()] [object] $Result)
    $operation = if ($null -ne $Result) { [string]$Result.Operation } else { '' }
    $ok = ($null -ne $Result -and $Result.Ok)
    $why = if ($null -ne $Result -and @($Result.Errors).Count -gt 0) { @($Result.Errors)[0] } else { $null }

    if ($operation -eq 'TraceStart') {
        $script:S.TraceRunning = $ok
        if ($ok) { Show-Banner -Kind Ok -Title 'Trace running' -Text (Get-SimRigString -Key 'MyPc_HardFaultRunning') }
        else { Show-Banner -Kind Warn -Title 'Trace not started' -Text $(if ($why) { $why } else { 'The trace did not start.' }) }
    }
    else {
        $script:S.TraceRunning = $false
        $report = $null
        $path = Join-Path -Path $script:S.SessionDir -ChildPath 'hardfaults.json'
        if (Test-Path -LiteralPath $path) {
            try { $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $report = $null }
        }
        if ($null -ne $report -and $report.IsValid) {
            $worst = if (@($report.ByProcess).Count -gt 0) { @($report.ByProcess)[0].Process } else { $null }
            $text = if ([int64]$report.TotalHardFaults -eq 0) {
                Get-SimRigString -Key 'MyPc_HardFaultNone'
            }
            else {
                (Get-SimRigString -Key 'MyPc_HardFaultDone') -f $report.TotalHardFaults, $(if ($worst) { $worst } else { 'this session' })
            }
            Show-Banner -Kind Ok -Title 'Trace read' -Text $text
        }
        else {
            Show-Banner -Kind Warn -Title 'Trace not read' -Text $(if ($why) { $why } else { 'The trace stopped but could not be read.' })
        }
    }
    Update-HardFaultTraceCard
}

# Continue closes the first-run card and shows what is underneath it. It used to
# call Show-Screen -Name 'ScreenMain', and ScreenMain is not one of the six screens
# that function takes - the ValidateSet refused it, so the click threw into
# Invoke-UiSafe and the card stayed where it was. Hide-V42Screen is the honest verb
# for what the button does. Reaching the six screens is a v4.3 item (C1); this adds
# no way in and takes none away.
$script:View['BtnFirstRunContinue'].Add_Click({ Invoke-UiSafe -What 'First run continue' -Action { Hide-V42Screen } })
$script:View['BtnExportGaps'].Add_Click({ Invoke-UiSafe -What 'Export gaps' -Action { Show-ShareScreen } })
$script:View['BtnCheckUpdate'].Add_Click({ Invoke-UiSafe -What 'Check for updates' -Action { Invoke-CheckUpdate } })
$script:View['BtnSaveReport'].Add_Click({ Invoke-UiSafe -What 'Save report' -Action { Invoke-SaveRigReport } })
$script:View['BtnFirstRunDryRun'].Add_Click({ Invoke-UiSafe -What 'Dry run (first run)' -Action { Invoke-DryRun } })
$script:View['BtnOpenSessionFolder'].Add_Click({ Invoke-UiSafe -What 'Open sessions folder' -Action { Open-SessionFolder } })
$script:View['BtnHardFaultTrace'].Add_Click({ Invoke-UiSafe -What 'Hard-fault trace' -Action { Invoke-HardFaultTrace } })
$script:View['BtnUninstall'].Add_Click({ Invoke-UiSafe -What 'Uninstall' -Action { Invoke-UninstallFlow } })
$script:View['BtnUninstallConfirm'].Add_Click({ Invoke-UiSafe -What 'Uninstall (confirmed)' -Action { Invoke-UninstallConfirmed } })
$script:View['BtnUninstallCancel'].Add_Click({ Invoke-UiSafe -What 'Cancel uninstall' -Action { Show-UninstallDialog -Visible $false } })
$script:View['BtnStart'].Add_Click({ Invoke-UiSafe -What 'Start' -Action { Invoke-StartSession } })
$script:View['BtnStartTools'].Add_Click({ Invoke-UiSafe -What 'Start with capture tools' -Action { Invoke-StartSession -Mode Tools } })
$script:View['BtnStartAnyway'].Add_Click({ Invoke-UiSafe -What 'Start anyway' -Action { Invoke-StartSession -Anyway } })
$script:View['BtnStartAnywayTools'].Add_Click({ Invoke-UiSafe -What 'Start anyway with capture tools' -Action { Invoke-StartSession -Anyway -Mode Tools } })
$script:View['BtnFixGpu'].Add_Click({ Invoke-UiSafe -What 'Fix GPU steering' -Action { Invoke-FixGpu } })
$script:View['BtnApplyTuning'].Add_Click({ Invoke-UiSafe -What 'Apply tuning' -Action { Invoke-ApplyTuningFlow } })
$script:View['BtnUndoTuning'].Add_Click({ Invoke-UiSafe -What 'Undo tuning' -Action { Invoke-UndoTuningFlow } })
# One dialog, two flows. The Apply button asks which one put it on screen rather
# than assuming, because a button wired to the wrong flow would apply something the
# user was not shown.
$script:View['BtnTuningConfirmApply'].Add_Click({ Invoke-UiSafe -What 'Apply (confirmed)' -Action {
            $pending = $script:S.PendingConfirm
            $script:S.PendingConfirm = $null
            if ($pending -eq 'FixGpu') { Invoke-FixGpu -Confirmed }
            # Step 7b: the first ask of Apply tuning (the tick list), then the second ask.
            elseif ($pending -eq 'TuningTick') { Invoke-ApplyTuningFlow -Ticked }
            elseif ($pending -eq 'ApplyTuning') { Invoke-ApplyTuningFlow -Confirmed }
            else { Show-TuningConfirm -Visible $false }
        } })
$script:View['BtnTuningConfirmCancel'].Add_Click({ Invoke-UiSafe -What 'Cancel' -Action {
            $script:S.PendingConfirm = $null
            $script:S.TuningTicked = $null
            Show-TuningConfirm -Visible $false
        } })
$script:View['BtnDryRun'].Add_Click({ Invoke-UiSafe -What 'Dry run' -Action { Invoke-DryRun } })
$script:View['BtnEndSession'].Add_Click({ Invoke-UiSafe -What 'End session' -Action { Stop-RaceWatch } })
$script:View['BtnRestore'].Add_Click({ Invoke-UiSafe -What 'Restore' -Action { Invoke-RestoreRun -Operation Restore } })
$script:View['BtnUndo'].Add_Click({ Invoke-UiSafe -What 'Undo' -Action { Invoke-RestoreRun -Operation Undo } })
$script:View['BtnFix'].Add_Click({
        Invoke-UiSafe -What 'Fix' -Action {
            [string[]]$ids = Get-FailedVerdictId -Verdict $script:S.Verdict
            if ($ids.Count -gt 0) { Invoke-RestoreRun -Operation Fix -OnlyId $ids } else { Invoke-RestoreRun -Operation Restore }
        }
    })
$script:View['BtnPush'].Add_Click({ Invoke-UiSafe -What 'Push' -Action { Invoke-Push } })
$script:View['BtnSaveLatencyMon'].Add_Click({ Invoke-UiSafe -What 'Save LatencyMon report' -Action { Invoke-LatencyMonSave } })
$script:View['BtnOpenFolder'].Add_Click({ Invoke-UiSafe -What 'Open folder' -Action { $f = if ($script:S.PushedTo) { $script:S.PushedTo } else { $script:S.SessionDir }; if ($f) { [void](Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $f) -PassThru) } } })
$script:View['BtnOpenReport'].Add_Click({ Invoke-UiSafe -What 'Open report' -Action { if ($script:S.SessionDir) { [void](Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f (Join-Path $script:S.SessionDir 'v4-report.json')) -PassThru) } } })
$script:View['BtnOpenLog'].Add_Click({ Invoke-UiSafe -What 'Open log' -Action { [void](Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:LogPath) -PassThru) } })

$window.Add_Closing({
        param($source, $e)
        [void]$source
        if ($null -ne $script:S.WatchTimer -and $script:S.WatchTimer.IsEnabled) {
            $answer = [System.Windows.MessageBox]::Show('Race watch is running and Windows is still quiet. Close anyway? The deadman task restores Windows at your next sign-in.', 'SimRig Console', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { $e.Cancel = $true; return }
        }
        Write-ConsoleLog 'console closed'
    })

Invoke-UiSafe -What 'Startup' -Action {
    if ($dataErrors.Count -gt 0) {
        Show-Heading -Title 'Data files invalid' -Subtitle 'quiet-list.psd1 or known-good.psd1 did not pass validation.'
        Show-Banner -Kind Bad -Title 'Cannot start' -Text ($dataErrors -join '; ')
        Show-ButtonSet -Mode Busy
        return
    }
    $marker = Read-SimRigJson -Path $script:Paths.ActiveMarker
    if ($null -ne $marker) {
        # A session was quieted and never restored (crash, power cut, closed window).
        $script:S.SessionDir = $marker.SessionDir
        $script:S.Stamp = $marker.SessionId
        Show-Heading -Title 'Unfinished session' -Subtitle ('Session {0} was quieted at {1} and never restored.' -f $marker.SessionId, $marker.QuietAt)
        Show-Banner -Kind Warn -Title 'Windows is still quiet' -Text 'Restore puts every item back from the snapshot. Undo does the same. Nothing else can start until it is restored.'
        foreach ($n in 1..3) { Show-StepState -Step $n -State Done -Text '' }
        Show-StepState -Step 4 -State Current -Text 'needed'
        Show-ButtonSet -Mode RestoredRed
        return
    }
}

# The window shows first; the preflight reads start once it is on screen.
$window.Add_ContentRendered({
        Invoke-UiSafe -What 'Startup' -Action {
            if ($script:StartupMark.Contains('WindowShown')) { return }
            $script:StartupMark['WindowShown'] = Get-Date
            if ($dataErrors.Count -gt 0 -or $null -ne (Read-SimRigJson -Path $script:Paths.ActiveMarker)) {
                if ($StartupReport) { Complete-Startup }
                return
            }
            Invoke-PreflightRun
        }
    })

# The last net (spec 16). A handler that Invoke-UiSafe does not wrap - a binding
# failure, a WPF callback, a timer added later - would otherwise take the window
# down with a raw trace. This catches it, says what happened in one sentence, and
# keeps the window up so Restore and Undo are still reachable.
function Invoke-DispatcherFailure {
    <# The dispatcher's handler signature is fixed; only the event carries anything. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'EventSender',
        Justification = 'DispatcherUnhandledExceptionEventHandler fixes the signature: the sender is the dispatcher and everything needed is on the event.')]
    [CmdletBinding()]
    param($EventSender, $RoutedArgs)

    try {
        # A .NET exception here, not a PowerShell error record: take the message and
        # the .NET stack, which is the same shape the log wants.
        Show-SimRigFailure -What 'The app' -Message $RoutedArgs.Exception.Message `
            -Detail $RoutedArgs.Exception.StackTrace -Line $null
    }
    catch {
        # Never let the last net throw: that is the crash it exists to prevent.
        Write-ConsoleLog ('[FAIL] unhandled: {0}' -f $RoutedArgs.Exception.Message)
    }
    $RoutedArgs.Handled = $true
}

$window.Dispatcher.Add_UnhandledException(${function:Invoke-DispatcherFailure})

[void]$window.ShowDialog()
