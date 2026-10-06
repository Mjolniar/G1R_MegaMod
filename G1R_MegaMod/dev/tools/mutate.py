#!/usr/bin/env python3
"""Mutation check: does the test suite notice when the code is broken on purpose?

    python dev/tools/mutate.py modules/xp/Scripts/main.lua --suite xp
    python dev/tools/mutate.py Scripts/core/kit.lua --suite core/test_kit --lines 180-330
    python dev/tools/mutate.py modules/xp/Scripts/main.lua --suite xp --list my_mutations.txt
    python dev/tools/mutate.py modules/xp/Scripts/main.lua --suite xp --show 14   (print mutation 14 as a diff)
    python dev/tools/mutate.py modules/repopulate/Scripts/util.lua --suite repopulate_engine,repopulate,files
                                    (several suites: a change is noticed when one of them notices)
    python dev/tools/mutate.py modules/xp/Scripts/main.lua --suite xp --only 14,20-25   (these mutations only)

The mod is copied to a temporary folder; one small change at a time is made to the
given file in that copy (a comparison turned round, `and` for `or`, a number moved
by one, `true` for `false`, a `not` removed, a line that ends a function early
taken out), and the suite is run from the copy. A change the suite does not notice
is listed as SURVIVED: either a check is missing, or the change makes no
difference to what the code does (then say why with --accept, see below).
The working tree is never touched, so several of these can run side by side.

Mutations come from the source automatically. Comment lines, log texts and lines
with the words in SKIP_WORDS are left alone. A file given with --list adds your
own: blocks separated by a line `----`, each `old text` / `====` / `new text`
(the old text must occur exactly once in the file).

--accept FILE: lines `<operator>|<the original line, without its indentation>|<reason>`
for survivors that were looked at and found harmless (the operator is the third
column of a SURVIVED line; for your own mutations `listed`, with the first line of
the old text); they are reported as accepted. An accept line that matches no
survivor is reported.

Exit code 0 when no unexplained survivor is left. Needs lua5.4 and luac5.4.
"""
import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
DEV = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(DEV)
RESULT_LINE = re.compile(r"finished: (\d+) ok, (\d+) failure")

# Lines with these words are not mutated automatically (diagnostics, logging, test hooks).
SKIP_WORDS = ("DIAG.", "log(", "L.once(", "L.log(", "print(", "_TEST", ":format(", "Log.once(", "error(")

OPERATORS = [
    # (name, pattern, replacement)
    ("lt->le", re.compile(r"(?<![<>=~])<(?![<=])"), "<="),
    ("le->lt", re.compile(r"<="), "<"),
    ("gt->ge", re.compile(r"(?<![<>=~\-])>(?![>=])"), ">="),
    ("ge->gt", re.compile(r">="), ">"),
    ("eq->ne", re.compile(r"=="), "~="),
    ("ne->eq", re.compile(r"~="), "=="),
    ("and->or", re.compile(r"\band\b"), "or"),
    ("or->and", re.compile(r"\bor\b"), "and"),
    ("true->false", re.compile(r"\btrue\b"), "false"),
    ("false->true", re.compile(r"\bfalse\b"), "true"),
    ("not->", re.compile(r"\bnot\s+"), ""),
    ("plus->minus", re.compile(r"(?<=[\w\)\]]) \+ (?=[\w\(])"), " - "),
    ("minus->plus", re.compile(r"(?<=[\w\)\]]) - (?=[\w\(])"), " + "),
    ("num+1", re.compile(r"(?<![\w.\"'%])(\d+)(?![\w.\"'])"), None),
]


def strip_strings_and_comment(line):
    """The code part of a line with string contents blanked (same length), comment removed."""
    out = []
    i, n = 0, len(line)
    quote = None
    while i < n:
        ch = line[i]
        if quote:
            if ch == "\\" and i + 1 < n:
                out.append("  ")
                i += 2
                continue
            if ch == quote:
                quote = None
                out.append(ch)
            else:
                out.append(" ")
        else:
            if ch in "\"'":
                quote = ch
                out.append(ch)
            elif ch == "-" and line[i:i + 2] == "--":
                break
            else:
                out.append(ch)
        i += 1
    return "".join(out)


def auto_mutations(lines, first, last):
    found = []
    in_long_comment = False
    for number, line in enumerate(lines, 1):
        if "--[[" in line or "--[=[" in line:
            in_long_comment = True
        if in_long_comment:
            if "]]" in line or "]=]" in line:
                in_long_comment = False
            continue
        if number < first or number > last:
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith("--"):
            continue
        if any(word in line for word in SKIP_WORDS):
            continue
        code = strip_strings_and_comment(line.rstrip("\n"))
        for name, pattern, replacement in OPERATORS:
            for m in pattern.finditer(code):
                if name == "num+1":
                    new = line[:m.start()] + str(int(m.group(1)) + 1) + line[m.end():]
                else:
                    new = line[:m.start()] + replacement + line[m.end():]
                found.append({"line": number, "op": name, "old": line, "new": new, "column": m.start()})
        # a line that only leaves the function early
        if re.match(r"^\s*(if .* then )?return\b[^\n]*( end)?\s*$", line) and not re.match(r"^\s*return\s+\w+\s*$", line):
            found.append({"line": number, "op": "drop-return", "old": line, "new": re.match(r"^\s*", line).group(0) + "do end\n", "column": 0})
    return found


