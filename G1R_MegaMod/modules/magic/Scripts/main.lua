-- ============================================================================
-- Magic balancing (module magic of G1R_MegaMod) - Gothic 1 Remake, UE4SS Lua
--
-- Damage, mana cost, casting time, flight speed, reach and stagger of the
-- spells, the health the heal spell gives, the price of the magic circles and
-- whether an ice spell freezes with every hit - each a setting, each changed
-- while the game runs.
--
-- How it works. What a spell does is written in the game's own data: every
-- spell has a "definition" (its damage, also by the caster's magic circle, its
-- flight speed, its force against a foe's stance) and a "config" (mana to
-- cast and per second, casting time per charge level, for some spells their
-- reach); a hit effect
-- says whether an ice hit freezes at once, a skill effect what a magic circle
-- costs to learn. The game reads these numbers from the default objects of
-- those classes whenever a spell is cast, a hit lands or a circle is learned
-- (dev/facts/magic.md says where each of this is known from).
-- The module changes the numbers there, not the hero:
--
--   * an object is searched by its path once per run, and only when a
--     setting that concerns it is not neutral (a few searches per look);
--   * the first number read from a place is kept as the game's own; a new
--     number is always computed from that one, never from a changed one;
--   * a number is only written over the game's own number or over the
--     module's last one. Anything else was changed by somebody else: it is
--     left alone and counted;
--   * every write is read back. A write that does not stay is said once, and
--     the place is left as it is;
--   * a setting back at neutral, or the module switched off: the game's own
--     numbers are written back. Then the game is not looked at any more;
--   * after a map change, and now and then, the changed places are looked at
--     again: numbers the game has put back are set again;
--   * the game's own numbers and the module's are also kept in a UE4SS shared
--     variable, so that a reload of the Lua mods does not make the module
--     take its own numbers for the game's.
--
-- What it cannot do: the numbers hold for everyone who uses the same spells
-- (human mages cast with the hero's runes); creatures, orc shamans and the
-- companions of the last fight have spell classes of their own, which are not
-- touched. A spell that is already on its way keeps the numbers it started
-- with. Nothing is written into a save.
--
-- One magic balance at a time: the loader does not load this module while the
-- mod G1R_MageBalance is enabled.
--
-- Settings: schema.lua describes them, config.lua holds them; the settings
-- app and the in-game mod menu change them while the game runs.
-- ============================================================================

local VERSION = "1.0.1"
local TAG = "G1R_Magic"

local KIT, SETTINGS = G1R_KIT, G1R_SETTINGS
-- Diagnostics handle of the loader; nil when the diagnostics are off, and then
-- nothing behind `if DIAG` runs.
local DIAG = G1R_DIAG
if type(KIT) ~= "table" or type(SETTINGS) ~= "table" then
    print("[" .. TAG .. "] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started\n")
    return
end
if DIAG then pcall(DIAG.version, VERSION) end

local pcall, type, tostring, tonumber, ipairs, pairs = pcall, type, tostring, tonumber, ipairs, pairs
local floor, abs, max = math.floor, math.abs, math.max
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
-- The game's spells, by the names of its script classes (dev/facts/magic.md)
--   key      start of the spell's settings: <key>Damage, <key>Mana, <key>CastTime
--   school   the setting for its kind of damage
--   defs     its definitions (one per charge level): damage, flight speed, force against a foe's stance
--   config   its spell config: mana, casting time, and for some spells their reach
--   flies    the definitions' speed is the speed of something that flies
--   steps    the spell has settings for its damage by the caster's circle (<key>Steps, <key>Step0 / 2 / 4 / 6)
--   freeze   the hit effect that holds its ice counter (<key>Freeze)
-- ---------------------------------------------------------------------------
local SPELLS = {
    { key = "FireBolt", school = "SchoolFire", config = "ProjectileSpellConfig_FireBolt", flies = true, steps = true,
      defs = { "FireBoltProjectileDefinition" } },
    { key = "FireBall", school = "SchoolFire", config = "ProjectileSpellConfig_FireBall", flies = true,
      defs = { "FireBallProjectileDefinition_Lvl1", "FireBallProjectileDefinition_Lvl2", "FireBallProjectileDefinition_Lvl3" } },
    { key = "Pyrokinesis", school = "SchoolFire", config = "PyrokinesisSpellConfig", defs = { "PyrokinesisProjectileDefinition" } },
    { key = "StormOfFire", school = "SchoolFire", config = "StormOfFireSpellConfig", flies = true, defs = { "StormOfFireDefinition" } },
    { key = "FireRain", school = "SchoolFire", config = "FireRainSpellConfig", defs = { "FireRainDefinition" } },
    { key = "IceBolt", school = "SchoolIce", config = "ProjectileSpellConfig_IceBolt", flies = true, steps = true,
      freeze = "GE_IceBolt_Damage", defs = { "IceBoltProjectileDefinition" } },
    { key = "IceBlock", school = "SchoolIce", config = "IceBlockSpellConfig", freeze = "GE_IceBlock_Freeze_Damage",
      defs = { "IceBlockProjectileDefinition" } },
    { key = "IceWave", school = "SchoolIce", config = "IceWaveSpellConfig", freeze = "GE_IceWave_Freeze_Damage",
      defs = { "IceWaveProjectileDefinition" } },
    { key = "BallLightning", school = "SchoolEnergy", config = "ProjectileSpellConfig_BallLightning", flies = true,
      defs = { "BallLightningDefinition_Lvl1", "BallLightningDefinition_Lvl2", "BallLightningDefinition_Lvl3", "BallLightningDefinition_Lvl4" } },
    -- the rune shows the first of the three, a hit uses one of the other two: each has its own copy of the numbers
    { key = "ChainLightning", school = "SchoolEnergy", config = "ChainLightningSpellConfig",
      defs = { "LightningRayDefinition_Base", "LightningRayDefinition_WithParalysis", "LightningRayDefinition_WithoutParalysis" } },
    { key = "Uriziel", school = "SchoolEnergy", config = "UrizielWaveOfDeathSpellConfig", defs = { "UrizielWaveOfDeathVisualDefinition" } },
    { key = "DeathToTheUndead", school = "SchoolEnergy", config = "DeathToTheUndeadSpellConfig", defs = { "DeathToTheUndeadDefinition" } },
    { key = "WindFist", school = "SchoolWind", config = "FistOfWindSpellConfig", defs = { "WindFistDefinition" } },
    { key = "StormFist", school = "SchoolWind", config = "StormFistSpellConfig", defs = { "StormFistDefinition" } },
    { key = "BreathOfDeath", school = "SchoolWind", config = "BreathOfDeathSpellConfig", defs = { "BreathOfDeathDefinition" } },
}
-- Spells without damage: the multipliers for all spells (mana, casting time, reach) hold for them too.
local HEAL = "HealSpellConfig"
local OTHER_SPELLS = {
    HEAL, "LightSpellConfig", "SleepSpellConfig", "CharmSpellConfig", "TelekinesisSpellConfig", "ControlSpellConfig",
    "FearSpellConfig", "ShrinkSpellConfig", "InnosPraySpellConfig",
    "TeleportSpellConfig_MagiciansOfFire", "TeleportSpellConfig_SwampCamp", "TeleportSpellConfig_MagiciansOfWater",
    "TeleportSpellConfig_Necromancer", "TeleportSpellConfig_OrcCementery", "TeleportSpellConfig_SleepersTemple",
    "TeleportSpellConfig_SunkenTower",
    "SummonSpellConfig_Skeletons", "SummonSpellConfig_Golem", "SummonSpellConfig_Demon", "SummonSpellConfig_ArmyOfDarkness",
    "TransformMeatbugSpellConfig", "TransformScavengerSpellConfig", "TransformMoleratSpellConfig", "TransformBloodflySpellConfig",
    "TransformWolfSpellConfig", "TransformLizardSpellConfig", "TransformLurkerSpellConfig", "TransformOrcDogSpellConfig",
    "TransformMinecrawlerSpellConfig", "TransformSnapperSpellConfig", "TransformBiterSpellConfig", "TransformRazorSpellConfig",
    "TransformBloodhoundSpellConfig", "TransformFireLizardSpellConfig", "TransformShadowbeastSpellConfig",
    "TransformHarpySpellConfig", "TransformSwampsharkSpellConfig",
}
-- The configs whose reach the game's scripts are known to use for the spell itself: the range in which a target
-- spell finds its target, and the radius storm fist, death to the undead and Uriziel's wave grow to. (The other area
-- spells get their area from the collision shape of the actor they spawn; their reach is left alone.)
local REACH = {
    PyrokinesisSpellConfig = true, ChainLightningSpellConfig = true, HealSpellConfig = true, SleepSpellConfig = true,
    CharmSpellConfig = true, ShrinkSpellConfig = true, TelekinesisSpellConfig = true, ControlSpellConfig = true,
    StormFistSpellConfig = true, DeathToTheUndeadSpellConfig = true, UrizielWaveOfDeathSpellConfig = true,
}
-- The skill effects a teacher gives for the magic circles, and the setting with the price of each.
local CIRCLES = {
    { "CircleCostBasics", "GE_Skill_Mage_Circle_Amateur" }, { "CircleCost1", "GE_Skill_Mage_Circle_1" },
    { "CircleCost2", "GE_Skill_Mage_Circle_2" }, { "CircleCost3", "GE_Skill_Mage_Circle_3" },
    { "CircleCost4", "GE_Skill_Mage_Circle_4" }, { "CircleCost5", "GE_Skill_Mage_Circle_5" },
    { "CircleCost6", "GE_Skill_Mage_Circle_6" },
}
local PLACE = "Angelscript"                 -- all of them are classes of the game's scripts: /Script/Angelscript.Default__<name>
local FLAG = "ForceOverflowElementalEffectStack"
-- A bolt's own damage numbers belong to these places (one kind of damage, three steps), in this shape of its data.
local STEPS_SHAPE = "1/3"
local STEP_OF = { ["base1"] = "Step0", ["step1.1"] = "Step2", ["step1.2"] = "Step4", ["step1.3"] = "Step6" }

