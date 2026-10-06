-- ============================================================================
-- Key list settings (module keys of G1R_MegaMod)
-- Easiest way to change these: the settings app, page "Interface > Key list", or the
-- in-game mod menu. Changes are picked up while the game is running.
-- ============================================================================
local Config = {}

-- ---- List of keys ----
-- Switches the list of keys on or off.
Config.Enabled = true
-- The list comes up when this key is pressed and goes when it is pressed again, in the pause
-- menu and while you play; a map load hides it as well. "" = no key: the pause menu then
-- shows the whole list.
Config.ListKey = "F3"
-- While the pause menu is open, a small line at its top left says which key shows the list.
Config.InPauseMenu = true
-- The keys of the other mods the list knows, read from their settings files each time the list
-- comes up; another mod that runs is named with "keys not known".
Config.OtherMods = true
-- The size of the letters of the list and of its line in the pause menu (the notes have 12).
Config.TextSize = 10

return Config
