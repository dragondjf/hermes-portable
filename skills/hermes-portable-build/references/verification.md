# Offline verification recipe (proves: no network + no system-dir writes + relocatable)

Run against a COPY unpacked to a DIFFERENT path than the build dir (e.g.
`/tmp/alt/hermes-portable`). We use `env -i` to wipe inherited env and `strace`
to trace syscalls, because `unshare -n` (network-namespace isolation) is often
denied in sandboxes (Operation not permitted).

```bash
# 1) unpack copy + install
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
#  - version output shows correct version AND:
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

## Glich notes from the real run
- `kanban create` does NOT accept `--title`/`--description`; `title` is positional,
  description is `--body`.
- If `Install directory` still shows the build path after install.sh, the editable
  metadata sed (step 8d) or pyc clear (8e) didn't match — check
  `venv/lib/python3.11/site-packages/__editable__*.py` and `direct_url.json`.
- `unshare -n` failed with "Operation not permitted" in this sandbox → use strace
  + env -i instead of network namespaces.
