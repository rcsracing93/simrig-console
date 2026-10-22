# engine/Engine.Topology.ps1 - SimRig Console v4.2, unit U3.1 (CPU topology)
#
# PURE. No clock, no filesystem, no registry, no processes, no $env:. Every
# input is a parameter. This file runs and is tested on Linux with no Windows
# at all: discover/Discover.Cpu.ps1 does the P/Invoke and hands the raw bytes
# and the CIM strings here, and this file decides what they mean.
#
# Written so it stays valid when concatenated into SimRig.Engine.ps1: function
# definitions only, no top-level code, strict-mode clean (Set-StrictMode
# -Version 3.0 is set once in the final file). Get-KnownGoodField (Engine) is
# used for every key that may be absent.
#
# The rules this file implements, and where each comes from:
#   - X3D = an L3 of 96 MB or more on one CCD, never the model name
#     (FABLE-REVIEW question 4, R-D2).
#   - The larger L3 is the V-Cache CCD, the smaller is the frequency CCD,
#     equal sizes mean there is no frequency CCD (flag 6).
#   - The IRQ target is the lowest set bit of the chosen L3 group's affinity
#     mask, never arithmetic on a core count (O-2, and it is the only form
#     that survives SMT off).
#   - Equal L3 on both CCDs: the steering row is Manual with no target
#     (flag 6).
#   - Dual-CCD FrequencyCcd and TargetCpu carry Confidence 'Warn' until a beta
#     dual-CCD capture proves them (O-2, Rick closed).
#   - Non-X3D runs read-only. The fact is reported; nothing refuses.

function Get-CpuX3DThresholdByte {
    <#
        .SYNOPSIS
        The L3 size at or above which one CCD counts as a V-Cache die: 96 MB.
        .DESCRIPTION
        96 MiB = 100663296 bytes. Every Ryzen 7000/9000 X3D part reports 96 MB
        on its V-Cache CCD (32 MB base plus 64 MB stacked) and 32 MB on a
        frequency CCD. The number is the threshold from the discovery method
        table (FABLE-REVIEW question 4, R-D2), not a model lookup.
    #>
    [CmdletBinding()]
    [OutputType([int64])]
    param()
    return [int64]100663296
}

function Get-CpuMaskBit {
    <#
        .SYNOPSIS
        The logical CPU numbers a KAFFINITY mask names, lowest first.
        .DESCRIPTION
        A logical CPU number is GroupNumber * 64 + the bit index inside the
        group mask, the convention Windows uses for a processor-group system.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [uint64] $Mask,
        [int] $GroupNumber = 0
    )
    $bit = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt 64; $i++) {
        if ((($Mask -shr $i) -band [uint64]1) -eq [uint64]1) {
            $bit.Add([int](($GroupNumber * 64) + $i))
        }
    }
    return ,@($bit.ToArray())
}

function Get-CpuGroupAffinity {
    <#
        .SYNOPSIS
        Reads Count GROUP_AFFINITY structures out of a byte buffer.
        .DESCRIPTION
        GROUP_AFFINITY on x64 is 16 bytes: KAFFINITY Mask (8), WORD Group (2),
        WORD Reserved[3] (6). Limit is the exclusive end of the record being
        parsed; a structure that would cross it is dropped rather than read
        past the record.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [byte[]] $Byte,
        [Parameter(Mandatory)] [int] $Offset,
        [Parameter(Mandatory)] [int] $Count,
        [Parameter(Mandatory)] [int] $Limit
    )
    $affinity = [System.Collections.Generic.List[object]]::new()
    for ($n = 0; $n -lt $Count; $n++) {
        $at = $Offset + ($n * 16)
        if (($at + 16) -gt $Limit -or ($at + 16) -gt $Byte.Length) { break }
        $mask = [System.BitConverter]::ToUInt64($Byte, $at)
        $group = [int][System.BitConverter]::ToUInt16($Byte, $at + 8)
        $cpu = Get-CpuMaskBit -Mask $mask -GroupNumber $group
        $affinity.Add([pscustomobject]@{
                Group      = $group
                Mask       = $mask
                LogicalCpu = $cpu
            })
    }
    return ,@($affinity.ToArray())
}

