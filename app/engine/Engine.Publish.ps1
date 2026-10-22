<#
    Engine.Publish.ps1 - unit U4.3 (build brief flag 9: the results Action treats every
    issue as hostile).

    Pure functions. No filesystem, no network, no clock, no $env:. The Action reads the
    event from $GITHUB_EVENT_PATH and hands the text to these functions; nothing here
    knows it is running in CI, which is why it can be tested with the hostile bodies a
    stranger can actually send.

    The threat model, stated plainly. Anyone on the internet can open an issue on a
    public repo. The body is attacker-controlled text. It reaches a workflow that has
    write access to the repository that serves the site. So:

    - No user text ever reaches a shell. The Action passes the body as data; these
      functions never build a command line.
    - A field is published only if it matched a rule written in advance. Not "is it
      dangerous" - "is it one of the values we expect". An allowlist refuses the
      attack nobody has thought of yet.
    - results.json is built from validated fields only, never by copying the payload.
      A field we do not publish cannot be a field we publish by mistake.
    - The site renders with textContent (U4.4's job), so a string that survives all of
      this still cannot execute. Two layers, because one is one too few.
#>

Set-StrictMode -Version 3.0

$script:SimRigPublishPayloadCap = 64KB
$script:SimRigPublishRowCap = 500

function Get-SimRigPublishPayloadCap {
    <#
        .SYNOPSIS
        The largest report body this Action will look at, in bytes.

        .DESCRIPTION
        64 KB (flag 9). A real report is a few KB. The cap is checked before the JSON
        parser is asked for an opinion, because a parser is the wrong place to discover
        that somebody sent a megabyte.

        .OUTPUTS
        [int]
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    return $script:SimRigPublishPayloadCap
}

function Get-SimRigPublishEventVerdict {
    <#
        .SYNOPSIS
        Whether this event may publish: the action, the label and the sender's
        permission.

        .DESCRIPTION
        Three conditions, and all three are the requirement (flag 9):

        - The action is 'labeled'. Not opened, not edited, not commented.
        - The label added is the approved label. A different label is not a refusal
          worth shouting about - it is simply not this Action's business.
        - The sender has admin or maintain permission. Write is not enough: a
          contributor with push rights is not the person who decides what the site
          publishes. The API call that reads the permission is the caller's; this
          function grades the answer.

        Pure.

        .OUTPUTS
        [pscustomobject] Ok, Verdict (Publish|Ignore|Refuse), Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [string] $Action,
        [AllowNull()] [string] $LabelName,
        [AllowNull()] [string] $Permission,
        [string] $ApprovedLabel = 'approved'
    )

    if ([string]$Action -ne 'labeled') {
        return [pscustomobject]@{
            Ok = $false; Verdict = 'Ignore'
            Reason = ("Nothing to do: this Action publishes on 'labeled' and the event was '{0}'." -f $Action)
        }
    }

    if ([string]$LabelName -ne $ApprovedLabel) {
        return [pscustomobject]@{
            Ok = $false; Verdict = 'Ignore'
            Reason = ("Nothing to do: the label added was '{0}', not '{1}'." -f $LabelName, $ApprovedLabel)
        }
    }

    # Deliberately not a "not in deny list" check. Only these two.
    if ([string]$Permission -notin @('admin', 'maintain')) {
        return [pscustomobject]@{
            Ok = $false; Verdict = 'Refuse'
            Reason = ("The approved label was added by an account with '{0}' permission. Publishing needs admin or maintain, because the label is the decision and anyone who can add it can put text on the site." -f $(if ($Permission) { $Permission } else { 'none' }))
        }
    }

    return [pscustomobject]@{ Ok = $true; Verdict = 'Publish'; Reason = 'Approved by an account that may approve.' }
}

function Get-SimRigPublishPayloadText {
    <#
        .SYNOPSIS
        The report JSON out of an issue body, or $null.

        .DESCRIPTION
        The issue form puts the textarea's contents in a fenced block, because the form
        field is declared with 'render: json'. So the body is markdown and the payload
        is inside it.

        The first fenced block that parses as an object wins, and nothing else in the
        body is read. A hostile body can carry three fences, a fence inside a fence, or
        a fence that never closes - none of that decides anything here, because a block
        that is not a JSON object is skipped rather than repaired.

        Pure.

        .OUTPUTS
        [string] the block's text, or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()] [AllowEmptyString()] [string] $Body)

    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }

    $normal = $Body -replace "`r`n", "`n"
    # Fence, optional language, then everything up to the next fence at line start.
    $pattern = '(?ms)^```[ \t]*[A-Za-z0-9]*[ \t]*\n(.*?)^```'
    foreach ($found in [regex]::Matches($normal, $pattern)) {
        $text = $found.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text.TrimStart().StartsWith('{')) { return $text }
    }

    # No fence at all: a body that is only the JSON is still a report. Anything else is
    # not, and says so by returning nothing.
    if ($normal.TrimStart().StartsWith('{')) { return $normal }
    return $null
}

