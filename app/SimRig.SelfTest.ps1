<#
    SimRig.SelfTest.ps1 - SimRig Console v4.0 self-test

    One click, one Windows prompt, about 5 minutes. It runs every rig check a
    script can run, grades each one PASS / FAIL / WARN, and writes a report to
    Claude to read:
      <log folder>\selftest\<yyyy-MM-dd_HHmm>\selftest.txt (+ .json and the logs),
      copied to <share>\session-data\v4-selftest\<stamp> when -NasRoot is given

    Shortcut target:
      pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File "C:\Program Files\SimRig\SimRig.SelfTest.ps1"
    The program files moved there in v4.2. The note used to say C:\SimRacer\Scripts\v4,
    which is where v4.0 and v4.1 put them and is the reason a space in the path
    went unconsidered for four release candidates (U4.32). The DATA still lives
    under C:\SimRacer - that part did not move.

    This script changes nothing itself. It reads through SimRig.Probe.ps1, and
    the only system changes come from SimRig.Actions.ps1: a dry run (no changes,
    unelevated) and one elevated SelfTest run, which quiets, reverts one service
    on purpose, restores, quiets again and lets the deadman task restore. That
    run must leave Windows exactly as it found it, and it checks that it did.
    Process items are skipped - it closes nothing.

    Do not run it while iRacing is running. It refuses if a v4 session is still
    quiet (restore that first).
#>
[CmdletBinding()]
param(
    [string] $Root = 'C:\SimRacer',
    # No default share: it was one person's mapped drive shipped to every reader
    # (2026-09-27). Pass -NasRoot to copy the report to a folder; without it the
    # report stays in the log folder and the last line says where.
    [string] $NasRoot = '',
    # G-12. The racer's own SID, captured BEFORE this script elevates and passed
    # to the elevated copy of itself. Every HKCU item a child writes goes to this
    # SID's hive rather than to whoever's credentials were typed at the prompt.
    [string] $UserSid = '',
    # Tests only: define the functions, run nothing.
    [switch] $DefineOnly
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# A terminating error used to take the window with it. The Read-Host at the end
# of this file only holds a run that REACHES the end, so on 2026-09-28 the whole
# self-test vanished off Rick's screen before he could read why it stopped, and
# he had to re-run it from a command prompt to see the message at all. A
# script-scope trap catches anything terminating, prints where it happened, and
# waits - the one thing a person at a rig needs from a failure.
trap {
    Write-Output ''
    Write-Output ('SimRig self-test stopped: {0}' -f $_.Exception.Message)
    if ($_.InvocationInfo) {
        Write-Output ('  at {0} line {1}' -f (Split-Path -Leaf ([string]$_.InvocationInfo.ScriptName)), $_.InvocationInfo.ScriptLineNumber)
    }
    # beta1-fix2 E-2: the elevated run prints in its own window, which nobody saves (the rig re-test of 2026-10-15 lost
    # these lines), so they also go to trap.txt in the report folder of the run, when it exists.
    $trapDir = Get-Variable -Name outDir -ValueOnly -ErrorAction SilentlyContinue
    if (Get-Command -Name Write-SelfTestTrapFile -CommandType Function -ErrorAction SilentlyContinue) {
        Write-SelfTestTrapFile -Directory $trapDir -ErrorRecord $_
    }
    Write-Output ''
    Write-Output 'Nothing was changed. Send these lines to Claude.'
    if (-not $DefineOnly) { [void](Read-Host 'Press Enter to close') }
    exit 4
}

if (-not $DefineOnly -and $IsWindows -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    & (Get-Process -Id $PID).Path -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -Root $Root -NasRoot $NasRoot
    exit $LASTEXITCODE
}

. (Join-Path -Path $PSScriptRoot -ChildPath 'SimRig.Engine.ps1')
# EVERY engine part, the same way SimRig.Actions.ps1 loads them - not a hand
# picked few. Naming individual parts here is how the release candidate died on
# the rig on 2026-09-28: the self-test called Get-SimRigShareRoot, which lives in
# engine/Engine.Install.ps1, which this file did not load, and the whole run
# stopped after one PASS with "the term is not recognized". Nothing on Linux
# caught it because the tests dot-source the tree themselves.
foreach ($enginePart in @(Get-ChildItem -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'engine') -Filter *.ps1 -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
    . $enginePart.FullName
}
# Every discover part, the same way SimRig.Actions.ps1 loads them. Push 2 of the unit tune, step 8:
# the self-test reads the machine (Get-SimRigMachineContext) to know the tuning state of this PC, and
# that reading needs each part, not only the CPU.
foreach ($discoverPart in @(Get-ChildItem -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'discover') -Filter *.ps1 -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
    . $discoverPart.FullName
}
. (Join-Path -Path $PSScriptRoot -ChildPath 'SimRig.Probe.ps1')
# The logger, for the steering history it reads back (U4.25). Third file in
# three days that this script called into without loading.
. (Join-Path -Path $PSScriptRoot -ChildPath 'SimRig.Logger.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'SimRig.Strings.ps1')
# SimRig.Strings.ps1 is loaded HERE and not left to the view file. The view's
# Initialize-ScreenText calls Get-SimRigString for every label, and on the rig
# on 2026-09-28 the theme check failed with "the term Get-SimRigString is not
# recognized" - the same class of miss as Get-SimRigShareRoot the night before.
. (Join-Path -Path $PSScriptRoot -ChildPath 'SimRigConsole.View.ps1')

# One prompt, not three. Every elevated step used to launch its own child with
# -Verb RunAs, so Rick got a UAC prompt for the tuning round trip, another for
# the undo and another for the elevated self-test - three in a row, for one
# thing he clicked once. A child started from an already-elevated process does
# not prompt, so the self-test asks once here and the rest inherit.
#
# The SID is read BEFORE elevating and handed to the elevated copy. That is not
# a detail: after elevation this process may be running as a different account,
# and G-12 says every HKCU write belongs to the RACER's hive, not to whoever's
# credentials were typed at the prompt.
function Get-SelfTestElevationArgument {
    <#
        .SYNOPSIS
        The command line the self-test uses to relaunch itself elevated.

        .DESCRIPTION
        Pure, and separate from the Start-Process call, because it is the part
        that was wrong and the part a test can check.

        Two faults lived here from v4.2 until 2026-09-29, and both came from
        passing an ARRAY to Start-Process -ArgumentList:

          1. Start-Process joins that array with spaces and does NOT quote an
             entry containing a space. In v4.0 and v4.1 the app lived at
             C:\SimRacer\Scripts\v4 and there was no space, so it worked by
             luck. v4.2 moved the program files to %ProgramFiles%\SimRig -
             'C:\Program Files\SimRig' - and the child was started with
             '-File C:\Program', which pwsh cannot find. pwsh exits 64 on a bad
             command line before running a line of the script, so the window
             appeared and vanished with nothing on it. The self-test was dead
             from that move onward and nothing noticed, because no test ever
             launched it from a path with a space in it.

          2. An empty -NasRoot vanished in the same join, leaving
             '-NasRoot -UserSid <sid>', which binds the SID to the wrong
             parameter. -NasRoot has no default on purpose, so this was the
             normal case, not an edge one.

        So: one string, every value quoted, and an omitted switch rather than an
        empty one. The rest of this file and the console already build their
        child command lines this way.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Root,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $NasRoot,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $UserSid
    )

    $line = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Root "{1}" -UserSid "{2}"' -f $ScriptPath, $Root, $UserSid
    if (-not [string]::IsNullOrWhiteSpace($NasRoot)) {
        $line += ' -NasRoot "{0}"' -f $NasRoot
    }
    return $line
}

if (-not $DefineOnly -and $IsWindows -and -not (Test-SimRigAdmin)) {
    $racerSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Write-Output 'SimRig self-test needs administrator rights. Windows will ask once; everything after that runs without asking again.'
    $childArgument = Get-SelfTestElevationArgument -ScriptPath $PSCommandPath -Root $Root -NasRoot $NasRoot -UserSid $racerSid
    try {
        $elevated = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $childArgument -Verb RunAs -PassThru -Wait
        exit $elevated.ExitCode
    }
    catch {
        Write-Output ''
        Write-Output 'That prompt was declined, so the self-test cannot run: it has to change Windows settings and put them back.'
        [void](Read-Host 'Press Enter to close')
        exit 3
    }
}
$script:RacerSid = $UserSid

# The same list the console uses, from the same place. It used to be eight file
# names written out here, last updated in v4.0: the preflight then compared 8
# hashes against the 45 files VERSIONS.md carries and called the other 37 missing.
$script:HashFile = Get-SimRigHashFileName -ScriptDir $PSScriptRoot
$script:Checks = [System.Collections.Generic.List[object]]::new()

function Add-SelfTestResult {
    [CmdletBinding()]
    # N/A: push 2 of the unit tune, step 8 (text 46): a check that does not apply to this PC. It is not
    # a SKIP: a run with N/A rows only is not INCOMPLETE.
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [ValidateSet('PASS', 'FAIL', 'WARN', 'SKIP', 'NOTE', 'N/A')] [string] $Status, [string] $Detail = '')
    $script:Checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    Write-Output ('{0,-4}  {1}{2}' -f $Status, $Name, $(if ($Detail) { " - $Detail" } else { '' }))
}

