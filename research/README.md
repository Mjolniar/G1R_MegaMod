# Research material for the megamod (Gothic 1 Remake, build Build83_CL174209, UE 5.4.3)

Nothing here is part of the mod. It is what is known about the game and about the other mods on the player's PC.
The game cannot be started from here and must never be started on the PC. Every claim about the game needs one of
these sources, and the source decides the status word in the facts file (dev/FACTS.md of the mod explains them):

| Status | Meaning | Where it can come from |
|---|---|---|
| IN-GAME | seen working in a real session | a line in one of the UE4SS logs below |
| DISASM | read from the game executable / UE4SS.dll | `research/re-tools/*.py` |
| SOURCE | game scripts, property layout, UE4SS source | `as-src`, `usmap.py`, `binds_strings.txt`, RE-UE4SS |
| OFFLINE | only exercised by our tests against a model | - |
| UNKNOWN | not known | - |

## The game

- **Game scripts (AngelScript source, 7317 files):** `<as-src>/` (`grep -rn`). This is how the game
  itself does things: abilities, effects, formulas, UI. Script classes live in `/Script/Angelscript`.
- **Property layout:** `python3 research/usmap.py <Class>` (also `--find`, `--prop`, `--enum`,
  `--sub`). From build 169686, a little older than the installed game.
- **Native functions the script layer can call:** `grep -n "Name" research/re-tools/binds_strings.txt`
  (lines like `void SkipTime(const FInGameTime& Duration)`; the type a function belongs to is the nearest
  `/Script/...` line above it - check with a few lines of context).
- **Native UFunctions with their parameters, from the executable:** `cd research/re-tools && python3 params.py SkipTime`
  -> `('0x14993b690', 1, 8, '0x4420401', ['Duration:Struct@0[ref,const]'])` (address, parameter count, size, function
  flags, parameters as name:kind@offset[ret|out|ref|const]). A function listed here is a UFunction that Lua can call
  through UE4SS and that `RegisterHook` can hook. About 2 seconds per call. Function flags: 0x400 = native,
  0x04000000 = BlueprintCallable, 0x2000 = static.
- **Packed files (pak):** `G1R-Windows.pak` (pak version 11, index not encrypted, most files Oodle-compressed) holds the
  config files the game was packed with (`G1R/Config/DefaultGame.ini`, `DefaultInput.ini`, ...); the assets are in the
  IoStore files next to it. `python re-tools/pakread.py <pak> --list <text>` lists, `--oodle <oo2core_9_win64.dll> --out
  <dir> <path>` extracts (Windows Python; the game links Oodle into its program, so the DLL comes from another installed
  game). Read on 2026-10-06: the start list of the logos (`dev/facts/intro.md`, IN1).
- **Executable:** `research/re-tools/game.exe` with `pe.py`, `scan.py` (`find_all`), `xref.py` (`callers`),
  `redis_.py` (`dis`), `props.py` (`prop_info`). Use only when a question cannot be answered otherwise.
- **Other data:** `<proj>/re/InteractionSpots.json`, textures in
  `<work>/tex`, respawn research in `<proj>/respawn-research/`.

## UE4SS (the script loader on the PC)

- Installed: v3.0.1 Beta, fork "AngelScript Fix 0.4", git c838a8ac. Its settings:
  `<mods-snapshot>/UE4SS-settings.ini`.
- Upstream source (newer than the fork; the Lua API is the same in what we use):
  `<RE-UE4SS source>/` - `UE4SS/src/Mod/LuaMod.cpp` (global functions), `UE4SS/src/LuaType/` (what an
  object, array, struct wrapper can do), `docs/lua-api/`.
- What is known about this build's behaviour: section 2 of `dev/FACTS.md` (U1 - U13). Read it.

## The other mods on the PC (other authors' work: facts may be taken from them, code may not)

Snapshot of 2026-10-01: `<mods-snapshot>/<Name>/` - BetterMining, BystanderXP, EXPModifier,
G1R_MageBalance, G1R_WaitOnT, HUDMap, SharedModMenu, SkillfulLocks, PLuaModLoader, G1R_PutAwayTorchRedux,
G1R_AutoPickUpItemNative; `mods.txt` is the PC's list. Native mods (G1R_RegenMana, G1R_RenderBridge,
G1R_ShowItemValueNative) are not in the snapshot; what is known of G1R_RegenMana is its log lines (below).

