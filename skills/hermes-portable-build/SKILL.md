---
name: hermes-portable-build
description: Use when building a self-contained offline Hermes Agent portable package — tar.gz that unpacks into a user home dir (~/), needs no root, no system dirs, and runs with zero network at runtime. Covers the build + install.sh + offline verification workflow.
category: devops
---

# Hermes Portable (Green) Build

Build a self-contained, offline-capable Hermes Agent package that:
- lives entirely under a user home dir (`~/`), never touches root/system dirs;
- requires **no network at runtime**;
- is relocatable: unpack to any path, run `install.sh` once, then `./hermes.sh`.

## Support files (run these, don't retype)
- `scripts/build_portable.sh` — canonical build script. Run on a machine with a
  working `hermes`; produces `~/hermes-portable/`.
- `scripts/install.sh` — deploy-time one-shot config: rewrites `pyvenv.cfg`, writes
  offline `config.yaml`, fixes editable metadata + pyc paths. Bundled into the package.
- `scripts/hermes.sh` — launcher: sets `HERMES_HOME` + `PATH`, then runs the agent.
- `references/verification.md` — strace + `env -i` offline-proof recipe and the
  real-run gotchas (`kanban` positional `title`, `unshare -n` denied, etc.).

## When to use
- User asks for a "green install", "portable package", "offline Hermes", "解压即用",
  "打包 Hermes", "独立安装包" that runs on a clean air-gapped Linux box.
- Hermes version upgrade → rebuild from the new checkout with this same flow.

## Constraint: user-dir only, no root
Hermes already stores everything under `$HERMES_HOME` (default `~/.hermes`), so the
design is compatible. The work is to (a) make the venv self-contained (no symlink
out to uv's shared python), and (b) kill all runtime network behavior.

## Key facts (do NOT skip — each caused a real failure)
1. **Hermes blocks `pip install .` (wheel/sdist).** `setup.py` raises
   `RuntimeError: Building wheels or sdists for hermes-agent is not supported.`
   Use an **editable install**: `pip install -e .` (offline, no compile).
2. **`venv/bin/python` is a SYMLINK into uv's shared dir**
   (`~/.local/share/uv/python/cpython-3.11.../bin/python3.11`) by default. Rebuild
   with `python -m venv --copies` and **bundle the interpreter** under `runtime/python/`.
3. **`pyvenv.cfg` `home` must be an ABSOLUTE in-package path set at deploy time.**
   A relative/empty home makes the copied interpreter resolve prefix against the
   BUILD path and die with `No module named 'encodings'`. `install.sh` rewrites it.
4. **Editable metadata bakes the BUILD-time absolute path** into
   `__editable__*.pth` / `__editable___*_finder.py` and
   `hermes_agent-*.dist-info/direct_url.json` → wrong `Install directory`. `install.sh`
   must `sed` the old path → `$DIR/hermes-agent`.
5. **Precompiled `.pyc` bake `co_filename` (source absolute path).** Stale pyc from a
   different path also show a wrong version string. `install.sh` deletes all
   `__pycache__` / `*.pyc` so they recompile under the deploy path.
6. **`security.allow_lazy_installs` + `update.check_on_startup` must be false** so
   optional backends and the updater never hit PyPI. Bundle `uv` under `home/bin/uv`
   so `managed_uv.py` never downloads.
7. **Sole external hard dependency = glibc ≥ 2.39** (the build machine's version).
   Older target → build on an equally-old builder. All 51 compiled `.so` files are
   self-contained (Pillow even ships `pillow.libs/`). No system libjpeg/freetype.
8. **`unshare -n` may be denied** in a sandbox (Operation not permitted). Prove
   offline behavior with `strace -f -e trace=network,file` + `env -i` instead.

## Package layout (after `build_portable.sh`)
```
hermes-portable/
├── install.sh        # one-shot: fix pyvenv.cfg, write offline config, fix metadata + pyc
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
Unpack to a DIFFERENT path (e.g. `/tmp/alt/hermes-portable`), run with wiped env
and a fresh HOME, and trace syscalls (full recipe in `references/verification.md`):
```bash
FRESH=/tmp/alt/hermes-portable/home-fresh
cp -a /tmp/alt/hermes-portable/home "$FRESH"
strace -f -e trace=network,file -o /tmp/trace.txt \
  env -i HOME="$FRESH" HERMES_HOME="$FRESH" \
  PATH=/tmp/alt/hermes-portable/hermes-agent/venv/bin:/usr/bin:/bin \
  bash /tmp/alt/hermes-portable/hermes.sh version
# Assert: correct version + Install directory == /tmp/alt/hermes-portable/hermes-agent
# Assert: grep 'connect(' /tmp/trace.txt | grep -vE 'AF_UNIX|127.0.0.1|::1'  => EMPTY
# Assert: no openat write to /etc /usr /opt /root /var
# Functional: kanban init / kanban create "离线测试任务" --body "..." / kanban list
```
`kanban create` takes `title` as a **positional** arg + `--body` (NOT `--title`).

## Pitfalls
- `No module named 'encodings'` → `pyvenv.cfg` `home` relative/empty → install.sh 8a.
- Wrong `Install directory` → editable metadata / pyc baked old path → install.sh 8d+8e.
- `pip install .` fails "Building wheels not supported" → use `-e .` (editable).
- Optional backend import fails offline (Slack/Matrix/…): expected; core works offline.
- Older target glibc → rebuild on older builder (glibc forward-compatible only).
