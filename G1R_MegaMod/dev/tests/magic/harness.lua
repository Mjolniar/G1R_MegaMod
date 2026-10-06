-- ============================================================================
-- Offline tests of the module magic (modules/magic/Scripts/main.lua).
--
--   lua5.4 harness.lua          (from any directory)
--
-- The module runs on the loader's kit and settings service; ../lib/modtest.lua
-- sets both up the way the loader does and replaces UE4SS by ../mock/ue4ss.lua.
-- The game's spell data is modelled here from game.lua (the numbers of the
-- game's scripts, each with its source): default objects of the definition,
-- config, hit effect and skill classes, handed out the way UE4SS hands them
-- out, and the game's own use of them (damage by the caster's circle, mana,
-- casting time, the freeze counter, the price of a circle).
-- Sections 1-15 run the module that way, section 16 through the real loader
-- with the real diagnostics; section 17 holds the facts file against both.
-- Last line: "magic tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
local Game = dofile(HERE .. "game.lua")
T.init("magic")
local section, has, printed, printedCount = T.section, T.has, T.printed, T.printedCount
-- Run by the mutation check (dev/tools/mutate.py gives every run a folder of its own below "g1r-mutate-..."): the
-- first failed check is all that check needs, so the suite stops there. Any other run does every check.
local FAST = (os.getenv("G1R_TEST_TMP") or ""):find("g1r-mutate-", 1, true) ~= nil
local function check(condition, text)
    local ok = T.check(condition, text)
    if FAST and not ok then T.finish() end
    return ok
end
local MOD = T.MOD
local PATH = "/Script/Angelscript.Default__"

-- ---------------------------------------------------------------------------
-- The model of the game's data as UE4SS shows it
--
-- What is modelled, and where it is known from:
--   * a default object is found by StaticFindObject("/Script/Angelscript.Default__<Name>") and is called
--     "<Name> /Script/Angelscript.Default__<Name>": IN-GAME for the path (the other author's mod found 36 of these
--     objects that way, log of 2026-10-01); the full name is how UE names a class default object;
--   * reading a property the object does not have gives an invalid object (not nil), writing one does nothing and
--     raises nothing: UE4SS source, LuaUObject.cpp handle_unreal_property_value;
--   * a map: ForEach(function(key, value)), value:get() / value:set(v) on the game's memory: UE4SS source
--     LuaTMap.cpp; IN-GAME for reading (the other mod printed the base damage it read that way) and FACTS U9;
--   * an array: ForEach(function(index, element)), element:get() is a struct wrapper on the game's memory; GetArrayNum;
--     indexing at or past the length adds an element (FACTS U6) - the model counts that in world.indexed;
--   * a struct wrapper: fields read and written in place, an unknown field raises, IsValid() is true: UE4SS source
--     LuaUScriptStruct.cpp;
--   * float properties keep single precision (native float32: m_Speed, m_SuperArmorDamageBase, m_AreaRange, SPCost,
--     the three numbers of a spell level, the damage map and steps: property layout, usmap); the heal map is a map of
--     doubles (a script `float`); the freeze flag is a bool.
-- The game's side (world.damage and so on) follows the game's scripts and executable; each function says where.
-- ---------------------------------------------------------------------------
local function f32(v) return (string.unpack("f", string.pack("f", v))) end

