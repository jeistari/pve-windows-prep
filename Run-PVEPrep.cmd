@echo off
rem ------------------------------------------------------------------------
rem  Proxmox VE migration preparation - double-click launcher
rem
rem  No arguments  -> opens the wizard (tick the steps you want to run)
rem  With arguments -> passed straight through, no wizard, e.g.
rem       Run-PVEPrep.cmd -Steps Drivers,BootDriver,Verify -Driver both
rem
rem  The PowerShell script requests elevation (UAC) itself if needed.
rem ------------------------------------------------------------------------
setlocal
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

if "%~1"=="" (
    "%PSEXE%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Prepare-PVEMigration.ps1" -Wizard -PauseAtEnd
) else (
    "%PSEXE%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Prepare-PVEMigration.ps1" -PauseAtEnd %*
)
exit /b %ERRORLEVEL%
