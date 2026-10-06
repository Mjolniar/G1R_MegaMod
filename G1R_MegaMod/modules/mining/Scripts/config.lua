-- ============================================================================
-- Mining rework (module mining of G1R_MegaMod)
-- Easiest way to change these: the settings app, page "Resources", or the
-- in-game mod menu. Changes are picked up while the game is running.
-- With the values the mod ships with, mining stays exactly as the game has it.
-- ============================================================================
local Config = {}

-- ---- Mining ----
-- false = the module does nothing; mining stays as the game has it.
Config.Enabled = true

-- ---- Mining: ore per swing ----
-- true = the ore a swing gives is worked out from the numbers below.
-- false = a swing gives what the game gives (3 ore).
Config.YieldEnabled = false
-- Every swing starts with this much ore. 3 = what the game gives. From 0 to 100.
Config.BaseAmount = 3
-- One more ore for every so many points of the hero's Strength. 0 = Strength does not count.
-- Example: 4 with Strength 30 = 7 more ore per swing.
Config.StrengthPerOre = 0.0
-- One more ore for every so many points of the hero's Dexterity. 0 = Dexterity does not count.
-- Example: 6 with Dexterity 20 = 3 more ore per swing.
Config.DexterityPerOre = 0.0
-- A hero who has learned mining gets this much more ore per swing. 0 = no difference.
Config.TrainedBonus = 0
-- A hero who has mastered mining gets this much more ore per swing, instead of the
-- bonus of a trained miner. 0 = no difference.
Config.MasterBonus = 0
-- The chance that a swing gives one more ore, in percent. 0 = never, 100 = always.
Config.ExtraChance = 0
-- A swing never gives less than this, as long as the vein holds that much.
-- 0 = a weak hero can go away empty-handed. A nearly empty vein gives 1 all the same
-- while the game's rule for it (below) is on.
Config.MinAmount = 1
-- A swing never gives more than this, whatever the numbers above add up to.
Config.MaxAmount = 100
-- true = a vein with 5 or fewer ore left gives 1 ore per swing, as in the game.
-- false = it gives the same as a full vein, down to the last ore.
Config.LowVeinRule = true

-- ---- Mining: how long a vein lasts ----
-- true = the vein the hero swings at is filled up again: it never runs out, and every swing
-- gives the full amount. A vein that was mined out earlier comes back as well.
Config.EndlessVeins = false
-- A vein gives this many times as much ore before it is empty: of what a swing takes,
-- the fitting part is put back. 1 = as the game has it. Not used while veins never run out.
Config.VeinLastsTimes = 1

-- ---- Mining: on screen and in the log ----
-- A short note on screen when a swing gave more or less ore than the game would have given.
-- How notes look is set on the page "General".
Config.ShowMessage = true
-- One line in UE4SS.log for every swing of the pickaxe the module sees.
Config.LogSwings = false

return Config
