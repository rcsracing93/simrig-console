# engine/Engine.Install.ps1 - SimRig Console v4.2, unit U3.11 (Setup / installer
# decisions).
#
# PURE. No clock, no filesystem, no registry, no processes, no environment
# reads. Every fact the installer needs - what folder it was started from, what
# the temp folders are, whether the session marker exists, what SHA256SUMS
# says, what is already installed, what the program folder's ACL looks like -
# is read by Install-SimRig.ps1 and handed in as a parameter. That is what
# makes the installer's decisions testable on Linux (CONTRACT.md), because the
# actions themselves (copy, Set-Acl, WScript.Shell shortcuts, winget, removing
# the deadman task) only exist on Windows.
#
# Function definitions only, no top-level code, so this file stays valid when
# it is concatenated into SimRig.Engine.ps1 (Set-StrictMode is set once in the
# final file; everything here is strict-mode clean).
#
# Token sources (nothing below is invented):
#   - winget ids Microsoft.PowerShell and Microsoft.DotNet.DesktopRuntime.9,
#     and "PowerShell 7.5+ / .NET 9 Desktop Runtime required":
#     V4.2-SPEC-2026-09-19.md section 11b.
#   - the winget flag order --exact --id <id> --source winget: the U3.11 job
#     brief, verbatim.
#   - %ProgramFiles%\SimRig for program files, %LOCALAPPDATA%\SimRig for data,
#     and the ACL "Administrators and SYSTEM full, Users read and execute":
#     OPUS-BUILD-BRIEF-v4.2-2026-09-19.md flag 3.
#   - refuse to upgrade while active-session.json exists, and what /uninstall
#     removes and keeps: the same brief, flag 16.
#   - Microsoft.WindowsDesktop.App 8.0.7 and 9.0.12, and PowerShell 7.6.6.0
#     installed by winget: fixtures/v4-prep/versions.txt, a real capture from
#     Rick's rig.
#   - the deadman task path \SimRig\ and name SimRigV4-Deadman:
#     SimRig.Actions.ps1 (lead-owned, read only).
#   - the two shortcut names, their pwsh argument shape and window styles 7/1:
#     Install-SimRigV4.ps1, the v4.0 installer.
#   - the exit-code table: Get-ActionExitCode in SimRig.Engine.ps1, reused so
#     Setup.cmd and the elevated child cannot drift apart.
#
# UNCONFIRMED (see _wip/U3.11/NOTES.md): the Explorer zip-staging folder name
# shape Temp<n>_<zipname>, which is documented Windows Explorer behaviour but
# has no capture in this project. Nothing depends on it alone - such a path is
# already refused twice over, by its .zip segment and by its Temp ancestor.

function Get-SimRigInstallExitCode {
    <#
        .SYNOPSIS
        The installer's exit codes, as data. Deliberately the same table as
        Get-ActionExitCode (SimRig.Engine.ps1) so Setup.cmd, the installer and
        the elevated child all read one number the same way.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{ Done = 0; StepFailed = 1; BadArgument = 2; Refused = 3; Fatal = 4 }
}

function Get-SimRigInstallFolderName {
    <#
        .SYNOPSIS
        The single folder name used under %ProgramFiles% for the program files
        and under %LOCALAPPDATA% for the data (brief flag 3).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'SimRig'
}

function Get-SimRigHashManifestName {
    <#
        .SYNOPSIS
        The release manifest file name (spec 11: SHA256SUMS, checked by
        preflight "Script integrity"). v4.0's VERSIONS.md is replaced by it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'SHA256SUMS'
}

function Get-SimRigShipItem {
    <#
        .SYNOPSIS
        What the installer copies: the top-level files, then the four data
        folders copied whole.

        .DESCRIPTION
        The file list is the console's own $script:HashFile literal list plus
        the release manifest, the readme and the two setup files (so
        /uninstall works from the installed copy). A-INST-10 fails if the
        console starts hashing a file this list does not carry.

        VERSIONS.md is on the list because tier B's B-INST-01 found it missing on
        the first Windows run of this installer: the install succeeded and left the
        console with no VERSIONS.md, which is where the preflight's "Script
        integrity" row and the About screen's version and commit come from. Both
        would have read "unknown" on every real install. A file that is only
        generated at release time is still a file the app needs installed.

        RESTORE-NOW.cmd and SimRig.RestoreNow.ps1 (blocker 2, push A): the standalone
        restore is in the zip and in the program folder, so it runs from either.

        LICENSE (unit beta1-readme, Rick 2026-10-20): the MIT licence is in the zip
        and in the program folder.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    return [pscustomobject]@{
        File      = @(
            'SimRigConsole.ps1', 'SimRigConsole.View.ps1', 'SimRig.Engine.ps1', 'SimRig.Probe.ps1',
            'SimRig.Actions.ps1', 'SimRig.SelfTest.ps1', 'SimRig.Strings.ps1', 'SimRig.Share.ps1',
            'SimRig.Logger.ps1', 'SimRig.Actions.Defender.ps1', 'quiet-list.psd1', 'known-good.psd1', 'my-apps.psd1',
            'SHA256SUMS', 'VERSIONS.md', 'README.md', 'Setup.cmd', 'Install-SimRig.ps1', 'simrig.ico',
            'RESTORE-NOW.cmd', 'SimRig.RestoreNow.ps1', 'SimRig.ChildLog.ps1', 'LICENSE'
        )
        Directory = @('engine', 'discover', 'rules', 'profiles')
    }
}

