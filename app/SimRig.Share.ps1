<#
    SimRig.Share.ps1 - SimRig Console v4.2, unit U3.6 (flag 8, spec section 8).

    The share flow, and nothing else:
      Get-ShareSalt           a fresh per-report salt (never written to a file)
      Get-ShareDenyList       assembles the denylist from values the caller read
      Get-ShareDenyArgument   the named arguments for it, from a reading
      Get-RigHardwareSummary  the short hardware line that goes in the issue URL
      Build-RigReport         simrig.rig-report/2, every string anonymized
      Test-RigReport          the last gate before anything leaves the PC
      Get-RigIssueUrl         the prefilled GitHub issue form URL
      ConvertTo-RigReportJson the one json text: preview and file are the same
      Export-RigReportFile    writes the report json
      Get-SupportBundlePlan   what goes in the bundle, and under what name
      Export-SupportBundle    reads, anonymizes, stages, zips
      Get-BundleScreenRow     the bundle screen: one row per file, "0 found"

    This file does NOT anonymize anything itself. There is one anonymizer
    (engine/Engine.Anon.ps1) and everything here goes through it. Dot-source
    SimRig.Engine.ps1 and engine/Engine.Anon.ps1 before this file.

    It reads and writes files (the session folder, the stage folder, the zip)
    and it never writes Windows state - SimRig.Actions.ps1 stays the only
    writer. It never touches a source file: the bundle is built from copies.
#>

function Get-ShareSalt {
    <#
        .SYNOPSIS
        A fresh random salt for one report. The engine is pure and cannot make
        one, and the salt must never be stored: it is what makes a placeholder
        one-way.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $ByteCount = 24)

    $bytes = [byte[]]::new($ByteCount)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

function Get-ShareDenyList {
    <#
        .SYNOPSIS
        Assembles the denylist from values the caller has already read. Pure by
        design: the reads belong in SimRig.Probe.ps1, not here (see the U3.6
        fragment under _wip/U3.6 for the probe function this wants).

        .DESCRIPTION
        Every parameter is optional except the salt, because a machine may have
        no domain, no Wi-Fi and no mapped drive. An empty or whitespace value is
        dropped rather than turned into a rule that matches everything.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Salt,
        [string] $UserName,
        [string] $FullName,
        [string] $ComputerName,
        [string] $Domain,
        [string[]] $Sid = @(),
        [string[]] $Email = @(),
        [string[]] $WifiProfile = @(),
        [string[]] $IpAddress = @(),
        [string[]] $MacAddress = @(),
        [string[]] $UncHost = @(),
        [string[]] $UncShare = @(),
        [string[]] $MappedDriveTarget = @(),
        [string[]] $VolumeLabel = @(),
        [string[]] $VolumeSerial = @(),
        [string[]] $DiskSerial = @(),
        [string[]] $MonitorSerial = @(),
        [string[]] $UsbSerial = @(),
        [string[]] $OneDriveOrg = @(),
        [string[]] $CustomerId = @()
    )

    $deny = @{ Salt = $Salt }
    $single = @{
        UserName = $UserName; FullName = $FullName; ComputerName = $ComputerName; Domain = $Domain
    }
    foreach ($key in @($single.Keys | Sort-Object)) {
        $value = [string]$single[$key]
        if (-not [string]::IsNullOrWhiteSpace($value)) { $deny[$key] = $value.Trim() }
    }
    $many = @{
        Sid = $Sid; Email = $Email; WifiProfile = $WifiProfile; IpAddress = $IpAddress
        MacAddress = $MacAddress; UncHost = $UncHost; UncShare = $UncShare
        MappedDriveTarget = $MappedDriveTarget; VolumeLabel = $VolumeLabel
        VolumeSerial = $VolumeSerial; DiskSerial = $DiskSerial; MonitorSerial = $MonitorSerial
        UsbSerial = $UsbSerial; OneDriveOrg = $OneDriveOrg; CustomerId = $CustomerId
    }
    foreach ($key in @($many.Keys | Sort-Object)) {
        $kept = @(@($many[$key]) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { ([string]$_).Trim() } | Sort-Object -Unique)
        if ($kept.Count -gt 0) { $deny[$key] = $kept }
    }

    $denyError = Get-AnonDenyError -Deny $deny -SaltRequired
    if ($denyError.Count -gt 0) {
        throw ('Get-ShareDenyList: the denylist it built is not usable - {0}' -f ($denyError -join ' '))
    }
    return $deny
}

