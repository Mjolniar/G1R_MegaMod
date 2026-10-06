-- ============================================================================
-- Loader of the megamod - the only file UE4SS runs.
--
--   Scripts/config.lua              which modules run, diagnostics settings
--   Scripts/core/                   version, the list of modules, diagnostics, module
--                                   loader, console, kit (access to the game), settings
--   Scripts/diagnostics/            written at run time (see the README.txt there)
--   modules/<name>/Scripts/main.lua the modules, each a complete mod of its own
--
-- Each module is loaded in an environment of its own (core/sandbox.lua). A
-- module that fails to load is reported and does not stop the next one. The
-- diagnostics are an extra: when they cannot be used, the modules still run.
-- Console: g1r, g1r diag, g1r dump, g1r help.
-- ============================================================================

local realPrint = print
local type, tostring, pcall, xpcall, ipairs, pairs, select = type, tostring, pcall, xpcall, ipairs, pairs, select

-- 1. Where this mod is: <root>/Scripts/main.lua. The path is kept as UE4SS
--    gave it; what is added uses "/".
local SCRIPTS, ROOT = (function()
    local ok, source = pcall(function() return debug.getinfo(1, "S").source end)
    local file = (ok and type(source) == "string") and source:gsub("^@", "") or "main.lua"
    local function parent(path) return path:match("^(.*)[/\\][^/\\]*$") end
    local scripts = parent(file) or "."
    local root = parent(scripts) or (scripts == "." and ".." or ".")
    return scripts, root
end)()

local function firstLine(text)
    return (tostring(text):match("^[^\r\n]*") or "")
end

-- 2. The core files. Each returns a table.
local function loadCore(file)
    local chunk, err = loadfile(SCRIPTS .. "/core/" .. file)
    if not chunk then return nil, err end
    local ok, result = pcall(chunk)
    if not ok then return nil, result end
    if type(result) ~= "table" then return nil, "core/" .. file .. " did not return a table" end
    return result
end

local Version, versionProblem = loadCore("version.lua")
local NAME = (Version and type(Version.name) == "string") and Version.name or (ROOT:match("([^/\\]+)$") or "mod")
local VERSION = (Version and type(Version.version) == "string") and Version.version or "?"

local function log(text)
    pcall(realPrint, "[" .. NAME .. "] " .. tostring(text) .. "\n")
end
if not Version then log("core/version.lua could not be read (" .. firstLine(versionProblem) .. ")") end

-- 3. Settings: plain values, read in an empty environment.
local Config
do
    local problem
    local chunk, err = loadfile(SCRIPTS .. "/config.lua", "t", {})
    if not chunk then
        problem = err
    else
        local ok, result = pcall(chunk)
        if not ok then problem = result
        elseif type(result) ~= "table" then problem = "config.lua did not return a table"
        else Config = result end
    end
    if not Config then
        log("config.lua missing or invalid (" .. firstLine(problem) .. "); using the default settings")
        Config = {}
    end
end
local Switches = type(Config.Modules) == "table" and Config.Modules or {}

