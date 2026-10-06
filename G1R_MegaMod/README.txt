G1R_MegaMod 0.3.5 - Gothic 1 Remake, UE4SS Lua
===============================================

One mod folder with ten modules and a small flight recorder. Every module
has its own switch, and everything a module does is a setting that can be
changed while the game runs. The seven newer modules (general to wait)
ship neutral: as installed they change nothing and do not even look at the
game - until you set something.

  repopulate   The world fills up again. Creatures come back at their own
               spawn points (35 % per missing creature every 24 in-game
               hours; Shadowbeasts, Swampsharks, Skeleton Mages 15 %), herbs
               regrow after 24 hours, items lying in the world come back
               (about 15 % per day), emptied chests and crates restock their
               original contents (30 % per day in the camps and mines, 10 %
               elsewhere). Optional switch that turns theft, trespassing and
               drawn-weapon crimes off. Never touched: named NPCs, humans,
               orcs, bosses and unique creatures, quest and story spawns,
               quest / unique / key / map / writing items.
               Details: modules\repopulate\README.txt

  markers      Open the map: every named NPC (181) is shown where that NPC
               is right now. Teachers blue, traders gold, others red, orcs
               green; a colour key sits at the bottom left. On the world
               map, people standing together become one badge with their
               number - hover it for the list of names. On the camp maps
               names are shown where they fit; hover any pin for the names
               around it.
               Details: modules\markers\README.txt

  general      How the short notes of the other modules look on screen
               (a small box in a corner, the game's own line, or none),
               where the box sits and how long a note stays; and the letters
               of every text the mod puts on screen: "gothic" (the game's
               blackletter, the default), "book" or "plain".
               Details: modules\general\README.txt

  regen        Mana and health come back over time: how much per step (a
               share of the maximum, a number of points, or both), how
               often, up to which part of the maximum, how long it waits
               after a spell or a hit; mana can follow the magic circle,
               and both can slow down or stop while a weapon is drawn.
               Details: modules\regen\README.txt

  magic        Magic balancing: damage, mana cost, casting time, flight
               speed, reach and stagger of the spells - for all spells, per
               kind (fire, ice, energy, wind) and per spell; what the heal
               spell gives; what a magic circle costs to learn; ice spells
               that freeze with every hit.
               Details: modules\magic\README.txt

  melee        Three switches for how a melee blow looks and feels: the
               game's own mirrored follow-up swings ("flow helper") held
               off or on, the length of the hit stop (0 to 300 %), camera
               shake on melee hits off. Damage, combos and their timing are
               not changed.
               Details: modules\melee\README.txt

  mining       Ore per swing from a base amount, Strength, Dexterity and
               the mining skill, between a lowest and a highest amount;
               veins that never run out or last several times as long.
               Details: modules\mining\README.txt

  xp           Experience multiplier (0 to 10), with a multiplier of its own
               for large gains (quests) if you want one; a short note says
               how much was added.
               Details: modules\xp\README.txt

  locks        Lock picking that follows the hero's skill: for the
               untrained, the skilled and the master you choose how many of
               a lock's connections are taken away (none, 1, 2, half, as
               many as the lock stays openable with, all) and how many wrong
               moves a lock pick takes - or that picks never break.
               Details: modules\locks\README.txt

  wait         Skip game time without a bed: four waits (two by minutes,
               two until an hour of the day), each with a key of your
               choice, a button in the in-game menu and a console word.
               Not while fighting, talking or in a cutscene, unless you
               allow it.
               Details: modules\wait\README.txt

  mount        The scavenger you ride: a name of your own over it (settings
               app); every whistle is written down with what the game says
               about you and it, and when it does not come, what stops it
               is put right without a restart (the game's riding block
               stuck on you, fear, a lost caller). Key, console words, two
               buttons in the in-game menu.
               Details: modules\mount\README.txt

  movement     How fast the hero walks and runs, how fast he swims and how
               fast your scavenger runs: his own speed factor, the game's
               swimming speeds and the scavenger's own speed factor times
               a multiplier each (1.00 = as the game has it).
               Details: modules\movement\README.txt

  intro        What plays when the game starts: the logos (Alkimia, THQ
               Nordic, the legal screen) skipped - the settings app writes
               that into the game's own Game.ini when it saves with the game
               closed, and it counts from the next start -, and the film of a
               new game replaced by the game's usual loading screen. Both off
               by default; settings app only (not in the in-game menu).
               Details: modules\intro\README.txt

  keys         The list of your keys: F3 (or a key of your choice) shows a
               small box at the top left that lists the keys of this mod and
               of the other mods it knows (SharedModMenu, HUDMap,
               FocusNearbyPickups, G1R_AutoPickUpItemNative,
               G1R_PutAwayTorchRedux - read from their own settings files),
               each with what it does; the key hides it again. While the
               pause menu is open, one small line there names the key.
               Details: modules\keys\README.txt

  timers       How long what is on you still lasts, in a small box (bottom
               left by default): healing and mana over time, burning, frozen,
               electrified, wind, slowed, knocked out, asleep, afraid,
               charmed, the Light spell, alcohol and swampweed. A switch for
               each kind; corner and distance of your choice.
               Details: modules\timers\README.txt

  othermods    Two distances of other mods: how far FocusNearbyPickups
               highlights things and how far G1R_AutoPickUpItemNative picks
               items up. The settings app writes the one line into each
               mod's own settings file when it saves with the game closed;
               it counts from the next start. Both off by default.
               Details: modules\othermods\README.txt

  diagnostics  The mod writes what it does, errors with their place, and
               what it found out about the game into Scripts\diagnostics\
               (plain text; the newest five session logs are kept, each at
               most 4 MB). Nothing leaves your PC. If something goes wrong,
               those files show where - after a crash, the session's .ops
               file names the step a module was in when the game ended.
               Details: Scripts\diagnostics\README.txt

