#!/usr/bin/env python3
"""Builds the release package of the mod - or refuses and says why.

    python dev/tools/build_release.py                    dev/out/dist/<name>-<version>.zip + manifest
    python dev/tools/build_release.py --with-dev         the same with the dev kit: <name>-<version>-dev.zip
    python dev/tools/build_release.py --check            all checks, nothing written
    python dev/tools/build_release.py --forbid-file F    words that must not appear anywhere (one per line)
    python dev/tools/build_release.py --foreign ZIP      files of another mod that must not be in the package

The zip has one top-level folder named after the mod; the manifest lists
`<sha256>  ./<path>` for every file in it. The same input gives the same zip,
byte for byte (sorted entries, fixed time stamp).

Left out: dev/ (unless --with-dev), dev/out/, what a game session wrote
(Scripts/diagnostics/*, modules/repopulate/Scripts/state/* - their README.txt
stays so that the folders exist), work files (*.bak *.tmp *.log *.from-*).

Refused, with nothing written:
  * a .lua file that does not compile, or a lint error (dev/tools/lint.py);
  * a path below somebody's home folder, or a forbidden word, in any file -
    binary files are searched for 8-bit and 16-bit text;
  * a file that is also in a --foreign zip (same content);
  * a save file or crash dump (*.sav, *.dmp) anywhere in the mod folder;
  * the settings app is in the package but modules/repopulate/Scripts/config.lua
    is not the default file the app was built for.
Keep the forbidden words (user name, machine name, e-mail, folder names of the
build machine) in a file OUTSIDE the mod and pass it with --forbid-file.

Python 3.8+, standard library only. Needs luac5.4 (or --luac).
"""
import argparse
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
import zipfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import lint  # noqa: E402

DEFAULT_ROOT = os.path.dirname(os.path.dirname(HERE))
FIXED_TIME = (2026, 1, 1, 0, 0, 0)
SETTINGS_APP = "G1R_Repopulate_Settings.exe"
SETTINGS_CONFIG = "modules/repopulate/Scripts/config.lua"
SETTINGS_CONFIG_SHA256 = "361ddd32bc00921ba58a41c8bfb9be3cf8c8863329069a9d313e717246e59ef2"
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()

WORK_FILES = ("*.bak", "*.tmp", "*.log", "*.from-*", "*.orig", "*.rej", "*.pyc", "Thumbs.db", ".DS_Store", "desktop.ini")
NEVER = ("*.sav", "*.dmp")
HOME_PATTERNS = [
    re.compile(r"[A-Za-z]:[\\/]+Users[\\/]+[^\\/\s\"'<>|*?]+", re.I),
    re.compile(r"/home/[a-z_][\w.-]*"),
    re.compile(r"/Users/[A-Za-z_][\w.-]*"),
]
NARROW_TEXT = re.compile(rb"[\x20-\x7e]{6,}")
WIDE_TEXT = re.compile(rb"(?:[\x20-\x7e]\x00){6,}")
TEXT_SUFFIXES = lint.TEXT_SUFFIXES


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def read_version(root):
    path = os.path.join(root, "Scripts", "core", "version.lua")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return None, None
    name = re.search(r'\bname\s*=\s*"([^"]+)"', text)
    version = re.search(r'\bversion\s*=\s*"([^"]+)"', text)
    return (name.group(1) if name else None), (version.group(1) if version else None)


def walk_all(root):
    out = []
    for base, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d != ".git")
        rel_base = os.path.relpath(base, root).replace("\\", "/")
        for name in sorted(files):
            out.append(name if rel_base == "." else rel_base + "/" + name)
    return out


def left_out_reason(rel, with_dev):
    """Why a file is not part of the package, or None when it is."""
    name = rel.rsplit("/", 1)[-1]
    parts = rel.split("/")
    if rel.startswith("dev/out/"):
        return "generated (dev/out)"
    if "__pycache__" in parts:
        return "work file"
    if parts[0] == "dev" and not with_dev:
        return "dev kit (add --with-dev)"
    if rel.startswith("Scripts/diagnostics/") and name != "README.txt":
        return "written by a game session (diagnostics)"
    if rel.startswith("modules/repopulate/Scripts/state/") and name != "README.txt":
        return "written by a game session (progress of a profile)"
    if any(fnmatch.fnmatch(name, p) for p in WORK_FILES):
        return "work file"
    if name.startswith(".") and name not in (".",):
        return "hidden file"
    return None


def texts_of(data, is_text):
    """The pieces of text in a file: (kind, text). Binary files: 8-bit and 16-bit strings of 6+ characters."""
    if is_text:
        yield "text", data.decode("latin-1")
        return
    for m in NARROW_TEXT.finditer(data):
        yield "8-bit text", m.group(0).decode("latin-1")
    for m in WIDE_TEXT.finditer(data):
        yield "16-bit text", m.group(0).decode("utf-16-le", "replace")