function Get-ShareDenyArgument {
    <#
        .SYNOPSIS
        The named arguments for Get-ShareDenyList, built from a machine reading.
        Pure: the reading is done by Get-SimRigShareDenyReading in
        SimRig.Probe.ps1, and this decides what of it is a denylist value.

        .DESCRIPTION
        It exists because the console called Get-ShareDenyList with -Machine, a
        parameter that function does not have, and without -Salt, which it
        requires. That call threw the moment anybody opened the Share screen, and
        no test saw it because no test loads the console.

        A share root is split into its host and its share: \\NAS-01\sim-sessions
        denies NAS-01 and sim-sessions separately, so a path written any other way
        (a mapped drive, a lower-case host) is still caught.

        An absent or unreadable value is left out rather than passed as an empty
        string: Get-ShareDenyList drops empties anyway, and a rule that matches
        everything is worse than a missing rule.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Salt,
        $Reading,
        $Machine,
        [AllowNull()] [AllowEmptyCollection()] [string[]] $SharePath = @()
    )

    $argument = @{ Salt = $Salt }

    foreach ($name in @('UserName', 'FullName', 'ComputerName', 'Domain')) {
        $value = [string](Get-ShareField -Entry $Reading -Name $name)
        if ([string]::IsNullOrWhiteSpace($value) -and $name -eq 'ComputerName') {
            $value = [string](Get-ShareField -Entry $Machine -Name 'ComputerName')
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) { $argument[$name] = $value.Trim() }
    }

    foreach ($name in @('Sid', 'Email', 'IpAddress', 'MacAddress', 'VolumeLabel',
            'VolumeSerial', 'DiskSerial', 'MonitorSerial', 'UsbSerial', 'WifiProfile',
            'OneDriveOrg', 'CustomerId')) {
        $kept = @(@(Get-ShareField -Entry $Reading -Name $name) |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { ([string]$_).Trim() } | Sort-Object -Unique)
        if ($kept.Count -gt 0) { $argument[$name] = [string[]]$kept }
    }

    $host_ = [System.Collections.Generic.List[string]]::new()
    $share = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @(@($SharePath) + @(Get-ShareField -Entry $Reading -Name 'MappedDriveTarget'))) {
        $text = [string]$path
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $match = [regex]::Match($text.Trim(), '^\\\\([^\\/]+)(?:[\\/]([^\\/]+))?')
        if (-not $match.Success) { continue }
        $host_.Add($match.Groups[1].Value)
        if ($match.Groups[2].Success -and -not [string]::IsNullOrWhiteSpace($match.Groups[2].Value)) {
            $share.Add($match.Groups[2].Value)
        }
    }
    $hostKept = @($host_.ToArray() | Sort-Object -Unique)
    $shareKept = @($share.ToArray() | Sort-Object -Unique)
    if ($hostKept.Count -gt 0) { $argument['UncHost'] = [string[]]$hostKept }
    if ($shareKept.Count -gt 0) { $argument['UncShare'] = [string[]]$shareKept }

    return $argument
}

function Get-ShareField {
    <#
        .SYNOPSIS
        Reads one field off a hashtable, ordered dictionary or object without
        tripping strict mode on an absent member.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Entry,
        [Parameter(Mandatory)] [string] $Name
    )
    if ($null -eq $Entry) { return $null }
    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains($Name)) { return $Entry[$Name] }
        return $null
    }
    if ($null -ne $Entry.PSObject -and $Entry.PSObject.Properties.Match($Name).Count -gt 0) {
        return $Entry.$Name
    }
    return $null
}

