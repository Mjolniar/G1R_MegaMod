-- ============================================================================
-- Game start (module intro of G1R_MegaMod) - Gothic 1 Remake, UE4SS Lua
--
-- The logos at the start of the game are the start list of the game's loading
-- screen plugin (AsyncLoadingScreen: StartupLoadingScreen.MoviePaths in the
-- game's packed DefaultGame.ini, IN1). They play before any mod runs, so the
-- one way that does not depend on timing is the game's own settings file
-- Game.ini (IN2). The settings app writes those lines when it saves with the
-- game closed; this module never writes the file. It says in UE4SS.log and in
-- the diagnostics whether this start of the game skipped the logos (the
-- plugin's settings object holds the list the start used, IN3) and whether
-- Game.ini skips them at the next start.
--
-- The film of a new game is the game's loading screen of the type "game
-- intro" (IN5): the screen is chosen by the type the game's loading screen
-- helper holds when a map load begins. When the type says "game intro", the
-- module sets the usual type at the very beginning of the map load (IN4, IN6);
-- the game then shows its usual loading screen. Loading a save has another
-- type and is not touched.
--
-- Settings: schema.lua describes them, config.lua holds them; the settings
-- app changes them. Not in the in-game menu: the logos cannot be changed
-- while the game runs.
-- ============================================================================

local VERSION = "1.0.0"
local TAG = "G1R_Intro"

local KIT, SETTINGS = G1R_KIT, G1R_SETTINGS
-- Diagnostics handle of the loader; nil when the diagnostics are off, and then
-- nothing behind `if DIAG` runs.
local DIAG = G1R_DIAG
if type(KIT) ~= "table" or type(SETTINGS) ~= "table" then
    print("[" .. TAG .. "] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started" .. string.char(10))
    return
end
if DIAG then pcall(DIAG.version, VERSION) end

local pcall, type, tostring, ipairs = pcall, type, tostring, ipairs
local L = KIT.logger(TAG, print)
local log = L.log

local SCRIPT_DIR = (function()
    local ok, src = pcall(function() return debug.getinfo(1, "S").source end)
    if ok and type(src) == "string" then
        local p = src:gsub("^@", ""):gsub(string.char(92), "/")
        local d = p:match("^(.*/)[^/]+$")
        if d then return d end
    end
    return "./"
end)()

-- ---------------------------------------------------------------------------
-- What the module knows about the game (dev/facts/intro.md)
-- ---------------------------------------------------------------------------
local LOGOS = { "Alkimia_Logo", "THQNordic_Logo", "V_LegalScreen" }                  -- the logos of the start list (IN1)
local SCREEN_SETTINGS = "/Script/AsyncLoadingScreen.Default__LoadingScreenSettings"   -- StartupLoadingScreen.MoviePaths (IN3)
local SUBSYSTEMS = "/Script/Engine.Default__SubsystemBlueprintLibrary"              -- GetEngineSubsystem(Class) (IN4)
local HELPER = "LoadingScreenHelperSubsystem"                                       -- /Script/G1R, an engine subsystem (IN4)
local GAME_INTRO, USUAL = 2, 0                                                      -- ELoadingScreenType GameIntro / Default (IN5)
local TYPES = { [0] = "default", [1] = "black screen", [2] = "game intro", [3] = "story recap" }
local MARK = "G1R_MegaMod: skip the logos at game start"                            -- the settings app's lines in Game.ini (IN2)
local INI = "/G1R/Saved/Config/Windows/Game.ini"                                    -- below %LOCALAPPDATA%
local TRIES = 3             -- failures in a row before the film part is given up for this run

-- ---------------------------------------------------------------------------
-- Settings (not in the in-game menu)
-- ---------------------------------------------------------------------------
local Settings, problem = SETTINGS.open({ module = "intro", dir = SCRIPT_DIR, log = log, menu = false })
if not Settings then
    log("the settings could not be set up (" .. tostring(problem) .. "); not started")
    return
end
local Cfg = Settings.values

-- ---------------------------------------------------------------------------
-- State of this run
-- ---------------------------------------------------------------------------
local S = {
    fileDue = true,         -- Game.ini is looked at at the next look (at the start, after a change of the settings)
    file = nil,             -- what Game.ini says: "written" | "not written"; nil = not looked at, or not readable
    started = nil,          -- what this start of the game played: "logos skipped" | "logos played" | "not readable"
    startList = nil,        -- the start list as it was read
    helperLooked = false,   -- the paths of the film part were looked up (at a quiet moment, never inside a map load)
    films = 0,              -- films of a new game skipped in this run
    lastType = nil,         -- the loading screen type at the last map load (while the film setting is on)
    fails = 0, off = false, -- the film part: failures in a row; given up for this run
}
local Noted = {}
local function note(key, value, detail)
    if DIAG and Noted[key] ~= value then
        Noted[key] = value
        DIAG.note(key, value, detail)
    end
end
local function firstLine(text) return (tostring(text):match("^[^\r\n]*") or "") end
local function wantLogos() return Cfg.Enabled == true and Cfg.SkipLogos == true end
local function wantFilm() return Cfg.Enabled == true and Cfg.SkipNewGameFilm == true end

-- ---------------------------------------------------------------------------
-- The logos: Game.ini (read only) and the start list this start used
-- ---------------------------------------------------------------------------
-- Game.ini's path, or nil (no LOCALAPPDATA).
local function iniPath()
    local ok, base = pcall(os.getenv, "LOCALAPPDATA")
    if not ok or type(base) ~= "string" or base == "" then return nil end
    return (base:gsub(string.char(92), "/")) .. INI
end
-- What Game.ini says: "written" (the settings app's lines are there) or "not written" (no file, no lines);
-- nil and why when it cannot be read.
local function readIni()
    local path = iniPath()
    if not path then return nil, "no LOCALAPPDATA" end
    local f = io.open(path, "rb")
    if not f then return "not written" end
    local ok, text = pcall(f.read, f, "a")
    pcall(f.close, f)
    if not ok or type(text) ~= "string" then return nil, "Game.ini cannot be read" end
    -- (a file the engine wrote in UTF-16: its ASCII is every other byte)
    if text:sub(1, 2) == string.char(255, 254) then text = text:gsub(string.char(0), "") end
    local begins = text:find(MARK .. " (begin)", 1, true)
    local ends = text:find(MARK .. " (end)", 1, true)
    if begins and ends and ends > begins then return "written" end
    return "not written"
end
local function lookAtFile()
    local state, why = readIni()
    S.file = state
    note("intro.logos_file", state or "not readable", why)
    if state == nil then
        L.once("file:unreadable", "Game.ini cannot be looked at (" .. tostring(why) .. ")")
        return
    end
    if wantLogos() and state ~= "written" then
        L.once("file:missing", "the logos are to be skipped, but Game.ini does not say so yet: the settings app writes it when it saves with the game closed (it counts from the next start of the game)")
    elseif not wantLogos() and state == "written" then
        L.once("file:left", "Game.ini still skips the logos: the settings app takes that out when it saves with the game closed")
    end
end

local function text(v)
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    return nil
end
-- What this start of the game played: the start list of the loading screen plugin's settings object (IN3).
local function lookAtStart()
    local cdo = KIT.findOnce(SCREEN_SETTINGS)
    local list = cdo and KIT.get(KIT.get(cdo, "StartupLoadingScreen"), "MoviePaths") or nil
    local names = {}
    local n = list and KIT.each(list, function(v) names[#names + 1] = text(v) or "?" end) or nil
    if not n then
        S.started = "not readable"
        note("intro.start_movies", "not readable", cdo and "MoviePaths cannot be read" or "the settings object of the loading screen was not found")
        L.once("start:unreadable", "the start list of the game's loading screen cannot be read: whether this start skipped the logos is not known")
        return
    end
    local played = false
    for _, name in ipairs(names) do
        for _, logo in ipairs(LOGOS) do
            if name == logo then played = true end
        end
    end
    S.started, S.startList = played and "logos played" or "logos skipped", table.concat(names, ", ")
    note("intro.start_movies", S.started, S.startList)
    if played then
        log("this start of the game played the logos (" .. S.startList .. ")")
    else
        log("this start of the game skipped the logos (it played: " .. (S.startList ~= "" and S.startList or "nothing") .. ")")
    end
end

-- ---------------------------------------------------------------------------
-- The film of a new game: the game's loading screen helper
-- ---------------------------------------------------------------------------
-- The helper (IN4), or nil, why, and whether that will not change in this run.
local function helper()
    local library = KIT.findOnce(SUBSYSTEMS)
    if not library then return nil, "the subsystem library was not found", true end
    local class = KIT.findClass(HELPER, "G1R")
    if not class then return nil, "the class " .. HELPER .. " was not found", true end
    local o = KIT.call(library, "GetEngineSubsystem", class)
    if not KIT.valid(o) or KIT.isDefaultName(KIT.fullName(o)) then return nil, "the engine has no " .. HELPER, false end
    return o
end
local function giveUp(why)
    S.off = true
    note("intro.helper", "not available", why)
    L.once("film:off", "the game's loading screen helper is not there (" .. tostring(why) .. "); the film of a new game is left to the game for this run")
end
local function filmFailed(what, why)
    S.fails = S.fails + 1
    note("intro.film", "fails", why)
    if S.fails >= TRIES then
        S.off = true
        L.once("film:fails", what .. " (" .. tostring(why) .. "); the film of a new game is left to the game for this run")
    end
end
local function typeOf(h)
    local ok, t = KIT.try(h, "GetCurrentLoadingScreenType")
    if not ok then return nil, firstLine(t) end
    t = KIT.number(KIT.unwrap(t))
    if t == nil then return nil, "not a number" end
    return t
end
-- At the beginning of a map load: a new game's film becomes the usual loading screen.
local function beforeLoad()
    if not wantFilm() or S.off or not S.helperLooked then return end
    local h, why, final = helper()
    if not h then
        if final then return giveUp(why) end
        return filmFailed("the game's loading screen helper was not there", why)
    end
    note("intro.helper", "found")
    local t, why2 = typeOf(h)
    if t == nil then return filmFailed("the type of the game's loading screen cannot be read", why2) end
    S.lastType = t
    note("intro.loading_type", TYPES[t] or tostring(t))
    if t ~= GAME_INTRO then
        S.fails = 0
        return
    end
    local ok, err = KIT.try(h, "SetCurrentLoadingScreenType", USUAL)
    local back = typeOf(h)
    if not ok or back ~= USUAL then
        return filmFailed("the film of a new game could not be skipped", ok and ("the type stayed " .. tostring(back)) or firstLine(err))
    end
    S.fails, S.films = 0, S.films + 1
    note("intro.film", "skipped")
    log("a new game starts: its film is skipped (the game's usual loading screen instead)")
end

-- ---------------------------------------------------------------------------
-- The loop: Game.ini at the start and after a change; the game's side only
-- when a setting needs it, never while a map loads, and not before a map load
-- has handed over the engine (the menu is up).
-- ---------------------------------------------------------------------------
local function tick()
    if KIT.loading() then return end
    if S.fileDue then
        S.fileDue = false
        lookAtFile()
    end
    if not KIT.engine() then return end
    if wantLogos() and S.started == nil then lookAtStart() end
    if wantFilm() and not S.helperLooked and not S.off then
        S.helperLooked = true
        local h, why, final = helper()
        if h then note("intro.helper", "found")
        elseif final then giveUp(why)
        else note("intro.helper", "not there yet", why) end
    end
end

-- ---------------------------------------------------------------------------
-- Status (console, the loader's reports), console words, settings
-- ---------------------------------------------------------------------------
local function summary()
    if not Cfg.Enabled then return "switched off" end
    if not Cfg.SkipLogos and not Cfg.SkipNewGameFilm then return "the game starts as it has it" end
    return (Cfg.SkipLogos and "logos skipped (through Game.ini, from the next start)" or "logos as the game has them")
        .. ", " .. (Cfg.SkipNewGameFilm and "the film of a new game skipped" or "the film of a new game as the game has it")
end
local function statusLines()
    local lines = { ("v%s | %s"):format(VERSION, summary()) }
    if S.file then
        lines[#lines + 1] = S.file == "written" and "Game.ini: the logos are skipped from the next start of the game" or "Game.ini: does not skip the logos"
    end
    if S.started then lines[#lines + 1] = "this start of the game: " .. S.started .. (S.startList and (" (" .. S.startList .. ")") or "") end
    if wantFilm() or S.films > 0 then lines[#lines + 1] = ("films of a new game skipped: %d"):format(S.films) end
    if S.lastType then lines[#lines + 1] = "loading screen at the last map load: " .. (TYPES[S.lastType] or tostring(S.lastType)) end
    if S.off then lines[#lines + 1] = "the film of a new game: left to the game for this run" end
    return lines
end

-- intro           status
-- intro reload    read config.lua now
local function console(fullCommand, params, device)
    local args = {}
    if type(params) == "table" then
        for _, p in ipairs(params) do args[#args + 1] = tostring(p) end
    elseif type(fullCommand) == "string" then
        for w in fullCommand:gmatch("%S+") do args[#args + 1] = w end
        table.remove(args, 1)
    end
    local lines
    if (args[1] or ""):lower() == "reload" then
        local ok, why = Settings:reload(true)
        lines = { ok and ("settings read: " .. summary()) or ("settings not read: " .. tostring(why)) }
    else
        lines = statusLines()
    end
    for _, l in ipairs(lines) do
        log(l)
        if device ~= nil then pcall(function() device:Log("[" .. TAG .. "] " .. l) end) end
    end
    return true
end

Settings.onChange = function(_, _, why)
    S.fileDue = true            -- Game.ini is looked at again at the next look
    log(("settings changed (%s): %s"):format(why == "file" and "config.lua" or tostring(why), summary()))
end

-- ---------------------------------------------------------------------------
-- Registration (each exactly once)
-- ---------------------------------------------------------------------------
KIT.onWorldChange(function(phase)
    if phase ~= "before" then return end
    local ok, err = pcall(beforeLoad)
    if not ok then L.once("load:" .. tostring(err), "map load error: " .. tostring(err)) end
end)
for _, name in ipairs({ "intro", "g1r_intro" }) do
    if type(RegisterConsoleCommandHandler) == "function" then
        pcall(RegisterConsoleCommandHandler, name, console)
    end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; the game starts as it has it.")
else
    LoopInGameThreadWithDelay(1000, function()
        local ok, err = pcall(tick)
        if not ok then L.once("tick:" .. tostring(err), "update error: " .. tostring(err)) end
    end)
end

log(("v%s loaded: %s"):format(VERSION, summary()))

if DIAG then
    pcall(function()
        DIAG.status(statusLines)
        DIAG.dump(function()
            return {
                version = VERSION, enabled = Cfg.Enabled, skip_logos = Cfg.SkipLogos, skip_film = Cfg.SkipNewGameFilm,
                file = S.file, started = S.started, start_list = S.startList, films = S.films, last_type = S.lastType,
                film_fails = S.fails, film_off = S.off,
            }
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "INTRO_TEST")) == "table" then
    local T = rawget(_G, "INTRO_TEST")
    T.state, T.console, T.status, T.tick, T.settings = S, console, statusLines, tick, Settings
end
