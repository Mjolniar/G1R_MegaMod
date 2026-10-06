#!/usr/bin/env python3
"""First look at a crash report folder of the game.

    python dev/tools/crashtriage.py <crash folder> [--log UE4SS.log] [--dll UE4SS.dll] [--frames N] [--json]

A crash report folder (the game writes them below its Saved/Crashes folder)
holds CrashContext.runtime-xml (error, call stack of every thread as module +
offset), UEMinidump.dmp (thread stacks, module list) and, written by the game
itself, gothic_crash_info.log (what the player was doing). UE4SS.log is copied
next to them by hand, or given with --log.

The tool prints: what crashed where, which module the top frames are in, a
match against the signatures known so far (table below), the game state, and
the end of the log. It names a cause only when a signature matches; everything
else is material for the analysis, not a verdict.

It never prints the account, machine and user fields of the report.
Python 3.8+, standard library only.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import struct
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
try:
    import loganalyze
except ImportError:         # the tool still works without the log part
    loganalyze = None

FRAME = re.compile(r"(\S+) 0x([0-9a-fA-F]+) \+ ([0-9a-fA-F]+)")

# The UE4SS build the offsets below belong to (fork "AngelScript Fix 0.4", v3.0.1 Beta, git c838a8ac).
UE4SS_DLL = {"file": "UE4SS.dll", "timestamp": 0x6A678186, "size_of_image": 0xFCA000,
             "sha256": "e1909f981e3f4c1dd603e9fc4e133fa679168e5d13d6d280b1dd79ed8f1dcaa3"}
GAME_EXE = {"file": "G1R-Win64-Shipping.exe", "timestamp": 0x6A74E07B, "size_of_image": 0xA7E7000}

# Signatures: the top frames of the crashed thread (module, offsets), optionally the error text.
# status: "analysed" (cause known) or "seen" (recorded, cause not known).
SIGNATURES = [
    {
        "id": "ue4ss-object-walk",
        "status": "analysed",
        "title": "UE4SS searched all objects for a path and read an invalid Outer pointer",
        "module": "UE4SS", "top": ["35cad1", "370ad8", "39e4ff", "372235", "39e68e", "371c59"],
        "error": r"EXCEPTION_ACCESS_VIOLATION reading address 0x0*28$",
        "binary": UE4SS_DLL,
        "text": [
            "Stack, read from the DLL: GetOutermost <- FindObject <- binding of RegisterHook / StaticFindObject <- Lua.",
            "A search by path that UE4SS cannot answer from its cache walks every object in memory and follows each",
            "object's Outer chain; one object had an invalid chain (which one, and why, is not known).",
            "A path that does not exist is never cached, so a mod that repeats such a search repeats the walk.",
            "First seen 2026-10-01: the mod SkillfulLocks 1.2.0 retried RegisterHook on a function that does not",
            "exist at the start of every lock minigame; the game crashed in the 12th.",
        ],
        "do": [
            "Find the mod that repeats a search: `python dev/tools/loganalyze.py UE4SS.log` (signature hook-retry),",
            "and for this mod `python dev/tools/diagread.py <Scripts/diagnostics>` (a breadcrumb at the end of the",
            "session log names the search that was running; `NOT FOUND again` lines name repeated searches).",
        ],
    },
    {
        "id": "ue4ss-2485b0",
        "status": "seen",
        "title": "access violation inside UE4SS shortly after the start",
        "module": "UE4SS", "top": ["2485b0"],
        "error": r"EXCEPTION_ACCESS_VIOLATION reading address 0x0+$",
        "binary": UE4SS_DLL,
        "text": [
            "Seen once (2026-09-30), 32 s after the start, called from a Lua function. Not analysed.",
        ],
        "do": ["Compare the UE4SS.log of that run (which mod's callback was running) when it happens again."],
    },
    {
        "id": "game-ragdoll-30e9606",
        "status": "seen",
        "title": "access violation inside the game executable (seen while the player died / ragdoll)",
        "module": "G1R-Win64-Shipping", "top": ["30e9606", "5c22e1a", "5c0efff"],
        "error": r"EXCEPTION_ACCESS_VIOLATION reading address 0x0*108$",
        "binary": GAME_EXE,
        "text": [
            "Seen once (2026-09-30) after 4.4 hours of play; the game's own report listed the abilities GA_Death and",
            "GameplayAbilityRagdoll as active. No frame of UE4SS near the top of the stack. Not analysed.",
        ],
        "do": ["Nothing points at a mod. Keep the report if it happens again."],
    },
]

ACCESS = {0: "reading", 1: "writing", 8: "executing"}
DULL_TAGS = ("Skill.", "Guild.", "Species.", "Character.Can.", "Character.Player", "Difficulty.")


def tag_text(xml, name):
    m = re.search(r"<%s>(.*?)</%s>" % (re.escape(name), re.escape(name)), xml, re.S)
    if not m:
        return None
    text = m.group(1)
    for a, b in (("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'), ("&apos;", "'"), ("&amp;", "&")):
        text = text.replace(a, b)
    return text.strip()


def frames_of(text):
    return [{"module": m.group(1), "base": int(m.group(2), 16), "offset": m.group(3).lower()} for m in FRAME.finditer(text or "")]


def read_context(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        xml = f.read()
    c = {
        "error": tag_text(xml, "ErrorMessage"),
        "type": tag_text(xml, "CrashType"),
        "seconds_since_start": None,
        "build": tag_text(xml, "BuildVersion"),
        "engine": tag_text(xml, "EngineVersion"),
        "is_assert": tag_text(xml, "IsAssert") == "true",
        "is_ensure": tag_text(xml, "IsEnsure") == "true",
        "time_utc": None,
        "frames": frames_of(tag_text(xml, "PCallStack")),
        "threads": 0, "crashed_thread": None, "thread_names": {},
    }
    try:
        c["seconds_since_start"] = int(tag_text(xml, "SecondsSinceStart"))
    except (TypeError, ValueError):
        pass
    ticks = tag_text(xml, "TimeOfCrash")
    try:        # .NET ticks: 100 ns since 0001-01-01
        t = datetime.datetime(1, 1, 1) + datetime.timedelta(microseconds=int(ticks) // 10)
        c["time_utc"] = t.replace(microsecond=0).isoformat(" ")
    except (TypeError, ValueError, OverflowError):
        pass
    for block in re.findall(r"<Thread>(.*?)</Thread>", xml, re.S):
        c["threads"] += 1
        name = tag_text(block, "ThreadName") or "?"
        group = re.sub(r"[\s#]*\d+$", "", name) or name
        c["thread_names"][group] = c["thread_names"].get(group, 0) + 1
        if tag_text(block, "IsCrashed") == "true" and c["crashed_thread"] is None:
            c["crashed_thread"] = {"name": name, "id": tag_text(block, "ThreadID"), "frames": frames_of(tag_text(block, "CallStack"))}
    return c


def read_minidump(path):
    """Exception record and the modules of interest. None when the file is not a minidump."""
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:4] != b"MDMP" or len(raw) < 32:
        return None
    count, directory = struct.unpack_from("<II", raw, 8)
    d = {"exception": None, "modules": []}
    for i in range(count):
        if directory + i * 12 + 12 > len(raw):
            break
        kind, size, rva = struct.unpack_from("<III", raw, directory + i * 12)
        if kind == 4 and rva + 4 <= len(raw):                       # ModuleListStream
            n = struct.unpack_from("<I", raw, rva)[0]
            for k in range(n):
                off = rva + 4 + k * 108
                if off + 24 > len(raw):
                    break
                base, image, checksum, stamp, name_rva = struct.unpack_from("<QIIII", raw, off)
                name = ""
                if name_rva + 4 <= len(raw):
                    length = struct.unpack_from("<I", raw, name_rva)[0]
                    name = raw[name_rva + 4:name_rva + 4 + length].decode("utf-16-le", "replace")
                d["modules"].append({"file": re.split(r"[\\/]", name)[-1], "base": base, "size_of_image": image, "timestamp": stamp})
        elif kind == 6 and rva + 40 <= len(raw):                    # ExceptionStream
            thread, _, code, _, _, address, nparams, _ = struct.unpack_from("<IIIIQQII", raw, rva)
            nparams = min(nparams, 15)
            params = list(struct.unpack_from("<%dQ" % nparams, raw, rva + 40)) if rva + 40 + 8 * nparams <= len(raw) else []
            d["exception"] = {"thread": thread, "code": code, "address": address, "params": params}
    return d


def module_at(modules, address):
    for m in modules:
        if m["base"] <= address < m["base"] + m["size_of_image"]:
            return m
    return None


def read_binary(path):
    with open(path, "rb") as f:
        data = f.read()
    out = {"file": os.path.basename(path), "sha256": hashlib.sha256(data).hexdigest(), "timestamp": None, "size_of_image": None}
    if data[:2] == b"MZ" and len(data) > 0x40:
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        if data[pe:pe + 4] == b"PE\0\0":
            out["timestamp"] = struct.unpack_from("<I", data, pe + 8)[0]
            out["size_of_image"] = struct.unpack_from("<I", data, pe + 24 + 56)[0]
    return out


def read_game_info(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    try:
        j = json.loads(text)
    except ValueError as e:
        return {"problem": "not readable as JSON (%s)" % e}
    game = j.get("game") if isinstance(j, dict) else None
    if not isinstance(game, dict):
        return {"problem": "no 'game' part"}

    def nearest(d, n, skip_zero=False):
        if not isinstance(d, dict):
            return []
        items = [(k, v) for k, v in d.items() if isinstance(v, (int, float)) and not (skip_zero and v == 0)]
        items.sort(key=lambda kv: kv[1])
        return [{"name": k, "distance": round(float(v), 1)} for k, v in items[:n]]

    tags = [t for t in game.get("ownedGameplayTags", []) if isinstance(t, str)]
    return {
        "tags_of_interest": [t for t in tags if not t.startswith(DULL_TAGS)],
        "tag_count": len(tags),
        "active_abilities": [re.sub(r"^Default__", "", a) for a in game.get("activeAbilities", []) if isinstance(a, str)],
        "nearest_spots": nearest(game.get("nearbyInteractionSpots"), 8),
        "nearest_characters": nearest(game.get("nearbyCharacters"), 6, skip_zero=True),
    }


def match_signatures(context, dump, binaries):
    """Every signature whose top frames are at the top of the crashed stack."""
    stack = context["frames"]
    top = [(f["module"], f["offset"]) for f in stack]
    out = []
    for s in SIGNATURES:
        want = [(s["module"], o) for o in s["top"]]
        if top[:len(want)] != want:
            continue
        r = {"id": s["id"], "status": s["status"], "title": s["title"], "frames": len(want), "text": s["text"], "do": s["do"]}
        r["error_matches"] = bool(context["error"] and re.search(s["error"], context["error"]))
        # are the offsets comparable at all? (same binary)
        b = s["binary"]
        identity = "not checked (no minidump, no file given)"
        same = None
        if dump:
            for m in dump["modules"]:
                if m["file"].lower() == b["file"].lower():
                    same = (m["timestamp"] == b["timestamp"] and m["size_of_image"] == b["size_of_image"])
                    identity = "%s in the minidump is %sthe build the offsets belong to (time stamp %08x, image size %x)" % (
                        b["file"], "" if same else "NOT ", m["timestamp"], m["size_of_image"])
        for given in binaries:
            if given["file"].lower() == b["file"].lower() or (b.get("sha256") and given["sha256"] == b["sha256"]):
                if b.get("sha256"):
                    same_file = given["sha256"] == b["sha256"]
                else:
                    same_file = given["timestamp"] == b["timestamp"] and given["size_of_image"] == b["size_of_image"]
                same = same_file if same is None else (same and same_file)
                identity += "; the file given is %sthat build (sha256 %s...)" % ("" if same_file else "NOT ", given["sha256"][:16])
        r["binary_identity"], r["binary_same"] = identity, same
        if same is False:
            r["verdict"] = "frames look alike, but the binary is another build: offsets cannot be compared"
        elif not r["error_matches"]:
            r["verdict"] = "top frames match, the error text differs: related, not the same"
        else:
            r["verdict"] = "MATCH"
        out.append(r)
    return out


def find_file(folder, names):
    for name in names:
        p = os.path.join(folder, name)
        if os.path.isfile(p):
            return p
    return None


def triage(folder, log=None, dlls=()):
    if os.path.isfile(folder):
        folder = os.path.dirname(os.path.abspath(folder))
    r = {"folder": os.path.basename(os.path.normpath(folder)), "files": sorted(os.listdir(folder)), "problems": []}
    xml = find_file(folder, ("CrashContext.runtime-xml",))
    if xml is None:
        r["problems"].append("CrashContext.runtime-xml not found: this is not a crash report folder")
        return r
    c = read_context(xml)
    r["context"] = c
    stack = c["frames"]
    counts, order = {}, []
    for f in stack:
        if f["module"] not in counts:
            order.append(f["module"])
        counts[f["module"]] = counts.get(f["module"], 0) + 1
    r["stack_modules"] = [{"module": m, "frames": counts[m]} for m in order]
    r["top_module"] = stack[0]["module"] if stack else None
    r["first_other"] = None
    for i, f in enumerate(stack):
        if f["module"] != r["top_module"]:
            r["first_other"] = {"index": i, "module": f["module"], "offset": f["offset"]}
            break
    r["ue4ss_frames"] = [i for i, f in enumerate(stack) if f["module"].upper() == "UE4SS"]

    dump_path = find_file(folder, ("UEMinidump.dmp",))
    dump = None
    if dump_path:
        try:
            dump = read_minidump(dump_path)
        except (OSError, struct.error) as e:
            r["problems"].append("UEMinidump.dmp could not be read (%s)" % e)
    if dump and dump["exception"]:
        e = dump["exception"]
        m = module_at(dump["modules"], e["address"])
        r["exception"] = {
            "code": "0x%08X" % e["code"], "thread": e["thread"],
            "at": ("%s+%x" % (re.sub(r"\.(dll|exe)$", "", m["file"], flags=re.I), e["address"] - m["base"])) if m else ("0x%x" % e["address"]),
            "access": (ACCESS.get(e["params"][0], "?") + " address 0x%x" % e["params"][1]) if e["code"] == 0xC0000005 and len(e["params"]) >= 2 else None,
        }
    if dump:
        r["binaries"] = [{"file": m["file"], "timestamp": "%08x" % m["timestamp"], "size_of_image": "%x" % m["size_of_image"]}
                         for m in dump["modules"] if m["file"].lower() in ("ue4ss.dll", GAME_EXE["file"].lower())]
    binaries = []
    for path in dlls:
        try:
            binaries.append(read_binary(path))
        except OSError as e:
            r["problems"].append("%s could not be read (%s)" % (os.path.basename(path), e))
    r["signatures"] = match_signatures(c, dump, binaries)

    info = find_file(folder, ("gothic_crash_info.log",))
    if info:
        r["game"] = read_game_info(info)
    log = log or find_file(folder, ("UE4SS.log",))
    if log and loganalyze is not None:
        a, _ = loganalyze.analyze(log)
        r["log"] = {"file": os.path.basename(log), "last": a["last"], "last_lines": a["last_lines"],
                    "signatures": [{"id": s["id"], "severity": s["severity"], "count": s["count"], "mods": s["mods"], "first": s["first"]}
                                   for s in a["signatures"] if s["severity"] in ("hazard", "error")],
                    "proptype_total": sum(a["proptype"].values())}
        # the log has local time, the report UTC: the difference is a zone offset plus the gap
        if a["last"] and c["time_utc"]:
            last = datetime.datetime.strptime(a["last"][:19], "%Y-%m-%d %H:%M:%S")
            crash = datetime.datetime.strptime(c["time_utc"], "%Y-%m-%d %H:%M:%S")
            diff = (crash - last).total_seconds()
            zone = round(diff / 900.0) * 900
            if abs(zone) <= 14 * 3600:
                r["log"]["ends_before_crash_s"] = round(diff - zone, 1)
                r["log"]["zone_hours"] = -zone / 3600.0
    elif log:
        r["problems"].append("loganalyze.py not found next to this tool: the log was not read")
    return r


def render(r, frames=16):
    L = []
    L.append("crash folder: %s" % r["folder"])
    for p in r["problems"]:
        L.append("PROBLEM: " + p)
    c = r.get("context")
    if not c:
        return "\n".join(L)
    L.append("error:        %s" % c["error"])
    secs = c["seconds_since_start"]
    L.append("type:         %s%s%s, %s after the start, build %s (engine %s)" % (
        c["type"], " (assert)" if c["is_assert"] else "", " (ensure)" if c["is_ensure"] else "",
        ("%d s (%.1f min)" % (secs, secs / 60.0)) if secs is not None else "?", c["build"], c["engine"]))
    L.append("time (UTC):   %s" % c["time_utc"])
    t = c["crashed_thread"]
    L.append("crashed:      thread %s (id %s), %d frames; %d threads in the report" % (
        t["name"] if t else "?", t["id"] if t else "?", len(c["frames"]), c["threads"]))
    if "exception" in r:
        e = r["exception"]
        L.append("minidump:     exception %s at %s%s" % (e["code"], e["at"], (", " + e["access"]) if e["access"] else ""))
    for b in r.get("binaries", []):
        L.append("              %s: time stamp %s, image size %s" % (b["file"], b["timestamp"], b["size_of_image"]))
    L.append("")
    L.append("== crashed thread, top %d of %d frames ==" % (min(frames, len(c["frames"])), len(c["frames"])))
    for i, f in enumerate(c["frames"][:frames]):
        L.append("#%-3d %s+%s" % (i, f["module"], f["offset"]))
    L.append("frames per module (in order of first appearance): " + ", ".join("%s %d" % (m["module"], m["frames"]) for m in r["stack_modules"]))
    if r["top_module"]:
        L.append("top frame is in %s%s" % (r["top_module"], (
            "; first frame of another module: #%d %s+%s" % (r["first_other"]["index"], r["first_other"]["module"], r["first_other"]["offset"]))
            if r["first_other"] else ""))
        if r["top_module"].upper() != "UE4SS":
            L.append("UE4SS frames on this stack: %s" % (("%d (first at #%d)" % (len(r["ue4ss_frames"]), r["ue4ss_frames"][0])) if r["ue4ss_frames"] else "none"))
    L.append("")
    L.append("== known signatures ==")
    if not r["signatures"]:
        L.append("no signature matches: this crash has not been seen before (see dev/AI_GUIDE.md, 'A crash')")
    for s in r["signatures"]:
        L.append("%s: %s  [%s]" % (s["id"], s["verdict"], "cause known" if s["status"] == "analysed" else "recorded, cause NOT known"))
        L.append("    " + s["title"])
        L.append("    top %d frame(s) equal; error text %s; %s" % (s["frames"], "equal" if s["error_matches"] else "different", s["binary_identity"]))
        for x in s["text"]:
            L.append("    " + x)
        for x in s["do"]:
            L.append("    > " + x)
    g = r.get("game")
    if g:
        L.append("")
        L.append("== what the game recorded (gothic_crash_info.log) ==")
        if "problem" in g:
            L.append(g["problem"])
        else:
            L.append("player tags of interest (%d of %d): %s" % (len(g["tags_of_interest"]), g["tag_count"], ", ".join(g["tags_of_interest"]) or "-"))
            L.append("active abilities (%d): %s" % (len(g["active_abilities"]), ", ".join(g["active_abilities"]) or "-"))
            L.append("nearest interaction spots: " + (", ".join("%s (%.0f)" % (s["name"], s["distance"]) for s in g["nearest_spots"]) or "-"))
            L.append("nearest characters: " + (", ".join("%s (%.0f)" % (s["name"], s["distance"]) for s in g["nearest_characters"]) or "-"))
    lg = r.get("log")
    if lg:
        L.append("")
        L.append("== %s ==" % lg["file"])
        if "ends_before_crash_s" in lg:
            L.append("the log ends %.0f s before the time of the report (log clock taken as UTC%+g h)" % (lg["ends_before_crash_s"], lg["zone_hours"]))
        for s in lg["signatures"]:
            L.append("%s %s, %d x%s: %s" % (s["severity"], s["id"], s["count"], (" [" + ", ".join(s["mods"]) + "]") if s["mods"] else "", s["first"][:160]))
        if lg["proptype_total"]:
            L.append("[DEBUG_PROPTYPE] lines: %d" % lg["proptype_total"])
        L.append("last lines:")
        for x in lg["last_lines"]:
            L.append("    " + x)
    else:
        L.append("")
        L.append("no UE4SS.log in the folder (copy it next to the report, or give it with --log)")
    return "\n".join(L)


def main(argv=None):
    ap = argparse.ArgumentParser(description="First look at a crash report folder of the game.")
    ap.add_argument("folder", help="the crash report folder (or its CrashContext.runtime-xml)")
    ap.add_argument("--log", help="UE4SS.log of that run (default: the one in the folder)")
    ap.add_argument("--dll", action="append", default=[], metavar="FILE",
                    help="UE4SS.dll (or the game executable) as installed, to check that offsets are comparable (repeatable)")
    ap.add_argument("--frames", type=int, default=16, help="frames of the crashed thread to print (default 16)")
    ap.add_argument("--json", action="store_true", help="print the result as JSON")
    args = ap.parse_args(argv)
    if not os.path.exists(args.folder):
        print("not found: %s" % args.folder, file=sys.stderr)
        return 2
    r = triage(args.folder, args.log, args.dll)
    if args.json:
        print(json.dumps(r, indent=1))
    else:
        print(render(r, args.frames))
    return 0 if not r["problems"] else 1


if __name__ == "__main__":
    sys.exit(main())
