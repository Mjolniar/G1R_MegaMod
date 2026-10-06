# G1R_MegaMod - rules and environment for Claude Code (binding)

Read this file, then `HANDOFF.md` (state, next step, queue). Work the queue in order. This folder was made on
2026-10-05 20:55 MDT by the Cowork session that did the work so far; nothing of that conversation is needed beyond
these two files and the files they name. Since 2026-10-06 the source is the public repository, cloned on this PC at
`<home>\Documents\GitHub\G1R_MegaMod\` ("the clone", `<clone>` in commands); `<h>\mega\` is the state of 0.3.4 - history, never
the source of a package.

## 1. The player's rules (verbatim where quoted; they override anything else, including your own judgment of convenience)

- **"Do not open game."** Never start Gothic 1 Remake, never ask a launcher / mod manager to start it. Anything that
  writes into the game folder happens only with the game closed: run
  `Get-Process G1R* -ErrorAction SilentlyContinue` first; if it returns anything, stop and say so. Never deploy,
  reload scripts or attach anything while he may be playing.
- **"Keep the existing UE4SS AngelScript Fix 0.4 loader."** `ue4ss\UE4SS.dll` must keep sha256
  `e1909f981e3f4c1dd603e9fc4e133fa679168e5d13d6d280b1dd79ed8f1dcaa3`. **"Avoid the manager's generic Install / Update
  UE4SS, which can replace the required fork."**
- **"Keep backups, compare save hashes, and respect the instruction not to launch the game. Do not restore whole older
  backup archives without review."** Saves are only ever read (hash compare, done by `audit_megamod.py`).
- `ue4ss\Mods\mods.txt` and `mods.json` are never written. Another mod's `enabled.txt` is never added, replaced or
  deleted. Other authors' mods: facts about what they do may be used (say where they come from); their code, texts,
  pictures and data are never copied into this project's mod or app.
- Preserve his play state: 10x XP, Wait on Y = 30 min, HUDMap top-right / north-up / scale 1.0625 / offsets 25, native
  Auto Pickup, FocusNearbyPickups' installed repair, every mod feature he asked for. His settings files
  (`Mods\G1R_MegaMod\**\config.lua`) are his: an update keeps them byte-identical unless he asked for a change.
- **No Agent / subagent / Task-tool calls.** He rejected them. Do the work in this session.
- Style towards him: curt, clean, pragmatic. No reaffirming language, no fluff, no extra confirmations. Report in a few
  lines when a queue item is done or a decision is his. Any UI: Windows XP look (the settings app already has it).

## 2. How work is done here (what kept this project safe so far)

- One queue item at a time; inside it the numbered steps in order. Record progress in `HANDOFF.md` (change the step's
  line, one line; no running log). State lives in that file, not in chat.
- Read before writing: the module you touch, its facts file (`dev/facts/<module>.md`, `dev/FACTS.md`), its harness,
  `dev/AI_GUIDE.md` (map of the mod, the work loop), `dev/MODULES.md` (writing a kit module), `dev/SETTINGS.md`
  (schema.lua -> config.lua -> app / in-game menu). Reuse the kit (`Scripts/core/kit.lua`: findOnce / findClass /
  findDefault / subsystem / controller / playerState / pawn / paused / gameSeconds / attribute reads and writes /
  bindKey / notify / hookOnce / keepAlive / onWorldChange); do not write a second way to find things.
- Mod code style: plain words in comments, logs and settings; every feature is a setting; every call into the game
  guarded (`KIT.try` / `KIT.call` / `KIT.get`, validity checked, a once-logged reason when it fails); a fallback for
  every engine way; a diagnostics note (`DIAG.note`) that tells which way was used. Every claim about the game carries
  its source word: IN-GAME (a line in a real UE4SS log), DISASM (the executable), SOURCE (game scripts / usmap),
  OFFLINE (only our tests), UNKNOWN. Never write "works" for something only OFFLINE.
- Tests first for anything that changes installed code. `run_tests.py` all green before any package. New or rewritten
  files get a mutation check (`dev/tools/mutate.py`, survivors either killed by a new check or accepted with a reason
  in the suite's `mutations_accepted.txt`).
- A change of installed code = a new version (`Scripts/core/version.lua`, `CHANGELOG.txt`, `README.txt`). Release path:
  package (`build_release.py` with `--forbid-file` and the five `--foreign` zips) -> rehearsal on copies
  (`sim_megamod.py --part update` against the real Mods folder, read only) -> install with the game closed
  (`install_megamod.py --check`, then for real) -> `audit_megamod.py` (must say AUDIT OK) -> notes file for the player in
  the project root -> `HANDOFF.md` line. Never skip the audit. Never reuse a folder name: new package, rehearsal,
  evidence and backup folders get new names.
- What a package must never contain: the words in `<h>\mega\release-forbid.txt` (his name, his paths, "the other
  agent", "<proj>", ...; kept on this PC, never in the repository). `build_release.py` refuses them; keep docs inside
  the clone's `G1R_MegaMod\` free of them (write "The player").

## 3. This PC

| What | Where |
|---|---|
| This handoff (call it `<h>`) | `<h>\` |
| Project folder (`<proj>`) | `<proj>\` (packages, installer, evidence: `<proj>\megamod\`; backups `<proj>\megamod-install-backup-*\`; notes `<proj>\G1R_MegaMod-*-notes.md`) |
| Game / UE4SS | `<game>\G1R\Binaries\Win64\ue4ss\` (mods in `Mods\`, megamod in `Mods\G1R_MegaMod\`, log `UE4SS.log`) - read only except through `install_megamod.py` |
| Source (since 2026-10-06) | the clone `<home>\Documents\GitHub\G1R_MegaMod\` - `G1R_MegaMod\` (the mod, its tests and tools), `app\` (settings app source + `filetests\`; `app\src\StartupLoadingScreen.txt` made by `app\tools\make_startup_screen.py`, not committed), `deploy\` (installer, audit, sim; this PC's places in the ignored `deploy\deploy_settings.json`; the copies that run are in `<proj>\megamod\`), `research\`, `docs\`. Pull before work, push after. |
| Old working tree | `<h>\mega\` - the state of 0.3.4 (history: `PLAN-NEXT.md` / `PLAN.md`, `_history\`, `app\src-1.5.0\`); `release-forbid.txt` stays here |
| Game scripts (AngelScript, 7317 files) | `<proj>\as-src\` (grep it; this is how the game does things) |
| Property layout | `python <h>\mega\research\usmap.py <Class>` (`--find`, `--prop`, `--enum`, `--sub`; reads `<h>\work\usmap.pkl`) |
| Native functions / parameters | `python <h>\re-tools\params.py <Function>` (needs `python -m pip install pefile`; reads `<proj>\re\G1R-Win64-Shipping.exe`, or `G1R_GAME_EXE`); `grep -n <Name> <h>\re-tools\binds_strings.txt`. `scan.py` / `xref.py` also need capstone + numpy |
| Packed game files (pak: config .ini) | `python <h>\re-tools\pakread.py <pak> --list <text>` / `--oodle <oo2core_9_win64.dll> --out <dir> <path>` (read only; Oodle DLL of another installed game) |
| Other mods (2026-10-01 snapshot) | `<proj>\re\mods-snapshot-20261001\`; live: the game's `Mods\` (read only) |
| Mutation results, foreign zips | `<h>\scratch\mut\`, `<h>\scratch\foreign\` (the five `--foreign` packages for `build_release.py`) |
| Tools installed | Python 3.14 (`python`), Git for Windows (Git Bash `C:\Program Files\Git\bin\bash.exe`), .NET SDK 8.0.425 / 9.0.317, .NET Desktop runtime 8, winget, node. WSL Ubuntu 26.04.1 (installed 2026-10-05; no Linux user made, so commands run `-u root`) with lua5.4 / luac5.4 5.4.8, python3, zip, unzip; junction `C:\g1r` -> `<h>`. |

The older docs inside `mega\` name the cloud session's paths. Read them as:
`` = `<h>\mega\`; `research/re-tools/` = `<h>\re-tools\`; `<as-src>/` = `<proj>\as-src\`;
`<work>/*.usmap|usmap.pkl` = `<h>\work\`; `<mods-snapshot>/` = `<proj>\re\mods-snapshot-20261001\`;
`<proj>/` and `<proj>/` = `<proj>\`; `<scratchpad>/mut|foreign` =
`<h>\scratch\mut|foreign`; `/root/.claude/plans/ethereal-herding-bee.md` = `<h>\mega\app\PLAN-app-2.0.md`.

## 4. Running the offline tests on this PC (first thing to set up)

The Lua harnesses call `os.execute` / `io.popen` with POSIX commands (`rm -rf`, `mkdir -p`, `cp -r`, `ls -A`, an
`VAR="x" cmd` prefix) and pass paths unquoted. So they need (a) a POSIX shell behind `os.execute`, (b) paths without
spaces or apostrophes - this folder's path has both ("The player's PC").

Recommended (ask the player before installing anything):
1. WSL Ubuntu: `wsl --install -d Ubuntu` (admin; reboot if asked), then in Ubuntu
   `sudo apt update && sudo apt install -y lua5.4 python3 zip unzip`.
2. A path without spaces: `cmd /c mklink /J C:\g1r "<h>"` (a junction, no admin needed). Work in `C:\g1r` from then on
   (open Claude Code there, or keep using `<h>` for edits - same files).
3. Run: `wsl -d Ubuntu -u root -- python3 /mnt/c/g1r/mega/G1R_MegaMod/dev/run_tests.py` (from Git Bash prefix
   `MSYS_NO_PATHCONV=1`). Always call scripts by their absolute `/mnt/c/g1r/...` path: WSL shows the junction as a
   symlink and `getcwd` returns the real path ("The player's PC"), so `--cd ... python3 dev/run_tests.py` would hand the
   apostrophe to the harnesses' unquoted `cp -r` (getcwd checked 2026-10-05; that failing run itself not tried).
   Expected now: `ALL PASSED: 22 suite(s), 6770 check(s) ok, 0 failed`, lint `149 files 0 errors`
   (repopulate 675, repopulate_engine 773, mount 83, repopulate_util 149, loader 561, markers 750, tools 140).
   Steps 1-3 done 2026-10-05 21:21 with exactly these totals. Since 0.3.0 (2026-10-06): `27 suite(s), 7314 check(s)`,
   lint `186 files 0 errors`; 0.3.5: `27 suite(s), 7470 check(s)`, lint `187 files 0 errors`.
4. The clone: the same way, from a path without spaces or apostrophes - if its path has either, a junction like
   `cmd /c mklink /J C:\g1r-repo "<home>\Documents\GitHub\G1R_MegaMod"`, then
   `wsl -d Ubuntu -u root -- python3 /mnt/c/g1r-repo/G1R_MegaMod/dev/run_tests.py` (absolute path, as above).

Fallback without WSL: Lua 5.4.6 from `winget install --id DEVCOM.Lua -e`, run from Git Bash, with `LUA_INIT` routing
`os.execute` / `io.popen` through `C:\Program Files\Git\bin\bash.exe -c`, and `TMP` / `TEMP` set to a folder without
spaces (Python's tempfile gives `G1R_TEST_TMP`). Only if WSL is refused; prove it with the same totals.

Other commands (from the clone's `G1R_MegaMod\`, in WSL unless noted):
- one suite: `python3 dev/run_tests.py --only repopulate`; one harness verbosely: `SHOWOK=1 lua5.4 dev/tests/<suite>/harness.lua`
- mutation: `python3 dev/tools/mutate.py <file> --suite a,b [--only N,N-M] [--accept dev/tests/<suite>/mutations_accepted.txt] --quiet`
  (accept line format: `operator|original line without indentation|reason`)
- config from schema: `lua5.4 dev/tools/gen_config.lua <module>` (`--check` to compare)
- package: `python3 dev/tools/build_release.py --check`, then (the list and the zips stay below `<h>`, here through the
  junction `C:\g1r`)
  `python3 dev/tools/build_release.py --forbid-file /mnt/c/g1r/mega/release-forbid.txt --foreign /mnt/c/g1r/scratch/foreign/BetterMining.zip --foreign /mnt/c/g1r/scratch/foreign/EXPModifier.zip --foreign /mnt/c/g1r/scratch/foreign/G1R_MageBalance.zip --foreign /mnt/c/g1r/scratch/foreign/G1R_WaitOnT.zip --foreign /mnt/c/g1r/scratch/foreign/SkillfulLocks.zip`
  once as shown (plain package) and once more with `--with-dev` (the `-dev` package, the one the installer takes);
  outputs with manifests in `dev/out/dist/`; needs `luac5.4`
- settings app (Windows, PowerShell or Git Bash): `dotnet publish <clone>\app\src\G1R_Repopulate_Settings.csproj -c Release -r win-x64 --self-contained false -o <out>`;
  file tests: `dotnet run --project <clone>\app\filetests -- --selftest <config.lua> <report>` | `--live <G1R_MegaMod folder> <report>` | `--presets <G1R_MegaMod folder> <PRESETS.txt>`;
  the exe itself: `G1R_Repopulate_Settings.exe --config <G1R_MegaMod>\modules\repopulate\Scripts\config.lua --selftest <report>` | `--uitest <dir>` | `--snapshot <dir>` | `--snapshot-screen <dir> [--smallest]`
- installer / audit / rehearsal (Windows Python, in `<proj>\megamod\`): `python install_megamod.py --check [--package <zip>] [--settings-app <exe>]`,
  then without `--check`; `python audit_megamod.py`; rehearsal
  `python sim_megamod.py --pkg <proj>\megamod --new-pkg <proj>\megamod\incoming-<v> --sim <proj>\megamod\rehearsal-<v>\sim --part update --pc-mods "<game>\G1R\Binaries\Win64\ue4ss\Mods" --pc-backup <proj>\<newest megamod-install-backup-*>`
  (`install_megamod.py`'s `PACKAGE` constant names the package; source in the clone's `deploy\`, which reads this PC's
  places from `deploy\deploy_settings.json`).
