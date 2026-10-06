#!/usr/bin/env python3
"""Mock-install tests for install_megamod.py and audit_megamod.py.

A mock of the PC is built below a temp folder: a Mods folder, a save folder, a fake UE4SS.dll, a
project folder with the packages, a desktop with the shortcut of the settings app. The installer
runs against it with its paths pointed there. The rollback script it writes is run with every
PowerShell that is found. The installed mod is started with Lua in the mock UE4SS of the mod's own
dev kit. The audit is run on the result and on states it must not accept.

Parts (all by default; --part NAME[,NAME] runs some):
  first    the first install of version 0.1.1 over our two own mods, as on the morning of
           2026-10-02 (package from --pkg). These are the checks the installer was released with.
  rules    the installer's readers and its config.lua rule against the mod's own Lua code.
  convert  the converters for the settings of the five mods of other authors: every mapping and
           every rule on files written for the case, the player's own files of 2026-10-01, and
           every converted file through the game's own settings code.
  update   the PC as it is now (0.1.1 installed, six mods of other authors next to it): update
           to the new version, take-over with the settings of all six carried over, audit, second
           run, rollback, rollback -Only. --show-plan prints the plan the installer makes there.
  cases    everything that can be different or go wrong around that.

What the settings of the five mods become is known to the letter for the player's files of
2026-10-01 (SNAPSHOT, PLAYER below). A mock that holds another file of a mod - a stand-in, or the
PC's own file in a rehearsal after the player changed a value - is checked for consistency only
(the game's own Settings.patch, the real settings service, the audit), and a note says so.

The new version's package is built from a temp copy of the mod's source (--mod-src) with the mod's
own builder; a module of the take-over table that the source does not have yet gets a tiny
stand-in there (never in the real tree). --new-pkg DIR takes a built package instead.

Runs on Linux (shortcut calls replaced by stand-ins, PowerShell 7 if present) and on Windows
(real shortcut calls through Windows Script Host, Windows PowerShell 5.1 and PowerShell 7).
On the PC, as a rehearsal on copies of the real folders (they are only read; everything happens below --sim):

    python sim_megamod.py --pkg <folder with the 0.1.1 package> --new-pkg <folder with the new package> --sim <temp folder>
                          --part update --pc-mods <the real Mods folder> --pc-backup <the backup folder of the 0.1.1 install>

(the other parts need --repop-src / --markers-src: the copies of our two own mods in that backup folder's
"retired" folder, with --as-is). --fail-fast stops at the first failed check.

Last line: ALL OK or FAILURES (exit code 0 / 1).
"""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import random
import re
import shutil
import subprocess
import sys
import zipfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
WINDOWS = os.name == "nt"
oks, fails = 0, 0
ARGS = None
WORK = None                 # scratch folder next to --sim: built packages, world templates
NEW = None                  # (folder, file name) of the new version's package
NEW_VERSION = None
NOTES = []                  # things to say once at the end


def check(cond, text):
    global oks, fails
    if cond:
        oks += 1
        print("ok   " + text)
    else:
        fails += 1
        print("FAIL " + text)
        if ARGS is not None and ARGS.fail_fast:
            print("%d checks, %d failed (stopped at the first failure)\nFAILURES" % (oks + fails, fails))
            sys.exit(1)
    return cond


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode("utf-8"))


def read(path):
    with open(path, "rb") as f:
        return f.read()


def sha_of(data):
    return hashlib.sha256(data).hexdigest()


def tree(root):
    """{relative path: sha256} of the files and {relative path + '/': 'dir'} of the folders below root."""
    out = {}
    for base, dirs, files in os.walk(root):
        for name in dirs:
            out[os.path.relpath(os.path.join(base, name), root) + os.sep] = "dir"
        for name in files:
            p = os.path.join(base, name)
            out[os.path.relpath(p, root)] = hashlib.sha256(read(p)).hexdigest()
    return out


def under(t, name):
    """The part of a tree() below the folder `name`, with paths relative to it."""
    pre = name + os.sep
    return {k[len(pre):]: v for k, v in t.items() if k.startswith(pre) and k != pre}


def without(t, *names):
    return {k: v for k, v in t.items() if not any(k == n + os.sep or k.startswith(n + os.sep) for n in names)}


def files_of(t, name):
    """The files below a folder of a tree(), with / in their paths."""
    return {k.replace(os.sep, "/"): v for k, v in under(t, name).items() if v != "dir"}


def wipe(path):
    """Removes a folder tree for good (read-only files included); raises when something of it stays."""
    if not os.path.lexists(path):
        return
    for base, dirs, files in os.walk(path, topdown=False):
        for name in files:
            p = os.path.join(base, name)
            try:
                os.remove(p)
            except PermissionError:
                os.chmod(p, 0o666)
                os.remove(p)
        for name in dirs:
            os.rmdir(os.path.join(base, name))
    os.rmdir(path)


