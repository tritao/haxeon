@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0haxeon.ps1" %*
exit /b %ERRORLEVEL%
