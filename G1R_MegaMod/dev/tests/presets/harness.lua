-- ============================================================================
-- Offline tests of the presets: the field Tiers of the items in the modules'
-- schema.lua files (dev/SETTINGS.md section 7), checked with dev/tools/presets.lua.
-- The game does not read Tiers; the settings app sets the five values with its
-- "Preset" box. What is tested here is the data the mod ships.
--
--   lua5.4 harness.lua          (from any directory)
-- Last line: "presets tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("presets")
local check, section = T.check, T.section
rawset(_G, "PRESETS_LIB", true)
local P = dofile(T.MOD .. "dev/tools/presets.lua")
rawset(_G, "PRESETS_LIB", nil)

local function by(schema)
    local list, problems = P.read(schema)
    local map = {}
    for _, e in ipairs(list) do map[e.item.Key] = e end
    return map, list, problems
end
local function same(a, b)
    for i = 1, P.COUNT do
        if a[i] ~= b[i] then return false end
    end
    return true
end
local function text(values)
    local out = {}
    for i = 1, P.COUNT do out[i] = P.valueText(values[i]) end
    return table.concat(out, " | ")
end

-- ---------------------------------------------------------------------------
section("1. the schemas the mod ships")
local shipped = {}
do
    local expected = { general = 0, intro = 0, keys = 0, othermods = 0, timers = 0, locks = 8, magic = 80, melee = 0, mining = 13, mount = 0, movement = 0, regen = 20, wait = 0, xp = 4 }
    local names = P.modules(T.MOD)
    local withSchema = {}
    for _, name in ipairs(names) do
        local schema = P.schemaOf(T.MOD, name)
        if schema then
            withSchema[#withSchema + 1] = name
            local map, list, problems = by(schema)
            shipped[name] = { schema = schema, map = map, list = list }
            check(#problems == 0, name .. ": every Tiers field is usable" .. (#problems > 0 and (" - " .. table.concat(problems, "; ")) or ""))
            check(#list == expected[name], ("%s: %d item(s) with Tiers (expected %s)"):format(name, #list, tostring(expected[name])))
        end
    end
    check(table.concat(withSchema, " ") == "general intro keys locks magic melee mining mount movement othermods regen timers wait xp", "the modules with a schema: " .. table.concat(withSchema, " "))
end

-- ---------------------------------------------------------------------------
section("2. a preset leaves nothing of a module's difficulty to chance")
do
    -- In a module that has presets, every setting the player sees is either part of them or one of these
    -- (notes and log lines: not a matter of difficulty). A new setting needs a decision.
    local untouched = { ShowMessage = true, LogSteps = true, LogChanges = true, LogSwings = true, LogGains = true, LogLocks = true }
    for _, name in ipairs({ "locks", "magic", "mining", "regen", "xp" }) do
        local m = shipped[name]
        local missing = {}
        for _, group in ipairs(m.schema.Groups) do
            for _, item in ipairs(group.Items) do
                if not item.Hidden and item.Kind ~= "action" and not m.map[item.Key] and not untouched[item.Key] then missing[#missing + 1] = item.Key end
            end
        end
        check(#missing == 0, name .. ": every setting on its page has Tiers, except the notes and log switches" .. (#missing > 0 and (" - missing: " .. table.concat(missing, ", ")) or ""))
    end
    -- The switches of a module and of its parts are on in every preset: a preset is not undone by a switch that was off.
    for _, pair in ipairs({ { "regen", "Enabled" }, { "regen", "ManaEnabled" }, { "regen", "HealthEnabled" }, { "magic", "Enabled" }, { "mining", "Enabled" },
        { "xp", "Enabled" }, { "locks", "Enabled" } }) do
        local e = shipped[pair[1]].map[pair[2]]
        check(e ~= nil and same(e.values, { true, true, true, true, true }), pair[1] .. "." .. pair[2] .. " is on in every preset")
    end
    -- From the second preset on a number moves in one direction only (the first is the game itself, where the
    -- feature the number belongs to can be off).
    local wrong = {}
    for name, m in pairs(shipped) do
        for _, e in ipairs(m.list) do
            if e.item.Kind == "number" then
                local up, down = true, true
                for i = 3, P.COUNT do
                    if e.values[i] < e.values[i - 1] then up = false end
                    if e.values[i] > e.values[i - 1] then down = false end
                end
                if not up and not down then wrong[#wrong + 1] = name .. "." .. e.item.Key end
            end
        end
    end
    table.sort(wrong)
    check(#wrong == 0, "from preset 2 to 5 every number moves in one direction" .. (#wrong > 0 and (" - not: " .. table.concat(wrong, ", ")) or ""))
end

-- ---------------------------------------------------------------------------
section("3. preset 1 is the game itself, preset 5 is as easy as the settings allow")
do
    local function values(module, key) return shipped[module].map[key].values end
    local function item(module, key) return shipped[module].map[key].item end
    -- preset 1: every item at its default (the tool refuses anything else); the defaults are the game's own
    local all = true
    for _, m in pairs(shipped) do
        for _, e in ipairs(m.list) do
            if e.values[1] ~= e.item.Default then all = false end
        end
    end
    check(all, "preset 1 has every item at its default")
    -- preset 5: at the end of the range that makes the game easier
    local atMax = { { "xp", "Multiplier" }, { "magic", "Damage" }, { "magic", "ProjectileSpeed" }, { "magic", "Range" }, { "magic", "Stagger" }, { "magic", "HealAmount" },
        { "regen", "ManaPercent" }, { "regen", "HealthPercent" }, { "mining", "BaseAmount" }, { "mining", "TrainedBonus" }, { "mining", "MasterBonus" },
        { "mining", "ExtraChance" }, { "mining", "MinAmount" }, { "mining", "MaxAmount" }, { "mining", "VeinLastsTimes" },
        { "locks", "UntrainedWrongMoves" }, { "locks", "SkilledWrongMoves" }, { "locks", "MasterWrongMoves" } }
    local atMin = { { "magic", "ManaCost" }, { "magic", "CastTime" }, { "regen", "ManaSeconds" }, { "regen", "ManaPause" }, { "regen", "HealthSeconds" }, { "regen", "HealthPause" },
        { "magic", "CircleCostBasics" }, { "magic", "CircleCost1" }, { "magic", "CircleCost2" }, { "magic", "CircleCost3" }, { "magic", "CircleCost4" }, { "magic", "CircleCost5" },
        { "magic", "CircleCost6" } }
    local off = {}
    for _, p in ipairs(atMax) do
        if values(p[1], p[2])[5] ~= item(p[1], p[2]).Max then off[#off + 1] = p[1] .. "." .. p[2] end
    end
    for _, p in ipairs(atMin) do
        if values(p[1], p[2])[5] ~= item(p[1], p[2]).Min then off[#off + 1] = p[1] .. "." .. p[2] end
    end
    check(#off == 0, "preset 5: " .. (#atMax + #atMin) .. " numbers stand at the end of their range" .. (#off > 0 and (" - not: " .. table.concat(off, ", ")) or ""))
    local switches = { { "magic", "IceBoltFreeze", true }, { "magic", "IceBlockFreeze", true }, { "magic", "IceWaveFreeze", true }, { "magic", "CircleCosts", true },
        { "mining", "YieldEnabled", true }, { "mining", "EndlessVeins", true }, { "mining", "LowVeinRule", false }, { "locks", "PicksNeverBreak", true },
        { "locks", "UntrainedConnections", "all" }, { "locks", "SkilledConnections", "all" }, { "locks", "MasterConnections", "all" } }
    off = {}
    for _, p in ipairs(switches) do
        if values(p[1], p[2])[5] ~= p[3] then off[#off + 1] = p[1] .. "." .. p[2] end
    end
    check(#off == 0, "preset 5: the switches and choices that make the game easier are set" .. (#off > 0 and (" - not: " .. table.concat(off, ", ")) or ""))
    -- the numbers the presets are known by
    check(text(values("xp", "Multiplier")) == "1 | 1.5 | 2 | 4 | 10", "experience: " .. text(values("xp", "Multiplier")))
    check(text(values("magic", "Damage")) == "1 | 1.25 | 1.5 | 2.5 | 10" and text(values("magic", "ManaCost")) == "1 | 0.9 | 0.75 | 0.5 | 0",
        "magic: damage " .. text(values("magic", "Damage")) .. ", mana cost " .. text(values("magic", "ManaCost")))
    check(text(values("regen", "ManaPercent")) == "0 | 1 | 2 | 5 | 100" and text(values("regen", "HealthPercent")) == "0 | 0.5 | 1 | 3 | 100",
        "regeneration per step: mana " .. text(values("regen", "ManaPercent")) .. ", health " .. text(values("regen", "HealthPercent")))
    check(text(values("mining", "BaseAmount")) == "3 | 3 | 4 | 6 | 100" and text(values("mining", "EndlessVeins")) == "no | no | no | no | yes",
        "mining: base amount " .. text(values("mining", "BaseAmount")) .. ", endless veins " .. text(values("mining", "EndlessVeins")))
    check(text(values("locks", "UntrainedConnections")) == "as the game has it | 1 | 2 | 2 | all" and text(values("locks", "SkilledConnections")) == "as the game has it | 2 | 2 | all | all"
        and text(values("locks", "MasterConnections")) == "as the game has it | as the game has it | safe | all | all",
        "locks: the connections taken away never get fewer from one preset to the next, for doors as well (fixed numbers below \"all\"; \"safe\" only where the level's own number is the floor)")
    -- single spells and kinds of magic are fine tuning: every preset puts them back to neutral
    local neutral, count = true, 0
    for _, e in ipairs(shipped.magic.list) do
        local k = e.item.Key
        if e.item.Kind == "number" and (k:match("^School") or (k ~= "Damage" and k ~= "ManaCost" and k ~= "CastTime" and (k:match("Damage$") or k:match("Mana$") or k:match("CastTime$")))) then
            count = count + 1
            if e.item.Tiers ~= "default" then neutral = false end
        end
    end
    check(neutral and count == 48, "magic: the " .. count .. " multipliers for kinds of magic and single spells are neutral in every preset")
end

-- ---------------------------------------------------------------------------
section("4. what the tool refuses")
do
    local function item(fields)
        local it = { Key = "K", Kind = "number", Default = 1.0, Min = 0, Max = 10, Decimals = 2 }
        for k, v in pairs(fields) do
            if v == "nil" then it[k] = nil else it[k] = v end
        end
        return it
    end
    local function refused(fields, why)
        local values, problem = P.tiersOf(item(fields))
        return values == nil and problem == why, tostring(problem)
    end
    local ok, got = P.tiersOf(item({}))
    check(ok == nil and got == nil, "no Tiers: nothing, and nothing wrong")
    local values = P.tiersOf(item({ Tiers = { 1, 2, 3.25, 4, 10 } }))
    check(values ~= nil and same(values, { 1, 2, 3.25, 4, 10 }), "five numbers in range: taken")
    values = P.tiersOf(item({ Tiers = "default" }))
    check(values ~= nil and same(values, { 1, 1, 1, 1, 1 }), "\"default\": the item's default five times")
    values = P.tiersOf(item({ Kind = "bool", Default = false, Tiers = { false, false, true, true, true } }))
    check(values ~= nil and same(values, { false, false, true, true, true }), "a yes/no item")
    values = P.tiersOf(item({ Kind = "choice", Default = "a", Options = { "a", "b" }, Tiers = { "a", "a", "b", "b", "b" } }))
    check(values ~= nil and same(values, { "a", "a", "b", "b", "b" }), "a choice")
    local cases = {
        { { Tiers = 5 }, "K: Tiers must be 5 values or \"default\"", "a number instead of a list" },
        { { Tiers = "neutral" }, "K: Tiers must be 5 values or \"default\"", "another word" },
        { { Tiers = { 1, 2, 3, 4 } }, "K: Tiers must be 5 values or \"default\"", "four values" },
        { { Tiers = { 1, 2, 3, 4, 5, 6 } }, "K: Tiers must be 5 values or \"default\"", "six values" },
        { { Tiers = { 1, 2, 3, 4, 5, Name = "x" } }, "K: Tiers must be 5 values or \"default\"", "a named entry" },
        { { Tiers = { 1, 2, 3, 4, 11 } }, "K: tier 5 must be a number from 0 to 10", "a number above the range" },
        { { Tiers = { 1, -1, 3, 4, 5 } }, "K: tier 2 must be a number from 0 to 10", "a number below the range" },
        { { Tiers = { 1, 2, "3", 4, 5 } }, "K: tier 3 must be a number from 0 to 10", "a text among numbers" },
        { { Tiers = { 1, 2, 3.125, 4, 5 } }, "K: tier 3 has more places than Decimals allows", "more places than Decimals" },
        { { Decimals = "nil", Tiers = { 1, 2.5, 3, 4, 5 } }, "K: tier 2 has more places than Decimals allows", "a fraction in a whole-number item" },
        { { Tiers = { 2, 2, 3, 4, 5 } }, "K: tier 1 is the game itself - it must be the item's Default", "a first value that is not the default" },
        { { Kind = "bool", Default = true, Tiers = { true, 1, true, true, true } }, "K: tier 2 must be true or false", "a number in a yes/no item" },
        { { Kind = "choice", Default = "a", Options = { "a", "b" }, Tiers = { "a", "a", "c", "b", "b" } }, "K: tier 3 is not one of the Options", "a choice that is not offered" },
        { { Kind = "text", Default = "", Tiers = "default" }, "K: Tiers are for yes/no, number and choice items", "a text item" },
        { { Kind = "key", Default = "", Tiers = "default" }, "K: Tiers are for yes/no, number and choice items", "a key" },
        { { Kind = "action", Tiers = "default" }, "K: Tiers are for yes/no, number and choice items", "a button" },
        { { Hidden = true, Tiers = "default" }, "K: a hidden item cannot have Tiers (the app has no control for it)", "a hidden item" },
    }
    for _, c in ipairs(cases) do
        local ok2, said = refused(c[1], c[2])
        check(ok2, c[3] .. ": " .. said)
    end
    local list, problems = P.read({ Groups = { { Title = "G", Items = { item({ Tiers = "default" }), item({ Key = "B", Tiers = { 1, 2 } }), item({ Key = "C" }) } } } })
    check(#list == 1 and list[1].item.Key == "K" and list[1].group == "G" and #problems == 1 and problems[1] == "B: Tiers must be 5 values or \"default\"",
        "a schema: the usable items with their group, and what is wrong with the others")
    list, problems = P.read({})
    check(#list == 0 and problems[1] == "the schema has no Groups", "something that is no schema")
end

T.finish()
