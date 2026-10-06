# Facts: module othermods

Two numbers of other mods that the settings app writes into those mods' own files. Sources: the two mods' files on
the PC (read only, 2026-10-06). Nothing of this module has run in the game yet. Facts about other authors' mods are
used; nothing of their code or texts is in the megamod.

| # | What | Where | Status | Note key |
|---|---|---|---|---|
| OM1 | FocusNearbyPickups (a child mod of PLuaModLoader: `PLuaModLoader/Scripts/Mods/FocusNearbyPickups/`) reads `FocusNearbyPickups.ini` once when the game starts, `key=value` lines; `maxRadius=1000.0` is how far it highlights things, in Unreal units (100 = 1 m; 0 = no limit). The mod only reads the file (`io.open(path, "r")`). | `main.lua` `LINES`; app `OtherMods.cs` | SOURCE (the files on the PC) | `othermods.highlight_file` |
| OM2 | G1R_AutoPickUpItemNative (a native mod) reads `G1R_AutoPickUpItemNative.ini`, `Key=Value` lines with `;` comments; `AreaLootingRadius=500` is how far it picks items up (100 is about one metre, by the file's own comment). Whether it ever writes the file: UNKNOWN (native code). | `main.lua` `LINES`; app `OtherMods.cs` | SOURCE (the file on the PC) | `othermods.loot_file` |
| OM3 | Both files are plain ASCII with LF line ends on the PC. The settings app changes exactly the value of the one line (indentation and the rest of the file byte for byte as they were), keeps the first version of a file it changes as `<file>.before-G1R_MegaMod`, and writes only while the game is closed. A switch that is off leaves the file alone. | app `OtherMods.cs` | OFFLINE | - |

## Diagnostics notes

| Note key | Expected | If it differs / what it settles |
|---|---|---|
| `othermods.highlight_file` | the number in the file (`1000.0` as the mod ships it) else `not readable` (detail: why) | OM1: what FocusNearbyPickups reads at the next start |
| `othermods.loot_file` | the number in the file (`500` as the mod ships it) else `not readable` | OM2 |