function Get-SimRigShareRoot {
    <#
        .SYNOPSIS
        The folder Push and the self-test copy a report to: what the caller was
        given, else the active profile's NasRoot, else nothing.

        .DESCRIPTION
        The share used to be a default in two scripts - one person's mapped drive,
        shipped to every reader (the export gate found it, 2026-09-27). It lives in
        the profile now, which does not ship.

        Two callers need the same answer and must not each invent it. The console
        resolves it at startup; the self-test runs on its own, loads no machine
        profile, and would otherwise copy its report nowhere on the rig that has
        always had one.

        Nothing is invented: no share is a state, and the caller says so in the line
        it prints. An explicit -NasRoot always wins, because someone typing a path is
        answering this question directly.

        Pure.

        .OUTPUTS
        [pscustomobject] Path, Source (Given|Profile|None).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $Given,
        [AllowNull()] $RigProfile
    )

    if (-not [string]::IsNullOrWhiteSpace($Given)) {
        return [pscustomobject]@{ Path = $Given.Trim(); Source = 'Given' }
    }
    $fromProfile = [string](Get-KnownGoodField -Entry $RigProfile -Name 'NasRoot')
    if (-not [string]::IsNullOrWhiteSpace($fromProfile)) {
        return [pscustomobject]@{ Path = $fromProfile.Trim(); Source = 'Profile' }
    }
    return [pscustomobject]@{ Path = ''; Source = 'None' }
}

function Get-SimRigPrerequisite {
    <#
        .SYNOPSIS
        The two required prerequisites from spec 11b, with the winget ids the
        spec names and the floors the spec sets.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return , @(
        [pscustomobject]@{
            Id             = 'PowerShell7'
            Name           = 'PowerShell'
            MinimumVersion = '7.5.0'
            RequiredMajor  = 0
            WingetId       = 'Microsoft.PowerShell'
            Why            = 'Runs the app'
        },
        [pscustomobject]@{
            Id             = 'DotNetDesktop9'
            Name           = '.NET 9 Desktop Runtime'
            MinimumVersion = '9.0.0'
            RequiredMajor  = 9
            WingetId       = 'Microsoft.DotNet.DesktopRuntime.9'
            Why            = 'WPF window'
        }
    )
}

function Get-SimRigWingetArgument {
    <#
        .SYNOPSIS
        The winget argument list, in the exact order the job brief fixes:
        install --exact --id <id> --source winget. Nothing else is added -
        no --silent, no --accept-package-agreements - so the user sees and
        accepts whatever winget asks.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $PackageId
    )
    return , @('install', '--exact', '--id', $PackageId, '--source', 'winget')
}

function Get-ToolInstallRequest {
    <#
        .SYNOPSIS
        What the Tools card's Install button should do for one row (A-TOOL-02,
        spec 11b R-T2): the package id, the exact winget argument list, and
        whether the button belongs on that row at all.

        .DESCRIPTION
        The decision is here, and pure, because the alternative is a button
        handler that decides for itself - and a handler cannot be tested on
        Linux, so the rule would ship unproved.

        The button appears only where it has something to do. A row with no
        winget id has none: the tools the G-17 audit makes discovery find and
        name - OBS, Process Lasso, MSI Afterburner, RTSS - are named so the
        report can warn about them, not so this app installs them. A row that
        is Installed and current has none either; offering Install there is how
        a user reinstalls something that was fine.

        TooOld does get the button, because 'winget install' upgrades a package
        it already knows, and the row's own text says the version is below the
        floor.

        The argument list comes from Get-SimRigWingetArgument, unchanged, so
        there is exactly one place in this build that decides what is passed to
        winget. Nothing is added: no --silent and no agreement flag, so the user
        sees and accepts whatever winget asks.

        Pure. It launches nothing.

        .OUTPUTS
        [pscustomobject] Name, PackageId, Argument, CommandLine, CanInstall,
        Why (why not, when CanInstall is false).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] $Row)

    $name = [string](Get-KnownGoodField -Entry $Row -Name 'Name')
    $state = [string](Get-KnownGoodField -Entry $Row -Name 'State')
    $packageId = [string](Get-KnownGoodField -Entry $Row -Name 'WingetId')

    $blocked = if ([string]::IsNullOrWhiteSpace($packageId)) {
        'this app does not install this tool - it only reports that it is there'
    }
    elseif ($state -notin @('Missing', 'TooOld')) {
        'already installed and new enough'
    }
    else { $null }

    if ($null -ne $blocked) {
        return [pscustomobject]@{
            Name = $name; PackageId = $null; Argument = @(); CommandLine = $null
            CanInstall = $false; Why = $blocked
        }
    }

    $argument = Get-SimRigWingetArgument -PackageId $packageId
    return [pscustomobject]@{
        Name        = $name
        PackageId   = $packageId
        Argument    = @($argument)
        CommandLine = (Get-SimRigWingetCommandLine -PackageId $packageId)
        CanInstall  = $true
        Why         = $null
    }
}

function Get-SimRigWingetCommandLine {
    <#
        .SYNOPSIS
        The same command as one line, for the message a user has to retype
        when winget could not do it for them.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $PackageId
    )
    $argument = Get-SimRigWingetArgument -PackageId $PackageId
    return ('winget {0}' -f ($argument -join ' '))
}

