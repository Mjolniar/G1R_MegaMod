-- ============================================================================
-- Kit: what the modules share when they deal with the game.
--
--   guarded access   valid / gone / get / call / try / fullName / classToken / unwrap / number
--   arrays           each(array, f) / count(array)
--   searches         findOnce(path): a search by path, once per path and run
--                    findClass(name) / findDefault(name): a class of the game / its default object
--                    firstOf(class): the first live object of a class, kept and checked
--                    hookOnce(path, pre, post): RegisterHook, once per path and run
--   the engine       engine / gameInstance / world: handed over at a map load, nothing is searched for
--                    subsystem(kind, class, place): a subsystem, asked from the engine
--                    keepAlive(object): an object this mod made stays for the rest of the run
--   the hero         controller / playerState / pawn / world / attributeSet / readAttribute / writeAttribute / attribute
--   other characters attributeSetOf
--   the world        onWorldChange(f), loading(), paused(), gameSeconds()
--   keys             keyCombo(text), bindKey(id, text, action): the action runs on the game thread;
--                    describeKey(id, label) / keyList(): what the keys do, for the list of keys
--   messages         notify(text, slot): a note the way the player chose; toast / subtitle: the two kinds;
--                    panel(id, options): a box of lines of a module's own;
--                    configureLetters(choice) / letters(): the letters of the mod's texts
--   logging          logger(tag, print) -> { log, once }
--
-- Rules this file keeps (dev/FACTS.md, U1 - U6):
--   * a search by path never repeats, found or not;
--   * an object wrapper is asked whether its object still exists, and kept
--     wrappers are compared by full name before they are used again (a new
--     object can get the address of an old one);
--   * what the engine hands out itself is asked from the engine; searches
--     among all objects (FindAllOf / FindFirstOf) are what is left when that
--     way is not there, and they are spaced out (dev/FACTS.md, U14 - U19);
--   * nothing here raises.
-- The loader runs this file in an environment of its own ("kit"), so its
-- searches and callbacks show up in the diagnostics like a module's.
-- ============================================================================

local Kit = {}

local pcall, type, tostring, tonumber, ipairs, pairs = pcall, type, tostring, tonumber, ipairs, pairs
local min, max, abs, huge = math.min, math.max, math.abs, math.huge
local clock = os.clock
local DIAG = G1R_DIAG           -- the kit's own handle; nil without diagnostics
local Noted = {}
local function note(key, value, detail)         -- a note for the diagnostics, when its value changes
    if DIAG and Noted[key] ~= value then
        Noted[key] = value
        DIAG.note(key, value, detail)
    end
end

-- ---------------------------------------------------------------------------
-- Guarded access
-- ---------------------------------------------------------------------------
local function isValidOf(o) return o:IsValid() end
local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(isValidOf, o)
    return ok and v == true
end
-- True when the wrapper's object is gone. Wrappers without IsValid (structs,
-- array elements) and plain values pass.
local function gone(o)
    local ok, v = pcall(isValidOf, o)
    return ok and v == false
end
local function get(o, key)
    if o == nil or gone(o) then return nil end
    local ok, v = pcall(function() return o[key] end)
    if ok then return v end
    return nil
end
local function call(o, fn, ...)
    if o == nil or gone(o) then return nil end
    local args = table.pack(...)
    local ok, v = pcall(function() return o[fn](o, table.unpack(args, 1, args.n)) end)
    if ok then return v end
    return nil
end
-- Like call, but says whether the call itself worked: ok, result-or-error.
local function try(o, fn, ...)
    if o == nil then return false, "nil object" end
    if gone(o) then return false, "object is gone" end
    local args = table.pack(...)
    return pcall(function() return o[fn](o, table.unpack(args, 1, args.n)) end)
end
local function fullName(o)
    if o == nil or gone(o) then return nil end
    local ok, v = pcall(function() return o:GetFullName() end)
    if ok and type(v) == "string" then return v end
    return nil
end
-- "ClassName /Path/To.Object" -> "ClassName"
local function classToken(o)
    local n = fullName(o)
    return n and n:match("^(%S+)") or nil
end
local function isDefaultName(name) return name == nil or name:find("Default__", 1, true) ~= nil end
-- Array and map elements arrive as the value itself or as a wrapper with :get().
local function unwrap(e)
    if e == nil then return nil end
    local ok, v = pcall(function() return e:get() end)
    if ok and v ~= nil then return v end
    return e
end
-- A finite number, or nil.
local function number(v)
    if type(v) ~= "number" or v ~= v or v == huge or v == -huge then return nil end
    return v
end
-- The length of an array property, or nil.
local function count(array)
    if array == nil then return nil end
    local ok, n = pcall(function() return array:GetArrayNum() end)
    if ok then return number(n) end
    return nil
