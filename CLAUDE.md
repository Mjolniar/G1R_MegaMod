# G1R_MegaMod - rules for Claude Code (binding)

Read this file, then `HANDOFF.md` (state, next step, queue). Work the queue in order. The instructions for the
player's PC - the game folder, WSL, installs - are `docs/CLAUDE-local-pc.md`; in both files `<h>` is the work folder
on that PC, `<proj>` its project folder, `<game>` the game folder, `<saves>`, `<desktop>`, `<home>` the player's.

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
- This repository is public: no file may hold the player's name, e-mail, user name or the paths of his PC (write "the
  player" and the placeholders above); never the game's files or data (its scripts, usmap, executable, pak contents,
  fonts, textures) and nothing of other authors' mods. Commits use the GitHub no-reply address of the owner.

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
- A change of installed code = a new version (`Scripts/core/version.lua`, `CHANGELOG.txt`, `README.txt`). Packages,
  rehearsal, install and audit happen on the player's PC (`docs/CLAUDE-local-pc.md`, section 2 and 4 there).

## 3. In the cloud (this repository on Linux)

- What can be done: the mod's code and docs, its offline tests and mutation checks, the settings app's source (C#;
  the program builds and runs only on Windows), the facts from what is in the repository. App changes:
  `python3 app/tools/linux_check.py` (needs `sudo apt-get install -y dotnet-sdk-8.0`) builds and runs the app's file
  tests (`--selftest`, `--live`) and compiles the whole app; expected `LINUX CHECK OK` (the self test's start-screen
  check fails on its stand-in value and is not counted).
- What cannot: anything with the game or the player's PC - install, audit, rehearsal, the app's UI tests, reading
  the game's scripts / usmap / executable / paks (not in the repository), release packages (they need the list of
  forbidden words and the other authors' packages, both kept on the PC). Write such steps into `HANDOFF.md` for a
  local session.
- Tests: `sudo apt-get install -y lua5.4 python3 zip unzip`, then `python3 G1R_MegaMod/dev/run_tests.py` from a path
  without spaces or apostrophes (the harnesses pass paths unquoted to the shell). Expected now:
  `ALL PASSED: 27 suite(s), 7470 check(s) ok, 0 failed`, lint 187 files 0 errors. One suite:
  `--only <suite>`; mutation: `python3 G1R_MegaMod/dev/tools/mutate.py <file> --suite <suite> --accept
  G1R_MegaMod/dev/tests/<suite>/mutations_accepted.txt --quiet` (run from `G1R_MegaMod/`).
- `build_release.py --check` works here; it checks what would go into a package.
