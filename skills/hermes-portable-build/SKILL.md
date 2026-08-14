---
name: hermes-portable-build
description: Use when building a self-contained, offline, relocatable ("green") Hermes Agent package for Linux (x64/arm64), macOS (x64), and Windows (x64) — a tar.gz/zip that unpacks into any user directory, needs no root, no system dirs, runs with zero network at runtime, and is relocated by install.sh/install.ps1/install.bat at deploy time. Covers the official-install-capture → --copies venv → tokenized editable metadata → cross-platform CI → green verification workflow.
category: devops
---

# Hermes Portable (Green) Build

Build a self-contained, offline-capable, **relocatable** Hermes Agent package that:
- lives entirely under a user directory (unpack anywhere, no root, no system dirs);
- requires **zero network at runtime**;
- is **relocatable**: unpack to any path, run `install.*` once, then launch.
- contains **no absolute build paths** in the published artifact — install relocates at deploy time.

## Canonical scripts (this skill's `scripts/`, identical to repo `build/`)
Run the builders; the installers/launchers/verifiers are bundled into the package.
- `build_portable.sh`   — Linux/macOS builder (uv-managed python, --copies venv).
- `build_portable.ps1`  — Windows builder (same strategy, PowerShell).
- `install.sh` / `install.ps1` / `install.bat` — deploy-time one-shot config (Unix / pwsh / cmd.exe).
- `hermes.sh` / `hermes.ps1` / `hermes.bat` — launchers (set HERMES_HOME+PATH, run agent).
- `_rewrite_paths.py`   — **the heart of relocation**: tokenizes build paths at build time, restores them at install time, and hard-verifies no build path remains.
- `verify_reloc.sh` / `verify_reloc.ps1` — prove relocatability + offline + no leaked build path (runs in CI on every platform).

## When to use
- User asks for a "green install", "portable package", "offline Hermes", "解压即用", "打包 Hermes", "独立安装包" for a clean air-gapped box.
- Cross-platform Hermes packaging (Linux x64/arm64, macOS x64, Windows x64) with a single `v*`-tagged CI build.
- Hermes version upgrade → rebuild from a fresh official install with the same flow.

## Core design: ZERO absolute paths in the artifact
The published package must contain **no** build-machine absolute paths. We achieve this with a two-phase tokenization:
1. **Build time** (`_rewrite_paths.py build`): replace the absolute BUILD package root in editable metadata (`__editable__*.py`, `__editable__*.pth`, `hermes_agent-*.dist-info/direct_url.json`) and `pyvenv.cfg` with the token `__HERMES_RUNTIME_BIN__`. The package ships with the token — fully relocatable.
2. **Install time** (`_rewrite_paths.py install`, called by install.*): replace `__HERMES_RUNTIME_BIN__` with the real deploy path, force `pyvenv.cfg` `home`/`executable` to the bundled runtime, **drop** the `command`/`uv`/`base-prefix` lines that carry build paths, then **verify** no build path remains (hard-fail if any does).

This is what makes the package genuinely relocatable: hermes's own venv startup-repair has no stale build prefix to restore.

