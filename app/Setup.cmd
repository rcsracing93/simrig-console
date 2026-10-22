@echo off
rem Setup.cmd - SimRig Console v4.2. Double-click entry point.
rem
rem A shim only: every decision and every action lives in Install-SimRig.ps1,
rem so one set of Pester tests covers the installer (unit U3.11). This file
rem finds a PowerShell 7 to run it with, hands over, and returns its exit code.
rem Exit codes come from Get-SimRigInstallExitCode: 0 done, 2 bad argument,
rem 3 refused, 4 fatal.
rem
rem   Setup.cmd              install or upgrade in place
rem   Setup.cmd /uninstall   remove the program, the shortcuts and the deadman task

setlocal
set "SIMRIG_SETUP_DIR=%~dp0"

rem Elevation. The program folder lives under Program Files, so the installer
rem cannot write it as a standard user - and on 2026-09-28 the release candidate
rem simply failed for Rick until he opened an administrator prompt himself. A
rem beta tester would have double-clicked, watched it fail, and filed that as the
rem app being broken. So: ask Windows once, the way every installer does, and
rem re-run this same file elevated. The elevated copy takes the same arguments.
rem
rem "if errorlevel 1" rather than "%ERRORLEVEL%" inside the block: a plain
rem %ERRORLEVEL% is expanded when the block is parsed, not when it runs, so it
rem would always read the value from before the command.
net session >nul 2>&1
if "%ERRORLEVEL%"=="0" goto :simrig_elevated

echo SimRig Setup needs administrator rights to write the program folder.
echo Windows will ask you to approve that now.
if "%*"=="" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs" >nul 2>&1
)
if errorlevel 1 (
  echo.
  echo That was declined, or it could not start. Right-click Setup.cmd, choose
  echo "Run as administrator", and try again.
  echo.
  pause
)
endlocal & exit /b 0

:simrig_elevated
set "SIMRIG_SETUP_PS1=%SIMRIG_SETUP_DIR%Install-SimRig.ps1"

if not exist "%SIMRIG_SETUP_PS1%" (
  echo SimRig Setup cannot find Install-SimRig.ps1 next to Setup.cmd.
  echo The zip is not fully extracted. Right-click the zip, choose Extract All,
  echo then run Setup.cmd from the extracted folder.
  endlocal
  exit /b 4
)

rem pwsh first. Windows PowerShell 5.1 is the fallback only so the installer
rem itself can run far enough to install PowerShell 7 through winget and then
rem tell the user what happened; the app needs 7.5+ either way.
rem The exit code is read OUTSIDE a bracketed block, and the branches are labels
rem rather than parentheses. Inside a block, cmd expands %ERRORLEVEL% when it
rem PARSES the block, not when the command runs - so this file used to report the
rem code from before the installer ran. On 2026-09-28 the installer refused to
rem upgrade over a live session, said so clearly, and Setup printed "exit code 0"
rem over the top of it. Three hours went into a refusal that had announced itself.
where /q pwsh.exe
if errorlevel 1 goto :simrig_windows_powershell

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SIMRIG_SETUP_PS1%" %*
set SIMRIG_SETUP_RC=%ERRORLEVEL%
goto :simrig_ran

:simrig_windows_powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SIMRIG_SETUP_PS1%" %*
set SIMRIG_SETUP_RC=%ERRORLEVEL%

:simrig_ran
if "%SIMRIG_SETUP_RC%"=="0" goto :simrig_done
echo.
echo SimRig Setup stopped with code %SIMRIG_SETUP_RC%. Read the message above.
echo.
pause

:simrig_done
endlocal & exit /b %SIMRIG_SETUP_RC%