function Test-GpuPolicyCaught {
    <# A removed GPU interrupt policy, applied to a COPY of the real readings: preflight must fail and name it. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Fact, [Parameter(Mandatory)] [hashtable] $KnownGood, [Parameter(Mandatory)] [object[]] $Item)
    $gpu = @($Fact.GpuAffinity)
    if ($gpu.Count -eq 0) { return [pscustomobject]@{ Status = 'FAIL'; Detail = 'no NVIDIA instance was read, so the check has nothing to break' } }
    $copy = $Fact.Clone()
    $victim = $gpu[0]
    $copy.GpuAffinity = @([pscustomobject]@{ InstanceId = $victim.InstanceId; DeviceId = $victim.DeviceId; DevicePolicy = $null; AssignmentSetOverride = $null }) + @($gpu | Select-Object -Skip 1)
    $rows = Get-PreflightCheck -Fact $copy -KnownGood $KnownGood -QuietItem $Item
    $hit = @($rows | Where-Object { $_.Name -eq 'GPU interrupt steering' -and $_.Verdict -eq 'Fail' -and ([string]$_.Detail + [string]$_.Found) -match [regex]::Escape($victim.InstanceId.Split('\')[-1]) })
    if ($hit.Count -eq 0) { $hit = @($rows | Where-Object { $_.Name -eq 'GPU interrupt steering' -and $_.Verdict -eq 'Fail' }) }
    $status = if ($hit.Count -gt 0) { 'PASS' } else { 'FAIL' }
    return [pscustomobject]@{ Status = $status; Detail = $(if ($hit.Count) { 'Fail row: ' + [string]$hit[0].Detail } else { 'preflight did not fail' }) }
}

function Test-ScriptByteCaught {
    <# One byte added to a COPY of SimRig.Probe.ps1: the integrity check must fail and name the file. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Fact, [Parameter(Mandatory)] [hashtable] $KnownGood, [Parameter(Mandatory)] [object[]] $Item, [Parameter(Mandatory)] [string] $ScriptDir, [Parameter(Mandatory)] [string] $TempDir)
    foreach ($f in @($script:HashFile) + 'VERSIONS.md') {
        $src = Join-Path $ScriptDir $f
        if (-not (Test-Path -LiteralPath $src)) { continue }
        # The list carries subfolder paths now (engine/..., rules/...), so the copy
        # has to make the folder. Copy-Item to a folder that is not there writes a
        # FILE with that name, and the hash of the next one overwrites it.
        $dest = Join-Path $TempDir $f
        $destDir = Split-Path -Path $dest -Parent
        if (-not (Test-Path -LiteralPath $destDir)) { [void](New-Item -ItemType Directory -Path $destDir -Force) }
        Copy-Item -LiteralPath $src -Destination $dest -Force
    }
    Add-Content -LiteralPath (Join-Path $TempDir 'SimRig.Probe.ps1') -Value ' ' -NoNewline
    $copy = $Fact.Clone()
    $copy.FileHash = Get-SimRigFileHash -ScriptDir $TempDir -FileName $script:HashFile
    $copy.VersionsText = Read-SimRigTextFile -Path (Join-Path $TempDir 'VERSIONS.md')
    $rows = Get-PreflightCheck -Fact $copy -KnownGood $KnownGood -QuietItem $Item
    $hit = @($rows | Where-Object { $_.Name -eq 'Script integrity' -and $_.Verdict -eq 'Fail' -and [string]$_.Detail -match 'SimRig\.Probe\.ps1 hash mismatch' })
    $status = if ($hit.Count -gt 0) { 'PASS' } else { 'FAIL' }
    return [pscustomobject]@{ Status = $status; Detail = $(if ($hit.Count) { [string]$hit[0].Detail } else { 'the changed byte was not caught' }) }
}

function Test-ThemeResource {
    <# Builds the console window without showing it, and looks up every theme resource the XAML asks for. #>
    [CmdletBinding()]
    param()
    $window = Initialize-ConsoleView -Xaml $script:ConsoleXaml
    try {
        $keys = @([regex]::Matches($script:ConsoleXaml, '\{DynamicResource\s+([A-Za-z0-9_.]+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $missing = @($keys | Where-Object { $null -eq $window.TryFindResource($_) })
        # Smoke: every view function runs on sample data.
        Show-Banner -Kind Ok -Title 'Self-test' -Text 'sample'
        Show-CheckRow -Title 'Self-test' -Row @([pscustomobject]@{ Name = 'a'; Detail = 'b'; Value = 'c'; Source = 'd'; Verdict = 'Pass' })
        Add-TimelineEntry -Time '00:00:00' -Message 'sample' -Severity OK
        foreach ($m in @($script:ButtonModeMap.Keys)) { Show-ButtonSet -Mode $m }
        foreach ($n in 1..5) { Show-StepState -Step $n -State Done -Text '' }
        $status = if ($missing.Count -eq 0) { 'PASS' } else { 'FAIL' }
        return [pscustomobject]@{ Status = $status; Detail = $(if ($missing.Count) { 'missing: ' + ($missing -join ', ') } else { '{0} theme resources found; view functions ran' -f $keys.Count }) }
    }
    finally { $window.Close() }
}

function Invoke-ActionsChild {
    <# Runs SimRig.Actions.ps1 and returns (ExitCode, Result). Elevated unless -WhatIfRun. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)] [string] $SessionDir,
        [string[]] $Only,
        [switch] $Force,
        [switch] $WhatIfRun
    )
    $rid = [guid]::NewGuid().ToString()
    # -UserSid: G-12 again. Without it the child writes HKCU items into the hive
    # of whichever account is elevated, which on a machine where the racer is not
    # a local admin is the wrong profile entirely.
    $argLine = Get-ActionArgument -ActionsScript (Join-Path $PSScriptRoot 'SimRig.Actions.ps1') -Operation $Operation -RequestId $rid -SessionDir $SessionDir -Only $Only -Force:$Force -WhatIfRun:$WhatIfRun -UserSid $script:RacerSid
    $splat = @{ FilePath = (Get-Process -Id $PID).Path; ArgumentList = $argLine; PassThru = $true; Wait = $true; WindowStyle = 'Hidden' }
    if (-not $WhatIfRun) { $splat['Verb'] = 'RunAs' }
    $proc = Start-Process @splat
    $paths = Get-SimRigPath -Root $Root
    $result = Read-SimRigJson -Path (Get-ActionResultPath -ResultDir $paths.Results -Operation $Operation -RequestId $rid)
    [string[]]$invalid = Test-ActionResult -Result $result -RequestId $rid -Operation $Operation
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Result = $result; Invalid = $invalid }
}

function Test-ConsoleStartup {
    <#
        Opens the real console the way the shortcut does, with -StartupReport.
        The console writes its startup timing and closes itself once the
        preflight is on screen. Graded by Get-StartupVerdict (limits in
        known-good.psd1 Startup). Added in v4.0.3 after the 10 s blank start.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ReportPath, $Limit)
    if (Test-Path -LiteralPath $ReportPath) { Remove-Item -LiteralPath $ReportPath -Force }
    $argLine = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Root "{1}" -NasRoot "{2}" -StartupReport "{3}"' -f (Join-Path $PSScriptRoot 'SimRigConsole.ps1'), $Root, $NasRoot, $ReportPath
    $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argLine -PassThru -WindowStyle Minimized
    if (-not $proc.WaitForExit(90000)) {
        try { $proc.Kill() } catch { Write-Verbose 'console already gone' }
        return [pscustomobject]@{ Status = 'FAIL'; Detail = 'the console did not finish its startup within 90 s' }
    }
    $doc = Read-SimRigJson -Path $ReportPath
    if ($null -eq $doc) { return [pscustomobject]@{ Status = 'FAIL'; Detail = ('no startup report (console exit {0}) - see the console log' -f $proc.ExitCode) } }
    $v = Get-StartupVerdict -Timing $doc.Seconds -Limit $Limit
    $marks = ($doc.Seconds.PSObject.Properties | ForEach-Object { '{0} {1} s' -f $_.Name, $_.Value }) -join ', '
    $status = if (-not $v.Pass) { 'FAIL' } elseif ($v.Warn) { 'WARN' } else { 'PASS' }
    return [pscustomobject]@{ Status = $status; Detail = ('{0} [{1}]' -f $v.Line, $marks) }
}

function Get-SelfTestTuningSkip {
    <#
        Blocker 4, and push 2 of the unit tune, step 8 (texts 46 and 47 of the sheet, text D of
        PUSH2-TEXTS-ADDED-2026-10-04.md, each with Rick's "Yes"; the Cowork answer to the texts of push
        2, answer 3). The rows to report in place of a tuning check that does not run, or no row:
        - Rig: no row; the dry run and the round trip run.
        - Supported: the dry run runs; the round trip, which writes MPO, is N/A with text D: no tuning
          value is written on such a PC without a tick for that item, also not by a test.
        - NotSupported, or no state: both are N/A with text 47 and the reason of the state.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowNull()] $Support)

    $state = [string](Get-KnownGoodField -Entry $Support -Name 'State')
    if ($state -eq 'Rig') { return , @() }
    $roundTrip = 'Apply tuning then undo leaves MPO as it was'
    if ($state -eq 'Supported') {
        return , @([pscustomobject]@{ Name = $roundTrip; Status = 'N/A'; Detail = 'does not apply to this PC: the self-test does not write tuning settings here.' })
    }
    $reason = [string](Get-KnownGoodField -Entry $Support -Name 'Reason')
    $why = ('does not apply to this PC: this version does not change tuning settings on this PC. {0}' -f $reason).TrimEnd()
    return , @(
        [pscustomobject]@{ Name = 'Apply tuning dry run covers every row and writes nothing'; Status = 'N/A'; Detail = $why }
        [pscustomobject]@{ Name = $roundTrip; Status = 'N/A'; Detail = $why }
    )
}

function Get-SelfTestTuningSupport {
    <#
        Push 2 of the unit tune, step 8 (the repair after REVIEW-tune-0e63545.md, finding 3). The tuning
        state of the self-test: the rig by the profile of the computer name (Test-ProfileTuningAllowed),
        as the elevated step decides it (Get-ActionTuningSupport); on each other PC
        Get-SimRigTuningSupport from the machine reading. Pure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [bool] $TuningAllowed, [AllowNull()] $Machine, [AllowNull()] $RigProfile)
    if ($TuningAllowed) { return [pscustomobject]@{ State = 'Rig'; Reason = $null } }
    return Get-SimRigTuningSupport -Machine $Machine -RigProfile $RigProfile
}