function Get-RigHardwareSummary {
    <#
        .SYNOPSIS
        The short hardware line: the only thing that goes in the issue URL
        (flag 9 - the URL carries no report json). Model names only, so there
        is nothing in it to anonymize.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Machine)

    $part = [System.Collections.Generic.List[string]]::new()

    $cpu = [string](Get-ShareField -Entry (Get-ShareField -Entry $Machine -Name 'Cpu') -Name 'Name')
    if (-not [string]::IsNullOrWhiteSpace($cpu)) { $part.Add($cpu.Trim()) }

    $gpu = Get-ShareField -Entry $Machine -Name 'Gpu'
    $gpuModel = [string](Get-ShareField -Entry $gpu -Name 'Model')
    $gpuDriver = [string](Get-ShareField -Entry $gpu -Name 'DriverVersion')
    if (-not [string]::IsNullOrWhiteSpace($gpuModel)) {
        if ([string]::IsNullOrWhiteSpace($gpuDriver)) { $part.Add($gpuModel.Trim()) }
        else { $part.Add(('{0} driver {1}' -f $gpuModel.Trim(), $gpuDriver.Trim())) }
    }

    $win = Get-ShareField -Entry $Machine -Name 'Windows'
    $build = Get-ShareField -Entry $win -Name 'Build'
    if ($null -ne $build -and -not [string]::IsNullOrWhiteSpace([string]$build)) {
        $part.Add(('Windows build {0}' -f $build))
    }

    $display = Get-ShareField -Entry $Machine -Name 'Display'
    $layout = [string](Get-ShareField -Entry $display -Name 'Layout')
    $count = Get-ShareField -Entry $display -Name 'Count'
    $refresh = Get-ShareField -Entry $display -Name 'Refresh'
    if (-not [string]::IsNullOrWhiteSpace($layout)) {
        $text = $layout.Trim()
        if ($null -ne $count) { $text = ('{0} {1} displays' -f $text, $count) }
        if ($null -ne $refresh) { $text = ('{0} at {1} Hz' -f $text, $refresh) }
        $part.Add($text)
    }

    return (($part.ToArray()) -join ' | ')
}

function Get-RigPathFreeText {
    <#
        .SYNOPSIS
        simrig.rig-report/2 "carries no path". Free text the user typed is kept
        (it is the most useful part of any issue), but a path in it is taken out
        whole - an anonymized path is still a path, and a path shape tells a
        reader more about the machine than the report should.
        Run this AFTER the anonymizer, never instead of it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    $out = [regex]::Replace($Text, '\\{2,4}[^\s"'']+', '[PATH]')
    $out = [regex]::Replace($out, '(?i)[A-Za-z]:[\\/](?!/)[^\s"'']*', '[PATH]')
    return $out
}

function Get-RigSafeMachine {
    <#
        .SYNOPSIS
        The machine profile with the fields that cannot be in a public report
        removed rather than anonymized: the iRacing install and ini folders
        (paths), and the GPU function instance ids (a device serial). What is
        left is hardware, grades and confidence - the useful part.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)] $Machine)

    $out = [ordered]@{}
    $names = if ($Machine -is [System.Collections.IDictionary]) { @($Machine.Keys) }
    else { @($Machine.PSObject.Properties | ForEach-Object { $_.Name }) }

    foreach ($name in $names) {
        $value = Get-ShareField -Entry $Machine -Name $name
        switch ($name) {
            'IRacing' {
                $out[$name] = [ordered]@{ Installed = [bool]($null -ne $value) }
            }
            'Gpu' {
                # A machine with no GPU block read still has to produce a report.
                if ($null -eq $value) { $out[$name] = $null; continue }
                $gpu = [ordered]@{}
                $gpuNames = if ($value -is [System.Collections.IDictionary]) { @($value.Keys) }
                else { @($value.PSObject.Properties | ForEach-Object { $_.Name }) }
                foreach ($g in $gpuNames) {
                    if ($g -eq 'Functions') {
                        $gpu['FunctionCount'] = @(Get-ShareField -Entry $value -Name 'Functions').Count
                        continue
                    }
                    $gpu[$g] = Get-ShareField -Entry $value -Name $g
                }
                $out[$name] = $gpu
            }
            default { $out[$name] = $value }
        }
    }
    return $out
}

