-- ============================================================================
-- Mining rework (module mining of G1R_MegaMod) - Gothic 1 Remake, UE4SS Lua
--
-- What a swing of the pickaxe gives, and how long a vein lasts:
--   * ore per swing = base amount + 1 for every so many points of Strength
--     + 1 for every so many points of Dexterity + a bonus for a trained or a
--     master miner, between a lowest and a highest amount, with a chance of
--     one more;
--   * veins that never run out, or that last several times as long.
-- With the settings the mod ships with nothing is changed and the game is not
-- looked at at all.
--
-- How it works. The game keeps its mining numbers in one object (the default
-- object of the class its world definition names as "mining definition"): how
-- much a swing gives from a full vein, how much from a nearly empty one, and
-- from how many ore on a vein counts as full. The game's mining ability reads
-- them from there at the end of every swing and then moves that much ore
-- from the vein to the hero, never more than the vein holds. This module
-- writes the first two numbers (each write is read back; the game's own
-- values are remembered and put back when the setting goes back) - so the ore
-- reaches the hero the game's own way and only through a swing at a vein.
-- Nothing is hooked, no item is ever handed to the hero by the module.
--
-- A swing is seen by looking, four times a second, at the hero's one mining
-- ability object: active or not, and which vein it is aimed at. While it is
-- active the vein's ore is counted at every look: the swing is over when the
-- ability is at rest, and also when the vein holds less than before (the
-- game has handed the ore out; the ability may stay active for a while, or
-- be started anew before the next look - then the next swing begins at
-- once) or the ability is aimed at another vein. When a swing begins the
-- amount is worked out anew (attributes, skill, the roll for the extra ore).
-- For veins that never run out the vein is then filled up to "what the game
-- gave it when it was new + the amount of this swing" - a level, not an
-- addition, so that starting and breaking off swings piles nothing up. (A
-- vein of 15 that was mined down before is kept at 14 for one swing: the
-- game redraws a vein at the end of a swing only while it holds fewer than
-- 15, and the vein would go on looking empty otherwise.) For veins that last
-- longer, the fitting part of what the swing really took is put back after
-- it. Ore is put into a vein with the game's own function for its container
-- (else by writing the count of its first slot), and counted again
-- afterwards; a way that leaves the count where it was is not used again in
-- this run.
--
-- One mining mod at a time: the loader does not load this module while the
-- mod BetterMining is enabled.
--
-- Settings: schema.lua describes them, config.lua holds them; the settings
-- app and the in-game mod menu change them while the game runs.
-- ============================================================================

local VERSION = "1.0.0"
local TAG = "G1R_Mining"

local KIT, SETTINGS = G1R_KIT, G1R_SETTINGS
-- Diagnostics handle of the loader; nil when the diagnostics are off, and then
-- nothing behind `if DIAG` runs.
local DIAG = G1R_DIAG
if type(KIT) ~= "table" or type(SETTINGS) ~= "table" then
    print("[" .. TAG .. "] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started\n")
    return
end
if DIAG then pcall(DIAG.version, VERSION) end

local pcall, type, tostring, tonumber, ipairs = pcall, type, tostring, tonumber, ipairs
local floor, min, max = math.floor, math.min, math.max
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
-- What the module knows about the game (dev/facts/mining.md)
-- ---------------------------------------------------------------------------
local ABILITY = "GameplayAbilityMining"         -- the hero's mining ability: bIsActive, m_InteractiveActor (the vein)
local CONTAINER = "DataModule_Container"        -- the part of a vein that holds its ore
local CONFIG = "MiningConfig"                   -- the game's script class with the mining numbers (by path: the second way)
local ORE = "ItMi_Orenugget"                    -- the ore item's script class (by path: the second way)
local MAIN = 1                                  -- EInventoryTypes: MainContainer
local RANKS = {                                 -- the game's mining skill: a tag on the hero's ability system
    { name = "master", tag = "Skill.Mining.Master" },
    { name = "trained", tag = "Skill.Mining.Trained" },
}
-- The two amounts the mining ability reads at every swing, and what they are called here.
local NUMBERS = {
    { key = "high", property = "m_AmountAtHighOre" },   -- from a vein with more than m_HighOre ore
    { key = "low", property = "m_AmountAtLowOre" },     -- from a vein with m_HighOre ore or fewer
}
local SHARED = "G1R_Mining:original"    -- UE4SS shared variable: the game's own two amounts while the module has changed them
local LIMIT = 100000                    -- a mining number or an ore count beyond this is not taken for one
local TRIES = 3                         -- looks at the short way before the long one is taken; failures before giving up
local PAUSE_FIRST, PAUSE_MAX = 5, 60    -- seconds between two tries of something that was not found (growing)
-- The search for the hero's mining ability among all objects of the game is the long way, taken when his own
-- list of abilities does not show it. The hero of the main menu has no such ability, and in a logged session
-- of megamod 0.2.1 that search ran once a minute for the 40 minutes the game sat in the menu. Its pauses grow
-- further than the others': a walk through all objects is not something to repeat every minute. (The hero's
-- own list goes on being read at the pauses above.)
local SCAN_PAUSE_MAX = 600
local AT_ONCE = -math.huge              -- a clock value that has passed: due at the next look

