Module "melee" (melee clean-ups 1.0) - Gothic 1 Remake, UE4SS Lua
================================================================

What it does
  Three things that shape how a melee blow looks and feels, each with its
  own setting. None of them changes damage, combos or their timing.

  1. Mirrored follow-up swings (the game's own "flow helper")
     The game has an option of its own (its program calls it "fake sloppy
     combos"). With it on (the game's default), pressing the same attack
     direction again while a swing ends starts a mirrored follow-up swing:
     hammering one direction looks like a chain of blows, though it is no
     combo. With it off the same swing simply starts again, and chains come
     only from real combos (the right direction at the right moment).
     The setting can leave that option to the game, or hold it off or on.

  2. Hit stop
     When a melee blow lands, both fighters stand still for a moment (about
     a twentieth of a second) and then pick up speed again. The setting is
     the length of that stop in percent of the game's own: 100 = unchanged,
     0 = none, 50 = half, 200 = twice as long.

  3. Camera shake on hits
     The jolt (and the short zoom) of the camera when a melee blow lands or
     the hero is hit by one. The setting switches it off for melee blows
     only; every other camera shake stays.

  The mod ships with all three at their neutral value (game, 100, true):
  nothing of the game is changed, and the module does not look at the game
  at all. The same holds while the module is switched off.

Settings
  Scripts\config.lua in this folder, the settings app (page "Combat"), or the
  in-game mod menu (entry "G1R Combat"). Changes are picked up while the game
  runs (a changed file within about 5 seconds, the menu at once) and acted on
  right away - but not while a map loads or the game is paused, and a setting
  is set for the first time only once a game is running.

    Enabled       false = the module does nothing; what it had changed in the
                  game is put back
    FlowHelper    "game" = the game's option is left alone
                  "off" / "on" = the module sets it, and sets it again
                  when something else changes it (up to five times in
                  a row; see below)
                  (in the in-game mod menu: 1 = game, 2 = off, 3 = on)
    HitStop       0 to 300, percent of the game's own length; 100 = unchanged
    HitShake      false = no camera shake when a melee blow lands
    ShowMessage   a short note on screen when the module has changed one of
                  the three in the game or has put it back

  Not shown in the app or the menu; a line can be added to config.lua by hand:
    Config.CheckSeconds = 3      how often the module looks whether the flow
                                 helper is still as set (1 - 60 seconds)
    Config.VerifySeconds = 30    how often it reads the hit stop and camera
                                 shake values again (5 - 3600 seconds)
    Config.FlowMethod = "auto"   how the flow helper is set: "auto" = the
                                 game's own function, and writing the value
                                 itself when that does not work; "option" =
                                 only the game's function; "direct" = only
                                 the value itself (the game then stores
                                 nothing)
    Config.ActWhilePaused = false   true = changes are also made while the
                                 game is paused

  Console (UE4SS console):  melee          what the module is doing
                            melee reload   read config.lua now

What you will notice
  - Every setting can be taken back: set it to its neutral value (or switch
    the module off) and the game has what it had before. Hit stop and camera
    shake are also back to the game's own after a restart of the game in any
    case - the module never writes them anywhere but into the running game.
  - The flow helper is different, because it is the game's own option: the
    game keeps it for each profile and stores it there. While FlowHelper is
    "off" or "on", a change you make in the game's own options menu is
    undone within 3 seconds - change it here instead. If the option is
    switched back five times in a row right after the module set it
    (something else in the game or another mod insists on its value), the
    module stops: one line in UE4SS.log, the option stays as the game has
    it, and choosing FlowHelper anew tries again. "game" hands the option
    back: the value the profile had before is put back, and the game's menu
    is yours again. If you close the game while the setting is "off" or
    "on", the profile keeps that value - the module remembers what the
    profile had only while the game runs. "game" (or removing the mod)
    then changes nothing: to get the game's own default back, set "on"
    once (on is the game's default) or use the game's own options menu.
  - If you play several profiles: each one is set when you play it, and
    "game" puts back only the profile you are in at that moment (the log
    names the others).
  - If the Lua mods are reloaded while the game runs (UE4SS can do that;
    it is switched off unless you switched it on) while hit stop or camera
    shake are changed, the module no longer knows the game's own values.
    It then leaves those tables as they are - a hit stop of 50 stays 50 -
    and says so in UE4SS.log and in its status; restart the game to change
    them again. The flow helper stays as set, as after closing the game.
  - The game has its own option for camera shake (all of it). With that
    option off there is no shake at all, whatever HitShake says. HitShake =
    false takes away the shake of melee blows only - including the one for
    squashing a meat bug - and leaves the rest.
  - A hit stop of 0 also removes the short slow-down of deflected blows.
    Bows have their own values, which the module does not touch.
  - What is NOT here, because the game has no safe switch for it: the timing
    of combo windows, how fast weapons are drawn or swung, the clumsy swings
    of the untrained fighter (that is the game's skill progression) - those
    sit inside animation files; and how far a hit pushes someone - one
    number of the game scales that for every fighter and every boss alike.

How it works
  Nothing of the hero is changed. The flow helper is set the way the game's
  options menu sets it (the game's own function), so the game stores it and
  its menu shows it. Hit stop and camera shake are numbers and names in four
  small tables that the game reads at every blow; the module remembers what
  each entry held, writes "the game's value x percent" (never a multiple of
  its own value), reads everything back, and looks again every 30 seconds
  and after every map load. A table that cannot be read, written or read
  back as expected is put back as it was and left alone, with one line in
  UE4SS.log saying why.

In the game
  With megamod 0.2.1 the module was loaded in every session and had
  nothing to change (all three settings as the game has them), so it did
  not look at the game. Nothing of what it changes has run in the game.
  What it relies on was read from the game's program and scripts:
  - that the game's own function for the flow helper can be called from a
    mod (if not, the module writes the value itself - then the game does not
    store it - and if that fails too, it leaves the option alone and says so);
  - whether the game's options menu shows the flow helper at all in this
    version, and under which name (another tool calls it "Close Combat Flow
    Helper");
  - that the four tables are where the module looks for them and can be
    written (another mod changes spell values in this game in the same kind
    of way; these tables have not been tried);
  - whether a map load puts the game's own values back (the module checks
    after every load and sets them again if so).
  The console command "melee" and the megamod's Scripts\diagnostics\ folder
  say what the module found and did.
