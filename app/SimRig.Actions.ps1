<#
    SimRig.Actions.ps1 - SimRig Console v4.0, the elevated child

    The ONLY file in v4 that changes Windows state. The console runs unelevated
    (so the mapped Z: drive stays visible) and starts this script elevated, once
    per state change. Every change honours -WhatIf.

    Result contract (flag 4, engine/Engine.Result.ps1): this script writes
    C:\SimRacer\Logs\v4\results\<Operation>-<RequestId>.json (write .tmp, then
    rename) and exits with a code from Get-ActionExitCode. The console waits on
    the process and reads the JSON. Nothing crosses the elevation boundary on
    stdout.

    Operations
      Quiet    snapshot every quiet-list item, register the deadman logon task,
               apply the quiet in Order, read every item back.
      Restore  replay the snapshot (fallback defaults only if it is missing),
               delete registry keys v4 created, read back, "Windows healthy"
               verdict. A green restore removes the marker and the deadman.
      Undo     same as Restore, from the active marker. For the Undo button.
      Fix      Restore limited to -OnlyId (the red line's Fix button).
      Deadman  run by the logon task: if a session was never restored, run
               Restore; the task removes itself after a green restore.
      ApplyTuning  write the persistent tuning values from known-good.psd1 -
               MPO, HAGS, the power plan, GPU interrupt steering. Opt-in per
               item with -OnlyId. Snapshots to tuning-snapshot.json before the
               first write and reads every item back. Refuses while iRacing, a
               CapFrameX capture or OBS runs (flag 7).
      UndoTuning   replay tuning-snapshot.json. A value that was not set
               before is removed. GPU steering is left alone.
      SelfTest one Windows prompt, run by SimRig.SelfTest.ps1: quiet, a real
               service revert (the race watch must see it), restore, then quiet
               again and start the deadman task at once - it must restore and
               remove itself. Process items are skipped (nothing is closed).
               Details go to selftest-elevated.json in -SessionDir.

    Usage (the console builds this line with Get-ActionArgument):
      pwsh -NoProfile -ExecutionPolicy Bypass -File SimRig.Actions.ps1 -Operation Quiet
           -RequestId <guid> -SessionDir "C:\SimRacer\Logs\v4\sessions\2026-10-04_1932" [-WhatIf]
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Quiet', 'Restore', 'Undo', 'Fix', 'Deadman', 'SelfTest', 'FixGpu', 'ApplyTuning', 'UndoTuning', 'TraceStart', 'TraceStop')]
    [string] $Operation,

    [ValidatePattern('^[0-9a-fA-F-]{8,64}$')]
    [string] $RequestId = ([guid]::NewGuid().ToString()),

    [string] $SessionDir,

    # Fix, ApplyTuning/UndoTuning and Quiet: Ids joined with '|'.
    #
    # For Quiet this is the user's ticks (spec 6: no write without a tick). Passing
    # it empty is not the same as leaving it out: empty means nothing was ticked
    # and nothing is written, absent means the whole list, which is what the
    # deadman and the self-test act on.
    [string] $OnlyId,

    # ApplyTuning only: write a value that already reads as its target. The
    # self-test uses it for the MPO round trip.
    [switch] $Force,

    # G-12: the racer's own SID, passed by the unelevated console. Every HKCU item
    # is written to HKEY_USERS\<sid> instead, because a standard user who types an
    # administrator's credentials at the prompt makes this child run as that
    # administrator - whose HKCU is the wrong profile. Left out, HKCU is used as
    # written, which is what the deadman wants: it runs as the racer.
    [string] $UserSid,

    # Flag 7: which GPU PCI functions a steering Fix may write. Display is the
    # public default and the default here too, so a machine whose console forgot to
    # say gets the safe one rather than the one measured on Rick's card.
    [ValidateSet('Display', 'All')]
    [string] $GpuScope = 'Display',

    [string] $Root = 'C:\SimRacer'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'SimRig.Engine.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'SimRig.Probe.ps1')
# The engine's part files, same as the console loads them. Without this an engine
# function written in a part file is invisible here, which is how a v4.2 function
# can sit in the tree looking finished while the action layer never calls it.
foreach ($enginePart in @(Get-ChildItem -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'engine') -Filter *.ps1 -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
    . $enginePart.FullName
}
# Blocker 5 (2026-10-02): the readers of this PC, same as the console loads them.
# Get-SimRigMachineContext needs them to filter the quiet list for this machine.
foreach ($discoverPart in @(Get-ChildItem -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'discover') -Filter *.ps1 -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
    . $discoverPart.FullName
}

$script:DeadmanTaskPath = '\SimRig\'
$script:DeadmanTaskName = 'SimRigV4-Deadman'
$script:IsWhatIf = [bool]$WhatIfPreference
$script:UserSid = $UserSid
# Set when a run could not finish everything and the session must stay open, even
# where the items it did touch all came back (flag 4).
$script:KeepMarker = $false
$script:Codes = Get-ActionExitCode
$script:Paths = Get-SimRigPath -Root $Root
# Blocker 7, commit 6 (O3): the log file of this run, opened by Open-ActionChildLog. The child does not open
# actions.log: the parent, which is not elevated, appends this file to it.
$script:ChildLog = $null
# Blocker 7, commit 8, part (c): the refusal of a link on the path of Logs\v4\results, or $null. With a refusal the
# child writes no folder, no log file and no result file.
$script:LogsRefusal = $null

# --------------------------------------------------------------------------
# Logging and files (v4's own files - not system state)
# --------------------------------------------------------------------------

function Resolve-ActionPath {
    <# .NET file calls do not follow the PowerShell location; resolve first. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Write-ActionLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Message)
    $line = '{0} [{1} {2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Operation, $RequestId.Substring(0, 8), $Message
    if ($null -eq $script:ChildLog) {
        Write-Warning ("the log file of this run is not open: {0}" -f $line)
    }
    else {
        try {
            # Each line goes to the disk at once, so that a run that stops keeps the lines before it (O3).
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($line + [Environment]::NewLine)
            $script:ChildLog.Write($bytes, 0, $bytes.Length)
            $script:ChildLog.Flush()
        }
        catch {
            Write-Warning ("the log file of this run is not writable ({0}): {1}" -f $_.Exception.Message, $line)
        }
    }
    Write-Verbose $line
}

function Open-ActionChildLog {
    <#
        Blocker 7, commit 6 (O3; NOTE-blocker7-commit5-6-cowork-2026-10-08.md, the addendum of 11:50). Opens the log
        file of this run, <Operation>-<RequestId>.log in the results folder, as a new file (CreateNew refuses when any
        item has the name, a link too). The handle stays open for the whole run, and FileShare.Read lets the parent
        read it. When it cannot be opened, the run goes on, and each line goes to the warning stream only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    try {
        $script:ChildLog = [System.IO.FileStream]::new((Resolve-ActionPath $Path), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    }
    catch {
        Write-Warning ("the log file of this run was not opened ({0}): {1}" -f $_.Exception.Message, $Path)
    }
}

function Close-ActionChildLog {
    <# Blocker 7, commit 6 (O3): closes the log file of this run, at the end of the run. #>
    [CmdletBinding()]
    param()
    if ($null -ne $script:ChildLog) {
        $script:ChildLog.Dispose()
        $script:ChildLog = $null
    }
}

function Test-ActionRunChanged {
    <#
        Blocker 7, commit 8, part (b) (APPROVALS-RICK-2026-10-08-1500 item 1a). True when this run has a step that
        changed Windows or may have changed it: the rule of the engine (Get-SelfTestLeftAsFoundCheck), a step Done,
        DidNotTake or Failed is a change by the app. Each change of the child is a step in $script:Steps, so the flag
        is read from the steps and is not set by hand in each writer.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    foreach ($step in @($script:Steps)) {
        if ($null -ne $step -and @('Done', 'DidNotTake', 'Failed') -contains [string]$step.Status) { return $true }
    }
    return $false
}

function Get-ActionLinkText {
    <#
        Blocker 7, commit 8, part (b). The refusal for a link or a folder at Path. Text 5 says "Nothing was changed",
        so it is given only when the run has changed nothing yet. After a change: text 5b (Rick's "Yes to
        APPROVALS-RICK-2026-10-08-1500", item 1a).
        Blocker 7, commit 9 (APPROVALS-RICK-2026-10-09-2125 item B.2, "Yes 0725"): text 5 says "a link or a folder".
        Text 5b by the operation: the form for Quiet only. The forms for Apply tuning, Trace Stop and the self-test
        are not true on each of their paths (review/TEXTS-blocker7-c9-2026-10-10.md), so those operations, and each
        other operation, keep the text 5b of commit 8.
        APPROVALS-RICK-2026-10-10-0910 item 3 ("yes 0910"): the new form for Trace Stop is true on each of its paths,
        so it is here. The new forms for Apply tuning and the self-test were not (the TEXTS file, section "0910
        texts"). Open-limits unit (APPROVALS-RICK-2026-10-12-0555 item 2): the form for the self-test (T2) is here;
        Apply tuning keeps the text 5b of commit 8 (limit C9-L10 stays open; T1 is not put in, see the record).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)
    if (Test-ActionRunChanged) {
        if ('Quiet' -eq $Operation) {
            # Text 5b, the form for Quiet. The marker and the deadman are written before the first step, so Restore
            # has the session to put back.
            return ('Refused: {0} is a link or a folder. Some steps were already done. Remove it, then run Restore.' -f $Path)
        }
        if ('TraceStop' -eq $Operation) {
            # Text 5b, the form for Trace Stop (0910 item 3). Each refusal after a change comes after the stop of xperf,
            # and Move-ActionFileOver never removes a trace file, so its files stay in the session folder.
            return ('Refused: {0} is a link or a folder. The trace was stopped. Its files are in the session folder, some maybe under a temporary name. Remove it. Do not run Trace Stop again; start a new trace if you need one.' -f $Path)
        }
        if ('SelfTest' -eq $Operation) {
            # Text T2 of TEXTS-open-limits-2026-10-12.md (APPROVALS-RICK-2026-10-12-0555 item 2, closes limit C9-L11). The
            # self-test applies no tuning, so Undo tuning is not the way back. After its first Quiet, Restore is.
            return ('Refused: {0} is a link or a folder. Remove it, then run the self-test again. If SimRig offers Restore when it starts, run Restore first.' -f $Path)
        }
        # Text 5b of commit 8.
        return ('Refused: {0} is a link or a folder. Some steps were already done. Remove the link, then run Undo tuning.' -f $Path)
    }
    # Text 5.
    return ('Refused: {0} is a link or a folder. Nothing was changed. Remove it and try again.' -f $Path)
}

function Get-ActionFinalNameRefusal {
    <#
        Blocker 7, commit 8, part (a) (REVIEW-night-o2-e0cab04.md, finding 1). Before the first step of an operation:
        each final name that it writes is checked for a link on its path (Find-SimRigPathLink, from the data folder
        down, the name included) and for a folder at the name. The refusal (Get-ActionLinkText), or $null. An item in
        a folder that cannot be read gets text 6 before a change; after a change the write itself decides (a limit of
        the change record).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string[]] $Path)
    foreach ($p in $Path) {
        $link = Find-SimRigPathLink -Root $script:Paths.Root -Path $p
        if ($null -ne $link) {
            if ($link.Cause -eq 'Link') { return (Get-ActionLinkText -Path $link.Item) }
            if (-not (Test-ActionRunChanged)) {
                # Text 6, the form for the session folder.
                return ('Refused: the app cannot check {0}, because Windows does not let it read the folder. Nothing was changed.' -f $link.Item)
            }
        }
        if ([System.IO.Directory]::Exists((Resolve-ActionPath $p))) { return (Get-ActionLinkText -Path $p) }
    }
    return $null
}

function Write-ActionTempFile {
    <#
        Blocker 7, commit 3 (NOTE-tmp-file-link-gap-cowork-2026-10-08.md; Rick's "Yes", 2026-10-08). Writes Text to
        the new file TempPath. The data folder gives each signed-in user Modify, so a user can put a link (a hard
        link needs no right) at a temp name, and a write that opens with truncate writes through it, as
        administrator. Here: a file or a link at the name is removed first (File.Delete removes the name, not the
        target of a link; it does nothing when no item has the name, and it fails on a folder, which is not
        removed). Then the file is opened with CreateNew, which refuses when any item has the name, a link too.
        When that fails, the write stops with text 5 and writes nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $TempPath, [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    try { [System.IO.File]::Delete($TempPath) } catch { Write-Verbose ('temp name not removed: {0}' -f $_.Exception.Message) }
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    try {
        $stream = [System.IO.FileStream]::new($TempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    }
    catch {
        # Text 5, the form for the session folder (the Cowork note, point 2: {0} is the temp path), only when an
        # item still has the name. Another fault (a folder that is not there, a full disk) stays an error.
        # Blocker 7, commit 8: text 5b after a change (Get-ActionLinkText).
        if ([System.IO.File]::Exists($TempPath) -or [System.IO.Directory]::Exists($TempPath)) {
            throw (Get-ActionLinkText -Path $TempPath)
        }
        throw
    }
    try { $stream.Write($bytes, 0, $bytes.Length) }
    finally { $stream.Dispose() }
}

function Get-ActionTempPath {
    <# Blocker 7, commit 3: a temp name that is new each time, so that a planted name cannot be guessed. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Full)
    return ('{0}.{1}.tmp' -f $Full, [guid]::NewGuid().ToString('N'))
}

function Move-ActionFileOver {
    <#
        Blocker 7, commit 6 (Causes row 11 of the change record; ANSWERS-night-o2-a6f61ac-move-cowork-2026-10-08.md).
        Renames the file Source to Destination, and replaces a file or a link that has that name. Move-Item is not
        used: when Destination is a folder, or a link to a folder, Move-Item moves the file INTO it, a write at a place
        that a user chose. File.Move replaces the name and fails on a folder. On a folder the write stops with text 5.
        The file at Source is removed only with -SourceIsTemp (a temp file of the app). A trace file is never removed:
        it is the data of the user (PRECHECK-night-o2-4237ef3.md, finding 11-1).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Source, [Parameter(Mandatory)] [string] $Destination, [switch] $SourceIsTemp)
    try { [System.IO.File]::Move($Source, $Destination, $true) }
    catch {
        if ([System.IO.Directory]::Exists($Destination)) {
            if ($SourceIsTemp) {
                try { [System.IO.File]::Delete($Source) } catch { Write-Verbose ('temp file not removed: {0}' -f $_.Exception.Message) }
            }
            # Blocker 7, commit 8 (REVIEW-night-o2-e0cab04.md, finding 1): text 5 only before a change, else 5b.
            throw (Get-ActionLinkText -Path $Destination)
        }
        throw
    }
}

function Clear-ActionNewName {
    <#
        Blocker 7, commit 6 (O2; NOTE-blocker7-commit5-6-cowork-2026-10-08.md). Before a program of Windows (xperf)
        writes to a new name of the app: removes a file or a link at the name (the name only, as Write-ActionTempFile
        does). Returns text 5 when an item stays at the name, else $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)
    $full = Resolve-ActionPath $Path
    try { [System.IO.File]::Delete($full) } catch { Write-Verbose ('new name not removed: {0}' -f $_.Exception.Message) }
    # Blocker 7, commit 8: Trace Stop calls this after the stop of xperf, so text 5b after a change.
    if ([System.IO.File]::Exists($full) -or [System.IO.Directory]::Exists($full)) {
        return (Get-ActionLinkText -Path $Path)
    }
    return $null
}

function Write-JsonFileAtomic {
    <# Writes JSON to a new temp file (Write-ActionTempFile), then renames over <path> (Move-ActionFileOver). A reader never sees half a file. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [object] $InputObject)
    $full = Resolve-ActionPath $Path
    $tmp = Get-ActionTempPath -Full $full
    $json = $InputObject | ConvertTo-Json -Depth 30
    Write-ActionTempFile -TempPath $tmp -Text $json
    Move-ActionFileOver -Source $tmp -Destination $full -SourceIsTemp
}

function Write-UndoByHandFile {
    <#
        Push 2 of the unit tune, step 6. Writes the same bytes of UNDO-BY-HAND.txt beside the snapshot of
        record and in Logs\v4 (the Cowork note of 2026-10-04, point 1), each as Write-JsonFileAtomic does:
        a new temp file, then a rename. A file that cannot be written throws, and the Apply writes no value.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SnapshotPath, [Parameter(Mandatory)] [string] $Text)
    $beside = Join-Path -Path (Split-Path -Path $SnapshotPath -Parent) -ChildPath 'UNDO-BY-HAND.txt'
    foreach ($path in @($beside, $script:Paths.TuningUndoByHand)) {
        $full = Resolve-ActionPath $path
        $tmp = Get-ActionTempPath -Full $full
        Write-ActionTempFile -TempPath $tmp -Text $Text
        Move-ActionFileOver -Source $tmp -Destination $full -SourceIsTemp
    }
}

function Initialize-ActionFolder {
    [CmdletBinding()]
    param([string[]] $Folder)
    foreach ($f in $Folder) {
        if ($f -and -not (Test-Path -LiteralPath $f)) {
            [void](New-Item -ItemType Directory -Path $f -Force -WhatIf:$false -Confirm:$false)
        }
    }
}

# --------------------------------------------------------------------------
# The writers. One function per plan Op. Each returns Done/WhatIf/Failed.
# --------------------------------------------------------------------------

function ConvertTo-ServiceStartupType {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $StartType)
    switch ($StartType) {
        'Automatic' { return 'Automatic' }
        'AutomaticDelayed' { return 'AutomaticDelayedStart' }
        'Manual' { return 'Manual' }
        'Disabled' { return 'Disabled' }
        default { return $null }
    }
}

