<#
    Install-SimRig.ps1 - SimRig Console v4.2 installer. Unit U3.11.

    This replaces Install-SimRigV4.ps1 (v4.0, a 30-line copy loop). The old
    file is left in place until the lead switches over.

    Run it through Setup.cmd, which is the double-click entry point:
        Setup.cmd                 install or upgrade in place
        Setup.cmd /uninstall      remove the program, shortcuts and deadman task

    Shape: this file is the ACTIONS half only. Every decision it makes -
    whether the folder it was started from is a temp or zip path, whether
    SHA256SUMS matches, whether a session is open, fresh install or upgrade,
    which prerequisites are missing, whether the ACL stops a standard user
    writing, what /uninstall removes and keeps - comes from pure functions in
    engine/Engine.Install.ps1, which the Pester suite tests on Linux
    (tests/Install.Tests.ps1, A-INST). Nothing is decided twice.

    Exit codes (Get-SimRigInstallExitCode, the same table as the elevated
    child's Get-ActionExitCode): 0 done, 1 a step failed, 2 bad argument,
    3 refused, 4 fatal.

    What only real Windows can prove: the ACL actually applied, the shortcuts
    actually created, winget actually installing, the scheduled task actually
    removed. Those are B-INST-01 to B-INST-03 in tier B.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Setup.cmd forwards whatever the user typed, including /uninstall, which
    # is not PowerShell parameter syntax - so it is caught here.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $PassThroughArgument = @(),

    [string] $SourcePath = $PSScriptRoot,
    [string] $InstallRoot = '',
    [string] $DataRoot = '',
    [string] $SessionRoot = 'C:\SimRacer',
    [string] $PackageVersion = '',
    [switch] $Uninstall,
    [switch] $RemoveData,
    [switch] $SkipPrerequisiteInstall
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Load the decisions. Two engine part files only: the installer must run on a
# machine where the app has never started, so it does not pull in the console.
# --------------------------------------------------------------------------
. (Join-Path -Path $PSScriptRoot -ChildPath 'engine/Engine.Settings.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'engine/Engine.Install.ps1')

$code = Get-SimRigInstallExitCode

function Write-SetupLine {
    <#
        .SYNOPSIS
        One line of user-visible output, through the output stream so the
        tier B workflow can capture it. No host-only writer is used anywhere
        in v4 (CONTRACT.md).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    Write-Output -InputObject $Text
}

function Get-SetupIsElevated {
    <#
        .SYNOPSIS
        True when this process can write to %ProgramFiles% and set an ACL.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SetupInstalledPwshVersion {
    <#
        .SYNOPSIS
        The version of the pwsh already on the machine, or '' when there is
        none. Read by asking pwsh itself, because the installer may be running
        under Windows PowerShell 5.1 from the Setup.cmd fallback.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $command = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) { return '' }
    try {
        $reported = & $command.Source -NoProfile -NoLogo -Command '$PSVersionTable.PSVersion.ToString()'
        return ([string]($reported | Select-Object -First 1)).Trim()
    }
    catch {
        Write-SetupLine -Text ('Could not ask pwsh for its version ({0}); treating it as not installed.' -f $_.Exception.Message)
        return ''
    }
}

function Get-SetupDesktopRuntimeVersion {
    <#
        .SYNOPSIS
        The installed Microsoft.WindowsDesktop.App versions, from
        'dotnet --list-runtimes'. The parsing is the engine's.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $command = Get-Command -Name 'dotnet' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) { return , @() }
    try {
        $line = @(& $command.Source '--list-runtimes' 2>$null)
    }
    catch {
        Write-SetupLine -Text ('Could not run dotnet --list-runtimes ({0}); treating the runtime as not installed.' -f $_.Exception.Message)
        return , @()
    }
    $parsed = ConvertFrom-SimRigDotnetRuntimeLine -Line $line -RuntimeName 'Microsoft.WindowsDesktop.App'
    return , $parsed
}

function Install-SetupPrerequisite {
    <#
        .SYNOPSIS
        Hands each missing prerequisite to winget with exactly the flags the
        engine fixes, and nothing else, so the user sees and answers whatever
        winget asks. Never throws: a failure is reported and the refusal gate
        decides.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Missing)
    $winget = Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $winget) {
        Write-SetupLine -Text 'winget is not on this machine, so Setup cannot install the prerequisites for you.'
        return
    }
    foreach ($item in $Missing) {
        $argument = Get-SimRigWingetArgument -PackageId $item.WingetId
        Write-SetupLine -Text ('Installing {0}: {1}' -f $item.Name, (Get-SimRigWingetCommandLine -PackageId $item.WingetId))
        if (-not $PSCmdlet.ShouldProcess($item.WingetId, 'winget install')) { continue }
        try {
            $run = Start-Process -FilePath $winget.Source -ArgumentList $argument -Wait -PassThru -NoNewWindow
            if ($run.ExitCode -ne 0) {
                Write-SetupLine -Text ('winget returned {0} for {1}.' -f $run.ExitCode, $item.WingetId)
            }
        }
        catch {
            Write-SetupLine -Text ('winget could not run for {0}: {1}' -f $item.WingetId, $_.Exception.Message)
        }
    }
}

