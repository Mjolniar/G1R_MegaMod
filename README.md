# G1R_MegaMod

Modules for **Gothic 1 Remake**, written in Lua for [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS), and a Windows
settings app for them. Every module has its own switch, and everything a module does is a setting that can be changed
while the game runs: in the settings app, in the in-game mod menu, or in the module's `config.lua`.

| Module | What it does |
|---|---|
| repopulate | The world fills up again: creatures at their own spawn points, herbs, items lying in the world, the contents of emptied chests. Named NPCs, quest and story things are never touched. |
| markers | Every named NPC on the map where that NPC is right now: pins drawn like the map itself, names, a colour key. |
| general | How the mod's notes look on screen, and the letters of its texts. |
| regen | Mana and health come back over time. |
| magic | Spell balancing: damage, mana cost, casting time, flight speed, reach, stagger. |
| melee | The game's flow helper, hit stop and camera shake of melee hits. |
| mining | Ore per swing from the hero's attributes and mining skill. |
| xp | An experience multiplier. |
| locks | Lock picking that follows the hero's skill. |
| wait | Skip game time on a key. |
| mount | Your scavenger: a name of your own over it, and a whistle it does not answer is put right. |
| movement | How fast the hero walks, runs and swims, and how fast the scavenger runs. |
| intro | Skip the logos at the start of the game. |
| keys | The list of the mod's keys (F3). |
| timers | How long the effects on you still last. |
| othermods | Settings of a few other mods, in the same settings app. |

Each module's `README.txt` (`G1R_MegaMod/modules/<name>/README.txt`) says what it does in detail, what it costs and
what has been seen working in the game so far.

## What is where

```
G1R_MegaMod/   the mod folder as it goes into ue4ss/Mods: README.txt, CHANGELOG.txt, Scripts/ (loader, kit,
               settings service, diagnostics), modules/
  dev/         the developer side: what is known about the game and where from (FACTS.md, facts/), the offline
               tests against a model of the game (tests/, run_tests.py), tools (packages, mutation checks, the
               default config.lua files, the drawn map pictures)
app/           the settings app (C#, .NET 8, WinForms, Windows XP look): src/, filetests/, tools/
deploy/        installer, independent audit and their rehearsal, as used on the PC the mod was made for
research/      how facts about the game are found (README.md) and the reading tools (re-tools/)
docs/          the instructions for that PC (CLAUDE-local-pc.md) and older plans (history/)
HANDOFF.md     the state of the work, the next step and the queue
CLAUDE.md      rules for Claude Code sessions on this repository
```

## Installing

1. Gothic 1 Remake with UE4SS. The mod is made and tested with the UE4SS fork "AngelScript Fix 0.4" (UE4SS
   v3.0.1 beta); the game's AngelScript layer needs it.
2. Copy the folder `G1R_MegaMod` into `<game>/G1R/Binaries/Win64/ue4ss/Mods/` (it has its `enabled.txt`).
3. Settings: the settings app, the in-game mod menu (F2, when SharedModMenu is installed), or each module's
   `Scripts/config.lua`. As installed, the newer modules change nothing until something is set.

`UE4SS.log` shows one load line per module; `Scripts/diagnostics/` holds the mod's own notes about which way into
the game worked.

## Developing

Offline tests (Linux or WSL, Lua 5.4 and Python 3, from a path without spaces or apostrophes):

```
sudo apt-get install -y lua5.4 python3 zip unzip
python3 G1R_MegaMod/dev/run_tests.py
```

Expected: `ALL PASSED: 27 suite(s), 7467 check(s) ok, 0 failed`, lint 187 files with 0 errors.

Read `G1R_MegaMod/dev/AI_GUIDE.md` first (the map of the mod and the work loop), then `dev/MODULES.md` (writing a
module on the kit) and `dev/SETTINGS.md` (schema.lua -> config.lua -> settings app and in-game menu). Every claim about
the game carries where it is known from: IN-GAME (a line of a real UE4SS log), DISASM (the executable), SOURCE (the
game's scripts and data layout), OFFLINE (only the tests), UNKNOWN.

The settings app: `dotnet publish app/src/G1R_Repopulate_Settings.csproj -c Release -r win-x64 --self-contained false
-o <out>`; its file tests: `dotnet run --project app/filetests -- --selftest <config.lua> <report>`.

## Not in this repository

The game's own files and data: its scripts, the property layout (usmap), its executable and what is packed in its
paks. The research tools read them from your own copy of the game (`research/README.md`). The settings app needs one
value of the game's packed config, `app/src/StartupLoadingScreen.txt`: make it from your game with
`app/tools/make_startup_screen.py`.

Mods of other authors are not in it either. The installer in `deploy/` retires a few of them on the PC it was made
for, when a module of this mod does the same job, and carries their settings over; facts about what they do are
named where they are used, none of their code, texts or pictures.
