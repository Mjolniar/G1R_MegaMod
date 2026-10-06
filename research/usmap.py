#!/usr/bin/env python3
"""Look things up in the game's property layout (usmap of build G1R-169686; the installed game is a
later build, Build83_CL174209 - names can differ in details, so treat this as SOURCE, not as proof).

    python3 usmap.py AttributeSet_Mana GameTimeSubsystem     properties of classes / structs (own and inherited)
    python3 usmap.py --own GothicCharacterState               own properties only
    python3 usmap.py --find Mining                            class, struct and enum names containing a text
    python3 usmap.py --prop Stamina                           properties whose name contains a text: Class.Prop : Type
    python3 usmap.py --enum EInventoryTypes                   the values of an enum
    python3 usmap.py --sub AttributeSet                       classes whose parent chain contains a class of that name

Functions are not in a usmap. For native functions use research/re-tools/params.py <FunctionName>
(parameter layout from the game executable) and grep research/re-tools/binds_strings.txt (what the
game's script layer is bound to, e.g. `void SkipTime(const FInGameTime& Duration)`); for the game's own
scripts read <as-src> (AngelScript source, 7317 files).
"""
import pickle
import sys

import os
# handoff: G1R_USMAP_PKL, else work/usmap.pkl two folders up (the handoff folder), else the cloud path
_PKL = os.environ.get("G1R_USMAP_PKL") or next((p for p in (os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "work", "usmap.pkl"),
        "<work>/usmap.pkl") if os.path.isfile(p)), "usmap.pkl")
NAMES, ENUMS, TYPES = pickle.load(open(_PKL, "rb"))


def chain(name):
    out = []
    seen = set()
    while name and name in TYPES and name not in seen:
        seen.add(name)
        out.append(name)
        name = TYPES[name][0]
    return out


def show(name, own):
    if name not in TYPES:
        close = sorted(n for n in TYPES if name.lower() in n.lower())[:30]
        print("%s: not in the usmap%s" % (name, (" (similar: %s)" % ", ".join(close)) if close else ""))
        return
    parents = chain(name)
    print("%s%s" % (name, (" : " + " : ".join(parents[1:])) if len(parents) > 1 else ""))
    for owner in ([name] if own else parents):
        props = TYPES[owner][1]
        if owner != name and props:
            print("  -- from %s --" % owner)
        for _, prop, kind in props:
            print("  %-46s %s" % (prop, kind))


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "--find":
        text = argv[1].lower()
        for n in sorted(TYPES):
            if text in n.lower():
                print("type  %s%s" % (n, (" : " + TYPES[n][0]) if TYPES[n][0] else ""))
        for n in sorted(ENUMS):
            if text in n.lower():
                print("enum  %s" % n)
        return 0
    if argv[0] == "--prop":
        text = argv[1].lower()
        for n in sorted(TYPES):
            for _, prop, kind in TYPES[n][1]:
                if text in prop.lower():
                    print("%s.%s : %s" % (n, prop, kind))
        return 0
    if argv[0] == "--enum":
        for name in argv[1:]:
            if name in ENUMS:
                print(name)
                for value, label in ENUMS[name]:
                    print("  %-4s %s" % (value, label))
            else:
                print("%s: no such enum (similar: %s)" % (name, ", ".join(sorted(n for n in ENUMS if name.lower() in n.lower())[:20])))
        return 0
    if argv[0] == "--sub":
        base = argv[1]
        for n in sorted(TYPES):
            if base in chain(n)[1:]:
                print("%s : %s" % (n, " : ".join(chain(n)[1:])))
        return 0
    own = False
    for a in argv:
        if a == "--own":
            own = True
        else:
            show(a, own)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
