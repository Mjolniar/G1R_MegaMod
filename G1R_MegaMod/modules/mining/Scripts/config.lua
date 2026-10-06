-- ============================================================================
-- Mining rework (module mining of G1R_MegaMod)
-- Set in the settings app or the in-game mod menu; changes count while the game runs.
-- ============================================================================
local Config = {}

-- ---- Mining ----
-- Off: mining as the game has it.
Config.Enabled = true

-- ---- Mining: ore per swing ----
Config.YieldEnabled = false
-- The game: 3.
Config.BaseAmount = 3
-- 0 = Strength does not count. 4 with Strength 30 = 7 more ore.
Config.StrengthPerOre = 0.0
-- 0 = Dexterity does not count. 6 with Dexterity 20 = 3 more ore.
Config.DexterityPerOre = 0.0
Config.TrainedBonus = 0
-- Instead of the trained bonus.
Config.MasterBonus = 0
Config.ExtraChance = 0
-- If the vein holds that much. 0 = a weak hero can get nothing.
Config.MinAmount = 1
Config.MaxAmount = 100
-- 5 or fewer ore left: 1 per swing, as in the game.
Config.LowVeinRule = true

-- ---- Mining: how long a vein lasts ----
-- Refills the vein you swing at, also mined-out ones.
Config.EndlessVeins = false
-- Part of each swing is put back. Not used while veins never run out.
Config.VeinLastsTimes = 1

-- ---- Mining: on screen and in the log ----
-- Than the game would have given.
Config.ShowMessage = true
Config.LogSwings = false

return Config
