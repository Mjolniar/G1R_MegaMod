Module "wait" (skip game time 1.0) - Gothic 1 Remake, UE4SS Lua
===============================================================

What it does
  Lets you skip game time without a bed: press a key and the game's clock
  is 30 minutes further, or four hours, or at eight in the morning. There
  are four waits, each with a key and an amount of its own:

    short wait           so many minutes (the mod ships with 30)
    long wait            so many minutes (240 = four hours)
    wait until morning   to an hour of the day (8 = 08:00)
    wait until evening   to another hour of the day (20 = 20:00)

  "Until" means the next time the clock shows that hour: today if it is
  still ahead, otherwise tomorrow. What counts is where the clock stood
  when you pressed the key. A press in the last moments before the hour
  (the clock reaches it by itself before the skip is made, about half a
  second after the press) skips nothing - the hour is there. Only a press
  in the last twentieth of a second before the hour, or one made while the
  game hangs for a moment, can be taken for a press after it: that is then
  a wait until tomorrow.

  After a skip a small note says what happened and what time it is now:
      30 minutes later - 14:30

  The mod ships WITHOUT keys: choose them in the settings (below). Without a
  key you can still wait:
    - in the in-game mod menu (SharedModMenu), page "G1R Time", every wait
      has a button ("Wait the short time now", ...);
    - in the console:  wait 30        skip 30 minutes (1 to 1440)
                       wait until 8   skip to the next 08:00 (hour 0 to 23)
      (the console words need a console: UE4SS's own or the game's, when one
      of them is switched on in your installation).

Settings
  Scripts\config.lua in this folder, the settings app (page "Time") or the
  in-game mod menu (page "G1R Time"; keys cannot be set there). Changes are
  picked up while the game runs, within about 5 seconds.

    Enabled              false = the module does nothing
    Cooldown             seconds between two skips (0 to 60, shipped: 2)
    ShortKey             key of the short wait, "" = none
    ShortMinutes         1 to 1440 (a whole day)
    LongKey, LongMinutes the same for the long wait
    MorningKey           key of "wait until morning"
    MorningHour          the hour it skips to, 0 to 23
    EveningKey, EveningHour   the same for "wait until evening"
    NotInFight           no skip while the hero has a weapon drawn
    NotInConversation    no skip while the hero is talking
    NotInCutscene        no skip during a cutscene
    NotWhenClockStopped  no skip while the game itself lets no time pass
    ShowMessage          the note after a skip
    ShowRefused          also a note when a skip was NOT taken, with the reason
    LogSkips             one line in UE4SS.log for every skip

  A key is written "Y", "F6", "CTRL+Y", "SHIFT+NUM_FIVE" (CTRL, SHIFT, ALT and
  one key). A key bound without CTRL does not fire while CTRL is held.
  While a map loads no time is skipped, whatever the switches say. Whether
  the game is paused is asked once, when the module takes the key press up
  (its first look): a game that is paused then skips nothing, whatever the
  switches say. A pause that begins in the quarter second between that look
  and the skip, or one the engine cannot be asked about, shows only in the
  game's clock standing still - and that is the switch NotWhenClockStopped.
  The four "Not..." switches are on when the mod is installed; switch one
  off if it keeps you from waiting where you want to.
  How notes look (box, the game's own line, off) is set on the page "General".

  Console:  wait           what the module is doing, the last skip, why the
                           last one was not taken
            wait reload    read config.lua now

What you will notice
  - The skip follows about half a second after the key: the module first
    looks whether the game's clock is running.
  - Nothing else is done to the game: the clock moves, as it does when the
    hero sleeps. People take up what their day plans for the new hour (those
    near you walk there), timers that count game time run on - also the
    mod's own repopulation timers.
  - Waiting is not sleeping: it gives no rest and heals nothing. Hunger,
    thirst and tiredness count the skipped hours in full, as if the hero had
    stood there all that time.
  - If nothing happens when you press the key, UE4SS.log says why
    ("[G1R_Wait] no time skipped: ..."), or switch ShowRefused on to see the
    reason on screen.

Other wait mods
  Use one at a time. While the mod "G1R_WaitOnT" is enabled, this module is
  not loaded (UE4SS.log: "wait left to the separate mod G1R_WaitOnT"). To use
  this module instead, disable or remove that mod.

How it works
  The game's clock is one number in its time subsystem, and the game's own
  function SkipTime adds to it - nothing more; everything that goes by the
  clock catches up at the game's next step. The module calls that function
  and then reads the clock to see that it really moved. If it did not, a
  second way of handing over the amount is tried, and as the last resort the
  clock number is written directly (which is all SkipTime does). What worked
  is remembered until the game is closed. One key press never skips twice.
  No game function is replaced and the mod never writes save files.

In the game
  The module ran in the game with megamod 0.2.1 (session of 2026-10-04):
  two skips by key - Y for 30 minutes, another key until 08:00 ("6 hours 48
  minutes, day 12 01:12 -> day 12 08:00"). The key press arrived, the clock
  had moved by what was asked right after the call, and the hero's states
  could be read before the skip. NOT seen in the game yet:
    - how people behave right after a skip, and how hunger, thirst and
      tiredness look after one (the game's code says they count the skipped
      hours);
    - a wait refused because of a drawn weapon, a conversation or a
      cutscene (if the module cannot read them it says so once in UE4SS.log
      and those switches simply have no effect);
    - the buttons in the in-game menu and the console words.
  The megamod's Scripts\diagnostics\ folder records what the module saw.
