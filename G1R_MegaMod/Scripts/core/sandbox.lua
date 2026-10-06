-- ============================================================================
-- Module loader: every module runs in an environment of its own.
--
--   * what a module defines as a global stays in its environment - it does not
--     reach _G or another module; everything the module does not define itself
--     is looked up in _G (the UE4SS functions, later additions included);
--   * dofile / loadfile give the module's other files the same environment;
--   * every module gets the shared services the loader provides (G1R_KIT,
--     G1R_SETTINGS);
--   * with diagnostics on, the module gets G1R_DIAG, its print is also
--     recorded, and the UE4SS functions that take a callback or search for
--     objects are wrapped: callbacks are timed and their errors are caught and
--     recorded with a traceback, searches by path are announced in the session
--     log before they run, and every search that walks through all objects is
--     announced as an operation (core/diag.lua, "Operations") while it runs.
--
-- A wrapper passes every argument and every return value on unchanged. The
-- wrappers search for nothing themselves. The only thing they ask of the game
-- is IsValid() on the result of StaticFindObject: the function returns an
-- object for "not found" as well, and that call (inside pcall) is how the
-- modules themselves tell the two apart.
-- ============================================================================

local Sandbox = {}

local type, select, pcall, xpcall, error, ipairs, pairs, tostring, setmetatable = type, select, pcall, xpcall, error, ipairs, pairs, tostring, setmetatable
local loadfile = loadfile
local unpack = table.unpack
local clock = os.clock
local traceback = debug.traceback

local Diag = nil            -- the diagnostics core while it is on; nil = no wrappers
local realPrint = print
local Services = {}         -- what every module's environment gets besides G1R_DIAG (name -> value)

local STANDARD = {
    "pairs", "ipairs", "next", "select", "type", "tostring", "tonumber", "pcall", "xpcall", "error",
    "assert", "rawget", "rawset", "rawequal", "rawlen", "setmetatable", "getmetatable",
    "math", "string", "table", "os", "io", "coroutine", "utf8", "debug", "load",
}

-- UE4SS functions that take one or more callbacks.
local REGISTRATIONS = {
    "RegisterHook", "NotifyOnNewObject", "LoopInGameThreadWithDelay", "LoopAsync", "ExecuteWithDelay",
    "ExecuteInGameThread", "ExecuteAsync", "RegisterLoadMapPreHook", "RegisterLoadMapPostHook",
    "RegisterConsoleCommandHandler", "RegisterConsoleCommandGlobalHandler", "RegisterKeyBind",
    "RegisterBeginPlayPreHook", "RegisterBeginPlayPostHook", "RegisterEndPlayPreHook", "RegisterEndPlayPostHook",
    "RegisterInitGameStatePreHook", "RegisterInitGameStatePostHook",
}

-- diag: the diagnostics core (wrappers are used when diag.enabled is true).
function Sandbox.init(diag, printFunction)
    if type(printFunction) == "function" then realPrint = printFunction end
    Diag = (type(diag) == "table" and diag.enabled == true) and diag or nil
end

-- The latest environment of each module: { failed = true } once its main file raised (Sandbox.fail)
local Lives = {}

-- ---------------------------------------------------------------------------
-- Wrappers
-- ---------------------------------------------------------------------------
-- The callback as the game will call it: same arguments, same return values;
-- an error ends in the diagnostics and nothing is returned.
local function guard(name, kind, where, callback, life)
    local count, failed = Diag.count, Diag.error
    local function finish(t0, ok, ...)
        local ms = (clock() - t0) * 1000
        if ok then
            count(name, kind, ms, true, where)
            return ...
        end
        count(name, kind, ms, false, where)
        failed(name, where, (...))
    end
    return function(...)
        -- registered by a module whose start then failed: it stays with UE4SS (that cannot be undone) and does nothing
        if life.failed then return end
        local t0 = clock()
        return finish(t0, xpcall(callback, traceback, ...))
    end
end

local function registration(env, name, kind, original, life)
    local report = Diag.registration
    local announce = kind == "RegisterHook" and Diag.crumb or nil
    local function finish(where, ok, ...)
        if ok then
            report(name, kind, where, true, nil, announce ~= nil)
            return ...
        end
        report(name, kind, where, false, (...))
        error((...), 0)   -- the caller gets the error the function raised
    end
    env[kind] = function(...)
        local n = select("#", ...)
        local args = { ... }
        local where = kind
        for i = 1, n do
            local t = type(args[i])
            if t == "string" or t == "number" then
                where = kind .. " " .. tostring(args[i])
                break
            end
        end
        local callbacks = 0
        for i = 1, n do
            if type(args[i]) == "function" then
                callbacks = callbacks + 1
                local label = where
                if callbacks > 1 then
                    label = where .. (kind == "RegisterHook" and " (post)" or (" (callback " .. callbacks .. ")"))
                end
                args[i] = guard(name, kind, label, args[i], life)
            end
        end
        -- RegisterHook looks its function up by path: announced like a search
        if announce then announce(name, where) end
        return finish(where, pcall(original, unpack(args, 1, n)))
    end
