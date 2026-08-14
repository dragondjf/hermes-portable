#!/usr/bin/env python3
"""
Deterministic path relocation for the Hermes portable package.

Build time (mode=build):
  Replace the absolute BUILD PACKAGE ROOT with the token __HERMES_PKG_ROOT__
  inside every editable/finder/direct_url metadata file, so the published
  package contains ZERO absolute paths (per requirement: green package must
  have zero absolute paths; install.sh/.ps1 fixes them at deploy time).

Install time (mode=install):
  Replace __HERMES_PKG_ROOT__ with the deployed package root.

The token root is the WHOLE package directory (not just hermes-agent), because
editable metadata may reference either .../hermes-portable (direct_url.json,
url) or .../hermes-agent (finder MAPPING). Tokenizing the package root catches
all of them regardless of suffix.

IMPORTANT: only EXACT string replacement of the package root (both path
separator variants) is used. No regex. Regex fallbacks that match "up to the
first hermes-portable" corrupt the path when the package is nested (e.g. CI's
/home/runner/work/hermes-portable/hermes-portable/hermes-portable), producing a
non-existent directory and a ModuleNotFoundError at runtime.

Usage:
  python _rewrite_paths.py <build|install> <PACKAGE_DIR>
The bundled python is used (no dependency on a system interpreter).
"""
import os
import sys
import glob

TOKEN = "__HERMES_PKG_ROOT__"


def _site_packages(pkg):
    # Windows: hermes-agent\venv\Lib\site-packages ; unix: hermes-agent/venv/lib/pythonX.Y/site-packages
    base = os.path.join(pkg, "hermes-agent", "venv")
    if os.path.isdir(os.path.join(base, "Lib", "site-packages")):
        return os.path.join(base, "Lib", "site-packages")
    lib = os.path.join(base, "lib")
    if os.path.isdir(lib):
        for name in os.listdir(lib):
            sp = os.path.join(lib, name, "site-packages")
            if os.path.isdir(sp):
                return sp
    return None


def _files(sp):
    files = []
    for pat in (
        os.path.join(sp, "__editable__*.py"),
        os.path.join(sp, "__editable__*.pth"),
        os.path.join(sp, "hermes_agent-*.dist-info", "direct_url.json"),
    ):
        files.extend(glob.glob(pat))
    return files


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("build", "install"):
        print("usage: _rewrite_paths.py <build|install> <PACKAGE_DIR>", file=sys.stderr)
        sys.exit(2)
    mode = sys.argv[1]
    pkg = os.path.abspath(sys.argv[2])
    sp = _site_packages(pkg)
    if not sp:
        print("    [skip] site-packages not found", file=sys.stderr)
        return
    files = _files(sp)
    if not files:
        print("    [skip] no editable metadata files found", file=sys.stderr)
        return

    # Exact roots to match (both separators). On Windows the editable finder may
    # store forward or back slashes; on CI the path may be nested hermes-portable
    # dirs. Exact replace of the FULL package root avoids any corruption.
    pkg_fwd = pkg.replace("\\", "/")

    changed = []
    for f in files:
        t = open(f, encoding="utf-8").read()
        orig = t
        if mode == "build":
            t = t.replace(pkg, TOKEN)
            t = t.replace(pkg_fwd, TOKEN)
        else:  # install
            deploy = pkg_fwd
            t = t.replace(TOKEN, deploy)
            # safety: if the build left a literal pkg path (token missing),
            # replace it exactly (no regex) so relocation is still correct.
            t = t.replace(pkg, deploy)
            t = t.replace(pkg_fwd, deploy)
        if t != orig:
            open(f, "w", encoding="utf-8").write(t)
            changed.append(f)

    if mode == "build":
        print("    [build] tokenized editable metadata (%d files)" % len(changed))
        return

    # install mode: verify the rewrite actually removed every absolute path that
    # is NOT the deploy root. A leftover token or a stray build path is a real
    # relocation failure (fail hard). We compare against the actual deploy dir,
    # so running in-place on CI (deploy == build workspace) does NOT false-fail.
    deploy_n = pkg_fwd
    bad = []
    import re
    for f in files:
        c = open(f, encoding="utf-8").read().replace("\\", "/")
        if TOKEN in c:
            bad.append((f, "leftover token"))
            continue
        is_text_meta = ("__editable__" in f or "direct_url.json" in f)
        if not is_text_meta:
            continue
        for m in re.findall(r'(?:/home/|/Users/|/root/|[A-Za-z]:/)[^"\'\s\\]*', c):
            if not m.startswith(deploy_n):
                bad.append((f, m))
                break
    if bad:
        for f, why in bad:
            print("    [FAIL] %s : %s" % (f, why), file=sys.stderr)
        print("FAIL: editable metadata still has non-deploy absolute path", file=sys.stderr)
        sys.exit(1)
    print("    [install] relocated editable metadata -> %s (%d files) + verified" % (pkg, len(changed)))


if __name__ == "__main__":
    main()
