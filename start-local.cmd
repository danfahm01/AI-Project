@echo off
rem Runs the app on this computer (API + web app at http://localhost:8000).
rem Double-click it, or run it from a terminal. Options are passed on:
rem   start-local.cmd -Port 8080
rem   start-local.cmd -RebuildWeb
rem   start-local.cmd -AddKey      (add a Gemini or OpenAI key, e.g. for voice mode)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-local.ps1" %*
if errorlevel 1 pause
