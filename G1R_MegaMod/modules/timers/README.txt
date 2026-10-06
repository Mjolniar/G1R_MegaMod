Module "timers" - how long what is on you still lasts (G1R_MegaMod)
====================================================================

What it does
  A small box lists what is on you and how long it still lasts, for
  example "Burning 7 s", "Healing 1:12", "Light 4:32", "Alcohol 1:00":
  * healing and mana over time from food and potions;
  * burning, frozen, electrified, wind, slowed;
  * knocked out, and sleep, fear or charm cast on you;
  * the Light spell (the game's own timer of the spell; when that cannot be
    read, the module counts itself - that count does not stand still while
    you talk, the game's does);
  * alcohol and swampweed: how long until they have worn off (the level and
    the rate it falls by);
  * if you want, every other effect of the game that lasts a while, by the
    game's own name for it.
  The box is only there while something is on you. It is read twice a
  second; nothing is written into the game.
  Console: timers (status), timers reload (read config.lua now).

Not tested in the game yet
  The list of effects is read straight from the hero's ability system, the
  Light's time from the engine's timer of the spell. If the box stays empty
  while you burn or drink, send UE4SS.log and the folder Scripts/diagnostics
  of G1R_MegaMod (the notes timers.* say which part did not answer).

Settings: Scripts/config.lua (the settings app, page "Interface > Effect
  timers", or the in-game mod menu, page "Effect timers")
  Enabled        the whole module (true)
  ShowFood       healing and mana over time (true)
  ShowElements   burning, frozen, electrified, wind, slowed (true)
  ShowMind       knocked out, asleep, afraid, charmed (true)
  ShowLight      the Light spell (true)
  ShowDrinks     alcohol and swampweed (true)
  ShowOthers     every other effect that lasts a while (false)
  Position       the corner of the box: "bottom left" (default), "top left",
                 "bottom right", "top right"
  DistanceX      how far from the side, in the screen's units (24)
  DistanceY      how far from the top or bottom (200) - move it up or down
                 to stand above the health bar
  The letters are the ones set on the page "Notes on screen" (module
  general: gothic, book or plain).
