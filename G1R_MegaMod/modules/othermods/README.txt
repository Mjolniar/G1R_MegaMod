Module "othermods" - settings of other mods (G1R_MegaMod)
=======================================================

What it does
  Two numbers that belong to two other mods, set from the settings app:
  * how far FocusNearbyPickups (in PLuaModLoader) highlights things:
    maxRadius in its FocusNearbyPickups.ini (the mod's own value: 10 m);
  * how far G1R_AutoPickUpItemNative picks items up: AreaLootingRadius in
    its G1R_AutoPickUpItemNative.ini (the mod's own value: 5 m).
  Each of those mods reads its file once, when the game starts. When you
  press Save in the settings app with the game closed, the app writes
  exactly that one line into the mod's file - nothing else in the file or in
  its folder changes - and keeps the first version of the file next to it
  (<file>.before-G1R_MegaMod). It counts from the next start of the game.
  While the game runs the app writes nothing and says so.
  A switch that is off leaves the mod's file as it is. To go back to the
  mod's own distance, set the number to it (10 m, 5 m) and save, or put the
  .before-G1R_MegaMod file back.
  This module itself only reads the two files: UE4SS.log says once when a
  file does not hold what the settings ask yet.
  Console: othermods (status), othermods reload (read config.lua now).

Not in the in-game mod menu
  The other mods read their files only when the game starts.

Settings: Scripts/config.lua (the settings app, page "Other mods")
  Enabled          the whole module (true)
  SetHighlight     write the highlight distance (false)
  HighlightMeters  how far things are highlighted, metres (10; 0 = no limit)
  SetLoot          write the pick-up distance (false)
  LootMeters       how far items are picked up, metres (5)
