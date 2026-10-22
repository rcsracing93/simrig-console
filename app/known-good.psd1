# known-good.psd1 - SimRig Console v4.0
# Schema: simrig.known-good/1 (CONTRACT.md). Preflight expected values.
# Preflight runs BEFORE the quiet, so every Services/Tasks entry below is the
# known-good ENABLED state (flag 5, CONTRACT.md), read from
# known-good-2026-09-19_0857/ (the repaired, restored rig) - never the
# quieted state.
#
# D2 (CONTRACT.md): persistent tuning (GPU steering, MPO, HAGS, power plan,
# timer resolution) is read-only in v4.0. This file only records expected
# values for preflight to grade against; nothing here writes the system.

@{
    Schema = 'simrig.known-good/1'

    # --- GPU interrupt steering (spec S4, TODO Stage 2) ---------------------
    # Confirmed against gpu-affinity-policy.txt: 4 DEV_2684 (display) PCI
    # instances at DevicePolicy=4 / AssignmentSetOverride=0x80 (decimal 128 =
    # CPU7), plus 1 DEV_22BA (GPU audio function) instance at DevicePolicy=4 /
    # AssignmentSetOverride=0x40 (decimal 64 = CPU6) - 5 real policy entries
    # total (the fixture also lists 3 "Affinity Policy - Temporal" containers
    # with no DevicePolicy set; those are not counted).
    GpuSteering = @{
        VendorId = 'VEN_10DE'
        # 2 = the PRESENT NVIDIA PCI functions: the RTX 4090 display function (DEV_2684)
        # and its audio function (DEV_22BA). Read by the self-test on the rig
        # 2026-09-19. The earlier 5 counted registry keys, which include old,
        # non-present instances; the probe reads present devices only.
        ExpectedInstanceCount = 2
        Default   = @{ DevicePolicy = 4; AssignmentSetOverride = 0x80; Cpu = 7 }
        Overrides = @(
            @{ DeviceId = 'DEV_22BA'; DevicePolicy = 4; AssignmentSetOverride = 0x40; Cpu = 6
               Reason = 'GPU audio function, deliberate (Rick 2026-09-19)' }
        )
        Provisional = $true
        ProvisionalReason = 'S.1 open: CPU7 target not yet re-checked under S4 Physics Islands (V4-SPEC-2026-09-19.md 12)'
    }

    # --- Registry (read-only preflight checks) -------------------------------
    Registry = @(
        # Graded Pass/Fail:
        @{ Name = 'MPO'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'; Value = 'OverlayTestMode'
           Expected = 5; Source = 'registry' }   # confirmed: mpo.txt 0x5
        @{ Name = 'HAGS'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Value = 'HwSchMode'
           Expected = 1; Source = 'registry' }   # confirmed: hwschmode.txt 0x1 (off)

        # Record-only (Expected=$null): iRacing 3b.2/3b.5 items with no
        # known-good registry capture in these fixtures. Preflight shows
        # these as Info, not Pass/Fail (documented per subagent-1 task).
        @{ Name = 'Auto HDR'; Path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'; Value = 'DirectXUserGlobalSettings'
           Expected = $null; Source = 'registry'; Note = 'record only - no known-good capture; TODO 3b.2' }
        @{ Name = 'Game Bar AllowAutoGameMode'; Path = 'HKCU:\Software\Microsoft\GameBar'; Value = 'AllowAutoGameMode'
           Expected = $null; Source = 'registry'; Note = 'record only - quiet-list sets this to 0 for the session; pre-quiet value has no known-good capture, TODO 3b.5' }
        @{ Name = 'Game Mode AutoGameModeEnabled'; Path = 'HKCU:\Software\Microsoft\GameBar'; Value = 'AutoGameModeEnabled'
           Expected = $null; Source = 'registry'; Note = 'record only - quiet-list sets this to 0 for the session; pre-quiet value has no known-good capture, TODO 3b.5' }
        @{ Name = 'USB Selective Suspend'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\USB'; Value = 'DisableSelectiveSuspend'
           Expected = $null; Source = 'registry'; Note = 'record only - quiet-list sets this to 1 for the session; pre-quiet value has no known-good capture, TODO 3b.5' }

        # Reported, not required (v3.9 bat reports this, does not require it -
        # subagent-1 task documents the choice explicitly):
        @{ Name = 'Global Timer Resolution'
           Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'; Value = 'GlobalTimerResolutionRequests'
           Expected = $null; Source = 'registry'; Severity = 'Info'
           Note = 'v3.9 pre_iracing_launch.bat reports this (read-only), it does not require it - kept Info here, not a Pass/Fail gate' }
    )

    PowerScheme = @{ Guid = 'c584c850-222a-4f65-ae2c-fe6e5b7a0c40'; Name = 'AMD Ryzen Balanced' }   # confirmed: powerplan.txt
    # Grade = $false: before the race nothing asks Windows for 0.5 ms (iRacing does,
    # once it runs), so a pre-race reading of 1 ms is normal - recorded, not graded.
    TimerResolution = @{ MaxMs = 0.5; ToleranceMs = 0.01; Grade = $false }

    # Console startup, graded by the self-test (v4.0.3). Seconds from process start.
    Startup = @{ WindowMaxSeconds = 3; PreflightMaxSeconds = 20 }

    # --- Services: known-good ENABLED start type (flag 5) --------------------
    # Every quiet-list Service Id has an entry here (Data.Tests.ps1 checks this).
    # Source: known-good-2026-09-19_0857/sc-qc.txt (StartType) and sc-query.txt
    # (State), the repaired/restored rig - not the 08:38 mid-quiet capture.
    Services = @{
        'WaaSMedicSvc'   = @{ StartType = 'Manual';          State = 'Running' }
        'InstallService' = @{ StartType = 'Manual';          State = 'Running' }
        'edgeupdate'     = @{ StartType = 'AutomaticDelayed'; State = 'Stopped' }
        'edgeupdatem'    = @{ StartType = 'Manual';          State = 'Stopped' }
        'PcaSvc'         = @{ StartType = 'AutomaticDelayed'; State = 'Running' }
        'bits'           = @{ StartType = 'Manual';          State = 'Stopped'; AlsoAccept = @('AutomaticDelayed'); SelfSwitches = @('Manual', 'AutomaticDelayed') }   # BITS switches itself Manual <-> AutomaticDelayed (rig 2026-09-19 19:31, mid self-test)
        'DoSvc'          = @{ StartType = 'AutomaticDelayed'; State = 'Running' }
        'wuauserv'       = @{ StartType = 'Manual';          State = 'Running'; AlsoAccept = @('Automatic') }   # AlsoAccept: Windows Update sets Automatic by itself (rig 2026-09-19 after a clean reboot). Disabled still fails (flag 5).
        'UsoSvc'         = @{ StartType = 'Automatic';       State = 'Running' }
        'WSearch'        = @{ StartType = 'AutomaticDelayed'; State = 'Running' }
        'Spooler'        = @{ StartType = 'Automatic';       State = 'Running' }
        'WlanSvc'        = @{ StartType = 'Automatic';       State = 'Running' }
        'bthserv'        = @{ StartType = 'Manual';          State = 'Running' }
        'BTAGService'    = @{ StartType = 'Manual';          State = 'Running' }
        'BthAvctpSvc'    = @{ StartType = 'Manual';          State = 'Running' }
        'XblAuthManager' = @{ StartType = 'Manual';          State = 'Stopped' }
        'bzserv'         = @{ StartType = 'Automatic';       State = 'Running' }
    }

    # --- Tasks: known-good Enabled=$true (flag 5) -----------------------------
    # Every quiet-list Task Id has an entry here (Data.Tests.ps1 checks this).
    # Source: known-good-2026-09-19_0857/tasks-state.csv - every one of these
    # reads back "Ready" (Enabled) on the restored rig.
    Tasks = @{
        '\Microsoft\Windows\InstallService\SmartRetry' = @{ Enabled = $true }
        '\Microsoft\Windows\InstallService\WakeUpAndContinueUpdates' = @{ Enabled = $true; WindowsManaged = $true }   # WindowsManaged: Windows Update changes this by itself (rig 2026-09-19 after a clean reboot) - recorded, not graded
        '\Microsoft\Windows\InstallService\WakeUpAndScanForUpdates' = @{ Enabled = $true; WindowsManaged = $true }   # WindowsManaged: Windows Update changes this by itself (rig 2026-09-19 after a clean reboot) - recorded, not graded
        '\Microsoft\Windows\UpdateOrchestrator\Report policies' = @{ Enabled = $true }
        '\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker' = @{ Enabled = $true }
        '\Microsoft\Windows\UpdateOrchestrator\UUS Failover Task' = @{ Enabled = $true }
        '\Microsoft\Windows\UpdateOrchestrator\UIEOrchestrator' = @{ Enabled = $true }
        '\Microsoft\Windows\UpdateOrchestrator\StartOobeAppsScanAfterUpdate' = @{ Enabled = $true }
        '\Microsoft\Windows\UpdateOrchestrator\StartOobeAppsScan_LicenseAccepted' = @{ Enabled = $true }
        '\Microsoft\Windows\Defrag\ScheduledDefrag' = @{ Enabled = $true }
        '\Microsoft\Windows\DiskCleanup\SilentCleanup' = @{ Enabled = $true }
        '\Microsoft\Windows\DiskFootprint\Diagnostics' = @{ Enabled = $true }
        '\Microsoft\Windows\DiskFootprint\StorageSense' = @{ Enabled = $true }
        '\Microsoft\Windows\Chkdsk\ProactiveScan' = @{ Enabled = $true }
        '\Microsoft\Windows\Maintenance\WinSAT' = @{ Enabled = $true }
        '\Microsoft\Windows\Servicing\StartComponentCleanup' = @{ Enabled = $true }
        '\Microsoft\Windows\Registry\RegIdleBackup' = @{ Enabled = $true }
        '\Microsoft\Windows\StateRepository\MaintenanceTasks' = @{ Enabled = $true }
        '\Microsoft\Windows\WindowsUpdate\Scheduled Start'                                    = @{ Enabled = $true }
        '\Microsoft\Windows\Application Experience\MareBackup'                                = @{ Enabled = $true }
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser Exp'     = @{ Enabled = $true }
        '\Microsoft\Windows\Application Experience\PcaPatchDbTask'                            = @{ Enabled = $true }
        '\Microsoft\Windows\Application Experience\SdbinstMergeDbTask'                        = @{ Enabled = $true }
        '\Microsoft\Windows\Application Experience\StartupAppTask'                            = @{ Enabled = $true }
        '\Microsoft\Windows\WaaSMedic\PerformRemediation'                                     = @{ Enabled = $true }
        '\Microsoft\Windows\Flighting\FeatureConfig\ReconcileFeatures'                        = @{ Enabled = $true }
        '\Microsoft\Windows\Flighting\FeatureConfig\UsageDataReceiver'                        = @{ Enabled = $true }
        '\Microsoft\Windows\Flighting\OneSettings\RefreshCache'                                = @{ Enabled = $true }
        '\Microsoft\Windows\Hotpatch\Monitoring'                                              = @{ Enabled = $true }
        '\Microsoft\Windows\Sysmain\WsSwapAssessmentTask'                                     = @{ Enabled = $true }
        '\Microsoft\Windows\DeviceDirectoryClient\RegisterUserDevice'                         = @{ Enabled = $true }
        '\Microsoft\Windows\DeviceDirectoryClient\RegisterDevicePeriodic24'                   = @{ Enabled = $true }
        '\Microsoft\Windows\UpdateOrchestrator\Start Oobe Expedite Work'                      = @{ Enabled = $true }
        '\Microsoft\Windows\Diagnosis\Scheduled'                                              = @{ Enabled = $true }
        '\Microsoft\Windows\Feedback\Siuf\DmClient'                                           = @{ Enabled = $true }
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'                  = @{ Enabled = $true }
        '\Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan'                 = @{ Enabled = $true }
        '\Microsoft\Windows\UpdateOrchestrator\Schedule Work'                                 = @{ Enabled = $true }
        '\Microsoft\Windows\InstallService\ScanForUpdates'                                    = @{ Enabled = $true }
        '\Microsoft\Windows\InstallService\ScanForUpdatesAsUser'                              = @{ Enabled = $true }
        '\Microsoft\Windows\UpdateOrchestrator\Schedule Scan'                                 = @{ Enabled = $true }
        '\Microsoft\Windows\UpdateOrchestrator\Schedule Scan Static Task'                     = @{ Enabled = $true }
        '\Microsoft\Windows\PushToInstall\LoginCheck'                                         = @{ Enabled = $true }
        '\Microsoft\Windows\PushToInstall\Registration'                                       = @{ Enabled = $true }
        '\Microsoft\Windows\LanguageComponentsInstaller\ReconcileLanguageResources'           = @{ Enabled = $false; WindowsManaged = $true }   # off in 0857 tasks-state.csv, on after the 2026-09-19 reboot - # WindowsManaged: Windows Update changes this by itself (rig 2026-09-19 after a clean reboot) - recorded, not graded
        '\MicrosoftEdgeUpdateTaskMachineCore'                                                 = @{ Enabled = $true }
        '\MicrosoftEdgeUpdateTaskMachineUA'                                                   = @{ Enabled = $true }

        # --- Group D, added with the v4.1 quiet-list items (flag 5: the ENABLED state) ---
        '\Microsoft\Windows\DeviceDirectoryClient\RegisterDeviceProtectionStateChanged' = @{ Enabled = $true }
        '\Microsoft\Windows\Windows Error Reporting\QueueReporting' = @{ Enabled = $true }
        '\Microsoft\Windows\WindowsAI\Settings\InitialConfiguration' = @{ Enabled = $true }
        '\Microsoft\Windows\Flighting\FeatureConfig\GovernedFeatureUsageProcessing' = @{ Enabled = $true }
        '\Microsoft\Windows\Flighting\FeatureConfig\ReconcileConfigs' = @{ Enabled = $true }
        '\Microsoft\Windows\Flighting\FeatureConfig\SafeguardsReconciliation' = @{ Enabled = $true }
        '\Microsoft\Windows\Flighting\FeatureConfig\UsageDataFlushing' = @{ Enabled = $true }
        '\Microsoft\Windows\Flighting\FeatureConfig\UsageDataReporting' = @{ Enabled = $true }
        '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload' = @{ Enabled = $true }
        '\Microsoft\Windows\DeviceDirectoryClient\HandleCommand' = @{ Enabled = $true }
        '\Microsoft\Windows\DeviceDirectoryClient\HandleWnsCommand' = @{ Enabled = $true }
        '\Microsoft\Windows\DeviceDirectoryClient\LocateCommandUserSession' = @{ Enabled = $true }
        '\Microsoft\Windows\DeviceDirectoryClient\RegisterDeviceAccountChange' = @{ Enabled = $true }
        '\Microsoft\Windows\DeviceDirectoryClient\RegisterDeviceLocationRightsChange' = @{ Enabled = $true }
        '\Microsoft\Windows\DeviceDirectoryClient\RegisterDevicePolicyChange' = @{ Enabled = $true }
        '\Microsoft\Windows\DeviceDirectoryClient\RegisterDeviceWnsFallback' = @{ Enabled = $true }
    }

    # --- iRacing ini read-back (TODO 3b.9) ------------------------------------
    # Which files: IniFile maps File='App'/'Core'/'Renderer' to the file names in
    # IniDir. Renderer = rendererDX11Monitor.ini (Opus review 2026-09-19): the
    # rig holds two renderer files, and the Monitor one is the live file for
    # monitor mode - it changed on 2026-09-16 (the MSAA 4x decision), while
    # rendererDX11.ini was last written 2026-09-09. Values in the live file on
    # 2026-09-19_0838: MSAASamples=4, DesiredFPSLimit=144, MaxCarsToDraw=20
    # (match), NvReflexMode=2 (on+boost). The spec expected 1. Reflex is an S4
    # test variable, so v4.0 records it and does not grade it (see its row).
    # No IniDir here. It is one user's Documents folder, and this file ships to
    # everybody - the export gate found the author's Windows user name in it
    # (2026-09-27, Rick's decision). Build-KnownGood takes IniDir from the active
    # profile, and discovery fills the profile in for a machine that has none of its
    # own, so the value is read on the machine it describes instead of shipped.
    IniFile = @{ App = 'app.ini'; Core = 'core.ini'; Renderer = 'rendererDX11Monitor.ini' }
    Ini = @(
        @{ File = 'Renderer'; Section = 'Graphics Options'; Key = 'MaxCarsToDraw';    Expected = '20' }
        @{ File = 'Core';     Section = 'Task';             Key = 'max_num_default_worker_threads'; Expected = '6' }
    )


    # --- Preferred values (v4.1) ---------------------------------------------
    # Rick picks the value; the code grades against the pick. Confirmed
    # 2026-09-20: Reflex 2 (on+boost), MSAA 4, FPS cap 144. To change one, edit
    # Preferred below. Never edit the Engine to change a preference. Allowed for
    # NvReflexMode and MSAASamples comes from the ini comments in fixture
    # 2026-09-19_0838. The DesiredFPSLimit set is the common refresh rates,
    # confirmed by Rick 2026-09-20 rather than read from a file.
    Preference = @(
        @{ Key = 'NvReflexMode'; File = 'Renderer'; Section = 'Graphics Options'; IniKey = 'NvReflexMode'
           Allowed = @('0', '1', '2')
           Preferred = '2'
           Reason = "Rick's pick, 2026-09-19: on+boost, matching the live rendererDX11Monitor.ini reading." }

        @{ Key = 'MSAASamples'; File = 'Renderer'; Section = 'Graphics Options'; IniKey = 'MSAASamples'
           Allowed = @('2', '4', '8')
           Preferred = '4'
           Reason = "Rick's monitor/GPU choice, confirmed 2026-09-16 (rendererDX11Monitor.ini)." }

        @{ Key = 'DesiredFPSLimit'; File = 'Renderer'; Section = 'Graphics Options'; IniKey = 'DesiredFPSLimit'
           Allowed = @('60', '120', '144', '165', '240')
           Preferred = '144'
           Reason = '144 Hz monitor refresh rate (spec G-7: FPS cap default comes from the monitor refresh rate).' }
    )

    FreeSpace = @{ MinGB = 30 }
    GpuPreference = @{ Exe = 'C:\Program Files (x86)\iRacing\iRacingSim64DX11.exe'; Expected = 'GpuPreference=2;' }   # confirmed: gpu-prefs.txt
    Backblaze = @{ ServiceName = 'bzserv'; WarnIfLastBackupOlderThanHours = 24 }
    Manual = @(
        @{ Name = 'G-Sync fullscreen+windowed'; Source = 'NVIDIA Control Panel' }
    )
}