function ConvertTo-ScStartWord {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $StartType)
    switch ($StartType) {
        'Automatic' { return 'auto' }
        'AutomaticDelayed' { return 'delayed-auto' }
        'Manual' { return 'demand' }
        'Disabled' { return 'disabled' }
        'Boot' { return 'boot' }
        'System' { return 'system' }
        default { throw "Unknown start type '$StartType'" }
    }
}

function Set-SimRigServiceStartType {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $StartType)
    if (-not $PSCmdlet.ShouldProcess("service $Name", "set start type $StartType")) { return 'WhatIf' }
    $psType = ConvertTo-ServiceStartupType -StartType $StartType
    if ($psType) {
        try {
            Set-Service -Name $Name -StartupType $psType -ErrorAction Stop
            return 'Done'
        }
        catch {
            Write-ActionLog ("Set-Service {0} {1} failed ({2}); trying sc.exe" -f $Name, $psType, $_.Exception.Message)
        }
    }
    $out = & sc.exe config $Name start= (ConvertTo-ScStartWord -StartType $StartType) 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("sc.exe config {0} failed ({1}): {2}" -f $Name, $LASTEXITCODE, ($out -join ' ')) }
    return 'Done'
}

function Stop-SimRigService {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Name)
    if (-not $PSCmdlet.ShouldProcess("service $Name", 'stop')) { return 'WhatIf' }
    $svc = Get-Service -Name $Name -ErrorAction Stop
    if ($svc.Status -eq 'Stopped') { return 'Done' }
    # No -Force: -Force also stops dependent services, which are not on the list.
    Stop-Service -Name $Name -ErrorAction Stop
    return 'Done'
}

function Start-SimRigService {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Name)
    if (-not $PSCmdlet.ShouldProcess("service $Name", 'start')) { return 'WhatIf' }
    $svc = Get-Service -Name $Name -ErrorAction Stop
    if ($svc.Status -eq 'Running') { return 'Done' }
    Start-Service -Name $Name -ErrorAction Stop
    return 'Done'
}

function Set-SimRigTaskEnabled {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $TaskPath, [Parameter(Mandatory)] [string] $TaskName, [Parameter(Mandatory)] [bool] $Enabled)
    $verb = if ($Enabled) { 'enable' } else { 'disable' }
    if (-not $PSCmdlet.ShouldProcess("task $TaskPath$TaskName", $verb)) { return 'WhatIf' }
    if ($Enabled) { [void](Enable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop) }
    else { [void](Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop) }
    return 'Done'
}

function Set-SimRigRegistryValue {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Value,
        [Parameter(Mandatory)] [object] $Data,
        [string] $RegType = 'DWord',
        [bool] $CreateKey
    )
    if (-not $PSCmdlet.ShouldProcess("$Path\$Value", "set $Data")) { return 'WhatIf' }
    if (-not (Test-Path -LiteralPath $Path)) {
        if (-not $CreateKey) { throw "Key $Path does not exist and this item does not create it" }
        [void](New-Item -Path $Path -Force -ErrorAction Stop)
    }
    [void](New-ItemProperty -LiteralPath $Path -Name $Value -Value $Data -PropertyType $RegType -Force -ErrorAction Stop)
    return 'Done'
}

function Remove-SimRigRegistryValue {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Value)
    if (-not $PSCmdlet.ShouldProcess("$Path\$Value", 'delete value')) { return 'WhatIf' }
    if (-not (Test-Path -LiteralPath $Path)) { return 'Done' }
    $key = Get-Item -LiteralPath $Path
    if (@($key.GetValueNames()) -contains $Value) { Remove-ItemProperty -LiteralPath $Path -Name $Value -ErrorAction Stop }
    return 'Done'
}

function Remove-SimRigRegistryKey {
    <#
        Deletes a key v4 created for the session (Absent='create-then-delete').
        Safety: only when the key holds nothing but v4's own value and has no
        subkeys. If Windows wrote something else into it meanwhile, only v4's
        value is deleted and the key stays.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $OwnValue)
    if (-not $PSCmdlet.ShouldProcess($Path, 'delete key')) { return 'WhatIf' }
    if (-not (Test-Path -LiteralPath $Path)) { return 'Done' }
    $key = Get-Item -LiteralPath $Path
    $others = @($key.GetValueNames() | Where-Object { $_ -ne $OwnValue -and $_ -ne '' })
    if ($others.Count -gt 0 -or $key.SubKeyCount -gt 0) {
        Write-ActionLog ("[WARN] {0} now holds other data ({1}); deleting only {2}" -f $Path, ($others -join ', '), $OwnValue)
        return (Remove-SimRigRegistryValue -Path $Path -Value $OwnValue)
    }
    Remove-Item -LiteralPath $Path -ErrorAction Stop
    return 'Done'
}

function Stop-SimRigProcess {
    <# Graceful close first, force only if needed - v3.9 learned that a force-kill breaks Claude's VM service. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Name)
    if (-not $PSCmdlet.ShouldProcess("process $Name", 'close')) { return 'WhatIf' }
    $procs = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return 'Done' }
    foreach ($p in $procs) { [void]$p.CloseMainWindow() }
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline -and @(Get-Process -Name $Name -ErrorAction SilentlyContinue).Count -gt 0) { Start-Sleep -Milliseconds 250 }
    $left = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    if ($left.Count -gt 0) { $left | Stop-Process -Force -ErrorAction Stop }
    return 'Done'
}

function Enable-SimRigTaskLog {
    <# TODO 2.3: the TaskScheduler/Operational log must be on for race watch. Idempotent; not restored. #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (Test-SimRigTaskLogEnabled) { return 'Done' }
    $cfg = [System.Diagnostics.Eventing.Reader.EventLogConfiguration]::new('Microsoft-Windows-TaskScheduler/Operational')
    try {
        if (-not $PSCmdlet.ShouldProcess('TaskScheduler/Operational log', 'enable')) { return 'WhatIf' }
        $cfg.IsEnabled = $true
        $cfg.SaveChanges()
        return 'Done'
    }
    finally { $cfg.Dispose() }
}

function Invoke-SimRigStep {
    <#
        Runs one plan step and returns the step record for the result JSON.
        A failed step is recorded and the plan continues: one refused item
        (WaaSMedicSvc is protected on some builds) must not leave the rest
        un-quieted or un-restored.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Step, [Parameter(Mandatory)] [hashtable] $ItemById)
    $item = $ItemById[$Step.Id]
    $status = 'Failed'
    $message = $null
    $a = $Step.Arg
    try {
        $status = switch ($Step.Op) {
            'Skip' { $message = $a.Why; 'Skipped' }
            'SetStartType' { Set-SimRigServiceStartType -Name $item.Name -StartType $a.StartType -WhatIf:$script:IsWhatIf }
            'StopService' { Stop-SimRigService -Name $item.Name -WhatIf:$script:IsWhatIf }
            'StartService' { Start-SimRigService -Name $item.Name -WhatIf:$script:IsWhatIf }
            'DisableTask' { Set-SimRigTaskEnabled -TaskPath $item.Path -TaskName $item.Name -Enabled $false -WhatIf:$script:IsWhatIf }
            'EnableTask' { Set-SimRigTaskEnabled -TaskPath $item.Path -TaskName $item.Name -Enabled $true -WhatIf:$script:IsWhatIf }
            'SetRegistryValue' { Set-SimRigRegistryValue -Path $a.Path -Value $a.Value -Data $a.Data -RegType $a.RegType -CreateKey ([bool]$a.CreateKey) -WhatIf:$script:IsWhatIf }
            'DeleteRegistryValue' { Remove-SimRigRegistryValue -Path $a.Path -Value $a.Value -WhatIf:$script:IsWhatIf }
            'DeleteRegistryKey' { Remove-SimRigRegistryKey -Path $a.Path -OwnValue $item.Value -WhatIf:$script:IsWhatIf }
            'SetDefenderRealtime' {
                # Flag 15: loaded here and nowhere else, so a build that never takes
                # a Defender step never loads the code that can take one. A step only
                # gets this far when the selected profile opted in.
                $defenderPart = Join-Path -Path $PSScriptRoot -ChildPath 'SimRig.Actions.Defender.ps1'
                if (-not (Test-Path -LiteralPath $defenderPart)) {
                    throw 'This step needs SimRig.Actions.Defender.ps1 and it is not installed. Re-install with Setup.cmd, or remove the Defender item from the quiet list.'
                }
                . $defenderPart
                Set-SimRigDefenderRealtime -On ([bool]$a.On) -WhatIf:$script:IsWhatIf
            }
            'CloseProcess' { Stop-SimRigProcess -Name $a.Name -WhatIf:$script:IsWhatIf }
            'EnableTaskLog' { Enable-SimRigTaskLog -WhatIf:$script:IsWhatIf }
            'RegisterDeadman' { $message = "$script:DeadmanTaskPath$script:DeadmanTaskName"; Register-SimRigDeadman -UserSid ([string]$a.UserSid) -WhatIf:$script:IsWhatIf }
            default { throw "Unknown op '$($Step.Op)'" }
        }
    }
    catch {
        $status = 'Failed'
        $message = ($_.Exception.Message -replace '\s+', ' ').Trim()
        # Windows protects some items even from an administrator (TrustedInstaller-
        # owned update tasks, WaaSMedicSvc, DoSvc's delayed flag), and a service with
        # running dependents will not stop. Measured on the rig 2026-09-19. These are
        # Windows' refusals, not v4 failures: logged, left out of the read-back, and
        # still watched during the race.
        if ($message -match 'Access is denied|access denied|0x80070005|registry access is not allowed|has dependent services') {
            $status = 'Refused'
        }
    }
    # RF-2. Done here means: Windows accepted the change and returned no error. It
    # does not mean that the change is there (rig 2026-09-30: EnableTask returned no
    # error and the task was still disabled). So the line says [SENT], not [OK].
    # Confirm-SimRigStepReadBack compares the step with the state that is read after
    # all steps, and logs [OK] for the steps that it confirmed.
    $tag = switch ($status) { 'Done' { '[SENT]' } 'WhatIf' { '[WHATIF]' } 'Skipped' { '[SKIP]' } 'Refused' { '[REFUSED]' } default { '[FAIL]' } }
    Write-ActionLog ('{0} {1} {2} {3}' -f $tag, $Step.Op, $Step.Id, $message)
    return [pscustomobject]@{ Seq = $Step.Seq; Id = $Step.Id; Op = $Step.Op; Source = $Step.Source; Status = $status; Message = $message }
}

function Confirm-SimRigStepReadBack {
    <#
        RF-2. Compares the steps of this operation with the state that was read back
        after them, and puts the confirmed status in $script:Steps.

        -From is the count of $script:Steps before this operation started. The
        self-test runs a quiet, a restore and a second quiet in one process, and a
        step of an earlier operation must not be compared with a later state.

        The log gets one [NOTSET] line for each step whose value is not there, one
        [OK] line with the count of the steps that were read back at their value,
        and one line with the steps that were sent and that no read covers, by op
        name, so the log never implies that those were confirmed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $From,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $State,
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Plan
    )
    if ($script:IsWhatIf) { return }
    $all = $script:Steps.ToArray()
    if ($From -ge $all.Count) { return }
    $earlier = @($all | Select-Object -First $From)
    $mine = @($all | Select-Object -Skip $From)
    $cmp = Compare-StepReadBack -Step $mine -State $State -KnownGood $script:Kg -Plan $Plan
    $script:Steps.Clear()
    foreach ($s in $earlier) { $script:Steps.Add($s) }
    foreach ($s in @($cmp.Steps)) { $script:Steps.Add($s) }
    foreach ($s in @($cmp.NotSet)) {
        Write-ActionLog ('[NOTSET] {0} {1} {2}' -f $s.Op, $s.Id, $s.Message)
    }
    Write-ActionLog ('[OK]   {0} step(s) read back at the value that was set' -f $cmp.Confirmed)
    if ($cmp.NotReadBack -gt 0) {
        Write-ActionLog ('[NOTE] {0} step(s) were sent and no read covers them: {1}' -f $cmp.NotReadBack, $cmp.NotReadBackText)
    }
}

function Write-SimRigQuietRecord {
    <#
        RF-1. Appends the steps of this quiet to <session folder>\quiet-record.json,
        so a later restore knows which items the app changed and which ones Windows
        refused. Written after the read-back comparison, so a step that did not take
        is in the record as DidNotTake.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Dir, [Parameter(Mandatory)] [string] $SessionId, [Parameter(Mandatory)] [int] $From)
    $path = Join-Path $Dir 'quiet-record.json'
    $existing = $null
    if (Test-Path -LiteralPath $path) {
        try { $existing = [System.IO.File]::ReadAllText((Resolve-ActionPath $path)) }
        catch { $existing = '' }
    }
    $mine = @($script:Steps.ToArray() | Select-Object -Skip $From)
    $record = Build-QuietRecord -SessionId $SessionId -Operation $Operation -RequestId $RequestId -WrittenAt (Get-Date) -Step $mine -ExistingText $existing
    Write-JsonFileAtomic -Path $path -InputObject $record
    $note = if ($record.Contains('Untrusted')) { ' - NOT TRUSTED: ' + $record['Untrusted'] } else { '' }
    Write-ActionLog ('quiet record: {0} step(s) of this run, {1} run(s) -> {2}{3}' -f $mine.Count, @($record['Runs']).Count, $path, $note)
}

function Read-SimRigQuietRecord {
    <#
        RF-1. The steps of the quiet record of the session that the marker names, or
        $null when no record can be used. $null means: no item can be called
        "refused by Windows", and each item that differs is not healthy.
    #>
    [CmdletBinding()]
    param([AllowNull()] [object] $Marker)
    if ($null -eq $Marker) {
        Write-ActionLog '[WARN] quiet record: no active session marker, so no record'
        return $null
    }
    $names = @($Marker.PSObject.Properties.Name)
    if ($names -notcontains 'SessionDir' -or $names -notcontains 'SessionId' -or -not $Marker.SessionDir -or -not $Marker.SessionId) {
        Write-ActionLog '[WARN] quiet record: the marker has no session folder or no session id, so no record'
        return $null
    }
    # Blocker 7 (O2): the session folder of the marker is checked as a -SessionDir is, before the record is read.
    # A folder that the check refuses gives no record (a log line only; the restore verdict then counts each item
    # that differs as not restored, as with no record).
    $folderRefusal = Get-ActionTuningPathRefusal -Dir ([string]$Marker.SessionDir)
    if ($folderRefusal) {
        Write-ActionLog ('[WARN] quiet record: not usable ({0}). An item that differs from the snapshot is counted as not restored' -f $folderRefusal)
        return $null
    }
    $path = Join-Path ([string]$Marker.SessionDir) 'quiet-record.json'
    $text = $null
    if (Test-Path -LiteralPath $path) {
        try { $text = [System.IO.File]::ReadAllText((Resolve-ActionPath $path)) }
        catch { $text = $null }
    }
    $read = ConvertFrom-QuietRecordText -Text $text -SessionId ([string]$Marker.SessionId)
    if (-not $read.Usable) {
        Write-ActionLog ('[WARN] quiet record: not usable ({0}). An item that differs from the snapshot is counted as not restored' -f $read.Reason)
        return $null
    }
    Write-ActionLog ('quiet record: {0} step(s) from {1} run(s) of session {2}' -f @($read.Steps).Count, @($read.Runs).Count, $Marker.SessionId)
    return , @($read.Steps)
}

# --------------------------------------------------------------------------
# Deadman logon task
# --------------------------------------------------------------------------

