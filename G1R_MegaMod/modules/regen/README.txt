Module "regen" (mana and health regeneration 1.0) - Gothic 1 Remake, UE4SS Lua
==============================================================================

What it does
  Every few seconds the hero gets some mana and some health back. You choose
  for each of the two: how much per step (a share of the maximum, a fixed
  number of points, or both), how many seconds between two steps, up to which
  part of the maximum it goes, and how long it waits after mana was spent or
  damage was taken. Mana can depend on the hero's magic circle, and both can
  run slower - or stop - while a weapon or a spell is drawn.

  The mod ships with every amount at 0: nothing regenerates until you set
  an amount. With the module switched off, or with every amount at 0, the
  module does not look at the game at all.

Settings
  Scripts\config.lua in this folder, the settings app (page "Combat"), or the
  in-game mod menu (entry "G1R Combat"). Changes are picked up while the game
  runs (a changed file within about 5 seconds, the menu at once).

    Enabled            false = the whole module does nothing

    ManaEnabled        false = mana does not regenerate
    ManaPercent        share of the maximum mana per step, in % (0 - 100)
    ManaFlat           points of mana per step, on top of the share (0 - 1000)
    ManaSeconds        seconds between two steps (0.5 - 600)
    ManaUpTo           regeneration stops at this part of the maximum
                       (0 - 100 %)
    ManaPause          seconds of waiting after mana went down (0 - 3600)
    ManaArmedPercent   share of the usual amount while a weapon, the fists or
                       a spell is drawn: 100 = no difference, 0 = nothing

    ManaByCircle       true = the amount depends on the hero's magic circle:
    ManaCircleNone       % of the amount without any magic training
    ManaCircleNovice     % with the basics of magic, before the first circle
    ManaCircleFirst      % in the first circle
    ManaCircleStep       % added by each further circle
                       (100 and 10 = 100, 110, 120 ... 150 % in the sixth)

    HealthEnabled, HealthPercent, HealthFlat, HealthSeconds, HealthUpTo,
    HealthPause, HealthArmedPercent
                       the same for health

    ShowMessage        a short note on screen when mana or health starts to
                       regenerate after a wait and when it reached its limit
    LogSteps           one line in UE4SS.log for every step

  Example - mana: 2 % of the maximum every 3 seconds up to 75 %, 15 seconds
  after a spell; health: 1 point and 1 % every 5 seconds up to 50 %, 30
  seconds after damage:
    Config.ManaPercent = 2.0      Config.HealthPercent = 1.0
    Config.ManaSeconds = 3.0      Config.HealthFlat = 1.0
    Config.ManaUpTo = 75          Config.HealthSeconds = 5.0
    Config.ManaPause = 15         Config.HealthUpTo = 50
                                  Config.HealthPause = 30

  Console (UE4SS console):  regen          what the module is doing
                            regen reload   read config.lua now
  "regen" also says when no time is counted at the moment and why (the
  engine is paused, the game's clock stands still), and how much time was
  counted since the game was started.

What you will notice
  - Amounts are whole points, because the game keeps mana and health as
    whole numbers. A step of less than a point is not lost: fractions are
    carried over (2 % of 30 mana = 0.6 per step = 3 points in 5 steps).
  - The limit is never passed: 75 % of 30 mana is 22. A value above the
    limit (a potion, sleep) is left alone.
  - Seconds are seconds of play. Nothing regenerates in the pause menu, while
    a map loads or while the game's own clock stands still. Sleeping or
    skipping time gives nothing extra - the bed restores what the game
    restores.
  - After a game was loaded the wait (ManaPause / HealthPause, at least 5
    seconds) runs once before the first step - also when the values go
    down in that time.
  - Every loss starts the wait again. Something that keeps taking health
    or mana away (poison, a spell that is held, hunger at its worst) keeps
    the wait running: nothing regenerates until it has stopped.
  - A wait that you make shorter in the settings while it runs is cut to
    the new length at once (not below the 5 seconds of SettleSeconds); one
    that you make longer counts from the next loss on.
  - A hero who is dead or lies unconscious gets nothing, and a dead hero is
    never healed.
  - When a spell has used up all mana the game blocks casting until one of
    its own effects (a potion) brings mana back. The module takes that block
    off when its first point of mana arrives, so regenerated mana can be
    used.
  - "With a weapon or spell drawn" is what the game calls combat: a weapon in
    hand, the fists up or a spell ready. It is not "enemies nearby" - the
    game has no cheap, certain way to ask that.

Other regeneration mods
  Use one at a time. While the mod "G1R_RegenMana" is enabled, this module is
  not loaded (UE4SS.log: "regen left to the separate mod G1R_RegenMana"), so
  nothing is ever restored twice. To use this module instead, disable or
  remove G1R_RegenMana and carry its values over (see the example above).
  Not carried over, because this module does not have them: the marker on
  the bars for values that can regenerate (the note on screen, ShowMessage,
  tells you instead when regeneration starts and when it is complete) and
  the requirement of wearing certain items.

Settings that are not shown (add them to config.lua by hand if needed)
    Method = "auto"             how the value is changed: "auto" = the game's
                                own way, a direct write when that does not
                                work; "game" = only the game's own way;
                                "direct" = only the direct write
    ManaClearBlock = true       false = the game's block on casting after mana
                                ran out is left to the game
    StopWhenPaused = true       false = time also counts while the engine
                                says the game is paused
    StopWhenClockStands = true  false = time also counts while the game's
                                clock stands still
    SettleSeconds = 5           the shortest wait after a game was loaded
    LookSeconds = 0.5           how often the module looks at the hero's
                                values (0.25 - 5 seconds)

How it works
  Mana and health are numbers ("attributes") of the hero's player state.
  Twice a second the module reads them. When a step is due it hands the new
  value to the game's ability system through the attribute set's own function
  (TrySetAttributeBaseValue): the game rounds and limits the value itself and
  tells the bars on screen. If that function cannot be used the two numbers
  are written directly; the bars on screen may then lag until the next change
  the game makes itself. Every change is read back; a value that cannot be
  written is left as the game has it, and after three such steps the module
  stops trying for that value. It tries again when the game is restarted,
  when the setting Method is changed, or when that value is switched off
  and on again (ManaEnabled / HealthEnabled). Changing Method also makes
  the module try the game's own way again after it had fallen back to the
  direct write. What cannot be re-armed without a restart: tags that cannot
  be asked, and a block on casting that cannot be taken off (each given up
  after three failures in a row). No game function is replaced, nothing is
  hooked, and the mod never writes save files - the game saves mana and
  health as it saves everything else.

In the game
  The module ran in the game with megamod 0.2.1 (a session of 140 minutes
  on 2026-10-04; mana +2 % every 3 s up to 75 %, health +1 and +1 % every
  5 s up to 50 %). Seen there, by the module's own notes:
    - mana +60 in 60 steps and health +74 in 15 steps, every step given
      through the game's ability system (the way the game itself changes
      these numbers);
    - the hero's tags can be read (a question was answered with "yes");
    - at zero mana the game's block on casting was found and taken off,
      7 times;
    - the game's menus pause the engine, and the counting stops there;
    - the game's own clock stood still at times while the engine was not
      paused (about 5 of the 140 minutes), and regeneration waited. Should
      mana and health ever stay put although you are playing, type "regen"
      in the console: if it says that the game's clock stands still, set
      StopWhenClockStands = false.
  Not seen yet: mana by magic circle (the setting was not in use), slower
  regeneration with a weapon drawn, a hero who is dead or unconscious when a
  step is due, and the direct write that is used when the game's own way
  does not work (it was never needed).
  If something does not work, the megamod's Scripts\diagnostics\ folder says
  what the module saw (notes regen.*), and "regen" in the console shows what
  it is doing.

Not in this module
  What sleeping restores cannot be changed safely: the game rounds every
  number of the mana and health attributes to whole numbers when they are set
  its own way (the bed's 12.5 % per hour could only become 0 or 100 %), and a
  direct write is not seen by the bed once the hero has slept. So the bed
  stays as the game made it.
