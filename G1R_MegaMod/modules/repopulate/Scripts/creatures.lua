-- G1R_Repopulate: creature respawning.
--
-- Each missing generic creature gets a chance to come back at its own spawn
-- point every few in-game hours: normal species NormalChance every
-- NormalEveryHours, elite species EliteChance every EliteEveryHours, and any
-- species can have its own chance / interval / on-off in Config.Species.
-- Only points from data/creature_points.lua (generated from the game's own
-- world-point scripts) are handled, and only after a census has seen that
-- point populated in this playthrough, so creatures the game has not spawned
-- yet (unvisited areas, later chapters) are never added. A point never goes
-- above its original count. When a creature comes back, the corpse of one of
-- its dead predecessors from the same spot is removed (generic creatures
-- only; humans, NPCs, named or quest creatures are never in the data).
--
-- Which objects are touched: the state objects of characters that are in
-- play (world.lua). The frequent look ("which spawn points are populated")
-- takes them from that list. The count that decides about respawns searches
-- among all objects - it has to be complete, and a search is the one way to
-- be sure of that - and touches only the states that are in play; a state
-- that leaves play while a count runs is skipped. Without the game's begin /
-- end of play calls both use the search and check every state before use, as
-- before 1.4. The script object of a spawn point is asked from the game's
-- world point manager at the moment it is needed and not kept.
local C = {}

-- Diagnostics handle of the megamod loader (nil when the mod runs on its own).
local DIAG = G1R_DIAG
local Noted = {}           -- diagnostics: the value last noted per fact

local U, Cfg, Points, State, World
local ByUnique = {}        -- unique name -> { point names }
local Intervals = {}       -- hours -> { idx = last boundary index, due = cycles to roll }
local Census = nil         -- running census job
local Queue = {}           -- spawn jobs
-- respawns being looked up (confirmStep): works = nil (not known yet) / true / false for this run
local CONFIRM_AFTER, CONFIRM_GIVE_UP, PROBES = 2, 20, 3
-- lookup: the default object of GothicNPCState (nil: not searched for yet; false: not there)
local Confirm = { works = nil, probes = 0, misses = 0, pending = {}, lookup = nil }
local Dead = {}            -- point -> unique -> { { st = state, id = its id, addr, reg } } (last full census)
local GlobalStates = nil   -- true when the census sees far-away creatures
local TokensWork = nil     -- false when creature ids carry no spawn point name
local LastSpawnReal = -1e9
local LastEvidenceReal = -1e9
local Forced = false       -- a count was asked for at the console and has not started yet
local Instances = { at = -1e9, map = {} }      -- the old way: script objects by class, from a search
local Scripts = nil        -- the manager's way: { manager = name, at = { class -> place in its list }, built = real time }
local ScriptsBroken = false -- the manager's list cannot be read: the old way is used
local StatesChecked = nil  -- real time the list of states in play was last compared with a search
local ClassCache = {}
local Stats = { cycles = 0, queued = 0, spawned = 0, failed = 0, deferred = 0, corpses = 0, corpsesKept = 0, skipped = 0,
    confirmed = 0, unconfirmed = 0 }

local SPATIAL_RADIUS = 3000      -- cm: token-less creatures count for the nearest point of their species
local EVIDENCE_RADIUS = 2000     -- cm: a living creature this close marks the point as populated
local NEAR_RADIUS = 9000         -- cm: used when only nearby creatures are visible to the census

local function cfg(key, default)
    local v = Cfg[key]
    if v == nil then return default end
    return v
end
local function numCfg(v, default)
    v = tonumber(v)
    if v == nil or v ~= v then return default end
    return v
end

-- Effective chance (0..1), interval (hours) and on/off for one species.
local function speciesParams(u, isElite, eliteSet, exclude, overrides)
    local chance, hours
    if isElite then
        chance, hours = numCfg(Cfg.EliteChance, 0.15), numCfg(Cfg.EliteEveryHours, 24)
    else
        chance, hours = numCfg(Cfg.NormalChance, 0.35), numCfg(Cfg.NormalEveryHours, 24)
    end
    local on = not exclude[u]
    local o = overrides[u]
    if type(o) == "table" then
        if o.Chance ~= nil then chance = numCfg(o.Chance, chance) end
        if o.EveryHours ~= nil then hours = numCfg(o.EveryHours, hours) end
        if o.Enabled == false then on = false elseif o.Enabled == true then on = true end
    end
    if chance < 0 then chance = 0 elseif chance > 1 then chance = 1 end
    hours = math.max(1, math.floor(hours + 0.5))
    return chance, hours, on
end