function Get-SelfTestSummaryLine {
    <#
        The last line of the self-test, from its rows. Push 2 of the unit tune, step 8 (text 48): an N/A
        row is not counted as skipped, so it does not make a run INCOMPLETE; when there are N/A rows the
        line says their count after the note part.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()] [object[]] $Check)

    $all = @($Check | Where-Object { $null -ne $_ })
    # NOTE is neither pass nor problem: it is a line that records evidence, like the
    # steering history. It must not count toward the verdict in either direction -
    # an INCOMPLETE run because something was merely observed would be a lie.
    $note = @($all | Where-Object { $_.Status -eq 'NOTE' }).Count
    $fail = @($all | Where-Object { $_.Status -eq 'FAIL' }).Count
    $warn = @($all | Where-Object { $_.Status -eq 'WARN' }).Count
    $pass = @($all | Where-Object { $_.Status -eq 'PASS' }).Count
    $skip = @($all | Where-Object { $_.Status -eq 'SKIP' }).Count
    $na = @($all | Where-Object { $_.Status -eq 'N/A' }).Count
    # A skipped main test is not a pass: the round trip and the deadman are the point.
    $line = if ($fail -gt 0) { 'SELF-TEST FAILED - {0} fail, {1} pass, {2} warn, {3} skipped' -f $fail, $pass, $warn, $skip }
    elseif ($skip -gt 0) { 'SELF-TEST INCOMPLETE - {0} skipped (see SKIP lines), {1} pass, {2} warn' -f $skip, $pass, $warn }
    else { 'SELF-TEST PASSED - {0} pass, {1} warn' -f $pass, $warn }
    if ($note -gt 0) { $line = '{0}, {1} note' -f $line, $note }
    if ($na -gt 0) { $line = '{0}, {1} do not apply to this PC (see N/A lines)' -f $line, $na }
    return $line
}

function Get-SelfTestExitCode {
    <#
        beta1-fix2 E-2 (the rig re-test of 2026-10-15: "self-test exit code 4" next to SELF-TEST PASSED). Pure. The exit
        code of a run that reaches the end: 0 with no FAIL row and no SKIP row, else 1, as the line of
        Get-SelfTestSummaryLine (PASSED, or FAILED / INCOMPLETE). The last line of this file read $fail and $skip, which
        only that function sets, so strict mode stopped the run there and the trap gave exit 4 after each report.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowEmptyCollection()] [object[]] $Check)

    $all = @($Check | Where-Object { $null -ne $_ })
    $bad = @($all | Where-Object { @('FAIL', 'SKIP') -contains [string]$_.Status }).Count
    return $(if ($bad -eq 0) { 0 } else { 1 })
}