function Get-SimRigPublishFieldRule {
    <#
        .SYNOPSIS
        What each published field has to look like: one table, reviewable in one screen.

        .DESCRIPTION
        This is the allowlist flag 9 asks for. Every rule is a shape, not a prohibition:
        a CPU name is a string that matches the vendor patterns we know, a layout is one
        of three words, a score is a number in a range. A value that does not match is
        not published, whatever it contains.

        Adding a field here is a deliberate act, and the test that walks this table
        fails if a rule has no Why.

        Pure.

        .OUTPUTS
        [object[]] Name, Kind (String|Number|Enum), Pattern/Allowed/Min/Max, Why.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    return @(
        [pscustomobject]@{ Name = 'Schema'; Kind = 'Enum'
            Allowed = @('simrig.rig-report/2', 'simrig.rig-report/1')
            Why = 'the document version. /1 is still read because a report from v4.1 is still a real report; anything else was written by something we have not seen.' }
        [pscustomobject]@{ Name = 'TakenAt'; Kind = 'String'
            Pattern = '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2})?Z?$'; MaxLength = 32
            Why = 'a timestamp, and only a timestamp. Free text here would be printed on the site next to a date.' }
        [pscustomobject]@{ Name = 'AppVersion'; Kind = 'String'
            Pattern = '^[0-9A-Za-z.\-+ ]{1,32}$'; MaxLength = 32
            Why = 'a version string. The characters allowed are the ones a version has.' }
        [pscustomobject]@{ Name = 'ProfileId'; Kind = 'String'
            Pattern = '^[A-Za-z0-9\-_]{1,40}$'; MaxLength = 40
            Why = 'a profile id, or the anonymizer placeholder that replaced one. No spaces, no punctuation to hide markup in.' }
        [pscustomobject]@{ Name = 'RuleVersion'; Kind = 'String'
            Pattern = '^[0-9a-fA-F]{6,64}$'; MaxLength = 64
            Why = 'the rules hash. It is a hash, so it looks like one.' }
        [pscustomobject]@{ Name = 'Hardware'; Kind = 'String'
            Pattern = '^[0-9A-Za-z.,\-+()/\\: ]{1,120}$'; MaxLength = 120
            Why = 'the short hardware summary the site groups by. Letters, digits and the punctuation a part number uses - nothing that opens a tag or a quote.' }
        [pscustomobject]@{ Name = 'Note'; Kind = 'String'
            Pattern = '^[0-9A-Za-z.,!?''\-+()/: \n]{0,400}$'; MaxLength = 400
            Why = "the reporter's own sentence, which is the one field a person writes freely - so it is the field held tightest: no angle brackets, no braces, no ampersands, 400 characters." }
        [pscustomobject]@{ Name = 'Cpu'; Kind = 'String'
            Pattern = '^(AMD|Intel)[0-9A-Za-z.\-+()/ ]{2,80}$'; MaxLength = 80
            Why = 'a CPU name from the two vendors this app supports. A name that does not start with a vendor is not a CPU name we can group by.' }
        [pscustomobject]@{ Name = 'Gpu'; Kind = 'String'
            Pattern = '^(NVIDIA|AMD|Intel)[0-9A-Za-z.\-+()/ ]{2,80}$'; MaxLength = 80
            Why = 'the same for the GPU: one of the three vendors whose cards this app grades, so a made-up card name cannot become a row on the site.' }
        [pscustomobject]@{ Name = 'DisplayLayout'; Kind = 'Enum'
            Allowed = @('Single', 'Multi', 'Surround', 'Unknown')
            Why = 'the three layouts the app grades, plus Unknown for a reading it could not take.' }
        [pscustomobject]@{ Name = 'GapFailCount'; Kind = 'Number'; Min = 0; Max = 200
            Why = 'how many rows failed. A number, bounded, because the site draws it.' }
        [pscustomobject]@{ Name = 'GapTotalCount'; Kind = 'Number'; Min = 0; Max = 500
            Why = 'how many rows there were, bounded the same way: the site draws the pair as a ratio and a ratio needs both sides to be real.' }
        [pscustomobject]@{ Name = 'ScoreWorstFrameMs'; Kind = 'Number'; Min = 0; Max = 10000
            Why = 'worst frame time in milliseconds. 10 s is absurd and still finite, which is the point of a range.' }
        [pscustomobject]@{ Name = 'ScoreStallsPer100s'; Kind = 'Number'; Min = 0; Max = 1000
            Why = 'stalls per 100 seconds, the number the site compares between rigs. Bounded because a score is a measurement, not an opinion.' }
    )
}

