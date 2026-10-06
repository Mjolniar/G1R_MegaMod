-- ============================================================================
-- G1R_Repopulate 1.4 (local) - Gothic 1 Remake, UE4SS Lua
--
-- Easy-mode world repopulation:
--   * generic creatures come back at their own spawn points
--     (35 % per missing creature every 24 in-game hours; Shadowbeasts,
--      Swampsharks, Skeleton Mages 15 % every 24 hours; any species can have
--      its own chance / interval / on-off); the corpse of a fallen one is
--     removed when its successor appears
--   * herbs, plants and mushrooms regrow after 24 in-game hours
--   * other items lying in the world come back (~15 % per day, about a week)
--   * chests and other containers restock their original contents
--     (30 % per day in the camps and mines, 10 % per day elsewhere)
--   * also for things emptied before the mod was installed
-- Never: named NPCs, humans, orcs, bosses / unique creatures, quest and event
-- spawns, quest / unique / key / map / writing items.
-- Optional: a crime switch (theft, trespassing, drawn weapons can be turned
-- off; see crime.lua). Left on by default, and then nothing of it runs.
--
-- Settings: Scripts/config.lua (or G1R_Repopulate_Settings.exe); changes are
-- picked up while the game runs.
--
-- Built from the game's own data (GORE decompile of the shipped AngelScript
-- and the native function tables of G1R-Win64-Shipping.exe CL174209); uses
-- the game's own spawn / refill / inventory / removal functions so everything
-- it changes is saved by the game itself. The mod never writes save files.
-- One game-thread loop, one object-creation notification, all Unreal calls
-- guarded; work is spread over ticks.
--
-- 1.4: what the game hands out itself is asked from the game (the player
-- controller, the game clock, the profile, the crime subsystems, the world
-- point manager - util.lua, "The engine's own way") instead of being searched
-- for among all objects, and the mod follows which objects are in play
-- (world.lua) instead of holding on to objects that may be gone. A session is
-- started anew when a map is loaded, the game clock goes back or the profile
-- changes - no longer every time the hero is put into the world again, which
-- also happens when he mounts or dismounts.
-- ============================================================================

local VERSION = "1.5.0"

-- Diagnostics handle of the megamod loader; nil when the mod runs on its own,
-- and then nothing behind `if DIAG` runs. It only records what the mod sees.
local DIAG = G1R_DIAG
local NotedProfile = nil     -- diagnostics: the profile last noted
if DIAG then pcall(DIAG.version, VERSION) end

local SCRIPT_DIR = (function()
    local ok, src = pcall(function() return debug.getinfo(1, "S").source end)
    if ok and type(src) == "string" then
        local p = src:gsub("^@", ""):gsub("\\", "/")
        local d = p:match("^(.*/)[^/]+$")
        if d then return d end
    end
    return "./"
end)()

local function loadModule(rel)
    local ok, v = pcall(dofile, SCRIPT_DIR .. rel)
    if ok then return v end
    print("[G1R_Repopulate] failed to load " .. rel .. ": " .. tostring(v) .. "\n")
    return nil
end

local U = loadModule("util.lua")
if type(U) ~= "table" then return end

-- Settings: read as text so they can be re-read while the game runs. The file
-- only holds plain values; it runs without access to anything else.
local CONFIG_PATH = SCRIPT_DIR .. "config.lua"
local ConfigText = nil
local function parseConfig(text)
    if type(text) ~= "string" then return nil, "config.lua not found" end
    text = text:gsub("^\239\187\191", "")   -- UTF-8 byte order mark from some editors
    local chunk, err = load(text, "=config.lua", "t", {})
    if not chunk then return nil, err end
    local ok, v = pcall(chunk)
    if not ok then return nil, v end
    if type(v) ~= "table" then return nil, "config.lua did not return a table" end
    return v
end
local Config
do
    local text = U.readText(CONFIG_PATH)
    local c, err = parseConfig(text)
    if c then
        Config, ConfigText = c, text
    else
        U.log("config.lua missing or invalid (" .. tostring(err) .. "); using defaults")
        Config, ConfigText = {}, text
    end
end
local World = loadModule("world.lua")
local Creatures = loadModule("creatures.lua")
local Items = loadModule("items.lua")
local Chests = loadModule("chests.lua")
if type(World) ~= "table" or type(Creatures) ~= "table" or type(Items) ~= "table" or type(Chests) ~= "table" then
    U.log("FATAL: a module failed to load; mod disabled.")
    return