-- Stand-in when the diagnostics core cannot be used: every function does nothing.
local function withoutDiagnostics()
    local nothing = function() end
    local D = { enabled = false, modules = {} }
    for _, key in ipairs({ "line", "crumb", "error", "count", "find", "lookup", "registration", "tick", "flush", "immediate", "handle", "op", "opDone" }) do
        D[key] = nothing
    end
    D.seen = function() return false end
    D.report = function() return nil, "the diagnostics are not available" end
    D.dump = D.report
    D.summary = function() return "unavailable" end
    D.status = function()
        local out = { NAME .. " v" .. VERSION }
        for _, r in ipairs(D.modules) do
            out[#out + 1] = r.name .. ": " .. (r.state == "ok" and "loaded" or r.state == "off" and "switched off in config.lua"
                or r.state == "separate" and ("not loaded - the separate mod " .. tostring(r.error) .. " is installed and enabled")
                or r.state == "absent" and "not installed (its main.lua is not there)"
                or ("FAILED - " .. firstLine(r.error)))
        end
        out[#out + 1] = "diagnostics: not available"
        return out
    end
    return D
end

local Diag
do
    local core, problem = loadCore("diag.lua")
    if core then
        local ok, started, why = pcall(core.init, ROOT, Config.Diagnostics, realPrint, { name = NAME, version = VERSION })
        if ok and started == true then Diag = core
        else problem = ok and (why or "it did not start") or started end
    end
    if not Diag then
        log("diagnostics not available (" .. firstLine(problem) .. "); the modules run without them")
        Diag = withoutDiagnostics()
    end
end

-- Module loader. Without core/sandbox.lua a module still gets an environment
-- of its own, only nothing is wrapped.
local Sandbox
do
    local core, problem = loadCore("sandbox.lua")
    if core then
        local ok, err = pcall(core.init, Diag, realPrint)
        if ok then Sandbox = core else problem = err end
    end
    if not Sandbox then
        log("core/sandbox.lua could not be used (" .. firstLine(problem) .. "); the modules are loaded without it")
        Diag.line("loader", "core/sandbox.lua could not be used: " .. firstLine(problem))
        local services = {}
        local function environment()
            local env = setmetatable({}, { __index = _G })
            env._G = env
            for key, value in pairs(services) do env[key] = value end
            env.loadfile = function(path, mode, ...)
                if select("#", ...) == 0 then return loadfile(path, mode, env) end
                return loadfile(path, mode, ...)
            end
            env.dofile = function(path)
                local chunk, err = loadfile(path, nil, env)
                if not chunk then error(err, 0) end
                return chunk()
            end
            return env
        end
        local function run(mainPath)
            local env = environment()
            local chunk, err = loadfile(mainPath, nil, env)
            if not chunk then error(err, 0) end
            return env, chunk()
        end
        Sandbox = {
            run = function(_, mainPath) return (run(mainPath)) end,
            load = function(_, path) return select(2, run(path)) end,
            provide = function(given) for key, value in pairs(given) do services[key] = value end end,
        }
    end
end

-- What the modules share: the kit (access to the game) and the settings
-- service (config.lua of each module, the in-game menu). Each is loaded like a
-- module, in an environment of its own, so that its searches and callbacks
-- are recorded. A module that needs one of them says so itself when it is
-- missing.
local Kit, Settings
do
    local function service(name, file)
        local ok, result = xpcall(Sandbox.load, debug.traceback, name, SCRIPTS .. "/core/" .. file)
        if ok and type(result) == "table" then return result end
        log("core/" .. file .. " could not be used (" .. firstLine(result) .. ")")
        Diag.error(name, "load", ok and "core/" .. file .. " did not return a table" or result, true)
        return nil
    end
    Kit = service("kit", "kit.lua")
    if Kit and type(Kit.setup) == "function" then pcall(Kit.setup, Config.Engine) end
    pcall(Sandbox.provide, { G1R_KIT = Kit })           -- the settings service asks the kit how keys are spelt
    Settings = service("settings", "settings.lua")
    if Settings then pcall(Settings.init, realPrint) end
    pcall(Sandbox.provide, { G1R_SETTINGS = Settings })
end

-- 4. The modules: core/modules.lua lists them in the order they are loaded.
local MODULES, modulesProblem = loadCore("modules.lua")
if not MODULES then
    log("core/modules.lua could not be read (" .. firstLine(modulesProblem) .. "); no module is loaded")
    Diag.line("loader", "core/modules.lua could not be read: " .. firstLine(modulesProblem))
    MODULES = {}
end

-- A module is not loaded while the same thing runs as a separate mod next to
-- this one: both would act on the game. A read-only look at the Mods folder:
-- <Mods>/<folder> holds a mod (Scripts/main.lua, or dlls/main.dll for a
-- native one) and UE4SS starts it (enabled.txt in its folder - that alone is
-- enough -, or "<folder> : 1" in mods.txt).
local function fileExists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end
local ModsTxt = nil
local function separateModRuns(folder)
    local base = ROOT .. "/../" .. folder
    -- UE4SS itself asks for "scripts"; on Windows the case of the name makes no difference
    if not fileExists(base .. "/Scripts/main.lua") and not fileExists(base .. "/scripts/main.lua")
        and not fileExists(base .. "/dlls/main.dll") then return false end
    if fileExists(base .. "/enabled.txt") then return true end
    if ModsTxt == nil then
        ModsTxt = ""
        local f = io.open(ROOT .. "/../mods.txt", "r")
        if f then
            ModsTxt = (f:read("a") or ""):gsub("^\239\187\191", "")     -- UE4SS skips a byte order mark too
            f:close()
        end
    end
    -- Line by line as UE4SS reads the file (start_mods in UE4SSProgram.cpp): a
    -- line with a ";" anywhere, or of four characters or fewer, is skipped;
    -- spaces (only spaces) do not count; the name is the text before the first
    -- colon, and the mod is on when the text after the last colon starts with 1.
    -- Names are compared without regard to case: the folder was found that way
    -- on Windows, and taking a mod for enabled once too often only costs a
    -- module, taking it for disabled would let two mods act on the same thing.
    local wanted = folder:lower()
    for line in (ModsTxt .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        if not line:find(";", 1, true) and #line > 4 then
            local compact = line:gsub(" ", "")
            local name = compact:match("^(.[^:]*):")
            if name and name:lower() == wanted and compact:match(".*:(.?)") == "1" then return true end
        end
    end
    return false
end
-- What a module may know of the other mods (the list of keys reads their
-- settings files): where the Mods folder is, and whether UE4SS starts a mod
-- there - the same read-only look as above.
pcall(Sandbox.provide, { G1R_MODS = {
    folder = ROOT .. "/..",
    runs = function(folder)
        local ok, runs = pcall(separateModRuns, tostring(folder))
        return ok and runs == true
    end,
} })
-- The first of a module's separate mods that runs, or nil.
local function separateOf(m)
    local list = m.separate
    if type(list) == "string" then list = { list } end
    if type(list) ~= "table" then return nil end
    for _, folder in ipairs(list) do
        local ok, runs = pcall(separateModRuns, folder)
        if ok and runs then return folder end
    end
    return nil
end

local results = {}
for _, m in ipairs(MODULES) do
    local result = { name = m.name }
    local mainPath = ROOT .. "/modules/" .. m.name .. "/Scripts/main.lua"
    local separate = separateOf(m)
    if Switches[m.switch] == false then
        result.state = "off"
        Diag.line("loader", "module " .. m.name .. ": switched off in config.lua")
    elseif separate then
        result.state, result.error = "separate", separate
        log("module " .. m.name .. " not loaded: the separate mod " .. separate
            .. " is installed and enabled (disable or remove it to use this module)")
        Diag.line("loader", "module " .. m.name .. ": not loaded, the separate mod " .. separate .. " is installed and enabled")
    elseif not fileExists(mainPath) then
        -- somebody took the module out: not an error
        result.state = "absent"
        Diag.line("loader", "module " .. m.name .. ": not installed (modules/" .. m.name .. "/Scripts/main.lua is not there)")
    else
        local ok, err = xpcall(Sandbox.run, debug.traceback, m.name, mainPath)
        if ok then
            result.state = "ok"
        else
            result.state, result.error = "failed", tostring(err)
            Sandbox.fail(m.name)        -- what it registered before the error does nothing from now on
            log("module " .. m.name .. " failed to load: " .. firstLine(err))
            Diag.error(m.name, "load", err, true)
        end
    end
    Diag.modules[#Diag.modules + 1] = result
    results[#results + 1] = m.name .. " " .. (result.state == "ok" and "ok" or result.state == "off" and "off"
        or result.state == "separate" and ("left to the separate mod " .. separate) or result.state == "absent" and "not installed" or "FAILED")
end

-- 5. Console command and the timer of the diagnostics.
do
    local core, problem = loadCore("console.lua")
    if core then
        local ok, registered, why = pcall(core.register, Diag, log)
        if not ok then problem = registered
        elseif not registered then problem = why
        else problem = nil end
    end
    if problem then
        log("console command g1r not available (" .. firstLine(problem) .. ")")
        Diag.line("loader", "console command g1r not available: " .. firstLine(problem))
    end
end
-- The shared services' own loop: edits from the in-game menu, changed
-- settings files, notes on screen that have had their time.
if (Kit or Settings) and type(LoopInGameThreadWithDelay) == "function" then
    local clock = os.clock
    local ok, err = pcall(LoopInGameThreadWithDelay, 250, function()
        local t0 = clock()
        local fine = true
        if Settings then fine = pcall(Settings.tick) and fine end
        if Kit then fine = pcall(Kit.tick) and fine end
        Diag.count("loader", "services", (clock() - t0) * 1000, fine, "settings and kit")
    end)
    if not ok then
        log("no timer for the settings (" .. firstLine(err) .. "): settings changed while the game runs are not picked up")
        Diag.line("loader", "no timer for the settings: " .. firstLine(err))
    end
end
if Diag.enabled then
    local problem
    if type(LoopInGameThreadWithDelay) == "function" then
        local clock = os.clock
        local ok, err = pcall(LoopInGameThreadWithDelay, 1000, function()
            local t0 = clock()
            local fine = pcall(Diag.tick)
            Diag.count("loader", "timer", (clock() - t0) * 1000, fine, "diagnostics timer")
        end)
        if not ok then problem = err end
    else
        problem = "this UE4SS build has no LoopInGameThreadWithDelay"
    end
    if problem then
        Diag.immediate(true)
        Diag.line("loader", "no timer for the diagnostics (" .. firstLine(problem) .. "): lines are written at once, reports only with 'g1r diag'")
    end
end

-- 6. The load line. The first report is written now, so that report-latest.txt
--    always belongs to this run (the modules are not asked for their status
--    here: that happens from the timer and the console, in the game thread).
local summary = #results > 0 and table.concat(results, ", ") or "no modules"
Diag.line("loader", "v" .. VERSION .. " loaded: " .. summary)
Diag.flush()
Diag.report(false, true)
log("v" .. VERSION .. " loaded: " .. summary .. " | diagnostics " .. tostring(Diag.summary() or "?"))

-- Offline test hook (inert in game: the global does not exist there).
if type(rawget(_G, "G1R_LOADER_TEST")) == "table" then
    local T = rawget(_G, "G1R_LOADER_TEST")
    T.diag, T.sandbox, T.root, T.scripts, T.name, T.version, T.config = Diag, Sandbox, ROOT, SCRIPTS, NAME, VERSION, Config
    T.kit, T.settings = Kit, Settings
end
