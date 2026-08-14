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

# 1) pyvenv.cfg -> bundled runtime (fixes 'No module named encodings' and makes
#    the package relocatable). The bundled base python lives at
#    $DIR\runtime\python\python.exe (uv installs it there; build copies it to
#    python.exe). Rewrite UNCONDITIONALLY: the build may have left a
#    __HERMES_RUNTIME_BIN__ placeholder OR a stale build-machine absolute path,
#    and we must not skip when the path is wrong. (Same fix as install.sh.)
$RT = "$DIR\runtime\python"
if (Test-Path $PYVCFG) {
  $txt = gc $PYVCFG
  # First expand any leftover token, then force the home/executable lines so a
  # stale build path can never survive.
  $txt = $txt -replace '__HERMES_RUNTIME_BIN__', $RT
  $txt = $txt -replace '^home = .*', "home = $RT"
  $txt = $txt -replace '^executable = .*', "executable = $RT\python.exe"
  $txt = $txt -replace '^command = .*', ''
  $txt = $txt -replace '^uv = .*', ''
  $txt | sc $PYVCFG
  # Hard guard: if a token or the CI build path survives, the package is NOT
  # relocatable. Fail loudly instead of shipping a broken pyvenv.cfg.
  $chk = gc $PYVCFG -Raw
  if ($chk -match '__HERMES_RUNTIME_BIN__' -or $chk -match 'D:/a/hermes-portable') {
    Write-Error "FAIL: pyvenv.cfg still has token/build path after rewrite"; exit 1
  }
  Write-Host "    [ok] pyvenv.cfg -> bundled runtime $RT"
} else { Write-Host "    [warn] pyvenv.cfg missing" }

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

# 4) rewrite editable metadata absolute path -> deploy path (token -> real)
#    _rewrite_paths.py install mode also verifies (fails if a non-deploy
#    absolute path remains). Abort the installer on failure.
$RW = "$DIR\home\bin\_rewrite_paths.py"
if (Test-Path $RW) {
  & "$VENV\Scripts\python.exe" $RW install "$DIR"
  if ($LASTEXITCODE -ne 0) { Write-Error "FAIL: editable metadata relocation/verify failed"; exit 1 }
  Write-Host "    [ok] editable metadata relocated + verified"
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