function Get-SetupActualHash {
    <#
        .SYNOPSIS
        SHA-256 of every file the manifest names, keyed by the manifest's own
        relative path. A file the manifest names but the folder does not hold
        is simply absent from the table, which is what makes the engine report
        a half-extracted zip.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Entry
    )
    $table = @{}
    foreach ($item in $Entry) {
        $relative = ([string]$item.Path).Replace('/', [System.IO.Path]::DirectorySeparatorChar).Replace('\', [System.IO.Path]::DirectorySeparatorChar)
        $full = Join-Path -Path $Root -ChildPath $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $table[$item.Path] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
    }
    return $table
}

function Get-SetupInstalledVersion {
    <#
        .SYNOPSIS
        The version recorded by the last install, from install.json in the
        program folder. '' when there is no readable record, which the engine
        treats as an upgrade rather than a downgrade refusal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Root)
    $marker = Join-Path -Path $Root -ChildPath 'install.json'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return '' }
    try {
        $record = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    }
    catch {
        Write-SetupLine -Text ('install.json could not be read ({0}); treating this as an upgrade.' -f $_.Exception.Message)
        return ''
    }
    if ($record.PSObject.Properties.Match('Version').Count -eq 0) { return '' }
    return [string]$record.Version
}

function Set-SetupInstallAcl {
    <#
        .SYNOPSIS
        Applies the flag 3 ACL to the program folder: Administrators and
        SYSTEM full, Users read and execute, inheritance broken so nothing a
        standard user can write is inherited from %ProgramFiles%.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Root)
    if (-not $PSCmdlet.ShouldProcess($Root, 'set the program-folder ACL')) { return }
    $acl = Get-Acl -LiteralPath $Root
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existing in @($acl.Access)) {
        [void]$acl.RemoveAccessRule($existing)
    }
    $ruleList = Get-SimRigInstallAclRule
    foreach ($rule in $ruleList) {
        $ace = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $rule.Identity,
            [System.Security.AccessControl.FileSystemRights]$rule.Rights,
            [System.Security.AccessControl.InheritanceFlags]$rule.Inheritance,
            [System.Security.AccessControl.PropagationFlags]$rule.Propagation,
            [System.Security.AccessControl.AccessControlType]$rule.Type)
        $acl.AddAccessRule($ace)
    }
    Set-Acl -LiteralPath $Root -AclObject $acl
    Write-SetupLine -Text ('Permissions set on {0}: Administrators and SYSTEM full, Users read and execute.' -f $Root)
}

