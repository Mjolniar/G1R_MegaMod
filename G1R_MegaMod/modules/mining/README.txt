Module "mining" (mining rework 1.0) - Gothic 1 Remake, UE4SS Lua
================================================================

What it does
  It decides how much ore a swing of the pickaxe gives and how long a vein
  lasts:
    * ore per swing = base amount
                      + 1 for every so many points of Strength
                      + 1 for every so many points of Dexterity
                      + a bonus for a trained or a master miner,
      kept between a lowest and a highest amount, with a chance of one more;
    * veins that never run out, or veins that last several times as long.
  With the settings the mod ships with nothing is changed: mining is exactly
  as the game has it, and the module does not even look at the game.

The game itself (what the settings start from)
  One swing gives 3 ore. When 5 or fewer ore are left in the vein, a swing
  gives 1. A vein holds 5, 10 or 15 ore; once it is empty it stays empty.
  The game has a mining skill (untrained, trained, master), but that skill
  does not change what a swing gives. There is only ore to be mined.

Settings
  Scripts\config.lua in this folder, the settings app (page "Resources") or
  the in-game mod menu (entry "G1R Resources"). Changes are picked up while
  the game runs and count from the next swing on.

    Enabled          false = the module does nothing

  Ore per swing
    YieldEnabled     true = the numbers below decide what a swing gives
    BaseAmount       every swing starts with this much (3 = the game's own)
    StrengthPerOre   one more ore for every so many points of Strength
                     (0 = Strength does not count; 2.5 is possible)
    DexterityPerOre  the same for Dexterity
    TrainedBonus     so much more for a hero who has learned mining
    MasterBonus      so much more for a master miner (instead of the above)
    ExtraChance      chance in percent that a swing gives one more ore
    MinAmount        a swing never gives less than this
    MaxAmount        a swing never gives more than this
    LowVeinRule      true = a vein with 5 or fewer ore left gives 1 per
                     swing, as in the game; false = the same as a full vein

    Example: BaseAmount 0, StrengthPerOre 4, DexterityPerOre 6 gives
    Strength / 4 + Dexterity / 6 (each rounded down): 3 ore with 10 / 10,
    13 ore with Strength 40 and Dexterity 22.

  How long a vein lasts
    EndlessVeins     true = the vein you swing at is filled up again. It
                     never runs out, every swing gives the full amount (also
                     more than the vein holds), and a vein you emptied
                     earlier comes back when you swing at it.
    VeinLastsTimes   a vein gives this many times as much ore before it is
                     empty (1 = as in the game). Of what a swing takes, the
                     fitting part is put back: with 3, two of every three
                     ore. Not used while EndlessVeins is on.

  On screen and in the log
    ShowMessage      a short note when a swing gave more or less than the
                     game would have:   Mining: 7 ore (the game gives 3)
    LogSwings        one line in UE4SS.log for every swing the module sees

  Not in the app or the menu (add the line to config.lua by hand):
    VeinMethod       how ore is put into a vein: "auto" (the game's own
                     function, else the count of the vein's first slot),
                     "function" or "slot". Only the game's own function
                     can bring back a vein that was mined out; the slot
                     way keeps a vein from running out but does not
                     refill an empty one.
    RefreshSeconds   how often the hero's Strength and Dexterity are looked
                     at when nobody swings (5)
    CheckMilliseconds  how often the module looks for a swing (250); read
                     once when the game starts, a change needs a restart

  Console (UE4SS console):  mining          what the module is doing
                            mining reload   read config.lua now

What you will notice
  - Without endless veins a swing never gives more than the vein holds: 20
    ore per swing from a vein of 15 gives 15, then nothing.
  - The ore reaches you the game's own way, with the game's own display.
  - Ore is only ever given by a swing at a vein. Nothing is added when you
    loot, trade or get a reward.
  - A changed setting never changes ore you already have. Switching the
    module off puts the game's own numbers back at once.
  - "A vein lasts ... times as long" loses the last fraction: a vein of 15
    that lasts 3 times as long gives a little less than 45 ore.
  - The game redraws a vein only when a swing ends. With endless veins a
    vein you had mined down looks whole again after the first full swing at
    it (for that one swing the module keeps it one ore below full, because
    the game does not redraw a full vein). Ore put back by "a vein lasts ...
    times as long" shows from the end of the next swing on.
  - An endless vein is filled for the next swing as early as possible, so
    a vein you walk away from, or switch the module off at, can hold one
    swing's amount more than the game gave it. That ore stays in the vein.

Other mining mods
  Use one at a time. While the mod "BetterMining" is enabled, this module is
  not loaded (UE4SS.log: "mining left to the separate mod BetterMining"). To
  use this module instead, disable or remove BetterMining. Its settings as
  settings of this module:
      StrPerOre = 4           ->  StrengthPerOre = 4
      AgiPerOre = 6           ->  DexterityPerOre = 6
      (its formula)           ->  YieldEnabled = true, BaseAmount = 0,
                                  MinAmount = 0, LowVeinRule = false
      PreventExhaustion=true  ->  EndlessVeins = true

How it works
  The game keeps three mining numbers in one object: how much a swing gives
  from a full vein, how much from a nearly empty one, and where "nearly
  empty" begins. Its mining code reads them at the end of every swing and
  moves that much ore from the vein to you. The module writes the first two
  numbers (and reads each one back); it remembers the game's own values and
  puts them back when you switch the feature off. Nothing of the game is
  hooked or replaced.
  To know when you swing, the module looks at your mining ability four
  times a second (is it active, and at which vein), and while you swing it
  counts the ore in that vein: when there is less, the game has handed the
  ore out. For endless veins it fills the vein while you swing, up to "what
  the game gave the vein when it was new + the amount of this swing"; for
  veins that last longer it puts part of the ore back after the swing. It
  never writes save files; the game saves a vein as it saves everything
  else.

In the game
  The module ran in the game with megamod 0.2.1 (session of 2026-10-04).
  Seen there, by the module's own notes: the game's numbers were read (3 ore
  per swing, 1 when 5 or fewer are left in the vein); the module's numbers
  were written and were still in place at every later look; Strength,
  Dexterity and the mining skill could be read; the hero's mining ability
  was found in his own list of abilities. No vein was mined in a logged
  session, so nobody has seen yet:
    - that a swing then gives the amount that was written (the module
      compares both and says so if they differ);
    - that ore can be put into a vein (two ways are tried), and that the
      game saves a vein that was filled;
    - that a mined-down vein looks whole again after one swing with endless
      veins;
    - whether the game lets you swing at a vein that is already empty (if
      not, an emptied vein cannot be brought back by swinging at it);
    - whether a mining skill can be learned in the game at all.
  If something does not work the module says so once in UE4SS.log and
  leaves that part of the game as it is. The megamod's Scripts\diagnostics\
  folder records what the module found.
