#requires -Version 7.0
<#
    New-SimRigManifest.ps1 - writes the SHA256SUMS file Setup.cmd verifies before
    it copies anything.

    Why this exists. Install-SimRig.ps1 refuses outright when SHA256SUMS is not in
    the folder ('Setup copies nothing it cannot verify first'), and nothing in this
    build produced one. The v4.0 path staged files to Z: by hand, so the manifest
    was whatever happened to be there. That is exactly the gap that lets a
    half-extracted or half-copied folder install.

    One writer, three callers: the tier B workflow before its install job, the
    release workflow when it builds the zip, and a person staging a folder by hand.
    A second copy of this logic is how the manifest and the verifier start
    disagreeing.

    The file list comes from the engine (Get-SimRigShipItem), not from a glob, for
    the same reason the installer's does: a glob would quietly include whatever
    else is sitting in the folder, and the console's integrity check compares
    against a named list.

        pwsh -File tools/New-SimRigManifest.ps1 -SourcePath . -Version 4.2.0-beta.1

    Exit codes: 0 written, 2 bad argument, 4 a file in the list is missing.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # The folder to hash. Every path in the manifest is relative to it, with '/'
    # separators, so the same manifest reads the same on any machine.
    [Parameter(Mandatory)] [string] $SourcePath,

    # Written as a comment line at the top. The installer's parser skips comment
    # lines, so this costs nothing and tells a person what they are holding.
    [string] $Version = '',

    # Where to write. Defaults to SHA256SUMS inside -SourcePath, which is where
    # Setup.cmd looks.
    [string] $OutputPath = '',

    # The commit these files came from, for VERSIONS.md's Commit: line. The About
    # screen shows it and the Push report carries it, so a bundle can be tied back to
    # a build.
    [string] $Commit = '',

    # VERSIONS.md as well as SHA256SUMS. The console's preflight compares its own
    # files against VERSIONS.md ("Script integrity"), and it was not in the folder
    # either - so the check had nothing to compare against. One writer for both,
    # because two writers is how a manifest and an integrity file start disagreeing.
    [switch] $SkipVersionsFile
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'engine/Engine.Install.ps1')

if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    Write-Output ("New-SimRigManifest: -SourcePath is not a folder: {0}" -f $SourcePath)
    exit 2
}

$root = (Resolve-Path -LiteralPath $SourcePath).Path
$manifestName = Get-SimRigHashManifestName
$out = if ($OutputPath) { $OutputPath } else { Join-Path -Path $root -ChildPath $manifestName }

$ship = Get-SimRigShipItem

# Neither generated file is listed: the manifest cannot contain its own hash, and
# VERSIONS.md is written by this script a few lines below - listing it would make a
# clean stage fail with "missing" before the file it wants exists. The installer's
# verdict skips both for the same reason.
$generated = @($manifestName, 'VERSIONS.md')
$wanted = [System.Collections.Generic.List[string]]::new()
foreach ($name in @($ship.File)) {
    if ($generated -contains $name) { continue }
    $wanted.Add($name)
}
foreach ($dir in @($ship.Directory)) {
    $dirPath = Join-Path -Path $root -ChildPath $dir
    if (-not (Test-Path -LiteralPath $dirPath)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $dirPath -File -Recurse | Sort-Object -Property FullName) {
        $wanted.Add(($file.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'))
    }
}

$missing = [System.Collections.Generic.List[string]]::new()
$line = [System.Collections.Generic.List[string]]::new()
if ($Version) { $line.Add(('# SimRig Console {0}' -f $Version)) }

foreach ($relative in $wanted) {
    $full = Join-Path -Path $root -ChildPath ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $missing.Add($relative)
        continue
    }
    $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToUpperInvariant()
    # Two spaces and a forward-slash path: the form sha256sum writes, and the form
    # ConvertFrom-SimRigHashManifestLine reads.
    $line.Add(('{0}  {1}' -f $hash, $relative))
}

if ($missing.Count -gt 0) {
    Write-Output ("New-SimRigManifest: {0} file(s) in the ship list are not in {1}:" -f $missing.Count, $root)
    foreach ($m in $missing) { Write-Output ("  missing: {0}" -f $m) }
    Write-Output 'Nothing was written. A manifest that skips a missing file would let a half-extracted folder install.'
    exit 4
}

if ($PSCmdlet.ShouldProcess($out, 'write SHA256SUMS')) {
    Set-Content -LiteralPath $out -Value $line -Encoding UTF8
}
Write-Output ("New-SimRigManifest: {0} file(s) -> {1}" -f (@($line).Count - $(if ($Version) { 1 } else { 0 })), $out)

if (-not $SkipVersionsFile) {
    # VERSIONS.md: the same hash lines with a Version: and Commit: header. The
    # console reads the header for the About screen and the hash lines for the
    # integrity check, and ConvertFrom-VersionsText skips anything that is not a
    # hash line - so the header costs nothing.
    $versionsPath = Join-Path -Path $root -ChildPath 'VERSIONS.md'
    $versionsLine = [System.Collections.Generic.List[string]]::new()
    $versionsLine.Add('# SimRig Console v4 - file versions')
    $versionsLine.Add('')
    $versionsLine.Add(('Version: {0}' -f $(if ($Version) { $Version } else { 'unknown' })))
    $versionsLine.Add(('Commit: {0}' -f $(if ($Commit) { $Commit } else { 'unknown' })))
    $versionsLine.Add('')
    $versionsLine.Add('The console compares its own files against the hashes below at startup')
    $versionsLine.Add('("Script integrity" in preflight). A line that does not match means the file')
    $versionsLine.Add('on disk is not the file that shipped.')
    $versionsLine.Add('')
    foreach ($text in $line) {
        if ($text -match '^[0-9A-Fa-f]{64}  ') { $versionsLine.Add($text) }
    }
    if ($PSCmdlet.ShouldProcess($versionsPath, 'write VERSIONS.md')) {
        Set-Content -LiteralPath $versionsPath -Value $versionsLine -Encoding UTF8
    }
    Write-Output ("New-SimRigManifest: VERSIONS.md -> {0}" -f $versionsPath)
}
exit 0
