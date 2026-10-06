-- ============================================================================
-- Offline tests of the module intro (modules/intro/Scripts/main.lua).
--
--   lua5.4 harness.lua          (from any directory)
--
-- The module runs on the loader's kit and settings service; ../lib/modtest.lua
-- sets both up the way the loader does and replaces UE4SS by ../mock/ue4ss.lua.
-- The game is the model below: the settings object of the loading screen
-- plugin with the start list (dev/facts/intro.md IN1, IN3), the game's loading
-- screen helper with its type (IN4, IN5), handed out by the engine's subsystem
-- library, and Game.ini below a %LOCALAPPDATA% of the tests (IN2; os.getenv
-- answers it while the cases run). Nothing of it has been seen in the game for
-- this module.
-- Last line: "intro tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*/)") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("intro")
local check, section, printed, printedCount = T.check, T.section, T.printed, T.printedCount
local NL, CRLF, BS = string.char(10), string.char(13, 10), string.char(92)

local SETTINGS_CDO = "/Script/AsyncLoadingScreen.Default__LoadingScreenSettings"
local LIBRARY = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local HELPER_CLASS = "/Script/G1R.LoadingScreenHelperSubsystem"
local START = { "Alkimia_Logo", "THQNordic_Logo", "V_LegalScreen", "LoopingEngineLoadScreen" }

-- %LOCALAPPDATA% of the tests (false = there is none)
local realGetenv = os.getenv
local LOCAL = T.TMP .. "/local"
local INI_DIR = LOCAL .. "/G1R/Saved/Config/Windows"
local INI = INI_DIR .. "/Game.ini"
local Env = { LOCALAPPDATA = LOCAL }
os.getenv = function(name)
    if Env[name] ~= nil then return Env[name] or nil end
    return realGetenv(name)
end

-- The lines the settings app writes into Game.ini (app/src/GameStart.cs), behind what the file held.
local BEGIN = "; ---- G1R_MegaMod: skip the logos at game start (begin) ----"
local END = "; ---- G1R_MegaMod: skip the logos at game start (end) ----"
local function appIni(before)
    return (before or "") .. BEGIN .. CRLF .. "[/Script/AsyncLoadingScreen.LoadingScreenSettings]" .. CRLF
        .. 'StartupLoadingScreen=(MinimumLoadingScreenDisplayTime=-1.000000,MoviePaths=("LoopingEngineLoadScreen"))' .. CRLF .. END .. CRLF
end
-- The same text the way the engine writes a file that is not plain text: UTF-16 with its mark.
local function utf16(s)
    local out = { string.char(255, 254) }
    for i = 1, #s do out[#out + 1] = s:sub(i, i) .. string.char(0) end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- The game model
