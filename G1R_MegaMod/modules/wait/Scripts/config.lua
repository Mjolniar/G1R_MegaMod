-- ============================================================================
-- Waiting: skip game time with a key (module wait of G1R_MegaMod)
-- Set in the settings app or the in-game mod menu; changes count while the game runs.
-- A key is written as "Y", "F6", "CTRL+Y", "SHIFT+NUM_FIVE"; "" = no key.
-- ============================================================================
local Config = {}

-- ---- Waiting ----
-- Off: nothing skips time.
Config.Enabled = true
-- Keeps a held key from skipping twice (0 to 60).
Config.Cooldown = 2.0

-- ---- Short wait ----
Config.ShortKey = ""
-- Game minutes (1 to 1440 = a day).
Config.ShortMinutes = 30

-- ---- Long wait ----
Config.LongKey = ""
-- Game minutes (1 to 1440 = a day).
Config.LongMinutes = 240

-- ---- Wait until morning ----
Config.MorningKey = ""
-- The next time the clock shows this hour (0 to 23).
Config.MorningHour = 8

-- ---- Wait until evening ----
Config.EveningKey = ""
-- The next time the clock shows this hour (0 to 23).
Config.EveningHour = 20

-- ---- When not to wait ----
Config.NotInFight = true
Config.NotInConversation = true
Config.NotInCutscene = true
-- Cutscenes, some menus. The game would undo the skip.
Config.NotWhenClockStopped = true

-- ---- On screen ----
-- How long, and the time now.
Config.ShowMessage = true
-- The reason is in UE4SS.log in any case.
Config.ShowRefused = false

-- ---- Log ----
-- The first skip of a run is always logged.
Config.LogSkips = false

return Config
