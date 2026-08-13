#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT_BIN="$DIR/runtime/python/bin"
VENV="$DIR/hermes-agent/venv"
PYVCFG="$VENV/pyvenv.cfg"

echo "==> Hermes portable installer (no root, no network)"
echo "    Package dir: $DIR"

# 1) Fix pyvenv.cfg home -> bundled runtime (absolute, in-package)
if [ -f "$PYVCFG" ]; then
  if grep -q '__HERMES_RUNTIME_BIN__' "$PYVCFG"; then
    sed -i "s#__HERMES_RUNTIME_BIN__#$RT_BIN#" "$PYVCFG"
    echo "    [ok] pyvenv.cfg home -> $RT_BIN"
  else
    echo "    [skip] pyvenv.cfg already configured"
  fi
else
  echo "    [warn] $PYVCFG not found"
fi

# 2) Ensure uv binary present (managed_uv falling back to download is blocked)
mkdir -p "$DIR/home/bin"
if [ ! -x "$DIR/home/bin/uv" ]; then
  if [ -x "$HOME/.hermes/bin/uv" ]; then
    cp -a "$HOME/.hermes/bin/uv" "$DIR/home/bin/uv"
    echo "    [ok] uv copied from $HOME/.hermes/bin"
  else
    echo "    [warn] uv binary missing; update/repair features may need network"
  fi
fi

# 3) Write offline config (idempotent)
cat > "$DIR/home/config.yaml" <<'YAML'
security:
  allow_lazy_installs: false
update:
  check_on_startup: false
telemetry:
  enabled: false
YAML
echo "    [ok] offline config.yaml written"

# 3b) Rewrite editable-install metadata to the real (in-package) source path.
#     The .pth/finder and direct_url.json were generated at BUILD time with the
#     builder's absolute path; leaving them breaks `version`'s "Install directory"
#     and any path resolution that reads direct_url.json.
SP="$DIR/hermes-agent/venv/lib/python3.11/site-packages"
OLD_PATH="$(grep -rhoE '/[a-zA-Z0-9_./-]*/hermes-agent' "$SP/__editable__"*.py 2>/dev/null | head -1)"
if [ -n "$OLD_PATH" ] && [ "$OLD_PATH" != "$DIR/hermes-agent" ]; then
  for f in "$SP"/__editable__*.py "$SP"/hermes_agent-*.dist-info/direct_url.json; do
    [ -f "$f" ] || continue
    sed -i "s#$OLD_PATH#$DIR/hermes-agent#g" "$f"
  done
  echo "    [ok] editable metadata path -> $DIR/hermes-agent"
else
  echo "    [skip] editable metadata already correct"
fi

# 4) Drop precompiled bytecode so co_filename resolves to THIS deploy path
#    (stale .pyc from a different absolute path shows a wrong "Install directory")
find "$DIR" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$DIR" -name '*.pyc' -delete 2>/dev/null || true
echo "    [ok] cleared stale .pyc caches"

# 5) Sanity check
if [ -x "$VENV/bin/python" ]; then
  if "$VENV/bin/python" -c "import hermes_cli" 2>/dev/null; then
    echo "    [ok] hermes_cli importable"
  else
    echo "    [warn] hermes_cli not importable; run with full env to debug"
  fi
fi

echo "==> Done. Run:  bash $DIR/hermes.sh version"