function Get-ShareProfileId {
    <#
        .SYNOPSIS
        The profile id as it should ship: raw when clean, a placeholder when not.

        .DESCRIPTION
        The field's purpose is grouping one rig's reports over time, and a salted
        placeholder cannot do that - it changes every report. So a profile id that
        holds nothing identifying travels as itself, and one that holds a machine or
        user name is replaced like any other string.

        .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ProfileId,
        [Parameter(Mandatory)] [hashtable] $Deny
    )

    if ([string]::IsNullOrWhiteSpace($ProfileId)) { return '' }
    # Assign, then wrap. Wrapped in place this was one element on every input, so a
    # profile id with no leak in it counted as one leak and was anonymised anyway.
    $leakRows = Test-AnonymousLeak -Text $ProfileId -Deny $Deny
    $leak = @($leakRows)
    if ($leak.Count -eq 0) { return $ProfileId }
    return (ConvertTo-AnonymousText -Text $ProfileId -Deny $Deny)
}

function Build-RigReport {
    <#
        .SYNOPSIS
        simrig.rig-report/2 - the anonymized community report. It carries the
        machine profile, the gap table by rule Id, the stutter score and the app
        version, and no path, user name, computer name, serial, IP or MAC.

        .DESCRIPTION
        Every string in it goes through ConvertTo-AnonymousObject. The gap rows
        keep Id and Verdict only: a Detail line is free text that names paths
        and file names, and the site does not need it (see the U3.6 asks).
        The app writes the file; it never posts it.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] $Machine,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Gap,
        [Parameter(Mandatory)] [string] $AppVersion,
        [Parameter(Mandatory)] [datetime] $TakenAt,
        [Parameter(Mandatory)] [hashtable] $Deny,
        # The loaded rule documents, for each row's fixed public sentence. Optional:
        # without them a row carries no explanation rather than the internal one,
        # which is the safe direction if a caller forgets.
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Rule = @(),
        $ScoreBefore,
        $ScoreAfter,
        [string] $ProfileId,
        [string] $RuleVersion,
        [string] $Note
    )

    $gapRow = @(foreach ($row in @($Gap | Where-Object { $null -ne $_ })) {
            [pscustomobject]@{
                Id      = [string](Get-ShareField -Entry $row -Name 'Id')
                Name    = [string](Get-ShareField -Entry $row -Name 'Name')
                Verdict = [string](Get-ShareField -Entry $row -Name 'Verdict')
            }
        })

    $scoreField = @('Frames', 'DurationSeconds', 'AvgFps', 'OnePctLowFps', 'PointOnePctLowFps',
        'WorstFrameMs', 'StallCount25', 'StallRate25Per100s', 'StallCount40', 'StallRate40Per100s')
    $score = [ordered]@{}
    foreach ($pair in @(@('Before', $ScoreBefore), @('After', $ScoreAfter))) {
        if ($null -eq $pair[1]) { $score[$pair[0]] = $null; continue }
        $one = [ordered]@{}
        foreach ($f in $scoreField) { $one[$f] = Get-ShareField -Entry $pair[1] -Name $f }
        $score[$pair[0]] = $one
    }

    $noteText = ''
    if (-not [string]::IsNullOrWhiteSpace($Note)) {
        $noteText = Get-RigPathFreeText -Text (ConvertTo-AnonymousText -Text $Note -Deny $Deny)
    }

    $report = [ordered]@{
        # /2, not /1: the gap rows changed shape this build. They were Id and
        # Verdict; they now carry Name and the rule's fixed PublicDetail sentence
        # and never carry Detail. A consumer written against /1 would read a row it
        # does not recognize, so the version says so rather than leaving it to
        # find out.
        Schema      = 'simrig.rig-report/2'
        TakenAt     = (Format-SimRigTime -Time $TakenAt)
        AppVersion  = (ConvertTo-AnonymousText -Text $AppVersion -Deny $Deny)
        # Raw when it carries nothing identifying, scrubbed when it does.
        #
        # A blanket anonymize was the first fix, after this suite found the report
        # carrying the machine name in this field - the profile was named after the PC.
        # It closed the leak and cost the field's only real use: the placeholder
        # changes with every report's salt, so two reports from one rig no longer
        # group. The reference rig's profile was renamed on 2026-09-26, which removes the
        # machine name at the source.
        #
        # Blanket-raw would be wrong, though: somebody else will name a profile after
        # their PC, and their report would leak exactly the way this one did. So the
        # id is checked and only anonymized if it would leak. A clean id groups; a
        # dirty one is replaced and the redaction list says so.
        ProfileId   = (Get-ShareProfileId -ProfileId ([string]$ProfileId) -Deny $Deny)
        RuleVersion = (ConvertTo-AnonymousText -Text ([string]$RuleVersion) -Deny $Deny)
        Hardware    = (ConvertTo-AnonymousText -Text (Get-RigHardwareSummary -Machine $Machine) -Deny $Deny)
        Machine     = (ConvertTo-AnonymousObject -InputObject (Get-RigSafeMachine -Machine $Machine) -Deny $Deny)
        # The public projection first, then the anonymizer over what is left. The
        # projection removes the graded Detail; the anonymizer is the second line of
        # defence, not the first.
        Gap         = (ConvertTo-AnonymousObject -InputObject (ConvertTo-PublicGapRow -Check $gapRow -Rule $Rule) -Deny $Deny)
        Score       = (ConvertTo-AnonymousObject -InputObject $score -Deny $Deny)
        Note        = $noteText
    }
    return $report
}

