#!/usr/bin/env python3
"""Reads the mod's own diagnostics (Scripts/diagnostics/) after a play session.

    python dev/tools/diagread.py <diagnostics folder>            summary of the newest session, report and dump
    python dev/tools/diagread.py <folder> --session 2            the session before the newest (3: the one before that;
                                                                 or a name: session-20261005-121500)
    python dev/tools/diagread.py <folder> --facts dev/FACTS.md   compare the notes with what the code assumes
    python dev/tools/diagread.py <session-...log | session-...ops | report-...txt | dump-...lua>
    python dev/tools/diagread.py <dump-...lua> --fixture OUT.lua turn a dump into a fixture file for the harnesses
    python dev/tools/diagread.py <folder> --json

What to look at first: the list of sessions (after a crash the session to read is
usually the one BEFORE the newest: the game was started again since), `ended
inside` (the operations file's newest record was begun and never finished, or
the session log ends with a breadcrumb: the game most likely went down in that
step), `errors`, `repeated searches` (each one walks every object of the game),
and the facts table.
With a folder, dev/FACTS.md next to this tool is used for the facts table
unless --no-facts is given. Nothing is changed; files are only read.
Python 3.8+, standard library only.
"""
import argparse
import json
import os
import re
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))

SESSION_NAME = re.compile(r"^session-\d{8}-\d{6}\.log$")
OPS_NAME = re.compile(r"^session-\d{8}-\d{6}\.ops$")
SESSION_REPORT_NAME = re.compile(r"^session-\d{8}-\d{6}\.report\.txt$")
# One record of an operations file (Scripts/core/diag.lua, "Operations"): fixed size, the line end included.
OPS_WIDTH = 128
OPS_RECORD = re.compile(r"^(\d{8}) ([>=]) (\d\d:\d\d:\d\d) (.{10}) (.*?) *\n$", re.S)
REPORT_NAME = re.compile(r"^report-(?:latest|\d{8}-\d{6})\.txt$")
DUMP_NAME = re.compile(r"^dump-\d{8}-\d{6}\.lua$")
LINE = re.compile(r"^(\d\d:\d\d:\d\d) \[([^\]]+)\] (.*)$")
NOTE_LINE = re.compile(r"^note (\S+) = (.*?)(?: \[was (.*?)\](?: \(further changes of this note are only counted\))?)?$")
LOOKUP_LINE = re.compile(r"^lookup (.+?): (found|NOT FOUND|RAISED)(.*)$")
REPORT_NOTE = re.compile(r"^(\S+) = (.*) \[first seen (\d\d:\d\d:\d\d)\](?: \[changed (\d+) time\(s\), last (\d\d:\d\d:\d\d), first value: (.*)\])?$")


def read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


# --------------------------------------------------------------------------- session log
def read_session(path, tail=25):
    lines = [l for l in read_text(path).split("\n") if l != ""]
    s = {"file": os.path.basename(path), "lines": len(lines), "first": None, "last": None, "start": None, "load": None,
         "modules": {}, "errors": [], "crumbs": 0, "ended_inside": None, "lookups": {"first_time": 0, "found": 0},
         "not_found": [], "repeated": [], "raised": [], "slow": 0, "notes": {}, "ignored_calls": [], "unparsed": 0,
         "tail": lines[-tail:]}
    last_parsed = None
    for raw in lines:
        m = LINE.match(raw)
        if not m:
            s["unparsed"] += 1
            continue
        stamp, module, text = m.groups()
        last_parsed = (stamp, module, text)
        if s["first"] is None:
            s["first"] = stamp
        s["last"] = stamp
        s["modules"][module] = s["modules"].get(module, 0) + 1
        if module == "loader" and text.startswith("session start: "):
            s["start"] = text[len("session start: "):]
        elif module == "loader" and re.match(r"^v\S+ loaded: ", text):
            s["load"] = text
        if text.startswith("> "):
            s["crumbs"] += 1
            continue
        if text.startswith("ERROR in "):
            s["errors"].append({"time": stamp, "module": module, "text": text})
            continue
        if text.startswith("slow callback: "):
            s["slow"] += 1
            continue
        if text.startswith("diagnostics call ignored: "):
            s["ignored_calls"].append("[%s] %s" % (module, text))
            continue
        m2 = NOTE_LINE.match(text)
        if m2:
            key, shown, was = m2.groups()
            n = s["notes"].setdefault(module + "/" + key, {"module": module, "key": key, "first": shown, "at": stamp, "changes": 0})
            if was is not None:
                n["changes"] += 1
            n["shown"] = shown
            continue
        m2 = LOOKUP_LINE.match(text)
        if m2:
            path_, outcome, rest = m2.groups()
            if outcome == "RAISED":
                s["raised"].append("[%s] %s%s" % (module, path_, rest))
            elif outcome == "found":
                if "found again" not in rest:
                    s["lookups"]["first_time"] += 1
                    s["lookups"]["found"] += 1
                if "after" in rest:
                    s["repeated"].append("[%s] %s: found%s" % (module, path_, rest.split(",")[0]))
            else:
                if rest.startswith(" again"):
                    s["repeated"].append("[%s] %s: NOT FOUND%s" % (module, path_, rest.split(",")[0]))
                elif rest.startswith(" any more"):
                    s["not_found"].append("[%s] %s (was found earlier)" % (module, path_))
                else:
                    s["lookups"]["first_time"] += 1
                    s["not_found"].append("[%s] %s" % (module, path_))
    if last_parsed and last_parsed[2].startswith("> "):
        s["ended_inside"] = "%s [%s] %s" % (last_parsed[0], last_parsed[1], last_parsed[2][2:])
    return s


