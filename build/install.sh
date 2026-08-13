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

# 1) pyvenv.cfg home -> bundled runtime (fixes 'No module named encodings')
if [ -f "$PYVCFG" ] && grep -q '__HERMES_RUNTIME_BIN__' "$PYVCFG"; then
  sed -i "s#__HERMES_RUNTIME_BIN__#$RT_BIN#" "$PYVCFG"
  echo "    [ok] pyvenv.cfg home -> $RT_BIN"
else
  echo "    [skip] pyvenv.cfg already configured"
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

# 4) rewrite editable metadata absolute path -> deploy path
OLD="$(grep -rhoE '/[a-zA-Z0-9_./-]*/hermes-agent' "$SP/__editable__"*.py 2>/dev/null | head -1 || true)"
if [ -n "$OLD" ] && [ "$OLD" != "$DIR/hermes-agent" ]; then
  for f in "$SP"/__editable__*.py "$SP"/hermes_agent-*.dist-info/direct_url.json; do
    [ -f "$f" ] || continue
    sed -i "s#$OLD#$DIR/hermes-agent#g" "$f"
  done
  echo "    [ok] editable metadata path -> $DIR/hermes-agent"
else
  echo "    [skip] editable metadata already correct"
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