function Test-RigReport {
    <#
        .SYNOPSIS
        The last gate before anything leaves the PC. Returns an empty list when
        the report is safe to paste, one sentence per problem otherwise. It
        walks every string in the document, so a field added later is checked
        without anyone remembering to add it here.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] $Report)

    $errors = [System.Collections.Generic.List[string]]::new()

    # Flag 16: /1 is still read, because a report written by an older app is still
    # a valid report - its gap rows simply carry no public sentence. Anything else
    # is refused with a sentence that names both versions.
    $schema = [string](Get-ShareField -Entry $Report -Name 'Schema')
    $verdict = Get-SimRigSchemaVerdict -Found $schema -Expected 'simrig.rig-report/2' -AlsoRead @('simrig.rig-report/1')
    if (-not $verdict.Ok) { $errors.Add($verdict.Reason) }
    foreach ($required in @('TakenAt', 'AppVersion', 'Machine', 'Gap')) {
        if ($null -eq (Get-ShareField -Entry $Report -Name $required)) {
            $errors.Add(('{0} is missing.' -f $required))
        }
    }

    $seen = Get-RigReportString -Value $Report
    foreach ($text in $seen) {
        if ([regex]::IsMatch($text, '(?i)[A-Za-z]:[\\/](?!/)')) {
            $errors.Add(('a string in the report still holds a drive path ({0} characters).' -f $text.Length))
        }
        elseif ([regex]::IsMatch($text, '\\{2,4}[A-Za-z0-9]')) {
            $errors.Add(('a string in the report still holds a UNC path ({0} characters).' -f $text.Length))
        }
    }

    $leak = Test-AnonymousLeak -Text (($seen -join "`n")) -Deny @{}
    foreach ($row in @($leak)) {
        $errors.Add(('the report still holds {0} {1} value(s) that rule {2} can see.' -f $row.Count, $row.Kind, $row.Rule))
    }

    return , @($errors.ToArray())
}

