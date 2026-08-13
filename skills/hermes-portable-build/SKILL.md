---
name: hermes-portable-build
description: Use when building a self-contained offline Hermes Agent portable package — tar.gz that unpacks into a user home dir (~/), needs no root, no system dirs, and runs with zero network at runtime. Covers the full build + install.sh + offline verification workflow.
category: devops
---

# Hermes Portable (Green) Build

## Support files (prefer these over retyping)
- `scripts/build_portable.sh` — canonical, re-runnable build script. Copy to a
  machine with a working `hermes` install and run it; produces `~/hermes-portable/`.
- `references/verification.md` — strace + `env -i` offline-proof recipe and the
  real-run gotchas (`kanban` positional `title`, `unshare -n` denied, etc.).

> The build script below mirrors `scripts/build_portable.sh` for readability;
> prefer running the script file directly.

Build a self-contained, offline-capable Hermes Agent package that:
- lives entirely under a user home dir (`~/`), never touches root/system dirs;
- requires **no network at runtime**;
- is relocatable: unpack to any path, run `install.sh` once, then `./hermes.sh`.

## When to use
- User asks for a "green install", "portable package", "offline Hermes", "解压即用",
  "打包 Hermes", "独立安装包" that runs on a clean air-gapped Linux box.
- Hermes version upgrade → rebuild from the new checkout with this same flow.

