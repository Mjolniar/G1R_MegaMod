-- ============================================================================
-- Movement settings (module movement of G1R_MegaMod)
-- Easiest way to change these: the settings app, page "Movement", or the
-- in-game mod menu. Changes are picked up while the game is running.
-- ============================================================================
local Config = {}

-- ---- Speeds ----
-- Switches the speed multipliers below on or off; off puts the game's own speeds back.
Config.Enabled = true
-- How fast the hero walks, runs and sneaks: his own speed factor times this (1.00 = as the game
-- has it, 0.50 to 3.00).
Config.HeroSpeed = 1.0
-- How fast the hero swims: the game's three swimming speeds times this (1.00 = as the game has
-- it, 0.50 to 3.00).
Config.SwimSpeed = 1.0
-- How fast the scavenger you ride runs: its own speed factor times this (1.00 = as the game has
-- it, 0.50 to 3.00). It runs that much faster when it follows you, too.
Config.MountSpeed = 1.0
-- A line in UE4SS.log whenever a speed of the game is changed or put back.
Config.LogChanges = false

return Config
