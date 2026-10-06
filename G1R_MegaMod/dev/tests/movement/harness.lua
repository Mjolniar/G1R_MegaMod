-- ============================================================================
-- Offline tests of the module movement (modules/movement/Scripts/main.lua).
--
--   lua5.4 harness.lua          (from any directory)
--
-- The module runs on the loader's kit and settings service; ../lib/modtest.lua
-- sets both up the way the loader does and replaces UE4SS by ../mock/ue4ss.lua.
-- The game is the model below: the default object of the script class
-- LocomotionSpeedSettings_Swim_Laying_Player with its map of swimming speeds
-- (dev/facts/movement.md MV1, entries with :get() and :set() as in melee M11),
-- the game's lookup of a character by its unique name (MV4, mount M2) and the
-- scavenger's state with its movement attributes (MV3). Nothing of it has
-- been seen in the game for this module.
-- Last line: "movement tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*/)") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("movement")
local check, section, has, printed, printedCount = T.check, T.section, T.has, T.printed, T.printedCount
local MOD = HERE .. "../../../"
local NL = string.char(10)

local SWIM = "/Script/Angelscript.Default__LocomotionSpeedSettings_Swim_Laying_Player"
local NPC_CDO = "/Script/G1R.Default__GothicNPCState"

-- ---------------------------------------------------------------------------
-- The game model
-- ---------------------------------------------------------------------------
-- options: noSwimClass, noSwimTable, swimRaises, swimText, swimNoKeep (the table does not keep a written value),
--          emptyTable, noLookup, lookupRaises, noMount, noSet, speedNoKeep (the attribute does not keep a written
--          value), speedMissing (no SpeedModifier), noController. While a case runs: world.swimRaises,
--          world.setRaises, world.breakAfterSet (the table cannot be walked after a write), world.lookupRaises.
local function newWorld(ue, o)
    o = o or {}
    local world = T.newWorld(ue, { noController = o.noController })
    world.calls = {}
    local function called(name) world.calls[name] = (world.calls[name] or 0) + 1 end
    -- the swimming speeds: a map on the class's default object (MV1)
    world.swim = o.emptyTable and {} or { { k = 0, v = 100 }, { k = 1, v = 150 }, { k = 2, v = 220 } }
    local map = {
        ForEach = function(self, f)
            called("swim:ForEach")
            if o.swimRaises or world.swimRaises then error("ForEach failed") end
            for _, e in ipairs(world.swim) do
                f({ get = function() return e.k end },
                  { get = function() if o.swimText then return "fast" end return e.v end,
                    set = function(_, x)
                        called("swim:set")
                        if world.setRaises then error("set failed") end
                        if not o.swimNoKeep then e.v = x end
                        if world.breakAfterSet then world.swimRaises = true end
                    end })
            end
        end,
    }
    if not o.noSwimClass then
        ue.objects[SWIM] = ue:object("LocomotionSpeedSettings_Swim_Laying_Player " .. SWIM, { m_Speeds = (not o.noSwimTable) and map or nil })
    end
    -- the scavenger: its state, its movement attributes (MV3)
    local m = {}
    local function newSet(id)
        local speed = { BaseValue = 1.0, CurrentValue = 1.0 }
        if o.speedNoKeep then speed = setmetatable({}, { __index = function(_, k) if k == "BaseValue" or k == "CurrentValue" then return 1.0 end end, __newindex = function() end }) end
        m.speed = speed
        return ue:object(("AttributeSet_Movement /Game/Maps/World.World:PersistentLevel.GothicNPCState_77.AttributeSet_Movement_%d"):format(id),
            { SpeedModifier = (not o.speedMissing) and speed or nil })
    end
    m.newSet = newSet
    m.set = newSet(3)
    m.list = T.array(o.noSet and {} or { m.set })
    m.component = ue:object("GothicAbilitySystemComponent /Game/Maps/World.World:PersistentLevel.GothicNPCState_77.AbilitySystemComponent",
        { SpawnedAttributes = m.list })
    m.state = ue:object("GothicNPCState /Game/Maps/World.World:PersistentLevel.GothicNPCState_77", { AbilitySystemComponent = m.component })
    world.mount = m
    -- the hero: his movement attributes beside the others of his state (MV6)
    local h = {}
    function h.newSet(id)
        local speed = { BaseValue = 1.0, CurrentValue = 1.0 }
        h.speed = speed
        return ue:object(("AttributeSet_Movement /Game/Maps/World.World:PersistentLevel.GothicPlayerState_5.AttributeSet_Movement_%d"):format(id),
            { SpeedModifier = speed })
    end
    h.set = h.newSet(31)
    h.items = world.hero.component.SpawnedAttributes.items
    if not o.noHeroSet then h.items[#h.items + 1] = h.set end
    function h.replace(set)
        for i, x in ipairs(h.items) do if x == h.set then h.items[i] = set end end
        h.set = set
    end
    world.heroMove = h
    -- the game's lookup by unique name (MV4)
    if not o.noLookup then
        ue.objects[NPC_CDO] = ue:object("GothicNPCState " .. NPC_CDO, {
            FindNPCByUniqueName = function(self, ctx, name)
                called("FindNPCByUniqueName")
                if o.lookupRaises or world.lookupRaises then error("bad context") end
                world.lookedUp = { ctx = ctx, name = name and name.__s }
                if o.noMount then return ue:object("None", { __valid = false }) end
                return m.state
            end,
        })
    end
    return world
end

local function boot(case, o, config)
    o = o or {}
    return T.boot(case, { module = "movement", hook = "MOVEMENT_TEST", config = config, diag = o.diag ~= false, widgets = true,
        prepare = function(ue) return newWorld(ue, o) end })
end
local function speeds(c)
    local t = {}
    for _, e in ipairs(c.world.swim) do t[#t + 1] = ("%g"):format(e.v) end
    return table.concat(t, "/")
end
local function speed(c) return c.world.mount.speed.BaseValue, c.world.mount.speed.CurrentValue end
local function heroSpeed(c) return c.world.heroMove.speed.BaseValue, c.world.heroMove.speed.CurrentValue end
local function close(a, b) return math.abs(a - b) < 1e-6 end
local function calls(c, name) return c.world.calls[name] or 0 end
local function lookups(c, path)
    local n = 0
    for _, p in ipairs(c.ue.lookups) do if p == path then n = n + 1 end end
    return n
end
local function cfg(lines) return T.config(table.concat(lines, NL)) end
local function status(c) return table.concat(c.hook.status(), " | ") end

-- ================================================================ load
section("load: the shipped settings leave the game alone")
do
    local c = boot("load")
    check(c.ok, "the module loads (" .. tostring(c.err) .. ")")
    check(printed(c.ue, "[G1R_Movement] v1.1.0 loaded: walking, swimming and riding as the game has them") ~= nil, "load line: " .. tostring(printed(c.ue, "loaded:")))
    check(c.ue.console.movement ~= nil and c.ue.console.g1r_movement ~= nil, "console words movement / g1r_movement registered")
    check(#c.ue.loops == 2, "its loop and the loader's (" .. #c.ue.loops .. ")")
    c.seconds(20)
    check(T.searches(c) == 0 and calls(c, "swim:ForEach") == 0 and calls(c, "FindNPCByUniqueName") == 0 and speeds(c) == "100/150/220" and speed(c) == 1.0,
        "with every multiplier at 1.00 the game is not looked at: nothing searched, nothing read, nothing changed")
    T.stop(c)
end

-- ================================================================ swimming
section("swimming: the game's three speeds times the multiplier, put back at 1.00")
do
    local c = boot("swim", {}, cfg({ "Config.SwimSpeed = 1.5" }))
    check(printed(c.ue, "loaded: on foot x1.00, swimming x1.50, your scavenger x1.00") ~= nil, "load line names the multipliers")
    c.ticks(1)
    check(speeds(c) == "150/225/330", "at the first look: 100 / 150 / 220 -> 150 / 225 / 330 (" .. speeds(c) .. ")")
    check(c.fake.value("movement.swim_table") == "found" and c.fake.detail("movement.swim_table") == "100 / 150 / 220" and c.fake.value("movement.swim_write") == "works",
        "noted: the table found (with the game's speeds), the write works")
    check(printed(c.ue, "swimming speeds 100") == nil, "the change is not logged (LogChanges is off)")
    local sets, walks = calls(c, "swim:set"), calls(c, "swim:ForEach")
    c.seconds(20)
    check(speeds(c) == "150/225/330" and calls(c, "swim:set") == sets and calls(c, "swim:ForEach") - walks == 10,
        "20 s later: not written twice; one walk through the table per look, a look every 2 s (" .. (calls(c, "swim:ForEach") - walks) .. ")")
    check(lookups(c, SWIM) == 1, "the class's default object is looked up once")
    check(status(c) == "v1.1.0 | on foot x1.00, swimming x1.50, your scavenger x1.00 | swimming speeds of the game: 100 / 150 / 220, now 150 / 225 / 330 | speeds changed: 1; put back: 0",
        "status: " .. status(c))
    check(calls(c, "FindNPCByUniqueName") == 0, "the scavenger is not looked up while its multiplier is 1.00")
    T.menuSet(c, "Movement", "Swimming (times)", 1.0)
    c.ticks(8)
    check(speeds(c) == "100/150/220" and c.hook.state.swim.applied == nil and has(status(c), "put back: 1"), "back to 1.00 in the in-game menu: the game's own speeds are put back")
    walks = calls(c, "swim:ForEach")
    c.seconds(20)
    check(calls(c, "swim:ForEach") == walks, "then the table is not looked at any more")
    T.stop(c)
end
do
    local c = boot("swim-off", {}, cfg({ "Config.SwimSpeed = 2.0" }))
    c.ticks(1)
    check(speeds(c) == "200/300/440", "x2.00: 200 / 300 / 440")
    T.write(c.path, cfg({ "Config.SwimSpeed = 2.0", "Config.Enabled = false" }))
    c.ticks(24)
    check(printed(c.ue, "settings changed (config.lua): switched off") ~= nil and speeds(c) == "100/150/220", "switched off in config.lua: said, and the game's speeds are back")
    T.stop(c)
end
do
    local c = boot("swim-ends", {}, cfg({ "Config.SwimSpeed = 0.5", "Config.LogChanges = true" }))
    c.ticks(1)
    check(speeds(c) == "50/75/110" and printed(c.ue, "swimming speeds 100 / 150 / 220 -> 50 / 75 / 110") ~= nil, "x0.50 (the lowest): 50 / 75 / 110, logged with LogChanges")
    T.menuSet(c, "Movement", "Swimming (times)", 3.0)
    c.ticks(8)
    check(speeds(c) == "300/450/660" and printed(c.ue, "swimming speeds 50 / 75 / 110 -> 300 / 450 / 660") ~= nil, "x3.00 (the highest): from the game's own values, not from the last ones")
    T.stop(c)
end

-- ================================================================ the scavenger
section("the scavenger: its own speed factor times the multiplier")
do
    local c = boot("mount", {}, cfg({ "Config.MountSpeed = 1.25" }))
    c.ticks(1)
    local base, current = speed(c)
    check(base == 1.25 and current == 1.25, "1.00 -> 1.25, base and current value (" .. tostring(base) .. " / " .. tostring(current) .. ")")
    check(c.world.lookedUp and c.world.lookedUp.name == "Scavenger_Adult_Rideable" and c.world.lookedUp.ctx == c.world.controller,
        "found by its unique name, with the player controller as context")
    check(c.fake.value("movement.lookup") == "works" and c.fake.value("movement.mount_set") == "found" and c.fake.detail("movement.mount_set") == "1.00"
        and c.fake.value("movement.mount_write") == "works", "noted: lookup, its attributes (with its own factor), the write")
    check(calls(c, "swim:ForEach") == 0, "the swimming table is not looked at (its multiplier is 1.00)")
    check(status(c) == "v1.1.0 | on foot x1.00, swimming x1.00, your scavenger x1.25 | the scavenger's own speed factor: 1.00, now 1.25 | speeds changed: 1; put back: 0", "status: " .. status(c))
    -- the game sets its own value again (the attributes made anew in place): the multiplier again
    c.world.mount.speed.BaseValue, c.world.mount.speed.CurrentValue = 1.0, 1.0
    c.seconds(2)
    check(speed(c) == 1.25 and not c.hook.state.mount.left, "the game's own value back in place: written again")
    -- a summon: the scavenger comes with new attributes that carry the module's value over
    local writes = c.fake.count["movement.mount_write"]
    c.world.mount.list.items[1] = c.world.mount.newSet(8)
    c.world.mount.speed.BaseValue, c.world.mount.speed.CurrentValue = 1.25, 1.25
    c.seconds(2)
    c.world.mount.list.items[1] = c.world.mount.newSet(10)
    c.world.mount.speed.BaseValue, c.world.mount.speed.CurrentValue = 1.25, 1.25
    c.seconds(2)
    check(speed(c) == 1.25 and c.hook.state.mount.applied == 1.25 and not c.hook.state.mount.left,
        "a summon (new attributes that carry the 1.25 over), twice: still 1.25 - not multiplied again (version 1.0.0 made it 1.56, then 1.95, ...)")
    -- a save from version 1.0.0 that kept such a value
    c.world.mount.list.items[1] = c.world.mount.newSet(11)
    c.world.mount.speed.BaseValue, c.world.mount.speed.CurrentValue = 1.5625, 1.5625
    c.seconds(2)
    check(speed(c) == 1.25, "new attributes with the 1.56 of two summons under version 1.0.0: back to the game's 1.0 x 1.25")
    -- another set of attributes with another value (a loaded save): the game's 1.0 times the multiplier
    local fresh = c.world.mount.newSet(9)
    c.world.mount.list.items[1] = fresh
    c.world.mount.speed.BaseValue, c.world.mount.speed.CurrentValue = 0.9, 0.9
    c.seconds(2)
    check(speed(c) == 1.25 and c.hook.state.mount.own == 1.0, "a new set of attributes with 0.90: the game's own 1.0 times 1.25 (the character definition gives 1.0)")
    T.menuSet(c, "Movement", "Your scavenger", 1.0)
    c.ticks(8)
    check(speed(c) == 1.0 and c.hook.state.mount.applied == nil, "back to 1.00: the game's own 1.0 is put back")
    T.stop(c)
end
do
    local c = boot("mount-away", { noMount = true }, cfg({ "Config.MountSpeed = 1.5" }))
    c.seconds(10)
    check(calls(c, "FindNPCByUniqueName") == 5 and #c.ue.errors == 0 and speed(c) == 1.0 and not c.hook.state.mount.off,
        "no scavenger in the world (not yours yet): asked again at every look, nothing done, nothing given up")
    T.stop(c)
end

-- ================================================================ the hero on foot
section("the hero on foot: his own speed factor times the multiplier")
do
    local c = boot("hero", {}, cfg({ "Config.HeroSpeed = 1.2" }))
    check(printed(c.ue, "loaded: on foot x1.20, swimming x1.00, your scavenger x1.00") ~= nil, "load line names it")
    c.ticks(1)
    local base, current = heroSpeed(c)
    check(close(base, 1.2) and close(current, 1.2), "1.00 -> 1.20, base and current value (" .. tostring(base) .. ")")
    check(c.fake.value("movement.hero_set") == "found" and c.fake.detail("movement.hero_set") == "1.00" and c.fake.value("movement.hero_write") == "works",
        "noted: his attributes (with his own factor), the write")
    check(calls(c, "FindNPCByUniqueName") == 0 and calls(c, "swim:ForEach") == 0 and speed(c) == 1.0, "the scavenger and the swimming table are left alone (their multipliers are 1.00)")
    check(status(c) == "v1.1.0 | on foot x1.20, swimming x1.00, your scavenger x1.00 | the hero's own speed factor: 1.00, now 1.20 | speeds changed: 1; put back: 0", "status: " .. status(c))
    -- new attributes that carry the value over (a loaded save, another map): not multiplied again
    c.world.heroMove.replace(c.world.heroMove.newSet(32))
    c.world.heroMove.speed.BaseValue, c.world.heroMove.speed.CurrentValue = 1.2, 1.2
    c.seconds(2)
    check(close(heroSpeed(c), 1.2) and c.hook.state.hero.applied == 1.2, "new attributes that carry 1.20 over: still 1.20")
    -- the game sets its own value again
    c.world.heroMove.speed.BaseValue, c.world.heroMove.speed.CurrentValue = 1.0, 1.0
    c.seconds(2)
    check(close(heroSpeed(c), 1.2), "the game's own 1.0 back in place: written again")
    -- something else sets another value: left alone
    c.world.heroMove.speed.BaseValue, c.world.heroMove.speed.CurrentValue = 0.8, 0.8
    c.seconds(4)
    check(close(heroSpeed(c), 0.8) and printedCount(c.ue, "the hero's speed factor was changed by something else (0.80); left as it is") == 1
        and c.fake.value("movement.left_alone") == "hero", "another value: left alone, said once")
    check(status(c) == "v1.1.0 | on foot x1.20, swimming x1.00, your scavenger x1.00 | the hero's own speed factor: 1.00, now 1.20 | speeds changed: 2; put back: 0"
        .. " | the hero's speed factor was changed by something else: left as it is", "the status names it: " .. status(c))
    T.menuSet(c, "Movement", "Hero on foot", 1.0)
    c.ticks(8)
    check(close(heroSpeed(c), 1.0) and c.hook.state.hero.applied == nil, "back to 1.00: the game's own 1.0")
    local reads = c.fake.count["movement.hero_set"] or 0
    T.stop(c)
end
do
    local c = boot("hero-nostate", { noController = true }, cfg({ "Config.HeroSpeed = 1.5" }))
    c.seconds(6)
    check(close(heroSpeed(c), 1.0) and not c.hook.state.hero.off and #c.ue.errors == 0, "no hero yet: nothing done, nothing given up")
    T.stop(c)
end
do
    local c = boot("hero-noset", { noHeroSet = true }, cfg({ "Config.HeroSpeed = 1.5" }))
    c.ticks(1)
    check(c.fake.value("movement.hero_set") == "not found", "no movement attributes on the hero: noted at the first look")
    c.seconds(2)
    check(not c.hook.state.hero.off, "two looks: not given up yet")
    c.seconds(2)
    check(c.hook.state.hero.off and printedCount(c.ue, "the hero's movement attributes were not found") == 1, "the third: given up, said once")
    check(status(c) == "v1.1.0 | on foot x1.50, swimming x1.00, your scavenger x1.00 | speeds changed: 0; put back: 0 | the hero on foot: given up for this run",
        "the status names it: " .. status(c))
    T.stop(c)
end
do
    local c = boot("hero-dump", {}, cfg({ "Config.HeroSpeed = 0.5" }))
    c.ticks(1)
    local d = c.fake.dump[1]()
    check(close(heroSpeed(c), 0.5) and d.hero_speed == 0.5 and d.hero_own == 1.0 and d.hero_applied == 0.5 and d.hero_left == false and d.hero_off == false,
        "x0.50 (the lowest); the dump holds the hero's part")
    T.stop(c)
end

-- ================================================================ somebody else changed it
section("a value somebody else set is left alone, and taken as the game's own at the next change of the setting")
do
    local c = boot("left", {}, cfg({ "Config.SwimSpeed = 1.5" }))
    c.ticks(1)
    c.world.swim[2].v = 999
    c.seconds(10)
    check(speeds(c) == "150/999/330" and printedCount(c.ue, "the swimming speeds were changed by something else (150 / 999 / 330); left as they are") == 1
        and c.fake.value("movement.left_alone") == "swimming", "another value in the table: left as it is, said once, noted")
    check(status(c) == "v1.1.0 | on foot x1.00, swimming x1.50, your scavenger x1.00 | swimming speeds of the game: 100 / 150 / 220, now 150 / 225 / 330 | speeds changed: 1; put back: 0"
        .. " | the swimming speeds were changed by something else: left as they are", "status names it: " .. status(c))
    T.menuSet(c, "Movement", "Swimming (times)", 2.0)
    c.ticks(8)
    check(speeds(c) == "300/1998/660" and not c.hook.state.swim.left and not has(status(c), "left as they are"),
        "the next change of the setting takes what is there as the game's own (150 / 999 / 330 x2)")
    c.world.swim[2].v = 777
    c.seconds(2)
    check(speeds(c) == "300/777/660", "after that a new value from somebody else is left alone again (not taken as the game's own)")
    T.stop(c)
end
do
    local c = boot("left-back", {}, cfg({ "Config.SwimSpeed = 1.5" }))
    c.ticks(1)
    for i, v in ipairs({ 100, 150, 220 }) do c.world.swim[i].v = v end
    c.seconds(2)
    check(speeds(c) == "150/225/330" and not c.hook.state.swim.left, "the game's own speeds back in the table: multiplied again, not left alone")
    T.stop(c)
end
do
    local c = boot("mount-left", {}, cfg({ "Config.MountSpeed = 1.5" }))
    c.ticks(1)
    c.world.mount.speed.BaseValue, c.world.mount.speed.CurrentValue = 0.7, 0.7
    c.seconds(10)
    check(speed(c) == 0.7 and printedCount(c.ue, "the scavenger's speed factor was changed by something else (0.70); left as it is") == 1
        and c.fake.value("movement.left_alone") == "scavenger", "the scavenger's factor set by something else: left alone, said once")
    check(status(c) == "v1.1.0 | on foot x1.00, swimming x1.00, your scavenger x1.50 | the scavenger's own speed factor: 1.00, now 1.50 | speeds changed: 1; put back: 0"
        .. " | the scavenger's speed factor was changed by something else: left as it is", "status names it: " .. status(c))
    T.menuSet(c, "Movement", "Your scavenger", 2.0)
    c.ticks(8)
    check(speed(c) == 2.0 and not has(status(c), "left as it is"), "the next change of the setting takes over again: the game's 1.0 x 2 = 2.00")
    c.world.mount.speed.BaseValue, c.world.mount.speed.CurrentValue = 0.5, 0.5
    c.seconds(2)
    check(speed(c) == 0.5, "after that a new value from somebody else is left alone again")
    T.stop(c)
end

-- ================================================================ map load
section("a map load: nothing while it loads")
do
    local c = boot("load-map", {}, cfg({ "Config.SwimSpeed = 1.5" }))
    c.ticks(1)
    c.ue:fireLoadMapPre("engine", "world", "url", nil, "")
    for i, v in ipairs({ 100, 150, 220 }) do c.world.swim[i].v = v end
    local walks = calls(c, "swim:ForEach")
    c.seconds(4)
    check(calls(c, "swim:ForEach") == walks and speeds(c) == "100/150/220", "while the map loads the game is not looked at")
    c.ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(2)
    check(speeds(c) == "150/225/330", "after the load: looked at at once, the multiplier is there again")
    T.stop(c)
end

-- ================================================================ what is missing or fails
section("what is missing or fails: said once, given up after three tries, the other part goes on")
do
    local c = boot("no-class", { noSwimClass = true }, cfg({ "Config.SwimSpeed = 1.5", "Config.MountSpeed = 1.25" }))
    c.ticks(1)
    check(c.fake.value("movement.swim_table") == "not found", "no such class: noted as not found at the first look")
    c.seconds(10)
    check(c.fake.value("movement.swim_table") == "fails" and has(c.fake.detail("movement.swim_table"), "was not found") and c.hook.state.swim.off
        and printedCount(c.ue, "the swimming speeds of the game cannot be read") == 1 and lookups(c, SWIM) == 1, "given up after three looks, said once, searched once")
    check(status(c) == "v1.1.0 | on foot x1.00, swimming x1.50, your scavenger x1.25 | the scavenger's own speed factor: 1.00, now 1.25 | speeds changed: 1; put back: 0 | swimming: given up for this run",
        "status: " .. status(c))
    check(speed(c) == 1.25, "the scavenger's part goes on")
    T.stop(c)
end
for _, case in ipairs({ { "raises", { swimRaises = true }, "ForEach failed", "not readable" }, { "text", { swimText = true }, "an entry is not a number", "not readable" },
                        { "no-table", { noSwimTable = true }, "m_Speeds cannot be read", "not found" } }) do
    local c = boot("swim-" .. case[1], case[2], cfg({ "Config.SwimSpeed = 1.5" }))
    c.ticks(1)
    check(c.fake.value("movement.swim_table") == case[4], "the table: " .. case[3] .. " - noted as " .. case[4] .. " at the first look")
    c.seconds(10)
    check(c.hook.state.swim.off and has(c.fake.detail("movement.swim_table"), case[3]) and #c.ue.errors == 0 and speeds(c) == "100/150/220",
        "the table: " .. case[3] .. " - given up, the game's speeds untouched, no error out")
    T.stop(c)
end
do
    local c = boot("swim-no-keep", { swimNoKeep = true }, cfg({ "Config.SwimSpeed = 1.5" }))
    c.seconds(10)
    check(c.fake.value("movement.swim_write") == "fails" and c.fake.detail("movement.swim_write") == "the table did not keep the new values"
        and c.hook.state.swim.off and calls(c, "swim:set") == 9 and printedCount(c.ue, "the swimming speeds cannot be written") == 1,
        "a table that does not keep what is written: three tries, then given up, said once")
    T.stop(c)
end
do
    local c = boot("no-lookup", { noLookup = true }, cfg({ "Config.SwimSpeed = 1.5", "Config.MountSpeed = 1.25" }))
    c.seconds(10)
    check(c.fake.value("movement.lookup") == "not available" and c.hook.state.lookupOff and lookups(c, NPC_CDO) == 1
        and printedCount(c.ue, "the game's lookup of characters by name was not found") == 1 and speeds(c) == "150/225/330"
        and c.fake.detail("movement.lookup") == "GothicNPCState default object not found", "no lookup by name: noted, said once, searched once; swimming goes on")
    check(status(c) == "v1.1.0 | on foot x1.00, swimming x1.50, your scavenger x1.25 | swimming speeds of the game: 100 / 150 / 220, now 150 / 225 / 330 | speeds changed: 1; put back: 0"
        .. " | the scavenger cannot be looked up in this run", "status: " .. status(c))
    T.stop(c)
end
do
    local c = boot("lookup-raises", { lookupRaises = true }, cfg({ "Config.MountSpeed = 1.25" }))
    c.seconds(10)
    check(c.fake.value("movement.lookup") == "fails" and calls(c, "FindNPCByUniqueName") == 3 and #c.ue.errors == 0,
        "a lookup that raises: three tries, then given up for the run")
    T.stop(c)
end
do
    local c = boot("no-set", { noSet = true }, cfg({ "Config.MountSpeed = 1.25" }))
    c.ticks(1)
    c.seconds(2)
    check(not c.hook.state.mount.off, "no movement attributes: two looks, not given up yet")
    c.seconds(2)
    check(c.hook.state.mount.off, "the third: given up")
    check(status(c) == "v1.1.0 | on foot x1.00, swimming x1.00, your scavenger x1.25 | speeds changed: 0; put back: 0 | the scavenger: given up for this run", "status: " .. status(c))
    c.seconds(6)
    check(c.fake.value("movement.mount_set") == "fails" and c.hook.state.mount.off and printedCount(c.ue, "the scavenger's movement attributes were not found") == 1,
        "no movement attributes on the scavenger: given up after three looks, said once")
    T.stop(c)
end
do
    local c = boot("speed-no-keep", { speedNoKeep = true }, cfg({ "Config.MountSpeed = 1.25" }))
    c.seconds(10)
    check(c.fake.value("movement.mount_write") == "fails" and c.hook.state.mount.off and speed(c) == 1.0,
        "an attribute that does not keep the written value: given up after three tries")
    T.stop(c)
end

-- ================================================================ diagnostics, console, files
section("diagnostics, console and files")
do
    local c = boot("diag", {}, cfg({ "Config.SwimSpeed = 1.5", "Config.MountSpeed = 1.25" }))
    c.seconds(20)
    local once = true
    for _, k in ipairs({ "movement.swim_table", "movement.swim_write", "movement.lookup", "movement.mount_set", "movement.mount_write" }) do
        if c.fake.count[k] ~= 1 then once = false end
    end
    check(once, "each note made once while its value stays the same")
    local before = calls(c, "swim:ForEach") + calls(c, "FindNPCByUniqueName")
    local lines = c.hook.status()
    check(calls(c, "swim:ForEach") + calls(c, "FindNPCByUniqueName") == before and #lines >= 4 and has(lines[1], "v1.1.0 | on foot x1.00, swimming x1.50, your scavenger x1.25"),
        "the status is built without a call into the game")
    c.ue:fireConsole("movement")
    check(printed(c.ue, "[G1R_Movement] speeds changed: 2; put back: 0") ~= nil, "the console word movement prints the status")
    T.write(c.path, cfg({ "Config.SwimSpeed = 1.25" }))
    c.ue:fireConsole("movement reload")
    check(printed(c.ue, "settings read: on foot x1.00, swimming x1.25, your scavenger x1.00") ~= nil, "movement reload reads config.lua at once")
    c.ticks(2)
    check(speeds(c) == "125/187.5/275" and speed(c) == 1.0, "and the speeds follow: swimming x1.25, the scavenger's own value back")
    local files = {}
    local p = io.popen("ls -A " .. T.q(c.dir))
    for f in p:lines() do files[#files + 1] = f end
    p:close()
    table.sort(files)
    check(table.concat(files, ",") == "config.lua,main.lua,schema.lua", "no file written but config.lua (" .. table.concat(files, ",") .. ")")
    T.stop(c)

    local shipped = T.read(MOD .. "modules/movement/Scripts/config.lua")
    local schema = dofile(MOD .. "modules/movement/Scripts/schema.lua")
    local probe = boot("default-text")
    check(probe.settings.defaultText(schema) == shipped and not shipped:find("[^" .. NL .. "\32-\126]"),
        "the shipped config.lua is exactly what the schema generates (lua5.4 dev/tools/gen_config.lua), plain ASCII")
    T.stop(probe)
end

-- ================================================================ piece by piece
section("failures after a success, the ways not taken yet, the console, the dump")
do
    local c = boot("swim-later", {}, cfg({ "Config.SwimSpeed = 1.5" }))
    c.ticks(1)
    c.seconds(2)
    c.world.swimRaises = true
    c.seconds(4)
    check(not c.hook.state.swim.off, "the table cannot be walked after a success: two looks, not given up yet")
    c.seconds(2)
    check(c.hook.state.swim.off, "the third: given up")
    T.stop(c)
end
do
    local c = boot("mount-later", {}, cfg({ "Config.MountSpeed = 1.25" }))
    c.ticks(1)
    c.seconds(2)
    c.world.mount.list.items = {}
    c.seconds(4)
    check(not c.hook.state.mount.off, "the scavenger's attributes gone after a success: two looks, not given up yet")
    c.seconds(2)
    check(c.hook.state.mount.off, "the third: given up")
    local n = calls(c, "FindNPCByUniqueName")
    c.seconds(10)
    check(calls(c, "FindNPCByUniqueName") == n, "a part given up is not looked at again")
    T.stop(c)
end
do
    local c = boot("lookup-later", {}, cfg({ "Config.MountSpeed = 1.25" }))
    c.ticks(1)
    c.world.lookupRaises = true
    c.seconds(4)
    check(not c.hook.state.lookupOff, "the lookup raising after it worked: two looks, not given up yet")
    c.seconds(2)
    check(c.hook.state.lookupOff, "the third: given up")
    T.stop(c)
end
do
    local c = boot("mount-own-back", {}, cfg({ "Config.MountSpeed = 1.25" }))
    c.ticks(1)
    c.world.mount.speed.BaseValue, c.world.mount.speed.CurrentValue = 1.0, 1.0
    T.menuSet(c, "Movement", "Your scavenger", 1.0)
    c.ticks(8)
    local n = calls(c, "FindNPCByUniqueName")
    c.seconds(10)
    check(c.hook.state.mount.applied == nil and calls(c, "FindNPCByUniqueName") == n and speed(c) == 1.0,
        "its own value back and the setting at 1.00: nothing written, and then not looked at any more")
    T.stop(c)
end
do
    local c = boot("no-hero", { noController = true }, cfg({ "Config.MountSpeed = 1.25" }))
    c.seconds(6)
    check(calls(c, "FindNPCByUniqueName") == 0 and speed(c) == 1.0 and not c.hook.state.lookupOff, "without the hero's controller nothing is looked up, nothing given up")
    T.stop(c)
end
do
    local c = boot("no-fname", {}, cfg({ "Config.MountSpeed = 1.25" }))
    rawset(_G, "FName", nil)
    c.seconds(6)
    check(c.fake.value("movement.lookup") == "not available" and c.fake.detail("movement.lookup") == "no FName" and calls(c, "FindNPCByUniqueName") == 0 and speed(c) == 1.0,
        "without FName: the lookup is not available, nothing is asked, nothing changed")
    T.stop(c)
end
do
    local c = boot("speed-missing", { speedMissing = true }, cfg({ "Config.MountSpeed = 1.25" }))
    c.ticks(1)
    check(c.fake.value("movement.mount_set") == "not readable", "no SpeedModifier: noted as not readable")
    c.seconds(6)
    check(c.hook.state.mount.off, "given up after three looks")
    T.stop(c)
end
do
    local c = boot("swim-empty", { emptyTable = true }, cfg({ "Config.SwimSpeed = 1.5" }))
    c.ticks(1)
    check(c.fake.value("movement.swim_table") == "not readable" and c.fake.detail("movement.swim_table") == "the table is empty", "an empty table: not readable (the table is empty)")
    T.stop(c)
end
do
    local c = boot("swim-grows", {}, cfg({ "Config.SwimSpeed = 1.5" }))
    c.ticks(1)
    c.world.swim[4] = { k = 3, v = 500 }
    c.seconds(2)
    check(c.hook.state.swim.left and speeds(c) == "150/225/330/500", "an entry more than the game's own: left alone")
    T.stop(c)
end
do
    local c = boot("swim-set-raises", {}, cfg({ "Config.SwimSpeed = 1.5" }))
    c.world.setRaises = true
    c.ticks(1)
    check(c.fake.value("movement.swim_write") == "fails" and has(c.fake.detail("movement.swim_write"), "set failed"), "a write that raises: noted, with why")
    T.stop(c)
    c = boot("swim-break", {}, cfg({ "Config.SwimSpeed = 1.5" }))
    c.world.breakAfterSet = true
    c.ticks(1)
    check(c.fake.value("movement.swim_write") == "fails" and has(c.fake.detail("movement.swim_write"), "ForEach failed"),
        "a table that cannot be read back after the write: noted as not written")
    T.stop(c)
end
do
    local c = boot("console", {}, cfg({ "Config.SwimSpeed = 1.5" }))
    c.ticks(1)
    local dev = { lines = {} }
    function dev:Log(l) self.lines[#self.lines + 1] = l end
    local ret = c.ue.console.movement[1]("movement reload", nil, dev)
    check(ret == true and dev.lines[1] == "[G1R_Movement] settings read: on foot x1.00, swimming x1.50, your scavenger x1.00",
        "a command line and a device: reload reads config.lua even when unchanged, the line goes to the device, true comes back (" .. tostring(dev.lines[1]) .. ")")
    ret = c.ue.console.movement[1]("movement", nil, dev)
    check(ret == true and dev.lines[2] == "[G1R_Movement] v1.1.0 | on foot x1.00, swimming x1.50, your scavenger x1.00", "without a word: the status (" .. tostring(dev.lines[2]) .. ")")
    T.stop(c)
end
do
    local c = boot("dump", {}, cfg({ "Config.SwimSpeed = 1.5", "Config.MountSpeed = 1.25" }))
    c.seconds(2)
    local d = c.fake.dump[1]()
    check(d.version == "1.1.0" and d.swim_own == "100 / 150 / 220" and d.swim_applied == 1.5 and d.mount_own == 1.0 and d.mount_applied == 1.25
        and d.lookup_works == true and d.changes == 2 and d.put_back == 0 and d.swim_off == false and d.mount_left == false, "the dump holds what the module knows")
    T.stop(c)
end

do
    -- failures straight after a write (no look with everything in place between): still three looks
    local c = boot("swim-after-write", {}, cfg({ "Config.SwimSpeed = 1.5" }))
    c.ticks(1)
    c.world.swimRaises = true
    c.seconds(4)
    check(not c.hook.state.swim.off, "the table cannot be walked right after the write: two looks, not given up yet")
    T.stop(c)
    c = boot("mount-after-write", {}, cfg({ "Config.MountSpeed = 1.25" }))
    c.ticks(1)
    c.world.mount.list.items = {}
    c.seconds(4)
    check(not c.hook.state.mount.off, "the scavenger's attributes gone right after the write: two looks, not given up yet")
    T.stop(c)
end
do
    -- a table that loses an entry: not ours any more and not the game's own: left alone
    local c = boot("swim-shrinks", {}, cfg({ "Config.SwimSpeed = 1.5" }))
    c.ticks(1)
    c.world.swim[3] = nil
    c.seconds(2)
    check(c.hook.state.swim.left and speeds(c) == "150/225", "an entry fewer than the game's own: left alone")
    T.stop(c)
end

section("without the loader, without its settings")
do
    local c = boot("no-loader")
    local saved = rawget(_G, "G1R_KIT")
    rawset(_G, "G1R_KIT", nil)
    local loops = #c.ue.loops
    local ok = pcall(dofile, c.dir .. "/main.lua")
    rawset(_G, "G1R_KIT", saved)
    check(ok and printed(c.ue, "[G1R_Movement] this module needs the loader of G1R_MegaMod") ~= nil and #c.ue.loops == loops,
        "without the loader's kit: said, nothing registered")
    T.stop(c)
    c = T.boot("no-schema", { module = "movement", hook = "MOVEMENT_TEST", files = { ["Scripts/schema.lua"] = false }, prepare = function(ue) return newWorld(ue, {}) end })
    check(c.ok and printed(c.ue, "[G1R_Movement] the settings could not be set up") ~= nil and #c.ue.loops == 1, "without schema.lua: said, not started (only the loader's loop)")
    T.stop(c)
end

T.finish()