function ConvertFrom-LogicalProcessorInformation {
    <#
        .SYNOPSIS
        Parses the GetLogicalProcessorInformationEx buffer into cache and core
        records. Pure: bytes in, records out.
        .DESCRIPTION
        SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX, x64 layout, offsets from the
        start of one record:
            +0  DWORD Relationship   (0 = ProcessorCore, 2 = Cache)
            +4  DWORD Size           (the record length, walk by this)
            +8  the union
        CACHE_RELATIONSHIP at +8:
            +8  BYTE  Level          +9  BYTE Associativity
            +10 WORD  LineSize       +12 DWORD CacheSize
            +16 DWORD Type           +20 WORD GroupCount (union with Reserved[20])
            +40 GROUP_AFFINITY GroupMask[GroupCount]
        PROCESSOR_RELATIONSHIP at +8:
            +8  BYTE  Flags (bit 0 = LTP_PC_SMT)   +9 BYTE EfficiencyClass
            +10 BYTE  Reserved[20]  +30 WORD GroupCount
            +32 GROUP_AFFINITY GroupMask[GroupCount]
        GroupCount reads 0 on a build that writes the Reserved bytes instead,
        so it is clamped to 1. A short or truncated buffer stops the walk; the
        records read so far are returned and nothing throws.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Byte
    )
    $record = [System.Collections.Generic.List[object]]::new()
    $pos = 0
    while (($pos + 8) -le $Byte.Length) {
        $relationship = [int][System.BitConverter]::ToUInt32($Byte, $pos)
        $size = [int][System.BitConverter]::ToUInt32($Byte, $pos + 4)
        if ($size -lt 8) { break }
        if (($pos + $size) -gt $Byte.Length) { break }
        $end = $pos + $size
        if ($relationship -eq 2 -and $size -ge 56) {
            $groupCount = [int][System.BitConverter]::ToUInt16($Byte, $pos + 20)
            if ($groupCount -lt 1) { $groupCount = 1 }
            $affinity = Get-CpuGroupAffinity -Byte $Byte -Offset ($pos + 40) -Count $groupCount -Limit $end
            $cpu = [System.Collections.Generic.List[int]]::new()
            foreach ($a in $affinity) { foreach ($c in $a.LogicalCpu) { $cpu.Add([int]$c) } }
            $record.Add([pscustomobject]@{
                    Kind       = 'Cache'
                    Level      = [int]$Byte[$pos + 8]
                    SizeBytes  = [int64][System.BitConverter]::ToUInt32($Byte, $pos + 12)
                    CacheType  = [int][System.BitConverter]::ToUInt32($Byte, $pos + 16)
                    Affinity   = $affinity
                    LogicalCpu = @($cpu.ToArray() | Sort-Object)
                    SmtFlagSet = $null
                })
        }
        elseif ($relationship -eq 0 -and $size -ge 48) {
            $groupCount = [int][System.BitConverter]::ToUInt16($Byte, $pos + 30)
            if ($groupCount -lt 1) { $groupCount = 1 }
            $affinity = Get-CpuGroupAffinity -Byte $Byte -Offset ($pos + 32) -Count $groupCount -Limit $end
            $cpu = [System.Collections.Generic.List[int]]::new()
            foreach ($a in $affinity) { foreach ($c in $a.LogicalCpu) { $cpu.Add([int]$c) } }
            $record.Add([pscustomobject]@{
                    Kind       = 'Core'
                    Level      = $null
                    SizeBytes  = $null
                    CacheType  = $null
                    Affinity   = $affinity
                    LogicalCpu = @($cpu.ToArray() | Sort-Object)
                    SmtFlagSet = (([int]$Byte[$pos + 8] -band 1) -eq 1)
                })
        }
        $pos = $end
    }
    return ,@($record.ToArray())
}

function Select-CpuL3Group {
    <#
        .SYNOPSIS
        The level-3 cache records out of ConvertFrom-LogicalProcessorInformation
        output, ordered by their lowest logical CPU.
        .DESCRIPTION
        The order is the CCD index the rest of this file uses: index 0 is the
        CCD that holds the lowest logical CPU. Nothing here assumes the
        V-Cache die is CCD 0 - Get-CpuVCacheCcd decides that by size.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Record
    )
    $l3 = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $Record) {
        $kind = Get-KnownGoodField -Entry $r -Name 'Kind'
        $level = Get-KnownGoodField -Entry $r -Name 'Level'
        if ($kind -eq 'Cache' -and $level -eq 3) { $l3.Add($r) }
    }
    $sorted = @($l3.ToArray() | Sort-Object -Property @{ Expression = {
                $cpu = @(Get-KnownGoodField -Entry $_ -Name 'LogicalCpu')
                if ($cpu.Count -gt 0 -and $null -ne $cpu[0]) { [int]$cpu[0] } else { [int]::MaxValue }
            }
        })
    return ,@($sorted)
}