# --------------------------------------------------------------------------- operations
def read_ops(path, tail=8):
    """The ring of the last operations of a session: what called into the game, begun (>) and finished (=).

    The newest record is the one with the highest number. When it was begun and never finished, the game
    went down inside that operation (or the session is still running and is inside it right now). An older
    record that was never finished is an operation that raised a Lua error before it could be taken back.
    """
    with open(path, "rb") as f:
        data = f.read()
    o = {"file": os.path.basename(path), "bytes": len(data), "records": 0, "unreadable": 0, "first": None, "last": None,
         "newest": None, "ended_inside": None, "open_earlier": [], "tail": []}
    records = []
    for at in range(0, len(data), OPS_WIDTH):
        raw = data[at:at + OPS_WIDTH].decode("latin-1")
        m = OPS_RECORD.match(raw) if len(raw) == OPS_WIDTH else None
        if not m:
            o["unreadable"] += 1          # a record cut off by the end of the file, or not one
            continue
        number, state, stamp, module, text = m.groups()
        records.append({"number": int(number), "state": state, "time": stamp, "module": module.strip(), "text": text})
    records.sort(key=lambda r: r["number"])
    o["records"] = len(records)
    if records:
        def show(r):
            return "#%d %s [%s] %s" % (r["number"], r["time"], r["module"], r["text"])
        o["first"], o["last"] = records[0]["number"], records[-1]["number"]
        newest_record = records[-1]
        o["newest"] = dict(newest_record, shown=show(newest_record))
        if newest_record["state"] == ">":
            o["ended_inside"] = show(newest_record)
        o["open_earlier"] = [show(r) for r in records[:-1] if r["state"] == ">"]
        o["tail"] = ["%s %s" % ("  begun, NOT finished" if r["state"] == ">" else "  finished           ", show(r)) for r in records[-tail:]]
    return o


def session_state(folder, log_name):
    """One line about a session of a folder: did it end inside something?"""
    base = log_name[:-4]
    state = {"log": log_name, "inside": None, "how": None}
    ops = os.path.join(folder, base + ".ops")
    if os.path.isfile(ops):
        try:
            inside = read_ops(ops)["ended_inside"]
        except OSError:
            inside = None
        if inside:
            state["inside"], state["how"] = inside, "operation"
    if state["inside"] is None:
        try:
            inside = read_session(os.path.join(folder, log_name), 1)["ended_inside"]
        except OSError:
            inside = None
        if inside:
            state["inside"], state["how"] = inside, "breadcrumb"
    return state


