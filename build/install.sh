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

PY="$VENV/bin/python"

# 1) pyvenv.cfg home -> bundled runtime (fixes 'No module named encodings')
if [ -f "$PYVCFG" ] && grep -q '__HERMES_RUNTIME_BIN__' "$PYVCFG"; then
  "$PY" - "$PYVCFG" "$RT_BIN" <<'PY'
import sys, re
p, rt = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
s = re.sub(r'^home = .*', 'home = ' + rt, s, flags=re.M)
s = re.sub(r'^uv = .*\n', '', s, flags=re.M)
open(p, "w", encoding="utf-8").write(s)
PY
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

# 4) rewrite editable metadata absolute path -> deploy path (cross-platform, Python not sed)
OLD="$("$PY" - "$SP" <<'PY'
import sys, glob, re, os
sp = sys.argv[1]
hits = glob.glob(os.path.join(sp, "__editable__*.py"))
pat = re.compile(r'(/[A-Za-z0-9_./-]+)/hermes-agent')
for f in hits:
    t = open(f, encoding="utf-8", errors="ignore").read()
    m = pat.search(t)
    if m:
        print(m.group(1)); break
PY
)"
if [ -n "$OLD" ] && [ "$OLD" != "$DIR/hermes-agent" ]; then
  "$PY" - "$OLD" "$DIR/hermes-agent" "$SP" <<'PY'
import sys, glob, os
old, new, sp = sys.argv[1], sys.argv[2], sys.argv[3]
for f in glob.glob(os.path.join(sp, "__editable__*.py")) + \
         glob.glob(os.path.join(sp, "hermes_agent-*.dist-info", "direct_url.json")):
    if not os.path.isfile(f):
        continue
    s = open(f, encoding="utf-8", errors="ignore").read()
    if old in s:
        open(f, "w", encoding="utf-8").write(s.replace(old, new))
PY
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