function Test-CpuX3D {
    <#
        .SYNOPSIS
        True when one L3 group is 96 MB or larger (R-D2). Never reads a name.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $L3Group
    )
    $threshold = Get-CpuX3DThresholdByte
    foreach ($g in $L3Group) {
        $size = Get-KnownGoodField -Entry $g -Name 'SizeBytes'
        if ($null -ne $size -and [int64]$size -ge $threshold) { return $true }
    }
    return $false
}

function Get-CpuVCacheCcd {
    <#
        .SYNOPSIS
        The index of the CCD with the largest L3, or $null when the sizes are
        equal or unreadable. The larger L3 is the V-Cache die.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $L3Group
    )
    return (Get-CpuL3Extreme -L3Group $L3Group -Largest $true)
}

function Get-CpuFrequencyCcd {
    <#
        .SYNOPSIS
        The index of the CCD with the smallest L3, or $null when there is no
        frequency CCD: one L3 group, or equal L3 on every group (flag 6).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $L3Group
    )
    return (Get-CpuL3Extreme -L3Group $L3Group -Largest $false)
}

function Get-CpuL3Extreme {
    <#
        .SYNOPSIS
        The index of the largest or the smallest L3 group. $null when there is
        fewer than one comparison to make, when a size is missing, or when
        every size is equal.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $L3Group,
        [Parameter(Mandatory)] [bool] $Largest
    )
    if ($L3Group.Count -lt 2) { return $null }
    $size = [System.Collections.Generic.List[int64]]::new()
    foreach ($g in $L3Group) {
        $s = Get-KnownGoodField -Entry $g -Name 'SizeBytes'
        if ($null -eq $s) { return $null }
        $size.Add([int64]$s)
    }
    $distinct = @($size.ToArray() | Sort-Object -Unique)
    if ($distinct.Count -lt 2) { return $null }
    $want = if ($Largest) { $distinct[-1] } else { $distinct[0] }
    for ($i = 0; $i -lt $size.Count; $i++) {
        if ($size[$i] -eq $want) { return $i }
    }
    return $null
}

function Get-CpuTargetFromL3Group {
    <#
        .SYNOPSIS
        The IRQ target for one L3 group: the lowest set bit of its affinity
        mask, with the within-group mask that names it.
        .DESCRIPTION
        This is the only way the target is produced. It is read from the mask,
        so it is right with SMT off, where the same core carries a different
        logical CPU number (O-2 says "computed from the L3 groups, never from a
        constant"; the guide value of CPU 16 or CPU 12 is an SMT-on artefact
        and is never assumed).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $L3Group
    )
    $empty = [pscustomobject]@{ TargetCpu = $null; TargetGroup = $null; TargetMask = $null }
    if ($null -eq $L3Group) { return $empty }
    $affinity = @(Get-KnownGoodField -Entry $L3Group -Name 'Affinity')
    if ($affinity.Count -eq 0 -or $null -eq $affinity[0]) { return $empty }
    $ordered = @($affinity | Sort-Object -Property @{ Expression = { [int](Get-KnownGoodField -Entry $_ -Name 'Group') } })
    foreach ($a in $ordered) {
        $cpu = @(Get-KnownGoodField -Entry $a -Name 'LogicalCpu')
        if ($cpu.Count -eq 0 -or $null -eq $cpu[0]) { continue }
        $lowest = [int](@($cpu | Sort-Object)[0])
        $group = [int](Get-KnownGoodField -Entry $a -Name 'Group')
        return [pscustomobject]@{
            TargetCpu   = $lowest
            TargetGroup = $group
            TargetMask  = ([uint64]1 -shl ($lowest - ($group * 64)))
        }
    }
    return $empty
}

function Test-CpuLogicalInL3Group {
    <#
        .SYNOPSIS
        True when a logical CPU number is inside an L3 group's affinity.
        Used to check a profile-supplied single-CCD target against the mask.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $L3Group,
        [Parameter(Mandatory)] [int] $LogicalCpu
    )
    if ($null -eq $L3Group) { return $false }
    $cpu = @(Get-KnownGoodField -Entry $L3Group -Name 'LogicalCpu')
    foreach ($c in $cpu) {
        if ($null -ne $c -and [int]$c -eq $LogicalCpu) { return $true }
    }
    return $false
}

