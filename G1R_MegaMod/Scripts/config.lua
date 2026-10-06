-- ============================================================================
-- Megamod settings: which modules run, and the diagnostics.
-- The modules keep their own settings in modules/<name>/Scripts/config.lua
-- (the settings app and the in-game mod menu change those; every module also
-- has a switch of its own there that works while the game runs).
-- This file is read once when the game starts. If it is missing or has an
-- error, the values below are used.
-- ============================================================================
local Config = {}

-- false = the module is not loaded at all (it then takes a restart of the
-- game to get it back).
Config.Modules = {
    Repopulate = true,      -- creatures, world items and containers come back; crime switch
    Markers = true,         -- NPC pins on the map screens
    General = true,         -- how notes on screen look
    Regen = true,           -- mana and health regeneration
    Magic = true,           -- magic balancing
    Melee = true,           -- melee animation switches
    Mining = true,          -- ore per swing, how long a vein lasts
    Xp = true,              -- experience multiplier
    Locks = true,           -- lock picking by skill
    Wait = true,            -- skipping time
    Mount = true,           -- the scavenger you ride: whistles watched, put right when it does not come
    Movement = true,        -- how fast the hero swims and the scavenger runs
    Intro = true,           -- the logos at the game's start, the film of a new game
    Keys = true,            -- the list of your keys in the pause menu
    Timers = true,          -- how long effects on you last (a small box)
    OtherMods = true,       -- two distances of other mods (written by the settings app)
}

-- Diagnostics: a small flight recorder in Scripts/diagnostics/ (see the
-- README.txt there). It records what the modules log, errors with their
-- place, and how the modules use the game, so that a problem can be found
-- afterwards without anyone watching the game.
Config.Diagnostics = {
    Level = "normal",          -- "off" | "normal" | "verbose"
    SessionFiles = 5,          -- session logs kept
    FlushSeconds = 20,         -- how often the session log is written out
    ReportMinutes = 5,         -- report-latest.txt is rewritten this often
    SlowCallMs = 30,           -- a module callback slower than this is counted and noted
}
-- Level "off": nothing is written and the modules run exactly as they do as
-- separate mods. "verbose": every line is written at once, and every object
-- search and every registration gets a line (for hunting a crash).

-- The engine. Nothing here is needed for the mod to work.
Config.Engine = {
    -- The game frees objects it no longer needs on a second thread while its
    -- scripts - and the mods - run. A mod's search among all objects that runs
    -- at that moment can read an object that is just being freed; one crash of
    -- 2026-10-05 was that. Since 0.2.2 this mod hardly searches any more, and
    -- waits for a calm moment when it does.
    -- true = the mod also tells the engine to free objects on the main thread
    -- (console variable gc.MultithreadedDestructionEnabled 0, set once after a
    -- map load). That closes the gap for the searches of every mod, at the
    -- price of a little more work on the main thread after an area was
    -- unloaded. It has not been tried in the game yet, so it is off.
    FreeObjectsOnGameThread = false,
}

return Config
