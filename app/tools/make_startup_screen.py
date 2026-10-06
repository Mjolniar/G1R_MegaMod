"""Makes app/src/StartupLoadingScreen.txt from the player's own game.

The file is the value the settings app writes into the game's Game.ini to skip the logos at the start (GameStart.cs):
the game's own StartupLoadingScreen= of [/Script/AsyncLoadingScreen.LoadingScreenSettings] in its packed
G1R/Config/DefaultGame.ini, with the three logos left out of MoviePaths. It is the game's data, so it is not in the
repository; the app does not build without it.

    python make_startup_screen.py --game "<the Gothic 1 Remake folder>" --oodle <oo2core_9_win64.dll> [--out FILE]

The game's G1R-Windows.pak is only read (research/re-tools/pakread.py). Its config files are compressed with Oodle:
the game links Oodle into its program, so the DLL comes from another installed game (oo2core_9_win64.dll).
Windows Python (the DLL is loaded with ctypes). --out: default app/src/StartupLoadingScreen.txt.
"""
import argparse
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PAKREAD = next((p for p in (os.path.join(HERE, "..", "..", "research", "re-tools", "pakread.py"),
                            os.path.join(HERE, "..", "..", "..", "re-tools", "pakread.py")) if os.path.isfile(p)),
               os.path.join(HERE, "..", "..", "research", "re-tools", "pakread.py"))
PAK = os.path.join("G1R", "Content", "Paks", "G1R-Windows.pak")
INI = "G1R/Config/DefaultGame.ini"
SECTION = "[/Script/AsyncLoadingScreen.LoadingScreenSettings]"
KEY = "StartupLoadingScreen="
LOGOS = ("Alkimia_Logo", "THQNordic_Logo", "V_LegalScreen")


def value_of(ini_text):
    """The value of StartupLoadingScreen= in the section, or None."""
    inside = False
    for line in ini_text.splitlines():
        s = line.strip()
        if s.startswith("["):
            inside = s == SECTION
        elif inside and s.startswith(KEY):
            return s[len(KEY):]
    return None


def without_logos(value):
    """The value with the logos left out of MoviePaths=(...); None when the list is not there or has none of them."""
    m = re.search(r'MoviePaths=\(([^)]*)\)', value)
    if not m:
        return None
    movies = [p.strip() for p in m.group(1).split(",") if p.strip()]
    kept = [p for p in movies if p.strip('"') not in LOGOS]
    if len(kept) == len(movies):
        return None
    return value[:m.start(1)] + ",".join(kept) + value[m.end(1):]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--game", required=True, help="the Gothic 1 Remake folder (the one with G1R in it)")
    ap.add_argument("--oodle", required=True, help="oo2core_9_win64.dll of another installed game")
    ap.add_argument("--out", default=os.path.join(HERE, "..", "src", "StartupLoadingScreen.txt"))
    a = ap.parse_args()
    spec = importlib.util.spec_from_file_location("pakread", PAKREAD)
    pakread = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pakread)
    pak = pakread.Pak(os.path.join(a.game, PAK))
    name = next((n for n in pak.files if n.replace("\\", "/").endswith(INI)), None)
    if name is None:
        sys.exit("%s is not in the game's pak" % INI)
    text = pak.read(name, pakread.load_oodle(a.oodle)).decode("utf-8-sig", errors="replace")
    value = value_of(text)
    if value is None:
        sys.exit("%s has no %s in %s" % (INI, KEY.rstrip("="), SECTION))
    made = without_logos(value)
    if made is None:
        sys.exit("the start list has none of the logos %s: nothing to leave out" % ", ".join(LOGOS))
    with open(a.out, "w", encoding="utf-8", newline="") as f:
        f.write(made)
    print("wrote", os.path.normpath(a.out), len(made.encode("utf-8")), "bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
