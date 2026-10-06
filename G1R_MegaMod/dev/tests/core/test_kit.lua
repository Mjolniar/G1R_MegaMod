-- ============================================================================
-- Offline tests of the kit (Scripts/core/kit.lua): guarded access, searches
-- that never repeat, the hero and his attributes, world changes, the game
-- clock, keys, notes on screen.
--
--   lua5.4 test_kit.lua          (from any directory)
--
-- Every case loads the file afresh (it keeps its state in upvalues) against the
-- UE4SS mock and the small game model of ../lib/modtest.lua.
-- Last line: "core/kit tests finished: N ok, M failure(s)".
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
local Fake = dofile(HERE .. "../markers/diag_fake.lua")
T.init("core-kit")
T.suite = "core/kit"
local check, section, has = T.check, T.section, T.has
local CORE = T.MOD .. "Scripts/core/"

-- A fresh kit. options: mock (options of the UE4SS mock), world (false = no
-- game model; a function(ue) -> world), widgets (true or options), diag.
local function fresh(options)
    options = options or {}
    local ue = T.Mock.new(options.mock)
    ue:install()
    local c = { ue = ue }
    if options.widgets then c.ui = T.widgets(ue, type(options.widgets) == "table" and options.widgets or nil) end
    if options.world ~= false then c.world = type(options.world) == "function" and options.world(ue) or T.newWorld(ue) end
    if options.diag then
        c.fake = Fake.new()
        rawset(_G, "G1R_DIAG", c.fake.handle)
    end
    c.K = dofile(CORE .. "kit.lua")
    rawset(_G, "G1R_DIAG", nil)
    c.atStart = #ue.lookups     -- what the kit searched by path when it was loaded: nothing (section 17)
    c.t = c.K._test
    function c.ticks(n)
        for _ = 1, n or 1 do
            ue:advance(0.25)
            ue:tick()
            c.K.tick()
        end
    end
    function c.printed(plain) return T.printedCount(ue, plain) end
    function c.allOf() return ue.calls.FindAllOf or 0 end
    return c
end
local function done(c)
    c.ue:uninstall()
    rawset(_G, "StaticConstructObject", nil)
end

