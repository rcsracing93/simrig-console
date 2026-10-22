<#
    New-SimRigLabel.ps1 - the issue labels this project's workflows depend on (U4.5).

    Six labels, each one load-bearing:

      bug, rig-report, beta-tester, question   the issue forms apply these
      approved                                 the results workflow publishes on this one
      needs-bundle                             a maintainer asks for the log this way

    Why a script and not a hand-made list: `approved` is the label that puts text on a
    public site (flag 9). A label that somebody made by hand, with a slightly different
    name or a different case, is a label the workflow does not recognise - and a rig report
    that never publishes for a reason nobody can see. The names live here, next to the
    workflow that reads them, and this script makes them match.

    It prints what it would do and changes nothing unless you pass -Apply. Creating labels
    in a public repository is a repository change, and those are Rick's to approve.

    Exit codes: 0 fine, 2 gh missing or not logged in, 3 a label could not be written.
#>
[CmdletBinding()]
param(
    # Not Mandatory on purpose: the tests dot-source this file to read
    # Get-SimRigLabelDefinition, and a mandatory parameter would prompt for a value that a
    # test run has no way to answer. Missing is checked below, where it can say so.
    [string] $Repository = '',
    [switch] $Apply
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-SimRigLabelDefinition {
    <#
        .SYNOPSIS
        The six labels: name, colour, and what applying it means.

        .OUTPUTS
        [object[]] Name, Color, Description.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    return @(
        [pscustomobject]@{ Name = 'bug'; Color = 'd73a4a'
            Description = 'Something the console did wrong. The log bundle is what makes it actionable.' }
        [pscustomobject]@{ Name = 'rig-report'; Color = '0e8a16'
            Description = 'A shared report from someone else PC, waiting to be read.' }
        [pscustomobject]@{ Name = 'beta-tester'; Color = '5319e7'
            Description = 'An offer to test a pre-release. A 7950X or 9950X closes the dual-CCD question.' }
        [pscustomobject]@{ Name = 'question'; Color = '0075ca'
            Description = 'A question the pages do not answer yet - which usually means a page needs a line.' }
        [pscustomobject]@{ Name = 'approved'; Color = 'fbca04'
            Description = 'Publishes a rig report to the results table. Only admin or maintain may add it, and an edit to the issue removes it.' }
        [pscustomobject]@{ Name = 'needs-bundle'; Color = 'fef2c0'
            Description = 'Waiting for the log bundle from C:\SimRacer\Logs\v4.' }
    )
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ([string]::IsNullOrWhiteSpace($Repository)) {
    Write-Output 'New-SimRigLabel: pass -Repository <owner>/<name>. Nothing was read or written.'
    exit 4
}

$gh = Get-Command -Name 'gh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $gh) {
    Write-Output 'New-SimRigLabel: the GitHub CLI (gh) is not on PATH, so nothing can be read or written.'
    exit 2
}

Write-Output ('New-SimRigLabel: {0} label(s) for {1}{2}' -f `
    @(Get-SimRigLabelDefinition).Count, $Repository, $(if ($Apply) { '' } else { ' (dry run - pass -Apply to write)' }))

$existing = @()
try {
    $listed = & $gh.Source 'label' 'list' '--repo' $Repository '--limit' '200' '--json' 'name' 2>$null
    if ($LASTEXITCODE -eq 0 -and $listed) { $existing = @(($listed | ConvertFrom-Json) | ForEach-Object { [string]$_.name }) }
}
catch { $existing = @() }

$failed = 0
foreach ($label in @(Get-SimRigLabelDefinition)) {
    $have = $existing -contains $label.Name
    $verb = if ($have) { 'update' } else { 'create' }
    Write-Output ('  {0,-8} {1,-14} #{2}  {3}' -f $verb, $label.Name, $label.Color, $label.Description)
    if (-not $Apply) { continue }
    # --force turns create into upsert, so running this twice is not an error and a colour
    # or description fixed here reaches the repo.
    & $gh.Source 'label' 'create' $label.Name '--repo' $Repository '--color' $label.Color `
        '--description' $label.Description '--force' 2>&1 | ForEach-Object { Write-Output ('    {0}' -f $_) }
    if ($LASTEXITCODE -ne 0) { $failed++ }
}

if ($failed -gt 0) {
    Write-Output ('New-SimRigLabel: {0} label(s) could not be written.' -f $failed)
    exit 3
}
if (-not $Apply) { Write-Output 'New-SimRigLabel: nothing was changed.' }
exit 0
