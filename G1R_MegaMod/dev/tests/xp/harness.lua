-- ============================================================================
-- Offline tests of the module xp (modules/xp/Scripts/main.lua).
--
--   lua5.4 harness.lua          (from any directory)
--
-- The module runs on the loader's kit and settings service; ../lib/modtest.lua
-- sets both up the way the loader does, replaces UE4SS by ../mock/ue4ss.lua and
-- the game by a small model (player controller -> player state -> ability
-- system -> attribute sets, the widget classes for notes, shared variables).
-- Sections 1-14 run the module that way, section 15 through the real loader
-- with the real diagnostics.
-- Last line: "xp tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("xp")
local check, section, has, printed, printedCount = T.check, T.section, T.has, T.printed, T.printedCount
local MOD = T.MOD

local function start(case, options)
    options = options or {}
    options.module, options.hook = "xp", "XP_TEST"
    local c = T.boot(case, options)
    c.S = c.hook and c.hook.state
    function c.gain(amount, who)
        c.world.add("Experience", amount, who)
        c.ticks(1)
    end
    function c.xp(who) return c.world.value("Experience", who) end
    return c
end
local stop = T.stop
local function allOf(ue) return ue.calls.FindAllOf or 0 end
local function status(c) return table.concat(c.hook.status(), "|") end

local LEDGER = "EXPModifier_lastWrite"
local RESTART = "/Script/Engine.PlayerController:ClientRestart"
-- Most cases count gains from the first look on; the settle time has its own section.
local NOW = "\nConfig.SettleSeconds = 0"
local X4 = T.config("Config.Multiplier = 4.0\nConfig.LogGains = true" .. NOW)
local shipped = T.read(MOD .. "modules/xp/Scripts/config.lua")

