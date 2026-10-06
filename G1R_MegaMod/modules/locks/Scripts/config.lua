-- ============================================================================
-- Lock picking that follows the hero's skill (module locks of G1R_MegaMod)
-- Easiest way to change these: the settings app, page "Lock picking", or the
-- in-game mod menu. Changes are picked up while the game is running; they take
-- effect with the next lock (never in the middle of one).
-- ============================================================================
local Config = {}

-- ---- Lock picking ----
-- false = the module does nothing; locks and lock picks are as the game has them.
Config.Enabled = true

-- ---- Connections taken away ----
-- Connections taken away from a lock while the hero is untrained in lock picking.
-- "as the game has it" (none), "none", "1", "2", "all" (every piece moves alone), or - for chests,
-- by the lock - "half" (half of the lock's connections) or "safe" (as many as the lock is proven
-- to stay solvable with).
Config.UntrainedConnections = "as the game has it"
-- The same while the hero is skilled (first level of the skill).
-- "as the game has it" (1), "none", "1", "2", "half", "safe" or "all".
Config.SkilledConnections = "as the game has it"
-- The same while the hero is a master (second level of the skill).
-- "as the game has it" (2), "none", "1", "2", "half", "safe" or "all".
Config.MasterConnections = "as the game has it"

-- ---- Lock picks ----
-- true = a lock pick does not break, whatever the hero's skill.
-- The three numbers below are not used then. (A pick that has made a wrong move is still used up
-- when the hero leaves the lock without opening it: that is the game's own rule.)
Config.PicksNeverBreak = false
-- Wrong moves a lock pick takes before it breaks while the hero is untrained.
-- 0 = as the game has it (2). From 1 to 99.
Config.UntrainedWrongMoves = 0
-- The same while the hero is skilled. 0 = as the game has it (4).
Config.SkilledWrongMoves = 0
-- The same while the hero is a master. 0 = as the game has it (6).
Config.MasterWrongMoves = 0

-- ---- On screen ----
-- A short note on screen when the hero starts on a lock that this module changed.
-- How notes look is set on the page "General".
Config.ShowMessage = true

-- ---- Log ----
-- One line in UE4SS.log for every lock the hero starts on, with what was changed for it.
Config.LogLocks = false

return Config
