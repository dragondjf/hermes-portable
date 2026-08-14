@echo off
REM Launcher (Windows, cmd.exe): sets HERMES_HOME + PATH, runs the agent.
REM Mirrors hermes.ps1 so users without pwsh can launch Hermes.
setlocal
set "DIR=%~dp0"
if "%DIR:~-1%"=="\" set "DIR=%DIR:~0,-1%"

set "HERMES_HOME=%DIR%\home"
set "PATH=%DIR%\home\bin;%DIR%\hermes-agent\venv\Scripts;%PATH%"

"%DIR%\hermes-agent\venv\Scripts\python.exe" -m hermes_cli.main %*
endlocal
