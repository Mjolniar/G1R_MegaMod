-- ============================================================================
-- Settings of other mods (module othermods of G1R_MegaMod)
-- Set in the settings app. It writes them into the other mods' files on Save with
-- the game closed; they count from the next start of the game.
-- ============================================================================
local Config = {}

-- ---- Highlight (FocusNearbyPickups) ----
-- Off: the other mods' files are left alone.
Config.Enabled = true
-- Writes FocusNearbyPickups.ini maxRadius.
Config.SetHighlight = false
-- 0 = no limit. The mod's own: 10.
Config.HighlightMeters = 10.0

-- ---- Picking up (G1R_AutoPickUpItemNative) ----
-- Writes G1R_AutoPickUpItemNative.ini AreaLootingRadius.
Config.SetLoot = false
-- The mod's own: 5.
Config.LootMeters = 5.0

return Config
