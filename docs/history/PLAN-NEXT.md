> 2026-10-05 20:55: handed over to Claude Code. The plan to work from is now `HANDOFF.md` in
> `<proj>\claude-code-handoff-20261005\` (with `CLAUDE.md`). This file stays as history.

# G1R_MegaMod - working plan (handoff 2026-10-05 20:40 MDT; P0 DONE - installed 0.2.3)

Read this first, top to bottom. It replaces the running log in `PLAN.md` as the thing to work from; `PLAN.md`
stays as history. Work the queue in section 3 in order. Do not start a later item while an earlier one has a step
you can do. Keep this file current: when a step is done, change its line here (one line), not a new log entry.

## 0. Rules that bind (The player's instructions, verbatim where quoted)

- "Do not open game" / never launch the game. Installing anything into the game folder happens only with the game
  closed (check `Get-Process G1R*` first). Never deploy, reload scripts or attach debugging while he may be playing.
- "Keep the existing UE4SS AngelScript Fix 0.4 loader" (`UE4SS.dll` sha256 `e1909f981e3f4c1dd603e9fc4e133fa679168e5d13d6d280b1dd79ed8f1dcaa3`).
  "Avoid the manager's generic Install / Update UE4SS, which can replace the required fork."
- "Keep backups, compare save hashes, and respect the instruction not to launch the game. Do not restore whole older
  backup archives without review." Saves are only ever read (hash compare). `mods.txt` / `mods.json` are never
  written. `enabled.txt` of other mods is never added / replaced / deleted. Other authors' mods: facts may be taken,
  code / texts / pictures / data are never copied.
- Preserve his play state: 10x XP, Wait on Y = 30 min, HUDMap top-right / north-up / scale 1.0625 / offsets 25,
  native Auto Pickup, FocusNearbyPickups' installed repair, all requested mod features.
- No Agent / subagent tool calls (he rejected them). "Always allow running command" was granted.
- Style: curt, clean, pragmatic. No reaffirming language, no fluff, no extra confirmations. Any UI theming:
  Windows XP style (settings app).
- Code / docs style of the mod: plain words, say where a fact comes from (IN-GAME / DISASM / SOURCE / OFFLINE /
  UNKNOWN), every feature is a setting, every call into the game guarded, a fallback for every engine way, and a
  diagnostics note that tells which way was used.

## 1. Where things are

| | |
|---|---|
| Mod source | `G1R_MegaMod/` (version in `Scripts/core/version.lua`, `CHANGELOG.txt`, `README.txt`) |
| Tests | `python3 dev/run_tests.py` (all: 21 suites + lint); `--only <suite>`; `SHOWOK=1 lua5.4 dev/tests/<suite>/harness.lua` |
| Mutation tool | `python3 dev/tools/mutate.py <file> --suite a,b,c [--only N,N-M] [--accept FILE] --quiet` |
| Config from schema | `lua5.4 dev/tools/gen_config.lua <module>` (`--check` to compare) |
| Release | `python3 dev/tools/build_release.py --check`, then with `--forbid-file release-forbid.txt --foreign <zip>`x5 (`<scratchpad>/foreign/`); outputs to `dev/out/dist/` |
| Research | `research/README.md` (game scripts `<as-src>/`, `usmap.py`, `research/re-tools/params.py <Function>`, `binds_strings.txt`), new notes in `research/q3/` |
| Settings app | `app/src/` (C# .NET 8 WinForms, 2.0.0 written); Linux build: `export PATH=<cloud home>/dotnet:$PATH DOTNET_ROOT=<cloud home>/dotnet`; Wine runner `<scratchpad>/wine-run.sh selftest|uitest|snapshot|smallest`; file tests `app/filetests/` (`--selftest`, `--live <megamod>`, `--presets`) |
| Scratchpad | `/tmp/a67a5710-d5a5-5b0e-aa57-faa11845e008/scratchpad/` (`mut/` mutation results, `foreign/`, `wineprefix/`) |
| PC (Windows-MCP PowerShell) | game `<game>\G1R\Binaries\Win64\ue4ss\`; project `<proj>\` (`megamod\` holds packages, installer, evidence) |
| PC file transfer | `device_stage_files` (PC -> here), `device_commit_files` (here -> PC). TRAP: commit changed files to a NEW folder name and compare SHA-256 on the PC; the device bridge may serve a stale copy under an old name. |
| Installer | `megamod\install_megamod.py` (`--check` first; `--settings-app <exe>` to install the app), `audit_megamod.py`, `sim_megamod.py`; sources in `deploy/` |
| Installed now | megamod **0.2.3** (installed 20:32, package `G1R_MegaMod-0.2.3-dev.zip` sha256 `ce2f0b1d...`, AUDIT OK 29), settings app **1.5.0**, backup `megamod-install-backup-20261005-203211\` with rollback script (0.2.2's: `...-181741\`) |
| Notes for the player | `<proj>/G1R_MegaMod-0.2.3-notes.md` (also in the PC project root); the next one: `G1R_MegaMod-0.3.0-notes.md` (app 2.0.0 gets a section in a notes file of its own or in 0.3.0's) |

Conventions: a tree change that alters installed code = a new version (0.2.3 ...). Package -> `sim_megamod.py` on Linux
-> rehearsal on copies on the PC (`megamod\rehearsal-<v>\`) -> install with the game closed -> `audit_megamod.py`
-> notes file -> `PLAN-NEXT.md` line.

## 2. State right now

- 0.2.2's first session: 18:24:47 - 19:47, 82 min, no crash, 0 errors, every new way in use (details in
  `G1R_MegaMod-0.2.3-notes.md`, section "Your 0.2.2 session"). Files: PC `megamod\first-session-0.2.2-20261005-1824\end\`
  (UE4SS.log, session log, report, .ops, profile_0 after); staged copies of the 19:47 state under
  `<proj>/megamod/first-session-0.2.2-20261005-1824/at-1945/`.
- **0.2.3 installed 20:32** (game closed, not started): module `mount` + repopulate 1.4.1 (util.lua walk-wait fix)
  + suites `repopulate_util` (149), `mount` (83), `main_cases.lua`; 22 suites, 6752 checks, lint clean; mutation:
  util.lua 0 unexplained (32 accepted), mount/main.lua 0 unexplained (39 accepted). Rehearsal 47 ALL OK, install
  10 added / 10 replaced / 411 same / 12 kept / 17 left alone, AUDIT OK (29). Settings app table knows `mount`
  (Hero > Mount); `filetests --live` 12 ok, PRESETS identical. The source tree == the installed 0.2.3 except
  nothing (all committed into the package).
- Left from the mutation work: main.lua round 2 has **19 survivors** (`<scratchpad>/mut/main_round2.txt`), not
  looked at (P0.2 below, now the only open P0 step).
- Settings app 2.0.0: fully written and verified on Linux (filetests 121 ok, `--live` 12 ok, PRESETS identical;
  under Wine: selftest 121, uitest 54, pictures of all 24 tabs reviewed at 1140x780 and 1040x690). Not built, not
  tested, not installed on the PC. Plan file `/root/.claude/plans/ethereal-herding-bee.md`; layout "Category pane +
  tabs". The megamod README still describes the 1.5.0 pages. The real layout now has 25 tabs (Hero > Mount, 5 settings).
- Task list (TaskList tool) mirrors this plan: #94 done, #93 = P0.2, #67/#68 = P1, #80-#92 = P2.

## 3. The queue, in order

### P0 - DONE 20:32: megamod 0.2.3 (mount module) installed. Leftover (task #93):

main.lua survivors: read `<scratchpad>/mut/main_round2.txt` (19), add checks to `dev/tests/repopulate/main_cases.lua`
or accept lines in a new `dev/tests/repopulate/mutations_accepted.txt` (format: see `dev/tests/mount/mutations_accepted.txt`);
rerun `python3 dev/tools/mutate.py modules/repopulate/Scripts/main.lua --suite repopulate,repopulate_engine --only <the 19>
--accept dev/tests/repopulate/mutations_accepted.txt` -> 0 unexplained. Tests only: no new package needed unless a
real defect shows (then 0.2.4 the P0.5-P0.7 way: build with --forbid-file + --foreign x5, sim on Linux, commit to a NEW
PC folder + SHA-256, rehearsal `sim_megamod.py --part update --pc-mods <real Mods> --pc-backup <latest backup>` in
`megamod\rehearsal-<v>\`, install with the game closed, audit, notes).

The mount analysis, facts and design: `dev/facts/mount.md`, `modules/mount/README.txt`, `research/q3/` has no file of
its own (the facts file is the record). Open to the player: the two questions in section 5.

### P1 - settings app 2.0.0 on the PC  (tasks #67, #68; only with the game closed)

All source work is done (section 2). Steps, in this order, nothing else between them:
1. Copy `app/src/*` + the embedded `MapPinsSchema.lua` / `MapPinsConfig.lua` to the PC as
   `repopulate-settings-2.0.0\` (new folder name; SHA-256 compare), `dotnet publish -c Release -r win-x64
   --self-contained false` with the real csproj (dotnet 9.0.317 is on the PC; the project targets net8 - use
   `-p:EnableWindowsTargeting=true` only on Linux).
2. On the PC: `--selftest` (121), `--uitest` (54), `--snapshot <dir>` on the test megamod and on the installed one;
   stage the pictures here and look at every one (24 tabs + find + unsaved); fix what is off, rebuild. Search the exe
   for personal paths (`Select-String "The player"`). Not auto-tested: Ctrl+F / Enter / Escape in the Find box - say so
   in the notes.
3. Install with `megamod\install_megamod.py --check --settings-app <exe>` then for real: megamod 0 added / 0
   replaced, old app into a new backup folder with rollback script; audit; his settings files byte-identical;
   UE4SS.dll hash. Desktop shortcut "G1R_MegaMod Settings" still valid.
4. Notes section "settings app 2.0.0" in the current notes file; megamod `README.txt` page list -> the 2.0 layout
   (can ride with 0.3.0 if that is the next package).

### P2 - megamod 0.3.0  (tasks #80-#92; one package, built feature by feature, each with tests before the next)

Order inside 0.3.0 (hardening first because every later feature rides on it; then the user-requested features in
the order he asked): #80 -> #81/#82 -> #84 -> #86 -> #88 -> #90 -> #92. Feasibility is DONE for all of them:
`research/q3/feasibility-0.3.0.md` (skip intro, key list, Gothic font, distances), `research/q3/spell-timers.md`
(timers), and the earlier movement findings (tasks #71/#72 completed; see `PLAN.md` 2026-10-05 entries). Read the
research file before starting a feature; do not redo it.

- Before anything else in 0.3.0: read the first 0.2.3 session's log for the `[G1R_Mount] whistle N` lines and the
  notes `mount.*`; upgrade `dev/facts/mount.md` statuses; if a call failed in the game, fix the module first.
- **#80 hardening leftovers** (from the the other agent review package `megamod\review-20261005\`): containers by key,
  engine lookups, creatures, items, wait, module start guard. Facts statuses to upgrade from the 0.2.2 session
  evidence: U18, U19, R20-R23, K12-K15 (OFFLINE -> IN-GAME, cite the 19:47 report). Also: magic's "look N (check)"
  line every minute floods the recorder's last-120 window - record it only when something changed.
- **#81/#82 module `movement`**: swimming speed multiplier; mounted scavenger speed multiplier (the 0.3.0 spec is
  in `PLAN.md` under the Q3 queue entry; `LocomotionConfig_Scavenger_Adult_Rideable.as` and the hero's swim
  locomotion config are the data objects; same write pattern as `magic`).
- **#84 skip intro**: the player: "Add into the list an option in the megamod to skip the intro". Default off. Way 1
  (`%LOCALAPPDATA%\G1R\Saved\Config\Windows\Game.ini` override of `MoviePlayerSettings`: `!StartupMovies=ClearArray`,
  `bWaitForMoviesToComplete=False`) first - read the packed `DefaultGame.ini` from the pak on the PC to see which
  list holds the four logos; way 2 (moving the .bk2 files into the mod folder and back) only if way 1 cannot work.
  Second toggle for `G1R_Intro.bk2` (the new-game film). Effective at the next game start; the installer / app
  writes the ini, the mod itself does not touch game files.
- **#86 key list**: the player: "a spot in the menu in the top left when you hit escape and you're in the pause menu where
  it shows you all of your modded keybinds and what they do, or a keybind that reveals that list. Have it be fairly
  unobtrusive". `NotifyOnNewObject` on `/Script/G1R.PauseMenuWidget` (+ `bIsActive`), own widget top left (kit's
  widget code), optional key. Keys: the megamod's own from the kit (needs a one-line text per binding from each
  module), other mods' from their files (table in the feasibility file; read the PC's files at list time).
- **#88 Gothic font**: the player: "change all the in-game mod text to the gothic text, or as close as you can get".
  Font objects `/Game/UI/Fonts/Boucherie-Block_Font` (blackletter) / `NotoSerif-Regular_Font`; read the text block
  of `W_DisplayName_GothicFont_C` in the first session to confirm which the game calls "Gothic"; set `Font.FontObject`
  in the kit's note box, markers' names, the key list, the timers; fallback = today's font.
- **#90 highlight / loot distance**: the player: "allow changing of the distance of auto highlight and auto loot". Two
  numbers (`FocusNearbyPickups.ini` `maxRadius`, `G1R_AutoPickUpItemNative.ini` `AreaLootingRadius`) on a settings
  app page "Other mods" + in-game menu; the installer/app writes exactly that one line per file (backup kept);
  effective at the next game start; never while the game runs.
- **#92 timers**: the player: "On you: heal / mana over time from food and potions, alcohol, swampweed, burning (10 s),
  frozen (5-8 s), electrified, wind (5 s), slowed. - all would be good, as well as any other over times that you could
  think of. Toggles in the menu. Display very small in bottom left of screen, or over health bar". Module `timers`:
  Light (engine timer `K2_GetTimerRemainingTimeHandle` on `ALightSpellVisual.TaskTimer`, else own count from
  `State.Spell.Light` + `LightSpellConfig.m_LifeSpan`), GAS effects via `GetActiveEffectsWithAllTags` +
  `GetActiveGameplayEffectRemainingDuration` (UNKNOWN in game: first session decides, fallback = those timers off),
  alcohol / swampweed = level / depletion rate (attribute reads), knocked out, sleep / fear / charm on the hero,
  regen's own wait; check hunger / thirst / breath. One toggle per timer + master; very small text; position
  "bottom left" (default) / "above the health bar" (`PlayerBarHealthMana` widget geometry; fallback bottom left).
- Package 0.3.0 the same way as P0.5-P0.7; the settings app gets the new pages (NavModel `Known`); notes file.

### P3 - afterwards

- Facts / docs hygiene after each in-game session: upgrade statuses with the evidence, keep `research/README.md` current.
- `megamod-dev-archive-<version>.zip` for the PC after each release (sources + tests + research, no game files).

## 4. Working method (what keeps this efficient)

- One queue item at a time; inside it, the numbered steps in order. Before a PC step: `Get-Process G1R*`.
- Read before writing: the module you touch, its facts file, its harness. Reuse the kit (`Scripts/core/kit.lua`
  exports: findOnce / findClass / findDefault / subsystem / controller / playerState / pawn / paused / gameSeconds /
  attribute reads & writes / bindKey / notify / hookOnce / keepAlive / onWorldChange) - do not re-implement searches.
- Every game call: `KIT.try` / `KIT.call` / `KIT.get`, validity checked, a once-logged reason when it fails, a
  diagnostics note that says which way worked. Nothing kept across updates that the game can free (U17).
- Tests first for anything that changes installed code; `python3 dev/run_tests.py` must be all green before a
  package; mutation check for new or rewritten files (`--suite <its suite>`, accept file with reasons).
- Package -> simulate -> rehearse -> install (game closed) -> audit -> notes. Never skip the audit.
- Report to the player in a few lines when a queue item is done or when a decision is his; no progress chatter.
  Open questions go into section 5, not into repeated messages.
- Record state here (section 2 + the step lines), not in chat, so a context break costs nothing.

## 5. Open questions for the player (asked once; do not re-ask, act on the answer when it comes)

1. Scavenger: when it fails, does it stand still or run away from you? Does a save -> load fix it, or only a full
   restart? (Decides whether "full" or "safe" should be the default of the auto fix.)
2. Skip intro: the logos at game start (default meaning), or also the film of a new game? (Both will be toggles;
   default: logos only.)
3. Timers position: "bottom left" is the default; "above the health bar" is the setting - fine?