-- ---------------------------------------------------------------------------
-- options: start (the start list; false = no settings object), plainStrings (the list hands out Lua strings),
-- odd (one more element that is no text), noLibrary, noClass, noHelper (the engine has none), cdoHelper (the engine
-- hands out the class's default object), getRaises, typeText (the type comes as a text), setRaises, setNoTake (the
-- type stays). While a case runs: world.type (the helper's type), world.noHelper, world.getRaises.
-- A map load plays the film when the type is "game intro" at the moment the game sets its loading screen up: that
-- screen sets the type back to the usual one (IN5). world.films counts the films the game played.
local function fstring(s) return { ToString = function() return s end } end
local function newWorld(ue, o)
    o = o or {}
    local world = T.newWorld(ue)
    world.calls, world.type, world.films = {}, 0, 0
    local function called(name) world.calls[name] = (world.calls[name] or 0) + 1 end
    world.viewport = ue:object("GameViewportClient /Engine/Transient.GothicGameEngine_0:GameViewportClient_0", { World = world.world })
    world.engine = ue:object("GothicGameEngine /Engine/Transient.GothicGameEngine_0", { GameViewport = world.viewport })
    if o.start ~= false then
        local items = {}
        for i, n in ipairs(o.start or START) do items[i] = o.plainStrings and n or fstring(n) end
        if o.odd then items[#items + 1] = {} end
        ue.objects[SETTINGS_CDO] = ue:object("LoadingScreenSettings " .. SETTINGS_CDO, {
            StartupLoadingScreen = setmetatable({}, { __index = function(_, k)
                called("start:" .. tostring(k))
                if k == "MoviePaths" then return T.array(items) end
            end }) })
    end
    world.helper = ue:object("LoadingScreenHelperSubsystem /Engine/Transient.GothicGameEngine_0.LoadingScreenHelperSubsystem_0", {
        GetCurrentLoadingScreenType = function()
            called("get")
            if o.getRaises or world.getRaises then error("type not readable") end
            if o.typeText then return "GameIntro" end
            return world.type
        end,
        SetCurrentLoadingScreenType = function(_, t)
            called("set")
            world.setTo = t
            if o.setRaises then error("cannot set the type") end
            if not o.setNoTake then world.type = t end
        end,
    })
    if not o.noClass then ue.objects[HELPER_CLASS] = ue:object("Class " .. HELPER_CLASS, {}) end
    if not o.noLibrary then
        ue.objects[LIBRARY] = ue:object("SubsystemBlueprintLibrary " .. LIBRARY, {
            GetEngineSubsystem = function(_, class)
                called("GetEngineSubsystem")
                world.askedFor = class
                if o.noHelper or world.noHelper then return ue:invalid() end
                if o.cdoHelper then return ue:object("LoadingScreenHelperSubsystem /Script/G1R.Default__LoadingScreenHelperSubsystem", {}) end
                return world.helper
            end,
        })
    end
    -- a map load as UE4SS reports it (the engine object first); `during` runs between the two hooks
    function world.load(during)
        ue:fireLoadMapPre(world.engine, "world", "url", nil, "")
        if world.type == 2 then world.films, world.type = world.films + 1, 0 end      -- the game sets its loading screen up
        if during then during() end
        ue:fireLoadMapPost(world.engine, "world", "url", nil, "")
    end
    return world
end

-- ini: the text of Game.ini (nil = no file)
local function boot(case, o, config, ini)
    o = o or {}
    T.sh("rm -rf " .. T.q(LOCAL) .. " && mkdir -p " .. T.q(INI_DIR))
    if ini then T.write(INI, ini) end
    return T.boot(case, { module = "intro", hook = "INTRO_TEST", config = config, diag = o.diag ~= false,
        prepare = function(ue) return newWorld(ue, o) end })
end
local function cfg(lines) return T.config(table.concat(lines, NL)) end
local function status(c) return table.concat(c.hook.status(), " | ") end
local function calls(c, name) return c.world.calls[name] or 0 end
local function lookups(c, path)
    local n = 0
    for _, p in ipairs(c.ue.lookups) do if p == path then n = n + 1 end end
    return n
end
local LOGOS_ON = { "Config.SkipLogos = true" }
local FILM_ON = { "Config.SkipNewGameFilm = true" }

-- ================================================================ load
section("load: the shipped settings leave the game alone")
do
    local c = boot("load")
    check(c.ok, "the module loads (" .. tostring(c.err) .. ")")
    check(printed(c.ue, "[G1R_Intro] v1.0.0 loaded: the game starts as it has it") ~= nil, "load line: " .. tostring(printed(c.ue, "loaded:")))
    check(c.ue.console.intro ~= nil and c.ue.console.g1r_intro ~= nil, "console words intro / g1r_intro registered")
    check(#c.ue.loops == 2 and c.ue.loops[2].ms == 1000, "its loop (once a second) and the loader's")
    local index = c.mods.store["SMM:index"]
    check(index == nil or not T.has(index, "Game start"), "not in the in-game menu (" .. tostring(index) .. ")")
    c.ticks(2)
    check(c.fake.value("intro.logos_file") == "not written", "Game.ini is looked at once at the start (no file: not written)")
    c.world.load()
    c.world.type = 2
    c.world.load()
    c.seconds(10)
    check(T.searches(c) == 0 and calls(c, "GetEngineSubsystem") == 0 and calls(c, "get") == 0 and calls(c, "set") == 0 and calls(c, "start:MoviePaths") == 0,
        "with both settings off the game is not looked at: nothing searched, nothing asked, nothing set")
    check(c.world.films == 1 and c.fake.value("intro.film") == nil and c.fake.value("intro.start_movies") == nil, "a new game plays its film; nothing noted about the game")
    check(printed(c.ue, "Game.ini") == nil, "nothing to say about Game.ini")
    check(status(c) == "v1.0.0 | the game starts as it has it | Game.ini: does not skip the logos", "status: " .. status(c))
    T.stop(c)
end

section("load: the kit without the settings service, a schema that cannot be used")
do
    local ue = T.Mock.new()
    ue:install()
    rawset(_G, "G1R_KIT", {})
    local ok = pcall(dofile, T.MOD .. "modules/intro/Scripts/main.lua")
    check(ok and T.printed(ue, "[G1R_Intro] this module needs the loader of G1R_MegaMod") ~= nil and #ue.loops == 0, "the kit alone: says so, registers nothing")
    rawset(_G, "G1R_KIT", nil)
    ue:uninstall()
    T.sh("rm -rf " .. T.q(LOCAL) .. " && mkdir -p " .. T.q(INI_DIR))
    local c = T.boot("badschema", { module = "intro", hook = "INTRO_TEST", diag = true, files = { ["Scripts/schema.lua"] = "return 5" .. NL },
        prepare = function(u) return newWorld(u) end })
    check(c.ok and printed(c.ue, "[G1R_Intro] the settings could not be set up (") ~= nil and printed(c.ue, "); not started") ~= nil
        and #c.ue.loops == 1 and c.ue.console.intro == nil, "a schema that cannot be used: said, nothing registered")
    T.stop(c)
end

-- ================================================================ the logos
section("the logos: Game.ini without the app's lines, and this start played them")
do
    local c = boot("logos-missing", {}, cfg(LOGOS_ON), "[/Script/Engine.Engine]" .. CRLF .. "bSmoothFrameRate=True" .. CRLF)
    check(printed(c.ue, "loaded: logos skipped (through Game.ini, from the next start), the film of a new game as the game has it") ~= nil, "load line names the setting")
    c.ticks(2)
    check(c.fake.value("intro.logos_file") == "not written", "Game.ini (with other lines) does not skip the logos")
    check(printedCount(c.ue, "the logos are to be skipped, but Game.ini does not say so yet: the settings app writes it when it saves with the game closed") == 1,
        "said once in UE4SS.log")
    check(calls(c, "start:MoviePaths") == 0 and lookups(c, SETTINGS_CDO) == 0, "before a map load has handed over the engine the game is not looked at")
    c.world.load(function()
        c.ticks(4)
        check(lookups(c, SETTINGS_CDO) == 0, "nor while a map loads")
    end)
    c.ticks(1)
    check(lookups(c, SETTINGS_CDO) == 1 and c.fake.value("intro.start_movies") == "logos played"
        and c.fake.detail("intro.start_movies") == "Alkimia_Logo, THQNordic_Logo, V_LegalScreen, LoopingEngineLoadScreen",
        "after the first map load: the start list of the plugin's settings object is read (looked up once): the logos were played")
    check(printedCount(c.ue, "this start of the game played the logos (Alkimia_Logo, THQNordic_Logo, V_LegalScreen, LoopingEngineLoadScreen)") == 1, "said in UE4SS.log")
    local reads = calls(c, "start:MoviePaths")
    c.seconds(20)
    c.world.load()
    c.seconds(5)
    check(calls(c, "start:MoviePaths") == reads and reads == 1 and lookups(c, SETTINGS_CDO) == 1, "read once per run")
    check(printedCount(c.ue, "Game.ini does not say so yet") == 1, "the missing lines are said once")
    check(status(c) == "v1.0.0 | logos skipped (through Game.ini, from the next start), the film of a new game as the game has it | Game.ini: does not skip the logos"
        .. " | this start of the game: logos played (Alkimia_Logo, THQNordic_Logo, V_LegalScreen, LoopingEngineLoadScreen)", "status: " .. status(c))
    T.stop(c)
end

section("the logos: Game.ini has the app's lines, and this start skipped them")
do
    local c = boot("logos-written", { start = { "LoopingEngineLoadScreen" } }, cfg(LOGOS_ON), appIni("[/Script/Engine.Engine]" .. CRLF .. "bSmoothFrameRate=True" .. CRLF))
    c.ticks(1)
    c.world.load()
    c.ticks(1)
    check(c.fake.value("intro.logos_file") == "written" and c.fake.value("intro.start_movies") == "logos skipped" and c.fake.detail("intro.start_movies") == "LoopingEngineLoadScreen",
        "Game.ini skips the logos; the start list held only the engine's loading picture")
    check(printed(c.ue, "this start of the game skipped the logos (it played: LoopingEngineLoadScreen)") ~= nil, "said in UE4SS.log")
    check(printed(c.ue, "does not say so yet") == nil and printed(c.ue, "still skips") == nil, "nothing to say about Game.ini")
    check(status(c) == "v1.0.0 | logos skipped (through Game.ini, from the next start), the film of a new game as the game has it"
        .. " | Game.ini: the logos are skipped from the next start of the game | this start of the game: logos skipped (LoopingEngineLoadScreen)", "status: " .. status(c))
    T.stop(c)

    c = boot("logos-utf16", { start = {}, plainStrings = true }, cfg(LOGOS_ON), utf16(appIni("[/Script/Engine.Engine]" .. CRLF)))
    c.ticks(1)
    c.world.load()
    c.ticks(1)
    check(c.fake.value("intro.logos_file") == "written", "a Game.ini in UTF-16 (the engine's way for text that is not plain): the lines are found")
    check(c.fake.value("intro.start_movies") == "logos skipped" and printed(c.ue, "it played: nothing)") ~= nil, "an empty start list: skipped, nothing played")
    T.stop(c)

    c = boot("logos-plain", { plainStrings = true, odd = true }, cfg(LOGOS_ON), BEGIN .. CRLF .. "[x]" .. CRLF)
    c.ticks(1)
    c.world.load()
    c.ticks(1)
    check(c.fake.value("intro.logos_file") == "not written", "only the first line of the app's lines: not written")
    check(c.fake.value("intro.start_movies") == "logos played", "a list of plain Lua strings is read as well")
    check(c.fake.detail("intro.start_movies") == "Alkimia_Logo, THQNordic_Logo, V_LegalScreen, LoopingEngineLoadScreen, ?", "an element that is no text: a question mark ("
        .. tostring(c.fake.detail("intro.start_movies")) .. ")")
    T.stop(c)

    c = boot("logos-order", {}, cfg(LOGOS_ON), END .. CRLF .. BEGIN .. CRLF)
    c.ticks(1)
    check(c.fake.value("intro.logos_file") == "not written", "the two lines the wrong way round: not written")
    T.stop(c)
end

section("the logos: setting off, Game.ini still has the app's lines")
do
    local c = boot("logos-left", {}, nil, appIni())
    c.ticks(2)
    check(c.fake.value("intro.logos_file") == "written" and printedCount(c.ue, "Game.ini still skips the logos: the settings app takes that out when it saves with the game closed") == 1,
        "said once")
    c.world.load()
    c.seconds(5)
    check(lookups(c, SETTINGS_CDO) == 0 and c.fake.value("intro.start_movies") == nil, "the game is not looked at")
    T.stop(c)
end

section("the logos: what cannot be read")
do
    local c = boot("logos-nocdo", { start = false }, cfg(LOGOS_ON))
    c.ticks(1)
    c.world.load()
    c.seconds(5)
    check(c.fake.value("intro.start_movies") == "not readable" and c.fake.detail("intro.start_movies") == "the settings object of the loading screen was not found"
        and lookups(c, SETTINGS_CDO) == 1, "no settings object: not readable, looked up once")
    check(printedCount(c.ue, "the start list of the game's loading screen cannot be read") == 1, "said once")
    T.stop(c)

    Env.LOCALAPPDATA = false
    c = boot("logos-noenv", {}, cfg(LOGOS_ON))
    c.ticks(2)
    check(c.fake.value("intro.logos_file") == "not readable" and c.fake.detail("intro.logos_file") == "no LOCALAPPDATA"
        and printedCount(c.ue, "Game.ini cannot be looked at (no LOCALAPPDATA)") == 1 and printed(c.ue, "does not say so yet") == nil, "no LOCALAPPDATA: not readable, said once, nothing else said")
    check(not T.has(status(c), "Game.ini:"), "the status says nothing about the file")
    T.stop(c)

    -- a LOCALAPPDATA written the Windows way
    Env.LOCALAPPDATA = LOCAL:gsub("/local$", BS .. "local")
    c = boot("logos-backslash", {}, cfg(LOGOS_ON), appIni())
    c.ticks(1)
    check(c.fake.value("intro.logos_file") == "written", "a LOCALAPPDATA with backslashes is used with slashes")
    T.stop(c)
    Env.LOCALAPPDATA = LOCAL

    -- a Game.ini that is a folder: io.open works, reading does not
    T.sh("rm -rf " .. T.q(LOCAL) .. " && mkdir -p " .. T.q(INI))
    c = T.boot("logos-folder", { module = "intro", hook = "INTRO_TEST", config = cfg(LOGOS_ON), diag = true, prepare = function(ue) return newWorld(ue) end })
    c.ticks(1)
    check(c.fake.value("intro.logos_file") == "not readable" or c.fake.value("intro.logos_file") == "not written", "a Game.ini that cannot be read is not taken for the app's lines ("
        .. tostring(c.fake.value("intro.logos_file")) .. ")")
    T.stop(c)
end

-- ================================================================ the film
section("the film of a new game: the type of the game's loading screen")
do
    local c = boot("film", {}, cfg(FILM_ON))
    check(printed(c.ue, "loaded: logos as the game has them, the film of a new game skipped") ~= nil, "load line names the setting")
    c.ticks(4)
    check(calls(c, "GetEngineSubsystem") == 0 and lookups(c, HELPER_CLASS) == 0, "before a map load has handed over the engine: nothing looked up")
    -- the first map load (the menu): nothing is looked up inside it
    c.world.type = 0
    c.world.load()
    check(calls(c, "GetEngineSubsystem") == 0 and calls(c, "get") == 0 and lookups(c, HELPER_CLASS) == 0, "inside the first map load nothing is looked up or asked")
    c.ticks(1)
    check(calls(c, "GetEngineSubsystem") == 1 and lookups(c, HELPER_CLASS) == 1 and c.world.askedFor == c.ue.objects[HELPER_CLASS]
        and c.fake.value("intro.helper") == "found", "after it, at a quiet moment: the helper is asked from the engine's library with its class (looked up once)")
    c.seconds(10)
    check(calls(c, "GetEngineSubsystem") == 1 and calls(c, "get") == 0, "and not again")
    c.world.type = 0
    c.world.load()
    check(c.fake.value("intro.loading_type") == "default" and calls(c, "set") == 0, "a map load of the usual type: read, noted, left as it is")
    c.world.type = 1
    c.world.load()
    check(c.world.type == 1 and c.fake.value("intro.loading_type") == "black screen" and calls(c, "set") == 0, "the black screen: the same")
    -- loading a save
    c.world.type = 3
    c.world.load()
    check(c.world.type == 3 and calls(c, "set") == 0 and c.fake.value("intro.loading_type") == "story recap" and c.fake.value("intro.film") == nil,
        "a map load with another type (a save): the type is read and left as it is")
    -- a new game
    c.world.type = 2
    c.world.load()
    check(c.world.type == 0 and c.world.setTo == 0 and calls(c, "set") == 1 and c.world.films == 0 and c.fake.value("intro.film") == "skipped" and c.fake.value("intro.loading_type") == "game intro",
        "a new game: at the beginning of its map load the type becomes the usual one; the game does not play the film")
    check(printedCount(c.ue, "a new game starts: its film is skipped (the game's usual loading screen instead)") == 1, "said in UE4SS.log")
    check(lookups(c, HELPER_CLASS) == 1 and T.searches(c) == 1, "nothing else was looked up (only the helper's class)")
    c.world.type = 2
    c.world.load()
    check(c.world.type == 0 and c.hook.state.films == 2 and c.world.films == 0, "a second new game: the same")
    check(status(c) == "v1.0.0 | logos as the game has them, the film of a new game skipped | Game.ini: does not skip the logos | films of a new game skipped: 2"
        .. " | loading screen at the last map load: game intro", "status: " .. status(c))
    -- the setting off: a new game keeps its film
    T.write(c.path, cfg({ "Config.SkipNewGameFilm = false" }))
    c.seconds(6)
    check(printed(c.ue, "settings changed (config.lua): the game starts as it has it") ~= nil, "a change of config.lua is picked up and said")
    local asks = calls(c, "get")
    c.world.type = 2
    c.world.load()
    check(c.world.films == 1 and calls(c, "get") == asks, "switched off: a new game's type is not even read; the game plays the film")
    T.stop(c)
end

section("the film: the module or the whole part off")
do
    local c = boot("film-disabled", {}, cfg({ "Config.Enabled = false", "Config.SkipNewGameFilm = true", "Config.SkipLogos = true" }), appIni())
    check(printed(c.ue, "loaded: switched off") ~= nil, "load line: switched off")
    c.ticks(1)
    c.world.load()
    c.ticks(2)
    c.world.type = 2
    c.world.load()
    c.seconds(5)
    check(c.world.films == 1 and calls(c, "GetEngineSubsystem") == 0 and T.searches(c) == 0 and lookups(c, SETTINGS_CDO) == 0, "Enabled = false: the game is not looked at")
    check(printedCount(c.ue, "Game.ini still skips the logos") == 1, "Game.ini still having the lines is said")
    check(status(c) == "v1.0.0 | switched off | Game.ini: the logos are skipped from the next start of the game", "status: " .. status(c))
    T.stop(c)
end

section("the film: what does not work")
do
    -- the class is not there: given up at once
    local c = boot("film-noclass", { noClass = true }, cfg(FILM_ON))
    c.world.load()
    c.ticks(1)
    check(c.fake.value("intro.helper") == "not available" and c.fake.detail("intro.helper") == "the class LoadingScreenHelperSubsystem was not found"
        and printedCount(c.ue, "the game's loading screen helper is not there (the class LoadingScreenHelperSubsystem was not found); the film of a new game is left to the game for this run") == 1,
        "no class: noted, said once, given up")
    c.world.type = 2
    c.world.load()
    c.seconds(5)
    check(c.world.films == 1 and calls(c, "GetEngineSubsystem") == 0 and lookups(c, HELPER_CLASS) == 1, "a new game then keeps its film; the class was looked up once")
    check(status(c) == "v1.0.0 | logos as the game has them, the film of a new game skipped | Game.ini: does not skip the logos | films of a new game skipped: 0"
        .. " | the film of a new game: left to the game for this run", "status: " .. status(c))
    T.stop(c)

    c = boot("film-nolibrary", { noLibrary = true }, cfg(FILM_ON))
    c.world.load()
    c.ticks(1)
    check(c.fake.value("intro.helper") == "not available" and c.fake.detail("intro.helper") == "the subsystem library was not found" and c.hook.state.off,
        "no library: given up at once")
    T.stop(c)

    -- the engine has no helper: three map loads, then given up
    c = boot("film-nohelper", {}, cfg(FILM_ON))
    c.world.noHelper = true
    c.world.load()
    c.ticks(1)
    check(c.fake.value("intro.helper") == "not there yet" and not c.hook.state.off, "the engine has none at the quiet moment: noted, not given up")
    for _ = 1, 2 do
        c.world.type = 2
        c.world.load()
    end
    check(c.fake.value("intro.film") == "fails" and c.hook.state.fails == 2 and not c.hook.state.off and printed(c.ue, "left to the game") == nil, "two map loads without it: failures")
    c.world.noHelper = false
    c.world.type = 2
    c.world.load()
    check(c.world.type == 0 and c.hook.state.fails == 0 and c.fake.value("intro.film") == "skipped" and c.fake.value("intro.helper") == "found", "there at the third: skipped, the count starts anew ("
        .. table.concat({ c.world.type, c.hook.state.fails, tostring(c.fake.value("intro.film")), tostring(c.fake.value("intro.helper")) }, " ") .. ")")
    c.world.noHelper = true
    for _ = 1, 3 do
        c.world.type = 2
        c.world.load()
    end
    check(c.hook.state.off and printedCount(c.ue, "the game's loading screen helper was not there (the engine has no LoadingScreenHelperSubsystem); the film of a new game is left to the game for this run") == 1,
        "three in a row: given up, said once")
    local asks = calls(c, "GetEngineSubsystem")
    c.world.load()
    check(calls(c, "GetEngineSubsystem") == asks, "and not asked any more")
    T.stop(c)

    -- the type cannot be read
    c = boot("film-getraises", { getRaises = true }, cfg(FILM_ON))
    c.world.load()
    c.ticks(1)
    for _ = 1, 3 do c.world.load() end
    check(c.hook.state.off and T.has(tostring(c.fake.detail("intro.film")), "type not readable"),
        "the type cannot be read: the game's error is noted (" .. tostring(c.fake.detail("intro.film")) .. ")")
    check(printedCount(c.ue, "the type of the game's loading screen cannot be read (") == 1 and calls(c, "set") == 0, "given up after three, said once; nothing set")
    T.stop(c)

    -- setting the type does not take
    c = boot("film-notake", { setNoTake = true }, cfg(FILM_ON))
    c.world.load()
    c.ticks(1)
    c.world.type = 2
    c.world.load()
    check(c.world.films == 1 and c.fake.value("intro.film") == "fails" and c.fake.detail("intro.film") == "the type stayed 2" and c.hook.state.films == 0,
        "a type that stays: a failure, not counted as skipped")
    check(printed(c.ue, "a new game starts") == nil, "nothing said about a skipped film")
    for _ = 1, 2 do
        c.world.type = 2
        c.world.load()
    end
    check(c.hook.state.off and printedCount(c.ue, "the film of a new game could not be skipped (the type stayed 2); the film of a new game is left to the game for this run") == 1,
        "three: given up, said once")
    T.stop(c)

    -- setting the type raises
    c = boot("film-setraises", { setRaises = true }, cfg(FILM_ON))
    c.world.load()
    c.ticks(1)
    c.world.type = 2
    c.world.load()
    check(c.fake.value("intro.film") == "fails" and T.has(tostring(c.fake.detail("intro.film")), "cannot set the type"), "the game's error is noted: " .. tostring(c.fake.detail("intro.film")))
    T.stop(c)

    -- the engine hands out the class's default object
    c = boot("film-cdo", { cdoHelper = true }, cfg(FILM_ON))
    c.world.load()
    c.ticks(1)
    check(c.fake.value("intro.helper") == "not there yet" and c.fake.detail("intro.helper") == "the engine has no LoadingScreenHelperSubsystem" and not c.hook.state.off,
        "the class's default object is no helper")
    T.stop(c)

    -- a type that is no number
    c = boot("film-text", { typeText = true }, cfg(FILM_ON))
    c.world.load()
    c.ticks(1)
    c.world.load()
    check(c.fake.value("intro.film") == "fails" and c.fake.detail("intro.film") == "not a number" and calls(c, "set") == 0, "a type that is no number: a failure, nothing set")
    T.stop(c)

    -- the class gone after it was found: given up at once
    c = boot("film-classgone", {}, cfg(FILM_ON))
    c.world.load()
    c.ticks(1)
    c.ue.objects[HELPER_CLASS].__valid = false
    c.world.type = 2
    c.world.load()
    check(c.hook.state.off and c.fake.value("intro.helper") == "not available" and c.fake.value("intro.film") == nil and c.hook.state.fails == 0 and c.world.films == 1,
        "the class gone after it was found: given up at once, no failure counted; the game plays the film")
    T.stop(c)

    -- failures count in a row: a type read in between starts the count anew
    c = boot("film-row", {}, cfg(FILM_ON))
    c.world.load()
    c.ticks(1)
    c.world.getRaises = true
    c.world.load()
    c.world.load()
    c.world.getRaises = false
    c.world.load()
    check(c.hook.state.fails == 0 and c.fake.value("intro.loading_type") == "default", "two failures, then a type read: the count starts anew")
    c.world.getRaises = true
    c.world.load()
    c.world.load()
    check(c.hook.state.fails == 2 and not c.hook.state.off, "two more: not given up (" .. c.hook.state.fails .. ")")
    T.stop(c)

    -- an odd type
    c = boot("film-odd", {}, cfg(FILM_ON))
    c.world.load()
    c.ticks(1)
    c.world.type = 7
    c.world.load()
    check(c.world.type == 7 and c.fake.value("intro.loading_type") == "7" and calls(c, "set") == 0, "a type the module does not know: noted as its number, left as it is")
    T.stop(c)
end

-- ================================================================ settings, console, diagnostics
section("settings: a change looks at Game.ini again")
do
    local c = boot("change", {}, nil, appIni())
    c.ticks(1)
    check(printedCount(c.ue, "Game.ini still skips the logos") == 1, "at the start: the lines are there though the setting is off")
    T.write(INI, "[x]" .. CRLF)
    c.seconds(5)
    check(c.fake.value("intro.logos_file") == "written", "the file is not looked at again without a reason")
    T.write(INI, appIni())
    T.write(c.path, cfg(LOGOS_ON))
    c.seconds(6)
    check(printed(c.ue, "settings changed (config.lua): logos skipped (through Game.ini, from the next start), the film of a new game as the game has it") ~= nil, "the change is said")
    check(c.fake.values("intro.logos_file")[1] == "written" and #c.fake.values("intro.logos_file") == 1 and printed(c.ue, "does not say so yet") == nil,
        "Game.ini looked at again: it says so already (noted once: the value did not change)")
    os.remove(INI)
    T.write(c.path, cfg({ "Config.SkipLogos = true", "Config.SkipNewGameFilm = true" }))
    c.seconds(6)
    check(c.fake.value("intro.logos_file") == "not written" and printedCount(c.ue, "Game.ini does not say so yet") == 1, "the file gone: looked at again after the next change")
    T.stop(c)
end

section("console and diagnostics")
do
    local c = boot("console", {}, cfg(FILM_ON))
    c.world.load()
    c.ticks(1)
    c.world.type = 2
    c.world.load()
    check(c.ue:fireConsole("intro") == true and T.has(c.ue.device.lines[1], "[G1R_Intro] v1.0.0 | logos as the game has them, the film of a new game skipped"),
        "console: the status lines go to the console (" .. tostring(c.ue.device.lines[1]) .. ")")
    T.write(c.path, cfg(LOGOS_ON))
    check(c.ue:fireConsole("g1r_intro reload") == true and printed(c.ue, "settings read: logos skipped (through Game.ini, from the next start), the film of a new game as the game has it") ~= nil,
        "console: reload reads config.lua at once")
    -- the handler as UE4SS calls it: the words in its parameters, or only in the whole line; reload reads an unchanged file too
    local handler = c.ue.console.intro[1]
    local before = #c.ue.printed
    check(handler("intro", { "reload" }, nil) == true and T.has(c.ue.printed[before + 1], "settings read: "), "parameters: reload (" .. tostring(c.ue.printed[before + 1]):gsub("%s+$", "") .. ")")
    before = #c.ue.printed
    check(handler("intro reload", nil, nil) == true and T.has(c.ue.printed[before + 1], "settings read: "), "no parameters: the words of the whole line (" .. tostring(c.ue.printed[before + 1]):gsub("%s+$", "") .. ")")
    before = #c.ue.printed
    check(handler("intro", nil, nil) == true and T.has(c.ue.printed[before + 1], "[G1R_Intro] v1.0.0 | "), "no parameters, no word: the status")
    check(#c.fake.versions == 1 and c.fake.versions[1] == "1.0.0" and #c.fake.status == 1 and #c.fake.dump == 1, "version, status and dump handed to the diagnostics")
    local d = c.fake.dump[1]()
    check(d.version == "1.0.0" and d.films == 1 and d.last_type == 2 and d.skip_logos == true and d.skip_film == false and d.film_off == false and d.file == "not written",
        "the dump: version, the settings, what happened")
    check(c.fake.neverRepeated("intro.logos_file") and c.fake.neverRepeated("intro.helper") and c.fake.neverRepeated("intro.loading_type"), "no note is repeated with the same value")
    T.stop(c)

    -- without diagnostics
    c = boot("nodiag", { diag = false }, cfg({ "Config.SkipLogos = true", "Config.SkipNewGameFilm = true" }))
    c.world.load()
    c.ticks(2)
    c.world.type = 2
    c.world.load()
    check(c.ok and c.world.type == 0 and c.world.films == 0 and printed(c.ue, "this start of the game played the logos") ~= nil, "without diagnostics it works the same")
    T.stop(c)
end

section("without the loader")
do
    local ue = T.Mock.new()
    ue:install()
    local ok = pcall(dofile, T.MOD .. "modules/intro/Scripts/main.lua")
    check(ok and T.printed(ue, "[G1R_Intro] this module needs the loader of G1R_MegaMod") ~= nil and #ue.loops == 0, "started on its own: says so, registers nothing")
    ue:uninstall()
end

os.getenv = realGetenv
T.finish()
