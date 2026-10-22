# quiet-list.psd1 - every item the console may quiet, and how.
#
# AppliesTo was added per item by unit U3.8 (wave 3b, 2026-09-26) and applied by
# the lead, so an item can be limited to the machines it suits. Read the caveat
# in meta/changes: the data is proven correct against Test-RuleApplies, but the
# Quiet action does not filter on it yet.

@{
    Schema = 'simrig.quiet-list/1'
    Items  = @(

        # --- Order 1: WaaSMedicSvc first, so it cannot re-enable the rest ---
        @{
            Kind = 'Service'; Name = 'WaaSMedicSvc'; Order = 1; Group = 'A'; Action = 'Disable'
            Reason   = 'Update Medic runs on a ~10 min cycle and repairs a tampered update stack - it must go first or it undoes every other update-stack change this session'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.1 (measured in reference trace); the v1 diagnostics quiet-set script WatchOnly list, promoted to a quiet item for v4'
            RestoreTo = 'snapshot'; Fallback = @{ StartType = 'Manual' }
        }

        # --- Order 2: Defender real-time ---
        @{
            Kind = 'Defender'; Name = 'RealtimeMonitoring'; Order = 2; Group = 'v3.9'; Action = 'Off'
            Reason   = 'Real-time scanning on iRacing/CapFrameX/Trophi.ai file I/O during a race is a stutter source'
            Evidence = 'v3.9 pre_iracing_launch.bat line 38 (Set-MpPreference -DisableRealtimeMonitoring $true)'
            RestoreTo = 'snapshot'; Fallback = @{ On = $true }
            # Flag 15: opt-in, and off unless the selected profile says otherwise.
            # Switching off a stranger's virus scanner is not a default anybody gets
            # to choose on their behalf, however well it works on this rig.
            AppliesTo = @{ DefenderOptIn = $true }
        }

        # --- Order 3: Automatic Maintenance switch (3.6a) ---
        @{
            Kind = 'Registry'
            Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'
            Value = 'MaintenanceDisabled'; Data = 1; RegType = 'DWord'
            Order = 3; Group = '3.6a'; Action = 'Set'; Absent = 'create-then-delete'
            Reason   = 'Automatic Maintenance fires ~30 tasks in one burst mid-session; one switch replaces editing all of them individually'
            Evidence = 'our task log 2026-09-19 08:54:16 (30-task burst); TODO 3.6a; key confirmed absent on this build in the 08:38 fixture, so it is created for the session and deleted on restore (TODO 3.6c)'
            RestoreTo = 'snapshot'; Fallback = @{ Delete = $true }
        }

        # ============================= Group A =============================
        # TODO 3.1: measured in the reference trace.
        @{
            Kind = 'Service'; Name = 'InstallService'; Order = 10; Group = 'A'; Action = 'Disable'
            Reason   = 'Microsoft Store install/update service - part of the update stack quieted for the session'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.1 Group A'
            RestoreTo = 'snapshot'; Fallback = @{ StartType = 'Manual' }
        }
        @{
            Kind = 'Service'; Name = 'edgeupdate'; Order = 11; Group = 'A'; Action = 'Disable'
            Reason   = 'Edge Update service - background update traffic during the race'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.1 Group A'
            RestoreTo = 'snapshot'; Fallback = @{ StartType = 'AutomaticDelayed' }
        }
        @{
            Kind = 'Service'; Name = 'edgeupdatem'; Order = 12; Group = 'A'; Action = 'Disable'
            Reason   = 'Edge Update medic service - repairs the Edge updater the same way WaaSMedic repairs Windows Update'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.1 Group A'
            RestoreTo = 'snapshot'; Fallback = @{ StartType = 'Manual' }
        }
        @{
            Kind = 'Service'; Name = 'PcaSvc'; Order = 13; Group = 'A'; Action = 'Disable'
            Reason   = 'Program Compatibility Assistant - background scanning not needed during a race'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.1 Group A'
            RestoreTo = 'snapshot'; Fallback = @{ StartType = 'AutomaticDelayed' }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\WindowsUpdate\'; Name = 'Scheduled Start'
            Order = 14; Group = 'A'; Action = 'Disable'
            Reason   = 'Scheduled Windows Update scan start - part of the Group A update-stack task set'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.1 Group A; task confirmed present, state Ready, in the 2026-09-19_0838 fixture'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Application Experience\'; Name = 'MareBackup'
            Order = 15; Group = 'A'; Action = 'Disable'
            Reason   = 'Application Experience task set (1 of 5) - compatibility telemetry, not needed mid-race'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.1 Group A (5 Application Experience tasks)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser Exp'
            Order = 16; Group = 'A'; Action = 'Disable'
            Reason   = 'Application Experience task set (2 of 5)'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.1 Group A (5 Application Experience tasks)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Application Experience\'; Name = 'PcaPatchDbTask'
            Order = 17; Group = 'A'; Action = 'Disable'
            Reason   = 'Application Experience task set (3 of 5)'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.1 Group A (5 Application Experience tasks)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Application Experience\'; Name = 'SdbinstMergeDbTask'
            Order = 18; Group = 'A'; Action = 'Disable'
            Reason   = 'Application Experience task set (4 of 5)'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.1 Group A (5 Application Experience tasks)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Application Experience\'; Name = 'StartupAppTask'
            Order = 19; Group = 'A'; Action = 'Disable'
            Reason   = 'Application Experience task set (5 of 5)'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.1 Group A (5 Application Experience tasks)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }

        # ============================= Group B =============================
        # TODO 3.2: update-stack gaps.
        @{
            Kind = 'Service'; Name = 'bits'; Order = 20; Group = 'B'; Action = 'Disable'
            Reason   = 'Background Intelligent Transfer Service; also seen drifting demand -> auto and back mid-session unprompted (3.6c) - disabling removes the ambiguity'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.2 Group B; our task log 2026-09-19: start type changed demand->auto at 10:38:56, auto->demand at 10:41:02 (tasksched-session2.csv / session-log.md 2026-09-19 Session 2), which no script of ours did'
            RestoreTo = 'snapshot'; Fallback = @{ StartType = 'Manual' }
        }
        @{
            Kind = 'Service'; Name = 'DoSvc'; Order = 21; Group = 'B'; Action = 'Disable'
            Reason   = 'Delivery Optimization - peer update distribution, update-stack gap'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.2 Group B'
            RestoreTo = 'snapshot'; Fallback = @{ StartType = 'AutomaticDelayed' }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\WaaSMedic\'; Name = 'PerformRemediation'
            Order = 22; Group = 'B'; Action = 'Disable'
            Reason   = 'The one task under the WaaSMedic path; pairs with the WaaSMedicSvc service so the remediation task cannot run even if the service is later restarted by Windows'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.2 Group B ("...and WaaSMedic tasks"); task confirmed present, state Ready, in the 2026-09-19_0838 fixture'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }

        # ===== Group B, rest of the four task folders (Opus review 2026-09-19) =====
        # TODO 3.2 names whole folders. v3.9 covers some tasks; these are the rest
        # that are enabled on the known-good rig. Tasks already Disabled on the
        # known-good rig (Schedule Maintenance Work, Schedule Wake To Work) and the
        # OOBE-only InstallService\RestoreDevice are left out.
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\InstallService\'; Name = 'SmartRetry'
            Order = 23; Group = 'B'; Action = 'Disable'
            Reason   = 'Update-stack task in a TODO 3.2 folder; can start an update scan or install mid-session'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.2 Group B (whole folder); present and Ready in known-good-2026-09-19_0857/tasks-state.csv'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\InstallService\'; Name = 'WakeUpAndContinueUpdates'
            Order = 23; Group = 'B'; Action = 'Disable'
            Reason   = 'Update-stack task in a TODO 3.2 folder; can start an update scan or install mid-session'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.2 Group B (whole folder); present and Ready in known-good-2026-09-19_0857/tasks-state.csv'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\InstallService\'; Name = 'WakeUpAndScanForUpdates'
            Order = 23; Group = 'B'; Action = 'Disable'
            Reason   = 'Update-stack task in a TODO 3.2 folder; can start an update scan or install mid-session'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.2 Group B (whole folder); present and Ready in known-good-2026-09-19_0857/tasks-state.csv'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Report policies'
            Order = 23; Group = 'B'; Action = 'Disable'
            Reason   = 'Update-stack task in a TODO 3.2 folder; can start an update scan or install mid-session'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.2 Group B (whole folder); present and Ready in known-good-2026-09-19_0857/tasks-state.csv'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'USO_UxBroker'
            Order = 23; Group = 'B'; Action = 'Disable'
            Reason   = 'Update-stack task in a TODO 3.2 folder; can start an update scan or install mid-session'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.2 Group B (whole folder); present and Ready in known-good-2026-09-19_0857/tasks-state.csv'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'UUS Failover Task'
            Order = 23; Group = 'B'; Action = 'Disable'
            Reason   = 'Update-stack task in a TODO 3.2 folder; can start an update scan or install mid-session'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.2 Group B (whole folder); present and Ready in known-good-2026-09-19_0857/tasks-state.csv'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'UIEOrchestrator'
            Order = 23; Group = 'B'; Action = 'Disable'
            Reason   = 'Update-stack task in a TODO 3.2 folder; can start an update scan or install mid-session'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.2 Group B (whole folder); present and Ready in known-good-2026-09-19_0857/tasks-state.csv'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'StartOobeAppsScanAfterUpdate'
            Order = 23; Group = 'B'; Action = 'Disable'
            Reason   = 'Update-stack task in a TODO 3.2 folder; can start an update scan or install mid-session'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.2 Group B (whole folder); present and Ready in known-good-2026-09-19_0857/tasks-state.csv'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'StartOobeAppsScan_LicenseAccepted'
            Order = 23; Group = 'B'; Action = 'Disable'
            Reason   = 'Update-stack task in a TODO 3.2 folder; can start an update scan or install mid-session'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.2 Group B (whole folder); present and Ready in known-good-2026-09-19_0857/tasks-state.csv'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        # ========================= Group C =================================
        # TODO 3.3 promoted to v4.0 (Rick 2026-09-19). Named one by one as well as
        # the Maintenance switch: some of these have their own time triggers, and
        # spec 4 lists group C as list content.
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Defrag\'; Name = 'ScheduledDefrag'
            Order = 45; Group = 'C'; Action = 'Disable'
            Reason   = 'Heavy maintenance task; low risk to defer until after the race'
            Evidence = 'TODO 3.3 Group C; ScheduledDefrag, SilentCleanup (08:54:46), Chkdsk ProactiveScan, StartComponentCleanup and StateRepository fired in our task log 2026-09-19 08:54:16 burst'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\DiskCleanup\'; Name = 'SilentCleanup'
            Order = 45; Group = 'C'; Action = 'Disable'
            Reason   = 'Heavy maintenance task; low risk to defer until after the race'
            Evidence = 'TODO 3.3 Group C; ScheduledDefrag, SilentCleanup (08:54:46), Chkdsk ProactiveScan, StartComponentCleanup and StateRepository fired in our task log 2026-09-19 08:54:16 burst'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\DiskFootprint\'; Name = 'Diagnostics'
            Order = 45; Group = 'C'; Action = 'Disable'
            Reason   = 'Heavy maintenance task; low risk to defer until after the race'
            Evidence = 'TODO 3.3 Group C; ScheduledDefrag, SilentCleanup (08:54:46), Chkdsk ProactiveScan, StartComponentCleanup and StateRepository fired in our task log 2026-09-19 08:54:16 burst'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\DiskFootprint\'; Name = 'StorageSense'
            Order = 45; Group = 'C'; Action = 'Disable'
            Reason   = 'Heavy maintenance task; low risk to defer until after the race'
            Evidence = 'TODO 3.3 Group C; ScheduledDefrag, SilentCleanup (08:54:46), Chkdsk ProactiveScan, StartComponentCleanup and StateRepository fired in our task log 2026-09-19 08:54:16 burst'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Chkdsk\'; Name = 'ProactiveScan'
            Order = 45; Group = 'C'; Action = 'Disable'
            Reason   = 'Heavy maintenance task; low risk to defer until after the race'
            Evidence = 'TODO 3.3 Group C; ScheduledDefrag, SilentCleanup (08:54:46), Chkdsk ProactiveScan, StartComponentCleanup and StateRepository fired in our task log 2026-09-19 08:54:16 burst'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Maintenance\'; Name = 'WinSAT'
            Order = 45; Group = 'C'; Action = 'Disable'
            Reason   = 'Heavy maintenance task; low risk to defer until after the race'
            Evidence = 'TODO 3.3 Group C; ScheduledDefrag, SilentCleanup (08:54:46), Chkdsk ProactiveScan, StartComponentCleanup and StateRepository fired in our task log 2026-09-19 08:54:16 burst'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Servicing\'; Name = 'StartComponentCleanup'
            Order = 45; Group = 'C'; Action = 'Disable'
            Reason   = 'Heavy maintenance task; low risk to defer until after the race'
            Evidence = 'TODO 3.3 Group C; ScheduledDefrag, SilentCleanup (08:54:46), Chkdsk ProactiveScan, StartComponentCleanup and StateRepository fired in our task log 2026-09-19 08:54:16 burst'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Registry\'; Name = 'RegIdleBackup'
            Order = 45; Group = 'C'; Action = 'Disable'
            Reason   = 'Heavy maintenance task; low risk to defer until after the race'
            Evidence = 'TODO 3.3 Group C; ScheduledDefrag, SilentCleanup (08:54:46), Chkdsk ProactiveScan, StartComponentCleanup and StateRepository fired in our task log 2026-09-19 08:54:16 burst'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\StateRepository\'; Name = 'MaintenanceTasks'
            Order = 45; Group = 'C'; Action = 'Disable'
            Reason   = 'Heavy maintenance task; low risk to defer until after the race'
            Evidence = 'TODO 3.3 Group C; ScheduledDefrag, SilentCleanup (08:54:46), Chkdsk ProactiveScan, StartComponentCleanup and StateRepository fired in our task log 2026-09-19 08:54:16 burst'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        # ===== Store auto-download policy (Group A, TODO 3.1) =====
        @{
            Kind = 'Registry'
            Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
            Value = 'AutoDownload'; Data = 2; RegType = 'DWord'
            Order = 19; Group = 'A'; Action = 'Set'; Absent = 'create-then-delete'
            Reason   = 'Stops Store app auto-download and install during the session (2 = off)'
            Evidence = 'TODO 3.1 Group A, from no6969el kit v3.3.2; documented Windows Store policy value; absent on a default build, so created for the session and deleted on restore'
            RestoreTo = 'snapshot'; Fallback = @{ Delete = $true }
        }

        # ========================= Group 3.6b ==============================
        # TODO 3.6b: group-D subset that measurably fired in our own task log
        # during the 08:37-08:59 session window.
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Flighting\FeatureConfig\'; Name = 'ReconcileFeatures'
            Order = 30; Group = '3.6b'; Action = 'Disable'
            Reason   = 'Flighting/feature-config reconciliation fired repeatedly in the 08:37-08:59 window'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.6a/3.6b (measured on our rig 2026-09-19)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Flighting\FeatureConfig\'; Name = 'UsageDataReceiver'
            Order = 31; Group = '3.6b'; Action = 'Disable'
            Reason   = 'Flighting usage-data receiver fired in the same window'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.6b'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Flighting\OneSettings\'; Name = 'RefreshCache'
            Order = 32; Group = '3.6b'; Action = 'Disable'
            Reason   = 'OneSettings cache refresh fired repeatedly in the 08:37-08:59 window'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.6a/3.6b (measured on our rig 2026-09-19)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Hotpatch\'; Name = 'Monitoring'
            Order = 33; Group = '3.6b'; Action = 'Disable'
            Reason   = 'Hotpatch monitoring fired in the practice-session window'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.6a/3.6b (measured on our rig 2026-09-19)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Sysmain\'; Name = 'WsSwapAssessmentTask'
            Order = 34; Group = '3.6b'; Action = 'Disable'
            Reason   = 'Memory-swap assessment fired in the practice-session window'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.6a/3.6b (measured on our rig 2026-09-19)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\DeviceDirectoryClient\'; Name = 'RegisterUserDevice'
            Order = 35; Group = '3.6b'; Action = 'Disable'
            Reason   = 'Device-directory registration fired in the practice-session window'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.6b'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\DeviceDirectoryClient\'; Name = 'RegisterDevicePeriodic24'
            Order = 36; Group = '3.6b'; Action = 'Disable'
            Reason   = 'Device-directory periodic 24h registration fired in the practice-session window'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.6b'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        # NOTE: TODO 3.6b also names MicrosoftEdgeUpdateTaskMachineUA. It is not
        # repeated here as its own item - Get-QuietItemId would collide with the
        # v3.9-group entry for the same Path+Name below (Id must be unique,
        # CONTRACT.md Item identity). One entry, Order=78, Group='v3.9', covers it.
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Start Oobe Expedite Work'
            Order = 38; Group = '3.6b'; Action = 'Disable'
            Reason   = 'Update Orchestrator OOBE-expedite work fired in the practice-session window'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.6a/3.6b (measured on our rig 2026-09-19)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Diagnosis\'; Name = 'Scheduled'
            Order = 39; Group = '3.6b'; Action = 'Disable'
            Reason   = 'Diagnosis scheduled task fired in the practice-session window'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.6b'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClient'
            Order = 40; Group = '3.6b'; Action = 'Disable'
            Reason   = 'Feedback DmClient fired in the practice-session window (also in the 3.6a burst list)'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.6a/3.6b (measured on our rig 2026-09-19)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip'
            Order = 41; Group = '3.6b'; Action = 'Disable'
            Reason   = 'USB CEIP task fired in the practice-session window (also in the 3.6a burst list)'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.6a/3.6b (measured on our rig 2026-09-19)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }

        # --- 3.6a: Defender Scheduled Scan (the named exception to the switch) ---
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Windows Defender\'; Name = 'Windows Defender Scheduled Scan'
            Order = 42; Group = '3.6a'; Action = 'Disable'
            Reason   = 'Named separately from the Maintenance switch because Defender scheduling is not gated by MaintenanceDisabled the same way the rest of the burst is'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.6a burst list ("Windows Defender Scheduled Scan..."); task confirmed present, state Ready, in the 2026-09-19_0838 fixture'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }

        # ========================= Group 3.6c ==============================
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Schedule Work'
            Order = 43; Group = '3.6c'; Action = 'Disable'
            Reason   = 'Fired mid-session in session 2 and ran usoclient.exe - a real update-stack task our v3.9 list did not cover'
            Evidence = 'our task log 2026-09-19 10:48:23 (tasksched-session2.csv); TODO-v4-launch-kit-2026-09-16.md 3.6c'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }

        # ============================ v3.9 set ==============================
        # D1: the full v3.9 pre_iracing_launch.bat / post_iracing_session.bat
        # quiet set, carried into v4 verbatim.
        @{
            Kind = 'Service'; Name = 'wuauserv'; Order = 50; Group = 'v3.9'; Action = 'Disable'
            Reason   = 'Windows Update service - prevents a mid-session Windows Update restart'
            Evidence = 'v3.9 pre_iracing_launch.bat line 74 (sc config wuauserv start= disabled)'
            RestoreTo = 'snapshot'; Fallback = @{ StartType = 'Manual' }
        }
        @{
            Kind = 'Service'; Name = 'UsoSvc'; Order = 51; Group = 'v3.9'; Action = 'Disable'
            Reason   = 'Update Orchestrator Service - paired with wuauserv in the v3.9 update-stack quiet'
            Evidence = 'v3.9 pre_iracing_launch.bat line 81 (sc config UsoSvc start= disabled)'
            RestoreTo = 'snapshot'; Fallback = @{ StartType = 'Automatic' }
        }
        @{
            Kind = 'Service'; Name = 'WSearch'; Order = 52; Group = 'v3.9'; Action = 'Disable'
            Reason   = 'Windows Search indexing competes for disk I/O during a race'
            Evidence = 'v3.9 pre_iracing_launch.bat line 87 (sc config WSearch start= disabled)'
            RestoreTo = 'snapshot'; Fallback = @{ StartType = 'AutomaticDelayed' }
        }
        @{
            Kind = 'Service'; Name = 'Spooler'; Order = 53; Group = 'v3.9'; Action = 'Stop'
            AppliesTo = @{ Profile = 'rcs-rig' }  # G-5 (V4.2-SPEC 6a): opt-in, off by default for a public profile
            Reason   = 'Print Spooler - stopped only, not needed during a race'
            Evidence = 'v3.9 pre_iracing_launch.bat line 104 (sc stop Spooler)'
            RestoreTo = 'snapshot'; Fallback = @{ State = 'Running' }
        }
        @{
            Kind = 'Service'; Name = 'WlanSvc'; Order = 54; Group = 'v3.9'; Action = 'Stop'
            # G-1 (V4.2-SPEC 6a): never offered when the active adapter is Wi-Fi.
            # Ethernet only, and deliberately not 'any' as well: Test-RuleApplies
            # treats 'any' as always-match only when it is the sole value, so in a
            # list it is just a literal nothing ever equals. An unread adapter
            # already fails to match, which is the safe answer - do not switch off
            # someone's wireless because discovery could not tell what they are on.
            AppliesTo = @{ NetworkAdapter = 'Ethernet' }
            Reason   = 'WiFi - the rig races wired; stopped to remove a background network source'
            Evidence = 'v3.9 pre_iracing_launch.bat line 108 (sc stop WlanSvc)'
            RestoreTo = 'snapshot'; Fallback = @{ State = 'Running' }
        }
        @{
            Kind = 'Service'; Name = 'bthserv'; Order = 57; Group = 'v3.9'; Action = 'Stop'
            AppliesTo = @{ Profile = 'rcs-rig'; BluetoothConnected = $false }  # G-2 (V4.2-SPEC 6a): opt-in, never offered while a BT device is connected. BluetoothConnected is a proposed machine-profile field - see U3.8 report, Ask for lead
            Reason   = 'Bluetooth Support Service - not needed during a race'
            Evidence = 'v3.9 pre_iracing_launch.bat line 116 (sc stop bthserv)'
            RestoreTo = 'snapshot'; Fallback = @{ State = 'Running' }
        }
        @{
            Kind = 'Service'; Name = 'BTAGService'; Order = 56; Group = 'v3.9'; Action = 'Stop'
            AppliesTo = @{ Profile = 'rcs-rig'; BluetoothConnected = $false }  # G-2, same as bthserv above
            Reason   = 'Bluetooth Audio Gateway Service - not needed during a race'
            Evidence = 'v3.9 pre_iracing_launch.bat line 114 (sc stop BTAGService)'
            RestoreTo = 'snapshot'; Fallback = @{ State = 'Running' }
        }
        @{
            Kind = 'Service'; Name = 'BthAvctpSvc'; Order = 55; Group = 'v3.9'; Action = 'Stop'
            AppliesTo = @{ Profile = 'rcs-rig'; BluetoothConnected = $false }  # G-2, same as bthserv above
            Reason   = 'AVCTP service (Bluetooth) - not needed during a race'
            Evidence = 'v3.9 pre_iracing_launch.bat line 112 (sc stop BthAvctpSvc)'
            RestoreTo = 'snapshot'; Fallback = @{ State = 'Running' }
        }
        @{
            Kind = 'Service'; Name = 'XblAuthManager'; Order = 58; Group = 'v3.9'; Action = 'Stop'
            AppliesTo = @{ Profile = 'rcs-rig' }  # G-5 (V4.2-SPEC 6a): opt-in, off by default for a public profile
            Reason   = 'Xbox Live Auth Manager - background auth traffic not needed during a race'
            Evidence = 'v3.9 pre_iracing_launch.bat line 120 (sc stop XblAuthManager)'
            RestoreTo = 'snapshot'; Fallback = @{ State = 'Running' }
        }
        @{
            Kind = 'Service'; Name = 'bzserv'; Order = 59; Group = 'v3.9'; Action = 'Stop'
            AppliesTo = @{ Profile = 'rcs-rig' }  # G-3 (V4.2-SPEC 6a): moved to my-apps.psd1 as a public suggestion; kept here, gated to Rick's profile, so his session behaviour does not change
            Reason   = 'Backblaze - background backup I/O paused for the race; restore verifies it resumes (TODO 4.6)'
            Evidence = 'v3.9 pre_iracing_launch.bat line 124-128 (sc stop bzserv)'
            RestoreTo = 'snapshot'; Fallback = @{ State = 'Running' }
        }

        @{
            Kind = 'Registry'
            Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Value = 'AppCaptureEnabled'
            Data = 0; RegType = 'DWord'; Order = 60; Group = 'v3.9'; Action = 'Set'
            Reason   = 'Xbox Game Bar background capture is a stutter source'
            Evidence = 'v3.9 pre_iracing_launch.bat line 57 (reg add ...GameDVR AppCaptureEnabled 0)'
            RestoreTo = 'snapshot'; Fallback = @{ Data = 1 }
        }
        @{
            Kind = 'Registry'
            Path = 'HKCU:\Software\Microsoft\GameBar'; Value = 'AllowAutoGameMode'
            Data = 0; RegType = 'DWord'; Order = 61; Group = 'v3.9'; Action = 'Set'
            AppliesTo = @{ Ccd = 1 }  # flag 6 / O-1 (spec line 77): Game Mode items never apply to dual-CCD - AMD's X3D driver needs Game Mode ON there. A-FIX-04.
            Reason   = 'Disables auto Game Mode, which the rig does not want engaging on its own'
            Evidence = 'v3.9 pre_iracing_launch.bat line 65 (reg add ...GameBar AllowAutoGameMode 0)'
            RestoreTo = 'snapshot'; Fallback = @{ Delete = $true }
        }
        @{
            Kind = 'Registry'
            Path = 'HKCU:\Software\Microsoft\GameBar'; Value = 'AutoGameModeEnabled'
            Data = 0; RegType = 'DWord'; Order = 62; Group = 'v3.9'; Action = 'Set'
            AppliesTo = @{ Ccd = 1 }  # flag 6 / O-1, same as AllowAutoGameMode above. A-FIX-04.
            Reason   = 'Disables Game Mode auto-enable, paired with AllowAutoGameMode'
            Evidence = 'v3.9 pre_iracing_launch.bat line 66 (reg add ...GameBar AutoGameModeEnabled 0)'
            RestoreTo = 'snapshot'; Fallback = @{ Delete = $true }
        }
        @{
            Kind = 'Registry'
            Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\USB'; Value = 'DisableSelectiveSuspend'
            Data = 1; RegType = 'DWord'; Order = 63; Group = 'v3.9'; Action = 'Set'
            Reason   = 'USB selective suspend can add input latency on the wheel/pedals mid-race'
            Evidence = 'v3.9 pre_iracing_launch.bat line 70 (reg add ...USB DisableSelectiveSuspend 1)'
            RestoreTo = 'snapshot'; Fallback = @{ Delete = $true }
        }

        # v3.9 task list (D1: named explicitly, no wildcards)
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\InstallService\'; Name = 'ScanForUpdates'
            Order = 70; Group = 'v3.9'; Action = 'Disable'
            Reason   = 'Periodic-scan task quieted by the v3.9 bat'
            Evidence = 'v3.9 pre_iracing_launch.bat line 99; task confirmed Disabled in the 2026-09-19_0838 fixture (already applied for that session)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\InstallService\'; Name = 'ScanForUpdatesAsUser'
            Order = 71; Group = 'v3.9'; Action = 'Disable'
            Reason   = 'Periodic-scan task quieted by the v3.9 bat'
            Evidence = 'v3.9 pre_iracing_launch.bat line 99; task confirmed Disabled in the 2026-09-19_0838 fixture'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Schedule Scan'
            Order = 72; Group = 'v3.9'; Action = 'Disable'
            Reason   = 'Periodic-scan task quieted by the v3.9 bat'
            Evidence = 'v3.9 pre_iracing_launch.bat line 99; task confirmed present, state Ready (pre-quiet), in the 2026-09-19_0838 fixture'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'Schedule Scan Static Task'
            Order = 73; Group = 'v3.9'; Action = 'Disable'
            Reason   = 'Periodic-scan task quieted by the v3.9 bat'
            Evidence = 'v3.9 pre_iracing_launch.bat line 99; task confirmed present, state Ready (pre-quiet), in the 2026-09-19_0838 fixture'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\PushToInstall\'; Name = 'LoginCheck'
            Order = 74; Group = 'v3.9'; Action = 'Disable'
            Reason   = 'Store push-install login check, quieted by the v3.9 bat'
            Evidence = 'v3.9 pre_iracing_launch.bat line 99; task confirmed Disabled in the 2026-09-19_0838 fixture'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\PushToInstall\'; Name = 'Registration'
            Order = 75; Group = 'v3.9'; Action = 'Disable'
            Reason   = 'Store push-install registration, quieted by the v3.9 bat'
            Evidence = 'v3.9 pre_iracing_launch.bat line 99; task confirmed Disabled in the 2026-09-19_0838 fixture'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\LanguageComponentsInstaller\'; Name = 'ReconcileLanguageResources'
            Order = 76; Group = 'v3.9'; Action = 'Disable'
            Reason   = 'Language pack reconciliation, quieted by the v3.9 bat'
            Evidence = 'v3.9 pre_iracing_launch.bat line 99; task confirmed Disabled in the 2026-09-19_0838 fixture'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\'; Name = 'MicrosoftEdgeUpdateTaskMachineCore'
            Order = 77; Group = 'v3.9'; Action = 'Disable'
            Reason   = 'Edge updater core task; v3.9 matches this by wildcard (MicrosoftEdgeUpdateTaskMachine*), named explicitly here per CONTRACT (no wildcards in v4)'
            Evidence = 'v3.9 pre_iracing_launch.bat line 99 (wildcard match); task confirmed present at root path in the 2026-09-19_0838 fixture'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\'; Name = 'MicrosoftEdgeUpdateTaskMachineUA'
            Order = 78; Group = 'v3.9'; Action = 'Disable'
            Reason   = 'Edge updater UA task; v3.9 matches this by wildcard, named explicitly here per CONTRACT. Same item TODO 3.6b also names - kept as this single entry so its Id is unique (see 3.6b comment above)'
            Evidence = 'v3.9 pre_iracing_launch.bat line 99 (wildcard match); TODO 3.6b; task confirmed present at root path in the 2026-09-19_0838 fixture'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }

        # v3.9 processes (close only, no restore)
        @{
            Kind = 'Process'; Name = 'OneDrive'; Order = 90; Group = 'v3.9'; Action = 'Close'
            AppliesTo = @{ Profile = 'rcs-rig' }  # G-4 (V4.2-SPEC 6a): moved to my-apps.psd1, empty by default; kept here gated to Rick's profile
            Reason   = 'Prevents OneDrive sync conflicts with the iRacing Documents folder mid-race'
            Evidence = 'v3.9 pre_iracing_launch.bat line 131 (taskkill /IM OneDrive.exe /F)'
            RestoreTo = 'none'; Verdict = 'None'
        }
        @{
            Kind = 'Process'; Name = 'chrome'; Order = 91; Group = 'v3.9'; Action = 'Close'
            AppliesTo = @{ Profile = 'rcs-rig' }  # G-4, same as OneDrive above
            Reason   = 'Frees CPU/GPU headroom and removes a background network source'
            Evidence = 'v3.9 pre_iracing_launch.bat line 137 (taskkill /IM chrome.exe /F)'
            RestoreTo = 'none'; Verdict = 'None'
        }
        @{
            Kind = 'Process'; Name = 'Claude'; Order = 92; Group = 'v3.9'; Action = 'Close'
            AppliesTo = @{ Profile = 'rcs-rig' }  # G-4, same as OneDrive above
            Reason   = 'Closes Claude/Cowork before a race so it cannot compete for CPU/GPU'
            Evidence = 'v3.9 pre_iracing_launch.bat lines 141-153 (taskkill /IM Claude.exe, graceful then forced)'
            RestoreTo = 'none'; Verdict = 'None'
        }
        # ========================= Group D =================================
        # TODO 3.4, built in v4.1 by unit U1.2 and folded in by the lead
        # 2026-09-20. Telemetry and flighting tasks. The 3.6b items measured
        # firing are already above, in v4.0; these are the rest of 3.4.
        # AppliesTo is data only in v4.1. The engine reads it from Phase 3
        # (unit U3.8), and CONTRACT.md records the field in its v4.2 section.
        # ===== Measured: fired during session 2, 10:39-11:07 (session-log.md 2026-09-19,
        # "Session 2 (10:39-11:07): restore verified clean, quiet list gaps measured") =====
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\DeviceDirectoryClient\'; Name = 'RegisterDeviceProtectionStateChanged'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'Required'
            Reason   = 'Device-directory protection-state registration fired mid-session while driving, alongside RegisterUserDevice (already on the list from 3.6b) - the same folder, measured a second time on a different run'
            Evidence = 'session-log.md 2026-09-19 "Session 2 (10:39-11:07)": "Tasks that ran while driving (10:39-11:07), 7 total: ... DeviceDirectoryClient\RegisterDeviceProtectionStateChanged and RegisterUserDevice ..."; TODO-v4-launch-kit-2026-09-16.md 3.4 names DeviceDirectoryClient; task confirmed Ready in known-good-2026-09-19_0857/tasks-state.csv'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }

        # ===== TODO 3.4 direct name matches (one task each, unmeasured) =====
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Windows Error Reporting\'; Name = 'QueueReporting'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Windows Error Reporting queue processing - background I/O and network, not needed mid-race; TODO 3.4 names this task by its exact folder and task name'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("WER QueueReporting"); task confirmed present, state Ready, in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures (tasks-state.csv); never individually measured firing on this rig, so Verdict=None (applied for hygiene, does not gate the healthy verdict)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\WindowsAI\Settings\'; Name = 'InitialConfiguration'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Windows AI Settings initial-configuration task; TODO 3.4 names "WindowsAI InitialConfiguration" - disambiguated against \WindowsAI\Recall\InitialConfiguration, which is already Disabled on this build and is a different feature (Recall) TODO 3.4 does not name'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("WindowsAI InitialConfiguration"); task confirmed present, state Ready, at \Microsoft\Windows\WindowsAI\Settings\ in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures (the sibling \WindowsAI\Recall\InitialConfiguration is state Disabled in the same fixtures and is left out - already off, and not the task TODO 3.4 means)'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }

        # ===== FeatureConfig folder, remaining enabled tasks (siblings of ReconcileFeatures
        # and UsageDataReceiver, already promoted to v4.0 by 3.6b as measured-firing) =====
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Flighting\FeatureConfig\'; Name = 'GovernedFeatureUsageProcessing'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Flighting/feature-config task in the same folder as the two 3.6b items measured firing in the 08:37-08:59 window; TODO 3.4 names the FeatureConfig folder'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("FeatureConfig"); task confirmed present, state Ready, in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures; not itself individually measured firing, so Verdict=None'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Flighting\FeatureConfig\'; Name = 'ReconcileConfigs'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Flighting/feature-config task in the same folder as the two 3.6b items measured firing in the 08:37-08:59 window; TODO 3.4 names the FeatureConfig folder'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("FeatureConfig"); task confirmed present, state Ready, in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures; not itself individually measured firing, so Verdict=None'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Flighting\FeatureConfig\'; Name = 'SafeguardsReconciliation'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Flighting/feature-config task in the same folder as the two 3.6b items measured firing in the 08:37-08:59 window; TODO 3.4 names the FeatureConfig folder'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("FeatureConfig"); task confirmed present, state Ready, in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures; not itself individually measured firing, so Verdict=None'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Flighting\FeatureConfig\'; Name = 'UsageDataFlushing'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Flighting/feature-config task in the same folder as the two 3.6b items measured firing in the 08:37-08:59 window; TODO 3.4 names the FeatureConfig folder'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("FeatureConfig"); task confirmed present, state Ready, in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures; not itself individually measured firing, so Verdict=None'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Flighting\FeatureConfig\'; Name = 'UsageDataReporting'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Flighting/feature-config task in the same folder as the two 3.6b items measured firing in the 08:37-08:59 window; TODO 3.4 names the FeatureConfig folder'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("FeatureConfig"); task confirmed present, state Ready, in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures; not itself individually measured firing, so Verdict=None'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }

        # ===== Feedback folder, remaining enabled task (sibling of Siuf\DmClient, already
        # promoted to v4.0 by 3.6b) =====
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClientOnScenarioDownload'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Feedback DmClient variant in the same folder as the 3.6b item measured firing in the 08:37-08:59 window; TODO 3.4 names Feedback'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("Feedback"); task confirmed present, state Ready, in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures; not itself individually measured firing, so Verdict=None'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }

        # ===== DeviceDirectoryClient folder, remaining enabled tasks (siblings of
        # RegisterUserDevice/RegisterDevicePeriodic24, 3.6b, and RegisterDeviceProtection-
        # StateChanged, measured above) =====
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\DeviceDirectoryClient\'; Name = 'HandleCommand'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Device-directory task in the same folder as items measured firing in both sessions; TODO 3.4 names DeviceDirectoryClient'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("DeviceDirectoryClient"); task confirmed present, state Ready, in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures; not itself individually measured firing, so Verdict=None'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\DeviceDirectoryClient\'; Name = 'HandleWnsCommand'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Device-directory task in the same folder as items measured firing in both sessions; TODO 3.4 names DeviceDirectoryClient'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("DeviceDirectoryClient"); task confirmed present, state Ready, in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures; not itself individually measured firing, so Verdict=None'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\DeviceDirectoryClient\'; Name = 'LocateCommandUserSession'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Device-directory task in the same folder as items measured firing in both sessions; TODO 3.4 names DeviceDirectoryClient'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("DeviceDirectoryClient"); task confirmed present, state Ready, in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures; not itself individually measured firing, so Verdict=None'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\DeviceDirectoryClient\'; Name = 'RegisterDeviceAccountChange'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Device-directory task in the same folder as items measured firing in both sessions; TODO 3.4 names DeviceDirectoryClient'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("DeviceDirectoryClient"); task confirmed present, state Ready, in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures; not itself individually measured firing, so Verdict=None'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\DeviceDirectoryClient\'; Name = 'RegisterDeviceLocationRightsChange'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Device-directory task in the same folder as items measured firing in both sessions; TODO 3.4 names DeviceDirectoryClient'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("DeviceDirectoryClient"); task confirmed present, state Ready, in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures; not itself individually measured firing, so Verdict=None'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\DeviceDirectoryClient\'; Name = 'RegisterDevicePolicyChange'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Device-directory task in the same folder as items measured firing in both sessions; TODO 3.4 names DeviceDirectoryClient'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("DeviceDirectoryClient"); task confirmed present, state Ready, in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures; not itself individually measured firing, so Verdict=None'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }
        @{
            Kind = 'Task'; Path = '\Microsoft\Windows\DeviceDirectoryClient\'; Name = 'RegisterDeviceWnsFallback'
            Order = 46; Group = 'D'; Action = 'Disable'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any' }
            Verdict = 'None'
            Reason   = 'Device-directory task in the same folder as items measured firing in both sessions; TODO 3.4 names DeviceDirectoryClient'
            Evidence = 'TODO-v4-launch-kit-2026-09-16.md 3.4 ("DeviceDirectoryClient"); task confirmed present, state Ready, in the 2026-09-19_0838 and known-good-2026-09-19_0857 fixtures; not itself individually measured firing, so Verdict=None'
            RestoreTo = 'snapshot'; Fallback = @{ Enabled = $true }
        }

        # NOTE on CEIP and OneSettings: TODO 3.4 also names CEIP and OneSettings. Both
        # folders have exactly one enabled task each on this build (Customer Experience
        # Improvement Program\UsbCeip; Flighting\OneSettings\RefreshCache) and both are
        # already in quiet-list.psd1 from 3.6b (measured firing). No further item is added
        # here for either - see NOTES.md.
    )
}

