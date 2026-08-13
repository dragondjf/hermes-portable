#!/usr/bin/env bash
# Build a self-contained, offline Hermes Agent portable package on Linux/macOS.
#
# Strategy (faithful to the official installer):
#   1. The official installer has already installed Hermes into $HERMES_HOME
#      (default ~/.hermes): it git-clones the source and `uv pip install -e '.[all]'`
#      into $HERMES_HOME/venv (NOT $HERMES_HOME/hermes-agent/venv). That venv's python is a symlink into
#      uv's shared directory, so it is NOT relocatable on its own.
#   2. We capture the official venv's full dependency set (pip freeze --exclude-editable),
#      build a --copies venv with a bundled CPython (via uv), reinstall the same
#      deps, copy the hermes-agent source tree, then add launcher/install/config.
#      Result is a self-contained, relocatable, offline package.
#
# Env:
#   HERMES_HOME   where the official installer placed Hermes (default ~/.hermes)
#   OUT           output package dir (default: ./hermes-portable)
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
OUT="${OUT:-$PWD/hermes-portable}"
SRC="$HERMES_HOME/hermes-agent"
VENV="$HERMES_HOME/hermes-agent/venv"

echo "==> building hermes-portable from official install at $HERMES_HOME"

if [ ! -d "$VENV" ]; then
  echo "Official Hermes venv not found at $VENV — run the official installer first:" >&2
  echo "  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash" >&2
  exit 1
fi

# 1) capture the official dependency set (pinned versions) from the real venv.
#    Use `uv pip freeze` (not $VENV/bin/pip) because uv-built venvs may lack a
#    standalone pip executable. uv is on PATH (setup-uv in CI).
REQ_TXT="$(mktemp)"
uv pip freeze --python "$VENV/bin/python" --exclude-editable > "$REQ_TXT" 2>/dev/null \
  || "$VENV/bin/python" -m pip freeze --exclude-editable > "$REQ_TXT"
echo "==> captured $(wc -l < "$REQ_TXT") pinned deps from official venv"

# 2) bundle a standalone CPython via uv (so the package needs no external interpreter)
if ! command -v uv >/dev/null 2>&1; then
  echo "uv not found — install it or prepend to PATH"; exit 1
fi
uv python install 3.11 >/dev/null
PY_PREFIX="$(cd "$(dirname "$(uv python find 3.11 --no-project)")/.." && pwd -P)"
echo "==> bundling python from $PY_PREFIX"

rm -rf "$OUT"
mkdir -p "$OUT/runtime" "$OUT/hermes-agent" "$OUT/home"

# 3) copy full standalone CPython runtime (stdlib + bin)
#    Use `cp -aL` (-L = --dereference) so any symlink in uv's python dir
#    (e.g. the cpython-3.11-<arch> symlink, or bin/python3 -> python3.11) is
#    expanded to a real file. Without this the package ends up holding a
#    symlink into uv's shared dir and is NOT self-contained.
cp -aL "$PY_PREFIX" "$OUT/runtime/python"

# 4) copies venv => interpreter is a real file, not a symlink out
"$OUT/runtime/python/bin/python3" -m venv --copies "$OUT/hermes-agent/venv"

# 5) reinstall the same pinned deps into the bundled venv
"$OUT/hermes-agent/venv/bin/pip" install --no-cache-dir -r "$REQ_TXT"

# 6) copy the hermes-agent source tree (drop git/tests/node artifacts)
rsync -a --exclude='.git' --exclude='tests' --exclude='tests-js' \
  --exclude='node_modules' --exclude='dist' --exclude='*.egg-info' \
  --exclude='__pycache__' --exclude='.venv' --exclude='venv' \
  "$SRC/" "$OUT/hermes-agent/"

# 7) re-establish editable install of hermes-agent inside the bundle
#    Use `uv pip install -e` (not venv/bin/pip — uv-built venvs lack a pip exe).
uv pip install --python "$OUT/hermes-agent/venv/bin/python" --no-build-isolation --no-cache-dir \
  -e "$OUT/hermes-agent/"

# 8) placeholder pyvenv.cfg paths; install.sh rewrites at deploy.
#    Placeholder BOTH `home`, `executable` AND `command` so the package is
#    relocatable. __HERMES_RUNTIME_BIN__ is the bundled runtime dir; it is
#    expanded by install.sh to the real (deploy-time) absolute path.
PYVCFG="$OUT/hermes-agent/venv/pyvenv.cfg"
RT="__HERMES_RUNTIME_BIN__"
"$OUT/runtime/python/bin/python3" - "$PYVCFG" "$RT" <<'PY'
import sys, re
p, rt = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
s = re.sub(r'^home = .*', f'home = {rt}/bin', s, flags=re.M)
s = re.sub(r'^executable = .*', f'executable = {rt}/bin/python3.11', s, flags=re.M)
s = re.sub(r'^command = .*', '', s, flags=re.M)
s = re.sub(r'^uv = .*\n', '', s, flags=re.M)
open(p, "w", encoding="utf-8").write(s)
PY

# 9) offline config placeholder (install.sh writes the real one)
printf '# Written by install.sh\n' > "$OUT/home/config.yaml"

# 10) launcher + installer from repo build/ templates
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/install.sh" "$OUT/install.sh"
cp "$SCRIPT_DIR/hermes.sh"  "$OUT/hermes.sh"
chmod +x "$OUT/install.sh" "$OUT/hermes.sh"

# 11) drop pyc so co_filename recompiles under deploy path
find "$OUT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$OUT" -name '*.pyc' -delete 2>/dev/null || true

# 12) bundle uv binary (so managed_uv never downloads)
mkdir -p "$OUT/home/bin"
cp "$(command -v uv)" "$OUT/home/bin/uv" 2>/dev/null || true

rm -f "$REQ_TXT"
echo "==> Done. Package at: $OUT"
