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
import re

TOKEN = "__HERMES_PKG_ROOT__"
RT_TOKEN = "__HERMES_RUNTIME_BIN__"


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


def _pyvenv_cfg(pkg):
    return os.path.join(pkg, "hermes-agent", "venv", "pyvenv.cfg")


def _files(sp):
    files = []
    for pat in (
        os.path.join(sp, "__editable__*.py"),
        os.path.join(sp, "__editable__*.pth"),
        os.path.join(sp, "hermes_agent-*.dist-info", "direct_url.json"),
    ):
        files.extend(glob.glob(pat))
    return files


def _fix_pyvenv(pkg, mode):
    """Relocate pyvenv.cfg so the venv points at the BUNDLED runtime (not a
    build-machine path). Done here in Python (not fragile PowerShell -replace)
    because the editable-metadata relocator already proved exact Python string
    replacement is the only reliable approach across platforms/escaping.

    build mode : tokenize any absolute build path -> RT_TOKEN (zero abs paths
                 in the published package).
    install mode: force home/executable to <deploy>/runtime/python, drop the
                 command/uv/base-prefix lines that carry the build path, scrub
                 any leftover build root, then verify no build path remains.
    """
    cfg = _pyvenv_cfg(pkg)
    if not os.path.isfile(cfg):
        return False
    rt = os.path.join(pkg, "runtime", "python")
    if os.sep == "\\":
        exe = os.path.join(rt, "python.exe")
    else:
        exe = os.path.join(rt, "bin", "python3.11")
    pkg_fwd = pkg.replace("\\", "/")
    pkg_bak = pkg.replace("/", "\\")
    pkg_dbl = pkg.replace("\\", "\\\\")

    lines = open(cfg, encoding="utf-8").read().split("\n")
    out = []
    changed = False
    for ln in lines:
        s = ln.strip()
        if s.startswith("home ="):
            if mode == "build":
                val = ln
                for root in (pkg, pkg_fwd, pkg_bak, pkg_dbl):
                    val = val.replace(root, RT_TOKEN)
                out.append(val)
            else:
                out.append("home = %s" % rt)
            changed = True
        elif s.startswith("executable ="):
            if mode == "build":
                val = ln
                for root in (pkg, pkg_fwd, pkg_bak, pkg_dbl):
                    val = val.replace(root, RT_TOKEN)
                out.append(val)
            else:
                out.append("executable = %s" % exe)
            changed = True
        elif s.startswith(("command =", "uv =", "base-prefix =",
                           "base-exec-prefix =", "orig-prefix =")):
            # These carry the build path; drop them (venv regenerates if needed,
            # and hermes's repair won't find a stale build prefix to restore).
            if mode == "build":
                # tokenize in place rather than drop, so structure is preserved
                val = ln
                for root in (pkg, pkg_fwd, pkg_bak, pkg_dbl):
                    val = val.replace(root, RT_TOKEN)
                out.append(val)
            else:
                changed = True  # dropped
            continue
        else:
            out.append(ln)
    text = "\n".join(out)
    if mode == "install":
        # Safety scrub: expand the runtime token (produced by build mode) to the
        # deploy runtime. We do NOT blanket-replace the deploy root here because
        # rt CONTAINS the deploy root, which would re-expand and multiply. The
        # home/executable lines are already force-written above, and
        # command/uv/base-prefix lines are dropped, so any leftover absolute path
        # is a genuine build-path leak that the verify step will catch.
        text = text.replace(RT_TOKEN, rt)
    if text != "\n".join(lines):
        changed = True
    if changed:
        open(cfg, "w", encoding="utf-8").write(text)
    return True


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("build", "install"):
        print("usage: _rewrite_paths.py <build|install> <PACKAGE_DIR>", file=sys.stderr)
        sys.exit(2)
    mode = sys.argv[1]
    pkg = os.path.abspath(sys.argv[2])

    # pyvenv.cfg relocation is independent of editable metadata and MUST run even
    # when site-packages is (for any reason) absent. Always handle it first.
    pv_changed = _fix_pyvenv(pkg, mode)

    sp = _site_packages(pkg)
    if not sp:
        print("    [skip] site-packages not found", file=sys.stderr)
        if mode == "build":
            if pv_changed:
                print("    [build] tokenized pyvenv.cfg")
            return
        # install: still verify pyvenv below
    files = _files(sp) if sp else []

    # Exact roots to match. The editable finder (a .py SOURCE file) stores
    # Windows paths with DOUBLED backslashes (a Python string literal: 'D:\\\\a\\..'),
    # while direct_url.json uses forward slashes (file:///D:/a/..). os.path.abspath
    # gives a single-backslash path, so we must try EVERY separator variant of the
    # full package root, otherwise the Windows finder is left untouched and hermes
    # keeps importing from the build path.
    pkg_fwd = pkg.replace("\\", "/")
    pkg_bak = pkg.replace("/", "\\")
    pkg_dbl = pkg.replace("\\", "\\\\")  # doubled, as stored in the .py finder

    changed = []
    for f in files:
        t = open(f, encoding="utf-8").read()
        orig = t
        if mode == "build":
            for root in (pkg, pkg_fwd, pkg_bak, pkg_dbl):
                t = t.replace(root, TOKEN)
        else:  # install
            # Restore with the SAME escaping the file uses, so the result is a
            # valid Python string literal. A .py finder on Windows stores paths
            # as DOUBLED backslashes ('C:\\\\Users\\..'); writing a single-
            # backslash prefix ('C:\\Users') would make '\\U' a unicode-escape and
            # crash on import (SyntaxError: 'unicodeescape'). So match doubling.
            if "\\\\" in t:
                sep = "\\\\"          # doubled backslash (Windows .py finder)
            elif "\\" in t:
                sep = "\\"           # single backslash
            else:
                sep = "/"            # forward slash (Unix)
            deploy = pkg.replace("/", sep).replace("\\", sep)
            t = t.replace(TOKEN, deploy)
            # safety: if the build left a literal pkg path (token missing),
            # replace it exactly (no regex) so relocation is still correct.
            for root in (pkg, pkg_fwd, pkg_bak, pkg_dbl):
                t = t.replace(root, deploy)
        if t != orig:
            open(f, "w", encoding="utf-8").write(t)
            changed.append(f)

    if mode == "build":
        print("    [build] tokenized editable metadata (%d files)" % len(changed))
        if pv_changed:
            print("    [build] tokenized pyvenv.cfg")
        return

    # install mode: verify the rewrite actually removed every absolute path that
    # is NOT the deploy root. A leftover token or a stray build path is a real
    # relocation failure (fail hard). We compare against the actual deploy dir,
    # so running in-place on CI (deploy == build workspace) does NOT false-fail.
    #
    # Normalize drive letters + separators before comparing: editable metadata on
    # Windows may store a path WITHOUT a drive letter (e.g. /Users/runneradmin/...)
    # while the deploy dir has one (C:/Users/...). Stripping the drive letter on
    # both sides makes the startswith check correct on every platform.
    def _norm(p):
        # Fully normalize: undo Python's string-literal escaping (\\ -> \), then
        # unify separators (\ -> /), then collapse any accidental // -> /. This
        # makes a Windows doubled-backslash path ('C:\\\\Users\\..') comparable to
        # the forward-slash deploy dir (/users/...), and avoids false mismatches
        # from the doubled separators.
        p = p.replace("\\\\", "\\").replace("\\", "/").replace("//", "/").lower()
        if len(p) >= 2 and p[1] == ":":
            p = p[2:]
        return p

    deploy_n = _norm(pkg_fwd)
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
        for m in re.findall(r'(?:/home/|/Users/|/root/|[A-Za-z]:\\)[^\"\'\s\\]*', c):
            if not _norm(m).startswith(deploy_n):
                bad.append((f, m))
                break
    # pyvenv.cfg verify: must contain no token and no build path.
    if pv_changed or os.path.isfile(_pyvenv_cfg(pkg)):
        c = open(_pyvenv_cfg(pkg), encoding="utf-8").read().replace("\\", "/")
        if RT_TOKEN in c or TOKEN in c:
            bad.append((_pyvenv_cfg(pkg), "leftover token"))
        else:
            for m in re.findall(r'(?:/home/|/Users/|/root/|[A-Za-z]:\\)[^\"\'\s\\]*', c):
                if not _norm(m).startswith(deploy_n):
                    bad.append((_pyvenv_cfg(pkg), m))
                    break
    if bad:
        for f, why in bad:
            print("    [FAIL] %s : %s" % (f, why), file=sys.stderr)
        print("FAIL: editable metadata still has non-deploy absolute path", file=sys.stderr)
        sys.exit(1)
    print("    [install] relocated editable metadata -> %s (%d files) + verified" % (pkg, len(changed)))


if __name__ == "__main__":
    main()
