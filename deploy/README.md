# deploy

The installer, its independent audit and their rehearsal, as used on the PC the mod was made for (Windows Python).

| File | What it does |
|---|---|
| `install_megamod.py` | installs or updates G1R_MegaMod from a `-dev` package (and the settings app); retires the mods of other authors whose jobs a module took over and carries their settings over; keeps every replaced file in a backup folder with a rollback script; refuses while the game runs |
| `audit_megamod.py` | checks the PC afterwards without the installer's logic: Mods folder, saves (hashes), UE4SS.dll, the settings app, the desktop shortcut; last line `AUDIT OK` |
| `sim_megamod.py` | builds a mock of the PC below a temp folder and runs installer, rollback and audit against it; with `--pc-mods` / `--pc-backup` a rehearsal on copies of the real folders |

The PC's places are in `deploy_settings.json` next to the scripts (not in the repository); copy
`deploy_settings.example.json` and fill it in:

| Key | What |
|---|---|
| `game` | the Gothic 1 Remake folder (the one with `G1R` in it) |
| `saves` | the game's save folder (`...\AppData\Local\G1R\Saved\SaveGames`) |
| `project` | the work folder: `megamod\` with the packages, and where the backup folders go |
| `shortcut` | the desktop shortcut of the settings app |

`python install_megamod.py --check` shows the plan and changes nothing; the run without `--check` follows only with
the game closed, then `python audit_megamod.py`.
