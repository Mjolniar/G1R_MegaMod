-- ============================================================================
-- General settings (module general of G1R_MegaMod)
-- Set in the settings app or the in-game mod menu; changes count while the game runs.
-- ============================================================================
local Config = {}

-- ---- Notes on screen ----
-- box: a small box in a corner. subtitle: the game's line at the top. off: no notes.
Config.NoteStyle = "box"
Config.NotePosition = "top right"
Config.NoteSeconds = 3

-- ---- Letters ----
-- gothic: the game's blackletter. book: the game's text letters. plain: the engine's letters.
Config.Letters = "gothic"

return Config
