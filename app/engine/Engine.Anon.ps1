# Engine.Anon.ps1 - SimRig Console v4.2, unit U3.6 (flag 8).
#
# THE anonymizer. One pure function behind one denylist, and every string that
# leaves the PC goes through it: rig report, support bundle, logs, self-test
# report, LatencyMon text, CapFrameX json, the GitHub issue URL.
#
# PURE. No clock, no filesystem, no registry, no process, no environment - the
# caller reads the machine, builds Deny (including the per-report Salt) and
# passes everything in. No top-level code except function definitions, so this
# file folds into SimRig.Engine.ps1 at integration (CONTRACT.md).
#
# Placeholder shape:  [KIND-xxxxxxxx]
#   xxxxxxxx is the first 4 bytes of sha256(Salt + kind + lower-cased value).
#   Stable  - the same value is the same placeholder in every file of one
#             report, because the salt is one per report. Two mentions of the
#             same machine read as the same machine.
#   One-way - with a fresh random salt per report that is never written down,
#             a placeholder cannot be taken back to the original, and a
#             dictionary of likely computer names does not break it.
#   Square brackets, not angle brackets: a GitHub issue body is Markdown, and
#   Markdown swallows <LIKE-THIS> as an unknown HTML tag.
#
# Kept on purpose: check results and grades, hardware model names (RTX 4090,
# 7800X3D), frametime figures, Windows build numbers.

function Get-AnonKindMap {
    <#
        .SYNOPSIS
        Denylist key -> placeholder kind. The keys are exactly the categories
        the brief names for the run-time denylist; anything else in Deny is an
        error, never silently ignored.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        UserName          = 'User'
        FullName          = 'Name'
        ComputerName      = 'Computer'
        Domain            = 'Domain'
        Sid               = 'Sid'
        Email             = 'Email'
        WifiProfile       = 'Wifi'
        IpAddress         = 'Ip'
        MacAddress        = 'Mac'
        UncHost           = 'Host'
        UncShare          = 'Share'
        MappedDriveTarget = 'Path'
        VolumeLabel       = 'Volume'
        VolumeSerial      = 'Serial'
        DiskSerial        = 'Serial'
        MonitorSerial     = 'Serial'
        UsbSerial         = 'Serial'
        OneDriveOrg       = 'Org'
        CustomerId        = 'CustId'
    }
}

function Get-AnonKeepValue {
    <#
        .SYNOPSIS
        Values a pattern may capture that identify nobody, so redacting them
        only makes the bundle harder to read. Compared case-insensitively.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return , @('Public', 'Default', 'Default User', 'All Users', 'defaultuser0', 'DefaultAppPool')
}

function Get-AnonDenyError {
    <#
        .SYNOPSIS
        Validates a denylist. An empty list means it is usable; otherwise one
        sentence per problem (the Test-RuleData convention).

        .PARAMETER SaltRequired
        Set by the replacing path only: a placeholder without a salt is
        reversible, so Resolve-AnonymousText refuses to run without one. A leak
        scan needs no salt and does not set it.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [hashtable] $Deny,
        [switch] $SaltRequired
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $map = Get-AnonKindMap

    foreach ($key in @($Deny.Keys | Sort-Object)) {
        if ($key -eq 'Salt') { continue }
        if (-not $map.ContainsKey($key)) {
            $errors.Add(("Deny key '{0}' is not a denylist category. Known: {1}." -f $key, ((@($map.Keys) | Sort-Object) -join ', ')))
            continue
        }
        foreach ($value in @($Deny[$key])) {
            if ($null -eq $value) { continue }
            if ($value -isnot [string]) {
                $errors.Add(("Deny.{0} holds a {1}; a denylist value is a string." -f $key, $value.GetType().Name))
                continue
            }
            $trimmed = ([string]$value).Trim()
            if ($trimmed.Length -eq 0) { continue }
            if ($trimmed.Length -lt 2) {
                $errors.Add(("Deny.{0} holds a one-character value; replacing it everywhere would shred the text." -f $key))
            }
        }
    }

    if ($SaltRequired) {
        $salt = if ($Deny.ContainsKey('Salt')) { [string]$Deny['Salt'] } else { '' }
        if ([string]::IsNullOrWhiteSpace($salt)) {
            $errors.Add('Deny.Salt is missing. Without a per-report salt the placeholders are reversible by dictionary, so the anonymizer will not run.')
        }
        elseif ($salt.Trim().Length -lt 8) {
            $errors.Add('Deny.Salt is shorter than 8 characters. Use at least 16 random characters, fresh per report.')
        }
    }

    return , @($errors.ToArray())
}