function Get-RigReportString {
    <#
        .SYNOPSIS
        Every string in a document, flattened, for the report gate. Keys count:
        a key is a string that leaves the PC like any other.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Value,
        [int] $Depth = 0
    )

    $out = [System.Collections.Generic.List[string]]::new()
    if ($Depth -gt 24 -or $null -eq $Value) { return , @($out.ToArray()) }

    if ($Value -is [string]) {
        if (-not [string]::IsNullOrEmpty($Value)) { $out.Add($Value) }
        return , @($out.ToArray())
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            if ($key -is [string] -and -not [string]::IsNullOrEmpty($key)) { $out.Add([string]$key) }
            $out.AddRange([string[]](Get-RigReportString -Value $Value[$key] -Depth ($Depth + 1)))
        }
        return , @($out.ToArray())
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in @($Value.PSObject.Properties)) {
            $out.Add([string]$prop.Name)
            $out.AddRange([string[]](Get-RigReportString -Value $prop.Value -Depth ($Depth + 1)))
        }
        return , @($out.ToArray())
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            $out.AddRange([string[]](Get-RigReportString -Value $item -Depth ($Depth + 1)))
        }
        return , @($out.ToArray())
    }
    return , @($out.ToArray())
}

function Get-RigIssueUrl {
    <#
        .SYNOPSIS
        The prefilled GitHub issue form URL. The URL carries the short hardware
        summary and nothing else (flag 9): the report json goes in a textarea
        the user pastes, never in a query string.

        .DESCRIPTION
        The title and the summary go through the anonymizer BEFORE they are
        percent-encoded, or an encoded user name would walk straight past a
        plain-text check. The repository must be an https github.com address,
        so a wrong setting cannot send the summary somewhere else.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Template,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Summary,
        [Parameter(Mandatory)] [hashtable] $Deny,
        [string[]] $Label = @('rig-report'),
        [int] $MaxLength = 2000
    )

    $repo = $Repository.TrimEnd('/')
    if ($repo -notmatch '^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') {
        throw ("Get-RigIssueUrl: '{0}' is not an https://github.com/<owner>/<repo> address. Nothing was built." -f $Repository)
    }
    if ($MaxLength -lt 200) {
        throw 'Get-RigIssueUrl: MaxLength below 200 leaves no room for the form URL itself.'
    }

    $safeTitle = ConvertTo-AnonymousText -Text $Title -Deny $Deny
    $safeSummary = Get-RigPathFreeText -Text (ConvertTo-AnonymousText -Text $Summary -Deny $Deny)
    $labels = (@($Label | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ',')

    # The fixed part of the query is built out here, so the analyser can see
    # every parameter being used and the loop below only varies the summary.
    $fixed = [System.Collections.Generic.List[string]]::new()
    $fixed.Add('template=' + [uri]::EscapeDataString($Template))
    if (-not [string]::IsNullOrWhiteSpace($labels)) { $fixed.Add('labels=' + [uri]::EscapeDataString($labels)) }
    $fixed.Add('title=' + [uri]::EscapeDataString($safeTitle))
    $fixedQuery = ($fixed.ToArray() -join '&')

    $build = {
        param([string] $SummaryText)
        return ('{0}/issues/new?{1}&hardware={2}' -f $repo, $fixedQuery, [uri]::EscapeDataString($SummaryText))
    }

    $url = & $build $safeSummary
    $text = $safeSummary
    while ($url.Length -gt $MaxLength -and $text.Length -gt 0) {
        $cut = [Math]::Max(0, $text.Length - [Math]::Max(16, [int]($text.Length / 4)))
        $text = $text.Substring(0, $cut)
        $url = & $build ($text + '...')
    }
    if ($url.Length -gt $MaxLength) {
        $url = & $build ''
    }
    return $url
}

function ConvertTo-RigReportJson {
    <#
        .SYNOPSIS
        The report as the json text that leaves the PC. One function, so the Share
        screen preview and the saved file cannot differ.

        .DESCRIPTION
        Depth 16, which is deeper than the document goes: a truncated branch would
        print as a type name, and a type name in place of a value is a silent hole
        in the report rather than an error anybody sees.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Report)

    return [string]($Report | ConvertTo-Json -Depth 16)
}

