-- ============================================================================
-- Mount settings (module mount of G1R_MegaMod)
-- Easiest way to change these: the settings app, page "Mount", or the
-- in-game mod menu. Changes are picked up while the game is running.
-- ============================================================================
local Config = {}

-- ---- Its name ----
-- Shown over your scavenger instead of the game's name; empty = the game's name.
-- At most 40 letters. Wild scavengers keep theirs.
Config.Name = ""

-- ---- Your scavenger ----
-- Every whistle for the scavenger is written to the log with what the game says about you and
-- about it, and again a few seconds later with how far away it is then.
Config.Enabled = true
-- What is done when the scavenger has not come closer a few seconds after a whistle.
-- "full" = a riding block on you is taken off, fear is taken off the scavenger and it is put
-- back to its idle routine - whistle again; "safe" = the same without touching the riding
-- block (inside a camp the game means it); "off" = only written down.
Config.AutoFix = "full"
-- How long after a whistle the scavenger's distance is looked at again (4 to 20 seconds).
Config.WaitSeconds = 8
-- A key that does what "full" does, at once and whether a whistle was seen or not
-- ("" = none). The console words do the same: mount, mount fix.
Config.FixKey = ""
-- A short note on screen when something was put right.
Config.ShowNotes = true

return Config
