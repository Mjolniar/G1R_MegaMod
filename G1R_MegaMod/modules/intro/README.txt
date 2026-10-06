Module "intro" - what plays when the game starts (G1R_MegaMod)
=============================================================

What it does
  * Skip the logos when the game starts: the logos at the start (Alkimia,
    THQ Nordic, the legal screen) are a list in the game's own settings -
    the start list of its loading screen. The game reads its settings file
    Game.ini (%LOCALAPPDATA%\G1R\Saved\Config\Windows) on top of the packed
    ones, so the settings app writes the game's own start list without the
    three logos there, between two comment lines of its own:
      ; ---- G1R_MegaMod: skip the logos at game start (begin) ----
      ...
      ; ---- G1R_MegaMod: skip the logos at game start (end) ----
    It does that when you press Save with the game closed (while the game
    runs it waits: it says so), and takes exactly those lines out again when
    you switch the setting off. Nothing else in Game.ini changes; the first
    version of a Game.ini that was there before is kept next to it
    (Game.ini.before-G1R_MegaMod). A Game.ini that the app made itself goes
    again when it is switched off. It counts from the next start of the
    game. The engine's loading picture still shows while the menu loads.
    If Game.ini already sets the start list itself (another tool, by hand),
    the app leaves it alone and says so.
  * Skip the film of a new game: when you start a new game, the game shows
    its usual loading screen instead of the film. The game chooses its
    loading screen by a type it sets before the map loads; at the very start
    of the map load the module turns the type "game intro" into the usual
    one. Loading a save is not touched. (The game itself also lets you skip
    the film: hold Space, Esc or the left mouse button for a second.)
  * The module itself never writes Game.ini or any other file of the game;
    it only reads Game.ini, and says in UE4SS.log whether this start of the
    game skipped the logos.
  * Nothing is written into your save games.
  * Console: intro (status), intro reload (read config.lua now).

Not tested in the game yet
  Whether the game takes the start list from Game.ini: after the first
  start with the setting on, UE4SS.log says "this start of the game skipped
  the logos" or "... played the logos". And whether the game has chosen the
  film of a new game already when the module looks: with the setting on,
  every map load notes the type it found (diagnostics: intro.loading_type);
  a new game that still shows the film means it had not. In both cases send
  UE4SS.log and the folder Scripts/diagnostics of G1R_MegaMod.

What it costs
  Nothing while both settings are off (it reads Game.ini once at the start).
  With "Skip the logos" on: one look at the game's start list after the
  first map load. With "Skip the film" on: one question to the game at the
  start of every map load.

Settings: Scripts/config.lua (the settings app, page "Interface > Game
  start"; not in the in-game mod menu - the logos cannot be changed while the
  game runs)
  Enabled          the whole module (true)
  SkipLogos        skip the logos when the game starts (false)
  SkipNewGameFilm  skip the film of a new game (false)

Remove the mod
  Switch "Skip the logos" off in the settings app and press Save with the
  game closed first - or delete the lines between the two comment lines
  above from Game.ini yourself.