function ConvertTo-SimRigInstallVersion {
    <#
        .SYNOPSIS
        Parses the leading numeric part of a version string to a [version],
        or $null when there is none. InvariantCulture on every number (flag
        5 - the release gate has a de-DE culture run).

        .DESCRIPTION
        A pre-release suffix is dropped: '9.0.0-preview.3.24172.9' parses to
        9.0.0. Test-SimRigInstallVersionIsPreRelease is what tells a caller
        the suffix was there, because 4.2.0-beta.1 must read as OLDER than
        4.2.0 when the installer decides upgrade versus reinstall.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $found = [regex]::Match($Text, '^\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $found.Success) { return $null }
    $part = @()
    foreach ($index in 1, 2, 3, 4) {
        if (-not $found.Groups[$index].Success) { continue }
        $part += [int]::Parse($found.Groups[$index].Value, [cultureinfo]::InvariantCulture)
    }
    switch ($part.Count) {
        4 { return [version]::new($part[0], $part[1], $part[2], $part[3]) }
        3 { return [version]::new($part[0], $part[1], $part[2]) }
        2 { return [version]::new($part[0], $part[1]) }
        default { return [version]::new($part[0], 0) }
    }
}

function Test-SimRigInstallVersionIsPreRelease {
    <#
        .SYNOPSIS
        True when the version text carries a pre-release suffix
        ('4.2.0-beta.1'). Pure string work.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [regex]::IsMatch($Text, '^\s*\d+(\.\d+)*\s*-')
}

function ConvertFrom-SimRigDotnetRuntimeLine {
    <#
        .SYNOPSIS
        Reads the installed versions of one runtime out of 'dotnet
        --list-runtimes' output. Each real line looks like
        'Microsoft.WindowsDesktop.App 9.0.12 [C:\Program Files\dotnet\shared\...]'
        (fixtures/v4-prep/versions.txt).

        .DESCRIPTION
        The name is anchored at the start of the line, so the AspNetCore rows
        - whose trailing path also ends in a runtime name - are not counted as
        desktop runtimes. Duplicates are dropped, because a capture can hold
        more than one run of the command. A row with no version, or a version
        that will not parse, is skipped rather than read as 0.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Line,
        [Parameter(Mandatory)] [string] $RuntimeName
    )
    $pattern = '^\s*' + [regex]::Escape($RuntimeName) + '\s+(\S+)\s+\['
    $seen = [System.Collections.Generic.List[string]]::new()
    foreach ($text in $Line) {
        if ($null -eq $text) { continue }
        $found = [regex]::Match($text, $pattern)
        if (-not $found.Success) { continue }
        $value = $found.Groups[1].Value
        if ($null -eq (ConvertTo-SimRigInstallVersion -Text $value)) { continue }
        if ($seen.Contains($value)) { continue }
        $seen.Add($value)
    }
    return , $seen.ToArray()
}

function Get-SimRigMissingPrerequisite {
    <#
        .SYNOPSIS
        Which of the two required prerequisites are absent or too old, given
        the PowerShell version the installer is running under and the list of
        installed Microsoft.WindowsDesktop.App versions.

        .DESCRIPTION
        PowerShell is a floor check (7.5.0 or newer). The desktop runtime is a
        major-version check as well as a floor: the app targets .NET 9, so a
        machine with only 8.0.7 or only 10.0.1 is missing it. Each record
        carries the winget command line the refusal message shows.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $PowerShellVersion,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $DesktopRuntimeVersion
    )
    $missing = [System.Collections.Generic.List[object]]::new()
    # Assigned first, never enumerated inline: Get-SimRigPrerequisite returns
    # ', @(...)', and 'foreach ($x in Get-...)' would hand the whole array
    # round once as a single item.
    $prereqList = Get-SimRigPrerequisite
    foreach ($prereq in $prereqList) {
        $floor = ConvertTo-SimRigInstallVersion -Text $prereq.MinimumVersion
        $reason = ''
        if ($prereq.Id -eq 'PowerShell7') {
            $have = ConvertTo-SimRigInstallVersion -Text $PowerShellVersion
            if ($null -eq $have) { $reason = 'not installed' }
            elseif ($have -lt $floor) { $reason = ('{0} is older than {1}' -f $have, $prereq.MinimumVersion) }
        }
        else {
            $best = $null
            foreach ($text in $DesktopRuntimeVersion) {
                $candidate = ConvertTo-SimRigInstallVersion -Text $text
                if ($null -eq $candidate) { continue }
                if ($candidate.Major -ne $prereq.RequiredMajor) { continue }
                if ($candidate -lt $floor) { continue }
                if ($null -eq $best -or $candidate -gt $best) { $best = $candidate }
            }
            if ($null -eq $best) {
                $reason = ('no {0}.x runtime of {1} or newer is installed' -f $prereq.RequiredMajor, $prereq.MinimumVersion)
            }
        }
        if ($reason -eq '') { continue }
        $missing.Add([pscustomobject]@{
                Id             = $prereq.Id
                Name           = $prereq.Name
                MinimumVersion = $prereq.MinimumVersion
                WingetId       = $prereq.WingetId
                CommandLine    = Get-SimRigWingetCommandLine -PackageId $prereq.WingetId
                Reason         = $reason
            })
    }
    return , $missing.ToArray()
}

function Get-SimRigInstallRefusalCode {
    <#
        .SYNOPSIS
        Every refusal the installer can give, as data, so a test can prove
        each one has a message and so the codes cannot drift from the
        messages.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return , @(
        'SourceUnknown', 'SourceInArchive', 'SourceInTempFolder', 'SessionActive',
        'ManifestMissing', 'ManifestEmpty', 'ManifestFileMissing', 'ManifestMismatch',
        'NotElevated', 'WouldDowngrade', 'PrerequisiteMissing'
    )
}

