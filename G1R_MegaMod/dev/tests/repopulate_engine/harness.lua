-- G1R_Repopulate the way it works in the game: the engine object is handed over
-- at a map load, the engine's function libraries and the game's own getters
-- answer, and the game's begin / end of play calls arrive for every actor.
-- The scenarios are the ones of ../repopulate/harness.lua, run in its "engine"
-- mode; what differs between the two modes is marked ENGINE there.
rawset(_G, "G1R_REPOP_MODE", "engine")
dofile((debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./") .. "../repopulate/harness.lua")
