# rules/public-manual.psd1 - public rules whose verdict only a person can give.
#
# Written by unit U3.8 (wave 3b, 2026-09-26), applied by the lead. A Manual row
# never grades Pass; it asks the user to confirm by eye and records what they say.

@{
    Schema = 'simrig.rule/1'
    Area   = 'public-manual'
    Rules  = @(
        @{
            Id        = 'PUB-MANUAL-GAMEBAR'
            PublicDetail = 'A setting only a person can confirm, because Windows does not report it in a way a script can read. It is shown so it is not silently skipped.'
            Order     = 99
            Name      = 'iRacing marked as a game in Game Bar'
            Kind      = 'Manual'
            Source    = 'Xbox Game Bar (Win+G) > Widget Menu > confirm iRacing.exe is tracked as a game'
            Severity  = 'Manual'
            AppliesTo = @{ Profile = 'any'; Ccd = 2; Gpu = 'any'; Windows = 'any' }
            Reason    = "AMD's dual-CCD X3D install guide requires iRacing be recognized as a game by Game Bar for the CPPC2/scheduler-driven CCD choice to work; nothing on the PC exposes this flag for the engine to read back, so it stays a manual confirmation on dual-CCD rigs only."
            Evidence  = 'V4.2-SPEC-2026-09-19.md line 424 (O-1 CLOSED note); TEST-SPEC-v4.2-2026-09-19.md R-G6/A-GAP-06.'
        }
    )
}