end

local function isValid(object) return object:IsValid() end

local function wrap(env, name, life)
    local G = _G
    for _, kind in ipairs(REGISTRATIONS) do
        if type(G[kind]) == "function" then registration(env, name, kind, G[kind], life) end
    end

    local find = G.StaticFindObject
    if type(find) == "function" then
        local seen, crumb, lookup = Diag.seen, Diag.crumb, Diag.lookup
        local function finish(path, t0, ok, ...)
            local ms = (clock() - t0) * 1000
            if not ok then
                lookup(name, path, false, ms, (...))
                error((...), 0)   -- the caller gets the error the function raised
            end
            local object = ...
            local found = object ~= nil
            if found then
                local valid
                ok, valid = pcall(isValid, object)
                if ok and valid == false then found = false end
            end
            lookup(name, path, found, ms)
            return ...
        end
        local op, opDone = Diag.op, Diag.opDone
        local function closed(token, path, t0, ...)
            if token then opDone(token) end
            return finish(path, t0, ...)
        end
        env.StaticFindObject = function(...)
            local path = ...
            local token = nil
            if type(path) == "string" and select("#", ...) == 1 then
                -- not found earlier in this run: the search walks every object
                if not seen(path) then
                    crumb(name, "lookup " .. path)
                    token = op(name, "search by path " .. path)
                end
            else
                path = nil
            end
            local t0 = clock()
            return closed(token, path, t0, pcall(find, ...))
        end
    end

    for _, kind in ipairs({ "FindAllOf", "FindFirstOf" }) do
        local original = G[kind]
        if type(original) == "function" then
            -- each of them walks through every object of the game: announced as an
            -- operation while it runs (an error it raises reaches the caller as before)
            local counted, op, opDone = Diag.find, Diag.op, Diag.opDone
            local function finish(t0, token, ok, ...)
                counted(name, kind, (clock() - t0) * 1000)
                if token then opDone(token) end
                if not ok then error((...), 0) end
                return ...
            end
            env[kind] = function(...)
                local token = op(name, kind .. " " .. tostring((...)))
                local t0 = clock()
                return finish(t0, token, pcall(original, ...))
            end
        end
    end

    local line = Diag.line
    env.print = function(...)
        realPrint(...)
        local n = select("#", ...)
        if n == 1 then
            line(name, (...))
        elseif n > 1 then
            local parts = { ... }
            for i = 1, n do parts[i] = tostring(parts[i]) end
            line(name, table.concat(parts, "\t", 1, n))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Environment
-- ---------------------------------------------------------------------------
function Sandbox.environment(name)
    local env = {}
    for _, key in ipairs(STANDARD) do env[key] = _G[key] end
    env._G = env
    env.loadfile = function(path, mode, ...)
        if select("#", ...) == 0 then return loadfile(path, mode, env) end
        return loadfile(path, mode, ...)
    end
    env.dofile = function(path)
        local chunk, err = loadfile(path, nil, env)
        if not chunk then error(err, 0) end
        return chunk()
    end
    setmetatable(env, { __index = _G })
    for key, value in pairs(Services) do env[key] = value end
    if Diag then
        env.G1R_DIAG = Diag.handle(name)
        local life = { failed = false }
        Lives[name] = life
        wrap(env, name, life)
    end
    return env
end

-- Globals that every environment made from now on gets (the loader's shared
-- services: G1R_KIT, G1R_SETTINGS).
function Sandbox.provide(services)
    if type(services) ~= "table" then return end
    for key, value in pairs(services) do
        if type(key) == "string" then Services[key] = value end
    end
end

-- Runs a file in an environment of its own and returns what the file returns
-- (the shared services are loaded this way, so that they are recorded like a
-- module). Raises like Sandbox.run.
function Sandbox.load(name, path)
    local env = Sandbox.environment(name)
    local chunk, err = loadfile(path, nil, env)
    if not chunk then error(err, 0) end
    return chunk()
end

-- Runs the main file of a module. Raises when the file cannot be loaded or
-- raises itself; the loader calls this inside xpcall.
function Sandbox.run(name, mainPath)
    local env = Sandbox.environment(name)
    local chunk, err = loadfile(mainPath, nil, env)
    if not chunk then error(err, 0) end
    chunk()
    return env
end

-- The main file of a module raised (the loader calls this): whatever it registered before the error does nothing
-- from now on. Meant is the module's latest environment; a later start of the module gets a new one.
function Sandbox.fail(name)
    local life = Lives[name]
    if life then life.failed = true end
end

return Sandbox
