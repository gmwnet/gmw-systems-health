@echo off
setlocal
set "GMW_PS1=%~dp0Install-HealthReport.ps1"

rem The path is passed through an environment variable rather than pasted into a PowerShell
rem string. Two bugs lived here before: Start-Process -ArgumentList joins its elements with
rem spaces and quotes none of them (a folder with a space split the path), and the
rem single-quoted form broke on a folder containing an apostrophe. $env: has neither issue.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',([char]34 + $env:GMW_PS1 + [char]34))"

echo.
echo The installer opened in an elevated window. Watch that window for the result.
pause
