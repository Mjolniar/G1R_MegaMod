-- ============================================================================
-- Effect timer settings (module timers of G1R_MegaMod)
-- Easiest way to change these: the settings app, page "Interface > Effect timers", or the
-- in-game mod menu. Changes are picked up while the game is running.
-- ============================================================================
local Config = {}

-- ---- What is shown ----
-- Switches the box of timers on or off.
Config.Enabled = true
-- Healing and mana that come over time from food and potions.
Config.ShowFood = true
-- What spells and fire do to you for a while.
Config.ShowElements = true
-- Being knocked out, and sleep, fear or charm cast on you.
Config.ShowMind = true
-- How long your Light spell still burns.
Config.ShowLight = true
-- How long until alcohol and swampweed have worn off.
Config.ShowDrinks = true
-- Other effects of the game that last a while, by the game's own name for them (for the
-- curious; most are short).
Config.ShowOthers = false

-- ---- Where ----
-- The corner of the screen the box sits in.
Config.Position = "bottom left"
-- How far the box is from the left or right edge of the screen.
Config.DistanceX = 24
-- How far the box is from the top or bottom edge of the screen.
Config.DistanceY = 200

return Config
