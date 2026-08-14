#!/usr/bin/env python3
"""
Deterministic path relocation for the Hermes portable package.

Build time (mode=build):
  Replace the absolute build hermes-agent root with the token
  __HERMES_AGENT_ROOT__ inside the editable finder + direct_url.json, so the
  published package contains NO absolute path (per requirement: green package
  must have zero absolute paths; install.ps1/.sh fixes them at deploy).

Install time (mode=install):
  Replace __HERMES_AGENT_ROOT__ with the deployed hermes-agent root.

Usage:
  python _rewrite_paths.py <build|install> <PACKAGE_DIR>
The bundled python is used (no dependency on a system interpreter).
"""
import os
import sys
import glob

TOKEN = "__HERMES_AGENT_ROOT__"


def _site_packages(pkg):
    # Windows: hermes-agent\venv\Lib\site-packages ; unix: hermes-agent/venv/lib/pythonX.Y/site-packages
    base = os.path.join(pkg, "hermes-agent", "venv")
    if os.path.isdir(os.path.join(base, "Lib", "site-packages")):
        return os.path.join(base, "Lib", "site-packages")
    # unix: find lib/python*/
    lib = os.path.join(base, "lib")
    if os.path.isdir(lib):
        for name in os.listdir(lib):
            sp = os.path.join(lib, name, "site-packages")
            if os.path.isdir(sp):
                return sp
    return None


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
    agent_root = os.path.join(pkg, "hermes-agent")

    changed = []
    patterns = [
        os.path.join(sp, "__editable__*.py"),
        os.path.join(sp, "__editable__*.pth"),
        os.path.join(sp, "hermes_agent-*.dist-info", "direct_url.json"),
    ]
    files = []
    for pat in patterns:
        files.extend(glob.glob(pat))

    for f in files:
        t = open(f, encoding="utf-8").read()
        orig = t
        if mode == "build":
            # Remove any absolute build path (both separators) -> token.
            # The editable finder stores the agent root; replace it.
            t = t.replace(agent_root, TOKEN)
            t = t.replace(agent_root.replace("\\", "/"), TOKEN)
            # Also catch any other stray absolute path containing the agent dir.
            import re
            t = re.sub(r"[A-Za-z]:[\\/][^'\"]*?hermes-agent", TOKEN, t)
            t = re.sub(r"/home/runner[^'\"]*?hermes-agent", TOKEN, t)
            t = re.sub(r"/Users/runneradmin[^'\"]*?hermes-agent", TOKEN, t)
            t = re.sub(r"/root[^'\"]*?hermes-agent", TOKEN, t)
        else:  # install
            deploy = agent_root.replace("\\", "/")
            t = t.replace(TOKEN, deploy)
            import re
            t = re.sub(r"[A-Za-z]:[\\/][^'\"]*?hermes-agent", deploy, t)
            t = re.sub(r"/home/runner[^'\"]*?hermes-agent", deploy, t)
            t = re.sub(r"/Users/runneradmin[^'\"]*?hermes-agent", deploy, t)
            t = re.sub(r"/root[^'\"]*?hermes-agent", deploy, t)
        if t != orig:
            open(f, "w", encoding="utf-8").write(t)
            changed.append(f)

    if mode == "build":
        print("    [build] tokenized editable metadata (%d files)" % len(changed))
    else:
        print("    [install] relocated editable metadata -> %s (%d files)" % (agent_root, len(changed)))


if __name__ == "__main__":
    main()
