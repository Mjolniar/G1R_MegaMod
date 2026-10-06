-- G1R_Repopulate: chests and other containers slowly restock their original
-- contents (data/chests.lua, generated from the game's container
-- definitions, without quest / unique / key / map items).
--
-- Once a container is seen with items missing, it gets one roll per in-game
-- day: SettlementDailyChance (30 %) for containers in the camps and mines,
-- WildDailyChance (10 %) everywhere else. On success the missing default
-- items are put back the next time the container is loaded and you are not
-- standing at it, through the container's own inventory function
-- (DataModule_Container::Multicast_AddNewItem, the call the game itself uses
-- on the hosting side). Items you stored yourself are never touched.
--
-- Retroactive: a container that is already missing items the first time it
-- is checked (looted before the mod was installed, or while it was off) is
-- treated as emptied RetroactiveDays ago and rolls right away. Containers
-- near the player are checked every few ticks, so ones you loot while the
-- mod runs are noticed at once and follow the normal daily rolls.
--
-- What is counted: the game's own "how many of this item are in the main
-- inventory" function (HasItemMain), one call per default item. The slot
-- list is deliberately not read for that: this UE4SS build writes a debug
-- line to UE4SS.log for every read of the properties involved.
--
-- Item classes: taken from the game's own data - the default contents the
-- game keeps on the container (and on its definition). They are read once
-- per kind of container and session, and only while one of its items is
-- still unknown (a handful of debug lines in UE4SS.log each time). Nothing
-- is searched by name: in this UE4SS build a search for an object walks
-- every object in memory, and such a walk is what crashed the game on
-- 2026-10-01 (another mod's search, repeated at every lock).
--
-- Saving: the game writes a container's contents into the save only when the
-- container is opened. A restocked container you have not opened yet goes
-- back to its looted state when its part of the world is unloaded or a save
-- is loaded. The mod therefore remembers "restocked, not opened yet" and puts
-- the same items back when the container shows up again (no new roll), until
-- you open it. Container progress is kept per profile in Scripts/state/
-- (not in the save files).
--
-- Restocked items carry no owner mark of their own (the game marks some item
-- kinds when it fills a container for the first time).
--
-- Which objects are looked at: the ones the game has put into play and not
-- taken out again (world.lua: BeginPlay seen, EndPlay not seen). An object
-- that leaves play is dropped here at once, with everything kept of it; its
-- progress record in the state stays. Without those calls of the game the
-- objects are taken from UE4SS's "new object" notification and one search
-- among all objects per session, as before 1.4, and every kept object is
-- checked by its name before it is used.
local K = {}

-- Diagnostics handle of the megamod loader (nil when the mod runs on its own).
local DIAG = G1R_DIAG
local Noted = {}             -- diagnostics: the value last noted per fact
local Learn = { slots = 0 }  -- diagnostics: what the current look at a container's lists met

local U, Cfg, Defs, State, World
local DefsUpper = {}
local PendingActors = {}     -- { o = actor, full = original name, due = real time, tries = n, reg = entry of world.lua or nil }
local PendingIndex = 1
local Tracked = {}           -- key -> { actor, key, name, def, x, y, z, checked, failed, reg }
local TrackedList = {}
local ByEntry = {}           -- entry of world.lua -> tracked record (what to drop when the object leaves play)
local Generation = 0         -- counts K.reset: an entry of world.lua is queued once per generation
local RoundRobin = 1
local NearList, NearIdx, LastNearReal = {}, 1, -1e9
local InitialScan, InitialDone = false, false
local ClassCache = {}        -- item name -> class object, from the game's container data
local ItemNames, ItemUpper = {}, {}   -- item names used in data/chests.lua (exact / upper case -> exact)
local Learned = {}           -- container definition -> true once its default contents were read for classes
local Relearned = {}         -- container definition -> times read again after a class object went away
local LeftOut, LeftOutLogged = {}, 0   -- items the game's lists did not hold (said once each, the first five)
local Failed = {}            -- container key -> true: putting items in did not work in this run (not tried again)
local LastRollReal = -1e9
local LastReportReal, LastReportSig = -1e9, nil
local Stats = { seen = 0, refilled = 0, items = 0, failed = 0, depleted = 0, retro = 0, restored = 0, unreadable = 0, classes = 0 }

local MAX_TRIES = 6          -- looks at a new object before giving up on its definition
local FIRST_LOOK = 2.0       -- seconds after an object was created before it is looked at (old way)
local FIRST_LOOK_IN_PLAY = 0.25  -- the same for an object the game has put into play
local PER_TICK = 25          -- waiting objects inspected per update
local NEAR_REFILL = 600      -- no restocking while the player stands this close (cm)
local REPORT_SECONDS = 300

local function cfg(key, default)
    local v = Cfg[key]
    if v == nil then return default end
    return v
end
local function num(v, d)
    v = tonumber(v)
    if v == nil or v ~= v then return d end
    return v
end

function K.init(u, config, defs, state, world)
    U, Cfg, Defs, State = u, config or {}, defs or {}, state
    if world ~= nil then World = world end
    -- (settings were read again: what is in play is gone through once more - plain Lua,
    -- and what is queued or known already is passed over)
    if World ~= nil and World.containersActive() then InitialScan = false end
    DefsUpper = {}
    ItemNames, ItemUpper = {}, {}
    local n = 0
    for name, d in pairs(Defs) do
        n = n + 1
        DefsUpper[name:upper()] = name
        for _, it in ipairs(d.i or {}) do
            ItemNames[it[1]] = true
            ItemUpper[it[1]:upper()] = it[1]
        end
    end
    return n
end

function K.reset()
    PendingActors, Tracked, TrackedList, ByEntry = {}, {}, {}, {}
    PendingIndex = 1
    Generation = Generation + 1
    RoundRobin, InitialScan, InitialDone = 1, false, false
    NearList, NearIdx, LastNearReal = {}, 1, -1e9
    LastReportSig = nil
    Learned, Relearned = {}, {}      -- class objects stay (script classes live for the whole run)
end

function K.stats() return Stats, #TrackedList end

local function inPlay() return World ~= nil and World.containersActive() end

local function enqueue(obj, due)
    -- Capture identity while the notification/discovery still owns the object.
    -- A retained wrapper can later point at a different, valid object.
    local full = U.fullName(obj)
    if not full then return end
    PendingActors[#PendingActors + 1] = { o = obj, full = full, due = due, tries = 0 }
end

-- An object the game has put into play (world.lua): queued once per generation.
local function enqueueEntry(entry, due)
    if entry.gone or entry.gen == Generation then return end
    entry.gen = Generation
    PendingActors[#PendingActors + 1] = { o = entry.o, full = entry.full, due = due, tries = 0, reg = entry }
end

-- UE4SS's "new object" notification: used while the game's own calls are not there.
function K.onNewObject(obj)
    if inPlay() then return end
    enqueue(obj, os.clock() + FIRST_LOOK)
end
-- world.lua: the game has put an interactive object into play / taken one out.
function K.onBegan(entry)
    if cfg("Enabled", true) == false then return end        -- switched off: nothing waits (see K.init)
    enqueueEntry(entry, os.clock() + FIRST_LOOK_IN_PLAY)
end
function K.onEnded(entry)
    local t = ByEntry[entry]
    if not t then return end
    ByEntry[entry] = nil
    -- nothing of the object is touched from here on; the round robin takes the record off its list
    t.gone, t.actor, t.dm, t.dmFull = true, nil, nil, nil
end

-- ---------------------------------------------------------------- item classes
-- The name used in data/chests.lua for an item class object, or nil when the
-- data does not know the item ("ItFo_Potion_Booze"; letter case and a leading
-- "U" on the object name are tolerated).
local function itemNameOf(cls)
    local token = U.objectToken(cls)
    if DIAG then Learn.token = token end
    if not token then return nil end
    if ItemNames[token] then return token end
    local real = ItemUpper[token:upper()]
    if real then return real end
    if token:sub(1, 1) == "U" then return ItemUpper[token:sub(2):upper()] end
    return nil
end
K._itemNameOf = function(cls) return itemNameOf(cls) end

-- A slot holds the item's class. Should a slot hand out an object of that
-- class instead, its class is taken.
local function asClass(o)
    if not U.valid(o) then return nil end
    local kind = U.classToken(o)             -- the class OF this object
    if kind == nil or kind:find("Class$") then return o end
    local c = U.call(o, "GetClass")
    if U.valid(c) then return c end
    return nil
end
K._asClass = function(o) return asClass(o) end
K._classes = function() return ClassCache end

-- Remembers the item classes found in one inventory of the game
-- (m_Values.Items[*].m_Slots[*].m_SlotData.m_ItemDefinition). Returns how
-- many were new. Each slot read is one debug line in UE4SS.log.
local function learnInventory(inv)
    local got = 0
    local items = U.get(U.get(inv, "m_Values"), "Items")
    if items == nil then return 0 end
    pcall(function()
        items:ForEach(function(_, e)
            local slots = U.get(U.unwrap(e), "m_Slots")
            if slots == nil then return end
            slots:ForEach(function(_, s)
                local data = U.get(U.unwrap(s), "m_SlotData")
                local cls = asClass(U.get(data, "m_ItemDefinition"))
                if cls then
                    local name = itemNameOf(cls)
                    if DIAG then
                        Learn.slots = Learn.slots + 1
                        if not name and not Learn.other then Learn.other = Learn.token end
                    end
                    if name and not ClassCache[name] then
                        ClassCache[name] = cls
                        got = got + 1
                    end
                end
            end)
        end)
    end)
    return got
end

local function anyUnknown(def)
    for _, it in ipairs(def.i) do
        if not ClassCache[it[1]] then return true end
    end
    return false
end

-- One look per kind of container and session, and only while one of its
-- items is unknown: the defaults kept on the container, then the list on its
-- definition, then what is in it right now.
local function ensureClasses(t, dm)
    if Learned[t.name] or not anyUnknown(t.def) then return end
    Learned[t.name] = true
    if DIAG then Learn.slots, Learn.other, Learn.token = 0, nil, nil end
    local got = learnInventory(U.get(dm, "m_DefaultInventory"))
    local src = nil              -- diagnostics: the first list that taught a class
    if DIAG and got > 0 then src = "default inventory" end
    if anyUnknown(t.def) then
        local def = U.call(t.actor, "GetInteractiveObjectDefinition")
        if U.valid(def) then
            got = got + learnInventory(U.get(def, "m_Inventory"))
            if DIAG and not src and got > 0 then src = "definition list" end
        end
    end
    if anyUnknown(t.def) then
        got = got + learnInventory(U.get(dm, "m_Inventory"))
        if DIAG and not src and got > 0 then src = "current contents" end
    end
    Stats.classes = Stats.classes + got
    if DIAG then
        src = src or "none"
        if src ~= Noted.classes then
            Noted.classes = src
            DIAG.note("containers.classes_source", src, ("%s: %d learned, %d slots read%s"):format(t.name, got, Learn.slots,
                (got == 0 and Learn.other) and (", e.g. " .. Learn.other .. " is not in the data") or ""))
        end
    end
end

local function classOf(t, name)
    local c = ClassCache[name]
    if c == nil then return nil end
    if U.valid(c) then return c end
    -- the class object went away (not expected): read this kind of container
    -- again next time, twice at most
    ClassCache[name] = nil
    local n = (Relearned[t.name] or 0) + 1
    Relearned[t.name] = n
    if n <= 2 then Learned[t.name] = nil end
    return nil
end

-- The container definition of an interactive object, by the name of its
-- class ("IO_NC_CHEST_..."). The game keeps the definition as a class on the
-- actor and hands out the object through its own getter; the runtime copy on
-- the interactive component is the second source.
local function definitionName(actor)
    local def = U.call(actor, "GetInteractiveObjectDefinition")
    if U.valid(def) then
        local n = U.classToken(def)
        if n then return n, "getter" end
    end
    local comp = U.get(actor, "m_InteractiveComponent")
    if U.valid(comp) then
        local item = U.get(comp, "m_InteractItem")
        if U.valid(item) then return U.classToken(item), "component" end
    end
    return nil
end

-- The game's function library for data modules: looked up when the mod
-- starts, else searched for once per run at most (util.lua, findOnce), and
-- only when the object's own module list did not help.
local function library()
    return (U.findOnce("/Script/G1R.Default__DataModuleLibrary"))
end

-- The container module of a tracked object: from the object's own module
-- list, else through the game's library function. Kept while it is valid.
local function dataModule(t)
    if U.valid(t.dm) and U.fullName(t.dm) == t.dmFull then return t.dm end
    t.dm, t.dmFull = nil, nil
    local comp = U.get(t.actor, "m_DataModuleComponent")
    local mods = U.get(comp, "m_DataModules")
    local found = nil
    if mods ~= nil then
        pcall(function()
            mods:ForEach(function(_, e)
                if found then return true end
                local m = U.unwrap(e)
                local kind = U.classToken(m)
                if kind and kind:find("DataModule_Container", 1, true) and U.valid(m) then found = m end
            end)
        end)
    end
    if not found then
        local dm = U.call(library(), "GetContainerDataModule", t.actor)
        if U.valid(dm) then
            found = dm
            if DIAG and Noted.module ~= "library" then
                Noted.module = "library"
                DIAG.note("containers.data_module_source", "library", t.name)
            end
        end
    elseif DIAG and Noted.module ~= "module list" then
        Noted.module = "module list"
        DIAG.note("containers.data_module_source", "module list", t.name)
    end
    if found then t.dm, t.dmFull = found, U.fullName(found) end
    return found
end

-- A wrapper is a pointer: IsValid() is also true when another object that Lua
-- knows has taken the place of the one that was tracked (objects that are
-- unloaded free their memory, and the next object often gets it). The full
-- name tells the tracked object from a newcomer; without this check the items
-- of one container could be put into another.
local function alive(t)
    if t.gone or t.actor == nil then return false end       -- the game took it out of play (world.lua)
    return U.valid(t.actor) and U.fullName(t.actor) == t.full
end

-- How many of one item are in the container's main inventory; nil when the
-- game's function cannot be called.
local function countForm(form, detail)      -- diagnostics only: noted when it changes
    Noted.count = form
    DIAG.note("containers.count_form", form, detail)
end
local function countOne(dm, cls, upTo)
    local out = {}
    if not U.valid(cls) then return nil end
    local ok, has = U.try(dm, "HasItemMain", cls, 1, out)
    if not ok then
        if DIAG and Noted.count ~= "call failed" then countForm("call failed", tostring(has)) end
        return nil
    end
    local n = out.hasItemCount
    if type(n) ~= "number" then
        n = U.num(U.unwrap(n))
        if DIAG and type(n) == "number" and Noted.count ~= "wrapped count" then countForm("wrapped count") end
    elseif DIAG and Noted.count ~= "count" then
        countForm("count")
    end
    if type(n) == "number" then return math.floor(n) end
    -- the count did not come back: only yes / no is available
    if DIAG and Noted.count ~= "yes-no only" then countForm("yes-no only") end
    if has ~= true then return 0 end
    local function atLeast(k)
        local o2 = {}
        if not U.valid(cls) then return nil end
        local ok2, r = U.try(dm, "HasItemMain", cls, k, o2)
        if not ok2 then return nil end
        return r == true
    end
    local enough = atLeast(upTo)
    if enough == nil then return nil end
    if enough then return upTo end
    local lo, hi = 1, upTo
    while hi - lo > 1 do
        local mid = (lo + hi) // 2
        local present = atLeast(mid)
        if present == nil then return nil end
        if present then lo = mid else hi = mid end
    end
    return lo
end
K._countOne = function(dm, cls, upTo) return countOne(dm, cls, upTo) end

-- Default items the container is short of: { name, class, missing }.
-- Second result: total missing. nil, "count" when the container cannot be
-- counted; nil, "classes" when none of its item classes is known.
local function deficits(entry, dm)
    ensureClasses(entry, dm)
    local list, total, known, unknown = {}, 0, 0, nil
    for _, it in ipairs(entry.def.i) do
        local name, want = it[1], it[2]
        local cls = classOf(entry, name)
        if cls then
            known = known + 1
            local have = countOne(dm, cls, want)
            if have == nil then return nil, "count" end
            if have < want then
                list[#list + 1] = { name, cls, want - have }
                total = total + (want - have)
            end
        elseif not LeftOut[name] then
            unknown = unknown or {}
            unknown[#unknown + 1] = name
        end
    end
    if known == 0 and #entry.def.i > 0 then return nil, "classes" end
    if unknown and Learned[entry.name] then
        -- the game's list for this container does not hold the item: say so
        -- (the first few), then leave it out
        for _, name in ipairs(unknown) do
            LeftOut[name] = true
            LeftOutLogged = LeftOutLogged + 1
            if LeftOutLogged <= 5 then
                U.log(("containers: %s is not in the game's list for %s; it is left out of restocking%s")
                    :format(name, entry.name, LeftOutLogged == 5 and " (further ones are not listed)" or ""))
            end
        end
    end
    return list, total
end

-- Puts the listed items in; returns how many are verifiably there afterwards
-- (counted again) and how many are still missing.
local function refill(entry, dm, list, missing)
    for _, d in ipairs(list) do
        local ok, err = U.try(dm, "Multicast_AddNewItem", 1, d[2], d[3], {}, false)
        if not ok then
            U.logError("add:" .. tostring(err), "Could not add items to a container: " .. tostring(err))
        end
    end
    local again, left = deficits(entry, dm)
    if again == nil then left = missing end
    return missing - left, left
end

-- diagnostics only: how putting items in went, noted when it changes
local function noteRefill(which, key, t, added, left, missing)
    local res = (added > 0 and left == 0) and "complete" or (added > 0 and "partial" or "nothing arrived")
    if res == Noted[which] then return end
    Noted[which] = res
    DIAG.note(key, res, ("%s: %d of %d"):format(t.name, added, missing))
end

-- true: registered or not a container; false: definition not available yet
local function track(actor, expectedFull, reg)
    if reg and reg.gone then return true end                 -- it left play while it waited: nothing of it is touched
    if not U.valid(actor) then
        if reg and World then World.missed() end             -- gone, and the game did not say so
        return true
    end
    -- Reject reuse before resolving any actor method or container definition.
    -- Names are a Lua-level mitigation, not an index/serial weak handle.
    if not expectedFull or U.fullName(actor) ~= expectedFull then return true end
    Stats.seen = Stats.seen + 1
    local name, source = definitionName(actor)
    if not name then return false end
    local d = Defs[name]
    if not d then
        local real = DefsUpper[name:upper()]
        if real then name, d = real, Defs[real] end
    end
    if not d then return true end
    if d.k == "loot" and cfg("IncludeLootObjects", true) == false then return true end
    local x, y, z = U.vec3(U.call(actor, "K2_GetActorLocation"))
    -- not placed yet: an object that is still being loaded reports the world
    -- origin, and its position is part of the key its progress is kept under
    if not x or (x == 0 and y == 0 and z == 0) then return false end
    local full = U.fullName(actor)
    if not full then return false end
    local key = ("%s@%d,%d"):format(name, math.floor(x / 100 + 0.5), math.floor(y / 100 + 0.5))
    -- a new object is a new entry (what was known about an earlier object at
    -- this place does not carry over; its record in the state does)
    local t = { actor = actor, full = full, key = key, name = name, def = d, x = x, y = y, z = z, checked = false,
                failed = Failed[key] == true, reg = reg }
    -- the container module is created when the object is registered in the
    -- world; until then the object is looked at again later
    if not dataModule(t) then return false end
    if DIAG then
        t.src = source
        if not Noted.definition then     -- the first container recognised in this run
            Noted.definition = true
            DIAG.note("containers.definition_source", source, name)
        end
    end
    if not Tracked[key] then TrackedList[#TrackedList + 1] = key end
    Tracked[key] = t
    if reg then ByEntry[reg] = t end
    return true
end

local function chanceFor(d)
    local c
    if d.s then c = num(cfg("SettlementDailyChance", 0.30), 0.30)
    else c = num(cfg("WildDailyChance", 0.10), 0.10) end
    if c < 0 then c = 0 elseif c > 1 then c = 1 end
    return c
end

local function tooClose(t, px, py)
    return px ~= nil and U.dist2(t.x, t.y, px, py) < NEAR_REFILL * NEAR_REFILL
end

-- One container check: notice when it was emptied, restock when a roll won,
-- put a restock back that the game has not saved yet.
local function check(t, now, px, py)
    if t.failed then return end
    local dm = dataModule(t)
    if not dm then
        -- it had one when it was registered here: the object is on its way out
        t.noModule = (t.noModule or 0) + 1
        if t.noModule >= 3 then t.failed = true end
        return
    end
    t.noModule = nil
    local list, missing = deficits(t, dm)
    if list == nil then
        t.failed = true
        Stats.unreadable = Stats.unreadable + 1
        if missing == "classes" then
            U.logOnce("noclasses", "containers: the item classes of " .. t.name .. " cannot be read from the game's data; containers like it are left alone")
        else
            U.logOnce("unreadable", "containers: the contents of " .. t.name .. " cannot be counted; containers like it are left alone")
        end
        return
    end
    local first = not t.checked
    t.checked = true
    local rec = State.chests[t.key]
    if missing == 0 then
        -- complete. A "restocked, not opened yet" note stays while this is
        -- the container the items were put into; a container that shows up
        -- complete has been saved by the game since.
        t.restore = nil
        if rec and (first or not rec.f) then State.chests[t.key] = nil; State.dirty = true end
        return
    end
    if type(rec) == "table" and rec.f then
        if first and rec.f <= now + 60 then t.restore = true end
        if t.restore then
            -- restocked earlier, never opened since: the game loaded the
            -- looted contents again. Same items back, no new roll - but,
            -- as with a restock, not while you stand at it.
            if tooClose(t, px, py) then return end
            t.restore = nil
            local added, left = refill(t, dm, list, missing)
            if DIAG then noteRefill("putback", "containers.putback_result", t, added, left, missing) end
            if left == 0 then
                Stats.restored = Stats.restored + 1
                if cfg("Verbose", false) then U.log(("put back the restock of %s: %d item(s)"):format(t.name, added)) end
            else
                Stats.failed = Stats.failed + 1
                t.failed = true
                Failed[t.key] = true
                U.logError("putback:" .. t.name, ("putting the restock of %s back did not work (%d of %d item(s) arrived); it is left alone until the game is restarted")
                    :format(t.name, added, missing))
            end
            return
        end
        if first then
            rec = nil                   -- an earlier save was loaded: start over below
            State.chests[t.key] = nil
            State.dirty = true
        else
            -- seen complete before in this session: you took things again
            State.chests[t.key] = { d = now, n = now + 86400 }
            State.dirty, State.urgent = true, true
            Stats.depleted = Stats.depleted + 1
            return
        end
    end
    if not rec then
        local retro = math.floor(num(cfg("RetroactiveDays", 3), 3))
        if first and retro > 0 then
            -- emptied before the mod ever saw it: as if emptied `retro` days
            -- ago, so it rolls (with catch-up) on the next pass
            State.chests[t.key] = { d = now - retro * 86400, n = now - (retro - 1) * 86400, r = true }
            Stats.retro = Stats.retro + 1
        else
            State.chests[t.key] = { d = now, n = now + 86400 }
        end
        State.dirty = true
        Stats.depleted = Stats.depleted + 1
        if Stats.depleted == 1 then
            U.log(("containers: first emptied container noticed (%s, %d item(s) missing)"):format(t.name, missing))
        end
        return
    end
    if rec.p then
        if tooClose(t, px, py) then return end      -- not while you stand at it
        local added, left = refill(t, dm, list, missing)
        if DIAG then noteRefill("restock", "containers.restock_result", t, added, left, missing) end
        if added > 0 and left == 0 then
            Stats.refilled = Stats.refilled + 1
            Stats.items = Stats.items + added
            State.chests[t.key] = { f = now }
            State.urgent = true
            U.log(("restocked %s (%s): %d item(s)"):format(t.name, t.def.s and "settlement" or "wild", added))
        else
            -- nothing or only part of it arrived: not tried again in this run
            Stats.failed = Stats.failed + 1
            t.failed = true
            Failed[t.key] = true
            State.chests[t.key] = { d = now, n = now + 86400 }
            U.logError("restock:" .. t.name, ("restocking %s did not work (%d of %d item(s) arrived); it is left alone until the game is restarted")
                :format(t.name, added, missing))
        end
        State.dirty = true
    end
end

-- Daily rolls for every container seen with missing items (loaded or not).
local function roll(now)
    local rnd = cfg("Random", math.random)
    local maxK = math.max(1, math.floor(num(cfg("MaxCatchUpDays", 3), 3)))
    for key, rec in pairs(State.chests) do
        if type(rec) == "table" and not rec.f then
            if not rec.p and rec.n and now >= rec.n then
                local k = math.min(maxK, 1 + math.floor((now - rec.n) / 86400))
                rec.n = rec.n + k * 86400
                if rec.n <= now then rec.n = now + 86400 end
                local name = key:match("^(.-)@")
                local d = name and Defs[name]
                if d and rnd() < U.catchUp(chanceFor(d), k) then rec.p = true end
                State.dirty = true
            elseif rec.d and rec.d > now + 60 then
                -- an earlier save was loaded: restart this container's clock
                rec.d, rec.n = now, now + 86400
                State.dirty = true
            end
        end
    end
end

local function counts()
    local waiting, won, held = 0, 0, 0
    for _, rec in pairs(State.chests) do
        if type(rec) == "table" then
            if rec.f then held = held + 1
            else
                waiting = waiting + 1
                if rec.p then won = won + 1 end
            end
        end
    end
    return waiting, won, held
end
K.counts = counts

function K.statusLine()
    local waiting, won, held = counts()
    return ("containers: %d here (%d objects looked at), %d waiting to restock (%d won their roll), %d restocked and not opened yet; this session: %d restocked (%d items), %d put back, %d found already emptied, %d failed%s, %d item classes known")
        :format(#TrackedList, Stats.seen, waiting, won, held, Stats.refilled, Stats.items, Stats.restored, Stats.retro, Stats.failed,
            Stats.unreadable > 0 and (", %d not readable"):format(Stats.unreadable) or "", Stats.classes)
end

-- One short line in the log when the numbers changed (the console is usually off).
local function report(realNow, force)
    if not force and realNow - LastReportReal < REPORT_SECONDS then return end
    local waiting, won, held = counts()
    local sig = ("%d/%d/%d/%d/%d/%d/%d"):format(#TrackedList, waiting, won, held, Stats.refilled, Stats.restored, Stats.failed)
    if sig == LastReportSig then return end
    LastReportReal, LastReportSig = realNow, sig
    U.log(("containers: %d here, %d waiting to restock, %d restocked and not opened yet | session: %d restocked, %d put back%s")
        :format(#TrackedList, waiting, held, Stats.refilled, Stats.restored,
            Stats.failed > 0 and (", %d did not work"):format(Stats.failed) or ""))
end

function K.tick(now, realNow)
    if not now then return end
    if not InitialScan then
        if inPlay() then
            -- everything the game has in play (queued when it began play; here again after a reset of
            -- the session without a map load) - plain Lua, the game is not asked
            InitialScan = true
            for _, entry in pairs(World.containers()) do enqueueEntry(entry, realNow) end
        elseif U.mayWalk(realNow) then
            -- the old way: one search among all objects per session
            InitialScan = true
            for _, a in ipairs(U.findAll("InteractiveObjectActor")) do enqueue(a, realNow) end
        end
    end
    -- identify new containers (a moment after they were created; an object
    -- whose definition is not there yet is looked at again later)
    local inspected = 0
    local budget = math.min(PER_TICK, #PendingActors)
    local token = nil
    while #PendingActors > 0 and inspected < budget do
        if PendingIndex > #PendingActors then PendingIndex = 1 end
        local i = PendingIndex
        local p = PendingActors[i]
        inspected = inspected + 1
        if (p.reg and p.reg.gone) or realNow >= p.due then
            if token == nil then token = U.op(("containers: look at new objects (%d waiting)"):format(#PendingActors)) or false end
            local done = track(p.o, p.full, p.reg)
            if done or p.tries + 1 >= MAX_TRIES then
                -- Constant-time removal; do not shift a large streaming queue.
                PendingActors[i] = PendingActors[#PendingActors]
                PendingActors[#PendingActors] = nil
            else
                p.tries = p.tries + 1
                p.due = realNow + 2 ^ p.tries         -- 2, 4, 8, 16, 32 s
                PendingIndex = i + 1
            end
        else
            PendingIndex = i + 1
        end
    end
    if token then U.done(token) end
    if not InitialDone and InitialScan and #PendingActors == 0 then
        InitialDone = true
        if #TrackedList == 0 and Stats.seen > 0 then
            U.log(("containers: none recognised among %d objects"):format(Stats.seen))
        end
        report(realNow, true)
    end
    if realNow - LastRollReal > 5 then
        LastRollReal = realNow
        roll(now)
    end
    if #TrackedList == 0 then return end
    local px, py = U.playerPos()
    local r = num(cfg("CheckRadius", 2500), 2500)
    -- fast lane: containers around the player, one per tick
    if realNow - LastNearReal > 2 then
        LastNearReal = realNow
        NearList, NearIdx = {}, 1
        if px then
            for _, k in ipairs(TrackedList) do
                local t = Tracked[k]
                if t and U.dist2(t.x, t.y, px, py) <= r * r then NearList[#NearList + 1] = k end
            end
        end
    end
    if NearIdx <= #NearList then
        local t = Tracked[NearList[NearIdx]]
        NearIdx = NearIdx + 1
        if NearIdx > #NearList then NearIdx = 1 end
        if t and alive(t) then
            local op = U.op("containers: check " .. t.key .. " (near)")
            check(t, now, px, py)
            U.done(op)
        end
    end
    -- round robin over everything loaded: drop unloaded ones, check new or
    -- pending ones
    if RoundRobin > #TrackedList then RoundRobin = 1 end
    local key = TrackedList[RoundRobin]
    local t = Tracked[key]
    if not t or not alive(t) then
        if t then
            if t.reg then
                ByEntry[t.reg] = nil
                -- gone although the game did not take it out of play: said to world.lua
                if not t.gone and not t.reg.gone and World then World.missed() end
            end
            t.actor, t.dm = nil, nil
        end
        Tracked[key] = nil
        table.remove(TrackedList, RoundRobin)
        return
    end
    RoundRobin = RoundRobin + 1
    local near = px and U.dist2(t.x, t.y, px, py) <= r * r
    local rec = State.chests[key]
    if not t.checked or near or t.restore or (rec and rec.p) then
        local op = U.op("containers: check " .. t.key)
        check(t, now, px, py)
        U.done(op)
    end
    if InitialDone then report(realNow, false) end
end

-- A picture of the container side for the megamod's diagnostics dump: plain
-- Lua values taken from what the mod holds; the game is not touched.
function K.diag()
    local tracked, classes, leftOut, records, stats = {}, {}, {}, {}, {}
    for _, key in ipairs(TrackedList) do
        local t = Tracked[key]
        if t then
            tracked[#tracked + 1] = {
                kind = t.name, key = t.key, x = t.x, y = t.y, z = t.z,
                checked = t.checked == true, failed = t.failed == true, restore = t.restore == true,
                type = t.def and t.def.k, settlement = (t.def and t.def.s) == true, definition = t.src,
            }
        end
    end
    for name, cls in pairs(ClassCache) do
        if cls then classes[#classes + 1] = tostring(name) end
    end
    table.sort(classes)
    for name in pairs(LeftOut) do leftOut[#leftOut + 1] = tostring(name) end
    table.sort(leftOut)
    local keys = {}
    for key in pairs(State and State.chests or {}) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        local rec = State.chests[key]
        if type(rec) == "table" then
            records[#records + 1] = { key = tostring(key), d = tonumber(rec.d), n = tonumber(rec.n), f = tonumber(rec.f),
                p = rec.p == true, r = rec.r == true }
        end
    end
    for k, v in pairs(Stats) do stats[k] = v end
    return {
        tracked = tracked, item_classes = classes, left_out = leftOut, records = records, stats = stats,
        objects_waiting = #PendingActors,
    }
end

return K
