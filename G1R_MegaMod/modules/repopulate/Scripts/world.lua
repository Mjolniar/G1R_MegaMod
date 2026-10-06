-- G1R_Repopulate: which actors are in play.
--
-- The mod works with two kinds of actors that come and go while the player
-- moves through the world: interactive objects (the containers among them)
-- and the state objects of characters. An object the mod has kept in a Lua
-- variable can be gone the next time the mod looks - the game unloads parts
-- of the world all the time, faster than ever while riding - and a Lua
-- variable is only a pointer: UE4SS cannot always tell that what it points
-- at is no longer the object that was kept (dev/FACTS.md, U5, U17). Two
-- crashes of 2026-10-04 / 05 ended inside a call on such an object.
--
-- So the mod asks the engine itself. The engine calls BeginPlay for every
-- actor that enters the world and EndPlay for every actor that leaves it
-- (destroyed, its part of the world unloaded, the map changed), and UE4SS
-- passes both on. Between the two calls an actor exists and is in the world;
-- after EndPlay the mod forgets it at once and never touches it again. What
-- is kept here is the list of actors of the two kinds for which BeginPlay was
-- seen and EndPlay was not.
--
-- The hooks run for every actor of the game, so what they do for an actor
-- of another kind is two questions about its class and nothing else.
--
-- The list begins with the first map load the mod sees: every actor of the
-- new world begins play after it, so none is missed. (A mod started in a
-- running game has not seen the actors that are in play already; until the
-- next map load it works the old way.)
--
-- When this UE4SS build has no such hooks, or they turn out not to fire, the
-- rest of the mod works as it did before 1.4: objects are announced when
-- they are created, found by a search among all objects, and checked by
-- name before every use.
local W = {}

local pcall, type, next = pcall, type, next

-- Diagnostics handle of the megamod loader (nil when the mod runs on its own).
local DIAG = G1R_DIAG
local Noted = nil               -- diagnostics: the state last noted

local U
local CONTAINER_CLASS = "/Script/G1R.InteractiveObjectActor"
local STATE_CLASS = "/Script/G1R.GothicCharacterState"
W.paths = { CONTAINER_CLASS, STATE_CLASS }      -- looked up with the mod's other paths (main.lua, firstMapLoad)
local ContainerClass, StateClass = nil, nil
local Containers = {}           -- address -> { o = actor, full = full name, addr = address }
local States = {}               -- address -> state object
local StatesEnded = {}          -- address -> true: a state that was in play there has left it (this world)
local Count = { begin = 0, finish = 0, containers = 0, states = 0, errors = 0, missed = 0 }
local Listener = nil            -- { began = function(entry), ended = function(entry) } (chests.lua)
local Registered = false
local Broken = nil              -- why the hooks are not relied on any more
local MapLoads = 0              -- map loads seen; the list is kept from the first one on
local FirstError = nil

-- How many actors left play lately (two windows of CHURN_WINDOW seconds):
-- after the game has taken many objects out of play it frees them, on another
-- thread, and a search among all objects is best not run at that moment (W.calm).
local CHURN_WINDOW = 2.0
local CALM_BELOW = 10           -- fewer ends of play than this in the last windows: calm
local WindowAt, WindowCount, PrevCount = -1e9, 0, 0
local clock = os.clock

local MAX_ERRORS = 20           -- errors inside the hooks before they are given up
local MAX_MISSED = 20           -- kept actors found gone without an EndPlay before the hooks are given up
local ENOUGH = 200              -- BeginPlay calls in a world: when it is unloaded, EndPlay calls must be seen
-- What the counters stood at when the last map load began, and how many
-- actors had begun play in the world that load took away (W.check).
local Mark = { begin = 0, finish = 0, before = 0 }

local function note(value, detail)
    if not DIAG or Noted == value then return end
    Noted = value
    DIAG.note("core.play_hooks", value, detail)
end

local function giveUp(why)
    if Broken then return end
    Broken = why
    Containers, States, StatesEnded = {}, {}, {}
    U.log("the game's begin / end of play calls are not used any more (" .. why .. "); objects are found and checked the old way")
    note("not used", why)
end

