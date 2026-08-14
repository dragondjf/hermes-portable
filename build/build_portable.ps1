# Build a self-contained, offline Hermes Agent portable package on Windows.
# Strategy (faithful to the official installer):
#   1. The official installer has already installed Hermes into $env:HERMES_HOME
#      (default %LOCALAPPDATA%\hermes): it git-clones the source and
#      `uv pip install -e '.[all]'` into $env:HERMES_HOME\venv (NOT hermes-agent\venv).
#      That venv's python is a symlink into uv's shared dir, so it is NOT
#      relocatable on its own.
#   2. We capture the official venv's full dependency set (pip freeze
#      --exclude-editable), build a --copies venv with a bundled CPython (via
#      uv), reinstall the same deps, copy the hermes-agent source tree, then add
#      launcher/install/config. Result is a self-contained, relocatable, offline
#      package.
param(
  [string]$HermesHome = $(if ($env:HERMES_HOME) { $env:HERMES_HOME } else { "$env:LOCALAPPDATA\hermes" }),
  [string]$Out = (Join-Path $PWD "hermes-portable")
)

$ErrorActionPreference = 'Stop'
$SRC = Join-Path $HermesHome "hermes-agent"
$VENV = Join-Path $SRC "venv"
Write-Host "==> building hermes-portable from official install at $HermesHome"

if (-not (Test-Path $VENV)) {
  Write-Error "Official Hermes venv not found at $VENV — run the official installer first: iex (irm https://hermes-agent.nousresearch.com/install.ps1)"
  exit 1
}
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { Write-Error "uv not found"; exit 1 }

# 1) capture the official dependency set (pinned versions)
#    Use `uv pip freeze` (not $VENV\Scripts\pip.exe) because uv-built venvs may
#    lack a standalone pip executable. uv is on PATH (setup-uv in CI).
$req = Join-Path $env:TEMP "hermes-reqs.txt"
uv pip freeze --python "$VENV\Scripts\python.exe" --exclude-editable | Out-File -Encoding utf8 $req
Write-Host "==> captured deps from official venv"

# 2) bundle a standalone CPython via uv
uv python install 3.11 | Out-Null
$pyBin = (uv python find 3.11 --no-project).Trim()
# $pyBin is .../cpython-3.11.15-windows-x86_64-none/python3.11.exe; the runtime
# dir we bundle is its parent (one level up), which holds python3.11.exe.
$pyPrefix = Split-Path $pyBin
Write-Host "==> bundling python from $pyPrefix"

Remove-Item -Recurse -Force $Out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Out, "$Out\runtime", "$Out\hermes-agent", "$Out\home" | Out-Null

# 3) copy full standalone CPython runtime
$pyDest = "$Out\runtime\python"
if (Test-Path $pyDest) { Remove-Item -Recurse -Force $pyDest }
New-Item -ItemType Directory -Force -Path $pyDest | Out-Null
Copy-Item -Recurse -Force "$pyPrefix\*" $pyDest
# uv installs the interpreter as python3.11.exe (no plain python.exe); venv needs
# python.exe, so create a copy/alias of the real binary.
$realPy = Get-ChildItem "$pyDest\python3*.exe" | Select-Object -First 1
if ($realPy -and -not (Test-Path "$pyDest\python.exe")) {
  Copy-Item $realPy.FullName "$pyDest\python.exe"
}

# 4) copies venv => interpreter is a real file, not a symlink out
& "$Out\runtime\python\python.exe" -m venv --copies "$Out\hermes-agent\venv"

# 5) reinstall the same pinned deps into the bundled venv
& "$Out\hermes-agent\venv\Scripts\pip.exe" install --no-cache-dir -r $req

# 6) copy the hermes-agent source tree (drop git/tests/node artifacts)
$excl = @('.git','tests','tests-js','node_modules','dist','*.egg-info','__pycache__','.venv','venv')
robocopy "$SRC" "$Out\hermes-agent" /E /XD $excl /XF *.pyc | Out-Null

# 7) re-establish editable install of hermes-agent inside the bundle
& "$Out\hermes-agent\venv\Scripts\pip.exe" install --no-build-isolation --no-cache-dir -e "$Out\hermes-agent"

# 8) placeholder pyvenv.cfg build paths; editable metadata + pyvenv.cfg are
#    tokenized in step 8b via the shared _rewrite_paths.py (build mode) so the
#    published package has ZERO absolute paths. install.ps1/.sh rewrites them at
#    deploy time (and drops the build-path-carrying command/uv lines). Done in
#    Python (not PowerShell -replace) because exact string replacement is the
#    only reliable approach across platforms/escaping.
#    NOTE: PowerShell is case-INsensitive, so a local `$out` would clobber the
#    `$Out` output-dir param. Use a distinctly-named buffer.

# 10) launcher + installer + shared rewrite script from repo build/ templates
#     Resolve the build/ dir relative to the repo root. $PWD is the directory
#     pwsh was launched in (the checked-out repo root on CI) and is reliable.
$scriptDir = Join-Path $PWD.Path 'build'
Write-Host "==> scriptDir = $scriptDir"
Copy-Item "$scriptDir\install.ps1" "$Out\install.ps1"
Copy-Item "$scriptDir\hermes.ps1"  "$Out\hermes.ps1"
New-Item -ItemType Directory -Force -Path "$Out\home\bin" | Out-Null
Copy-Item "$scriptDir\_rewrite_paths.py" "$Out\home\bin\_rewrite_paths.py"

# 8b) tokenize editable metadata (build mode) — removes ALL absolute paths from
#     the published package per the green-package requirement.
& "$Out\runtime\python\python.exe" "$Out\home\bin\_rewrite_paths.py" build "$Out"

# 11) drop pyc
Get-ChildItem -Recurse -Force -Path $Out -Directory -Filter __pycache__ | Remove-Item -Recurse -Force
Get-ChildItem -Recurse -Force -Path $Out -Filter *.pyc | Remove-Item -Force

# 12) bundle uv binary
New-Item -ItemType Directory -Force -Path "$Out\home\bin" | Out-Null
Copy-Item (Get-Command uv).Source "$Out\home\bin\uv.exe"

Remove-Item $req -ErrorAction SilentlyContinue
Write-Host "==> Done. Package at: $Out"
