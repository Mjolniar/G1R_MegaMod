# Working on this mod (guide for an AI or a developer)

The one fact that shapes everything: **you cannot run the game.** The mod is written and tested offline, installed on
a player's PC, and what really happened is read afterwards from files. So the work is a loop:

    change -> python dev/run_tests.py -> build a package -> install on the PC -> the player plays
           -> fetch UE4SS.log and Scripts/diagnostics/ -> read them with the tools -> update dev/FACTS.md -> change

Read `dev/FACTS.md` before touching code: it says for every assumption whether it was ever seen working in the game.
Never write "works" for something that is only OFFLINE there.

## 1. Map

    Scripts/main.lua            loader, the only file UE4SS runs (finds its folder, loads core + modules)
    Scripts/config.lua          which modules run, diagnostics settings
    Scripts/core/modules.lua    the list of modules: load order, switch, mods that do the same job
    Scripts/core/diag.lua       recorder: session log, report, dump, notes, counters, errors
    Scripts/core/sandbox.lua    loads a module in its own environment, wraps the UE4SS functions
    Scripts/core/kit.lua        what modules share when they deal with the game (G1R_KIT): guarded access, the
                                engine's own ways to the hero and the subsystems, keys, notes on screen
    Scripts/core/settings.lua   a module's settings: file, settings app, in-game menu (G1R_SETTINGS)
    Scripts/core/console.lua    console command g1r
    Scripts/core/version.lua    name and version (the only place)
    Scripts/diagnostics/        written at run time (README.txt there explains every file)
    modules/repopulate/         creatures, world items, containers, crime switch (a complete mod of its own);
                                Scripts/world.lua: the actors in play, from the game's begin / end of play calls;
                                Scripts/util.lua: the engine's ways, the gate for searches, the file writer
    modules/markers/            NPC pins on the map screens (a complete mod of its own)
    modules/general/, xp/, ...  the modules written for the kit: main.lua, schema.lua, config.lua, README.txt
    dev/run_tests.py            every test and the lint
    dev/tests/<suite>/          core, loader, markers, pointers, repopulate, repopulate_engine, world, files,
                                presets, tools, one per kit module
    dev/tests/lib/modtest.lua   test library for kit modules (mock, game model, in-game menu)
    dev/tools/                  lint, mutate, gen_config, presets, loganalyze, crashtriage, diagread, build_release;
                                labels (blackletter names, C#), drawn (the drawn look of the map pins, Python + Pillow)
    PRESETS.txt                 the five presets of the settings app, every value (generated: dev/SETTINGS.md section 7)
    dev/FACTS.md, dev/facts/    what is known, and how well (one file per kit module)
    dev/MODULES.md              how to write a module for the kit
    dev/SETTINGS.md             the settings format (schema.lua, config.lua, the in-game menu, the app)
    dev/out/                    generated (test summary, packages); never part of a package

There are two kinds of modules. `repopulate` and `markers` are complete mods of their own: each must keep working
when UE4SS runs its `Scripts/main.lua` directly (that is how their harnesses run them and how they can be installed
as separate mods); the loader only adds things for them: an environment, `G1R_DIAG`, wrapped callbacks. Every other
module is written for the loader's kit and settings service and needs the loader: `dev/MODULES.md` is its contract,
and the rules below apply to it in the form given there.

## 2. Rules for the code, and why

1. **A search by path may never repeat, and its moment is chosen.** `StaticFindObject` / `RegisterHook` results are
   kept for the run, found or not. In this UE4SS build a search that is not answered from its cache walks every
   object in memory; one such walk crashed the game (FACTS U1, U2). Use the helpers (`U.findOnce`, `findStaticOnce`,
   `KIT.findOnce` / `findClass` / `findDefault`); a new place that searches goes into `dev/tools/lint_allow.txt` only
   after a harness check counts its searches. Paths of the engine and of the game's program are looked up in the
   hook before the first map load (`Kit.paths`, `U.warm` in `main.lua` `firstMapLoad`): on the game thread, before
   there is a world. Loading the mod searches nothing - UE4SS starts mods on a thread of its own while the engine is
   still starting.
2. **Do not read properties named `m_Capacity`, `m_InventoryType`, `m_InteractiveObjectDefinition`,
   `m_ItemDefinition`** (the last one only in the bounded class-learning pass of `chests.lua`). This fork logs every
   such read (FACTS U4).
3. **Every call into the game inside `pcall`** (or `U.call` / `U.get` / `wcall`, which do it). A callback never lets
   an error out.
4. **Do not keep an object the game can destroy from one update to the next.** A wrapper is a pointer; `IsValid()`
   and a comparison of the full name read the object's memory and cannot make a stale one safe (FACTS U5, U15 -
   U17; three crashes of 2026-10-04 / 05). What is safe to use: what the engine hands out in the same update
   (`KIT.controller()`, `KIT.subsystem()`, a property of such an object, the game's own look-up functions); objects
   that live for the whole run (classes, class default objects, the engine, the game instance); an actor between its
   begin and its end of play (`world.lua` keeps that list and drops an actor at its end of play); an object on a
   property list of a living object; an object the mod made itself and put on the game instance's list
   (`KIT.keepAlive`). Where a kept wrapper is all there is (the old ways, kept as fallbacks), check `IsValid()` and
   the full name before every use - that is the best that can be done, not safety.
5. **Never index a TArray wrapper at or past its length** unless growing it is the intention (FACTS U6).
6. **Write files only below `Scripts/diagnostics/` and `modules/repopulate/Scripts/state/`**, and a module's own
   `config.lua` through the settings service. Never a save file, never another mod's file. A file the player would
   miss is written to `<file>.tmp`, read back, and only then put in place, with the file before it kept as
   `<file>.bak` (`U.writeFile`, the settings service's `writeText`; suite `files`): Lua's `os.rename` does not
   overwrite on Windows, and a write can be cut off.
7. **No global variables in `Scripts/` and `modules/`**, and no personal paths or names in any file.
8. **Diagnostics only observe.** `local DIAG = G1R_DIAG` once per file; every use behind `if DIAG then`; no game
   call, no object search, no new property read for the sake of a note; a note only when its value changes.
9. **No search among all objects where the engine can be asked.** `FindAllOf` / `FindFirstOf` walk every object of
   the game without any lock while the game frees objects on another thread (FACTS U14; a crash of 2026-10-05). Ask
   the engine (rule 4). A search that is left is a fallback or a cross-check: spaced, held back after a map load
   and while many actors have just left play (`U.mayWalk`, `U.quiet`, `World.calm`), and counted by a harness
   check (`H.finds`). A fallback takes over only when the engine's way was not there or has not answered once in
   the run (`lastWord` in the kit, `final` in `util.lua`), and a note says which way is in use.
10. **Announce a step that calls into the game for more than a moment** - a search among all objects, a round over
   kept objects, a map refresh: `local t = DIAG.op("what") ... DIAG.done(t)` (`U.op` / `U.done` in repopulate). The
   record is on disk before the step runs; it is what names the step when the game dies inside it.

`python dev/tools/lint.py --explain` lists what the lint checks of this; `--lookups` lists every object search.
`python dev/tools/mutate.py <file> --suite <suite>` breaks a file on purpose, one small change at a time, and lists
the changes the suite does not notice.

## 3. Tests

    python dev/run_tests.py                 all suites + lint, summary in dev/out/test-summary.json
    python dev/run_tests.py --only markers  one suite
    lua5.4 dev/tests/repopulate/harness.lua (a suite on its own; SHOWOK=1 shows passed checks, QUIET=1 hides the mod's log)

| Suite | What it runs | What it shows |
|---|---|---|
| `loader` | `Scripts/main.lua` + core in a mock UE4SS (`dev/tests/mock/ue4ss.lua`), with tiny modules and with both real modules | loading, environments, wrappers, files, console, failure cases |
| `repopulate` | the real module against a model of creatures, item spots, containers, crime tables; then again through the real recorder. The model has no engine object and no begin / end of play calls: the module works the way 1.3 did | behaviour, number of searches and property reads, notes, no difference with diagnostics on |
| `repopulate_engine` | the same harness with the engine object handed over at a map load, the engine's libraries and the begin / end of play calls (`G1R_REPOP_MODE=engine`), plus `engine_cases.lua` | the same behaviour with one search among all objects left (the creature count); nothing of an object is touched after it left play; sessions (what ends one and what does not) |
| `world` | `world.lua` alone | the list of actors in play: registration, the first map load, begins and ends, errors, when the calls are given up, the calm test |
| `files` | the two file writers (`U.writeFile` / `U.readTable`, the settings service) with file functions that fail the way Windows does | a write that is cut off at any step leaves a readable file |
| `markers` | the real module against a model of the map widgets, with positions checked against an independent projection | pin / pool / key placement, widget budget, deleted widgets (scenario 14), notes |
| `pointers` | `chests.lua` (and `world.lua`) against a fake API with real pointer behaviour (addresses reused, freed memory that UE4SS still lists) | nothing lands in a wrong container; with the play calls freed memory is not read |
| `tools` | the dev tools on generated samples (and on real material when `G1R_SAMPLES=<folder>` is set) | the tools themselves |
| `core/test_kit`, `core/test_settings` | the two shared services alone | guarded access, searches, the hero, keys, notes; schema, config.lua text, the in-game menu's format |
| `xp`, `general`, ... | a kit module through `dev/tests/lib/modtest.lua`, and through the real loader | behaviour, settings while running, cost, notes |

What the tests do **not** show: anything about the real game. A model answers the way its author believed the game
answers. When a model is more forgiving than the real API, a defect hides behind a green test - that has happened
(a property modelled as filled that the game leaves empty on chests; `IsValid` modelled per object instead of
per address).
So:

- When you add game behaviour to a model, write down where you know it from (FACTS status words).
- After writing a check, break the code on purpose once and see the check fail.
- New behaviour gets a note key (section 5) so that the next play session confirms or refutes the model.

Harness pitfalls: a Lua function may have at most 200 local variables (wrap a new section in
`(function() ... end)()` or use a table); `pairs` order differs between runs (sort before picking fixtures); the
harnesses replace `os.clock`, `print` and the UE4SS globals for the whole process.

## 4. After a play session

Ask for two things from the PC: `UE4SS.log` (next to UE4SS.dll; rewritten at every game start) and the folder
`<mod>/Scripts/diagnostics/`.

    python dev/tools/diagread.py <diagnostics folder>      the sessions of the folder and how each ended; the newest
                                                           one: log, operations, report, notes against FACTS, dump
    python dev/tools/diagread.py <diagnostics folder> --session 2    the session before the newest - after a crash
                                                           and a restart that is the one to read
    python dev/tools/loganalyze.py <UE4SS.log>             mods started, known signatures, debug-line counts
    python dev/tools/loganalyze.py <UE4SS.log> --mod G1R_MegaMod

| Question | Where the answer is |
|---|---|
| Did the mod load, and every module? | `load:` line of diagread; `== modules ==` of the report |
| Did the game go down inside a step of the mod? | diagread `ENDED INSIDE`: the newest record of the session's operations file (`.ops`) was begun and never finished, or the session log ends with a breadcrumb. Nothing there = the game did not die inside a step the mod announced (rule 10) |
| Which way is the mod on? | the notes `kit.engine`, `kit.controller_by`, `kit.subsystem_by`, `core.engine`, `core.play_hooks`, `core.paths_found`, `markers.map_screens`: `fallback in use` or `DIFFERS` in the facts table = an engine way did not work in the game |
| How many searches among all objects were made? | report `== counters ==`: `FindAllOf` / `FindFirstOf` per module; the last status line of repopulate (`this run: ... N searches among all objects`) |
| Did anything raise? | `errors` (session log `ERROR in ...` with traceback; report `== errors ==`) |
| Did any search repeat? | diagread `REPEATED SEARCHES`; report counter `repeated after not found` must be 0 |
| Is an assumption right? | the facts table of diagread: `as expected`, `fallback in use`, `DIFFERS`, `not seen` |
| How much does the mod cost? | report `== counters ==`: calls, slow calls, longest call per callback kind |
| What does a module know right now? | console `g1r dump` in the game, then diagread on the dump |
| Did a debug-log flood come back? | loganalyze `[DEBUG_PROPTYPE]` counts (rule 2) |

Then update `dev/FACTS.md`: a note seen as expected turns its line to IN-GAME (say which session); a DIFFERS line
is a wrong assumption - fix the code and the model together. `diagread --fixture OUT.lua` turns a dump into a
fixture file, so that a harness can replay what the game really held.

In the game: console `g1r` (status), `g1r diag` (report now), `g1r dump` (dump now). `Config.Diagnostics.Level =
"verbose"` in `Scripts/config.lua` writes every line at once and records every search and registration - use it
when hunting a crash, not for normal play.

## 5. Diagnostics from inside a module

A module loaded by the loader sees `G1R_DIAG` (nil when it runs as a separate mod). Its functions never raise:

    DIAG.note(key, value, detail)   an observed fact; first and latest value are kept, a change gets a line
    DIAG.event(text)                a line in the session log only (not in UE4SS.log)
    DIAG.crumb(text)                a line that is on disk before the call returns - before a risky step
    DIAG.op(text) -> token          announces a step (a fixed-size record, on disk before the call returns)
    DIAG.done(token)                takes the announcement back when the step has returned (rule 10)
    DIAG.status(fn)                 fn() -> list of texts, shown by `g1r` and in every report
    DIAG.dump(fn)                   fn() -> plain table (texts, numbers, booleans, tables), written by `g1r dump`
    DIAG.version(text)              the module's version for the report

`print` inside a module is recorded as well. The loader wraps the UE4SS functions a module calls: callbacks are
timed and their errors caught with a traceback; `StaticFindObject` is counted, and announced on disk before a
first-time search. Status and dump functions must be built from what the module already holds - they may run at
any time and must not call into the game.

Adding a note:

1. In the module, where the fact is already at hand: `if DIAG and value ~= Noted.x then Noted.x = value;
   DIAG.note("module.key", value, detail) end`.
2. A row in the table "Diagnostics notes" of `dev/FACTS.md` - for a kit module: of `dev/facts/<module>.md` -
   (expected values, `else` fallbacks) and a line in the module's table above it.
3. A harness check that the note appears with the right value and is not repeated (the `tools` suite checks that
   FACTS.md and the modules list the same keys).

## 6. A crash

    python dev/tools/crashtriage.py <crash report folder> [--log UE4SS.log] [--dll UE4SS.dll]

The folder is one of the game's crash report folders (`CrashContext.runtime-xml`, `UEMinidump.dmp`,
`gothic_crash_info.log`); copy the `UE4SS.log` of that run next to them. The tool names a cause only when a known
signature matches (same top frames, same error, same binary). Otherwise:

1. Which module are the top frames in? `UE4SS` at the top with Lua frames below it means a Lua call was running.
2. `loganalyze` on the log of that run: which mod logged last, any `hook-retry` or Lua error?
3. `diagread` on the diagnostics of that run: `ENDED INSIDE`, repeated searches, errors.
4. Split facts from guesses in what you write down. A culprit needs evidence from the log chain.
5. Add a signature to `SIGNATURES` in `crashtriage.py` (status `seen` until the cause is known) and a line to
   FACTS section 6. Offsets are only valid for the binary named in the signature.

## 7. A release

    python dev/tools/build_release.py --check
    python dev/tools/build_release.py --forbid-file <file outside the mod> --foreign <package of the original mod>
    python dev/tools/build_release.py --with-dev ...

The builder refuses instead of warning (lint errors, personal paths in any file including binaries, forbidden
words, files of another mod, save files or crash dumps, a settings app without its default settings file). Keep the
forbidden words - user name, machine name, e-mail, folder names of the build machine - in a file outside the mod.
Before a public upload also: bump `Scripts/core/version.lua` and `CHANGELOG.txt`, and read `README.txt` once as a
player would.

Known blockers for a public upload, as of 0.2.2:

- 0.2.1 ran in the game (nine logged sessions; "Seen in the game" in the facts files). What 0.2.2 adds - the
  engine's ways, the begin / end of play calls, kept-alive pictures, the operations file, the verified writers - is
  OFFLINE: publish after play sessions with 0.2.2 have been read with `diagread` (the notes named in section 4 must
  say `as expected`) and the "In the game" sections of the READMEs have been brought up to date. The module melee
  has only run idle, and no vein was mined (module mining).
- Six modules do jobs that mods of other authors do (the `separate` names in `Scripts/core/modules.lua`). They were
  written anew from the game's scripts, layout and code; prove it for the package with `--foreign <that mod's
  package>` for each of them, and keep the credits paragraph of the README. The table `modules/locks/Scripts/
  lockdata.lua` is computed from the game's lock data by `dev/tests/locks/tools/` (an independent second solver gave
  the same numbers); it agrees with the other author's table wherever both have a lock, because both are the same
  function of the same game data.
- The settings app for the repopulate module is not in this tree. Its source had a fallback path of the build
  machine, and a .NET binary usually carries the path it was built in: rebuild it without both, then run
  `build_release.py` (it searches binaries too) before putting the app into `modules/repopulate/`.
- The idea of NPC pins on the map comes from the mod "Active NPCMarkers" (Nexus id 270, another author). All code
  and images here are new, but prove it for the package: `--foreign <the original's package>`. Credit the original
  (README does) and publish under a name that is not the original's.
- Data derived from the game: `modules/markers/Scripts/data/corr_*.bin` (map correction textures),
  `modules/markers/Scripts/npcs.lua` and the label images (names from the localisation), the tables in
  `modules/repopulate/Scripts/data/` (spawn points, item spots, container contents from the game's scripts).
  Check that the upload site's rules allow that.
- The requirements line of the README names the UE4SS build by what its log prints; add where players get it.

## 8. Installing on a player's PC

Not part of the mod (scripts live next to the packages). The pattern that has worked:

- Only while the game is closed; refuse otherwise. Never start the game yourself.
- Verify the package against its manifest; record hashes of the whole Mods folder and of the save folder first.
- Backup folder with the replaced files and a rollback script; install; verify against the manifest; then prove
  that nothing else changed (other mods, saves, UE4SS itself, `mods.txt`).
- Keep what the player owns: settings files, progress files, `enabled.txt` (a mod manager may own it - never add
  or remove it in an update). Since 0.2.2 the mod writes files of its own next to them at run time, which are the
  player's too and never part of a package: `config.lua.bak` / `.tmp` next to a module's `config.lua`,
  `profile_<n>.lua.bak` / `.tmp` / `.bad` in `modules/repopulate/Scripts/state/`, and `session-*.ops` /
  `session-*.report.txt` in `Scripts/diagnostics/`.
- The loader does not load a module while the same thing is installed and enabled as a separate mod (the
  `separate` names in `Scripts/core/modules.lua`: our own `G1R_Repopulate` and `NPCMarkers`, and six mods of other
  authors). To hand a job to this mod the installer retires that mod's folder - and carries its settings over into
  the module's `config.lua`, through the module's `schema.lua` - only after this mod is in place and verified: copy to the backup folder, compare file by file, rename (fails as a whole
  while a file is open), remove - what makes it a mod (`enabled.txt`, `Scripts/main.lua`) first. Their settings,
  progress files and the settings app are copied into `modules/` before that. The rollback script puts the folders
  back. `mods.txt` is left alone: UE4SS skips a line whose folder is missing (seen in the log: the lines of the
  debug mods that are not installed), and the line is needed again after a rollback.
- A desktop shortcut that points into a retired folder is pointed to the copy (and restored by the rollback).

## 9. Before you say "it works"

- [ ] `python dev/run_tests.py` passes, and the new check failed when you broke the code on purpose
      (`python dev/tools/mutate.py <file> --suite <suite> --accept dev/tests/<suite>/mutations_accepted.txt` for a
      file with tests of its own: no survivor without a written reason).
- [ ] No new search among all objects, and no object of the game kept from one update to the next (rules 4, 9).
- [ ] `python dev/tools/lint.py` has no warning you cannot explain; `--lookups` shows no new unlisted search.
- [ ] Nothing new is read per tick from the game that was not read before (count it in the harness).
- [ ] Every new assumption is a line in `dev/FACTS.md` with its real status, and has a note key.
- [ ] What you tell the player says what was tested offline and what nobody has seen in the game yet.