function Get-SimRigPublishField {
    <#
        .SYNOPSIS
        One named field from parsed JSON, whether it arrived as a hashtable or an object.
        $null when absent.

        .DESCRIPTION
        ConvertFrom-Json gives objects; -AsHashtable gives hashtables; a hostile body
        gives whatever it likes. Reading a missing property under Set-StrictMode throws,
        so every read goes through here.

        Pure.

        .OUTPUTS
        [object] or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()] $Document,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $Document) { return $null }
    if ($Document -is [System.Collections.IDictionary]) {
        foreach ($key in $Document.Keys) { if ([string]$key -eq $Name) { return $Document[$key] } }
        return $null
    }
    if ($Document -is [System.Management.Automation.PSCustomObject] -or $Document -is [psobject]) {
        $property = $Document.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        return $property.Value
    }
    return $null
}

function Test-SimRigPublishValue {
    <#
        .SYNOPSIS
        Whether one value matches one rule. True or false, and never an exception.

        .DESCRIPTION
        A rule is a shape (see Get-SimRigPublishFieldRule). This is the only place that
        compares a value to one, so "how do we check a field" has one answer.

        Pure.

        .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Rule,
        [AllowNull()] $Value
    )

    if ($null -eq $Value) { return $false }

    switch ([string]$Rule.Kind) {
        'Enum' {
            return (@($Rule.Allowed) -contains [string]$Value)
        }
        'Number' {
            # A string that looks like a number is not a number. The app writes numbers;
            # a string here means something rewrote the payload.
            if ($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [double] -and $Value -isnot [decimal]) { return $false }
            $number = [double]$Value
            if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $false }
            return ($number -ge [double]$Rule.Min -and $number -le [double]$Rule.Max)
        }
        'String' {
            if ($Value -isnot [string]) { return $false }
            if ($Value.Length -gt [int]$Rule.MaxLength) { return $false }
            # -match on the whole string: the patterns are anchored, and an unanchored
            # pattern here would pass anything with a good substring in it.
            return [bool]([regex]::IsMatch($Value, [string]$Rule.Pattern))
        }
        default { return $false }
    }
}

