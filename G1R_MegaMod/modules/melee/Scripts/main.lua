-- ============================================================================
-- Melee clean-ups (module melee of G1R_MegaMod) - Gothic 1 Remake, UE4SS Lua
--
-- Three things that shape how a melee blow looks and feels, each a setting:
--
--   FlowHelper  the game's own option "fake sloppy combos" (close combat flow
--               helper): pressing the same attack direction again while a
--               swing ends starts a mirrored follow-up swing instead of the
--               same swing again. "game" leaves it to the game's menu, "off"
--               and "on" set it.
--   HitStop     how long both fighters stand still when a blow lands, in
--               percent of the game's own time (100 = unchanged, 0 = none).
--   HitShake    the camera's jolt when a blow lands (true = as the game has
--               it, false = none for melee blows).
--
-- How it works. Nothing of the hero is changed; the module changes what the
-- game itself goes by, and puts it back.
--   * The flow helper is a yes/no value of the game's settings, which the
--     game keeps per profile. The module sets it the way the game's options
--     menu does (the option object's own SetValue: the game stores it and its
--     menu shows it); when that does not work, the value itself is written.
--     Every few seconds it looks whether the value is still as set - the game
--     puts the profile's value in when a save is loaded, and the player can
--     change it in the game's menu - and sets it again. What the game had
--     before is remembered per profile and put back when the setting returns
--     to "game".
--   * Hit stop and camera shake are numbers and class names in four tables of
--     one object (the default object of the game's script class
--     GenericMeleeFeedback, which every melee weapon names). The game's
--     damage script reads them at every blow. The module first reads a whole
--     table and remembers what the game has in it, then writes "the game's
--     value x percent" (never a multiple of its own value), then reads
--     everything back, and looks again now and then and after a map load.
--     Entries are never added or removed: a blow whose kind has no entry
--     freezes for more than a second. A table that cannot be read, written or
--     read back as expected gets the game's values back and is left alone.
--   * Which tables may hold values of the module is also kept in a UE4SS
--     shared variable: a run of the Lua mods that finds values of an earlier
--     run in a table (the mods were reloaded while the game ran) does not take
--     them for the game's own; it leaves that table alone.
--
-- The module only changes things while a game runs (the hero's attributes
-- are there), not while a map loads or the game is paused. Putting back needs
-- no hero. With every setting at its neutral value (game, 100, true) or the
-- module switched off, and nothing left to put back, it does not look at the
-- game at all.
--
-- Settings: schema.lua describes them, config.lua holds them; the settings
-- app and the in-game mod menu change them while the game runs.
-- ============================================================================

local VERSION = "1.0.0"
local TAG = "G1R_Melee"

local KIT, SETTINGS = G1R_KIT, G1R_SETTINGS
-- Diagnostics handle of the loader; nil when the diagnostics are off, and then
-- nothing behind `if DIAG` runs.
local DIAG = G1R_DIAG
if type(KIT) ~= "table" or type(SETTINGS) ~= "table" then
    print("[" .. TAG .. "] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started\n")
    return
end
if DIAG then pcall(DIAG.version, VERSION) end

local pcall, type, tostring, ipairs, pairs, next, error = pcall, type, tostring, ipairs, pairs, next, error
local abs, max, floor = math.abs, math.max, math.floor
local concat, sort = table.concat, table.sort
local clock = KIT.clock
local L = KIT.logger(TAG, print)
local log = L.log

local SCRIPT_DIR = (function()
    local ok, src = pcall(function() return debug.getinfo(1, "S").source end)
    if ok and type(src) == "string" then
        local p = src:gsub("^@", ""):gsub("\\", "/")
        local d = p:match("^(.*/)[^/]+$")
        if d then return d end
    end
    return "./"
end)()

-- ---------------------------------------------------------------------------
-- What the module knows about the game (dev/facts/melee.md)
-- ---------------------------------------------------------------------------
local OPTION = "SettingObject_Bool_EnableFakeSloppyCombos"     -- /Script/G1R: the game's option object; GetValue(), SetValue(bool)
local USER_SETTINGS = "GothicGameUserSettings"                  -- /Script/G1R: GetGothicGameUserSettings() -> the settings object
local FLAG = "m_FakeSloppyCombos"                               -- the yes/no value in that object which the fight code reads
local PROFILES = "PersistentDataSubsystem"                      -- m_CurrentProfileId: the game keeps the option per profile
local FEEDBACK = "GenericMeleeFeedback"                         -- /Script/Angelscript: script class whose default object holds the tables
local FEEDBACK_OBJECT = "Default__" .. FEEDBACK                 -- the object name of that default object
local NO_SHAKE = "MatineeCameraShake_None"                      -- the game's own class for "no shake" (it stands in some entries)
local GUARD = "G1R_Melee:tables"                                -- UE4SS shared variable: the tables that may hold values of the module
local STALE = "the Lua mods were reloaded while values of the mod were in it"
local TRIES = 3                 -- failures in a row before a way of doing something is given up
local AGAIN = 5                 -- looks in a row at which the flow helper had to be set again before it is left alone
local SOON = -math.huge         -- a clock value that has passed: "at the next turn of the loop"

