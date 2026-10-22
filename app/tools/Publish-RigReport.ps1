<#
    Publish-RigReport.ps1 - unit U4.3 (flag 9). The impure half of the results publisher.

    It reads a GitHub issue event from a file, asks engine/Engine.Publish.ps1 whether the
    report in it may be published, and - only then - writes the row into the site's
    results.json and a comment for the workflow to post.

    Every decision is in the engine, which is pure and tested against the bodies a
    stranger can send. This file does the three things a pure function cannot: read the
    event file, write two files, and set an exit code.

    What it never does, and the reason:

    - It never interpolates user text into a command. It is handed a path and reads it as
      data (flag 9: "No user text inside a run: line").
    - It does not fetch anything. The report arrives in the issue body; there is no URL
      to follow and no download to trust.
    - It does not ask GitHub who the sender is. The workflow does that with its own token
      and passes the answer in -Permission, so this script stays runnable on a laptop
      with no network and no secrets.

    Exit codes, because the workflow branches on them:
      0  published (or would have been, with -WhatIf)
      1  not this Action's business (wrong action, wrong label) - not a failure
      2  refused: the report is not a report this app wrote
      3  refused: the sender may not approve
      4  usage error (a path that is not there)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # The event JSON. In CI this is $env:GITHUB_EVENT_PATH.
    [Parameter(Mandatory)] [string] $EventPath,

    # The site's results file. Created if it does not exist.
    [Parameter(Mandatory)] [string] $ResultsPath,

    # What the sender may do in this repo, as the API reports it: admin, maintain, write,
    # triage, read or none. The workflow reads it; this script grades it.
    [AllowNull()] [string] $Permission,

    # Where to write the comment body for the workflow to post. Optional: without it the
    # comment is printed and nothing is written.
    [AllowNull()] [string] $CommentPath,

    # How many rows results.json keeps.
    [int] $RowCap = 500
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Path $PSScriptRoot -Parent
. (Join-Path -Path $root -ChildPath 'SimRig.Engine.ps1')
. (Join-Path -Path $root -ChildPath 'engine/Engine.Publish.ps1')

function Write-PublishLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    Write-Output ('Publish-RigReport: {0}' -f $Text)
}

if (-not (Test-Path -LiteralPath $EventPath -PathType Leaf)) {
    Write-PublishLine -Text ('no event file at {0}' -f $EventPath)
    exit 4
}

$eventDocument = $null
try { $eventDocument = (Get-Content -LiteralPath $EventPath -Raw) | ConvertFrom-Json -ErrorAction Stop }
catch {
    Write-PublishLine -Text ('the event file is not valid JSON: {0}' -f ($_.Exception.Message -split "`n")[0])
    exit 4
}

# Read as data, field by field, with the same helper the engine uses - a missing property
# under StrictMode throws, and an event from a trigger we did not expect is missing plenty.
$action = [string](Get-SimRigPublishField -Document $eventDocument -Name 'action')
$issue = Get-SimRigPublishField -Document $eventDocument -Name 'issue'
$label = Get-SimRigPublishField -Document $eventDocument -Name 'label'
$labelName = [string](Get-SimRigPublishField -Document $label -Name 'name')
$issueNumber = [int](Get-SimRigPublishField -Document $issue -Name 'number')
$body = [string](Get-SimRigPublishField -Document $issue -Name 'body')

$eventVerdict = Get-SimRigPublishEventVerdict -Action $action -LabelName $labelName -Permission $Permission
Write-PublishLine -Text ('event: action={0} label={1} issue=#{2} permission={3} -> {4}' -f `
        $action, $labelName, $issueNumber, $(if ($Permission) { $Permission } else { 'none' }), $eventVerdict.Verdict)

if (-not $eventVerdict.Ok) {
    Write-PublishLine -Text $eventVerdict.Reason
    # A comment is written only for a refusal, never for an event that was not ours: a bot
    # that comments on every label is a bot people mute.
    if ($eventVerdict.Verdict -eq 'Refuse') {
        $text = Get-SimRigPublishComment -Verdict ([pscustomobject]@{ Ok = $false; Reason = $eventVerdict.Reason; Finding = @(); Row = $null })
        if ($CommentPath) { Set-Content -LiteralPath $CommentPath -Value $text -Encoding UTF8 }
        else { Write-Output $text }
        exit 3
    }
    exit 1
}

$payload = Get-SimRigPublishPayloadText -Body $body
$verdict = Get-SimRigPublishVerdict -PayloadText $payload -IssueNumber $issueNumber
$comment = Get-SimRigPublishComment -Verdict $verdict
if ($CommentPath) { Set-Content -LiteralPath $CommentPath -Value $comment -Encoding UTF8 }

if (-not $verdict.Ok) {
    Write-PublishLine -Text ('refused: {0}' -f $verdict.Reason)
    foreach ($one in @($verdict.Finding)) { Write-PublishLine -Text ('  {0}' -f $one) }
    if (-not $CommentPath) { Write-Output $comment }
    exit 2
}

# Read the existing file, if there is one. A results.json this script cannot read is not
# overwritten: that would turn one bad write into a lost file.
$existingRow = @()
if (Test-Path -LiteralPath $ResultsPath -PathType Leaf) {
    try {
        $existing = (Get-Content -LiteralPath $ResultsPath -Raw) | ConvertFrom-Json -ErrorAction Stop
        $existingRow = @(Get-SimRigPublishField -Document $existing -Name 'Row')
    }
    catch {
        Write-PublishLine -Text ('{0} exists and is not readable as JSON, so nothing was written: {1}' -f $ResultsPath, ($_.Exception.Message -split "`n")[0])
        exit 4
    }
}

$row = @(Add-SimRigPublishRow -Existing $existingRow -Row $verdict.Row -Cap $RowCap)
$document = [ordered]@{
    Schema = 'simrig.results/1'
    Count  = $row.Count
    Row    = $row
}
$json = ($document | ConvertTo-Json -Depth 6)

if ($PSCmdlet.ShouldProcess($ResultsPath, ('write {0} row(s)' -f $row.Count))) {
    $directory = Split-Path -Path $ResultsPath -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    # Temp file then move: a half-written results.json is a broken site, and the site is
    # the one file every reader sees.
    $temp = '{0}.tmp' -f $ResultsPath
    Set-Content -LiteralPath $temp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $ResultsPath -Force
}

Write-PublishLine -Text ('published issue #{0}: {1} ({2} row(s) in the file)' -f $issueNumber, $verdict.Row.Hardware, $row.Count)
exit 0
