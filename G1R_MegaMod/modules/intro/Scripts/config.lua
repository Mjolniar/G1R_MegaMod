-- ============================================================================
-- Game start settings (module intro of G1R_MegaMod)
-- Easiest way to change these: the settings app, page "Interface > Game start".
-- Skipping the logos is a line in the game's own Game.ini: the settings app
-- writes it when it saves with the game closed; it counts from the next start.
-- ============================================================================
local Config = {}

-- ---- What plays at the start ----
-- Switches the two settings below on or off.
Config.Enabled = true
-- The logos at the start of the game (Alkimia, THQ Nordic, the legal screen) are skipped. The
-- settings app writes this into the game's Game.ini when it saves with the game closed; it
-- counts from the next start of the game.
Config.SkipLogos = false
-- When you start a new game, its film is not played: the game shows its usual loading screen
-- instead. Loading a save is not touched.
Config.SkipNewGameFilm = false

return Config
