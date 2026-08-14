@echo off
REM One-shot deploy config for the Hermes portable package (Windows).
REM No admin, no network, idempotent. Run once after unpacking.
REM Mirrors install.ps1 (PowerShell) so users without pwsh can deploy too.

setlocal
set "DIR=%~dp0"
REM Remove trailing backslash for cleaner path joins below.
if "%DIR:~-1%"=="\" set "DIR=%DIR:~0,-1%"

echo ==^> Hermes portable installer (no admin, no network)
echo     Package dir: %DIR%

REM 1) pyvenv.cfg + editable metadata relocation is handled by the shared
REM    _rewrite_paths.py (step 4 below). It forces home/executable to the
REM    bundled runtime and drops the build-path-carrying command/uv lines,
REM    using exact Python string replacement. This is what makes the package
REM    genuinely relocatable (hermes's startup repair won't find a stale build
REM    prefix to restore).
REM
REM    IMPORTANT: we run _rewrite_paths.py with the BUNDLED standalone runtime
REM    python (%DIR%\runtime\python\python.exe), NOT the venv python. The venv
REM    python reads pyvenv.cfg to start, and pyvenv.cfg still holds the
REM    __HERMES_RUNTIME_BIN__ token until that script rewrites it - so the venv
REM    python cannot launch itself. The bundled runtime python has no pyvenv
REM    dependency and starts fine.

REM 2) ensure uv binary present
if not exist "%DIR%\home\bin" mkdir "%DIR%\home\bin"
if not exist "%DIR%\home\bin\uv.exe" (
  where uv >nul 2>nul
  if errorlevel 1 (
    echo     [warn] uv binary missing; update features may need network
  ) else (
    for /f "delims=" %%i in ('where uv') do copy /Y "%%i" "%DIR%\home\bin\uv.exe" >nul 2>nul
    if exist "%DIR%\home\bin\uv.exe" (echo     [ok] uv copied) else (echo     [warn] uv binary missing; update features may need network)
  )
) else (
  echo     [ok] uv already present
)

REM 3) offline config
(
echo security:
echo   allow_lazy_installs: false
echo update:
echo   check_on_startup: false
echo telemetry:
echo   enabled: false
) > "%DIR%\home\config.yaml"
echo     [ok] offline config.yaml written

REM 4) rewrite editable metadata + pyvenv.cfg absolute path -> deploy path
REM    (token -> real) via the BUNDLED runtime python.
set "RW=%DIR%\home\bin\_rewrite_paths.py"
set "RTPY=%DIR%\runtime\python\python.exe"
if exist "%RW%" (
  if not exist "%RTPY%" (
    echo     [FAIL] bundled runtime python not found at %RTPY%
    exit /b 1
  )
  "%RTPY%" "%RW%" install "%DIR%"
  if errorlevel 1 (
    echo     [FAIL] editable metadata/pyvenv relocation failed
    exit /b 1
  )
  echo     [ok] editable metadata + pyvenv.cfg relocated + verified
) else (
  echo     [warn] _rewrite_paths.py missing; editable metadata may keep build path
)

REM 5) clear stale pyc
for /d /r "%DIR%" %%d in (__pycache__) do if exist "%%d" rmdir /s /q "%%d" 2>nul
del /s /q "%DIR%\*.pyc" >nul 2>nul
echo     [ok] cleared stale .pyc caches

REM 6) sanity
"%DIR%\hermes-agent\venv\Scripts\python.exe" -c "import hermes_cli" >nul 2>nul
if errorlevel 1 (
  echo     [warn] hermes_cli not importable; debug with full env
) else (
  echo     [ok] hermes_cli importable
)

echo ==^> Done. Run:  %DIR%\hermes.bat version
endlocal