function Write-SelfTestTrapFile {
    <#
        beta1-fix2 E-2 (ANSWER-beta1-fix2-E2-cowork-2026-10-15.md item 1). Writes the message and the place of the error
        that stopped the self-test to trap.txt in the report folder of the run. With no folder, or a folder that is not
        there, it writes nothing. It never throws: it runs inside the trap.
    #>
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string] $Directory, [AllowNull()] $ErrorRecord)
    try {
        if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
        $lines = @(('SimRig self-test stopped: {0}' -f $(if ($ErrorRecord) { $ErrorRecord.Exception.Message } else { 'no error record' })))
        if ($ErrorRecord -and $ErrorRecord.InvocationInfo) {
            $lines += ('  at {0} line {1}' -f (Split-Path -Leaf ([string]$ErrorRecord.InvocationInfo.ScriptName)), $ErrorRecord.InvocationInfo.ScriptLineNumber)
        }
        [System.IO.File]::WriteAllText((Join-Path -Path $Directory -ChildPath 'trap.txt'), (($lines -join [Environment]::NewLine) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    }
    catch { Write-Output ('trap.txt not written: {0}' -f $_.Exception.Message) }
}

function Get-SelfTestDryRunId {
    <#
        Push 2 of the unit tune, step 8. The ids for the dry run of Apply tuning: on the rig $null (the
        child plans each item of known-good.psd1, as before); on a supported PC the items of the offer
        with Offer Write, because the child refuses an Apply there with no list (text A) and refuses an
        id that it does not offer as a write (text B). Pure.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Support, [AllowNull()] [AllowEmptyCollection()] [object[]] $Offer)

    if ([string](Get-KnownGoodField -Entry $Support -Name 'State') -eq 'Rig') { return $null }
    return , @(@($Offer) | Where-Object { $null -ne $_ -and [string](Get-KnownGoodField -Entry $_ -Name 'Offer') -eq 'Write' } | ForEach-Object { [string]$_.Id })
}

function Get-SelfTestDir {
    <#
        Commit 8 of the blocker 6 unit (REVIEW-blocker6-994c5a7.md, finding 1). Pure. The folder of one
        self-test run, Logs\v4\selftest\<stamp>, or a folder in it (-Child). The elevated child accepts a
        tuning folder under Logs\v4\selftest (Get-ActionTuningPathRefusal), so the run folder is made here
        and nowhere else, and a test gives this folder to the check of the child.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Logs, [Parameter(Mandatory)] [string] $Stamp, [string] $Child)

    $run = Join-Path -Path ($Logs + '\selftest') -ChildPath $Stamp
    if ($Child) { return (Join-Path -Path $run -ChildPath $Child) }
    return $run
}

function Get-SelfTestDryRunNone {
    <#
        Causes row 30 (the blocker 6 unit, condition D; Rick's "Yes", 2026-10-07). Pure. Why the dry run
        of Apply tuning does not run, or $null when it runs: NothingToWrite when this PC is offered items
        and none is a write (the row is N/A with text 13); NoItem when no item is offered at all (the row
        is FAIL with its own text: the design offers MPO and HAGS on each supported PC, so an empty offer
        is a fault of the app, and text 13 is not true there).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [AllowEmptyCollection()] [object[]] $DryId, [AllowNull()] [AllowEmptyCollection()] [object[]] $Offer)

    # $null: the rig, where the child plans the items of known-good.psd1.
    if ($null -eq $DryId -or @($DryId).Count -gt 0) { return $null }
    if (@(@($Offer) | Where-Object { $null -ne $_ }).Count -gt 0) { return 'NothingToWrite' }
    return 'NoItem'
}

function Get-SelfTestDryRunGpuRow {
    <#
        beta1-fix (REVIEW-beta1-fix-8a947a0.md finding 1). Pure. The rows that the dry run of Apply tuning plans for GPU
        steering: 0 with no steering item (a supported PC); 1 when the plan step of steering is Skip (the steered
        functions are at their values: the child adds one row with the Id GpuSteering, and the FixGpu writer does not
        run); else one row for each NVIDIA function, which the FixGpu writer gives. Before, the count was always one row
        for each function, and it was right on the rig only because the old value read the out-of-scope function 22BA.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowNull()] [AllowEmptyCollection()] [object[]] $TuneItem, [AllowNull()] [AllowEmptyCollection()] [object[]] $Row,
        [AllowNull()] [AllowEmptyCollection()] [object[]] $GpuAffinity)
    if (@(@($TuneItem) | Where-Object { $null -ne $_ -and $_.Kind -eq 'GpuSteering' }).Count -eq 0) { return 0 }
    if (@(@($Row) | Where-Object { $null -ne $_ -and [string]$_.Id -eq 'GpuSteering' }).Count -gt 0) { return 1 }
    return [Math]::Max(@(@($GpuAffinity) | Where-Object { $null -ne $_ }).Count, 1)
}

function Get-SelfTestDryRunGpuDevice {
    <#
        beta1-fix (REVIEW-beta1-fix-6ccb6be.md finding 1). Pure. The NVIDIA functions that the detail of the dry run row
        names as "GPU device(s)": 0 with no steering item (a supported PC), else each function of the reading. Not the
        count of rows (Get-SelfTestDryRunGpuRow): with the steering step Skip that is 1, and the rig has two functions.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowNull()] [AllowEmptyCollection()] [object[]] $TuneItem, [AllowNull()] [AllowEmptyCollection()] [object[]] $GpuAffinity)
    if (@(@($TuneItem) | Where-Object { $null -ne $_ -and $_.Kind -eq 'GpuSteering' }).Count -eq 0) { return 0 }
    return @(@($GpuAffinity) | Where-Object { $null -ne $_ }).Count
}

function Copy-SelfTestReportToShare {
    <#
        The last part of the self-test: copies the report folder to the share, or says where it is. Returns the line
        for the person. The rig run of 2026-10-10 (push 3 record rows 6 and 6a): the share was on the mapped drive Z:,
        which the elevated process does not have, and Join-Path threw "Cannot find drive" after the graded result,
        before the Test-Path of the share. The root is now tested first, so that case gives the "is not visible" line.
    #>
    param([string] $NasRoot, [string] $Source, [string] $OutDir, [string] $Stamp, [string] $SelfTestDir)
    if ([string]::IsNullOrWhiteSpace($NasRoot)) {
        return "No share is set, in this profile or on the command line. The report is in {0}." -f $OutDir
    }
    if (-not (Test-Path -LiteralPath $NasRoot)) {
        return "{0} (from the {1}) is not visible. The report is in {2}." -f $NasRoot, $Source.ToLowerInvariant(), $OutDir
    }
    $nas = Join-Path -Path $NasRoot -ChildPath 'session-data\v4-selftest'
    $dest = Join-Path $nas $Stamp
    [void](New-Item -ItemType Directory -Path $dest -Force)
    Copy-Item -Path (Join-Path $OutDir '*') -Destination $dest -Recurse -Force
    # Earlier runs whose window closed before their own copy step: copy them too.
    foreach ($d in @(Get-ChildItem -LiteralPath $SelfTestDir -Directory)) {
        $to = Join-Path $nas $d.Name
        if (-not (Test-Path -LiteralPath $to)) { Copy-Item -LiteralPath $d.FullName -Destination $nas -Recurse -Force }
    }
    return "Report copied to {0}. Tell Claude the self-test ran." -f $dest
}

if ($DefineOnly) { return }

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------