function Get-SimRigInstallRefusalMessage {
    <#
        .SYNOPSIS
        The exact words a user sees for one refusal. Every message names what
        was wrong (the Detail) and what to do next; none of them is a warning
        the user can click past, because Setup refuses instead of half
        installing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Code,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Detail
    )
    switch ($Code) {
        'SourceUnknown' {
            return ('SimRig Setup cannot tell which folder it was started from, so it stops rather than guess. Extract the release zip to a real folder and run Setup.cmd from there. It was given: {0}' -f $Detail)
        }
        'SourceInArchive' {
            return ('SimRig Setup will not install from inside a zip. Right-click the zip, choose Extract All, and run Setup.cmd from the extracted folder. It was started from: {0}' -f $Detail)
        }
        'SourceInTempFolder' {
            return ('SimRig Setup will not install from a temporary folder, because Windows can empty it part way through. Extract the whole zip to a real folder - Downloads is fine - then run Setup.cmd from there. It was started from: {0}' -f $Detail)
        }
        'SessionActive' {
            return ('SimRig Console has a session open and Windows is still quiet. Open SimRig Console and finish Restore first, then run Setup again. Upgrading now would leave Windows quiet with a restore path that no longer matches. Session marker: {0}' -f $Detail)
        }
        'ManifestMissing' {
            return ('SHA256SUMS is not in this folder. Setup copies nothing it cannot verify first. Download the release zip again and extract all of it, then run Setup.cmd. Looked in: {0}' -f $Detail)
        }
        'ManifestEmpty' {
            return ('SHA256SUMS has no file lines in it, so there is nothing to verify against. Download the release zip again from the release page. Manifest: {0}' -f $Detail)
        }
        'ManifestFileMissing' {
            return ('These files are listed in SHA256SUMS but are not in this folder, so the zip is not fully extracted: {0}. Extract all of it and run Setup.cmd again. Nothing was copied.' -f $Detail)
        }
        'ManifestMismatch' {
            return ('These files do not match SHA256SUMS: {0}. Setup copied nothing. Download the release zip again from the release page and check the zip SHA256 shown there before running Setup.' -f $Detail)
        }
        'NotElevated' {
            return ('SimRig Setup must run as administrator, because it writes to the program folder and sets its permissions so a standard user cannot change the elevated code. Right-click Setup.cmd and choose Run as administrator. Program folder: {0}' -f $Detail)
        }
        'WouldDowngrade' {
            return ('The SimRig already installed is newer than this copy, so Setup will not go backwards. Uninstall the newer one first if that is really what you want. {0}' -f $Detail)
        }
        'PrerequisiteMissing' {
            return ('SimRig still needs {0}. Install it by hand and run Setup.cmd again.' -f $Detail)
        }
        default {
            return ('SimRig Setup stopped and gave no reason it knows how to explain. Tell Claude the code and what you were doing. Code: {0}, detail: {1}' -f $Code, $Detail)
        }
    }
}

function Test-SimRigSourcePathIsTemporary {
    <#
        .SYNOPSIS
        True when a folder is a temp folder or sits under one. Pure string
        work on the path plus the temp folders the caller read from the
        environment.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $TempPathList
    )
    return ((Get-SimRigSourcePathVerdict -Path $Path -TempPathList $TempPathList).Code -eq 'SourceInTempFolder')
}