function Test-SetupInstallAcl {
    <#
        .SYNOPSIS
        Reads the ACL back and asks the engine whether a standard user could
        still write there. The console's preflight asks the same question of
        its own install root (flag 3).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Root)
    $ace = @(Get-Acl -LiteralPath $Root | Select-Object -ExpandProperty Access | ForEach-Object {
            [pscustomobject]@{
                Identity = [string]$_.IdentityReference
                Rights   = [string]$_.FileSystemRights
                Type     = [string]$_.AccessControlType
            }
        })
    $verdict = Get-SimRigInstallAclVerdict -Ace $ace
    if (-not $verdict.IsSafe) {
        Write-SetupLine -Text ('The program folder is still writable by: {0}. The console will refuse to run from it.' -f (@($verdict.Offender) -join ', '))
    }
    return $verdict.IsSafe
}

function New-SetupShortcut {
    <#
        .SYNOPSIS
        Creates the two desktop shortcuts from the engine's plan. Neither is
        "Run as administrator": the RunAsAdministrator byte in the .lnk is
        left unset, which is what the engine records and what the console
        needs (it runs unelevated and elevates one child per action).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $PwshPath
    )
    $desktop = [System.Environment]::GetFolderPath('Desktop')
    $shell = New-Object -ComObject WScript.Shell
    $plan = Get-SimRigInstallShortcut -InstallRoot $Root -DesktopPath $desktop -PwshPath $PwshPath
    foreach ($item in $plan) {
        if (-not $PSCmdlet.ShouldProcess($item.LinkPath, 'create desktop shortcut')) { continue }
        $link = $shell.CreateShortcut($item.LinkPath)
        $link.TargetPath = $item.TargetPath
        $link.Arguments = $item.Argument
        $link.WorkingDirectory = $item.WorkingDirectory
        $link.WindowStyle = $item.WindowStyle
        if ($item.PSObject.Properties.Name -contains 'IconLocation' -and $item.IconLocation) {
            $link.IconLocation = $item.IconLocation
        }
        $link.Save()
        Write-SetupLine -Text ('Shortcut: {0}' -f $item.LinkPath)
    }
}

