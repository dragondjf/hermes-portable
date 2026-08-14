# Offline + relocatable verification (proves: no network, no system-dir writes, no leaked build path)

The goal: prove the published package is a TRUE green package — runs from a
NON-standard path, makes no external network call, writes nothing to system
dirs, and contains NO build-machine absolute path.

## Unix (Linux/macOS): strace + env -i
`unshare -n` (network-namespace isolation) is often denied in sandboxes
("Operation not permitted"), so use `strace` + a wiped env instead.

```bash
# 1) unpack copy + install (smoke test in CI runs on a COPY so the artifact stays tokenized)
rm -rf /tmp/alt; mkdir -p /tmp/alt
cp -a "$HOME/hermes-portable" /tmp/alt/
cd /tmp/alt/hermes-portable
bash install.sh

# 2) fresh isolated HOME
FRESH=/tmp/alt/hermes-portable/home-fresh
rm -rf "$FRESH"; cp -a /tmp/alt/hermes-portable/home "$FRESH"

# 3) trace network + file opens under wiped env
strace -f -e trace=network,file -o /tmp/trace.txt \
  env -i HOME="$FRESH" HERMES_HOME="$FRESH" \
  PATH=/tmp/alt/hermes-portable/hermes-agent/venv/bin:/usr/bin:/bin \
  bash /tmp/alt/hermes-portable/hermes.sh version

# 4) ASSERTIONS
#  - version shows correct version AND:
#      Install directory: /tmp/alt/hermes-portable/hermes-agent   (NOT the build path)
#  - NO external network connect:
grep 'connect(' /tmp/trace.txt | grep -vE 'AF_UNIX|127\.0\.0\.1|::1'   # must be EMPTY
#  - NO writes to system dirs:
grep -E 'openat.*(O_WRONLY|O_CREAT|O_RDWR).*(/etc/|/usr/|/opt/|/root/|/var/)' /tmp/trace.txt  # must be EMPTY

# 5) functional offline test (SQLite-backed kanban must persist)
RUN="env -i HOME=$FRESH HERMES_HOME=$FRESH PATH=/tmp/alt/hermes-portable/hermes-agent/venv/bin:/usr/bin:/bin bash /tmp/alt/hermes-portable/hermes.sh"
$RUN kanban init
$RUN kanban create "离线测试任务" --body "验证绿色包"    # title is POSITIONAL; --body is the description
$RUN kanban list                                          # must show the created task
```

## Windows: no strace → assert relocatability + leak-scan
Windows has no `strace`. Instead, `verify_reloc.ps1` (run in CI) does:
1. Copy the package to a different path (`$env:TEMP/hermes-reloc-test`).
2. Run `install.ps1` there.
3. Run `hermes.ps1 version` and assert it prints `Hermes Agent v...` and an
   `Install directory` that is NOT the CI build workspace (`D:\a\hermes-portable`).
4. **Scan for leaked build paths** in `pyvenv.cfg`, `__editable__*.py`,
   `direct_url.json`, `__editable__*.pth` (ignore `.exe`/`.pyc`). Flag only the
   CI BUILD workspace (`D:/a/hermes-portable`, `/home/runner`, `/root/`) — NOT
   the legitimate Windows deploy dir `C:/Users/runneradmin/...`. Normalize
   drive letters + doubled backslashes before comparing.
5. Functional offline test: `kanban init` / `kanban create` / `kanban list`.

## Cross-platform leak-scan recipe (what _rewrite_paths.py install verifies)
`_rewrite_paths.py install` rewrites AND verifies in one step. It fails hard if
any non-deploy absolute path remains. The pattern (mirrored in verify_reloc.*):
- Tokenize at build: replace the package root (all separator variants, including
  the Windows doubled-backslash form) in editable metadata + pyvenv.cfg with
  `__HERMES_RUNTIME_BIN__`.
- Restore at install: replace `__HERMES_RUNTIME_BIN__` with the deploy path,
  force `pyvenv.cfg` `home`/`executable` to `<deploy>/runtime/python`, drop
  `command`/`uv`/`base-prefix` lines.
- Verify: for each scanned file, no leftover token and no absolute path that is
  NOT the deploy root (normalize drive letters + separators first).

## Glitch notes from the real run
- `kanban create` does NOT accept `--title`/`--description`; `title` is
  positional, description is `--body`.
- If `Install directory` still shows the build path after install, the editable
  metadata relocation or pyc clear didn't match — check
  `venv/.../site-packages/__editable__*.py` and `direct_url.json`.
- If the Windows venv python won't start during install (`No Python at
  '__HERMES_RUNTIME_BIN__\runtime\python\python.exe'`), you hit the
  chicken-and-egg: run `_rewrite_paths.py` with the BUNDLED runtime python, not
  the venv python.
- `unshare -n` failed with "Operation not permitted" in this sandbox → use
  strace + env -i instead of network namespaces.