-- ---------------------------------------------------------------------------
-- State of this run
-- ---------------------------------------------------------------------------
local S = {
    nextLook = SOON,            -- clock value of the next look at the game
    verifyAt = SOON,            -- clock value from which the tables are read again
    hero = false,               -- a game was running at the last look
    halt = nil,                 -- why the last look did nothing
    looks = 0, pausedLooks = 0,
    changes = 0,                -- looks that changed something in the game
    last = nil,                 -- what the last of them changed
    flow = {
        direct = false,         -- FlowMethod "auto" has fallen back to the settings object for this run
        fails = 0,              -- failures in a row of the way in use
        again = 0,              -- looks in a row at which the option had to be set again (something switches it back)
        off = nil,              -- why the flow helper is left alone for now (nil = it is not)
        way = nil,              -- the way that worked last
        value = nil,            -- the game's value at the last look
        before = {},            -- profile -> the value the game had before the module set it
        sets = 0, backs = 0,
        called = {},            -- way -> its write has been called in this run
    },
    feedback = nil,             -- full name of the feedback object while it is in use
    noFeedback = false,         -- the feedback object was not found: hit stop and camera shake cannot be changed in this run
    mem = {},                   -- table name -> what the game had in it, while values of the module may be in there
    broken = {},                -- table name -> why it is left alone for now
    stale = {},                 -- table name -> why it is left alone for the whole run: an earlier run of the Lua mods left its values in it
    guard = nil,                -- the shared variable as the module last wrote or found it
    count = {},                 -- table name -> entries seen in it
    none = nil,                 -- the "no shake" class: { class, name, from }; false = not found
    written = 0, putBack = 0,   -- values written into the tables / written back
    walked = false,             -- a table has been walked in this run
}
local Noted = {}
local function note(key, value, detail)
    if DIAG and Noted[key] ~= value then
        Noted[key] = value
        DIAG.note(key, value, detail)
    end
end

-- The first line of an error text, without the "file:line:" in front (the path of the game folder says nothing
-- about the problem and does not belong into a log).
local function reason(text) return ((tostring(text):match("^[^\r\n]*") or ""):gsub("^.-:%d+: ", "")) end
local function onOff(v) return v and "on" or "off" end
-- A number as short as it can be written: 0.05, 0.025, 2
local function num(v) return (("%.4f"):format(v):gsub("%.?0+$", "")) end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local Settings, problem = SETTINGS.open({ module = "melee", dir = SCRIPT_DIR, log = log })
if not Settings then
    log("the settings could not be set up (" .. tostring(problem) .. "); not started")
    return
end
local Cfg = Settings.values

-- What the settings ask of the game: the flow helper ("game" / "off" / "on"),
-- the hit stop in percent, the camera shake. All neutral while the module is
-- switched off.
local function wanted()
    if not Cfg.Enabled then return "game", 100, true end         -- the neutral values (STOP.rest, SHAKE.rest below)
    return Cfg.FlowHelper, Cfg.HitStop, Cfg.HitShake
end
-- The tables of the feedback object, by kind (filled in further down).
local STOP, SHAKE
-- Something of the module's is still in the game (what the game had is remembered).
local function pending()
    return next(S.flow.before) ~= nil or next(S.mem) ~= nil
end
-- A table holds values of the module that can be looked after or put back (one that is left alone cannot).
local function inHand()
    for name in pairs(S.mem) do
        if S.broken[name] == nil then return true end
    end
    return false
end
-- Is there something to set and a way of setting it? Why not, when it is wanted and cannot be done.
local function flowBusy(flow)
    if flow == "game" then return false end
    return S.flow.off == nil, S.flow.off
end
local function kindBusy(kind, want)
    if want == kind.rest then return false end
    if S.noFeedback then return false, "the game's feedback object was not found" end
    local blocked = kind.blocked(want)
    if blocked then return false, blocked end
    for _, name in ipairs(kind.tables) do
        if S.broken[name] ~= nil then return false, name .. ": " .. S.broken[name] end
    end
    return true
end
-- True while there is nothing to do at all: the game is not looked at.
local function idle()
    local flow, stop, shake = wanted()
    if flowBusy(flow) or kindBusy(STOP, stop) or kindBusy(SHAKE, shake) then return false end
    if flow == "game" and next(S.flow.before) ~= nil then return false end      -- the flow helper is to be put back
    return not inHand()
