-- ============================================================================
-- Offline tests of the module mining (modules/mining/Scripts/main.lua).
--
--   lua5.4 harness.lua          (from any directory)
--
-- The module runs on the loader's kit and settings service; ../lib/modtest.lua
-- sets both up the way the loader does and replaces UE4SS by ../mock/ue4ss.lua.
-- The game is a model built below: the hero (player controller -> player
-- state -> ability system -> attributes, granted abilities, gameplay tags),
-- the world's game state and world definition, the mining config object, the
-- hero's mining ability, veins with their container module, and the game's own
-- code at the end of a swing. Where each modelled behaviour is known from is
-- said at the model (dev/facts/mining.md has the full list).
-- The last section runs the module through the real loader with the real
-- diagnostics.
-- Last line: "mining tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("mining")
local check, section, has, printed, printedCount = T.check, T.section, T.has, T.printed, T.printedCount
local MOD = T.MOD
local shipped = T.read(MOD .. "modules/mining/Scripts/config.lua")

-- The roll for the extra ore: the module asks math.random; the tests decide what it says.
local Roll, Rolls = 0.5, 0
local realRandom = math.random
math.random = function()
    Rolls = Rolls + 1
    return Roll
end

-- ---------------------------------------------------------------------------
-- The model of the game
-- ---------------------------------------------------------------------------
-- Property names this UE4SS build writes a debug line for at every read
-- (FACTS U4): the module must never read them.
local FLOOD = { m_Capacity = true, m_InventoryType = true, m_InteractiveObjectDefinition = true, m_ItemDefinition = true }
local STATE = "/Game/Maps/World.World:PersistentLevel.GothicPlayerState_21"

-- An object of the game. Every property read and function call (w.n.reads, by
-- name in w.byName), every write (w.n.writes) and every IsValid / GetFullName
-- (w.n.checks) is counted. Raw fields: __full, __valid (false: the object is
-- gone), __empty (a name the object does not have gives an empty object, as
-- UE4SS does - UE4SS source, handle_unreal_property_value), __readonly (a
-- write raises), __deaf (a write goes nowhere), __lock (names whose write
-- goes nowhere), __blind (names that give an empty object when read).
local function thing(w, fullName, fields)
    local o = { __full = fullName, __data = fields or {} }
    return setmetatable(o, {
        __index = function(t, k)
            if k == "IsValid" then
                return function(self)
                    w.n.checks = w.n.checks + 1
                    return rawget(self, "__valid") ~= false
                end
            end
            if k == "GetFullName" then
                return function(self)
                    w.n.checks = w.n.checks + 1
                    return rawget(self, "__full")
                end
            end
            if rawget(t, "__valid") == false then w.n.stale = w.n.stale + 1 end      -- FACTS U5: this reads freed memory
            if FLOOD[k] then w.n.flood = w.n.flood + 1 end
            w.n.reads = w.n.reads + 1
            w.byName[k] = (w.byName[k] or 0) + 1
            local v = rawget(t, "__data")[k]
            local blind = rawget(t, "__blind")
            if (v == nil and rawget(t, "__empty")) or (blind and blind[k]) then return w.ue:invalid() end
            return v
        end,
        __newindex = function(t, k, v)
            if type(k) == "string" and k:sub(1, 2) == "__" then
                rawset(t, k, v)
                return
            end
            w.n.writes = w.n.writes + 1
            if rawget(t, "__readonly") then error("the property cannot be written (test)") end
            local lock = rawget(t, "__lock")
            if rawget(t, "__deaf") or (lock and lock[k]) then return end
            rawget(t, "__data")[k] = v
        end,
    })
end
-- A struct value (no IsValid, no name). `on`: optional { get = f(k), set = f(k, v) } for values kept elsewhere.
local function struct(w, fields, on)
    return setmetatable({}, {
        __index = function(_, k)
            if k == "IsValid" or k == "GetFullName" or k == "get" then return nil end
            if FLOOD[k] then w.n.flood = w.n.flood + 1 end
            w.n.reads = w.n.reads + 1
            w.byName[k] = (w.byName[k] or 0) + 1
            if on and on.get then
                local v = on.get(k)
                if v ~= nil then return v end
            end
            return fields[k]
        end,
        __newindex = function(_, k, v)
            w.n.writes = w.n.writes + 1
            if on and on.set and on.set(k, v) then return end
            fields[k] = v
        end,
    })
end
-- An array property as UE4SS hands it out (FACTS U6): GetArrayNum, ForEach
-- with (index, element), elements with :get(). `list` is a table or a
-- function that gives the elements as they are now. An index into it is
-- counted (w.n.indexed): at or past the length it would add an element to the
-- game's array - the module must never do that.
local function array(w, list)
    local function items() return type(list) == "function" and list() or list end
    local a = {}
    function a:GetArrayNum()
        w.n.reads = w.n.reads + 1
        return #items()
    end
    function a:ForEach(f)
        w.n.reads = w.n.reads + 1
        for i, v in ipairs(items()) do
            if f(i, { get = function() return v end }) == true then break end
        end
    end
    return setmetatable(a, { __index = function(_, k)
        if type(k) == "number" then w.n.indexed = w.n.indexed + 1 end
        return nil
    end })
end
-- A weak reference as UE4SS hands it out: a value with Get() / get() (UE4SS source, LuaFWeakObjectPtr.cpp).
local function weak(w, target)
    local function get()
        w.n.reads = w.n.reads + 1
        return target() or w.ue:invalid()
    end
    return { Get = get, get = get }
end
local function attributeData(value) return { BaseValue = value, CurrentValue = value } end