-- ---------------------------------------------------------------------------
section("1. loading with the shipped settings")
do
    local c = start("load")
    local ue = c.ue
    check(c.ok, "the module loads (" .. tostring(c.err) .. ")")
    check(#ue.printed == 1 and ue.printed[1] == "[G1R_XP] v1.0.0 loaded: multiplier x1.0 (experience unchanged)\n", "one load line: " .. tostring(ue.printed[1]):gsub("\n", ""))
    check(#ue.loops == 2 and ue.loops[2].ms == 250 and math.type(ue.loops[2].ms) == "integer", "one game-thread loop of its own, every 250 ms")
    check(ue.console.xp ~= nil and ue.console.g1r_xp ~= nil and #ue.loadMapPre == 1 and #ue.loadMapPost == 1, "console commands xp and g1r_xp; the kit's hooks before and after a map load")
    check(#ue.lookups == 0 and allOf(ue) == 0 and (ue.calls.FindFirstOf or 0) == 0, "loading searches for nothing")
    check(ue.calls.RegisterHook == 1 and ue.hooks[RESTART] == nil and #ue.errors == 0, "a UE4SS that does not know the hook's function: asked once, the module loads all the same")
    local v = c.hook.settings.values
    check(v.Enabled == true and v.Multiplier == 1.0 and v.LargeGainFrom == 0 and v.LargeGainMultiplier == 1.0 and v.ShowMessage == true
        and v.LogGains == false and v.MaxGain == 50000 and v.SettleSeconds == 10 and v.CheckMilliseconds == 250, "the shipped file gives the documented defaults")
    c.ticks(8)
    c.gain(30)
    c.ticks(8)
    check(c.xp() == 6732 and c.S.gains == 0 and #ue.errors == 0, "multiplier 1.0: a gain stays as the game gave it, nothing is written")
    check(allOf(ue) == 0 and c.world.reads[21] == nil and #ue.lookups == 0, "with nothing to multiply the module does not look at the game at all")
    local idleLines = c.hook.status()
    check(#idleLines == 3 and idleLines[1] == "v1.0.0 | multiplier x1.0 (experience unchanged)" and idleLines[2] == "nothing to multiply: the game is not looked at"
        and idleLines[3] == "gains multiplied: 0 (+0 experience in total)", "the status says so, in three lines")
    check(T.read(c.path) == shipped, "the settings file is left as it is")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("2. gains are multiplied (the numbers of a real session at x4)")
do
    local c = start("x4", { config = X4 })
    local ue, w = c.ue, c.world
    check(printed(ue, "loaded: multiplier x4.0") ~= nil, "load line names the multiplier")
    c.ticks(2)
    check(c.S.via == "player state" and c.S.setName == w.hero.set:GetFullName() and c.xp() == 6702, "the first look only takes the value: nothing is added to what is there")
    check(allOf(ue) == 1, "found through the player state: one search for the controller, none for the attributes (" .. allOf(ue) .. " FindAllOf)")
    c.gain(30)
    check(c.xp() == 6822 and w.base("Experience") == 6822, "gain 30 counts as 120: 6702 -> 6822, base value and current value")
    check(printed(ue, "[G1R_XP] gained 30 -> 120 (x4.0); experience now 6822\n") ~= nil, "log line as written: gained 30 -> 120 (x4.0); experience now 6822")
    c.ticks(20)
    check(c.xp() == 6822 and c.S.gains == 1, "no gain, nothing added (20 looks)")
    local expected = { { 10, 6862 }, { 30, 6982 }, { 30, 7102 }, { 50, 7302 }, { 30, 7422 }, { 30, 7542 } }
    local good = true
    for _, e in ipairs(expected) do
        c.gain(e[1])
        if c.xp() ~= e[2] then good = false end
        c.ticks(3)
    end
    check(good and c.S.gains == 7 and c.S.added == 630, "six more gains (10, 30, 30, 50, 30, 30) end at 7542 as in the session log; 630 added in total")
    w.add("Experience", 30)
    w.add("Experience", 10)
    c.ticks(1)
    check(c.xp() == 7542 + 160, "two gains between two looks count as one gain of 40 -> 160")
    check(w.value("Health") == 80 and w.value("Mana") == 10 and w.value("Level") == 4 and #ue.errors == 0, "nothing else of the hero is touched, no error")
    check(allOf(ue) == 1 and #ue.lookups == 2, "all of this with the one search from the start (and two by path for the note, which this model does not have)")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("3. the multiplier: below 1, zero, fractions, out of range, not a number")
do
    local function after(multiplierText, gain)
        local c = start("m", { config = T.config("Config.Multiplier = " .. multiplierText .. NOW) })
        c.ticks(1)
        c.gain(gain)
        local e, m = c.xp(), c.hook.settings.values.Multiplier
        local errors, lines, gains = #c.ue.errors, table.concat(c.ue.printed), c.S.gains
        stop(c)
        return e - 6702, m, errors, lines, gains
    end
    local got, m, errors, lines = after("2.5", 30)
    check(got == 75 and m == 2.5, "x2.5: 30 -> 75")
    got = after("0.5", 30)
    check(got == 15, "x0.5: 30 -> 15")
    got = after("0", 30)
    check(got == 0, "x0: the gain is taken back, nothing more")
    got = after("1.5", 3)
    check(got == 5, "x1.5 of 3: 4.5 is rounded to 5")
    got = after("2.5", 1)
    check(got == 3, "x2.5 of 1: 2.5 is rounded to 3")
    local gains
    got, m, errors, lines, gains = after("0.5", 1)
    check(got == 1 and gains == 0, "x0.5 of 1: 0.5 is rounded to 1, nothing is written")
    got, m, errors, lines, gains = after("1.1", 3)
    check(got == 3 and gains == 0, "x1.1 of 3: the bonus rounds to 0, nothing is written")
    got, m, errors, lines = after("25", 10)
    check(got == 100 and m == 10 and has(lines, "config.lua: Multiplier = 25 is not usable; 10.0 is used"), "25 is taken as 10 (the upper end), said in the log")
    got, m = after("-3", 10)
    check(got == 0 and m == 0, "-3 is taken as 0 (the lower end)")
    got, m, errors = after('"fast"', 10)
    check(got == 10 and m == 1.0 and errors == 0, "a text instead of a number: 1.0, no error")
    got, m = after("0/0", 10)
    check(got == 10 and m == 1.0, "not-a-number: 1.0")
    got, m = after('"3"', 10)
    check(got == 30 and m == 3, "a number written as text is taken as the number")
    got, m = after("2.126", 100)
    check(m == 2.13 and got == 213, "more places than the setting has are rounded: 2.126 -> 2.13")
    got, m, errors, lines = after("2,5", 10)
    check(got == 20 and m == 2 and has(lines, "a number seems to be written with a comma"), "2,5 (a comma) is 2 for Lua: said in the log")

    -- large gains with a multiplier of their own
    local c = start("large", { config = T.config("Config.Multiplier = 2.0\nConfig.LargeGainFrom = 100\nConfig.LargeGainMultiplier = 1.5\nConfig.LogGains = true" .. NOW) })
    check(printed(c.ue, "loaded: multiplier x2.0, gains from 100 on x1.5") ~= nil, "a size for large gains: the load line names both multipliers")
    c.ticks(1)
    c.gain(99)
    check(c.xp() == 6702 + 198, "a gain below the size uses Multiplier: 99 -> 198")
    c.gain(100)
    check(c.xp() == 6900 + 150, "a gain of that size uses LargeGainMultiplier: 100 -> 150")
    c.gain(500)
    check(c.xp() == 7050 + 750 and printed(c.ue, "gained 500 -> 750 (x1.5)") ~= nil, "500 -> 750, the log names the multiplier used")
    stop(c)
    c = start("large-only", { config = T.config("Config.Multiplier = 1.0\nConfig.LargeGainFrom = 100\nConfig.LargeGainMultiplier = 3.0" .. NOW) })
    c.ticks(1)
    c.gain(30)
    c.gain(200)
    check(c.xp() == 6702 + 30 + 600, "Multiplier 1.0 with large gains x3: small gains stay, large ones are multiplied")
    stop(c)
    c = start("large-from-1", { config = T.config("Config.Multiplier = 2.0\nConfig.LargeGainFrom = 1\nConfig.LargeGainMultiplier = 3.0" .. NOW) })
    check(printed(c.ue, "loaded: multiplier x2.0, gains from 1 on x3.0") ~= nil, "LargeGainFrom = 1: every gain is a large one, the load line says from 1 on")
    c.ticks(1)
    c.gain(30)
    check(c.xp() == 6702 + 90, "and uses LargeGainMultiplier: 30 -> 90")
    stop(c)
    c = start("large-from-1b", { config = T.config("Config.Multiplier = 1.0\nConfig.LargeGainFrom = 1\nConfig.LargeGainMultiplier = 3.0" .. NOW) })
    c.ticks(1)
    c.gain(30)
    check(c.xp() == 6702 + 90, "the same with Multiplier 1.0: the module is not idle")
    stop(c)
    c = start("large-unused", { config = T.config("Config.Multiplier = 1.0\nConfig.LargeGainFrom = 0\nConfig.LargeGainMultiplier = 3.0" .. NOW) })
    c.ticks(4)
    c.gain(30)
    check(allOf(c.ue) == 0 and c.xp() == 6732, "LargeGainFrom = 0 makes LargeGainMultiplier unused: with Multiplier 1.0 the game is not looked at")
    stop(c)
    c = start("large-neutral", { config = T.config("Config.Multiplier = 1.0\nConfig.LargeGainFrom = 100\nConfig.LargeGainMultiplier = 1.0" .. NOW) })
    c.ticks(4)
    check(allOf(c.ue) == 0 and has(status(c), "multiplier x1.0 (experience unchanged)"), "both multipliers 1.0: nothing to multiply, the game is not looked at")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("4. what is never multiplied")
do
    local c = start("never", { config = X4 })
    local w = c.world
    c.ticks(1)
    w.set("Experience", 5000.0)         -- a save with less experience
    c.ticks(1)
    check(c.xp() == 5000 and c.S.gains == 0, "experience went down (a loaded save): taken as it is")
    c.gain(20)
    check(c.xp() == 5080, "the next gain counts from there: 20 -> 80")
    w.add("Experience", 60000)          -- a jump no fight or quest gives
    c.ticks(1)
    check(c.xp() == 65080 and c.S.skipped == 1 and printed(c.ue, "more than MaxGain") ~= nil, "a jump of 60000 (more than MaxGain) is taken as a loaded save, said in the log")
    c.gain(50000)
    check(c.xp() == 65080 + 200000, "50000 is still a gain (MaxGain itself)")
    check(has(status(c), "1 jump(s) taken as a loaded save"), "the status counts the jump")
    stop(c)

    c = start("off", { config = T.config("Config.Multiplier = 4.0\nConfig.Enabled = false" .. NOW) })
    w = c.world
    check(printed(c.ue, "loaded: switched off in the settings") ~= nil, "Enabled = false: the load line says so")
    c.ticks(1)
    c.gain(30)
    check(c.xp() == 6732 and allOf(c.ue) == 0, "switched off: nothing is added, the game is not looked at")
    T.write(c.path, X4)
    c.ticks(24)
    check(printed(c.ue, "[G1R_XP] settings changed (config.lua): multiplier x4.0\n") ~= nil, "switched on while the game runs: said in the log")
    check(c.xp() == 6732, "what was gained while it was off is not multiplied afterwards")
    c.gain(30)
    check(c.xp() == 6852, "the next gain is")
    -- the multiplier changes between two looks, and a gain arrives in the same quarter second
    T.write(c.path, T.config("Config.Multiplier = 2.0" .. NOW))
    w.add("Experience", 30)
    c.ue:fireConsole("xp reload")
    c.ticks(1)
    check(printed(c.ue, "settings changed (config.lua): multiplier x2.0") ~= nil and c.xp() == 6882,
        "a gain that arrives together with a new multiplier is left alone (it cannot be said which one it belongs to)")
    c.gain(30)
    check(c.xp() == 6942, "from then on the new multiplier: 30 -> 60")
    -- switched off again: at rest at once
    T.write(c.path, T.config("Config.Multiplier = 2.0\nConfig.Enabled = false" .. NOW))
    c.ue:fireConsole("xp reload")
    local reads = w.reads[21]
    c.gain(30)
    c.ticks(30)
    check(c.xp() == 6972 and w.reads[21] == reads and c.S.setName == nil, "switched off while the game runs: nothing is added and nothing is read any more")
    check(has(status(c), "|nothing to multiply: the game is not looked at|") and not has(status(c), "|experience "), "the status no longer shows a number it does not follow")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("5. the first seconds after the hero was found (a save may still be filling in)")
do
    local c = start("settle", { config = T.config("Config.Multiplier = 4.0\nConfig.LogGains = true"), diag = true, mock = { anyHook = true } })
    local ue, w = c.ue, c.world
    c.ticks(1)
    w.add("Experience", 800)            -- the save's own number arrives after the first look
    c.ticks(4)
    check(c.xp() == 7502 and c.S.gains == 0, "what changes in the first seconds after the hero was found is not a gain")
    c.ticks(34)
    c.gain(30)
    check(c.xp() == 7532 and c.S.gains == 0, "still not a quarter second before the 10 seconds (SettleSeconds) are over")
    c.gain(30)
    check(c.xp() == 7532 + 120 and c.S.gains == 1, "from 10 seconds after the first look on gains count: 30 -> 120")
    check(c.fake.value("xp.changed_while_settling") == "yes" and c.fake.detail("xp.changed_while_settling") == "6702 -> 7532",
        "the diagnostics note that the number moved in that time, and from where to where")
    -- the hero is put into the world again (a loaded save, a respawn): the wait starts again
    check(#(ue.hooks[RESTART] or {}) == 1, "one hook on the player controller's restart")
    w.add("Experience", 500)
    ue:fireHook(RESTART, w.controller)
    c.ticks(1)
    check(c.xp() == 8152 and c.S.gains == 1, "what arrives together with a restart of the hero is not a gain")
    c.gain(30)
    c.ticks(30)
    check(c.xp() == 8182 and c.S.gains == 1, "nor what comes in the seconds after it")
    c.ticks(12)
    c.gain(30)
    check(c.xp() == 8182 + 120 and #ue.errors == 0, "then gains count again")
    stop(c)

    c = start("settle-calm", { config = T.config("Config.Multiplier = 4.0"), diag = true })
    c.ticks(44)
    c.gain(30)
    check(c.xp() == 6822 and c.fake.value("xp.changed_while_settling") == "no" and c.fake.count["xp.changed_while_settling"] == 1,
        "a number that stayed still in that time is noted once as such")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("6. another player state, wrappers that outlive their object")
do
    local c = start("swap", { config = X4 })
    local ue, w = c.ue, c.world
    local function progression(n, experience)
        return ue:object("AttributeSet_LevelProgression /Game/Maps/World.World:PersistentLevel.GothicPlayerState_40.AttributeSet_LevelProgression_" .. n, {
            Level = { BaseValue = 1.0, CurrentValue = 1.0 }, Experience = { BaseValue = experience, CurrentValue = experience } })
    end
    c.ticks(1)
    c.gain(30)
    -- a new game: the controller gets another player state with its own attributes
    local second = T.hero(ue, w, 40, { Experience = 900.0, Level = 1.0 })
    w.controller.PlayerState = second.state
    c.ticks(1)
    check(c.S.setName == second.set:GetFullName() and c.xp(second) == 900 and c.xp() == 6822, "another player state: its attributes are taken, nothing is added to either")
    c.gain(100, second)
    check(c.xp(second) == 1300 and c.xp() == 6822, "gains of the new hero are multiplied; the old attributes are left alone")
    w.add("Experience", 500)            -- the old hero's attributes still change (an object on its way out)
    c.ticks(2)
    check(c.xp() == 7322, "a change in the old attributes is nobody's gain")

    -- the attributes object is destroyed and another object gets its address: the wrapper looks alive again
    local stale = second.set
    local replacement = progression(77, 1300.0)
    second.component.SpawnedAttributes.items[3] = replacement
    stale.__full = "GothicNPCState /Game/Maps/World.World:PersistentLevel.GothicNPCState_9.AttributeSet_LevelProgression_3"
    stale.Experience = { BaseValue = 50.0, CurrentValue = 50.0 }
    c.ticks(1)
    stale.Experience.BaseValue, stale.Experience.CurrentValue = 80.0, 80.0
    replacement.Experience.BaseValue, replacement.Experience.CurrentValue = 1310.0, 1310.0
    c.ticks(1)
    check(c.S.setName == replacement:GetFullName() and stale.Experience.CurrentValue == 80 and replacement.Experience.CurrentValue == 1340,
        "a kept wrapper that now names another object is dropped: that object is not written to, the hero's new attributes are")
    -- the object is gone for good
    replacement.__valid = false
    local third = progression(78, 1340.0)
    second.component.SpawnedAttributes.items[3] = third
    c.ticks(1)
    third.Experience.BaseValue, third.Experience.CurrentValue = 1350.0, 1350.0
    c.ticks(1)
    check(c.S.setName == third:GetFullName() and third.Experience.CurrentValue == 1380 and #ue.errors == 0, "attributes that are gone are looked up again through the player state")
    -- the state gets other attributes while the old object stays alive under its name
    local fourth = progression(79, 2000.0)
    second.component.SpawnedAttributes.items[3] = fourth
    third.Experience.BaseValue, third.Experience.CurrentValue = 1400.0, 1400.0
    c.ticks(21)
    fourth.Experience.BaseValue, fourth.Experience.CurrentValue = 2010.0, 2010.0
    c.ticks(1)
    check(c.S.setName == fourth:GetFullName() and fourth.Experience.CurrentValue == 2040, "attributes replaced under the same player state are noticed within seconds")
    check(allOf(ue) == 1, "all of this without another search among all objects (" .. allOf(ue) .. " FindAllOf)")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("7. no hero: menus, the search and how often it runs")
do
    -- a controller whose player state has no ability system (a menu)
    local c = start("menu", { config = X4, prepare = function(ue)
        local world = { reads = {} }
        local state = ue:object("PlayerState /Game/Maps/Menu.Menu:PersistentLevel.PlayerState_3", {})
        local meta = getmetatable(state)
        setmetatable(state, { __index = function(_, k)
            if k == "AbilitySystemComponent" then world.reads.menu = (world.reads.menu or 0) + 1 return nil end
            return meta.__index[k]
        end })
        world.controller = T.controllerOf(ue, 2, state)
        ue.allOf["GothicPlayerControllerBaseBP_C"] = { world.controller }
        return world
    end })
    local ue, w = c.ue, c.world
    c.ticks(240)        -- one minute
    check(w.reads.menu == 3, "a player state without an ability system is asked for it 3 times, not four times a second (" .. tostring(w.reads.menu) .. ")")
    local scans = allOf(ue) - 1
    check(scans == 4, "then the search among all objects runs with growing pauses: 4 times in the first minute (" .. scans .. ")")
    c.ticks(240 * 4)    -- four more minutes
    check(allOf(ue) - 1 - scans == 4, "and once a minute after that (" .. (allOf(ue) - 1 - scans) .. " in four minutes)")
    check(c.S.setName == nil and #ue.errors == 0 and has(status(c), "has not been found yet"), "no hero is not an error; the status says the experience has not been found")
    stop(c)

    -- no controller at all, then one appears
    c = start("nocontroller", { config = X4, prepare = function(ue) return T.newWorld(ue, { noController = true }) end })
    ue, w = c.ue, c.world
    c.ticks(48)         -- 12 seconds
    check(allOf(ue) == 8, "without a controller: searched every 3 seconds under both class names (" .. allOf(ue) .. " FindAllOf in 12 s)")
    ue.allOf["PlayerController"] = { w.controller }
    c.ticks(12)
    check(c.kit._test.hero.controller == w.controller and c.S.setName == w.hero.set:GetFullName(), "a controller of the general class is taken too")
    c.gain(30)
    check(c.xp() == 6822, "and gains are multiplied")
    local before = allOf(ue)
    w.controller.__valid = false
    ue.allOf["PlayerController"] = nil
    c.ticks(1)
    w.add("Experience", 500)            -- while the hero cannot be reached
    local newer = T.controllerOf(ue, 6, w.hero.state)
    ue.allOf["PlayerController"] = { newer }
    c.ticks(12)
    c.gain(30)
    check(c.kit._test.hero.controller == newer and c.xp() == 6822 + 500 + 120 and allOf(ue) - before <= 4,
        "a controller that is gone is searched again; what the number did meanwhile is no gain, the next gain is")
    stop(c)

    -- the controller's wrapper names another object now (its object went away, the address was used again)
    c = start("controller-alias", { config = X4 })
    ue, w = c.ue, c.world
    c.ticks(1)
    c.gain(30)
    w.controller.__full = "StaticMeshActor /Game/Maps/World.World:PersistentLevel.StaticMeshActor_77"
    w.controller.PlayerState = nil
    local second = T.controllerOf(ue, 8, w.hero.state)
    ue.allOf["GothicPlayerControllerBaseBP_C"] = { second }
    c.ticks(16)
    c.gain(30)
    check(c.kit._test.hero.controller == second and c.xp() == 6942, "a kept controller that now names another object is dropped and the real one found within seconds")
    stop(c)

    -- only the class default object of the controller exists (very early, or a menu without a player)
    c = start("controller-default", { config = X4, prepare = function(ue)
        local world = T.newWorld(ue)
        ue.allOf["GothicPlayerControllerBaseBP_C"] = { world.controllerDefault }
        return world
    end })
    c.ticks(20)
    check(c.kit._test.hero.controller == nil and c.S.setName == nil and #c.ue.errors == 0, "the default object of the controller class is not taken for a controller")
    stop(c)

    -- two controllers: the one with a player state is the hero's
    c = start("controller-two", { config = X4, prepare = function(ue)
        local world = T.newWorld(ue)
        world.spectator = T.controllerOf(ue, 9, nil)
        ue.allOf["GothicPlayerControllerBaseBP_C"] = { world.controllerDefault, world.controller, world.spectator }
        return world
    end })
    c.ticks(1)
    c.gain(30)
    check(c.kit._test.hero.controller == c.world.controller and c.xp() == 6822, "of two controllers the one with a player state is taken")
    stop(c)

    -- the state's own list is not usable: the search finds the attributes of this player state
    c = start("scan", { config = X4, diag = true, prepare = function(ue)
        local world = T.newWorld(ue)
        world.hero.component.SpawnedAttributes = nil
        local other = T.hero(ue, world, 60, { Experience = 111.0 })
        local npc = ue:object("AttributeSet_LevelProgression /Game/Maps/World.World:PersistentLevel.GothicNPCState_8.AttributeSet_LevelProgression_9", {
            Experience = { BaseValue = 5.0, CurrentValue = 5.0 } })
        local default = ue:object("AttributeSet_LevelProgression /Script/G1R.Default__AttributeSet_LevelProgression", { Experience = { BaseValue = 0.0, CurrentValue = 0.0 } })
        world.other, world.npc = other, npc
        ue.allOf["AttributeSet_LevelProgression"] = { default, world.hero.set, npc, other.set }
        return world
    end })
    ue, w = c.ue, c.world
    c.ticks(16)
    check(c.S.via == "scan" and c.S.setName == w.hero.set:GetFullName() and c.fake.value("xp.set_found_by") == "scan",
        "found by the search: the attributes inside the controller's player state, not another state's, not a creature's, not the default object")
    c.gain(30)
    w.add("Experience", 30, w.other)
    w.npc.Experience.CurrentValue = 500.0
    c.ticks(2)
    check(c.xp() == 6822 and c.xp(w.other) == 141 and w.npc.Experience.CurrentValue == 500, "only the hero's gains are multiplied")
    check(has(status(c), "found through the scan"), "the status names the way the attributes were found")
    stop(c)

    -- two player states in the list, none of them the controller's: nothing is taken
    c = start("scan2", { config = X4, prepare = function(ue)
        local world = T.newWorld(ue)
        world.hero.component.SpawnedAttributes = nil
        local a, b = T.hero(ue, world, 60, { Experience = 111.0 }), T.hero(ue, world, 70, { Experience = 222.0 })
        ue.allOf["AttributeSet_LevelProgression"] = { a.set, b.set }
        return world
    end })
    c.ticks(40)
    check(c.S.setName == nil, "attributes of other player states only: none is taken")
    stop(c)

    -- one hero in the list under a name that does not tell its state: that one is the hero
    c = start("scan1", { config = X4, prepare = function(ue)
        local world = T.newWorld(ue)
        world.hero.component.SpawnedAttributes = nil
        world.hero.set.__full = "AttributeSet_LevelProgression /Game/Maps/World.World:PersistentLevel.BP_PlayerState_C_1.AttributeSet_LevelProgression_0"
        local npc = ue:object("AttributeSet_LevelProgression /Game/Maps/World.World:PersistentLevel.GothicNPCState_8.AttributeSet_LevelProgression_9", {
            Experience = { BaseValue = 5.0, CurrentValue = 5.0 } })
        ue.allOf["AttributeSet_LevelProgression"] = { world.hero.set, npc }
        return world
    end })
    c.ticks(16)
    c.gain(30)
    check(c.S.via == "scan" and c.xp() == 6822, "a single set in some player state is taken (creatures' sets do not count)")
    stop(c)

    -- experience that cannot be read
    c = start("unreadable", { config = X4, diag = true, prepare = function(ue)
        local world = T.newWorld(ue)
        world.kept = world.hero.set.Experience
        world.hero.set.Experience = nil
        world.asked = 0
        local meta = getmetatable(world.hero.set)
        setmetatable(world.hero.set, { __index = function(_, k)
            if k == "Experience" then world.asked = world.asked + 1 return nil end
            return meta.__index[k]
        end })
        return world
    end })
    ue, w = c.ue, c.world
    c.ticks(44)
    check(printedCount(ue, "the hero's experience could not be read from AttributeSet_LevelProgression") == 1 and c.fake.value("xp.readable") == "no" and #ue.errors == 0,
        "experience that cannot be read: said once in the log and noted, no error")
    check(w.asked == 3, "and asked for again every 5 seconds, not four times a second (" .. w.asked .. " times in 11 s)")
    w.hero.set.Experience = w.kept
    c.ticks(21)
    c.gain(30)
    check(c.xp() == 6822 and c.fake.value("xp.readable") == "yes", "readable again: the module goes on within seconds, and notes it")
    w.hero.set.Experience.CurrentValue = 0 / 0
    c.ticks(1)
    check(c.S.setName == nil and #ue.errors == 0, "a value that is not a number is not taken for experience")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("8. map loads")
do
    local c = start("load-map", { config = X4 })
    local ue, w = c.ue, c.world
    c.ticks(1)
    c.gain(30)
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    local reads = w.reads[21]
    w.add("Experience", 30)
    c.ticks(20)
    check(c.xp() == 6852 and w.reads[21] == reads and #ue.errors == 0, "between the two map load hooks the module does nothing and reads nothing")
    -- the new world: other objects
    w.hero.set.__valid, w.hero.state.__valid, w.controller.__valid = false, false, false
    local fresh = T.hero(ue, w, 90, { Experience = 7000.0, Level = 5.0 })
    local control = T.controllerOf(ue, 91, fresh.state)
    ue.allOf["GothicPlayerControllerBaseBP_C"] = { control }
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(2)
    check(c.S.setName == fresh.set:GetFullName() and c.xp(fresh) == 7000, "after the load the hero of the new world is found; the difference to the old one is no gain")
    c.gain(10, fresh)
    check(c.xp(fresh) == 7040, "and gains are multiplied again")
    -- a load whose end is never reported
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    c.ticks(4 * 19)
    w.add("Experience", 10, fresh)
    c.ticks(2)
    local stillWaiting = c.xp(fresh) == 7050
    c.ticks(4)
    c.gain(10, fresh)
    check(stillWaiting and c.xp(fresh) == 7090, "a map load that never reports its end is waited for 20 seconds, not for ever")
    stop(c)

    c = start("no-post-hook", { config = X4, mock = { without = { "RegisterLoadMapPostHook" } } })
    c.ticks(1)
    c.ue:fireLoadMapPre("engine", "world", "url", nil, "")
    c.ticks(2)
    c.gain(30)
    check(c.xp() == 6822 and #c.ue.errors == 0, "a UE4SS without the hook after a map load: the loop does not stop")
    stop(c)

    c = start("no-loop", { config = X4, mock = { without = { "LoopInGameThreadWithDelay" } } })
    check(c.ok and printed(c.ue, "FATAL: this UE4SS build lacks LoopInGameThreadWithDelay") ~= nil and #c.ue.errors == 0, "a UE4SS without the game-thread loop: said, nothing else happens")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("9. another experience multiplier in the same game")
do
    local c = start("ledger", { config = X4, diag = true })
    local w, store = c.world, c.mods.store
    c.ticks(1)
    c.gain(30)
    check(store[LEDGER] == 6822, "what the module writes is announced the way the mod EXPModifier announces its writes")
    c.gain(10)
    check(c.xp() == 6862 and store[LEDGER] == 6862 and not c.S.other and c.fake.value("xp.other_multiplier") == "none", "its own announcement is not taken for somebody else's")
    -- an older save is loaded, and a gain happens to end exactly at the value announced last
    w.set("Experience", 6000.0)
    c.ticks(2)
    c.gain(862)
    check(c.xp() == 6000 + 862 * 4 and not c.S.other, "a gain that ends at the value the module itself announced last is still a gain")
    -- the other mod adds its bonus to a gain first and announces the new value
    local at = c.xp()
    w.add("Experience", 30 + 90)
    store[LEDGER] = c.xp()
    c.ticks(1)
    check(c.xp() == at + 120 and c.S.other == true, "a value the other mod announced is its write: nothing is added on top")
    check(printedCount(c.ue, "another experience multiplier (the mod EXPModifier) is active - it announced a write") == 1, "said once in the log, with the reason")
    check(c.fake.value("xp.other_multiplier") == "EXPModifier" and c.fake.detail("xp.other_multiplier") == "it announced a write", "and noted for the diagnostics")
    local reads = w.reads[21]
    w.add("Experience", 30)
    c.ticks(4)
    w.add("Experience", 30 + 90)
    store[LEDGER] = c.xp()
    c.ticks(4)
    check(c.xp() == at + 270 and c.S.gains == 3 and printedCount(c.ue, "another experience multiplier") == 1 and w.reads[21] == reads,
        "from then on the module adds nothing and reads nothing (also for gains the other mod has not touched yet)")
    check(has(status(c), "standing down: another experience multiplier is active"), "the status says so")
    c.ue:fireConsole("xp 8")
    c.gain(30)
    check(c.S.other == true and c.xp() == at + 300, "a new multiplier does not end the standing down")
    stop(c)

    -- a value left in the store by an earlier run of the Lua mods (they were reloaded) is nobody's write
    c = start("ledger-left", { config = X4, shared = { [LEDGER] = 5555.0 } })
    c.ticks(1)
    c.gain(30)
    c.gain(10)
    check(c.xp() == 6862 and not c.S.other, "a value that was announced before this run started does not make the module stand down")
    c.mods.store[LEDGER] = 7777.0
    c.gain(10)
    check(c.S.other == true and c.xp() == 6872, "a new foreign value after that does")
    stop(c)

    -- the other mod under any folder name: it registers with the mod menu as EXPModifier
    c = start("menu-name", { config = X4, shared = { ["SMM:index"] = "HUDMap,EXPModifier" } })
    check(c.S.other == true and printed(c.ue, "is active - it is registered with the mod menu") ~= nil
        and printed(c.ue, "loaded: standing down: another experience multiplier is active") ~= nil, "EXPModifier in the mod menu's list at the start: the module stands down at once")
    check(c.mods.store["SMM:index"] == "HUDMap,EXPModifier,G1R Experience", "(the module's own page is added to that list)")
    c.ticks(1)
    c.gain(30)
    check(c.xp() == 6732 and allOf(c.ue) == 0, "nothing is added, the game is not looked at")
    stop(c)
    c = start("menu-name-later", { config = X4 })
    c.ticks(1)
    c.gain(30)
    c.mods.store["SMM:index"] = c.mods.store["SMM:index"] .. ",EXPModifier"
    c.gain(30)
    check(c.xp() == 6822 + 30 and c.S.other == true, "registered later in the run: the next gain is left to the other mod")
    stop(c)
    c = start("menu-name-like", { config = X4, shared = { ["SMM:index"] = "EXPModifierPlus,MyEXPModifier" } })
    c.ticks(1)
    c.gain(30)
    check(c.xp() == 6822 and not c.S.other, "names that only contain that name are other mods")
    stop(c)

    -- both run: every gain is multiplied once, whoever looks first
    local function together(weFirst)
        local c2 = start("both", { config = X4 })
        local w2, store2 = c2.world, c2.mods.store
        local their = { last = nil }
        local function theirLook()          -- the other mod's way of working, x3
            local now = c2.xp()
            if their.last ~= nil and now > their.last then
                if store2[LEDGER] ~= nil and math.abs(now - store2[LEDGER]) < 0.5 then their.last = now return end
                local new = now + (now - their.last) * 2
                w2.set("Experience", new)
                store2[LEDGER] = new
                their.last = new
                return
            end
            their.last = now
        end
        theirLook()
        c2.ticks(1)
        local total = 6702
        local ok = true
        for _, g in ipairs({ 30, 10, 50, 30 }) do
            w2.add("Experience", g)
            if weFirst then c2.ticks(1) theirLook() else theirLook() c2.ticks(1) end
            local got = c2.xp() - total
            if got ~= g * 4 and got ~= g * 3 then ok = false end
            total = c2.xp()
            c2.ticks(2)
            theirLook()
        end
        local result = c2.xp()
        stop(c2)
        return ok, result
    end
    local ok1, r1 = together(true)
    local ok2, r2 = together(false)
    check(ok1 and r1 == 6702 + 120 * 4, "both mods active, this module looks first: every gain is multiplied exactly once (" .. r1 .. ")")
    check(ok2 and r2 == 6702 + 120 * 3, "the other mod looks first: every gain is multiplied exactly once, by the other mod (" .. r2 .. ")")

    c = start("no-modref", { config = X4, noModRef = true })
    c.ticks(1)
    c.gain(30)
    check(c.xp() == 6822 and #c.ue.errors == 0, "a UE4SS without shared variables: the module works")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("10. a write that does not work")
do
    local function attribute(world, onWrite)
        local values = { BaseValue = 6702.0, CurrentValue = 6702.0 }
        world.values = values
        world.hero.set.Experience = setmetatable({}, { __index = values, __newindex = onWrite(values) })
        function world.add(_, amount) values.BaseValue, values.CurrentValue = values.BaseValue + amount, values.CurrentValue + amount end
        function world.value() return values.CurrentValue end
        return world
    end
    local c = start("readonly", { config = X4, diag = true, prepare = function(ue)
        return attribute(T.newWorld(ue), function() return function() error("read only (test)") end end)
    end })
    c.ticks(1)
    c.gain(30)
    check(c.xp() == 6732 and c.S.failedWrites == 1 and c.S.gains == 0 and #c.ue.errors == 0, "a write that raises: the gain stays as the game gave it, no error reaches UE4SS")
    c.gain(30)
    c.gain(30)
    check(c.S.failedWrites == 3 and printedCount(c.ue, "the experience could not be written (the write raised an error); the gain stays as the game gave it") == 1,
        "tried again with every gain, said once in the log")
    check(has(status(c), "writes that did not work: 3") and c.fake.value("xp.write") == "failed" and c.fake.count["xp.write"] == 1, "the status counts them; noted once for the diagnostics")
    check(c.mods.store[LEDGER] == nil, "nothing is announced for a write that did not happen")
    stop(c)

    c = start("copy", { config = X4, prepare = function(ue)
        local world = T.newWorld(ue)
        local values = { BaseValue = 6702.0, CurrentValue = 6702.0 }
        -- every read hands out a copy: a write goes nowhere
        local meta = getmetatable(world.hero.set)
        setmetatable(world.hero.set, { __index = function(_, k)
            if k == "Experience" then return { BaseValue = values.BaseValue, CurrentValue = values.CurrentValue } end
            if k == "Level" then return { BaseValue = 4.0, CurrentValue = 4.0 } end
            return meta.__index[k]
        end })
        world.hero.set.Experience, world.hero.set.Level = nil, nil
        function world.add(_, amount) values.BaseValue, values.CurrentValue = values.BaseValue + amount, values.CurrentValue + amount end
        function world.value() return values.CurrentValue end
        return world
    end })
    c.ticks(1)
    c.gain(30)
    c.gain(10)
    check(c.xp() == 6742 and c.S.failedWrites == 2 and c.S.last == 6742 and printed(c.ue, "could not be written (the value did not stay)") ~= nil,
        "a write that does not stay is noticed by reading the value back; the next look starts from what is really there")
    stop(c)

    c = start("half", { config = X4, prepare = function(ue)
        return attribute(T.newWorld(ue), function(values) return function(_, k, v) if k == "BaseValue" then values.BaseValue = v end end end)
    end })
    c.ticks(1)
    c.gain(30)
    check(c.S.failedWrites == 1 and c.S.gains == 0 and c.S.last == 6732, "a write of which only one of the two values stays counts as failed")
    stop(c)

    -- the game keeps the number in single precision
    c = start("single", { config = X4, prepare = function(ue)
        return attribute(T.newWorld(ue), function(values) return function(_, k, v) values[k] = string.unpack("f", string.pack("f", v)) end end)
    end })
    c.ticks(1)
    c.world.add("Experience", 16777216.5 - 6702)
    c.ticks(1)
    c.gain(30)
    check(c.S.failedWrites == 0 and c.S.gains == 1, "a value that comes back rounded to single precision is still the value that was written")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("11. the note on screen")
do
    local c = start("note", { config = X4, widgets = true, diag = true })
    local ue, w, ui = c.ue, c.world, c.ui
    c.ticks(1)
    local perPath = {}
    for _, p in ipairs(ue.lookups) do perPath[p] = (perPath[p] or 0) + 1 end
    local once, paths = true, 0
    for _, n in pairs(perPath) do paths = paths + 1 if n ~= 1 then once = false end end
    check(once and paths == 6 and ui.created == 0, "when the hero is found the six paths of the note are searched, each once; nothing is built yet")
    c.gain(30)
    check(ui.created == 1 and ui.createArgs[1] == w.controller and ui.createArgs[3] == w.controller, "the first bonus builds the widget once, owned by the player controller")
    local text = ui.TextBlock[1]
    check(ui.note() == "+90 experience  (30 -> 120, x4.0)", "text: " .. tostring(ui.note()))
    check(ui.last("SetVisibility", ui.widget).args[1] == 3 and ui.count("AddToViewport") == 1, "shown without taking clicks (visibility 3), added to the viewport once")
    local frame, fill = ui.Border[1], ui.Border[2]
    local fc, ic = ui.last("SetBrushColor", frame).args[1], ui.last("SetBrushColor", fill).args[1]
    check(fc.R == 0 and fc.G == 0 and fc.B == 0 and ic.R == 1 and ic.G == 1 and ic.B > 0.7 and ic.B < 0.8 and ui.last("SetColorAndOpacity", text).args[1].SpecifiedColor.R == 0,
        "a black frame, pale yellow inside, black text")
    local slotCall = ui.last("SetAnchors")
    check(slotCall ~= nil and slotCall.args[1].Minimum.X == 1 and slotCall.args[1].Minimum.Y == 0 and ui.last("SetAlignment").args[1].X == 1 and ui.last("SetAutoSize").args[1] == true,
        "anchored to the top right corner, sized by its text")
    check(text.Font.Size == 12 and text.Font.TypefaceFontName.__s == "Regular" and ui.count("SetFont") == 1, "letter size 12, regular weight")
    c.ticks(11)
    check(ui.note() ~= nil, "still shown after 2.75 seconds")
    c.ticks(1)
    check(ui.note() == nil and ui.last("SetVisibility", ui.widget).args[1] == 1, "hidden after 3 seconds (visibility 1)")
    c.gain(10)
    check(ui.created == 1 and ui.constructed == 4 and ui.note() == "+30 experience  (10 -> 40, x4.0)", "the next bonus uses the same widget with a new text")
    c.gain(10)
    check(ui.note() == "+30 experience  (10 -> 40, x4.0)" and ui.count("SetText") == 3, "a bonus while a note is up replaces it (one line, not two)")
    check(#ue.lookups == 6 and c.kitFake.value("kit.toast") == "shown", "nothing was searched again; the kit notes that notes can be shown")
    -- the widget is destroyed without a map load
    ui.widget.__valid = false
    c.gain(10)
    check(ui.created == 2 and ui.note() == "+30 experience  (10 -> 40, x4.0)" and #ue.errors == 0, "a widget that is gone is built again for the next note")
    ui.widget.__full = "UserWidget /Engine/Transient.SomethingElse_9"
    c.gain(10)
    check(ui.created == 3 and #ue.lookups == 6, "so is one whose wrapper now names another object; nothing is searched again")
    -- the game clears its viewport without destroying the widget
    local added = ui.count("AddToViewport")
    rawset(ui.widget, "__inViewport", false)
    c.gain(10)
    check(ui.created == 3 and ui.count("AddToViewport") == added + 1, "a widget that was taken out of the viewport is put back in")
    -- a map change takes the widget away
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    ui.widget.__valid = false
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(2)
    local at = c.xp()
    c.gain(10)
    check(ui.created == 4 and T.searches(c) == 6 and c.xp() == at + 40, "after a map change the widget is built again, without a new search")
    -- switched off while the note is up
    T.write(c.path, T.config("Config.Multiplier = 4.0\nConfig.ShowMessage = false" .. NOW))
    local upBefore = ui.note() ~= nil
    ue:fireConsole("xp reload")
    check(upBefore and ui.note() == nil, "ShowMessage = false while a note is up: it is hidden at once")
    c.ticks(1)
    local calls = #ui.calls
    at = c.xp()
    c.gain(10)
    check(#ui.calls == calls and c.xp() == at + 40, "ShowMessage = false: the gain is multiplied, the widget is left alone")
    stop(c)

    c = start("note-seconds", { config = T.config("Config.Multiplier = 2.0" .. NOW), widgets = true })
    c.kit.configureNotes({ seconds = 1 })
    c.ticks(1)
    c.gain(30)
    c.ticks(3)
    local stillUp = c.ui.note() == "+30 experience  (30 -> 60, x2.0)"
    c.ticks(1)
    check(stillUp and c.ui.note() == nil, "notes set to one second (page General): hidden after one second")
    stop(c)

    c = start("note-less", { config = T.config("Config.Multiplier = 0.5" .. NOW), widgets = true })
    c.ticks(1)
    c.gain(30)
    check(c.ui.note() == "-15 experience  (30 -> 15, x0.5)", "a multiplier below 1: " .. tostring(c.ui.note()))
    stop(c)

    -- the game's own line instead of the box
    c = start("subtitle", { config = X4, widgets = true })
    c.kit.configureNotes({ style = "subtitle", seconds = 5 })
    c.ticks(1)
    check(#c.ue.lookups == 0, "notes set to the game's own line (page General): the paths of the box are not searched")
    c.gain(30)
    local s = c.ui.subtitles[1]
    check(#c.ui.subtitles == 1 and s.text == "+90 experience  (30 -> 120, x4.0)" and s.title == "" and s.seconds == 5 and s.world == c.world.world and c.ui.created == 0,
        "the note is the game's own line at the top: text, empty title, 5 seconds, the hero's world; no widget is built")
    c.gain(30)
    check(#c.ui.subtitles == 2 and #c.ue.lookups == 2, "two searches in all (the game's subtitle function and the text library), not repeated")
    stop(c)
    c = start("notes-off", { config = X4, widgets = true })
    c.kit.configureNotes({ style = "off" })
    c.ticks(1)
    c.gain(30)
    check(c.xp() == 6822 and #c.ue.lookups == 0 and c.ui.created == 0 and #c.ui.subtitles == 0, "notes switched off altogether: the gain is multiplied, nothing is searched or shown")
    stop(c)

    -- things that are not there: the box is given up, the game's line is used
    for _, case in ipairs({
        { "a widget class is missing", { missing = "/Script/UMG.Border" }, "not found: /Script/UMG.Border" },
        { "the widget library is missing", { missing = "/Script/UMG.Default__WidgetBlueprintLibrary" }, "not found: /Script/UMG.Default__WidgetBlueprintLibrary" },
        { "a widget function raises", { failing = "SetPadding" }, "the widget could not be put together" },
        { "showing raises", { failing = "SetText" }, "the text could not be set" },
    }) do
        c = start("note-missing", { config = X4, widgets = case[2] })
        c.ticks(1)
        c.gain(30)
        local searches = #c.ue.lookups
        c.gain(30)
        c.gain(30)
        check(c.xp() == 6702 + 360 and c.S.gains == 3 and #c.ue.errors == 0, case[1] .. ": the gains are multiplied all the same")
        check(printedCount(c.ue, "[G1R_MegaMod] notes on screen are not available (" .. case[3]) == 1 and #c.ue.lookups == searches and c.kit.toastAvailable() == false,
            case[1] .. ": said once, the box is given up for this run, nothing is searched again (" .. searches .. " searches)")
        check(#c.ui.subtitles == 3 and c.ui.subtitles[3].text == "+90 experience  (30 -> 120, x4.0)", case[1] .. ": every note goes to the game's own line instead")
        stop(c)
    end
    c = start("note-no-text", { config = X4, widgets = { missing = "/Script/Engine.Default__KismetTextLibrary" } })
    c.ticks(1)
    c.gain(30)
    c.gain(30)
    check(c.xp() == 6942 and #c.ui.subtitles == 0 and c.kit.toastAvailable() == false and #c.ue.errors == 0, "the text library is missing: no note of either kind, the gains are multiplied")
    stop(c)
    c = start("note-none", { config = X4 })      -- no widget classes at all
    c.ticks(1)
    c.gain(30)
    c.gain(30)
    check(c.xp() == 6942 and c.kit.toastAvailable() == false and #c.ue.lookups == 2 and #c.ue.errors == 0,
        "nothing of the widget side exists: two searches, once (" .. #c.ue.lookups .. "), and the module goes on")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("12. settings while the game runs: the file, the in-game menu, the console")
do
    local c = start("reload", { config = X4 })
    local ue, w = c.ue, c.world
    local v = c.hook.settings.values
    c.ticks(1)
    T.write(c.path, T.config("Config.Multiplier = 2.0" .. NOW))
    c.ticks(18)
    check(printed(ue, "settings changed") == nil, "the file is not read more often than every 5 seconds")
    c.ticks(1)
    check(printed(ue, "[G1R_XP] settings changed (config.lua): multiplier x2.0\n") ~= nil, "a changed file is picked up within 5 seconds")
    c.ticks(40)
    check(printedCount(ue, "settings changed") == 1, "an unchanged file is not reported again")
    T.write(c.path, "local Config = {}\nConfig.Multiplier = \nreturn Config\n")
    c.ticks(60)
    check(printedCount(ue, "config.lua has an error, keeping the previous settings") == 1 and v.Multiplier == 2.0, "a file with an error: said once, the previous settings stay")
    c.gain(30)
    check(c.xp() == 6762, "and are used")
    os.remove(c.path)
    c.ticks(24)
    check(v.Multiplier == 2.0 and #ue.errors == 0, "a file that is gone: the settings stay")
    T.write(c.path, T.config('Config.Multiplier = 3\nos.exit(1)' .. NOW))
    c.ticks(24)
    check(v.Multiplier == 2.0 and printedCount(ue, "keeping the previous settings") == 2, "a file that reaches for anything but plain values is refused (it runs without access to Lua's libraries)")
    T.write(c.path, T.config("Config.Multiplier = 9" .. NOW))
    check(ue:fireConsole("xp reload") == true and v.Multiplier == 9 and printed(ue, "[G1R_XP] settings read: multiplier x9.0\n") ~= nil, "xp reload reads the file at once")

    -- the console sets the multiplier
    local before = #ue.printed
    check(ue:fireConsole("xp 2.5") == true and v.Multiplier == 2.5, "xp 2.5 sets the multiplier")
    check(ue.printed[before + 1] == "[G1R_XP] settings changed (console): multiplier x2.5\n" and ue.printed[before + 2] == "[G1R_XP] multiplier set: multiplier x2.5\n", "said in the log")
    check(has(T.read(c.path), "Config.Multiplier = 2.5\n") and has(T.read(c.path), "Config.SettleSeconds = 0"), "and written into config.lua: only that line changes")
    ue:fireConsole("xp 99")
    check(v.Multiplier == 10 and has(T.read(c.path), "Config.Multiplier = 10.0\n"), "xp 99: the upper end is used and written")
    c.ticks(1)
    c.gain(30)
    check(c.xp() == 6762 + 300, "the next gain uses it")

    -- the in-game mod menu
    local index = T.menuIndex(c)
    check(#index == 1 and index[1] == "G1R Experience", "the module's page is registered with the in-game mod menu as G1R Experience")
    local page = T.menuPage(c, "Experience")
    local titles = {}
    for _, s in ipairs(page.sections) do titles[#titles + 1] = s.title .. ":" .. #s.items end
    check(table.concat(titles, "|") == "Experience multiplier:2|Large gains (quests):2|On screen:1|Log:1", "its sections and their items: " .. table.concat(titles, "|"))
    local item = T.menuItem(c, "Experience", "Every gain counts")
    check(item.kind == "num" and item.min == 0 and item.max == 10 and item.step == 0.25 and item.value == 10 and item.name == "Every gain counts (times)",
        "the multiplier: a number from 0 to 10 in steps of 0.25, with its value")
    check(T.menuItem(c, "Experience", "Multiply experience gains").kind == "bool" and T.menuItem(c, "Experience", "Multiply experience gains").desc == "off: experience as the game gives it",
        "a switch is a switch, with its short menu text as the hint")
    for _, i in ipairs(page.items) do
        if has(i.name, "MaxGain") or has(i.name, "SettleSeconds") or has(i.name, "CheckMilliseconds") then check(false, "a hidden setting is in the menu: " .. i.name) end
    end
    local fileChanges = printedCount(ue, "settings changed (config.lua)")
    T.menuSet(c, "Experience", "Every gain counts", 3)
    c.ticks(1)
    check(v.Multiplier == 3 and printed(ue, "[G1R_XP] settings changed (in-game menu): multiplier x3.0\n") ~= nil, "an edit in the menu is applied at the next look")
    check(has(T.read(c.path), "Config.Multiplier = 3.0\n") and T.menuItem(c, "Experience", "Every gain counts").value == 3 and c.mods.store["SMM:cmd:G1R Experience"] == "",
        "written into config.lua, shown in the menu, the edit taken off the queue")
    c.ticks(1)
    c.gain(30)
    check(c.xp() == 7062 + 90, "and used: 30 -> 90")
    T.menuSet(c, "Experience", "Multiply experience gains", false)
    c.ticks(1)
    c.gain(30)
    check(v.Enabled == false and c.xp() == 7152 + 30 and has(T.read(c.path), "Config.Enabled = false\n"), "switched off in the menu: the next gain stays, config.lua says Enabled = false")
    T.menuSet(c, "Experience", "Note when experience was added", false)
    T.menuSet(c, "Experience", "Large gain from (experience)", 150)
    c.ticks(1)
    check(v.ShowMessage == false and v.LargeGainFrom == 150, "two edits at once")
    c.ticks(40)
    check(fileChanges == 2 and printedCount(ue, "settings changed (config.lua)") == 2, "what the module wrote itself is not taken for a change of the file")
    stop(c)

    c = start("badstart", { config = "this is not lua\n" })
    check(c.ok and printed(c.ue, "config.lua has an error (") ~= nil and c.hook.settings.values.Multiplier == 1.0, "a broken file at the start: said, default settings")
    check(T.read(c.path) == "this is not lua\n", "the broken file is left for its owner to repair")
    stop(c)
    c = start("nofile", { config = false })
    check(c.ok and printed(c.ue, "config.lua was not there: written with the default settings") ~= nil and T.read(c.path) == shipped, "no file at the start: the default file is written")
    stop(c)
    c = start("bom", { config = "\239\187\191" .. X4 })
    check(c.hook.settings.values.Multiplier == 4.0, "a byte order mark at the start of the file is skipped")
    stop(c)
    c = start("interval", { config = T.config("Config.CheckMilliseconds = 100.7") })
    check(c.ue.loops[2].ms == 101 and math.type(c.ue.loops[2].ms) == "integer", "CheckMilliseconds is handed to UE4SS as a whole number")
    stop(c)
    c = start("interval2", { config = T.config("Config.CheckMilliseconds = 1") })
    check(c.ue.loops[2].ms == 50, "and not below 50")
    stop(c)
    c = start("noschema", { files = { ["Scripts/schema.lua"] = false } })
    check(c.ok and printed(c.ue, "the settings could not be set up (schema.lua could not be read") ~= nil and #c.ue.loops == 1, "without schema.lua the module says so and does not start")
    stop(c)

    -- the shipped files
    local schema = dofile(MOD .. "modules/xp/Scripts/schema.lua")
    local chunk = load(shipped, "=config.lua", "t", {})
    local values = chunk and chunk() or {}
    local keys = {}
    for k in pairs(values) do keys[#keys + 1] = k end
    table.sort(keys)
    check(table.concat(keys, ",") == "Enabled,LargeGainFrom,LargeGainMultiplier,LogGains,Multiplier,ShowMessage"
        and not shipped:find("\r", 1, true) and not shipped:find("[^\n\32-\126]"), "the shipped config.lua: six settings, plain ASCII, LF line ends (" .. table.concat(keys, ",") .. ")")
    local probe = start("default-text", {})
    check(probe.settings.defaultText(schema) == shipped, "the shipped config.lua is exactly what the schema generates (lua5.4 dev/tools/gen_config.lua)")
    stop(probe)
end

-- ---------------------------------------------------------------------------
section("13. console command and status")
do
    local c = start("console", { config = X4 })
    local ue = c.ue
    local before = #ue.printed
    check(ue:fireConsole("xp") == true and #ue.errors == 0, "xp: handled (a boolean is returned)")
    check(ue.printed[before + 1] == "[G1R_XP] v1.0.0 | multiplier x4.0\n" and has(ue.printed[before + 2], "has not been found yet") and has(ue.printed[before + 3], "gains multiplied: 0 (+0 experience in total)"),
        "before a game is loaded: version and multiplier, no experience yet, no gains")
    check(#ue.device.lines == 3 and ue.device.lines[1] == "[G1R_XP] v1.0.0 | multiplier x4.0", "the same lines go to the console window")
    c.ticks(1)
    c.gain(30)
    c.gain(10)
    local lines = c.hook.status()
    check(#lines == 3 and lines[2] == "experience 6862, level 4, found through the player state" and lines[3] == "gains multiplied: 2 (+120 experience in total); last: 10 -> 40",
        "after two gains: " .. tostring(lines[2]) .. " | " .. tostring(lines[3]))
    check(ue:fireConsole("g1r_xp status") == true and ue:fireConsole("xp something") == true, "g1r_xp works too; an unknown word shows the status")
    before = #ue.printed
    ue:fireConsole("xp reload")
    check(ue.printed[before + 1] == "[G1R_XP] settings read: multiplier x4.0\n", "xp reload reads the file also when it has not changed")
    check(c.hook.console(nil, nil, nil) == true and c.hook.console("xp reload", nil, nil) == true and c.hook.console("xp", { 2, {} }, {}) == true and #ue.errors == 0
        and c.hook.settings.values.Multiplier == 2, "called with nothing, with the command line only, with parameters of another kind: handled")
    check(c.hook.console("xp 3", nil, nil) == true and c.hook.settings.values.Multiplier == 3, "with the command line only, the words are taken from it: xp 3 sets the multiplier")
    check(c.hook.times(4) == "x4.0" and c.hook.times(2.5) == "x2.5" and c.hook.times(0.75) == "x0.75" and c.hook.times(10) == "x10.0" and c.hook.times(0) == "x0.0" and select("#", c.hook.times(1.25)) == 1,
        "multipliers are written as x4.0, x2.5, x0.75")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("14. nothing leaks, only config.lua is written; the diagnostics")
do
    local known = {}
    local probe = T.Mock.new()
    probe:install()                 -- what the mock itself puts into _G does not count
    for k in pairs(_G) do known[k] = true end
    probe:uninstall()
    local given = { XP_TEST = true, ModRef = true, G1R_KIT = true, G1R_SETTINGS = true, G1R_DIAG = true, Key = true, ModifierKey = true, StaticConstructObject = true }
    local c = start("leak", { config = X4, widgets = true, diag = true })
    c.ticks(1)
    c.gain(30)
    c.ticks(40)
    local leaked = {}
    for k in pairs(_G) do
        if not known[k] and not given[k] then leaked[#leaked + 1] = tostring(k) end
    end
    local sequence = table.concat(c.fake.sequence(), " ")
    local dump = c.fake.dump[1] and c.fake.dump[1]() or nil
    local statusLines = c.fake.status[1] and c.fake.status[1]() or {}
    local reads = c.world.reads[21]
    local lookups, finds = #c.ue.lookups, allOf(c.ue)
    for _ = 1, 20 do
        c.fake.dump[1]()
        c.fake.status[1]()
    end
    check(c.world.reads[21] == reads and #c.ue.lookups == lookups and allOf(c.ue) == finds, "the status and the dump are built from what the module holds: no call into the game")
    stop(c)
    local leftAfter = {}
    for k in pairs(_G) do if not known[k] then leftAfter[#leftAfter + 1] = tostring(k) end end
    check(#leaked == 0 and #leftAfter == 0, "the module defines no global (" .. table.concat(leaked, ", ") .. ")")
    local p = io.popen("ls -A " .. T.q(c.dir))
    local listing = p:read("a"):gsub("%s+", " ")
    p:close()
    -- (config.lua.bak is the settings layer's: the file before the last change, as the settings app keeps it)
    check(listing:gsub("config%.lua%.bak ", "") == "config.lua main.lua schema.lua ", "the module writes no file of its own (its folder holds: " .. listing .. ")")
    check(sequence == "xp.set_found_by=player state xp.readable=yes xp.changed_while_settling=no xp.other_multiplier=none xp.write=ok", "the notes of a session, each once: " .. sequence)
    check(c.fake.versions[1] == "1.0.0" and #c.fake.events == 1 and c.fake.events[1] == "first gain: 30 -> 120 (x4.0), experience now 6822, found through the player state",
        "version and the first gain go to the diagnostics")
    local Fake = dofile(HERE .. "../markers/diag_fake.lua")
    local plain, where = Fake.plain(dump)
    check(plain and Fake.roundTrip(dump) and dump.multiplier == 4 and dump.gains == 1 and dump.experience == 6822 and dump.found_through == "player state"
        and dump.other_multiplier == false and dump.settle_seconds == 0, "the dump is plain data: what the module holds (" .. tostring(where) .. ")")
    check(#statusLines == 3 and statusLines[1] == "v1.0.0 | multiplier x4.0", "the status function gives the status lines")
end

-- ---------------------------------------------------------------------------
section("15. through the megamod loader, with the real diagnostics")
do
    local TMP = T.TMP
    local root = TMP .. "/mega/G1R_MegaMod"
    T.sh("rm -rf " .. T.q(TMP .. "/mega") .. " && mkdir -p " .. T.q(root) .. " && cp -r " .. T.q(MOD .. "Scripts") .. " " .. T.q(root .. "/") .. " && mkdir -p " .. T.q(root .. "/modules")
        .. " && cp -r " .. T.q(MOD .. "modules/xp") .. " " .. T.q(root .. "/modules/"))
    -- only this module: the list of modules is cut down to it
    T.write(root .. "/Scripts/core/modules.lua", 'return { { name = "xp", switch = "Xp", separate = { "EXPModifier" } } }\n')
    T.write(root .. "/modules/xp/Scripts/config.lua", X4)

    local function boot(prepare)
        local ue = T.Mock.new()
        ue:install()
        local ui = T.widgets(ue)
        local world = T.newWorld(ue)
        local mods = T.shared()
        rawset(_G, "ModRef", mods)
        if prepare then prepare(ue, world) end
        local ok, err = pcall(dofile, root .. "/Scripts/main.lua")
        local c = { ue = ue, ui = ui, world = world, mods = mods, ok = ok, err = err, dir = root .. "/Scripts/diagnostics" }
        function c.looks(n)
            for _ = 1, n do
                ue:advance(0.25)
                ue:tick()
            end
        end
        function c.xp() return world.value("Experience") end
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

    local c = boot()
    local ue, w = c.ue, c.world
    check(c.ok and has(last(c), "loaded: xp ok | diagnostics normal"), "the loader loads the module: " .. last(c))
    check(rawget(_G, "XP_TEST") == nil and rawget(_G, "G1R_KIT") == nil and rawget(_G, "G1R_SETTINGS") == nil, "the test hook stays inert; the kit and the settings service are no globals")
    c.looks(2)
    w.add("Experience", 30)
    c.looks(1)
    w.add("Experience", 10)
    c.looks(4)
    check(c.xp() == 6862 and #ue.errors == 0 and c.ui.note() == "+30 experience  (10 -> 40, x4.0)", "gains are multiplied as without the loader: 6702 -> 6862, the note is shown")
    check(ue:fireConsole("g1r diag") == true, "g1r diag handled")
    local report = T.read(c.dir .. "/report-latest.txt") or ""
    check(has(report, "xp: loaded, version 1.0.0") and has(report, "[xp] v1.0.0 | multiplier x4.0") and has(report, "[xp] experience 6862, level 4, found through the player state")
        and has(report, "[xp] gains multiplied: 2 (+120 experience in total); last: 10 -> 40"), "report: the module's version and its status lines")
    check(has(report, "xp.set_found_by = player state") and has(report, "xp.readable = yes") and has(report, "xp.write = ok") and has(report, "xp.changed_while_settling = no")
        and has(report, "xp.other_multiplier = none") and has(report, "kit.toast = shown"), "report: the notes of the module and of the kit")
    check(has(report, "[xp] callbacks LoopInGameThreadWithDelay: 7 calls, 0 errors") and has(report, "[kit] lookups: 6 calls, 6 first-time, 0 not found")
        and has(report, "[loader] callbacks services: 7 calls, 0 errors"), "report: the module's loop, the kit's six searches and the loader's own loop are counted")
    local log = newest(c, "session-")
    check(has(log, "[xp] first gain: 30 -> 120 (x4.0), experience now 6822, found through the player state") and has(log, "[xp] [G1R_XP] v1.0.0 loaded: multiplier x4.0"),
        "session log: the load line and the first gain")
    check(has(log, "[kit] lookup /Script/UMG.Default__WidgetBlueprintLibrary") and not has(log, "ERROR in "), "session log: a search is announced before it runs; no error")
    check(ue:fireConsole("g1r dump") == true, "g1r dump handled")
    local okDump, dump = pcall(load(newest(c, "dump-"), "=dump", "t", {}))
    check(okDump and type(dump) == "table" and type(dump.xp) == "table" and dump.xp.multiplier == 4 and dump.xp.gains == 2 and dump.xp.experience == 6862
        and dump.xp.found_through == "player state" and dump._meta.refusedCount == 0, "dump: what the module holds")
    check(ue:fireConsole("g1r") == true and printed(ue, "[G1R_MegaMod] xp: loaded, version 1.0.0, 0 error(s), 5 note(s)") ~= nil, "g1r lists the module with its notes")
    -- settings through the loader: the in-game menu and the file
    c.mods.store["SMM:cmd:G1R Experience"] = "2\31n2"
    c.looks(1)
    w.add("Experience", 30)
    c.looks(1)
    check(printed(ue, "[G1R_XP] settings changed (in-game menu): multiplier x2.0") ~= nil and c.xp() == 6892, "an edit in the in-game menu reaches the module through the loader's loop")
    c.looks(1)
    w.add("Experience", 30)
    c.looks(1)
    check(c.xp() == 6892 + 60 and has(T.read(root .. "/modules/xp/Scripts/config.lua"), "Config.Multiplier = 2.0\n"), "the new multiplier is used and written into the module's config.lua")
    shutdown(c)

    -- the other author's mod is installed and enabled next to the megamod: the module is not loaded
    T.sh("mkdir -p " .. T.q(TMP .. "/mega/EXPModifier/scripts"))
    T.write(TMP .. "/mega/EXPModifier/scripts/main.lua", "-- another mod\n")
    T.write(TMP .. "/mega/EXPModifier/enabled.txt", "")
    T.write(root .. "/modules/xp/Scripts/config.lua", X4)
    c = boot()
    check(c.ok and has(last(c), "xp left to the separate mod EXPModifier")
        and printed(c.ue, "module xp not loaded: the separate mod EXPModifier is installed and enabled") ~= nil,
        "EXPModifier enabled next to the megamod (its folder is called scripts): " .. last(c))
    c.looks(2)
    c.world.add("Experience", 30)
    c.looks(2)
    check(c.xp() == 6732 and c.mods.store["SMM:index"] == nil, "nothing is added to a gain, no page is registered with the in-game menu")
    shutdown(c)
    os.remove(TMP .. "/mega/EXPModifier/enabled.txt")
    c = boot()
    check(has(last(c), "xp ok"), "the same folder without enabled.txt and without a line in mods.txt: the module is loaded")
    shutdown(c)
    T.write(TMP .. "/mega/mods.txt", "EXPModifier : 1\r\n")
    c = boot()
    check(has(last(c), "xp left to the separate mod EXPModifier"), "enabled through mods.txt: not loaded")
    shutdown(c)
    os.remove(TMP .. "/mega/mods.txt")
    T.sh("rm -rf " .. T.q(TMP .. "/mega/EXPModifier"))

    -- switched off in the megamod's own settings
    T.write(root .. "/Scripts/config.lua", T.config("Config.Modules = { Xp = false }"))
    c = boot()
    check(has(last(c), "loaded: xp off |"), "Config.Modules.Xp = false: the module is not loaded")
    shutdown(c)

    -- diagnostics off: the module runs as on its own
    T.write(root .. "/Scripts/config.lua", T.config('Config.Diagnostics = { Level = "off" }'))
    c = boot()
    c.looks(2)
    c.world.add("Experience", 30)
    c.looks(2)
    check(printed(c.ue, "xp ok | diagnostics off") ~= nil and c.xp() == 6822 and #c.ue.errors == 0, "diagnostics off: gains are multiplied, no error")
    shutdown(c)

    -- a loader without its kit: the module says what it needs
    os.remove(root .. "/Scripts/core/kit.lua")
    c = boot()
    check(c.ok and printed(c.ue, "[G1R_MegaMod] core/kit.lua could not be used") ~= nil
        and printed(c.ue, "[G1R_XP] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started") ~= nil,
        "core/kit.lua missing: the loader says so, the module says what it needs and does not start")
    check(has(last(c), "xp ok") and not has(table.concat(c.ue.printed), "failed to load"), "that is not an error of the module: " .. last(c))
    c.looks(2)
    c.world.add("Experience", 30)
    c.looks(2)
    check(c.xp() == 6732 and #c.ue.errors == 0, "and nothing is added, no error")
    shutdown(c)
end

T.finish()
