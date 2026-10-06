#!/usr/bin/env python3
"""What a UE4SS.log says: which mods started, what each one logged, what looks wrong.

    python dev/tools/loganalyze.py <UE4SS.log>
    python dev/tools/loganalyze.py <UE4SS.log> --mod G1R_MegaMod      lines of one mod
    python dev/tools/loganalyze.py <UE4SS.log> --json

The log is the one next to UE4SS.dll (it is rewritten at every start of the
game, so it holds one run). Nothing is changed; the file is only read.
Python 3.8+, standard library only.
"""
import argparse
import datetime
import json
import os
import re
import sys

sys.dont_write_bytecode = True

STAMP = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?:\.(\d+))?\] ?(.*)$")
START_MOD = re.compile(r"^Starting (Lua|C\+\+) mod '([^']+)'")
START_BLOCK = re.compile(r"^Starting mods \(from (mods\.txt|enabled\.txt)")
DISABLED = re.compile(r"^Mod '([^']+)' disabled in mods\.txt")
VERSION = re.compile(r"^UE4SS - (v\S+(?: \S+)*?) - Git SHA #(\w+)")
TAG = re.compile(r"^(?:\[Lua\] )?\[([A-Za-z0-9_ .+-]{1,48})\] ?(.*)$")
PROPTYPE = re.compile(r"^\[DEBUG_PROPTYPE\] Property '([^']+)'")
# member offsets UE4SS prints at start (FArchiveState::ArIsError = 0x29 ...): not errors
OFFSET_DUMP = re.compile(r"^[\w:<>~ ]+::[\w~]+ = 0x[0-9A-Fa-f]+$")

# id, severity, pattern, meaning
SIGNATURES = [
    ("hook-retry", "hazard", re.compile(r"not loaded yet, will retry", re.I),
     "a mod retries RegisterHook on a function that was not found; in this UE4SS build every retry walks all "
     "objects in memory (the cause of the crash of 2026-10-01)"),
    ("megamod-lookup-repeat", "hazard", re.compile(r"NOT FOUND again"),
     "the megamod recorded a repeated search for a path that was not found (each one walks all objects)"),
    ("lua-error", "error", re.compile(r"stack traceback:|attempt to (?:index|call|perform|compare|concatenate)|\[Lua\]\[Error\]|\[Lua\] Error", re.I),
     "a Lua error reached UE4SS (the callback it happened in was aborted)"),
    ("megamod-error", "error", re.compile(r"\[G1R_MegaMod\] error in |\] module \w+ failed to load"),
     "the megamod caught an error in a module (details in Scripts/diagnostics/)"),
    ("fatal", "error", re.compile(r"\bFATAL\b"),
     "a mod gave up (its own FATAL line)"),
    ("class-not-found", "warning", re.compile(r"Class not found"),
     "a class was looked up by name and does not exist (other game version?)"),
    ("cannot-be-read", "warning", re.compile(r"cannot be read"),
     "game data a module relies on was not readable"),
    ("did-not-work", "warning", re.compile(r"did not work"),
     "an action of a module had no effect in the game"),
    ("diag-file-output-off", "warning", re.compile(r"file output switched off"),
     "the megamod could not write its diagnostics files"),
    ("config-invalid", "warning", re.compile(r"config\.lua (?:missing or invalid|has an error)"),
     "a settings file could not be read; defaults or the last good settings are used"),
    ("ue4ss-scan-failed", "info", re.compile(r"^\[PS\] Failed to find "),
     "UE4SS could not find one of its optional engine functions at start (usual for this game)"),
]
ERROR_WORDS = re.compile(r"\b(?:error|errors|failed|failure|exception|fatal)\b", re.I)