<#
    NOT ON THIS BUILD

    - Store auto-download policy: ADDED by Opus review (Order 19). The value
      is a documented Windows policy, not a parsed token, and create-then-delete
      covers its absence on this build.

    - WindowsUpdate\Automatic App Update (TODO 3.1, Group A). Not present in
      tasks-state.csv: the only tasks under \Microsoft\Windows\WindowsUpdate\
      on this build are "Refresh Group Policy Cache" and "Scheduled Start"
      (the latter is included above). Runtime skip covers this too (spec S4);
      this item is left out of Items rather than spelled from memory.

    - Store auto-download policy (TODO 3.1, Group A). No fixture captures a
      registry path for this policy, and CONTRACT.md forbids guessing a
      token, so no Registry item was added. If this is wanted for v4, it
      needs a real reg query capture first (likely
      HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore or
      HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager -
      unconfirmed, do not use without a capture).

    - TabletInputService. Confirmed absent on this build: sc-qc.txt shows
      "[SC] OpenService FAILED 1060: The specified service does not exist"
      for TabletInputService (spec S4/TODO 3.5 example item). It was never a
      v4.0 scope item (groups A+B/C/3.6a/3.6b/3.6c/v3.9 do not name it) -
      recorded here only because the spec and TODO both use it as the
      worked example of a "missing on this build" item, and it is worth
      confirming that example holds against real data.
#>