The mod never writes save files.

Known limits
------------
  The game folder should have a path of plain English characters. With
  umlauts, Cyrillic or similar characters in the path the mod may not find
  its own files (UE4SS.log then has "could not be read" lines). Not tested.

Requirements
------------
  Gothic 1 Remake (Steam), game build Build83_CL174209.
  UE4SS for this game: v3.0.1 Beta, the build "AngelScript Fix 0.4"
  (UE4SS.log starts with "UE4SS - v3.0.1 Beta #0 - Git SHA #c838a8ac").
  Other builds of the game or of UE4SS are untested.

Install
-------
  1. Close the game.
  2. Copy the folder G1R_MegaMod into
         <game>\G1R\Binaries\Win64\ue4ss\Mods\
     so that ...\Mods\G1R_MegaMod\Scripts\main.lua exists.
  3. The file enabled.txt in the folder switches the mod on. (If you manage
     mods through mods.txt, the line is:  G1R_MegaMod : 1 )
  4. Start the game. UE4SS.log (next to UE4SS.dll) then has a line like
         [G1R_MegaMod] v0.3.5 loaded: repopulate ok, markers ok, general ok, regen ok, ... | diagnostics normal -> ...

  Never twice: a module is NOT loaded while a mod that does the same job is
  installed and enabled (the load line says "left to the separate mod ..."):

      module       stays out while this mod is enabled
      repopulate   G1R_Repopulate
      markers      NPCMarkers
      regen        G1R_RegenMana
      magic        G1R_MageBalance
      mining       BetterMining
      xp           EXPModifier
      locks        SkillfulLocks
      wait         G1R_WaitOnT

  Disable or remove the other mod to use the module of this one, and set
  the module up in its own settings (below): the settings of the other mod
  are not read. For G1R_Repopulate and NPCMarkers you can copy your
  Scripts\config.lua (and for G1R_Repopulate the folder Scripts\state\)
  into modules\repopulate\Scripts\ or modules\markers\Scripts\.