$paths = Get-SimRigPath -Root $Root
$started = Get-Date
$stamp = Get-SessionStamp -Time $started
$outDir = Get-SelfTestDir -Logs $paths.Logs -Stamp $stamp
[void](New-Item -ItemType Directory -Path $outDir -Force)

# One self-test at a time. On 2026-09-19 two ran at once (a double click): the
# second saw the first one's quiet session and skipped the main tests.
$lock = Join-Path -Path ($paths.Logs + '\selftest') -ChildPath 'running.lock'
if (Test-Path -LiteralPath $lock) {
    $other = (Get-Content -LiteralPath $lock -Raw).Trim()
    if ($other -match '^\d+$' -and (Get-Process -Id ([int]$other) -ErrorAction SilentlyContinue)) {
        Write-Output ('Another self-test is already running (process {0}). Let it finish; close this window.' -f $other)
        [void](Read-Host 'Press Enter to close')
        exit 2
    }
}
Set-Content -LiteralPath $lock -Value $PID
Write-Output ("SimRig v4 self-test - {0}. Leave this window open. One Windows prompt will appear; click Yes." -f $started.ToString('yyyy-MM-dd HH:mm'))
Write-Output ''

$items = $null; $kg = $null; $fact = $null
try {
    $listData = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'quiet-list.psd1')
    $kg = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'known-good.psd1')
    [string[]]$e1 = Test-QuietListData -Data $listData
    [string[]]$e2 = Test-KnownGoodData -Data $kg
    $errs = @($e1 | Where-Object { $_ }) + @($e2 | Where-Object { $_ })
    $items = ConvertTo-QuietItem -Data $listData
    Add-SelfTestResult -Name 'Data files load and validate' -Status $(if ($errs.Count) { 'FAIL' } else { 'PASS' }) -Detail $(if ($errs.Count) { $errs -join '; ' } else { '{0} quiet-list items' -f @($items).Count })
}
catch { Add-SelfTestResult -Name 'Data files load and validate' -Status FAIL -Detail $_.Exception.Message }

# Where the report gets copied. The share is a profile fact now, not a default in this
# file, so the self-test has to ask the profile the way the console does - otherwise
# the rig that has always had a share would quietly stop receiving reports.
# ComputerName is the only thing every profile matches on, and Select-SimRigProfile
# reads it through Get-KnownGoodField, so a small object is enough here: this script
# runs on its own and builds no machine profile.
$shareChoice = [pscustomobject]@{ Path = $NasRoot; Source = 'Given' }
# Blocker 4: the tuning rows below write only where the profile allows tuning. The
# elevated step decides it with the same key; here it decides what the rows check.
$selfTestTuningAllowed = $false
try {
    $profileDocument = Get-SimRigProfileDocument -Directory (Join-Path $PSScriptRoot 'profiles')
    $selfTestProfile = Select-SimRigProfile -RigProfile $profileDocument.Document -Machine @{ ComputerName = $env:COMPUTERNAME }
    $shareChoice = Get-SimRigShareRoot -Given $NasRoot -RigProfile $selfTestProfile
    $selfTestTuningAllowed = Test-ProfileTuningAllowed -RigProfile $selfTestProfile
}
catch {
    $shareChoice = Get-SimRigShareRoot -Given $NasRoot -RigProfile $null
    Write-Output ('Could not read the profiles folder, so no share came from a profile: {0}' -f $_.Exception.Message)
}
$NasRoot = [string]$shareChoice.Path

# Push 2 of the unit tune, step 8 (Causes row 16 of the record of commit 2): the tuning state of this PC
# and the values that the preflight grades with, made with the functions of the console. A machine
# reading that fails leaves the machine $null, and Get-SimRigTuningSupport then gives NotSupported with
# text 40, which the N/A rows show.
$selfTestMachine = $null
$selfTestRigProfile = $null
$selfTestRuleDocument = @()
try {
    $selfTestRigProfile = $selfTestProfile
    $selfTestRuleDocument = @((Get-SimRigRuleDocument -Directory (Join-Path $PSScriptRoot 'rules')).Document)
    $selfTestContext = Get-SimRigMachineContext -ProfileDocument @($profileDocument.Document) -MachineName $env:COMPUTERNAME -Settings $null
    $selfTestMachine = $selfTestContext.Machine
    $selfTestRigProfile = $selfTestContext.RigProfile
}
catch { $selfTestMachine = $null }
# The rig first, by the profile of the computer name, as the elevated step decides it
# (Get-ActionTuningSupport); on each other PC the state from the machine reading.
$selfTestSupport = Get-SelfTestTuningSupport -TuningAllowed $selfTestTuningAllowed -Machine $selfTestMachine -RigProfile $selfTestRigProfile

