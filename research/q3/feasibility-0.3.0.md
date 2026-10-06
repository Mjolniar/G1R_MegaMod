# Megamod 0.3.0 - feasibility of the queued features (2026-10-05, from the game's scripts, the executable and the
# other mods' settings files; nothing was tried in the game)

## Skip the intro (#83 -> #84)

What plays (PC, `G1R\Content\Movies\`): `THQNordic_Logo.bk2`, `Alkimia_Logo.bk2`, `Game_Logo.bk2`, `V_LegalScreen.bk2`
(start of the game: about 20 s between the first map load hook and the menu world in the session of 2026-10-05
18:24), `LoopingEngineLoadScreen.bk2`, and `G1R_Intro.bk2` (1.1 GB, the film of a new game; script
`LoadingScreen/LoadingScreens/LoadingScreen_Intro.as`: skippable by holding Space / Esc / left mouse / pad A or B
for 1 s).

- The game uses the plugin AsyncLoadingScreen (`/Script/AsyncLoadingScreen.ALoadingScreenSettings`) and the
  engine's `/Script/MoviePlayer.MoviePlayerSettings` (`StartupMovies`, `bWaitForMoviesToComplete`,
  `bMoviesAreSkippable`; all three names are in the executable). Which of the two lists the logos are in stands in
  the game's packed `DefaultGame.ini` (not looked at yet: read it from the pak on the PC).
- A Lua mod cannot stop the logos reliably: they play while the game thread loads the first map, and the mod's
  calls run on that thread (`AsyncLoadingScreenLibrary:StopLoadingScreen()` exists, 0x1498c3fd0, but would only run
  once the thread is free again).
- Ways that do not depend on timing, both undone by the same switch:
  1. settings override in `%LOCALAPPDATA%\G1R\Saved\Config\Windows\Game.ini` (the folder holds only
     `GameUserSettings.ini` today): `[/Script/MoviePlayer.MoviePlayerSettings]` with `!StartupMovies=ClearArray`,
     `bWaitForMoviesToComplete=False`. Works if the logos are engine startup movies. No game file is touched.
  2. moving the logo files out of `Content\Movies\` into a folder of the megamod (and back). The engine skips a
     movie it cannot open. Touches game files; Steam's "verify files" puts them back.
- The film of a new game: second toggle; way 2 with `G1R_Intro.bk2` (or leave it: it is skippable by hand).
- Takes effect at the next game start. Can only be confirmed by a start of the game.

## List of modded keys (#85 -> #86)

- Pause menu: native widget class `/Script/G1R.PauseMenuWidget` (`GothicCommonActivatableWidget`, `bIsActive`).
  UE4SS announces new widgets of a class (`NotifyOnNewObject`, IN-GAME for the map screen), so the menu is known
  without a search; while it is active the list is drawn top left by a widget of the mod's own (the kind the notes
  use, IN-GAME).
- A key that shows the list: the kit's keys (IN-GAME: wait's Y).
- The megamod's own keys: known to the kit (who registered what) - needs a short text per key from the modules.
- Other mods' keys are settings in their own files (read as text, at the time the list is built):
  `SharedModMenu\Scripts\config.lua` (`menuKey = "F2"`, `keys = {...}`), `HUDMap\config.txt` (`hotkeyworld = N`,
  `hotkeyregion`, `hotkeymenu = Ctrl+N`), `PLuaModLoader\Scripts\Mods\FocusNearbyPickups\FocusNearbyPickups.ini`
  (`toggleKey=F6`, `corpsesKey`, `chestsKey`, `quickLootKey=V` when `quickLoot=true`),
  `G1R_AutoPickUpItemNative\G1R_AutoPickUpItemNative.ini` (`HoldHotkey=R`, `ToggleHotkey=X`, `..._Stealing`),
  `G1R_PutAwayTorchRedux\G1R_PutAwayTorchRedux.ini` (`Hotkey=T`: tap = draw / put away, hold 500 ms = drop).
  A mod that is not in this table is listed by name with "keys not known". (Values above: snapshot of 2026-10-01;
  the PC's files are read when the list is shown.)

## Gothic font (#87 -> #88)

- Fonts named in the game's scripts: `/Game/UI/Fonts/Boucherie-Block_Font.Boucherie-Block_Font` (headlines, book
  titles - the blackletter face) and `/Game/UI/Fonts/NotoSerif-Regular_Font.NotoSerif-Regular_Font` (running text;
  typeface entry `Default`). The HUD has a widget of its own for names "in the Gothic font":
  `/Game/UI/Crosshair/W_DisplayName_GothicFont.W_DisplayName_GothicFont_C` (`UHUDDisplayNameGothicFontController`);
  which font object its text block holds is read from it in the game (note for the first session).
- The kit already changes a text block's font from Lua (`text.Font` -> `Size`, `TypefaceFontName` ->
  `text:SetFont(font)`, IN-GAME). Setting `FontObject` to the game's font object is the same call with one more
  field: UNKNOWN in game. When the font cannot be found or set, the text stays as it is today.
- Texts of the mod: the note box (kit), the map pins' names and name lists (markers), the key list, the timers.

## Distance of auto highlight and auto loot (#89 -> #90)

Both are settings of the two mods themselves (other authors; read once when the game starts):
- highlight: `FocusNearbyPickups.ini` `maxRadius=1000.0` (cm; 0 = no limit; `viewHalfAngleDeg=35.0` is the cone)
- auto loot: `G1R_AutoPickUpItemNative.ini` `AreaLootingRadius=500` (cm)
  (FocusNearbyPickups has an auto loot of its own, off: `autoLoot=false`, `autoLootRadius=200.0`.)
The megamod can offer the two numbers (settings app page "Other mods"; in-game menu) and write exactly that one
line into each file (copy of the file kept, nothing else in those folders touched). Effective from the next game
start. Not possible: changing them while the game runs (each mod keeps its own copy of the value).
