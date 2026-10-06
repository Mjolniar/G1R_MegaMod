-- ============================================================================
-- Experience multiplier (module xp of G1R_MegaMod)
-- Easiest way to change these: the settings app, page "Experience", or the
-- in-game mod menu. Changes are picked up while the game is running.
-- ============================================================================
local Config = {}

-- ---- Experience multiplier ----
-- false = the module does nothing; experience stays as the game gives it.
Config.Enabled = true
-- Every experience gain counts this many times: 2.0 = double, 0.5 = half,
-- 1.0 = unchanged. From 0 to 10.
Config.Multiplier = 1.0

-- ---- Large gains (quests) ----
-- Gains of at least this size use LargeGainMultiplier instead of Multiplier.
-- 0 = every gain uses Multiplier.
Config.LargeGainFrom = 0
-- The multiplier for large gains (only used when LargeGainFrom is above 0).
Config.LargeGainMultiplier = 1.0

-- ---- On screen ----
-- A short note on screen when experience was added. How notes look is set on the page "General".
Config.ShowMessage = true

-- ---- Log ----
-- One line in UE4SS.log for every experience gain.
Config.LogGains = false

return Config
