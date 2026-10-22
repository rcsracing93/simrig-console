# discover/Discover.Cpu.ps1 - SimRig Console v4.2, unit U3.1 (CPU topology read)
#
# READ ONLY. This file reads Windows and grades nothing. It calls
# GetLogicalProcessorInformationEx through P/Invoke for the L3 cache groups and
# the SMT flag, and CIM (Win32_Processor) for the processor name, the vendor and
# the core counts. It returns the raw reading. Every decision - X3D, the CCD
# count, which CCD carries the V-Cache, which carries the frequency, the target
# CPU - belongs to engine/Engine.Topology.ps1, which is pure and is tested on
# Linux with no Windows at all.
#
# Rule for this file, the same rule SimRig.Probe.ps1 holds: no Set-*, Stop-*,
# Start-*, Enable-*, Disable-*, New-Item, Remove-*, sc.exe, reg.exe add/delete.
# Nothing here writes. Every reading that cannot be taken is $null and is named
# in Unavailable; nothing throws for a missing reading.
#
# The byte layout of the returned buffer is parsed by the pure engine function
# ConvertFrom-LogicalProcessorInformation, so the offset arithmetic - the part
# most likely to be wrong - is under test on Linux against synthetic buffers.

Set-StrictMode -Version 3.0

function Get-CpuInformationBuffer {
    <#
        .SYNOPSIS
        The raw GetLogicalProcessorInformationEx(RelationAll) buffer as bytes,
        or $null when it cannot be read.
        .DESCRIPTION
        Two calls: the first fails with ERROR_INSUFFICIENT_BUFFER (122) and
        sets the length, the second fills the buffer. RelationAll is 0xffff, so
        one call returns both the cache records and the per-core records.
        Read-only: the function allocates its own unmanaged buffer, frees it,
        and touches no system state.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()
    if (-not $IsWindows) {
        Write-Verbose 'GetLogicalProcessorInformationEx is Windows only; no buffer read.'
        return $null
    }
    try {
        if (-not ('SimRigV4.CpuInfo' -as [type])) {
            Add-Type -Namespace SimRigV4 -Name CpuInfo -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetLogicalProcessorInformationEx(int RelationshipType, System.IntPtr Buffer, ref int ReturnedLength);
'@
        }
        $length = 0
        $null = [SimRigV4.CpuInfo]::GetLogicalProcessorInformationEx(0xffff, [System.IntPtr]::Zero, [ref]$length)
        if ($length -le 0) {
            Write-Verbose 'GetLogicalProcessorInformationEx reported a zero buffer length.'
            return $null
        }
        $buffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($length)
        try {
            if (-not [SimRigV4.CpuInfo]::GetLogicalProcessorInformationEx(0xffff, $buffer, [ref]$length)) {
                Write-Verbose ('GetLogicalProcessorInformationEx failed with Win32 error {0}.' -f [System.Runtime.InteropServices.Marshal]::GetLastWin32Error())
                return $null
            }
            $byte = [byte[]]::new($length)
            [System.Runtime.InteropServices.Marshal]::Copy($buffer, $byte, 0, $length)
            return $byte
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
        }
    }
    catch {
        Write-Verbose ('CPU topology buffer not readable: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Get-CpuProcessorCimRecord {
    <#
        .SYNOPSIS
        Win32_Processor Name, Manufacturer and counts, or $null.
        .DESCRIPTION
        The first processor is used and the socket count is reported beside it,
        so a multi-socket machine is visible rather than silently reduced.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()
    if (-not $IsWindows) {
        Write-Verbose 'Win32_Processor is Windows only; no CIM read.'
        return $null
    }
    try {
        $all = @(Get-CimInstance -ClassName Win32_Processor -OperationTimeoutSec 60 -ErrorAction Stop)
        if ($all.Count -eq 0) { return $null }
        $first = $all[0]
        return [pscustomobject]@{
            Name            = [string]$first.Name
            Manufacturer    = [string]$first.Manufacturer
            CoreCount       = $first.NumberOfCores
            LogicalCount    = $first.NumberOfLogicalProcessors
            ProcessorCount  = $all.Count
        }
    }
    catch {
        Write-Verbose ('Win32_Processor not readable: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Get-CpuTopologyReading {
    <#
        .SYNOPSIS
        The raw CPU topology reading for this PC, shape simrig.cpu-reading/1.
        Reads only; grades nothing.
        .DESCRIPTION
        Returns a hashtable, never $null, with every key present:

            Schema          'simrig.cpu-reading/1'
            ProcessorName   Win32_Processor Name, or $null
            Vendor          Win32_Processor Manufacturer, or $null
            CoreCountCim    Win32_Processor NumberOfCores, or $null
            LogicalCountCim Win32_Processor NumberOfLogicalProcessors, or $null
            ProcessorCount  how many Win32_Processor instances answered
            L3Group         level-3 cache records (Level, SizeBytes, CacheType,
                            Affinity of Group/Mask/LogicalCpu, LogicalCpu),
                            ordered by their lowest logical CPU
            CoreGroup       per-core records (SmtFlagSet, Affinity, LogicalCpu)
            BufferByteCount the buffer length, for the support bundle
            Unavailable     the names of the readings that could not be taken
            Note            one line per reading that was not taken

        Pass the result to Get-CpuTopology (engine) to get the Cpu block of
        simrig.machine-profile/1 and a Confidence per field.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # Keeps the raw buffer, packaged by Format-CpuBufferCapture, on the
        # reading as BufferCapture. Off by default: the reading travels inside
        # every report and the bytes are only wanted once, in the support
        # bundle, to turn the F-RIG fixture from synthetic into a capture.
        [switch] $IncludeBuffer,
        # The reader owns the clock; the engine formatter stays pure.
        [datetime] $CaptureTakenAt = (Get-Date)
    )

    $unavailable = [System.Collections.Generic.List[string]]::new()
    $note = [System.Collections.Generic.List[string]]::new()

    $cim = Get-CpuProcessorCimRecord
    if ($null -eq $cim) {
        $unavailable.Add('ProcessorName')
        $unavailable.Add('Vendor')
        $unavailable.Add('CoreCountCim')
        $unavailable.Add('LogicalCountCim')
        $note.Add('Win32_Processor did not answer, so the processor name, the vendor and the core counts were not read.')
    }
    elseif ($cim.ProcessorCount -gt 1) {
        $note.Add(('{0} processor sockets answered. The first one names the reading; v4.2 grades a single-socket PC.' -f $cim.ProcessorCount))
    }

    $l3 = @()
    $coreGroup = @()
    $byteCount = $null
    $byte = Get-CpuInformationBuffer
    if ($null -eq $byte) {
        $unavailable.Add('L3Group')
        $unavailable.Add('CoreGroup')
        $note.Add('GetLogicalProcessorInformationEx did not answer, so the L3 cache groups and the SMT flag were not read.')
    }
    elseif (-not (Get-Command -Name 'ConvertFrom-LogicalProcessorInformation' -ErrorAction SilentlyContinue)) {
        $unavailable.Add('L3Group')
        $unavailable.Add('CoreGroup')
        $note.Add('The engine parser ConvertFrom-LogicalProcessorInformation was not loaded, so the buffer was not parsed. Dot-source SimRig.Engine.ps1 before this file.')
    }
    else {
        $byteCount = $byte.Length
        $record = ConvertFrom-LogicalProcessorInformation -Byte $byte
        $l3 = Select-CpuL3Group -Record $record
        $coreGroup = @($record | Where-Object { $_.Kind -eq 'Core' })
        if ($l3.Count -eq 0) {
            $unavailable.Add('L3Group')
            $note.Add('The buffer carried no level-3 cache record.')
        }
        if ($coreGroup.Count -eq 0) {
            $unavailable.Add('CoreGroup')
            $note.Add('The buffer carried no per-core record, so SMT falls back to the CIM counts.')
        }
    }

    $bufferCapture = $null
    if ($IncludeBuffer) {
        if (Get-Command -Name 'Format-CpuBufferCapture' -ErrorAction SilentlyContinue) {
            $bufferCapture = Format-CpuBufferCapture -TakenAt $CaptureTakenAt -Byte @(if ($null -ne $byte) { $byte } else { @() }) -Reading @{
                ProcessorName   = $(if ($null -ne $cim) { $cim.Name } else { $null })
                Vendor          = $(if ($null -ne $cim) { $cim.Manufacturer } else { $null })
                CoreCountCim    = $(if ($null -ne $cim) { $cim.CoreCount } else { $null })
                LogicalCountCim = $(if ($null -ne $cim) { $cim.LogicalCount } else { $null })
            }
        }
        else {
            $note.Add('The buffer capture was asked for but Format-CpuBufferCapture was not loaded, so no bytes were kept. Dot-source engine/Engine.Topology.ps1 before this file.')
        }
    }

    return @{
        Schema          = 'simrig.cpu-reading/1'
        BufferCapture   = $bufferCapture
        ProcessorName   = $(if ($null -ne $cim) { $cim.Name } else { $null })
        Vendor          = $(if ($null -ne $cim) { $cim.Manufacturer } else { $null })
        CoreCountCim    = $(if ($null -ne $cim) { $cim.CoreCount } else { $null })
        LogicalCountCim = $(if ($null -ne $cim) { $cim.LogicalCount } else { $null })
        ProcessorCount  = $(if ($null -ne $cim) { $cim.ProcessorCount } else { $null })
        L3Group         = $l3
        CoreGroup       = $coreGroup
        BufferByteCount = $byteCount
        Unavailable     = @($unavailable.ToArray())
        Note            = @($note.ToArray())
    }
}
