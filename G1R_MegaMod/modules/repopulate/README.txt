Module "repopulate" (G1R_Repopulate 1.4) - Gothic 1 Remake, UE4SS Lua
======================================================================

Easy-mode world repopulation. Defaults:

  Creatures   every missing creature: 35 % chance every 24 in-game hours
              Shadow Beasts, Swampsharks, Skeleton Mages (elites):
              15 % every 24 in-game hours
              any species can get its own chance / interval, or be switched off
  Corpses     when a creature comes back, one corpse of its kind at that spot
              disappears (generic creatures only; never humans, NPCs, orcs,
              named / boss / quest creatures; never within 40 m of you)
  Herbs       plants, berries, mushrooms regrow after 24 in-game hours
  Items       everything else lying in the world comes back, about 15 %
              per in-game day (one week on average)
  Containers  emptied chests / crates / corpses restock their original
              contents: 30 % per day in the camps and mines (Old, New,
              Swamp and Bandit Camp, Old and Free Mine), 10 % per day
              everywhere else. Items you stored yourself stay untouched.
              Nothing is put in while you stand at the container.

  Crime       optional switch (Config.Crime in Scripts\config.lua). Left on
              = the game's own rules. Details below.

  One in-game day is about 96 real minutes; sleeping counts.

Settings
  Scripts\config.lua in this folder (plain text, explained inside):
  chances and timers per group and per species, corpses, containers, crime,
  advanced. The settings app G1R_Repopulate_Settings.exe, when it is in this
  folder, edits the same file (presets, "scale all chances / timers").
  A running game picks up saved changes within about 15 seconds
  (UE4SS.log: "settings reloaded").

Already looted before installing (retroactive)
  - Item spots: the game itself stores when each spot was emptied, also for
    spots that never refilled; such spots refill on your next visit once
    their time is up.
  - Containers: a container that is already missing items the first time the
    mod sees it counts as emptied 3 days ago (RetroactiveDays) and gets its
    first roll right away.
  - Creatures: dead creatures stay in the save as "dead", so their spawn
    points count as populated and refill like any other.
  The "base state" is the game's own data (container definitions, item spot
  definitions, spawn points), so no old save is needed.

Crime and restocked loot
  Opening or picking an owned chest is judged by the chest, as before.
  Restocked items carry no owner mark of their own (the game marks some item
  kinds when it fills a container for the first time); whether taking them
  is reported as theft has not been checked in game. Regrown items on owned
  spots get their owners again from the spot. Theft memory still fades after
  12-72 in-game hours; there is just more to steal. One-time owned spots
  (e.g. Gomez's rooms) become repeatable theft targets.

Crime switch (Config.Crime in Scripts\config.lua)
  Enabled = true (default): the game's own rules; the mod does not touch
  the crime system at all.
  Enabled = false switches these kinds off (each can be left on):
    DisableTheft        stealing, pickpocketing, lockpicking, using other
                        people's things (chests, beds, ...)
    DisableTrespassing  other people's huts and areas, sneaking around
    DisableWeapons      drawn weapons or fists, threatening people,
                        blocking their way
    ForgetOldCrimes     also wipes what you already did of those kinds
                        (only your own, only those kinds)
  Always counts: hitting and killing people. Story fights and defeat
  bookkeeping are not touched. People who are already hostile or after you
  when you switch stay that way until it ends by itself.
  Also off with DisableTheft / DisableTrespassing: the owner or guard who
  only hears you at an owned chest or door (or in an owned place) and walks
  over to look and comment.
  Not covered: an item that makes a noise in someone's area still draws
  them (the game's distraction mechanic), and the owner of a bed still
  wakes you.
  How: the game looks up a rule for every crime in one table on its crime
  subsystems, on your side and on every witness's side. Off puts an
  existing rule into the entry that finds no victim for that act, so the
  crime is dropped before it is written down and nobody reacts. On puts
  the original rules back. The game rebuilds the table on every load and
  the mod applies the switch again about a second later; the switch is
  never stored in a save. Forgotten crimes are removed with the game's own
  function and stay forgotten when you save.
  The walk-over after a noise is a separate response module; while its kind
  is off it is made to apply to nobody (it then asks for a tag only the
  player character owns). That sits in memory only and is undone by
  switching back on or restarting the game.
  A running game follows the setting within about 15 seconds.

Never touched
  Named NPCs, humans, orcs and orc dogs, bosses and unique creatures
  (Prime / Named / Queen / golems / demons / Homer's lurker / Viran's
  bloodflies / ...), creatures spawned by quests or story events, the
  Sleeper Temple and Xardas' tower. Quest, unique, key, map and writing
  items, and items placed by story events.

How it works
  Built from the game's own data (GORE decompile of the shipped scripts:
  401 generic creature spawn points with 814 creatures, 2495 item spots,
  528 containers) and the game's own functions:
  - creatures are spawned by their own world point (WorldPointScript
    SpawnAIAgent), only at points that were populated in this
    playthrough, never above the point's original count, never within
    40 m of you; corpses go through the NPC state's RemoveFromWorld, the
    same call the game's level scripts use;
  - item spots use the game's own refill (the spot's m_Refillable /
    m_RefillHours), set again after every load; turning a group off
    restores the game's own values;
  - containers are counted with the game's own function (HasItemMain)
    and get their items back through their own inventory
    (DataModule_Container Multicast_AddNewItem, the call the game uses
    itself). The item classes are read from the default contents the
    game keeps on each container, not searched for by name.
  Creatures and items are saved by the game like any other change. A
  container is written into the save by the game only when you open it:
  until then the mod remembers "restocked, not opened yet" and puts the
  same items back when the container is loaded again (no new roll).
  The mod itself never writes save files; its own progress (which spawn
  points were populated, which containers wait or were restocked) is kept
  per profile in Scripts/state/.