-- options (all optional):
--   strength, dexterity   the hero's attributes (10 / 10: the game's start values)
--   rank                  "trained" / "master": the hero's mining skill tag
--   numbers               { high, low, threshold }: the game's mining numbers (3 / 1 / 5: WorldDefinition.as)
--   others                granted abilities in front of the mining ability (6)
--   behind                granted abilities behind it (0)
local function build(ue, o)
    o = o or {}
    local w = T.newWorld(ue)
    w.ue = ue
    w.n = { reads = 0, writes = 0, checks = 0, flood = 0, indexed = 0, stale = 0 }     -- what the module asked of the model
    w.byName = {}
    w.heroOre = 0               -- ore in the hero's inventory
    w.tagAsked = 0

    -- the hero's attributes (property layout: AttributeSet_Strength.Strength, AttributeSet_Dexterity.Dexterity)
    w.strength = thing(w, "AttributeSet_Strength " .. STATE .. ".AttributeSet_Strength_31", { Strength = attributeData(o.strength or 10.0) })
    w.dexterity = thing(w, "AttributeSet_Dexterity " .. STATE .. ".AttributeSet_Dexterity_32", { Dexterity = attributeData(o.dexterity or 10.0) })
    local sets = w.hero.component.SpawnedAttributes.items
    sets[#sets + 1] = w.strength
    sets[#sets + 1] = w.dexterity
    function w.attribute(name, value)
        local set = name == "Strength" and w.strength or w.dexterity
        rawget(set, "__data")[name] = attributeData(value)
    end

    -- the mining config: the default object of the script class UMiningConfig (WorldDefinition.as: 3 ore from a
    -- vein with more than 5, else 1); the world definition names its class and the ore's class
    local n = o.numbers or {}
    w.numbers = { m_MiningDuration = 3.0, m_HighOre = n.threshold or 5, m_AmountAtHighOre = n.high or 3, m_AmountAtLowOre = n.low or 1,
        m_VisualMaxOre = 15 }
    w.config = thing(w, "MiningConfig /Script/Angelscript.Default__MiningConfig", w.numbers)
    w.oreClass = thing(w, "ASClass /Script/Angelscript.ItMi_Orenugget", {})
    local function classOf(name, object)
        return thing(w, "ASClass /Script/Angelscript." .. name, { GetCDO = function() return object end })
    end
    w.definition = thing(w, "DefaultWorldDefinition /Script/Angelscript.Default__DefaultWorldDefinition", {
        m_MiningDefinition = classOf("MiningConfig", w.config), m_DefaultOre = w.oreClass })
    -- the game state hands the world definition out (G1RGameState::GetWorldDefinition, a static function of the
    -- game; the class is also in its property m_WorldDefinition)
    w.gameState = thing(w, "G1RGameState_C /Game/Maps/World.World:PersistentLevel.G1RGameState_C_2147482400", {
        GetWorldDefinition = function(_, world) return world == w.world and w.definition or nil end,
        m_WorldDefinition = classOf("DefaultWorldDefinition", w.definition) })
    w.world = thing(w, "World /Game/Maps/World.World", { GameState = w.gameState })
    -- by path (the module's second way)
    ue.objects["/Script/Angelscript.Default__MiningConfig"] = w.config
    ue.objects["/Script/Angelscript.ItMi_Orenugget"] = w.oreClass

    -- the hero's mining ability: one object per hero (instancing policy "per actor"), listed in his ability
    -- system's granted abilities next to the others
    w.ability = thing(w, "GameplayAbilityMining " .. STATE .. ".GameplayAbilityMining_2147482102", { bIsActive = false })
    w.abilityDefault = thing(w, "GameplayAbilityMining /Script/G1R.Default__GameplayAbilityMining", { bIsActive = false })
    w.target = nil
    rawget(w.ability, "__data").m_InteractiveActor = weak(w, function() return w.target end)
    local granted = {}
    for i = 1, o.others or 6 do
        local default = thing(w, "GameplayAbilityOther" .. i .. " /Script/G1R.Default__GameplayAbilityOther" .. i, {})
        local instance = thing(w, "GameplayAbilityOther" .. i .. " " .. STATE .. ".GameplayAbilityOther" .. i .. "_" .. (2147482000 + i), { bIsActive = false })
        granted[#granted + 1] = struct(w, { Ability = default, NonReplicatedInstances = array(w, { instance }), ReplicatedInstances = array(w, {}) })
    end
    w.entry = { Ability = w.abilityDefault, NonReplicatedInstances = array(w, { w.ability }), ReplicatedInstances = array(w, {}) }
    granted[#granted + 1] = struct(w, w.entry)
    for i = 1, o.behind or 0 do
        local default = thing(w, "GameplayAbilityLater" .. i .. " /Script/G1R.Default__GameplayAbilityLater" .. i, {})
        granted[#granted + 1] = struct(w, { Ability = default, NonReplicatedInstances = array(w, {}), ReplicatedInstances = array(w, {}) })
    end
    w.granted = granted
    w.hero.component.ActivatableAbilities = struct(w, { Items = array(w, granted) })
    -- gameplay tags of the hero (the skill effects give exactly one of Skill.Mining.Untrained / .Trained / .Master)
    w.rank = o.rank
    w.hero.component.HasGameplayTag = function(_, tag)
        w.tagAsked = w.tagAsked + 1
        if type(tag) ~= "table" then error("HasGameplayTag needs a tag (test)") end
        local name = tag.TagName and tag.TagName.__s
        if name == "Skill.Mining.Master" then return w.rank == "master" end
        if name == "Skill.Mining.Trained" then return w.rank == "trained" end
        return false
    end

    -- Another hero (after a map load, a new game): a player state with attributes and a mining ability of its
    -- own, and a controller for it.
    function w.another(number, strength)
        local state = ("/Game/Maps/World.World:PersistentLevel.GothicPlayerState_%d"):format(number)
        local h = T.hero(ue, w, number)
        local list = h.component.SpawnedAttributes.items
        list[#list + 1] = thing(w, "AttributeSet_Strength " .. state .. ".AttributeSet_Strength_1", { Strength = attributeData(strength or 10.0) })
        list[#list + 1] = thing(w, "AttributeSet_Dexterity " .. state .. ".AttributeSet_Dexterity_2", { Dexterity = attributeData(10.0) })
        h.ability = thing(w, "GameplayAbilityMining " .. state .. ".GameplayAbilityMining_3", { bIsActive = false })
        rawget(h.ability, "__data").m_InteractiveActor = weak(w, function() return w.target end)
        h.component.ActivatableAbilities = struct(w, { Items = array(w, { struct(w, { Ability = w.abilityDefault,
            NonReplicatedInstances = array(w, { h.ability }), ReplicatedInstances = array(w, {}) }) }) })
        h.component.HasGameplayTag = function() return false end
        h.controller = T.controllerOf(ue, number + 1, h.state, { GetWorld = function() return w.world end })
        return h
    end

    -- the game's library of data modules (the second way to a vein's container)
    w.libraryAsked = 0
    w.library = thing(w, "DataModuleLibrary /Script/G1R.Default__DataModuleLibrary", {
        GetContainerDataModule = function(_, actor)
            w.libraryAsked = w.libraryAsked + 1
            for _, v in ipairs(w.veins) do
                if v.actor == actor then return v.container end
            end
            return nil
        end })
    ue.objects["/Script/G1R.Default__DataModuleLibrary"] = w.library

    -- A vein: an interactive object with a data module component; its container module holds the ore in slots
    -- (property layout: DataModule_Container.m_Inventory / m_DefaultInventory -> m_Values.Items[*].m_Slots[*]
    -- .m_SlotData.m_ItemCount). `size`: what the game gave it (15 / 10 / 5: CraftingSpaces.as), `count`: what it holds.
    w.veins = {}
    function w.vein(id, size, count)
        local v = { id = id, size = size, slots = {}, defaults = { { count = size } }, added = 0, addCalls = 0, countCalls = 0 }
        if (count or size) > 0 then v.slots[1] = { count = count or size } end
        local path = "/Game/Maps/World.World:PersistentLevel.BP_MiningSpot_C_" .. id
        local function inventory(records)
            local function slotsNow()
                local out = {}
                for i, r in ipairs(records) do
                    r.proxy = r.proxy or struct(w, { m_Id = i }, { get = function(k)
                        if k == "m_SlotData" then
                            r.data = r.data or struct(w, {}, {
                                get = function(name) if name == "m_ItemCount" then return r.count end end,
                                set = function(name, value)
                                    if name ~= "m_ItemCount" then return false end
                                    if v.readonly then error("the count cannot be written (test)") end
                                    if not v.deaf then r.count = value end
                                    return true
                                end })
                            return r.data
                        end
                    end })
                    out[i] = r.proxy
                end
                return out
            end
            return struct(w, { m_Values = struct(w, { Items = array(w, { struct(w, { m_Slots = array(w, slotsNow) }) }) }) })
        end
        function v.total()
            local n = 0
            for _, r in ipairs(v.slots) do n = n + r.count end
            return n
        end
        -- The game's picture of the vein (its visual component, read from the executable): `meshes` pieces of
        -- ore; when it is drawn with fewer ore than m_VisualMaxOre, piece i (from 0) is shown when the vein holds
        -- at least i * m_VisualMaxOre / meshes; with that many ore or more nothing is changed.
        v.meshes, v.shown = 5, 5
        function v.draw()
            local total, most = v.total(), w.numbers.m_VisualMaxOre or 15
            if total >= most then return end
            v.shown = 0
            for i = 0, v.meshes - 1 do
                if total >= i * most / v.meshes then v.shown = v.shown + 1 end
            end
        end
        v.draw()
        v.container = thing(w, "DataModule_Container " .. path .. ".DataModules.DataModule_Container_0", {
            m_Inventory = inventory(v.slots), m_DefaultInventory = inventory(v.defaults),
            -- the game's counting function: how many of this item are in the main inventory (out parameter: FACTS U7)
            HasItemMain = function(_, class, wanted, out)
                v.countCalls = v.countCalls + 1
                v.lastWanted = wanted
                local n = class == w.oreClass and v.total() or 0
                if type(out) == "table" and not v.noOut then out.hasItemCount = n end
                return n >= wanted
            end,
            -- the game's adding function (FACTS R13): the item goes onto its stack, or into a new slot
            Multicast_AddNewItem = function(_, kind, class, amount, payload, predicted)
                v.addCalls = v.addCalls + 1
                v.lastAdd = { kind = kind, class = class, amount = amount, payload = payload, predicted = predicted }
                if v.addDeaf then return end
                if v.slots[1] then v.slots[1].count = v.slots[1].count + amount else v.slots[1] = { count = amount } end
                v.added = v.added + amount
            end,
        })
        local other = thing(w, "DataModule_Targeting " .. path .. ".DataModules.DataModule_Targeting_0", {})
        v.component = thing(w, "DataModuleComponent " .. path .. ".DataModules", { m_DataModules = array(w, { other, v.container }) })
        v.actor = thing(w, "BP_MiningSpot_C " .. path, { m_DataModuleComponent = v.component })
        w.veins[#w.veins + 1] = v
        return v
    end

    -- The hero starts to swing at a vein: the ability is active and aimed at it.
    function w.startSwing(v)
        w.target = v.actor
        rawget(w.ability, "__data").bIsActive = true
    end
    -- The game's own code at the end of a swing (read from the executable, dev/facts/mining.md): the ore in the
    -- vein is counted; nothing when there is none; else the config's amount for a vein above / not above the
    -- threshold, taken slot by slot and never more than there is, moved to the hero; the vein is redrawn.
    -- Returns what the hero got. (Whether the ability is at rest in the same step is not known: endSwing models
    -- that it is, handOut alone that it stays active - for a while, or because the hero swings again at once.)
    function w.handOut(v)
        local got = 0
        local total = v.total()
        if total > 0 then
            local numbers = w.deafGame and { m_HighOre = 5, m_AmountAtHighOre = 3, m_AmountAtLowOre = 1 } or w.numbers
            local rest = total > numbers.m_HighOre and numbers.m_AmountAtHighOre or numbers.m_AmountAtLowOre
            for _, r in ipairs(v.slots) do
                local take = math.min(r.count, rest)
                r.count, rest, got = r.count - take, rest - take, got + take
            end
            for i = #v.slots, 1, -1 do
                if v.slots[i].count == 0 then table.remove(v.slots, i) end
            end
        end
        v.draw()
        w.heroOre = w.heroOre + got
        return got
    end
    -- The ability comes to rest and names no vein any more.
    function w.release()
        w.target = nil
        rawget(w.ability, "__data").bIsActive = false
    end
    -- A swing ends: the ore is handed out and the ability is at rest. An interrupted swing whose animation had
    -- not started hands nothing out.
    function w.endSwing(v, interrupted)
        local got = interrupted and 0 or w.handOut(v)
        w.release()
        return got
    end
    return w
end

local function start(case, options)
    options = options or {}
    options.module, options.hook = "mining", "MINING_TEST"
    local model = options.model
    options.prepare = function(ue)
        local w = build(ue, model)
        if options.change then options.change(w, ue) end
        return w
    end
    local c = T.boot(case, options)
    c.S = c.hook and c.hook.state
    -- one swing: it begins, the module looks `looks` times (2 seconds), the game ends it, the module looks once
    function c.swing(v, looks, interrupted)
        c.world.startSwing(v)
        c.ticks(looks or 8)
        local got = c.world.endSwing(v, interrupted)
        c.ticks(1)
        return got
    end
    return c
end
local function stop(c)
    local line = printed(c.ue, "update error")
    if line then check(false, "the module's loop raised an error in the case " .. tostring(c.case) .. ": " .. line:gsub("\n", "")) end
    T.stop(c)
end
local function allOf(ue) return ue.calls.FindAllOf or 0 end
-- Counts the searches among all objects for the mining ability (c.scans()), apart from the kit's for the controller.
local function countScans(c, list)
    local n = 0
    local plain = c.ue.allOf
    c.ue.allOf = setmetatable({}, { __index = function(_, k)
        if k == "GameplayAbilityMining" then
            n = n + 1
            return list
        end
        return plain[k]
    end, __newindex = function(_, k, v) plain[k] = v end })
    function c.scans() return n end
end
local function status(c) return table.concat(c.hook.status(), "|") end
local function config(lines) return T.config(table.concat(lines, "\n")) end

-- The player's settings of the other author's mod, carried over (the handoff's table): floor(Strength / 4) +
-- floor(Dexterity / 6) ore per swing, veins never run out.
local PLAYER = { "Config.YieldEnabled = true", "Config.BaseAmount = 0", "Config.StrengthPerOre = 4", "Config.DexterityPerOre = 6",
    "Config.MinAmount = 0", "Config.LowVeinRule = false", "Config.EndlessVeins = true" }
local YIELD = { "Config.YieldEnabled = true" }

-- ---------------------------------------------------------------------------
section("1. loading with the shipped settings")
do
    local c = start("load")
    local ue, w = c.ue, c.world
    check(c.ok, "the module loads (" .. tostring(c.err) .. ")")
    check(#ue.printed == 1 and ue.printed[1] == "[G1R_Mining] v1.0.0 loaded: nothing to change (ore per swing and veins as the game has them)\n",
        "one load line: " .. tostring(ue.printed[1]):gsub("\n", ""))
    check(#ue.loops == 2 and ue.loops[2].ms == 250 and math.type(ue.loops[2].ms) == "integer", "one game-thread loop of its own, every 250 ms")
    check(ue.console.mining ~= nil and ue.console.g1r_mining ~= nil and #ue.loadMapPre == 1 and #ue.loadMapPost == 1,
        "console commands mining and g1r_mining; the kit's hooks before and after a map load")
    check(#ue.lookups == 0 and allOf(ue) == 0 and (ue.calls.FindFirstOf or 0) == 0 and (ue.calls.RegisterHook or 0) == 0,
        "loading searches for nothing and hooks nothing")
    local v = c.hook.settings.values
    check(v.Enabled == true and v.YieldEnabled == false and v.BaseAmount == 3 and v.StrengthPerOre == 0 and v.DexterityPerOre == 0 and v.TrainedBonus == 0
        and v.MasterBonus == 0 and v.ExtraChance == 0 and v.MinAmount == 1 and v.MaxAmount == 100 and v.LowVeinRule == true and v.EndlessVeins == false
        and v.VeinLastsTimes == 1 and v.ShowMessage == true and v.LogSwings == false and v.VeinMethod == "auto" and v.RefreshSeconds == 5
        and v.CheckMilliseconds == 250, "the shipped file gives the documented defaults")
    -- the game as it is: a vein of 15 gives 3, 3, 3, 3, then 1, 1, 1 (the model of the game's own code)
    local vein = w.vein(1, 15)
    local got = {}
    for i = 1, 8 do got[i] = c.swing(vein) end
    check(table.concat(got, ",") == "3,3,3,3,1,1,1,0" and w.heroOre == 15 and vein.total() == 0,
        "the game untouched: a vein of 15 gives 3, 3, 3, 3, 1, 1, 1 and is empty (" .. table.concat(got, ",") .. ")")
    check(w.n.reads == 0 and w.n.writes == 0 and w.n.checks == 0 and allOf(ue) == 0 and #ue.lookups == 0 and w.reads[21] == nil,
        "with nothing to change the module does not look at the game at all: 0 reads, 0 writes, 0 searches in 18 seconds of mining")
    check(w.numbers.m_AmountAtHighOre == 3 and w.numbers.m_AmountAtLowOre == 1 and w.numbers.m_HighOre == 5, "the game's numbers are as they were")
    local lines = c.hook.status()
    check(#lines == 3 and lines[1] == "v1.0.0 | nothing to change (ore per swing and veins as the game has them)"
        and lines[2] == "nothing to change: the game is not looked at"
        and lines[3] == "swings seen: 0, ore: 0 (by the game's own numbers: 0), put into veins: 0", "the status says so, in three lines")
    check(T.read(c.path) == shipped and #ue.errors == 0 and c.S.swings == 0, "the settings file is left as it is; no error; no swing was watched")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("2. the amount a swing gives, worked out by hand")
do
    local function amounts(lines, cases)
        local c = start("amount", { config = config(lines) })
        local out = {}
        for i, case in ipairs(cases) do out[i] = tostring(c.hook.amountFor(case[1], case[2], case[3], case[4] or 0)) end
        local kind = math.type(c.hook.amountFor(10, 10, nil, 0))
        stop(c)
        return table.concat(out, ","), kind
    end
    -- the player's settings so far: floor(Strength / 4) + floor(Dexterity / 6)
    local got, kind = amounts(PLAYER, { { 10, 10 }, { 12, 12 }, { 40, 22 }, { 3, 5 }, { 100, 100 }, { 4, 6 }, { 7.9, 11.9 }, { 200, 200 } })
    check(got == "3,5,13,0,41,2,2,83", "Strength / 4 + Dexterity / 6, rounded down each: 10/10 -> 3 (the game's own amount), 12/12 -> 5, 40/22 -> 13, 3/5 -> 0, "
        .. "100/100 -> 41, 4/6 -> 2, 7.9/11.9 -> 2, 200/200 -> 83 (" .. got .. ")")
    check(kind == "integer", "the amount is a whole number for the game (a Lua integer)")
    got = amounts(PLAYER, { { 11.9999, 5.9999 }, { 11.99, 5.99 } })
    check(got == "4,2", "an attribute a hair below a whole number counts as that number (the game keeps them as numbers with a fraction part): " .. got)
    got = amounts({ "Config.YieldEnabled = true", "Config.StrengthPerOre = 10" }, { { 9, 50 }, { 10, 50 }, { 19, 50 }, { 20, 50 }, { 20, nil } })
    check(got == "3,4,4,5,5", "base 3 and one more per 10 Strength: 9 -> 3, 10 -> 4, 19 -> 4, 20 -> 5; Dexterity does not count at 0 and is not even looked at (" .. got .. ")")
    got = amounts({ "Config.BaseAmount = 0", "Config.MinAmount = 0", "Config.StrengthPerOre = 1", "Config.DexterityPerOre = 1" }, { { 10, 12 }, { 0.5, 0.999 } })
    check(got == "22,1", "one ore per point: Strength 10 and Dexterity 12 give 22; half a point gives nothing, 0.999 counts as 1 (" .. got .. ")")
    got = amounts({ "Config.BaseAmount = 1", "Config.DexterityPerOre = 2.5" }, { { 50, 10 }, { 50, 12 }, { 50, 12.5 }, { 50, 2.4 } })
    check(got == "5,5,6,1", "points per ore can have a fraction: one per 2.5 Dexterity gives 10 -> 4, 12 -> 4, 12.5 -> 5, 2.4 -> 0 more (" .. got .. ")")
    got = amounts({ "Config.TrainedBonus = 2", "Config.MasterBonus = 5" }, { { 10, 10, nil }, { 10, 10, "trained" }, { 10, 10, "master" }, { 10, 10, "untrained" } })
    check(got == "3,5,8,3", "a trained miner gets 2 more, a master 5 more (not both): 3, 5, 8; any other rank nothing (" .. got .. ")")
    got = amounts({ "Config.BaseAmount = 0", "Config.StrengthPerOre = 4", "Config.MinAmount = 2", "Config.MaxAmount = 6" },
        { { 3, 0 }, { 8, 0 }, { 12, 0 }, { 24, 0 }, { 28, 0 }, { 400, 0 } })
    check(got == "2,2,3,6,6,6", "at least 2 and at most 6: 0 -> 2, 2 -> 2, 3 -> 3, 6 -> 6, 7 -> 6, 100 -> 6 (" .. got .. ")")
    got = amounts({ "Config.BaseAmount = 0", "Config.StrengthPerOre = 4", "Config.MinAmount = 2", "Config.MaxAmount = 6" },
        { { 3, 0, nil, 1 }, { 12, 0, nil, 1 }, { 20, 0, nil, 1 }, { 24, 0, nil, 1 } })
    check(got == "3,4,6,6", "the extra ore comes on top of the lowest amount and stops at the highest: 2+1, 3+1, 5+1, 6+0 (" .. got .. ")")
    got = amounts({ "Config.BaseAmount = 4", "Config.MinAmount = 8", "Config.MaxAmount = 6" }, { { 0, 0 }, { 0, 0, nil, 1 } })
    check(got == "8,8", "a lowest amount above the highest: the lowest counts, and leaves no room for the extra ore (" .. got .. ")")
    got = amounts({ "Config.BaseAmount = 0", "Config.MinAmount = 0" }, { { 50, 50 }, { 50, 50, "master", 1 } })
    check(got == "0,1", "base 0 without any bonus: nothing, and 1 with the extra ore (" .. got .. ")")
end

-- ---------------------------------------------------------------------------
section("3. the ore per swing is changed through the game's own numbers")
do
    local QUIET = "Config.ShowMessage = false"
    local c = start("yield", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 5", QUIET }), diag = true })
    local ue, w = c.ue, c.world
    check(printed(ue, "loaded: ore per swing: base 5, 1 to 100") ~= nil, "the load line names the rule: " .. tostring(ue.printed[1]):gsub("\n", ""))
    c.ticks(1)
    check(c.S.configName == "MiningConfig /Script/Angelscript.Default__MiningConfig" and c.S.configVia == "world definition"
        and c.S.game.high == 3 and c.S.game.low == 1 and c.S.game.threshold == 5,
        "the first look finds the game's mining numbers through the hero's world: 3 per swing, 1 when 5 or fewer are left")
    check(w.numbers.m_AmountAtHighOre == 5 and w.numbers.m_AmountAtLowOre == 1 and w.numbers.m_HighOre == 5 and w.numbers.m_VisualMaxOre == 15
        and w.numbers.m_MiningDuration == 3.0, "the amount from a full vein is written (5); the other four numbers are left alone")
    check(#ue.lookups == 0 and allOf(ue) == 1 and (ue.calls.RegisterHook or 0) == 0,
        "no search by path, one search for the hero's controller (the kit's), no hook")
    check(c.fake.value("mining.config_found_by") == "world definition" and c.fake.value("mining.game_numbers") == "3/1/5"
        and c.fake.value("mining.config_write") == "ok", "noted: where the numbers were found, what they were, that the write stayed")
    local vein = w.vein(1, 15)
    local got = {}
    for i = 1, 8 do got[i] = c.swing(vein) end
    check(table.concat(got, ",") == "5,5,1,1,1,1,1,0" and w.heroOre == 15,
        "a vein of 15 gives 5, 5, and then - nearly empty, the game's rule - 1, 1, 1, 1, 1 (" .. table.concat(got, ",") .. ")")
    check(c.S.swings == 0 and w.n.reads < 40, "with nothing to say about a swing, swings are not even watched (" .. w.n.reads .. " reads in 18 seconds)")
    stop(c)

    c = start("yield-low", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 5", "Config.LowVeinRule = false", QUIET }) })
    w = c.world
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 5 and w.numbers.m_AmountAtLowOre == 5 and w.numbers.m_HighOre == 5, "without the rule for nearly empty veins both amounts are written")
    vein = w.vein(1, 15)
    got = { c.swing(vein), c.swing(vein), c.swing(vein), c.swing(vein) }
    check(table.concat(got, ",") == "5,5,5,0", "a vein of 15 gives 5, 5, 5 (" .. table.concat(got, ",") .. ")")
    local small = w.vein(2, 5)
    got = { c.swing(small), c.swing(small) }
    check(table.concat(got, ",") == "5,0", "a vein of 5 gives its 5 in one swing")
    stop(c)

    c = start("yield-cap", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 20", QUIET }) })
    w = c.world
    c.ticks(1)
    vein = w.vein(1, 15)
    got = { c.swing(vein), c.swing(vein) }
    check(table.concat(got, ",") == "15,0" and w.heroOre == 15, "a swing never gives more than the vein holds: 20 per swing from a vein of 15 gives 15")
    stop(c)

    -- the hero's attributes
    c = start("yield-hero", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 0", "Config.StrengthPerOre = 4", "Config.DexterityPerOre = 6",
        "Config.MinAmount = 0", "Config.LowVeinRule = false", QUIET }), diag = true })
    ue, w = c.ue, c.world
    check(printed(ue, "loaded: ore per swing: base 0, +1 per 4 Strength, +1 per 6 Dexterity, 0 to 100, the same from a nearly empty vein") ~= nil,
        "the load line: " .. tostring(ue.printed[1]):gsub("\n", ""))
    c.ticks(1)
    check(c.S.strength == 10 and c.S.dexterity == 10 and c.S.amount == 3 and w.numbers.m_AmountAtHighOre == 3 and w.numbers.m_AmountAtLowOre == 3,
        "Strength 10 and Dexterity 10: 2 + 1 = 3 per swing, also from a nearly empty vein")
    check(c.fake.value("mining.attributes") == "readable", "noted: the attributes could be read")
    w.attribute("Strength", 40.0)
    w.attribute("Dexterity", 22.0)
    c.ticks(18)
    check(w.numbers.m_AmountAtHighOre == 3, "new attributes are not looked for more often than every 5 seconds")
    c.ticks(2)
    check(w.numbers.m_AmountAtHighOre == 13 and w.numbers.m_AmountAtLowOre == 13 and c.S.amount == 13, "then the numbers follow: Strength 40 and Dexterity 22 = 10 + 3 = 13")
    check(has(status(c), "|ore per swing now: 13, Strength 40, Dexterity 22|"), "the status names the amount and what it comes from")
    vein = w.vein(1, 15)
    check(c.swing(vein) == 13 and c.swing(vein) == 2, "a vein of 15 gives 13 and then its last 2")
    stop(c)

    -- the extra ore: one roll per swing
    c = start("yield-extra", { config = config({ "Config.YieldEnabled = true", "Config.ExtraChance = 50", QUIET }) })
    w = c.world
    check(printed(c.ue, "loaded: ore per swing: base 3, 50% chance of one more, 1 to 100") ~= nil, "the load line names the chance")
    vein = w.vein(1, 15)
    Roll, Rolls = 0.49, 0
    c.ticks(4)
    check(Rolls == 0 and w.numbers.m_AmountAtHighOre == 3, "no roll while nobody swings: the numbers hold the plain amount")
    w.startSwing(vein)
    c.ticks(1)
    check(Rolls == 1 and w.numbers.m_AmountAtHighOre == 4, "a swing begins: one roll - 49 of 100 is below the chance of 50, the swing gives one more")
    c.ticks(30)
    check(Rolls == 1 and w.numbers.m_AmountAtHighOre == 4, "no second roll while the swing lasts (7 seconds)")
    got = w.endSwing(vein)
    c.ticks(1)
    check(got == 4 and w.numbers.m_AmountAtHighOre == 3 and c.S.extras == 1, "the swing gave 4; at once the numbers hold the plain amount again")
    Roll = 0.5
    check(c.swing(vein) == 3 and Rolls == 2 and c.S.extras == 1, "the next swing rolls again: 50 of 100 is not below 50 - no extra ore")
    stop(c)
    c = start("yield-extra-always", { config = config({ "Config.YieldEnabled = true", "Config.ExtraChance = 100", QUIET }) })
    Roll = 0.999
    vein = c.world.vein(1, 15)
    check(c.swing(vein) == 4, "a chance of 100: always one more")
    stop(c)
    Roll = 0.5

    -- the game's mining skill
    c = start("yield-skill", { config = config({ "Config.YieldEnabled = true", "Config.TrainedBonus = 2", "Config.MasterBonus = 4", QUIET }), diag = true })
    w = c.world
    check(printed(c.ue, "loaded: ore per swing: base 3, +2 for a trained miner, +4 for a master miner, 1 to 100") ~= nil, "the load line names the bonuses")
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 3 and c.fake.value("mining.skill_tags") == "readable" and w.tagAsked == 2,
        "a hero without the skill gets the base amount (both skill tags are asked for)")
    w.rank = "trained"
    c.ticks(20)
    check(w.numbers.m_AmountAtHighOre == 5 and has(status(c), "|ore per swing now: 5, a trained miner|"), "a trained miner: 3 + 2")
    w.rank = "master"
    c.ticks(20)
    check(w.numbers.m_AmountAtHighOre == 7 and has(status(c), "|ore per swing now: 7, a master miner|"), "a master miner: 3 + 4")
    stop(c)
    c = start("yield-noskill", { config = config({ "Config.YieldEnabled = true", "Config.StrengthPerOre = 5", QUIET }) })
    c.ticks(1)
    check(c.world.tagAsked == 0 and c.world.numbers.m_AmountAtHighOre == 5, "without a bonus for the skill the hero's tags are not asked")
    stop(c)

    c = start("yield-extra-one", { config = config({ "Config.YieldEnabled = true", "Config.ExtraChance = 1", QUIET }) })
    Roll = 0.005
    vein = c.world.vein(1, 15)
    check(c.S.swings == 0 and c.swing(vein) == 4 and c.S.swings == 1, "a chance of 1 is a chance: swings are watched for it, and a roll of 0.5 of 100 wins the extra ore")
    Roll = 0.01
    check(c.swing(vein) == 3, "a roll of exactly 1 of 100 does not")
    Roll = 0.5
    stop(c)
    c = start("yield-extra-broken", { config = config({ "Config.YieldEnabled = true", "Config.ExtraChance = 100", QUIET }) })
    vein = c.world.vein(1, 15)
    c.swing(vein, 2, true)
    check(c.S.extras == 0 and c.S.swings == 1, "an extra ore rolled for a swing that was broken off is not counted as given")
    stop(c)
    c = start("yield-extra-only", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 0", "Config.MinAmount = 0", "Config.ExtraChance = 100", QUIET }) })
    vein = c.world.vein(1, 15)
    check(c.swing(vein) == 1 and c.S.extras == 1 and c.S.amount == 0, "base 0 and a sure extra ore: the swing gives that 1, and it is counted")
    stop(c)
    c = start("yield-extra-full", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 6", "Config.MaxAmount = 6", "Config.ExtraChance = 100", QUIET }) })
    vein = c.world.vein(1, 15)
    check(c.swing(vein) == 6 and c.S.extras == 0, "an extra ore that the highest amount leaves no room for is not given and not counted")
    stop(c)

    -- one attribute alone, one ore per point
    c = start("yield-strength", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 0", "Config.StrengthPerOre = 1", QUIET }), diag = true,
        model = { strength = 12 } })
    c.ticks(1)
    check(c.world.numbers.m_AmountAtHighOre == 12 and c.S.dexterity == nil and c.world.byName.Dexterity == nil and c.fake.value("mining.attributes") == "readable",
        "one ore per point of Strength, Strength 12: 12 per swing; Dexterity is not read; noted that the attribute could be read")
    stop(c)
    c = start("yield-dexterity", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 0", "Config.DexterityPerOre = 1", QUIET }), diag = true,
        model = { dexterity = 9 } })
    c.ticks(1)
    check(c.world.numbers.m_AmountAtHighOre == 9 and c.S.strength == nil and c.world.byName.Strength == nil and c.fake.value("mining.attributes") == "readable",
        "the same for Dexterity alone: 9 per swing")
    stop(c)
    c = start("yield-master", { config = config({ "Config.YieldEnabled = true", "Config.MasterBonus = 1", QUIET }), model = { rank = "master" } })
    c.ticks(1)
    check(c.world.numbers.m_AmountAtHighOre == 4 and c.world.tagAsked == 1, "a bonus for the master alone (1): asked for and given")
    stop(c)

    -- a weak hero
    c = start("yield-zero", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 0", "Config.StrengthPerOre = 20", "Config.MinAmount = 0", QUIET }) })
    w = c.world
    c.ticks(1)
    vein = w.vein(1, 15)
    check(w.numbers.m_AmountAtHighOre == 0 and c.swing(vein) == 0 and vein.total() == 15, "an amount of 0: the swing gives nothing and the vein keeps its ore")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("4. settings while the game runs: what was changed in the game is put back")
do
    local QUIET = "Config.ShowMessage = false"
    local c = start("back", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 7", "Config.LowVeinRule = false", QUIET }) })
    local ue, w = c.ue, c.world
    local v = c.hook.settings.values
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 7 and w.numbers.m_AmountAtLowOre == 7 and c.mods.store["G1R_Mining:original"] == "3/1",
        "7 per swing is in the game's numbers; the game's own two amounts are kept in the shared store meanwhile")
    T.menuSet(c, "Resources", "Base amount", 9)
    c.ticks(1)
    check(v.BaseAmount == 9 and w.numbers.m_AmountAtHighOre == 9 and w.numbers.m_AmountAtLowOre == 9
        and printed(ue, "[G1R_Mining] settings changed (in-game menu): ore per swing: base 9, 1 to 100, the same from a nearly empty vein\n") ~= nil,
        "the base amount changed in the in-game menu: in the game's numbers at the next look, said in the log")
    T.menuSet(c, "Resources", "Nearly empty vein gives less", true)
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 9 and w.numbers.m_AmountAtLowOre == 1, "the rule for nearly empty veins switched on again: the game's own low amount is back")
    T.menuSet(c, "Resources", "Ore per swing from the numbers", false)
    c.ticks(1)
    check(v.YieldEnabled == false and w.numbers.m_AmountAtHighOre == 3 and w.numbers.m_AmountAtLowOre == 1 and c.mods.store["G1R_Mining:original"] == "",
        "the ore per swing switched off: both of the game's amounts are back, the shared store is cleared")
    check(printed(ue, "settings changed (in-game menu): nothing to change (ore per swing and veins as the game has them)") ~= nil and has(T.read(c.path), "Config.YieldEnabled = false\n"),
        "said in the log, written into config.lua")
    local reads, writes, checks, finds = w.n.reads, w.n.writes, w.n.checks, allOf(ue)
    c.ticks(240)
    check(w.n.reads == reads and w.n.writes == writes and w.n.checks == checks and allOf(ue) == finds and c.S.awake == false,
        "from then on the game is not looked at: 0 reads, 0 writes, 0 searches in a minute")
    check(has(status(c), "|nothing to change: the game is not looked at|"), "the status says so")
    T.menuSet(c, "Resources", "Ore per swing from the numbers", true)
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 9 and c.mods.store["G1R_Mining:original"] == "3/1", "switched on again: 9 per swing at the next look")
    -- the whole module off, through the file
    T.write(c.path, config({ "Config.Enabled = false", "Config.YieldEnabled = true", "Config.BaseAmount = 9", QUIET }))
    ue:fireConsole("mining reload")
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 3 and w.numbers.m_AmountAtLowOre == 1 and printed(ue, "[G1R_Mining] settings read: switched off in the settings\n") ~= nil,
        "Enabled = false in config.lua, read with `mining reload`: the game's numbers are back")
    reads = w.n.reads
    c.ticks(40)
    check(w.n.reads == reads and has(status(c), "v1.0.0 | switched off in the settings|nothing to change: the game is not looked at"), "and the module is at rest")
    T.write(c.path, config({ "Config.YieldEnabled = true", "Config.BaseAmount = 4", QUIET }))
    c.ticks(24)
    check(w.numbers.m_AmountAtHighOre == 4 and printed(ue, "[G1R_Mining] settings changed (config.lua): ore per swing: base 4, 1 to 100\n") ~= nil,
        "a changed file is picked up within seconds")
    stop(c)

    -- in the middle of a swing
    c = start("midswing", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 7", "Config.EndlessVeins = true", QUIET }) })
    w = c.world
    local vein = w.vein(1, 15)
    w.startSwing(vein)
    c.ticks(2)
    check(vein.total() == 22 and c.S.swing ~= nil, "a swing in progress with endless veins: the vein is filled to 15 + 7")
    T.menuSet(c, "Resources", "Base amount", 4)
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 4 and c.S.swing ~= nil and vein.total() == 22, "the base amount changed in the middle of the swing: the new amount counts for it")
    check(w.endSwing(vein) == 4, "the swing gives the new amount")
    c.ticks(1)
    check(c.swing(vein) == 4 and vein.total() == 15, "the next swing takes the ore that was left over first (18 -> no filling needed up to 19: 1 more), and the vein is at its size again")
    w.startSwing(vein)
    c.ticks(2)
    T.menuSet(c, "Resources", "Mining rework", false)
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 3 and c.S.swing == nil, "the module switched off in the middle of a swing: the game's numbers are back at once")
    check(w.endSwing(vein) == 3 and vein.total() == 16, "that swing gives the game's amount; one swing's filling is left in the vein (19 - 3)")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("5. veins that never run out")
do
    local QUIET = "Config.ShowMessage = false"
    Rolls = 0
    local c = start("endless", { config = config({ "Config.EndlessVeins = true", QUIET }), diag = true })
    local ue, w = c.ue, c.world
    check(printed(ue, "loaded: veins never run out") ~= nil, "the load line: " .. tostring(ue.printed[1]):gsub("\n", ""))
    local vein = w.vein(1, 15)
    c.ticks(4)
    check(vein.total() == 15 and vein.addCalls == 0 and w.numbers.m_AmountAtHighOre == 3, "nobody swings: the vein is not touched, the game's numbers are not changed")
    w.startSwing(vein)
    c.ticks(1)
    check(vein.total() == 18 and vein.addCalls == 1, "a swing begins: the vein is filled up to its size + the amount of the swing (15 + 3)")
    local a = vein.lastAdd
    check(a.kind == 1 and a.class == w.oreClass and a.amount == 3 and type(a.payload) == "table" and next(a.payload) == nil and a.predicted == false,
        "with the game's own function: main inventory (1), the ore's class, 3, an empty payload, not predicted")
    c.ticks(7)
    check(vein.total() == 18 and vein.addCalls == 1, "once per swing")
    local writes = w.n.writes
    c.ticks(240)
    check(vein.total() == 18 and vein.addCalls == 1 and w.n.writes == writes and Rolls == 0 and c.S.swings == 0,
        "the swing stays in progress for a minute (the game is paused in the middle of it): nothing is done a second time")
    check(w.endSwing(vein) == 3, "the swing gives the game's 3")
    c.ticks(1)
    check(vein.total() == 15 and c.S.swings == 1 and c.S.putBack == 3 and c.S.ore_given == 3, "afterwards the vein holds its 15 again")
    local sum = 0
    for _ = 1, 20 do sum = sum + c.swing(vein, 2) end
    check(sum == 60 and vein.total() == 15 and w.heroOre == 63, "20 more swings: 3 each, the vein stays at 15")
    check(c.fake.value("mining.vein_add") == "function" and c.fake.detail("mining.vein_add") == "complete" and c.fake.value("mining.vein_count") == "function"
        and c.fake.value("mining.vein_size_from") == "default contents" and c.fake.value("mining.vein_module") == "module list"
        and c.fake.value("mining.vein_reference") == "weak pointer" and c.fake.value("mining.ability_found_by") == "ability list"
        and c.fake.value("mining.swing_gave") == "as the numbers say" and c.fake.value("mining.ore_class") == "world definition",
        "noted: how the ability, the vein, its container, its size and its ore were reached, and that the swing gave what the numbers said")
    check(#ue.lookups == 0 and allOf(ue) == 1 and w.n.flood == 0 and w.n.indexed == 0 and w.n.stale == 0,
        "all of it without a search by path, without the logged property names, without indexing an array")
    check(w.n.writes == 0 and c.mods.store["G1R_Mining:original"] == nil and c.fake.value("mining.config_write") == nil and c.fake.value("mining.config_kept") == nil
        and c.S.dirty == false and c.S.extras == 0 and Rolls == 0,
        "the game's numbers are only read for this: nothing is written, nothing is kept in the shared store, nothing is rolled")
    check(vein.lastWanted == 1, "the game's counting function is asked the way the module repopulate asks it (at least 1 of the item)")
    -- a vein that was mined down before, and one that is empty
    local used = w.vein(2, 15, 2)
    local looked = used.shown
    w.startSwing(used)
    c.ticks(1)
    check(used.total() == 17 and looked == 1, "a vein mined down to 2 (the game shows 1 of its 5 pieces of ore) is filled up as well - to one below its 15 + 3")
    check(w.endSwing(used) == 3 and used.total() == 14 and used.shown == 5,
        "it gives the full amount and holds 14: the game redraws a vein only while it holds fewer than 15 - now it shows all 5 pieces again")
    c.ticks(1)
    check(c.swing(used) == 3 and used.total() == 15 and used.shown == 5, "from the next swing on it is kept at its 15")
    local again = w.vein(4, 15, 6)
    c.swing(again, 2, true)
    check(again.total() == 17 and again.shown == 3, "a mined-down vein whose first swing is broken off: filled, but not redrawn by the game")
    check(c.swing(again) == 3 and again.total() == 14 and again.shown == 5 and c.swing(again) == 3 and again.total() == 15,
        "the next swing still keeps it one below 15, so that it is redrawn; the one after that goes to 15")
    local nearly = w.vein(5, 15, 14)
    check(c.swing(nearly) == 3 and nearly.total() == 15 and nearly.shown == 5, "a vein found with 14 shows every piece already: kept at 15 at once")
    local middle = w.vein(6, 10, 4)
    check(c.swing(middle) == 3 and middle.total() == 10 and middle.shown == 4, "a vein of 10 is always redrawn (10 is below 15): kept at 10, shown as the game shows a new one")
    local empty = w.vein(3, 10, 0)
    check(c.swing(empty) == 3 and empty.total() == 10, "an empty vein of 10 comes back (if the game lets the hero swing at it)")
    -- breaking a swing off piles nothing up
    for _ = 1, 5 do c.swing(vein, 2, true) end
    check(vein.total() == 18 and w.heroOre == 84, "five swings broken off before the pickaxe hit: the vein holds 18, not more (the filling is a level), and the hero got nothing")
    check(c.swing(vein) == 3 and vein.total() == 15, "the next full swing takes its 3 from that")
    check(table.concat(c.fake.values("mining.swing_gave"), ",") == "as the numbers say", "a swing without ore says nothing about the numbers: the note stays as it was")
    check(#c.hook.status() == 3 and has(c.hook.status()[2], "the game's own numbers: 3 ore per swing"), "the status has no line for the ore per swing (it is the game's)")
    local thirteen = w.vein(7, 15, 13)
    check(c.swing(thirteen) == 3 and thirteen.total() == 14 and c.swing(thirteen) == 3 and thirteen.total() == 15,
        "a vein found with 13 counts as mined down (the module does not know how many pieces the game's picture has): one swing at 14, then 15")
    stop(c)
    c = start("endless-one", { config = config({ "Config.EndlessVeins = true", QUIET }), diag = true })
    w = c.world
    local tiny = w.vein(1, 1)
    check(c.swing(tiny) == 3 and tiny.total() == 3 and c.fake.value("mining.vein_size_from") == "default contents",
        "a vein whose default contents are 1 ore: that is a size (it is filled to one above the game's threshold: 6, and holds 3 afterwards)")
    stop(c)

    -- mined down in this world, then switched to endless
    c = start("endless-later", { config = config({ "Config.VeinLastsTimes = 2", QUIET }) })
    w = c.world
    vein = w.vein(1, 15)
    c.swing(vein)
    c.swing(vein)
    check(vein.total() == 12 and vein.shown == 4, "(two swings at a vein that lasts longer: 12 left, the game shows 4 of 5 pieces)")
    T.menuSet(c, "Resources", "Veins never run out", true)
    c.ticks(1)
    check(c.swing(vein) == 3 and vein.total() == 14 and vein.shown == 5 and c.swing(vein) == 3 and vein.total() == 15,
        "veins switched to endless: the vein the module saw being mined down is kept at 14 once, then at 15")
    stop(c)
    -- A swing that leaves exactly 15 in the vein: the game redraws nothing then (it only does below 15).
    c = start("endless-fifteen", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 3", "Config.EndlessVeins = true", QUIET }) })
    w = c.world
    vein = w.vein(1, 15, 6)
    c.swing(vein, 2, true)
    check(vein.total() == 17 and vein.shown == 3, "(a mined-down vein, its first swing broken off: filled to 14 + 3, still shown as mined down)")
    T.menuSet(c, "Resources", "Base amount", 2)
    c.ticks(1)
    check(c.swing(vein) == 2 and vein.total() == 15 and vein.shown == 3, "(then a swing of 2: the vein is left with exactly 15, which the game does not redraw)")
    check(c.swing(vein) == 2 and vein.total() == 14 and vein.shown == 5, "the module knows that: the next swing still leaves 14, and the game redraws the vein")
    check(c.swing(vein) == 2 and vein.total() == 15 and vein.shown == 5, "and the one after that 15")
    stop(c)
    c = start("endless-undrawn", { config = config({ "Config.EndlessVeins = true", QUIET }), change = function(w) w.config.__blind = { m_VisualMaxOre = true } end })
    w = c.world
    vein = w.vein(1, 15, 2)
    check(c.swing(vein) == 3 and vein.total() == 15 and c.S.game.drawn == nil and #c.ue.errors == 0,
        "the game's redraw limit cannot be read: a mined-down vein is kept at its 15 at once (it may go on looking mined down)")
    stop(c)

    -- with an amount of the module's
    c = start("endless-yield", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 20", "Config.EndlessVeins = true", QUIET }) })
    w = c.world
    check(printed(c.ue, "loaded: ore per swing: base 20, 1 to 100; veins never run out") ~= nil, "the load line names both")
    local small = w.vein(1, 5)
    w.startSwing(small)
    c.ticks(1)
    check(small.total() == 25, "20 per swing from a vein of 5: it is filled to 25")
    check(w.endSwing(small) == 20 and small.total() == 5, "the swing gives the full 20 and the vein keeps its 5")
    c.ticks(1)
    stop(c)
    c = start("endless-player", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 0", "Config.StrengthPerOre = 4", "Config.DexterityPerOre = 6",
        "Config.MinAmount = 0", "Config.LowVeinRule = false", "Config.EndlessVeins = true", QUIET }), model = { strength = 62, dexterity = 40 } })
    w = c.world
    vein = w.vein(1, 15)
    local got = { c.swing(vein), c.swing(vein), c.swing(vein) }
    check(table.concat(got, ",") == "21,21,21" and vein.total() == 15,
        "the player's settings so far, Strength 62 and Dexterity 40: 15 + 6 = 21 per swing from a vein of 15, which stays at 15")
    stop(c)
    -- an amount of 0 from a small vein: the vein must count as full for the game to give 0
    c = start("endless-zero", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 0", "Config.MinAmount = 0", "Config.EndlessVeins = true", QUIET }) })
    w = c.world
    small = w.vein(1, 5)
    check(c.swing(small) == 0 and small.total() == 6, "0 per swing from a vein of 5: it is filled to 6 (one above the game's threshold), so that the game gives 0 and not its 1")
    check(c.swing(small) == 0 and small.total() == 6 and small.addCalls == 1, "and stays there")
    stop(c)
    -- both vein settings: endless counts
    c = start("endless-and-longer", { config = config({ "Config.EndlessVeins = true", "Config.VeinLastsTimes = 4", QUIET }) })
    w = c.world
    check(printed(c.ue, "loaded: veins never run out\n") ~= nil, "veins never run out and last 4 times as long: the first counts (load line)")
    vein = w.vein(1, 15)
    check(c.swing(vein) == 3 and c.swing(vein) == 3 and vein.total() == 15 and vein.added == 6, "nothing is put back on top of the filling")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("6. veins that last longer")
do
    local QUIET = "Config.ShowMessage = false"
    local function life(c, vein, most)
        local got, left = {}, {}
        for i = 1, most do
            got[i] = c.swing(vein, 2)
            left[i] = vein.total()
            if got[i] == 0 then break end
        end
        return table.concat(got, ","), table.concat(left, ",")
    end
    local c = start("longer", { config = config({ "Config.VeinLastsTimes = 2", QUIET }), diag = true })
    local w = c.world
    check(printed(c.ue, "loaded: a vein lasts 2 times as long") ~= nil, "the load line: " .. tostring(c.ue.printed[1]):gsub("\n", ""))
    local small = w.vein(1, 5)
    local got, left = life(c, small, 20)
    -- by hand: a vein of 5 gives 1 per swing (the game's rule); half of each is owed back, a whole ore is put
    -- back after every second swing: 4, 4, 3, 3, 2, 2, 1, 1 (empty for a moment, then 1 again), 0
    check(got == "1,1,1,1,1,1,1,1,1,0" and left == "4,4,3,3,2,2,1,1,0,0", "twice as long, a vein of 5: nine swings of 1 instead of five (" .. got .. " / " .. left .. ")")
    check(w.heroOre == 9 and small.added == 4 and c.S.putBack == 4, "9 ore in all: the 5 of the vein and 4 put back - never more than was taken")
    check(c.fake.value("mining.swing_gave") == "as the numbers say" and c.fake.count["mining.swing_gave"] == 1, "swings of 1 ore are swings: noted that they gave what the numbers say")
    check(c.fake.value("mining.vein_add") == "function" and c.fake.count["mining.vein_add"] == 1, "noted once: how ore is put into a vein")
    stop(c)

    c = start("longer-3", { config = config({ "Config.VeinLastsTimes = 3", "Config.YieldEnabled = true", "Config.BaseAmount = 5", "Config.LowVeinRule = false", QUIET }) })
    w = c.world
    local vein = w.vein(1, 15)
    got, left = life(c, vein, 30)
    -- by hand: each swing of 5 owes 3 1/3; put back 3, 3, 4, 3, 3, 4, then of the rests
    check(got == "5,5,5,5,5,5,5,3,2,1,1,1,0" and left == "13,11,10,8,6,5,3,2,1,1,1,0,0",
        "three times as long, 5 per swing from a vein of 15: " .. got .. " (vein: " .. left .. ")")
    check(w.heroOre == 43 and vein.added == 28, "43 ore instead of 15: 28 were put back, two thirds of what was taken (the last fraction is lost)")
    stop(c)

    -- only what a swing really took is put back
    c = start("longer-broken", { config = config({ "Config.VeinLastsTimes = 4", QUIET }) })
    w = c.world
    vein = w.vein(1, 15)
    for _ = 1, 6 do c.swing(vein, 2, true) end
    check(vein.total() == 15 and vein.addCalls == 0 and c.S.swings == 6 and c.S.ore_given == 0, "swings that are broken off give nothing and put nothing back")
    check(c.swing(vein) == 3 and vein.total() == 14 and vein.added == 2, "a swing of 3 with 4 times as long: 2 1/4 are owed, 2 are put back")
    check(c.swing(vein) == 3 and vein.total() == 13 and vein.added == 4, "the next: 2 1/4 + 1/4, 2 again")
    c.swing(vein)
    c.swing(vein)
    check(vein.added == 9 and vein.total() == 12, "after four swings the quarters make a whole ore: 9 put back of 12 taken")
    -- another vein has its own account
    local other = w.vein(2, 10)
    check(c.swing(other) == 3 and other.added == 2 and c.swing(vein) == 3 and vein.added == 11, "each vein has its own account of what is owed")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("7. the note on screen and the line in the log")
do
    Rolls = 0
    local c = start("note", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 7", "Config.LogSwings = true" }), widgets = true })
    local ue, w, ui = c.ue, c.world, c.ui
    c.ticks(1)
    local perPath = {}
    for _, p in ipairs(ue.lookups) do perPath[p] = (perPath[p] or 0) + 1 end
    local once, paths = true, 0
    for _, n in pairs(perPath) do paths = paths + 1 if n ~= 1 then once = false end end
    check(once and paths == 6 and ui.created == 0, "when the hero's mining ability is found the six paths of the note are searched, each once; nothing is built yet")
    local vein = w.vein(1, 15)
    check(c.swing(vein) == 7 and ui.note() == "Mining: 7 ore (the game gives 3)", "a swing that gave more than the game would: " .. tostring(ui.note()))
    check(printed(ue, "[G1R_Mining] swing at BP_MiningSpot_C_1: 7 ore (the game's own amount: 3); ore in the vein: 15, 8 after the swing\n") ~= nil,
        "the line in the log: " .. tostring(ue.printed[#ue.printed]):gsub("\n", ""))
    check(c.swing(vein) == 7 and ui.note() == "Mining: 7 ore (the game gives 3)", "the next swing: the same note again")
    c.ticks(16)
    check(c.swing(vein) == 1 and ui.note() == nil and printed(ue, "swing at BP_MiningSpot_C_1: 1 ore (the game's own amount: 1); ore in the vein: 1, 0 after the swing") ~= nil,
        "the last ore of the vein: the game would give that 1 as well - no note, but a line in the log")
    c.swing(vein)
    check(ui.note() == nil and printed(ue, "swing at BP_MiningSpot_C_1: 0 ore (the game's own amount: 0); ore in the vein: 0, 0 after the swing") ~= nil,
        "a swing at the empty vein: 0 ore, no note")
    local full = w.vein(2, 15)
    c.swing(full, 4, true)
    check(ui.note() == nil and printed(ue, "swing at BP_MiningSpot_C_2: 0 ore (the game's own amount: 3); ore in the vein: 15, 15 after the swing") ~= nil,
        "a swing that was broken off: no note (the game would have given nothing either)")
    check(#ue.lookups == 6 and has(status(c), "|swings seen: 5, ore: 15 (by the game's own numbers: 7), put into veins: 0; last: 0 ore from BP_MiningSpot_C_2"),
        "the status counts swings and ore: " .. c.hook.status()[#c.hook.status()])
    -- switched off while a note is up
    c.swing(full)
    local up = ui.note()
    T.menuSet(c, "Resources", "Note when a swing gave more/less", false)
    c.ticks(1)
    check(up == "Mining: 7 ore (the game gives 3)" and ui.note() == nil, "ShowMessage switched off while a note is up: it is hidden at once")
    local calls = #ui.calls
    c.swing(full)
    check(#ui.calls == calls and w.heroOre == 29, "and no further note is shown")
    check(Rolls == 0, "without a chance for an extra ore nothing is rolled")
    stop(c)
    c = start("note-threshold", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 7" }), widgets = true, diag = true })
    w = c.world
    check(c.swing(w.vein(1, 5)) == 1 and c.ui.note() == nil and c.fake.value("mining.swing_gave") == "as the numbers say",
        "a vein of exactly 5 counts as nearly empty for the game (more than 5 is full): 1 ore, as the module expects - no note, no difference noted")
    check(c.swing(w.vein(2, 6)) == 6 and c.ui.note() == "Mining: 6 ore (the game gives 3)", "a vein of 6 is full: it gives its 6 of the 7")
    stop(c)

    c = start("note-less", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 1" }), widgets = true })
    w = c.world
    check(c.swing(w.vein(1, 15)) == 1 and c.ui.note() == "Mining: 1 ore (the game gives 3)", "a swing that gave less: " .. tostring(c.ui.note()))
    stop(c)
    c = start("note-none", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 0", "Config.MinAmount = 0" }), widgets = true })
    w = c.world
    check(c.swing(w.vein(1, 15)) == 0 and c.ui.note() == "Mining: 0 ore (the game gives 3)", "a swing that gives nothing by the settings says so: " .. tostring(c.ui.note()))
    stop(c)
    c = start("note-same", { config = config(PLAYER), widgets = true })
    w = c.world
    check(c.swing(w.vein(1, 15)) == 3 and c.ui.note() == nil and c.ui.created == 0, "the player's settings so far at Strength 10 / Dexterity 10: 3 as in the game - no note")
    w.attribute("Strength", 22.0)
    check(c.swing(w.veins[1]) == 6 and c.ui.note() == "Mining: 6 ore (the game gives 3)", "with Strength 22: 5 + 1 = 6, and a note")
    stop(c)
    c = start("note-vein", { config = config({ "Config.EndlessVeins = true", "Config.LogSwings = true" }), widgets = true })
    w = c.world
    local low = w.vein(1, 15, 2)
    check(c.swing(low) == 3 and c.ui.note() == "Mining: 3 ore (the game gives 1)", "a nearly empty vein that never runs out: 3 where the game would give 1")
    check(printed(c.ue, "swing at BP_MiningSpot_C_1: 3 ore (the game's own amount: 1); ore in the vein: 2, filled to 17, 14 after the swing") ~= nil, "the log line names the filling")
    stop(c)
    c = start("note-back", { config = config({ "Config.VeinLastsTimes = 3", "Config.LogSwings = true" }), widgets = true })
    w = c.world
    check(c.swing(w.vein(1, 15)) == 3 and c.ui.note() == nil
        and printed(c.ue, "swing at BP_MiningSpot_C_1: 3 ore (the game's own amount: 3); ore in the vein: 15, 12 after the swing, 2 put back") ~= nil,
        "a vein that lasts longer: the swing gives what the game gives (no note); the log line names what was put back")
    stop(c)
    c = start("note-subtitle", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 4" }), widgets = true })
    c.kit.configureNotes({ style = "subtitle" })
    w = c.world
    c.swing(w.vein(1, 15))
    check(#c.ui.subtitles == 1 and c.ui.subtitles[1].text == "Mining: 4 ore (the game gives 3)" and c.ui.created == 0,
        "notes set to the game's own line (page General): the note goes there")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("8. the hero's mining ability and the vein it is aimed at")
do
    local QUIET = "Config.ShowMessage = false"
    local ENDLESS = config({ "Config.EndlessVeins = true", QUIET })
    local c = start("ability", { config = ENDLESS, diag = true })
    local ue, w = c.ue, c.world
    c.ticks(1)
    check(c.S.ability and c.S.ability.object == w.ability and c.S.ability.via == "ability list" and allOf(ue) == 1,
        "found in the hero's own list of abilities - no search among all objects for it")
    local n = w.byName.Ability
    c.ticks(40)
    check(w.byName.Ability == n and n == 7, "the list is walked once (7 entries), not at every look")
    stop(c)
    c = start("ability-middle", { config = ENDLESS, model = { others = 3, behind = 4 } })
    c.ticks(1)
    check(c.S.ability and c.S.ability.object == c.world.ability and c.world.byName.Ability == 4, "the list is walked up to the mining ability's entry (the fourth of eight), not further")
    stop(c)
    c = start("ability-entries", { config = ENDLESS, change = function(w)
        w.dead = thing(w, "GameplayAbilityMining " .. STATE .. ".GameplayAbilityMining_1", { bIsActive = true })
        w.dead.__valid = false
        w.entry.NonReplicatedInstances = array(w, { w.dead, w.abilityDefault })
        w.entry.ReplicatedInstances = array(w, { w.ability })
    end })
    c.ticks(1)
    check(c.S.ability and c.S.ability.object == c.world.ability and c.world.n.stale == 0,
        "an entry that also lists a dead object and the class's default object: neither is taken, the dead one is not touched")
    stop(c)

    -- the game keeps the object in the other of the entry's two lists
    c = start("ability-replicated", { config = ENDLESS, change = function(w)
        w.entry.NonReplicatedInstances, w.entry.ReplicatedInstances = w.entry.ReplicatedInstances, w.entry.NonReplicatedInstances
    end })
    c.ticks(1)
    check(c.S.ability and c.S.ability.object == c.world.ability, "the ability object in the entry's list of replicated instances is found as well")
    check(c.swing(c.world.vein(1, 15)) == 3 and c.world.veins[1].total() == 15, "and swings are seen")
    stop(c)

    -- the hero's list is not usable: a search among all objects, the object inside the hero's player state
    local function unlisted(w, ue)
        w.hero.component.ActivatableAbilities = nil
        w.foreign = thing(w, "GameplayAbilityMining /Game/Maps/World.World:PersistentLevel.GothicPlayerState_77.GameplayAbilityMining_5", { bIsActive = true })
        w.old = thing(w, "GameplayAbilityMining " .. STATE .. ".GameplayAbilityMining_4", { bIsActive = true })
        w.old.__valid = false
        w.alike = thing(w, "GameplayAbilityMining /Game/Maps/World.World:PersistentLevel.xGothicPlayerState_21x.GameplayAbilityMining_6", { bIsActive = true })
        w.deeper = thing(w, "GameplayAbilityMining " .. STATE .. ".Something.GameplayAbilityMining_8", { bIsActive = true })
        ue.allOf.GameplayAbilityMining = { w.abilityDefault, w.alike, w.deeper, w.foreign, w.old, w.ability }
    end
    c = start("ability-scan", { config = ENDLESS, diag = true, change = unlisted })
    ue, w = c.ue, c.world
    c.ticks(8)
    check(c.S.ability == nil and allOf(ue) == 1, "the list is tried three times, a second apart, before anything else")
    c.ticks(1)
    check(c.S.ability and c.S.ability.object == w.ability and c.S.ability.via == "scan" and allOf(ue) == 2 and c.fake.value("mining.ability_found_by") == "scan",
        "then one search among all objects: the hero's ability (the last of six) - not the default object, not another player state's, not one of a "
        .. "state with a similar name, not one deeper inside the hero's state, not a dead one")
    check(w.n.stale == 0, "the dead object was only asked whether it exists")
    check(c.swing(w.vein(1, 15)) == 3 and w.veins[1].total() == 15 and allOf(ue) == 2, "swings are seen; no further search")
    stop(c)

    -- no mining ability at all
    c = start("ability-none", { config = ENDLESS, change = function(w, ue)
        w.hero.component.ActivatableAbilities = nil
        ue.allOf.GameplayAbilityMining = { w.abilityDefault }
    end })
    ue, w = c.ue, c.world
    local vein = w.vein(1, 15)
    c.ticks(240)
    local first = allOf(ue) - 1
    check(first == 4, "not found: searched again with growing pauses - 4 times in the first minute (" .. first .. ")")
    c.ticks(240 * 4)
    check(allOf(ue) - 1 - first == 2, "and the pauses go on growing (" .. (allOf(ue) - 1 - first) .. " more in the next four minutes)")
    c.ticks(240 * 35)
    check(allOf(ue) - 1 == 10, "ten searches among all objects in forty minutes without the ability - once in ten minutes in the end (" .. (allOf(ue) - 1) .. ")")
    check(c.S.abilityTries == 45, "the hero's own list was read 45 times in that time - once a minute in the end (" .. tostring(c.S.abilityTries) .. ")")
    check(printedCount(ue, "the hero's mining ability was not found (yet): swings are not seen") == 1 and #ue.errors == 0, "said once in the log, no error")
    check(c.swing(vein) == 3 and vein.total() == 12 and vein.addCalls == 0, "mining goes on as the game has it")
    stop(c)
    -- the hero gets the ability late: his own list goes on being read once a minute, whatever the pause of the search has grown to
    local listLater
    c = start("ability-late", { config = ENDLESS, change = function(w, ue)
        listLater = w.hero.component.ActivatableAbilities
        w.hero.component.ActivatableAbilities = nil
        ue.allOf.GameplayAbilityMining = { w.abilityDefault }
    end })
    ue, w = c.ue, c.world
    c.ticks(240 * 20)
    local before = allOf(ue) - 1
    w.hero.component.ActivatableAbilities = listLater
    c.ticks(244)
    check(before == 8 and c.S.ability ~= nil and c.S.ability.via == "ability list" and allOf(ue) - 1 == before,
        "twenty minutes without the ability (" .. before .. " searches), then the hero has it: found in his own list within a minute, with no further search among all objects")
    check(c.swing(w.vein(1, 15)) == 3 and #ue.errors == 0, "and swings are seen")
    stop(c)
    c = start("ability-noscan", { config = ENDLESS, change = function(w, ue)
        w.hero.component.ActivatableAbilities = nil
    end })
    c.ticks(40)
    check(c.S.ability == nil and #c.ue.errors == 0, "a search that gives no list at all: no ability, no error")
    stop(c)

    -- the object goes away, or its wrapper names another object
    c = start("ability-gone", { config = ENDLESS })
    ue, w = c.ue, c.world
    vein = w.vein(1, 15)
    w.startSwing(vein)
    c.ticks(2)
    local newer = thing(w, "GameplayAbilityMining " .. STATE .. ".GameplayAbilityMining_2147482999", { bIsActive = false })
    rawget(newer, "__data").m_InteractiveActor = weak(w, function() return w.target end)
    w.ability.__valid = false
    w.entry.NonReplicatedInstances = array(w, { newer })
    c.ticks(1)
    check(c.S.ability and c.S.ability.object == newer and c.S.swing == nil and w.n.stale == 0,
        "the ability object is gone in the middle of a swing: the swing is dropped, the hero's new object is found, the dead one is not touched")
    rawget(newer, "__data").bIsActive = true
    c.ticks(1)
    check(c.S.swing ~= nil and vein.total() == 18, "a swing of the new object is seen")
    rawget(newer, "__data").bIsActive = false
    c.ticks(1)
    newer.__full = "GameplayAbilityOpen /Game/Maps/World.World:PersistentLevel.GothicNPCState_3.GameplayAbilityOpen_9"
    rawget(newer, "__data").bIsActive = true
    local third = thing(w, "GameplayAbilityMining " .. STATE .. ".GameplayAbilityMining_2147483000", { bIsActive = false })
    w.entry.NonReplicatedInstances = array(w, { third })
    c.ticks(1)
    check(c.S.ability.object == third and c.S.swing == nil, "a kept wrapper that now names another object (its address was used again) is dropped: no swing is seen in it")
    stop(c)

    c = start("ability-again", { config = ENDLESS })
    ue, w = c.ue, c.world
    c.ticks(1)
    local later = thing(w, "GameplayAbilityMining " .. STATE .. ".GameplayAbilityMining_2147483555", { bIsActive = false })
    countScans(c, { later })
    c.ticks(2)
    w.ability.__valid = false                           -- gone, and the hero's list is not usable any more
    w.hero.component.ActivatableAbilities = nil
    c.ticks(1)
    check(c.S.ability == nil and c.S.abilityTries == 1 and c.scans() == 0, "the ability object is gone and the list does not show a new one: the search starts again with the list")
    c.ticks(7)
    check(c.scans() == 0 and c.S.abilityTries == 2, "second try a second later - still no search among all objects")
    c.ticks(1)
    check(c.scans() == 1 and c.S.ability and c.S.ability.object == later, "third try: now the search among all objects, which finds the new object")
    stop(c)
    c = start("ability-nohero", { config = ENDLESS })
    ue, w = c.ue, c.world
    c.ticks(1)
    countScans(c, {})
    c.ticks(2)                                          -- t = 0.75 s
    w.ability.__valid = false
    w.hero.component.ActivatableAbilities = nil
    c.ticks(1)                                          -- the first try of the new search: 1 s
    c.ticks(1)                                          -- 1.25 s: the hero is asked for (once a second) - still there
    w.controller.PlayerState = nil                      -- then he is gone
    c.ticks(3)                                          -- 2.0 s: the second try is due before the hero is asked for again
    check(c.S.abilityTries == 1 and c.S.hero ~= nil and c.scans() == 0, "a try that finds no hero is no try: nothing is searched")
    c.ticks(1)
    check(c.S.hero == nil and c.S.awake == false and #ue.errors == 0, "at the next look for the hero the module rests")
    stop(c)

    -- another hero (a new game, a loaded save without a map load)
    c = start("ability-hero", { config = ENDLESS })
    ue, w = c.ue, c.world
    c.ticks(1)
    local second = T.hero(ue, w, 40)
    local theirs = thing(w, "GameplayAbilityMining /Game/Maps/World.World:PersistentLevel.GothicPlayerState_40.GameplayAbilityMining_7", { bIsActive = false })
    second.component.ActivatableAbilities = struct(w, { Items = array(w, { struct(w, { Ability = w.abilityDefault,
        NonReplicatedInstances = array(w, { theirs }), ReplicatedInstances = array(w, {}) }) }) })
    w.controller.PlayerState = second.state
    rawget(w.ability, "__data").bIsActive = true        -- the old hero's ability is still there and looks active
    c.ticks(4)
    check(c.S.ability.object == theirs and c.S.swing == nil and c.S.hero == second.state:GetFullName(),
        "another player state: its mining ability is taken, the old one is not watched any more")
    stop(c)

    -- how the game hands the vein out
    c = start("vein-object", { config = ENDLESS, diag = true, change = function(w)
        rawget(w.ability, "__data").m_InteractiveActor = nil
    end })
    w = c.world
    vein = w.vein(1, 15)
    rawget(w.ability, "__data").m_InteractiveActor = vein.actor
    rawget(w.ability, "__data").bIsActive = true
    c.ticks(1)
    check(vein.total() == 18 and c.fake.value("mining.vein_reference") == "object", "a build that hands the vein out as the object itself: taken as well, and noted")
    stop(c)
    c = start("vein-late", { config = ENDLESS })
    w = c.world
    vein = w.vein(1, 15)
    rawget(w.ability, "__data").bIsActive = true        -- active, but not aimed at anything yet
    c.ticks(3)
    check(c.S.swing == nil and vein.total() == 15 and #c.ue.errors == 0, "an active ability that names no vein yet: nothing happens")
    w.target = vein.actor
    c.ticks(1)
    check(c.S.swing ~= nil and vein.total() == 18, "the look after it does: the swing begins")
    check(w.endSwing(vein) == 3, "and gives its ore")
    stop(c)
    c = start("vein-lowercase", { config = ENDLESS, change = function(w)
        local get = function() return w.target or w.ue:invalid() end
        rawget(w.ability, "__data").m_InteractiveActor = { get = get }
    end })
    w = c.world
    check(c.swing(w.vein(1, 15)) == 3 and w.veins[1].total() == 15, "a weak reference that only knows get() (the other spelling): the vein is found")
    stop(c)
    c = start("nobody", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 7", "Config.EndlessVeins = true" }),
        change = function(_, ue) ue.allOf["GothicPlayerControllerBaseBP_C"] = nil end })
    ue, w = c.ue, c.world
    c.ticks(80)
    check(#ue.lookups == 0 and w.n.reads == 0 and w.n.checks == 0 and c.S.awake == false and c.S.config == nil and #ue.errors == 0,
        "no hero (the main menu): nothing is searched by path and nothing is read, for 20 seconds")
    check(has(status(c), "|the game's mining numbers have not been found yet (no game loaded?)|"), "the status says that no game seems to be loaded")
    stop(c)
    c = start("active-odd", { config = ENDLESS, change = function(w)
        w.ability.__empty = true
        rawget(w.ability, "__data").bIsActive = nil
    end })
    w = c.world
    vein = w.vein(1, 15)
    w.target = vein.actor
    c.ticks(8)
    check(c.S.swing == nil and vein.total() == 15 and #c.ue.errors == 0, "an ability whose active flag is not a yes/no value (UE4SS gives an empty object for a missing name): never taken as active")
    stop(c)

    -- When the ability comes to rest after the ore was handed out is not known (dev/facts/mining.md M17), and
    -- the hero can swing again before the module looks. So the module also goes by the vein's ore.
    local LOGGED = "Config.LogSwings = true"
    c = start("linger", { config = config({ "Config.EndlessVeins = true", LOGGED, QUIET }), diag = true })
    ue, w = c.ue, c.world
    vein = w.vein(1, 15)
    w.startSwing(vein)
    c.ticks(8)
    check(w.handOut(vein) == 3 and vein.total() == 15, "(the game hands the ore out; the ability stays active)")
    c.ticks(1)
    check(c.S.swings == 1 and c.S.ore_given == 3 and printedCount(ue, "swing at BP_MiningSpot_C_1: 3 ore") == 1,
        "the ore was handed out and the ability is active still: the look after it counts the swing")
    check(c.fake.value("mining.swing_end") == "ability still active", "noted: the ability does not come to rest with the hand-out")
    check(vein.total() == 18 and vein.addCalls == 2 and c.S.swing ~= nil, "and takes the ability for swinging on: the vein is filled for the next swing at once")
    c.ticks(3)
    check(vein.total() == 18 and vein.addCalls == 2 and c.S.swings == 1, "nothing more while it stays active")
    w.release()
    c.ticks(1)
    check(c.S.swings == 1 and c.S.swing == nil and printedCount(ue, "swing at ") == 1 and c.fake.count["mining.swing_gave"] == 1,
        "the ability comes to rest and no ore was taken since: that was the end of the same swing - not counted, no line, no note")
    check(c.swing(vein) == 3 and vein.total() == 15 and vein.addCalls == 2 and c.S.swings == 2, "the next swing finds the vein filled already and gives its 3")
    check(c.fake.value("mining.swing_end") == "ability still active" and c.fake.count["mining.swing_end"] == 1,
        "(this one ended with the ability at rest) the note stays: it says what was seen at least once")
    local used = w.vein(2, 15, 6)
    w.startSwing(used)
    c.ticks(8)
    check(w.handOut(used) == 3 and used.total() == 14 and used.shown == 5, "(a mined-down vein, kept at 14 for its first swing: the game redraws it)")
    c.ticks(1)
    check(used.total() == 18, "the filling for the next swing goes to the full 15 + 3: the vein has been redrawn")
    w.release()
    c.ticks(1)
    stop(c)
    c = start("at-once", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 20", "Config.EndlessVeins = true", LOGGED, QUIET }), diag = true })
    ue, w = c.ue, c.world
    vein = w.vein(1, 15)
    w.startSwing(vein)
    c.ticks(8)
    local got = { w.handOut(vein) }
    c.ticks(8)
    got[2] = w.handOut(vein)
    c.ticks(8)
    got[3] = w.endSwing(vein)
    c.ticks(1)
    check(table.concat(got, ",") == "20,20,20" and vein.total() == 15,
        "three swings with no look at rest between them (the hero swings again at once), 20 ore per swing from an endless vein of 15: each gives the full 20 ("
        .. table.concat(got, ",") .. ")")
    check(c.S.swings == 3 and c.S.ore_given == 60 and c.S.game_gives == 9 and printedCount(ue, "swing at BP_MiningSpot_C_1: 20 ore (the game's own amount: 3)") == 3,
        "each is counted and logged by itself")
    check(table.concat(c.fake.values("mining.swing_gave"), ",") == "as the numbers say", "and each gave what the numbers say")
    stop(c)
    c = start("at-once-longer", { config = config({ "Config.VeinLastsTimes = 3", LOGGED, QUIET }) })
    ue, w = c.ue, c.world
    vein = w.vein(1, 15)
    w.startSwing(vein)
    c.ticks(8)
    w.handOut(vein)
    c.ticks(1)
    check(vein.total() == 14 and c.S.swings == 1 and c.S.putBack == 2, "a vein that lasts 3 times as long, the ability still active after the ore was handed out: 2 of the 3 are put back at that look")
    c.ticks(7)
    w.handOut(vein)
    c.ticks(1)
    check(vein.total() == 13 and c.S.swings == 2 and c.S.putBack == 4, "the next swing, begun without a look at rest: 2 of its 3 as well")
    w.release()
    c.ticks(1)
    check(vein.total() == 13 and c.S.swings == 2 and printedCount(ue, "swing at ") == 2, "at rest: nothing more is counted or put back")
    stop(c)
    Roll, Rolls = 0.5, 0
    c = start("at-once-note", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 7", "Config.ExtraChance = 100" }), widgets = true })
    w = c.world
    vein = w.vein(1, 40)
    w.startSwing(vein)
    c.ticks(8)
    check(w.handOut(vein) == 8 and Rolls == 1, "(a swing with the extra ore: 7 + 1)")
    c.ticks(1)
    local shown = #c.ui.calls
    check(c.ui.note() == "Mining: 8 ore (the game gives 3)" and Rolls == 2 and w.numbers.m_AmountAtHighOre == 8,
        "the note is shown at the look after the ore was handed out; for the swing that may follow at once the extra ore is rolled anew")
    c.ticks(7)
    check(w.handOut(vein) == 8 and Rolls == 2, "(the next swing, without a look at rest)")
    c.ticks(1)
    check(#c.ui.calls > shown and c.S.swings == 2 and c.S.extras == 2 and Rolls == 3, "it has its own note and its own extra ore")
    w.release()
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 7 and c.S.swings == 2 and Rolls == 3, "at rest: the plain amount is in the game's numbers again, nothing is rolled")
    stop(c)
    -- from one vein to the next without a look at rest
    c = start("next-vein", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 20", "Config.EndlessVeins = true", LOGGED, QUIET }) })
    ue, w = c.ue, c.world
    local first, second, third = w.vein(1, 15), w.vein(2, 15), w.vein(3, 10)
    w.startSwing(first)
    c.ticks(8)
    w.handOut(first)
    c.ticks(2)
    check(first.total() == 35 and c.S.swings == 1, "(a swing at one vein; the ability stays active, the vein is filled for the next swing)")
    w.startSwing(second)
    c.ticks(1)
    check(second.total() == 35 and c.S.swings == 1 and c.S.swing.name == second.actor:GetFullName(),
        "the ability is aimed at the vein next to it before the module saw it at rest: the swing at that vein begins, it is filled")
    check(w.endSwing(second) == 20 and second.total() == 15, "and gives the full 20")
    c.ticks(1)
    check(c.S.swings == 2 and printedCount(ue, "swing at BP_MiningSpot_C_2: 20 ore") == 1 and printedCount(ue, "swing at ") == 2, "it is counted; the first vein's is not counted twice")
    w.startSwing(second)
    c.ticks(4)
    w.startSwing(third)
    c.ticks(1)
    check(third.total() == 30 and c.S.swings == 3 and printedCount(ue, "swing at BP_MiningSpot_C_2: 0 ore") == 1,
        "a swing broken off for the next vein, again without a look at rest: counted as a swing without ore, and the next vein is filled")
    check(w.endSwing(third) == 20 and third.total() == 10, "which gives its 20")
    c.ticks(1)
    -- the ability stops naming its vein in the middle of a swing
    w.startSwing(first)
    c.ticks(2)
    w.target = nil
    c.ticks(4)
    check(c.S.swing ~= nil and c.S.swings == 4, "the ability names no vein any more while it is active: the swing goes on")
    check(w.handOut(first) == 20, "(it gives its ore)")
    c.ticks(1)
    check(c.S.swings == 5 and c.S.ore_given == 80 and c.S.swing == nil, "and is counted when the ore has been handed out; no next swing is begun without a vein")
    w.release()
    c.ticks(1)
    check(c.S.swings == 5 and first.total() == 15 and #ue.errors == 0, "at rest: nothing more")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("9. things that are missing or fail: the game's mining numbers")
do
    local QUIET = "Config.ShowMessage = false"
    local SEVEN = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 7", QUIET })
    local CONFIG_PATH, ORE_PATH = "/Script/Angelscript.Default__MiningConfig", "/Script/Angelscript.ItMi_Orenugget"
    local function data(o) return rawget(o, "__data") end

    -- the hero's world does not lead to them: by path
    local c = start("config-path", { config = SEVEN, diag = true, change = function(w) data(w.world).GameState = nil end })
    local ue, w = c.ue, c.world
    c.ticks(8)
    check(c.S.config == nil and #ue.lookups == 0 and w.byName.GameState == 2, "the way through the hero's world is tried three times, a second apart, before anything is searched")
    c.ticks(1)
    check(c.S.configVia == "path" and #ue.lookups == 1 and ue.lookups[1] == CONFIG_PATH and w.numbers.m_AmountAtHighOre == 7
        and c.fake.value("mining.config_found_by") == "path", "then the config object is searched by its path, once, and the amount is written")
    c.ticks(240)
    check(#ue.lookups == 1 and has(status(c), "(found through the path)"), "no further search; the status names the way")
    stop(c)
    c = start("config-cdo", { config = SEVEN, diag = true, change = function(w) data(w.gameState).GetWorldDefinition = nil end })
    c.ticks(1)
    check(c.S.configVia == "world definition" and c.world.numbers.m_AmountAtHighOre == 7 and #c.ue.lookups == 0,
        "a game state without the getter: the world definition is taken from its class property")
    stop(c)
    c = start("config-refused", { config = SEVEN, change = function(w) data(w.gameState).GetWorldDefinition = function() error("not for you (test)") end end })
    c.ticks(1)
    check(c.S.configVia == "world definition" and #c.ue.errors == 0, "a getter that raises: the same, no error")
    stop(c)

    -- nowhere
    c = start("config-none", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 7", "Config.EndlessVeins = true" }), diag = true,
        change = function(w, ue)
            data(w.world).GameState = nil
            ue.objects[CONFIG_PATH] = nil
        end })
    ue, w = c.ue, c.world
    c.ticks(240)
    local paths = 0
    for _, p in ipairs(ue.lookups) do if p == CONFIG_PATH then paths = paths + 1 end end
    check(paths == 1 and w.byName.GameState == 6, "not found at all: one search by path, and the way through the world again with growing pauses (6 times in a minute)")
    check(printedCount(ue, "[G1R_Mining] the game's mining numbers were not found; mining stays as the game has it\n") == 1
        and c.fake.value("mining.config_found_by") == "not found" and #ue.errors == 0, "said once in the log, noted, no error")
    local vein = w.vein(1, 15)
    check(c.swing(vein) == 3 and vein.total() == 12 and vein.addCalls == 0 and w.n.writes == 0,
        "mining stays as the game has it: nothing is written, no vein is filled (without the numbers the level cannot be worked out)")
    check(has(status(c), "|the game's mining numbers have not been found yet (no game loaded?)|"), "the status says the numbers were not found")
    check(c.S.swings == 1 and c.S.ore_given == 3 and c.S.extras == 0 and c.S.game_gives == 0, "the swing is counted with its ore; nothing else is known about it")
    stop(c)

    -- the pauses between two looks at something that is not usable
    c = start("config-pause", { config = SEVEN, change = function(w) w.config.__empty = true w.numbers.m_AmountAtHighOre = nil end })
    w = c.world
    local function looks() return w.byName.m_AmountAtHighOre end
    c.ticks(1)
    local first = looks()
    c.ticks(19)
    local before5 = looks()
    c.ticks(1)
    local at5 = looks()
    c.ticks(39)
    local before15 = looks()
    c.ticks(1)
    check(first == 1 and before5 == 1 and at5 == 2 and before15 == 2 and looks() == 3, "numbers that cannot be read are looked at again after exactly 5 and then 10 more seconds")
    c.ticks(479)
    local before235 = looks()
    c.ticks(1)
    check(before235 == 5 and looks() == 6, "then after 20, 40 and - the longest pause - 60 seconds (the sixth look comes 235 seconds after the first)")
    stop(c)

    -- found, but not readable / not plausible
    for _, case in ipairs({
        { "a config object without the amount (UE4SS gives an empty object for a name that is not there)", function(w) w.config.__empty = true w.numbers.m_AmountAtHighOre = nil end },
        { "a config object without the low amount", function(w) w.numbers.m_AmountAtLowOre = nil end },
        { "a config object without the threshold", function(w) w.config.__empty = true w.numbers.m_HighOre = nil end },
        { "an amount below 0", function(w) w.numbers.m_AmountAtHighOre = -1 end },
        { "an amount that is absurdly large", function(w) w.numbers.m_AmountAtLowOre = 100001 end },
        { "an amount that is not a number", function(w) w.numbers.m_AmountAtHighOre = 0 / 0 end },
    }) do
        c = start("config-odd", { config = SEVEN, diag = true, change = case[2] })
        ue, w = c.ue, c.world
        c.ticks(240)
        check(c.S.config == nil and w.n.writes == 0 and #ue.errors == 0 and c.fake.value("mining.game_numbers") == "not readable"
            and printedCount(ue, "the game's mining numbers could not be read from MiningConfig /Script/Angelscript.Default__MiningConfig; mining stays as the game has it") == 1,
            case[1] .. ": not taken, nothing is written, said once")
        check(w.byName.m_AmountAtHighOre == 4, case[1] .. ": looked at again with growing pauses (4 times in a minute: at once, after 5, 15, 35 seconds), not at every look")
        stop(c)
    end
    c = start("config-edge", { config = config({ "Config.EndlessVeins = true", QUIET }), diag = true, model = { numbers = { high = 100000, low = 0, threshold = 0 } } })
    c.ticks(1)
    check(c.S.game and c.S.game.high == 100000 and c.S.game.low == 0 and c.S.game.threshold == 0 and c.fake.value("mining.game_numbers") == "100000/0/0",
        "numbers of 0 and of 100000 are still taken as numbers")
    stop(c)
    c = start("config-other", { config = config({ "Config.EndlessVeins = true", QUIET }), diag = true, model = { numbers = { high = 4, low = 2, threshold = 8 } } })
    w = c.world
    vein = w.vein(1, 15)
    local got = { c.swing(vein), c.swing(w.vein(2, 5)) }
    check(table.concat(got, ",") == "4,4" and c.fake.value("mining.game_numbers") == "4/2/8" and vein.total() == 15 and w.veins[2].total() == 5,
        "a game with other numbers (4 per swing, 2 when 8 or fewer are left): they are what counts - veins are filled to their size + 4")
    stop(c)

    -- a write that does not work
    for _, case in ipairs({
        { "a write that raises", function(w) w.config.__readonly = true end },
        { "a write that goes nowhere", function(w) w.config.__deaf = true end },
    }) do
        c = start("config-write", { config = SEVEN, diag = true, change = case[2] })
        ue, w = c.ue, c.world
        c.ticks(80)
        check(w.numbers.m_AmountAtHighOre == 3 and w.numbers.m_AmountAtLowOre == 1 and w.n.writes == 1 and #ue.errors == 0,
            case[1] .. ": noticed by reading the number back; tried once, not at every look; no error")
        check(printedCount(ue, "[G1R_Mining] the game's mining numbers could not be written (the value did not stay); the ore per swing stays as the game has it\n") == 1
            and c.fake.value("mining.config_write") == "failed" and c.fake.detail("mining.config_write") == "7 / 1 wanted, 3 / 1 there",
            case[1] .. ": said once, noted with what was wanted and what is there")
        check(has(status(c), "|ore per swing: left as the game has it for this run (the game's mining numbers could not be written)|")
            and c.mods.store["G1R_Mining:original"] == "" and c.S.dirty == false and c.fake.value("mining.config_kept") == nil,
            case[1] .. ": the status says so; nothing is left to put back; nothing is noted about numbers being kept")
        T.menuSet(c, "Resources", "Ore per swing from the numbers", false)
        c.ticks(1)
        T.menuSet(c, "Resources", "Ore per swing from the numbers", true)
        c.ticks(1)
        check(w.n.writes == 2 and printedCount(ue, "could not be written") == 1, case[1] .. ": switched off and on again - tried once more, not said again")
        stop(c)
    end
    c = start("config-half", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 7", "Config.LowVeinRule = false", QUIET }), diag = true,
        change = function(w) w.config.__lock = { m_AmountAtLowOre = true } end })
    w = c.world
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 3 and w.numbers.m_AmountAtLowOre == 1 and w.n.writes == 3 and c.S.yieldOff ~= nil
        and c.fake.detail("mining.config_write") == "7 / 7 wanted, 7 / 1 there",
        "one of the two amounts cannot be written: the other is taken back, so that the game's own pair stays")
    stop(c)

    -- putting the game's numbers back does not work
    c = start("config-stuck", { config = SEVEN, diag = true })
    ue, w = c.ue, c.world
    c.ticks(1)
    w.config.__readonly = true
    T.menuSet(c, "Resources", "Ore per swing from the numbers", false)
    c.ticks(1)
    w.config.__readonly = nil
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 3 and c.S.dirty == false and c.S.backFails == 0 and w.n.writes == 3,
        "putting the game's number back fails once and works at the next look: done, and the count of failures starts again")
    T.menuSet(c, "Resources", "Ore per swing from the numbers", true)
    c.ticks(1)
    w.config.__readonly = true
    T.menuSet(c, "Resources", "Ore per swing from the numbers", false)
    c.ticks(2)
    check(c.S.dirty == true and printed(ue, "could not be put back") == nil, "it cannot be put back at all: tried again at the next looks")
    c.ticks(40)
    check(c.S.dirty == false and w.n.writes == 7 and w.numbers.m_AmountAtHighOre == 7
        and printedCount(ue, "[G1R_Mining] the game's own mining numbers could not be put back; they return when the game is started again\n") == 1
        and c.fake.value("mining.config_write") == "not put back", "three tries, then it is said once and left (the number returns with the next start of the game)")
    stop(c)

    -- the numbers are looked at again and again
    c = start("config-kept", { config = SEVEN, diag = true })
    w = c.world
    c.ticks(1)
    check(c.fake.value("mining.config_kept") == nil, "(the first write says nothing about keeping)")
    c.ticks(20)
    check(c.fake.value("mining.config_kept") == "yes" and w.n.writes == 1, "five seconds later the amount is still there: noted, nothing is written again")
    w.numbers.m_AmountAtHighOre = 3         -- the game has put its own number back
    c.ticks(20)
    check(w.numbers.m_AmountAtHighOre == 7 and w.n.writes == 2 and c.fake.value("mining.config_kept") == "no"
        and c.fake.detail("mining.config_kept") == "7 / 1 left there, 7 / 1 wanted now", "a number the game has put back is written again within seconds, and that is noted")
    -- the object itself is replaced
    local newer = thing(w, "MiningConfig /Script/Angelscript.Default__MiningConfig", { m_HighOre = 5, m_AmountAtHighOre = 3, m_AmountAtLowOre = 1 })
    newer.__full = "MiningConfig /Script/Angelscript.Default__MiningConfig_REINST_3"
    w.config.__valid = false
    data(data(w.definition).m_MiningDefinition).GetCDO = function() return newer end
    c.ticks(20)
    check(c.S.config == newer and data(newer).m_AmountAtHighOre == 7 and w.n.stale == 0, "a config object that is gone: the new one is found the same way and gets the amount")
    stop(c)

    -- numbers that cannot be read any more after they were found
    c = start("config-blind-high", { config = config({ "Config.EndlessVeins = true", QUIET }) })
    ue, w = c.ue, c.world
    c.ticks(1)
    w.config.__blind, w.config.__readonly = { m_AmountAtHighOre = true }, true
    local vein = w.vein(1, 15)
    check(c.swing(vein) == 3 and vein.total() == 12 and vein.addCalls == 0 and c.S.swings == 1 and c.S.ore_given == 3 and #ue.errors == 0,
        "the amount cannot be read any more: the vein is not filled (the level cannot be worked out), the swing is still counted")
    check(printed(ue, "could not be put back") == nil and c.S.dirty == false and c.S.backFails == 0, "nothing of the module's was in the config: nothing is said about putting back")
    stop(c)
    c = start("config-blind-low", { config = config({ "Config.VeinLastsTimes = 2", QUIET }) })
    ue, w = c.ue, c.world
    c.ticks(1)
    w.config.__blind, w.config.__readonly = { m_AmountAtLowOre = true }, true
    vein = w.vein(1, 3)
    check(c.swing(vein) == 1 and c.swing(vein) == 1 and vein.total() == 2 and vein.added == 1 and c.S.game_gives == 0 and #ue.errors == 0,
        "the low amount cannot be read any more: what a swing takes is still measured and put back; what the game would give is not worked out")
    stop(c)

    -- the hero's values
    c = start("hero-strength", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 0", "Config.StrengthPerOre = 4", "Config.DexterityPerOre = 6", QUIET }),
        diag = true, change = function(w)
            local sets = w.hero.component.SpawnedAttributes.items
            table.remove(sets, 4)       -- the hero has no Strength attributes (yet)
        end })
    ue, w = c.ue, c.world
    c.ticks(36)
    check(w.numbers.m_AmountAtHighOre == 3 and w.n.writes == 0 and c.S.waiting == "Strength" and c.S.waits == 9 and printed(ue, "cannot be read") == nil,
        "Strength cannot be read: the game's numbers are left alone; nine tries, a second apart, and nothing is said yet")
    check(has(status(c), "|ore per swing: waiting for the hero's Strength|"), "the status says what is waited for")
    c.ticks(1)
    check(printedCount(ue, "the hero's Strength cannot be read") == 1, "the tenth try says it")
    c.ticks(39)
    check(printedCount(ue, "[G1R_Mining] the hero's Strength cannot be read; the ore per swing stays as it is until it can\n") == 1
        and c.fake.value("mining.attributes") == "not readable" and c.fake.detail("mining.attributes") == "Strength" and #ue.errors == 0,
        "after ten tries (a second apart) it is said once and noted")
    ue.allOf.AttributeSet_Strength = { w.strength }
    c.ticks(280)
    check(w.numbers.m_AmountAtHighOre == 3 and c.S.amount == 3 and c.S.waiting == nil and c.fake.value("mining.attributes") == "readable",
        "Strength appears: the amount is worked out (2 + 1 = 3, which needs no write)")
    w.attribute("Dexterity", 0 / 0)
    for _ = 1, 24 do
        c.ticks(1)
        if c.S.waiting then break end
    end
    check(c.S.waiting == "Dexterity" and c.S.waits == 1 and w.numbers.m_AmountAtHighOre == 3, "a Dexterity that is not a number is not taken for one; the tries are counted from 1 again")
    stop(c)

    -- the hero's skill tags
    for _, case in ipairs({
        { "a tag function that raises", function() error("no such function (test)") end, "no such function (test)" },
        { "a tag function that answers with something else than yes or no", function() return "perhaps" end, "the answer was perhaps" },
    }) do
        local asked = 0
        c = start("tags", { config = config({ "Config.YieldEnabled = true", "Config.TrainedBonus = 2", "Config.MasterBonus = 4", QUIET }), diag = true,
            model = { rank = "master" }, change = function(w)
                w.hero.component.HasGameplayTag = function()
                    asked = asked + 1
                    return case[2]()
                end
            end })
        ue, w = c.ue, c.world
        c.ticks(40)
        check(c.S.tagsOff == false and printed(ue, "mining skill") == nil and w.numbers.m_AmountAtHighOre == 3, case[1] .. ": asked again at the next two looks at the hero")
        c.ticks(1)
        check(c.S.tagsOff == true and printedCount(ue, "[G1R_Mining] the hero's mining skill cannot be asked (" .. case[3] .. "); the bonus of a trained or master miner is not given\n") == 1
            and c.fake.value("mining.skill_tags") == "not readable" and c.fake.detail("mining.skill_tags") == case[3] and #ue.errors == 0,
            case[1] .. ": after the third time it is said once, with the reason, and not asked again")
        c.ticks(80)
        check(w.numbers.m_AmountAtHighOre == 3 and printedCount(ue, "mining skill") == 1 and asked == 3, case[1] .. ": the base amount is given without the bonus; three questions in all")
        stop(c)
    end
    c = start("tags-recover", { config = config({ "Config.YieldEnabled = true", "Config.TrainedBonus = 2", QUIET }), model = { rank = "trained" } })
    w = c.world
    local real = w.hero.component.HasGameplayTag
    local broken = function() error("not now (test)") end
    w.hero.component.HasGameplayTag = broken
    c.ticks(21)                                         -- two looks at the hero fail
    w.hero.component.HasGameplayTag = real
    c.ticks(20)
    check(w.numbers.m_AmountAtHighOre == 5 and c.S.tagFails == 0, "two failures and then an answer: the count of failures starts again")
    w.hero.component.HasGameplayTag = broken
    c.ticks(40)
    check(c.S.tagsOff == false and c.S.tagFails == 2, "two more failures do not make three in a row")
    w.rank = nil
    w.hero.component.HasGameplayTag = real
    c.ticks(20)
    check(c.S.tagFails == 0 and w.numbers.m_AmountAtHighOre == 3, "an answer of no starts the count again as well")
    stop(c)
    c = start("tags-noname", { config = config({ "Config.YieldEnabled = true", "Config.TrainedBonus = 2", QUIET }), model = { rank = "trained" }, mock = { without = { "FName" } } })
    c.ticks(44)
    check(c.S.tagsOff == true and printedCount(c.ue, "the hero's mining skill cannot be asked (HasGameplayTag needs a tag (test))") == 1 and #c.ue.errors == 0,
        "a UE4SS without FName: no tag can be made - said once, no bonus, no error")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("10. things that are missing or fail: veins")
do
    local QUIET = "Config.ShowMessage = false"
    local ENDLESS = config({ "Config.EndlessVeins = true", QUIET })
    local ORE_PATH, LIBRARY_PATH = "/Script/Angelscript.ItMi_Orenugget", "/Script/G1R.Default__DataModuleLibrary"
    local function data(o) return rawget(o, "__data") end

    -- the ore's class
    local c = start("ore-path", { config = ENDLESS, diag = true, change = function(w) data(w.definition).m_DefaultOre = nil end })
    local ue, w = c.ue, c.world
    local vein = w.vein(1, 15)
    c.ticks(4)
    check(#ue.lookups == 0, "the world definition does not name the ore's class: nothing is searched before a vein is swung at")
    check(c.swing(vein) == 3 and vein.total() == 15 and #ue.lookups == 1 and ue.lookups[1] == ORE_PATH and c.fake.value("mining.ore_class") == "path",
        "then it is searched by its path, once")
    c.swing(vein)
    check(#ue.lookups == 1 and vein.total() == 15, "not again")
    stop(c)
    c = start("ore-none", { config = ENDLESS, diag = true, change = function(w, ue)
        data(w.definition).m_DefaultOre = nil
        ue.objects[ORE_PATH] = nil
    end })
    ue, w = c.ue, c.world
    vein = w.vein(1, 15)
    check(c.swing(vein) == 3 and vein.total() == 15 and vein.countCalls == 0 and vein.addCalls == 0,
        "no class for the ore at all: the vein's slots are counted and its first slot is written - the game's functions are not called")
    check(c.fake.value("mining.ore_class") == "not found" and c.fake.value("mining.vein_count") == "slots" and c.fake.value("mining.vein_add") == "slot"
        and w.n.indexed == 0 and w.n.flood == 0, "noted; the slot lists are walked without an index and without the logged property names")
    check(c.fake.crumbCount("first ore put into a vein by writing the count of its first slot") == 1
        and c.fake.crumbCount("first ore put into a vein by its container's Multicast_AddNewItem") == 0
        and c.fake.crumbCount("first count of a vein's ore by its container's HasItemMain") == 0, "the write of the slot count is announced, the calls that were not made are not")
    local empty = w.vein(2, 10, 0)
    check(c.swing(empty) == 0 and empty.total() == 0 and c.S.addOff == false and c.swing(vein) == 3 and vein.total() == 15,
        "an empty vein has no slot to write: it stays empty, and that is no verdict on the way (the next vein is filled)")
    c.swing(vein)
    check(#ue.lookups == 1, "one search for the class in all")
    stop(c)

    -- the vein's container
    c = start("container-library", { config = ENDLESS, diag = true })
    ue, w = c.ue, c.world
    vein = w.vein(1, 15)
    data(vein.component).m_DataModules = array(w, {})
    check(c.swing(vein) == 3 and vein.total() == 15 and w.libraryAsked == 1 and #ue.lookups == 1 and ue.lookups[1] == LIBRARY_PATH
        and c.fake.value("mining.vein_module") == "library", "a vein whose own list has no container: the game's library function gives it (one search, once)")
    c.swing(vein)
    check(#ue.lookups == 1 and vein.total() == 15 and c.fake.crumbCount("first call of the data module library's GetContainerDataModule") == 1,
        "not searched again; the first call of the library is announced")
    stop(c)
    c = start("container-none", { config = ENDLESS, diag = true, change = function(_, ue) ue.objects[LIBRARY_PATH] = nil end })
    ue, w = c.ue, c.world
    vein = w.vein(1, 15)
    data(vein.actor).m_DataModuleComponent = nil
    check(c.swing(vein) == 3 and vein.total() == 12 and c.swing(vein) == 3 and #ue.errors == 0 and #ue.lookups == 1,
        "no container to be had: mining goes on as the game has it, the library is searched once")
    check(printedCount(ue, "[G1R_Mining] the ore of a vein cannot be counted (BP_MiningSpot_C_1): veins stay as the game has them, and nothing is said about a swing\n") == 1
        and c.fake.value("mining.vein_count") == "not readable" and c.S.swings == 2 and c.fake.value("mining.vein_module") == nil,
        "said once and noted; the swings are counted; no way to the container is noted")
    check(c.fake.crumbCount("first call of the data module library's GetContainerDataModule") == 0, "a library that is not there is not announced as called")
    stop(c)
    c = start("container-empty", { config = ENDLESS, diag = true })
    w = c.world
    vein = w.vein(1, 15)
    data(vein.actor).m_DataModuleComponent = nil
    data(w.library).GetContainerDataModule = function() return w.ue:invalid() end
    check(c.swing(vein) == 3 and vein.total() == 12 and c.fake.value("mining.vein_module") == nil and vein.countCalls == 0 and #c.ue.errors == 0,
        "a library that answers with an empty object (UE4SS's way of saying nothing): not taken for a container")
    stop(c)

    -- counting
    for _, case in ipairs({
        { "a counting function that gives no number back", function(v) v.noOut = true end },
        { "a counting function that raises", function(v) data(v.container).HasItemMain = function() v.countCalls = v.countCalls + 1 error("no (test)") end end },
    }) do
        c = start("count", { config = ENDLESS, diag = true })
        w = c.world
        vein = w.vein(1, 15)
        case[2](vein)
        check(c.swing(vein) == 3 and vein.total() == 15 and c.swing(vein) == 3 and vein.countCalls == 1 and c.S.countWay == "slots"
            and c.fake.value("mining.vein_count") == "slots" and #c.ue.errors == 0, case[1] .. ": the slots are added up instead, and the function is not called again")
        stop(c)
    end
    for _, case in ipairs({
        { "neither the function nor the slot list", function(w, v) v.noOut = true data(v.container).m_Inventory = nil end },
        { "no function and a slot whose count is not a number", function(w, v) v.noOut = true v.slots[2] = { count = "many" } end },
        { "no function and a slot with a count below 0", function(w, v) v.noOut = true v.slots[2] = { count = -3 } end },
    }) do
        c = start("count-none", { config = ENDLESS, diag = true })
        w = c.world
        vein = w.vein(1, 15)
        case[2](w, vein)
        c.swing(vein, 2, true)
        check(vein.addCalls == 0 and c.S.countWay == nil and printedCount(c.ue, "the ore of a vein cannot be counted") == 1 and #c.ue.errors == 0,
            case[1] .. ": the vein is not touched, said once")
        stop(c)
    end
    c = start("count-wrapped", { config = ENDLESS })
    w = c.world
    vein = w.vein(1, 15)
    data(vein.container).HasItemMain = function(_, _, _, out) out.hasItemCount = { get = function() return vein.total() end } return true end
    check(c.swing(vein) == 3 and vein.total() == 15 and c.S.countWay == "function", "a count that comes back wrapped (a value with get()) is taken")
    stop(c)

    -- putting ore into a vein
    local SAID_FUNCTION = "[G1R_Mining] putting ore into a vein by its container function did not work (%s); that way is not used again in this run\n"
    for _, case in ipairs({
        { "an adding function that raises", function(v) data(v.container).Multicast_AddNewItem = function() v.addCalls = v.addCalls + 1 error("no (test)") end end, "the call failed" },
        { "an adding function that adds nothing", function(v) v.addDeaf = true end, "the count stayed" },
    }) do
        c = start("add-function", { config = ENDLESS, diag = true })
        ue, w = c.ue, c.world
        vein = w.vein(1, 15)
        case[2](vein)
        check(c.swing(vein) == 3 and vein.total() == 15 and vein.addCalls == 1 and c.fake.value("mining.vein_add") == "slot",
            case[1] .. ": noticed by counting again; the count of the first slot is written instead, in the same swing")
        check(printedCount(ue, SAID_FUNCTION:format(case[3])) == 1, case[1] .. ": said once, with what happened")
        c.swing(vein)
        c.swing(vein)
        check(vein.addCalls == 1 and vein.total() == 15 and printedCount(ue, "putting ore into a vein") == 1 and #ue.errors == 0, case[1] .. ": the function is not called again")
        local dump = c.fake.dump[1]()
        check(dump.add_off == false and dump.add_failed_function == true and dump.add_failed_slot == false and not has(status(c), "ore cannot be put"),
            case[1] .. ": the dump names the way that failed; veins are still filled, and the status does not say otherwise")
        stop(c)
    end
    c = start("add-none", { config = ENDLESS, diag = true })
    ue, w = c.ue, c.world
    vein = w.vein(1, 15)
    vein.addDeaf, vein.deaf = true, true
    check(c.swing(vein) == 3 and vein.total() == 12 and c.S.addOff == true, "neither way puts ore into the vein: it is mined as the game has it")
    check(printedCount(ue, SAID_FUNCTION:format("the count stayed")) == 1
        and printedCount(ue, "[G1R_Mining] putting ore into a vein by its slot count did not work (the count stayed); that way is not used again in this run\n") == 1
        and printedCount(ue, "[G1R_Mining] ore cannot be put into veins: they stay as the game has them\n") == 1 and c.fake.value("mining.vein_add") == "failed",
        "each way is said once, and that veins stay as they are; noted")
    local writes = w.n.writes
    check(c.swing(vein) == 3 and c.swing(vein) == 3 and vein.addCalls == 1 and w.n.writes == writes and #ue.errors == 0, "nothing is tried again at the next swings")
    local lines = c.hook.status()
    check(#lines == 4 and has(lines[2], "the game's own numbers") and has(lines[3], "swings seen: 3, ore: 9")
        and lines[4] == "ore cannot be put into veins in this run: they stay as the game has them", "the status says so, in a line of its own")
    local dump = c.fake.dump[1]()
    check(dump.add_off == true and dump.add_failed_function == true and dump.add_failed_slot == true, "the dump names both ways as failed")
    stop(c)
    c = start("add-slot-raises", { config = ENDLESS })
    w = c.world
    vein = w.vein(1, 15)
    vein.addDeaf, vein.readonly = true, true
    c.swing(vein)
    check(printedCount(c.ue, "[G1R_Mining] putting ore into a vein by its slot count did not work (the call failed); that way is not used again in this run\n") == 1
        and c.S.addOff == true and #c.ue.errors == 0, "a slot count that cannot be written: said as a failed call, no error")
    stop(c)
    c = start("add-partial", { config = ENDLESS, diag = true })
    w = c.world
    vein = w.vein(1, 15)
    data(vein.container).Multicast_AddNewItem = function(_, _, _, amount) vein.slots[1].count = vein.slots[1].count + amount - 1 end
    check(c.swing(vein) == 3 and vein.total() == 14 and c.fake.detail("mining.vein_add") == "2 of 3 arrived" and c.S.addOff == false and c.S.putBack == 2,
        "an adding function that adds less than asked: what arrived counts (noted), the way is kept")
    stop(c)
    -- the hidden setting that names the way
    c = start("method-slot", { config = config({ "Config.EndlessVeins = true", 'Config.VeinMethod = "slot"', QUIET }), diag = true })
    w = c.world
    vein = w.vein(1, 15)
    check(c.swing(vein) == 3 and vein.total() == 15 and vein.addCalls == 0 and c.fake.value("mining.vein_add") == "slot", "VeinMethod = \"slot\": only the slot count is written")
    stop(c)
    c = start("method-function", { config = config({ "Config.EndlessVeins = true", 'Config.VeinMethod = "function"', QUIET }) })
    ue, w = c.ue, c.world
    vein = w.vein(1, 15)
    vein.addDeaf = true
    check(c.swing(vein) == 3 and vein.total() == 12 and w.n.writes == 0 and c.S.addOff == true, "VeinMethod = \"function\" and the function adds nothing: the slot count is not written")
    vein.addDeaf = false
    T.write(c.path, config({ "Config.EndlessVeins = true", 'Config.VeinMethod = "auto"', QUIET }))
    ue:fireConsole("mining reload")
    check(c.S.addOff == false and c.swing(vein) == 3 and vein.total() == 14, "the setting changed: the ways are tried anew (the vein, mined down meanwhile, is filled again)")
    stop(c)

    -- the vein's size
    c = start("size-first", { config = ENDLESS, diag = true })
    w = c.world
    vein = w.vein(1, 15, 9)
    data(vein.container).m_DefaultInventory = nil
    check(c.swing(vein) == 3 and vein.total() == 9 and c.fake.value("mining.vein_size_from") == "first look",
        "a vein whose default contents cannot be read: it is kept at what it held when it was first seen (9)")
    c.swing(vein, 2, true)
    check(c.swing(vein) == 3 and vein.total() == 9, "also after a swing that was broken off")
    stop(c)
    c = start("size-zero", { config = ENDLESS, diag = true })
    w = c.world
    vein = w.vein(1, 0, 7)        -- default contents of 0 (an ore-less object by the game's data)
    check(c.swing(vein) == 3 and vein.total() == 7 and c.fake.value("mining.vein_size_from") == "first look", "default contents of 0 are not taken for a size")
    stop(c)

    -- the vein at the end of the swing
    c = start("vein-gone", { config = config({ "Config.VeinLastsTimes = 3", QUIET }) })
    ue, w = c.ue, c.world
    vein = w.vein(1, 15)
    w.startSwing(vein)
    c.ticks(2)
    w.endSwing(vein)
    vein.container.__valid, vein.actor.__valid = false, false
    c.ticks(1)
    check(c.S.swings == 1 and c.S.ore_given == 0 and vein.addCalls == 0 and w.n.stale == 0 and #ue.errors == 0,
        "the vein is gone when the swing is over (its part of the world was unloaded): nothing is counted, nothing is put back, the dead object is not touched")
    local second = w.vein(2, 15)
    w.startSwing(second)
    c.ticks(2)
    w.endSwing(second)
    second.container.__full = "DataModule_Container /Game/Maps/World.World:PersistentLevel.Chest_4.DataModules.DataModule_Container_0"
    c.ticks(1)
    check(second.addCalls == 0 and c.S.ore_given == 0, "a container wrapper that names another object by then (FACTS U5): no ore is put into it")
    stop(c)
    c = start("vein-grew", { config = config({ "Config.VeinLastsTimes = 3", QUIET }), diag = true })
    ue, w = c.ue, c.world
    vein = w.vein(1, 15)
    w.startSwing(vein)
    c.ticks(2)
    w.endSwing(vein)
    vein.slots[1].count = 25            -- somebody else has filled the vein
    c.ticks(1)
    check(vein.addCalls == 0 and c.S.ore_given == 0 and c.fake.value("mining.swing_gave") == "the vein grew" and c.fake.detail("mining.swing_gave") == "15 -> 25"
        and printedCount(ue, "[G1R_Mining] a vein held more ore after a swing than before it: something else fills veins (another mining mod?)\n") == 1,
        "a vein that holds more after the swing than before: somebody else fills veins - nothing is put back, said once, noted")
    stop(c)

    -- the game does not go by the numbers
    c = start("game-deaf", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 7" }), diag = true, widgets = true })
    w = c.world
    w.deafGame = true
    check(c.swing(w.vein(1, 15)) == 3 and c.fake.value("mining.swing_gave") == "differs" and c.fake.detail("mining.swing_gave") == "7 expected, 3 given"
        and c.ui.note() == nil, "a game that gives its 3 whatever the numbers say: noted as a difference (the swing gave what the game gives: no note on screen)")
    stop(c)

    -- UE4SS without things
    c = start("no-modref", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 7", "Config.EndlessVeins = true", QUIET }), noModRef = true })
    w = c.world
    check(c.swing(w.vein(1, 15)) == 7 and w.veins[1].total() == 15 and #c.ue.errors == 0, "a UE4SS without shared variables: the module works")
    stop(c)
    c = start("no-loop", { config = ENDLESS, mock = { without = { "LoopInGameThreadWithDelay" } } })
    check(c.ok and printed(c.ue, "[G1R_Mining] FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; the mining rework is disabled.\n") ~= nil and #c.ue.errors == 0,
        "a UE4SS without the game-thread loop: said, nothing else happens")
    stop(c)
    c = start("no-console", { config = ENDLESS, mock = { without = { "RegisterConsoleCommandHandler" } } })
    check(c.ok and printed(c.ue, "loaded: veins never run out") ~= nil and c.swing(c.world.vein(1, 15)) == 3 and #c.ue.errors == 0, "a UE4SS without console commands: the module works")
    stop(c)
    c = start("no-schema", { files = { ["Scripts/schema.lua"] = false } })
    check(c.ok and printed(c.ue, "[G1R_Mining] the settings could not be set up (schema.lua could not be read") ~= nil and #c.ue.loops == 1,
        "without schema.lua the module says so and does not start")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("11. map loads, and numbers an earlier run of the Lua mods left behind")
do
    local QUIET = "Config.ShowMessage = false"
    local c = start("load-map", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 0", "Config.StrengthPerOre = 2", "Config.VeinLastsTimes = 2", QUIET }) })
    local ue, w = c.ue, c.world
    local vein = w.vein(1, 15)
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 5, "Strength 10, one ore per 2: 5 per swing")
    check(c.swing(vein) == 5 and vein.total() == 12 and c.S.veins[vein.actor:GetFullName()].owed == 0.5, "a swing of 5: 2 put back, half an ore still owed to this vein")
    w.startSwing(vein)
    c.ticks(2)
    check(c.S.swing ~= nil, "a swing is in progress")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    check(c.S.swing == nil and c.S.ability == nil and next(c.S.veins) == nil and c.S.config == w.config,
        "a map load begins: the swing, the ability and the veins of the old world are dropped; the config object is kept (it outlives a world)")
    local reads, checks = w.n.reads, w.n.checks
    c.ticks(20)
    check(w.n.reads == reads and w.n.checks == checks and #ue.errors == 0, "between the two map load hooks the module does nothing and reads nothing")
    -- the new world: other objects
    w.endSwing(vein, true)
    w.ability.__valid, w.hero.state.__valid, w.controller.__valid, vein.actor.__valid, vein.container.__valid = false, false, false, false, false
    local fresh = w.another(90, 20.0)
    ue.allOf["GothicPlayerControllerBaseBP_C"] = { fresh.controller }
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(2)
    check(c.S.ability and c.S.ability.object == fresh.ability and w.numbers.m_AmountAtHighOre == 10 and c.S.config == w.config and w.n.stale == 0,
        "after the load the hero of the new world and his ability are found; his Strength 20 gives 10 per swing; no dead object was touched")
    check(T.searches(c) == 0, "nothing was searched by path for that (the kit's own paths, at the first map load, apart)")
    stop(c)

    c = start("load-ability", { config = config({ "Config.EndlessVeins = true", QUIET }) })
    ue, w = c.ue, c.world
    c.ticks(1)
    check(c.S.abilityTries == 1 and c.S.ability ~= nil, "(the ability was found at the first try)")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    w.ability.__valid, w.hero.state.__valid, w.controller.__valid = false, false, false
    fresh = w.another(95)
    fresh.component.ActivatableAbilities = nil              -- the new hero's list does not show his ability
    ue.allOf["GothicPlayerControllerBaseBP_C"] = { fresh.controller }
    countScans(c, { fresh.ability })
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.ticks(5)
    check(c.S.abilityTries == 2 and c.scans() == 0 and c.S.ability == nil, "after a map load the search for the ability starts afresh: two tries with the list, a second apart")
    c.ticks(4)
    check(c.scans() == 1 and c.S.ability and c.S.ability.object == fresh.ability, "the third goes on to the search among all objects")
    stop(c)

    c = start("load-endless", { config = config({ "Config.EndlessVeins = true", QUIET }) })
    ue, w = c.ue, c.world
    c.ticks(1)
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    c.ticks(4 * 19)
    vein = w.vein(1, 15)
    w.startSwing(vein)
    c.ticks(3)
    check(vein.total() == 15, "a map load whose end is never reported: still waited for after 19 seconds")
    c.ticks(2)
    check(vein.total() == 18, "but not for longer than 20 seconds")
    stop(c)

    -- an earlier run of the Lua mods (UE4SS can load them anew while the game runs) left its numbers in the config
    c = start("left", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 7", QUIET }), diag = true, shared = { ["G1R_Mining:original"] = "3/1" },
        model = { numbers = { high = 9, low = 9 } } })
    ue, w = c.ue, c.world
    check(c.S.dirty == true, "the shared store holds the game's own two amounts from an earlier run: its numbers are still in the config")
    c.ticks(1)
    check(c.S.game.high == 3 and c.S.game.low == 1 and c.fake.value("mining.game_numbers") == "3/1/5",
        "the game's own numbers are taken from the store (3 and 1), not from the config (9 and 9)")
    check(w.numbers.m_AmountAtHighOre == 7 and w.numbers.m_AmountAtLowOre == 1, "the amount of this run is written, and the low amount the earlier run had changed is put back")
    T.menuSet(c, "Resources", "Ore per swing from the numbers", false)
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 3 and w.numbers.m_AmountAtLowOre == 1 and c.mods.store["G1R_Mining:original"] == "", "switched off: the game's own numbers are back")
    stop(c)

    c = start("left-idle", { shared = { ["G1R_Mining:original"] = "3/1" }, model = { numbers = { high = 9, low = 9 } } })
    ue, w = c.ue, c.world
    check(printed(ue, "loaded: nothing to change") ~= nil and c.S.dirty == true, "the same with the shipped settings (nothing to change)")
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 3 and w.numbers.m_AmountAtLowOre == 1 and c.mods.store["G1R_Mining:original"] == "" and c.S.dirty == false,
        "the one thing the module does while there is nothing to change: the game's own numbers are put back")
    local reads, writes, checks, finds = w.n.reads, w.n.writes, w.n.checks, allOf(ue)
    c.ticks(240)
    check(w.n.reads == reads and w.n.writes == 2 and writes == 2 and w.n.checks == checks and allOf(ue) == finds and #ue.lookups == 0 and #ue.errors == 0,
        "then the game is not looked at any more (two writes in all, no search by path)")
    stop(c)

    c = start("left-menu", { shared = { ["G1R_Mining:original"] = "3/1" }, model = { numbers = { high = 9, low = 9 } },
        change = function(_, ue) ue.allOf["GothicPlayerControllerBaseBP_C"] = nil end })
    ue, w = c.ue, c.world
    c.ticks(8)
    check(w.numbers.m_AmountAtHighOre == 9 and #ue.lookups == 0, "the same without a hero (the main menu): the way through the world is tried first")
    c.ticks(1)
    check(w.numbers.m_AmountAtHighOre == 3 and w.numbers.m_AmountAtLowOre == 1 and #ue.lookups == 1 and c.S.dirty == false,
        "then the config is found by its path and the numbers are put back")
    finds = allOf(ue)
    c.ticks(240)
    check(allOf(ue) == finds and #ue.lookups == 1, "after that nothing is searched any more")
    stop(c)

    for _, text in ipairs({ "junk", "3/x", "/1", "3/1/5", "" }) do
        c = start("left-odd", { shared = { ["G1R_Mining:original"] = text } })
        c.ticks(4)
        check(c.S.dirty == false and c.world.n.reads == 0, "a value in the store that is not two numbers (\"" .. text .. "\") is nobody's numbers")
        stop(c)
    end
    c = start("left-number", { shared = { ["G1R_Mining:original"] = 31 } })
    c.ticks(4)
    check(c.S.dirty == false and #c.ue.errors == 0, "nor is a value that is not a text")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("12. cost: what is asked of the game")
do
    local QUIET = "Config.ShowMessage = false"
    -- the kit's own questions to the hero's controller and player state (IsValid, GetFullName) are counted as well
    local function watchHero(c)
        local w = c.world
        w.hero_checks = 0
        for _, o in ipairs({ w.controller, w.hero.state }) do
            local valid, name = o.IsValid, o.GetFullName
            rawset(o, "IsValid", function(self) w.hero_checks = w.hero_checks + 1 return valid(self) end)
            rawset(o, "GetFullName", function(self) w.hero_checks = w.hero_checks + 1 return name(self) end)
        end
    end
    local function snapshot(c)
        local w, ue = c.world, c.ue
        return { reads = w.n.reads, writes = w.n.writes, checks = w.n.checks, finds = allOf(ue), lookups = #ue.lookups, system = w.reads[21] or 0,
            hero = w.hero_checks, tags = w.tagAsked }
    end
    local function since(c, before)
        local now, out = snapshot(c), {}
        for k, v in pairs(now) do out[k] = v - before[k] end
        return out
    end
    local function text(m)
        return ("%d property reads, %d validity / name checks, %d questions to the hero's objects (%d / %d / %d), %d writes, %d searches"):format(m.reads, m.checks,
            m.hero + m.system + m.tags, m.hero, m.system, m.tags, m.writes, m.finds + m.lookups)
    end
    -- the ore per swing only, nothing to say about swings
    local c = start("cost-yield", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 0", "Config.StrengthPerOre = 4", "Config.DexterityPerOre = 6",
        "Config.TrainedBonus = 1", QUIET }) })
    watchHero(c)
    c.ticks(40)
    local before = snapshot(c)
    c.ticks(240)
    local m = since(c, before)
    check(m.finds == 0 and m.lookups == 0 and m.writes == 0, "the ore per swing alone, a minute in which nothing changes: no search, no write")
    check(m.reads == 12 * 4 and m.checks == 12 * 22 and m.tags == 12 * 2, "the game is looked at every 5 seconds: 2 numbers of the config, Strength, Dexterity, 2 skill tags - " .. text(m))
    check(m.reads + m.checks + m.hero + m.system + m.tags < 900, "fewer than 900 questions a minute in all")
    stop(c)
    -- swings are watched, nobody swings
    c = start("cost-watch", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 5", "Config.EndlessVeins = true" }) })
    watchHero(c)
    c.ticks(40)
    before = snapshot(c)
    c.ticks(240)
    m = since(c, before)
    check(m.finds == 0 and m.lookups == 0 and m.writes == 0, "swings are watched, a minute without one: no search, no write")
    check(m.reads == 240 + 12 * 2 and m.checks == 240 * 4 + 12 * 5, "four looks a second at the ability (still there, still the same, active?), and every 5 seconds the config's 2 numbers - " .. text(m))
    check(m.hero >= 60 * 6 and m.hero <= 60 * 8 and m.system == 0 and m.tags == 0,
        "the hero himself is asked for once a second (about 7 questions of the kit to his controller and player state each time), his ability system not at all")
    check(m.reads + m.checks + m.hero + m.system + m.tags < 1800, "fewer than 1800 questions a minute in all")
    stop(c)
    -- a minute of swinging at an endless vein
    c = start("cost-mine", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 5", "Config.EndlessVeins = true", "Config.LogSwings = true" }) })
    watchHero(c)
    local w = c.world
    local vein = w.vein(1, 15)
    c.swing(vein)
    before = snapshot(c)
    for _ = 1, 26 do c.swing(vein) end          -- 26 swings of 2.25 seconds: about a minute
    m = since(c, before)
    check(w.heroOre == 27 * 5 and vein.addCalls == 27 and vein.countCalls == 27 * 10,
        "27 swings: 5 ore each; per swing the vein is filled once and counted ten times (when it begins, after the filling, at each of the 8 later looks)")
    check(m.writes == 0 and m.finds == 0 and m.lookups == 0 and m.reads == 26 * 51,
        "a minute of swinging: no write to the game's numbers, no search, 51 property reads and function calls a swing - " .. text(m))
    check(m.reads + m.checks + m.hero + m.system + m.tags < 6000, "fewer than 6000 questions a minute in all (about 22 at each look)")
    check(w.n.flood == 0 and w.n.indexed == 0 and w.n.stale == 0 and (c.ue.calls.RegisterHook or 0) == 0 and (c.ue.calls.NotifyOnNewObject or 0) == 0,
        "never: a logged property name read, an array indexed, a dead object touched, a hook or a notification registered")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("13. the settings: the in-game menu, the shipped file, values out of range")
do
    local c = start("menu", {})
    local ue = c.ue
    local index = T.menuIndex(c)
    check(#index == 1 and index[1] == "G1R Resources", "the module's page is registered with the in-game mod menu as G1R Resources")
    local page = T.menuPage(c, "Resources")
    local titles = {}
    for _, sec in ipairs(page.sections) do titles[#titles + 1] = sec.title .. ":" .. #sec.items end
    check(table.concat(titles, "|") == "Mining:1|Mining: ore per swing:10|How long a vein lasts:2|Mining: screen and log:2",
        "its sections and their items: " .. table.concat(titles, "|"))
    for _, i in ipairs(page.items) do
        if has(i.name, "VeinMethod") or has(i.name, "RefreshSeconds") or has(i.name, "CheckMilliseconds") then check(false, "a hidden setting is in the menu: " .. i.name) end
    end
    local item = T.menuItem(c, "Resources", "+1 ore per Strength points")
    check(item.kind == "num" and item.min == 0 and item.max == 200 and item.step == 1 and item.value == 0 and item.name == "+1 ore per Strength points" and item.desc == "one more ore for every so many; 0 = none",
        "points of Strength per ore: a number from 0 to 200 with its value, its short name and hint")
    item = T.menuItem(c, "Resources", "A vein lasts")
    check(item.kind == "num" and item.min == 1 and item.max == 50 and item.value == 1 and item.desc == "this many times the ore before empty; 1 = the game's",
        "how long a vein lasts: 1 to 50, with its hint (" .. tostring(item.desc) .. ")")
    local cut = {}
    for _, i in ipairs(page.items) do
        if i.desc:sub(-3) == "..." then cut[#cut + 1] = i.name end
    end
    check(#cut == 0, "no hint of the menu is cut off (" .. table.concat(cut, "; ") .. ")")
    check(T.menuItem(c, "Resources", "Veins never run out").kind == "bool" and T.menuItem(c, "Resources", "Mining rework").value == true, "switches are switches")
    -- every setting through the menu
    local v = c.hook.settings.values
    T.menuSet(c, "Resources", "Ore per swing from the numbers", true)
    T.menuSet(c, "Resources", "Base amount", 2)
    T.menuSet(c, "Resources", "+1 ore per Strength points", 2.5)
    T.menuSet(c, "Resources", "+1 ore per Dexterity points", 5)
    T.menuSet(c, "Resources", "A trained miner gets", 1)
    T.menuSet(c, "Resources", "A master miner gets", 3)
    T.menuSet(c, "Resources", "Chance of one more ore", 25)
    T.menuSet(c, "Resources", "A swing gives at least", 2)
    T.menuSet(c, "Resources", "A swing gives at most", 40)
    T.menuSet(c, "Resources", "Nearly empty vein gives less", false)
    T.menuSet(c, "Resources", "Veins never run out", true)
    T.menuSet(c, "Resources", "A vein lasts", 3)
    T.menuSet(c, "Resources", "Note when a swing gave more/less", false)
    T.menuSet(c, "Resources", "Log every swing", true)
    c.ticks(1)
    check(v.YieldEnabled == true and v.BaseAmount == 2 and v.StrengthPerOre == 2.5 and v.DexterityPerOre == 5 and v.TrainedBonus == 1 and v.MasterBonus == 3
        and v.ExtraChance == 25 and v.MinAmount == 2 and v.MaxAmount == 40 and v.LowVeinRule == false and v.EndlessVeins == true and v.VeinLastsTimes == 3
        and v.ShowMessage == false and v.LogSwings == true, "every setting can be changed in the menu")
    check(printed(ue, "[G1R_Mining] settings changed (in-game menu): ore per swing: base 2, +1 per 2.5 Strength, +1 per 5 Dexterity, +1 for a trained miner, "
        .. "+3 for a master miner, 25% chance of one more, 2 to 40, the same from a nearly empty vein; veins never run out\n") ~= nil,
        "the log names the whole rule: " .. tostring(ue.printed[#ue.printed]):gsub("\n", ""))
    local text = T.read(c.path)
    check(has(text, "Config.StrengthPerOre = 2.5\n") and has(text, "Config.EndlessVeins = true\n") and has(text, "Config.VeinLastsTimes = 3\n")
        and has(text, "-- ---- Mining: ore per swing ----\n"), "and config.lua holds the values, with its comments still there")
    check(c.world.numbers.m_AmountAtHighOre == 2 + 4 + 2 and c.world.numbers.m_AmountAtLowOre == 8, "Strength 10 / 2.5 and Dexterity 10 / 5 on top of 2: 8 per swing, at the next look")
    T.menuSet(c, "Resources", "Veins never run out", false)
    c.ticks(1)
    check(printed(ue, "the same from a nearly empty vein; a vein lasts 3 times as long\n") ~= nil, "without endless veins the log names how long a vein lasts")
    stop(c)

    -- values that are not usable
    c = start("range", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 500", "Config.StrengthPerOre = -3", "Config.DexterityPerOre = \"fast\"",
        "Config.ExtraChance = 250", "Config.MinAmount = -1", "Config.MaxAmount = 0", "Config.VeinLastsTimes = 0", "Config.VeinMethod = \"magic\"",
        "Config.RefreshSeconds = 0", "Config.CheckMilliseconds = 1" }) })
    v = c.hook.settings.values
    check(v.BaseAmount == 100 and v.StrengthPerOre == 0 and v.DexterityPerOre == 0 and v.ExtraChance == 100 and v.MinAmount == 0 and v.MaxAmount == 1
        and v.VeinLastsTimes == 1 and v.VeinMethod == "auto" and v.RefreshSeconds == 1 and v.CheckMilliseconds == 50 and #c.ue.errors == 0,
        "values out of range or of the wrong kind: the nearest end of the range, or the default")
    check(c.ue.loops[2].ms == 50 and math.type(c.ue.loops[2].ms) == "integer", "the loop's interval is handed to UE4SS as a whole number, not below 50 ms")
    stop(c)
    c = start("idle-kinds", { config = config({ "Config.BaseAmount = 9", "Config.StrengthPerOre = 4", "Config.ExtraChance = 50", "Config.LogSwings = true", "Config.VeinLastsTimes = 1" }) })
    c.ticks(8)
    check(c.world.n.reads == 0 and printed(c.ue, "loaded: nothing to change") ~= nil,
        "numbers for the ore per swing without its switch, and the log switch alone, change nothing: the game is not looked at")
    stop(c)
    c = start("off", { config = config({ "Config.Enabled = false", "Config.YieldEnabled = true", "Config.BaseAmount = 9", "Config.EndlessVeins = true", "Config.VeinLastsTimes = 5" }) })
    c.ticks(8)
    local vein = c.world.vein(1, 15)
    check(c.world.n.reads == 0 and printed(c.ue, "loaded: switched off in the settings") ~= nil and c.swing(vein) == 3 and vein.total() == 12 and allOf(c.ue) == 0,
        "Enabled = false with everything else set: nothing is looked at, nothing is changed")
    stop(c)
    for _, case in ipairs({
        { { "Config.VeinLastsTimes = 2" }, "a vein lasts 2 times as long" },
        { { "Config.EndlessVeins = true" }, "veins never run out" },
        { { "Config.YieldEnabled = true" }, "ore per swing: base 3, 1 to 100" },
    }) do
        c = start("alone", { config = config(case[1]) })
        c.ticks(1)
        check(printed(c.ue, "loaded: " .. case[2] .. "\n") ~= nil and c.world.n.reads > 0, "one feature alone is enough for the module to look at the game: " .. case[2])
        stop(c)
    end
    c = start("badstart", { config = "this is not lua\n" })
    check(c.ok and printed(c.ue, "config.lua has an error (") ~= nil and c.hook.settings.values.YieldEnabled == false, "a broken file at the start: said, default settings")
    stop(c)
    c = start("nofile", { config = false })
    check(c.ok and printed(c.ue, "config.lua was not there: written with the default settings") ~= nil and T.read(c.path) == shipped, "no file at the start: the default file is written")
    stop(c)

    -- the shipped files
    local schema = dofile(MOD .. "modules/mining/Scripts/schema.lua")
    local chunk = load(shipped, "=config.lua", "t", {})
    local values = chunk and chunk() or {}
    local keys = {}
    for k in pairs(values) do keys[#keys + 1] = k end
    table.sort(keys)
    check(table.concat(keys, ",") == "BaseAmount,DexterityPerOre,Enabled,EndlessVeins,ExtraChance,LogSwings,LowVeinRule,MasterBonus,MaxAmount,MinAmount,ShowMessage,"
        .. "StrengthPerOre,TrainedBonus,VeinLastsTimes,YieldEnabled" and not shipped:find("\r", 1, true) and not shipped:find("[^\n\32-\126]"),
        "the shipped config.lua: fifteen settings, plain ASCII, LF line ends")
    local widest = 0
    for line in shipped:gmatch("[^\n]+") do widest = math.max(widest, #line) end
    check(widest <= 110, "no line of it is wider than 110 characters (" .. widest .. ")")
    local probe = start("default-text", {})
    check(probe.settings.defaultText(schema) == shipped, "the shipped config.lua is exactly what the schema generates (lua5.4 dev/tools/gen_config.lua mining)")
    stop(probe)
    check(schema.Page == "Resources" and schema.PageOrder == 20 and schema.Groups[1].Items[1].Key == "Enabled", "the page is Resources (order 20); the first item is the module's switch")
    local orders = {}
    for _, g in ipairs(schema.Groups) do orders[#orders + 1] = g.Order end
    check(table.concat(orders, ",") == "10,12,16,20,24", "the groups have the orders 10 to 29 that the page gives to this module (" .. table.concat(orders, ",") .. ")")
end

-- ---------------------------------------------------------------------------
section("14. console command and status")
do
    local c = start("console", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 0", "Config.StrengthPerOre = 4", "Config.TrainedBonus = 2",
        "Config.EndlessVeins = true", "Config.ShowMessage = false" }), model = { strength = 30, rank = "trained" } })
    local ue, w = c.ue, c.world
    local before = #ue.printed
    check(ue:fireConsole("mining") == true and #ue.errors == 0, "mining: handled (a boolean is returned)")
    check(ue.printed[before + 1] == "[G1R_Mining] v1.0.0 | ore per swing: base 0, +1 per 4 Strength, +2 for a trained miner, 1 to 100; veins never run out\n"
        and ue.printed[before + 2] == "[G1R_Mining] the game's mining numbers have not been found yet (no game loaded?)\n"
        and ue.printed[before + 3] == "[G1R_Mining] swings seen: 0, ore: 0 (by the game's own numbers: 0), put into veins: 0\n" and #ue.printed == before + 3,
        "before a game is loaded: the rule, no numbers yet, no swings")
    check(#ue.device.lines == 3 and ue.device.lines[1] == "[G1R_Mining] v1.0.0 | ore per swing: base 0, +1 per 4 Strength, +2 for a trained miner, 1 to 100; veins never run out",
        "the same lines go to the console window")
    local vein = w.vein(1, 10)
    c.swing(vein)
    c.swing(vein)
    local lines = c.hook.status()
    check(#lines == 4 and lines[2] == "the game's own numbers: 3 ore per swing, 1 when 5 or fewer are left in the vein (found through the world definition)"
        and lines[3] == "ore per swing now: 9, Strength 30, a trained miner"
        and lines[4] == "swings seen: 2, ore: 18 (by the game's own numbers: 6), put into veins: 18; last: 9 ore from BP_MiningSpot_C_1",
        "after two swings: " .. tostring(lines[3]) .. " | " .. tostring(lines[4]))
    check(ue:fireConsole("g1r_mining status") == true and ue:fireConsole("mining something") == true, "g1r_mining works too; an unknown word shows the status")
    before = #ue.printed
    ue:fireConsole("mining reload")
    check(ue.printed[before + 1] == "[G1R_Mining] settings read: ore per swing: base 0, +1 per 4 Strength, +2 for a trained miner, 1 to 100; veins never run out\n",
        "mining reload reads the file also when it has not changed")
    ue:fireConsole("mining RELOAD")
    check(printedCount(ue, "settings read:") == 2, "the word is taken in any letter case")
    os.remove(c.path)
    before = #ue.printed
    ue:fireConsole("mining reload")
    check(ue.printed[before + 1] == "[G1R_Mining] settings not read: config.lua not found\n", "mining reload without a file says so")
    check(c.hook.console(nil, nil, nil) == true and c.hook.console("mining reload", nil, nil) == true and c.hook.console("mining", { 2, {} }, {}) == true and #ue.errors == 0,
        "called with nothing, with the command line only, with parameters of another kind: handled")
    check(printedCount(ue, "settings not read") == 2, "with the command line only, the words are taken from it")
    stop(c)
    c = start("status-vein-only", { config = config({ "Config.VeinLastsTimes = 2", "Config.ShowMessage = false" }) })
    c.ticks(1)
    lines = c.hook.status()
    check(#lines == 3 and lines[1] == "v1.0.0 | a vein lasts 2 times as long" and has(lines[2], "the game's own numbers: 3 ore per swing"),
        "without a rule for the ore per swing the status has no line for it")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("15. nothing leaks, only config.lua is written; the diagnostics")
do
    local known = {}
    local probe = T.Mock.new()
    probe:install()                 -- what the mock itself puts into _G does not count
    for k in pairs(_G) do known[k] = true end
    probe:uninstall()
    local given = { MINING_TEST = true, ModRef = true, G1R_KIT = true, G1R_SETTINGS = true, G1R_DIAG = true, Key = true, ModifierKey = true, StaticConstructObject = true }
    local c = start("leak", { config = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 0", "Config.StrengthPerOre = 4", "Config.DexterityPerOre = 6",
        "Config.TrainedBonus = 1", "Config.MinAmount = 0", "Config.LowVeinRule = false", "Config.EndlessVeins = true" }), widgets = true, diag = true,
        model = { strength = 20, dexterity = 12 } })
    local w = c.world
    local vein = w.vein(1, 15)
    c.swing(vein)
    c.ticks(40)
    c.swing(vein)
    local leaked = {}
    for k in pairs(_G) do
        if not known[k] and not given[k] then leaked[#leaked + 1] = tostring(k) end
    end
    local sequence = table.concat(c.fake.sequence(), " ")
    local dump = c.fake.dump[1] and c.fake.dump[1]() or nil
    local statusLines = c.fake.status[1] and c.fake.status[1]() or {}
    local reads, checks, lookups, finds, system = w.n.reads, w.n.checks, #c.ue.lookups, allOf(c.ue), w.reads[21]
    for _ = 1, 20 do
        c.fake.dump[1]()
        c.fake.status[1]()
    end
    check(w.n.reads == reads and w.n.checks == checks and #c.ue.lookups == lookups and allOf(c.ue) == finds and w.reads[21] == system,
        "the status and the dump are built from what the module holds: no call into the game")
    local never = true
    for _, key in ipairs({ "mining.ability_found_by", "mining.config_found_by", "mining.game_numbers", "mining.ore_class", "mining.attributes", "mining.skill_tags",
        "mining.config_write", "mining.swing_seen", "mining.vein_reference", "mining.vein_module", "mining.vein_count", "mining.vein_size_from", "mining.vein_add",
        "mining.swing_gave", "mining.swing_end", "mining.config_kept" }) do
        if c.fake.count[key] ~= 1 then never = false end
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
    check(sequence == "mining.ability_found_by=ability list mining.config_found_by=world definition mining.game_numbers=3/1/5 mining.ore_class=world definition "
        .. "mining.skill_tags=readable mining.attributes=readable mining.config_write=ok mining.swing_seen=yes mining.vein_reference=weak pointer "
        .. "mining.vein_module=module list mining.vein_count=function mining.vein_size_from=default contents mining.vein_add=function "
        .. "mining.swing_gave=as the numbers say mining.swing_end=ability at rest mining.config_kept=yes", "the notes of a session with two swings: " .. sequence)
    check(never, "each of them made once")
    check(c.fake.versions[1] == "1.0.0" and #c.fake.events == 1
        and c.fake.events[1] == "first swing with ore: 7 from BP_MiningSpot_C_1 (the numbers in force said 7, the game's own 3); the vein held 15 when the swing began, 22 before the game took its ore, 15 after",
        "the version and the first swing with ore go to the diagnostics: " .. tostring(c.fake.events[1]))
    local crumbs = table.concat(c.fake.crumbs, " | ")
    check(crumbs == "first call of the game state's GetWorldDefinition | first question for a gameplay tag of the hero (HasGameplayTag) | "
        .. "first write of one of the game's mining numbers | first count of a vein's ore by its container's HasItemMain | "
        .. "first ore put into a vein by its container's Multicast_AddNewItem",
        "each first step into the game is announced on disk before it is taken, once: " .. crumbs)
    local Fake = dofile(HERE .. "../markers/diag_fake.lua")
    local plain, where = Fake.plain(dump)
    check(plain and Fake.roundTrip(dump), "the dump is plain data (" .. tostring(where) .. ")")
    check(dump.version == "1.0.0" and dump.enabled == true and dump.looking == true and dump.yield_enabled == true and dump.base_amount == 0 and dump.strength_per_ore == 4
        and dump.dexterity_per_ore == 6 and dump.trained_bonus == 1 and dump.master_bonus == 0 and dump.extra_chance == 0 and dump.min_amount == 0
        and dump.max_amount == 100 and dump.low_vein_rule == false and dump.endless_veins == true and dump.vein_lasts_times == 1 and dump.show_message == true
        and dump.log_swings == false and dump.vein_method == "auto" and dump.refresh_seconds == 5, "the dump: the settings")
    check(dump.config == "MiningConfig /Script/Angelscript.Default__MiningConfig" and dump.config_found_through == "world definition" and dump.game_numbers.high == 3
        and dump.game_numbers.low == 1 and dump.game_numbers.threshold == 5 and dump.config_holds.high == 7 and dump.config_holds.low == 7
        and dump.own_numbers_in_config == true and dump.yield_off == nil, "the dump: the game's numbers and what the config holds now")
    check(dump.amount == 7 and dump.strength == 20 and dump.dexterity == 12 and dump.rank == nil and dump.waiting_for == nil and dump.skill_tags_unusable == false
        and dump.ore_class_from == "world definition" and dump.ability == w.ability:GetFullName() and dump.ability_found_through == "ability list",
        "the dump: the hero's values and his ability")
    check(dump.swing == nil and dump.count_way == "function" and dump.add_off == false and dump.add_failed_function == false and dump.add_failed_slot == false
        and dump.swings == 2 and dump.ore == 14 and dump.game_would_give == 6 and dump.put_into_veins == 14 and dump.extras == 0
        and dump.last_swing == "7 ore from BP_MiningSpot_C_1", "the dump: swings and veins")
    check(#statusLines == 4 and statusLines[1] == "v1.0.0 | ore per swing: base 0, +1 per 4 Strength, +1 per 6 Dexterity, +1 for a trained miner, 0 to 100, "
        .. "the same from a nearly empty vein; veins never run out", "the status function gives the status lines")

    -- a dump in the middle of a swing, and of a module that found nothing
    c = start("dump-swing", { config = config({ "Config.YieldEnabled = true", "Config.ExtraChance = 100", "Config.EndlessVeins = true", "Config.ShowMessage = false" }), diag = true })
    w = c.world
    vein = w.vein(1, 15)
    w.startSwing(vein)
    c.ticks(2)
    dump = c.fake.dump[1]()
    check(Fake.plain(dump) and dump.swing.vein == vein.actor:GetFullName() and dump.swing.found == 15 and dump.swing.before == 19 and dump.swing.expected == 4
        and dump.swing.game == 3 and dump.swing.extra == 1 and dump.config_holds.high == 4, "the dump in the middle of a swing: the vein, what it held, what the swing will give")
    w.endSwing(vein)
    c.ticks(1)
    check(c.fake.dump[1]().extras == 1 and c.fake.dump[1]().swing == nil, "after it: one extra ore counted")
    stop(c)
    -- the first swing with ore, when the first swing gave none and the next just one
    c = start("event-one", { config = config({ "Config.VeinLastsTimes = 2", "Config.ShowMessage = false" }), diag = true })
    w = c.world
    vein = w.vein(1, 5)
    c.swing(vein, 2, true)
    check(#c.fake.events == 0 and c.S.swings == 1, "a swing that was broken off is not the first swing with ore: nothing goes to the session log")
    check(c.swing(vein) == 1 and #c.fake.events == 1
        and c.fake.events[1] == "first swing with ore: 1 from BP_MiningSpot_C_1 (the numbers in force said 1, the game's own 1); the vein held 5 when the swing began, 5 before the game took its ore, 4 after",
        "a swing of 1 ore is: " .. tostring(c.fake.events[1]))
    c.swing(vein)
    check(#c.fake.events == 1, "it is said once")
    stop(c)
    c = start("dump-idle", { diag = true })
    dump = c.fake.dump[1]()
    c.ticks(8)
    check(Fake.plain(dump) and Fake.roundTrip(dump) and dump.looking == false and dump.game_numbers == nil and dump.config == nil and dump.ability == nil
        and dump.own_numbers_in_config == false and #c.fake.notes == 0 and #c.fake.crumbs == 0 and #c.fake.events == 0,
        "the dump of the idle module is plain data too; no note is made, nothing is announced")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("16. through the megamod loader, with the real diagnostics")
do
    local TMP = T.TMP
    local root = TMP .. "/mega/G1R_MegaMod"
    T.sh("rm -rf " .. T.q(TMP .. "/mega") .. " && mkdir -p " .. T.q(root) .. " && cp -r " .. T.q(MOD .. "Scripts") .. " " .. T.q(root .. "/") .. " && mkdir -p " .. T.q(root .. "/modules")
        .. " && cp -r " .. T.q(MOD .. "modules/mining") .. " " .. T.q(root .. "/modules/"))
    -- only this module: the list of modules is cut down to it
    T.write(root .. "/Scripts/core/modules.lua", 'return { { name = "mining", switch = "Mining", separate = { "BetterMining" } } }\n')
    local SETTINGS = config({ "Config.YieldEnabled = true", "Config.BaseAmount = 7", "Config.EndlessVeins = true" })
    T.write(root .. "/modules/mining/Scripts/config.lua", SETTINGS)

    local function boot()
        local ue = T.Mock.new()
        ue:install()
        local ui = T.widgets(ue)
        local world = build(ue)
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
        function c.swing(v)
            world.startSwing(v)
            c.looks(8)
            local got = world.endSwing(v)
            c.looks(1)
            return got
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
    check(c.ok and has(last(c), "loaded: mining ok | diagnostics normal"), "the loader loads the module: " .. last(c))
    check(rawget(_G, "MINING_TEST") == nil and rawget(_G, "G1R_KIT") == nil and rawget(_G, "G1R_SETTINGS") == nil, "the test hook stays inert; the kit and the settings service are no globals")
    local vein = w.vein(1, 15)
    check(c.swing(vein) == 7 and vein.total() == 15 and #ue.errors == 0 and c.ui.note() == "Mining: 7 ore (the game gives 3)",
        "as without the loader: 7 ore per swing from a vein that stays at 15, and the note")
    check(ue:fireConsole("g1r diag") == true, "g1r diag handled")
    local report = T.read(c.dir .. "/report-latest.txt") or ""
    check(has(report, "mining: loaded, version 1.0.0") and has(report, "[mining] v1.0.0 | ore per swing: base 7, 1 to 100; veins never run out")
        and has(report, "[mining] the game's own numbers: 3 ore per swing, 1 when 5 or fewer are left in the vein (found through the world definition)")
        and has(report, "[mining] ore per swing now: 7")
        and has(report, "[mining] swings seen: 1, ore: 7 (by the game's own numbers: 3), put into veins: 7; last: 7 ore from BP_MiningSpot_C_1"),
        "report: the module's version and its status lines")
    check(has(report, "mining.config_found_by = world definition") and has(report, "mining.game_numbers = 3/1/5") and has(report, "mining.config_write = ok")
        and has(report, "mining.ability_found_by = ability list") and has(report, "mining.vein_add = function") and has(report, "mining.swing_gave = as the numbers say")
        and has(report, "mining.swing_end = ability at rest") and has(report, "kit.toast = shown"), "report: the notes of the module and of the kit")
    check(has(report, "[mining] callbacks LoopInGameThreadWithDelay: 9 calls, 0 errors") and has(report, "[kit] lookups: 6 calls, 6 first-time, 0 not found"),
        "report: the module's loop and the kit's six searches (for the note) are counted; the module itself searched nothing")
    local log = newest(c, "session-")
    check(has(log, "[mining] [G1R_Mining] v1.0.0 loaded: ore per swing: base 7, 1 to 100; veins never run out") and not has(log, "ERROR in "), "session log: the load line, no error")
    check(ue:fireConsole("g1r dump") == true, "g1r dump handled")
    local okDump, dump = pcall(load(newest(c, "dump-"), "=dump", "t", {}))
    check(okDump and type(dump) == "table" and type(dump.mining) == "table" and dump.mining.swings == 1 and dump.mining.ore == 7 and dump.mining.game_numbers.high == 3
        and dump.mining.config_holds.high == 7 and dump._meta.refusedCount == 0, "dump: what the module holds")
    check(ue:fireConsole("g1r") == true and printed(ue, "[G1R_MegaMod] mining: loaded, version 1.0.0, 0 error(s), 14 note(s)") ~= nil, "g1r lists the module with its notes")
    -- settings through the loader: the in-game menu
    c.mods.store["SMM:cmd:G1R Resources"] = "3\31n4"
    c.looks(2)
    check(printed(ue, "[G1R_Mining] settings changed (in-game menu): ore per swing: base 4, 1 to 100; veins never run out") ~= nil and w.numbers.m_AmountAtHighOre == 4,
        "an edit in the in-game menu reaches the module through the loader's loop, and the game's number follows at the module's next look")
    check(c.swing(vein) == 4 and has(T.read(root .. "/modules/mining/Scripts/config.lua"), "Config.BaseAmount = 4\n"), "the new amount is used and written into the module's config.lua")
    check(ue:fireConsole("mining") == true and printed(ue, "[G1R_Mining] swings seen: 2, ore: 11") ~= nil, "the module's own console command works through the loader")
    shutdown(c)

    -- the other author's mod is installed and enabled next to the megamod: the module is not loaded
    T.sh("mkdir -p " .. T.q(TMP .. "/mega/BetterMining/scripts"))
    T.write(TMP .. "/mega/BetterMining/scripts/main.lua", "-- another mod\n")
    T.write(TMP .. "/mega/BetterMining/enabled.txt", "")
    T.write(root .. "/modules/mining/Scripts/config.lua", SETTINGS)
    c = boot()
    check(c.ok and has(last(c), "mining left to the separate mod BetterMining")
        and printed(c.ue, "module mining not loaded: the separate mod BetterMining is installed and enabled") ~= nil,
        "BetterMining enabled next to the megamod (its folder is called scripts): " .. last(c))
    vein = c.world.vein(1, 15)
    check(c.swing(vein) == 3 and vein.total() == 12 and c.world.n.reads == 0 and c.mods.store["SMM:index"] == nil,
        "the game is left to that mod: nothing is read or written, no page is registered with the in-game menu")
    shutdown(c)
    os.remove(TMP .. "/mega/BetterMining/enabled.txt")
    c = boot()
    check(has(last(c), "mining ok"), "the same folder without enabled.txt and without a line in mods.txt: the module is loaded")
    shutdown(c)
    T.write(TMP .. "/mega/mods.txt", "BetterMining : 1\r\n")
    c = boot()
    check(has(last(c), "mining left to the separate mod BetterMining"), "enabled through mods.txt: not loaded")
    shutdown(c)
    os.remove(TMP .. "/mega/mods.txt")
    T.sh("rm -rf " .. T.q(TMP .. "/mega/BetterMining"))

    -- switched off in the megamod's own settings
    T.write(root .. "/Scripts/config.lua", T.config("Config.Modules = { Mining = false }"))
    c = boot()
    check(has(last(c), "loaded: mining off |"), "Config.Modules.Mining = false: the module is not loaded")
    shutdown(c)

    -- diagnostics off: the module runs as on its own
    T.write(root .. "/Scripts/config.lua", T.config('Config.Diagnostics = { Level = "off" }'))
    c = boot()
    vein = c.world.vein(1, 15)
    check(printed(c.ue, "mining ok | diagnostics off") ~= nil and c.swing(vein) == 7 and vein.total() == 15 and #c.ue.errors == 0, "diagnostics off: the module works, no error")
    shutdown(c)

    -- a loader without its kit: the module says what it needs
    os.remove(root .. "/Scripts/core/kit.lua")
    c = boot()
    check(c.ok and printed(c.ue, "[G1R_MegaMod] core/kit.lua could not be used") ~= nil
        and printed(c.ue, "[G1R_Mining] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started") ~= nil,
        "core/kit.lua missing: the loader says so, the module says what it needs and does not start")
    check(has(last(c), "mining ok") and not has(table.concat(c.ue.printed), "failed to load"), "that is not an error of the module: " .. last(c))
    vein = c.world.vein(1, 15)
    check(c.swing(vein) == 3 and c.world.n.reads == 0 and #c.ue.errors == 0, "and the game is left alone, no error")
    shutdown(c)
end

math.random = realRandom

T.finish()