function Get-SimRigPublishVerdict {
    <#
        .SYNOPSIS
        Whether a report body may be published, and the row to publish if it may.

        .DESCRIPTION
        The order is the requirement: size, then parse, then shape, then every field.
        Each step refuses with a sentence a human can act on, and the first refusal
        stops the rest - a 1 MB body is not worth parsing to find out its CPU name.

        Unknown top-level fields are a refusal, not something to ignore. A report
        carrying a field this app never wrote was written by something else, and the
        polite reading of that is "not a report from this app".

        Pure.

        .OUTPUTS
        [pscustomobject] Ok, Reason, Finding [string[]], Row (or $null).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $PayloadText,
        [int] $IssueNumber = 0
    )

    $finding = [System.Collections.Generic.List[string]]::new()
    $refuse = {
        param($Reason)
        [pscustomobject]@{ Ok = $false; Reason = $Reason; Finding = @($finding); Row = $null }
    }

    if ([string]::IsNullOrWhiteSpace($PayloadText)) {
        return (& $refuse 'The issue has no report JSON in it. The app copies the report to the clipboard; paste it into the report field of the form.')
    }

    $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($PayloadText)
    if ($byteCount -gt (Get-SimRigPublishPayloadCap)) {
        return (& $refuse ("The report is {0} bytes and the limit is {1}. A real report is a few KB, so this one is not one." -f $byteCount, (Get-SimRigPublishPayloadCap)))
    }

    $document = $null
    try { $document = $PayloadText | ConvertFrom-Json -ErrorAction Stop }
    catch { return (& $refuse ('The report field is not valid JSON: {0}' -f ($_.Exception.Message -split "`n")[0])) }

    if ($null -eq $document -or $document -is [array] -or $document -is [string] -or $document -is [bool] -or $document -is [double]) {
        return (& $refuse 'The report field parses, but it is not a JSON object.')
    }

    # Every top-level name this app writes. Anything else is a refusal.
    $known = @('Schema', 'TakenAt', 'AppVersion', 'ProfileId', 'RuleVersion', 'Hardware', 'Machine', 'Gap', 'Score', 'Note')
    $present = @(if ($document -is [System.Collections.IDictionary]) { @($document.Keys | ForEach-Object { [string]$_ }) }
        else { @($document.PSObject.Properties | ForEach-Object { $_.Name }) })
    $unknown = @($present | Where-Object { $known -notcontains $_ })
    if ($unknown.Count -gt 0) {
        return (& $refuse ('The report carries {0} field(s) this app never writes: {1}. Nothing was published.' -f $unknown.Count, ($unknown -join ', ')))
    }

    $rules = @{}
    foreach ($rule in @(Get-SimRigPublishFieldRule)) { $rules[$rule.Name] = $rule }

    # Top-level strings and the schema.
    foreach ($name in 'Schema', 'TakenAt', 'AppVersion', 'Hardware') {
        $value = Get-SimRigPublishField -Document $document -Name $name
        if (-not (Test-SimRigPublishValue -Rule $rules[$name] -Value $value)) {
            $finding.Add(('{0}: not a value this app writes ({1})' -f $name, $rules[$name].Why))
        }
    }
    # Optional, and checked when present.
    foreach ($name in 'ProfileId', 'RuleVersion', 'Note') {
        $value = Get-SimRigPublishField -Document $document -Name $name
        if ($null -eq $value -or ($value -is [string] -and $value.Length -eq 0)) { continue }
        if (-not (Test-SimRigPublishValue -Rule $rules[$name] -Value $value)) {
            $finding.Add(('{0}: not a value this app writes ({1})' -f $name, $rules[$name].Why))
        }
    }

    $machine = Get-SimRigPublishField -Document $document -Name 'Machine'
    $cpuBlock = Get-SimRigPublishField -Document $machine -Name 'Cpu'
    $gpuBlock = Get-SimRigPublishField -Document $machine -Name 'Gpu'
    $displayBlock = Get-SimRigPublishField -Document $machine -Name 'Display'

    $cpu = [string](Get-SimRigPublishField -Document $cpuBlock -Name 'ProcessorName')
    $gpu = [string](Get-SimRigPublishField -Document $gpuBlock -Name 'Name')
    $layout = [string](Get-SimRigPublishField -Document $displayBlock -Name 'Layout')
    if ([string]::IsNullOrWhiteSpace($layout)) { $layout = 'Unknown' }

    if (-not (Test-SimRigPublishValue -Rule $rules['Cpu'] -Value $cpu)) { $finding.Add(('Machine.Cpu.ProcessorName: {0}' -f $rules['Cpu'].Why)) }
    if (-not (Test-SimRigPublishValue -Rule $rules['Gpu'] -Value $gpu)) { $finding.Add(('Machine.Gpu.Name: {0}' -f $rules['Gpu'].Why)) }
    if (-not (Test-SimRigPublishValue -Rule $rules['DisplayLayout'] -Value $layout)) { $finding.Add(('Machine.Display.Layout: {0}' -f $rules['DisplayLayout'].Why)) }

    $gapRows = @(Get-SimRigPublishField -Document $document -Name 'Gap')
    $failCount = @($gapRows | Where-Object { [string](Get-SimRigPublishField -Document $_ -Name 'Verdict') -eq 'Fail' }).Count
    $totalCount = @($gapRows).Count
    if (-not (Test-SimRigPublishValue -Rule $rules['GapFailCount'] -Value $failCount)) { $finding.Add('Gap: more failed rows than a real report has') }
    if (-not (Test-SimRigPublishValue -Rule $rules['GapTotalCount'] -Value $totalCount)) { $finding.Add('Gap: more rows than a real report has') }

    if ($finding.Count -gt 0) {
        return (& $refuse ('{0} field(s) in the report are not values this app writes, so nothing was published.' -f $finding.Count))
    }

    $row = ConvertTo-SimRigPublishRow -Document $document -IssueNumber $IssueNumber -Cpu $cpu -Gpu $gpu -Layout $layout -GapFail $failCount -GapTotal $totalCount
    return [pscustomobject]@{ Ok = $true; Reason = 'Every field matched its rule.'; Finding = @(); Row = $row }
}

