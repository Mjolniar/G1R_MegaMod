# Facts: module xp

| # | What | Where | Status | Note key |
|---|---|---|---|---|
| X1 | The hero's experience is the attribute `Experience` (a `GameplayAttributeData`: `BaseValue`, `CurrentValue`) of the `AttributeSet_LevelProgression` object inside his player state; `Level` sits next to it. | `main.lua` `tick` | IN-GAME (another author's mod, EXPModifier 1.0.4, read it that way on this installation: UE4SS.log of 2026-10-01, "gained 30 -> +120 total (x4.00); Experience now 6822") | `xp.readable` |
| X2 | The way to that object: the kit's `attributeSet("LevelProgression")` (facts K2). | `main.lua` `tick` | IN-GAME (`xp.set_found_by = player state`, see below) | `xp.set_found_by` |
| X3 | Writing `BaseValue` and `CurrentValue` changes the hero's experience for good; the game saves it. | `main.lua` `tick` (`KIT.writeAttribute`) | IN-GAME (same log: every later total builds on the written one) | `xp.write` |
| X4 | The game compares experience and level only when experience arrives through its own effect (`GiveExperience` -> `GE_IncreaseExperience` -> the attribute set's native code after the effect: experience >= `ExperienceRequiredForLevel(level + 1)` x the difficulty's multiplier). A direct write does not run that check: a level the bonus makes possible comes with the next gain. | header of `main.lua` | DISASM (game executable, the reader of the multiplier at `+0x5b669f7`) + SOURCE (`WorldDefinition.as`: level x 250 x (level + 1)) | - |
| X5 | `m_ExperienceMultiplier` of the progression difficulty (Easy 0.8, Hard 1.2; `GetLevelUpXPMultiplier`) scales the experience needed per level, not the experience gained. It is not used here: changing it would move the thresholds of a running game. | - | DISASM (both readers multiply `ExperienceRequiredForLevel` with it) | - |
| X6 | A loaded save can fill the attributes in after the hero's objects exist: what the number does in the first seconds (`SettleSeconds`, 10) after the attributes were found, or after the player controller's `ClientRestart`, is not a gain. | `main.lua` `tick`, `rest` | IN-GAME that the number moves in those seconds (`xp.changed_while_settling = yes (298792 -> 298842)`, five such changes in the session below; whether a late fill-in or a real gain is not told apart - the wait costs at most the bonus of gains in those seconds); `/Script/Engine.PlayerController:ClientRestart` can be hooked: IN-GAME (the module's own hook was called 19 times in that session) | `xp.changed_while_settling` |
| X7 | UE4SS shared variables are one store for all Lua mods (K10). EXPModifier announces every value it writes in `EXPModifier_lastWrite`, takes a value announced there for a write, not a gain, and registers with the mod menu under the name `EXPModifier`. The module announces its writes the same way; when it sees a foreign announcement or that name in `SMM:index` it adds nothing for the rest of the run. | `main.lua` `otherAtWork`, `ledgerSet`, `standDown` | SOURCE (the script of EXPModifier 1.0.4; UE4SS `LuaModRef.cpp`); OFFLINE | `xp.other_multiplier` |
| X8 | The loader does not load the module while a mod folder `EXPModifier` with `Scripts/main.lua` (or `scripts/`) is enabled. A copy of that mod under another folder name is only caught by X7. | `Scripts/core/modules.lua` | OFFLINE | - |

## Seen in the game

megamod 0.2.1, session of 2026-10-04 21:19 - 23:39 (140 minutes, report of 23:39; 0 errors), multiplier x10: `xp.readable = yes`, `xp.set_found_by = player state`, `xp.write = ok`,
`xp.other_multiplier = none`; status "gains multiplied: 70 (+121590 experience in total); last: 200 -> 2000",
"experience 298842, level 38". That settles X1 - X3 for this module itself. Not seen: X7 with another multiplier
at work (there was none).

## Diagnostics notes

| Note key | Expected | If it differs / what it settles |
|---|---|---|
| `xp.set_found_by` | `player state` else `scan` | K2: scan = the player state's own attribute list was not usable; the attributes are found by a search among all objects |
| `xp.readable` | `yes` | X1: no = the experience could not be read from the attributes (the detail names the object) |
| `xp.changed_while_settling` | `no` else `yes` | X6: yes = the number moved in the seconds after the hero was found (the detail says from where to where): the wait is doing its job |
| `xp.write` | `ok` | X3: failed = experience cannot be written this way; gains stay as the game gives them |
| `xp.other_multiplier` | `none` else `EXPModifier` | X7: EXPModifier = another experience multiplier runs in the same game and this module stands down (the detail says how it was recognised) |