## Constraint: user-dir only, no root
Hermes already stores everything under `$HERMES_HOME` (default `~/.hermes`), so the
design is compatible. The work is to (a) make the venv self-contained (no symlink
out to uv's shared python), and (b) kill all runtime network behavior.

## Key facts discovered (do NOT skip)
1. **Hermes blocks `pip install .` (wheel/sdist build).** `setup.py` raises
   `RuntimeError: Building wheels or sdists for hermes-agent is not supported.`
   Use an **editable install** instead: `pip install -e .` (offline, no compile,
   only writes an `.egg-link`/`__editable__*.pth` finder).
2. **`venv/bin/python` is a SYMLINK into uv's shared dir**
   (`~/.local/share/uv/python/cpython-3.11.../bin/python3.11`) by default. A
   copied-but-symlinked venv breaks on a clean machine. Rebuild with
   `python -m venv --copies` and **bundle the interpreter** under
   `runtime/python/`.
3. **`pyvenv.cfg` `home` must be an ABSOLUTE in-package path set at deploy time.**
   A relative home (or empty env) makes the copied interpreter resolve its prefix
   against the BUILD path and die with `No module named 'encodings'`. Let
   `install.sh` rewrite it from its own `$DIR`.
4. **Editable-install metadata bakes the BUILD-time absolute path** into
   `__editable__*.pth` / `__editable___*_finder.py` and
   `hermes_agent-*.dist-info/direct_url.json`. This surfaces as a wrong
   `Install directory` in `hermes version`. `install.sh` must `sed` the old path
   → `$DIR/hermes-agent`.
5. **Precompiled `.pyc` bake `co_filename` (the source absolute path).** Stale
   pyc from a different path also show a wrong version string. `install.sh` must
   delete all `__pycache__` / `*.pyc` so they recompile under the deploy path.
6. **`security.allow_lazy_installs` + `update.check_on_startup` must be false**
   so optional backends (Slack/Matrix/Bedrock/…) and the updater never hit PyPI.
   Bundle `uv` under `home/bin/uv` so `managed_uv.py` never downloads.
7. **Sole external hard dependency = glibc ≥ 2.39** (the build machine's version).
   A target machine with older glibc must be built on an equally-old builder.
   All 51 compiled `.so` files (cryptography, pydantic_core, aiohttp, uvloop,
   psutil, Pillow, nemo_relay…) are self-contained; Pillow even ships its own
   `pillow.libs/`. No system libjpeg/freetype needed.
8. `unshare -n` (network namespace isolation) may be **denied** in a sandbox
   (Operation not permitted). Verify offline behavior with `strace -f -e
   trace=network,file` instead, plus `env -i` to wipe inherited env.

## Build script (`build_portable.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail
SRC_AGENT="$HOME/.hermes/hermes-agent"
BASE_PYTHON="$(ls -d "$HOME/.local/share/uv/python/cpython-3.11"*/ 2>/dev/null | head -1)"
[ -z "$BASE_PYTHON" ] && { echo "uv python not found" >&2; exit 1; }
BASE_PYTHON="${BASE_PYTHON%/}"
OUT="$HOME/hermes-portable"
echo "src=$SRC_AGENT  py=$BASE_PYTHON  out=$OUT"

rm -rf "$OUT"
mkdir -p "$OUT/runtime" "$OUT/hermes-agent" "$OUT/home"

# 1) bundle full CPython (stdlib+bin) so venv symlinks resolve
cp -a "$BASE_PYTHON" "$OUT/runtime/python"

# 2) copies venv => interpreter is a real file, not a symlink out
"$OUT/runtime/python/bin/python3.11" -m venv --copies "$OUT/hermes-agent/venv"

# 3) copy agent source (drop git/tests/node artifacts)
rsync -a --exclude='.git' --exclude='tests' --exclude='tests-js' \
  --exclude='node_modules' --exclude='dist' --exclude='*.egg-info' \
  --exclude='__pycache__' --exclude='.venv' --exclude='venv' \
  "$SRC_AGENT/" "$OUT/hermes-agent/"

# 4) editable install (Hermes blocks wheel builds) — offline, no compile
"$OUT/hermes-agent/venv/bin/pip" install --no-build-isolation --no-cache-dir \
  -e "$OUT/hermes-agent/"

# 5) placeholder home; install.sh rewrites to real in-package path at deploy
PYVCFG="$OUT/hermes-agent/venv/pyvenv.cfg"
[ -f "$PYVCFG" ] && { sed -i 's#^home = .*#home = __HERMES_RUNTIME_BIN__#' "$PYVCFG"; sed -i '/^uv = /d' "$PYVCFG"; }

# 6) offline config placeholder; install.sh writes the real one
mkdir -p "$OUT/home"
printf '# Written by install.sh\n' > "$OUT/home/config.yaml"

# 7) launcher (resolves its own dir; no hardcoded absolute paths)
cat > "$OUT/hermes.sh" <<'EOF'
#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HERMES_HOME="$DIR/home"
export PATH="$DIR/home/bin:$DIR/hermes-agent/venv/bin:$PATH"
exec "$DIR/hermes-agent/venv/bin/python" -m hermes_cli.main "$@"
EOF
chmod +x "$OUT/hermes.sh"

# 8) install.sh — one-shot deploy config (no root, no network, idempotent)
cat > "$OUT/install.sh" <<'EOF'
#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT_BIN="$DIR/runtime/python/bin"
VENV="$DIR/hermes-agent/venv"
PYVCFG="$VENV/pyvenv.cfg"
SP="$VENV/lib/python3.11/site-packages"
echo "==> Hermes portable installer (no root, no network)"
echo "    Package dir: $DIR"
# 8a) pyvenv.cfg home -> bundled runtime (fixes encodings crash)
if [ -f "$PYVCFG" ] && grep -q '__HERMES_RUNTIME_BIN__' "$PYVCFG"; then
  sed -i "s#__HERMES_RUNTIME_BIN__#$RT_BIN#" "$PYVCFG"; echo "    [ok] pyvenv.cfg home -> $RT_BIN"
else echo "    [skip] pyvenv.cfg already configured"; fi
# 8b) ensure uv binary present
mkdir -p "$DIR/home/bin"
if [ ! -x "$DIR/home/bin/uv" ]; then
  [ -x "$HOME/.hermes/bin/uv" ] && cp -a "$HOME/.hermes/bin/uv" "$DIR/home/bin/uv" && echo "    [ok] uv copied"
fi
# 8c) offline config
cat > "$DIR/home/config.yaml" <<'YAML'
security:
  allow_lazy_installs: false
update:
  check_on_startup: false
telemetry:
  enabled: false
YAML
echo "    [ok] offline config.yaml written"
# 8d) rewrite editable metadata absolute path -> deploy path
OLD="$(grep -rhoE '/[a-zA-Z0-9_./-]*/hermes-agent' "$SP/__editable__"*.py 2>/dev/null | head -1)"
if [ -n "$OLD" ] && [ "$OLD" != "$DIR/hermes-agent" ]; then
  for f in "$SP"/__editable__*.py "$SP"/hermes_agent-*.dist-info/direct_url.json; do
    [ -f "$f" ] && sed -i "s#$OLD#$DIR/hermes-agent#g" "$f"
  done; echo "    [ok] editable metadata path -> $DIR/hermes-agent"
else echo "    [skip] editable metadata already correct"; fi
# 8e) clear stale pyc (recompile under deploy path)
find "$DIR" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$DIR" -name '*.pyc' -delete 2>/dev/null || true
echo "    [ok] cleared stale .pyc caches"
# 8f) sanity
if [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c "import hermes_cli" 2>/dev/null; then
  echo "    [ok] hermes_cli importable"
else echo "    [warn] hermes_cli not importable; debug with full env"; fi
echo "==> Done. Run:  bash $DIR/hermes.sh version"
EOF
chmod +x "$OUT/install.sh"

# 9) drop pyc now (install.sh also does at deploy; belt & suspenders)
find "$OUT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$OUT" -name '*.pyc' -delete 2>/dev/null || true
echo "==> Done. Package at: $OUT"
echo "==> Deploy: cd hermes-portable && bash install.sh"
echo "==> Run:    bash hermes.sh version"
```

## Package (after build)
```
hermes-portable/
├── install.sh        # one-shot: fix pyvenv.cfg, write offline config, rewrite editable metadata, clear pyc
├── hermes.sh         # launcher; sets HERMES_HOME + PATH; no manual env vars needed
├── runtime/python/   # self-contained CPython 3.11 (copied, not symlinked)
├── hermes-agent/     # venv (deps installed) + source
└── home/             # config.yaml (allow_lazy_installs:false) + bin/uv
```

## Deploy (clean machine)
```bash
tar xzf hermes-portable.tar.gz -C ~/
cd ~/hermes-portable && bash install.sh
bash hermes.sh version
bash hermes.sh chat
```

## Verification (proves offline + no system writes)
Run on a copy unpacked to a DIFFERENT path (e.g. `/tmp/alt/hermes-portable`),
with wiped env and a fresh HOME, and trace syscalls:
```bash
FRESH=/tmp/alt/hermes-portable/home-fresh
cp -a /tmp/alt/hermes-portable/home "$FRESH"
strace -f -e trace=network,file -o /tmp/trace.txt \
  env -i HOME="$FRESH" HERMES_HOME="$FRESH" \
  PATH=/tmp/alt/hermes-portable/hermes-agent/venv/bin:/usr/bin:/bin \
  bash /tmp/alt/hermes-portable/hermes.sh version
# Assertions:
#  - output shows correct version + Install directory == /tmp/alt/hermes-portable/hermes-agent
#  - grep 'connect(' /tmp/trace.txt | grep -vE 'AF_UNIX|127.0.0.1|::1'  => EMPTY (no external net)
#  - grep openat write to /etc /usr /opt /root /var => EMPTY (no system dir writes)
# Functional offline test:
#  hermes.sh kanban init
#  hermes.sh kanban create "离线测试任务" --body "验证绿色包"
#  hermes.sh kanban list   # shows the task => SQLite persisted offline
```
Note: `kanban create` takes `title` as a POSITIONAL arg and `--body` for the
description (NOT `--title`/`--description`).

## Pitfalls / troubleshooting
- **`No module named 'encodings'`** → pyvenv.cfg `home` is relative/empty. Fix:
  install.sh must set an absolute in-package path (step 8a).
- **Wrong `Install directory`** → editable metadata / pyc baked old path. Fix:
  steps 8d + 8e.
- **`pip install .` fails with "Building wheels … not supported"** → use `-e .`
  (editable). Do NOT try to build a wheel/sdist.
- **Optional backend import fails offline** (Slack/Matrix/…): expected — those
  are lazy extras not preinstalled. Core agent/kanban/chat work fully offline.
- **Target machine older glibc** → rebuild on a builder with matching/older glibc;
  glibc is forward-compatible only (new binary won't run on older libc).
- **`unshare -n` denied** in sandbox → use `strace` + `env -i` instead of
  network namespaces to prove offline behavior.
