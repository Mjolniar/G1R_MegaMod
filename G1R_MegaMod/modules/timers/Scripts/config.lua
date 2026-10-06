-- ============================================================================
-- Effect timer settings (module timers of G1R_MegaMod)
-- Set in the settings app or the in-game mod menu; changes count while the game runs.
-- ============================================================================
local Config = {}

-- ---- What is shown ----
Config.Enabled = true
-- From food and potions.
Config.ShowFood = true
Config.ShowElements = true
Config.ShowMind = true
Config.ShowLight = true
Config.ShowDrinks = true
-- By the game's own name. Most are short.
Config.ShowOthers = false

-- ---- Where ----
Config.Position = "bottom left"
Config.DistanceX = 24
Config.DistanceY = 200

return Config
