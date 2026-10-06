-- G1R_Repopulate: items lying in the world (herbs, mushrooms, food, tools,
-- weapons, ...) regrow through the game's own world-point refill.
--
-- The game already refills some item spots: when a spot whose config has
-- m_Refillable set is visited again and more than m_RefillHours in-game
-- hours passed since it was emptied, its items come back (native check in
-- the world-point script update, G1R-Win64-Shipping.exe @0x145A5D5EF).
-- This module only changes those two fields, once per loaded game, on the
-- spots listed in data/item_points.lua:
--   herb  -> refill after RegrowHours (24)
--   loose -> refillable; hours drawn per spot so that it behaves like a
--            DailyChance (15 %) roll per in-game day (average ~1 week)
--   keep  -> already refillable in vanilla; the shorter of vanilla and a draw
-- The draw is fixed per spot and playthrough (hash of spot name and profile),
-- so reloading a save does not re-roll it.
-- Quest, unique, key, map and writing items and event-spawned spots are not
-- in the list, so they never come back. Nothing is written to save files;
-- the values are reapplied after every load. Turning a group off restores
-- the game's own values.
--
-- Retroactive: the game stores, for every item spot, the in-game time its
-- first item was taken (also for spots that never refill; set in the pickup
-- handler @0x145A7D720, saved as WorldPointSaveGameData.m_CurrentSeconds).
-- So spots emptied before the mod was installed refill on the next visit
-- once their time has passed.
local I = {}

-- Diagnostics handle of the megamod loader (nil when the mod runs on its own).
local DIAG = G1R_DIAG
local NotedSpots = nil     -- diagnostics: the number of spots last noted

local U, Cfg, Spots
local Done = false
local Tries = 0          -- passes in a row in which a spot raised (given up after three)
local DoneManager = nil    -- the full name of the manager the values were written to
local Kept = nil           -- the old way only: that manager (checked by its name before use)
local LastCheckReal = -1e9
local Stats = {}
local Orig = {}            -- spot name -> { r = refillable, h = hours } as first seen (vanilla)
local Seed = "default"

local function cfg(key, default)
    local v = Cfg[key]
    if v == nil then return default end
    return v
end

function I.init(u, config, spots)
    U, Cfg, Spots = u, config or {}, spots or {}
    local n = 0
    for _ in pairs(Spots) do n = n + 1 end
    return n
end

function I.reset()
    Done, DoneManager, Kept, Tries = false, nil, nil, 0
end

-- Seed for the per-spot draws (the profile key).
function I.setSeed(s) Seed = tostring(s or "default") end

