-- ============================================================================
-- The game's own numbers for spells, as the tests of the module magic model
-- them. Data only; harness.lua builds the objects from it, and
-- facts_rows.lua writes the "expected" column of dev/facts/magic.md from it.
--
-- Where each number is from (status words of dev/FACTS.md):
--   SOURCE   the game's scripts, decompiled (as-src):
--            Items/Projectiles.as        spell definitions (m_DamageBase, AddDamageForMagicCircle, m_Speed,
--                                        m_SuperArmorDamageBase)
--            Spells/*.as                 spell configs (AddSpellLevel(mana, time, held), m_AreaRange); `reach = true`
--                                        marks the eleven whose m_AreaRange the scripts use for the spell itself:
--                                        the trace range of the eight target spells (USpellTraceConfigBase,
--                                        GA_TraceTarget_Base.as 32, GA_CastSpell_Targetable.as 63), the radius the
--                                        hit sphere grows to (StormFistVisual.as 32, DeathToTheUndeadVisual.as 33,
--                                        GA_Spell_UrizielWaveOfDeath.as 82)
--            GAS/Effects/Damage/Ice/     the three ice hit effects (one entry in m_ElementalEffectStacks, flag false)
--            GAS/Effects/Debuffs/GE_Damage.as   the entry every hit effect has in m_CommonElementalEffectStacks
--            GAS/Effects/Skills/GE_Skills.as    SPCost of the magic circles
--   IN-GAME  another author's mod (G1R_MageBalance 0.9.0) found the object and printed numbers it read from it in
--            the session of 2026-10-01 (UE4SS.log lines 1136-1177). `seen` says what the log shows for the object:
--            the base damage it read; for the spells it scaled by a factor also the steps (its targets are the
--            read numbers times the factor); m_Speed of the ball lightning levels; m_SuperArmorDamageBase of the
--            fist of wind; the six circle prices; for ten configs only that they exist.
--   UNKNOWN  what no script sets: the class default of m_Speed (1500 was printed for BallLightningDefinition_Base,
--            so that is used for every definition that sets none), of m_SuperArmorDamageBase and of m_AreaRange
--            (0 is used here; the module only multiplies what it reads). Marked in `guess`.
--
-- A step is { circle, damage }: the caster's magic circle from which the number counts
-- (USpellProjectileDefinition::GetDamageByCharacterMagicCircle, read from the executable).
-- ============================================================================

local Game = {}

local function def(name, tag, base, steps, speed, stagger, more)
    local d = { name = name, tag = tag, base = base, steps = steps or {}, speed = speed or 1500, stagger = stagger or 0, guess = {} }
    if speed == nil then d.guess.speed = true end
    if stagger == nil then d.guess.stagger = true end
    for k, v in pairs(more or {}) do d[k] = v end
    return d
end

Game.definitions = {
    def("FireBoltProjectileDefinition", "Fire", 35, { { 2, 40 }, { 4, 50 }, { 6, 65 } }, 4000, 30, { seen = "its base damage" }),
    def("FireBallProjectileDefinition_Lvl1", "Fire", 90, { { 4, 110 }, { 5, 130 }, { 6, 150 } }, 3000, 20, { seen = "its damage numbers" }),
    def("FireBallProjectileDefinition_Lvl2", "Fire", 110, { { 4, 130 }, { 5, 150 }, { 6, 170 } }, 3000, 50, { seen = "its damage numbers" }),
    def("FireBallProjectileDefinition_Lvl3", "Fire", 130, { { 4, 150 }, { 5, 170 }, { 6, 200 } }, 3000, 100, { seen = "its damage numbers" }),
    def("PyrokinesisProjectileDefinition", "Fire", 20, { { 5, 35 } }, nil, nil, { seen = "its damage numbers" }),
    def("StormOfFireDefinition", "Fire", 250, { { 6, 300 } }, 300, 10, { seen = "its damage numbers" }),
    def("FireRainDefinition", "Fire", 50, nil, nil, 0, { seen = "its damage numbers" }),
    def("IceBoltProjectileDefinition", "Ice", 20, { { 2, 30 }, { 4, 40 }, { 6, 50 } }, 4000, nil, { seen = "its base damage" }),
    def("IceBlockProjectileDefinition", "Ice", 60, { { 5, 80 }, { 6, 100 } }),
    def("IceWaveProjectileDefinition", "Ice", 120, { { 6, 150 } }),
    def("BallLightningDefinition_Lvl1", "Energy", 70, { { 4, 90 }, { 5, 110 }, { 6, 130 } }, 300, nil, { seen = "its flight speed" }),
    def("BallLightningDefinition_Lvl2", "Energy", 90, { { 4, 110 }, { 5, 130 }, { 6, 150 } }, 350, nil, { seen = "its flight speed" }),
    def("BallLightningDefinition_Lvl3", "Energy", 110, { { 4, 130 }, { 5, 150 }, { 6, 170 } }, 400, nil, { seen = "its flight speed" }),
    def("BallLightningDefinition_Lvl4", "Energy", 150, { { 4, 170 }, { 5, 200 }, { 6, 220 } }, 450, nil, { seen = "its flight speed" }),
    def("LightningRayDefinition_Base", "Energy", 20, { { 5, 35 }, { 6, 45 } }, nil, nil, { seen = "its damage numbers" }),
    def("LightningRayDefinition_WithParalysis", "Energy", 20, { { 5, 35 }, { 6, 45 } }, nil, nil, { seen = "its damage numbers" }),
    def("LightningRayDefinition_WithoutParalysis", "Energy", 20, { { 5, 35 }, { 6, 45 } }, nil, nil, { seen = "its damage numbers" }),
    def("UrizielWaveOfDeathVisualDefinition", "Energy", 90, nil, nil, nil, { seen = "its damage numbers" }),
    def("DeathToTheUndeadDefinition", "Energy", 500, nil, nil, nil, { seen = "its damage numbers" }),
    def("WindFistDefinition", "Wind", 20, { { 2, 30 }, { 4, 40 }, { 5, 50 }, { 6, 70 } }, nil, 200, { seen = "its base damage, the first three steps and its force against a foe's stance" }),
    def("StormFistDefinition", "Wind", 120, { { 6, 160 } }, nil, 250),
    def("BreathOfDeathDefinition", "Wind", 150, nil, nil, nil, { seen = "its damage numbers" }),
}

-- levels: { mana, time, held } as in AddSpellLevel(NewCastManaCost, NewCastTime, NewManaCostSc, ...)
local function cfg(name, levels, range, more)
    local c = { name = name, levels = levels, range = range or 0, guess = {} }
    if range == nil then c.guess.range = true end
    for k, v in pairs(more or {}) do c[k] = v end
    return c
end

Game.configs = {
    -- the fifteen damage spells
    cfg("ProjectileSpellConfig_FireBolt", { { 1, 0.1, 1 } }, nil, { seen = "that the object exists" }),
    cfg("ProjectileSpellConfig_FireBall", { { 1, 0.4, 0 }, { 2, 0.6, 0 }, { 2, 0.8, 2 } }, nil, { seen = "that the object exists" }),
    cfg("PyrokinesisSpellConfig", { { 5, 0.5, 1 } }, 1500, { reach = true }),
    cfg("StormOfFireSpellConfig", { { 30, 0.5, 0 } }, nil, { seen = "that the object exists" }),
    cfg("FireRainSpellConfig", { { 20, 0.1, 0 } }, nil, { seen = "that the object exists" }),
    cfg("ProjectileSpellConfig_IceBolt", { { 1, 0.1, 1 } }),
    cfg("IceBlockSpellConfig", { { 3, 0.2, 0 } }, 720),
    cfg("IceWaveSpellConfig", { { 15, 0.2, 0 } }, 600, { seen = "that the object exists" }),
    cfg("ProjectileSpellConfig_BallLightning", { { 5, 0.3, 0 }, { 1, 1.03, 0 }, { 1, 1.03, 0 }, { 2, 1.03, 0 } }, nil, { seen = "that the object exists" }),
    cfg("ChainLightningSpellConfig", { { 5, 0.5, 1 } }, 1500, { reach = true }),
    cfg("UrizielWaveOfDeathSpellConfig", { { 40, 0.3, 0 } }, 750, { seen = "that the object exists", reach = true }),
    cfg("DeathToTheUndeadSpellConfig", { { 25, 0.5, 0 } }, 500, { seen = "that the object exists", reach = true }),
    cfg("FistOfWindSpellConfig", { { 2, 0, 0 } }, 700),
    cfg("StormFistSpellConfig", { { 10, 0.5, 0 } }, 700, { seen = "that the object exists", reach = true }),
    cfg("BreathOfDeathSpellConfig", { { 15, 0.5, 0 } }, 1000, { seen = "that the object exists" }),
    -- spells without damage: runes
    cfg("HealSpellConfig", { { 2, 0.1, 1 } }, 1500, { heal = { 4, 4, 4, 6, 10, 15, 20, 30 }, reach = true }),
    cfg("LightSpellConfig", { { 5, 0.25, 0 } }),
    cfg("SleepSpellConfig", { { 3, 0.5, 0 } }, 1500, { reach = true }),
    cfg("CharmSpellConfig", { { 5, 0.5, 0 } }, 1500, { reach = true }),
    cfg("TelekinesisSpellConfig", { { 3, 1, 1 }, { 3, 1, 1 } }, 1500, { reach = true }),
    cfg("ControlSpellConfig", { { 5, 0.5, 4 } }, 2000, { reach = true }),
    -- scrolls only
    cfg("FearSpellConfig", { { 5, 0.5, 0 } }, 1000),
    cfg("ShrinkSpellConfig", { { 5, 0.5, 0 } }, 1500, { reach = true }),
    cfg("InnosPraySpellConfig", { { 5, 0.1, 0 } }),
    -- teleports
    cfg("TeleportSpellConfig_MagiciansOfFire", { { 5, 4, 0 } }, 300),
    cfg("TeleportSpellConfig_SwampCamp", { { 5, 4, 0 } }, 300),
    cfg("TeleportSpellConfig_MagiciansOfWater", { { 5, 4, 0 } }, 300),
    cfg("TeleportSpellConfig_Necromancer", { { 5, 4, 0 } }, 300),
    cfg("TeleportSpellConfig_OrcCementery", { { 5, 4, 0 } }, 300),
    cfg("TeleportSpellConfig_SleepersTemple", { { 5, 4, 0 } }, 300),
    cfg("TeleportSpellConfig_SunkenTower", { { 5, 4, 0 } }, 300),
    -- summoning
    cfg("SummonSpellConfig_Skeletons", { { 10, 0.5, 0 } }),
    cfg("SummonSpellConfig_Golem", { { 15, 0.5, 0 } }),
    cfg("SummonSpellConfig_Demon", { { 20, 0.5, 0 } }),
    cfg("SummonSpellConfig_ArmyOfDarkness", { { 25, 0.5, 0 } }),
}
-- transformation scrolls: mana only, cast at once
for _, t in ipairs({ { "Meatbug", 5 }, { "Scavenger", 5 }, { "Molerat", 5 }, { "Bloodfly", 10 }, { "Wolf", 10 }, { "Lizard", 15 },
    { "Lurker", 15 }, { "OrcDog", 20 }, { "Minecrawler", 20 }, { "Snapper", 25 }, { "Biter", 30 }, { "Razor", 35 },
    { "Bloodhound", 35 }, { "FireLizard", 35 }, { "Shadowbeast", 50 }, { "Harpy", 60 }, { "Swampshark", 60 } }) do
    Game.configs[#Game.configs + 1] = cfg("Transform" .. t[1] .. "SpellConfig", { { t[2], 0, 0 } })
end

-- hit effects of the ice spells: m_ElementalEffectStacks has the ice counter (UGE_IceStack, 50 stacks, overflow =
-- frozen for 8 s), m_CommonElementalEffectStacks the counter of hits on a frozen foe (inherited from UGE_Damage)
Game.effects = {
    { name = "GE_IceBolt_Damage", stacks = { false }, common = { false } },
    { name = "GE_IceBlock_Freeze_Damage", stacks = { false }, common = { false }, seen = "that writing the flag of its entries does not raise" },
    { name = "GE_IceWave_Freeze_Damage", stacks = { false }, common = { false } },
}
Game.ICE_STACK_LIMIT = 50

Game.skills = {
    { name = "GE_Skill_Mage_Circle_Amateur", cost = 5 },
    { name = "GE_Skill_Mage_Circle_1", cost = 10, seen = "this number" },
    { name = "GE_Skill_Mage_Circle_2", cost = 15, seen = "this number" },
    { name = "GE_Skill_Mage_Circle_3", cost = 20, seen = "this number" },
    { name = "GE_Skill_Mage_Circle_4", cost = 25, seen = "this number" },
    { name = "GE_Skill_Mage_Circle_5", cost = 30, seen = "this number" },
    { name = "GE_Skill_Mage_Circle_6", cost = 40, seen = "this number" },
}

-- A number as the module writes it into its notes: at most three places, no trailing zeros.
function Game.num(v)
    local s = ("%.3f"):format(v):gsub("0+$", "")
    if s:sub(-1) == "." then s = s:sub(1, -2) end
    return s
end

-- The text of the note magic.original.<name> for an object with these numbers.
function Game.originalText(o)
    local num = Game.num
    if o.base ~= nil then
        local steps = {}
        for _, s in ipairs(o.steps) do steps[#steps + 1] = num(s[2]) end
        return ("base %s, steps %s, speed %s, stagger %s"):format(num(o.base), #steps > 0 and table.concat(steps, " ") or "-", num(o.speed), num(o.stagger))
    elseif o.levels ~= nil then
        local levels = {}
        for _, l in ipairs(o.levels) do levels[#levels + 1] = ("%s %s %s"):format(num(l[1]), num(l[2]), num(l[3])) end
        local text = "levels " .. table.concat(levels, " / ")
        if o.reach then text = text .. ", range " .. num(o.range) end
        if o.heal then
            local h = {}
            for _, v in ipairs(o.heal) do h[#h + 1] = num(v) end
            text = text .. ", heal " .. table.concat(h, " ")
        end
        return text
    elseif o.stacks ~= nil then
        local flags = {}
        for _, f in ipairs(o.stacks) do flags[#flags + 1] = tostring(f) end
        return table.concat(flags, " ")
    end
    return num(o.cost)
end

return Game