-- ---------------------------------------------------------------------------
-- State of this run
-- ---------------------------------------------------------------------------
local S = {
    awake = nil,                -- the module is looking at the game (set by rest())
    hero = nil, heroAt = nil,   -- full name of the hero's player state when it was last asked for, and when it is asked again
    config = nil,               -- the object the game reads its mining numbers from, its full name, how it was found
    configName = nil, configVia = nil,
    configTries = 0, configAt = AT_ONCE, configPause = PAUSE_FIRST,
    game = nil,                 -- the game's own numbers: { high, low, threshold, drawn (may be nil) }
    holds = {},                 -- the two amounts as the config holds them now: { high, low }
    dirty = false,              -- the config holds (or may hold) amounts of the module: they have to be put back
    wrote = false,              -- the last look left amounts of the module in the config
    backFails = 0,              -- tries in a row at putting the game's own amounts back that did not work
    yieldOff = nil,             -- why the ore per swing cannot be changed in this run (a write did not stay)
    ore = nil, oreVia = nil,    -- the ore item's class (false: searched and not found)
    strength = nil, dexterity = nil, rank = nil,    -- what the amount was last worked out from
    amount = nil, extra = nil,  -- the ore per swing by the settings, and the extra ore rolled for the swing in progress
    waiting = nil, waits = 0,   -- what of the hero could not be read at the last tries, and how often in a row
    tagFails = 0, tagsOff = false,
    refreshAt = nil,            -- the clock value of the next look at the hero's attributes
    ability = nil,              -- { object, name, via }: the hero's mining ability
    abilityTries = nil, abilityAt = nil, abilityPause = nil,    -- its search (set by rest())
    scanAt = nil, scanPause = nil,                              -- the search among all objects: when it may be made next
    swing = nil,                -- the swing in progress
    veins = {},                 -- full name -> { owed, first, reduced }: the veins swung at in this world
    countWay = nil,             -- how a vein's ore is counted: "function" / "slots"
    addFailed = {}, addOff = false,     -- ways of putting ore into a vein that did not work; none works
    swings = 0, ore_given = 0, game_gives = 0, putBack = 0, extras = 0, last = nil,
    told = false,               -- the first swing with ore has gone to the session log
}
local Noted = {}
local function note(key, value, detail)
    if DIAG and Noted[key] ~= value then
        Noted[key] = value
        DIAG.note(key, value, detail)
    end
end
-- A line that is on disk before a step into the game is taken for the first
-- time: should the game end inside it, the session log ends with this line.
local Announced = {}
local function crumb(text)
    if DIAG and not Announced[text] then
        Announced[text] = true
        DIAG.crumb(text)
    end
end

-- The first line of an error text, without the "file:line:" in front.
local function reason(text) return ((tostring(text):match("^[^\r\n]*") or ""):gsub("^.-:%d+: ", "")) end
-- A number as short as it can be written: 4, 2.5
local function num(v) return (("%.1f"):format(v):gsub("%.0$", "")) end
-- The last part of an object's full name ("... PersistentLevel.BP_Vein_C_12" -> "BP_Vein_C_12").
local function short(name) return tostring(name):match("([^%.:/%s]+)$") or tostring(name) end
-- A whole number from 0 to LIMIT, or nil.
local function whole(v)
    v = KIT.number(v)
    if v == nil or v < 0 or v > LIMIT then return nil end
    return floor(v + 0.5)
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local Settings, problem = SETTINGS.open({ module = "mining", dir = SCRIPT_DIR, log = log })
if not Settings then
    log("the settings could not be set up (" .. tostring(problem) .. "); not started")
    return
end
local Cfg = Settings.values

-- True while there is nothing to change at all: the game is not looked at.
local function idle()
    return not Cfg.Enabled or not (Cfg.YieldEnabled or Cfg.EndlessVeins or Cfg.VeinLastsTimes > 1)
end
-- True when swings have to be seen (a vein to fill, a roll to make, something to say).
local function watching()
    return Cfg.EndlessVeins or Cfg.VeinLastsTimes > 1 or Cfg.ShowMessage or Cfg.LogSwings or Cfg.ExtraChance > 0
