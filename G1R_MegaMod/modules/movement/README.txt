Module "movement" - how fast you walk, run and swim, and your scavenger runs (G1R_MegaMod)
==========================================================================================

What it does
  * Hero on foot: the hero's own speed factor (his movement
    attribute SpeedModifier; the game's character definition gives him
    1.00, its tiredness lowers it by a few percent on top) times the
    multiplier: walking, running, sneaking.
  * Swimming: the game's three swimming speeds of the hero (slow,
    normal, fast: 100, 150 and 220) times the multiplier. The game keeps
    them in a table of its own (the default object of the script class
    LocomotionSpeedSettings_Swim_Laying_Player); the module multiplies that
    table.
  * Your scavenger: the scavenger's own speed factor (its movement
    attribute SpeedModifier, 1.00; the game's own tiredness moves such a
    factor by a few percent) times the multiplier. It counts whenever the
    scavenger runs: with you on its back, and when it follows you. The
    scavenger is found through the game's own lookup by name, as the module
    "mount" finds it - no search among all objects.
  * 1.00 leaves the game as it is. Going back to 1.00, or switching the
    module off, puts the game's own values back.
  * The game's own factor of the hero and of the scavenger is the 1.00 of
    their character definitions; the module sets 1.00 times the multiplier.
    New attributes - the scavenger summoned, a save loaded - are set to
    that, never multiplied again (version 1.0.0 did: the scavenger got
    faster with every summon).
  * A value somebody else set in the meantime (another mod, or the game
    itself) is left alone - said once in UE4SS.log - until the next change
    of the setting or new attributes.
  * Nothing is written into your save games.
  * Console: movement (status), movement reload (read config.lua now).

Seen in the game (1.0.0 and 1.1.0, 2026-10-06)
  The swimming table and the scavenger's factor found and written; the
  player saw the scavenger faster (too fast after several summons: fixed
  in 1.1.0). 1.1.0 found the scavenger's factor at 1.00 and set 1.30 once
  (MountSpeed 1.30); a summon under 1.1.0 is not seen yet. The hero's own
  factor (1.1.0) has run in the offline tests only.

Not tested in the game yet
  Whether the game uses changed swimming speeds and a changed speed factor
  at once, or only for a hero or scavenger made after the change (for
  example after loading a save). If a setting seems to do nothing, load the
  save again; if it still does nothing, send UE4SS.log and the folder
  Scripts/diagnostics of G1R_MegaMod.

What it costs
  Nothing while every multiplier is 1.00. Otherwise one look every two
  seconds: the hero's factor, the swimming table (three values) and the
  scavenger's factor.

Settings: Scripts/config.lua (the settings app, page "Hero > Movement", or the
  in-game mod menu, page "Movement", change them while the game runs)
  Enabled        the whole module (true)
  HeroSpeed      speed of the hero on foot, times (1.00; 0.50 - 3.00)
  SwimSpeed      swimming speed, times (1.00; 0.50 - 3.00)
  MountSpeed     speed of your scavenger, times (1.00; 0.50 - 3.00)
  LogChanges     a line in UE4SS.log for every speed changed or put back (false)
  The multipliers are not part of the five presets of the settings app.
