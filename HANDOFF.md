# G1R_MegaMod - handoff, 2026-10-06 (cloud)

Rules and commands: `CLAUDE.md` (read it first). This file: what the project is, where it stands, the next step, the
queue. Keep it current: when a step is done, change its line here (one line). `mega\PLAN-NEXT.md` and `mega\PLAN.md`
are the cloud session's plan and log - history, for looking things up; this file replaces them.

## 0. This repository

The work moved from the player's PC into this public repository on 2026-10-06, with megamod 0.3.4 (0.3.3: the
scavenger's own name; 0.3.4: no "Frozen" on every hit) and settings app 2.1.1, both installed on the PC. `<h>`, `<proj>`, `<game>` and the other placeholders are places on that PC
(`docs/CLAUDE-local-pc.md`); what this file names there - packages, backups, session evidence, the game's scripts and
data - is on that PC only, not here. The deploy scripts read the PC's places from `deploy/deploy_settings.json` (not
committed). From now on this repository is the source; `<h>\mega` on the PC is the state of 0.3.4.

- In the cloud: P5 DONE (0.3.5 + app 2.1.2, committed, not installed); P3 facts of the 0.3.2 session DONE.
- Next, local session: release 0.3.5 + app 2.1.2 (section 3).
- Needs the PC (a local session): installs and audits, rehearsals, the app's UI tests, anything that reads the game.

## 1. The project in short

- Gothic 1 Remake (Steam, build `Build83_CL174209`, UE 5.4.3, game logic in AngelScript), script loader UE4SS v3.0.1
  fork "AngelScript Fix 0.4". The game cannot be run by you; everything is tested offline and the truth comes from
  the logs of the player's sessions (the work loop: `mega\G1R_MegaMod\dev\AI_GUIDE.md`).