def parse_time(text, fraction):
    try:
        t = datetime.datetime.strptime(text, "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None
    if fraction:
        t = t.replace(microsecond=int((fraction + "000000")[:6]))
    return t


def read_entries(path):
    """The log as entries {n, time, text, extra}: lines without a time stamp belong to the line before."""
    entries = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for number, raw in enumerate(f, 1):
            line = raw.rstrip("\r\n")
            m = STAMP.match(line)
            if m:
                entries.append({"n": number, "time": parse_time(m.group(1), m.group(2)), "text": m.group(3), "extra": []})
            elif entries:
                entries[-1]["extra"].append(line)
            elif line.strip():
                entries.append({"n": number, "time": None, "text": line, "extra": []})
    return entries


def analyze(path, megamod="G1R_MegaMod"):
    entries = read_entries(path)
    out = {
        "file": os.path.basename(path), "lines": sum(1 + len(e["extra"]) for e in entries), "entries": len(entries),
        "first": None, "last": None, "seconds": None, "sessions": [], "mods": [], "disabled": [],
        "proptype": {}, "signatures": [], "error_lines": [], "megamod": None, "last_lines": [],
    }
    if not entries:
        return out, entries
    times = [e["time"] for e in entries if e["time"] is not None]
    if times:
        out["first"], out["last"] = times[0].isoformat(" "), times[-1].isoformat(" ")
        out["seconds"] = round((times[-1] - times[0]).total_seconds(), 1)

    mods, by_name = [], {}
    tag_owner = {}                 # tag -> mod name (learned while that mod was starting)
    current = None                 # the mod whose start is running
    proptype, sig_hits = {}, {}
    for e in entries:
        text = e["text"]
        m = VERSION.match(text)
        if m:
            out["sessions"].append({"line": e["n"], "version": m.group(1), "git": m.group(2),
                                    "time": e["time"].isoformat(" ") if e["time"] else None})
            current = None
            continue
        m = START_MOD.match(text)
        if m:
            name = m.group(2)
            mod = by_name.get(name)
            if mod is None:
                mod = {"name": name, "kinds": [], "start_line": e["n"], "tags": [], "lines": 0, "load_line": None,
                       "errors": 0, "first_error": None}
                by_name[name] = mod
                mods.append(mod)
            if m.group(1) not in mod["kinds"]:
                mod["kinds"].append(m.group(1))
            current = mod
            continue
        if START_BLOCK.match(text):
            current = None
            continue
        m = DISABLED.match(text)
        if m:
            out["disabled"].append(m.group(1))
            continue
        m = PROPTYPE.match(text)
        if m:
            proptype[m.group(1)] = proptype.get(m.group(1), 0) + 1
            e["proptype"] = True
            continue
        owner, tag = None, None
        m = TAG.match(text)
        if m and m.group(1) not in ("Lua", "PS", "DEBUG_PROPTYPE"):
            tag = m.group(1)
            if current is not None and tag not in tag_owner:
                tag_owner[tag] = current["name"]
                current["tags"].append(tag)
            owner = by_name.get(tag_owner.get(tag) or tag)
        elif current is not None and text.startswith("[Lua] "):
            owner = current
        if owner is not None:
            owner["lines"] += 1
            e["mod"], e["tag"] = owner["name"], tag
            if owner["load_line"] is None and re.search(r"\bloaded\b|\bLoaded\b|\bboot\b", text):
                owner["load_line"] = text[:300]
        for sig_id, severity, pattern, meaning in SIGNATURES:
            if pattern.search(text) or any(pattern.search(x) for x in e["extra"]):
                hit = sig_hits.setdefault(sig_id, {"id": sig_id, "severity": severity, "count": 0, "meaning": meaning,
                                                   "first_line": e["n"], "first": text[:300], "mods": []})
                hit["count"] += 1
                if owner is not None and owner["name"] not in hit["mods"]:
                    hit["mods"].append(owner["name"])
        if ERROR_WORDS.search(text) and not OFFSET_DUMP.match(text) and not text.startswith("[PS] "):
            out["error_lines"].append({"line": e["n"], "mod": owner["name"] if owner else None, "text": text[:300]})
            if owner is not None:
                owner["errors"] += 1
                if owner["first_error"] is None:
                    owner["first_error"] = text[:300]

    out["mods"] = mods
    out["proptype"] = proptype
    order = {"hazard": 0, "error": 1, "warning": 2, "info": 3}
    out["signatures"] = sorted(sig_hits.values(), key=lambda h: (order[h["severity"]], -h["count"]))
    mega = by_name.get(megamod)
    if mega is not None:
        groups = {}
        for e in entries:
            if e.get("mod") == megamod:
                groups.setdefault(e.get("tag") or "(no tag)", []).append(e["text"][:300])
        out["megamod"] = {"lines": mega["lines"], "by_tag": {k: {"lines": len(v), "first": v[0], "last": v[-1]} for k, v in groups.items()}}
    # the end of the log, runs of debug lines folded
    tail, run = [], 0
    for e in reversed(entries):
        if e.get("proptype"):
            run += 1
            continue
        if run:
            tail.append("(%d [DEBUG_PROPTYPE] lines)" % run)
            run = 0
        tail.append(("%s  %s" % (e["time"].strftime("%H:%M:%S") if e["time"] else "--:--:--", e["text"]))[:260])
        if len(tail) >= 15:
            break
    if run:
        tail.append("(%d [DEBUG_PROPTYPE] lines)" % run)
    out["last_lines"] = list(reversed(tail))
    return out, entries


def render(a, show_mod=None, entries=None, limit=200):
    L = []
    L.append("%s: %d lines, %s .. %s (%s s)" % (a["file"], a["lines"], a["first"], a["last"], a["seconds"]))
    if not a["sessions"]:
        L.append("no UE4SS start line found (not a UE4SS.log, or cut off)")
    for s in a["sessions"]:
        L.append("UE4SS %s, git %s, started %s (line %d)" % (s["version"], s["git"], s["time"], s["line"]))
    if len(a["sessions"]) > 1:
        L.append("NOTE: %d start lines - the file holds more than one run" % len(a["sessions"]))
    L.append("")
    L.append("== mods started (%d) ==" % len(a["mods"]))
    for m in a["mods"]:
        L.append("%-28s %-8s line %-6d %5d line(s) logged%s" % (m["name"], "/".join(m["kinds"]), m["start_line"], m["lines"],
                                                                 (", %d error-looking" % m["errors"]) if m["errors"] else ""))
        if m["load_line"]:
            L.append("    " + m["load_line"][:200])
        if m["first_error"]:
            L.append("    first error-looking line: " + m["first_error"][:200])
    if a["disabled"]:
        L.append("disabled in mods.txt: " + ", ".join(a["disabled"]))
    L.append("")
    L.append("== known signatures ==")
    if not a["signatures"]:
        L.append("(none)")
    for s in a["signatures"]:
        L.append("%-8s %-24s %5d x  first at line %d%s" % (s["severity"], s["id"], s["count"], s["first_line"],
                                                           (" [" + ", ".join(s["mods"]) + "]") if s["mods"] else ""))
        L.append("    " + s["meaning"])
        L.append("    " + s["first"][:200])
    L.append("")
    L.append("== [DEBUG_PROPTYPE] lines (one per Lua read of a property with that name) ==")
    if not a["proptype"]:
        L.append("(none)")
    total = sum(a["proptype"].values())
    for name, count in sorted(a["proptype"].items(), key=lambda kv: -kv[1]):
        L.append("%-34s %7d" % (name, count))
    if total and a["seconds"]:
        L.append("total %d, %.0f per minute" % (total, total * 60.0 / max(a["seconds"], 1.0)))
    if a["megamod"]:
        L.append("")
        L.append("== megamod lines by tag ==")
        for tag, g in sorted(a["megamod"]["by_tag"].items()):
            L.append("[%s] %d line(s)" % (tag, g["lines"]))
            L.append("    first: " + g["first"][:200])
            if g["lines"] > 1:
                L.append("    last:  " + g["last"][:200])
    L.append("")
    L.append("== error-looking lines (%d) ==" % len(a["error_lines"]))
    for e in a["error_lines"][:25]:
        L.append("%6d %s%s" % (e["line"], ("[" + e["mod"] + "] ") if e["mod"] else "", e["text"][:200]))
    if len(a["error_lines"]) > 25:
        L.append("(%d more)" % (len(a["error_lines"]) - 25))
    L.append("")
    L.append("== end of the log ==")
    L.extend(a["last_lines"])
    if show_mod and entries is not None:
        L.append("")
        L.append("== lines of %s ==" % show_mod)
        shown = 0
        for e in entries:
            if e.get("mod") == show_mod:
                shown += 1
                if shown <= limit:
                    L.append("%6d %s  %s" % (e["n"], e["time"].strftime("%H:%M:%S") if e["time"] else "--:--:--", e["text"][:240]))
                    for x in e["extra"][:20]:
                        L.append("         " + x[:240])
        if shown > limit:
            L.append("(%d more; raise --limit)" % (shown - limit))
        if shown == 0:
            L.append("(no line; mods in this log: %s)" % ", ".join(m["name"] for m in a["mods"]))
    return "\n".join(L)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Summary of a UE4SS.log.")
    ap.add_argument("log", help="path of the UE4SS.log")
    ap.add_argument("--mod", help="also list the lines of this mod")
    ap.add_argument("--limit", type=int, default=200, help="most lines listed with --mod (default 200)")
    ap.add_argument("--megamod", default="G1R_MegaMod", help="name of the megamod's folder (default G1R_MegaMod)")
    ap.add_argument("--json", action="store_true", help="print the result as JSON")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.log):
        print("not a file: %s" % args.log, file=sys.stderr)
        return 2
    a, entries = analyze(args.log, args.megamod)
    if args.json:
        print(json.dumps(a, indent=1))
    else:
        print(render(a, args.mod, entries, args.limit))
    return 0


if __name__ == "__main__":
    sys.exit(main())
