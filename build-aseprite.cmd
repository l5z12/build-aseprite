@echo off
setlocal
set "PS=powershell.exe"
where pwsh.exe >nul 2>nul && set "PS=pwsh.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-aseprite.ps1" %*
set "RC=%ERRORLEVEL%"
echo %CMDCMDLINE% | find /i "%~0" >nul && pause
exit /b %RC%