-- BeginPlay of any actor (after the engine's own part of it).
local function began(context)
    Count.begin = Count.begin + 1
    if Broken or MapLoads == 0 then return end
    local actor = context:get()
    if not U.valid(actor) then return end
    if ContainerClass and actor:IsA(ContainerClass) then
        local addr, full = actor:GetAddress(), actor:GetFullName()
        if type(addr) ~= "number" or type(full) ~= "string" then return end
        local old = Containers[addr]
        if old then
            -- another actor was kept at this address and its end of play was not seen: it is gone
            old.gone, old.o = true, nil
            if Listener then Listener.ended(old) end
        end
        local entry = { o = actor, full = full, addr = addr }
        Containers[addr] = entry
        Count.containers = Count.containers + 1
        if Listener then Listener.began(entry) end
    elseif StateClass and actor:IsA(StateClass) then
        local addr = actor:GetAddress()
        if type(addr) ~= "number" then return end
        States[addr] = actor
        StatesEnded[addr] = nil
        Count.states = Count.states + 1
    end
end

-- EndPlay of any actor (before the engine's own part of it): from here on
-- the object is not the mod's to touch.
local function ended(context)
    Count.finish = Count.finish + 1
    local now = clock()
    if now - WindowAt >= CHURN_WINDOW then
        PrevCount = (now - WindowAt < 2 * CHURN_WINDOW) and WindowCount or 0
        WindowAt, WindowCount = now, 0
    end
    WindowCount = WindowCount + 1
    if Broken or (next(Containers) == nil and next(States) == nil) then return end
    local addr = context:get():GetAddress()
    local entry = Containers[addr]
    if entry then
        Containers[addr] = nil
        entry.gone, entry.o = true, nil
        if Listener then Listener.ended(entry) end
    elseif States[addr] ~= nil then
        States[addr] = nil
        StatesEnded[addr] = true
    end
end

local function guarded(f)
    return function(context)
        local ok, err = pcall(f, context)
        if ok then return end
        Count.errors = Count.errors + 1
        FirstError = FirstError or tostring(err)
        if Count.errors >= MAX_ERRORS then giveUp("errors inside the hooks, first: " .. FirstError) end
    end
end

-- Registers the hooks: once per run. Nothing is searched for here.
function W.init(util)
    U = util
    if Registered then return end
    Registered = true
    if type(RegisterBeginPlayPostHook) ~= "function" or type(RegisterEndPlayPreHook) ~= "function" then
        Broken = "this UE4SS build has no begin / end of play hooks"
        note("not available", Broken)
        return
    end
    local ok, why = pcall(RegisterEndPlayPreHook, guarded(ended))
    if ok then ok, why = pcall(RegisterBeginPlayPostHook, guarded(began)) end
    if not ok then
        Broken = "the hooks could not be registered (" .. tostring(why) .. ")"
        note("not available", Broken)
    end
end

-- True while the list of actors in play can be relied on: the hooks are
-- registered, a map load has been seen (the list is complete from there on),
-- BeginPlay calls have arrived, and nothing spoke against them.
function W.active()
    return Registered and not Broken and MapLoads > 0 and Count.begin > 0
end
-- The same for the state objects of characters (their class must be known).
function W.statesActive() return W.active() and StateClass ~= nil end
function W.containersActive() return W.active() and ContainerClass ~= nil end

-- False while the game has just taken many objects out of play (the hooks
-- must be there for that to be known; without them: always true).
function W.calm(now)
    if not Registered or Broken then return true end
    now = now or clock()
    local age = now - WindowAt
    if age >= 2 * CHURN_WINDOW then return true end
    local recent = WindowCount + (age < CHURN_WINDOW and PrevCount or 0)
    return recent < CALM_BELOW
end

function W.listen(listener) Listener = listener end
function W.containers() return Containers end
function W.states() return States end
-- True when a state that was in play at this address has left it since the map was loaded
-- (the object can still be found by a search for a while).
function W.stateEnded(addr) return StatesEnded[addr] == true end
function W.stateCount()
    local n = 0
    for _ in next, States do n = n + 1 end
    return n
end

-- A kept actor turned out to be gone although no EndPlay was seen for it.
function W.missed()
    Count.missed = Count.missed + 1
    if Count.missed >= MAX_MISSED then giveUp(Count.missed .. " kept objects were gone without the game having said so") end
end

-- Another way of knowing the objects in play contradicts the list (creatures.lua
-- compares it with a search): it is not relied on any more in this run.
function W.distrust(why) giveUp(why) end

-- A map is being loaded: every actor of the old world leaves play. At the
-- first one the two classes are looked up (the moment for it: util.lua, U.warm).
function W.reset()
    MapLoads = MapLoads + 1
    Containers, States, StatesEnded = {}, {}, {}
    if MapLoads == 1 then Count.begin, Count.finish = 0, 0 end      -- (what came before is not a world the list knows)
    Mark.before = Count.begin - Mark.begin
    Mark.begin, Mark.finish = Count.begin, Count.finish
    if MapLoads == 1 and Registered and not Broken then
        ContainerClass = U.findOnce(CONTAINER_CLASS, true)
        StateClass = U.findOnce(STATE_CLASS, true)
        if not ContainerClass and not StateClass then
            Broken = "the classes of the game were not found"
            note("not available", Broken)
        end
    end
end

-- Called when a session starts (the hero is in the world a map load has
-- brought): by now the calls must have been seen. An actor of the new world
-- has begun play - the hero at least. And when the load took a world away in
-- which many actors had begun play, each of them has ended play in it; not
-- one such call means that the game's ends of play do not reach the mod, and
-- the list would never lose an object. (In the first world nothing can be
-- said about the ends of play: an actor may or may not have left it yet.)
function W.check()
    if Broken or not Registered then return end
    if MapLoads == 0 then
        note("waiting for a map load")          -- the mod was started in a running game
    elseif Count.begin == Mark.begin then
        giveUp("no begin of play call arrived")
    elseif Mark.before >= ENOUGH and Count.finish == Mark.finish then
        giveUp("no end of play call arrived")
    else
        note("in use")
    end
end

function W.stats()
    return { begin = Count.begin, finish = Count.finish, containers = Count.containers, states = Count.states,
        errors = Count.errors, missed = Count.missed, broken = Broken, active = W.active() }
end
function W.statusLine()
    if Broken then return "objects in play: not followed (" .. Broken .. ")" end
    if MapLoads == 0 then return "objects in play: followed from the next map load on (the mod was started in a running game)" end
    if not W.active() then return "objects in play: no begin of play call seen yet" end
    local n = 0
    for _ in next, Containers do n = n + 1 end
    return ("objects in play: %d interactive objects, %d character states (the game announced %d begins and %d ends of play)")
        :format(n, W.stateCount(), Count.begin, Count.finish)
end

return W