# --------------------------------------------------------------------------- report
def read_report(path):
    lines = read_text(path).split("\n")
    r = {"file": os.path.basename(path), "title": lines[0] if lines else "", "header": {}, "parts": {}, "notes": {}}
    part = None
    for raw in lines[1:]:
        if raw.startswith("== ") and raw.endswith(" =="):
            part = raw[3:-3]
            if part.startswith("last ") and part.endswith("recorder lines"):
                part = "recorder"
            r["parts"][part] = []
            continue
        if part is None:
            if ": " in raw:
                k, v = raw.split(": ", 1)
                r["header"][k] = v
        elif raw != "":
            r["parts"][part].append(raw)
    module = None
    for raw in r["parts"].get("notes", []):
        m = re.match(r"^\[([^\]]+)\]$", raw)
        if m:
            module = m.group(1)
            continue
        m = REPORT_NOTE.match(raw)
        if m and module:
            key, shown, at, changes, _last, first = m.groups()
            r["notes"][module + "/" + key] = {"module": module, "key": key, "shown": shown, "at": at,
                                              "changes": int(changes or 0), "first": first if first is not None else shown}
    errors = r["parts"].get("errors", [])
    m = re.match(r"^count: (\d+) \((\d+) distinct", errors[0]) if errors else None
    r["error_count"] = int(m.group(1)) if m else None
    r["error_heads"] = [l for l in errors[1:] if l.startswith("[")]
    return r


# --------------------------------------------------------------------------- dump (the subset of Lua the mod writes)
class DumpError(ValueError):
    pass


def parse_dump(text):
    """The table a dump file returns, as dicts (keys: text or number)."""
    pos = [0]
    n = len(text)

    def skip():
        while pos[0] < n:
            c = text[pos[0]]
            if c in " \t\r\n":
                pos[0] += 1
            elif text.startswith("--", pos[0]):
                j = text.find("\n", pos[0])
                pos[0] = n if j < 0 else j
            else:
                break

    def expect(tok):
        skip()
        if not text.startswith(tok, pos[0]):
            raise DumpError("expected %r at offset %d" % (tok, pos[0]))
        pos[0] += len(tok)

    def string():
        out = []
        pos[0] += 1
        while True:
            if pos[0] >= n:
                raise DumpError("text without an end")
            c = text[pos[0]]
            if c == '"':
                pos[0] += 1
                return "".join(out)
            if c == "\\":
                m = re.compile(r"\\(\d{1,3})").match(text, pos[0])
                if m:
                    out.append(chr(int(m.group(1))))
                    pos[0] = m.end()
                else:
                    out.append({"n": "\n", "t": "\t", "\\": "\\", '"': '"'}.get(text[pos[0] + 1:pos[0] + 2], "?"))
                    pos[0] += 2
            else:
                out.append(c)
                pos[0] += 1

    def value(depth):
        skip()
        if depth > 64:
            raise DumpError("nested too deep")
        c = text[pos[0]:pos[0] + 1]
        if c == '"':
            return string()
        if c == "{":
            pos[0] += 1
            table = {}
            while True:
                skip()
                if text.startswith("}", pos[0]):
                    pos[0] += 1
                    return table
                expect("[")
                key = value(depth + 1)
                expect("]")
                expect("=")
                table[key] = value(depth + 1)
                skip()
                if text.startswith(",", pos[0]):
                    pos[0] += 1
        for word, v in (("true", True), ("false", False), ("(0/0)", float("nan")), ("(1/0)", float("inf")),
                        ("(-1/0)", float("-inf")), ("(-9223372036854775807-1)", -9223372036854775808)):
            if text.startswith(word, pos[0]):
                pos[0] += len(word)
                return v
        m = re.compile(r"-?(?:\d+\.?\d*(?:[eE][+-]?\d+)?)").match(text, pos[0])
        if m:
            pos[0] = m.end()
            t = m.group(0)
            return float(t) if any(ch in t for ch in ".eE") else int(t)
        raise DumpError("unexpected text at offset %d: %r" % (pos[0], text[pos[0]:pos[0] + 20]))

    expect("return")
    result = value(0)
    skip()
    if pos[0] != n:
        raise DumpError("text after the table at offset %d" % pos[0])
    if not isinstance(result, dict):
        raise DumpError("the file does not return a table")
    return result


def is_list(d):
    return isinstance(d, dict) and len(d) > 0 and all(isinstance(k, int) for k in d) and sorted(d) == list(range(1, len(d) + 1))


