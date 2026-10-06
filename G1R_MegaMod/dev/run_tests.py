#!/usr/bin/env python3
"""Runs every offline test of the mod and the lint. One command, one answer.

    python dev/run_tests.py                 everything
    python dev/run_tests.py --list          the suites that would run
    python dev/run_tests.py --only markers  one suite (repeatable; also: lint)
    python dev/run_tests.py --verbose       show the output of failing suites in full

A suite is a file below dev/tests/<name>/: harness.lua or test_*.lua (run with
Lua 5.4) or test_*.py (run with this Python). Its last line says
`... finished: N ok, M failure(s)`; it passes when M is 0 and its exit code is 0.
A summary goes to dev/out/test-summary.json. Exit code 0 only when every suite
and the lint pass.

Needs lua5.4 and luac5.4 (or --lua / --luac) and, for the Lua suites, a POSIX
shell with cp, mkdir, rm (Linux, macOS, WSL, Git Bash). No game, no UE4SS.
Python 3.8+, standard library only.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
DEV = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(DEV)
RESULT_LINE = re.compile(r"finished: (\d+) ok, (\d+) failure")


def find_tool(given, names):
    if given:
        return given if (os.path.isfile(given) or shutil.which(given)) else None
    for name in names:
        if shutil.which(name):
            return name
    return None


def discover():
    """[(name, kind, path)] for every suite, in a fixed order."""
    suites = []
    tests = os.path.join(DEV, "tests")
    if not os.path.isdir(tests):
        return suites
    for folder in sorted(os.listdir(tests)):
        base = os.path.join(tests, folder)
        if not os.path.isdir(base):
            continue
        files = sorted(os.listdir(base))
        found = [f for f in files if f == "harness.lua" or re.match(r"^test_.*\.(lua|py)$", f)]
        for f in found:
            name = folder if len(found) == 1 else "%s/%s" % (folder, os.path.splitext(f)[0])
            suites.append((name, "lua" if f.endswith(".lua") else "python", os.path.join(base, f)))
    return suites


def run_suite(kind, path, lua, env, timeout):
    command = [lua, path] if kind == "lua" else [sys.executable, path]
    started = time.time()
    try:
        p = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, timeout=timeout,
                           cwd=os.path.dirname(path))
        output, code, timed_out = p.stdout.decode("utf-8", "replace"), p.returncode, False
    except subprocess.TimeoutExpired as e:
        output, code, timed_out = (e.stdout or b"").decode("utf-8", "replace"), None, True
    except OSError as e:
        output, code, timed_out = "could not be started: %s" % e, None, False
    seconds = time.time() - started
    lines = [l for l in output.splitlines() if l.strip()]
    m = RESULT_LINE.search(lines[-1]) if lines else None
    ok_count, failed = (int(m.group(1)), int(m.group(2))) if m else (None, None)
    passed = (m is not None and failed == 0 and code == 0)
    if timed_out:
        problem = "no result after %d s (timeout)" % timeout
    elif m is None:
        problem = "no result line (the suite stopped early; exit code %s)" % code
    elif failed:
        problem = "%d check(s) failed" % failed
    elif code != 0:
        problem = "exit code %s" % code
    else:
        problem = None
    failing = [l.strip() for l in lines if re.search(r"\bFAIL\b", l)]
    return {"passed": passed, "ok": ok_count, "failed": failed, "seconds": round(seconds, 1), "exit_code": code,
            "problem": problem, "failing_lines": failing[:40], "tail": lines[-25:], "output": output}


def run_lint(luac):
    sys.path.insert(0, os.path.join(DEV, "tools"))
    started = time.time()
    try:
        import lint
        result = lint.run(ROOT, luac)
        errors, warnings = result.count("error"), result.count("warning")
        skipped = [n for n in result.notes if "skipped" in n]
        lines = ["%s %s:%d [%s] %s" % (f["severity"], f["file"], f["line"], f["rule"], f["text"]) for f in result.findings]
        lines += ["note %s" % n for n in result.notes]
        return {"passed": errors == 0 and not skipped, "ok": result.files, "failed": errors, "warnings": warnings,
                "seconds": round(time.time() - started, 1), "exit_code": 1 if errors else 0,
                "problem": ("%d error(s)" % errors) if errors else (skipped[0] if skipped else None),
                "failing_lines": [l for l in lines if l.startswith("error")][:40], "tail": lines[-25:], "output": "\n".join(lines)}
    except Exception as e:      # a broken lint must show as a failure, not take the runner down
        return {"passed": False, "ok": None, "failed": None, "warnings": None, "seconds": round(time.time() - started, 1),
                "exit_code": None, "problem": "lint could not run: %s" % e, "failing_lines": [], "tail": [], "output": ""}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Run every offline test of the mod and the lint.")
    ap.add_argument("--only", action="append", default=[], metavar="NAME", help="run only this suite (repeatable; `lint` is one too)")
    ap.add_argument("--list", action="store_true", help="list the suites and stop")
    ap.add_argument("--tmp", metavar="DIR", help="folder for the suites' temporary files (default: <system temp>/g1r-tests)")
    ap.add_argument("--json", metavar="FILE", help="summary file (default: dev/out/test-summary.json)")
    ap.add_argument("--timeout", type=int, default=900, metavar="SECONDS", help="per suite (default 900)")
    ap.add_argument("--lua", help="Lua 5.4 interpreter (default: lua5.4 on the PATH)")
    ap.add_argument("--luac", help="Lua 5.4 compiler for the lint (default: luac5.4 on the PATH)")
    ap.add_argument("--verbose", action="store_true", help="print the whole output of a failing suite")
    args = ap.parse_args(argv)

    suites = discover()
    names = [s[0] for s in suites] + ["lint"]
    if args.list:
        for name, kind, path in suites:
            print("%-22s %-6s %s" % (name, kind, os.path.relpath(path, ROOT).replace("\\", "/")))
        print("%-22s %-6s %s" % ("lint", "python", "dev/tools/lint.py"))
        return 0
    wanted = set()
    for item in args.only:
        wanted.update(x.strip() for x in item.split(",") if x.strip())
    unknown = sorted(w for w in wanted if w not in names and not any(n.startswith(w + "/") for n in names))
    if unknown:
        print("unknown suite(s): %s (have: %s)" % (", ".join(unknown), ", ".join(names)))
        return 2

    def selected(name):
        return not wanted or name in wanted or name.split("/")[0] in wanted

    lua = find_tool(args.lua, ("lua5.4", "lua54", "lua"))
    luac = find_tool(args.luac, ("luac5.4", "luac54", "luac"))
    need_lua = any(kind == "lua" and selected(name) for name, kind, _ in suites)
    if need_lua and lua is None:
        print("lua5.4 not found: install Lua 5.4 or give --lua PATH")
        return 2

    tmp = os.path.abspath(args.tmp or os.path.join(tempfile.gettempdir(), "g1r-tests"))
    os.makedirs(tmp, exist_ok=True)
    env = dict(os.environ)
    env["G1R_TEST_TMP"] = tmp
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    if lua:
        env["G1R_LUA"] = lua
    if luac:
        env["G1R_LUAC"] = luac

    results = []
    for name, kind, path in suites:
        if not selected(name):
            continue
        r = run_suite(kind, path, lua, env, args.timeout)
        r["name"], r["kind"] = name, kind
        results.append(r)
        print("%-22s %-4s %6s ok %4s failed %7.1f s%s" % (name, "ok" if r["passed"] else "FAIL", r["ok"] if r["ok"] is not None else "?",
                                                         r["failed"] if r["failed"] is not None else "?", r["seconds"],
                                                         ("   " + r["problem"]) if r["problem"] else ""))
        if not r["passed"]:
            shown = r["output"].splitlines() if args.verbose else (r["failing_lines"] or r["tail"])
            for line in shown:
                print("    | " + line[:300])
        sys.stdout.flush()
    if selected("lint"):
        r = run_lint(luac)
        r["name"], r["kind"] = "lint", "python"
        results.append(r)
        print("%-22s %-4s %6s files %2s errors %5.1f s%s" % ("lint", "ok" if r["passed"] else "FAIL", r["ok"] if r["ok"] is not None else "?",
                                                           r["failed"] if r["failed"] is not None else "?", r["seconds"],
                                                           ("   %d warning(s)" % r["warnings"]) if r.get("warnings") else (("   " + r["problem"]) if r["problem"] else "")))
        if not r["passed"] or r.get("warnings"):
            for line in (r["failing_lines"] or r["tail"]):
                print("    | " + line[:300])

    total_ok = sum(r["ok"] or 0 for r in results if r["name"] != "lint")
    total_failed = sum(r["failed"] or 0 for r in results if r["name"] != "lint")
    passed = bool(results) and all(r["passed"] for r in results)
    print("%s: %d suite(s), %d check(s) ok, %d failed%s" % ("ALL PASSED" if passed else "FAILED", len(results), total_ok, total_failed,
                                                          "" if passed else " - failing: " + ", ".join(r["name"] for r in results if not r["passed"])))

    summary = {"passed": passed, "checks_ok": total_ok, "checks_failed": total_failed, "time": time.strftime("%Y-%m-%d %H:%M:%S"),
               "suites": [{k: r[k] for k in ("name", "kind", "passed", "ok", "failed", "seconds", "exit_code", "problem", "failing_lines")} for r in results]}
    json_path = args.json or os.path.join(DEV, "out", "test-summary.json")
    try:
        os.makedirs(os.path.dirname(os.path.abspath(json_path)), exist_ok=True)
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=1)
    except OSError as e:
        print("summary not written (%s)" % e)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
