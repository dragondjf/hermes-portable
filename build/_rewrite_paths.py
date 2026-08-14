#!/usr/bin/env python3
"""
Deterministic path relocation for the Hermes portable package.

Build time (mode=build):
  Replace the absolute BUILD PACKAGE ROOT with the token __HERMES_PKG_ROOT__
  inside every editable/finder/direct_url metadata file, so the published
  package contains ZERO absolute paths (per requirement: green package must
  have zero absolute paths; install.ps1/.sh fixes them at deploy time).

Install time (mode=install):
  Replace __HERMES_PKG_ROOT__ with the deployed package root.

The token root is the WHOLE package directory (not just hermes-agent), because
editable metadata may reference either .../hermes-portable (direct_url.json,
url) or .../hermes-agent (finder MAPPING). Tokenizing the package root catches
all of them regardless of suffix.

Usage:
  python _rewrite_paths.py <build|install> <PACKAGE_DIR>
The bundled python is used (no dependency on a system interpreter).
"""
import os
import sys
import glob
import re

TOKEN = "__HERMES_PKG_ROOT__"

# Known CI build roots, in case the package was built on a runner. Tokenized as a
# safety net even if the literal pkg path below did not match (e.g. nested dirs).
CI_ROOTS = [
    "/home/runner/work/hermes-portable/hermes-portable",
    "D:\\a\\hermes-portable\\hermes-portable",
    "D:/a/hermes-portable/hermes-portable",
    "/Users/runneradmin/work/hermes-portable/hermes-portable",
]


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

    changed = []
    for f in files:
        t = open(f, encoding="utf-8").read()
        orig = t
        if mode == "build":
            # Tokenize the package root (both separators) + every CI build root.
            for root in [pkg, pkg.replace("\\", "/")] + CI_ROOTS:
                t = t.replace(root, TOKEN)
            # Safety net: any absolute path pointing at hermes-portable/hermes-agent.
            t = re.sub(r"[A-Za-z]:[\\/][^'\"]*?hermes-portable", TOKEN, t)
            t = re.sub(r"[A-Za-z]:[\\/][^'\"]*?hermes-agent", TOKEN, t)
            t = re.sub(r"/home/runner[^'\"]*?hermes-portable", TOKEN, t)
            t = re.sub(r"/Users/runneradmin[^'\"]*?hermes-portable", TOKEN, t)
            t = re.sub(r"/root[^'\"]*?hermes-portable", TOKEN, t)
        else:  # install
            deploy = pkg.replace("\\", "/")
            t = t.replace(TOKEN, deploy)
            t = re.sub(r"[A-Za-z]:[\\/][^'\"]*?hermes-portable", deploy, t)
            t = re.sub(r"[A-Za-z]:[\\/][^'\"]*?hermes-agent", deploy, t)
            t = re.sub(r"/home/runner[^'\"]*?hermes-portable", deploy, t)
            t = re.sub(r"/Users/runneradmin[^'\"]*?hermes-portable", deploy, t)
            t = re.sub(r"/root[^'\"]*?hermes-portable", deploy, t)
        if t != orig:
            open(f, "w", encoding="utf-8").write(t)
            changed.append(f)

    if mode == "build":
        print("    [build] tokenized editable metadata (%d files)" % len(changed))
    else:
        print("    [install] relocated editable metadata -> %s (%d files)" % (pkg, len(changed)))


if __name__ == "__main__":
    main()