function Get-AnonPlaceholder {
    <#
        .SYNOPSIS
        The stable, one-way placeholder for one value of one kind under one
        salt. Case and surrounding whitespace do not change the answer, so
        RIGPC and rigpc read as the same machine.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Kind,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value,
        [Parameter(Mandatory)] [string] $Salt
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $material = ('{0}{1}{2}{1}{3}' -f $Salt, [char]0, $Kind.ToLowerInvariant(), $Value.Trim().ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material))
    }
    finally { $sha.Dispose() }
    $hex = -join (@($digest[0], $digest[1], $digest[2], $digest[3]) | ForEach-Object { $_.ToString('x2', $culture) })
    return ('[{0}-{1}]' -f $Kind.ToUpperInvariant(), $hex)
}

function Test-AnonPlaceholder {
    <#
        .SYNOPSIS
        True when a string is already a placeholder. Every rule skips one, so
        anonymizing an already-anonymized file changes nothing and a leak scan
        of anonymized text reports nothing.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)
    return [regex]::IsMatch($Value, '^\[[A-Z]{2,12}-[0-9a-f]{8}\]$')
}

function Get-AnonRule {
    <#
        .SYNOPSIS
        The fixed patterns, in the order they run. Each rule names the groups
        that hold the secret; the rest of the match is kept, so a path still
        reads as a path and a device id keeps its VEN/DEV model ids.

        .DESCRIPTION
        Order matters:
          - UNC runs before the address rules, so a share on a NAS addressed by
            IP still has its share name taken out.
          - The IPv6 rules need a '::' or seven colons, or the LatencyMon
            duration "0:03:06" would go with them.
          - IPv4 is octet-accurate with no digit or dot either side, which is
            what keeps 10.0.26100.1 and every four-part file version out of it.
        Every secret group starts with (?!\[) so a placeholder is never
        re-wrapped.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    $none = [System.Text.RegularExpressions.RegexOptions]::None
    $icase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $both = [System.Text.RegularExpressions.RegexOptions]::Multiline -bor $icase

    $rule = @(
        # The LatencyMon "Computer name" line (the brief names it explicitly).
        # Group 2 eats the padding so group 3 must start on a non-space: that
        # is what makes this rule idempotent.
        [pscustomobject]@{
            Id      = 'LatencyMonComputer'; Kind = @('Computer'); Group = @(3); Option = $both
            Pattern = '^(Computer name:)([ \t]*)((?!\[)\S[^\r\n]*?)[ \t]*$'
        }
        [pscustomobject]@{
            Id      = 'Sid'; Kind = @('Sid'); Group = @(0); Option = $icase
            Pattern = 'S-1-5-21-\d{1,10}-\d{1,10}-\d{1,10}(?:-\d{1,10})+'
        }
        [pscustomobject]@{
            Id      = 'Email'; Kind = @('Email'); Group = @(0); Option = $none
            Pattern = '(?<![\w.+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,24}(?![\w.-])'
        }
        # \\host\share in plain text and in json-escaped text (\\\\h\\s). The
        # slashes must START a path token (line start, space, quote, comma...).
        # A json log writes C:\\Users\\x with two slashes per separator, and
        # after an earlier rule leaves a ] before one of them, any looser guard
        # reads \\Documents as a UNC host - it did, on the first run.
        [pscustomobject]@{
            Id      = 'UncPath'; Kind = @('Host', 'Share'); Group = @(1, 2); Option = $none
            Pattern = '(?:^|[\s"''=,;(<>|])\\{2,4}((?!\[)[A-Za-z0-9._-]{2,})\\{1,2}((?!\[)[A-Za-z0-9._$-]+)'
        }
        [pscustomobject]@{
            Id      = 'UncHost'; Kind = @('Host'); Group = @(1); Option = $none
            Pattern = '(?:^|[\s"''=,;(<>|])\\{2,4}((?!\[)[A-Za-z0-9._-]{2,})(?![A-Za-z0-9._-])'
        }
        [pscustomobject]@{
            Id      = 'Mac'; Kind = @('Mac'); Group = @(0); Option = $none
            Pattern = '(?<![\w:.-])(?:[A-Fa-f0-9]{2}[:-]){5}[A-Fa-f0-9]{2}(?![\w:.-])'
        }
        [pscustomobject]@{
            Id      = 'Ipv6Full'; Kind = @('Ip'); Group = @(0); Option = $none
            Pattern = '(?<![\w:])(?:[A-Fa-f0-9]{1,4}:){7}[A-Fa-f0-9]{1,4}(?![\w:])'
        }
        [pscustomobject]@{
            Id      = 'Ipv6Compressed'; Kind = @('Ip'); Group = @(0); Option = $none
            Pattern = '(?<![\w:])(?:[A-Fa-f0-9]{1,4}:){1,6}:(?:[A-Fa-f0-9]{1,4}(?::[A-Fa-f0-9]{1,4}){0,5})?(?![\w:])'
        }
        [pscustomobject]@{
            Id      = 'Ipv4'; Kind = @('Ip'); Group = @(0); Option = $none
            Pattern = '(?<![\d.])(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}(?![\d.])'
        }
        # The user name inside a profile path, however deep the path goes and
        # whether the separators are \, \\ (json) or /.
        [pscustomobject]@{
            Id      = 'UserProfilePath'; Kind = @('User'); Group = @(2); Option = $icase
            Pattern = '([\\/]{1,2}Users[\\/]{1,2})((?!\[)[^\\/:*?"<>|\r\n]+)'
        }
        # The serial part of a PCI/USB/HID instance id. The VEN/DEV/SUBSYS
        # segment is model information and is kept.
        [pscustomobject]@{
            Id      = 'DeviceInstanceSerial'; Kind = @('Serial'); Group = @(2); Option = $icase
            Pattern = '((?:PCI|USB|HID|SCSI|ACPI|BTH)\\[^\\\r\n",]+)\\((?!\[)[^\\\r\n",;)\s]+)'
        }
        # The bare enumeration key, e.g. 4&15a5c264&0&010B. A PowerShell
        # registry dump wraps long instance ids across lines, so the rule above
        # cannot see the id it belongs to (gpu-affinity-policy.txt does exactly
        # this). This catches the key on its own.
        [pscustomobject]@{
            Id      = 'DeviceEnumKey'; Kind = @('Serial'); Group = @(0); Option = $none
            Pattern = '(?<![\w&])\d&[0-9a-fA-F]{6,10}&\d&[0-9a-fA-F]{1,6}(?![\w&])'
        }
        [pscustomobject]@{
            Id      = 'SerialLine'; Kind = @('Serial'); Group = @(2); Option = $both
            Pattern = '^([ \t]*(?:Serial Number|SerialNumber|Serial)[ \t]*[:=][ \t]*)((?!\[)\S+)[ \t]*$'
        }
        # Rick ran the finder on the rig on 2026-09-27 and it found his customer
        # id in three shapes. This rule matched ONE of them:
        #
        #   iRacingSim64DX11__18h16m09s.log : custID:1234567        matched
        #   aiseasons\*.json                : "cust_id": 1234567     MISSED
        #   sidekick\irSidekick.ini         : MemberID=1234567       MISSED
        #   sidekick\irSidekickDeploy.log   : MemberID: 1234567      MISSED
        #
        # The JSON form missed because the key is quoted, so the closing quote
        # sits between the name and the colon. Sidekick missed because it calls
        # it a member id, and nothing here had ever heard that word. A shared rig
        # report would have carried the number in two of the four places it lives.
        #
        # Quotes around the key are optional on both sides rather than matched as
        # a pair: a report is text scraped from several formats, and refusing to
        # redact something because its quoting was odd is the wrong way to fail.
        [pscustomobject]@{
            Id      = 'CustomerId'; Kind = @('CustId'); Group = @(2); Option = $icase
            Pattern = '((?:["\x27])?(?:cust(?:omer)?[ _]?id|iRacingCustomerId|iracing[ _]?id|member[ _]?id)(?:["\x27])?[ \t]*[:=][ \t]*)((?!\[)\d{3,12})'
        }
    )
    return , @($rule)
}

function Resolve-AnonymousText {
    <#
        .SYNOPSIS
        The one code path: returns the anonymized text AND the redaction list
        that produced it, so what the bundle screen shows can never drift from
        what actually changed.

        .DESCRIPTION
        Patterns first, then the denylist literals longest value first. The
        pattern pass is what saves a value the caller never knew about (an
        unseen user name, an unknown NAS, an unknown SID); the literal pass
        catches the known values everywhere else in the text.

        A captured value that is also on the denylist takes that entry's kind,
        so \\RIGPC\share and a bare RIGPC read as the same machine.

        .OUTPUTS
        pscustomobject: Text (string), Redaction (Kind, Placeholder, Count, Rule).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [hashtable] $Deny
    )

    $denyError = Get-AnonDenyError -Deny $Deny -SaltRequired
    if ($denyError.Count -gt 0) {
        throw ('Resolve-AnonymousText: the denylist is not usable - {0}' -f ($denyError -join ' '))
    }

    $salt = ([string]$Deny['Salt']).Trim()
    $map = Get-AnonKindMap
    $keep = Get-AnonKeepValue
    $tally = [System.Collections.Generic.Dictionary[string, pscustomobject]]::new()
    $cache = [System.Collections.Generic.Dictionary[string, string]]::new()

    # value (lower-cased) -> kind, and the literal list. Keys are walked in
    # sorted order, so a value on two categories always lands on one kind.
    $known = [System.Collections.Generic.Dictionary[string, string]]::new()
    $literal = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($key in @($map.Keys | Sort-Object)) {
        if (-not $Deny.ContainsKey($key)) { continue }
        foreach ($value in @($Deny[$key])) {
            if ($null -eq $value) { continue }
            $s = ([string]$value).Trim()
            if ($s.Length -lt 2) { continue }
            $low = $s.ToLowerInvariant()
            if ($known.ContainsKey($low)) { continue }
            $known[$low] = [string]$map[$key]
            $literal.Add([pscustomobject]@{ Kind = [string]$map[$key]; Value = $s })
        }
    }

    $out = $Text

    foreach ($rule in (Get-AnonRule)) {
        if ([string]::IsNullOrEmpty($out)) { break }
        $regex = [regex]::new($rule.Pattern, $rule.Option)
        if (-not $regex.IsMatch($out)) { continue }

        # Secret groups back to front, so replacing one does not move another.
        $slot = @(0..($rule.Group.Count - 1) | ForEach-Object {
                [pscustomobject]@{ Group = [int]$rule.Group[$_]; Kind = [string]$rule.Kind[$_] }
            } | Sort-Object -Property Group -Descending)
        $ruleId = [string]$rule.Id

        $out = $regex.Replace($out, {
                param($m)
                $rebuilt = $m.Value
                foreach ($s in $slot) {
                    $group = $m.Groups[$s.Group]
                    if (-not $group.Success) { continue }
                    $raw = $group.Value
                    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                    if (Test-AnonPlaceholder -Value $raw) { continue }
                    if ($keep -contains $raw) { continue }

                    $low = $raw.ToLowerInvariant()
                    $kind = if ($known.ContainsKey($low)) { $known[$low] } else { $s.Kind }
                    $cacheKey = $kind + [char]0 + $low
                    if ($cache.ContainsKey($cacheKey)) {
                        $ph = $cache[$cacheKey]
                    }
                    else {
                        $ph = Get-AnonPlaceholder -Kind $kind -Value $raw -Salt $salt
                        $cache[$cacheKey] = $ph
                    }

                    $rebuilt = $rebuilt.Remove(($group.Index - $m.Index), $group.Length).Insert(($group.Index - $m.Index), $ph)

                    if ($tally.ContainsKey($ph)) {
                        $row = $tally[$ph]
                        $row.Count = $row.Count + 1
                        if (($row.Rule -split ',') -notcontains $ruleId) {
                            $row.Rule = ((@($row.Rule -split ',') + $ruleId) | Sort-Object) -join ','
                        }
                    }
                    else {
                        $tally[$ph] = [pscustomobject]@{ Kind = $kind; Placeholder = $ph; Count = 1; Rule = $ruleId }
                    }
                }
                return $rebuilt
            })
    }

    # Longest value first, so RIGPC\racer is handled before RIGPC alone
    # and a full name before its parts. The trailing lookahead stops a literal
    # that happens to spell a kind (a machine called USER) from eating the
    # placeholder text written a moment ago.
    $ordered = @($literal | Sort-Object -Property @{ Expression = { $_.Value.Length }; Descending = $true }, @{ Expression = { $_.Value }; Descending = $false })
    foreach ($lit in $ordered) {
        if ([string]::IsNullOrEmpty($out)) { break }
        $pattern = '(?<![A-Za-z0-9])' + [regex]::Escape($lit.Value) + '(?![A-Za-z0-9])(?!-[0-9a-f]{8}\])'
        $regex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $found = $regex.Matches($out)
        if ($found.Count -eq 0) { continue }

        $low = $lit.Value.ToLowerInvariant()
        $cacheKey = $lit.Kind + [char]0 + $low
        if ($cache.ContainsKey($cacheKey)) {
            $ph = $cache[$cacheKey]
        }
        else {
            $ph = Get-AnonPlaceholder -Kind $lit.Kind -Value $lit.Value -Salt $salt
            $cache[$cacheKey] = $ph
        }

        if ($tally.ContainsKey($ph)) {
            $row = $tally[$ph]
            $row.Count = $row.Count + $found.Count
            if (($row.Rule -split ',') -notcontains 'Deny') {
                $row.Rule = ((@($row.Rule -split ',') + 'Deny') | Sort-Object) -join ','
            }
        }
        else {
            $tally[$ph] = [pscustomobject]@{ Kind = $lit.Kind; Placeholder = $ph; Count = $found.Count; Rule = 'Deny' }
        }

        $out = $regex.Replace($out, $ph)
    }

    $rows = @($tally.Values | Sort-Object -Property Kind, Placeholder)
    return [pscustomobject]@{ Text = $out; Redaction = $rows }
}