function Register-SimRigDeadman {
    <#
        Flag 4. v4.0 registered this task for the child's own user, read from
        $env:USERNAME. In an elevated child that is whoever's credentials were typed
        at the prompt - so on a PC where a standard user borrows an administrator's
        password, the task was registered for the administrator, triggered at the
        administrator's sign-in (which may never come) and ran with the
        administrator's hive. The racer could sign in every day and never have their
        session restored.

        So it runs as SYSTEM and triggers at the RACER's sign-in, and the racer's SID
        travels in the argument list rather than being read at run time. SYSTEM can
        write any loaded hive; the -UserSid argument says which one.

        Without a SID there is no racer to trigger for, so it falls back to this
        process's own user and says so in the log. A deadman for the wrong user is
        still better than none - it restores the machine, just possibly later - but
        it is a fallback and it is recorded as one.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([AllowNull()] [string] $UserSid)

    if (-not $PSCmdlet.ShouldProcess("$script:DeadmanTaskPath$script:DeadmanTaskName", 'register logon task')) { return 'WhatIf' }
    $pwsh = (Get-Process -Id $PID).Path
    $racer = if (Test-SimRigUserSid -Sid $UserSid) { $UserSid } else { $null }

    $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Operation Deadman -Root "{1}"' -f $PSCommandPath, $script:Paths.Root
    if ($racer) { $arg += (' -UserSid {0}' -f $racer) }
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument $arg

    # SYSTEM either way, never this process's own user: reading $env:USERNAME here is
    # exactly the flag 4 mistake, because in an elevated child that name may belong to
    # whoever's credentials were typed at the prompt.
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    if ($racer) {
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $racer
        Write-ActionLog ('deadman: SYSTEM principal, triggers at the sign-in of {0}' -f $racer)
    }
    else {
        # No SID to trigger on, so any sign-in starts it. As SYSTEM it can still put
        # the machine-wide half back; the per-user half is skipped, with a Warn, by
        # the run itself - because SYSTEM's HKCU is not the racer's.
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        Write-ActionLog '[WARN] deadman: no -UserSid, so it triggers at any sign-in and will skip the per-user items'
    }
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    [void](Register-ScheduledTask -TaskPath $script:DeadmanTaskPath -TaskName $script:DeadmanTaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force -Description 'SimRig v4: restores Windows at sign-in if a race session was never restored. Removes itself after a green restore.')
    return 'Done'
}

function Unregister-SimRigDeadman {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $t = Get-ScheduledTask -TaskPath $script:DeadmanTaskPath -TaskName $script:DeadmanTaskName -ErrorAction SilentlyContinue
    if ($null -eq $t) { return 'Done' }
    if (-not $PSCmdlet.ShouldProcess("$script:DeadmanTaskPath$script:DeadmanTaskName", 'unregister logon task')) { return 'WhatIf' }
    Unregister-ScheduledTask -TaskPath $script:DeadmanTaskPath -TaskName $script:DeadmanTaskName -Confirm:$false -ErrorAction Stop
    return 'Done'
}

# --------------------------------------------------------------------------
# Operations
# --------------------------------------------------------------------------

function Invoke-QuietOperation {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Item, [string] $Dir = $SessionDir)

    if (@($Item).Count -eq 0) {
        # Spec 6: no write without a tick. Nothing ticked means no snapshot, no
        # marker, no deadman and no session - there is nothing to undo, so
        # starting one would leave the user a restore they do not need.
        $script:Errors.Add('Nothing was ticked, so nothing was changed. Tick the items to quiet, then run it again.')
        Write-ActionLog 'no items selected - nothing written'
        return
    }
    if (-not $script:IsWhatIf -and (Test-Path -LiteralPath $script:Paths.ActiveMarker)) {
        $m = Read-SimRigJson -Path $script:Paths.ActiveMarker
        $sid = if ($null -ne $m) { $m.SessionId } else { 'unknown' }
        $script:Errors.Add("Refused: session $sid was never restored. Its snapshot is the only record of the real prior state. Run Restore or Undo first.")
        $script:ExitCode = $script:Codes.Refused
        return
    }
    if (-not $Dir) { throw 'Quiet needs -SessionDir' }
    $snapName = if ($script:IsWhatIf) { 'snapshot-dryrun.json' } else { 'snapshot.json' }
    # Blocker 7, commit 8, part (a): each final name of this Quiet before its first step (probe B of
    # REVIEW-night-o2-e0cab04.md: a folder at quiet-record.json gave text 5 after the quiet).
    $finalName = @((Join-Path $Dir $snapName))
    if (-not $script:IsWhatIf) { $finalName += @((Join-Path $Dir 'quiet-record.json'), $script:Paths.ActiveMarker) }
    $finalRefusal = Get-ActionFinalNameRefusal -Path $finalName
    if ($finalRefusal) {
        $script:Errors.Add($finalRefusal)
        $script:ExitCode = $script:Codes.Refused
        return
    }
    Initialize-ActionFolder -Folder $Dir

    $sessionId = Split-Path -Path $Dir -Leaf
    $before = Get-TimedItemState -Item $Item -Label 'before quiet'
    $snapshot = Build-Snapshot -QuietItem $Item -State $before -TakenAt (Get-Date) -SessionId $sessionId
    $script:SnapshotPath = Join-Path $Dir $snapName
    Write-JsonFileAtomic -Path $script:SnapshotPath -InputObject $snapshot
    Write-ActionLog ("snapshot of {0} items -> {1}" -f @($before).Count, $script:SnapshotPath)

    if (-not $script:IsWhatIf) {
        # Marker first, then deadman, then the quiet: a crash from here on is recoverable.
        $marker = Build-ActiveMarker -SessionId $sessionId -SessionDir $Dir -SnapshotPath $script:SnapshotPath -QuietAt (Get-Date) -UserSid $script:UserSid
        $bb = Get-SimRigBackblazeLastBackup
        $marker['BackblazeLastBackup'] = if ($null -ne $bb) { Format-SimRigTime -Time $bb } else { $null }
        Write-JsonFileAtomic -Path $script:Paths.ActiveMarker -InputObject $marker
    }
    $stepsBefore = $script:Steps.Count
    $script:Steps.Add((Invoke-SimRigStep -Step ([pscustomobject]@{ Seq = 0; Id = 'Deadman'; Op = 'RegisterDeadman'; Arg = @{ UserSid = $script:UserSid }; Source = 'quiet' }) -ItemById @{}))
    $script:Steps.Add((Invoke-SimRigStep -Step ([pscustomobject]@{ Seq = 0; Id = 'TaskLog'; Op = 'EnableTaskLog'; Arg = @{}; Source = 'quiet' }) -ItemById @{}))

    $byId = @{}
    foreach ($i in $Item) { $byId[$i.Id] = $i }
    $quietPlan = Get-QuietPlan -QuietItem $Item -Current $before
    foreach ($step in $quietPlan) {
        $script:Steps.Add((Invoke-SimRigStep -Step $step -ItemById $byId))
    }

    $after = Get-TimedItemState -Item $Item -Label 'quiet read-back'
    # RF-2: the step status from the value that was read. Then RF-1: the record of
    # what this quiet did, for the restore verdict. Not in a dry run: nothing was
    # changed, and a dry run has no session to restore.
    Confirm-SimRigStepReadBack -From $stepsBefore -State $after -Plan $quietPlan
    if (-not $script:IsWhatIf) {
        Write-SimRigQuietRecord -Dir $Dir -SessionId $sessionId -From $stepsBefore
    }
    if ($script:IsWhatIf) {
        # Dry run (TODO T.4): the machine must be unchanged - compare with the snapshot.
        $expected = @($before | Where-Object { $_.Kind -ne 'Process' })
    }
    else {
        $expected = Select-ReadBackItem -Target (Get-QuietTarget -QuietItem $Item) -Current $before
        # An item Windows refused to change cannot be at its quiet target; it is
        # reported by its Refused step, not as a read-back failure.
        $refusedIds = @($script:Steps | Where-Object { $_.Status -eq 'Refused' } | ForEach-Object { $_.Id })
        $expected = @($expected | Where-Object { $refusedIds -notcontains $_.Id })
    }
    $script:ReadBack = @(Compare-ItemState -QuietItem $Item -Expected $expected -Actual $after)
    if ($script:IsWhatIf) {
        # A dry run changes nothing, so a service Windows switches by itself (BITS,
        # rig 2026-09-19 19:56) is not a dry-run change: accept its start type and state.
        $script:ReadBack = @(foreach ($r in $script:ReadBack) {
                $name = $r.Id -replace '^Service:', ''
                $self = ($r.Id -like 'Service:*') -and @(@(Get-KnownGoodField -Entry $script:Kg['Services'][$name] -Name 'SelfSwitches') | Where-Object { $_ }).Count -gt 0
                if (-not $r.Match -and $self -and $r.Field -in @('StartType', 'State')) {
                    Write-ActionLog ("[NOTE] {0} {1} moved by itself during the dry run: {2} -> {3}" -f $r.Id, $r.Field, $r.Expected, $r.Actual)
                    $r | Add-Member -NotePropertyName Match -NotePropertyValue $true -Force
                }
                $r
            })
    }
    foreach ($r in @($script:ReadBack | Where-Object { -not $_.Match })) {
        Write-ActionLog ("[FAIL] read-back {0} {1}: expected {2}, found {3}" -f $r.Id, $r.Field, $r.Expected, $r.Actual)
    }
}

function Get-TimedItemState {
    <# Get-SimRigItemState with a log line before and after, so a slow or hung read shows in actions.log (a 2026-09-19 restore stopped here with no trace). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Item, [Parameter(Mandatory)] [string] $Label)
    Write-ActionLog ("reading {0} items ({1})" -f @($Item).Count, $Label)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $state = Get-SimRigItemState -QuietItem $Item
    Write-ActionLog ("read {0} items in {1:N1} s ({2})" -f @($state).Count, $sw.Elapsed.TotalSeconds, $Label)
    return , @($state)
}