- **G1R_MegaMod**: one Lua mod, a loader + kit + settings service and these modules: repopulate (creature respawn,
  herb regrowth, world items, container restock, crime switch), markers (NPC pins on the map), regen, magic, melee,
  mining, locks, xp, wait, general (notes, letters), mount, movement, intro, keys, timers, othermods. Each module: `main.lua`, `schema.lua` -> `config.lua`, `README.txt`, a test
  suite, a facts file. In-game mod menu, console command `g1r`, diagnostics in `Scripts\diagnostics\`.
- **Settings app** "G1R_MegaMod Settings" (`G1R_Repopulate_Settings.exe`, C# .NET 8 WinForms, Windows XP look) edits
  the config files; desktop shortcut "G1R_MegaMod Settings".
- **Installer / audit / rehearsal**: `<proj>\megamod\install_megamod.py`, `audit_megamod.py`, `sim_megamod.py`
  (sources `mega\deploy\`). Every install so far: rehearsal on copies, install with the game closed, AUDIT OK, a
  backup folder with a rollback script, a notes file for the player in `<proj>\`.

## 2. State now

- **Installed (game folder):** megamod **0.3.4** + settings app **2.1.1** (2026-10-06 12:53; package
  `<proj>\megamod\G1R_MegaMod-0.3.4-dev.zip` sha256 `852fc301...af21`, 6 replaced, rehearsal-0.3.4 47/47, AUDIT OK 29,
  backup `<proj>\megamod-install-backup-20261006-125340\`; 0.3.3 at 12:46: 9 replaced, rehearsal-0.3.3b 47/47, AUDIT
  OK 29, backup `...-20261006-124614\`; notes for both `<proj>\G1R_MegaMod-0.3.4-notes.md`). Evidence of the 0.3.2
  session (10:33-12:44, no mod errors): `<proj>\megamod\session-0.3.2-20261006-1033\end\` - markers 2.7 drawn pictures
  loaded (`markers.textures = 65 loaded, 0 failed`), `movement.mount_set = found (1.00)` + `mount_write = works` (x1.30;
  HeroSpeed 1.00: idle), two whistles answered (26 m -> 16 m; 156 m -> mounted), `timers.light_by = engine timer`;
  the player reported "Frozen" on every hit (fixed in 0.3.4, P4 item 8).
  Before: megamod **0.3.2** + settings app **2.1.1** (2026-10-06 10:22, package sha256
  `74f3f00d...ada8`, 470 added / 15 replaced, rehearsal-0.3.2 47/47, AUDIT OK 29, backup
  `<proj>\megamod-install-backup-20261006-102210\`, notes `<proj>\G1R_MegaMod-0.3.2-notes.md`). Evidence of the 0.3.1
  session (09:45-10:09, 0 errors): `<proj>\megamod\session-0.3.1-20261006-0946\end\` - `movement.mount_set = found (1.69)`
  at its first look: the save keeps the scavenger's SpeedModifier (1.3 x 1.3 from the session before: MV5 IN-GAME);
  0.3.2 sets 1.0 x 1.3 at the first look. Keys 1.1.0: pause menu found, other mods read.
  Before: 0.3.1 (09:45, backup `...-20261006-094515`); 0.3.0 + settings app **2.1.0** (2026-10-06 08:34, one run; package
  `<proj>\megamod\G1R_MegaMod-0.3.0-dev.zip`, sha256 `f1ed0c53f60ce677e6228efc853fa8ee51e36e73a1c39eec1865c6233e1414dc`;
  app sha256 `9193e14582f24641...`; AUDIT OK 29; backup + rollback `<proj>\megamod-install-backup-20261006-083421\`;
  notes `<proj>\G1R_MegaMod-0.3.0-notes.md`). Not run in the game yet.
  Before: 0.2.3 (2026-10-05 20:32, backup `...-20261005-203211\`), app 2.0.0 (22:08, backup `...-20261005-220822\`).
  0.2.3's first session: 21:07-22:05, UE4SS.log without error lines; evidence copied read only (hashes checked) to
  `<proj>\megamod\first-session-0.2.3-20261005-2107\end\` - read (P2 step 0): one whistle, the scavenger came; nothing failed.
  Another session 2026-10-05 22:14-23:38 (84 min, 0 errors; evidence copied read only, hashes checked, to
  `<proj>\megamod\session-0.2.3-20261005-2214\end\`): 2 whistles (178 m, 887 m), the scavenger came both times
  (in `devacts\mount.md`); no respawn cycle came due. The settings app 2.0.0 was open since 22:14.
- **0.2.3 = 0.2.2 + module `mount`** (The player: "Sometimes my scavenger won't come to me when called ... fixed on
  restart"): every whistle logged (`[G1R_Mount] whistle N: ...`), a second look after 8 s, and when the scavenger did
  not come: riding block off the hero, fear off the scavenger, back to its idle routine (setting "When it did not
  come": full / safe / off; key + console `mount`, `mount report`, `mount fix`). Facts: `mega\G1R_MegaMod\dev\facts\mount.md`
  (M3-M7 are OFFLINE until a session shows them). Also repopulate 1.4.1 (util.lua walk-wait fix).
- **Last real session:** 0.2.2, 18:24-19:47, 82 min, no crash, 0 errors. Evidence:
  `<proj>\megamod\first-session-0.2.2-20261005-1824\end\` (UE4SS.log, session log, report, .ops, profile copy).
- **Working tree** (`mega\`) = installed 0.3.0 (sources of the package and of app 2.1.0). Older note (0.2.3 time):
  0.2.3 plus test-only changes (not in any package, none needed):
  `dev\tests\repopulate\main_cases.lua` (new checks: a session reset ends the update; StartDelaySeconds = 0; another
  player controller; the profile change does no part work in that update; clock at 0.5 s counts as begun; no
  ReloadCheckSeconds in the file = 15 s) and the new `dev\tests\repopulate\mutations_accepted.txt` (13 reasons).
  Full run in the cloud after these changes: **ALL PASSED, 22 suites, 6770 checks, lint 149 files 0 errors.**
- **Settings app 2.1.0** (installed 2026-10-06 with 0.3.0): source `mega\app\src\`, build folder
  `<proj>\repopulate-settings-2.1.0\`. 2.0 layout (`mega\app\PLAN-app-2.0.md`: category pane left + tabs right) with
  nine categories / 30 tabs (new: Hero > Movement, Interface > Game start / Key list / Effect timers, Other mods);
  writes Game.ini (`GameStart.cs`) and the two other mods' .ini lines (`OtherMods.cs`) on Save with the game closed.
  2.0.0 (2026-10-05, P1) is in `megamod-install-backup-20261006-083421\replaced\`.

## 3. Next step

**Local session: release megamod 0.3.5 + settings app 2.1.2** (P5, made in the cloud 2026-10-06; only texts changed,
no setting / default / range / logic). Cloud checks: suite 27 / 7470 ALL PASSED, lint 187 / 0, `build_release.py
--check` OK (1033 files); every schema compared field by field with 0.3.4 (only Header / Notes / Hint / Comment /
Menu / MenuLabel / Label / Unit differ); app fixtures regenerated (`gen_fixtures.sh`). The C# was NOT compiled or run
(no Windows in the cloud) - only string literals changed. Steps on the PC, game closed where it says so:
1. Pull the repository; `app/src/StartupLoadingScreen.txt` from `app/tools/make_startup_screen.py` if missing.
2. Build app 2.1.2; exe `--selftest`, `--uitest`, filetests selftest + `--live` (needs `lua5.4`), `--snapshot` normal +
   smallest: look at every page (texts shorter: Overview, World pages, Map pins, module pages). Fix if a test pinned a
   text the cloud missed (strings changed: `GameStart.cs` notes / status, `OtherMods.cs` status, `MainForm.cs` repopulate
   pages, Overview notes, tool tips; tests updated: `SelfTestGameStart.cs`, `SelfTestModules.cs` Find "Large gain from").
3. Package the release way (forbid file + foreign packages): `G1R_MegaMod-0.3.5-dev.zip`; installer `PACKAGE` ->
   0.3.5-dev (both copies); rehearsal 47/47; install mod + app (the player's config.lua files stay byte-identical:
   only the shipped defaults' comments changed); AUDIT OK; notes `<proj>\G1R_MegaMod-0.3.5-notes.md`.
Then P3 for the sessions after 0.3.4 (the scavenger's name - notes `mount.name_*`; no "Frozen" on hits; MV5 re-summon
under movement 1.1.0; MV6 hero speed when the player sets it; how the drawn pins look).

Done before: **0.3.3 (P4 item 7, the scavenger's name)**, waiting from 11:02 while the game ran 10:32-12:44; installed
12:46. Package `<proj>\megamod\G1R_MegaMod-0.3.3-dev.zip` sha256 `cc388e94...0dcc` (also in `incoming-0.3.3`;
PACKAGE set in both installer copies); suite 27 / 7467, lint 187 / 0; app 2.1.1 unchanged (`--live` ok: the Mount tab
takes the new group). `rehearsal-0.3.3` ran with the game open: 36 / 47, the 11 failures are the rollback refusing
("Close the game first") - rerun as `rehearsal-0.3.3b` when `Get-Process G1R*` is empty, then install `--check`,
install, audit, notes `<proj>\G1R_MegaMod-0.3.3-notes.md`. P6 (the public repository) does not touch the game: built
meanwhile; `move_to_cloud` after the install (the cloud cannot install).

Earlier: **P4 item 3: drawn map pins** -> 0.3.2 with app 2.1.1 (INSTALLED 10:22). 0.3.1 INSTALLED 2026-10-06 09:45 (The player: "Game is
closed, push some stuff rq"): items 1, 2, 4, 5; package `G1R_MegaMod-0.3.1-dev.zip` sha256 `b7e303a9...366f`, 45
replaced; rehearsal `rehearsal-0.3.1` 47/47; AUDIT OK 29; backup `megamod-install-backup-20261006-094515`; notes
`<proj>\G1R_MegaMod-0.3.1-notes.md`; suite 27 / 7374, lint 186 / 0. P3: copy the 0.3.0 session's final evidence
(interim copies in `<proj>\megamod\first-session-0.3.0-20261006-0848\at-*`), upgrade TM / K18 / K19 / MV facts.

- P0 done 2026-10-05 21:22 on this PC (WSL, CLAUDE.md section 4): baseline ALL PASSED 22 suites / 6770 checks / lint
  149 files 0 errors; rerun of the 19 main.lua mutants (`--jobs 4`): 6 killed, 13 accepted, 0 survived, no unmatched
  accept line.

## 4. Queue after that, in order

### P1 - settings app 2.0.0 on this PC (game closed for step 3)
1. DONE 2026-10-05 21:38: `<proj>\repopulate-settings-2.0.0\` (src copy; `publish\G1R_Repopulate_Settings.exe`;
   reports in `test\`). filetests (built in `mega\app\filetests\bin`): selftest 123 ok / 0 failed, `--presets`
   identical, `--live` 12 ok after a fix in `filetests\LiveTests.cs` (cases files now written with "\n": WriteAllLines
   gave "\r\n" on Windows and the generator in WSL read a closing step as "reset\r"). `--live` here needs `lua5.4` on
   the PATH = the WSL stand-in `<h>\scratch\filetests-2.0.0\luabin\lua5.4`, and `C:\g1r\...` paths (no apostrophe).
2. DONE. `--snapshot-screen` (+ `--smallest`) copies the real screen, so only with the game closed (done 22:07):
   pixel-identical to `--snapshot` except Find, whose result list is a popup only the screen shows (fine at both
   sizes); the other modes are safe while the game runs (off screen, opacity 0, never activated). On the copy `<h>\scratch\app-2.0.0\`:
   exe selftest 123 ok, uitest 54 ok; `--snapshot` normal + smallest (34 + 34) and uitest (18) pictures all looked at;
   `--snapshot` of the installed megamod read only (its 12 config.lua hashes unchanged). Fixed: the Overview page had
   no scroll bar (smallest window: "Files" cut off) - now in an `XpScrollPanel` like the module pages, notes wrap
   (`MainForm.OverviewPage`); rebuilt (exe sha256 `87FF0635...913D`): normal pictures identical, smallest Overview
   scrolls. No word of `release-forbid.txt` in the exe. Not auto-tested: Ctrl+F / Enter / Escape in the Find box - say
   so in the notes.
3. DONE 2026-10-05 22:08: check (0 added / 0 replaced, app replaced), install, AUDIT OK 29 (UE4SS.dll unchanged; app
   sha256 87ff0635...), the 12 config.lua byte-identical, old app + rollback in
   `<proj>\megamod-install-backup-20261005-220822\`. Desktop shortcut "G1R_MegaMod Settings.lnk" still points at the
   installed exe. Logs: `<proj>\megamod\install-app-2.0.0*.txt`, `audit-app-2.0.0*.txt`.
4. DONE: notes `<proj>\G1R_MegaMod-settings-2.0.0-notes.md`; megamod `README.txt` page list -> the 2.0 layout in the
   working tree 2026-10-05 21:45 (rides with 0.3.0; lint + tools ok).

### P2 - megamod 0.3.0 (one package, built feature by feature, each with tests before the next)
Feasibility is done for every feature - read it, do not redo it: `mega\research\q3\feasibility-0.3.0.md` (skip intro,
key list, Gothic font, distances), `mega\research\q3\spell-timers.md` (timers), movement findings in `mega\PLAN.md`
(2026-10-05 entries, tasks #71/#72).

0. DONE 2026-10-05: evidence `<proj>\megamod\first-session-0.2.3-20261005-2107\end\`; one whistle (21:08), the
   scavenger came and the hero was mounted 8 s later; `mount.lookup = works`, `mount.tags = readable`, 0 errors.
   `dev\facts\mount.md` upgraded (M1, M2, M3 tag reads, M4 whistle, M8 -> IN-GAME); M3 `RemoveTag`, M4 with the
   block, M5, M6, M7 stay open (they show only when it does not come). No mount call failed: no 0.2.4.
1. **Hardening leftovers** (the other agent review package `<proj>\megamod\review-20261005\`, findings extracted to
   `<h>\scratch\review\`: F08 items, F09 marker cache identity, F11/F12 creatures, F13 profile, F14 wait, F16 module
   start guard; containers = brief section 5): containers by key, engine lookups, creatures, items, wait, module start
   guard. F11 DONE 2026-10-05: the corpse half was already in 0.2.2; the spawn half now - an unreadable player
   position defers the spawn like 'too close' (`creatures.lua` `spawnStep`; check in the harness case 'player too
   close'; suite 6774 ok; mutants of the condition killed; 9 older survivors of that block in
   `<h>\scratch\mut\creatures_spawnstep.txt`, not handled yet). F14 DONE 2026-10-05: wait asks hero / pause / "When not to wait" states again right before
   every call that moves the clock (`stillFine`, `secondLook`, `checkLook`); 6 new checks (weapon / talk / pause /
   hero gone between the looks), read-count pins 11 -> 16; all mutants of the new lines killed. F16 DONE 2026-10-05: a module whose start raises
   leaves its callbacks inert (`sandbox.lua` life per environment, `Sandbox.fail` called by the loader; works where
   the diagnostics wrap the module, i.e. always in the loader); loader test 'what a module registered before it
   raised does nothing'; suite 6783 ok; mutants of the new lines killed. F08 DONE 2026-10-05: item spots - only what differs
   is written (log: "N written now"), a pass with a raising spot is not done and is made again 10 s later, given up
   after three in a row; 5 new checks; mutants killed or accepted in the new
   `dev/tests/repopulate/mutations_accepted_items.txt` (4 lines with reasons); suite 6793 ok. Looked at, nothing to
   do: F09 (markers ask the game for every person at every refresh since 0.2.2, M13; only the scan fallback, never
   used in the game, keeps states up to 10 s) and engine lookups (0.2.3 session: 2 walks in 58 min, repopulate 26 ms,
   mining 6 ms). F12 DONE 2026-10-06: spawn confirmation - the first three point spawns of a run are looked up by the
   returned Name (`FindNPCByUniqueName`, 2-20 s later); once one is found, a corpse goes only for a found creature and
   "None" is a failed spawn; until then / without the lookup corpses go at once as before (`creatures.lua` `lookUp`,
   `confirmStep`, `C.confirmState`; fact R28 + note `creatures.spawn_confirm`, UNKNOWN in the game). Harness models
   the lookup in the engine run only (`H.noNpcLookup = not ENGINE`); 21 new checks incl. the deferral cap (the 9 old
   spawnStep survivors are killed now); all mutants of the new code killed or accepted in the new
   `dev/tests/repopulate/mutations_accepted_creatures.txt` (4 lines); suite 6826 ok. F13 DONE 2026-10-06: progress file read record by record
   (wrong shapes left out, logged), a newer `version` left untouched, no file for an unreadable profile (was the shared
   `profile_default.lua`), serializer bounded (cycles / depth 12); R2 updated, R29 new; 18 new checks; mutants killed
   or accepted (2 equivalent lines with reasons); suite 6859 ok. util contract DONE 2026-10-06: `U.gone` - an object whose `IsValid` raises,
   or whose methods cannot be looked up, counts as gone (nothing read); plain values pass as before; 2 pointer checks;
   suite 6861 ok. Containers by key: DECIDED, not redesigned - the brief's C1-C8 are covered by the in-play design
   since 1.4 (world.lua Begin/EndPlay, IN-GAME `core.play_hooks = in use`; `track` returns at once for an entry that
   left play) and by the pointer suite (address reuse, Image handed the address, won roll kept, IsValid cases); a
   design without any kept object would replace that proven way with an unproven one (The player can still ask for it).
   Installer / audit SHORTCUT name - DONE 2026-10-06: `G1R_MegaMod Settings.lnk` in install / audit / sim (sources and
   the running copies in `<proj>\megamod\`, identical); the next install records it in its baseline (an audit run now
   only differs on it, and on what the game wrote since - an audit means something right after an install only).
   STEP 1 DONE 2026-10-06.
   (A red run with 0 failed checks and "no result line" = run_tests.py called by a relative path after `cd`: the
   apostrophe path reaches the harnesses' unquoted `cp -r`. Always call it by `/mnt/c/g1r/...`.) Module versions:
   magic is 1.0.1 already; repopulate, wait: bump at packaging (step 8). Facts U18, U19, R20-R23, K12-K15 -> IN-GAME: DONE 2026-10-05 (0.2.2 report of 19:47 + the
   0.2.3 session; R20 / R21 fallbacks and an end of play (R22) stay OFFLINE). Magic's "look N (check)" line: DONE 2026-10-05 (magic
   1.0.1: a check look that changed nothing writes no line; 2 new checks, 16/16 mutants of the lines killed). Small ones DONE 2026-10-05: repopulate
   `VERSION = "1.4.1"` (status pin in `main_cases.lua`, module README); `loadState` returns only the spawn-point count
   (its 3 accept lines dropped); CHANGELOG has a "0.3.0 (in work)" section; suite 6770 ok; full `main.lua` mutation
   run: 365, 351 killed, 10 accepted, 0 survived. Installer + audit (`mega\deploy\` and `<proj>\megamod\`): `SHORTCUT` still names
   "G1R_Repopulate Settings.lnk"; the real one is "G1R_MegaMod Settings.lnk", so the audit checks one that is not there.
2. **Module `movement`** DONE 2026-10-06 (offline): `modules/movement/` (main, schema, config from gen_config, README),
   `dev/facts/movement.md` (MV1-MV5; the game's data SOURCE + usmap, whether the game uses new values UNKNOWN),
   `dev/tests/movement/harness.lua` (89 checks), mutation 246: 228 killed, 17 accepted with reasons, 0 survived;
   kit `attributeSetOf(state, part)` (+ core check, MODULES.md); `Scripts/core/modules.lua` + shipped `Scripts/config.lua`
   switch `Movement`; loader / presets expectations; mod README + CHANGELOG; app `NavModel.cs` gets Hero > Movement - the
   installed app 2.0.0 does not know the page: rebuild + install the app with 0.3.0 (step 8). Suite 23 suites, 6954 ok.
   Swimming: the map `m_Speeds` of `Default__LocomotionSpeedSettings_Swim_Laying_Player` x multiplier; scavenger:
   `AttributeSet_Movement.SpeedModifier` of the state found by unique name x multiplier (also while it follows).
3. **Skip intro** - the player: "Add into the list an option in the megamod to skip the intro". Default off. Way 1:
   `%LOCALAPPDATA%\G1R\Saved\Config\Windows\Game.ini` override of `MoviePlayerSettings` (`!StartupMovies=ClearArray`,
   `bWaitForMoviesToComplete=False`) - first read the packed `DefaultGame.ini` from the pak to see which list holds
   the four logos. Way 2 (moving the .bk2 files aside and back) only if way 1 cannot work. Second toggle for
   `G1R_Intro.bk2` (new-game film). Effective at the next game start; installer / app writes the ini, the mod itself
   does not touch game files.
   DONE 2026-10-06 (offline): the packed `G1R/Config/DefaultGame.ini` (pak v11, Oodle; `re-tools/pakread.py`) has no
   `MoviePlayerSettings`: the logos are `[/Script/AsyncLoadingScreen.LoadingScreenSettings] StartupLoadingScreen=(...
   MoviePaths=("Alkimia_Logo","THQNordic_Logo","V_LegalScreen","LoopingEngineLoadScreen"), MT_LoadingLoop, not
   skippable)` (Game_Logo is not in it). Way 1 adjusted: the app writes `StartupLoadingScreen=` with the packed value and
   only the three logos left out (a struct value replaces the whole struct) between two comment lines into Game.ini
   (`app/src/GameStart.cs`, value `StartupLoadingScreen.txt`; only with the game closed; first version kept as
   `Game.ini.before-G1R_MegaMod`; a file it made goes again; another tool's key left alone). The film: script
   `LoadingScreen_Intro` (type 2 of the native `LoadingScreenHelperSubsystem`, Get/SetCurrentLoadingScreenType = native
   UFunctions per params.py) - the module sets type 2 -> 0 in the kit's map load hook "before" (no file touched).
   New module `intro` 1.0.0 (switch `Intro`; settings app only, `menu = false`): SkipLogos / SkipNewGameFilm (off),
   reads Game.ini and the plugin's settings object (`intro.start_movies` tells after a start whether Game.ini was
   taken). `dev/facts/intro.md` IN1-IN6 (SOURCE / DISASM; the effect UNKNOWN), harness 95 checks, mutation 198: 190
   killed, 6 accepted, 0 survived. App: NavModel Interface > Game start, SchemaPages `ExtraNote`, MainForm Save /
   load / activate, self tests 159 ok (`SelfTestGameStart.cs`: file cases + a window case in `--uitest`), `--live` 13 ok
   (layout now with Movement and Game start; marks of app and module compared). Suite 24 suites, 7052 ok. README,
   CHANGELOG, module README; mount line of "Not seen in a game yet" updated. App needs 2.1.0 (step 8).
4. **Key list** - the player: "a spot in the menu in the top left when you hit escape and you're in the pause menu where it
   shows you all of your modded keybinds and what they do, or a keybind that reveals that list. Have it be fairly
   unobtrusive". `NotifyOnNewObject` on `/Script/G1R.PauseMenuWidget` (+ `bIsActive`), own widget top left (kit's
   widget code), optional key. Keys: the megamod's own from the kit (each binding needs a one-line text from its
   module), other mods' from their files (table in the feasibility file; read the files at list time).
   DONE 2026-10-06 (offline): module `keys` 1.0.0 (switch `Keys`; page Interface > Key list and in-game menu
   "Key list"; `InPauseMenu` on by default - the player asked for the list - , `ShowKey` none, `OtherMods` on). The pause
   menu is NOT kept from a NotifyOnNewObject (FACTS U17): every look reads controller -> `m_Widget` (PlayerWidget) ->
   `Stack_PauseMenu` -> `DisplayedWidget` -> `bIsActive`, and `IsA(PauseMenuWidget)` (usmap; KL1); the loop runs while
   paused (kit K6, IN-GAME). Kit: `panel(id, options)` (box in the notes' look, layer 1000 for the list; the toast now
   uses the same `buildBox`), `describeKey` / `keyList` (wait and mount describe their keys). Loader: `G1R_MODS`
   (`folder`, `runs(name)`) for reading other mods' files (SharedModMenu, HUDMap, FocusNearbyPickups via PLuaModLoader's
   enabled.txt, G1R_AutoPickUpItemNative, G1R_PutAwayTorchRedux; others from mods.txt "keys not known"); lint knows
   it. Facts `dev/facts/keys.md` KL1-KL9, kit K18. Tests: keys 68, kit 412, loader 567; mutation keys 201: 191 killed,
   9 accepted; kit ranges 0 survived (7 accepted); loader service 4/4. App NavModel + `--live` layout (Key list).
   Suite 25 suites, 7178 ok; app selftest 161, live 13. README, CHANGELOG, module README, MODULES.md.
5. **Gothic font** - the player: "change all the in-game mod text to the gothic text, or as close as you can get". Font
   objects `/Game/UI/Fonts/Boucherie-Block_Font` (blackletter) / `NotoSerif-Regular_Font`; confirm in a session which
   one the game's `W_DisplayName_GothicFont_C` uses; set `Font.FontObject` in the kit's note box, markers' names, the
   key list, the timers; fallback = today's font.
   DONE 2026-10-06 (offline): setting `Letters` (gothic / book / plain, default gothic - the player asked) in module
   `general` 1.1.0 (new group "Letters"; his general/config.lua stays untouched, the missing key takes the default).
   Kit `configureLetters` / `letters` + `applyLetters` in `buildBox`: gothic = `/Game/UI/Fonts/Boucherie-Block_Font`,
   book = `NotoSerif-Regular_Font` (typeface Default), plain = the font a new text block has; applied to live boxes at
   once; a font not found keeps the engine's (note `kit.letters`, K19 UNKNOWN in game). The map names are PNG pictures,
   not text: markers 2.5.0 picks `Assets/LabelsGothic/<same file>` (181 new pictures rendered with Windows' Old English
   Text MT by `dev/tools/labels` - same 49 px plate, prefixes (T)/(M)/(T/M)) while letters = gothic, falls back to the
   plain picture (M16). Tests: kit 425, general 24, markers 753; mutation: kit letters 14/14, markers labelRel 17/17.
   App: fixtures regenerated (`gen_fixtures.sh`), self test 161, live 13. Docs: README, CHANGELOG, general README.
6. **Highlight / loot distance** - the player: "allow changing of the distance of auto highlight and auto loot". Two numbers
   (`FocusNearbyPickups.ini` `maxRadius`, `G1R_AutoPickUpItemNative.ini` `AreaLootingRadius`) on an app page "Other
   mods" + in-game menu; installer / app writes exactly that one line per file (backup kept); effective at the next
   game start; never while the game runs.
   DONE 2026-10-06 (offline): module `othermods` 1.0.0 (switch `OtherMods`; settings app category/page "Other
   mods"; NOT in the in-game menu - the mods read their files at game start only, and the files may only be written
   with the game closed): SetHighlight / HighlightMeters (10 m) -> FocusNearbyPickups.ini `maxRadius` (cm, "1500.0"),
   SetLoot / LootMeters (5 m) -> G1R_AutoPickUpItemNative.ini `AreaLootingRadius` (cm, "750"). App `OtherMods.cs`:
   only the value of that one line changes (rest byte for byte, CRLF/LF kept), `.before-G1R_MegaMod` once, no .tmp/.bak
   left, game running -> not written + said, switch off -> file untouched, same number written otherwise (3000.0 vs
   3000) -> left. The Lua module only reads both files and says once when they differ (facts OM1-OM3). Tests: othermods
   31 (mutation 66: 62 killed, 3 accepted); app self test 176 (15 new), live 13 (layout + Other mods).
7. **Effect timers** - the player: "On you: heal / mana over time from food and potions, alcohol, swampweed, burning
   (10 s), frozen (5-8 s), electrified, wind (5 s), slowed. - all would be good, as well as any other over times that
   you could think of. Toggles in the menu. Display very small in bottom left of screen, or over health bar". Module
   `timers`: Light (engine timer `K2_GetTimerRemainingTimeHandle` on `ALightSpellVisual.TaskTimer`, else own count from
   `State.Spell.Light` + `LightSpellConfig.m_LifeSpan`); GAS effects via `GetActiveEffectsWithAllTags` +
   `GetActiveGameplayEffectRemainingDuration` (UNKNOWN in game: the first session decides, fallback = those timers
   off); alcohol / swampweed = level / depletion rate (attribute reads); knocked out, sleep / fear / charm on the hero,
   regen's own wait; check hunger / thirst / breath. One toggle per timer + master; very small text; position "bottom
   left" (default) / "above the health bar" (`PlayerBarHealthMana` geometry; fallback bottom left).
   DONE 2026-10-06 (offline): module `timers` 1.0.0 (switch `Timers`; page Interface > Effect timers + in-game menu).
   Effects read as PROPERTIES (U17-safe, no struct-param calls): playerState.AbilitySystemComponent ->
   `ActiveGameplayEffects.GameplayEffects_Internal[i]` -> `Spec.Def` (class name), `Spec.Duration`, `StartWorldTime`;
   left = start + duration - `GameplayStatics:GetTimeSeconds(world)`. Kinds by class name (TM3: Healing/Mana
   *Overtime, Burning, Frozen, Electrified, Wind, Slowed, Knocked out, Asleep, Afraid, Charmed; *Visual*, *Cooldown*,
   *Depletion* left out; others optional). Light: actor `*LightSpellVisual*` among the pawn's `Children` ->
   `K2_GetTimerRemainingTimeHandle(world, TaskTimer)` (3 failures in a row -> own count from `m_LastTimeSpan` /
   `LightSpellConfig.m_LifeSpan`). Alcohol / swampweed = level / |rate|. Box: kit panel per placement (corner +
   DistanceX/Y, default bottom left 24/200; the player's "above the health bar" = move it up), layer 40. Facts TM1-TM6 (all
   UNKNOWN in game except the box). Tests: timers 79, mutation 213: 202 killed, 10 accepted. Suite 27 suites, 7314
   ok; app self test 178, live 13 (layout with Effect timers). README, CHANGELOG, module README.
8. Package 0.3.0 the release way (CLAUDE.md section 2); settings app gets the new pages (`NavModel.cs` `Known`);
   notes file `<proj>\G1R_MegaMod-0.3.0-notes.md`.
   DONE 2026-10-06 08:34: suite 27 suites / 7314, lint 186 / 0; app 2.1.0 `<proj>\repopulate-settings-2.1.0\` (exe
   selftest 178, uitest 59, filetests 178 / live 13, snapshots normal + smallest looked at); packages `<proj>\megamod\`
   (+ `incoming-0.3.0\`): `G1R_MegaMod-0.3.0.zip` 564 files `473a1a52...`, `-dev.zip` 664 files `f1ed0c53...`;
   installer `PACKAGE` -> 0.3.0-dev (both copies identical); rehearsal `rehearsal-0.3.0b\` 47/47 (`rehearsal-0.3.0\`:
   its 8 rollback checks refused while the settings app was open); install mod + app in one run (221 added, 40
   replaced, 390 same, 13 kept; logs `install-0.3.0*.txt`), AUDIT OK 29 (`audit-0.3.0.out.txt`), the 16 player files
   (config, enabled.txt, progress) byte-identical, installed app `--snapshot` on the real settings read only (`<h>\scratch\app-2.1.0-installed\`);
   notes `<proj>\G1R_MegaMod-0.3.0-notes.md`; dev archive `<proj>\megamod\megamod-dev-archive-0.3.0.zip`.

### P3 - afterwards
- After each session of the player's: facts statuses upgraded with the evidence; `mega\research\README.md` current.
  Up to date 2026-10-06 08:37 (no session since 2026-10-05 23:38; README lists the sessions up to 0.2.3 and `q3\`).
- After each release: `<proj>\megamod\megamod-dev-archive-<version>.zip` (sources + tests + research, no game files).
  From 0.3.3 on the public repository is that archive (P6).
- DONE 2026-10-06 (cloud, from section 2's summary of `session-0.3.2-20261006-1033\end\`): FACTS M17 loading IN-GAME
  (65 loaded, 0 failed; the look not reported); movement MV3 found / written / used IN-GAME, MV5 1.1.0's single set
  IN-GAME (found 1.00, set 1.30), a re-summon under 1.1.0 not seen yet. Mount: two more whistles answered (no M fact
  changes: M3-M7 show only when it does not come).

### P4 - 0.3.1 (The player's requests of 2026-10-06, during his first 0.3.0 session)
1. **F2 menu texts** - "In game F2 mod menu needs text formatting to prevent truncating of text". SharedModMenu
   (its `viewmath.lua`, SOURCE): one line per row; item name cut after 35 chars (name column 120-300 px at 8.5 px a
   char), description after 54 (460 px), tab / sub-tab names after 28. Our `settings.lua` publishes "Label (Unit)",
   choices as "1 = a, 2 = b, ...", hints cut at 90. Fix in `settings.lua`: every published text fits (short menu
   labels / titles where needed, a choice's hint = its current option), a test over every schema pins the limits.
   DONE 2026-10-06 (offline): `settings.lua` fit / menuLabel / menuHint ("now: x (i of n)" re-published + SMM:refresh
   on change) / menuTitle (page prefix left out); schema fields MenuLabel / Menu / MenuTitle written for 10 modules
   (~190 texts); test_settings 9b checks every real schema (all fit); harness lookups moved to the short names.
   Mutation: 88, 79 killed, 3 accepted, 0 survived (after 7 new checks).
2. **Key list** - "the keybind menu in the pause menu needs to be on a toggle with the keybind shown to reveal it,
   and it needs to be smaller as a whole". Pause menu: a one-line hint with the key; the key toggles the full list
   (a default key that no other mod / the game uses); smaller box (font, padding).
   DONE 2026-10-06 (offline): keys 1.1.0 - `ListKey` F3 (new key: his file has `ShowKey = ""`, kept as Hidden),
   pause menu = "F3 - list of keys", F3 toggles the list anywhere, no key = whole list in the pause menu; lines
   without mod names, no header; `TextSize` 10 (8-16). Kit: `panel(..., { size })`, `p.resize`, letters keep the size,
   padding in step. His keys in use: F2 F6 V R X Y ] N Ctrl+N T (F3 free; the game's own bindings to check in the
   paks). Tests keys 86, kit 432; mutation keys 221 (5 survivors -> 1 killed, 4 equivalent accepted), kit 0 survived.
3. **Map pins** - "Change the appearance of the map pins to something more in-world lore accurate if you can".
   Today: bright dots in black rings, cream number discs, white name plates (modern UI). The game's map: sepia pen
   drawing + watercolour on parchment; its own player marker is a rough ink / red-ochre brush ring, its map drawings
   are pen strokes (`<proj>\tex\`, research only, never shipped). Plan: setting "PinLook" drawn (default) / classic;
   own pictures drawn by a new tool (ink circle + pigment wash: woad blue, ochre, red ochre, verdigris; numbers in
   ink; names in sepia ink with a parchment halo derived from the existing name pictures; legend on a parchment
   strip) in `Assets/Drawn/` with the same sizes; fallback to the classic file; app MapPinsSchema item.

4. **Map names font** - "On the npcs on the map, use the game's UI text font, as the gothic suggestion I made is too
   hard to read": map names no longer follow general's Letters (own setting, default the game's text face = the plain
   pictures); check that the plain pictures are Noto Serif (the game's running text, SOURCE) - with the game closed,
   read the font from the paks (AssetDump, read only).
5. **Timers** - "the UI effect tracking is putting casting a spell as burning with a 5 second cast timer as it
   casts": `GE_ManaBurn` (+ `GE_Mana_Channeling`, `GE_Mana_AimingLaunchingSpell`) = the mana cost of every cast
   (SOURCE: `GA_CastSpell_*` `m_GE_Mana`), matched "Burn". Also seen in the session: at a Light's end the game clears
   its timer and keeps the actor 5 s (`LightVisual.as` `DoDestroy`: `ClearAndInvalidateTimerHandle`, `SetLifeSpan(5)`);
   the module took the 0.0 for a failure, showed a new 5:00 and counted by itself for the rest of the run.
   DONE 2026-10-06 (offline): timers 1.0.1 - SKIP += ManaBurn, Mana_Channeling, Mana_Aiming, Removal, UnBurn,
   EquipAbilities (all 1047 GE classes of as-src run through the rules: only real kinds left); a number from the Light's
   timer is the answer (<= 0: out, no line), only a failed call counts. Tests 86; mutation 33/33 killed.

   DONE (offline) for 0.3.2: markers 2.7 + 469 pictures `Assets/Drawn` (`dev/tools/drawn/drawn.py`: Pillow + numpy,
   Noto Serif from the paks via `<h>\scratch\assetdump2` raw mode; RGBA, 128 colours, 4.7 MB); PinLook / NameLetters in
   config.lua + app (MapPinsSchema / MapPinsConfig); app 2.1.1 `<proj>\repopulate-settings-2.1.1\` (exe `a1efccb6...`,
   selftest 178, uitest 59, filetests 178 / live ok); markers suite 754 (now ~100 s: the mod copies carry the pictures).
   **Bug (The player: "Every time the scavenger is summoned, he is having his speed multiplied again and again")**: a summon
   gives new attribute objects carrying the written factor; 1.0.0 re-read it as own and multiplied again. Fixed in
   movement 1.1.0 (`factorLook`: own = the definitions' 1.0, new attributes / a setting change set 1.0 x m; harness
   summon cases). Mutation movement 268: 245 killed, 0 survived after 3 checks + 3 accepted.
6. **Player speed** - "Also add a player speed modifier." DONE (offline) in movement 1.1.0: `HeroSpeed` (0.50-3.00),
   the hero's `AttributeSet_Movement.SpeedModifier` (MV6) the same way as the scavenger's. Module movement: a multiplier for the hero's speed on land
   (as SwimSpeed / MountSpeed); find in as-src / usmap where the hero's walk / run speed lives (the scavenger's is
   `AttributeSet_Movement.SpeedModifier`; the swim speeds the map `m_Speeds` of LocomotionSpeedSettings).

7. **Scavenger's name** - "add a way to rename the scavenger in game to a custom name in the settings app if possible".
   Module mount: a text setting (settings app; texts are not editable in the F2 menu); find in as-src / usmap where
   the game takes a character's shown name (an FText property of the state / character?) and whether setting it from
   Lua sticks (UNKNOWN until a session); empty = the game's own name.
   Research 2026-10-06 (SOURCE: paks dump `<h>\scratch\namewidget\`, usmap): the name over a character is the widget
   `/Game/UI/Crosshair/W_DisplayName_GothicFont` (TextBlock `Text_CharacterName`, Noto Serif Regular 16 + outline;
   BP event `DisplayName(const FText& Name)` called by the native `HUDDisplayNameGothicFontController`). Reach without a
   search: controller `MyHUD` (GothicHUDBase) -> `m_Controllers` Map<SoftObj,Object> -> that controller -> `m_Widgets`
   Map<Object,Object> (key: the character? UNKNOWN) -> the widget -> `Text_CharacterName:SetText`. Wild scavengers
   have the same name text: the key must be matched with the scavenger (`FindNPCByUniqueName` state -> its pawn).
   Plan: mount 1.1.0 setting `Name` (text, ""), a look every 0.25 s while it is set; notes `mount.name_*`.
   DONE (offline) for 0.3.3: DISASM showed the name is `FText::FromStringTable("AlkimiaLocalization", definition
   m_UniqueName)` (`dev/facts/mount.md` M9) - no source to change; mount 1.1.0 sets the widget's text (HUD list, else a
   search every 2 s; either side of the widget list; state / character / a part of it), puts the game's own back when
   emptied; harness 159, mutation 410: 361 killed, 0 survived, 48 accepted. INSTALLED 2026-10-06 12:46 (0.3.3).
8. **"Frozen" on every hit** - the player: "Frozen status appearing when struck is not right - also appearing randomly
   for some reason". Cause (SOURCE): every damage effect puts `GE_FreezeHitsStack` (2 s) on whoever it hits
   (`GE_Damage.as:17`), and timers 1.0.1 took any name with "Freeze" for Frozen (also `GE_IceStack`, the ice build-up).
   Fixed in timers 1.0.2: Frozen = "Freeze" / "Frozen" in the name; names ending in "Stack" (hit counters) and
   `NoElectrified` (the lightning magnet's protection) are skipped. Audit of all effect names: `<h>\scratch\effect_audit.py`.
   Harness 89, mutation lines 55-150: 42 killed, 0 survived, 2 accepted. INSTALLED 2026-10-06 12:53 (0.3.4).

### P6 - public GitHub repository, then the session to the cloud (The player 2026-10-06)
"Make this into a massive github repository when done and move session into the cloud"; answers: **public**, move
**after the scavenger rename** (P4 item 7). gh is logged in as `Mjolniar` (scopes repo, workflow). Rules for the
export (a clean folder, not `<h>` itself): the mod as in the -dev package (forbid-clean), app src + filetests, deploy
scripts with their paths read from a local, ignored settings file, research notes and tools (no session logs, no
`thirdparty`, no `binds_strings.txt` / `hits.pkl`), scrubbed HANDOFF / CLAUDE ("The player", placeholders for paths);
never game files (as-src, tex, usmap, paks extracts, fonts) or other authors' mods; a scan for the words of
`release-forbid.txt` + the e-mail over the whole export must be empty; commits with the GitHub no-reply address.
Then `move_to_cloud` from the repo folder (change the session's directory first). The cloud cannot install or read
the game: installs need a local session.
DONE 2026-10-06 11:12: https://github.com/Mjolniar/G1R_MegaMod (public, branch main; commit a8f9273 by
`Mjolniar <18622548+Mjolniar@users.noreply.github.com>` - the repo's own git config; the global one holds the e-mail).
Working folder `<home>\Documents\GitHub\G1R_MegaMod\` (with the ignored `deploy\deploy_settings.json` of this PC).
Made by `<h>\scratch\export_repo.py <new folder>` from the 0.3.3 -dev package + app src / filetests / tools + deploy
(places -> `deploy_settings.json`; tested: without it both scripts refuse, with it `--check` sees the running game),
research, scrubbed HANDOFF / CLAUDE (`docs\CLAUDE-local-pc.md`) / plans; the repo's own README.md, CLAUDE.md
(rules + cloud section), .gitignore, .gitattributes (`* -text`), deploy\README.md from `<h>\scratch\repo-root\`.
Scan of all 1190 committed files for the forbidden words + e-mail (UTF-8 and UTF-16): 0. Left out: the app's
`StartupLoadingScreen.txt` (the game's packed config value) - `app\tools\make_startup_screen.py` remakes it from the
game byte for byte (checked: same sha256); the csproj stops with a clear error without it. From now on the repository
is the source; this `<h>\mega` is 0.3.3. The repository replaces the dev archives of P3.

### P5 - settings app texts (the player 2026-10-06) - DONE in the cloud 2026-10-06 as 0.3.5 + app 2.1.2 (section 3)
"clean up all explanations in the settings app to be shorter and more concise, use very short and clear language and
descriptions, and eliminate descriptions where things are self-explanatory": every schema Comment / Hint / Notes /
Unit, MapPinsSchema, the app's own pages and notes (MainForm, GameStart, OtherMods, NavModel). The config.lua comments
come from the same Comment texts (his files keep theirs). Keep the facts (ranges, what 0 means) where they matter.
Done: all 14 module schemas + MapPinsSchema (comments of self-explanatory items dropped; headers two lines), config.lua
regenerated, menu limits kept (test_settings 9b); harnesses follow the new menu names / hints, and an empty menu hint
is allowed now (locks / regen "nothing cut off" checks). Group titles and xp / general note+hint counts unchanged (the
app's UI test pins them). App: GameStart / OtherMods messages, MainForm repopulate pages, Overview notes, tool tips.

## 5. Open questions for the player (asked once; do not ask again, act on the answer when it comes)

1. Scavenger: when it fails, does it stand still or run away from you? Does a save -> load fix it, or only a full
   restart? (Decides whether "full" or "safe" is the default of the auto fix.)
2. Skip intro: the logos at game start (default meaning), or also the film of a new game? (Both will be toggles;
   default: logos only.)
3. Effect timers position: "bottom left" default, "above the health bar" as the setting - fine?
