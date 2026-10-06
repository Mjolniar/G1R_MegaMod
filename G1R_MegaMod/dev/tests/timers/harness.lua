-- ============================================================================
-- Offline tests of the module timers (modules/timers/Scripts/main.lua).
--
--   lua5.4 harness.lua          (from any directory)
--
-- The module runs on the loader's kit and settings service (../lib/modtest.lua,
-- ../mock/ue4ss.lua). The game is the model below: the hero's ability system
-- with its list of active effects (dev/facts/timers.md TM1), the world's time
-- (TM2), the Light's actor among the hero's children with its engine timer and
-- the spell's settings (TM4), the hero's alcohol and swampweed (TM5), and the
-- widgets of the box (T.widgets). Nothing of it has been seen in the game.
-- Last line: "timers tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*/)") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("timers")
local check, section, printed, printedCount = T.check, T.section, T.printed, T.printedCount
local NL = string.char(10)

local STATICS = "/Script/Engine.Default__GameplayStatics"
local SYSTEM = "/Script/Engine.Default__KismetSystemLibrary"
local CONFIG = "/Script/Angelscript.Default__LightSpellConfig"

-- ---------------------------------------------------------------------------
-- The game model
-- ---------------------------------------------------------------------------
-- options: noTime (GetTimeSeconds is not there), noList (the ability system has no list), noConfig.
-- While a case runs: world.time, world.effects (list of { name, duration, start }), world.addLight(left, last),
-- world.lightLeft (what the engine timer says; nil = the call raises), world.alcohol / world.swampweed { level, rate }.
local function newWorld(ue, o)
    o = o or {}
    local world = T.newWorld(ue)
    world.time, world.effects, world.calls = 100, {}, {}
    local function called(name) world.calls[name] = (world.calls[name] or 0) + 1 end
    local defs = {}
    local function def(name)
        defs[name] = defs[name] or ue:object(name .. " /Script/Angelscript.Default__" .. name, {})
        return defs[name]
    end
    local list = setmetatable({}, { __index = function(_, k)
        if k == "ForEach" then
            return function(_, f)
                called("effects")
                if world.listRaises then error("the list cannot be walked") end
                for i, e in ipairs(world.effects) do
                    local item = { Spec = { Def = e.name and def(e.name) or nil, Duration = e.duration }, StartWorldTime = e.start }
                    if f(i, { get = function() return item end }) == true then break end
                end
            end
        end
    end })
    if not o.noList then world.hero.component.ActiveGameplayEffects = { GameplayEffects_Internal = list } end
    if o.noSystem then rawset(world.hero.state, "__component", nil) end
    ue.objects[STATICS] = ue:object("GameplayStatics " .. STATICS, {
        GetTimeSeconds = (not o.noTime) and function(_, w)
            called("time")
            world.timeAsked = w
            if world.timeGone then return nil end
            return world.time
        end or nil,
        IsGamePaused = function() return false end,
    })
    ue.objects[SYSTEM] = ue:object("KismetSystemLibrary " .. SYSTEM, {
        K2_GetTimerRemainingTimeHandle = function(_, w, handle)
            called("timer")
            world.timerHandle = handle
            if world.lightLeft == nil then error("bad handle") end
            return world.lightLeft
        end,
    })
    if not o.noConfig then ue.objects[CONFIG] = ue:object("LightSpellConfig " .. CONFIG, { m_LifeSpan = 300.0 }) end
    -- the hero's children (the Light's actor is one of them)
    world.children = {}
    world.pawn.Children = T.array(world.children)
    world.pawn.Children.items = world.children
    function world.addLight(left, last, n)
        local light = ue:object(("BP_LightSpellVisual_C /Game/Maps/World.World:PersistentLevel.BP_LightSpellVisual_C_%d"):format(n or 1),
            { TaskTimer = { Handle = 70 + (n or 1) }, m_LastTimeSpan = last or 0.0 })
        world.children[#world.children + 1] = ue:object("BP_Sword_C /Game/Maps/World.World:PersistentLevel.BP_Sword_C_1", {})
        world.children[#world.children + 1] = light
        world.lightLeft = left
        world.light = light
        return light
    end
    function world.dropLight()
        for i = #world.children, 1, -1 do table.remove(world.children, i) end
        world.light = nil
    end
    -- alcohol and swampweed
    world.alcohol, world.swampweed = { level = 0, rate = 0.5 }, { level = 0, rate = 1 }
    local prefix = "/Game/Maps/World.World:PersistentLevel.GothicPlayerState_21"
    local function drug(part, d)
        local o = ue:object(("AttributeSet_%s %s.AttributeSet_%s_31"):format(part, prefix, part), {})
        local base = getmetatable(o)
        return setmetatable(o, { __index = function(_, k)
            if k == part then return { BaseValue = d.level, CurrentValue = d.level } end
            if k == part .. "DepletionRate" and d.rate ~= nil then return { BaseValue = d.rate, CurrentValue = d.rate } end
            return base.__index[k]
        end })
    end
    local items = world.hero.component.SpawnedAttributes.items
    items[#items + 1] = drug("Alcohol", world.alcohol)
    items[#items + 1] = drug("Swampweed", world.swampweed)
    return world
end

local function boot(case, o, config)
    o = o or {}
    return T.boot(case, { module = "timers", hook = "TIMERS_TEST", config = config, diag = o.diag ~= false,
        widgets = o.widgets == nil and true or o.widgets, prepare = function(ue) return newWorld(ue, o) end })
end
local function cfg(lines) return T.config(table.concat(lines, NL)) end
local function status(c) return table.concat(c.hook.status(), " | ") end
-- what the box shows now, or nil
local function box(c)
    local S = c.hook.state
    if not (S.shown and S.box) then return nil end
    local set = c.ui.last("SetText", S.box.text)
    return set and set.args[1] and set.args[1].text or nil
end
local function effect(c, name, duration, start) c.world.effects[#c.world.effects + 1] = { name = name, duration = duration, start = start } end
local function look(c, seconds)
    c.world.time = c.world.time + (seconds or 0)
    c.ticks(2)
end

-- ================================================================ load
section("load")
do
    local c = boot("load")
    check(c.ok, "the module loads (" .. tostring(c.err) .. ")")
    check(printed(c.ue, "[G1R_Timers] v1.0.2 loaded: food, elements, mind, light, drinks; bottom left, 24 / 200") ~= nil, "load line: " .. tostring(printed(c.ue, "loaded:")))
    check(c.ue.console.timers ~= nil and c.ue.console.g1r_timers ~= nil and #c.ue.loops == 2 and c.ue.loops[2].ms == 250, "console words; its loop and the loader's")
    local page = T.menuPage(c, "Effect timers")
    check(page ~= nil and #page.items == 10 and page.items[1].name == "Effect timers" and page.items[8].kind == "num" and page.items[8].max == 4,
        "in the in-game menu: the switches, the corner (1 to 4), the distances")
    c.seconds(3)
    check(box(c) == nil and c.ui.created == 0 and c.fake.value("timers.effects") == "readable" and c.fake.value("timers.world_time") == "works", "nothing on the hero: no box; the list and the time read")
    check(status(c) == "v1.0.2 | food, elements, mind, light, drinks; bottom left, 24 / 200 | nothing on screen", "status: " .. status(c))
    T.stop(c)
end

-- ================================================================ the effects
section("the effects with a duration")
do
    local c = boot("effects")
    effect(c, "GE_Burn", 10, 100)
    effect(c, "GE_Item_Heal_Overtime", 75, 100)
    effect(c, "GE_Spell_Light", -1, 100)                   -- no end: nothing to count
    effect(c, "GE_BurnDebuffVisualEffect", 30, 100)         -- only shows something (and lasts longer)
    effect(c, "GE_Item_AlcoholDrugDepletion_Overtime", 60, 100)
    effect(c, "GE_Item_Strength_Buff", 60, 100)             -- not one of the kinds (others are off)
    look(c, 3)
    check(box(c) == "Healing 1:12" .. NL .. "Burning 7 s", "the lines in the order of the kinds, the time left (start + length - now): " .. tostring(box(c)))
    check(c.world.timeAsked == c.world.world and c.ui.last("AddToViewport").args[1] == 40, "the world's time from the shown world; the box on layer 40")
    local anchors, position = c.ui.last("SetAnchors").args[1], c.ui.last("SetPosition").args[1]
    check(anchors.Minimum.X == 0 and anchors.Minimum.Y == 1 and position.X == 24 and position.Y == -200, "at the bottom left, 24 / 200 from the corner")
    effect(c, "GE_Damage_Fire_Duration_Burning", 20, 102)
    look(c, 1)
    check(box(c) == "Healing 1:11" .. NL .. "Burning 18 s", "two burning effects: one line, the longer: " .. tostring(box(c)))
    local texts = c.ui.count("SetText")
    c.ticks(1)
    check(c.ui.count("SetText") == texts, "the same lines: nothing is set again")
    local reads = c.world.calls.effects
    c.ticks(4)
    check(c.world.calls.effects == reads + 2, "a look every half second (two in four quarter seconds): " .. (c.world.calls.effects - reads))
    c.world.effects = { { name = "GE_Item_Heal_Overtime", duration = 75, start = 100 } }
    look(c, 70)
    check(box(c) == "Healing 1 s", "a second left: 1 s")
    look(c, 0.6)
    check(box(c) == "Healing 0 s", "0.4 s left: 0 s")
    look(c, 0.4)
    check(box(c) == nil, "exactly at its end: no line")
    look(c, 0.5)
    check(box(c) == nil and c.ui.last("SetVisibility", c.hook.state.box.widget).args[1] == 1, "run out: nothing left, the box is hidden")
    T.stop(c)
end

section("the kinds and their switches")
do
    local c = boot("kinds", {}, cfg({ "Config.ShowOthers = true" }))
    for _, e in ipairs({ { "GE_Item_Mana_Overtime", 30 }, { "GE_IceStack_Freeze", 8 }, { "GE_Electrified", 5 }, { "GE_Wind", 5 }, { "GE_Slowdown", 6 },
        { "GE_Defeated", 20 }, { "GE_Sleep", 30 }, { "GE_Fear", 10 }, { "GE_Charm", 60 }, { "GE_Item_Strength_Buff", 90 }, { "GE_Ability_CooldownCall", 3 } }) do
        effect(c, e[1], e[2], 100)
    end
    look(c, 0)
    check(box(c) == table.concat({ "Mana 30 s", "Frozen 8 s", "Electrified 5 s", "Wind 5 s", "Slowed 6 s", "Knocked out 20 s", "Asleep 30 s", "Afraid 10 s", "Charmed 1:00",
        "Item Strength Buff 1:30" }, NL), "every kind with its own name; another effect by the game's name (a cooldown left out):" .. NL .. tostring(box(c)))
    c.world.effects = {}
    effect(c, "GE_ManaShield", 10, c.world.time)
    look(c, 0)
    check(box(c) == "ManaShield 10 s", "mana without over time is not the food kind: " .. tostring(box(c)))
    -- what the game puts on the caster while a spell is cast or held: its mana cost, for as long as the cast (TM3)
    c.world.effects = {}
    for _, name in ipairs({ "GE_ManaBurn", "GE_Mana_Channeling", "GE_Mana_AimingLaunchingSpell", "GE_NoManaBurn", "GE_BurnRemoval", "GE_UnBurn",
        "GE_Burn_Damage_Infinite_Removal", "GE_EquipAbilitiesWhen_RuneEquip_FistOfWind" }) do
        effect(c, name, 5, c.world.time)
    end
    look(c, 0)
    check(box(c) == nil, "a spell's mana cost while it is cast, the removal of an effect, the abilities of an equipped rune: none of them is a timer (not 'Burning', not 'Wind', not among the others): " .. tostring(box(c)))
    effect(c, "GE_Burn", 5, c.world.time)
    effect(c, "GE_FireDemonFireExplosionBurn", 7, c.world.time)
    look(c, 0)
    check(box(c) == "Burning 7 s", "real burning still is: " .. tostring(box(c)))
    for _, name in ipairs({ "GE_IceStack_Freeze", "GE_Frozen", "GE_Freeze_5Secs", "GE_Freeze" }) do
        c.world.effects = {}
        effect(c, name, 8, c.world.time)
        look(c, 0)
        check(box(c) == "Frozen 8 s", name .. ": frozen")
    end
    -- reported 2026-10-06: "Frozen status appearing when struck ... also appearing randomly": every damage puts
    -- GE_FreezeHitsStack (2 s) on whoever it hits; the hits of ice and fire put GE_IceStack / GE_FireStack (TM3)
    c.world.effects = {}
    for _, name in ipairs({ "GE_FreezeHitsStack", "GE_IceStack", "GE_FireStack", "GE_LightingMagnet_NoElectrifiedDamage" }) do
        effect(c, name, 2, c.world.time)
    end
    look(c, 0)
    check(box(c) == nil, "the counter of every hit, the build-up of ice and fire, the lightning magnet's protection: no line (not 'Frozen', not among the others): " .. tostring(box(c)))
    effect(c, "GE_IceStack_Freeze", 8, c.world.time)
    look(c, 0)
    check(box(c) == "Frozen 8 s", "frozen while the counters run: the freeze's own time: " .. tostring(box(c)))
    c.world.effects = {}
    effect(c, "GE_Damage_Fire_Duration", 1, c.world.time)
    effect(c, false, 50, c.world.time)                      -- an effect whose class cannot be read
    effect(c, "GE_Wind", nil, c.world.time)                 -- one whose length cannot be read
    effect(c, "GE_Slowdown", 5, nil)                        -- one whose start cannot be read
    effect(c, "GE_Electrified", 0, c.world.time)            -- one that acts at once
    look(c, 0)
    check(box(c) == "Burning 1 s" and not c.hook.state.effectsOff and c.hook.state.fails.effects == 0, "an effect of one second is shown; the ones that cannot be read are passed over: " .. tostring(box(c)))
    c.world.effects = {}
    effect(c, "GE_Some_Buff", 30, c.world.time - 29.6)
    look(c, 0)
    check(box(c) == "Some Buff 0 s", "another effect with 0.4 s left: 0 s")
    T.write(c.path, cfg({ "Config.ShowElements = false", "Config.ShowMind = false", "Config.ShowFood = false" }))
    c.seconds(6)
    check(box(c) == nil, "food, elements, mind off (and the others off again): nothing")
    T.stop(c)

    -- each group on its own
    for _, g in ipairs({ { "ShowFood", "GE_Item_Heal_Overtime", "Healing" }, { "ShowElements", "GE_Wind", "Wind" }, { "ShowMind", "GE_Fear", "Afraid" } }) do
        local lines = { "Config.ShowFood = false", "Config.ShowElements = false", "Config.ShowMind = false", "Config.ShowLight = false", "Config.ShowDrinks = false" }
        lines[#lines + 1] = "Config." .. g[1] .. " = true"
        c = boot("only-" .. g[1], {}, cfg(lines))
        effect(c, g[2], 10, 100)
        look(c, 0)
        check(box(c) == g[3] .. " 10 s", g[1] .. " alone: " .. tostring(box(c)))
        T.stop(c)
    end

    c = boot("nothing", {}, cfg({ "Config.ShowElements = false", "Config.ShowMind = false", "Config.ShowFood = false", "Config.ShowLight = false", "Config.ShowDrinks = false" }))
    effect(c, "GE_Burn", 10, 100)
    c.world.addLight(100)
    c.world.alcohol.level = 10
    look(c, 1)
    check(box(c) == nil and (c.world.calls.effects or 0) == 0 and (c.world.calls.timer or 0) == 0 and printed(c.ue, "loaded: nothing shown;") ~= nil, "every switch off: nothing is read")
    T.stop(c)

    c = boot("disabled", {}, cfg({ "Config.Enabled = false" }))
    effect(c, "GE_Burn", 10, 100)
    look(c, 1)
    check(box(c) == nil and (c.world.calls.effects or 0) == 0 and printed(c.ue, "loaded: switched off") ~= nil, "switched off: nothing is read")
    T.stop(c)
end

-- ================================================================ the Light
section("the Light: its engine timer, else the module's own count")
do
    local c = boot("light")
    c.world.addLight(272.4)
    look(c, 0)
    check(box(c) == "Light 4:32" and c.world.timerHandle == c.world.light.TaskTimer and c.fake.value("timers.light_by") == "engine timer", "the engine's timer of the Light's actor: 4:32")
    c.world.lightLeft = 59.6
    look(c, 1)
    check(box(c) == "Light 1:00", "the timer goes on (it stands while you talk - the engine's own)")
    c.world.lightLeft = 0.8
    look(c, 0)
    check(box(c) == "Light 1 s", "0.8 s left: 1 s")
    c.world.dropLight()
    look(c, 1)
    check(box(c) == nil and c.hook.state.light == nil, "the Light is gone: no line")
    local first = c.world.addLight(50, 0, 1)
    c.world.addLight(50, 0, 2)
    look(c, 0)
    check(c.world.timerHandle == first.TaskTimer, "two Lights among the children: the first one's timer is asked")
    T.stop(c)

    -- the Light goes out: the game clears its timer and keeps the actor 5 s while it fades (TM4)
    c = boot("light-end")
    c.world.addLight(3.2)
    look(c, 0)
    check(box(c) == "Light 3 s", "(3 s left)")
    c.world.lightLeft = 0
    for _ = 1, 10 do look(c, 0.5) end
    check(box(c) == nil and c.hook.state.fails.timer == 0 and not c.hook.state.timerOff and c.hook.state.light == nil and c.fake.value("timers.light_by") == "engine timer",
        "the timer says 0 while the actor fades: the Light is out - no line, no failure, no count of the module's own (five seconds of it)")
    c.world.lightLeft = -1
    for _ = 1, 4 do look(c, 0.5) end
    check(box(c) == nil and c.hook.state.fails.timer == 0 and not c.hook.state.timerOff, "-1 (a timer the engine no longer has): the same")
    c.world.dropLight()
    c.world.addLight(300, 0, 2)
    look(c, 0)
    check(box(c) == "Light 5:00" and c.fake.value("timers.light_by") == "engine timer", "the next Light: by the engine's timer again")
    T.stop(c)

    -- the timer call fails, then a good answer, then fails again: failures count in a row
    c = boot("light-row")
    c.world.addLight(nil, 0)
    look(c, 0)
    look(c, 0)
    check(not c.hook.state.timerOff and c.hook.state.fails.timer == 2, "two failed calls: counted, not given up")
    c.world.lightLeft = 100
    look(c, 0)
    check(c.hook.state.fails.timer == 0 and box(c) == "Light 1:40", "a good answer: the count starts anew")
    c.world.lightLeft = nil
    look(c, 0)
    look(c, 0)
    check(not c.hook.state.timerOff, "two more: not given up")
    look(c, 0)
    check(c.hook.state.timerOff and T.has(tostring(c.fake.detail("timers.light_by")), "bad handle"), "the third in a row: the module counts itself")
    T.stop(c)

    -- the timer cannot be asked: three times, then the module counts itself
    c = boot("light-count")
    c.world.addLight(nil, 120)
    look(c, 0)
    check(box(c) == "Light 2:00" and c.fake.value("timers.light_by") == nil, "the timer call fails: the module's own count from the loaded light's time left (2:00)")
    look(c, 10)
    check(not c.hook.state.timerOff, "two failures: the timer is still asked")
    look(c, 10)
    check(box(c) == "Light 1:40" and c.fake.value("timers.light_by") == "own count" and T.has(tostring(c.fake.detail("timers.light_by")), "bad handle") and c.hook.state.timerOff,
        "three times: counted by the module from then on (noted)")
    local asks = c.world.calls.timer
    look(c, 10)
    check(c.world.calls.timer == asks and box(c) == "Light 1:30", "the timer is not asked any more")
    check(status(c) == "v1.0.2 | food, elements, mind, light, drinks; bottom left, 24 / 200 | on screen: Light 1:30 | the Light is counted by the module", "status: " .. status(c))
    check(c.fake.dump[1]().light == 120, "the dump has the Light's length")
    look(c, 90)
    check(box(c) == nil, "counted to exactly its end: no line")
    c.world.dropLight()
    c.world.addLight(nil, 0, 2)
    look(c, 1)
    check(box(c) == "Light 5:00", "a new Light: counted from the spell's length (300 s)")
    T.stop(c)

    -- a timer that answers something that is no number counts as a failure
    c = boot("light-odd")
    c.world.addLight("soon", 0)
    for _ = 1, 3 do look(c, 1) end
    check(c.hook.state.timerOff and c.fake.detail("timers.light_by") == "the timer said soon" and box(c) == "Light 4:58", "an answer that is no number: a failure; three, then the module's own count")
    T.stop(c)

    -- a loaded light with less than a second left, the own count
    c = boot("light-short")
    c.world.addLight(nil, 0.8)
    look(c, 0)
    check(box(c) == "Light 1 s", "a loaded light with 0.8 s left: 1 s")
    T.stop(c)

    -- the world's time goes away while the module counts: no line, no error
    c = boot("light-timegone")
    c.world.addLight(nil, 60)
    for _ = 1, 3 do look(c, 1) end
    check(box(c) == "Light 58 s" and c.hook.state.timerOff, "(counted by the module: 58 s)")
    c.world.timeGone = true
    look(c, 1)
    check(box(c) == nil or box(c) == "Light 58 s", "the time cannot be read any more: no new line (" .. tostring(box(c)) .. ")")
    T.stop(c)

    -- no world time for the own count: no line, no error
    c = boot("light-notime", { noTime = true })
    c.world.addLight(nil)
    for _ = 1, 4 do look(c, 1) end
    check(box(c) == nil and c.hook.state.timerOff, "the timer cannot be asked and the world's time cannot be read: no Light line")
    T.stop(c)

    c = boot("light-raises", { noConfig = true })
    c.world.addLight(nil)
    for _ = 1, 3 do look(c, 1) end
    check(box(c) == "Light 4:58" and c.fake.value("timers.light_by") == "own count" and T.has(tostring(c.fake.detail("timers.light_by")), "bad handle"),
        "the timer raises: the module's own count; no settings object: 300 s (" .. tostring(box(c)) .. ", " .. tostring(c.fake.detail("timers.light_by")) .. ")")
    T.stop(c)
end

-- ================================================================ alcohol and swampweed
section("alcohol and swampweed")
do
    local c = boot("drinks")
    c.world.alcohol.level, c.world.alcohol.rate = 30, 0.5
    c.world.swampweed.level, c.world.swampweed.rate = 12, -2
    look(c, 0)
    check(box(c) == "Alcohol 1:00" .. NL .. "Swampweed 6 s" and c.fake.value("timers.drinks") == "readable", "level / rate (a rate written below zero counts by its size): alcohol 1:00, swampweed 6 s ("
        .. tostring(box(c)) .. ", " .. tostring(c.fake.value("timers.drinks")) .. ")")
    c.world.alcohol.rate = 0
    c.world.swampweed.level = 0
    look(c, 1)
    check(box(c) == nil, "a rate of 0, a level of 0: no line")
    c.world.alcohol.level, c.world.alcohol.rate = 0.5, 0.5
    look(c, 1)
    check(box(c) == "Alcohol 1 s", "a level of 0.5: 1 s")
    c.world.alcohol.rate = nil
    look(c, 1)
    local noted = false
    for _, n in ipairs(c.fake.notes) do
        if n.key == "timers.drinks" and n.value == "not readable" and n.detail == "Alcohol" then noted = true end
    end
    check(box(c) == nil and noted, "a rate that is not there: no line, noted for alcohol")
    T.stop(c)
end

-- ================================================================ where the box sits
section("where the box sits")
do
    local c = boot("place", {}, cfg({ 'Config.Position = "top right"', "Config.DistanceX = 40", "Config.DistanceY = 60" }))
    effect(c, "GE_Burn", 10, 100)
    look(c, 0)
    local a, p = c.ui.last("SetAlignment").args[1], c.ui.last("SetPosition").args[1]
    check(box(c) == "Burning 10 s" and a.X == 1 and a.Y == 0 and p.X == -40 and p.Y == 60, "top right, 40 / 60 from the corner")
    local first = c.hook.state.box
    T.write(c.path, cfg({ 'Config.Position = "bottom right"', "Config.DistanceX = 40", "Config.DistanceY = 60" }))
    c.seconds(6)
    a, p = c.ui.last("SetAlignment").args[1], c.ui.last("SetPosition").args[1]
    check(box(c) == "Burning 4 s" or box(c) == "Burning 10 s", "moved: the lines in a box at the new place (" .. tostring(box(c)) .. ")")
    check(c.hook.state.box ~= first and a.X == 1 and a.Y == 1 and p.X == -40 and p.Y == -60 and c.ui.last("SetVisibility", first.widget).args[1] == 1,
        "the new box at the bottom right; the old one hidden")
    T.stop(c)
end

-- ================================================================ what does not work
section("what does not work")
do
    local c = boot("nolist", { noList = true })
    c.world.addLight(50)
    for _ = 1, 3 do look(c, 1) end
    check(c.fake.value("timers.effects") == "not readable" and c.fake.detail("timers.effects") == "no list of effects" and c.hook.state.effectsOff
        and printedCount(c.ue, "the hero's effects cannot be read (no list of effects); their timers are not shown in this run") == 1, "no list: three times, then given up, said once")
    check(box(c) == "Light 50 s", "the Light is shown all the same")
    check(status(c) == "v1.0.2 | food, elements, mind, light, drinks; bottom left, 24 / 200 | on screen: Light 50 s | the hero's effects cannot be read in this run", "status: " .. status(c))
    T.stop(c)

    -- failures count in a row
    c = boot("rows")
    c.world.listRaises = true
    look(c, 0)
    look(c, 0)
    check(not c.hook.state.effectsOff and c.hook.state.fails.effects == 2, "two looks whose list cannot be walked: counted, not given up")
    c.world.listRaises = false
    look(c, 0)
    check(c.hook.state.fails.effects == 0, "a good look: the count starts anew")
    c.world.listRaises = true
    look(c, 0)
    look(c, 0)
    check(not c.hook.state.effectsOff, "two more: not given up")
    look(c, 0)
    check(c.hook.state.effectsOff and c.fake.detail("timers.effects") == "the list of effects cannot be walked", "the third in a row: given up, the reason noted")
    T.stop(c)

    c = boot("nosystem", { noSystem = true })
    for _ = 1, 4 do look(c, 1) end
    check(not c.hook.state.effectsOff and c.fake.value("timers.effects") == nil, "a hero without an ability system yet: nothing counted as a failure")
    T.stop(c)

    c = boot("notime", { noTime = true })
    effect(c, "GE_Burn", 10, 100)
    for _ = 1, 3 do look(c, 1) end
    check(c.fake.value("timers.world_time") == "not readable" and c.hook.state.effectsOff and c.fake.detail("timers.effects") == "the world's time cannot be read",
        "the world's time cannot be read: the effects are given up, with that reason")
    T.stop(c)

    c = boot("nobox", { widgets = { missing = "/Script/UMG.Border" } })
    effect(c, "GE_Burn", 10, 100)
    look(c, 0)
    look(c, 1)
    check(box(c) == nil and c.hook.state.box.available() == false and printedCount(c.ue, 'the box "timers:bottom left:24:200" is not available') == 1, "no box: said once by the kit")
    T.stop(c)

    c = boot("loading")
    effect(c, "GE_Burn", 10, 100)
    look(c, 0)
    c.ue:fireLoadMapPre("engine", "world", "url", nil, "")
    c.ticks(2)
    check(box(c) == nil, "while a map loads: hidden")
    c.ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.world.effects = {}
    look(c, 1)
    check(box(c) == nil and c.hook.state.lines == nil, "after it: nothing on the hero, nothing shown")
    T.stop(c)
end

section("console and diagnostics")
do
    local c = boot("console")
    effect(c, "GE_Burn", 10, 100)
    look(c, 2)
    check(c.ue:fireConsole("timers") == true and c.ue.device.lines[2] == "[G1R_Timers] on screen: Burning 8 s", "console: what is on screen")
    local handler = c.ue.console.timers[1]
    local before = #c.ue.printed
    check(handler("timers", { "reload" }, nil) == true and T.has(c.ue.printed[before + 1], "settings read: food"), "parameters: reload")
    before = #c.ue.printed
    check(handler("timers reload", nil, nil) == true and T.has(c.ue.printed[before + 1], "settings read: "), "no parameters: the words of the whole line")
    before = #c.ue.printed
    check(handler("timers", nil, nil) == true and T.has(c.ue.printed[before + 1], "[G1R_Timers] v1.0.2 | "), "no parameters, no word: the status")
    check(#c.fake.versions == 1 and #c.fake.status == 1 and #c.fake.dump == 1 and c.fake.dump[1]().lines[1] == "Burning 8 s", "version, status and dump")
    T.stop(c)
    c = boot("nodiag", { diag = false })
    effect(c, "GE_Burn", 10, 100)
    look(c, 0)
    check(box(c) == "Burning 10 s", "without diagnostics it works the same")
    T.stop(c)
end

section("load: without the loader, a schema that cannot be used")
do
    local ue = T.Mock.new()
    ue:install()
    local ok = pcall(dofile, T.MOD .. "modules/timers/Scripts/main.lua")
    check(ok and T.printed(ue, "[G1R_Timers] this module needs the loader of G1R_MegaMod") ~= nil and #ue.loops == 0, "started on its own: says so")
    ue:uninstall()
    ue = T.Mock.new()
    ue:install()
    rawset(_G, "G1R_KIT", {})
    ok = pcall(dofile, T.MOD .. "modules/timers/Scripts/main.lua")
    check(ok and T.printed(ue, "[G1R_Timers] this module needs the loader of G1R_MegaMod") ~= nil and #ue.loops == 0, "the kit alone: the same")
    rawset(_G, "G1R_KIT", nil)
    ue:uninstall()
    local c = T.boot("badschema", { module = "timers", hook = "TIMERS_TEST", diag = true, files = { ["Scripts/schema.lua"] = "return 5" .. NL } })
    check(c.ok and printed(c.ue, "[G1R_Timers] the settings could not be set up (") ~= nil and #c.ue.loops == 1, "a schema that cannot be used: said, nothing registered")
    T.stop(c)
end

T.finish()
