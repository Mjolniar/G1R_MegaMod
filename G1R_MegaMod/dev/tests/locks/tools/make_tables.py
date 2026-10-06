#!/usr/bin/env python3
"""Makes the two tables of the module locks from the game's own lock data.

    gcc -O2 -o /tmp/lock-solver dev/tests/locks/tools/solver.c
    python3 dev/tests/locks/tools/make_tables.py <folder of the game's decompiled scripts> /tmp/lock-solver

Reads the lock definitions (classes derived from UGothicLockConfig in Items/GenericItems/LockPickGeneric.as:
AddPiece(id, start position), AddConnection(id, connectedId, direction)) and which of them a chest or a door
names (m_Lock = n"..." in InteractiveObjects/ChestsLibrary.as and TriggerSpaces.as), runs the solver on every lock
and every number of connections taken away, and writes

    modules/locks/Scripts/lockdata.lua    for the game: per lock the number of its connections and how many of
                                          them can be taken away with the lock proven to stay solvable
    dev/tests/locks/gamelocks.lua         for the tests: the locks themselves and, for every number the module can
                                          write for a lock, a way to open it (which the suite replays move by move)

"Proven": the solver searches every position a lock can be in (solver.c), so a number is only called solvable when
a way to open the lock exists, and unsolvable when none does. The proven number of a lock is the largest d such
that the lock can be opened with every number of connections from 0 to d taken away.
One lock definition of the game sets its name twice (two `default m_UniqueName = ...` lines; which of the two
the game ends up with is not known): such a lock is in both tables under each of its names.
Nothing here is taken from another mod: the input is the game's script source, the solver is this folder's.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))

LOCK_CLASS = re.compile(r"class\s+(\w+)\s*:\s*UGothicLockConfig\s*\{(.*?)\n\}", re.S)
USED = re.compile(r'm_Lock\s*=\s*n"([^"]+)"')


def read_locks(source):
    text = open(os.path.join(source, "Items", "GenericItems", "LockPickGeneric.as"), encoding="utf-8", errors="replace").read()
    locks = []
    for match in LOCK_CLASS.finditer(text):
        body = match.group(2)
        names = re.findall(r'm_UniqueName\s*=\s*n"([^"]+)"', body)
        pieces = [(int(a), int(b)) for a, b in re.findall(r"AddPiece\((-?\d+),\s*(-?\d+)\)", body)]
        connections = [(int(a), int(b), int(c)) for a, b, c in re.findall(r"AddConnection\((-?\d+),\s*(-?\d+),\s*(-?\d+)\)", body)]
        if not names or not pieces:
            raise SystemExit("a lock class without a name or without pieces: " + match.group(1))
        if [i for i, _ in pieces] != list(range(len(pieces))):
            raise SystemExit("piece ids are not 0 .. n-1 in " + names[0])
        for a, b, d in connections:
            if a == b or not (0 <= a < len(pieces)) or not (0 <= b < len(pieces)) or d not in (-1, 1):
                raise SystemExit("a connection the solver does not expect in %s: %r" % (names[0], (a, b, d)))
        locks.append({"name": names[0], "names": names, "pieces": [p for _, p in pieces], "connections": connections})
    seen = set()
    for lock in locks:
        for name in lock["names"]:
            if name in seen:
                raise SystemExit("two locks with the name " + name)
            seen.add(name)
    return locks


def read_used(source):
    used = {}
    for kind, path in (("chest", "ChestsLibrary.as"), ("door", "TriggerSpaces.as")):
        text = open(os.path.join(source, "InteractiveObjects", path), encoding="utf-8", errors="replace").read()
        for name in USED.findall(text):
            used.setdefault(name, kind)
    return used


def solve(locks, solver):
    lines = []
    for lock in locks:
        parts = [lock["name"], str(len(lock["pieces"]))] + [str(p) for p in lock["pieces"]] + [str(len(lock["connections"]))]
        for a, b, d in lock["connections"]:
            parts += [str(a), str(b), str(d)]
        lines.append(" ".join(parts))
    out = subprocess.run([solver], input="\n".join(lines) + "\n", capture_output=True, text=True, check=True).stdout
    ways = {}
    for line in out.splitlines():
        fields = line.split()
        ways[fields[0]] = [None if f == "-" else ("" if f == "=" else f) for f in fields[3:]]
    return ways


def depths_written(count, proven):
    """Every number the module can write for a lock: the choices "none", "1", "2", "all", and the two per-lock
    choices ("half", "safe") at each of the game's own numbers 0 / 1 / 2 (main.lua, depthFor)."""
    wanted = {0, 1, 2, count, proven}
    for own in (0, 1, 2):
        wanted.add(min(max(count // 2, own), proven))
    return sorted(d for d in wanted if d <= count)


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    source, solver = argv[1], argv[2]
    locks = read_locks(source)
    used = read_used(source)
    ways = solve(locks, solver)
    data = ["-- Per lock of the game: { the number of its connections, how many of them can be taken away with the lock",
            "-- proven to stay solvable } - the largest number d such that the lock can be opened with every number of",
            "-- connections from 0 to d taken away (in the order the game takes them away: from the front of the lock's",
            "-- list). Made by dev/tests/locks/tools/make_tables.py from the game's own lock definitions with the solver",
            "-- next to it, which searches every position a lock can be in; the test suite replays a way to open each",
            "-- lock for every number the module writes. A lock that is not in this table is left as the game has it.",
            "return {"]
    tests = ["-- The game's locks for the tests of the module locks (made by tools/make_tables.py from the game's script",
             "-- source; see there). Per lock: p = start positions of its pieces (ids 0 ...), c = its connections as",
             "-- id, connectedId, direction triples in the game's order, used = \"chest\" / \"door\" when an object of the",
             "-- game names the lock, ways = for the numbers of connections the module can take away from this lock a",
             "-- shortest way to open it: moves \"<piece><+|->\", \"\" = nothing to do, false = it cannot be opened.",
             "return {"]
    summary = {"locks": 0, "names": 0, "used": 0, "proven_all": 0}
    for lock in locks:
        name, count = lock["name"], len(lock["connections"])
        solved = ways[name]
        proven = -1
        for depth in range(count + 1):
            if solved[depth] is None:
                break
            proven = depth
        if proven < 0:
            raise SystemExit("%s cannot be opened even as the game has it" % name)
        summary["locks"] += 1
        summary["used"] += 1 if any(n in used for n in lock["names"]) else 0
        summary["proven_all"] += 1 if proven == count else 0
        cert = []
        for depth in depths_written(count, proven):
            way = solved[depth]
            cert.append("[%d] = %s" % (depth, "false" if way is None else '"%s"' % way))
        flat = ", ".join("%d, %d, %d" % c for c in lock["connections"])
        for each in lock["names"]:
            summary["names"] += 1
            data.append('    ["%s"] = { %d, %d },' % (each, count, proven))
            tests.append('    { name = "%s", used = %s, p = { %s }, c = { %s },\n      ways = { %s } },' % (
                each, ('"%s"' % used[each]) if each in used else "false", ", ".join(str(p) for p in lock["pieces"]), flat, ", ".join(cert)))
    data.append("}")
    tests.append("}")
    with open(os.path.join(MOD, "modules", "locks", "Scripts", "lockdata.lua"), "w", newline="\n") as f:
        f.write("\n".join(data) + "\n")
    with open(os.path.join(MOD, "dev", "tests", "locks", "gamelocks.lua"), "w", newline="\n") as f:
        f.write("\n".join(tests) + "\n")
    print("%(locks)d locks under %(names)d names, %(used)d named by a chest or a door, %(proven_all)d solvable with any number of connections taken away" % summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