function Export-RigReportFile {
    <#
        .SYNOPSIS
        Writes the report the user is about to attach. The gate runs first: a
        report that does not pass Test-RigReport is never written.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Report,
        [Parameter(Mandatory)] [string] $Path
    )

    $gate = Test-RigReport -Report $Report
    if ($gate.Count -gt 0) {
        throw ('Export-RigReportFile: the report did not pass its own gate, so nothing was written - {0}' -f ($gate -join ' '))
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Write the anonymized rig report')) { return $Path }

    $json = ConvertTo-RigReportJson -Report $Report
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

function Get-SupportBundlePlan {
    <#
        .SYNOPSIS
        What goes into the support bundle and under what name. Pure: it decides,
        Export-SupportBundle does the reading and writing.

        .DESCRIPTION
        An entry name is anonymized too - a file called
        RIGPC-latencymon.txt leaks the machine before anyone opens it.
        A file the anonymizer cannot read as text is REFUSED, never copied
        through: flag 8 says every file that leaves the PC passes through the
        anonymizer, and a byte stream cannot.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Source,
        [Parameter(Mandatory)] [datetime] $Now,
        [Parameter(Mandatory)] [hashtable] $Deny,
        [string] $NamePrefix = 'support-bundle'
    )

    $textExtension = @('.txt', '.csv', '.xml', '.ini', '.json', '.jsonl', '.log', '.md', '.yml', '.yaml', '.psd1', '.ps1', '.html', '.cfg')
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $stamp = $Now.ToString('yyyy-MM-dd_HHmm', $culture)

    $used = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $entry = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($item in @($Source | Where-Object { $null -ne $_ })) {
        $path = if ($item -is [string]) { $item } else { [string](Get-ShareField -Entry $item -Name 'Path') }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        $leaf = [System.IO.Path]::GetFileName($path)
        $name = ConvertTo-AnonymousText -Text $leaf -Deny $Deny
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($name)
        $ext = [System.IO.Path]::GetExtension($name)
        $candidate = $name
        $n = 2
        while (-not $used.Add($candidate)) {
            $candidate = ('{0}-{1}{2}' -f $stem, $n, $ext)
            $n++
        }

        $isText = $textExtension -contains ([System.IO.Path]::GetExtension($path)).ToLowerInvariant()
        $entry.Add([pscustomobject]@{
                SourcePath = $path
                EntryName  = $candidate
                Kind       = if ($isText) { 'Text' } else { 'Refuse' }
                Reason     = if ($isText) { $null } else { 'not a text file: the anonymizer cannot read it, so it is left out of the bundle' }
            })
    }

    return [pscustomobject]@{
        Stamp   = $stamp
        ZipName = ('{0}-{1}.zip' -f $NamePrefix, $stamp)
        Entry   = $entry.ToArray()
    }
}