def listed_mutations(path, text):
    out = []
    with open(path, encoding="utf-8") as f:
        blocks = f.read().split("\n----\n")
    for index, block in enumerate(blocks, 1):
        if not block.strip():
            continue
        if "\n====\n" not in block:
            raise SystemExit("%s: block %d has no ==== line" % (path, index))
        old, new = block.split("\n====\n", 1)
        old, new = old.strip("\n"), new.strip("\n")
        if text.count(old) != 1:
            raise SystemExit("%s: block %d: the old text occurs %d times in the file (must be once)" % (path, index, text.count(old)))
        out.append({"line": text[:text.index(old)].count("\n") + 1, "op": "listed %d" % index, "whole_old": old, "whole_new": new})
    return out


def apply(text, lines, mutation):
    if "whole_old" in mutation:
        return text.replace(mutation["whole_old"], mutation["whole_new"])
    changed = list(lines)
    changed[mutation["line"] - 1] = mutation["new"]
    return "".join(changed)


def run_one(args):
    copy, relative, suite_path, mutated_text, lua, luac, timeout, tmp = args
    target = os.path.join(copy, relative)
    with open(target, encoding="utf-8", newline="") as f:
        original = f.read()
    try:
        with open(target, "w", encoding="utf-8", newline="") as f:
            f.write(mutated_text)
        if luac:
            p = subprocess.run([luac, "-p", target], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if p.returncode != 0:
                return "invalid", ""
        env = dict(os.environ)
        env["G1R_TEST_TMP"] = tmp
        command = [lua, suite_path] if suite_path.endswith(".lua") else [sys.executable, suite_path]
        try:
            p = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, timeout=timeout, cwd=os.path.dirname(suite_path))
        except subprocess.TimeoutExpired:
            return "killed", "timeout"
        output = p.stdout.decode("utf-8", "replace")
        lines = [l for l in output.splitlines() if l.strip()]
        m = RESULT_LINE.search(lines[-1]) if lines else None
        if m is None or p.returncode != 0 or int(m.group(2)) > 0:
            first_fail = next((l for l in lines if l.startswith("FAIL")), lines[-1] if lines else "no output")
            return "killed", first_fail[:160]
        return "survived", ""
    finally:
        with open(target, "w", encoding="utf-8", newline="") as f:
            f.write(original)