function Select-ActionMachineItem {
    <#
        Blocker 5 (2026-10-02). The quiet items that apply to this PC, decided here in
        the process that writes. It reads the machine and the profile with the
        function the console uses (Get-SimRigMachineContext) and filters with the
        function the console uses (Select-QuietItemForMachine).

        A profile folder that does not load stops the run: with no profile the filter
        cannot say which PC this is, and the full list is not a safe answer.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Item)

    $profileLoad = Get-SimRigProfileDocument -Directory (Join-Path $PSScriptRoot 'profiles')
    $profileErrors = @($profileLoad.Error | Where-Object { $_ })
    if ($profileErrors.Count -gt 0 -or @($profileLoad.Document).Count -eq 0) {
        throw ('Profiles invalid, so the quiet list cannot be filtered for this PC: ' + ($profileErrors -join '; '))
    }
    $context = Get-SimRigMachineContext -ProfileDocument @($profileLoad.Document) -MachineName $env:COMPUTERNAME -Settings $null
    $kept = Select-QuietItemForMachine -QuietItem $Item -Machine $context.Machine
    $kept = @($kept)
    Write-ActionLog ('machine filter: profile {0}, {1} of {2} quiet items apply, machine reads unavailable: {3}' -f `
            [string](Get-KnownGoodField -Entry $context.Machine -Name 'Profile'), $kept.Count, @($Item).Count,
        $(if (@($context.Reading.Unavailable).Count -gt 0) { @($context.Reading.Unavailable) -join ', ' } else { 'none' }))
    return , $kept
}

function Select-ActionProfileItem {
    <#
        Blocker 5, Cowork ruling of 2026-10-02. The list of a restore that has no
        snapshot: each item that a quiet on this PC could have changed. It filters by
        the keys of the profile only (Select-QuietItemForProfile: the profile id and
        its Defender opt-in) and reads nothing of the machine but its name, so a reading
        that fails at restore time takes no item out.

        It never stops the restore. When the profile folder does not load, the items
        that name a profile are left out. It writes no text for the user: the Warn is
        made from the plan of the run (Invoke-RestoreOperation), because an id list
        can leave out none of these items. It sets $script:ProfileNotLoaded and
        $script:ProfileLeftOutId for that Warn.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Item)

    $profileId = $null
    $defenderOptIn = $false
    $profileLoad = Get-SimRigProfileDocument -Directory (Join-Path $PSScriptRoot 'profiles')
    $profileErrors = @($profileLoad.Error | Where-Object { $_ })
    $loaded = ($profileErrors.Count -eq 0 -and @($profileLoad.Document).Count -gt 0)
    if ($loaded) {
        $rigProfile = Select-SimRigProfile -RigProfile @($profileLoad.Document) -Machine @{ ComputerName = $env:COMPUTERNAME }
        if ($null -ne $rigProfile) {
            $profileId = [string](Get-KnownGoodField -Entry $rigProfile -Name 'Id')
            $defenderOptIn = [bool](Get-KnownGoodField -Entry (Get-KnownGoodField -Entry $rigProfile -Name 'Values') -Name 'DefenderOptIn')
        }
    }
    $kept = Select-QuietItemForProfile -QuietItem $Item -ProfileId $profileId -DefenderOptIn $defenderOptIn
    $kept = @($kept)
    Write-ActionLog ('profile filter: profile {0}, {1} of {2} quiet items' -f $(if ($profileId) { $profileId } else { 'none' }), $kept.Count, @($Item).Count)
    $script:ProfileNotLoaded = -not $loaded
    $script:ProfileLeftOutId = @()
    if (-not $loaded) {
        $keptId = @($kept | ForEach-Object { [string]$_.Id })
        $leftOutItem = @(@($Item) | Where-Object { [string]$_.Id -notin $keptId })
        # Only the items that a restore can act on: Get-RestorePlan makes no step for a
        # process item (VERDICT-qfilter-4c2ec24.md, answer 2).
        $script:ProfileLeftOutId = @($leftOutItem | Where-Object { [string]$_.Kind -ne 'Process' } | ForEach-Object { [string]$_.Id })
        Write-ActionLog ('[WARN] profiles not loaded - {0} item(s) of the list are for one profile: {1}' -f $leftOutItem.Count, ($profileErrors -join '; '))
    }
    return , $kept
}

function Test-ActionTuningAllowed {
    <#
        Blocker 4, push 1 of the unit tune (amendments 8 and 9). ApplyTuning,
        UndoTuning and FixGpu write the values of known-good.psd1, the values of the
        rig. So they run only where the selected profile has the key
        Values.TuningFromKnownGood. Only the profile of the rig has it, and that
        profile never leaves the private repo. The child decides, from the profile
        that it selects itself by the computer name, with the same function as the
        console: a refusal that is only in the window is not a refusal (amendment 7a).

        A profile folder that does not load gives no profile, so no tuning.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $profileLoad = Get-SimRigProfileDocument -Directory (Join-Path $PSScriptRoot 'profiles')
    $profileErrors = @($profileLoad.Error | Where-Object { $_ })
    $profileId = 'none'
    $allowed = $false
    if ($profileErrors.Count -eq 0 -and @($profileLoad.Document).Count -gt 0) {
        $rigProfile = Select-SimRigProfile -RigProfile @($profileLoad.Document) -Machine @{ ComputerName = $env:COMPUTERNAME }
        if ($null -ne $rigProfile) {
            $profileId = [string](Get-KnownGoodField -Entry $rigProfile -Name 'Id')
            $allowed = Test-ProfileTuningAllowed -RigProfile $rigProfile
        }
    }
    Write-ActionLog ('tuning: profile {0}, tuning {1}' -f $profileId, $(if ($allowed) { 'allowed' } else { 'refused' }))
    return $allowed
}

function Get-ActionTuningSupport {
    <#
        Push 2 of the unit tune, step 4 (design section 6, amendment 8 condition 4). The tuning state
        that the child decides for itself: Rig by Test-ActionTuningAllowed, as before; on each other
        PC the child reads the machine and selects the profile itself (Get-SimRigMachineContext, as for
        Quiet) and calls Get-SimRigTuningSupport. It does not take a state or a value from the console.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if (Test-ActionTuningAllowed) { return [pscustomobject]@{ State = 'Rig'; Reason = $null; RigProfile = $null; Machine = $null } }
    $profileLoad = Get-SimRigProfileDocument -Directory (Join-Path $PSScriptRoot 'profiles')
    if (@($profileLoad.Error | Where-Object { $_ }).Count -gt 0 -or @($profileLoad.Document).Count -eq 0) {
        $none = Get-SimRigTuningSupport -Machine $null -RigProfile $null
        return [pscustomobject]@{ State = $none.State; Reason = $none.Reason; RigProfile = $null; Machine = $null }
    }
    $context = Get-SimRigMachineContext -ProfileDocument @($profileLoad.Document) -MachineName $env:COMPUTERNAME -Settings $null
    $support = Get-SimRigTuningSupport -Machine $context.Machine -RigProfile $context.RigProfile
    return [pscustomobject]@{ State = $support.State; Reason = $support.Reason; RigProfile = $context.RigProfile; Machine = $context.Machine }
}

function Invoke-RestoreOperation {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Item, [Parameter(Mandatory)] [hashtable] $KnownGood, [string[]] $Only)

    $marker = Read-SimRigJson -Path $script:Paths.ActiveMarker
    if ($null -eq $marker) {
        if ($Operation -eq 'Deadman') {
            Write-ActionLog 'no unrestored session - nothing to do'
            $status = Unregister-SimRigDeadman -WhatIf:$script:IsWhatIf
            Write-ActionLog ("[{0}] deadman removed (no session)" -f $status)
            return
        }
        if ($Operation -eq 'Undo') {
            $script:Errors.Add('Nothing to undo: no active v4 session. Windows was already restored.')
            $script:ExitCode = $script:Codes.Done
            return
        }
    }
    $snapshot = $null
    # Set when there is no snapshot: the count of the quiet list before the profile filter.
    $listCount = $null
    # Blocker 7 (O2), Restore as (b) (Rick, 2026-10-08): the snapshot path of the marker is checked as the tuning
    # record is (the two fixed roots, the names, snapshot.json, the link check), before it is read. A path that the
    # check refuses is not read, and Restore uses the defaults of the quiet list, as for a missing snapshot.
    $snapshotRefused = $null
    if ($null -ne $marker) {
        $script:SnapshotPath = $marker.SnapshotPath
        if (-not $SessionDir) { $script:SessionDirOut = $marker.SessionDir }
        $markerSnapshot = [string](Get-KnownGoodField -Entry $marker -Name 'SnapshotPath')
        $snapshotRoots = @($script:Paths.Sessions, ($script:Paths.Logs + '\selftest'))
        if ([string]::IsNullOrWhiteSpace($markerSnapshot)) { $snapshot = $null }
        elseif (-not (Test-SimRigTuningRecordPath -Path $markerSnapshot -Sessions $snapshotRoots -FileName 'snapshot.json') -or
            $null -ne (Find-SimRigPathLink -Root $script:Paths.Root -Path $markerSnapshot)) {
            $snapshotRefused = $markerSnapshot
            Write-ActionLog ('[WARN] snapshot path refused, not read: {0}' -f $markerSnapshot)
        }
        else { $snapshot = Read-SimRigJson -Path $markerSnapshot }
    }
    if ($null -eq $snapshot) {
        # Spec 8.1: hardcoded defaults are a fallback only. Say so loudly.
        if ($null -ne $snapshotRefused) {
            # Text R1 (Rick's "Yes", 2026-10-08).
            $script:Errors.Add(('Restore did not read the snapshot that the session marker names ({0}): it is not in the sessions folder of the app, or a link or a folder that cannot be read is on its path. Restored from the defaults of the quiet list, not from the real prior state.' -f $snapshotRefused))
        }
        else { $script:Errors.Add('Snapshot missing or unreadable - restored from the quiet list Fallback defaults, not from the real prior state.') }
        Write-ActionLog '[WARN] snapshot missing - fallback defaults used'
        # Blocker 5. With no snapshot the defaults go to each item that a quiet on this
        # PC could have changed: the items of its profile, with no reading of the
        # machine. With a snapshot the snapshot decides (below).
        # Assign, then wrap: the function returns the comma form.
        $listCount = @($Item).Count
        $profileItems = Select-ActionProfileItem -Item $Item
        $Item = @($profileItems)
    }
    else {
        # Flag 16. A snapshot is the only record of the prior state, so a shape this
        # app does not understand stops the restore. Reading it anyway and putting
        # back whatever came out is worse than refusing and saying why.
        $schema = Get-SimRigSchemaVerdict -Found ([string](Get-KnownGoodField -Entry $snapshot -Name 'Schema')) -Expected 'simrig.snapshot/1'
        if (-not $schema.Ok) {
            $script:Errors.Add(('Refused: ' + $schema.Reason))
            Write-ActionLog ('[FAIL] snapshot schema: {0}' -f $schema.Reason)
            $script:ExitCode = $script:Codes.Refused
            return
        }
        if ($schema.Verdict -eq 'Note') { Write-ActionLog ('[NOTE] snapshot schema: {0}' -f $schema.Reason) }
    }

    # Restore what this session quieted, not the whole list. Since the user's
    # ticks decide what Quiet writes, a snapshot can hold a subset, and judging
    # the untouched items against a snapshot that never mentions them turns every
    # partial session red for nothing. Without a snapshot the list is all there
    # is, so it stays whole.
    if ($null -ne $snapshot) {
        $snapId = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($si in @($snapshot.Items)) { if ($null -ne $si) { [void]$snapId.Add([string]$si.Id) } }
        $narrowed = @($Item | Where-Object { $snapId.Contains([string]$_.Id) })
        if ($narrowed.Count -gt 0 -and $narrowed.Count -lt @($Item).Count) {
            # A line about the list, not about the run: with an id list the plan has
            # fewer items (Cowork, answer to the questions at 327e890).
            Write-ActionLog ("the snapshot names {0} of the {1} item(s) in the list" -f $narrowed.Count, @($Item).Count)
            $Item = $narrowed
        }
    }

    $current = Get-TimedItemState -Item $Item -Label 'before restore'
    $byId = @{}
    foreach ($i in $Item) { $byId[$i.Id] = $i }
    $plan = if ($Only) { Get-RestorePlan -QuietItem $Item -Snapshot $snapshot -Current $current -Only $Only }
    else { Get-RestorePlan -QuietItem $Item -Snapshot $snapshot -Current $current }
    if ($null -ne $listCount) {
        # The window shows the count of a quiet. A restore with no snapshot acts on
        # another count, so the result says it. The count is the count of the items
        # that have a step in the plan: not of a list. A restore has no step for a
        # process item, and Fix has steps for the named ids only (REVIEW at 5560c6e,
        # finding 1).
        $planId = @(@($plan) | ForEach-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Id') } | Where-Object { $_ } | Sort-Object -Unique)
        if ($script:ProfileNotLoaded) {
            # A text about what this run did is made from its plan (Cowork, answer to
            # the questions at 327e890). With an id list, an item is left out of this
            # run only when the list names it. The Defender sentence is there only
            # when the plan has a Defender step.
            $leftOutId = @($script:ProfileLeftOutId | Where-Object { -not $Only -or $Only -contains $_ })
            $warn = if ($leftOutId.Count -gt 0) {
                'Warn: the profiles did not load, so {0} item(s) that are for one profile were left out of this restore.' -f $leftOutId.Count
            }
            else { 'Warn: the profiles did not load.' }
            # A step that writes: a Skip step has the kind Defender also
            # (VERDICT-qfilter-4c2ec24.md, finding 4).
            if (@(@($plan) | Where-Object { [string](Get-KnownGoodField -Entry $_ -Name 'Kind') -eq 'Defender' -and [string](Get-KnownGoodField -Entry $_ -Name 'Op') -ne 'Skip' }).Count -gt 0) {
                $warn += ' Defender real-time protection is part of this restore.'
            }
            $script:Errors.Add($warn)
            Write-ActionLog ('[WARN] profiles not loaded - {0} item(s) for one profile left out of this run' -f $leftOutId.Count)
        }
        $script:Errors.Add(('The fallback defaults went to {0} of the {1} items of the quiet list.' -f $planId.Count, $listCount))
    }
    $stepsBefore = $script:Steps.Count
    foreach ($step in @($plan)) {
        $script:Steps.Add((Invoke-SimRigStep -Step $step -ItemById $byId))
    }

    $after = Get-TimedItemState -Item $Item -Label 'restore read-back'
    # RF-2: the step status from the value that was read.
    Confirm-SimRigStepReadBack -From $stepsBefore -State $after -Plan @($plan)
    if ($null -ne $snapshot) {
        $expected = @($snapshot.Items | Where-Object { $_.Kind -ne 'Process' })
        $script:ReadBack = @(Compare-ItemState -QuietItem $Item -Expected $expected -Actual $after)
        foreach ($r in @($script:ReadBack | Where-Object { -not $_.Match })) {
            Write-ActionLog ("[NOTE] read-back {0} {1}: snapshot {2}, now {3} (the verdict decides)" -f $r.Id, $r.Field, $r.Expected, $r.Actual)
        }
    }
    $bbBefore = $null
    if ($null -ne $marker -and $marker.PSObject.Properties.Name -contains 'BackblazeLastBackup' -and $marker.BackblazeLastBackup) {
        $bbBefore = [datetime]::Parse($marker.BackblazeLastBackup, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $bbAfter = Get-SimRigBackblazeLastBackup
    # RF-1. What the quiet of this session did. $null when no record can be used:
    # then the verdict has no "refused by Windows" state. A restore step is not
    # appended to the record: it writes the snapshot value, so it cannot make an
    # item differ from the snapshot.
    $quietStep = Read-SimRigQuietRecord -Marker $marker
    $script:Verdict = Get-HealthyVerdict -QuietItem $Item -Snapshot $snapshot -Current $after `
        -Backblaze @{ BeforeLastBackup = $bbBefore; AfterLastBackup = $bbAfter } -KnownGood $KnownGood -Now (Get-Date) -QuietStep $quietStep
    Write-ActionLog ("verdict: {0}" -f $script:Verdict.Line)
    foreach ($w in @($script:Verdict.Warnings)) { Write-ActionLog ("[WARN] {0}" -f $w) }

    if ($script:Verdict.Green -and $script:KeepMarker) {
        # Green over the items it could reach is not the same as finished. Clearing
        # the marker here would close a session whose per-user half never ran, and
        # nothing would ever come back for it.
        Write-ActionLog '[WARN] verdict is green but items were skipped - marker and deadman kept so the next sign-in finishes it'
        if ($script:ExitCode -eq $script:Codes.Done) { $script:ExitCode = $script:Codes.StepFailed }
    }
    elseif ($script:Verdict.Green -and -not $script:IsWhatIf) {
        # A green restore ends the session: remove the marker, then the deadman task.
        Remove-Item -LiteralPath $script:Paths.ActiveMarker -Force -ErrorAction SilentlyContinue -WhatIf:$false
        $status = Unregister-SimRigDeadman
        Write-ActionLog ("[{0}] marker cleared, deadman removed" -f $status)
    }
    elseif (-not $script:Verdict.Green) {
        Write-ActionLog '[FAIL] restore is not green - marker and deadman kept so Fix and the next sign-in can finish it'
    }
}

function Restart-SimRigDevice {
    <# Restarts one PnP device with pnputil so its driver re-reads the interrupt policy. The display goes black for a few seconds. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $InstanceId)
    if (-not $PSCmdlet.ShouldProcess($InstanceId, 'restart device')) { return 'WhatIf' }
    $out = & pnputil.exe /restart-device $InstanceId 2>&1
    $code = $LASTEXITCODE
    $text = (($out | Out-String) -replace '\s+', ' ').Trim()
    # Flag 7: exit 3010, or text that says the SYSTEM still needs a restart, is
    # RestartNeeded and a Warn. It is never reported as Done. The match is on
    # the phrases that ask for a reboot, not on the word "restart" alone:
    # pnputil says "Restarted device successfully" on the happy path.
    if ($code -eq 3010 -or $text -match 'reboot|restart (the )?(system|computer|windows)|restart is required|must be restarted|requires a restart') {
        return 'RestartNeeded'
    }
    if ($code -ne 0) { throw ('pnputil /restart-device exit {0}: {1}' -f $code, $text) }
    return 'Done'
}

function Invoke-FixGpuOperation {
    <#
        v4.0.4 (Rick 2026-09-19): writes the known-good GPU interrupt steering
        (known-good.psd1 GpuSteering) to every PRESENT NVIDIA function whose
        policy is missing or different, then reads every one back. A Windows
        Update re-enumerated the PCI IDs that day and the policy was gone.
        Only the Affinity Policy key of those devices is touched. The new
        policy takes effect after a restart.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $KnownGood, [ValidateSet('Display', 'All')] [string] $Scope = 'Display')

    # All three blockers, not just iRacing (flag 7). A device restart takes the
    # screens down for a few seconds: doing that under a running capture spoils the
    # capture, and under OBS it spoils somebody's stream.
    $blocker = Test-TuningBlocker
    if ($blocker) {
        $script:Errors.Add(('Refused: {0}. Close it, then Fix GPU steering.' -f $blocker))
        $script:ExitCode = $script:Codes.Refused
        return
    }
    $vendor = [string]$KnownGood['GpuSteering'].VendorId
    [object[]]$targets = Get-GpuSteeringTarget -KnownGood $KnownGood -Affinity (Get-SimRigGpuAffinity -VendorId $vendor) -Scope $Scope
    Write-ActionLog ('GPU steering scope: {0}' -f $Scope)
    if ($targets.Count -eq 0) {
        $script:Errors.Add("No present $vendor device found - nothing to steer.")
        $script:ExitCode = $script:Codes.StepFailed
        return
    }
    $seq = 0
    foreach ($t in $targets) {
        $seq++
        $id = 'Gpu:{0}' -f $t.InstanceId
        $was = if ($null -eq $t.CurrentPolicy) { 'no policy' } else { 'DevicePolicy={0}, AssignmentSetOverride=0x{1:X}' -f $t.CurrentPolicy, [uint64]$t.CurrentMask }
        if (-not $t.InScope) {
            # Reported, never written. A function left out silently looks like a
            # function this app did not find.
            Write-ActionLog ('[SKIP] SetGpuAffinity {0} out of scope: {1}' -f $id, $t.ScopeWhy)
            $script:Steps.Add([pscustomobject]@{ Seq = $seq; Id = $id; Op = 'SetGpuAffinity'; Source = 'known-good'; Status = 'Skipped'
                    Message = ('out of scope: {0}; found DevicePolicy={1}' -f $t.ScopeWhy, $(if ($null -eq $t.CurrentPolicy) { 'none' } else { $t.CurrentPolicy })) })
            continue
        }
        if (-not $t.NeedsWrite) {
            Write-ActionLog ('[SKIP] SetGpuAffinity {0} already DevicePolicy={1}, AssignmentSetOverride=0x{2:X}' -f $id, $t.DevicePolicy, $t.Mask)
            $script:Steps.Add([pscustomobject]@{ Seq = $seq; Id = $id; Op = 'SetGpuAffinity'; Source = 'known-good'; Status = 'Skipped'; Message = 'already at target' })
            continue
        }
        $status = 'Failed'; $message = $null
        try {
            $a = Set-SimRigRegistryValue -Path $t.KeyPath -Value 'DevicePolicy' -Data $t.DevicePolicy -RegType 'DWord' -CreateKey $true -WhatIf:$script:IsWhatIf
            $b = Set-SimRigRegistryValue -Path $t.KeyPath -Value 'AssignmentSetOverride' -Data $t.Bytes -RegType 'Binary' -CreateKey $true -WhatIf:$script:IsWhatIf
            $status = if ($a -eq 'WhatIf' -or $b -eq 'WhatIf') { 'WhatIf' } else { 'Done' }
            $message = 'was {0}; set DevicePolicy={1}, AssignmentSetOverride=0x{2:X}' -f $was, $t.DevicePolicy, $t.Mask
        }
        catch {
            $message = ($_.Exception.Message -replace '\s+', ' ').Trim()
            if ($message -match 'Access is denied|registry access is not allowed') { $status = 'Refused' }
        }
        $tag = switch ($status) { 'Done' { '[OK]  ' } 'WhatIf' { '[WHATIF]' } 'Refused' { '[REFUSED]' } default { '[FAIL]' } }
        Write-ActionLog ('{0} SetGpuAffinity {1} {2}' -f $tag, $id, $message)
        $script:Steps.Add([pscustomobject]@{ Seq = $seq; Id = $id; Op = 'SetGpuAffinity'; Source = 'known-good'; Status = $status; Message = $message })
    }
    # v4.0.6: restart each written device so Windows applies the policy now. The
    # instance ID changed at every boot on the rig (2026-09-19), so a policy that
    # waits for a restart lands on an ID that is gone after it.
    foreach ($s in @($script:Steps | Where-Object { $_.Op -eq 'SetGpuAffinity' -and $_.Status -eq 'Done' })) {
        $seq++
        $inst = $s.Id -replace '^Gpu:', ''
        $status = 'Failed'; $message = $null
        try { $status = Restart-SimRigDevice -InstanceId $inst -WhatIf:$script:IsWhatIf; $message = 'device restarted - policy active now' }
        catch { $message = ($_.Exception.Message -replace '\s+', ' ').Trim() }
        $tag = switch ($status) { 'Done' { '[OK]  ' } 'WhatIf' { '[WHATIF]' } default { '[FAIL]' } }
        Write-ActionLog ('{0} RestartDevice {1} {2}' -f $tag, $s.Id, $message)
        $script:Steps.Add([pscustomobject]@{ Seq = $seq; Id = $s.Id; Op = 'RestartDevice'; Source = 'known-good'; Status = $status; Message = $message })
    }

    # Read every present device back, written or not.
    [object[]]$after = Get-GpuSteeringTarget -KnownGood $KnownGood -Affinity (Get-SimRigGpuAffinity -VendorId $vendor) -Scope $Scope
    $rb = foreach ($t in $after) {
        $actual = if ($null -eq $t.CurrentPolicy) { 'no policy' } else { 'DevicePolicy={0}, AssignmentSetOverride=0x{1:X}' -f $t.CurrentPolicy, [uint64]$t.CurrentMask }
        # An out-of-scope function has no expected value: nothing was written to it,
        # so comparing it against the known-good would report a failure for a
        # decision this app made on purpose.
        $expected = if ($t.InScope) { 'DevicePolicy={0}, AssignmentSetOverride=0x{1:X}' -f $t.DevicePolicy, $t.Mask } else { 'not written (out of scope)' }
        [pscustomobject]@{ Id = 'Gpu:{0}' -f $t.InstanceId; Field = 'AffinityPolicy'; Expected = $expected; Actual = $actual; Match = (-not $t.NeedsWrite) }
    }
    $script:ReadBack = @($rb)
    if ($script:IsWhatIf) { $script:ReadBack = @() }
    foreach ($r in @($script:ReadBack)) {
        Write-ActionLog ('{0} read-back {1}: expected {2}, found {3}' -f $(if ($r.Match) { '[OK]  ' } else { '[FAIL]' }), $r.Id, $r.Expected, $r.Actual)
    }
    if (-not $script:IsWhatIf -and @($script:Steps | Where-Object { $_.Op -eq 'RestartDevice' -and $_.Status -ne 'Done' }).Count -gt 0) {
        $script:Errors.Add('Policy written, but a device did not restart: restart Windows is NOT a fix here (the ID changes at boot) - tell Claude.')
    }
}