## Constraint: user-dir only, no root, no network
Hermes stores everything under `$HERMES_HOME` (default `~/.hermes`), so the design is compatible. The work is to (a) make the venv self-contained (no symlink out to uv's shared python), (b) kill all runtime network behavior, and (c) remove every build absolute path.

## Key facts (do NOT skip — each cost a real CI cycle)
1. **Hermes blocks `pip install .` (wheel/sdist).** `setup.py` raises `RuntimeError: Building wheels or sdists for hermes-agent is not supported.` Use an **editable install**: `uv pip install -e .` (offline, no compile).
2. **`venv/bin/python` is a SYMLINK into uv's shared dir** by default. Rebuild with `python -m venv --copies` and **bundle the interpreter** under `runtime/python/`. Use `cp -aL` when copying uv's python so any symlink inside it (e.g. `bin/python3 -> python3.11`) is dereferenced into a real file.
3. **Editable metadata bakes the BUILD-time absolute path** into `__editable__*.pth` / `__editable___*_finder.py` and `hermes_agent-*.dist-info/direct_url.json` → wrong `Install directory`. Tokenize at build, restore at install (see above). **No regex, exact string replace only** — a greedy regex that matches "up to the first hermes-portable" corrupts paths when the package is nested (CI's `/home/runner/work/hermes-portable/hermes-portable/hermes-portable`), producing a non-existent dir and `ModuleNotFoundError`.
4. **Windows editable finder stores paths with DOUBLED backslashes** (a Python string literal: `'D:\\\\a\\..'`). `os.path.abspath` gives single backslashes, so the build-mode replace MUST try every separator variant (`pkg`, `pkg_fwd`, `pkg_bak`, `pkg_dbl`) or the Windows finder is left untouched and hermes imports from the build path.
5. **`pyvenv.cfg` `home` must point at the bundled runtime** (a copied interpreter with a relative/empty home resolves prefix against the BUILD path and dies with `No module named 'encodings'`). But **do NOT leave the build path in `home`** — tokenize it at build, restore at install. Drop the `command`/`uv`/`base-prefix` lines (they carry the build path and trigger hermes's repair to rewrite `home` back to the build path).
6. **CHICKEN-AND-EGG (Windows):** the venv `python.exe` reads `pyvenv.cfg` to start, and `pyvenv.cfg` still holds `__HERMES_RUNTIME_BIN__` until `_rewrite_paths.py` rewrites it — so the venv python **cannot launch itself**. Run `_rewrite_paths.py` with the **BUNDLED standalone runtime python** (`runtime/python/python.exe`), which has no pyvenv dependency and starts fine. On Unix, `install.sh` fixes `pyvenv.cfg` with `sed` *before* step 4, so the venv python can start — but route the same shared script via the bundled python for consistency.
7. **PowerShell `-replace` is unreliable for this** (case-insensitive, regex-based, and it silently failed to rewrite `pyvenv.cfg` on Windows in practice). Route ALL path rewriting through the deterministic Python `_rewrite_paths.py` instead.
8. **Precompiled `.pyc` bake `co_filename` (source absolute path)** and stale pyc from a different path shows a wrong version string. Delete all `__pycache__` / `*.pyc` at build end and at install (step 5).
9. **`security.allow_lazy_installs` + `update.check_on_startup` must be false** so optional backends and the updater never hit PyPI. Bundle `uv` under `home/bin/uv` so `managed_uv.py` never downloads.
10. **Leak-check false positives:** when verifying "no build path leaked", do NOT flag the deploy dir itself. On Windows CI the deploy dir legitimately lives under `C:/Users/runneradmin/...` (that's the reloc target, not a leak); only flag the CI BUILD workspace (`D:/a/hermes-portable`, `/home/runner`, `/root/`). Normalize drive letters + doubled backslashes before comparing.
11. **Sole external hard dependency = glibc ≥ 2.39** (build machine's version). Older target → build on an equally-old builder. All compiled `.so` are self-contained. No system libjpeg/freetype.
12. **`unshare -n` may be denied** in a sandbox (Operation not permitted). On Unix, prove offline behavior with `strace -f -e trace=network,file` + `env -i` (see `references/verification.md`). Windows has no strace → assert relocatability + correct deploy paths + offline config + a functional kanban round-trip, and scan for leaked build paths instead.

## Package layout (after build)
```
hermes-portable/
├── install.sh  / install.ps1 / install.bat   # one-shot: relocate + offline config (choose per shell)
├── hermes.sh   / hermes.ps1  / hermes.bat    # launcher (set HERMES_HOME+PATH; run agent)
├── runtime/python/   # self-contained CPython 3.11 (copied, not symlinked)
├── hermes-agent/     # venv (deps installed, --copies) + editable source
├── home/             # config.yaml (allow_lazy_installs:false) + bin/ (uv, _rewrite_paths.py)
└── (Windows) .zip · (Unix/macOS) .tar.gz
```

## Deploy (clean machine)
```bash
# Linux/macOS
tar xzf hermes-portable.tar.gz -C ~/
cd ~/hermes-portable && bash install.sh      # or: pwsh install.ps1 / install.bat
bash hermes.sh version

# Windows (PowerShell or cmd)
Expand-Archive hermes-portable.zip -DestinationPath $HOME\
cd $HOME\hermes-portable; pwsh install.ps1     # or: install.bat
hermes.ps1 version                              # or: hermes.bat version
```

## CI matrix (`.github/workflows/build.yml`, tag `v*` triggers)
Four jobs, each runs the official installer, then `build_portable.{sh,ps1}`, then a **smoke test on a COPY** (so the built artifact stays tokenized), then `verify_reloc.{sh,ps1}` (relocate to a different path + assert no leaked build path + offline + kanban). All four must pass before the run is green. Release assets are uploaded with `overwrite: true` so re-tagging a `v*` tag replaces stale assets. The unix smoke test MUST run on a copy — running in-place de-tokenizes the only artifact and both the smoke test AND the published zip end up with leaked build paths.

## Verification (proves green) — full recipe in `references/verification.md`
Unpack to a DIFFERENT path, install, run with wiped env + fresh HOME, and (Unix) `strace` / (Windows) scan for leaked build paths:
- `Install directory` == the deploy path (NOT the build path).
- No external `connect()` (no network); no writes to `/etc /usr /opt /root /var`.
- **No build absolute path** in `pyvenv.cfg`, `__editable__*.py`, `direct_url.json`, `__editable__*.pth`.
- Functional: `kanban init` / `kanban create "任务" --body "..."` / `kanban list` persists.
- `kanban create` takes `title` as a **positional** arg + `--body` (NOT `--title`).

## Pitfalls
- `No module named 'encodings'` → `pyvenv.cfg` `home` wrong → bundled runtime not set.
- Wrong `Install directory` → editable metadata / pyc baked old path → relocation didn't run.
- `pip install .` fails "Building wheels not supported" → use `-e .` (editable).
- Windows `SyntaxError: 'unicodeescape'` on import → a path with single backslashes before a `\U` was written into the `.py` finder; the doubled-backslash form is required (`C:\\Users\\..`).
- Venv python won't start during install on Windows → chicken-and-egg (fact 6); use the bundled runtime python.
- Optional backend import fails offline (Slack/Matrix/…): expected; core works offline.
- Older target glibc → rebuild on older builder (glibc forward-compatible only).
