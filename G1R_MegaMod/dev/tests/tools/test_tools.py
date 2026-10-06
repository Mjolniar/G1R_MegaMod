#!/usr/bin/env python3
"""Tests of the dev tools (dev/tools/*.py, dev/run_tests.py).

    python dev/tests/tools/test_tools.py

Everything is built in a temp folder (G1R_TEST_TMP or the system temp folder).
With G1R_SAMPLES=<folder> the tools are also run against real material: the
folder holds crash report folders (crash-*/ with CrashContext.runtime-xml) and
UE4SS logs; without it those checks are skipped and that is said.
Last line: `tools tests finished: N ok, M failure(s)`; exit code 0 / 1.
"""
import contextlib
import hashlib
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(os.path.dirname(HERE))
ROOT = os.path.dirname(DEV)
sys.path.insert(0, os.path.join(DEV, "tools"))
sys.path.insert(0, DEV)

import build_release  # noqa: E402
import crashtriage    # noqa: E402
import diagread       # noqa: E402
import lint           # noqa: E402
import loganalyze     # noqa: E402
import run_tests      # noqa: E402

TMP = os.path.join(os.environ.get("G1R_TEST_TMP") or os.path.join(tempfile.gettempdir(), "g1r-tests"), "tools")
LUA = os.environ.get("G1R_LUA") or shutil.which("lua5.4") or shutil.which("lua")
LUAC = os.environ.get("G1R_LUAC") or shutil.which("luac5.4") or shutil.which("luac")
SAMPLES = os.environ.get("G1R_SAMPLES")

# Texts the checks must find, put together here so that this file itself stays clean.
BS = chr(92)
HOME_WIN = "C:" + BS + "Users" + BS + "tester" + BS + "notes.txt"
HOME_NIX = "/ho" + "me/tester/notes"
DRIVE = "D:" + BS + "Games" + BS + "Thing"

oks, fails = 0, 0


def check(condition, text):
    global oks, fails
    if condition:
        oks += 1
        print("ok   " + text)
    else:
        fails += 1
        print("FAIL " + text)
    return condition


def section(text):
    print("== " + text)


def quiet(function, *args):
    """Calls a tool's main() without its output."""
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return function(*args)


