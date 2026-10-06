Module "magic" (magic balancing 1.0) - Gothic 1 Remake, UE4SS Lua
=================================================================

What it does
  It changes the numbers of the game's spells: damage, mana cost, casting
  and charging time, flight speed, reach, how hard a spell staggers, what
  the heal spell gives, what a magic circle costs to learn, and whether an
  ice spell freezes with every hit. Everything is a setting, and every
  setting can be changed while the game runs.

  As shipped, every multiplier is 1.0 and every switch of a change is off:
  the module then does not touch the game at all - it does not even look
  at the spell data.

Settings
  Scripts\config.lua in this folder, the settings app (page "Combat",
  the groups "Magic: ...") or the in-game mod menu (page "G1R Combat").
  Changes are picked up while the game runs: from the menu at once, from
  the file within about 5 seconds. A changed number counts from the next
  cast on.

  A value in the game is
      the game's own number (or your own number, where there is one)
        x the multiplier for all spells
        x the multiplier for its kind (fire, ice, energy, wind)
        x the multiplier for the single spell.
  Damage and mana are whole numbers in the game's data, and a multiplier
  has three decimals: a product that misses a whole number by 0.025 or
  less is taken as that number (90 x 2.778 = 250.02 becomes 250).

  Magic: all spells
    Enabled           false = the module does nothing, the game's own
                      numbers are in place
    Damage            damage of every damage spell (0.1 to 10)
    ManaCost          mana to cast, and mana a second for spells that are
                      held (0 to 10; 0 = free)
    WholeMana         true = a changed mana cost is rounded to whole points
                      and never becomes 0 unless a multiplier is 0
                      false = the exact product is written (2 x 1.25 = 2.5)
    CastTime          casting time, and the time to charge to the next
                      level (0.1 to 10; 0.5 = twice as fast)
    ProjectileSpeed   how fast fire bolt, ice bolt, fire ball, ball
                      lightning and the storm of fire fly (0.25 to 5)
    Range             how far a target spell finds its target (sleep,
                      charm, shrink, heal, pyrokinesis, chain lightning,
                      telekinesis, control) and how far storm fist, death
                      to the undead and Uriziel's wave of death spread
                      (0.25 to 4). Other spells keep their reach.
    Stagger           how much of a foe's steadiness a spell hit takes
                      away (0 to 20)
    HealAmount        the health a step of the heal spell gives (0.1 to 10)
    SchoolFire        damage of fire bolt, fire ball, pyrokinesis, storm of
                      fire, rain of fire
    SchoolIce         damage of ice bolt, ice block, ice wave
    SchoolEnergy      damage of ball lightning, chain lightning, Uriziel's
                      wave of death, death to the undead
    SchoolWind        damage of fist of wind, storm fist, breath of death

  Magic: fire / ice / energy / wind spells - for each of the fifteen damage
  spells (FireBolt, FireBall, Pyrokinesis, StormOfFire, FireRain, IceBolt,
  IceBlock, IceWave, BallLightning, ChainLightning, Uriziel,
  DeathToTheUndead, WindFist, StormFist, BreathOfDeath):
    <Spell>Damage     damage of that spell (0.1 to 10)
    <Spell>Mana       its mana cost (0 to 10)
    <Spell>CastTime   its casting or charging time (0.1 to 10; the fist of
                      wind has none: the game casts it at once)
  and
    IceBoltFreeze, IceBlockFreeze, IceWaveFreeze
                      true = every hit of that spell freezes at once, also
                      foes with ice resistance. false = as the game has it:
                      a hit freezes when its damage fills the foe's ice
                      counter (50 points)
    BallLightningSpeed  the speed of the ball at every charge level, in
                      units a second; 0 = the game's own (300 to 450)
    WindFistStagger   how hard the fist of wind staggers (0 to 20; the game
                      has 200, a storm fist 250)

  Magic: fire bolt and ice bolt by the caster's circle
    FireBoltSteps     true = the four numbers below are the fire bolt's
                      damage (the multipliers still apply)
    FireBoltStep0     below the 2nd circle        (the game: 35)
    FireBoltStep2     from the 2nd circle         (40)
    FireBoltStep4     from the 4th circle         (50)
    FireBoltStep6     in the 6th circle           (65)
    IceBoltSteps, IceBoltStep0 / 2 / 4 / 6        (the game: 20 / 30 / 40 / 50)

  Magic: learning the circles
    CircleCosts       true = the numbers below are the prices
    CircleCostBasics  the basics of magic, before the 1st circle (the game: 5)
    CircleCost1 ... CircleCost6   learning points for each circle
                      (the game: 10, 15, 20, 25, 30, 40)

  Magic: on screen, log
    ShowMessage       a short note on screen when a changed setting has
                      reached the game
    LogChanges        one line in UE4SS.log for every value that is changed
                      or put back
    In the in-game menu: the button "Write what is changed right now into
    UE4SS.log" lists the state of the module and every changed value.

  Not shown in the app or the menu; a line can be added to config.lua by hand:
    Config.SearchesPerLook = 4      how many of the game's data objects are
                                    searched for per look (1 - 32). Each
                                    search costs a few milliseconds, once
                                    while the game runs: set 1 or 2 if the
                                    game stutters right after its start or
                                    after a changed setting
    Config.CheckSeconds = 60        how often the changed values are read
                                    again (0 - 3600 seconds; 0 = only after
                                    a map change)
    Config.LookMilliseconds = 250   how often the module looks whether
                                    there is something to do (50 - 5000;
                                    read once, when the game starts)

  Console (UE4SS console):  magic          what is on, how many values are
                                           changed, what could not be found
                            magic values   the same and every changed value
                            magic reload   read config.lua now
                            (g1r_magic does the same as magic)

