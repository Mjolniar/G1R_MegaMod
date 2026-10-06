Module "locks" (lock picking that follows the hero's skill 1.0) - Gothic 1 Remake, UE4SS Lua
============================================================================================

What it does
  A lock is a row of pieces that have to be brought to the middle. The pieces
  are connected: moving one drags others along - that is what makes a lock
  hard. The game makes locks easier as the hero's lock picking skill grows:
  it takes none of a lock's connections away for the untrained, the first
  one for a skilled hero, the first two for a master. And a lock pick stands
  2 wrong moves (a move a piece cannot make) for the untrained, 4 for the
  skilled, 6 for a master before it breaks.

  This module lets you choose both numbers for each of the three skill
  levels: how many connections are taken away, and how many wrong moves a
  lock pick takes - or that lock picks do not break at all. A short note on
  screen says what was changed when the hero starts on a lock.

  The mod ships with everything "as the game has it": nothing changes until
  you choose something. With the module switched off, or with every level as
  the game has it, the module does not look at the game at all.

Settings
  Scripts\config.lua in this folder, the settings app (page "Lock picking"),
  or the in-game mod menu (entry "G1R Lock picking"). Changes are picked up
  while the game runs (a changed file within about 5 seconds, the menu at
  once). They count from the next lock on: a lock that is being picked is
  never changed.

    Enabled                false = the module does nothing

    UntrainedConnections   connections taken away from a lock while the hero
    SkilledConnections     is untrained / skilled / a master:
    MasterConnections
        "as the game has it"   untrained none, skilled 1, master 2
        "none"                 every connection stays (harder for a skilled
                               hero or a master)
        "1", "2"               the first one / the first two
        "all"                  every piece moves on its own
        "half"                 by the lock: half of its connections
        "safe"                 by the lock: as many as the lock is proven to
                               stay solvable with (see below)

    PicksNeverBreak        true = lock picks do not break in the middle of a
                           lock
    UntrainedWrongMoves    wrong moves a lock pick takes before it breaks:
    SkilledWrongMoves      0 = as the game has it (2 / 4 / 6), or 1 to 99
    MasterWrongMoves       (not used while PicksNeverBreak is true)

    ShowMessage            a short note on screen when the hero starts on a
                           lock that this module changed
    LogLocks               one line in UE4SS.log for every lock the hero
                           starts on, with what was changed for it

  In the in-game menu a choice is a number: 1 = as the game has it,
  2 = none, 3 = 1, 4 = 2, 5 = half, 6 = safe, 7 = all. The menu also has the
  button "Put the game's own values back now" (see "Saves" below).
  In config.lua the choices are texts, with the quotation marks:
  Config.SkilledConnections = "2", not = 2.

  Example - the untrained hero as the game has him, the skilled one as easy
  as each lock allows, the master without any connection:
    Config.SkilledConnections = "safe"
    Config.MasterConnections = "all"

  Console (UE4SS console):  locks            what the module is doing
                            locks reload     read config.lua now
                            locks restore    put the game's own values back
                                             (see "Saves")

Which choices are safe
  With some of its connections taken away a lock can become impossible to
  open. So the module only offers numbers that were checked against the
  game's own lock definitions (346 locks; 332 of them belong to a chest or
  a door, the other 14 to a random-lock feature the game has switched off):
  - "none", "1", "2" and "all": each of the 332 locks can be opened with
    each of these. "1" and "2" are what the game itself uses for the skilled
    hero and the master.
  - A fixed 3, 4, 5 ... is not offered: 78 of the 332 locks cannot be opened
    any more with some number between 3 and all of their connections taken
    away.
  - "safe" takes, for each lock, the largest number that is proven: the lock
    can be opened with that many taken away and with every smaller number.
    For 267 of the 346 locks that is all of their connections; for the others
    between 1 and 6.
  - "half" takes half of the lock's connections (rounded down), but never
    more than the "safe" number.
  - "half" and "safe" never take fewer away than the game does itself at the
    hero's level, for every lock of a chest or door in the world. (One test
    lock in the game's data that no chest or door uses cannot be opened at
    the master's own number even in the unchanged game; the table has the
    largest number it can be opened with.)
  "Can be opened" was checked by a program that tries every position a lock
  can be in; the test suite of the mod plays a way to open every lock for
  every number the module can write. The check rests on how the game's
  minigame works as read from the game's program code (see "In the game").
  The numbers for "half" and "safe" are in Scripts\lockdata.lua. They belong
  to this version of the game: a lock that is not in the file is left as the
  game has it. If a game update should change existing locks, use "all" or
  "as the game has it" until the file has been made anew. A lock that
  cannot be opened is not damaged: leave it, choose another setting and
  start on it again (the lock's own reset key puts its pieces back to where
  they started).

What you will notice
  - "half" and "safe" work for chests. A door's lock is left as the game has
    it with these two choices (untrained none, skilled 1, master 2 taken
    away): the module cannot learn early enough which lock a door has. The
    fixed choices ("none", "1", "2", "all") work for doors and chests alike.
  - A setting changed while a lock is being picked counts from the next
    lock. A pick that breaks in the middle of a lock does not change the
    lock either.
  - When the hero learns the next level of the skill, the module writes the
    numbers chosen for that level within a second.
  - The game uses a lock pick up in two ways: it breaks when it has taken
    its number of wrong moves, and a pick that has taken at least one wrong
    move is gone when the hero leaves the lock without opening it. The
    wrong-moves settings and "lock picks do not break" change the first,
    not the second: giving up on a lock after a wrong move still costs the
    pick, as in the game. Opening the lock keeps it.
  - The module changes nothing else about lock picking: not the experience
    for a picked lock, not who notices the hero at a lock, not the lock
    picks in the inventory.

