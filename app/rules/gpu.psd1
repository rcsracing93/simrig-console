# rules/gpu.psd1 - SimRig Console v4.2
# Schema: simrig.rule/1 (CONTRACT.md, v4.2 additions). Area 'gpu'.
#
# The GPU area of the preflight: interrupt steering, the steering instance
# count and GPU preference. Order 10, 15 and 85 come from the contract's
# Order bands table and must not move.
#
# Every value a rule needs (the steering targets, the GPU preference exe and
# string) lives in the chosen profile's Values, read here by ValueKey. This
# file names the check; the profile holds the number (contract: "Why rules
# and profiles exist").
#
# MSI mode (build brief section 3, flag 7 area) is not in this file. v4.0 has
# no MSI check and no fixture for one - nothing here to move. Adding one now
# would be a rule with no known-good capture behind it, the same bar the
# quiet list holds (contract: "A rule with no evidence does not go in").
#
# G1 proof: Get-RuleCheck on this file, the reference rig's profile and the
# F-RIG fixture must reproduce Get-PreflightCheck's GPU rows byte for byte
# (contract test A-GAP-09).

@{
    Schema = 'simrig.rule/1'
    Area   = 'gpu'
    Rules  = @(
        # --- Order 10: GPU interrupt steering -----------------------------
        # Get-PreflightCheck emits one row per present NVIDIA PCI function
        # from $Fact.GpuAffinity, graded against this rule's resolved value
        # (Convert-RuleToKnownGood Kind 'GpuSteering' -> kg.GpuSteering).
        # ValueKey 'GpuSteering' reads the whole block - VendorId,
        # ExpectedInstanceCount, Default, Overrides, Provisional,
        # ProvisionalReason - because the engine's steering grading (spec
        # section 5) already reads all of those from one object.
        @{
            Id        = 'GPU-STEER'
            PublicDetail = 'The graphics card can be told which CPU core handles its interrupts. Left on core 0, that work competes with Windows itself and shows up as an occasional long frame. This row checks whether a core has been chosen.'
            Order     = 10
            Name      = 'GPU interrupt steering'
            Kind      = 'GpuSteering'
            Source    = 'registry, PCI VEN_10DE'
            ValueKey  = 'GpuSteering'
            Severity  = 'Fail'
            AppliesTo = @{ Profile = 'any'; Ccd = 1; Gpu = 'any'; Windows = 'any' }
            Reason    = 'Interrupt steering keeps NVIDIA GPU ISR/DPC handling off CPU0 to avoid stutter (spec section 5, flag 6).'
            Evidence  = 'gpu-affinity-policy.txt, known-good-2026-09-19_0857 (the repaired, restored rig); self-test read on the rig 2026-09-19.'
        }

        # --- Order 15: GPU interrupt steering count -----------------------
        # The count row is built from the same $steer block above, inside
        # the same Get-PreflightCheck GPU-steering section - it is not a
        # separate known-good field. Convert-RuleToKnownGood's 'GpuSteeringCount'
        # case does nothing on purpose (contract: "the count row comes with
        # the steering block"). This rule exists only to give that row an Id,
        # an Order and its own Evidence in the traceability table; it carries
        # no ValueKey and its Expected is never read.
        @{
            Id        = 'GPU-STEER-COUNT'
            PublicDetail = 'A graphics card presents more than one device to Windows, and interrupt steering has to be set on each of them. This row checks that none was missed - a driver update often adds a new one.'
            Order     = 15
            Name      = 'GPU interrupt steering count'
            Kind      = 'GpuSteeringCount'
            Source    = 'registry, PCI VEN_10DE'
            Severity  = 'Fail'
            AppliesTo = @{ Profile = 'any'; Ccd = 1; Gpu = 'any'; Windows = 'any' }
            Reason    = 'Confirms every present NVIDIA PCI function carries a steering policy - a missing or extra entry means the fix did not reach every function.'
            Evidence  = 'gpu-affinity-policy.txt, known-good-2026-09-19_0857; the probe counts present devices only, not stale registry keys (known-good.psd1 GpuSteering comment).'
        }

        # --- Order 85: GPU preference ---------------------------------------
        @{
            Id        = 'GPU-PREF'
            PublicDetail = 'Windows keeps a per-program graphics preference. If the game is set to anything but high performance, it can end up on the wrong adapter on a machine with two.'
            Order     = 85
            Name      = 'GPU preference'
            Kind      = 'GpuPreference'
            Source    = 'registry'
            ValueKey  = 'GpuPreference'
            Severity  = 'Fail'
            AppliesTo = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Reason    = 'iRacing must run on the discrete NVIDIA GPU, not an integrated GPU, for consistent frame delivery.'
            Evidence  = 'gpu-prefs.txt, known-good-2026-09-19_0857 (the repaired, restored rig).'
        }
    )
}