function Remove-SetupInstall {
    <#
        .SYNOPSIS
        /uninstall. Removes what the engine's plan lists and nothing else, then
        prints what it kept. Session history, settings, profiles and logs are
        the user's, so they stay unless -RemoveData is given AND the user says
        yes at the prompt (flag 16: ask before deleting sessions and logs).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Data,
        [Parameter(Mandatory)] [string] $Session,
        [Parameter(Mandatory)] [bool] $AlsoRemoveData
    )
    $desktop = [System.Environment]::GetFolderPath('Desktop')
    $marker = Join-Path -Path (Join-Path -Path $Session -ChildPath 'Logs') -ChildPath 'v4/active-session.json'
    $plan = Get-SimRigUninstallPlan -InstallRoot $Root -DesktopPath $desktop -DataRoot $Data `
        -SessionRoot $Session -IsSessionActive (Test-Path -LiteralPath $marker -PathType Leaf)
    if ($plan.IsRefusal) {
        Write-SetupLine -Text $plan.Message
        return $code.Refused
    }
    foreach ($link in @($plan.RemoveShortcut)) {
        if (-not (Test-Path -LiteralPath $link -PathType Leaf)) { continue }
        if (-not $PSCmdlet.ShouldProcess($link, 'remove shortcut')) { continue }
        Remove-Item -LiteralPath $link -Force
        Write-SetupLine -Text ('Removed shortcut: {0}' -f $link)
    }
    $taskFullName = '{0}{1}' -f $plan.RemoveTaskPath, $plan.RemoveTaskName
    if ($PSCmdlet.ShouldProcess($taskFullName, 'remove the deadman logon task')) {
        try {
            $task = Get-ScheduledTask -TaskPath $plan.RemoveTaskPath -TaskName $plan.RemoveTaskName -ErrorAction SilentlyContinue
            if ($null -ne $task) {
                Unregister-ScheduledTask -TaskPath $plan.RemoveTaskPath -TaskName $plan.RemoveTaskName -Confirm:$false
                Write-SetupLine -Text ('Removed the deadman task {0}.' -f $taskFullName)
            }
            else {
                Write-SetupLine -Text ('No deadman task {0} to remove.' -f $taskFullName)
            }
        }
        catch {
            Write-SetupLine -Text ('The deadman task {0} could not be removed: {1}. Remove it in Task Scheduler.' -f $taskFullName, $_.Exception.Message)
        }
    }
    foreach ($folder in @($plan.RemoveFolder)) {
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        if (-not $PSCmdlet.ShouldProcess($folder, 'remove the program folder')) { continue }
        Remove-Item -LiteralPath $folder -Recurse -Force
        Write-SetupLine -Text ('Removed the program folder: {0}' -f $folder)
    }
    if ($AlsoRemoveData) {
        Write-SetupLine -Text ''
        Write-SetupLine -Text ('This deletes your settings, profiles, logs and every saved session under {0} and {1}.' -f $Data, $Session)
        $answer = Read-Host -Prompt 'Type DELETE to confirm, or press Enter to keep them'
        if ($answer -ceq 'DELETE') {
            foreach ($folder in @($Data)) {
                if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
                if (-not $PSCmdlet.ShouldProcess($folder, 'remove the data folder')) { continue }
                Remove-Item -LiteralPath $folder -Recurse -Force
                Write-SetupLine -Text ('Removed the data folder: {0}' -f $folder)
            }
        }
        else {
            Write-SetupLine -Text 'Nothing was deleted. Your data is still there.'
        }
    }
    Write-SetupLine -Text ''
    Write-SetupLine -Text 'Left alone:'
    foreach ($kept in @($plan.Keep)) { Write-SetupLine -Text ('  {0}' -f $kept) }
    return $code.Done
}

# ==========================================================================
# Main
# ==========================================================================

$wantUninstall = $Uninstall.IsPresent
$wantRemoveData = $RemoveData.IsPresent
foreach ($given in @($PassThroughArgument)) {
    if ([string]::IsNullOrWhiteSpace($given)) { continue }
    $flag = $given.TrimStart('/', '-').ToLowerInvariant()
    switch ($flag) {
        'uninstall' { $wantUninstall = $true }
        'removedata' { $wantRemoveData = $true }
        default {
            Write-SetupLine -Text ('SimRig Setup does not know the option "{0}". It accepts /uninstall only.' -f $given)
            exit $code.BadArgument
        }
    }
}

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $programFiles = [System.Environment]::GetFolderPath('ProgramFiles')
    $InstallRoot = Join-SimRigSettingsPath -Root $programFiles -Child (Get-SimRigInstallFolderName)
}
if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $localAppData = [System.Environment]::GetFolderPath('LocalApplicationData')
    $DataRoot = Join-SimRigSettingsPath -Root $localAppData -Child (Get-SimRigInstallFolderName)
}

if ($wantUninstall) {
    $result = Remove-SetupInstall -Root $InstallRoot -Data $DataRoot -Session $SessionRoot -AlsoRemoveData $wantRemoveData
    exit $result
}

# --- facts ----------------------------------------------------------------

$tempPath = @(
    [System.Environment]::GetEnvironmentVariable('TEMP'),
    [System.Environment]::GetEnvironmentVariable('TMP'),
    (Join-Path -Path ([System.Environment]::GetFolderPath('Windows')) -ChildPath 'Temp')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$markerPath = Join-SimRigSettingsPath -Root $SessionRoot -Child 'Logs\v4\active-session.json'
$isSessionActive = Test-Path -LiteralPath $markerPath -PathType Leaf

$manifestPath = Join-Path -Path $SourcePath -ChildPath (Get-SimRigHashManifestName)
$isManifestPresent = Test-Path -LiteralPath $manifestPath -PathType Leaf
$manifestEntry = @()
$actualHash = @{}
if ($isManifestPresent) {
    $manifestEntry = ConvertFrom-SimRigHashManifestLine -Line @(Get-Content -LiteralPath $manifestPath)
    $actualHash = Get-SetupActualHash -Root $SourcePath -Entry $manifestEntry
}

if ([string]::IsNullOrWhiteSpace($PackageVersion)) {
    # The release workflow (U4.2) is expected to drop a VERSION file beside
    # SHA256SUMS. Without one the version stays '', which the engine reads as
    # "upgrade" rather than inventing a number. See NOTES.md, asks for the lead.
    $versionFile = Join-Path -Path $SourcePath -ChildPath 'VERSION'
    if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
        $PackageVersion = ((Get-Content -LiteralPath $versionFile -Raw) -split "`r?`n" | Select-Object -First 1).Trim()
    }
}

# --- prerequisites, tried once before the gate decides --------------------

$missing = Get-SimRigMissingPrerequisite -PowerShellVersion (Get-SetupInstalledPwshVersion) `
    -DesktopRuntimeVersion (Get-SetupDesktopRuntimeVersion)
