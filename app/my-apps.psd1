# my-apps.psd1 - the user's own list of programs to quiet, plus a picker catalog.
#
# Written by unit U3.8 (wave 3b, 2026-09-26), applied by the lead. Items ships
# empty on purpose: the app never quiets a program the user did not choose.
# Suggestions is an inert catalog the picker reads; nothing in it is acted on
# until the user moves it into Items.

@{
    Schema      = 'simrig.my-apps/1'

    # The user's own picks. Empty by default for every profile (G-4).
    Items       = @()

    # Suggestions for the settings picker. None of these are quieted unless
    # the user (or the picker UI, on their say-so) copies an entry into
    # Items above.
    Suggestions = @(
        @{
            Kind           = 'Service'
            Name           = 'bzserv'
            Label          = 'Backblaze backup'
            Detect         = @{ Kind = 'Service'; Name = 'bzserv' }
            DefaultChecked = $false
            Reason         = 'Background backup I/O during a race is a stutter source on a PC that has Backblaze installed; most users do not (G-3)'
            Evidence       = 'V4.2-SPEC-2026-09-19.md G-3; known-good-2026-09-19_0857 services-all.csv (bzserv, Backblaze) - Rick-only capture, service name confirmed real'
        }
        @{
            Kind           = 'Process'
            Name           = 'OneDrive'
            Label          = 'OneDrive'
            Detect         = @{ Kind = 'Process'; Name = 'OneDrive' }
            DefaultChecked = $false
            Reason         = 'v3.9 closed this for Rick; a stranger may need OneDrive running (sync, shared files) so it is a suggestion, not a default (G-4)'
            Evidence       = 'V4.2-SPEC-2026-09-19.md G-4; quiet-list.psd1 v3.9 Process item (moved out of the unconditional list by this unit, see quiet-list-appliesto.psd1.fragment)'
        }
        @{
            Kind           = 'Process'
            Name           = 'chrome'
            Label          = 'Google Chrome'
            Detect         = @{ Kind = 'Process'; Name = 'chrome' }
            DefaultChecked = $false
            Reason         = 'Chrome may be running an overlay, a SimHub dashboard, Garage61 or the race stream - closing it for everyone would break those setups (G-4)'
            Evidence       = 'V4.2-SPEC-2026-09-19.md G-4; quiet-list.psd1 v3.9 Process item'
        }
        @{
            Kind           = 'Process'
            Name           = 'Claude'
            Label          = 'Claude desktop'
            Detect         = @{ Kind = 'Process'; Name = 'Claude' }
            DefaultChecked = $false
            Reason         = 'Rick-specific tool, no reason to close it for a stranger by default (G-4)'
            Evidence       = 'V4.2-SPEC-2026-09-19.md G-4; quiet-list.psd1 v3.9 Process item'
        }
        @{
            Kind           = 'Service'
            Name           = 'Spooler'
            Label          = 'Print Spooler'
            Detect         = @{ Kind = 'Service'; Name = 'Spooler' }
            DefaultChecked = $false
            Reason         = 'Low value for most users; stopping print services is a Rick-specific habit from v3.9, not a public default (G-5)'
            Evidence       = 'V4.2-SPEC-2026-09-19.md G-5; known-good-2026-09-19_0857 services-all.csv (Spooler, Print Spooler)'
        }
        @{
            Kind           = 'Service'
            Name           = 'XblAuthManager'
            Label          = 'Xbox Live Auth Manager'
            Detect         = @{ Kind = 'Service'; Name = 'XblAuthManager' }
            DefaultChecked = $false
            Reason         = 'Only relevant to Xbox app sign-in; low value for most users (G-5)'
            Evidence       = 'V4.2-SPEC-2026-09-19.md G-5; 2026-09-19_0838 services-all.csv line 280 (XblAuthManager, Xbox Live Auth Manager)'
        }
    )
}