end
local function top() return max(Cfg.MaxAmount, Cfg.MinAmount) end
local function yieldText()
    local parts = { ("base %d"):format(Cfg.BaseAmount) }
    if Cfg.StrengthPerOre > 0 then parts[#parts + 1] = ("+1 per %s Strength"):format(num(Cfg.StrengthPerOre)) end
    if Cfg.DexterityPerOre > 0 then parts[#parts + 1] = ("+1 per %s Dexterity"):format(num(Cfg.DexterityPerOre)) end
    if Cfg.TrainedBonus > 0 then parts[#parts + 1] = ("+%d for a trained miner"):format(Cfg.TrainedBonus) end
    if Cfg.MasterBonus > 0 then parts[#parts + 1] = ("+%d for a master miner"):format(Cfg.MasterBonus) end
    if Cfg.ExtraChance > 0 then parts[#parts + 1] = ("%d%% chance of one more"):format(Cfg.ExtraChance) end
    parts[#parts + 1] = ("%d to %d"):format(Cfg.MinAmount, top())
    if not Cfg.LowVeinRule then parts[#parts + 1] = "the same from a nearly empty vein" end
    return "ore per swing: " .. table.concat(parts, ", ")
end
local function summary()
    if not Cfg.Enabled then return "switched off in the settings" end
    if idle() then return "nothing to change (ore per swing and veins as the game has them)" end
    local parts = {}
    if Cfg.YieldEnabled then parts[#parts + 1] = yieldText() end
    if Cfg.EndlessVeins then
        parts[#parts + 1] = "veins never run out"
    elseif Cfg.VeinLastsTimes > 1 then
        parts[#parts + 1] = ("a vein lasts %d times as long"):format(Cfg.VeinLastsTimes)
    end
    return table.concat(parts, "; ")
end

-- ---------------------------------------------------------------------------
-- The amount a swing gives by the settings
-- ---------------------------------------------------------------------------
-- One more ore for every `per` points (0 = none). The game keeps attributes
-- as numbers with a fraction part: a hair below a whole number is that number.
local function share(points, per)
    if per <= 0 then return 0 end
    return floor((points + 0.001) / per)
end
-- strength / dexterity: the hero's (not looked at where the settings do not
-- ask for it); rank: "master" / "trained" / nil; extra: 0 or 1.
local function amountFor(strength, dexterity, rank, extra)
    local amount = Cfg.BaseAmount + share(strength, Cfg.StrengthPerOre) + share(dexterity, Cfg.DexterityPerOre)
    if rank == "master" then
        amount = amount + Cfg.MasterBonus
    elseif rank == "trained" then
        amount = amount + Cfg.TrainedBonus
    end
    return floor(min(max(amount, Cfg.MinAmount) + extra, top()))
end

-- A gameplay tag as the game takes it: a table with its name. Made once per
-- text; nil when this UE4SS cannot make a name.
local Tags = {}
local function tagOf(text)
    if not Tags[text] then
        local ok, name = pcall(FName, text)
        if ok and name ~= nil then Tags[text] = { TagName = name } end
    end
    return Tags[text]
end
-- The hero's rank as a miner ("master" / "trained"), or nil: asked from the
-- tags of his ability system.
local function rankOf()
    if S.tagsOff then return nil end
    local system = KIT.get((KIT.playerState()), "AbilitySystemComponent")
    crumb("first question for a gameplay tag of the hero (HasGameplayTag)")
    for _, r in ipairs(RANKS) do
        local ok, has = KIT.try(system, "HasGameplayTag", tagOf(r.tag))
        if not ok or type(has) ~= "boolean" then
            S.tagFails = S.tagFails + 1
            if S.tagFails >= TRIES then
                S.tagsOff = true
                local why = reason(ok and ("the answer was " .. tostring(has)) or has)
                L.once("tags", "the hero's mining skill cannot be asked (" .. why .. "); the bonus of a trained or master miner is not given")
                note("mining.skill_tags", "not readable", why)
            end
            return nil
        end
        if has then
            S.tagFails = 0
            note("mining.skill_tags", "readable")
            return r.name
        end
    end
    S.tagFails = 0
    note("mining.skill_tags", "readable")
    return nil
end
-- Reads what the settings ask for of the hero. False and what is missing
-- while something of it cannot be read.
local function readHero()
    local strength, dexterity, rank
    if Cfg.StrengthPerOre > 0 then
        strength = KIT.attribute("Strength", "Strength")
        if strength == nil then return false, "Strength" end
    end
    if Cfg.DexterityPerOre > 0 then
        dexterity = KIT.attribute("Dexterity", "Dexterity")
        if dexterity == nil then return false, "Dexterity" end
    end
    if Cfg.TrainedBonus > 0 or Cfg.MasterBonus > 0 then rank = rankOf() end
    S.strength, S.dexterity, S.rank = strength, dexterity, rank
    return true
end

-- ---------------------------------------------------------------------------
-- The game's mining numbers
-- ---------------------------------------------------------------------------
-- The game's own two amounts as an earlier run of the Lua mods left them in
-- the shared store (UE4SS can load its Lua mods anew while the game keeps
-- running - with the module's numbers still in the config), or nil.
local function remembered()
    local ok, text = pcall(function() return ModRef:GetSharedVariable(SHARED) end)
    if ok and type(text) == "string" then
        local high, low = text:match("^(%d+)/(%d+)$")
        if high then return tonumber(high), tonumber(low) end
    end
    return nil
end
local function remember(text)
    pcall(function() ModRef:SetSharedVariable(SHARED, text) end)
end

-- The object the mining ability reads its numbers from, and the world
-- definition that names it: asked the way the game asks, through the hero's
-- world.
local function throughWorld()
    local world = KIT.world()
    local gameState = KIT.get(world, "GameState")
    if KIT.valid(gameState) then crumb("first call of the game state's GetWorldDefinition") end
    local definition = KIT.call(gameState, "GetWorldDefinition", world)
    if not KIT.valid(definition) then definition = KIT.call(KIT.get(gameState, "m_WorldDefinition"), "GetCDO") end
    local config = KIT.call(KIT.get(definition, "m_MiningDefinition"), "GetCDO")
    if KIT.valid(config) then return config, definition end
    return nil
end

-- Takes a found object for the game's mining config when its numbers can be read.
local function takeConfig(config, via, definition)
    local name = KIT.fullName(config)
    local high, low = whole(KIT.get(config, NUMBERS[1].property)), whole(KIT.get(config, NUMBERS[2].property))
    local threshold = whole(KIT.get(config, "m_HighOre"))
    if not (name and high and low and threshold) then
        L.once("numbers", "the game's mining numbers could not be read from " .. tostring(name) .. "; mining stays as the game has it")
        note("mining.game_numbers", "not readable", name)
        return nil
    end
    S.config, S.configName, S.configVia = config, name, via
    S.holds = { high = high, low = low }
    local leftHigh, leftLow = remembered()
    if leftHigh then
        -- an earlier run of the Lua mods changed the amounts and could not put them back: these are the game's own
        high, low, S.dirty = leftHigh, leftLow, true
    end
    -- m_VisualMaxOre: with this much ore or more the game does not redraw a vein (nil when it cannot be read)
    S.game = { high = high, low = low, threshold = threshold, drawn = whole(KIT.get(config, "m_VisualMaxOre")) }
    note("mining.config_found_by", via)
    note("mining.game_numbers", ("%d/%d/%d"):format(high, low, threshold), name)
    local class = KIT.get(definition, "m_DefaultOre")
    if KIT.valid(class) then
        S.ore, S.oreVia = class, "world definition"
        note("mining.ore_class", S.oreVia)
    end
    return config
end

-- The config object, or nil while it cannot be had. Kept once found (it lives
-- as long as the game runs) and checked by name before every use.
local function findConfig(now)
    if S.config ~= nil then
        if KIT.valid(S.config) and KIT.fullName(S.config) == S.configName then return S.config end
        S.config, S.configName, S.game, S.holds = nil, nil, nil, {}        -- gone: found again the same way
    end
    if now < S.configAt then return nil end
    local config, definition = throughWorld()
    local via = "world definition"
    if not config then
        S.configTries = S.configTries + 1
        if S.configTries < TRIES then
            S.configAt = now + 1
            return nil
        end
        config, via = KIT.findDefault(CONFIG, "Angelscript"), "path"
    end
    -- should this look not give a usable object, the next one is some seconds away (a search by path is not repeated)
    S.configAt, S.configPause = now + S.configPause, min(S.configPause * 2, PAUSE_MAX)
    if config then return takeConfig(config, via, definition) end
    L.once("config", "the game's mining numbers were not found; mining stays as the game has it")
    note("mining.config_found_by", "not found")
    return nil
end

-- Brings the config's two amounts to `want`. Returns whether both are there
-- afterwards (each write is read back), and whether they were still what
-- the last look had left there.
local function setNumbers(config, want)
    local there, kept = true, true
    for _, n in ipairs(NUMBERS) do
        local have = whole(KIT.get(config, n.property))
        if have ~= S.holds[n.key] then kept = false end
        if have ~= want[n.key] then
            crumb("first write of one of the game's mining numbers")
            pcall(function() config[n.property] = want[n.key] end)
            have = whole(KIT.get(config, n.property))
            if have ~= want[n.key] then there = false end
        end
        S.holds[n.key] = have
    end
    return there, kept
end

-- Puts the wanted amounts into the config: the module's, or the game's own.
-- What does not stay is taken back, and the ore per swing is then left alone
-- for this run.
local function write(config, want)
    local game = S.game
    local own = want.high ~= game.high or want.low ~= game.low
    if own and not S.dirty then
        S.dirty = true
        remember(("%d/%d"):format(game.high, game.low))
    end
    local held = { high = S.holds.high, low = S.holds.low }
    local there, kept = setNumbers(config, want)
    if S.wrote then
        -- the module's amounts were in the config: were they still there at this look?
        note("mining.config_kept", kept and "yes" or "no", ("%s / %s left there, %s / %s wanted now"):format(tostring(held.high), tostring(held.low),
            tostring(want.high), tostring(want.low)))
    end
    S.wrote = own and there
    if there then
        if own then
            note("mining.config_write", "ok")
        elseif S.dirty then
            S.dirty, S.backFails = false, 0
            remember("")
        end
    elseif own then
        S.yieldOff = "the game's mining numbers could not be written"
        L.once("write", "the game's mining numbers could not be written (the value did not stay); the ore per swing stays as the game has it")
        note("mining.config_write", "failed", ("%s / %s wanted, %s / %s there"):format(tostring(want.high), tostring(want.low), tostring(S.holds.high), tostring(S.holds.low)))
        write(config, game)
    elseif S.dirty then
        -- the game's own amounts could not be put back
        S.backFails = S.backFails + 1
        if S.backFails >= TRIES then
            S.dirty = false
            L.once("back", "the game's own mining numbers could not be put back; they return when the game is started again")
            note("mining.config_write", "not put back")
        end
    end
end

-- Works the amount out anew and brings the config to it. `rolling`: a swing
-- begins - its extra ore is rolled. (While the config cannot be had this is
-- tried at every look; findConfig spaces its own tries.)
local function refresh(now, rolling)
    S.extra = 0
    local config = findConfig(now)
    if not config then return end
    S.refreshAt = now + Cfg.RefreshSeconds
    local want = { high = S.game.high, low = S.game.low }
    if Cfg.YieldEnabled and not S.yieldOff then
        local ok, missing = readHero()
        if not ok then
            -- the numbers stay as they are until the hero's values can be read
            S.waiting, S.waits, S.refreshAt = missing, S.waits + 1, now + 1
            if S.waits == 10 then
                L.once("hero:" .. missing, "the hero's " .. missing .. " cannot be read; the ore per swing stays as it is until it can")
                note("mining.attributes", "not readable", missing)
            end
            return
        end
        if S.strength or S.dexterity then note("mining.attributes", "readable") end
        S.waiting, S.waits = nil, 0
        local extra = (rolling and Cfg.ExtraChance > 0 and math.random() * 100 < Cfg.ExtraChance) and 1 or 0
        S.amount = amountFor(S.strength, S.dexterity, S.rank, 0)
        want.high = amountFor(S.strength, S.dexterity, S.rank, extra)
        S.extra = want.high - S.amount              -- 0 when the highest amount leaves no room for it
        if not Cfg.LowVeinRule then want.low = want.high end
    else
        S.amount = nil
    end
    write(config, want)
end

-- ---------------------------------------------------------------------------
-- The hero's mining ability
-- ---------------------------------------------------------------------------
-- From the hero's own list of abilities: the entry of the mining ability
-- holds the one object the game made of it for him.
local function fromList(state)
    local found = nil
    local system = KIT.get(state, "AbilitySystemComponent")
    KIT.each(KIT.get(KIT.get(system, "ActivatableAbilities"), "Items"), function(entry)
        if KIT.classToken(KIT.get(entry, "Ability")) ~= ABILITY then return false end
        for _, list in ipairs({ "NonReplicatedInstances", "ReplicatedInstances" }) do
            KIT.each(KIT.get(entry, list), function(object)
                if KIT.valid(object) and not KIT.isDefaultName(KIT.fullName(object)) then found = found or object end
            end)
        end
        return true     -- the hero has one mining ability: the rest of the list is not walked
    end)
    return found
end
-- By a search among all objects: the mining ability that sits directly inside
-- the hero's player state.
local function fromScan(stateName)
    local ok, list = pcall(FindAllOf, ABILITY)
    if not ok or type(list) ~= "table" then return nil end
    local owner = short(stateName)
    for _, object in ipairs(list) do
        local name = KIT.valid(object) and KIT.fullName(object) or nil
        if name and name:match("%.([^%.:/%s]+)%.[^%.:/%s]+$") == owner then return object end
    end
    return nil
end
-- The hero's mining ability, or nil while it cannot be had. Kept once found
-- and checked by name at every look. Searched in his own list; from the
-- third look in vain on, also among all objects, with growing pauses.
local function findAbility(now)
    local a = S.ability
    if a ~= nil then
        if KIT.valid(a.object) and KIT.fullName(a.object) == a.name then return a.object end
        S.ability, S.swing = nil, nil
        S.abilityTries, S.abilityAt, S.abilityPause = 0, AT_ONCE, PAUSE_FIRST
        S.scanAt, S.scanPause = AT_ONCE, PAUSE_FIRST
    end
    if now < S.abilityAt then return nil end
    local state, stateName = KIT.playerState()
    if not state then return nil end
    S.abilityTries, S.abilityAt = S.abilityTries + 1, now + 1
    local object, via = fromList(state), "ability list"
    if not object then
        if S.abilityTries < TRIES then return nil end
        if now >= S.scanAt then
            object, via = fromScan(stateName), "scan"
            if not object then S.scanAt, S.scanPause = now + S.scanPause, min(S.scanPause * 2, SCAN_PAUSE_MAX) end
        end
        if not object then
            S.abilityAt, S.abilityPause = now + S.abilityPause, min(S.abilityPause * 2, PAUSE_MAX)
            L.once("ability", "the hero's mining ability was not found (yet): swings are not seen - no vein is filled, nothing is said about a swing")
            return nil
        end
    end
    S.ability = { object = object, name = KIT.fullName(object), via = via }
    note("mining.ability_found_by", via)
    if Cfg.ShowMessage then KIT.prepareNotes() end      -- searches now, not in the middle of a swing
    return object
end

-- ---------------------------------------------------------------------------
-- Veins
-- ---------------------------------------------------------------------------
-- The vein the ability is aimed at, and how the game handed it out. UE4SS
-- gives a weak reference as a value with Get().
local function veinOf(ability)
    local reference = KIT.get(ability, "m_InteractiveActor")
    if KIT.valid(reference) then return reference, "object" end
    for _, name in ipairs({ "Get", "get" }) do
        local actor = KIT.call(reference, name)
        if KIT.valid(actor) then return actor, "weak pointer" end
    end
    return nil
end

-- The part of the vein that holds its ore: from the vein's own list of data
-- modules, else through the game's library function.
local function containerOf(vein)
    local found = nil
    KIT.each(KIT.get(KIT.get(vein, "m_DataModuleComponent"), "m_DataModules"), function(module)
        local kind = KIT.classToken(module)
        if kind and kind:find(CONTAINER, 1, true) then found = found or module end
    end)
    local via = "module list"
    if not found then
        local library = KIT.findDefault("DataModuleLibrary", "G1R")
        if library then crumb("first call of the data module library's GetContainerDataModule") end
        found, via = KIT.call(library, "GetContainerDataModule", vein), "library"
        if not KIT.valid(found) then return nil end
    end
    note("mining.vein_module", via)
    return found
end

-- One of a container's item lists ("m_Inventory": what it holds,
-- "m_DefaultInventory": what the game gave it): the sum of its slots' counts
-- and the data of its first slot. nil when the list cannot be walked or a
-- count is not a number. (Only the lists' own lengths are walked: an index
-- past the end would add an element to the game's list.)
local function slots(container, which)
    local total, first, good = 0, nil, true
    local seen = KIT.each(KIT.get(KIT.get(KIT.get(container, which), "m_Values"), "Items"), function(entry)
        KIT.each(KIT.get(entry, "m_Slots"), function(slot)
            local data = KIT.get(slot, "m_SlotData")
            local count = whole(KIT.get(data, "m_ItemCount"))
            if count == nil then good = false else total, first = total + count, first or data end
        end)
    end)
    if seen == nil or not good then return nil end
    return total, first
end

-- The ore item's class: from the world definition (taken with the config),
-- else by its path, once.
local function oreClass()
    if S.ore == nil then
        S.ore = KIT.findClass(ORE, "Angelscript") or false
        S.oreVia = S.ore and "path" or nil
        note("mining.ore_class", S.oreVia or "not found")
    end
    if KIT.valid(S.ore) then return S.ore end
    return nil
end

-- How much ore a vein holds, or nil. The game's own counting function, else
-- the sum of the slots; the way that worked is kept.
local function count(container)
    local ore = S.countWay ~= "slots" and oreClass() or nil
    if ore then
        local out = {}
        crumb("first count of a vein's ore by its container's HasItemMain")
        local ok = KIT.try(container, "HasItemMain", ore, 1, out)
        local n = ok and whole(KIT.unwrap(out.hasItemCount)) or nil
        if n ~= nil then
            S.countWay = "function"
            note("mining.vein_count", S.countWay)
            return n
        end
    end
    local n = slots(container, "m_Inventory")
    if n ~= nil then
        S.countWay = "slots"
        note("mining.vein_count", S.countWay)
    end
    return n
end

-- The ways of putting ore into a vein. Each returns nil when it cannot be
-- tried now, else whether the call went through.
local ADD = {
    { name = "function", run = function(container, amount)
        local ore = oreClass()
        if not ore then return nil end
        crumb("first ore put into a vein by its container's Multicast_AddNewItem")
        return (KIT.try(container, "Multicast_AddNewItem", MAIN, ore, amount, {}, false))
    end },
    { name = "slot", run = function(container, amount)
        local _, first = slots(container, "m_Inventory")
        local own = whole(KIT.get(first, "m_ItemCount"))
        if own == nil then return nil end
        crumb("first ore put into a vein by writing the count of its first slot")
        return (pcall(function() first.m_ItemCount = own + amount end))
    end },
}
-- Puts `amount` ore into a vein that holds `have`. Returns what it holds
-- afterwards (counted again), or nil when nothing arrived.
local function add(container, have, amount)
    local open = false          -- a way that could not be tried with this vein: no verdict on it
    for _, way in ipairs(ADD) do
        if (Cfg.VeinMethod == "auto" or Cfg.VeinMethod == way.name) and not S.addFailed[way.name] then
            local called = way.run(container, amount)
            if called == nil then
                open = true
            else
                local now = count(container)
                if now ~= nil and now > have then
                    note("mining.vein_add", way.name, now - have == amount and "complete" or ("%d of %d arrived"):format(now - have, amount))
                    return now
                end
                S.addFailed[way.name] = true
                L.once("add:" .. way.name, ("putting ore into a vein by its %s did not work (%s); that way is not used again in this run"):format(
                    way.name == "function" and "container function" or "slot count", called and "the count stayed" or "the call failed"))
            end
        end
    end
    if not open and not S.addOff then
        S.addOff = true
        L.once("add", "ore cannot be put into veins: they stay as the game has them")
        note("mining.vein_add", "failed")
    end
    return nil
end

-- The game's picture of a vein: it is redrawn at the end of a swing, and only
-- while the vein holds fewer ore than this (m_VisualMaxOre; a number that is
-- never reached when it could not be read).
local function drawLimit() return S.game and S.game.drawn or math.huge end
-- Does the picture of a vein that was last drawn with `count` ore show it as
-- mined down? One below the limit already shows every piece of ore.
local function reduced(count) return count < drawLimit() - 1 end

-- What the game gave a vein when it was new, else what it held when it was
-- first seen in this world.
local function sizeOf(container, record)
    local size = slots(container, "m_DefaultInventory")
    if size ~= nil and size >= 1 then
        note("mining.vein_size_from", "default contents")
        return size
    end
    note("mining.vein_size_from", "first look")
    return record.first
end

-- ---------------------------------------------------------------------------
-- A swing
-- ---------------------------------------------------------------------------
local function show(text)
    if Cfg.ShowMessage then KIT.notify(text, "mining") end
end
-- What a swing gives from a vein that holds `have`, by these two amounts.
local function gives(have, amounts)
    return min(have > S.game.threshold and amounts.high or amounts.low, have)
end

-- The ore in the vein of the swing in progress, or nil (also when its container is not the same object any more).
local function left(sw)
    if KIT.valid(sw.container) and KIT.fullName(sw.container) == sw.containerName then return count(sw.container) end
    return nil
end

-- Is the ability aimed at another vein than the one of this swing? (Naming none is no answer: the swing goes on.)
local function elsewhere(ability, sw)
    local vein = veinOf(ability)
    return vein ~= nil and KIT.fullName(vein) ~= sw.name
end

-- A look that finds the ability active and no swing in progress: a swing begins. `again`: the same look has
-- seen a swing end - the ability is active still, or it was started anew at once.
local function begin(now, ability, again)
    local vein, how = veinOf(ability)
    if not vein then return end         -- it does not name its vein (yet): asked again at the next look
    refresh(now, true)
    local sw = { name = KIT.fullName(vein), extra = S.extra, again = again }
    S.swing = sw
    note("mining.swing_seen", "yes", sw.name)
    note("mining.vein_reference", how)
    local container = containerOf(vein)
    local have = container and count(container) or nil
    if have == nil then
        L.once("vein", "the ore of a vein cannot be counted (" .. short(sw.name) .. "): veins stay as the game has them, and nothing is said about a swing")
        note("mining.vein_count", "not readable", sw.name)
        return
    end
    sw.container, sw.containerName, sw.found, sw.before = container, KIT.fullName(container), have, have
    local record = S.veins[sw.name]
    if record == nil then
        record = { owed = 0, first = have, reduced = reduced(have) }
        S.veins[sw.name] = record
    end
    sw.record = record
    -- without the game's numbers (not found, or not readable any more) nothing more can be worked out
    if not S.game or S.holds.high == nil or S.holds.low == nil then return end
    sw.game = gives(have, S.game)
    if Cfg.EndlessVeins then
        local keep = sizeOf(container, record)
        -- A vein the game shows as mined down would go on looking so when it is kept at the limit or above:
        -- it is kept one below, until the game has redrawn it (at the end of this swing).
        if record.reduced and keep >= drawLimit() then keep = drawLimit() - 1 end
        local level = max(keep + S.holds.high, S.game.threshold + 1)
        if have < level then
            local got = add(container, have, level - have)
            if got then S.putBack, have = S.putBack + (got - have), got end
        end
    end
    sw.before, sw.expected = have, gives(have, S.holds)
end

-- The swing in progress is over. `after`: the ore in its vein now (nil: it cannot be counted); `active`: the
-- ability is active still.
local function finish(after, active)
    local sw = S.swing
    S.swing, S.refreshAt = nil, AT_ONCE         -- the extra ore of this swing leaves the numbers again at once
    local before = sw.before
    -- begun at the look that saw the swing before it end, and nothing was taken since: the end of that swing, not one more
    if sw.again and (after == nil or after == before) then return end
    S.swings = S.swings + 1
    if after == nil then return end
    local given = before - after
    if given < 0 then
        L.once("grew", "a vein held more ore after a swing than before it: something else fills veins (another mining mod?)")
        note("mining.swing_gave", "the vein grew", ("%d -> %d"):format(before, after))
        return
    end
    S.ore_given = S.ore_given + given
    if DIAG and given > 0 and not S.told then
        S.told = true
        DIAG.event(("first swing with ore: %d from %s (the numbers in force said %s, the game's own %s); the vein held %d when the swing began, %d before the game took its ore, %d after"):format(
            given, short(sw.name), tostring(sw.expected), tostring(sw.game), sw.found, before, after))
    end
    if sw.game then S.game_gives = S.game_gives + (given > 0 and sw.game or 0) end
    if given > 0 and sw.expected then
        note("mining.swing_gave", given == sw.expected and "as the numbers say" or "differs", ("%d expected, %d given"):format(sw.expected, given))
    end
    local back = 0
    if not Cfg.EndlessVeins then
        -- a vein that lasts longer: the fitting part of what the swing took is owed back (nothing at "1 times")
        local record = sw.record
        record.owed = record.owed + given * (1 - 1 / Cfg.VeinLastsTimes)
        local due = floor(record.owed + 0.000001)
        if due >= 1 then
            local got = add(sw.container, after, due)
            if got then
                back = got - after
                record.owed, S.putBack = record.owed - back, S.putBack + back
            end
        end
    end
    if given > 0 then
        S.extras = S.extras + sw.extra
        if after < drawLimit() then sw.record.reduced = reduced(after) end      -- the game has redrawn the vein with what it held then
        -- Does the ability come to rest with the hand-out? "Still active" (it stayed active for a look or more, or
        -- the next swing followed at once) is kept once it was seen.
        if active then
            note("mining.swing_end", "ability still active")
        elseif not Noted["mining.swing_end"] then
            note("mining.swing_end", "ability at rest")
        end
    end
    S.last = ("%d ore from %s"):format(given, short(sw.name))
    if Cfg.LogSwings then
        log(("swing at %s: %d ore%s; ore in the vein: %d%s, %d after the swing%s"):format(short(sw.name), given,
            sw.game and (" (the game's own amount: %d)"):format(sw.game) or "", sw.found,
            before ~= sw.found and (", filled to %d"):format(before) or "", after, back > 0 and (", %d put back"):format(back) or ""))
    end
    if sw.game and given ~= sw.game and (given > 0 or sw.expected == 0) then
        show(("Mining: %d ore (the game gives %d)"):format(given, sw.game))
    end
end

-- ---------------------------------------------------------------------------
-- The loop
-- ---------------------------------------------------------------------------
-- Nothing is watched: the next look at the game starts afresh. (The config
-- object and what it holds are kept: they outlive a world.)
local function rest()
    S.awake, S.hero, S.heroAt = false, nil, AT_ONCE
    S.ability, S.swing = nil, nil
    S.abilityTries, S.abilityAt, S.abilityPause = 0, AT_ONCE, PAUSE_FIRST
    S.scanAt, S.scanPause = AT_ONCE, PAUSE_FIRST
    S.veins = {}
    S.refreshAt = AT_ONCE
end
rest()

local function tick()
    if KIT.loading() then return end
    local now = clock()
    if idle() then
        if S.awake then rest() end
        if S.dirty then
            -- the one thing done while there is nothing to change: the game's own numbers go back
            local config = findConfig(now)
            if config then write(config, S.game) end
        end
        return
    end
    local watch = watching()
    if not watch and now < S.refreshAt then return end
    if now >= S.heroAt then
        -- once a second: is there a hero, and is he still the same?
        local _, name = KIT.playerState()
        if name ~= S.hero then
            if S.awake then rest() end
            S.hero = name
        end
        S.heroAt = now + 1
    end
    if not S.hero then return end
    S.awake = true
    local ability = watch and findAbility(now) or nil
    local active = ability ~= nil and KIT.get(ability, "bIsActive") == true
    local sw = S.swing
    if sw then
        -- The swing is over when the ability is at rest - and when the vein holds less than when the swing began
        -- (the game has handed the ore out, and the ability is active still, or was started anew between two
        -- looks), and when the ability is aimed at another vein.
        local have = left(sw)
        if not active or (have ~= nil and have < sw.before) or elsewhere(ability, sw) then finish(have, active) end
    end
    if active and not S.swing then begin(now, ability, sw ~= nil) end
    if not S.swing and now >= S.refreshAt then refresh(now, false) end
end

Settings.onChange = function(_, changed, why)
    log(("settings changed (%s): %s"):format(why == "menu" and "in-game menu" or (why == "file" and "config.lua" or tostring(why)), summary()))
    if not Cfg.ShowMessage then KIT.hideToast("mining") end
    -- the new settings count from the next look on: a swing in progress is taken as just begun
    S.swing, S.refreshAt = nil, AT_ONCE
    for _, key in ipairs(changed) do
        if key == "YieldEnabled" then S.yieldOff = nil end                          -- switched on again: writing is tried anew
        if key == "VeinMethod" then S.addFailed, S.addOff = {}, false end
    end
end

-- ---------------------------------------------------------------------------
-- Status (console command mining, the loader's reports). Built from what the
-- module holds; it does not call into the game.
-- ---------------------------------------------------------------------------
local function statusLines()
    local lines = { ("v%s | %s"):format(VERSION, summary()) }
    if idle() then
        lines[#lines + 1] = "nothing to change: the game is not looked at"
    elseif S.game == nil then
        lines[#lines + 1] = "the game's mining numbers have not been found yet (no game loaded?)"
    else
        lines[#lines + 1] = ("the game's own numbers: %d ore per swing, %d when %d or fewer are left in the vein (found through the %s)"):format(
            S.game.high, S.game.low, S.game.threshold, tostring(S.configVia))
        if S.yieldOff then
            lines[#lines + 1] = "ore per swing: left as the game has it for this run (" .. S.yieldOff .. ")"
        elseif S.waiting then
            lines[#lines + 1] = "ore per swing: waiting for the hero's " .. S.waiting
        elseif S.amount then
            lines[#lines + 1] = ("ore per swing now: %d%s%s%s"):format(S.amount,
                S.strength and (", Strength %d"):format(floor(S.strength + 0.001)) or "",
                S.dexterity and (", Dexterity %d"):format(floor(S.dexterity + 0.001)) or "",
                S.rank and (", a " .. S.rank .. " miner") or "")
        end
    end
    lines[#lines + 1] = ("swings seen: %d, ore: %d (by the game's own numbers: %d), put into veins: %d%s"):format(S.swings, S.ore_given, S.game_gives,
        S.putBack, S.last and ("; last: " .. S.last) or "")
    if S.addOff then lines[#lines + 1] = "ore cannot be put into veins in this run: they stay as the game has them" end
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
    if (args[1] or ""):lower() == "reload" then
        local ok, why = Settings:reload(true)
        lines = { ok and ("settings read: " .. summary()) or ("settings not read: " .. tostring(why)) }
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
for _, name in ipairs({ "mining", "g1r_mining" }) do
    if type(RegisterConsoleCommandHandler) == "function" then
        pcall(RegisterConsoleCommandHandler, name, console)
    end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; the mining rework is disabled.")
    return
end
LoopInGameThreadWithDelay(Cfg.CheckMilliseconds, function()
    local ok, err = pcall(tick)
    if not ok then L.once("tick:" .. tostring(err), "update error: " .. tostring(err)) end
end)

-- An earlier run of the Lua mods left its numbers in the game's config: they are put back even while idle.
if remembered() then S.dirty = true end
log(("v%s loaded: %s"):format(VERSION, summary()))

if DIAG then
    pcall(function()
        DIAG.status(statusLines)
        DIAG.dump(function()
            local sw = S.swing
            return {
                version = VERSION, enabled = Cfg.Enabled, looking = S.awake,
                yield_enabled = Cfg.YieldEnabled, base_amount = Cfg.BaseAmount, strength_per_ore = Cfg.StrengthPerOre,
                dexterity_per_ore = Cfg.DexterityPerOre, trained_bonus = Cfg.TrainedBonus, master_bonus = Cfg.MasterBonus,
                extra_chance = Cfg.ExtraChance, min_amount = Cfg.MinAmount, max_amount = Cfg.MaxAmount, low_vein_rule = Cfg.LowVeinRule,
                endless_veins = Cfg.EndlessVeins, vein_lasts_times = Cfg.VeinLastsTimes, show_message = Cfg.ShowMessage,
                log_swings = Cfg.LogSwings, vein_method = Cfg.VeinMethod, refresh_seconds = Cfg.RefreshSeconds,
                config = S.configName, config_found_through = S.configVia,
                game_numbers = S.game and { high = S.game.high, low = S.game.low, threshold = S.game.threshold, drawn = S.game.drawn } or nil,
                config_holds = { high = S.holds.high, low = S.holds.low }, own_numbers_in_config = S.dirty, yield_off = S.yieldOff,
                amount = S.amount, strength = S.strength, dexterity = S.dexterity, rank = S.rank, waiting_for = S.waiting,
                skill_tags_unusable = S.tagsOff, ore_class_from = S.oreVia or nil,
                ability = S.ability and S.ability.name or nil, ability_found_through = S.ability and S.ability.via or nil,
                swing = sw and { vein = sw.name, found = sw.found, before = sw.before, expected = sw.expected, game = sw.game, extra = sw.extra } or nil,
                count_way = S.countWay, add_off = S.addOff, add_failed_function = S.addFailed["function"] == true,
                add_failed_slot = S.addFailed.slot == true,
                swings = S.swings, ore = S.ore_given, game_would_give = S.game_gives, put_into_veins = S.putBack, extras = S.extras,
                last_swing = S.last,
            }
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "MINING_TEST")) == "table" then
    local T = rawget(_G, "MINING_TEST")
    T.state, T.console, T.status, T.tick, T.settings, T.amountFor, T.summary = S, console, statusLines, tick, Settings, amountFor, summary
end