def quiet_text(function, *args):
    """Calls a tool's main() and returns what it printed."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        function(*args)
    return out.getvalue()


def write(path, text, mode="w"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if "b" in mode:
        with open(path, mode) as f:
            f.write(text)
    else:
        with open(path, mode, encoding="utf-8", newline="") as f:
            f.write(text)


def fresh(name):
    path = os.path.join(TMP, name)
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(path)
    return path


def rules_of(result, rel=None):
    return sorted(f["rule"] for f in result.findings if rel is None or f["file"] == rel)


def has(result, rule, rel, part=""):
    return any(f["rule"] == rule and f["file"] == rel and part in f["text"] for f in result.findings)


# --------------------------------------------------------------------------- lint
def test_lint():
    section("lint: tokens and blocks")
    toks = lint.tokenize('local s = [[ function end ]] -- function\nlocal t = "a \\" end" --[==[ if\n do ]==] x = 0x1F + 1e-3\n')
    kinds = [(t.kind, t.text) for t in toks]
    check(("str", " function end ") in kinds and ("str", 'a \\" end') in kinds and ("name", "x") in kinds and toks[-1].line == 3
          and not any(t.kind == "kw" and t.text in ("function", "end", "if", "do") for t in toks),
          "texts and comments are not read as code; line numbers continue after a long comment")
    src = "\n".join([
        "local function plain() return StaticFindObject end",                 # 1
        "function A.b:c() for i = 1, 2 do StaticFindObject() end end",         # 2
        "x.y = function() while true do RegisterHook() end end",               # 3
        "LoopInGameThreadWithDelay(100, function() RegisterHook() end)",       # 4
        "pcall(function() RegisterHook() end)",                                # 5
        "if a then repeat RegisterHook() until b end",                         # 6
        "local z = (function() return RegisterHook end)()",                    # 7
    ])
    found = {}
    toks = lint.tokenize(src)
    for i, t, scopes in lint.walk(toks):
        if t.kind == "name" and t.text in ("StaticFindObject", "RegisterHook"):
            found[t.line] = lint.context_of(scopes)
    check(found.get(1) == ("plain", "function", False) and found.get(2) == ("A.b:c", "function", True) and found.get(3) == ("x.y", "function", True),
          "named functions (local, method, assigned) and loops inside them are recognised")
    check(found.get(4) == ("main chunk", "callback", False) and found.get(5) == ("main chunk", "main", False)
          and found.get(6) == ("main chunk", "main", True) and found.get(7) == ("main chunk", "function", False),
          "callback of a registrar / pcall wrapper at file level / loop at file level / other anonymous function")

    section("lint: rules on a small mod")
    root = fresh("lintmod")
    write(root + "/Scripts/main.lua", "local a = 1\nreturn a\n")
    write(root + "/Scripts/core/version.lua", 'return { name = "T", version = "1" }\n')
    write(root + "/modules/x/Scripts/broken.lua", "local = 1\n")
    write(root + "/modules/x/Scripts/globals.lua", "foo = 1\nlocal a = bar\nlocal b = StaticConstructObject\nlocal DIAG = G1R_DIAG\nreturn a, b, DIAG\n")
    write(root + "/modules/x/Scripts/props.lua", 'local o = {}\nlocal v = o.m_Capacity\nlocal w = o["m_ItemDefinition"]\n-- m_InventoryType in a comment\nreturn v, w\n')
    write(root + "/modules/x/Scripts/lookups.lua", "\n".join([
        "local function helper(path) return pcall(StaticFindObject, path) end",
        "local function tick() for i = 1, 3 do local o = StaticFindObject('/X') end end",
        "LoopInGameThreadWithDelay(100, function() RegisterHook('/a:b', function() end) end)",
        "pcall(function() RegisterHook('/a:c', function() end) end)",
        "local t = {}",
        "local x = t.StaticFindObject",
        "local function user() return helper('/Y') end",
        "local function cached() return helper('/Z') end",
        "return tick, x, user, cached", ""]))
    write(root + "/modules/x/Scripts/files.lua", "\n".join([
        "local function save() local f = io.open('a', 'w') return f end",
        "local function load2() return io.open('a', 'rb') end",
        "local function del() os.remove('a') end",
        "local function mode(m) return io.open('a', m) end",
        "local op = io.open",
        "return save, load2, del, mode, op", ""]))
    write(root + "/modules/x/Scripts/diag.lua", "local DIAG = G1R_DIAG\nif DIAG then DIAG.note('a', 1) end\nG1R_DIAG.note('b', 2)\n")
    write(root + "/modules/x/README.txt", b"caf\xc3\xa9\n", "wb")
    write(root + "/modules/x/paths.txt", "home: %s\nother home: %s\ndrive: %s\nallowed: %s (lint:allow-path)\nword: SecretWord here\n" % (HOME_WIN, HOME_NIX, DRIVE, DRIVE))
    write(root + "/modules/x/mixed.txt", b"one\r\ntwo\nthree\r\n", "wb")
    write(root + "/dev/tests/t/harness.lua", "GLOBAL_IN_A_TEST = 1\nlocal x = undefined_in_a_test\nreturn x\n")
    write(root + "/dev/out/generated.lua", "this is not lua (\n")
    write(root + "/dev/tools/lint_allow.txt", "\n".join([
        "# comment",
        "helper        modules/x/Scripts/           helper",
        "direct-lookup modules/x/Scripts/lookups.lua helper   # the wrapper",
        "lookup-site   modules/x/Scripts/lookups.lua cached",
        "file-write    modules/x/Scripts/files.lua   save",
        "logged-property modules/x/Scripts/props.lua m_ItemDefinition",
        "lookup-site   modules/x/Scripts/nothing.lua nobody",
        "bogus-rule    a b",
        "short line", ""]))
    if not check(LUAC is not None, "luac5.4 is available for the tests"):
        return
    r = lint.run(root, LUAC, ["secretword"])
    P = "modules/x/Scripts/"
    check(has(r, "syntax", P + "broken.lua") and rules_of(r, P + "broken.lua") == ["syntax"], "syntax: a file that does not compile (and no other rule is tried on it... except text rules)")
    check(has(r, "global-write", P + "globals.lua", "'foo'") and has(r, "global-read", P + "globals.lua", "'bar'")
          and rules_of(r, P + "globals.lua") == ["global-read", "global-write"], "global-write / global-read: only the unknown names (UE4SS functions and G1R_DIAG are known)")
    check(rules_of(r, P + "props.lua") == ["logged-property"] and has(r, "logged-property", P + "props.lua", "m_Capacity"),
          "logged-property: the name as a field; the allowed name and the comment are not reported")
    lk = [f for f in r.findings if f["file"] == P + "lookups.lua"]
    check(sorted((f["rule"], f["line"]) for f in lk) == [("direct-lookup", 2), ("hook-in-function", 3), ("lookup-site", 7)],
          "direct-lookup (in a loop, not in the allowed wrapper), hook-in-function (in a timer callback, not at file level), lookup-site (a caller that is not listed): %s"
          % sorted((f["rule"], f["line"]) for f in lk))
    check(any("inside a loop" in f["text"] for f in lk if f["rule"] == "direct-lookup"), "the loop is mentioned")
    fw = sorted((f["line"], f["text"]) for f in r.findings if f["file"] == P + "files.lua")
    check([l for l, _ in fw] == [3, 4, 5] and "os.remove" in fw[0][1] and "not a plain text" in fw[1][1] and "another name" in fw[2][1],
          "file-write: os.remove, a mode that is not a text, io.open under another name; reading and the allowed function are fine")
    check(rules_of(r, P + "diag.lua") == ["diag-handle"] and [f["line"] for f in r.findings if f["file"] == P + "diag.lua"] == [3],
          "diag-handle: only the direct use, not `local DIAG = G1R_DIAG`")
    check(has(r, "non-ascii", "modules/x/README.txt", "0xc3"), "non-ascii: the byte and where it is")
    pf = [f for f in r.findings if f["file"] == "modules/x/paths.txt"]
    check(sorted((f["rule"], f["line"]) for f in pf) == [("drive-path", 3), ("personal-path", 1), ("personal-path", 2), ("personal-path", 5)],
          "personal-path (Windows and Unix home, forbidden word in any case), drive-path (not on a line with lint:allow-path)")
    check(has(r, "line-endings", "modules/x/mixed.txt"), "line-endings: CRLF and LF mixed")
    check(rules_of(r, "dev/tests/t/harness.lua") == [] and not any(f["file"].startswith("dev/out/") for f in r.findings),
          "test code may use globals; dev/out is not looked at")
    notes = "\n".join(r.notes)
    check("unknown rule 'bogus-rule'" in notes and "expected `rule path name`" in notes and "nothing.lua nobody` matched nothing" in notes,
          "problems in lint_allow.txt and entries that match nothing are reported")
    check(r.count("error") == 8 and r.count("warning") == 9, "counts: %d errors, %d warnings" % (r.count("error"), r.count("warning")))
    check(any(l["what"] == "helper" and l["function"] == "cached" for l in r.lookups) and any(l["what"] == "StaticFindObject" for l in r.lookups),
          "the list of object searches (for --lookups) names helper calls and direct uses")
    code = quiet(lint.main, ["--root", root, "--quiet", "--forbid", "secretword"])
    check(code == 1, "exit code 1 with errors")
    clean = fresh("lintclean")
    write(clean + "/Scripts/main.lua", "local a = 1\nreturn a\n")
    check(quiet(lint.main, ["--root", clean, "--quiet"]) == 0, "exit code 0 on a clean tree")
    check("syntax" in lint.explain() and "lint_allow.txt" in lint.explain(), "--explain names every rule and the exceptions file")

    section("lint: the mod itself")
    r = lint.run(ROOT, LUAC)
    check(r.count("error") == 0 and r.count("warning") == 0, "no error, no warning (%d / %d)%s" % (
        r.count("error"), r.count("warning"), "".join("\n     %s:%d %s" % (f["file"], f["line"], f["text"]) for f in r.findings[:8])))
    check(not [n for n in r.notes if "matched nothing" in n], "every entry of lint_allow.txt is in use")
    paths = sorted(set(l["source"] for l in r.lookups if l["what"] in ("U.findStatic", "findStaticOnce")))
    check(len(paths) >= 8, "the mod's searches by path are listed (%d places)" % len(paths))


# --------------------------------------------------------------------------- loganalyze
LOG = """[2026-10-03 20:00:00.0000001] Console created
[2026-10-03 20:00:00.1000000] UE4SS - v3.0.1 Beta #0 - Git SHA #c838a8ac
[2026-10-03 20:00:00.2000000] FArchiveState::ArIsError = 0x29
[2026-10-03 20:00:00.3000000] [PS] Failed to find FUObjectHashTables::Get(): expected at least one value
[2026-10-03 20:00:01.0000000] Starting mods (from mods.txt (X) load order)...
[2026-10-03 20:00:01.1000000] Starting C++ mod 'NativeThing'
[2026-10-03 20:00:01.2000000] [NativeThing] Loaded v1.
[2026-10-03 20:00:02.0000000] Mod 'OffMod' disabled in mods.txt.
[2026-10-03 20:00:02.1000000] Starting Lua mod 'G1R_MegaMod'
[2026-10-03 20:00:02.2000000] [Lua] [G1R_Repopulate] v1.3.0-local loaded: 401 creature spawn points
[2026-10-03 20:00:02.3000000] [Lua] [NPCMarkers] v2.3.0-local loaded: 181 named NPCs
[2026-10-03 20:00:02.4000000] [Lua] [G1R_MegaMod] v0.1.0 loaded: repopulate ok, markers ok | diagnostics normal -> Scripts/diagnostics/session-20261003-200002.log
[2026-10-03 20:00:02.5000000] Starting Lua mod 'OtherMod'
[2026-10-03 20:00:02.6000000] [Lua] [OtherMod] restore hooks not loaded yet, will retry per minigame: /Script/G1R.X:Y
[2026-10-03 20:00:03.0000000] Starting mods (from enabled.txt (X), no defined load order)...
[2026-10-03 20:01:00.0000000] [DEBUG_PROPTYPE] Property 'm_ItemDefinition' has FField class 'ClassProperty' (has_handler=true)
[2026-10-03 20:01:00.1000000] [DEBUG_PROPTYPE] Property 'm_ItemDefinition' has FField class 'ClassProperty' (has_handler=true)
[2026-10-03 20:01:00.2000000] [DEBUG_PROPTYPE] Property 'm_Capacity' has FField class 'IntProperty' (has_handler=true)
[2026-10-03 20:02:00.0000000] [Lua] [G1R_Repopulate] containers: the item classes of IO_X cannot be read from the game's data
[2026-10-03 20:02:30.0000000] [Lua] [G1R_MegaMod] error in markers (LoopInGameThreadWithDelay 150): main.lua:10: attempt to index a nil value
[2026-10-03 20:03:00.0000000] [Lua] [OtherMod] something failed here
[2026-10-03 20:03:10.0000000] Error: main.lua:5: attempt to call a nil value (global 'nope')
stack traceback:
        [C]: in ?
