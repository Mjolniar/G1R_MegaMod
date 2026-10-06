-- ============================================================================
-- Mount settings (module mount of G1R_MegaMod)
-- Set in the settings app or the in-game mod menu; changes count while the game runs.
-- ============================================================================
local Config = {}

-- ---- Its name ----
-- Empty = the game's name. At most 40 letters. Wild scavengers keep theirs.
Config.Name = ""

-- ---- Your scavenger ----
-- Logs every whistle and looks again later.
Config.Enabled = true
-- full: takes the riding block off you, fear off the scavenger, and puts it back to its
-- routine; whistle again. safe: the same, but leaves the riding block (camps mean it). off: only logged.
Config.AutoFix = "full"
Config.WaitSeconds = 8
-- Does what "full" does, at once. "" = none. Console: mount fix.
Config.FixKey = ""
Config.ShowNotes = true

return Config
