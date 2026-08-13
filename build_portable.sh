#!/usr/bin/env bash
# Build a self-contained, offline-capable Hermes Agent portable package.
# All artifacts live under $OUT (a user directory). No root, no system dirs,
# no network at runtime. Python interpreter is copied (--copies) so the venv
# no longer depends on uv's shared python directory.
set -euo pipefail

SRC_AGENT="$HOME/.hermes/hermes-agent"
BASE_PYTHON="$(ls -d "$HOME/.local/share/uv/python/cpython-3.11"*/ 2>/dev/null | head -1)"
if [ -z "$BASE_PYTHON" ]; then
  echo "ERROR: uv-managed python not found under $HOME/.local/share/uv/python/" >&2
  exit 1
fi
BASE_PYTHON="${BASE_PYTHON%/}"
OUT="$HOME/hermes-portable"

echo "==> Source agent : $SRC_AGENT"
echo "==> Base python  : $BASE_PYTHON"
echo "==> Output dir   : $OUT"

# 1. Clean + scaffold
rm -rf "$OUT"
mkdir -p "$OUT/runtime" "$OUT/hermes-agent" "$OUT/home"

# 2. Copy the full CPython runtime (stdlib + bin) so venv's symlinks resolve
echo "==> Copying CPython runtime (self-contained) ..."
cp -a "$BASE_PYTHON" "$OUT/runtime/python"

# 3. Create a copies venv so the interpreter is a real file, not a symlink out
echo "==> Creating --copies venv ..."
"$OUT/runtime/python/bin/python3.11" -m venv --copies "$OUT/hermes-agent/venv"

# 4. Copy agent source tree (drop git/tests/node artifacts)
echo "==> Copying agent source ..."
rsync -a --exclude='.git' --exclude='tests' --exclude='tests-js' \
  --exclude='node_modules' --exclude='dist' --exclude='*.egg-info' \
  --exclude='__pycache__' --exclude='.venv' --exclude='venv' \
  "$SRC_AGENT/" "$OUT/hermes-agent/"

# 5. Editable install (Hermes blocks wheel/sdist builds; editable only writes
#    an .egg-link / __editable__ finder, no compilation, works offline).
echo "==> Installing hermes (editable, offline) ..."
"$OUT/hermes-agent/venv/bin/pip" install --no-build-isolation --no-cache-dir \
  -e "$OUT/hermes-agent/"

# 6. Placeholder pyvenv.cfg home; install.sh rewrites it to the real
#    (absolute, in-package) path at deploy time. A relative/absent home makes
#    a copied interpreter resolve prefix against the build path and crash with
#    "No module named 'encodings'". install.sh always knows its own dir, so it
#    sets the correct absolute path on the target machine.
PYVCFG="$OUT/hermes-agent/venv/pyvenv.cfg"
if [ -f "$PYVCFG" ]; then
  sed -i "s#^home = .*#home = __HERMES_RUNTIME_BIN__#" "$PYVCFG" || true
  sed -i '/^uv = /d' "$PYVCFG" || true
fi

# 7. Bundle the uv binary so managed_uv() never tries to download
mkdir -p "$OUT/home/bin"
if [ -x "$HOME/.hermes/bin/uv" ]; then
  cp -a "$HOME/.hermes/bin/uv" "$OUT/home/bin/uv"
fi

# 8. Offline config placeholder; install.sh writes the real offline config.
mkdir -p "$OUT/home"
cat > "$OUT/home/config.yaml" <<'EOF'
# Written by install.sh — offline defaults.
EOF

# 9. Launcher (no hardcoded absolute paths; resolves its own dir)
cat > "$OUT/hermes.sh" <<'EOF'
#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HERMES_HOME="$DIR/home"
export PATH="$DIR/home/bin:$DIR/hermes-agent/venv/bin:$PATH"
exec "$DIR/hermes-agent/venv/bin/python" -m hermes_cli.main "$@"
EOF
chmod +x "$OUT/hermes.sh"

# 10. install.sh: one-shot deploy config inside the package dir.
#     - rewrites pyvenv.cfg home to the in-package runtime (fixes encodings crash)
#     - ensures uv binary present
#     - writes offline config.yaml
#     - no root, no system dirs, idempotent
cat > "$OUT/install.sh" <<'EOF'
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
EOF
chmod +x "$OUT/install.sh"

# 11. Drop precompiled bytecode: .pyc files bake the SOURCE absolute path into
#     co_filename, which surfaces as a stale "Install directory" in `version`.
#     Removing them forces runtime recompile under the correct deploy path.
echo "==> Removing precompiled .pyc caches (recompile at runtime) ..."
find "$OUT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$OUT" -name '*.pyc' -delete 2>/dev/null || true

echo "==> Done. Package at: $OUT"
echo "==> Deploy:  cd hermes-portable && bash install.sh"
echo "==> Run:     bash hermes.sh version"