end
local function summary()
    if not Cfg.Enabled then return "switched off in the settings" end
    local flow, stop, shake = wanted()
    local parts = {}
    if flow ~= "game" then parts[#parts + 1] = "flow helper " .. flow end
    if stop ~= 100 then parts[#parts + 1] = ("hit stop %d %%"):format(stop) end
    if not shake then parts[#parts + 1] = "no camera shake on hits" end
    if #parts == 0 then return "nothing to change (flow helper left to the game, hit stop 100 %, camera shake on hits)" end
    return concat(parts, ", ")
end

-- ---------------------------------------------------------------------------
-- The flow helper: the game's own option, two ways of reaching it. Each way
-- reads the value (true / false, or nil and why not) and writes it (true, or
-- false and why not).
-- ---------------------------------------------------------------------------
local function settingsObject()
    local class = KIT.findDefault(USER_SETTINGS, "G1R")
    if not class then return nil, "the game's settings class was not found" end
    local ok, object = KIT.try(class, "GetGothicGameUserSettings")
    if ok and KIT.valid(object) then return object end
    return nil, ok and "the game has no settings object" or reason(object)
end
local WAYS = {
    option = {
        name = "option object", text = "the game's option object",
        read = function()
            local option = KIT.findDefault(OPTION, "G1R")
            if not option then return nil, "the game's option object was not found" end
            local ok, value = KIT.try(option, "GetValue")
            if ok and type(value) == "boolean" then return value end
            return nil, ok and ("GetValue answered " .. tostring(value)) or reason(value)
        end,
        write = function(value)         -- (only called after a read that worked)
            local ok, err = KIT.try(KIT.findDefault(OPTION, "G1R"), "SetValue", value)
            if ok then return true end
            return false, reason(err)
        end,
    },
    direct = {
        name = "settings object", text = "the game's settings object",
        read = function()
            local object, why = settingsObject()
            if not object then return nil, why end
            local value = KIT.get(object, FLAG)
            if type(value) == "boolean" then return value end
            return nil, FLAG .. " could not be read"
        end,
        write = function(value)         -- (only called after a read that worked)
            local object = settingsObject()
            if pcall(function() object[FLAG] = value end) then return true end
            return false, "the write raised an error"
        end,
    },
}
-- The way in use now.
local function flowWay()
    if Cfg.FlowMethod == "direct" or (Cfg.FlowMethod == "auto" and S.flow.direct) then return WAYS.direct end
    return WAYS.option
end
-- The profile the game is in, as text ("?" when that cannot be read).
local function profile()
    local id = KIT.number(KIT.get(KIT.subsystem("instance", PROFILES, "G1R"), "m_CurrentProfileId"))
    if id == nil then
        note("melee.profile", "not readable")
        return "?"
    end
    id = floor(id + 0.5)
    note("melee.profile", id)
    return tostring(id)
end

-- A way did not work: after three times in a row the other way is taken
-- (FlowMethod "auto"), or the flow helper is left alone until its setting changes.
local function flowFailed(way, what, why)
    local F = S.flow
    F.fails = F.fails + 1
    L.once("flow:" .. way.name .. ":" .. what, ("the flow helper could not be %s through %s (%s)"):format(what, way.text, tostring(why)))
    if F.fails < TRIES then return end
    F.fails = 0
    if way == WAYS.option and Cfg.FlowMethod == "auto" then
        F.direct = true
        L.once("flow:direct", "from now on the flow helper is set in the game's settings object itself; the game does not store that value in the profile")
        return
    end
    F.off = tostring(why)
    note("melee.flow.way", "none", F.off)
    L.once("flow:off", "the flow helper is left as the game has it: it cannot be set in this game (" .. F.off .. ")")
end

-- Writes the value and reads it back. Returns whether the game has it now,
-- why not, and what it has (nil when that cannot be read).
local function flowWrite(way, value)
    -- the first call of a way in a run is announced on disk before it is made: should the game go down
    -- inside it, the diagnostics end with that line
    local first = DIAG ~= nil and not S.flow.called[way.name]
    S.flow.called[way.name] = true
    if first then DIAG.crumb("first write of the flow helper through " .. way.text) end
    local ok, why = way.write(value)
    local now = way.read()
    if first then DIAG.event("first write of the flow helper returned: " .. (ok and "no error" or tostring(why))) end
    if now == value then return true, nil, now end
    return false, ok and "the value did not stay" or why, now
end

-- The setting is "off" or "on": the game's option is looked at and set when it differs.
local function flowSet(want, changes)
    local F = S.flow
    local way = flowWay()
    local value, why = way.read()
    if value == nil then return flowFailed(way, "read", why) end
    if Noted["melee.flow.game_value"] == nil then note("melee.flow.game_value", onOff(value)) end
    F.value = value
    if value == want then
        F.fails, F.way, F.again = 0, way.name, 0
        note("melee.flow.way", way.name)
        return
    end
    -- the game has another value: its own (a profile was loaded, or the player changed it in the game's menu).
    -- The first one seen in a profile is what is put back later.
    local id = profile()
    local known = F.before[id] ~= nil
    if known then
        -- set before in this profile, and the game has its own value again. Once is the player in the game's
        -- menu; look after look it is something that keeps switching it back. Every set stores the profile and
        -- writes a line, so that is not kept up: the option is left as the game has it until the setting changes.
        F.again = F.again + 1
        if F.again > AGAIN then
            F.off, F.again, F.before[id] = "something keeps switching it back", 0, nil      -- the game's own value stands: nothing to put back
            note("melee.flow.way", "none", F.off)
            log(("the flow helper was switched back %d times in a row right after the mod set it: it is left as the game has it now (%s). Choosing FlowHelper anew tries again."):format(AGAIN, onOff(value)))
            return
        end
    else
        F.before[id] = value
    end
    local ok, problemText, now = flowWrite(way, want)
    if not ok then
        if not known and now ~= nil then F.before[id] = nil end     -- still the game's own value: nothing to put back
        note("melee.flow.write", "failed", problemText)
        return flowFailed(way, "set", problemText)
    end
    F.fails, F.way, F.value, F.sets = 0, way.name, want, F.sets + 1
    note("melee.flow.way", way.name)
    note("melee.flow.write", "ok")
    changes[#changes + 1] = "flow helper " .. onOff(want)
end

-- The setting is "game" again (or the module is off): what the game had in
-- this profile is put back.
local function flowBack(changes)
    local F = S.flow
    local id = profile()
    -- the option of another profile can only be written while that profile is in use: it stays as set
    local others = {}
    for other in pairs(F.before) do
        if other ~= id then others[#others + 1] = other end
    end
    sort(others)
    for _, other in ipairs(others) do
        log(("the flow helper of profile %s stays as the mod set it (the game had it %s); the game's own menu changes it"):format(other, onOff(F.before[other])))
        F.before[other] = nil
    end
    local before = F.before[id]
    if before == nil then return end
    if F.off then
        log(("the flow helper could not be put back to %s (%s); the game's own menu changes it"):format(onOff(before), F.off))
        F.before[id] = nil
        return
    end
    local way = flowWay()
    local value, why = way.read()
    if value == nil then return flowFailed(way, "read", why) end
    F.value = value
    if value ~= before then
        local ok, problemText = flowWrite(way, before)
        if not ok then
            note("melee.flow.write", "failed", problemText)
            return flowFailed(way, "put back", problemText)
        end
        F.value, F.backs = before, F.backs + 1
        changes[#changes + 1] = "flow helper as the game had it (" .. onOff(before) .. ")"
    end
    F.before[id] = nil
end

-- ---------------------------------------------------------------------------
-- Hit stop and camera shake: the tables of the feedback object
-- ---------------------------------------------------------------------------
-- "Class /Script/Angelscript.MatineeCameraShake_None" -> "MatineeCameraShake_None"
local function className(class)
    local name = KIT.fullName(class)
    return name and name:match("([%w_]+)$") or nil
end
-- The name of an entry's key (a gameplay tag), or nil: "Combat.HitType.Standard" -> "Standard". Read the way the
-- repopulate module reads such keys in the game.
local function tagOf(key)
    local name = KIT.get(KIT.unwrap(key), "TagName")
    if type(name) ~= "string" then          -- a name object: its text
        local ok, text = pcall(function() return name:ToString() end)
        name = ok and text or nil
    end
    if type(name) == "string" and name ~= "" and name ~= "None" then return name:match("([^%.]+)$") end
    return nil
end

-- Calls visit(index, value, key) for every entry of a table of the game.
-- Returns the number of entries, or nil and what went wrong. Nothing leaves
-- the callback of ForEach as an error: in this UE4SS an error there is not
-- caught by a pcall around the walk.
local function walk(map, visit)
    -- the first walk of a run is announced on disk before it is made: should the game go down inside it,
    -- the diagnostics end with that line
    local first = DIAG ~= nil and not S.walked
    S.walked = true
    if first then DIAG.crumb("first walk through a table of the game") end
    local count, trouble = 0, nil
    local ok, err = pcall(function()
        map:ForEach(function(key, value)
            count = count + 1
            local fine, why = pcall(visit, count, value, key)
            if not fine and trouble == nil then trouble = reason(why) end
        end)
    end)
    if first then DIAG.event("first walk through a table of the game returned: " .. (ok and (count .. " entries") or reason(err))) end
    if not ok then return nil, reason(err) end
    if trouble then return nil, trouble end
    return count
end

-- The two kinds of table. For each: the tables, the values of an entry, how a
-- value is read (what it is compared by, and what is written to put it back),
-- what it should be, how it is written.
STOP = {
    word = "hit stop", tables = { "m_AttackFreezeParams", "m_HitFreezeParams" },
    fields = { "m_FreezeDuration", "m_BlendOutDuration" },
    seen = { "melee.stop.attack", "melee.stop.hit" }, wrote = "melee.stop.write",        -- the notes: what a table held, how writing went
    rest = 100,                 -- the setting that leaves the game's values alone
    blocked = function() return nil end,
    sane = function() return nil end,
    read = function(value, field)
        local seconds = KIT.number(KIT.get(KIT.unwrap(value), field))
        if seconds == nil then error(field .. " of an entry is not a number") end
        return seconds, seconds
    end,
    -- the game keeps these numbers in single precision: what comes back may differ in the last digits
    same = function(a, b) return abs(a - b) <= max(0.000001, abs(b) * 0.0001) end,
    target = function(rec, want)
        local seconds = rec.original * want / 100
        return seconds, seconds
    end,
    write = function(value, field, seconds) KIT.unwrap(value)[field] = seconds end,
    show = function(key) return num(key) end,
}
SHAKE = {
    word = "camera shake on hits", tables = { "m_AttackCameraShakeParams", "m_HitCameraShakeParams" },
    fields = { "class" },
    seen = { "melee.shake.attack", "melee.shake.hit" }, wrote = "melee.shake.write",
    rest = true,
    -- switching the shake off takes the game's class for "no shake"
    blocked = function(want)
        if not want and S.none == false then return "the game's class for no shake (" .. NO_SHAKE .. ") was not found" end
        return nil
    end,
    -- a table of the game names a class in most entries: one that seems to name none was not read properly
    sane = function(mem)
        for _, entry in ipairs(mem.entries) do
            if entry.values.class.original ~= "" then return nil end
        end
        return "no entry names a class"
    end,
    read = function(value)
        local class = KIT.unwrap(value)
        return className(class) or "", class            -- "" = the entry names no class
    end,
    same = function(a, b) return a == b end,
    target = function(rec, want)
        if want or rec.original == "" or rec.original == S.none.name then return rec.original, rec.raw end
        return S.none.name, S.none.class
    end,
    write = function(value, _, class, name)
        if not KIT.valid(class) or className(class) ~= name then error("the class " .. name .. " is gone") end
        value:set(class)
    end,
    show = function(key) return key == "" and "no class" or (key:gsub("^U?MatineeCameraShake_", "")) end,
}

-- The game's class for "no shake": taken from the tables themselves (the game
-- puts it into the entries of hits that do not shake), else found by its name.
local function noShake(object)
    local none = S.none
    if none == false then return nil end                -- looked for and not found
    if none ~= nil then
        if KIT.valid(none.class) and className(none.class) == none.name then return none end
        note("melee.shake.none_class", "gone")
        S.none = false                                  -- it is gone: not looked for again
        return nil
    end
    for _, name in ipairs(SHAKE.tables) do
        local map = none == nil and KIT.get(object, name) or nil
        if map ~= nil then
            walk(map, function(_, value)
                local class = KIT.unwrap(value)
                local found = className(class)
                if none == nil and (found == NO_SHAKE or found == "U" .. NO_SHAKE) then none = { class = class, name = found, from = "from the table" } end
            end)
        end
    end
    if none == nil then
        local class = KIT.findClass(NO_SHAKE, "Angelscript")
        if class then none = { class = class, name = NO_SHAKE, from = "by name" } end
    end
    note("melee.shake.none_class", none and none.from or "not found")
    S.none = none or false
    return none
end

-- One pass over a table. `mem` holds what the game had in each entry: the
-- value met first is taken for it, and what a value should be is always
-- worked out from that - never from a value the module wrote. An entry is
-- known by its place in the walk. write = false: values are only compared.
-- write = true: every value that is not what it should be is written (an
-- entry is only written to after all its values could be read). Returns how
-- many values differ / were written, or nil and what went wrong.
local function pass(map, mem, kind, want, write)
    local fresh = mem.count == nil
    local off = 0
    local count, why = walk(map, function(index, value, key)
        local entry = mem.entries[index]
        if entry == nil then
            if not fresh then
                mem.reshaped = true
                error("the table has more entries than before")
            end
            entry = { label = tagOf(key) or ("#" .. index), values = {} }
            mem.entries[index] = entry
        end
        local todo = {}
        for _, field in ipairs(kind.fields) do
            local now, raw = kind.read(value, field)
            local rec = entry.values[field]
            if rec == nil then
                rec = { original = now, raw = raw }
                entry.values[field] = rec
            end
            local goal, goalRaw = kind.target(rec, want)
            if not kind.same(now, goal) then
                off = off + 1
                todo[#todo + 1] = { field, goalRaw, goal }
            end
        end
        if write then
            for _, t in ipairs(todo) do
                mem.touched = true
                kind.write(value, t[1], t[2], t[3])
            end
        end
    end)
    if count == nil then return nil, why end
    if fresh then
        local odd = count == 0 and "the table is empty" or kind.sane(mem)
        if odd then return nil, odd end
        mem.count = count
    elseif count ~= mem.count then
        mem.reshaped = true         -- which entry is which is no longer known
        return nil, ("the table has %d entries where it had %d"):format(count, mem.count)
    end
    return off
end

-- Brings a table to what is wanted: the whole table is read first (nothing
-- is written into a table that cannot be read or has changed its shape), then
-- written, then read back. Returns the number of values written, or nil and
-- what went wrong.
local function bring(object, name, mem, kind, want)
    local map = KIT.get(object, name)
    if map == nil then return nil, "the table could not be read" end
    local differ, why = pass(map, mem, kind, want, false)
    if differ == nil then return nil, why end
    if differ == 0 then return 0 end
    local written
    written, why = pass(map, mem, kind, want, true)
    if written == nil then return nil, why end
    -- read back in a pass of its own: a value handed out as a copy would look written in the same one
    differ, why = pass(map, mem, kind, want, false)
    if differ == nil then return nil, why end
    if differ > 0 then return nil, ("%d of %d values did not stay"):format(differ, written) end
    return written
end

-- What the game had in a table, for the diagnostics: "Additive 0.033/0.033, Standard 0.05/0.05"
local function describe(mem, kind)
    local parts = {}
    for index = 1, mem.count do
        local entry = mem.entries[index]
        local values = {}
        for _, field in ipairs(kind.fields) do values[#values + 1] = kind.show(entry.values[field].original) end
        parts[#parts + 1] = entry.label .. " " .. concat(values, "/")
    end
    return concat(parts, ", ")
end

-- A table that could not be changed: what the module wrote into it is taken
-- back as far as that can be done (every entry that can be read gets the
-- game's value back, whatever happens at the others; nothing is written into
-- a table that has changed its shape), and the table is left alone until its
-- setting changes. Returns true when values of the module may still be in it.
local function leave(object, name, mem, kind, why)
    local left = mem.touched == true
    if left and not mem.reshaped then
        local map = KIT.get(object, name)
        if map ~= nil and pass(map, mem, kind, kind.rest, true) ~= nil and pass(map, mem, kind, kind.rest, false) == 0 then left = false end
    end
    S.broken[name] = why
    S.mem[name] = left and mem or nil       -- still remembered while the module's values may be in it
    return left
end

-- The tables of one kind brought to what the settings ask. A table that has
-- the game's own values and is to keep them is not read at all; one that is
-- to be changed for the first time is only touched while a game runs. A kind
-- is changed as a whole: when one of its tables cannot be changed, the others
-- get the game's values back. Returns the number of values written, and
-- whether the kind is left alone.
local function sync(object, kind, want, hero)
    local total, failed = 0, false
    local off = kind.blocked(want) ~= nil
    for _, name in ipairs(kind.tables) do off = off or S.broken[name] ~= nil end
    -- one table brought to `goal`; true when that could not be done
    local function one(index, goal)
        local name = kind.tables[index]
        local mem = S.mem[name]
        local neutral = goal == kind.rest
        if S.broken[name] ~= nil or (mem == nil and (neutral or not hero)) then return end
        mem = mem or { entries = {} }
        local written, why = bring(object, name, mem, kind, goal)
        if mem.count ~= nil and S.count[name] == nil then
            S.count[name] = mem.count
            note(kind.seen[index], mem.count, describe(mem, kind))
        end
        if written == nil then
            local text = "%s stays as the game has it: the game's table %s could not be changed (%s); it is as the game had it"
            if leave(object, name, mem, kind, tostring(why)) then
                text = "%s: the game's table %s could not be put back as the game had it (%s); values of the mod may still be in it - restart the game to be safe"
            end
            L.once("table:" .. name .. ":" .. tostring(why), text:format(kind.word, name, tostring(why)))
            note(kind.wrote, "failed", name .. ": " .. tostring(why))
            return true
        end
        S.mem[name] = (not neutral) and mem or nil      -- back as the game had it: nothing left to remember
        total = total + written
        if neutral then
            S.putBack = S.putBack + written
        else
            S.written = S.written + written
            if written > 0 then note(kind.wrote, "ok") end
        end
    end
    for index in ipairs(kind.tables) do
        if one(index, off and kind.rest or want) then off, failed = true, true end
    end
    if failed then
        for index in ipairs(kind.tables) do one(index, kind.rest) end       -- the tables changed before the one that failed
    end
    return total, off
end

-- The feedback object, or nil. It is searched for once per run; a wrapper
-- that no longer names it is not used.
local function feedback()
    local object = KIT.findDefault(FEEDBACK, "Angelscript")
    local name = object and KIT.fullName(object) or nil
    if name ~= nil and name:sub(-#FEEDBACK_OBJECT) == FEEDBACK_OBJECT then
        S.feedback = name
        note("melee.feedback", "found")
        return object
    end
    L.once("feedback", "the game's melee feedback object (" .. FEEDBACK .. ") was not found: hit stop and camera shake stay as the game has them")
    note("melee.feedback", "not found", name)
    -- it is not searched for again in this run; what was remembered belonged to an object that is no longer there
    S.noFeedback, S.feedback, S.mem = true, nil, {}
    return nil
end

-- Hit stop and camera shake brought to what the settings ask (or back).
local function tables(stop, shake, hero, changes)
    local object = feedback()
    if not object then return end
    local written, off = sync(object, STOP, stop, hero)
    if written > 0 and not off then
        changes[#changes + 1] = stop == STOP.rest and "hit stop as the game has it" or ("hit stop %d %%"):format(stop)
    end
    -- no shake takes the game's class for it (looked for while a game runs)
    if not shake and (hero or S.none ~= nil) and not noShake(object) then
        L.once("none", "camera shake on hits stays as the game has it: " .. tostring(SHAKE.blocked(shake)))
    end
    written, off = sync(object, SHAKE, shake, hero)
    if written > 0 and not off then
        changes[#changes + 1] = shake and "camera shake on hits as the game has it" or "no camera shake on hits"
    end
end

-- ---------------------------------------------------------------------------
-- A reload of the Lua mods while the game runs starts this file anew in the
-- same game: what the game had in its tables is forgotten, and what stands in
-- them is the module's. A run that took those values for the game's own would
-- halve a halved hit stop again. So the names of the tables that may hold
-- values of the module are kept in a UE4SS shared variable, which outlives the
-- reload; a run that finds a name there leaves that table alone until the game
-- is restarted (it cannot tell the game's values any more).
-- ---------------------------------------------------------------------------
local function shared(name)
    local ok, v = pcall(function() return ModRef:GetSharedVariable(name) end)
    if ok then return v end
    return nil
end
-- Brings the shared variable up to date: written when the list has changed, not at every look.
local function guard()
    local names = {}
    for _, kind in ipairs({ STOP, SHAKE }) do
        for _, name in ipairs(kind.tables) do
            if S.mem[name] ~= nil or S.stale[name] ~= nil then names[#names + 1] = name end
        end
    end
    local text = concat(names, ",")
    if text == (S.guard or "") then return end
    if pcall(function() ModRef:SetSharedVariable(GUARD, text) end) then S.guard = text end
end

-- ---------------------------------------------------------------------------
-- The loop
-- ---------------------------------------------------------------------------
local function look(now)
    S.looks = S.looks + 1
    if not Cfg.ActWhilePaused and KIT.paused() then
        S.halt, S.pausedLooks = "the game is paused", S.pausedLooks + 1
        return
    end
    local flow, stop, shake = wanted()
    local hero = KIT.attributeSet("Health") ~= nil
    if hero and not S.hero then
        S.verifyAt = SOON                                       -- a game has just begun: what waited for it is done now
        if Cfg.ShowMessage then KIT.prepareNotes() end          -- searches now, not in a fight
    end
    S.hero = hero
    S.halt = (not hero) and "no game is running (the hero was not found)" or nil
    local changes = {}

    if flow == "game" then
        if next(S.flow.before) ~= nil then flowBack(changes) end
    elseif hero and S.flow.off == nil then
        flowSet(flow == "on", changes)
    end

    -- the tables: while something of the module's is in them, or is to be put in (which takes a running game)
    if inHand() or (hero and (kindBusy(STOP, stop) or kindBusy(SHAKE, shake))) then
        if now >= S.verifyAt then
            S.verifyAt = now + Cfg.VerifySeconds
            tables(stop, shake, hero, changes)
        end
    end
    guard()             -- which tables hold values of the module now: kept where a later run of the Lua mods finds it

    if #changes > 0 then
        local text = concat(changes, ", ")
        S.changes, S.last = S.changes + 1, text
        log("changed in the game: " .. text)
        if Cfg.ShowMessage then KIT.notify("Melee: " .. text, "melee") end
    end
end

local function tick()
    if KIT.loading() then return end
    if idle() then return end           -- nothing to do: the game is not looked at
    local now = clock()
    if now < S.nextLook then return end
    S.nextLook = now + Cfg.CheckSeconds - 0.001
    look(now)
end

Settings.onChange = function(_, changed, why)
    log(("settings changed (%s): %s"):format(why == "menu" and "in-game menu" or (why == "file" and "config.lua" or tostring(why)), summary()))
    if not Cfg.ShowMessage then KIT.hideToast("melee") end
    for _, key in ipairs(changed) do
        -- another way of setting, or the feature set anew: what was given up is tried again
        if key == "FlowMethod" or key == "FlowHelper" or key == "Enabled" then S.flow.off, S.flow.fails, S.flow.again = nil, 0, 0 end
        if key == "FlowMethod" then S.flow.direct = false end
        for _, kind in ipairs({ STOP, SHAKE }) do
            if (kind == STOP and key == "HitStop") or (kind == SHAKE and key == "HitShake") or key == "Enabled" then
                -- (a table an earlier run of the Lua mods left changed stays left alone: S.stale)
                for _, name in ipairs(kind.tables) do S.broken[name] = S.stale[name] end
            end
        end
        if key == "HitShake" or key == "Enabled" then
            if S.none == false then S.none = nil end
        end
    end
    S.nextLook, S.verifyAt = SOON, SOON         -- looked at with the next turn of the loop
end

-- ---------------------------------------------------------------------------
-- Status (console command melee, the loader's reports). Built from what the
-- module holds; it does not call into the game.
-- ---------------------------------------------------------------------------
local function kindLine(kind, want, wantText)
    local held, total, some, stuck = 0, 0, false, nil
    for _, name in ipairs(kind.tables) do
        local count = S.count[name] or 0            -- a table in hand has been counted
        total = total + count
        if S.mem[name] ~= nil then
            held, some = held + count, true
            if S.broken[name] ~= nil then stuck = stuck or (name .. ": " .. S.broken[name]) end
        end
    end
    local _, why = kindBusy(kind, want)
    local text
    if stuck then
        text = ("values of the mod may still be in the game (%s) - restart the game to be safe"):format(stuck)
    elseif want == kind.rest then
        text = some and "being put back" or "as the game has it"
    elseif why then
        text = ("wanted %s, but left as the game has it (%s)"):format(wantText, why)
    elseif not some then
        text = ("wanted %s, not looked at yet"):format(wantText)
    else
        text = ("%s in %d of %d entries"):format(wantText, held, total)
    end
    return kind.word .. ": " .. text
end
local function statusLines()
    local lines = { ("v%s | %s"):format(VERSION, summary()) }
    local flow, stop, shake = wanted()
    if flow == "game" and stop == STOP.rest and shake and not pending() then
        lines[#lines + 1] = "nothing to change: the game is not looked at"
    else
        local F = S.flow
        local text
        if flow == "game" then text = next(F.before) ~= nil and "being put back" or "left to the game"
        elseif F.off then text = ("wanted %s, but left as the game has it (%s)"):format(flow, F.off)
        elseif F.value == nil then text = ("wanted %s, not looked at yet"):format(flow)
        else text = ("wanted %s, the game has it %s (through the %s)"):format(flow, onOff(F.value), tostring(F.way)) end
        lines[#lines + 1] = "flow helper: " .. text
        lines[#lines + 1] = kindLine(STOP, stop, ("%d %% of the game's"):format(stop))
        lines[#lines + 1] = kindLine(SHAKE, shake, "none")
        if idle() then
            lines[#lines + 1] = "nothing left to do: the game is not looked at"
        elseif S.halt then
            lines[#lines + 1] = "nothing is changed at the moment: " .. S.halt
        end
    end
    lines[#lines + 1] = ("changes: %d%s; flow helper set %d time(s), put back %d; table values written %d, put back %d; looks %d (%d while paused)"):format(
        S.changes, S.last and (" (last: " .. S.last .. ")") or "", S.flow.sets, S.flow.backs, S.written, S.putBack, S.looks, S.pausedLooks)
    return lines
end

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

-- ---------------------------------------------------------------------------
-- Registration (each exactly once)
-- ---------------------------------------------------------------------------
-- After a map load everything is looked at again (objects of the game can be new).
KIT.onWorldChange(function() S.nextLook, S.verifyAt = SOON, SOON end)
for _, name in ipairs({ "melee", "g1r_melee" }) do
    if type(RegisterConsoleCommandHandler) == "function" then
        pcall(RegisterConsoleCommandHandler, name, console)
    end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; the melee clean-ups are disabled.")
    return
end
LoopInGameThreadWithDelay(250, function()
    local ok, err = pcall(tick)
    if not ok then L.once("tick:" .. tostring(err), "update error: " .. tostring(err)) end
end)

log(("v%s loaded: %s"):format(VERSION, summary()))

-- What an earlier run of the Lua mods left in the game's tables (the mods were reloaded while the game ran): those
-- tables are left alone in this run. They stay in S.mem as tables that may hold values of the module (the status
-- says so) and in the shared variable (for a run after this one).
S.guard = shared(GUARD)
if type(S.guard) == "string" then
    local named, left = {}, {}
    for name in S.guard:gmatch("[^,]+") do named[name] = true end
    for _, kind in ipairs({ STOP, SHAKE }) do
        for _, name in ipairs(kind.tables) do
            if named[name] then
                S.stale[name], S.broken[name], S.mem[name] = STALE, STALE, {}
                left[#left + 1] = name
            end
        end
    end
    if #left > 0 then log(("the Lua mods were reloaded while values of the mod were in the game's tables (%s): what the game had there is no longer known, so they are left as they are - restart the game to change them again"):format(concat(left, ", "))) end
end

if DIAG then
    pcall(function()
        DIAG.status(statusLines)
        DIAG.dump(function()
            local before, kept, broken = {}, {}, {}
            for id, value in pairs(S.flow.before) do before[id] = onOff(value) end
            for name, mem in pairs(S.mem) do kept[name] = mem.count end
            for name, why in pairs(S.broken) do broken[name] = why end
            return {
                version = VERSION, enabled = Cfg.Enabled, flow_helper = Cfg.FlowHelper, hit_stop = Cfg.HitStop, hit_shake = Cfg.HitShake,
                show_message = Cfg.ShowMessage, flow_method = Cfg.FlowMethod, check_seconds = Cfg.CheckSeconds,
                verify_seconds = Cfg.VerifySeconds, act_while_paused = Cfg.ActWhilePaused,
                hero = S.hero, not_changing = S.halt, looks = S.looks, looks_paused = S.pausedLooks, changes = S.changes, last_change = S.last,
                flow = {
                    game_value = S.flow.value ~= nil and onOff(S.flow.value) or nil, way = S.flow.way, direct_fallback = S.flow.direct,
                    failures = S.flow.fails, given_up = S.flow.off, set = S.flow.sets, put_back = S.flow.backs, before = before,
                },
                feedback_object = S.feedback, tables_in_hand = kept, tables_left_alone = broken,
                feedback_missing = S.noFeedback, no_shake_class = S.none and S.none.name or nil, values_written = S.written, values_put_back = S.putBack,
            }
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "MELEE_TEST")) == "table" then
    local T = rawget(_G, "MELEE_TEST")
    T.state, T.console, T.status, T.tick, T.settings, T.num = S, console, statusLines, tick, Settings, num
end