-- FNV-1a hash of a string mapped to [0, 1).
local function hash01(s)
    local h = 2166136261
    for i = 1, #s do
        h = h ~ s:byte(i)
        h = (h * 16777619) & 0xffffffff
    end
    -- mix the high bits (FNV's low bits are weak for similar names)
    h = h ~ (h >> 15)
    h = (h * 0x2c1b3c6d) & 0xffffffff
    h = h ~ (h >> 12)
    return h / 4294967296
end
I._hash01 = hash01

function I.stats() return Stats, Done end

-- Days until the first success of a daily roll with chance p (>= 1),
-- from a uniform draw u in [0, 1).
local function geometricDays(p, u, maxDays)
    if p >= 1 then return 1 end
    if p <= 0 then return maxDays end
    if u >= 1 then u = 0.999999 end
    if u < 0 then u = 0 end
    local d = 1 + math.floor(math.log(1 - u) / math.log(1 - p))
    if d > maxDays then d = maxDays end
    if d < 1 then d = 1 end
    return d
end
I._geometricDays = geometricDays

local function num(v, d)
    v = tonumber(v)
    if v == nil or v ~= v then return d end
    return v
end

local function hoursFor(name, spot, rnd)
    local herbs = Cfg.Herbs or {}
    local world = Cfg.WorldItems or {}
    if spot.p == "herb" then
        if herbs.Enabled == false then return nil end
        return math.max(1, math.floor(num(herbs.RegrowHours, 24) + 0.5))
    end
    if world.Enabled == false then return nil end
    local u = rnd and rnd() or hash01(name .. "|" .. Seed)
    local days = geometricDays(num(world.DailyChance, 0.15), u, math.max(1, math.floor(num(world.MaxDays, 30))))
    local h = days * 24
    if spot.p == "keep" and spot.r and spot.r > 0 then
        if h > spot.r then h = spot.r end
    end
    return h
end

local function managerKey(mgr) return U.fullName(mgr) or tostring(mgr) end

-- The game's world point manager: from the game's own getter (util.lua), else
-- by a search among all objects (when one is due). Second result: how.
local function manager()
    local mgr, asked = U.worldPointManager()
    if asked then
        if mgr then U.way("items.manager_by", "engine") end
        return mgr, "engine"
    end
    if not U.mayWalk() then return nil, "later" end
    mgr = U.findFirst("WorldPointManager")
    if mgr then U.way("items.manager_by", U.engineWorld() and "search (the game's own getter answered nothing)" or "search") end
    return mgr, "search"
end

function I.apply()
    local mgr, how = manager()
    if not mgr then
        if how == "later" then return false, "later" end
        return false, "no WorldPointManager"
    end
    local arr = U.get(mgr, "m_WorldPointConfigs")
    if arr == nil then return false, "configs not readable" end
    local rnd = Cfg.Random
    local op = U.op("items: set the refill values of the item spots")
    local t0 = os.clock()
    local s = { configs = 0, matched = 0, herb = 0, loose = 0, keep = 0, written = 0, changed = 0, restored = 0, verifyFail = 0, errors = 0 }
    local firstErr = nil
    local ok, err = pcall(function()
        arr:ForEach(function(_, e)
            s.configs = s.configs + 1
            local okE, errE = pcall(function()
                local c = U.unwrap(e)
                local name = U.fname(c.m_Name)
                local spot = name and Spots[name]
                if not spot then return end
                s.matched = s.matched + 1
                local isc = c.m_ItemSpawnConfig
                local o = Orig[name]
                if not o then
                    o = { r = isc.m_Refillable == true, h = U.num(isc.m_RefillHours) or 0 }
                    Orig[name] = o
                end
                local h = hoursFor(name, spot, rnd)
                if not h then
                    -- group turned off: put the game's own values back
                    if isc.m_Refillable ~= o.r or U.num(isc.m_RefillHours) ~= o.h then
                        isc.m_Refillable = o.r
                        isc.m_RefillHours = o.h
                        s.restored = s.restored + 1
                    end
                    return
                end
                s[spot.p] = (s[spot.p] or 0) + 1
                s.written = s.written + 1
                -- written only where it differs: a pass over spots that are set already writes nothing
                if isc.m_Refillable ~= true or U.num(isc.m_RefillHours) ~= h then
                    isc.m_Refillable = true
                    isc.m_RefillHours = h
                    s.changed = s.changed + 1
                    if s.changed <= 5 then
                        local back = U.num(isc.m_RefillHours)
                        local refill = isc.m_Refillable
                        if back ~= h or refill ~= true then s.verifyFail = s.verifyFail + 1 end
                    end
                end
            end)
            if not okE then
                s.errors = s.errors + 1
                firstErr = firstErr or errE
            end
        end)
    end)
    s.ms = math.floor((os.clock() - t0) * 1000 + 0.5)
    U.done(op)
    Stats = s
    if not ok then return false, "ForEach failed: " .. tostring(err) end
    -- a spot that raised is tried again: the whole list is looked at once more ten seconds later (what is set
    -- already is not written again); after three such passes in a row the pass counts as done (the errors are logged)
    Tries = s.errors > 0 and Tries + 1 or 0
    Done, DoneManager = s.errors == 0 or Tries >= 3, managerKey(mgr)
    Kept = how == "search" and mgr or nil
    if DIAG and s.written ~= NotedSpots then
        NotedSpots = s.written
        DIAG.note("items.configs_set", s.written .. " spots", s.ms .. " ms")
    end
    U.log(("world items: %d spots set refillable (%d herbs/plants at %dh, %d other items ~%d%%/day, %d vanilla refill spots)%s, %d written now, %d configs scanned in %d ms%s%s")
        :format(s.written, s.herb, math.floor(num((Cfg.Herbs or {}).RegrowHours, 24) + 0.5), s.loose,
            math.floor(num((Cfg.WorldItems or {}).DailyChance, 0.15) * 100 + 0.5), s.keep,
            s.restored > 0 and (", " .. s.restored .. " restored to the game's values") or "", s.changed, s.configs, s.ms,
            s.verifyFail > 0 and (" | WARNING: " .. s.verifyFail .. " writes did not read back") or "",
            s.errors > 0 and (" | " .. s.errors .. " errors, first: " .. tostring(firstErr)) or ""))
    if s.matched == 0 then
        U.logOnce("items-nomatch", "world items: no spot names matched; the item refill part is inactive.")
    end
    return true
end

-- Called every driver tick once the world is ready (and the start delay passed).
function I.tick(realNow)
    if not Done then
        if realNow - LastCheckReal < 10 then return end
        local ok, why = I.apply()
        if not ok and why == "later" then return end       -- a search is not due yet: asked again on the next update
        LastCheckReal = realNow
        if not ok then U.logError("items:" .. tostring(why), "world items: " .. tostring(why) .. " (retrying)") end
        return
    end
    -- Is the manager still the one the values were written to? (A map load
    -- starts a new session anyway; this is for a manager the game replaces
    -- without one.) The game's getter is asked; without it the kept manager is
    -- looked at, and nothing is searched for while it is there.
    if realNow - LastCheckReal > 30 then
        LastCheckReal = realNow
        local mgr, asked = U.worldPointManager()
        if asked then
            if mgr and managerKey(mgr) ~= DoneManager then Done = false end
        elseif not (Kept ~= nil and U.valid(Kept) and managerKey(Kept) == DoneManager) then
            Done, Kept = false, nil
        end
    end
end

return I