function Get-CpuVendorName {
    <#
        .SYNOPSIS
        The CIM manufacturer string as the one vendor vocabulary: AMD, Intel,
        the raw string when it is neither, $null when it was not read.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()] [string] $Manufacturer)
    if ([string]::IsNullOrWhiteSpace($Manufacturer)) { return $null }
    switch ($Manufacturer.Trim()) {
        'AuthenticAMD' { return 'AMD' }
        'GenuineIntel' { return 'Intel' }
        default { return $Manufacturer.Trim() }
    }
}

function Get-CpuSmtState {
    <#
        .SYNOPSIS
        SMT on or off, from the per-core affinity masks. $null when neither the
        core records nor the CIM counts were read.
        .DESCRIPTION
        A core record whose mask holds more than one logical CPU means SMT is
        on for that core. The LTP_PC_SMT flag byte is read too and is returned
        as FlagSaysOn; when the two disagree the mask wins and the
        disagreement is reported, because the mask is what an affinity is
        built from. The CIM counts are the last fallback.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $CoreGroup,
        [AllowNull()] $CoreCountCim,
        [AllowNull()] $LogicalCountCim
    )
    $maskSaysOn = $null
    $flagSaysOn = $null
    if ($CoreGroup.Count -gt 0 -and $null -ne $CoreGroup[0]) {
        $maskSaysOn = $false
        $flagSaysOn = $false
        foreach ($c in $CoreGroup) {
            $cpu = @(Get-KnownGoodField -Entry $c -Name 'LogicalCpu')
            if ($cpu.Count -gt 1) { $maskSaysOn = $true }
            if ((Get-KnownGoodField -Entry $c -Name 'SmtFlagSet') -eq $true) { $flagSaysOn = $true }
        }
    }
    $source = 'mask'
    $smtOn = $maskSaysOn
    if ($null -eq $smtOn) {
        $source = 'cim-count'
        if ($null -ne $CoreCountCim -and $null -ne $LogicalCountCim -and [int]$CoreCountCim -gt 0) {
            $smtOn = ([int]$LogicalCountCim -gt [int]$CoreCountCim)
        }
        else {
            $source = 'none'
        }
    }
    return [pscustomobject]@{
        SmtOn      = $smtOn
        Source     = $source
        FlagSaysOn = $flagSaysOn
        Disagree   = ($null -ne $maskSaysOn -and $null -ne $flagSaysOn -and $maskSaysOn -ne $flagSaysOn)
    }
}