if (@($missing).Count -gt 0 -and -not $SkipPrerequisiteInstall) {
    foreach ($item in $missing) {
        Write-SetupLine -Text ('Missing prerequisite: {0} ({1}).' -f $item.Name, $item.Reason)
    }
    Install-SetupPrerequisite -Missing $missing
    $missing = Get-SimRigMissingPrerequisite -PowerShellVersion (Get-SetupInstalledPwshVersion) `
        -DesktopRuntimeVersion (Get-SetupDesktopRuntimeVersion)
}

# --- the one gate ---------------------------------------------------------

$refusal = Get-SimRigInstallRefusal `
    -SourcePath $SourcePath `
    -TempPathList @($tempPath) `
    -ActiveSessionMarkerPath $markerPath `
    -IsSessionActive $isSessionActive `
    -IsManifestPresent $isManifestPresent `
    -ManifestEntry @($manifestEntry) `
    -ActualHash $actualHash `
    -IsElevated (Get-SetupIsElevated) `
    -TargetExists (Test-Path -LiteralPath $InstallRoot -PathType Container) `
    -InstalledVersion (Get-SetupInstalledVersion -Root $InstallRoot) `
    -PackageVersion $PackageVersion `
    -MissingPrerequisite @($missing) `
    -InstallRoot $InstallRoot
if ($null -ne $refusal) {
    Write-SetupLine -Text ''
    Write-SetupLine -Text $refusal.Message
    exit $code.Refused
}

$mode = Get-SimRigInstallMode -TargetExists (Test-Path -LiteralPath $InstallRoot -PathType Container) `
    -InstalledVersion (Get-SetupInstalledVersion -Root $InstallRoot) -PackageVersion $PackageVersion
Write-SetupLine -Text ('{0} SimRig into {1}' -f $mode.Mode, $InstallRoot)

# --- actions --------------------------------------------------------------

$ship = Get-SimRigShipItem
try {
    if ($PSCmdlet.ShouldProcess($InstallRoot, 'create the program folder')) {
        [void](New-Item -ItemType Directory -Path $InstallRoot -Force)
    }
    # An in-place upgrade replaces the four code and data folders whole, so a
    # file dropped in v4.1 and gone in v4.2 does not stay behind and fail the
    # console's integrity check. Nothing the user owns lives here - settings,
    # profiles, logs and sessions are all under the data root.
    foreach ($folder in @($ship.Directory)) {
        $sourceDir = Join-Path -Path $SourcePath -ChildPath $folder
        if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) { continue }
        $targetDir = Join-Path -Path $InstallRoot -ChildPath $folder
        if ((Test-Path -LiteralPath $targetDir -PathType Container) -and $PSCmdlet.ShouldProcess($targetDir, 'replace the folder')) {
            Remove-Item -LiteralPath $targetDir -Recurse -Force
        }
        if (-not $PSCmdlet.ShouldProcess($targetDir, 'copy the folder')) { continue }
        Copy-Item -LiteralPath $sourceDir -Destination $targetDir -Recurse -Force

        # Then check that it actually happened. On 2026-09-29 this exact copy
        # left engine\Engine.Anon.ps1 behind - one file out of sixteen, the
        # first alphabetically - and Setup reported success. The console found
        # it on the next start, which means the racer found it.
        #
        # A missing file is retried once by name, because a single transient
        # failure is worth one more try; a file still missing after that stops
        # the install rather than leaving a tree the integrity check will fail.
        $sourceRel = @(Get-ChildItem -LiteralPath $sourceDir -Recurse -File |
                ForEach-Object { $_.FullName.Substring($sourceDir.Length).TrimStart('\', '/') })
        $targetRel = @(Get-ChildItem -LiteralPath $targetDir -Recurse -File -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName.Substring($targetDir.Length).TrimStart('\', '/') })
        $missing = @(Get-SimRigMissingAfterCopy -SourceRelativePath $sourceRel -TargetRelativePath $targetRel)
        foreach ($one in $missing) {
            Write-SetupLine -Text ('The folder copy missed {0}\{1}. Copying it again.' -f $folder, $one)
            $from = Join-Path -Path $sourceDir -ChildPath $one
            $to = Join-Path -Path $targetDir -ChildPath $one
            [void](New-Item -ItemType Directory -Path (Split-Path -Path $to -Parent) -Force)
            Copy-Item -LiteralPath $from -Destination $to -Force
        }
        if ($missing.Count -gt 0) {
            $targetRel = @(Get-ChildItem -LiteralPath $targetDir -Recurse -File -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.FullName.Substring($targetDir.Length).TrimStart('\', '/') })
            $stillMissing = @(Get-SimRigMissingAfterCopy -SourceRelativePath $sourceRel -TargetRelativePath $targetRel)
            if ($stillMissing.Count -gt 0) {
                Write-SetupLine -Text ('These files would not copy into {0}: {1}' -f $targetDir, ($stillMissing -join ', '))
                Write-SetupLine -Text 'Setup stopped rather than leave an install the integrity check will fail.'
                exit $code.StepFailed
            }
        }
    }
    $copied = 0
    foreach ($file in @($ship.File)) {
        $sourceFile = Join-Path -Path $SourcePath -ChildPath $file
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
            Write-SetupLine -Text ('Not in this copy, so not installed: {0}' -f $file)
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($file, 'copy')) { continue }
        Copy-Item -LiteralPath $sourceFile -Destination $InstallRoot -Force
        $copied++
    }
    Write-SetupLine -Text ('Copied {0} files and {1} folders.' -f $copied, @($ship.Directory).Count)

    Set-SetupInstallAcl -Root $InstallRoot
    if (-not (Test-SetupInstallAcl -Root $InstallRoot)) { exit $code.StepFailed }

    $pwsh = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $pwsh) {
        Write-SetupLine -Text 'PowerShell 7 is not on the PATH, so the shortcuts were not created. Install it and run Setup.cmd again.'
        exit $code.StepFailed
    }
    New-SetupShortcut -Root $InstallRoot -PwshPath $pwsh.Source

    if ($PSCmdlet.ShouldProcess((Join-Path -Path $InstallRoot -ChildPath 'install.json'), 'record the installed version')) {
        # Every file the app writes carries a schema version (flag 16).
        $record = [ordered]@{
            Schema      = 'simrig.install/1'
            Version     = $PackageVersion
            InstallRoot = $InstallRoot
            DataRoot    = $DataRoot
            SessionRoot = $SessionRoot
            Mode        = $mode.Mode
        }
        $record | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path -Path $InstallRoot -ChildPath 'install.json') -Encoding utf8
    }
}
catch {
    Write-SetupLine -Text ('SimRig Setup stopped part way through: {0}' -f $_.Exception.Message)
    Write-SetupLine -Text ('Nothing was changed outside {0}. Run Setup.cmd again as administrator, and tell Claude this message if it happens twice.' -f $InstallRoot)
    exit $code.Fatal
}

Write-SetupLine -Text ''
Write-SetupLine -Text ('Done. Program files in {0}. Your settings, profiles, logs and sessions stay in {1}.' -f $InstallRoot, $DataRoot)
Write-SetupLine -Text 'Next: close iRacing, double-click "SimRig Self-test", and approve the Windows prompt.'
exit $code.Done