function C.init(u, config, points, state, world)
    U, Cfg, Points, State = u, config or {}, points or {}, state
    if world ~= nil then World = world end
    local exclude, eliteSet = {}, {}
    for _, s in ipairs(cfg("ExcludeSpecies", {})) do exclude[s] = true end
    for _, s in ipairs(cfg("EliteSpecies", {})) do eliteSet[s] = true end
    local overrides = type(Cfg.Species) == "table" and Cfg.Species or {}
    -- EliteSpecies decides when present (an empty list = no elites);
    -- without it the elite flags from the data apply
    local useEliteList = type(Cfg.EliteSpecies) == "table"
    ByUnique = {}
    local newIntervals = {}
    local n, c = 0, 0
    for name, p in pairs(Points) do
        n = n + 1
        for _, s in ipairs(p.s) do
            if s.e0 == nil then s.e0 = s.e end              -- elite flag from the data
            if useEliteList then s.e = eliteSet[s.u] == true else s.e = s.e0 end
            s.p, s.h, s.on = speciesParams(s.u, s.e, eliteSet, exclude, overrides)
            if s.on then
                c = c + s.n
                if not newIntervals[s.h] then
                    newIntervals[s.h] = Intervals[s.h] or { idx = nil, due = 0 }
                end
            end
            local list = ByUnique[s.u]
            if not list then list = {}; ByUnique[s.u] = list end
            if list[#list] ~= name then list[#list + 1] = name end
        end
    end
    Intervals = newIntervals
    return n, c
end

function C.reset()
    LastEvidenceReal, Forced = -1e9, false
    for _, t in pairs(Intervals) do t.idx, t.due = nil, 0 end
    Census, Queue, Dead = nil, {}, {}
    Confirm.pending = {}        -- (what a map change leaves undecided is not looked at in the new world)
    GlobalStates = nil
    Instances = { at = -1e9, map = {} }
    Scripts, StatesChecked = nil, nil
    -- ClassCache stays: script classes live for the whole run, and a class that
    -- was not found is not searched for again (in this UE4SS build every such
    -- search walks all objects in memory)
end

function C.stats() return Stats, #Queue, Census ~= nil, GlobalStates, Intervals end
-- The respawns being looked up and what is known of the lookup in this run (diagnostics, tests).
function C.confirmState() return Confirm end

-- Spawn definition and routine classes, looked up by name the first time a
-- species comes back (at most once per class and session, found or not).
local function classFor(short)
    local c = ClassCache[short]
    if c == false or (c ~= nil and U.valid(c)) then return c or nil end
    if not U.mayWalk() then return nil, "later" end      -- (a first search by name walks all objects)
    c = U.findStatic("/Script/Angelscript." .. short)
        or U.findStatic("/Script/Angelscript.U" .. short)
        or U.findStatic("/Script/G1R." .. short)
        or false
    if not c then U.logOnce("nocls:" .. short, "Class not found: " .. short) end
    if DIAG then
        -- the first lookup that found its class and the first that did not
        local outcome = c and "found" or "not found"
        if not Noted[outcome] then
            Noted[outcome] = true
            DIAG.note("creatures.class_lookup", outcome, short)
        end
    end
    ClassCache[short] = c
    return c or nil
end

-- Point id parsing. Global ids are built by the game from the creature's
-- unique name, the spawning world point and an index; accept any form that
-- contains a known point name as one or more '-'/'_' separated segments.
local function pointFromId(id)
    if not id or id == "" then return nil end
    for part in id:gmatch("[^%-]+") do
        if Points[part] then return part end
        local bare = part:gsub("^WP_", "")
        if Points[bare] then return bare end
        if Points["WP_" .. part] then return "WP_" .. part end
    end
    -- fallback: longest underscore-joined run that is a known point
    local segs = {}
    for s in id:gmatch("[^_%-]+") do segs[#segs + 1] = s end
    for len = math.min(#segs, 9), 2, -1 do
        for i = 1, #segs - len + 1 do
            local cand = table.concat(segs, "_", i, i + len - 1)
            if Points[cand] then return cand end
        end
    end
    return nil
end
C._pointFromId = pointFromId

local function bump(t, a, b, n)
    local x = t[a]
    if not x then x = {}; t[a] = x end
    x[b] = (x[b] or 0) + (n or 1)
end
local function push(t, a, b, v)
    local x = t[a]
    if not x then x = {}; t[a] = x end
    local l = x[b]
    if not l then l = {}; x[b] = l end
    l[#l + 1] = v
end

-- True while the list of character states in play (world.lua) can be used.
local function inPlay() return World ~= nil and World.statesActive() end

-- All character states, by a search among all objects (NPC states exist for
-- unspawned characters too). With the list of states in play at hand every
-- found state is paired with its entry there: { st, addr, reg = true }; a
-- state that is not in play gets no `reg` and is not touched by the count.
local function searchStates()
    local found = U.findAll("GothicCharacterState")
    if #found == 0 then
        found = U.findAll("GothicNPCState")
        if DIAG and #found > 0 and Noted.states ~= "GothicNPCState" then
            Noted.states = "GothicNPCState"
            DIAG.note("creatures.states_class", "GothicNPCState", #found)
        end
    elseif DIAG and Noted.states ~= "GothicCharacterState" then
        Noted.states = "GothicCharacterState"
        DIAG.note("creatures.states_class", "GothicCharacterState", #found)
    end
    local reg = inPlay() and World.states() or nil
    local list, there, left, never = {}, 0, 0, 0
    for i = 1, #found do
        local st = found[i]
        local addr = reg and U.address(st) or nil
        local known = addr and reg[addr] or nil
        if known ~= nil then
            list[i] = { st = known, addr = addr, reg = true }
            there = there + 1
        else
            list[i] = { st = st }
            -- not in play: it has left play (the object is still there for a while) or was never announced
            if addr and World.stateEnded(addr) then left = left + 1 else never = never + 1 end
        end
    end
    if reg then
        -- the two ways of knowing the states are compared: when the search finds
        -- many that the game never announced, its announcements are not relied on
        StatesChecked = os.clock()
        if DIAG then
            local value = ("%d found: %d in play, %d have left play, %d never announced; %d in play and not found")
                :format(#found, there, left, never, World.stateCount() - there)
            if value ~= Noted.compared then
                Noted.compared = value
                DIAG.note("creatures.states_in_play", value)
            end
        end
        if never > 10 and never * 20 > #found then
            World.distrust(("%d of %d character states were never announced"):format(never, #found))
            for i = 1, #list do list[i] = { st = found[i] } end
            return list, false
        end
    end
    return list, reg ~= nil
end

-- mode "full": count creatures and roll for missing ones (cycle boundary)
-- mode "evidence": only note which spawn points are populated (frequent,
-- cheap), so points cleared between two cycles are still known later
-- Returns false when the count cannot start now (a search is not due yet).
local function startCensus(reason, mode, realNow)
    local list, onlyInPlay
    if mode == "evidence" and inPlay() then
        -- what is in play is at hand: the game is not searched
        list, onlyInPlay = {}, true
        local n = 0
        for addr, st in pairs(World.states()) do
            n = n + 1
            list[n] = { st = st, addr = addr, reg = true }
        end
    else
        if not U.mayWalk(realNow) then return false end
        local op = U.op("creatures: search for character states (" .. reason .. ")")
        list, onlyInPlay = searchStates()
        U.done(op)
    end
    local px, py = U.playerPos()
    Census = {
        list = list, i = 1, reason = reason, mode = mode or "full", inPlay = onlyInPlay,
        alive = {}, evidence = {}, spatial = {}, dead = {},
        tokens = 0, aliveTokens = 0, deadTokens = 0, tokenless = 0, samples = {}, skipped = 0,
        px = px, py = py, maxDist = 0, now = U.gameSeconds() or 0,
    }
    if cfg("Verbose", false) and Census.mode == "full" then U.log(("census started (%s): %d character states"):format(reason, #list)) end
    return true
end

local function nearestPoint(u, x, y, radius)
    local best, bd = nil, radius * radius
    for _, name in ipairs(ByUnique[u] or {}) do
        local p = Points[name]
        local d = U.dist2(x, y, p.x, p.y)
        if d < bd then best, bd = name, d end
    end
    return best
end

local function isDeadState(st)
    return U.callBool(st, "IsDead") == true or U.callBool(st, "GetRemovedFromWorld") == true
end

local function censusStep(budget)
    local c = Census
    local n = 0
    local states = c.inPlay and World.states() or nil
    while c.i <= #c.list and n < budget do
        local e = c.list[c.i]
        c.i, n = c.i + 1, n + 1
        local st = e.st
        local usable
        if states then
            -- only a state that is still in play is touched (world.lua drops it the moment it leaves)
            usable = e.reg == true and rawequal(states[e.addr], st)
            if not usable then c.skipped = c.skipped + 1 end
        else
            usable = U.valid(st)
        end
        if usable then
            local id = U.fname(U.call(st, "GetCharacterGlobalId")) or U.fname(U.get(st, "CharacterGlobalId"))
            local pt = pointFromId(id)
            if c.mode == "evidence" and (pt or TokensWork ~= false) then
                if pt then c.evidence[pt] = true; c.tokens = c.tokens + 1 end
            elseif pt then
                c.tokens = c.tokens + 1
                local unique = U.fname(U.call(st, "GetCharacterUniqueName"))
                local dead = U.callBool(st, "IsDead") == true
                local removed = U.callBool(st, "GetRemovedFromWorld") == true
                c.evidence[pt] = true
                if dead or removed then
                    c.deadTokens = c.deadTokens + 1
                    if dead and not removed and id then push(c.dead, pt, unique or "?", { st = st, id = id, addr = e.addr, reg = e.reg }) end
                else
                    c.aliveTokens = c.aliveTokens + 1
                    bump(c.alive, pt, unique or "?")
                    if c.px and c.maxDist < 15000 then
                        local x, y = U.vec3(U.call(st, "GetCharacterLocation"))
                        if x then
                            local d = math.sqrt(U.dist2(x, y, c.px, c.py))
                            if d > c.maxDist then c.maxDist = d end
                        end
                    end
                end
            else
                local unique = U.fname(U.call(st, "GetCharacterUniqueName"))
                if unique and ByUnique[unique] then
                    c.tokenless = c.tokenless + 1
                    if #c.samples < 4 and id then c.samples[#c.samples + 1] = id end
                    local dead = U.callBool(st, "IsDead") == true
                    local removed = U.callBool(st, "GetRemovedFromWorld") == true
                    local x, y = U.vec3(U.call(st, "GetCharacterLocation"))
                    if x then
                        local pt2 = nearestPoint(unique, x, y, SPATIAL_RADIUS)
                        if not dead and not removed then
                            if pt2 then
                                bump(c.spatial, pt2, unique)
                                if U.dist2(x, y, Points[pt2].x, Points[pt2].y) <= EVIDENCE_RADIUS * EVIDENCE_RADIUS then
                                    c.evidence[pt2] = true
                                end
                            end
                            if c.px then
                                local d = math.sqrt(U.dist2(x, y, c.px, c.py))
                                if d > c.maxDist then c.maxDist = d end
                            end
                        elseif dead and not removed and pt2 and c.mode == "full"
                            and U.dist2(x, y, Points[pt2].x, Points[pt2].y) <= EVIDENCE_RADIUS * EVIDENCE_RADIUS then
                            if id then push(c.dead, pt2, unique, { st = st, id = id, addr = e.addr, reg = e.reg }) end
                        end
                    end
                end
            end
        end
    end
    return c.i > #c.list
end

local function rollFor(entry)
    local t = Intervals[entry.h]
    if not t or t.due <= 0 then return nil end
    return U.catchUp(entry.p, t.due)
end

local function dueText()
    local hs = {}
    for h, t in pairs(Intervals) do if t.due > 0 then hs[#hs + 1] = h end end
    table.sort(hs)
    local parts = {}
    for _, h in ipairs(hs) do parts[#parts + 1] = ("%dh x%d"):format(h, Intervals[h].due) end
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function finishCensus()
    local c = Census
    Census = nil
    Stats.skipped = Stats.skipped + c.skipped
    if c.tokens > 0 then TokensWork = true
    elseif c.tokenless > 0 and TokensWork == nil then TokensWork = false end
    if DIAG and TokensWork ~= nil and TokensWork ~= Noted.tokens then
        Noted.tokens = TokensWork
        DIAG.note("creatures.ids_carry_point_names", TokensWork,
            TokensWork and (c.tokens .. " ids matched a spawn point")
                or (#c.samples > 0 and ("sample ids: " .. table.concat(c.samples, ", ")) or "no id readable"))
    end
    if c.mode == "evidence" then
        local added = 0
        for pt in pairs(c.evidence) do
            if not State.seen[pt] then State.seen[pt] = true; added = added + 1; State.dirty = true end
        end
        if added > 0 and cfg("Verbose", false) then
            U.log(("evidence scan: %d populated spawn points newly known (%d creature ids matched)"):format(added, c.tokens))
        end
        return
    end
    if c.maxDist >= 15000 then GlobalStates = true
    elseif GlobalStates == nil then GlobalStates = false end
    if DIAG and GlobalStates ~= Noted.global then
        Noted.global = GlobalStates
        DIAG.note("creatures.far_states_visible", GlobalStates,
            ("farthest living creature seen %d m away"):format(math.floor(c.maxDist / 100)))
    end
    Dead = c.dead
    local seen = State.seen
    local newlySeen = 0
    for pt in pairs(c.evidence) do
        if not seen[pt] then seen[pt] = true; newlySeen = newlySeen + 1; State.dirty = true end
    end
    local rnd = cfg("Random", math.random)
    local maxQueue = cfg("MaxSpawnsPerCycle", 150)
    local considered, missingTotal, queued = 0, 0, 0
    local excludePrefixes = cfg("ExcludePointPrefixes", {})
    local recentHours = numCfg(Cfg.RecentSpawnHours, 30)
    for name, p in pairs(Points) do
        if seen[name] then
            local skip = false
            for _, pre in ipairs(excludePrefixes) do
                if name:sub(1, #pre) == pre then skip = true; break end
            end
            if not skip and not GlobalStates and c.px then
                if U.dist2(p.x, p.y, c.px, c.py) > NEAR_RADIUS * NEAR_RADIUS then skip = true end
            end
            if not skip then
                considered = considered + 1
                local avail = {}
                for u, k in pairs(c.alive[name] or {}) do avail[u] = (avail[u] or 0) + k end
                for u, k in pairs(c.spatial[name] or {}) do avail[u] = (avail[u] or 0) + k end
                -- creatures this mod spawned recently count as present until
                -- the census had time to see them (async spawns, wandering)
                local rec = State.recent and State.recent[name]
                if rec then
                    local live = false
                    local horizon = c.now + recentHours * 3600 + 60
                    for u, r in pairs(rec) do
                        if type(r) == "table" and r.t and r.t > c.now and r.t <= horizon then
                            avail[u] = (avail[u] or 0) + (r.n or 0)
                            live = true
                        else
                            rec[u] = nil
                        end
                    end
                    if not live then State.recent[name] = nil; State.dirty = true end
                end
                -- creatures at this point whose unique name is not one of the
                -- point's species (naming differences) count as wildcards
                local species = {}
                for _, s in ipairs(p.s) do species[s.u] = true end
                local wild = 0
                for u, k in pairs(avail) do
                    if not species[u] then wild = wild + k; avail[u] = 0 end
                end
                for _, s in ipairs(p.s) do
                    if s.on then
                        local have = math.min(avail[s.u] or 0, s.n)
                        avail[s.u] = (avail[s.u] or 0) - have
                        if have < s.n and wild > 0 then
                            local w = math.min(wild, s.n - have)
                            have, wild = have + w, wild - w
                        end
                        local missing = s.n - have
                        if missing > 0 then
                            missingTotal = missingTotal + missing
                            local chance = rollFor(s)
                            if chance and chance > 0 then
                                for _ = 1, missing do
                                    if queued < maxQueue and rnd() < chance then
                                        Queue[#Queue + 1] = { point = name, s = s, tries = 0 }
                                        queued = queued + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    Stats.cycles = Stats.cycles + 1
    Stats.queued = Stats.queued + queued
    local seenCount = 0
    for _ in pairs(seen) do seenCount = seenCount + 1 end
    U.log(("creature cycle (%s, due %s): %d states, %d at known points (%d alive, %d dead), %d other creatures; points populated so far %d (+%d), checked %d, missing %d, respawning %d%s")
        :format(c.reason, dueText(), #c.list, c.tokens, c.aliveTokens, c.deadTokens, c.tokenless,
            seenCount, newlySeen, considered, missingTotal, queued,
            GlobalStates and "" or " [only nearby creatures visible: far points wait]"))
    if c.tokens == 0 and #c.samples > 0 then
        U.logOnce("idfmt", "No creature id matched a spawn point; sample ids: " .. table.concat(c.samples, ", "))
    end
    for _, t in pairs(Intervals) do t.due = 0 end
end

-- The script object of a spawn point, by the name of its class. Points
-- without a live script object use the AI script library instead.
--
-- The game's world point manager keeps, for every point, the script object it
-- works with (WorldPointConfig.m_WorldPointScriptInstance). Where in the
-- manager's list the mod's points are is looked up once per session (again
-- after five minutes when a point was not there); the object itself is asked
-- from the manager at the moment it is needed, so nothing of it is kept.
local SCRIPTS_EVERY = 300
local function noteScripts(how, detail)     -- diagnostics only: noted when it changes
    if Noted.scripts == how then return end
    Noted.scripts = how
    DIAG.note("creatures.point_scripts_by", how, detail)
end
local function buildScripts(arr, name, realNow)
    local wanted = {}
    for _, p in pairs(Points) do wanted[p.c] = true end
    local at, n, i = {}, 0, 0
    local op = U.op("creatures: read the world point manager's list of scripts")
    local ok, err = pcall(function()
        arr:ForEach(function(_, e)
            i = i + 1
            local inst = U.unwrap(e).m_WorldPointScriptInstance
            if inst ~= nil and U.valid(inst) then
                local token = U.classToken(inst)
                if token and wanted[token] and at[token] == nil then
                    at[token] = i
                    n = n + 1
                end
            end
        end)
    end)
    U.done(op)
    if not ok or i == 0 then
        ScriptsBroken = true
        U.logOnce("noscripts", "creatures: the world point manager's list cannot be read (" .. tostring(ok and "it is empty" or err)
            .. "); spawn point scripts are searched for as before")
        if DIAG then noteScripts("search", "the manager's list cannot be read") end
        return nil
    end
    Scripts = { manager = name, at = at, n = n, configs = i, built = realNow }
    if cfg("Verbose", false) then U.log(("world point scripts: %d of the mod's points have one (%d points in the game's list)"):format(n, i)) end
    return Scripts
end
-- Not one of the mod's points has a script object in the manager's list: the
-- list is not what it is taken for (or no point is active yet), and the old
-- way decides - until the list is read again, five minutes later.
-- Returns the script object, or nil (the point has none), or nil and "later"
-- (it cannot be looked up right now), or nil and "old way" (the manager cannot be asked).
local function fromManager(token, realNow)
    if ScriptsBroken then return nil, "old way" end
    local mgr, asked = U.worldPointManager()
    if not asked then return nil, "old way" end
    if not mgr then return nil, "later" end
    local arr = U.get(mgr, "m_WorldPointConfigs")
    local name = U.fullName(mgr)
    if arr == nil or not name then return nil, "later" end
    local index = Scripts
    if index == nil or index.manager ~= name then
        index = buildScripts(arr, name, realNow)
        if not index then return nil, "old way" end
    end
    local place = index.at[token]
    if place == nil and realNow - index.built > SCRIPTS_EVERY then
        index = buildScripts(arr, name, realNow)
        if not index then return nil, "old way" end
        place = index.at[token]
    end
    if index.n == 0 then
        if DIAG then noteScripts("search", "no script objects in the manager's list") end
        return nil, "old way"
    end
    if place == nil then return nil end
    -- (never past the end of the list: this UE4SS build adds an element when an index past the end is touched)
    local okN, count = pcall(function() return arr:GetArrayNum() end)
    if not okN or type(count) ~= "number" or place > count then
        Scripts = nil
        return nil, "later"
    end
    local okI, inst = pcall(function() return U.unwrap(arr[place]).m_WorldPointScriptInstance end)
    if okI and inst ~= nil and U.valid(inst) and U.classToken(inst) == token then
        if DIAG then noteScripts("manager", ("%d of the mod's points have a script"):format(index.n)) end
        return inst
    end
    index.at[token] = nil       -- the list has changed there: looked up again when the index is rebuilt
    return nil
end
-- The old way: all script objects by a search among all objects, kept for
-- five minutes and checked by their class name before use.
local function fromSearch(token, realNow)
    -- (a kept wrapper is a pointer: make sure the object there is still the
    -- script of this point and not something that took its place)
    local inst = Instances.map[token]
    if inst and U.valid(inst) and U.classToken(inst) == token then return inst end
    if realNow - Instances.at > SCRIPTS_EVERY then
        if not U.mayWalk(realNow) then return nil, "later" end
        Instances.at = realNow
        local map, n = {}, 0
        local op = U.op("creatures: search for world point scripts")
        for _, o in ipairs(U.findAll("WorldPointScript")) do
            local full = U.fullName(o)
            if full and not full:find("Default__", 1, true) then
                local t = full:match("^(%S+)")
                if t then map[t] = o; n = n + 1 end
            end
        end
        U.done(op)
        Instances.map = map
        if cfg("Verbose", false) then U.log("world point script instances: " .. n) end
        inst = map[token]
        if inst and U.valid(inst) and U.classToken(inst) == token then return inst end
    end
    return nil
end
local function scriptInstance(token, realNow)
    local inst, why = fromManager(token, realNow)
    if why == "old way" then return fromSearch(token, realNow) end
    return inst, why
end

-- The game's AI script library (used when a point has no live script
-- object): looked up when the mod starts, else searched for once per run at
-- most, found or not (util.lua, findOnce). Second result "later": a search is
-- not due yet.
local function spawnLibrary()
    return U.findOnce("/Script/G1R.Default__AIScriptLibrary")
end

local function spawnOne(job, realNow)
    local p = Points[job.point]
    local s = job.s
    local def, wait = classFor(s.d)
    if wait then return nil, "later" end
    if not def then return false, "no-class" end
    local inst, why = scriptInstance(p.c, realNow)
    if why == "later" then return nil, "later" end
    if inst then
        local routine = nil
        if s.r then
            local rc, waitR = classFor(s.r)
            if waitR then return nil, "later" end
            if rc then
                local ok, obj = pcall(StaticConstructObject, rc, inst)
                if ok and U.valid(obj) then routine = obj end
            end
        end
        local ok, ret = U.try(inst, "SpawnAIAgent", def, routine)
        if not ok and routine ~= nil then ok, ret = U.try(inst, "SpawnAIAgent", def, nil) end
        if ok then return true, "point", U.fname(ret) end
        U.logError("pspawn:" .. tostring(ret), "Point spawn failed (" .. tostring(ret) .. "); using the AI script library.")
    end
    local lib, waitL = spawnLibrary()
    if waitL then return nil, "later" end
    local world = U.world()
    if lib and world then
        local a = math.random() * 2 * math.pi
        local r = 60 + math.random() * 120
        local pos = { X = p.x + math.cos(a) * r, Y = p.y + math.sin(a) * r, Z = p.z + 60 }
        local ok, req = U.try(lib, "SpawnAIAgent", world, def, pos)
        if ok then return true, "library" end
        U.logError("lspawn:" .. tostring(req), "Library spawn failed: " .. tostring(req))
    end
    return false, "no-spawner"
end

-- The creature came back: remove one corpse of its kind from the same spot
-- (not if the corpse lies near the player, and not when it is not known how
-- far from the player it lies).
local function removeCorpse(point, unique, px, py)
    if cfg("RemoveCorpsesOnRespawn", true) == false then return end
    local byU = Dead[point]
    local list = byU and (byU[unique] or byU["?"])
    if not list then return end
    local minD = numCfg(Cfg.MinPlayerDistance, 4000)
    local states = inPlay() and World.states() or nil
    while #list > 0 do
        local e = table.remove(list, 1)
        local st = e.st
        -- the state object was noted at the last count: it is touched only while
        -- it is still in play (world.lua; without that list: while it is valid)
        local there
        if e.reg then there = states ~= nil and rawequal(states[e.addr], st)
        else there = states == nil and U.valid(st) end
        -- and only when it is still the same character (same id) is its corpse the one to remove
        if there and (U.fname(U.call(st, "GetCharacterGlobalId")) or U.fname(U.get(st, "CharacterGlobalId"))) == e.id
            and U.callBool(st, "IsDead") == true and U.callBool(st, "GetRemovedFromWorld") ~= true then
            local x, y = U.vec3(U.call(st, "GetCharacterLocation"))
            if not (x and px) then
                -- where it lies, or where the player is, is not known: it stays (looked at again at the next respawn here)
                list[#list + 1] = e
                Stats.corpsesKept = Stats.corpsesKept + 1
                if DIAG and not Noted.corpseKept then
                    Noted.corpseKept = true
                    DIAG.note("creatures.corpse_kept", "distance to the player not known", tostring(unique) .. " at " .. tostring(point))
                end
                return
            elseif U.dist2(x, y, px, py) < minD * minD then
                -- lying next to the player: leave it to the game's own cleanup
            else
                local op = U.op("creatures: remove the corpse of " .. tostring(unique) .. " at " .. tostring(point))
                local ok = U.try(st, "RemoveFromWorld")
                U.done(op)
                if ok then
                    Stats.corpses = Stats.corpses + 1
                    if DIAG and not Noted.corpse then
                        Noted.corpse = true
                        DIAG.note("creatures.corpse_removed", true, tostring(unique) .. " at " .. tostring(point))
                    end
                    return
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Did the creature come? The point's script hands back a name (DISASM: SpawnAIAgent(Class, Object) -> Name).
-- Whether the game's lookup by unique name (GothicNPCState:FindNPCByUniqueName, IN-GAME for the markers) knows
-- that name is UNKNOWN: the first spawns of a run are looked up to find out. Until a spawned creature was found
-- the corpse is removed at once, as before; once one was found in this run, a corpse goes only for a spawn whose
-- creature the lookup found, and a "None" handed back is a spawn that did not happen.
-- ---------------------------------------------------------------------------
local function lookUp(name)
    if Confirm.lookup == nil then
        -- a search by path: put off like every search among all objects (util.lua)
        if not U.mayWalk() then return nil, "later" end
        Confirm.lookup = U.findStatic("/Script/G1R.Default__GothicNPCState") or false
    end
    local cdo = Confirm.lookup
    if not cdo or not U.valid(cdo) then return nil, "not available" end
    local ctrl = U.controller()
    if not ctrl then return nil, "later" end
    local ok, st = pcall(function() return cdo:FindNPCByUniqueName(ctrl, FName(name)) end)
    if not ok then return nil, "fails" end
    if U.valid(st) then return st end
    return nil
end

local function noteConfirm(e, how)
    if DIAG and Noted.confirm ~= how then
        Noted.confirm = how
        DIAG.note("creatures.spawn_confirm", how, tostring(e.name) .. " at " .. tostring(e.point))
    end
end

local function removeFor(e)
    if e.probe then return end      -- (its corpse went at the spawn)
    local px, py = U.playerPos()
    pcall(removeCorpse, e.point, e.unique, px, py)
end

local function confirmStep(realNow)
    local list = Confirm.pending
    local i = 1
    while i <= #list do
        local e = list[i]
        local age, finished = realNow - e.at, false
        if age >= CONFIRM_AFTER and realNow - (e.tried or -1e9) >= 1 then
            e.tried = realNow
            local st, why = lookUp(e.name)
            if why == "not available" or why == "fails" then
                -- the lookup cannot be asked in this run: corpses go at once, as before
                Confirm.works = false
                noteConfirm(e, why)
                removeFor(e)
                finished = true
            elseif st then
                Stats.confirmed = Stats.confirmed + 1
                if Confirm.works ~= true then
                    Confirm.works = true
                    noteConfirm(e, "works")
                end
                removeFor(e)
                finished = true
            elseif age >= CONFIRM_GIVE_UP then
                -- not found: its corpse stays
                Stats.unconfirmed = Stats.unconfirmed + 1
                if e.probe then
                    Confirm.misses = Confirm.misses + 1
                    if Confirm.works == nil and Confirm.misses >= PROBES then
                        Confirm.works = false
                        noteConfirm(e, "not found")
                    end
                end
                finished = true
            end
        end
        if finished then table.remove(list, i) else i = i + 1 end
    end
end

local function spawnStep(realNow)
    if #Queue == 0 then return end
    if realNow - LastSpawnReal < numCfg(Cfg.SpawnIntervalSeconds, 0.6) then return end
    local job = table.remove(Queue, 1)
    if job.s.on == false then return end      -- species turned off since it was queued
    if job.waitUntil and realNow < job.waitUntil then
        Queue[#Queue + 1] = job
        return
    end
    local p = Points[job.point]
    local px, py = U.playerPos()
    local minD = numCfg(Cfg.MinPlayerDistance, 4000)
    -- near the player, or it cannot be read where the player is (then nobody knows it is far enough): later
    if not px or U.dist2(p.x, p.y, px, py) < minD * minD then
        job.tries = job.tries + 1
        job.waitUntil = realNow + 20
        if job.tries <= cfg("MaxDeferrals", 90) then
            Queue[#Queue + 1] = job
            Stats.deferred = Stats.deferred + 1
        end
        return
    end
    local op = U.op("creatures: respawn " .. tostring(job.s.u) .. " at " .. job.point)
    local ok, how, id = spawnOne(job, realNow)
    U.done(op)
    if ok == nil then
        -- the point's script cannot be looked up right now: the job keeps its place
        table.insert(Queue, 1, job)
        return
    end
    LastSpawnReal = realNow
    if ok and how == "point" and id == "None" and Confirm.works == true then
        -- the names handed back are known to be real in this run: "None" is a spawn that did not happen
        ok, how = false, "none"
    end
    if DIAG then
        local via = ok and how or "failed"
        if via ~= Noted.via then
            Noted.via = via
            DIAG.note("creatures.spawn_via", via, ok and job.point or (tostring(how) .. " at " .. job.point))
        end
    end
    if ok then
        Stats.spawned = Stats.spawned + 1
        local now = U.gameSeconds()
        if now then
            State.recent = State.recent or {}
            local rp = State.recent[job.point]
            if not rp then rp = {}; State.recent[job.point] = rp end
            local r = rp[job.s.u]
            local untilT = now + numCfg(Cfg.RecentSpawnHours, 30) * 3600
            if r and r.t and r.t > now then r.n, r.t = r.n + 1, untilT
            else rp[job.s.u] = { n = 1, t = untilT } end
            State.dirty = true
        end
        if how == "point" and id ~= nil and id ~= "None" and Confirm.works ~= false then
            if Confirm.works == true then
                -- its corpse goes once the lookup has found the creature (confirmStep)
                Confirm.pending[#Confirm.pending + 1] = { name = id, point = job.point, unique = job.s.u, at = realNow }
            else
                pcall(removeCorpse, job.point, job.s.u, px, py)
                if Confirm.probes < PROBES then
                    Confirm.probes = Confirm.probes + 1
                    Confirm.pending[#Confirm.pending + 1] = { name = id, point = job.point, unique = job.s.u, at = realNow, probe = true }
                end
            end
        else
            pcall(removeCorpse, job.point, job.s.u, px, py)
        end
        if cfg("Verbose", false) then
            U.log(("respawned %s at %s via %s%s"):format(job.s.u, job.point, how, id and (" (" .. id .. ")") or ""))
        end
    else
        Stats.failed = Stats.failed + 1
        U.logError("spawnfail:" .. tostring(how), "Respawn failed (" .. tostring(how) .. ") at " .. job.point)
    end
end

-- Called every driver tick once the world is ready.
function C.tick(now, realNow, force)
    if not now then return end
    local maxK = cfg("MaxCatchUpCycles", 3)
    local anyDue = false
    for h, t in pairs(Intervals) do
        local idx = math.floor(now / (h * 3600))
        if t.idx == nil or idx < t.idx then
            t.idx = idx
        elseif idx > t.idx then
            t.due = math.min(maxK, t.due + (idx - t.idx))
            t.idx = idx
        end
        if force then t.due = math.max(t.due, 1) end
        if t.due > 0 then anyDue = true end
    end
    if force then Forced = true end
    if Census and Census.inPlay and not inPlay() then
        Census = nil -- the list of states in play is not relied on any more: counted anew, the old way
    end
    if Census and Census.mode == "evidence" and anyDue then
        Census = nil -- a full count supersedes the evidence scan
    end
    if Census == nil and anyDue then
        -- (a search among all objects: started when one is due, see util.lua)
        if startCensus(Forced and "forced" or "timer", "full", realNow) then
            LastEvidenceReal, Forced = realNow, false
        end
    elseif Census == nil and realNow - LastEvidenceReal > cfg("EvidenceScanSeconds", 300) then
        if startCensus("evidence", "evidence", realNow) then LastEvidenceReal = realNow end
    end
    if Census then
        local per = Census.mode == "evidence" and cfg("EvidenceStatesPerTick", 120) or cfg("CensusStatesPerTick", 60)
        local op = U.op(("creatures: %s, states %d to %d of %d"):format(Census.mode == "evidence" and "look at populated points" or "count",
            Census.i, math.min(Census.i + per - 1, #Census.list), #Census.list))
        local finished = censusStep(per)
        U.done(op)
        if finished then finishCensus() end
    end
    spawnStep(realNow)
    confirmStep(realNow)
end

-- A picture of the creature side for the megamod's diagnostics dump: plain
-- Lua values taken from what the mod holds; the game is not touched.
function C.diag()
    local seen, recent, intervals, classes, stats = {}, {}, {}, {}, {}
    local points = 0
    for _ in pairs(Points or {}) do points = points + 1 end
    for name in pairs(State and State.seen or {}) do seen[#seen + 1] = tostring(name) end
    table.sort(seen)
    for point, byUnique in pairs(State and State.recent or {}) do
        if type(byUnique) == "table" then
            for unique, r in pairs(byUnique) do
                if type(r) == "table" then
                    recent[#recent + 1] = { point = tostring(point), unique = tostring(unique), n = tonumber(r.n), t = tonumber(r.t) }
                end
            end
        end
    end
    table.sort(recent, function(a, b)
        if a.point ~= b.point then return a.point < b.point end
        return a.unique < b.unique
    end)
    for hours, t in pairs(Intervals) do
        intervals[#intervals + 1] = { hours = hours, due = t.due, index = t.idx }
    end
    table.sort(intervals, function(a, b) return a.hours < b.hours end)
    for short, c in pairs(ClassCache) do
        classes[#classes + 1] = { name = short, found = c ~= false }
    end
    table.sort(classes, function(a, b) return a.name < b.name end)
    for k, v in pairs(Stats) do stats[k] = v end
    return {
        points_known = points, points_seen = #seen, seen = seen,
        queue = #Queue, census_running = Census ~= nil,
        far_states_visible = GlobalStates, ids_carry_point_names = TokensWork,
        stats = stats, intervals = intervals, recent = recent, classes = classes,
        states_in_play_used = inPlay(), point_scripts = Scripts and { known = Scripts.n, list = Scripts.configs } or nil,
    }
end

return C
