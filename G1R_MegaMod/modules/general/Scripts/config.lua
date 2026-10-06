-- ============================================================================
-- General settings (module general of G1R_MegaMod)
-- Easiest way to change these: the settings app, page "General", or the
-- in-game mod menu. Changes are picked up while the game is running.
-- ============================================================================
local Config = {}

-- ---- Notes on screen ----
-- "box" = a small box in a corner of the screen; "subtitle" = the game's own line at the top
-- of the screen (also used when the box cannot be shown); "off" = no notes at all.
Config.NoteStyle = "box"
-- The corner of the screen the box sits in.
Config.NotePosition = "top right"
-- How long a note stays on screen, in seconds (1 to 10).
Config.NoteSeconds = 3

-- ---- Letters ----
-- "gothic" = the game's blackletter, as in its headlines; "book" = the game's letters for running
-- text; "plain" = the engine's plain letters (as up to version 0.2.3). The names on the map
-- screens have a setting of their own (module markers, NameLetters).
Config.Letters = "gothic"

return Config
