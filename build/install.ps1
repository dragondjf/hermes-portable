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
#    the package relocatable). Rewrite UNCONDITIONALLY: the build may have left a
#    __HERMES_RUNTIME_BIN__ placeholder OR a stale build-machine absolute path,
#    and we must not skip when the path is wrong. (Same fix as install.sh on unix.)
if (Test-Path $PYVCFG) {
  $txt = gc $PYVCFG
  $txt = $txt -replace '__HERMES_RUNTIME_BIN__', $RT_BIN
  $txt = $txt -replace '^home = .*', "home = $RT_BIN"
  $txt = $txt -replace '^executable = .*', "executable = $RT_BIN\python.exe"
  $txt = $txt -replace '^command = .*', ''
  $txt = $txt -replace '^uv = .*', ''
  $txt | sc $PYVCFG
  Write-Host "    [ok] pyvenv.cfg -> bundled runtime $RT_BIN"
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

# 4) rewrite editable metadata absolute path -> deploy path (robust, mirrors install.sh)
#    The editable finder records the hermes-agent source dir; on relocation it must
#    point at the deployed copy. Use Python so deep paths (D:\a\...\hermes-agent) and
#    both MAPPING/NAMESPACES entries are rewritten, and bytes are preserved.
$rewritePy = Join-Path $DIR "home\bin\_rewrite_editable.py"
New-Item -ItemType Directory -Force -Path (Split-Path $rewritePy) | Out-Null
@'
import os, glob, re, sys
DIR, SP = sys.argv[1], sys.argv[2]
target = os.path.join(DIR, "hermes-agent").replace("\\", "/")
changed = []
for pat in (os.path.join(SP, "__editable__*.py"),
            os.path.join(SP, "hermes_agent-*.dist-info", "direct_url.json")):
    for f in glob.glob(pat):
        t = open(f, encoding="utf-8").read()
        m = re.search(r"[A-Za-z]:[\\/].+?[\\/]hermes-agent", t)
        if not m:
            continue
        old = m.group(0).replace("\\", "/")
        if old == target:
            continue
        open(f, "w", encoding="utf-8").write(t.replace(old, target))
        changed.append(f)
if changed:
    print("    [ok] editable metadata path -> " + target)
else:
    print("    [skip] editable metadata already correct")
'@ | Set-Content -NoNewline $rewritePy
& "$VENV\Scripts\python.exe" $rewritePy "$DIR" "$SP"
Remove-Item -Force $rewritePy -ErrorAction SilentlyContinue

# 5) clear stale pyc
Get-ChildItem -Recurse -Force -Path $DIR -Directory -Filter __pycache__ | Remove-Item -Recurse -Force
Get-ChildItem -Recurse -Force -Path $DIR -Filter *.pyc | Remove-Item -Force
Write-Host "    [ok] cleared stale .pyc caches"

# 6) sanity
if (& "$VENV\Scripts\python.exe" -c "import hermes_cli" 2>$null) { Write-Host "    [ok] hermes_cli importable" }
else { Write-Host "    [warn] hermes_cli not importable; debug with full env" }

Write-Host "==> Done. Run:  pwsh $DIR\hermes.ps1 version"