def load_installer():
    spec = importlib.util.spec_from_file_location("install_megamod", os.path.join(HERE, "install_megamod.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---- the shortcut: on Windows the real thing, elsewhere a JSON file that plays the .lnk
def fake_shortcut_read(lnk):
    try:
        return json.loads(read(lnk).decode("utf-8"))
    except (OSError, ValueError):
        return None


def fake_shortcut_write(lnk, target, workdir, icon=""):
    info = fake_shortcut_read(lnk) or {"icon": ",0", "args": ""}
    info.update({"target": target, "workdir": workdir})
    if icon:
        info["icon"] = icon
    write(lnk, json.dumps(info))
    return True


OLD_PACKAGE = "G1R_MegaMod-0.1.1-dev.zip"           # the version that is installed on the PC now
MODS_TXT = b"CheatManagerEnablerMod : 0\r\nKeybinds : 0\r\nG1R_Repopulate : 1\r\nSkillfulLocks : 1\r\nHUDMap : 1\r\nNPCMarkers : 1\r\n"
SETTINGS_EXE = "G1R_Repopulate_Settings.exe"
OWN = ("G1R_Repopulate", "NPCMarkers")

# ---- the mods of other authors: copies of the real folders (--fixtures) where they exist, else these stand-ins
EXP_INI = (b"; EXPModifier - multiply the experience you gain\r\n\r\nExpMultiplier=4.0\r\n\r\nUpdateIntervalMs=250\r\n\r\n"
           b"ShowBonusMessage=true\r\n\r\nMessageDurationSeconds=3\r\n\r\nDebug=true\r\n")
REGEN_INI = (b"; G1R Regen Mana Native\nEnabled=true\n\nRegenValueRounding=0.1\nRecoveryIndicatorPrefix=>>\n\nManaEnabled=true\n"
             b"ManaSecondsPerTick=3.0\nManaPercentPerTick=2\nManaMaxRegenPercentage=75\nHealthEnabled=true\nHealthPerTick=1\n")
FAKES = {
    "EXPModifier": {"scripts/main.lua": b"-- EXPModifier\n", "scripts/modmenu.lua": b"-- menu\n", "enabled.txt": b"", "EXPModifier.ini": EXP_INI},
    "SkillfulLocks": {"Scripts/main.lua": b"-- SkillfulLocks\n", "Scripts/data/locksafe.lua": b"return {}\n", "enabled.txt": b"", "readme.txt": b"readme\n",
                      "Scripts/config.lua": b'-- SkillfulLocks configuration\nreturn {\n    removeConnections = {\n        untrained = false,  -- vanilla\n'
                                            b'        skilled   = "auto",\n        master    = "all",\n    },\n'
                                            b'    vanillaPrecision = { untrained = 0, skilled = 1, master = 2 },\n    debug = true,\n}\n'},
    "G1R_WaitOnT": {"Scripts/main.lua": b"-- G1R_WaitOnT\n", "enabled.txt": b""},
    "BetterMining": {"scripts/main.lua": b"-- BetterMining\n", "enabled.txt": b"",
                     "BetterMining.ini": b"; BetterMining\n\n[Settings]\nEnabled=true\nStrPerOre=4\nAgiPerOre=6\nPreventExhaustion=true\n;StrPerOre=1"},
    "G1R_MageBalance": {"Scripts/main.lua": b"-- G1R_MageBalance\n", "Scripts/lib/log.lua": b"return {}\n", "enabled.txt": b"",
                        "Scripts/config.lua": b'return {\n    ModName = "G1R Mage Balance",\n    Enabled = true,\n    Spells = {\n'
                                              b'        Feuerball = { class = "FireBallProjectileDefinition", damage = 1.25, mana = { 2 } },\n    },\n'
                                              b'    CircleCost = { 10, 12, 15, 18, 20, 25 },\n    Verbose = true,\n}\n'},
    "HUDMap": {"Scripts/main.lua": b"-- another mod\n", "settings.ini": b"x=1\n", "enabled.txt": b""},
    "SharedModMenu": {"Scripts/main.lua": b"-- another mod\n", "Scripts/config.lua": b"return { menuKey = \"F2\" }\n", "enabled.txt": b""},
    "BystanderXP": {"Scripts/main.lua": b"-- another mod\n", "settings.ini": b"Share=50\n", "enabled.txt": b""},
}
STAYING = ("HUDMap", "SharedModMenu", "BystanderXP")
PC_MODS_TXT = ("CheatManagerEnablerMod : 0\r\nKeybinds : 0\r\nBPModLoaderMod : 0\r\nG1R_Repopulate : 1\r\nBetterMining : 1\r\nBystanderXP : 1\r\n"
               "EXPModifier : 1\r\nG1R_MageBalance : 1\r\nG1R_RegenMana : 1\r\nG1R_WaitOnT : 1\r\nHUDMap : 1\r\nNPCMarkers : 1\r\nSharedModMenu : 1\r\n"
               "SkillfulLocks : 1\r\n").encode("ascii")

# ---- a tiny module, where the simulation needs one that the mod's source does not have (yet)
STANDIN_MAIN = """-- Stand-in for the module %(name)s (made by the installer's simulation; not part of the mod).
local KIT, SETTINGS = G1R_KIT, G1R_SETTINGS
if type(KIT) ~= "table" or type(SETTINGS) ~= "table" then return end
local SCRIPT_DIR = (function()
    local ok, src = pcall(function() return debug.getinfo(1, "S").source end)
    if ok and type(src) == "string" then
        local d = src:gsub("^@", ""):gsub("\\\\", "/"):match("^(.*/)[^/]+$")
        if d then return d end
    end
    return "./"
end)()
local Settings = SETTINGS.open({ module = "%(name)s", dir = SCRIPT_DIR, menu = false })
if Settings then print("[G1R_%(name)s] stand-in loaded\\n") end
"""
STANDIN_SCHEMA = """-- Stand-in settings of the module %(name)s (made by the installer's simulation).
local Schema = {}
Schema.Module = "%(name)s"
Schema.Page = "Stand-in"
Schema.Groups = {
    {
        Title = "Stand-in",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true, Label = "On", Comment = "A switch." },
            { Key = "Amount", Kind = "number", Default = 1.5, Min = 0, Max = 10, Step = 0.5, Decimals = 2, Label = "Amount", Comment = "A number." },
            { Key = "Count", Kind = "number", Default = 3, Min = 1, Max = 60, Decimals = 0, Label = "Count", Comment = "A whole number." },
            { Key = "Mode", Kind = "choice", Default = "auto", Options = { "auto", "all", "off" }, Label = "Mode", Comment = "A choice." },
            { Key = "Name", Kind = "text", Default = "", Label = "Name", Comment = "A text." },
            { Key = "Key", Kind = "key", Default = "", Label = "Key", Comment = "A key." },
            { Key = "Secret", Kind = "number", Default = 7, Min = 0, Max = 100, Decimals = 0, Hidden = true },
            { Key = "Quiet", Kind = "number", Default = 5, Min = 0, Max = 9, Decimals = 0, Hidden = true },
            { Key = "Push", Kind = "action", Label = "A button" },
        },
    },
}
return Schema
"""
STANDIN_CONFIG = """-- ============================================================================
-- Settings of the module %(name)s
-- ============================================================================
local Config = {}

-- ---- Stand-in ----
-- A switch.
Config.Enabled = true
-- A number.
Config.Amount = 1.5
-- A whole number.
Config.Count = 3
-- A choice.
Config.Mode = "auto"
-- A text.
Config.Name = ""
-- A key.
Config.Key = ""

return Config
"""


def standin_files(name):
    """{path inside the mod: bytes} of a stand-in module."""
    return {"modules/%s/Scripts/main.lua" % name: (STANDIN_MAIN % {"name": name}).encode("ascii"),
            "modules/%s/Scripts/schema.lua" % name: (STANDIN_SCHEMA % {"name": name}).encode("ascii"),
            "modules/%s/Scripts/config.lua" % name: (STANDIN_CONFIG % {"name": name}).encode("ascii"),
            "modules/%s/README.txt" % name: ("Stand-in for the module %s.\n" % name).encode("ascii")}


def with_modules(modules_lua, lines):
    """The text of a Scripts/core/modules.lua with entries added at the end of its list."""
    cut = modules_lua.rstrip().rfind(b"}")
    return modules_lua[:cut] + b"".join(l.encode("ascii") + b"\n" for l in lines) + modules_lua[cut:]


# ---------------------------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------------------------
def package_files(folder, name):
    """{path inside the mod: bytes} of a package."""
    with zipfile.ZipFile(os.path.join(folder, name)) as zf:
        return {i.filename.split("/", 1)[1]: zf.read(i) for i in zf.infolist() if not i.is_dir()}


def make_package(folder, name, files):
    """Writes a package (zip + manifest) with these files; returns (folder, name)."""
    os.makedirs(folder, exist_ok=True)
    top = "G1R_MegaMod"
    with zipfile.ZipFile(os.path.join(folder, name), "w", zipfile.ZIP_DEFLATED) as zf:
        for rel in sorted(files):
            zf.writestr(zipfile.ZipInfo(top + "/" + rel, date_time=(2026, 1, 1, 0, 0, 0)), files[rel], zipfile.ZIP_DEFLATED)
    with open(os.path.join(folder, name[:-4] + "-manifest.sha256"), "w", encoding="ascii", newline="\n") as f:
        for rel in sorted(files):
            f.write("%s  ./%s\n" % (sha_of(files[rel]), rel))
    return folder, name


def variant(source, label, drop=(), put=None, name=None, change=None):
    """A package made from another one: (folder, name). drop: path prefixes left out; put: {path: bytes} added or
    replaced; change: function(files) for anything else; name: another file name (another version)."""
    files = {rel: data for rel, data in package_files(*source).items() if not any(rel.startswith(d) for d in drop)}
    files.update(put or {})
    if change:
        change(files)
    return make_package(os.path.join(WORK, "pkg-" + label), name or source[1], files)


def build_new_package(table):
    """The new version's package: --new-pkg, or built with the mod's own builder from a temp copy of its source.
    Returns (folder, name)."""
    if ARGS.new_pkg:
        names = sorted(n for n in os.listdir(ARGS.new_pkg) if re.match(r"^G1R_MegaMod-.+\.zip$", n) and n != OLD_PACKAGE)
        dev = [n for n in names if n.endswith("-dev.zip")]
        if not names:
            raise SystemExit("no G1R_MegaMod-*.zip in %s" % ARGS.new_pkg)
        return ARGS.new_pkg, (dev or names)[-1]
    src = os.path.join(WORK, "src", "G1R_MegaMod")
    wipe(os.path.join(WORK, "src"))
    shutil.copytree(ARGS.mod_src, src, ignore=lambda folder, names: [n for n in names if n == "__pycache__"
                    or (n == "out" and os.path.basename(folder) == "dev")])
    out = os.path.join(WORK, "dist")
    wipe(out)

    def stand_in(names, why):
        for name in names:
            for rel in ("modules/" + name, "dev/tests/" + name):
                wipe(os.path.join(src, rel.replace("/", os.sep)))
            if os.path.isfile(os.path.join(src, "dev", "facts", name + ".md")):
                os.remove(os.path.join(src, "dev", "facts", name + ".md"))
            for rel, data in standin_files(name).items():
                write(os.path.join(src, rel.replace("/", os.sep)), data)
        if names:
            subprocess.run([LUA, os.path.join(src, "dev", "tools", "gen_config.lua")] + list(names), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            NOTES.append("stand-in modules in the package (%s): %s" % (why, ", ".join(names)))

    def build():
        p = subprocess.run([sys.executable, os.path.join(src, "dev", "tools", "build_release.py"), "--root", src, "--out", out, "--with-dev", "--json"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            return json.loads(p.stdout.decode("utf-8", "replace"))
        except ValueError:
            return {"built": False, "refused": [(p.stderr.decode("utf-8", "replace") or "the builder gave no result")[-400:]]}

    missing = [module for mod, _, module in table if not os.path.isfile(os.path.join(src, "modules", module, "Scripts", "main.lua"))]
    stand_in(missing, "the mod's source does not have them yet")
    modules_path = os.path.join(src, "Scripts", "core", "modules.lua")
    listed = re.findall(rb'name\s*=\s*"([^"]+)"', read(modules_path))
    lines = ['    { name = "%s", switch = "%s", separate = { "%s" } },' % (module, module.capitalize(), mod)
             for mod, _, module in table if module.encode("ascii") not in listed]
    if lines:
        write(modules_path, with_modules(read(modules_path), lines))
        NOTES.append("module list of the temp copy extended by: %s" % ", ".join(l.split('"')[1] for l in lines))
    result = build()
    if not result.get("built"):
        broken = sorted(set(module for _, _, module in table for line in result.get("refused", [])
                            if re.search(r"\b(modules|dev/tests)/%s/|dev/facts/%s\.md" % (module, module), line)))
        if broken:
            stand_in(broken, "the source's own do not build right now: " + "; ".join(result["refused"][:2])[:200])
            result = build()
    if not result.get("built"):
        raise SystemExit("the new package cannot be built from %s:\n  %s" % (ARGS.mod_src, "\n  ".join(result.get("refused", [])[:8])))
    return out, os.path.basename(result["zip"])


# ---------------------------------------------------------------------------------------------
# Worlds
# ---------------------------------------------------------------------------------------------
def attach():
    """The installer with its paths pointed into the mock below --sim."""
    sim = ARGS.sim
    inst = load_installer()
    inst.GAME = os.path.join(sim, "Game")
    inst.UE4SS = os.path.join(inst.GAME, "ue4ss")
    inst.MODS = os.path.join(inst.UE4SS, "Mods")
    inst.SAVES = os.path.join(sim, "Saves")
    inst.WS = os.path.join(sim, "Project")
    inst.PKGDIR = os.path.join(inst.WS, "megamod")
    inst.SHORTCUT = os.path.join(sim, "Desktop", "G1R_MegaMod Settings.lnk")
    inst.EXPECTED_UE4SS = hashlib.sha256(b"fake dll").hexdigest()
    inst.running_images = lambda: ["explorer.exe", "python.exe"]
    if not WINDOWS:
        inst.shortcut_read, inst.shortcut_write = fake_shortcut_read, fake_shortcut_write
    inst.PACKAGE = OLD_PACKAGE
    inst.MANIFEST = inst.manifest_name(inst.PACKAGE)
    return inst


def make_shortcut(inst, points_to):
    if WINDOWS:
        made = inst.shortcut_write(inst.SHORTCUT, points_to, os.path.dirname(points_to))
        if not made or not os.path.isfile(inst.SHORTCUT):
            raise SystemExit("the mock shortcut could not be created through Windows Script Host")
    else:
        fake_shortcut_write(inst.SHORTCUT, points_to, os.path.dirname(points_to))


def put_mod(mods, name):
    """A mod of another author into the mock: a copy of the real folder when there is one, else a stand-in."""
    real = os.path.join(ARGS.fixtures, name) if ARGS.fixtures else ""
    if name == "G1R_RegenMana":             # native; its dll is not in the snapshot
        ini = read(ARGS.regen_ini) if ARGS.regen_ini and os.path.isfile(ARGS.regen_ini) else REGEN_INI
        write(os.path.join(mods, name, "dlls", "main.dll"), b"MZ a native mod")
        write(os.path.join(mods, name, "G1R_RegenMana.ini"), ini)
    elif os.path.isdir(real):
        shutil.copytree(real, os.path.join(mods, name))
    else:
        for rel, data in FAKES[name].items():
            write(os.path.join(mods, name, rel.replace("/", os.sep)), data)


def build_world(shortcut="old", pkg=None, others=None):
    """A mock of the PC before the megamod was installed: returns the installer module with its paths set.
    shortcut: 'old' (points to the settings app in G1R_Repopulate), 'none', or a path it points to.
    pkg: (folder, name) of the package in the project folder (default: the 0.1.1 one from --pkg).
    others: the mods of other authors to put next to our two (default: two small stand-ins)."""
    sim = ARGS.sim
    wipe(sim)
    inst = attach()
    game, ue4ss, mods, saves, ws = inst.GAME, inst.UE4SS, inst.MODS, inst.SAVES, inst.WS
    desktop = os.path.join(sim, "Desktop")
    repop = os.path.join(mods, "G1R_Repopulate")
    shutil.copytree(ARGS.repop_src, repop)
    shutil.copytree(ARGS.markers_src, os.path.join(mods, "NPCMarkers"))
    if not ARGS.as_is:
        # as on the PC: enabled through mods.txt, the player's settings, progress, the settings app and its work file
        if os.path.exists(os.path.join(repop, "enabled.txt")):
            os.remove(os.path.join(repop, "enabled.txt"))
        write(os.path.join(repop, "Scripts", "config.lua"), b"-- the player's own settings\r\nlocal Config = {}\r\nConfig.Enabled = true\r\nreturn Config\r\n")
        write(os.path.join(repop, "Scripts", "state", "profile_0.lua"), b"return { seen = { A = true } }\n")
        write(os.path.join(repop, "Scripts", "config.lua.bak"), b"old\n")
        write(os.path.join(repop, SETTINGS_EXE), b"MZ settings app")
        os.makedirs(os.path.join(repop, "Scripts", "state", "empty"), exist_ok=True)       # an empty folder is kept too
        write(os.path.join(mods, "NPCMarkers", "enabled.txt"), b"")
    if others is None:
        write(os.path.join(mods, "SkillfulLocks", "Scripts", "main.lua"), b"-- another mod\n")
        write(os.path.join(mods, "SkillfulLocks", "enabled.txt"), b"")
        write(os.path.join(mods, "HUDMap", "Scripts", "main.lua"), b"-- another mod\n")
        write(os.path.join(mods, "HUDMap", "settings.ini"), b"x=1\n")
        write(os.path.join(mods, "mods.txt"), read(ARGS.mods_txt) if ARGS.mods_txt else MODS_TXT)
    else:
        for name in others:
            put_mod(mods, name)
        real = os.path.join(ARGS.fixtures, "mods.txt") if ARGS.fixtures else ""
        write(os.path.join(mods, "mods.txt"), read(ARGS.mods_txt) if ARGS.mods_txt else (read(real) if os.path.isfile(real) else PC_MODS_TXT))
    write(os.path.join(mods, "shared", "types.lua"), b"-- not a mod\n")
    write(os.path.join(mods, "mods.json"), read(ARGS.mods_json) if ARGS.mods_json else b'[\r\n  {\r\n    "mod_name": "G1R_Repopulate",\r\n    "mod_enabled": true\r\n  }\r\n]\r\n')
    write(os.path.join(ue4ss, "UE4SS.dll"), b"fake dll")
    for i in range(3):
        write(os.path.join(saves, "Save%d.sav" % i), os.urandom(64))
    os.makedirs(os.path.join(ws, "megamod"))
    os.makedirs(desktop)
    folder, name = pkg or (ARGS.pkg, OLD_PACKAGE)
    inst.PACKAGE, inst.MANIFEST = name, inst.manifest_name(name)
    for n in (inst.PACKAGE, inst.MANIFEST):
        shutil.copy2(os.path.join(folder, n), os.path.join(ws, "megamod", n))
    if shortcut != "none":
        make_shortcut(inst, os.path.join(repop, SETTINGS_EXE) if shortcut == "old" else shortcut)
    return inst


MORNING = "megamod-install-backup-20001002-070457"          # the backup folder of the first install, with a stamp that sorts first
LEGACY_REPORT_KEYS = ("stamp", "mode", "target", "package", "plan", "copies", "notes", "retire", "retired", "shortcut", "ok", "problems", "status")
OBSOLETE = {"dev/old_note.md": b"a file only the old version had\n", "modules/markers/Scripts/old_helper.lua": b"-- only in the old version\n",
            "oldfolder/only/file.txt": b"its folder goes with it\n", "modules/gone/Scripts/main.lua": b"-- a module only the old version had\n"}
OLD_PLAYERS = {"modules/gone/Scripts/config.lua": b"-- settings of a module only the old version had: the player's own once installed\nreturn {}\n"}
_templates = {}


def build_pc_world(new=None, old=None, real=False, tweak=None):
    """The PC as it is now: G1R_MegaMod 0.1.1 installed as on the morning of 2026-10-02 (our two own mods retired
    into that run's backup folder, the shortcut pointing into the megamod, files of a game session), the six mods
    of other authors and others that stay, mods.txt still naming our two. The new package lies next to the old one
    in the project folder, and the installer's PACKAGE names it.
    new / old: (folder, name) of the packages; real: build it from --pc-mods / --pc-backup instead (rehearsal);
    tweak: function(installer) for what a case needs different."""
    new, old = new or NEW, old or ((ARGS.pkg, OLD_PACKAGE) if real else OLDX)
    sim = ARGS.sim
    key = (old, real)
    if key in _templates:
        wipe(sim)
        shutil.copytree(_templates[key], sim)
        inst = attach()
    elif real:
        wipe(sim)
        inst = attach()
        shutil.copytree(ARGS.pc_mods, inst.MODS)
        write(os.path.join(inst.UE4SS, "UE4SS.dll"), b"fake dll")
        for i in range(3):
            write(os.path.join(inst.SAVES, "Save%d.sav" % i), os.urandom(64))
        os.makedirs(inst.PKGDIR)
        os.makedirs(os.path.dirname(inst.SHORTCUT))
        for n in (old[1], inst.manifest_name(old[1])):
            if os.path.isfile(os.path.join(old[0], n)):
                shutil.copy2(os.path.join(old[0], n), os.path.join(inst.PKGDIR, n))
        if ARGS.pc_backup:
            shutil.copytree(ARGS.pc_backup, os.path.join(inst.WS, os.path.basename(ARGS.pc_backup.rstrip("/\\"))))
        exe = os.path.join(inst.MODS, inst.NAME, "modules", "repopulate", SETTINGS_EXE)
        if os.path.isfile(exe):
            make_shortcut(inst, exe)
    else:
        third = [e[0] for e in load_installer().TAKEOVERS if e[0] not in OWN]
        inst = build_world(pkg=old, others=third + list(STAYING))
        code, out = run(inst)                       # the first install, this morning
        made = backups(inst)
        if code != 0 or len(made) != 1:
            raise SystemExit("the mock of this morning's install failed:\n" + out)
        morning = os.path.join(inst.WS, MORNING)
        os.rename(os.path.join(inst.WS, made[0]), morning)
        # ... whose report and baseline did not have what the installer writes today
        report = json.loads(read(os.path.join(morning, "install-report.json")).decode("utf-8"))
        report = {k: report[k] for k in LEGACY_REPORT_KEYS}
        report["plan"] = {k: v for k, v in report["plan"].items() if k != "remove"}
        write(os.path.join(morning, "install-report.json"), json.dumps(report, indent=1))
        baseline = json.loads(read(os.path.join(morning, "baseline-hashes.json")).decode("utf-8"))
        baseline.pop("shortcut", None)
        write(os.path.join(morning, "baseline-hashes.json"), json.dumps(baseline, indent=1, sort_keys=True))
        # a game session, and something the player put there
        target = os.path.join(inst.MODS, inst.NAME)
        write(os.path.join(target, "Scripts", "diagnostics", "session-20261002-080000.log"), b"08:00:00 [loader] v0.1.1 loaded\n")
        write(os.path.join(target, "Scripts", "diagnostics", "report-latest.txt"), b"a report\n")
        write(os.path.join(target, "modules", "markers", "Scripts", "my-notes.txt"), b"The player's own notes\n")
    if key not in _templates:
        _templates[key] = os.path.join(WORK, "world-%d" % len(_templates))
        wipe(_templates[key])
        shutil.copytree(sim, _templates[key])
    inst.PACKAGE, inst.MANIFEST = new[1], inst.manifest_name(new[1])
    for n in (inst.PACKAGE, inst.MANIFEST):
        shutil.copy2(os.path.join(new[0], n), os.path.join(inst.PKGDIR, n))
    if tweak:
        tweak(inst)
    return inst


def run(inst, *args):
    buf = io.StringIO()
    code = None
    with contextlib.redirect_stdout(buf):
        try:
            code = inst.main(list(args))
        except SystemExit as e:
            code = e.code
    return code, buf.getvalue()


def backups(inst):
    return sorted(d for d in os.listdir(inst.WS) if d.startswith("megamod-install-backup-"))


def last_backup(inst):
    return os.path.join(inst.WS, backups(inst)[-1])


def last_line(out):
    lines = out.strip().splitlines()
    return lines[-1][:140] if lines else ""


@contextlib.contextmanager
def patched(obj, name, value):
    old = getattr(obj, name)
    setattr(obj, name, value)
    try:
        yield
    finally:
        setattr(obj, name, old)


LOAD_SCRIPT = r"""
local mock = dofile(arg[1] .. "/dev/tests/mock/ue4ss.lua")
local ue = mock.new()
ue:install()
ue.functions["/Script/Engine.PlayerController:ClientRestart"] = true
local ok, err = pcall(dofile, arg[1] .. "/Scripts/main.lua")
for _ = 1, 8 do ue:advance(0.25) ue:tick() end
ue:uninstall()
local line = ue.printed[#ue.printed] or "?"
for _, text in ipairs(ue.printed) do
    if tostring(text):find("%] v[%d%.]+ loaded: ") then line = text end        -- the loader's line (modules may print after it)
end
io.write(line)
io.write("errors: ", #ue.errors, " ok: ", tostring(ok), " ", tostring(err), "\n")
-- what the modules say for themselves: their own load lines, and anything about a config.lua
for _, text in ipairs(ue.printed) do
    text = tostring(text)
    if text:find(" loaded: ", 1, true) or text:find("config.lua", 1, true) or text:find("is not usable", 1, true) then
        io.write("printed: ", text, text:sub(-1) == "\n" and "" or "\n")
    end
end
"""
LUA = shutil.which("lua5.4") or shutil.which("lua")


def start_mod(target):
    """Starts the installed mod in the mock UE4SS; returns its load line plus an error count, or None without Lua."""
    if not LUA:
        return None
    script = os.path.join(ARGS.sim, "load.lua")
    write(script, LOAD_SCRIPT)
    p = subprocess.run([LUA, script, target], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    os.remove(script)
    return p.stdout.decode("utf-8", "replace")


def find_shells():
    """[(label, [exe], env)] of every PowerShell that answers."""
    found = []
    candidates = []
    if WINDOWS:
        candidates = [("Windows PowerShell", shutil.which("powershell")), ("PowerShell 7", shutil.which("pwsh"))]
    else:
        pw = os.environ.get("SIM_PWSH") or shutil.which("pwsh")
        if not pw and os.path.isfile("/tmp/sim13/_pwsh/tool/pwsh"):
            pw = "/tmp/sim13/_pwsh/tool/pwsh"
        candidates = [("pwsh on Linux", pw)]
    env = dict(os.environ)
    if not WINDOWS:
        if os.path.isfile("<cloud home>/dotnet/dotnet"):            # a private .NET runtime for pwsh in the sandbox
            env["PATH"] = "<cloud home>/dotnet" + os.pathsep + env.get("PATH", "")
            env["DOTNET_ROOT"] = "<cloud home>/dotnet"
        home = os.path.join(os.path.dirname(ARGS.sim.rstrip("/\\")), "_sim_megamod_home")
        os.makedirs(home, exist_ok=True)
        env.update({"HOME": home, "DOTNET_CLI_HOME": home, "DOTNET_CLI_TELEMETRY_OPTOUT": "1", "POWERSHELL_TELEMETRY_OPTOUT": "1",
                    "POWERSHELL_UPDATECHECK": "Off", "NO_COLOR": "1"})
    for label, exe in candidates:
        if not exe:
            continue
        probe = subprocess.run([exe, "-NoProfile", "-NonInteractive", "-Command", "$PSVersionTable.PSVersion.ToString()"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        if probe.returncode == 0:
            found.append(("%s %s" % (label, probe.stdout.decode("ascii", "replace").strip()), exe, env))
    return found


def rollback(shell, inst, script, *more):
    label, exe, env = shell
    p = subprocess.run([exe, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script,
                        "-ModsRoot", inst.MODS, "-Shortcut", inst.SHORTCUT] + list(more), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    return p.returncode, p.stdout.decode("utf-8", "replace")


class _FakeSubprocess:
    """Stand-in for the two programs the audit calls (tasklist, PowerShell for the shortcut) where there is no Windows."""
    PIPE = subprocess.PIPE

    @staticmethod
    def run(cmd, **kw):
        class R:
            returncode, stdout, stderr = 0, b"", b""
        if cmd[0] == "tasklist":
            R.stdout = b'"explorer.exe","4321","Console","1","80,000 K"\r\n"python.exe","77","Console","1","9,000 K"\r\n'
        else:
            info = fake_shortcut_read(kw["env"]["G1R_LNK"])
            if info is None:
                R.returncode = 1
            else:
                R.stdout = (info["target"] + "\n" + info["workdir"]).encode("utf-8")
        return R


def load_audit(inst, table=None):
    """The audit with its paths pointed into the mock. table: a take-over table to use instead of the installer file's."""
    spec = importlib.util.spec_from_file_location("audit_megamod", os.path.join(HERE, "audit_megamod.py"))
    aud = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(aud)
    aud.GAME, aud.UE4SS, aud.MODS, aud.SAVES, aud.WS, aud.PKGDIR, aud.SHORTCUT = inst.GAME, inst.UE4SS, inst.MODS, inst.SAVES, inst.WS, inst.PKGDIR, inst.SHORTCUT
    aud.EXPECTED_UE4SS = inst.EXPECTED_UE4SS
    # the audit knows the PC's patched SkillfulLocks by the start of its hash; here it is the mock's file (in Mods, or retired)
    for locks in [os.path.join(inst.MODS, "SkillfulLocks", "Scripts", "main.lua")] + \
            [os.path.join(inst.WS, b, "retired", "SkillfulLocks", "Scripts", "main.lua") for b in reversed(backups(inst))]:
        if os.path.isfile(locks):
            aud.SKILLFULLOCKS_MAIN = hashlib.sha256(read(locks)).hexdigest()[:8]
            break
    aud.TAKEOVERS = table
    if not WINDOWS:
        aud.subprocess = _FakeSubprocess
    return aud


def run_audit(aud, *argv):
    aud.oks, aud.fails = 0, 0
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = aud.main(list(argv))
    return code, buf.getvalue()


def make_rejects(inst, aud):
    """A function that changes one file (data None = removes it), runs the audit, puts the file back, and checks
    that the audit failed with a line that contains `expect`."""
    def rejects(text, path, data, expect, *argv):
        had = read(path) if os.path.isfile(path) else None
        if data is None:
            os.remove(path)
        elif data is not False:
            write(path, data)
        acode, aout = run_audit(aud, *argv)
        if had is None and data is not False:
            os.remove(path)
            d = os.path.dirname(path)
            while d != inst.MODS and os.path.isdir(d) and not os.listdir(d):
                os.rmdir(d)
                d = os.path.dirname(d)
        elif data is not False:
            write(path, had)
        failed = [l for l in aout.splitlines() if l.startswith("FAIL")]
        check(acode == 1 and "AUDIT FAILED" in aout and any(expect in l for l in failed), "the audit does not accept %s (%d check(s) fail)" % (text, len(failed)))
    return rejects


# ---------------------------------------------------------------------------------------------
# Part "first": the first install of 0.1.1 over our two own mods (the checks of the morning of 2026-10-02)
# ---------------------------------------------------------------------------------------------
def part_first(shells):
    sim = ARGS.sim

    # ================= dry run
    inst = build_world()
    target = os.path.join(inst.MODS, inst.NAME)
    new_exe = os.path.join(target, "modules", "repopulate", SETTINGS_EXE)
    old_exe = os.path.join(inst.MODS, "G1R_Repopulate", SETTINGS_EXE)
    has_exe = os.path.isfile(old_exe)
    profiles = sorted(n for n in os.listdir(os.path.join(inst.MODS, "G1R_Repopulate", "Scripts", "state")) if n.startswith("profile_") and n.endswith(".lua")) \
        if os.path.isdir(os.path.join(inst.MODS, "G1R_Repopulate", "Scripts", "state")) else []
    markers_23 = b"NPCMarkers 2.3 configuration" in read(os.path.join(inst.MODS, "NPCMarkers", "Scripts", "config.lua"))[:4096]
    before = tree(sim)
    code, out = run(inst, "--check")
    check(code == 0 and "first install" in out and "CHECK ONLY" in out and tree(sim) == before, "--check: prints the plan, creates and changes nothing")
    check("copy: Mods\\G1R_Repopulate\\Scripts\\config.lua" in out and all(p in out for p in profiles) and (not has_exe or ("copy: Mods\\G1R_Repopulate\\" + SETTINGS_EXE) in out)
          and (not markers_23 or "copy: Mods\\NPCMarkers\\Scripts\\config.lua" in out), "the plan lists the settings, the progress file(s) and the settings app to be copied")
    check("retire: Mods\\G1R_Repopulate (" in out and "retire: Mods\\NPCMarkers (" in out and out.count(", enabled) -> backup folder") == 2,
          "the plan lists both separate mods as to be retired, and that both are enabled")
    check((not has_exe) or ("shortcut: G1R_MegaMod Settings.lnk -> " + new_exe) in out, "and where the desktop shortcut will point")

    # ================= first install, taking over
    mods_before = tree(inst.MODS)
    saves_before = tree(inst.SAVES)
    lnk_before = read(inst.SHORTCUT)
    code, out = run(inst)
    manifest = inst.read_manifest(os.path.join(inst.PKGDIR, inst.MANIFEST))
    after = tree(inst.MODS)
    ours = {k.replace(os.sep, "/"): v for k, v in under(after, inst.NAME).items() if v != "dir"}
    check(code == 0 and "DONE:" in out, "first install: done (%s)" % last_line(out))
    copied = {"modules/repopulate/Scripts/config.lua": os.path.join("G1R_Repopulate", "Scripts", "config.lua")}
    for p in profiles:
        copied["modules/repopulate/Scripts/state/" + p] = os.path.join("G1R_Repopulate", "Scripts", "state", p)
    if has_exe:
        copied["modules/repopulate/" + SETTINGS_EXE] = os.path.join("G1R_Repopulate", SETTINGS_EXE)
    if markers_23:
        copied["modules/markers/Scripts/config.lua"] = os.path.join("NPCMarkers", "Scripts", "config.lua")
    wrong = [r for r in manifest if r not in copied and ours.get(r) != manifest[r]]
    extra = sorted(set(ours) - set(manifest))
    check(not wrong and extra == sorted(set(copied) - set(manifest)),
          "every package file is in place with the manifest's hash (%d files; %d wrong), plus the progress file(s) and the settings app (%d)" % (len(manifest), len(wrong), len(extra)))
    check(all(ours.get(dst) == mods_before[src] for dst, src in copied.items()) and "modules/repopulate/Scripts/config.lua.bak" not in ours,
          "settings, progress and the settings app are copies of the separate mods' files (work files are not taken)")
    check(not os.path.exists(os.path.join(inst.MODS, "G1R_Repopulate")) and not os.path.exists(os.path.join(inst.MODS, "NPCMarkers"))
          and not [k for k in after if ".retired-" in k], "both separate mod folders are gone from Mods, nothing is left behind")
    check(without(after, inst.NAME) == without(mods_before, "G1R_Repopulate", "NPCMarkers") and tree(inst.SAVES) == saves_before,
          "nothing else changed: the other mods, mods.txt, mods.json, the saves")
    b = backups(inst)
    bdir = os.path.join(inst.WS, b[-1]) if b else ""
    check(len(b) == 1 and sorted(os.listdir(bdir)) == sorted(["ROLLBACK-megamod-install.ps1", "baseline-hashes.json", "install-report.json", "retired", "shortcut"]),
          "backup folder with baseline hashes, report, rollback script, the retired mods and the shortcut")
    kept = tree(os.path.join(bdir, "retired"))
    check(under(kept, "G1R_Repopulate") == under(mods_before, "G1R_Repopulate") and under(kept, "NPCMarkers") == under(mods_before, "NPCMarkers")
          and sorted(os.listdir(os.path.join(bdir, "retired"))) == ["G1R_Repopulate", "NPCMarkers"],
          "the copies in the backup folder are identical to the retired folders: every file, every folder (%d + %d entries)"
          % (len(under(kept, "G1R_Repopulate")), len(under(kept, "NPCMarkers"))))
    check(read(os.path.join(bdir, "shortcut", "G1R_MegaMod Settings.lnk")) == lnk_before, "the shortcut as it was is in the backup folder")
    report = read_json(os.path.join(bdir, "install-report.json"))
    files_of = lambda t, name: sum(1 for v in under(t, name).values() if v != "dir")
    check(report["ok"] is True and report["mode"] == "install" and report["problems"] == [] and len(report["plan"]["add"]) == len(manifest)
          and report["retire"] == ["G1R_Repopulate", "NPCMarkers"] and report["retired"]["G1R_Repopulate"]["files"] == files_of(mods_before, "G1R_Repopulate")
          and report["retired"]["NPCMarkers"]["files"] == files_of(mods_before, "NPCMarkers"), "report: ok, mode install, both mods retired with their file counts")
    now = inst.shortcut_read(inst.SHORTCUT)
    check(now is not None and inst.same_path(now["target"], new_exe) and inst.same_path(now["workdir"], os.path.dirname(new_exe))
          and "shortcut: G1R_MegaMod Settings.lnk now starts " in out, "the desktop shortcut starts the settings app inside G1R_MegaMod, from its folder")
    rb = read(os.path.join(bdir, "ROLLBACK-megamod-install.ps1"))
    check(all(c < 128 for c in rb) and b"\r\n" in rb and b"\n" not in rb.replace(b"\r\n", b""), "the rollback script is plain ASCII with CRLF line ends (Windows PowerShell reads it as it is)")

    # ---- the installed mod starts and does both jobs
    line = start_mod(target)
    if line is not None:
        check("loaded: repopulate ok, markers ok | diagnostics normal" in line and "errors: 0 ok: true" in line,
              "started in a mock UE4SS: both modules load although mods.txt still names the retired mods (%s)" % line.strip().splitlines()[0][:150])
        diag = os.path.join(target, "Scripts", "diagnostics")
        check(any(n.startswith("session-") for n in os.listdir(diag)) and os.path.isfile(os.path.join(diag, "report-latest.txt")), "and the diagnostics files appear in its folder")

    # ---- a second run: an update with nothing new; the player's files stay, nothing to retire
    write(os.path.join(target, "Scripts", "config.lua"), b"local Config = {}\nConfig.Modules = { Repopulate = true, Markers = false }\nreturn Config\n")
    os.remove(os.path.join(target, "enabled.txt"))                                   # as a mod manager does
    write(os.path.join(target, "modules", "repopulate", "Scripts", "util.lua"), b"-- damaged\n")
    write(os.path.join(target, "modules", "repopulate", "Scripts", "config.lua"), b"-- changed with the settings app\r\nreturn {}\r\n")
    state_before = tree(target)
    lnk_now = read(inst.SHORTCUT)
    code, out = run(inst)
    state_after = tree(target)
    changed = sorted(k for k in set(state_before) | set(state_after) if state_before.get(k) != state_after.get(k))
    check(code == 0 and "update of the installed mod" in out and "1 replaced" in out and changed == [os.path.join("modules", "repopulate", "Scripts", "util.lua")]
          and "retire:" not in out and "shortcut:" not in out and read(inst.SHORTCUT) == lnk_now,
          "update: only the file that differed from the package is replaced; nothing to retire, the shortcut stays (%s)" % changed)
    check(not os.path.exists(os.path.join(target, "enabled.txt")) and b"Markers = false" in read(os.path.join(target, "Scripts", "config.lua"))
          and b"changed with the settings app" in read(os.path.join(target, "modules", "repopulate", "Scripts", "config.lua"))
          and "kept: enabled.txt" in out, "settings files, progress, diagnostics stay; a removed enabled.txt is not put back")
    b = backups(inst)
    check(len(b) == 2 and read(os.path.join(inst.WS, b[-1], "replaced", "modules", "repopulate", "Scripts", "util.lua")) == b"-- damaged\n"
          and not os.path.exists(os.path.join(inst.WS, b[-1], "retired")), "the replaced file is in the backup folder of that run")

    # ================= the independent audit (audit_megamod.py) on a fresh take-over, and on states it must not accept
    if os.path.isfile(os.path.join(HERE, "audit_megamod.py")):
        inst = build_world()
        target = os.path.join(inst.MODS, inst.NAME)
        code, out = run(inst)
        bdir = os.path.join(inst.WS, backups(inst)[-1])
        aud = load_audit(inst)
        acode, aout = run_audit(aud)
        n_checks = aout.count("\nok   ") + (1 if aout.startswith("ok   ") else 0)
        check(code == 0 and acode == 0 and "AUDIT OK (" in aout and "FAIL" not in aout and n_checks >= 18,
              "audit after the install: %s" % last_line(aout))

        def rejects(text, path, data, expect):
            """Changes one file (data None = remove it), runs the audit, puts the file back."""
            had = read(path) if os.path.isfile(path) else None
            if data is None:
                os.remove(path)
            else:
                write(path, data)
            acode, aout = run_audit(aud)
            if had is None:
                os.remove(path)
                d = os.path.dirname(path)
                while d != inst.MODS and os.path.isdir(d) and not os.listdir(d):
                    os.rmdir(d)
                    d = os.path.dirname(d)
            else:
                write(path, had)
            failed = [l for l in aout.splitlines() if l.startswith("FAIL")]
            check(acode == 1 and "AUDIT FAILED" in aout and any(expect in l for l in failed), "the audit does not accept %s (%d check(s) fail)" % (text, len(failed)))

        rejects("a changed file of another mod", os.path.join(inst.MODS, "HUDMap", "settings.ini"), b"x=2\n", "every other file in Mods is as before")
        rejects("a changed mods.txt", os.path.join(inst.MODS, "mods.txt"), b"HUDMap : 0\r\n", "mods.txt and mods.json are unchanged")
        rejects("an enabled.txt that appeared in another mod", os.path.join(inst.MODS, "HUDMap", "enabled.txt"), b"", "have enabled.txt as before")
        rejects("a changed file of the mod", os.path.join(target, "Scripts", "core", "sandbox.lua"), b"-- other\n", "every file of the package is in")
        rejects("a missing file of the mod", os.path.join(target, "modules", "markers", "Scripts", "npcs.lua"), None, "every file of the package is in")
        rejects("an unknown file in the mod folder", os.path.join(target, "modules", "stray.lua"), b"--\n", "besides the package only")
        rejects("a module settings file that is not the separate mod's", os.path.join(target, "modules", "repopulate", "Scripts", "config.lua"), b"return {}\n", "module settings files are the ones")
        rejects("a changed save", os.path.join(inst.SAVES, "Save0.sav"), b"other", "the save folder is unchanged")
        rejects("a new save", os.path.join(inst.SAVES, "Save9.sav"), b"new", "the save folder is unchanged")
        rejects("another UE4SS.dll", os.path.join(inst.UE4SS, "UE4SS.dll"), b"another build", "UE4SS.dll is the AngelScript Fix 0.4 build")
        rejects("a separate mod that is back in Mods", os.path.join(inst.MODS, "NPCMarkers", "Scripts", "main.lua"), b"--\n", "NPCMarkers (-> module markers)")
        rejects("an incomplete copy of a retired mod", os.path.join(bdir, "retired", "NPCMarkers", "Scripts", "npcs.lua"), None, "the copy of NPCMarkers in the backup folder")
        rejects("a changed copy of a retired mod", os.path.join(bdir, "retired", "G1R_Repopulate", "Scripts", "main.lua"), b"--\n", "the copy of G1R_Repopulate in the backup folder")
        rejects("a missing rollback script", os.path.join(bdir, "ROLLBACK-megamod-install.ps1"), None, "the rollback script is in the backup folder")
        rejects("a missing enabled.txt of the mod", os.path.join(target, "enabled.txt"), None, "enabled.txt is in the folder")
        rejects("another package in the project folder", os.path.join(inst.PKGDIR, inst.PACKAGE), read(os.path.join(inst.PKGDIR, inst.PACKAGE)) + b"x", "the package in the project folder")
        lnk_now = read(inst.SHORTCUT)
        inst.shortcut_write(inst.SHORTCUT, os.path.join(inst.MODS, "HUDMap", "x.exe"), os.path.join(inst.MODS, "HUDMap"))
        acode, aout = run_audit(aud)
        write(inst.SHORTCUT, lnk_now)
        check(acode == 1 and "FAIL the desktop shortcut starts the settings app" in aout, "the audit does not accept a shortcut that points somewhere else")
        report_path = os.path.join(bdir, "install-report.json")
        rep = json.loads(read(report_path).decode("utf-8"))
        rep["ok"], rep["problems"] = False, ["something"]
        rejects("an installer report with a problem", report_path, json.dumps(rep).encode("utf-8"), "the installer's report")
        acode, aout = run_audit(aud)
        check(acode == 0 and "AUDIT OK (" in aout, "and with everything put back it passes again: %s" % last_line(aout))

    # ================= the rollback script, with every PowerShell
    for shell in shells:
        inst = build_world()
        target = os.path.join(inst.MODS, inst.NAME)
        world_before = tree(inst.MODS)
        lnk_before = read(inst.SHORTCUT)
        code, out = run(inst)
        bdir = os.path.join(inst.WS, backups(inst)[-1])
        script = os.path.join(bdir, "ROLLBACK-megamod-install.ps1")
        write(os.path.join(target, "Scripts", "diagnostics", "session-20261003-200000.log"), b"a session\n")     # what a game session leaves
        installed = tree(target)
        rc, text = rollback(shell, inst, script)
        removed = os.path.join(bdir, "removed-" + inst.NAME)
        check(code == 0 and rc == 0 and tree(inst.MODS) == world_before and read(inst.SHORTCUT) == lnk_before and "Rollback finished." in text,
              "[%s] rollback: the Mods folder is exactly as before the install (both mods back, G1R_MegaMod gone), the shortcut too (%s)" % (shell[0], text.strip().splitlines()[-1][:60] if text.strip() else rc))
        check(os.path.isdir(removed) and tree(removed) == installed, "[%s] and a copy of the removed G1R_MegaMod, with what a session wrote, is kept in the backup folder" % shell[0])
        rc, text = rollback(shell, inst, script)
        check(rc == 0 and text.count("already; left as it is.") == 2 and "nothing to remove" in text and tree(inst.MODS) == world_before,
              "[%s] run again: nothing to do, nothing changed" % shell[0])
        # the list file lost the line of a mod that has no enabled.txt (a mod manager may rewrite it)
        shutil.rmtree(os.path.join(inst.MODS, "G1R_Repopulate"))
        shutil.rmtree(os.path.join(inst.MODS, "NPCMarkers"))
        write(os.path.join(inst.MODS, "mods.txt"), b"SkillfulLocks : 1\r\nHUDMap : 1\r\n     \r\n:\r\n")
        rc, text = rollback(shell, inst, script)
        repop_flag = os.path.exists(os.path.join(inst.MODS, "G1R_Repopulate", "enabled.txt"))
        check(rc == 0 and under(tree(inst.MODS), "G1R_Repopulate") == under(world_before, "G1R_Repopulate")
              and (repop_flag or "NOTE: G1R_Repopulate has no enabled.txt and mods.txt has no line" in text) and "NOTE: NPCMarkers" not in text,
              "[%s] a restored mod that neither enabled.txt nor mods.txt switches on is named (the one with enabled.txt is not)" % shell[0])
        # a folder of that name that is not this mod
        write(os.path.join(target, "Scripts", "core", "version.lua"), b'return { name = "SomethingElse" }\n')
        rc, text = rollback(shell, inst, script)
        check(rc != 0 and os.path.isdir(target) and "is not the mod" in text, "[%s] a folder of that name that is not this mod is not removed" % shell[0])

    # ================= next to the separate mods (--keep-separate), then taking over later
    inst = build_world()
    target = os.path.join(inst.MODS, inst.NAME)
    mods_before = tree(inst.MODS)
    lnk_before = read(inst.SHORTCUT)
    code, out = run(inst, "--keep-separate")
    check(code == 0 and "DONE:" in out and without(tree(inst.MODS), inst.NAME) == mods_before and read(inst.SHORTCUT) == lnk_before
          and "left in place" in out and "retire:" not in out and not os.path.exists(os.path.join(inst.WS, backups(inst)[-1], "retired")),
          "--keep-separate: only Mods\\G1R_MegaMod is written; the separate mods and the shortcut stay, and that is said")
    line = start_mod(target)
    if line is not None:
        check("loaded: repopulate left to the separate mod G1R_Repopulate, markers left to the separate mod NPCMarkers" in line and "errors: 0 ok: true" in line,
              "started next to the enabled separate mods: both jobs are left to them (%s)" % line.strip().splitlines()[0][:150])
    write(os.path.join(inst.MODS, "G1R_Repopulate", "Scripts", "config.lua"), b"-- changed later\r\nreturn {}\r\n")
    code, out = run(inst, "--sync-settings")
    check(code == 0 and read(os.path.join(target, "modules", "repopulate", "Scripts", "config.lua")) == b"-- changed later\r\nreturn {}\r\n"
          and os.path.isdir(os.path.join(inst.MODS, "G1R_Repopulate")) and "retire:" not in out, "--sync-settings: the separate mod's settings are copied again, nothing is retired")
    b = backups(inst)
    check(len(b) == 2 and os.path.isfile(os.path.join(inst.WS, b[-1], "replaced", "modules", "repopulate", "Scripts", "config.lua")), "and the overwritten settings are in the backup folder")
    # the separate mods are still the ones in use: their newest settings come along when they are retired
    write(os.path.join(inst.MODS, "G1R_Repopulate", "Scripts", "config.lua"), b"-- changed once more\r\nreturn {}\r\n")
    write(os.path.join(target, "modules", "markers", "Scripts", "config.lua"), b"-- stale copy in the megamod\n")
    mods_mid = tree(inst.MODS)
    code, out = run(inst)
    after = tree(inst.MODS)
    check(code == 0 and "update of the installed mod" in out and "DONE:" in out and not os.path.exists(os.path.join(inst.MODS, "G1R_Repopulate"))
          and not os.path.exists(os.path.join(inst.MODS, "NPCMarkers")) and without(after, inst.NAME) == without(mods_mid, inst.NAME, "G1R_Repopulate", "NPCMarkers"),
          "a later run without the option takes over: both separate mods are retired, nothing else changes (%s)" % last_line(out))
    check(read(os.path.join(target, "modules", "repopulate", "Scripts", "config.lua")) == b"-- changed once more\r\nreturn {}\r\n"
          and (not markers_23 or read(os.path.join(target, "modules", "markers", "Scripts", "config.lua")) == read(os.path.join(inst.WS, backups(inst)[-1], "retired", "NPCMarkers", "Scripts", "config.lua"))),
          "the settings of the separate mods, which were the ones in use, are taken along")
    bdir = os.path.join(inst.WS, backups(inst)[-1])
    check((not markers_23 or read(os.path.join(bdir, "replaced", "modules", "markers", "Scripts", "config.lua")) == b"-- stale copy in the megamod\n")
          and os.path.isfile(os.path.join(bdir, "replaced", "modules", "repopulate", "Scripts", "config.lua")), "what they replaced in the megamod is in the backup folder")
    now = inst.shortcut_read(inst.SHORTCUT)
    check((not has_exe) or (now is not None and inst.same_path(now["target"], os.path.join(target, "modules", "repopulate", SETTINGS_EXE))), "and the shortcut follows")
    for shell in shells[:1]:
        rc, text = rollback(shell, inst, os.path.join(bdir, "ROLLBACK-megamod-install.ps1"))
        back = tree(inst.MODS)
        check(rc == 0 and without(back, inst.NAME) == without(mods_mid, inst.NAME) and "replaced file(s) put back" in text
              and read(os.path.join(target, "modules", "markers", "Scripts", "config.lua")) == (b"-- stale copy in the megamod\n" if markers_23 else read(os.path.join(target, "modules", "markers", "Scripts", "config.lua")))
              and read(inst.SHORTCUT) == lnk_before,
              "[%s] rollback of that run: both mods back, the megamod's own files as before the run, the shortcut too" % shell[0])

    # ---- a separate mod that is switched off: its settings are not the ones in use
    inst = build_world()
    target = os.path.join(inst.MODS, inst.NAME)
    run(inst, "--keep-separate")
    flag = os.path.join(inst.MODS, "NPCMarkers", "enabled.txt")
    if os.path.exists(flag):
        os.remove(flag)
    write(os.path.join(inst.MODS, "mods.txt"), read(os.path.join(inst.MODS, "mods.txt")).replace(b"NPCMarkers : 1", b"NPCMarkers : 0"))
    write(os.path.join(target, "modules", "markers", "Scripts", "config.lua"), b"-- the megamod's own, in use\n")
    code, out = run(inst)
    check(code == 0 and "NPCMarkers is disabled: its settings are not copied" in out and ", disabled) -> backup folder" in out
          and read(os.path.join(target, "modules", "markers", "Scripts", "config.lua")) == b"-- the megamod's own, in use\n"
          and not os.path.exists(os.path.join(inst.MODS, "NPCMarkers")),
          "a separate mod that is switched off is retired too, but its settings do not replace the module's own (said in the plan)")

    # ================= things that go wrong
    # the mod itself cannot be written completely: nothing is retired
    inst = build_world()
    target = os.path.join(inst.MODS, inst.NAME)
    mods_before = tree(inst.MODS)
    lnk_before = read(inst.SHORTCUT)
    real_write = inst.write_file

    def broken_write(dst, data):
        if dst.endswith(os.path.join("core", "sandbox.lua")):
            raise OSError("disk full (test)")
        return real_write(dst, data)
    inst.write_file = broken_write
    code, out = run(inst)
    check(code == 1 and "writing failed" in out and "were NOT retired" in out and under(tree(inst.MODS), "G1R_Repopulate") == under(mods_before, "G1R_Repopulate")
          and under(tree(inst.MODS), "NPCMarkers") == under(mods_before, "NPCMarkers") and read(inst.SHORTCUT) == lnk_before,
          "the mod could not be written completely: reported, the separate mods and the shortcut are not touched")

    # a file of a separate mod is open in another program: that mod stays, whole
    inst = build_world()
    target = os.path.join(inst.MODS, inst.NAME)
    mods_before = tree(inst.MODS)
    lnk_before = read(inst.SHORTCUT)
    real_rename = os.rename

    def busy_rename(a, b):
        if os.path.basename(a) == "G1R_Repopulate":
            raise PermissionError(13, "The process cannot access the file because it is being used by another process (test)", a)
        return real_rename(a, b)
    with patched(os, "rename", busy_rename):
        code, out = run(inst)
    after = tree(inst.MODS)
    check(code == 1 and "G1R_Repopulate is in use" in out and under(after, "G1R_Repopulate") == under(mods_before, "G1R_Repopulate")
          and not os.path.exists(os.path.join(inst.MODS, "NPCMarkers")) and read(inst.SHORTCUT) == lnk_before and not [k for k in after if ".retired-" in k],
          "a separate mod that is in use stays in place, complete; the other one is retired; the shortcut is left (%s)" % last_line(out))
    line = start_mod(target)
    if line is not None:
        check("loaded: repopulate left to the separate mod G1R_Repopulate, markers ok" in line and "errors: 0 ok: true" in line,
              "in that state every job is done exactly once (%s)" % line.strip().splitlines()[0][:150])
    for shell in shells[:1]:
        rc, text = rollback(shell, inst, os.path.join(inst.WS, backups(inst)[-1], "ROLLBACK-megamod-install.ps1"))
        check(rc == 0 and tree(inst.MODS) == mods_before and "G1R_Repopulate is in" in text and "NPCMarkers restored" in text,
              "[%s] rollback from that state: everything as before the install" % shell[0])

    # removing fails part-way: what is left is not a mod, and it is reported
    inst = build_world()
    target = os.path.join(inst.MODS, inst.NAME)
    mods_before = tree(inst.MODS)
    real_remove = inst._remove_file

    def stuck_remove(path):
        if os.path.basename(path) == "npcs.lua":
            raise PermissionError(13, "Access is denied (test)", path)
        return real_remove(path)
    inst._remove_file = stuck_remove
    code, out = run(inst)
    inst._remove_file = real_remove
    left = os.path.join(inst.MODS, "NPCMarkers.retired-tmp")
    check(code == 1 and "removing failed part-way" in out and "left-over folder in Mods: NPCMarkers.retired-tmp" in out and os.path.isdir(left)
          and not os.path.exists(os.path.join(left, "Scripts", "main.lua")) and not os.path.exists(os.path.join(left, "enabled.txt"))
          and not os.path.exists(os.path.join(inst.MODS, "NPCMarkers")) and not os.path.exists(os.path.join(inst.MODS, "G1R_Repopulate")),
          "removing a retired mod failed part-way: reported; the left-over has neither main.lua nor enabled.txt (UE4SS does not start it)")
    bdir = os.path.join(inst.WS, backups(inst)[-1])
    check(under(tree(os.path.join(bdir, "retired")), "NPCMarkers") == under(mods_before, "NPCMarkers"), "the complete copy of that mod is in the backup folder all the same")
    before_refusal = tree(sim)
    code, out = run(inst)
    check(isinstance(code, str) and "left over from an interrupted run" in code and code.endswith("Nothing changed.") and tree(sim) == before_refusal,
          "the next run refuses until the left-over is looked at")
    for shell in shells[:1]:
        rc, text = rollback(shell, inst, os.path.join(bdir, "ROLLBACK-megamod-install.ps1"))
        check(rc == 0 and without(tree(inst.MODS), "NPCMarkers.retired-tmp") == mods_before and "NOTE: left-over folder of an interrupted run" in text,
              "[%s] rollback from that state: both mods back complete, and the left-over is named" % shell[0])

    # the copy in the backup folder is not identical: the folder stays
    inst = build_world()
    mods_before = tree(inst.MODS)
    real_copy_tree = inst.copy_tree

    def bad_copy(src, dst):
        real_copy_tree(src, dst)
        if os.path.basename(src) == "NPCMarkers":
            write(os.path.join(dst, "Scripts", "main.lua"), b"-- cut short")
    inst.copy_tree = bad_copy
    code, out = run(inst)
    check(code == 1 and "NPCMarkers: the copy in the backup folder is not identical" in out and under(tree(inst.MODS), "NPCMarkers") == under(mods_before, "NPCMarkers")
          and not os.path.exists(os.path.join(inst.MODS, "G1R_Repopulate")), "a copy that differs from the folder: that mod is left in place, complete")

    # something else changes while the installer runs: the audit names it
    for what, rel_parts, expect in (("a file of another mod", ("Mods", "HUDMap", "settings.ini"), "CHANGED OUTSIDE THE MOD: Mods\\HUDMap\\settings.ini"),
                                    ("mods.txt", ("Mods", "mods.txt"), "CHANGED OUTSIDE THE MOD: Mods\\mods.txt"),
                                    ("a new file next to the mods", ("Mods", "stray.txt"), "CHANGED OUTSIDE THE MOD: Mods\\stray.txt"),
                                    ("a save", ("Saves", "Save1.sav"), "the save folder changed"),
                                    ("UE4SS.dll", ("UE4SS.dll",), "UE4SS.dll changed")):
        inst = build_world()
        victim = os.path.join(inst.SAVES, rel_parts[1]) if rel_parts[0] == "Saves" else os.path.join(inst.UE4SS, *rel_parts)
        real_copy_file = inst.copy_file
        state = {"done": False}

        def meddling_copy(src, dst, _victim=victim, _real=real_copy_file, _state=state):
            if not _state["done"]:
                _state["done"] = True
                write(_victim, b"changed by something else\n")
            return _real(src, dst)
        inst.copy_file = meddling_copy
        code, out = run(inst)
        check(code == 1 and expect in out and "PROBLEMS:" in out, "the audit notices a change it did not make: %s" % what)

    # ---- the shortcut in other states
    inst = build_world(shortcut="none")
    code, out = run(inst)
    check(code == 0 and "shortcut" not in out and not os.path.exists(inst.SHORTCUT) and not os.path.exists(os.path.join(inst.WS, backups(inst)[-1], "shortcut")),
          "no shortcut on the desktop: none is made")
    elsewhere = os.path.join(sim, "Other", "Tool.exe")
    write(elsewhere, b"MZ")
    inst = build_world(shortcut=elsewhere)
    write(elsewhere, b"MZ")
    lnk_before = read(inst.SHORTCUT)
    code, out = run(inst)
    check(code == 0 and "points to" in out and "left as it is" in out and read(inst.SHORTCUT) == lnk_before, "a shortcut that points somewhere else is left as it is, and that is said")
    inst = build_world()
    lnk_before = read(inst.SHORTCUT)
    inst.shortcut_read = lambda lnk: None
    code, out = run(inst)
    check(code == 0 and "cannot be read: left as it is" in out and read(inst.SHORTCUT) == lnk_before, "a shortcut that cannot be read is left as it is, and that is said")
    inst = build_world()
    lnk_before = read(inst.SHORTCUT)
    inst.shortcut_write = lambda *a: False
    code, out = run(inst)
    check(code == 1 and "could not be pointed to" in out and read(inst.SHORTCUT) == lnk_before and not os.path.exists(os.path.join(inst.MODS, "G1R_Repopulate")),
          "a shortcut that cannot be written: reported as a problem (the rest is done)")
    if not WINDOWS:
        inst = build_world()
        info = fake_shortcut_read(inst.SHORTCUT)
        info["icon"] = info["target"] + ",0"
        write(inst.SHORTCUT, json.dumps(info))
        code, out = run(inst)
        now = fake_shortcut_read(inst.SHORTCUT)
        check(code == 0 and now["icon"] == now["target"] + ",0" and inst.NAME in now["icon"], "an icon taken from the old file by its path follows to the new file")
    if has_exe and not ARGS.as_is:
        inst = build_world()
        os.remove(os.path.join(inst.MODS, "G1R_Repopulate", SETTINGS_EXE))
        lnk_before = read(inst.SHORTCUT)
        code, out = run(inst)
        check(code == 0 and "will point to a retired file" in out and read(inst.SHORTCUT) == lnk_before, "no settings app to take over: the shortcut is left, and that is said")

    # ================= refusals: nothing changed
    def refusal(text, prepare, expect, *argv):
        inst = build_world()
        prepare(inst)
        before = tree(sim)
        code, out = run(inst, *argv)
        check(isinstance(code, str) and expect in code and code.endswith("Nothing changed.") and tree(sim) == before, "refused, nothing changed: %s" % text)

    refusal("the game runs", lambda i: setattr(i, "running_images", lambda: ["g1r-win64-shipping.exe"]), "The game is running")
    refusal("the process list cannot be read", lambda i: setattr(i, "running_images", lambda: None), "cannot be read")
    refusal("the mod manager runs", lambda i: setattr(i, "running_images", lambda: ["explorer.exe", "iskllauncher.app.exe"]), "The mod manager is running")
    refusal("the settings app runs", lambda i: setattr(i, "running_images", lambda: ["g1r_repopulate_settings.exe"]), "The settings app is running")
    refusal("another UE4SS.dll", lambda i: write(os.path.join(i.UE4SS, "UE4SS.dll"), b"other"), "not the expected build")
    refusal("a folder of that name that is not this mod", lambda i: write(os.path.join(i.MODS, i.NAME, "readme.txt"), b"x"), "exists and is not this mod")
    refusal("package missing", lambda i: os.remove(os.path.join(i.PKGDIR, i.PACKAGE)), "Package file missing")

    def tamper(i):
        src = os.path.join(i.PKGDIR, i.PACKAGE)
        with zipfile.ZipFile(src) as zf:
            items = [(info, zf.read(info)) for info in zf.infolist()]
        with zipfile.ZipFile(src, "w", zipfile.ZIP_DEFLATED) as zf:
            for info, data in items:
                zf.writestr(info, data + (b"\n-- changed" if info.filename.endswith("Scripts/main.lua") and "/modules/" not in info.filename else b""))
    refusal("a package that does not match its manifest", tamper, "does not match the manifest")
    refusal("--sync-settings before the mod is installed", lambda i: None, "is not installed yet", "--sync-settings")
    refusal("an unknown option", lambda i: None, "unrecognized arguments", "--frobnicate")

    def installed_first(i):
        run(i, "--keep-separate")
    refusal("--sync-settings together with --keep-separate", installed_first, "do not go together", "--sync-settings", "--keep-separate")

    # ================= a 2.2 settings file of NPCMarkers is not taken over
    inst = build_world()
    write(os.path.join(inst.MODS, "NPCMarkers", "Scripts", "config.lua"), b"-- NPCMarkers 2.2 configuration\nlocal Config = {}\nConfig.WorldPinSize = 8\nreturn Config\n")
    code, out = run(inst)
    manifest = inst.read_manifest(os.path.join(inst.PKGDIR, inst.MANIFEST))
    got = tree(os.path.join(inst.MODS, inst.NAME))
    check(code == 0 and "is not a 2.3 settings file" in out and got[os.path.join("modules", "markers", "Scripts", "config.lua")] == manifest["modules/markers/Scripts/config.lua"]
          and read(os.path.join(inst.WS, backups(inst)[-1], "retired", "NPCMarkers", "Scripts", "config.lua")).startswith(b"-- NPCMarkers 2.2"),
          "a 2.2 settings file of NPCMarkers is not copied: the module keeps its default settings, that is said, and the file is in the backup folder")


# ---------------------------------------------------------------------------------------------
# The five converters: the player's files of 2026-10-01 and what they become
# ---------------------------------------------------------------------------------------------
# The file of each mod that holds its settings (G1R_WaitOnT has them built into its script), with the sha256 it had
# on the PC on 2026-10-01. The expectations below are for exactly these files; a mock whose file is another one
# (a stand-in, or the PC's own file in a rehearsal after the player changed something) is checked for consistency only.
SNAPSHOT = {
    "G1R_RegenMana": ("G1R_RegenMana.ini", "04844b06d84227ef5f8c8706def0e3464362941768867b61170e216ee02259e6"),
    "G1R_WaitOnT": ("Scripts/main.lua", "4f3b7fc5db8fc29d01f9feb75efbc1f5d7a1fe7a7dba15e48f23e5f011bea0de"),
    "BetterMining": ("BetterMining.ini", "9f139f7107caa10975d0ac207e572b95a277450b4c34bb096ce9c789b3339c55"),
    "SkillfulLocks": ("Scripts/config.lua", "4eac7fcb959c008744606942f9e9f9322241ace3c52ca62ef6482eea1de0c44d"),
    "G1R_MageBalance": ("Scripts/config.lua", "51a0aa80c3ae4fe8d66ef260a7ea7d0f7715e01a0541aebe945fc6f5919c1d65"),
}
FIVE = tuple(SNAPSHOT)
# What those files become: our module, then {our key: the text of its value in config.lua} - first the values that
# differ from what the module ships with (the lines the lead's order and the modules' own reports name), then the
# values the converter also gives and that are the shipped ones.
PLAYER = {
    "G1R_RegenMana": ("regen", {
        "ManaPercent": "2.0", "ManaUpTo": "75", "ManaPause": "15", "ManaCircleNone": "0", "ManaCircleNovice": "50",
        "HealthPercent": "1.0", "HealthFlat": "1.0", "HealthUpTo": "50", "HealthPause": "30",
    }, {
        "Enabled": "true", "ManaEnabled": "true", "ManaSeconds": "3.0", "ManaFlat": "0.0", "ManaByCircle": "false", "ManaCircleFirst": "100",
        "ManaCircleStep": "10", "HealthEnabled": "true", "HealthSeconds": "5.0", "ManaClearBlock": "true", "ShowMessage": "false",
    }),
    "G1R_WaitOnT": ("wait", {"ShortKey": '"Y"'}, {"ShortMinutes": "30", "Cooldown": "2.0", "ShowMessage": "true"}),
    "BetterMining": ("mining", {
        "YieldEnabled": "true", "BaseAmount": "0", "StrengthPerOre": "4.0", "DexterityPerOre": "6.0", "MinAmount": "0", "LowVeinRule": "false",
        "EndlessVeins": "true", "ShowMessage": "false",
    }, {"Enabled": "true"}),
    "SkillfulLocks": ("locks", {"SkilledConnections": '"safe"', "MasterConnections": '"all"', "LogLocks": "true"},
                      {"UntrainedConnections": '"as the game has it"'}),
    "G1R_MageBalance": ("magic", {
        "WholeMana": "false", "FireBoltSteps": "true", "FireBoltStep0": "30", "FireBoltMana": "2.0",
        "FireBallDamage": "1.25", "FireBallCastTime": "0.7", "FireBallMana": "1.25",
        "BallLightningSpeed": "800", "BallLightningCastTime": "0.7", "BallLightningMana": "1.25",
        "FireRainDamage": "2.5", "FireRainMana": "1.5",
        "IceBoltSteps": "true", "IceBoltStep0": "25", "IceBoltStep2": "40", "IceBoltStep4": "45", "IceBoltStep6": "55",
        "BreathOfDeathDamage": "2.0", "BreathOfDeathCastTime": "0.5",
        "PyrokinesisDamage": "2.5", "StormOfFireDamage": "1.2", "UrizielDamage": "2.778", "ChainLightningDamage": "3.0",
        "WindFistDamage": "2.0", "WindFistStagger": "5.0",
        "DeathToTheUndeadDamage": "1.998", "DeathToTheUndeadMana": "1.2", "DeathToTheUndeadCastTime": "4.0",
        "StormFistMana": "1.5", "IceWaveMana": "1.333", "IceBlockFreeze": "true",
        "CircleCosts": "true", "CircleCost2": "12", "CircleCost3": "15", "CircleCost4": "18", "CircleCost5": "20", "CircleCost6": "25",
    }, {
        "Enabled": "true", "FireBoltStep2": "40", "FireBoltStep4": "50", "FireBoltStep6": "65", "BallLightningDamage": "1.0", "BreathOfDeathMana": "1.0",
        "StormOfFireMana": "1.0", "UrizielMana": "1.0", "StormFistDamage": "1.0", "IceWaveDamage": "1.0", "IceBlockDamage": "1.0", "CircleCost1": "10",
    }),
}
# What each module says when it starts with those settings (from the modules' own suites and the lead's order).
LOAD_LINES = {
    "regen": "loaded: mana +2% every 3 s up to 75%, pause 15 s; health +1 and +1% every 5 s up to 50%, pause 30 s",
    "wait": "loaded: Y = 30 minutes",
    "mining": "loaded: ore per swing: base 0, +1 per 4 Strength, +1 per 6 Dexterity, 0 to 100, the same from a nearly empty vein; veins never run out",
    "locks": "loaded: connections taken away game / safe / all (untrained / skilled / master); wrong moves per pick game / game / game",
    "magic": "loaded: 24 setting(s) for single spells, 1 ice spell(s) freeze with every hit, own prices for the magic circles",
}


def config_rel(module):
    return "modules/%s/Scripts/config.lua" % module


def with_values(default, values, schema_defaults=None):
    """The text of a default config.lua with these values ({key: the text of the value}) - made by replacing the
    key's line as a whole, not by the installer's rule. A key that has no line of its own (a setting that is not
    shown) gets one below the last line with text, unless the value is the schema's default for it (schema_defaults:
    {key: text}); None when that cannot be done by this simple rule."""
    text = default
    for key, value in values.items():
        line = re.compile(rb"(?m)^Config\." + key.encode("ascii") + rb" = [^\r\n]*$")
        found = line.findall(text)
        if len(found) == 1:
            text = line.sub(lambda m: b"Config." + key.encode("ascii") + b" = " + value.encode("utf-8"), text)
        elif found:
            return None
        elif (schema_defaults or {}).get(key) != value:
            if text.count(b"\n\nreturn Config\n") != 1 or not text.endswith(b"\n\nreturn Config\n"):
                return None
            text = text[:-len(b"\n\nreturn Config\n")] + b"\nConfig." + key.encode("ascii") + b" = " + value.encode("utf-8") + b"\n\nreturn Config\n"
    return text


def literal_value(text):
    """The value a text of config.lua stands for: true / false, a text in double quotes, a number."""
    if text in ("true", "false"):
        return text == "true"
    if text.startswith('"'):
        return re.sub(r"\\(.)", r"\1", text[1:-1])
    return float(text)


def snapshot_file(mod):
    """The settings file of one of the five mods as it was on the PC on 2026-10-01 (from --fixtures / --regen-ini):
    its bytes, or None when the file is not there or is not that file."""
    rel, digest = SNAPSHOT[mod]
    path = ARGS.regen_ini if mod == "G1R_RegenMana" else os.path.join(ARGS.fixtures or "", mod, rel.replace("/", os.sep))
    data = read(path) if path and os.path.isfile(path) else None
    return data if data is not None and sha_of(data) == digest else None


def is_snapshot(mods, mod):
    """Whether the mock's Mods folder (a tree()) holds that mod with its settings file of 2026-10-01."""
    rel, digest = SNAPSHOT[mod]
    return {k.lower(): v for k, v in files_of(mods, mod).items()}.get(rel.lower()) == digest


def player_text(files, mod, change=None):
    """The config.lua our module gets from the player's file of that mod: the package's default with his values.
    change: {key: value text} that a case has different."""
    module, differ, shipped = PLAYER[mod]
    return with_values(files[config_rel(module)], dict(dict(differ, **shipped), **(change or {})), {"ManaClearBlock": "true"})


class Converted:
    """What the installer's conversion makes of one mod of the table whose folder holds `their_files`
    ({path inside the mod: bytes}): plan_carry on a folder written for the case, nothing else of the installer.
    player=True: our config.lua counts as changed by the player."""
    root = None

    def __init__(self, inst, files, mod, their_files, player=False):
        base = os.path.join(WORK, "convert")
        wipe(base)
        for rel, data in their_files.items():
            write(os.path.join(base, "Mods", mod, rel.replace("/", os.sep)), data)
        os.makedirs(os.path.join(base, "Mods", mod), exist_ok=True)
        inst.MODS = os.path.join(base, "Mods")
        entry = next(e for e in inst.TAKEOVERS if e[0] == mod)
        todo = [{"mod": mod, "folder": mod, "inside": {rel: sha_of(data) for rel, data in their_files.items()}, "convert": entry[3]}]
        self.mod, self.module = mod, entry[2]
        self.carry = inst.plan_carry(todo, files, {}, (lambda rel: (False, "changed by the player")) if player else (lambda rel: (True, "not there yet")))
        convs = self.carry["conversions"]
        self.conv = convs[0] if len(convs) == 1 else None
        self.set = dict(self.conv["set"]) if self.conv else {}
        self.same = dict(self.conv["same"]) if self.conv else {}
        self.values = dict(self.set, **self.same)
        self.remarks = dict(self.conv["remarks"]) if self.conv else {}
        self.default = files[config_rel(self.module)]
        self.text = self.carry["texts"].get(config_rel(self.module))
        self.lost = [(l["what"], l["why"]) for l in self.carry["lost"]]
        self.notes = list(self.carry["notes"])
        self.plan = "\n".join(inst.settings_lines(self.carry, [mod]) + ["  note: " + n for n in self.notes])
        self.only_module = len(convs) <= 1 and all(c["module"] == self.module for c in convs)

    def why(self, what):
        """The reasons given for something that was not carried over (what: the start of its text)."""
        return [why for text, why in self.lost if text == what or text.startswith(what + "=") or text.startswith(what + " ")]

    def first(self, what):
        """The first reason given for it ("" when it is not listed)."""
        return (self.why(what) or [""])[0]

    def told(self, *whats):
        """Whether each of these is listed as not carried over."""
        return all(self.why(what) for what in whats)

    def shows(self):
        return "set %r, same %r, lost %r, notes %r" % (self.set, self.same, self.lost, self.notes)


# ---------------------------------------------------------------------------------------------
# Part "rules": the installer's readers and its config.lua rule, against the mod's own Lua code
# ---------------------------------------------------------------------------------------------
ORACLE = r"""
-- Answers of the mod's own code (Scripts/core/kit.lua, settings.lua) and of Lua itself, for the simulation.
-- Usage: lua oracle.lua <folder with kit.lua and settings.lua> <cases> <answers>; a case is "op TAB hex TAB hex ...".
local core, cases, answers = arg[1], arg[2], arg[3]
G1R_KIT = dofile(core .. "/kit.lua")
local Settings = dofile(core .. "/settings.lua")
local function unhex(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end
local function hex(s) return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
local function leaf(v)
    if type(v) == "boolean" then return "b:" .. tostring(v) end
    if math.type(v) == "integer" then return "i:" .. ("%d"):format(v) end
    if type(v) == "number" then return "f:" .. ("%.17g"):format(v) end
    return "s:" .. hex(tostring(v))
end
local function flat(t, prefix, out)
    for k, v in pairs(t) do
        local name = prefix .. (math.type(k) == "integer" and ("#" .. k) or ("$" .. hex(tostring(k))))
        if type(v) == "table" then flat(v, name .. ".", out) else out[#out + 1] = name .. "=" .. leaf(v) end
    end
    return out
end
local f = assert(io.open(answers, "wb"))
for line in io.lines(cases) do
    local parts = {}
    for p in (line .. "\t"):gmatch("([^\t]*)\t") do parts[#parts + 1] = p end
    local op, a = parts[1], {}
    for i = 2, #parts do a[#a + 1] = unhex(parts[i]) end
    local ok, result = pcall(function()
        if op == "patch" then return Settings.patch(a[1], a[2], a[3]) end
        if op == "patchall" then            -- a text, then key, value, key, value ...: one after the other, as the game sets several
            local text = a[1]
            for i = 2, #a, 2 do text = Settings.patch(text, a[i], a[i + 1]) end
            return text
        end
        if op == "open" then
            -- a module name, its schema.lua, a config.lua: what the game's settings service says when it reads that
            -- file (every line it logs), and the values the module then works with
            local dir = core .. "/open/"
            for name, text in pairs({ ["schema.lua"] = a[2], ["config.lua"] = a[3] }) do
                local f = assert(io.open(dir .. name, "wb"))
                f:write(text)
                f:close()
            end
            local lines = {}
            local object, problem = Settings.open({ module = a[1], dir = dir, log = function(text) lines[#lines + 1] = tostring(text) end })
            if not object then return "<not opened> " .. tostring(problem) end
            local out = flat(object.values, "", {})
            table.sort(out)
            return table.concat(lines, "\n") .. "\n==\n" .. table.concat(out, ";")
        end
        if op == "number" then return Settings.numberText(tonumber(a[1]), tonumber(a[2])) end
        if op == "key" then local k = Settings.keyText(a[1]); return k == nil and "<nil>" or k end
        if op == "text" then return Settings._test.literal({ Kind = "text" }, a[1]) end
        if op == "fit" then
            local item = { Kind = "number", Min = tonumber(a[1]), Max = tonumber(a[2]), Decimals = tonumber(a[3]), Default = tonumber(a[1]) }
            return Settings._test.literal(item, (Settings._test.checked(item, tonumber(a[4]))))
        end
        if op == "default" then return Settings.defaultText(assert(load(a[1], "=schema", "t", {}))()) end
        if op == "tonumber" then local n = tonumber(a[1]); return n == nil and "<nil>" or leaf(n) end
        if op == "lua" then
            local chunk = load((a[1]:gsub("^\239\187\191", "")), "=file", "t", {})     -- without a byte order mark, as the game reads its files
            if not chunk then return "<not Lua>" end
            local t = chunk()
            if type(t) ~= "table" then return "<no table>" end
            local out = flat(t, "", {})
            table.sort(out)
            return table.concat(out, ";")
        end
        return "<unknown op>"
    end)
    f:write(hex(ok and tostring(result) or ("<error> " .. tostring(result))), "\n")
end
f:close()
"""


def lua_oracle(cases):
    """What the mod's own Lua code answers for [(op, bytes, ...)]: a list of bytes (None without Lua)."""
    if not LUA:
        return None
    core = os.path.join(WORK, "core")
    files = package_files(*NEW)
    for name in ("kit.lua", "settings.lua"):
        write(os.path.join(core, name), files["Scripts/core/" + name])
    os.makedirs(os.path.join(core, "open"), exist_ok=True)
    script, asked, answered = os.path.join(WORK, "oracle.lua"), os.path.join(WORK, "cases.txt"), os.path.join(WORK, "answers.txt")
    write(script, ORACLE)
    write(asked, "".join("\t".join([c[0]] + [a.hex() for a in c[1:]]) + "\n" for c in cases))
    p = subprocess.run([LUA, script, core, asked, answered], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if p.returncode != 0:
        raise SystemExit("the Lua side of the rule checks failed:\n" + p.stdout.decode("utf-8", "replace"))
    return [bytes.fromhex(line) for line in read(answered).decode("ascii").split("\n")[:-1]]


def canonical(table, prefix=""):
    """A table read by the installer's read_lua in the form the oracle's op "lua" prints."""
    out = []
    for k, v in table.items():
        if isinstance(k, float):
            k = "%.14g" % k                       # how Lua shows a number that is not whole
        name = prefix + (("#%d" % k) if isinstance(k, int) else ("$" + k.encode("utf-8", "surrogateescape").hex()))
        if isinstance(v, dict):
            out.extend(canonical(v, name + "."))
        elif isinstance(v, bool):
            out.append(name + "=b:" + ("true" if v else "false"))
        elif isinstance(v, int):
            out.append(name + "=i:%d" % v)
        elif isinstance(v, float):
            out.append(name + "=f:%.17g" % v)
        else:
            out.append(name + "=s:" + v.encode("utf-8", "surrogateescape").hex())
    return out


def part_rules():
    inst = load_installer()
    b = lambda s: s.encode("utf-8", "surrogateescape")
    files = package_files(*NEW)

    # ---- the rule for changing a value in a config.lua
    xp_default = files.get("modules/xp/Scripts/config.lua", (STANDIN_CONFIG % {"name": "xp"}).encode("ascii"))
    texts = [
        xp_default, xp_default.replace(b"\n", b"\r\n"), b"", b"return Config", b"return Config\n", b"\nreturn Config\n", b"\n\n  \nreturn Config\n",
        b"local Config = {}\nreturn Config", b"local Config = {}\n\n\nreturn Config\n\n\n", b"local Config = {}\r\n\r\nreturn Config\r\n",
        b"local Config = {}\nConfig.A = 1\nConfig.A = 2\nreturn Config\n", b"Config.A = 1\nlocal x\nreturn Config\n", b"  Config.A = 1 -- note\nreturn Config\n",
        b"\tConfig.A=1\r\nreturn Config\r\n", b"-- Config.A = 1\nreturn Config\n", b"Config.AB = 1\nConfig.BA = 2\nreturn Config\n", b"Config.A   =   7   \nreturn Config -- end\n",
        b"local Config = {}\nreturn Config\n-- after the end\n", b"local Config = {}\nreturn Config\nreturn Config\n", b"local Config = {}\nreturn  Config  \n  \n",
        b"local Config = {}\nreturn\nConfig\n", b"local Config = {}\nreturn Configuration\n", b"local Config = {}\n  return Config", b"no line end", b"x\n\n", b"\r\n\r\nreturn Config",
        b"Config.A = 1", b"Config.A = 1\rConfig.A = 2\nreturn Config\n", b"local Config = {}\nConfig.B = 2\n\n-- tail\n\nreturn Config\n",
    ]
    cases = [("patch", t, k, v) for t in texts for k, v in ((b"A", b"5"), (b"Multiplier", b"4.0"), (b"CheckMilliseconds", b"100"), (b"B", b'"a b"'))]
    rng = random.Random(20261002)
    pieces = [b"local Config = {}", b"Config.A = 1", b"  Config.A = 2 -- note", b"\tConfig.A=3", b"-- Config.A = 4", b"Config.AB = 5", b'Config.B = "x"', b"", b"   ", b"\t",
              b"return Config", b"return  Config  ", b"  return Config -- end", b"return Configuration", b"-- comment", b"x = 1", b"Config.A   =   7", b"return\tConfig", b"Config.A ="]
    for _ in range(600):
        newline = rng.choice([b"\n", b"\n", b"\r\n"])
        text = newline.join(rng.choice(pieces) for _ in range(rng.randint(0, 8))) + rng.choice([b"", newline, newline + newline, b"  ", b"\n \n", b"\r"])
        cases.append(("patch", text, rng.choice([b"A", b"B", b"AB", b"C"]), rng.choice([b"1", b"4.0", b"true", b'"a b"'])))
    mine = [inst.patch_config(c[1], c[2].decode("ascii"), c[3]) for c in cases]
    theirs = lua_oracle(cases)
    if theirs is not None:
        differ = [i for i in range(len(cases)) if mine[i] != theirs[i]]
        check(not differ, "the rule for changing a value in config.lua: %d texts (%d written, %d generated) come out exactly as from the game's own Settings.patch%s"
              % (len(cases), len(texts) * 4, 600, "" if not differ else " - FIRST DIFFERENCE: %r key %r -> %r, the game: %r" % (cases[differ[0]][1], cases[differ[0]][2], mine[differ[0]], theirs[differ[0]])))
    one = inst.patch_config(xp_default, "Multiplier", b"4.0")
    check(one == xp_default.replace(b"Config.Multiplier = 1.0", b"Config.Multiplier = 4.0") and one != xp_default
          and inst.patch_config(b"Config.A = 1\nConfig.A = 2 -- x\r\nreturn Config\n", "A", b"9") == b"Config.A = 1\nConfig.A = 9\r\nreturn Config\n"
          and inst.patch_config(b"local Config = {}\n\nreturn Config\n", "N", b"3") == b"local Config = {}\nConfig.N = 3\n\nreturn Config\n"
          and inst.patch_config(b"a\r\n\r\nreturn Config\r\n", "N", b"3") == b"a\r\nConfig.N = 3\r\n\r\nreturn Config\r\n"
          and inst.patch_config(b"a\n", "N", b"3") == b"a\nConfig.N = 3\n",
          "by hand: the last matching line gets the value (its comment goes, its line end stays); a new line goes below the last line with text in front of return Config, with the file's line ending; without that line it is appended")

    # ---- values as the game writes them
    numbers = [0, 1, 4, 4.0, 2.5, 0.75, 1 / 3, 2.675, -0.001, -0.4, 10, 99.999, 0.005, 1e-7, 123456.789, 0.5, 1.5, 2.5000001, -2.5, 1e15]
    cases = [("number", repr(float(n)).encode("ascii"), str(d).encode("ascii")) for n in numbers for d in (0, 1, 2, 3)]
    mine = [b(inst.number_text(float(c[1]), int(c[2]))) for c in cases]
    fits = [("fit", str(lo).encode(), str(hi).encode(), str(d).encode(), repr(float(v)).encode()) for lo, hi in ((0, 10), (1, 60), (-5, 5)) for d in (0, 2)
            for v in (-7, 0, 0.004, 0.5, 1.49, 2.5, 3.14159, 9.999, 10, 61, 250.5)]
    mine += [b(inst.literal({"Kind": "number", "Decimals": int(c[3])}, inst.fit_value({"Kind": "number", "Min": int(c[1]), "Max": int(c[2]), "Decimals": int(c[3])}, float(c[4]))[0]))
             for c in fits]
    words = ["plain", 'a"b', "back\\slash", "tab\there", "new\nline", "", "\x7fdel", "caf\u00e9", 'both \\" of them', "C:\\Games\\x"]
    quoted = [("text", b(w)) for w in words]
    mine += [b(inst.literal({"Kind": "text"}, w)) for w in words]
    keys = ["Y", "y", "ctrl+y", "CTRL + Y", "shift+alt+f5", "alt+shift+ctrl+f5", "strg+1", "Delete", "", "  ", "ctrl", "ctrl+", "a+b", "F13", "num5", "mouse4",
            "enter", "PageUp", "page_up", "+", "stra\u00dfe", "ctrl+shift", "x button", "control+insert", "F12", "oem_102", "ALT+ALT+Q", "\u0131"]
    asked = [("key", b(k)) for k in keys]
    mine += [b("<nil>" if inst.key_text(k) is None else inst.key_text(k)) for k in keys]
    theirs = lua_oracle(cases + fits + quoted + asked)
    if theirs is not None:
        differ = [i for i in range(len(mine)) if mine[i] != theirs[i]]
        check(not differ, "values as the game writes them: %d numbers, %d numbers pulled into a range, %d texts and %d key combinations come out exactly as from the game's own code%s"
              % (len(cases), len(fits), len(quoted), len(asked), "" if not differ else " - FIRST DIFFERENCE: %r -> %r, the game: %r" % ((cases + fits + quoted + asked)[differ[0]], mine[differ[0]], theirs[differ[0]])))
    check(inst.number_text(4.0, 2) == "4.0" and inst.number_text(3, 0) == "3" and inst.number_text(0.75, 2) == "0.75" and inst.number_text(2.5, 0) == "3"
          and inst.literal({"Kind": "bool"}, True) == "true" and inst.literal({"Kind": "bool"}, False) == "false"
          and inst.literal({"Kind": "text"}, 'a "b" \\ c') == '"a \\"b\\" \\\\ c"' and inst.literal({"Kind": "choice"}, "top right") == '"top right"'
          and inst.key_text("ctrl + y") == "CTRL+Y" and inst.key_text("nonsense") is None,
          "by hand: true / false, whole numbers plain, decimals trimmed to at least one place, texts in double quotes with \\\\ and \\\"")
    item = {"Kind": "number", "Min": 0, "Max": 10, "Decimals": 2}
    check(inst.fit_value(item, 25) == (10.0, "was 25; the range is 0 to 10") and inst.fit_value(item, 4.0) == (4.0, None) and inst.fit_value(item, "abc")[0] is None
          and inst.fit_value(item, True)[0] is None and inst.fit_value({"Kind": "bool"}, 1)[0] is None and inst.fit_value({"Kind": "bool"}, False) == (False, None)
          and inst.fit_value({"Kind": "choice", "Options": {1: "a", 2: "b"}}, "c")[0] is None and inst.fit_value({"Kind": "choice", "Options": {1: "a", 2: "b"}}, "b") == ("b", None)
          and inst.fit_value({"Kind": "key"}, "strg+y")[0] == "CTRL+Y" and inst.fit_value({"Kind": "key"}, "nonsense")[0] is None
          and inst.fit_value({"Kind": "text"}, 5)[0] is None and inst.fit_value({"Kind": "action"}, True)[0] is None
          and inst.fit_value({"Kind": "number", "Min": 1, "Max": 10, "Decimals": 0}, 2.5) == (3, "was 2.5; rounded"),
          "a converted value is checked against the schema: numbers are pulled into Min..Max and rounded (and that is said), a wrong kind, an unknown choice or key is refused")

    # ---- the reader for plain Lua settings files, against Lua itself
    real = [os.path.join(ARGS.fixtures or "", rel) for rel in ("SkillfulLocks/Scripts/config.lua", "G1R_MageBalance/Scripts/config.lua", "SharedModMenu/Scripts/config.lua",
                                                               "NPCMarkers/Scripts/config.lua", "G1R_Repopulate/Scripts/config.lua")]
    samples = [read(p) for p in real if os.path.isfile(p)]
    n_real = len(samples)
    samples += [data for rel, data in sorted(files.items()) if re.match(r"^modules/[^/]+/Scripts/(schema|config)\.lua$", rel) or rel == "Scripts/core/modules.lua"]
    n_package = len(samples) - n_real
    samples += [FAKES["SkillfulLocks"]["Scripts/config.lua"], FAKES["G1R_MageBalance"]["Scripts/config.lua"], (STANDIN_SCHEMA % {"name": "x"}).encode("ascii"),
                b"return { a = 1, b = { c = \"x\", [2] = true, 3.5, -4 }, }",
                b"local Config = {}\nConfig.A = 1\nConfig.B = { 1, 2 }\nConfig.B[3] = \"z\"\nConfig.T = {}\nConfig.T.x = -0.5\nConfig[\"quoted key\"] = false\nreturn Config\n",
                b"-- c\n--[[ block\ncomment ]] return --[==[ x ]==] { 'single', \"esc \\\" \\\\ \\n \\t \\65 \\x41 \\u{e9}\", [[long\nstring]], [==[with ]] inside]==], 0x10, 1e3, .5, 5., 1E-2 };",
                b"\xef\xbb\xbfreturn { n = nil, 1, nil, 3, t = { }, deep = { { { { 1 } } } }, [\"k\"] = 1, [-1] = \"neg\", [1.5] = \"f\", [2.0] = \"two\" }",
                b"local A = { 1, 2 }\nlocal B = { a = A, }\nB.c = \"\\\n line\"\nreturn B",
                b"Config = { x = 1 ; y = 2 }\nConfig.x = nil\nreturn Config", b"local t = {}; t.a = { b = {} }; t.a.b.c = 7; return t",
                b"return { [\"caf\xc3\xa9\"] = \"\xff raw byte\" }"]
    cases = [("lua", s) for s in samples]
    mine = []
    for s in samples:
        try:
            mine.append(b(";".join(sorted(canonical(inst.read_lua(s))))))
        except inst.LuaError as e:
            mine.append(b("<LuaError> %s" % e))
    theirs = lua_oracle(cases)
    if theirs is not None:
        differ = [i for i in range(len(mine)) if mine[i] != theirs[i]]
        check(not differ and n_package >= 3, "the reader for plain Lua files gives what Lua itself gives: %d files (%d real settings files of other mods, %d of the package, %d written cases)%s"
              % (len(samples), n_real, n_package, len(samples) - n_real - n_package, "" if not differ else " - FIRST DIFFERENCE in %r: %r, Lua: %r" % (samples[differ[0]][:80], mine[differ[0]][:200], theirs[differ[0]][:200])))
    more = [b"return { a = f() }", b"return { a = 1 + 2 }", b'return { a = "x" .. "y" }', b"x = os.time()\nreturn {}", b"return function() end", b"local Config = {}\nConfig.A = 1\n",
            b"return 5", b"return { a = b }", b'return { a = "open }', b"while true do end", b"return { a = math.huge }", b"local C = {}\nC.x.y = 1\nreturn C", b"return { a = 1 } + 1",
            b"return { a = #t }", b"return { a = not true }", b"return { [true] = 1 }", b"return {", b"return { 1 2 }", b"local C = {}\nC:method()\nreturn C", b"return { a = -x }",
            b"return setmetatable({}, {})", b"--[[ never closed\nreturn {}", b"return { a = 12abc }", b"return { 'a\nb' }", b"return {} return {}", b"return { a = (1) }",
            b"if true then return {} end", b"return { a = { b = { c = function() end } } }", b"return require('x')", b"\x00\x01\x02", b"MZ\x90\x00"]
    refused = []
    for s in more:
        try:
            inst.read_lua(s)
        except inst.LuaError:
            refused.append(s)
    check(len(refused) == len(more), "a Lua file that is more than plain values is refused, nothing of it is run: %d of %d cases (a call, a calculation, a function, a loop, a name it does not know, a file without return)%s"
          % (len(refused), len(more), "" if len(refused) == len(more) else " - ACCEPTED: %r" % [s for s in more if s not in refused][:3]))
    t = inst.read_lua(b"return { removeConnections = { untrained = false, skilled = \"auto\" }, list = { 10, 12 }, debug = true }")
    check(t == {"removeConnections": {"untrained": False, "skilled": "auto"}, "list": {1: 10, 2: 12}, "debug": True} and inst.lua_list(t["list"]) == [10, 12]
          and inst.lua_flat(t) == [("removeConnections.untrained", False), ("removeConnections.skilled", "auto"), ("list.1", 10), ("list.2", 12), ("debug", True)],
          "by hand: nested tables come as nested dicts, list positions count from 1, and the flat form names every value by its path")
    asked = [("tonumber", b(s)) for s in ("4.0", "4", " 7 ", "0x10", "1e2", ".5", "5.", "-3", "+3", "4,0", "abc", "", "1_000", "inf", "nan", "0x", "1e", "  ", "3 4", "-0x1F", "1.5e-3", "--1", "0b1")]
    theirs = lua_oracle(asked)
    if theirs is not None:
        mine = []
        for _, s in asked:
            n = inst.lua_tonumber(s.decode("ascii"))
            mine.append(b("<nil>" if n is None else ("i:%d" % n if isinstance(n, int) else "f:%.17g" % n)))
        differ = [i for i in range(len(mine)) if mine[i] != theirs[i]]
        check(not differ, "a number written as text is read the way Lua's tonumber reads it: %d texts%s" % (len(asked), "" if not differ else " - DIFFER: %r" % [(asked[i][1], mine[i], theirs[i]) for i in differ[:3]]))
        default = lua_oracle([("default", (STANDIN_SCHEMA % {"name": "simtest"}).encode("ascii"))])[0]
        items, why = inst.module_schema({"modules/simtest/Scripts/schema.lua": (STANDIN_SCHEMA % {"name": "simtest"}).encode("ascii")}, "simtest")
        check(default == (STANDIN_CONFIG % {"name": "simtest"}).encode("ascii") and why is None and list(items) == ["Enabled", "Amount", "Count", "Mode", "Name", "Key", "Secret", "Quiet", "Push"]
              and items["Amount"]["Max"] == 10 and items["Secret"]["Hidden"] is True and inst.lua_list(items["Mode"]["Options"]) == ["auto", "all", "off"],
              "the simulation's stand-in module: its config.lua is the default text the game makes from its schema, and the installer reads the schema's items")

    # ---- the ini reader
    text = (b"\xef\xbb\xbf; comment\r\n# another\r\n\r\nTop = 1\r\n  Spaced Key   =   some value ; kept  \r\n[ Settings ]\r\nEnabled=true\r\n;StrPerOre=1\r\nStrPerOre=4\r\nstrperore=5\r\n"
            b"Empty=\r\n=novalue\r\nno equals sign\r\nPath=C:\\x=y\r\n[Other]\r\nEnabled=no\r\nPrefix=>>\r\n[broken\r\n")
    entries, unread = inst.read_ini(text)
    check(entries == [("", "Top", "1", 4), ("", "Spaced Key", "some value ; kept", 5), ("Settings", "Enabled", "true", 7), ("Settings", "StrPerOre", "4", 9), ("Settings", "strperore", "5", 10),
                      ("Settings", "Empty", "", 11), ("Settings", "Path", "C:\\x=y", 14), ("Other", "Enabled", "no", 16), ("Other", "Prefix", ">>", 17)]
          and [n for n, _ in unread] == [12, 13, 18],
          "the ini reader: sections, ; and # comments, key=value with spaces around both, the first = splits, a byte order mark and CRLF are fine, lines that are neither are reported")
    their = inst.TheirMod("X", "/nowhere", [])
    handed = their._hand_out("x.ini", [((s + "." + k) if s else k, v) for s, k, v, _ in entries], False, None)
    check(handed.number("top") == 1 and handed.number("STRPERORE") == 5 and handed.number("settings.strperore") == 5 and handed.boolean("Other.Enabled") is False
          and handed.boolean("Settings.Enabled") is True and handed.boolean("enabled") is None and handed.text("prefix") == ">>" and handed.number("Empty") is None
          and handed.value("Missing") is None and handed.number("Path") is None
          and [n for n, _ in handed.rest()] == ["Spaced Key"] and len(handed.complaints) == 4,
          "values are found without regard to case, the last of two counts, yes / no / on / off / 1 / 0 are true and false, a key in two sections must be named with its section, "
          "and what is missing, unusable or not asked for is kept for the plan")
    lua_file = their._hand_out("c.lua", inst.lua_flat(inst.read_lua(FAKES["G1R_MageBalance"]["Scripts/config.lua"])), True, None, inst.read_lua(FAKES["G1R_MageBalance"]["Scripts/config.lua"]))
    spells = lua_file.table("spells")
    fixed = their.fixed({"Key": "Y", "Minutes": 30})
    check(spells == {"Feuerball": {"class": "FireBallProjectileDefinition", "damage": 1.25, "mana": {1: 2}}} and inst.lua_list(lua_file.table("CircleCost")) == [10, 12, 15, 18, 20, 25]
          and lua_file.boolean("Enabled") is True and lua_file.text("modname") == "G1R Mage Balance" and lua_file.number("Verbose") is None and lua_file.table("Nothing") is None
          and lua_file.rest() == [] and len(lua_file.complaints) == 2 and handed.table("other") == {"Enabled": "no", "Prefix": ">>"}
          and fixed.text("key") == "Y" and fixed.number("Minutes") == 30 and fixed.rest() == [],
          "a Lua file's values come with their kinds; a whole table is handed out as it stands (nested, lists from 1), an ini section as its keys; built-in values of a mod without a file work the same")
    # ---- what a converter uses for a file whose tables it walks by hand, and how the plan prints what it gives back
    tree_ = inst.read_lua(b'return { Debug = true, levels = { a = 1, b = { c = 2, d = "x" } }, list = { 4, 5 }, listing = 7, other = 6 }')
    exact = their._hand_out("c.lua", inst.lua_flat(tree_), True, None, tree_, True)
    loose = their._hand_out("c.lua", inst.lua_flat(tree_), True, None, tree_)
    looked = (exact.value("debug"), exact.value("Debug"), loose.value("debug"), exact.peek("levels.b"), exact.peek("Levels"), exact.peek() == tree_, exact.peek("levels.b.c"), loose.table("LEVELS.B"))
    before = [n for n, _ in exact.rest()]
    exact.used("levels.b")
    exact.used("Other")
    mid = [n for n, _ in exact.rest()]
    exact.leave("list", "a list")
    exact.leave("LEVELS.a", "wrong case")
    exact.tell("something it did", "has no counterpart")
    their.remark("m", "Key", "how it was worked out")
    check(looked == (None, True, True, {"c": 2, "d": "x"}, None, True, 2, {"c": 2, "d": "x"}) and before == ["levels.a", "levels.b.c", "levels.b.d", "list.1", "list.2", "listing", "other"]
          and mid == ["levels.a", "list.1", "list.2", "listing", "other"] and [n for n, _ in loose.rest()] == ["levels.a", "list.1", "list.2", "listing", "other"]
          and [n for n, _ in exact.rest()] == ["levels.a", "listing", "other"] and exact.complaints == [("debug", "is not in c.lua")]
          and exact.passed == [("list.1=4", "a list"), ("list.2=5", "a list"), ("something it did", "has no counterpart")] and their.remarks == {("m", "Key"): "how it was worked out"}
          and their.fixed({"A": 1}, "Scripts\\main.lua").name == "Scripts\\main.lua" and their.fixed({"A": 1}).name == "built-in values",
          "a Lua file read with its names as written (exact): Debug is not debug; peek() hands out a value or table without marking it, used() marks a value or a whole table as "
          "dealt with, leave() lists every value of a table with the reason, tell() adds a line that is no value of the file - and what is left is what the plan lists as overlooked")
    conv = {"mod": "M", "module": "m", "config": "modules/m/Scripts/config.lua", "state": "write", "why": "not there yet", "set": {"A": "1", "B": "2.0"}, "same": {"C": "true"},
            "remarks": {"B": "was 2.04; rounded", "C": "theirs: on"}}
    six = dict(conv, set={k: "1" for k in "ABCDEF"}, same={}, remarks={})
    seven = dict(conv, set={k: "1" for k in "ABDEFGH"}, remarks={"C": "theirs: on", "H": "was 0; the range is 1 to 9"})
    lost = [{"mod": "M", "what": "x=1", "why": "no setting"}, {"mod": "M", "what": "y=2", "why": "no setting"}, {"mod": "N", "what": "z=3", "why": "another"}]
    where = "  settings: Mods\\M -> G1R_MegaMod\\modules\\m\\Scripts\\config.lua: "
    check(inst.conversion_lines(conv) == [where + "A = 1, B = 2.0 (was 2.04; rounded) (our default already: C = true (theirs: on))"]
          and inst.conversion_lines(dict(conv, state="player", why="changed by the player")) == [where + "NOT written, the file was changed by the player (it would get: A = 1, B = 2.0 (was 2.04; rounded))"]
          and inst.conversion_lines(dict(conv, state="nothing", set={})) == [where + "nothing to write (our default already: C = true (theirs: on))"]
          and inst.conversion_lines(six) == [where + "A = 1, B = 1, C = 1, D = 1, E = 1, F = 1"]
          and inst.conversion_lines(seven) == [where + "7 values"] + ["      %s = 1" % k for k in "ABDEFG"] + ["      H = 1 (was 0; the range is 1 to 9)", "      (our default already: C = true (theirs: on))"]
          and inst.conversion_lines(dict(seven, state="player", why="changed by the player"))
          == [where + "NOT written, the file was changed by the player; it would get 7 values:"] + ["      %s = 1" % k for k in "ABDEFG"] + ["      H = 1 (was 0; the range is 1 to 9)"]
          and inst.settings_lines({"conversions": [], "lost": lost}, ["N", "M", "O"])
          == ["  settings: Mods\\N: not carried over: z=3 (another)", "  settings: Mods\\M: not carried over: x=1; y=2 (all 2: no setting)"]
          and inst.settings_lines({"conversions": [conv], "lost": lost + [{"mod": "M", "what": "w", "why": "a third"}]}, ["M"])
          == inst.conversion_lines(conv) + ["  settings: Mods\\M: not carried over:", "      x=1; y=2 (all 2: no setting)", "      w (a third)"],
          "the plan's lines about settings: up to six values on the line of the module, more than six one per line; behind a value what was done to it or how it was worked out, "
          "also for a value that is our default already; what is not carried over on one line when there is one reason, one line per reason when there are more")
    if ARGS.fixtures and os.path.isfile(os.path.join(ARGS.fixtures, "EXPModifier", "EXPModifier.ini")):
        e1, u1 = inst.read_ini(read(os.path.join(ARGS.fixtures, "EXPModifier", "EXPModifier.ini")))
        e2, u2 = inst.read_ini(read(os.path.join(ARGS.fixtures, "BetterMining", "BetterMining.ini")))
        e3, u3 = inst.read_ini(read(ARGS.regen_ini)) if ARGS.regen_ini and os.path.isfile(ARGS.regen_ini) else ([("", "RecoveryIndicatorPrefix", ">>", 0)], [])
        check([(k, v) for _, k, v, _ in e1] == [("ExpMultiplier", "4.0"), ("UpdateIntervalMs", "250"), ("ShowBonusMessage", "true"), ("MessageDurationSeconds", "3"), ("Debug", "true")]
              and [(s, k, v) for s, k, v, _ in e2] == [("Settings", "Enabled", "true"), ("Settings", "StrPerOre", "4"), ("Settings", "AgiPerOre", "6"), ("Settings", "PreventExhaustion", "true")]
              and ("", "RecoveryIndicatorPrefix", ">>") in [(s, k, v) for s, k, v, _ in e3] and not u1 and not u2 and not u3,
              "the three real ini files of the PC are read completely: EXPModifier.ini (5 values), BetterMining.ini (4, the commented ones not), G1R_RegenMana.ini (%d)" % len(e3))



# ---------------------------------------------------------------------------------------------
# Part "convert": the five converters, each mapping and each rule, on files written for the case
# ---------------------------------------------------------------------------------------------
GAME_DUMP = r"""
-- The game's numbers as the tests of the module magic model them (dev/tests/magic/game.lua), one line per object.
local Game = dofile(arg[1])
for _, d in ipairs(Game.definitions) do print(("def\t%s\t%s\t%d\t%s"):format(d.name, d.base, #d.steps, d.stagger)) end
for _, c in ipairs(Game.configs) do
    local levels = {}
    for _, l in ipairs(c.levels) do levels[#levels + 1] = ("%s,%s,%s"):format(l[1], l[3], l[2]) end       -- mana, held, time
    print("cfg\t" .. c.name .. "\t" .. table.concat(levels, ";"))
end
for _, e in ipairs(Game.effects) do print("fx\t" .. e.name) end
for _, s in ipairs(Game.skills) do print("skill\t" .. s.name .. "\t" .. s.cost) end
"""


# ---- random settings files for the five mods (part convert): whatever stands in a file, a converter must cope
_FUZZ_NAMES = ["class", "damage", "fields", "spellConfig", "mana", "cast", "configFields", "freezeGE", "reliableFreeze", "enabled", "base", "c2", "c4", "c6", "m_Speed",
               "m_SuperArmorDamageBase", "m_XOffset", "removeConnections", "untrained", "skilled", "master", "debug", "vanillaPrecision", "Spells", "CircleCost", "Enabled",
               "Verbose", "A", "B"]
_FUZZ_WORDS = ["all", "auto", "x", "", "FireBoltProjectileDefinition", "IceBoltProjectileDefinition", "FireRainDefinition", "BallLightningDefinition", "WindFistDefinition",
               "UrizielWaveOfDeathVisualDefinition", "FireBallProjectileDefinition_Lvl2", "ProjectileSpellConfig_FireBall", "FistOfWindSpellConfig", "FireRainSpellConfig",
               "PyrokinesisSpellConfig", "ProjectileSpellConfig_FireBolt", "GE_IceBolt_Damage", "GE_Other", "HealSpellConfig"]
_FUZZ_NUMBERS = ["0", "1", "2", "3", "-1", "0.5", "1.25", "2.5", "100", "1e308", "1e999", "5000", "0.0001", "30", "1600", ".5", "0x10", "7", "99999999999999999999999999"]
_FUZZ_INI = {
    "G1R_RegenMana": ["Enabled", "RegenValueRounding", "RecoveryIndicatorPrefix", "ManaEnabled", "ManaSecondsPerTick", "ManaPerTick", "ManaPercentPerTick", "ManaMaxRegenPercentage",
                      "ManaCooldownAfterCast", "ManaCirclePercentEnabled", "CircleUnskilledPercent", "CircleNovizePercent", "CircleOnePercent", "CircleTwoPercent",
                      "CircleThreePercent", "CircleFourPercent", "CircleFivePercent", "CircleSixPercent", "HealthEnabled", "HealthSecondsPerTick", "HealthPerTick",
                      "HealthPercentPerTick", "HealthMaxRegenPercentage", "HealthCooldownAfterDamage", "ActivateManaRegenRequirements", "ClearZeroManaGate"],
    "BetterMining": ["Enabled", "StrPerOre", "AgiPerOre", "PreventExhaustion"],
}
_FUZZ_INI_VALUES = ["true", "false", "yes", "no", "1", "0", "on", "off", "", "abc", "4", "6", "-3", "0.5", "2.75", "1e308", "1e999", "nan", "0x10", "250", "99999", "100", "110", "120",
                    "75", "1,5", "TRUE", ">>", "99999999999999999999999999"]


def fuzz_value(rng, depth):
    roll = rng.random()
    if roll < 0.32:
        return rng.choice(_FUZZ_NUMBERS)
    if roll < 0.45:
        return rng.choice(["true", "false", "nil"])
    if roll < 0.62:
        return '"%s"' % rng.choice(_FUZZ_WORDS)
    if depth > 3:
        return "{}"
    parts = []
    for _ in range(rng.randint(0, 5)):
        kind = rng.random()
        if kind < 0.55:
            parts.append("%s = %s" % (rng.choice(_FUZZ_NAMES), fuzz_value(rng, depth + 1)))
        elif kind < 0.7:
            parts.append("[%s] = %s" % (rng.choice(["1", "2", "3", "7", "1.5", "-1", '"k"']), fuzz_value(rng, depth + 1)))
        else:
            parts.append(fuzz_value(rng, depth + 1))
    return "{ %s }" % ", ".join(parts)


def fuzz_file(rng, mod):
    """A random settings file for one of the five mods: the names its converter knows, with values of every kind."""
    if mod in _FUZZ_INI:
        lines = []
        for key in _FUZZ_INI[mod]:
            roll = rng.random()
            if roll < 0.88:
                lines.append("%s=%s" % (key if rng.random() < 0.9 else key.upper(), rng.choice(_FUZZ_INI_VALUES)))
            if roll > 0.97:
                lines.append("%s=%s" % (key, rng.choice(_FUZZ_INI_VALUES)))
        if rng.random() < 0.3:
            lines.insert(rng.randint(0, len(lines)), "[%s]" % rng.choice(["Settings", "Other"]))
        if rng.random() < 0.2:
            lines.append(rng.choice(["a line that is nothing", "=x", "; comment"]))
        return rng.choice(["\n", "\r\n"]).join(lines) + "\n"
    if mod == "G1R_WaitOnT":
        lines = ["-- G1R_WaitOnT"]
        for name in ("WAIT_HOURS", "COOLDOWN_SECONDS"):
            if rng.random() < 0.85:
                lines.append("local %s = %s%s" % (name, rng.choice(["0.5", "2", "0", "48", ".25", "5.", "abc", "0.5 * 2", "999999", "9" * 400 + ".5"]), rng.choice(["", " -- note", "  "])))
        for _ in range(rng.randint(0, 2)):
            lines.append(rng.choice(["pcall(RegisterKeyBind, Key.%s, f)", "RegisterKeyBind(Key.%s, f)", "RegisterKeyBind(Key.%s, { ModifierKey.CONTROL }, f)",
                                     "RegisterKeyBind(Key.%s, { ModifierKey.BOGUS, 5 }, f)", "-- RegisterKeyBind(Key.%s, f)"]) % rng.choice(["Y", "T", "F6", "NUM_FIVE", "WEIRD", "y"]))
        return rng.choice(["\n", "\r\n"]).join(lines) + "\n"
    top = ["removeConnections", "debug", "vanillaPrecision"] if mod == "SkillfulLocks" else ["Enabled", "Spells", "Spells", "CircleCost", "Verbose"]
    parts = ["%s = %s" % (name, fuzz_value(rng, 0)) for name in top if rng.random() < 0.85]
    parts += ["%s = %s" % (rng.choice(_FUZZ_NAMES), fuzz_value(rng, 1)) for _ in range(rng.randint(0, 2))]
    rng.shuffle(parts)
    return "return { %s }\n" % ", ".join(parts)


def suite_lines(files, rel, name):
    """The Config lines a module's own suite holds under `local <name> = ...{ "Config.A = 1", ... }`: {key: value text},
    or None when the package has no such suite or no such list."""
    data = files.get(rel)
    m = re.search(rb"local " + name.encode("ascii") + rb" = (?:cfg\()?\{(.*?)\n\s*\}", data or b"", re.S)
    if not m:
        return None
    return dict(re.findall(r'"Config\.([A-Za-z0-9_]+) = ((?:[^"\\]|\\.)*)"', m.group(1).decode("utf-8", "replace")))


def part_convert():
    inst = load_installer()
    files = package_files(*NEW)
    proofs = []                 # (mod, label, the Converted): every file a case wrote, for the two proofs at the end
    table = {e[0]: e[2] for e in inst.TAKEOVERS}
    missing = [m for m in FIVE if config_rel(table[m]) not in files or ("modules/%s/Scripts/schema.lua" % table[m]) not in files]
    if not check(not missing and not any("stand-in" in n for n in NOTES),
                 "the package has the five modules themselves, each with schema.lua and config.lua (no stand-in): regen, wait, mining, locks, magic%s"
                 % ("" if not missing else " - MISSING: " + ", ".join(missing))):
        return
    snap = {mod: snapshot_file(mod) for mod in FIVE}
    if not all(snap.values()):
        NOTES.append("The player's files of 2026-10-01 are not all there (--fixtures, --regen-ini): their conversion is not checked for %s"
                     % ", ".join(m for m in FIVE if not snap[m]))

    def run(mod, their_files, label, player=False):
        c = Converted(inst, files, mod, {rel: (data if isinstance(data, bytes) else data.encode("utf-8")) for rel, data in their_files.items()}, player)
        if c.text is not None:
            proofs.append((mod, label, c))
        return c

    def holds(c, values, text=True):
        """The conversion gives exactly these values ({key: value text}), and the file is the default with them."""
        want = with_values(c.default, values, {"ManaClearBlock": "true"})
        return c.only_module and c.values == values and (not text or (c.text if c.text is not None else c.default) == want)

    def snapshot_case(mod, rel, more=None):
        """The player's file of 2026-10-01: the values of the lead's order, the file, and what the plan says."""
        module, differ, shipped = PLAYER[mod]
        c = run(mod, dict({rel: snap[mod]}, **(more or {})), "The player's file")
        ok = (holds(c, dict(differ, **shipped)) and c.text == player_text(files, mod) and c.text != c.default
              and c.conv["state"] == "write" and c.conv["from"] == {rel: SNAPSHOT[mod][1]} and c.carry["read"][0]["values"] == len(c.carry["read"][0]["asked"])
              and "not looked at by the converter" not in c.plan)
        return c, ok

    # ================= G1R_RegenMana.ini -> regen
    mod, name = "G1R_RegenMana", "G1R_RegenMana.ini"
    if snap[mod]:
        c, ok = snapshot_case(mod, name)
        lines = sorted("Config.%s = %s" % kv for kv in re.findall(r"(?m)^Config\.(\w+) = (.*)$", (c.text or b"").decode("utf-8")))
        check(ok and len(lines) == 22 and set(c.set) == set(PLAYER[mod][1]) and len(c.carry["read"][0]["asked"]) == 34,
              "G1R_RegenMana.ini as on the PC: mana 2 % every 3 s up to 75 % with a pause of 15 s, health +1 and 1 % every 5 s up to 50 % with a pause of 30 s, "
              "the circle numbers 0 / 50 / 100 / +10 - nine lines differ from the shipped file, eleven values are the shipped ones")
        suite = suite_lines(files, "dev/tests/regen/harness.lua", "INSTALLER")
        if suite is None:
            NOTES.append("the package has no dev/tests/regen/harness.lua with the list INSTALLER: the converted regen file is not compared with the module's own suite")
        else:
            check(sorted("Config.%s = %s" % kv for kv in suite.items()) == lines and len(suite) == 22,
                  "and its 22 lines are exactly the lines the module's own suite expects of the installer (INSTALLER in dev/tests/regen/harness.lua)")
        check("carries fractions over to the next step" in c.first("RegenValueRounding") and all("no marker on the bars" in w for n in ("RecoveryIndicatorEnabled", "RecoveryIndicatorPrefix") for w in c.why(n))
              and c.told("RecoveryIndicatorEnabled", "RecoveryIndicatorPrefix")
              and c.told("ActivateManaRegenRequirements", "ManaRegenStacksPerItem", "ManaRegenStackPercentByItemCount", "ManaRegenItemWhitelist", "ActivateHealthRegenRequirements",
                         "HealthRegenStacksPerItem", "HealthRegenStackPercentByItemCount", "HealthRegenItemWhitelist")
              and all("no item requirements" in w for w in c.why("ManaRegenItemWhitelist") + c.why("HealthRegenStacksPerItem")) and len(c.lost) == 11 and c.notes == []
              and "settings: Mods\\G1R_RegenMana -> G1R_MegaMod\\modules\\regen\\Scripts\\config.lua: 9 values\n      ManaPercent = 2.0\n      ManaUpTo = 75\n" in c.plan
              and "ManaClearBlock = true, ShowMessage = false)" in c.plan and "all 8: the module regen has no item requirements" in c.plan,
              "the plan names the eleven values that are not carried over, each with its reason: the rounding step, the marker on the bars (2), the item requirements (8)")
    base = ("Enabled=true\nRegenValueRounding=0.1\nManaEnabled=true\nManaSecondsPerTick=7.5\nManaPerTick=3\nManaPercentPerTick=4.25\nManaMaxRegenPercentage=60\n"
            "ManaCooldownAfterCast=12\nManaCirclePercentEnabled=false\nCircleUnskilledPercent=5\nCircleNovizePercent=55\nCircleOnePercent=90\nCircleTwoPercent=110\n"
            "CircleThreePercent=130\nCircleFourPercent=150\nCircleFivePercent=170\nCircleSixPercent=190\nHealthEnabled=true\nHealthSecondsPerTick=9.5\nHealthPerTick=2\n"
            "HealthPercentPerTick=1.75\nHealthMaxRegenPercentage=40\nHealthCooldownAfterDamage=45\nClearZeroManaGate=true\n")
    all_values = {"Enabled": "true", "ManaEnabled": "true", "ManaSeconds": "7.5", "ManaFlat": "3.0", "ManaPercent": "4.25", "ManaUpTo": "60", "ManaPause": "12",
                  "ManaByCircle": "false", "ManaCircleNone": "5", "ManaCircleNovice": "55", "ManaCircleFirst": "90", "ManaCircleStep": "20", "HealthEnabled": "true",
                  "HealthSeconds": "9.5", "HealthFlat": "2.0", "HealthPercent": "1.75", "HealthUpTo": "40", "HealthPause": "45", "ManaClearBlock": "true",
                  "ShowMessage": "false"}
    c = run(mod, {name: base}, "every number another one")
    check(holds(c, all_values) and c.lost == [("RegenValueRounding=0.1", c.first("RegenValueRounding"))] and c.conv["state"] == "write",
          "every number of G1R_RegenMana.ini changed to one of its own: each lands in its own key of ours - the seven of mana, the three circle numbers, "
          "the step from circle to circle ((190 - 90) / 5 = 20), the five of health - %d values in all" % len(all_values))
    flips = (("Enabled=true\nRegenValueRounding", "Enabled=false\nRegenValueRounding", "Enabled", "false"), ("ManaEnabled=true", "ManaEnabled=no", "ManaEnabled", "false"),
             ("ManaCirclePercentEnabled=false", "ManaCirclePercentEnabled=1", "ManaByCircle", "true"), ("HealthEnabled=true", "HealthEnabled=off", "HealthEnabled", "false"))
    done = [run(mod, {name: base.replace(old, new)}, "switch %s" % key) for old, new, key, value in flips]
    check(all(holds(c, dict(all_values, **{flip[2]: flip[3]})) for c, flip in zip(done, flips)),
          "each of its four switches on its own (false, no, 1, off): only the switch of ours that stands for it changes")
    c = run(mod, {name: base.replace("ClearZeroManaGate=true", "ClearZeroManaGate=false")}, "the casting block stays")
    check(holds(c, dict(all_values, ManaClearBlock="false")) and c.text.endswith(b"Config.LogSteps = false\nConfig.ManaClearBlock = false\n\nreturn Config\n")
          and c.set.get("ManaClearBlock") == "false" and "ManaClearBlock" not in run(mod, {name: base}, "the casting block is cleared").set,
          "ClearZeroManaGate=false becomes a line of its own for the setting ManaClearBlock, which the shipped file does not show; with true (the default of that setting) no line is added")
    c = run(mod, {name: base.replace("ManaSecondsPerTick=7.5", "ManaSecondsPerTick=0.1").replace("ManaPercentPerTick=4.25", "ManaPercentPerTick=250")
                  .replace("HealthCooldownAfterDamage=45", "HealthCooldownAfterDamage=99999").replace("ManaMaxRegenPercentage=60", "ManaMaxRegenPercentage=72.5")
                  .replace("CircleSixPercent=190", "CircleSixPercent=40").replace("HealthMaxRegenPercentage=40", "HealthMaxRegenPercentage=140")},
            "numbers outside our ranges")
    check(holds(c, dict(all_values, ManaSeconds="0.5", ManaPercent="100.0", HealthPause="3600", ManaUpTo="73", ManaCircleStep="0", HealthUpTo="100"))
          and "ManaSeconds = 0.5 (was 0.1; the range is 0.5 to 600)" in c.plan and "ManaPercent = 100.0 (was 250; the range is 0 to 100)" in c.plan
          and "HealthPause = 3600 (was 99999; the range is 0 to 3600)" in c.plan and "ManaUpTo = 73 (was 72.5; rounded)" in c.plan
          and "ManaCircleStep = 0 (was -10; the range is 0 to 500)" in c.plan and "HealthUpTo = 100 (was 140; the range is 0 to 100)" in c.plan,
          "numbers outside our ranges are pulled inside, a fraction where we keep whole numbers is rounded - each said in the plan, also where the result is the shipped value")
    c = run(mod, {name: base.replace("CircleThreePercent=130", "CircleThreePercent=145")}, "an uneven circle table, same ends")
    d = run(mod, {name: base.replace("CircleOnePercent=90", "CircleOnePercent=100").replace("CircleTwoPercent=110", "CircleTwoPercent=105").replace("CircleThreePercent=130", "CircleThreePercent=120")
                  .replace("CircleFourPercent=150", "CircleFourPercent=130").replace("CircleFivePercent=170", "CircleFivePercent=135").replace("CircleSixPercent=190", "CircleSixPercent=138")},
            "an uneven circle table")
    e = run(mod, {name: base.replace("CircleTwoPercent=110", "CircleTwoPercent=92.5").replace("CircleThreePercent=130", "CircleThreePercent=95").replace("CircleFourPercent=150", "CircleFourPercent=97.5")
                  .replace("CircleFivePercent=170", "CircleFivePercent=100").replace("CircleSixPercent=190", "CircleSixPercent=102.5")}, "a circle table in half steps")
    check(holds(c, all_values) and c.why("the uneven rise of CircleTwoPercent .. CircleSixPercent (110, 145, 150, 170, 190)")
          == ["our module has one step for every further circle: ManaCircleStep = 20 gives 110, 130, 150, 170, 190"]
          and holds(d, dict(all_values, ManaCircleFirst="100", ManaCircleStep="8")) and "(105, 120, 130, 135, 138) (our module has one step for every further circle: ManaCircleStep = 8 gives 108, 116, 124, 132, 140)" in d.plan
          and holds(e, dict(all_values, ManaCircleStep="3")) and "ManaCircleStep = 3 (was 2.5; rounded)" in e.plan and not [w for w, _ in e.lost if "uneven" in w]
          and not [w for w, _ in run(mod, {name: base}, "an even circle table").lost if "uneven" in w],
          "a circle table that does not rise evenly: the nearest whole step between the first and the sixth circle is taken, and the plan says that the table was uneven "
          "and what our one step gives instead; an even table says nothing of the kind")
    c = run(mod, {name: base.replace("ManaPercentPerTick=4.25", "ManaPercentPerTick=two").replace("ManaEnabled=true", "ManaEnabled=maybe").replace("HealthPerTick=2\n", "")
                  .replace("CircleThreePercent=130\n", "") + "this line is nothing\n"}, "a broken file")
    left = {k: v for k, v in all_values.items() if k not in ("ManaPercent", "ManaEnabled", "HealthFlat", "ManaCircleStep")}
    check(holds(c, left) and c.why("ManaPercentPerTick") == ["is not a number"] and c.why("ManaEnabled") == ["is not true or false"] and c.why("HealthPerTick") == ["is not in G1R_RegenMana.ini"]
          and c.why("CircleThreePercent") == ["is not in G1R_RegenMana.ini"] and [w for t, w in c.lost if t.endswith("(this line is nothing)")] == ["is not a key=value line"]
          and all(c.why(n) == ["the step from circle to circle takes all six numbers of the table: not carried over"] for n in ("CircleTwoPercent", "CircleFourPercent", "CircleFivePercent", "CircleSixPercent")),
          "a broken G1R_RegenMana.ini: what can be read is carried over; a word for a number, a switch that is neither on nor off, a missing key, a line without = are each named "
          "with the reason, and without all six circle numbers the step is left as shipped")
    done = [run(mod, {name: b"\x00\x01\x02\xff" * 30}, "binary"), run(mod, {name: b"just words\nand more words\n"}, "no key=value"), run(mod, {"dlls/main.dll": b"MZ"}, "no file")]
    check([c.lost for c in done] == [[(name, "is not a text file")], [(name, "has no key=value line")], [(name, "not found")]]
          and all(c.conv is None and c.text is None and not c.carry["conversions"] for c in done),
          "a G1R_RegenMana.ini that is no text, has no key=value line, or is not there: nothing is carried over - not even the fixed ShowMessage - and the plan says which of the three it is")
    c = run(mod, {name: base + "ActivateManaRegenRequirements=true\nManaRegenItemWhitelist=_Magic_\nActivateHealthRegenRequirements=yes\n"}, "item requirements switched on")
    check(holds(c, all_values) and len(c.notes) == 2 and "let mana regenerate only with certain items equipped (ActivateManaRegenRequirements=true): the module regen has NO item requirements - "
          "mana will regenerate whatever the hero wears" in c.notes[0] and "let health regenerate only with certain items equipped (ActivateHealthRegenRequirements=yes)" in c.notes[1]
          and c.told("ActivateManaRegenRequirements", "ManaRegenItemWhitelist", "ActivateHealthRegenRequirements") and "  note: G1R_RegenMana let mana regenerate only" in c.plan
          and run(mod, {name: base + "ActivateManaRegenRequirements=false\n"}, "item requirements off").notes == [],
          "item requirements that are switched on in G1R_RegenMana.ini: the plan says in a note of its own, for mana and for health, that our module has none and regeneration "
          "will not depend on what the hero wears")
    c = run(mod, {name: base}, "our file is the player's", player=True)
    check(c.conv["state"] == "player" and c.text is None and c.carry["texts"] == {}
          and ("config.lua: NOT written, the file was changed by the player; it would get 14 values:\n      ManaSeconds = 7.5\n      ManaFlat = 3.0\n      ManaPercent = 4.25\n") in c.plan
          and "(our default already" not in c.plan and len(c.set) == 14,
          "a regen config.lua the player already changed is not written: the plan says so and lists the values it would have got")

    # ================= G1R_WaitOnT (its Scripts\main.lua) -> wait
    mod, name = "G1R_WaitOnT", "Scripts/main.lua"
    script = ("-- G1R_WaitOnT 1.0.0. Y advances 30 in-game minutes.\nlocal TAG = \"[G1R_WaitOnT] \"\nlocal WAIT_HOURS = 0.5\nlocal COOLDOWN_SECONDS = 2\n"
              "local function on_y_pressed() end\nif type(RegisterKeyBind) ~= \"function\" or not Key.Y then return end\n"
              "local ok, err = pcall(RegisterKeyBind, Key.Y, on_y_pressed)\n")
    if snap[mod]:
        c, ok = snapshot_case(mod, name, {"enabled.txt": b""})
        check(ok and c.set == {"ShortKey": '"Y"'} and c.notes == [] and len(c.lost) == 2 and c.told("the text and the place of its note", "it skipped time whenever a game was loaded and not paused")
              and c.plan.startswith("  settings: Mods\\G1R_WaitOnT -> G1R_MegaMod\\modules\\wait\\Scripts\\config.lua: ShortKey = \"Y\" "
                                    "(our default already: ShortMinutes = 30 (its WAIT_HOURS = 0.5), Cooldown = 2.0, ShowMessage = true)\n")
              and inst.waitont_built_in(snap[mod]) == (inst.WAITONT_KNOWN, []),
              "G1R_WaitOnT as on the PC: its key Y becomes the key of our short wait; its 30 minutes, its 2 seconds between two skips and its note are what our module ships with, "
              "and the plan says so; all three were read from its main.lua, which is named as the source")
    c = run(mod, {name: script}, "a main.lua written for the test")
    check(holds(c, dict(PLAYER[mod][1], **PLAYER[mod][2])) and c.notes == [], "a main.lua of the same form written for the test gives the same")
    c = run(mod, {name: script.replace("WAIT_HOURS = 0.5", "WAIT_HOURS = 1.5").replace("COOLDOWN_SECONDS = 2", "COOLDOWN_SECONDS = 5").replace("Key.Y, on_y", "Key.T, on_y")}, "other built-in values")
    check(holds(c, {"ShortKey": '"T"', "ShortMinutes": "90", "Cooldown": "5.0", "ShowMessage": "true"}) and "ShortMinutes = 90 (its WAIT_HOURS = 1.5)" in c.plan and c.notes == [],
          "a main.lua somebody changed (another key, 1.5 hours, 5 seconds): the three values are read from the file as it is - T, 90 minutes, 5 seconds")
    d = run(mod, {"scripts/main.lua": script.replace("pcall(RegisterKeyBind, Key.Y, on_y_pressed)", "RegisterKeyBind(Key.F6, { ModifierKey.CONTROL, ModifierKey.SHIFT }, on_y_pressed)")}, "a key with CTRL and SHIFT")
    check(holds(d, {"ShortKey": '"CTRL+SHIFT+F6"', "ShortMinutes": "30", "Cooldown": "2.0", "ShowMessage": "true"}) and 'ShortKey = "CTRL+SHIFT+F6" (was written CONTROL+SHIFT+F6)' in d.plan
          and d.conv["from"] == {"scripts/main.lua": sha_of(script.replace("pcall(RegisterKeyBind, Key.Y, on_y_pressed)", "RegisterKeyBind(Key.F6, { ModifierKey.CONTROL, ModifierKey.SHIFT }, on_y_pressed)").encode())},
          "a key registered with modifier keys, in a folder spelt scripts: read as CTRL+SHIFT+F6")
    c = run(mod, {name: script.replace("WAIT_HOURS = 0.5", "WAIT_HOURS = 48").replace("COOLDOWN_SECONDS = 2", "COOLDOWN_SECONDS = 120")}, "values outside our ranges")
    check(holds(c, {"ShortKey": '"Y"', "ShortMinutes": "1440", "Cooldown": "60.0", "ShowMessage": "true"})
          and "ShortMinutes = 1440 (its WAIT_HOURS = 48; was 2880; the range is 1 to 1440)" in c.plan and "Cooldown = 60.0 (was 120; the range is 0 to 60)" in c.plan,
          "48 hours and 120 seconds are pulled into our ranges (1440 minutes, 60 seconds), said in the plan")
    cases = (("-- G1R_WaitOnT\n", "its key, WAIT_HOURS, COOLDOWN_SECONDS", "key = Y, WAIT_HOURS = 0.5, COOLDOWN_SECONDS = 2"),
             (script.replace("WAIT_HOURS = 0.5", "WAIT_HOURS = 0.25 * 2"), "WAIT_HOURS", "WAIT_HOURS = 0.5"),
             (script + "pcall(RegisterKeyBind, Key.T, on_y_pressed)\n", "its key", "key = Y"),
             (script.replace("local COOLDOWN_SECONDS = 2\n", "-- local COOLDOWN_SECONDS = 9\n"), "COOLDOWN_SECONDS", "COOLDOWN_SECONDS = 2"))
    done = [run(mod, {name: text}, "not the known form: %s" % what) for text, what, _ in cases]
    check(all(holds(c, dict(PLAYER[mod][1], **PLAYER[mod][2])) and c.notes == ["G1R_WaitOnT\\Scripts\\main.lua does not name %s in the form known from version 1.0.0: taken as that version has it (%s)" % (what, taken)]
              for c, (_, what, taken) in zip(done, cases)),
          "a main.lua that does not show a value in the known form (no such line, a calculation, two keys, a line that is a comment): that value is taken as version 1.0.0 "
          "has it - Y, 0.5 hours, 2 seconds - and a note in the plan names it")
    done = [run(mod, {name: script.replace("WAIT_HOURS = 0.5\n", "WAIT_HOURS = 0.75 -- three quarters of an hour\n") + "-- pcall(RegisterKeyBind, Key.T, on_y_pressed)\n"}, "comments"),
            run(mod, {name: script.replace("WAIT_HOURS = 0.5", "WAIT_HOURS = 0.75").replace("\n", "\r\n")}, "CRLF line ends")]
    check(all(holds(c, {"ShortKey": '"Y"', "ShortMinutes": "45", "Cooldown": "2.0", "ShowMessage": "true"}) and c.notes == [] for c in done),
          "a comment behind a value, a key registration that is commented out, CRLF line ends: the values are read all the same (45 minutes, key Y), no note")
    c = run(mod, {"enabled.txt": b""}, "no main.lua")
    d = run(mod, {name: script.replace("Key.Y, on_y", "Key.WEIRD, on_y")}, "a key our module does not know")
    check(holds(c, dict(PLAYER[mod][1], **PLAYER[mod][2])) and len(c.notes) == 1 and c.conv["from"] == {}
          and d.values == {"ShortMinutes": "30", "Cooldown": "2.0", "ShowMessage": "true"} and d.text is None and d.why("wait.ShortKey") == ["names no key"],
          "without a main.lua the three known values are taken (a note says so); a key that is none our module knows is not carried over, with the reason")
    c = run(mod, {name: script}, "our file is the player's", player=True)
    check(c.conv["state"] == "player" and c.text is None and "config.lua: NOT written, the file was changed by the player (it would get: ShortKey = \"Y\")" in c.plan,
          "a wait config.lua the player already changed is not written; the plan says what it would have got")

    # ================= BetterMining.ini -> mining
    mod, name = "BetterMining", "BetterMining.ini"
    ini = "; BetterMining\n[Settings]\nEnabled=true\nStrPerOre=4\nAgiPerOre=6\nPreventExhaustion=true\n;StrPerOre=1\n"
    formula = {"Enabled": "true", "YieldEnabled": "true", "BaseAmount": "0", "StrengthPerOre": "4.0", "DexterityPerOre": "6.0", "MinAmount": "0", "LowVeinRule": "false",
               "EndlessVeins": "true", "ShowMessage": "false"}
    plain = {"Enabled": "true", "EndlessVeins": "true", "ShowMessage": "false"}
    if snap[mod]:
        c, ok = snapshot_case(mod, name)
        check(ok and set(c.set) == set(PLAYER[mod][1]) and c.lost == [] and c.notes == []
              and "config.lua: 8 values\n      YieldEnabled = true (its formula: Strength / StrPerOre + Dexterity / AgiPerOre, each rounded down - no base amount, no least amount, "
                  "the same for a nearly empty vein)\n      BaseAmount = 0\n      StrengthPerOre = 4.0\n      DexterityPerOre = 6.0\n      MinAmount = 0\n      LowVeinRule = false\n"
                  "      EndlessVeins = true\n      ShowMessage = false (BetterMining showed no notes)\n      (our default already: Enabled = true)" in c.plan,
              "BetterMining.ini as on the PC: its formula in our terms (no base amount, one ore per 4 Strength and per 6 Dexterity, no least amount, the same for a nearly empty vein), "
              "veins that never run out, and no notes on screen - eight lines; nothing is left over")
    c = run(mod, {name: ini}, "the same values, written for the test")
    check(holds(c, formula) and c.lost == [], "a BetterMining.ini with the same values written for the test gives the same")
    c = run(mod, {name: ini.replace("StrPerOre=4", "StrPerOre=2.5").replace("AgiPerOre=6", "AgiPerOre=7").replace("PreventExhaustion=true", "PreventExhaustion=false")}, "other values")
    d = run(mod, {name: "Enabled=1\nStrPerOre=3\n[Other]\nAgiPerOre=9\nPreventExhaustion=on\n"}, "1 and on, keys in any section")
    check(holds(c, dict(formula, StrengthPerOre="2.5", DexterityPerOre="7.0", EndlessVeins="false")) and "EndlessVeins" not in c.set
          and holds(d, dict(formula, StrengthPerOre="3.0", DexterityPerOre="9.0")),
          "changed values: StrPerOre goes to StrengthPerOre and AgiPerOre to DexterityPerOre (2.5 and 7), PreventExhaustion=false leaves the veins as the game has them; "
          "1 / on count as true and the keys are found in whatever section they stand, as that mod reads them")
    c = run(mod, {name: ini.replace("Enabled=true", "Enabled=false")}, "switched off in its own file")
    check(holds(c, {"Enabled": "false"}) and c.set == {"Enabled": "false"} and c.told("Settings.StrPerOre", "Settings.AgiPerOre", "Settings.PreventExhaustion")
          and all("switched off in its own file (Enabled=false)" in w for _, w in c.lost) and len(c.lost) == 3,
          "Enabled=false in BetterMining.ini: our module is switched off and nothing else is written - not its formula, not the veins, not ShowMessage; the plan says why")
    c = run(mod, {name: ini.replace("StrPerOre=4", "StrPerOre=250").replace("AgiPerOre=6", "AgiPerOre=6.26")}, "values outside our range")
    check(holds(c, dict(formula, StrengthPerOre="200.0", DexterityPerOre="6.3")) and "StrengthPerOre = 200.0 (was 250; the range is 0 to 200)" in c.plan
          and "DexterityPerOre = 6.3 (was 6.26; rounded)" in c.plan,
          "250 points per ore are pulled to our 200, 6.26 is rounded to one place - both said in the plan")
    done = [run(mod, {name: ini.replace("StrPerOre=4", "StrPerOre=" + bad)}, "StrPerOre=%s" % bad) for bad in ("0", "-4", "abc")]
    d = run(mod, {name: ini.replace("AgiPerOre=6\n", "")}, "no AgiPerOre")
    check(all(holds(c, plain) and c.why("its formula for the ore of a swing") and c.why("Settings.AgiPerOre") == ["not carried over without the other number of the formula"] for c in done)
          and "must be above 0: BetterMining divides by it" in done[0].first("Settings.StrPerOre") and "must be above 0" in done[1].first("Settings.StrPerOre")
          and done[2].why("StrPerOre") == ["is not a number"]
          and holds(d, plain) and d.why("AgiPerOre") == ["is not in BetterMining.ini"] and d.why("Settings.StrPerOre") == ["not carried over without the other number of the formula"]
          and "YieldEnabled" not in d.values,
          "the formula is carried over as a whole or not at all: with StrPerOre at 0, below 0, a word, or AgiPerOre missing, the ore of a swing stays as the game has it "
          "(the plan names the number and says so); the veins and the notes are carried over all the same")
    done = [run(mod, {"scripts/BetterMining.ini": ini.replace("StrPerOre=4", "StrPerOre=8")}, "the file inside the scripts folder"),
            run(mod, {"scripts/BetterMining.ini": ini.replace("StrPerOre=4", "StrPerOre=8"), name: ini}, "a file in both places")]
    check(holds(done[0], dict(formula, StrengthPerOre="8.0")) and done[0].conv["from"] == {"scripts/BetterMining.ini": sha_of(ini.replace("StrPerOre=4", "StrPerOre=8").encode())}
          and holds(done[1], formula) and done[1].conv["from"] == {name: sha_of(ini.encode())},
          "BetterMining.ini is taken from the mod's folder, and from its scripts folder when it is only there - the order in which that mod looks for it")
    c = run(mod, {name: ini.replace("PreventExhaustion=true", "PreventExhaustion=maybe").replace("Enabled=true", "Enabled=perhaps")}, "switches that are neither on nor off")
    check(holds(c, {k: v for k, v in formula.items() if k not in ("Enabled", "EndlessVeins")}) and c.why("PreventExhaustion") == ["is not true or false"] and c.why("Enabled") == ["is not true or false"],
          "a switch of BetterMining.ini that is neither on nor off is named and not carried over; the rest is")
    done = [run(mod, {name: b"\xff\x00" * 40}, "binary"), run(mod, {name: b"; only comments\n\n"}, "no key=value"), run(mod, {"scripts/main.lua": b"--\n"}, "no file")]
    check([c.lost for c in done] == [[(name, "is not a text file")], [(name, "has no key=value line")], [(name, "not found")]] and all(c.conv is None and c.text is None for c in done),
          "a BetterMining.ini that is no text, has no key=value line, or is not there: nothing is carried over, said in the plan")
    c = run(mod, {name: ini}, "our file is the player's", player=True)
    check(c.conv["state"] == "player" and c.text is None and "NOT written, the file was changed by the player; it would get 8 values:\n      YieldEnabled = true" in c.plan,
          "a mining config.lua the player already changed is not written; the plan lists what it would have got")

    # ================= SkillfulLocks\Scripts\config.lua -> locks
    mod, name = "SkillfulLocks", "Scripts/config.lua"
    game = '"as the game has it"'

    def locks(untrained, skilled, master, debug="false", more=""):
        return "return {\n    removeConnections = { untrained = %s, skilled = %s, master = %s },\n    vanillaPrecision = { untrained = 0, skilled = 1, master = 2 },\n    debug = %s,%s\n}\n" \
            % (untrained, skilled, master, debug, more)

    def locks_values(untrained, skilled, master, log="false"):
        return {"UntrainedConnections": untrained, "SkilledConnections": skilled, "MasterConnections": master, "LogLocks": log}
    if snap[mod]:
        c, ok = snapshot_case(mod, name)
        check(ok and c.set == PLAYER[mod][1] and len(c.lost) == 3 and c.told("vanillaPrecision.untrained", "vanillaPrecision.skilled", "vanillaPrecision.master")
              and all("the game's own numbers for the three skill levels are built into the module locks" == w for _, w in c.lost)
              and "config.lua: SkilledConnections = \"safe\" (their \"auto\"), MasterConnections = \"all\", LogLocks = true (our default already: UntrainedConnections = \"as the game has it\")" in c.plan,
              "SkillfulLocks' config.lua as on the PC: untrained as the game has it, skilled \"safe\" (their \"auto\"), master all, one log line per lock; "
              "the three vanillaPrecision numbers are not carried over (ours are built in)")
    grid = (("false", "0", "1", locks_values(game, '"none"', '"1"')), ("2", '"auto"', '"all"', locks_values('"2"', '"safe"', '"all"')),
            ('"all"', "false", "2.0", locks_values('"all"', game, '"2"')), ('"auto"', "1.0", "0", locks_values('"safe"', '"1"', '"none"')),
            ("1", '"all"', "false", locks_values('"1"', '"all"', game)))
    done = [run(mod, {name: locks(u, s, m)}, "levels %s / %s / %s" % (u, s, m)) for u, s, m, _ in grid]
    check(all(holds(c, want) and len(c.lost) == 3 and c.notes == [] for c, (_, _, _, want) in zip(done, grid)),
          "every level with every kind of value: false -> as the game has it, 0 -> none, 1 -> 1, 2 -> 2, \"auto\" -> safe, \"all\" -> all, each level to its own key (15 values in 5 files)")
    c = run(mod, {name: locks("3", "-1", "99", "true")}, "numbers outside 0 to 2")
    check(holds(c, locks_values('"safe"', '"none"', '"safe"', "true"))
          and 'UntrainedConnections = "safe" (was 3: our module offers no fixed number above 2; their mod capped such a number per lock at what is proven solvable, which is what "safe" does)' in c.plan
          and 'SkilledConnections = "none" (was -1: their mod takes a negative number as 0)' in c.plan and 'MasterConnections = "safe" (was 99: our module offers no fixed number above 2' in c.plan,
          "a number above 2 becomes \"safe\" and the plan says that our module offers no fixed number above 2; a negative number is 0 there and \"none\" here")
    c = run(mod, {name: locks("1.5", "true", '"most"')}, "values their mod takes as: leave the lock alone")
    d = run(mod, {name: "return { removeConnections = { untrained = { 1 }, master = 2, expert = 3 }, debug = false }\n"}, "a table, a missing level, a fourth level")
    check(holds(c, {"LogLocks": "false"}) and c.text is None and c.why("removeConnections.untrained") == ["is not a whole number of connections: not carried over"]
          and all("is none of false, a number, \"all\", \"auto\"" in w for w in c.why("removeConnections.skilled") + c.why("removeConnections.master")) and len(c.lost) == 6
          and holds(d, {"MasterConnections": '"2"', "LogLocks": "false"}) and "is not in Scripts\\config.lua: their mod leaves such a level as the game has it" in d.first("removeConnections.skilled")
          and ("removeConnections.untrained (a table)", d.first("removeConnections.untrained")) in d.lost and "is none of false, a number" in d.first("removeConnections.untrained")
          and d.why("removeConnections.expert") == ["is not one of the three skill levels untrained, skilled, master"],
          "what SkillfulLocks itself takes as \"leave the lock alone\" - half a connection, true, a word it does not know, a missing level - is not carried over and named "
          "(our default is the same); a level it does not have is named too")
    legacy = "return {\n    leaveSkilled = 2,\n    leaveConnections = 1,\n    debug = true,\n}\n"
    c = run(mod, {name: legacy}, "a settings file of version 1.0")
    d = run(mod, {name: "return { removeConnections = 2, debug = false }\n"}, "one number for all levels")
    check(holds(c, {"LogLocks": "true"}) and "the mod itself then takes untrained as the game has it, skilled \"auto\", master \"all\"; nothing of it is carried over" in c.first("removeConnections")
          and c.why("leaveSkilled") == ["not looked at by the converter"] and c.why("leaveConnections") == ["not looked at by the converter"]
          and holds(d, {"LogLocks": "false"}) and d.why("removeConnections") and d.text is None,
          "a file without the table of the three levels (version 1.0, or one number for all): none of the levels is carried over, and the plan says what that mod does with such a file")
    c = run(mod, {name: locks("false", "false", "false", "1")}, "debug = 1")
    d = run(mod, {name: locks("false", "false", "false", "false").replace("debug = false", "Debug = true")}, "Debug with a capital D")
    check(holds(c, locks_values(game, game, game, "true")) and "LogLocks = true (was 1: anything but false counts as true there)" in c.plan
          and holds(d, {k: v for k, v in locks_values(game, game, game).items() if k != "LogLocks"}) and d.why("debug") == ["is not in Scripts\\config.lua"]
          and d.why("Debug") == ["not looked at by the converter"],
          "debug = 1 counts as true (as in Lua); Debug with a capital letter is not the mod's setting: names are read as written, and the plan lists it as not looked at")
    done = [run(mod, {name: "return { removeConnections = levels() }\n"}, "a call"), run(mod, {name: "return {\n    removeConnections = {\n"}, "cut off"),
            run(mod, {name: b"\x00\x01\x02"}, "binary"), run(mod, {"Scripts/main.lua": b"--\n"}, "no file")]
    check(all(c.conv is None and c.text is None and len(c.lost) == 1 for c in done) and all("could not be read as plain values" in c.lost[0][1] for c in done[:3])
          and done[3].lost == [("Scripts\\config.lua", "not found")],
          "a config.lua of SkillfulLocks that is more than plain values, is cut off, is no text, or is not there: nothing is carried over (and nothing of it is run), said in the plan")
    c = run(mod, {name: locks("false", '"auto"', '"all"', "true")}, "our file is the player's", player=True)
    check(c.conv["state"] == "player" and c.text is None
          and 'NOT written, the file was changed by the player (it would get: SkilledConnections = "safe" (their "auto"), MasterConnections = "all", LogLocks = true)' in c.plan,
          "a locks config.lua the player already changed is not written; the plan says what it would have got")

    # ================= G1R_MageBalance\Scripts\config.lua -> magic
    mod, name = "G1R_MageBalance", "Scripts/config.lua"
    spells = inst.MAGIC_SPELLS

    def magic(blocks, more="", enabled="Enabled = true,"):
        return "return {\n    ModName = \"G1R Mage Balance\", Version = \"0.9.0\", %s\n    Spells = {\n%s    },\n%s}\n" % (enabled, "".join("        %s,\n" % b for b in blocks), more)

    def got(c, **values):
        """The conversion gives these values besides Enabled = true (and nothing else)."""
        return holds(c, dict({"Enabled": "true"}, **values))
    if snap[mod]:
        c, ok = snapshot_case(mod, name)
        check(ok and c.set == PLAYER[mod][1] and len(c.set) == 37 and c.notes == [] and len(c.carry["read"][0]["asked"]) == 77,
              "G1R_MageBalance's config.lua as on the PC: 37 lines differ from the shipped file - the two bolts by the caster's circle, damage, mana and casting time of twelve more "
              "spells, the ball lightning's speed, the fist of wind's force, the ice block that always freezes, five circle prices, and WholeMana = false for his fractional mana costs")
        suite = suite_lines(files, "dev/tests/magic/harness.lua", "PLAYER")
        if suite is None:
            NOTES.append("the package has no dev/tests/magic/harness.lua with the list PLAYER: the converted magic file is not compared with the module's own suite")
        else:
            check(suite == c.set and len(suite) == 37, "and these 37 lines are exactly the configuration the module's own suite runs as the player's (PLAYER in dev/tests/magic/harness.lua)")
        check(c.why("Spells.Feuerregen.fields.m_XOffset") and "the game's scripts do not read this number" in c.first("Spells.Feuerregen.fields.m_YOffset")
              and "which the rune does not use" in c.first("Spells.Kugelblitz.fields.m_Speed for BallLightningDefinition_Base")
              and "our module sets it in the ice counter only" in c.first("Spells.Eisblock.reliableFreeze for hits on a foe that is frozen already")
              and c.told("ModName", "Version", "Verbose", "DebugSteps") and len(c.lost) == 8
              and "      UrizielDamage = 2.778 (their 250; the game has 90)\n" in c.plan and "      FireRainMana = 1.5 (their 30; the game has 20)\n" in c.plan
              and "      BreathOfDeathCastTime = 0.5 (their 0.25 s; the game has 0.5 s)\n" in c.plan and "      WindFistStagger = 5.0 (their 1000; the game has 200)\n" in c.plan
              and "      WholeMana = false (their mod writes the exact product: 2 x 1.25 = 2.5)\n" in c.plan and "BreathOfDeathMana = 1.0 (their 15; the game has 15)" in c.plan,
              "the plan names the three things our module does not do as that mod did - the rain of fire's two offsets, the speed of the ball lightning definition no rune uses, "
              "the freeze flag in the list of hits on a frozen foe - and says for every number worked out from his how (his number, the game's)")
    # every spell by its three multipliers
    blocks, want = [], {}
    for i, spell in enumerate(spells):
        damage, mana, cast = round(1.1 + i * 0.05, 2), round(0.5 + i * 0.05, 2), round(2.0 + i * 0.1, 1)
        blocks.append('S%d = { class = "%s", damage = %s, spellConfig = "%s", mana = %s, cast = %s }' % (i, spell["class"], damage, spell["config"], mana, cast))
        want[spell["key"] + "Damage"] = inst.number_text(damage, 3)
        want[spell["key"] + "Mana"] = inst.number_text(mana, 3)
        if any(level[2] for level in spell["levels"]):
            want[spell["key"] + "CastTime"] = inst.number_text(cast, 3)
    c = run(mod, {name: magic(blocks)}, "every spell by three multipliers")
    check(got(c, WholeMana="false", **want) and len(want) == 44 and c.why("Spells.S12.cast") == ["the game's casting time of this spell is 0: there is nothing to change, and our module has no setting for it"]
          and len(c.lost) == 3 and len(spells) == 15,
          "a block for each of the fifteen spells with a multiplier for damage, mana and casting time: each of the 44 lands in the setting of its own spell "
          "(the fist of wind has no casting time in the game: named, not carried over)")
    # every number of the game's the table holds: absolute values per spell
    blocks, want, lost = [], {}, 0
    for i, spell in enumerate(spells):
        levels = spell["levels"]
        mana = ", ".join(inst.short_number(level[0] * 1.5) for level in levels)
        cast = ", ".join(inst.short_number(level[2] * 0.5) for level in levels)
        parts = ['class = "%s"' % spell["class"], 'spellConfig = "%s"' % spell["config"], "mana = { %s }" % mana]
        want[spell["key"] + "Mana"] = "1.5"
        if any(level[2] for level in levels):
            parts.append("cast = { %s }" % cast)
            want[spell["key"] + "CastTime"] = "0.5"
        if spell.get("damage"):
            parts.append("damage = { base = %s }" % inst.short_number(spell["damage"] * 3))
            want[spell["key"] + "Damage"] = "3.0"
        if spell.get("stagger"):
            parts.append("fields = { m_SuperArmorDamageBase = %s }" % inst.short_number(spell["stagger"] * 2.5))
            want[spell["key"] + "Stagger"] = "2.5"
        blocks.append("S%d = { %s }" % (i, ", ".join(parts)))
    c = run(mod, {name: magic(blocks)}, "every spell by absolute numbers")
    check(got(c, WholeMana="false", **want) and len(want) == 15 + 14 + 4 + 1 and [w for w, _ in c.lost] == ['ModName="G1R Mage Balance"', 'Version="0.9.0"']
          and "PyrokinesisMana = 1.5 (their 7.5; the game has 5; their mod also set the cost of each further shot or second to 7.5, here it follows the multiplier: 1.5)" in c.plan
          and "FireBallMana = 1.5 (their 1.5 / 3 / 3; the game has 1 / 2 / 2)" in c.plan and "BallLightningCastTime = 0.5 (their 0.15 / 0.515 / 0.515 / 0.515 s; the game has 0.3 / 1.03 / 1.03 / 1.03 s)" in c.plan
          and "FireBoltMana = 1.5 (their 1.5; the game has 1)\n" in c.plan,
          "absolute numbers for every spell - mana and casting time per charge level, the damage of the four spells with one damage number, the fist of wind's force - at 1.5, 0.5, "
          "3 and 2.5 times the game's: every one comes out as that multiplier (34 values, so the table of the game's numbers in the installer is the game's); where their mod "
          "also set the cost per further shot or second to the same number, the plan says that ours follows the multiplier")
    dump = None
    if LUA and "dev/tests/magic/game.lua" in files:
        write(os.path.join(WORK, "game.lua"), files["dev/tests/magic/game.lua"])
        write(os.path.join(WORK, "game_dump.lua"), GAME_DUMP)
        p = subprocess.run([LUA, os.path.join(WORK, "game_dump.lua"), os.path.join(WORK, "game.lua")], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        dump = [line.split("\t") for line in p.stdout.decode("utf-8", "replace").splitlines()] if p.returncode == 0 else None
    if dump is None:
        NOTES.append("no Lua or no dev/tests/magic/game.lua in the package: the installer's table of the game's spell numbers is not compared with the module's model")
    else:
        defs = {d[1]: (float(d[2]), int(d[3]), float(d[4])) for d in dump if d[0] == "def"}
        configs = {d[1]: tuple(tuple(float(x) for x in level.split(",")) for level in d[2].split(";")) for d in dump if d[0] == "cfg"}
        effects = [d[1] for d in dump if d[0] == "fx"]
        skills = [d[1] for d in dump if d[0] == "skill"]
        wrong, claimed = [], []
        for spell in spells:
            mine = [n for n in defs if n == spell["class"] or n in [spell["class"] + suffix for suffix in inst.MAGIC_VARIANTS]]
            claimed += mine
            one = len(mine) == 1 and defs[mine[0]][1] == 0
            if (not mine or configs.get(spell["config"]) != tuple(tuple(float(x) for x in level) for level in spell["levels"])
                    or (spell.get("damage") is not None) != (one and not spell.get("steps")) or (one and spell.get("damage") != defs[mine[0]][0])
                    or (spell.get("stagger") and defs[mine[0]][2] != spell["stagger"]) or (spell.get("freeze") and spell["freeze"] not in effects)
                    or (spell.get("steps") and (len(mine) != 1 or defs[mine[0]][1] != 3))):
                wrong.append(spell["key"])
        items, _ = inst.module_schema(files, "magic")
        keys = ["Enabled", "WholeMana", "BallLightningSpeed", "CircleCosts"] + ["CircleCost%d" % n for n in range(1, 7)]
        for spell in spells:
            keys += [spell["key"] + "Damage", spell["key"] + "Mana"] + ([spell["key"] + "CastTime"] if any(l[2] for l in spell["levels"]) else [])
            keys += [spell["key"] + s for s in ("Steps", "Step0", "Step2", "Step4", "Step6")] if spell.get("steps") else []
            keys += ([spell["key"] + "Freeze"] if spell.get("freeze") else []) + ([spell["key"] + "Stagger"] if spell.get("stagger") else [])
        snap_rule = re.search(rb"local SNAP = ([0-9.]+)", files.get("modules/magic/Scripts/main.lua", b""))
        check(not wrong and sorted(claimed) == sorted(defs) and len(claimed) == len(set(claimed)) and sorted(s["freeze"] for s in spells if s.get("freeze")) == sorted(effects)
              and all(("GE_Skill_Mage_Circle_%d" % n) in skills for n in range(1, 7)) and not [k for k in keys if k not in items]
              and snap_rule is not None and float(snap_rule.group(1)) == inst.MAGIC_SNAP,
              "the installer's table of the fifteen spells is the game as the module's own tests model it (dev/tests/magic/game.lua): the %d definitions each belong to one spell, "
              "mana and casting time of every charge level, the four single damage numbers, the fist of wind's 200, the three ice hit effects, the six circles; every setting the "
              "converter writes is in the module's schema (%d keys)%s" % (len(defs), len(keys), "" if not wrong else " - WRONG: " + ", ".join(wrong)))
    # mana and casting time per charge level: one multiplier or none
    c = run(mod, {name: magic(['A = { spellConfig = "ProjectileSpellConfig_FireBall", mana = { 3, 3, 3 }, cast = { 0.2, 0.3, 0.4 } }',
                               'B = { spellConfig = "ProjectileSpellConfig_BallLightning", mana = { 10 }, cast = { 0.6, 2.06, 2.06, 2.06 } }',
                               'C = { spellConfig = "IceWaveSpellConfig", mana = { 12.5, 40 } }', 'D = { spellConfig = "FireRainSpellConfig", mana = { "many" }, cast = "fast" }',
                               'E = { spellConfig = "BreathOfDeathSpellConfig", mana = { 15 }, cast = {} }'])}, "numbers per charge level")
    check(got(c, WholeMana="false", FireBallCastTime="0.5", BallLightningCastTime="2.0", IceWaveMana="0.833", BreathOfDeathMana="1.0")
          and c.why("Spells.A.mana.1") == ["our module has one multiplier for a spell, not a number for each charge level (theirs are x3 / x1.5 / x1.5 of the game's 1 / 2 / 2)"]
          and c.told("Spells.A.mana.2", "Spells.A.mana.3") and "(theirs are x2 / x1 / x1 / x1 of the game's 5 / 1 / 1 / 2)" in c.first("Spells.B.mana.1")
          and "IceWaveMana = 0.833 (their 12.5; the game has 15; x0.833 gives 12.495)" in c.plan and c.why("Spells.C.mana.2") == ["the spell has 1 charge level(s) in the game"]
          and c.why("Spells.D.mana.1") == ["is not a number"] and c.why("Spells.D.cast") == ["is neither a number (a multiplier) nor a table of absolute numbers"],
          "absolute numbers per charge level become one multiplier where one says them (0.2 / 0.3 / 0.4 s of 0.4 / 0.6 / 0.8 s is x0.5); where it does not - the same cost for "
          "every level, or only the first level given - nothing is written and the plan says why; a number three places cannot hit exactly is said with what comes out")
    c = run(mod, {name: magic(['A = { spellConfig = "ProjectileSpellConfig_BallLightning", cast = { %r, 4, 4, 4 } }' % (0.3 * (4 / 1.03)),
                               'B = { spellConfig = "FireRainSpellConfig", mana = { 30 } }', 'C = { spellConfig = "FireRainSpellConfig", mana = 2 }',
                               'D = { spellConfig = "IceWaveSpellConfig", mana = { 29.99 } }'])}, "a time close to a whole number; two blocks for one spell")
    check(got(c, WholeMana="false", BallLightningCastTime="3.883", FireRainMana="2.0", IceWaveMana="1.999")
          and ("BallLightningCastTime = 3.883 (their 1.165 / 4 / 4 / 4 s; the game has 0.3 / 1.03 / 1.03 / 1.03 s; x3.883 gives 3.999), FireRainMana = 2.0, "
               "IceWaveMana = 1.999 (their 29.99; the game has 15; x1.999 gives 30) (our default already: Enabled = true)") in c.plan,
          "what comes out is said as the module will write it: a casting time is the plain product (4 s of 1.03 s is x3.883, which gives 3.999 - said once, not for each level), "
          "a mana cost within 0.025 of a whole number is that number (29.99 of 15 gives 30); of two blocks for the same spell the later one counts, with its own remark")
    c = run(mod, {name: magic(['A = { spellConfig = "StormFistSpellConfig", mana = 1.0, cast = 2 }', 'B = { spellConfig = "BreathOfDeathSpellConfig", mana = { 15 } }',
                               'C = { class = "StormOfFireDefinition", damage = 2 }', 'D = { spellConfig = "ProjectileSpellConfig_FireBall", mana = { 1 } }'])}, "no mana cost changed")
    d = run(mod, {name: magic(['A = { spellConfig = "StormFistSpellConfig", mana = 0.5 }'])}, "one mana cost changed")
    check(got(c, StormFistMana="1.0", StormFistCastTime="2.0", BreathOfDeathMana="1.0", StormOfFireDamage="2.0", FireBallMana="1.0") and "WholeMana" not in c.values
          and "FireBallMana = 1.0 (their 1 / - / -; the game has 1 / 2 / 2)" in c.plan
          and got(d, WholeMana="false", StormFistMana="0.5") and d.set == {"WholeMana": "false", "StormFistMana": "0.5"},
          "WholeMana = false is written exactly when a mana cost is changed (their mod writes the exact product); with mana at 1.0, or equal to the game's number, it stays as shipped")
    # damage as absolute numbers
    c = run(mod, {name: magic(['A = { class = "FireBoltProjectileDefinition", damage = { c4 = 60 } }', 'B = { class = "IceBoltProjectileDefinition", damage = 1.5 }',
                               'C = { class = "StormOfFireDefinition", damage = { base = 300, c2 = 350 } }', 'D = { class = "FireRainDefinition", damage = { base = 52.33, c2 = 70 } }',
                               'E = { class = "BreathOfDeathDefinition", damage = "strong" }', 'F = { class = "IceBlockProjectileDefinition", damage = { base = "x", c6 = 120 } }',
                               'G = { class = "UrizielWaveOfDeathVisualDefinition", damage = {} }'])}, "damage as absolute numbers")
    check(got(c, FireBoltSteps="true", FireBoltStep4="60", IceBoltDamage="1.5", FireRainDamage="1.047") and "IceBoltSteps" not in c.values and "FireBoltStep0" not in c.values
          and "our module has numbers of its own for the damage by the caster's circle only for the fire bolt and the ice bolt; this spell has one multiplier (StormOfFireDamage)" in c.first("Spells.C.damage.base")
          and c.told("Spells.C.damage.c2") and c.why("Spells.D.damage.c2") == ["the spell has one damage number in the game: their mod finds no step to write this to"]
          and "FireRainDamage = 1.047 (their 52.33; the game has 50; x1.047 gives 52.35)" in c.plan
          and c.why("Spells.E.damage") == ["is neither a number (a multiplier) nor a table of absolute numbers"] and c.why("Spells.F.damage.base") == ["is not a number"]
          and c.told("Spells.F.damage.c6"),
          "absolute damage: for the two bolts the numbers given go into the steps of their own (one step given: that one, and the switch); a multiplier for a bolt stays a multiplier; "
          "for a spell with one damage number the base becomes a multiplier; for a spell with steps or charge levels nothing is written, and the plan says that our module has one multiplier there")
    # fields, the other blocks
    c = run(mod, {name: magic(['A = { class = "FireBoltProjectileDefinition", fields = { m_Speed = 6000, m_LifeTime = 3 } }',
                               'B = { class = "StormFistDefinition", fields = { m_SuperArmorDamageBase = 500 } }',
                               'C = { class = "BallLightningDefinition", fields = { m_Speed = 0 } }', 'D = { class = "WindFistDefinition", fields = { m_SuperArmorDamageBase = 250 } }',
                               'E = { class = "IceWaveProjectileDefinition", spellConfig = "IceWaveSpellConfig", configFields = { m_EmitterWidth = 900 }, fields = "wide" }',
                               'F = { class = "FireRainDefinition", fields = { m_XOffset = 1600 } }', 'G = { class = "IceBoltProjectileDefinition", fields = { m_XOffset = 5 } }',
                               'H = { class = "WindFistDefinition", fields = { m_SuperArmorDamageBase = -1 } }'])},
            "fields")
    check(got(c, WindFistStagger="1.25") and "only for the ball lightning" in c.first("Spells.A.fields.m_Speed") and c.why("Spells.A.fields.m_LifeTime") == ["the module magic has no setting for this number"]
          and "only for the fist of wind" in c.first("Spells.B.fields.m_SuperArmorDamageBase") and "takes a speed above 0" in c.first("Spells.C.fields.m_Speed")
          and c.why("Spells.E.configFields.m_EmitterWidth") == ["the module magic has no setting for this number"] and ("Spells.E.fields=\"wide\"", "is not a table of numbers") in c.lost
          and "the game's scripts do not read this number" in c.first("Spells.F.fields.m_XOffset") and c.why("Spells.G.fields.m_XOffset") == ["the module magic has no setting for this number"]
          and "WindFistStagger = 1.25 (their 250; the game has 200)" in c.plan and c.why("Spells.H.fields.m_SuperArmorDamageBase") == ["is not a number of 0 or more"],
          "fields: the speed is carried over only for the ball lightning and the force against a foe's stance only for the fist of wind (250 of 200 = x1.25); every other field, "
          "and every configFields, is named as having no setting")
    c = run(mod, {name: magic(['A = { class = "FireRainDefinition", damage = 2, enabled = false, spellConfig = "FireRainSpellConfig", mana = 2 }',
                               'B = { class = "HealProjectile", damage = 2, fields = { m_Speed = 1 }, spellConfig = "HealSpellConfig", mana = 0.5, cast = 0.5 }',
                               'C = { class = "FireBallProjectileDefinition_Lvl2", damage = 2 }', 'D = { damage = 3, spellConfig = "StormFistSpellConfig", mana = 2 }',
                               'E = { class = "StormFistDefinition", damage = 1.5, mana = 3, cast = 3 }', 'F = 5', '{ class = "IceWaveProjectileDefinition", damage = 1.75, enabled = true }'])},
            "blocks their mod skips, spells our module has no settings for")
    check(got(c, WholeMana="false", StormFistMana="2.0", StormFistDamage="1.5", IceWaveDamage="1.75")
          and all(w == "the block is switched off there (enabled = false)" for n in ("class", "damage", "enabled", "spellConfig", "mana") for w in c.why("Spells.A." + n)) and c.told("Spells.A.class", "Spells.A.mana")
          and '"HealProjectile" is not the definition of one of the fifteen spells' in c.first("Spells.B.damage")
          and '"HealProjectile" is not the definition of one of the fifteen spells' in c.first("Spells.B.fields.m_Speed")
          and '"HealSpellConfig" is not the spell config of one of the fifteen spells' in c.first("Spells.B.mana") and c.told("Spells.B.cast")
          and c.why("Spells.C.damage") == ["FireBallProjectileDefinition_Lvl2 is one definition of a spell that has several: our settings hold for the whole spell"]
          and c.why("Spells.D.damage") == ["the block names no class: their mod does not apply it either"]
          and c.why("Spells.E.mana") == ["the block names no spellConfig: their mod does not apply it either"] and c.told("Spells.E.cast")
          and c.why("Spells.F") == ["is not a table with the settings of a spell"],
          "blocks: one switched off there (enabled = false) is not carried over; damage needs the class and mana the spellConfig of one of our fifteen spells, each without the "
          "other; a spell our module has no settings of its own for, a single charge level, a block without the name it needs: each named with its reason")
    # freeze
    c = run(mod, {name: magic(['A = { freezeGE = "GE_IceBolt_Damage", reliableFreeze = true }', 'B = { class = "FireRainDefinition", freezeGE = "GE_IceWave_Freeze_Damage", reliableFreeze = true }',
                               'C = { freezeGE = "GE_IceBlock_Freeze_Damage", reliableFreeze = false }', 'D = { freezeGE = "GE_Burn", reliableFreeze = true }', 'E = { reliableFreeze = true }',
                               'F = { freezeGE = "GE_IceBlock_Freeze_Damage" }'])}, "freeze")
    check(got(c, IceBoltFreeze="true", IceWaveFreeze="true") and "IceBlockFreeze" not in c.values
          and c.why("Spells.C.reliableFreeze") == ["without reliableFreeze = true their mod does nothing with it, and our switch stays off"] and c.told("Spells.C.freezeGE", "Spells.F.freezeGE")
          and c.why("Spells.D.freezeGE") == ['"GE_Burn" is not the hit effect of the ice bolt, the ice block or the ice wave'] and c.told("Spells.D.reliableFreeze")
          and c.why("Spells.E.reliableFreeze") == ["the block names no freezeGE: their mod does not apply it either"]
          and c.told("Spells.A.reliableFreeze for hits on a foe that is frozen already", "Spells.B.reliableFreeze for hits on a foe that is frozen already"),
          "\"freezes with every hit\": the switch of the ice spell whose hit effect the block names (ice bolt, ice wave - whatever class the block has); "
          "without reliableFreeze = true, without the effect's name or with another effect nothing is switched, and the plan says why")
    # the circle prices, the top-level values
    c = run(mod, {name: magic([], "    CircleCost = 12,\n")}, "one price for all circles")
    d = run(mod, {name: magic([], "    CircleCost = { [3] = 9, [5] = \"x\", [7] = 1, 500 },\n")}, "prices for some circles")
    e = run(mod, {name: magic([], "    CircleCost = \"cheap\",\n    Verbose = false,\n    DebugSteps = true,\n    enabled = false,\n", enabled="")}, "no prices")
    check(got(c, CircleCosts="true", **{"CircleCost%d" % n: "12" for n in range(1, 7)})
          and holds(d, {"Enabled": "true", "CircleCosts": "true", "CircleCost1": "200", "CircleCost3": "9"}) and "CircleCost1 = 200 (was 500; the range is 0 to 200)" in d.plan
          and d.why("CircleCost.5") == ["is not a number"] and d.why("CircleCost.7") == ["not looked at by the converter"]
          and holds(e, {}) and e.conv is None and e.why("CircleCost") == ["is neither a number nor a table of six numbers"] and e.told("Verbose", "DebugSteps")
          and e.why("enabled") == ["not looked at by the converter"],
          "the circle prices: one number for all six, or the circles a table names (an own price also pulled into our range, said); Enabled missing is not carried over "
          "(it counts as on there, as ours does), and a lower-case enabled is not that mod's switch")
    c = run(mod, {name: magic(['A = { class = "FireRainDefinition", damage = 2.5 }'], enabled="Enabled = false,")}, "switched off in its own file")
    check(holds(c, {"Enabled": "false", "FireRainDamage": "2.5"}) and c.set == {"Enabled": "false", "FireRainDamage": "2.5"},
          "Enabled = false in that file switches our module off; his numbers are carried over all the same, for the day he switches it on")
    c = run(mod, {name: magic(['A = { class = "FireRainDefinition", damage = 25, spellConfig = "FireRainSpellConfig", cast = { 100 }, mana = { 300 } }',
                               'B = { class = "FireBoltProjectileDefinition", damage = { base = 5000, c2 = 40.6 } }', 'C = { class = "StormFistDefinition", damage = 0 }'])},
            "numbers outside our ranges")
    check(got(c, WholeMana="false", FireRainDamage="10.0", FireRainCastTime="10.0", FireRainMana="10.0", FireBoltSteps="true", FireBoltStep0="2000", FireBoltStep2="41", StormFistDamage="0.1")
          and "FireRainDamage = 10.0 (was 25; the range is 0.1 to 10)" in c.plan and "FireRainMana = 10.0 (their 300; the game has 20; was 15.0; the range is 0 to 10)" in c.plan
          and "FireRainCastTime = 10.0 (their 100 s; the game has 0.1 s; was 1000.0; the range is 0.1 to 10)" in c.plan and "FireBoltStep0 = 2000 (was 5000; the range is 0 to 2000)" in c.plan
          and "FireBoltStep2 = 41 (was 40.6; rounded)" in c.plan and "StormFistDamage = 0.1 (was 0; the range is 0.1 to 10)" in c.plan,
          "numbers outside our ranges - a multiplier of 25 or 0, an absolute cost or time far from the game's, a bolt step of 5000 - are pulled inside, each said in the plan")
    c = run(mod, {name: 'return { Enabled = true, Spells = "none", CircleCost = { 11 } }\n'}, "Spells is no table")
    check(holds(c, {"Enabled": "true", "CircleCosts": "true", "CircleCost1": "11"}) and c.lost == [('Spells="none"', "is not a table of spell blocks")],
          "a file whose Spells is not a table: said in the plan; the rest of the file is carried over")
    done = [run(mod, {name: magic([]).replace("Enabled = true", "Enabled = isEnabled()")}, "a call"), run(mod, {name: "return 5\n"}, "no table"),
            run(mod, {name: magic([])[:-20]}, "cut off"), run(mod, {name: b"MZ\x90\x00\x03"}, "binary"), run(mod, {"Scripts/main.lua": b"--\n"}, "no file")]
    check(all(c.conv is None and c.text is None and len(c.lost) == 1 for c in done) and all("could not be read as plain values" in c.lost[0][1] for c in done[:4])
          and done[4].lost == [("Scripts\\config.lua", "not found")],
          "a config.lua of G1R_MageBalance that calls a function, gives back no table, is cut off, is no text, or is not there: nothing is carried over and nothing of it is run, said in the plan")
    c = run(mod, {name: magic(['A = { class = "FireRainDefinition", damage = 2.5 }'])}, "our file is the player's", player=True)
    check(c.conv["state"] == "player" and c.text is None and "NOT written, the file was changed by the player (it would get: FireRainDamage = 2.5)" in c.plan,
          "a magic config.lua the player already changed is not written; the plan says what it would have got")

    # ================= numbers no setting can hold
    r = run("G1R_RegenMana", {"G1R_RegenMana.ini": base.replace("CircleSixPercent=190", "CircleSixPercent=1e999").replace("ManaPerTick=3", "ManaPerTick=1e999")}, "an infinite number")
    k = run("SkillfulLocks", {"Scripts/config.lua": locks("1e999", "2", "99999999999999999999")}, "an infinite number")
    g = run("G1R_MageBalance", {"Scripts/config.lua": magic(['A = { class = "FireRainDefinition", damage = { base = 1e999 }, spellConfig = "FireRainSpellConfig", mana = { 1e999 }, cast = 1e999 }',
                                                              'B = { class = "IceBoltProjectileDefinition", damage = { base = 1e999, c2 = 44 } }'], "    CircleCost = 1e999,\n")}, "infinite numbers")
    check(holds(r, dict({k2: v for k2, v in all_values.items() if k2 != "ManaCircleStep"}, ManaFlat="1000.0")) and r.why("CircleSixPercent") == ["is no number to calculate with"]
          and "ManaFlat = 1000.0 (was inf; the range is 0 to 1000)" in r.plan
          and holds(k, {"SkilledConnections": '"2"', "LogLocks": "false"}) and "is none of false, a number" in k.first("removeConnections.untrained") and k.why("removeConnections.master")
          and got(g, IceBoltSteps="true", IceBoltStep2="44") and g.why("Spells.A.damage.base") == ["is not a number"] and g.why("Spells.A.mana.1") == ["is not a number"]
          and g.why("Spells.A.cast") and g.why("Spells.B.damage.base") == ["is not a number"] and g.why("CircleCost"),
          "a number beyond any setting (1e999, twenty digits): where it is a plain value it is pulled into our range like any other; where a converter would have to calculate "
          "with it - the circle table, a level of the locks, an absolute number of a spell - it is named and not carried over; no converter fails")

    # ================= files nobody wrote by hand: whatever stands in them, every converter copes
    rng = random.Random(20261003)
    names = {"G1R_RegenMana": "G1R_RegenMana.ini", "G1R_WaitOnT": "Scripts/main.lua", "BetterMining": "BetterMining.ini", "SkillfulLocks": "Scripts/config.lua",
             "G1R_MageBalance": "Scripts/config.lua"}
    failed, unsaid, random_files = [], [], []
    for mod in FIVE:
        for n in range(60):
            text = fuzz_file(rng, mod)
            try:
                c = Converted(inst, files, mod, {names[mod]: text.encode("utf-8")})
            except Exception as e:
                failed.append("%s #%d: %s: %s" % (mod, n, type(e).__name__, e))
                continue
            if any("THE CONVERTER FAILED" in why for _, why in c.lost):
                failed.append("%s #%d: %s" % (mod, n, [why for _, why in c.lost if "FAILED" in why][0]))
            if c.text is not None:
                random_files.append((mod, "random file %d" % n, c))
            # every value of the file: asked for by the converter, or listed
            theirs = []
            if names[mod].endswith(".ini"):
                theirs = [(section + "." + key) if section else key for section, key, _, _ in inst.read_ini(text.encode("utf-8"))[0]]
            elif mod != "G1R_WaitOnT":
                try:
                    theirs = [name for name, _ in inst.lua_flat(inst.read_lua(text.encode("utf-8")))]
                except inst.LuaError:
                    theirs = []
            asked = set(name for item in c.carry["read"] for name in item["asked"])
            unsaid += ["%s #%d: %s" % (mod, n, name) for name in theirs if name not in asked and not c.why(name)]
    check(not failed and not unsaid and len(random_files) > 150,
          "300 random settings files (60 for each mod: every name its converter knows, with numbers of every size, words, switches, tables, nothing): no converter fails, "
          "and every value of every file is asked for by its converter or listed as not carried over (%d of the files lead to a config.lua)%s"
          % (len(random_files), "" if not (failed or unsaid) else " - " + "; ".join((failed + unsaid)[:3])))
    proofs += random_files

    # ================= the two proofs for every file a case made
    patched = lua_oracle([("patchall", c.default) + tuple(b for kv in c.set.items() for b in (kv[0].encode("ascii"), kv[1].encode("utf-8"))) for _, _, c in proofs])
    opened = lua_oracle([("open", c.module.encode("ascii"), files["modules/%s/Scripts/schema.lua" % c.module], c.text) for _, _, c in proofs])
    if patched is None:
        return
    for mod in FIVE:
        mine = [(label, c, patched[i], opened[i].decode("utf-8", "replace")) for i, (m, label, c) in enumerate(proofs) if m == mod]
        differ = [label for label, c, text, _ in mine if text != c.text]
        check(not differ and len(mine) >= 4, "%s: the %d converted files are byte for byte what the game's own Settings.patch makes of the module's default file with the same values%s"
              % (mod, len(mine), "" if not differ else " - DIFFER: " + ", ".join(differ)))
        bad = []
        for label, c, _, answer in mine:
            log, _, values = answer.partition("\n==\n")
            loaded = {}
            for pair in values.split(";"):
                key, _, leaf = pair.partition("=")
                kind, _, value = leaf.partition(":")
                loaded[bytes.fromhex(key[1:]).decode("ascii")] = (value == "true") if kind == "b" else (bytes.fromhex(value).decode("utf-8") if kind == "s" else float(value))
            if "==" not in answer or "is not usable" in log or "has an error" in log or log.strip() or any(loaded.get(k) != literal_value(v) for k, v in c.values.items()):
                bad.append("%s (%s)" % (label, log.strip()[:120] or [k for k, v in c.values.items() if loaded.get(k) != literal_value(v)]))
        check(not bad and len(mine) >= 4, "%s: each of them, read by the real settings service with the module's real schema, is taken without a complaint (no \"is not usable\" line), "
              "and every value is the one meant%s" % (mod, "" if not bad else " - NOT SO: " + "; ".join(bad[:3])))


# ---------------------------------------------------------------------------------------------
# Part "update": the PC as it is now -> the new version, with the take-overs
# ---------------------------------------------------------------------------------------------
def read_json(path):
    return json.loads(read(path).decode("utf-8"))


def holds_mod(t, name):
    """Whether a tree() of a Mods folder has a mod of that name (Scripts\\main.lua in either spelling, or dlls\\main.dll)."""
    low = set(k.lower() for k in files_of(t, name))
    return "scripts/main.lua" in low or "dlls/main.dll" in low


def is_players(rel):
    """A file of the megamod folder that an update never takes away (written here once more, not the installer's)."""
    return bool(rel == "enabled.txt" or re.match(r"^(Scripts|modules/[^/]+/Scripts)/config\.lua$", rel)
                or (rel.startswith(("Scripts/diagnostics/", "modules/repopulate/Scripts/state/")) and not rel.endswith("/README.txt"))
                or rel == "modules/repopulate/" + SETTINGS_EXE)


def expected_xp(default):
    """The package's default settings of the module xp with this PC's EXPModifier values put in - made by plain
    text replacement, not by the installer's rule."""
    return default.replace(b"Config.Multiplier = 1.0\n", b"Config.Multiplier = 4.0\n").replace(b"Config.LogGains = false\n", b"Config.LogGains = true\n")


def load_line(inst, files, left=None, off=()):
    """The loader's line for a megamod with these package files: every module ok, except those left to a mod or switched off."""
    left = left or {}
    parts = []
    for module in inst.package_modules(files):
        if module in off:
            parts.append("%s off" % module)
        elif module in left:
            parts.append("%s left to the separate mod %s" % (module, left[module]))
        else:
            parts.append("%s %s" % (module, "ok" if ("modules/%s/Scripts/main.lua" % module) in files else "not installed"))
    return "loaded: " + ", ".join(parts) + " | diagnostics normal"


def world_facts(inst):
    """What a check needs to know about the world before a run."""
    mods = tree(inst.MODS)
    files = package_files(inst.PKGDIR, inst.PACKAGE)
    manifest = {rel: sha_of(data) for rel, data in files.items()}
    table = [(e[0], e[1], e[2]) for e in inst.TAKEOVERS]
    going = [m for m, _, module in table if holds_mod(mods, m) and ("modules/%s/Scripts/main.lua" % module) in manifest]
    return {"mods": mods, "files": files, "manifest": manifest, "table": table, "going": going,
            "staying": [m for m, _, _ in table if holds_mod(mods, m) and m not in going], "absent": [m for m, _, _ in table if not holds_mod(mods, m)],
            "was": files_of(mods, inst.NAME), "saves": tree(inst.SAVES), "lnk": read(inst.SHORTCUT) if os.path.isfile(inst.SHORTCUT) else None,
            "module_of": {m: module for m, _, module in table}}


def part_update(shells):
    real = bool(ARGS.pc_mods)
    sim = ARGS.sim
    inst = build_pc_world(real=real)
    target = os.path.join(inst.MODS, inst.NAME)
    w = world_facts(inst)
    manifest, files, was, going, staying, absent = w["manifest"], w["files"], w["was"], w["going"], w["staying"], w["absent"]
    old_manifest_path = os.path.join(inst.PKGDIR, inst.manifest_name(OLDX[1]))
    old_listed = inst.read_manifest(old_manifest_path) if os.path.isfile(old_manifest_path) else {}
    obsolete = sorted(r for r in was if r in old_listed and r not in manifest and not is_players(r))
    installed_version = re.search(rb'version\s*=\s*"([^"]+)"', read(os.path.join(target, "Scripts", "core", "version.lua"))).group(1).decode("ascii")
    has_exp = "EXPModifier" in going and "modules/general/Scripts/main.lua" in manifest and "modules/xp/Scripts/config.lua" not in was
    xp_text = expected_xp(files.get("modules/xp/Scripts/config.lua", b""))
    # the five mods with a converter of their own; `known`: those that have the player's file of 2026-10-01 in this
    # mock - what that becomes is known to the letter (another file is checked for consistency only)
    five = [m for m in FIVE if m in going and config_rel(w["module_of"][m]) in files and config_rel(w["module_of"][m]) not in was]
    known = [m for m in five if is_snapshot(w["mods"], m)]
    expected = {config_rel(PLAYER[m][0]): player_text(files, m) for m in known}
    if len(known) < len(FIVE):
        NOTES.append("part update: the mock does not have the player's file of 2026-10-01 for %s: its conversion is checked for consistency only"
                     % ", ".join(m for m in FIVE if m not in known))

    # ================= the plan
    before = tree(sim)
    code, plan_text = run(inst, "--check")
    if ARGS.show_plan:
        print("---- the plan (--check) on the mock of the PC ----\n%s---- end of the plan ----" % plan_text)
    check(code == 0 and "update of the installed mod" in plan_text and "CHECK ONLY" in plan_text and tree(sim) == before,
          "--check on the PC as it is now: prints the plan of the update, creates and changes nothing")
    check(("package: %s, version %s, %d files" % (inst.PACKAGE, NEW_VERSION, len(manifest))) in plan_text
          and ("installed: version %s (its file list: the report in megamod-install-backup-" % installed_version) in plan_text,
          "the plan names the package's version (%s), the installed one (%s) and where the installed version's file list comes from" % (NEW_VERSION, installed_version))
    check(all(("retire: Mods\\%s (" % m) in plan_text and ("removed from Mods; the module %s takes over" % w["module_of"][m]) in plan_text for m in going)
          and plan_text.count("-> backup folder, then removed from Mods") == len(going) and plan_text.count(", enabled) -> backup folder") == len(going)
          and all(("left alone: Mods\\%s (the package has no module" % m) in plan_text for m in staying)
          and (not absent or ("not installed, nothing to do: " + ", ".join(absent)) in plan_text),
          "the plan says for every mod of the table what happens to it: %d retired (%s), %d left alone, %d not installed (%s)"
          % (len(going), ", ".join(going), len(staying), len(absent), ", ".join(absent)))
    if not real:
        check(going == [e[0] for e in inst.TAKEOVERS if e[0] not in OWN] and absent == list(OWN) and len(going) == 6,
              "that is: the six mods of other authors are retired, our own two are not installed any more")
        check(sorted(obsolete) == sorted(OBSOLETE) and all(("    removed: %s" % r) in plan_text for r in obsolete) and ("%d of the old version removed" % len(obsolete)) in plan_text
              and "kept: Scripts/config.lua (The player's own; differs from the package's)" in plan_text and "kept: modules/repopulate/Scripts/config.lua" in plan_text
              and "kept: modules/markers/Scripts/config.lua" in plan_text and "kept: enabled.txt" in plan_text and "other files in the folder left alone" in plan_text,
              "the plan lists the %d files only the old version had as to be removed, and the settings files and enabled.txt as kept" % len(obsolete))
    if has_exp:
        check("settings: Mods\\EXPModifier -> G1R_MegaMod\\modules\\xp\\Scripts\\config.lua: Multiplier = 4.0, LogGains = true (our default already: ShowMessage = true)" in plan_text
              and "settings: Mods\\EXPModifier -> G1R_MegaMod\\modules\\general\\Scripts\\config.lua: nothing to write (our default already: NoteSeconds = 3)" in plan_text
              and "settings: Mods\\EXPModifier: not carried over: UpdateIntervalMs=250 (the module xp has its own check interval)" in plan_text,
              "the plan lists the conversion of EXPModifier.ini: Multiplier = 4.0 and LogGains = true into the module xp, ShowMessage and general's NoteSeconds as our defaults "
              "already, UpdateIntervalMs as not carried over")

    def said(mod):
        """What the plan says about the settings of a mod: its `settings:` lines with the lines listed below them."""
        lines, out = plan_text.splitlines(), []
        for i, line in enumerate(lines):
            if line.startswith("  settings: Mods\\%s " % mod) or line.startswith("  settings: Mods\\%s:" % mod):
                out.append(line)
                for more in lines[i + 1:]:
                    if not more.startswith("      "):
                        break
                    out.append(more)
        return "\n".join(out)
    if five:
        check(all(said(m) for m in five), "the plan has lines about the settings of each of the %d mods with a converter of its own (%s)" % (len(five), ", ".join(five)))
    if known:
        fragments = {
            "G1R_RegenMana": ("modules\\regen\\Scripts\\config.lua: 9 values", "RegenValueRounding=0.1 (", "RecoveryIndicatorEnabled=true; RecoveryIndicatorPrefix=>> (all 2: ",
                              "HealthRegenItemWhitelist=_Life_,Enlight (all 8: the module regen has no item requirements"),
            "G1R_WaitOnT": ("modules\\wait\\Scripts\\config.lua: ShortKey = \"Y\" (our default already: ShortMinutes = 30 (its WAIT_HOURS = 0.5), Cooldown = 2.0, ShowMessage = true)",
                            "the text and the place of its note", "it skipped time whenever a game was loaded and not paused"),
            "BetterMining": ("modules\\mining\\Scripts\\config.lua: 8 values", "ShowMessage = false (BetterMining showed no notes)", "(our default already: Enabled = true)"),
            "SkillfulLocks": ("modules\\locks\\Scripts\\config.lua: SkilledConnections = \"safe\" (their \"auto\"), MasterConnections = \"all\", LogLocks = true "
                              "(our default already: UntrainedConnections = \"as the game has it\")",
                              "vanillaPrecision.untrained=0; vanillaPrecision.skilled=1; vanillaPrecision.master=2 (all 3: the game's own numbers"),
            "G1R_MageBalance": ("modules\\magic\\Scripts\\config.lua: 37 values", "Spells.Feuerregen.fields.m_XOffset=1600; Spells.Feuerregen.fields.m_YOffset=1600 (all 2: ",
                                "Spells.Kugelblitz.fields.m_Speed for BallLightningDefinition_Base (", "Spells.Eisblock.reliableFreeze for hits on a foe that is frozen already (",
                                "Verbose=true (", "DebugSteps=false ("),
        }
        short = [m for m in known if not all(("%s = %s" % kv) in said(m) for kv in PLAYER[m][1].items()) or not all(f in said(m) for f in fragments[m])]
        check(not short and "not looked at by the converter" not in plan_text and "THE CONVERTER FAILED" not in plan_text,
              "for the player's files of 2026-10-01 the plan lists every value our modules get - regen 9, wait 1, mining 8, locks 3, magic 37, each with what it was worked out from "
              "where that is not plain - and everything that is not carried over with its reason; no value of any file is left unmentioned%s" % ("" if not short else " - NOT SO: " + ", ".join(short)))

    # ================= the update
    code, out = run(inst)
    after = tree(inst.MODS)
    ours = files_of(after, inst.NAME)
    bdir = last_backup(inst)
    report = read_json(os.path.join(bdir, "install-report.json"))
    check(code == 0 and "DONE:" in out and ("%s %s is in place and verified" % (inst.NAME, NEW_VERSION)) in out, "update %s -> %s: done (%s)" % (installed_version, NEW_VERSION, last_line(out)))
    kept = sorted(r for r in manifest if is_players(r) and r in was)
    converted = {"modules/xp/Scripts/config.lua": xp_text} if has_exp else {}
    for rel in report.get("written", {}):                # what the converters wrote: as expected where that is known, else as it is on disk
        if rel not in converted:
            converted[rel] = expected[rel] if rel in expected else read(os.path.join(target, rel.replace("/", os.sep)))
    wrong = [r for r in manifest if r not in kept and r not in converted and ours.get(r) != manifest[r] and not (r == "enabled.txt" and r not in was)]
    check(not wrong and len(manifest) > 300, "every package file is in place with the manifest's hash (%d files; %d wrong%s)" % (len(manifest), len(wrong), "" if not wrong else ": " + ", ".join(wrong[:4])))
    check(all(ours.get(r) == was[r] for r in kept) and len(kept) >= 3 and ("Scripts/config.lua" not in kept or ours["Scripts/config.lua"] != manifest["Scripts/config.lua"] or real),
          "The player's settings files and enabled.txt are exactly as before, also where the package has a newer default (%s)" % ", ".join(kept))
    others = sorted(r for r in was if r not in manifest and r not in obsolete)
    check(all(ours.get(r) == was[r] for r in others) and (real or sorted(r.rsplit("/", 1)[-1] for r in others)
          == ["G1R_Repopulate_Settings.exe", "config.lua", "my-notes.txt", "profile_0.lua", "report-latest.txt", "session-20261002-080000.log"]),
          "what the update must not take away stays untouched: the progress file, the diagnostics files, the settings app, the player's own file, "
          "and the settings file of a module the new version does not have any more (%d files)" % len(others))
    new_modules = sorted(set(r.split("/")[1] for r in manifest if re.match(r"^modules/[^/]+/Scripts/config\.lua$", r) and r not in was and r not in converted))
    check(all(ours.get("modules/%s/Scripts/config.lua" % m) == manifest["modules/%s/Scripts/config.lua" % m] for m in new_modules) and (real or len(new_modules) >= 2),
          "the new modules get their default config.lua from the package (%s)" % ", ".join(new_modules))
    removed_copies = files_of(tree(bdir), "removed")
    check(all(r not in ours for r in obsolete) and removed_copies == {r: was[r] for r in obsolete} and (real or (len(obsolete) == len(OBSOLETE) and not os.path.exists(os.path.join(target, "oldfolder"))
                                                                                        and os.listdir(os.path.join(target, "modules", "gone", "Scripts")) == ["config.lua"])),
          "the files only the old version had are gone from the folder, a folder they leave empty too, and each has its copy in the backup folder (%d)" % len(obsolete))
    replaced_copies = files_of(tree(bdir), "replaced")
    replaced = sorted(r for r in manifest if r in was and r not in kept and was[r] != manifest[r])
    check(replaced_copies == {r: was[r] for r in replaced} and (real or len(replaced) >= 10), "the old version of every replaced file is in the backup folder (%d)" % len(replaced))
    if has_exp:
        got = read(os.path.join(target, "modules", "xp", "Scripts", "config.lua"))
        default = files["modules/xp/Scripts/config.lua"]
        check(got == xp_text and xp_text != default and sum(1 for a, b2 in zip(got.split(b"\n"), default.split(b"\n")) if a != b2) == 2 and b"\r" not in got,
              "the module xp starts with the player's EXPModifier settings: its config.lua is the package's default file with Config.Multiplier = 4.0 and Config.LogGains = true, nothing else differs")
        answer = lua_oracle([("patch", default, b"Multiplier", b"4.0")])
        if answer is not None:
            check(lua_oracle([("patch", answer[0], b"LogGains", b"true")])[0] == got, "and that is byte for byte what the game's own code makes of the default file with these two values")
    if known:
        on_disk = {m: read(cfg_path) if os.path.isfile(cfg_path) else None for m, cfg_path in ((m, os.path.join(target, config_rel(PLAYER[m][0]).replace("/", os.sep))) for m in known)}
        lines_changed = {m: sum(1 for a, b2 in zip((on_disk[m] or b"").split(b"\n"), files[config_rel(PLAYER[m][0])].split(b"\n")) if a != b2) for m in known}
        wrong = [m for m in known if on_disk[m] != expected[config_rel(PLAYER[m][0])] or on_disk[m] is None]
        check(not wrong and all(lines_changed[m] == len(PLAYER[m][1]) for m in known),
              "the modules regen, wait, mining, locks and magic start with the player's settings of the mods they replace: each config.lua is the package's default file with exactly "
              "his values (lines that differ: %s)%s" % (", ".join("%s %d" % (PLAYER[m][0], lines_changed[m]) for m in known), "" if not wrong else " - WRONG: " + ", ".join(wrong)))
    writes = [c for c in report["conversions"] if c["state"] == "write" and c["mod"] in five]
    if writes:
        made = [read(os.path.join(target, c["config"].replace("/", os.sep))) for c in writes]
        answers = lua_oracle([("patchall", files[c["config"]]) + tuple(b for kv in c["set"].items() for b in (kv[0].encode("ascii"), kv[1].encode("utf-8"))) for c in writes])
        if answers is not None:
            check(answers == made, "every one of these files is byte for byte what the game's own Settings.patch makes of the module's default file with the reported values (%d files)" % len(writes))
            opened = lua_oracle([("open", c["module"].encode("ascii"), files["modules/%s/Scripts/schema.lua" % c["module"]], text) for c, text in zip(writes, made)])
            bad = []
            for c, answer in zip(writes, opened):
                log, _, values = answer.decode("utf-8", "replace").partition("\n==\n")
                loaded = {}
                for pair in values.split(";"):
                    key, _, leaf = pair.partition("=")
                    kind, _, value = leaf.partition(":")
                    loaded[bytes.fromhex(key[1:]).decode("ascii")] = (value == "true") if kind == "b" else (bytes.fromhex(value).decode("utf-8") if kind == "s" else float(value))
                if log.strip() or not values or any(loaded.get(k) != literal_value(v) for k, v in dict(c["set"], **c["same"]).items()):
                    bad.append("%s (%s)" % (c["module"], log.strip()[:100]))
            check(not bad, "and each, read by the game's real settings service with the module's real schema, is taken without a complaint, every value as reported%s"
                  % ("" if not bad else " - NOT SO: " + "; ".join(bad)))

    # ---- the mods
    check(all(not os.path.exists(os.path.join(inst.MODS, m)) for m in going) and not [k for k in after if ".retired-" in k],
          "the retired mods are gone from Mods, nothing is left behind (%s)" % ", ".join(going))
    # (a run that retires nothing - an update of a megamod that took the mods over earlier - makes no folder "retired")
    retired_dir = os.path.join(bdir, "retired")
    kept_tree = tree(retired_dir) if os.path.isdir(retired_dir) else {}
    check(sorted(os.listdir(retired_dir) if os.path.isdir(retired_dir) else []) == sorted(going) and all(under(kept_tree, m) == under(w["mods"], m) and under(kept_tree, m) for m in going),
          "the copies in the backup folder are identical to the retired folders: every file, every folder (%s)"
          % (", ".join("%s %d" % (m, len(under(kept_tree, m))) for m in going) or "nothing was retired: the backup folder has no folder for them"))
    if not real:
        spellings = {k.replace(os.sep, "/") for k in w["mods"]}
        check({"EXPModifier/scripts/main.lua", "BetterMining/scripts/main.lua", "SkillfulLocks/Scripts/main.lua", "G1R_MageBalance/Scripts/main.lua", "G1R_RegenMana/dlls/main.dll"} <= spellings
              and "G1R_RegenMana/enabled.txt" not in spellings and "G1R_RegenMana/Scripts/main.lua" not in spellings,
              "among them Lua mods with Scripts\\main.lua, Lua mods with scripts\\main.lua, and a native mod (dlls\\main.dll, switched on only through mods.txt)")
    check(without(after, inst.NAME, *going) == without(w["mods"], inst.NAME, *going) and tree(inst.SAVES) == w["saves"]
          and (read(inst.SHORTCUT) if os.path.isfile(inst.SHORTCUT) else None) == w["lnk"],
          "nothing else changed: the mods that stay, mods.txt, mods.json, the saves, the desktop shortcut")
    check(sorted(os.listdir(bdir)) == sorted(["ROLLBACK-megamod-install.ps1", "baseline-hashes.json", "install-report.json"] + (["retired"] if going else [])
                                             + (["replaced"] if replaced else []) + (["removed"] if obsolete else [])),
          "backup folder with baseline hashes, report, rollback script, and a folder each for what there was of them: the retired mods (%d), the replaced (%d) and the removed files (%d)"
          % (len(going), len(replaced), len(obsolete)))
    states = {t["mod"]: t["state"] for t in report["takeovers"]}
    check(report["ok"] is True and report["mode"] == "update" and report["problems"] == [] and report["version"] == NEW_VERSION and report["installed_version"] == installed_version
          and report["package_sha256"] == sha_of(read(os.path.join(inst.PKGDIR, inst.PACKAGE))) and report["package_files"] == manifest
          and sorted(report["retired"]) == sorted(going) and all(report["retired"][m]["files"] == len(files_of(w["mods"], m)) for m in going)
          and states == dict([(m, "retired") for m in going] + [(m, "left") for m in staying] + [(m, "absent") for m in absent])
          and report["removed"] == obsolete and sorted(report["replaced"]) == replaced,
          "report: ok, mode update, both versions, the package's hash and file list, a state for every mod of the table, the removed and the replaced files")
    if has_exp:
        convs = {c["module"]: c for c in report["conversions"] if c["mod"] == "EXPModifier"}
        lost = [l for l in report["not_carried"] if l["mod"] == "EXPModifier"]
        check(convs["xp"]["state"] == "write" and convs["xp"]["set"] == {"Multiplier": "4.0", "LogGains": "true"} and convs["xp"]["same"] == {"ShowMessage": "true"}
              and convs["xp"]["sha256"] == sha_of(xp_text) and report["written"] == {rel: sha_of(text) for rel, text in converted.items()}
              and convs["general"]["state"] == "nothing" and convs["general"]["same"] == {"NoteSeconds": "3"}
              and [l["what"] for l in lost] == ["UpdateIntervalMs=250"] and convs["xp"]["from"] == {"EXPModifier.ini": w["mods"]["EXPModifier" + os.sep + "EXPModifier.ini"]}
              and "settings: G1R_MegaMod\\modules\\xp\\Scripts\\config.lua holds Multiplier = 4.0, LogGains = true (from Mods\\EXPModifier)" in out,
              "report: the conversion with the values taken, those that are our defaults already, the one not carried over, and the hash of the file they were read from")
    if known:
        convs = {c["mod"]: c for c in report["conversions"] if c["mod"] in known}
        wrong = [m for m in known if m not in convs or convs[m]["state"] != "write" or dict(convs[m]["set"], **convs[m]["same"]) != dict(PLAYER[m][1], **PLAYER[m][2])
                 or convs[m]["module"] != PLAYER[m][0] or convs[m]["from"] != {next(k for k in files_of(w["mods"], m) if k.lower() == SNAPSHOT[m][0].lower()): SNAPSHOT[m][1]}
                 or convs[m]["sha256"] != sha_of(expected[convs[m]["config"]])]
        check(not wrong and all(("settings: G1R_MegaMod\\modules\\%s\\Scripts\\config.lua holds " % PLAYER[m][0]) in out and ("(from Mods\\%s)" % m) in out for m in known)
              and "37 converted values, as listed in the plan above (from Mods\\G1R_MageBalance)" in out,
              "report: for each of the five mods the conversion with every value - those written and those that are our defaults already - the module, the hash of the written file, "
              "and the hash of the file of the mod the values were read from%s" % ("" if not wrong else " - WRONG: " + ", ".join(wrong)))
    # nothing of a retired mod's settings may vanish without a word: every value of its files was asked for by its
    # converter, or is listed as not carried over
    counted, silent, stubs = [], [], []
    for mod in going:
        if mod in OWN:
            continue
        theirs = []
        for rel, data in ((k, read(os.path.join(bdir, "retired", mod, k.replace("/", os.sep)))) for k in files_of(kept_tree, mod)):
            if rel.lower().endswith(".ini"):
                theirs += [(section + "." + key) if section else key for section, key, _, _ in inst.read_ini(data)[0]]
            elif rel.lower() == "scripts/config.lua":
                try:
                    theirs += [name for name, _ in inst.lua_flat(inst.read_lua(data))]
                except inst.LuaError:
                    pass
        asked = [name for item in report["settings_read"] if item["mod"] == mod for name in item["asked"]]
        listed = [l["what"] for l in report["not_carried"] if l["mod"] == mod]
        carried = sum(len(c["set"]) + len(c["same"]) for c in report["conversions"] if c["mod"] == mod)
        unsaid = [name for name in theirs if name not in asked and not any(what == name or what.startswith(name + "=") for what in listed)]
        counted.append("%s %d: %d asked for, %d values of ours, %d listed" % (mod, len(theirs), len(set(asked) & set(theirs)), carried, len(listed)))
        if unsaid or carried + len(listed) == 0 or not [item for item in report["settings_read"] if item["mod"] == mod]:
            silent.append("%s (%s)" % (mod, ", ".join(unsaid[:3])))
        if carried == 0:
            stubs.append(mod)
    check(not silent, "every value of the retired mods' settings files is accounted for in the report - its converter asked for it, or it is listed as not carried over (%s)%s"
          % ("; ".join(counted), "" if not silent else " - SILENT: " + ", ".join(silent)))
    if stubs:
        NOTES.append("converters that carried nothing over in part update: %s" % ", ".join(stubs))

    # ================= the independent audit on the update, and on states it must not accept
    aud = load_audit(inst)
    acode, aout = run_audit(aud)
    n_checks = aout.count("\nok   ") + (1 if aout.startswith("ok   ") else 0)
    check(acode == 0 and "AUDIT OK (" in aout and "FAIL" not in aout and n_checks >= 24 + (2 if has_exp else 0) + 2 * len(writes), "audit after the update: %s" % last_line(aout))
    check(all(("%s (-> module %s): retired - gone from Mods, and the copy of %s in the backup folder has every file" % (m, w["module_of"][m], m)) in aout for m in going)
          and all(("%s (-> module %s): not installed before the run and not now" % (m, w["module_of"][m])) in aout for m in absent)
          and (not has_exp or "settings carried over, EXPModifier -> modules/xp/Scripts/config.lua: the file is the package's default with Multiplier = 4.0, LogGains = true and nothing else changed" in aout),
          "the audit has a line for every mod of the table and for the carried-over settings")
    if writes:
        check(all(("settings carried over, %s -> %s: the file is the package's default with %s" % (c["mod"], c["config"], ", ".join("%s = %s" % kv for kv in c["set"].items()))) in aout for c in writes)
              and aout.count("and those values were read from ") == len(writes) + (1 if has_exp else 0)
              and all(("and those values were read from %s\\%s as it was before the run" % (c["mod"], list(c["from"])[0].replace("/", "\\"))) in aout for c in writes),
              "the independent audit confirms each of the %d converted files: the package's default with exactly the reported values, nothing else changed, the values read from the "
              "mod's file as it was before the run (for G1R_WaitOnT its main.lua)" % len(writes))
    version_now = sha_of(read(os.path.join(inst.PKGDIR, inst.PACKAGE)))
    acode, aout = run_audit(aud, "--package", os.path.join(inst.PKGDIR, inst.PACKAGE), "--sha256", version_now, "--version", NEW_VERSION, "--backup", bdir)
    check(acode == 0 and "AUDIT OK (" in aout, "the audit takes package, hash, version and backup folder as arguments too: %s" % last_line(aout))
    rejects = make_rejects(inst, aud)
    rejects("another version than the one named", inst.SHORTCUT, False, "it is version 9.9.9", "--version", "9.9.9")
    rejects("another package hash than the one named", inst.SHORTCUT, False, "the package in the project folder", "--sha256", "0" * 64)
    rejects("a package that is not what its manifest lists", os.path.join(inst.PKGDIR, inst.manifest_name(inst.PACKAGE)),
            read(os.path.join(inst.PKGDIR, inst.manifest_name(inst.PACKAGE))).replace(b"./README.txt", b"./README2.txt"), "the package holds exactly what the manifest")
    rejects("a changed file of another mod", os.path.join(inst.MODS, "HUDMap", "enabled.txt") if real else os.path.join(inst.MODS, "shared", "types.lua"), b"-- other\n", "every other file in Mods is as before")
    rejects("a changed mods.txt", os.path.join(inst.MODS, "mods.txt"), b"HUDMap : 0\r\n", "mods.txt and mods.json are unchanged")
    rejects("a changed file of the mod", os.path.join(target, "Scripts", "core", "sandbox.lua"), b"-- other\n", "every file of the package is in")
    rejects("an unknown file in the mod folder", os.path.join(target, "modules", "stray.lua"), b"--\n", "besides the package only")
    rejects("a changed settings file of the player", os.path.join(target, "modules", "repopulate", "Scripts", "config.lua"), b"return {}\n", "The player's own files that were there before")
    rejects("a changed save", os.path.join(inst.SAVES, "Save0.sav"), b"other", "the save folder is unchanged")
    rejects("another UE4SS.dll", os.path.join(inst.UE4SS, "UE4SS.dll"), b"another build", "UE4SS.dll is the AngelScript Fix 0.4 build")
    if os.path.isfile(os.path.join(target, "modules", "repopulate", SETTINGS_EXE)):
        rejects("another settings app than before", os.path.join(target, "modules", "repopulate", SETTINGS_EXE), b"MZ another", "the settings app is the one that was there")
    if os.path.isfile(inst.SHORTCUT):
        rejects("a changed desktop shortcut", inst.SHORTCUT, read(inst.SHORTCUT) + b" ", "the desktop shortcut is as it was")
    for m in going[:1] + going[-1:]:
        a_file = sorted(files_of(kept_tree, m))[0].replace("/", os.sep)
        marker = [k for k in files_of(kept_tree, m) if k.lower() in ("scripts/main.lua", "dlls/main.dll")][0].replace("/", os.sep)
        rejects("an incomplete copy of the retired %s" % m, os.path.join(bdir, "retired", m, a_file), None, "the copy of %s in the backup folder" % m)
        rejects("%s back in Mods" % m, os.path.join(inst.MODS, m, marker), b"--\n", "%s (-> module %s)" % (m, w["module_of"][m]))
    if obsolete:
        rejects("a missing copy of a removed file", os.path.join(bdir, "removed", obsolete[0].replace("/", os.sep)), None, "the files that are gone from the folder")
        rejects("a removed file that is back", os.path.join(target, obsolete[0].replace("/", os.sep)), b"back\n", "besides the package only")
    if report["replaced"]:
        rejects("a missing old version of a replaced file", os.path.join(bdir, "replaced", report["replaced"][0].replace("/", os.sep)), None, "every file of the folder that was replaced")
    if has_exp:
        cfg = os.path.join(target, "modules", "xp", "Scripts", "config.lua")
        rejects("a carried-over value that is not in our settings file", cfg, xp_text.replace(b"Config.Multiplier = 4.0", b"Config.Multiplier = 1.0"), "settings carried over, EXPModifier -> modules/xp")
        rejects("a converted settings file with another change in it", cfg, xp_text.replace(b"Config.Enabled = true", b"Config.Enabled = false"), "settings carried over, EXPModifier -> modules/xp")
        rep = read_json(os.path.join(bdir, "install-report.json"))
        for c in rep["conversions"]:
            c["from"] = {k: "0" * 64 for k in c.get("from", {})}
        rejects("carried-over values that were not read from the retired mod's file", os.path.join(bdir, "install-report.json"), json.dumps(rep).encode("utf-8"), "and those values were read from")
    rep = read_json(os.path.join(bdir, "install-report.json"))
    rep["ok"], rep["problems"] = False, ["something"]
    rejects("an installer report with a problem", os.path.join(bdir, "install-report.json"), json.dumps(rep).encode("utf-8"), "the installer's report")
    rejects("a run that left no report (it did not finish)", os.path.join(bdir, "install-report.json"), None, "the backup folder has the installer's baseline and report")
    acode, aout = run_audit(aud)
    check(acode == 0 and "AUDIT OK (" in aout and tree(inst.MODS) == after, "and with everything put back it passes again: %s" % last_line(aout))

    # ================= a second run right after the first
    snapshot = tree(sim)
    code, out = run(inst)
    check(code == 0 and "NOTHING TO DO" in out and "0 added, 0 replaced" in out and "retire:" not in out and tree(sim) == snapshot,
          "a second run right after the first: nothing to do, nothing created or changed - not even a backup folder (%s)" % last_line(out)[:90])
    code, out = run(inst, "--check")
    check(code == 0 and "CHECK ONLY" in out and ("installed: version %s (its file list: the report in %s)" % (NEW_VERSION, os.path.basename(bdir))) in out and tree(sim) == snapshot,
          "and --check now names the new version as installed, with its file list from the update's own report")

    version_file = os.path.join(target, "Scripts", "core", "version.lua")
    saved = read(version_file)
    write(version_file, saved.replace(('"%s"' % NEW_VERSION).encode("ascii"), ('"%s"' % installed_version).encode("ascii")))       # as if somebody had put the old version back by hand
    code, out = run(inst, "--check")
    write(version_file, saved)
    check(code == 0 and ("installed: version %s (" % installed_version) in out and "its file list: the report in" not in out,
          "a folder that is not the version the last run installed: that run's report is not taken for its file list")

    # ---- the updated mod starts and does every job (last here: a session writes its diagnostics files)
    line = start_mod(target)
    if line is not None:
        check(load_line(inst, files) in line and "errors: 0 ok: true" in line and ("v%s loaded" % NEW_VERSION) in line,
              "started in a mock UE4SS: version %s loads every module although mods.txt still names the retired mods (%s)" % (NEW_VERSION, line.strip().splitlines()[0][:230]))
        if known:
            said_at_load = [l[len("printed: "):] for l in line.splitlines() if l.startswith("printed: ")]
            lacking = [PLAYER[m][0] for m in known if not any(LOAD_LINES[PLAYER[m][0]] in l for l in said_at_load)]
            check(not lacking and not [l for l in said_at_load if "is not usable" in l or "has an error" in l or "config.lua" in l],
                  "and the five modules start with his settings - each says so in its own load line (regen: \"%s\"), none complains about its config.lua%s"
                  % (LOAD_LINES["regen"][len("loaded: "):], "" if not lacking else " - NOT AS EXPECTED: " + " | ".join(l.strip() for l in said_at_load if any(("G1R_%s]" % x.capitalize()) in l for x in lacking))))

    # ================= the rollback script, with every PowerShell
    rb = read(os.path.join(bdir, "ROLLBACK-megamod-install.ps1"))
    check(all(c < 128 for c in rb) and b"\r\n" in rb and b"\n" not in rb.replace(b"\r\n", b"") and b"[string]$Only = ''" in rb
          and not re.search(rb"\?\?|\?\.|&&|\|\||-Parallel|Get-FileHash \$| \? .* : ", rb.replace(b"# SHA-256 through .NET: Get-FileHash is not found", b"")),
          "the rollback script is plain ASCII with CRLF line ends, has the -Only parameter and uses nothing that Windows PowerShell 5.1 does not know (no ??, ?., &&, ||, ?:, Get-FileHash)")
    for shell in shells:
        inst = build_pc_world(real=real)
        w = world_facts(inst)
        target = os.path.join(inst.MODS, inst.NAME)
        code, out = run(inst)
        bdir = last_backup(inst)
        script = os.path.join(bdir, "ROLLBACK-megamod-install.ps1")
        added = sorted(r for r in manifest if r not in w["was"] and r != "enabled.txt")
        cfg = os.path.join(target, "modules", "xp", "Scripts", "config.lua")
        if has_exp:
            write(cfg, read(cfg).replace(b"Config.Multiplier = 4.0", b"Config.Multiplier = 6.0"))       # the player turned it up after the update
        rc, text = rollback(shell, inst, script)
        check(code == 0 and rc == 0 and tree(inst.MODS) == w["mods"] and (read(inst.SHORTCUT) if os.path.isfile(inst.SHORTCUT) else None) == w["lnk"] and "Rollback finished." in text,
              "[%s] rollback of the update: the Mods folder is exactly as before the run - every retired mod back, the megamod's replaced and removed files back, the added ones gone (%s)"
              % (shell[0], text.strip().splitlines()[-1][:60] if text.strip() else rc))
        taken = files_of(tree(bdir), "taken-out")
        check(sorted(taken) == added and all(taken[r] == manifest[r] for r in added if r not in converted) and os.path.isfile(os.path.join(bdir, "rolled-back.txt"))
              and (not has_exp or b"Config.Multiplier = 6.0" in read(os.path.join(bdir, "taken-out", "modules", "xp", "Scripts", "config.lua")))
              and all(taken.get(rel) == sha_of(text) for rel, text in expected.items()),
              "[%s] what the update had added is kept in the backup folder (%d files): the settings file the player changed since as he last had it, the other %d converted ones as written"
              % (shell[0], len(added), len(expected)))
        rc, text = rollback(shell, inst, script)
        check(rc == 0 and text.count("already; left as it is.") == len(going) and tree(inst.MODS) == w["mods"], "[%s] run again: nothing to do, nothing changed" % shell[0])
        code, again = run(inst, "--check")
        check(code == 0 and again == plan_text, "[%s] after the rollback the installer plans the same update again (the rolled-back run does not count as the installed one)" % shell[0])

        # ---- only one of the retired mods back
        if not going:
            continue
        only = "EXPModifier" if "EXPModifier" in going else going[0]
        inst = build_pc_world(real=real)
        w = world_facts(inst)
        code, out = run(inst)
        bdir = last_backup(inst)
        script = os.path.join(bdir, "ROLLBACK-megamod-install.ps1")
        state = tree(inst.MODS)
        rc, text = rollback(shell, inst, script, "-Only", only.lower())
        back = tree(inst.MODS)
        check(rc == 0 and under(back, only) == under(w["mods"], only) and without(back, only) == state and ("Only %s was put back" % only) in text
              and (read(inst.SHORTCUT) if os.path.isfile(inst.SHORTCUT) else None) == w["lnk"] and os.path.isfile(os.path.join(bdir, "put-back-%s.txt" % only))
              and not os.path.exists(os.path.join(bdir, "rolled-back.txt")) and "Rollback finished" not in text,
              "[%s] rollback -Only %s (any case): that mod is back exactly as it was, and nothing else changed - the megamod with the converted settings stays" % (shell[0], only.lower()))
        acode, aout = run_audit(load_audit(inst))
        check(acode == 0 and ("%s (-> module %s): retired by the run and put back afterwards with the rollback script's -Only: in Mods again, every file as before" % (only, w["module_of"][only])) in aout,
              "[%s] the audit of that run accepts the mod that was put back on purpose: %s" % (shell[0], last_line(aout)))
        line = start_mod(target)
        if line is not None:
            check(load_line(inst, files, {w["module_of"][only]: only}) in line and "errors: 0 ok: true" in line,
                  "[%s] the megamod then leaves that one job to the mod and does the others (%s)" % (shell[0], line.strip().splitlines()[0][:200]))
        snapshot = tree(inst.MODS)
        rc, text = rollback(shell, inst, script, "-Only", "HUDMap")
        check(rc != 0 and "is not one of the mods this run retired" in text and "Nothing changed." in text and tree(inst.MODS) == snapshot,
              "[%s] -Only with a mod this run did not retire: refused, nothing changed" % shell[0])
        rc, text = rollback(shell, inst, script, "-Only", only)
        check(rc == 0 and "already; left as it is." in text and tree(inst.MODS) == snapshot, "[%s] -Only for a mod that is back already: nothing to do" % shell[0])
        if shell is shells[0]:
            before = tree(sim)
            code, out = run(inst)
            check(code == 0 and ("left alone: Mods\\%s (The player put it back with the rollback script of %s (-Only); --retire %s retires it again)" % (only, os.path.basename(bdir), only)) in out
                  and "NOTHING TO DO" in out and tree(sim) == before,
                  "a later run of the installer leaves a mod alone that the player put back, and says so")
            code, out = run(inst, "--retire", only)
            check(code == 0 and "DONE:" in out and not os.path.exists(os.path.join(inst.MODS, only)) and ("retired: Mods\\%s" % only) in out
                  and under(tree(os.path.join(last_backup(inst), "retired")), only) == under(w["mods"], only)
                  and (not has_exp or read(os.path.join(inst.MODS, inst.NAME, "modules", "xp", "Scripts", "config.lua")) == xp_text)
                  and not os.path.exists(os.path.join(last_backup(inst), "replaced")),
                  "--retire %s retires it again; the settings converted the first time are as the installer wrote them and stay" % only)



# ---------------------------------------------------------------------------------------------
# Part "cases": what can be different, and what can go wrong
# ---------------------------------------------------------------------------------------------
def part_cases(shells):
    sim = ARGS.sim
    shell = shells[0] if shells else None
    files = package_files(*NEW)
    manifest = {rel: sha_of(data) for rel, data in files.items()}
    default_xp = files["modules/xp/Scripts/config.lua"]
    xp_text = expected_xp(default_xp)
    third = [e[0] for e in load_installer().TAKEOVERS if e[0] not in OWN]

    def cfg(inst, module):
        return os.path.join(inst.MODS, inst.NAME, "modules", module, "Scripts", "config.lua")

    def ini(inst):
        return os.path.join(inst.MODS, "EXPModifier", "EXPModifier.ini")

    def gone(inst, names):
        return all(not os.path.exists(os.path.join(inst.MODS, m)) for m in names)

    def busy(name):
        real_rename = os.rename

        def rename(a, b):
            if os.path.basename(a) == name:
                raise PermissionError(13, "The process cannot access the file because it is being used by another process (test)", a)
            return real_rename(a, b)
        return patched(os, "rename", rename)

    # ================= a mod that is not installed, a mod that is switched off
    def tweak(i):
        wipe(os.path.join(i.MODS, "G1R_WaitOnT"))
        os.remove(os.path.join(i.MODS, "EXPModifier", "enabled.txt"))
        write(os.path.join(i.MODS, "mods.txt"), read(os.path.join(i.MODS, "mods.txt")).replace(b"EXPModifier : 1", b"EXPModifier : 0"))
    inst = build_pc_world(tweak=tweak)
    target = os.path.join(inst.MODS, inst.NAME)
    w = world_facts(inst)
    code, out = run(inst)
    bdir = last_backup(inst)
    report = read_json(os.path.join(bdir, "install-report.json"))
    states = {t["mod"]: t["state"] for t in report["takeovers"]}
    check(code == 0 and "not installed, nothing to do: G1R_Repopulate, NPCMarkers, G1R_WaitOnT" in out and "G1R_WaitOnT" not in os.listdir(os.path.join(bdir, "retired"))
          and states["G1R_WaitOnT"] == "absent" and "retire: Mods\\G1R_WaitOnT" not in out,
          "a mod of the table that is not installed: nothing to do for it, and the plan says so")
    check(("retire: Mods\\EXPModifier (%d files, disabled)" % len(files_of(w["mods"], "EXPModifier"))) in out
          and "note: EXPModifier is disabled: its settings are not carried over (its job was switched off; the module xp starts with its defaults)" in out
          and "settings: Mods\\EXPModifier" not in out and gone(inst, ["EXPModifier"]) and states["EXPModifier"] == "retired"
          and under(tree(os.path.join(bdir, "retired")), "EXPModifier") == under(w["mods"], "EXPModifier") and read(cfg(inst, "xp")) == default_xp,
          "a mod that is installed but switched off is retired too (The player asked to replace it), but its settings are not carried over: the module keeps its defaults, and the plan says so")
    if shell:
        rc, text = rollback(shell, inst, os.path.join(bdir, "ROLLBACK-megamod-install.ps1"), "-Only", "EXPModifier")
        line = start_mod(target)
        check(rc == 0 and under(tree(inst.MODS), "EXPModifier") == under(w["mods"], "EXPModifier") and "NOTE: EXPModifier has no enabled.txt and mods.txt has no line" in text
              and (line is None or (load_line(inst, files) in line and "errors: 0 ok: true" in line)),
              "[%s] put back with -Only it is switched off as before (the script says so), and the megamod keeps doing that job" % shell[0])

    # ================= a file of a mod is open in another program: that mod stays, the rest goes on
    inst = build_pc_world()
    target = os.path.join(inst.MODS, inst.NAME)
    w = world_facts(inst)
    with busy("BetterMining"):
        code, out = run(inst)
    after = tree(inst.MODS)
    bdir = last_backup(inst)
    report = read_json(os.path.join(bdir, "install-report.json"))
    told = {t["mod"]: t for t in report["takeovers"]}
    rest = [m for m in third if m != "BetterMining"]
    check(code == 1 and "BetterMining is in use" in out and "it was left in place and keeps its job" in out and under(after, "BetterMining") == under(w["mods"], "BetterMining")
          and gone(inst, rest) and not [k for k in after if ".retired-" in k] and all(("retired: Mods\\%s (" % m) in out for m in rest)
          and files_of(after, inst.NAME)["Scripts/core/version.lua"] == manifest["Scripts/core/version.lua"] and read(cfg(inst, "xp")) == xp_text,
          "a mod with scripts\\main.lua whose folder is in use stays in place, complete; the megamod is updated and the other five are retired (%s)" % last_line(out))
    check(report["ok"] is False and told["BetterMining"]["state"] == "kept" and told["BetterMining"]["why"] == "it is in use" and report["status"]["BetterMining"] == "kept"
          and sorted(report["retired"]) == sorted(rest) and any("BetterMining is in use" in p for p in report["problems"]) and "PROBLEMS:" in out,
          "and the report says so: not ok, that mod kept because it is in use, the others retired")
    aud = load_audit(inst)
    acode, aout = run_audit(aud)
    failed = [l for l in aout.splitlines() if l.startswith("FAIL")]
    check(acode == 1 and len(failed) == 1 and "the installer's report" in failed[0] and "BetterMining is in use" in failed[0]
          and "ok   BetterMining (-> module mining): still in Mods, every file as before" in aout and "and the report says so: it is in use" in aout,
          "the audit finds the mod that stayed unchanged and reported; the one thing it does not accept is that the installer reported a problem")
    line = start_mod(target)
    if line is not None:
        check(load_line(inst, files, {"mining": "BetterMining"}) in line and "errors: 0 ok: true" in line,
              "in that state every job is done exactly once: the megamod leaves mining to BetterMining (%s)" % line.strip().splitlines()[0][:200])
    code, out = run(inst)
    check(code == 0 and "retire: Mods\\BetterMining (" in out and out.count("retire: Mods\\") == 1 and "0 added, 0 replaced" in out and gone(inst, ["BetterMining"])
          and under(tree(os.path.join(last_backup(inst), "retired")), "BetterMining") == under(w["mods"], "BetterMining"),
          "the next run, when nothing holds the folder any more, retires just that mod")

    # ---- the mod's folder changes while the installer runs: the copy is not what was planned, the mod stays
    inst = build_pc_world()
    w = world_facts(inst)
    real_copy_tree = inst.copy_tree

    def meddling(src, dst):
        real_copy_tree(src, dst)
        if os.path.basename(src) == "G1R_MageBalance":             # ... right after its copy was made: the copy is complete, the folder is newer
            write(os.path.join(src, "Scripts", "config.lua"), b"return { Enabled = false } -- changed after the copy was made\n")
    inst.copy_tree = meddling
    code, out = run(inst)
    check(code == 1 and "G1R_MageBalance: the copy in the backup folder is not identical to the folder; it was left in place" in out
          and os.path.isfile(os.path.join(inst.MODS, "G1R_MageBalance", "Scripts", "main.lua")) and gone(inst, [m for m in third if m != "G1R_MageBalance"])
          and "G1R_MageBalance was left in place but is not as it was" in out,
          "a mod whose files changed while the installer ran is not removed (the folder too, not only the copy, is compared with what was recorded before the run), and the change is reported")

    # ---- the megamod's own files do not come out as planned: the installer notices by itself, and retires nothing
    inst = build_pc_world()
    w = world_facts(inst)
    real_write, real_remove = inst.write_file, inst._remove_file

    def cut_short(dst, data):
        return real_write(dst, data[:-20] if dst.endswith(os.path.join("xp", "Scripts", "config.lua")) else data)

    def not_really(path):
        if os.path.basename(path) != "old_helper.lua":
            real_remove(path)
    inst.write_file, inst._remove_file = cut_short, not_really
    code, out = run(inst)
    after = tree(inst.MODS)
    check(code == 1 and "modules/xp/Scripts/config.lua is not the converted settings file" in out and "modules/markers/Scripts/old_helper.lua of the old version is still there" in out
          and "the separate mods were NOT retired because of the problem(s) above" in out and all(under(after, m) == under(w["mods"], m) for m in third),
          "a converted settings file that did not reach the disk whole, an old file that is still there: the installer's own check finds both, and no mod is retired")

    # ---- a mod folder spelt in another case (Windows does not tell them apart)
    def other_case(i):
        os.rename(os.path.join(i.MODS, "EXPModifier"), os.path.join(i.MODS, "expmodifier"))
    inst = build_pc_world(tweak=other_case)
    mods_before = tree(inst.MODS)
    code, out = run(inst)
    bdir = last_backup(inst)
    told = {t["mod"]: t for t in read_json(os.path.join(bdir, "install-report.json"))["takeovers"]}
    check(code == 0 and "retire: Mods\\expmodifier (" in out and not os.path.exists(os.path.join(inst.MODS, "expmodifier"))
          and under(tree(os.path.join(bdir, "retired")), "expmodifier") == under(mods_before, "expmodifier") and read(cfg(inst, "xp")) == xp_text
          and told["EXPModifier"]["folder"] == "expmodifier" and told["EXPModifier"]["state"] == "retired" and told["EXPModifier"]["enabled"] is True,
          "a mod folder spelt in another case than the table's is found (and found switched on through mods.txt, which spells it differently), converted and retired under the name it has on disk")
    acode, aout = run_audit(load_audit(inst))
    check(acode == 0 and "EXPModifier (-> module xp): retired" in aout, "and the audit finds it the same way (%s)" % last_line(aout))
    if shell:
        rc, text = rollback(shell, inst, os.path.join(bdir, "ROLLBACK-megamod-install.ps1"), "-Only", "EXPModifier")
        check(rc == 0 and under(tree(inst.MODS), "expmodifier") == under(mods_before, "expmodifier") and "Only expmodifier was put back" in text,
              "[%s] and -Only puts it back, whatever case the name is given in" % shell[0])

    # ---- what makes a folder a mod is removed first
    unit = os.path.join(sim, "unit", "SomeMod")
    made = {}
    for rel in ("enabled.txt", "Scripts/main.lua", "Scripts/aaa.lua", "Scripts/zzz.lua", "Scripts/sub/a.lua", "scripts/main.lua", "scripts/other.lua", "scripts/sub/b.lua",
                "dlls/main.dll", "dlls/aaa.dll", "dlls/sub/c.bin", "aaa.ini", "sub/deep/file.bin"):      # a sub folder in each: without the rule, something of it would go before the marker
        write(os.path.join(unit, rel.replace("/", os.sep)), rel.encode("ascii"))
    for base, _, names in os.walk(unit):
        for n in names:
            made[os.path.relpath(os.path.join(base, n), unit).replace(os.sep, "/")] = True
    markers = sorted(r for r in made if r.lower() in ("enabled.txt", "scripts/main.lua", "dlls/main.dll"))
    order = []
    real_remove = inst._remove_file

    def noting(path):
        order.append(os.path.relpath(path, unit).replace(os.sep, "/"))
        return real_remove(path)
    inst._remove_file = noting
    inst.remove_tree(unit)
    inst._remove_file = real_remove
    check(sorted(order[:len(markers)]) == markers and len(markers) >= 3 and sorted(order) == sorted(made) and not os.path.exists(unit),
          "what makes a folder a mod is removed before anything else of it: enabled.txt, Scripts\\main.lua in either spelling, dlls\\main.dll (%d files, then the other %d)"
          % (len(markers), len(made) - len(markers)))

    # ================= an entry whose module is not in the package: its mod is left alone
    nowait = variant(NEW, "nowait", drop=("modules/wait/",))
    inst = build_pc_world(new=nowait)
    target = os.path.join(inst.MODS, inst.NAME)
    w = world_facts(inst)
    code, out = run(inst)
    after = tree(inst.MODS)
    check(code == 0 and "DONE:" in out and "left alone: Mods\\G1R_WaitOnT (the package has no module wait)" in out and "retire: Mods\\G1R_WaitOnT" not in out
          and under(after, "G1R_WaitOnT") == under(w["mods"], "G1R_WaitOnT") and w["staying"] == ["G1R_WaitOnT"] and gone(inst, w["going"]) and len(w["going"]) == 5
          and not os.path.exists(os.path.join(target, "modules", "wait")),
          "a mod whose module is not in the package is left alone, untouched (the package may be built before every module is finished); the others are retired")
    acode, aout = run_audit(load_audit(inst))
    check(acode == 0 and "AUDIT OK" in aout and "G1R_WaitOnT (-> module wait): still in Mods, every file as before" in aout and "and the report says so: the package has no module wait" in aout,
          "the audit accepts that: still in Mods, unchanged, and the report says why (%s)" % last_line(aout))
    line = start_mod(target)
    if line is not None:
        check(load_line(inst, package_files(*nowait), {"wait": "G1R_WaitOnT"}) in line and "errors: 0 ok: true" in line, "and the megamod leaves that job to the mod (%s)" % line.strip().splitlines()[0][:200])

    # ================= the settings of EXPModifier in other states
    inst = build_pc_world(tweak=lambda i: write(ini(i), b"ExpMultiplier=fast\r\nShowBonusMessage=maybe\r\nDebug=on\r\nthis line is nothing\r\n"))
    w = world_facts(inst)
    code, out = run(inst)
    bdir = last_backup(inst)
    check(code == 0 and read(cfg(inst, "xp")) == default_xp.replace(b"Config.LogGains = false\n", b"Config.LogGains = true\n")
          and "modules\\xp\\Scripts\\config.lua: LogGains = true\n" in out and "ExpMultiplier=fast (is not a number)" in out and "ShowBonusMessage=maybe (is not true or false)" in out
          and "MessageDurationSeconds (is not in EXPModifier.ini)" in out and "line 4 (this line is nothing) (is not a key=value line)" in out
          and gone(inst, ["EXPModifier"]) and read(os.path.join(bdir, "retired", "EXPModifier", "EXPModifier.ini")).startswith(b"ExpMultiplier=fast"),
          "a broken EXPModifier.ini: what can be read is carried over (LogGains), every value that cannot is named with its reason, the mod is retired and its file is in the backup folder")
    inst = build_pc_world(tweak=lambda i: write(ini(i), b"\x00\x01\x02\xff" * 20))
    before = tree(sim)
    code, out = run(inst, "--check")
    write(ini(inst), b"just some words\nand some more\n")
    code2, out2 = run(inst, "--check")
    check(code == 0 and "settings: Mods\\EXPModifier: not carried over: EXPModifier.ini (is not a text file)" in out and "-> G1R_MegaMod\\modules\\xp" not in out
          and code2 == 0 and "settings: Mods\\EXPModifier: not carried over: EXPModifier.ini (has no key=value line)" in out2 and "-> G1R_MegaMod\\modules\\xp" not in out2,
          "an EXPModifier.ini that is no ini at all (binary, or words without key=value): the converter says it could not read it, nothing is carried over")
    os.remove(ini(inst))
    code, out = run(inst)
    check(code == 0 and "settings: Mods\\EXPModifier: not carried over: EXPModifier.ini (not found)" in out and read(cfg(inst, "xp")) == default_xp and gone(inst, ["EXPModifier"])
          and read(cfg(inst, "general")) == files["modules/general/Scripts/config.lua"],
          "no EXPModifier.ini at all: said in the plan, the modules xp and general keep their default settings, the mod is retired")
    mine = b"-- mine\nlocal Config = {}\nConfig.Multiplier = 2.5\nreturn Config\n"
    inst = build_pc_world(tweak=lambda i: write(cfg(i, "xp"), mine))
    code, out = run(inst)
    bdir = last_backup(inst)
    report = read_json(os.path.join(bdir, "install-report.json"))
    conv = [c for c in report["conversions"] if c["module"] == "xp"]
    check(code == 0 and read(cfg(inst, "xp")) == mine
          and "modules\\xp\\Scripts\\config.lua: NOT written, the file was changed by the player (it would get: Multiplier = 4.0, LogGains = true)" in out
          and "kept: modules/xp/Scripts/config.lua (The player's own; differs from the package's)" in out and gone(inst, ["EXPModifier"])
          and len(conv) == 1 and conv[0]["state"] == "player" and "modules/xp/Scripts/config.lua" not in report["written"] and "modules/xp/Scripts/config.lua" not in report["replaced"],
          "our config.lua already changed by the player: it is never overwritten - the conversion is skipped, the plan says so and what it would have set; the mod is retired all the same")
    acode, aout = run_audit(load_audit(inst))
    check(acode == 0 and "settings NOT carried over, EXPModifier -> modules/xp/Scripts/config.lua: the file the player had changed is as before" in aout, "and the audit confirms the player's file is as before")
    inst = build_pc_world()
    with busy("EXPModifier"):
        code, out = run(inst)                   # converted, but EXPModifier itself could not be retired
    first = read(cfg(inst, "xp"))
    write(ini(inst), read(ini(inst)).replace(b"ExpMultiplier=4.0", b"ExpMultiplier=5.0"))       # ... and the player changes it once more
    code2, out2 = run(inst)
    bdir = last_backup(inst)
    check(code == 1 and first == xp_text and code2 == 0 and read(cfg(inst, "xp")) == xp_text.replace(b"Config.Multiplier = 4.0", b"Config.Multiplier = 5.0")
          and "modules\\xp\\Scripts\\config.lua: Multiplier = 5.0, LogGains = true" in out2 and gone(inst, ["EXPModifier"])
          and read(os.path.join(bdir, "replaced", "modules", "xp", "Scripts", "config.lua")) == xp_text,
          "a config.lua that is still as the installer wrote it counts as untouched: a later run writes it again with the mod's newest values (the earlier text goes to the backup folder)")
    inst = build_pc_world()
    with busy("EXPModifier"):
        run(inst)
    changed = xp_text.replace(b"Config.Multiplier = 4.0", b"Config.Multiplier = 3.0")
    write(cfg(inst, "xp"), changed)             # the player lowers it in the settings app; then the mod can be retired
    code, out = run(inst)
    check(code == 0 and read(cfg(inst, "xp")) == changed and "NOT written, the file was changed by the player" in out and gone(inst, ["EXPModifier"]),
          "but once the player changed it after that, it is the player's: not written again")
    inst = build_pc_world(tweak=lambda i: write(ini(i), read(ini(i)).replace(b"ExpMultiplier=4.0", b"ExpMultiplier=25").replace(b"MessageDurationSeconds=3", b"MessageDurationSeconds=7.4")))
    code, out = run(inst)
    check(code == 0 and "Multiplier = 10.0 (was 25; the range is 0 to 10)" in out and "modules\\general\\Scripts\\config.lua: NoteSeconds = 7 (was 7.4; rounded)" in out
          and read(cfg(inst, "xp")) == xp_text.replace(b"Config.Multiplier = 4.0", b"Config.Multiplier = 10.0")
          and read(cfg(inst, "general")) == files["modules/general/Scripts/config.lua"].replace(b"Config.NoteSeconds = 3\n", b"Config.NoteSeconds = 7\n"),
          "values outside our schema's range are pulled inside and whole-number settings rounded (both said in the plan); one converter sets keys of two modules")

    # ================= the settings of the five other mods in other states, on the PC as a whole
    # (every mapping and every rule of the five converters is checked in the part "convert", on files written for the case)
    inst = build_pc_world()
    if not all(is_snapshot(tree(inst.MODS), m) for m in FIVE):
        NOTES.append("part cases: the mock does not have the player's files of 2026-10-01 for all five mods: the cases with changed, out-of-range, broken and missing files of theirs are left out")
    else:
        def theirs(i, mod):
            return os.path.join(i.MODS, mod, SNAPSHOT[mod][0].replace("/", os.sep))

        def change(i, mod, old, new):
            data = read(theirs(i, mod))
            if data.count(old) != 1:
                raise SystemExit("the case cannot be set up: %r is in %s of %s %d times" % (old, SNAPSHOT[mod][0], mod, data.count(old)))
            write(theirs(i, mod), data.replace(old, new))

        def all_five(i, changes):
            for mod, old, new in changes:
                change(i, mod, old, new)

        def texts(i):
            return {m: read(cfg(i, PLAYER[m][0])) for m in FIVE}

        # ---- a value the player changed since the snapshot
        changed = (("G1R_RegenMana", b"ManaPercentPerTick=2", b"ManaPercentPerTick=3.5", {"ManaPercent": "3.5"}, "ManaPercent = 3.5"),
                   ("G1R_WaitOnT", b"local WAIT_HOURS = 0.5", b"local WAIT_HOURS = 1", {"ShortMinutes": "60"}, "ShortMinutes = 60 (its WAIT_HOURS = 1)"),
                   ("BetterMining", b"StrPerOre=4", b"StrPerOre=5", {"StrengthPerOre": "5.0"}, "StrengthPerOre = 5.0"),
                   ("SkillfulLocks", b'skilled   = "auto"', b"skilled   = 1", {"SkilledConnections": '"1"'}, 'SkilledConnections = "1"'),
                   ("G1R_MageBalance", b'FireBallProjectileDefinition", damage = 1.25,', b'FireBallProjectileDefinition", damage = 1.5,', {"FireBallDamage": "1.5"}, "FireBallDamage = 1.5"))
        inst = build_pc_world(tweak=lambda i: all_five(i, [c[:3] for c in changed]))
        w = world_facts(inst)
        code, out = run(inst)
        bdir = last_backup(inst)
        got = texts(inst)
        wrong = [m for m, _, new, values, said in changed if got[m] != player_text(files, m, values) or got[m] == player_text(files, m) or said not in out
                 or new not in read(os.path.join(bdir, "retired", m, SNAPSHOT[m][0].replace("/", os.sep)))]
        check(code == 0 and not wrong and gone(inst, FIVE) and all(under(tree(os.path.join(bdir, "retired")), m) == under(w["mods"], m) for m in FIVE),
              "a value the player changed in each of the five mods since 2026-10-01 (mana 3.5 %%, a wait of one hour, 5 Strength per ore, skilled = 1, fire ball x1.5): the files are read "
              "as they are - each config.lua of ours has the new value, the plan names it, the mods are retired with their files in the backup folder%s" % ("" if not wrong else " - WRONG: " + ", ".join(wrong)))
        acode, aout = run_audit(load_audit(inst))
        check(acode == 0 and aout.count("settings carried over, ") == 6 and "FireBallDamage = 1.5" in aout, "and the audit confirms the six converted files of that run (%s)" % last_line(aout))

        # ---- a value outside our range
        outside = (("G1R_RegenMana", b"ManaMaxRegenPercentage=75", b"ManaMaxRegenPercentage=175", {"ManaUpTo": "100"}, "ManaUpTo = 100 (was 175; the range is 0 to 100)"),
                   ("G1R_WaitOnT", b"local COOLDOWN_SECONDS = 2", b"local COOLDOWN_SECONDS = 120", {"Cooldown": "60.0"}, "Cooldown = 60.0 (was 120; the range is 0 to 60)"),
                   ("BetterMining", b"AgiPerOre=6", b"AgiPerOre=600", {"DexterityPerOre": "200.0"}, "DexterityPerOre = 200.0 (was 600; the range is 0 to 200)"),
                   ("SkillfulLocks", b'master    = "all"', b"master    = 7", {"MasterConnections": '"safe"'}, 'MasterConnections = "safe" (was 7: our module offers no fixed number above 2;'),
                   ("G1R_MageBalance", b'FireRainDefinition",           damage = 2.5,', b'FireRainDefinition",           damage = 25,', {"FireRainDamage": "10.0"},
                    "FireRainDamage = 10.0 (was 25; the range is 0.1 to 10)"))
        inst = build_pc_world(tweak=lambda i: all_five(i, [c[:3] for c in outside]))
        code, out = run(inst)
        got = texts(inst)
        wrong = [m for m, _, _, values, said in outside if got[m] != player_text(files, m, values) or said not in out]
        check(code == 0 and not wrong and gone(inst, FIVE),
              "a value outside our range in each of the five (175 %%, 120 seconds, 600 points per ore, 7 connections, damage x25): each is pulled to the nearest value our module takes "
              "(100, 60, 200, \"safe\", 10), and the plan says so%s" % ("" if not wrong else " - WRONG: " + ", ".join(wrong)))

        # ---- broken files
        def broken(i):
            write(theirs(i, "G1R_RegenMana"), b"\x00\x01\x02\xff" * 40)
            change(i, "G1R_WaitOnT", b"local WAIT_HOURS = 0.5", b"local WAIT_HOURS = 0.25 * 2")
            change(i, "BetterMining", b"StrPerOre=4", b"StrPerOre=abc")
            write(theirs(i, "SkillfulLocks"), b"return {\n    removeConnections = {\n")
            change(i, "G1R_MageBalance", b"    Enabled = true,", b"    Enabled = isEnabled(),")
        inst = build_pc_world(tweak=broken)
        w = world_facts(inst)
        code, out = run(inst)
        bdir = last_backup(inst)
        got = texts(inst)
        default = {m: files[config_rel(PLAYER[m][0])] for m in FIVE}
        check(code == 0 and got["G1R_RegenMana"] == default["G1R_RegenMana"] and got["SkillfulLocks"] == default["SkillfulLocks"] and got["G1R_MageBalance"] == default["G1R_MageBalance"]
              and got["G1R_WaitOnT"] == player_text(files, "G1R_WaitOnT")
              and got["BetterMining"] == with_values(default["BetterMining"], {"EndlessVeins": "true", "ShowMessage": "false"})
              and "settings: Mods\\G1R_RegenMana: not carried over: G1R_RegenMana.ini (is not a text file)" in out
              and "settings: Mods\\SkillfulLocks: not carried over: Scripts\\config.lua (could not be read as plain values (" in out
              and "settings: Mods\\G1R_MageBalance: not carried over: Scripts\\config.lua (could not be read as plain values (" in out
              and "StrPerOre=abc (is not a number)" in out and "its formula for the ore of a swing (" in out
              and "note: G1R_WaitOnT\\Scripts\\main.lua does not name WAIT_HOURS in the form known from version 1.0.0: taken as that version has it (WAIT_HOURS = 0.5)" in out
              and gone(inst, FIVE) and all(under(tree(os.path.join(bdir, "retired")), m) == under(w["mods"], m) for m in FIVE),
              "broken files of the five - bytes that are no text, a calculation where a number stood, a word for a number, a file cut off, a file that calls a function: nothing that "
              "cannot be read is carried over (regen, locks, magic keep their defaults; mining keeps the game's ore per swing; wait takes the known 30 minutes), the plan says "
              "what and why, nothing of those files is run, and the mods are retired with the broken files in the backup folder")
        acode, aout = run_audit(load_audit(inst))
        check(acode == 0 and "AUDIT OK" in aout, "the audit accepts that run (%s)" % last_line(aout))

        # ---- no settings file at all
        def no_files(i):
            for mod in ("G1R_RegenMana", "BetterMining", "SkillfulLocks", "G1R_MageBalance"):
                os.remove(theirs(i, mod))
        inst = build_pc_world(tweak=no_files)
        code, out = run(inst)
        got = texts(inst)
        check(code == 0 and all(got[m] == default[m] for m in FIVE if m != "G1R_WaitOnT") and got["G1R_WaitOnT"] == player_text(files, "G1R_WaitOnT")
              and "settings: Mods\\G1R_RegenMana: not carried over: G1R_RegenMana.ini (not found)" in out and "settings: Mods\\BetterMining: not carried over: BetterMining.ini (not found)" in out
              and "settings: Mods\\SkillfulLocks: not carried over: Scripts\\config.lua (not found)" in out and "settings: Mods\\G1R_MageBalance: not carried over: Scripts\\config.lua (not found)" in out
              and gone(inst, FIVE) and out.count("retire: Mods\\") == 6,
              "a mod without its settings file: said in the plan, nothing is carried over for it - the module keeps its default settings - and the mod is retired all the same "
              "(G1R_WaitOnT never had one: its values come from its script)")

        # ---- our config.lua of each of the five modules already changed by the player
        mine = {m: ("-- my own %s settings\nlocal Config = {}\nConfig.Enabled = true\nreturn Config\n" % PLAYER[m][0]).encode("ascii") for m in FIVE}
        inst = build_pc_world(tweak=lambda i: [write(cfg(i, PLAYER[m][0]), mine[m]) for m in FIVE])
        code, out = run(inst)
        bdir = last_backup(inst)
        report = read_json(os.path.join(bdir, "install-report.json"))
        states = {c["mod"]: c["state"] for c in report["conversions"] if c["mod"] in FIVE}
        check(code == 0 and texts(inst) == mine and states == {m: "player" for m in FIVE} and sorted(report["written"]) == ["modules/xp/Scripts/config.lua"]
              and out.count("NOT written, the file was changed by the player") == 5 and "it would get: ShortKey = \"Y\")" in out and "it would get 37 values:\n      WholeMana = false" in out
              and all(("kept: %s (The player's own; differs from the package's)" % config_rel(PLAYER[m][0])) in out for m in FIVE) and gone(inst, FIVE)
              and not [r for r in report["replaced"] if r.endswith("/config.lua")],
              "a config.lua of ours the player already changed - in each of the five modules: none is overwritten; the plan says so for each and lists what it would have got; "
              "the mods are retired all the same, with their settings files in the backup folder")
        acode, aout = run_audit(load_audit(inst))
        check(acode == 0 and aout.count("settings NOT carried over, ") == 5 and "settings NOT carried over, G1R_MageBalance -> modules/magic/Scripts/config.lua: the file the player had changed is as before" in aout,
              "and the audit confirms for each of the five that the player's file is as before (%s)" % last_line(aout))

    # ================= the converter framework, with a module and a mod made for the test
    simtest = variant(NEW, "simtest", put=dict(standin_files("simtest"), **{"Scripts/core/modules.lua": with_modules(
        files["Scripts/core/modules.lua"], ['    { name = "simtest", switch = "SimTest", separate = { "SimTestMod" } },'])}))

    def convert_simtest(their):
        a, b = their.ini("settings.ini"), their.lua("Scripts/config.lua")
        return {"simtest": {"Enabled": a.boolean("On"), "Amount": a.number("Amount"), "Count": b.number("limits.count"), "Mode": b.text("mode"), "Name": a.text("Name"),
                            "Key": a.text("Hotkey"), "Secret": b.number("secret"), "Quiet": b.number("quiet"), "Nope": a.number("Amount"), "Push": b.boolean("flag")},
                "general": {"NoteSeconds": a.number("Seconds"), "NoteStyle": b.text("style"), "NotePosition": b.text("corner")},
                "nomodule": {"X": a.number("Amount")}}

    def boom(their):
        their.ini("settings.ini")
        raise KeyError("a mistake in the mapping")

    def tweak(i):
        mod = os.path.join(i.MODS, "SimTestMod")
        write(os.path.join(mod, "Scripts", "main.lua"), b"-- a mod made for the test\n")
        write(os.path.join(mod, "enabled.txt"), b"")
        write(os.path.join(mod, "settings.ini"), b"On=no\nAmount=12.345\nName=say \"hi\" \\ there\nHotkey=ctrl + y\nSeconds=9\nUnused=1\n")
        write(os.path.join(mod, "Scripts", "config.lua"), b'return { limits = { count = 3.6 }, mode = "all", secret = 42, quiet = 5, flag = true, style = "hologram", corner = "bottom left", extra = { 1, 2 } }\n')
    inst = build_pc_world(new=simtest, tweak=tweak)
    table = inst.TAKEOVERS
    before = tree(sim)
    code, out = run(inst, "--check")
    check(code == 0 and "note: SimTestMod is installed and the package's module simtest stands down for it, but it is not in this installer's table: left as it is" in out
          and "Mods\\SimTestMod" not in out and tree(sim) == before,
          "a mod the package's loader stands down for but the installer's table does not have: said in the plan, left as it is")
    inst.TAKEOVERS = table + (("SimTestMod", "lua", "simtest", boom),)
    before = tree(sim)
    code, out = run(inst, "--check")
    check(code == 0 and "settings: Mods\\SimTestMod: not carried over: everything (THE CONVERTER FAILED (KeyError: 'a mistake in the mapping'))" in out
          and "retire: Mods\\SimTestMod (" in out and tree(sim) == before,
          "a mistake inside a converter does not take the installer down: the plan says the converter failed and that nothing of that mod is carried over")
    inst.TAKEOVERS = table + (("SimTestMod", "lua", "simtest", convert_simtest),)
    code, out = run(inst)
    default = (STANDIN_CONFIG % {"name": "simtest"}).encode("ascii")
    want = (default.replace(b"Config.Enabled = true", b"Config.Enabled = false").replace(b"Config.Amount = 1.5", b"Config.Amount = 10.0").replace(b"Config.Count = 3", b"Config.Count = 4")
            .replace(b'Config.Mode = "auto"', b'Config.Mode = "all"').replace(b'Config.Name = ""', b'Config.Name = "say \\"hi\\" \\\\ there"')
            .replace(b'Config.Key = ""\n', b'Config.Key = "CTRL+Y"\nConfig.Secret = 42\n'))
    check(code == 0 and read(cfg(inst, "simtest")) == want and gone(inst, ["SimTestMod"])
          and read(cfg(inst, "general")) == files["modules/general/Scripts/config.lua"].replace(b'Config.NotePosition = "top right"', b'Config.NotePosition = "bottom left"'),
          "a converter for a made-up mod (an ini and a Lua file) fills a module's config.lua: a switch, a number, a whole number, a choice, a text with quotes and a backslash, "
          "a key in its usual spelling, a setting without a line of its own (added below the last line; not added when it has its default), and a key of a second module")
    answer = lua_oracle([("patch", default, b"Enabled", b"false")])
    if answer is not None:
        text = answer[0]
        for key, value in ((b"Amount", b"10.0"), (b"Count", b"4"), (b"Mode", b'"all"'), (b"Name", b'"say \\"hi\\" \\\\ there"'), (b"Key", b'"CTRL+Y"'), (b"Secret", b"42")):
            text = lua_oracle([("patch", text, key, value)])[0]
        check(text == want, "and that file is byte for byte what the game's own code makes of the default file with these seven values")
    check("Amount = 10.0 (was 12.345; the range is 0 to 10)" in out and "Count = 4 (was 3.6; rounded)" in out and 'Key = "CTRL+Y" (was written ctrl + y)' in out
          and "      Secret = 42\n      (our default already: Quiet = 5)\n" in out and "modules\\simtest\\Scripts\\config.lua: 7 values\n      Enabled = false\n" in out
          and "simtest.Nope = 12.345 (the module simtest has no setting Nope)" in out and "simtest.Push = true (is not a setting that holds a value)" in out
          and "general.NoteSeconds = 9 (general.NoteSeconds is set from EXPModifier already)" in out and "general.NoteStyle = hologram (is not one of: box, subtitle, off)" in out
          and "nomodule.X = 12.345 (the package has no module nomodule)" in out and "Unused=1; extra.1=1; extra.2=2 (all 3: not looked at by the converter)" in out,
          "the plan names what was changed on the way (range, rounding, spelling) and everything that was not carried over with its reason: a key our module does not have, "
          "a button, a key another mod set already, an unknown choice, a module that is not in the package, values the converter did not look at")
    acode, aout = run_audit(load_audit(inst, table=[(e[0], e[1], e[2]) for e in inst.TAKEOVERS]))
    check(acode == 0 and "settings carried over, SimTestMod -> modules/simtest/Scripts/config.lua: the file is the package's default with Enabled = false" in aout and "(1 line(s) added)" in aout
          and "SimTestMod (-> module simtest): retired" in aout, "the audit follows the table it is given: the made-up mod is retired, its converted settings are in place (%s)" % last_line(aout))

    # ================= --settings-app
    new_app = os.path.join(sim, "Other", "NewSettings.exe")
    inst = build_pc_world(tweak=lambda i: write(new_app, b"MZ the settings app, built today"))
    target = os.path.join(inst.MODS, inst.NAME)
    w = world_facts(inst)
    exe = os.path.join(target, "modules", "repopulate", SETTINGS_EXE)
    old_app = read(exe)
    code, out = run(inst, "--settings-app", new_app)
    bdir = last_backup(inst)
    report = read_json(os.path.join(bdir, "install-report.json"))
    check(code == 0 and read(exe) == b"MZ the settings app, built today" and read(os.path.join(bdir, "replaced", "modules", "repopulate", SETTINGS_EXE)) == old_app
          and report["settings_app"] == {"source": new_app, "sha256": sha_of(read(new_app)), "bytes": 32, "state": "replace", "installed": True, "previous_sha256": sha_of(old_app)}
          and ("settings app: %s -> G1R_MegaMod\\modules\\repopulate\\%s (32 bytes, sha256 %s...; the installed one goes to the backup folder)" % (new_app, SETTINGS_EXE, sha_of(read(new_app))[:16])) in out
          and ("settings app: installed (sha256 %s...)" % sha_of(read(new_app))[:16]) in out and read(new_app) == b"MZ the settings app, built today",
          "--settings-app: the given program is installed as the module's settings app and verified, the old one is in the backup folder, the report has both hashes")
    aud = load_audit(inst)
    acode, aout = run_audit(aud)
    check(acode == 0 and "the settings app is the one given to the installer" in aout and "and the one that was there is in the backup folder" in aout, "the audit checks it (%s)" % last_line(aout))
    make_rejects(inst, aud)("a settings app that is not the one given", exe, b"MZ something else", "the settings app is the one given to the installer")
    snapshot = tree(sim)
    code, out = run(inst, "--settings-app", new_app)
    check(code == 0 and "the installed one is the same already" in out and "NOTHING TO DO" in out and tree(sim) == snapshot, "the same program given again: nothing to do")
    if shell:
        rc, text = rollback(shell, inst, os.path.join(bdir, "ROLLBACK-megamod-install.ps1"))
        check(rc == 0 and tree(inst.MODS) == w["mods"] and read(os.path.join(inst.MODS, inst.NAME, "modules", "repopulate", SETTINGS_EXE)) == old_app,
              "[%s] the rollback puts the old settings app back (and everything else)" % shell[0])

    # ================= the first install of the new version on a PC that has all eight mods
    inst = build_world(pkg=NEW, others=third + list(STAYING))
    write(new_app, b"MZ the settings app, built today")
    target = os.path.join(inst.MODS, inst.NAME)
    w = world_facts(inst)
    markers_23 = b"NPCMarkers 2.3 configuration" in read(os.path.join(inst.MODS, "NPCMarkers", "Scripts", "config.lua"))[:4096]
    code, out = run(inst, "--settings-app", new_app)
    after = tree(inst.MODS)
    ours = files_of(after, inst.NAME)
    bdir = last_backup(inst)
    copied = {"modules/repopulate/Scripts/config.lua": "G1R_Repopulate/Scripts/config.lua", "modules/repopulate/Scripts/state/profile_0.lua": "G1R_Repopulate/Scripts/state/profile_0.lua"}
    if markers_23:
        copied["modules/markers/Scripts/config.lua"] = "NPCMarkers/Scripts/config.lua"
    special = dict({dst: w["mods"][src.replace("/", os.sep)] for dst, src in copied.items()}, **{"modules/xp/Scripts/config.lua": sha_of(xp_text),
                   "modules/repopulate/" + SETTINGS_EXE: sha_of(b"MZ the settings app, built today")})
    for m in FIVE:                              # the player's files of 2026-10-01 become what is known; another file: what the run reports
        rel = config_rel(PLAYER[m][0])
        special[rel] = sha_of(player_text(files, m)) if is_snapshot(w["mods"], m) else read_json(os.path.join(bdir, "install-report.json"))["written"].get(rel, manifest[rel])
    wrong = [r for r in manifest if r not in special and ours.get(r) != manifest[r]]
    check(code == 0 and "first install" in out and "DONE:" in out and not wrong and all(ours.get(r) == h for r, h in special.items()) and sorted(set(ours) - set(manifest)) == sorted(set(special) - set(manifest))
          and gone(inst, w["going"]) and len(w["going"]) == 8 and sorted(os.listdir(os.path.join(bdir, "retired"))) == sorted(w["going"])
          and without(after, inst.NAME) == without(w["mods"], *w["going"]),
          "a first install of the new version on a PC with all eight mods: package in place, our own two mods' files copied, the settings of the six other mods converted, the given "
          "settings app (not the old mod's) installed, all eight retired, nothing else changed (%s)" % last_line(out))
    now = inst.shortcut_read(inst.SHORTCUT)
    check(now is not None and inst.same_path(now["target"], os.path.join(target, "modules", "repopulate", SETTINGS_EXE)), "and the desktop shortcut starts the settings app inside the megamod")
    acode, aout = run_audit(load_audit(inst))
    check(acode == 0 and "mode install" in aout and aout.count(": retired - gone from Mods") == 8, "audit after that install: %s" % last_line(aout))
    if shell:
        rc, text = rollback(shell, inst, os.path.join(bdir, "ROLLBACK-megamod-install.ps1"))
        check(rc == 0 and tree(inst.MODS) == w["mods"] and read(inst.SHORTCUT) == w["lnk"] and tree(os.path.join(bdir, "removed-" + inst.NAME)) == under(after, inst.NAME),
              "[%s] rollback of a first install: all eight mods back, the megamod gone (a copy of it in the backup folder), the shortcut as before" % shell[0])

    def exp_off(i):
        os.remove(os.path.join(i.MODS, "EXPModifier", "enabled.txt"))
        write(os.path.join(i.MODS, "mods.txt"), read(os.path.join(i.MODS, "mods.txt")).replace(b"EXPModifier : 1", b"EXPModifier : 0"))
    inst = build_world(pkg=NEW, others=third + list(STAYING))
    exp_off(inst)
    before = tree(sim)
    code, out = run(inst, "--check")
    check(code == 0 and "first install" in out and "note: EXPModifier is disabled: its settings are not carried over" in out and "settings: Mods\\EXPModifier" not in out
          and ", disabled) -> backup folder" in out and "copy: Mods\\G1R_Repopulate\\Scripts\\config.lua" in out and tree(sim) == before,
          "on a first install too, a mod of another author that is switched off is retired without its settings being carried over")

    # ================= where the installed version's file list comes from
    inst = build_pc_world(tweak=lambda i: wipe(os.path.join(i.WS, MORNING)))
    code, out = run(inst)
    check(code == 0 and "installed: version 0.1.1 (its file list: the manifest G1R_MegaMod-0.1.1-dev-manifest.sha256)" in out and ("%d of the old version removed" % len(OBSOLETE)) in out
          and not any(os.path.exists(os.path.join(inst.MODS, inst.NAME, r.replace("/", os.sep))) for r in OBSOLETE),
          "without the backup folder of the earlier run the installed version's file list comes from its manifest in the package folder: the old files are removed all the same")

    def no_record(i):
        wipe(os.path.join(i.WS, MORNING))
        os.remove(os.path.join(i.PKGDIR, i.manifest_name(OLD_PACKAGE)))
    inst = build_pc_world(tweak=no_record)
    code, out = run(inst)
    acode, aout = run_audit(load_audit(inst))
    check(code == 0 and "its file list is not known" in out and "files that only the old version had stay where they are" in out and "removed:" not in out
          and all(os.path.isfile(os.path.join(inst.MODS, inst.NAME, r.replace("/", os.sep))) for r in OBSOLETE) and acode == 0,
          "without any record of what the installed version brought, nothing is removed (said in the plan); the audit accepts those files as there before")

    # ================= a later update (to the version after the new one), with another package than the default one
    parts = NEW_VERSION.split(".")
    LATER = ".".join(parts[:-1] + [str(int(parts[-1]) + 1)])
    later_name = "G1R_MegaMod-%s-dev.zip" % LATER

    def later(f):
        f["Scripts/core/version.lua"] = f["Scripts/core/version.lua"].replace(('"%s"' % NEW_VERSION).encode("ascii"), ('"%s"' % LATER).encode("ascii"))
        f["README.txt"] += ("\nnew in %s\n" % LATER).encode("ascii")
        del f["modules/general/README.txt"]
        f["modules/xp/extra.txt"] = b"a file the next version adds\n"
        f["modules/xp/Scripts/config.lua"] = f["modules/xp/Scripts/config.lua"].replace(b"-- Experience multiplier", b"-- Experience multiplier, second edition")
    later_pkg = variant(NEW, "later", name=later_name, change=later)
    later_files = package_files(*later_pkg)
    inst = build_pc_world()
    target = os.path.join(inst.MODS, inst.NAME)
    w = world_facts(inst)
    code, out = run(inst, "--keep", "expmodifier", "--keep", "G1R_RegenMana")
    after = tree(inst.MODS)
    check(code == 0 and "left alone: Mods\\EXPModifier (--keep EXPModifier)" in out and "left alone: Mods\\G1R_RegenMana (--keep G1R_RegenMana)" in out
          and under(after, "EXPModifier") == under(w["mods"], "EXPModifier") and under(after, "G1R_RegenMana") == under(w["mods"], "G1R_RegenMana")
          and gone(inst, [m for m in third if m not in ("EXPModifier", "G1R_RegenMana")]) and read(cfg(inst, "xp")) == default_xp and "settings: Mods\\EXPModifier" not in out
          and "note: EXPModifier and G1R_RegenMana installed as separate mod(s) and left in place" in out and "The separate mods are still in place" in out,
          "--keep MOD (any case, repeatable): those mods are left alone - not retired, their settings not read; the others are retired")
    state = tree(inst.MODS)
    line = start_mod(target)
    if line is not None:
        check(load_line(inst, files, {"xp": "EXPModifier", "regen": "G1R_RegenMana"}) in line and "errors: 0 ok: true" in line,
              "the megamod's loader sees a kept mod with scripts\\main.lua and a kept native mod (dlls\\main.dll, on only through mods.txt) and leaves their jobs to them")
        wipe(sim)
        inst = build_pc_world()
        run(inst, "--keep", "EXPModifier", "--keep", "G1R_RegenMana")
        state = tree(inst.MODS)
    for n in (later_pkg[1], inst.manifest_name(later_pkg[1])):
        shutil.copy2(os.path.join(later_pkg[0], n), os.path.join(inst.PKGDIR, n))
    earlier = os.path.basename(last_backup(inst))
    code, out = run(inst, "--package", os.path.join(inst.PKGDIR, later_pkg[1]))
    bdir = last_backup(inst)
    report = read_json(os.path.join(bdir, "install-report.json"))
    ours = files_of(tree(inst.MODS), inst.NAME)
    later_xp = expected_xp(later_files["modules/xp/Scripts/config.lua"])
    check(code == 0 and ("package: %s, version %s, %d files" % (later_name, LATER, len(later_files))) in out
          and ("installed: version %s (its file list: the report in %s)" % (NEW_VERSION, earlier)) in out and "files: 1 added, 2 replaced, " in out and "1 of the old version removed" in out
          and "    removed: modules/general/README.txt" in out and ours["modules/xp/extra.txt"] == sha_of(b"a file the next version adds\n") and "modules/general/README.txt" not in ours
          and ('"%s"' % LATER).encode("ascii") in read(os.path.join(target, "Scripts", "core", "version.lua")) and report["version"] == LATER and report["installed_version"] == NEW_VERSION
          and report["removed"] == ["modules/general/README.txt"] and report["package"] == later_name,
          "a later update with --package: %s -> %s replaces what differs, adds the new file and removes the one file the new version dropped, by the earlier run's own report" % (NEW_VERSION, LATER))
    check(read(cfg(inst, "xp")) == later_xp and later_xp != xp_text and gone(inst, ["EXPModifier", "G1R_RegenMana"])
          and "modules\\xp\\Scripts\\config.lua: Multiplier = 4.0, LogGains = true" in out
          and read(os.path.join(bdir, "replaced", "modules", "xp", "Scripts", "config.lua")) == default_xp,
          "the kept mods are retired by that run; the module's config.lua, still the default file of the installed version, becomes the new version's default file with the values put in")
    acode, aout = run_audit(load_audit(inst))
    check(acode == 0 and ("it is version %s" % LATER) in aout and ("the package in the project folder is the one that was installed (%s" % later_name) in aout,
          "the audit takes package and version from the report and the manifest, not from constants: %s" % last_line(aout))
    if shell:
        rc, text = rollback(shell, inst, os.path.join(bdir, "ROLLBACK-megamod-install.ps1"))
        check(rc == 0 and tree(inst.MODS) == state, "[%s] rollback of that update: exactly the state before it again - the two mods back, the dropped file back, the added one gone, the settings file as it was" % shell[0])

    # ---- never leave a job to nobody: a module the player switched off, a megamod that is switched off itself
    def switch_off(i):
        path = os.path.join(i.MODS, i.NAME, "Scripts", "config.lua")
        write(path, read(path).replace(b"Markers = true", b"Markers = true, Xp = false"))
    inst = build_pc_world(tweak=switch_off)
    target = os.path.join(inst.MODS, inst.NAME)
    w = world_facts(inst)
    code, out = run(inst)
    after = tree(inst.MODS)
    check(code == 0 and b"Xp = false" in read(os.path.join(target, "Scripts", "config.lua"))
          and "left alone: Mods\\EXPModifier (the module xp is switched off in G1R_MegaMod\\Scripts\\config.lua (Xp = false): nothing would do the mod's job; --retire EXPModifier retires it all the same)" in out
          and under(after, "EXPModifier") == under(w["mods"], "EXPModifier") and gone(inst, [m for m in third if m != "EXPModifier"]) and "settings: Mods\\EXPModifier" not in out
          and read(cfg(inst, "xp")) == default_xp,
          "a module the player switched off in the megamod's config.lua: the mod that does that job today is left alone (said in the plan), the others are retired")
    line = start_mod(target)
    if line is not None:
        check(load_line(inst, files, off=("xp",)) in line and "errors: 0 ok: true" in line, "and the megamod keeps that module off (%s)" % line.strip().splitlines()[0][:150])
    code, out = run(inst, "--retire", "EXPModifier")
    check(code == 0 and gone(inst, ["EXPModifier"]) and "retire: Mods\\EXPModifier (" in out and read(cfg(inst, "xp")) == xp_text, "--retire MOD retires it all the same, with its settings carried over")

    def megamod_off(i):
        os.remove(os.path.join(i.MODS, i.NAME, "enabled.txt"))
    inst = build_pc_world(tweak=megamod_off)
    w = world_facts(inst)
    code, out = run(inst)
    after = tree(inst.MODS)
    check(code == 0 and "DONE:" in out and out.count("left alone: Mods\\") == 6 and "(G1R_MegaMod itself is switched off (no enabled.txt, no line in mods.txt): nothing would do the mod's job;" in out
          and "retire:" not in out and all(under(after, m) == under(w["mods"], m) for m in third) and not os.path.exists(os.path.join(inst.MODS, inst.NAME, "enabled.txt"))
          and files_of(after, inst.NAME)["Scripts/core/version.lua"] == manifest["Scripts/core/version.lua"],
          "a megamod that is switched off itself (no enabled.txt, not in mods.txt) is updated, its enabled.txt is not put back, and no mod is retired: nothing would do their jobs")
    write(os.path.join(inst.MODS, "mods.txt"), read(os.path.join(inst.MODS, "mods.txt")) + b"g1r_megamod : 1\r\n")        # the mod manager lists it
    code, out = run(inst)
    check(code == 0 and gone(inst, third) and out.count("retire: Mods\\") == 6 and not os.path.exists(os.path.join(inst.MODS, inst.NAME, "enabled.txt")),
          "once mods.txt switches the megamod on (a mod manager's way), the next run retires them")

    # ---- settings carried over again without retiring (--sync-settings)
    inst = build_pc_world()
    run(inst, "--keep", "EXPModifier")
    write(ini(inst), read(ini(inst)).replace(b"ExpMultiplier=4.0", b"ExpMultiplier=3.0").replace(b"MessageDurationSeconds=3", b"MessageDurationSeconds=7"))
    for n in (later_pkg[1], inst.manifest_name(later_pkg[1])):
        shutil.copy2(os.path.join(later_pkg[0], n), os.path.join(inst.PKGDIR, n))
    before = tree(sim)
    code, out = run(inst, "--sync-settings", "--package", os.path.join(inst.PKGDIR, later_pkg[1]))
    check(code == 0 and ("note: the package is version %s, installed is %s: settings of other authors' mods are not converted (run an update first)" % (LATER, NEW_VERSION)) in out
          and "NOTHING TO DO" in out and tree(sim) == before,
          "--sync-settings with a package of another version than the installed one converts nothing (the settings files belong to their version), and says so")
    mods_mid = tree(inst.MODS)
    code, out = run(inst, "--sync-settings")
    now = tree(inst.MODS)
    changed = sorted(k for k in set(mods_mid) | set(now) if mods_mid.get(k) != now.get(k))
    check(code == 0 and "settings and progress are copied again" in out and read(cfg(inst, "xp")) == xp_text.replace(b"Config.Multiplier = 4.0", b"Config.Multiplier = 3.0")
          and read(cfg(inst, "general")) == files["modules/general/Scripts/config.lua"].replace(b"Config.NoteSeconds = 3\n", b"Config.NoteSeconds = 7\n")
          and changed == [os.path.join(inst.NAME, "modules", m, "Scripts", "config.lua") for m in ("general", "xp")] and "retire:" not in out and "left alone" not in out,
          "--sync-settings: the settings of a mod that is still installed are converted again into the config.lua files that are still untouched; nothing else changes, nothing is retired")

    # ---- the package without the dev kit over an installed one that had it
    plain = variant(NEW, "plain", drop=("dev/",), name="G1R_MegaMod-%s.zip" % NEW_VERSION)
    inst = build_pc_world(new=plain)
    w = world_facts(inst)
    dev = sorted(r for r in w["was"] if r.startswith("dev/"))
    code, out = run(inst)
    bdir = last_backup(inst)
    ours = files_of(tree(inst.MODS), inst.NAME)
    check(code == 0 and len(dev) > 20 and not [r for r in ours if r.startswith("dev/")] and not os.path.exists(os.path.join(inst.MODS, inst.NAME, "dev"))
          and ("%d of the old version removed" % (len(dev) + len(OBSOLETE) - 1)) in out and ("removed: ... and %d more (all in the report)" % (len(dev) + len(OBSOLETE) - 1 - 12)) in out
          and all(files_of(tree(bdir), "removed").get(r) == w["was"][r] for r in dev),
          "a package without the dev kit over an installed version that had it: the %d dev files go (copies in the backup folder), with their folders" % len(dev))
    if shell:
        rc, text = rollback(shell, inst, os.path.join(bdir, "ROLLBACK-megamod-install.ps1"))
        check(rc == 0 and tree(inst.MODS) == w["mods"], "[%s] and the rollback brings every one of them back" % shell[0])

    # ================= removing fails part-way: what is left is not a mod - for scripts\main.lua and for a native mod too
    inst = build_pc_world()
    w = world_facts(inst)
    real_remove = inst._remove_file

    def stuck_remove(path):
        if os.path.basename(path) in ("BetterMining.ini", "G1R_RegenMana.ini"):
            raise PermissionError(13, "Access is denied (test)", path)
        return real_remove(path)
    inst._remove_file = stuck_remove
    code, out = run(inst)
    inst._remove_file = real_remove
    bdir = last_backup(inst)
    left = {m: os.path.join(inst.MODS, m + ".retired-tmp") for m in ("BetterMining", "G1R_RegenMana")}
    kept_tree = tree(os.path.join(bdir, "retired"))
    check(code == 1 and out.count("removing failed part-way") == 2 and all(os.path.isdir(d) for d in left.values()) and gone(inst, third)
          and sorted(files_of(tree(inst.MODS), "BetterMining.retired-tmp")) == ["BetterMining.ini"] and sorted(files_of(tree(inst.MODS), "G1R_RegenMana.retired-tmp")) == ["G1R_RegenMana.ini"]
          and all(under(kept_tree, m) == under(w["mods"], m) for m in left),
          "removing two retired mods failed part-way: reported; of the mod with scripts\\main.lua and of the native mod only the stuck file is left - main.lua, main.dll and "
          "enabled.txt went first, so UE4SS starts neither; their complete copies are in the backup folder")
    before = tree(sim)
    code, out = run(inst)
    check(isinstance(code, str) and "BetterMining.retired-tmp exists (left over from an interrupted run)" in code and code.endswith("Nothing changed.") and tree(sim) == before,
          "the next run refuses until the left-over is looked at")

    # ================= refusals with the new package: nothing changed
    def refusal(text, prepare, expect, *argv):
        inst = build_pc_world()
        prepare(inst)
        before = tree(sim)
        code, out = run(inst, *argv)
        check(isinstance(code, str) and expect in code and code.endswith("Nothing changed.") and tree(sim) == before, "refused, nothing changed: %s" % text)

    refusal("the game runs", lambda i: setattr(i, "running_images", lambda: ["g1r-win64-shipping.exe"]), "The game is running")
    refusal("the mod manager runs", lambda i: setattr(i, "running_images", lambda: ["explorer.exe", "iskllauncher.app.exe"]), "The mod manager is running")
    refusal("the settings app runs", lambda i: setattr(i, "running_images", lambda: ["g1r_repopulate_settings.exe"]), "The settings app is running")
    refusal("another UE4SS.dll", lambda i: write(os.path.join(i.UE4SS, "UE4SS.dll"), b"other"), "not the expected build")

    def tamper(i):
        src = os.path.join(i.PKGDIR, i.PACKAGE)
        with zipfile.ZipFile(src) as zf:
            items = [(info, zf.read(info)) for info in zf.infolist()]
        with zipfile.ZipFile(src, "w", zipfile.ZIP_DEFLATED) as zf:
            for info, data in items:
                zf.writestr(info, data + (b"\n-- changed" if info.filename.endswith("modules/xp/Scripts/main.lua") else b""))
    refusal("a package that does not match its manifest", tamper, "does not match the manifest")
    refusal("a package without its manifest", lambda i: os.remove(os.path.join(i.PKGDIR, i.manifest_name(i.PACKAGE))), "Package file missing")

    def other_list(text):
        def prepare(i):
            f = package_files(i.PKGDIR, i.PACKAGE)
            f["Scripts/core/modules.lua"] = text(f["Scripts/core/modules.lua"])
            make_package(i.PKGDIR, i.PACKAGE, f)
        return prepare
    refusal("a package whose module list does not name the mod its module replaces (the loader would not stand down for it)",
            other_list(lambda t: t.replace(b'separate = { "EXPModifier" }', b"separate = { }")), "does not name EXPModifier as a separate mod of the module xp")
    refusal("a package whose module list cannot be read as plain values", other_list(lambda t: t.replace(b"return {", b"return list({", 1) + b")"), "cannot be read")
    refusal("--settings-app with a file that is not there", lambda i: None, "is not a file", "--settings-app", os.path.join(sim, "nothing.exe"))
    refusal("--settings-app with a file that is no program", lambda i: write(os.path.join(sim, "Other", "notes.exe"), b"just text"), "is not a Windows program",
            "--settings-app", os.path.join(sim, "Other", "notes.exe"))
    refusal("--sync-settings together with --settings-app", lambda i: write(os.path.join(sim, "Other", "a.exe"), b"MZ"), "do not go together", "--sync-settings", "--settings-app", os.path.join(sim, "Other", "a.exe"))
    refusal("--keep with a mod that is not in the table", lambda i: None, "--keep HUDMap: not one of the mods this installer replaces", "--keep", "HUDMap")
    refusal("--keep and --retire for the same mod", lambda i: None, "--keep and --retire name the same mod", "--keep", "EXPModifier", "--retire", "expmodifier")
    refusal("a left-over folder of another author's mod from an interrupted run", lambda i: os.makedirs(os.path.join(i.MODS, "EXPModifier.retired-tmp")), "EXPModifier.retired-tmp exists")

    # ================= the installer and the loader read mods.txt alike
    samples = [
        b"NPCMarkers : 1\r\n", b"NPCMarkers : 0\r\n", b"NPCMarkers:1\n", b"  NPCMarkers   :   1  \n", b"; NPCMarkers : 1\n", b"NPCMarkers : 1 ; note\n",
        b"NPCMarkers\t: 1\n", b"NPCMarkers : 0 : 1\n", b"NPCMarkers : 1 : 0\n", b"NPCMarkers : 10\n", b"NPCMarkers : 01\n", b"NPCMarkersX : 1\n", b"XNPCMarkers : 1\n",
        b"\xef\xbb\xbfNPCMarkers : 1\n", b"NPCMarkers\n", b"NPCMarkers :\n", b"NPCMarkers : true\n", b"npcmarkers : 1\n", b"Other : 1\nNPCMarkers : 1", b"NPCMarkers : 0\nNPCMarkers : 1\n",
        b"", b"\n\n: 1\n", b":NPCMarkers : 1\n", b"NPC Markers : 1\n", b"NPCMARKERS:1\r\n", b"nPcMaRkErS : 1", b"NPCMarkers : 1\r", b"a:1\r\n", b"NPCM\xc4rkers : 1\n", b"NPCMarkers : 1\r\r\n",
    ]
    if LUA:
        inst = build_pc_world()
        target = os.path.join(inst.MODS, inst.NAME)
        run(inst)
        write(os.path.join(inst.MODS, "NPCMarkers", "Scripts", "main.lua"), b"-- a separate mod without enabled.txt\n")
        differ = []
        for text in samples:
            write(os.path.join(inst.MODS, "mods.txt"), text)
            line = start_mod(target)
            lua_says = "markers left to the separate mod NPCMarkers" in line
            py_says = inst.mods_txt_enables(text.decode("latin-1"), "NPCMarkers")
            if lua_says != py_says or "errors: 0 ok: true" not in line:
                differ.append((text, lua_says, py_says))
        on = sum(1 for text in samples if inst.mods_txt_enables(text.decode("latin-1"), "NPCMarkers"))
        check(not differ and 0 < on < len(samples), "%d mods.txt texts: the installer and the new version's loader agree on whether UE4SS starts a mod, names in any case (%d on, %d off)%s"
              % (len(samples), on, len(samples) - on, "" if not differ else " - differ: %r" % differ[:3]))



def main():
    global ARGS, WORK, NEW, NEW_VERSION, OLDX
    ap = argparse.ArgumentParser(description="Mock-install tests for install_megamod.py and audit_megamod.py.")
    ap.add_argument("--pkg", required=True, help="folder with the 0.1.1 package (the version installed on the PC now) and its manifest")
    ap.add_argument("--new-pkg", help="folder with the new version's package and manifest (default: built from --mod-src)")
    ap.add_argument("--mod-src", default="G1R_MegaMod", help="the mod's source folder, for building the new package (it is copied, never changed)")
    ap.add_argument("--sim", default="/tmp/sim-megamod", help="folder for the mock install (removed and rebuilt; <sim>-work next to it too)")
    ap.add_argument("--part", default="first,rules,convert,update,cases", help="which parts to run: first, rules, convert, update, cases (comma separated; default all)")
    ap.add_argument("--repop-src", default="research/re-toolspop/mod/G1R_Repopulate")
    ap.add_argument("--markers-src", default="<cloud home>/mod/NPCMarkers")
    ap.add_argument("--as-is", action="store_true", help="the two sources above are installed folders: copy them as they are")
    ap.add_argument("--mods-txt", help="a mods.txt to use in the mock")
    ap.add_argument("--mods-json", help="a mods.json to use in the mock")
    ap.add_argument("--fixtures", default="<cloud home>/crash/mods", help="folder with the real folders of the other authors' mods (stand-ins where one is missing)")
    ap.add_argument("--regen-ini", default="research/thirdparty/G1R_RegenMana.ini", help="The player's G1R_RegenMana.ini for the mock of that native mod")
    ap.add_argument("--pc-mods", help="rehearsal: a real Mods folder; part update runs on a copy of it instead of the built mock")
    ap.add_argument("--pc-backup", help="rehearsal: the backup folder of the earlier install, copied into the mock's project folder")
    ap.add_argument("--fail-fast", action="store_true", help="stop at the first failed check")
    ap.add_argument("--show-plan", action="store_true", help="part update: print the plan (--check) the installer makes for the mock of the PC")
    ARGS = ap.parse_args()
    parts = [p.strip() for p in ARGS.part.split(",") if p.strip()]
    unknown = [p for p in parts if p not in ("first", "rules", "convert", "update", "cases")]
    if unknown:
        raise SystemExit("unknown part: %s" % ", ".join(unknown))
    WORK = ARGS.sim.rstrip("/\\") + "-work"
    wipe(WORK)
    os.makedirs(WORK)
    shells = find_shells()
    for s in shells:
        print("note " + s[0])
    if not shells:
        print("note no PowerShell: the rollback script is not run")
    if not LUA:
        print("note no Lua: the installed mod is not started, and the rules are not compared with the game's own code")
    print("note shortcut calls: %s" % ("Windows Script Host" if WINDOWS else "stand-ins"))
    if set(parts) - {"first"}:
        table = [(e[0], e[1], e[2]) for e in load_installer().TAKEOVERS]
        NEW = build_new_package(table)
        NEW_VERSION = re.search(rb'version\s*=\s*"([^"]+)"', package_files(*NEW)["Scripts/core/version.lua"]).group(1).decode("ascii")
        OLDX = variant((ARGS.pkg, OLD_PACKAGE), "old", put=dict(OBSOLETE, **OLD_PLAYERS))
        print("note new package: %s (version %s, %s)" % (NEW[1], NEW_VERSION, "given" if ARGS.new_pkg else "built from a temp copy of %s" % ARGS.mod_src))
    counts = []
    for name, run_part in (("first", lambda: part_first(shells)), ("rules", part_rules), ("convert", part_convert), ("update", lambda: part_update(shells)),
                           ("cases", lambda: part_cases(shells))):
        if name in parts:
            before = oks + fails
            run_part()
            counts.append("%s %d" % (name, oks + fails - before))
    for note in NOTES:
        print("note " + note)
    print("note checks per part: %s" % ", ".join(counts))
    print("%d checks, %d failed" % (oks + fails, fails))
    print("ALL OK" if fails == 0 else "FAILURES")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