What a mod of another author does and which functions of the game it calls is a fact about the game and can be
used (say where it comes from). Its code, its texts and its data files are its author's: do not copy them, do not
translate them line by line. Our modules are written anew, do more or other things, and every feature is a
setting.

## Logs of real sessions on the PC (the only IN-GAME evidence there is)

- `research/session1/UE4SS-20261003-205934.log` and `session1/diagnostics/` (the megamod's own
  report and session log): the megamod's first session in the game, 2026-10-03 20:44, megamod 0.2.1. All ten
  modules loaded, 0 errors. IN-GAME evidence for the kit and for the modules.
- Later sessions on the PC, copied read only (hashes checked) into the project folder's `megamod\` (`<proj>` in
  CLAUDE.md; `<proj>/` in the older paths here):
  `first-session-20261003-2044\` (0.2.1, the same as session1 above), `live-session-20261005-1542\` (0.2.1 + a hotfix,
  130 min, 0 errors: how often 0.2.1 searched among all objects - why 0.2.2 asks the engine instead), `first-session-0.2.2-20261005-1824\` (0.2.2, 82 min, the
  engine's own ways seen), `first-session-0.2.3-20261005-2107\` and `session-0.2.3-20261005-2214\` (0.2.3, 58 and
  84 min, the mount module's whistles), `first-session-0.3.0-20261006-0848\` (0.3.0, interim copies `at-*`: the
  player's requests of 0.3.1), `session-0.3.1-20261006-0946\` (0.3.1, 24 min, 0 errors: the scavenger's factor kept
  in the save) and `session-0.3.2-20261006-1033\` (0.3.2, 131 min, no mod errors: the drawn pictures loaded, the
  scavenger x1.30 set once, the Light by the engine's timer). Each has `end\` with UE4SS.log, the session log, the
  report, the .ops file and a copy of the progress file; HANDOFF.md says what was read from each.
- `<proj>/re/crash-20261001-1942/UE4SS.log` (10 minutes of play, ends in a crash
  caused by another mod: U2 in FACTS)
- `<proj>/re/UE4SS-log-copy.txt`, `UE4SS-log-copy2.txt`
- `<proj>/original/UE4SS-before-uninstall.log`

`grep -n "\[SkillfulLocks\]\|\[EXPModifier\]\|\[BetterMining\]\|G1R_WaitOnT\|G1R_RegenMana"` shows what each mod
logged. A mod that only logged its load line proves that its hooks could be registered, not that they do
anything.

## The megamod

- Source: `G1R_MegaMod/`. Read `dev/AI_GUIDE.md`, `dev/FACTS.md`, `dev/MODULES.md`,
  `dev/SETTINGS.md`; the module `modules/xp` with `dev/tests/xp/harness.lua` is the worked example.
- Tests: `lua5.4 dev/tests/<suite>/harness.lua`, all: `python3 dev/run_tests.py`.
- What was found out before 0.3.0 was built (which game objects, functions and files each new feature uses, and
  what stays UNKNOWN until a session): `q3/feasibility-0.3.0.md` (skip intro, key list, Gothic font, distances of
  other mods), `q3/spell-timers.md` (effect timers). The results are the facts files `dev/facts/intro.md`,
  `keys.md`, `timers.md`, `othermods.md`, `movement.md` and K18 / K19 / M16 (kit, markers).

## The player's current settings of the mods our modules take over

The installer carries these over into our modules' `config.lua`, so each module needs settings that can express
them (its handoff says which of our keys gets which value):

- EXPModifier: `<mods-snapshot>/EXPModifier/EXPModifier.ini` (ExpMultiplier=4.0, ShowBonusMessage=true)
- BetterMining: `<mods-snapshot>/BetterMining/BetterMining.ini` (Enabled=true, StrPerOre=4, AgiPerOre=6, PreventExhaustion=true)
- G1R_WaitOnT: no settings file; the key Y and half an hour are written in its `Scripts/main.lua`
- SkillfulLocks: `<mods-snapshot>/SkillfulLocks/Scripts/config.lua`
- G1R_MageBalance: `<mods-snapshot>/G1R_MageBalance/Scripts/config.lua`
- G1R_RegenMana (native, C++): `research/thirdparty/G1R_RegenMana.ini` (fetched from the PC on
  2026-10-02) and its log lines in `G1R_RegenMana.log-lines.txt` next to it. Its code is not available.
