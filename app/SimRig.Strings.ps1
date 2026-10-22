#requires -Version 7.0
<#
    SimRig.Strings.ps1

    Every user-visible string shown by SimRigConsole.View.ps1, in one file
    (requirement G-19). No string literal shown to a person may stay in
    the view or the controller - both look up their text here by key, so
    a later version can translate the app by replacing this one file.

    $script:SimRigStrings is a flat hashtable: Key (string) -> Text
    (string). Get-SimRigString resolves a key and never throws: a
    missing key logs to the verbose stream and returns the key itself,
    so a screen never shows a blank space when a key is misspelled.
#>

Set-StrictMode -Version 3.0

$script:SimRigStrings = @{

    # -- First run ----------------------------------------------------
    FirstRun_Title           = 'Welcome to SimRig Console'
    FirstRun_ChangesHeading  = 'What this app changes'
    # Text 1 of PUSH2-TEXTS-FOR-RICK-2026-10-03.md (Rick's "Yes"). On the rig, Initialize-ScreenText adds text 7.
    FirstRun_ChangesBody     = 'With your OK, it can turn off Multiplane Overlay and hardware-accelerated GPU scheduling (HAGS), and in one case change the power plan. It saves the old values first, and Undo tuning puts them back. On a PC that this version does not support, it changes no tuning settings.'
    FirstRun_NeverHeading    = 'What this app never does'
    FirstRun_NeverBody       = 'It never runs a fix without asking first. It never deletes a race session. It never sends anything off this PC unless you choose to share a report.'
    FirstRun_SessionFolder   = 'Your sessions save to:'
    FirstRun_ChangeFolder    = 'Change folder'
    FirstRun_DryRun          = 'Dry run (no changes)'
    FirstRun_Guide           = 'Open the guide'
    FirstRun_Continue        = 'Continue'

    # -- My PC ----------------------------------------------------------
    MyPc_Title               = 'My PC'
    MyPc_CpuCardTitle        = 'CPU'
    MyPc_GpuCardTitle        = 'GPU'
    MyPc_DisplayCardTitle    = 'Displays'
    MyPc_IracingCardTitle    = 'iRacing'
    MyPc_PeripheralsTitle    = 'Peripherals'
    MyPc_ConfirmDisplayLabel = 'Confirm display layout'
    # The layout on the card is an inference. These say what confirming it does, and
    # what it cannot do - correcting a wrong reading needs a picker that is not built.
    MyPc_ConfirmDisplayDoneTitle = 'Display layout confirmed'
    MyPc_ConfirmDisplayDoneText  = 'Saved as {0}. The gap table now grades against your answer instead of what this app worked out on its own. If that is not your layout, the app cannot be corrected here yet - tell Claude.'
    MyPc_ConfirmDisplayNoneTitle = 'Nothing to confirm'
    MyPc_ConfirmDisplayNoneText  = 'No display layout was read, so there is nothing to confirm yet. The Gaps screen says why it could not be read.'
    MyPc_ToolsCardTitle      = 'Tools'
    MyPc_InstallTool         = 'Install'
    MyPc_SessionSizeWarn     = 'Your session folder is large. Nothing is deleted automatically.'
    MyPc_OpenSessionFolder   = 'Open session folder'
    Session_Racing           = 'racing'
    Session_WaitingForSim    = 'waiting for iRacing'
    Session_BetweenSessions  = 'between sessions - still quiet'
    Session_Ending           = 'iRacing closed - finishing up'
    Session_Ended            = 'finished'
    MyPc_HardFaultTitle      = 'Hard-fault trace'
    MyPc_HardFaultStart      = 'Start hard-fault trace'
    MyPc_HardFaultStop       = 'Stop the trace and read it'
    MyPc_HardFaultIdle       = 'Records which programs wait on the disk while you drive. Start it before you go out, stop it when you come in. It writes to the session folder as it goes, so an interrupted trace still keeps what it had.'
    MyPc_HardFaultRunning    = 'Recording. Drive your stint, then come back and stop it.'
    MyPc_HardFaultNoSession  = 'Start a session first - the trace is saved with the session it covers.'
    MyPc_HardFaultDone       = '{0} hard fault(s) in {1}. Saved with the session.'
    MyPc_HardFaultNone       = 'No hard faults at all. On a warmed machine that is the answer to hope for.'

    # -- Gaps -------------------------------------------------------------
    Gaps_Title               = 'Gaps'
    Gaps_FilterLabel         = 'Filter by severity'
    Gaps_FilterAutomationName = 'Filter gaps by severity'
    Gaps_Export              = 'Export table'
    Gaps_FixLabel            = 'Fix'

    # -- Score ------------------------------------------------------------
    Score_Title              = 'Score'
    Score_BeforeTitle        = 'Before'
    Score_AfterTitle         = 'After'
    Score_Limits             = 'This score is one session on one track. The iRacing-side engine stall does not go away with any Windows change.'
    Score_CaptureBefore      = 'Capture before'
    Score_CaptureAfter       = 'Capture after'

    # -- Share --------------------------------------------------------------
    Share_Title              = 'Share with the community'
    Share_Why                = 'Your report helps people with your hardware. We publish the results on the site.'
    Share_PreviewLabel       = 'This is exactly what would be shared:'
    Share_Save               = 'Save report'
    Share_OpenIssue          = 'Open a rig report on GitHub'
    Share_Disable            = "Don't ask again"

    # -- About ---------------------------------------------------------------
    About_Title              = 'About SimRig Console'
    About_VersionLabel       = 'Version'
    About_CommitLabel        = 'Commit'
    About_HashLabel          = 'File hash'
    About_UpdateChecking     = 'Checking for updates...'
    # The update check is note only: it never downloads and never installs, so every
    # sentence here ends with the user deciding. 'Unknown' is said plainly rather than
    # dressed up as 'up to date', which is a claim the app would not have earned.
    About_UpdateNotChecked   = 'Not checked yet. Use Check for updates.'
    About_UpdateOff          = 'Update check is off. You can turn it on in settings.'
    About_UpdateNoAnswer     = 'Could not reach the update list. Nothing was sent from this PC.'
    About_UpdateUnreadable   = 'Could not read the update list: {0}'
    About_UpdateNoVersion    = 'This build does not say which version it is, so it cannot be checked.'
    About_UpdateNoLatest     = 'The update list does not say which version is newest.'
    About_UpdateCurrent      = 'Version {0} is the newest.'
    About_UpdateAvailable    = 'Version {0} is available. You have {1}. Download it from the site when you are ready.'
    About_UpdateProblem      = 'This version has a known problem: {0} Update to {1}.'
    About_UpdateProblemNoFix = 'This version has a known problem: {0} A fixed build is not out yet.'
    About_Credits            = 'Credits: no6969el, Tom Brice'
    About_BuyMeACoffee       = 'Buy Me a Coffee'
    About_CheckUpdate        = 'Check for updates'

    # -- Uninstall ------------------------------------------------------------
    Uninstall_Title          = 'Uninstall SimRig Console'
    Uninstall_Text           = 'This removes the app files. It does not touch your saved sessions, snapshots or settings. This cannot undo a tuning change that is still applied - use Undo tuning first.'
    Uninstall_Open           = 'Uninstall this app'
    Uninstall_Confirm        = 'Uninstall'
    # Shown instead of the dialog when something this app changed is still applied.
    # Not a warning on the dialog: a confirmation for something that cannot proceed
    # teaches people to click through confirmations.
    Uninstall_BlockedTitle   = 'Not yet - one thing first'
    Uninstall_StartedTitle   = 'Uninstall started'
    Uninstall_StartedText    = 'Setup is removing the program folder, the shortcuts and the sign-in task. Your sessions, settings and profiles stay where they are. This window closes when it is done.'
    Uninstall_NoSetupTitle   = 'Setup not found'
    Uninstall_NoSetupText    = 'Uninstalling is done by Setup.cmd, and it is not next to this app. Run Setup.cmd /uninstall from wherever you installed from.'
    Uninstall_Cancel         = 'Cancel'

    # -- Apply tuning: the second confirmation (A-FIX-02, spec 6) ---------------
    # {0} is the number of values, {1} the list of names. The restart sentence is
    # added only when the plan actually holds an item that needs one, because a
    # warning that is always there stops being read.
    # Push 2 of the unit tune, step 7b: the texts of PUSH2-TEXTS-FOR-RICK-2026-10-03.md (Rick's "Yes"),
    # word for word. The row number of the sheet is at the end of each line.
    Tuning_ConfirmTitle      = 'Confirm tuning changes'
    Tuning_ConfirmOne        = 'Apply tuning writes this value to Windows. It stays until you press Undo tuning:'   # 3
    Tuning_ConfirmMany       = 'Apply tuning writes these {0} values to Windows. They stay until you press Undo tuning:'   # 4
    Tuning_ConfirmItem       = '{0}: now {1}, new {2}.'   # 5
    Tuning_ConfirmUndo       = 'The app saves the old values first. Undo tuning puts back each value in this list. It works also after you close the app and open it again.'   # 6
    Tuning_ConfirmNoUndoSteering = 'Undo tuning does not put GPU interrupt steering back.'   # 7
    Tuning_ConfirmRestart    = 'Needs a Windows restart before it takes effect: {0}.'   # 8
    Tuning_ConfirmSkipOne    = 'One item already has a value that the app accepts. The app does not change it.'   # 9
    Tuning_ConfirmSkipMany   = '{0} items already have a value that the app accepts. The app does not change them.'   # 10
    Tuning_ApplySubtitle     = 'Writing the values that you ticked. Approve the Windows prompt.'   # 17
    # -- Apply tuning: the first ask, the tick list (step 7b) -------------------
    Tuning_TickTitle         = 'Apply tuning'
    Tuning_TickText          = 'Tick each change that you want. No item is ticked at the start.'   # 26
    Tuning_TickValue         = 'now {0}, new {1}'   # 27
    Tuning_ValueMpoNotSet    = 'on (not set)'   # 28
    Tuning_ValueHagsNotSet   = 'not set (Windows decides)'   # 28
    Tuning_ValueOff          = 'off ({0})'   # 28
    Tuning_ValueOn           = 'on ({0})'   # 28
    Tuning_ValuePlan         = '{0} ({1})'   # 28
    Tuning_PlanBalanced      = 'Windows Balanced'   # 28
    Tuning_NoChange          = 'No change. The value is already {0}, and the app accepts it.'   # 30
    Tuning_DetailMpo         = 'Turns Multiplane Overlay off.'   # 31
    Tuning_DetailPlan        = 'This PC has two CCDs, and the active plan parks no cores. Windows Balanced parks cores, so the game can stay on the V-Cache die.'   # 32
    Tuning_DetailHags        = 'Turning HAGS off stops frame generation in games that use it, and Windows needs a restart before the change takes effect.'   # 33
    # -- Fix GPU steering: the second confirmation (flag 7) ---------------------
    GpuFix_ConfirmTitle      = 'Confirm the GPU steering fix'
    GpuFix_ConfirmText       = 'This writes the interrupt steering policy and then restarts the graphics device so it takes effect now. Your screens will go black for a few seconds, and a program using the GPU can reset - close anything you care about first. {0} Undo tuning does not put this policy back.'   # 11
    GpuFix_ScopeDisplay      = 'Only the display function of the card is changed; its audio and USB functions are recorded and left alone.'
    GpuFix_ScopeAll          = 'Every function of the card is changed, because this profile asks for that.'

    Tuning_NothingTitle      = 'Nothing to apply'
    Tuning_NothingText       = 'Each tuning value on this PC already has a value that the app accepts. There is nothing to write.'   # 13
}

function Get-SimRigString {
    <#
        .SYNOPSIS
        Resolves one string by key from $script:SimRigStrings. Never
        throws: a missing key logs to the verbose stream and returns the
        key itself, so the caller can spot it on screen instead of the
        function crashing the view.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Key
    )

    if (-not $script:SimRigStrings.ContainsKey($Key)) {
        Write-Verbose "Get-SimRigString: no string for key '$Key'."
        return $Key
    }

    return $script:SimRigStrings[$Key]
}
