Module "keys" - the list of your keys (G1R_MegaMod)
===================================================

What it does
  * F3 (or a key of your choice) shows a small box at the top left that
    lists your keys, each with what it does; the key hides it again. It
    works in the pause menu and while you play; a map load hides it too.
      - the keys of this mod's modules that have a key set (the list's own
        key, the waits, the scavenger);
      - the keys of the other mods it knows, read from their own settings
        files each time the list comes up: SharedModMenu (the mod menu),
        HUDMap (the HUD map, its settings), FocusNearbyPickups in
        PLuaModLoader (show what lies nearby, corpses, chests, quick loot
        while it is on), G1R_AutoPickUpItemNative (pick up, pick up by
        itself) and G1R_PutAwayTorchRedux (the torch);
      - another mod that UE4SS starts is named with "keys not known".
    A key you changed in one of those files shows up the next time the list
    comes up. The box takes no clicks.
  * While the pause menu is open, one small line at its top left names the
    key ("F3 - list of keys"). Without a key the pause menu shows the whole
    list instead.
  * F3 is not used by the game (its keyboard mappings, read from the game's
    files, use F5 and F9 only of the function keys) nor by the other mods
    the list knows.
  * The pause menu is looked at afresh four times a second through the
    game's own widgets (the player's main widget and the stack the pause menu
    is shown in); nothing of the menu is kept. Nothing is written anywhere.
  * Console: keys (status and the list), keys reload (read config.lua now).

Seen in the game (0.3.0, 2026-10-06)
  The pause menu found, the list shown above it, the five other mods of the
  PC read. 1.1.0 (the key, the line, the smaller box) has run in the
  offline tests only.

What it costs
  While the line or the list is up: four property reads a second. The other
  mods' settings files are read when the list comes up, not while it is up.

Settings: Scripts/config.lua (the settings app, page "Interface > Key list",
  or the in-game mod menu, page "Key list")
  Enabled        the whole module (true)
  ListKey        the key that shows or hides the list ("F3"; "" = none)
  InPauseMenu    the line in the pause menu that names the key (true)
  OtherMods      list the keys of the other mods too (true)
  TextSize       the size of the letters (10; 8 to 16; the notes have 12)
  ShowKey        the key of version 1.0.0; no longer used (ListKey took its
                 place, so that the new key reaches a file that said "")