def shape(v):
    if isinstance(v, dict):
        if not v:
            return "empty"
        return ("list of %d" % len(v)) if is_list(v) else ("table with %d keys" % len(v))
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return '"%s"' % (v if len(v) < 60 else v[:57] + "...")
    return repr(v)


def read_dump(path):
    d = {"file": os.path.basename(path), "problem": None, "meta": {}, "modules": {}}
    try:
        table = parse_dump(read_text(path))
    except DumpError as e:
        d["problem"] = "cannot be read (%s)" % e
        return d
    meta = table.get("_meta") or {}
    d["meta"] = {"mod": meta.get("mod"), "version": meta.get("version"), "time": meta.get("time"), "minutes": meta.get("minutes"),
                 "modules": meta.get("modules") or {}, "refused": [meta["refused"][k] for k in sorted(meta.get("refused") or {})],
                 "refused_count": meta.get("refusedCount")}
    for name, value in table.items():
        if name == "_meta" or not isinstance(value, dict):
            continue
        d["modules"][name] = {str(k): shape(v) for k, v in value.items()}
    return d


def write_fixture(dump_path, out_path):
    text = read_text(dump_path)
    parse_dump(text)        # refuses a file that is not a dump
    body = text if text.endswith("\n") else text + "\n"
    with open(out_path, "w", encoding="ascii", errors="backslashreplace", newline="\n") as f:
        f.write("-- Fixture made from %s by dev/tools/diagread.py --fixture.\n" % os.path.basename(dump_path))
        f.write("-- What the modules' dump providers returned in a real game session; load with dofile().\n")
        f.write(body)


# --------------------------------------------------------------------------- facts
def read_facts(path):
    """Rows `| `key` | expected | ...` of the notes tables in FACTS.md and in facts/*.md next to it.

    The second cell: values in backticks; those before the word `else` are expected, those after it are
    fallbacks the code handles. No backticks: any value. -> {key: {expected: [...] or None, fallback: [...]}}
    """
    facts = {}
    # the file itself, and the facts files of the single modules in the folder `facts` next to it
    texts = [read_text(path)]
    more = os.path.join(os.path.dirname(os.path.abspath(path)), "facts")
    if os.path.isdir(more):
        for name in sorted(os.listdir(more)):
            if name.endswith(".md"):
                texts.append(read_text(os.path.join(more, name)))
    for raw in "\n".join(texts).split("\n"):
        cells = [c.strip() for c in raw.strip().strip("|").split("|")]
        if len(cells) < 2:
            continue
        m = re.match(r"^`([a-z_]+\.[A-Za-z0-9_.]+)`$", cells[0])
        if not m:
            continue
        first, _, second = cells[1].partition(" else ")
        expected = re.findall(r"`([^`]+)`", first)
        facts[m.group(1)] = {"expected": expected or None, "fallback": re.findall(r"`([^`]+)`", second),
                             "text": cells[1], "meaning": cells[2] if len(cells) > 2 else ""}
    return facts


def matches(shown, alternative):
    if alternative.startswith("re:"):
        return re.search(alternative[3:], shown) is not None
    return shown == alternative or shown.startswith(alternative + " (")


def compare_facts(facts, notes):
    """notes: {module/key: {...}} -> rows (key, verdict, shown, expected text)."""
    by_key = {}
    for n in notes.values():
        by_key.setdefault(n["key"], n)
    rows = []
    for key in sorted(facts):
        f = facts[key]
        n = by_key.get(key)
        if n is None:
            rows.append({"key": key, "verdict": "not seen", "shown": None, "expected": f["text"]})
        elif f["expected"] is None:
            rows.append({"key": key, "verdict": "seen", "shown": n["shown"], "expected": f["text"]})
        elif any(matches(n["shown"], a) for a in f["expected"]):
            rows.append({"key": key, "verdict": "as expected", "shown": n["shown"], "expected": f["text"]})
        elif any(matches(n["shown"], a) for a in f["fallback"]):
            rows.append({"key": key, "verdict": "fallback in use", "shown": n["shown"], "expected": f["text"]})
        else:
            rows.append({"key": key, "verdict": "DIFFERS", "shown": n["shown"], "expected": f["text"]})
        if n is not None and n.get("changes"):
            rows[-1]["changes"] = n["changes"]
            rows[-1]["first"] = n.get("first")
    for key in sorted(by_key):
        if key not in facts:
            rows.append({"key": key, "verdict": "not in FACTS.md", "shown": by_key[key]["shown"], "expected": ""})
    return rows