def suite_file(root, suite):
    base = os.path.join(root, "dev", "tests")
    if "/" in suite:
        folder, name = suite.split("/", 1)
        for ext in (".lua", ".py"):
            path = os.path.join(base, folder, name + ext)
            if os.path.isfile(path):
                return path
    else:
        folder = os.path.join(base, suite)
        if os.path.isfile(os.path.join(folder, "harness.lua")):
            return os.path.join(folder, "harness.lua")
        if os.path.isdir(folder):
            tests = sorted(f for f in os.listdir(folder) if re.match(r"^test_.*\.(lua|py)$", f))
            if len(tests) == 1:
                return os.path.join(folder, tests[0])
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description="Break the code on purpose and see whether a suite notices.")
    ap.add_argument("file", help="the file to mutate, relative to the mod folder")
    ap.add_argument("--suite", required=True, help="the suite that should notice (a name as run_tests.py lists it); several, separated by commas: "
                    "they are run in that order until one notices")
    ap.add_argument("--lines", metavar="A-B", help="only mutate these lines")
    ap.add_argument("--only", metavar="N[,N-M...]", help="only run the mutations with these numbers (as printed; the numbering stays that of the whole run)")
    ap.add_argument("--list", metavar="FILE", help="mutations of your own (see above); with --only-list no automatic ones")
    ap.add_argument("--only-list", action="store_true")
    ap.add_argument("--accept", metavar="FILE", help="survivors that were looked at (see above)")
    ap.add_argument("--show", type=int, metavar="N", help="print mutation N and stop")
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2)), help="suites run side by side (default: number of CPUs)")
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--lua", default=shutil.which("lua5.4") or shutil.which("lua54") or "lua")
    ap.add_argument("--luac", default=shutil.which("luac5.4") or shutil.which("luac54"))
    ap.add_argument("--quiet", action="store_true", help="only survivors and the summary")
    args = ap.parse_args(argv)

    relative = args.file.replace("\\", "/")
    source = os.path.join(ROOT, relative)
    if not os.path.isfile(source):
        print("no such file in the mod: %s" % relative)
        return 2
    suites = [name.strip() for name in args.suite.split(",") if name.strip()]
    for name in suites:
        if suite_file(ROOT, name) is None:
            print("no such suite: %s" % name)
            return 2
    if not suites:
        print("no suite given")
        return 2
    with open(source, encoding="utf-8", newline="") as f:
        text = f.read()
    lines = text.splitlines(keepends=True)
    first, last = 1, len(lines)
    if args.lines:
        a, b = args.lines.split("-")
        first, last = int(a), int(b)
    mutations = [] if args.only_list else auto_mutations(lines, first, last)
    if args.list:
        mutations += listed_mutations(args.list, text)
    for number, m in enumerate(mutations, 1):
        m["n"] = number
    if args.show:
        m = mutations[args.show - 1]
        if "whole_old" in m:
            print("line %d, %s\n- %s\n+ %s" % (m["line"], m["op"], m["whole_old"], m["whole_new"]))
        else:
            print("line %d, %s\n- %s+ %s" % (m["line"], m["op"], m["old"], m["new"]))
        return 0
    if not mutations:
        print("nothing to mutate")
        return 2
    chosen = None
    if args.only:
        chosen = set()
        try:
            for part in args.only.split(","):
                if "-" in part:
                    a, b = part.split("-", 1)
                    chosen.update(range(int(a), int(b) + 1))
                elif part.strip():
                    chosen.add(int(part))
        except ValueError:
            print("--only takes numbers and ranges: 14,20-25")
            return 2
        wrong = sorted(n for n in chosen if n < 1 or n > len(mutations))
        if wrong:
            print("--only: there is no mutation %s (the file has %d)" % (", ".join(str(n) for n in wrong), len(mutations)))
            return 2

    accepted = []
    if args.accept:
        with open(args.accept, encoding="utf-8") as f:
            for raw in f:
                raw = raw.rstrip("\n")
                if raw.strip() and not raw.startswith("#"):
                    if raw.count("|") < 2:
                        raise SystemExit("%s: not `operator|original line|reason`: %s" % (args.accept, raw))
                    op, rest = raw.split("|", 1)
                    old, reason = rest.rsplit("|", 1)
                    accepted.append({"op": op.strip(), "old": old.strip(), "reason": reason.strip(), "raw": raw, "used": False})

    def accepted_reason(m):
        old_line = (m.get("old") or m.get("whole_old") or "").strip().splitlines()[0].strip()
        op = "listed" if m["op"].startswith("listed") else m["op"]
        for a in accepted:
            if a["op"] == op and a["old"] == old_line:
                a["used"] = True
                return a["reason"]
        return None

    work = tempfile.mkdtemp(prefix="g1r-mutate-")
    try:
        jobs = max(1, min(args.jobs, len(mutations)))
        copies = []
        for j in range(jobs):
            copy = os.path.join(work, "copy%d" % j, os.path.basename(ROOT))
            shutil.copytree(ROOT, copy, ignore=shutil.ignore_patterns("out", "__pycache__"))
            copies.append(copy)
        # the unmutated copy must pass, or every "killed" would be meaningless
        for name in suites:
            base = run_one((copies[0], relative, suite_file(copies[0], name), text, args.lua, args.luac, args.timeout, os.path.join(work, "tmp0")))
            if base[0] != "survived":
                print("the suite %s does not pass on the unchanged file (%s): fix that first" % (name, base[1]))
                return 2

        results = [None] * len(mutations)
        todo = [i for i in range(len(mutations)) if chosen is None or (i + 1) in chosen]

        def worker(slot, indexes):
            copy = copies[slot]
            for i in indexes:
                m = mutations[i]
                mutated = apply(text, lines, m)
                # the suites in the order given, until one notices
                for name in suites:
                    results[i] = run_one((copy, relative, suite_file(copy, name), mutated, args.lua, args.luac, args.timeout,
                                          os.path.join(work, "tmp%d" % slot)))
                    if results[i][0] != "survived":
                        if len(suites) > 1 and results[i][0] == "killed":
                            results[i] = ("killed", ("[%s] " % name) + results[i][1])
                        break

        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            futures = [pool.submit(worker, slot, todo[slot::jobs]) for slot in range(jobs)]
            for f in futures:
                f.result()
    finally:
        shutil.rmtree(work, ignore_errors=True)

    killed = survived = invalid = explained = 0
    ran = [(m, r) for m, r in zip(mutations, results) if r is not None]
    for m, (state, detail) in ran:
        shown = (m.get("new") or m.get("whole_new", "")).strip().splitlines()[0][:110] if (m.get("new") or m.get("whole_new")) else ""
        if state == "killed":
            killed += 1
            if not args.quiet:
                print("killed    #%-4d line %-5d %-12s %s" % (m["n"], m["line"], m["op"], detail[:90]))
        elif state == "invalid":
            invalid += 1
        else:
            reason = accepted_reason(m)
            if reason:
                explained += 1
                print("accepted  #%-4d line %-5d %-12s %s   (%s)" % (m["n"], m["line"], m["op"], shown, reason))
            else:
                survived += 1
                print("SURVIVED  #%-4d line %-5d %-12s %s" % (m["n"], m["line"], m["op"], shown))
    for a in accepted:
        if not a["used"] and chosen is None:        # (with --only the other survivors were not run)
            print("note: the accept line `%s` matched no survivor" % a["raw"])
    print("%s: %d mutation(s): %d killed, %d survived, %d accepted, %d not valid Lua" % (relative, len(ran), killed, survived, explained, invalid))
    return 0 if survived == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