function Export-SupportBundle {
    <#
        .SYNOPSIS
        Builds the support bundle: read each planned file, run it through the
        one anonymizer, write the result into a staging folder, zip the folder.

        .DESCRIPTION
        The source files are opened read-only and never written, so the session
        folder (on the NAS or anywhere else) comes out of this untouched. Each
        staged file is searched again afterwards, and the per-file leak count is
        what the bundle screen shows as "0 found".
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)] [hashtable] $Deny,
        [Parameter(Mandatory)] [string] $StagePath,
        [Parameter(Mandatory)] [string] $ZipPath
    )

    if (-not $PSCmdlet.ShouldProcess($ZipPath, 'Write the anonymized support bundle')) {
        return [pscustomobject]@{ ZipPath = $ZipPath; File = @(); Redaction = @() }
    }

    $null = New-Item -ItemType Directory -Path $StagePath -Force
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $result = [System.Collections.Generic.List[pscustomobject]]::new()
    $written = 0

    foreach ($item in @($Plan.Entry)) {
        if ($item.Kind -ne 'Text') {
            $result.Add([pscustomobject]@{
                    EntryName  = $item.EntryName
                    SourcePath = $item.SourcePath
                    StagedPath = $null
                    Included   = $false
                    Reason     = $item.Reason
                    SourceByte = $null
                    StagedByte = $null
                    Redaction  = @()
                    Leak       = @()
                })
            continue
        }

        $raw = ''
        try {
            $raw = [System.IO.File]::ReadAllText($item.SourcePath)
        }
        catch {
            $result.Add([pscustomobject]@{
                    EntryName  = $item.EntryName
                    SourcePath = $item.SourcePath
                    StagedPath = $null
                    Included   = $false
                    Reason     = ('could not be read as text, so it is left out: {0}' -f $_.Exception.Message)
                    SourceByte = $null
                    StagedByte = $null
                    Redaction  = @()
                    Leak       = @()
                })
            continue
        }

        $resolved = Resolve-AnonymousText -Text $raw -Deny $Deny
        $leakRow = Test-AnonymousLeak -Text $resolved.Text -Deny $Deny
        $staged = Join-Path -Path $StagePath -ChildPath $item.EntryName
        [System.IO.File]::WriteAllText($staged, $resolved.Text, $encoding)
        $written++

        $result.Add([pscustomobject]@{
                EntryName  = $item.EntryName
                SourcePath = $item.SourcePath
                StagedPath = $staged
                Included   = $true
                Reason     = $null
                SourceByte = $raw.Length
                StagedByte = $resolved.Text.Length
                Redaction  = $resolved.Redaction
                Leak       = $leakRow
            })
    }

    if ($written -eq 0) {
        throw 'Export-SupportBundle: no file in the plan could be anonymized, so no bundle was made.'
    }

    $zipParent = Split-Path -Path $ZipPath -Parent
    if ($zipParent -and -not (Test-Path -LiteralPath $zipParent)) {
        $null = New-Item -ItemType Directory -Path $zipParent -Force
    }
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    Compress-Archive -Path (Join-Path -Path $StagePath -ChildPath '*') -DestinationPath $ZipPath -Force

    $merged = @($result | Where-Object { $_.Included } | ForEach-Object { $_.Redaction } |
            Group-Object -Property Placeholder | ForEach-Object {
                [pscustomobject]@{
                    Kind        = $_.Group[0].Kind
                    Placeholder = $_.Name
                    Count       = (@($_.Group | ForEach-Object { $_.Count }) | Measure-Object -Sum).Sum
                    Rule        = ((@($_.Group | ForEach-Object { $_.Rule -split ',' }) | Sort-Object -Unique) -join ',')
                }
            } | Sort-Object -Property Kind, Placeholder)

    return [pscustomobject]@{
        ZipPath   = $ZipPath
        StagePath = $StagePath
        File      = $result.ToArray()
        Redaction = $merged
    }
}

function Get-BundleScreenRow {
    <#
        .SYNOPSIS
        The bundle screen (flag 8): every file listed, what was taken out of it,
        and the "0 found" search for the user name and the computer name. A row
        for a refused file says why it is not in the zip.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)] $Result)

    $rows = @(foreach ($f in @($Result.File)) {
            $leak = @($f.Leak)
            [pscustomobject]@{
                File          = [string]$f.EntryName
                Included      = [bool]$f.Included
                Reason        = $f.Reason
                Byte          = $f.StagedByte
                Redacted      = (@(@($f.Redaction) | ForEach-Object { $_.Count }) | Measure-Object -Sum).Sum
                UserFound     = @($leak | Where-Object { $_.Kind -eq 'User' -or $_.Kind -eq 'Name' }).Count
                ComputerFound = @($leak | Where-Object { $_.Kind -eq 'Computer' -or $_.Kind -eq 'Domain' }).Count
                LeakFound     = $leak.Count
            }
        })
    return , @($rows | Sort-Object -Property File)
}