# --------------------------------------------------------------------------- everything
def newest(names, pattern):
    hits = sorted(n for n in names if pattern.match(n))
    return hits[-1] if hits else None


def pick_session(names, which):
    """The session log `which` names: None / 1 = the newest, 2 = the one before, ...; or (part of) a name."""
    sessions = sorted(n for n in names if SESSION_NAME.match(n))
    if not sessions:
        return None, None
    if which is None:
        return sessions[-1], None
    text = str(which)
    if re.match(r"^\d{1,3}$", text):
        back = int(text)
        if back < 1 or back > len(sessions):
            return None, "there is no session %d (the folder has %d; 1 is the newest)" % (back, len(sessions))
        return sessions[-back], None
    hits = [n for n in sessions if text in n]
    if len(hits) != 1:
        return None, "%s names %s session log of this folder" % (text, "no" if not hits else "more than one")
    return hits[0], None


def read_all(path, facts_path=None, tail=25, which=None):
    out = {"path": os.path.basename(os.path.normpath(path)), "files": None, "sessions": None, "session": None, "ops": None,
           "report": None, "dump": None, "facts": None, "problems": []}
    session = report = dump = ops = None
    if os.path.isdir(path):
        names = sorted(os.listdir(path))
        out["files"] = {"sessions": [n for n in names if SESSION_NAME.match(n)],
                        "reports": [n for n in names if REPORT_NAME.match(n)],
                        "dumps": [n for n in names if DUMP_NAME.match(n)],
                        "operations": [n for n in names if OPS_NAME.match(n)],
                        "session reports": [n for n in names if SESSION_REPORT_NAME.match(n)]}
        out["sessions"] = [session_state(path, n) for n in out["files"]["sessions"]]
        s, problem = pick_session(names, which)
        if problem:
            out["problems"].append(problem)
        d = newest(names, DUMP_NAME)
        session = os.path.join(path, s) if s else None
        dump = os.path.join(path, d) if d else None
        is_newest = s is not None and s == newest(names, SESSION_NAME)
        if s and (s[:-4] + ".report.txt") in names:
            report = os.path.join(path, s[:-4] + ".report.txt")       # the session's own report
        elif "report-latest.txt" in names and (is_newest or s is None) and not problem:
            report = os.path.join(path, "report-latest.txt")
        if s and (s[:-4] + ".ops") in names:
            ops = os.path.join(path, s[:-4] + ".ops")
        if not (session or report or dump) and not problem:
            out["problems"].append("no session log, report or dump in this folder (was the game started with the mod, and is "
                                   "Config.Diagnostics.Level not \"off\"?)")
    else:
        name = os.path.basename(path)
        folder = os.path.dirname(os.path.abspath(path))
        if name.endswith(".lua"):
            dump = path
        elif OPS_NAME.match(name):
            ops = path
        elif name.startswith("report") or SESSION_REPORT_NAME.match(name):
            report = path
        else:
            session = path
            if SESSION_NAME.match(name) and os.path.isfile(os.path.join(folder, name[:-4] + ".ops")):
                ops = os.path.join(folder, name[:-4] + ".ops")      # what belongs to this session log
    if session:
        out["session"] = read_session(session, tail)
    if ops:
        try:
            out["ops"] = read_ops(ops)
        except OSError as e:
            out["problems"].append("operations file not readable (%s)" % e)
    if report:
        out["report"] = read_report(report)
    if dump:
        out["dump"] = read_dump(dump)
    notes = {}
    if out["session"]:
        notes.update(out["session"]["notes"])
    if out["report"]:
        notes.update(out["report"]["notes"])        # the report has the latest values
    out["notes"] = [notes[k] for k in sorted(notes)]
    if facts_path:
        try:
            out["facts"] = compare_facts(read_facts(facts_path), notes)
        except OSError as e:
            out["problems"].append("facts file not readable (%s)" % e)
    return out


