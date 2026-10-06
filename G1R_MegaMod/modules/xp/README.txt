Module "xp" (experience multiplier 1.0) - Gothic 1 Remake, UE4SS Lua
====================================================================

What it does
  Every experience gain of the hero counts as many times as you set:
  2.0 = double, 4.0 = four times, 0.5 = half. It works for every source of
  experience (fights, quests, lock picking, ...). With 1.0 (the value the mod
  ships with) or with the module switched off, experience stays exactly as
  the game gives it.

  When experience was added, a small note on screen says how much:
      +90 experience  (30 -> 120, x4.0)

Settings
  Scripts\config.lua in this folder, the settings app (page "Experience"),
  or the in-game mod menu (entry "G1R Experience"). Changes are picked up
  while the game runs (a changed file within about 5 seconds, the menu at
  once).
    Enabled              false = the module does nothing
    Multiplier           0 to 10; 1.0 = unchanged
    LargeGainFrom        a gain of at least this size counts as large (a
                         quest reward rather than a fight); 0 = no
                         difference between small and large gains
    LargeGainMultiplier  the multiplier for large gains (0 to 10), only used
                         when LargeGainFrom is above 0
    ShowMessage          the note on screen (how notes look, where they sit
                         and how long they stay is set on the page "General")
    LogGains             one line in UE4SS.log per gain
  Not in the app or the menu (add the line to config.lua by hand):
    MaxGain              a rise larger than this at once is not taken for a
                         gain (50000)
    SettleSeconds        after a save was loaded, nothing is multiplied for
                         this long (10)
    CheckMilliseconds    how often the module looks (250)
  Console (UE4SS console):  xp          what the module is doing
                            xp reload   read config.lua now

What you will notice
  - The game's own "+ experience" display shows the amount before the
    multiplier. Your total (character screen) is the multiplied one.
  - A level that the added experience makes possible is given with your
    next experience gain: the game compares experience and level whenever
    it gives experience itself.
  - Never multiplied: the difference after loading a save or starting a new
    game, and anything gained while the module was off or the multiplier
    was 1.0. Changing the multiplier never changes experience you already
    have.

Other experience multipliers
  Use one at a time. While the mod "EXPModifier" is enabled, this module is
  not loaded (UE4SS.log: "xp left to the separate mod EXPModifier"), so a
  gain is never multiplied twice. To use this module instead, disable or
  remove EXPModifier.

How it works
  The hero's experience is a number in the level progression attributes of
  his player state. Four times per second the module looks at it. When it
  went up by a plausible amount (at most 50000 at once), the gain times
  (multiplier - 1) is added to it. Nothing else of the game is changed, no
  game function is replaced, and the mod never writes save files - the game
  saves the experience as it saves everything else.

In the game
  The module ran in the game with megamod 0.2.1 (a session of 140 minutes
  on 2026-10-04, multiplier x10): 70 gains multiplied, +121590 experience
  in all; the hero's experience was found through his player state and
  every write was read back. Not seen: the module standing down next to
  another experience multiplier (there was none). If something does not
  work, the megamod's Scripts\diagnostics\ folder says what the module saw.
