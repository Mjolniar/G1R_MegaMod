-- ============================================================================
-- Melee clean-ups (module melee of G1R_MegaMod)
-- Easiest way to change these: the settings app, page "Combat", or the
-- in-game mod menu. Changes are picked up while the game is running.
-- With the values the mod ships with nothing of the game is changed.
-- ============================================================================
local Config = {}

-- ---- Melee: clean-ups ----
-- false = the module does nothing; what it had changed in the game is put back.
Config.Enabled = true
-- The game's own option "fake sloppy combos" (close combat flow helper). With it on, pressing
-- the same attack direction again while a swing ends starts a mirrored follow-up swing:
-- hammering one direction looks like a chain. With it off the same swing simply starts
-- again, and chains only come from real combos (the right direction at the right moment).
-- "game" = the mod leaves the option as the game has it. "off" / "on" = the mod sets it, and
-- sets it again when the game or its own menu changes it; the game stores it in your profile.
Config.FlowHelper = "game"
-- When a melee blow lands, both fighters stand still for a moment (about a twentieth of a
-- second) and then pick up speed again. This is the length of that stop in percent of the
-- game's own: 100 = unchanged, 0 = no stop at all, 50 = half as long, 200 = twice as long.
Config.HitStop = 100
-- false = the camera does not jolt when a melee blow lands or the hero is hit by one.
-- Other camera shakes stay (the game's own option "camera shake" switches all of them).
Config.HitShake = true

-- ---- Melee: on screen ----
-- A note on screen when the mod has changed one of the three in the game or put it back.
-- How notes look is set on the page "General".
Config.ShowMessage = true

return Config
