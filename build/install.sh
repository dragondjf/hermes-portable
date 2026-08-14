#!/usr/bin/env bash
# One-shot deploy config for the Hermes portable package.
# No root, no network, idempotent. Run once after unpacking.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT_BIN="$DIR/runtime/python/bin"
VENV="$DIR/hermes-agent/venv"
PYVCFG="$VENV/pyvenv.cfg"
SP="$VENV/lib/python3.11/site-packages"

echo "==> Hermes portable installer (no root, no network)"
echo "    Package dir: $DIR"

# 1) pyvenv.cfg -> bundled runtime (fixes 'No module named encodings' and makes
#    the package relocatable). Rewrite UNCONDITIONALLY: the build may have left a
#    __HERMES_RUNTIME_BIN__ placeholder OR a stale build-machine absolute path.
#    Do NOT use $VENV/bin/python here — pyvenv.cfg may still point outside the
#    package, so that interpreter cannot start yet. Use sed -i.bak (GNU + BSD).
RT_BIN="$DIR/runtime/python/bin"
if [ -f "$PYVCFG" ]; then
  sed -i.bak "s#__HERMES_RUNTIME_BIN__#$RT_BIN#g" "$PYVCFG"
  sed -i.bak -E "s#^home = .*#home = $RT_BIN#" "$PYVCFG"
  sed -i.bak -E "s#^executable = .*#executable = $RT_BIN/python3.11#" "$PYVCFG"
  sed -i.bak -E "/^command = /d" "$PYVCFG"
  sed -i.bak -E "/^uv = /d" "$PYVCFG"
  rm -f "$PYVCFG.bak"
  echo "    [ok] pyvenv.cfg -> bundled runtime $RT_BIN"
else
  echo "    [warn] pyvenv.cfg missing"
fi

# 2) ensure uv binary present
mkdir -p "$DIR/home/bin"
if [ ! -x "$DIR/home/bin/uv" ]; then
  if [ -x "$HOME/.hermes/bin/uv" ]; then
    cp -a "$HOME/.hermes/bin/uv" "$DIR/home/bin/uv"
    echo "    [ok] uv copied from $HOME/.hermes/bin"
  else
    echo "    [warn] uv binary missing; update/repair features may need network"
  fi
fi

# 3) offline config
cat > "$DIR/home/config.yaml" <<'YAML'
security:
  allow_lazy_installs: false
update:
  check_on_startup: false
telemetry:
  enabled: false
YAML
echo "    [ok] offline config.yaml written"

# 4) rewrite editable metadata absolute path -> deploy path (shared script)
#    Uses the same _rewrite_paths.py as Windows for identical, testable behavior.
RW="$DIR/home/bin/_rewrite_paths.py"
if [ -f "$RW" ]; then
  "$VENV/bin/python" "$RW" install "$DIR"
  # verify no build path remains
  if grep -rIl -E 'D:\\\\a\\\\hermes-portable|D:/a/hermes-portable|/home/runner|/Users/runneradmin|__HERMES_PKG_ROOT__' "$SP" 2>/dev/null | grep -qE '__editable__|direct_url'; then
    echo "    [FAIL] editable metadata still has build path" >&2
    exit 1
  fi
  echo "    [ok] editable metadata relocated + verified"
else
  echo "    [warn] _rewrite_paths.py missing; editable metadata may keep build path"
fi

# 5) clear stale pyc (recompile under deploy path)
find "$DIR" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$DIR" -name '*.pyc' -delete 2>/dev/null || true
echo "    [ok] cleared stale .pyc caches"

# 6) sanity
if [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c "import hermes_cli" 2>/dev/null; then
  echo "    [ok] hermes_cli importable"
else
  echo "    [warn] hermes_cli not importable; debug with full env"
fi

echo "==> Done. Run:  bash $DIR/hermes.sh version"
