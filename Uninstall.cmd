@echo off
rem Clean removal: stop the task, unregister it, delete the install folder.
rem Nothing else was registered, so nothing else needs removing.
setlocal
set "GMW_PS1=%~dp0Install-HealthReport.ps1"

rem Path via environment variable - see Install.cmd for why.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',([char]34 + $env:GMW_PS1 + [char]34),'-Uninstall')"

echo.
echo The removal window opened. It stops the task, unregisters it and deletes
echo the install folder. No registry keys are involved.
pause