def forbidden_in(path, rel, forbid):
    """Findings (text) for one file: home paths and forbidden words."""
    with open(path, "rb") as f:
        data = f.read()
    is_text = rel.lower().endswith(TEXT_SUFFIXES)
    found, seen = [], set()
    low_forbid = [w.lower() for w in forbid]
    for kind, text in texts_of(data, is_text):
        for pattern in HOME_PATTERNS:
            for m in pattern.finditer(text):
                key = ("home", m.group(0))
                if key not in seen:
                    seen.add(key)
                    found.append("%s: path below a home folder (%s): %s" % (rel, kind, m.group(0)[:80]))
        if low_forbid:
            low = text.lower()
            for word, shown in zip(low_forbid, forbid):
                if word in low and ("word", word) not in seen:
                    seen.add(("word", word))
                    found.append("%s: forbidden word '%s' (%s)" % (rel, shown, kind))
        if len(found) >= 20:
            break
    return found


def foreign_hashes(zips):
    known = {}
    for z in zips:
        with zipfile.ZipFile(z) as zf:
            for info in zf.infolist():
                if info.is_dir():
                    continue
                digest = hashlib.sha256(zf.read(info)).hexdigest()
                if digest != EMPTY_SHA256:
                    known.setdefault(digest, "%s:%s" % (os.path.basename(z), info.filename))
    return known