function Test-TuningBlocker {
    <#
        Flag 7: ApplyTuning refuses while iRacing, a CapFrameX capture or OBS
        runs. Returns the blocker text, or $null when nothing blocks.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($pair in @(
            @{ Process = 'iRacingSim64DX11'; Text = 'iRacing is running' },
            @{ Process = 'CapFrameX'; Text = 'a CapFrameX capture is running' },
            @{ Process = 'obs64'; Text = 'OBS is running' }
        )) {
        if (Get-Process -Name $pair.Process -ErrorAction SilentlyContinue) { return [string]$pair.Text }
    }
    return $null
}

function Set-SimRigPowerScheme {
    <# Makes one power scheme active. powercfg is the only supported way. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Guid)
    if (-not $PSCmdlet.ShouldProcess($Guid, 'set the active power scheme')) { return 'WhatIf' }
    $out = & powercfg.exe /setactive $Guid 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('powercfg /setactive exit {0}: {1}' -f $LASTEXITCODE, (($out | Out-String) -replace '\s+', ' ').Trim()) }
    return 'Done'
}

function Get-TuningFact {
    <# The readings the tuning plan needs. Read-only, through the Probe. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [hashtable] $KnownGood, [AllowNull()] [string] $GpuScope)
    $registry = @{}
    foreach ($r in @($KnownGood.Registry)) {
        $registry[('{0}\{1}' -f $r.Path, $r.Value)] = Get-SimRigRegistryValue -Path $r.Path -Value $r.Value
    }
    # Assign, then wrap: Get-SimRigGpuAffinity returns the comma form, so wrapping
    # the call put the device array inside a one-element array. Every later read of
    # $Fact.GpuAffinity then saw one row that was itself an array, and the tuning
    # screen's "Now" column for GPU steering said "no policy on any device" on a rig
    # that had one on both.
    $gpuAffinity = Get-SimRigGpuAffinity -VendorId ([string]$KnownGood.GpuSteering.VendorId)
    return @{
        Registry    = $registry
        PowerScheme = Get-SimRigPowerScheme
        GpuAffinity = @($gpuAffinity)
        # beta1-fix D-A: Get-TuningNowValue reads the functions of this scope only, as the writer.
        GpuScope    = $GpuScope
    }
}

# Find-SimRigPathLink is in SimRig.Probe.ps1 (blocker 7, commit 9): the window calls it too.

function Get-ActionTuningKnownItem {
    <#
        Blocker 6. The registry items that the app writes, for the row check of a tuning record
        (Find-SimRigTuningRecordBadRow): the items of known-good.psd1 and the items of the rules W-MPO and
        W-HAGS, each also in the G-12 form of the user hive. Each input is read from the program folder
        (condition A of 2026-10-07): known-good.psd1 is the caller's, the rules are under $PSScriptRoot.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $KnownGood)

    # Assign, then wrap: both functions return the comma form.
    $rigItems = Get-TuningItem -KnownGood $KnownGood
    $ruleLoad = Get-SimRigRuleDocument -Directory (Join-Path $PSScriptRoot 'rules')
    $rule = foreach ($doc in @($ruleLoad.Document)) { @(Get-KnownGoodField -Entry $doc -Name 'Rules') }
    $ruleItems = Get-SimRigTuningOffer -Support ([pscustomobject]@{ State = 'Supported' }) -Machine $null -Rule @($rule) -ProfileValues $null -KnownGood $KnownGood `
        -Fact @{ Registry = @{}; PowerScheme = $null; GpuAffinity = @() }
    [object[]]$known = @(@($rigItems) + @($ruleItems) | Where-Object { $null -ne $_ -and $_.Kind -eq 'Registry' })
    if ($script:UserSid) {
        $hive = Set-SimRigItemUserHive -Item $known -UserSid $script:UserSid
        [object[]]$known = @($known) + @($hive)
    }
    return , $known
}

function Get-ActionTuningPathRefusal {
    <#
        Blocker 6, texts 2, 3 and 5 (Rick's "Yes", 2026-10-07; text 5 in the form of Cowork). The refusal
        for the session folder of an elevated Apply or Undo (Dir), or for the path of the record
        (RecordPath), or $null. The path check first: a path that is not in the sessions folder gets text
        3 or text 2, and the link check does not run. Then the link check: a link gets text 5, with the
        item that is the link; an item in a folder that cannot be read gets text 6 (open row O8, Rick's
        "Yes", 2026-10-07), with that item. The cause NotRead for a path not under Root does not come here:
        the path check refuses each path that is not under the sessions folder first.
    #>
    [CmdletBinding()]
    param([string] $Dir, [string] $RecordPath)

    # Commit 8 (REVIEW-blocker6-994c5a7.md, finding 1; Rick's "Yes", 2026-10-07): two fixed roots, the
    # sessions folder and the folder of the self-test (SimRig.SelfTest.ps1, Get-SelfTestDir). Both are in
    # the data folder; the link check is the same for both.
    $roots = @($script:Paths.Sessions, ($script:Paths.Logs + '\selftest'))
    if ($Dir) {
        # Text 3.
        $text3 = 'Refused: the session folder {0} is not in the sessions folder of the app. Nothing was changed.' -f $Dir
        $probe = Join-Path -Path $Dir -ChildPath 'tuning-snapshot.json'
        if (-not (Test-SimRigTuningRecordPath -Path $probe -Sessions $roots)) { return $text3 }
        $link = Find-SimRigPathLink -Root $script:Paths.Root -Path $probe
        if ($null -ne $link) {
            # Text 5, the form for the session folder (no last sentence).
            if ($link.Cause -eq 'Link') { return ('Refused: {0} is a link, and the app does not use a path with a link in it. Nothing was changed. Remove the link and try again.' -f $link.Item) }
            # Text 6, the form for the session folder.
            return ('Refused: the app cannot check {0}, because Windows does not let it read the folder. Nothing was changed.' -f $link.Item)
        }
        # Blocker 7, commit 3 (the Cowork note of 2026-10-08 09:30, point 3): UNDO-BY-HAND.txt beside the record too.
        $undoLink = Find-SimRigPathLink -Root $script:Paths.Root -Path (Join-Path -Path $Dir -ChildPath 'UNDO-BY-HAND.txt')
        if ($null -ne $undoLink -and $undoLink.Cause -eq 'Link') { return ('Refused: {0} is a link, and the app does not use a path with a link in it. Nothing was changed. Remove the link and try again.' -f $undoLink.Item) }
    }
    if ($PSBoundParameters.ContainsKey('RecordPath')) {
        # Text 2.
        $text2 = 'Refused: the record of the last Apply is not a file in the sessions folder of the app ({0}). Nothing was changed. Do not run the commands in UNDO-BY-HAND.txt: they were made from this record.' -f $RecordPath
        if (-not (Test-SimRigTuningRecordPath -Path $RecordPath -Sessions $roots)) { return $text2 }
        $link = Find-SimRigPathLink -Root $script:Paths.Root -Path $RecordPath
        if ($null -ne $link) {
            # Text 5, the form for the record.
            if ($link.Cause -eq 'Link') { return ('Refused: {0} is a link, and the app does not use a path with a link in it. Nothing was changed. Remove the link and try again. Do not run the commands in UNDO-BY-HAND.txt: they were made from this record.' -f $link.Item) }
            # Text 6, the form for the record.
            return ('Refused: the app cannot check {0}, because Windows does not let it read the folder. Nothing was changed. Do not run the commands in UNDO-BY-HAND.txt: they were made from this record.' -f $link.Item)
        }
        # Blocker 7, commit 3: UNDO-BY-HAND.txt beside the record (point 3). Text 5, the form for the record.
        $undoLink = Find-SimRigPathLink -Root $script:Paths.Root -Path (Join-Path -Path (Split-Path -Path $RecordPath -Parent) -ChildPath 'UNDO-BY-HAND.txt')
        if ($null -ne $undoLink -and $undoLink.Cause -eq 'Link') { return ('Refused: {0} is a link, and the app does not use a path with a link in it. Nothing was changed. Remove the link and try again. Do not run the commands in UNDO-BY-HAND.txt: they were made from this record.' -f $undoLink.Item) }
    }
    return $null
}

function Get-ActionTuningRowRefusal {
    <#
        Blocker 6, text 1 (Rick's "Yes", 2026-10-07). The refusal for a record with a row that the app
        does not write on this PC, or $null. Each row is checked before the first write, on the copy in
        memory that the caller then uses (condition B).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Record, [Parameter(Mandatory)] [string] $RecordPath, [Parameter(Mandatory)] [hashtable] $KnownGood)

    $known = Get-ActionTuningKnownItem -KnownGood $KnownGood
    $bad = Find-SimRigTuningRecordBadRow -Record $Record -Known $known
    if ($bad -eq 0) { return $null }
    # Text 1.
    return ('Refused: the record of the last Apply ({0}) has row {1}, which this app does not write on this PC. Nothing was changed. Do not run the commands in UNDO-BY-HAND.txt: they were made from this record.' -f $RecordPath, $bad)
}

function Invoke-ApplyTuningOperation {
    <#
        v4.1: writes the persistent tuning values from known-good.psd1 - MPO,
        HAGS, the power plan and the GPU interrupt steering. Opt-in per item
        through -Only, and the console asks twice before it calls this (flag 7).

        A snapshot is written before the first write, so UndoTuning can put
        every value back. GPU steering goes through Invoke-FixGpuOperation, so
        there is one writer for that policy and not two.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $KnownGood,
        [string[]] $Only,
        [switch] $Force,
        # Push 2 of the unit tune, step 4: on a supported PC, the items that the child made itself
        # (Select-SimRigTuningRequest). With none, the items of known-good.psd1, as on the rig.
        [object[]] $Item
    )

    $blocker = Test-TuningBlocker
    if ($blocker) {
        $script:Errors.Add(('Refused: {0}. Close it, then apply tuning.' -f $blocker))
        $script:ExitCode = $script:Codes.Refused
        return
    }

    # Blocker 6: the session folder of the command line is checked before any read or write.
    $dir = if ($SessionDir) { $SessionDir } else { $script:Paths.Sessions }
    $pathRefusal = Get-ActionTuningPathRefusal -Dir $dir
    if ($pathRefusal) {
        $script:Errors.Add($pathRefusal)
        $script:ExitCode = $script:Codes.Refused
        return
    }

    $fact = Get-TuningFact -KnownGood $KnownGood -GpuScope $GpuScope
    # By the bound parameter: @($null).Count is 1, so a count does not show that no item was given.
    if ($PSBoundParameters.ContainsKey('Item')) { [object[]]$items = $Item } else { [object[]]$items = Get-TuningItem -KnownGood $KnownGood }
    # G-12: Auto HDR and both Game Bar values are HKCU items.
    if ($script:UserSid) { [object[]]$items = Set-SimRigItemUserHive -Item $items -UserSid $script:UserSid }
    [object[]]$plan = Get-TuningPlan -Item $items -Fact $fact -Only $Only -Force:$Force
    if ($plan.Count -eq 0) {
        $script:Errors.Add('No tuning item matched - nothing to apply.')
        $script:ExitCode = $script:Codes.BadArgument
        return
    }

    # Push 2 of the unit tune, step 5 (design section 5): with a marker, its snapshot is the snapshot
    # of record, and this Apply adds only the items that are not in it yet. The repair after the REVIEW
    # at 20405c6 (Causes row 12): a marker file that is there, with a marker or a record that cannot be
    # read, is refused with text C before any write. A new record there wrote over the values from
    # before the first Apply.
    $markerFilePresent = Test-Path -LiteralPath $script:Paths.TuningMarker
    $tuningMarker = $null
    $record = $null
    if ($markerFilePresent) {
        $tuningMarker = Read-SimRigJson -Path $script:Paths.TuningMarker
        $recordPath = if ($null -ne $tuningMarker) { [string](Get-KnownGoodField -Entry $tuningMarker -Name 'SnapshotPath') } else { '' }
        # Blocker 6: the path of the marker before the read (text 2).
        if ($recordPath) {
            $pathRefusal = Get-ActionTuningPathRefusal -RecordPath $recordPath
            if ($pathRefusal) {
                $script:Errors.Add($pathRefusal)
                $script:ExitCode = $script:Codes.Refused
                return
            }
            $record = Read-SimRigJson -Path $recordPath
        }
        if ($null -eq $record) {
            $unreadable = if ($recordPath) { $recordPath } else { $script:Paths.TuningMarker }
            # Text C of PUSH2-TEXTS-ADDED-2026-10-04.md (Rick's "Yes", 2026-10-04). Its second sentence
            # changed by blocker 6, open row O6 (Rick's "Yes", 2026-10-07): the file is in a folder that
            # another program can write, so the text does not tell the user to trust it. Commit 7 (Rick's
            # "Yes", 2026-10-07, the form of Cowork): the old sentence stays, and the warning follows it.
            $script:Errors.Add(('Refused: Apply tuning cannot read the record of the last Apply ({0}). Nothing was changed. The file UNDO-BY-HAND.txt in the same folder has the commands to undo it by hand. Read each line before you run it: another program can change that file. After that, delete {1}, and Apply tuning works again.' -f $unreadable, $script:Paths.TuningMarker))
            $script:ExitCode = $script:Codes.Refused
            return
        }
        # Blocker 6: each row of the one copy that this Apply merges and writes (text 1). The rows go
        # into UNDO-BY-HAND.txt, a file for a Command Prompt as administrator.
        $rowRefusal = Get-ActionTuningRowRefusal -Record $record -RecordPath $recordPath -KnownGood $KnownGood
        if ($rowRefusal) {
            $script:Errors.Add($rowRefusal)
            $script:ExitCode = $script:Codes.Refused
            return
        }
    }

    # The snapshot covers every item, not only the ones being written: an Undo
    # after two partial applies still has one document to replay.
    $snapshot = Build-TuningSnapshot -Item $items -Fact $fact -TakenAt (Get-Date) -SessionId ([string]$RequestId)
    $snapshotPath = if ($null -ne $record) { $recordPath } else { Join-Path -Path $dir -ChildPath 'tuning-snapshot.json' }
    if (-not $script:IsWhatIf) {
        # Blocker 7, commit 8, part (a): each final name of this Apply before its first step. The writes after the
        # registry writes (the snapshot, the marker, the two files UNDO-BY-HAND.txt) then refuse only in a race (5b).
        $finalRefusal = Get-ActionFinalNameRefusal -Path @($snapshotPath, (Join-Path -Path (Split-Path -Path $snapshotPath -Parent) -ChildPath 'UNDO-BY-HAND.txt'),
            $script:Paths.TuningUndoByHand, $script:Paths.TuningMarker)
        if ($finalRefusal) {
            $script:Errors.Add($finalRefusal)
            $script:ExitCode = $script:Codes.Refused
            return
        }
    }
    Initialize-ActionFolder -Folder @($dir)
    $snapshot = Merge-SimRigTuningSnapshot -Record $record -New $snapshot
    if (-not $script:IsWhatIf) {
        Write-JsonFileAtomic -Path $snapshotPath -InputObject $snapshot
        $script:SnapshotPath = $snapshotPath
        Write-ActionLog ('[OK]   tuning snapshot -> {0}' -f $snapshotPath)
        # Step 6: UNDO-BY-HAND.txt before the first write, with the items that this Apply is about to
        # write and the items that an Apply before it wrote.
        $writeId = @(@($plan) | Where-Object { $_.Op -ne 'Skip' } | ForEach-Object { [string]$_.Id })
        Write-UndoByHandFile -SnapshotPath $snapshotPath -Text (Build-SimRigUndoByHandText -Snapshot $snapshot -SnapshotPath $snapshotPath -WrittenAt (Get-Date) -WriteId $writeId)
        Write-ActionLog ('[OK]   UNDO-BY-HAND.txt -> beside the snapshot, and {0}' -f $script:Paths.TuningUndoByHand)
    }

    $seq = 0
    foreach ($step in $plan) {
        $seq++
        if ($step.Op -eq 'Skip') {
            Write-ActionLog ('[SKIP] {0} {1}' -f $step.Id, $step.Reason)
            $script:Steps.Add([pscustomobject]@{ Seq = $seq; Id = $step.Id; Op = 'Skip'; Source = 'tuning'; Status = 'Skipped'; Message = $step.Reason })
            continue
        }
        if ($step.Kind -eq 'GpuSteering') {
            Write-ActionLog '[INFO] GPU steering goes through the FixGpu writer'
            Invoke-FixGpuOperation -KnownGood $KnownGood -Scope $GpuScope
            continue
        }
        $status = 'Failed'; $message = $null
        try {
            if ($step.Kind -eq 'Registry') {
                $status = Set-SimRigRegistryValue -Path $step.Arg.Path -Value $step.Arg.Value -Data $step.Arg.Data `
                    -RegType $step.Arg.RegType -CreateKey $true -WhatIf:$script:IsWhatIf
            } else {
                $status = Set-SimRigPowerScheme -Guid $step.Target -WhatIf:$script:IsWhatIf
            }
            $message = 'was {0}; set {1}' -f $(if ($null -eq $step.Now) { 'not set' } else { $step.Now }), $step.Target
            if ($step.RestartNeeded -and $status -eq 'Done') { $message += '; needs a Windows restart to take effect' }
        }
        catch {
            $message = ($_.Exception.Message -replace '\s+', ' ').Trim()
            if ($message -match 'Access is denied|registry access is not allowed') { $status = 'Refused' }
        }
        $tag = switch ($status) { 'Done' { '[OK]  ' } 'WhatIf' { '[WHATIF]' } 'Refused' { '[REFUSED]' } default { '[FAIL]' } }
        Write-ActionLog ('{0} {1} {2} {3}' -f $tag, $step.Op, $step.Id, $message)
        $script:Steps.Add([pscustomobject]@{ Seq = $seq; Id = $step.Id; Op = $step.Op; Source = 'tuning'; Status = $status; Message = $message })
    }

    # Push 2 of the unit tune, step 5: the snapshot of record keeps what this Apply wrote, and the
    # marker names it, so that Undo works after the app is closed.
    if (-not $script:IsWhatIf) {
        $doneId = @(@($script:Steps) | Where-Object { $_.Source -eq 'tuning' -and $_.Status -eq 'Done' } | ForEach-Object { [string]$_.Id })
        $snapshot = Set-SimRigTuningWrote -Snapshot $snapshot -Item $items -DoneId $doneId
        Write-JsonFileAtomic -Path $snapshotPath -InputObject $snapshot
        # The marker before the second write of the two files (the repair after the REVIEW at 20405c6,
        # finding 19): a file that cannot be written then does not leave written values with no marker.
        if (-not $markerFilePresent -and $doneId.Count -gt 0) {
            Write-JsonFileAtomic -Path $script:Paths.TuningMarker -InputObject (Build-SimRigTuningMarker -SnapshotPath $snapshotPath -AppliedAt (Get-Date))
            Write-ActionLog ('[OK]   tuning marker -> {0}' -f $script:Paths.TuningMarker)
        }
        # Step 6: the two files again, now with the items that an Apply wrote (Wrote), not the items
        # that this Apply was about to write.
        Write-UndoByHandFile -SnapshotPath $snapshotPath -Text (Build-SimRigUndoByHandText -Snapshot $snapshot -SnapshotPath $snapshotPath -WrittenAt (Get-Date) -WriteId @())
        if (-not $markerFilePresent -and $doneId.Count -eq 0) {
            # Step 6, the rule of Claude Code (accepted by Cowork with the repair of finding 12, Causes
            # row 11): no marker file and no value written, so there is nothing to undo, and a copy in
            # Logs\v4 would tell a user to undo values that nobody changed.
            # beta1-fix D-C: the copy beside the snapshot too. With no value written it has the header lines
            # only ("run each line below", and no line), and the window listed it as a row (beta.1 rig run).
            # beta1-fix2 E-1' (Rick "E1 keep"): a run can write GPU steering here (the FixGpu writer, Source known-good),
            # which Undo does not put back, so the log names the tuning values only.
            Remove-Item -LiteralPath $script:Paths.TuningUndoByHand -Force
            Write-ActionLog ('[OK]   no tuning value for Undo tuning written: removed {0}' -f $script:Paths.TuningUndoByHand)
            $besideHandFile = Join-Path -Path (Split-Path -Path $snapshotPath -Parent) -ChildPath 'UNDO-BY-HAND.txt'
            Remove-Item -LiteralPath $besideHandFile -Force
            Write-ActionLog ('[OK]   no tuning value for Undo tuning written: removed {0}' -f $besideHandFile)
        }
    }

    # Read back each item of the plan, written or not. Push 2 of the unit tune, step 5b: not the items
    # that -Only left out. What a run says about itself is made from the plan of that run (the Cowork
    # rule of 2026-10-02); before, an Apply of some ticked items failed when an item that was not
    # ticked was not at its value.
    if (-not $script:IsWhatIf) {
        $after = Get-TuningFact -KnownGood $KnownGood -GpuScope $GpuScope
        $planId = @(@($plan) | ForEach-Object { [string]$_.Id })
        $rows = foreach ($it in $items) {
            if ($planId -notcontains [string]$it.Id) { continue }
            $actual = Get-TuningNowValue -Item $it -Fact $after
            [pscustomobject]@{
                Id       = 'Tuning:{0}' -f $it.Id
                Field    = $it.Kind
                Expected = [string]$it.Target
                Actual   = $(if ($null -eq $actual) { 'not set' } else { [string]$actual })
                Match    = ($null -ne $actual -and [string]$actual -eq [string]$it.Target)
            }
        }
        $script:ReadBack = @(@($script:ReadBack) + @($rows) | Where-Object { $null -ne $_ })
        foreach ($r in @($rows)) {
            Write-ActionLog ('{0} read-back {1}: expected {2}, found {3}' -f $(if ($r.Match) { '[OK]  ' } else { '[FAIL]' }), $r.Id, $r.Expected, $r.Actual)
        }
    }
}

