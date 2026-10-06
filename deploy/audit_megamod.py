"""Independent check of the PC after install_megamod.py ran (reads only, changes nothing).

It uses none of the installer's logic: the state of the Mods folder, the save folder, UE4SS.dll and
the desktop shortcut is compared with the baseline the installer recorded before it changed
anything (baseline-hashes.json in the newest megamod-install-backup-* folder), with the package
itself and with the copies of the retired mods. The only thing it takes from install_megamod.py
(which must lie next to it) is the take-over table TAKEOVERS: which mod is replaced by which module.

Usage:  python audit_megamod.py [--package ZIP] [--sha256 HASH] [--version X] [--backup FOLDER]
            --package   the package that was installed (default: the one the installer's report names, in the
                        package folder); it is checked against the manifest next to it
            --sha256    the sha256 the package file must have (default: the one in the installer's report)
            --version   the version that must be installed (default: the one the package names)
            --backup    the backup folder of the run to check (default: the newest one)
        last line: AUDIT OK (n checks) or AUDIT FAILED
"""
import argparse
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import zipfile

# This PC's places: deploy_settings.json next to this script (not in the repository; copy
# deploy_settings.example.json and fill it in). sim_megamod.py, which imports this file, sets them itself.
def _local_settings():
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "deploy_settings.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


_LOCAL = _local_settings()
GAME = _LOCAL.get("game", "")                   # the Gothic 1 Remake folder
UE4SS = GAME + r"\G1R\Binaries\Win64\ue4ss"
MODS = UE4SS + r"\Mods"
SAVES = _LOCAL.get("saves", "")                 # ...\AppData\Local\G1R\Saved\SaveGames
WS = _LOCAL.get("project", "")                  # the folder with megamod\ (the packages) and the backup folders
PKGDIR = WS + r"\megamod"
SHORTCUT = _LOCAL.get("shortcut", "")           # the desktop shortcut of the settings app
EXPECTED_UE4SS = "e1909f981e3f4c1dd603e9fc4e133fa679168e5d13d6d280b1dd79ed8f1dcaa3"
NAME = "G1R_MegaMod"
SETTINGS_EXE = "G1R_Repopulate_Settings.exe"
SETTINGS_EXE_REL = "modules/repopulate/" + SETTINGS_EXE
SKILLFULLOCKS_MAIN = "858c966c"             # the patched main.lua of SkillfulLocks (update of 2026-10-01) starts with this
HERE = os.path.dirname(os.path.abspath(__file__))
TAKEOVERS = None                            # [(mod folder, kind, our module)]; read from install_megamod.py when None

oks, fails = 0, 0


def check(cond, text):
    global oks, fails
    if cond:
        oks += 1
        print("ok   " + text)
    else:
        fails += 1
        print("FAIL " + text)
    return cond


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def hashes(root):
    out = {}
    for base, _, names in os.walk(root):
        for n in names:
            p = os.path.join(base, n)
            out[os.path.relpath(p, root).replace("\\", "/")] = sha(p)
    return out


