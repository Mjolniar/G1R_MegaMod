-- ============================================================================
-- Lock picking that follows the hero's skill (module locks of G1R_MegaMod) -
-- Gothic 1 Remake, UE4SS Lua
--
-- The pieces of a lock are connected: moving one drags others along. When a
-- lock is set up the game takes the first connections of the lock's list away,
-- as many as the hero's attribute LockpickPrecision says (the game's own:
-- untrained 0, skilled 1, master 2), and gives the lock pick as many wrong
-- moves as LockpickDurability says (2 / 4 / 6). This module keeps these two
-- numbers at what the settings say for the hero's present skill level.
--
-- How it works. Once a second the module looks at the hero: which of the three
-- skill tags he has (Skill.Lockpicking.Untrained / .Trained / .Master), whether
-- a lock is being picked (tag State.PickLock), and what the two attributes
-- hold. A value that differs from the wanted one is written and read back.
-- The game writes its own numbers again when the hero learns a level and after
-- a load; the next look puts the wanted ones back in.
--
-- Never: nothing is written while a lock is being picked (the game reads the
-- numbers again after a broken pick and would rebuild the connections under
-- the pieces as they stand); changes wait until the lock is over.
--
-- The choices "none", "1", "2" and "all" are the same for every lock. "half"
-- and "safe" depend on the lock: half of its connections, or as many as it is
-- proven to stay solvable with (lockdata.lua, made with a solver from the
-- game's own lock definitions). For these the module must know the lock before
-- the game sets it up: it hooks the function of the game that starts the lock
-- of a chest (GameplayAbilityOpen:OnIntroFinished, registered once through the
-- kit, and only when such a choice is in use), reads the lock's name there and
-- writes the number for it; when the lock is over the game's own number is put
-- back. A lock that is not known in time (a door, a lock that is not in the
-- table, a hook that does not work) is left as the game has it. Two things
-- keep these choices safe: they are only in use while the hero's skill tag
-- tells his level (tags that do not show it are not relied on to tell when a
-- lock is over), and between locks the number is looked at at every look -
-- one that is not the game's own, such as the number of one chest's lock in
-- a save made during that lock, is put back before it can meet another lock.
--
-- Putting back: the module remembers which of the two numbers it changed. A
-- level set back to "as the game has it", or the module switched off, puts the
-- game's own number for the hero's level back first; after that the game is
-- not looked at at all. The game saves these attributes with everything else:
-- a save made while the module has them changed holds the changed numbers (the
-- game overwrites them with its own after a load, and the button "Put the
-- game's own values back now" / the console word `locks restore` does it by
-- hand).
--
-- One such mod at a time: the loader does not load this module while the mod
-- SkillfulLocks is enabled.
--
-- Settings: schema.lua describes them, config.lua holds them; the settings
-- app and the in-game mod menu change them while the game runs.
-- ============================================================================

local VERSION = "1.0.0"
local TAG = "G1R_Locks"

local KIT, SETTINGS = G1R_KIT, G1R_SETTINGS
-- Diagnostics handle of the loader; nil when the diagnostics are off, and then
-- nothing behind `if DIAG` runs.
local DIAG = G1R_DIAG
if type(KIT) ~= "table" or type(SETTINGS) ~= "table" then
    print("[" .. TAG .. "] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started\n")
    return
end
if DIAG then pcall(DIAG.version, VERSION) end

local pcall, type, tostring, ipairs = pcall, type, tostring, ipairs
local floor, abs, min, max = math.floor, math.abs, math.min, math.max
local concat = table.concat
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
-- What the game calls things (sources: dev/facts/locks.md)
-- ---------------------------------------------------------------------------
-- The two attributes of the hero's AttributeSet_Lockpicking, each with the keys of its diagnostics notes.
local PRECISION = { name = "LockpickPrecision", what = "connections taken away",
    found = "locks.found_precision", readable = "locks.readable_precision", wrote = "locks.write_precision" }
local DURABILITY = { name = "LockpickDurability", what = "wrong moves per pick",
    found = "locks.found_durability", readable = "locks.readable_durability", wrote = "locks.write_durability" }
local BOTH = { PRECISION, DURABILITY }

-- The three levels of the skill: the tag the game's skill effect gives the
-- hero, the numbers the game's definition of the hero sets with that tag, and
-- this module's settings for the level.
local TIERS = {
    { key = "untrained", tag = "Skill.Lockpicking.Untrained", mode = "UntrainedConnections", moves = "UntrainedWrongMoves",
      game = { LockpickPrecision = 0, LockpickDurability = 2 } },
    { key = "skilled", tag = "Skill.Lockpicking.Trained", mode = "SkilledConnections", moves = "SkilledWrongMoves",
      game = { LockpickPrecision = 1, LockpickDurability = 4 } },
    { key = "master", tag = "Skill.Lockpicking.Master", mode = "MasterConnections", moves = "MasterWrongMoves",
      game = { LockpickPrecision = 2, LockpickDurability = 6 } },
}
local TAG_PICKING = "State.PickLock"    -- on the hero while a lock is being picked

local ALL = 99                  -- "all": more connections than any lock has (the largest has 11)
local NEVER = 100000            -- wrong moves of a pick that "does not break"
local REMOVED = { ["none"] = 0, ["1"] = 1, ["2"] = 2, ["all"] = ALL }      -- the choices that are one number for every lock
local PER_LOCK = { half = true, safe = true }       -- the choices whose number depends on the lock
local GAME = "as the game has it"
-- The function of the game that starts the lock of a chest: it creates and activates the lock task, which reads
-- the hero's two attributes. A function hooked before it runs is the last moment to write a number for that lock.
local HOOK_CHEST = "/Script/G1R.GameplayAbilityOpen:OnIntroFinished"
local SAME = 0.01               -- two attribute values closer than this are the same number
local TRIES = 3                 -- failures in a row before a way of doing something is given up for this run
local RESTORE_SECONDS = 10      -- a pass asked for by hand looks for the hero this long

-- ---------------------------------------------------------------------------
-- State of this run
-- ---------------------------------------------------------------------------
local S = {
    failed = {}, givenUp = {},          -- per attribute: writes that did not work; given up for this run
    asked = nil,                        -- a pass that puts the game's values back was asked for by hand (until this clock value)
    askedTier = nil,                    -- the level named with it, for a hero whose level cannot be told
    locks = 0, changed = 0,             -- locks the hero started on; of these with a value of this module in place
    writes = 0, putBack = 0, rewritten = 0,
    lastLock = nil,                     -- what was said about the last lock
    hooked = nil,                       -- the chest hook: true / false once it was asked for (once per run)
    hookCalls = 0, hookRuns = 0,        -- how often the game called it; how often it took the name of a lock of the hero from it
    nextLook = 0,                       -- the clock value of the next look
}
-- Nothing is known about the hero: the next look at the game starts afresh.
local function rest()
    S.setName, S.via = nil, nil         -- full name of the attributes last looked at; how they were found
    S.tier, S.tierBy = nil, nil         -- the hero's level (an entry of TIERS) and what told it ("tags" / "values")
    S.picking = nil                     -- a lock is being picked (nil = not known)
    S.mark = {}                         -- attribute name -> the value in these attributes that is this module's, not the game's
    S.value = {}                        -- attribute name -> its value at the last look
    S.first = {}                        -- attribute name -> true once its first value in these attributes was noted
    S.blind = {}                        -- attribute name -> true while it cannot be read
    S.lock = nil                        -- the lock the chest hook announced: { name, count, value, tier, mode, started }
    S.tagFails, S.tagsOff = 0, false    -- looks in a row at which his tags could not be asked; given up for these attributes
    S.noTier, S.unknown = 0, 0          -- looks in a row at which he had none of the three skill tags / his level could not be told
    S.awake = false                     -- the module is looking at the game
end
rest()
local Noted = {}
local function note(key, value, detail)
    if DIAG and Noted[key] ~= value then
        Noted[key] = value
        DIAG.note(key, value, detail)
    end
end

-- The first line of an error text, without the "file:line:" in front.
local function reason(text) return ((tostring(text):match("^[^\r\n]*") or ""):gsub("^.-:%d+: ", "")) end
local function whole(v) return floor(v + 0.5) end
local function dirty() return S.mark.LockpickPrecision ~= nil or S.mark.LockpickDurability ~= nil end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local Settings, problem = SETTINGS.open({ module = "locks", dir = SCRIPT_DIR, log = log })
if not Settings then
    log("the settings could not be set up (" .. tostring(problem) .. "); not started")
    return
end
local Cfg = Settings.values

-- The number the settings want in an attribute for a level, or nil for "as
-- the game has it". A choice that depends on the lock wants the game's own
-- number except for the lock the chest hook announced.
local function wanted(tier, a)
    if a == PRECISION then
        local mode = Cfg[tier.mode]
        if PER_LOCK[mode] then
            local lock = S.lock
            if lock and lock.tier == tier and lock.mode == mode then return lock.value end
            return nil
        end
        return REMOVED[mode]
    end
    if Cfg.PicksNeverBreak then return NEVER end
    local moves = Cfg[tier.moves]
    if moves > 0 then return moves end
    return nil
end
-- True while the settings change nothing at any level: the game is not looked at.
local function idle()
    if not Cfg.Enabled then return true end
    if Cfg.PicksNeverBreak then return false end
    for _, tier in ipairs(TIERS) do
        if Cfg[tier.mode] ~= GAME or Cfg[tier.moves] > 0 then return false end
    end
    return true
end
local function summary()
    if not Cfg.Enabled then return "switched off in the settings" end
    if idle() then return "locks and lock picks as the game has them" end
    local removed, moves = {}, {}
    for i, tier in ipairs(TIERS) do
        local mode = Cfg[tier.mode]
        removed[i] = mode == GAME and "game" or mode
        moves[i] = Cfg[tier.moves] > 0 and tostring(Cfg[tier.moves]) or "game"
    end
    return ("connections taken away %s (untrained / skilled / master); %s"):format(concat(removed, " / "),
        Cfg.PicksNeverBreak and "lock picks do not break" or ("wrong moves per pick " .. concat(moves, " / ")))
end

-- ---------------------------------------------------------------------------
-- The hero's gameplay tags. A tag is handed to the game as a table with its
-- name; names and tags are made once per text and kept.
-- ---------------------------------------------------------------------------
local Tags = {}
local function tagOf(text)
    local t = Tags[text]
    if t == nil then
        local ok, name = pcall(function() return FName(text) end)
        t = (ok and name ~= nil) and { TagName = name } or false
        Tags[text] = t
    end
    return t or nil
end

-- The hero's ability system (it holds his gameplay tags), or nil.
local function ability()
    local state = KIT.playerState()
    local system = state and KIT.get(state, "AbilitySystemComponent") or nil
    if KIT.valid(system) then return system end
    return nil
end

-- Does the hero have this tag? true / false, or nil when that cannot be asked.
local function hasTag(system, text)
    if S.tagsOff then return nil end
    local ok, result = false, "the hero has no ability system"
    if system ~= nil then
        local tag = tagOf(text)
        if tag then ok, result = KIT.try(system, "HasGameplayTag", tag) else result = "this UE4SS build has no FName" end
    end
    if ok and type(result) == "boolean" then
        S.tagFails = 0
        note("locks.tags", "readable")
        return result
    end
    S.tagFails = S.tagFails + 1
    if S.tagFails >= TRIES then
        S.tagsOff = true
        local why = reason(ok and ("the answer was " .. tostring(result)) or result)
        L.once("tags", "the hero's gameplay tags cannot be asked (" .. why .. "); the skill level is told by the numbers the game "
            .. "set, and a lock being picked is not noticed (no note, and a changed setting does not wait for its end)")
        note("locks.tags", "not readable", why)
    end
    return nil
end

-- The hero's level by his skill tag: an entry of TIERS, false when he has none
-- of the three, nil when the tags cannot be asked. Asked from the top: should
-- he ever have two of the tags, the higher level counts (levels are learned
-- upwards, and the game writes the numbers of the tag that came last).
local function tierByTags(system)
    for i = #TIERS, 1, -1 do
        local has = hasTag(system, TIERS[i].tag)
        if has == nil then return nil end
        if has then return TIERS[i] end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- The two attributes
-- ---------------------------------------------------------------------------
-- An attribute's current and base value at this look (read once per look).
local function read(set, a, seen)
    local s = seen[a.name]
    if s == nil then
        local current, base = KIT.readAttribute(set, a.name)
        if current == nil then
            L.once("unreadable:" .. a.name, ("the hero's %s could not be read from %s"):format(a.name, tostring(S.setName)))
            note(a.readable, "no")
            s = false
            S.value[a.name] = nil
        else
            note(a.readable, "yes")
            s = { current, base or current }
            S.value[a.name] = current
        end
        S.blind[a.name] = current == nil
        seen[a.name] = s
    end
    if s then return s[1], s[2] end
    return nil
end

-- A mark says "this number is the module's". When the attribute holds another
-- number now, somebody else wrote it: the game (a level was learned, a save
-- was loaded) or another mod.
local function reconcile(set, a, seen)
    local mark = S.mark[a.name]
    if mark == nil then return end
    local current = read(set, a, seen)
    if current ~= nil and abs(current - mark) > SAME then
        S.mark[a.name] = nil
        S.rewritten = S.rewritten + 1
        note("locks.rewritten", "seen", ("%s %s -> %s"):format(a.name, whole(mark), whole(current)))
    end
end

-- The hero's level by the numbers the game set for it: the pick's wrong moves
-- (2 / 4 / 6), or - while that number is this module's - the connections taken
-- away (0 / 1 / 2). Only a number this module did not write tells the level.
local function tierByValues(set, seen)
    reconcile(set, DURABILITY, seen)
    reconcile(set, PRECISION, seen)
    local a = (S.mark.LockpickDurability == nil and DURABILITY) or (S.mark.LockpickPrecision == nil and PRECISION) or nil
    if a == nil then return S.tier end      -- both numbers are this module's: the level they were written for
    local current = read(set, a, seen)
    if current ~= nil then
        for _, tier in ipairs(TIERS) do
            if abs(current - tier.game[a.name]) <= SAME then return tier end
        end
    end
    return nil
end

-- Writes a number into an attribute (base and current value) and reads it
-- back. When it does not arrive as written, what did arrive is taken back.
local function put(set, a, value, current, base)
    local ok, why = KIT.writeAttribute(set, a.name, value)
    if ok then
        S.failed[a.name] = 0
        note(a.wrote, "ok")
        return true
    end
    pcall(function()
        local data = set[a.name]
        data.BaseValue = base
        data.CurrentValue = current
    end)
    S.failed[a.name] = (S.failed[a.name] or 0) + 1
    L.once("write:" .. a.name, ("%s could not be written (%s); it is left as it was (%s)"):format(a.name, tostring(why), whole(current)))
    note(a.wrote, "failed", tostring(why))
    if S.failed[a.name] >= TRIES then
        local mark = S.mark[a.name]
        S.givenUp[a.name] = true
        S.mark[a.name] = nil
        log(("%s is left alone until the settings change: %d writes in a row did not work%s"):format(a.name, S.failed[a.name],
            mark ~= nil and (" - it still holds the " .. whole(mark) .. " this module wrote earlier") or ""))
    end
    return false
end

-- Brings one attribute to what is wanted now: the settings' number for the
-- level, or - when the settings want the game's own and the number in place
-- is this module's - the game's number. `force`: the game's number in any case
-- (the pass asked for by hand). Returns what was done: "written", "put back",
-- "failed" (the write did not work), or nil.
local function settle(set, tier, a, seen, off, force)
    if S.givenUp[a.name] then return nil end
    local own = tier.game[a.name]
    local want = nil
    if not off and not force then want = wanted(tier, a) end
    -- A choice that goes by the lock counts on the game's own number standing between locks: a door's lock, and
    -- any lock the hook does not announce, is set up with what the attribute holds. A save made while a chest's
    -- lock was being picked holds that lock's number, without a mark of this module, and with another lock's
    -- number a lock can be impossible to open. So under such a choice the number is looked at at every look,
    -- like the number of a fixed choice, and another one than the game's own is put back.
    local between = a == PRECISION and PER_LOCK[Cfg[tier.mode]] and not off
    if want == nil and S.mark[a.name] == nil and not force and not between then return nil end       -- the game's own, untouched: not even read
    reconcile(set, a, seen)
    local current, base = read(set, a, seen)
    if current == nil then return nil end
    if between and want == nil and S.mark[a.name] == nil and abs(current - own) > SAME then
        L.once("leftover", ("%s held %s between two locks, not the game's own %s for the level %s (a number left by a save made in the middle "
            .. "of a lock?): under \"half\" / \"safe\" the game's own number is put back"):format(a.name, whole(current), own, tier.key))
    end
    if not S.first[a.name] then
        -- What these attributes held before this module wrote anything into them: the game's own number, or -
        -- after a load of a save that was made with the module's number in place - the number the module would
        -- write now, or neither.
        S.first[a.name] = true
        local detail = ("%s at level %s (the game's own: %s)"):format(whole(current), tier.key, own)
        if abs(current - own) <= SAME then
            note(a.found, "the game's own")
        elseif want ~= nil and abs(current - want) <= SAME then
            note(a.found, "this module's number", detail)
        else
            note(a.found, "another number", detail)
        end
    end
    local target = want or own
    local done = nil
    if abs(current - target) > SAME then
        if not put(set, a, target, current, base) then return "failed" end
        seen[a.name] = { target, target }
        S.value[a.name] = target
        if want ~= nil then
            S.writes = S.writes + 1
            done = "written"
        else
            S.putBack = S.putBack + 1
            note("locks.put_back", "ok")
            done = "put back"
        end
    end
    -- the number in place is the module's when it is not the game's own
    S.mark[a.name] = (want ~= nil and abs(want - own) > SAME) and want or nil
    return done
end

-- ---------------------------------------------------------------------------
-- The choices that depend on the lock ("half", "safe")
-- ---------------------------------------------------------------------------
-- lockdata.lua: lock name -> { number of its connections, how many of them can
-- be taken away with the lock proven to stay solvable }. Read once, when such
-- a choice is first in use.
local LockData = nil            -- nil: not read yet; false: could not be read
local LockNames = {}            -- a lock's name in small letters -> its spelling in the table
local function lockData()
    if LockData == nil then
        local ok, data = pcall(dofile, SCRIPT_DIR .. "lockdata.lua")
        LockData = (ok and type(data) == "table") and data or false
        if LockData then
            for name in pairs(LockData) do
                if type(name) == "string" then LockNames[name:lower()] = name end
            end
            note("locks.lock_table", "read")
        else
            L.once("table", "lockdata.lua could not be read (" .. reason(data) .. "); the choices \"half\" and \"safe\" leave every lock as the game has it")
            note("locks.lock_table", "not readable", reason(data))
        end
    end
    return LockData or nil
end

-- The number of connections a choice takes away from a lock, and how many the
-- lock has: half of them, or as many as proven - not fewer than the game takes
-- away itself at this level (own), never more than the lock is proven to stay
-- solvable with. nil for a lock that is not in the table.
local function depthFor(mode, own, lockName)
    local data = lockData()
    -- (the game does not keep capital and small letters of a name apart: it may hand a name out in another
    -- spelling than the lock's definition has)
    local entry = data and (data[lockName] or data[LockNames[lockName:lower()]])
    if type(entry) ~= "table" or type(entry[1]) ~= "number" or type(entry[2]) ~= "number" then return nil end
    local count, proven = entry[1], entry[2]
    local base = mode == "half" and floor(count / 2) or count
    return min(max(base, own), proven), count
end

-- Runs inside the game's call that starts the lock of a chest, before the
-- lock is set up: notes which lock it is and writes the number for it.
-- Everything else is left to the next look.
local function announce(context)
    local tier = S.tier
    if tier == nil or S.tierBy ~= "tags" or S.picking ~= false or not Cfg.Enabled then return end
    local mode = Cfg[tier.mode]
    if not PER_LOCK[mode] then return end
    local chest = KIT.unwrap(context)                   -- the hero's ability of opening a chest
    local owner = KIT.fullName(chest)
    if owner == nil or not owner:find("PlayerState", 1, true) then return end       -- somebody else's
    local ok, lockName = pcall(function() return chest.m_Lock:ToString() end)
    if not ok or type(lockName) ~= "string" or lockName == "" or lockName == "None" then return end      -- nothing to pick
    local set = KIT.attributeSet("Lockpicking")
    if not set or KIT.fullName(set) ~= S.setName then return end        -- not the attributes the last look knew
    S.hookRuns = S.hookRuns + 1
    local value, count = depthFor(mode, tier.game.LockpickPrecision, lockName)
    S.lock = { name = lockName, count = count, value = value, tier = tier, mode = mode, started = false }
    settle(set, tier, PRECISION, {}, false, false)
    S.nextLook = 0              -- the next tick looks whether the lock has started
end
-- The hook itself: the game calls it for every character that opens a chest.
-- Nothing may leave it as an error.
local function chestOpens(context)
    S.hookCalls = S.hookCalls + 1
    note("locks.lock_hook", "runs")
    local ok, err = pcall(announce, context)
    if not ok then L.once("hook:" .. tostring(err), "error in the chest hook: " .. reason(err)) end
end

-- Registers the hook: once per run, through the kit, and only when a choice
-- needs it.
local function ensureHook()
    if S.hooked == nil then
        local ok, why = KIT.hookOnce(HOOK_CHEST, chestOpens)
        S.hooked = ok == true
        if S.hooked then
            note("locks.lock_hook", "registered")
            lockData()          -- the table is read here, in the module's look - not inside the game's call when the first chest is opened
        else
            L.once("hook", "the game's function that starts the lock of a chest could not be hooked (" .. reason(why)
                .. "); the choices \"half\" and \"safe\" leave every lock as the game has it")
            note("locks.lock_hook", "not available", reason(why))
        end
    end
end

-- ---------------------------------------------------------------------------
-- A lock is started: the note on screen and the log line
-- ---------------------------------------------------------------------------
local function describe(tier, lock)
    local parts = {}
    local removed, moves = S.mark.LockpickPrecision, S.mark.LockpickDurability
    if removed ~= nil then
        local own = tier.game.LockpickPrecision
        if lock and lock.count then parts[#parts + 1] = ("%d of %d connections taken away (the game: %d)"):format(min(removed, lock.count), lock.count, own)
        elseif removed >= ALL then parts[#parts + 1] = ("all connections taken away (the game: %d)"):format(own)
        elseif removed == 0 then parts[#parts + 1] = ("no connection taken away (the game: %d)"):format(own)
        else parts[#parts + 1] = ("%d of the connections taken away (the game: %d)"):format(removed, own) end
    end
    if moves ~= nil then
        local own = tier.game.LockpickDurability
        if moves >= NEVER then parts[#parts + 1] = ("the pick does not break (the game: after %d wrong moves)"):format(own)
        else parts[#parts + 1] = ("the pick breaks after %d wrong moves (the game: %d)"):format(moves, own) end
    end
    return concat(parts, ", ")
end

local function lockStarted(set, tier, seen)
    S.locks = S.locks + 1
    note("locks.minigame", "seen")
    -- is what this module wrote still in place? (another mod may write when a lock starts)
    local intact = true
    for _, a in ipairs(BOTH) do
        local mark = S.mark[a.name]
        if mark ~= nil then
            local current = read(set, a, seen)
            if current ~= nil and abs(current - mark) > SAME then
                intact = false
                S.mark[a.name] = nil
                L.once("foreign:" .. a.name, ("at the start of a lock %s was %s, not the %s this module had written: the game or another mod "
                    .. "changed it, and this module's number did not count for that lock"):format(a.name, whole(current), whole(mark)))
                note("locks.in_place", "no", ("%s %s instead of %s"):format(a.name, whole(current), whole(mark)))
            end
        end
    end
    -- a choice that depends on the lock: was the lock known before it started?
    local lock, why = S.lock, ""
    if PER_LOCK[Cfg[tier.mode]] then
        if lock == nil then
            why = " (the lock was not known before it started: a door, or the hook did not run)"
            note("locks.lock_known", "not announced")
        elseif lock.value == nil then
            why = " (this lock is not in the module's table)"
            note("locks.lock_known", "not in the table", lock.name)
        else
            note("locks.lock_known", "announced", lock.name)
        end
    end
    local who = lock and (tier.key .. ", " .. lock.name) or tier.key
    local text = describe(tier, lock)
    if text == "" then
        S.lastLock = ("%s: as the game has it%s"):format(who, why)
    else
        if intact then note("locks.in_place", "yes") end
        S.changed = S.changed + 1
        S.lastLock = ("%s: %s"):format(who, text)
        if S.changed == 1 and DIAG then
            DIAG.event(("first changed lock: %s, level told by %s, attributes found through the %s"):format(S.lastLock, tostring(S.tierBy), tostring(S.via)))
        end
        if Cfg.ShowMessage then
            KIT.notify(("Lock picking (%s): %s"):format(tier.key, (text:gsub(" %(the game: [^)]*%)", ""))), "locks")
        end
    end
    if Cfg.LogLocks then log("lock started - " .. S.lastLock) end
end

-- ---------------------------------------------------------------------------
-- The look
-- ---------------------------------------------------------------------------
-- A pass asked for by hand is over: says what it did.
local function answer(text)
    S.asked, S.askedTier = nil, nil
    log(text)
    KIT.notify(text, "locks")
end

-- One look at the hero. `off`: the settings change nothing (any more): what
-- this module changed is put back.
local function look(off)
    local now = clock()
    local force = S.asked ~= nil
    local set, via = KIT.attributeSet("Lockpicking")
    if not set then
        if S.setName ~= nil then rest() end         -- the hero is gone, and what was written with him
        if force and now >= S.asked then answer("the hero's lock picking values were not found (no game loaded?): nothing was put back") end
        return
    end
    local name = KIT.fullName(set)
    if name ~= S.setName then
        -- other attributes than at the last look: a new game, a loaded save, another map
        rest()
        S.setName, S.via = name, via
        note("locks.set_found_by", via)
        if Cfg.ShowMessage then KIT.prepareNotes() end      -- searches now, not while a lock is picked
    end
    S.awake = true
    local seen = {}
    local system = ability()

    -- the hero's level
    local byTags = tierByTags(system)       -- false: he has none of the three; nil: the tags cannot be asked
    local tier, by = byTags, "tags"
    if tier then
        S.noTier = 0
    else
        if tier == false then
            -- said when it lasts: a hero whose save is still filling in may have no skill tag for a moment
            S.noTier = S.noTier + 1
            if S.noTier == TRIES then L.once("notier", "the hero has none of the three lock picking skill tags; his level is told by the numbers the game set") end
        end
        tier, by = tierByValues(set, seen), "values"
    end
    if not tier and force and S.askedTier then tier, by = S.askedTier, "hand" end       -- named with the console word
    if not tier then
        S.tier, S.tierBy, S.picking = nil, nil, nil
        S.unknown = S.unknown + 1
        if S.unknown == TRIES then
            L.once("level", "the hero's lock picking level cannot be told (neither by his tags nor by the numbers the game set); nothing is changed")
        end
        note("locks.level_by", "unknown")
        if force and now >= S.asked then
            answer("the hero's lock picking level cannot be told: nothing was put back (the console word locks restore untrained / skilled / master names it)")
        end
        return
    end
    S.unknown = 0
    S.tier, S.tierBy = tier, by
    note("locks.level", tier.key)
    note("locks.level_by", by)

    -- a lock is being picked: nothing is written until it is over
    local picking = nil
    if byTags ~= nil then picking = hasTag(system, TAG_PICKING) end
    if picking and not S.picking then lockStarted(set, tier, seen) end
    S.picking = picking
    local lock = S.lock
    if lock ~= nil then
        -- the lock the chest hook announced: it has started, or it is over, or it never started (not locked any
        -- more, opened with a key, no lock pick) - then the game's own number counts again
        if picking then lock.started = true else S.lock = nil end
    end
    if picking then return end

    -- A choice that depends on the lock needs the hook, and the hero's tags to tell when a lock is over. Tags that
    -- answer but show none of his three skill levels (the level is told by the numbers then) are not relied on
    -- for that either: an answer of "no lock" in the middle of a lock would put the game's number back under it.
    if not off and PER_LOCK[Cfg[tier.mode]] then
        if picking == nil then
            L.once("perlock", "without the hero's tags it cannot be told when a lock is over: the choices \"half\" and \"safe\" leave every lock as the game has it")
        elseif by == "tags" then
            ensureHook()
        elseif S.noTier >= TRIES then
            L.once("perlock:level", "the hero's tags do not show his level, so they are not relied on to tell when a lock is over: the choices \"half\" and \"safe\" leave every lock as the game has it")
        end
    end

    local did, failed = {}, {}
    for _, a in ipairs(BOTH) do
        local done = settle(set, tier, a, seen, off, force)
        if done == "failed" then
            failed[#failed + 1] = a.name
        elseif done then
            did[#did + 1] = ("%s %s"):format(a.name, done == "written" and ("-> " .. whole(S.value[a.name])) or ("back to " .. whole(S.value[a.name])))
        end
    end
    if force then
        local level = tier.key .. (by == "hand" and " (as named)" or "")
        if #failed > 0 then
            answer("the game's own values for the level " .. level .. " could not be written: " .. concat(failed, ", ")
                .. (#did > 0 and ("; put back: " .. concat(did, ", ")) or ""))
        elseif #did > 0 then
            answer("the game's own values for the level " .. level .. " were put back: " .. concat(did, ", "))
        else
            answer("nothing to put back: the hero's lock picking values are the game's own for the level " .. level)
        end
    elseif #did > 0 and Cfg.LogLocks then
        log(("level %s: %s"):format(tier.key, concat(did, ", ")))
    end
end

local function tick()
    if KIT.loading() then return end
    local off = idle()
    if not off then S.asked, S.askedTier = nil, nil end     -- the settings write their own numbers: nothing to put back by hand
    if not off or dirty() or S.asked ~= nil then
        local now = clock()
        if now < S.nextLook then return end
        -- (while a lock the chest hook announced is in hand every tick looks: its number is for that lock only and
        -- goes back as soon as the lock is over, whatever the pace of the looks)
        S.nextLook = now + (S.lock == nil and Cfg.LookSeconds or 0) - 0.001
        look(off)
        if not off or dirty() or S.asked ~= nil then return end
    end
    -- nothing to change and nothing left to put back: the game is not looked at
    if S.awake then rest() end
end

-- Puts the game's own values back by hand (the button of the in-game menu,
-- the console word). Only while the settings change nothing: otherwise the
-- next look would write the settings' numbers again.
local function restoreNow(word)
    if not idle() then
        return "the module is changing these values at the moment: switch it off or set every level to \"as the game has it\", "
            .. "and the game's own values are put back by themselves"
    end
    local named = nil
    if word ~= nil and word ~= "" then
        for _, tier in ipairs(TIERS) do
            if tier.key == word then named = tier end
        end
        if named == nil then return "unknown level \"" .. word .. "\": locks restore, or locks restore untrained / skilled / master" end
    end
    S.asked, S.askedTier = clock() + RESTORE_SECONDS, named
    S.failed, S.givenUp = {}, {}        -- what was given up is tried anew
    S.nextLook = 0
    return "putting the game's own values back ..."
end

Settings.onChange = function(_, _, why)
    log(("settings changed (%s): %s"):format(why == "menu" and "in-game menu" or (why == "file" and "config.lua" or tostring(why)), summary()))
    if not Cfg.ShowMessage then KIT.hideToast("locks") end
    -- what was given up is tried anew, and the next tick looks at once
    S.failed, S.givenUp = {}, {}
    S.nextLook = 0
end
Settings.onAction = function(key)
    if key == "RestoreNow" then
        local text = restoreNow()
        if S.asked == nil then answer(text) end
    end
end

-- ---------------------------------------------------------------------------
-- Status (console command locks, the loader's reports). Built from what the
-- module holds; it does not call into the game.
-- ---------------------------------------------------------------------------
local BY = { tags = "his skill tag", values = "the numbers the game set", hand = "the console word" }
local function valueText(a)
    local mark, value = S.mark[a.name], S.value[a.name]
    if mark ~= nil then return ("%s %d (this module's; the game's own: %d)"):format(a.what, whole(mark), S.tier.game[a.name]) end
    if value ~= nil then
        local own = S.tier.game[a.name]
        if abs(value - own) <= SAME then return ("%s %d (the game's own)"):format(a.what, whole(value)) end
        return ("%s %d (not this module's; the game's own: %d)"):format(a.what, whole(value), own)
    end
    if S.blind[a.name] then return a.what .. " cannot be read" end
    return a.what .. " as the game has it (not looked at)"
end
local function statusLines()
    local lines = { ("v%s | %s"):format(VERSION, summary()) }
    if S.setName == nil then
        if idle() and not dirty() and S.asked == nil then
            lines[#lines + 1] = "nothing to change: the game is not looked at"
        else
            lines[#lines + 1] = "the hero's lock picking values have not been found yet (no game loaded?)"
        end
    elseif S.tier == nil then
        lines[#lines + 1] = "the hero's lock picking level cannot be told (neither by his tags nor by the numbers the game set): nothing is changed"
    else
        lines[#lines + 1] = ("the hero is %s (told by %s); %s; %s"):format(S.tier.key, BY[S.tierBy] or "?", valueText(PRECISION), valueText(DURABILITY))
        if S.picking then lines[#lines + 1] = "a lock is being picked: nothing is changed until it is over" end
    end
    lines[#lines + 1] = ("locks started: %d (with this module's numbers: %d)%s; values written: %d, put back: %d, rewritten by the game: %d"):format(
        S.locks, S.changed, S.lastLock and ("; last - " .. S.lastLock) or "", S.writes, S.putBack, S.rewritten)
    if S.hooked ~= nil then
        lines[#lines + 1] = S.hooked and ("chests: the lock is told by the game's function that starts it (called %d times, %d of them for a lock of the hero)"):format(S.hookCalls, S.hookRuns)
            or "chests: the game's function that starts a lock could not be hooked - \"half\" and \"safe\" leave every lock as the game has it"
    end
    local given = {}
    for _, a in ipairs(BOTH) do
        if S.givenUp[a.name] then given[#given + 1] = a.name end
    end
    if #given > 0 then lines[#lines + 1] = "left alone until the settings change (could not be written): " .. concat(given, ", ") end
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
    local word = (args[1] or ""):lower()
    if word == "reload" then
        local ok, why = Settings:reload(true)
        lines = { ok and ("settings read: " .. summary()) or ("settings not read: " .. tostring(why)) }
    elseif word == "restore" then
        lines = { restoreNow((args[2] or ""):lower()) }
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
KIT.onWorldChange(function() rest() end)
for _, name in ipairs({ "locks", "g1r_locks" }) do
    if type(RegisterConsoleCommandHandler) == "function" then
        pcall(RegisterConsoleCommandHandler, name, console)
    end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; lock picking stays as the game has it.")
    return
end
LoopInGameThreadWithDelay(250, function()
    local ok, err = pcall(tick)
    if not ok then L.once("tick:" .. tostring(err), "update error: " .. tostring(err)) end
end)

log(("v%s loaded: %s"):format(VERSION, summary()))

if DIAG then
    pcall(function()
        DIAG.status(statusLines)
        DIAG.dump(function()
            local out = {
                version = VERSION, enabled = Cfg.Enabled, idle = idle(), looking = S.awake,
                picks_never_break = Cfg.PicksNeverBreak, show_message = Cfg.ShowMessage, log_locks = Cfg.LogLocks, look_seconds = Cfg.LookSeconds,
                attributes = S.setName, found_through = S.via, level = S.tier and S.tier.key or nil, level_by = S.tierBy,
                picking = S.picking, tags_unusable = S.tagsOff,
                locks_started = S.locks, locks_changed = S.changed, last_lock = S.lastLock,
                writes = S.writes, put_back = S.putBack, rewritten = S.rewritten,
                chest_hook = S.hooked, chest_hook_calls = S.hookCalls, chest_hook_runs = S.hookRuns, lock_table = LockData and "read" or (LockData == false and "not readable" or "not needed yet"),
                announced_lock = S.lock and { name = S.lock.name, connections = S.lock.count, taken_away = S.lock.value, started = S.lock.started } or nil,
                levels = {},
            }
            for _, tier in ipairs(TIERS) do
                out.levels[tier.key] = { connections = Cfg[tier.mode], wrong_moves = Cfg[tier.moves] }
            end
            for _, a in ipairs(BOTH) do
                out[a.name] = { value = S.value[a.name], this_modules = S.mark[a.name], failed_writes = S.failed[a.name] or 0, given_up = S.givenUp[a.name] == true }
            end
            return out
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "LOCKS_TEST")) == "table" then
    local T = rawget(_G, "LOCKS_TEST")
    T.state, T.console, T.status, T.tick, T.settings, T.summary, T.depthFor = S, console, statusLines, tick, Settings, summary, depthFor
end