if ($null -ne $items) {
    try {
        # The ini folder comes from the PROFILE, the way the console resolves it.
        # It used to read $kg.IniDir, and known-good.psd1 stopped carrying that
        # on 2026-09-27 when one user's Documents path came out of the file every
        # user gets. Strict mode then threw "the property IniDir cannot be found
        # on this object", the preflight check failed, and every later check that
        # reads $fact failed with it - four reds from one removed key.
        $selfTestIniDir = ''
        try {
            $selfTestIniDir = [string](Get-SimRigIniDirChoice `
                    -FromProfile ([string](Get-KnownGoodField -Entry $selfTestProfile -Name 'IniDir')) `
                    -Discovered '').Path
        }
        catch { $selfTestIniDir = '' }
        $fact = Get-SimRigPreflightFact -QuietItem $items -KnownGood $kg -ScriptDir $PSScriptRoot -HashFile $script:HashFile -IniDir $selfTestIniDir
        # facts.json - the raw Probe readings, written before anything grades
        # them. Flag 2 of the v4.2 build: tests/Export-GoldenState.ps1 -FactJson
        # <this file> rebuilds every golden section from live rig readings, so
        # tier C runs the same compare the fixture runs.
        try {
            [System.IO.File]::WriteAllText((Join-Path $outDir 'facts.json'), ($fact | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
            Add-SelfTestResult -Name 'Raw readings saved for the golden compare' -Status PASS -Detail ('facts.json, {0} fields' -f @($fact.Keys).Count)
        }
        catch { Add-SelfTestResult -Name 'Raw readings saved for the golden compare' -Status FAIL -Detail $_.Exception.Message }
        # cpu-topology-buffer.json - the raw GetLogicalProcessorInformationEx
        # buffer, once, so the F-RIG fixture stops being synthetic. Every CPU
        # topology number in this project is a built buffer; the 96 MB L3 figure
        # is AMD's published number, not a reading of this rig. The capture
        # holds cache sizes and affinity masks only: no name, no path, no
        # serial, so it needs no anonymizer pass. A machine that refuses the
        # read still writes the document, saying there was no buffer.
        try {
            $cpuReading = Get-CpuTopologyReading -IncludeBuffer -CaptureTakenAt (Get-Date)
            $capture = $cpuReading['BufferCapture']
            if ($null -eq $capture) {
                Add-SelfTestResult -Name 'CPU topology buffer captured' -Status WARN -Detail 'No capture was produced. The reading is still in facts.json.'
            }
            else {
                [System.IO.File]::WriteAllText((Join-Path $outDir 'cpu-topology-buffer.json'), ($capture | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
                $detail = if ($capture.ByteCount -gt 0) {
                    'cpu-topology-buffer.json, {0} bytes, sha256 {1}' -f $capture.ByteCount, $capture.Sha256.Substring(0, 12)
                } else {
                    'cpu-topology-buffer.json, no buffer was readable on this PC'
                }
                $status = if ($capture.ByteCount -gt 0) { 'PASS' } else { 'WARN' }
                Add-SelfTestResult -Name 'CPU topology buffer captured' -Status $status -Detail $detail
            }
        }
        catch { Add-SelfTestResult -Name 'CPU topology buffer captured' -Status WARN -Detail $_.Exception.Message }
        # Causes row 16: on a PC that is not the rig the four tuning rows are graded from the rules and
        # the profile of this PC, as the console grades them, not from the values of the rig.
        $selfTestPreflightValue = Get-SimRigPreflightValue -KnownGood $kg -Support $selfTestSupport -Rule @($selfTestRuleDocument) `
            -RigProfile $selfTestRigProfile -Machine $selfTestMachine
        $rows = Get-PreflightCheck -Fact $fact -KnownGood $selfTestPreflightValue -QuietItem $items -Machine $selfTestMachine `
            -TuningState $selfTestSupport.State
        $sum = Get-PreflightSummary -Check $rows
        Add-SelfTestResult -Name 'Preflight runs' -Status PASS -Detail $sum.Line
        # Rig findings (a Fail or Warn row) are reported, not self-test failures.
        foreach ($r in @($rows | Where-Object { $_.Verdict -in @('Fail', 'Warn') })) {
            Add-SelfTestResult -Name ('  preflight row: {0}' -f $r.Name) -Status WARN -Detail ('{0}; expected {1}, found {2}' -f $r.Detail, (Format-ViewValue $r.Expected), (Format-ViewValue $r.Found))
        }
        # GPU identity for diagnosis (v4.0.6): the NVIDIA instance IDs changed at each boot on 2026-09-19.
        foreach ($g in @($fact.GpuAffinity)) {
            Add-SelfTestResult -Name ('  GPU device {0}' -f $g.DeviceId) -Status PASS -Detail ('id {0}; location {1}; parent {2}; policy {3}' -f $g.InstanceId, (Format-ViewValue $g.LocationPath), (Format-ViewValue $g.Parent), $(if ($null -eq $g.DevicePolicy) { 'none' } else { '{0}/0x{1:X}' -f $g.DevicePolicy, [uint64]$g.AssignmentSetOverride }))
        }
        $integ = @($rows | Where-Object { $_.Name -eq 'Script integrity' })
        $badInteg = @($integ | Where-Object { $_.Verdict -ne 'Pass' })
        Add-SelfTestResult -Name 'Installed files match VERSIONS.md' -Status $(if ($integ.Count -and -not $badInteg.Count) { 'PASS' } else { 'FAIL' }) -Detail $(if ($badInteg.Count) { ($badInteg | ForEach-Object { $_.Detail }) -join '; ' } else { '{0} files' -f $integ.Count })
    }
    catch { Add-SelfTestResult -Name 'Preflight runs' -Status FAIL -Detail $_.Exception.Message }
}

try { $t = Test-ThemeResource; Add-SelfTestResult -Name 'Console window builds, Fluent theme resources exist' -Status $t.Status -Detail $t.Detail }
catch { Add-SelfTestResult -Name 'Console window builds, Fluent theme resources exist' -Status FAIL -Detail $_.Exception.Message }

Write-Output '(The console opens for a few seconds and closes itself - that is the startup-time check.)'
try {
    $lim = if ($kg -and $kg.ContainsKey('Startup')) { $kg['Startup'] } else { $null }
    $t = Test-ConsoleStartup -ReportPath (Join-Path $outDir 'startup.json') -Limit $lim
    # A slow start is a number to watch, not a failed self-test. The rig takes
    # 8.5 s to the window against a 3 s limit and always has, so this row was red
    # on every run Rick will ever do - and a check that is always red teaches you
    # to skim past red. It still FAILS when the console does not open at all,
    # because that is a different thing entirely.
    $opened = Test-Path -LiteralPath (Join-Path $outDir 'startup.json')
    $status = if (-not $opened) { 'FAIL' } elseif ($t.Status -eq 'PASS') { 'PASS' } else { 'NOTE' }
    $detail = if ($opened -and $t.Status -ne 'PASS') { '{0} - recorded, not failed: the limit has never been met on this machine' -f $t.Detail } else { $t.Detail }
    Add-SelfTestResult -Name 'Console opens fast (window first, preflight in the background)' -Status $status -Detail $detail
}
catch { Add-SelfTestResult -Name 'Console opens fast (window first, preflight in the background)' -Status FAIL -Detail $_.Exception.Message }

if ($null -ne $fact) {
    try { $t = Test-GpuPolicyCaught -Fact $fact -KnownGood $kg -Item $items; Add-SelfTestResult -Name 'Preflight catches a removed GPU policy (on a copy of the readings)' -Status $t.Status -Detail $t.Detail }
    catch { Add-SelfTestResult -Name 'Preflight catches a removed GPU policy (on a copy of the readings)' -Status FAIL -Detail $_.Exception.Message }
    try {
        $tmp = Join-Path $outDir 'byte-test'
        [void](New-Item -ItemType Directory -Path $tmp -Force)
        $t = Test-ScriptByteCaught -Fact $fact -KnownGood $kg -Item $items -ScriptDir $PSScriptRoot -TempDir $tmp
        Add-SelfTestResult -Name 'Preflight catches a changed script byte (on a copy)' -Status $t.Status -Detail $t.Detail
    }
    catch { Add-SelfTestResult -Name 'Preflight catches a changed script byte (on a copy)' -Status FAIL -Detail $_.Exception.Message }
}

$lm = Test-LatencyMonReport -Text 'https://www.resplendence.com/latencymon'
Add-SelfTestResult -Name 'LatencyMon save refuses text that is not a report' -Status $(if (-not $lm.IsValid) { 'PASS' } else { 'FAIL' }) -Detail (@($lm.Reasons) -join '; ')

$bb = Get-SimRigBackblazeLastBackup
Add-SelfTestResult -Name 'Backblaze last-backup time readable' -Status $(if ($null -ne $bb) { 'PASS' } else { 'WARN' }) -Detail $(if ($null -ne $bb) { 'last backup {0}' -f $bb.ToString('yyyy-MM-dd HH:mm') } else { 'status file not found - the restore shows a WARN, never red' })

# The steering question (U4.25). The console writes one line per start; this
# reads them back and says what they add up to. It is a NOTE, never a failure:
# the answer is evidence being gathered, not a fault in this run.
$steeringRows = Get-SimRigSteeringRecord -Path $paths.SteeringHistory
$steeringVerdict = Get-SimRigSteeringHistoryVerdict -Record $steeringRows
Add-SelfTestResult -Name 'GPU steering across boots (evidence, not a test)' -Status $(
    if ($steeringVerdict.Verdict -eq 'NotEnough') { 'SKIP' } else { 'NOTE' }
) -Detail $steeringVerdict.Line

$marker = Test-Path -LiteralPath $paths.ActiveMarker
$racing = [bool](Get-Process -Name 'iRacingSim64DX11' -ErrorAction SilentlyContinue)
if ($null -eq $items -or $marker -or $racing) {
    $why = if ($marker) { 'a v4 session is still quiet - open the console and Restore first' } elseif ($racing) { 'iRacing is running' } else { 'data files did not load' }
    Add-SelfTestResult -Name 'Dry run changes nothing' -Status SKIP -Detail $why
    Add-SelfTestResult -Name 'Elevated round trip, revert, deadman' -Status SKIP -Detail $why
}
else {
    $noProc = @($items | Where-Object { $_.Kind -ne 'Process' })
    try {
        $before = Get-SimRigItemState -QuietItem $noProc
        $dry = Invoke-ActionsChild -Operation Quiet -SessionDir (Join-Path $outDir 'dryrun') -WhatIfRun
        $after = Get-SimRigItemState -QuietItem $noProc
        $changed = @(Compare-ItemState -QuietItem $noProc -Expected @($before | Where-Object { $_.Exists }) -Actual $after | Where-Object { -not $_.Match -and $_.Field -notin @('State', 'TaskState') })
        $ok = ($dry.Invalid.Count -eq 0 -and $dry.ExitCode -eq 0 -and $changed.Count -eq 0)
        $planned = if ($dry.Result) { @($dry.Result.Steps | Where-Object { $_.Status -eq 'WhatIf' }).Count } else { 0 }
        Add-SelfTestResult -Name 'Dry run changes nothing' -Status $(if ($ok) { 'PASS' } else { 'FAIL' }) -Detail $(if ($ok) { '{0} changes planned, 0 made' -f $planned } elseif ($dry.Invalid.Count) { $dry.Invalid -join '; ' } else { 'exit {0}; changed: {1}' -f $dry.ExitCode, (($changed | ForEach-Object { $_.Id }) -join ', ') })
    }
    catch { Add-SelfTestResult -Name 'Dry run changes nothing' -Status FAIL -Detail $_.Exception.Message }

    # --- v4.1: the tuning operations, proved on real Windows -----------------
    # A dry run first (nothing is written), then one real round trip on the MPO
    # value: write the value that is already there, then undo it from the
    # snapshot and compare. The brief asks for exactly this pair. Only where the
    # profile allows tuning; elsewhere each check is reported as not run.
    # Push 2 of the unit tune, step 8: Get-SelfTestTuningSkip gives the N/A rows, and the dry run runs
    # on the rig and on a supported PC. Assign, then count: the function returns the comma form.
    $tuningSkip = Get-SelfTestTuningSkip -Support $selfTestSupport
    foreach ($skipRow in $tuningSkip) { Add-SelfTestResult -Name $skipRow.Name -Status $skipRow.Status -Detail $skipRow.Detail }
    $skipName = @($tuningSkip | ForEach-Object { [string]$_.Name })
    if ($skipName -notcontains 'Apply tuning dry run covers every row and writes nothing') {
    try {
        $tuneDir = Get-SelfTestDir -Logs $paths.Logs -Stamp $stamp -Child 'tuning'
        $dryFact = @{ Registry = $fact.Registry; PowerScheme = $fact.PowerScheme; GpuAffinity = @($fact.GpuAffinity) }
        $dryRules = foreach ($doc in @($selfTestRuleDocument)) { @(Get-KnownGoodField -Entry $doc -Name 'Rules') }
        # Assign, then wrap: both functions return the comma form.
        $dryOffer = Get-SimRigTuningOffer -Support $selfTestSupport -Machine $selfTestMachine -Rule @($dryRules) `
            -ProfileValues (Get-KnownGoodField -Entry $selfTestRigProfile -Name 'Values') -KnownGood $kg -Fact $dryFact
        $dryId = Get-SelfTestDryRunId -Support $selfTestSupport -Offer @($dryOffer)
        # Causes row 30 (blocker 6 unit, condition D; Rick's "Yes", 2026-10-07): a check that did not
        # run is not a PASS. Items offered and none to write: N/A with text 13. No item offered at all:
        # FAIL with its own text (Rick's "Yes", 2026-10-07). The design offers MPO and HAGS on each
        # supported PC (rules W-MPO and W-HAGS, AppliesTo any), so an empty offer is a fault of the app.
        $dryNone = Get-SelfTestDryRunNone -DryId $dryId -Offer @($dryOffer)
        $nothingToWrite = ($dryNone -eq 'NothingToWrite')
        $noDryRun = ($null -ne $dryNone)
        if ($nothingToWrite) {
            # Text 13 of PUSH2-TEXTS-FOR-RICK-2026-10-03.md.
            Add-SelfTestResult -Name 'Apply tuning dry run covers every row and writes nothing' -Status 'N/A' `
                -Detail 'Each tuning value on this PC already has a value that the app accepts. There is nothing to write.'
        }
        elseif ($dryNone -eq 'NoItem') {
            Add-SelfTestResult -Name 'Apply tuning dry run covers every row and writes nothing' -Status FAIL `
                -Detail 'The app offers no tuning item on this PC, so the dry run did not run. This is a fault of the app: it did not find its rules for MPO and HAGS.'
        }
        elseif ($null -eq $dryId) {
            $dryTune = Invoke-ActionsChild -Operation ApplyTuning -SessionDir $tuneDir -WhatIfRun
            $tuneItems = Get-TuningItem -KnownGood $kg
        }
        else {
            # A supported PC with items to write (Get-SelfTestDryRunNone is $null here).
            $dryTune = Invoke-ActionsChild -Operation ApplyTuning -SessionDir $tuneDir -Only @($dryId) -WhatIfRun
            $tuneItems = @(@($dryOffer) | Where-Object { @($dryId) -contains [string]$_.Id })
        }
        if (-not $noDryRun) {
        $rows = if ($dryTune.Result) { @($dryTune.Result.Steps) } else { @() }
        # Assign, then wrap. Get-TuningItem returns the comma form, so
        # @(Get-TuningItem ...).Count reads 1 on every machine - the wrap takes the
        # returned array as one element instead of enumerating it. Rick's rig found
        # this on 2026-09-27: the row said "expected 1 rows, got 5".
        $planned = @{}
        foreach ($r in $rows) { $planned[[string]$r.Id] = $true }
        # One row per item, except GPU steering. That one goes through the FixGpu
        # writer, which emits one row per GPU device, so a rig with two GPUs plans
        # five rows for four items. Comparing the two counts failed on exactly that,
        # and it would have failed on any two-GPU machine. A supported PC has no
        # steering item, so its count is 0. beta1-fix: one row when the steering step is Skip.
        $gpuCount = Get-SelfTestDryRunGpuRow -TuneItem @($tuneItems) -Row @($rows) -GpuAffinity @($fact.GpuAffinity)
        # The detail names the functions, not the rows (REVIEW-beta1-fix-6ccb6be.md finding 1).
        $gpuDevice = Get-SelfTestDryRunGpuDevice -TuneItem @($tuneItems) -GpuAffinity @($fact.GpuAffinity)
        $want = 0
        $absent = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $tuneItems) {
            if ($item.Kind -eq 'GpuSteering') { $want += $gpuCount; continue }
            $want++
            if (-not $planned.ContainsKey([string]$item.Id)) { $absent.Add([string]$item.Id) }
        }
        $noSnapshot = -not (Test-Path -LiteralPath (Join-Path $tuneDir 'tuning-snapshot.json'))
        $ok = ($dryTune.Invalid.Count -eq 0 -and $absent.Count -eq 0 -and $rows.Count -eq $want -and $noSnapshot)
        Add-SelfTestResult -Name 'Apply tuning dry run covers every row and writes nothing' `
            -Status $(if ($ok) { 'PASS' } else { 'FAIL' }) `
            -Detail $(if ($ok) {
                    '{0} rows planned for {1} item(s) ({2} GPU device(s)), no snapshot written' -f $rows.Count, @($tuneItems).Count, $gpuDevice
                }
                else {
                    'expected {0} rows for {1} item(s) and {2} GPU device(s), got {3}{4}{5}; invalid: {6}' -f `
                        $want, @($tuneItems).Count, $gpuDevice, $rows.Count, `
                        $(if ($absent.Count) { '; no row for: ' + ($absent -join ', ') } else { '' }), `
                        $(if (-not $noSnapshot) { '; a snapshot was written during a dry run' } else { '' }), `
                        ($dryTune.Invalid -join '; ')
                })
        }
    }
    catch { Add-SelfTestResult -Name 'Apply tuning dry run covers every row and writes nothing' -Status FAIL -Detail $_.Exception.Message }
    }

    # The round trip writes MPO, so it runs on the rig only (step 8; on a supported PC it is N/A, text D).
    if ($skipName -notcontains 'Apply tuning then undo leaves MPO as it was') {
    try {
        $roundDir = Get-SelfTestDir -Logs $paths.Logs -Stamp $stamp -Child 'tuning-roundtrip'
        $mpoEntry = @(@($kg.Registry) | Where-Object { $_.Name -eq 'MPO' })[0]
        $beforeMpo = Get-SimRigRegistryValue -Path $mpoEntry.Path -Value $mpoEntry.Value
        $apply = Invoke-ActionsChild -Operation ApplyTuning -SessionDir $roundDir -Only @('Mpo') -Force
        $midMpo = Get-SimRigRegistryValue -Path $mpoEntry.Path -Value $mpoEntry.Value
        $undo = Invoke-ActionsChild -Operation UndoTuning -SessionDir $roundDir -Only @('Mpo')
        $afterMpo = Get-SimRigRegistryValue -Path $mpoEntry.Path -Value $mpoEntry.Value
        $wrote = @($apply.Result.Steps | Where-Object { $_.Id -eq 'Mpo' -and $_.Status -eq 'Done' }).Count -eq 1
        $same = ([string]$beforeMpo -eq [string]$afterMpo)
        $ok = ($apply.Invalid.Count -eq 0 -and $undo.Invalid.Count -eq 0 -and $wrote -and $same)
        Add-SelfTestResult -Name 'Apply tuning then undo leaves MPO as it was' `
            -Status $(if ($ok) { 'PASS' } else { 'FAIL' }) `
            -Detail ('was {0}, after the write {1}, after the undo {2}; snapshot {3}' -f `
                $(if ($null -eq $beforeMpo) { 'not set' } else { $beforeMpo }), `
                $(if ($null -eq $midMpo) { 'not set' } else { $midMpo }), `
                $(if ($null -eq $afterMpo) { 'not set' } else { $afterMpo }), `
                $(if ($apply.Result) { $apply.Result.SnapshotPath } else { 'none' }))
    }
    catch { Add-SelfTestResult -Name 'Apply tuning then undo leaves MPO as it was' -Status FAIL -Detail $_.Exception.Message }
    }

    Write-Output ''
    Write-Output 'Next: the elevated part (about 3 minutes). Click Yes on the Windows prompt.'
    try {
        $elevDir = Join-Path $outDir 'elevated'
        $run = Invoke-ActionsChild -Operation SelfTest -SessionDir $elevDir
        if ($run.Invalid.Count) {
            Add-SelfTestResult -Name 'Elevated round trip, revert, deadman' -Status FAIL -Detail ('no usable result ({0}); exit {1} - if you clicked No on the prompt, run the self-test again' -f ($run.Invalid -join '; '), $run.ExitCode)
        }
        else {
            $detail = Read-SimRigJson -Path (Join-Path $elevDir 'selftest-elevated.json')
            if ($null -eq $detail) {
                Add-SelfTestResult -Name 'Elevated round trip, revert, deadman' -Status FAIL -Detail ('exit {0}: {1}' -f $run.ExitCode, (@($run.Result.Errors) -join ' '))
            }
            else {
                foreach ($c in @($detail.Check)) { Add-SelfTestResult -Name $c.Name -Status $(if ($c.Pass) { 'PASS' } else { 'FAIL' }) -Detail $c.Detail }
            }
        }
    }
    catch { Add-SelfTestResult -Name 'Elevated round trip, revert, deadman' -Status FAIL -Detail $_.Exception.Message }
}

# --------------------------------------------------------------------------
# Report - local, then the NAS copy Claude reads
# --------------------------------------------------------------------------

$all = $script:Checks.ToArray()
# Push 2 of the unit tune, step 8: one function for the line, so that text 48 is testable.
$line = Get-SelfTestSummaryLine -Check @($all)
# The build under test, read STRAIGHT from VERSIONS.md rather than through the
# preflight fact. On 2026-09-28 the fact failed before it got that far, the report
# said "Version": null, and an hour went into arguing about which build had been
# tested. A report that cannot name its build is evidence of nothing.
$versionsText = Read-SimRigTextFile -Path (Join-Path $PSScriptRoot 'VERSIONS.md')
if ([string]::IsNullOrWhiteSpace($versionsText) -and $fact) { $versionsText = $fact.VersionsText }
$versions = Get-VersionsHeader -Text $versionsText
$report = [ordered]@{
    Schema = 'simrig.selftest/1'; Rig = $env:COMPUTERNAME; StartedAt = (Format-SimRigTime -Time $started); FinishedAt = (Format-SimRigTime -Time (Get-Date))
    Version = $versions.Version; Commit = $versions.Commit; Pwsh = [string]$PSVersionTable.PSVersion; Line = $line; Check = $all
}
[System.IO.File]::WriteAllText((Join-Path $outDir 'selftest.json'), ($report | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
$text = @($line, ('v{0} commit {1}, pwsh {2}, {3}' -f $versions.Version, $versions.Commit, $PSVersionTable.PSVersion, $env:COMPUTERNAME), '') + @($all | ForEach-Object { '{0,-4}  {1}{2}' -f $_.Status, $_.Name, $(if ($_.Detail) { " - $($_.Detail)" } else { '' }) })
[System.IO.File]::WriteAllText((Join-Path $outDir 'selftest.txt'), ($text -join [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $paths.Logs 'actions.log') -Destination $outDir -Force -ErrorAction SilentlyContinue
# The console log of the startup-time check (it has the "startup seconds:" line).
$consoleLog = Get-SimRigNewestFile -Directory (Split-Path -Path $paths.ConsoleLogPattern -Parent) -Filter 'console_*.log' -Since $started
if ($consoleLog) { Copy-Item -LiteralPath $consoleLog.FullName -Destination $outDir -Force -ErrorAction SilentlyContinue }
# Evidence from real sessions since yesterday, so Claude can read what happened
# without asking: every console log and every action result file of the last 24 h.
$since = $started.AddHours(-24)
$recent = Join-Path $outDir 'recent'
[void](New-Item -ItemType Directory -Path $recent -Force)
# Blocker 7, commit 6 (O3): the log files of the child too. This script runs elevated, so it does not append them to
# actions.log; the window does that at its next start.
foreach ($pair in @(@((Split-Path -Path $paths.ConsoleLogPattern -Parent), 'console_*.log'), @($paths.Results, '*.json'), @($paths.Results, '*.log'))) {
    Get-ChildItem -LiteralPath $pair[0] -Filter $pair[1] -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $since } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $recent -Force -ErrorAction SilentlyContinue }
}

Write-Output ''
Write-Output $line
# Join-Path and Test-Path both throw on an empty root, and Join-Path throws on a drive that the process does not have;
# the function answers both before it joins a path.
Write-Output (Copy-SelfTestReportToShare -NasRoot $NasRoot -Source $shareChoice.Source -OutDir $outDir -Stamp $stamp -SelfTestDir ($paths.Logs + '\selftest'))
Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
[void](Read-Host 'Press Enter to close')
# beta1-fix2 E-2: the code from the rows; $fail and $skip are not set at this level.
exit (Get-SelfTestExitCode -Check @($all))
