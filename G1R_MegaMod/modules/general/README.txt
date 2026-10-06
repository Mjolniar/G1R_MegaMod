General settings (module "general" of G1R_MegaMod)
===================================================

What it does
------------
Several parts of the mod can show a short note on screen (experience added,
time skipped, ore mined, ...). This module holds the settings all of them
share: how such a note looks, where it sits and how long it stays. Whether a
part shows a note at all is that part's own switch.

Settings (Scripts/config.lua; the settings app, page "General"; the in-game
mod menu, entry "G1R General"). Changes are picked up while the game runs.

    NoteStyle      "box"       a small box in a corner of the screen (black
                               frame, pale yellow, black letters). If the box
                               cannot be shown, the game's own line is used.
                   "subtitle"  the game's own line at the top of the screen
                   "off"       no notes at all
    NotePosition   the corner of the box: "top right", "top left",
                   "bottom right", "bottom left"
    NoteSeconds    how long a note stays (1 to 10 seconds)
    Letters        the letters of the boxes the mod puts on screen (the
                   notes, the list of keys, the effect timers):
                   "gothic"    the game's blackletter, as in its headlines
                               (default)
                   "book"      the game's letters for running text
                   "plain"     the engine's plain letters (as up to 0.2.3)
                   The names on the map screens have a setting of their
                   own (module markers, NameLetters: the game's own letters
                   by default, or blackletter).

In the in-game mod menu there is also a button "Show a note now".

Not tested in the game yet
--------------------------
The box is built from plain interface widgets of the engine; whether it looks
as described has not been seen in the game. If it cannot be built, UE4SS.log
says "notes on screen are not available (...)" once and notes go to the
game's own line.
Whether the game's own fonts are found and taken has not been seen either;
when one is not found the texts keep the engine's letters (diagnostics:
kit.letters).