def takeover_table():
    """The one take-over table, from install_megamod.py next to this file (nothing else of that file is used)."""
    spec = importlib.util.spec_from_file_location("install_megamod_table", os.path.join(HERE, "install_megamod.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return [(entry[0], entry[1], entry[2]) for entry in module.TAKEOVERS]


def below(tree, folder):
    """The part of a {path: hash} below a folder, paths relative to it."""
    pre = folder + "/"
    return {k[len(pre):]: v for k, v in tree.items() if k.startswith(pre)}


def folder_of(tree, name):
    """The folder of a mod in a {path: hash} of Mods, found without regard to case (None when it is not there)."""
    folders = sorted(set(k.split("/", 1)[0] for k in tree if "/" in k))
    return name if name in folders else next((f for f in folders if f.lower() == name.lower()), None)


def is_mod(inside):
    """Whether a folder's files make it a mod UE4SS starts: Scripts\\main.lua (in either spelling) or dlls\\main.dll."""
    lower = set(k.lower() for k in inside)
    return "scripts/main.lua" in lower or "dlls/main.dll" in lower


def is_settings_file(rel):
    return re.match(r"^(?:Scripts|modules/[^/]+/Scripts)/config\.lua$", rel, re.I) is not None


def config_lines(data, keys):
    """A config.lua text as (its lines without the lines that set one of `keys`, {key: the value its last line gives})."""
    setter = re.compile(rb"^[ \t]*Config\.(" + b"|".join(re.escape(k.encode("ascii")) for k in keys) + rb")[ \t]*=[ \t]*(.*?)[ \t\r]*$")
    rest, values = [], {}
    for line in data.split(b"\n"):
        m = setter.match(line) if keys else None
        if m:
            values[m.group(1).decode("ascii")] = m.group(2).decode("utf-8", "replace")
        else:
            rest.append(line)
    return rest, values


def main(argv=None):
    ap = argparse.ArgumentParser(description="Independent check of the PC after install_megamod.py ran (reads only).")
    ap.add_argument("--package", metavar="ZIP", help="the package that was installed (default: the one the installer's report names)")
    ap.add_argument("--sha256", metavar="HASH", help="the sha256 the package file must have (default: the one in the installer's report)")
    ap.add_argument("--version", metavar="X", help="the version that must be installed (default: the one the package names)")
    ap.add_argument("--backup", metavar="FOLDER", help="the backup folder of the run to check (default: the newest one)")
    args = ap.parse_args([] if argv is None else argv)
    if not (GAME and SAVES and WS and SHORTCUT):
        print('deploy_settings.json next to this script is missing or incomplete (game, saves, project, shortcut): copy deploy_settings.example.json and fill it in.')
        return 2
    for stream in (sys.stdout, sys.stderr):             # a character the console cannot show must not stop the check
        try:
            stream.reconfigure(errors="backslashreplace")
        except (AttributeError, ValueError, OSError):
            pass
    try:
        table = TAKEOVERS if TAKEOVERS is not None else takeover_table()
    except Exception as e:
        check(False, "the take-over table can be read from install_megamod.py next to this script (%s: %s)" % (type(e).__name__, e))
        return finish()

    # 1. nothing is running
    try:
        r = subprocess.run(["tasklist", "/FO", "CSV", "/NH"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        images = [l.strip()[1:].split('"', 1)[0].lower() for l in r.stdout.decode("ascii", "replace").splitlines() if l.strip().startswith('"')]
    except Exception:
        images = None
    check(images is not None and not [n for n in images if n in ("g1r-win64-shipping.exe", "g1r.exe") or "gothic" in n],
          "the game is not running (and was not started by this check)")

    # 2. the backup folder of the run
    if args.backup:
        backup = os.path.abspath(args.backup)
        found = os.path.isdir(backup)
    else:
        folders = sorted(d for d in os.listdir(WS) if d.startswith("megamod-install-backup-") and os.path.isdir(os.path.join(WS, d)))
        found = bool(folders)
        backup = os.path.join(WS, folders[-1]) if folders else ""
    if not check(found, "a megamod-install-backup-* folder exists in the project folder"):
        return finish()
    print("     backup folder: %s" % backup)
    try:
        with open(os.path.join(backup, "baseline-hashes.json"), encoding="utf-8") as f:
            base = json.load(f)
        with open(os.path.join(backup, "install-report.json"), encoding="utf-8") as f:
            report = json.load(f)
    except (OSError, ValueError) as e:
        check(False, "the backup folder has the installer's baseline and report (%s) - a run that did not finish? Its rollback script is in that folder" % e)
        return finish()
    mode = report.get("mode")
    check(report.get("ok") is True and report.get("problems") == [] and mode in ("install", "update", "sync-settings"),
          "the installer's report: ok, no problems, mode %s%s" % (mode, "" if report.get("ok") is True else " - PROBLEMS: " + "; ".join(str(p) for p in report.get("problems", []))[:300]))
    check(os.path.isfile(os.path.join(backup, "ROLLBACK-megamod-install.ps1")), "the rollback script is in the backup folder")

    # 3. UE4SS
    dll = sha(os.path.join(UE4SS, "UE4SS.dll"))
    check(dll == EXPECTED_UE4SS and dll == base["ue4ss_dll"], "UE4SS.dll is the AngelScript Fix 0.4 build, unchanged (sha256 %s...)" % dll[:16])

    # 4. the package: the file the installer used, and exactly what its manifest says
    zip_path = os.path.join(PKGDIR, str(report.get("package")))
    if args.package:
        zip_path = os.path.abspath(args.package)
    elif not os.path.isfile(zip_path) and os.path.isfile(str(report.get("package_path"))):
        zip_path = report["package_path"]               # the installer was given a package from another folder
    wanted_sha = (args.sha256 or report.get("package_sha256") or "").lower()
    zip_sha = sha(zip_path) if os.path.isfile(zip_path) else None
    check(zip_sha is not None and (not wanted_sha or zip_sha == wanted_sha),
          "the package in the project folder is the one that was %s (%s, sha256 %s...)"
          % ("named" if args.sha256 else "installed", os.path.basename(zip_path), str(wanted_sha or zip_sha)[:16]))
    package, package_data = {}, {}
    if zip_sha is not None:
        try:
            with zipfile.ZipFile(zip_path) as zf:
                for i in zf.infolist():
                    if not i.is_dir():
                        package_data[i.filename[len(NAME) + 1:]] = zf.read(i)
        except (OSError, zipfile.BadZipFile):
            package_data = {}
        package = {rel: hashlib.sha256(data).hexdigest() for rel, data in package_data.items()}
    listed = {}
    manifest_path = zip_path[:-4] + "-manifest.sha256"
    if os.path.isfile(manifest_path):
        with open(manifest_path, encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split(None, 1)
                if len(parts) == 2 and parts[1].startswith("./"):
                    listed[parts[1][2:]] = parts[0].lower()
    check(bool(package) and listed == package, "the package holds exactly what the manifest next to it lists (%d files)" % len(listed))
    version_text = package_data.get("Scripts/core/version.lua", b"").decode("latin-1")
    named = re.search(r'\bversion\s*=\s*"([^"]+)"', version_text)
    version = args.version or (named.group(1) if named else None)

    # 5. the installed mod against the package and against what was there before
    now = hashes(MODS)
    pre = NAME + "/"
    mod = below(now, NAME)
    base_mods = base["mods"]
    before = below(base_mods, NAME)
    copies = {dst: src for src, dst in report.get("copies", [])}               # whole files of our own former mods
    converted = {c["config"]: c for c in report.get("conversions", []) if c.get("state") == "write"}
    app = report.get("settings_app") or None
    kept = sorted(r for r in package if (is_settings_file(r) or r == "enabled.txt") and r in before and r not in copies and r not in converted)
    plain = sorted(r for r in package if r not in kept and r not in copies and r not in converted and not (r == "enabled.txt" and mode != "install"))
    if mode == "sync-settings":
        wrong = sorted(r for r in before if r not in copies and r not in converted and mod.get(r) != before[r])
        check(not wrong, "every file of the mod that the run did not carry over is as before (%d files, %d differ)%s"
              % (len(before), len(wrong), "" if not wrong else ": " + ", ".join(wrong[:5])))
    else:
        wrong = sorted(r for r in plain if mod.get(r) != package[r])
        check(not wrong, "every file of the package is in Mods\\%s with the package's content (%d files, %d differ)%s"
              % (NAME, len(plain), len(wrong), "" if not wrong else ": " + ", ".join(wrong[:5])))
        wrong = sorted(r for r in kept if mod.get(r) != before[r])
        check(not wrong, "The player's own files that were there before are as before (%d: %s)%s"
              % (len(kept), ", ".join(kept) or "none", "" if not wrong else " - DIFFER: " + ", ".join(wrong[:5])))
    if copies:
        check(all(mod.get(dst) == base_mods.get(src) and dst in mod for dst, src in copies.items()),
              "module settings files are the ones the separate mods had: every file the run copied from a mod of our own is identical to that mod's (%d: %s)"
              % (len(copies), ", ".join(sorted(c.rsplit("/", 1)[-1] for c in copies))))
    extra = sorted(set(mod) - set(package))
    unknown = []
    for rel in extra:
        if rel in copies or rel in converted:
            continue
        if app and rel == SETTINGS_EXE_REL and mod[rel] == app.get("sha256"):
            continue
        if before.get(rel) != mod[rel]:
            unknown.append(rel)
    check(not unknown, "besides the package only files that were there before, unchanged, or that the run reports are in the folder (%d: %s)%s"
          % (len(extra), ", ".join(e.rsplit("/", 1)[-1] for e in extra[:6]) + (", ..." if len(extra) > 6 else ""), "" if not unknown else " - UNKNOWN: " + ", ".join(unknown[:5])))
    gone = sorted(set(before) - set(mod))
    removed = sorted(report.get("removed", []))
    kept_copies = hashes(os.path.join(backup, "removed")) if os.path.isdir(os.path.join(backup, "removed")) else {}
    check(gone == removed and all(kept_copies.get(r) == before[r] for r in gone),
          "the files that are gone from the folder are the ones the old version had and the new one has not, each with its copy in the backup folder (%d)%s"
          % (len(gone), "" if gone == removed else " - gone: %s; reported: %s" % (", ".join(gone[:4]), ", ".join(removed[:4]))))
    changed = sorted(r for r in before if r in mod and mod[r] != before[r])
    old_copies = hashes(os.path.join(backup, "replaced")) if os.path.isdir(os.path.join(backup, "replaced")) else {}
    lost = [r for r in changed if old_copies.get(r) != before[r]]
    check(not lost, "every file of the folder that was replaced has its old version in the backup folder (%d replaced)%s"
          % (len(changed), "" if not lost else " - MISSING: " + ", ".join(lost[:5])))
    try:
        with open(os.path.join(MODS, NAME, "Scripts", "core", "version.lua"), encoding="latin-1") as f:
            installed_version = f.read()
    except OSError:
        installed_version = ""
    if mode == "sync-settings":
        check(('"%s"' % NAME) in installed_version, "the folder is the mod %s" % NAME)
    else:
        check(bool(version) and ('version = "%s"' % version) in installed_version, "it is version %s" % version)
    if mode == "install":
        check("enabled.txt" in mod, "enabled.txt is in the folder (UE4SS starts a mod that has it)")
    else:
        check(mod.get("enabled.txt") == before.get("enabled.txt"), "enabled.txt is as it was before the run (%s)" % ("there" if "enabled.txt" in mod else "not there"))

    # 6. the take-overs: every mod of the table is either retired (gone from Mods, complete copy in the backup
    #    folder) or still in Mods as it was, and then the report says why
    left = [d for d in os.listdir(MODS) if ".retired-" in d]
    check(not left, "Mods has neither a retired mod's left-over (*.retired-*) nor a half-removed folder")
    copies_of = hashes(os.path.join(backup, "retired")) if os.path.isdir(os.path.join(backup, "retired")) else {}
    states = {str(t.get("mod")): t for t in report.get("takeovers", []) if isinstance(t, dict)}
    legacy_status = report.get("status", {}) if not states else {}
    table_folders = []
    for name, kind, module in table:
        was = folder_of(base_mods, name)
        was_files = below(base_mods, was) if was else {}
        was_mod = bool(was) and is_mod(was_files)
        here = folder_of(now, name)
        here_files = below(now, here) if here else {}
        table_folders.extend(f for f in (was, here) if f)
        told = states.get(name, {})
        state = told.get("state") or legacy_status.get(name)
        if not was_mod and not here_files:
            check(state in (None, "absent"), "%s (-> module %s): not installed before the run and not now: nothing to do" % (name, module))
        elif was_mod and not here_files:
            have = below(copies_of, was)
            check(have == was_files and state == "retired" and not os.path.exists(os.path.join(MODS, was)),
                  "%s (-> module %s): retired - gone from Mods, and the copy of %s in the backup folder has every file as it was before (%d files)"
                  % (name, module, name, len(was_files)))
        elif was_mod and state == "retired" and os.path.isfile(os.path.join(backup, "put-back-%s.txt" % was)):
            check(here_files == was_files and below(copies_of, was) == was_files,
                  "%s (-> module %s): retired by the run and put back afterwards with the rollback script's -Only: in Mods again, every file as before (%d)"
                  % (name, module, len(was_files)))
        elif was_mod:
            check(here_files == was_files and state in ("left", "kept") and state is not None,
                  "%s (-> module %s): still in Mods, every file as before (%d), and the report says so: %s"
                  % (name, module, len(was_files), told.get("why") or state or "NOT REPORTED"))
        else:
            check(here_files == was_files, "%s (-> module %s): a folder of that name that holds no mod is as before (%d files)" % (name, module, len(was_files)))

    # 7. nothing else in Mods changed
    skip = (pre,) + tuple(sorted(set(f + "/" for f in table_folders)))
    others_before = {k: v for k, v in base_mods.items() if not k.startswith(skip)}
    others_now = {k: v for k, v in now.items() if not k.startswith(skip)}
    diff = sorted(k for k in set(others_before) | set(others_now) if others_before.get(k) != others_now.get(k))
    check(not diff, "every other file in Mods is as before: %d files in %d folders%s"
          % (len(others_now), len(set(k.split("/", 1)[0] for k in others_now if "/" in k)), "" if not diff else " - DIFFER: " + ", ".join(diff[:6])))
    check(now.get("mods.txt") == base_mods.get("mods.txt") and now.get("mods.json") == base_mods.get("mods.json") and "mods.txt" in now and "mods.json" in now,
          "mods.txt and mods.json are unchanged (mods.txt %s..., mods.json %s...)" % (str(now.get("mods.txt"))[:8], str(now.get("mods.json"))[:8]))
    flags_before = sorted(k for k in others_before if k.endswith("/enabled.txt"))
    flags_now = sorted(k for k in others_now if k.endswith("/enabled.txt"))
    check(flags_before == flags_now, "the same %d other mods have enabled.txt as before" % len(flags_now))
    locks = folder_of(base_mods, "SkillfulLocks")
    patched = base_mods.get("%s/Scripts/main.lua" % locks) if locks else None
    if patched is None:
        print("     SkillfulLocks was not installed before the run: its patched main.lua is not looked for")
    else:
        where = now.get("%s/Scripts/main.lua" % locks) or copies_of.get("%s/Scripts/main.lua" % locks)
        check(patched.startswith(SKILLFULLOCKS_MAIN) and where == patched, "SkillfulLocks still has the patched main.lua of the last update (%s)"
              % ("in Mods" if ("%s/Scripts/main.lua" % locks) in now else "in its copy in the backup folder"))

    # 8. the saves
    saves = hashes(SAVES)
    check(base.get("saves") is not None and saves == base["saves"], "the save folder is unchanged: %d files, same hashes" % len(saves))

    # 9. the settings carried over from other authors' mods: our config.lua is the package's default file with
    #    exactly the reported values put in, and they were read from the files that are now in the backup folder
    for conv in report.get("conversions", []):
        rel, keys = conv.get("config", ""), list(conv.get("set", {}))
        what = "%s -> %s" % (conv.get("mod"), rel)
        if conv.get("state") == "write":
            try:
                with open(os.path.join(MODS, NAME, rel.replace("/", os.sep)), "rb") as f:
                    text = f.read()
            except OSError:
                text = b""
            rest_now, values = config_lines(text, keys)
            rest_default, _ = config_lines(package_data.get(rel, b"\x00"), keys)
            inserted = [k for k in keys if not re.search(rb"(?m)^[ \t]*Config\." + re.escape(k.encode("ascii")) + rb"[ \t]*=", package_data.get(rel, b""))]
            check(rest_now == rest_default and all(values.get(k) == v for k, v in conv["set"].items()) and bool(keys),
                  "settings carried over, %s: the file is the package's default with %s%s and nothing else changed"
                  % (what, ", ".join("%s = %s" % (k, values.get(k)) for k in keys), (" (%d line(s) added)" % len(inserted)) if inserted else ""))
            folder = folder_of(base_mods, str(conv.get("mod")))
            sources = conv.get("from", {})
            check(bool(sources) and all(base_mods.get("%s/%s" % (folder, src)) == digest for src, digest in sources.items()),
                  "and those values were read from %s as it was before the run" % ", ".join("%s\\%s" % (conv.get("mod"), s.replace("/", "\\")) for s in sources))
        elif conv.get("state") == "player":
            check(mod.get(rel) == before.get(rel) and rel in mod,
                  "settings NOT carried over, %s: the file the player had changed is as before (%s)" % (what, conv.get("why")))
    if report.get("not_carried"):
        by_mod = {}
        for item in report["not_carried"]:
            by_mod.setdefault(str(item.get("mod")), []).append(str(item.get("what")))
        for name in sorted(by_mod):
            print("     not carried over from %s: %s%s" % (name, "; ".join(by_mod[name][:6]), " ... (%d in all)" % len(by_mod[name]) if len(by_mod[name]) > 6 else ""))

    # 10. the settings app
    exe = os.path.join(MODS, NAME, "modules", "repopulate", SETTINGS_EXE)
    if app:
        was_exe = before.get(SETTINGS_EXE_REL)
        check(mod.get(SETTINGS_EXE_REL) == app.get("sha256") and (was_exe is None or was_exe == app.get("sha256") or old_copies.get(SETTINGS_EXE_REL) == was_exe),
              "the settings app is the one given to the installer (sha256 %s...)%s" % (str(app.get("sha256"))[:16],
              "" if was_exe in (None, app.get("sha256")) else ", and the one that was there is in the backup folder"))
    elif mode != "install" and SETTINGS_EXE_REL in before:
        check(mod.get(SETTINGS_EXE_REL) == before[SETTINGS_EXE_REL], "the settings app is the one that was there (sha256 %s...)" % before[SETTINGS_EXE_REL][:16])

    # 11. the desktop shortcut
    shortcut = report.get("shortcut")
    if isinstance(shortcut, dict) and shortcut.get("after"):
        script = ("[Console]::OutputEncoding = [Text.Encoding]::UTF8; $s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:G1R_LNK); "
                  "[Console]::Out.Write($s.TargetPath + [char]10 + $s.WorkingDirectory)")
        try:
            r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script],
                               env=dict(os.environ, G1R_LNK=SHORTCUT), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
            parts = r.stdout.decode("utf-8", "replace").lstrip("\ufeff").split("\n") if r.returncode == 0 else []
        except Exception:
            parts = []
        norm = lambda p: os.path.normcase(os.path.normpath(p.strip()))
        check(len(parts) >= 2 and norm(parts[0]) == norm(exe) and norm(parts[1]) == norm(os.path.dirname(exe)) and os.path.isfile(exe),
              "the desktop shortcut starts the settings app inside %s (%s)" % (NAME, parts[0].strip() if parts else "not readable"))
        check(os.path.isfile(os.path.join(backup, "shortcut", os.path.basename(SHORTCUT))), "the shortcut as it was is in the backup folder")
    elif "shortcut" in base:
        current = sha(SHORTCUT) if os.path.isfile(SHORTCUT) else None
        check(current == base["shortcut"], "the desktop shortcut is as it was before the run (%s)" % ("not there" if current is None else "sha256 %s..." % current[:8]))
    return finish()


def finish():
    print("AUDIT OK (%d checks)" % oks if fails == 0 else "AUDIT FAILED (%d of %d checks)" % (fails, oks + fails))
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
