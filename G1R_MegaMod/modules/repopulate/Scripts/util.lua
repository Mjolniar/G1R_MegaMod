-- G1R_Repopulate: small guarded helpers around the UE4SS Lua API.
-- pcall catches Lua errors, not native access violations. UObject calls must
-- pass validation first; this is not a native object-lifetime guarantee.
local U = {}

local pcall, type, tostring, tonumber = pcall, type, tostring, tonumber

-- Diagnostics handle of the megamod loader; nil when the mod runs on its own,
-- and then nothing behind `if DIAG` runs. It only records what the mod sees.
local DIAG = G1R_DIAG
local Answered = {}          -- diagnostics: paths found earlier in this run (answered from the UE4SS cache since)
local TimeSource = nil       -- diagnostics: how the in-game time was read last

U.MOD = "G1R_Repopulate"
local Logged, ErrorCount = {}, 0
function U.log(msg) print("[" .. U.MOD .. "] " .. tostring(msg) .. "\n") end
function U.logOnce(key, msg)
    if Logged[key] then return end
    Logged[key] = true
    U.log(msg)
end
function U.logError(key, msg)
    if Logged[key] or ErrorCount >= 20 then return end
    ErrorCount = ErrorCount + 1
    U.logOnce(key, msg .. (ErrorCount == 20 and " (further errors suppressed)" or ""))
end

-- Megamod diagnostics: a step that calls into the game is announced before it
-- runs and taken back when it has returned (core/diag.lua, "Operations"), so
-- that the files show what was going on when the game ended. Without the
-- megamod loader both do nothing.
function U.op(text)
    if DIAG and DIAG.op then return DIAG.op(text) end
    return nil
end
function U.done(token)
    if token ~= nil and DIAG and DIAG.done then DIAG.done(token) end
end

local function isValidOf(o) return o:IsValid() end
function U.valid(o)
    if o == nil then return false end
    local ok, v = pcall(isValidOf, o)
    return ok and v == true
end
-- An object wrapper is a pointer, and UE4SS reads the object's memory on every
-- member access without asking whether the object still exists. So a wrapper
-- is asked first: true when its object is gone. Wrappers that have no IsValid
-- (parameters) or an always-true one (structs, arrays) pass.
-- When the question itself fails nothing is known of the object: it counts as
-- gone, and nothing of it is read. A value without an IsValid (a Lua table, a
-- parameter) passes.
function U.gone(o)
    local looked, method = pcall(function() return o.IsValid end)
    if not looked then return true end
    if method == nil then return false end
    local ok, v = pcall(method, o)
    return not ok or v == false
end
function U.get(o, key)
    if o == nil or U.gone(o) then return nil end
    local ok, v = pcall(function() return o[key] end)
    if ok then return v end
    return nil
end
function U.call(o, fn, ...)
    if not U.valid(o) then return nil end
    local args = table.pack(...)
    local ok, v = pcall(function() return o[fn](o, table.unpack(args, 1, args.n)) end)
    if ok then return v end
    return nil
end
-- Like call, but also reports whether the call itself succeeded.
function U.try(o, fn, ...)
    if o == nil then return false, "nil object" end
    if not U.valid(o) then return false, "object validation failed" end
    local args = table.pack(...)
    return pcall(function() return o[fn](o, table.unpack(args, 1, args.n)) end)
end
function U.callBool(o, fn, ...)
    local v = U.call(o, fn, ...)
    if type(v) == "boolean" then return v end
    return nil
end
function U.num(v)
    if type(v) == "number" then return v end
    return tonumber(v)
end
function U.fullName(o)
    if not U.valid(o) then return nil end
    local ok, v = pcall(function() return o:GetFullName() end)
    if ok and type(v) == "string" then return v end
    return nil
end
-- "ClassName /Path/To.Object" -> "ClassName"
function U.classToken(o)
    local n = U.fullName(o)
    if not n then return nil end
    return n:match("^(%S+)")
end
-- Last path segment of an object's name, without a Default__ prefix.
function U.objectToken(o)
    local n = U.fullName(o)
    if not n then return nil end
    local path = n:match("^%S+%s+(.*)$") or n
    local seg = path:match("([^%.:/]+)$") or path
    return (seg:gsub("^Default__", ""))
