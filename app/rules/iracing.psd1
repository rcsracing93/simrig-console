# rules/iracing.psd1 - SimRig Console v4.2
# Schema: simrig.rule/1 (CONTRACT.md, v4.2 additions). Area: iracing.
# Written by unit U2.4, Phase 2. Owner: lead (CONTRACT.md file-owner table).
#
# Two Kinds:
#   - Ini (Order 70): one rule per known-good.psd1 Ini array entry, same
#     order. Target names the file/section/key; Expected is that entry's
#     literal value, carried on the rule (Convert-RuleToKnownGood falls back
#     to the rule's own Expected when no ValueKey is set - CONTRACT.md,
#     Convert-RuleToKnownGood doc comment). Kind Ini never resolves through
#     the profile: the ini locations (IniDir/IniFile) are profile facts, not
#     rule values.
#   - Preference (Order 75): one rule, ValueKey = 'Preference'. The engine
#     resolves the whole Preference array from Profile.Values.Preference and
#     Get-PreferenceCheck (SimRig.Engine.ps1) emits one row per entry.
#
# Both Kinds feed the SAME preflight row Name prefix, "iRacing ini: <File>/
# <Key or IniKey>" (Get-PreflightCheck for Ini, Get-PreferenceCheck for
# Preference - SimRig.Engine.ps1). An Ini rule and a Preference rule that
# named the same File/Key would collide in the gap table: the second row
# would silently duplicate the first, both grading the same ini value
# independently and possibly disagreeing. known-good.psd1 keeps the two sets
# disjoint on purpose (Ini: MaxCarsToDraw, max_num_default_worker_threads;
# Preference: NvReflexMode, MSAASamples, DesiredFPSLimit) and this file keeps
# that split. See the report for the safety judgement.

@{
    Schema = 'simrig.rule/1'
    Area   = 'iracing'
    Rules  = @(
        # --- Order 70: iRacing ini rows, known-good.psd1 Ini array order ---
        @{
            Id        = 'IRC-INI-MAXCARSTODRAW'
            PublicDetail = 'The number of cars the sim is allowed to draw. Set higher than the field you actually race, it costs frame time for cars nobody can see.'
            Order     = 70
            Name      = 'iRacing ini: Renderer/MaxCarsToDraw'
            Kind      = 'Ini'
            Source    = 'ini read-back'
            Target    = @{ File = 'Renderer'; Section = 'Graphics Options'; Key = 'MaxCarsToDraw' }
            Expected  = '20'
            Severity  = 'Fail'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = 'MaxCarsToDraw 20 is the tuned baseline every reference session ran on. TC-20 (2026-07-04) tested lowering it to 15 and found no stall-rate change, so 20 stays the known-good value, not a performance lever.'
            Evidence  = 'known-good.psd1 (2026-09-19_0838 ini read-back, 20, "match"); TROUBLESHOOTING-HISTORY.md TC-20 and TS-33 config checks confirm 20 as the byte-verified baseline.'
        }
        @{
            Id        = 'IRC-INI-WORKERTHREADS'
            PublicDetail = 'How many worker threads the sim starts. A value that does not match the CPU leaves cores idle or oversubscribed, and both show up as uneven frame times.'
            Order     = 70
            Name      = 'iRacing ini: Core/max_num_default_worker_threads'
            Kind      = 'Ini'
            Source    = 'ini read-back'
            Target    = @{ File = 'Core'; Section = 'Task'; Key = 'max_num_default_worker_threads' }
            Expected  = '6'
            Severity  = 'Fail'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = "Enki worker threads=6 avoids oversubscribing the 8-core/16-thread X3D CCD at the end-of-tick join (CPU0 is reserved for render). iRacing's stock default of 10 reproduced the stall on the same build (TS-23 discriminator)."
            Evidence  = 'known-good.psd1 (2026-09-19_0838 ini read-back, 6); TROUBLESHOOTING-HISTORY.md TS-22/TS-23/TS-24-26 (n>=3 confirm) and the 2026-07-28 correction (rate lever, not full elimination).'
        }

        # --- Order 75: preferred values, resolved from the profile ---------
        @{
            Id        = 'IRC-PREF-VALUES'
            PublicDetail = 'Graphics settings that are recorded rather than graded, because the right value depends on the rig and the driver. They appear so a reader can compare two machines.'
            Order     = 75
            Name      = 'iRacing preferred values'
            Kind      = 'Preference'
            Source    = 'ini read-back'
            Target    = $null
            ValueKey  = 'Preference'
            Expected  = $null
            Severity  = 'Fail'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional = $false
            ProvisionalReason = $null
            Detail    = $null
            Reason    = "One rule for every preferred ini value in Profile.Values.Preference (NvReflexMode, MSAASamples, DesiredFPSLimit). Get-PreferenceCheck emits one row per entry, so the row text and the per-value Reason stay with the value, not with this rule. Rick confirmed the three values 2026-09-20: Reflex 2, MSAA 4, FPS cap 144."
            Evidence  = "the reference rig profile Values.Preference; Rick's confirmation 2026-09-20; V4.2-SPEC-2026-09-19.md G-7 (all three become Preference rules; FPS cap default comes from the monitor refresh rate)."
        }
    )
}
