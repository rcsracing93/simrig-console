# rules/windows.psd1 - SimRig Console v4.2
# Schema: simrig.rule/1 (CONTRACT.md, "SimRig Console v4.2 - contract additions").
#
# Unit U2.2 (Phase 2, wave 2). One rule per row family in the v4.0/v4.1
# windows-area preflight rows: known-good Registry entries, power plan,
# timer resolution, free space, script integrity, pending reboot, overlays
# and Defender, plus the Manual entries. Order follows the bands fixed in
# CONTRACT.md so Get-RuleCheck reproduces G1 byte for byte (A-GAP-09).
#
# Name and Source on every rule equal the text the current Get-PreflightCheck
# rows carry, byte for byte - read from SimRig.Engine.ps1, not invented.
#
# GPU steering, GPU preference and MSI are rules/gpu.psd1 (a different unit).
# Services, tasks, ini rows and preferred values are other units' files.
#
# Dual-CCD power-plan Fail (flag 6 of OPUS-BUILD-BRIEF-v4.2-2026-09-19.md):
# left OUT of this file. v4.0 has no core-parking reading and no dual-CCD
# fixture to test against, so a Target/Evidence here would be invented. See
# the U2.2 report for this judgement call; Phase 3 (public gap rules) owns
# the dual-CCD guard rows.

