# profiles/default.psd1 - the public profile, shipped to strangers.
#
# The Services, Tasks and Preference values are the public quiet list, written by
# unit U3.8 (wave 3b, 2026-09-26) and applied by the lead. Services covers the
# update-stack items that are safe on any Windows 11 PC; each carries AlsoAccept
# including its own quiet-list target, so a service already at that state grades
# Pass instead of a false Fail. Wireless, Bluetooth, print spooler, Xbox auth and
# the backup client are deliberately absent - they are machine-specific and the
# public gap rules exclude them. Preference values are recorded, never graded:
# there is no right answer to pick for someone else's rig.
#
# This file ships. It carries no machine name, no user name, no path and no
# vendor product name, and the export gate in tests/Rules.Tests.ps1 enforces
# that with a case-insensitive match. Cite a requirement id in a comment here,
# never a literal example - a comment that quotes a forbidden string trips the
# gate exactly as a value would, which is how this file failed once already.

@{
    Schema  = 'simrig.profile/1'
    Id      = 'default'
    Name    = 'Any supported PC'
    # No Match: this profile is the fallback, chosen when nothing else matches.
    Match   = @{}
    RuleSet = @('gpu', 'windows', 'services-tasks', 'iracing')

    # Discovery fills both from the iRacing install it finds (Phase 3, U3.3).
    IniDir  = $null
    # Where Push copies a session bundle. No default for a public build: it is one
    # person's mapped drive, and a shipped Z: path means nothing on anybody else's PC.
    # Push says so and copies nothing until a folder is set (2026-09-27).
    NasRoot = $null
    IniFile = @{ App = 'app.ini'; Core = 'core.ini'; Renderer = 'rendererDX11.ini' }

    Notes   = 'Phase 2 skeleton. Discovery fills the machine-derived values in Phase 3.'

    Values  = @{
        # Flag 15: never on by default. Switching off a stranger's virus scanner is
        # not a choice this app makes for them, however well it works on one rig.
        DefenderOptIn = $false

        # Flag 7: the display function only. The card's audio and USB functions are
        # recorded in the report and left alone.
        GpuSteeringScope = 'Display'


        # GPU interrupt steering. The target CPU is the first logical CPU of the
        # frequency CCD on a dual-CCD chip (O-2) and is graded Warn until a beta
        # capture proves it, so the mask is machine-derived and not a constant.
        GpuSteering = @{
            VendorId              = 'VEN_10DE'
            ExpectedInstanceCount = $null
            Default               = @{ DevicePolicy = 4; AssignmentSetOverride = $null; Cpu = $null }
            Overrides             = @()
            Provisional           = $true
            ProvisionalReason     = 'the steering target comes from this PC topology and is graded Warn until a dual-CCD beta capture proves it (O-2)'
        }

        # G-8: two plans are both fine, so both pass. A stranger on the Windows
        # default and a stranger on the AMD plan are each in good shape, and
        # failing one of them because it is not the plan this project's own rig
        # uses is a false alarm - which is how people learn to ignore preflight.
        #
        # High Performance is on both the Note and the NoParking list, and those
        # mean different things on purpose. On a single-CCD PC it is only worth a
        # word: nothing is wrong, it just parks no cores. On a dual-CCD PC the
        # same plan grades Fail, because the AMD driver needs core parking to keep
        # the game on the V-Cache die (flag 6).
        #
        # GUIDs: Windows Balanced (381b4222-...) and High Performance (8c5e7fda-...)
        # are Microsoft's published constants. The source of 45bcc044-... is not in
        # the repo, and it is not the plan of the rig capture: that one is
        # c584c850-... (known-good.psd1, powerplan.txt of 2026-09-19). It stays on the
        # accept list, because an accept entry writes nothing (the Cowork answer to
        # the tuning design, answer 2); the send-logs bundle of beta.1 gives its name
        # (OPEN-ITEMS.md). Corrected in push 2 of the unit tune, step 10.
        PowerScheme     = @{
            Accept    = @('381b4222-f694-41f0-9685-ff5bb260df2e', '45bcc044-d885-43e2-8605-ee0ec6e96b59')
            Note      = @('8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
            NoParking = @('8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
        }

        # Recorded, not graded: nothing asks Windows for 0.5 ms before the race.
        TimerResolution = @{ MaxMs = 0.5; ToleranceMs = 0.01; Grade = $false }

        FreeSpace       = @{ MinGB = 30 }

        # Discovery finds the iRacing executable, so the exe path is not written
        # here. The expected value is the same on every machine.
        GpuPreference   = @{ Exe = $null; Expected = 'GpuPreference=2;' }

        # No backup-service check on a public PC. The key is left out rather
        # than set to $null, because the export gate greps the public tree for
        # the name of the product Rick's rig uses (flag 11), and a key name is
        # a string in the file like any other.

        Startup         = @{ WindowMaxSeconds = 3; PreflightMaxSeconds = 20 }

        # The public quiet list and its expected ENABLED states come from the
        # public gap rules in Phase 3 (unit U3.8).
        Services        = @{
            # Update-stack services safe to include for any Windows 11 PC
            # (v4.0 Group A, no G-id in V4.2-SPEC 6a flags them as risky).
            # StartType is the known-good ENABLED state (flag 5), sourced
            # from known-good-2026-09-19_0857/sc-qc.txt via known-good.psd1
            # (Rick's rig, same real Windows update-stack services on every
            # Windows 11 install - not rig-specific values).
            # AlsoAccept adds each service's OWN quiet-list Disable target
            # (unit U3.8, G-6): a service a user already had disabled before
            # ever running SimRig now grades Pass ("Windows sets this by
            # itself - accepted" text is inherited from the engine's
            # existing AlsoAccept path; it is not literally true here, but
            # it is the only data hook Get-PreflightCheck's Service branch
            # has for "do not fail a pre-existing state" - see the U3.8
            # report, Ask for the lead, for an Info-verdict alternative).
            'WaaSMedicSvc'   = @{ StartType = 'Manual';           AlsoAccept = @('Disabled') }
            'InstallService' = @{ StartType = 'Manual';           AlsoAccept = @('Disabled') }
            'edgeupdate'     = @{ StartType = 'AutomaticDelayed'; AlsoAccept = @('Disabled') }
            'edgeupdatem'    = @{ StartType = 'Manual';           AlsoAccept = @('Disabled') }
            'PcaSvc'         = @{ StartType = 'AutomaticDelayed'; AlsoAccept = @('Disabled') }
            'bits'           = @{ StartType = 'Manual';           AlsoAccept = @('AutomaticDelayed', 'Disabled'); SelfSwitches = @('Manual', 'AutomaticDelayed') }
            'DoSvc'          = @{ StartType = 'AutomaticDelayed'; AlsoAccept = @('Disabled') }
            'wuauserv'       = @{ StartType = 'Manual';           AlsoAccept = @('Automatic', 'Disabled') }
            'UsoSvc'         = @{ StartType = 'Automatic';        AlsoAccept = @('Disabled') }
            'WSearch'        = @{ StartType = 'AutomaticDelayed'; AlsoAccept = @('Disabled') }

            # Left OUT of the public default and gated to the named-rig profile
            # in quiet-list.psd1 instead (see quiet-list-appliesto.psd1.fragment):
            # WlanSvc (G-1), bthserv/BTAGService/BthAvctpSvc (G-2), Spooler and
            # XblAuthManager (G-5), and the G-3 backup-service item (also offered via my-apps.psd1).
        }
        Tasks           = @{
            # Update-stack/maintenance tasks safe for any Windows 11 PC - the
            # same real task names and Enabled=$true known-good state as
            # known-good.psd1's Tasks map (known-good-2026-09-19_0857/
            # tasks-state.csv), no G-id in V4.2-SPEC 6a excludes any of them.
            # WindowsManaged entries carry the same flag as known-good.psd1:
            # Windows changes these itself, so a mismatch is Info, not Fail
            # (the engine's own G-6-shaped behaviour for tasks - it predates
            # this unit and needed no change).
            '\Microsoft\Windows\InstallService\SmartRetry'                                  = @{ Enabled = $true }
            '\Microsoft\Windows\InstallService\WakeUpAndContinueUpdates'                     = @{ Enabled = $true; WindowsManaged = $true }
            '\Microsoft\Windows\InstallService\WakeUpAndScanForUpdates'                      = @{ Enabled = $true; WindowsManaged = $true }
            '\Microsoft\Windows\InstallService\ScanForUpdates'                               = @{ Enabled = $true }
            '\Microsoft\Windows\InstallService\ScanForUpdatesAsUser'                         = @{ Enabled = $true }
            '\Microsoft\Windows\UpdateOrchestrator\Report policies'                          = @{ Enabled = $true }
            '\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker'                             = @{ Enabled = $true }
            '\Microsoft\Windows\UpdateOrchestrator\UUS Failover Task'                        = @{ Enabled = $true }
            '\Microsoft\Windows\UpdateOrchestrator\UIEOrchestrator'                          = @{ Enabled = $true }
            '\Microsoft\Windows\UpdateOrchestrator\StartOobeAppsScanAfterUpdate'              = @{ Enabled = $true }
            '\Microsoft\Windows\UpdateOrchestrator\StartOobeAppsScan_LicenseAccepted'         = @{ Enabled = $true }
            '\Microsoft\Windows\UpdateOrchestrator\Start Oobe Expedite Work'                  = @{ Enabled = $true }
            '\Microsoft\Windows\UpdateOrchestrator\Schedule Work'                             = @{ Enabled = $true }
            '\Microsoft\Windows\UpdateOrchestrator\Schedule Scan'                             = @{ Enabled = $true }
            '\Microsoft\Windows\UpdateOrchestrator\Schedule Scan Static Task'                 = @{ Enabled = $true }
            '\Microsoft\Windows\Defrag\ScheduledDefrag'                                       = @{ Enabled = $true }
            '\Microsoft\Windows\DiskCleanup\SilentCleanup'                                    = @{ Enabled = $true }
            '\Microsoft\Windows\DiskFootprint\Diagnostics'                                    = @{ Enabled = $true }
            '\Microsoft\Windows\DiskFootprint\StorageSense'                                   = @{ Enabled = $true }
            '\Microsoft\Windows\Chkdsk\ProactiveScan'                                         = @{ Enabled = $true }
            '\Microsoft\Windows\Maintenance\WinSAT'                                           = @{ Enabled = $true }
            '\Microsoft\Windows\Servicing\StartComponentCleanup'                              = @{ Enabled = $true }
            '\Microsoft\Windows\Registry\RegIdleBackup'                                       = @{ Enabled = $true }
            '\Microsoft\Windows\StateRepository\MaintenanceTasks'                             = @{ Enabled = $true }
            '\Microsoft\Windows\WindowsUpdate\Scheduled Start'                                = @{ Enabled = $true }
            '\Microsoft\Windows\Application Experience\MareBackup'                            = @{ Enabled = $true }
            '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser Exp' = @{ Enabled = $true }
            '\Microsoft\Windows\Application Experience\PcaPatchDbTask'                        = @{ Enabled = $true }
            '\Microsoft\Windows\Application Experience\SdbinstMergeDbTask'                    = @{ Enabled = $true }
            '\Microsoft\Windows\Application Experience\StartupAppTask'                        = @{ Enabled = $true }
            '\Microsoft\Windows\WaaSMedic\PerformRemediation'                                 = @{ Enabled = $true }
            '\Microsoft\Windows\Flighting\FeatureConfig\ReconcileFeatures'                   = @{ Enabled = $true }
            '\Microsoft\Windows\Flighting\FeatureConfig\UsageDataReceiver'                   = @{ Enabled = $true }
            '\Microsoft\Windows\Flighting\OneSettings\RefreshCache'                          = @{ Enabled = $true }
            '\Microsoft\Windows\Hotpatch\Monitoring'                                          = @{ Enabled = $true }
            '\Microsoft\Windows\Sysmain\WsSwapAssessmentTask'                                 = @{ Enabled = $true }
            '\Microsoft\Windows\DeviceDirectoryClient\RegisterUserDevice'                     = @{ Enabled = $true }
            '\Microsoft\Windows\DeviceDirectoryClient\RegisterDevicePeriodic24'               = @{ Enabled = $true }
            '\Microsoft\Windows\Diagnosis\Scheduled'                                          = @{ Enabled = $true }
            '\Microsoft\Windows\Feedback\Siuf\DmClient'                                      = @{ Enabled = $true }
            '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'              = @{ Enabled = $true }
            '\Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan'             = @{ Enabled = $true }
            '\Microsoft\Windows\PushToInstall\LoginCheck'                                     = @{ Enabled = $true }
            '\Microsoft\Windows\PushToInstall\Registration'                                   = @{ Enabled = $true }
            '\Microsoft\Windows\LanguageComponentsInstaller\ReconcileLanguageResources'       = @{ Enabled = $false; WindowsManaged = $true }
            '\MicrosoftEdgeUpdateTaskMachineCore'                                                = @{ Enabled = $true }
            '\MicrosoftEdgeUpdateTaskMachineUA'                                                  = @{ Enabled = $true }
        }

        # No preferred value is chosen for a stranger. Every preference row
        # records its value until the user picks one in settings.
        Preference      = @(
            # G-7 (V4.2-SPEC 6a): these were Rick's fixed expectations in
            # v4.0/v4.1. For the public profile Preferred is $null on every
            # entry - Get-PreferenceCheck grades a $null Preferred as Info
            # ("recorded - no preferred value chosen"), so a stranger sees
            # the value recorded and is never failed for not matching Rick's
            # pick. The Allowed lists and Reason text are still useful data
            # for a settings picker built later.
            @{ Key = 'NvReflexMode'; File = 'Renderer'; Section = 'Graphics Options'; IniKey = 'NvReflexMode'
               Allowed = @('0', '1', '2')
               Preferred = $null
               Reason = 'No pick for a stranger (G-7); recorded only until the user chooses one in settings.' }

            @{ Key = 'MSAASamples'; File = 'Renderer'; Section = 'Graphics Options'; IniKey = 'MSAASamples'
               Allowed = @('2', '4', '8')
               Preferred = $null
               Reason = 'No pick for a stranger (G-7); recorded only until the user chooses one in settings.' }

            @{ Key = 'DesiredFPSLimit'; File = 'Renderer'; Section = 'Graphics Options'; IniKey = 'DesiredFPSLimit'
               Allowed = @('60', '120', '144', '165', '240')
               Preferred = $null
               Reason = 'G-7: the default should come from the monitor refresh rate once discovery (Display.Refresh) feeds a profile default - not built by this unit. Recorded only for now.' }
        )
    }
}
