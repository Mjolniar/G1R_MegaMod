-- ============================================================================
-- Offline tests of the module locks (modules/locks/Scripts/main.lua).
--
--   lua5.4 harness.lua          (from any directory)
--
-- The module runs on the loader's kit and settings service; ../lib/modtest.lua
-- sets both up the way the loader does and replaces UE4SS by ../mock/ue4ss.lua.
-- The game is a model built here on top of modtest's (function `game` below):
-- every behaviour in it names where it is known from (dev/facts/locks.md has
-- the same sources). The model also plays the lock minigame by the game's
-- rules, so that the checks can show what a written number does to a lock.
-- Section 11 is the proof for the numbers the module writes (every lock, every
-- number, a way to open it replayed); section 20 runs the module through the
-- real loader with the real diagnostics; section 21 is a long random walk with
-- the three things that must always hold checked all the way.
-- gamelocks.lua (next to this file) is test data made by tools/make_tables.py.
-- Last line: "locks tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("locks")
local check, section, has, printed, printedCount = T.check, T.section, T.has, T.printed, T.printedCount
local MOD = T.MOD

-- ---------------------------------------------------------------------------
-- The model of the game
-- ---------------------------------------------------------------------------
-- The three levels of the lock picking skill: the tag the game's skill effect grants (as-src
-- GAS/Effects/Skills/GE_Skills.as: UGE_Skill_Picklock_Untrained / _Skilled / _Master) and the numbers the hero's
-- definition sets with that tag (as-src Player/PlayerCharacter.as:142-147, SetAttributeValueForTag).
local LEVELS = {
    untrained = { tag = "Skill.Lockpicking.Untrained", precision = 0, durability = 2 },
    skilled = { tag = "Skill.Lockpicking.Trained", precision = 1, durability = 4 },
    master = { tag = "Skill.Lockpicking.Master", precision = 2, durability = 6 },
}
local PICKING = "State.PickLock"

-- Two locks of the game (as-src Items/GenericItems/LockPickGeneric.as): pieces by id with their start position,
-- connections in the order of the game's AddConnection(id, connectedId, direction) lines.
local LOCKS = {
    -- solvable with any number of connections taken away
    AM_Chest_04_Lock = { pieces = { 1, 0, 3, -1, 1, 1 },
        connections = { { 2, 1, -1 }, { 4, 0, -1 }, { 1, 2, -1 }, { 0, 2, -1 }, { 4, 1, -1 }, { 1, 3, -1 }, { 3, 5, 1 }, { 5, 2, -1 } } },
    -- not solvable with exactly 3 or 4 taken away
    FM_Chest_Digginggallery_02_Lock = { pieces = { 0, 1, 2, 1, -3 },
        connections = { { 2, 1, 1 }, { 2, 0, -1 }, { 0, 3, -1 }, { 1, 0, 1 }, { 1, 4, -1 }, { 3, 4, -1 }, { 1, 2, -1 }, { 3, 2, -1 }, { 4, 0, 1 }, { 4, 1, -1 } } },
}