function ConvertTo-SimRigPublishRow {
    <#
        .SYNOPSIS
        The results.json row, built from validated values only.

        .DESCRIPTION
        Nothing here copies the payload. Every value is one that Get-SimRigPublishVerdict
        already matched against a rule, and a field that is not in this function is a
        field the site never sees - which is the only way to be sure of that.

        Pure.

        .OUTPUTS
        [pscustomobject] the row.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] $Document,
        [int] $IssueNumber,
        [AllowNull()] [string] $Cpu,
        [AllowNull()] [string] $Gpu,
        [AllowNull()] [string] $Layout,
        [int] $GapFail,
        [int] $GapTotal
    )

    $note = [string](Get-SimRigPublishField -Document $Document -Name 'Note')
    return [pscustomobject]@{
        Schema        = 'simrig.results-row/1'
        Issue         = $IssueNumber
        TakenAt       = [string](Get-SimRigPublishField -Document $Document -Name 'TakenAt')
        AppVersion    = [string](Get-SimRigPublishField -Document $Document -Name 'AppVersion')
        Hardware      = [string](Get-SimRigPublishField -Document $Document -Name 'Hardware')
        Cpu           = [string]$Cpu
        Gpu           = [string]$Gpu
        DisplayLayout = [string]$Layout
        GapFailCount  = [int]$GapFail
        GapTotalCount = [int]$GapTotal
        Note          = $note
    }
}

function Add-SimRigPublishRow {
    <#
        .SYNOPSIS
        A row into the results list: newest first, one row per issue, capped.

        .DESCRIPTION
        One row per issue number, because a re-approved issue is a correction and not a
        second rig. Newest first is what the site shows. The cap keeps the file a page
        can load; the oldest rows fall off the end and the site says how many it holds.

        Pure.

        .OUTPUTS
        [object[]] the new list.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Existing,
        [Parameter(Mandatory)] $Row,
        [int] $Cap = 0
    )

    if ($Cap -le 0) { $Cap = $script:SimRigPublishRowCap }
    $keep = [System.Collections.Generic.List[object]]::new()
    $keep.Add($Row)
    foreach ($old in @($Existing | Where-Object { $null -ne $_ })) {
        if ([int](Get-SimRigPublishField -Document $old -Name 'Issue') -eq [int]$Row.Issue) { continue }
        $keep.Add($old)
    }
    if ($keep.Count -gt $Cap) { return @($keep[0..($Cap - 1)]) }
    return @($keep)
}

function Get-SimRigPublishComment {
    <#
        .SYNOPSIS
        The comment the Action leaves on the issue, with every @ escaped.

        .DESCRIPTION
        A bot comment that repeats a hostile string can notify people: '@everyone' in a
        Note would become a mention written by us, and the people notified would have no
        idea why. So every at-sign in the finished comment is wrapped in backticks, which
        GitHub renders as code and does not resolve as a mention (flag 9: "Bot comments
        escape @"). It happens last, over the whole text, so a line added above cannot
        skip it.

        The comment also never repeats the payload. It says what happened and names the
        fields, because a refusal nobody can act on gets ignored.

        Pure.

        .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Verdict,
        [AllowNull()] [string] $Prefix = 'SimRig results'
    )

    $line = [System.Collections.Generic.List[string]]::new()
    if ($Verdict.Ok) {
        $line.Add(('**{0}:** published.' -f $Prefix))
        $line.Add('')
        $line.Add(('Hardware: `{0}`' -f $Verdict.Row.Hardware))
        $line.Add(('Failed rows: {0} of {1}' -f $Verdict.Row.GapFailCount, $Verdict.Row.GapTotalCount))
    }
    else {
        $line.Add(('**{0}:** nothing was published.' -f $Prefix))
        $line.Add('')
        $line.Add([string]$Verdict.Reason)
        foreach ($one in @($Verdict.Finding)) { $line.Add(('- {0}' -f $one)) }
    }
    $text = ($line -join "`n")
    # Every at-sign, wherever it came from, wrapped in code so GitHub does not read it
    # as a mention. Done last, over the whole comment, so a field added above cannot
    # skip it.
    return ($text -replace '@', '`@`')
}
