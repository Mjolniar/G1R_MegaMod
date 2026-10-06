-- ============================================================================
-- Experience multiplier (module xp of G1R_MegaMod)
-- Set in the settings app or the in-game mod menu; changes count while the game runs.
-- ============================================================================
local Config = {}

-- ---- Experience multiplier ----
-- Off: experience as the game gives it.
Config.Enabled = true
-- 2 = double, 0.5 = half, 1 = unchanged (0 to 10).
Config.Multiplier = 1.0

-- ---- Large gains (quests) ----
-- Gains of at least this size use the large multiplier. 0 = off.
Config.LargeGainFrom = 0
-- Used while 'Large gain from' is above 0.
Config.LargeGainMultiplier = 1.0

-- ---- On screen ----
Config.ShowMessage = true

-- ---- Log ----
Config.LogGains = false

return Config