Settings
--------
  Three ways, all changing the same files:

  1. The files themselves. Plain text, a comment for every setting.
       Scripts\config.lua                      which modules are loaded at all;
                                               diagnostics level; one switch
                                               for the engine, off (read once,
                                               when the game starts)
       modules\<name>\Scripts\config.lua       one file per module. A running
                                               game reads a changed file again
                                               within about 5 seconds
                                               (repopulate: 15; markers reads
                                               its file when the game starts).
  2. The settings app (Windows): G1R_Repopulate_Settings.exe in
     modules\repopulate\, when it was installed with the mod. Categories on
     the left, their pages as tabs: Overview; World (Creatures, Herbs and
     items, Containers, Crime, Advanced); Combat (Regeneration, Magic, Fire,
     Ice, Energy and Wind spells, Circles, Melee); Resources (Mining); Hero
     (Experience, Lock picking, Mount, Movement); Time (Waiting, Rules); Map (Map pins,
     People, Colour key, Advanced); Interface (Notes on screen, Game start, Key list, Effect timers);
     Other mods (Other mods).
  3. The in-game mod menu, when the mod SharedModMenu is installed: entries
     "G1R General", "G1R Combat", "G1R Resources", "G1R Experience",
     "G1R Lock picking", "G1R Time". Changes count at once and are written
     into the files. Keys and texts cannot be set there.

  Keys (module wait) are written "Y", "F6", "CTRL+Y", "SHIFT+NUM_FIVE".

  Files next to a config.lua: when a setting is changed from the in-game
  menu, the mod writes the new file as config.lua.tmp, reads it back, and
  only then puts it in place; config.lua.bak is the file as it was before
  that change. Both can be deleted while the game is closed.

  Presets (settings app): the box "Preset" above the pages has five sets of
  settings, from "1 - Base game" (the game itself, the hardest: nothing
  comes back, nothing regenerates, every number the game's own) to
  "5 - Easiest" (every setting at the end of its range that makes the game
  easier). "Apply preset" sets everything that makes the game easier or
  harder on all pages at once - respawn and crime, regeneration, magic,
  mining, experience, lock picking; keys, notes, log switches, the melee
  clean-ups, waiting and per-species respawn settings stay as they are.
  Nothing is written until you press Save. The box stands on the preset
  your settings are at ("- in use"), or on "Your own settings" when they
  are at none of the five. PRESETS.txt lists every value of the five.

Console (UE4SS console)
-----------------------
  g1r            status of the modules and of the diagnostics
  g1r diag       write a diagnostics report now
  g1r dump       write what the modules know right now into a file
  g1r help       this list
  repop          status of the repopulate module (repop now | items | reload |
                 crime | save: see its README)
  regen, magic, melee, mining, xp, locks, wait, mount, movement, intro, keys,
  timers, othermods
                 status of that module; with "reload" behind it the module
                 reads its config.lua now. More words: wait 30, wait until 8,
                 locks restore, mount report, mount fix (see the module's
                 README)
  (The console words need a console: UE4SS's own, when it is switched on in
  UE4SS-settings.ini. Nothing depends on them.)

Uninstall
---------
  Close the game and delete the folder G1R_MegaMod. Creatures and items the
  mod brought back stay in your saves as normal game objects. The crime
  switch is gone with the next game start. What the other modules change
  lives in the running game only and is gone with the next game start, with
  these exceptions - set them back BEFORE removing the mod if you want the
  game's own values:
    - melee, FlowHelper "off" / "on": it is the game's own option and the
      game stores it in your profile. "game" puts back what the profile
      had in the same session; later the game's own default is "on" (see
      modules\melee\README.txt);
    - locks: a save made while a level's numbers were changed holds those
      numbers until the game rewrites them (console: locks restore; see
      modules\locks\README.txt, "Saves");
    - experience, mana, health, ore and game time you gained are yours;
    - intro, "Skip the logos when the game starts": the line the settings
      app wrote into the game's Game.ini stays. Switch it off in the app and
      press Save with the game closed (or delete the lines between the two
      "G1R_MegaMod: skip the logos" lines in
      %LOCALAPPDATA%\G1R\Saved\Config\Windows\Game.ini).

