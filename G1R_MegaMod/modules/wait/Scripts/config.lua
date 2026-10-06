-- ============================================================================
-- Waiting: skip game time with a key (module wait of G1R_MegaMod)
-- Easiest way to change these: the settings app, page "Time", or the
-- in-game mod menu. Changes are picked up while the game is running.
-- A key is written as "Y", "F6", "CTRL+Y", "SHIFT+NUM_FIVE"; "" = no key.
-- ============================================================================
local Config = {}

-- ---- Waiting ----
-- false = the module does nothing; its keys, buttons and console words skip no time.
Config.Enabled = true
-- Seconds that must pass after a skip before the next one is taken (0 to 60).
-- Keeps a held or doubly pressed key from skipping twice.
Config.Cooldown = 2.0

-- ---- Short wait ----
-- The key for the short wait ("" = none).
Config.ShortKey = ""
-- Minutes of game time the short wait skips (1 to 1440; 1440 = a whole day).
Config.ShortMinutes = 30

-- ---- Long wait ----
-- The key for the long wait ("" = none).
Config.LongKey = ""
-- Minutes of game time the long wait skips (1 to 1440; 240 = four hours).
Config.LongMinutes = 240

-- ---- Wait until morning ----
-- The key that skips to the morning hour ("" = none).
Config.MorningKey = ""
-- The hour (0 to 23) this wait skips to. That is the next time the clock shows that
-- hour: today if it is still ahead, otherwise tomorrow.
Config.MorningHour = 8

-- ---- Wait until evening ----
-- The key that skips to the evening hour ("" = none).
Config.EveningKey = ""
-- The hour (0 to 23) this wait skips to, like the morning hour.
Config.EveningHour = 20

-- ---- When not to wait ----
-- true = no time is skipped while the hero has a weapon drawn.
Config.NotInFight = true
-- true = no time is skipped while the hero is talking to somebody.
Config.NotInConversation = true
-- true = no time is skipped while a cutscene is playing.
Config.NotInCutscene = true
-- true = no time is skipped while the game itself lets no time pass (cutscenes, some menus).
-- The game puts its clock back after a cutscene, so a skip there would be lost.
Config.NotWhenClockStopped = true

-- ---- On screen ----
-- A short note after a skip: how long, and what time it is now. How notes look is set on the page "General".
Config.ShowMessage = true
-- A short note when a skip was not taken, with the reason. The reason is in UE4SS.log in any case.
Config.ShowRefused = false

-- ---- Log ----
-- One line in UE4SS.log for every skip. The first skip after the game started is always written.
Config.LogSkips = false

return Config