end
-- The crime switch is optional: without it everything else still works.
local Crime = loadModule("crime.lua")
if type(Crime) ~= "table" then
    Crime = nil
    U.log("crime.lua did not load; the crime switch is not available.")
end
local CreatureDB = loadModule("data/creature_points.lua") or {}
local ItemDB = loadModule("data/item_points.lua") or {}
local ChestDB = loadModule("data/chests.lua") or {}

local function section(name)
    local s = Config[name]
    if type(s) ~= "table" then s = {} end
    if s.Verbose == nil then s.Verbose = Config.Verbose end
    return s
end
local CreatureCfg, ChestCfg, ItemCfg, CrimeCfg
local function buildSections()
    CreatureCfg, ChestCfg = section("Creatures"), section("Chests")
    ItemCfg = { Herbs = section("Herbs"), WorldItems = section("WorldItems"), Verbose = Config.Verbose }
    CrimeCfg = section("Crime")
end
buildSections()

-- ---------------------------------------------------------------------------
-- Per-profile state (Scripts/state/profile_<id>.lua; never the save files)
-- ---------------------------------------------------------------------------
local State = { seen = {}, chests = {}, recent = {}, dirty = false }
local StatePath = nil
local LastSaveReal = -1e9

local PROFILES = "/Script/G1R.PersistentDataSubsystem"
-- The key of the profile the game is in: "profile_<id>". Second result: false
-- when the id could not be read (the key is then "profile_default").
local function profileKey()
    local pds, asked = U.subsystem("instance", PROFILES)
    if asked then
        local id = U.num(U.get(pds, "m_CurrentProfileId"))
        if id then return "profile_" .. math.floor(id), true end
        return "profile_default", false
    end
    -- the old way: a search among all objects (spaced like every such search)
    if U.mayWalk() then
        for _, o in ipairs(U.findAll("PersistentDataSubsystem")) do
            if U.valid(o) and not U.isDefault(o) then
                local id = U.num(U.get(o, "m_CurrentProfileId"))
                if id then return "profile_" .. math.floor(id), true end
            end
        end
    end
    return "profile_default", false
end

-- What a progress file holds is taken record by record: a record of a shape this
-- version does not write is left out (and counted), the others are used.
local STATE_VERSION = 1
local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function flag(v) return type(v) == "boolean" end
local CHEST_FIELDS = { d = finite, n = finite, f = finite, r = flag, p = flag }
local function chestRecord(r)
    if type(r) ~= "table" then return false end
    for k, v in pairs(r) do
        local ok = CHEST_FIELDS[k]
        if not ok or not ok(v) then return false end
    end
    return true
end
local function recentRecord(byUnique)          -- { [species] = { n = respawns, t = until } }
    if type(byUnique) ~= "table" then return false end
    for u, r in pairs(byUnique) do
        if type(u) ~= "string" or type(r) ~= "table" or not finite(r.n) or not finite(r.t) then return false end
    end
    return true
end
local function shaped(t, ok)
    local out, bad = {}, 0
    if type(t) ~= "table" then return out, 0 end
    for k, v in pairs(t) do
        if type(k) == "string" and ok(v) then out[k] = v else bad = bad + 1 end
    end
    return out, bad
end