-- Every object of the game the module can change: kind, name, the spell it belongs to; and what is known of it
-- in this run (state, object, slots: place -> { orig = the game's own number, ours = the module's }).
local Objects = {}
local function object(kind, name, more)
    local rec = more or {}
    rec.kind, rec.name, rec.slots = kind, name, {}
    rec.reach = kind == "config" and REACH[name] == true
    Objects[#Objects + 1] = rec
end
for _, spell in ipairs(SPELLS) do
    for _, name in ipairs(spell.defs) do object("definition", name, { spell = spell }) end
    object("config", spell.config, { spell = spell })
    if spell.freeze then object("effect", spell.freeze, { spell = spell }) end
end
for _, name in ipairs(OTHER_SPELLS) do object("config", name, { heal = name == HEAL }) end
for _, circle in ipairs(CIRCLES) do object("skill", circle[2], { setting = circle[1] }) end

-- What a place is called in the status, and which way of writing it uses (one diagnostics note per way).
local WORDS = {
    base = "damage", step = "damage", mana = "mana", held = "mana", time = "casting time", speed = "flight speed",
    range = "reach", stagger = "stagger", heal = "healing", force = "freeze", cost = "circle price",
}
local WORD_ORDER = { "damage", "mana", "casting time", "flight speed", "reach", "stagger", "healing", "freeze", "circle price" }
local WRITES = {
    base = "magic.write.map", heal = "magic.write.map", step = "magic.write.steps",
    mana = "magic.write.levels", held = "magic.write.levels", time = "magic.write.levels",
    speed = "magic.write.plain", stagger = "magic.write.plain", range = "magic.write.plain", cost = "magic.write.plain",
    force = "magic.write.flags",
}

local LEDGER = "G1R_Magic:changed"          -- the shared variable with the game's numbers and the module's
local SETTLE = 2                            -- seconds after a map change before the changed places are looked at again

-- ---------------------------------------------------------------------------
-- State of this run
-- ---------------------------------------------------------------------------
local S = {
    asked = nil,                -- why the game's data is to be looked at: { start / settings / world / check = true }
    queue = nil, at = nil,      -- the objects of the look that is under way, and how far it is
    why = nil, pass = nil,      -- its reasons and its counts
    checkAt = nil,              -- a map changed: the look after it is due at this clock value
    nextCheck = nil,            -- the next look at the changed places without a reason
    count = 0, holders = 0,     -- places / objects that hold a number of the module right now
    by = {},                    -- the same by kind of number
    others = {},                -- places somebody else changed: "Object place"
    shifted = {},               -- objects whose lists have other lengths than at the first look
    failed = 0,                 -- places whose last write did not stay
    missing = {}, gone = {},    -- objects that were not found / that were found and are gone
    lacking = {},               -- properties that are not there: "Object.property"
    told = {},                  -- what of the three lists was said in the log already
    ledgerText = nil,           -- the shared variable as the module last wrote or found it
    unsaved = nil,              -- true: something was written since the shared variable was last brought up to date
    passes = 0, searches = 0,
    crumbed = {},
}
local Noted = {}
local function note(key, value, detail)
    if DIAG and Noted[key] ~= value then
        Noted[key] = value
        DIAG.note(key, value, detail)
    end
end

-- A number as short as it can be written: 35, 0.1, 1.03, 2.778
local function num(v)
    local s = ("%.3f"):format(v):gsub("0+$", "")
    if s:sub(-1) == "." then s = s:sub(1, -2) end
    return s
end
local function show(v)
    if type(v) == "number" then return num(v) end
    return tostring(v)
end
-- The same value? The game keeps most of these numbers in single precision: what comes back differs in the last digits.
local function same(a, b)
    if type(a) == "number" and type(b) == "number" then return abs(a - b) <= max(0.000001, abs(b) * 0.0000004) end
    return a == b
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local Settings, problem = SETTINGS.open({ module = "magic", dir = SCRIPT_DIR, log = log })
if not Settings then
    log("the settings could not be set up (" .. tostring(problem) .. "); not started")
    return
end
local Cfg = Settings.values

-- Does a setting that concerns this object differ from neutral? (Asked without looking at the game.)
local NEEDS = {}
function NEEDS.definition(rec)
    local spell = rec.spell
    return Cfg.Damage ~= 1 or Cfg[spell.school] ~= 1 or Cfg[spell.key .. "Damage"] ~= 1 or Cfg.Stagger ~= 1
        or (spell.steps and Cfg[spell.key .. "Steps"])
        or (spell.flies and (Cfg.ProjectileSpeed ~= 1 or (spell.key == "BallLightning" and Cfg.BallLightningSpeed > 0)))
        or (spell.key == "WindFist" and Cfg.WindFistStagger ~= 1)
end
function NEEDS.config(rec)
    local spell = rec.spell
    return Cfg.ManaCost ~= 1 or Cfg.CastTime ~= 1 or (rec.reach and Cfg.Range ~= 1) or (rec.heal and Cfg.HealAmount ~= 1)
        or (spell ~= nil and (Cfg[spell.key .. "Mana"] ~= 1 or (Cfg[spell.key .. "CastTime"] or 1) ~= 1))
end
function NEEDS.effect(rec) return Cfg[rec.spell.key .. "Freeze"] end
function NEEDS.skill() return Cfg.CircleCosts end
local function needs(rec)
    return Cfg.Enabled and NEEDS[rec.kind](rec)
end
local function anyNeeds()
    for _, rec in ipairs(Objects) do
        if needs(rec) then return true end
    end
    return false
end

-- Damage and mana are whole numbers in the game's data, and a multiplier has three decimals: 90 x 2.778 is meant
-- as 250, 15 x 1.333 as 20. A product that misses a whole number by no more than this is that number.
local SNAP = 0.025
local function snapped(v)
    local whole = floor(v + 0.5)
    if abs(v - whole) <= SNAP then return whole end
    return v
end

-- The number a place is to hold, from the game's own number.
local WANT = {}
function WANT.definition(rec, key, orig)
    local spell = rec.spell
    if key == "speed" then
        if not spell.flies then return orig end
        if spell.key == "BallLightning" and Cfg.BallLightningSpeed > 0 then orig = Cfg.BallLightningSpeed end
        return orig * Cfg.ProjectileSpeed
    end
    if key == "stagger" then
        if spell.key == "WindFist" then orig = orig * Cfg.WindFistStagger end
        return orig * Cfg.Stagger
    end
    -- damage: "base<i>" for a caster below the first step, "step<i>.<j>" from the circle of step j on
    if spell.steps and Cfg[spell.key .. "Steps"] and rec.shape == STEPS_SHAPE then orig = Cfg[spell.key .. STEP_OF[key]] end
    local times = Cfg.Damage * Cfg[spell.school] * Cfg[spell.key .. "Damage"]
    if times == 1 then return orig end
    return snapped(orig * times)
end
function WANT.config(rec, key, orig)
    local spell = rec.spell
    local what = key:match("^%a+")
    if what == "range" then return orig * Cfg.Range end
    if what == "heal" then return orig * Cfg.HealAmount end
    if what == "time" then return orig * Cfg.CastTime * (spell and Cfg[spell.key .. "CastTime"] or 1) end
    -- "mana<i>": to cast level i; "held<i>": each second while the spell is held
    local times = Cfg.ManaCost * (spell and Cfg[spell.key .. "Mana"] or 1)
    if times == 1 then return orig end
    if not Cfg.WholeMana then
        local cost = snapped(orig * times)
        if cost == 0 then cost = orig * times end       -- a small product is not the whole number 0: only a multiplier of 0 makes a spell free
        return cost
    end
    -- halves are rounded up; the little added keeps a half that the multiplication left a hair short (15 x 4.1 =
    -- 61.499999999999993) from being rounded down
    local cost = floor(orig * times + 0.5 + 1e-9)
    if cost == 0 and times > 0 and orig > 0 then cost = 1 end      -- only a multiplier of 0 makes a spell free
    return cost
end
function WANT.effect(rec, _, orig)
    return Cfg[rec.spell.key .. "Freeze"] or orig
end
function WANT.skill(rec, _, orig)
    if Cfg.CircleCosts then return Cfg[rec.setting] end
    return orig
end
local function want(rec, key, orig)
    if not Cfg.Enabled then return orig end
    return WANT[rec.kind](rec, key, orig)
end

local function summary()
    if not Cfg.Enabled then return "switched off in the settings" end
    local parts = {}
    for _, item in ipairs({ { "Damage", "damage" }, { "ManaCost", "mana" }, { "CastTime", "casting time" },
        { "ProjectileSpeed", "flight speed" }, { "Range", "reach" }, { "Stagger", "stagger" }, { "HealAmount", "healing" },
        { "SchoolFire", "fire" }, { "SchoolIce", "ice" }, { "SchoolEnergy", "energy" }, { "SchoolWind", "wind" } }) do
        if Cfg[item[1]] ~= 1 then parts[#parts + 1] = item[2] .. " x" .. num(Cfg[item[1]]) end
    end
    local single, freeze = 0, 0
    for _, spell in ipairs(SPELLS) do
        for _, what in ipairs({ "Damage", "Mana", "CastTime" }) do
            if (Cfg[spell.key .. what] or 1) ~= 1 then single = single + 1 end
        end
        if spell.steps and Cfg[spell.key .. "Steps"] then single = single + 1 end
        if spell.freeze and Cfg[spell.key .. "Freeze"] then freeze = freeze + 1 end
    end
    if Cfg.BallLightningSpeed > 0 then single = single + 1 end
    if Cfg.WindFistStagger ~= 1 then single = single + 1 end
    if single > 0 then parts[#parts + 1] = single .. " setting(s) for single spells" end
    if freeze > 0 then parts[#parts + 1] = freeze .. " ice spell(s) freeze with every hit" end
    if Cfg.CircleCosts then parts[#parts + 1] = "own prices for the magic circles" end
    if #parts == 0 then return "everything as the game has it (the game is not touched)" end
    return concat(parts, ", ")
end

-- ---------------------------------------------------------------------------
-- The shared variable (UE4SS keeps it while the game runs, also through a
-- reload of the Lua mods): one line "Object|place|the game's number|ours" for
-- every place that holds a number of the module.
-- ---------------------------------------------------------------------------
local function shared(name)
    local ok, v = pcall(function() return ModRef:GetSharedVariable(name) end)
    if ok then return v end
    return nil
end
local function share(name, value)
    return (pcall(function() ModRef:SetSharedVariable(name, value) end))
end
local function written(v)
    if type(v) == "number" then return ("%.17g"):format(v) end
    return tostring(v)
end
local function parsed(text)
    if text == "true" then return true end
    if text == "false" then return false end
    return tonumber(text)
end
-- What an earlier run of the Lua mods left: Object -> place -> { orig, ours }. Returns the number of places.
local function inherit(text)
    local byName, n = {}, 0
    for _, rec in ipairs(Objects) do byName[rec.name] = rec end
    for line in tostring(text):gmatch("[^\n]+") do
        local name, key, orig, ours = line:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
        local rec = byName[name]
        orig, ours = parsed(orig), parsed(ours)
        if rec and orig ~= nil and ours ~= nil then
            rec.inherited = rec.inherited or {}
            rec.inherited[key] = { orig = orig, ours = ours }
            n = n + 1
        end
    end
    return n
end
local function publish()
    S.unsaved = nil
    local lines = {}
    for _, rec in ipairs(Objects) do
        for key, old in pairs(rec.inherited or {}) do       -- not looked at yet in this run: passed on as it was found
            lines[#lines + 1] = concat({ rec.name, key, written(old.orig), written(old.ours) }, "|")
        end
        for key, slot in pairs(rec.slots) do
            if slot.ours ~= nil then lines[#lines + 1] = concat({ rec.name, key, written(slot.orig), written(slot.ours) }, "|") end
        end
    end
    sort(lines)
    local text = concat(lines, "\n")
    if text == S.ledgerText then return end
    if share(LEDGER, text) then
        S.ledgerText = text
        note("magic.ledger", "kept")
    else
        note("magic.ledger", "not available")
    end
end

-- ---------------------------------------------------------------------------
-- Reading the game's data. Each function walks one object and calls
--   visit(place, value, set)   for every place it can read (set(v) writes it; only usable inside the call)
--   lack(property)             for what is not there
-- and returns the shape of the data (how many entries each list has).
-- Arrays are walked with the kit's each (never indexed: an index past the end
-- would add entries to the game's array), maps with their own ForEach.
-- ---------------------------------------------------------------------------
-- What UE4SS runs inside such a walk must not raise - the error would have to pass through UE4SS's own code on
-- its way out. So every step of a walk is guarded, and a walk with a failed step counts as not walked.
--
-- f(value, n) for every pair of a map property, in the map's order; value is the pair's value with get() and
-- set(). Returns the number of pairs, or nil when the map cannot be walked.
local function pairsOf(map, f)
    local n, good = 0, true
    local ok = pcall(function()
        map:ForEach(function(_, value)
            n = n + 1
            if not pcall(f, value, n) then good = false end
        end)
    end)
    if ok and good then return n end
    return nil
end
-- f(element, index) for every element of an array property. Returns the number of elements, or nil.
local function eachOf(array, f)
    local good = true
    local n = KIT.each(array, function(element, index)
        if not pcall(f, element, index) then good = false end
    end)
    if good then return n end
    return nil
end
local function got(value) return value:get() end
-- A number that is the value of a pair of a map.
local function number(value, property, key, visit, lack)
    local ok, raw = pcall(got, value)
    local v = ok and KIT.number(raw) or nil
    if v == nil then return lack(property) end
    visit(key, v, function(x) value:set(x) end)
end
-- A number that is a property of an object or a field of a struct.
local function plain(owner, property, key, visit, lack)
    local v = KIT.number(KIT.get(owner, property))
    if v == nil then return lack(property) end
    visit(key, v, function(x) owner[property] = x end)
end

local SCAN = {}
function SCAN.definition(o, visit, lack)
    local sizes = {}
    local n = pairsOf(KIT.get(o, "m_DamageBase"), function(value, i)
        number(value, "m_DamageBase", "base" .. i, visit, lack)
    end)
    if not n or n == 0 then lack("m_DamageBase") end
    sizes[1] = n or 0
    local whole = true
    n = pairsOf(KIT.get(o, "m_DamageMagicCircleProgression"), function(value, i)
        local m = eachOf(KIT.get(value:get(), "m_DamageByMagicCircle"), function(step, j)
            plain(step, "m_Damage", "step" .. i .. "." .. j, visit, lack)
        end)
        if m == nil then whole = false end
        sizes[#sizes + 1] = m or 0
    end)
    if not n or not whole then lack("m_DamageMagicCircleProgression") end
    plain(o, "m_Speed", "speed", visit, lack)
    plain(o, "m_SuperArmorDamageBase", "stagger", visit, lack)
    return concat(sizes, "/")
end
function SCAN.config(o, visit, lack, rec)
    local n = eachOf(KIT.get(o, "m_SpellLevels"), function(level, i)
        plain(level, "CastManaCost", "mana" .. i, visit, lack)
        plain(level, "CastTime", "time" .. i, visit, lack)
        plain(level, "ManaCostSc", "held" .. i, visit, lack)
    end)
    if not n or n == 0 then lack("m_SpellLevels") end
    if rec.reach then plain(o, "m_AreaRange", "range", visit, lack) end
    if not rec.heal then return tostring(n or 0) end
    local h = pairsOf(KIT.get(o, "m_healAmountByMagicCircle"), function(value, i)
        number(value, "m_healAmountByMagicCircle", "heal" .. i, visit, lack)
    end)
    if not h or h == 0 then lack("m_healAmountByMagicCircle") end
    return (n or 0) .. "/" .. (h or 0)
end
function SCAN.effect(o, visit, lack)
    local n = eachOf(KIT.get(o, "m_ElementalEffectStacks"), function(stack, j)
        local v = KIT.get(stack, FLAG)
        if type(v) ~= "boolean" then return lack(FLAG) end
        visit("force" .. j, v, function(x) stack[FLAG] = x end)
    end)
    if not n or n == 0 then lack("m_ElementalEffectStacks") end
    return tostring(n or 0)
end
function SCAN.skill(o, visit, lack)
    plain(o, "SPCost", "cost", visit, lack)
    return ""
end

-- Everything that can be read of an object now: place -> value, the places in order, what is lacking, the shape.
local function read(rec)
    local values, order, lacking = {}, {}, {}
    local shape = SCAN[rec.kind](rec.object, function(key, value)
        values[key] = value
        order[#order + 1] = key
    end, function(property) lacking[#lacking + 1] = property end, rec)
    return values, order, lacking, shape
end

-- The game's own numbers of an object as one text (the diagnostics note magic.original.<name>):
--   a definition   base 35, steps 40 50 65, speed 4000, stagger 30
--   a config       levels 5 0.5 1, range 1500     (a level: mana, time, mana a second; the range where it is used)
--   a hit effect   false                                             (the flag of each ice counter)
--   a skill effect 10
-- "-" stands for what could not be read. (No "|" in it: dev/facts/magic.md has these texts in a table.)
local function originalText(rec, order)
    local by = {}
    for _, key in ipairs(order) do
        local word = key:match("^%a+")
        by[word] = by[word] or {}
        by[word][#by[word] + 1] = show(rec.slots[key].orig)
    end
    local function all(word) return by[word] and concat(by[word], " ") or "-" end
    if rec.kind == "definition" then
        return ("base %s, steps %s, speed %s, stagger %s"):format(all("base"), all("step"), all("speed"), all("stagger"))
    elseif rec.kind == "config" then
        local levels = {}
        for i = 1, tonumber(rec.shape:match("^%d+")) do
            local function of(word)
                local slot = rec.slots[word .. i]
                return slot and show(slot.orig) or "-"
            end
            levels[i] = of("mana") .. " " .. of("time") .. " " .. of("held")
        end
        local text = "levels " .. (#levels > 0 and concat(levels, " / ") or "-")
        if rec.reach then text = text .. ", range " .. all("range") end
        if rec.heal then text = text .. ", heal " .. all("heal") end
        return text
    elseif rec.kind == "effect" then
        return all("force")
    end
    return all("cost")
end

-- ---------------------------------------------------------------------------
-- One look at one object: read every place, write what has to change, read
-- back. Counts into S.pass.
-- ---------------------------------------------------------------------------
local KIND = { definition = "a definition", config = "a config", effect = "a hit effect", skill = "a skill effect" }
-- The first look at, and the first write to, an object of each kind is announced to the diagnostics before it
-- happens (should the game stop there, that line is the last one).
local function crumb(rec, what)
    local key = what .. rec.kind
    if not DIAG or S.crumbed[key] then return false end
    S.crumbed[key] = true
    DIAG.crumb(("first %s %s: %s"):format(what, KIND[rec.kind], rec.name))
    return true
end

local function wrote(rec, key, ok, why)
    local kind = WRITES[key:match("^%a+")]
    if ok then
        note(kind, "ok")
        return
    end
    note(kind, "failed", ("%s %s: %s"):format(rec.name, key, why))
    L.once(kind, ("a number could not be changed: %s %s (%s); numbers of this kind stay as the game has them"):format(rec.name, key, why))
end

local function examine(rec)
    local P = S.pass
    P.looked = P.looked + 1
    local first = crumb(rec, "look at")
    local values, order, lacking, shape = read(rec)
    if rec.shape == nil then
        -- the first look: what is there now is the game's own (or what an earlier run of the Lua mods noted as that)
        rec.shape = shape
        for _, key in ipairs(order) do
            local slot = { orig = values[key] }
            local old = rec.inherited and rec.inherited[key]
            if old then slot.orig, slot.ours = old.orig, old.ours end
            rec.slots[key] = slot
        end
        rec.inherited = nil
        rec.order = order
        note("magic.original." .. rec.name, originalText(rec, order))
        for _, property in ipairs(lacking) do S.lacking[#S.lacking + 1] = rec.name .. "." .. property end
        if rec.spell and rec.spell.steps and rec.kind == "definition" then
            note("magic.steps", shape == STEPS_SHAPE and "as expected" or "other shape", rec.name .. " " .. shape)
        end
    end
    if first then DIAG.event(("first look at %s done: %s = %s"):format(KIND[rec.kind], rec.name, originalText(rec, rec.order))) end
    rec.shifted = shape ~= rec.shape
    if rec.shifted then
        -- the lists have other lengths than at the first look: no longer the data the numbers belong to
        L.once("shape:" .. rec.name, ("%s has another shape than before (%s, was %s): it is left alone"):format(rec.name, shape, rec.shape))
        return
    end

    local plan, planned = {}, false
    for _, key in ipairs(rec.order) do
        local slot, value = rec.slots[key], values[key]
        if value ~= nil then
            local ours = slot.ours ~= nil and same(value, slot.ours)
            if ours or same(value, slot.orig) then
                slot.other = nil
                -- counted once per look, also when the look starts over: was the number the module's when the look
                -- first came by (held), and has the game put its own back since (reset)?
                local fresh = slot.pass ~= P
                if fresh then slot.pass, slot.held = P, ours end
                if ours then
                    if fresh then P.held = P.held + 1 end
                elseif slot.ours ~= nil then        -- the game has its own number again
                    slot.ours = nil
                    if fresh then
                        P.reset = P.reset + 1
                    elseif slot.held then
                        slot.held, P.held, P.reset = false, P.held - 1, P.reset + 1
                    end
                end
                local target = want(rec, key, slot.orig)
                if not same(value, target) and not same(slot.failed, target) then
                    plan[key] = target
                    planned = true
                end
            else
                slot.other = value                  -- somebody else's number: not the module's to touch
            end
        end
    end
    if not planned then return end

    S.unsaved = true
    first = crumb(rec, "write to")
    local raised = {}
    SCAN[rec.kind](rec.object, function(key, _, set)
        local target = plan[key]
        if target ~= nil and not pcall(set, target) then raised[key] = true end
    end, function() end, rec)
    local after = read(rec)
    if first then DIAG.event(("first write to %s done: %s"):format(KIND[rec.kind], rec.name)) end
    for _, key in ipairs(rec.order) do
        local target = plan[key]
        if target ~= nil then
            local slot, now = rec.slots[key], after[key]
            if same(now, target) then
                slot.failed = nil
                if same(target, slot.orig) then
                    slot.ours = nil
                    P.restored = P.restored + 1
                else
                    slot.ours = target
                    P.changed = P.changed + 1
                end
                wrote(rec, key, true)
                if Cfg.LogChanges then log(("%s %s: %s -> %s"):format(rec.name, key, show(values[key]), show(target))) end
            else
                -- left as it is; what is there now and is not the game's own number is the module's doing
                slot.failed = target
                slot.ours = nil
                if now ~= nil and not same(now, slot.orig) then slot.ours = now end
                P.failed = P.failed + 1
                wrote(rec, key, false, raised[key] and "the write raised an error" or "the value did not stay")
            end
        end
    end
end

local function look(rec)
    examine(rec)
    rec.ours = false            -- does the object hold a number of the module now?
    for _, slot in pairs(rec.slots) do
        if slot.ours ~= nil then rec.ours = true end
    end
end

-- ---------------------------------------------------------------------------
-- Finding the objects: by path through the kit, each path once per run.
-- ---------------------------------------------------------------------------
local function find(rec)
    S.searches = S.searches + 1
    local o = KIT.findDefault(rec.name, PLACE)
    local full = o and KIT.fullName(o) or nil
    local path = "Default__" .. rec.name
    if full and full:sub(-#path) == path then
        rec.state, rec.object, rec.full = "found", o, full
        return
    end
    rec.state, rec.inherited = "missing", nil
    S.missing[#S.missing + 1] = rec.name
end
-- Is the object that was found still there, and still the same? (A wrapper is a pointer: FACTS U5.)
local function alive(rec)
    local o = KIT.findDefault(rec.name, PLACE)           -- answered from the kit's memory; never a second search
    if o ~= nil and KIT.fullName(o) == rec.full then
        rec.object = o
        return true
    end
    rec.state, rec.object, rec.slots, rec.order, rec.shape = "gone", nil, {}, nil, nil
    S.gone[#S.gone + 1] = rec.name
    return false
end

-- ---------------------------------------------------------------------------
-- A look at everything that is, or has to be, changed
-- ---------------------------------------------------------------------------
local function ask(why)
    S.asked = S.asked or {}
    S.asked[why] = true
end

local function tally()
    local count, holders, failed, by, others, shifted = 0, 0, 0, {}, {}, {}
    for _, rec in ipairs(Objects) do
        local held = false
        for _, key in ipairs(rec.order or {}) do
            local slot = rec.slots[key]
            if slot.other ~= nil then
                others[#others + 1] = rec.name .. " " .. key
            elseif slot.ours ~= nil then
                held = true
                count = count + 1
                local word = WORDS[key:match("^%a+")]
                by[word] = (by[word] or 0) + 1
            end
            if slot.failed ~= nil then failed = failed + 1 end
        end
        if held then holders = holders + 1 end
        if rec.shifted then shifted[#shifted + 1] = rec.name end
    end
    S.count, S.holders, S.failed, S.by, S.others, S.shifted = count, holders, failed, by, others, shifted
end

-- Says what is new in one of the lists of things that are not there, once.
local function tell(list, key, text)
    local from = (S.told[key] or 0) + 1
    if #list < from then return end
    S.told[key] = #list
    log(text:format(concat(list, ", ", from)))
end

-- When the changed places are looked at next without a reason: while there are any, every CheckSeconds.
local function schedule()
    S.nextCheck = (S.count > 0 and Cfg.CheckSeconds > 0) and (clock() + Cfg.CheckSeconds) or nil
end

local function finish()
    local P, why = S.pass, S.why
    S.queue, S.passes = nil, S.passes + 1
    tally()
    publish()

    local lost = #S.missing + #S.gone
    note("magic.objects", lost == 0 and "all found" or (lost .. " not found"),
        lost > 0 and (concat(S.missing, ", ") .. (#S.gone > 0 and ("; gone: " .. concat(S.gone, ", ")) or "")) or nil)
    note("magic.properties", #S.lacking == 0 and "all there" or (#S.lacking .. " not there"), #S.lacking > 0 and concat(S.lacking, ", ") or nil)
    note("magic.others", #S.others == 0 and "none" or (#S.others .. " value(s)"), #S.others > 0 and concat(S.others, ", ") or nil)
    note("magic.applied", ("%d value(s) in %d object(s)"):format(S.count, S.holders))
    if P.held + P.reset > 0 then
        local key = why.world and "magic.after_load" or (why.check and "magic.between_loads" or nil)
        if key then note(key, P.reset > 0 and "reset" or "kept", P.reset .. " of " .. (P.held + P.reset) .. " value(s)") end
    end
    local line = ("%d value(s) changed, %d put back: %d value(s) in %d object(s) of the game hold the module's numbers now")
        :format(P.changed, P.restored, S.count, S.holders)
    if DIAG then
        local reasons = {}
        for _, r in ipairs({ "start", "settings", "world", "check" }) do if why[r] then reasons[#reasons + 1] = r end end
        -- a look only by CheckSeconds that found every number in place says nothing new: no line (one a minute
        -- pushed everything else out of the recorder's last lines)
        local quiet = #reasons == 1 and why.check and P.changed == 0 and P.restored == 0 and P.failed == 0 and P.reset == 0
        if not quiet then
            DIAG.event(("look %d (%s): %d object(s), %s; %d failed, %d reset by the game"):format(S.passes, concat(reasons, ", "), P.looked, line, P.failed, P.reset))
        end
    end

    if P.changed + P.restored > 0 and (Cfg.LogChanges or not S.said) then
        S.said = true
        log(line)
    end
    if P.reset > 0 then
        L.once("reset", ("the game had put %d number(s) back to its own (%s); they are set again whenever that is seen")
            :format(P.reset, why.world and "after a map change" or "without a map change"))
    end
    tell(S.missing, "missing", "not found in this game: %s - what these would change stays as the game has it")
    tell(S.gone, "gone", "no longer there: %s - they cannot be searched again in this run; their numbers are the game's affair now")
    tell(S.lacking, "lacking", "not there in this game: %s - the settings for them change nothing")
    if #S.others > 0 then
        L.once("others", ("%d number(s) were changed by something else (another mod?) and are left alone, first %s; the status lists them")
            :format(#S.others, S.others[1]))
    end
    if why.settings and Cfg.ShowMessage and P.changed + P.restored + P.failed > 0 then
        local text = "Magic: nothing is changed"
        if S.count > 0 then
            text = ("Magic: %d value(s) changed"):format(S.count)
        elseif P.restored > 0 then
            text = "Magic: the game's own values are back"
        end
        if P.failed > 0 then text = text .. (", %d could not be set"):format(P.failed) end
        KIT.notify(text, "magic")
    end
    schedule()
end

-- Starts a look: every object a setting concerns, every object that holds a number of the module, and every
-- object an earlier run of the Lua mods left changed.
local function plan()
    local queue = {}
    for _, rec in ipairs(Objects) do
        if rec.state ~= "missing" and rec.state ~= "gone" and (needs(rec) or rec.ours or rec.inherited) then queue[#queue + 1] = rec end
    end
    local why, pass = S.asked, S.queue and S.pass or nil
    S.asked = nil
    if pass then
        -- a look that is under way starts over: what it was for and what it has done still count
        for reason in pairs(S.why) do why[reason] = true end
        pass.looked = 0
    elseif #queue == 0 then
        return
    end
    S.why, S.queue, S.at = why, queue, 1
    S.pass = pass or { looked = 0, changed = 0, restored = 0, failed = 0, reset = 0, held = 0 }
end

local function work()
    local queue, budget = S.queue, Cfg.SearchesPerLook
    while S.at <= #queue do
        local rec = queue[S.at]
        if rec.state == nil then
            if budget <= 0 then
                -- the rest at the next look: a search costs milliseconds. What was written so far is made known
                -- now, so that a reload of the Lua mods before the end of this look finds it.
                if S.unsaved then publish() end
                return
            end
            budget = budget - 1
            find(rec)
        end
        if rec.state == "found" and alive(rec) then look(rec) end
        S.at = S.at + 1
    end
    finish()
end

local function tick()
    if KIT.loading() then return end
    local now = clock()
    if S.checkAt and now >= S.checkAt then
        S.checkAt = nil
        ask("world")
    end
    if S.nextCheck and now >= S.nextCheck then
        S.nextCheck = nil
        ask("check")
    end
    if S.asked then plan() end
    if S.queue then work() end
end

-- ---------------------------------------------------------------------------
-- Settings while the game runs
-- ---------------------------------------------------------------------------
-- Settings that change nothing in the game's data.
local QUIET = { ShowMessage = true, LogChanges = true, SearchesPerLook = true, CheckSeconds = true, LookMilliseconds = true }
Settings.onChange = function(_, changed, why)
    log(("settings changed (%s): %s"):format(why == "menu" and "in-game menu" or (why == "file" and "config.lua" or tostring(why)), summary()))
    for _, key in ipairs(changed) do
        if not QUIET[key] then ask("settings") end
        if key == "CheckSeconds" then schedule() end
    end
    if not Cfg.ShowMessage then KIT.hideToast("magic") end
end

-- ---------------------------------------------------------------------------
-- Status (console command magic, the button of the in-game menu, the loader's
-- reports). Built from what the module holds; it does not call into the game.
-- ---------------------------------------------------------------------------
local function statusLines()
    local lines = { ("v%s | %s"):format(VERSION, summary()) }
    if S.count > 0 then
        local parts = {}
        for _, word in ipairs(WORD_ORDER) do
            if S.by[word] then parts[#parts + 1] = word .. " " .. S.by[word] end
        end
        lines[#lines + 1] = ("changed right now: %d value(s) in %d object(s) of the game (%s)"):format(S.count, S.holders, concat(parts, ", "))
    elseif anyNeeds() then
        lines[#lines + 1] = "nothing is changed right now"
    else
        lines[#lines + 1] = "nothing is changed: the game's own numbers are in place and the game is not looked at"
    end
    if S.queue then lines[#lines + 1] = ("still at work: %d of %d object(s) looked at"):format(S.at - 1, #S.queue) end
    if #S.missing > 0 then lines[#lines + 1] = "not found in this game: " .. concat(S.missing, ", ") end
    if #S.gone > 0 then lines[#lines + 1] = "no longer there: " .. concat(S.gone, ", ") end
    if #S.lacking > 0 then lines[#lines + 1] = "not there in this game: " .. concat(S.lacking, ", ") end
    if S.failed > 0 then lines[#lines + 1] = ("writes that did not stay: %d"):format(S.failed) end
    if #S.others > 0 then lines[#lines + 1] = ("changed by something else and left alone: %d (%s)"):format(#S.others, concat(S.others, ", ")) end
    if #S.shifted > 0 then lines[#lines + 1] = "another shape than at the first look, left alone: " .. concat(S.shifted, ", ") end
    return lines
end
-- One line for every object that holds a number of the module: place, the game's number -> the module's.
local function valueLines()
    local lines = {}
    for _, rec in ipairs(Objects) do
        local parts = {}
        for _, key in ipairs(rec.order or {}) do
            local slot = rec.slots[key]
            if slot.ours ~= nil and slot.other == nil then parts[#parts + 1] = ("%s %s -> %s"):format(key, show(slot.orig), show(slot.ours)) end
        end
        if #parts > 0 then lines[#lines + 1] = rec.name .. ": " .. concat(parts, ", ") end
    end
    return lines
end

local function say(lines, device)
    for _, l in ipairs(lines) do
        log(l)
        if device ~= nil then pcall(function() device:Log("[" .. TAG .. "] " .. l) end) end
    end
end

local function console(fullCommand, params, device)
    local args = {}
    if type(params) == "table" then
        for _, p in ipairs(params) do args[#args + 1] = tostring(p) end
    elseif type(fullCommand) == "string" then
        for w in fullCommand:gmatch("%S+") do args[#args + 1] = w end
        table.remove(args, 1)
    end
    local word = (args[1] or ""):lower()
    if word == "reload" then
        local ok, why = Settings:reload(true)
        say({ ok and ("settings read: " .. summary()) or ("settings not read: " .. tostring(why)) }, device)
    else
        say(statusLines(), device)
        if word == "values" then say(valueLines(), device) end
    end
    return true
end

Settings.onAction = function(key)
    if key ~= "Status" then return end
    local lines = statusLines()
    say(lines)
    say(valueLines())
    if Cfg.ShowMessage then KIT.notify(("Magic: %d value(s) changed in %d object(s); the list is in UE4SS.log"):format(S.count, S.holders), "magic") end
end

-- ---------------------------------------------------------------------------
-- Registration (each exactly once)
-- ---------------------------------------------------------------------------
-- A map change: the changed places are looked at again when it is over.
KIT.onWorldChange(function() S.checkAt = clock() + SETTLE end)
for _, name in ipairs({ "magic", "g1r_magic" }) do
    if type(RegisterConsoleCommandHandler) == "function" then
        pcall(RegisterConsoleCommandHandler, name, console)
    end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; the magic balancing is disabled.")
    return
end
LoopInGameThreadWithDelay(Cfg.LookMilliseconds, function()
    local ok, err = pcall(tick)
    if not ok then L.once("tick:" .. tostring(err), "update error: " .. tostring(err)) end
end)

-- What an earlier run of the Lua mods left in the game (they were reloaded while the game ran).
S.ledgerText = shared(LEDGER)
local left = type(S.ledgerText) == "string" and inherit(S.ledgerText) or 0
note("magic.inherited", left == 0 and "none" or (left .. " value(s)"))
if left > 0 then log(("%d value(s) of the game still hold numbers from before the Lua mods were reloaded; they are taken over"):format(left)) end
ask("start")            -- the first look: at what the settings want changed and at what an earlier run left
log(("v%s loaded: %s"):format(VERSION, summary()))

if DIAG then
    pcall(function()
        DIAG.status(statusLines)
        DIAG.dump(function()
            local objects = {}
            for _, rec in ipairs(Objects) do
                if rec.state then
                    local slots = {}
                    for _, key in ipairs(rec.order or {}) do
                        local slot = rec.slots[key]
                        slots[key] = { orig = slot.orig, ours = slot.ours, other = slot.other, failed = slot.failed }
                    end
                    objects[rec.name] = { kind = rec.kind, state = rec.state, shape = rec.shape, shifted = rec.shifted or nil, slots = slots }
                end
            end
            return {
                version = VERSION, enabled = Cfg.Enabled, summary = summary(), whole_mana = Cfg.WholeMana,
                changed_values = S.count, changed_objects = S.holders, by_kind = S.by, failed_writes = S.failed,
                changed_by_others = S.others, other_shape = S.shifted, not_found = S.missing, gone = S.gone, not_there = S.lacking,
                looks = S.passes, searches = S.searches, at_work = S.queue ~= nil, objects = objects,
            }
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "MAGIC_TEST")) == "table" then
    local T = rawget(_G, "MAGIC_TEST")
    T.state, T.objects, T.console, T.status, T.values, T.tick, T.settings = S, Objects, console, statusLines, valueLines, tick, Settings
    T.num, T.same, T.summary = num, same, summary
end