-- ---------------------------------------------------------------------------
section("1. guarded access")
do
    local c = fresh({ world = false })
    local K, ue = c.K, c.ue
    local live = ue:object("Thing /Game/Map.Map:Thing_1", { Value = 5, Add = function(self, a, b, d) return (a or 0) + (b or 0) + (d or 0) end,
        Count = function(_, ...) return select("#", ...) end, Boom = function() error("boom") end })
    local dead = ue:invalid()
    local raising = setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() error("no such object") end end
        error("property access failed")
    end })
    local struct = { X = 1, Y = 2 }      -- a struct wrapper: no IsValid
    check(K.valid(live) == true and K.valid(dead) == false and K.valid(nil) == false and K.valid(raising) == false and K.valid(struct) == false and K.valid(5) == false,
        "valid: only an object that says it is")
    check(K.gone(dead) == true and K.gone(live) == false and K.gone(struct) == false and K.gone(nil) == false and K.gone(raising) == false,
        "gone: only an object that says it is not valid (structs and plain values pass)")
    check(K.get(live, "Value") == 5 and K.get(live, "Missing") == nil and K.get(nil, "Value") == nil and K.get(dead, "__full") == nil and K.get(raising, "Value") == nil and K.get(struct, "Y") == 2,
        "get: a property, nil for no object, a gone object or a read that raises")
    check(K.call(live, "Add", 1, 2, 3) == 6 and K.call(live, "Add", 1, nil, 3) == 4 and K.call(live, "Count", nil, nil) == 2 and K.call(live, "Count") == 0,
        "call: the arguments are passed on as given, nils and their number included")
    check(K.call(live, "Boom") == nil and K.call(live, "NoSuchFunction") == nil and K.call(nil, "Add") == nil and K.call(dead, "GetFullName") == nil, "call: nil when the call raises, the function is missing or the object is gone")
    local ok, result = K.try(live, "Add", 2, 2)
    local ok2, why2 = K.try(live, "Boom")
    local ok3, why3 = K.try(nil, "Add")
    local ok4, why4 = K.try(dead, "Add")
    check(ok == true and result == 4 and ok2 == false and has(why2, "boom") and ok3 == false and why3 == "nil object" and ok4 == false and why4 == "object is gone",
        "try: says whether the call worked, with the result or the reason")
    check(K.fullName(live) == "Thing /Game/Map.Map:Thing_1" and K.fullName(dead) == nil and K.fullName(nil) == nil and K.fullName(struct) == nil and K.classToken(live) == "Thing" and K.classToken(dead) == nil,
        "fullName and the class in front of it")
    check(K.isDefaultName("X /Script/G1R.Default__X") == true and K.isDefaultName("X /Game/Map.X_1") == false and K.isDefaultName(nil) == true, "default objects are told by their name")
    check(K.unwrap({ get = function() return live end }) == live and K.unwrap(live) == live and K.unwrap(7) == 7 and K.unwrap(nil) == nil, "unwrap: the value behind :get(), or the value itself")
    check(K.number(5) == 5 and K.number(2.5) == 2.5 and K.number(0 / 0) == nil and K.number(math.huge) == nil and K.number(-math.huge) == nil and K.number("5") == nil and K.number(nil) == nil,
        "number: finite numbers only")
    -- arrays
    local list = T.array({ "a", "b", "c", "d" })
    local seen = {}
    check(K.each(list, function(v, i) seen[#seen + 1] = i .. v end) == 4 and table.concat(seen, " ") == "1a 2b 3c 4d" and K.count(list) == 4, "each: every element with its index; count: the length")
    seen = {}
    check(K.each(list, function(v) seen[#seen + 1] = v return v == "b" end) == 2 and table.concat(seen) == "ab", "each: the function returning true ends the loop")
    check(K.each(nil, print) == nil and K.each(list, nil) == nil and K.each({}, function() end) == nil and K.count(nil) == nil and K.count({}) == nil
        and K.each(T.array({}), function() end) == 0, "something that is no array: nil, no error; an empty array: 0")
    check(K.each(list, function() error("boom") end) == nil and #ue.errors == 0, "a function that raises: nil, the error does not get out")
    done(c)
end

-- ---------------------------------------------------------------------------
section("2. logging")
do
    local c = fresh({ world = false })
    local out = {}
    local L = c.K.logger("TAG", function(text) out[#out + 1] = text end)
    L.log("one")
    check(out[1] == "[TAG] one\n" and L.tag == "TAG", "a line is the tag in brackets, the text and a line break")
    check(L.once("k", "first") == true and L.once("k", "again") == false and L.once("k2", "other") == true and #out == 3 and out[2] == "[TAG] first\n", "once: one line per key")
    L.log(nil)
    L.log(5)
    check(out[4] == "[TAG] nil\n" and out[5] == "[TAG] 5\n", "anything can be logged")
    local L2 = c.K.logger("OTHER")
    L2.log("x")
    check(c.ue.printed[1] == "[OTHER] x\n" and L2.once("k", "y") == true, "without a print function the kit's own is used; each logger has its own keys")
    done(c)
end

-- ---------------------------------------------------------------------------
section("3. searches by path: once per path and run")
do
    local c = fresh({ world = false })
    local K, ue = c.K, c.ue
    ue.objects["/Script/G1R.There"] = ue:object("Class /Script/G1R.There", {})
    local a1, a2, b1, b2 = K.findOnce("/Script/G1R.There"), K.findOnce("/Script/G1R.There"), K.findOnce("/Script/G1R.NotThere"), K.findOnce("/Script/G1R.NotThere")
    ue.objects["/Script/G1R.NotThere"] = ue:object("Class /Script/G1R.NotThere", {})
    check(a1 ~= nil and a1 == a2 and b1 == nil and b2 == nil and K.findOnce("/Script/G1R.NotThere") == nil and #ue.lookups == 2,
        "found or not, a path is searched once (2 searches for 5 questions; what appears later is not found)")
    a1.__valid = false
    check(K.findOnce("/Script/G1R.There") == nil and #ue.lookups == 2, "an object that was found and is gone is not searched again")
    check(K.findOnce(nil) == nil and K.findOnce(5) == nil and #ue.lookups == 2 and K.searched("/Script/G1R.There") == true and K.searched("/Script/G1R.Never") == false, "something that is no path is not searched")
    done(c)
    c = fresh({ world = false, mock = { nilWhenMissing = true } })
    check(c.K.findOnce("/Script/G1R.X") == nil and c.K.findOnce("/Script/G1R.X") == nil and #c.ue.lookups == 1, "a UE4SS that answers nil for not found: the same")
    done(c)
    c = fresh({ world = false, mock = { without = { "StaticFindObject" } } })
    check(c.K.findOnce("/Script/G1R.X") == nil and #c.ue.errors == 0, "a UE4SS without the search function: nil, no error")
    done(c)

    -- classes and default objects by name
    c = fresh({ world = false })
    K, ue = c.K, c.ue
    ue.objects["/Script/Angelscript.Spell"] = ue:object("Class /Script/Angelscript.Spell", {})
    ue.objects["/Script/G1R.Default__Lib"] = ue:object("Lib /Script/G1R.Default__Lib", {})
    check(K.findClass("Spell") == ue.objects["/Script/Angelscript.Spell"] and table.concat(ue.lookups, " ") == "/Script/G1R.Spell /Script/Angelscript.Spell",
        "findClass without a place: the native classes first, then the script classes")
    check(K.findClass("Spell") ~= nil and #ue.lookups == 2, "asked again: no search")
    check(K.findClass("Spell", "Angelscript") ~= nil and K.findClass("Other", "Angelscript") == nil and K.findClass("Other", "Angelscript") == nil and #ue.lookups == 3
        and ue.lookups[3] == "/Script/Angelscript.Other", "with the place given only that one path is searched, once")
    check(K.findDefault("Lib") == ue.objects["/Script/G1R.Default__Lib"] and K.findDefault("Lib", "G1R") ~= nil and #ue.lookups == 4, "findDefault: the default object of a class")
    check(K.findClass("Nowhere") == nil and #ue.lookups == 7 and K.findClass("Nowhere") == nil and #ue.lookups == 7, "a class that is nowhere: three searches, then none")
    check(K.findClass(nil) == nil and K.findDefault(5) == nil and K.findClass(5, "G1R") == nil and #ue.lookups == 7, "something that is no name: nil, nothing is searched")
    done(c)
end

-- ---------------------------------------------------------------------------
section("4. hooks: registered once per path")
do
    local c = fresh({ world = false })
    local K, ue = c.K, c.ue
    ue.functions["/Script/G1R.A:F"] = true
    local calls = {}
    local ok, why = K.hookOnce("/Script/G1R.A:F", function(...) calls[#calls + 1] = "pre" end)
    check(ok == true and why == nil and #ue.hooks["/Script/G1R.A:F"] == 1 and K.hooked("/Script/G1R.A:F") == true, "a hook on a function that exists: registered")
    ok = K.hookOnce("/Script/G1R.A:F", function() calls[#calls + 1] = "second" end)
    ue:fireHook("/Script/G1R.A:F", {})
    check(ok == true and ue.calls.RegisterHook == 1 and table.concat(calls) == "pre", "asked again for the same path: nothing is registered, the first functions stay")
    ok, why = K.hookOnce("/Script/G1R.A:Missing", function() end)
    local ok2, why2 = K.hookOnce("/Script/G1R.A:Missing", function() end)
    check(ok == false and has(why, "no UFunction with the specified name was found") and not has(why, "\n") and ok2 == false and why2 == why and ue.calls.RegisterHook == 2
        and K.hooked("/Script/G1R.A:Missing") == false, "a function that does not exist: false with the first line of the reason; not tried again")
    ue.functions["/Script/G1R.A:G"] = true
    ok = K.hookOnce("/Script/G1R.A:G", function() calls[#calls + 1] = "g-pre" end, function() calls[#calls + 1] = "g-post" end)
    ue:fireHook("/Script/G1R.A:G", {})
    check(ok == true and table.concat(calls, " ") == "pre g-pre g-post" and ue.hooks["/Script/G1R.A:G"][1].post ~= nil, "a second function runs after the hooked one")
    check(K.hookOnce(nil, print) == false and K.hookOnce("/Script/G1R.A:H") == false and K.hookOnce("/Script/G1R.A:H", "x") == false and ue.calls.RegisterHook == 3
        and K.hooked("/Script/G1R.A:H") == false and K.hooked("never") == false, "without a path or a function: refused, nothing is registered or remembered")
    done(c)
    c = fresh({ world = false, mock = { without = { "RegisterHook" } } })
    ok, why = c.K.hookOnce("/Script/G1R.A:F", function() end)
    check(ok == false and why == "this UE4SS build has no RegisterHook", "a UE4SS without RegisterHook: false with the reason")
    done(c)
end

-- ---------------------------------------------------------------------------
section("5. the first live object of a class")
do
    local c = fresh({ world = false })
    local K, ue = c.K, c.ue
    local function finds() return ue.calls.FindFirstOf or 0 end
    check(K.firstOf("GameTimeSubsystem") == nil and K.firstOf("GameTimeSubsystem") == nil and finds() == 1, "none there: nil, and not searched again at once")
    c.ticks(11)
    check(K.firstOf("GameTimeSubsystem") == nil and finds() == 1, "not within 3 seconds")
    c.ticks(1)
    local sub = ue:object("GameTimeSubsystem /Engine/Transient.GameInstance_1:GameTimeSubsystem_1", {})
    ue.firstOf["GameTimeSubsystem"] = sub
    check(K.firstOf("GameTimeSubsystem") == sub and finds() == 2, "after 3 seconds it is searched again, and found")
    for _ = 1, 50 do K.firstOf("GameTimeSubsystem") end
    check(finds() == 2, "a found object is kept: no search for 50 more questions")
    c.ticks(12)
    sub.__full = "Other /Engine/Transient.Other_5"
    ue.firstOf["GameTimeSubsystem"] = ue:object("GameTimeSubsystem /Engine/Transient.GameInstance_1:GameTimeSubsystem_2", {})
    check(K.firstOf("GameTimeSubsystem") == ue.firstOf["GameTimeSubsystem"] and finds() == 3, "a kept wrapper that now names another object is dropped and the object searched again")
    ue.firstOf["GameTimeSubsystem"].__valid = false
    ue.firstOf["GameTimeSubsystem"] = nil
    check(K.firstOf("GameTimeSubsystem") == nil and finds() == 3, "an object that is gone right after a search: nil (the next search waits its 3 seconds)")
    c.ticks(12)
    check(K.firstOf("GameTimeSubsystem") == nil and finds() == 4, "then it is searched")
    ue.firstOf["Lib"] = ue:object("Lib /Script/G1R.Default__Lib", {})
    check(K.firstOf("Lib") == nil and K.firstOf(nil) == nil and K.firstOf(5) == nil, "a default object is no live object; something that is no class name is not searched")
    -- a map change: asked again at once
    local other = ue:object("Manager /Game/Map.Map:Manager_1", {})
    ue.firstOf["Manager"] = other
    check(K.firstOf("Manager") == other, "(another class, found)")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    local newer = ue:object("Manager /Game/Map2.Map2:Manager_1", {})
    ue.firstOf["Manager"] = newer
    ue.firstOf["GameTimeSubsystem"] = sub
    sub.__full = "GameTimeSubsystem /Engine/Transient.GameInstance_1:GameTimeSubsystem_3"
    check(K.firstOf("Manager") == newer and K.firstOf("GameTimeSubsystem") == sub, "after a map change every class is searched afresh, without waiting")
    done(c)
    c = fresh({ world = false, mock = { without = { "FindFirstOf" } } })
    check(c.K.firstOf("X") == nil and #c.ue.errors == 0, "a UE4SS without FindFirstOf: nil, no error")
    done(c)
end

-- ---------------------------------------------------------------------------
section("6. world changes")
do
    local c = fresh()
    local K, ue = c.K, c.ue
    local phases = {}
    K.onWorldChange(function(phase) phases[#phases + 1] = phase end)
    K.onWorldChange(function() error("a listener fails") end)
    K.onWorldChange(function(phase) phases[#phases + 1] = phase .. "2" end)
    K.onWorldChange("not a function")
    check(K.loading() == false and #ue.loadMapPre == 1 and #ue.loadMapPost == 1, "one hook before and one after a map load; not loading at the start")
    check(K.controller() == c.world.controller, "(the hero is found)")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    check(K.loading() == true and table.concat(phases, " ") == "before before2" and c.t.hero.controller == nil and #ue.errors == 0,
        "before a load: loading, the listeners are told (one that fails does not stop the others), what was kept of the hero is dropped")
    c.ticks(40)
    check(K.loading() == true, "still loading after 10 seconds")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    check(K.loading() == false and table.concat(phases, " ") == "before before2 after after2", "after the load: not loading, the listeners are told again")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    c.ticks(79)
    local at19 = K.loading()
    c.ticks(1)
    check(at19 == true and K.loading() == false, "a load that never reports its end counts as over after 20 seconds")
    done(c)
    c = fresh({ mock = { without = { "RegisterLoadMapPostHook" } } })
    phases = {}
    c.K.onWorldChange(function(phase) phases[#phases + 1] = phase end)
    c.ue:fireLoadMapPre("engine", "world", "url", nil, "")
    check(c.K.loading() == false and phases[1] == "before", "a UE4SS without the hook after a load: never loading (nothing would end it), the listeners are still told")
    done(c)
    c = fresh({ mock = { without = { "RegisterLoadMapPostHook", "RegisterLoadMapPreHook" } } })
    check(c.K.loading() == false and c.K.controller() ~= nil, "a UE4SS without both hooks: the kit works")
    done(c)
end

-- ---------------------------------------------------------------------------
section("7. the hero: controller, player state, pawn, world")
do
    local c = fresh()
    local K, ue, w = c.K, c.ue, c.world
    check(K.controller() == w.controller and c.allOf() == 1, "the controller: found with one search, the class default object is passed over")
    for _ = 1, 20 do K.controller() end
    check(c.allOf() == 1, "kept: no search for 20 more questions")
    local state, name = K.playerState()
    check(state == w.hero.state and name == w.hero.state:GetFullName() and K.pawn() == w.pawn and K.world() == w.world, "player state with its full name, pawn, world")
    local other = ue:object("GothicCharacter_C /Game/Maps/World.World:PersistentLevel.GothicCharacter_C_8", {})
    w.controller.Pawn = other
    check(K.pawn() == w.pawn, "the pawn the function gives comes first")
    w.controller.K2_GetPawn = function() return nil end
    check(K.pawn() == other, "the pawn from the property when the function gives none")
    w.controller.Pawn = nil
    w.controller.GetWorld = function() return ue:invalid() end
    check(K.pawn() == nil and K.world() == nil, "no pawn, no world: nil")
    -- gone, and found again after the wait
    w.controller.__valid = false
    local second = T.controllerOf(ue, 6, w.hero.state)
    ue.allOf["GothicPlayerControllerBaseBP_C"] = { second }
    check(K.controller() == nil and c.allOf() == 1, "a controller that is gone: nil; the next search waits until 3 seconds after the last")
    c.ticks(12)
    check(K.controller() == second and c.allOf() == 2, "then it is searched and found")
    second.__full = "Actor /Game/Map.Map:Actor_3"
    c.ticks(12)
    local third = T.controllerOf(ue, 7, w.hero.state)
    ue.allOf["GothicPlayerControllerBaseBP_C"] = { third }
    check(K.controller() == third, "a kept wrapper that now names another object is dropped")
    done(c)

    -- only the class default object
    c = fresh({ world = function(ue)
        local world = T.newWorld(ue)
        ue.allOf["GothicPlayerControllerBaseBP_C"] = { world.controllerDefault }
        return world
    end })
    check(c.K.controller() == nil and c.t.hero.controller == nil, "the class default object alone is no controller")
    done(c)

    -- the general class, the order of the classes
    c = fresh({ world = function(ue) return T.newWorld(ue, { noController = true }) end })
    K, ue, w = c.K, c.ue, c.world
    check(K.controller() == nil and c.allOf() == 2 and K.playerState() == nil and K.pawn() == nil and K.world() == nil and K.attributeSet("Health") == nil and c.allOf() == 2,
        "no controller: nil for everything that hangs on it; both class names were searched once")
    local quiet = true
    for _ = 1, 24 do
        c.ticks(1)
        if K.attributeSet("Health") ~= nil or K.attribute("Health", "Health") ~= nil then quiet = false end
    end
    check(quiet and c.allOf() == 6 and #ue.errors == 0, "asked for 6 seconds without a hero: nil every time, only the controller is searched (every 3 seconds)")
    ue.allOf["PlayerController"] = { w.controller }
    c.ticks(12)
    check(K.controller() == w.controller and c.allOf() == 8, "a controller of the general class is taken when the game's own class has none")
    done(c)

    -- several controllers
    c = fresh({ world = function(ue)
        local world = T.newWorld(ue)
        world.spare = T.controllerOf(ue, 9, nil)
        world.spare2 = T.controllerOf(ue, 10, ue:invalid())
        ue.allOf["GothicPlayerControllerBaseBP_C"] = { world.controllerDefault, world.spare2, world.controller, world.spare }
        return world
    end })
    check(c.K.controller() == c.world.controller, "of several controllers the one with a player state is taken, wherever it stands in the list")
    done(c)
    c = fresh({ world = function(ue)
        local world = T.newWorld(ue)
        world.spare = T.controllerOf(ue, 9, nil)
        world.gone = T.controllerOf(ue, 11, nil)
        world.gone.__valid = false
        ue.allOf["GothicPlayerControllerBaseBP_C"] = { world.controllerDefault, world.spare, world.gone }
        ue.allOf["PlayerController"] = { world.controller }
        return world
    end })
    K, ue, w = c.K, c.ue, c.world
    check(K.controller() == w.spare and K.playerState() == nil, "only controllers without a player state: a live one is taken (a menu); it has no player state")
    c.ticks(59)
    check(K.controller() == w.spare and K.playerState() == nil and c.allOf() == 1, "it is kept for a while")
    ue.allOf["GothicPlayerControllerBaseBP_C"] = { w.controllerDefault, w.spare, w.controller }
    c.ticks(1)
    check(K.playerState() == nil and K.playerState() == w.hero.state, "after 15 seconds without a player state the controller is searched again: the one with a hero is found")
    done(c)
end

-- ---------------------------------------------------------------------------
section("8. the hero's attributes")
do
    local c = fresh()
    local K, ue, w = c.K, c.ue, c.world
    local set, via, at = K.attributeSet("LevelProgression")
    check(set == w.hero.progression and via == "player state" and at == os.clock() and c.allOf() == 1 and w.reads[21] == 1, "found in the player state's own list: no search among all objects")
    check(K.attributeSet("Health") == w.hero.health and K.attributeSet("Mana") == w.hero.mana and K.attributeSet("Nothing") == nil and K.attributeSet("Heal") == nil and K.attributeSet("ana") == nil,
        "each set by its class name AttributeSet_<part>: the whole name counts, not a piece of it")
    for _ = 1, 20 do K.attributeSet("LevelProgression") end
    check(w.reads[21] == 6, "kept: asked again 20 times, the player state is not asked again")
    local current, base = K.readAttribute(set, "Experience")
    check(current == 6702 and base == 6702 and K.readAttribute(set, "Missing") == nil and K.readAttribute(nil, "Experience") == nil, "readAttribute: current and base value; nil when there is none")
    set.Experience.BaseValue = 6000.0
    current, base = K.readAttribute(set, "Experience")
    check(current == 6702 and base == 6000, "the two values are read separately")
    set.Experience.CurrentValue = 0 / 0
    check(K.readAttribute(set, "Experience") == nil, "a current value that is not a number: nil")
    set.Experience.CurrentValue, set.Experience.BaseValue = 6702.0, "x"
    current, base = K.readAttribute(set, "Experience")
    check(current == 6702 and base == nil, "a base value that is not a number: the current value alone")
    local ok, why = K.writeAttribute(set, "Experience", 7000)
    check(ok == true and why == nil and set.Experience.BaseValue == 7000 and set.Experience.CurrentValue == 7000, "writeAttribute: both values are written")
    ok, why = K.writeAttribute(set, "Experience", 0 / 0)
    local ok2, why2 = K.writeAttribute(nil, "Experience", 5)
    local ok3, why3 = K.writeAttribute(set, "Missing", 5)
    check(ok == false and why == "nothing to write to" and ok2 == false and why2 == "nothing to write to" and ok3 == false and why3 == "the write raised an error" and set.Experience.CurrentValue == 7000,
        "not a number, no set, no such attribute: false with the reason, nothing is written")
    local c1, b1, s1 = K.attribute("Health", "Health")
    check(c1 == 80 and b1 == 80 and s1 == w.hero.health and K.attribute("Health", "Missing") == nil and K.attribute("Nothing", "Health") == nil, "attribute: value, base value and the set in one call")

    -- the wrapper outlives its object
    local replacement = ue:object("AttributeSet_Health /Game/Maps/World.World:PersistentLevel.GothicPlayerState_21.AttributeSet_Health_99", { Health = { BaseValue = 50.0, CurrentValue = 50.0 } })
    w.hero.health.__full = "Something /Game/Maps/World.World:PersistentLevel.Something_1"
    w.hero.component.SpawnedAttributes.items[1] = replacement
    check(K.attributeSet("Health") == replacement, "a kept set whose wrapper now names another object is dropped and looked up again")
    replacement.__valid = false
    local third = ue:object("AttributeSet_Health /Game/Maps/World.World:PersistentLevel.GothicPlayerState_21.AttributeSet_Health_100", { Health = { BaseValue = 60.0, CurrentValue = 60.0 } })
    w.hero.component.SpawnedAttributes.items[1] = third
    check(K.attributeSet("Health") == third, "so is one that is gone")
    -- replaced under the same state while the old object lives on
    local fourth = ue:object("AttributeSet_Health /Game/Maps/World.World:PersistentLevel.GothicPlayerState_21.AttributeSet_Health_101", { Health = { BaseValue = 70.0, CurrentValue = 70.0 } })
    w.hero.component.SpawnedAttributes.items[1] = fourth
    c.ticks(19)
    check(K.attributeSet("Health") == third, "another set in the state's list is not noticed before the next check")
    c.ticks(1)
    local s4, v4, at4 = K.attributeSet("Health")
    check(s4 == fourth and v4 == "player state" and at4 == os.clock(), "it is 5 seconds after the set was found")
    local reads = w.reads[21]
    for _ = 1, 19 do
        c.ticks(1)
        K.attributeSet("Health")
    end
    local readsBefore = w.reads[21]
    c.ticks(1)
    K.attributeSet("Health")
    check(readsBefore == reads and w.reads[21] == reads + 1, "after a check the next one is 5 seconds later: the player state is asked once in that time")
    w.hero.component.SpawnedAttributes = nil
    c.ticks(40)
    check(K.attributeSet("Health") == fourth, "a list that cannot be read at a check: the kept set stays")
    -- another player state
    local other = T.hero(ue, w, 40, { Health = 33.0 })
    w.controller.PlayerState = other.state
    check(K.attributeSet("Health") == other.health and K.attribute("Health", "Health") == 33, "another player state: its sets, at once")
    check(c.allOf() == 1, "all of this without a search among all objects")
    done(c)

    -- a name that cannot be read: such a set is never taken for the kept one
    c = fresh()
    K, ue, w = c.K, c.ue, c.world
    local nameReads, nameLimit = 0, 1
    local real = w.hero.health.__full
    w.hero.health.GetFullName = function()
        nameReads = nameReads + 1
        if nameReads > nameLimit then error("the name cannot be read") end
        return real
    end
    check(K.attributeSet("Health") == w.hero.health and nameReads == 1, "a set is kept under the name it was found by: the name is read once for that")
    check(K.attributeSet("Health") == nil and K.attribute("Health", "Health") == nil and #ue.errors == 0,
        "a kept set whose name cannot be read any more is not used (it could be another object by now), and it is not found again without a name")
    nameLimit = math.huge
    c.ticks(4)
    check(K.attributeSet("Health") == w.hero.health, "when the name can be read again, the set is found again")
    -- the same at the check against the state's list: the other set's name is the one read in the list
    local swapped = ue:object("AttributeSet_Health /Game/Maps/World.World:PersistentLevel.GothicPlayerState_21.AttributeSet_Health_55", { Health = { BaseValue = 44.0, CurrentValue = 44.0 } })
    local swappedReads = 0
    swapped.GetFullName = function(self)
        swappedReads = swappedReads + 1
        if swappedReads > 1 then error("the name cannot be read") end
        return self.__full
    end
    w.hero.component.SpawnedAttributes.items[1] = swapped
    c.ticks(20)
    check(K.attributeSet("Health") == swapped and swappedReads == 1, "a set that replaces the kept one at a check is kept under the name read in the list")
    check(K.attributeSet("Health") == nil and #ue.errors == 0, "and is dropped when that name cannot be read at the next question")
    done(c)

    -- the state's list is not usable: tries, then the search with growing pauses
    c = fresh({ world = function(ue)
        local world = T.newWorld(ue)
        world.hero.component.SpawnedAttributes = nil
        return world
    end })
    K, ue, w = c.K, c.ue, c.world
    local function scans() return c.allOf() - 1 end
    check(K.attributeSet("Mana") == nil and w.reads[21] == 1 and scans() == 0, "a list that cannot be read: nil, no search yet")
    c.ticks(3)
    check(K.attributeSet("Mana") == nil and w.reads[21] == 1, "the list is not asked again within a second")
    c.ticks(1)
    check(K.attributeSet("Mana") == nil and w.reads[21] == 2 and scans() == 0, "after a second it is")
    c.ticks(4)
    check(K.attributeSet("Mana") == nil and w.reads[21] == 3 and scans() == 1, "the third time is the last; then the search among all objects runs")
    local times = {}
    local start = os.clock()
    for i = 1, 4 * 200 do
        c.ticks(1)
        local before = scans()
        K.attributeSet("Mana")
        if scans() > before then times[#times + 1] = os.clock() - start end
    end
    check(table.concat(times, " ") == "5.0 15.0 35.0 75.0 135.0 195.0" and w.reads[21] == 3, "the search repeats after 5, 10, 20, 40 and then every 60 seconds: " .. table.concat(times, " "))
    -- what the search takes
    local npc = ue:object("AttributeSet_Mana /Game/Maps/World.World:PersistentLevel.GothicNPCState_8.AttributeSet_Mana_9", {})
    local default = ue:object("AttributeSet_Mana /Script/G1R.Default__AttributeSet_Mana", {})
    local stranger = T.hero(ue, w, 60)
    local gone = ue:object("AttributeSet_Mana /Game/Maps/World.World:PersistentLevel.GothicPlayerState_21.AttributeSet_Mana_77", {})
    gone.__valid = false
    ue.allOf["AttributeSet_Mana"] = { default, gone, w.hero.mana, npc, stranger.mana }
    c.ticks(4 * 60)
    local s, v = K.attributeSet("Mana")
    check(s == w.hero.mana and v == "scan", "the search takes the set inside the controller's player state: not another state's, not a creature's, not the default object, not one that is gone")
    local n = scans()
    for _ = 1, 30 do
        c.ticks(4)
        K.attributeSet("Mana")
    end
    check(scans() == n, "a set found by the search is kept: no more searches")
    done(c)

    for _, case in ipairs({
        { "one set in some player state under a name that does not tell its state: taken", function(ue, world)
            world.hero.mana.__full = "AttributeSet_Mana /Game/Maps/World.World:PersistentLevel.BP_PlayerState_C_1.AttributeSet_Mana_0"
            ue.allOf["AttributeSet_Mana"] = { world.hero.mana, ue:object("AttributeSet_Mana /Game/Maps/World.World:PersistentLevel.GothicNPCState_8.AttributeSet_Mana_9", {}) }
            return world.hero.mana
        end },
        { "two sets of other player states: none is taken", function(ue, world)
            ue.allOf["AttributeSet_Mana"] = { T.hero(ue, world, 60).mana, T.hero(ue, world, 70).mana }
            return nil
        end },
        { "a state whose name is the start of another's (21 and 210): only its own set", function(ue, world)
            local long = T.hero(ue, world, 210)
            ue.allOf["AttributeSet_Mana"] = { world.hero.mana, long.mana }
            return world.hero.mana
        end },
        { "no list from the search: nil", function(ue) ue.allOf["AttributeSet_Mana"] = nil return nil end },
    }) do
        local expected
        c = fresh({ world = function(ue)
            local world = T.newWorld(ue)
            world.hero.component.SpawnedAttributes = nil
            expected = case[2](ue, world)
            return world
        end })
        c.K.attributeSet("Mana")
        c.ticks(4)
        c.K.attributeSet("Mana")
        c.ticks(4)
        check(c.K.attributeSet("Mana") == expected and #c.ue.errors == 0, "the search: " .. case[1])
        done(c)
    end

    -- writes that do not work
    c = fresh()
    K, w = c.K, c.world
    local values = { BaseValue = 80.0, CurrentValue = 80.0 }
    w.hero.health.Health = setmetatable({}, { __index = values, __newindex = function() error("read only") end })
    ok, why = K.writeAttribute(w.hero.health, "Health", 90)
    check(ok == false and why == "the write raised an error", "a write that raises: false with the reason")
    w.hero.health.Health = setmetatable({}, { __index = values, __newindex = function(_, k, v) if k == "BaseValue" then values.BaseValue = v end end })
    ok, why = K.writeAttribute(w.hero.health, "Health", 90)
    check(ok == false and why == "the value did not stay", "only the base value stays: false")
    values.BaseValue = 80.0
    w.hero.health.Health = setmetatable({}, { __index = values, __newindex = function(_, k, v) if k == "CurrentValue" then values.CurrentValue = v end end })
    ok, why = K.writeAttribute(w.hero.health, "Health", 90)
    check(ok == false and why == "the value did not stay", "only the current value stays: false")
    w.hero.health.Health = setmetatable({}, { __index = values, __newindex = function(_, k, v) values[k] = string.unpack("f", string.pack("f", v)) end })
    check(K.writeAttribute(w.hero.health, "Health", 16777217.3) == true and K.writeAttribute(w.hero.health, "Health", 0.1) == true and K.writeAttribute(w.hero.health, "Health", -3.3) == true,
        "values that come back rounded to single precision count as written")
    w.hero.health.Health = setmetatable({}, { __index = values, __newindex = function(_, k, v) values[k] = v + 0.01 end })
    check(K.writeAttribute(w.hero.health, "Health", 50) == false, "a value that comes back a hundredth off does not")
    w.hero.health.Health = setmetatable({}, { __index = function(_, k) if k == "BaseValue" then return "x" end return values[k] end, __newindex = function(_, k, v) values[k] = v end })
    local okWrite, result = pcall(K.writeAttribute, w.hero.health, "Health", 50)
    check(okWrite and result == false, "a base value that cannot be read back: false, and no error")
    done(c)
    check(K.attributeSetOf(w.hero.state, "Health") == w.hero.health and K.attributeSetOf(w.hero.state, "Nothing") == nil
        and K.attributeSetOf(nil, "Health") == nil and K.attributeSetOf(ue:object("None", { __valid = false }), "Health") == nil,
        "attributeSetOf: the set of another character's state, from that state's own list (nil without a valid state)")
end

-- ---------------------------------------------------------------------------
section("9. pause and the game's clock")
do
    local c = fresh({ diag = true })
    local K, ue, w = c.K, c.ue, c.world
    check(K.paused() == false and #ue.lookups == 1, "no way to ask the engine: not paused (one search)")
    done(c)
    c = fresh({ diag = true })
    K, ue, w = c.K, c.ue, c.world
    local paused = false
    local asked
    ue.objects["/Script/Engine.Default__GameplayStatics"] = ue:object("GameplayStatics /Script/Engine.Default__GameplayStatics", {
        IsGamePaused = function(_, world) asked = world return paused end })
    check(K.paused() == false and asked == w.world, "the engine is asked with the hero's world: not paused")
    paused = true
    check(K.paused() == true, "paused")
    paused = "yes"
    check(K.paused() == false, "anything but true is not paused")
    check(K.gameSeconds() == nil, "no game time subsystem: no clock")
    local sub = ue:object("GameTimeSubsystem /Engine/Transient.GameInstance_1:GameTimeSubsystem_1", { CurrentGameTime = { TotalSeconds = 345600.5 } })
    ue.firstOf["GameTimeSubsystem"] = sub
    c.ticks(12)
    check(K.gameSeconds() == 345600.5 and c.fake.value("kit.game_time_source") == "property", "the clock is read from the subsystem's property; noted how")
    sub.CurrentGameTime = { get = function() return { TotalSeconds = 100.0 } end }
    check(K.gameSeconds() == 100 and c.fake.value("kit.game_time_source") == "property (wrapped)", "or from the value behind :get()")
    sub.CurrentGameTime = nil
    sub.GetCurrentGameTime = function() return { TotalSeconds = 200.0 } end
    check(K.gameSeconds() == 200 and c.fake.value("kit.game_time_source") == "function", "or from the subsystem's function")
    K.gameSeconds()
    check(c.fake.count["kit.game_time_source"] == 3, "the way is noted when it changes, not at every reading")
    sub.GetCurrentGameTime = function() return { TotalSeconds = 0 / 0 } end
    check(K.gameSeconds() == nil and (ue.calls.FindFirstOf or 0) == 2, "a value that is not a number: nil; the subsystem itself is kept")
    done(c)
    c = fresh({ world = false })
    check(c.K.paused() == false and #c.ue.lookups == 0, "without a hero nothing is asked: not paused")
    done(c)
end

-- ---------------------------------------------------------------------------
section("10. keys")
do
    local c = fresh({ world = false })
    local K, ue = c.K, c.ue
    local function combo(text)
        local usual, code, modifiers = K.keyCombo(text)
        if usual == nil then return "nil:" .. tostring(code) end
        return usual .. "/" .. tostring(code) .. "/" .. table.concat(modifiers, ",")
    end
    check(combo("Y") == "Y/89/" and combo("ctrl+y") == "CTRL+Y/89/17" and combo(" Alt + Shift+ctrl +f5 ") == "CTRL+SHIFT+ALT+F5/116/17,16,18" and combo("") == "/nil/" and combo("   ") == "/nil/",
        "a key as text: its usual spelling, the key's code, the codes of the modifiers; \"\" is no key")
    check(combo("strg+1") == "CTRL+ONE/49/17" and combo("control+insert") == "CTRL+INS/45/17" and combo("num5") == "NUM_FIVE/101/" and combo("pgdn") == "PAGE_DOWN/34/"
        and combo("mouse4") == "XBUTTON_ONE/5/" and combo("Enter") == "RETURN/13/" and combo("up") == "UP_ARROW/38/" and combo("delete") == "DEL/46/" and combo("OEM_PLUS") == "OEM_PLUS/187/",
        "other spellings people use: digits, STRG, INSERT, NUM5, PGDN, MOUSE4, ENTER, UP, DELETE")
    check(combo("ctrl+ctrl+y") == "CTRL+Y/89/17", "a modifier named twice counts once")
    check(combo("nokey") == "nil:unknown key NOKEY" and combo("ctrl") == "nil:only modifier keys" and combo("a+b") == "nil:more than one key (A, B)" and combo("ctrl++y") == "nil:unknown key (nothing)"
        and combo("y+") == "nil:unknown key (nothing)" and combo(5) == "nil:a key is written as text" and combo("LEFT_MOUSE_BUTTON") == "nil:unknown key LEFT_MOUSE_BUTTON" and combo("ESCAPE") == "nil:unknown key ESCAPE",
        "what names no key gives nil and the reason (the left mouse button and Escape cannot be bound)")
    local names = K.keyNames()
    local sorted = true
    for i = 2, #names do if names[i - 1] >= names[i] then sorted = false end end
    local allGood = true
    for _, name in ipairs(names) do
        local usual, code = K.keyCombo(name)
        if usual ~= name or math.type(code) ~= "integer" or code < 1 or code > 255 then allGood = false end
    end
    check(#names == 97 and sorted and allGood, "keyNames: the " .. #names .. " key names, sorted; each is its own usual spelling with a code from 1 to 255")
    -- the codes are Windows virtual-key codes (what RegisterKeyBind takes); written out here a second time
    local expected = { MIDDLE_MOUSE_BUTTON = 0x04, XBUTTON_ONE = 0x05, XBUTTON_TWO = 0x06, BACKSPACE = 0x08, TAB = 0x09, RETURN = 0x0D, PAUSE = 0x13, CAPS_LOCK = 0x14, SPACE = 0x20,
        PAGE_UP = 0x21, PAGE_DOWN = 0x22, END = 0x23, HOME = 0x24, LEFT_ARROW = 0x25, UP_ARROW = 0x26, RIGHT_ARROW = 0x27, DOWN_ARROW = 0x28, INS = 0x2D, DEL = 0x2E,
        MULTIPLY = 0x6A, ADD = 0x6B, SUBTRACT = 0x6D, DECIMAL = 0x6E, DIVIDE = 0x6F, NUM_LOCK = 0x90, SCROLL_LOCK = 0x91, OEM_ONE = 0xBA, OEM_PLUS = 0xBB, OEM_COMMA = 0xBC,
        OEM_MINUS = 0xBD, OEM_PERIOD = 0xBE, OEM_TWO = 0xBF, OEM_THREE = 0xC0, OEM_FOUR = 0xDB, OEM_FIVE = 0xDC, OEM_SIX = 0xDD, OEM_SEVEN = 0xDE, OEM_EIGHT = 0xDF, OEM_102 = 0xE2 }
    for i, word in ipairs({ "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE" }) do
        expected[word] = 0x30 + i - 1
        expected["NUM_" .. word] = 0x60 + i - 1
    end
    for byte = string.byte("A"), string.byte("Z") do expected[string.char(byte)] = byte end
    for i = 1, 12 do expected["F" .. i] = 0x6F + i end
    local wrong, n = {}, 0
    for name, code in pairs(expected) do
        n = n + 1
        if select(2, K.keyCombo(name)) ~= code then wrong[#wrong + 1] = name end
    end
    table.sort(wrong)
    check(n == 97 and #wrong == 0, "every key has its Windows virtual-key code (" .. table.concat(wrong, ", ") .. ")")
    local _, _, mods = K.keyCombo("ctrl+shift+alt+a")
    check(mods[1] == 0x11 and mods[2] == 0x10 and mods[3] == 0x12, "the modifiers too: CTRL 0x11, SHIFT 0x10, ALT 0x12")

    -- binding
    local runs = {}
    local ok, usual = K.bindKey("wait.skip", "ctrl+y", function() runs[#runs + 1] = "skip" end)
    check(ok == true and usual == "CTRL+Y" and K.boundKey("wait.skip") == "CTRL+Y" and #ue.keys == 1 and ue.keys[1].key == 89 and ue.keys[1].modifiers[1] == 17 and #ue.keys[1].modifiers == 1,
        "bindKey: registered with UE4SS as key code and modifier codes")
    check(#ue.loops == 1 and ue.loops[1].ms == 50 and math.type(ue.loops[1].ms) == "integer", "the first key starts one loop on the game thread, every 50 ms")
    ue:fireKey(89)
    check(#runs == 0, "the key's own function (UE4SS's thread) does not run the action")
    ue:tick()
    check(#runs == 1, "the next look of the loop does")
    ue:tick()
    check(#runs == 1, "once per press")
    ue:fireKey(89)
    ue:tick()
    check(#runs == 1, "a second press within 0.3 seconds is dropped (a held key, a double press)")
    ue:advance(0.25)
    ue:fireKey(89)
    ue:tick()
    check(#runs == 1, "still within 0.3 seconds")
    ue:advance(0.0625)
    ue:fireKey(89)
    ue:tick()
    check(#runs == 2, "after 0.3 seconds a press counts again")
    ue:advance(1)
    ue:fireKey(89)
    ue:fireKey(89)
    ue:tick()
    ue:tick()
    check(#runs == 3, "two presses between two looks are one")
    -- moved to another key
    ok, usual = K.bindKey("wait.skip", "F7")
    check(ok == true and usual == "F7" and K.boundKey("wait.skip") == "F7" and #ue.keys == 2 and ue.keys[2].key == 118 and ue.keys[2].modifiers == nil and #ue.loops == 1,
        "the binding is moved to another key: that key is registered (without modifiers), no second loop")
    ue:advance(1)
    ue:fireKey(89)
    ue:tick()
    check(#runs == 3, "the old key does nothing any more")
    ue:fireKey(118)
    ue:tick()
    check(#runs == 4, "the new one runs the action")
    ok, usual = K.bindKey("wait.skip", "CTRL+Y")
    check(ok == true and #ue.keys == 2, "moved back: UE4SS is not asked again for a key it already has")
    ue:advance(1)
    ue:fireKey(89)
    ue:tick()
    check(#runs == 5, "and the key works again")
    -- two bindings on one key, in the order of their names
    K.bindKey("b.second", "CTRL+Y", function() runs[#runs + 1] = "b" end)
    K.bindKey("a.first", "CTRL+Y", function() runs[#runs + 1] = "a" end)
    ue:advance(1)
    ue:fireKey(89)
    ue:tick()
    check(table.concat(runs, " ", 6) == "a b skip" and #ue.keys == 2, "three bindings on one key: each runs, in the order of their names; the key is registered once")
    -- no key
    ok, usual = K.bindKey("wait.skip", "")
    check(ok == true and usual == "" and K.boundKey("wait.skip") == "", "\"\": the binding has no key")
    ok = K.bindKey("b.second", nil)
    local okSpaces, spaces = K.bindKey("b.second", "   ")
    check(okSpaces == true and spaces == "" and #ue.keys == 2, "a text of spaces is no key as well")
    ue:advance(1)
    ue:fireKey(89)
    ue:tick()
    check(ok == true and table.concat(runs, " ", 9) == "a", "nil too; only the binding that still has the key runs")
    -- what does not work
    local ok1, why1 = K.bindKey("wait.skip", "nokey")
    local ok2, why2 = K.bindKey("new", "F8")
    local ok3, why3 = K.bindKey(nil, "F8", print)
    check(ok1 == false and why1 == "unknown key NOKEY" and K.boundKey("wait.skip") == "" and ok2 == false and why2 == "bindKey needs an action" and ok3 == false and why3 == "bindKey needs a name"
        and K.boundKey("new") == "" and K.boundKey("never") == "", "an unknown key (the binding then has none), a new binding without an action, no name: false with the reason")
    -- an action that fails
    K.bindKey("bad", "F9", function() error("the action fails\nsecond line") end)
    ue:fireKey(120)
    ue:tick()
    ue:advance(1)
    ue:fireKey(120)
    ue:tick()
    check(c.printed("[G1R_MegaMod] the action of key F9 (bad) failed:") == 1 and has(table.concat(ue.printed), "the action fails\n") and not has(table.concat(ue.printed), "second line") and #ue.errors == 0,
        "an action that raises: said once in the log with the first line of the error; nothing reaches UE4SS")
    -- a cooldown of its own, a new action
    K.bindKey("fast", "F10", function() runs[#runs + 1] = "fast" end, 0)
    local n = #runs
    ue:fireKey(121)
    ue:tick()
    ue:fireKey(121)
    ue:tick()
    check(#runs == n + 2, "a cooldown of 0: every press counts")
    K.bindKey("fast", "F10", function() runs[#runs + 1] = "faster" end)
    ue:fireKey(121)
    ue:tick()
    check(runs[#runs] == "faster", "bindKey with a new action replaces the old one")
    -- a press during a map load is dropped
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    n = #runs
    ue:fireKey(121)
    ue:tick()
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    ue:tick()
    check(#runs == n, "a press during a map load is dropped, not kept for later")
    ue:fireKey(121)
    ue:tick()
    check(#runs == n + 1, "after the load the key works")
    done(c)

    -- a UE4SS that refuses a key
    c = fresh({ world = false })
    K, ue = c.K, c.ue
    local real = rawget(_G, "RegisterKeyBind")
    local asked = 0
    rawset(_G, "RegisterKeyBind", function(key, ...)
        asked = asked + 1
        if key == 112 then error("the key cannot be registered\nmore", 0) end
        return real(key, ...)
    end)
    ok, usual = K.bindKey("x", "F1", function() end)
    ok2, why2 = K.bindKey("x", "F1")
    ok3, why3 = K.bindKey("y", "F2", function() end)
    check(ok == false and usual == "the key could not be registered (the key cannot be registered)" and ok2 == false and why2 == "the key could not be registered earlier in this run"
        and asked == 2 and ok3 == true and K.boundKey("x") == "", "a key UE4SS refuses: false with the reason; that key is not tried again, others still work")
    done(c)
    c = fresh({ world = false })
    rawset(_G, "LoopInGameThreadWithDelay", function() error("no timers today", 0) end)
    ok, usual = c.K.bindKey("x", "F1", function() end)
    ok2, why2 = c.K.bindKey("y", "F2", function() end)
    check(ok == false and usual == "no timer for the keys" and ok2 == false and why2 == "no timer for the keys" and c.K.boundKey("x") == "" and c.printed("no timer for the keys: key bindings do nothing in this run") == 1,
        "the loop for the keys cannot be started: false with the reason, said once in the log")
    done(c)
    c = fresh({ world = false, mock = { without = { "RegisterKeyBind" } } })
    ok, usual = c.K.bindKey("x", "F1", function() end)
    check(ok == false and usual == "this UE4SS build has no key bindings" and #c.ue.loops == 0, "a UE4SS without key bindings: false with the reason, no loop")
    done(c)
    c = fresh({ world = false, mock = { without = { "LoopInGameThreadWithDelay" } } })
    ok, usual = c.K.bindKey("x", "F1", function() end)
    check(ok == false and usual == "this UE4SS build has no key bindings" and #c.ue.keys == 0, "a UE4SS without the game-thread loop: no key is registered (its action could never run)")
    done(c)
end

-- ---------------------------------------------------------------------------
section("10b. what the keys do (the list of keys)")
do
    local c = fresh({ world = false })
    local K = c.K
    K.bindKey("wait.1", "Y", function() end)
    K.bindKey("mount:fix", "", function() end)
    K.bindKey("a.first", "ctrl+f5", function() end)
    check(K.describeKey("wait.1", "wait 30 minutes") == true and K.describeKey("nothing", "x") == false and K.describeKey("wait.1", 5) == false and K.describeKey(nil, "x") == false,
        "describeKey: a text for a binding there is; false for one that is not there, or a label that is no text")
    local minutes = 30
    check(K.describeKey("a.first", function() return "every " .. minutes end) == true, "or a function")
    local list = K.keyList()
    check(#list == 2 and list[1].id == "a.first" and list[1].key == "CTRL+F5" and list[1].label == "every 30" and list[2].id == "wait.1" and list[2].key == "Y"
        and list[2].label == "wait 30 minutes", "keyList: the bindings that have a key, in the order of their names, each with its key and what it does")
    minutes = 60
    check(K.keyList()[1].label == "every 60", "a function is asked when the list is made")
    K.describeKey("a.first", function() error("no") end)
    K.describeKey("wait.1", function() return 7 end)
    list = K.keyList()
    check(list[1].label == "" and list[2].label == "" and #c.ue.errors == 0, "a function that fails or gives no text: no label, nothing raised")
    K.bindKey("mount:fix", "F4")
    list = K.keyList()
    check(#list == 3 and list[2].id == "mount:fix" and list[2].key == "F4" and list[2].label == "", "a binding that gets its key later is in the list, without a label until it is described")
    K.bindKey("wait.1", "")
    list = K.keyList()
    check(#list == 2 and list[1].id == "a.first" and list[2].id == "mount:fix", "one whose key is taken away is not")
    K.bindKey("bad", "nokey", function() end)
    check(#K.keyList() == 2, "nor one whose key is unknown")
    done(c)
end

-- ---------------------------------------------------------------------------
section("11. notes on screen: the box")
do
    local c = fresh({ widgets = true, diag = true })
    local K, ue, w, ui = c.K, c.ue, c.world, c.ui
    check(K.toastAvailable() == true and K.prepareToast() == true and #ue.lookups == 6 and ui.created == 0, "prepareToast searches the six paths the box needs and builds nothing")
    check(K.toast("first", 3) == true and ui.created == 1 and ui.constructed == 4 and ui.createArgs[1] == w.controller and ui.createArgs[3] == w.controller
        and ui.createArgs[2] == ue.objects["/Script/UMG.UserWidget"], "the first note builds the box once: a user widget owned by the controller, a canvas, two borders, a text")
    check(ui.note() == "first" and ui.count("AddToViewport") == 1 and ui.last("AddToViewport").args[1] == 60 and c.fake.value("kit.toast") == "shown", "shown (visibility 3), in the viewport once; noted for the diagnostics")
    local text, frame, fill = ui.TextBlock[1], ui.Border[1], ui.Border[2]
    local fc, ic = ui.last("SetBrushColor", frame).args[1], ui.last("SetBrushColor", fill).args[1]
    local tc = ui.last("SetColorAndOpacity", text).args[1]
    check(fc.R == 0 and fc.G == 0 and fc.B == 0 and fc.A == 1 and ic.R == 1 and ic.G == 1 and ic.B > 0.75 and ic.B < 0.76 and ic.A == 1
        and tc.SpecifiedColor.R == 0 and tc.SpecifiedColor.G == 0 and tc.SpecifiedColor.B == 0 and tc.SpecifiedColor.A == 1 and tc.ColorUseRule == 0, "a black frame, pale yellow inside, black letters")
    local fp, ip = ui.last("SetPadding", frame).args[1], ui.last("SetPadding", fill).args[1]
    check(fp.Left == 1 and fp.Top == 1 and fp.Right == 1 and fp.Bottom == 1 and ip.Left == 9 and ip.Top == 4 and ip.Right == 9 and ip.Bottom == 5, "the frame is one unit wide; the text has 9 units of room at the sides, 4 above, 5 below")
    check(ui.last("SetContent", fill).args[1] == text and ui.last("SetContent", frame).args[1] == fill
        and ui.last("AddChildToCanvas").args[1] == frame and rawget(ui.tree, "RootWidget") == ui.CanvasPanel[1], "the text sits in the fill, the fill in the frame, the frame on the canvas")
    local anchors, alignment, position = ui.last("SetAnchors").args[1], ui.last("SetAlignment").args[1], ui.last("SetPosition").args[1]
    check(anchors.Minimum.X == 1 and anchors.Minimum.Y == 0 and anchors.Maximum.X == 1 and anchors.Maximum.Y == 0 and alignment.X == 1 and alignment.Y == 0 and position.X == -24 and position.Y == 96
        and ui.last("SetAutoSize").args[1] == true, "anchored to the top right corner, sized by its text")
    check(text.Font.Size == 12 and text.Font.TypefaceFontName.__s == "Regular" and ui.count("SetFont") == 1, "letter size 12, regular weight")
    -- lines
    check(K.toast("second", 5) == true and ui.note() == "first\nsecond" and ui.created == 1, "a second note stands below the first, in the same box")
    c.ticks(11)
    check(ui.note() == "first\nsecond", "both are up after 2.75 seconds")
    c.ticks(1)
    check(ui.note() == "second", "after 3 seconds the first has had its time; the second (5 seconds) stays")
    c.ticks(8)
    check(ui.note() == nil and ui.last("SetVisibility", ui.widget).args[1] == 1, "after 5 seconds the box is hidden (visibility 1)")
    local calls = #ui.calls
    c.ticks(20)
    K.hideToast()
    K.hideToast("xp")
    check(#ui.calls == calls, "while nothing is up the box is left alone (also by hideToast)")
    K.toast("steady", 5)
    calls = #ui.calls
    c.ticks(19)
    check(#ui.calls == calls and ui.note() == "steady", "a note that is up is not drawn again at every look")
    c.ticks(1)
    -- slots
    K.toast("xp 1", 3, "xp")
    K.toast("ore", 3, "mining")
    K.toast("xp 2", 3, "xp")
    check(ui.note() == "xp 2\nore", "a note with a slot replaces the earlier note of that slot, in its place")
    K.hideToast("mining")
    check(ui.note() == "xp 2", "hideToast with a slot takes that line away")
    calls = #ui.calls
    K.hideToast("nothing")
    check(ui.note() == "xp 2" and #ui.calls == calls, "a slot that has no line: nothing happens")
    K.toast("a")
    K.toast("b")
    K.toast("c")
    K.toast("d")
    check(ui.note() == "a\nb\nc\nd", "more than four lines: the oldest goes")
    K.hideToast()
    check(ui.note() == nil and #c.t.toast.lines == 0, "hideToast without a slot hides the box")
    c.ticks(1)
    K.toast(5, "x")
    c.ticks(11)
    local up = ui.note()
    c.ticks(1)
    check(up == "5" and ui.note() == nil, "anything can be shown; seconds that are no number mean 3")
    -- the widget goes away
    K.toast("again")
    ui.widget.__valid = false
    check(K.toast("rebuilt") == true and ui.created == 2 and ui.note() == "again\nrebuilt" and #ue.lookups == 6, "a box that is gone is built again for the next note, without a search; the lines that were up stay")
    ui.widget.__full = "UserWidget /Engine/Transient.Other_9"
    check(K.toast("once more", 3, "s") == true and ui.created == 3, "so is one whose wrapper now names another object")
    rawset(ui.widget, "__inViewport", false)
    local added = ui.count("AddToViewport")
    K.toast("back", 3, "s")
    check(ui.created == 3 and ui.count("AddToViewport") == added + 1 and ui.last("AddToViewport").args[1] == 60, "a box that was taken out of the viewport is put back in")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    ui.widget.__valid = false
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    check(#c.t.toast.lines == 0 and K.toast("new world") == true and ui.created == 4 and ui.note() == "new world", "a map change: the lines are gone with the old world, the next note builds a new box")
    check(c.fake.count["kit.toast"] == 1, "the note for the diagnostics is made once")
    done(c)

    -- no hero yet
    c = fresh({ widgets = true, world = function(ue) return T.newWorld(ue, { noController = true }) end })
    check(c.K.toast("early") == false and c.K.toastAvailable() == true and #c.t.toast.lines == 0 and #c.ue.lookups == 0,
        "no hero yet: the note is not shown and not kept; the box is not given up, nothing is searched for it")
    c.ue.allOf["GothicPlayerControllerBaseBP_C"] = { c.world.controller }
    c.ticks(12)
    check(c.K.toast("later") == true and c.ui.note() == "later", "with a hero the next note is shown")
    done(c)

    -- things that are missing or fail
    for _, case in ipairs({
        { "a widget class is missing", { widgets = { missing = "/Script/UMG.Border" } }, "not found: /Script/UMG.Border" },
        { "the widget library is missing", { widgets = { missing = "/Script/UMG.Default__WidgetBlueprintLibrary" } }, "not found: /Script/UMG.Default__WidgetBlueprintLibrary" },
        { "the text library is missing", { widgets = { missing = "/Script/Engine.Default__KismetTextLibrary" } }, "not found: /Script/Engine.Default__KismetTextLibrary" },
        { "putting the box together raises", { widgets = { failing = "SetPadding" } }, "the widget could not be put together" },
        { "showing raises", { widgets = { failing = "SetText" } }, "the text could not be set" },
        { "adding to the viewport raises", { widgets = { failing = "AddToViewport" } }, "the widget could not be put together" },
    }) do
        local options = case[2]
        options.diag = true
        c = fresh(options)
        local first = c.K.toast("x")
        local searches = #c.ue.lookups
        check(first == false and c.K.toast("y") == false and c.K.toastAvailable() == false and c.K.prepareToast() == false and #c.ue.lookups == searches and #c.ue.errors == 0,
            case[1] .. ": false, the box is given up for this run, nothing is searched again")
        check(c.printed("[G1R_MegaMod] notes on screen are not available (" .. case[3] .. ")") == 1 and c.fake.value("kit.toast") == "not available" and c.fake.detail("kit.toast") == case[3],
            case[1] .. ": said once in the log and noted with the reason")
        check(c.ui.widget == nil or c.ui.last("SetVisibility", c.ui.widget) == nil or c.ui.last("SetVisibility", c.ui.widget).args[1] == 1, case[1] .. ": no half-built box stays visible")
        done(c)
    end
    c = fresh({ widgets = true })
    rawset(_G, "StaticConstructObject", nil)
    check(c.K.toast("x") == false and c.printed("this UE4SS build has no StaticConstructObject") == 1, "a UE4SS without StaticConstructObject: given up with that reason")
    done(c)
    c = fresh({ widgets = true })
    c.ue.objects["/Script/UMG.Default__WidgetBlueprintLibrary"].Create = function() return c.ue:invalid() end
    check(c.K.toast("x") == false and c.printed("the widget could not be created") == 1, "the library gives no widget: given up")
    done(c)
    c = fresh({ widgets = true })
    rawset(_G, "StaticConstructObject", function() return c.ue:invalid() end)
    check(c.K.toast("x") == false and c.printed("a widget could not be created") == 1, "a part cannot be made: given up")
    done(c)
    for _, part in ipairs({ "CanvasPanel", "Border", "TextBlock" }) do
        c = fresh({ widgets = true })
        local construct = rawget(_G, "StaticConstructObject")
        rawset(_G, "StaticConstructObject", function(class, outer)
            if class.__full:find(part, 1, true) then return c.ue:invalid() end
            return construct(class, outer)
        end)
        check(c.K.toast("x") == false and c.printed("a widget could not be created") == 1 and c.K.toastAvailable() == false, "only the " .. part .. " cannot be made: given up")
        done(c)
    end
    c = fresh({ widgets = true })
    c.ue.objects["/Script/UMG.Default__WidgetBlueprintLibrary"].Create = function() return c.ue:object("UserWidget /Engine/Transient.UserWidget_1", {}) end
    check(c.K.toast("x") == false and c.printed("the widget could not be created") == 1, "a widget without a widget tree: given up")
    done(c)
    c = fresh({ widgets = { missing = "/Script/UMG.TextBlock" } })
    check(c.K.prepareToast() == false and c.K.toastAvailable() == false, "prepareToast itself says false when a path is missing")
    done(c)
    c = fresh({ widgets = true })
    c.K.prepareToast()
    c.ue.objects["/Script/Engine.Default__KismetTextLibrary"].Conv_StringToText = function() return nil end
    check(c.K.toast("x") == false and c.printed("notes on screen are not available (text could not be made)") == 1, "the text library gives no text: false, given up with that reason")
    done(c)
    c = fresh({ widgets = true })
    c.ue.objects["/Script/UMG.Default__WidgetBlueprintLibrary"].Create = function(_, context, class, owner)
        local widget = T.recorder(c.ue, c.ui.calls, "UserWidget /Engine/Transient.UserWidget_1", { WidgetTree = T.recorder(c.ue, c.ui.calls, "WidgetTree /Engine/Transient.UserWidget_1.WidgetTree") })
        c.ui.widget = widget
        return widget
    end
    c.ui.TextBlockFont = true
    local construct = rawget(_G, "StaticConstructObject")
    rawset(_G, "StaticConstructObject", function(class, outer)
        local o = construct(class, outer)
        if class.__full:find("TextBlock", 1, true) then rawset(o, "Font", nil) end
        return o
    end)
    check(c.K.toast("x") == true and c.ui.note() == "x", "a text widget whose font cannot be set: the note is shown with the widget's own font")
    done(c)
end

-- ---------------------------------------------------------------------------
section("11b. a box of lines of a module's own (panel)")
do
    local c = fresh({ widgets = true, diag = true })
    local K, ue, ui = c.K, c.ue, c.ui
    check(K.panel(5) == nil and K.panel(nil) == nil, "a box needs a name")
    local P = K.panel("keys", { position = "top left", dx = 32, dy = 40, z = 1000 })
    check(K.panel("keys") == P and K.panel("keys", { z = 5 }) == P and P.available() == true and ui.created == 0 and #ue.lookups == 0,
        "a box is made once per name (later options do not change it); nothing is built or searched before it is shown")
    check(P.show({ "Y - wait", "F2 - menu" }) == true and ui.created == 1 and ui.constructed == 4 and #ue.lookups == 6 and ui.createArgs[1] == c.world.controller,
        "the first show builds it: the note box's six paths, a user widget owned by the controller, four parts")
    local text = ui.TextBlock[1]
    check(ui.last("SetText", text).args[1].text == "Y - wait\nF2 - menu" and ui.last("SetVisibility", P.widget).args[1] == 3 and ui.last("AddToViewport", P.widget).args[1] == 1000,
        "the lines one below the other, shown (3, takes no clicks), on layer 1000")
    local fc, ic = ui.last("SetBrushColor", ui.Border[1]).args[1], ui.last("SetBrushColor", ui.Border[2]).args[1]
    check(fc.R == 0 and fc.A == 1 and ic.R == 1 and ic.G == 1 and ic.B > 0.75 and ic.B < 0.76 and text.Font.Size == 12, "the notes' look: a black frame, pale yellow inside, letters of size 12")
    local anchors, alignment, position = ui.last("SetAnchors").args[1], ui.last("SetAlignment").args[1], ui.last("SetPosition").args[1]
    check(anchors.Minimum.X == 0 and anchors.Minimum.Y == 0 and anchors.Maximum.X == 0 and anchors.Maximum.Y == 0 and alignment.X == 0 and alignment.Y == 0
        and position.X == 32 and position.Y == 40 and ui.last("SetAutoSize").args[1] == true, "anchored at the top left, 32 / 40 from the corner, sized by its text")
    check(c.fake.value("kit.panel") == "shown" and c.fake.detail("kit.panel") == "keys", "noted for the diagnostics")
    local calls = #ui.calls
    check(P.show({ "Y - wait", "F2 - menu" }) == true and #ui.calls == calls, "the same lines again: nothing is done")
    check(P.show({ "Y - wait", 7 }) == true and ui.last("SetText", text).args[1].text == "Y - wait\n7" and ui.created == 1, "other lines: the text is set anew in the same box")
    P.hide()
    check(P.shown == false and ui.last("SetVisibility", P.widget).args[1] == 1, "hide: collapsed (1)")
    calls = #ui.calls
    P.hide()
    check(#ui.calls == calls, "hiding a box that is hidden does nothing")
    check(P.show({ "Y - wait", 7 }) == true and ui.last("SetVisibility", P.widget).args[1] == 3 and ui.created == 1, "shown again after a hide, with the same lines")
    -- other boxes beside it
    local Q = K.panel("plain")
    check(Q.show("one line") == true and ui.created == 2 and ui.last("SetText").args[1].text == "one line", "a second box is a widget of its own; a text alone is one line")
    local qa, qp = ui.last("SetAlignment").args[1], ui.last("SetPosition").args[1]
    check(qa.X == 0 and qa.Y == 0 and qp.X == 24 and qp.Y == 96 and ui.last("AddToViewport").args[1] == 60, "without options: the notes' top left place (24 / 96), layer 60")
    local R = K.panel("corner", { position = "bottom right", dx = "x", z = "high" })
    R.show({ "x" })
    local ra, rp = ui.last("SetAlignment").args[1], ui.last("SetPosition").args[1]
    check(ra.X == 1 and ra.Y == 1 and rp.X == -24 and rp.Y == -160 and ui.last("AddToViewport").args[1] == 60, "another corner; a distance or layer that is no number is the default")
    local S = K.panel("odd", { position = "middle" })
    S.show({ "x" })
    check(ui.last("SetAlignment").args[1].X == 0 and ui.last("SetPosition").args[1].Y == 96, "a corner the kit does not know: the top left")
    check(K.toast("note") == true and ui.created == 5 and P.available() and Q.available(), "the note box is a widget of its own as well")
    -- the size of the letters
    local borders = #ui.Border
    local Z = K.panel("small", { size = 10 })
    check(Z.size == 10 and Z.show({ "small" }) == true and ui.created == 6, "(a box with letters of size 10)")
    local zt, zf = ui.TextBlock[#ui.TextBlock], ui.Border[borders + 2]
    local zp, zfp = ui.last("SetPadding", zf).args[1], ui.last("SetPadding", ui.Border[borders + 1]).args[1]
    check(zt.Font.Size == 10 and zp.Left == 8 and zp.Top == 3 and zp.Right == 8 and zp.Bottom == 4 and zfp.Left == 1,
        "size 10: letters of size 10 and the space around them in step (8 / 3 / 8 / 4 instead of 9 / 4 / 9 / 5); the frame stays 1")
    check(K.panel("big", { size = 99 }).size == 40 and K.panel("tiny", { size = 1 }).size == 6 and K.panel("word", { size = "x" }).size == 12 and K.panel("half", { size = 10.6 }).size == 11,
        "a size is a whole number from 6 to 40 (rounded, pulled inside); one that is no number is 12")
    check(Z.resize(10) == false and Z.resize("x") == false and Z.widget ~= nil and Z.shown == true, "the same size again, or no number: nothing changes")
    local zw = Z.widget
    check(Z.resize(14) == true and Z.size == 14 and Z.shown == false and Z.widget == nil and ui.last("SetVisibility", zw).args[1] == 1 and ui.count("RemoveFromParent") >= 1,
        "another size: the box is taken down (hidden and removed)")
    check(Z.show({ "small" }) == true and ui.created == 7 and ui.TextBlock[#ui.TextBlock].Font.Size == 14, "and built anew at its next show, with the new size")
    -- gone, out of the viewport, renamed, a map change
    P.widget.__valid = false
    check(P.show({ "again" }) == true and ui.created == 8 and #ue.lookups == 6, "a widget that is gone: built again, without a search")
    rawset(P.widget, "__inViewport", false)
    local added = ui.count("AddToViewport")
    P.show({ "back" })
    check(ui.count("AddToViewport") == added + 1 and ui.last("AddToViewport").args[1] == 1000, "taken out of the viewport by the game: put back on its layer")
    P.text.__valid = false
    check(P.show({ "text gone" }) == true and ui.created == 9, "a text that is gone: built again")
    P.widget.__full = "UserWidget /Engine/Transient.Other_3"
    check(P.show({ "renamed" }) == true and ui.created == 10, "a wrapper that names another object now: built again")
    local before = P.widget
    P.widget.__valid = false
    P.hide()
    check(P.shown == false and ui.last("SetVisibility", before).args[1] == 3, "hiding a box whose widget is gone: nothing is asked of it")
    P.show({ "x" })
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    check(P.shown == false and P.widget == nil and Q.widget == nil and P.show({ "new world" }) == true and ui.created == 12, "a map change: every box is forgotten and built again at its next show")
    check(c.fake.count["kit.panel"] == 1 and #ue.errors == 0, "the note for the diagnostics is made once; nothing raised")
    done(c)

    -- no hero yet
    c = fresh({ widgets = true, world = function(u) return T.newWorld(u, { noController = true }) end })
    local E = c.K.panel("early")
    check(E.show({ "x" }) == false and E.available() == true and c.ui.created == 0, "no hero yet: false, not given up, nothing built")
    c.ue.allOf["GothicPlayerControllerBaseBP_C"] = { c.world.controller }
    c.ticks(12)
    check(E.show({ "x" }) == true and c.ui.created == 1, "with a hero it is shown")
    done(c)

    -- things that are missing or fail: the box is given up for the run
    for _, case in ipairs({
        { "a widget class is missing", { widgets = { missing = "/Script/UMG.Border" } }, "not found: /Script/UMG.Border" },
        { "putting the box together raises", { widgets = { failing = "SetPadding" } }, "the widget could not be put together" },
        { "showing raises", { widgets = { failing = "SetText" } }, "the text could not be set" },
    }) do
        local options = case[2]
        options.diag = true
        c = fresh(options)
        local B = c.K.panel("k", { z = 1000 })
        local first = B.show({ "x" })
        local searches, built = #c.ue.lookups, c.ui.created
        check(first == false and B.show({ "y" }) == false and B.available() == false and #c.ue.lookups == searches and c.ui.created == built and #c.ue.errors == 0 and B.widget == nil,
            case[1] .. ": false, given up for this run, nothing is searched or built again")
        check(c.printed('[G1R_MegaMod] the box "k" is not available (' .. case[3] .. ")") == 1 and c.fake.value("kit.panel") == "not available" and c.fake.detail("kit.panel") == "k: " .. case[3],
            case[1] .. ": said once in the log and noted with the box and the reason")
        check(c.ui.widget == nil or c.ui.last("SetVisibility", c.ui.widget) == nil or c.ui.last("SetVisibility", c.ui.widget).args[1] == 1, case[1] .. ": no half-built box stays visible")
        check(c.K.toastAvailable() == true, case[1] .. ": the note box is not given up with it")
        done(c)
    end
    c = fresh({ widgets = true })
    rawset(_G, "StaticConstructObject", nil)
    check(c.K.panel("k").show({ "x" }) == false and c.printed("this UE4SS build has no StaticConstructObject") == 1, "a UE4SS without StaticConstructObject: given up with that reason")
    done(c)
    c = fresh({ widgets = true })
    c.ue.objects["/Script/UMG.Default__WidgetBlueprintLibrary"].Create = function() return c.ue:invalid() end
    check(c.K.panel("k").show({ "x" }) == false and c.printed("the widget could not be created") == 1, "the library gives no widget: given up")
    done(c)
    c = fresh({ widgets = true })
    rawset(_G, "StaticConstructObject", function() return c.ue:invalid() end)
    check(c.K.panel("k").show({ "x" }) == false and c.printed("a widget could not be created") == 1, "a part cannot be made: given up")
    done(c)
    c = fresh({ widgets = true })
    local B = c.K.panel("k")
    B.show({ "x" })
    c.ue.objects["/Script/Engine.Default__KismetTextLibrary"].Conv_StringToText = function() return nil end
    check(B.show({ "y" }) == false and c.printed('the box "k" is not available (text could not be made)') == 1 and c.ui.last("SetVisibility", c.ui.widget).args[1] == 1,
        "the text library gives no text: given up, the box that was up is hidden")
    done(c)
end

-- ---------------------------------------------------------------------------
section("11c. the letters of the mod's texts")
do
    local GOTHIC = "/Game/UI/Fonts/Boucherie-Block_Font.Boucherie-Block_Font"
    local BOOK = "/Game/UI/Fonts/NotoSerif-Regular_Font.NotoSerif-Regular_Font"
    -- text blocks hold the engine's font, as a new one does in the game
    local function withFonts(options)
        local c = fresh(options or { widgets = true, diag = true })
        c.engineFont = c.ue:object("Font /Engine/EngineFonts/Roboto.Roboto", {})
        c.gothic = c.ue:object("Font " .. GOTHIC, {})
        c.book = c.ue:object("Font " .. BOOK, {})
        c.ue.objects[GOTHIC], c.ue.objects[BOOK] = c.gothic, c.book
        local construct = rawget(_G, "StaticConstructObject")
        rawset(_G, "StaticConstructObject", function(class, outer)
            local o = construct(class, outer)
            if class.__full:find("TextBlock", 1, true) then o.Font.FontObject = c.engineFont end
            return o
        end)
        return c
    end
    local function lastFont(c, text) local call = c.ui.last("SetFont", text) return call and call.args[1] end

    local c = withFonts()
    local K, ue, ui = c.K, c.ue, c.ui
    check(K.letters() == "plain" and K._test.letters.choice == "plain", "the letters start as the engine's own (plain)")
    K.toast("plain note")
    local f = lastFont(c, ui.TextBlock[1])
    check(f.FontObject == c.engineFont and f.TypefaceFontName.__s == "Regular" and f.Size == 12 and #ue.lookups == 6 and c.fake.value("kit.letters") == nil,
        "plain: the engine's own font, regular, size 12; no font is looked up")
    K.configureLetters("gothic")
    f = lastFont(c, ui.TextBlock[1])
    check(K.letters() == "gothic" and f.FontObject == c.gothic and f.TypefaceFontName.__s == "Default" and f.Size == 12 and ue.lookups[7] == GOTHIC
        and c.fake.value("kit.letters") == "set" and c.fake.detail("kit.letters") == "gothic", "gothic: the box that is up gets the game's blackletter at once (typeface Default), looked up by its path")
    local P = K.panel("list")
    P.show({ "a" })
    f = lastFont(c, P.text)
    check(f.FontObject == c.gothic and #ue.lookups == 7, "a box built later gets it as well; the font is looked up once")
    local Z = K.panel("sized", { size = 9 })
    Z.show({ "z" })
    K.configureLetters("book")
    check(lastFont(c, P.text).FontObject == c.book and lastFont(c, ui.TextBlock[1]).FontObject == c.book and ue.lookups[8] == BOOK, "book: every box there is gets the game's book letters")
    check(lastFont(c, Z.text).FontObject == c.book and lastFont(c, Z.text).Size == 9 and lastFont(c, P.text).Size == 12, "a box with letters of its own size keeps that size")
    K.configureLetters("plain")
    check(lastFont(c, P.text).FontObject == c.engineFont and lastFont(c, P.text).TypefaceFontName.__s == "Regular" and lastFont(c, ui.TextBlock[1]).FontObject == c.engineFont,
        "plain again: the engine's own font is put back (the one a new text block has)")
    local fonts = ui.count("SetFont")
    K.configureLetters("plain")
    K.configureLetters("fraktur")
    K.configureLetters(nil)
    check(ui.count("SetFont") == fonts and K.letters() == "plain", "the same letters again, or letters that are not one of the three: nothing happens")
    P.widget.__valid = false
    K.configureLetters("gothic")
    check(ui.count("SetFont") == fonts + 2, "a box whose widget is gone is left out (it gets the letters when it is built again; the note box and the sized box get them)")
    P.show({ "rebuilt" })
    fonts = ui.count("SetFont")
    P.text.__valid = false
    K.configureLetters("book")
    check(ui.count("SetFont") == fonts + 2, "a box whose text is gone is left out (only the note box and the sized box get them)")
    P.text.__valid = true
    P.widget.__full = "UserWidget /Engine/Transient.Other_7"
    K.configureLetters("gothic")
    check(ui.count("SetFont") == fonts + 4, "so is one whose wrapper names another object now")
    done(c)

    -- a font of the game that is not found
    c = withFonts()
    c.ue.objects[GOTHIC] = nil
    c.K.configureLetters("gothic")
    c.K.toast("x")
    f = lastFont(c, c.ui.TextBlock[1])
    check(f.FontObject == c.engineFont and f.TypefaceFontName.__s == "Regular" and c.fake.value("kit.letters") == "not found" and c.fake.detail("kit.letters") == GOTHIC and c.ui.note() == "x",
        "the game's font not found: the engine's own letters, noted with the path; the note is shown")
    done(c)

    -- a text block whose font cannot be set
    c = withFonts()
    c.K.configureLetters("book")
    local construct = rawget(_G, "StaticConstructObject")
    rawset(_G, "StaticConstructObject", function(class, outer)
        local o = construct(class, outer)
        if class.__full:find("TextBlock", 1, true) then rawset(o, "Font", nil) end
        return o
    end)
    check(c.K.toast("x") == true and c.ui.note() == "x" and c.ui.count("SetFont") == 0, "a text block whose font cannot be read: the note is shown with the widget's own letters")
    done(c)

    -- a text block without a font object of its own: plain leaves the font object alone
    c = fresh({ widgets = true })
    c.K.toast("x")
    local first = lastFont(c, c.ui.TextBlock[1])
    check(first.FontObject == nil and first.TypefaceFontName.__s == "Regular" and c.K._test.letters.engine == false, "a text block without a font object: plain sets size and weight only")
    done(c)
end

-- ---------------------------------------------------------------------------
section("12. notes on screen: the game's own line, and the way the player chose")
do
    local c = fresh({ widgets = true })
    local K, ue, w, ui = c.K, c.ue, c.world, c.ui
    check(K.subtitle("hello", 4) == true and #ui.subtitles == 1 and ui.subtitles[1].text == "hello" and ui.subtitles[1].title == "" and ui.subtitles[1].seconds == 4 and ui.subtitles[1].world == w.world,
        "subtitle: the game's function gets the hero's world, an empty title, the text and the seconds")
    check(K.subtitle("again") == true and ui.subtitles[2].seconds == 3 and #ue.lookups == 2, "seconds default to 3; the two paths are searched once")
    check(K.text("abc").text == "abc" and K.text(5).text == "5", "text: the engine's text value for anything")
    -- notify: the default is the box
    check(K.notify("n1", "slot") == true and ui.note() == "n1" and #ui.subtitles == 2, "notify: the box by default")
    c.ticks(11)
    local up = ui.note()
    c.ticks(1)
    check(up == "n1" and ui.note() == nil, "for 3 seconds by default")
    K.configureNotes({ seconds = 1 })
    K.notify("n2", "slot")
    c.ticks(3)
    up = ui.note()
    c.ticks(1)
    check(up == "n2" and ui.note() == nil, "configureNotes: seconds")
    K.notify("n3", "slot", 2)
    c.ticks(7)
    up = ui.note()
    c.ticks(1)
    check(up == "n3" and ui.note() == nil, "seconds given with a note count for that note")
    K.notify("n4", "slot")
    K.configureNotes({ style = "subtitle" })
    check(ui.note() == nil and K.notify("s1") == true and #ui.subtitles == 3 and ui.subtitles[3].text == "s1" and ui.subtitles[3].seconds == 1 and ui.note() == nil,
        "style subtitle: a box that is up is hidden; notes go to the game's own line")
    K.configureNotes({ style = "off" })
    check(K.notify("nothing") == false and #ui.subtitles == 3 and ui.note() == nil, "style off: no note of either kind")
    K.configureNotes({ style = "nonsense", seconds = -5, position = "middle" })
    K.configureNotes({ seconds = "x" })
    K.configureNotes({ seconds = 0 })
    K.configureNotes("x")
    K.configureNotes(5)
    K.configureNotes(nil)
    check(c.t.notes.style == "off" and c.t.notes.seconds == 1 and c.t.notes.position == "top right", "what is not usable changes nothing")
    -- position
    K.configureNotes({ style = "box", seconds = 3 })
    K.notify("p1")
    local created = ui.created
    local old = ui.widget
    K.configureNotes({ position = "bottom left" })
    check(ui.note() == nil and ui.last("RemoveFromParent", old) ~= nil, "a new position: the box that is up is taken off the screen")
    K.notify("p2")
    local anchors, alignment, position = ui.last("SetAnchors").args[1], ui.last("SetAlignment").args[1], ui.last("SetPosition").args[1]
    check(ui.created == created + 1 and ui.note() == "p2" and anchors.Minimum.X == 0 and anchors.Minimum.Y == 1 and alignment.X == 0 and alignment.Y == 1 and position.X == 24 and position.Y == -160,
        "the next note builds it in the new corner (bottom left)")
    K.configureNotes({ position = "bottom left" })
    check(ui.note() == "p2", "the same position again: nothing happens")
    for name, expect in pairs({ ["top left"] = { 0, 0, 24, 96 }, ["bottom right"] = { 1, 1, -24, -160 }, ["top right"] = { 1, 0, -24, 96 } }) do
        K.configureNotes({ position = name })
        K.notify("p")
        anchors, position = ui.last("SetAnchors").args[1], ui.last("SetPosition").args[1]
        check(anchors.Minimum.X == expect[1] and anchors.Maximum.Y == expect[2] and position.X == expect[3] and position.Y == expect[4], "position " .. name)
    end
    done(c)

    -- the box cannot be shown: the game's own line takes over
    c = fresh({ widgets = { missing = "/Script/UMG.Border" } })
    check(c.K.notify("fallback", "s") == true and #c.ui.subtitles == 1 and c.ui.subtitles[1].text == "fallback" and c.K.toastAvailable() == false, "notify with a box that cannot be built: the game's own line")
    done(c)
    c = fresh({ widgets = true })
    c.K.prepareNotes()
    check(#c.ue.lookups == 6, "prepareNotes with the box: the six paths are searched")
    done(c)
    c = fresh({ widgets = true })
    c.K.configureNotes({ style = "subtitle" })
    c.K.prepareNotes()
    check(#c.ue.lookups == 0, "prepareNotes with another style: nothing is searched")
    done(c)

    -- the game's line when things are missing
    c = fresh({ widgets = { missing = "/Script/G1R.Default__ConversationStatics" } })
    check(c.K.subtitle("x") == false and c.K.subtitle("x") == false and #c.ue.lookups == 1, "the game's subtitle function is missing: false, searched once")
    done(c)
    c = fresh({ widgets = { missing = "/Script/Engine.Default__KismetTextLibrary" } })
    check(c.K.subtitle("x") == false and c.K.text("x") == nil and #c.ui.subtitles == 0, "the text library is missing: false")
    done(c)
    c = fresh({ widgets = true, world = function(ue) return T.newWorld(ue, { noController = true }) end })
    check(c.K.subtitle("x") == false and #c.ue.lookups == 0, "no hero, so no world: false, nothing is searched")
    done(c)
    c = fresh({ widgets = true })
    c.ue.objects["/Script/Engine.Default__KismetTextLibrary"].Conv_StringToText = function(_, text) if text == "" then return nil end return { text = text } end
    check(c.K.subtitle("x") == false and #c.ui.subtitles == 0, "the text library gives no text for the empty title: false, the game's function is not called")
    done(c)
    c = fresh({ widgets = true })
    c.ue.objects["/Script/G1R.Default__ConversationStatics"].ShowTopSubtitle = function() error("boom") end
    check(c.K.subtitle("x") == false and #c.ue.errors == 0, "the game's function raises: false, no error gets out")
    done(c)
end

-- ---------------------------------------------------------------------------
-- The engine side of the game model (sections 13 - 17): the engine object
-- with its game window and game instance, and the engine's function
-- libraries, as the kit asks them. Built on T.newWorld; the model is
-- world.engineModel. options: noStatics, noLibrary, noStateLibrary,
-- noSystemLibrary (the path is not there), list (options of the list of
-- referenced objects), noList.
-- ---------------------------------------------------------------------------
-- An array of objects as UE4SS hands it out (dev/FACTS.md, U6): GetArrayNum,
-- ForEach with element wrappers, an index read gives the object, a write one
-- past the end adds an entry - and an index past the end adds empty entries
-- also on a read (counted in a.grownByRead: the kit must never do that).
-- options: unreadable (GetArrayNum raises), writeRaises, writeIgnored,
-- readsBack = function(value) -> what an index read answers.
local function objectArray(ue, options)
    options = options or {}
    local a = { items = {}, grownByRead = 0, writes = 0, reads = 0 }
    local methods = {
        GetArrayNum = function()
            if options.unreadable then error("not an array") end
            return #a.items
        end,
        ForEach = function(_, f)
            for i, v in ipairs(a.items) do
                if f(i, { get = function() return v end }) == true then break end
            end
        end,
    }
    a.wrapper = setmetatable({}, {
        __index = function(_, k)
            if type(k) ~= "number" then return methods[k] end
            a.reads = a.reads + 1
            while #a.items < k do
                a.items[#a.items + 1] = ue:invalid()
                a.grownByRead = a.grownByRead + 1
            end
            if options.readsBack then return options.readsBack(a.items[k]) end
            return a.items[k]
        end,
        __newindex = function(_, k, v)
            a.writes = a.writes + 1
            if options.writeRaises then error("the array cannot be written") end
            if options.writeIgnored then return end
            a.items[k] = v
        end,
    })
    return a
end

local STATICS = "/Script/Engine.Default__GameplayStatics"
local SYSTEM_LIBRARY = "/Script/Engine.Default__KismetSystemLibrary"
local LIBRARY = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local STATE_LIBRARY = "/Script/GameStateSubsystem.Default__GameStateSubsystemBlueprintLibrary"
local CVAR = "gc.MultithreadedDestructionEnabled"

local function engineModel(ue, options)
    options = options or {}
    local w = T.newWorld(ue, options.world)
    local m = { calls = { controller = 0, paused = 0, world = 0, instance = 0, state = 0, cvar = 0, command = 0 },
        asked = {}, commands = {}, answers = { world = {}, instance = {}, state = {} }, cvar = 1, paused = false }
    w.engineModel = m
    -- (the world the controller would name is another object: what the kit hands out shows whom it asked)
    w.shown = ue:object("World /Game/Maps/World.World", {})
    m.viewport = ue:object("GameViewportClient /Engine/Transient.GameEngine_0:GameViewportClient_0", { World = w.shown })
    m.list = objectArray(ue, options.list)
    m.instance = ue:object("G1RGameInstance /Engine/Transient.GameEngine_0:G1RGameInstance_0",
        { ReferencedObjects = (not options.noList) and m.list.wrapper or nil })
    m.engine = ue:object("GameEngine /Engine/Transient.GameEngine_0", { GameViewport = m.viewport, GameInstance = m.instance })
    m.parameter = { get = function() return m.engine end }      -- what UE4SS hands a map load hook first
    m.controller = w.controller                                 -- what the engine answers; false = none
    m.statics = ue:object("GameplayStatics " .. STATICS, {
        GetPlayerController = function(_, world, index)
            m.calls.controller = m.calls.controller + 1
            m.asked[#m.asked + 1] = { world = world, index = index }
            return m.controller or nil
        end,
        IsGamePaused = function(_, world)
            m.calls.paused = m.calls.paused + 1
            m.pausedWorld = world
            return m.paused
        end })
    local function answer(kind)
        return function(_, world, class)
            m.calls[kind] = m.calls[kind] + 1
            m.lastAsk = { kind = kind, world = world, class = class }
            return m.answers[kind][class]
        end
    end
    m.library = ue:object("SubsystemBlueprintLibrary " .. LIBRARY,
        { GetWorldSubsystem = answer("world"), GetGameInstanceSubsystem = answer("instance") })
    m.stateLibrary = ue:object("GameStateSubsystemBlueprintLibrary " .. STATE_LIBRARY, { GetGameStateSubsystem = answer("state") })
    m.systemLibrary = ue:object("KismetSystemLibrary " .. SYSTEM_LIBRARY, {
        GetConsoleVariableIntValue = function(_, name)
            m.calls.cvar = m.calls.cvar + 1
            m.cvarName = name
            return m.cvar
        end,
        ExecuteConsoleCommand = function(_, world, command, player)
            m.calls.command = m.calls.command + 1
            m.commands[#m.commands + 1] = { world = world, command = command, player = player }
            local value = tostring(command):match("^" .. CVAR:gsub("%.", "%%.") .. " (%d+)$")
            if value and m.commandTakes ~= false then m.cvar = tonumber(value) end
        end })
    if not options.noStatics then ue.objects[STATICS] = m.statics end
    if not options.noLibrary then ue.objects[LIBRARY] = m.library end
    if not options.noStateLibrary then ue.objects[STATE_LIBRARY] = m.stateLibrary end
    if not options.noSystemLibrary then ue.objects[SYSTEM_LIBRARY] = m.systemLibrary end
    -- a class of the game, and an object of it
    function m.class(name, place)
        local path = "/Script/" .. (place or "G1R") .. "." .. name
        local o = ue.objects[path] or ue:object("Class " .. path, {})
        ue.objects[path] = o
        return o
    end
    function m.subsystem(name, n, fields)
        return ue:object(("%s /Game/Maps/World.World:%s_%d"):format(name, name, n or 0), fields or {})
    end
    m.timeClass, m.profileClass = m.class("GameTimeSubsystem"), m.class("PersistentDataSubsystem")
    -- a map load, as UE4SS reports it
    function m.load(parameter)
        if parameter == nil then parameter = m.parameter end
        ue:fireLoadMapPre(parameter, "world", "url", nil, "")
        ue:fireLoadMapPost(parameter, "world", "url", nil, "")
    end
    return w
end
-- A fresh kit with the engine model; options as for engineModel, plus model = function(world, m) to change it
-- before the kit is loaded.
local function withEngine(options)
    options = options or {}
    local c = fresh({ diag = true, mock = options.mock, world = function(ue)
        local w = engineModel(ue, options)
        if options.model then options.model(w, w.engineModel) end
        return w
    end })
    c.m = c.world.engineModel
    function c.firstOf() return c.ue.calls.FindFirstOf or 0 end
    function c.note(key) return c.fake.value(key) end
    return c
end
-- Counts every question put to an object from now on (its methods and the fields it does not have).
local function watch(o)
    local seen = { n = 0 }
    local base = getmetatable(o)
    setmetatable(o, { __index = function(_, k)
        seen.n = seen.n + 1
        return base.__index[k]
    end })
    seen.release = function() setmetatable(o, base) end
    return seen
end

-- ---------------------------------------------------------------------------
section("13. the engine object: handed over at a map load, never searched for")
do
    local c = withEngine()
    local K, ue, w, m = c.K, c.ue, c.world, c.m
    check(K.engine() == nil and K.gameInstance() == nil and c.note("kit.engine") == nil, "before a map load there is no engine object")
    check(K.controller() == w.controller and c.allOf() == 1 and m.calls.controller == 0 and c.note("kit.controller_by") == "search"
        and K.world() == w.world, "the controller is searched for as before, the world is the one it names; the engine is not asked")
    -- what is not the engine is not taken
    local strangers = {
        "engine",
        { get = function() return nil end },
        ue:invalid(),
        { get = function() return ue:invalid() end },
        ue:object("GameEngine /Script/Engine.Default__GameEngine", { GameViewport = m.viewport }),
        ue:object("World /Game/Maps/World.World", { GameViewport = m.viewport }),
        ue:object("GameEngine /Engine/Transient.GameEngine_7", {}),
        5, true,
    }
    local taken = 0
    for _, s in ipairs(strangers) do
        m.load(s)
        if K.engine() ~= nil then taken = taken + 1 end
    end
    check(taken == 0 and #ue.errors == 0 and c.note("kit.engine") == nil,
        "a text, nothing, a dead object, a class default object, an object of another class, an engine without a game window: none is taken for the engine")
    m.load()
    check(K.engine() == m.engine and K.gameInstance() == m.instance and c.note("kit.engine") == "handed over at a map load"
        and c.fake.detail("kit.engine") == "GameEngine" and #ue.errors == 0, "a map load hands the engine object over: engine, game instance; noted with its class")
    check(K.world() == w.shown and m.calls.controller == 0, "the world is the one the game window shows; nobody had to be asked for it")
    local other = ue:object("GameEngine /Engine/Transient.GameEngine_1", { GameViewport = m.viewport, GameInstance = m.instance })
    m.load(other)
    check(K.engine() == m.engine and c.fake.count["kit.engine"] == 1, "the engine object is kept for the run: another one handed over later is not taken")
    m.instance.__valid = false
    check(K.gameInstance() == nil and K.engine() == m.engine, "a game instance that is gone: nil")
    m.viewport.World = ue:invalid()
    w.controller.GetWorld = function() return w.world end
    check(K.world() == w.world, "a game window without a world: the world is asked of the controller as before")
    m.viewport.World = w.shown
    m.engine.__valid = false
    check(K.engine() == nil and c.t.engine.object == nil and K.gameInstance() == nil, "an engine object that is gone is dropped")
    m.engine.__valid = true
    check(K.engine() == nil, "and is not looked for")
    m.load()
    check(K.engine() == m.engine, "the next map load hands it over again")
    m.engine.__valid = false
    m.load(other)
    check(K.engine() == other, "an engine object that is gone gives way to the one the next map load hands over")
    done(c)
    c = withEngine()
    local plain = c.ue:object("Engine /Engine/Transient.Engine_0", { GameViewport = c.m.viewport, GameInstance = c.m.instance })
    c.m.load(plain)
    check(c.K.engine() == plain and c.fake.detail("kit.engine") == "Engine", "the class name only has to hold the word Engine, wherever")
    done(c)

    -- the engine handed over as it is (no parameter wrapper), and by the hook before the load alone
    c = withEngine({ mock = { without = { "RegisterLoadMapPostHook" } } })
    c.ue:fireLoadMapPre(c.m.engine, "world", "url", nil, "")
    check(c.K.engine() == c.m.engine and c.K.loading() == false, "the engine object itself (not wrapped), from the hook before a load, in a UE4SS without the hook after it")
    done(c)

    -- pause: the engine can be asked without a hero
    c = withEngine({ world = { noController = true } })
    K, ue, w, m = c.K, c.ue, c.world, c.m
    check(K.paused() == false and m.calls.paused == 0, "no engine object, no hero: not paused, nothing asked")
    m.load()
    local searched = #ue.lookups
    m.paused = true
    check(K.paused() == true and m.pausedWorld == w.shown and c.allOf() == 2, "with the engine object the pause is asked with the shown world, hero or not")
    m.paused = false
    check(K.paused() == false and #ue.lookups == searched, "not paused; no path had to be searched for the question (they were looked up at the map load)")
    done(c)
end

-- ---------------------------------------------------------------------------
section("14. the controller, asked from the engine")
do
    local c = withEngine()
    local K, ue, w, m = c.K, c.ue, c.world, c.m
    m.load()
    check(K.controller() == w.controller and m.calls.controller == 1 and m.asked[1].world == w.shown and m.asked[1].index == 0
        and c.allOf() == 0 and c.note("kit.controller_by") == "engine", "the engine is asked for player 0 of the shown world; nothing is searched; noted")
    for _ = 1, 20 do K.controller() end
    check(m.calls.controller == 1, "asked once for the questions of one look")
    local state, name = K.playerState()
    check(state == w.hero.state and name == w.hero.state:GetFullName() and K.pawn() == w.pawn and K.attribute("Health", "Health") == 80,
        "player state, pawn, attributes hang on it as before")
    for _ = 1, 40 do
        c.ticks(1)
        K.controller()
    end
    check(m.calls.controller == 41 and c.allOf() == 0, "and anew at every look of the modules (a quarter second apart): the answer is not kept from one look to the next")
    -- the engine names another controller
    local second = T.controllerOf(ue, 6, w.hero.state)
    m.controller = second
    local first = watch(w.controller)
    c.ticks(1)
    check(K.controller() == second and first.n == 0 and c.fake.count["kit.controller_by"] == 1,
        "the engine names another controller: that is the controller now; the one named before is not asked anything")
    first.release()
    -- answers that are no controller
    m.controller = w.controllerDefault
    c.ticks(1)
    check(K.controller() == nil, "the class default object is no controller")
    m.controller = ue:invalid()
    c.ticks(2)
    check(K.controller() == nil and K.playerState() == nil and K.pawn() == nil and K.attributeSet("Health") == nil, "a dead object neither; nothing hangs on it")
    -- none, after the engine has answered: final
    m.controller = false
    local asks = m.calls.controller
    local any = false
    for _ = 1, 240 do
        c.ticks(1)
        if K.controller() ~= nil then any = true end
    end
    check(not any and c.allOf() == 0 and m.calls.controller - asks == 120,
        "the engine has none (main menu): nil for a minute, asked twice a second, nothing is searched")
    m.controller = w.controller
    c.ticks(2)
    check(K.controller() == w.controller and c.allOf() == 0, "it has one again: found at the next question")
    -- a map load in between
    ue:fireLoadMapPre(m.parameter, "world", "url", nil, "")
    check(c.t.hero.controller == nil, "(a map load drops what was kept)")
    ue:fireLoadMapPost(m.parameter, "world", "url", nil, "")
    asks = m.calls.controller
    check(K.controller() == w.controller and m.calls.controller == asks + 1, "after a map load the engine is asked at once")
    -- the game window loses its world: the search does the work
    m.viewport.World = nil
    c.ticks(1)
    asks = m.calls.controller
    check(K.controller() == w.controller and m.calls.controller == asks and c.allOf() == 0, "no shown world: the engine cannot be asked; the controller it named last is used while it is there")
    w.controller.__valid = false
    local third = T.controllerOf(ue, 8, w.hero.state)
    ue.allOf["GothicPlayerControllerBaseBP_C"] = { third }
    check(K.controller() == third and c.allOf() == 1 and c.note("kit.controller_by") == "search", "gone: searched for, as before")
    done(c)

    -- the engine's way never answers: after ten seconds the search takes over
    c = withEngine({ model = function(_, model) model.controller = false end })
    K, ue, w, m = c.K, c.ue, c.world, c.m
    m.load()
    any = K.controller() ~= nil
    for _ = 1, 39 do
        c.ticks(1)
        if K.controller() ~= nil then any = true end
    end
    check(not any and c.allOf() == 0 and m.calls.controller == 20, "the engine answers none and never has: for ten seconds that is taken as the answer")
    c.ticks(1)
    check(K.controller() == w.controller and c.allOf() == 1 and c.note("kit.controller_by") == "search (the engine's own way answered nothing)",
        "then the search does the work, and it is noted that the engine's way answered nothing")
    asks = m.calls.controller
    any = true
    for _ = 1, 40 do
        c.ticks(1)
        if K.controller() ~= w.controller then any = false end
    end
    check(any and c.allOf() == 1 and m.calls.controller - asks == 20, "the controller found is kept and checked as before; the engine goes on being asked")
    w.controller.__valid = false
    local later = T.controllerOf(ue, 6, w.hero.state)
    ue.allOf["GothicPlayerControllerBaseBP_C"] = { later }
    local found
    for _ = 1, 12 do
        c.ticks(1)
        found = K.controller()
    end
    check(found == later and c.allOf() == 2, "gone: searched again after the usual wait")
    m.controller = later
    c.ticks(2)
    check(K.controller() == later and c.note("kit.controller_by") == "engine", "the engine's way answers after all: it is used from then on")
    m.controller = false
    any = false
    for _ = 1, 80 do
        c.ticks(1)
        if K.controller() ~= nil then any = true end
    end
    check(not any and c.allOf() == 2, "and its none is the answer now: nothing is searched")
    done(c)

    -- the ten seconds are not counted while a map loads, and start anew with the new world
    c = withEngine({ model = function(_, model) model.controller = false end })
    K, ue, w, m = c.K, c.ue, c.world, c.m
    m.load()
    ue:fireLoadMapPre(m.parameter, "world", "url", nil, "")
    any = false
    for _ = 1, 60 do
        c.ticks(1)
        if K.controller() ~= nil then any = true end
    end
    check(not any and c.allOf() == 0 and K.loading() == true, "a map is loading for 15 seconds: nothing is searched")
    ue:fireLoadMapPost(m.parameter, "world", "url", nil, "")
    any = K.controller() ~= nil
    for _ = 1, 39 do
        c.ticks(1)
        if K.controller() ~= nil then any = true end
    end
    check(not any and c.allOf() == 0, "after the load the ten seconds start anew")
    c.ticks(1)
    check(K.controller() == w.controller and c.allOf() == 1, "then the search")
    done(c)

    -- the engine's library is not there
    c = withEngine({ noStatics = true })
    K, ue, w, m = c.K, c.ue, c.world, c.m
    m.load()
    check(#ue.lookups == 6 and ue.lookups[1] == STATICS and c.note("kit.paths_found") == "5 of 6 found", "(the engine's library is looked for at the first map load, with the kit's other paths, and is not there)")
    check(K.controller() == w.controller and c.allOf() == 1 and #ue.lookups == 6 and m.calls.controller == 0 and c.note("kit.controller_by") == "search",
        "without the engine's library the controller is searched for at once")
    c.ticks(40)
    m.load()
    check(K.controller() == w.controller and K.paused() == false and #ue.lookups == 6 and c.allOf() == 2, "and the library is not looked for again, at a later map load neither")
    done(c)
end

-- ---------------------------------------------------------------------------
section("15. subsystems, asked from the engine")
do
    local c = withEngine()
    local K, ue, w, m = c.K, c.ue, c.world, c.m
    local crimeClass = m.class("CrimeMemorySubsystem")
    local crime = m.subsystem("CrimeMemorySubsystem", 0)
    ue.firstOf["CrimeMemorySubsystem"] = crime
    m.answers.world[crimeClass] = crime
    check(K.subsystem("world", "CrimeMemorySubsystem", "G1R") == crime and c.firstOf() == 1 and m.calls.world == 0 and #ue.lookups == 0
        and c.note("kit.subsystem_by") == "search" and c.fake.detail("kit.subsystem_by") == "CrimeMemorySubsystem",
        "no engine object: the subsystem is searched for as before (no path is looked up for it)")
    m.load()
    local L = #ue.lookups       -- (the kit's own paths, looked up at the first map load: section 17)
    check(K.subsystem("world", "CrimeMemorySubsystem", "G1R") == crime and m.calls.world == 1 and m.lastAsk.world == w.shown and m.lastAsk.class == crimeClass
        and c.firstOf() == 1 and ue.lookups[L + 1] == "/Script/G1R.CrimeMemorySubsystem" and #ue.lookups == L + 1 and c.note("kit.subsystem_by") == "engine",
        "with it: the engine's library is asked with the shown world and the class (looked up by its path, once); nothing is searched among the objects")
    for _ = 1, 19 do
        c.ticks(1)
        K.subsystem("world", "CrimeMemorySubsystem", "G1R")
    end
    check(m.calls.world == 1, "the object is used for five seconds")
    c.ticks(1)
    check(K.subsystem("world", "CrimeMemorySubsystem", "G1R") == crime and m.calls.world == 2 and #ue.lookups == L + 1, "then the engine is asked again")
    local crime2 = m.subsystem("CrimeMemorySubsystem", 1)
    crime.__valid = false
    m.answers.world[crimeClass] = crime2
    check(K.subsystem("world", "CrimeMemorySubsystem", "G1R") == crime2 and m.calls.world == 3, "an object that is gone within the five seconds: asked again at once")
    crime2.__full = "Actor /Game/Maps/World.World:Actor_9"
    m.answers.world[crimeClass] = crime
    crime.__valid = true
    check(K.subsystem("world", "CrimeMemorySubsystem", "G1R") == crime and m.calls.world == 4, "so is one that names another object now")
    -- none, after the way has answered
    m.answers.world[crimeClass] = nil
    c.ticks(20)
    local any = false
    local asks = m.calls.world
    for _ = 1, 240 do
        c.ticks(1)
        if K.subsystem("world", "CrimeMemorySubsystem", "G1R") ~= nil then any = true end
    end
    check(not any and c.firstOf() == 1 and m.calls.world - asks == 60, "the engine has none (the way has answered before): nil, asked once a second, nothing is searched")
    m.answers.world[crimeClass] = ue:object("CrimeMemorySubsystem /Script/G1R.Default__CrimeMemorySubsystem", {})
    c.ticks(4)
    check(K.subsystem("world", "CrimeMemorySubsystem", "G1R") == nil, "a class default object is no subsystem")
    m.answers.world[crimeClass] = crime
    c.ticks(4)
    check(K.subsystem("world", "CrimeMemorySubsystem", "G1R") == crime, "there again: found")
    -- a map load
    asks = m.calls.world
    m.load()
    check(K.subsystem("world", "CrimeMemorySubsystem", "G1R") == crime and m.calls.world == asks + 1, "a map load drops what was kept: asked again at once")
    -- the three kinds
    local profiles, clock = m.subsystem("PersistentDataSubsystem", 0, { m_CurrentProfileId = 2 }), m.subsystem("GameTimeSubsystem", 0, { CurrentGameTime = { TotalSeconds = 1234.5 } })
    m.answers.instance[m.profileClass], m.answers.state[m.timeClass] = profiles, clock
    check(K.subsystem("instance", "PersistentDataSubsystem", "G1R") == profiles and m.calls.instance == 1 and m.lastAsk.kind == "instance" and m.lastAsk.class == m.profileClass,
        "a subsystem of the game instance: asked from the same library with its own function")
    check(K.subsystem("state", "GameTimeSubsystem", "G1R") == clock and m.calls.state == 1 and m.lastAsk.world == w.shown and m.lastAsk.class == m.timeClass,
        "a game-state subsystem: asked from the game's own library")
    check(K.gameSeconds() == 1234.5 and m.calls.state == 1 and c.firstOf() == 1 and #ue.lookups == L + 1,
        "the game clock comes that way: nothing searched, no path looked up (the two classes were looked up at the map load)")
    check(K.subsystem("world", "PersistentDataSubsystem", "G1R") == nil and m.calls.world == asks + 2, "each kind keeps its own answers")
    check(K.subsystem("galaxy", "CrimeMemorySubsystem", "G1R") == nil and K.subsystem("world", 5) == nil and K.subsystem(nil, nil) == nil and m.calls.world == asks + 2
        and #ue.errors == 0, "a kind that does not exist, a class that is no name: nil, nobody is asked")
    -- a class that is not found: the search
    local lookups, firsts = #ue.lookups, c.firstOf()
    check(K.subsystem("world", "NoSuchSubsystem", "G1R") == nil and #ue.lookups == lookups + 1 and c.firstOf() == firsts + 1,
        "a class that is not found by its path: the search among the objects is what is left")
    local odd = m.subsystem("NoSuchSubsystem", 0)
    ue.firstOf["NoSuchSubsystem"] = odd
    c.ticks(12)
    check(K.subsystem("world", "NoSuchSubsystem", "G1R") == odd and #ue.lookups == lookups + 1 and c.note("kit.subsystem_by") == "search", "and finds it; the path is not looked up again")
    done(c)

    -- the engine's way never answers: after ten seconds the search takes over
    c = withEngine()
    K, ue, w, m = c.K, c.ue, c.world, c.m
    local questClass = m.class("QuestSubsystem")
    local quests = m.subsystem("QuestSubsystem", 0)
    ue.firstOf["QuestSubsystem"] = quests
    m.load()
    any = K.subsystem("state", "QuestSubsystem", "G1R") ~= nil
    for _ = 1, 39 do
        c.ticks(1)
        if K.subsystem("state", "QuestSubsystem", "G1R") ~= nil then any = true end
    end
    check(not any and c.firstOf() == 0 and m.calls.state == 10, "the engine answers none and never has: for ten seconds that is taken as the answer")
    c.ticks(1)
    check(K.subsystem("state", "QuestSubsystem", "G1R") == quests and c.firstOf() == 1
        and c.note("kit.subsystem_by") == "search (the engine's own way answered nothing)" and c.fake.detail("kit.subsystem_by") == "QuestSubsystem",
        "then the search does the work, and it is noted that the engine's way answered nothing")
    asks = m.calls.state
    any = true
    for _ = 1, 40 do
        c.ticks(1)
        if K.subsystem("state", "QuestSubsystem", "G1R") ~= quests then any = false end
    end
    check(any and c.firstOf() == 1 and m.calls.state - asks == 10, "the object found is kept and checked as before; the engine goes on being asked once a second")
    -- (another class of the same kind has its own ten seconds)
    local weatherClass = m.class("WeatherSubsystem")
    local weather = m.subsystem("WeatherSubsystem", 0)
    m.answers.state[weatherClass] = weather
    check(K.subsystem("state", "WeatherSubsystem", "G1R") == weather and c.note("kit.subsystem_by") == "engine", "a class the engine does answer for is taken from the engine")
    m.answers.state[questClass] = quests
    c.ticks(4)
    check(K.subsystem("state", "QuestSubsystem", "G1R") == quests and c.note("kit.subsystem_by") == "engine", "the way answers after all: it is used from then on")
    m.answers.state[questClass] = nil
    quests.__valid = false
    ue.firstOf["QuestSubsystem"] = m.subsystem("QuestSubsystem", 1)
    any = false
    for _ = 1, 80 do
        c.ticks(1)
        if K.subsystem("state", "QuestSubsystem", "G1R") ~= nil then any = true end
    end
    check(not any and c.firstOf() == 1, "and its none is the answer now: nothing is searched")
    done(c)

    -- the libraries are not there
    c = withEngine({ noLibrary = true, noStateLibrary = true })
    K, ue, w, m = c.K, c.ue, c.world, c.m
    m.load()
    local clockObject = m.subsystem("GameTimeSubsystem", 0, { CurrentGameTime = { TotalSeconds = 77.0 } })
    ue.firstOf["GameTimeSubsystem"] = clockObject
    check(#ue.lookups == 6 and c.note("kit.paths_found") == "4 of 6 found", "(the two libraries are looked for at the first map load and are not there)")
    check(K.gameSeconds() == 77 and c.firstOf() == 1 and m.calls.state == 0 and #ue.lookups == 6 and c.note("kit.subsystem_by") == "search",
        "without the engine's library a subsystem is searched for at once")
    check(K.subsystem("instance", "PersistentDataSubsystem", "G1R") == nil and #ue.lookups == 6 and c.firstOf() == 2, "the other kind too")
    c.ticks(40)
    K.gameSeconds()
    K.subsystem("instance", "PersistentDataSubsystem", "G1R")
    check(#ue.lookups == 6, "and the libraries are not looked for again")
    done(c)
end

-- ---------------------------------------------------------------------------
section("16. objects kept alive for the run")
do
    local c = withEngine()
    local K, ue, w, m = c.K, c.ue, c.world, c.m
    local picture = ue:object("Texture2D /Engine/Transient.Texture2D_1", {})
    local ok, why = K.keepAlive(picture)
    check(ok == false and why == "no game instance yet" and K.keptAlive() == 0 and c.note("kit.keep_alive") == nil, "no engine object yet: false, and nothing is given up")
    m.load()
    ok, why = K.keepAlive(picture)
    check(ok == true and why == nil and #m.list.items == 1 and m.list.items[1] == picture and K.keptAlive() == 1 and c.note("kit.keep_alive") == "works",
        "with the game instance: the object is added to its list of referenced objects, read back, and counted")
    check(m.list.writes == 1 and m.list.reads == 1 and m.list.grownByRead == 0, "one write one past the end, one read inside the list")
    check(K.keepAlive(picture) == true and #m.list.items == 1 and m.list.writes == 1, "the same object again: true, it is not added twice")
    local second = ue:object("Texture2D /Engine/Transient.Texture2D_2", {})
    check(K.keepAlive(second) == true and #m.list.items == 2 and m.list.items[2] == second and K.keptAlive() == 2 and m.list.grownByRead == 0, "another object: added after it")
    ok, why = K.keepAlive(nil)
    local ok2, why2 = K.keepAlive(ue:invalid())
    local ok3, why3 = K.keepAlive("picture")
    check(ok == false and why == "not an object" and ok2 == false and why2 == "not an object" and ok3 == false and why3 == "not an object" and #m.list.items == 2,
        "nothing, a dead object, a text: false, nothing is added")
    local odd = ue:object("Texture2D /Engine/Transient.Texture2D_9", {})
    odd.GetAddress = function() return "0x7ff6" end
    local raising = ue:object("Texture2D /Engine/Transient.Texture2D_8", {})
    raising.GetAddress = function() error("no address") end
    check(K.addressOf(picture) == picture.__address and K.addressOf(nil) == nil and K.addressOf(odd) == nil and K.addressOf(raising) == nil and K.addressOf(5) == nil,
        "addressOf: the number UE4SS gives; nil for nothing, for an answer that is no number, for a call that raises")
    ok, why = K.keepAlive(odd)
    check(ok == false and why == "the object has no address" and #m.list.items == 2, "an object whose address is no number is not kept")
    local noAddress = ue:object("Texture2D /Engine/Transient.Texture2D_3", {})
    noAddress.__address = nil
    ok, why = K.keepAlive(noAddress)
    check(ok == false and why == "the object has no address" and #m.list.items == 2 and c.note("kit.keep_alive") == "works" and #ue.errors == 0,
        "an object whose address cannot be told: false; that gives nothing up")
    m.load()
    check(K.keepAlive(picture) == true and m.list.writes == 2 and K.keptAlive() == 2, "a map load changes nothing: what is kept stays kept")
    done(c)

    -- element wrappers on reading back
    c = withEngine({ list = { readsBack = function(v) return { get = function() return v end } end } })
    c.m.load()
    check(c.K.keepAlive(c.ue:object("Texture2D /Engine/Transient.Texture2D_1", {})) == true, "a list whose entries read back wrapped: the same")
    done(c)

    -- what can go wrong, each time: false with the reason, noted, and not tried again
    local function failing(options, reason, text, after)
        c = withEngine(options)
        K, ue, m = c.K, c.ue, c.m
        m.load()
        local a, b = ue:object("Texture2D /Engine/Transient.Texture2D_1", {}), ue:object("Texture2D /Engine/Transient.Texture2D_2", {})
        local ok1, why1 = K.keepAlive(a)
        local writes, reads = m.list.writes, m.list.reads
        local ok2, why2 = K.keepAlive(b)
        local ok3, why3 = K.keepAlive(a)
        check(ok1 == false and why1 == reason and ok2 == false and why2 == reason and ok3 == false and why3 == reason and m.list.writes == writes and m.list.reads == reads
            and K.keptAlive() == 0 and c.note("kit.keep_alive") == "not available" and c.fake.detail("kit.keep_alive") == reason and c.fake.count["kit.keep_alive"] == 1
            and m.list.grownByRead == 0 and #ue.errors == 0 and (after == nil or after(m)), text)
        done(c)
    end
    failing({ noList = true }, "the game instance's list cannot be read", "the game instance has no such list: false, said once, the list is left alone from then on")
    failing({ list = { unreadable = true } }, "the game instance's list cannot be read", "its length cannot be read: the same",
        function(model) return model.list.writes == 0 end)
    failing({ list = { writeRaises = true } }, "the game instance's list cannot be added to", "the write raises: the same",
        function(model) return model.list.writes == 1 and #model.list.items == 0 end)
    failing({ list = { writeIgnored = true } }, "the game instance's list cannot be added to", "the write does nothing (the list is no longer than before): the same",
        function(model) return model.list.reads == 0 end)
    failing({ list = { readsBack = function() return nil end } }, "the entry does not read back", "the entry reads back as nothing: the same")
    local stranger
    failing({ list = { readsBack = function() return stranger end }, model = function(world) stranger = world.pawn end }, "the entry does not read back",
        "the entry reads back as another object: the same")
    failing({ list = { readsBack = function(v) v.__valid = false; return v end } }, "the entry does not read back", "the entry reads back dead: the same")
end

-- ---------------------------------------------------------------------------
section("17. the kit's own paths; where the engine frees objects")
do
    -- the paths
    local c = withEngine()
    local K, ue, w, m = c.K, c.ue, c.world, c.m
    local PATHS = { STATICS, SYSTEM_LIBRARY, LIBRARY, STATE_LIBRARY, "/Script/G1R.GameTimeSubsystem", "/Script/G1R.PersistentDataSubsystem" }
    check(c.atStart == 0 and #ue.lookups == 0 and c.note("kit.paths_found") == nil and table.concat(K.paths, " ") == table.concat(PATHS, " "),
        "loading the kit searches nothing by path")
    ue:fireLoadMapPre(m.parameter, "world", "url", nil, "")
    check(table.concat(ue.lookups, " ") == table.concat(PATHS, " "), "at the first map load the kit looks its own six paths up, each once, in the hook before the load")
    check(c.note("kit.paths_found") == "6 of 6 found" and c.fake.detail("kit.paths_found") == "at the first map load", "noted: all found")
    ue:fireLoadMapPost(m.parameter, "world", "url", nil, "")
    K.controller()
    K.paused()
    K.gameSeconds()
    K.subsystem("instance", "PersistentDataSubsystem", "G1R")
    m.load()
    m.load()
    check(#ue.lookups == 6 and c.fake.count["kit.paths_found"] == 1 and m.calls.controller > 0 and m.calls.instance > 0,
        "in the world, and at later map loads, none of them is looked up again")
    check(K.warm({ "/Script/G1R.Late", STATICS, 5, "/Script/G1R.Never" }) == 1 and #ue.lookups == 8, "warm: paths not known yet are looked up; it says how many of the paths are known now")
    ue.objects["/Script/G1R.Late"] = ue:object("Class /Script/G1R.Late", {})
    check(K.findOnce("/Script/G1R.Late") == ue.objects["/Script/G1R.Late"] and #ue.lookups == 9 and K.findOnce("/Script/G1R.Never") == nil and #ue.lookups == 10,
        "a path warm did not find is looked up once more when it is needed")
    check(K.warm({ "/Script/G1R.Late", "/Script/G1R.Never" }) == 1 and K.findOnce("/Script/G1R.Never") == nil and #ue.lookups == 10, "and then never again, found or not")
    check(K.warm(nil) == 0 and K.warm("x") == 0 and K.warm({}) == 0 and #ue.errors == 0, "warm with nothing to do: 0")
    done(c)
    -- paths that are not there
    c = withEngine({ noStateLibrary = true, noSystemLibrary = true })
    K, ue, w, m = c.K, c.ue, c.world, c.m
    m.load()
    check(#ue.lookups == 6 and c.note("kit.paths_found") == "4 of 6 found" and m.calls.cvar == 0, "paths that are not there at the first map load: noted")
    ue.objects[STATE_LIBRARY], ue.objects[SYSTEM_LIBRARY] = m.stateLibrary, m.systemLibrary
    local clock = m.subsystem("GameTimeSubsystem", 0, { CurrentGameTime = { TotalSeconds = 5.0 } })
    m.answers.state[m.timeClass] = clock
    ue.firstOf["GameTimeSubsystem"] = clock
    m.load()
    check(K.gameSeconds() == 5 and m.calls.state == 0 and c.firstOf() == 1 and m.calls.cvar == 0 and #ue.lookups == 6 and c.fake.count["kit.paths_found"] == 1,
        "they are parts of the game's program: what is not there then is not looked up again - not at later map loads, not when it is needed")
    done(c)
    -- needed before any map load (the mod was started in a running game)
    c = withEngine({ noStatics = true })
    K, ue, w, m = c.K, c.ue, c.world, c.m
    check(K.paused() == false and #ue.lookups == 1 and ue.lookups[1] == STATICS, "a path needed before the first map load is looked up then, once")
    m.load()
    check(#ue.lookups == 6 and K.paused() == false and #ue.lookups == 6 and c.note("kit.paths_found") == "5 of 6 found", "and not again at the first map load (the five others are)")
    done(c)
    c = withEngine()
    K, ue, w, m = c.K, c.ue, c.world, c.m
    check(K.paused() == false and m.calls.paused == 1 and #ue.lookups == 1, "(found before the first map load)")
    m.load()
    check(#ue.lookups == 6 and c.note("kit.paths_found") == "6 of 6 found", "a path found before the first map load is counted as found, and not looked up again")
    done(c)
    c = withEngine({ mock = { without = { "StaticFindObject" } } })
    c.m.load()
    check(c.note("kit.paths_found") == "0 of 6 found" and c.K.warm({ "/Script/G1R.X" }) == 0 and c.K.controller() == c.world.controller and #c.ue.errors == 0,
        "a UE4SS without the search by path: nothing found, no error, the hero is searched for as before")
    done(c)
    c = withEngine({ mock = { without = { "RegisterLoadMapPreHook" } }, noStatics = true })
    c.ue:fireLoadMapPost(c.m.parameter, "world", "url", nil, "")
    check(#c.ue.lookups == 1 and c.ue.lookups[1] == SYSTEM_LIBRARY and c.K.paused() == false and #c.ue.lookups == 2 and c.note("kit.paths_found") == nil,
        "a UE4SS without the hook before a map load: every path is looked up when it is needed, as before")
    done(c)

    -- the engine's way of freeing objects is read after every map load and left alone
    c = withEngine()
    K, ue, w, m = c.K, c.ue, c.world, c.m
    check(c.t.engineOptions.freeOnGameThread == false and m.calls.cvar == 0, "nothing is read before a map load; the switch is off")
    ue:fireLoadMapPre(m.parameter, "world", "url", nil, "")
    check(m.calls.cvar == 0 and c.note("kit.object_destruction") == nil, "nor by the hook before the load")
    ue:fireLoadMapPost(m.parameter, "world", "url", nil, "")
    check(m.calls.cvar == 1 and m.cvarName == CVAR and m.calls.command == 0 and c.note("kit.object_destruction") == "worker thread (the game's own way)",
        "after a map load the setting is read and noted; nothing is changed")
    m.load()
    check(m.calls.cvar == 2 and m.calls.command == 0 and c.fake.count["kit.object_destruction"] == 1, "at every map load; noted when it changes")
    m.cvar = 0
    m.load()
    check(c.note("kit.object_destruction") == "game thread" and m.calls.command == 0, "the game itself frees on the game thread: noted")
    m.cvar = "x"
    m.load()
    check(c.note("kit.object_destruction") == "not readable" and m.calls.command == 0 and #ue.errors == 0, "a value that is no number: noted as not readable")
    done(c)

    c = withEngine({ model = function(_, model) model.cvar = 0 end })
    c.m.load()
    check(c.note("kit.object_destruction") == "game thread" and c.m.calls.command == 0, "a game that frees on the game thread from the start: noted as the game's own, not as set by this mod")
    done(c)

    -- only Scripts/config.lua switches it
    for _, options in ipairs({ false, "x", {}, { FreeObjectsOnGameThread = "yes" }, { FreeObjectsOnGameThread = 1 }, { FreeObjectsOnGameThread = false } }) do
        c = withEngine()
        c.K.setup(options or nil)
        c.m.load()
        check(c.t.engineOptions.freeOnGameThread == false and c.m.calls.command == 0 and c.m.cvar == 1,
            "setup with " .. (type(options) == "table" and (options.FreeObjectsOnGameThread == nil and "an empty table" or ("FreeObjectsOnGameThread = " .. tostring(options.FreeObjectsOnGameThread))) or tostring(options))
            .. ": the setting is left alone")
        done(c)
    end
    c = withEngine()
    K, ue, w, m = c.K, c.ue, c.world, c.m
    K.setup({ FreeObjectsOnGameThread = true })
    check(c.t.engineOptions.freeOnGameThread == true and m.calls.command == 0, "setup with FreeObjectsOnGameThread = true: nothing happens before a map load")
    ue:fireLoadMapPre(m.parameter, "world", "url", nil, "")
    check(m.calls.command == 0, "nor in the hook before the load")
    ue:fireLoadMapPost(m.parameter, "world", "url", nil, "")
    check(m.calls.command == 1 and m.commands[1].command == CVAR .. " 0" and m.commands[1].world == w.shown and m.commands[1].player == nil and m.cvar == 0
        and c.note("kit.object_destruction") == "game thread (set by this mod)", "after the load the setting is switched with one console command, read back and noted")
    m.load()
    m.load()
    check(m.calls.command == 1 and c.note("kit.object_destruction") == "game thread (set by this mod)" and c.fake.count["kit.object_destruction"] == 1,
        "at later map loads it reads as set: no further command, the note stays")
    m.cvar = 1
    m.load()
    check(m.calls.command == 2 and m.cvar == 0, "the game has switched it back: set again after the next map load")
    K.setup({ FreeObjectsOnGameThread = false })
    m.cvar = 1
    m.load()
    check(m.calls.command == 2 and m.cvar == 1 and c.note("kit.object_destruction") == "worker thread (the game's own way)", "switched off in the settings again: left alone from the next map load on")
    done(c)
    c = withEngine({ model = function(_, model) model.commandTakes = false end })
    c.K.setup({ FreeObjectsOnGameThread = true })
    c.m.load()
    check(c.m.calls.command == 1 and c.note("kit.object_destruction") == "worker thread (the setting did not take)" and #c.ue.errors == 0, "the command does not take: noted as it is")
    done(c)
    c = withEngine({ noSystemLibrary = true })
    c.K.setup({ FreeObjectsOnGameThread = true })
    c.m.load()
    check(c.note("kit.object_destruction") == nil and #c.ue.errors == 0 and #c.ue.lookups == 6 and c.m.calls.cvar == 0, "without the engine's library nothing is read or switched")
    done(c)
    c = withEngine({ mock = { without = { "RegisterLoadMapPostHook" } } })
    c.K.setup({ FreeObjectsOnGameThread = true })
    c.ue:fireLoadMapPre(c.m.parameter, "world", "url", nil, "")
    check(c.m.calls.cvar == 0 and c.m.calls.command == 0, "a UE4SS without the hook after a map load: the setting is never touched")
    done(c)
end

T.finish()
