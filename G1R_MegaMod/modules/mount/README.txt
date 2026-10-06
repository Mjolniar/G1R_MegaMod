Module "mount" - the scavenger you ride (G1R_MegaMod)
======================================================

Its name
  Setting "Name of your scavenger" (settings app, page Mount; the in-game
  menu cannot take texts): the name shown over your scavenger instead of
  the game's. Empty = the game's name. At most 40 letters. Wild scavengers
  keep theirs. The game makes that name from its own text table, so the
  module changes the text of the name widget over the scavenger, a quarter
  second after the game shows it at the latest (new in 1.1.0; not seen in
  the game yet).

Why
  Sometimes the scavenger does not come when you whistle, and a restart of
  the game puts that right. The game has three ways to that:
    1. you carry the game's riding block (State.RidingBlocked). The game
       puts it on you inside camps and other no-riding areas and takes it
       off when you leave; a missed exit leaves it on you until a reload,
       and the scavenger's follow routine gives up at once while you have it.
    2. the scavenger fears you: one of your own hits landed on it, it marked
       you as an enemy and runs from you instead of following. Gone after a
       restart.
    3. the whistle reached nobody: the follow routine waits for a caller
       for ever.
  None of these is caused by this mod. This module finds out which it was
  and puts it right without a restart.

What it does
  * Every whistle (the game marks you with Action.CallMount for 3 seconds)
    writes one line to the log, for example
      [G1R_Mount] whistle 3: you: riding block no, mounted no | scavenger:
                  42 m away, fears you no
    and 8 seconds later (setting "Look again after") a second line with the
    distance then.
  * When the scavenger is not here by then, has not come closer and you are
    not riding, it is put right (setting "When it did not come"):
      full  - the riding block is taken off you, fear is taken off the
              scavenger, and it is put back to its idle routine (which makes
              it friendly to you again). A note says "whistle again".
      safe  - the same without touching the riding block. Choose this if you
              want camps to stay no-riding areas even when the block is
              stuck on you; the key or the console then take it off.
      off   - only written down.
    When the scavenger's distance cannot be read, nothing is done (a routine
    that may be working is not touched).
  * A key of your choice ("Key that puts the scavenger right") and the
    console words do the same at once, whistle or not:
      mount           status
      mount report    one look at you and the scavenger (also shown on screen)
      mount fix       put it right now (as "full")
      mount reload    read config.lua now
    The in-game mod menu has the two buttons "Report the scavenger now" and
    "Put the scavenger right now".

What it costs
  One tag question to the hero's ability system per quarter second (the
  same kind of question the modules regen, locks and mining ask). The
  scavenger is only looked up at a whistle, through the game's own lookup by
  name - no search among all objects. With a name set: a look at the HUD's
  name widgets per quarter second, and the lookup while one is shown.

Settings: Scripts/config.lua (the settings app, page "Mount", or the in-game
  mod menu change them while the game runs)
  Name           the name shown over your scavenger ("" = the game's)
  Enabled        watch the whistle (true)
  AutoFix        "full" | "safe" | "off" (full)
  WaitSeconds    seconds between the whistle and the second look (8; 4 - 20)
  FixKey         the key ("" = none)
  ShowNotes      a note on screen when something was put right (true)

What to send when it still does not come
  UE4SS.log and Mods\G1R_MegaMod\Scripts\diagnostics\ (the whistle lines and
  the notes mount.*) - they say which of the three it was, or that it was
  none of them.
