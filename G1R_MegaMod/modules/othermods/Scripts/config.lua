-- ============================================================================
-- Settings of other mods (module othermods of G1R_MegaMod)
-- Easiest way to change these: the settings app, page "Other mods". The app writes
-- them into the other mods' own settings files when it saves with the game closed;
-- they count from the next start of the game.
-- ============================================================================
local Config = {}

-- ---- Highlight (FocusNearbyPickups) ----
-- Switches the settings below on or off; off leaves the other mods' files as they are.
Config.Enabled = true
-- Writes the distance below into FocusNearbyPickups.ini (its maxRadius) when the settings app
-- saves with the game closed. Off: the file is left as it is.
Config.SetHighlight = false
-- How far away FocusNearbyPickups highlights things, in metres (0 = no limit; the mod's own
-- value is 10).
Config.HighlightMeters = 10.0

-- ---- Picking up (G1R_AutoPickUpItemNative) ----
-- Writes the distance below into G1R_AutoPickUpItemNative.ini (its AreaLootingRadius) when the
-- settings app saves with the game closed. Off: the file is left as it is.
Config.SetLoot = false
-- How far away G1R_AutoPickUpItemNative picks items up, in metres (the mod's own value is 5).
Config.LootMeters = 5.0

return Config