function ConvertTo-AnonymousText {
    <#
        .SYNOPSIS
        The contract entry point (CONTRACT.md, "The anonymizer API (flag 8)"):
        one string in, the anonymized string out. Every file that leaves the PC
        goes through this.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [hashtable] $Deny
    )
    return (Resolve-AnonymousText -Text $Text -Deny $Deny).Text
}

function Measure-AnonRedaction {
    <#
        .SYNOPSIS
        What changed, for the screen the user reads before anything leaves: one
        row per placeholder, with its kind, the rules that produced it and a
        count. It names no original value, so the list itself is safe to show
        and to attach.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [hashtable] $Deny
    )
    return , @((Resolve-AnonymousText -Text $Text -Deny $Deny).Redaction)
}

function Test-AnonymousLeak {
    <#
        .SYNOPSIS
        The "0 found" search the bundle screen runs on the OUTPUT: every
        denylist value and every fixed pattern, looked for again. An empty list
        means nothing is left. A row carries the kind, the rule and a count
        only - never the value that leaked.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [hashtable] $Deny
    )

    $denyError = Get-AnonDenyError -Deny $Deny
    if ($denyError.Count -gt 0) {
        throw ('Test-AnonymousLeak: the denylist is not usable - {0}' -f ($denyError -join ' '))
    }

    $map = Get-AnonKindMap
    $keep = Get-AnonKeepValue
    $rows = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($key in @($map.Keys | Sort-Object)) {
        if (-not $Deny.ContainsKey($key)) { continue }
        foreach ($value in @($Deny[$key])) {
            if ($null -eq $value) { continue }
            $s = ([string]$value).Trim()
            if ($s.Length -lt 2) { continue }
            $pattern = '(?<![A-Za-z0-9])' + [regex]::Escape($s) + '(?![A-Za-z0-9])(?!-[0-9a-f]{8}\])'
            $n = [regex]::Matches($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
            if ($n -gt 0) {
                $rows.Add([pscustomobject]@{ Kind = [string]$map[$key]; Rule = 'Deny'; Count = $n })
            }
        }
    }

    foreach ($rule in (Get-AnonRule)) {
        $regex = [regex]::new($rule.Pattern, $rule.Option)
        $left = 0
        foreach ($m in $regex.Matches($Text)) {
            for ($i = 0; $i -lt $rule.Group.Count; $i++) {
                $group = $m.Groups[[int]$rule.Group[$i]]
                if (-not $group.Success) { continue }
                $raw = $group.Value
                if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                if (Test-AnonPlaceholder -Value $raw) { continue }
                if ($keep -contains $raw) { continue }
                $left++
            }
        }
        if ($left -gt 0) {
            $rows.Add([pscustomobject]@{ Kind = [string]$rule.Kind[0]; Rule = [string]$rule.Id; Count = $left })
        }
    }

    return , @($rows.ToArray() | Sort-Object -Property Kind, Rule)
}

