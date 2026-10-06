-- ============================================================================
-- Mana and health regeneration (module regen of G1R_MegaMod)
-- Set in the settings app or the in-game mod menu; changes count while the game runs.
-- With every amount at 0 (as shipped) nothing regenerates.
-- ============================================================================
local Config = {}

-- ---- Mana regeneration ----
-- Off: mana and health as the game handles them.
Config.Enabled = true
Config.ManaEnabled = true
-- 0 = none. 2 with 60 maximum mana = 1.2 per step.
Config.ManaPercent = 0.0
-- 0 = none.
Config.ManaFlat = 0.0
Config.ManaSeconds = 3.0
Config.ManaUpTo = 100
-- 0 = no wait. Also runs once after loading.
Config.ManaPause = 10
-- 100 = no difference, 0 = nothing.
Config.ManaArmedPercent = 100

-- ---- Mana regeneration by magic circle ----
Config.ManaByCircle = false
Config.ManaCircleNone = 50
-- Before the first circle.
Config.ManaCircleNovice = 75
Config.ManaCircleFirst = 100
-- 100 in the first and 10 here = 150 in the sixth.
Config.ManaCircleStep = 10

-- ---- Health regeneration ----
Config.HealthEnabled = true
-- 0 = none. 1 with 150 maximum health = 1.5 per step.
Config.HealthPercent = 0.0
-- 0 = none.
Config.HealthFlat = 0.0
Config.HealthSeconds = 5.0
Config.HealthUpTo = 100
-- 0 = no wait. Also runs once after loading.
Config.HealthPause = 20
-- 100 = no difference, 0 = nothing.
Config.HealthArmedPercent = 100

-- ---- Mana regeneration and health regeneration: on screen, log ----
-- When it starts after a wait and when it is full.
Config.ShowMessage = false
Config.LogSteps = false

return Config