Its own progress file
  Scripts\state\profile_<n>.lua, one per game profile. It is written to
  profile_<n>.lua.tmp first, read back, and only then put in place; the
  file before it stays as profile_<n>.lua.bak and is used when the newest
  one cannot be read (UE4SS.log says so). A file that cannot be read at
  all is kept as profile_<n>.lua.bad and the module starts with nothing
  remembered. To start over on purpose: close the game and delete
  profile_<n>.lua and profile_<n>.lua.bak.

Objects of the game (1.4)
  The game loads and unloads parts of the world all the time, fastest
  while riding. Up to 1.3 the module kept objects it had found and checked
  them before use; three crashes of 2026-10-04 / 05 ended in a call on such
  an object, or in a search among all objects of the game. Since 1.4:
  - a container or a creature is followed from the moment the game puts it
    into play to the moment it takes it out (the game's own begin / end of
    play calls); after that nothing of it is touched;
  - the hero, the game clock, the profile, the crime rule sets and the list
    of item spots are asked from the engine, not searched for;
  - the one search that is left - the creature count, once per roll -
    waits after a map load and while the game is unloading many objects;
  - mounting, dismounting and getting up from a bed do not make the module
    start over (it waits 3 seconds and goes on); it starts over at a map
    load - loading a save is one -, when the game clock goes back, or when
    the profile changes; nothing is done while the game is paused;
  - in the main menu, where the game has no clock, the module waits: where
    the clock has to be searched for, that is done at growing pauses (2
    seconds to 2 minutes) instead of at every update.
  If the engine does not answer one of these questions, or the game's
  calls do not arrive, the module works the way 1.3 did and says so in
  UE4SS.log and in "repop" (lines "objects in play: ..." and "this run:
  ...").

Console (UE4SS console)
  repop          status
  repop now      run a creature cycle now (testing)
  repop items    re-apply the item refill settings
  repop reload   re-read config.lua now
  repop crime    crime switch status (and re-check now)
  repop save     write the state file now

UE4SS.log lines
  [G1R_Repopulate] v1.5.0 loaded: 401 creature spawn points ...
  [G1R_Repopulate] session started at day N hh:mm | state profile_X.lua ...
  [G1R_Repopulate] session reset N (map load | the game clock went back |
                   another player controller | the profile changed)
  [G1R_Repopulate] the game's begin / end of play calls are not used any
                   more (reason); objects are found and checked the old way
  [G1R_Repopulate] world items: 2495 spots set refillable ...
  [G1R_Repopulate] creature cycle (timer, due 24h x1): ... respawning N
  [G1R_Repopulate] settings reloaded: creatures on 35%/24h ...
  [G1R_Repopulate] containers: N here, N waiting to restock, N restocked
                   and not opened yet | session: ...   (when it changes,
                   at most every 5 minutes)
  [G1R_Repopulate] containers: first emptied container noticed (IO_...,
                   N item(s) missing)
  [G1R_Repopulate] restocked IO_... (settlement): N item(s)
  [G1R_Repopulate] restocking IO_... did not work (N of M item(s) arrived)
  [G1R_Repopulate] containers: the item classes of IO_... cannot be read
                   from the game's data; containers like it are left alone
  [G1R_Repopulate] crime: OFF for theft, trespassing, weapons - N rules
                   switched in M rule sets, N noise reactions off
  [G1R_Repopulate] crime: noise reaction not switched (reason)
  [G1R_Repopulate] crime: N earlier crimes forgotten
  [G1R_Repopulate] crime: back to the game's own rules
  [G1R_Repopulate] crime: switch not applied completely (reason)
                   = it did not work; the game's rules are still active

Switching it off
  Set Repopulate = false in the mod's Scripts\config.lua (or remove the
  mod). Creatures and items it brought back stay in your saves as normal
  game objects; nothing else needs cleaning. The crime switch is gone with
  the next game start (forgotten crimes stay forgotten).
