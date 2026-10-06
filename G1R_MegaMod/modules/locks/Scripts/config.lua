-- ============================================================================
-- Lock picking that follows the hero's skill (module locks of G1R_MegaMod)
-- Set in the settings app or the in-game mod menu; changes count from the next lock.
-- ============================================================================
local Config = {}

-- ---- Lock picking ----
-- Off: locks and picks as the game has them.
Config.Enabled = true

-- ---- Connections taken away ----
-- The game: none. all = every piece moves alone. half / safe: chests only.
Config.UntrainedConnections = "as the game has it"
-- The game: 1.
Config.SkilledConnections = "as the game has it"
-- The game: 2.
Config.MasterConnections = "as the game has it"

-- ---- Lock picks ----
-- The numbers below are then not used.
Config.PicksNeverBreak = false
-- 0 = the game's (2). 1 to 99.
Config.UntrainedWrongMoves = 0
-- 0 = the game's (4). 1 to 99.
Config.SkilledWrongMoves = 0
-- 0 = the game's (6). 1 to 99.
Config.MasterWrongMoves = 0

-- ---- On screen ----
Config.ShowMessage = true

-- ---- Log ----
Config.LogLocks = false

return Config
