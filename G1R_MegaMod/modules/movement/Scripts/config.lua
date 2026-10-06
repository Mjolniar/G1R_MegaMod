-- ============================================================================
-- Movement settings (module movement of G1R_MegaMod)
-- Set in the settings app or the in-game mod menu; changes count while the game runs.
-- ============================================================================
local Config = {}

-- ---- Speeds ----
-- Off: the game's own speeds.
Config.Enabled = true
-- Walking, running, sneaking (0.50 to 3.00).
Config.HeroSpeed = 1.0
-- 0.50 to 3.00.
Config.SwimSpeed = 1.0
-- Ridden and following you (0.50 to 3.00).
Config.MountSpeed = 1.0
Config.LogChanges = false

return Config
