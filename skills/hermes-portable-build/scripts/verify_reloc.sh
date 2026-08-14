#!/usr/bin/env bash
# Verify the built Hermes portable package is a TRUE green package:
#   - relocatable: runs from a NON-standard path (copied out of the build dir)
#   - offline:     no external network connect() under a wiped env
#   - isolated:    no writes to system dirs (/etc /usr /opt /root /var)
#   - functional:  `hermes.sh version` shows the deploy path, kanban persists
#
# Designed to run inside CI (after `tar xzf`/unpack) with only the package dir
# as input. Mirrors build/verify_reloc.ps1 on Windows.
set -euo pipefail

PKG="${1:-$PWD/hermes-portable}"
[ -d "$PKG" ] || { echo "ERROR: package dir not found: $PKG"; exit 1; }
# Normalize: macOS symlinks /tmp -> /private/tmp, so compare against the real path.
PKG="$(cd "$PKG" && pwd -P)"

echo "==> relocatability test: deploy to a different path and run with wiped env"
RELOC=/tmp/hermes-reloc-test
rm -rf "$RELOC"
mkdir -p "$RELOC"
cp -a "$PKG/." "$RELOC/hermes-portable/"
PKG="$RELOC/hermes-portable"
# Re-normalize: on macOS /tmp -> /private/tmp, and hermes reports the real path.
PKG="$(cd "$PKG" && pwd -P)"

bash "$PKG/install.sh"

FRESH="$PKG/home-fresh"
rm -rf "$FRESH"; cp -a "$PKG/home" "$FRESH"

RUN="env -i HOME=$FRESH HERMES_HOME=$FRESH PATH=$PKG/hermes-agent/venv/bin:/usr/bin:/bin bash $PKG/hermes.sh"

echo "==> version (must show deploy Install directory, not the build path)"
OUT=$($RUN version 2>&1)
echo "$OUT"
echo "$OUT" | grep -q "Install directory: $PKG/hermes-agent" || { echo "FAIL: Install directory not the deploy path"; exit 1; }
echo "$OUT" | grep -q "Hermes Agent v" || { echo "FAIL: version not printed"; exit 1; }

echo "==> strace: assert no external network + no system-dir writes"
TRACE=/tmp/hermes-reloc-trace.txt
rm -f "$TRACE"
if command -v strace >/dev/null 2>&1; then
  strace -f -e trace=network,file -o "$TRACE" $RUN version >/dev/null 2>&1 || true
  if [ -f "$TRACE" ]; then
    # NOTE: under `set -o pipefail` an empty grep returns 1, so guard with || true.
    # `wc -l` pads with spaces on BSD/macOS — trim it.
    EXT=$(grep 'connect(' "$TRACE" | grep -vE 'AF_UNIX|127\.0\.0\.1|::1' | wc -l | tr -d ' ' || true)
    SYS=$(grep -E 'openat.*(O_WRONLY|O_CREAT|O_RDWR).*(/etc/|/usr/|/opt/|/root/|/var/)' "$TRACE" | wc -l | tr -d ' ' || true)
    echo "external connect()  = $EXT (must be 0)"
    echo "system-dir writes   = $SYS (must be 0)"
    [ "$EXT" = "0" ] || { echo "FAIL: package made external network calls"; exit 1; }
    [ "$SYS" = "0" ] || { echo "FAIL: package wrote to system dirs"; exit 1; }
  else
    echo "    [warn] strace produced no trace file; skipping network assertion"
  fi
else
  echo "    [warn] strace unavailable on this platform; skipping network assertion"
fi

echo "==> functional offline test (kanban SQLite persists)"
$RUN kanban init >/dev/null 2>&1 || true
$RUN kanban create "离线测试任务" --body "verify green package" 2>&1 | tail -1
$RUN kanban list 2>&1 | grep -q "离线测试任务" || { echo "FAIL: kanban task not persisted"; exit 1; }

echo "==> ALL GREEN-PACKAGE CHECKS PASSED"