-- Every lock of the game (made from the game's script source by tools/make_tables.py), by name, in the form the
-- model plays: pieces = start positions, connections = { id, connectedId, direction } in the game's order.
local GAMELOCKS = dofile(HERE .. "gamelocks.lua")
local BYNAME = {}
for _, entry in ipairs(GAMELOCKS) do
    local def = { pieces = entry.p, connections = {}, used = entry.used, ways = entry.ways }
    for i = 1, #entry.c, 3 do def.connections[#def.connections + 1] = { entry.c[i], entry.c[i + 1], entry.c[i + 2] } end
    BYNAME[entry.name] = def
end
-- The function of the game that starts the lock of a chest (see world.openChest).
local HOOK = "/Script/G1R.GameplayAbilityOpen:OnIntroFinished"

local function round(v) return math.floor(v + 0.5) end
local function fname(text) return { ToString = function() return text end } end

-- options: level (the hero's level at the start, default untrained), noController, noTags (the ability system has
-- no HasGameplayTag), tagError (HasGameplayTag raises; world.tagError does the same while the game runs), noSet
-- (the hero has no lock picking attributes), noHook (the game has no function OnIntroFinished to hook).
-- world.tagAnswer = function: what HasGameplayTag answers instead of true / false.
local function game(ue, options)
    options = options or {}
    local world = T.newWorld(ue, { noController = options.noController })
    world.calls = {}            -- function name -> calls made by the module
    world.asked = {}            -- attribute name -> how often its struct was read from a set
    world.tagAsked = {}         -- tag name -> how often it was asked for
    world.stores = {}           -- set -> its attributes
    world.pending = {}          -- what the game writes at its next tick
    local function called(name) world.calls[name] = (world.calls[name] or 0) + 1 end
    function world.called(name) return world.calls[name] or 0 end
    -- /Script/G1R.GameplayAbilityOpen:OnIntroFinished is a UFunction of the game (its native thunk is in the
    -- executable, 0x145477160), so RegisterHook finds it.
    if not options.noHook then ue.functions[HOOK] = true end

    -- Attributes are served from a store, so that the module's reads can be counted.
    local function instrument(set)
        local store = {}
        for k, v in pairs(set) do
            if type(v) == "table" and rawget(v, "BaseValue") ~= nil then store[k] = v end
        end
        for k in pairs(store) do rawset(set, k, nil) end
        local meta = getmetatable(set)
        setmetatable(set, { __index = function(_, k)
            local a = store[k]
            if a ~= nil then
                world.asked[k] = (world.asked[k] or 0) + 1
                return a
            end
            return meta.__index[k]
        end })
        world.stores[set] = store
        return store
    end

    -- A hero as the module meets him: the attribute set AttributeSet_Lockpicking with LockpickDurability and
    -- LockpickPrecision (property layout; native class /Script/G1R.AttributeSet_Lockpicking) in the list of his
    -- ability system, and UAngelscriptAbilitySystemComponent::HasGameplayTag(FGameplayTag) -> bool (facts G8 of the
    -- module regen: a tag below the asked one counts). A gameplay tag arrives as a table with its name.
    function world.adopt(h, level)
        local path = h.state.__full:match("^%S+ (.*)$")
        h.tags = {}
        -- The hero's ability of opening a chest: an object of the game's script class UGA_Human_OpenContainer
        -- (as-src GAS/Abilities/Interact/GA_Human_OpenContainer.as; it derives from the native GameplayAbilityOpen,
        -- which has the property m_Lock and the function OnIntroFinished). The ability system creates such an
        -- object inside its owner - for the hero his player state (engine source: instanced abilities get the
        -- ability system's owner as outer) - and the game uses the same one for every chest; m_Lock is the name
        -- of the chest's lock (names of this form are in the log of a real session: NC_Chest_Torlof_Lock).
        h.open = ue:object(("GA_Human_OpenContainer %s.GA_Human_OpenContainer_%d"):format(path, h.n + 7), { m_Lock = fname("None") })
        if not options.noSet then
            h.locks = ue:object(("AttributeSet_Lockpicking %s.AttributeSet_Lockpicking_%d"):format(path, h.n + 4), {
                LockpickDurability = { BaseValue = 0.0, CurrentValue = 0.0 }, LockpickPrecision = { BaseValue = 0.0, CurrentValue = 0.0 } })
            table.insert(h.component.SpawnedAttributes.items, h.locks)
            h.store = instrument(h.locks)
        end
        if not options.noTags then
            rawset(h.component, "HasGameplayTag", function(self, tag)
                called("HasGameplayTag")
                if options.tagError or world.tagError then error("HasGameplayTag failed (test)") end
                if world.tagAnswer then return world.tagAnswer() end
                if type(tag) ~= "table" or type(tag.TagName) ~= "table" or tag.TagName.__s == nil then error("parameter 1 is not a gameplay tag") end
                local text = tag.TagName.__s
                world.tagAsked[text] = (world.tagAsked[text] or 0) + 1
                for owned, n in pairs(h.tags) do
                    if n > 0 and (owned == text or owned:sub(1, #text + 1) == text .. ".") then return true end
                end
                return false
            end)
        end
        world.level(level or options.level or "untrained", h)
        return h
    end

    -- The hero gets a level of the skill: the skill effect removes the effects of the other levels and grants its
    -- tag; a listener of the character then sets the numbers of that tag with an instant effect at the game's next
    -- tick (read from the executable: handler 0x145ad51d0, applied by 0x145ac01c0 with Override modifiers - base and
    -- current value). `later`: the write waits for world.frame().
    function world.level(key, who, later)
        local h = who or world.hero
        for _, l in pairs(LEVELS) do h.tags[l.tag] = nil end
        h.tags[LEVELS[key].tag] = 1
        h.level = key
        local function write()
            if h.store then
                for name, v in pairs({ LockpickPrecision = LEVELS[key].precision, LockpickDurability = LEVELS[key].durability }) do
                    h.store[name].BaseValue, h.store[name].CurrentValue = v + 0.0, v + 0.0
                end
            end
        end
        if later then world.pending[#world.pending + 1] = write else write() end
    end
    function world.frame()
        local list = world.pending
        world.pending = {}
        for _, f in ipairs(list) do f() end
    end
    function world.precision(who) return (who or world.hero).store.LockpickPrecision.CurrentValue end
    function world.durability(who) return (who or world.hero).store.LockpickDurability.CurrentValue end
    function world.bases(who)
        local s = (who or world.hero).store
        return s.LockpickPrecision.BaseValue, s.LockpickDurability.BaseValue
    end
    -- somebody else writes a number (another mod, a cheat): both values, as a direct write does
    function world.write(name, v, who)
        local a = (who or world.hero).store[name]
        a.BaseValue, a.CurrentValue = v, v
    end
    -- An attribute whose writes go wrong (nothing of this has been seen in the game; a module must survive it):
    -- "raises" - the write raises an error; "ignored" - nothing arrives; "base only" - the base value arrives,
    -- the current value does not. Returns what the attribute really holds. world.writesTried counts the tries.
    function world.spoil(name, mode, who)
        local h = who or world.hero
        local real = h.store[name]
        local data = { BaseValue = real.BaseValue, CurrentValue = real.CurrentValue }
        world.writesTried = 0
        h.store[name] = setmetatable({}, {
            __index = data,
            __newindex = function(_, k, v)
                world.writesTried = world.writesTried + 1
                if mode == "raises" then error("the property cannot be written (test)") end
                if mode == "base only" and k == "BaseValue" then data[k] = v end
            end })
        return data
    end

    -- The lock minigame as the game's task runs it (read from the executable: set-up 0x145b8c670, Move 0x145b8d860,
    -- Check 0x145b82320, the task's tick 0x145b8b210, reset 0x145b95d30, tag State.PickLock from the task's
    -- constructor 0x145b72e70 / Activate 0x145b7acf0 / OnDestroy):
    --   * starting: the hero gets the tag State.PickLock; the pick's wrong moves and the number of connections to
    --     leave out are the rounded current values of LockpickDurability and LockpickPrecision (not below 0); the
    --     connections from that number on (in the order of the lock's list) are in force;
    --   * a move takes a piece one step (+1 / -1) and every piece connected from it by step x direction; when a
    --     piece would leave -3 .. 3 nothing moves and the pick loses one wrong move; at 0 it breaks;
    --   * after a broken pick, with another pick in the inventory, the lock is set up again where it stands: the
    --     two numbers are read again;
    --   * all pieces at 0: open. The end takes the tag away.
    function world.startLock(def, picks)
        local h = world.hero
        local lock = { def = def, picks = picks or 1, broken = 0, over = false, opened = false, setUps = 0 }
        h.tags[PICKING] = (h.tags[PICKING] or 0) + 1
        local function finish()
            lock.over = true
            h.tags[PICKING] = h.tags[PICKING] - 1
            if h.tags[PICKING] <= 0 then h.tags[PICKING] = nil end
        end
        local function setUp(first)
            lock.setUps = lock.setUps + 1
            lock.durability = round(math.max(h.store.LockpickDurability.CurrentValue, 0))
            lock.precision = round(math.max(h.store.LockpickPrecision.CurrentValue, 0))
            lock.left = lock.durability
            if first then
                lock.at = {}
                for i, p in ipairs(def.pieces) do lock.at[i] = p end
            end
            lock.links, lock.inForce = {}, 0
            for i = lock.precision + 1, #def.connections do
                local c = def.connections[i]
                lock.links[c[1]] = lock.links[c[1]] or {}
                table.insert(lock.links[c[1]], { c[2], c[3] })
                lock.inForce = lock.inForce + 1
            end
        end
        setUp(true)
        -- piece: its id (0 ...); step: +1 or -1. Returns "moved", "blocked", "broke", "open" or "over".
        function lock.move(piece, step)
            if lock.over then return "over" end
            local t = {}
            for i, p in ipairs(lock.at) do t[i] = p end
            t[piece + 1] = t[piece + 1] + step
            for _, link in ipairs(lock.links[piece] or {}) do t[link[1] + 1] = t[link[1] + 1] + step * link[2] end
            for _, p in ipairs(t) do
                if p < -3 or p > 3 then
                    lock.left = lock.left - 1
                    if lock.left > 0 then return "blocked" end
                    lock.broken, lock.picks = lock.broken + 1, lock.picks - 1
                    if lock.picks > 0 then setUp(false) else finish() end
                    return "broke"
                end
            end
            lock.at = t
            for _, p in ipairs(t) do
                if p ~= 0 then return "moved" end
            end
            lock.opened = true
            finish()
            return "open"
        end
        function lock.reset()
            for i, p in ipairs(def.pieces) do lock.at[i] = p end
        end
        -- the player gives up (the task ends)
        function lock.leave() if not lock.over then finish() end end
        -- Can the lock be opened from where it stands, with the connections in force? (a search over all positions)
        function lock.solvable()
            local n = #lock.at
            local function key(t)
                local x = 0
                for i = n, 1, -1 do x = x * 7 + t[i] + 3 end
                return x
            end
            local seen, queue, head = { [key(lock.at)] = true }, { lock.at }, 1
            while queue[head] do
                local at = queue[head]
                head = head + 1
                local done = true
                for i = 1, n do if at[i] ~= 0 then done = false break end end
                if done then return true end
                for piece = 0, n - 1 do
                    for step = -1, 1, 2 do
                        local t, ok = {}, true
                        for i = 1, n do t[i] = at[i] end
                        t[piece + 1] = t[piece + 1] + step
                        for _, link in ipairs(lock.links[piece] or {}) do t[link[1] + 1] = t[link[1] + 1] + step * link[2] end
                        for i = 1, n do if t[i] < -3 or t[i] > 3 then ok = false break end end
                        if ok then
                            local k = key(t)
                            if not seen[k] then
                                seen[k] = true
                                queue[#queue + 1] = t
                            end
                        end
                    end
                end
            end
            return false
        end
        world.lock = lock
        return lock
    end

    -- Opening a chest (read from the executable): the ability plays its intro and the montage's end calls the
    -- UFunction OnIntroFinished by name (thunk 0x145477160 -> 0x145aad610). That function - when the chest is
    -- locked - creates the lock task with the ability's m_Lock and activates it at once: the lock is set up
    -- inside this call. A function hooked before it runs first. `locked` = false: the chest is not locked (any
    -- more), no lock is started. `who`: another character's ability object.
    function world.openChest(lockName, locked, who)
        local chest = who or world.hero.open
        chest.m_Lock = fname(lockName)
        ue:fireHook(HOOK, { get = function() return chest end })
        if locked == false or who ~= nil then return nil end
        local def = BYNAME[lockName] or world.unknownLock
        if def == nil then
            -- (a name is the same name in any spelling of capital and small letters: the engine's names are that way)
            for name, d in pairs(BYNAME) do
                if name:lower() == lockName:lower() then def = d end
            end
        end
        return world.startLock((assert(def, "the model has no lock " .. lockName)))
    end
    -- A door: its lock task is created by another function of the game (0x145aaeaa0, reached through a virtual
    -- call, with no UFunction in front of it that the module knows): nothing runs before the lock is set up.
    function world.openDoor(lockName)
        return world.startLock((assert(BYNAME[lockName], "the model has no lock " .. lockName)))
    end

    -- Saving and loading (read from the executable, 0x14590d000 / 0x14590df20): a save holds every attribute of
    -- every attribute set with base and current value as they are; a load brings a new player state with new
    -- attribute sets, copies the saved values in, then restores the active effects - the skill effect grants its
    -- tag anew, and the game sets the numbers of that tag (see world.level). `noHeal`: that last step does not
    -- happen (it has not been seen in the game).
    function world.save()
        local s = world.hero.store
        return { level = world.hero.level,
            precision = { s.LockpickPrecision.BaseValue, s.LockpickPrecision.CurrentValue },
            durability = { s.LockpickDurability.BaseValue, s.LockpickDurability.CurrentValue } }
    end
    world.heroes = 0
    function world.load(saved, noHeal)
        ue:fireLoadMapPre("engine", "world", "url", nil, "")
        local old = world.hero
        for _, o in ipairs({ old.locks, old.state, old.component, world.controller }) do o.__valid = false end
        world.heroes = world.heroes + 1
        local fresh = T.hero(ue, world, 100 * world.heroes + 30)
        world.hero = fresh
        world.adopt(fresh, saved.level)
        local s = fresh.store
        s.LockpickPrecision.BaseValue, s.LockpickPrecision.CurrentValue = saved.precision[1], saved.precision[2]
        s.LockpickDurability.BaseValue, s.LockpickDurability.CurrentValue = saved.durability[1], saved.durability[2]
        if not noHeal then world.level(saved.level, fresh) end
        world.controller = T.controllerOf(ue, 100 * world.heroes + 5, fresh.state, {
            Pawn = world.pawn, K2_GetPawn = function() return world.pawn end, GetWorld = function() return world.world end })
        ue.allOf["GothicPlayerControllerBaseBP_C"] = { world.controllerDefault, world.controller }
        ue:fireLoadMapPost("engine", "world", "url", nil, "")
        return fresh
    end

    world.adopt(world.hero)
    return world
end

local function start(case, options)
    options = options or {}
    options.module, options.hook = "locks", "LOCKS_TEST"
    if options.prepare == nil then
        local gameOptions = options.game
        options.prepare = function(ue) return game(ue, gameOptions) end
    end
    local c = T.boot(case, options)
    c.S = c.hook and c.hook.state
    function c.precision() return c.world.precision() end
    function c.durability() return c.world.durability() end
    return c
end
-- Ends a case. An error the module caught inside a look or inside its hook ("update error", "error in the chest
-- hook") fails the case, unless the case is about exactly that (`caught` = true).
local function stop(c, caught)
    if not caught then
        local line = printed(c.ue, "[G1R_Locks] update error") or printed(c.ue, "[G1R_Locks] error in the chest hook")
        if line then check(false, "the case " .. tostring(c.case) .. " ran into an error: " .. line:gsub("\n", "")) end
    end
    T.stop(c)
end
local function allOf(ue) return ue.calls.FindAllOf or 0 end
local function status(c) return table.concat(c.hook.status(), "|") end
local function sum(t) local n = 0 for _, v in pairs(t) do n = n + v end return n end

-- Most cases look at the game at every tick (a quarter second); the shipped pace has its own section.
local QUICK = "\nConfig.LookSeconds = 0.25"
local function config(body) return T.config((body or "") .. QUICK) end
-- The settings of the player this module was written for, as the installer carries them over from the other mod
-- (see the module's report): untrained as the game has it, skilled "safe", master all, one log line per lock.
local PLAYER_SAFE = 'Config.SkilledConnections = "safe"\nConfig.MasterConnections = "all"\nConfig.LogLocks = true'
-- The same with a fixed choice for the skilled hero (most cases need no lock table and no hook).
local PLAYER = 'Config.SkilledConnections = "2"\nConfig.MasterConnections = "all"\nConfig.LogLocks = true'
local shipped = T.read(MOD .. "modules/locks/Scripts/config.lua")

-- ---------------------------------------------------------------------------
section("1. loading with the shipped settings")
do
    local c = start("load", { game = { level = "master" } })
    local ue, w = c.ue, c.world
    check(c.ok, "the module loads (" .. tostring(c.err) .. ")")
    check(#ue.printed == 1 and ue.printed[1] == "[G1R_Locks] v1.0.0 loaded: locks and lock picks as the game has them\n", "one load line: " .. tostring(ue.printed[1]):gsub("\n", ""))
    check(#ue.loops == 2 and ue.loops[2].ms == 250 and math.type(ue.loops[2].ms) == "integer", "one game-thread loop of its own, every 250 ms")
    check(ue.console.locks ~= nil and ue.console.g1r_locks ~= nil and #ue.loadMapPre == 1 and #ue.loadMapPost == 1, "console commands locks and g1r_locks; the kit's hooks before and after a map load")
    check(#ue.lookups == 0 and allOf(ue) == 0 and (ue.calls.FindFirstOf or 0) == 0 and (ue.calls.RegisterHook or 0) == 0 and (ue.calls.NotifyOnNewObject or 0) == 0 and #ue.errors == 0,
        "loading searches for nothing, hooks nothing and asks for no notification")
    local v = c.hook.settings.values
    check(v.Enabled == true and v.UntrainedConnections == "as the game has it" and v.SkilledConnections == "as the game has it" and v.MasterConnections == "as the game has it"
        and v.PicksNeverBreak == false and v.UntrainedWrongMoves == 0 and v.SkilledWrongMoves == 0 and v.MasterWrongMoves == 0
        and v.ShowMessage == true and v.LogLocks == false and v.LookSeconds == 1, "the shipped file gives the documented defaults")
    c.ticks(40)
    local lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(8)
    check(lock.precision == 2 and lock.durability == 6 and lock.inForce == 6 and c.precision() == 2 and c.durability() == 6,
        "a master's lock as the game has it: 2 of 8 connections left out, the pick takes 6 wrong moves")
    lock.leave()
    c.ticks(8)
    check(allOf(ue) == 0 and #ue.lookups == 0 and w.reads[21] == nil and sum(w.asked) == 0 and w.called("HasGameplayTag") == 0 and #ue.errors == 0,
        "with nothing to change the module does not look at the game at all: no search, no read, no question")
    local lines = c.hook.status()
    check(#lines == 3 and lines[1] == "v1.0.0 | locks and lock picks as the game has them" and lines[2] == "nothing to change: the game is not looked at"
        and lines[3] == "locks started: 0 (with this module's numbers: 0); values written: 0, put back: 0, rewritten by the game: 0", "the status says so, in three lines")
    check(T.read(c.path) == shipped, "the settings file is left as it is")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("2. the player's settings: a master's lock has no connections")
do
    local c = start("master", { config = config(PLAYER_SAFE), game = { level = "master" }, diag = true })
    local ue, w = c.ue, c.world
    check(printed(ue, "loaded: connections taken away game / safe / all (untrained / skilled / master); wrong moves per pick game / game / game") ~= nil, "the load line names the choices")
    check(c.precision() == 2, "before the first look the number is the game's (2)")
    c.ticks(1)
    local base = w.bases()
    check(c.precision() == 99 and base == 99 and c.durability() == 6, "the first look writes 99 (more than any lock has) into the base and the current value; the pick's number is not touched")
    check(c.S.via == "player state" and c.S.tier.key == "master" and c.S.tierBy == "tags" and c.S.mark.LockpickPrecision == 99 and c.S.mark.LockpickDurability == nil,
        "found through the player state, level told by the skill tag, the number is marked as this module's")
    check(allOf(ue) == 1 and #ue.lookups == 1, "one search for the controller, none for the attributes (and one by path for the note, which this model does not have: " .. #ue.lookups .. ")")
    check(w.asked.LockpickDurability == nil, "the pick's number, which no setting changes, is not even read")
    c.ticks(20)
    check(c.S.writes == 1 and c.precision() == 99, "it stays: 20 more looks write nothing")
    local lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    check(lock.precision == 99 and lock.inForce == 0, "the lock is set up without any connection")
    c.ticks(1)
    check(printed(ue, "[G1R_Locks] lock started - master: all connections taken away (the game: 2)\n") ~= nil and c.S.locks == 1 and c.S.changed == 1, "the next look notices the lock: one log line")
    -- every piece moves alone: bring each to 0
    local moves, result = 0, nil
    for piece, at in ipairs(LOCKS.AM_Chest_04_Lock.pieces) do
        for _ = 1, math.abs(at) do
            result = lock.move(piece - 1, at > 0 and -1 or 1)
            moves = moves + 1
        end
    end
    check(result == "open" and moves == 7 and lock.broken == 0, "every piece moves alone: open after 7 moves, one per step a piece is off")
    c.ticks(2)
    check(c.S.picking == false and c.precision() == 99, "the lock is over; the number stays for the next one")
    check(status(c) == "v1.0.0 | connections taken away game / safe / all (untrained / skilled / master); wrong moves per pick game / game / game"
        .. "|the hero is master (told by his skill tag); connections taken away 99 (this module's; the game's own: 2); wrong moves per pick as the game has it (not looked at)"
        .. "|locks started: 1 (with this module's numbers: 1); last - master: all connections taken away (the game: 2); values written: 1, put back: 0, rewritten by the game: 0",
        "the status: " .. status(c))
    check(w.precision() == 99 and w.durability() == 6 and w.value("Experience") == 6702 and w.value("Health") == 80 and #ue.errors == 0, "nothing else of the hero is touched, no error")
    check((ue.calls.RegisterHook or 0) == 0 and (ue.calls.NotifyOnNewObject or 0) == 0 and c.S.hooked == nil and c.fake.value("locks.lock_table") == nil,
        "for a master with \"all\" nothing is hooked and no notification asked for, although the skilled level is set to \"safe\": the hook and the table are only for a hero at that level")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("3. every choice at every level, and what it does to a lock")
do
    -- what a lock of 8 connections is set up with, by level and choice
    local expect = {
        untrained = { ["as the game has it"] = 0, none = 0, ["1"] = 1, ["2"] = 2, all = 99 },
        skilled = { ["as the game has it"] = 1, none = 0, ["1"] = 1, ["2"] = 2, all = 99 },
        master = { ["as the game has it"] = 2, none = 0, ["1"] = 1, ["2"] = 2, all = 99 },
    }
    local keys = { untrained = "UntrainedConnections", skilled = "SkilledConnections", master = "MasterConnections" }
    local good, marks, writes, solvable = true, true, true, true
    for _, level in ipairs({ "untrained", "skilled", "master" }) do
        for _, choice in ipairs({ "as the game has it", "none", "1", "2", "all" }) do
            local c = start("choice", { config = config(('Config.%s = "%s"'):format(keys[level], choice)), game = { level = level } })
            c.ticks(2)
            local want = expect[level][choice]
            local own = LEVELS[level].precision
            if c.precision() ~= want or (c.world.bases()) ~= want then good = false end
            -- a number that is the game's own is not marked, and nothing is written for it
            if (c.S.mark.LockpickPrecision ~= nil) ~= (want ~= own) then marks = false end
            if c.S.writes ~= ((want ~= own) and 1 or 0) then writes = false end
            for name in pairs(LOCKS) do
                -- the lock is set up with that many connections less, and the way the test data has for that
                -- number opens it, move by move
                local def = BYNAME[name]
                local lock = c.world.startLock(def)
                local result = nil
                for piece, sign in def.ways[math.min(want, #def.connections)]:gmatch("(%d)([+-])") do result = lock.move(tonumber(piece), sign == "+" and 1 or -1) end
                if lock.inForce ~= math.max(#def.connections - want, 0) or result ~= "open" or lock.broken ~= 0 then solvable = false end
            end
            stop(c)
        end
    end
    check(good, "15 cases (3 levels x 5 choices): the number in the hero's attribute is the chosen one, base and current value")
    check(marks and writes, "a choice that is the game's own number for the level writes nothing and marks nothing")
    check(solvable, "in every case both locks are set up with that many connections less, and are opened by the moves the test data has for that number")

    -- the other levels' choices do not count for the hero's level
    local c = start("other-levels", { config = config('Config.UntrainedConnections = "all"\nConfig.MasterConnections = "none"'), game = { level = "skilled" } })
    c.ticks(4)
    check(c.precision() == 1 and c.S.writes == 0 and c.world.asked.LockpickPrecision == nil and c.S.tier.key == "skilled",
        "choices for the untrained and the master do nothing to a skilled hero: his number is not even read")
    stop(c)

    -- why the choices stop at 2: the game's lock FM_Chest_Digginggallery_02 with 3 connections taken away
    c = start("why-not-3", { game = { level = "master" } })
    local opens = {}
    for removed = 0, 10 do
        c.world.write("LockpickPrecision", removed)
        local lock = c.world.startLock(LOCKS.FM_Chest_Digginggallery_02_Lock)
        opens[#opens + 1] = lock.solvable() and "y" or "n"
        lock.leave()
    end
    check(table.concat(opens) == "yyynnyyyyyy", "that lock can be opened with 0, 1, 2 and with 5 to 10 connections taken away, not with 3 or 4: " .. table.concat(opens))
    stop(c)
end

-- ---------------------------------------------------------------------------
section("4. the hero learns a level: the game writes its numbers, the module the chosen ones")
do
    local c = start("learn", { config = config(PLAYER), diag = true })
    local ue, w = c.ue, c.world
    c.ticks(2)
    check(c.precision() == 0 and c.S.writes == 0 and c.S.tier.key == "untrained" and c.fake.value("locks.level") == "untrained", "untrained, as the game has it: nothing is written")
    w.level("skilled")
    check(c.precision() == 1 and c.durability() == 4, "(the game sets 1 and 4 when the hero becomes skilled)")
    c.ticks(1)
    check(c.precision() == 2 and c.durability() == 4 and c.S.tier.key == "skilled" and c.S.writes == 1 and c.fake.value("locks.level") == "skilled",
        "skilled: the next look writes the chosen 2")
    w.level("master")
    c.ticks(1)
    check(c.precision() == 99 and c.durability() == 6 and c.S.tier.key == "master" and c.S.writes == 2, "master: the chosen 99")
    check(c.S.rewritten == 0 and c.fake.value("locks.rewritten") == nil, "(the game's 2 for a master is the number the module had written for the skilled: nothing to notice)")
    -- the game's write comes a tick after the tag (its listener sets a timer for the next tick)
    w.level("skilled", nil, true)
    c.ticks(1)
    check(c.precision() == 2 and c.S.tier.key == "skilled" and c.S.writes == 3, "the tag is there, the game's write is not yet: the module writes the number of the new level (2)")
    w.frame()
    check(c.precision() == 1, "(then the game's write arrives: 1)")
    c.ticks(1)
    check(c.precision() == 2 and c.S.writes == 4 and c.S.rewritten == 1 and c.fake.value("locks.rewritten") == "seen" and c.fake.detail("locks.rewritten") == "LockpickPrecision 2 -> 1",
        "the next look puts the 2 back in; noted as rewritten by the game")
    -- back to a level whose choice is the game's own
    w.level("untrained")
    c.ticks(1)
    check(c.precision() == 0 and c.S.mark.LockpickPrecision == nil and c.S.writes == 4 and c.S.putBack == 0, "untrained again: the game's own number stands, nothing to write or put back")
    -- the game does not write at all (not seen in the game: the module must not depend on it)
    w.hero.tags[LEVELS.untrained.tag] = nil
    w.hero.tags[LEVELS.master.tag] = 1
    c.ticks(1)
    check(c.precision() == 99 and c.S.tier.key == "master", "a new tag without any write of the game: the module's number for that level")
    w.hero.tags[LEVELS.master.tag] = nil
    w.hero.tags[LEVELS.untrained.tag] = 1
    c.ticks(1)
    check(c.precision() == 0 and c.S.putBack == 1 and c.S.mark.LockpickPrecision == nil and c.fake.value("locks.put_back") == "ok",
        "and back to a level left to the game: the game's own number for THAT level is put back (0, not the master's 2)")
    check(#ue.errors == 0 and allOf(ue) == 1, "no error, no further search")
    stop(c)

    -- the tags are asked from the top
    c = start("tag-order", { config = config(PLAYER), game = { level = "skilled" } })
    w = c.world
    c.ticks(1)
    check(w.tagAsked[LEVELS.master.tag] == 1 and w.tagAsked[LEVELS.skilled.tag] == 1 and w.tagAsked[LEVELS.untrained.tag] == nil and w.tagAsked[PICKING] == 1,
        "a look asks for master, then skilled - and stops at the tag the hero has; then for a lock being picked")
    c.ticks(10)
    check(w.tagAsked[LEVELS.master.tag] == 11 and w.tagAsked[LEVELS.skilled.tag] == 11 and w.tagAsked[LEVELS.untrained.tag] == nil and w.tagAsked[PICKING] == 11, "the same at every look")
    -- two of the tags at once (the game takes the lower one off when a level is learned; should it ever not)
    w.hero.tags[LEVELS.master.tag] = 1
    w.write("LockpickPrecision", 2)
    c.ticks(1)
    check(c.S.tier.key == "master" and c.precision() == 99, "a hero with two of the skill tags: the higher level counts")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("5. lock picks: wrong moves before a pick breaks")
do
    -- a move that cannot be made: piece 2 of AM_Chest_04 stands at 3 and cannot go further up
    local function wrongMoves(lock, limit)
        local n = 0
        while n < limit do
            n = n + 1
            local result = lock.move(2, 1)
            if result == "broke" then return n end
        end
        return nil
    end
    local c = start("moves", { config = config("Config.UntrainedWrongMoves = 5\nConfig.SkilledWrongMoves = 1\nConfig.MasterWrongMoves = 20"), game = { level = "untrained" } })
    local ue, w = c.ue, c.world
    check(printed(ue, "loaded: connections taken away game / game / game (untrained / skilled / master); wrong moves per pick 5 / 1 / 20") ~= nil, "the load line names the three numbers")
    c.ticks(1)
    local _, base = w.bases()
    check(c.durability() == 5 and base == 5 and c.precision() == 0 and c.S.mark.LockpickDurability == 5 and w.asked.LockpickPrecision == nil,
        "untrained: 5 wrong moves instead of 2 (base and current value); the connections are not touched, not even read")
    check(wrongMoves(w.startLock(LOCKS.AM_Chest_04_Lock), 50) == 5, "the pick breaks at the 5th move that cannot be made")
    c.ticks(1)
    w.level("skilled")
    c.ticks(1)
    check(c.durability() == 1 and wrongMoves(w.startLock(LOCKS.AM_Chest_04_Lock), 50) == 1, "skilled with 1: the first wrong move breaks the pick (harder than the game's 4)")
    c.ticks(1)
    w.level("master")
    c.ticks(1)
    check(c.durability() == 20 and wrongMoves(w.startLock(LOCKS.AM_Chest_04_Lock), 50) == 20, "master with 20")
    stop(c)

    c = start("moves-own", { config = config("Config.UntrainedWrongMoves = 2\nConfig.SkilledWrongMoves = 4\nConfig.MasterWrongMoves = 6"), game = { level = "skilled" } })
    c.ticks(3)
    check(c.durability() == 4 and c.S.writes == 0 and c.S.mark.LockpickDurability == nil, "the game's own numbers chosen as numbers: nothing is written, nothing marked")
    c.world.level("untrained")
    c.ticks(2)
    c.world.level("master")
    c.ticks(2)
    check(c.durability() == 6 and c.S.writes == 0 and c.S.putBack == 0 and c.S.rewritten == 0, "the same at the other two levels (2 for the untrained, 6 for the master)")
    stop(c)

    -- one number alone, at each level: written, and put back to that level's own when it is set to 0 again
    for _, level in ipairs({ "untrained", "skilled", "master" }) do
        local key = level:sub(1, 1):upper() .. level:sub(2) .. "WrongMoves"
        c = start("moves-one-" .. level, { config = config("Config." .. key .. " = 1"), game = { level = level } })
        c.ticks(1)
        local written = c.durability()
        T.write(c.path, config(""))
        c.ue:fireConsole("locks reload")
        c.ticks(1)
        check(written == 1 and c.durability() == LEVELS[level].durability and c.S.writes == 1 and c.S.putBack == 1 and c.S.awake == false,
            ("%s: a single wrong move as the only setting is written; set to 0 again, the level's own %d is put back and the module rests"):format(level, LEVELS[level].durability))
        stop(c)
    end
    c = start("never-alone", { config = config("Config.PicksNeverBreak = true"), game = { level = "untrained" } })
    c.ticks(1)
    check(c.durability() == 100000 and c.S.mark.LockpickDurability == 100000 and c.world.asked.LockpickPrecision == nil, "lock picks that do not break as the only setting: written at any level")
    stop(c)

    c = start("never", { config = config("Config.PicksNeverBreak = true\nConfig.MasterWrongMoves = 3"), game = { level = "master" }, widgets = true })
    w = c.world
    check(printed(c.ue, "loaded: connections taken away game / game / game (untrained / skilled / master); lock picks do not break") ~= nil, "lock picks do not break: the load line says so")
    c.ticks(1)
    check(c.durability() == 100000 and c.precision() == 2, "the pick's number is 100000 at any level (the level's own number of wrong moves is not used)")
    local lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    check(wrongMoves(lock, 500) == nil and lock.left == 100000 - 500 and lock.broken == 0, "500 wrong moves later the pick is still whole")
    c.ticks(1)
    check(c.ui.note() == "Lock picking (master): the pick does not break", "the note on screen: " .. tostring(c.ui.note()))
    lock.leave()
    for _, level in ipairs({ "untrained", "skilled" }) do
        w.level(level)
        c.ticks(1)
        if c.durability() ~= 100000 then check(false, "never-breaking picks at level " .. level) end
    end
    stop(c)

    c = start("both", { config = config('Config.MasterConnections = "none"\nConfig.MasterWrongMoves = 99'), game = { level = "master" }, widgets = true })
    w = c.world
    c.ticks(1)
    check(c.precision() == 0 and c.durability() == 99, "both numbers at once: a master with every connection in place and 99 wrong moves")
    lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(1)
    check(lock.inForce == 8 and c.ui.note() == "Lock picking (master): no connection taken away, the pick breaks after 99 wrong moves", "the note names both: " .. tostring(c.ui.note()))
    stop(c)

    -- out of range, not a number
    c = start("moves-range", { config = config('Config.MasterWrongMoves = 500\nConfig.SkilledWrongMoves = -3\nConfig.UntrainedWrongMoves = "many"\nConfig.MasterConnections = "3"') })
    local v = c.hook.settings.values
    check(v.MasterWrongMoves == 99 and v.SkilledWrongMoves == 0 and v.UntrainedWrongMoves == 0 and v.MasterConnections == "as the game has it"
        and printed(c.ue, 'config.lua: MasterConnections = 3 is not usable; "as the game has it" is used') ~= nil,
        "500 is taken as 99, -3 as 0, a text as 0; a choice that is not offered (3) as the game's own - said in the log")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("6. while a lock is being picked nothing is written")
do
    -- what the wait is for: the game sets a lock up again after a broken pick, where the pieces stand
    local c = start("why-hold", { game = { level = "master" } })
    local w = c.world
    w.write("LockpickPrecision", 99)
    local lock = w.startLock(LOCKS.FM_Chest_Digginggallery_02_Lock, 3)
    check(lock.move(0, -1) == "moved" and lock.solvable(), "(a lock without connections: a piece moved alone)")
    w.write("LockpickPrecision", 2)             -- the number changes in the middle of the lock ...
    while lock.setUps < 2 do lock.move(4, -1) end       -- ... and a pick breaks (piece 4 stands at -3 and cannot go further)
    check(lock.broken == 1 and lock.precision == 2 and lock.inForce == 8 and not lock.solvable(),
        "a number that changes during a lock counts from the next broken pick on: here the lock can no longer be opened from where it stands")
    lock.reset()
    check(lock.solvable(), "(only putting the pieces back to the start helps)")
    stop(c)

    c = start("hold", { config = config('Config.MasterConnections = "all"\nConfig.MasterWrongMoves = 3'), game = { level = "master" }, diag = true })
    local ue
    ue, w = c.ue, c.world
    c.ticks(1)
    lock = w.startLock(LOCKS.FM_Chest_Digginggallery_02_Lock, 3)
    c.ticks(1)
    check(c.S.picking == true and lock.precision == 99 and lock.durability == 3 and c.fake.value("locks.minigame") == "seen" and c.fake.value("locks.in_place") == "yes",
        "the look notices the lock; the module's numbers were in place when it was set up")
    local asked = sum(w.asked)
    -- the settings change in the middle of the lock
    T.write(c.path, config('Config.MasterConnections = "2"\nConfig.MasterWrongMoves = 9'))
    ue:fireConsole("locks reload")
    c.ticks(8)
    check(c.precision() == 99 and c.durability() == 3 and c.S.writes == 2 and sum(w.asked) == asked, "new settings during a lock: nothing is written, nothing is even read")
    check(has(status(c), "|a lock is being picked: nothing is changed until it is over|"), "the status says why")
    lock.move(1, -1)
    for _ = 1, 3 do lock.move(4, -1) end
    check(lock.broken == 1 and lock.setUps == 2 and lock.precision == 99 and lock.durability == 3 and lock.solvable(),
        "a pick breaks: the lock is set up again with the numbers it was started with, and can still be opened")
    lock.leave()
    c.ticks(1)
    check(c.precision() == 2 and c.durability() == 9 and c.S.picking == false and c.S.mark.LockpickPrecision == nil and c.S.mark.LockpickDurability == 9,
        "the lock is over: now the new numbers are written (2 is the game's own for a master: put back; 9 wrong moves)")
    check(c.S.writes == 4 and c.S.putBack == 0, "two writes (a chosen number is written like any other, also where it is the game's own)")
    -- the module is switched off in the middle of a lock
    lock = w.startLock(LOCKS.AM_Chest_04_Lock, 2)
    c.ticks(1)
    T.write(c.path, config('Config.Enabled = false\nConfig.MasterWrongMoves = 9'))
    ue:fireConsole("locks reload")
    c.ticks(8)
    check(c.durability() == 9 and c.S.mark.LockpickDurability == 9 and c.S.picking == true, "switched off during a lock: what was written stays until the lock is over")
    lock.leave()
    c.ticks(1)
    check(c.durability() == 6 and c.S.putBack == 1 and c.S.mark.LockpickDurability == nil, "then the game's own number is put back")
    asked = sum(w.asked)
    local questions = w.called("HasGameplayTag")
    c.ticks(40)
    check(sum(w.asked) == asked and w.called("HasGameplayTag") == questions and c.S.setName == nil and #ue.errors == 0, "and after that the game is not looked at any more")
    stop(c)

    -- a lock that is already being picked when the module first looks
    c = start("hold-first", { config = config('Config.MasterConnections = "all"'), game = { level = "master" } })
    w = c.world
    lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(5)
    check(c.precision() == 2 and c.S.writes == 0 and c.S.locks == 1 and c.S.changed == 0 and c.S.lastLock == "master: as the game has it",
        "a lock that is already open when the module first looks: left as it is, counted as not changed")
    lock.leave()
    c.ticks(1)
    check(c.precision() == 99, "after it the number is written")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("7. putting back: a level left to the game again, the module switched off")
do
    local c = start("put-back", { config = config('Config.MasterConnections = "all"\nConfig.MasterWrongMoves = 12\nConfig.SkilledConnections = "2"\nConfig.LogLocks = true'), game = { level = "master" }, diag = true })
    local ue, w = c.ue, c.world
    c.ticks(2)
    check(c.precision() == 99 and c.durability() == 12 and printed(ue, "[G1R_Locks] level master: LockpickPrecision -> 99, LockpickDurability -> 12\n") ~= nil,
        "both numbers written, said in the log (LogLocks)")
    -- the master's connections back to the game's own; the pick's number stays
    T.menuSet(c, "Lock picking", "Master", 1)
    c.ticks(1)
    check(c.precision() == 2 and (w.bases()) == 2 and c.durability() == 12 and c.S.putBack == 1 and c.S.mark.LockpickPrecision == nil
        and printed(ue, "[G1R_Locks] level master: LockpickPrecision back to 2\n") ~= nil, "\"as the game has it\" for the master: his 2 is put back at once (base and current value), said in the log")
    local reads = w.asked.LockpickPrecision
    c.ticks(20)
    check(w.asked.LockpickPrecision == reads and w.asked.LockpickDurability > 20, "from then on the connections are not read any more; the pick's number still is")
    -- every level left to the game: the module rests although it is switched on
    T.menuSet(c, "Lock picking", "Master: wrong moves per pick", 0)
    T.menuSet(c, "Lock picking", "Skilled", 1)
    c.ticks(1)
    check(c.durability() == 6 and c.S.putBack == 2 and has(status(c), "v1.0.0 | locks and lock picks as the game has them|nothing to change: the game is not looked at|"),
        "every level as the game has it: the last number is put back, the module rests")
    local asked, questions, finds = sum(w.asked), w.called("HasGameplayTag"), allOf(ue)
    c.ticks(240)
    check(sum(w.asked) == asked and w.called("HasGameplayTag") == questions and allOf(ue) == finds and w.reads[21] ~= nil and c.S.awake == false,
        "a minute later: nothing was read, asked or searched")
    stop(c)

    -- switched off: both numbers back, then nothing
    c = start("off", { config = config('Config.MasterConnections = "none"\nConfig.PicksNeverBreak = true'), game = { level = "master" } })
    ue, w = c.ue, c.world
    c.ticks(1)
    check(c.precision() == 0 and c.durability() == 100000, "(a master with every connection and a pick that does not break)")
    T.menuSet(c, "Lock picking", "Lock picking by skill", false)
    c.ticks(1)
    local pb, db = w.bases()
    check(c.precision() == 2 and c.durability() == 6 and pb == 2 and db == 6 and c.S.putBack == 2 and printed(ue, "settings changed (in-game menu): switched off in the settings") ~= nil,
        "Enabled = false: both numbers are put back to the master's own (2 and 6)")
    asked = sum(w.asked)
    c.ticks(40)
    w.level("skilled")
    c.ticks(40)
    check(sum(w.asked) == asked and c.precision() == 1 and has(status(c), "switched off in the settings|nothing to change: the game is not looked at"), "and the module rests")
    -- switched on again
    T.menuSet(c, "Lock picking", "Lock picking by skill", true)
    T.menuSet(c, "Lock picking", "Skilled", 7)
    c.ticks(1)
    check(c.precision() == 99 and c.durability() == 100000, "switched on again: the numbers for the hero's level are written at the next look")
    stop(c)

    -- switched off from the start
    c = start("off-start", { config = config('Config.Enabled = false\nConfig.MasterConnections = "all"'), game = { level = "master" } })
    check(printed(c.ue, "loaded: switched off in the settings") ~= nil, "Enabled = false at the start: the load line says so")
    c.ticks(40)
    check(c.precision() == 2 and allOf(c.ue) == 0 and sum(c.world.asked) == 0, "nothing is changed, the game is not looked at")
    stop(c)

    -- the hero is gone when the module is switched off
    c = start("off-gone", { config = config('Config.MasterConnections = "all"'), game = { level = "master" } })
    ue, w = c.ue, c.world
    c.ticks(1)
    w.hero.locks.__valid, w.hero.state.__valid, w.controller.__valid = false, false, false
    ue.allOf["GothicPlayerControllerBaseBP_C"] = nil
    T.write(c.path, config("Config.Enabled = false"))
    ue:fireConsole("locks reload")
    c.ticks(3)
    check(c.S.setName == nil and c.S.mark.LockpickPrecision == nil and c.S.awake == false and #ue.errors == 0,
        "switched off while the hero's attributes are gone: nothing to put back, the module rests")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("8. saving and loading")
do
    local c = start("save", { config = config('Config.MasterConnections = "all"'), game = { level = "master" }, diag = true })
    local ue, w = c.ue, c.world
    c.ticks(2)
    local changed = w.save()
    check(changed.precision[1] == 99 and changed.precision[2] == 99, "a save made while the module has the number changed holds the changed number (the game saves every attribute)")
    -- loading it: the game sets its own number, the module writes again
    local old = w.hero
    local fresh = w.load(changed)
    check(w.precision() == 2, "(after the load the game has set the master's 2 again)")
    c.ticks(1)
    check(w.precision() == 99 and old.store.LockpickPrecision.CurrentValue == 99 and c.S.setName == fresh.locks:GetFullName() and c.S.writes == 2,
        "the first look after the load writes into the new attributes")
    check(c.fake.value("locks.found_precision") == "the game's own" and c.fake.count["locks.found_precision"] == 1, "what the new attributes held is noted: the game's own number")
    -- the game does not set its number after a load (not seen in the game)
    w.load(changed, true)
    c.ticks(1)
    check(w.precision() == 99 and c.S.writes == 2 and c.S.mark.LockpickPrecision == 99 and c.fake.value("locks.found_precision") == "this module's number"
        and c.fake.detail("locks.found_precision") == "99 at level master (the game's own: 2)",
        "a load that leaves the saved 99 in place: nothing to write, but the number counts as the module's - and is noted as not the game's own")
    T.menuSet(c, "Lock picking", "Master", 1)
    c.ticks(1)
    check(w.precision() == 2 and c.S.putBack == 1, "so it is put back when the level is left to the game again")
    local clean = w.save()
    check(clean.precision[1] == 2 and clean.precision[2] == 2, "and a save made after that is clean")
    stop(c)

    -- the changed save is loaded while the module is off: the game's own write decides
    c = start("load-off", { config = config("Config.Enabled = false"), game = { level = "master" } })
    w = c.world
    w.load(changed)
    c.ticks(8)
    check(w.precision() == 2 and sum(w.asked) == 0, "the module off, the game sets its number after the load: clean, and the module has not looked")
    w.load(changed, true)
    c.ticks(8)
    check(w.precision() == 99 and sum(w.asked) == 0, "the module off, the game does not: the 99 of the save stays - the module does not look at the game while it is off")
    check(c.ue:fireConsole("locks restore") == true and printed(c.ue, "[G1R_Locks] putting the game's own values back ...\n") ~= nil, "the console word locks restore")
    c.ticks(1)
    check(w.precision() == 2 and (w.bases()) == 2 and printed(c.ue, "[G1R_Locks] the game's own values for the level master were put back: LockpickPrecision back to 2\n") ~= nil,
        "puts the game's own number back at the next look, and says so")
    local asked = sum(w.asked)
    c.ticks(40)
    check(sum(w.asked) == asked and c.S.awake == false, "after that the module rests again")
    stop(c)

    -- A choice that goes by the lock: the number of one chest's lock is in a save that was made while that lock
    -- was being picked. (Whether the game can save then is not known; UE4SS loading the Lua mods anew during a
    -- lock leaves the same behind.) With such a number a door's lock can be impossible to open.
    local FOUND = "[G1R_Locks] LockpickPrecision held 6 between two locks, not the game's own 1 for the level skilled (a number left by a save made in the middle "
        .. "of a lock?): under \"half\" / \"safe\" the game's own number is put back\n"
    c = start("save-lock-door")
    c.world.write("LockpickPrecision", 6)
    check(c.world.openDoor("OC_Gomez_Room_Lock").solvable() == false, "(a door's lock that cannot be opened with exactly 6 of its 10 connections taken away)")
    stop(c)
    c = start("save-lock", { config = config('Config.SkilledConnections = "safe"\nConfig.LogLocks = true'), game = { level = "skilled" }, diag = true })
    ue, w = c.ue, c.world
    c.ticks(2)
    check(c.precision() == 1 and w.asked.LockpickPrecision == 2 and c.fake.value("locks.found_precision") == "the game's own" and c.S.putBack == 0 and c.S.writes == 0
        and printed(ue, "between two locks") == nil, "\"safe\", between locks: the number is looked at at every look - it is the game's own, nothing is written or said")
    local lock = w.openChest("BC_Chest_05_Lock")
    c.ticks(2)
    local inLock = w.save()
    check(lock.precision == 6 and inLock.precision[2] == 6, "(a chest whose lock is proven for all 6 connections; the game saves while it is being picked: the save holds the 6)")
    lock.leave()
    c.ticks(2)
    check(c.precision() == 1 and c.S.putBack == 1 and printed(ue, "between two locks") == nil, "(the lock is over: the game's own 1 is back - the module's own number, nothing to say)")
    w.load(inLock)
    c.ticks(2)
    check(c.precision() == 1 and c.S.putBack == 1 and printed(ue, "between two locks") == nil, "that save is loaded and the game sets its own number: nothing to do")
    w.load(inLock, true)
    check(c.precision() == 6, "(it is loaded and the game does not: the new attributes hold the 6)")
    c.ticks(1)
    local pb = w.bases()
    check(c.precision() == 1 and pb == 1 and c.S.putBack == 2 and c.S.mark.LockpickPrecision == nil and printedCount(ue, FOUND) == 1,
        "the first look at the new attributes puts the game's own number back (base and current value) and says so")
    check(c.fake.value("locks.found_precision") == "another number" and c.fake.detail("locks.found_precision") == "6 at level skilled (the game's own: 1)",
        "noted: what the attributes held")
    lock = w.openDoor("OC_Gomez_Room_Lock")
    c.ticks(2)
    check(lock.precision == 1 and lock.solvable(), "a door after that is set up as the game has it, and can be opened")
    lock.leave()
    c.ticks(1)
    -- also without a load: whatever puts another number there between two locks
    w.write("LockpickPrecision", 4)
    c.ticks(1)
    check(c.precision() == 1 and c.S.putBack == 3 and printedCount(ue, "between two locks") == 1, "another number that appears between two locks is put back at the next look (said once per run)")
    -- the first look falls into a lock: nothing is written under it
    w.load(inLock, true)
    lock = w.openDoor("AMR_Storage_Room_Lock")
    c.ticks(4)
    check(c.precision() == 6 and lock.precision == 6, "the attributes are first seen while a lock is being picked: the number is left alone until the lock is over")
    lock.leave()
    c.ticks(1)
    check(c.precision() == 1 and c.S.putBack == 4, "then it is put back")
    -- a fixed choice has its own way: the number of the choice is the one that stands
    T.menuSet(c, "Lock picking", "Skilled", 7)
    c.ticks(2)
    w.load(w.save(), true)
    c.ticks(4)
    check(c.precision() == 99 and c.S.putBack == 4 and printedCount(ue, "between two locks") == 1, "the fixed choice \"all\" and a load of its save: its 99 stands, nothing is put back")
    stop(c)
    -- The hero's level told wrongly for a moment (after a load his own skill tag may come a moment after
    -- another one): the number of the wrong level does not stay.
    c = start("save-lock-level", { config = config('Config.UntrainedConnections = "safe"\nConfig.MasterConnections = "safe"'), game = { level = "master" } })
    ue, w = c.ue, c.world
    w.write("LockpickPrecision", 6)
    w.hero.tags[LEVELS.master.tag], w.hero.tags[LEVELS.untrained.tag] = nil, 1
    c.ticks(1)
    check(c.precision() == 0 and c.S.tier.key == "untrained" and c.S.putBack == 1,
        "(a master whose tags show the untrained level for a moment, and a 6 left in his attributes: the look puts the untrained hero's own 0 back)")
    w.hero.tags[LEVELS.master.tag], w.hero.tags[LEVELS.untrained.tag] = 1, nil
    c.ticks(1)
    check(c.precision() == 2 and c.S.tier.key == "master" and c.S.putBack == 2, "his own tag is there: the next look puts the master's own 2 back")
    stop(c)
    c = start("save-lock-learn", { config = config('Config.SkilledConnections = "safe"\nConfig.MasterConnections = "safe"'), game = { level = "skilled" } })
    ue, w = c.ue, c.world
    c.ticks(2)
    w.level("master")
    c.ticks(8)
    check(c.precision() == 2 and c.S.putBack == 0 and c.S.writes == 0 and printed(ue, "between two locks") == nil,
        "the hero learns a level (the game writes its own numbers): nothing to put back, nothing said")
    stop(c)
    -- the level is left to the game: its attributes are not looked at, whatever they hold
    c = start("save-lock-game", { config = config('Config.MasterConnections = "safe"'), game = { level = "skilled" } })
    c.world.write("LockpickPrecision", 6)
    c.ticks(8)
    check(c.precision() == 6 and c.world.asked.LockpickPrecision == nil, "\"safe\" for another level than the hero's: his number is not read and not touched")
    stop(c)
    -- a fixed choice: its number is not the game's own, and that is nothing to report
    c = start("save-lock-fixed", { config = config('Config.SkilledConnections = "all"'), game = { level = "skilled" } })
    c.ticks(4)
    check(c.precision() == 99 and printed(c.ue, "between two locks") == nil, "a fixed choice: its number stands, and nothing is said about a number found between two locks")
    stop(c)
    -- switched off: nothing is looked at, whatever the attributes hold
    c = start("save-lock-off", { config = config('Config.SkilledConnections = "safe"\nConfig.Enabled = false'), game = { level = "skilled" } })
    c.world.write("LockpickPrecision", 6)
    c.ticks(8)
    check(c.precision() == 6 and sum(c.world.asked) == 0, "\"safe\" with the module switched off: not read, not touched")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("9. putting the game's values back by hand")
do
    local c = start("restore", { game = { level = "skilled" }, widgets = true })
    local ue, w = c.ue, c.world
    w.write("LockpickPrecision", 99)
    w.write("LockpickDurability", 100000)
    c.ticks(8)
    check(w.precision() == 99 and sum(w.asked) == 0, "(numbers left in a save by an earlier session; the module rests with the shipped settings)")
    check(T.menuItem(c, "Lock picking", "Put the game's own values back now").kind == "action", "the in-game menu has a button for it")
    T.menuSet(c, "Lock picking", "Put the game's own values back now", true)
    c.ticks(2)
    local pb, db = w.bases()
    check(w.precision() == 1 and w.durability() == 4 and pb == 1 and db == 4, "the button: the skilled hero's own numbers (1 and 4) are written, base and current value")
    check(printed(ue, "[G1R_Locks] the game's own values for the level skilled were put back: LockpickPrecision back to 1, LockpickDurability back to 4\n") ~= nil
        and c.ui.note() == "the game's own values for the level skilled were put back: LockpickPrecision back to 1, LockpickDurability back to 4", "said in the log and on screen")
    local asked = sum(w.asked)
    c.ticks(20)
    check(sum(w.asked) == asked and c.S.asked == nil and c.S.awake == false, "one pass, then the module rests again")
    ue:fireConsole("g1r_locks restore")
    c.ticks(2)
    check(printed(ue, "[G1R_Locks] nothing to put back: the hero's lock picking values are the game's own for the level skilled\n") ~= nil and c.S.putBack == 2,
        "a second time: nothing to put back, said so")
    -- during a lock the pass waits
    w.write("LockpickPrecision", 5)
    local lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    ue:fireConsole("locks restore")
    c.ticks(8)
    check(w.precision() == 5 and c.S.asked ~= nil, "asked for while a lock is being picked: it waits")
    lock.leave()
    c.ticks(4)
    check(w.precision() == 1 and c.S.asked == nil, "and runs when the lock is over (at the next look, a second later at most)")
    stop(c)

    -- while the settings change the numbers there is nothing to do by hand
    c = start("restore-active", { config = config('Config.SkilledConnections = "all"'), game = { level = "skilled" }, widgets = true })
    ue, w = c.ue, c.world
    c.ticks(1)
    ue:fireConsole("locks restore")
    c.ticks(2)
    check(w.precision() == 99 and c.S.asked == nil and printed(ue, "[G1R_Locks] the module is changing these values at the moment: switch it off or set every level to \"as the game has it\"") ~= nil,
        "while the settings change the numbers: said that switching off puts them back, nothing is done")
    T.menuSet(c, "Lock picking", "Put the game's own values back now", true)
    c.ticks(2)
    check(w.precision() == 99 and has(tostring(c.ui.note()), "the module is changing these values at the moment"), "the button says the same on screen")
    stop(c)

    -- no game loaded
    c = start("restore-nogame", { config = config("Config.Enabled = false"), prepare = function(ue) return game(ue, { noController = true }) end })
    ue = c.ue
    ue:fireConsole("locks restore")
    c.ticks(39)
    check(printed(ue, "were not found") == nil and c.S.asked ~= nil, "no hero: the pass looks for him for 10 seconds")
    c.ticks(1)
    check(printed(ue, "[G1R_Locks] the hero's lock picking values were not found (no game loaded?): nothing was put back\n") ~= nil and c.S.asked == nil, "then - at the look ten seconds after the word - it says so and stops")
    local finds = allOf(ue)
    c.ticks(40)
    check(allOf(ue) == finds, "and the module rests")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("10. the choices that go by the lock: \"safe\" and \"half\" (chests)")
do
    local c = start("safe", { config = config('Config.SkilledConnections = "safe"\nConfig.LogLocks = true'), game = { level = "skilled" }, widgets = true, diag = true })
    local ue, w = c.ue, c.world
    check(printed(ue, "loaded: connections taken away game / safe / game (untrained / skilled / master)") ~= nil and (ue.calls.RegisterHook or 0) == 0, "the load line names the choice; nothing is hooked at load")
    c.ticks(2)
    check(ue.calls.RegisterHook == 1 and #ue.hooks[HOOK] == 1 and c.fake.value("locks.lock_hook") == "registered", "the first look hooks the game's function that starts a chest's lock: one registration")
    check(c.precision() == 1 and c.S.writes == 0 and c.S.mark.LockpickPrecision == nil, "between locks the game's own number stands (1 for the skilled): nothing is written")
    check(c.fake.value("locks.lock_table") == "read" and c.fake.count["locks.lock_table"] == 1, "the lock table is read at the look that registers the hook")
    -- a lock that cannot be opened with 3 or 4 connections taken away: proven up to 2
    local filesRead, realDofile = 0, dofile
    rawset(_G, "dofile", function(...)
        filesRead = filesRead + 1
        return realDofile(...)
    end)
    local lock = w.openChest("FM_Chest_Digginggallery_02_Lock")
    rawset(_G, "dofile", realDofile)
    check(filesRead == 0, "so that the hook reads no file inside the game's call that opens the first chest")
    check(lock.precision == 2 and lock.inForce == 8 and lock.solvable() and c.S.hookRuns == 1, "a chest whose lock is proven up to 2 of 10: set up with 2 taken away, and it can be opened")
    check(c.fake.value("locks.lock_hook") == "runs" and c.fake.count["locks.lock_hook"] == 2, "that the game calls the hook is noted (once)")
    c.ticks(1)
    check(printed(ue, "[G1R_Locks] lock started - skilled, FM_Chest_Digginggallery_02_Lock: 2 of 10 connections taken away (the game: 1)\n") ~= nil
        and c.ui.note() == "Lock picking (skilled): 2 of 10 connections taken away", "the next look says so in the log and on screen: " .. tostring(c.ui.note()))
    check(c.fake.value("locks.lock_known") == "announced" and c.fake.value("locks.lock_table") == "read" and c.fake.value("locks.in_place") == "yes", "noted: the lock was announced by the hook, the table was read")
    for _ = 1, 4 do lock.move(4, -1) end          -- four moves that cannot be made: the pick breaks, the game ends the lock
    check(lock.over and lock.broken == 1, "(the pick breaks)")
    c.ticks(1)
    check(c.precision() == 1 and (w.bases()) == 1 and c.S.putBack == 1 and c.S.lock == nil and c.S.mark.LockpickPrecision == nil,
        "the lock is over: the game's own number is put back at the next look - a save made between locks is clean")
    -- a lock that can be opened with any number taken away: all of them
    lock = w.openChest("AM_Chest_04_Lock")
    check(lock.precision == 8 and lock.inForce == 0 and lock.solvable(), "a chest whose lock is proven for all 8: set up without connections")
    c.ticks(1)
    check(printed(ue, "lock started - skilled, AM_Chest_04_Lock: 8 of 8 connections taken away (the game: 1)") ~= nil, "said in the log with the lock's name")
    -- a second pick: the lock is set up again with the same number
    lock.leave()
    c.ticks(1)
    lock = w.openChest("FM_Chest_Digginggallery_02_Lock", nil)
    lock.picks = 2
    c.ticks(3)
    for _ = 1, 4 do lock.move(4, -1) end
    check(lock.setUps == 2 and lock.precision == 2 and lock.solvable() and not lock.over, "a pick breaks during such a lock: set up again with the same number")
    lock.leave()
    c.ticks(1)
    check(c.precision() == 1 and ue.calls.RegisterHook == 1 and c.S.hookRuns == 3, "three chests, one registration of the hook")
    -- a door: no function of the game runs before its lock that the module could hook
    lock = w.openDoor("AMR_Storage_Room_Lock")
    c.ticks(1)
    check(lock.precision == 1 and c.S.hookRuns == 3 and c.fake.value("locks.lock_known") == "not announced"
        and printed(ue, "lock started - skilled: as the game has it (the lock was not known before it started: a door, or the hook did not run)") ~= nil,
        "a door's lock is not known in time: it is set up as the game has it (1), said in the log, noted")
    lock.leave()
    c.ticks(1)
    -- a chest that is not locked (any more): the number is written for nothing and taken back at once
    check(w.openChest("AM_Chest_04_Lock", false) == nil and c.precision() == 8, "(a chest that is not locked: the hook runs and writes, no lock starts)")
    c.ticks(1)
    check(c.precision() == 1 and c.S.lock == nil and c.S.locks == 4, "the next tick, a quarter second later, puts the game's own number back")
    -- a lock the table does not know, a chest without a lock, somebody else's chest
    w.unknownLock = LOCKS.AM_Chest_04_Lock
    lock = w.openChest("XX_New_Chest_Lock")
    c.ticks(1)
    check(lock.precision == 1 and printed(ue, "lock started - skilled, XX_New_Chest_Lock: as the game has it (this lock is not in the module's table)") ~= nil
        and c.fake.value("locks.lock_known") == "not in the table" and c.fake.detail("locks.lock_known") == "XX_New_Chest_Lock",
        "a lock that is not in the table (a later version of the game): left as the game has it, said in the log, noted with its name")
    lock.leave()
    c.ticks(1)
    -- the game does not keep capital and small letters of a name apart
    lock = w.openChest("am_chest_04_LOCK")
    c.ticks(1)
    check(lock.precision == 8 and c.hook.depthFor("safe", 1, "fm_chest_digginggallery_02_lock") == 2 and c.hook.depthFor("safe", 1, "am_chest_04_lock_") == nil
        and printed(ue, "lock started - skilled, am_chest_04_LOCK: 8 of 8 connections taken away (the game: 1)") ~= nil,
        "a lock's name in another spelling of capital and small letters is found in the table")
    lock.leave()
    c.ticks(1)
    local runs = c.S.hookRuns
    w.openChest("None", false)
    w.openChest("", false)
    local npc = ue:object("GA_Human_OpenContainer /Game/Maps/World.World:PersistentLevel.GothicNPCState_9.GA_Human_OpenContainer_2", {})
    w.openChest("AM_Chest_04_Lock", nil, npc)
    check(c.S.hookRuns == runs and c.precision() == 1 and c.S.lock == nil, "a chest without a lock (the name None, or an empty one) and another character's chest: the hook does nothing")
    check(has(status(c), "|chests: the lock is told by the game's function that starts it (called 9 times, 6 of them for a lock of the hero)"), "the status counts the hook's calls: " .. c.hook.status()[4])
    -- the level's choice is changed to a fixed one: the hook stays, and does nothing
    T.menuSet(c, "Lock picking", "Skilled", 4)
    c.ticks(1)
    lock = w.openChest("AM_Chest_04_Lock")
    check(lock.precision == 2 and c.S.hookRuns == runs and ue.calls.RegisterHook == 1, "the choice changed to \"2\": the hook no longer writes; every lock gets the 2")
    lock.leave()
    check(#ue.errors == 0, "no error")
    stop(c)

    -- half of the connections, never fewer than the game takes away itself
    c = start("half", { config = config('Config.UntrainedConnections = "half"\nConfig.SkilledConnections = "half"\nConfig.MasterConnections = "half"'), game = { level = "untrained" } })
    w = c.world
    c.ticks(1)
    lock = w.openChest("AM_Chest_04_Lock")
    check(lock.precision == 4 and lock.inForce == 4 and lock.solvable(), "half, 8 connections: 4 taken away")
    lock.leave()
    c.ticks(1)
    lock = w.openChest("FM_Chest_Digginggallery_02_Lock")
    check(lock.precision == 2 and lock.solvable(), "half of 10 would be 5; the lock is proven up to 2: 2 taken away")
    lock.leave()
    c.ticks(1)
    local small                                  -- a lock of the game with 4 connections
    for _, entry in ipairs(GAMELOCKS) do
        if #entry.c == 12 and entry.used == "chest" then small = entry.name break end
    end
    lock = w.openChest(small)
    check(lock.precision == 2 and c.S.mark.LockpickPrecision == 2, "half of 4 connections for the untrained: 2")
    lock.leave()
    w.level("master")
    c.ticks(1)
    local writes = c.S.writes
    lock = w.openChest(small)
    c.ticks(1)
    check(lock.precision == 2 and c.S.writes == writes and c.S.mark.LockpickPrecision == nil and c.S.lastLock == "master, " .. small .. ": as the game has it",
        "the same lock for a master, whose own number is 2: nothing is written")
    lock.leave()
    stop(c)

    -- never fewer than the game takes away itself (the game's chests have 4 connections and more, so half is at
    -- least the master's 2 there: shown with smaller locks in a table of the test's own)
    c = start("half-floor", { config = config('Config.SkilledConnections = "half"\nConfig.MasterConnections = "half"'), game = { level = "master" },
        files = { ["Scripts/lockdata.lua"] = "return { XX_Three_Lock = { 3, 3 }, XX_One_Lock = { 1, 1 }, XX_Tight_Lock = { 8, 1 } }" } })
    w = c.world
    w.unknownLock = LOCKS.AM_Chest_04_Lock
    c.ticks(1)
    lock = w.openChest("XX_Three_Lock")
    check(lock.precision == 2 and c.S.writes == 0 and c.S.lock.value == 2, "half of 3 connections would be 1; a master gets the game's own 2")
    lock.leave()
    c.ticks(1)
    w.level("skilled")
    c.ticks(1)
    lock = w.openChest("XX_One_Lock")
    check(lock.precision == 1 and c.S.writes == 0 and c.S.lock.value == 1, "half of 1 connection would be 0; a skilled hero gets the game's own 1")
    lock.leave()
    c.ticks(1)
    w.level("master")
    c.ticks(1)
    lock = w.openChest("XX_Tight_Lock")
    check(lock.precision == 1 and c.S.writes == 1 and c.S.lock.value == 1, "but what is proven comes first: a lock proven only up to 1 gets 1, also for a master")
    lock.leave()
    stop(c)

    -- the number for a lock goes back as soon as the lock is over, also at a slow pace of the looks
    c = start("safe-slow", { config = T.config('Config.SkilledConnections = "safe"\nConfig.LookSeconds = 10'), game = { level = "skilled" } })
    w = c.world
    c.ticks(1)
    lock = w.openChest("AM_Chest_04_Lock")
    c.ticks(3)
    check(c.S.picking == true and c.S.locks == 1 and c.precision() == 8, "LookSeconds = 10: a lock the hook announced is noticed at the next tick all the same")
    lock.leave()
    c.ticks(1)
    check(c.precision() == 1 and c.S.lock == nil and c.S.putBack == 1, "and when it is over the game's own number is back a quarter second later - no door's lock can meet the number of this chest")
    local looked = w.called("HasGameplayTag")
    c.ticks(1)
    c.ticks(38)
    check(w.called("HasGameplayTag") == looked + 3, "after that the slow pace again (one more look in ten seconds)")
    stop(c)

    -- the hook is asked for when the hero's level needs it, not before
    c = start("hook-later", { config = config('Config.MasterConnections = "safe"'), game = { level = "untrained" } })
    w = c.world
    c.ticks(8)
    check((c.ue.calls.RegisterHook or 0) == 0 and c.S.hooked == nil, "\"safe\" for the master, the hero untrained: nothing is hooked")
    w.level("master")
    c.ticks(1)
    check(c.ue.calls.RegisterHook == 1 and c.S.hooked == true, "he becomes a master: the hook is registered")
    lock = w.openChest("AM_Chest_04_Lock")
    check(lock.precision == 8, "and works")
    stop(c)

    -- the game has no such function: asked once, never again - the retried registration of another mod is what crashed the game
    c = start("no-hook", { config = config('Config.SkilledConnections = "safe"\nConfig.MasterConnections = "half"'), game = { level = "skilled", noHook = true }, diag = true })
    ue, w = c.ue, c.world
    c.ticks(8)
    for _ = 1, 12 do
        lock = w.openChest("AM_Chest_04_Lock")
        c.ticks(2)
        lock.leave()
        c.ticks(2)
    end
    w.level("master")
    c.ticks(8)
    T.write(c.path, config('Config.SkilledConnections = "half"\nConfig.MasterConnections = "safe"'))
    ue:fireConsole("locks reload")
    c.ticks(8)
    check(ue.calls.RegisterHook == 1 and ue.hooks[HOOK] == nil, "a game without that function: RegisterHook is called once in 12 locks, a new level and new settings")
    check(printedCount(ue, "the game's function that starts the lock of a chest could not be hooked") == 1 and c.fake.value("locks.lock_hook") == "not available"
        and c.fake.count["locks.lock_hook"] == 1, "said once in the log, noted once")
    check(lock.precision == 1 and c.precision() == 2 and c.S.writes == 0 and #ue.errors == 0, "every lock stays as the game has it, no error")
    check(has(status(c), "|chests: the game's function that starts a lock could not be hooked - \"half\" and \"safe\" leave every lock as the game has it"), "the status says so")
    stop(c)

    -- the table cannot be read
    c = start("no-table", { config = config('Config.SkilledConnections = "safe"'), game = { level = "skilled" }, files = { ["Scripts/lockdata.lua"] = "return {" }, diag = true })
    w = c.world
    c.ticks(1)
    lock = w.openChest("AM_Chest_04_Lock")
    c.ticks(1)
    lock.leave()
    lock = w.openChest("AM_Chest_04_Lock")
    check(lock.precision == 1 and printedCount(c.ue, "lockdata.lua could not be read (") == 1 and c.fake.value("locks.lock_table") == "not readable" and #c.ue.errors == 0,
        "a broken lockdata.lua: said once, every lock as the game has it")
    stop(c)
    c = start("no-table-5", { config = config('Config.SkilledConnections = "safe"'), game = { level = "skilled" }, files = { ["Scripts/lockdata.lua"] = "return 5" }, diag = true })
    c.ticks(1)
    lock = c.world.openChest("AM_Chest_04_Lock")
    check(lock.precision == 1 and printedCount(c.ue, "[G1R_Locks] lockdata.lua could not be read (5); the choices \"half\" and \"safe\" leave every lock as the game has it\n") == 1
        and c.fake.value("locks.lock_table") == "not readable" and #c.ue.errors == 0, "a lockdata.lua that gives no table: the same")
    stop(c)
    c = start("odd-table", { config = config('Config.SkilledConnections = "safe"'), game = { level = "skilled" },
        files = { ["Scripts/lockdata.lua"] = 'return { AM_Chest_04_Lock = "8", FM_Chest_Digginggallery_02_Lock = { 10 }, A = 8, B = { "8", 8 }, C = { 8, "8" }, D = { 8, 3 } }' } })
    c.ticks(1)
    check(c.world.openChest("AM_Chest_04_Lock").precision == 1 and c.hook.depthFor("safe", 1, "FM_Chest_Digginggallery_02_Lock") == nil and c.hook.depthFor("safe", 1, "A") == nil
        and c.hook.depthFor("safe", 1, "B") == nil and c.hook.depthFor("safe", 1, "C") == nil and c.hook.depthFor("safe", 1, "D") == 3 and #c.ue.errors == 0,
        "entries of another form than { connections, proven } - a text, a number, one number, a text for a number - count as not in the table")
    stop(c)

    -- without the hero's tags the end of a lock cannot be told: the choices do nothing
    c = start("safe-no-tags", { config = config('Config.SkilledConnections = "safe"'), game = { level = "skilled", tagError = true } })
    c.ticks(12)
    lock = c.world.openChest("AM_Chest_04_Lock")
    check((c.ue.calls.RegisterHook or 0) == 0 and lock.precision == 1 and c.S.tierBy == "values"
        and printedCount(c.ue, "without the hero's tags it cannot be told when a lock is over") == 1, "tags that cannot be asked: no hook, said once, locks as the game has them")
    stop(c)

    -- Tags that answer, but with "no" to everything (not seen in the game; a tag handed over in a form the game
    -- does not take would look like this): they show none of the hero's three levels, and would say "no lock" in
    -- the middle of a lock - the game's number would be put back under it, and a broken pick would set the lock up
    -- again with other connections. So they are not relied on for the choices that go by the lock.
    local LEVEL_SAID = "[G1R_Locks] the hero's tags do not show his level, so they are not relied on to tell when a lock is over: "
        .. "the choices \"half\" and \"safe\" leave every lock as the game has it\n"
    c = start("safe-tags-no", { config = config('Config.SkilledConnections = "safe"'), game = { level = "skilled" } })
    ue, w = c.ue, c.world
    w.tagAnswer = function() return false end
    c.ticks(2)
    check((ue.calls.RegisterHook or 0) == 0 and c.S.tierBy == "values" and c.S.tier.key == "skilled" and c.S.picking == false and printed(ue, "do not show his level") == nil,
        "tags that answer no to everything: the level is told by the numbers and nothing is hooked; two looks say nothing yet (a save may still be filling in)")
    c.ticks(1)
    check(printedCount(ue, LEVEL_SAID) == 1 and (ue.calls.RegisterHook or 0) == 0, "the third look says that \"safe\" does nothing")
    lock = w.openChest("FM_Chest_Digginggallery_02_Lock")
    lock.picks = 2
    local setUpWith = lock.precision
    c.ticks(4)
    check(setUpWith == 1 and c.precision() == 1 and c.S.writes == 0 and c.S.putBack == 0, "a chest's lock is as the game has it, and nothing is written while it is being picked")
    for _ = 1, 4 do lock.move(4, -1) end
    check(lock.setUps == 2 and lock.precision == setUpWith and not lock.over, "a pick breaks: the lock is set up again with the number it was first set up with")
    lock.leave()
    c.ticks(8)
    check(printedCount(ue, LEVEL_SAID) == 1, "(said once)")
    stop(c)
    c = start("safe-tag-lost", { config = config('Config.SkilledConnections = "safe"'), game = { level = "skilled" } })
    ue, w = c.ue, c.world
    c.ticks(2)
    check(ue.calls.RegisterHook == 1 and c.S.tierBy == "tags", "(the hook is registered while the hero's skill tag tells his level)")
    w.hero.tags[LEVELS.skilled.tag] = nil
    c.ticks(1)
    lock = w.openChest("AM_Chest_04_Lock")
    check(c.S.tierBy == "values" and c.S.picking == false and lock.precision == 1 and c.S.hookRuns == 0 and c.precision() == 1 and printed(ue, "do not show his level") == nil,
        "his skill tag goes away (the level is told by the numbers): the hook does nothing, the chest's lock is as the game has it")
    lock.leave()
    w.hero.tags[LEVELS.skilled.tag] = 1
    c.ticks(1)
    lock = w.openChest("AM_Chest_04_Lock")
    check(lock.precision == 8 and c.S.hookRuns == 1, "the tag is back: the next chest's lock gets its number again")
    lock.leave()
    stop(c)

    -- the hook while it must not act
    c = start("hook-guards", { config = config('Config.SkilledConnections = "safe"'), game = { level = "skilled" } })
    ue, w = c.ue, c.world
    c.ticks(1)
    lock = w.openDoor("AMR_Storage_Room_Lock")
    c.ticks(1)
    w.openChest("AM_Chest_04_Lock", false)
    check(c.precision() == 1 and c.S.hookRuns == 0, "the hook runs while a lock is being picked: it does nothing")
    lock.leave()
    c.ticks(1)
    T.menuSet(c, "Lock picking", "Lock picking by skill", false)
    c.ticks(1)
    w.openChest("AM_Chest_04_Lock", false)
    check(c.precision() == 1 and c.S.hookRuns == 0, "the module switched off: the hook does nothing")
    T.menuSet(c, "Lock picking", "Lock picking by skill", true)
    c.ticks(1)
    w.hero.open.m_Lock = nil
    ue:fireHook(HOOK, { get = function() return w.hero.open end })
    ue:fireHook(HOOK, nil)
    ue:fireHook(HOOK, { get = function() error("gone (test)") end })
    check(c.precision() == 1 and c.S.hookRuns == 0 and #ue.errors == 0, "an ability without a lock name, no ability at all, one that cannot be read: nothing happens, no error")
    -- the hero's attributes were replaced since the last look
    local other = ue:object("AttributeSet_Lockpicking /Game/Maps/World.World:PersistentLevel.GothicPlayerState_21.AttributeSet_Lockpicking_99", {
        LockpickDurability = { BaseValue = 4.0, CurrentValue = 4.0 }, LockpickPrecision = { BaseValue = 1.0, CurrentValue = 1.0 } })
    w.hero.locks.__valid = false
    w.hero.component.SpawnedAttributes.items[4] = other
    w.openChest("AM_Chest_04_Lock", false)
    check(other.LockpickPrecision.CurrentValue == 1 and c.S.hookRuns == 0, "attributes the last look did not know: the hook leaves them to the next look")
    c.ticks(1)
    -- an error inside the hook does not reach the game
    local real = c.kit.attributeSet
    c.kit.attributeSet = function() error("the kit failed (test)") end
    w.hero.open.m_Lock = fname("AM_Chest_04_Lock")
    for _ = 1, 3 do ue:fireHook(HOOK, { get = function() return w.hero.open end }) end
    c.kit.attributeSet = real
    check(#ue.errors == 0 and printedCount(ue, "[G1R_Locks] error in the chest hook: the kit failed (test)\n") == 1 and c.S.hookCalls == 9 and c.S.hookRuns == 0,
        "an error inside the hook is caught and said once; the game's call goes on undisturbed")
    stop(c, true)
end

-- ---------------------------------------------------------------------------
section("11. the proof: every number the module can write leaves the lock solvable")
do
    -- Plays a way to open a lock by the game's rules (the same as world.startLock, written out again here so that
    -- the proof does not lean on the model above): the first `removed` connections left out, then the moves.
    local function opens(def, removed, way)
        if type(way) ~= "string" then return false end
        local at, links = {}, {}
        for i, p in ipairs(def.pieces) do at[i] = p end
        for i = removed + 1, #def.connections do
            local c = def.connections[i]
            links[c[1]] = links[c[1]] or {}
            links[c[1]][#links[c[1]] + 1] = c
        end
        for piece, sign in way:gmatch("(%d)([+-])") do
            local id, step = tonumber(piece), sign == "+" and 1 or -1
            if at[id + 1] == nil then return false end
            at[id + 1] = at[id + 1] + step
            for _, c in ipairs(links[id] or {}) do at[c[2] + 1] = at[c[2] + 1] + step * c[3] end
            for _, p in ipairs(at) do
                if p < -3 or p > 3 then return false end           -- a move the game would not make
            end
        end
        if #way ~= 2 * select(2, way:gsub("%d[+-]", "")) then return false end        -- nothing but moves in the text
        for _, p in ipairs(at) do
            if p ~= 0 then return false end
        end
        return true
    end
    -- Can a lock be opened at all with that many connections left out? Every position is tried.
    local function solvable(def, removed)
        local links = {}
        for i = removed + 1, #def.connections do
            local c = def.connections[i]
            links[c[1]] = links[c[1]] or {}
            links[c[1]][#links[c[1]] + 1] = c
        end
        local n = #def.pieces
        local function index(t)
            local x = 0
            for i = n, 1, -1 do x = x * 7 + t[i] + 3 end
            return x
        end
        local start = {}
        for i, p in ipairs(def.pieces) do start[i] = p end
        local seen, queue, head = { [index(start)] = true }, { start }, 1
        while queue[head] do
            local at = queue[head]
            head = head + 1
            local open = true
            for i = 1, n do if at[i] ~= 0 then open = false break end end
            if open then return true end
            for id = 0, n - 1 do
                for step = -1, 1, 2 do
                    local t, ok = {}, true
                    for i = 1, n do t[i] = at[i] end
                    t[id + 1] = t[id + 1] + step
                    for _, c in ipairs(links[id] or {}) do t[c[2] + 1] = t[c[2] + 1] + step * c[3] end
                    for i = 1, n do if t[i] < -3 or t[i] > 3 then ok = false break end end
                    if ok then
                        local x = index(t)
                        if not seen[x] then
                            seen[x] = true
                            queue[#queue + 1] = t
                        end
                    end
                end
            end
        end
        return false
    end
    check(opens(LOCKS.AM_Chest_04_Lock, 8, "0-2-2-2-3+4-5-") and not opens(LOCKS.AM_Chest_04_Lock, 8, "0-2-2-2-3+4-") and not opens(LOCKS.AM_Chest_04_Lock, 7, "0-2-2-2-3+4-5-")
        and not opens(LOCKS.AM_Chest_04_Lock, 8, "2+0-2-2-2-2-3+4-5-") and not opens(LOCKS.AM_Chest_04_Lock, 8, "0-2-2-2-3+4-5-x") and not opens(LOCKS.AM_Chest_04_Lock, 8, false),
        "(the replay itself: a right way opens; a move short, one connection more, a move out of range, other text, no way do not)")
    check(solvable(LOCKS.FM_Chest_Digginggallery_02_Lock, 2) and not solvable(LOCKS.FM_Chest_Digginggallery_02_Lock, 3) and not solvable(LOCKS.FM_Chest_Digginggallery_02_Lock, 4)
        and solvable(LOCKS.FM_Chest_Digginggallery_02_Lock, 5), "(the search itself: the lock of section 3 at 2, 3, 4, 5 connections taken away)")

    local c = start("proof", { config = config('Config.SkilledConnections = "safe"') })
    local depthFor = c.hook.depthFor
    local table_ = dofile(MOD .. "modules/locks/Scripts/lockdata.lua")
    local names = 0
    for _ in pairs(table_) do names = names + 1 end
    local same = names == #GAMELOCKS
    for _, entry in ipairs(GAMELOCKS) do
        local row = table_[entry.name]
        if type(row) ~= "table" or row[1] ~= #entry.c / 3 or row[2] < 0 or row[2] > row[1] or #row ~= 2 then same = false end
    end
    -- (346 lock definitions; one of them sets its name twice and is in the table under both names)
    local twice = table_.OC_Mages_Room_01_Lock and table_.Test_Lock_85_07
    check(same and names == 347 and twice and table.concat(table_.OC_Mages_Room_01_Lock, ",") == table.concat(table_.Test_Lock_85_07, ","),
        "lockdata.lua has the game's 346 locks under their 347 names, each with the number of connections the game's definition has: " .. names)
    for name, def in pairs(LOCKS) do
        local game_ = BYNAME[name]
        local equal = game_ ~= nil and table.concat(game_.pieces, ",") == table.concat(def.pieces, ",") and #game_.connections == #def.connections
        for i, cn in ipairs(def.connections) do
            if not equal or table.concat(cn, ",") ~= table.concat(game_.connections[i], ",") then equal = false end
        end
        if not equal then check(false, "the lock " .. name .. " of the model above is the game's") end
    end

    -- the choices that go by the lock: every number they can produce, for every lock and every level
    local cases, bad, deepest, all = 0, {}, 0, 0
    for _, entry in ipairs(GAMELOCKS) do
        local def = BYNAME[entry.name]
        for _, mode in ipairs({ "half", "safe" }) do
            for own = 0, 2 do
                local removed, count = depthFor(mode, own, entry.name)
                cases = cases + 1
                if removed == nil or count ~= #def.connections or not opens(def, removed, def.ways[removed]) then
                    bad[#bad + 1] = ("%s %s at %d -> %s"):format(entry.name, mode, own, tostring(removed))
                end
                if removed ~= nil and removed < count and removed > deepest then deepest = removed end
                if removed == count and mode == "safe" and own == 0 then all = all + 1 end
            end
        end
    end
    check(#bad == 0 and cases == 2082, ("\"half\" and \"safe\" at each of the three levels, for each of the 347 names: %d numbers, each with a way that opens the lock when replayed (%s)"):format(cases, table.concat(bad, "; ")))
    check(all == 268 and deepest == 6, ("\"safe\" takes all connections away from %d of the names (267 of the 346 locks); from the others at most %d"):format(all, deepest))

    -- the fixed choices: for every lock a chest or a door of the game has
    local used, fixedBad = 0, {}
    for _, entry in ipairs(GAMELOCKS) do
        if entry.used then
            used = used + 1
            local def = BYNAME[entry.name]
            for _, removed in ipairs({ 0, 1, 2, #def.connections }) do
                if not opens(def, math.min(removed, #def.connections), def.ways[math.min(removed, #def.connections)]) then fixedBad[#fixedBad + 1] = entry.name .. " at " .. removed end
            end
        end
    end
    check(used == 332 and #fixedBad == 0, ("\"none\", \"1\", \"2\" and \"all\": a way that opens each of the %d locks a chest or a door has (%s)"):format(used, table.concat(fixedBad, "; ")))
    local forge = BYNAME.TST_Chest_Forge_01_Lock
    check(forge.used == false and forge.ways[2] == false and not solvable(forge, 2) and not solvable(forge, 3) and solvable(forge, 1) and table_.TST_Chest_Forge_01_Lock[2] == 1
        and depthFor("safe", 2, "TST_Chest_Forge_01_Lock") == 1 and depthFor("half", 2, "TST_Chest_Forge_01_Lock") == 1,
        "one lock that no chest names (it is in the game's switched-off random pool) cannot be opened with 2 or 3 taken away: proven up to 1, and \"safe\" / \"half\" write 1 for it even for a master")

    -- "as many as proven": one more would be too many. Every position is searched for a sample of the locks that
    -- are not proven for all their connections (every 4th of those with at most 5 pieces; with LOCKS_FULL=1 in
    -- the environment all of them, of any size, which takes minutes). All of them were searched by
    -- tools/solver.c when the table was made.
    local full = os.getenv("LOCKS_FULL") == "1"
    local candidates, searched, wrong = 0, 0, {}
    for _, entry in ipairs(GAMELOCKS) do
        local def = BYNAME[entry.name]
        local row = table_[entry.name]
        if row[2] < row[1] and (full or #def.pieces <= 5) then
            candidates = candidates + 1
            if full or candidates % 4 == 1 then
                searched = searched + 1
                if solvable(def, row[2] + 1) then wrong[#wrong + 1] = entry.name end
            end
        end
    end
    check(searched >= 8 and #wrong == 0, ("\"proven\" is not too small: for %d locks that are not proven for all their connections, with one more taken away no way exists (every position searched) (%s)"):format(searched, table.concat(wrong, "; ")))
    stop(c)
end

-- ---------------------------------------------------------------------------
section("12. things that are missing or fail")
do
    -- the hero's tags cannot be asked: the level is told by the numbers the game set
    local TAGS_SAID = "[G1R_Locks] the hero's gameplay tags cannot be asked (%s); the skill level is told by the numbers the game set, "
        .. "and a lock being picked is not noticed (no note, and a changed setting does not wait for its end)\n"
    local c = start("tags-raise", { config = config(PLAYER), game = { level = "master", tagError = true }, diag = true, widgets = true })
    local ue, w = c.ue, c.world
    c.ticks(1)
    check(c.precision() == 99 and c.S.tier.key == "master" and c.S.tierBy == "values" and c.S.tagsOff == false and c.fake.value("locks.level_by") == "values" and c.fake.value("locks.tags") == nil,
        "HasGameplayTag raises: at the first look the level is told by the pick's number the game set (6 = master), and the chosen number is written")
    c.ticks(2)
    check(c.S.tagsOff == true and printedCount(ue, TAGS_SAID:format("HasGameplayTag failed (test)")) == 1 and c.fake.value("locks.tags") == "not readable"
        and c.fake.detail("locks.tags") == "HasGameplayTag failed (test)" and w.called("HasGameplayTag") == 3, "after three looks the tags are given up: said once with the reason, noted")
    c.ticks(40)
    check(w.called("HasGameplayTag") == 3 and c.fake.count["locks.tags"] == 1 and #ue.errors == 0, "and not asked again: three calls in all")
    check(status(c):find("|the hero is master (told by the numbers the game set); connections taken away 99 (this module's; the game's own: 2); wrong moves per pick 6 (the game's own)|", 1, true) ~= nil,
        "the status says how the level is told: " .. c.hook.status()[2])
    w.level("skilled")
    c.ticks(1)
    check(c.precision() == 2 and c.S.tier.key == "skilled" and c.S.rewritten == 1 and c.fake.detail("locks.rewritten") == "LockpickPrecision 99 -> 1",
        "the hero becomes skilled: the game's numbers (1 and 4) tell it, the chosen 2 is written")
    local lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(8)
    check(lock.precision == 2 and c.S.locks == 0 and c.S.picking == nil and c.ui.note() == nil and printed(ue, "lock started") == nil,
        "a lock is set up with the chosen number, but its start is not noticed: no note, no log line")
    lock.leave()
    -- new attributes: the tags are asked again
    w.tagError = false
    stop(c)
    c = start("tags-later", { config = config(PLAYER), game = { level = "master" }, diag = true })
    ue, w = c.ue, c.world
    c.ticks(2)
    w.tagError = true
    c.ticks(2)
    check(c.S.tagsOff == false and c.S.tierBy == "values" and c.S.tier.key == "master" and c.precision() == 99 and c.S.writes == 1, "tags that stop working in the middle of a session: the level stays told (by the numbers)")
    c.ticks(1)
    check(c.S.tagsOff == true and c.fake.value("locks.tags") == "not readable" and c.fake.value("locks.level_by") == "values", "given up after the third look")
    w.tagError = false
    c.ticks(8)
    check(c.S.tagsOff == true and c.S.tierBy == "values", "(they are not asked again for these attributes)")
    w.load(w.save())
    c.ticks(1)
    check(c.S.tagsOff == false and c.S.tierBy == "tags" and c.fake.value("locks.tags") == "readable" and c.fake.value("locks.level_by") == "tags" and c.precision() == 99,
        "a loaded save brings new attributes: the tags are asked again, and answer")
    stop(c)

    -- an answer that is no true / false, a game without the function, a UE4SS without FName, a hero without ability system
    c = start("tags-odd", { config = config(PLAYER), game = { level = "skilled" }, diag = true, prepare = function(ue2)
        local world = game(ue2, { level = "skilled" })
        world.tagAnswer = function() return 1 end
        return world
    end })
    c.ticks(3)
    check(c.precision() == 2 and printedCount(c.ue, TAGS_SAID:format("the answer was 1")) == 1 and c.fake.detail("locks.tags") == "the answer was 1", "HasGameplayTag answers with a number: not taken for yes; told by the numbers")
    stop(c)
    c = start("tags-nil", { config = config(PLAYER), prepare = function(ue2)
        local world = game(ue2, { level = "skilled" })
        world.tagAnswer = function() return nil end
        return world
    end })
    c.ticks(3)
    check(c.precision() == 2 and printedCount(c.ue, TAGS_SAID:format("the answer was nil")) == 1, "it answers with nothing: the same")
    stop(c)
    c = start("tags-none", { config = config(PLAYER), game = { level = "master", noTags = true }, diag = true })
    c.ticks(3)
    check(c.precision() == 99 and printedCount(c.ue, TAGS_SAID:format("attempt to call a nil value (field '?')")) == 1 and #c.ue.errors == 0, "an ability system without HasGameplayTag: the same, no error")
    stop(c)
    c = start("no-fname", { config = config(PLAYER), game = { level = "master" }, mock = { without = { "FName" } }, diag = true })
    c.ticks(3)
    check(c.precision() == 99 and printedCount(c.ue, TAGS_SAID:format("this UE4SS build has no FName")) == 1 and c.world.called("HasGameplayTag") == 0 and #c.ue.errors == 0,
        "a UE4SS without FName: no tag can be made, HasGameplayTag is not called at all; told by the numbers")
    stop(c)
    c = start("no-system", { config = config(PLAYER), diag = true, prepare = function(ue2)
        local world = game(ue2, { level = "master" })
        rawset(world.hero.state, "__component", nil)
        ue2.allOf["AttributeSet_Lockpicking"] = { world.hero.locks }
        return world
    end })
    c.seconds(8)
    check(c.S.via == "scan" and c.fake.value("locks.set_found_by") == "scan" and c.precision() == 99 and c.S.tierBy == "values"
        and printedCount(c.ue, TAGS_SAID:format("the hero has no ability system")) == 1 and c.world.called("HasGameplayTag") == 0 and #c.ue.errors == 0,
        "a hero whose ability system cannot be reached: his attributes are found by the kit's search, the level by the numbers; no tag function is called on nothing")
    stop(c)

    -- the tags work, but the hero has none of the three skill tags
    c = start("no-tier-tag", { config = config(PLAYER), game = { level = "master" }, diag = true })
    ue, w = c.ue, c.world
    w.hero.tags[LEVELS.master.tag] = nil
    c.ticks(2)
    check(c.precision() == 99 and c.S.tierBy == "values" and c.fake.value("locks.tags") == "readable" and c.fake.value("locks.level_by") == "values" and printed(ue, "none of the three") == nil,
        "a hero without any of the three skill tags: the level is told by the numbers; nothing is said yet (a save may still be filling in)")
    c.ticks(1)
    check(printedCount(ue, "[G1R_Locks] the hero has none of the three lock picking skill tags; his level is told by the numbers the game set\n") == 1, "it lasts for three looks: said once")
    lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(1)
    T.write(c.path, config('Config.MasterConnections = "none"'))
    ue:fireConsole("locks reload")
    c.ticks(4)
    check(c.S.picking == true and c.S.locks == 1 and c.precision() == 99, "the tag of a lock being picked is still asked: the lock is noticed, and new settings wait for its end")
    lock.leave()
    c.ticks(1)
    check(c.precision() == 0, "(then they are written)")
    w.hero.tags[LEVELS.master.tag] = 1
    c.ticks(1)
    check(c.S.tierBy == "tags" and c.fake.value("locks.level_by") == "tags", "the tag is there again: told by the tag")
    w.hero.tags[LEVELS.master.tag] = nil
    c.ticks(9)
    check(printedCount(ue, "none of the three") == 1, "(said once per run)")
    stop(c)
    c = start("no-tier-tag-later", { config = config(PLAYER), game = { level = "master" } })
    c.ticks(2)
    c.world.hero.tags[LEVELS.master.tag] = nil
    c.ticks(2)
    check(printed(c.ue, "none of the three") == nil, "a skill tag that goes away in the middle of a session: two looks without it say nothing ...")
    c.ticks(1)
    check(printedCount(c.ue, "none of the three") == 1, "... the third does (the count starts anew after every look that found a tag)")
    stop(c)

    -- told by the numbers, at each of the three levels
    for level, expect in pairs({ untrained = 1, skilled = 0, master = 99 }) do
        c = start("values-" .. level, { config = config('Config.UntrainedConnections = "1"\nConfig.SkilledConnections = "none"\nConfig.MasterConnections = "all"'), game = { level = level, tagError = true } })
        c.ticks(1)
        check(c.S.tier and c.S.tier.key == level and c.S.tierBy == "values" and c.precision() == expect,
            ("without tags a hero whose pick takes %d wrong moves is %s: the number chosen for that level is written"):format(LEVELS[level].durability, level))
        stop(c)
    end

    -- told by the numbers while a number is this module's own
    c = start("values", { config = config('Config.SkilledWrongMoves = 10\nConfig.MasterConnections = "all"'), game = { level = "skilled", tagError = true }, diag = true })
    ue, w = c.ue, c.world
    c.ticks(1)
    check(c.durability() == 10 and c.S.tier.key == "skilled" and w.asked.LockpickPrecision == nil, "skilled by the pick's number (4); the module writes its own 10 over it")
    c.ticks(4)
    check(c.S.tier.key == "skilled" and c.S.writes == 1 and w.asked.LockpickPrecision == 4, "from then on the pick's number is the module's and tells nothing: the connections (1, the game's own) tell the level")
    w.level("master")
    c.ticks(1)
    check(c.S.tier.key == "master" and c.precision() == 99 and c.durability() == 6 and c.S.rewritten == 1, "the hero becomes a master: the game's 6 over the module's 10 is noticed and tells the new level")
    T.write(c.path, config('Config.SkilledWrongMoves = 10\nConfig.MasterConnections = "all"\nConfig.MasterWrongMoves = 12'))
    ue:fireConsole("locks reload")
    c.ticks(5)
    check(c.S.tier.key == "master" and c.durability() == 12 and c.precision() == 99, "both numbers are the module's: the level they were written for stays")
    w.level("skilled")
    c.ticks(1)
    check(c.S.tier.key == "skilled" and c.durability() == 10 and c.precision() == 1 and c.S.rewritten == 3, "until the game writes again (skilled: 1 and 4)")
    stop(c)

    -- neither the tags nor the numbers tell the level
    c = start("unknown", { config = config(PLAYER), game = { level = "master", tagError = true }, diag = true })
    ue, w = c.ue, c.world
    w.write("LockpickDurability", 5)
    c.ticks(2)
    check(c.precision() == 2 and c.S.tier == nil and c.fake.value("locks.level_by") == "unknown" and printed(ue, "cannot be told") == nil, "a pick's number that is none of 2 / 4 / 6, no tags: the level is not known, nothing is changed")
    c.ticks(1)
    check(printedCount(ue, "[G1R_Locks] the hero's lock picking level cannot be told (neither by his tags nor by the numbers the game set); nothing is changed\n") == 1, "it lasts for three looks: said once")
    c.ticks(20)
    check(c.precision() == 2 and c.durability() == 5 and c.S.writes == 0 and printedCount(ue, "cannot be told") == 1 and #ue.errors == 0
        and has(status(c), "|the hero's lock picking level cannot be told (neither by his tags nor by the numbers the game set): nothing is changed|"), "it stays so; the status says it")
    lock = w.openChest("AM_Chest_04_Lock")
    check(lock.precision == 2, "(a lock is as the game has it)")
    lock.leave()
    w.write("LockpickDurability", 6)
    c.ticks(1)
    check(c.precision() == 99 and c.S.tier.key == "master" and c.fake.value("locks.level_by") == "values", "the number is the game's again: the level is told, the chosen number written")
    stop(c)
    c = start("unknown-later", { config = config(PLAYER), game = { level = "master", tagError = true } })
    c.ticks(2)
    c.world.write("LockpickDurability", 5)
    c.ticks(2)
    check(c.S.tier == nil and printed(c.ue, "cannot be told") == nil, "a level that can no longer be told in the middle of a session: two looks say nothing ...")
    c.ticks(1)
    check(printedCount(c.ue, "cannot be told") == 1, "... the third does (the count starts anew after every look that told the level)")
    stop(c)

    -- numbers left in a save, the module off, no tags: the level must be named
    c = start("restore-named", { config = config(""), game = { level = "master", tagError = true }, widgets = true })
    ue, w = c.ue, c.world
    w.write("LockpickPrecision", 99)
    w.write("LockpickDurability", 100000)
    ue:fireConsole("locks restore")
    c.ticks(39)
    check(c.S.asked ~= nil and w.precision() == 99, "locks restore for a hero whose level cannot be told: it looks for ten seconds")
    c.ticks(1)
    check(c.S.asked == nil and w.precision() == 99 and printed(ue, "[G1R_Locks] the hero's lock picking level cannot be told: nothing was put back (the console word locks restore untrained / skilled / master names it)\n") ~= nil,
        "then says that the level must be named, and changes nothing")
    local before = #ue.printed
    ue:fireConsole("locks restore king")
    check(ue.printed[before + 1] == '[G1R_Locks] unknown level "king": locks restore, or locks restore untrained / skilled / master\n' and c.S.asked == nil, "a word that is no level: said, nothing asked for")
    ue:fireConsole("locks restore MASTER")
    c.ticks(2)
    local pb, db = w.bases()
    check(w.precision() == 2 and w.durability() == 6 and pb == 2 and db == 6 and c.S.asked == nil and c.S.askedTier == nil
        and printed(ue, "[G1R_Locks] the game's own values for the level master (as named) were put back: LockpickPrecision back to 2, LockpickDurability back to 6\n") ~= nil,
        "locks restore master: the master's own numbers are written, said so")
    local asked = sum(w.asked)
    c.ticks(40)
    check(sum(w.asked) == asked and c.S.awake == false, "and the module rests")
    stop(c)
    c = start("restore-named-known", { game = { level = "skilled" } })
    ue, w = c.ue, c.world
    w.write("LockpickPrecision", 99)
    ue:fireConsole("locks restore master")
    c.ticks(2)
    check(w.precision() == 1 and w.durability() == 4 and printed(ue, "[G1R_Locks] the game's own values for the level skilled were put back: LockpickPrecision back to 1\n") ~= nil,
        "a level named for a hero whose level the game tells: the game's answer counts (skilled), not the word")
    stop(c)

    -- an attribute that cannot be read
    c = start("unreadable", { config = config(PLAYER .. "\nConfig.MasterWrongMoves = 9"), game = { level = "master" }, diag = true })
    ue, w = c.ue, c.world
    local kept = w.hero.store.LockpickPrecision
    w.hero.store.LockpickPrecision = nil
    c.ticks(12)
    check(c.durability() == 9 and kept.CurrentValue == 2 and printedCount(ue, "[G1R_Locks] the hero's LockpickPrecision could not be read from " .. w.hero.locks:GetFullName() .. "\n") == 1
        and c.fake.value("locks.readable_precision") == "no" and c.fake.count["locks.readable_precision"] == 1 and c.fake.value("locks.readable_durability") == "yes"
        and c.fake.count["locks.readable_durability"] == 1 and #ue.errors == 0,
        "the connections' number cannot be read: said once, noted once, nothing written to it; the pick's number is set as chosen")
    check(has(status(c), "connections taken away cannot be read; wrong moves per pick 9 (this module's; the game's own: 6)"), "the status says so: " .. c.hook.status()[2])
    w.hero.store.LockpickPrecision = kept
    c.ticks(1)
    check(c.precision() == 99 and c.fake.value("locks.readable_precision") == "yes", "readable again: written at the next look, noted")
    kept.CurrentValue = 0 / 0
    T.write(c.path, config('Config.MasterConnections = "none"'))
    ue:fireConsole("locks reload")
    c.ticks(2)
    check(kept.BaseValue == 99 and c.fake.value("locks.readable_precision") == "no" and #ue.errors == 0, "a value that is not a number is not read as one: nothing is written over it")
    stop(c)

    -- writes that do not work
    for _, mode in ipairs({ "raises", "ignored", "base only" }) do
        c = start("write-" .. mode:gsub(" ", "-"), { config = config(PLAYER .. "\nConfig.MasterWrongMoves = 9"), game = { level = "master" }, diag = true, widgets = true })
        ue, w = c.ue, c.world
        local data = w.spoil("LockpickPrecision", mode)
        local why = mode == "raises" and "the write raised an error" or "the value did not stay"
        c.ticks(1)
        check(data.CurrentValue == 2 and data.BaseValue == 2 and c.durability() == 9 and c.S.mark.LockpickPrecision == nil and c.S.failed.LockpickPrecision == 1
            and printedCount(ue, "[G1R_Locks] LockpickPrecision could not be written (" .. why .. "); it is left as it was (2)\n") == 1
            and c.fake.value("locks.write_precision") == "failed" and c.fake.detail("locks.write_precision") == why and c.fake.value("locks.write_durability") == "ok",
            "a write that " .. (mode == "raises" and "raises" or (mode == "ignored" and "does not arrive" or "arrives by half")) .. ": the old numbers are back in place (2 and 2), said, noted; the other attribute is written")
        c.ticks(1)
        check(c.S.failed.LockpickPrecision == 2 and c.S.givenUp.LockpickPrecision == nil, "tried again at the next look")
        c.ticks(1)
        local tried = w.writesTried
        check(c.S.givenUp.LockpickPrecision == true and printedCount(ue, "[G1R_Locks] LockpickPrecision is left alone until the settings change: 3 writes in a row did not work\n") == 1,
            "after three looks it is left alone: said")
        local reads = w.asked.LockpickPrecision
        c.ticks(40)
        check(w.writesTried == tried and w.asked.LockpickPrecision == reads and printedCount(ue, "could not be written") == 1 and #ue.errors == 0 and c.durability() == 9,
            "no further try, not even a read; the other attribute is kept as chosen")
        check(has(status(c), "|left alone until the settings change (could not be written): LockpickPrecision") and has(status(c), "connections taken away 2 (the game's own)"), "the status names it")
        local dumped = c.fake.dump[1]()
        check(dumped.LockpickPrecision.given_up == true and dumped.LockpickPrecision.failed_writes == 3 and dumped.LockpickDurability.given_up == false and dumped.LockpickDurability.failed_writes == 0,
            "and so does the dump")
        lock = w.startLock(LOCKS.AM_Chest_04_Lock)
        c.ticks(1)
        check(lock.precision == 2 and c.ui.note() == "Lock picking (master): the pick breaks after 9 wrong moves" and c.fake.value("locks.in_place") == "yes",
            "a lock: the note names only what is really changed")
        lock.leave()
        c.ticks(1)
        -- a change of the settings tries anew
        T.write(c.path, config(PLAYER))
        ue:fireConsole("locks reload")
        c.ticks(1)
        check(w.writesTried > tried and c.S.failed.LockpickPrecision == 1 and c.durability() == 6, "new settings: the write is tried anew")
        stop(c)
    end

    -- what is taken back is the base value and the current value as they were, also when the two differ
    c = start("write-half", { config = config(PLAYER), game = { level = "master" } })
    local half = c.world.spoil("LockpickPrecision", "base only")
    half.BaseValue, half.CurrentValue = 2.0, 3.0
    c.ticks(1)
    check(half.BaseValue == 2 and half.CurrentValue == 3 and c.S.failed.LockpickPrecision == 1 and c.S.mark.LockpickPrecision == nil,
        "a base value and a current value that differ (an effect of the game on top): after a write that arrived by half both are as they were")
    stop(c)

    c = start("current-counts", { config = config(PLAYER), game = { level = "master" } })
    c.world.hero.store.LockpickPrecision.BaseValue, c.world.hero.store.LockpickPrecision.CurrentValue = 2.0, 99.0
    c.ticks(2)
    check(c.S.writes == 0 and c.S.mark.LockpickPrecision == 99 and (c.world.bases()) == 2, "the current value is what the game reads at a lock, and what the module compares: where it already is the chosen number nothing is written")
    stop(c)

    -- the write works at first, then no longer: what the module wrote stays in place, and it says so
    c = start("write-later", { config = config('Config.MasterConnections = "all"'), game = { level = "master" }, diag = true })
    ue, w = c.ue, c.world
    c.ticks(2)
    local data = w.spoil("LockpickPrecision", "ignored")
    T.menuSet(c, "Lock picking", "Lock picking by skill", false)
    c.ticks(1)
    check(data.CurrentValue == 99 and c.S.mark.LockpickPrecision == 99 and c.S.putBack == 0 and c.S.awake == true and c.S.failed.LockpickPrecision == 1,
        "putting back fails: the number stays marked as the module's, the module does not rest yet (the first failure after a write that worked)")
    c.ticks(2)
    check(c.S.givenUp.LockpickPrecision == true and c.S.mark.LockpickPrecision == nil
        and printed(ue, "[G1R_Locks] LockpickPrecision is left alone until the settings change: 3 writes in a row did not work - it still holds the 99 this module wrote earlier\n") ~= nil,
        "after three tries it gives up and says that its number is still in place")
    c.ticks(1)
    check(c.S.awake == false and c.S.setName == nil, "then it rests")
    ue:fireConsole("locks restore")
    c.ticks(2)
    check(data.CurrentValue == 99 and printed(ue, "[G1R_Locks] the game's own values for the level master could not be written: LockpickPrecision\n") ~= nil and c.S.asked == nil,
        "locks restore tries once more, and says honestly that it could not write")
    w.write("LockpickDurability", 50)
    ue:fireConsole("locks restore")
    c.ticks(2)
    check(c.durability() == 6 and printed(ue, "[G1R_Locks] the game's own values for the level master could not be written: LockpickPrecision; put back: LockpickDurability back to 6\n") ~= nil,
        "one number that cannot be written and one that can: both are said")
    w.hero.store.LockpickPrecision = data            -- the attribute takes writes again
    ue:fireConsole("locks restore")
    c.ticks(2)
    check(data.CurrentValue == 2 and data.BaseValue == 2 and printed(ue, "were put back: LockpickPrecision back to 2") ~= nil, "and once the write works, locks restore puts the game's number back")
    stop(c)

    -- no lock picking attributes at all
    c = start("no-set", { config = T.config(PLAYER), game = { level = "master", noSet = true } })
    ue, w = c.ue, c.world
    c.seconds(60)
    check(allOf(ue) == 5 and c.S.setName == nil and #ue.errors == 0 and w.called("HasGameplayTag") == 0,
        "a hero without lock picking attributes: the kit looks at his list three times, then searches with growing pauses - 4 searches in the first minute (and 1 for the controller): " .. allOf(ue))
    c.seconds(240)
    check(allOf(ue) == 9, "and one a minute after that (" .. (allOf(ue) - 5) .. " in four minutes)")
    check(has(status(c), "|the hero's lock picking values have not been found yet (no game loaded?)|") and printedCount(ue, "\n") == 1, "the status says so; nothing is written into the log about it")
    stop(c)

    -- no controller (the main menu), then one appears
    c = start("no-controller", { config = T.config(PLAYER), game = { level = "master", noController = true } })
    ue, w = c.ue, c.world
    c.seconds(12)
    check(allOf(ue) == 8 and sum(w.asked) == 0 and w.called("HasGameplayTag") == 0, "without a controller the kit searches every 3 seconds under two class names (" .. allOf(ue) .. " searches in 12 s); nothing else is asked")
    ue.allOf["PlayerController"] = { w.controller }
    c.seconds(4)
    check(c.precision() == 99 and c.S.via == "player state", "a controller appears: the hero is found within 3 seconds, the number written")
    stop(c)

    -- a UE4SS that lacks something
    c = start("no-loop", { config = config(PLAYER), mock = { without = { "LoopInGameThreadWithDelay" } } })
    check(c.ok and printed(c.ue, "[G1R_Locks] FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; lock picking stays as the game has it.\n") ~= nil and printed(c.ue, "loaded:") == nil and #c.ue.errors == 0,
        "a UE4SS without the game-thread loop: said, nothing else happens")
    stop(c)
    c = start("no-console", { config = config(PLAYER), game = { level = "master" }, mock = { without = { "RegisterConsoleCommandHandler" } } })
    c.ticks(1)
    check(c.ok and c.precision() == 99 and #c.ue.errors == 0, "a UE4SS without console commands: the module works without them")
    stop(c)
    c = start("no-registerhook", { config = config('Config.MasterConnections = "safe"'), game = { level = "master" }, mock = { without = { "RegisterHook" } }, diag = true })
    c.ticks(3)
    lock = c.world.openChest("AM_Chest_04_Lock")
    check(lock.precision == 2 and c.S.hooked == false and c.fake.detail("locks.lock_hook") == "this UE4SS build has no RegisterHook"
        and printedCount(c.ue, "could not be hooked (this UE4SS build has no RegisterHook)") == 1 and #c.ue.errors == 0, "a UE4SS without RegisterHook: \"safe\" leaves the lock as the game has it, said once")
    stop(c)
    c = start("no-schema", { files = { ["Scripts/schema.lua"] = false } })
    check(c.ok and printed(c.ue, "[G1R_Locks] the settings could not be set up (schema.lua could not be read") ~= nil and #c.ue.loops == 1 and c.ue.console.locks == nil,
        "without schema.lua the module says so and does not start")
    stop(c)

    -- an error inside a look does not leave the module
    c = start("tick-error", { config = config(PLAYER), game = { level = "master" } })
    c.expectErrors = true        -- this case provokes an error inside the loop
    ue = c.ue
    c.ticks(1)
    local real = c.kit.attributeSet
    c.kit.attributeSet = function() error("the kit failed (test)") end
    c.ticks(8)
    check(#ue.errors == 0 and printedCount(ue, "[G1R_Locks] update error: ") == 1 and printed(ue, "the kit failed (test)") ~= nil, "an error inside a look is caught and said once, not eight times; UE4SS sees no error")
    c.kit.attributeSet = real
    c.ticks(1)
    check(c.S.awake == true and c.precision() == 99, "the loop goes on")
    stop(c, true)
end

-- ---------------------------------------------------------------------------
section("13. another hero, replaced and stale objects, other characters")
do
    local function lockSet(ue, statePath, n, precision, durability)
        return ue:object(("AttributeSet_Lockpicking %s.AttributeSet_Lockpicking_%d"):format(statePath, n), {
            LockpickDurability = { BaseValue = durability, CurrentValue = durability }, LockpickPrecision = { BaseValue = precision, CurrentValue = precision } })
    end
    local c = start("swap", { config = config(PLAYER), game = { level = "master" }, diag = true })
    local ue, w = c.ue, c.world
    local first = w.hero
    -- other characters have lock picking attributes too (a search among all objects would find them)
    local npc = lockSet(ue, "/Game/Maps/World.World:PersistentLevel.GothicNPCState_9", 3, 0.0, 2.0)
    ue.allOf["AttributeSet_Lockpicking"] = { npc, first.locks }
    c.ticks(2)
    check(c.precision() == 99 and c.S.setName == first.locks:GetFullName(), "(a master with the chosen number)")
    -- a new game: the controller gets another player state with its own attributes
    local second = w.adopt(T.hero(ue, w, 40), "skilled")
    w.controller.PlayerState = second.state
    c.ticks(1)
    check(c.S.setName == second.locks:GetFullName() and w.precision(second) == 2 and c.S.tier.key == "skilled" and c.S.mark.LockpickPrecision == 2,
        "another player state: its attributes are taken at the next look, with the number for ITS level (skilled: 2)")
    check(w.precision(first) == 99 and c.S.writes == 2, "the old attributes are left as they are - they go away with their player state")
    w.write("LockpickPrecision", 7, first)
    c.ticks(4)
    check(w.precision(first) == 7 and c.S.rewritten == 0, "a change in the old attributes is nobody's business")
    check(c.fake.count["locks.set_found_by"] == 1 and c.fake.value("locks.found_precision") == "the game's own", "(noted: found through the player state, holding the game's own number)")

    -- the attribute object is destroyed and another object gets its address: the kept wrapper looks alive again
    local stale = second.locks
    local replacement = lockSet(ue, "/Game/Maps/World.World:PersistentLevel.GothicPlayerState_40", 77, 1.0, 4.0)
    second.component.SpawnedAttributes.items[4] = replacement
    stale.__full = "AttributeSet_Lockpicking /Game/Maps/World.World:PersistentLevel.GothicNPCState_9.AttributeSet_Lockpicking_5"
    w.write("LockpickPrecision", 0, second)      -- (what the other character's attributes hold now)
    c.ticks(1)
    check(c.S.setName == replacement:GetFullName() and replacement.LockpickPrecision.CurrentValue == 2 and w.precision(second) == 0,
        "a kept wrapper that now names another character's attributes is dropped: those are not written to, the hero's new ones are")
    -- the object is gone for good
    replacement.__valid = false
    local third = lockSet(ue, "/Game/Maps/World.World:PersistentLevel.GothicPlayerState_40", 78, 1.0, 4.0)
    second.component.SpawnedAttributes.items[4] = third
    c.ticks(1)
    check(c.S.setName == third:GetFullName() and third.LockpickPrecision.CurrentValue == 2 and replacement.LockpickPrecision.CurrentValue == 2 and #ue.errors == 0,
        "attributes that are gone are looked up again through the player state")
    check(npc.LockpickPrecision.CurrentValue == 0 and npc.LockpickDurability.CurrentValue == 2 and allOf(ue) == 1, "another character's attributes are never touched; all of this without a second search among all objects")
    stop(c)

    -- the hero goes away (the controller has no player state for a while) and comes back
    c = start("leave", { config = config(PLAYER), game = { level = "master" }, diag = true })
    ue, w = c.ue, c.world
    c.ticks(2)
    w.controller.PlayerState = nil
    c.ticks(1)
    check(c.S.setName == nil and c.S.mark.LockpickPrecision == nil and c.S.tier == nil and has(status(c), "|the hero's lock picking values have not been found yet (no game loaded?)|"),
        "the controller has no player state any more: what was known about the hero is forgotten, the status says so")
    local asked, questions = sum(w.asked), w.called("HasGameplayTag")
    c.ticks(40)
    check(sum(w.asked) == asked and w.called("HasGameplayTag") == questions and c.precision() == 99, "his attributes are neither read nor written, his tags not asked")
    w.controller.PlayerState = w.hero.state
    c.ticks(1)
    check(c.S.setName == w.hero.locks:GetFullName() and c.S.mark.LockpickPrecision == 99 and c.S.writes == 1 and c.fake.value("locks.found_precision") == "this module's number",
        "he is back with the same attributes: the number in them is taken for the module's own (nothing to write), and noted as that")
    T.menuSet(c, "Lock picking", "Master", 1)
    c.ticks(1)
    check(c.precision() == 2 and c.S.putBack == 1, "so it is put back when the level is left to the game")
    stop(c)

    -- the state's own list is not usable: the kit's search finds the attributes of this player state
    c = start("scan", { config = config(PLAYER), diag = true, prepare = function(ue2)
        local world = game(ue2, { level = "master" })
        world.hero.component.SpawnedAttributes = nil
        world.other = world.adopt(T.hero(ue2, world, 60), "skilled")
        world.npc = lockSet(ue2, "/Game/Maps/World.World:PersistentLevel.GothicNPCState_9", 3, 0.0, 2.0)
        ue2.allOf["AttributeSet_Lockpicking"] = { world.npc, world.hero.locks, world.other.locks }
        return world
    end })
    ue, w = c.ue, c.world
    c.seconds(6)
    check(c.S.via == "scan" and c.fake.value("locks.set_found_by") == "scan" and c.precision() == 99 and c.S.tierBy == "tags",
        "found by the kit's search: the attributes inside the controller's player state (noted); the level still by his tag")
    check(w.precision(w.other) == 1 and w.npc.LockpickPrecision.CurrentValue == 0, "only the hero's number is changed: not the other player state's, not the other character's")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("14. map loads")
do
    local c = start("load-map", { config = config(PLAYER .. "\nConfig.MasterWrongMoves = 9"), game = { level = "master" }, diag = true })
    local ue, w = c.ue, c.world
    c.ticks(2)
    check(c.precision() == 99 and c.durability() == 9, "(before the load: 99 and 9)")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    check(c.S.setName == nil and c.S.mark.LockpickPrecision == nil and c.S.tier == nil, "the hook before a map load: what was known about the hero is forgotten")
    local asked, questions, state, finds = sum(w.asked), w.called("HasGameplayTag"), w.reads[21], allOf(ue)
    w.write("LockpickPrecision", 2)
    c.seconds(15)
    check(c.precision() == 2 and sum(w.asked) == asked and w.called("HasGameplayTag") == questions and w.reads[21] == state and allOf(ue) == finds and #ue.errors == 0,
        "between the two map load hooks the module does nothing: no read, no question, no search, no write")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(1)
    check(c.precision() == 99 and c.S.writes == 3 and allOf(ue) == finds + 1, "after the load the hero is searched for once and found; his numbers are written at the first look")
    -- a save is loaded while a lock is being picked
    local lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(1)
    check(c.S.picking == true, "(a lock is being picked)")
    local saved = w.save()
    local fresh = w.load(saved)
    check(c.S.picking == nil and c.S.lock == nil, "a load in the middle of a lock: the lock is forgotten with everything else")
    c.ticks(1)
    check(w.precision() == 99 and w.durability() == 9 and c.S.setName == fresh.locks:GetFullName() and c.S.picking == false, "the new hero's numbers are written at the first look")
    lock.leave()
    -- a load whose end is never reported
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    w.write("LockpickPrecision", 2)
    c.seconds(19.5)
    check(w.precision() == 2, "a map load that never reports its end: nothing for 20 seconds")
    c.seconds(1)
    check(w.precision() == 99, "then the module goes on (it does not wait for ever)")
    stop(c)

    -- a lock announced by the chest hook, then a load
    c = start("load-announced", { config = config('Config.SkilledConnections = "safe"'), game = { level = "skilled" } })
    ue, w = c.ue, c.world
    c.ticks(1)
    w.openChest("AM_Chest_04_Lock", false)
    check(c.S.lock ~= nil and c.precision() == 8, "(the hook has announced a lock and written its number)")
    local old = w.hero
    w.load(w.save())
    check(c.S.lock == nil and c.S.tier == nil, "a load right after: the announced lock is forgotten")
    w.openChest("AM_Chest_04_Lock", false)
    check(w.precision() == 1 and c.S.hookRuns == 1, "the hook before the first look at the new hero does nothing")
    c.ticks(1)
    lock = w.openChest("FM_Chest_Digginggallery_02_Lock")
    check(lock.precision == 2 and c.ue.calls.RegisterHook == 1 and old.store.LockpickPrecision.CurrentValue == 8, "after the first look it works again - with the one registration of this run")
    stop(c)

    c = start("no-post-hook", { config = config(PLAYER), game = { level = "master" }, mock = { without = { "RegisterLoadMapPostHook" } } })
    c.ticks(1)
    c.ue:fireLoadMapPre("engine", "world", "url", nil, "")
    c.world.write("LockpickPrecision", 2)
    c.ticks(2)
    check(c.precision() == 99 and #c.ue.errors == 0, "a UE4SS without the hook after a map load: the module does not wait for an end that cannot be reported")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("15. settings while the game runs: the file, the in-game menu, the console")
do
    local c = start("reload", { game = { level = "master" }, diag = true })      -- the shipped settings: nothing to change
    local ue, w = c.ue, c.world
    local v = c.hook.settings.values
    c.seconds(3)
    check(allOf(ue) == 0 and sum(w.asked) == 0, "shipped settings: the game is not looked at")
    T.write(c.path, T.config('Config.MasterConnections = "all"'))
    c.ticks(7)
    check(printed(ue, "settings changed") == nil and c.precision() == 2, "the file is not read more often than every 5 seconds")
    c.ticks(1)
    check(printed(ue, "[G1R_Locks] settings changed (config.lua): connections taken away game / game / all (untrained / skilled / master); wrong moves per pick game / game / game\n") ~= nil,
        "a changed file is picked up within 5 seconds, said in the log")
    check(c.precision() == 99 and allOf(ue) == 1 and c.S.awake == true, "a choice was made: the module looks at the game in the same quarter second and writes the number")
    -- another choice: the next look writes it
    T.write(c.path, config('Config.MasterConnections = "1"'))
    local before = #ue.printed
    check(ue:fireConsole("locks reload") == true and ue.printed[before + 1] == "[G1R_Locks] settings changed (config.lua): connections taken away game / game / 1 (untrained / skilled / master); wrong moves per pick game / game / game\n"
        and ue.printed[before + 2] == "[G1R_Locks] settings read: connections taken away game / game / 1 (untrained / skilled / master); wrong moves per pick game / game / game\n",
        "locks reload reads the file at once and says what is set")
    check(c.precision() == 99, "(nothing is written inside the console command)")
    c.ticks(1)
    check(c.precision() == 1 and c.S.writes == 2, "the next quarter second writes the new number")
    -- switched off: put back, then at rest
    T.write(c.path, config('Config.MasterConnections = "1"\nConfig.Enabled = false'))
    ue:fireConsole("locks reload")
    c.ticks(1)
    local asked, questions, finds = sum(w.asked), w.called("HasGameplayTag"), allOf(ue)
    c.ticks(240)
    check(c.precision() == 2 and c.S.putBack == 1 and sum(w.asked) == asked and w.called("HasGameplayTag") == questions and allOf(ue) == finds and c.S.awake == false,
        "Enabled = false while the game runs: the game's number is put back at the next look, then nothing is read or asked any more")
    check(has(status(c), "v1.0.0 | switched off in the settings|nothing to change: the game is not looked at|"), "the status says so")
    -- a file with an error, a file that is gone
    T.write(c.path, "local Config = {}\nConfig.MasterConnections = \nreturn Config\n")
    c.ticks(24)
    check(printedCount(ue, "config.lua has an error, keeping the previous settings") == 1 and v.Enabled == false and v.MasterConnections == "1", "a file with an error: said once, the previous settings stay")
    os.remove(c.path)
    c.ticks(24)
    check(v.Enabled == false and #ue.errors == 0, "a file that is gone: the settings stay")
    before = #ue.printed
    ue:fireConsole("locks reload")
    check(ue.printed[before + 1] == "[G1R_Locks] settings not read: config.lua not found\n", "locks reload without a file: said")
    stop(c)

    -- the in-game mod menu
    c = start("menu", { config = config(""), game = { level = "skilled" }, diag = true })
    ue, w = c.ue, c.world
    v = c.hook.settings.values
    local index = T.menuIndex(c)
    check(#index == 1 and index[1] == "G1R Lock picking", "the module is registered with the in-game mod menu as the page G1R Lock picking")
    local page = T.menuPage(c, "Lock picking")
    local titles = {}
    for _, s in ipairs(page.sections) do titles[#titles + 1] = s.title .. ":" .. #s.items end
    check(table.concat(titles, "|") == "Lock picking:1|Connections taken away:3|Lock picks:4|On screen:1|Log:1|Repair:1", "its sections and their items: " .. table.concat(titles, "|"))
    local long = {}
    for _, i in ipairs(page.items) do
        if has(i.name, "LookSeconds") then check(false, "a hidden setting is in the menu: " .. i.name) end
        if #i.name > 35 or #i.desc > 54 or i.desc == "" or i.desc:sub(-3) == "..." or i.name:sub(-3) == "..." then long[#long + 1] = i.name end
    end
    check(#long == 0, "every item has a name of at most 35 characters and a hint of at most 54, nothing cut off - the menu's columns (" .. table.concat(long, "; ") .. ")")
    local item = T.menuItem(c, "Lock picking", "Skilled")
    check(item.kind == "num" and item.min == 1 and item.max == 7 and item.step == 1 and item.value == 1 and item.section == "Connections taken away"
        and item.desc == "now: as the game has it (1 of 7)", "a choice is a number from 1 to 7 in the menu; its hint names the choice it has (the list of seven does not fit)")
    item = T.menuItem(c, "Lock picking", "Master: wrong moves per pick")
    check(item.kind == "num" and item.min == 0 and item.max == 99 and item.step == 1 and item.value == 0 and item.name == "Master: wrong moves per pick"
        and item.desc == "moves before a pick breaks; 0 = the game's (6)", "the wrong moves: a number from 0 to 99, the game's own number in its hint")
    check(T.menuItem(c, "Lock picking", "Lock picking by skill").kind == "bool"
        and T.menuItem(c, "Lock picking", "Lock picking by skill").desc == "off: locks and picks as the game has them",
        "the module's switch is a switch, with its short menu text as the hint")
    c.ticks(4)
    check(c.precision() == 1 and sum(w.asked) == 0, "(nothing chosen yet: the game is not looked at)")
    T.menuSet(c, "Lock picking", "Skilled", 6)
    c.ticks(1)
    check(v.SkilledConnections == "safe" and printed(ue, "[G1R_Locks] settings changed (in-game menu): connections taken away game / safe / game (untrained / skilled / master); wrong moves per pick game / game / game\n") ~= nil,
        "an edit in the menu is applied at the next look of the loader")
    check(T.menuItem(c, "Lock picking", "Skilled").desc == "now: safe (6 of 7)", "the choice's hint names the new choice")
    check(has(T.read(c.path), 'Config.SkilledConnections = "safe"\n') and T.menuItem(c, "Lock picking", "Skilled").value == 6 and c.mods.store["SMM:cmd:G1R Lock picking"] == "",
        "written into config.lua, shown in the menu, the edit taken off the queue")
    check(ue.calls.RegisterHook == 1, "and used in the same quarter second: the hook for the chosen kind is registered")
    T.menuSet(c, "Lock picking", "Skilled", 7)
    T.menuSet(c, "Lock picking", "Lock picks do not break", true)
    T.menuSet(c, "Lock picking", "Log every lock you start on", true)
    c.ticks(1)
    check(v.SkilledConnections == "all" and v.PicksNeverBreak == true and v.LogLocks == true and c.precision() == 99 and c.durability() == 100000, "three edits at once: all applied, both numbers written")
    T.menuSet(c, "Lock picking", "Skilled", 9)
    T.menuSet(c, "Lock picking", "Skilled: wrong moves per pick", 500)
    c.ticks(1)
    check(v.SkilledConnections == "all" and v.SkilledWrongMoves == 99, "a number the menu should not send (choice 9 of 7, 500 wrong moves): the choice stays, the number is pulled to 99")
    T.menuSet(c, "Lock picking", "Lock picking by skill", false)
    c.ticks(1)
    check(v.Enabled == false and has(T.read(c.path), "Config.Enabled = false\n") and c.precision() == 1 and c.durability() == 4 and c.S.awake == false,
        "switched off in the menu: config.lua says Enabled = false, the game's numbers are back, and the module rests in the same quarter second")
    check(printedCount(ue, "settings changed (config.lua)") == 0, "what the module's settings wrote themselves is not taken for a change of the file")
    stop(c)

    -- values that are not usable
    c = start("bad", { config = T.config('Config.MasterConnections = "everything"\nConfig.SkilledConnections = 2\nConfig.UntrainedConnections = "ALL"\nConfig.LookSeconds = 0.01\n'
        .. 'Config.ShowMessage = "yes"\nConfig.PicksNeverBreak = 1\nConfig.MasterWrongMoves = 2.6\nConfig.SkilledWrongMoves = 0/0\nConfig.Unknown = 5') })
    v = c.hook.settings.values
    check(v.MasterConnections == "as the game has it" and v.SkilledConnections == "as the game has it" and v.UntrainedConnections == "as the game has it" and v.LookSeconds == 0.25
        and v.ShowMessage == true and v.PicksNeverBreak == false and v.MasterWrongMoves == 3 and v.SkilledWrongMoves == 0,
        "a choice that is not offered, a choice written as a number or in capitals, a switch that is no true / false, a number out of range or not a number: the default, or pulled into range")
    check(printed(c.ue, 'config.lua: MasterConnections = everything is not usable; "as the game has it" is used') ~= nil
        and printed(c.ue, 'config.lua: SkilledConnections = 2 is not usable; "as the game has it" is used') ~= nil and #c.ue.errors == 0, "each said in the log")
    stop(c)
    c = start("look-range", { config = T.config('Config.MasterConnections = "all"\nConfig.LookSeconds = 100'), game = { level = "master" } })
    check(c.hook.settings.values.LookSeconds == 10, "the hidden pace of the looks: at most 10 seconds")
    c.ticks(1)
    check(c.precision() == 99, "(the first look comes at once all the same)")
    c.world.write("LockpickPrecision", 2)
    c.ticks(39)
    check(c.precision() == 2, "the next one ten seconds later, not before")
    c.ticks(1)
    check(c.precision() == 99, "(then)")
    stop(c)
    c = start("badstart", { config = "this is not lua\n", game = { level = "master" } })
    check(c.ok and printed(c.ue, "config.lua has an error (") ~= nil and c.hook.settings.values.MasterConnections == "as the game has it" and printed(c.ue, "loaded: locks and lock picks as the game has them") ~= nil,
        "a broken file at the start: said, default settings (nothing is changed)")
    check(T.read(c.path) == "this is not lua\n", "the broken file is left for its owner to repair")
    stop(c)
    c = start("nofile", { config = false })
    check(c.ok and printed(c.ue, "config.lua was not there: written with the default settings") ~= nil and T.read(c.path) == shipped, "no file at the start: the default file is written")
    stop(c)

    -- the console
    c = start("console", { config = config(PLAYER), game = { level = "master" } })
    ue, w = c.ue, c.world
    before = #ue.printed
    check(ue:fireConsole("locks") == true and #ue.errors == 0, "locks: handled (a boolean is returned)")
    check(ue.printed[before + 1] == "[G1R_Locks] v1.0.0 | connections taken away game / 2 / all (untrained / skilled / master); wrong moves per pick game / game / game\n"
        and ue.printed[before + 2] == "[G1R_Locks] the hero's lock picking values have not been found yet (no game loaded?)\n"
        and ue.printed[before + 3] == "[G1R_Locks] locks started: 0 (with this module's numbers: 0); values written: 0, put back: 0, rewritten by the game: 0\n"
        and #ue.printed == before + 3, "before the first look: the settings, nothing found, nothing counted")
    check(#ue.device.lines == 3 and ue.device.lines[1] == "[G1R_Locks] v1.0.0 | connections taken away game / 2 / all (untrained / skilled / master); wrong moves per pick game / game / game",
        "the same lines go to the console window")
    check(sum(w.asked) == 0 and allOf(ue) == 0, "the console command itself does not look at the game")
    c.ticks(1)
    check(ue:fireConsole("g1r_locks status") == true and ue:fireConsole("locks something") == true and printedCount(ue, "the hero is master (told by his skill tag)") == 2, "g1r_locks works too; an unknown word shows the status")
    ue:fireConsole("locks RELOAD")
    check(printedCount(ue, "settings read:") == 1, "the word may be written in capitals")
    check(c.hook.console(nil, nil, nil) == true and c.hook.console("locks reload", nil, nil) == true and c.hook.console("locks", { 2, {} }, {}) == true and #ue.errors == 0,
        "called with nothing, with the command line only, with parameters of another kind: handled")
    check(printedCount(ue, "settings read:") == 2, "with the command line only, the words are taken from it (locks reload)")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("16. what is shown and what is logged")
do
    local c = start("note", { config = config('Config.UntrainedConnections = "1"\nConfig.MasterConnections = "all"'), game = { level = "untrained" }, widgets = true, diag = true })
    local ue, w, ui = c.ue, c.world, c.ui
    c.ticks(1)
    local perPath = {}
    for _, p in ipairs(ue.lookups) do perPath[p] = (perPath[p] or 0) + 1 end
    local once, paths = true, 0
    for _, n in pairs(perPath) do paths = paths + 1 if n ~= 1 then once = false end end
    check(once and paths == 6 and ui.created == 0, "when the hero is found the six paths of the note are searched, each once; nothing is built yet")
    local lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    check(ui.note() == nil and lock.precision == 1, "(a lock starts with 1 connection taken away; nothing is shown before the next look)")
    c.ticks(1)
    check(ui.note() == "Lock picking (untrained): 1 of the connections taken away" and ui.created == 1, "the next look shows the note: " .. tostring(ui.note()))
    check(#c.fake.events == 1 and c.fake.events[1] == "first changed lock: untrained: 1 of the connections taken away (the game: 0), level told by tags, attributes found through the player state",
        "the first changed lock goes to the diagnostics as an event: " .. tostring(c.fake.events[1]))
    check(printed(ue, "lock started") == nil and #ue.printed == 1, "nothing is written into the log about it (LogLocks is off): the load line is the only line")
    c.seconds(2.5)
    check(ui.note() ~= nil, "the note stays ...")
    c.seconds(1)
    check(ui.note() == nil, "... for the three seconds the kit gives a note")
    lock.leave()
    c.ticks(1)
    local lookups = #ue.lookups
    w.level("master")
    c.ticks(1)
    lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(1)
    check(ui.note() == "Lock picking (master): all connections taken away" and #c.fake.events == 1 and ui.created == 1 and #ue.lookups == lookups,
        "the next lock, as a master: its own note, in the same widget; no second event, no further search")
    T.menuSet(c, "Lock picking", "Note when a lock was changed", false)
    c.ticks(1)
    check(ui.note() == nil, "ShowMessage switched off while a note is up: it is taken off the screen")
    lock.leave()
    c.ticks(1)
    lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(2)
    check(ui.note() == nil and c.S.locks == 3 and c.S.changed == 3 and lock.precision == 99, "and the next lock shows none (the lock is changed all the same)")
    lock.leave()
    stop(c)

    -- a lock the module did not change gets no note
    c = start("note-own", { config = config(PLAYER), game = { level = "untrained" }, widgets = true })
    ue, w, ui = c.ue, c.world, c.ui
    c.ticks(1)
    lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(1)
    check(ui.note() == nil and ui.created == 0 and c.S.locks == 1 and c.S.changed == 0 and printed(ue, "[G1R_Locks] lock started - untrained: as the game has it\n") ~= nil,
        "a lock at a level left to the game: no note; the log line (LogLocks) says \"as the game has it\"")
    lock.leave()
    stop(c)

    -- the game's own line instead of the box; notes switched off
    c = start("note-subtitle", { config = config(PLAYER), game = { level = "master" }, widgets = true })
    ue, w, ui = c.ue, c.world, c.ui
    c.kit.configureNotes({ style = "subtitle" })
    c.ticks(1)
    lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(1)
    check(#ui.subtitles == 1 and ui.subtitles[1].text == "Lock picking (master): all connections taken away" and ui.created == 0, "notes set to the game's own line (page General): the note goes there")
    lock.leave()
    c.kit.configureNotes({ style = "off" })
    c.ticks(1)
    lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(1)
    check(#ui.subtitles == 1 and ui.created == 0 and c.S.changed == 2, "notes switched off there: none")
    stop(c)

    -- no widget side at all, ShowMessage off from the start
    c = start("note-none", { config = config(PLAYER), game = { level = "master" } })
    c.ticks(1)
    lock = c.world.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(2)
    check(lock.precision == 99 and #c.ue.errors == 0 and printedCount(c.ue, "[G1R_MegaMod] notes on screen are not available") == 1, "a game without the note's widgets: the kit says so once, the lock is changed, no error")
    stop(c)
    c = start("note-off", { config = config(PLAYER .. "\nConfig.ShowMessage = false"), game = { level = "master" }, widgets = true })
    c.ticks(1)
    lock = c.world.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(2)
    check(#c.ue.lookups == 0 and c.ui.created == 0 and c.ui.note() == nil and c.S.changed == 1, "ShowMessage = false from the start: the note's paths are never searched, nothing is built or shown")
    stop(c)

    -- the log lines
    c = start("log", { config = config('Config.MasterConnections = "none"\nConfig.MasterWrongMoves = 3\nConfig.SkilledConnections = "2"\nConfig.SkilledWrongMoves = 4\nConfig.LogLocks = true'), game = { level = "skilled" } })
    ue, w = c.ue, c.world
    c.ticks(1)
    check(printed(ue, "[G1R_Locks] level skilled: LockpickPrecision -> 2\n") ~= nil, "LogLocks: a written number is said with the level (the pick's 4 is the game's own: not written, not said)")
    lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(1)
    check(printed(ue, "[G1R_Locks] lock started - skilled: 2 of the connections taken away (the game: 1)\n") ~= nil, "a lock: what is changed, with the game's own number")
    lock.leave()
    w.level("master")
    c.ticks(1)
    check(printed(ue, "[G1R_Locks] level master: LockpickPrecision -> 0, LockpickDurability -> 3\n") ~= nil, "a new level: both numbers")
    lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(1)
    check(printed(ue, "[G1R_Locks] lock started - master: no connection taken away (the game: 2), the pick breaks after 3 wrong moves (the game: 6)\n") ~= nil, "a lock made harder is said the same way")
    lock.leave()
    local lines = #ue.printed
    c.ticks(6)
    check(printedCount(ue, "] level ") == 2 and printedCount(ue, "lock started") == 2 and #ue.printed == lines, "six looks that have nothing to write: no line (one line per written level and one per lock is all)")
    T.menuSet(c, "Lock picking", "Log every lock you start on", false)
    c.ticks(1)
    w.level("skilled")
    c.ticks(1)
    lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(1)
    check(#ue.printed == lines + 1 and has(ue.printed[#ue.printed], "settings changed (in-game menu)"), "LogLocks off: no line for a level or a lock (one line for the changed settings)")
    lock.leave()
    stop(c)

    -- another mod writes its own number when a lock starts
    c = start("foreign", { config = config('Config.MasterConnections = "all"\nConfig.MasterWrongMoves = 9\nConfig.LogLocks = true'), game = { level = "master" }, widgets = true, diag = true })
    ue, w, ui = c.ue, c.world, c.ui
    c.ticks(1)
    local FOREIGN = "[G1R_Locks] at the start of a lock LockpickPrecision was 2, not the 99 this module had written: the game or another mod changed it, and this module's number did not count for that lock\n"
    for round = 1, 2 do
        w.write("LockpickPrecision", 2)
        lock = w.startLock(LOCKS.AM_Chest_04_Lock)
        c.ticks(1)
        if round == 1 then
            check(lock.precision == 2 and c.fake.value("locks.in_place") == "no" and c.fake.detail("locks.in_place") == "LockpickPrecision 2 instead of 99" and printedCount(ue, FOREIGN) == 1,
                "a lock that was set up with another number than the module's: noted, said in the log")
            check(ui.note() == "Lock picking (master): the pick breaks after 9 wrong moves" and printed(ue, "[G1R_Locks] lock started - master: the pick breaks after 9 wrong moves (the game: 6)\n") ~= nil,
                "the note and the log line name only what really counted for that lock")
        end
        lock.leave()
        c.ticks(1)
    end
    check(c.precision() == 99 and printedCount(ue, FOREIGN) == 1 and c.fake.count["locks.in_place"] == 1 and c.S.writes == 4, "after the lock the module's number is written again; a second time is not said again")
    lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(1)
    check(lock.precision == 99 and c.fake.value("locks.in_place") == "yes" and c.fake.count["locks.in_place"] == 2, "a lock with the module's numbers in place: noted as that")
    lock.leave()
    stop(c)
end

-- ---------------------------------------------------------------------------
section("17. what the module asks of the game (counted, at the shipped pace of one look a second)")
do
    -- everything the model counts, as one text: reads of the two attributes, tag questions, the player state asked
    -- for its ability system, searches, hook registrations
    local function snap(c)
        local w, ue = c.world, c.ue
        local t = { state = w.reads[21] or 0, FindAllOf = ue.calls.FindAllOf or 0, FindFirstOf = ue.calls.FindFirstOf or 0, lookups = #ue.lookups, RegisterHook = ue.calls.RegisterHook or 0,
            NotifyOnNewObject = ue.calls.NotifyOnNewObject or 0, writes = c.S.writes + c.S.putBack }
        for k, v in pairs(w.asked) do t[k] = v end
        for k, v in pairs(w.calls) do t[k] = v end
        return t
    end
    local ORDER = { "LockpickPrecision", "LockpickDurability", "HasGameplayTag", "state", "writes", "FindAllOf", "FindFirstOf", "lookups", "RegisterHook", "NotifyOnNewObject" }
    local function since(a, b)
        local out = {}
        for _, k in ipairs(ORDER) do
            local n = (b[k] or 0) - (a[k] or 0)
            if n ~= 0 then out[#out + 1] = k .. " " .. n end
        end
        return table.concat(out, ", ")
    end
    local c = start("cost", { config = T.config(PLAYER), game = { level = "master" }, widgets = true })
    local w = c.world
    c.ticks(1)
    local first = snap(c)
    check(since({}, first) == "LockpickPrecision 3, HasGameplayTag 2, state 2, writes 1, FindAllOf 1, lookups 6",
        "the first look: one search for the controller, the six paths of the note, two tag questions; the number is read, written and read back (" .. since({}, first) .. ")")
    c.seconds(60)
    local one = snap(c)
    c.seconds(60)
    local two = snap(c)
    check(since(one, two) == "LockpickPrecision 60, HasGameplayTag 120, state 72",
        "a minute between locks, master with \"all\": per look the number is read once and two tags are asked (the master's, a lock being picked): " .. since(one, two))
    local lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.seconds(1)
    local three = snap(c)
    c.seconds(60)
    local four = snap(c)
    check(since(three, four) == "HasGameplayTag 120, state 72", "a minute inside a lock: the two tag questions per look, no attribute is read (" .. since(three, four) .. ")")
    lock.leave()
    w.level("untrained")
    c.seconds(2)
    local five = snap(c)
    c.seconds(60)
    local six = snap(c)
    check(since(five, six) == "HasGameplayTag 240, state 72", "a minute at a level left to the game (untrained): four tag questions per look - the three levels from the top, a lock being picked - and nothing else (" .. since(five, six) .. ")")
    check(six.FindAllOf == 1 and six.lookups == 6 and six.RegisterHook == 0 and six.NotifyOnNewObject == 0 and c.ui.created == 1,
        "more than three minutes and a lock with its note: the searches of the first look are all there are; no hook, no notification")
    stop(c)

    c = start("cost-safe", { config = T.config('Config.SkilledConnections = "safe"\nConfig.MasterConnections = "all"'), game = { level = "skilled" }, widgets = true })
    w = c.world
    c.seconds(2)
    local a = snap(c)
    c.seconds(60)
    local b = snap(c)
    check(since(a, b) == "LockpickPrecision 60, HasGameplayTag 180, state 72" and b.RegisterHook == 1,
        "\"safe\" between locks, skilled: per look three tag questions, and the number is read once (it must be the game's own); nothing is written; one hook registered (" .. since(a, b) .. ")")
    lock = w.openChest("AM_Chest_04_Lock")
    local d = snap(c)
    check(since(b, d) == "LockpickPrecision 3, writes 1", "a chest is opened: the hook reads the number, writes the lock's and reads it back (" .. since(b, d) .. ")")
    c.seconds(1)
    lock.leave()
    c.seconds(2)
    local e = snap(c)
    check(since(d, e) == "LockpickPrecision 6, HasGameplayTag 21, state 7, writes 1" and e.RegisterHook == 1,
        "a second inside the lock and two after it: while such a lock is in hand every quarter second looks (three tag questions); the number is checked once at the start, the game's own put back once at the end, and read at the two looks after that ("
        .. since(d, e) .. ")")
    stop(c)

    c = start("cost-both", { config = T.config('Config.MasterConnections = "all"\nConfig.PicksNeverBreak = true'), game = { level = "master" } })
    c.seconds(2)
    a = snap(c)
    c.seconds(60)
    b = snap(c)
    check(since(a, b) == "LockpickPrecision 60, LockpickDurability 60, HasGameplayTag 120, state 72", "both numbers chosen: both are read once per look (" .. since(a, b) .. ")")
    stop(c)

    c = start("cost-values", { config = T.config(PLAYER), game = { level = "master", tagError = true } })
    c.seconds(5)
    a = snap(c)
    c.seconds(60)
    b = snap(c)
    check(since(a, b) == "LockpickPrecision 60, LockpickDurability 60, state 72", "without usable tags: the pick's number tells the level, once per look; no tag question (" .. since(a, b) .. ")")
    stop(c)

    c = start("cost-idle", { game = { level = "master" } })
    c.seconds(600)
    check(since({}, snap(c)) == "", "the shipped settings, ten minutes: nothing at all")
    stop(c)
    c = start("cost-off", { config = T.config(PLAYER .. "\nConfig.Enabled = false"), game = { level = "master" } })
    c.seconds(600)
    check(since({}, snap(c)) == "", "switched off, ten minutes: nothing at all")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("18. the diagnostics")
do
    local c = start("diag", { config = config('Config.SkilledConnections = "safe"\nConfig.MasterConnections = "all"\nConfig.MasterWrongMoves = 9'), game = { level = "skilled" }, diag = true, widgets = true })
    local ue, w = c.ue, c.world
    c.ticks(2)
    local lock = w.openChest("FM_Chest_Digginggallery_02_Lock")
    c.ticks(2)
    lock.leave()
    c.ticks(2)
    lock = w.openDoor("AMR_Storage_Room_Lock")
    c.ticks(2)
    lock.leave()
    c.ticks(2)
    w.level("master")
    c.ticks(2)
    w.level("master")           -- (the game writes its numbers once more)
    c.ticks(2)
    local sequence = table.concat(c.fake.sequence(), " ")
    check(sequence == "locks.set_found_by=player state locks.tags=readable locks.level=skilled locks.level_by=tags locks.lock_hook=registered locks.lock_table=read"
        .. " locks.readable_precision=yes locks.found_precision=the game's own locks.lock_hook=runs locks.write_precision=ok locks.minigame=seen locks.lock_known=announced locks.in_place=yes locks.put_back=ok"
        .. " locks.lock_known=not announced locks.level=master locks.readable_durability=yes locks.found_durability=the game's own locks.write_durability=ok locks.rewritten=seen",
        "the notes of a session, each when its value changes: " .. sequence)
    for key, n in pairs({ ["locks.set_found_by"] = 1, ["locks.tags"] = 1, ["locks.level"] = 2, ["locks.level_by"] = 1, ["locks.lock_hook"] = 2, ["locks.lock_table"] = 1, ["locks.readable_precision"] = 1,
        ["locks.found_precision"] = 1, ["locks.write_precision"] = 1, ["locks.minigame"] = 1, ["locks.lock_known"] = 2, ["locks.in_place"] = 1, ["locks.put_back"] = 1,
        ["locks.readable_durability"] = 1, ["locks.found_durability"] = 1, ["locks.write_durability"] = 1, ["locks.rewritten"] = 1 }) do
        if c.fake.count[key] ~= n then check(false, "the note " .. key .. " was made " .. tostring(c.fake.count[key]) .. " times, not " .. n) end
    end
    check(c.fake.detail("locks.lock_known") == nil and c.fake.detail("locks.rewritten") == "LockpickPrecision 99 -> 2" and c.fake.versions[1] == "1.0.0" and #c.fake.events == 1
        and c.fake.events[1] == "first changed lock: skilled, FM_Chest_Digginggallery_02_Lock: 2 of 10 connections taken away (the game: 1), level told by tags, attributes found through the player state",
        "the version and the first changed lock go to the diagnostics: " .. tostring(c.fake.events[1]))
    local dump = c.fake.dump[1] and c.fake.dump[1]() or nil
    local statusLines = c.fake.status[1] and c.fake.status[1]() or {}
    local asked, calls, state, finds, lookups = sum(w.asked), sum(w.calls), w.reads[21], allOf(ue), #ue.lookups
    for _ = 1, 20 do
        c.fake.dump[1]()
        c.fake.status[1]()
    end
    check(sum(w.asked) == asked and sum(w.calls) == calls and w.reads[21] == state and allOf(ue) == finds and #ue.lookups == lookups, "the status and the dump are built from what the module holds: no call into the game")
    local Fake = dofile(HERE .. "../markers/diag_fake.lua")
    local plain, where = Fake.plain(dump)
    check(plain and Fake.roundTrip(dump), "the dump is plain data (" .. tostring(where) .. ")")
    check(dump.version == "1.0.0" and dump.enabled == true and dump.idle == false and dump.looking == true and dump.picks_never_break == false and dump.show_message == true and dump.log_locks == false
        and dump.look_seconds == 0.25 and dump.levels.skilled.connections == "safe" and dump.levels.master.connections == "all" and dump.levels.master.wrong_moves == 9 and dump.levels.untrained.wrong_moves == 0,
        "the dump: the settings")
    check(dump.attributes == w.hero.locks:GetFullName() and dump.found_through == "player state" and dump.level == "master" and dump.level_by == "tags" and dump.picking == false and dump.tags_unusable == false,
        "the hero: his attributes, how they were found, his level and how it was told")
    check(dump.locks_started == 2 and dump.locks_changed == 1 and dump.last_lock == "skilled: as the game has it (the lock was not known before it started: a door, or the hook did not run)"
        and dump.writes == 5 and dump.put_back == 1 and dump.rewritten == 2, "the counts: locks, writes, numbers put back and rewritten")
    check(dump.chest_hook == true and dump.chest_hook_calls == 1 and dump.chest_hook_runs == 1 and dump.lock_table == "read" and dump.announced_lock == nil, "the chest hook and the table")
    check(dump.LockpickPrecision.value == 99 and dump.LockpickPrecision.this_modules == 99 and dump.LockpickPrecision.failed_writes == 0 and dump.LockpickPrecision.given_up == false
        and dump.LockpickDurability.value == 9 and dump.LockpickDurability.this_modules == 9, "the two numbers: what they hold and that they are this module's")
    check(#statusLines == 4 and statusLines[1] == c.hook.status()[1] and statusLines[4] == "chests: the lock is told by the game's function that starts it (called 1 times, 1 of them for a lock of the hero)",
        "the status function gives the status lines")
    -- a lock that is announced shows in the dump
    w.level("skilled")
    c.ticks(1)
    w.openChest("AM_Chest_04_Lock", false)
    dump = c.fake.dump[1]()
    check(type(dump.announced_lock) == "table" and dump.announced_lock.name == "AM_Chest_04_Lock" and dump.announced_lock.connections == 8 and dump.announced_lock.taken_away == 8 and dump.announced_lock.started == false
        and Fake.plain(dump), "a lock the hook has announced is in the dump with its numbers")
    c.ticks(1)
    lock = w.openChest("AM_Chest_04_Lock")
    c.ticks(1)
    check(c.fake.dump[1]().announced_lock.started == true and c.fake.dump[1]().picking == true, "and once the look has seen it being picked, as started")
    lock.leave()
    stop(c)

    -- the dump of a module at rest, and before the table was needed
    c = start("diag-rest", { diag = true })
    c.ticks(4)
    dump = c.fake.dump[1]()
    check(dump.idle == true and dump.looking == false and dump.attributes == nil and dump.level == nil and dump.chest_hook == nil and dump.lock_table == "not needed yet" and #c.fake.notes == 0 and Fake.plain(dump)
        and dump.LockpickPrecision.failed_writes == 0 and dump.LockpickPrecision.given_up == false and dump.LockpickPrecision.value == nil and dump.LockpickPrecision.this_modules == nil,
        "at rest: nothing known, nothing noted, the table not read")
    stop(c)
    c = start("diag-table", { config = config('Config.SkilledConnections = "safe"'), game = { level = "skilled" }, files = { ["Scripts/lockdata.lua"] = false }, diag = true })
    c.ticks(1)
    c.world.openChest("AM_Chest_04_Lock", false)
    check(c.fake.dump[1]().lock_table == "not readable" and c.fake.value("locks.lock_table") == "not readable" and has(tostring(c.fake.detail("locks.lock_table")), "lockdata.lua"),
        "a missing lockdata.lua shows in the dump and as a note with the reason")
    stop(c)

    -- without diagnostics nothing of this runs
    c = start("diag-off", { config = config(PLAYER), game = { level = "master" } })
    c.ticks(2)
    lock = c.world.startLock(LOCKS.AM_Chest_04_Lock)
    c.ticks(2)
    check(c.precision() == 99 and c.S.changed == 1 and #c.ue.errors == 0, "without the diagnostics handle the module works the same")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("19. nothing leaks, only config.lua is written; the shipped files")
do
    local known = {}
    local probe = T.Mock.new()
    probe:install()                 -- what the mock itself puts into _G does not count
    for k in pairs(_G) do known[k] = true end
    probe:uninstall()
    local given = { LOCKS_TEST = true, ModRef = true, G1R_KIT = true, G1R_SETTINGS = true, G1R_DIAG = true, Key = true, ModifierKey = true, StaticConstructObject = true }
    local c = start("leak", { config = config('Config.SkilledConnections = "safe"\nConfig.MasterConnections = "all"\nConfig.PicksNeverBreak = true\nConfig.LogLocks = true'), widgets = true, diag = true, game = { level = "skilled" } })
    c.ticks(2)
    local lock = c.world.openChest("AM_Chest_04_Lock")
    c.ticks(2)
    lock.leave()
    c.world.level("master")
    c.ticks(2)
    c.ue:fireConsole("locks")
    T.menuSet(c, "Lock picking", "Lock picking by skill", false)
    c.ticks(2)
    c.ue:fireConsole("locks restore")
    c.ticks(2)
    local leaked = {}
    for k in pairs(_G) do
        if not known[k] and not given[k] then leaked[#leaked + 1] = tostring(k) end
    end
    stop(c)
    local leftAfter = {}
    for k in pairs(_G) do if not known[k] then leftAfter[#leftAfter + 1] = tostring(k) end end
    check(#leaked == 0 and #leftAfter == 0, "the module defines no global (" .. table.concat(leaked, ", ") .. ")")
    local p = io.popen("ls -A " .. T.q(c.dir))
    local listing = p:read("a"):gsub("%s+", " ")
    p:close()
    -- (config.lua.bak is the settings layer's: the file before the last change, as the settings app keeps it)
    check(listing:gsub("config%.lua%.bak ", "") == "config.lua lockdata.lua main.lua schema.lua ", "the module writes no file of its own (its folder holds: " .. listing .. ")")

    local schema = dofile(MOD .. "modules/locks/Scripts/schema.lua")
    local chunk = load(shipped, "=config.lua", "t", {})
    local values = chunk and chunk() or {}
    local keys = {}
    for k in pairs(values) do keys[#keys + 1] = k end
    table.sort(keys)
    check(table.concat(keys, ",") == "Enabled,LogLocks,MasterConnections,MasterWrongMoves,PicksNeverBreak,ShowMessage,SkilledConnections,SkilledWrongMoves,UntrainedConnections,UntrainedWrongMoves"
        and not shipped:find("\r", 1, true) and not shipped:find("[^\n\32-\126]"), "the shipped config.lua: 10 settings, plain ASCII, LF line ends (" .. #keys .. ")")
    probe = start("default-text", {})
    check(probe.settings.defaultText(schema) == shipped, "the shipped config.lua is exactly what the schema generates (lua5.4 dev/tools/gen_config.lua locks)")
    stop(probe)
    check(schema.Module == "locks" and schema.Page == "Lock picking" and schema.PageOrder == 40, "the schema puts the module on a page of its own: Lock picking (order 40)")
    local first = schema.Groups[1].Items[1]
    local neutral, choices = true, true
    for _, g in ipairs(schema.Groups) do
        for _, i in ipairs(g.Items) do
            if i.Kind == "choice" then
                if i.Default ~= "as the game has it" then neutral = false end
                if table.concat(i.Options, "|") ~= "as the game has it|none|1|2|half|safe|all" then choices = false end
            end
            if i.Kind == "number" and not i.Hidden and i.Default ~= 0 then neutral = false end
            if i.Key == "PicksNeverBreak" and i.Default ~= false then neutral = false end
        end
    end
    check(first.Key == "Enabled" and first.Default == true and neutral and choices,
        "the first item is the module's switch; every level's choice ships as \"as the game has it\", every number as 0; the three levels offer the same seven choices")
    -- the player's README names every setting, the button and the console words
    local readme = T.read(MOD .. "modules/locks/README.txt") or ""
    local missing = {}
    for _, g in ipairs(schema.Groups) do
        for _, i in ipairs(g.Items) do
            local name = i.Kind == "action" and i.Label or i.Key
            if not readme:find(name, 1, true) then missing[#missing + 1] = name end
        end
    end
    for _, word in ipairs({ "locks reload", "locks restore", "SkillfulLocks", "G1R Lock picking", "lockdata.lua", "In the game", "not seen in the game", "Saves" }) do
        if not readme:find(word, 1, true) then missing[#missing + 1] = word end
    end
    check(#missing == 0 and not readme:find("[^\n\32-\126]"), "README.txt names every setting (also the one that is not shown), the button, the console words, the other mod and what was seen in the game (" .. table.concat(missing, ", ") .. "); plain ASCII")
    -- every search and every hook goes through the kit (once per path and run, found or not): the module's own
    -- source does not even name the functions of UE4SS that search, hook or notify
    local source = T.read(MOD .. "modules/locks/Scripts/main.lua")
    local named = {}
    for _, word in ipairs({ "StaticFindObject", "FindAllOf", "FindFirstOf", "FindObject", "RegisterHook", "NotifyOnNewObject", "LoopAsync", "ExecuteAsync", "ExecuteWithDelay", "ExecuteInGameThread" }) do
        if source:find(word, 1, true) then named[#named + 1] = word end
    end
    check(#named == 0 and select(2, source:gsub("KIT%.hookOnce%(", "")) == 1 and select(2, source:gsub("LoopInGameThreadWithDelay%(", "")) == 1,
        "main.lua names no search, hook or notification function of UE4SS (" .. table.concat(named, ", ") .. "): one KIT.hookOnce, one game-thread loop")
    -- the table of the locks is plain data and needs nothing of the game
    local text = T.read(MOD .. "modules/locks/Scripts/lockdata.lua")
    local loaded = load(text, "=lockdata.lua", "t", {})
    local data = loaded and loaded() or nil
    local rows, wrong = 0, 0
    for name, row in pairs(data or {}) do
        rows = rows + 1
        if type(name) ~= "string" or type(row) ~= "table" or math.type(row[1]) ~= "integer" or math.type(row[2]) ~= "integer" or row[2] < 1 or row[2] > row[1] then wrong = wrong + 1 end
    end
    check(rows == 347 and wrong == 0 and not text:find("\r", 1, true) and not text:find("[^\n\32-\126]") and #text < 20000,
        "lockdata.lua: 347 rows of two whole numbers (connections, proven: 1 .. connections), plain ASCII, readable without any global, " .. #text .. " bytes")
end

-- ---------------------------------------------------------------------------
section("20. through the megamod loader, with the real diagnostics")
do
    local TMP = T.TMP
    local root = TMP .. "/mega/G1R_MegaMod"
    T.sh("rm -rf " .. T.q(TMP .. "/mega") .. " && mkdir -p " .. T.q(root) .. " && cp -r " .. T.q(MOD .. "Scripts") .. " " .. T.q(root .. "/") .. " && mkdir -p " .. T.q(root .. "/modules")
        .. " && cp -r " .. T.q(MOD .. "modules/locks") .. " " .. T.q(root .. "/modules/"))
    -- only this module: the list of modules is cut down to it (the line the module's report gives for core/modules.lua)
    T.write(root .. "/Scripts/core/modules.lua", 'return { { name = "locks", switch = "Locks", separate = { "SkillfulLocks" } } }\n')
    local SETTINGS = T.config('Config.SkilledConnections = "safe"\nConfig.MasterConnections = "all"\nConfig.LogLocks = true\nConfig.LookSeconds = 0.25')
    T.write(root .. "/modules/locks/Scripts/config.lua", SETTINGS)

    local function boot(level)
        local ue = T.Mock.new()
        ue:install()
        local ui = T.widgets(ue)
        local world = game(ue, { level = level or "master" })
        local mods = T.shared()
        rawset(_G, "ModRef", mods)
        local ok, err = pcall(dofile, root .. "/Scripts/main.lua")
        local c = { ue = ue, ui = ui, world = world, mods = mods, ok = ok, err = err, dir = root .. "/Scripts/diagnostics" }
        function c.looks(n)
            for _ = 1, n do
                ue:advance(0.25)
                ue:tick()
            end
        end
        return c
    end
    local function shutdown(c)
        c.ue:uninstall()
        rawset(_G, "ModRef", nil)
        rawset(_G, "StaticConstructObject", nil)
    end
    local function newest(c, prefix)
        local found
        local p = io.popen("ls " .. T.q(c.dir))
        -- (a session has three files: the log is the one meant by "session-")
        for name in p:lines() do if name:sub(1, #prefix) == prefix and (prefix ~= "session-" or name:sub(-4) == ".log") then found = name end end
        p:close()
        return T.read(c.dir .. "/" .. tostring(found)) or ""
    end
    local function last(c) return tostring(c.ue.printed[#c.ue.printed]):gsub("\n", "") end

    local c = boot("skilled")
    local ue, w = c.ue, c.world
    check(c.ok and has(last(c), "loaded: locks ok | diagnostics normal"), "the loader loads the module: " .. last(c))
    check(rawget(_G, "LOCKS_TEST") == nil and rawget(_G, "G1R_KIT") == nil and rawget(_G, "G1R_SETTINGS") == nil, "the test hook stays inert; the kit and the settings service are no globals")
    c.looks(2)
    check(ue.calls.RegisterHook == 1 and w.precision() == 1 and #ue.errors == 0, "skilled with \"safe\": the chest hook is registered through the loader, the number stays the game's between locks")
    local lock = w.openChest("FM_Chest_Digginggallery_02_Lock")
    c.looks(1)
    check(lock.precision == 2 and c.ui.note() == "Lock picking (skilled): 2 of 10 connections taken away"
        and printed(ue, "[G1R_Locks] lock started - skilled, FM_Chest_Digginggallery_02_Lock: 2 of 10 connections taken away (the game: 1)\n") ~= nil,
        "a chest: the hook runs inside the module's environment, the lock gets its number, the note and the log line appear")
    lock.leave()
    c.looks(1)
    w.level("master")
    c.looks(1)
    lock = w.startLock(LOCKS.AM_Chest_04_Lock)
    c.looks(1)
    check(lock.precision == 99 and w.precision() == 99 and c.ui.note() == "Lock picking (master): all connections taken away", "the hero becomes a master: every lock without connections, as without the loader")
    lock.leave()
    c.looks(1)
    check(ue:fireConsole("g1r diag") == true, "g1r diag handled")
    local report = T.read(c.dir .. "/report-latest.txt") or ""
    check(has(report, "locks: loaded, version 1.0.0") and has(report, "[locks] v1.0.0 | connections taken away game / safe / all (untrained / skilled / master); wrong moves per pick game / game / game")
        and has(report, "[locks] the hero is master (told by his skill tag); connections taken away 99 (this module's; the game's own: 2)")
        and has(report, "[locks] locks started: 2 (with this module's numbers: 2); last - master: all connections taken away (the game: 2); values written: 2, put back: 1, rewritten by the game: 0")
        and has(report, "[locks] chests: the lock is told by the game's function that starts it (called 1 times, 1 of them for a lock of the hero)"),
        "report: the module's version and its status lines")
    check(has(report, "locks.set_found_by = player state") and has(report, "locks.tags = readable") and has(report, "locks.level = master") and has(report, "locks.level_by = tags")
        and has(report, "locks.lock_hook = runs") and has(report, "locks.lock_table = read") and has(report, "locks.lock_known = announced") and has(report, "locks.found_precision = the game's own")
        and has(report, "locks.write_precision = ok") and has(report, "locks.minigame = seen") and has(report, "locks.in_place = yes") and has(report, "locks.put_back = ok")
        and has(report, "kit.toast = shown"), "report: the notes of the module and of the kit")
    check(has(report, "[locks] callbacks LoopInGameThreadWithDelay: 7 calls, 0 errors") and has(report, "[kit] callbacks RegisterHook: 1 calls, 0 errors") and has(report, "[kit] lookups: 6 calls, 6 first-time, 0 not found"),
        "report: the module's loop, the one call of the hook (registered through the kit) and the kit's six searches (for the note) are counted")
    local log = newest(c, "session-")
    check(has(log, "[locks] first changed lock: skilled, FM_Chest_Digginggallery_02_Lock: 2 of 10 connections taken away (the game: 1), level told by tags, attributes found through the player state")
        and has(log, "[locks] [G1R_Locks] v1.0.0 loaded: connections taken away game / safe / all") and not has(log, "ERROR in "), "session log: the load line and the first changed lock; no error")
    check(ue:fireConsole("g1r dump") == true, "g1r dump handled")
    local okDump, dump = pcall(load(newest(c, "dump-"), "=dump", "t", {}))
    check(okDump and type(dump) == "table" and type(dump.locks) == "table" and dump.locks.level == "master" and dump.locks.LockpickPrecision.this_modules == 99 and dump.locks.chest_hook == true
        and dump.locks.locks_started == 2 and dump._meta.refusedCount == 0, "dump: what the module holds")
    check(ue:fireConsole("g1r") == true and printed(ue, "[G1R_MegaMod] locks: loaded, version 1.0.0, 0 error(s), 13 note(s)") ~= nil, "g1r lists the module with its notes")
    check(ue:fireConsole("locks") == true and printed(ue, "[G1R_Locks] the hero is master (told by his skill tag)") ~= nil, "the module's own console command works through the loader")
    -- settings through the loader: the in-game menu
    local page = c.mods.store["SMM:schema:G1R Lock picking"]
    check(c.mods.store["SMM:index"] == "G1R Lock picking" and type(page) == "string" and has(page, "Connections taken away") and has(page, "Put the game's own values back now"), "the page G1R Lock picking is registered with the in-game menu")
    c.mods.store["SMM:cmd:G1R Lock picking"] = "4\31n1"            -- the fourth item of the page: Master -> as the game has it
    c.looks(2)
    check(printed(ue, "[G1R_Locks] settings changed (in-game menu): connections taken away game / safe / game (untrained / skilled / master)") ~= nil and w.precision() == 2,
        "an edit in the in-game menu reaches the module through the loader's loop: the master's number is put back at the module's next look")
    check(has(T.read(root .. "/modules/locks/Scripts/config.lua"), 'Config.MasterConnections = "as the game has it"\n'), "and is written into the module's config.lua")
    shutdown(c)

    -- the other author's mod is installed and enabled next to the megamod: the module is not loaded
    T.sh("mkdir -p " .. T.q(TMP .. "/mega/SkillfulLocks/Scripts"))
    T.write(TMP .. "/mega/SkillfulLocks/Scripts/main.lua", "-- (another author's mod)\n")
    T.write(TMP .. "/mega/SkillfulLocks/enabled.txt", "")
    T.write(root .. "/modules/locks/Scripts/config.lua", SETTINGS)
    c = boot()
    check(c.ok and has(last(c), "locks left to the separate mod SkillfulLocks") and printed(c.ue, "module locks not loaded: the separate mod SkillfulLocks is installed and enabled") ~= nil,
        "SkillfulLocks enabled next to the megamod: " .. last(c))
    c.looks(40)
    lock = c.world.startLock(LOCKS.AM_Chest_04_Lock)
    c.looks(4)
    check(lock.precision == 2 and c.world.precision() == 2 and c.mods.store["SMM:index"] == nil and sum(c.world.asked) == 0 and c.world.called("HasGameplayTag") == 0 and (c.ue.calls.RegisterHook or 0) == 0,
        "nothing is changed, read, asked or hooked through this module; no page is registered with the in-game menu")
    shutdown(c)
    os.remove(TMP .. "/mega/SkillfulLocks/enabled.txt")
    c = boot()
    check(has(last(c), "locks ok"), "the same folder without enabled.txt and without a line in mods.txt: the module is loaded")
    shutdown(c)
    T.write(TMP .. "/mega/mods.txt", "SkillfulLocks : 1\r\n")
    c = boot()
    check(has(last(c), "locks left to the separate mod SkillfulLocks"), "enabled through mods.txt (as on the player's PC): not loaded")
    shutdown(c)
    os.remove(TMP .. "/mega/mods.txt")
    T.sh("rm -rf " .. T.q(TMP .. "/mega/SkillfulLocks"))

    -- switched off in the megamod's own settings
    T.write(root .. "/Scripts/config.lua", T.config("Config.Modules = { Locks = false }"))
    c = boot()
    c.looks(8)
    check(has(table.concat(c.ue.printed), "locks off") and c.world.precision() == 2 and sum(c.world.asked) == 0, "Config.Modules.Locks = false: the module is not loaded")
    shutdown(c)

    -- diagnostics off: the module runs as on its own
    T.write(root .. "/Scripts/config.lua", T.config('Config.Diagnostics = { Level = "off" }'))
    T.write(root .. "/modules/locks/Scripts/config.lua", SETTINGS)
    c = boot()
    c.looks(2)
    lock = c.world.startLock(LOCKS.AM_Chest_04_Lock)
    c.looks(1)
    check(printed(c.ue, "locks ok | diagnostics off") ~= nil and lock.precision == 99 and c.ui.note() == "Lock picking (master): all connections taken away" and #c.ue.errors == 0,
        "diagnostics off: the lock is changed, the note shown, no error")
    shutdown(c)

    -- a loader without its kit: the module says what it needs
    os.remove(root .. "/Scripts/core/kit.lua")
    c = boot()
    check(c.ok and printed(c.ue, "[G1R_MegaMod] core/kit.lua could not be used") ~= nil
        and printed(c.ue, "[G1R_Locks] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started") ~= nil,
        "core/kit.lua missing: the loader says so, the module says what it needs and does not start")
    check(has(last(c), "locks ok") and not has(table.concat(c.ue.printed), "failed to load"), "that is not an error of the module: " .. last(c))
    c.looks(8)
    check(c.world.precision() == 2 and #c.ue.errors == 0, "and nothing is changed, no error")
    shutdown(c)
end

-- ---------------------------------------------------------------------------
section("21. many things at random: every lock stays solvable, nothing is written during a lock, switching off puts everything back")
do
    -- A long random walk through what a player can do - learn a level, change any setting in the in-game menu,
    -- open chests (locked or not) and doors, break picks, give up, save and load (with and without the game
    -- writing its own numbers afterwards), switch the module off and on - with three things checked all the way:
    --   1. every lock is set up with a number of connections for which the test data has a way to open it;
    --   2. while a lock is being picked neither of the two attributes changes;
    --   3. whenever the module is switched off and no lock is being picked, a quarter second later both
    --      attributes hold the game's own numbers for the hero's level.
    -- One thing the walk does not do, because the game cannot: start a lock in the same quarter second in which
    -- another lock ended or a chest was opened (the hero walks, and an animation plays, in between).
    local CHOICES = { "as the game has it", "none", "1", "2", "half", "safe", "all" }
    local LEVEL_KEYS = { "untrained", "skilled", "master" }
    local LABELS = { untrained = "Untrained", skilled = "Skilled", master = "Master" }
    local chests, doors, hard = {}, {}, {}        -- hard: chests whose lock is not proven for all its connections
    local proven = dofile(MOD .. "modules/locks/Scripts/lockdata.lua")
    for _, entry in ipairs(GAMELOCKS) do
        if entry.used == "chest" then
            chests[#chests + 1] = entry.name
            if proven[entry.name][2] < proven[entry.name][1] then hard[#hard + 1] = entry.name end
        elseif entry.used == "door" then
            doors[#doors + 1] = entry.name
        end
    end
    local seed = 20261002
    local function random(n)            -- 1 .. n (a generator of its own: the same walk on every machine)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return (seed >> 8) % n + 1
    end
    local c = start("random", { config = config(""), game = { level = "untrained" } })
    local ue, w = c.ue, c.world
    local problems, locksPlayed, setUps, changedLocks, loads, broken, kinds = {}, 0, 0, 0, 0, 0, {}
    local function problem(text) if #problems < 5 then problems[#problems + 1] = text end end
    local function own(name) return LEVELS[w.hero.level][name] end
    local function settled(where)
        if c.hook.settings.values.Enabled == false and (w.lock == nil or w.lock.over) then
            if w.precision() ~= own("precision") or w.durability() ~= own("durability") then
                problem(("%s: switched off, but the hero has %s / %s at level %s"):format(where, w.precision(), w.durability(), w.hero.level))
            end
        end
    end
    local function ticks(n)
        for _ = 1, n do
            local lock = w.lock
            local before = lock and not lock.over and { w.precision(), w.durability() } or nil
            c.ticks(1)
            if before and not lock.over and (w.precision() ~= before[1] or w.durability() ~= before[2]) then
                problem(("a number changed during a lock: %s / %s -> %s / %s"):format(before[1], before[2], w.precision(), w.durability()))
            end
        end
    end
    local function checkSetUp(name, lock, kind)
        setUps = setUps + 1
        local def = BYNAME[name]
        local removed = math.min(lock.precision, #def.connections)
        if type(def.ways[removed]) ~= "string" then
            problem(("%s %s was set up with %d of %d connections taken away at level %s: no way to open it is known"):format(kind, name, removed, #def.connections, w.hero.level))
        end
        if lock.precision ~= own("precision") then changedLocks = changedLocks + 1 end
        if lock.durability < 1 then problem(("%s %s: a pick with %d wrong moves"):format(kind, name, lock.durability)) end
    end
    local function play(name, lock, kind)
        locksPlayed = locksPlayed + 1
        checkSetUp(name, lock, kind)
        local how = random(4)
        ticks(random(3))
        if how == 1 then
            -- a setting changes in the middle of the lock
            T.menuSet(c, "Lock picking", LABELS[w.hero.level], random(#CHOICES))
            ticks(2)
        elseif how == 2 then
            -- picks break: the lock is set up again where it stands, with the same numbers
            lock.picks = 2
            local first = { lock.precision, lock.durability }
            local guard = 0
            while lock.setUps < 2 and not lock.over and guard < 400 do      -- (piece 0 is pushed up until it cannot move, and on)
                guard = guard + 1
                lock.move(0, 1)
            end
            if lock.setUps >= 2 then broken = broken + 1 end
            if lock.setUps >= 2 and (lock.precision ~= first[1] or lock.durability ~= first[2]) then
                problem(("%s %s: set up again with other numbers after a broken pick"):format(kind, name))
            end
            ticks(1)
        elseif how == 3 then
            -- opened by the way the test data has
            local def = BYNAME[name]
            local way = def.ways[math.min(lock.precision, #def.connections)]
            if type(way) == "string" then
                local result = nil
                for piece, sign in way:gmatch("(%d)([+-])") do result = lock.move(tonumber(piece), sign == "+" and 1 or -1) end
                if #way > 0 and result ~= "open" then problem(("%s %s: the known way did not open it (%s)"):format(kind, name, tostring(result))) end
            end
        end
        lock.leave()
        ticks(1 + random(2))            -- (the hero needs longer than this from one lock to the next)
    end
    for step = 1, 700 do
        local what = random(100)
        local kind
        if what <= 30 then
            kind = "chest"
            local name = random(2) == 1 and hard[random(#hard)] or chests[random(#chests)]
            local lock = w.openChest(name, random(5) ~= 1)
            if lock then play(name, lock, "the chest") else ticks(1 + random(2)) end
        elseif what <= 42 then
            kind = "door"
            local name = doors[random(#doors)]
            play(name, w.openDoor(name), "the door")
        elseif what <= 62 then
            kind = "choice"
            T.menuSet(c, "Lock picking", LABELS[LEVEL_KEYS[random(3)]], random(#CHOICES))
            ticks(random(2))
        elseif what <= 70 then
            kind = "moves"
            T.menuSet(c, "Lock picking", LABELS[LEVEL_KEYS[random(3)]] .. ": wrong moves", ({ 0, 0, 1, 3, 99 })[random(5)])
            T.menuSet(c, "Lock picking", "Lock picks do not break", random(4) == 1)
            ticks(random(2))
        elseif what <= 78 then
            kind = "level"
            w.level(LEVEL_KEYS[random(3)], nil, random(2) == 1)
            ticks(1)
            w.frame()
            ticks(1 + random(2))
        elseif what <= 86 then
            kind = "switch"
            T.menuSet(c, "Lock picking", "Lock picking by skill", random(2) == 1)
            ticks(2)
            settled("step " .. step)
        elseif what <= 92 then
            kind = "load"
            loads = loads + 1
            w.load(w.save(), random(2) == 1)
            ticks(1 + random(2))
        else
            kind = "wait"
            ticks(random(8))
        end
        kinds[kind] = (kinds[kind] or 0) + 1
        if printed(ue, "update error") or printed(ue, "error in the chest hook") or #ue.errors > 0 then
            problem("an error at step " .. step .. ": " .. tostring(printed(ue, "update error") or printed(ue, "error in the chest hook") or ue.errors[1]))
            break
        end
    end
    check(#problems == 0, ("700 random steps (%d locks, %d of them set up with another number than the game's, %d with a broken pick and a second set-up; %d loads): no problem (%s)"):format(
        locksPlayed, changedLocks, broken, loads, table.concat(problems, "; ")))
    check(locksPlayed > 150 and setUps == locksPlayed and changedLocks > 40 and broken > 20 and loads > 20 and (kinds.switch or 0) > 30,
        "(the walk did all of it: locks, changed locks, broken picks, loads, switching off and on)")
    -- at the end: switched off, everything back, at rest
    if w.lock and not w.lock.over then w.lock.leave() end
    T.menuSet(c, "Lock picking", "Lock picking by skill", false)
    ticks(2)
    check(w.precision() == own("precision") and w.durability() == own("durability") and c.S.awake == false and ue.calls.RegisterHook <= 1 and (ue.calls.NotifyOnNewObject or 0) == 0,
        "switched off at the end: the game's own numbers, the module at rest; one hook registration at most in the whole walk")
    stop(c)
end

T.finish()
