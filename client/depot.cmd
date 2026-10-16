@echo off
rem depot - AppDepot command-line client (wrapper for depot.ps1)
where pwsh.exe >nul 2>nul
if %ERRORLEVEL%==0 (
    pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0depot.ps1" %*
) else (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0depot.ps1" %*
)
exit /b %ERRORLEVEL%
