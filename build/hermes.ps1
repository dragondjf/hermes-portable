# Launcher (Windows): sets HERMES_HOME + PATH, runs the agent.
$ErrorActionPreference = 'Stop'
$DIR = Split-Path $MyInvocation.MyCommand.Path
$env:HERMES_HOME = "$DIR\home"
$env:PATH = "$DIR\home\bin;$DIR\hermes-agent\venv\Scripts;$env:PATH"
& "$DIR\hermes-agent\venv\Scripts\python.exe" -m hermes_cli.main @args
