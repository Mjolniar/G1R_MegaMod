-- ============================================================================
-- Game start settings (module intro of G1R_MegaMod)
-- Set in the settings app. Skipping the logos is a line in the game's Game.ini:
-- the app writes it on Save with the game closed; it counts from the next start.
-- ============================================================================
local Config = {}

-- ---- What plays at the start ----
Config.Enabled = true
-- Alkimia, THQ Nordic, the legal screen. Counts from the next start.
Config.SkipLogos = false
Config.SkipNewGameFilm = false

return Config