function Get-SimRigSourcePathVerdict {
    <#
        .SYNOPSIS
        Is this folder safe to install from? People double-click Setup.cmd
        straight out of the download, and a half-extracted install that half
        works is worse than one that refuses.

        .DESCRIPTION
        Two refusals, checked in this order:
          SourceInArchive - a path segment is still an archive file
            ('...\SimRig-v4.2.0.zip\SimRig-v4.2.0'), which is what Explorer
            shows when someone opens the zip and runs Setup.cmd from inside it.
            Checked first, because the Explorer staging folder is both an
            archive path and a temp path and the archive message is the one
            that tells the user what they actually did.
          SourceInTempFolder - the path is, or sits under, one of the temp
            folders the caller passed in, OR any segment of it is exactly
            'Temp' or 'tmp', which catches another account's
            AppData\Local\Temp and C:\Windows\Temp when the caller's own
            %TEMP% does not match.
        A folder merely NAMED Templates or Temperature is not a temp folder:
        the segment must be the whole word.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $TempPathList
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{
            Code = 'SourceUnknown'; IsRefusal = $true
            Message = Get-SimRigInstallRefusalMessage -Code 'SourceUnknown' -Detail '(blank)'
        }
    }
    $normal = $Path.Replace('/', '\').TrimEnd('\')
    $segment = @($normal.Split('\') | Where-Object { $_ -ne '' })
    foreach ($name in $segment) {
        foreach ($extension in '.zip', '.7z', '.rar', '.cab') {
            if ($name.EndsWith($extension, [System.StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{
                    Code = 'SourceInArchive'; IsRefusal = $true
                    Message = Get-SimRigInstallRefusalMessage -Code 'SourceInArchive' -Detail $Path
                }
            }
        }
    }
    foreach ($name in $segment) {
        if ($name -ieq 'Temp' -or $name -ieq 'tmp' -or $name -ieq 'INetCache') {
            return [pscustomobject]@{
                Code = 'SourceInTempFolder'; IsRefusal = $true
                Message = Get-SimRigInstallRefusalMessage -Code 'SourceInTempFolder' -Detail $Path
            }
        }
    }
    foreach ($root in $TempPathList) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $rootNormal = $root.Replace('/', '\').TrimEnd('\')
        if ($normal -ieq $rootNormal -or $normal.StartsWith(($rootNormal + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                Code = 'SourceInTempFolder'; IsRefusal = $true
                Message = Get-SimRigInstallRefusalMessage -Code 'SourceInTempFolder' -Detail $Path
            }
        }
    }
    return [pscustomobject]@{ Code = 'SourceOk'; IsRefusal = $false; Message = '' }
}

function ConvertFrom-SimRigHashManifestLine {
    <#
        .SYNOPSIS
        Parses SHA256SUMS lines. Accepts both forms sha256sum writes:
        '<64 hex>  <path>' and '<64 hex> *<path>' (binary). Blank lines,
        comment lines and anything that is not a 64-hex-digit line are
        skipped, so a release note at the top of the file costs nothing.

        .DESCRIPTION
        The path is the rest of the line, trimmed - not the first whitespace
        token - so a file name with a space in it survives.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Line
    )
    $entry = [System.Collections.Generic.List[object]]::new()
    foreach ($text in $Line) {
        if ($null -eq $text) { continue }
        $found = [regex]::Match($text, '^([0-9A-Fa-f]{64})[ \t]+\*?(.+?)\s*$')
        if (-not $found.Success) { continue }
        $entry.Add([pscustomobject]@{
                Hash = $found.Groups[1].Value
                Path = $found.Groups[2].Value
            })
    }
    return , $entry.ToArray()
}

function Get-SimRigHashManifestVerdict {
    <#
        .SYNOPSIS
        Compares the manifest against the hashes the caller computed. A file
        that does not match is a refusal, not a warning: Setup verifies
        before it copies anything.

        .DESCRIPTION
        Paths are compared with / and \ treated as the same separator and
        without case, because SHA256SUMS is written by a Linux runner and read
        on Windows. The manifest never checks itself. A file listed but absent
        is reported ahead of a file that mismatches, because the fix differs:
        an absent file means the zip was not fully extracted, a mismatch means
        the download is wrong or the tree was edited. An extra file on disk
        that the manifest does not list is not a refusal - a user's notes next
        to the zip are not the installer's business.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Entry,
        [Parameter(Mandatory)] [hashtable] $ActualHash
    )
    $manifestName = Get-SimRigHashManifestName
    $actual = @{}
    foreach ($key in $ActualHash.Keys) {
        $actual[([string]$key).Replace('\', '/').ToLowerInvariant()] = [string]$ActualHash[$key]
    }
    $missing = [System.Collections.Generic.List[string]]::new()
    $mismatch = [System.Collections.Generic.List[string]]::new()
    $checked = 0
    foreach ($item in $Entry) {
        if ($null -eq $item) { continue }
        if ($item.PSObject.Properties.Match('Path').Count -eq 0) { continue }
        if ($item.PSObject.Properties.Match('Hash').Count -eq 0) { continue }
        $key = ([string]$item.Path).Replace('\', '/').ToLowerInvariant()
        if ($key -eq $manifestName.ToLowerInvariant()) { continue }
        $checked++
        if (-not $actual.ContainsKey($key)) { $missing.Add([string]$item.Path); continue }
        if (-not [string]::Equals($actual[$key], [string]$item.Hash, [System.StringComparison]::OrdinalIgnoreCase)) {
            $mismatch.Add([string]$item.Path)
        }
    }
    if ($checked -eq 0) {
        return [pscustomobject]@{
            Code = 'ManifestEmpty'; IsRefusal = $true
            Missing = @(); Mismatch = @()
            Message = Get-SimRigInstallRefusalMessage -Code 'ManifestEmpty' -Detail $manifestName
        }
    }
    if ($missing.Count -gt 0) {
        return [pscustomobject]@{
            Code = 'ManifestFileMissing'; IsRefusal = $true
            Missing = $missing.ToArray(); Mismatch = $mismatch.ToArray()
            Message = Get-SimRigInstallRefusalMessage -Code 'ManifestFileMissing' -Detail ($missing.ToArray() -join ', ')
        }
    }
    if ($mismatch.Count -gt 0) {
        return [pscustomobject]@{
            Code = 'ManifestMismatch'; IsRefusal = $true
            Missing = @(); Mismatch = $mismatch.ToArray()
            Message = Get-SimRigInstallRefusalMessage -Code 'ManifestMismatch' -Detail ($mismatch.ToArray() -join ', ')
        }
    }
    return [pscustomobject]@{
        Code = 'ManifestOk'; IsRefusal = $false
        Missing = @(); Mismatch = @(); Message = ''
    }
}

function Get-SimRigInstallMode {
    <#
        .SYNOPSIS
        Fresh install, in-place upgrade, reinstall of the same version, or a
        refusal because what is installed is newer.

        .DESCRIPTION
        A target folder with no readable version is an upgrade, not a
        downgrade refusal: an install too old or too broken to state its
        version is exactly the case an upgrade has to fix. A pre-release
        counts as older than the release it precedes, so 4.2.0-beta.1 to
        4.2.0 is an upgrade rather than a reinstall.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [bool] $TargetExists,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $InstalledVersion,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $PackageVersion
    )
    if (-not $TargetExists) {
        return [pscustomobject]@{ Mode = 'Fresh'; IsRefusal = $false; Code = ''; Message = '' }
    }
    $have = ConvertTo-SimRigInstallVersion -Text $InstalledVersion
    $want = ConvertTo-SimRigInstallVersion -Text $PackageVersion
    if ($null -eq $have -or $null -eq $want) {
        return [pscustomobject]@{ Mode = 'Upgrade'; IsRefusal = $false; Code = ''; Message = '' }
    }
    if ($have -gt $want) {
        $detail = ('Installed {0}, this copy {1}.' -f $InstalledVersion, $PackageVersion)
        return [pscustomobject]@{
            Mode = 'Downgrade'; IsRefusal = $true; Code = 'WouldDowngrade'
            Message = Get-SimRigInstallRefusalMessage -Code 'WouldDowngrade' -Detail $detail
        }
    }
    if ($have -lt $want) {
        return [pscustomobject]@{ Mode = 'Upgrade'; IsRefusal = $false; Code = ''; Message = '' }
    }
    $havePre = Test-SimRigInstallVersionIsPreRelease -Text $InstalledVersion
    $wantPre = Test-SimRigInstallVersionIsPreRelease -Text $PackageVersion
    if ($havePre -and -not $wantPre) {
        return [pscustomobject]@{ Mode = 'Upgrade'; IsRefusal = $false; Code = ''; Message = '' }
    }
    if ($wantPre -and -not $havePre) {
        $detail = ('Installed {0}, this copy {1}.' -f $InstalledVersion, $PackageVersion)
        return [pscustomobject]@{
            Mode = 'Downgrade'; IsRefusal = $true; Code = 'WouldDowngrade'
            Message = Get-SimRigInstallRefusalMessage -Code 'WouldDowngrade' -Detail $detail
        }
    }
    return [pscustomobject]@{ Mode = 'Reinstall'; IsRefusal = $false; Code = ''; Message = '' }
}

function Get-SimRigSessionVerdict {
    <#
        .SYNOPSIS
        Refuse while a session is quiet (brief flag 16). The marker
        (C:\SimRacer\Logs\v4\active-session.json, from Get-SimRigPath) means a
        quiet ran and no restore has finished, so Windows is still quiet and
        the restore path in the marker points at the install about to be
        replaced.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $MarkerPath,
        [Parameter(Mandatory)] [bool] $IsSessionActive
    )
    if (-not $IsSessionActive) {
        return [pscustomobject]@{ Code = 'SessionOk'; IsRefusal = $false; Message = '' }
    }
    return [pscustomobject]@{
        Code = 'SessionActive'; IsRefusal = $true
        Message = Get-SimRigInstallRefusalMessage -Code 'SessionActive' -Detail $MarkerPath
    }
}

function Get-SimRigInstallAclRule {
    <#
        .SYNOPSIS
        The program-folder ACL from brief flag 3: Administrators and SYSTEM
        full control, Users read and execute. Inherited down the whole tree,
        because the engine, discover, rules and profiles folders hold code and
        data the elevated child reads.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return , @(
        [pscustomobject]@{
            Identity = 'BUILTIN\Administrators'; Rights = 'FullControl'; Type = 'Allow'
            Inheritance = 'ContainerInherit, ObjectInherit'; Propagation = 'None'
        },
        [pscustomobject]@{
            Identity = 'NT AUTHORITY\SYSTEM'; Rights = 'FullControl'; Type = 'Allow'
            Inheritance = 'ContainerInherit, ObjectInherit'; Propagation = 'None'
        },
        [pscustomobject]@{
            Identity = 'BUILTIN\Users'; Rights = 'ReadAndExecute'; Type = 'Allow'
            Inheritance = 'ContainerInherit, ObjectInherit'; Propagation = 'None'
        }
    )
}

function Get-SimRigInstallAclTrustedIdentity {
    <#
        .SYNOPSIS
        The identities that may hold a write right on the install root. Only
        accounts a standard user cannot act as: anything else with a write
        right defeats flag 3.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return , @(
        'BUILTIN\Administrators', 'Administrators',
        'NT AUTHORITY\SYSTEM', 'SYSTEM',
        'NT SERVICE\TrustedInstaller', 'CREATOR OWNER', 'NT AUTHORITY\CREATOR OWNER'
    )
}

function Get-SimRigInstallAclVerdict {
    <#
        .SYNOPSIS
        Does this ACL stop a standard user writing to the install root? The
        console's own preflight asks the same question of its install root
        (flag 3), so the rule lives here rather than in the installer.

        .DESCRIPTION
        An Allow entry that grants any write right to an identity outside the
        trusted list is an offender. Deny entries are ignored - a Deny on
        Users is not a way in. An empty ACL is not safe: no entries means the
        installer never set them.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Ace
    )
    $writeRight = @(
        'FullControl', 'Modify', 'Write', 'WriteData', 'CreateFiles', 'CreateDirectories',
        'AppendData', 'WriteAttributes', 'WriteExtendedAttributes', 'Delete',
        'DeleteSubdirectoriesAndFiles', 'TakeOwnership', 'ChangePermissions'
    )
    $trusted = Get-SimRigInstallAclTrustedIdentity
    $offender = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Ace) {
        if ($null -eq $item) { continue }
        if ($item.PSObject.Properties.Match('Identity').Count -eq 0) { continue }
        if ($item.PSObject.Properties.Match('Rights').Count -eq 0) { continue }
        if ($item.PSObject.Properties.Match('Type').Count -gt 0 -and [string]$item.Type -ine 'Allow') { continue }
        $identity = [string]$item.Identity
        if ($trusted -icontains $identity) { continue }
        $granted = @(([string]$item.Rights).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        foreach ($right in $granted) {
            if ($writeRight -icontains $right) {
                if (-not $offender.Contains($identity)) { $offender.Add($identity) }
            }
        }
    }
    return [pscustomobject]@{
        IsSafe   = (($offender.Count -eq 0) -and (@($Ace).Count -gt 0))
        Offender = $offender.ToArray()
    }
}

function Get-SimRigMissingAfterCopy {
    <#
        .SYNOPSIS
        Which files the source has and the target does not, after a folder copy.

        .DESCRIPTION
        Verify the effect, never the intention - the same rule deploy.py has
        carried since a copy reported success and wrote nothing.

        On 2026-09-29 an install of rc.7 left engine\Engine.Anon.ps1 out of
        C:\Program Files\SimRig. One file, the first one alphabetically, from a
        folder copied with Copy-Item -Recurse. Setup reported success. Nothing
        in the installer noticed, because nothing in the installer looked: it
        copied, and then trusted that copying had happened.

        The console caught it on the next start - "Script integrity:
        engine/Engine.Anon.ps1 missing from file hash" - which is the app's own
        check doing its job, but by then the bad install is already on the
        machine and the racer is the one reading a red row.

        Pure: both lists come from the caller, so this is testable without
        touching a disk. Comparison ignores case, because Windows paths do.

        .OUTPUTS
        [string[]] the relative paths present in Source and absent from Target.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $SourceRelativePath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $TargetRelativePath
    )

    # .Replace, not -replace: the right-hand side of -replace is a regex
    # replacement string, where a backslash needs escaping and the first cut of
    # this function turned one separator into two.
    $have = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $TargetRelativePath) {
        if (-not [string]::IsNullOrWhiteSpace($item)) { [void]$have.Add($item.Replace('/', '\')) }
    }
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $SourceRelativePath) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $normal = $item.Replace('/', '\')
        if (-not $have.Contains($normal)) { $missing.Add($normal) }
    }
    # No comma wrap. This returns a string[], and the callers wrap it in @().
    # A ", $array" here hands back an array containing the array, which is how
    # the first cut reported one finding no matter how many were missing.
    return $missing.ToArray()
}

function Get-SimRigInstallShortcut {
    <#
        .SYNOPSIS
        The two desktop shortcuts, as data. Neither is "Run as administrator":
        the console runs unelevated on purpose (v4.0 - a mapped Z: drive is
        only visible to the unelevated session) and asks for elevation per
        action through one child.

        .DESCRIPTION
        Argument shapes and window styles are the v4.0 ones
        (Install-SimRigV4.ps1): the console is a window of its own, so its
        PowerShell host is hidden (style 7); the self-test prints its results
        in the host window, so that one stays visible (style 1).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [string] $InstallRoot,
        [Parameter(Mandatory)] [string] $DesktopPath,
        [Parameter(Mandatory)] [string] $PwshPath
    )
    $root = $InstallRoot.TrimEnd('\')
    $plan = @(
        [pscustomobject]@{ Name = 'SimRig Console'; Script = 'SimRigConsole.ps1'; Hidden = $true; WindowStyle = 7 },
        [pscustomobject]@{ Name = 'SimRig Self-test'; Script = 'SimRig.SelfTest.ps1'; Hidden = $false; WindowStyle = 1 }
    )
    $shortcut = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $plan) {
        $scriptPath = Join-SimRigSettingsPath -Root $root -Child $item.Script
        $argument = if ($item.Hidden) {
            '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
        }
        else {
            '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
        }
        $shortcut.Add([pscustomobject]@{
                Name               = $item.Name
                Script             = $item.Script
                LinkPath           = Join-SimRigSettingsPath -Root ($DesktopPath.TrimEnd('\')) -Child ($item.Name + '.lnk')
                TargetPath         = $PwshPath
                Argument           = $argument
                WorkingDirectory   = $root
                WindowStyle        = $item.WindowStyle
                RunAsAdministrator = $false
                # Both shortcuts point at pwsh.exe, so without this they wear the
                # PowerShell icon and the app looks like a loose script on the
                # desktop. ',0' is the first icon in the file.
                IconLocation       = (Join-SimRigSettingsPath -Root $root -Child 'simrig.ico') + ',0'
            })
    }
    return , $shortcut.ToArray()
}

function Get-SimRigUninstallReadiness {
    <#
        .SYNOPSIS
        Whether it is safe to uninstall yet, and what has to happen first (spec 16).

        .DESCRIPTION
        Two things can outlive this app on the machine, and both are things it did on
        purpose:

        A quiet session. Windows is in its session state and the snapshot in the
        session folder is the only record of what it was before. Remove the app and
        that snapshot has nothing left to replay it - the user is left with services
        disabled, tasks off and no way back that does not involve a support thread.

        Applied persistent tuning. HAGS, MPO and the power plan survive a reboot by
        design. They also survive an uninstall, so a user who removes the app because
        it did not help is left with the changes it made and no Undo button.

        So neither is a warning. Each one stops the uninstall and names the button to
        press first, and the dialog is not even shown - a confirmation dialog for
        something that cannot proceed teaches people to click through dialogs.

        Pure: the caller does the two reads and passes what it found.

        .OUTPUTS
        [pscustomobject] Ready, Reason, OfferRestore, OfferUndo.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [bool] $IsSessionActive,
        [Parameter(Mandatory)] [bool] $IsTuningApplied
    )

    if ($IsSessionActive) {
        return [pscustomobject]@{
            Ready = $false; OfferRestore = $true; OfferUndo = $false
            Reason = 'Windows is still in its session state. Restore it first: the session snapshot is the only record of what it was before, and removing the app leaves nothing to replay it.'
        }
    }
    if ($IsTuningApplied) {
        return [pscustomobject]@{
            Ready = $false; OfferRestore = $false; OfferUndo = $true
            Reason = 'Persistent tuning is still applied. Undo tuning first: those values survive a reboot, so they survive an uninstall too, and afterwards there is no Undo button left to press.'
        }
    }
    return [pscustomobject]@{
        Ready = $true; OfferRestore = $false; OfferUndo = $false
        Reason = 'Nothing this app changed is still applied.'
    }
}

function Get-SimRigUninstallPlan {
    <#
        .SYNOPSIS
        What /uninstall removes and what it leaves alone (brief flag 16): the
        program folder, the two shortcuts and the deadman logon task go; the
        user's data folder, settings, profiles, app logs and session history
        stay.

        .DESCRIPTION
        Refuses on the same session marker as an install: uninstalling while
        Windows is quiet would leave the quiet in place with nothing left to
        restore it. The program folder is never removed when it is the data
        root or an ancestor of it - on Rick's rig the install root is
        C:\SimRacer\Scripts\v4 inside the data root C:\SimRacer, and taking
        the parent would take the session history with it.
        The task path and name are the ones SimRig.Actions.ps1 registers.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $InstallRoot,
        [Parameter(Mandatory)] [string] $DesktopPath,
        [Parameter(Mandatory)] [string] $DataRoot,
        [Parameter(Mandatory)] [string] $SessionRoot,
        [Parameter(Mandatory)] [bool] $IsSessionActive
    )
    $install = $InstallRoot.TrimEnd('\')
    $data = $DataRoot.TrimEnd('\')
    $session = $SessionRoot.TrimEnd('\')
    $keep = @(
        $data
        Join-SimRigSettingsPath -Root $data -Child 'settings.json'
        Join-SimRigSettingsPath -Root $data -Child 'profiles'
        Join-SimRigSettingsPath -Root $data -Child 'Logs'
        Join-SimRigSettingsPath -Root $session -Child 'Logs\v4'
        Join-SimRigSettingsPath -Root $session -Child 'Logs\v4\sessions'
    )
    $removeFolder = @()
    $isAncestor = $false
    foreach ($other in $data, $session) {
        if ($other -ieq $install) { $isAncestor = $true }
        if ($other.StartsWith(($install + '\'), [System.StringComparison]::OrdinalIgnoreCase)) { $isAncestor = $true }
    }
    if (-not $isAncestor) { $removeFolder = @($install) }
    $shortcutPlan = Get-SimRigInstallShortcut -InstallRoot $install -DesktopPath $DesktopPath -PwshPath 'pwsh.exe'
    $shortcut = @($shortcutPlan | ForEach-Object { $_.LinkPath })
    if ($IsSessionActive) {
        return [pscustomobject]@{
            IsRefusal = $true; Code = 'SessionActive'
            Message = Get-SimRigInstallRefusalMessage -Code 'SessionActive' -Detail (Join-SimRigSettingsPath -Root $session -Child 'Logs\v4\active-session.json')
            RemoveFolder = @(); RemoveShortcut = @(); RemoveTaskPath = ''; RemoveTaskName = ''; Keep = $keep
        }
    }
    return [pscustomobject]@{
        IsRefusal      = $false
        Code           = ''
        Message        = ''
        RemoveFolder   = $removeFolder
        RemoveShortcut = $shortcut
        RemoveTaskPath = '\SimRig\'
        RemoveTaskName = 'SimRigV4-Deadman'
        Keep           = $keep
    }
}

function Get-SimRigInstallRefusal {
    <#
        .SYNOPSIS
        The one gate. Returns the first refusal, or $null when the install may
        go ahead. Every caller-side read is a parameter here, so the whole
        decision is testable off Windows.

        .DESCRIPTION
        Order, and why:
          1. the source folder - a temp or zip path means the tree itself
             cannot be trusted, so nothing else is worth reading.
          2. an open session - the most urgent thing to tell a racer, and the
             one refusal whose fix is inside the app rather than in Setup.
          3. SHA256SUMS present, then its verdict - verify before copying.
          4. elevation - checked after the tree is known good, so a user who
             forgot to right-click is not also told the download is broken.
          5. a newer install already there.
          6. a prerequisite winget could not install. Last, because it is the
             only one the installer first tries to fix itself.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $SourcePath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $TempPathList,
        [Parameter(Mandatory)] [string] $ActiveSessionMarkerPath,
        [Parameter(Mandatory)] [bool] $IsSessionActive,
        [Parameter(Mandatory)] [bool] $IsManifestPresent,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ManifestEntry,
        [Parameter(Mandatory)] [hashtable] $ActualHash,
        [Parameter(Mandatory)] [bool] $IsElevated,
        [Parameter(Mandatory)] [bool] $TargetExists,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $InstalledVersion,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $PackageVersion,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $MissingPrerequisite,
        [string] $InstallRoot = ''
    )
    $source = Get-SimRigSourcePathVerdict -Path $SourcePath -TempPathList $TempPathList
    if ($source.IsRefusal) {
        return [pscustomobject]@{ Code = $source.Code; Message = $source.Message; Detail = $SourcePath }
    }
    $session = Get-SimRigSessionVerdict -MarkerPath $ActiveSessionMarkerPath -IsSessionActive $IsSessionActive
    if ($session.IsRefusal) {
        return [pscustomobject]@{ Code = $session.Code; Message = $session.Message; Detail = $ActiveSessionMarkerPath }
    }
    if (-not $IsManifestPresent) {
        return [pscustomobject]@{
            Code = 'ManifestMissing'
            Message = Get-SimRigInstallRefusalMessage -Code 'ManifestMissing' -Detail $SourcePath
            Detail = $SourcePath
        }
    }
    $manifest = Get-SimRigHashManifestVerdict -Entry $ManifestEntry -ActualHash $ActualHash
    if ($manifest.IsRefusal) {
        return [pscustomobject]@{ Code = $manifest.Code; Message = $manifest.Message; Detail = (@($manifest.Missing) + @($manifest.Mismatch)) -join ', ' }
    }
    if (-not $IsElevated) {
        $where = if ([string]::IsNullOrWhiteSpace($InstallRoot)) { 'the SimRig program folder' } else { $InstallRoot }
        return [pscustomobject]@{
            Code = 'NotElevated'
            Message = Get-SimRigInstallRefusalMessage -Code 'NotElevated' -Detail $where
            Detail = $where
        }
    }
    $mode = Get-SimRigInstallMode -TargetExists $TargetExists -InstalledVersion $InstalledVersion -PackageVersion $PackageVersion
    if ($mode.IsRefusal) {
        return [pscustomobject]@{ Code = $mode.Code; Message = $mode.Message; Detail = $InstalledVersion }
    }
    $stillMissing = @($MissingPrerequisite | Where-Object { $null -ne $_ })
    if ($stillMissing.Count -gt 0) {
        $part = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $stillMissing) {
            $name = if ($item.PSObject.Properties.Match('Name').Count -gt 0) { [string]$item.Name } else { 'a prerequisite' }
            $floor = if ($item.PSObject.Properties.Match('MinimumVersion').Count -gt 0) { [string]$item.MinimumVersion } else { '' }
            $line = if ($floor -eq '') { $name } else { ('{0} {1} or newer' -f $name, $floor) }
            if ($item.PSObject.Properties.Match('CommandLine').Count -gt 0) {
                $line = ('{0} - winget could not install it. Run: {1}' -f $line, [string]$item.CommandLine)
            }
            $part.Add($line)
        }
        $detail = $part.ToArray() -join '; '
        return [pscustomobject]@{
            Code = 'PrerequisiteMissing'
            Message = Get-SimRigInstallRefusalMessage -Code 'PrerequisiteMissing' -Detail $detail
            Detail = $detail
        }
    }
    return $null
}
