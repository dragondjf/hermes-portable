# One-shot deploy config for the Hermes portable package (Windows).
# No admin, no network, idempotent. Run once after unpacking.
$ErrorActionPreference = 'Stop'
$DIR = Split-Path $MyInvocation.MyCommand.Path
$RT_BIN = "$DIR\runtime\python\Scripts"
$VENV = "$DIR\hermes-agent\venv"
$PYVCFG = "$VENV\pyvenv.cfg"
$SP = "$VENV\Lib\site-packages"

Write-Host "==> Hermes portable installer (no admin, no network)"
Write-Host "    Package dir: $DIR"

# 1) pyvenv.cfg relocation is handled by the shared _rewrite_paths.py (called in
#    step 4 below) — it forces home/executable to the bundled runtime and drops
#    the build-path-carrying command/uv lines, using exact Python string
#    replacement (reliable across platforms, unlike PowerShell -replace). This is
#    what makes the package genuinely relocatable (hermes's startup repair won't
#    find a stale build prefix to restore).

# 2) ensure uv binary present
New-Item -ItemType Directory -Force -Path "$DIR\home\bin" | Out-Null
if (-not (Test-Path "$DIR\home\bin\uv.exe")) {
  $src = (Get-Command uv -ErrorAction SilentlyContinue).Source
  if ($src) { Copy-Item $src "$DIR\home\bin\uv.exe"; Write-Host "    [ok] uv copied" }
  else { Write-Host "    [warn] uv binary missing; update features may need network" }
}

# 3) offline config
@'
security:
  allow_lazy_installs: false
update:
  check_on_startup: false
telemetry:
  enabled: false
'@ | sc "$DIR\home\config.yaml"
Write-Host "    [ok] offline config.yaml written"

# 4) rewrite editable metadata + pyvenv.cfg absolute path -> deploy path
#    (token -> real). Done by the SHARED _rewrite_paths.py. CRITICAL: run it with
#    the BUNDLED standalone runtime python ($DIR\runtime\python\python.exe), NOT
#    the venv python. The venv python reads pyvenv.cfg to start, and pyvenv.cfg
#    still holds the __HERMES_RUNTIME_BIN__ token until this script rewrites it —
#    so the venv python cannot launch itself. The bundled runtime python is a
#    standalone interpreter (no pyvenv dependency) and starts fine; _rewrite_paths
#    fixes pyvenv.cfg first, then the editable metadata, and verifies both.
#    (On Unix, install.sh step 1 fixes pyvenv.cfg with sed before step 4; on
#    Windows we route the whole fix through this bundled-python call instead.)
$RW = "$DIR\home\bin\_rewrite_paths.py"
$RTPY = "$DIR\runtime\python\python.exe"
if (Test-Path $RW) {
  if (-not (Test-Path $RTPY)) { Write-Error "FAIL: bundled runtime python not found at $RTPY"; exit 1 }
  & "$RTPY" $RW install "$DIR"
  if ($LASTEXITCODE -ne 0) { Write-Error "FAIL: editable metadata/pyvenv relocation failed"; exit 1 }
  Write-Host "    [ok] editable metadata + pyvenv.cfg relocated + verified"
} else {
  Write-Host "    [warn] _rewrite_paths.py missing; editable metadata may keep build path"
}

# 5) clear stale pyc
Get-ChildItem -Recurse -Force -Path $DIR -Directory -Filter __pycache__ | Remove-Item -Recurse -Force
Get-ChildItem -Recurse -Force -Path $DIR -Filter *.pyc | Remove-Item -Force
Write-Host "    [ok] cleared stale .pyc caches"

# 6) sanity
if (& "$VENV\Scripts\python.exe" -c "import hermes_cli" 2>$null) { Write-Host "    [ok] hermes_cli importable" }
else { Write-Host "    [warn] hermes_cli not importable; debug with full env" }

Write-Host "==> Done. Run:  pwsh $DIR\hermes.ps1 version"
