#!/usr/bin/env python3
"""Static checks for the mod's Lua code and text files.

    python dev/tools/lint.py                 check the mod this file is in
    python dev/tools/lint.py --explain       what each rule is for
    python dev/tools/lint.py --lookups       every object search in the code, for review
    python dev/tools/lint.py --json          machine-readable result on stdout

Exit code 1 when there is an error, 0 otherwise (warnings do not fail).
Exceptions to the hazard rules are listed in dev/tools/lint_allow.txt, one per
line, so that every exception is a visible decision.

Python 3.8+, standard library only. Needs luac5.4 (or `--luac`) for the syntax
and global-variable rules; without it those rules are skipped and that is said.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(os.path.dirname(HERE))

# --------------------------------------------------------------------------- rules
RULES = [
    ("syntax", "error",
     "Every .lua file must pass `luac -p`.",
     "A file that does not compile takes its whole module down when the game starts; nothing can be tried in the "
     "game first."),
    ("global-write", "error",
     "Code under Scripts/ and modules/ must not assign a global variable.",
     "A module also runs as a stand-alone mod, where globals are shared with every other Lua mod of the game. "
     "Use `local`."),
    ("global-read", "error",
     "Code under Scripts/ and modules/ may only read globals that Lua or UE4SS provides (list in this file).",
     "An unknown global is almost always a misspelt name: it is nil at run time and the error only shows when "
     "that line runs in the game. Add real UE4SS functions to UE4SS_GLOBALS here."),
    ("logged-property", "error",
     "The property names m_Capacity, m_InventoryType, m_InteractiveObjectDefinition, m_ItemDefinition must not "
     "be used, except where lint_allow.txt allows it.",
     "The UE4SS fork this mod runs on writes a debug line to UE4SS.log for every Lua read of a property with "
     "one of these names (thousands of lines in minutes when read in a loop)."),
    ("direct-lookup", "warning",
     "StaticFindObject may only be used inside the cached helper functions named in lint_allow.txt.",
     "A search by path that the loader cannot answer from its cache walks every object in memory; one such walk "
     "crashed the game. Results, found or not, must be kept for the run - which only the helpers and their "
     "callers do."),
    ("lookup-site", "warning",
     "A call of a lookup helper (lines `helper` in lint_allow.txt) outside the functions listed there.",
     "Each place that searches by path must keep the answer, found or not. A new place is listed in "
     "lint_allow.txt once that has been checked (and tested: the harness counts searches)."),
    ("hook-in-function", "warning",
     "RegisterHook inside a function or callback (anything but the main chunk).",
     "RegisterHook searches for its function by path like StaticFindObject. Registering from a callback can "
     "repeat; retrying a hook on a function that does not exist is what crashed the game."),
    ("file-write", "warning",
     "io.open for writing, os.remove and os.rename outside the functions listed in lint_allow.txt.",
     "The mod writes only below Scripts/diagnostics/ and modules/repopulate/Scripts/state/. Never save files, "
     "never another mod's files."),
    ("diag-handle", "warning",
     "In modules/, G1R_DIAG may only appear as `local DIAG = G1R_DIAG`.",
     "The handle is nil when the module runs without the loader; every use goes through the local, behind "
     "`if DIAG then`."),
    ("non-ascii", "error",
     "Text files of the mod are plain ASCII.",
     "The game's Lua, the settings app and Windows editors disagree about encodings; ASCII is the same in all."),
    ("personal-path", "error",
     "No path below a user's home folder, and none of the --forbid words.",
     "The mod is meant to be published. Paths of the machine it was built on, user names and the like do not "
     "belong in it."),
    ("drive-path", "warning",
     "A Windows path with a drive letter (allowed on a line that says lint:allow-path).",
     "Usually a left-over of the machine the code was written on. Test data with invented paths marks the line."),
    ("line-endings", "warning",
     "A file mixes CRLF and LF line endings.",
     "Mixed endings come from editing a file with two tools; hash comparisons and diffs then mislead."),
]
RULE_SEVERITY = {r[0]: r[1] for r in RULES}

LUA_GLOBALS = set("""_G _VERSION assert collectgarbage dofile error getmetatable ipairs load loadfile next pairs
pcall print rawequal rawget rawlen rawset require select setmetatable tonumber tostring type warn xpcall
coroutine debug io math os package string table utf8""".split())

# What UE4SS (Lua API of v3) puts into the globals. Extend when a new function is really used.
UE4SS_GLOBALS = set("""StaticFindObject FindFirstOf FindAllOf FindObject FindObjects StaticConstructObject
ForEachUObject FName FText RegisterHook UnregisterHook NotifyOnNewObject LoopAsync LoopInGameThreadWithDelay
ExecuteAsync ExecuteWithDelay ExecuteInGameThread RegisterLoadMapPreHook RegisterLoadMapPostHook
RegisterInitGameStatePreHook RegisterInitGameStatePostHook RegisterBeginPlayPreHook RegisterBeginPlayPostHook
RegisterEndPlayPreHook RegisterEndPlayPostHook ExecuteInGameThreadWithDelay ExecuteInGameThreadAfterFrames
LoopInGameThreadAfterFrames RetriggerableExecuteInGameThreadWithDelay CancelDelayedAction IsInGameThread
RegisterConsoleCommandHandler RegisterConsoleCommandGlobalHandler RegisterProcessConsoleExecPreHook
RegisterProcessConsoleExecPostHook RegisterKeyBind IsKeyBindRegistered RegisterCustomEvent UnregisterCustomEvent
RegisterCustomProperty LoadAsset IterateGameDirectories CreateInvalidObject Key ModifierKey EObjectFlags
EInternalObjectFlags PropertyTypes UnrealVersion ModRef""".split())

MOD_GLOBALS = {"G1R_DIAG", "G1R_KIT", "G1R_SETTINGS", "G1R_MODS"}       # what the loader puts into a module's environment

LOGGED_PROPERTIES = ("m_Capacity", "m_InventoryType", "m_InteractiveObjectDefinition", "m_ItemDefinition")
REGISTRARS = {"LoopInGameThreadWithDelay", "LoopAsync", "NotifyOnNewObject", "RegisterHook", "ExecuteWithDelay",
              "ExecuteInGameThread", "ExecuteAsync", "RegisterLoadMapPreHook", "RegisterLoadMapPostHook",
              "RegisterConsoleCommandHandler", "RegisterConsoleCommandGlobalHandler", "RegisterKeyBind",
              "RegisterCustomEvent"}
TRANSPARENT = {"pcall", "xpcall"}
TEXT_SUFFIXES = (".lua", ".txt", ".md", ".py", ".json", ".sh", ".ini", ".cfg", ".csv", ".tsv")
SKIP_DIRS = {"__pycache__", ".git"}

HOME_PATTERNS = [
    re.compile(r"[A-Za-z]:[\\/]+Users[\\/]+[^\\/\s\"'<>|*?]+", re.I),
    re.compile(r"/home/[a-z_][\w.-]*"),
    re.compile(r"/Users/[A-Za-z_][\w.-]*"),
]
DRIVE_PATTERN = re.compile(r"(?<![A-Za-z0-9_\\])[A-Za-z]:\\{1,2}[A-Za-z_]")


# --------------------------------------------------------------------------- Lua tokens
KEYWORDS = set("""and break do else elseif end false for function goto if in local nil not or repeat return then
true until while""".split())


class Tok(object):
    __slots__ = ("kind", "text", "line")

    def __init__(self, kind, text, line):
        self.kind, self.text, self.line = kind, text, line

    def __repr__(self):
        return "%s(%r@%d)" % (self.kind, self.text, self.line)


def _long_bracket(src, i):
    """If src[i:] opens a long bracket ([[ or [=[ ...), return the number of '='; else -1."""
    if i >= len(src) or src[i] != "[":
        return -1
    j = i + 1
    while j < len(src) and src[j] == "=":
        j += 1
    if j < len(src) and src[j] == "[":
        return j - i - 1
    return -1


def tokenize(src):
    """Lua source -> list of Tok. Comments are dropped; kinds: name, kw, str, num, op."""
    toks = []
    i, n, line = 0, len(src), 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
        elif c in " \t\r":
            i += 1
        elif c == "-" and src.startswith("--", i):
            level = _long_bracket(src, i + 2)
            if level >= 0:
                close = "]" + "=" * level + "]"
                j = src.find(close, i + 4 + level)
                j = n if j < 0 else j + len(close)
                line += src.count("\n", i, j)
                i = j
            else:
                j = src.find("\n", i)
                i = n if j < 0 else j
        elif c == "[" and _long_bracket(src, i) >= 0:
            level = _long_bracket(src, i)
            close = "]" + "=" * level + "]"
            start = i + 2 + level
            j = src.find(close, start)
            end = n if j < 0 else j
            toks.append(Tok("str", src[start:end], line))
            line += src.count("\n", i, end)
            i = n if j < 0 else j + len(close)
        elif c in "\"'":
            j = i + 1
            buf = []
            start_line = line
            while j < n and src[j] != c:
                if src[j] == "\\" and j + 1 < n:
                    if src[j + 1] == "\n":
                        line += 1
                    buf.append(src[j:j + 2])
                    j += 2
                else:
                    if src[j] == "\n":      # unfinished string; luac reports it
                        break
                    buf.append(src[j])
                    j += 1
            toks.append(Tok("str", "".join(buf), start_line))
            i = j + 1
        elif c.isalpha() or c == "_":
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            word = src[i:j]
            toks.append(Tok("kw" if word in KEYWORDS else "name", word, line))
            i = j
        elif c.isdigit() or (c == "." and i + 1 < n and src[i + 1].isdigit()):
            m = re.compile(r"0[xX][0-9a-fA-F.]*(?:[pP][+-]?\d+)?|\d*\.?\d*(?:[eE][+-]?\d+)?").match(src, i)
            j = m.end() if m and m.end() > i else i + 1
            toks.append(Tok("num", src[i:j], line))
            i = j
        else:
            for op in ("...", "..", "==", "~=", "<=", ">=", "//", "::", "<<", ">>"):
                if src.startswith(op, i):
                    toks.append(Tok("op", op, line))
                    i += len(op)
                    break
            else:
                toks.append(Tok("op", c, line))
                i += 1
    return toks


class Scope(object):
    """One open block while walking the tokens."""
    __slots__ = ("kind", "name", "callee", "loop")

    def __init__(self, kind, name=None, callee=None, loop=False):
        self.kind, self.name, self.callee, self.loop = kind, name, callee, loop


def _dotted_name_before(toks, i):
    """The dotted name that ends at token i (a.b.c or a.b:c), or None."""
    if i < 0 or toks[i].kind != "name":
        return None
    parts = [toks[i].text]
    j = i - 1
    while j >= 1 and toks[j].kind == "op" and toks[j].text in (".", ":") and toks[j - 1].kind == "name":
        parts.insert(0, toks[j].text)
        parts.insert(0, toks[j - 1].text)
        j -= 2
    return "".join(parts)


def walk(toks):
    """Yields (index, token, scopes) for every token, with the stack of open blocks at that point.

    Functions carry their name (as written), or for an anonymous one the function it is an argument of.
    """
    stack = []
    parens = []            # for each open '(': the name called, or None
    pending_loop = False   # a for / while whose `do` has not come yet
    i, n = 0, len(toks)
    while i < n:
        t = toks[i]
        yield i, t, stack
        if t.kind == "op":
            if t.text == "(":
                parens.append(_dotted_name_before(toks, i - 1))
            elif t.text == ")":
                if parens:
                    parens.pop()
        elif t.kind == "kw":
            w = t.text
            if w == "function":
                name, callee = None, None
                j = i + 1
                if j < n and toks[j].kind == "name":
                    parts = [toks[j].text]
                    j += 1
                    while j + 1 < n and toks[j].kind == "op" and toks[j].text in (".", ":") and toks[j + 1].kind == "name":
                        parts.append(toks[j].text)
                        parts.append(toks[j + 1].text)
                        j += 2
                    name = "".join(parts)
                else:
                    # `name = function`, `local name = function`, or an argument of a call
                    if i >= 2 and toks[i - 1].kind == "op" and toks[i - 1].text == "=":
                        name = _dotted_name_before(toks, i - 2)
                    if name is None and parens:
                        callee = parens[-1]
                stack.append(Scope("function", name, callee))
            elif w in ("for", "while"):
                pending_loop = True
            elif w == "do":
                stack.append(Scope("do", loop=pending_loop))
                pending_loop = False
            elif w == "if":
                stack.append(Scope("if"))
            elif w == "repeat":
                stack.append(Scope("repeat", loop=True))
            elif w in ("end", "until"):
                if stack:
                    stack.pop()
        i += 1


def context_of(scopes):
    """(function label, kind, in a loop) for a token inside these scopes.

    label: innermost named function, else "main chunk".
    kind:  "main" when the code runs once while the file loads (pcall wrappers are looked through),
           "callback" when it is inside a function handed to a registrar, "function" otherwise.
    """
    label, kind, in_loop = "main chunk", None, False
    for s in reversed(scopes):
        if s.kind != "function":
            if s.loop and kind is None:
                in_loop = True
            continue
        if s.name:
            if kind is None:
                kind = "function"
            label = s.name
            break
        if s.callee in TRANSPARENT:
            continue
        if kind is None:
            kind = "callback" if (s.callee or "").split(".")[-1] in REGISTRARS else "function"
    return label, (kind or "main"), in_loop


# --------------------------------------------------------------------------- allow file
class Allow(object):
    def __init__(self, path):
        self.entries = []      # (rule, path prefix, function or name)
        self.helpers = []      # (path prefix, name)
        self.used = set()
        self.path = path
        self.problems = []
        if not os.path.isfile(path):
            return
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for number, raw in enumerate(f, 1):
                line = raw.split("#", 1)[0].strip()
                if not line:
                    continue
                parts = line.split()
                if len(parts) < 3:
                    self.problems.append("%s:%d: expected `rule path name`" % (os.path.basename(path), number))
                    continue
                rule, where = parts[0], parts[1].replace("\\", "/")
                if rule == "helper":
                    for name in parts[2:]:
                        self.helpers.append((where, name))
                elif rule in RULE_SEVERITY:
                    self.entries.append((rule, where, parts[2]))
                else:
                    self.problems.append("%s:%d: unknown rule '%s'" % (os.path.basename(path), number, rule))

    def allows(self, rule, rel, name):
        for entry in self.entries:
            if entry[0] == rule and rel.startswith(entry[1]) and entry[2] in ("*", name):
                self.used.add(entry)
                return True
        return False

    def helpers_for(self, rel):
        return {name for where, name in self.helpers if rel.startswith(where)}

    def unused(self):
        return [e for e in self.entries if e not in self.used]


# --------------------------------------------------------------------------- checks
class Result(object):
    def __init__(self):
        self.findings = []
        self.notes = []
        self.lookups = []
        self.files = 0
        self.lua_files = 0

    def add(self, rule, rel, line, text):
        self.findings.append({"rule": rule, "severity": RULE_SEVERITY[rule], "file": rel, "line": line, "text": text})

    def count(self, severity):
        return sum(1 for f in self.findings if f["severity"] == severity)


def list_files(root):
    out = []
    for base, dirs, files in os.walk(root):
        rel_base = os.path.relpath(base, root).replace("\\", "/")
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not (rel_base == "dev" and d == "out"))
        for name in sorted(files):
            rel = name if rel_base == "." else rel_base + "/" + name
            out.append(rel)
    return out


def is_runtime(rel):
    return rel.startswith("Scripts/") or rel.startswith("modules/")


def find_tool(given, names):
    if given:
        return given if (os.path.isfile(given) or shutil.which(given)) else None
    for name in names:
        if shutil.which(name):
            return name
    return None


def check_bytecode(root, rel, luac, result):
    """Syntax, and the globals a runtime file reads and writes (from the compiler's listing)."""
    path = os.path.join(root, rel)
    try:
        p = subprocess.run([luac, "-l", "-p", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        result.add("syntax", rel, 0, "could not run %s: %s" % (luac, e))
        return
    if p.returncode != 0:
        message = p.stderr.decode("utf-8", "replace").strip().replace(path, rel)
        m = re.search(r":(\d+):", message)
        result.add("syntax", rel, int(m.group(1)) if m else 0, message)
        return
    if not is_runtime(rel):
        return
    known = LUA_GLOBALS | UE4SS_GLOBALS | MOD_GLOBALS
    seen = set()
    for raw in p.stdout.decode("utf-8", "replace").splitlines():
        m = re.match(r"\s*\d+\s+\[(\d+)\]\s+(GETTABUP|SETTABUP)\s.*;\s+_ENV \"([^\"]+)\"", raw)
        if not m:
            continue
        line, op, name = int(m.group(1)), m.group(2), m.group(3)
        if (op, name, line) in seen:
            continue
        seen.add((op, name, line))
        if op == "SETTABUP":
            result.add("global-write", rel, line, "assigns the global '%s'" % name)
        elif name not in known:
            result.add("global-read", rel, line, "reads the unknown global '%s'" % name)


def check_lua_tokens(rel, src, allow, result):
    try:
        toks = tokenize(src)
    except Exception as e:      # the tokenizer must never take the lint down
        result.notes.append("%s: could not be read as Lua tokens (%s); hazard rules skipped" % (rel, e))
        return
    lines = src.splitlines()
    helpers = allow.helpers_for(rel)
    in_modules = rel.startswith("modules/")
    for i, t, scopes in walk(toks):
        prev = toks[i - 1] if i > 0 else None
        nxt = toks[i + 1] if i + 1 < len(toks) else None
        is_field = prev is not None and prev.kind == "op" and prev.text in (".", ":")
        if t.kind == "str":
            for name in LOGGED_PROPERTIES:
                if name in t.text and not allow.allows("logged-property", rel, name):
                    result.add("logged-property", rel, t.line, "uses the property name %s (in a text)" % name)
            continue
        if t.kind != "name":
            continue
        label, kind, in_loop = context_of(scopes)
        if t.text in LOGGED_PROPERTIES:
            if not allow.allows("logged-property", rel, t.text):
                result.add("logged-property", rel, t.line, "uses the property name %s" % t.text)
        elif t.text == "StaticFindObject" and not is_field:
            source = lines[t.line - 1].strip() if t.line <= len(lines) else ""
            result.lookups.append({"file": rel, "line": t.line, "function": label, "what": "StaticFindObject", "source": source})
            if not allow.allows("direct-lookup", rel, label):
                result.add("direct-lookup", rel, t.line, "StaticFindObject used in %s%s; use the cached helper"
                           % (label, " (inside a loop)" if in_loop else ""))
        elif t.text == "RegisterHook" and not is_field:
            if kind != "main" and not allow.allows("hook-in-function", rel, label):
                result.add("hook-in-function", rel, t.line, "RegisterHook inside %s %s%s"
                           % ("a callback in" if kind == "callback" else "the function", label,
                              " (inside a loop)" if in_loop else ""))
        elif t.text in ("FindAllOf", "FindFirstOf") and not is_field:
            source = lines[t.line - 1].strip() if t.line <= len(lines) else ""
            result.lookups.append({"file": rel, "line": t.line, "function": label, "what": t.text, "source": source})
        elif t.text == "G1R_DIAG" and in_modules and not is_field:
            ok = (i >= 3 and toks[i - 1].text == "=" and toks[i - 2].text == "DIAG" and toks[i - 3].text == "local")
            if not ok:
                result.add("diag-handle", rel, t.line, "G1R_DIAG used directly; use `local DIAG = G1R_DIAG` and `if DIAG then`")
        # lookup helpers: a call of one (not its definition)
        if helpers and nxt is not None and nxt.kind == "op" and nxt.text == "(":
            full = _dotted_name_before(toks, i)
            first = i - 2 * (len(re.split(r"[.:]", full)) - 1) if full else i
            is_definition = first >= 1 and toks[first - 1].kind == "kw" and toks[first - 1].text == "function"
            if full in helpers and not is_definition:
                source = lines[t.line - 1].strip() if t.line <= len(lines) else ""
                result.lookups.append({"file": rel, "line": t.line, "function": label, "what": full, "source": source})
                if label not in helpers and not allow.allows("lookup-site", rel, label):
                    result.add("lookup-site", rel, t.line, "%s called in %s%s, which lint_allow.txt does not list"
                               % (full, label, " (inside a loop)" if in_loop else ""))
        # file writes
        if t.text in ("io", "os") and not is_field and nxt is not None and nxt.text == "." and i + 2 < len(toks):
            member = toks[i + 2].text
            call = i + 3 < len(toks) and toks[i + 3].text == "("
            writes = None
            if t.text == "io" and member == "open":
                if not call:
                    writes = "io.open kept under another name"
                else:
                    # the mode is the second argument when it is a text
                    depth, j, mode, commas = 0, i + 4, None, 0
                    while j < len(toks):
                        tj = toks[j]
                        if tj.kind == "op" and tj.text in "([{":
                            depth += 1
                        elif tj.kind == "op" and tj.text in ")]}":
                            if depth == 0:
                                break
                            depth -= 1
                        elif tj.kind == "op" and tj.text == "," and depth == 0:
                            commas += 1
                            if commas == 1 and j + 1 < len(toks):
                                after = toks[j + 1]
                                closing = toks[j + 2] if j + 2 < len(toks) else None
                                if after.kind == "str" and closing is not None and closing.text == ")":
                                    mode = after.text
                                else:
                                    mode = "?"
                        j += 1
                    if mode is None:
                        mode = "r"
                    if mode == "?":
                        writes = "io.open with a mode that is not a plain text"
                    elif any(ch in mode for ch in "wa+"):
                        writes = "io.open(..., \"%s\")" % mode
            elif t.text == "os" and member in ("remove", "rename"):
                writes = "os.%s" % member
            if writes and not allow.allows("file-write", rel, label):
                result.add("file-write", rel, t.line, "%s in %s" % (writes, label))


def check_text(root, rel, forbid, result):
    path = os.path.join(root, rel)
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        result.notes.append("%s: cannot be read (%s)" % (rel, e))
        return None
    crlf = data.count(b"\r\n")
    lf = data.count(b"\n") - crlf
    if crlf and lf:
        result.add("line-endings", rel, 0, "%d lines end with CRLF, %d with LF" % (crlf, lf))
    text = data.decode("latin-1")
    reported_ascii = 0
    for number, line in enumerate(text.split("\n"), 1):
        if reported_ascii < 3:
            m = re.search(r"[^\x09\x0a\x0d\x20-\x7e]", line)
            if m:
                reported_ascii += 1
                result.add("non-ascii", rel, number, "byte 0x%02x at column %d" % (ord(m.group(0)), m.start() + 1))
        for pattern in HOME_PATTERNS:
            m = pattern.search(line)
            if m:
                result.add("personal-path", rel, number, "path below a home folder: %s" % m.group(0))
                break
        low = line.lower()
        for word in forbid:
            if word.lower() in low:
                result.add("personal-path", rel, number, "forbidden word '%s'" % word)
        if "lint:allow-path" not in line and DRIVE_PATTERN.search(line) and not any(p.search(line) for p in HOME_PATTERNS):
            result.add("drive-path", rel, number, "Windows path with a drive letter: %s" % line.strip()[:80])
    return text


def run(root, luac=None, forbid=(), allow_path=None):
    result = Result()
    allow = Allow(allow_path or os.path.join(root, "dev", "tools", "lint_allow.txt"))
    for problem in allow.problems:
        result.notes.append(problem)
    luac = find_tool(luac, ("luac5.4", "luac54", "luac"))
    if luac is None:
        result.notes.append("luac5.4 not found: the rules syntax, global-write and global-read were skipped")
    for rel in list_files(root):
        if not rel.lower().endswith(TEXT_SUFFIXES):
            continue
        result.files += 1
        text = check_text(root, rel, forbid, result)
        if rel.endswith(".lua"):
            result.lua_files += 1
            if luac is not None:
                check_bytecode(root, rel, luac, result)
            if text is not None and is_runtime(rel):
                check_lua_tokens(rel, text, allow, result)
    for rule, where, name in allow.unused():
        result.notes.append("lint_allow.txt: the entry `%s %s %s` matched nothing (remove it, or the code moved)" % (rule, where, name))
    order = {"error": 0, "warning": 1}
    result.findings.sort(key=lambda f: (order[f["severity"]], f["file"], f["line"], f["rule"]))
    return result


def explain():
    out = []
    for rule, severity, what, why in RULES:
        out.append("%s  (%s)" % (rule, severity))
        out.append("    " + what)
        out.append("    Why: " + why)
        out.append("")
    out.append("Exceptions: dev/tools/lint_allow.txt, lines `rule path function` (path = start of the file's path")
    out.append("inside the mod, function = the named function the code is in, `main chunk`, or * ). Lines")
    out.append("`helper path name...` name the functions that wrap StaticFindObject for the files below that path.")
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Static checks for the mod (see --explain).")
    ap.add_argument("--root", default=DEFAULT_ROOT, help="the mod folder (default: the one this tool is in)")
    ap.add_argument("--luac", help="Lua 5.4 compiler (default: luac5.4 on the PATH)")
    ap.add_argument("--forbid", action="append", default=[], metavar="WORD", help="a word that must not appear (repeatable)")
    ap.add_argument("--forbid-file", metavar="FILE", help="file with one forbidden word per line (kept outside the mod)")
    ap.add_argument("--allow", metavar="FILE", help="exceptions file (default: dev/tools/lint_allow.txt)")
    ap.add_argument("--json", action="store_true", help="print the result as JSON")
    ap.add_argument("--explain", action="store_true", help="print what each rule is for and stop")
    ap.add_argument("--lookups", action="store_true", help="list every object search in the code")
    ap.add_argument("--quiet", action="store_true", help="print only the summary line")
    args = ap.parse_args(argv)
    if args.explain:
        print(explain())
        return 0
    forbid = list(args.forbid)
    if args.forbid_file:
        with open(args.forbid_file, "r", encoding="utf-8", errors="replace") as f:
            forbid += [l.strip() for l in f if l.strip() and not l.startswith("#")]
    root = os.path.abspath(args.root)
    result = run(root, args.luac, forbid, args.allow)
    errors, warnings = result.count("error"), result.count("warning")
    if args.json:
        print(json.dumps({"files": result.files, "lua_files": result.lua_files, "errors": errors, "warnings": warnings,
                          "findings": result.findings, "notes": result.notes, "lookups": result.lookups}, indent=1))
    else:
        if args.lookups:
            for l in result.lookups:
                print("lookup  %s:%d  %-18s in %-22s %s" % (l["file"], l["line"], l["what"], l["function"], l["source"][:110]))
        if not args.quiet:
            for f in result.findings:
                print("%-7s %s:%d  [%s] %s" % (f["severity"], f["file"], f["line"], f["rule"], f["text"]))
            for note in result.notes:
                print("note    %s" % note)
        print("lint finished: %d file(s), %d Lua, %d error(s), %d warning(s)" % (result.files, result.lua_files, errors, warnings))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