function Get-CpuTopology {
    <#
        .SYNOPSIS
        Turns the raw CPU reading into the Cpu block of
        simrig.machine-profile/1, with a Confidence per field.
        .DESCRIPTION
        Reading is the simrig.cpu-reading/1 hashtable that
        discover/Discover.Cpu.ps1 returns, or the same shape built from a
        fixture. Nothing here reads the machine.

        ProfileTargetCpu is the single-CCD target the selected profile holds
        (Rick's rig: CPU 7, measured, 0x80). Discovery alone cannot produce a
        single-CCD target: O-2 defines the dual-CCD rule only, and inventing a
        number from a core count is the trap the X3D tooling assessment names
        ("don't copy core numbers out of a dual-CCD guide"). Without the
        parameter a single-CCD TargetCpu stays $null with Confidence
        'Unknown'. With it, the value is checked against the L3 group's mask
        before it is used.

        Confidence vocabulary: Read, Read (derived), Inferred, Warn, Manual,
        Unknown. Warn is the O-2 grade: a dual-CCD FrequencyCcd and TargetCpu
        never grade Pass until a beta dual-CCD capture proves them. A
        single-CCD target is Warn too, because S.1 (Physics Islands re-check)
        is open and no steering rule grades Pass before it closes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [hashtable] $Reading,
        [AllowNull()] $ProfileTargetCpu = $null
    )

    $note = [System.Collections.Generic.List[string]]::new()
    $unavailable = [System.Collections.Generic.List[string]]::new()

    $name = Get-KnownGoodField -Entry $Reading -Name 'ProcessorName'
    if ([string]::IsNullOrWhiteSpace([string]$name)) { $name = $null; $unavailable.Add('Name') }
    $vendor = Get-CpuVendorName -Manufacturer ([string](Get-KnownGoodField -Entry $Reading -Name 'Vendor'))
    if ($null -eq $vendor) { $unavailable.Add('Vendor') }

    $l3 = @(Get-KnownGoodField -Entry $Reading -Name 'L3Group')
    if ($l3.Count -eq 1 -and $null -eq $l3[0]) { $l3 = @() }
    $coreGroup = @(Get-KnownGoodField -Entry $Reading -Name 'CoreGroup')
    if ($coreGroup.Count -eq 1 -and $null -eq $coreGroup[0]) { $coreGroup = @() }

    $l3Count = $l3.Count
    $x3d = Test-CpuX3D -L3Group $l3
    $vcache = Get-CpuVCacheCcd -L3Group $l3
    $freq = Get-CpuFrequencyCcd -L3Group $l3
    $equalL3 = ($l3Count -ge 2 -and $null -eq $freq)

    $size = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $l3) { $size.Add((Get-KnownGoodField -Entry $g -Name 'SizeBytes')) }

    $ccd = $null
    $ccdConfidence = 'Unknown'
    if ($l3Count -gt 0) {
        $ccd = $l3Count
        $ccdConfidence = 'Read (derived)'
        if ($vendor -ne 'AMD') {
            $ccdConfidence = 'Inferred'
            $note.Add('Ccd is the L3 group count. One L3 per CCD holds on AMD Ryzen; on another vendor the count is reported as read and no CCD rule applies.')
        }
    }
    else {
        $unavailable.Add('L3GroupCount')
        $unavailable.Add('Ccd')
        $note.Add('No level-3 cache record was read, so X3D, Ccd, the V-Cache CCD, the frequency CCD and the target CPU are all unknown.')
    }

    $smt = Get-CpuSmtState -CoreGroup $coreGroup -CoreCountCim (Get-KnownGoodField -Entry $Reading -Name 'CoreCountCim') -LogicalCountCim (Get-KnownGoodField -Entry $Reading -Name 'LogicalCountCim')
    $smtConfidence = switch ($smt.Source) {
        'mask' { 'Read (derived)' }
        'cim-count' { 'Inferred' }
        default { 'Unknown' }
    }
    if ($smt.Source -eq 'none') { $unavailable.Add('SmtOn') }
    if ($smt.Disagree) {
        $note.Add('The LTP_PC_SMT flag byte and the per-core affinity masks disagree. The masks decide, because an affinity is built from a mask.')
    }

    # Target CPU. Three cases, and only these three.
    $targetCpu = $null
    $targetGroup = $null
    $targetMask = $null
    $targetSource = 'none'
    $steering = 'Manual'
    $targetConfidence = 'Unknown'
    $targetReason = 'No level-3 cache record was read, so no target can be named.'
    $freqConfidence = 'Unknown'
    $freqReason = 'No level-3 cache record was read.'

    if ($l3Count -ge 2 -and $null -ne $freq) {
        $hit = Get-CpuTargetFromL3Group -L3Group $l3[$freq]
        $targetCpu = $hit.TargetCpu
        $targetGroup = $hit.TargetGroup
        $targetMask = $hit.TargetMask
        $targetSource = 'frequency-ccd'
        $steering = 'Target'
        $targetConfidence = 'Warn'
        $targetReason = 'O-2: the dual-CCD IRQ target is the first logical CPU of the frequency CCD, read from that CCD L3 group affinity mask. Evidence level Community; it grades Warn, never Pass, until a beta dual-CCD capture proves it (no more stalls over 25 ms per 100 s, a worst frame no higher, and lower nvlddmkm highest DPC and ISR times).'
        $freqConfidence = 'Warn'
        $freqReason = 'The smaller L3 is the frequency CCD. The identification is read from the L3 sizes; the Warn is O-2 - the AMD driver parks the frequency CCD during a game, and no beta dual-CCD capture has shown that steering an interrupt to a parked core costs nothing.'
        if ($null -eq $targetCpu) {
            $targetSource = 'none'
            $steering = 'Manual'
            $targetConfidence = 'Manual'
            $targetReason = 'The frequency CCD L3 group carried no readable affinity mask, so the steering row is Manual with no target.'
            $note.Add('The frequency CCD was identified but its affinity mask was empty, so no target was produced.')
        }
    }
    elseif ($equalL3) {
        $steering = 'Manual'
        $targetConfidence = 'Manual'
        $targetReason = 'Flag 6: equal L3 size on both CCDs means there is no frequency CCD, so the steering row is Manual with no target. A CCD is never guessed.'
        $freqConfidence = 'Read (derived)'
        $freqReason = 'Flag 6: the L3 sizes are equal, so there is no frequency CCD. The $null is a read result, not a gap.'
        $note.Add('Equal L3 size on every CCD: no frequency CCD, no target, the steering row is Manual (flag 6).')
    }
    elseif ($l3Count -eq 1) {
        $freqConfidence = 'Read (derived)'
        $freqReason = 'One L3 group means one CCD, so there is no frequency CCD. The $null is a read result, not a gap.'
        if ($null -ne $ProfileTargetCpu) {
            $wanted = [int]$ProfileTargetCpu
            if (Test-CpuLogicalInL3Group -L3Group $l3[0] -LogicalCpu $wanted) {
                $targetCpu = $wanted
                $group = 0
                $affinity = @(Get-KnownGoodField -Entry $l3[0] -Name 'Affinity')
                foreach ($a in $affinity) {
                    $cpu = @(Get-KnownGoodField -Entry $a -Name 'LogicalCpu')
                    foreach ($c in $cpu) { if ($null -ne $c -and [int]$c -eq $wanted) { $group = [int](Get-KnownGoodField -Entry $a -Name 'Group') } }
                }
                $targetGroup = $group
                $targetMask = ([uint64]1 -shl ($wanted - ($group * 64)))
                $targetSource = 'profile'
                $steering = 'Target'
                $targetConfidence = 'Warn'
                $targetReason = 'Single-CCD: the target is the measured value the selected profile holds (Rick rig: CPU 7, mask 0x80), checked against the one L3 group affinity mask before use. It grades Warn, never Pass, while S.1 (the Physics Islands re-check) is open.'
            }
            else {
                $targetSource = 'none'
                $steering = 'Manual'
                $targetConfidence = 'Manual'
                $targetReason = 'The profile single-CCD target is not in this PC L3 group affinity mask, so it is refused and the steering row is Manual.'
                $note.Add(('Profile target CPU {0} is not in the L3 group mask of this PC, so it was refused.' -f $ProfileTargetCpu))
            }
        }
        else {
            $targetSource = 'none'
            $steering = 'Manual'
            $targetConfidence = 'Unknown'
            $targetReason = 'Single-CCD: O-2 defines the dual-CCD rule only, and the single-CCD target is a measured profile value. Topology alone produces no number, and a number is never derived from a core count.'
            $unavailable.Add('TargetCpu')
        }
    }

    $readOnly = $false
    $readOnlyReason = $null
    if ($l3Count -gt 0 -and -not $x3d) {
        $readOnly = $true
        $readOnlyReason = 'Non-X3D CPU: no L3 group of 96 MB or more. Section 2 of the build brief runs this PC read-only. Discovery and grading still run; nothing is refused.'
        $note.Add($readOnlyReason)
    }

    $cpu = [ordered]@{
        Name         = $name
        Vendor       = $vendor
        X3D          = $(if ($l3Count -gt 0) { $x3d } else { $null })
        Ccd          = $ccd
        L3GroupCount = $(if ($l3Count -gt 0) { $l3Count } else { $null })
        FrequencyCcd = $freq
        TargetCpu    = $targetCpu
        SmtOn        = $smt.SmtOn
    }

    $confidence = [ordered]@{
        Name         = $(if ($null -eq $name) { 'Unknown' } else { 'Read' })
        Vendor       = $(if ($null -eq $vendor) { 'Unknown' } else { 'Read' })
        X3D          = $(if ($l3Count -gt 0) { 'Read (derived)' } else { 'Unknown' })
        Ccd          = $ccdConfidence
        L3GroupCount = $(if ($l3Count -gt 0) { 'Read' } else { 'Unknown' })
        FrequencyCcd = $freqConfidence
        TargetCpu    = $targetConfidence
        SmtOn        = $smtConfidence
    }

    $reason = [ordered]@{
        Name         = 'Win32_Processor Name by CIM.'
        Vendor       = 'Win32_Processor Manufacturer by CIM, mapped to AMD or Intel.'
        X3D          = 'An L3 group of 96 MB or more, from GetLogicalProcessorInformationEx(RelationCache). The model name is never read for this (R-D2).'
        Ccd          = 'The count of level-3 cache groups. One L3 per CCD on AMD Ryzen.'
        L3GroupCount = 'The count of level-3 cache records from GetLogicalProcessorInformationEx.'
        FrequencyCcd = $freqReason
        TargetCpu    = $targetReason
        SmtOn        = ('From the per-core affinity masks ({0}): a core mask with more than one logical CPU means SMT is on.' -f $smt.Source)
    }

    return [pscustomobject]@{
        Cpu              = $cpu
        Confidence       = $confidence
        ConfidenceReason = $reason
        VCacheCcd        = $vcache
        SteeringMode     = $steering
        TargetGroup      = $targetGroup
        TargetMask       = $targetMask
        TargetSource     = $targetSource
        EqualL3          = $equalL3
        L3SizeByte       = @($size.ToArray())
        SmtFlagSaysOn    = $smt.FlagSaysOn
        ReadOnly         = $readOnly
        ReadOnlyReason   = $readOnlyReason
        Note             = @($note.ToArray())
        Unavailable      = @($unavailable.ToArray())
    }
}

