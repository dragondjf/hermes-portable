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
PY_VER="${PY_VER:-3.14}"            # bundled CPython minor — must match the official
                                    # PM pin era (pm/lock.json pins 3.14.7 for v0.21.6,
                                    # and dependency pins carry python_version>='3.14'
                                    # markers, so 3.11-3.13 bundles would miss deps)
SRC="$HERMES_HOME/hermes-agent"

# v0.21+ (PM era): the official installer's dependency venv lives OUTSIDE the
# checkout, under <HERMES_HOME>/installs/<install-key>/environments/<gen>/ —
# and PM DELETES the legacy in-tree hermes-agent/venv once it commits a
# generation. Discover the PM venv (a fresh official install has exactly one);
# fall back to the legacy in-tree venv for pre-PM (v0.20.x) installs.
VENV=""
for _cfg in "$HERMES_HOME"/installs/*/environments/*/pyvenv.cfg; do
  [ -f "$_cfg" ] || continue
  VENV="$(dirname "$_cfg")"
  break
done
[ -n "$VENV" ] || VENV="$SRC/venv"

echo "==> building hermes-portable (Python $PY_VER) from official install at $HERMES_HOME"
echo "==> official dependency venv: $VENV"

if [ ! -d "$VENV" ]; then
  echo "Official Hermes venv not found (looked in $HERMES_HOME/installs/*/environments/*/ and $SRC/venv)" >&2
  echo "— run the official installer first:" >&2
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
uv python install "$PY_VER" >/dev/null
PY_PREFIX="$(cd "$(dirname "$(uv python find "$PY_VER" --no-project)")/.." && pwd -P)"
echo "==> bundling python $PY_VER from $PY_PREFIX"

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

# 5b) build backend for the editable install: --no-build-isolation imports the
#     backend from the target venv, and pyproject pins setuptools==83.0.0 +
#     wheel. Python 3.12+ venvs no longer seed setuptools via ensurepip, and
#     the freeze may not carry them, so install explicitly (idempotent).
"$OUT/hermes-agent/venv/bin/pip" install --no-cache-dir "setuptools==83.0.0" wheel

# 6) copy the hermes-agent source tree (drop git/tests/node artifacts)
rsync -a --exclude='.git' --exclude='tests' --exclude='tests-js' \
  --exclude='node_modules' --exclude='dist' --exclude='*.egg-info' \
  --exclude='__pycache__' --exclude='.venv' --exclude='venv' \
  "$SRC/" "$OUT/hermes-agent/"

# 7) re-establish editable install of hermes-agent inside the bundle
#    Use `uv pip install -e` (not venv/bin/pip — uv-built venvs lack a pip exe).
uv pip install --python "$OUT/hermes-agent/venv/bin/python" --no-build-isolation --no-cache-dir \
  -e "$OUT/hermes-agent/"

# 8) pyvenv.cfg build-path placeholder is handled by the shared
#    _rewrite_paths.py in build mode (step 8b below), which tokenizes
#    home/executable/command/uv using exact string replacement that is
#    version-agnostic (no hardcoded python3.11). install.sh/.ps1 relocates
#    them at deploy time. The inline re.sub here was removed to avoid the
#    hardcoded minor-version suffix that broke 3.12/3.13.

# 9) offline config placeholder (install.sh writes the real one)
printf '# Written by install.sh\n' > "$OUT/home/config.yaml"

# 10) launcher + installer + shared rewrite script from repo build/ templates
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/install.sh" "$OUT/install.sh"
cp "$SCRIPT_DIR/hermes.sh"  "$OUT/hermes.sh"
mkdir -p "$OUT/home/bin"
cp "$SCRIPT_DIR/_rewrite_paths.py" "$OUT/home/bin/_rewrite_paths.py"
chmod +x "$OUT/install.sh" "$OUT/hermes.sh"

# 8b) tokenize editable metadata (build mode) — removes ALL absolute paths from
#     the published package per the green-package requirement (zero absolute
#     paths in the artifact; install.sh relocates at deploy).
"$OUT/runtime/python/bin/python3" "$OUT/home/bin/_rewrite_paths.py" build "$OUT"

# 11) drop pyc so co_filename recompiles under deploy path
find "$OUT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$OUT" -name '*.pyc' -delete 2>/dev/null || true

# 12) bundle uv binary (so managed_uv never downloads)
mkdir -p "$OUT/home/bin"
cp "$(command -v uv)" "$OUT/home/bin/uv" 2>/dev/null || true

rm -f "$REQ_TXT"
echo "==> Done. Package at: $OUT"
