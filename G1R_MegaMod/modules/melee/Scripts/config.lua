-- ============================================================================
-- Melee clean-ups (module melee of G1R_MegaMod)
-- Set in the settings app or the in-game mod menu; changes count while the game runs.
-- ============================================================================
local Config = {}

-- ---- Melee: clean-ups ----
-- Off: what it changed is put back.
Config.Enabled = true
-- The game's option "fake sloppy combos": on, the same direction again chains mirrored swings.
-- off: only real combos chain. game: left as the game has it.
Config.FlowHelper = "game"
-- 100 = unchanged, 0 = none, 200 = twice as long.
Config.HitStop = 100
-- Off: no jolt on melee hits. Other shakes stay.
Config.HitShake = true

-- ---- Melee: on screen ----
Config.ShowMessage = true

return Config