end
-- Calls f(value, index) for every element of an array property; f returning
-- true ends the loop. Returns the number of elements seen, or nil when the
-- array cannot be walked. (An array wrapper is never indexed past its length:
-- that would add elements to the game's array.)
local function each(array, f)
    if array == nil or type(f) ~= "function" then return nil end
    local seen = 0
    local ok = pcall(function()
        array:ForEach(function(index, element)
            seen = seen + 1
            return f(unwrap(element), index) == true
        end)
    end)
    if ok then return seen end
    return nil
end
-- The address of a wrapper's object as a number (nothing of the object is read for it), or nil.
local function addressOf(o)
    if o == nil then return nil end
    local ok, v = pcall(function() return o:GetAddress() end)
    if ok and type(v) == "number" then return v end
    return nil
end
Kit.count, Kit.each, Kit.addressOf = count, each, addressOf
Kit.valid, Kit.gone, Kit.get, Kit.call, Kit.try = valid, gone, get, call, try
Kit.fullName, Kit.classToken, Kit.isDefaultName, Kit.unwrap, Kit.number = fullName, classToken, isDefaultName, unwrap, number
Kit.clock = clock

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------
-- A module gives its own print, so that its lines are recorded as its own:
--   local L = KIT.logger("G1R_XP", print)
function Kit.logger(tag, out)
    if type(out) ~= "function" then out = print end
    local seen = {}
    local L = { tag = tag }
    function L.log(text) out("[" .. tag .. "] " .. tostring(text) .. "\n") end
    function L.once(key, text)
        if seen[key] then return false end
        seen[key] = true
        L.log(text)
        return true
    end
    return L
end
local Log = Kit.logger("G1R_MegaMod")

-- ---------------------------------------------------------------------------
-- Searches by path: once per path and run. A path UE4SS has not answered
-- before is searched by walking every object in memory, so the answer is
-- kept, found or not.
-- ---------------------------------------------------------------------------
local Found = {}
function Kit.findOnce(path)
    if type(path) ~= "string" then return nil end
    local known = Found[path]
    if known ~= nil then
        if known == false then return nil end
        if valid(known) then return known end
        return nil          -- found once and gone since: not searched again
    end
    local ok, o = pcall(StaticFindObject, path)
    if ok and valid(o) then
        Found[path] = o
        return o
    end
    Found[path] = false
    return nil
end
function Kit.searched(path) return Found[path] ~= nil end
-- Looks paths up at a quiet moment, so that their first use in the world is
-- not a walk through all objects (dev/FACTS.md, U1, U2). A path that was
-- asked for before is not searched again; what is not found now is searched
-- once more when it is needed. Returns how many of the paths are known now.
function Kit.warm(paths)
    if type(paths) ~= "table" then return 0 end
    local found = 0
    for _, path in ipairs(paths) do
        if type(path) == "string" then
            if Found[path] == nil then
                local ok, o = pcall(StaticFindObject, path)
                if ok and valid(o) then Found[path] = o end
            end
            if Found[path] then found = found + 1 end
        end
    end
    return found
end
-- A class of the game by its name. Native classes live in /Script/G1R, the
-- game's script classes in /Script/Angelscript, the engine's in
-- /Script/Engine. Say where when you know it (`place`: "G1R", "Angelscript",
-- "Engine", "UMG", ...): every place tried in vain costs one walk through all
-- objects (once per run). Without a place the three are tried in that order.
local PLACES = { "G1R", "Angelscript", "Engine" }
function Kit.findClass(name, place)
    if type(name) ~= "string" then return nil end
    if type(place) == "string" then return Kit.findOnce("/Script/" .. place .. "." .. name) end
    for _, p in ipairs(PLACES) do
        local o = Kit.findOnce("/Script/" .. p .. "." .. name)
        if o then return o end
    end
    return nil
end
-- The default object of such a class (where its functions that need no
-- object are called, and where its default values are).
function Kit.findDefault(name, place)
    if type(name) ~= "string" then return nil end
    return Kit.findClass("Default__" .. name, place)
end

local function firstLine(text) return (tostring(text):match("^[^\r\n]*") or "") end

-- RegisterHook looks its function up by path, like a search: once per path
-- and run, found or not. Returns true, or false and why. The callbacks get
-- what UE4SS hands them (parameter wrappers with :get() and :set()).
-- For hooks that are only needed once a setting is switched on: nothing is
-- registered before the first call, and a second call registers nothing.
local Hooks = {}
function Kit.hookOnce(path, pre, post)
    if type(path) ~= "string" or type(pre) ~= "function" then return false, "hookOnce needs a path and a function" end
    local h = Hooks[path]
    if h ~= nil then return h.ok, h.why end
    h = { ok = false }
    Hooks[path] = h
    if type(RegisterHook) ~= "function" then
        h.why = "this UE4SS build has no RegisterHook"
        return false, h.why
    end
    local ok, a, b
    if type(post) == "function" then ok, a, b = pcall(RegisterHook, path, pre, post) else ok, a, b = pcall(RegisterHook, path, pre) end
    if ok then
        h.ok, h.preId, h.postId = true, a, b
    else
        h.why = firstLine(a)
    end
    return h.ok, h.why
end
function Kit.hooked(path) return Hooks[path] ~= nil and Hooks[path].ok == true end

-- ---------------------------------------------------------------------------
-- The engine's own way to the objects that are there once. The engine object
-- is handed to the map load hooks; it holds the game instance and the game
-- window, and the window holds the world. With a world the engine's function
-- libraries hand out the player controller and the subsystems. None of this
-- walks through all objects of the game - FindAllOf and FindFirstOf do, and a
-- crash was seen inside such a walk (dev/FACTS.md, section 6). The engine
-- object is never searched for: until a map load has handed it over (the mod
-- was started later than the last one), the searches further down do the
-- work, as they did before.
-- ---------------------------------------------------------------------------
local Engine = { object = nil, name = nil }
local STATICS = "/Script/Engine.Default__GameplayStatics"
local SYSTEM_LIBRARY = "/Script/Engine.Default__KismetSystemLibrary"

local function rememberEngine(parameter)
    if Engine.object ~= nil and valid(Engine.object) then return end
    local o = unwrap(parameter)
    if o == nil or not valid(o) then return end
    local name = fullName(o)
    local class = name and name:match("^(%S+)") or nil
    if not class or isDefaultName(name) or not class:find("Engine", 1, true) then return end
    if get(o, "GameViewport") == nil then return end       -- not what it should be: nothing is assumed about it
    Engine.object, Engine.name = o, name
    note("kit.engine", "handed over at a map load", class)
end
-- The engine object (it lives as long as the game runs), or nil while no map load has handed it over.
function Kit.engine()
    local e = Engine.object
    if e == nil then return nil end
    if valid(e) then return e end
    Engine.object, Engine.name = nil, nil
    return nil
end
-- The world the game shows, the engine's own answer; nil without the engine object.
local function engineWorld()
    local e = Kit.engine()
    if not e then return nil end
    local w = get(get(e, "GameViewport"), "World")
    if valid(w) then return w end
    return nil
end
-- The game instance (it lives as long as the game runs), or nil.
function Kit.gameInstance()
    local e = Kit.engine()
    local instance = e and get(e, "GameInstance") or nil
    if valid(instance) then return instance end
    return nil
end

-- "There is none" is the engine's last word only once the same way has handed
-- out an object in this run: every way of asking the engine was read from the
-- game's program, and what was not yet seen at work is not relied on. Until
-- then, after DOUBT_AFTER seconds of "none" (not counted while a map is
-- loading: nothing is there to be found then), the caller searches the way
-- it did before 0.2.2.
local DOUBT_AFTER = 10
local Proven, NoneSince = {}, {}
local function lastWord(key, found, now)
    if found then
        Proven[key], NoneSince[key] = true, nil
        return true
    end
    if Proven[key] then return true end
    if Kit.loading() then
        NoneSince[key] = nil
        return true
    end
    local since = NoneSince[key]
    if since == nil then
        NoneSince[key] = now
        return true
    end
    return now - since < DOUBT_AFTER
end

-- What the loader hands over from Scripts/config.lua (Config.Engine).
local EngineOptions = { freeOnGameThread = false }
function Kit.setup(options)
    if type(options) ~= "table" then return end
    EngineOptions.freeOnGameThread = options.FreeObjectsOnGameThread == true
end
-- Where the engine frees the memory of destroyed objects: on a thread of its
-- own (the game's way), or on the game's main thread. Read after every map
-- load and noted for the diagnostics; changed only when Scripts/config.lua
-- asks for it (Config.Engine.FreeObjectsOnGameThread). The change is made
-- here, inside the map load hook: the engine has just finished a complete
-- clean-up, and the setting must not change while one is under way.
local DESTRUCTION = "gc.MultithreadedDestructionEnabled"
local SetHere = false           -- the value read is the one this mod set
local function objectDestruction()
    local world = engineWorld()
    local library = world and Kit.findOnce(SYSTEM_LIBRARY) or nil
    if not library then return end
    local before = number(call(library, "GetConsoleVariableIntValue", DESTRUCTION))
    if before == nil then
        note("kit.object_destruction", "not readable")
        return
    end
    if EngineOptions.freeOnGameThread and before ~= 0 then
        try(library, "ExecuteConsoleCommand", world, DESTRUCTION .. " 0", nil)
        local after = number(call(library, "GetConsoleVariableIntValue", DESTRUCTION))
        SetHere = after == 0
        note("kit.object_destruction", SetHere and "game thread (set by this mod)" or "worker thread (the setting did not take)")
        return
    end
    if before ~= 0 then SetHere = false end
    note("kit.object_destruction", before ~= 0 and "worker thread (the game's own way)" or SetHere and "game thread (set by this mod)" or "game thread")
end

-- ---------------------------------------------------------------------------
-- World changes: map loads. Callbacks get "before" / "after".
-- ---------------------------------------------------------------------------
local World = { loading = false, since = 0, listeners = {}, havePost = false, seen = false }
local LOADING_LIMIT = 20        -- a load that never reports its end is not waited for longer (seconds)

local Hero       -- forward: the hero cache, dropped on a world change
local function worldChange(phase)
    if Hero then Hero.drop() end
    for _, f in ipairs(World.listeners) do pcall(f, phase) end
end
function Kit.onWorldChange(f)
    if type(f) == "function" then World.listeners[#World.listeners + 1] = f end
end
-- True between the two map load hooks (at most LOADING_LIMIT seconds).
function Kit.loading()
    if World.loading and clock() - World.since >= LOADING_LIMIT then World.loading = false end
    return World.loading
end
-- (UE4SS hands the hooks the engine object first; nothing may be returned from them but nil or a boolean)
if type(RegisterLoadMapPostHook) == "function" then
    World.havePost = pcall(RegisterLoadMapPostHook, function(engine)
        World.loading = false
        pcall(rememberEngine, engine)
        worldChange("after")
        pcall(objectDestruction)
    end)
end
local warmPaths      -- forward (end of the file): the kit's own paths, looked up at quiet moments
if type(RegisterLoadMapPreHook) == "function" then
    pcall(RegisterLoadMapPreHook, function(engine)
        World.loading, World.since = World.havePost, clock()      -- without the second hook nothing waits
        pcall(rememberEngine, engine)
        if not World.seen then
            World.seen = true
            pcall(warmPaths)
        end
        worldChange("before")
    end)
end

-- ---------------------------------------------------------------------------
-- The first live object of a class (the game's subsystems, managers). The
-- search compares every object's class, so the answer is kept: it is checked
-- on every call (still there, still the same object) and searched again at
-- most every few seconds while there is none.
-- ---------------------------------------------------------------------------
local FIRST_EVERY = 3
local First = {}
function Kit.firstOf(class)
    if type(class) ~= "string" then return nil end
    local e = First[class]
    if e == nil then
        e = { searchAt = 0 }
        First[class] = e
    end
    if e.object ~= nil then
        if valid(e.object) and fullName(e.object) == e.name then return e.object end
        e.object, e.name = nil, nil
    end
    local now = clock()
    if now < e.searchAt then return nil end
    e.searchAt = now + FIRST_EVERY
    local ok, o = pcall(FindFirstOf, class)
    if ok and valid(o) then
        local name = fullName(o)
        if name and not isDefaultName(name) then
            e.object, e.name = o, name
            return o
        end
    end
    return nil
end
Kit.onWorldChange(function()
    for _, e in pairs(First) do e.object, e.name, e.searchAt = nil, nil, 0 end
end)

-- ---------------------------------------------------------------------------
-- Subsystems, asked from the engine: `kind` says who owns the subsystem -
-- "world", "instance" (the game instance) or "state" (the game's own
-- game-state subsystems: the game clock, quests, weather) -, `place` where
-- its class is ("G1R", "Angelscript", "Engine"). The object handed out is
-- used for a few seconds, then the engine is asked again. Without the engine
-- object, when the library or the class is not found, or while the engine's
-- way has not answered once in this run (see lastWord above), the answer
-- comes from Kit.firstOf (a search among all objects, as before).
-- ---------------------------------------------------------------------------
local SUBSYSTEM_WAYS = {
    world = { "/Script/Engine.Default__SubsystemBlueprintLibrary", "GetWorldSubsystem" },
    instance = { "/Script/Engine.Default__SubsystemBlueprintLibrary", "GetGameInstanceSubsystem" },
    state = { "/Script/GameStateSubsystem.Default__GameStateSubsystemBlueprintLibrary", "GetGameStateSubsystem" },
}
local SUBSYSTEM_FRESH = 5       -- seconds a subsystem is used before the engine is asked again
local SUBSYSTEM_EVERY = 1       -- seconds between two questions while there is none
local Subsystems = {}
function Kit.subsystem(kind, class, place)
    local way = SUBSYSTEM_WAYS[kind]
    if not way or type(class) ~= "string" then return nil end
    local key = kind .. ":" .. class
    local e = Subsystems[key]
    if e == nil then
        e = { askAt = 0, freshUntil = 0, doubted = false }
        Subsystems[key] = e
    end
    local now = clock()
    if e.object ~= nil then
        if now < e.freshUntil and valid(e.object) and fullName(e.object) == e.name then return e.object end
        e.object, e.name = nil, nil
    end
    local world = engineWorld()
    local library = world and Kit.findOnce(way[1]) or nil
    local classObject = library and Kit.findClass(class, place) or nil
    if classObject then
        if now >= e.askAt then
            local o = call(library, way[2], world, classObject)
            local name = valid(o) and fullName(o) or nil
            if name and not isDefaultName(name) then
                e.object, e.name, e.freshUntil, e.askAt, e.doubted = o, name, now + SUBSYSTEM_FRESH, 0, false
                lastWord(key, true, now)
                note("kit.subsystem_by", "engine", class)
                return o
            end
            e.askAt = now + SUBSYSTEM_EVERY
            e.doubted = not lastWord(key, false, now)
        end
        if not e.doubted then return nil end
    end
    -- the engine's way is not there, or it has not answered once in this run: the search
    local o = Kit.firstOf(class)
    if o then note("kit.subsystem_by", classObject and "search (the engine's own way answered nothing)" or "search", class) end
    return o
end
Kit.onWorldChange(function()
    for _, e in pairs(Subsystems) do e.object, e.name, e.askAt, e.freshUntil, e.doubted = nil, nil, 0, 0, false end
    NoneSince = {}              -- the engine's "none" is counted from the new world on
end)

-- ---------------------------------------------------------------------------
-- An object this mod made itself (an image it imported) lives only as long
-- as something of the game refers to it. keepAlive puts it into the game
-- instance's own list of referenced objects - the engine's place for this -,
-- reads the entry back, and only then says true: from then on the object
-- stays until the game is closed, so it must only be used for the few things
-- that are made once per run. After one failure it is not tried again.
-- ---------------------------------------------------------------------------
local Keep = { kept = {}, count = 0, failed = nil }
function Kit.keepAlive(object)
    if Keep.failed then return false, Keep.failed end
    if not valid(object) then return false, "not an object" end
    local address = addressOf(object)
    if address == nil then return false, "the object has no address" end
    if Keep.kept[address] then return true end
    local instance = Kit.gameInstance()
    if not instance then return false, "no game instance yet" end       -- asked again with the next object
    local function fail(why)
        Keep.failed = why
        note("kit.keep_alive", "not available", why)
        return false, why
    end
    local list = get(instance, "ReferencedObjects")
    local n = count(list)
    if n == nil then return fail("the game instance's list cannot be read") end
    local ok = pcall(function() list[n + 1] = object end)
    if not ok or count(list) ~= n + 1 then return fail("the game instance's list cannot be added to") end
    local back = unwrap(get(list, n + 1))            -- (inside the list's length: nothing is added by reading)
    if not valid(back) or addressOf(back) ~= address then return fail("the entry does not read back") end
    Keep.kept[address], Keep.count = true, Keep.count + 1
    note("kit.keep_alive", "works")
    return true
end
function Kit.keptAlive() return Keep.count end

-- ---------------------------------------------------------------------------
-- The hero: player controller -> player state -> ability system -> attributes
-- ---------------------------------------------------------------------------
local CONTROLLER_EVERY = 3      -- seconds between searches for the controller
local CONTROLLER_FRESH = 0.2    -- seconds the engine's answer is used before it is asked again (less than one look of the modules)
local CONTROLLER_ASK = 0.5      -- seconds between two questions to the engine while there is none
local STATELESS_RECHECK = 15    -- a controller without a player state for this long is searched again
local LIST_TRIES = 3            -- looks at a state's attribute list before the search takes over
local SCAN_FIRST, SCAN_MAX = 5, 60
local VERIFY_EVERY = 5          -- seconds between checks that kept attributes are still the state's

Hero = { controller = nil, controllerName = nil, searchAt = 0, askAt = 0, engineAnswers = false, engineAsked = false,
    statelessSince = nil, sets = {} }
function Hero.drop()
    Hero.controller, Hero.controllerName, Hero.searchAt, Hero.statelessSince = nil, nil, 0, nil
    Hero.askAt, Hero.engineAnswers, Hero.engineAsked = 0, false, false
    Hero.sets = {}
end

-- The engine's own answer: the first player controller of the world the game
-- shows. Second result: whether the engine could be asked at all.
local function engineController()
    local world = engineWorld()
    local statics = world and Kit.findOnce(STATICS) or nil
    if not statics then return nil, false end
    local c = call(statics, "GetPlayerController", world, 0)
    local name = valid(c) and fullName(c) or nil
    if name and not isDefaultName(name) then return c, true, name end
    return nil, true
end

-- The hero's player controller, or nil. With the engine object: what the
-- engine says, asked anew for every look of the modules (a controller kept
-- from an earlier look is not relied on: dev/FACTS.md, U17). Without it, or
-- while the engine's way has not answered once: kept under its full name and
-- searched for when it is gone.
function Kit.controller()
    local now = clock()
    if now >= Hero.askAt then
        local found, asked, name = engineController()
        Hero.engineAsked = asked
        Hero.engineAnswers = asked and lastWord("controller", found ~= nil, now)
        if Hero.engineAnswers then
            -- (none: the main menu before a game, a map is loading - nothing to search for)
            Hero.askAt = now + (found and CONTROLLER_FRESH or CONTROLLER_ASK)
            Hero.controller, Hero.controllerName, Hero.statelessSince = found, name, nil
            if found then note("kit.controller_by", "engine") end
            return found
        end
        Hero.askAt = now + CONTROLLER_ASK
    end
    local c = Hero.controller
    if c ~= nil then
        if valid(c) and fullName(c) == Hero.controllerName then return c end
        Hero.controller, Hero.controllerName = nil, nil
    end
    if Hero.engineAnswers then return nil end
    if now < Hero.searchAt then return nil end
    Hero.searchAt = now + CONTROLLER_EVERY
    local how = Hero.engineAsked and "search (the engine's own way answered nothing)" or "search"
    for _, class in ipairs({ "GothicPlayerControllerBaseBP_C", "PlayerController" }) do
        local ok, list = pcall(FindAllOf, class)
        if ok and type(list) == "table" then
            local spare, spareName = nil, nil
            for i = #list, 1, -1 do
                local o = list[i]
                local name = valid(o) and fullName(o) or nil
                if name and not isDefaultName(name) then
                    if valid(get(o, "PlayerState")) then        -- the one that has a hero
                        Hero.controller, Hero.controllerName, Hero.statelessSince = o, name, nil
                        note("kit.controller_by", how)
                        return o
                    end
                    if not spare then spare, spareName = o, name end
                end
            end
            if spare then
                Hero.controller, Hero.controllerName, Hero.statelessSince = spare, spareName, nil
                note("kit.controller_by", how)
                return spare
            end
        end
    end
    return nil
end

-- The hero's player state and its full name, or nil.
function Kit.playerState()
    local c = Kit.controller()
    if not c then return nil end
    local state = get(c, "PlayerState")
    local name = valid(state) and fullName(state) or nil
    if not name then
        local now = clock()
        Hero.statelessSince = Hero.statelessSince or now
        if now - Hero.statelessSince >= STATELESS_RECHECK then Hero.controller, Hero.controllerName = nil, nil end
        return nil
    end
    Hero.statelessSince = nil
    return state, name
end
function Kit.pawn()
    local c = Kit.controller()
    if not c then return nil end
    local p = call(c, "K2_GetPawn")
    if valid(p) then return p end
    p = get(c, "Pawn")
    if valid(p) then return p end
    return nil
end
function Kit.world()
    local w = engineWorld()
    if w then return w end
    local c = Kit.controller()
    w = c and call(c, "GetWorld") or nil
    if valid(w) then return w end
    return nil
end

-- True while the game is paused (as the engine sees it). When that cannot be
-- asked the answer is false.
function Kit.paused()
    local w = Kit.world()
    if not w then return false end
    local statics = Kit.findOnce(STATICS)
    if not statics then return false end
    return call(statics, "IsGamePaused", w) == true
end

-- The game's own clock in seconds of game time (it jumps when the hero
-- sleeps; whether it stands still in the game's menus is not known), or nil.
-- One day has 86400 of them.
function Kit.gameSeconds()
    local subsystem = Kit.subsystem("state", "GameTimeSubsystem", "G1R")
    if not subsystem then return nil end
    local how = "property"
    local current = get(subsystem, "CurrentGameTime")
    local t = number(get(current, "TotalSeconds"))
    if t == nil and current ~= nil then
        t, how = number(get(unwrap(current), "TotalSeconds")), "property (wrapped)"
    end
    if t == nil then
        t, how = number(get(call(subsystem, "GetCurrentGameTime"), "TotalSeconds")), "function"
    end
    if t ~= nil then note("kit.game_time_source", how) end
    return t
end

local function inList(state, part)
    local sets = get(get(state, "AbilitySystemComponent"), "SpawnedAttributes")
    if sets == nil then return nil end
    local class = "AttributeSet_" .. part
    local found, foundName = nil, nil
    pcall(function()
        sets:ForEach(function(_, element)
            local o = unwrap(element)
            local name = valid(o) and fullName(o) or nil
            if name and not isDefaultName(name) and name:match("^(%S+)") == class then
                found, foundName = o, name
                return true     -- ends the loop
            end
        end)
    end)
    return found, foundName
end
local function byScan(stateName, part)
    local ok, list = pcall(FindAllOf, "AttributeSet_" .. part)
    if not ok or type(list) ~= "table" then return nil end
    local owner = stateName:match("([^%.:/%s]+)$")
    local only, onlyName, candidates = nil, nil, 0
    for i = #list, 1, -1 do
        local o = list[i]
        local name = valid(o) and fullName(o) or nil
        if name and not isDefaultName(name) and name:find("PlayerState", 1, true) then
            candidates = candidates + 1
            if owner and name:find("." .. owner .. ".", 1, true) then return o, name end
            if only == nil then only, onlyName = o, name end
        end
    end
    if candidates == 1 then return only, onlyName end
    return nil
end

-- The hero's attribute set of the class AttributeSet_<part> ("LevelProgression",
-- "Health", "Mana", "Strength", ...). Returns the object, how it was found
-- ("player state" / "scan") and when, or nil. Cheap to call often: the object
-- is kept, compared by name on every call and checked against the state's
-- list now and then.
function Kit.attributeSet(part)
    local state, stateName = Kit.playerState()
    if not state then return nil end
    local now = clock()
    local e = Hero.sets[part]
    if e == nil or e.stateName ~= stateName then
        e = { stateName = stateName, tries = 0, tryAt = 0, scanAt = 0, scanEvery = SCAN_FIRST }
        Hero.sets[part] = e
    end
    if e.set ~= nil then
        -- (the name is the one the set was found under: a set is only ever kept with a name that could be read,
        -- so a wrapper whose name cannot be read any more never passes for the kept one)
        if valid(e.set) and fullName(e.set) == e.name then
            if e.via == "player state" and now >= e.verifyAt then
                e.verifyAt = now + VERIFY_EVERY
                local current, currentName = inList(state, part)
                if current ~= nil and currentName ~= e.name then      -- the state has other attributes now
                    e.set, e.name, e.foundAt = current, currentName, now
                end
            end
            return e.set, e.via, e.foundAt
        end
        e.set, e.name = nil, nil
        e.tries, e.tryAt = 0, 0
    end
    local set, name, via = nil, nil, "player state"
    if e.tries < LIST_TRIES and now >= e.tryAt then
        e.tries, e.tryAt = e.tries + 1, now + 1
        set, name = inList(state, part)
    end
    if not set then
        if e.tries < LIST_TRIES or now < e.scanAt then return nil end
        set, name = byScan(stateName, part)
        via = "scan"
        if not set then
            e.scanAt, e.scanEvery = now + e.scanEvery, min(e.scanEvery * 2, SCAN_MAX)
            return nil
        end
    end
    e.set, e.name, e.via, e.foundAt, e.verifyAt = set, name, via, now, now + VERIFY_EVERY
    e.scanAt, e.scanEvery = 0, SCAN_FIRST
    return set, via, now
end

-- Current and base value of an attribute, or nil when it cannot be read.
-- The AttributeSet_<part> of another character's state (an NPC's, the
-- scavenger's), from that state's own list of attribute sets: asked anew at
-- every call, nothing kept. The set and its full name, or nil.
function Kit.attributeSetOf(state, part)
    if not valid(state) then return nil end
    return inList(state, part)
end

function Kit.readAttribute(set, name)
    local a = get(set, name)
    if a == nil then return nil end
    local current, base = number(get(a, "CurrentValue")), number(get(a, "BaseValue"))
    if current == nil then return nil end
    return current, base
end
-- Writes base and current value and reads both back. True when both stayed.
function Kit.writeAttribute(set, name, value)
    if not valid(set) or number(value) == nil then return false, "nothing to write to" end
    local ok = pcall(function()
        local a = set[name]
        a.BaseValue = value
        a.CurrentValue = value
    end)
    if not ok then return false, "the write raised an error" end
    -- the game keeps these numbers in single precision: what comes back may differ in the last digits
    local current, base = Kit.readAttribute(set, name)
    local slack = max(0.001, abs(value) * 0.000001)
    if current == nil or base == nil or abs(current - value) > slack or abs(base - value) > slack then
        return false, "the value did not stay"
    end
    return true
end

-- The hero's attribute `name` in the attribute set `part`: current value, base
-- value and the set (for writeAttribute), or nil.
--   local health, _, set = Kit.attribute("Health", "Health")
function Kit.attribute(part, name)
    local set = Kit.attributeSet(part)
    if not set then return nil end
    local current, base = Kit.readAttribute(set, name)
    if current == nil then return nil end
    return current, base, set
end

-- ---------------------------------------------------------------------------
-- Keys. UE4SS calls a key's function on its own thread, where nothing of the
-- game may be touched: that function only notes the press, and a loop on the
-- game thread (every 50 ms, started with the first key) runs the action.
-- UE4SS cannot take a key back, so a key combination is registered once per
-- run and asks at each press what is bound to it now: a binding can be moved
-- to another key while the game runs.
--
-- A combination is written "Y", "CTRL+Y", "SHIFT+ALT+F5": modifiers CTRL,
-- SHIFT, ALT, then one key by its UE4SS name (the numbers are Windows
-- virtual-key codes, which is what RegisterKeyBind takes).
-- ---------------------------------------------------------------------------
local KEY_CODES = {
    MIDDLE_MOUSE_BUTTON = 4, XBUTTON_ONE = 5, XBUTTON_TWO = 6, BACKSPACE = 8, TAB = 9, RETURN = 13, PAUSE = 19,
    CAPS_LOCK = 20, SPACE = 32, PAGE_UP = 33, PAGE_DOWN = 34, END = 35, HOME = 36, LEFT_ARROW = 37, UP_ARROW = 38,
    RIGHT_ARROW = 39, DOWN_ARROW = 40, INS = 45, DEL = 46, ZERO = 48, ONE = 49, TWO = 50, THREE = 51, FOUR = 52,
    FIVE = 53, SIX = 54, SEVEN = 55, EIGHT = 56, NINE = 57, A = 65, B = 66, C = 67, D = 68, E = 69, F = 70, G = 71,
    H = 72, I = 73, J = 74, K = 75, L = 76, M = 77, N = 78, O = 79, P = 80, Q = 81, R = 82, S = 83, T = 84, U = 85,
    V = 86, W = 87, X = 88, Y = 89, Z = 90, NUM_ZERO = 96, NUM_ONE = 97, NUM_TWO = 98, NUM_THREE = 99,
    NUM_FOUR = 100, NUM_FIVE = 101, NUM_SIX = 102, NUM_SEVEN = 103, NUM_EIGHT = 104, NUM_NINE = 105, MULTIPLY = 106,
    ADD = 107, SUBTRACT = 109, DECIMAL = 110, DIVIDE = 111, F1 = 112, F2 = 113, F3 = 114, F4 = 115, F5 = 116,
    F6 = 117, F7 = 118, F8 = 119, F9 = 120, F10 = 121, F11 = 122, F12 = 123, NUM_LOCK = 144, SCROLL_LOCK = 145,
    OEM_ONE = 186, OEM_PLUS = 187, OEM_COMMA = 188, OEM_MINUS = 189, OEM_PERIOD = 190, OEM_TWO = 191,
    OEM_THREE = 192, OEM_FOUR = 219, OEM_FIVE = 220, OEM_SIX = 221, OEM_SEVEN = 222, OEM_EIGHT = 223, OEM_102 = 226,
}
-- other spellings people use
local KEY_ALIASES = {
    ["0"] = "ZERO", ["1"] = "ONE", ["2"] = "TWO", ["3"] = "THREE", ["4"] = "FOUR", ["5"] = "FIVE", ["6"] = "SIX",
    ["7"] = "SEVEN", ["8"] = "EIGHT", ["9"] = "NINE", NUM0 = "NUM_ZERO", NUM1 = "NUM_ONE", NUM2 = "NUM_TWO",
    NUM3 = "NUM_THREE", NUM4 = "NUM_FOUR", NUM5 = "NUM_FIVE", NUM6 = "NUM_SIX", NUM7 = "NUM_SEVEN", NUM8 = "NUM_EIGHT",
    NUM9 = "NUM_NINE", INSERT = "INS", DELETE = "DEL", ENTER = "RETURN", PGUP = "PAGE_UP", PGDN = "PAGE_DOWN",
    PAGEUP = "PAGE_UP", PAGEDOWN = "PAGE_DOWN", UP = "UP_ARROW", DOWN = "DOWN_ARROW", LEFT = "LEFT_ARROW",
    RIGHT = "RIGHT_ARROW", MOUSE3 = "MIDDLE_MOUSE_BUTTON", MOUSE4 = "XBUTTON_ONE", MOUSE5 = "XBUTTON_TWO",
    CAPSLOCK = "CAPS_LOCK", NUMLOCK = "NUM_LOCK", SCROLLLOCK = "SCROLL_LOCK",
}
local MODIFIER_CODES = { CTRL = 17, SHIFT = 16, ALT = 18 }       -- UE4SS ModifierKey.CONTROL / SHIFT / ALT
local MODIFIER_ALIASES = { CONTROL = "CTRL", STRG = "CTRL", CTRL = "CTRL", SHIFT = "SHIFT", ALT = "ALT" }
local MODIFIER_ORDER = { "CTRL", "SHIFT", "ALT" }

-- A key combination as text -> its usual spelling ("ctrl + y" -> "CTRL+Y"),
-- the key's code and the list of modifier codes. "" (no key) -> "". Not
-- usable -> nil and why.
function Kit.keyCombo(text)
    if type(text) ~= "string" then return nil, "a key is written as text" end
    local compact = text:gsub("%s+", ""):upper()
    if compact == "" then return "", nil, {} end
    local held, key = {}, nil
    for part in (compact .. "+"):gmatch("([^+]*)%+") do
        local modifier = MODIFIER_ALIASES[part]
        if modifier then
            held[modifier] = true
        else
            part = KEY_ALIASES[part] or part
            if KEY_CODES[part] == nil then return nil, "unknown key " .. (part == "" and "(nothing)" or part) end
            if key ~= nil then return nil, "more than one key (" .. key .. ", " .. part .. ")" end
            key = part
        end
    end
    if key == nil then return nil, "only modifier keys" end
    local names, codes = {}, {}
    for _, modifier in ipairs(MODIFIER_ORDER) do
        if held[modifier] then
            names[#names + 1] = modifier
            codes[#codes + 1] = MODIFIER_CODES[modifier]
        end
    end
    names[#names + 1] = key
    return table.concat(names, "+"), KEY_CODES[key], codes
end
-- The names keyCombo knows, sorted (for the documentation and the tests).
function Kit.keyNames()
    local names = {}
    for name in pairs(KEY_CODES) do names[#names + 1] = name end
    table.sort(names)
    return names
end

local Keys = { combos = {}, bindings = {}, order = {}, pump = nil }
local KEY_PUMP_MS = 50
local KEY_COOLDOWN = 0.3            -- seconds between two runs of one binding (a held key, a double press)

local function pumpKeys()
    local loading = Kit.loading()
    local now = clock()
    for _, combo in pairs(Keys.combos) do
        if combo and combo.pressed then
            combo.pressed = false
            if not loading then             -- a press during a map load is dropped
                for _, id in ipairs(Keys.order) do
                    local b = Keys.bindings[id]
                    if b.combo == combo and now - b.lastAt >= b.cooldown then
                        b.lastAt = now
                        local ok, err = pcall(b.action)
                        if not ok then Log.once("key:" .. id .. ":" .. tostring(err), "the action of key " .. combo.text .. " (" .. id .. ") failed: " .. firstLine(err)) end
                    end
                end
            end
        end
    end
end

-- Binds an action to a key combination, or moves the binding `id` to another
-- one. text "" or nil: the binding has no key. Returns true and the usual
-- spelling, or false and why (then the binding has no key).
--   Kit.bindKey("thing.skip", Cfg.Key, function() ... end)      at load
--   Kit.bindKey("thing.skip", Cfg.Key)                           when the setting changed
function Kit.bindKey(id, text, action, cooldown)
    if type(id) ~= "string" then return false, "bindKey needs a name" end
    local b = Keys.bindings[id]
    if b == nil then
        if type(action) ~= "function" then return false, "bindKey needs an action" end
        b = { id = id, action = action, cooldown = KEY_COOLDOWN, lastAt = -huge }
        Keys.bindings[id] = b
        Keys.order[#Keys.order + 1] = id
        table.sort(Keys.order)
    elseif type(action) == "function" then
        b.action = action
    end
    if number(cooldown) then b.cooldown = max(0, cooldown) end
    b.combo, b.text = nil, ""
    if text == nil or text == "" then return true, "" end
    local canonical, code, modifiers = Kit.keyCombo(text)
    if canonical == nil then return false, code end
    if canonical == "" then return true, "" end
    local combo = Keys.combos[canonical]
    if combo == false then return false, "the key could not be registered earlier in this run" end
    if combo == nil then
        if type(RegisterKeyBind) ~= "function" or type(LoopInGameThreadWithDelay) ~= "function" then
            return false, "this UE4SS build has no key bindings"
        end
        combo = { text = canonical, pressed = false }
        local function pressed() combo.pressed = true end       -- runs on UE4SS's own thread: nothing else happens here
        local ok, err
        if #modifiers > 0 then ok, err = pcall(RegisterKeyBind, code, modifiers, pressed) else ok, err = pcall(RegisterKeyBind, code, pressed) end
        if not ok then
            Keys.combos[canonical] = false          -- not tried again in this run
            return false, "the key could not be registered (" .. firstLine(err) .. ")"
        end
        Keys.combos[canonical] = combo
        if Keys.pump == nil then
            Keys.pump = pcall(LoopInGameThreadWithDelay, KEY_PUMP_MS, pumpKeys)
            if not Keys.pump then Log.once("keys", "no timer for the keys: key bindings do nothing in this run") end
        end
    end
    if Keys.pump == false then return false, "no timer for the keys" end
    b.combo, b.text = combo, canonical
    return true, canonical
end
-- The key a binding has now ("" = none).
function Kit.boundKey(id) return Keys.bindings[id] and Keys.bindings[id].text or "" end
-- What a binding does, in a few words, for the list of keys ("wait 30 minutes"): a text, or a function that
-- gives one when the list is made. False for a binding that does not exist or a label that is neither.
function Kit.describeKey(id, label)
    local b = Keys.bindings[id]
    if b == nil or (type(label) ~= "string" and type(label) ~= "function") then return false end
    b.label = label
    return true
end
-- The bindings that have a key now, in the order of their names: { id, key, label } (label "" when the binding
-- was not described, or its function failed or gave no text).
function Kit.keyList()
    local list = {}
    for _, id in ipairs(Keys.order) do
        local b = Keys.bindings[id]
        if b.text ~= "" then
            local label = b.label
            if type(label) == "function" then
                local ok, v = pcall(label)
                label = ok and v or nil
            end
            list[#list + 1] = { id = id, key = b.text, label = type(label) == "string" and label or "" }
        end
    end
    return list
end

-- ---------------------------------------------------------------------------
-- Messages on screen
-- ---------------------------------------------------------------------------
local TEXT_LIBRARY = "/Script/Engine.Default__KismetTextLibrary"
function Kit.text(s)
    local library = Kit.findOnce(TEXT_LIBRARY)
    if not library then return nil end
    return call(library, "Conv_StringToText", tostring(s))
end

-- The game's own line at the top of the screen (the one conversations use).
function Kit.subtitle(message, seconds)
    local world = Kit.world()
    if not world then return false end
    local statics = Kit.findOnce("/Script/G1R.Default__ConversationStatics")
    if not statics then return false end
    local empty, text = Kit.text(""), Kit.text(message)
    if empty == nil or text == nil then return false end
    local ok = try(statics, "ShowTopSubtitle", world, empty, text, tonumber(seconds) or 3)
    return ok == true
end

-- A small note at the top right: black frame, pale yellow inside, black
-- text. Built once from plain widgets. It holds up to four lines, each shown
-- for its own time (several modules can have something to say at once); a
-- line given with a `slot` replaces the earlier line of that slot. When a
-- step fails the note is given up for this run; Kit.toast then returns false.
local Toast = { widget = nil, widgetName = nil, text = nil, shown = false, lines = {}, givenUp = false, why = nil }
local MAX_LINES = 4
-- Where the box sits: anchor and alignment (0 - 1 across and down the screen) and the distance from that corner.
local POSITIONS = {
    ["top right"] = { x = 1, y = 0, dx = -24, dy = 96 },
    ["top left"] = { x = 0, y = 0, dx = 24, dy = 96 },
    ["bottom right"] = { x = 1, y = 1, dx = -24, dy = -160 },
    ["bottom left"] = { x = 0, y = 1, dx = 24, dy = -160 },
}
-- How notes are shown; the module "general" sets this from the player's settings.
local Notes = { style = "box", seconds = 3, position = "top right" }
local VISIBLE, COLLAPSED = 3, 1         -- ESlateVisibility: HitTestInvisible (takes no clicks), Collapsed
local WIDGET_PATHS = {
    "/Script/UMG.Default__WidgetBlueprintLibrary", "/Script/UMG.UserWidget", "/Script/UMG.CanvasPanel",
    "/Script/UMG.Border", "/Script/UMG.TextBlock", TEXT_LIBRARY,
}

-- The letters of the mod's own texts (the notes' box, the modules' boxes):
-- "gothic" (the game's blackletter face, its headlines), "book" (the game's
-- face for running text), "plain" (the engine's own, as up to 0.2.3). The
-- module general sets it from the player's settings. A font of the game that
-- is not found leaves the engine's own (noted as kit.letters).
local FONTS = {
    gothic = "/Game/UI/Fonts/Boucherie-Block_Font.Boucherie-Block_Font",
    book = "/Game/UI/Fonts/NotoSerif-Regular_Font.NotoSerif-Regular_Font",
}
local Letters = { choice = "plain", engine = nil }
-- Gives a text block the letters chosen, of `size` (default 12). The engine's
-- own font is the one a new text block has (kept from the first one: it lasts
-- the run); the widget's own font stays when this is not possible.
local function applyLetters(text, size)
    local choice = Letters.choice
    local object = nil
    if choice ~= "plain" then
        object = Kit.findOnce(FONTS[choice])
        if object then note("kit.letters", "set", choice) else note("kit.letters", "not found", FONTS[choice]) end
    end
    pcall(function()
        local font = text.Font
        if Letters.engine == nil then Letters.engine = font.FontObject or false end
        font.Size = size or 12
        if object then
            font.FontObject = object
            font.TypefaceFontName = FName("Default")
        else
            if Letters.engine then font.FontObject = Letters.engine end
            font.TypefaceFontName = FName("Regular")
        end
        text:SetFont(font)
    end)
end

local function giveUp(why)
    if valid(Toast.widget) then pcall(function() Toast.widget:SetVisibility(COLLAPSED) end) end
    Toast.givenUp, Toast.why = true, why
    Toast.widget, Toast.text, Toast.shown, Toast.lines = nil, nil, false, {}
    Log.once("toast", "notes on screen are not available (" .. tostring(why) .. ")")
    note("kit.toast", "not available", why)
end

-- Searches the six paths the note needs. Meant for a quiet moment (a module
-- calls it when it has found the hero), so that no search falls into a fight.
function Kit.prepareToast()
    if Toast.givenUp then return false end
    for _, path in ipairs(WIDGET_PATHS) do
        if not Kit.findOnce(path) then
            giveUp("not found: " .. path)
            return false
        end
    end
    return true
end

-- A box in the notes' look (black frame, pale yellow inside, black letters of
-- `size`, default 12, the space around them in step) on a widget of its own,
-- hidden: anchored at `at` (an entry of POSITIONS, or one like it) and put on
-- the screen's layer `z`. Returns the widget and its text; nil and false while
-- there is no hero (nothing was made); nil and why when it cannot be built.
local function buildBox(at, z, size)
    size = size or 12
    local owner = Kit.controller()
    if not owner then return nil, false end
    for _, path in ipairs(WIDGET_PATHS) do
        if not Kit.findOnce(path) then return nil, "not found: " .. path end
    end
    if type(StaticConstructObject) ~= "function" then return nil, "this UE4SS build has no StaticConstructObject" end
    local library = Kit.findOnce(WIDGET_PATHS[1])
    local widget = call(library, "Create", owner, Kit.findOnce(WIDGET_PATHS[2]), owner)
    local tree = get(widget, "WidgetTree")
    if not valid(widget) or not valid(tree) then return nil, "the widget could not be created" end
    local function make(path)
        local ok, o = pcall(StaticConstructObject, Kit.findOnce(path), tree)
        if ok and valid(o) then return o end
        return nil
    end
    local canvas, frame, fill, text = make(WIDGET_PATHS[3]), make(WIDGET_PATHS[4]), make(WIDGET_PATHS[4]), make(WIDGET_PATHS[5])
    if not (canvas and frame and fill and text) then return nil, "a widget could not be created" end
    applyLetters(text, size)
    local function step(n) return math.floor(n * size / 12 + 0.5) end
    local ok = pcall(function()
        tree.RootWidget = canvas
        frame:SetBrushColor({ R = 0, G = 0, B = 0, A = 1 })
        frame:SetPadding({ Left = 1, Top = 1, Right = 1, Bottom = 1 })
        fill:SetBrushColor({ R = 1, G = 1, B = 0.753, A = 1 })
        fill:SetPadding({ Left = step(9), Top = step(4), Right = step(9), Bottom = step(5) })
        text:SetColorAndOpacity({ SpecifiedColor = { R = 0, G = 0, B = 0, A = 1 }, ColorUseRule = 0 })
        fill:SetContent(text)
        frame:SetContent(fill)
        local slot = canvas:AddChildToCanvas(frame)
        slot:SetAnchors({ Minimum = { X = at.x, Y = at.y }, Maximum = { X = at.x, Y = at.y } })
        slot:SetAlignment({ X = at.x, Y = at.y })
        slot:SetPosition({ X = at.dx, Y = at.dy })
        slot:SetAutoSize(true)
        widget:SetVisibility(COLLAPSED)
        widget:AddToViewport(z)
    end)
    if not ok then return nil, "the widget could not be put together" end
    return widget, text
end

local function buildToast()
    if not Kit.controller() then return false end              -- no hero yet: the next note tries again
    if not Kit.prepareToast() then return false end
    local widget, text = buildBox(POSITIONS[Notes.position] or POSITIONS["top right"], 60)
    if not widget then
        if text then giveUp(text) end
        return false
    end
    Toast.widget, Toast.widgetName, Toast.text, Toast.shown = widget, fullName(widget), text, false
    return true
end

local function toastAlive()
    return valid(Toast.widget) and valid(Toast.text) and fullName(Toast.widget) == Toast.widgetName
end

local function collapse()
    if not Toast.shown then return end
    Toast.shown = false
    if toastAlive() then pcall(function() Toast.widget:SetVisibility(COLLAPSED) end) end
end

-- Puts the lines that are up on screen. True when they are shown (or there is
-- nothing to show), false when the note cannot be shown now.
local function draw()
    if #Toast.lines == 0 then
        collapse()
        return true
    end
    -- a widget lives as long as its world: after a map change it is built again
    if not toastAlive() then
        Toast.widget, Toast.text, Toast.shown = nil, nil, false
        if not buildToast() then return false end
    end
    local parts = {}
    for _, line in ipairs(Toast.lines) do parts[#parts + 1] = line.text end
    local text = Kit.text(table.concat(parts, "\n"))
    if text == nil then
        giveUp("text could not be made")
        return false
    end
    local set = pcall(function()
        -- the game can clear its viewport without destroying the widget
        if Toast.widget:IsInViewport() == false then Toast.widget:AddToViewport(60) end
        Toast.text:SetText(text)
        Toast.widget:SetVisibility(VISIBLE)
    end)
    if not set then
        giveUp("the text could not be set")
        return false
    end
    Toast.shown = true
    note("kit.toast", "shown")
    return true
end

-- Shows a line for `seconds` (default 3). True when it is on screen.
function Kit.toast(message, seconds, slot)
    if Toast.givenUp then return false end
    local line = { text = tostring(message), hideAt = clock() + (tonumber(seconds) or 3), slot = slot }
    local kept = Toast.lines
    local lines = {}
    local placed = false
    for _, l in ipairs(kept) do
        if slot ~= nil and l.slot == slot then
            lines[#lines + 1] = line
            placed = true
        else
            lines[#lines + 1] = l
        end
    end
    if not placed then lines[#lines + 1] = line end
    while #lines > MAX_LINES do table.remove(lines, 1) end
    Toast.lines = lines
    local ok, shown = pcall(draw)
    if not ok then
        giveUp(shown)
        return false
    end
    if not shown and not Toast.givenUp then Toast.lines = {} end       -- no hero yet: the next note starts afresh
    return shown
end
-- Takes the line of a slot off the screen (without a slot: every line).
function Kit.hideToast(slot)
    if slot == nil then
        Toast.lines = {}
        collapse()
        return
    end
    local lines, removed = {}, false
    for _, l in ipairs(Toast.lines) do
        if l.slot == slot then removed = true else lines[#lines + 1] = l end
    end
    if not removed then return end
    Toast.lines = lines
    if not Toast.givenUp and not pcall(draw) then giveUp("the note could not be updated") end
end
function Kit.toastAvailable() return not Toast.givenUp end

-- How notes are shown: style "box" (the small box; the game's own line when
-- the box cannot be shown), "subtitle" (the game's own line) or "off";
-- seconds a note stays; position of the box ("top right", "top left",
-- "bottom right", "bottom left"). Only what is given changes.
function Kit.configureNotes(options)
    if type(options) ~= "table" then return end
    if options.style == "box" or options.style == "subtitle" or options.style == "off" then
        Notes.style = options.style
        if Notes.style ~= "box" then Kit.hideToast() end
    end
    if number(options.seconds) and options.seconds > 0 then Notes.seconds = options.seconds end
    if POSITIONS[options.position] and options.position ~= Notes.position then
        Notes.position = options.position
        -- the box is built again at its new place with the next note
        if toastAlive() then
            pcall(function()
                Toast.widget:SetVisibility(COLLAPSED)
                Toast.widget:RemoveFromParent()
            end)
        end
        Toast.widget, Toast.text, Toast.shown, Toast.lines = nil, nil, false, {}
    end
end
-- A note the way the player chose. `slot`: a name of the module's own; its
-- next note replaces this one instead of standing below it. True when shown.
function Kit.notify(message, slot, seconds)
    if Notes.style == "off" then return false end
    seconds = number(seconds) or Notes.seconds
    if Notes.style == "box" and Kit.toast(message, seconds, slot) then return true end
    return Kit.subtitle(message, seconds)
end
-- Searches what notes need, at a quiet moment (when a module has found the
-- hero), so that no search falls into a fight.
function Kit.prepareNotes()
    if Notes.style == "box" then Kit.prepareToast() end
end
Kit.onWorldChange(function() Toast.widget, Toast.text, Toast.shown, Toast.lines = nil, nil, false, {} end)

-- ---------------------------------------------------------------------------
-- A box of lines of a module's own (the list of keys, the timers): the notes'
-- look, at a place of its own, on a layer of its own. Built when it is first
-- shown, built again after a map change or when the game took it away; given
-- up for the run when a step fails (said once, noted as kit.panel).
--   local P = KIT.panel("keys", { position = "top left", dx = 32, dy = 32, z = 1000, size = 10 })
--   P.show({ "line", ... })      true when the lines are on screen
--   P.hide()
--   P.resize(10)                 other letters: built anew at the next show (true when it changes)
--   P.available()                false once given up
-- options: position (a corner as for the notes; default "top left"), dx / dy
-- (the distance from that corner; default the notes'), z (the layer; default 60),
-- size (of the letters: 6 to 40; default the notes' 12).
-- ---------------------------------------------------------------------------
local Panels = {}
local function panelSize(v)
    v = number(v)
    if not v then return nil end
    return math.max(6, math.min(40, math.floor(v + 0.5)))
end
function Kit.panel(id, options)
    if type(id) ~= "string" then return nil end
    local p = Panels[id]
    if p then return p end
    options = type(options) == "table" and options or {}
    local corner = POSITIONS[options.position] or POSITIONS["top left"]
    local at = { x = corner.x, y = corner.y, dx = number(options.dx) or corner.dx, dy = number(options.dy) or corner.dy }
    local z = number(options.z) or 60
    p = { id = id, widget = nil, name = nil, text = nil, shown = false, givenUp = false, why = nil, lines = nil, size = panelSize(options.size) or 12 }
    local function alive() return valid(p.widget) and valid(p.text) and fullName(p.widget) == p.name end
    local function drop(why)
        if valid(p.widget) then pcall(function() p.widget:SetVisibility(COLLAPSED) end) end
        p.widget, p.name, p.text, p.shown, p.lines, p.givenUp, p.why = nil, nil, nil, false, nil, true, why
        Log.once("panel:" .. id, "the box \"" .. id .. "\" is not available (" .. tostring(why) .. ")")
        note("kit.panel", "not available", id .. ": " .. tostring(why))
    end
    function p.available() return not p.givenUp end
    function p.show(lines)
        if p.givenUp then return false end
        if type(lines) ~= "table" then lines = { tostring(lines) } end
        if not alive() then
            p.widget, p.name, p.text, p.shown, p.lines = nil, nil, nil, false, nil
            local widget, text = buildBox(at, z, p.size)
            if not widget then
                if text then drop(text) end
                return false
            end
            p.widget, p.name, p.text = widget, fullName(widget), text
        end
        local joined = {}
        for i, line in ipairs(lines) do joined[i] = tostring(line) end
        joined = table.concat(joined, "\n")
        if p.shown and joined == p.lines then return true end           -- (already on screen as it is)
        local message = Kit.text(joined)
        if message == nil then
            drop("text could not be made")
            return false
        end
        local ok = pcall(function()
            if p.widget:IsInViewport() == false then p.widget:AddToViewport(z) end
            p.text:SetText(message)
            p.widget:SetVisibility(VISIBLE)
        end)
        if not ok then
            drop("the text could not be set")
            return false
        end
        p.shown, p.lines = true, joined
        note("kit.panel", "shown", id)
        return true
    end
    function p.hide()
        if not p.shown then return end
        p.shown, p.lines = false, nil
        if alive() then pcall(function() p.widget:SetVisibility(COLLAPSED) end) end
    end
    function p.resize(size)
        size = panelSize(size)
        if not size or size == p.size then return false end
        p.size = size
        if valid(p.widget) then
            pcall(function()
                p.widget:SetVisibility(COLLAPSED)
                p.widget:RemoveFromParent()
            end)
        end
        p.widget, p.name, p.text, p.shown, p.lines = nil, nil, nil, false, nil
        return true
    end
    Panels[id] = p
    return p
end
Kit.onWorldChange(function()
    for _, p in pairs(Panels) do p.widget, p.name, p.text, p.shown, p.lines = nil, nil, nil, false, nil end
end)

-- The letters of the mod's texts: "gothic", "book" or "plain" (anything else
-- is left out). Boxes that are there get them at once.
function Kit.configureLetters(choice)
    if (FONTS[choice] == nil and choice ~= "plain") or choice == Letters.choice then return end
    Letters.choice = choice
    if toastAlive() then applyLetters(Toast.text) end
    for _, p in pairs(Panels) do
        if valid(p.widget) and valid(p.text) and fullName(p.widget) == p.name then applyLetters(p.text, p.size) end
    end
end
function Kit.letters() return Letters.choice end

-- Called by the loader's quarter-second loop.
function Kit.tick()
    if #Toast.lines == 0 then return end
    local now = clock()
    local lines = {}
    for _, l in ipairs(Toast.lines) do
        if now < l.hideAt then lines[#lines + 1] = l end
    end
    if #lines == #Toast.lines then return end
    Toast.lines = lines
    if Toast.givenUp then return end
    local ok, err = pcall(draw)
    if not ok then giveUp(err) end
end

-- Offline test access (the loader hands the kit to the tests only).
-- The paths this file asks UE4SS for are looked up at the first map load the
-- kit sees: that call comes on the game thread, the engine is complete by
-- then, and in a game that has just been started there is no world to play
-- in yet - a first look-up walks through all objects (Kit.warm), and this is
-- the moment for it. They are parts of the engine and of the game's program:
-- what is not there then will not come, and is not looked up again. (A path
-- needed before that - the mod was started in a running game - is looked up
-- when it is needed, as before 0.2.2.)
Kit.paths = { STATICS, SYSTEM_LIBRARY, SUBSYSTEM_WAYS.world[1], SUBSYSTEM_WAYS.state[1],
    "/Script/G1R.GameTimeSubsystem", "/Script/G1R.PersistentDataSubsystem" }
warmPaths = function()
    local found = Kit.warm(Kit.paths)
    for _, path in ipairs(Kit.paths) do
        if Found[path] == nil then Found[path] = false end
    end
    note("kit.paths_found", ("%d of %d found"):format(found, #Kit.paths), "at the first map load")
end

Kit._test = { hero = Hero, toast = Toast, world = World, found = Found, first = First, hooks = Hooks, keys = Keys, pumpKeys = pumpKeys, notes = Notes, letters = Letters,
    engine = Engine, subsystems = Subsystems, keep = Keep, engineOptions = EngineOptions, proven = Proven,
    noneSince = function() return NoneSince end }

return Kit
