-- ============================================================================
-- Offline tests of the module regen (modules/regen/Scripts/main.lua).
--
--   lua5.4 harness.lua          (from any directory)
--
-- The module runs on the loader's kit and settings service; ../lib/modtest.lua
-- sets both up the way the loader does and replaces UE4SS by ../mock/ue4ss.lua.
-- The game is a model built here on top of modtest's (function `game` below):
-- every behaviour in it names where it is known from (dev/facts/regen.md has
-- the same sources). Sections 1-19 run the module that way, section 20 through
-- the real loader with the real diagnostics.
-- Last line: "regen tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("regen")
local check, section, has, printed, printedCount = T.check, T.section, T.has, T.printed, T.printedCount
local MOD = T.MOD

-- ---------------------------------------------------------------------------
-- The model of the game
-- ---------------------------------------------------------------------------
-- options: values (the hero's attributes), noController, noClock (no game time subsystem), noStatics (no
-- GameplayStatics object), level (MagicianLevel).
local function game(ue, options)
    options = options or {}
    local world = T.newWorld(ue, { values = options.values, noController = options.noController })
    world.tags = {}             -- gameplay tags the hero's ability system owns: name -> count
    world.calls = {}            -- function name -> calls made by the module
    world.asked = {}            -- attribute name -> how often its struct was read from a set
    world.tagAsked = {}         -- tag name -> how often it was asked for
    world.hud = {}              -- what the bars on screen show: attribute name -> value
    world.hudEvents = 0         -- how often a bar was told about a change
    world.bonus = {}            -- attribute name -> what an active effect adds on top of the base value
    world.stores = {}           -- set -> its attributes
    world.outOfManaEnds = 0     -- how often the bar was told that the casting block ended
    local function called(name) world.calls[name] = (world.calls[name] or 0) + 1 end
    function world.called(name) return world.calls[name] or 0 end
    local function rounded(v) return math.floor(v + 0.5) end

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
    local function storeFor(name, who)
        local h = who or world.hero
        for _, set in ipairs({ h.mana, h.health, h.progression }) do
            local store = world.stores[set]
            if store and store[name] ~= nil then return store, set end
            if rawget(set, name) ~= nil then return set, set end
        end
        error("the model has no attribute " .. tostring(name))
    end

    -- What the game's attribute sets do to a new value before it is stored. Read from the executable:
    -- AttributeSet_Mana PreAttributeBaseChange 0x145b67190 / PreAttributeChange 0x145b67d80 and AttributeSet_Health
    -- 0x145b66ff0 / 0x145b676d0: every attribute of the two sets is rounded half up; Mana is kept in 0 .. MaxMana,
    -- Health in 0 .. MaxHealth (current values of the maxima), Health not while the tag State.RestoringSave is there.
    local function settle(store, name, v)
        v = rounded(v)
        local top = (name == "Mana" and store.MaxMana) or (name == "Health" and store.MaxHealth) or nil
        if top and not (name == "Health" and world.tags["State.RestoringSave"]) then
            v = math.max(0, math.min(v, top.CurrentValue))
        end
        return v
    end
    -- UAbilitySystemComponent::SetNumericAttributeBase (0x1443e86f0 -> the effects container's
    -- SetAttributeBaseValue 0x144453cb0): base value through PreAttributeBaseChange, current value through
    -- PreAttributeChange, then the attribute's change delegate - which is what the bars on screen listen to
    -- (UGameplayAttributeProgressBarWidget, handler 0x145c22ca0).
    function world.setBase(name, v, who)
        local store = storeFor(name, who)
        local a = store[name]
        a.BaseValue = settle(store, name, v)
        a.CurrentValue = settle(store, name, a.BaseValue + (world.bonus[name] or 0))
        if who == nil then
            world.hud[name] = a.CurrentValue
            world.hudEvents = world.hudEvents + 1
        end
    end
    -- An execution of one of the game's own effects on an attribute: a spell burning mana, a potion, a hit.
    -- After it the attribute set's PostGameplayEffectExecute runs. Mana (0x145b66cd0): at zero the loose tag
    -- State.OutMana is added (once more with every execution), above zero the ability system's RemoveTag takes
    -- it off. Health (0x145b64d40): nothing for a hero with State.Dead; at zero the hero dies or is defeated.
    function world.effect(name, delta, who)
        local store = storeFor(name, who)
        world.setBase(name, store[name].BaseValue + delta, who)
        local value = store[name].CurrentValue
        if who ~= nil then return value end
        if name == "Mana" then
            if value <= 0 then world.tags["State.OutMana"] = (world.tags["State.OutMana"] or 0) + 1
            else world.tags["State.OutMana"] = nil end
        elseif name == "Health" and value <= 0 and not world.tags["State.Dead"] then
            world.tags[world.defeatOnly and "State.Defeated" or "State.Dead"] = 1
        end
        return value
    end
    -- the plain accessors of modtest, on the stores
    function world.value(name, who) return storeFor(name, who)[name].CurrentValue end
    function world.base(name, who) return storeFor(name, who)[name].BaseValue end
    function world.set(name, v, who)
        local a = storeFor(name, who)[name]
        a.BaseValue, a.CurrentValue = v, v
    end
    function world.add(name, d, who)
        local a = storeFor(name, who)[name]
        a.BaseValue, a.CurrentValue = a.BaseValue + d, a.CurrentValue + d
    end

    -- A hero's attribute sets and ability system as the module meets them.
    function world.adopt(h)
        -- AttributeSet_Mana also has MagicianLevel (-1 untrained, 0 the basics, 1 to 6 the circles: the game's
        -- skill effects UGE_Skill_Mage_Circle_*) and RecoveryRatePerHourOfSleep (property layout).
        h.mana.MagicianLevel = { BaseValue = -1.0, CurrentValue = options.level or -1.0 }
        h.mana.RecoveryRatePerHourOfSleep = { BaseValue = 0.125, CurrentValue = 0.125 }
        h.health.RecoveryRatePerHourOfSleep = { BaseValue = 0.125, CurrentValue = 0.125 }
        for _, set in ipairs({ h.mana, h.health }) do
            local store = instrument(set)
            -- UAngelscriptAttributeSet::TrySetAttributeBaseValue(FName, float) -> bool (parameters read from the
            -- executable; native 0x14491c080): false without an owning ability system or when the set has no such
            -- attribute, else SetNumericAttributeBase and true. The name must be an FName (UE4SS push_nameproperty
            -- raises on anything else).
            rawset(set, "TrySetAttributeBaseValue", function(self, name, value)
                called("TrySetAttributeBaseValue")
                if type(name) ~= "table" or name.__s == nil then error("parameter 1 is not an FName") end
                if type(value) ~= "number" then error("parameter 2 is not a number") end
                if world.noOwner or store[name.__s] == nil then return false end
                world.setBase(name.__s, value, h ~= world.hero and h or nil)
                return true
            end)
        end
        -- UAngelscriptAbilitySystemComponent::HasGameplayTag(FGameplayTag) -> bool (exec 0x1448f4f30 calls
        -- HasMatchingGameplayTag: a tag below the asked one counts) and UGothicAbilitySystemComponent::RemoveTag
        -- (0x145b694f0: takes every count of the tag off; the bar's tag listener 0x145c56420 then ends its
        -- out-of-mana state). A gameplay tag arrives as a table with its name (UE4SS: a struct from a table).
        local function nameOf(tag)
            if type(tag) ~= "table" or type(tag.TagName) ~= "table" or tag.TagName.__s == nil then error("parameter 1 is not a gameplay tag") end
            return tag.TagName.__s
        end
        rawset(h.component, "HasGameplayTag", function(self, tag)
            called("HasGameplayTag")
            local text = nameOf(tag)
            world.tagAsked[text] = (world.tagAsked[text] or 0) + 1
            if h ~= world.hero then return false end
            for owned, n in pairs(world.tags) do
                if n > 0 and (owned == text or owned:sub(1, #text + 1) == text .. ".") then return true end
            end
            return false
        end)
        rawset(h.component, "RemoveTag", function(self, tag)
            called("RemoveTag")
            local text = nameOf(tag)
            if world.tags[text] ~= nil and text == "State.OutMana" then world.outOfManaEnds = world.outOfManaEnds + 1 end
            world.tags[text] = nil
        end)
        return h
    end
    world.adopt(world.hero)
    world.hud.Mana, world.hud.Health = world.value("Mana"), world.value("Health")

    -- /Script/Engine.Default__GameplayStatics:IsGamePaused(world) - what the kit's paused() asks (facts K6).
    if not options.noStatics then
        ue.objects["/Script/Engine.Default__GameplayStatics"] = ue:object("GameplayStatics /Script/Engine.Default__GameplayStatics", {
            IsGamePaused = function(_, w)
                called("IsGamePaused")
                return world.paused == true
            end })
    end
    -- GameTimeSubsystem.CurrentGameTime.TotalSeconds - the game's clock (facts K5, in-game). It runs with the
    -- mock's clock (12 game seconds per second here) unless the test lets it stand.
    world.clock = { stands = false, value = 345600 + ue.clock * 12 }
    if not options.noClock then
        local time = setmetatable({}, { __index = function(_, k)
            if k ~= "TotalSeconds" then return nil end
            called("TotalSeconds")
            if not world.clock.stands then world.clock.value = 345600 + ue.clock * 12 end
            return world.clock.value
        end })
        world.timeSubsystem = ue:object("GameTimeSubsystem /Engine/Transient.GameInstance_1:GameTimeSubsystem_1", { CurrentGameTime = time })
        ue.firstOf["GameTimeSubsystem"] = world.timeSubsystem
    end
    return world
end

local function start(case, options)
    options = options or {}
    options.module, options.hook = "regen", "REGEN_TEST"
    if options.prepare == nil then
        local gameOptions = options.game
        options.prepare = function(ue) return game(ue, gameOptions) end
    end
    local c = T.boot(case, options)
    c.S = c.hook and c.hook.state
    function c.mana() return c.world.value("Mana") end
    function c.health() return c.world.value("Health") end
    -- The module looks at the game at its first tick and every half second after it (every second tick).
    -- c.at(t): runs the game up to and including the look t seconds after the first one.
    local done, plain = 0, c.ticks
    function c.ticks(n, seconds)
        done = done + (n or 1)
        return plain(n, seconds)
    end
    function c.at(t)
        local wanted = 1 + math.floor(t * 4 + 0.5)
        assert(wanted >= done, "c.at(" .. t .. "): that look is over")
        c.ticks(wanted - done)
    end
    return c
end
local stop = T.stop
local function allOf(ue) return ue.calls.FindAllOf or 0 end
local function status(c) return table.concat(c.hook.status(), "|") end
local function sum(t) local n = 0 for _, v in pairs(t) do n = n + v end return n end

-- The settings of the player this module was written for (his G1R_RegenMana.ini, see the module's report):
-- mana every 3 s +2 % of the maximum up to 75 %, 15 s after a spell; health every 5 s +1 and +1 % up to 50 %,
-- 30 s after damage.
local PLAYER = "Config.ManaPercent = 2\nConfig.ManaFlat = 0\nConfig.ManaSeconds = 3\nConfig.ManaUpTo = 75\nConfig.ManaPause = 15\n"
    .. "Config.HealthPercent = 1\nConfig.HealthFlat = 1\nConfig.HealthSeconds = 5\nConfig.HealthUpTo = 50\nConfig.HealthPause = 30"
-- Most cases want steps to come quickly: no wait after the hero was found.
local QUICK = "\nConfig.SettleSeconds = 0\nConfig.ManaPause = 0\nConfig.HealthPause = 0"
local MANA1 = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.LogSteps = true" .. QUICK)
local shipped = T.read(MOD .. "modules/regen/Scripts/config.lua")

-- ---------------------------------------------------------------------------
section("1. loading with the shipped settings")
do
    local c = start("load")
    local ue, w = c.ue, c.world
    check(c.ok, "the module loads (" .. tostring(c.err) .. ")")
    check(#ue.printed == 1 and ue.printed[1] == "[G1R_Regen] v1.0.0 loaded: nothing to regenerate (every amount is 0 or switched off)\n", "one load line: " .. tostring(ue.printed[1]):gsub("\n", ""))
    check(#ue.loops == 2 and ue.loops[2].ms == 250 and math.type(ue.loops[2].ms) == "integer", "one game-thread loop of its own, every 250 ms")
    check(ue.console.regen ~= nil and ue.console.g1r_regen ~= nil and #ue.loadMapPre == 1 and #ue.loadMapPost == 1, "console commands regen and g1r_regen; the kit's hooks before and after a map load")
    check(#ue.lookups == 0 and allOf(ue) == 0 and (ue.calls.FindFirstOf or 0) == 0 and (ue.calls.RegisterHook or 0) == 0 and #ue.errors == 0, "loading searches for nothing and hooks nothing")
    local v = c.hook.settings.values
    check(v.Enabled == true and v.ManaEnabled == true and v.ManaPercent == 0 and v.ManaFlat == 0 and v.ManaSeconds == 3 and v.ManaUpTo == 100 and v.ManaPause == 10
        and v.ManaArmedPercent == 100 and v.ManaByCircle == false and v.ManaCircleNone == 50 and v.ManaCircleNovice == 75 and v.ManaCircleFirst == 100 and v.ManaCircleStep == 10,
        "the shipped file gives the documented defaults for mana")
    check(v.HealthEnabled == true and v.HealthPercent == 0 and v.HealthFlat == 0 and v.HealthSeconds == 5 and v.HealthUpTo == 100 and v.HealthPause == 20 and v.HealthArmedPercent == 100
        and v.ShowMessage == false and v.LogSteps == false, "for health, the note and the log")
    check(v.Method == "auto" and v.ManaClearBlock == true and v.StopWhenPaused == true and v.StopWhenClockStands == true and v.SettleSeconds == 5 and v.LookSeconds == 0.5,
        "and for the settings that are not shown")
    w.effect("Mana", -5)
    w.effect("Health", -30)
    c.seconds(120)
    check(c.mana() == 5 and c.health() == 50 and #ue.errors == 0, "every amount 0: mana and health stay as the game has them (two minutes)")
    check(allOf(ue) == 0 and #ue.lookups == 0 and (ue.calls.FindFirstOf or 0) == 0 and w.reads[21] == nil and sum(w.asked) == 0 and sum(w.calls) == 0,
        "with nothing to regenerate the module does not look at the game at all: no search, no read, no call")
    local idleLines = c.hook.status()
    check(#idleLines == 4 and idleLines[1] == "v1.0.0 | nothing to regenerate (every amount is 0 or switched off)" and idleLines[2] == "nothing to regenerate: the game is not looked at"
        and idleLines[3] == "restored: mana +0 in 0 steps, health +0 in 0 steps"
        and idleLines[4] == "time counted: 0 s; looks that counted nothing: 0 in the engine's pause, 0 with the game's clock standing still", "the status says so, in four lines")
    check(T.read(c.path) == shipped, "the settings file is left as it is")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("2. the settings of the player this was written for: mana 2 % every 3 s to 75 %, health +1 +1 % every 5 s to 50 %")
do
    local c = start("player", { config = T.config(PLAYER .. "\nConfig.LogSteps = true"), game = { values = { Health = 20.0 } }, diag = true })
    local ue, w = c.ue, c.world
    check(printed(ue, "[G1R_Regen] v1.0.0 loaded: mana +2% every 3 s up to 75%, pause 15 s; health +1 and +1% every 5 s up to 50%, pause 30 s\n") ~= nil,
        "the load line names both: " .. tostring(ue.printed[1]):gsub("\n", ""))
    c.at(0)
    check(c.S.Mana.setName == w.hero.mana:GetFullName() and c.S.Health.setName == w.hero.health:GetFullName() and c.S.Mana.via == "player state",
        "the first look finds the hero's mana and health through his player state")
    check(allOf(ue) == 1 and #ue.lookups == 1 and ue.lookups[1] == "/Script/Engine.Default__GameplayStatics" and ue.calls.FindFirstOf == 1,
        "with one search for the controller, one by path (the engine's pause question) and one for the game's clock")
    c.at(17.5)
    check(c.mana() == 10 and c.health() == 20 and w.called("TrySetAttributeBaseValue") == 0, "nothing in the first 15 s (the wait after a load) and before the first step is due")
    c.at(18)
    check(c.mana() == 10 and c.S.Mana.carry > 0.59 and c.S.Mana.carry < 0.61, "18 s: the first mana step is 2 % of 30 = 0.6 - less than a point, carried over")
    c.at(20.5)
    check(c.mana() == 10, "not before the next step")
    c.at(21)
    check(c.mana() == 11 and w.base("Mana") == 11 and w.hud.Mana == 11, "21 s: 1.2 carried - one point is added: 11, base value and current value, and the bar on screen knows")
    check(printed(ue, "[G1R_Regen] mana +1 -> 11 of 30 (ability system)\n") ~= nil, "log line as written: mana +1 -> 11 of 30 (ability system)")
    c.at(30)
    check(c.mana() == 13, "30 s: five steps of 0.6 have added exactly 3 (13)")
    check(c.health() == 20, "health waits 30 s after the load and then 5 s for its first step")
    c.at(35)
    check(c.health() == 22 and w.base("Health") == 22 and w.hud.Health == 22 and printed(ue, "[G1R_Regen] health +2 -> 22 of 100 (ability system)\n") ~= nil,
        "35 s: +1 and 1 % of 100 = 2 health: 22")
    c.at(57)
    check(c.mana() == 18, "57 s: fourteen mana steps = 8.4, eight points added (18)")
    c.at(120)
    check(c.mana() == 22 and c.health() == 50, "two minutes: mana stands at 22 (75 % of 30 is 22.5: not above it), health at 50 (50 % of 100)")
    local calls = w.called("TrySetAttributeBaseValue")
    c.at(300)
    check(c.mana() == 22 and c.health() == 50 and w.called("TrySetAttributeBaseValue") == calls and calls == 12 + 15, "and stay there: nothing more is written (27 writes in all)")
    check(w.value("MaxMana") == 30 and w.value("MaxHealth") == 100 and w.value("Experience") == 6702 and w.value("MagicianLevel") == -1 and #ue.errors == 0,
        "nothing else of the hero is touched, no error")
    local lines = c.hook.status()
    check(#lines == 5 and lines[2] == "mana 22 of 30: at its limit" and lines[3] == "health 50 of 100: at its limit"
        and lines[4] == "restored: mana +12 in 12 steps, health +30 in 15 steps; written by ability system"
        and lines[5] == "time counted: 300 s; looks that counted nothing: 0 in the engine's pause, 0 with the game's clock standing still", "status: " .. table.concat(lines, " | ", 2))
    check(allOf(ue) == 1 and #ue.lookups == 1 and ue.calls.FindFirstOf == 1, "all of it with the three searches of the first look")
    stop(c)

    -- The lines the installer writes for this player (the module's report, section 5): every setting of the shipped
    -- file, with his values of G1R_RegenMana.ini.
    local INSTALLER = {
        "Config.Enabled = true", "Config.ManaEnabled = true", "Config.ManaPercent = 2.0", "Config.ManaFlat = 0.0", "Config.ManaSeconds = 3.0", "Config.ManaUpTo = 75",
        "Config.ManaPause = 15", "Config.ManaArmedPercent = 100", "Config.ManaByCircle = false", "Config.ManaCircleNone = 0", "Config.ManaCircleNovice = 50",
        "Config.ManaCircleFirst = 100", "Config.ManaCircleStep = 10", "Config.HealthEnabled = true", "Config.HealthPercent = 1.0", "Config.HealthFlat = 1.0",
        "Config.HealthSeconds = 5.0", "Config.HealthUpTo = 50", "Config.HealthPause = 30", "Config.HealthArmedPercent = 100", "Config.ShowMessage = false", "Config.LogSteps = false",
    }
    c = start("installer", { config = T.config(table.concat(INSTALLER, "\n")) })
    local shippedKeys, missing = {}, {}
    for key in shipped:gmatch("\nConfig%.([%w_]+) = ") do shippedKeys[#shippedKeys + 1] = key end
    for _, key in ipairs(shippedKeys) do
        if not has(table.concat(INSTALLER, "\n") .. "\n", "Config." .. key .. " = ") then missing[#missing + 1] = key end
    end
    check(#shippedKeys == 22 and #INSTALLER == 22 and #missing == 0, "the installer's lines for this player give every setting of the shipped file a value (" .. table.concat(missing, ", ") .. ")")
    check(printed(c.ue, "[G1R_Regen] v1.0.0 loaded: mana +2% every 3 s up to 75%, pause 15 s; health +1 and +1% every 5 s up to 50%, pause 30 s\n") ~= nil
        and printed(c.ue, "is not usable") == nil and c.hook.settings.values.ManaCircleNone == 0 and c.hook.settings.values.ManaCircleNovice == 50 and c.hook.settings.values.ManaCircleStep == 10,
        "they are taken as written: his regeneration, and his circle numbers kept for the day he switches the circle on")
    stop(c)
    -- his circle table (0, 50, 100, 110 ... 150 %), switched on
    for _, level in ipairs({ -1.0, 0.0, 1.0, 2.0, 6.0 }) do
        c = start("installer-circle", { config = T.config(table.concat(INSTALLER, "\n") .. "\nConfig.ManaByCircle = true\nConfig.ManaFlat = 10\nConfig.ManaPercent = 0\nConfig.ManaSeconds = 1\nConfig.ManaUpTo = 100" .. QUICK),
            game = { level = level, values = { Mana = 0.0, MaxMana = 400.0 } } })
        c.at(2)
        local expected = ({ [-1] = 0, [0] = 10, [1] = 20, [2] = 22, [6] = 30 })[level]
        check(c.mana() == expected, ("his circle table at level %d: two steps of 10 give %d"):format(level, expected))
        stop(c)
    end
end

-- ---------------------------------------------------------------------------
section("3. amounts: points, a share of the maximum, fractions, the limit")
do
    -- A run with these settings (no waits) and these attributes; returns the case.
    local function run(case, lines, values, gameOptions)
        gameOptions = gameOptions or {}
        gameOptions.values = values
        return start(case, { config = T.config(lines .. QUICK), game = gameOptions })
    end
    local c = run("flat", "Config.ManaFlat = 1\nConfig.ManaSeconds = 1")
    local w = c.world
    check(printed(c.ue, "loaded: mana +1 every 1 s up to 100%, pause 0 s") ~= nil, "points only: the load line says +1 every 1 s")
    c.at(0.5)
    check(c.mana() == 10, "nothing before the first second is over")
    c.at(1)
    check(c.mana() == 11 and w.base("Mana") == 11, "1 point per second: 11 after one second")
    c.at(5)
    check(c.mana() == 15, "15 after five")
    c.at(20)
    check(c.mana() == 30, "30 (the maximum) after twenty")
    local writes = w.called("TrySetAttributeBaseValue")
    c.at(40)
    check(c.mana() == 30 and w.base("Mana") == 30 and w.called("TrySetAttributeBaseValue") == writes and writes == 20 and c.S.Mana.phase == "full",
        "never above the maximum: at 30 nothing more is written")
    check(c.health() == 80 and w.asked.Health == nil and w.asked.MaxHealth == nil, "health has no amount: it is not even read")
    stop(c)

    c = run("percent", "Config.HealthPercent = 10\nConfig.HealthSeconds = 2", { Health = 35.0, MaxHealth = 150.0 })
    check(printed(c.ue, "loaded: health +10% every 2 s up to 100%, pause 0 s") ~= nil, "a share only: the load line says +10% every 2 s")
    c.at(2)
    check(c.health() == 50, "10 % of 150 maximum health = 15 per step: 35 -> 50")
    c.at(4)
    check(c.health() == 65 and c.mana() == 10 and c.world.asked.Mana == nil, "65 after the second step; mana is not read")
    stop(c)

    c = run("both", "Config.HealthPercent = 10\nConfig.HealthFlat = 2.5\nConfig.HealthSeconds = 2", { Health = 35.0, MaxHealth = 150.0 })
    check(printed(c.ue, "loaded: health +2.5 and +10% every 2 s up to 100%, pause 0 s") ~= nil, "both: +2.5 and +10%")
    c.at(2)
    check(c.health() == 52 and c.S.Health.carry > 0.49 and c.S.Health.carry < 0.51, "2.5 + 15 = 17.5 per step: 17 are added, half a point is carried")
    c.at(4)
    check(c.health() == 70 and c.S.Health.carry < 0.01, "the next step adds 18: 70")
    stop(c)

    c = run("fraction", "Config.ManaPercent = 2.5\nConfig.ManaSeconds = 1")
    local seen = {}
    for t = 1, 8 do
        c.at(t)
        seen[#seen + 1] = ("%d"):format(c.mana())
    end
    check(table.concat(seen, " ") == "10 11 12 13 13 14 15 16", "2.5 % of 30 = 0.75 per step: three points in four steps (" .. table.concat(seen, " ") .. ")")
    stop(c)
    c = run("half", "Config.ManaFlat = 0.5\nConfig.ManaSeconds = 1")
    c.at(1)
    local first = c.mana()
    c.at(2)
    check(first == 10 and c.mana() == 11, "half a point per step: one point every second step")
    stop(c)
    c = run("tiny", "Config.ManaPercent = 0.01\nConfig.ManaSeconds = 0.5")
    c.at(100)
    check(c.mana() == 10 and c.world.called("TrySetAttributeBaseValue") == 0 and c.S.Mana.carry > 0.59 and c.S.Mana.carry < 0.61, "0.01 % of 30 two hundred times = 0.6: still carried, nothing written")
    stop(c)

    c = run("limit", "Config.ManaFlat = 4\nConfig.ManaSeconds = 1\nConfig.ManaUpTo = 50")
    w = c.world
    c.at(1)
    check(c.mana() == 14, "4 points per step: 14")
    c.at(2)
    check(c.mana() == 15 and c.S.Mana.carry == 0, "the next step would give 18, the limit is 50 % of 30 = 15: it gives 15 and carries nothing over")
    c.at(10)
    check(c.mana() == 15 and w.called("TrySetAttributeBaseValue") == 2, "and stops there")
    w.effect("Mana", 10)        -- a potion
    c.at(20)
    check(c.mana() == 25 and w.called("TrySetAttributeBaseValue") == 2, "a value above the limit (a potion) is left alone: never lowered, nothing added")
    stop(c)

    c = run("huge", "Config.ManaFlat = 1000\nConfig.ManaPercent = 100\nConfig.ManaSeconds = 1\nConfig.HealthFlat = 1000\nConfig.HealthSeconds = 1\nConfig.HealthUpTo = 95")
    c.at(1)
    check(c.mana() == 30 and c.health() == 95 and c.world.base("Mana") == 30 and c.world.base("Health") == 95, "the largest amounts: one step to the limit, not a point above it")
    stop(c)

    c = run("limit-rounding", "Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ManaUpTo = 75", { Mana = 21.0, MaxMana = 30.0 })
    c.at(1)
    local at22 = c.mana()
    c.at(5)
    check(at22 == 22 and c.mana() == 22, "75 % of 30 is 22.5: the limit is 22, the half point is not given")
    stop(c)
    c = run("limit-whole", "Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ManaUpTo = 70", { Mana = 20.0, MaxMana = 30.0 })
    c.at(5)
    check(c.mana() == 21, "70 % of 30 is 21: the limit is 21")
    stop(c)

    -- a value with a fraction, as another mod can leave it behind
    c = run("fractional", "Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ManaUpTo = 75", { Mana = 20.7, MaxMana = 30.0 })
    c.at(1)
    check(c.mana() == 22 and c.world.base("Mana") == 22, "a value of 20.7: the game rounds what it is given (21.7 -> 22)")
    c.at(3)
    check(c.mana() == 22, "and 22 is the limit")
    stop(c)

    -- the maximum as it is now: an amulet or a debuff changes the current value of MaxMana, not its base value
    c = run("max-current", "Config.ManaPercent = 10\nConfig.ManaSeconds = 1", nil)
    w = c.world
    w.stores[w.hero.mana].MaxMana.CurrentValue = 50.0
    c.at(1)
    check(c.mana() == 15, "the share is taken of the maximum as it is now (current value 50, base value 30): +5")
    c.at(10)
    check(c.mana() == 50, "and the limit too: 50")
    stop(c)

    c = run("zero-max", "Config.ManaFlat = 1\nConfig.ManaSeconds = 1", { Mana = 0.0, MaxMana = 0.0 })
    c.at(5)
    check(c.mana() == 0 and c.world.called("TrySetAttributeBaseValue") == 0 and #c.ue.errors == 0, "a hero without any mana (maximum 0) gets none")
    stop(c)

    c = run("upto-one", "Config.ManaPercent = 0.5\nConfig.ManaSeconds = 1\nConfig.ManaUpTo = 1", { Mana = 0.0, MaxMana = 400.0 })
    check(printed(c.ue, "loaded: mana +0.5% every 1 s up to 1%, pause 0 s") ~= nil, "a share below 1 % and a limit of 1 %: the load line says +0.5% ... up to 1%")
    c.at(5)
    check(c.mana() == 4, "0.5 % of 400 = 2 per step, up to 1 % of 400 = 4")
    stop(c)

    c = run("upto-zero", "Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ManaUpTo = 0")
    c.at(5)
    check(c.mana() == 10 and sum(c.world.asked) == 0 and allOf(c.ue) == 0 and printed(c.ue, "loaded: nothing to regenerate") ~= nil, "a limit of 0 % is nothing to regenerate: the game is not looked at")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("4. the wait after a loss")
do
    local PAUSED = "Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ManaPause = 5\nConfig.HealthFlat = 1\nConfig.HealthSeconds = 1\nConfig.HealthPause = 8\nConfig.SettleSeconds = 0"
    local c = start("pause", { config = T.config(PAUSED), game = { values = { Health = 50.0 } } })
    local w = c.world
    c.at(5.5)
    check(c.mana() == 10 and c.health() == 50, "after the hero was found the waits run once: nothing in the first 5 seconds")
    c.at(6)
    check(c.mana() == 11 and c.health() == 50, "mana: 5 s wait, then a step every second - the first at 6 s")
    c.at(8.5)
    check(c.mana() == 13 and c.health() == 50, "health waits 8 s")
    c.at(9)
    check(c.mana() == 14 and c.health() == 51, "its first step comes at 9 s")
    c.at(12)
    check(c.mana() == 17 and c.health() == 54 and c.S.Mana.losses == 0, "what the module adds itself is not a loss: the steps go on (12 s: 17 and 54)")
    -- a spell: the game burns 3 mana
    w.effect("Mana", -3)
    c.at(17)
    check(c.mana() == 14 and c.S.Mana.losses == 1, "mana was spent between two looks: no step in the next 5 seconds (14)")
    check(c.health() == 59, "a loss of mana does not stop health (59)")
    c.at(17.5)
    local before = c.mana()
    c.at(18)
    check(before == 14 and c.mana() == 15, "5 s wait and 1 s to the first step: mana goes on 6 s after the loss was seen")
    -- a hit during the wait of the other value, and one more while its own wait runs
    w.effect("Health", -10)
    c.at(21)
    w.effect("Health", -1)
    c.at(29)
    check(c.health() == 54 - 0 + 5 + 1 - 11 and c.S.Health.losses == 2, "a second hit while the wait runs starts it again: still no health step 8 s after the second hit")
    c.at(29.5)
    check(c.health() == 49, "(49)")
    c.at(30)
    check(c.health() == 50, "9 s after the second hit the next step")
    check(c.mana() == 15 + 12, "mana went on all the time")
    -- a gain by the game (a potion) is no reason to wait
    w.effect("Health", 20)
    c.at(31)
    check(c.health() == 71, "a potion (+20) does not stop the steps: 70 and one more")
    -- a spell that burns mana in small portions
    for _ = 1, 4 do
        w.effect("Mana", -1)
        c.ticks(1)
    end
    local low = c.mana()
    c.at(37)
    check(c.mana() == low and c.S.Mana.losses >= 3, "mana that goes down bit by bit: every bit seen starts the wait again")
    c.at(38)
    check(c.mana() == low + 1, "the first step 6 s after the last bit")
    -- less than half a point is not a loss (the game keeps whole numbers; a rounding difference must not start a wait)
    local losses = c.S.Mana.losses
    w.add("Mana", -0.4)
    c.at(39)
    check(c.S.Mana.losses == losses, "a difference of less than half a point is not a loss")
    w.add("Mana", -0.5)
    c.at(40)
    check(c.S.Mana.losses == losses + 1, "half a point is")
    stop(c)

    c = start("pause-zero", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 2\nConfig.ManaPause = 0\nConfig.SettleSeconds = 0") })
    c.at(2)
    check(c.mana() == 11, "a wait of 0: the first step one interval after the hero was found")
    c.at(3)
    c.world.effect("Mana", -5)
    c.at(4.5)
    check(c.mana() == 6, "after a loss the interval starts again: no step 1.5 s after it")
    c.at(5)
    check(c.mana() == 7, "but a full interval (2 s) after it")
    stop(c)

    c = start("settle", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ManaPause = 2\nConfig.HealthFlat = 1\nConfig.HealthSeconds = 1\nConfig.HealthPause = 9"), game = { values = { Health = 50.0 } } })
    c.at(5.5)
    check(c.mana() == 10, "a wait shorter than SettleSeconds (5): after the hero was found the 5 seconds count")
    c.at(6)
    check(c.mana() == 11 and c.health() == 50, "(first mana step at 6 s)")
    c.at(10)
    check(c.health() == 51, "a longer wait counts as it is (9 s, first health step at 10 s)")
    stop(c)

    -- The values go down while the wait after "hero found" runs - a loaded game filling in what the save holds
    -- looks just like that. (Found in review: the loss put the shorter wait after a loss in place of what was
    -- left, and the first step came before the five seconds were over.)
    local function firstSteps(case, lines)
        local d = start(case, { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.HealthFlat = 1\nConfig.HealthSeconds = 1\n" .. lines), game = { values = { Health = 80.0 } } })
        d.at(1)
        d.world.setBase("Mana", 6)
        d.world.setBase("Health", 50)
        local firstMana, firstHealth
        for t = 1.5, 13, 0.5 do
            d.at(t)
            if not firstMana and d.mana() > 6 then firstMana = t end
            if not firstHealth and d.health() > 50 then firstHealth = t end
        end
        local losses = d.S.Mana.losses + d.S.Health.losses
        stop(d)
        return firstMana, firstHealth, losses
    end
    local firstMana, firstHealth, losses = firstSteps("settle-loss", "Config.ManaPause = 0\nConfig.HealthPause = 2")
    check(firstMana == 6 and firstHealth == 6 and losses == 2,
        "a loss 1 s after the hero was found, waits of 0 and 2 s: SettleSeconds (5) still runs to its end - first steps at 6 s (mana " .. tostring(firstMana) .. ", health " .. tostring(firstHealth) .. ")")
    firstMana, firstHealth = firstSteps("settle-loss-long", "Config.ManaPause = 5\nConfig.HealthPause = 9")
    check(firstMana == 7 and firstHealth == 11, "waits of 5 and 9 s: the loss starts them again as ever (first steps at 7 and 11 s)")
    firstMana, firstHealth = firstSteps("settle-loss-none", "Config.ManaPause = 0\nConfig.HealthPause = 2\nConfig.SettleSeconds = 0")
    check(firstMana == 2 and firstHealth == 4, "SettleSeconds = 0: only the waits after a loss count (first steps at 2 and 4 s)")

    -- the wait is changed in the settings while it runs
    c = start("pause-lowered", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ManaPause = 600\nConfig.SettleSeconds = 0") })
    c.at(2)
    check(c.S.Mana.pause == 598, "(a wait of ten minutes runs: 598 s left)")
    T.menuSet(c, "Combat", "Wait after mana was spent (seconds)", 3)
    c.at(5.5)
    before = c.mana()
    c.at(6)
    check(before == 10 and c.mana() == 11 and c.S.Mana.pause == 0, "the wait is set to 3 s in the in-game menu while it runs: it ends 3 s after the change, not after the ten minutes (first step at 6 s)")
    c.world.effect("Mana", -1)
    c.at(9.5)
    before = c.mana()
    c.at(10)
    check(before == 10 and c.mana() == 11, "and a loss after that waits the new 3 s")
    -- made longer while it runs: what runs is not stretched, the next loss gets the new wait
    c.world.effect("Mana", -1)
    c.at(11)
    T.menuSet(c, "Combat", "Wait after mana was spent (seconds)", 60)
    c.at(13.5)
    before = c.mana()
    c.at(14)
    check(before == 10 and c.mana() == 11, "the wait is set to 60 s while a wait of 3 s runs: that one ends as it was started")
    c.world.effect("Mana", -1)
    c.at(40)
    check(c.mana() == 10 and c.S.Mana.pause > 30, "the next loss waits the 60 s")
    stop(c)
    -- cut down to nothing: what is left is the shortest wait there is (SettleSeconds)
    c = start("pause-lowered-settle", { config = T.config("Config.HealthFlat = 1\nConfig.HealthSeconds = 1\nConfig.HealthPause = 3600\nConfig.SettleSeconds = 4"), game = { values = { Health = 50.0 } } })
    c.at(3)
    T.write(c.path, T.config("Config.HealthFlat = 1\nConfig.HealthSeconds = 1\nConfig.HealthPause = 0\nConfig.SettleSeconds = 4"))
    c.ue:fireConsole("regen reload")
    c.at(3.5)
    check(c.S.Health.pause == 3.5, "a wait of an hour, set to 0 in the file while it runs: cut to SettleSeconds (4 s) from then on")
    c.at(7.5)
    before = c.health()
    c.at(8)
    check(before == 50 and c.health() == 51, "(first step at 8 s: 4 s from the look before the change, and one interval)")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("5. the time that counts: pause, the game's clock, stalls, jumps")
do
    local c = start("paused", { config = MANA1, diag = true })
    local ue, w = c.ue, c.world
    c.at(3)
    check(c.mana() == 13, "three seconds of play: 13")
    check(c.S.counted == 3 and c.S.pausedLooks == 0 and c.S.stoodLooks == 0 and c.S.halt == nil and #c.hook.status() == 5, "three seconds were counted, every look counted")
    -- the pause menu
    w.paused = true
    local asked = sum(w.asked)
    c.at(63)
    check(c.mana() == 13 and sum(w.asked) == asked, "a minute in the pause menu: nothing is added, and the hero's values are not even read")
    check(c.fake.value("regen.engine_pause") == "seen" and c.fake.count["regen.engine_pause"] == 1, "the diagnostics note once that the engine reported a pause")
    local lines = c.hook.status()
    check(c.S.counted == 3 and c.S.pausedLooks == 120 and #lines == 6 and lines[3] == "health: nothing to regenerate (the amount is 0)"
        and lines[4] == "time is not counted at the moment: the engine is paused" and has(lines[5], "restored: mana +3 in 3 steps")
        and lines[6] == "time counted: 3 s; looks that counted nothing: 120 in the engine's pause, 0 with the game's clock standing still",
        "the status says that no time is counted and why, and how many looks counted nothing: " .. tostring(lines[4]) .. " | " .. tostring(lines[6]))
    w.paused = false
    c.at(64)
    check(c.mana() == 13, "the first look after the pause counts no time: no step half a second later")
    check(c.S.halt == nil and #c.hook.status() == 5 and c.S.counted == 3.5 and c.S.pausedLooks == 120, "the pause is over: the status line about it is gone, time is counted again")
    c.at(64.5)
    check(c.mana() == 14, "the steps go on where they were: a full second of play after the last one")
    -- the game's own clock stands still although the engine is not paused
    w.clock.stands = true
    c.at(80)
    check(c.mana() == 14 and c.fake.value("regen.clock_stood") == "seen" and c.fake.count["regen.clock_stood"] == 1, "the game's clock stands still: no time counts (noted once)")
    lines = c.hook.status()
    check(c.S.counted == 4 and c.S.stoodLooks == 31 and c.S.pausedLooks == 120 and #lines == 6 and lines[4] == "time is not counted at the moment: the game's clock stands still"
        and lines[6] == "time counted: 4 s; looks that counted nothing: 120 in the engine's pause, 31 with the game's clock standing still",
        "the status says so too: " .. tostring(lines[4]) .. " | " .. tostring(lines[6]))
    w.effect("Mana", -4)
    c.at(81)
    check(c.mana() == 10 and c.S.Mana.losses == 1, "the values are still watched meanwhile: a loss is seen")
    w.clock.stands = false
    c.at(82)
    check(c.mana() == 11, "the clock runs again: the steps go on")
    -- the game stalls (a hitch, a breakpoint, the window in the background)
    ue:advance(600)
    c.ticks(1)
    c.at(82.25)
    check(c.mana() == 12 and c.S.Mana.waited == 0, "ten minutes without a look count as one second at most (two look intervals), not as ten minutes: one step, nothing left over")
    -- the hero sleeps or time is skipped: the game's clock jumps
    w.clock.value = w.clock.value + 8 * 3600
    local jumped = c.mana()
    c.ticks(2)
    check(c.mana() <= jumped + 1, "eight hours on the game's clock in one look (sleep, skipped time) give nothing extra")
    check(#ue.errors == 0 and c.fake.value("regen.game_clock") == "readable" and c.fake.count["regen.game_clock"] == 1, "no error; the clock was readable all along (noted once)")
    lines = c.hook.status()
    check(c.S.counted == 6.5 and c.S.stoodLooks == 33 and c.S.halt == nil and #lines == 5
        and lines[5] == "time counted: 6 s; looks that counted nothing: 120 in the engine's pause, 33 with the game's clock standing still",
        "of 683 seconds on the clock six and a half were counted (whole seconds in the status): " .. tostring(lines[5]))
    local dump = c.fake.dump[1]()
    check(dump.seconds_counted == 6.5 and dump.looks_engine_paused == 120 and dump.looks_clock_stood == 33 and dump.not_counting == nil, "the dump has the same numbers")
    -- a map load while the engine is paused: what the last look said is forgotten with the world
    w.paused = true
    c.ticks(2)
    local halted = c.S.halt
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    check(halted == "the engine is paused" and c.S.halt == nil and c.S.pausedLooks == 121 and c.fake.dump[1]().looks_engine_paused == 121, "a map load: the status no longer says that the engine is paused")
    stop(c)

    -- the wait after a loss does not run down in the pause menu
    c = start("paused-wait", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ManaPause = 5\nConfig.SettleSeconds = 0") })
    w = c.world
    c.at(8)
    w.effect("Mana", -2)
    c.at(9)
    local after = c.mana()
    w.paused = true
    c.at(60)
    w.paused = false
    c.at(63)
    check(c.mana() == after and c.S.Mana.pause > 0, "a minute in the pause menu does not use up the wait after a loss")
    c.at(66)
    check(c.mana() > after, "it runs on when the game does")
    stop(c)

    -- the two stops can be switched off (settings that are not shown)
    c = start("no-pause-stop", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.StopWhenPaused = false" .. QUICK) })
    c.world.paused = true
    c.at(5)
    check(c.mana() == 15 and #c.ue.lookups == 0 and c.world.called("IsGamePaused") == 0, "StopWhenPaused = false: the engine is not asked, and not searched for")
    stop(c)
    c = start("no-clock-stop", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.StopWhenClockStands = false" .. QUICK) })
    c.world.clock.stands = true
    c.at(5)
    check(c.mana() == 15 and (c.ue.calls.FindFirstOf or 0) == 0 and c.world.called("TotalSeconds") == 0, "StopWhenClockStands = false: the game's clock is not asked, and not searched for")
    stop(c)

    -- a game without a readable clock, a UE4SS without the engine's pause question
    c = start("no-clock", { config = MANA1, game = { noClock = true }, diag = true })
    c.at(5)
    check(c.mana() == 15, "no game clock to be found: time counts")
    c.at(9.5)
    local asking = c.S.clockOff == false
    c.at(10)
    check(asking and c.S.clockOff == true, "after ten seconds without one the clock is left alone for this world")
    c.at(60)
    check(c.ue.calls.FindFirstOf == 4 and c.fake.value("regen.game_clock") == "not readable" and c.fake.count["regen.game_clock"] == 1,
        "it is searched for four times in ten seconds, then left alone (" .. tostring(c.ue.calls.FindFirstOf) .. " searches in a minute), noted once")
    stop(c)
    c = start("no-statics", { config = MANA1, game = { noStatics = true } })
    c.world.paused = true
    c.at(30)
    check(c.mana() == 30 and #c.ue.lookups == 1 and #c.ue.errors == 0, "the engine's pause question cannot be found: searched once, then time counts")
    stop(c)

    -- how often the module looks is a setting; the loop itself stays at four times a second
    c = start("look-fast", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 0.5\nConfig.LookSeconds = 0.25" .. QUICK) })
    c.at(0.25)
    local readsFast = c.world.asked.Mana
    c.at(2)
    check(readsFast == 2 and c.world.asked.Mana == 9 + 4 and c.mana() == 14, "LookSeconds = 0.25: a look at every tick (nine in two seconds), a step every half second")
    stop(c)
    c = start("look-slow", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.LookSeconds = 2" .. QUICK) })
    c.at(1.75)
    local readsSlow = c.world.asked.Mana
    c.at(2)
    check(c.mana() == 11 and c.S.Mana.waited == 0, "two seconds counted at one look with an interval of one: one step, and nothing of the rest is kept for a second one")
    c.at(8)
    check(readsSlow == 1 and c.world.asked.Mana == 5 + 4 and c.mana() == 14 and c.S.Mana.waited == 0, "LookSeconds = 2: a look every two seconds; a step at each (the interval of one second cannot be kept: no catching up)")
    stop(c)
    -- looks that do not fall on the interval: the rhythm is right on average
    c = start("uneven", { config = MANA1 })
    c.ticks(1)
    c.ticks(250, 0.4)
    check(c.mana() == 30, "ticks 0.4 s apart for 100 s: a step per second on average (20 points to the maximum)")
    stop(c)
    c = start("uneven2", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 3" .. QUICK) })
    c.ticks(1)
    c.ticks(100, 0.4)
    check(c.mana() == 23, "a step every 3 s with looks 0.8 s apart: 13 steps in 40 s (" .. c.mana() .. ")")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("6. a hero who is dead, unconscious or being restored gets nothing")
do
    local BOTH1 = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.HealthFlat = 1\nConfig.HealthSeconds = 1" .. QUICK)
    local c = start("dead", { config = BOTH1, game = { values = { Health = 50.0 } }, diag = true })
    local ue, w = c.ue, c.world
    c.at(3)
    check(c.mana() == 13 and c.health() == 53 and c.fake.value("regen.tags") == "only no so far" and c.fake.count["regen.tags"] == 1,
        "alive: both regenerate; the hero's tags answer - with no so far, which proves nothing yet (noted once)")
    check(w.tagAsked["State.Dead"] == 6 and w.tagAsked["State.Defeated"] == 6 and w.tagAsked["State.RestoringSave"] == 6 and w.tagAsked["State.Combat"] == nil,
        "the three tags are asked once per step and value, the weapon tag not at all (its setting is at 100 %)")
    w.effect("Health", -500)        -- a deadly hit: the game marks the hero State.Dead
    check(w.tags["State.Dead"] == 1 and c.health() == 0, "(the model: a deadly hit leaves 0 health and the tag State.Dead)")
    c.at(60)
    check(c.health() == 0 and w.base("Health") == 0, "a dead hero is never healed: health stays 0 for a minute")
    check(c.mana() == 13, "and his mana does not regenerate either")
    check(table.concat(c.fake.values("regen.tags"), ",") == "only no so far,readable" and c.S.tagYes == true,
        "State.Dead was answered with yes: from then on the tags are noted as readable - a yes is the proof that the questions arrive")
    check(has(status(c), "|mana 13 of 30: the hero gets nothing now (State.Dead)|") and has(status(c), "|health 0 of 100: the hero gets nothing now (no health)|"), "the status says why")
    stop(c)

    -- defeated: the game lays the hero out and stands him up again later
    c = start("defeated", { config = BOTH1, game = { values = { Health = 50.0 } } })
    w = c.world
    w.defeatOnly = true
    c.at(2)
    w.effect("Health", -500)
    check(w.tags["State.Defeated"] == 1 and w.tags["State.Dead"] == nil, "(the model: beaten, not killed - the tag State.Defeated)")
    c.at(30)
    check(c.health() == 0 and c.mana() == 12, "unconscious: no health, no mana")
    w.setBase("Health", 20)         -- the game stands him up with a fifth of his health; he is still marked for a moment
    c.at(40)
    check(c.health() == 20 and c.mana() == 12, "health above 0 but still marked State.Defeated: nothing")
    w.tags["State.Defeated"] = nil
    c.at(42)
    check(c.health() > 20 and c.mana() > 12, "the mark is gone: both regenerate again")
    stop(c)

    -- no health and no tag (the tags come a moment later, or not at all)
    c = start("zero", { config = BOTH1, game = { values = { Health = 50.0 } } })
    w = c.world
    c.at(2)
    w.set("Health", 0.0)
    c.at(30)
    check(c.health() == 0 and w.called("TrySetAttributeBaseValue") == 2 + 2 + 18, "0 health without any tag: health is not touched (mana, which nothing forbids, goes on)")
    stop(c)

    -- one point of health is alive
    c = start("one", { config = BOTH1, game = { values = { Health = 1.0 } } })
    c.at(2)
    check(c.health() == 3 and c.mana() == 12, "a hero with 1 health is alive: both regenerate")
    stop(c)

    -- a save is being restored
    c = start("restoring", { config = BOTH1, game = { values = { Health = 50.0 } } })
    w = c.world
    w.tags["State.RestoringSave"] = 1
    c.at(10)
    check(c.mana() == 10 and c.health() == 50 and has(status(c), "(State.RestoringSave)"), "while the game restores a save (State.RestoringSave): nothing")
    w.tags["State.RestoringSave"] = nil
    c.at(12)
    check(c.mana() > 10 and c.health() > 50, "afterwards: both regenerate")
    stop(c)

    -- the tags cannot be asked
    for _, case in ipairs({
        { "the function is not there", function(world) rawset(world.hero.component, "HasGameplayTag", nil) end, "attempt to call a nil value (field '?')" },
        { "the function raises", function(world) rawset(world.hero.component, "HasGameplayTag", function() error("no such tag (test)", 0) end) end, "no such tag (test)" },
        { "the function gives no yes or no", function(world) rawset(world.hero.component, "HasGameplayTag", function() return 1 end) end, "the answer was 1" },
    }) do
        c = start("tags-" .. case[3]:gsub("%W", ""), { config = BOTH1, game = { values = { Health = 50.0 } }, diag = true, prepare = function(ue2)
            local world = game(ue2, { values = { Health = 50.0 } })
            world.probes = 0
            local plain = rawget(world.hero.component, "HasGameplayTag")
            case[2](world)
            local broken = rawget(world.hero.component, "HasGameplayTag")
            if broken then
                rawset(world.hero.component, "HasGameplayTag", function(...)
                    world.probes = world.probes + 1
                    return broken(...)
                end)
            end
            world.plainHasTag = plain
            return world
        end })
        w = c.world
        c.at(10)
        check(c.mana() == 20 and c.health() == 60 and #c.ue.errors == 0, case[1] .. ": a living hero regenerates all the same")
        check(printedCount(c.ue, "the hero's gameplay tags cannot be asked (") == 1
            and printed(c.ue, "[G1R_Regen] the hero's gameplay tags cannot be asked (" .. case[3] .. "); what cannot be told without them: a drawn weapon, unconsciousness, the block on casting\n") ~= nil
            and c.fake.value("regen.tags") == "not readable" and c.fake.count["regen.tags"] == 1 and c.fake.detail("regen.tags") == case[3],
            case[1] .. ": said once in the log with the reason (no file path in it), noted once")
        check(w.probes == 0 or w.probes == 3, case[1] .. ": asked three times, then not again in this run (" .. w.probes .. ")")
        w.set("Health", 0.0)
        local mana = c.mana()
        c.at(30)
        check(c.health() == 0 and c.mana() == mana, case[1] .. ": without tags the health number decides - at 0 neither health nor mana regenerates")
        stop(c)
    end

    -- one answer that fails is not the end of asking
    c = start("tags-transient", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1" .. QUICK), prepare = function(ue2)
        local world = game(ue2)
        local plain = rawget(world.hero.component, "HasGameplayTag")
        world.fail = 0
        rawset(world.hero.component, "HasGameplayTag", function(...)
            if world.fail > 0 then
                world.fail = world.fail - 1
                error("not now (test)", 0)
            end
            return plain(...)
        end)
        return world
    end })
    w = c.world
    c.at(2)
    w.fail = 2
    c.at(4)
    w.fail = 2
    c.at(8)
    check(c.S.tagsOff == false and c.S.tagFails == 0 and printed(c.ue, "cannot be asked") == nil and c.mana() == 18, "two failures, an answer, two failures: the tags stay in use")
    w.fail = 3
    c.at(12)
    check(c.S.tagsOff == true, "three failures in a row end it")
    stop(c)

    -- mana only, tags unusable, the hero has no health: the health number is read for that
    c = start("mana-only-dead", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1" .. QUICK), game = { values = { Health = 0.0 } }, prepare = function(ue2)
        local world = game(ue2, { values = { Health = 0.0 } })
        rawset(world.hero.component, "HasGameplayTag", nil)
        return world
    end })
    c.at(10)
    check(c.mana() == 10 and c.world.asked.Health == 10 and c.world.called("TrySetAttributeBaseValue") == 0, "mana only, no tags, 0 health: the health number is read at each step and nothing is added")
    c.world.set("Health", 1.0)
    c.at(12)
    check(c.mana() == 12 and c.health() == 1, "1 health: mana regenerates; health itself is not touched (it has no amount)")
    stop(c)

    -- the tags are only asked when there is something to give
    c = start("tags-cost", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1" .. QUICK), game = { values = { Mana = 30.0 } } })
    c.at(30)
    check(c.world.called("HasGameplayTag") == 0, "at the limit no tag is asked")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("7. a drawn weapon, the magic circle")
do
    local c = start("armed", { config = T.config("Config.ManaFlat = 2\nConfig.ManaSeconds = 1\nConfig.ManaArmedPercent = 50\nConfig.HealthFlat = 2\nConfig.HealthSeconds = 1" .. QUICK),
        game = { values = { Mana = 0.0, MaxMana = 200.0, Health = 20.0, MaxHealth = 200.0 } } })
    local w = c.world
    check(printed(c.ue, "loaded: mana +2 every 1 s up to 100%, pause 0 s, 50% with a weapon drawn; health +2 every 1 s up to 100%, pause 0 s") ~= nil, "the load line names the share with a weapon drawn")
    c.at(2)
    check(c.mana() == 4 and c.health() == 24, "nothing drawn: the usual 2 per step")
    w.tags["State.Combat.Melee.Sword.OneHanded"] = 1        -- the game's tag while a one-handed sword is drawn
    c.at(4)
    check(c.mana() == 6 and c.health() == 28, "a sword drawn (a tag below State.Combat): mana at 50 % - 1 per step; health, set to 100 %, as usual")
    check(w.tagAsked["State.Combat"] == 4, "the weapon tag is asked once per mana step, not for health")
    w.tags["State.Combat.Melee.Sword.OneHanded"] = nil
    w.tags["State.Combat"] = 1
    c.at(5)
    check(c.mana() == 7, "the tag State.Combat itself counts as well")
    w.tags["State.Combat"] = nil
    c.at(6)
    check(c.mana() == 9, "put away: 2 per step again")
    stop(c)

    c = start("armed-proof", { config = T.config("Config.ManaFlat = 2\nConfig.ManaSeconds = 1\nConfig.ManaArmedPercent = 50" .. QUICK), diag = true, game = { values = { Mana = 5.0, MaxMana = 200.0 } } })
    c.at(1)
    check(c.fake.value("regen.tags") == "only no so far" and c.fake.count["regen.tags"] == 1, "nothing drawn: every tag question is answered with no - noted as 'only no so far'")
    c.world.tags["State.Combat.Melee.Sword.OneHanded"] = 1
    c.at(2)
    check(c.mana() == 5 + 2 + 1 and table.concat(c.fake.values("regen.tags"), ",") == "only no so far,readable", "a sword is drawn and the weapon tag answers yes: the tags are noted as readable")
    c.world.tags["State.Combat.Melee.Sword.OneHanded"] = nil
    c.at(5)
    check(c.fake.value("regen.tags") == "readable" and c.fake.count["regen.tags"] == 2, "put away again: the note stays (one yes in a run is the proof)")
    stop(c)
    c = start("armed-zero", { config = T.config("Config.HealthFlat = 2\nConfig.HealthSeconds = 1\nConfig.HealthArmedPercent = 0" .. QUICK), game = { values = { Health = 20.0 } } })
    w = c.world
    w.tags["State.Combat.Magic.Rune"] = 1
    c.at(10)
    check(c.health() == 20 and c.S.Health.carry == 0 and w.called("TrySetAttributeBaseValue") == 0, "0 % with a spell drawn: nothing, and nothing is saved up for later")
    w.tags["State.Combat.Magic.Rune"] = nil
    c.at(11)
    check(c.health() == 22, "put away: the usual amount at the next step")
    stop(c)
    c = start("armed-more", { config = T.config("Config.HealthFlat = 2\nConfig.HealthSeconds = 1\nConfig.HealthArmedPercent = 250" .. QUICK), game = { values = { Health = 20.0 } } })
    c.world.tags["State.Combat.Melee.Fist"] = 1
    c.at(2)
    check(c.health() == 30, "250 % with the fists up: 5 per step")
    stop(c)
    c = start("armed-blind", { config = T.config("Config.HealthFlat = 2\nConfig.HealthSeconds = 1\nConfig.HealthArmedPercent = 0" .. QUICK), prepare = function(ue2)
        local world = game(ue2, { values = { Health = 20.0 } })
        world.tags["State.Combat"] = 1
        rawset(world.hero.component, "HasGameplayTag", nil)
        return world
    end })
    c.at(4)
    check(c.health() == 28, "tags that cannot be asked: no weapon is assumed (the usual amount)")
    stop(c)

    -- the magic circle: MagicianLevel -1 untrained, 0 the basics, 1 to 6 the circles
    local CIRCLE = "Config.ManaFlat = 10\nConfig.ManaSeconds = 1\nConfig.ManaByCircle = true"
    local function gain(level, extra)
        local c2 = start("circle" .. tostring(level), { config = T.config(CIRCLE .. (extra or "") .. QUICK), diag = true,
            game = { level = level, values = { Mana = 0.0, MaxMana = 400.0 } } })
        c2.at(2)
        local got, noted, base = c2.mana(), c2.fake.value("regen.circle"), c2.world.base("MagicianLevel")
        stop(c2)
        return got, noted, base
    end
    local got, noted, base = gain(-1.0)
    check(got == 10 and noted == "-1", "no magic training (-1): 50 % - two steps of 10 give 10")
    got = gain(0.0)
    check(got == 15, "the basics (0): 75 % - 15")
    got = gain(1.0)
    check(got == 20, "first circle: 100 % - 20")
    got = gain(2.0)
    check(got == 22, "second circle: 110 % - 22")
    got, noted, base = gain(6.0)
    check(got == 30 and noted == "6" and base == -1, "sixth circle: 150 % - 30 (the circle is the current value; the base value in this model stays -1)")
    got = gain(2.6)
    check(got == 24, "a level of 2.6 is taken as 3: 120 %")
    got = gain(-1.0, "\nConfig.ManaCircleNone = 0")
    check(got == 0, "0 % for the untrained: nothing")
    got = gain(4.0, "\nConfig.ManaCircleNone = 0\nConfig.ManaCircleNovice = 0\nConfig.ManaCircleFirst = 40\nConfig.ManaCircleStep = 20")
    check(got == 20, "own numbers: 40 % in the first circle and 20 more per circle = 100 % in the fourth")
    got = gain(1.0, "\nConfig.ManaCircleFirst = 1000\nConfig.ManaCircleStep = 500")
    check(got == 200, "the upper ends: 1000 % in the first circle")

    c = start("circle-learn", { config = T.config(CIRCLE .. QUICK), game = { level = 1.0, values = { Mana = 0.0, MaxMana = 400.0 } }, diag = true })
    w = c.world
    c.at(1)
    w.stores[w.hero.mana].MagicianLevel.CurrentValue = 3.0      -- the hero learns the third circle
    c.at(2)
    check(c.mana() == 10 + 12 and table.concat(c.fake.values("regen.circle"), ",") == "1,3", "a circle learned while the game runs counts from the next step on (noted)")
    stop(c)
    c = start("circle-off", { config = T.config("Config.ManaFlat = 10\nConfig.ManaSeconds = 1" .. QUICK), game = { level = 6.0, values = { Mana = 0.0, MaxMana = 400.0 } } })
    c.at(2)
    check(c.mana() == 20 and c.world.asked.MagicianLevel == nil, "ManaByCircle = false: everyone gets the same, the circle is not read")
    stop(c)
    c = start("circle-unreadable", { config = T.config(CIRCLE .. QUICK), diag = true, prepare = function(ue2)
        local world = game(ue2, { level = 6.0, values = { Mana = 0.0, MaxMana = 400.0 } })
        world.stores[world.hero.mana].MagicianLevel = nil
        return world
    end })
    c.at(3)
    check(c.mana() == 30 and printedCount(c.ue, "the hero's magic circle could not be read; mana regenerates as without the circle setting") == 1
        and c.fake.value("regen.circle") == "not readable" and c.fake.count["regen.circle"] == 1 and #c.ue.errors == 0,
        "a circle that cannot be read: the full amount, said once, noted once")
    stop(c)
    c = start("circle-health", { config = T.config("Config.HealthFlat = 10\nConfig.HealthSeconds = 1\nConfig.ManaByCircle = true" .. QUICK), game = { level = 6.0, values = { Health = 20.0 } } })
    c.at(2)
    check(c.health() == 40 and c.world.asked.MagicianLevel == nil, "the circle is about mana: health is not scaled by it")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("8. mana that comes back from zero: the game's block on casting")
do
    local c = start("block", { config = MANA1, diag = true })
    local ue, w = c.ue, c.world
    c.at(2)
    check(c.mana() == 12 and w.tagAsked["State.OutMana"] == 2 and w.called("RemoveTag") == 0 and c.fake.value("regen.mana.block") == "not set",
        "mana above zero and no block: asked after each step, nothing to take off (noted)")
    -- a spell uses up the mana; its effect runs twice more at zero
    w.effect("Mana", -12)
    w.effect("Mana", -1)
    w.effect("Mana", -1)
    check(c.mana() == 0 and w.tags["State.OutMana"] == 3, "(the model: at zero the game marks the hero State.OutMana, once per effect execution)")
    c.at(2.5)
    check(c.mana() == 0 and w.tags["State.OutMana"] == 3, "as long as nothing came back the block stays")
    c.at(3)
    check(c.mana() == 1 and w.tags["State.OutMana"] == nil and w.called("RemoveTag") == 1, "the first point back: the block is taken off with the game's own RemoveTag, every count of it")
    check(w.outOfManaEnds == 1 and w.hud.Mana == 1, "the bar on screen is told: the out-of-mana state ends, the value shows")
    check(printed(ue, "[G1R_Regen] the game's block on casting (out of mana) was taken off\n") ~= nil and c.S.cleared == 1
        and table.concat(c.fake.values("regen.mana.block"), ",") == "not set,cleared", "said in the log (LogSteps), counted and noted")
    c.at(8)
    check(c.mana() == 6 and w.called("RemoveTag") == 1 and w.tagAsked["State.OutMana"] == 2 + 2 + 5 and c.fake.value("regen.mana.block") == "cleared" and c.fake.count["regen.mana.block"] == 2,
        "later steps find no block (asked after each step); the note stays at cleared")
    check(has(status(c), "; casting block taken off 1 time(s)"), "the status counts it")
    -- the game takes its block off itself when one of its own effects brings mana back
    w.effect("Mana", -6)
    check(w.tags["State.OutMana"] == 1, "(zero again)")
    w.effect("Mana", 10)
    c.at(12)
    check(w.tags["State.OutMana"] == nil and w.called("RemoveTag") == 1, "a potion: the game took its block off itself, the module had nothing to do")
    stop(c)

    c = start("block-first", { config = MANA1, diag = true, game = { values = { Mana = 0.0 } } })
    c.world.tags["State.OutMana"] = 1
    c.at(3)
    check(c.mana() == 3 and c.world.tags["State.OutMana"] == nil and table.concat(c.fake.values("regen.mana.block"), ",") == "cleared",
        "a hero who starts out of mana with the block on: taken off at the first step, noted as cleared only")
    stop(c)

    c = start("block-off", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ManaClearBlock = false" .. QUICK), game = { values = { Mana = 3.0 } } })
    w = c.world
    w.effect("Mana", -3)
    c.at(5)
    check(c.mana() == 5 and w.tags["State.OutMana"] == 1 and w.tagAsked["State.OutMana"] == nil and w.called("RemoveTag") == 0, "ManaClearBlock = false: mana comes back, the block is left to the game, not even asked for")
    stop(c)

    c = start("block-health", { config = T.config("Config.HealthFlat = 1\nConfig.HealthSeconds = 1" .. QUICK), game = { values = { Mana = 0.0, Health = 20.0 } } })
    c.world.tags["State.OutMana"] = 1
    c.at(5)
    check(c.health() == 25 and c.world.tagAsked["State.OutMana"] == nil and c.world.tags["State.OutMana"] == 1, "health steps have nothing to do with it")
    stop(c)

    -- the block cannot be taken off
    for _, case in ipairs({
        { "RemoveTag is not there", nil, "attempt to call a nil value (field '?')", 3 },
        { "RemoveTag raises", function() error("not allowed (test)", 0) end, "not allowed (test)", 3 },
        { "RemoveTag does nothing", function() end, "the tag is still there", 6 },
    }) do
        c = start("block-" .. case[3]:gsub("%W", ""), { config = MANA1, diag = true, prepare = function(ue2)
            local world = game(ue2, { values = { Mana = 2.0 } })
            world.removes = 0
            rawset(world.hero.component, "RemoveTag", case[2] and function(...)
                world.removes = world.removes + 1
                return case[2](...)
            end or nil)
            return world
        end })
        w = c.world
        w.effect("Mana", -2)
        c.at(10)
        check(c.mana() == 10 and w.tags["State.OutMana"] == 1 and #c.ue.errors == 0, case[1] .. ": mana regenerates, the block stays")
        check(printedCount(c.ue, "the game's block on casting (out of mana) could not be taken off (" .. case[3] .. "); a mana potion takes it off") == 1
            and c.fake.value("regen.mana.block") == "still set" and c.fake.count["regen.mana.block"] == 1 and c.fake.detail("regen.mana.block") == case[3],
            case[1] .. ": said once with the reason and what helps, noted once")
        check(w.tagAsked["State.OutMana"] == case[4] and w.removes == (case[2] and 3 or 0), case[1] .. ": tried at three steps, then left alone")
        stop(c)
    end

    -- one failure is not the end of it
    c = start("block-transient", { config = MANA1, prepare = function(ue2)
        local world = game(ue2, { values = { Mana = 2.0 } })
        local plain = rawget(world.hero.component, "RemoveTag")
        world.fail = 2
        rawset(world.hero.component, "RemoveTag", function(...)
            if world.fail > 0 then
                world.fail = world.fail - 1
                error("busy (test)", 0)
            end
            return plain(...)
        end)
        return world
    end })
    w = c.world
    w.effect("Mana", -2)
    c.at(3)
    check(w.tags["State.OutMana"] == nil and c.S.cleared == 1 and c.S.clearFails == 0, "RemoveTag fails twice and works the third time: the block is off, the failures are forgotten")
    stop(c)

    -- the same with values written directly
    c = start("block-direct", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.Method = \"direct\"" .. QUICK), game = { values = { Mana = 2.0 } } })
    w = c.world
    w.effect("Mana", -2)
    c.at(1)
    check(c.mana() == 1 and w.tags["State.OutMana"] == nil and w.called("RemoveTag") == 1 and w.called("TrySetAttributeBaseValue") == 0, "values written directly: the block is taken off the same way")
    stop(c)

    -- Mana comes back from zero and the block is NOT there. In the game that should not happen (the game sets the
    -- block whenever an effect leaves mana at zero); it is what the module sees when the questions about the
    -- hero's tags do not arrive (then every answer is no). The module cannot tell the two apart without another
    -- call into the game: it notes a value of its own and says it once.
    local ZERO_LINE = "[G1R_Regen] mana came back from zero, but the game's block on casting (out of mana) was not found: either this game sets none at zero mana,"
        .. " or the hero's tags cannot be read - then regenerated mana cannot be cast until a mana potion is drunk, and ManaArmedPercent / HealthArmedPercent"
        .. " have no effect. To find out which, send UE4SS.log and the megamod's Scripts\\diagnostics folder\n"
    c = start("block-zero", { config = MANA1, diag = true, game = { values = { Mana = 0.0 } } })
    ue, w = c.ue, c.world
    c.at(3)
    check(c.mana() == 3 and w.called("RemoveTag") == 0 and table.concat(c.fake.values("regen.mana.block"), ",") == "not set at zero mana",
        "a step from zero mana, no block, no tag has answered yes yet: noted as 'not set at zero mana' (once; the steps from 1 and 2 change nothing)")
    check(printedCount(ue, ZERO_LINE) == 1 and printedCount(ue, "came back from zero") == 1 and c.fake.value("regen.tags") == "only no so far",
        "and said once in the log, with what it means and what to send; the tags are noted as 'only no so far'")
    w.set("Mana", 0.0)          -- at zero again, still no block
    c.at(6)
    check(c.mana() > 0 and c.fake.count["regen.mana.block"] == 1 and printedCount(ue, "came back from zero") == 1, "a second time: no second line, no second note")
    w.effect("Mana", -c.mana())     -- a spell uses the mana up: now the game's block is there, and the tag answers yes
    c.at(9)
    check(w.tags["State.OutMana"] == nil and table.concat(c.fake.values("regen.mana.block"), ",") == "not set at zero mana,cleared" and c.fake.value("regen.tags") == "readable",
        "the block is found and taken off later: noted as cleared, and the tags are proven readable")
    w.set("Mana", 0.0)          -- zero without a block once more, after a tag has answered yes
    c.at(12)
    check(c.mana() > 0 and c.fake.value("regen.mana.block") == "cleared" and c.fake.count["regen.mana.block"] == 2 and printedCount(ue, "came back from zero") == 1,
        "zero mana without a block after a tag has answered yes: the tags are known to work, nothing is noted or said")
    stop(c)
    c = start("block-one", { config = MANA1, diag = true, game = { values = { Mana = 1.0 } } })
    c.at(2)
    check(c.mana() == 3 and c.fake.value("regen.mana.block") == "not set" and c.fake.count["regen.mana.block"] == 1 and printed(c.ue, "came back from zero") == nil,
        "a step from 1 mana without a block is the usual 'not set': only zero is the case in question")
    stop(c)
    c = start("block-zero-blind", { config = MANA1, diag = true, prepare = function(ue2)
        local world = game(ue2, { values = { Mana = 0.0 } })
        rawset(world.hero.component, "HasGameplayTag", nil)
        return world
    end })
    c.at(6)
    check(c.mana() == 6 and c.S.tagsOff == true and c.fake.value("regen.mana.block") == nil and printed(c.ue, "came back from zero") == nil and c.fake.value("regen.tags") == "not readable",
        "tags that cannot be asked at all: that is said as before ('not readable'); nothing is claimed about the block")
    stop(c)
    -- the case all this is for: the tag question answers no to everything (the tag made from a table does not carry
    -- its name). A weapon is drawn, the setting says 0 % then, and a spell has used the mana up.
    c = start("tags-deaf", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ManaArmedPercent = 0" .. QUICK), diag = true, prepare = function(ue2)
        local world = game(ue2, { values = { Mana = 3.0 } })
        rawset(world.hero.component, "HasGameplayTag", function() return false end)
        return world
    end })
    w = c.world
    w.tags["State.Combat.Melee.Sword"] = 1
    w.effect("Mana", -3)
    c.at(5)
    check(c.mana() == 5 and w.tags["State.OutMana"] == 1 and w.called("RemoveTag") == 0, "(tags that answer no to everything: mana regenerates with the weapon drawn, the game's block stays)")
    check(c.fake.value("regen.mana.block") == "not set at zero mana" and c.fake.value("regen.tags") == "only no so far" and printedCount(c.ue, ZERO_LINE) == 1,
        "the diagnostics do not call that 'as expected': the block is noted as 'not set at zero mana', the tags as 'only no so far', and the log has the line")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("9. how the value is written: the game's own way, the direct write, and what can go wrong")
do
    local function method(text) return T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.LogSteps = true\nConfig.Method = \"" .. text .. "\"" .. QUICK) end
    -- A world whose TrySetAttributeBaseValue (of the mana set) is replaced; world.tries counts the calls.
    local function broken(replacement, values)
        return function(ue2)
            local world = game(ue2, { values = values })
            world.tries = 0
            local plain = rawget(world.hero.mana, "TrySetAttributeBaseValue")
            rawset(world.hero.mana, "TrySetAttributeBaseValue", replacement and function(...)
                world.tries = world.tries + 1
                return replacement(world, plain, ...)
            end or nil)
            return world
        end
    end

    local c = start("auto", { config = method("auto"), diag = true })
    local ue, w = c.ue, c.world
    c.at(3)
    check(c.mana() == 13 and w.base("Mana") == 13 and w.hud.Mana == 13 and w.called("TrySetAttributeBaseValue") == 3 and c.S.how == "ability system",
        "auto: the game's own way - three steps, three calls, base value, current value and the bar on screen agree")
    check(c.fake.value("regen.mana.write") == "ability system" and c.fake.count["regen.mana.write"] == 1 and has(status(c), "; written by ability system"), "noted once; the status names the way")
    stop(c)

    c = start("direct", { config = method("direct"), diag = true })
    w = c.world
    c.at(3)
    check(c.mana() == 13 and w.base("Mana") == 13 and w.called("TrySetAttributeBaseValue") == 0, "direct: base value and current value are written, the game's function is not called")
    check(w.hud.Mana == 10 and w.hudEvents == 0, "(the model: the bar on screen is not told - it follows with the game's next own change)")
    check(c.fake.value("regen.mana.write") == "direct write" and printed(c.ue, "[G1R_Regen] mana +1 -> 13 of 30 (direct write)\n") ~= nil and has(status(c), "; written by direct write"),
        "noted, logged and shown in the status as direct write")
    w.effect("Mana", -1)
    check(c.mana() == 12 and w.hud.Mana == 12, "the game's next own change starts from the written value (13 - 1) and the bar shows it")
    stop(c)

    -- the game's way only: when it does not work nothing is written
    c = start("game-missing", { config = method("game"), diag = true, prepare = broken(nil) })
    ue, w = c.ue, c.world
    c.at(2)
    check(c.mana() == 10 and w.base("Mana") == 10 and c.S.Mana.failed == 2 and c.S.Mana.givenUp == false, "game: the function is not there - nothing is written, the direct write is not used")
    check(printedCount(ue, "[G1R_Regen] the game's own way of setting mana did not work (the call failed: attempt to call a nil value (field '?'))\n") == 1
        and printedCount(ue, "[G1R_Regen] mana could not be written (the call failed: attempt to call a nil value (field '?')); it stays as the game has it\n") == 1,
        "each said once, with the reason")
    check(c.fake.value("regen.mana.write") == "failed" and c.fake.count["regen.mana.write"] == 1 and has(c.fake.detail("regen.mana.write"), "the call failed"), "noted once as failed")
    c.at(3)
    local reads = sum(w.asked)
    check(c.S.Mana.givenUp == true and printedCount(ue, "[G1R_Regen] mana regeneration is given up for this run: 3 steps in a row could not be written\n") == 1, "three steps in a row: mana regeneration is given up for this run, said once")
    c.at(60)
    check(c.mana() == 10 and sum(w.asked) == reads and has(status(c), "|mana: given up for this run (the value could not be written)|"), "then mana is not looked at again; the status says so")
    check(#ue.errors == 0 and printedCount(ue, "given up") == 1 and printedCount(ue, "did not work") == 1, "no error, no further lines")
    -- another way of writing is chosen: what was given up is tried anew
    T.write(c.path, method("direct"))
    ue:fireConsole("regen reload")
    c.ticks(8)
    check(c.S.Mana.givenUp == false and c.mana() > 10, "Method changed to direct while the game runs: mana regenerates")
    stop(c)

    c = start("game-rearm", { config = method("game"), prepare = broken(function(world, plain, ...)
        if world.heal then return plain(...) end
        return false
    end) })
    w = c.world
    c.at(5)
    check(c.S.Mana.givenUp == true and c.mana() == 10 and w.tries == 3 and printed(c.ue, "did not work (the game refused (false))") ~= nil, "the game refuses three times (the function answers false): given up, three calls")
    T.menuSet(c, "Combat", "Mana regenerates", false)
    c.ticks(1)
    T.menuSet(c, "Combat", "Mana regenerates", true)
    c.ticks(1)
    check(c.S.Mana.givenUp == false and c.S.Mana.failed == 0, "mana regeneration switched off and on again in the menu: tried anew")
    c.ticks(8)
    check(c.S.Mana.givenUp == false and c.S.Mana.failed == 2 and w.tries == 5, "anew means three steps again before it is given up (two failures: still trying)")
    c.ticks(4)
    check(c.S.Mana.givenUp == true and w.tries == 6, "(the third)")
    w.heal = true
    T.menuSet(c, "Combat", "Mana regenerates", false)
    c.ticks(1)
    T.menuSet(c, "Combat", "Mana regenerates", true)
    c.ticks(8)
    check(c.S.Mana.givenUp == false and c.mana() > 10, "the game's function works now: switched off and on once more, mana regenerates")
    stop(c)

    -- a step that could not be written is not made up for later
    c = start("game-once", { config = T.config("Config.ManaFlat = 1.5\nConfig.ManaSeconds = 1\nConfig.Method = \"game\"" .. QUICK), prepare = broken(function(world, plain, ...)
        if world.tries == 2 then return false end
        return plain(...)
    end) })
    c.at(1)
    local stepOne = c.mana()
    c.at(2)
    check(stepOne == 11 and c.mana() == 11 and c.S.Mana.failed == 1 and c.S.Mana.carry == 0, "1.5 per step: 11, then a step that fails - nothing is written and nothing carried over")
    c.at(3)
    check(c.mana() == 12 and c.S.Mana.failed == 0 and c.S.Mana.carry == 0.5, "the next step gives its own amount only (12), and the failure is forgotten")
    stop(c)

    -- auto fell back to the direct write; choosing a way of writing anew tries the game's way again
    c = start("auto-rearm", { config = method("auto"), prepare = broken(function(world, plain, ...)
        if world.heal then return plain(...) end
        return false
    end) })
    w = c.world
    c.at(4)
    check(c.S.direct == true and c.S.gameFails == 3 and c.mana() == 14, "(auto has fallen back to the direct write)")
    w.heal = true
    T.write(c.path, method("auto"):gsub("LogSteps = true", "LogSteps = false"))
    c.ue:fireConsole("regen reload")
    c.at(6)
    check(c.S.direct == true and w.tries == 3, "another setting changes: the fallback stays")
    T.write(c.path, method("game"))
    c.ue:fireConsole("regen reload")
    check(c.S.direct == false and c.S.gameFails == 0, "Method changes: the game's way is tried anew")
    c.at(8)
    check(w.tries == 5 and w.hud.Mana == c.mana() and c.S.how == "ability system", "and used when it works now")
    stop(c)

    -- auto: when the game's way does not work the value is written directly, and after three failures only directly
    for _, case in ipairs({
        { "the function is not there", nil, "the call failed: attempt to call a nil value (field '?')" },
        { "the function raises", function() error("Tried calling a member function but the UObject instance is nullptr (test)", 0) end, "the call failed: Tried calling a member function but the UObject instance is nullptr (test)" },
        { "the game refuses", function() return false end, "the game refused (false)" },
        { "the function answers nothing", function() end, "the game refused (nil)" },
        { "the call changes nothing", function() return true end, "the value did not change" },
    }) do
        c = start("auto-" .. case[1]:gsub("%W", ""), { config = method("auto"), diag = true, prepare = broken(case[2]) })
        ue, w = c.ue, c.world
        c.at(1)
        check(c.mana() == 11 and w.base("Mana") == 11 and c.S.gameFails == 1 and c.S.direct == false, case[1] .. ": the first step is written directly at once")
        c.at(10)
        check(c.mana() == 20 and c.S.direct == true and w.tries == (case[2] and 3 or 0), case[1] .. ": tried at three steps, then only the direct write (ten steps, ten points)")
        check(printedCount(ue, "[G1R_Regen] the game's own way of setting mana did not work (" .. case[3] .. ")\n") == 1
            and printedCount(ue, "[G1R_Regen] from now on the values are written directly; the bars on screen follow with the game's next own change\n") == 1,
            case[1] .. ": the reason and the consequence are each said once")
        check(c.fake.value("regen.mana.write") == "direct write" and c.fake.count["regen.mana.write"] == 1 and #ue.errors == 0 and printed(ue, "could not be written") == nil,
            case[1] .. ": noted as direct write; nothing failed for the player")
        stop(c)
    end

    -- the call works but the game makes something else of the value: taken as done, nothing is written on top
    c = start("auto-other", { config = method("auto"), prepare = broken(function(world, plain, self, name, value)
        return plain(self, name, value - 0.75)     -- as if the game had its own idea of the number
    end) })
    c.at(4)
    check(c.mana() == 14 and c.S.gameFails == 3 and c.S.direct == true and c.world.tries == 3, "a call after which the value is where it was (the game rounded it back) counts as not working: direct write ...")
    stop(c)
    c = start("auto-less", { config = T.config("Config.ManaFlat = 4\nConfig.ManaSeconds = 1" .. QUICK), prepare = broken(function(world, plain, self, name, value)
        return plain(self, name, value - 2)
    end) })
    c.at(3)
    check(c.mana() == 16 and c.S.gameFails == 0 and c.S.Mana.added == 6 and c.world.tries == 3, "... one that moves it by another amount is the game's doing: taken as it is (+2 instead of +4), nothing written on top")
    stop(c)

    -- a failure now and then does not end the game's way
    c = start("auto-transient", { config = method("auto"), prepare = broken(function(world, plain, ...)
        if world.fail and world.fail > 0 then
            world.fail = world.fail - 1
            return false
        end
        return plain(...)
    end) })
    w = c.world
    c.at(2)
    w.fail = 2
    c.at(5)
    w.fail = 2
    c.at(9)
    check(c.mana() == 19 and c.S.direct == false and c.S.gameFails == 0 and w.hud.Mana == 19, "two failures, a success, two failures: the game's way stays in use (every step arrived, one way or the other)")
    w.fail = 3
    c.at(13)
    check(c.S.direct == true and c.mana() == 23, "three failures in a row: direct from then on")
    stop(c)

    -- a UE4SS without FName: neither the game's function nor the tags can be used
    c = start("no-fname", { config = method("auto"), mock = { without = { "FName" } }, diag = true })
    c.at(5)
    check(c.mana() == 15 and c.S.direct == true and c.world.called("TrySetAttributeBaseValue") == 0 and c.world.called("HasGameplayTag") == 0
        and printed(c.ue, "did not work (the call failed: this UE4SS build has no FName)") ~= nil and printed(c.ue, "gameplay tags cannot be asked (this UE4SS build has no FName)") ~= nil and #c.ue.errors == 0,
        "no FName: said for both, the values are written directly, no call is made with a wrong argument")
    stop(c)

    -- the direct write does not work either
    local function sealed(onWrite)
        return function(ue2)
            local world = game(ue2)
            rawset(world.hero.mana, "TrySetAttributeBaseValue", nil)
            local values = world.stores[world.hero.mana].Mana
            local held = { BaseValue = values.BaseValue, CurrentValue = values.CurrentValue }
            world.stores[world.hero.mana].Mana = setmetatable({}, { __index = held, __newindex = onWrite(held) })
            world.held = held
            return world
        end
    end
    for _, case in ipairs({
        { "the write raises", function() return function() error("read only (test)") end end, "the write raised an error" },
        { "the write goes nowhere", function() return function() end end, "the value did not stay" },
        { "only the base value stays", function(held) return function(_, k, v) if k == "BaseValue" then held.BaseValue = v end end end, "the value did not stay" },
        { "only the current value stays", function(held) return function(_, k, v) if k == "CurrentValue" then held.CurrentValue = v end end end, "the value did not stay" },
    }) do
        c = start("sealed-" .. case[1]:gsub("%W", ""), { config = method("auto"), diag = true, prepare = sealed(case[2]) })
        ue, w = c.ue, c.world
        c.at(1)
        check(w.held.CurrentValue == 10 and w.held.BaseValue == 10 and c.S.Mana.failed == 1 and c.S.Mana.steps == 0 and #ue.errors == 0,
            case[1] .. ": the step counts as failed, the value is as the game had it (10 / 10), no error reaches UE4SS")
        check(printedCount(ue, "[G1R_Regen] mana could not be written (" .. case[3] .. "); it stays as the game has it\n") == 1 and c.fake.value("regen.mana.write") == "failed"
            and c.fake.detail("regen.mana.write") == case[3], case[1] .. ": said once with the reason, noted")
        c.at(30)
        check(c.S.Mana.givenUp == true and c.S.Mana.steps == 0 and printedCount(ue, "mana could not be written") == 1 and printedCount(ue, "given up") == 1
            and w.held.CurrentValue == 10 and w.held.BaseValue == 10, case[1] .. ": given up after three steps, said once; still 10 / 10")
        stop(c)
    end
    c = start("direct-sealed", { config = method("direct"), prepare = sealed(function() return function() end end) })
    c.at(30)
    check(c.mana() == 10 and c.S.Mana.givenUp == true and printed(c.ue, "did not work") == nil, "Method direct with a write that does not stay: given up, the game's way is not tried")
    stop(c)

    -- the game keeps the numbers in single precision
    c = start("single", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.Method = \"direct\"" .. QUICK), prepare = function(ue2)
        local world = game(ue2, { values = { Mana = 20.7, MaxMana = 30000000.0 } })
        local held = { BaseValue = 20.7, CurrentValue = 20.7 }
        world.stores[world.hero.mana].Mana = setmetatable({}, { __index = held, __newindex = function(_, k, v) held[k] = string.unpack("f", string.pack("f", v)) end })
        world.held = held
        return world
    end })
    c.at(1)
    check(c.S.Mana.failed == 0 and c.S.Mana.steps == 1 and math.abs(c.world.held.CurrentValue - 21.7) < 0.0001, "a value that comes back rounded to single precision is still the value that was written (21.7)")
    stop(c)

    -- an effect that adds to the value on top of its base value
    for _, way in ipairs({ "auto", "direct" }) do
        c = start("bonus-" .. way, { config = T.config("Config.HealthFlat = 2\nConfig.HealthSeconds = 1\nConfig.Method = \"" .. way .. "\"" .. QUICK), prepare = function(ue2)
            local world = game(ue2, { values = { Health = 40.0 } })
            world.bonus.Health = 10
            world.stores[world.hero.health].Health.CurrentValue = 50.0
            return world
        end })
        c.at(2)
        check(c.world.base("Health") == 44 and c.health() == 54, way .. ": base value 40, current value 50 (an effect adds 10) - both go up by what was added (44 / 54)")
        stop(c)
    end

    -- another hero's set: its function writes to that hero
    c = start("other-owner", { config = method("auto") })
    w = c.world
    w.noOwner = true        -- the set has no ability system that owns it: the game's function answers false
    c.at(4)
    check(c.mana() == 14 and c.S.direct == true and w.called("TrySetAttributeBaseValue") == 3, "a set without an owning ability system (the game answers false): direct write")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("10. another hero, replaced and stale objects, no hero")
do
    local BOTH1 = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.HealthFlat = 1\nConfig.HealthSeconds = 1\nConfig.SettleSeconds = 3\nConfig.ManaPause = 0\nConfig.HealthPause = 0")
    local c = start("swap", { config = BOTH1, game = { values = { Health = 50.0 } } })
    local ue, w = c.ue, c.world
    c.at(6)
    check(c.mana() == 13 and c.health() == 53, "the hero regenerates (3 s after he was found, then every second)")
    -- a new game: the controller gets another player state with its own attributes
    local second = w.adopt(T.hero(ue, w, 40, { Mana = 5.0, MaxMana = 20.0, Health = 30.0, MaxHealth = 60.0 }))
    w.controller.PlayerState = second.state
    c.at(9.5)
    check(c.S.Mana.setName == second.mana:GetFullName() and c.S.Health.setName == second.health:GetFullName() and w.value("Mana", second) == 5 and w.value("Health", second) == 30,
        "another player state: its attributes are taken, and the wait runs again (nothing in the first 3 s)")
    c.at(12)
    check(w.value("Mana", second) == 7 and w.value("Health", second) == 32, "then the new hero regenerates")
    check(c.mana() == 13 and c.health() == 53, "the old attributes are left alone")
    w.effect("Mana", -3)        -- the old hero's attributes still change (an object on its way out)
    c.at(14)
    check(c.mana() == 10 and w.value("Mana", second) == 9 and c.S.Mana.losses == 0, "a change in the old attributes is nobody's loss")

    -- the mana object is destroyed and another object gets its address: the wrapper looks alive again
    local function manaSet(n, mana)
        local set = ue:object("AttributeSet_Mana /Game/Maps/World.World:PersistentLevel.GothicPlayerState_40.AttributeSet_Mana_" .. n, {
            Mana = { BaseValue = mana, CurrentValue = mana }, MaxMana = { BaseValue = 20.0, CurrentValue = 20.0 } })
        local hero = { mana = set, health = second.health, progression = second.progression, component = second.component }
        return set, hero
    end
    local stale = second.mana
    local replacement = manaSet(77, 9.0)
    second.component.SpawnedAttributes.items[2] = replacement
    stale.__full = "GothicNPCState /Game/Maps/World.World:PersistentLevel.GothicNPCState_9.AttributeSet_Mana_3"
    w.stores[stale].Mana.BaseValue, w.stores[stale].Mana.CurrentValue = 1.0, 1.0
    c.at(20)
    check(c.S.Mana.setName == replacement:GetFullName() and w.stores[stale].Mana.CurrentValue == 1 and replacement.Mana.CurrentValue > 9,
        "a kept wrapper that now names another object is dropped: that object is not written to, the hero's new attributes are")
    -- the object is gone for good
    replacement.__valid = false
    local third = manaSet(78, 11.0)
    second.component.SpawnedAttributes.items[2] = third
    c.at(26)
    check(c.S.Mana.setName == third:GetFullName() and third.Mana.CurrentValue > 11 and #ue.errors == 0, "attributes that are gone are looked up again through the player state")
    check(allOf(ue) == 1, "all of this without another search among all objects (" .. allOf(ue) .. " FindAllOf)")
    stop(c)

    -- a menu: a controller whose player state has no ability system
    c = start("menu", { config = BOTH1, prepare = function(ue2)
        local world = game(ue2)
        rawset(world.hero.state, "__component", nil)
        return world
    end })
    ue, w = c.ue, c.world
    c.at(60)
    check(c.S.Mana.setName == nil and c.S.Health.setName == nil and #ue.errors == 0 and sum(w.asked) == 0 and sum(w.calls) == 0 and #ue.lookups == 0 and (ue.calls.FindFirstOf or 0) == 0,
        "no hero is not an error: nothing is read, the engine and the clock are not asked")
    local scans = allOf(ue) - 1
    check(w.reads[21] == 6 and scans == 8, "the kit asks a player state without an ability system 3 times per attribute set, then searches with growing pauses: "
        .. scans .. " searches among all objects in the first minute")
    c.at(300)
    check(allOf(ue) - 1 - scans == 8, "and once a minute per set after that (" .. (allOf(ue) - 1 - scans) .. " in four minutes)")
    check(has(status(c), "|mana: the hero's mana has not been found yet (no game loaded?)|health: the hero's health has not been found yet (no game loaded?)|"), "the status says that the hero has not been found")
    stop(c)

    -- the hero goes away (back to the main menu without a map load being reported)
    c = start("leave", { config = BOTH1, game = { values = { Health = 50.0 } } })
    w = c.world
    c.at(6)
    check(c.S.Mana.setName ~= nil and c.S.Health.setName ~= nil and c.mana() == 13, "(a hero, regenerating)")
    w.controller.PlayerState = nil
    c.at(7)
    check(c.S.Mana.setName == nil and c.S.Health.setName == nil and c.S.Mana.value == nil and has(status(c), "|mana: the hero's mana has not been found yet (no game loaded?)|"),
        "the controller has no player state any more: what was known about the hero is forgotten, the status says so")
    local asked = sum(w.asked)
    c.at(30)
    check(c.mana() == 13 and sum(w.asked) == asked, "his attributes are neither read nor written any more")
    w.controller.PlayerState = w.hero.state
    c.at(34)
    check(c.mana() == 13 and c.S.Mana.setName ~= nil, "he is back: found again, and the wait runs again (3 s) ...")
    c.at(36)
    check(c.mana() > 13, "... before the steps go on")
    stop(c)

    -- no controller at all, then one appears
    c = start("nocontroller", { config = BOTH1, prepare = function(ue2) return game(ue2, { noController = true }) end })
    ue, w = c.ue, c.world
    c.at(12)
    check(allOf(ue) == 10 and sum(w.asked) == 0, "without a controller the kit searches every 3 seconds under both class names (" .. allOf(ue) .. " FindAllOf in 12 s); nothing else is asked")
    ue.allOf["PlayerController"] = { w.controller }
    c.at(20)
    check(c.S.Mana.setName == w.hero.mana:GetFullName() and c.mana() > 10, "a controller appears: the hero is found and regenerates")
    stop(c)

    -- the state's own list is not usable: the kit's search finds the attributes of this player state
    c = start("scan", { config = BOTH1, diag = true, prepare = function(ue2)
        local world = game(ue2, { values = { Health = 50.0 } })
        world.hero.component.SpawnedAttributes = nil
        world.other = world.adopt(T.hero(ue2, world, 60, { Mana = 1.0, Health = 2.0 }))
        ue2.allOf["AttributeSet_Mana"] = { world.hero.mana, world.other.mana }
        ue2.allOf["AttributeSet_Health"] = { world.other.health, world.hero.health }
        return world
    end })
    ue, w = c.ue, c.world
    c.at(12)
    check(c.S.Mana.via == "scan" and c.S.Health.via == "scan" and c.fake.value("regen.mana.set_found_by") == "scan" and c.fake.value("regen.health.set_found_by") == "scan",
        "found by the search: the attributes inside the controller's player state (noted)")
    check(c.mana() > 10 and c.health() > 50 and w.value("Mana", w.other) == 1 and w.value("Health", w.other) == 2, "only the hero regenerates, not the other player state")
    stop(c)

    -- the hero's attributes are found by the search, but his ability system cannot be reached: no tags, and the
    -- game's own way of writing has no ability system to hand the value to (the game's function answers false)
    c = start("no-system", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.HealthFlat = 1\nConfig.HealthSeconds = 1" .. QUICK), diag = true, prepare = function(ue2)
        local world = game(ue2, { values = { Health = 50.0 } })
        rawset(world.hero.state, "__component", nil)
        world.noOwner = true
        ue2.allOf["AttributeSet_Mana"] = { world.hero.mana }
        ue2.allOf["AttributeSet_Health"] = { world.hero.health }
        return world
    end })
    ue, w = c.ue, c.world
    c.at(30)
    check(c.S.Mana.via == "scan" and c.mana() > 10 and c.health() > 50 and w.base("Mana") == c.mana() and #ue.errors == 0, "a hero without a reachable ability system still regenerates (found by the search, written directly)")
    check(printedCount(ue, "[G1R_Regen] the hero's gameplay tags cannot be asked (the hero has no ability system); what cannot be told without them") == 1
        and printedCount(ue, "the game's own way of setting mana did not work (the game refused (false))") == 1 and printedCount(ue, "from now on the values are written directly") == 1
        and c.fake.value("regen.tags") == "not readable" and c.fake.detail("regen.tags") == "the hero has no ability system" and c.fake.value("regen.mana.write") == "direct write"
        and w.called("HasGameplayTag") == 0 and w.called("RemoveTag") == 0 and w.called("TrySetAttributeBaseValue") == 3,
        "each problem is said once and noted; no tag function is called on nothing, the game's function three times")
    stop(c)

    -- only one of the two sets can be found
    c = start("one-set", { config = BOTH1, prepare = function(ue2)
        local world = game(ue2, { values = { Health = 50.0 } })
        world.hero.component.SpawnedAttributes.items = { world.hero.health, world.hero.progression }
        return world
    end })
    c.at(10)
    check(c.health() == 57 and c.mana() == 10 and c.S.Mana.setName == nil and #c.ue.errors == 0, "a hero whose mana cannot be found: health regenerates, mana is left alone")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("11. values that cannot be read")
do
    local BOTH1 = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.HealthFlat = 1\nConfig.HealthSeconds = 1" .. QUICK)
    local c = start("unreadable", { config = BOTH1, diag = true, prepare = function(ue2)
        local world = game(ue2, { values = { Health = 50.0 } })
        world.kept = world.stores[world.hero.mana].Mana
        world.stores[world.hero.mana].Mana = nil
        world.tries = 0
        local meta = getmetatable(world.hero.mana)
        setmetatable(world.hero.mana, { __index = function(t, k)
            if k == "Mana" and world.stores[world.hero.mana].Mana == nil then world.tries = world.tries + 1 end
            return meta.__index(t, k)
        end })
        return world
    end })
    local ue, w = c.ue, c.world
    c.at(11)
    check(printedCount(ue, "[G1R_Regen] the hero's Mana could not be read from " .. w.hero.mana:GetFullName() .. "\n") == 1 and c.fake.value("regen.mana.readable") == "no"
        and c.fake.detail("regen.mana.readable") == "Mana" and c.fake.count["regen.mana.readable"] == 1 and #ue.errors == 0, "mana that cannot be read: said once in the log and noted, no error")
    check(w.tries == 3, "and asked for again every 5 seconds, not twice a second (" .. w.tries .. " times in 11 s)")
    check(c.health() == 61 and c.fake.value("regen.health.readable") == "yes", "health, which can be read, regenerates meanwhile")
    w.stores[w.hero.mana].Mana = w.kept
    c.at(17)
    check(c.mana() > 10 and c.fake.value("regen.mana.readable") == "yes", "readable again: mana regenerates within seconds, and that is noted")
    w.stores[w.hero.mana].Mana.CurrentValue = 0 / 0
    local writes = w.called("TrySetAttributeBaseValue")
    c.at(18)
    check(c.S.Mana.setName == nil and #ue.errors == 0, "a value that is not a number is not taken for mana")
    stop(c)

    c = start("unreadable-max", { config = BOTH1, diag = true, prepare = function(ue2)
        local world = game(ue2, { values = { Health = 50.0 } })
        world.kept = world.stores[world.hero.health].MaxHealth
        world.stores[world.hero.health].MaxHealth = nil
        return world
    end })
    ue, w = c.ue, c.world
    c.at(12)
    check(c.health() == 50 and c.mana() == 22 and printedCount(ue, "[G1R_Regen] the hero's MaxHealth could not be read from " .. w.hero.health:GetFullName() .. "\n") == 1
        and c.fake.value("regen.health.readable") == "no" and c.fake.detail("regen.health.readable") == "MaxHealth", "a maximum that cannot be read: nothing is added to that value, said once, noted; mana goes on")
    w.stores[w.hero.health].MaxHealth = w.kept
    c.at(20)
    check(c.health() > 50, "readable again: health regenerates")
    stop(c)

    -- only the current value can be read: it is taken for the base value as well
    c = start("no-base", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1" .. QUICK), prepare = function(ue2)
        local world = game(ue2)
        world.stores[world.hero.mana].Mana = setmetatable({ CurrentValue = 10.0 }, { __newindex = function(t, k, v) if k ~= "BaseValue" then rawset(t, k, v) end end })
        rawset(world.hero.mana, "TrySetAttributeBaseValue", function(self, name, value)
            world.given = value
            world.stores[world.hero.mana].Mana.CurrentValue = value
            return true
        end)
        return world
    end })
    c.at(1)
    check(c.world.given == 11 and c.world.value("Mana") == 11, "no base value to be read: the current value stands in for it (11 is handed to the game)")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("12. map loads")
do
    local c = start("load-map", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ManaPause = 4\nConfig.SettleSeconds = 0") })
    local ue, w = c.ue, c.world
    c.at(6)
    check(c.mana() == 12, "before the load: 12")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    local asked, calls = sum(w.asked), sum(w.calls)
    c.at(11)
    check(c.mana() == 12 and sum(w.asked) == asked and sum(w.calls) == calls and c.S.Mana.setName == nil and #ue.errors == 0,
        "between the two map load hooks the module does nothing, reads nothing and calls nothing")
    -- the new world: other objects
    w.hero.mana.__valid, w.hero.health.__valid, w.hero.state.__valid, w.controller.__valid = false, false, false, false
    local fresh = w.adopt(T.hero(ue, w, 90, { Mana = 3.0, MaxMana = 40.0 }))
    local control = T.controllerOf(ue, 91, fresh.state, { GetWorld = function() return w.world end })
    ue.allOf["GothicPlayerControllerBaseBP_C"] = { control }
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.at(15.5)
    check(c.S.Mana.setName == fresh.mana:GetFullName() and w.value("Mana", fresh) == 3, "after the load the hero of the new world is found; the wait runs first (4 s)")
    c.at(16)
    local early = w.value("Mana", fresh)
    c.at(17.5)
    check(early == 3 and w.value("Mana", fresh) == 5, "then he regenerates (first step 5 s after he was found, then every second)")
    -- a load whose end is never reported
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    c.at(37)
    local waiting = w.value("Mana", fresh)
    c.at(42)
    local found = w.value("Mana", fresh)
    c.at(45)
    check(waiting == 5 and found == 5 and w.value("Mana", fresh) == 8, "a map load that never reports its end is waited for 20 seconds, not for ever (then the hero is found, waits and regenerates)")
    stop(c)

    -- in a world without a readable game clock the clock is left alone; the next world is asked again
    c = start("load-clock", { config = MANA1, game = { noClock = true } })
    ue, w = c.ue, c.world
    c.at(12)
    check(c.S.clockOff == true and c.mana() == 22, "(a world without a game clock: left alone after ten seconds)")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    ue.firstOf["GameTimeSubsystem"] = ue:object("GameTimeSubsystem /Engine/Transient.GameInstance_1:GameTimeSubsystem_2", { CurrentGameTime = { TotalSeconds = 500.0 } })
    c.at(20)
    check(c.S.clockOff == false and c.mana() == 22, "after a map load the clock is asked again - this one stands still, so no time counts")
    stop(c)

    c = start("no-post-hook", { config = MANA1, mock = { without = { "RegisterLoadMapPostHook" } } })
    c.at(1)
    c.ue:fireLoadMapPre("engine", "world", "url", nil, "")
    c.at(8)
    check(c.mana() > 11 and #c.ue.errors == 0, "a UE4SS without the hook after a map load: the loop does not stop")
    stop(c)

    c = start("no-loop", { config = MANA1, mock = { without = { "LoopInGameThreadWithDelay" } } })
    check(c.ok and printed(c.ue, "[G1R_Regen] FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; regeneration is disabled.\n") ~= nil and #c.ue.errors == 0
        and printed(c.ue, "loaded:") == nil, "a UE4SS without the game-thread loop: said, nothing else happens")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("13. settings while the game runs: the file, the in-game menu, the console")
do
    local c = start("reload", { game = { values = { Health = 50.0 } } })      -- the shipped settings: nothing to regenerate
    local ue, w = c.ue, c.world
    local v = c.hook.settings.values
    c.at(3)
    check(allOf(ue) == 0 and sum(w.asked) == 0, "shipped settings: the game is not looked at")
    T.write(c.path, T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1" .. QUICK))
    c.at(4.5)
    check(printed(ue, "settings changed") == nil, "the file is not read more often than every 5 seconds")
    c.at(4.75)
    check(printed(ue, "[G1R_Regen] settings changed (config.lua): mana +1 every 1 s up to 100%, pause 0 s\n") ~= nil, "a changed file is picked up within 5 seconds, said in the log")
    check(c.mana() == 10 and allOf(ue) == 1 and c.S.awake == true, "an amount was set: the module starts to look at the game; what the hero has is not changed")
    c.at(9)
    check(c.mana() > 10, "and mana regenerates from then on")
    local was = c.mana()
    -- the amount changes: the next step uses it
    T.write(c.path, T.config("Config.ManaFlat = 3\nConfig.ManaSeconds = 1" .. QUICK))
    ue:fireConsole("regen reload")
    check(printed(ue, "[G1R_Regen] settings read: mana +3 every 1 s up to 100%, pause 0 s\n") ~= nil and c.mana() == was, "regen reload reads the file at once; nothing is added for the time that is over")
    c.ticks(4)
    check(c.mana() == was + 3, "the next step gives the new amount")
    -- switched off: at rest at once
    T.write(c.path, T.config("Config.ManaFlat = 3\nConfig.ManaSeconds = 1\nConfig.Enabled = false" .. QUICK))
    ue:fireConsole("regen reload")
    c.ticks(1)
    local reads, calls, finds = sum(w.asked), sum(w.calls), allOf(ue)
    was = c.mana()
    c.ticks(240)
    check(c.mana() == was and sum(w.asked) == reads and sum(w.calls) == calls and allOf(ue) == finds and c.S.awake == false and c.S.Mana.setName == nil,
        "Enabled = false while the game runs: nothing is added and nothing is read any more")
    check(has(status(c), "v1.0.0 | switched off in the settings|nothing to regenerate: the game is not looked at|"), "the status says so")
    check(c.S.Mana.pause == 0 and c.S.Mana.waited == 0 and c.S.Mana.carry == 0 and c.S.Mana.last == nil and c.S.Mana.value == nil and c.S.Mana.phase == nil and c.S.Mana.resting == true
        and c.S.nextLook == 0 and c.S.lookAt == nil and c.S.game == nil, "what was known about the hero is forgotten")
    -- only one of the two switched off
    T.write(c.path, T.config("Config.ManaFlat = 3\nConfig.ManaSeconds = 1\nConfig.ManaEnabled = false\nConfig.HealthFlat = 1\nConfig.HealthSeconds = 1" .. QUICK))
    ue:fireConsole("regen reload")
    reads = w.asked.Mana
    was = c.mana()
    c.ticks(40)
    local healed = c.health()
    check(c.mana() == was and w.asked.Mana == reads and healed >= 59 and has(status(c), ("|mana: switched off|health %d of 100: regenerating, next step in "):format(healed)),
        "ManaEnabled = false: mana is not read, health regenerates (ten seconds: " .. healed .. "); the status shows both")
    -- every amount back to 0: at rest
    T.write(c.path, T.config("Config.ManaEnabled = false\nConfig.HealthFlat = 0\nConfig.HealthPercent = 0" .. QUICK))
    ue:fireConsole("regen reload")
    c.ticks(1)
    reads = sum(w.asked)
    c.ticks(40)
    check(c.health() == healed and sum(w.asked) == reads and c.S.awake == false and printed(ue, "settings read: nothing to regenerate (every amount is 0 or switched off)") ~= nil,
        "every amount at 0 again: at rest")
    -- a file with an error, a file that is gone
    T.write(c.path, "local Config = {}\nConfig.ManaFlat = \nreturn Config\n")
    c.ticks(24)
    check(printedCount(ue, "config.lua has an error, keeping the previous settings") == 1 and v.HealthFlat == 0, "a file with an error: said once, the previous settings stay")
    os.remove(c.path)
    c.ticks(24)
    check(v.ManaEnabled == false and #ue.errors == 0, "a file that is gone: the settings stay")
    stop(c)

    -- a shorter interval must not bring a burst of steps
    c = start("interval", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 600" .. QUICK) })
    c.at(100)
    check(c.mana() == 10 and c.S.Mana.waited == 100, "an interval of ten minutes: 100 s counted, nothing given yet")
    T.write(c.path, T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1" .. QUICK))
    c.ue:fireConsole("regen reload")
    c.at(100.5)
    check(c.mana() == 11 and c.S.Mana.waited == 0, "the interval is set to one second: one step, not a hundred")
    c.at(103.5)
    check(c.mana() == 14, "then one per second")
    stop(c)

    -- the in-game mod menu
    c = start("menu", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1" .. QUICK) })
    ue, w = c.ue, c.world
    v = c.hook.settings.values
    local index = T.menuIndex(c)
    check(#index == 1 and index[1] == "G1R Combat", "the module's groups are registered with the in-game mod menu on the page G1R Combat")
    local page = T.menuPage(c, "Combat")
    local titles = {}
    for _, s in ipairs(page.sections) do titles[#titles + 1] = s.title .. ":" .. #s.items end
    check(table.concat(titles, "|") == "Mana regeneration:8|Mana by magic circle:5|Health regeneration:7|Regeneration: screen, log:2",
        "its sections and their items: " .. table.concat(titles, "|"))
    local long = {}
    for _, i in ipairs(page.items) do
        if has(i.name, "Method") or has(i.name, "ManaClearBlock") or has(i.name, "StopWhen") or has(i.name, "SettleSeconds") or has(i.name, "LookSeconds") then check(false, "a hidden setting is in the menu: " .. i.name) end
        if #i.name > 35 or #i.desc > 54 or i.desc:sub(-3) == "..." or i.name:sub(-3) == "..." then long[#long + 1] = i.name end
    end
    check(#long == 0, "every item has a name of at most 35 characters and a hint of at most 54 (or none), nothing cut off - the menu's columns (" .. table.concat(long, "; ") .. ")")
    local item = T.menuItem(c, "Combat", "Share of the maximum per step")
    check(item.kind == "num" and item.min == 0 and item.max == 100 and item.step == 0.5 and item.value == 0 and item.name == "Share of the maximum per step (%)" and item.section == "Mana regeneration",
        "the mana share: a number from 0 to 100 in steps of 0.5, with its value and unit")
    check(T.menuItem(c, "Combat", "Regeneration of mana and health").kind == "bool" and T.menuItem(c, "Combat", "Regeneration of mana and health").desc == "Off: mana and health as the game handles them.",
        "the module's switch is a switch, with its short menu text as the hint")
    local changes = printedCount(ue, "settings changed (config.lua)")
    c.at(2)
    T.menuSet(c, "Combat", "Points per step", 4)        -- the first item with that label: mana
    c.ticks(1)
    check(v.ManaFlat == 4 and printed(ue, "[G1R_Regen] settings changed (in-game menu): mana +4 every 1 s up to 100%, pause 0 s\n") ~= nil, "an edit in the menu is applied at the next look of the loader")
    check(has(T.read(c.path), "Config.ManaFlat = 4.0\n") and T.menuItem(c, "Combat", "Points per step").value == 4 and c.mods.store["SMM:cmd:G1R Combat"] == "",
        "written into config.lua, shown in the menu, the edit taken off the queue")
    c.at(3)
    check(c.mana() == 12 + 4, "and used: +4 at the next step")
    T.menuSet(c, "Combat", "Mana regenerates up to", 60)
    T.menuSet(c, "Combat", "Wait after mana was spent (seconds)", 7)
    T.menuSet(c, "Combat", "Health regenerates", false)
    c.ticks(1)
    check(v.ManaUpTo == 60 and v.ManaPause == 7 and v.HealthEnabled == false, "three edits at once")
    c.at(20)
    check(c.mana() == 18, "the new limit holds: 60 % of 30")
    T.menuSet(c, "Combat", "Regeneration of mana and health", false)
    c.ticks(1)
    check(v.Enabled == false and has(T.read(c.path), "Config.Enabled = false\n") and c.S.awake == false, "switched off in the menu: config.lua says Enabled = false, and the module rests at once")
    local finds = sum(w.asked)
    c.ticks(40)
    check(sum(w.asked) == finds and c.mana() == 18, "(nothing is read or added any more)")
    check(changes == 0 and printedCount(ue, "settings changed (config.lua)") == 0, "what the module's settings wrote themselves is not taken for a change of the file")
    stop(c)

    -- values that are not usable
    c = start("bad", { config = T.config("Config.ManaPercent = 250\nConfig.ManaFlat = -3\nConfig.ManaSeconds = 0\nConfig.ManaUpTo = \"all\"\nConfig.HealthPercent = \"1.5\"\nConfig.HealthSeconds = 100000\n"
        .. "Config.Method = \"magic\"\nConfig.LookSeconds = 0.01\nConfig.SettleSeconds = 500\nConfig.ManaCircleStep = 2.6\nConfig.ManaPause = 0/0") })
    v = c.hook.settings.values
    check(v.ManaPercent == 100 and v.ManaFlat == 0 and v.ManaSeconds == 0.5 and v.ManaUpTo == 100 and v.HealthPercent == 1.5 and v.HealthSeconds == 600 and v.Method == "auto"
        and v.LookSeconds == 0.25 and v.SettleSeconds == 120 and v.ManaCircleStep == 3 and v.ManaPause == 10,
        "out of range, of the wrong kind, not a number: pulled into range or the default; a number written as text is taken as the number")
    check(printed(c.ue, "config.lua: ManaPercent = 250 is not usable; 100.0 is used") ~= nil and printed(c.ue, "config.lua: Method = magic is not usable; \"auto\" is used") ~= nil and #c.ue.errors == 0,
        "each said in the log")
    stop(c)
    c = start("badstart", { config = "this is not lua\n" })
    check(c.ok and printed(c.ue, "config.lua has an error (") ~= nil and c.hook.settings.values.ManaFlat == 0 and printed(c.ue, "loaded: nothing to regenerate") ~= nil, "a broken file at the start: said, default settings (nothing regenerates)")
    check(T.read(c.path) == "this is not lua\n", "the broken file is left for its owner to repair")
    stop(c)
    c = start("nofile", { config = false })
    check(c.ok and printed(c.ue, "config.lua was not there: written with the default settings") ~= nil and T.read(c.path) == shipped, "no file at the start: the default file is written")
    stop(c)
    c = start("noschema", { files = { ["Scripts/schema.lua"] = false } })
    check(c.ok and printed(c.ue, "[G1R_Regen] the settings could not be set up (schema.lua could not be read") ~= nil and #c.ue.loops == 1 and c.ue.console.regen == nil,
        "without schema.lua the module says so and does not start")
    stop(c)
    c = start("off", { config = T.config(PLAYER .. "\nConfig.Enabled = false") })
    c.at(60)
    check(printed(c.ue, "[G1R_Regen] v1.0.0 loaded: switched off in the settings\n") ~= nil and c.mana() == 10 and allOf(c.ue) == 0 and sum(c.world.asked) == 0,
        "Enabled = false at the start: the load line says so, the game is not looked at")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("14. the note on screen")
do
    local NOTES = "Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ManaPause = 2\nConfig.ManaUpTo = 50\nConfig.HealthFlat = 5\nConfig.HealthSeconds = 1\nConfig.HealthPause = 2\nConfig.SettleSeconds = 0\nConfig.ShowMessage = true"
    local c = start("note", { config = T.config(NOTES), widgets = true, game = { values = { Mana = 12.0, Health = 90.0 } } })
    local ue, w, ui = c.ue, c.world, c.ui
    c.at(0)
    local perPath = {}
    for _, p in ipairs(ue.lookups) do perPath[p] = (perPath[p] or 0) + 1 end
    local once, paths = true, 0
    for _, n in pairs(perPath) do paths = paths + 1 if n ~= 1 then once = false end end
    check(once and paths == 7 and ui.created == 0, "when the hero is found the six paths of the note are searched (and the engine's pause question), each once; nothing is built yet")
    c.at(2.5)
    check(ui.created == 0 and ui.note() == nil, "no note while the wait runs")
    c.at(3)
    check(c.mana() == 13 and ui.created == 1 and has(ui.note(), "Mana regenerates again") and has(ui.note(), "Health regenerates again"),
        "the first step after the wait: one note for mana, one for health, both on screen")
    c.at(4)
    check(c.mana() == 14 and c.health() == 100 and has(ui.note(), "Mana regenerates again") and has(ui.note(), "Health has regenerated (100 of 100)") and not has(ui.note(), "Health regenerates again"),
        "health reaches its limit: its note is replaced; a step in between brings no new note for mana")
    c.at(5)
    check(c.mana() == 15 and has(ui.note(), "Mana has regenerated (15 of 30)"), "mana reaches its limit (50 % of 30): Mana has regenerated (15 of 30)")
    local sets = ui.count("SetText")
    c.at(20)
    check(ui.count("SetText") <= sets + 2 and ui.note() == nil, "at the limit no further note; the two notes go away after their three seconds")
    -- a spell, the wait, the first step: the note again
    w.effect("Mana", -5)
    c.at(22.5)
    check(ui.note() == nil, "a loss shows nothing")
    c.at(23)
    check(c.mana() == 11 and ui.note() == "Mana regenerates again", "after the wait the first step says so again")
    sets = ui.count("SetText")
    c.at(25)
    check(c.mana() == 13 and ui.count("SetText") == sets, "the steps that follow do not")
    -- switched off while a note is up
    w.effect("Mana", -5)
    c.at(28)
    local up = ui.note()
    T.write(c.path, T.config(NOTES:gsub("ShowMessage = true", "ShowMessage = false")))
    ue:fireConsole("regen reload")
    check(up == "Mana regenerates again" and ui.note() == nil, "ShowMessage = false while a note is up: it is hidden at once")
    local calls = #ui.calls
    w.effect("Mana", -5)
    c.at(42)
    check(#ui.calls == calls and c.mana() == 15, "ShowMessage = false: mana regenerates to its limit, the widget is left alone")
    check(#ue.lookups == 7 and #ue.errors == 0, "nothing was searched again")
    stop(c)

    -- the limit is raised while the value stands at it; the hero is laid out and gets up again
    for _, from in ipairs({ 14.0, 15.0 }) do
        c = start("note-limit" .. from, { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ManaUpTo = 50\nConfig.ShowMessage = true" .. QUICK), widgets = true, game = { values = { Mana = from } } })
        c.at(6)
        check(c.mana() == 15 and c.ui.note() == nil, from .. " mana, limit 15: at the limit (" .. (from < 15 and "reached by a step" or "from the start") .. "), no note up")
        T.write(c.path, T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ManaUpTo = 100\nConfig.ShowMessage = true" .. QUICK))
        c.ue:fireConsole("regen reload")
        c.at(7)
        check(c.mana() == 16 and c.ui.note() == "Mana regenerates again", "the limit is raised: the first step above the old limit says that mana regenerates again")
        stop(c)
    end
    c = start("note-down", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ShowMessage = true" .. QUICK), widgets = true })
    c.at(2)
    c.world.tags["State.Defeated"] = 1
    c.at(10)
    check(c.mana() == 12 and c.ui.note() == nil, "unconscious: nothing, and the note of the start is gone")
    c.world.tags["State.Defeated"] = nil
    c.at(11)
    check(c.mana() == 13 and c.ui.note() == "Mana regenerates again", "up again: the first step says so")
    stop(c)

    -- one step from far below to the limit: only the second note
    c = start("note-one", { config = T.config("Config.HealthFlat = 50\nConfig.HealthSeconds = 1\nConfig.ShowMessage = true" .. QUICK), widgets = true, game = { values = { Health = 70.0 } } })
    c.at(1)
    check(c.ui.note() == "Health has regenerated (100 of 100)" and c.ui.count("SetText") == 1, "a step that reaches the limit at once shows one note: Health has regenerated (100 of 100)")
    stop(c)
    -- shipped: no note, and the paths of the note are not searched
    c = start("note-off", { config = MANA1, widgets = true })
    c.at(5)
    check(c.mana() == 15 and c.ui.created == 0 and #c.ue.lookups == 1, "ShowMessage = false (as shipped): no widget, no search for one")
    stop(c)
    -- notes switched off altogether on the page General
    c = start("notes-off", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ShowMessage = true" .. QUICK), widgets = true })
    c.kit.configureNotes({ style = "off" })
    c.at(5)
    check(c.mana() == 15 and c.ui.created == 0 and #c.ui.subtitles == 0 and #c.ue.lookups == 1, "notes switched off for the whole mod: mana regenerates, nothing is searched or shown")
    stop(c)
    -- the game's own line
    c = start("subtitle", { config = T.config("Config.ManaFlat = 1\nConfig.ManaSeconds = 1\nConfig.ShowMessage = true" .. QUICK), widgets = true })
    c.kit.configureNotes({ style = "subtitle", seconds = 4 })
    c.at(1)
    check(#c.ui.subtitles == 1 and c.ui.subtitles[1].text == "Mana regenerates again" and c.ui.subtitles[1].seconds == 4 and c.ui.created == 0, "notes as the game's own line: Mana regenerates again")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("15. console command and status")
do
    local c = start("console", { config = T.config(PLAYER), game = { values = { Health = 20.0 } } })
    local ue, w = c.ue, c.world
    local before = #ue.printed
    check(ue:fireConsole("regen") == true and #ue.errors == 0, "regen: handled (a boolean is returned)")
    check(ue.printed[before + 1] == "[G1R_Regen] v1.0.0 | mana +2% every 3 s up to 75%, pause 15 s; health +1 and +1% every 5 s up to 50%, pause 30 s\n"
        and ue.printed[before + 2] == "[G1R_Regen] mana: the hero's mana has not been found yet (no game loaded?)\n"
        and ue.printed[before + 3] == "[G1R_Regen] health: the hero's health has not been found yet (no game loaded?)\n"
        and ue.printed[before + 4] == "[G1R_Regen] restored: mana +0 in 0 steps, health +0 in 0 steps\n"
        and ue.printed[before + 5] == "[G1R_Regen] time counted: 0 s; looks that counted nothing: 0 in the engine's pause, 0 with the game's clock standing still\n"
        and #ue.printed == before + 5, "before a game is loaded: the settings, nothing found, nothing restored, no time counted")
    check(#ue.device.lines == 5 and ue.device.lines[1] == "[G1R_Regen] v1.0.0 | mana +2% every 3 s up to 75%, pause 15 s; health +1 and +1% every 5 s up to 50%, pause 30 s", "the same lines go to the console window")
    c.at(4)
    local lines = c.hook.status()
    check(lines[2] == "mana 10: waiting 11 s after a loss or a load" and lines[3] == "health 20: waiting 26 s after a loss or a load", "during the wait after a load: " .. lines[2] .. " | " .. lines[3])
    c.at(19)
    lines = c.hook.status()
    check(lines[2] == "mana 10 of 30: regenerating, next step in 2 s" and lines[3] == "health 20: waiting 11 s after a loss or a load", "regenerating: " .. lines[2])
    c.at(19.5)
    check(c.hook.status()[2] == "mana 10 of 30: regenerating, next step in 1.5 s", "the time to the next step counts down")
    c.at(200)
    lines = c.hook.status()
    check(lines[2] == "mana 22 of 30: at its limit" and lines[3] == "health 50 of 100: at its limit" and lines[4] == "restored: mana +12 in 12 steps, health +30 in 15 steps; written by ability system",
        "at the limit: " .. lines[2] .. " | " .. lines[4])
    check(ue:fireConsole("g1r_regen status") == true and ue:fireConsole("regen something") == true, "g1r_regen works too; an unknown word shows the status")
    before = #ue.printed
    ue:fireConsole("regen reload")
    check(ue.printed[before + 1] == "[G1R_Regen] settings read: mana +2% every 3 s up to 75%, pause 15 s; health +1 and +1% every 5 s up to 50%, pause 30 s\n", "regen reload reads the file also when it has not changed")
    ue:fireConsole("regen RELOAD")
    check(printedCount(ue, "settings read:") == 2, "the word may be written in capitals")
    os.remove(c.path)
    before = #ue.printed
    ue:fireConsole("regen reload")
    check(ue.printed[before + 1] == "[G1R_Regen] settings not read: config.lua not found\n", "regen reload without a file: said")
    check(c.hook.console(nil, nil, nil) == true and c.hook.console("regen reload", nil, nil) == true and c.hook.console("regen", { 2, {} }, {}) == true and #ue.errors == 0,
        "called with nothing, with the command line only, with parameters of another kind: handled")
    check(printedCount(ue, "settings not read:") == 2, "with the command line only, the words are taken from it (regen reload)")
    check(c.hook.num(2) == "2" and c.hook.num(0.5) == "0.5" and c.hook.num(1.25) == "1.25" and c.hook.num(10) == "10" and c.hook.num(100) == "100" and c.hook.num(0) == "0"
        and c.hook.num(2.50) == "2.5" and select("#", c.hook.num(3)) == 1, "numbers are written as short as they can be: 2, 0.5, 1.25, 10, 100")
    stop(c)

    c = start("summary", { config = T.config("Config.ManaFlat = 1.5\nConfig.ManaPercent = 0.25\nConfig.ManaSeconds = 2.5\nConfig.ManaByCircle = true\nConfig.ManaArmedPercent = 0\nConfig.HealthEnabled = false\nConfig.HealthFlat = 3") })
    check(printed(c.ue, "[G1R_Regen] v1.0.0 loaded: mana +1.5 and +0.25% every 2.5 s up to 100%, pause 10 s, 0% with a weapon drawn, by magic circle\n") ~= nil,
        "the load line names what is set: " .. tostring(c.ue.printed[1]):gsub("\n", ""))
    check(has(status(c), "|health: switched off|"), "a value switched off is named as such in the status")
    stop(c)
    c = start("summary2", { config = T.config("Config.HealthFlat = 3\nConfig.ManaEnabled = true") })
    check(has(status(c), "|mana: nothing to regenerate (the amount is 0)|health: the hero's health has not been found yet"), "a value without an amount is named as such")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("16. what the module asks of the game (counted)")
do
    -- everything the model counts, as one text: reads of attribute structs, calls, the player state asked for its
    -- ability system, searches
    local function snap(c)
        local w, ue = c.world, c.ue
        local t = { state = w.reads[21] or 0, FindAllOf = ue.calls.FindAllOf or 0, FindFirstOf = ue.calls.FindFirstOf or 0, lookups = #ue.lookups }
        for k, v in pairs(w.asked) do t[k] = v end
        for k, v in pairs(w.calls) do t[k] = v end
        return t
    end
    local ORDER = { "Mana", "MaxMana", "Health", "MaxHealth", "MagicianLevel", "IsGamePaused", "TotalSeconds", "HasGameplayTag", "TrySetAttributeBaseValue", "RemoveTag", "state", "FindAllOf", "FindFirstOf", "lookups" }
    local function since(a, b)
        local out = {}
        for _, k in ipairs(ORDER) do
            local n = (b[k] or 0) - (a[k] or 0)
            if n ~= 0 then out[#out + 1] = k .. " " .. n end
        end
        return table.concat(out, ", ")
    end
    local c = start("cost", { config = T.config(PLAYER), game = { values = { Health = 20.0, Mana = 0.0, MaxMana = 200.0, MaxHealth = 400.0 } } })
    c.at(0)
    local first = snap(c)
    check(since({}, first) == "Mana 1, Health 1, IsGamePaused 1, TotalSeconds 1, state 2, FindAllOf 1, FindFirstOf 1, lookups 1",
        "the first look: one search for the controller, one for the game's clock, one by path (the engine's pause question); each value read once (" .. since({}, first) .. ")")
    c.at(60)
    local one = snap(c)
    c.at(120)
    local two = snap(c)
    check(c.mana() == 140 and c.health() == 110, "(the second minute: mana 4 every 3 s, health 5 every 5 s)")
    check(since(one, two) == "Mana 140, MaxMana 20, Health 132, MaxHealth 12, IsGamePaused 120, TotalSeconds 120, HasGameplayTag 116, TrySetAttributeBaseValue 32, state 56",
        "a minute of regenerating: " .. since(one, two))
    check((two.FindAllOf - one.FindAllOf) == 0 and (two.FindFirstOf - one.FindFirstOf) == 0 and two.lookups == one.lookups, "no search of any kind in that minute")
    c.at(1200)
    local three = snap(c)
    c.at(1260)
    local four = snap(c)
    check(c.mana() == 150 and c.health() == 200 and since(three, four) == "Mana 120, MaxMana 20, Health 120, MaxHealth 12, IsGamePaused 120, TotalSeconds 120, state 24",
        "a minute at the limit: two values per look, the maximum when a step is due, the pause and the clock; no tag, no write (" .. since(three, four) .. ")")
    check(four.FindAllOf == 1 and four.FindFirstOf == 1 and four.lookups == 1, "twenty-one minutes with the three searches of the first look")
    -- the pause menu
    c.world.paused = true
    c.at(1320)
    local five = snap(c)
    check(since(four, five) == "IsGamePaused 120, state 24", "a minute in the pause menu: the pause question only (" .. since(four, five) .. ")")
    stop(c)

    c = start("cost-mana", { config = T.config("Config.ManaPercent = 2\nConfig.ManaSeconds = 3\nConfig.ManaUpTo = 75\nConfig.ManaPause = 15\nConfig.ManaByCircle = true\nConfig.ManaArmedPercent = 50"),
        game = { values = { Mana = 0.0, MaxMana = 200.0 } } })
    c.at(60)
    local a = snap(c)
    c.at(120)
    local b = snap(c)
    check(since(a, b) == "Mana 140, MaxMana 20, MagicianLevel 20, IsGamePaused 120, TotalSeconds 120, HasGameplayTag 100, TrySetAttributeBaseValue 20, state 32",
        "mana only, with the circle and the weapon setting: health is never read (" .. since(a, b) .. ")")
    stop(c)

    c = start("cost-idle", {})
    c.at(600)
    check(since({}, snap(c)) == "", "the shipped settings, ten minutes: nothing at all")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("17. the diagnostics")
do
    local c = start("diag", { config = T.config(PLAYER .. "\nConfig.ManaByCircle = true\nConfig.HealthArmedPercent = 50"), diag = true, game = { level = 2.0, values = { Health = 20.0, Mana = 1.0 } } })
    local ue, w = c.ue, c.world
    c.at(40)
    w.effect("Mana", -10)       -- a spell uses up the mana
    c.at(80)
    w.paused = true
    c.at(82)
    w.paused = false
    w.clock.stands = true
    c.at(84)
    w.clock.stands = false
    c.at(300)
    local sequence = table.concat(c.fake.sequence(), " ")
    check(sequence == "regen.game_clock=readable regen.mana.set_found_by=player state regen.health.set_found_by=player state regen.mana.readable=yes regen.tags=only no so far regen.circle=2"
        .. " regen.mana.write=ability system regen.mana.block=not set regen.health.readable=yes regen.health.write=ability system regen.tags=readable regen.mana.block=cleared"
        .. " regen.engine_pause=seen regen.clock_stood=seen", "the notes of a session, each when its value changes: " .. sequence)
    for _, key in ipairs({ "regen.mana.set_found_by", "regen.health.set_found_by", "regen.game_clock", "regen.mana.readable", "regen.health.readable", "regen.circle",
        "regen.mana.write", "regen.health.write", "regen.engine_pause", "regen.clock_stood" }) do
        if c.fake.count[key] ~= 1 then check(false, "the note " .. key .. " was made " .. tostring(c.fake.count[key]) .. " times") end
    end
    check(c.fake.count["regen.tags"] == 2 and c.fake.count["regen.mana.block"] == 2, "the tags are noted twice (only no so far, then readable when the casting block answered yes), the block twice")
    check(c.fake.versions[1] == "1.0.0" and #c.fake.events == 2
        and c.fake.events[1] == "first mana step: 1 -> 2 of 30, by ability system, found through the player state"
        and c.fake.events[2] == "first health step: 20 -> 22 of 100, by ability system, found through the player state", "version and the first step of each value go to the diagnostics: " .. tostring(c.fake.events[1]))
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
    check(dump.version == "1.0.0" and dump.enabled == true and dump.method == "auto" and dump.written_by == "ability system" and dump.direct_fallback == false and dump.casting_block_cleared == 1
        and dump.looking == true and dump.by_circle == true and dump.circle.step == 10 and dump.settle_seconds == 5 and dump.look_seconds == 0.5 and dump.tags_unusable == false,
        "what the module holds: the settings, the way of writing, the casting block")
    check(dump.mana.value == 22 and dump.mana.maximum == 30 and dump.mana.phase == "full" and dump.mana.percent == 2 and dump.mana.up_to == 75 and dump.mana.pause == 15 and dump.mana.losses == 1
        and dump.mana.found_through == "player state" and dump.mana.attributes == w.hero.mana:GetFullName() and dump.mana.given_up == false and dump.mana.steps == 27 and dump.mana.added == 5 + 22,
        "mana: value, maximum, state, what was restored")
    check(dump.health.value == 50 and dump.health.flat == 1 and dump.health.armed_percent == 50 and dump.health.seconds == 5 and dump.health.added == 30 and dump.health.failed_steps == 0, "health likewise")
    check(dump.seconds_counted == 296 and dump.looks_engine_paused == 4 and dump.looks_clock_stood == 4 and dump.not_counting == nil,
        "the time: 296 of 300 seconds counted, four looks in the engine's pause, four with the game's clock standing still")
    check(#statusLines == 5 and statusLines[1] == c.hook.status()[1]
        and statusLines[5] == "time counted: 296 s; looks that counted nothing: 4 in the engine's pause, 4 with the game's clock standing still", "the status function gives the status lines")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("18. nothing leaks, only config.lua is written")
do
    local known = {}
    local probe = T.Mock.new()
    probe:install()                 -- what the mock itself puts into _G does not count
    for k in pairs(_G) do known[k] = true end
    probe:uninstall()
    local given = { REGEN_TEST = true, ModRef = true, G1R_KIT = true, G1R_SETTINGS = true, G1R_DIAG = true, Key = true, ModifierKey = true, StaticConstructObject = true }
    local c = start("leak", { config = T.config(PLAYER .. "\nConfig.ShowMessage = true" .. QUICK), widgets = true, diag = true, game = { values = { Health = 20.0 } } })
    c.at(60)
    c.ue:fireConsole("regen")
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
    check(listing:gsub("config%.lua%.bak ", "") == "config.lua main.lua schema.lua ", "the module writes no file of its own (its folder holds: " .. listing .. ")")
end

-- ---------------------------------------------------------------------------
section("19. the shipped files")
do
    local schema = dofile(MOD .. "modules/regen/Scripts/schema.lua")
    local chunk = load(shipped, "=config.lua", "t", {})
    local values = chunk and chunk() or {}
    local keys = {}
    for k in pairs(values) do keys[#keys + 1] = k end
    table.sort(keys)
    check(table.concat(keys, ",") == "Enabled,HealthArmedPercent,HealthEnabled,HealthFlat,HealthPause,HealthPercent,HealthSeconds,HealthUpTo,LogSteps,ManaArmedPercent,ManaByCircle,"
        .. "ManaCircleFirst,ManaCircleNone,ManaCircleNovice,ManaCircleStep,ManaEnabled,ManaFlat,ManaPause,ManaPercent,ManaSeconds,ManaUpTo,ShowMessage"
        and not shipped:find("\r", 1, true) and not shipped:find("[^\n\32-\126]"), "the shipped config.lua: 22 settings, plain ASCII, LF line ends (" .. #keys .. ")")
    local probe = start("default-text", {})
    check(probe.settings.defaultText(schema) == shipped, "the shipped config.lua is exactly what the schema generates (lua5.4 dev/tools/gen_config.lua regen)")
    stop(probe)
    check(schema.Module == "regen" and schema.Page == "Combat" and schema.PageOrder == 10, "the schema puts the module on the page Combat (order 10)")
    local orders, titles, first = {}, {}, schema.Groups[1].Items[1]
    for _, g in ipairs(schema.Groups) do
        orders[#orders + 1] = g.Order
        local shown = false
        for _, i in ipairs(g.Items) do if not i.Hidden then shown = true end end
        if shown and not (g.Title:sub(1, 17) == "Mana regeneration" or g.Title:sub(1, 19) == "Health regeneration") then titles[#titles + 1] = g.Title end
    end
    check(table.concat(orders, ",") == "10,14,20,28,29" and #titles == 0 and first.Key == "Enabled" and first.Default == true,
        "its groups have the orders 10 to 29, their titles start with the feature, the first item is the module's switch")
    -- the player's README names every setting that is shown
    local readme = T.read(MOD .. "modules/regen/README.txt") or ""
    local missing = {}
    for _, g in ipairs(schema.Groups) do
        for _, i in ipairs(g.Items) do
            if not readme:find(i.Key, 1, true) then missing[#missing + 1] = i.Key end
        end
    end
    check(#missing == 0 and not readme:find("[^\n\32-\126]"), "README.txt names every setting, also those that are not shown (" .. table.concat(missing, ", ") .. "); plain ASCII")
end

-- ---------------------------------------------------------------------------
section("20. through the megamod loader, with the real diagnostics")
do
    local TMP = T.TMP
    local root = TMP .. "/mega/G1R_MegaMod"
    T.sh("rm -rf " .. T.q(TMP .. "/mega") .. " && mkdir -p " .. T.q(root) .. " && cp -r " .. T.q(MOD .. "Scripts") .. " " .. T.q(root .. "/") .. " && mkdir -p " .. T.q(root .. "/modules")
        .. " && cp -r " .. T.q(MOD .. "modules/regen") .. " " .. T.q(root .. "/modules/"))
    -- only this module: the list of modules is cut down to it (the line the module's report gives for core/modules.lua)
    T.write(root .. "/Scripts/core/modules.lua", 'return { { name = "regen", switch = "Regen", separate = { "G1R_RegenMana" } } }\n')
    local FAST = T.config(PLAYER .. "\nConfig.ManaPause = 1\nConfig.HealthPause = 2\nConfig.SettleSeconds = 0\nConfig.ShowMessage = true")
    T.write(root .. "/modules/regen/Scripts/config.lua", FAST)

    local function boot()
        local ue = T.Mock.new()
        ue:install()
        local ui = T.widgets(ue)
        local world = game(ue, { values = { Health = 20.0 } })
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
        function c.mana() return world.value("Mana") end
        function c.health() return world.value("Health") end
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
    check(c.ok and has(last(c), "loaded: regen ok | diagnostics normal"), "the loader loads the module: " .. last(c))
    check(rawget(_G, "REGEN_TEST") == nil and rawget(_G, "G1R_KIT") == nil and rawget(_G, "G1R_SETTINGS") == nil, "the test hook stays inert; the kit and the settings service are no globals")
    c.looks(1 + 4 * 30)
    check(c.mana() == 15 and c.health() == 30 and w.hud.Mana == 15 and #ue.errors == 0, "mana and health regenerate as without the loader (30 s: 15 and 30)")
    check(c.ui.created == 1 and c.ui.count("SetText") >= 2, "the notes are shown")
    check(ue:fireConsole("g1r diag") == true, "g1r diag handled")
    local report = T.read(c.dir .. "/report-latest.txt") or ""
    check(has(report, "regen: loaded, version 1.0.0") and has(report, "[regen] v1.0.0 | mana +2% every 3 s up to 75%, pause 1 s; health +1 and +1% every 5 s up to 50%, pause 2 s")
        and has(report, "[regen] mana 15 of 30: regenerating, next step in") and has(report, "[regen] restored: mana +5 in 5 steps, health +10 in 5 steps; written by ability system"),
        "report: the module's version and its status lines")
    check(has(report, "regen.mana.set_found_by = player state") and has(report, "regen.health.set_found_by = player state") and has(report, "regen.mana.readable = yes") and has(report, "regen.mana.write = ability system")
        and has(report, "regen.health.write = ability system") and has(report, "regen.tags = only no so far") and has(report, "regen.mana.block = not set") and has(report, "regen.game_clock = readable")
        and has(report, "kit.toast = shown"), "report: the notes of the module and of the kit")
    check(has(report, "[regen] callbacks LoopInGameThreadWithDelay: 121 calls, 0 errors") and has(report, "[kit] lookups: 7 calls, 7 first-time, 0 not found")
        and has(report, "[loader] callbacks services: 121 calls, 0 errors"), "report: the module's loop, the kit's seven searches and the loader's own loop are counted")
    local log = newest(c, "session-")
    check(has(log, "[regen] first mana step: 10 -> 11 of 30, by ability system, found through the player state") and has(log, "[regen] [G1R_Regen] v1.0.0 loaded: mana +2% every 3 s up to 75%, pause 1 s"),
        "session log: the load line and the first step")
    check(has(log, "[kit] lookup /Script/Engine.Default__GameplayStatics") and not has(log, "ERROR in "), "session log: a search is announced before it runs; no error")
    check(ue:fireConsole("g1r dump") == true, "g1r dump handled")
    local okDump, dump = pcall(load(newest(c, "dump-"), "=dump", "t", {}))
    check(okDump and type(dump) == "table" and type(dump.regen) == "table" and dump.regen.mana.value == 15 and dump.regen.health.value == 30 and dump.regen.written_by == "ability system"
        and dump.regen.mana.found_through == "player state" and dump._meta.refusedCount == 0, "dump: what the module holds")
    check(ue:fireConsole("g1r") == true and printed(ue, "[G1R_MegaMod] regen: loaded, version 1.0.0, 0 error(s), 9 note(s)") ~= nil, "g1r lists the module with its notes")
    check(ue:fireConsole("regen") == true and printed(ue, "[G1R_Regen] mana 15 of 30: regenerating") ~= nil, "the module's own console command works through the loader")
    -- settings through the loader: the in-game menu
    local page = c.mods.store["SMM:schema:G1R Combat"]
    check(c.mods.store["SMM:index"] == "G1R Combat" and type(page) == "string" and has(page, "Mana regeneration") and has(page, "Health regeneration"), "the page G1R Combat is registered with the in-game menu")
    c.mods.store["SMM:cmd:G1R Combat"] = "4\31n5"            -- the fourth item of the page: points of mana per step
    c.looks(13)
    check(printed(ue, "[G1R_Regen] settings changed (in-game menu): mana +5 and +2% every 3 s up to 75%, pause 1 s; health") ~= nil and c.mana() == 21,
        "an edit in the in-game menu reaches the module through the loader's loop: the next step gives 5 and the carried fraction")
    check(has(T.read(root .. "/modules/regen/Scripts/config.lua"), "Config.ManaFlat = 5.0\n"), "and is written into the module's config.lua")
    shutdown(c)

    -- the other author's native mod is installed and enabled next to the megamod: the module is not loaded
    T.sh("mkdir -p " .. T.q(TMP .. "/mega/G1R_RegenMana/dlls"))
    T.write(TMP .. "/mega/G1R_RegenMana/dlls/main.dll", "MZ")
    T.write(TMP .. "/mega/G1R_RegenMana/enabled.txt", "")
    T.write(root .. "/modules/regen/Scripts/config.lua", FAST)
    c = boot()
    check(c.ok and has(last(c), "regen left to the separate mod G1R_RegenMana")
        and printed(c.ue, "module regen not loaded: the separate mod G1R_RegenMana is installed and enabled") ~= nil,
        "G1R_RegenMana (a native mod: dlls/main.dll) enabled next to the megamod: " .. last(c))
    c.looks(1 + 4 * 30)
    check(c.mana() == 10 and c.health() == 20 and c.mods.store["SMM:index"] == nil and sum(c.world.asked) == 0, "nothing regenerates through this mod, no page is registered with the in-game menu")
    shutdown(c)
    os.remove(TMP .. "/mega/G1R_RegenMana/enabled.txt")
    c = boot()
    check(has(last(c), "regen ok"), "the same folder without enabled.txt and without a line in mods.txt: the module is loaded")
    shutdown(c)
    T.write(TMP .. "/mega/mods.txt", "G1R_RegenMana : 1\r\n")
    c = boot()
    check(has(last(c), "regen left to the separate mod G1R_RegenMana"), "enabled through mods.txt: not loaded")
    shutdown(c)
    os.remove(TMP .. "/mega/mods.txt")
    T.sh("rm -rf " .. T.q(TMP .. "/mega/G1R_RegenMana"))

    -- switched off in the megamod's own settings
    T.write(root .. "/Scripts/config.lua", T.config("Config.Modules = { Regen = false }"))
    c = boot()
    check(has(last(c), "loaded: regen off |"), "Config.Modules.Regen = false: the module is not loaded")
    shutdown(c)

    -- diagnostics off: the module runs as on its own
    T.write(root .. "/Scripts/config.lua", T.config('Config.Diagnostics = { Level = "off" }'))
    T.write(root .. "/modules/regen/Scripts/config.lua", FAST)
    c = boot()
    c.looks(1 + 4 * 30)
    check(printed(c.ue, "regen ok | diagnostics off") ~= nil and c.mana() == 15 and c.health() == 30 and #c.ue.errors == 0, "diagnostics off: mana and health regenerate, no error")
    shutdown(c)

    -- a loader without its kit: the module says what it needs
    os.remove(root .. "/Scripts/core/kit.lua")
    c = boot()
    check(c.ok and printed(c.ue, "[G1R_MegaMod] core/kit.lua could not be used") ~= nil
        and printed(c.ue, "[G1R_Regen] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started") ~= nil,
        "core/kit.lua missing: the loader says so, the module says what it needs and does not start")
    check(has(last(c), "regen ok") and not has(table.concat(c.ue.printed), "failed to load"), "that is not an error of the module: " .. last(c))
    c.looks(1 + 4 * 30)
    check(c.mana() == 10 and c.health() == 20 and #c.ue.errors == 0, "and nothing regenerates, no error")
    shutdown(c)
end

T.finish()