-- `readable`: false when the id of the profile could not be read. Whose progress
-- that is cannot be told then: no progress file is read or written until the id
-- can be read (the session then starts anew on that profile's file).
local function loadState(key, readable)
    if DIAG and key ~= NotedProfile then
        NotedProfile = key
        local id = key:match("^profile_(.+)$") or key
        DIAG.note("core.profile", tonumber(id) or id, readable == false and "not written" or (key .. ".lua"))
    end
    Items.setSeed(key)
    if readable == false then
        StatePath = nil
        State.seen, State.chests, State.recent, State.dirty = {}, {}, {}, false
        return 0
    end
    StatePath = SCRIPT_DIR .. "state/" .. key .. ".lua"
    local t, from = U.readTable(StatePath)
    if from == "finished" then
        U.log("the last write of the progress file " .. key .. ".lua had been cut off; its complete new copy was put in place")
    elseif from == "backup" then
        -- the file is damaged: it is kept for a look, and the copy of the write before it is used
        U.keepBad(StatePath)
        U.log("the progress file " .. key .. ".lua could not be read; it is kept as " .. key .. ".lua.bad and the copy of the write before it (" .. key .. ".lua.bak) is used")
    elseif t == nil and from == "unreadable" then
        U.keepBad(StatePath)
        U.log("the progress file " .. key .. ".lua could not be read and there is no earlier copy; it is kept as " .. key .. ".lua.bad and progress starts anew")
    end
    if DIAG and from ~= nil and from ~= "missing" then DIAG.note("core.state_file", from, key .. ".lua") end
    if type(t) == "table" and finite(t.version) and t.version > STATE_VERSION then
        -- written by a newer version of the mod: left as it is (not read, not written over)
        U.log(("the progress file %s.lua was written by a newer version of the mod (%s): it is left as it is, and progress is kept for this session only")
            :format(key, tostring(t.version)))
        StatePath, t = nil, nil
    end
    local src = type(t) == "table" and t or {}
    local badSeen, badChests, badRecent
    State.seen, badSeen = shaped(src.seen, function(v) return v == true end)
    State.chests, badChests = shaped(src.chests, chestRecord)
    State.recent, badRecent = shaped(src.recent, recentRecord)
    local bad = badSeen + badChests + badRecent
    if bad > 0 then
        U.log(("the progress file %s.lua held %d record(s) of a shape this version does not write: they were left out (the file before stays as %s.lua.bak at the next write)")
            :format(key, bad, key))
    end
    State.dirty = false
    local n = 0
    for _ in pairs(State.seen) do n = n + 1 end
    return n
end

local SaveFailures = 0
local function saveState(force)
    if not StatePath or (not State.dirty and not force) then return end
    local text, dropped = U.serialize({ version = STATE_VERSION, seen = State.seen, chests = State.chests, recent = State.recent })
    if dropped > 0 then U.logOnce("state-dropped", ("the progress file: %d table(s) inside themselves or too deep were written as nothing"):format(dropped)) end
    local ok, err = U.writeFile(StatePath, text)
    if ok then
        State.dirty = false
    else
        -- what is in memory stays marked as not written: the next minute tries again
        State.dirty = true
        SaveFailures = SaveFailures + 1
        U.logError("state:" .. tostring(err), "could not write the progress file: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Session handling
--
-- A session is the time the mod works in one loaded world on one profile. It
-- ends, and everything the mod holds of the world is dropped, when
--   * a map is loaded (also what loading a save does: log of 2026-10-04,
--     21:28 - the hero's experience went back and the map load hooks fired),
--   * the game clock goes back (a save loaded without a map load, should the
--     game ever do that),
--   * the player controller is another one, or
--   * the profile changes.
-- It does not end when the hero is put into the world again
-- (PlayerController:ClientRestart): that also happens when he mounts or
-- dismounts and when he gets up from a bed, and nothing of the world changes
-- then. The mod only waits a moment (SettleSeconds) before it touches
-- anything again - mounting and dismounting are when the game removes and
-- creates objects.
-- ---------------------------------------------------------------------------
local function newSession() return { ready = false, readyAt = nil, lastNow = nil, started = false } end
local Session = newSession()
-- What happened in this run (never reset): for the status lines and the megamod's reports.
local Life = { resets = 0, why = {}, last = nil, possessions = 0, pauses = 0, paused = false, sessions = 0, held = 0 }
local SettleUntil = -1e9
local LoadingUntil = 0
local CLOCK_BACK = 5            -- game seconds the clock may go back without it being another save
local PROFILE_EVERY = 30        -- seconds between two looks at the profile in use
local PROFILE_WAIT = 20         -- seconds a session start waits for the profile id to become readable
local PROFILE_ASK = 5           -- seconds between two tries during that wait

-- Nothing of the game is touched for the next `seconds`.
local function settle(seconds, realNow)
    if seconds <= 0 then return end
    if realNow + seconds > SettleUntil then SettleUntil = realNow + seconds end
    U.quiet(seconds, realNow)
end

local function resetSession(why, detail)
    if Session.started then saveState(true) end
    Session = newSession()
    U.resetCaches()
    U.resetTime()
    Creatures.reset()
    Items.reset()
    Chests.reset()
    if Crime then Crime.reset() end
    Life.resets = Life.resets + 1
    Life.why[why] = (Life.why[why] or 0) + 1
    Life.last = why
    U.log(("session reset %d (%s%s)"):format(Life.resets, why, detail and (": " .. detail) or ""))
end

local function worldReady()
    local now = U.gameSeconds()
    if not now or now <= 0 then return nil end
    if not U.pawn() then return nil end
    return now
end

-- ---------------------------------------------------------------------------
-- Settings reload (config.lua changed on disk, e.g. by the settings app)
-- ---------------------------------------------------------------------------
local function pct(v, d) return math.floor((tonumber(v) or d) * 100 + 0.5) end
local function summary()
    local c, h, w, k = CreatureCfg, ItemCfg.Herbs, ItemCfg.WorldItems, ChestCfg
    local nOver = 0
    if type(c.Species) == "table" then for _ in pairs(c.Species) do nOver = nOver + 1 end end
    return ("creatures %s %d%%/%dh (elite %d%%/%dh, %d species with own settings, corpses %s) | herbs %s %dh | items %s %d%%/day | containers %s %d%%/%d%% per day | crime %s")
        :format(c.Enabled == false and "OFF" or "on", pct(c.NormalChance, 0.35), tonumber(c.NormalEveryHours) or 24,
            pct(c.EliteChance, 0.15), tonumber(c.EliteEveryHours) or 24, nOver,
            c.RemoveCorpsesOnRespawn == false and "kept" or "removed",
            h.Enabled == false and "OFF" or "on", tonumber(h.RegrowHours) or 24,
            w.Enabled == false and "OFF" or "on", pct(w.DailyChance, 0.15),
            k.Enabled == false and "OFF" or "on", pct(k.SettlementDailyChance, 0.30), pct(k.WildDailyChance, 0.10),
            Crime and Crime.describe(Config.Enabled ~= false) or "switch unavailable")
end

local LastConfigCheckReal = nil
local BadConfigText = nil
local function reloadConfig(force)
    local text = U.readText(CONFIG_PATH)
    if text == nil then return false, "config.lua not found" end
    if not force and text == ConfigText then return false, "unchanged" end
    if not force and text == BadConfigText then return false, "still invalid" end
    local c, err = parseConfig(text)
    if not c then
        BadConfigText = text
        U.log("config.lua has an error, keeping the previous settings: " .. tostring(err))
        return false, err
    end
    Config, ConfigText, BadConfigText = c, text, nil
    buildSections()
    Creatures.init(U, CreatureCfg, CreatureDB, State, World)
    Items.init(U, ItemCfg, ItemDB)
    Items.reset()   -- re-apply item spot values with the new settings
    Chests.init(U, ChestCfg, ChestDB, State, World)
    if Crime then Crime.init(U, CrimeCfg) end
    U.log("settings reloaded: " .. summary())
    return true
end

local function tick()
    local realNow = os.clock()
    local every = tonumber(Config.ReloadCheckSeconds) or 15
    if every > 0 then
        if LastConfigCheckReal == nil then LastConfigCheckReal = realNow end
        if realNow - LastConfigCheckReal >= every then
            LastConfigCheckReal = realNow
            local ok, err = pcall(reloadConfig, false)
            if not ok then U.logError("reload:" .. tostring(err), "settings reload error: " .. tostring(err)) end
        end
    end
    -- a map is loading, or the hero was just put into the world again: nothing of the game is touched
    if realNow < LoadingUntil then return end
    if realNow < SettleUntil then
        Life.held = Life.held + 1
        return
    end
    -- While the game is paused nothing of it is touched and nothing is asked
    -- for, not even its clock (objects that leave play in the meantime are
    -- still followed: world.lua). The one question is the engine's own, and
    -- it costs no search.
    if U.paused() == true then
        if not Life.paused then Life.paused, Life.pauses = true, Life.pauses + 1 end
        return
    end
    if Life.paused then
        Life.paused = false
        settle(1, realNow)      -- the game runs again: a moment later the mod does too
        return
    end
    local now = worldReady()
    if not now then
        Session.ready = false
        return
    end
    -- another world than the one this session belongs to?
    if Session.lastNow and now < Session.lastNow - CLOCK_BACK then
        resetSession("the game clock went back", ("%d s"):format(math.floor(Session.lastNow - now)))
        return
    end
    local controller = U.controllerName()
    if controller and Session.controller and controller ~= Session.controller then
        resetSession("another player controller")
        return
    end
    Session.controller = controller or Session.controller
    Session.lastNow = now
    if not Session.ready then
        Session.ready, Session.readyAt = true, realNow
        if Crime then Crime.recheck() end
        return
    end
    -- The crime switch does not wait for the start delay: a loaded world has
    -- the game's own rules again, and they should not be active for long.
    if Crime and realNow - Session.readyAt >= 1 then
        local ok, err = pcall(Crime.tick, realNow, Config.Enabled ~= false)
        if not ok then U.logError("cr:" .. tostring(err), "crime update error: " .. tostring(err)) end
    end
    local delay = tonumber(Config.StartDelaySeconds) or 8
    if realNow - Session.readyAt < delay then return end
    if not Session.started then
        -- progress is kept per profile: a start waits a little for the id to become readable
        if Session.profileAskAt and realNow - Session.profileAskAt < PROFILE_ASK then return end
        local key, readable = profileKey()
        if not readable and realNow - Session.readyAt < delay + PROFILE_WAIT then
            Session.profileAskAt = realNow
            return
        end
        Session.started = true
        Session.profile, Session.profileKnown, Session.profileAt = key, readable, realNow
        Life.sessions = Life.sessions + 1
        World.check()
        local seen = loadState(key, readable)
        local waiting, _, held = Chests.counts()
        U.log(("session started at day %d %02d:%02d | state %s: %d populated spawn points known, %d containers waiting, %d restocked and not opened yet")
            :format(math.floor(now / 86400), math.floor(now % 86400 / 3600), math.floor(now % 3600 / 60),
                StatePath and StatePath:match("([^/]+)$") or (key .. " (not written)"), seen, waiting, held))
        if not readable then
            U.logOnce("noprofile", "the id of the profile could not be read: no progress file is read or written until it can be (the session then starts anew on that profile's file)")
        end
    elseif realNow - Session.profileAt >= PROFILE_EVERY then
        -- the profile in use, asked from the engine (never searched for here)
        Session.profileAt = realNow
        local pds, asked = U.subsystem("instance", PROFILES)
        local id = asked and U.num(U.get(pds, "m_CurrentProfileId")) or nil
        local key = id and ("profile_" .. math.floor(id)) or nil
        if key and key ~= Session.profile then
            local was = Session.profile
            resetSession("the profile changed", was .. " -> " .. key)
            return
        end
    end
    if Config.Enabled == false then return end
    if CreatureCfg.Enabled ~= false then
        local ok, err = pcall(Creatures.tick, now, realNow, Session.forceCreatures)
        Session.forceCreatures = nil
        if not ok then U.logError("ct:" .. tostring(err), "creature update error: " .. tostring(err)) end
    end
    if (ItemCfg.Herbs.Enabled ~= false) or (ItemCfg.WorldItems.Enabled ~= false) then
        local ok, err = pcall(Items.tick, realNow)
        if not ok then U.logError("it:" .. tostring(err), "item update error: " .. tostring(err)) end
    end
    if ChestCfg.Enabled ~= false then
        local ok, err = pcall(Chests.tick, now, realNow)
        if not ok then U.logError("ch:" .. tostring(err), "container update error: " .. tostring(err)) end
    end
    -- a restock (or its end) is written at once; everything else once a minute
    if State.urgent or realNow - LastSaveReal > 60 then
        LastSaveReal = realNow
        State.urgent = nil
        saveState(false)
    end
end

-- ---------------------------------------------------------------------------
-- Status / console
-- ---------------------------------------------------------------------------
-- The status lines for a given in-game time. Nothing in here touches the
-- game (the megamod's diagnostics call it on their own schedule).
-- How the run went so far: sessions and what ended them, how often the hero
-- was put into the world again, pauses, searches among all objects.
local function lifeLine()
    local parts = {}
    local reasons = {}
    for why in pairs(Life.why) do reasons[#reasons + 1] = why end
    table.sort(reasons)
    for _, why in ipairs(reasons) do parts[#parts + 1] = ("%s %d"):format(why, Life.why[why]) end
    return ("this run: %d session%s, %d reset%s%s; hero put into the world again %d time%s (no reset), %d pause%s; %d searches among all objects%s")
        :format(Life.sessions, Life.sessions == 1 and "" or "s", Life.resets, Life.resets == 1 and "" or "s",
            #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "",
            Life.possessions, Life.possessions == 1 and "" or "s", Life.pauses, Life.pauses == 1 and "" or "s",
            (U.walks()), SaveFailures > 0 and ("; %d writes of the progress file failed"):format(SaveFailures) or "")
end
local function statusLines(now)
    local cs, q, censusRunning, global, intervals = Creatures.stats()
    local is, done = Items.stats()
    local seen = 0
    for _ in pairs(State.seen) do seen = seen + 1 end
    local iv = {}
    local hs = {}
    for h in pairs(intervals or {}) do hs[#hs + 1] = h end
    table.sort(hs)
    for _, h in ipairs(hs) do
        local nextAt = (math.floor(now / (h * 3600)) + 1) * h * 3600
        iv[#iv + 1] = ("every %dh (next in %.1fh)"):format(h, (nextAt - now) / 3600)
    end
    return {
        ("v%s | day %d %02d:%02d | %s"):format(VERSION, math.floor(now / 86400), math.floor(now % 86400 / 3600), math.floor(now % 3600 / 60), summary()),
        ("creatures: %d cycles, %d queued, %d respawned, %d corpses removed, %d failed, %d waiting for you to move away; queue %d%s; populated points %d; far creatures visible: %s; rolls %s")
            :format(cs.cycles, cs.queued, cs.spawned, cs.corpses or 0, cs.failed, cs.deferred, q, censusRunning and " (census running)" or "", seen,
                tostring(global), #iv > 0 and table.concat(iv, ", ") or "none"),
        ("world items: %s, %d spots (%d herbs, %d other, %d vanilla)"):format(done and "applied" or "pending",
            is.written or 0, is.herb or 0, is.loose or 0, is.keep or 0),
        Chests.statusLine(),
        Crime and Crime.statusLine() or "crime: switch unavailable (crime.lua did not load)",
        World.statusLine(),
        lifeLine(),
    }
end
local function status() return statusLines(U.gameSeconds() or 0) end

local function console(fullCommand, params, ar)
    local args = {}
    if type(params) == "table" then
        for _, p in ipairs(params) do args[#args + 1] = tostring(p) end
    elseif type(fullCommand) == "string" then
        for w in fullCommand:gmatch("%S+") do args[#args + 1] = w end
        table.remove(args, 1)
    end
    local sub = (args[1] or "status"):lower()
    local lines
    if sub == "now" then
        Session.forceCreatures = true
        lines = { "creature cycle queued (runs on the next update)" }
    elseif sub == "items" then
        Items.reset()
        lines = { "world item pass queued" }
    elseif sub == "save" then
        saveState(true)
        lines = { "state written to " .. tostring(StatePath) }
    elseif sub == "reload" then
        local ok, why = reloadConfig(true)
        lines = { ok and "settings reloaded" or ("settings not reloaded: " .. tostring(why)) }
    elseif sub == "crime" then
        if Crime then Crime.init(U, CrimeCfg) end   -- re-check on the next update
        lines = { Crime and Crime.statusLine() or "crime: switch unavailable (crime.lua did not load)" }
    else
        lines = status()
    end
    for _, l in ipairs(lines) do
        U.log(l)
        if ar ~= nil then pcall(function() ar:Log("[G1R_Repopulate] " .. l) end) end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Registration (each exactly once)
-- ---------------------------------------------------------------------------
World.init(U)
World.listen({ began = Chests.onBegan, ended = Chests.onEnded })
U.setCalm(World.calm)
-- The objects of the game that are asked for by path are looked up at the
-- first map load the mod sees (util.lua, U.warm): loading the mod searches
-- nothing.
local FirstLoadSeen = false
local function firstMapLoad()
    if FirstLoadSeen then return end
    FirstLoadSeen = true
    local paths = {}
    for _, path in ipairs(U.paths) do paths[#paths + 1] = path end
    for _, path in ipairs(Crime and Crime.paths or {}) do paths[#paths + 1] = path end
    for _, path in ipairs(World.paths) do paths[#paths + 1] = path end
    paths[#paths + 1] = "/Script/G1R.Default__DataModuleLibrary"
    paths[#paths + 1] = "/Script/G1R.Default__AIScriptLibrary"
    local ok, found = pcall(U.warm, paths)
    if DIAG then DIAG.note("core.paths_found", ok and ("%d of %d found"):format(found, #paths) or "failed", "at the first map load") end
end
local nC, cC = Creatures.init(U, CreatureCfg, CreatureDB, State, World)
local nI = Items.init(U, ItemCfg, ItemDB)
local nK = Chests.init(U, ChestCfg, ChestDB, State, World)
if Crime then Crime.init(U, CrimeCfg) end

-- A map load (UE4SS hands both hooks the engine object first; nothing but nil
-- may come back from them). Every object of the old world leaves play.
if type(RegisterLoadMapPreHook) == "function" then
    pcall(RegisterLoadMapPreHook, function(engine)
        pcall(U.setEngine, engine)
        pcall(firstMapLoad)
        resetSession("map load")
        World.reset()
        local now = os.clock()
        LoadingUntil = now + 3
        U.quiet(3, now)
    end)
end
if type(RegisterLoadMapPostHook) == "function" then
    pcall(RegisterLoadMapPostHook, function(engine)
        pcall(U.setEngine, engine)
        local now = os.clock()
        if now + 3 > LoadingUntil then LoadingUntil = now + 3 end
        U.quiet(3, now)
    end)
end
-- The hero was put into the world again: a mount, a dismount, getting up
-- from a bed - or part of a load, which the hooks above deal with. Nothing is
-- reset; the mod waits a moment before it touches the game again.
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
        Life.possessions = Life.possessions + 1
        local seconds = tonumber(Config.SettleSeconds) or 3
        if seconds > 30 then seconds = 30 end
        settle(seconds, os.clock())
    end)
end)
if type(NotifyOnNewObject) == "function" then
    pcall(NotifyOnNewObject, "/Script/G1R.InteractiveObjectActor", function(obj)
        Chests.onNewObject(obj)
    end)
end
for _, name in ipairs({ "repop", "g1r_repopulate" }) do
    if type(RegisterConsoleCommandHandler) == "function" then
        pcall(RegisterConsoleCommandHandler, name, console)
    end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    U.log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; mod disabled.")
    return
end
math.randomseed(os.time())
LoopInGameThreadWithDelay(250, function()
    local ok, err = pcall(tick)
    if not ok then U.logError("tick:" .. tostring(err), "update error: " .. tostring(err)) end
end)

U.log(("v%s loaded: %d creature spawn points (%d creatures), %d item spots, %d containers | %s")
    :format(VERSION, nC, cC, nI, nK, summary()))

-- Megamod diagnostics: the status lines for its reports and a picture of what
-- the mod holds for its dump command. Both are built from the mod's own Lua
-- data (the in-game time is the one the last update saw); neither touches the game.
if DIAG then
    pcall(function()
        DIAG.status(function() return statusLines(Session.lastNow or 0) end)
        DIAG.dump(function()
            local crime = nil
            if Crime then
                crime = Crime.stats()
                crime.status = Crime.statusLine()
            end
            return {
                version = VERSION,
                profile = Session.profile,
                game_seconds = Session.lastNow,
                session_started = Session.started == true,
                containers = Chests.diag(),
                creatures = Creatures.diag(),
                crime = crime,
                objects_in_play = World.stats(),
                run = { sessions = Life.sessions, resets = Life.resets, reset_reasons = Life.why, last_reset = Life.last,
                    put_into_world_again = Life.possessions, pauses = Life.pauses, updates_held = Life.held,
                    searches = (U.walks()), state_write_failures = SaveFailures },
            }
        end)
    end)
end

-- Offline test harness hook (inert in game).
if type(rawget(_G, "REPOP_TEST")) == "table" then
    local T = rawget(_G, "REPOP_TEST")
    T.state = State
    T.status = status
    T.console = console
    T.session = function() return Session end
    T.creatures, T.items, T.chests, T.crime = Creatures, Items, Chests, Crime
    T.reload = reloadConfig
    T.config = function() return Config, CreatureCfg, ItemCfg, ChestCfg, CrimeCfg end
    T.world, T.util = World, U
    T.life = function() return Life end
    T.statePath = function() return StatePath end
    T.save = saveState
end