end
-- The address of a wrapper's object as a number; nothing of the object is
-- read for it (the wrapper itself knows it).
function U.address(o)
    if o == nil then return nil end
    local ok, v = pcall(function() return o:GetAddress() end)
    if ok and type(v) == "number" then return v end
    return nil
end
function U.fname(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    return nil
end
function U.vec3(v)
    if v == nil then return nil end
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    if ok then
        x, y, z = U.num(x), U.num(y), U.num(z)
        if x and y and z then return x, y, z end
    end
    return nil
end
-- TArray / TMap elements arrive either as the value itself or as a
-- param wrapper with :get(); return the usable value.
function U.unwrap(e)
    if e == nil then return nil end
    local ok, v = pcall(function() return e:get() end)
    if ok and v ~= nil then return v end
    return e
end
-- Searches among all objects. FindFirstOf and FindAllOf walk through every
-- object of the game, and so does a search by path that UE4SS has not answered
-- before (found or not). A crash was seen inside such a walk (2026-10-05): the
-- game frees objects on another thread while the walk reads them. A walk also
-- costs 5 to 20 ms. So walks are what is left when the engine cannot be asked
-- (see "The engine's own way" below), and they are spaced out: a place that
-- wants to walk asks mayWalk first and comes back later when the answer is no.
-- And a walk waits for a calm moment (world.lua tells: the game has not just
-- taken many objects out of play, which it then frees) - for CALM_WAIT seconds
-- at most, so that nothing waits for ever while the world keeps changing.
-- The wait is counted from the first "no" (WantedSince) and is over with the
-- next "yes", a walk or a map load: a wish nobody came back for must not let
-- a later walk through at once.
local LastWalk, QuietUntil = -1e9, -1e9
local WALK_GAP = 1.0            -- seconds between two walks
local CALM_WAIT = 20.0          -- seconds a walk is put off at most because the world is not calm
local Walks, PutOff = 0, 0
local Calm, WantedSince = nil, nil
function U.setCalm(f) Calm = f end
function U.mayWalk(realNow)
    realNow = realNow or os.clock()
    if realNow < QuietUntil or realNow - LastWalk < WALK_GAP then return false end
    if Calm and not Calm(realNow) then
        if WantedSince == nil then WantedSince = realNow end
        if realNow - WantedSince < CALM_WAIT then
            PutOff = PutOff + 1
            return false
        end
    end
    WantedSince = nil
    return true
end
-- No walk for the next `seconds` (a map is loading, the hero mounts or dismounts).
function U.quiet(seconds, realNow)
    local t = (realNow or os.clock()) + (seconds or 0)
    if t > QuietUntil then QuietUntil = t end
end
function U.walks() return Walks, PutOff end
function U.findFirst(cls)
    LastWalk, Walks, WantedSince = os.clock(), Walks + 1, nil
    local ok, o = pcall(FindFirstOf, cls)
    if ok and U.valid(o) then return o end
    return nil
end
function U.findAll(cls)
    LastWalk, Walks, WantedSince = os.clock(), Walks + 1, nil
    local ok, list = pcall(FindAllOf, cls)
    if ok and type(list) == "table" then return list end
    return {}
end
function U.findStatic(path)
    if not Answered[path] then
        -- not found before in this run: UE4SS walks every object in memory for
        -- it. With the megamod loader a line goes to disk first.
        LastWalk, Walks, WantedSince = os.clock(), Walks + 1, nil
        if DIAG then DIAG.crumb("U.findStatic " .. tostring(path)) end
    end
    local ok, o = pcall(StaticFindObject, path)
    if ok and U.valid(o) then
        if path ~= nil then Answered[path] = true end
        return o
    end
    return nil
end
-- A search by path, once per path and run: the answer is kept, found or not
-- (a path that does not exist is searched for by walking all objects, every
-- time it is asked for). Spaced like every walk: while one is not due the
-- answer is nil and "later", and nothing is kept. With `now` the search is
-- not put off (for the mod's start, when nothing of a world is there yet).
local Once = {}
function U.findOnce(path, now)
    local o = Once[path]
    if o == false then return nil end
    if o ~= nil then
        if U.valid(o) then return o end
        return nil              -- found once and gone since: not searched again
    end
    if not now and not U.mayWalk() then return nil, "later" end
    o = U.findStatic(path)
    Once[path] = o or false
    return o
end
function U.isDefault(o)
    local n = U.fullName(o)
    return n ~= nil and n:find("Default__", 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- The engine's own way to the objects that are there once. UE4SS hands the
-- map load hook the engine object; the engine object holds the game window,
-- and the window the world the game shows. With a world the engine's function
-- libraries hand out the player controller and the subsystems, and the game's
-- own getter hands out its world point manager. None of this walks through
-- all objects. The engine object is never searched for: until a map load has
-- handed it over (the mod was started later than the last one), the searches
-- do the work, as in the versions before 1.4.
--
-- Every such way was read from the game's program and not yet seen at work in
-- a real session. So an answer "there is none" is only final once the same
-- way has handed out an object in this run; until then, after DOUBT_AFTER
-- seconds of "none", the caller is told that the engine could not be asked
-- and searches as it did before.
-- ---------------------------------------------------------------------------
local Engine = nil
local STATICS = "/Script/Engine.Default__GameplayStatics"
local MANAGER = "/Script/G1R.Default__WorldPointManager"
local SUBSYSTEM_WAYS = {
    world = { "/Script/Engine.Default__SubsystemBlueprintLibrary", "GetWorldSubsystem" },
    instance = { "/Script/Engine.Default__SubsystemBlueprintLibrary", "GetGameInstanceSubsystem" },
    state = { "/Script/GameStateSubsystem.Default__GameStateSubsystemBlueprintLibrary", "GetGameStateSubsystem" },
}
local DOUBT_AFTER = 10.0
local Proven, NoneSince = {}, {}
-- What an answer of the engine is worth: true = final, false = the caller may search.
local function final(key, o)
    if o ~= nil then
        Proven[key], NoneSince[key] = true, nil
        return true
    end
    if Proven[key] then return true end
    local now = os.clock()
    local since = NoneSince[key]
    if since == nil then
        NoneSince[key] = now
        return true
    end
    return now - since < DOUBT_AFTER
end
local Way = {}              -- diagnostics: how a thing was found last ("engine" / "search")
local function way(key, how, detail)
    if Way[key] == how then return end
    Way[key] = how
    if DIAG then DIAG.note(key, how, detail) end
end
U.way = way

-- Called by the map load hooks with what UE4SS hands them first.
function U.setEngine(parameter)
    if Engine ~= nil and U.valid(Engine) then return end
    Engine = nil
    local o = U.unwrap(parameter)
    if o == nil or not U.valid(o) then return end
    local name = U.fullName(o)
    local class = name and name:match("^(%S+)") or nil
    if not class or name:find("Default__", 1, true) or not class:find("Engine", 1, true) then return end
    if U.get(o, "GameViewport") == nil then return end      -- not what it should be: nothing is assumed about it
    Engine = o
    way("core.engine", "handed over at a map load", class)
end
function U.engine()
    if Engine == nil then return nil end
    if U.valid(Engine) then return Engine end               -- (it lives as long as the game runs)
    Engine = nil
    return nil
end
-- The world the game shows: the engine's own answer, or nil without the engine object.
function U.engineWorld()
    local e = U.engine()
    if not e then return nil end
    local w = U.get(U.get(e, "GameViewport"), "World")
    if U.valid(w) then return w end
    return nil
end
-- A subsystem, fresh from the engine. kind: "world", "instance" (of the game
-- instance) or "state" (the game's own game-state subsystems, the game clock
-- among them); classPath: the path of its class. Second result: false when
-- the engine could not be asked (no engine object, library or class not
-- found, or its "none" is not to be trusted yet) - then the caller searches
-- the way it did before.
function U.subsystem(kind, classPath)
    local w = SUBSYSTEM_WAYS[kind]
    local world = w and U.engineWorld() or nil
    local library = world and U.findOnce(w[1]) or nil
    local class = library and U.findOnce(classPath) or nil
    if not class then return nil, false end
    local o = U.call(library, w[2], world, class)
    if not (U.valid(o) and not U.isDefault(o)) then o = nil end
    return o, final(classPath, o)
end
-- The game's world point manager (item spots, spawn points with their
-- scripts), fresh from the game's own getter. Second result as above.
function U.worldPointManager()
    local world = U.engineWorld()
    local owner = world and U.findOnce(MANAGER) or nil
    if not owner then return nil, false end
    local o = U.call(owner, "GetInstance", world)
    if not (U.valid(o) and not U.isDefault(o)) then o = nil end
    return o, final(MANAGER, o)
end
-- The paths this file asks UE4SS for, and a way to have them (and others)
-- looked up at a quiet moment, so that their first use in the world does not
-- walk through all objects: the first map load the mod sees (main.lua) - a
-- call on the game thread, the engine complete, and in a game that has just
-- been started no world to play in yet. They are parts of the engine and of
-- the game's program: the answer is kept, found or not, like every answer
-- of U.findOnce. Returns how many of the paths are there.
U.paths = { STATICS, MANAGER, SUBSYSTEM_WAYS.world[1], SUBSYSTEM_WAYS.state[1],
    "/Script/G1R.GameTimeSubsystem", "/Script/G1R.PersistentDataSubsystem" }
function U.warm(paths)
    local found = 0
    for _, path in ipairs(paths) do
        if U.findOnce(path, true) then found = found + 1 end
    end
    return found
end
-- True / false while the engine can be asked whether the game is paused, else nil.
function U.paused()
    local world = U.engineWorld()
    local statics = world and U.findOnce(STATICS) or nil
    if not statics then return nil end
    return U.callBool(statics, "IsGamePaused", world)
end

-- The player controller. With the engine: asked anew every ASK_EVERY seconds
-- (in between the one it answered with, while that is still the same object).
-- Without: kept under its full name and searched for when it is gone (spaced).
local CachedController, ControllerName = nil, nil
local ControllerAskedAt, ControllerSearchAt = -1e9, -1e9
local SEARCH_EVERY = 2.0
local ASK_EVERY = 0.5
local function kept()
    local c = CachedController
    if c == nil then return nil end
    if U.valid(c) and U.fullName(c) == ControllerName then return c end
    CachedController, ControllerName = nil, nil
    return nil
end
function U.controller()
    local now = os.clock()
    if now - ControllerAskedAt < ASK_EVERY then return kept() end
    local world = U.engineWorld()
    local statics = world and U.findOnce(STATICS) or nil
    if statics then
        local c = U.call(statics, "GetPlayerController", world, 0)
        local name = U.valid(c) and U.fullName(c) or nil
        if not name or name:find("Default__", 1, true) then c, name = nil, nil end
        if final("controller", c) then
            -- (none: main menu, a map is loading)
            ControllerAskedAt = now
            CachedController, ControllerName = c, name
            if c then way("core.controller_by", "engine") end
            return c
        end
    end
    local c = kept()
    if c then return c end
    if now - ControllerSearchAt < SEARCH_EVERY or not U.mayWalk(now) then return nil end
    ControllerSearchAt = now
    for _, cls in ipairs({ "GothicPlayerControllerBaseBP_C", "PlayerController" }) do
        local list = U.findAll(cls)
        for i = #list, 1, -1 do
            c = list[i]
            local name = U.valid(c) and U.fullName(c) or nil
            if name and not name:find("Default__", 1, true) then
                CachedController, ControllerName = c, name
                way("core.controller_by", statics and "search (the engine's own way answered nothing)" or "search")
                return c
            end
        end
    end
    return nil
end
-- The full name of the controller U.controller() answered with last (a new
-- world has a controller of another name).
function U.controllerName() return ControllerName end
function U.pawn()
    local c = U.controller()
    local p = U.call(c, "K2_GetPawn")
    if U.valid(p) then return p end
    p = U.get(c, "Pawn")
    if U.valid(p) then return p end
    return nil
end
function U.world()
    local w = U.engineWorld()
    if w then return w end
    local c = U.controller()
    w = U.call(c, "GetWorld")
    if U.valid(w) then return w end
    return nil
end
function U.playerPos()
    local p = U.pawn()
    if not p then return nil end
    return U.vec3(U.call(p, "K2_GetActorLocation"))
end
-- A map is loaded: nothing kept of the old world, and the engine's "none" is
-- counted from now.
function U.resetCaches()
    CachedController, ControllerName = nil, nil
    ControllerAskedAt, ControllerSearchAt = -1e9, -1e9
    NoneSince = {}
    WantedSince = nil
end

-- In-game clock (seconds since game start, survives save/load). Where it has
-- to be searched for among all objects and is not there - the main menu has
-- no game clock, and the game can sit in it for a long time - the search is
-- repeated after a pause that grows (2, 4, 8 ... 120 s): version 1.3 searched
-- at every update, 9325 times in 40 minutes of main menu in one logged
-- session. A map load starts the pauses anew (U.resetTime).
local TimeSub, TimeSubName = nil, nil
local TimeSearchAt = -1e9
local TIME_SEARCH_FIRST, TIME_SEARCH_MAX = 2.0, 120.0
local TimeSearchMisses = 0              -- searches in a row that found no clock (in this world)
local TIME_CLASS = "/Script/G1R.GameTimeSubsystem"
local function timeSource(how)          -- diagnostics only: noted when it changes
    TimeSource = how
    DIAG.note("core.game_time_source", how)
end
local function timeSubsystem()
    local sub = TimeSub
    if sub ~= nil then
        if U.valid(sub) and U.fullName(sub) == TimeSubName then return sub end
        TimeSub, TimeSubName = nil, nil
    end
    local asked
    sub, asked = U.subsystem("state", TIME_CLASS)
    if sub then
        way("core.game_time_by", "engine")
    elseif not asked then
        local now = os.clock()
        -- (the pause after the 1st, 2nd, 3rd ... search without a clock: 2, 4, 8 ... 120 s)
        local pause = TimeSearchMisses == 0 and 0 or math.min(TIME_SEARCH_FIRST * 2 ^ (TimeSearchMisses - 1), TIME_SEARCH_MAX)
        if now - TimeSearchAt < pause or not U.mayWalk(now) then return nil end
        TimeSearchAt = now
        sub = U.findFirst("GameTimeSubsystem")
        if sub then
            TimeSearchMisses = 0
            way("core.game_time_by", U.engineWorld() and "search (the engine's own way answered nothing)" or "search")
        else
            TimeSearchMisses = TimeSearchMisses + 1
        end
    end
    if sub then TimeSub, TimeSubName = sub, U.fullName(sub) end
    if TimeSubName == nil then TimeSub = nil end
    return TimeSub
end
function U.gameSeconds()
    local sub = timeSubsystem()
    if not sub then return nil end
    local cur = U.get(sub, "CurrentGameTime")
    if cur ~= nil then
        local t = U.num(U.get(cur, "TotalSeconds"))
        if t then
            if DIAG and TimeSource ~= "property" then timeSource("property") end
            return t
        end
        local g = U.unwrap(cur)
        t = U.num(U.get(g, "TotalSeconds"))
        if t then
            if DIAG and TimeSource ~= "property (wrapped)" then timeSource("property (wrapped)") end
            return t
        end
    end
    local r = U.call(sub, "GetCurrentGameTime")
    local t = U.num(U.get(r, "TotalSeconds"))
    if DIAG and t and TimeSource ~= "function" then timeSource("function") end
    return t
end
function U.resetTime()
    TimeSub, TimeSubName = nil, nil
    TimeSearchAt, TimeSearchMisses = -1e9, 0
end

function U.dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

-- Probability that at least one of k independent rolls at p succeeds.
function U.catchUp(p, k)
    if k <= 0 then return 0 end
    if p >= 1 then return 1 end
    if p <= 0 then return 0 end
    return 1 - (1 - p) ^ k
end

-- Simple serializer for plain Lua tables (strings, numbers, booleans). A table
-- inside itself, or deeper than MAX_DEPTH levels, is written as nil and counted:
-- the text stays readable and writing it always ends at once (a progress file
-- is four levels deep).
local MAX_DEPTH, Dropped = 12, 0
local function ser(v, indent, out, depth, open)
    local t = type(v)
    if t == "table" then
        if depth > MAX_DEPTH or open[v] then
            out[#out + 1] = "nil"
            Dropped = Dropped + 1
            return
        end
        open[v] = true
        out[#out + 1] = "{\n"
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            local kv = v[k]
            local kt = type(kv)
            if kt == "table" or kt == "string" or kt == "number" or kt == "boolean" then
                out[#out + 1] = indent .. "  ["
                if type(k) == "string" then out[#out + 1] = string.format("%q", k) else out[#out + 1] = tostring(k) end
                out[#out + 1] = "] = "
                ser(kv, indent .. "  ", out, depth + 1, open)
                out[#out + 1] = ",\n"
            end
        end
        open[v] = nil
        out[#out + 1] = indent .. "}"
    elseif t == "string" then
        out[#out + 1] = string.format("%q", v)
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "0"
        elseif math.type and math.type(v) == "integer" then out[#out + 1] = tostring(v)
        else out[#out + 1] = string.format("%.3f", v) end
    elseif t == "boolean" then
        out[#out + 1] = v and "true" or "false"
    else
        out[#out + 1] = "nil"
    end
end
-- The text, and how many tables were written as nil (see ser).
function U.serialize(v)
    local out = { "return " }
    Dropped = 0
    ser(v, "", out, 1, {})
    out[#out + 1] = "\n"
    return table.concat(out), Dropped
end
-- Writes a file so that a complete copy of it exists at every moment. The
-- new text goes into "<path>.tmp" and is read back; only then the old file
-- becomes "<path>.bak" and the new one takes its place. (Plain Lua cannot
-- replace a file in one step on Windows: os.rename does not overwrite. So
-- between the two renames the file itself is missing for an instant - a start
-- after a crash at that instant finds the complete "<path>.tmp", see readTable.)
-- Returns true, or false and what went wrong; the old file is then untouched
-- or back in its place.
function U.writeFile(path, text)
    local tmp, bak = path .. ".tmp", path .. ".bak"
    local f, err = io.open(tmp, "wb")
    if not f then return false, "cannot open " .. tmp .. " (" .. tostring(err) .. ")" end
    local okWrite, errWrite = f:write(text)
    local okClose, errClose = f:close()
    if not okWrite then
        os.remove(tmp)
        return false, "writing failed (" .. tostring(errWrite) .. ")"
    end
    if not okClose then
        os.remove(tmp)
        return false, "closing failed (" .. tostring(errClose) .. ")"
    end
    if U.readText(tmp) ~= text then         -- what is on disk must be what was meant
        os.remove(tmp)
        return false, "the new file does not read back"
    end
    local old = io.open(path, "rb")
    if old then
        old:close()
        os.remove(bak)
        local okAside, errAside = os.rename(path, bak)
        if not okAside then
            os.remove(tmp)
            return false, "the old file cannot be moved aside (" .. tostring(errAside) .. ")"
        end
    end
    local ok, errPlace = os.rename(tmp, path)
    if not ok then
        if old then os.rename(bak, path) end        -- the old file goes back
        os.remove(tmp)
        return false, "the new file cannot be put in place (" .. tostring(errPlace) .. ")"
    end
    return true
end
function U.readText(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
end
local function loadTable(path)
    local f = io.open(path, "r")
    if not f then return nil, "missing" end
    local text = f:read("a")
    f:close()
    local chunk = load(text or "", "=" .. path, "t", {})
    if not chunk then return nil, "unreadable" end
    local ok, v = pcall(chunk)
    if ok and type(v) == "table" then return v end
    return nil, "unreadable"
end
-- A table written with serialize / writeFile. Results:
--   table                          the file itself
--   table, "finished"              the file was missing and "<path>.tmp" held a
--                                  complete new copy: a write was cut off between
--                                  its two renames. The copy is put in place.
--   table, "backup"                the file cannot be read; "<path>.bak" (the
--                                  copy of the write before) is taken
--   nil, "missing" / "unreadable"  nothing usable
-- A file that is simply not there is "missing" even when a ".bak" lies next to
-- it: who removes the file wants a fresh start, not the copy before it.
function U.readTable(path)
    local t, why = loadTable(path)
    if t then return t end
    if why == "missing" then
        local tmp = path .. ".tmp"
        local unfinished = loadTable(tmp)
        if unfinished then
            os.rename(tmp, path)
            return unfinished, "finished"
        end
        return nil, why
    end
    local b = loadTable(path .. ".bak")
    if b then return b, "backup" end
    return nil, why
end
-- A file that cannot be read is moved aside as "<path>.bad", so that a person
-- can still look at it and the next write does not take it for the good copy
-- before. One such file is kept: when there is one already, the unreadable
-- file is removed.
function U.keepBad(path)
    local bad = path .. ".bad"
    local there = io.open(bad, "rb")
    if there then
        there:close()
        os.remove(path)
        return false
    end
    return os.rename(path, bad) == true
end

return U
