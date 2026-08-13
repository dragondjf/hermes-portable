# Verify the built Hermes portable package is a TRUE green package (Windows).
# Mirrors build/verify_reloc.sh (Linux/macOS). Windows has no strace, so we
# assert relocatability + correct deploy paths + offline config + a functional
# kanban round-trip, and that NO build-machine absolute path leaked into the
# package (which would break relocation).
param(
  [string]$PackageDir = (Join-Path $PWD "hermes-portable")
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $PackageDir)) { Write-Error "package dir not found: $PackageDir"; exit 1 }

Write-Host "==> relocatability test: deploy to a different path"
$RELOC = Join-Path $env:TEMP "hermes-reloc-test"
Remove-Item -Recurse -Force $RELOC -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $RELOC | Out-Null
Copy-Item -Recurse -Force "$PackageDir\*" (Join-Path $RELOC "hermes-portable")
$PKG = Join-Path $RELOC "hermes-portable"

& "$PKG\install.ps1"

$FRESH = Join-Path $PKG "home-fresh"
Remove-Item -Recurse -Force $FRESH -ErrorAction SilentlyContinue
Copy-Item -Recurse -Force (Join-Path $PKG "home") $FRESH

$env:HOME = $FRESH
$env:HERMES_HOME = $FRESH
$env:PATH = "$(Join-Path $PKG 'hermes-agent\venv\Scripts');$env:SystemRoot\System32"

Write-Host "==> version (must show deploy Install directory, not the build path)"
$OUT = & "$PKG\hermes.ps1" version 2>&1 | Out-String
Write-Host $OUT
if ($OUT -notmatch [regex]::Escape("Install directory: $PKG\hermes-agent")) {
  Write-Error "FAIL: Install directory not the deploy path"; exit 1
}
if ($OUT -notmatch 'Hermes Agent v') { Write-Error "FAIL: version not printed"; exit 1 }

Write-Host "==> assert no build-machine absolute path leaked (relocation safety)"
$BAD = Get-ChildItem -Recurse -Force $PKG -File |
  Where-Object { $_.Name -match 'pyvenv\.cfg|__editable__|direct_url\.json|.*\.pth$' } |
  ForEach-Object { $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue; if ($c -match '/home/runner|/Users/runneradmin|C:\\Users\\runneradmin|/root/') { $_.FullName } }
if ($BAD) { Write-Error "FAIL: build-machine path leaked in:`n$BAD"; exit 1 }

Write-Host "==> functional offline test (kanban SQLite persists)"
& "$PKG\hermes.ps1" kanban init 2>&1 | Out-Null
& "$PKG\hermes.ps1" kanban create "离线测试任务" --body "verify green package" 2>&1 | Out-String | Write-Host
$LIST = & "$PKG\hermes.ps1" kanban list 2>&1 | Out-String
if ($LIST -notmatch '离线测试任务') { Write-Error "FAIL: kanban task not persisted"; exit 1 }

Write-Host "==> ALL GREEN-PACKAGE CHECKS PASSED"