Saves
  The two numbers are values of the hero, and the game stores every value of
  the hero in its saves.
  - While a fixed choice or a number of wrong moves is in force, a save made
    then holds the changed number. As long as the module stays on that makes
    no difference: it would write the same number anyway.
  - With "half" and "safe" the changed number is only in place from the
    moment a chest's lock starts until that lock is over. Should the game
    save in that time, the save holds that one lock's number. Between
    locks the module looks at the number at every look and puts the game's
    own back when it finds another (UE4SS.log says so once), so that the
    number of one lock cannot meet another lock - with it a door could
    become impossible to open.
  - Switching the module off (Enabled = false), or setting a level back to
    "as the game has it", while the game runs: the module first puts the
    game's own numbers for the hero's level back - at once, or as soon as a
    lock that is being picked is over - and then stops looking at the game.
    A save made after that is clean.
  - A changed number can stay behind in a save when the game is closed (or
    crashes) while the module has it changed, and the module is switched off
    or the mod removed before that save is played again. From what the
    game's program code shows, the game sets its own numbers again whenever
    a save is loaded, which would repair this by itself - but that has not
    been seen in the game yet.
  - The remedy, if lock picking is still changed although the module is off:
    leave the mod installed and this module loaded (its switch Enabled may be
    false), load the save and press "Put the game's own values back now" in
    the in-game mod menu (entry "G1R Lock picking"), or type  locks restore
    in the UE4SS console. The module writes the game's own numbers for the
    hero's level once and says what it did. Then save. Should the module
    answer that it cannot tell the hero's level, name it:
    locks restore untrained  /  locks restore skilled  /  locks restore master.
  - Before removing the mod for good: switch this module off while the game
    runs, wait a second, save.
  A number that stays behind does no harm to the save itself: locks are
  then easier (or harder) than the game would make them until the game
  writes its own numbers again, which it does when the hero learns a level
  of the skill. One case is worse: a number of "half" / "safe" that stayed
  behind (a save made in the middle of a chest's lock) while the module is
  off or removed - with the number of another lock a few locks cannot be
  opened at all. The remedy above puts that right too.

Other lock picking mods
  Use one at a time. While the mod "SkillfulLocks" is enabled, this module is
  not loaded (UE4SS.log: "locks left to the separate mod SkillfulLocks"), so
  the two never write the same value. To use this module instead, disable or
  remove SkillfulLocks and carry its settings over:
    untrained: left alone   ->  UntrainedConnections = "as the game has it"
    skilled: "auto"         ->  SkilledConnections = "safe"
    master: "all"           ->  MasterConnections = "all"
  "safe" is this module's own answer to the same question (how many
  connections can go without making the lock impossible), from its own check
  of the game's locks. The difference you will see: at a door the skilled
  hero gets the game's own lock (1 connection taken away), not the easier
  one.

A setting that is not shown (add it to config.lua by hand if needed)
    LookSeconds = 1    how often the module looks at the hero (0.25 to 10
                       seconds)

How it works
  The two numbers are attributes of the hero's player state
  (LockpickPrecision and LockpickDurability). The game reads them at the
  moment a lock is set up. Once a second the module looks which skill level
  the hero has (the game marks it with a tag), whether a lock is being picked
  (another tag), and what the two attributes hold; a number that differs from
  the chosen one is written and read back. Nothing is written while a lock is
  being picked. The module remembers which numbers are its own and puts the
  game's back before it stops.
  For "half" and "safe" the module has to know the lock before the game sets
  it up. It hooks one function of the game - the one that starts the lock of
  a chest - once, and only when such a choice is in use, reads the lock's
  name there and writes the number for that lock; when the lock is over the
  game's own number is put back. If that hook cannot be set up, or the game
  never calls it, these two choices leave every lock as the game has it, and
  the module says so (UE4SS.log, the command locks).
  The module registers nothing else: no notification, no search by name that
  could repeat. (A crash of the game on 2026-10-01 came from another mod that
  repeated a search for a function that does not exist at every lock.)

In the game
  The module ran in the game with megamod 0.2.1 (session of 2026-10-04; the
  hero a master of lock picking, "all" set for the master).
  - Seen there: eleven locks were started, each with the module's number
    (99) in place; the hero's level was told by his skill tags; the game
    wrote its own number (2) back seven times and the module set its own
    again. The names of chest locks are the ones in lockdata.lua (seen in a
    session with another author's mod).
  - Read from the game's program code and data, not seen in the game: the
    rules of the minigame that the "safe" numbers rest on; that the pick's
    wrong moves can be set the same way; the function hooked for "half"
    and "safe"; the settings for an untrained and a skilled hero.
  - Not known: what the lock screen shows for a pick that takes many more
    wrong moves than the game's 2 to 6.
  If the tags cannot be asked, the module tells the level by the numbers the
  game itself set and no longer notices a lock in progress (no note, and a
  changed setting does not wait for the lock's end); with "half" and "safe"
  it then leaves every lock as the game has it. "half" and "safe" also
  leave every lock as the game has it while the tags answer but do not show
  the hero's skill level (the module says so once): tags like that are not
  relied on to tell when a lock is over. If a number cannot be written, it
  is left as it was and the module says so once.
  The megamod's Scripts\diagnostics\ folder records what the module saw:
  how the level was told, whether its numbers were in place when a lock
  started, whether the hook ran, and what the hero's values held after a
  load.