What has run in the game
------------------------
  Version 0.2.1 ran in the game from 2026-10-03 on: nine logged sessions,
  the longest 140 minutes, no error of the mod's own in any of them. Seen
  working there, by the mod's own notes (dev\facts\ and dev\FACTS.md say
  which note shows what):
    - the loader, the diagnostics and the settings service, notes on
      screen, keys;
    - repopulate: the refill settings written to 2496 item spots; a
      creature cycle (62 creatures brought back at their own spawn points);
      containers restocked (81 in one session) and put back after a
      reload; the crime switch for theft, trespassing and weapons;
    - markers: pins, pools, names and hover lists on the world map and the
      camp maps (the built-in comparison with the game's own player arrow:
      0 to 4 units of a map that is 1400 to 1600 wide);
    - regen: mana and health given the game's own way, the block on
      casting taken off at zero mana, the game's pause noticed;
    - magic: 73 numbers in 33 objects of the game changed, and still
      there after every map load;
    - mining: the game's numbers read and replaced;
    - xp: 70 gains multiplied;  locks: the module's number in place at
      eleven locks;  wait: two skips by key.
  Versions 0.2.2 and 0.2.3 ran on 2026-10-05 (three sessions, the longest
  84 minutes): the engine's own ways - the map load hooks handing over the
  engine, the controller and the subsystems asked from the engine, the
  game's begin and end of play calls followed for containers and
  creatures - were seen working; mount: a whistle, the scavenger came, the
  game's lookup by name and its tags answered.
  Version 0.3.0 ran on 2026-10-06: all 16 modules loaded; the pause menu
  found and the list of keys shown (five other mods read); the hero's
  effects, alcohol and the Light's own timer read, the timer box shown;
  the game's blackletter set in the boxes; the swimming speeds and the
  scavenger's factor written and read back. The player's reports led to
  0.3.1: the in-game menu cut long texts, the list of keys was too big and
  always there, a spell's mana cost showed as "Burning", blackletter names
  on the map were hard to read.

  Not seen in a game yet:
    - The module movement: how the changed speeds feel (written and read
      back in the game; nobody has said yet).
    - The module intro (new in 0.3.0): whether the game takes the start
      list from Game.ini (the first start after the app wrote it tells:
      UE4SS.log "this start of the game skipped the logos"), and whether the
      film of a new game is chosen after the module's look at the start of
      the map load.
    - Of 0.3.1: the menu texts that fit SharedModMenu's columns (built
      from its own code), the list of keys on F3 and its line in the
      pause menu, the timers without the mana cost of a spell and with the
      Light read to its end, the map names in the game's letters.
    - Of 0.3.2: the drawn pins, badges, names and colour key on the map
      screens (the same pictures in another look: loaded the way the
      classic ones are, which works in the game).
    - Of 0.3.3: the scavenger's own name over it (the way to the game's
      name widget is built from its program code and data layout).
    - The module mount: what it puts right when the scavenger does not come
      has not been needed yet.
    - Of 0.2.2: the ways back for when the engine does not answer (the mod
      then searches as 0.2.1 did), an end of play seen for a container,
      pictures kept alive, the operations file after a crash.
    - What is new in 0.3.1 has run in the offline tests only (about 7400
      automatic checks against a model of the game, built from the game's
      scripts, its data layout and its program code).
    - herbs and items actually coming back after their time (the settings
      are written; nobody has waited at a spot);
    - the crime switch also stopping people who walk over to send you away;
    - a mined vein (module mining: no swing was made in a logged session),
      the module melee (it has only run with nothing to change), and what a
      changed magic number does in a fight;
    - the pages in the in-game mod menu.
  Each module's README says what exactly it relies on and how it behaves
  if the game differs: a module that cannot do its job says so once in
  UE4SS.log and leaves the game alone.

Credits
-------
  The idea of showing NPCs as pins on the map comes from the mod
  "Active NPCMarkers" (Nexus Mods, Gothic 1 Remake, mod 270). The markers
  module is a new implementation; it contains none of that mod's files.
  The modules regen, magic, mining, xp, locks and wait do jobs that mods of
  other authors do as well (G1R_RegenMana, G1R_MageBalance, BetterMining,
  EXPModifier, SkillfulLocks, G1R_WaitOnT). They are written anew and
  contain none of those mods' code, texts or data; the lock table of the
  module locks was computed from the game's own lock data.
  Spawn points, item spots, container contents, NPC names and the map
  correction data are derived from the game's own scripts and data.
  Runs on UE4SS (RE-UE4SS).