[2026-10-03 20:04:00.0000000] [Lua] [NPCMarkers] Map_World map Area: 12 single pins
"""


def test_loganalyze():
    section("loganalyze: a small log")
    folder = fresh("log")
    path = folder + "/UE4SS.log"
    write(path, LOG)
    a, entries = loganalyze.analyze(path)
    check(a["lines"] == 25 and a["entries"] == 23 and a["seconds"] == 240.0 and len(a["sessions"]) == 1
          and a["sessions"][0]["version"] == "v3.0.1 Beta #0" and a["sessions"][0]["git"] == "c838a8ac",
          "lines, entries (a traceback belongs to its line), duration, the UE4SS start line")
    mods = {m["name"]: m for m in a["mods"]}
    check(sorted(mods) == ["G1R_MegaMod", "NativeThing", "OtherMod"] and a["disabled"] == ["OffMod"], "mods started and mods switched off")
    mega = mods["G1R_MegaMod"]
    check(mega["tags"] == ["G1R_Repopulate", "NPCMarkers", "G1R_MegaMod"] and mega["lines"] == 6,
          "the megamod owns the lines of its modules' tags (%d lines, tags %s)" % (mega["lines"], mega["tags"]))
    check(a["megamod"] and sorted(a["megamod"]["by_tag"]) == ["G1R_MegaMod", "G1R_Repopulate", "NPCMarkers"]
          and a["megamod"]["by_tag"]["NPCMarkers"]["lines"] == 2, "megamod lines grouped by tag")
    check(a["proptype"] == {"m_ItemDefinition": 2, "m_Capacity": 1}, "[DEBUG_PROPTYPE] lines counted per property")
    sig = {s["id"]: s for s in a["signatures"]}
    check(sig["hook-retry"]["count"] == 1 and sig["hook-retry"]["mods"] == ["OtherMod"] and sig["hook-retry"]["severity"] == "hazard"
          and a["signatures"][0]["id"] == "hook-retry", "hook-retry: found, with the mod, listed first")
    check(sig["lua-error"]["count"] == 2 and sig["megamod-error"]["count"] == 1 and sig["cannot-be-read"]["mods"] == ["G1R_MegaMod"]
          and sig["ue4ss-scan-failed"]["severity"] == "info", "Lua error (also from a traceback line), megamod error, cannot-be-read, the usual scan failure")
    errs = [e["line"] for e in a["error_lines"]]
    check(errs == [20, 21, 22], "error-looking lines: not the member-offset dump, not the scan failure (%s)" % errs)
    check(mods["OtherMod"]["errors"] == 1 and mods["G1R_MegaMod"]["errors"] == 1, "error-looking lines per mod")
    check(a["last_lines"][-1].endswith("12 single pins") and "(3 [DEBUG_PROPTYPE] lines)" in a["last_lines"], "end of the log, debug lines folded")
    text = loganalyze.render(a, "G1R_MegaMod", entries)
    check("== lines of G1R_MegaMod ==" in text and "hazard   hook-retry" in text and "total 3," in text, "the report prints (also with --mod)")
    check(quiet(loganalyze.main, [path, "--json"]) == 0 and quiet(loganalyze.main, [folder + "/missing.log"]) == 2, "exit codes: 0, and 2 for a missing file")
    empty = folder + "/empty.log"
    write(empty, "")
    a2, _ = loganalyze.analyze(empty)
    check(a2["lines"] == 0 and "no UE4SS start line" in loganalyze.render(a2), "an empty file is handled")

    section("loganalyze: real logs")
    real = os.path.join(SAMPLES, "crash-20261001-1942", "UE4SS.log") if SAMPLES else None
    if real and os.path.isfile(real):
        a, _ = loganalyze.analyze(real)
        sig = {s["id"]: s for s in a["signatures"]}
        check(a["proptype"] == {"m_InteractiveObjectDefinition": 3245} and sig.get("hook-retry", {}).get("mods") == ["SkillfulLocks"]
              and len(a["mods"]) == 16 and a["error_lines"] == [],
              "the log of the crash of 2026-10-01: 3245 debug lines, the hook retry of SkillfulLocks, 16 mods, no false error line")
    else:
        print("note skipped: no real log (set G1R_SAMPLES)")


# --------------------------------------------------------------------------- crashtriage
def crash_xml(frames, error, seconds=640, extra=""):
    stack = " ".join("%s 0x00007ff800000000 + %s" % (m, o) for m, o in frames)
    return """<?xml version="1.0" encoding="UTF-8"?>
<FGenericCrashContext>
	<RuntimeProperties>
		<CrashType>Crash</CrashType>
		<ErrorMessage>%s</ErrorMessage>
		<IsAssert>false</IsAssert>
		<IsEnsure>false</IsEnsure>
		<SecondsSinceStart>%d</SecondsSinceStart>
		<EngineVersion>5.4.3-174209</EngineVersion>
		<BuildVersion>Build83_CL174209</BuildVersion>
		<UserName>SECRETUSER</UserName>
		<MachineId>SECRETMACHINE</MachineId>
		<EpicAccountId>SECRETACCOUNT</EpicAccountId>
		<BaseDir>%s</BaseDir>
		<TimeOfCrash>639265021740120000</TimeOfCrash>
		<PCallStack>%s</PCallStack>
		<Threads>
			<Thread><CallStack>%s</CallStack><IsCrashed>true</IsCrashed><Registers /><ThreadID>4242</ThreadID><ThreadName>GameThread</ThreadName></Thread>
			<Thread><CallStack>ntdll 0x00007ff900000000 + 1</CallStack><IsCrashed>false</IsCrashed><Registers /><ThreadID>7</ThreadID><ThreadName>Background Worker #3</ThreadName></Thread>
		</Threads>%s
	</RuntimeProperties>