function Invoke-UndoTuningOperation {
    <#
        v4.1: puts every tuning value back to its snapshot. A value that was
        not set before is removed, not written as a zero. GPU steering is left
        alone: the policy is what the rig needs, and removing it would need
        another device restart.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $KnownGood,
        [string[]] $Only
    )

    $blocker = Test-TuningBlocker
    if ($blocker) {
        $script:Errors.Add(('Refused: {0}. Close it, then undo tuning.' -f $blocker))
        $script:ExitCode = $script:Codes.Refused
        return
    }

    # Push 2 of the unit tune, step 5 (design section 5): with a marker, its snapshot of record is the
    # one to undo, also with no session folder and after the app was closed. A marker or a snapshot of
    # record that cannot be read: text 52, and nothing is written.
    # Blocker 6: the session folder of the command line (text 3), and below, the path of the record
    # before its one read (text 2) and each of its rows before the first write (text 1).
    $dir = if ($SessionDir) { $SessionDir } else { $script:Paths.Sessions }
    $pathRefusal = Get-ActionTuningPathRefusal -Dir $dir
    if ($pathRefusal) {
        $script:Errors.Add($pathRefusal)
        $script:ExitCode = $script:Codes.Refused
        return
    }
    $markerPresent = Test-Path -LiteralPath $script:Paths.TuningMarker
    if ($markerPresent) {
        $tuningMarker = Read-SimRigJson -Path $script:Paths.TuningMarker
        $recordPath = if ($null -ne $tuningMarker) { [string](Get-KnownGoodField -Entry $tuningMarker -Name 'SnapshotPath') } else { '' }
        if ($recordPath) {
            $pathRefusal = Get-ActionTuningPathRefusal -RecordPath $recordPath
            if ($pathRefusal) {
                $script:Errors.Add($pathRefusal)
                $script:ExitCode = $script:Codes.Refused
                return
            }
        }
        $snapshot = if ($recordPath) { Read-SimRigJson -Path $recordPath } else { $null }
        if ($null -eq $snapshot) {
            $unreadable = if ($recordPath) { $recordPath } else { $script:Paths.TuningMarker }
            # Text 52; its last sentence changed by blocker 6, open row O6 (Rick's "Yes", 2026-10-07).
            $script:Errors.Add(('Undo tuning cannot read the record of the last Apply ({0}). Nothing was changed. The file UNDO-BY-HAND.txt in the same folder has the commands to undo it by hand. Read each line before you run it: another program can change that file.' -f $unreadable))
            $script:ExitCode = $script:Codes.BadArgument
            return
        }
        $snapshotPath = $recordPath
    }
    else {
        $snapshotPath = Join-Path -Path $dir -ChildPath 'tuning-snapshot.json'
        if (-not (Test-Path -LiteralPath $snapshotPath)) {
            $script:Errors.Add(('No tuning snapshot at {0} - there is nothing to undo.' -f $snapshotPath))
            $script:ExitCode = $script:Codes.BadArgument
            return
        }
        $snapshot = Read-SimRigJson -Path $snapshotPath
        if ($null -eq $snapshot) {
            $script:Errors.Add(('{0} could not be read as JSON.' -f $snapshotPath))
            $script:ExitCode = $script:Codes.BadArgument
            return
        }
    }
    # Flag 16, same rule as the session snapshot: an older shape this app lists is
    # read with a note, anything else is refused with a sentence that names both
    # versions. The old check said only "is not a simrig.tuning-snapshot/1
    # document", which is true of a file from a newer app and tells the user
    # nothing about what to do next.
    $tuningSchema = Get-SimRigSchemaVerdict -Found ([string](Get-KnownGoodField -Entry $snapshot -Name 'Schema')) -Expected 'simrig.tuning-snapshot/1'
    if (-not $tuningSchema.Ok) {
        $script:Errors.Add(('Refused: ' + $tuningSchema.Reason))
        Write-ActionLog ('[FAIL] tuning snapshot schema: {0}' -f $tuningSchema.Reason)
        $script:ExitCode = $script:Codes.BadArgument
        return
    }
    if ($tuningSchema.Verdict -eq 'Note') { Write-ActionLog ('[NOTE] tuning snapshot schema: {0}' -f $tuningSchema.Reason) }
    $rowRefusal = Get-ActionTuningRowRefusal -Record $snapshot -RecordPath $snapshotPath -KnownGood $KnownGood
    if ($rowRefusal) {
        $script:Errors.Add($rowRefusal)
        $script:ExitCode = $script:Codes.Refused
        return
    }
    $script:SnapshotPath = $snapshotPath

    # The values now: an item that is not at the value that Apply wrote is left as it is (text 50).
    $undoFact = Get-TuningFact -KnownGood $KnownGood
    [object[]]$plan = Get-TuningUndoPlan -Snapshot $snapshot -Only $Only -Fact $undoFact
    $seq = 0
    foreach ($step in $plan) {
        $seq++
        if ($step.Op -eq 'Skip' -or $step.Op -eq 'Unknown') {
            Write-ActionLog ('[SKIP] {0} {1}' -f $step.Id, $step.Reason)
            $script:Steps.Add([pscustomobject]@{ Seq = $seq; Id = $step.Id; Op = 'Skip'; Source = 'tuning-undo'; Status = 'Skipped'; Message = $step.Reason })
            continue
        }
        $status = 'Failed'; $message = $null
        try {
            if ($step.Op -eq 'RemoveRegistryValue') {
                $status = Remove-SimRigRegistryValue -Path $step.Arg.Path -Value $step.Arg.Value -WhatIf:$script:IsWhatIf
            } elseif ($step.Op -eq 'SetRegistryValue') {
                $status = Set-SimRigRegistryValue -Path $step.Arg.Path -Value $step.Arg.Value -Data $step.Arg.Data `
                    -RegType $step.Arg.RegType -CreateKey $true -WhatIf:$script:IsWhatIf
            } else {
                $status = Set-SimRigPowerScheme -Guid ([string]$step.Target) -WhatIf:$script:IsWhatIf
            }
            $message = $step.Reason
        }
        catch {
            $message = ($_.Exception.Message -replace '\s+', ' ').Trim()
            if ($message -match 'Access is denied|registry access is not allowed') { $status = 'Refused' }
        }
        $tag = switch ($status) { 'Done' { '[OK]  ' } 'WhatIf' { '[WHATIF]' } 'Refused' { '[REFUSED]' } default { '[FAIL]' } }
        Write-ActionLog ('{0} {1} {2} {3}' -f $tag, $step.Op, $step.Id, $message)
        $script:Steps.Add([pscustomobject]@{ Seq = $seq; Id = $step.Id; Op = $step.Op; Source = 'tuning-undo'; Status = $status; Message = $message })
    }

    if (-not $script:IsWhatIf) {
        $after = Get-TuningFact -KnownGood $KnownGood
        # Push 2 of the unit tune, step 5: read back the items that this Undo puts back: not an item
        # that no Apply wrote, and not an item left as it is because it changed after the Apply. The
        # repair after the REVIEW at 20405c6 (finding 20): the rows of the snapshot that the Undo
        # replays, not the items of known-good.psd1, so the read-back does not depend on the ids of two
        # lists. The rows have the paths that the Apply wrote (G-12 included).
        $putBackId = @(@($plan) | Where-Object { $_.Op -ne 'Skip' -and $_.Op -ne 'Unknown' } | ForEach-Object { [string]$_.Id })
        $rows = foreach ($it in @($snapshot.Items)) {
            if ($it.Kind -eq 'GpuSteering') { continue }
            if ($putBackId -notcontains [string]$it.Id) { continue }
            $expected = $it.Was
            $actual = Get-TuningNowValue -Item $it -Fact $after
            [pscustomobject]@{
                Id       = 'Tuning:{0}' -f $it.Id
                Field    = $it.Kind
                Expected = $(if ($null -eq $expected) { 'not set' } else { [string]$expected })
                Actual   = $(if ($null -eq $actual) { 'not set' } else { [string]$actual })
                Match    = ([string]$expected -eq [string]$actual)
            }
        }
        $script:ReadBack = @($rows | Where-Object { $null -ne $_ })
        foreach ($r in @($script:ReadBack)) {
            Write-ActionLog ('{0} read-back {1}: expected {2}, found {3}' -f $(if ($r.Match) { '[OK]  ' } else { '[FAIL]' }), $r.Id, $r.Expected, $r.Actual)
        }

        # Push 2 of the unit tune, step 5: a green Undo removes the marker (design section 5). Green:
        # no step that failed or was refused, and each item that it put back reads back.
        $undoSteps = @(@($script:Steps) | Where-Object { $_.Source -eq 'tuning-undo' })
        $bad = @($undoSteps | Where-Object { $_.Status -eq 'Failed' -or $_.Status -eq 'Refused' })
        $notBack = @(@($script:ReadBack) | Where-Object { -not $_.Match })
        if ($markerPresent -and $bad.Count -eq 0 -and $notBack.Count -eq 0) {
            Remove-Item -LiteralPath $script:Paths.TuningMarker -Force
            Write-ActionLog ('[OK]   tuning marker removed: {0}' -f $script:Paths.TuningMarker)
            # Step 6 (the Cowork note of 2026-10-04, point 1, condition 3): the copy goes with the marker.
            # The file beside the snapshot stays with the snapshot.
            if (Test-Path -LiteralPath $script:Paths.TuningUndoByHand) {
                Remove-Item -LiteralPath $script:Paths.TuningUndoByHand -Force
                Write-ActionLog ('[OK]   removed: {0}' -f $script:Paths.TuningUndoByHand)
            }
        }
    }
}

function Resolve-XperfPath {
    <#
        Where xperf is on this machine, or $null. PATH first, then the known
        install locations from the engine. On the rig it is NOT on the PATH and
        NOT under Program Files (x86), which cost an evening to find out.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $onPath = Get-Command -Name 'xperf' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    # Assign, then wrap. Wrapping the call itself hands this loop ONE item that
    # is the whole candidate array: Test-Path then returns an array of booleans,
    # an array of more than one element is true in an if, and the function
    # returns the array instead of a path. Caught by A-LINT-02 the moment it was
    # written, which is the second time that guard has paid for itself today.
    # Machine-wide locations only. A-LINT-07 (flag 4) forbids this elevated child
    # reading a per-user value of its own, and it is right to: $env:USERPROFILE
    # here is whoever typed the administrator credentials at the prompt, not the
    # racer, so a UIforETW copy in the racer's Downloads would be invisible and
    # an administrator's would be found instead. If the portable copy ever needs
    # to be used, the unelevated console passes its path in.
    $candidateList = Get-SimRigXperfCandidatePath -ProgramFiles $env:ProgramFiles -ProgramFilesX86 ${env:ProgramFiles(x86)}
    foreach ($candidate in @($candidateList)) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Test-KernelLoggerRunning {
    <#
        True when something already holds the NT Kernel Logger. Read-only: it
        lists the running loggers and reads the answer, it never stops anything.

        Asked through xperf rather than logman. xperf is already resolved to a
        full path here, while logman is a bare command name that exists only on
        Windows - and a bare name is exactly what the "calls only functions that
        exist" test refuses, because a typo in one would be found by a user
        rather than by the suite.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $XperfPath)
    try {
        $output = & $XperfPath -loggers 2>&1
        return (($output | Out-String) -match 'NT Kernel Logger')
    }
    catch { return $false }
}

function Invoke-XperfStep {
    <# Runs xperf with an argument list and records one step. Returns the exit code. #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $XperfPath,
        [Parameter(Mandatory)] [string[]] $Argument,
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [int] $Seq
    )
    if ($script:IsWhatIf) {
        Write-ActionLog ('[WHATIF] xperf {0}' -f ($Argument -join ' '))
        $script:Steps.Add([pscustomobject]@{ Seq = $Seq; Id = $Id; Op = 'Xperf'; Source = 'trace'; Status = 'WhatIf'; Message = ($Argument -join ' ') })
        return 0
    }
    $output = & $XperfPath @Argument 2>&1
    $code = $LASTEXITCODE
    $text = (($output | Out-String) -replace '\s+', ' ').Trim()
    $status = if ($code -eq 0) { 'Done' } else { 'Failed' }
    Write-ActionLog ('[{0}] xperf {1} -> {2} {3}' -f $status.ToUpperInvariant(), ($Argument -join ' '), $code, $text)
    $script:Steps.Add([pscustomobject]@{ Seq = $Seq; Id = $Id; Op = 'Xperf'; Source = 'trace'; Status = $status; Message = ('exit {0}{1}' -f $code, $(if ($text) { ': ' + $text } else { '' })) })
    return $code
}

function Invoke-TraceStartOperation {
    <#
        Starts the hard-fault trace for a session.

        Two rules, both bought the hard way on 2026-09-27. It writes to a file
        in the session folder from the first second (-f), so an interrupted
        trace still leaves everything up to the interruption - that night only
        xperf's own C:\kernel.etl fallback saved any data at all. And it refuses
        rather than taking the kernel logger off whatever already holds it,
        because stopping that session dumps its data and may stop the tool that
        owns it collecting.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)] [string] $SessionDir)

    $xperf = Resolve-XperfPath
    # No xperf, nothing to ask: the verdict is Blocked either way, and calling
    # the check with an empty path would throw on a mandatory parameter.
    $busy = if ($xperf) { Test-KernelLoggerRunning -XperfPath $xperf } else { $false }
    $verdict = Get-SimRigHardFaultStartVerdict -XperfPath $xperf -KernelLoggerRunning $busy -OwnerHint $null

    if ($verdict.Verdict -ne 'Ready') {
        $script:Errors.Add(('Refused: {0}' -f $verdict.Detail))
        $script:ExitCode = $script:Codes.Refused
        Write-ActionLog ('[SKIP] trace not started: {0}' -f $verdict.Detail)
        return
    }

    Initialize-ActionFolder -Folder @($SessionDir)
    # Blocker 7, commit 6 (O2): xperf writes to a new GUID name; Trace Stop moves the file to hardfaults.etl.
    $etl = Join-Path -Path $SessionDir -ChildPath ('hardfaults.{0}.etl' -f [guid]::NewGuid().ToString('N'))
    $refusal = Clear-ActionNewName -Path $etl
    if ($refusal) {
        $script:Errors.Add($refusal)
        $script:ExitCode = $script:Codes.Refused
        return
    }
    $argument = Get-SimRigHardFaultCommand -Phase Start -EtlPath $etl
    $code = Invoke-XperfStep -XperfPath $xperf -Argument $argument -Id 'TraceStart' -Seq 1
    if ($code -ne 0) {
        $script:ExitCode = $script:Codes.StepFailed
        return
    }
    $script:SessionDirOut = $SessionDir
    Write-ActionLog ('[OK]   hard-fault trace running -> {0}' -f $etl)
}

function Invoke-TraceStopOperation {
    <#
        Stops the trace, converts it, and reads it.

        The stop is "-stop" and nothing else. "-stop -d <file>" has to name a
        session that may already be gone, and that is what answered 0x1069 on
        2026-09-27 after the logger was taken away mid-stint. Stopping and then
        converting the file we already have cannot fail that way - and if the
        session did die during the stint, the file is still there with
        everything up to the moment it died, so the conversion still runs.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)] [string] $SessionDir)

    $xperf = Resolve-XperfPath
    if (-not $xperf) {
        $script:Errors.Add('Refused: xperf.exe was not found, so a running trace cannot be stopped or read.')
        $script:ExitCode = $script:Codes.Refused
        return
    }

    # Blocker 7, commit 6 (O2; ANSWERS-night-o2-a6f61ac-cowork-2026-10-08.md, Q1): Trace Start wrote to a new GUID
    # name. One such file: it is the trace. More than one: text O2-1, before the stop, so that nothing is changed.
    $found = @(Get-ChildItem -LiteralPath $SessionDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^hardfaults\.[0-9a-f]{32}\.etl$' })
    if ($found.Count -gt 1) {
        $script:Errors.Add(('Refused: the session folder {0} has more than one trace file of the app. Nothing was changed. Keep the trace file that you need, remove the others, and try Trace Stop again.' -f $SessionDir))
        $script:ExitCode = $script:Codes.Refused
        return
    }
    # A folder at a final name makes the move fail after the conversion. Refuse before the stop, so that the text
    # "Nothing was changed" is true and the trace stays at its GUID name (PRECHECK-night-o2-4237ef3.md, finding 11-1).
    # Blocker 7, commit 8, part (a): the three final names, hardfaults.json too (probe A of REVIEW-night-o2-e0cab04.md),
    # for a folder and for a link.
    $finalRefusal = Get-ActionFinalNameRefusal -Path @('hardfaults.etl', 'hardfaults.csv', 'hardfaults.json' | ForEach-Object { Join-Path -Path $SessionDir -ChildPath $_ })
    if ($finalRefusal) {
        $script:Errors.Add($finalRefusal)
        $script:ExitCode = $script:Codes.Refused
        return
    }

    # A failed stop is not fatal: the session may already be gone, and the file
    # on disk is what we came for.
    [void](Invoke-XperfStep -XperfPath $xperf -Argument (Get-SimRigHardFaultCommand -Phase Stop) -Id 'TraceStop' -Seq 1)

    if ($script:IsWhatIf) { return }

    if ($found.Count -eq 0) {
        $script:Errors.Add(('No trace file at {0}. The trace was never started, or it was started without -f.' -f $SessionDir))
        $script:ExitCode = $script:Codes.StepFailed
        return
    }
    $etlNew = $found[0].FullName
    $csvNew = Join-Path -Path $SessionDir -ChildPath ('hardfaults.{0}.csv' -f [guid]::NewGuid().ToString('N'))
    $refusal = Clear-ActionNewName -Path $csvNew
    if ($refusal) {
        $script:Errors.Add($refusal)
        $script:ExitCode = $script:Codes.Refused
        return
    }

    $code = Invoke-XperfStep -XperfPath $xperf -Argument (Get-SimRigHardFaultCommand -Phase Convert -EtlPath $etlNew -CsvPath $csvNew) -Id 'TraceConvert' -Seq 2
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $csvNew)) {
        $script:ExitCode = $script:Codes.StepFailed
        return
    }
    $etl = Resolve-ActionPath (Join-Path -Path $SessionDir -ChildPath 'hardfaults.etl')
    $csv = Resolve-ActionPath (Join-Path -Path $SessionDir -ChildPath 'hardfaults.csv')
    Move-ActionFileOver -Source (Resolve-ActionPath $etlNew) -Destination $etl
    Move-ActionFileOver -Source (Resolve-ActionPath $csvNew) -Destination $csv

    $report = Get-SimRigHardFaultReport -Text (Get-Content -LiteralPath $csv -Raw)
    Write-JsonFileAtomic -Path (Join-Path -Path $SessionDir -ChildPath 'hardfaults.json') -InputObject $report
    $script:SessionDirOut = $SessionDir

    if (-not $report.IsValid) {
        $script:Errors.Add(('The trace converted but did not parse: {0}' -f $report.Reason))
        $script:ExitCode = $script:Codes.StepFailed
        return
    }

    $worst = if (@($report.ByProcess).Count -gt 0) { '{0} ({1})' -f $report.ByProcess[0].Process, $report.ByProcess[0].Faults } else { 'none' }
    Write-ActionLog ('[OK]   {0} hard fault(s), {1} byte(s); worst process: {2}' -f $report.TotalHardFaults, $report.TotalBytes, $worst)
    $script:Steps.Add([pscustomobject]@{
            Seq = 3; Id = 'TraceRead'; Op = 'Read'; Source = 'trace'; Status = 'Done'
            Message = ('{0} hard fault(s) across {1} process(es); worst: {2}' -f $report.TotalHardFaults, @($report.ByProcess).Count, $worst)
        })
}

function Invoke-SelfTestOperation {
    <#
        One elevated run that proves on real Windows what the Linux tests can
        only simulate. Every change it makes is undone before it returns: the
        final state must equal the state it started from.
          1. Quiet (no Process items - nothing is closed).
          2. Revert one quieted Disable service on purpose, read the System log,
             and classify it: the race watch must report a Revert for it.
          3. Restore - the verdict must be green.
          4. Quiet again, start the deadman task now (not at sign-in), wait:
             it must restore, go green and remove itself.
        If step 4 does not finish, a normal restore runs as a fallback, so the
        rig is never left quiet.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Item, [Parameter(Mandatory)] [hashtable] $KnownGood)
    if (-not $SessionDir) { throw 'SelfTest needs -SessionDir' }
    Initialize-ActionFolder -Folder $SessionDir
    $items = @($Item | Where-Object { $_.Kind -ne 'Process' })
    $report = [ordered]@{ Schema = 'simrig.selftest-elevated/1'; StartedAt = (Format-SimRigTime -Time (Get-Date)); Check = [System.Collections.Generic.List[object]]::new() }
    $add = {
        param($Name, [bool]$Pass, $Detail)
        $report.Check.Add([pscustomobject]@{ Name = $Name; Pass = $Pass; Detail = [string]$Detail })
        Write-ActionLog ('[SELFTEST {0}] {1} - {2}' -f $(if ($Pass) { 'PASS' } else { 'FAIL' }), $Name, $Detail)
    }
    $before = Get-TimedItemState -Item $items -Label 'self-test start'

    # 1. Quiet
    Invoke-QuietOperation -Item $items -Dir (Join-Path $SessionDir 'roundtrip')
    if ($script:ExitCode -ne $script:Codes.Done) { & $add 'Quiet ran' $false (@($script:Errors) -join ' '); $report.Check = $report.Check.ToArray(); return $report }
    $quietMiss = @($script:ReadBack | Where-Object { -not $_.Match })
    $refused = @($script:Steps | Where-Object { $_.Status -eq 'Refused' } | ForEach-Object { $_.Id } | Select-Object -Unique)
    & $add 'Quiet read-back: every item at its quiet target' ($quietMiss.Count -eq 0) $(if ($quietMiss.Count) { ($quietMiss | ForEach-Object { '{0} {1}={2}' -f $_.Id, $_.Field, $_.Actual }) -join '; ' } else { '{0} values read back; {1} item(s) refused by Windows: {2}' -f @($script:ReadBack).Count, $refused.Count, ($refused -join ', ') })

    # 2. A real revert, seen by the race-watch classifier
    # RF-1. Only a service that this quiet changed (Select-SelfTestRevertService, in
    # the engine, with its tests). The service is then set to Manual by a direct call,
    # which is no step. With a Done quiet step it can never be an item that Windows
    # refused, so the last check of the self-test cannot call it "not changed by SimRig".
    $victim = @(Select-SelfTestRevertService -Item $items -ReadBack $script:ReadBack -Step $script:Steps.ToArray() | Where-Object { $null -ne $_ })
    if ($victim.Count -eq 0) {
        & $add 'Race watch sees a revert' $false 'no quieted Disable service to revert'
    }
    else {
        $t0 = (Get-Date).AddSeconds(-1)
        try {
            [void](Set-SimRigServiceStartType -Name $victim[0].Name -StartType 'Manual')
            Start-Sleep -Seconds 3
            $rec = Get-SimRigEventRecord -Since $t0
            $map = Get-SimRigServiceDisplayNameMap
            $svcEv = if (@($rec.Service).Count) { ConvertFrom-ServiceControlEvent -Event @($rec.Service) -DisplayNameMap $map } else { @() }
            $watch = Get-WatchEvent -ServiceEvent $svcEv -TaskEvent @() -QuietItem $items
            # Only the revert made here counts (To = Manual), not the quiet's own change to Disabled.
            $hit = @($watch | Where-Object { $_.ItemId -eq $victim[0].Id -and $_.Severity -eq 'Revert' -and $_.Kind -eq 'StartTypeChange' -and $_.To -eq 'Manual' })
            & $add 'Race watch sees a revert' ($hit.Count -gt 0) $(if ($hit.Count) { '{0} at {1}: {2}' -f $victim[0].Id, $hit[0].Time, $hit[0].Message } else { 'set {0} to Manual; {1} SCM event(s) read, no Revert for it' -f $victim[0].Name, @($rec.Service).Count })
        }
        catch { & $add 'Race watch sees a revert' $false $_.Exception.Message }
    }

    # 3. Restore
    Invoke-RestoreOperation -Item $items -KnownGood $KnownGood
    $v1 = $script:Verdict
    & $add 'Restore verdict green' ([bool]($null -ne $v1 -and $v1.Green)) $(if ($v1) { $v1.Line } else { 'no verdict' })
    & $add 'Marker cleared and deadman removed after restore' ((-not (Test-Path -LiteralPath $script:Paths.ActiveMarker)) -and $null -eq (Get-ScheduledTask -TaskPath $script:DeadmanTaskPath -TaskName $script:DeadmanTaskName -ErrorAction SilentlyContinue)) ''

    # 4. Deadman, started now instead of at sign-in
    if (Test-Path -LiteralPath $script:Paths.ActiveMarker) {
        & $add 'Deadman restored and went green' $false 'skipped: the restore in step 3 was not green'
    }
    else {
        Invoke-QuietOperation -Item $items -Dir (Join-Path $SessionDir 'deadman')
        $task = Get-ScheduledTask -TaskPath $script:DeadmanTaskPath -TaskName $script:DeadmanTaskName -ErrorAction SilentlyContinue
        & $add 'Deadman task registered (logon trigger, elevated)' ($null -ne $task) $(if ($task) { 'RunLevel {0}' -f $task.Principal.RunLevel } else { 'not found' })
        $deadmanGreen = $false
        if ($null -ne $task) {
            $t1 = Get-Date
            Start-ScheduledTask -TaskPath $script:DeadmanTaskPath -TaskName $script:DeadmanTaskName
            $deadline = $t1.AddMinutes(4)
            # The deadman clears the marker, removes its task, then writes its result
            # file. Wait for the result file itself, not only for the marker (the
            # 2026-09-19 rig run read the folder in the second between the two).
            $res = $null
            while ((Get-Date) -lt $deadline) {
                $res = Get-ChildItem -LiteralPath $script:Paths.Results -Filter 'Deadman-*.json' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -ge $t1 } | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
                if ($null -ne $res -and -not (Test-Path -LiteralPath $script:Paths.ActiveMarker)) { break }
                Start-Sleep -Seconds 2
            }
            $dr = if ($res) { Read-SimRigJson -Path $res.FullName } else { $null }
            $deadmanGreen = ($null -ne $dr -and $null -ne $dr.Verdict -and [bool]$dr.Verdict.Green)
            $why = if ($dr -and $dr.Verdict) { $dr.Verdict.Line }
                   elseif (Test-Path -LiteralPath $script:Paths.ActiveMarker) { 'deadman did not restore within 4 min (marker still there)' }
                   else { 'marker cleared but no Deadman result file within 4 min' }
            & $add 'Deadman restored and went green' $deadmanGreen $why
            & $add 'Deadman removed itself' ($null -eq (Get-ScheduledTask -TaskPath $script:DeadmanTaskPath -TaskName $script:DeadmanTaskName -ErrorAction SilentlyContinue)) ''
        }
    }
    if (Test-Path -LiteralPath $script:Paths.ActiveMarker) {
        Write-ActionLog '[SELFTEST] deadman did not finish - running a normal restore so the rig is not left quiet'
        Invoke-RestoreOperation -Item $items -KnownGood $KnownGood
    }

    # The whole run must leave Windows as it found it.
    $after = Get-TimedItemState -Item $items -Label 'self-test end'
    $expected = @($before | Where-Object { $_.Exists })
    $diff = @(Compare-ItemState -QuietItem $items -Expected $expected -Actual $after | Where-Object { -not $_.Match -and $_.Field -ne 'State' -and $_.Field -ne 'TaskState' } |
            Where-Object { -not ($_.Field -eq 'StartType' -and (Test-SelfSwitchStartType -KnownGood $KnownGood -Name ($_.Id -replace '^Service:', '') -Expected $_.Expected -Actual $_.Actual)) })
    # RF-1. An item that differs fails this check, except an item that Windows
    # refused in the quiets of this run and that no quiet of this run changed. The
    # function gets each step of the run and chooses the quiet steps itself.
    $left = Get-SelfTestLeftAsFoundCheck -Diff $diff -Compared $expected.Count -Step $script:Steps.ToArray()
    & $add 'Windows left exactly as found (start types, tasks, registry, Defender)' $left.Pass $left.Detail
    $report['FinishedAt'] = Format-SimRigTime -Time (Get-Date)
    $report.Check = $report.Check.ToArray()
    return $report
}

# --------------------------------------------------------------------------
# Main: always write a result, always exit with a code from the table.
# --------------------------------------------------------------------------

$script:StartedAt = Get-Date
$script:Steps = [System.Collections.Generic.List[object]]::new()
$script:Errors = [System.Collections.Generic.List[string]]::new()
$script:ReadBack = @()
$script:Verdict = $null
$script:SnapshotPath = $null
$script:SessionDirOut = $SessionDir
$script:ExitCode = $script:Codes.Done
# Push 2 of the unit tune, step 4: set for ApplyTuning and UndoTuning by Get-ActionTuningSupport.
$script:TuningSupport = $null

try {
    # Blocker 7, commit 8, part (c) (REVIEW-night-o2-e0cab04.md, finding 4): before the first write, a link on the
    # path of the results folder (the data folder, Logs, Logs\v4, Logs\v4\results) is refused, and the child writes
    # nothing: no folder, no log file, no result file. The window then reports that no result file was written.
    $logsLink = Find-SimRigPathLink -Root $script:Paths.Root -Path $script:Paths.Results
    if ($null -ne $logsLink) {
        # Text 5, or text 6 in the form for the session folder. No step has run, so nothing was changed. The window
        # cannot read this text (blocker 7, commit 9): it makes the same check itself (Get-ConsoleRefusalLinkText).
        $script:LogsRefusal = if ($logsLink.Cause -eq 'Link') { Get-ActionLinkText -Path $logsLink.Item }
        else { 'Refused: the app cannot check {0}, because Windows does not let it read the folder. Nothing was changed.' -f $logsLink.Item }
    }
    else {
        Initialize-ActionFolder -Folder @($script:Paths.Logs, $script:Paths.Results, $script:Paths.Sessions)
        Open-ActionChildLog -Path (Get-ActionChildLogPath -ResultDir $script:Paths.Results -Operation $Operation -RequestId $RequestId)
    }
    Write-ActionLog ("start (WhatIf={0}, elevated={1})" -f $script:IsWhatIf, (Test-SimRigAdmin))

    if ($null -ne $script:LogsRefusal) {
        $script:Errors.Add($script:LogsRefusal)
        $script:ExitCode = $script:Codes.Refused
    }
    elseif ($resultRefusal = Get-ActionFinalNameRefusal -Path @(Get-ActionResultPath -ResultDir $script:Paths.Results -Operation $Operation -RequestId $RequestId)) {
        # Blocker 7, commit 8, part (a): the result file is a final name of each operation.
        $script:Errors.Add($resultRefusal)
        $script:ExitCode = $script:Codes.Refused
    }
    elseif (-not $script:IsWhatIf -and -not (Test-SimRigAdmin)) {
        $script:Errors.Add('Refused: state changes need an elevated process.')
        $script:ExitCode = $script:Codes.Refused
    }
    elseif ($Operation -eq 'Fix' -and -not $OnlyId) {
        $script:Errors.Add('Fix needs -OnlyId.')
        $script:ExitCode = $script:Codes.BadArgument
    }
    elseif ($Operation -in @('Quiet', 'TraceStart', 'TraceStop', 'SelfTest') -and $SessionDir -and
        ($sessionRefusal = Get-ActionTuningPathRefusal -Dir $SessionDir)) {
        # O2 of blocker 6 (Rick typed "Q1 blocker", 2026-10-07): the session folder of the command line is
        # checked as for Apply and Undo of tuning, before any data is loaded and before any write: Quiet writes
        # its snapshot and its record there, the trace runs xperf with its output there, the self-test writes
        # there. The console can take that folder from the session marker, a file that a program with no
        # elevation can write. Texts 3, 5 and 6, word for word.
        $script:Errors.Add($sessionRefusal)
        $script:ExitCode = $script:Codes.Refused
    }
    elseif ($Operation -eq 'FixGpu' -and -not (Test-ActionTuningAllowed)) {
        # Before any data is loaded and before any write. GPU steering is for the rig only (amendment 9).
        $script:Errors.Add('Refused: This version does not change tuning settings on this PC.')
        $script:ExitCode = $script:Codes.Refused
    }
    elseif ($Operation -in @('ApplyTuning', 'UndoTuning') -and @('Rig', 'Supported') -notcontains ($script:TuningSupport = Get-ActionTuningSupport).State -and
        -not ($Operation -eq 'UndoTuning' -and (Test-Path -LiteralPath $script:Paths.TuningMarker))) {
        # Push 2 of the unit tune, step 4: the rig and a supported PC; before any data is loaded and
        # before any write. Undo runs on a supported PC also, so that an Apply there can be undone.
        # Step 5: Undo runs also on a PC that is not supported when the marker is there: a way back
        # does not depend on the check that allowed the write (design section 6).
        $script:Errors.Add('Refused: This version does not change tuning settings on this PC.')
        $script:ExitCode = $script:Codes.Refused
    }
    else {
        $listData = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'quiet-list.psd1')
        $kg = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'known-good.psd1')
        [string[]]$listErrors = Test-QuietListData -Data $listData
        [string[]]$kgErrors = Test-KnownGoodData -Data $kg
        $dataErrors = @($listErrors | Where-Object { $_ }) + @($kgErrors | Where-Object { $_ })
        if ($dataErrors.Count -gt 0) { throw ('Data files invalid: ' + ($dataErrors -join '; ')) }
        $items = ConvertTo-QuietItem -Data $listData

        # The user's own extras (spec 6a G-3/G-4). Empty for every profile by
        # default, so this adds nothing until somebody picks something.
        $myAppsPath = Join-Path $PSScriptRoot 'my-apps.psd1'
        if (Test-Path -LiteralPath $myAppsPath) {
            $myApps = Import-PowerShellDataFile -LiteralPath $myAppsPath
            [string[]]$myAppErrors = Test-MyAppsData -Data $myApps
            $myAppErrors = @($myAppErrors | Where-Object { $_ })
            if ($myAppErrors.Count -gt 0) { throw ('my-apps.psd1 invalid: ' + ($myAppErrors -join '; ')) }
            # Assign, then wrap. The engine's array-returning functions use the
            # ', @(...)' shape, and '@(Func ...)' on that gives one element holding
            # the whole array. Bare assignment unrolls it correctly.
            $extra = ConvertTo-MyAppItem -Data $myApps
            $extra = @($extra)
            if ($extra.Count -gt 0) {
                Write-ActionLog ("my-apps: {0} user item(s) added after the public list" -f $extra.Count)
                $items = @($items) + $extra
            }
        }
        $script:Kg = $kg

        # G-12. After the merge and before anything reads or writes, so the plan,
        # the state reads, the snapshot and the restore all use one target. The Id
        # is untouched: it is how the console's rows and the read-back find each
        # other, and it belongs to the data file, not to the hive.
        if ($script:UserSid) {
            if (-not (Test-SimRigUserSid -Sid $script:UserSid)) {
                throw ('Not a user SID: {0}' -f $script:UserSid)
            }
            $items = Set-SimRigItemUserHive -Item $items -UserSid $script:UserSid
        }
        # Flag 4: the deadman runs as SYSTEM, and SYSTEM can be there before the
        # racer's profile is mounted - or the task can be started by hand while they
        # are not signed in at all. Then HKEY_USERS\<sid> is simply absent, and a
        # write there would either fail or leave a stray key nothing reads. So the
        # user items are dropped, a Warn is recorded, and the marker is kept: the
        # session is not finished and the next sign-in has to finish it.
        # The condition is the one the brief names, and only that one: the hive is not
        # loaded. A run with no SID is left alone - it writes its own HKCU, which is
        # also the hive its snapshot was read from, so nothing is put back wrong. The
        # wider rule I first wrote here ("a SYSTEM deadman with no SID skips the
        # per-user half") failed three existing tests, and it was wrong rather than
        # unlucky: it turned a complete restore into an incomplete one for the
        # hand-run and self-test cases, which are not the case flag 4 is about.
        if ($script:UserSid -and -not (Test-SimRigUserHiveMounted -UserSid $script:UserSid)) {
            $before = @($items).Count
            $items = @($items | Where-Object { [string]$_.Path -notlike 'Registry::HKEY_USERS\*' })
            $skipped = $before - @($items).Count
            $skipWhy = 'the hive of {0} is not loaded' -f $script:UserSid
            if ($skipped -gt 0) {
                $script:KeepMarker = $true
                $script:Errors.Add(('Warn: {0}, so {1} per-user item(s) were skipped. Sign in as that user and this finishes then.' -f $skipWhy, $skipped))
                Write-ActionLog ('[WARN] {0} - {1} item(s) skipped, marker kept' -f $skipWhy, $skipped)
            }
        }

        $hive = Get-SimRigUserHiveCount -Item $items
        if ($hive.UserHive -gt 0) {
            Write-ActionLog ('G-12: {0} item(s) write the racer hive {1}' -f $hive.UserHive, $script:UserSid)
        }
        elseif ($hive.CurrentUser -gt 0) {
            Write-ActionLog ('G-12: {0} HKCU item(s) write this process own profile - no -UserSid was passed' -f $hive.CurrentUser)
        }

        if ($Operation -eq 'Quiet') {
            # Absent -OnlyId means the whole list; present-but-empty means no ticks.
            # Typed, and not through an if-block: a block whose output is '@()'
            # writes nothing to the pipeline, so '$x = if (..) { @() }' leaves $x
            # $null - which here would read as 'no ticks given' and quiet the lot.
            $ticked = $null
            if ($PSBoundParameters.ContainsKey('OnlyId')) {
                [string[]] $ticked = @($OnlyId -split '\|' | Where-Object { $_ })
            }
            # Blocker 5: the machine filter first, then the ticks. So an id that the
            # console passes for an item of another profile writes nothing.
            # With a tick set that is present and empty nothing is written, so the
            # machine is not read: that run touches nothing (A-FIX-01).
            $machineItems = @()
            if ($null -eq $ticked -or @($ticked).Count -gt 0) { $machineItems = Select-ActionMachineItem -Item $items }
            $selected = Select-TickedQuietItem -QuietItem @($machineItems) -Ticked $ticked
            Invoke-QuietOperation -Item @($selected)
        }
        elseif ($Operation -eq 'FixGpu') {
            Invoke-FixGpuOperation -KnownGood $kg -Scope $GpuScope
        }
        elseif ($Operation -eq 'ApplyTuning') {
            $onlyTuning = if ($OnlyId) { @($OnlyId -split '\|' | Where-Object { $_ }) } else { $null }
            if ($script:TuningSupport.State -eq 'Supported') {
                # Push 2 of the unit tune, step 4: the child makes the items of this PC itself, from
                # the rules, its profile and its own readings, and writes only those (design section 6).
                $tuningFact = Get-TuningFact -KnownGood $kg
                $tuningRuleLoad = Get-SimRigRuleDocument -Directory (Join-Path $PSScriptRoot 'rules')
                $tuningRule = foreach ($doc in @($tuningRuleLoad.Document)) { @(Get-KnownGoodField -Entry $doc -Name 'Rules') }
                $tuningOffer = Get-SimRigTuningOffer -Support $script:TuningSupport -Machine $script:TuningSupport.Machine -Rule @($tuningRule) `
                    -ProfileValues (Get-KnownGoodField -Entry $script:TuningSupport.RigProfile -Name 'Values') -KnownGood $kg -Fact $tuningFact
                $tuningRequest = Select-SimRigTuningRequest -Support $script:TuningSupport -Offer @($tuningOffer) -Only $onlyTuning
                if (-not $tuningRequest.Allowed) {
                    $script:Errors.Add($tuningRequest.Error)
                    $script:ExitCode = $script:Codes.Refused
                }
                else {
                    Invoke-ApplyTuningOperation -KnownGood $kg -Only $onlyTuning -Force:$Force -Item @($tuningRequest.Item)
                }
            }
            else {
                Invoke-ApplyTuningOperation -KnownGood $kg -Only $onlyTuning -Force:$Force
            }
        }
        elseif ($Operation -eq 'UndoTuning') {
            $onlyTuning = if ($OnlyId) { @($OnlyId -split '\|' | Where-Object { $_ }) } else { $null }
            Invoke-UndoTuningOperation -KnownGood $kg -Only $onlyTuning
        }
        elseif ($Operation -eq 'TraceStart') {
            if (-not $SessionDir) { throw 'TraceStart needs -SessionDir: the trace file belongs with the session it covers.' }
            Invoke-TraceStartOperation -SessionDir $SessionDir
        }
        elseif ($Operation -eq 'TraceStop') {
            if (-not $SessionDir) { throw 'TraceStop needs -SessionDir: that is where the trace file was written.' }
            Invoke-TraceStopOperation -SessionDir $SessionDir
        }
        elseif ($Operation -eq 'SelfTest') {
            # Blocker 7, commit 8, part (a): the final name of the self-test before its first step. The quiets of the
            # self-test check their own names.
            $selfTestRefusal = Get-ActionFinalNameRefusal -Path @((Join-Path $SessionDir 'selftest-elevated.json'))
            if ($selfTestRefusal) {
                $script:Errors.Add($selfTestRefusal)
                $script:ExitCode = $script:Codes.Refused
            }
            else {
                $machineItems = Select-ActionMachineItem -Item $items
                $st = Invoke-SelfTestOperation -Item @($machineItems) -KnownGood $kg
                Write-JsonFileAtomic -Path (Join-Path $SessionDir 'selftest-elevated.json') -InputObject $st
                if (@($st.Check | Where-Object { -not $_.Pass }).Count -gt 0 -and $script:ExitCode -eq $script:Codes.Done) { $script:ExitCode = $script:Codes.StepFailed }
            }
        }
        else {
            $only = if ($Operation -eq 'Fix') { @($OnlyId -split '\|' | Where-Object { $_ }) } else { $null }
            Invoke-RestoreOperation -Item $items -KnownGood $kg -Only $only
        }
        if ($script:ExitCode -eq $script:Codes.Done) {
            $failedSteps = @($script:Steps | Where-Object { $_.Status -eq 'Failed' }).Count
            # A restore is graded by its verdict (flag 2), not by the raw read-back:
            # demand-start services stop by themselves after a restore (the
            # 2026-09-19 19:28 deadman went green and still exited 1).
            $failedRead = if ($null -ne $script:Verdict) { 0 } else { @($script:ReadBack | Where-Object { -not $_.Match }).Count }
            $red = ($null -ne $script:Verdict -and -not $script:Verdict.Green)
            if ($failedSteps -gt 0 -or $failedRead -gt 0 -or $red) { $script:ExitCode = $script:Codes.StepFailed }
        }
    }
}
catch {
    $script:ExitCode = $script:Codes.Fatal
    $script:Errors.Add(('Fatal: {0} (line {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber))
    Write-ActionLog ('[FAIL] fatal: {0}' -f $_.Exception.Message)
}
finally {
    if ($null -ne $script:LogsRefusal) {
        # Blocker 7, commit 8, part (c): no result file through a link. The text goes to the error stream only.
        Write-Warning $script:LogsRefusal
    }
    else {
        try {
            $result = Build-ActionResult -RequestId $RequestId -Operation $Operation -WhatIfRun $script:IsWhatIf `
                -StartedAt $script:StartedAt -FinishedAt (Get-Date) -ExitCode $script:ExitCode `
                -SessionDir $script:SessionDirOut -SnapshotPath $script:SnapshotPath -Step $script:Steps.ToArray() `
                -ReadBack $script:ReadBack -Verdict $script:Verdict -ErrorText $script:Errors.ToArray()
            $resultPath = Get-ActionResultPath -ResultDir $script:Paths.Results -Operation $Operation -RequestId $RequestId
            Write-JsonFileAtomic -Path $resultPath -InputObject $result
            Write-ActionLog ("result -> {0} (exit {1})" -f $resultPath, $script:ExitCode)
        }
        catch {
            # Last resort: the console will report "no result JSON was written".
            Write-ActionLog ('[FAIL] could not write the result JSON: {0}' -f $_.Exception.Message)
            if ($script:ExitCode -eq $script:Codes.Done) { $script:ExitCode = $script:Codes.Fatal }
        }
    }
    Close-ActionChildLog
}
exit $script:ExitCode