def build(root, out_dir=None, name=None, version=None, with_dev=False, forbid=(), foreign=(), luac=None, check_only=False):
    r = {"built": False, "refused": [], "left_out": {}, "files": 0, "bytes": 0, "zip": None, "manifest": None, "notes": []}
    v_name, v_version = read_version(root)
    name, version = name or v_name, version or v_version
    if not name or not version:
        r["refused"].append("Scripts/core/version.lua does not give name and version (and none was given)")
        return r
    if not re.match(r"^[A-Za-z0-9_.-]+$", name) or not re.match(r"^[A-Za-z0-9_.+-]+$", version):
        r["refused"].append("name or version has characters that do not belong in a file name")
        return r
    r["name"], r["version"] = name, version

    everything = walk_all(root)
    included = []
    for rel in everything:
        reason = left_out_reason(rel, with_dev)
        if reason:
            r["left_out"].setdefault(reason, []).append(rel)
        else:
            included.append(rel)
    if not any(rel == "Scripts/main.lua" for rel in included):
        r["refused"].append("Scripts/main.lua is missing: this is not the mod folder")
        return r

    # 1. files that must never be near a release
    for rel in everything:
        if rel.startswith("dev/out/"):
            continue
        if any(fnmatch.fnmatch(rel.rsplit("/", 1)[-1].lower(), p) for p in NEVER):
            r["refused"].append("%s: a save file or crash dump is in the mod folder" % rel)

    # 2. syntax and lint
    luac_tool = lint.find_tool(luac, ("luac5.4", "luac54", "luac"))
    if luac_tool is None:
        r["refused"].append("luac5.4 not found (give --luac): the Lua files cannot be checked")
    else:
        for rel in included:
            if rel.endswith(".lua"):
                p = subprocess.run([luac_tool, "-p", os.path.join(root, rel)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if p.returncode != 0:
                    r["refused"].append("%s does not compile: %s" % (rel, p.stderr.decode("utf-8", "replace").strip().splitlines()[-1][-160:]))
        result = lint.run(root, luac_tool, forbid)
        for f in result.findings:
            if f["severity"] == "error" and (with_dev or not f["file"].startswith("dev/")):
                r["refused"].append("lint: %s:%d [%s] %s" % (f["file"], f["line"], f["rule"], f["text"]))
        r["lint_warnings"] = result.count("warning")

    # 3. personal paths and forbidden words, in every file of the package
    for rel in included:
        r["refused"].extend(forbidden_in(os.path.join(root, rel), rel, forbid))

    # 4. files of another mod
    hashes = {}
    for rel in included:
        hashes[rel] = sha256_of(os.path.join(root, rel))
    if foreign:
        known = foreign_hashes(foreign)
        for rel in included:
            if hashes[rel] in known:
                r["refused"].append("%s is a file of another mod (%s)" % (rel, known[hashes[rel]]))
        r["notes"].append("compared with %d file(s) of %d foreign package(s)" % (len(known), len(foreign)))
    else:
        r["notes"].append("no --foreign package given: not checked against the files of other mods")

    # 5. the settings app and the file it was built for
    if any(rel.rsplit("/", 1)[-1] == SETTINGS_APP for rel in included):
        if hashes.get(SETTINGS_CONFIG) != SETTINGS_CONFIG_SHA256:
            r["refused"].append("%s is in the package, but %s is not the default file the app was built for (sha256 %s...)"
                                % (SETTINGS_APP, SETTINGS_CONFIG, SETTINGS_CONFIG_SHA256[:16]))
    if not forbid:
        r["notes"].append("no forbidden words given (--forbid-file): only paths below home folders were searched for")

    r["files"] = len(included)
    r["bytes"] = sum(os.path.getsize(os.path.join(root, rel)) for rel in included)
    r["refused"] = sorted(set(r["refused"]))
    if r["refused"] or check_only:
        return r

    # write
    out_dir = out_dir or os.path.join(root, "dev", "out", "dist")
    os.makedirs(out_dir, exist_ok=True)
    stem = "%s-%s%s" % (name, version, "-dev" if with_dev else "")
    zip_path = os.path.join(out_dir, stem + ".zip")
    manifest_path = os.path.join(out_dir, stem + "-manifest.sha256")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel in sorted(included):
            info = zipfile.ZipInfo(name + "/" + rel, date_time=FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 0
            info.external_attr = 0
            with open(os.path.join(root, rel), "rb") as f:
                zf.writestr(info, f.read(), compresslevel=9)
    with open(manifest_path, "w", encoding="ascii", newline="\n") as f:
        for rel in sorted(included):
            f.write("%s  ./%s\n" % (hashes[rel], rel))
    # read it back: the package must hold exactly what the manifest says
    with zipfile.ZipFile(zip_path) as zf:
        names = sorted(i.filename for i in zf.infolist())
        if names != sorted(name + "/" + rel for rel in included):
            r["refused"].append("the zip does not hold the expected files (internal problem)")
        for rel in included:
            if hashlib.sha256(zf.read(name + "/" + rel)).hexdigest() != hashes[rel]:
                r["refused"].append("%s differs inside the zip (the file changed while the package was built?)" % rel)
    if r["refused"]:
        for p in (zip_path, manifest_path):
            try:
                os.remove(p)
            except OSError:
                pass
        return r
    r["built"] = True
    r["zip"], r["manifest"] = zip_path, manifest_path
    r["zip_sha256"], r["manifest_sha256"] = sha256_of(zip_path), sha256_of(manifest_path)
    r["zip_bytes"] = os.path.getsize(zip_path)
    return r


def render(r, check_only):
    L = []
    if "name" in r:
        L.append("%s %s: %d file(s), %d bytes in the package" % (r["name"], r["version"], r["files"], r["bytes"]))
    for reason in sorted(r["left_out"]):
        names = r["left_out"][reason]
        L.append("left out, %s: %d file(s)%s" % (reason, len(names), "" if len(names) > 6 else (" - " + ", ".join(names))))
        if len(names) > 6:
            L.append("    " + ", ".join(names[:5]) + ", ... (%d more)" % (len(names) - 5))
    for note in r["notes"]:
        L.append("note: " + note)
    if r.get("lint_warnings"):
        L.append("note: %d lint warning(s) (python dev/tools/lint.py)" % r["lint_warnings"])
    if r["refused"]:
        L.append("REFUSED - nothing written:")
        for x in r["refused"][:60]:
            L.append("  * " + x)
        if len(r["refused"]) > 60:
            L.append("  * (%d more)" % (len(r["refused"]) - 60))
    elif check_only:
        L.append("CHECK OK - nothing written (--check)")
    else:
        L.append("BUILT %s" % r["zip"])
        L.append("  %d bytes, sha256 %s" % (r["zip_bytes"], r["zip_sha256"]))
        L.append("  manifest %s, sha256 %s" % (os.path.basename(r["manifest"]), r["manifest_sha256"]))
    return "\n".join(L)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Build the release package of the mod, or refuse and say why.")
    ap.add_argument("--root", default=DEFAULT_ROOT, help="the mod folder (default: the one this tool is in)")
    ap.add_argument("--out", help="output folder (default: <mod>/dev/out/dist)")
    ap.add_argument("--name", help="package and top-level folder name (default: from Scripts/core/version.lua)")
    ap.add_argument("--version", help="version (default: from Scripts/core/version.lua)")
    ap.add_argument("--with-dev", action="store_true", help="include the dev kit (dev/)")
    ap.add_argument("--forbid", action="append", default=[], metavar="WORD", help="a word that must not appear in any file (repeatable)")
    ap.add_argument("--forbid-file", metavar="FILE", help="file with one forbidden word per line (keep it outside the mod)")
    ap.add_argument("--foreign", action="append", default=[], metavar="ZIP", help="package of another mod whose files must not be included (repeatable)")
    ap.add_argument("--luac", help="Lua 5.4 compiler (default: luac5.4 on the PATH)")
    ap.add_argument("--check", action="store_true", help="run every check, write nothing")
    ap.add_argument("--json", action="store_true", help="print the result as JSON")
    args = ap.parse_args(argv)
    forbid = [w for w in args.forbid if w.strip()]
    if args.forbid_file:
        with open(args.forbid_file, "r", encoding="utf-8", errors="replace") as f:
            forbid += [l.strip() for l in f if l.strip() and not l.startswith("#")]
    for z in args.foreign:
        if not os.path.isfile(z):
            print("not a file: %s" % z, file=sys.stderr)
            return 2
    r = build(os.path.abspath(args.root), args.out, args.name, args.version, args.with_dev, forbid, args.foreign, args.luac, args.check)
    if args.json:
        print(json.dumps(r, indent=1))
    else:
        print(render(r, args.check))
    return 1 if r["refused"] else 0


if __name__ == "__main__":
    sys.exit(main())