What you will notice
  - The numbers hold for everyone who uses the same spells. Human mages
    cast with the same runes as the hero: with damage x2 their fire balls
    hit twice as hard too. With a larger reach they also keep a larger
    distance in a fight.
  - Creatures, orc shamans, golems, demons and the companions of the last
    fight have spells of their own. They stay as the game has them.
  - A spell that is already flying keeps the numbers it started with.
  - Tool tips of runes and scrolls show the changed damage and mana as far
    as the game reads them from the same data; this was not checked.
  - Nothing is written into a save. With a setting back at 1.0, or the
    module switched off, the game's own number is put back at once.

Coming from the mod G1R_MageBalance
  Use one magic balance at a time. While the mod "G1R_MageBalance" is
  enabled, this module is not loaded (UE4SS.log: "magic left to the
  separate mod G1R_MageBalance"). To use this module, disable that mod.
  Its config.lua is a table of absolute numbers per spell; here the same
  is said with multipliers (30 damage for a spell the game gives 20 is
  x1.5) and, for the two bolts and the circle prices, with numbers of
  your own. What that mod writes as fractions of mana (1.25, 2.5) needs
  WholeMana = false here.

How it works
  The numbers of a spell are the game's own data: the default object of
  the spell's definition class (damage, also by the caster's magic circle,
  flight speed, force against a foe's stance), of its config class (mana,
  casting time, reach), of an ice spell's hit effect and of the skill
  effects of the magic circles. The game reads them there whenever a spell
  is cast, a hit lands or a circle is learned. The module writes the
  changed numbers into those objects:
  - an object is searched only when a setting that concerns it is not
    neutral, at most four per look (a search costs a few milliseconds),
    each once while the game runs;
  - the first number read from a place is kept as the game's own, and a
    new number is always computed from that one;
  - a place is only written while it holds the game's own number or the
    module's last one. A number somebody else put there (another mod) is
    left alone and listed in the status;
  - every write is read back; one that did not stay is said once in
    UE4SS.log;
  - two seconds after a map change and once a minute the changed places
    are read again; what the game has put back is set again;
  - the game's numbers and the module's are also kept in a UE4SS shared
    variable, so that reloading the Lua mods while the game runs does not
    make the module multiply its own numbers.
  No game function is replaced and no hook is set.

In the game
  The module ran in the game with megamod 0.2.1 (a session of 140 minutes
  on 2026-10-04: 24 settings for single spells, one ice spell set to freeze
  with every hit, own prices for the magic circles). Seen there, by the
  module's own notes: all 33 objects of the game were found; the game's own
  numbers were read (the diagnostics list them as magic.original.<name>);
  every kind of write was read back as written - 73 numbers in all -; and
  all of them were still in place after each of eight map loads.
  Not shown by any note, only read from the game's scripts and executable:
  that the game then uses the changed numbers (damage dealt, mana taken,
  time to cast, price asked, a freeze with every hit) - that is for you to
  see in a fight. What the game makes of a mana cost with a fraction is not
  known - hence WholeMana.
  The megamod's Scripts\diagnostics\ folder says what the module saw: the
  game's own numbers of every object it touched (magic.original.<name>),
  whether each kind of write stayed (magic.write.*), and whether the
  numbers outlived a map change (magic.after_load).