def render(a):
    L = ["diagnostics: %s" % a["path"]]
    for p in a["problems"]:
        L.append("PROBLEM: " + p)
    if a["files"]:
        f = a["files"]
        L.append("files: %d session log(s), %d report(s), %d dump(s); %d operations file(s), %d report(s) kept per session"
                 % (len(f["sessions"]), len(f["reports"]), len(f["dumps"]), len(f.get("operations", [])), len(f.get("session reports", []))))
    if a.get("sessions"):
        L.append("sessions, oldest first (the one read below is marked; --session 2 reads the one before the newest):")
        read = a["session"]["file"] if a["session"] else None
        for st in a["sessions"]:
            if st["inside"]:
                state = "ENDED INSIDE %s: %s" % ("AN OPERATION" if st["how"] == "operation" else "A STEP (breadcrumb)", st["inside"])
            else:
                state = "nothing was under way at its end"
            L.append("  %s %s  %s" % ("*" if st["log"] == read else " ", st["log"], state))
    s = a["session"]
    if s:
        L.append("")
        L.append("== session log %s ==" % s["file"])
        L.append("%d lines, %s .. %s" % (s["lines"], s["first"], s["last"]))
        if s["start"]:
            L.append("start: " + s["start"])
        L.append("load:  " + (s["load"] or "NO LOAD LINE - the loader did not get to its end"))
        L.append("lines per part: " + ", ".join("%s %d" % (k, v) for k, v in sorted(s["modules"].items())))
        if s["ended_inside"]:
            L.append("ENDED INSIDE: " + s["ended_inside"])
            L.append("    (the log ends with a breadcrumb: the game most likely went down in this step)")
        else:
            L.append("ended inside: nothing (the last line is not a breadcrumb)")
        L.append("errors: %d" % len(s["errors"]))
        for e in s["errors"][:10]:
            L.append("    %s [%s] %s" % (e["time"], e["module"], e["text"][:220]))
        L.append("searches by path: %d first-time (%d found), %d breadcrumb(s) in all" % (s["lookups"]["first_time"], s["lookups"]["found"], s["crumbs"]))
        if s["not_found"]:
            L.append("not found (%d):" % len(s["not_found"]))
            for x in s["not_found"][:20]:
                L.append("    " + x)
        if s["repeated"]:
            L.append("REPEATED SEARCHES (%d) - each one walks every object of the game:" % len(s["repeated"]))
            for x in s["repeated"][:20]:
                L.append("    " + x)
        if s["raised"]:
            L.append("searches that raised (%d): %s" % (len(s["raised"]), "; ".join(s["raised"][:5])))
        if s["slow"]:
            L.append("slow callbacks noted: %d" % s["slow"])
        for x in s["ignored_calls"]:
            L.append("wrong diagnostics call: " + x)
        if s["unparsed"]:
            L.append("lines not in the usual form: %d" % s["unparsed"])
    o = a.get("ops")
    if o:
        L.append("")
        L.append("== operations %s ==" % o["file"])
        if not o["records"]:
            L.append("no operation was announced in this session")
        else:
            L.append("%d record(s), numbers %d .. %d (a ring of the last %d)" % (o["records"], o["first"], o["last"], 256))
            if o["ended_inside"]:
                L.append("ENDED INSIDE: " + o["ended_inside"])
                L.append("    (the newest operation was begun and never finished: the game most likely went down in it -")
                L.append("     unless the game is still running and is in it right now)")
            else:
                L.append("ended inside: nothing (the newest operation was finished)")
            if o["open_earlier"]:
                L.append("begun and never finished earlier (%d) - each raised an error before it could be taken back:" % len(o["open_earlier"]))
                for x in o["open_earlier"][-10:]:
                    L.append("    " + x)
            L.append("the last operations:")
            L.extend("  " + x for x in o["tail"])
        if o["unreadable"]:
            L.append("records that cannot be read: %d" % o["unreadable"])
    r = a["report"]
    if r:
        L.append("")
        L.append("== report %s ==" % r["file"])
        L.append(r["title"])
        for k in ("time", "minutes since load", "level", "session log", "file output", "lines not written", "internal problems of the diagnostics"):
            if k in r["header"]:
                L.append("%s: %s" % (k, r["header"][k]))
        for name in ("modules", "status", "counters"):
            L.append("-- %s --" % name)
            L.extend("    " + x for x in r["parts"].get(name, [])[:60])
        L.append("-- errors --")
        L.append("    count: %s" % r["error_count"])
        L.extend("    " + x for x in r["error_heads"][:10])
    if a["notes"]:
        L.append("")
        L.append("== notes (what the modules saw) ==")
        for n in a["notes"]:
            L.append("[%s] %s = %s  (first seen %s%s)" % (n["module"], n["key"], n["shown"], n["at"],
                                                         (", changed %d time(s), first value: %s" % (n["changes"], n["first"])) if n.get("changes") else ""))
    if a["facts"] is not None:
        L.append("")
        L.append("== facts (dev/FACTS.md against the notes) ==")
        width = max([len(x["key"]) for x in a["facts"]] + [10])
        for x in a["facts"]:
            L.append("%-15s %-*s %s" % (x["verdict"], width, x["key"], x["shown"] if x["shown"] is not None else ""))
            if x["verdict"] in ("DIFFERS", "fallback in use"):
                L.append("%-15s %-*s expected: %s" % ("", width, "", x["expected"]))
        counts = {}
        for x in a["facts"]:
            counts[x["verdict"]] = counts.get(x["verdict"], 0) + 1
        L.append("summary: " + ", ".join("%d %s" % (v, k) for k, v in sorted(counts.items())))
    d = a["dump"]
    if d:
        L.append("")
        L.append("== dump %s ==" % d["file"])
        if d["problem"]:
            L.append("PROBLEM: " + d["problem"])
        else:
            m = d["meta"]
            L.append("%s v%s, %s, %s minutes after load" % (m["mod"], m["version"], m["time"], m["minutes"]))
            for name, state in sorted(m["modules"].items()):
                L.append("    %s: %s" % (name, state))
            if m["refused_count"]:
                L.append("    refused values: %s (%s)" % (m["refused_count"], "; ".join(str(x) for x in m["refused"][:5])))
            for name, keys in sorted(d["modules"].items()):
                L.append("[%s] %s" % (name, ", ".join("%s: %s" % (k, v) for k, v in sorted(keys.items()))))
    if s:
        L.append("")
        L.append("== end of the session log ==")
        L.extend(s["tail"])
    return "\n".join(L)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Summary of the mod's diagnostics files.")
    ap.add_argument("path", help="the diagnostics folder, or one session log, report or dump")
    ap.add_argument("--facts", metavar="FACTS.md", help="compare the notes with this facts file")
    ap.add_argument("--no-facts", action="store_true", help="do not use dev/FACTS.md")
    ap.add_argument("--lines", type=int, default=25, help="lines shown from the end of the session log (default 25)")
    ap.add_argument("--session", metavar="WHICH", help="with a folder: 2 = the session before the newest, 3 = the one before that, ...; "
                                                       "or (part of) a session's name")
    ap.add_argument("--fixture", metavar="OUT.lua", help="write the dump as a fixture file for the harnesses")
    ap.add_argument("--json", action="store_true", help="print the result as JSON")
    args = ap.parse_args(argv)
    if not os.path.exists(args.path):
        print("not found: %s" % args.path, file=sys.stderr)
        return 2
    facts = args.facts
    if facts is None and not args.no_facts:
        default = os.path.join(os.path.dirname(HERE), "FACTS.md")
        if os.path.isfile(default):
            facts = default
    a = read_all(args.path, facts, args.lines, args.session)
    if args.fixture:
        source = args.path
        if os.path.isdir(source):
            name = newest(os.listdir(source), DUMP_NAME)
            source = os.path.join(source, name) if name else None
        if not source or not source.endswith(".lua"):
            print("no dump file to make a fixture from (write one in the game with the console command: g1r dump)", file=sys.stderr)
            return 2
        try:
            write_fixture(source, args.fixture)
        except DumpError as e:
            print("not a dump of this mod: %s" % e, file=sys.stderr)
            return 2
        print("fixture written: %s" % args.fixture)
        return 0
    if args.json:
        print(json.dumps(a, indent=1, default=str))
    else:
        print(render(a))
    return 0


if __name__ == "__main__":
    sys.exit(main())