local function build(ue, world, options)
    options = options or {}
    local data = { definitions = {}, configs = {}, effects = {}, skills = {} }
    world.data = data
    world.reads, world.writes, world.walks, world.keys, world.indexed = 0, 0, 0, 0, 0
    world.read = {}                 -- "Object.property" -> how often it was read
    world.objects = {}              -- name -> object
    world.hidden = {}               -- name -> true: this build of the game does not have the object
    world.frozen = {}               -- name -> true: writes to this object's data do not stay
    world.raising = {}              -- "Object.field" -> true: writing it raises
    world.twist = {}                -- "Object.field" -> function(v): what a write of v really stores
    world.broken = {}               -- "Object.property" -> true: this list or map cannot be walked
    world.sealed = {}               -- "Object.property" -> true: the values of this map cannot be read (get() raises)
    world.crossed = 0               -- errors that left a function UE4SS was running inside a walk (ForEach)
    -- UE4SS runs the function it is given once per element. An error in it has to pass through UE4SS's own code
    -- (upstream LuaMadeSimple call_function: lua_pcall, then a C++ exception): the model counts such errors.
    local function run(f, ...)
        local ok, result = pcall(f, ...)
        if ok then return result end
        world.crossed = world.crossed + 1
        error(result, 0)
    end

    local function wrote(owner, field)
        world.writes = world.writes + 1
        if world.raising[owner .. "." .. field] then error("write refused (test)") end
        return not world.frozen[owner]
    end
    local function stored(owner, field, v, single)
        local twist = world.twist[owner .. "." .. field]
        if twist then v = twist(v) end
        if single and type(v) == "number" then return f32(v) end
        return v
    end
    -- a struct of the game's data: `store` holds the fields, `single` names the single precision ones
    local function struct(owner, store, single)
        return setmetatable({}, {
            __index = function(_, k)
                if k == "IsValid" then return function() return true end end
                if store[k] == nil then error("Was unable to retrieve property '" .. tostring(k) .. "'", 0) end
                world.reads = world.reads + 1
                return store[k]
            end,
            __newindex = function(_, k, v)
                if store[k] == nil then error("Was unable to retrieve property '" .. tostring(k) .. "'", 0) end
                if wrote(owner, k) then store[k] = stored(owner, k, v, single[k]) end
            end,
        })
    end
    local function array(owner, name, items, single)
        local a = {
            GetArrayNum = function() return #items end,
            ForEach = function(_, f)
                world.walks = world.walks + 1
                if world.broken[owner .. "." .. name] then error("the array cannot be walked (test)") end
                for i, item in ipairs(items) do
                    if run(f, i, { get = function() return struct(owner, item, single) end }) == true then break end
                end
            end,
        }
        return setmetatable(a, { __index = function(_, k)
            if type(k) == "number" then         -- what UE4SS does to the game's array when it is indexed past its end
                world.indexed = world.indexed + 1
                items[#items + 1] = {}
            end
            return nil
        end })
    end
    -- pairs: list of { key = tag name, value = number or struct store }; `wrap` turns a store into what get() returns
    local function map(owner, name, list, single, wrap)
        return {
            ForEach = function(_, f)
                world.walks = world.walks + 1
                if world.broken[owner .. "." .. name] then error("the map cannot be walked (test)") end
                for _, pair in ipairs(list) do
                    local key = { get = function()
                        world.keys = world.keys + 1
                        return { TagName = { ToString = function() return pair.key end } }
                    end }
                    local value = {
                        get = function()
                            world.reads = world.reads + 1
                            if world.sealed[owner .. "." .. name] then error("the value cannot be read (test)") end
                            if wrap then return wrap(pair.value) end
                            return pair.value
                        end,
                        set = function(_, v)
                            if wrote(owner, name) then pair.value = stored(owner, name, v, single) end
                        end,
                    }
                    if run(f, key, value) == true then break end
                end
            end,
        }
    end
    local function object(name, props)
        local o = ue:object(name .. " " .. PATH .. name, {})
        local base = getmetatable(o).__index
        setmetatable(o, {
            __index = function(t, k)
                if base[k] ~= nil then return base[k] end
                if type(k) ~= "string" or k:sub(1, 2) == "__" then return rawget(t, k) end
                world.reads = world.reads + 1
                world.read[name .. "." .. k] = (world.read[name .. "." .. k] or 0) + 1
                local p = props[k]
                if p == nil then return ue:invalid() end
                return p.get()
            end,
            __newindex = function(t, k, v)
                if type(k) ~= "string" or k:sub(1, 2) == "__" then return rawset(t, k, v) end
                local p = props[k]
                if p == nil or p.set == nil then return end
                if wrote(name, k) then p.set(stored(name, k, v, false)) end
            end,
        })
        world.objects[name] = o
        if options.absent and options.absent[name] then world.hidden[name] = true else ue.objects[PATH .. name] = o end
        return o
    end
    local function plain(store, field, single)
        return { get = function() return store[field] end, set = function(v) store[field] = single and f32(v) or v end }
    end
    local function without(name, props)
        for _, lacking in ipairs(options.lacking and options.lacking[name] or {}) do props[lacking] = nil end
        return props
    end

    for _, d in ipairs(Game.definitions) do
        local live = { name = d.name, base = { { key = "Item.Damage.Elemental." .. d.tag, value = d.base } }, steps = {}, speed = d.speed, stagger = d.stagger }
        for _, s in ipairs(d.steps) do live.steps[#live.steps + 1] = { m_CircleTag = s[1], m_Damage = s[2] } end
        local progression = {}
        if #live.steps > 0 then
            progression[1] = { key = live.base[1].key, value = { m_DamageByMagicCircle = true } }
        end
        data.definitions[d.name] = live
        object(d.name, without(d.name, {
            m_DamageBase = { get = function() return map(d.name, "m_DamageBase", live.base, true) end },
            m_DamageMagicCircleProgression = { get = function()
                return map(d.name, "m_DamageMagicCircleProgression", progression, false, function()
                    return setmetatable({}, { __index = function(_, k)
                        if k == "IsValid" then return function() return true end end
                        if k ~= "m_DamageByMagicCircle" then error("Was unable to retrieve property '" .. tostring(k) .. "'", 0) end
                        world.reads = world.reads + 1
                        return array(d.name, "m_DamageByMagicCircle", live.steps, { m_Damage = true })
                    end })
                end)
            end },
            m_Speed = plain(live, "speed", true),
            m_SuperArmorDamageBase = plain(live, "stagger", true),
        }))
    end
    for _, c in ipairs(Game.configs) do
        local live = { name = c.name, levels = {}, range = c.range }
        for _, l in ipairs(c.levels) do live.levels[#live.levels + 1] = { CastManaCost = f32(l[1]), CastTime = f32(l[2]), ManaCostSc = f32(l[3]) } end
        if c.heal then
            live.heal = {}
            for i, v in ipairs(c.heal) do live.heal[i] = { key = "Skill.Mage.Circle." .. i, value = v } end
        end
        data.configs[c.name] = live
        local props = {
            m_SpellLevels = { get = function() return array(c.name, "m_SpellLevels", live.levels, { CastManaCost = true, CastTime = true, ManaCostSc = true }) end },
            m_AreaRange = plain(live, "range", true),
        }
        if c.heal then props.m_healAmountByMagicCircle = { get = function() return map(c.name, "m_healAmountByMagicCircle", live.heal, false) end } end
        object(c.name, without(c.name, props))
    end
    for _, e in ipairs(Game.effects) do
        local live = { name = e.name, stacks = {}, common = {} }
        for _, f in ipairs(e.stacks) do live.stacks[#live.stacks + 1] = { ForceOverflowElementalEffectStack = f } end
        for _, f in ipairs(e.common) do live.common[#live.common + 1] = { ForceOverflowElementalEffectStack = f } end
        data.effects[e.name] = live
        object(e.name, without(e.name, {
            m_ElementalEffectStacks = { get = function() return array(e.name, "m_ElementalEffectStacks", live.stacks, {}) end },
            m_CommonElementalEffectStacks = { get = function() return array(e.name, "m_CommonElementalEffectStacks", live.common, {}) end },
        }))
    end
    for _, s in ipairs(Game.skills) do
        local live = { name = s.name, cost = s.cost }
        data.skills[s.name] = live
        object(s.name, without(s.name, { SPCost = plain(live, "cost", true) }))
    end

    -- ------------------------------------------------------------------ the game's side
    -- USpellProjectileDefinition::GetDamageByCharacterMagicCircle (game.exe 0x145a304c0): the base damage, replaced
    -- by every step whose circle is not above the caster's, in the order of the list; the first step above ends it.
    function world.damage(name, circle)
        local d = data.definitions[name]
        local damage = d.base[1].value
        for _, step in ipairs(d.steps) do
            if step.m_CircleTag > circle then break end
            damage = step.m_Damage
        end
        return damage
    end
    function world.speed(name) return data.definitions[name].speed end
    function world.stagger(name) return data.definitions[name].stagger end
    -- UGameplayAbilityMagicBase::GetCastManaCost / GetLevelCastingTime / GetSpellManaCostPerSecond (0x145b25dc0,
    -- 0x145b27540, 0x145b289f0): the level's three numbers, read from the config's default object at every call.
    function world.mana(name, level) return data.configs[name].levels[level or 1].CastManaCost end
    function world.time(name, level) return data.configs[name].levels[level or 1].CastTime end
    function world.held(name, level) return data.configs[name].levels[level or 1].ManaCostSc end
    function world.range(name) return data.configs[name].range end
    -- GA_Spell_Heal.as 145: the amount of the caster's circle from the config's map (1 = untrained ... 8 = sixth)
    function world.heal(index) return data.configs.HealSpellConfig.heal[index].value end
    -- LearnSkill / HasEnoughSkillpointsToLearnSkill (GASCharacterStateMixins.as 972-1003): the skill class's
    -- default object's SPCost at the moment of learning. n = 0 for the basics, 1-6 for the circles.
    function world.price(n) return data.skills["GE_Skill_Mage_Circle_" .. (n == 0 and "Amateur" or n)].cost end
    -- UGE_Ex_Damage.ApplyStack (Damage.as 603-628) with UGE_IceStack (limit 50): the hit sets the counter to the
    -- limit when its damage reaches the limit or the entry forces it, else to floor(damage - 1); one more stack
    -- follows, and a counter above its limit freezes.
    function world.freezes(name, damage)
        for _, stack in ipairs(data.effects[name].stacks) do
            local count = math.max(0, math.abs(math.floor(damage - 1)))
            if stack.ForceOverflowElementalEffectStack or damage >= Game.ICE_STACK_LIMIT then count = Game.ICE_STACK_LIMIT end
            if count + 1 > Game.ICE_STACK_LIMIT then return true end
        end
        return false
    end
    -- the game puts its own numbers back into one object or all (what a reload of the classes' defaults would do)
    function world.restore(only)
        for _, d in ipairs(Game.definitions) do
            if only == nil or only == d.name then
                local live = data.definitions[d.name]
                live.base[1].value, live.speed, live.stagger = d.base, d.speed, d.stagger
                for i, s in ipairs(d.steps) do live.steps[i].m_Damage = s[2] end
            end
        end
        for _, c in ipairs(Game.configs) do
            if only == nil or only == c.name then
                local live = data.configs[c.name]
                live.range = c.range
                for i, l in ipairs(c.levels) do
                    live.levels[i].CastManaCost, live.levels[i].CastTime, live.levels[i].ManaCostSc = f32(l[1]), f32(l[2]), f32(l[3])
                end
                for i, v in ipairs(c.heal or {}) do live.heal[i].value = v end
            end
        end
        for _, e in ipairs(Game.effects) do
            if only == nil or only == e.name then
                for i, f in ipairs(e.stacks) do data.effects[e.name].stacks[i].ForceOverflowElementalEffectStack = f end
            end
        end
        for _, s in ipairs(Game.skills) do
            if only == nil or only == s.name then data.skills[s.name].cost = s.cost end
        end
    end
    -- Is everything as the game has it? Returns true, or false and the first difference.
    function world.untouched()
        for _, d in ipairs(Game.definitions) do
            local live = data.definitions[d.name]
            if live.base[1].value ~= d.base then return false, d.name .. " base " .. tostring(live.base[1].value) end
            if live.speed ~= d.speed then return false, d.name .. " speed " .. tostring(live.speed) end
            if live.stagger ~= d.stagger then return false, d.name .. " stagger " .. tostring(live.stagger) end
            if #live.steps ~= #d.steps then return false, d.name .. " has " .. #live.steps .. " steps" end
            for i, s in ipairs(d.steps) do
                if live.steps[i].m_Damage ~= s[2] then return false, d.name .. " step " .. i .. " " .. tostring(live.steps[i].m_Damage) end
            end
        end
        for _, c in ipairs(Game.configs) do
            local live = data.configs[c.name]
            if live.range ~= c.range then return false, c.name .. " range " .. tostring(live.range) end
            if #live.levels ~= #c.levels then return false, c.name .. " has " .. #live.levels .. " levels" end
            for i, l in ipairs(c.levels) do
                local now = live.levels[i]
                if now.CastManaCost ~= f32(l[1]) or now.CastTime ~= f32(l[2]) or now.ManaCostSc ~= f32(l[3]) then
                    return false, ("%s level %d %s %s %s"):format(c.name, i, tostring(now.CastManaCost), tostring(now.CastTime), tostring(now.ManaCostSc))
                end
            end
            for i, v in ipairs(c.heal or {}) do
                if live.heal[i].value ~= v then return false, c.name .. " heal " .. i .. " " .. tostring(live.heal[i].value) end
            end
        end
        for _, e in ipairs(Game.effects) do
            local live = data.effects[e.name]
            for i, f in ipairs(e.stacks) do
                if live.stacks[i].ForceOverflowElementalEffectStack ~= f then return false, e.name .. " stack " .. i end
            end
            for i, f in ipairs(e.common) do
                if live.common[i].ForceOverflowElementalEffectStack ~= f then return false, e.name .. " common stack " .. i end
            end
        end
        for _, s in ipairs(Game.skills) do
            if data.skills[s.name].cost ~= s.cost then return false, s.name .. " " .. tostring(data.skills[s.name].cost) end
        end
        return true
    end
    return world
end

local function start(case, options)
    options = options or {}
    options.module, options.hook = "magic", "MAGIC_TEST"
    local more = options.prepare
    options.prepare = function(ue)
        local world = options.reuse
        if world then
            -- the same game, the Lua mods loaded again: the objects are the ones of the run before
            for name, o in pairs(world.objects) do
                if not world.hidden[name] then ue.objects[PATH .. name] = o end
            end
        else
            world = build(ue, T.newWorld(ue, options.hero), options.game)
        end
        if more then more(ue, world) end
        return world
    end
    local c = T.boot(case, options)
    c.S = c.hook and c.hook.state
    -- the object record of the module for a name
    function c.rec(name)
        for _, rec in ipairs(c.hook.objects) do
            if rec.name == name then return rec end
        end
        return nil
    end
    -- how many of the game's data objects were searched (the paths of the note box do not count)
    function c.searches()
        local n = 0
        for _, path in ipairs(c.ue.lookups) do
            if path:sub(1, #PATH) == PATH then n = n + 1 end
        end
        return n
    end
    -- looks until the module has nothing under way (at most `limit`); returns how many it took
    function c.settle(limit)
        local n = 0
        repeat
            c.ticks(1)
            n = n + 1
        until (c.S.queue == nil and c.S.asked == nil) or n >= (limit or 60)
        return n
    end
    return c
end
local stop = T.stop
local function status(c) return table.concat(c.hook.status(), "|") end
local function near(a, b) return math.abs(a - b) <= math.max(1e-6, math.abs(b) * 1e-6) end
local function allOf(ue) return ue.calls.FindAllOf or 0 end
local function firstNote(c, key) return c.fake.values(key)[1] end
local shipped = T.read(MOD .. "modules/magic/Scripts/config.lua")
local function cfg(lines) return T.config(table.concat(lines, "\n")) end

-- ---------------------------------------------------------------------------
section("1. loading with the shipped settings")
do
    local c = start("load")
    local ue, w = c.ue, c.world
    check(c.ok, "the module loads (" .. tostring(c.err) .. ")")
    check(#ue.printed == 1 and ue.printed[1] == "[G1R_Magic] v1.0.1 loaded: everything as the game has it (the game is not touched)\n",
        "one load line: " .. tostring(ue.printed[1]):gsub("\n", ""))
    check(#ue.loops == 2 and ue.loops[2].ms == 250 and math.type(ue.loops[2].ms) == "integer", "one game-thread loop of its own, every 250 ms")
    check(ue.console.magic ~= nil and ue.console.g1r_magic ~= nil and #ue.loadMapPre == 1 and #ue.loadMapPost == 1 and (ue.calls.RegisterHook or 0) == 0,
        "console commands magic and g1r_magic; the kit's hooks before and after a map load; no hook of its own")
    c.ticks(240)
    check(#ue.lookups == 0 and allOf(ue) == 0 and (ue.calls.FindFirstOf or 0) == 0, "a minute of play with the shipped settings: nothing is searched")
    check(w.reads == 0 and w.writes == 0 and w.walks == 0 and w.untouched() and #ue.errors == 0, "nothing is read, nothing is written, the game is untouched")
    local lines = c.hook.status()
    check(#lines == 2 and lines[1] == "v1.0.1 | everything as the game has it (the game is not touched)"
        and lines[2] == "nothing is changed: the game's own numbers are in place and the game is not looked at", "the status says so, in two lines")
    check(T.read(c.path) == shipped, "the settings file is left as it is")
    local v = c.hook.settings.values
    local neutral = true
    for key, value in pairs(v) do
        if type(value) == "number" and (key:find("Damage$") or key:find("Mana$") or key:find("CastTime$") or key:find("^School")) and value ~= 1 then neutral = false end
    end
    check(neutral and v.Enabled == true and v.Damage == 1 and v.ManaCost == 1 and v.CastTime == 1 and v.ProjectileSpeed == 1 and v.Range == 1 and v.Stagger == 1
        and v.HealAmount == 1 and v.WholeMana == true and v.BallLightningSpeed == 0 and v.WindFistStagger == 1 and v.FireBoltSteps == false and v.IceBoltSteps == false
        and v.CircleCosts == false and v.IceBlockFreeze == false and v.IceBoltFreeze == false and v.IceWaveFreeze == false and v.ShowMessage == true
        and v.LogChanges == false and v.SearchesPerLook == 4 and v.CheckSeconds == 60 and v.LookMilliseconds == 250,
        "the shipped file gives the documented defaults: every multiplier 1.0, every switch of a change off")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("2. damage of every spell: the definitions are searched a few per look, read once, changed, read back")
do
    local c = start("damage", { config = cfg({ "Config.Damage = 1.5" }), diag = true })
    local ue, w = c.ue, c.world
    check(printed(ue, "[G1R_Magic] v1.0.1 loaded: damage x1.5\n") ~= nil, "the load line names the multiplier")
    check(#ue.lookups == 0 and w.reads == 0, "loading itself searches and reads nothing")
    c.ticks(1)
    check(#ue.lookups == 4 and ue.lookups[1] == PATH .. "FireBoltProjectileDefinition" and w.damage("FireBoltProjectileDefinition", 0) == 52.5
        and w.damage("BreathOfDeathDefinition", 0) == 150, "the first look searches four objects (SearchesPerLook) and changes them; the rest waits")
    check(has(status(c), "still at work: 4 of 22 object(s) looked at"), "the status says how far the look is")
    c.ticks(4)
    check(#ue.lookups == 20 and c.S.queue ~= nil, "five looks: twenty searches")
    c.ticks(1)
    local once, wrong = true, 0
    local seen = {}
    for _, path in ipairs(ue.lookups) do
        if seen[path] then once = false end
        seen[path] = true
    end
    for _, d in ipairs(Game.definitions) do
        if not seen[PATH .. d.name] then wrong = wrong + 1 end
    end
    check(#ue.lookups == 22 and once and wrong == 0 and c.S.queue == nil, "six looks: the 22 definitions, each path searched once; no config, effect or skill is searched")
    -- the numbers, by the game's own way of choosing the damage for a caster's circle
    check(w.damage("FireBoltProjectileDefinition", 0) == 52.5 and w.damage("FireBoltProjectileDefinition", 1) == 52.5 and w.damage("FireBoltProjectileDefinition", 2) == 60
        and w.damage("FireBoltProjectileDefinition", 3) == 60 and w.damage("FireBoltProjectileDefinition", 4) == 75 and w.damage("FireBoltProjectileDefinition", 5) == 75
        and w.damage("FireBoltProjectileDefinition", 6) == 97.5, "fire bolt 35 / 40 / 50 / 65 x 1.5 = 52.5 / 60 / 75 / 97.5 for a caster of circle 0-1 / 2-3 / 4-5 / 6")
    check(w.damage("FireBallProjectileDefinition_Lvl1", 3) == 135 and w.damage("FireBallProjectileDefinition_Lvl2", 4) == 195 and w.damage("FireBallProjectileDefinition_Lvl3", 6) == 300,
        "fire ball: every charge level (90 -> 135, level 2 in the 4th circle 130 -> 195, level 3 in the 6th 200 -> 300)")
    check(w.damage("WindFistDefinition", 5) == 75 and w.damage("WindFistDefinition", 6) == 105, "fist of wind: all four steps (5th circle 50 -> 75, 6th 70 -> 105)")
    check(w.damage("LightningRayDefinition_Base", 6) == 67.5 and w.damage("LightningRayDefinition_WithParalysis", 6) == 67.5 and w.damage("LightningRayDefinition_WithoutParalysis", 0) == 30,
        "chain lightning: the definition the rune shows and the two a hit uses")
    check(w.damage("FireRainDefinition", 6) == 75 and w.damage("DeathToTheUndeadDefinition", 0) == 750 and w.damage("UrizielWaveOfDeathVisualDefinition", 3) == 135
        and w.damage("BreathOfDeathDefinition", 6) == 225, "spells without steps: rain of fire 75, death to the undead 750, Uriziel 135, breath of death 225")
    local good = true
    for _, d in ipairs(Game.definitions) do
        for circle = 0, 6 do
            local was = d.base
            for _, s in ipairs(d.steps) do if s[1] <= circle then was = s[2] end end
            if w.damage(d.name, circle) ~= was * 1.5 then good = false end
        end
        if w.speed(d.name) ~= d.speed or w.stagger(d.name) ~= d.stagger then good = false end
    end
    check(good, "all 22 definitions, every circle from 0 to 6: the game's damage x 1.5; flight speed and stagger are as they were")
    local untouched = true
    for _, cc in ipairs(Game.configs) do
        if w.mana(cc.name) ~= cc.levels[1][1] or w.range(cc.name) ~= cc.range then untouched = false end
    end
    check(untouched and w.price(1) == 10 and not w.freezes("GE_IceBlock_Freeze_Damage", 49), "mana, reach, prices and the ice counter are untouched")
    check(w.keys == 0 and w.indexed == 0, "no key of a map is read and no array is indexed (the lists are walked)")
    check(c.S.count == 65 and c.S.holders == 22 and has(status(c), "changed right now: 65 value(s) in 22 object(s) of the game (damage 65)"),
        "65 numbers in 22 objects hold the module's value (22 base values and 43 steps); the status says so")
    check(printedCount(ue, "65 value(s) changed, 0 put back: 65 value(s) in 22 object(s) of the game hold the module's numbers now") == 1 and #ue.printed == 2,
        "the first look that changed something is one line in the log")
    -- afterwards nothing is read until there is a reason
    local reads, writes, walks = w.reads, w.writes, w.walks
    c.ticks(200)
    check(w.reads == reads and w.writes == writes and w.walks == walks and #ue.lookups == 22, "50 seconds on: nothing is read, written or searched")
    c.ticks(40)
    check(w.reads > reads and w.writes == writes and #ue.lookups == 22 and c.fake.value("magic.between_loads") == "kept" and c.fake.detail("magic.between_loads") == "0 of 65 value(s)",
        "after a minute (CheckSeconds) the changed places are read again: all still hold the module's numbers, nothing is written")
    check(c.fake.value("magic.objects") == "all found" and c.fake.value("magic.properties") == "all there" and c.fake.value("magic.others") == "none"
        and c.fake.value("magic.applied") == "65 value(s) in 22 object(s)" and c.fake.value("magic.write.map") == "ok" and c.fake.value("magic.write.steps") == "ok",
        "diagnostics: everything found and there, nothing changed by others, the two ways of writing damage work")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("3. mana cost and casting time of every spell")
do
    local c = start("mana", { config = cfg({ "Config.ManaCost = 1.5" }), diag = true })
    local ue, w = c.ue, c.world
    check(c.settle() == 13 and #ue.lookups == 52, "mana x1.5: the 52 spell configs are searched, four a look (13 looks); no definition")
    check(w.mana("ProjectileSpellConfig_FireBolt") == 2 and w.held("ProjectileSpellConfig_FireBolt") == 2, "fire bolt: 1 a shot -> 2 (1.5 rounded to a whole point), each further shot too")
    check(w.mana("ProjectileSpellConfig_FireBall", 1) == 2 and w.mana("ProjectileSpellConfig_FireBall", 2) == 3 and w.mana("ProjectileSpellConfig_FireBall", 3) == 3
        and w.held("ProjectileSpellConfig_FireBall", 3) == 3 and w.held("ProjectileSpellConfig_FireBall", 1) == 0,
        "fire ball: 1 / 2 / 2 by charge -> 2 / 3 / 3, steering the largest ball 2 a second -> 3; a cost of 0 stays 0")
    check(w.mana("PyrokinesisSpellConfig") == 8 and w.mana("IceBlockSpellConfig") == 5 and w.mana("IceWaveSpellConfig") == 23 and w.mana("StormOfFireSpellConfig") == 45
        and w.mana("DeathToTheUndeadSpellConfig") == 38 and w.mana("UrizielWaveOfDeathSpellConfig") == 60, "5 -> 8 (7.5), 3 -> 5 (4.5), 15 -> 23 (22.5), 30 -> 45, 25 -> 38 (37.5), 40 -> 60: halves are rounded up")
    check(w.mana("HealSpellConfig") == 3 and w.held("ControlSpellConfig") == 6 and w.mana("TeleportSpellConfig_SwampCamp") == 8 and w.mana("SummonSpellConfig_ArmyOfDarkness") == 38
        and w.mana("TransformHarpySpellConfig") == 90 and w.mana("TelekinesisSpellConfig", 2) == 5, "spells without damage too: heal, control, teleport, summoning, transformation, both levels of telekinesis")
    check(c.S.count == 67 and c.S.holders == 52 and has(status(c), "(mana 67)") and w.time("ProjectileSpellConfig_FireBall", 2) == f32(0.6) and w.range("IceBlockSpellConfig") == 720,
        "67 numbers changed (58 costs to cast, 9 costs per second); casting time and reach are as they were")
    check(c.fake.value("magic.write.levels") == "ok" and c.fake.value("magic.applied") == "67 value(s) in 52 object(s)", "diagnostics: writing a level's numbers works")
    stop(c)

    c = start("mana-low", { config = cfg({ "Config.ManaCost = 0.4" }) })
    w = c.world
    c.settle()
    check(w.mana("ProjectileSpellConfig_FireBolt") == 1 and w.mana("ProjectileSpellConfig_FireBall", 2) == 1 and w.mana("IceBlockSpellConfig") == 1 and w.mana("PyrokinesisSpellConfig") == 2
        and w.mana("StormOfFireSpellConfig") == 12 and w.held("ProjectileSpellConfig_FireBall", 1) == 0,
        "mana x0.4: 30 -> 12, 5 -> 2, 3 -> 1, 2 -> 1; a cost of 1 stays 1 - rounding never makes a spell free")
    stop(c)
    c = start("mana-free", { config = cfg({ "Config.ManaCost = 0" }) })
    w = c.world
    c.settle()
    check(w.mana("ProjectileSpellConfig_FireBolt") == 0 and w.held("ProjectileSpellConfig_FireBolt") == 0 and w.mana("UrizielWaveOfDeathSpellConfig") == 0, "mana x0: spells are free")
    stop(c)
    c = start("mana-raw", { config = cfg({ "Config.ManaCost = 1.25", "Config.WholeMana = false" }) })
    w = c.world
    c.settle()
    check(w.mana("ProjectileSpellConfig_FireBall", 1) == 1.25 and w.mana("ProjectileSpellConfig_FireBall", 2) == 2.5 and w.held("ProjectileSpellConfig_FireBall", 3) == 2.5
        and w.mana("ProjectileSpellConfig_BallLightning", 1) == 6.25, "WholeMana = false: the exact product is written (1.25, 2.5, 6.25)")
    stop(c)
    c = start("mana-raw-whole", { config = cfg({ "Config.IceWaveMana = 1.333", "Config.StormOfFireMana = 1.001", "Config.FireRainMana = 1.001", "Config.WholeMana = false" }) })
    w = c.world
    c.settle()
    check(w.mana("IceWaveSpellConfig") == 20 and w.mana("StormOfFireSpellConfig") == f32(30.03) and w.mana("FireRainSpellConfig") == 20 and c.S.count == 2,
        "but a product that misses a whole number by 0.025 or less is that number: 15 x 1.333 = 19.995 -> 20, 20 x 1.001 = 20.02 -> 20 (the game's own: not written); 30 x 1.001 = 30.03 stays")
    stop(c)
    -- (found in review) halves that the multiplication leaves a hair short of the half are rounded up all the same
    c = start("mana-halves", { config = cfg({ "Config.IceWaveMana = 4.1", "Config.DeathToTheUndeadMana = 0.58" }) })
    w = c.world
    c.settle()
    check(15 * 4.1 < 61.5 and 25 * 0.58 < 14.5 and w.mana("IceWaveSpellConfig") == 62 and w.mana("DeathToTheUndeadSpellConfig") == 15,
        "15 x 4.1 (61.499999999999993 as the machine multiplies) -> 62, 25 x 0.58 (14.499999999999998) -> 15")
    stop(c)
    -- and without whole points a small product is not taken for the whole number 0: only a multiplier of 0 makes a spell free
    c = start("mana-raw-small", { config = cfg({ "Config.FireBoltMana = 0.02", "Config.WholeMana = false" }) })
    w = c.world
    c.settle()
    check(w.mana("ProjectileSpellConfig_FireBolt") == f32(0.02) and w.held("ProjectileSpellConfig_FireBolt") == f32(0.02), "WholeMana = false, 1 x 0.02: the cost is 0.02, not 0")
    stop(c)
    c = start("mana-raw-free", { config = cfg({ "Config.FireBoltMana = 0", "Config.WholeMana = false" }) })
    w = c.world
    c.settle()
    check(w.mana("ProjectileSpellConfig_FireBolt") == 0 and w.held("ProjectileSpellConfig_FireBolt") == 0, "a multiplier of 0 still makes it free")
    stop(c)
    c = start("mana-one", { config = cfg({ "Config.FireBoltMana = 2.0" }) })
    w = c.world
    check(c.settle() == 1 and #c.ue.lookups == 1 and c.ue.lookups[1] == PATH .. "ProjectileSpellConfig_FireBolt", "a single spell's mana: only its config is searched")
    check(w.mana("ProjectileSpellConfig_FireBolt") == 2 and w.held("ProjectileSpellConfig_FireBolt") == 2 and w.mana("ProjectileSpellConfig_IceBolt") == 1 and c.S.count == 2,
        "fire bolt mana x2: 2 a shot; the ice bolt is as it was")
    stop(c)
    c = start("mana-both", { config = cfg({ "Config.ManaCost = 2.0", "Config.StormFistMana = 1.5", "Config.BreathOfDeathMana = 0.5" }) })
    w = c.world
    c.settle()
    check(w.mana("StormFistSpellConfig") == 30 and w.mana("BreathOfDeathSpellConfig") == 15 and w.mana("FistOfWindSpellConfig") == 4,
        "both multipliers: storm fist 10 x 2 x 1.5 = 30; breath of death 15 x 2 x 0.5 = 15 (not written: it is the game's number); fist of wind 2 x 2 = 4")
    check(c.rec("BreathOfDeathSpellConfig").slots.mana1.ours == nil, "a product that is the game's own number is not counted as changed")
    stop(c)

    c = start("time", { config = cfg({ "Config.CastTime = 0.5" }) })
    ue, w = c.ue, c.world
    c.settle()
    check(#ue.lookups == 52 and near(w.time("ProjectileSpellConfig_FireBolt"), 0.05) and near(w.time("ProjectileSpellConfig_FireBall", 1), 0.2)
        and near(w.time("ProjectileSpellConfig_FireBall", 3), 0.4) and near(w.time("ProjectileSpellConfig_BallLightning", 2), 0.515) and w.time("TeleportSpellConfig_Necromancer") == 2,
        "casting time x0.5: bolt 0.1 -> 0.05, fire ball 0.4 / 0.8 -> 0.2 / 0.4, ball lightning 1.03 -> 0.515, a teleport 4 -> 2 seconds")
    check(w.time("FistOfWindSpellConfig") == 0 and w.time("TransformWolfSpellConfig") == 0 and c.S.count == 40 and has(status(c), "(casting time 40)") and w.mana("ProjectileSpellConfig_FireBall", 2) == 2,
        "a time of 0 stays 0 (fist of wind, the transformations): 40 times changed; mana is as it was")
    stop(c)
    c = start("time-one", { config = cfg({ "Config.CastTime = 0.5", "Config.FireBallCastTime = 0.7", "Config.DeathToTheUndeadCastTime = 4.0" }) })
    w = c.world
    c.settle()
    check(near(w.time("ProjectileSpellConfig_FireBall", 1), 0.14) and near(w.time("ProjectileSpellConfig_FireBall", 2), 0.21) and near(w.time("ProjectileSpellConfig_FireBall", 3), 0.28)
        and w.time("DeathToTheUndeadSpellConfig") == 1 and near(w.time("StormFistSpellConfig"), 0.25),
        "both multipliers: fire ball x0.5 x0.7 = 0.14 / 0.21 / 0.28; death to the undead 0.5 x0.5 x4 = 1; others x0.5")
    stop(c)
    c = start("time-single", { config = cfg({ "Config.FireBallCastTime = 0.7" }) })
    w = c.world
    check(c.settle() == 1 and #c.ue.lookups == 1 and near(w.time("ProjectileSpellConfig_FireBall", 1), 0.28) and near(w.time("ProjectileSpellConfig_FireBall", 2), 0.42)
        and near(w.time("ProjectileSpellConfig_FireBall", 3), 0.56) and c.S.count == 3, "a single spell's time: fire ball x0.7 = 0.28 / 0.42 / 0.56, one search")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("4. flight speed, reach, stagger, healing")
do
    local c = start("speed", { config = cfg({ "Config.ProjectileSpeed = 2.0" }), diag = true })
    local ue, w = c.ue, c.world
    c.settle()
    check(#ue.lookups == 10, "flight speed: only the ten definitions of things that fly are searched (" .. #ue.lookups .. ")")
    check(w.speed("FireBoltProjectileDefinition") == 8000 and w.speed("IceBoltProjectileDefinition") == 8000 and w.speed("FireBallProjectileDefinition_Lvl2") == 6000
        and w.speed("BallLightningDefinition_Lvl1") == 600 and w.speed("BallLightningDefinition_Lvl4") == 900 and w.speed("StormOfFireDefinition") == 600,
        "x2: bolts 4000 -> 8000, fire ball 3000 -> 6000, ball lightning 300 - 450 -> 600 - 900, storm of fire 300 -> 600")
    check(c.S.count == 10 and has(status(c), "(flight speed 10)") and w.damage("FireBoltProjectileDefinition", 0) == 35 and c.fake.value("magic.write.plain") == "ok",
        "ten numbers changed, damage untouched; the diagnostics note that a plain number can be written")
    stop(c)
    c = start("speed-all", { config = cfg({ "Config.ProjectileSpeed = 2.0", "Config.Damage = 2.0" }) })
    w = c.world
    c.settle()
    check(w.speed("FireRainDefinition") == 1500 and w.speed("WindFistDefinition") == 1500 and w.speed("FireBoltProjectileDefinition") == 8000 and w.damage("FireRainDefinition", 0) == 100,
        "a definition that is looked at for another reason and does not fly keeps its speed")
    stop(c)

    c = start("range", { config = cfg({ "Config.Range = 2.0" }) })
    ue, w = c.ue, c.world
    c.settle()
    check(#ue.lookups == 11 and w.range("SleepSpellConfig") == 3000 and w.range("ControlSpellConfig") == 4000 and w.range("PyrokinesisSpellConfig") == 3000 and w.range("HealSpellConfig") == 3000
        and w.range("StormFistSpellConfig") == 1400 and w.range("DeathToTheUndeadSpellConfig") == 1000 and w.range("UrizielWaveOfDeathSpellConfig") == 1500,
        "reach x2: the eleven configs whose reach the game's scripts use - target spells (sleep, pyrokinesis, heal 1500 -> 3000, control 2000 -> 4000), storm fist 700 -> 1400, "
        .. "death to the undead 500 -> 1000, Uriziel's wave 750 -> 1500")
    check(c.S.count == 11 and has(status(c), "(reach 11)") and w.range("IceBlockSpellConfig") == 720 and w.range("FistOfWindSpellConfig") == 700 and w.range("TeleportSpellConfig_SwampCamp") == 300
        and w.read["IceBlockSpellConfig.m_AreaRange"] == nil, "eleven numbers changed; the reach of the other spells (ice block, fist of wind, the teleports) is not read and not touched")
    stop(c)
    c = start("range-mana", { config = cfg({ "Config.Range = 2.0", "Config.ManaCost = 2.0" }) })
    c.settle()
    check(c.world.range("IceBlockSpellConfig") == 720 and c.world.mana("IceBlockSpellConfig") == 6 and c.world.range("SleepSpellConfig") == 3000 and c.world.read["IceBlockSpellConfig.m_AreaRange"] == nil,
        "also when such a config is looked at for its mana")
    stop(c)

    c = start("stagger", { config = cfg({ "Config.Stagger = 2.0" }) })
    ue, w = c.ue, c.world
    c.settle()
    check(#ue.lookups == 22 and w.stagger("FireBoltProjectileDefinition") == 60 and w.stagger("FireBallProjectileDefinition_Lvl3") == 200 and w.stagger("WindFistDefinition") == 400
        and w.stagger("StormFistDefinition") == 500 and w.stagger("StormOfFireDefinition") == 20 and w.stagger("FireRainDefinition") == 0 and c.S.count == 7 and has(status(c), "(stagger 7)"),
        "stagger x2: fire bolt 30 -> 60, largest fire ball 100 -> 200, fist of wind 200 -> 400, storm fist 250 -> 500; seven numbers")
    stop(c)

    c = start("heal", { config = cfg({ "Config.HealAmount = 2.0" }) })
    ue, w = c.ue, c.world
    check(c.settle() == 1 and #ue.lookups == 1 and ue.lookups[1] == PATH .. "HealSpellConfig", "healing: only the heal spell's config is searched")
    check(w.heal(1) == 8 and w.heal(4) == 12 and w.heal(5) == 20 and w.heal(8) == 60 and c.S.count == 8 and has(status(c), "(healing 8)") and w.mana("HealSpellConfig") == 2 and w.keys == 0,
        "x2: 4 -> 8 for the untrained, 6 -> 12, 10 -> 20, 30 -> 60 in the 6th circle; eight numbers, its mana untouched")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("5. kinds of damage and single spells")
do
    local c = start("school", { config = cfg({ "Config.SchoolFire = 2.0" }) })
    local ue, w = c.ue, c.world
    c.settle()
    check(#ue.lookups == 7 and w.damage("FireBoltProjectileDefinition", 0) == 70 and w.damage("PyrokinesisProjectileDefinition", 5) == 70 and w.damage("StormOfFireDefinition", 6) == 600
        and w.damage("FireRainDefinition", 0) == 100 and w.damage("IceBoltProjectileDefinition", 0) == 20, "fire x2: the seven fire definitions, nothing else")
    stop(c)
    for _, case in ipairs({
        { "SchoolIce", 3, "IceWaveProjectileDefinition", 240, "FireBoltProjectileDefinition", 35 },
        { "SchoolEnergy", 9, "DeathToTheUndeadDefinition", 1000, "StormFistDefinition", 120 },
        { "SchoolWind", 3, "StormFistDefinition", 240, "UrizielWaveOfDeathVisualDefinition", 90 },
    }) do
        c = start("school-" .. case[1], { config = cfg({ "Config." .. case[1] .. " = 2.0" }) })
        c.settle()
        check(#c.ue.lookups == case[2] and c.world.damage(case[3], 0) == case[4] and c.world.damage(case[5], 0) == case[6],
            ("%s x2: %d definitions, %s %d, %s untouched"):format(case[1], case[2], case[3], case[4], case[5]))
        stop(c)
    end
    c = start("single", { config = cfg({ "Config.FireBallDamage = 1.25" }) })
    ue, w = c.ue, c.world
    check(c.settle() == 1 and #ue.lookups == 3, "a single spell: fire ball damage x1.25 searches its three definitions")
    check(w.damage("FireBallProjectileDefinition_Lvl1", 0) == 112.5 and w.damage("FireBallProjectileDefinition_Lvl1", 4) == 137.5 and w.damage("FireBallProjectileDefinition_Lvl1", 5) == 162.5
        and w.damage("FireBallProjectileDefinition_Lvl1", 6) == 187.5 and w.damage("FireBallProjectileDefinition_Lvl2", 0) == 137.5 and w.damage("FireBallProjectileDefinition_Lvl3", 6) == 250,
        "90 / 110 / 130 / 150 -> 112.5 / 137.5 / 162.5 / 187.5; level 2 from 137.5; level 3 up to 250")
    stop(c)
    -- a multiplier has three decimals: a product that just misses a whole number is that number
    c = start("whole", { config = cfg({ "Config.UrizielDamage = 2.778", "Config.DeathToTheUndeadDamage = 1.998", "Config.StormFistDamage = 0.333", "Config.WindFistDamage = 1.001" }) })
    w = c.world
    c.settle()
    check(w.damage("UrizielWaveOfDeathVisualDefinition", 0) == 250 and w.damage("DeathToTheUndeadDefinition", 0) == 999,
        "90 x 2.778 = 250.02 is taken as 250, 500 x 1.998 as 999: a product that misses a whole number by 0.025 or less is that number")
    check(near(w.damage("StormFistDefinition", 0), 39.96) and near(w.damage("StormFistDefinition", 6), 53.28) and near(w.damage("WindFistDefinition", 2), 30.03)
        and w.damage("WindFistDefinition", 0) == 20 and c.rec("WindFistDefinition").slots.base1.ours == nil,
        "120 x 0.333 = 39.96 and 30 x 1.001 = 30.03 stay as they are (further off); 20 x 1.001 = 20.02 is 20, the game's own number: not written")
    stop(c)
    c = start("fraction", { config = cfg({ "Config.Stagger = 2.0", "Config.CastTime = 2.0" }), prepare = function(_, world)
        world.data.definitions.FireRainDefinition.base[1].value = 49.99                             -- another build of the game with numbers that are nearly whole
        world.data.configs.FireRainSpellConfig.levels[1].CastManaCost = f32(19.99)
    end })
    w = c.world
    c.settle()
    check(w.damage("FireRainDefinition", 0) == 49.99 and w.mana("FireRainSpellConfig") == f32(19.99) and near(w.time("FireRainSpellConfig"), 0.2) and w.stagger("FireBoltProjectileDefinition") == 60,
        "a number whose multipliers are all 1.0 is not touched, whatever it is (49.99 damage, 19.99 mana stay; stagger and casting time, which are set, change)")
    stop(c)
    c = start("combined", { config = cfg({ "Config.Damage = 1.5", "Config.SchoolFire = 2.0", "Config.FireBallDamage = 1.2", "Config.SchoolWind = 0.5", "Config.WindFistDamage = 3.0" }) })
    w = c.world
    c.settle()
    check(near(w.damage("FireBallProjectileDefinition_Lvl1", 0), 324) and w.damage("FireBoltProjectileDefinition", 0) == 105 and w.damage("IceBoltProjectileDefinition", 0) == 30
        and w.damage("WindFistDefinition", 0) == 45 and w.damage("StormFistDefinition", 0) == 90,
        "all spells x kind x spell: fire ball 90 x 1.5 x 2 x 1.2 = 324, fire bolt 105, ice bolt 30, fist of wind 20 x 1.5 x 0.5 x 3 = 45, storm fist 90")
    check(has(c.ue.printed[1], "loaded: damage x1.5, fire x2, wind x0.5, 2 setting(s) for single spells"), "the load line lists what is set: " .. c.ue.printed[1]:gsub("\n", ""))
    stop(c)
    -- every single-spell setting reaches its spell and no other
    local keys = { "FireBolt", "FireBall", "Pyrokinesis", "StormOfFire", "FireRain", "IceBolt", "IceBlock", "IceWave", "BallLightning", "ChainLightning", "Uriziel",
        "DeathToTheUndead", "WindFist", "StormFist", "BreathOfDeath" }
    local lines = { "Config.WholeMana = false" }
    for i, key in ipairs(keys) do
        lines[#lines + 1] = ("Config.%sDamage = %s"):format(key, 1 + i / 10)
        lines[#lines + 1] = ("Config.%sMana = %s"):format(key, 1 + i / 5)
        if key ~= "WindFist" then lines[#lines + 1] = ("Config.%sCastTime = %s"):format(key, 1 + i / 4) end
    end
    c = start("every", { config = cfg(lines) })
    w = c.world
    c.settle()
    local good, bad = true, ""
    for i, spell in ipairs(c.hook.objects) do
        if spell.spell then
            local index
            for n, key in ipairs(keys) do if key == spell.spell.key then index = n end end
            if spell.kind == "definition" then
                local d
                for _, g in ipairs(Game.definitions) do if g.name == spell.name then d = g end end
                if not near(w.damage(spell.name, 0), d.base * (1 + index / 10)) then good, bad = false, spell.name end
            elseif spell.kind == "config" then
                local g
                for _, x in ipairs(Game.configs) do if x.name == spell.name then g = x end end
                if not near(w.mana(spell.name), g.levels[1][1] * (1 + index / 5)) then good, bad = false, spell.name .. " mana" end
                local time = spell.spell.key == "WindFist" and 0 or g.levels[1][2] * (1 + index / 4)
                if not near(w.time(spell.name), time) then good, bad = false, spell.name .. " time" end
            end
        end
    end
    check(good and #c.ue.lookups == 37, "fifteen spells, each with its own damage, mana and casting time: every one reaches its own objects (" .. bad .. "; 22 definitions and 15 configs searched)")
    check(w.mana("HealSpellConfig") == 2 and has(c.ue.printed[1], "loaded: 44 setting(s) for single spells"), "the spells without settings of their own are untouched; the load line counts 44 settings")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("6. own numbers: the bolts by the caster's circle, ball lightning speed, fist of wind stagger")
do
    local c = start("steps", { config = cfg({ "Config.FireBoltSteps = true", "Config.FireBoltStep0 = 30" }), diag = true })
    local ue, w = c.ue, c.world
    check(c.settle() == 1 and #ue.lookups == 1, "own fire bolt numbers: one definition is searched")
    check(w.damage("FireBoltProjectileDefinition", 1) == 30 and w.damage("FireBoltProjectileDefinition", 2) == 40 and w.damage("FireBoltProjectileDefinition", 4) == 50
        and w.damage("FireBoltProjectileDefinition", 6) == 65 and c.S.count == 1, "30 below the 2nd circle, the other three as the game has them: one number changed")
    check(c.fake.value("magic.steps") == "as expected" and has(ue.printed[1], "loaded: 1 setting(s) for single spells"), "the shape of the bolt's data is as expected (noted)")
    check(printedCount(ue, "[G1R_Magic] 1 value(s) changed, 0 put back: 1 value(s) in 1 object(s) of the game hold the module's numbers now\n") == 1, "a single changed value is a line in the log too")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(8)
    check(c.fake.value("magic.after_load") == "kept" and c.fake.detail("magic.after_load") == "0 of 1 value(s)", "and is looked at after a map change (noted: kept, 0 of 1)")
    c.ticks(240)
    check(c.fake.value("magic.between_loads") == "kept" and c.fake.detail("magic.between_loads") == "0 of 1 value(s)", "and once a minute")
    stop(c)
    c = start("steps-ice", { config = cfg({ "Config.IceBoltSteps = true", "Config.IceBoltStep0 = 25", "Config.IceBoltStep2 = 40", "Config.IceBoltStep4 = 45", "Config.IceBoltStep6 = 55",
        "Config.Damage = 2.0", "Config.IceBoltDamage = 0.5", "Config.SchoolIce = 3.0" }) })
    w = c.world
    c.settle()
    check(w.damage("IceBoltProjectileDefinition", 0) == 75 and w.damage("IceBoltProjectileDefinition", 2) == 120 and w.damage("IceBoltProjectileDefinition", 5) == 135
        and w.damage("IceBoltProjectileDefinition", 6) == 165 and w.damage("IceBlockProjectileDefinition", 0) == 360 and w.damage("FireBoltProjectileDefinition", 0) == 70,
        "own ice bolt numbers 25 / 40 / 45 / 55 with the multipliers on top (x2 x3 x0.5 = x3): 75 / 120 / 135 / 165; fire bolt only x2")
    stop(c)
    c = start("steps-off", { config = cfg({ "Config.FireBoltStep0 = 30", "Config.IceBoltStep6 = 99" }) })
    c.ticks(8)
    check(#c.ue.lookups == 0 and c.world.untouched(), "the numbers without their switch do nothing: nothing is searched")
    stop(c)
    -- another build of the game with other steps for the bolt: the four numbers have no place to go
    c = start("steps-shape", { config = cfg({ "Config.FireBoltSteps = true", "Config.FireBoltStep0 = 30", "Config.FireBoltStep2 = 44", "Config.FireBoltDamage = 2.0" }), diag = true,
        prepare = function(_, world) table.remove(world.data.definitions.FireBoltProjectileDefinition.steps, 3) end })
    w = c.world
    c.settle()
    check(w.damage("FireBoltProjectileDefinition", 0) == 70 and w.damage("FireBoltProjectileDefinition", 2) == 80 and w.damage("FireBoltProjectileDefinition", 6) == 100
        and c.fake.value("magic.steps") == "other shape" and c.fake.detail("magic.steps") == "FireBoltProjectileDefinition 1/2",
        "a bolt with two steps instead of three: the own numbers are not used (noted), the multiplier still is")
    stop(c)

    c = start("ball", { config = cfg({ "Config.BallLightningSpeed = 800" }) })
    ue, w = c.ue, c.world
    check(c.settle() == 1 and #ue.lookups == 4 and w.speed("BallLightningDefinition_Lvl1") == 800 and w.speed("BallLightningDefinition_Lvl2") == 800
        and w.speed("BallLightningDefinition_Lvl3") == 800 and w.speed("BallLightningDefinition_Lvl4") == 800 and w.speed("FireBoltProjectileDefinition") == 4000 and c.S.count == 4,
        "ball lightning speed 800: every charge level flies at 800 (the game: 300 / 350 / 400 / 450); four searches, four numbers")
    stop(c)
    c = start("ball-one", { config = cfg({ "Config.BallLightningSpeed = 1" }) })
    check(c.settle() == 1 and #c.ue.lookups == 4 and c.world.speed("BallLightningDefinition_Lvl1") == 1 and c.world.speed("BallLightningDefinition_Lvl4") == 1
        and has(c.ue.printed[1], "loaded: 1 setting(s) for single spells"), "any speed above 0 is a speed of your own (1 unit a second, for the sake of the rule)")
    stop(c)
    c = start("ball-times", { config = cfg({ "Config.BallLightningSpeed = 800", "Config.ProjectileSpeed = 1.5" }) })
    w = c.world
    c.settle()
    check(w.speed("BallLightningDefinition_Lvl3") == 1200 and w.speed("FireBoltProjectileDefinition") == 6000, "with the multiplier for all flight speeds on top: 800 x 1.5 = 1200")
    stop(c)

    c = start("fist", { config = cfg({ "Config.WindFistStagger = 5.0" }) })
    ue, w = c.ue, c.world
    check(c.settle() == 1 and #ue.lookups == 1 and w.stagger("WindFistDefinition") == 1000 and w.stagger("StormFistDefinition") == 250 and w.damage("WindFistDefinition", 0) == 20 and c.S.count == 1,
        "fist of wind stagger x5: 200 -> 1000, nothing else")
    stop(c)
    c = start("fist-times", { config = cfg({ "Config.WindFistStagger = 5.0", "Config.Stagger = 2.0" }) })
    c.settle()
    check(c.world.stagger("WindFistDefinition") == 2000 and c.world.stagger("StormFistDefinition") == 500, "with the multiplier for all spells on top: 200 x 5 x 2 = 2000")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("7. the price of the magic circles, freezing with every hit")
do
    local c = start("prices-same", { config = cfg({ "Config.CircleCosts = true" }), diag = true })
    local ue, w = c.ue, c.world
    check(c.settle() == 2 and #ue.lookups == 7 and w.writes == 0 and c.S.count == 0 and w.untouched(),
        "own prices switched on with the game's numbers: the seven skill effects are read, nothing is written")
    check(has(status(c), "| own prices for the magic circles|nothing is changed right now") and printedCount(ue, "value(s) changed, ") == 0 and #ue.printed == 1,
        "the status says that nothing is changed; a look that changed nothing is no line in the log")
    local reads = w.reads
    c.ticks(300)
    check(w.reads == reads, "while nothing is changed there is nothing to look after: no look once a minute")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(8)
    check(w.reads > reads and w.writes == 0 and c.fake.value("magic.after_load") == nil, "a map change brings a look (the setting is on), but there is nothing to note about numbers that outlived it")
    stop(c)
    c = start("prices", { config = cfg({ "Config.CircleCosts = true", "Config.CircleCost2 = 12", "Config.CircleCost3 = 15", "Config.CircleCost4 = 18", "Config.CircleCost5 = 20",
        "Config.CircleCost6 = 25", "Config.CircleCostBasics = 0" }) })
    w = c.world
    c.settle()
    check(w.price(0) == 0 and w.price(1) == 10 and w.price(2) == 12 and w.price(3) == 15 and w.price(4) == 18 and w.price(5) == 20 and w.price(6) == 25 and c.S.count == 6,
        "prices 0 / 10 / 12 / 15 / 18 / 20 / 25: what the teacher takes; the first circle's 10 is the game's own and not written")
    check(has(status(c), "(circle price 6)"), "the status counts six prices")
    stop(c)

    c = start("freeze", { config = cfg({ "Config.IceBlockFreeze = true" }), diag = true })
    ue, w = c.ue, c.world
    check(not w.freezes("GE_IceBlock_Freeze_Damage", 49) and w.freezes("GE_IceBlock_Freeze_Damage", 50), "(the game: an ice hit freezes when its damage reaches the counter's 50)")
    check(c.settle() == 1 and #ue.lookups == 1 and ue.lookups[1] == PATH .. "GE_IceBlock_Freeze_Damage", "ice block freezes with every hit: its hit effect is searched")
    check(w.freezes("GE_IceBlock_Freeze_Damage", 49) and w.freezes("GE_IceBlock_Freeze_Damage", 1) and not w.freezes("GE_IceBolt_Damage", 49) and not w.freezes("GE_IceWave_Freeze_Damage", 49),
        "now a weak hit of the ice block freezes too; ice bolt and ice wave are as they were")
    check(w.data.effects.GE_IceBlock_Freeze_Damage.common[1].ForceOverflowElementalEffectStack == false and w.read["GE_IceBlock_Freeze_Damage.m_CommonElementalEffectStacks"] == nil,
        "the counter of hits on a frozen foe (the other list of the effect) is not read and not touched")
    check(c.S.count == 1 and has(status(c), "1 ice spell(s) freeze with every hit|changed right now: 1 value(s) in 1 object(s) of the game (freeze 1)") and c.fake.value("magic.write.flags") == "ok",
        "one switch set; the status and the diagnostics say so")
    stop(c)
    c = start("freeze-all", { config = cfg({ "Config.IceBlockFreeze = true", "Config.IceBoltFreeze = true", "Config.IceWaveFreeze = true" }) })
    c.settle()
    check(#c.ue.lookups == 3 and c.world.freezes("GE_IceBolt_Damage", 5) and c.world.freezes("GE_IceWave_Freeze_Damage", 5) and c.S.count == 3, "all three ice spells")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("8. the settings that stand for the player's file of the mod G1R_MageBalance")
-- What that mod printed when it applied his file (UE4SS.log of 2026-10-01, lines 1136-1177) is the reference.
local PLAYER = cfg({
    "Config.WholeMana = false",
    "Config.FireBoltSteps = true", "Config.FireBoltStep0 = 30", "Config.FireBoltMana = 2.0",
    "Config.FireBallDamage = 1.25", "Config.FireBallCastTime = 0.7", "Config.FireBallMana = 1.25",
    "Config.BallLightningSpeed = 800", "Config.BallLightningCastTime = 0.7", "Config.BallLightningMana = 1.25",
    "Config.FireRainDamage = 2.5", "Config.FireRainMana = 1.5",
    "Config.IceBoltSteps = true", "Config.IceBoltStep0 = 25", "Config.IceBoltStep2 = 40", "Config.IceBoltStep4 = 45", "Config.IceBoltStep6 = 55",
    "Config.BreathOfDeathDamage = 2.0", "Config.BreathOfDeathCastTime = 0.5",
    "Config.PyrokinesisDamage = 2.5", "Config.StormOfFireDamage = 1.2", "Config.UrizielDamage = 2.778", "Config.ChainLightningDamage = 3.0",
    "Config.WindFistDamage = 2.0", "Config.WindFistStagger = 5.0",
    "Config.DeathToTheUndeadDamage = 1.998", "Config.DeathToTheUndeadMana = 1.2", "Config.DeathToTheUndeadCastTime = 4.0",
    "Config.StormFistMana = 1.5", "Config.IceWaveMana = 1.333", "Config.IceBlockFreeze = true",
    "Config.CircleCosts = true", "Config.CircleCost2 = 12", "Config.CircleCost3 = 15", "Config.CircleCost4 = 18", "Config.CircleCost5 = 20", "Config.CircleCost6 = 25",
})
do
    local c = start("player", { config = PLAYER, diag = true })
    local ue, w = c.ue, c.world
    check(c.settle() == 9 and #ue.lookups == 35, "35 objects are searched in nine looks (19 definitions, 8 configs, 1 hit effect, 7 skill effects)")
    local function all(name, list)          -- the damage for the circles 0, 2, 4, 5, 6
        local got = {}
        for i, circle in ipairs({ 0, 2, 4, 5, 6 }) do got[i] = w.damage(name, circle) end
        for i, v in ipairs(list) do if got[i] ~= v then return false end end
        return true
    end
    check(all("FireBoltProjectileDefinition", { 30, 40, 50, 50, 65 }), "fire bolt 30 / 40 / 50 / 65 (his file: base 30, c2 40, c4 50, c6 65)")
    check(all("IceBoltProjectileDefinition", { 25, 40, 45, 45, 55 }), "ice bolt 25 / 40 / 45 / 55")
    check(all("FireBallProjectileDefinition_Lvl1", { 112.5, 112.5, 137.5, 162.5, 187.5 }) and all("FireBallProjectileDefinition_Lvl2", { 137.5, 137.5, 162.5, 187.5, 212.5 })
        and all("FireBallProjectileDefinition_Lvl3", { 162.5, 162.5, 187.5, 212.5, 250 }), "fire ball x1.25: 112.5 -> 187.5, 137.5 -> 212.5, 162.5 -> 250 (as that mod printed)")
    check(all("StormOfFireDefinition", { 300, 300, 300, 300, 360 }) and all("FireRainDefinition", { 125, 125, 125, 125, 125 }) and all("PyrokinesisProjectileDefinition", { 50, 50, 50, 87.5, 87.5 })
        and all("BreathOfDeathDefinition", { 300, 300, 300, 300, 300 }), "storm of fire 300 / 360, rain of fire 125, pyrokinesis 50 / 87.5, breath of death 300")
    check(all("LightningRayDefinition_Base", { 60, 60, 60, 105, 135 }) and all("LightningRayDefinition_WithParalysis", { 60, 60, 60, 105, 135 })
        and all("LightningRayDefinition_WithoutParalysis", { 60, 60, 60, 105, 135 }), "chain lightning x3: 60 / 105 / 135 on all three definitions")
    check(all("WindFistDefinition", { 40, 60, 80, 100, 140 }) and w.stagger("WindFistDefinition") == 1000, "fist of wind x2: 40 / 60 / 80 / 100 / 140, stagger 1000")
    check(w.damage("DeathToTheUndeadDefinition", 0) == 999 and w.damage("UrizielWaveOfDeathVisualDefinition", 0) == 250,
        "death to the undead 500 x 1.998 = 999; Uriziel 90 x 2.778 = 250 (250.02 is taken as the whole number it is meant to be)")
    check(w.speed("BallLightningDefinition_Lvl1") == 800 and w.speed("BallLightningDefinition_Lvl4") == 800 and all("BallLightningDefinition_Lvl1", { 70, 70, 90, 110, 130 }),
        "ball lightning flies at 800, its damage is the game's")
    check(w.mana("ProjectileSpellConfig_FireBolt") == 2 and w.held("ProjectileSpellConfig_FireBolt") == 2, "fire bolt mana 2, also for every further shot")
    check(w.mana("ProjectileSpellConfig_FireBall", 1) == 1.25 and w.mana("ProjectileSpellConfig_FireBall", 2) == 2.5 and w.mana("ProjectileSpellConfig_FireBall", 3) == 2.5
        and w.held("ProjectileSpellConfig_FireBall", 3) == 2.5 and near(w.time("ProjectileSpellConfig_FireBall", 1), 0.28) and near(w.time("ProjectileSpellConfig_FireBall", 2), 0.42)
        and near(w.time("ProjectileSpellConfig_FireBall", 3), 0.56), "fire ball mana x1.25 = 1.25 / 2.5 / 2.5 (the exact products, as that mod wrote them), charge x0.7 = 0.28 / 0.42 / 0.56")
    check(w.mana("ProjectileSpellConfig_BallLightning", 1) == 6.25 and w.mana("ProjectileSpellConfig_BallLightning", 4) == 2.5 and near(w.time("ProjectileSpellConfig_BallLightning", 1), 0.21)
        and near(w.time("ProjectileSpellConfig_BallLightning", 3), 0.721), "ball lightning mana 6.25 / 1.25 / 1.25 / 2.5, charge 0.21 / 0.721")
    check(w.mana("FireRainSpellConfig") == 30 and w.mana("DeathToTheUndeadSpellConfig") == 30 and w.time("DeathToTheUndeadSpellConfig") == 2 and w.mana("StormFistSpellConfig") == 15
        and w.mana("IceWaveSpellConfig") == 20 and w.time("BreathOfDeathSpellConfig") == 0.25 and w.mana("BreathOfDeathSpellConfig") == 15,
        "rain of fire 30, death to the undead 30 mana and 2 s, storm fist 15, breath of death 0.25 s; ice wave 15 x 1.333 = 20 (19.995 is taken as 20)")
    check(w.freezes("GE_IceBlock_Freeze_Damage", 10) and not w.freezes("GE_IceBolt_Damage", 10), "the ice block freezes with every hit")
    check(w.price(0) == 5 and w.price(1) == 10 and w.price(2) == 12 and w.price(3) == 15 and w.price(4) == 18 and w.price(5) == 20 and w.price(6) == 25, "circle prices 10 / 12 / 15 / 18 / 20 / 25")
    check(w.mana("StormOfFireSpellConfig") == 30 and w.mana("UrizielWaveOfDeathSpellConfig") == 40 and w.read["StormOfFireSpellConfig.m_SpellLevels"] == nil
        and w.read["UrizielWaveOfDeathSpellConfig.m_SpellLevels"] == nil, "what his file sets to the game's own number (mana 30, 40, 15) needs no setting: those configs are not even read")
    check(c.S.count == 73 and c.S.holders == 33 and has(status(c), "changed right now: 73 value(s) in 33 object(s) of the game (damage 39, mana 14, casting time 9, flight speed 4, stagger 1, freeze 1, circle price 5)"),
        "73 numbers in 33 objects: " .. c.hook.status()[2])
    check(has(ue.printed[1], "loaded: 24 setting(s) for single spells, 1 ice spell(s) freeze with every hit, own prices for the magic circles"), "the load line: " .. ue.printed[1]:gsub("\n", ""))
    check(c.fake.value("magic.objects") == "all found" and c.fake.value("magic.applied") == "73 value(s) in 33 object(s)" and c.fake.value("magic.steps") == "as expected", "diagnostics: all found, 73 values")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("9. settings while the game runs: the file, the in-game menu; neutral or off puts the game's numbers back")
do
    local c = start("live", { config = cfg({ "Config.Damage = 1.5" }), widgets = true, diag = true })
    local ue, w = c.ue, c.world
    c.settle()
    check(c.ui.note() == nil and c.ui.created == 0 and allOf(ue) == 0, "what is set at the start is applied without a note on screen (and without looking for the hero)")
    T.write(c.path, cfg({ "Config.Damage = 2.0" }))
    c.ticks(13)
    check(w.damage("FireBoltProjectileDefinition", 0) == 52.5, "the file is not read more often than every 5 seconds")
    c.ticks(1)
    check(printed(ue, "[G1R_Magic] settings changed (config.lua): damage x2\n") ~= nil, "a changed file is picked up within 5 seconds, said in the log")
    check(w.damage("FireBoltProjectileDefinition", 0) == 70 and w.damage("FireBoltProjectileDefinition", 6) == 130 and w.damage("FireBallProjectileDefinition_Lvl3", 6) == 400,
        "the new number comes from the game's own, not from the changed one: fire bolt 35 x 2 = 70 (not 52.5 x 2)")
    check(c.searches() == 22 and c.S.count == 65, "nothing is searched again; the same 65 places hold the new numbers")
    check(c.ui.note() == "Magic: 65 value(s) changed", "a note on screen says that the change has reached the game: " .. tostring(c.ui.note()))
    check(printedCount(ue, "value(s) changed, ") == 1, "only the first look that changed something is a line in the log")

    -- the in-game mod menu
    local index = T.menuIndex(c)
    check(#index == 1 and index[1] == "G1R Combat", "the module's groups are on the page G1R Combat of the in-game mod menu")
    local page = T.menuPage(c, "Combat")
    local titles = {}
    for _, sec in ipairs(page.sections) do titles[#titles + 1] = sec.title .. ":" .. #sec.items end
    check(table.concat(titles, "|") == "Magic: all spells:13|Magic: fire spells:15|Magic: ice spells:12|Magic: energy spells:13|Magic: wind spells:9"
        .. "|Bolt damage by circle:10|Magic: learning the circles:8|Magic: on screen, log:3", "its sections and their items (a sub-tab of more than 28 characters has a short title): " .. table.concat(titles, "|"))
    local item = T.menuItem(c, "Combat", "Damage of every spell")
    check(item.kind == "num" and item.min == 0.1 and item.max == 10 and item.step == 0.05 and item.value == 2 and item.name == "Damage of every spell (times)"
        and item.desc == "1.5 = half as much again, 0.5 = half.", "the damage multiplier: a number from 0.1 to 10 in steps of 0.05, with its value and a short hint")
    for _, i in ipairs(page.items) do
        if has(i.name, "SearchesPerLook") or has(i.name, "CheckSeconds") or has(i.name, "LookMilliseconds") then check(false, "a hidden setting is in the menu: " .. i.name) end
        if #i.desc > 90 or i.desc:sub(-3) == "..." then check(false, "the hint of " .. i.name .. " does not fit into 90 characters and is cut: " .. i.desc) end
    end
    T.menuSet(c, "Combat", "Damage of every spell", 3)
    c.ticks(1)
    check(printed(ue, "[G1R_Magic] settings changed (in-game menu): damage x3\n") ~= nil and w.damage("FireBoltProjectileDefinition", 0) == 105 and w.damage("WindFistDefinition", 6) == 210,
        "an edit in the menu is in the game at the next look: 35 x 3 = 105")
    check(has(T.read(c.path), "Config.Damage = 3.0\n"), "and written into config.lua")
    -- back to 1.0: the game's numbers
    T.menuSet(c, "Combat", "Damage of every spell", 1)
    c.ticks(1)
    check(w.untouched() and c.S.count == 0 and c.ui.note() == "Magic: the game's own values are back", "back at 1.0: every number is the game's own again; the note says so")
    check(has(status(c), "everything as the game has it (the game is not touched)|nothing is changed: the game's own numbers are in place and the game is not looked at"), "the status too")
    local reads, writes = w.reads, w.writes
    c.ticks(300)
    check(w.reads == reads and w.writes == writes and c.searches() == 22, "from then on nothing is read: the module is at rest")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(12)
    check(w.reads == reads, "also after a map change")
    -- two edits at once, one look
    T.menuSet(c, "Combat", "Damage of every spell", 2)
    T.menuSet(c, "Combat", "Damage of fire spells", 0.5)
    c.ticks(1)
    check(w.damage("FireBoltProjectileDefinition", 0) == 35 and w.damage("IceBoltProjectileDefinition", 0) == 40 and c.S.passes == 5,
        "two edits before one look: one look, all spells x2, fire x2 x0.5 = the game's number (which is not counted as changed)")
    check(c.S.count == 65 - 21 and c.S.holders == 15, "44 places in 15 objects hold a number of the module (the 21 of the seven fire definitions do not)")
    -- the whole module off
    T.menuSet(c, "Combat", "Magic balancing", false)
    c.ticks(1)
    check(w.untouched() and c.S.count == 0 and printed(ue, "settings changed (in-game menu): switched off in the settings") ~= nil and has(T.read(c.path), "Config.Enabled = false\n"),
        "switched off in the menu: everything is put back at once")
    reads = w.reads
    c.ticks(300)
    check(w.reads == reads and w.untouched(), "and nothing is read while it is off")
    T.menuSet(c, "Combat", "Magic balancing", true)
    c.ticks(1)
    check(w.damage("IceBoltProjectileDefinition", 0) == 40 and c.S.count == 44 and c.searches() == 22, "switched on again: the settings are back in the game, without a new search")
    -- settings that are not about the game's data
    reads = w.reads
    T.menuSet(c, "Combat", "Note when changes reached the game", false)
    c.ticks(1)
    check(c.ui.note() == nil and w.reads == reads and printed(ue, "settings changed (in-game menu): damage x2, fire x0.5") ~= nil, "ShowMessage off: a note that is up is taken down, the game is not looked at for it")
    local passes = c.S.passes
    T.menuSet(c, "Combat", "Log every value changed", true)
    c.ticks(1)
    check(w.reads == reads and c.S.passes == passes and c.hook.settings.values.LogChanges == true, "LogChanges on: the game is not looked at for that either")
    T.menuSet(c, "Combat", "Damage of wind spells", 2)
    local calls = #c.ui.calls
    c.ticks(1)
    check(w.damage("StormFistDefinition", 6) == 640 and printed(ue, "[G1R_Magic] StormFistDefinition step1.1: 320 -> 640\n") ~= nil and printed(ue, "[G1R_Magic] WindFistDefinition base1: 40 -> 80\n") ~= nil
        and #c.ui.calls == calls, "LogChanges: one line for every number that changes; with ShowMessage off the note box is left alone")
    check(printedCount(ue, "8 value(s) changed, 0 put back: 44 value(s) in 15 object(s)") == 1, "and a line for the look as a whole")
    stop(c)

    -- a change while a look is still under way
    c = start("midway", { config = cfg({ "Config.ManaCost = 1.5" }) })
    ue, w = c.ue, c.world
    c.ticks(3)
    check(c.searches() == 12 and w.mana("ProjectileSpellConfig_FireBolt") == 2 and c.S.queue ~= nil, "(three looks into a pass over 52 configs: twelve are done)")
    T.menuSet(c, "Combat", "Mana cost of every spell", 1)
    c.ticks(1)
    check(w.untouched() and c.searches() == 12 and c.S.queue == nil and c.S.count == 0, "back to 1.0 midway: the twelve are put back, the other forty are never searched")
    T.menuSet(c, "Combat", "Mana cost of every spell", 2)
    c.ticks(2)
    T.menuSet(c, "Combat", "Mana cost of every spell", 3)
    c.settle()
    check(w.mana("ProjectileSpellConfig_FireBolt") == 3 and w.mana("TransformHarpySpellConfig") == 180 and c.searches() == 52,
        "a new value midway: the look starts over with it; in the end every config has it, each searched once")
    stop(c)

    c = start("midway-nothing", { config = cfg({ "Config.CircleCosts = true" }), diag = true })
    c.ticks(1)
    check(c.searches() == 4 and c.S.queue ~= nil, "(one look into a pass over the seven skill effects: four are searched)")
    T.menuSet(c, "Combat", "Own prices for the magic circles", false)
    c.ticks(1)
    check(c.searches() == 4 and c.S.queue == nil and c.S.passes == 1 and c.world.writes == 0 and has(status(c), "the game's own numbers are in place and the game is not looked at"),
        "switched off midway with nothing changed yet: the look ends there, the other three are never searched")
    check(c.fake.value("magic.objects") == "all found" and c.fake.value("magic.applied") == "0 value(s) in 0 object(s)", "and it is closed like any other look (the notes are written)")
    stop(c)

    -- a setting that concerns nothing while its switch is off: no look, no notes, no shared variable
    c = start("idle-edit", { diag = true })
    T.menuSet(c, "Combat", "Fire bolt, below 2nd circle", 31)
    c.ticks(8)
    check(c.hook.settings.values.FireBoltStep0 == 31 and c.S.passes == 0 and c.S.queue == nil and #c.ue.lookups == 0 and c.fake.value("magic.applied") == nil
        and c.fake.value("magic.objects") == nil and c.mods.store["G1R_Magic:changed"] == nil,
        "a number of the bolts changed while their switch is off: taken, but there is nothing to look at - no look, no notes, no shared variable")
    stop(c)
    -- the hidden settings are not about the game's data either; a new CheckSeconds counts from now
    c = start("hidden-edit", { config = cfg({ "Config.Damage = 1.5", "Config.CheckSeconds = 0" }) })
    c.settle()
    local quietReads, quietPasses = c.world.reads, c.S.passes
    T.write(c.path, cfg({ "Config.Damage = 1.5", "Config.CheckSeconds = 0", "Config.SearchesPerLook = 8", "Config.LookMilliseconds = 500", "Config.LogChanges = true" }))
    c.ticks(40)
    check(c.hook.settings.values.SearchesPerLook == 8 and c.world.reads == quietReads and c.S.passes == quietPasses, "SearchesPerLook, LookMilliseconds, LogChanges changed in the file: taken, no look")
    T.write(c.path, cfg({ "Config.Damage = 1.5", "Config.CheckSeconds = 10", "Config.SearchesPerLook = 8", "Config.LookMilliseconds = 500", "Config.LogChanges = true" }))
    c.ticks(20)
    check(c.hook.settings.values.CheckSeconds == 10 and c.world.reads == quietReads, "CheckSeconds from 0 to 10: no look for the change itself")
    c.ticks(40)
    check(c.world.reads > quietReads and c.S.passes == quietPasses + 1, "but the changed places are looked at ten seconds later")
    T.write(c.path, cfg({ "Config.Damage = 1.5", "Config.CheckSeconds = 0", "Config.SearchesPerLook = 8", "Config.LookMilliseconds = 500", "Config.LogChanges = true" }))
    c.ticks(24)
    quietReads = c.world.reads
    c.ticks(400)
    check(c.world.reads == quietReads, "and back at 0 the looks without a reason stop")
    stop(c)

    -- a setting that needs a look but changes nothing shows no note
    c = start("quiet", { widgets = true })
    T.menuSet(c, "Combat", "Own prices for the magic circles", true)
    c.settle()
    check(c.searches() == 7 and c.ui.note() == nil and c.world.writes == 0, "own prices switched on with the game's numbers: looked at, nothing written, no note")
    T.menuSet(c, "Combat", "The 6th circle", 25)
    c.ticks(1)
    check(c.world.price(6) == 25 and c.ui.note() == "Magic: 1 value(s) changed", "one price changed: the note counts one value")
    T.menuSet(c, "Combat", "The 6th circle", 40)
    c.ticks(1)
    check(c.world.price(6) == 40 and c.ui.note() == "Magic: the game's own values are back", "back at the game's price: the note says that the game's own values are back")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("10. a map change, and time: numbers the game has put back are set again, never twice")
do
    local c = start("map", { config = cfg({ "Config.Damage = 1.5" }), diag = true })
    local ue, w = c.ue, c.world
    c.settle()
    local reads, writes = w.reads, w.writes
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    c.ticks(20)
    check(w.reads == reads and w.writes == writes, "between the two map load hooks nothing is read")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(7)
    check(w.reads == reads, "nor in the first two seconds after the load")
    c.ticks(1)
    check(w.reads > reads and w.writes == writes and w.damage("FireBoltProjectileDefinition", 0) == 52.5 and c.searches() == 22,
        "then the changed places are read once: the numbers are still the module's, nothing is written, nothing searched")
    check(c.fake.value("magic.after_load") == "kept" and c.fake.detail("magic.after_load") == "0 of 65 value(s)", "the diagnostics note that the numbers outlived the map change")
    -- the game puts its own numbers back during a load
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    w.restore()
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(7)
    check(w.damage("FireBoltProjectileDefinition", 0) == 35, "(the game has put its numbers back)")
    c.ticks(1)
    check(w.damage("FireBoltProjectileDefinition", 0) == 52.5 and w.damage("FireBallProjectileDefinition_Lvl3", 6) == 300 and c.S.count == 65,
        "two seconds after the load the numbers are set again: 35 x 1.5 = 52.5, once")
    check(c.fake.value("magic.after_load") == "reset" and c.fake.detail("magic.after_load") == "65 of 65 value(s)"
        and printedCount(ue, "[G1R_Magic] the game had put 65 number(s) back to its own (after a map change); they are set again whenever that is seen\n") == 1, "noted, and said once in the log")
    -- only one object is reset
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    w.restore("WindFistDefinition")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    writes = w.writes
    c.ticks(8)
    check(w.damage("WindFistDefinition", 6) == 105 and w.writes == writes + 5 and w.damage("FireBoltProjectileDefinition", 0) == 52.5 and printedCount(ue, "the game had put") == 1,
        "one object reset: its five numbers are written again, the others are left as they are; not said twice")
    -- a load whose end is never reported
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    w.restore("FireRainDefinition")
    c.ticks(79)
    check(w.damage("FireRainDefinition", 0) == 50, "a map load that never reports its end: nothing for 20 seconds")
    c.ticks(1)
    check(w.damage("FireRainDefinition", 0) == 75 and #ue.errors == 0, "then the look runs all the same")
    stop(c)

    -- a map change while a look after a changed setting is still under way
    c = start("map-midway", { config = cfg({ "Config.Damage = 1.5" }), widgets = true, diag = true })
    ue, w = c.ue, c.world
    c.settle()
    T.menuSet(c, "Combat", "Mana cost of every spell", 2)
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    w.restore("WindFistDefinition")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(7)
    check(c.S.queue ~= nil and c.S.passes == 1 and w.damage("WindFistDefinition", 0) == 30 and c.searches() == 22 + 28,
        "(seven looks into the pass over the 52 configs; the fist of wind, put back by the game, is set again already)")
    local looks = 7 + c.settle()
    check(looks == 13 and c.S.passes == 2 and c.searches() == 74,
        "the look after the map change joins the one under way: it starts over with what is found already (" .. looks .. " looks in all, as without the map change), each config is searched once")
    check(c.fake.value("magic.after_load") == "reset" and c.fake.detail("magic.after_load") == "5 of 65 value(s)",
        "what the first part of the look found put back still counts: 5 of the 65 numbers (each counted once): " .. tostring(c.fake.detail("magic.after_load")))
    check(c.ui.note() == "Magic: 132 value(s) changed" and printed(ue, "the game had put 5 number(s) back to its own (after a map change)") ~= nil and c.S.count == 132,
        "so does its reason: the note for the changed setting is shown at the end, the log says what the game did")
    check(c.fake.events[#c.fake.events] == "look 2 (settings, world): 74 object(s), 72 value(s) changed, 0 put back: 132 value(s) in 74 object(s) of the game hold the module's numbers now; 0 failed, 5 reset by the game",
        "the diagnostics event of the look: " .. tostring(c.fake.events[#c.fake.events]))
    stop(c)

    -- the game puts a number back between the parts of one look, twice
    c = start("midway-reset", { config = cfg({ "Config.Damage = 1.5" }), diag = true })
    ue, w = c.ue, c.world
    c.settle()
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    T.menuSet(c, "Combat", "Mana cost of every spell", 2)
    c.ticks(2)                                  -- the look for the new setting has come by all definitions (65 numbers held) and searches configs
    w.restore("FireRainDefinition")
    T.menuSet(c, "Combat", "Mana cost of every spell", 3)
    c.ticks(2)                                  -- it starts over: the rain of fire is found put back, and set again
    check(w.damage("FireRainDefinition", 0) == 75 and c.S.queue ~= nil and c.S.passes == 1, "(a number put back between two parts of a look is set again when the look comes by the second time)")
    w.restore("FireRainDefinition")
    T.menuSet(c, "Combat", "Mana cost of every spell", 4)
    c.settle()                                  -- it starts over once more; two seconds after the map change that reason joins
    check(w.damage("FireRainDefinition", 0) == 75 and w.mana("ProjectileSpellConfig_FireBolt") == 4 and c.S.passes == 2, "put back a second time: set again; the look ends as one look")
    check(c.fake.value("magic.after_load") == "reset" and c.fake.detail("magic.after_load") == "1 of 65 value(s)"
        and printed(ue, "the game had put 1 number(s) back to its own (after a map change)") ~= nil and has(c.fake.events[#c.fake.events], "; 0 failed, 1 reset by the game"),
        "the number counts once: 1 of the 65 that were the module's when the look first came by (" .. tostring(c.fake.detail("magic.after_load")) .. ")")
    stop(c)

    -- without a map change: the look every CheckSeconds
    c = start("check", { config = cfg({ "Config.Damage = 1.5", "Config.CheckSeconds = 10" }), diag = true })
    ue, w = c.ue, c.world
    c.settle()
    local quietEvents, quietReads = #c.fake.events, w.reads
    c.ticks(40)
    check(w.reads > quietReads and #c.fake.events == quietEvents,
        "a look by CheckSeconds that finds every number in place writes no diagnostics line (one a minute pushed everything else out of the recorder's last lines)")
    w.restore("IceBoltProjectileDefinition")
    c.ticks(39)
    check(w.damage("IceBoltProjectileDefinition", 0) == 20, "(a number put back between two map changes)")
    c.ticks(1)
    check(w.damage("IceBoltProjectileDefinition", 0) == 30 and c.fake.value("magic.between_loads") == "reset" and c.fake.detail("magic.between_loads") == "4 of 65 value(s)"
        and printed(ue, "the game had put 4 number(s) back to its own (without a map change)") ~= nil, "is set again at the next look (CheckSeconds = 10), noted and said")
    check(#c.fake.events == quietEvents + 1 and has(c.fake.events[#c.fake.events], " (check): ") and has(c.fake.events[#c.fake.events], "; 0 failed, 4 reset by the game"),
        "a look by CheckSeconds that found numbers reset writes its line: " .. tostring(c.fake.events[#c.fake.events]))
    stop(c)
    c = start("check-often", { config = cfg({ "Config.Damage = 1.5", "Config.CheckSeconds = 1" }) })
    w = c.world
    c.settle()
    local often = w.reads
    c.ticks(3)
    check(w.reads == often, "CheckSeconds = 1: nothing for three quarters of a second")
    c.ticks(1)
    check(w.reads > often, "then a look")
    stop(c)
    c = start("check-off", { config = cfg({ "Config.Damage = 1.5", "Config.CheckSeconds = 0" }) })
    w = c.world
    c.settle()
    local before = w.reads
    c.ticks(1200)
    check(w.reads == before, "CheckSeconds = 0: five minutes without a look")
    c.ue:fireLoadMapPre("engine", "world", "url", nil, "")
    c.ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(8)
    check(w.reads > before, "a map change still brings one")
    stop(c)
    c = start("no-post-hook", { config = cfg({ "Config.Damage = 1.5" }), mock = { without = { "RegisterLoadMapPostHook" } } })
    c.settle()
    c.world.restore()
    c.ue:fireLoadMapPre("engine", "world", "url", nil, "")
    c.ticks(8)
    check(c.world.damage("FireBoltProjectileDefinition", 0) == 52.5 and #c.ue.errors == 0, "a UE4SS without the hook after a map load: the look comes two seconds after the hook before it")
    stop(c)
    c = start("no-loop", { config = cfg({ "Config.Damage = 1.5" }), mock = { without = { "LoopInGameThreadWithDelay" } } })
    check(c.ok and printed(c.ue, "FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; the magic balancing is disabled.") ~= nil and #c.ue.errors == 0 and c.world.untouched(),
        "a UE4SS without the game-thread loop: said, nothing else happens")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("11. the Lua mods are loaded again while the game runs: the module does not take its own numbers for the game's")
do
    local LEDGER = "G1R_Magic:changed"
    -- a first run that leaves numbers in the game, as the base of every case
    local function firstRun(lines, options)
        options = options or {}
        options.config, options.diag = cfg(lines), true
        local first = start("reload-first", options)
        first.settle()
        return first
    end
    local first = firstRun({ "Config.Damage = 1.5", "Config.IceBlockFreeze = true" })
    local world, store = first.world, first.mods.store
    check(type(store[LEDGER]) == "string" and has("\n" .. store[LEDGER] .. "\n", "\nFireBoltProjectileDefinition|base1|35|52.5\n")
        and has(store[LEDGER], "GE_IceBlock_Freeze_Damage|force1|false|true") and select(2, store[LEDGER]:gsub("[^\n]+", "")) == 66,
        "the game's number and the module's are kept in a UE4SS shared variable, one line for each of the 66 changed places")
    check(first.fake.value("magic.ledger") == "kept" and first.fake.value("magic.inherited") == "none" and first.fake.count["magic.ledger"] == 1, "noted for the diagnostics")
    local sets, set = 0, first.mods.SetSharedVariable
    first.mods.SetSharedVariable = function(self, name, value)
        if name == LEDGER then sets = sets + 1 end
        return set(self, name, value)
    end
    first.ticks(480)
    check(sets == 0 and first.S.passes == 3, "it is written when its text changes, not at every look (two looks a minute apart: no write)")
    stop(first)

    -- loaded again with the same settings
    local c = start("reload-same", { config = cfg({ "Config.Damage = 1.5", "Config.IceBlockFreeze = true" }), reuse = world, shared = store, diag = true })
    check(printed(c.ue, "[G1R_Magic] 66 value(s) of the game still hold numbers from before the Lua mods were reloaded; they are taken over\n") ~= nil
        and c.fake.value("magic.inherited") == "66 value(s)", "the second run finds the 66 places in the shared variable: said and noted")
    local writes = world.writes
    c.settle()
    check(world.damage("FireBoltProjectileDefinition", 0) == 52.5 and world.damage("FireBallProjectileDefinition_Lvl3", 6) == 300 and world.writes == writes and c.S.count == 66,
        "the numbers stay as they are (52.5, not 78.75): nothing is written, and the 66 places count as the module's")
    check(c.rec("FireBoltProjectileDefinition").slots.base1.orig == 35 and c.fake.value("magic.original.FireBoltProjectileDefinition") == "base 35, steps 40 50 65, speed 4000, stagger 30",
        "the game's own numbers are known again: 35, then 40 50 65")
    T.menuSet(c, "Combat", "Damage of every spell", 2)
    c.ticks(1)
    check(world.damage("FireBoltProjectileDefinition", 0) == 70 and has("\n" .. c.mods.store[LEDGER] .. "\n", "\nFireBoltProjectileDefinition|base1|35|70\n"), "a new multiplier counts from the game's 35: 70; the shared variable follows")
    stop(c)

    -- loaded again with everything neutral: the game's numbers are put back
    c = start("reload-neutral", { reuse = world, shared = c.mods.store, diag = true })
    check(printed(c.ue, "loaded: everything as the game has it (the game is not touched)") ~= nil, "(third run: shipped settings)")
    c.settle()
    check(world.untouched() and c.S.count == 0 and c.mods.store[LEDGER] == "" and c.searches() == 23, "what the earlier run left is put back: the 23 objects are searched for that, the game is untouched, the shared variable empty")
    check(printedCount(c.ue, "[G1R_Magic] 0 value(s) changed, 66 put back: 0 value(s) in 0 object(s) of the game hold the module's numbers now\n") == 1, "said in the log, also when a look only puts numbers back")
    local reads = world.reads
    c.ticks(300)
    check(world.reads == reads, "then the module is at rest")
    stop(c)

    -- loaded again switched off
    first = firstRun({ "Config.SchoolWind = 2.0", "Config.CircleCosts = true", "Config.CircleCost6 = 25" })
    world = first.world
    stop(first)
    c = start("reload-off", { config = cfg({ "Config.Enabled = false", "Config.SchoolWind = 2.0" }), reuse = world, shared = first.mods.store })
    c.settle()
    check(world.untouched() and world.price(6) == 40 and c.S.count == 0, "loaded again switched off: everything is put back")
    stop(c)

    -- loaded again while only a part is still as the module left it
    first = firstRun({ "Config.Damage = 1.5" })
    world = first.world
    stop(first)
    world.restore("FireRainDefinition")                                             -- the game put this one back
    world.data.definitions.StormOfFireDefinition.base[1].value = 999                -- somebody else changed this one
    c = start("reload-mixed", { config = cfg({ "Config.Damage = 2.0" }), reuse = world, shared = first.mods.store, diag = true })
    c.settle()
    check(world.damage("FireRainDefinition", 0) == 100 and world.damage("FireBoltProjectileDefinition", 0) == 70 and world.damage("StormOfFireDefinition", 0) == 999
        and world.damage("StormOfFireDefinition", 6) == 600, "a place the game put back meanwhile: 50 x 2; one that holds a stranger's number: left alone; the rest from the game's numbers")
    stop(c)

    -- what the shared variable holds is not trusted blindly
    first = firstRun({ "Config.FireBoltDamage = 2.0" })
    world = first.world
    stop(first)
    local junk = "nonsense\n|||\nNoSuchObject|base1|1|2\nFireBoltProjectileDefinition|base1|x|70\nFireBoltProjectileDefinition|base1|35\n" .. first.mods.store[LEDGER]
    c = start("reload-junk", { config = cfg({ "Config.FireBoltDamage = 3.0" }), reuse = world, shared = { [LEDGER] = junk }, diag = true })
    check(c.fake.value("magic.inherited") == "4 value(s)", "lines that are not of the form Object|place|number|number, or name no object of the module, are passed over")
    c.settle()
    check(world.damage("FireBoltProjectileDefinition", 0) == 105 and world.damage("FireBoltProjectileDefinition", 6) == 195 and not has(c.mods.store[LEDGER], "NoSuchObject"), "the four good lines are used: 35 x 3 = 105")
    stop(c)
    c = start("reload-number", { config = cfg({ "Config.FireBoltDamage = 3.0" }), reuse = world, shared = { [LEDGER] = 5 } })
    c.settle()
    check(c.ok and #c.ue.errors == 0, "a shared variable that is no text is passed over")
    stop(c)

    -- an object the earlier run changed is not there for this run
    first = firstRun({ "Config.Damage = 1.5" })
    world = first.world
    stop(first)
    world.hidden.FireRainDefinition = true
    c = start("reload-absent", { reuse = world, shared = first.mods.store })
    c.settle()
    check(world.damage("FireRainDefinition", 0) == 75 and world.damage("FireBoltProjectileDefinition", 0) == 35 and not has(c.mods.store[LEDGER], "FireRain")
        and printed(c.ue, "not found in this game: FireRainDefinition") ~= nil, "what cannot be found cannot be put back: said, and dropped from the shared variable")
    stop(c)

    -- a single value is taken over too
    first = firstRun({ "Config.FireBoltSteps = true", "Config.FireBoltStep0 = 30" })
    world = first.world
    stop(first)
    c = start("reload-one", { reuse = world, shared = first.mods.store, diag = true })
    c.settle()
    check(c.fake.value("magic.inherited") == "1 value(s)" and world.untouched() and c.searches() == 1, "one value left by the earlier run: taken over and, with the shipped settings, put back")
    stop(c)

    -- loaded again twice, the second time before the first reload had looked at everything
    first = firstRun({ "Config.Damage = 1.5" })
    world = first.world
    stop(first)
    c = start("reload-twice-1", { config = cfg({ "Config.Damage = 2.0", "Config.SearchesPerLook = 1" }), reuse = world, shared = first.mods.store })
    c.ticks(3)
    check(world.damage("FireBoltProjectileDefinition", 0) == 70 and world.damage("FireBallProjectileDefinition_Lvl2", 0) == 220 and world.damage("BreathOfDeathDefinition", 0) == 225 and c.S.queue ~= nil,
        "(second run, stopped after three looks: three definitions hold its x2, nineteen still the x1.5 of the first run)")
    local between = c.mods.store
    check(has("\n" .. between[LEDGER] .. "\n", "\nFireBoltProjectileDefinition|base1|35|70\n") and has("\n" .. between[LEDGER] .. "\n", "\nBreathOfDeathDefinition|base1|150|225\n")
        and select(2, between[LEDGER]:gsub("[^\n]+", "")) == 65, "the shared variable has what this run wrote and, unchanged, what it had not come to yet: 65 lines")
    stop(c)
    c = start("reload-twice-2", { reuse = world, shared = between })
    c.settle()
    check(world.untouched(), "the third run puts all of it back: the game's numbers were handed on through both reloads")
    stop(c)

    -- the Lua mods are loaded again while a look is still under way
    first = start("reload-midway", { config = cfg({ "Config.ManaCost = 1.5" }) })
    first.ticks(3)
    world, store = first.world, first.mods.store
    check(first.S.queue ~= nil and has("\n" .. tostring(store[LEDGER]) .. "\n", "\nProjectileSpellConfig_FireBolt|mana1|1|2\n") and not has(store[LEDGER], "TransformHarpySpellConfig"),
        "what a look has written is in the shared variable at the end of every part of it (three parts done: twelve configs)")
    stop(first)
    c = start("reload-midway-2", { config = cfg({ "Config.ManaCost = 1.5" }), reuse = world, shared = store })
    c.settle()
    check(world.mana("ProjectileSpellConfig_FireBolt") == 2 and world.mana("PyrokinesisSpellConfig") == 8 and world.mana("TransformHarpySpellConfig") == 90 and c.S.count == 67,
        "the next run takes the twelve over (fire bolt 2, not 3) and does the other forty")
    stop(c)

    -- without shared variables nothing can be kept: the known limit
    first = start("reload-noref", { config = cfg({ "Config.Damage = 1.5" }), noModRef = true, diag = true })
    first.settle()
    check(first.world.damage("FireBoltProjectileDefinition", 0) == 52.5 and first.fake.value("magic.ledger") == "not available" and #first.ue.errors == 0,
        "a UE4SS without shared variables: the module works, and notes that it cannot keep the game's numbers through a reload")
    stop(first)
    c = start("reload-noref-2", { config = cfg({ "Config.Damage = 1.5" }), reuse = first.world, noModRef = true })
    c.settle()
    check(first.world.damage("FireBoltProjectileDefinition", 0) == 78.75, "(then a reload of the Lua mods makes it take 52.5 for the game's number - what the shared variable is there to prevent)")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("12. numbers that somebody else changed are left alone")
do
    local c = start("others", { config = cfg({ "Config.Damage = 1.5", "Config.CheckSeconds = 10" }), diag = true })
    local ue, w = c.ue, c.world
    c.settle()
    local bolt = w.data.definitions.FireBoltProjectileDefinition
    bolt.base[1].value = 30                 -- another mod writes its own number over the module's
    c.ticks(40)
    check(bolt.base[1].value == 30 and w.damage("FireBoltProjectileDefinition", 2) == 60, "a number that is neither the game's nor the module's is not touched (30 stays); its neighbours are as before")
    check(c.S.count == 64 and has(status(c), "|changed by something else and left alone: 1 (FireBoltProjectileDefinition base1)") and c.fake.value("magic.others") == "1 value(s)"
        and c.fake.detail("magic.others") == "FireBoltProjectileDefinition base1", "it no longer counts as changed by the module; status and diagnostics name it")
    check(printedCount(ue, "[G1R_Magic] 1 number(s) were changed by something else (another mod?) and are left alone, first FireBoltProjectileDefinition base1; the status lists them\n") == 1, "said once in the log")
    T.menuSet(c, "Combat", "Damage of every spell", 2)
    c.ticks(1)
    check(bolt.base[1].value == 30 and w.damage("FireBoltProjectileDefinition", 2) == 80 and w.damage("IceBoltProjectileDefinition", 0) == 40, "a new multiplier: everything else follows, the stranger's number stays")
    local lines = table.concat(c.hook.values(), "|")
    check(has(lines, "FireBoltProjectileDefinition: step1.1 40 -> 80, step1.2 50 -> 100, step1.3 65 -> 130|") and not has(lines, "base1 35 -> 70, step1.1 40"),
        "the list of changed values leaves it out")
    bolt.base[1].value = 35                 -- the other mod gives the game's number back
    c.ticks(40)
    check(bolt.base[1].value == 70 and c.S.count == 65 and c.fake.value("magic.others") == "none" and not has(status(c), "left alone"), "once the place holds the game's number again it is the module's to set: 70")
    bolt.base[1].value = 99
    bolt.steps[2].m_Damage = 98
    T.menuSet(c, "Combat", "Magic balancing", false)
    c.ticks(1)
    local same, what = w.untouched()
    check(not same and what == "FireBoltProjectileDefinition base 99" and bolt.steps[2].m_Damage == 98 and bolt.steps[1].m_Damage == 40 and w.damage("IceBoltProjectileDefinition", 0) == 20,
        "switched off: everything is put back except the two numbers that are a stranger's")
    check(has(status(c), "switched off in the settings|nothing is changed: the game's own numbers are in place and the game is not looked at|changed by something else and left alone: 2 ("),
        "the status says what was left as it is")
    check(printedCount(ue, "were changed by something else") == 1, "not said a second time")
    stop(c)

    -- the lists of an object have other lengths than at the first look
    c = start("shape", { config = cfg({ "Config.Damage = 1.5", "Config.CheckSeconds = 10" }), diag = true })
    ue, w = c.ue, c.world
    c.settle()
    local fist = w.data.definitions.WindFistDefinition
    table.insert(fist.steps, { m_CircleTag = 7, m_Damage = 500 })
    T.menuSet(c, "Combat", "Damage of every spell", 2)
    c.ticks(1)
    check(fist.base[1].value == 30 and fist.steps[4].m_Damage == 105 and fist.steps[5].m_Damage == 500 and w.damage("StormFistDefinition", 0) == 240,
        "a definition that has another step than at the first look is left alone as it is; the others follow the new multiplier")
    check(printedCount(ue, "[G1R_Magic] WindFistDefinition has another shape than before (1/5, was 1/4): it is left alone\n") == 1
        and has(status(c), "|another shape than at the first look, left alone: WindFistDefinition"), "said once in the log; the status names it")
    c.ticks(80)
    check(printedCount(ue, "has another shape") == 1 and fist.base[1].value == 30, "and not again at later looks")
    local shifted = c.fake.dump[1]().objects
    check(shifted.WindFistDefinition.shifted == true and shifted.WindFistDefinition.shape == "1/4" and shifted.StormFistDefinition.shifted == nil, "the dump marks the object (and no other)")
    table.remove(fist.steps, 5)
    c.ticks(40)
    check(fist.base[1].value == 40 and fist.steps[4].m_Damage == 140 and not has(status(c), "another shape"), "with the old shape back it is the module's again: 20 x 2 = 40")
    stop(c)
    c = start("shape-effect", { config = cfg({ "Config.IceBlockFreeze = true", "Config.CheckSeconds = 10" }) })
    w = c.world
    c.settle()
    local stacks = w.data.effects.GE_IceBlock_Freeze_Damage.stacks
    stacks[2] = { ForceOverflowElementalEffectStack = false }
    T.menuSet(c, "Combat", "Ice block: freezes with every hit", false)
    c.ticks(1)
    check(stacks[1].ForceOverflowElementalEffectStack == true and stacks[2].ForceOverflowElementalEffectStack == false
        and printed(c.ue, "[G1R_Magic] GE_IceBlock_Freeze_Damage has another shape than before (2, was 1): it is left alone\n") ~= nil,
        "a hit effect that has two ice counters where it had one: left alone as it is")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("13. things that are not there, or do not work: said once, the rest keeps working, nothing is searched twice")
do
    local function lookups(c, name)
        local n = 0
        for _, path in ipairs(c.ue.lookups) do if path == PATH .. name then n = n + 1 end end
        return n
    end
    -- an object this build of the game does not have
    local c = start("absent", { config = cfg({ "Config.Damage = 1.5" }), game = { absent = { FireRainDefinition = true, StormFistDefinition = true } }, diag = true })
    local ue, w = c.ue, c.world
    c.settle()
    check(printedCount(ue, "[G1R_Magic] not found in this game: FireRainDefinition, StormFistDefinition - what these would change stays as the game has it\n") == 1,
        "two definitions that do not exist: one line in the log names both")
    check(c.fake.value("magic.objects") == "2 not found" and c.fake.detail("magic.objects") == "FireRainDefinition, StormFistDefinition"
        and has(status(c), "|not found in this game: FireRainDefinition, StormFistDefinition"), "diagnostics and status name them")
    check(w.damage("FireBoltProjectileDefinition", 0) == 52.5 and w.damage("BreathOfDeathDefinition", 0) == 225 and c.S.count == 65 - 3 and c.S.holders == 20, "the other twenty are changed")
    T.menuSet(c, "Combat", "Damage of every spell", 2)
    c.ticks(1)
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(8)
    T.menuSet(c, "Combat", "Force against stance (times)", 2)
    c.ticks(300)
    check(lookups(c, "FireRainDefinition") == 1 and lookups(c, "StormFistDefinition") == 1 and c.searches() == 22 and printedCount(ue, "not found in this game") == 1,
        "a changed setting, a map change, another setting, a minute of looks: neither is searched again, the line is not repeated")
    stop(c)
    -- a config that is missing shows up in a later look: a line of its own
    c = start("absent-later", { config = cfg({ "Config.Damage = 1.5" }), game = { absent = { FireRainDefinition = true, SleepSpellConfig = true } } })
    c.settle()
    T.menuSet(c, "Combat", "Mana cost of every spell", 2)
    c.settle()
    check(printedCount(c.ue, "not found in this game: FireRainDefinition - ") == 1 and printedCount(c.ue, "not found in this game: SleepSpellConfig - ") == 1
        and has(status(c), "|not found in this game: FireRainDefinition, SleepSpellConfig") and c.world.mana("CharmSpellConfig") == 10,
        "what turns out to be missing later gets its own line; the status lists both")
    stop(c)
    -- StaticFindObject can also answer with nil
    c = start("absent-nil", { config = cfg({ "Config.HealAmount = 2.0", "Config.IceBlockFreeze = true" }), game = { absent = { HealSpellConfig = true } }, mock = { nilWhenMissing = true },
        diag = true })
    c.settle()
    check(printed(c.ue, "not found in this game: HealSpellConfig") ~= nil and c.world.freezes("GE_IceBlock_Freeze_Damage", 1) and #c.ue.errors == 0, "a search that answers nil: the same")
    check(c.fake.value("magic.objects") == "1 not found" and c.fake.detail("magic.objects") == "HealSpellConfig" and has(status(c), "|not found in this game: HealSpellConfig")
        and c.fake.value("magic.properties") == "all there" and c.fake.detail("magic.properties") == nil and c.fake.detail("magic.others") == nil,
        "a single missing object is named in the diagnostics and the status like several (notes without anything to name have no detail)")
    stop(c)
    -- something else answers to the path
    c = start("absent-other", { config = cfg({ "Config.CircleCosts = true", "Config.CircleCost1 = 3" }), prepare = function(ue2, world)
        world.stranger = ue2:object("GE_Skill_Mage_Circle_1 /Script/Angelscript.Default__GE_Skill_Mage_Circle_10", { SPCost = 77 })
        ue2.objects[PATH .. "GE_Skill_Mage_Circle_1"] = world.stranger
    end })
    c.settle()
    check(rawget(c.world.stranger, "SPCost") == 77 and c.world.price(1) == 10 and printed(c.ue, "not found in this game: GE_Skill_Mage_Circle_1 - ") ~= nil,
        "an object whose name is not the one asked for is not taken")
    stop(c)

    -- properties that are not there
    c = start("lacking", { config = cfg({ "Config.Damage = 1.5", "Config.ProjectileSpeed = 2.0", "Config.Stagger = 2.0" }),
        game = { lacking = { FireBoltProjectileDefinition = { "m_Speed" }, IceBoltProjectileDefinition = { "m_DamageBase", "m_SuperArmorDamageBase" },
            WindFistDefinition = { "m_DamageMagicCircleProgression" } } }, diag = true })
    ue, w = c.ue, c.world
    c.settle()
    check(printedCount(ue, "[G1R_Magic] not there in this game: FireBoltProjectileDefinition.m_Speed, IceBoltProjectileDefinition.m_DamageBase, IceBoltProjectileDefinition.m_SuperArmorDamageBase, "
        .. "WindFistDefinition.m_DamageMagicCircleProgression - the settings for them change nothing\n") == 1, "properties this build does not have: one line names them")
    check(c.fake.value("magic.properties") == "4 not there" and has(status(c), "|not there in this game: FireBoltProjectileDefinition.m_Speed, "), "diagnostics and status too")
    check(w.damage("FireBoltProjectileDefinition", 0) == 52.5 and w.stagger("FireBoltProjectileDefinition") == 60 and w.speed("FireBoltProjectileDefinition") == 4000
        and w.damage("IceBoltProjectileDefinition", 2) == 45 and w.speed("IceBoltProjectileDefinition") == 8000 and w.damage("WindFistDefinition", 0) == 30 and w.stagger("WindFistDefinition") == 400,
        "what is there is changed: the bolt's damage and stagger without its speed, the ice bolt's steps and speed without its base")
    check(c.fake.value("magic.original.FireBoltProjectileDefinition") == "base 35, steps 40 50 65, speed -, stagger 30"
        and c.fake.value("magic.original.IceBoltProjectileDefinition") == "base -, steps 30 40 50, speed 4000, stagger -" and c.fake.value("magic.original.WindFistDefinition") == "base 20, steps -, speed 1500, stagger 200",
        "the note of the game's own numbers shows what could be read")
    stop(c)
    c = start("lacking-more", { config = cfg({ "Config.ManaCost = 2.0", "Config.Range = 2.0", "Config.HealAmount = 2.0", "Config.IceBlockFreeze = true", "Config.IceWaveFreeze = true",
        "Config.CircleCosts = true", "Config.CircleCost1 = 3" }), game = { lacking = { IceBlockSpellConfig = { "m_SpellLevels" }, HealSpellConfig = { "m_healAmountByMagicCircle", "m_AreaRange" },
        GE_IceBlock_Freeze_Damage = { "m_ElementalEffectStacks" }, GE_Skill_Mage_Circle_1 = { "SPCost" } } }, diag = true,
        prepare = function(_, world)
            world.data.effects.GE_IceWave_Freeze_Damage.stacks[1] = nil                         -- an effect without an ice counter
            world.data.configs.StormFistSpellConfig.levels[1] = nil                             -- a config without a level
            world.data.configs.FireRainSpellConfig.levels[1].CastManaCost = nil                 -- a level without one of its numbers
        end })
    ue, w = c.ue, c.world
    c.settle()
    local line = printed(ue, "not there in this game: ") or ""
    check(has(line, "IceBlockSpellConfig.m_SpellLevels") and has(line, "HealSpellConfig.m_AreaRange") and has(line, "HealSpellConfig.m_healAmountByMagicCircle")
        and has(line, "GE_IceBlock_Freeze_Damage.m_ElementalEffectStacks") and has(line, "GE_IceWave_Freeze_Damage.m_ElementalEffectStacks") and has(line, "GE_Skill_Mage_Circle_1.SPCost")
        and has(line, "StormFistSpellConfig.m_SpellLevels") and has(line, "FireRainSpellConfig.CastManaCost"),
        "a config without levels, without reach, without the heal map; an effect without its list or with an empty one; a skill without price; a level without its mana: all named")
    check(w.range("SleepSpellConfig") == 3000 and w.mana("HealSpellConfig") == 4 and w.range("HealSpellConfig") == 1500 and w.heal(1) == 4 and w.price(1) == 10 and w.price(2) == 15 and not w.freezes("GE_IceBlock_Freeze_Damage", 1)
        and w.range("StormFistSpellConfig") == 1400 and w.held("PyrokinesisSpellConfig") == 2 and near(w.time("FireRainSpellConfig"), 0.1),
        "the rest of each object, and every other object, is changed as set")
    check(c.rec("HealSpellConfig").shape == "1/0" and c.fake.value("magic.original.IceBlockSpellConfig") == "levels -" and c.fake.value("magic.original.HealSpellConfig") == "levels 2 0.1 1, range -, heal -"
        and c.fake.value("magic.original.GE_IceWave_Freeze_Damage") == "-" and c.fake.value("magic.original.GE_Skill_Mage_Circle_1") == "-"
        and c.fake.value("magic.original.FireRainSpellConfig") == "levels - 0.1 0" and c.fake.value("magic.original.StormFistSpellConfig") == "levels -, range 700", "the notes show the gaps")
    check(#ue.errors == 0 and w.indexed == 0, "no error, and no list was indexed")
    stop(c)

    c = start("lacking-one", { config = cfg({ "Config.CircleCosts = true", "Config.CircleCost2 = 12" }), game = { lacking = { GE_Skill_Mage_Circle_1 = { "SPCost" } } }, diag = true })
    c.settle()
    check(c.fake.value("magic.properties") == "1 not there" and c.fake.detail("magic.properties") == "GE_Skill_Mage_Circle_1.SPCost"
        and has(status(c), "|not there in this game: GE_Skill_Mage_Circle_1.SPCost") and c.world.price(2) == 12 and c.fake.detail("magic.objects") == nil,
        "a single property that is not there: named in the diagnostics and the status too")
    stop(c)
    c = start("empty", { config = cfg({ "Config.HealAmount = 2.0" }), diag = true, prepare = function(_, world)
        world.data.configs.HealSpellConfig.heal = {}                        -- a heal map without entries
        world.broken["HealSpellConfig.m_SpellLevels"] = true
    end })
    c.settle()
    check(printed(c.ue, "[G1R_Magic] not there in this game: HealSpellConfig.m_SpellLevels, HealSpellConfig.m_healAmountByMagicCircle - ") ~= nil and c.rec("HealSpellConfig").shape == "0/0"
        and c.fake.value("magic.original.HealSpellConfig") == "levels -, range 1500, heal -" and c.world.writes == 0, "a heal map without entries and levels that cannot be walked: named; nothing to change")
    stop(c)

    -- a map or a list that cannot be walked, a number that is none
    c = start("unreadable", { config = cfg({ "Config.Damage = 1.5", "Config.ManaCost = 2.0", "Config.IceBoltFreeze = true", "Config.IceBlockFreeze = true", "Config.HealAmount = 2.0",
        "Config.FireBoltSteps = true", "Config.FireBoltStep2 = 44" }), diag = true,
        prepare = function(_, world)
            world.broken["FireBoltProjectileDefinition.m_DamageBase"] = true
            world.broken["IceBoltProjectileDefinition.m_DamageMagicCircleProgression"] = true
            world.broken["WindFistDefinition.m_DamageByMagicCircle"] = true
            world.broken["ProjectileSpellConfig_FireBolt.m_SpellLevels"] = true
            world.broken["GE_IceBolt_Damage.m_ElementalEffectStacks"] = true
            world.broken["HealSpellConfig.m_healAmountByMagicCircle"] = true
            world.data.definitions.FireRainDefinition.base[1].value = 0 / 0
            world.data.definitions.StormFistDefinition.steps[1].m_Damage = "many"
            world.data.effects.GE_IceBlock_Freeze_Damage.stacks[1].ForceOverflowElementalEffectStack = 0
            world.sealed["PyrokinesisProjectileDefinition.m_DamageBase"] = true
            world.sealed["StormOfFireDefinition.m_DamageMagicCircleProgression"] = true
        end })
    ue, w = c.ue, c.world
    c.settle()
    line = printed(ue, "not there in this game: ") or ""
    check(has(line, "PyrokinesisProjectileDefinition.m_DamageBase") and has(line, "StormOfFireDefinition.m_DamageMagicCircleProgression")
        and w.damage("PyrokinesisProjectileDefinition", 0) == 20 and w.damage("PyrokinesisProjectileDefinition", 5) == 52.5 and w.damage("StormOfFireDefinition", 0) == 375
        and w.damage("StormOfFireDefinition", 6) == 300, "a map whose values cannot be read: named as not there; what can be read of the object is changed (the step without the base, the base without the step)")
    check(w.crossed == 0, "no error leaves a function that UE4SS runs inside a walk")
    check(has(line, "GE_IceBlock_Freeze_Damage.ForceOverflowElementalEffectStack") and w.data.effects.GE_IceBlock_Freeze_Damage.stacks[1].ForceOverflowElementalEffectStack == 0,
        "a freeze flag that is no yes / no value: named, and not written")
    check(c.rec("FireBoltProjectileDefinition").shape == "0/3" and c.fake.value("magic.steps") == "other shape" and c.fake.detail("magic.steps") == "FireBoltProjectileDefinition 0/3"
        and c.rec("WindFistDefinition").shape == "1/0" and c.rec("GE_IceBolt_Damage").shape == "0" and c.rec("HealSpellConfig").shape == "1/0",
        "the shape of each object says what could be walked (0 = not): the bolt without its base map is not the shape its own numbers are for")
    check(has(line, "FireBoltProjectileDefinition.m_DamageBase") and has(line, "IceBoltProjectileDefinition.m_DamageMagicCircleProgression") and has(line, "WindFistDefinition.m_DamageMagicCircleProgression")
        and has(line, "ProjectileSpellConfig_FireBolt.m_SpellLevels") and has(line, "GE_IceBolt_Damage.m_ElementalEffectStacks") and has(line, "HealSpellConfig.m_healAmountByMagicCircle")
        and has(line, "FireRainDefinition.m_DamageBase") and has(line, "StormFistDefinition.m_Damage"),
        "a map or list whose walk raises, a damage that is not a number: named as not there")
    check(w.damage("FireBoltProjectileDefinition", 2) == 60 and w.damage("IceBoltProjectileDefinition", 0) == 30 and w.damage("WindFistDefinition", 0) == 30
        and w.damage("StormFistDefinition", 0) == 180 and w.mana("ProjectileSpellConfig_IceBolt") == 2 and w.mana("HealSpellConfig") == 4 and #ue.errors == 0,
        "everything that can be read is changed; no error reaches UE4SS")
    stop(c)

    -- a write that does not stay
    c = start("frozen", { config = cfg({ "Config.Damage = 1.5", "Config.CheckSeconds = 10" }), diag = true, widgets = true, prepare = function(_, world) world.frozen.FireBoltProjectileDefinition = true end })
    ue, w = c.ue, c.world
    c.settle()
    check(w.damage("FireBoltProjectileDefinition", 0) == 35 and w.damage("FireBoltProjectileDefinition", 6) == 65 and w.damage("IceBoltProjectileDefinition", 0) == 30,
        "an object whose numbers do not take a write stays as the game has it; the others are changed")
    check(printedCount(ue, "[G1R_Magic] a number could not be changed: FireBoltProjectileDefinition base1 (the value did not stay); numbers of this kind stay as the game has them\n") == 1
        and printedCount(ue, "a number could not be changed: FireBoltProjectileDefinition step1.1 (the value did not stay)") == 1 and printedCount(ue, "a number could not be changed") == 2,
        "noticed by reading back; said once for each way of writing (the damage map, the steps)")
    check(c.S.count == 61 and c.S.failed == 4 and has(status(c), "|writes that did not stay: 4"), "the status counts the four writes")
    check(has(c.fake.events[#c.fake.events], "look 1 (start): 22 object(s), 61 value(s) changed, 0 put back: 61 value(s) in 21 object(s) of the game hold the module's numbers now; 4 failed, 0 reset by the game"),
        "so does the diagnostics line of the look: " .. tostring(c.fake.events[#c.fake.events]))
    check(firstNote(c, "magic.write.map") == "failed" and c.fake.detail("magic.write.map") == nil and c.fake.value("magic.write.map") == "ok" and c.fake.count["magic.write.map"] == 2,
        "the diagnostics note the failure (first) and that the same way works on other objects (then)")
    local writes = w.writes
    c.ticks(200)
    check(w.writes == writes, "the later looks do not try the same write again")
    T.menuSet(c, "Combat", "Damage of every spell", 2)
    c.ticks(1)
    check(w.writes == writes + 61 + 4 and w.damage("FireBoltProjectileDefinition", 0) == 35, "a new value is tried once")
    check(c.ui.note() == "Magic: 61 value(s) changed, 4 could not be set", "the note on screen says how many could not be set")
    w.frozen.FireBoltProjectileDefinition = nil
    T.menuSet(c, "Combat", "Damage of every spell", 3)
    c.ticks(1)
    check(w.damage("FireBoltProjectileDefinition", 0) == 105 and c.S.failed == 0 and c.S.count == 65 and not has(status(c), "did not stay"), "when the write works, the place is the module's like any other")
    stop(c)
    c = start("frozen-only", { widgets = true, prepare = function(_, world) world.frozen.FireBoltProjectileDefinition = true end })
    T.menuSet(c, "Combat", "Fire bolt: damage", 2)
    c.settle()
    check(c.ui.note() == "Magic: nothing is changed, 4 could not be set" and c.S.count == 0 and c.world.untouched(), "a setting none of whose writes stays: the note says that nothing is changed")
    stop(c)
    -- a write that raises
    c = start("raising", { config = cfg({ "Config.Damage = 1.5", "Config.ManaCost = 2.0", "Config.Stagger = 2.0", "Config.IceBlockFreeze = true" }), diag = true, prepare = function(_, world)
        world.raising["FireBoltProjectileDefinition.m_DamageBase"] = true
        world.raising["FireBoltProjectileDefinition.m_Damage"] = true
        world.raising["FireBoltProjectileDefinition.m_SuperArmorDamageBase"] = true
        world.raising["ProjectileSpellConfig_FireBolt.CastManaCost"] = true
        world.raising["GE_IceBlock_Freeze_Damage.ForceOverflowElementalEffectStack"] = true
    end })
    ue, w = c.ue, c.world
    c.settle()
    check(printedCount(ue, "a number could not be changed: FireBoltProjectileDefinition base1 (the write raised an error)") == 1
        and printedCount(ue, "a number could not be changed: FireBoltProjectileDefinition step1.1 (the write raised an error)") == 1
        and printedCount(ue, "a number could not be changed: FireBoltProjectileDefinition stagger (the write raised an error)") == 1
        and printedCount(ue, "a number could not be changed: ProjectileSpellConfig_FireBolt mana1 (the write raised an error)") == 1
        and printedCount(ue, "a number could not be changed: GE_IceBlock_Freeze_Damage force1 (the write raised an error)") == 1 and printedCount(ue, "a number could not be changed") == 5,
        "writes that raise, one of each of the five ways of writing: each said once, with the reason")
    check(w.damage("FireBoltProjectileDefinition", 0) == 35 and w.mana("ProjectileSpellConfig_FireBolt") == 1 and w.held("ProjectileSpellConfig_FireBolt") == 2 and not w.freezes("GE_IceBlock_Freeze_Damage", 1)
        and w.damage("IceBoltProjectileDefinition", 0) == 30 and w.stagger("WindFistDefinition") == 400 and #ue.errors == 0 and c.S.failed == 7,
        "those places stay the game's (seven: base, three steps, stagger, mana, the freeze flag); the walk goes on behind a write that raised (the bolt's mana per second is set); no error reaches UE4SS")
    check(firstNote(c, "magic.write.flags") == "failed" and c.fake.detail("magic.write.flags") == "GE_IceBlock_Freeze_Damage force1: the write raised an error"
        and firstNote(c, "magic.write.levels") == "failed" and c.fake.value("magic.write.levels") == "ok" and firstNote(c, "magic.write.plain") == "failed", "noted per way of writing")
    stop(c)
    -- a write that lands as another value than asked for
    c = start("twisted", { config = cfg({ "Config.CircleCosts = true", "Config.CircleCost2 = 12", "Config.CheckSeconds = 10" }), prepare = function(_, world)
        world.twist["GE_Skill_Mage_Circle_2.SPCost"] = function(v) return math.floor(v / 5) * 5 end          -- the game keeps prices in fives
    end })
    ue, w = c.ue, c.world
    c.settle()
    check(w.price(2) == 10 and c.S.failed == 1 and c.S.count == 1 and has(table.concat(c.hook.values(), "|"), "GE_Skill_Mage_Circle_2: cost 15 -> 10"),
        "a write that lands as another number (12 becomes 10): counted as not stayed, and the 10 is known to be the module's doing")
    writes = w.writes
    c.ticks(80)
    check(w.writes == writes and w.price(2) == 10, "it is not written again and again")
    T.menuSet(c, "Combat", "Own prices for the magic circles", false)
    c.ticks(1)
    check(w.price(2) == 15 and w.untouched() and c.S.count == 0 and c.S.failed == 0, "and put back to the game's 15 when the setting goes")
    stop(c)

    -- an object that is gone, or whose wrapper names another object now (FACTS U5)
    c = start("gone", { config = cfg({ "Config.Damage = 1.5", "Config.CheckSeconds = 10" }), diag = true })
    ue, w = c.ue, c.world
    c.settle()
    w.objects.FireRainDefinition.__valid = false
    c.ticks(40)
    check(printedCount(ue, "[G1R_Magic] no longer there: FireRainDefinition - they cannot be searched again in this run; their numbers are the game's affair now\n") == 1
        and c.fake.value("magic.objects") == "1 not found" and c.fake.detail("magic.objects") == "; gone: FireRainDefinition" and has(status(c), "|no longer there: FireRainDefinition")
        and c.S.count == 64, "an object that is gone: said, noted, in the status; its place no longer counts")
    check(printed(ue, "not there in this game") == nil and c.fake.value("magic.properties") == "all there" and c.fake.count["magic.original.FireRainDefinition"] == 1,
        "nothing is read from it any more (no property is reported missing)")
    w.objects.StormFistDefinition.__full = "StaticMeshActor /Game/Maps/World.World:PersistentLevel.StaticMeshActor_77"
    w.data.definitions.StormFistDefinition.base[1].value = 5
    local reads = w.read["StormFistDefinition.m_DamageBase"]
    c.ticks(40)
    check(printedCount(ue, "[G1R_Magic] no longer there: StormFistDefinition - they cannot be searched again in this run; their numbers are the game's affair now\n") == 1
        and printedCount(ue, "no longer there") == 2, "an object whose wrapper now names another object: a line of its own")
    check(w.data.definitions.StormFistDefinition.base[1].value == 5 and w.read["StormFistDefinition.m_DamageBase"] == reads, "the stranger behind the old wrapper is not read and not written")
    check(c.S.count == 65 - 3 and has(status(c), "|no longer there: FireRainDefinition, StormFistDefinition") and c.fake.value("magic.objects") == "2 not found"
        and c.fake.detail("magic.objects") == "; gone: FireRainDefinition, StormFistDefinition", "status and diagnostics name both; their places no longer count")
    T.menuSet(c, "Combat", "Damage of every spell", 2)
    c.ticks(1)
    c.ticks(80)
    check(lookups(c, "FireRainDefinition") == 1 and lookups(c, "StormFistDefinition") == 1 and w.damage("FireBoltProjectileDefinition", 0) == 70 and printedCount(ue, "no longer there") == 2,
        "they are never searched again; everything else goes on")
    stop(c)

    -- an error inside the module's own loop does not reach UE4SS, and is said once
    c = start("tick-error", { config = cfg({ "Config.Damage = 1.5" }) })
    c.expectErrors = true        -- this case provokes an error inside the loop
    c.settle()
    c.S.queue, c.S.at = { {} }, 1
    c.ticks(5)
    check(#c.ue.errors == 0 and printedCount(c.ue, "[G1R_Magic] update error: ") == 1, "an error in the loop: caught, one line")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("14. what it costs: searches, reads and writes are counted; nothing happens while a map loads")
do
    -- the player's configuration, from the start of the game through a map change and two minutes of play
    local c = start("cost", { config = PLAYER })
    local ue, w = c.ue, c.world
    local worst, looks = 0, 0
    repeat
        local before = #ue.lookups
        c.ticks(1)
        looks = looks + 1
        worst = math.max(worst, #ue.lookups - before)
    until c.S.queue == nil
    check(looks == 9 and worst == 4 and #ue.lookups == 35, "the player's configuration: 35 searches, never more than four in one look (SearchesPerLook), nine looks")
    check(w.reads == 662 and w.walks == 186 and w.writes == 73 and w.keys == 0 and w.indexed == 0 and w.crossed == 0,
        ("the first look at the 35 objects: %d properties read (before and after writing), %d lists walked, %d numbers written"):format(w.reads, w.walks, w.writes))
    local reads, walks, writes = w.reads, w.walks, w.writes
    c.ticks(239)
    check(w.reads == reads and w.walks == walks and w.writes == writes, "the next 239 looks (a minute less one) do nothing in the game")
    c.ticks(1)
    check(w.reads == reads + 222 and w.walks == walks + 62 and w.writes == writes,
        ("the look after a minute (CheckSeconds): %d properties read, %d lists walked, nothing written"):format(w.reads - reads, w.walks - walks))
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    reads, walks = w.reads, w.walks
    c.ticks(8)
    check(w.reads == reads + 222 and w.walks == walks + 62 and w.writes == writes, "the look after a map change costs the same")
    T.menuSet(c, "Combat", "Fire ball: damage", 1.5)
    reads, writes = w.reads, w.writes
    c.ticks(1)
    check(w.writes == writes + 12 and w.reads == reads + 282 and c.searches() == 35,
        "one changed setting: the 33 objects are read (222), the twelve numbers of the three fire balls are written and read back (60 more); no search")
    local seen, twice = {}, 0
    for _, path in ipairs(ue.lookups) do
        if seen[path] then twice = twice + 1 end
        seen[path] = true
    end
    check(twice == 0 and (ue.calls.FindFirstOf or 0) == 0 and (ue.calls.RegisterHook or 0) == 0 and (ue.calls.NotifyOnNewObject or 0) == 0 and #ue.loops == 2,
        "in the whole session: no path searched twice, no hook, no notification; one loop besides the loader's")
    check(T.searches(c) - c.searches() == 2 and allOf(ue) == 1, "the note on screen is the kit's: its two paths and the player controller are searched once, when the first note is due")
    local names, banned = {}, 0
    for key in pairs(w.read) do
        local property = key:match("%.([%w_]+)$")
        names[property] = true
        if property == "m_Capacity" or property == "m_InventoryType" or property == "m_InteractiveObjectDefinition" or property == "m_ItemDefinition" then banned = banned + 1 end
    end
    local list = {}
    for name in pairs(names) do list[#list + 1] = name end
    table.sort(list)
    check(banned == 0 and table.concat(list, " ") == "SPCost m_AreaRange m_DamageBase m_DamageMagicCircleProgression m_ElementalEffectStacks m_Speed m_SpellLevels m_SuperArmorDamageBase",
        "the properties read from the objects in this session (none of the four whose read makes UE4SS write a debug line, rule 2): " .. table.concat(list, " "))
    stop(c)
    c = start("cost-silent", { config = PLAYER:gsub("return Config", "Config.ShowMessage = false\nreturn Config") })
    c.settle()
    T.menuSet(c, "Combat", "Fire ball: damage", 1.5)
    c.ticks(300)
    check(#c.ue.lookups == 35 and allOf(c.ue) == 0 and c.world.damage("FireBallProjectileDefinition_Lvl1", 0) == 135, "without the note (ShowMessage = false) the 35 searches are all there is")
    stop(c)

    -- while a map loads
    c = start("loading", { config = cfg({ "Config.Damage = 1.5" }) })
    ue, w = c.ue, c.world
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    c.ticks(40)
    check(T.searches(c) == 0 and w.reads == 0, "the mod is loaded while a map loads: nothing is searched or read before the load is over")
    check(#ue.lookups == #c.kit.paths, "(but for the kit's own paths, which it looks up in the hook before the first map load)")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(2)
    check(T.searches(c) == 8 and w.damage("FireBoltProjectileDefinition", 0) == 52.5 and c.S.queue ~= nil, "then the look starts (two looks: eight searches)")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    reads = w.reads
    c.ticks(12)
    check(T.searches(c) == 8 and w.reads == reads, "another load while the look is under way: it waits")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.settle()
    check(T.searches(c) == 22 and #ue.lookups == 22 + #c.kit.paths and w.damage("BreathOfDeathDefinition", 0) == 225 and c.S.count == 65,
        "and goes on afterwards: all 22 definitions, each searched once (the second map load searched nothing)")
    stop(c)

    -- the hidden settings
    c = start("one-search", { config = cfg({ "Config.Damage = 1.5", "Config.SearchesPerLook = 1" }) })
    check(c.settle() == 22 and #c.ue.lookups == 22, "SearchesPerLook = 1: one search a look, 22 looks")
    stop(c)
    c = start("many-searches", { config = cfg({ "Config.ManaCost = 1.5", "Config.SearchesPerLook = 32" }) })
    check(c.settle() == 2 and #c.ue.lookups == 52, "SearchesPerLook = 32: the 52 configs in two looks")
    stop(c)
    c = start("no-searches", { config = cfg({ "Config.Damage = 1.5", "Config.SearchesPerLook = 0" }) })
    check(c.settle() == 22 and c.world.damage("BreathOfDeathDefinition", 0) == 225 and printed(c.ue, "SearchesPerLook = 0 is not usable; 1 is used") ~= nil,
        "SearchesPerLook = 0 would never get anywhere: 1 is used, and said")
    stop(c)
    c = start("interval", { config = cfg({ "Config.LookMilliseconds = 100.7" }) })
    check(c.ue.loops[2].ms == 101 and math.type(c.ue.loops[2].ms) == "integer", "LookMilliseconds is handed to UE4SS as a whole number")
    stop(c)
    c = start("interval-low", { config = cfg({ "Config.LookMilliseconds = 1" }) })
    check(c.ue.loops[2].ms == 50, "and not below 50")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("15. console command, status, the button of the in-game menu; the diagnostics; nothing leaks; the files")
do
    local known = {}
    local probe = T.Mock.new()
    probe:install()                 -- what the mock itself puts into _G does not count
    for k in pairs(_G) do known[k] = true end
    probe:uninstall()
    local given = { MAGIC_TEST = true, ModRef = true, G1R_KIT = true, G1R_SETTINGS = true, G1R_DIAG = true, Key = true, ModifierKey = true, StaticConstructObject = true }

    local c = start("console", { config = cfg({ "Config.Damage = 1.5", "Config.IceBlockFreeze = true" }), widgets = true, diag = true })
    local ue, w = c.ue, c.world
    local before = #ue.printed
    check(ue:fireConsole("magic") == true and #ue.errors == 0, "magic: handled (a boolean is returned)")
    check(#ue.printed == before + 2 and ue.printed[before + 1] == "[G1R_Magic] v1.0.1 | damage x1.5, 1 ice spell(s) freeze with every hit\n"
        and ue.printed[before + 2] == "[G1R_Magic] nothing is changed right now\n", "before the first look: version, what is set, nothing changed yet")
    check(#ue.device.lines == 2 and ue.device.lines[1] == "[G1R_Magic] v1.0.1 | damage x1.5, 1 ice spell(s) freeze with every hit", "the same lines go to the console window")
    check(w.reads == 0 and #ue.lookups == 0, "the status does not look at the game")
    local early = c.fake.dump[1]()
    check(early.changed_values == 0 and early.changed_objects == 0 and early.failed_writes == 0 and early.looks == 0 and early.searches == 0 and early.at_work == false and next(early.objects) == nil,
        "nor does the dump: before the first look it says that nothing is changed, searched or under way")
    local same = c.hook.same
    check(same(0, 0.000001) and not same(0, 0.0000011) and same(1000000, 1000000.3) and not same(1000000, 1000000.5) and same(52.5, f32(52.5)) and same(19.995, f32(19.995))
        and same(true, true) and not same(true, false) and not same(nil, 1) and same(nil, nil) and not same(0, false),
        "(two numbers count as the same within a millionth, or within 0.0000004 of their size: what single precision keeps of a number)")
    c.settle()
    before = #ue.printed
    check(ue:fireConsole("g1r_magic") == true and #ue.printed == before + 2
        and ue.printed[before + 2] == "[G1R_Magic] changed right now: 66 value(s) in 23 object(s) of the game (damage 65, freeze 1)\n", "g1r_magic works too: what is changed, by kind")
    before = #ue.printed
    check(ue:fireConsole("magic values") == true and #ue.printed == before + 2 + 23
        and ue.printed[before + 3] == "[G1R_Magic] FireBoltProjectileDefinition: base1 35 -> 52.5, step1.1 40 -> 60, step1.2 50 -> 75, step1.3 65 -> 97.5\n"
        and printed(ue, "[G1R_Magic] GE_IceBlock_Freeze_Damage: force1 false -> true\n") ~= nil
        and printed(ue, "[G1R_Magic] WindFistDefinition: base1 20 -> 30, step1.1 30 -> 45, step1.2 40 -> 60, step1.3 50 -> 75, step1.4 70 -> 105\n") ~= nil,
        "magic values: the status and one line for each of the 23 objects - place, the game's number -> the module's")
    before = #ue.printed
    check(ue:fireConsole("magic something") == true and #ue.printed == before + 2, "an unknown word shows the status")
    before = #ue.printed
    check(ue:fireConsole("magic reload") == true and ue.printed[before + 1] == "[G1R_Magic] settings read: damage x1.5, 1 ice spell(s) freeze with every hit\n" and #ue.printed == before + 1,
        "magic reload reads the file also when it has not changed")
    T.write(c.path, cfg({ "Config.Damage = 2.0" }))
    before = #ue.printed
    ue:fireConsole("magic RELOAD")
    check(ue.printed[before + 1] == "[G1R_Magic] settings changed (config.lua): damage x2\n" and ue.printed[before + 2] == "[G1R_Magic] settings read: damage x2\n",
        "with a changed file: read at once (not after the usual five seconds)")
    c.ticks(1)
    check(w.damage("FireBoltProjectileDefinition", 0) == 70 and not w.freezes("GE_IceBlock_Freeze_Damage", 1) and c.S.count == 65, "and in the game at the next look: 35 x 2, the ice block as the game has it")
    T.write(c.path, "local Config = {}\nConfig.Damage = \nreturn Config\n")
    before = #ue.printed
    ue:fireConsole("magic reload")
    check(has(ue.printed[#ue.printed], "[G1R_Magic] settings not read: ") and c.hook.settings.values.Damage == 2, "a file with an error: said, the settings stay")
    T.write(c.path, cfg({ "Config.Damage = 2.0" }))
    check(c.hook.console(nil, nil, nil) == true and c.hook.console("magic values", nil, nil) == true and c.hook.console("magic", { 2, {} }, {}) == true
        and c.hook.console("magic", { "values" }, { Log = function() error("no console window (test)") end }) == true and #ue.errors == 0,
        "called with nothing, with the command line only, with parameters of another kind, with a console window that raises: handled")
    before = #ue.printed
    c.hook.console("magic values", nil, nil)
    check(#ue.printed == before + 2 + 22, "with the command line only, the words are taken from it")

    -- the button of the in-game menu (the console is switched off on many installations)
    local item = T.menuItem(c, "Combat", "Write the changes to the log")
    check(item ~= nil and item.kind == "action" and item.section == "Magic: on screen, log", "the menu has a button for the status")
    T.menuSet(c, "Combat", "Write the changes to the log", true)
    before = #ue.printed
    local reads = w.reads
    c.ticks(1)
    check(#ue.printed == before + 2 + 22 and ue.printed[before + 1] == "[G1R_Magic] v1.0.1 | damage x2\n"
        and ue.printed[before + 3] == "[G1R_Magic] FireBoltProjectileDefinition: base1 35 -> 70, step1.1 40 -> 80, step1.2 50 -> 100, step1.3 65 -> 130\n",
        "pressed: the status and the list of changed values go to UE4SS.log")
    check(c.ui.note() == "Magic: 65 value(s) changed in 22 object(s); the list is in UE4SS.log" and w.reads == reads, "a note on screen says where to look; the game is not read for it")
    T.menuSet(c, "Combat", "Note when changes reached the game", false)
    T.menuSet(c, "Combat", "Write the changes to the log", true)
    before = #ue.printed
    c.ticks(1)
    check(#ue.printed == before + 1 + 2 + 22 and c.ui.note() == nil, "with ShowMessage off the lines are written without a note")
    check(c.hook.settings.onAction("SomethingElse") == nil and #ue.printed == before + 1 + 2 + 22, "another button is not the module's")

    -- the diagnostics of that session
    local sequence = c.fake.sequence()
    check(sequence[1] == "magic.inherited=none" and sequence[2] == "magic.original.FireBoltProjectileDefinition=base 35, steps 40 50 65, speed 4000, stagger 30"
        and sequence[3] == "magic.steps=as expected" and sequence[4] == "magic.write.map=ok" and sequence[5] == "magic.write.steps=ok",
        "notes: what an earlier run left, then for the first object its own numbers, its shape, the two ways of writing damage")
    local originals, others = 0, {}
    for _, n in ipairs(c.fake.notes) do
        if n.key:sub(1, 15) == "magic.original." then originals = originals + 1 else others[#others + 1] = n.key .. "=" .. tostring(n.value) end
    end
    check(originals == 23 and table.concat(others, " ") == "magic.inherited=none magic.steps=as expected magic.write.map=ok magic.write.steps=ok magic.ledger=kept magic.write.flags=ok "
        .. "magic.objects=all found magic.properties=all there magic.others=none magic.applied=66 value(s) in 23 object(s) magic.applied=65 value(s) in 22 object(s)",
        "one note with the game's own numbers for each of the 23 objects; every other note once, and again only when its value changes: " .. table.concat(others, " "))
    check(c.fake.versions[1] == "1.0.1" and table.concat(c.fake.crumbs, " ; ") == "first look at a definition: FireBoltProjectileDefinition ; first write to a definition: FireBoltProjectileDefinition ; "
        .. "first look at a hit effect: GE_IceBlock_Freeze_Damage ; first write to a hit effect: GE_IceBlock_Freeze_Damage",
        "the version; the first look at and the first write to an object of each kind are announced before they happen")
    check(c.fake.events[1] == "first look at a definition done: FireBoltProjectileDefinition = base 35, steps 40 50 65, speed 4000, stagger 30"
        and c.fake.events[2] == "first write to a definition done: FireBoltProjectileDefinition" and c.fake.events[3] == "first look at a hit effect done: GE_IceBlock_Freeze_Damage = false"
        and c.fake.events[4] == "first write to a hit effect done: GE_IceBlock_Freeze_Damage"
        and c.fake.events[5] == "look 1 (start): 23 object(s), 66 value(s) changed, 0 put back: 66 value(s) in 23 object(s) of the game hold the module's numbers now; 0 failed, 0 reset by the game"
        and c.fake.events[6] == "look 2 (settings): 23 object(s), 65 value(s) changed, 1 put back: 65 value(s) in 22 object(s) of the game hold the module's numbers now; 0 failed, 0 reset by the game"
        and #c.fake.events == 6, "each of them is followed by a line that it is done; every look that had a reason is one line")
    local dump = c.fake.dump[1] and c.fake.dump[1]() or nil
    local statusLines = c.fake.status[1] and c.fake.status[1]() or {}
    reads = w.reads
    local lookups = #ue.lookups
    for _ = 1, 20 do
        c.fake.dump[1]()
        c.fake.status[1]()
    end
    check(w.reads == reads and #ue.lookups == lookups, "the status and the dump are built from what the module holds: no call into the game")
    local Fake = dofile(HERE .. "../markers/diag_fake.lua")
    local plain, where = Fake.plain(dump)
    check(plain and (Fake.roundTrip(dump)) and dump.version == "1.0.1" and dump.enabled == true and dump.summary == "damage x2" and dump.changed_values == 65 and dump.changed_objects == 22
        and dump.by_kind.damage == 65 and dump.failed_writes == 0 and dump.looks == 2 and dump.searches == 23 and dump.at_work == false and dump.whole_mana == true
        and #dump.not_found == 0 and #dump.gone == 0 and #dump.not_there == 0 and #dump.changed_by_others == 0 and #dump.other_shape == 0,
        "the dump is plain data: what the module holds (" .. tostring(where) .. ")")
    local bolt, block, heal = dump.objects.FireBoltProjectileDefinition, dump.objects.GE_IceBlock_Freeze_Damage, dump.objects.HealSpellConfig
    check(bolt.kind == "definition" and bolt.state == "found" and bolt.shape == "1/3" and bolt.slots.base1.orig == 35 and bolt.slots.base1.ours == 70 and bolt.slots.speed.orig == 4000
        and bolt.slots.speed.ours == nil and block.kind == "effect" and block.slots.force1.orig == false and block.slots.force1.ours == nil and heal == nil,
        "for every object that was searched: its kind, its shape, the game's number and the module's for each place; nothing for objects never searched")
    check(#statusLines == 2 and statusLines[1] == "v1.0.1 | damage x2" and statusLines[2] == "changed right now: 65 value(s) in 22 object(s) of the game (damage 65)", "the status function gives the status lines")
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

    -- without the diagnostics nothing of them runs
    c = start("no-diag", { config = cfg({ "Config.Damage = 1.5", "Config.IceBlockFreeze = true" }) })
    c.settle()
    check(c.ok and #c.ue.errors == 0 and c.S.count == 66 and next(c.S.crumbed) == nil, "without G1R_DIAG (diagnostics off): the same result, nothing is announced")
    stop(c)

    -- the settings file
    c = start("badstart", { config = "this is not lua\n" })
    c.ticks(40)
    check(c.ok and printed(c.ue, "config.lua has an error (") ~= nil and c.hook.settings.values.Damage == 1.0 and #c.ue.lookups == 0 and c.world.untouched(),
        "a broken file at the start: said, default settings - the game is not touched")
    check(T.read(c.path) == "this is not lua\n", "the broken file is left for its owner to repair")
    stop(c)
    c = start("nofile", { config = false })
    check(c.ok and printed(c.ue, "config.lua was not there: written with the default settings") ~= nil and T.read(c.path) == shipped, "no file at the start: the default file is written")
    stop(c)
    c = start("bom", { config = "\239\187\191" .. cfg({ "Config.Damage = 1.5" }) })
    check(c.hook.settings.values.Damage == 1.5, "a byte order mark at the start of the file is skipped")
    stop(c)
    c = start("noschema", { files = { ["Scripts/schema.lua"] = false } })
    check(c.ok and printed(c.ue, "[G1R_Magic] the settings could not be set up (schema.lua could not be read") ~= nil and #c.ue.loops == 1 and c.ue.console.magic == nil,
        "without schema.lua the module says so and does not start")
    stop(c)
    c = start("range", { config = cfg({ "Config.Damage = 99", "Config.ManaCost = -3", 'Config.CastTime = "fast"', "Config.SchoolFire = 0", "Config.FireBoltSteps = 1", "Config.CircleCost1 = 12.6",
        "Config.CircleCosts = true", "Config.WholeMana = false" }) })
    local v = c.hook.settings.values
    check(v.Damage == 10 and v.ManaCost == 0 and v.CastTime == 1 and v.SchoolFire == 0.1 and v.FireBoltSteps == false and v.CircleCost1 == 13
        and printed(c.ue, "config.lua: Damage = 99 is not usable; 10.0 is used") ~= nil and printed(c.ue, "config.lua: CastTime = fast is not usable; 1.0 is used") ~= nil,
        "values out of range or of the wrong kind: the nearest usable value or the default is used, and said (10, 0, 1.0, 0.1, false, 13)")
    c.settle()
    check(near(c.world.damage("FireBoltProjectileDefinition", 0), 35) and c.world.damage("IceBoltProjectileDefinition", 0) == 200 and c.world.mana("StormOfFireSpellConfig") == 0
        and near(c.world.time("StormOfFireSpellConfig"), 0.5) and c.world.price(1) == 13, "and they do what they say: damage x10, fire x0.1 on top, mana 0, the first circle for 13")
    stop(c)
    c = start("comma", { config = cfg({ "Config.Damage = 1,5" }) })
    check(c.hook.settings.values.Damage == 1 and printed(c.ue, "a number seems to be written with a comma") ~= nil and #c.ue.lookups == 0, "1,5 is read as 1 by Lua: said, nothing is changed")
    stop(c)

    -- the shipped files
    local schema = dofile(MOD .. "modules/magic/Scripts/schema.lua")
    local chunk = load(shipped, "=config.lua", "t", {})
    local values = chunk and chunk() or {}
    local count, hidden, longest = 0, 0, 0
    for _ in pairs(values) do count = count + 1 end
    for _, key in ipairs({ "SearchesPerLook", "CheckSeconds", "LookMilliseconds", "Status" }) do if values[key] ~= nil then hidden = hidden + 1 end end
    for line in shipped:gmatch("[^\n]*") do longest = math.max(longest, #line) end
    check(count == 82 and hidden == 0 and not shipped:find("\r", 1, true) and not shipped:find("[^\n\32-\126]") and longest <= 110,
        ("the shipped config.lua: 82 settings, none of the hidden ones, plain ASCII, LF line ends, no line longer than 110 characters (%d settings, longest line %d)"):format(count, longest))
    local probe2 = start("default-text", {})
    check(probe2.settings.defaultText(schema) == shipped, "the shipped config.lua is exactly what the schema generates (lua5.4 dev/tools/gen_config.lua magic)")
    local page = T.menuPage(probe2, "Combat")
    local orders, ok = {}, schema.Page == "Combat" and schema.PageOrder == 10 and schema.Module == "magic"
    for _, group in ipairs(schema.Groups) do
        orders[#orders + 1] = group.Order
        if group.Order < 30 or group.Order > 59 then ok = false end
        if group.Title ~= "Advanced" and group.Title:sub(1, 7) ~= "Magic: " then ok = false end
    end
    check(ok and #page.items == 83 and table.concat(orders, " ") == "30 34 38 42 46 50 54 58 59",
        "the schema: page Combat (PageOrder 10), groups in the range 30-59, every shown title starts with \"Magic: \"; 82 settings and one button in the menu")
    stop(probe2)
end

-- ---------------------------------------------------------------------------
section("16. through the megamod loader, with the real diagnostics")
do
    local TMP = T.TMP
    local root = TMP .. "/mega/G1R_MegaMod"
    T.sh("rm -rf " .. T.q(TMP .. "/mega") .. " && mkdir -p " .. T.q(root) .. " && cp -r " .. T.q(MOD .. "Scripts") .. " " .. T.q(root .. "/") .. " && mkdir -p " .. T.q(root .. "/modules")
        .. " && cp -r " .. T.q(MOD .. "modules/magic") .. " " .. T.q(root .. "/modules/"))
    -- only this module: the list of modules is cut down to it (the line the loader needs for it)
    T.write(root .. "/Scripts/core/modules.lua", 'return { { name = "magic", switch = "Magic", separate = { "G1R_MageBalance" } } }\n')
    T.write(root .. "/modules/magic/Scripts/config.lua", PLAYER)

    local function boot(prepare)
        local ue = T.Mock.new()
        ue:install()
        local ui = T.widgets(ue)
        local world = build(ue, T.newWorld(ue))
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
    check(c.ok and has(last(c), "loaded: magic ok | diagnostics normal"), "the loader loads the module: " .. last(c))
    check(rawget(_G, "MAGIC_TEST") == nil and rawget(_G, "G1R_KIT") == nil and rawget(_G, "G1R_SETTINGS") == nil, "the test hook stays inert; the kit and the settings service are no globals")
    c.looks(9)
    check(w.damage("FireBoltProjectileDefinition", 0) == 30 and w.damage("WindFistDefinition", 6) == 140 and w.mana("ProjectileSpellConfig_FireBall", 2) == 2.5 and w.speed("BallLightningDefinition_Lvl2") == 800
        and w.freezes("GE_IceBlock_Freeze_Damage", 1) and w.price(6) == 25 and #ue.errors == 0, "the player's configuration reaches the game as without the loader")
    check(ue:fireConsole("g1r diag") == true, "g1r diag handled")
    local report = T.read(c.dir .. "/report-latest.txt") or ""
    check(has(report, "magic: loaded, version 1.0.1")
        and has(report, "[magic] v1.0.1 | 24 setting(s) for single spells, 1 ice spell(s) freeze with every hit, own prices for the magic circles")
        and has(report, "[magic] changed right now: 73 value(s) in 33 object(s) of the game (damage 39, mana 14, casting time 9, flight speed 4, stagger 1, freeze 1, circle price 5)"),
        "report: the module's version and its status lines")
    check(has(report, "magic.objects = all found [") and has(report, "magic.properties = all there [") and has(report, "magic.others = none [") and has(report, "magic.inherited = none [")
        and has(report, "magic.ledger = kept [") and has(report, "magic.steps = as expected (FireBoltProjectileDefinition 1/3) [") and has(report, "magic.applied = 73 value(s) in 33 object(s) [")
        and has(report, "magic.write.map = ok [") and has(report, "magic.write.steps = ok [") and has(report, "magic.write.levels = ok [") and has(report, "magic.write.plain = ok [")
        and has(report, "magic.write.flags = ok ["), "report: the notes - everything found and there, the five ways of writing work")
    check(has(report, "magic.original.FireBoltProjectileDefinition = base 35, steps 40 50 65, speed 4000, stagger 30 [")
        and has(report, "magic.original.ProjectileSpellConfig_FireBall = levels 1 0.4 0 / 2 0.6 0 / 2 0.8 2 [") and has(report, "magic.original.StormFistSpellConfig = levels 10 0.5 0, range 700 [")
        and has(report, "magic.original.GE_IceBlock_Freeze_Damage = false [") and has(report, "magic.original.GE_Skill_Mage_Circle_6 = 40 ["),
        "report: the game's own numbers of every object the module has under its hand, as it found them")
    check(has(report, "[kit] lookups: 35 calls, 35 first-time, 0 not found, 0 repeated after not found") and has(report, "[magic] callbacks LoopInGameThreadWithDelay: 9 calls, 0 errors")
        and has(report, "[magic] registered RegisterConsoleCommandHandler: 2 ok, 0 failed") and has(report, "count: 0 (0 distinct)"),
        "report: the 35 searches (none repeated), the module's loop and its two console commands are counted; no error")
    local log = newest(c, "session-")
    check(has(log, "[magic] [G1R_Magic] v1.0.1 loaded: 24 setting(s) for single spells") and has(log, "[magic] look 1 (start): 35 object(s), 73 value(s) changed, 0 put back"),
        "session log: the load line and the first look")
    local at = log:find("[magic] > first write to a definition: FireBoltProjectileDefinition", 1, true)
    check(at ~= nil and log:find("[magic] first write to a definition done: FireBoltProjectileDefinition", at, true) ~= nil
        and has(log, "[kit] > lookup /Script/Angelscript.Default__FireBoltProjectileDefinition") and has(log, "[magic] > first look at a skill effect: GE_Skill_Mage_Circle_Amateur")
        and not has(log, "ERROR in "), "session log: a search, the first look at and the first write to each kind of object are announced before they run; no error")
    check(ue:fireConsole("g1r dump") == true, "g1r dump handled")
    local okDump, dump = pcall(load(newest(c, "dump-"), "=dump", "t", {}))
    check(okDump and type(dump) == "table" and type(dump.magic) == "table" and dump.magic.changed_values == 73 and dump.magic.changed_objects == 33 and dump.magic.searches == 35
        and dump.magic.objects.FireBoltProjectileDefinition.slots.base1.ours == 30 and dump.magic.objects.GE_Skill_Mage_Circle_6.slots.cost.orig == 40 and dump._meta.refusedCount == 0,
        "dump: what the module holds, nothing refused")
    check(ue:fireConsole("g1r") == true and printed(ue, "[G1R_MegaMod] magic: loaded, version 1.0.1, 0 error(s), 47 note(s)") ~= nil, "g1r lists the module with its notes")
    check(ue:fireConsole("magic") == true and printed(ue, "[G1R_Magic] changed right now: 73 value(s) in 33 object(s)") ~= nil, "the module's own console command works through the loader")
    -- settings through the loader: the in-game menu
    local page = c.mods.store["SMM:schema:G1R Combat"]
    check(type(page) == "string" and has(page, "Magic: all spells") and c.mods.store["SMM:index"] == "G1R Combat", "the page G1R Combat is registered with the in-game menu")
    c.mods.store["SMM:cmd:G1R Combat"] = "1\31b0"
    c.looks(2)          -- the loader's loop takes the edit after the module's own look: it is in the game one look later
    check(printed(ue, "[G1R_Magic] settings changed (in-game menu): switched off in the settings") ~= nil and w.untouched()
        and has(T.read(root .. "/modules/magic/Scripts/config.lua"), "Config.Enabled = false\n"),
        "the first item of the page (the module's switch) set to off in the menu: the game's own numbers are back, config.lua says Enabled = false")
    check(c.ui.note() == "Magic: the game's own values are back", "the note on screen is shown through the loader's kit")
    shutdown(c)

    -- the other author's mod is installed and enabled next to the megamod: the module is not loaded
    T.write(root .. "/modules/magic/Scripts/config.lua", PLAYER)
    T.sh("mkdir -p " .. T.q(TMP .. "/mega/G1R_MageBalance/Scripts"))
    T.write(TMP .. "/mega/G1R_MageBalance/Scripts/main.lua", "-- another mod\n")
    T.write(TMP .. "/mega/G1R_MageBalance/enabled.txt", "")
    c = boot()
    check(c.ok and has(last(c), "magic left to the separate mod G1R_MageBalance")
        and printed(c.ue, "module magic not loaded: the separate mod G1R_MageBalance is installed and enabled") ~= nil,
        "G1R_MageBalance enabled next to the megamod: " .. last(c))
    c.looks(12)
    check(c.world.untouched() and c.world.reads == 0 and #c.ue.lookups == 0 and c.mods.store["SMM:index"] == nil and c.ue.console.magic == nil,
        "the game's spell data is neither read nor changed, no page is registered with the in-game menu, no console command")
    shutdown(c)
    os.remove(TMP .. "/mega/G1R_MageBalance/enabled.txt")
    c = boot()
    check(has(last(c), "magic ok"), "the same folder without enabled.txt and without a line in mods.txt: the module is loaded")
    shutdown(c)
    T.write(TMP .. "/mega/mods.txt", "G1R_MageBalance : 1\r\n")
    c = boot()
    check(has(last(c), "magic left to the separate mod G1R_MageBalance"), "enabled through mods.txt (the player's installation has this line): not loaded")
    shutdown(c)
    T.write(TMP .. "/mega/mods.txt", "G1R_MageBalance : 0\r\n")
    c = boot()
    check(has(last(c), "magic ok"), "switched off in mods.txt: the module is loaded")
    shutdown(c)
    os.remove(TMP .. "/mega/mods.txt")
    T.sh("rm -rf " .. T.q(TMP .. "/mega/G1R_MageBalance"))

    -- switched off in the megamod's own settings
    T.write(root .. "/Scripts/config.lua", T.config("Config.Modules = { Magic = false }"))
    c = boot()
    c.looks(12)
    check(has(last(c), "loaded: magic off |") and c.world.reads == 0 and #c.ue.lookups == 0, "Config.Modules.Magic = false: the module is not loaded, the game is not touched")
    shutdown(c)

    -- diagnostics off: the module runs as on its own
    T.write(root .. "/Scripts/config.lua", T.config('Config.Diagnostics = { Level = "off" }'))
    c = boot()
    c.looks(9)
    check(printed(c.ue, "magic ok | diagnostics off") ~= nil and c.world.damage("FireBoltProjectileDefinition", 0) == 30 and c.world.price(6) == 25 and #c.ue.errors == 0,
        "diagnostics off: the configuration reaches the game, no error")
    shutdown(c)

    -- a loader without its kit: the module says what it needs
    os.remove(root .. "/Scripts/core/kit.lua")
    c = boot()
    check(c.ok and printed(c.ue, "[G1R_MegaMod] core/kit.lua could not be used") ~= nil
        and printed(c.ue, "[G1R_Magic] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started") ~= nil,
        "core/kit.lua missing: the loader says so, the module says what it needs and does not start")
    c.looks(12)
    check(has(last(c), "magic ok") and not has(table.concat(c.ue.printed), "failed to load") and c.world.untouched() and #c.ue.errors == 0,
        "that is not an error of the module, and the game is not touched: " .. last(c))
    shutdown(c)
end

-- ---------------------------------------------------------------------------
section("17. the facts file dev/facts/magic.md and what the module notes")
do
    local Rows = dofile(HERE .. "facts_rows.lua")
    local text = T.read(MOD .. "dev/facts/magic.md") or ""
    local facts, count = Rows.read(text)
    local generated = Rows.rows()
    local inFile = {}
    for line in text:gmatch("[^\n]+") do
        if line:sub(1, 18) == "| `magic.original." then inFile[#inFile + 1] = line end
    end
    check(#generated == 84 and #inFile == 84 and table.concat(inFile, "\n") == table.concat(generated, "\n"),
        "the 84 rows magic.original.<Name> of the facts file are the ones facts_rows.lua makes from the model's numbers (lua5.4 dev/tests/magic/facts_rows.lua)")
    check(count == 98, "98 note keys in all (" .. count .. ")")
    check(Rows.fits("re:^[0-9]+ not found", "2 not found") and not Rows.fits("re:^[0-9]+ not found", "all found") and Rows.fits("re:^[0-9]+ value\\(s\\)", "66 value(s)")
        and not Rows.fits("re:^[0-9]+ value\\(s\\)", "66 values") and Rows.fits("re:^base 20, steps -, speed [0-9.]+, stagger 200$", "base 20, steps -, speed 1500, stagger 200")
        and not Rows.fits("re:^base 20, steps -, speed [0-9.]+, stagger 200$", "base 20, steps -, speed -, stagger 200") and not Rows.fits("kept", "reset") and Rows.fits("kept", "kept"),
        "(the patterns of the facts rows are read here as dev/tools/diagread.py reads them)")

    -- a session that looks at every object and passes a map change and a minute
    local c = start("facts", { config = cfg({ "Config.Damage = 1.5", "Config.ManaCost = 2.0", "Config.Stagger = 2.0", "Config.ProjectileSpeed = 2.0", "Config.Range = 2.0", "Config.HealAmount = 2.0",
        "Config.IceBoltFreeze = true", "Config.IceBlockFreeze = true", "Config.IceWaveFreeze = true", "Config.CircleCosts = true", "Config.CircleCost1 = 12" }), diag = true })
    c.settle()
    c.ue:fireLoadMapPre("engine", "world", "url", nil, "")
    c.ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(260)
    local seen, unknown, differs = {}, {}, {}
    for _, n in ipairs(c.fake.notes) do seen[n.key] = true end
    for key in pairs(seen) do
        local row, value = facts[key], c.fake.value(key)
        if not row then
            unknown[#unknown + 1] = key
        elseif #row.expected > 0 then
            local fits = false
            for _, alternative in ipairs(row.expected) do
                if Rows.fits(alternative, value) then fits = true end
            end
            if not fits then differs[#differs + 1] = key .. " = " .. tostring(value) end
        end
    end
    local never = {}
    for key in pairs(facts) do
        if not seen[key] then never[#never + 1] = key end
    end
    table.sort(unknown)
    table.sort(differs)
    table.sort(never)
    check(c.searches() == 84 and #unknown == 0, "every object searched (84): each note the module writes has its row in the facts file (" .. table.concat(unknown, ", ") .. ")")
    check(#differs == 0, "and says what the row expects when all is as the model has it (" .. table.concat(differs, "; ") .. ")")
    check(#never == 0, "the facts file has no row for a note the module never writes (" .. table.concat(never, ", ") .. ")")
    stop(c)

    -- what the rows call a fallback is what the module notes when something is not as expected
    local function fallback(key, value)
        for _, alternative in ipairs(facts[key] and facts[key].fallback or {}) do
            if Rows.fits(alternative, value) then return true end
        end
        return false
    end
    check(fallback("magic.objects", "2 not found") and fallback("magic.properties", "4 not there") and fallback("magic.steps", "other shape") and fallback("magic.write.map", "failed")
        and fallback("magic.write.steps", "failed") and fallback("magic.write.levels", "failed") and fallback("magic.write.plain", "failed") and fallback("magic.write.flags", "failed")
        and fallback("magic.others", "1 value(s)") and fallback("magic.after_load", "reset") and fallback("magic.between_loads", "reset") and fallback("magic.ledger", "not available")
        and fallback("magic.inherited", "66 value(s)") and not fallback("magic.objects", "all found"),
        "the other values seen in the sections above (2 not found, failed, reset, not available ...) are the rows' fallbacks")
end

T.finish()