</FGenericCrashContext>
""" % (error, seconds, HOME_WIN, stack, stack, extra)


def minidump(modules, thread, code, address, params):
    """A minimal minidump: module list and exception stream."""
    header = 32
    directory = header
    stream_modules = directory + 2 * 12
    records = b""
    names = b""
    names_at = stream_modules + 4 + 108 * len(modules)
    for name, base, size, stamp in modules:
        wide = name.encode("utf-16-le")
        records += struct.pack("<QIIII", base, size, 0, stamp, names_at + len(names)) + b"\0" * (52 + 8 + 8 + 8 + 8)
        names += struct.pack("<I", len(wide)) + wide + b"\0\0"
    modules_blob = struct.pack("<I", len(modules)) + records + names
    stream_exception = stream_modules + len(modules_blob)
    info = list(params) + [0] * (15 - len(params))
    exception_blob = struct.pack("<IIIIQQII15QII", thread, 0, code, 0, 0, address, len(params), 0, *(info + [0, 0]))
    head = struct.pack("<4sIIIIIQ", b"MDMP", 0xA793, 2, directory, 0, 0, 0)
    table = struct.pack("<III", 4, len(modules_blob), stream_modules) + struct.pack("<III", 6, len(exception_blob), stream_exception)
    return head + table + modules_blob + exception_blob


WALK = [("UE4SS", o) for o in ("35cad1", "370ad8", "39e4ff", "372235", "39e68e", "371c59", "29943a")] + [("G1R-Win64-Shipping", "5ba05e7"), ("KERNEL32", "2cd87")]
AV28 = "Unhandled Exception: EXCEPTION_ACCESS_VIOLATION reading address 0x0000000000000028"


def test_crashtriage():
    section("crashtriage: a report with the known signature")
    folder = fresh("crash") + "/crash-A"
    write(folder + "/CrashContext.runtime-xml", crash_xml(WALK, AV28))
    dll = crashtriage.UE4SS_DLL
    write(folder + "/UEMinidump.dmp", minidump([("C:" + BS + "Game" + BS + "UE4SS.dll", 0x7ff800000000, dll["size_of_image"], dll["timestamp"])],
                                               4242, 0xC0000005, 0x7ff800000000 + 0x35cad1, [0, 0x28]), "wb")
    write(folder + "/gothic_crash_info.log", json.dumps({"game": {
        "ownedGameplayTags": ["Guild.None", "Skill.Bow.Untrained", "State.Interact", "Character.Player", "UI.Map.InRegion"],
        "activeAbilities": ["Default__GA_Human_OpenContainer", "Default__GameplayAbilityPivot"],
        "nearbyCharacters": {"PlayerCharacterBP_C_1": 0, "Character_A": 700.5, "Character_B": 120.25},
        "nearbyInteractionSpots": {"iO_FAR": 900, "iO_NC_CHEST_X": 90, "bad": "text"}}}))
    write(folder + "/UE4SS.log", LOG.replace("2026-10-03 20:04:00", "2026-10-01 19:42:49"))
    r = crashtriage.triage(folder)
    c = r["context"]
    check(c["error"] == AV28 and c["seconds_since_start"] == 640 and c["build"] == "Build83_CL174209" and c["time_utc"] == "2026-10-02 01:42:54"
          and c["crashed_thread"]["name"] == "GameThread" and c["threads"] == 2 and len(c["frames"]) == 9,
          "error, seconds since start, build, time of the crash (UTC), crashed thread, frames")
    check(r["top_module"] == "UE4SS" and r["first_other"] == {"index": 7, "module": "G1R-Win64-Shipping", "offset": "5ba05e7"}
          and r["stack_modules"][0] == {"module": "UE4SS", "frames": 7}, "which module the top frames are in, first frame of another module")
    check(r["exception"] == {"code": "0xC0000005", "thread": 4242, "at": "UE4SS+35cad1", "access": "reading address 0x28"},
          "minidump: exception code, module + offset, kind of access: %s" % r.get("exception"))
    s = r["signatures"]
    check(len(s) == 1 and s[0]["id"] == "ue4ss-object-walk" and s[0]["verdict"] == "MATCH" and s[0]["binary_same"] is True
          and "is the build the offsets belong to" in s[0]["binary_identity"], "signature ue4ss-object-walk: MATCH, the DLL in the minidump is the known build")
    g = r["game"]
    check(g["tags_of_interest"] == ["State.Interact", "UI.Map.InRegion"] and g["active_abilities"] == ["GA_Human_OpenContainer", "GameplayAbilityPivot"]
          and [x["name"] for x in g["nearest_spots"]] == ["iO_NC_CHEST_X", "iO_FAR"] and [x["name"] for x in g["nearest_characters"]] == ["Character_B", "Character_A"],
          "game state: tags of interest, active abilities, nearest spots and characters (nearest first, the player left out)")
    lg = r["log"]
    check(lg["ends_before_crash_s"] == 5.0 and lg["zone_hours"] == -6.0 and any(x["id"] == "hook-retry" for x in lg["signatures"]),
          "log: ends 5 s before the report (time zone worked out), hazard signatures of the log")
    text = crashtriage.render(r)
    blob = text + json.dumps(r)
    check("ue4ss-object-walk: MATCH" in text and "the log ends 5 s before" in text, "the report prints")
    check(not any(x in blob for x in ("SECRETUSER", "SECRETMACHINE", "SECRETACCOUNT", "tester")), "account, machine, user and folder fields of the report are never printed")

    section("crashtriage: near misses")
    other = fresh("crash2") + "/crash-B"
    write(other + "/CrashContext.runtime-xml", crash_xml(WALK, AV28))
    write(other + "/UEMinidump.dmp", minidump([("UE4SS.dll", 0x7ff800000000, dll["size_of_image"], dll["timestamp"] + 1)], 1, 0xC0000005, 0x7ff800000000, [0, 0x28]), "wb")
    r = crashtriage.triage(other)
    check(r["signatures"][0]["verdict"].startswith("frames look alike, but the binary is another build") and r["signatures"][0]["binary_same"] is False,
          "another build of UE4SS.dll: the offsets are not trusted")
    write(other + "/CrashContext.runtime-xml", crash_xml(WALK, "Unhandled Exception: EXCEPTION_ACCESS_VIOLATION writing address 0x0000000000000010"))
    os.remove(other + "/UEMinidump.dmp")
    r = crashtriage.triage(other)
    check(r["signatures"][0]["verdict"].startswith("top frames match, the error text differs") and "not checked" in r["signatures"][0]["binary_identity"]
          and "exception" not in r, "same frames, other error text: related, not the same; without a minidump the DLL is 'not checked'")
    fake_dll = other + "/UE4SS.dll"
    write(fake_dll, b"MZ" + b"\0" * 0x3a + struct.pack("<I", 0x80) + b"\0" * 0x40 + b"PE\0\0" + struct.pack("<HHI", 0x8664, 1, 0x11111111) + b"\0" * 12
          + struct.pack("<H", 0x20B) + b"\0" * 54 + struct.pack("<I", 0x5000) + b"\0" * 64, "wb")
    b = crashtriage.read_binary(fake_dll)
    check(b["timestamp"] == 0x11111111 and b["size_of_image"] == 0x5000 and len(b["sha256"]) == 64, "--dll: time stamp, image size and hash of a file")
    r = crashtriage.triage(other, dlls=[fake_dll])
    check(r["signatures"][0]["binary_same"] is False and "the file given is NOT that build" in r["signatures"][0]["binary_identity"], "--dll with another file: said")
    write(other + "/CrashContext.runtime-xml", crash_xml([("G1R-Win64-Shipping", "abc123"), ("UE4SS", "3d6698"), ("KERNEL32", "1")], "Fatal error!"))
    r = crashtriage.triage(other)
    text = crashtriage.render(r)
    check(r["signatures"] == [] and "no signature matches" in text and "UE4SS frames on this stack: 1 (first at #1)" in text and "no UE4SS.log in the folder" in text,
          "an unknown crash: no signature, UE4SS frames counted, the missing log is mentioned")
    empty = fresh("crash3")
    r = crashtriage.triage(empty)
    check(r["problems"] and "not a crash report folder" in r["problems"][0] and quiet(crashtriage.main, [empty]) == 1 and quiet(crashtriage.main, [empty + "/nothing"]) == 2,
          "a folder without a report: said, exit code 1; a missing folder: exit code 2")

    section("crashtriage: the real crash reports")
    if SAMPLES and os.path.isdir(SAMPLES):
        want = {"crash-20261001-1942": ("ue4ss-object-walk", "analysed", "UE4SS"), "crash-old-422FC6AC": ("ue4ss-2485b0", "seen", "UE4SS"),
                "crash-old-8DD6ED2A": ("game-ragdoll-30e9606", "seen", "G1R-Win64-Shipping")}
        for name in sorted(want):
            path = os.path.join(SAMPLES, name)
            if not os.path.isdir(path):
                print("note skipped: %s not in G1R_SAMPLES" % name)
                continue
            r = crashtriage.triage(path)
            s = r["signatures"]
            check(len(s) == 1 and (s[0]["id"], s[0]["status"]) == want[name][:2] and s[0]["verdict"] == "MATCH" and s[0]["binary_same"] is True
                  and r["top_module"] == want[name][2], "%s: %s (%s)" % (name, want[name][0], "cause known" if want[name][1] == "analysed" else "recorded, cause not known"))
        r = crashtriage.triage(os.path.join(SAMPLES, "crash-20261001-1942"))
        if "log" in r:
            check(r["log"]["ends_before_crash_s"] == 5.0 and r["log"]["signatures"][0]["id"] == "hook-retry" and "GA_Human_OpenContainer" in r["game"]["active_abilities"]
                  and r["game"]["nearest_spots"][0]["name"] == "iO_NC_CHEST_ROGUE03_806", "2026-10-01: log ends 5 s before, hook retry in the log, the player was opening a chest")
        blob = json.dumps(r) + crashtriage.render(r)
        check("MachineId" not in blob and "EpicAccountId" not in blob and "LoginId" not in blob and (BS + "Users" + BS) not in blob, "nothing personal in the output for the real report")
    else:
        print("note skipped: no real crash reports (set G1R_SAMPLES)")


# --------------------------------------------------------------------------- diagread
FACTS = """# Facts (test)
| Note key | Expected | Meaning |
|---|---|---|
| `containers.definition_source` | `getter` else `component` | how |
| `containers.data_module_source` | `module list` else `library` | how |
| `containers.count_form` | `count` or `wrapped count` | how |
| `creatures.spawn_via` | `library` or `point` | how |
| `markers.self_test.world` | `re:^0\\.[0-4] / ` | px |
| `markers.map_found_by` | (any) | how |
| `markers.hover_path` | `canvas fast path` or `per-pin polling` | how |
| `core.profile` | (any) | which |
| not a key row | x | y |
"""


def test_diagread():
    section("diagread: the subset of Lua a dump is written in")
    table = diagread.parse_dump('-- c\nreturn {\n  ["a"] = "q\\034 \\092 \\010 x",\n  [1] = 1.5,\n  [2] = -3,\n  [-1] = (0/0),\n  ["t"] = {\n    [1] = true,\n    [2] = false,\n  },\n  ["e"] = {},\n  ["m"] = (-9223372036854775807-1),\n  ["i"] = (-1/0),\n  ["x"] = 1e-05,\n}\n')
    check(table["a"] == 'q" \\ \n x' and table[1] == 1.5 and table[2] == -3 and table[-1] != table[-1] and table["t"] == {1: True, 2: False}
          and table["e"] == {} and table["m"] == -2 ** 63 and table["i"] == float("-inf") and table["x"] == 1e-05, "texts with escapes, numbers of every kind, nested and empty tables")
    for bad in ("return 5", "x = {}", 'return { ["a"] = }', 'return { ["a"] = "x" } junk', 'return { ["a"] = function() end }'):
        try:
            diagread.parse_dump(bad)
            ok = False
        except diagread.DumpError:
            ok = True
        check(ok, "refused: %s" % bad)

    section("diagread: files written by the mod's own recorder")
    if not check(LUA is not None, "lua5.4 is available to write the sample files"):
        return
    out = fresh("diag")
    p = subprocess.run([LUA, os.path.join(HERE, "make_diag_sample.lua"), ROOT, out], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if not check(p.returncode == 0, "sample files written (%s)" % p.stdout.decode("utf-8", "replace").strip()[-200:]):
        return
    facts = out + "/FACTS.md"
    write(facts, FACTS)
    a = diagread.read_all(out + "/a/Scripts/diagnostics", facts)
    s = a["session"]
    check(a["files"] == {"sessions": ["session-20261003-201500.log"], "reports": ["report-20261003-202030.txt", "report-latest.txt"], "dumps": ["dump-20261003-202030.lua"],
                         "operations": ["session-20261003-201500.ops"], "session reports": ["session-20261003-201500.report.txt"]},
          "the files of a diagnostics folder, by kind")
    check(a["sessions"] == [{"log": "session-20261003-201500.log", "inside": None, "how": None}] and a["report"]["file"] == "session-20261003-201500.report.txt",
          "one session, nothing under way at its end; the report read is the session's own")
    o = a["ops"]
    check(o["file"] == "session-20261003-201500.ops" and o["records"] == 3 and (o["first"], o["last"]) == (1, 3) and o["unreadable"] == 0 and o["ended_inside"] is None
          and o["newest"]["shown"] == "#3 20:15:30 [repopulate] FindAllOf GothicCharacterState" and o["newest"]["state"] == "="
          and o["open_earlier"] == ["#2 20:15:30 [markers] markers: refresh Map_World"],
          "operations: the records in the order of their numbers, the newest one finished, an earlier one that was never finished")
    check(s["start"].startswith("G1R_MegaMod v0.1.0") and s["load"] == "v0.1.0 loaded: repopulate ok, markers ok" and s["unparsed"] == 0 and s["ended_inside"] is None,
          "session log: start line, load line, every line understood, did not end inside a step")
    check(len(s["errors"]) == 1 and "attempt to index a nil value" in s["errors"][0]["text"] and s["errors"][0]["module"] == "markers" and s["slow"] == 1,
          "session log: the error with its module, slow callbacks")
    check(s["lookups"] == {"first_time": 3, "found": 2} and s["not_found"] == ["[repopulate] /Script/Angelscript.RoutineX"]
          and s["repeated"] == ["[repopulate] /Script/Angelscript.RoutineX: NOT FOUND again (search number 2 for this path; each one walks all objects)"],
          "session log: first-time searches, what was not found, the repeated search")
    r = a["report"]
    check(r["title"] == "G1R_MegaMod v0.1.0 - diagnostics report" and r["header"]["minutes since load"] == "5.5" and r["error_count"] == 1
          and r["parts"]["modules"] == ["repopulate: loaded, version 1.3.0-local", "markers: loaded, version 2.3.0-local"]
          and "[repopulate] creatures: 2 cycles" in r["parts"]["status"] and any("lookups: 5 calls, 3 first-time, 2 not found, 1 repeated" in x for x in r["parts"]["counters"]),
          "report: header, modules, status lines, counters, error count")
    notes = {n["key"]: n for n in a["notes"]}
    check(notes["creatures.spawn_via"]["shown"] == "library (OC_WOLF_SPAWN_2)" and notes["creatures.spawn_via"]["changes"] == 1 and notes["creatures.spawn_via"]["first"] == "point"
          and notes["markers.self_test.world"]["shown"] == "0.3 / 0.1 UI px (raw / corrected, map width 1600) (box W_Box_1 [registered])" and notes["core.profile"]["at"] == "20:15:00",
          "notes: latest value with its detail, changes and the first value, when first seen")
    verdicts = {x["key"]: x["verdict"] for x in a["facts"]}
    check(verdicts == {"containers.definition_source": "as expected", "containers.data_module_source": "fallback in use", "containers.count_form": "DIFFERS",
                       "creatures.spawn_via": "as expected", "markers.self_test.world": "as expected", "markers.map_found_by": "seen",
                       "markers.hover_path": "not seen", "core.profile": "seen", "markers.unknown_key": "not in FACTS.md"},
          "facts: as expected (any value before `else`) / fallback in use / DIFFERS / seen / not seen / not in FACTS.md: %s" % sorted(verdicts.items()))
    d = a["dump"]
    check(d["problem"] is None and d["meta"]["mod"] == "G1R_MegaMod" and d["meta"]["modules"] == {"markers": "dumped", "repopulate": "dumped"} and d["meta"]["minutes"] == 5.5
          and d["modules"]["repopulate"]["containers"] == "list of 1" and d["modules"]["repopulate"]["version"] == '"1.3.0-local"' and d["modules"]["markers"]["pins"] == "empty",
          "dump: what was dumped, and the shape of each module's table")
    text = diagread.render(a)
    check(all(x in text for x in ("REPEATED SEARCHES (1)", "DIFFERS", "containers.count_form", "expected: `count` or `wrapped count`", "ended inside: nothing", "== end of the session log ==",
                                  "summary: 1 DIFFERS, 3 as expected, 1 fallback in use, 1 not in FACTS.md, 1 not seen, 2 seen")),
          "the summary prints the things to look at first")
    check(all(x in text for x in ("== operations session-20261003-201500.ops ==", "3 record(s), numbers 1 .. 3", "ended inside: nothing (the newest operation was finished)",
                                  "begun and never finished earlier (1) - each raised an error", "    #2 20:15:30 [markers] markers: refresh Map_World",
                                  "  begun, NOT finished #2 20:15:30 [markers]", "  finished            #3 20:15:30 [repopulate] FindAllOf GothicCharacterState",
                                  "* session-20261003-201500.log  nothing was under way at its end", "1 operations file(s), 1 report(s) kept per session")),
          "and the operations of the session: how it ended, what raised earlier, the last ones")
    b = diagread.read_all(out + "/b/Scripts/diagnostics", None)
    check(b["session"]["ended_inside"] == "21:20:30 [repopulate] lookup /Script/Angelscript.SpawnAIAgentDefinition_Lurker" and "ENDED INSIDE" in diagread.render(b)
          and b["report"] is None and b["dump"] is None, "a session log that ends with a breadcrumb: the step the game went down in is named")
    check(b["ops"]["ended_inside"] == "#2 21:20:30 [repopulate] search by path /Script/Angelscript.SpawnAIAgentDefinition_Lurker" and b["ops"]["open_earlier"] == []
          and b["sessions"] == [{"log": "session-20261003-212030.log", "inside": b["ops"]["ended_inside"], "how": "operation"}]
          and "ENDED INSIDE: #2 21:20:30 [repopulate] search by path" in diagread.render(b) and "ENDED INSIDE AN OPERATION: #2" in diagread.render(b),
          "the same session by its operations file: the newest operation was begun and never finished")
    one = diagread.read_all(out + "/a/Scripts/diagnostics/report-20261003-202030.txt", None)
    check(one["session"] is None and one["ops"] is None and one["report"]["error_count"] == 1 and len(one["notes"]) == 8, "a single file can be given: a report")
    one = diagread.read_all(out + "/a/Scripts/diagnostics/session-20261003-201500.report.txt", None)
    check(one["session"] is None and one["report"]["error_count"] == 1 and len(one["notes"]) == 8, "a session's own report")
    one = diagread.read_all(out + "/a/Scripts/diagnostics/session-20261003-201500.log", None)
    check(one["report"] is None and len(one["notes"]) == 8 and one["notes"][0]["module"] in ("markers", "repopulate") and one["ops"]["records"] == 3 and one["sessions"] is None,
          "a single file can be given: a session log (notes from its lines; the operations file next to it is read with it)")
    one = diagread.read_all(out + "/b/Scripts/diagnostics/session-20261003-212030.ops", None)
    check(one["session"] is None and one["report"] is None and one["ops"]["ended_inside"].startswith("#2 21:20:30") and "ENDED INSIDE: #2" in diagread.render(one),
          "an operations file alone")
    # two sessions: the game went down in the first and was started again
    c = diagread.read_all(out + "/c/Scripts/diagnostics", None)
    inside = "#301 22:20:30 [repopulate] FindAllOf CrimeProcessingSubsystem_Human"
    check(c["sessions"] == [{"log": "session-20261003-222030.log", "inside": inside, "how": "operation"}, {"log": "session-20261003-224030.log", "inside": None, "how": None}]
          and c["session"]["file"] == "session-20261003-224030.log" and c["ops"]["ended_inside"] is None and c["report"]["file"] == "session-20261003-224030.report.txt",
          "a folder with two sessions: both are listed with how they ended; the newest is read, with its own operations and report")
    text = diagread.render(c)
    check("    session-20261003-222030.log  ENDED INSIDE AN OPERATION: " + inside in text and "  * session-20261003-224030.log  nothing was under way at its end" in text,
          "the list says which session to look at")
    for which in (2, "2", "222030", "session-20261003-222030.log"):
        earlier = diagread.read_all(out + "/c/Scripts/diagnostics", None, 25, which)
        ok = (earlier["session"]["file"] == "session-20261003-222030.log" and earlier["ops"]["ended_inside"] == inside and earlier["ops"]["records"] == 256
              and (earlier["ops"]["first"], earlier["ops"]["last"]) == (46, 301) and earlier["ops"]["open_earlier"] == [] and earlier["report"] is None and not earlier["problems"])
        check(ok, "--session %r reads the earlier session: its ring of 256 operations ends inside the search; the newest session's report is not mixed in" % (which,))
    for which, said in ((3, "there is no session 3"), (0, "there is no session 0"), ("nothing", "names no session log"), ("session-", "names more than one session log")):
        wrong = diagread.read_all(out + "/c/Scripts/diagnostics", None, 25, which)
        check(wrong["session"] is None and wrong["ops"] is None and wrong["report"] is None and any(said in p for p in wrong["problems"]) and len(wrong["problems"]) == 1,
              "--session %r: said, nothing is read (%s)" % (which, wrong["problems"]))
    shown = quiet_text(diagread.main, [out + "/c/Scripts/diagnostics", "--session", "2", "--no-facts"])
    check("* session-20261003-222030.log  ENDED INSIDE AN OPERATION" in shown and "ENDED INSIDE: " + inside in shown and "the last operations:" in shown,
          "from the command line")
    # a file that is cut off, and one that is no operations file
    cut = fresh("diag-cut")
    data = open(out + "/c/Scripts/diagnostics/session-20261003-222030.ops", "rb").read()
    with open(cut + "/session-20261003-222030.ops", "wb") as f:
        f.write(data[:128 * 3 + 40])
    part = diagread.read_ops(cut + "/session-20261003-222030.ops")
    check(part["records"] == 3 and part["unreadable"] == 1 and part["ended_inside"] is None, "an operations file that is cut off: the whole records are read, the rest is counted")
    with open(cut + "/session-20261003-222031.ops", "wb") as f:
        f.write(b"\x00" * 300)
    none = diagread.read_ops(cut + "/session-20261003-222031.ops")
    check(none["records"] == 0 and none["unreadable"] == 3 and none["newest"] is None and "no operation was announced" in diagread.render({"path": "x", "problems": [], "files": None,
          "session": None, "ops": none, "report": None, "notes": [], "facts": None, "dump": None}), "a file that holds no records: said, not raised")
    fixture = out + "/fixture.lua"
    code = quiet(diagread.main, [out + "/a/Scripts/diagnostics", "--fixture", fixture, "--no-facts"])
    write(out + "/load_fixture.lua", "local t = dofile(arg[1])\nassert(t.repopulate.containers[1].kind == 'IO_NC_CHEST_01' and t._meta.version == '0.1.0')\n")
    p = subprocess.run([LUA, out + "/load_fixture.lua", fixture], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    check(code == 0 and p.returncode == 0 and open(fixture).read().startswith("-- Fixture made from dump-20261003-202030.lua"), "--fixture: a dump becomes a fixture file that Lua loads")
    check(quiet(diagread.main, [out + "/b/Scripts/diagnostics", "--fixture", out + "/none.lua"]) == 2 and not os.path.exists(out + "/none.lua"), "--fixture without a dump: exit code 2, nothing written")
    empty = fresh("diag-empty")
    e = diagread.read_all(empty, None)
    check(e["problems"] and "no session log, report or dump" in e["problems"][0] and quiet(diagread.main, [empty + "/missing"]) == 2, "an empty folder and a missing one are handled")
    write(empty + "/dump-20260101-000000.lua", "return 5\n")
    check("cannot be read" in diagread.read_all(empty, None)["dump"]["problem"], "a dump that is not one is reported, not raised")

    section("diagread: the facts file of the mod")
    path = os.path.join(DEV, "FACTS.md")
    if os.path.isfile(path):
        facts_real = diagread.read_facts(path)
        import re
        # whose notes these are: the parts of the two older modules, the kit, and every module with a schema.lua
        older = ["containers", "core", "creatures", "crime", "items", "markers"]
        newer = sorted(n for n in os.listdir(os.path.join(ROOT, "modules")) if os.path.isfile(os.path.join(ROOT, "modules", n, "Scripts", "schema.lua")))
        prefixes = sorted(set(older + newer + ["kit"]))
        modules = sorted(set(k.split(".")[0] for k in facts_real))
        check(len(facts_real) >= 25 and all(m in prefixes for m in modules) and all(m in modules for m in older + ["kit", "xp"]),
              "dev/FACTS.md and dev/facts/*.md list %d note keys of %s" % (len(facts_real), ", ".join(modules)))
        sources = []
        for top in ("modules", os.path.join("Scripts", "core")):
            for base, _, files in os.walk(os.path.join(ROOT, top)):
                for f in files:
                    if f.endswith(".lua"):
                        sources.append(open(os.path.join(base, f), encoding="utf-8", errors="replace").read())
        used = set()
        for text in sources:
            for key in facts_real:
                if '"' + key + '"' in text or '"' + key.rsplit(".", 1)[0] + '."' in text:
                    used.add(key)
        check(sorted(facts_real) == sorted(used), "every key of the facts files is noted somewhere in the code (missing: %s)" % sorted(set(facts_real) - used))
        literal = set()
        pattern = re.compile(r'"((?:%s)\.[a-z_.]+[a-z])"' % "|".join(re.escape(p) for p in prefixes))
        for text in sources:
            literal.update(pattern.findall(text))
        literal = set(k for k in literal if not k.endswith(".lua"))
        unknown = sorted(k for k in literal if k not in facts_real and not any(f.startswith(k + ".") for f in facts_real))
        check(len(literal) >= 20 and unknown == [], "every note key written in the code is in the facts files (%d keys; not listed: %s)" % (len(literal), unknown))
        for name in newer:
            if name != "general":
                check(os.path.isfile(os.path.join(DEV, "facts", name + ".md")), "the module %s has its facts file dev/facts/%s.md" % (name, name))
    else:
        check(False, "dev/FACTS.md exists")


# --------------------------------------------------------------------------- build_release
def small_mod(name):
    root = fresh(name) + "/TheMod"
    write(root + "/enabled.txt", "")
    write(root + "/README.txt", "A mod.\n")
    write(root + "/Scripts/main.lua", "local a = 1\nreturn a\n")
    write(root + "/Scripts/config.lua", "return {}\n")
    write(root + "/Scripts/core/version.lua", 'return { name = "TheMod", version = "1.2.3" }\n')
    write(root + "/Scripts/diagnostics/README.txt", "Written at run time.\n")
    write(root + "/Scripts/diagnostics/session-20260101-000000.log", "00:00:00 [loader] x\n")
    write(root + "/Scripts/diagnostics/sessions.txt", "session-20260101-000000.log\n")
    write(root + "/modules/repopulate/Scripts/config.lua", "return {}\n")
    write(root + "/modules/repopulate/Scripts/state/README.txt", "Progress files.\n")
    write(root + "/modules/repopulate/Scripts/state/profile_0.lua", "return {}\n")
    write(root + "/modules/repopulate/Scripts/config.lua.bak", "return {}\n")
    write(root + "/modules/markers/Scripts/Assets/pin.png", b"\x89PNG\r\n\x1a\n" + bytes(range(256)), "wb")
    write(root + "/dev/tools/thing.py", "print('dev')\n")
    write(root + "/dev/out/dist/old.zip", b"old", "wb")
    return root


def test_build_release():
    section("build_release: a package")
    if not check(LUAC is not None, "luac5.4 is available for the tests"):
        return
    root = small_mod("rel")
    out = os.path.dirname(root) + "/out"
    r = build_release.build(root, out, luac=LUAC)
    if not check(r["built"] and r["refused"] == [] and os.path.basename(r["zip"]) == "TheMod-1.2.3.zip" and os.path.basename(r["manifest"]) == "TheMod-1.2.3-manifest.sha256",
                 "built: <name>-<version>.zip and its manifest (%s)" % r["refused"]):
        return
    with zipfile.ZipFile(r["zip"]) as zf:
        names = [i.filename for i in zf.infolist()]
        stamps = set(i.date_time for i in zf.infolist())
        content = {n: zf.read(n) for n in names}
    want = sorted("TheMod/" + x for x in ("enabled.txt", "README.txt", "Scripts/main.lua", "Scripts/config.lua", "Scripts/core/version.lua", "Scripts/diagnostics/README.txt",
                                          "modules/repopulate/Scripts/config.lua", "modules/repopulate/Scripts/state/README.txt", "modules/markers/Scripts/Assets/pin.png"))
    check(names == want, "one top-level folder; entries sorted; only what belongs in it (%d files)" % len(names))
    check(stamps == {build_release.FIXED_TIME}, "every entry has the same fixed time stamp")
    reasons = {k: sorted(v) for k, v in r["left_out"].items()}
    check(reasons == {"dev kit (add --with-dev)": ["dev/tools/thing.py"], "generated (dev/out)": ["dev/out/dist/old.zip"],
                      "work file": ["modules/repopulate/Scripts/config.lua.bak"],
                      "written by a game session (diagnostics)": ["Scripts/diagnostics/session-20260101-000000.log", "Scripts/diagnostics/sessions.txt"],
                      "written by a game session (progress of a profile)": ["modules/repopulate/Scripts/state/profile_0.lua"]},
          "what was left out, with the reason: %s" % sorted(reasons))
    lines = open(r["manifest"]).read().splitlines()
    ok = len(lines) == len(names)
    for line in lines:
        digest, rel = line.split("  ./")
        ok = ok and hashlib.sha256(content["TheMod/" + rel]).hexdigest() == digest
    check(ok and lines == sorted(lines, key=lambda l: l.split("  ./")[1]), "manifest: `<sha256>  ./<path>` for every file, matching the zip")
    first = r["zip_sha256"]
    os.utime(root + "/Scripts/main.lua", (1, 1))
    r2 = build_release.build(root, out, luac=LUAC)
    check(r2["zip_sha256"] == first and r2["manifest_sha256"] == r["manifest_sha256"], "the same input gives the same zip, byte for byte (file times do not matter)")
    r3 = build_release.build(root, out, with_dev=True, luac=LUAC)
    with zipfile.ZipFile(r3["zip"]) as zf:
        names3 = [i.filename for i in zf.infolist()]
    check(os.path.basename(r3["zip"]) == "TheMod-1.2.3-dev.zip" and "TheMod/dev/tools/thing.py" in names3 and not any("dev/out" in n for n in names3),
          "--with-dev: the dev kit is in, dev/out is not; the file is named ...-dev.zip")
    check("BUILT" in build_release.render(r3, False) and quiet(build_release.main, ["--root", root, "--out", out, "--check", "--luac", LUAC]) == 0, "printing and exit code 0")

    section("build_release: refusals")

    def refused(name, change, expect, **options):
        root = small_mod(name)
        out = os.path.dirname(root) + "/out"
        change(root)
        r = build_release.build(root, out, luac=LUAC, **options)
        text = "\n".join(r["refused"])
        check(not r["built"] and expect in text and not os.path.exists(out), "refused, nothing written: %s (%s)" % (expect, text[:140].replace("\n", " | ")))
        return r

    refused("r1", lambda root: write(root + "/modules/markers/Scripts/main.lua", "local = 1\n"), "does not compile")
    refused("r2", lambda root: write(root + "/modules/markers/Scripts/main.lua", "leaked = 1\n"), "lint: modules/markers/Scripts/main.lua:1 [global-write]")
    refused("r3", lambda root: write(root + "/README.txt", "see %s\n" % HOME_WIN), "path below a home folder")
    refused("r4", lambda root: write(root + "/modules/markers/Scripts/Assets/tool.exe", b"MZ\0\0" + ("built in " + HOME_WIN).encode("utf-16-le") + b"\0\0\x01\x02", "wb"),
            "path below a home folder (16-bit text)")
    refused("r5", lambda root: write(root + "/modules/markers/Scripts/Assets/tool.bin", b"\x00\x01" + HOME_NIX.encode("ascii") + b"\x00", "wb"), "path below a home folder (8-bit text)")
    refused("r6", lambda root: write(root + "/modules/markers/Scripts/Assets/tool.bin", b"\x00\x01" + "My SecretWord".encode("utf-16-le") + b"\x00", "wb"),
            "forbidden word 'secretword' (16-bit text)", forbid=["secretword"])
    refused("r7", lambda root: write(root + "/Scripts/diagnostics/crash.dmp", b"MDMP", "wb"), "a save file or crash dump is in the mod folder")
    refused("r8", lambda root: write(root + "/dev/tests/t/Game.sav", b"x", "wb"), "a save file or crash dump is in the mod folder")

    def with_app(root):
        write(root + "/modules/repopulate/G1R_Repopulate_Settings.exe", b"MZ app", "wb")
    refused("r9", with_app, "is not the default file the app was built for")
    foreign = fresh("foreign") + "/other-mod.zip"
    with zipfile.ZipFile(foreign, "w") as zf:
        zf.writestr("Other/Scripts/pin.png", b"\x89PNG\r\n\x1a\n" + bytes(range(256)))
        zf.writestr("Other/enabled.txt", b"")
    r = refused("r10", lambda root: None, "modules/markers/Scripts/Assets/pin.png is a file of another mod (other-mod.zip:Other/Scripts/pin.png)", foreign=[foreign])
    check(not any("enabled.txt" in x for x in r["refused"]), "an empty file is not taken for a file of another mod")
    refused("r11", lambda root: os.remove(root + "/Scripts/core/version.lua"), "version.lua does not give name and version")
    root = small_mod("r12")
    check(quiet(build_release.main, ["--root", root, "--out", os.path.dirname(root) + "/out", "--name", "Bad Name", "--luac", LUAC]) == 1, "a name that is no file name: exit code 1")
    root = small_mod("r13")
    r = build_release.build(root, None, check_only=True, luac=LUAC)
    check(not r["built"] and r["refused"] == [] and not os.path.exists(root + "/dev/out/dist/TheMod-1.2.3.zip") and "CHECK OK" in build_release.render(r, True),
          "--check: every check runs, nothing is written")

    section("build_release: the mod itself")
    for with_dev in (False, True):
        r = build_release.build(ROOT, None, with_dev=with_dev, check_only=True, luac=LUAC)
        check(r["refused"] == [], "the mod passes the release checks%s (%d files)%s" % (" with the dev kit" if with_dev else "", r["files"],
                                                                                    "".join("\n     " + x for x in r["refused"][:10])))
    check(not any(x.startswith("dev/") for x in build_release.walk_all(ROOT) if build_release.left_out_reason(x, False) is None), "no dev file in the player package")


# --------------------------------------------------------------------------- run_tests
def test_runner():
    section("run_tests: suites and their result line")
    suites = run_tests.discover()
    names = [s[0] for s in suites]
    check(names == sorted(names) and all(n in names for n in ("loader", "markers", "pointers", "repopulate", "tools")),
          "suites found below dev/tests: %s" % ", ".join(names))
    if not check(LUA is not None, "lua5.4 is available for the tests"):
        return
    folder = fresh("runner")
    env = dict(os.environ)
    write(folder + "/good.lua", 'print("ok   a")\nprint("x finished: 3 ok, 0 failure(s)")\n')
    write(folder + "/bad.lua", 'print("FAIL b is wrong")\nprint("x finished: 2 ok, 1 failure(s)")\nos.exit(1)\n')
    write(folder + "/crash.lua", 'print("ok   a")\nerror("boom")\n')
    write(folder + "/liar.lua", 'print("x finished: 2 ok, 0 failure(s)")\nos.exit(3)\n')
    write(folder + "/slow.lua", "while true do end\n")
    write(folder + "/py.py", 'print("t finished: 1 ok, 0 failure(s)")\n')
    r = run_tests.run_suite("lua", folder + "/good.lua", LUA, env, 30)
    check(r["passed"] and r["ok"] == 3 and r["failed"] == 0 and r["problem"] is None, "a passing suite: counts from its last line")
    r = run_tests.run_suite("lua", folder + "/bad.lua", LUA, env, 30)
    check(not r["passed"] and r["failed"] == 1 and r["failing_lines"] == ["FAIL b is wrong"] and r["problem"] == "1 check(s) failed", "a failing suite: its FAIL lines are kept")
    r = run_tests.run_suite("lua", folder + "/crash.lua", LUA, env, 30)
    check(not r["passed"] and r["ok"] is None and "no result line" in r["problem"] and any("boom" in l for l in r["tail"]), "a suite that stops early is a failure, with the end of its output")
    r = run_tests.run_suite("lua", folder + "/liar.lua", LUA, env, 30)
    check(not r["passed"] and r["problem"] == "exit code 3", "a result line with 0 failures but a bad exit code is a failure")
    r = run_tests.run_suite("lua", folder + "/slow.lua", LUA, env, 1)
    check(not r["passed"] and "timeout" in r["problem"], "a suite that does not end is stopped")
    r = run_tests.run_suite("python", folder + "/py.py", LUA, env, 30)
    check(r["passed"] and r["ok"] == 1, "Python suites run with this Python")
    check(quiet(run_tests.main, ["--only", "nothing-like-this"]) == 2, "--only with an unknown name: exit code 2")


def main():
    shutil.rmtree(TMP, ignore_errors=True)
    os.makedirs(TMP)
    for test in (test_lint, test_loganalyze, test_crashtriage, test_diagread, test_build_release, test_runner):
        buffer = io.StringIO()
        try:
            test()
        except Exception as e:      # a test that raises is a failure, with its place
            import traceback
            traceback.print_exc(file=buffer)
            check(False, "%s ran to its end: %s\n%s" % (test.__name__, e, buffer.getvalue()))
    print("tools tests finished: %d ok, %d failure(s)" % (oks, fails))
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