@{
    Schema = 'simrig.rule/1'
    Area   = 'windows'
    Rules  = @(

        # --- Order 20-29: known-good Registry entries, known-good.psd1 order ---

        @{
            Id        = 'W-MPO'
            PublicDetail = 'Multiplane overlay changes how Windows composites the screen. On this class of hardware it has been measured as a stutter source with the sim in full screen.'
            Order     = 20
            Name      = 'MPO'
            Kind      = 'Registry'
            Source    = 'registry'
            Target    = @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'; Value = 'OverlayTestMode' }
            Expected  = 5
            Severity  = 'Fail'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'Multiplane overlay causes hitching on this driver branch'
            Evidence  = 'mpo.txt 0x5, known-good-2026-09-19_0857 capture'
        }

        @{
            Id        = 'W-HAGS'
            PublicDetail = 'Hardware-accelerated GPU scheduling moves queue management onto the card. It helps on some driver versions and hurts on others, so the value is checked rather than assumed.'
            Order     = 21
            Name      = 'HAGS'
            Kind      = 'Registry'
            Source    = 'registry'
            Target    = @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Value = 'HwSchMode' }
            Expected  = 1
            Severity  = 'Fail'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'Hardware-accelerated GPU scheduling adds frame-time variance on this driver; kept off (HwSchMode=1)'
            Evidence  = 'hwschmode.txt 0x1 (off), known-good-2026-09-19_0857 capture'
        }

        @{
            Id        = 'W-AUTOHDR'
            PublicDetail = 'Auto HDR adds a processing pass on every frame. Recorded because its cost depends on the display and the driver.'
            Order     = 22
            Name      = 'Auto HDR'
            Kind      = 'Registry'
            Source    = 'registry'
            Target    = @{ Path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'; Value = 'DirectXUserGlobalSettings' }
            Expected  = $null
            Severity  = 'Info'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'Tracked for iRacing steering (spec 3b.2); no known-good capture exists yet, so it is recorded, not graded'
            Evidence  = 'known-good.psd1 Registry entry, Note: record only - no known-good capture; TODO 3b.2'
        }

        @{
            Id        = 'W-GAMEBAR-AUTOMODE'
            PublicDetail = 'The Game Bar can attach itself to a game automatically and start capturing. That capture is a frame-time cost the user did not ask for.'
            Order     = 23
            Name      = 'Game Bar AllowAutoGameMode'
            Kind      = 'Registry'
            Source    = 'registry'
            Target    = @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Value = 'AllowAutoGameMode' }
            Expected  = $null
            Severity  = 'Info'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'The quiet list sets this to 0 for the session; the pre-quiet value has no known-good capture (TODO 3b.5), so it is recorded, not graded'
            Evidence  = 'known-good.psd1 Registry entry, Note: TODO 3b.5'
        }

        @{
            Id        = 'W-GAMEMODE-AUTOMODE'
            PublicDetail = 'Game Mode changes how Windows schedules work while a game is in the foreground. Its effect varies by CPU, so the value is checked and reported rather than forced.'
            Order     = 24
            Name      = 'Game Mode AutoGameModeEnabled'
            Kind      = 'Registry'
            Source    = 'registry'
            Target    = @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Value = 'AutoGameModeEnabled' }
            Expected  = $null
            Severity  = 'Info'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'The quiet list sets this to 0 for the session; the pre-quiet value has no known-good capture (TODO 3b.5), so it is recorded, not graded'
            Evidence  = 'known-good.psd1 Registry entry, Note: TODO 3b.5'
        }

        @{
            Id        = 'W-USB-SS'
            PublicDetail = 'Selective suspend lets Windows power down a USB device that looks idle. On a wheel or pedals that can mean a brief input drop.'
            Order     = 25
            Name      = 'USB Selective Suspend'
            Kind      = 'Registry'
            Source    = 'registry'
            Target    = @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\USB'; Value = 'DisableSelectiveSuspend' }
            Expected  = $null
            Severity  = 'Info'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'The quiet list sets this to 1 for the session; the pre-quiet value has no known-good capture (TODO 3b.5), so it is recorded, not graded'
            Evidence  = 'known-good.psd1 Registry entry, Note: TODO 3b.5'
        }

        @{
            Id        = 'W-TIMER-GLOBAL'
            PublicDetail = 'A global timer resolution change affects every program on the machine, not just the game. Recorded so a reader knows whether something set it.'
            Order     = 26
            Name      = 'Global Timer Resolution'
            Kind      = 'Registry'
            Source    = 'registry'
            Target    = @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'; Value = 'GlobalTimerResolutionRequests' }
            Expected  = $null
            Severity  = 'Info'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'v3.9 pre_iracing_launch.bat reports this read-only and does not require it, so it stays Info, not a Pass/Fail gate'
            Evidence  = 'known-good.psd1 Registry entry, Severity=Info; v3.9 pre_iracing_launch.bat'
        }

        # --- Order 30: power plan ------------------------------------------------

        @{
            Id        = 'W-POWERPLAN'
            PublicDetail = 'The power plan decides how aggressively cores are parked and clocked. Some plans park cores the game needs; a plan that parks none can be wrong on a two-die CPU.'
            Order     = 30
            Name      = 'Power plan'
            Kind      = 'PowerScheme'
            Source    = 'powercfg /getactivescheme'
            ValueKey  = 'PowerScheme'
            Severity  = 'Fail'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = "AMD Ryzen Balanced avoids the core-parking stalls seen with High Performance and Ultimate on this rig"
            Evidence  = 'powerplan.txt, known-good-2026-09-19_0857 capture'
        }

        # --- Order 40: timer resolution -------------------------------------------

        @{
            Id        = 'W-TIMER-RES'
            PublicDetail = 'The timer resolution the game asks Windows for while it runs. Reported because the sim requests its own and the value tells you whether it took.'
            Order     = 40
            Name      = 'Timer resolution'
            Kind      = 'TimerResolution'
            Source    = 'NtQueryTimerResolution'
            ValueKey  = 'TimerResolution'
            Severity  = 'Fail'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'Before the race nothing requests 0.5 ms; iRacing requests its own resolution once it runs, so a pre-race reading is recorded, not graded (Grade=$false)'
            Evidence  = 'known-good.psd1 TimerResolution.Grade=$false'
        }

        # --- Order 80: free space, install drive then documents drive ------------

        @{
            Id        = 'W-FREESPACE'
            PublicDetail = 'Free space on the drive holding the session data. A capture that runs out of room part way through is worse than no capture, because it looks complete.'
            Order     = 80
            Name      = 'Free space'
            Kind      = 'FreeSpace'
            Source    = 'Get-Volume'
            ValueKey  = 'FreeSpace'
            Severity  = 'Fail'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'Low free space on the install or documents drive risks a failed capture or log write mid-session; the engine emits one row per drive (install, then documents) from this rule'
            Evidence  = 'known-good.psd1 FreeSpace.MinGB=30'
        }

        # --- Order 90, 95, 96, 97: graded from facts alone, no profile data ------

        @{
            Id        = 'W-SCRIPT-INTEGRITY'
            PublicDetail = 'Each of the app own files is checked against a recorded hash. A mismatch means a file was edited or a copy is incomplete, and nothing it reports afterwards can be trusted.'
            Order     = 90
            Name      = 'Script integrity'
            Kind      = 'ScriptIntegrity'
            Source    = 'file hash'
            Severity  = 'Fail'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'The check needs no data: it compares the file hash read at session start against VERSIONS.md, one row per file'
            Evidence  = 'Get-PreflightCheck script integrity block, SimRig.Engine.ps1'
        }

        @{
            Id        = 'W-PENDING-REBOOT'
            PublicDetail = 'Windows is waiting for a restart to finish an update. Until it does, some settings change back on their own and a session can quietly measure the wrong thing.'
            Order     = 95
            Name      = 'Pending reboot'
            Kind      = 'PendingReboot'
            Source    = 'registry'
            Severity  = 'Warn'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'The check needs no data: a pending reboot is read from the registry at run time and always graded'
            Evidence  = 'Get-PreflightCheck pending reboot block, SimRig.Engine.ps1'
        }

        @{
            Id        = 'W-OVERLAY'
            PublicDetail = 'Programs that draw over the game - chat, capture, hardware monitors. Each one adds work to every frame, and several together are a common cause of uneven frame times.'
            Order     = 96
            Name      = 'Overlays running'
            Kind      = 'Overlay'
            Source    = 'process list'
            Severity  = 'Info'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'The check needs no data: the running overlay list is read from the process list at run time and recorded, not graded'
            Evidence  = 'Get-PreflightCheck overlays block, SimRig.Engine.ps1'
        }

        @{
            Id        = 'W-DEFENDER'
            PublicDetail = 'Real-time virus scanning inspects file reads while the game loads and streams. Whether it is on during a session is reported, because it has been measured as a stutter source on this class of machine.'
            Order     = 97
            Name      = 'Defender real-time monitoring'
            Kind      = 'Defender'
            Source    = 'Get-MpComputerStatus'
            Severity  = 'Fail'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'The check needs no data: Defender real-time status is read live at run time and always graded'
            Evidence  = 'Get-PreflightCheck Defender block, SimRig.Engine.ps1'
        }

        # --- Order 99: manual entries, known-good.psd1 Manual array order --------

        @{
            Id        = 'W-MANUAL-GSYNC'
            PublicDetail = 'A display setting only a person can confirm, because Windows does not expose it to a script. It is shown so it is not silently skipped.'
            Order     = 99
            Name      = 'G-Sync fullscreen+windowed'
            Kind      = 'Manual'
            Source    = 'NVIDIA Control Panel'
            Severity  = 'Manual'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'G-Sync fullscreen and windowed mode is set in the NVIDIA Control Panel and cannot be read back by the engine'
            Evidence  = 'known-good.psd1 Manual entry'
        }
    )
}
