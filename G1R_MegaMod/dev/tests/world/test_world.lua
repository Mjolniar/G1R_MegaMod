-- ============================================================================
-- Offline tests of modules/repopulate/Scripts/world.lua: the list of actors in
-- play, kept from the game's begin / end of play calls.
--
--   lua5.4 test_world.lua          (from any directory)
--
-- Every case loads util.lua and world.lua afresh against a few stand-ins for
-- UE4SS (the two hook registrations, StaticFindObject) and a clock of its own.
-- Last line: "world tests finished: N ok, M failure(s)".
-- ============================================================================
local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local SRC = os.getenv("G1R_REPOP_SRC") or (HERE .. "../../../modules/repopulate/Scripts/")

local oks, fails = 0, 0
local function check(condition, text)
    if condition then
        oks = oks + 1
        io.write("ok   ", text, "\n")
    else
        fails = fails + 1
        io.write("FAIL ", text, "\n")
    end
    return condition
end
local function section(text) io.write("== ", text, "\n") end

-- ---------------------------------------------------------------------------
-- Stand-ins
-- ---------------------------------------------------------------------------
local IO, ST = "/Script/G1R.InteractiveObjectActor", "/Script/G1R.GothicCharacterState"
local NOW = 1000.0
local LOGS, NOTES, LOOKUPS, REG, HOOK, PATHS = {}, {}, {}, {}, {}, {}
local ASKED = { get = 0, isA = 0, other = 0 }
os.clock = function() return NOW end
_G.print = function(text) LOGS[#LOGS + 1] = tostring(text) end
_G.FindAllOf = function() return nil end
_G.FindFirstOf = function() return nil end

local nextAddress = 100
-- An object as UE4SS hands it out. fields: class (what IsA answers yes to), address / name (false = cannot be told), valid.
local function obj(name, fields)
    fields = fields or {}
    nextAddress = nextAddress + 1
    local o = { __name = name, __class = fields.class, __address = nextAddress, __valid = fields.valid ~= false, __asked = {} }
    if fields.address ~= nil then o.__address = fields.address or nil end
    if fields.name == false then o.__name = nil end
    function o.IsValid(self) return self.__valid end
    function o.GetFullName(self) self.__asked[#self.__asked + 1] = "GetFullName"; return self.__name end
    function o.GetAddress(self) return self.__address end
    function o.IsA(self, class)
        ASKED.isA = ASKED.isA + 1
        self.__asked[#self.__asked + 1] = "IsA"
        return class ~= nil and self.__class == class
    end
    return o
end
local IOClass, StateClass = obj("Class " .. IO), obj("Class " .. ST)
local function container(n, fields)
    fields = fields or {}
    fields.class = IOClass
    return obj("Interactive_Chest_C /Game/Map.Chest_" .. n, fields)
end
local function state(n, fields)
    fields = fields or {}
    fields.class = StateClass
    return obj("GothicCharacterState /Game/Map.State_" .. n, fields)
end
local function param(o)
    return { get = function()
        ASKED.get = ASKED.get + 1
        return o
    end }
end
local FAKE = {
    note = function(key, value, detail) NOTES[#NOTES + 1] = { key = key, value = value, detail = detail } end,
    crumb = function() end, op = function() return nil end, done = function() end,
}
local function lastNote() return NOTES[#NOTES] or {} end
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function logged(plain)
    local n = 0
    for _, l in ipairs(LOGS) do if l:find(plain, 1, true) then n = n + 1 end end
    return n
end

-- A fresh util.lua and world.lua. options: hooks = "none" | "no begin" | "no end" | "begin raises" | "end raises",
-- noContainerClass, noStateClass, noDiag, noInit.
local function fresh(options)
    options = options or {}
    NOW = 1000.0
    LOGS, NOTES, LOOKUPS, REG, HOOK = {}, {}, {}, { began = 0, ended = 0 }, {}
    ASKED = { get = 0, isA = 0, other = 0 }
    PATHS = { [IO] = (not options.noContainerClass) and IOClass or nil, [ST] = (not options.noStateClass) and StateClass or nil }
    _G.StaticFindObject = function(path)
        LOOKUPS[#LOOKUPS + 1] = path
        return PATHS[path] or obj("None", { valid = false })
    end
    _G.G1R_DIAG = (not options.noDiag) and FAKE or nil
    local hooks = options.hooks
    _G.RegisterBeginPlayPostHook, _G.RegisterEndPlayPreHook = nil, nil
    if hooks ~= "none" and hooks ~= "no begin" then
        _G.RegisterBeginPlayPostHook = function(f)
            if hooks == "begin raises" then error("the begin hook was refused", 0) end
            REG.began = REG.began + 1
            HOOK.began = f
        end
    end
    if hooks ~= "none" and hooks ~= "no end" then
        _G.RegisterEndPlayPreHook = function(f)
            if hooks == "end raises" then error("the end hook was refused", 0) end
            REG.ended = REG.ended + 1
            HOOK.ended = f
        end
    end
    local U = dofile(SRC .. "util.lua")
    local W = dofile(SRC .. "world.lua")
    _G.G1R_DIAG = nil
    if not options.noInit then W.init(U) end
    return W, U
end
local function begins(o) HOOK.began(param(o)) end
local function ends(o) HOOK.ended(param(o), param(0)) end
-- what a listener (chests.lua) is told, in order
local function listener()
    local heard = {}
    return heard, {
        began = function(entry) heard[#heard + 1] = { "began", entry } end,
        ended = function(entry) heard[#heard + 1] = { "ended", entry, entry.gone, entry.o } end,
    }
end

-- ---------------------------------------------------------------------------
section("1. registering the hooks")
do
    local W, U = fresh()
    check(REG.began == 1 and REG.ended == 1 and #LOOKUPS == 0 and #NOTES == 0, "one hook for begins and one for ends of play; nothing is searched for, nothing noted yet")
    W.init(U)
    W.init(U)
    check(REG.began == 1 and REG.ended == 1, "asked again: nothing is registered twice")
    check(W.active() == false and W.containersActive() == false and W.statesActive() == false and W.stats().active == false and W.stats().broken == nil,
        "no map load seen yet: the list is not in use")
    check(W.statusLine() == "objects in play: followed from the next map load on (the mod was started in a running game)", "the status says so: " .. W.statusLine())
    check(type(W.paths) == "table" and W.paths[1] == IO and W.paths[2] == ST and #W.paths == 2, "the two class paths are there for the mod's look-up at the first map load")

    local NONE = "this UE4SS build has no begin / end of play hooks"
    for _, how in ipairs({ "none", "no begin", "no end" }) do
        W = fresh({ hooks = how })
        check(W.stats().broken == NONE and REG.began == 0 and REG.ended == 0 and W.active() == false and lastNote().key == "core.play_hooks"
            and lastNote().value == "not available" and lastNote().detail == NONE and #NOTES == 1,
            "a UE4SS without the hooks (" .. how .. "): not available, said once, the other hook is not registered either")
        check(W.statusLine() == "objects in play: not followed (" .. NONE .. ")" and W.calm(NOW) == true, "status, and nothing is known about objects leaving play: " .. W.statusLine())
        W.reset()
        W.check()
        check(#LOOKUPS == 0 and #NOTES == 1 and W.active() == false, "a map load and a session start change nothing; the classes are not looked up")
    end
    W = fresh({ hooks = "end raises" })
    check(W.stats().broken == "the hooks could not be registered (the end hook was refused)" and REG.began == 0 and lastNote().value == "not available"
        and lastNote().detail == W.stats().broken, "the hook for ends of play is refused: not available, with the reason; the other hook is not asked for")
    W = fresh({ hooks = "begin raises" })
    check(W.stats().broken == "the hooks could not be registered (the begin hook was refused)" and REG.ended == 1 and lastNote().detail == W.stats().broken,
        "the hook for begins of play is refused: not available, with its reason")
    W = fresh({ noDiag = true })
    W.reset()
    begins(container(1))
    W.check()
    W.distrust("x")
    check(#NOTES == 0 and W.stats().broken == "x", "without the megamod's diagnostics nothing is noted, and nothing raises")
end

-- ---------------------------------------------------------------------------
section("2. before the first map load: counted, not followed")
do
    local W = fresh()
    local heard, l = listener()
    W.listen(l)
    begins(container(1))
    begins(state(1))
    begins(obj("Actor /Game/Map.Actor_1"))
    local s = W.stats()
    check(s.begin == 3 and s.finish == 0 and s.containers == 0 and s.states == 0 and s.errors == 0 and s.missed == 0, "three begins of play are counted")
    check(count(W.containers()) == 0 and W.stateCount() == 0 and #heard == 0 and ASKED.get == 0 and ASKED.isA == 0, "none is followed, none is asked anything")
    check(W.active() == false, "the list is not in use")
    ends(obj("Actor /Game/Map.Actor_2"))
    check(W.stats().finish == 1 and ASKED.get == 0, "an end of play is counted; the actor is not asked for")
    W.check()
    check(lastNote().value == "waiting for a map load" and W.stats().broken == nil and #NOTES == 1, "a session start: noted that the list waits for a map load; nothing is given up")
    W.check()
    check(#NOTES == 1, "noted once")
end

-- ---------------------------------------------------------------------------
section("3. the first map load: the classes, then every begin and end of play")
do
    local W, U = fresh()
    local heard, l = listener()
    W.listen(l)
    begins(container(0))
    ends(container(0))
    U.quiet(30, NOW)            -- (searches among all objects are held back right now)
    W.reset()
    check(#LOOKUPS == 2 and LOOKUPS[1] == IO and LOOKUPS[2] == ST, "the two classes are looked up at the first map load, each once - also while searches are held back")
    check(W.stats().begin == 0 and W.stats().finish == 0, "what was counted before is dropped: the list knows this world only")
    check(W.active() == false and W.statusLine() == "objects in play: no begin of play call seen yet", "no begin of play yet: not in use (" .. W.statusLine() .. ")")
    local A, S, X = container(1), state(1), obj("Actor /Game/Map.Actor_1")
    begins(A)
    check(W.active() == true and W.containersActive() == true and W.statesActive() == true and W.stats().active == true, "the first begin of play: in use")
    local entry = W.containers()[A:GetAddress()]
    check(entry ~= nil and entry.o == A and entry.full == "Interactive_Chest_C /Game/Map.Chest_1" and entry.addr == A:GetAddress() and entry.gone == nil
        and count(W.containers()) == 1, "an interactive object that begins play is kept: the object, its full name, its address")
    check(#heard == 1 and heard[1][1] == "began" and heard[1][2] == entry, "the listener is told")
    begins(S)
    check(W.states()[S:GetAddress()] == S and W.stateCount() == 1 and #heard == 1, "a character state that begins play is kept (the listener hears of containers only)")
    local isA = ASKED.isA
    begins(X)
    check(count(W.containers()) == 1 and W.stateCount() == 1 and ASKED.isA == isA + 2 and #X.__asked == 2, "an actor of another kind: two questions about its class, nothing else, nothing kept")
    isA = ASKED.isA
    begins(obj("Actor /Game/Map.Dead", { valid = false, class = IOClass }))
    check(count(W.containers()) == 1 and ASKED.isA == isA, "an object that is not valid is not asked anything")
    local B, S2 = container(2), state(2)
    begins(B)
    begins(S2)
    local s = W.stats()
    check(s.begin == 6 and s.containers == 2 and s.states == 2 and s.finish == 0 and s.errors == 0 and count(W.containers()) == 2 and W.stateCount() == 2,
        "counted: 6 begins, 2 containers, 2 states")
    check(W.statusLine() == "objects in play: 2 interactive objects, 2 character states (the game announced 6 begins and 0 ends of play)", "status: " .. W.statusLine())
    -- objects that cannot be kept
    begins(container(3, { address = false }))
    begins(container(4, { name = false }))
    begins(state(3, { address = false }))
    check(count(W.containers()) == 2 and W.stateCount() == 2 and #heard == 2 and W.stats().errors == 0 and W.stats().containers == 2 and W.stats().states == 2,
        "a container whose address or whose name cannot be told, a state without an address: not kept, no error")

    -- ends of play
    local gets = ASKED.get
    local entryB = W.containers()[B:GetAddress()]
    B.__asked = {}
    ends(B)
    check(W.containers()[B:GetAddress()] == nil and count(W.containers()) == 1 and entryB.gone == true and entryB.o == nil and ASKED.get == gets + 1,
        "a container ends play: taken off the list, its entry marked gone and emptied")
    check(#heard == 3 and heard[3][1] == "ended" and heard[3][2] == entryB and heard[3][3] == true and heard[3][4] == nil and #B.__asked == 0,
        "the listener is told, with the entry already emptied; nothing of the object is read (its address is the wrapper's own)")
    check(W.stateEnded(S:GetAddress()) == false, "(a state in play has not left it)")
    ends(S)
    check(W.states()[S:GetAddress()] == nil and W.stateCount() == 1 and W.stateEnded(S:GetAddress()) == true and W.stateEnded(424242) == false and #heard == 3,
        "a state ends play: taken off the list, and remembered as one that has left play at that address")
    ends(X)
    ends(obj("Actor /Game/Map.Actor_9"))
    check(count(W.containers()) == 1 and W.stateCount() == 1 and W.stats().finish == 4 and W.stats().errors == 0, "ends of play of actors that are not kept change nothing; all four are counted")
    local S3 = state(5, { address = S:GetAddress() })
    begins(S3)
    check(W.states()[S:GetAddress()] == S3 and W.stateEnded(S:GetAddress()) == false, "a state that begins play at the address of one that left: kept, and that address is no longer one a state has left")

    -- a container begins play at the address of a kept one whose end of play was not announced
    local entryA = W.containers()[A:GetAddress()]
    local A2 = container(6, { address = A:GetAddress() })
    local before = #heard
    begins(A2)
    local entryA2 = W.containers()[A:GetAddress()]
    check(entryA2 ~= entryA and entryA2.o == A2 and entryA2.full == "Interactive_Chest_C /Game/Map.Chest_6" and entryA.gone == true and entryA.o == nil and count(W.containers()) == 1,
        "a container begins play at the address of a kept one: the kept one is gone (its end of play was missed), the new one takes its place")
    check(#heard == before + 2 and heard[before + 1][1] == "ended" and heard[before + 1][2] == entryA and heard[before + 1][3] == true
        and heard[before + 2][1] == "began" and heard[before + 2][2] == entryA2, "the listener hears of the end of the old one first, then of the new one")

    -- a later map load
    W.reset()
    check(count(W.containers()) == 0 and W.stateCount() == 0 and W.stateEnded(S:GetAddress()) == false and #LOOKUPS == 2 and W.active() == true,
        "a later map load: every actor of the old world is off the list, nothing is looked up again")
    W.listen(nil)
    begins(container(7))
    ends(container(7))
    check(W.stats().errors == 0, "without a listener nothing raises")
end

-- ---------------------------------------------------------------------------
section("4. an end of play costs nothing while nothing is kept")
do
    local W = fresh()
    W.reset()
    begins(obj("Actor /Game/Map.Actor_1"))
    ends(obj("Actor /Game/Map.Actor_1"))
    check(ASKED.get == 1 and W.stats().finish == 1, "nothing kept: the actor that ends play is not even asked for (one question, for the begin)")
    local A = container(1)
    begins(A)
    local gets = ASKED.get
    ends(A)
    check(ASKED.get == gets + 1 and count(W.containers()) == 0, "only containers kept: the end of play of one is seen")
    local S = state(1)
    begins(S)
    gets = ASKED.get
    ends(S)
    check(ASKED.get == gets + 1 and W.stateCount() == 0 and W.stateEnded(S:GetAddress()) == true, "only states kept: the end of play of one is seen")
end

-- ---------------------------------------------------------------------------
section("5. the classes at the first map load")
do
    local W = fresh({ noContainerClass = true, noStateClass = true })
    W.reset()
    local NOCLASS = "the classes of the game were not found"
    check(W.stats().broken == NOCLASS and lastNote().value == "not available" and lastNote().detail == NOCLASS and #LOOKUPS == 2 and W.active() == false,
        "neither class is found: not available, said once")
    begins(container(1))
    W.reset()
    check(count(W.containers()) == 0 and #LOOKUPS == 2 and ASKED.get == 0, "nothing is followed, and a later map load does not look again")

    W = fresh({ noStateClass = true })
    W.reset()
    begins(container(1))
    begins(state(1))
    check(W.stats().broken == nil and W.containersActive() == true and W.statesActive() == false and count(W.containers()) == 1 and W.stateCount() == 0,
        "only the class of the interactive objects is found: they are followed, character states are not")
    W = fresh({ noContainerClass = true })
    W.reset()
    begins(container(1))
    begins(state(1))
    check(W.stats().broken == nil and W.containersActive() == false and W.statesActive() == true and count(W.containers()) == 0 and W.stateCount() == 1,
        "only the class of the character states is found: the other way round")
end

-- ---------------------------------------------------------------------------
section("6. errors inside the hooks, objects gone without a word, distrust")
do
    local W = fresh()
    local heard, l = listener()
    W.listen(l)
    W.reset()
    local A, S = container(1), state(1)
    begins(A)
    begins(S)
    local n = 0
    local function broken()
        return { get = function()
            n = n + 1
            error("boom " .. n, 0)
        end }
    end
    local out = true
    for i = 1, 19 do
        local ok = pcall(i % 2 == 0 and HOOK.began or HOOK.ended, broken())
        if not ok then out = false end
    end
    check(out and W.stats().errors == 19 and W.stats().broken == nil and W.active() == true and count(W.containers()) == 1 and W.stateCount() == 1,
        "19 errors inside the hooks: none gets out to the game, each is counted, the list stays in use")
    check(pcall(HOOK.began, broken()) and W.stats().errors == 20, "(the twentieth)")
    local WHY = "errors inside the hooks, first: boom 1"
    check(W.stats().broken == WHY and W.active() == false and count(W.containers()) == 0 and W.stateCount() == 0 and W.stateEnded(S:GetAddress()) == false,
        "at 20 the hooks are given up: the reason names the first error, the list is emptied")
    check(lastNote().value == "not used" and lastNote().detail == WHY
        and logged("[G1R_Repopulate] the game's begin / end of play calls are not used any more (" .. WHY .. "); objects are found and checked the old way") == 1,
        "noted and logged, once")
    local gets, counted = ASKED.get, W.stats()
    begins(container(2))
    ends(A)
    check(count(W.containers()) == 0 and ASKED.get == gets and W.stats().begin == counted.begin + 1 and W.stats().finish == counted.finish + 1
        and W.statusLine() == "objects in play: not followed (" .. WHY .. ")", "from then on begins and ends are counted and nothing else: " .. W.statusLine())
    for _ = 1, 30 do ends(obj("Actor /Game/Map.X")) end
    check(W.calm(NOW) == true, "and nothing is said about objects leaving play any more")
    W.distrust("another reason")
    W.check()
    check(W.stats().broken == WHY and logged("are not used any more") == 1 and #NOTES == 1, "given up once: a later reason or a session start changes nothing")

    W = fresh()
    W.reset()
    begins(container(1))
    for _ = 1, 19 do W.missed() end
    check(W.stats().missed == 19 and W.stats().broken == nil and W.active() == true, "19 kept objects found gone without an end of play: counted, the list stays in use")
    W.missed()
    check(W.stats().broken == "20 kept objects were gone without the game having said so" and W.active() == false and count(W.containers()) == 0
        and lastNote().value == "not used", "the twentieth: the game's calls are not relied on any more")

    W = fresh()
    W.reset()
    begins(state(1))
    W.distrust("12 of 40 character states were never announced")
    check(W.stats().broken == "12 of 40 character states were never announced" and W.stateCount() == 0 and W.statesActive() == false and lastNote().detail == W.stats().broken,
        "distrust (the creature count compares the list with a search): given up with that reason")
end

-- ---------------------------------------------------------------------------
section("7. the check at a session start")
do
    local W = fresh()
    W.reset()
    W.check()
    check(W.stats().broken == "no begin of play call arrived" and lastNote().value == "not used", "a session starts after a map load and no actor has begun play: the calls do not arrive - given up")

    W = fresh()
    W.reset()
    begins(obj("Actor /Game/Map.Hero"))
    W.check()
    check(W.stats().broken == nil and lastNote().value == "in use" and #NOTES == 1, "one begin of play: in use")
    W.check()
    check(#NOTES == 1, "noted once")

    -- the first world: nothing can be said about ends of play
    W = fresh()
    W.reset()
    for i = 1, 500 do begins(obj("Actor /Game/Map.Actor_" .. i)) end
    W.check()
    check(W.stats().broken == nil and lastNote().value == "in use", "500 begins and no end of play in the first world: in use (no actor may have left it yet)")

    -- a world is unloaded: its actors end play
    local function second(beginsBefore, endsBefore, endsAfter, beginsAfter)
        W = fresh()
        W.reset()
        for i = 1, beginsBefore do begins(obj("Actor /Game/Map.Actor_" .. i)) end
        for i = 1, endsBefore do ends(obj("Actor /Game/Map.Actor_" .. i)) end
        W.check()
        W.reset()
        for i = 1, endsAfter do ends(obj("Actor /Game/Map.Actor_" .. i)) end
        for i = 1, beginsAfter do begins(obj("Actor /Game/Map2.Actor_" .. i)) end
        W.check()
        return W.stats().broken
    end
    check(second(200, 0, 0, 5) == "no end of play call arrived" and lastNote().value == "not used",
        "a world in which 200 actors had begun play is unloaded and not one end of play arrives: the calls are not relied on any more")
    check(second(199, 0, 0, 5) == nil and lastNote().value == "in use", "199: too few to say")
    check(second(200, 0, 1, 5) == nil, "one end of play after the map load began: they arrive - in use")
    check(second(200, 3, 0, 5) == "no end of play call arrived", "ends of play counted before the map load say nothing about it")
    check(second(200, 0, 200, 0) == "no begin of play call arrived", "the new world: no actor has begun play in it - given up, however many began in the old one")
    check(second(0, 0, 0, 1) == "no begin of play call arrived", "(the first session start already found no begin of play)")
    -- what counts is the world that was unloaded, not everything since the game was started
    W = fresh()
    W.reset()
    for i = 1, 100 do begins(obj("Actor /Game/Map.Actor_" .. i)) end
    W.check()
    W.reset()
    for i = 1, 100 do ends(obj("Actor /Game/Map.Actor_" .. i)) end
    for i = 1, 150 do begins(obj("Actor /Game/Map2.Actor_" .. i)) end
    W.check()
    W.reset()
    begins(obj("Actor /Game/Map3.Hero"))
    W.check()
    check(W.stats().broken == nil and W.stats().begin == 251, "a third world after one of 150 actors (251 begins since the start), no end of play heard at its unloading: too few to say")
    W.reset()
    for i = 1, 200 do begins(obj("Actor /Game/Map4.Actor_" .. i)) end
    W.check()
    W.reset()
    begins(obj("Actor /Game/Map5.Hero"))
    W.check()
    check(W.stats().broken == "no end of play call arrived", "after a world of 200: said")
end

-- ---------------------------------------------------------------------------
section("8. calm: no search among all objects while the game takes many objects out of play")
do
    local function world()
        local W = fresh()
        W.reset()
        return W
    end
    local function leave(n, at)
        NOW = at
        for _ = 1, n do ends(obj("Actor /Game/Map.Leaving")) end
    end
    local W = world()
    check(W.calm(NOW) == true and W.calm() == true, "no end of play yet: calm")
    leave(9, 1000.0)
    check(W.calm(1000.0) == true, "9 actors leave play within a moment: calm")
    leave(1, 1000.0)
    check(W.calm(1000.0) == false, "the tenth: not calm")
    NOW = 2000.0
    check(W.calm(1001.9) == false and W.calm(1003.9) == false, "that holds for the two seconds they are counted in, and the two after")
    check(W.calm(1004.0) == true, "four seconds after the first of them: calm again (the time given counts, not the clock)")
    NOW = 1003.0
    local okCall, answer = pcall(W.calm)
    check(okCall and answer == false, "asked without a time: the clock's")
    NOW = 1004.0
    okCall, answer = pcall(W.calm)
    check(okCall and answer == true, "the same, later")

    -- the next two seconds are counted together with the two before
    W = world()
    leave(10, 1000.0)
    leave(1, 1002.5)
    local okA, a = pcall(W.calm, 1003.0)
    check(okA and a == false and W.calm(1004.4) == false, "one more two and a half seconds later: counted with the ten before - not calm")
    check(W.calm(1004.5) == true, "two seconds after it: the ten are no longer counted - calm")
    W = world()
    leave(10, 1000.0)
    leave(9, 1002.5)
    check(W.calm(1004.5) == true and W.calm(1004.4) == false, "nine in the later two seconds: calm once the earlier ten are no longer counted")
    -- a gap of four seconds: the earlier ones are forgotten
    W = world()
    leave(10, 1000.0)
    leave(1, 1004.0)
    check(W.calm(1004.0) == true, "four seconds without an end of play: what left before is no longer counted")
    W = world()
    leave(10, 1000.0)
    leave(9, 1004.0)
    check(W.calm(1004.0) == true, "nine after such a gap: calm")
    leave(1, 1004.1)
    check(W.calm(1004.1) == false, "ten: not calm")
    -- where a span of two seconds ends
    W = world()
    leave(5, 1000.0)
    leave(5, 1002.0)
    leave(4, 1003.0)
    check(W.calm(1003.0) == false and W.calm(1004.5) == true, "5, then 5 exactly two seconds later, then 4: the second five begin a new span (14 counted at first, 9 once the first five are out)")

    -- nothing is known without the hooks, or after they were given up
    W = world()
    leave(30, 1000.0)
    W.distrust("x")
    check(W.calm(1000.0) == true, "after the calls were given up: always calm")
    W = fresh({ hooks = "none" })
    check(W.calm(1000.0) == true, "without the hooks: always calm")
    W = fresh({ noInit = true })
    check(W.calm(1000.0) == true, "before the hooks are registered: calm")
end

io.write(("world tests finished: %d ok, %d failure(s)\n"):format(oks, fails))
os.exit(fails == 0 and 0 or 1)