function ConvertTo-AnonymousObject {
    <#
        .SYNOPSIS
        The same anonymizer over a whole document: every string in a nested
        hashtable, ordered dictionary, pscustomobject or array - VALUES AND
        KEYS. A hashtable keyed by file path is otherwise a leak hiding behind
        a clean-looking value.

        Numbers, booleans, dates, guids, enums and $null pass through
        untouched, so frametimes, build numbers and grades survive.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [hashtable] $Deny,
        [int] $Depth = 0
    )

    if ($Depth -gt 24) {
        throw 'ConvertTo-AnonymousObject: the document nests deeper than 24 levels; refusing rather than half-anonymizing it.'
    }
    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [string]) {
        return (ConvertTo-AnonymousText -Text $InputObject -Deny $Deny)
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($key in @($InputObject.Keys)) {
            $newKey = if ($key -is [string]) { ConvertTo-AnonymousText -Text $key -Deny $Deny } else { $key }
            $slot = $newKey
            $n = 2
            while ($out.Contains($slot)) {
                $slot = ('{0} ({1})' -f $newKey, $n)
                $n++
            }
            $out[$slot] = ConvertTo-AnonymousObject -InputObject $InputObject[$key] -Deny $Deny -Depth ($Depth + 1)
        }
        return $out
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $out = [ordered]@{}
        foreach ($prop in @($InputObject.PSObject.Properties)) {
            $newKey = ConvertTo-AnonymousText -Text $prop.Name -Deny $Deny
            $out[$newKey] = ConvertTo-AnonymousObject -InputObject $prop.Value -Deny $Deny -Depth ($Depth + 1)
        }
        return [pscustomobject]$out
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $InputObject) {
            $list.Add((ConvertTo-AnonymousObject -InputObject $item -Deny $Deny -Depth ($Depth + 1)))
        }
        return , @($list.ToArray())
    }

    return $InputObject
}

