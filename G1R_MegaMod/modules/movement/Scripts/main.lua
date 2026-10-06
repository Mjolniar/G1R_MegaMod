-- ============================================================================
-- Movement speeds (module movement of G1R_MegaMod) - Gothic 1 Remake, UE4SS Lua
--
-- How fast the hero walks and runs, how fast he swims, and how fast the
-- scavenger he rides runs.
--
-- On foot: the hero's own speed factor (SpeedModifier of his movement
-- attributes, MV6) times the multiplier.
--
-- Swimming: the hero's three swimming speeds (slow, normal, fast) are a table
-- of the game's script class LocomotionSpeedSettings_Swim_Laying_Player, which
-- the game takes from that class's default object (MV1). The module multiplies
-- them there.
--
-- The scavenger: its own speed factor (SpeedModifier of its movement
-- attributes, MV3) times the multiplier. It is found through the game's lookup
-- of a character by its unique name, as the module mount finds it.
--
-- What the module changed is put back when a setting goes back to 1.00 or the
-- module is switched off. A value somebody else set since (neither the game's
-- own nor the module's) is left alone - said once - and taken as the game's
-- own at the next change of the setting (swimming) - the speed factors of the
-- hero and the scavenger are the 1.0 of their character definitions (MV5,
-- MV6). Whether the game uses a changed swimming table at once is not known (MV2).
--
-- Settings: schema.lua describes them, config.lua holds them; the settings
-- app and the in-game mod menu change them while the game runs.
-- ============================================================================

local VERSION = "1.1.0"
local TAG = "G1R_Movement"

local KIT, SETTINGS = G1R_KIT, G1R_SETTINGS
-- Diagnostics handle of the loader; nil when the diagnostics are off, and then
-- nothing behind `if DIAG` runs.
local DIAG = G1R_DIAG
if type(KIT) ~= "table" or type(SETTINGS) ~= "table" then
    print("[" .. TAG .. "] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started" .. string.char(10))
    return
end
if DIAG then pcall(DIAG.version, VERSION) end

local pcall, type, tostring, ipairs, pairs = pcall, type, tostring, ipairs, pairs
local abs, floor = math.abs, math.floor
local clock = KIT.clock
local L = KIT.logger(TAG, print)
local log = L.log

local SCRIPT_DIR = (function()
    local ok, src = pcall(function() return debug.getinfo(1, "S").source end)
    if ok and type(src) == "string" then
        local p = src:gsub("^@", ""):gsub(string.char(92), "/")
        local d = p:match("^(.*/)[^/]+$")
        if d then return d end
    end
    return "./"
end)()

-- ---------------------------------------------------------------------------
-- What the module knows about the game (dev/facts/movement.md)
-- ---------------------------------------------------------------------------
local SWIM_CLASS = "LocomotionSpeedSettings_Swim_Laying_Player"   -- its default object holds the swimming speeds (MV1)
local SWIM_TABLE = "m_Speeds"                                     -- Map<EWalkSpeed, float> (MV1)
local MOUNT_NAME = "Scavenger_Adult_Rideable"                     -- the scavenger's unique name (module mount, M1)
local NPC_STATE_DEFAULT = "GothicNPCState"                        -- answers FindNPCByUniqueName(controller, name) (mount M2)
local SPEED_PART, SPEED = "Movement", "SpeedModifier"             -- AttributeSet_Movement.SpeedModifier (MV3)
local OWN = 1.0             -- the speed factor the character definitions of the scavenger and of the hero give (MV3, MV6)
local LOOK_EVERY = 2.0      -- seconds between two looks while there is something to do
local TRIES = 3             -- failures in a row before a part is given up for this run
local SAME = 0.0005         -- two speeds closer than this are the same

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local Settings, problem = SETTINGS.open({ module = "movement", dir = SCRIPT_DIR, log = log })
if not Settings then
    log("the settings could not be set up (" .. tostring(problem) .. "); not started")
    return
end
local Cfg = Settings.values

-- ---------------------------------------------------------------------------
-- State of this run. Per part: own = the game's own value(s), applied = the
-- multiplier the module wrote (nil: the game's own values are in place),
-- left = somebody else changed them since, retake = take what is there as the
-- game's own at the next look (a setting changed).
-- ---------------------------------------------------------------------------
local S = {
    lookAt = -1e9,
    swim = { own = nil, applied = nil, left = false, retake = false, fails = 0, off = false },
    mount = { own = nil, applied = nil, left = false, retake = false, fails = 0, off = false, set = nil },
    hero = { own = nil, applied = nil, left = false, retake = false, fails = 0, off = false, set = nil },
    lookupFails = 0, lookupOff = false,
    changes = 0, putBack = 0,
}
local Noted = {}
local function note(key, value, detail)
    if DIAG and Noted[key] ~= value then
        Noted[key] = value
        DIAG.note(key, value, detail)
    end
end
local function firstLine(text) return (tostring(text):match("^[^\r\n]*") or "") end
local function same(a, b) return abs(a - b) < SAME end
local function wanted(part)
    if not Cfg.Enabled then return 1 end
    if part == "swim" then return Cfg.SwimSpeed end
    return part == "hero" and Cfg.HeroSpeed or Cfg.MountSpeed
end
local function factor(m) return ("x%.2f"):format(m) end

-- A failure of a part: after TRIES in a row the part is given up for this run (said once, noted).
local function failed(p, key, what, why)
    p.fails = p.fails + 1
    if p.fails >= TRIES then
        p.off = true
        L.once(key, what .. " (" .. tostring(why) .. "); left as the game has it for this run")
        note(key, "fails", why)
    end
end
local function done(p, m, before, after, word)
    p.applied = (not same(m, 1)) and m or nil
    if p.applied then S.changes = S.changes + 1 else S.putBack = S.putBack + 1 end
    if Cfg.LogChanges then log(("%s %s -> %s"):format(word, before, after)) end
end

-- ---------------------------------------------------------------------------
-- Swimming: the table of the class's default object
-- ---------------------------------------------------------------------------
-- Calls visit(key, value) for every entry; the whole callback inside pcall (an
-- error that leaves the callback of ForEach is not caught around the walk,
-- melee M12). The key: the entry's EWalkSpeed number, else its place.
-- Returns the number of entries, or nil and what went wrong.
local function walk(map, visit)
    local count, trouble = 0, nil
    local ok, err = pcall(function()
        map:ForEach(function(key, value)
            count = count + 1
            local fine, why = pcall(function() visit(KIT.number(KIT.unwrap(key)) or count, value) end)
            if not fine and trouble == nil then trouble = firstLine(why) end
        end)
    end)
    if not ok then return nil, firstLine(err) end
    if trouble then return nil, trouble end
    return count
end
local function swimTable()
    local cdo = KIT.findDefault(SWIM_CLASS, "Angelscript")
    if not cdo then return nil, "the class " .. SWIM_CLASS .. " was not found" end
    local map = KIT.get(cdo, SWIM_TABLE)
    if map == nil then return nil, SWIM_TABLE .. " cannot be read" end
    return map
end
-- The speeds the table holds, { [key] = speed }, or nil and why.
local function readSwim(map)
    local speeds, n = {}, 0
    local count, why = walk(map, function(key, value)
        local v = KIT.number(KIT.unwrap(value))
        if v == nil then error("an entry is not a number") end
        speeds[key] = v
        n = n + 1
    end)
    if not count then return nil, why end
    if n == 0 then return nil, "the table is empty" end
    return speeds
end
local function sameSpeeds(a, b)
    for k, v in pairs(a) do
        if b[k] == nil or not same(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end
local function times(speeds, m)
    local out = {}
    for k, v in pairs(speeds) do out[k] = v * m end
    return out
end
-- "100 / 150 / 220", by key
local function speedText(speeds)
    local keys, parts = {}, {}
    for k in pairs(speeds) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = ("%g"):format(floor(speeds[k] * 10 + 0.5) / 10) end
    return table.concat(parts, " / ")
end
local function writeSwim(map, speeds)
    local count, why = walk(map, function(key, value)
        local v = speeds[key]
        if v ~= nil then value:set(v) end
    end)
    if not count then return false, why end
    local back, why2 = readSwim(map)
    if not back then return false, why2 end
    if not sameSpeeds(back, speeds) then return false, "the table did not keep the new values" end
    return true
end

local function swimLook()
    local p, m = S.swim, wanted("swim")
    if p.off or (same(m, 1) and p.applied == nil) then return end
    local map, why = swimTable()
    local now
    if map then now, why = readSwim(map) end
    if not now then
        note("movement.swim_table", map and "not readable" or "not found", why)
        return failed(p, "movement.swim_table", "the swimming speeds of the game cannot be read", why)
    end
    if p.own == nil then p.own = now end
    local ours = p.applied and times(p.own, p.applied) or p.own
    if p.retake then
        p.retake = false
        if not sameSpeeds(now, ours) and not sameSpeeds(now, p.own) then p.own, p.applied, ours, p.left = now, nil, now, false end
    end
    note("movement.swim_table", "found", speedText(p.own))
    if not sameSpeeds(now, ours) and not sameSpeeds(now, p.own) then
        -- somebody else set other values since: left alone (taken as the game's own at the next change of the setting)
        if not p.left then
            p.left = true
            L.once("swim:left", "the swimming speeds were changed by something else (" .. speedText(now) .. "); left as they are")
            note("movement.left_alone", "swimming", speedText(now))
        end
        return
    end
    local target = times(p.own, m)
    if sameSpeeds(now, target) then
        p.applied, p.fails = (not same(m, 1)) and m or nil, 0
        return
    end
    local ok, why2 = writeSwim(map, target)
    if not ok then
        note("movement.swim_write", "fails", why2)
        return failed(p, "movement.swim_write", "the swimming speeds cannot be written", why2)
    end
    p.fails = 0                         -- (only a part that is where it should be starts its count of failures anew)
    note("movement.swim_write", "works")
    done(p, m, speedText(now), speedText(target), "swimming speeds")
end

-- ---------------------------------------------------------------------------
-- The scavenger: its movement attributes
-- ---------------------------------------------------------------------------
local Names = {}
local function nameOf(text)
    local n = Names[text]
    if n == nil then
        local ok, made = pcall(function() return FName(text) end)
        n = (ok and made ~= nil) and made or false
        Names[text] = n
    end
    return n or nil
end
-- The scavenger's character state, through the game's own lookup by unique
-- name (mount M2), or nil and why.
local function mountState()
    if S.lookupOff then return nil, "lookup given up" end
    local ctrl = KIT.controller()
    if not ctrl then return nil, "no hero" end
    local cdo, name = KIT.findDefault(NPC_STATE_DEFAULT, "G1R"), nameOf(MOUNT_NAME)
    if not cdo or not name then
        S.lookupOff = true
        L.once("lookup", "the game's lookup of characters by name was not found; the scavenger's speed is left as the game has it")
        note("movement.lookup", "not available", cdo and "no FName" or "GothicNPCState default object not found")
        return nil, "lookup not available"
    end
    local ok, st = KIT.try(cdo, "FindNPCByUniqueName", ctrl, name)
    if not ok then
        S.lookupFails = S.lookupFails + 1
        if S.lookupFails >= TRIES then
            S.lookupOff = true
            L.once("lookup", "the game's lookup of characters by name fails (" .. firstLine(st) .. "); the scavenger's speed is left as the game has it")
            note("movement.lookup", "fails", firstLine(st))
        end
        return nil, "lookup failed"
    end
    S.lookupFails = 0
    note("movement.lookup", "works")
    if not KIT.valid(st) then return nil, "not in the world" end
    return st
end

-- A character's own speed factor (SpeedModifier of its movement attributes) is the 1.0 its character definition
-- gives it (MV3, MV6); the module sets that times the multiplier m, for the part p of state st. who: the words and
-- keys of that character.
-- New attributes (a summon of the scavenger, a loaded save, another map) or a changed setting: whatever is there is
-- the game's own value or one the module wrote before - a summon carries the written value over, a save may keep it -
-- and never a value to multiply again (version 1.0.0 did that: the scavenger got faster with every summon). Between
-- those, a value that is neither the game's own nor the module's was set by something else: left alone, said once.
local function factorLook(p, m, st, who)
    local set, setName = KIT.attributeSetOf(st, SPEED_PART)
    if not set then
        note(who.set, "not found", KIT.fullName(st))
        return failed(p, who.set, who.name .. " movement attributes were not found", "no AttributeSet_" .. SPEED_PART)
    end
    local _, base = KIT.readAttribute(set, SPEED)
    if base == nil then
        note(who.set, "not readable", SPEED)
        return failed(p, who.set, who.name .. " speed factor cannot be read", SPEED .. " not readable")
    end
    note(who.set, "found", ("%.2f"):format(base))
    p.own = OWN
    local fresh = setName ~= p.set or p.retake
    p.set, p.retake = setName, false
    if fresh then p.left = false end
    if not fresh and not same(base, OWN * (p.applied or 1)) and not same(base, OWN) then
        if not p.left then
            p.left = true
            L.once(who.part .. ":left", ("%s speed factor was changed by something else (%.2f); left as it is"):format(who.name, base))
            note("movement.left_alone", who.alone, ("%.2f"):format(base))
        end
        return
    end
    local target = OWN * m
    if same(base, target) then
        p.applied, p.fails = (not same(m, 1)) and m or nil, 0
        return
    end
    local ok, why = KIT.writeAttribute(set, SPEED, target)
    if not ok then
        note(who.write, "fails", why)
        return failed(p, who.write, who.name .. " speed factor cannot be written", why)
    end
    p.fails = 0
    note(who.write, "works")
    done(p, m, ("%.2f"):format(base), ("%.2f"):format(target), who.name .. " speed factor")
end
local MOUNT = { part = "mount", name = "the scavenger's", alone = "scavenger", set = "movement.mount_set", write = "movement.mount_write" }
local HERO = { part = "hero", name = "the hero's", alone = "hero", set = "movement.hero_set", write = "movement.hero_write" }
local function mountLook()
    local p, m = S.mount, wanted("mount")
    if p.off or (same(m, 1) and p.applied == nil) then return end
    local st = mountState()
    if not st then return end           -- not there now (not yours yet, another map): looked at again later
    factorLook(p, m, st, MOUNT)
end
local function heroLook()
    local p, m = S.hero, wanted("hero")
    if p.off or (same(m, 1) and p.applied == nil) then return end
    local st = KIT.playerState()
    if not st then return end           -- no hero now (a menu, a map load): looked at again later
    factorLook(p, m, st, HERO)
end

-- ---------------------------------------------------------------------------
-- The loop
-- ---------------------------------------------------------------------------
local function idle()
    return same(wanted("swim"), 1) and S.swim.applied == nil and same(wanted("mount"), 1) and S.mount.applied == nil
        and same(wanted("hero"), 1) and S.hero.applied == nil
end
local function tick()
    if KIT.loading() then return end
    if idle() then return end
    local now = clock()
    if now < S.lookAt then return end
    S.lookAt = now + LOOK_EVERY
    heroLook()
    swimLook()
    mountLook()
end

-- ---------------------------------------------------------------------------
-- Status (console, the loader's reports), console words, settings
-- ---------------------------------------------------------------------------
local function summary()
    if not Cfg.Enabled then return "switched off" end
    if same(Cfg.HeroSpeed, 1) and same(Cfg.SwimSpeed, 1) and same(Cfg.MountSpeed, 1) then return "walking, swimming and riding as the game has them" end
    return ("on foot %s, swimming %s, your scavenger %s"):format(factor(Cfg.HeroSpeed), factor(Cfg.SwimSpeed), factor(Cfg.MountSpeed))
end
local function statusLines()
    local lines = { ("v%s | %s"):format(VERSION, summary()) }
    local sw, mo, he = S.swim, S.mount, S.hero
    if he.own then
        lines[#lines + 1] = ("the hero's own speed factor: %.2f%s"):format(he.own, he.applied and (", now " .. ("%.2f"):format(he.own * he.applied)) or "")
    end
    if sw.own then
        lines[#lines + 1] = "swimming speeds of the game: " .. speedText(sw.own)
            .. (sw.applied and (", now " .. speedText(times(sw.own, sw.applied))) or "")
    end
    if mo.own then
        lines[#lines + 1] = ("the scavenger's own speed factor: %.2f%s"):format(mo.own, mo.applied and (", now " .. ("%.2f"):format(mo.own * mo.applied)) or "")
    end
    lines[#lines + 1] = ("speeds changed: %d; put back: %d"):format(S.changes, S.putBack)
    if he.left then lines[#lines + 1] = "the hero's speed factor was changed by something else: left as it is" end
    if sw.left then lines[#lines + 1] = "the swimming speeds were changed by something else: left as they are" end
    if mo.left then lines[#lines + 1] = "the scavenger's speed factor was changed by something else: left as it is" end
    if he.off then lines[#lines + 1] = "the hero on foot: given up for this run" end
    if sw.off then lines[#lines + 1] = "swimming: given up for this run" end
    if mo.off then lines[#lines + 1] = "the scavenger: given up for this run" end
    if S.lookupOff then lines[#lines + 1] = "the scavenger cannot be looked up in this run" end
    return lines
end

-- movement           status
-- movement reload    read config.lua now
local function console(fullCommand, params, device)
    local args = {}
    if type(params) == "table" then
        for _, p in ipairs(params) do args[#args + 1] = tostring(p) end
    elseif type(fullCommand) == "string" then
        for w in fullCommand:gmatch("%S+") do args[#args + 1] = w end
        table.remove(args, 1)
    end
    local lines
    if (args[1] or ""):lower() == "reload" then
        local ok, why = Settings:reload(true)
        lines = { ok and ("settings read: " .. summary()) or ("settings not read: " .. tostring(why)) }
    else
        lines = statusLines()
    end
    for _, l in ipairs(lines) do
        log(l)
        if device ~= nil then pcall(function() device:Log("[" .. TAG .. "] " .. l) end) end
    end
    return true
end

Settings.onChange = function(_, changed, why)
    -- looked at at the next update; what is there now counts as the game's own if it is neither the game's nor ours
    S.lookAt = -1e9
    S.swim.retake, S.mount.retake, S.hero.retake = true, true, true
    log(("settings changed (%s): %s"):format(why == "menu" and "in-game menu" or (why == "file" and "config.lua" or tostring(why)), summary()))
end

-- ---------------------------------------------------------------------------
-- Registration (each exactly once)
-- ---------------------------------------------------------------------------
KIT.onWorldChange(function() S.lookAt = -1e9 end)
for _, name in ipairs({ "movement", "g1r_movement" }) do
    if type(RegisterConsoleCommandHandler) == "function" then
        pcall(RegisterConsoleCommandHandler, name, console)
    end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; the speeds are left as the game has them.")
else
    LoopInGameThreadWithDelay(250, function()
        local ok, err = pcall(tick)
        if not ok then L.once("tick:" .. tostring(err), "update error: " .. tostring(err)) end
    end)
end

log(("v%s loaded: %s"):format(VERSION, summary()))

if DIAG then
    pcall(function()
        DIAG.status(statusLines)
        DIAG.dump(function()
            local sw, mo, he = S.swim, S.mount, S.hero
            return {
                version = VERSION, enabled = Cfg.Enabled, swim_speed = Cfg.SwimSpeed, mount_speed = Cfg.MountSpeed, hero_speed = Cfg.HeroSpeed,
                hero_own = he.own, hero_applied = he.applied, hero_left = he.left, hero_off = he.off,
                log_changes = Cfg.LogChanges,
                swim_own = sw.own and speedText(sw.own) or nil, swim_applied = sw.applied, swim_left = sw.left, swim_off = sw.off,
                mount_own = mo.own, mount_applied = mo.applied, mount_left = mo.left, mount_off = mo.off,
                lookup_works = not S.lookupOff, changes = S.changes, put_back = S.putBack,
            }
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "MOVEMENT_TEST")) == "table" then
    local T = rawget(_G, "MOVEMENT_TEST")
    T.state, T.console, T.status, T.tick, T.settings = S, console, statusLines, tick, Settings
end