function Format-CpuBufferCapture {
    <#
        .SYNOPSIS
        Packages a raw GetLogicalProcessorInformationEx buffer for the support
        bundle, shape simrig.cpu-buffer-capture/1.

        .DESCRIPTION
        Every CPU topology number in this project is synthetic. Nothing in the
        repository holds a real GetLogicalProcessorInformationEx capture, so the
        96 MB L3 figure on Rick's rig is AMD's published number rather than a
        reading, and the F-RIG fixture is a synthetic buffer built around three
        real lines of a LatencyMon log. Saving the buffer once turns F-RIG into
        a capture and confirms the L3 size by measurement.

        The buffer holds cache sizes and affinity masks only. It carries no
        name, no path, no serial and no identifier, so it needs no anonymizer
        pass, and the returned document says so in its Note rather than leaving
        the next person to work it out.

        An empty or absent buffer returns a capture that says there was no
        buffer. It never throws: a machine that refuses the read still produces
        a support bundle.

        .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary] Schema TakenAt
        ByteCount Sha256 Base64 ProcessorName Vendor CoreCountCim
        LogicalCountCim Note
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Byte,
        [Parameter(Mandatory)] [hashtable] $Reading,
        # Mandatory, and no default: this file is the pure half of the split and
        # names no clock call. Topology.Tests.ps1 enforces that, and it caught
        # this. The caller reads the clock and passes the time in.
        [Parameter(Mandatory)] [datetime] $TakenAt
    )

    $noPersonal = 'The buffer holds cache sizes and affinity masks. It carries no name, no path, no serial and no identifier, so it needs no anonymizer pass.'

    $bytes = @($Byte)
    if ($bytes.Count -eq 0) {
        return [ordered]@{
            Schema          = 'simrig.cpu-buffer-capture/1'
            TakenAt         = Format-SimRigTime -Time $TakenAt
            ByteCount       = 0
            Sha256          = $null
            Base64          = $null
            ProcessorName   = $Reading['ProcessorName']
            Vendor          = $Reading['Vendor']
            CoreCountCim    = $Reading['CoreCountCim']
            LogicalCountCim = $Reading['LogicalCountCim']
            Note            = ('There was no buffer to capture, so this document records only what CIM answered. ' + $noPersonal)
        }
    }

    $raw = [byte[]]$bytes
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = ($sha.ComputeHash($raw) | ForEach-Object { $_.ToString('x2') }) -join ''
    }
    finally {
        $sha.Dispose()
    }

    return [ordered]@{
        Schema          = 'simrig.cpu-buffer-capture/1'
        TakenAt         = Format-SimRigTime -Time $TakenAt
        ByteCount       = $raw.Length
        Sha256          = $hash
        Base64          = [Convert]::ToBase64String($raw)
        ProcessorName   = $Reading['ProcessorName']
        Vendor          = $Reading['Vendor']
        CoreCountCim    = $Reading['CoreCountCim']
        LogicalCountCim = $Reading['LogicalCountCim']
        Note            = ('Raw GetLogicalProcessorInformationEx(RelationAll) buffer, base64. Decode it, pass it to ConvertFrom-LogicalProcessorInformation, and it parses to the same records the rig read. ' + $noPersonal)
    }
}