function ConvertTo-PublicGapRow {
    <#
        .SYNOPSIS
        Gap rows for the community report: Id, Name, Verdict, and the rule's own
        fixed public sentence.

        .DESCRIPTION
        The graded Detail line never travels. It is assembled while grading and it
        names paths, ini keys, device instance ids and file names - the sort of free
        text an anonymizer can only ever partly clean, because it can only remove
        what it recognizes.

        So the explanation comes from the rule instead. PublicDetail is written by
        hand, once, by whoever wrote the rule, at a time when there is no machine to
        leak anything about. Nothing in it needs scrubbing because nothing machine-
        specific can get into it, and a test fails the build if one ever does.

        A row whose rule cannot be found says so plainly. Falling back to the graded
        Detail would defeat the entire arrangement, and the first person to hit that
        path would never know.

        Pure.

        .OUTPUTS
        [object[]] Id, Name, Verdict, PublicDetail - and no Detail.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Check,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rule
    )

    $sentence = @{}
    foreach ($r in @($Rule)) {
        if ($null -eq $r) { continue }
        $id = Get-KnownGoodField -Entry $r -Name 'Id'
        $text = Get-KnownGoodField -Entry $r -Name 'PublicDetail'
        if ($id -and $text) { $sentence[[string]$id] = [string]$text }
    }

    $rows = foreach ($row in @($Check)) {
        if ($null -eq $row) { continue }
        $id = [string](Get-KnownGoodField -Entry $row -Name 'Id')
        [pscustomobject]@{
            Id           = $id
            Name         = [string](Get-KnownGoodField -Entry $row -Name 'Name')
            Verdict      = [string](Get-KnownGoodField -Entry $row -Name 'Verdict')
            PublicDetail = $(if ($sentence.ContainsKey($id)) { $sentence[$id] } else { 'This check has no public explanation yet, so none is shown rather than the internal one.' })
        }
    }

    return , @($rows | Where-Object { $null -ne $_ })
}
