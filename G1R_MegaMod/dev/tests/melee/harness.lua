-- ============================================================================
-- Offline tests of the module melee (modules/melee/Scripts/main.lua).
--
--   lua5.4 harness.lua          (from any directory)
--
-- The module runs on the loader's kit and settings service; ../lib/modtest.lua
-- sets both up the way the loader does and replaces UE4SS by ../mock/ue4ss.lua.
-- The game is a model built here on top of modtest's (function `game` below):
-- every behaviour in it names where it is known from (dev/facts/melee.md has
-- the same sources). Addresses are those of the game executable of build
-- Build83_CL174209; script lines those of the game's AngelScript source.
-- Last line: "melee tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("melee")
local check, section, has, printed, printedCount = T.check, T.section, T.has, T.printed, T.printedCount
local MOD = T.MOD

-- The game keeps these numbers in single precision.
local function f32(v) return (string.unpack("f", string.pack("f", v))) end
local function near(a, b) return a ~= nil and b ~= nil and math.abs(a - b) < 1e-7 end

-- ---------------------------------------------------------------------------
-- The model of the game
-- ---------------------------------------------------------------------------
local OPTION_PATH = "/Script/G1R.Default__SettingObject_Bool_EnableFakeSloppyCombos"
local SETTINGS_PATH = "/Script/G1R.Default__GothicGameUserSettings"
local FEEDBACK_PATH = "/Script/Angelscript.Default__GenericMeleeFeedback"
local STATICS_PATH = "/Script/Engine.Default__GameplayStatics"
local NONE_PATH = "/Script/Angelscript.MatineeCameraShake_None"

-- Items/Weapons/ControlFeedback.as, class UGenericMeleeFeedback: AddAttackFreezeFrame / AddHitFreezeFrame
-- (hit type, CustomSlow, FreezeDuration, BlendOutDuration), in the order of the file.
local FREEZES = {
    { "Combat.HitType.Additive", { 0.0, 0.033, 0.033 }, { 0.0, 0.033, 0.033 } },
    { "Combat.HitType.Standard", { 0.0, 0.05, 0.05 }, { 0.0, 0.05, 0.05 } },
    { "Combat.HitType.Knockback", { 0.0, 0.05, 0.033 }, { 0.0, 0.05, 0.05 } },
    { "Combat.HitType.Parried", { 0.0, 0.05, 0.05 }, { 0.0, 0.05, 0.05 } },
    { "Combat.HitType.Deflected", { 0.5, 0.033, 0.033 }, { 0.5, 0.033, 0.033 } },
    { "Combat.HitType.Dot", { 1.0, 0.033, 0.033 }, { 1.0, 0.033, 0.033 } },
}
-- The same class: AddCameraShake (the attacker's table, seven entries) and m_HitCameraShakeParams.Add (six).
local ATTACK_SHAKES = {
    { "Action.Smash.MeatBug", "MatineeCameraShake_SmashMeatBug" },
    { "Combat.HitType.Additive", "MatineeCameraShake_Combat_Additive" },
    { "Combat.HitType.Standard", "MatineeCameraShake_Combat_Standard" },
    { "Combat.HitType.Knockback", "MatineeCameraShake_Combat_Standard" },
    { "Combat.HitType.Parried", "MatineeCameraShake_Combat_Parried" },
    { "Combat.HitType.Deflected", "MatineeCameraShake_Combat_Deflected" },
    { "Combat.HitType.Dot", "MatineeCameraShake_None" },
}
local HIT_SHAKES = {
    { "Combat.HitType.Additive", "MatineeCameraShake_Combat_Additive" },
    { "Combat.HitType.Standard", "MatineeCameraShake_Combat_Standard" },
    { "Combat.HitType.Knockback", "MatineeCameraShake_Combat_Standard" },
    { "Combat.HitType.Parried", "MatineeCameraShake_Combat_Parried" },
    { "Combat.HitType.Deflected", "MatineeCameraShake_None" },
    { "Combat.HitType.Dot", "MatineeCameraShake_None" },
}
-- Items/Weapons/S1H/Combos_Human_Trained.as: the options of the first attacks. AddOption = an option of the combo
-- window (EComboTiming 1), AddOptionByTiming(.., EComboTiming(2), ..) = one of the recovery ("reset states").
local COMBOS = {
    R01 = { { "Right", 2, "L01_NoCombo" }, { "Left", 1, "R_L02" }, { "Top", 1, "R_T02" } },
    L01 = { { "Right", 1, "L_R02" }, { "Left", 2, "R01_NoCombo" }, { "Top", 1, "L_T02" } },
    T01 = { { "Right", 1, "T_R02" }, { "Left", 1, "T_L02" } },
}
-- Items/Weapons/S1H/AnimConfig_Human.as: m_Attacks of USword1H_Human_Trained (the first attack of a direction).
local FIRST = { Right = "R01", Left = "L01", Top = "T01", Bottom = "B01" }

-- options: noController, profiles ({ [id] = value }), profile (id in use), noOption, noSettingsClass, noProfiles,
-- noFeedback, noStatics, noNoneClass (the "no shake" class cannot be found by its name), plainShakes (no entry
-- of the shake tables names that class), noneName (the object name of that class in the tables), feedbackName
-- (full name of the feedback object).
local function game(ue, options)
    options = options or {}
    local world = T.newWorld(ue, { noController = options.noController })
    world.calls = {}            -- what the module asked of the game: name -> times
    world.fieldReads, world.fieldWrites, world.walks = 0, 0, 0     -- struct fields read / written, tables walked (world.reads is modtest's)
    world.escaped = 0           -- errors that left a ForEach callback
    local function called(name) world.calls[name] = (world.calls[name] or 0) + 1 end
    function world.called(name) return world.calls[name] or 0 end

    -- /Script/Engine.Default__GameplayStatics:IsGamePaused(world) - what the kit's paused() asks (facts K6).
    if not options.noStatics then
        ue.objects[STATICS_PATH] = ue:object("GameplayStatics " .. STATICS_PATH, {
            IsGamePaused = function()
                called("IsGamePaused")
                return world.paused == true
            end })
    end

    -- ------------------------------------------------------------------ the flow helper
    -- The value the fight code reads is one byte of the game's settings object (m_FakeSloppyCombos, +0x283).
    world.profiles = options.profiles or { [0] = true }        -- what each profile has stored; the game's default is on
    world.profileId = options.profile or 0
    world.stores = 0            -- how often the game stored the profile
    local flag = { value = world.profiles[world.profileId] }
    function world.sloppy() return flag.value end
    world.settings = ue:object("GothicGameUserSettings /Engine/Transient.GothicGameUserSettings_2147482581", {})
    do
        local base = getmetatable(world.settings)
        setmetatable(world.settings, {
            __index = function(_, k)
                if k == "m_FakeSloppyCombos" then
                    called("flag read")
                    if world.flagUnreadable then return nil end
                    return flag.value
                end
                return base.__index[k]
            end,
            __newindex = function(t, k, v)
                if k ~= "m_FakeSloppyCombos" then return rawset(t, k, v) end
                called("flag write")
                if world.flagReadOnly then error("the property is read only (test)") end
                if type(v) ~= "boolean" then error("m_FakeSloppyCombos takes a boolean") end
                if not world.flagDeaf then flag.value = v end
            end })
    end
    -- UGothicGameUserSettings::SetFakeSloppyCombos (0x145bfb840) writes the byte and raises the settings' delegate;
    -- bound to it is UDifficultyManagerSubsystem::OnFakeSloppyCombosApplied (0x14595e300): the subsystem's own
    -- copy, the value in the data of the profile in use, and the profile is stored.
    function world.gameSets(v)
        flag.value = v
        world.subsystemCopy = v
        world.profiles[world.profileId] = v
        world.stores = world.stores + 1
    end
    -- A profile is applied (0x145966560): its stored value goes into the settings object the same way.
    function world.loadProfile(id)
        world.profileId = id
        world.persistent.m_CurrentProfileId = id
        if world.profiles[id] == nil then world.profiles[id] = true end
        world.gameSets(world.profiles[id])
    end
    -- The game's own option object, class USettingObject_Bool_EnableFakeSloppyCombos. GetValue (0x145c78bb0) and
    -- SetValue (0x145c8cb30) do not use the object they are called on: they go to the settings object. So the
    -- class default object does what the row of the options menu does.
    if not options.noOption then
        ue.objects[OPTION_PATH] = ue:object("SettingObject_Bool_EnableFakeSloppyCombos " .. OPTION_PATH, {
            GetValue = function(_, ...)
                called("GetValue")
                if select("#", ...) ~= 0 then error("GetValue takes no parameter") end
                if world.getValue then return world.getValue() end
                return flag.value
            end,
            SetValue = function(_, v, ...)
                called("SetValue")
                if type(v) ~= "boolean" or select("#", ...) ~= 0 then error("SetValue takes one boolean") end
                if world.setValue then return world.setValue(v) end
                world.gameSets(v)
            end })
    end
    -- UGothicGameUserSettings::GetGothicGameUserSettings() - a static UFunction (flags 0x4022401) that returns
    -- the settings object; called on the class default object.
    if not options.noSettingsClass then
        ue.objects[SETTINGS_PATH] = ue:object("GothicGameUserSettings " .. SETTINGS_PATH, {
            GetGothicGameUserSettings = function()
                called("GetGothicGameUserSettings")
                if world.getSettingsRaises then error("GetGothicGameUserSettings failed (test)") end
                if world.noSettingsObject then return ue:invalid() end
                return world.settings
            end })
    end
    -- PersistentDataSubsystem.m_CurrentProfileId (property layout; the repopulate module reads it in the game).
    world.persistent = ue:object("PersistentDataSubsystem /Engine/Transient.GameEngine_2147482624:G1RGameInstance_2147482484.PersistentDataSubsystem_2147482432",
        { m_CurrentProfileId = world.profileId })
    if not options.noProfiles then ue.firstOf["PersistentDataSubsystem"] = world.persistent end
    -- What the flag does. The option lookup of a combo (0x1459c0f00): with the flag off only options of the combo
    -- window are found. The attack input (0x145adfd40): in the combo window the option of that window or nothing;
    -- while the swing recovers the option of the recovery, else the weapon's first attack of that direction.
    local function option(attack, direction, timing)
        if not flag.value and timing ~= 1 then return nil end
        for _, o in ipairs(COMBOS[attack] or {}) do
            if o[1] == direction and o[2] == timing then return o[3] end
        end
        return nil
    end
    function world.press(current, direction, window)
        if window == "recovery" then return option(current, direction, 2) or FIRST[direction] end
        return option(current, direction, 1)
    end

    -- ------------------------------------------------------------------ the feedback object
    -- A struct of the game as UE4SS hands it out: a wrapper on the entry's own memory; reading a field reads it,
    -- assigning writes it; IsValid() is a method of the wrapper, not a read (LuaUScriptStruct.cpp; in the game:
    -- the mod G1R_MageBalance reads and assigns float fields of map and array elements of script class default
    -- objects this way, UE4SS.log of 2026-10-01).
    local function structValid() return true end
    local function freezeStruct(values)
        local store = { m_CustomTimeDilation = f32(values[1]), m_FreezeDuration = f32(values[2]), m_BlendOutDuration = f32(values[3]) }
        return setmetatable({ __store = store }, {
            __index = function(_, k)
                if k == "IsValid" then return structValid end
                world.fieldReads = world.fieldReads + 1
                if world.fieldUnreadable == k then return nil end
                return store[k]
            end,
            __newindex = function(_, k, v)
                world.fieldWrites = world.fieldWrites + 1
                if world.fieldRaises then error("the property could not be written (test)") end
                if store[k] == nil then error("FreezeParams has no property " .. tostring(k)) end
                if type(v) ~= "number" then error(tostring(k) .. " takes a number") end
                if world.fieldDeaf == true or world.fieldDeaf == k then return end
                store[k] = f32(v)
            end })
    end
    local function storeOf(struct) return rawget(struct, "__store") end
    world.classes = {}
    local function classOf(name)
        if world.classes[name] == nil then world.classes[name] = ue:object("Class /Script/Angelscript." .. name, {}) end
        return world.classes[name]
    end
    -- A gameplay tag as a map key: a struct with the property TagName (an FName with ToString()). Switches:
    -- keysUnreadable (the property gives nothing), keyNamePlain (the name arrives as a Lua string),
    -- keyTextRaises (ToString raises), keyText (what ToString answers instead of the name).
    local function tagStruct(text)
        return setmetatable({}, { __index = function(_, k)
            if k == "IsValid" then return structValid end
            if k ~= "TagName" then return nil end
            called("key name")
            if world.keysUnreadable then return nil end
            if world.keyNamePlain then return text end
            return { ToString = function()
                if world.keyTextRaises then error("ToString failed (test)") end
                if world.keyText ~= nil then return world.keyText end
                return text
            end }
        end })
    end
    -- A TMap property as this UE4SS hands it out (LuaTMap.cpp): ForEach(function(key, value)) with parameter
    -- wrappers that have get() and set(). An error that leaves the callback is not an ordinary Lua error in the
    -- game (Lua::call_function throws a C++ exception; the author of G1R_MageBalance calls it uncatchable): the
    -- model counts it in world.escaped, and the checks demand zero.
    local function tmap(name, entries)
        local map = { entries = entries, name = name, walked = 0 }
        function map:ForEach(f)
            world.walks = world.walks + 1
            self.walked = self.walked + 1
            called("ForEach " .. name)
            if world.mapRaises == name then error("ForEach of " .. name .. " failed (test)") end
            -- mapRaisesOn = { name, walk }: only that walk through that table fails
            if world.mapRaisesOn and world.mapRaisesOn.name == name and world.mapRaisesOn.walk == self.walked then error("ForEach of " .. name .. " failed (test)") end
            if world.emptyMap == name then return end              -- the walk visits nothing
            for index, e in ipairs(self.entries) do
                if world.vanishing == name and index == #self.entries then break end       -- the last entry is gone
                local key = { get = function()
                    called("key")
                    return e.key
                end }
                local value = {
                    get = function()
                        if world.valueNil == name then return nil end
                        if world.copies and type(e.value) == "table" and storeOf(e.value) then
                            local s = storeOf(e.value)
                            return freezeStruct({ s.m_CustomTimeDilation, s.m_FreezeDuration, s.m_BlendOutDuration })
                        end
                        return e.value
                    end,
                    set = function(_, x)
                        called("set")
                        if world.setRaises then error("the value could not be set (test)") end
                        if type(x) ~= "table" or x.__full == nil then error("the value of " .. name .. " is a class") end
                        if not world.setDeaf then e.value = x end
                    end,
                }
                local ok, err = pcall(f, key, value)
                if not ok then
                    world.escaped = world.escaped + 1
                    error(err, 0)
                end
            end
            if world.growing == name then
                -- one more entry than at the last walk
                local extra = { get = function() return self.entries[1].key end }
                local ok, err = pcall(f, extra, { get = function() return self.entries[1].value end, set = function() end })
                if not ok then
                    world.escaped = world.escaped + 1
                    error(err, 0)
                end
            end
        end
        return map
    end
    local attackFreeze, hitFreeze, attackShake, hitShake = {}, {}, {}, {}
    for _, f in ipairs(FREEZES) do
        attackFreeze[#attackFreeze + 1] = { key = tagStruct(f[1]), tag = f[1], value = freezeStruct(f[2]) }
        hitFreeze[#hitFreeze + 1] = { key = tagStruct(f[1]), tag = f[1], value = freezeStruct(f[3]) }
    end
    local function shakeName(name)
        if name ~= "MatineeCameraShake_None" then return name end
        if options.plainShakes then return "MatineeCameraShake_Combat_Deflected" end
        return options.noneName or name
    end
    for _, s in ipairs(ATTACK_SHAKES) do attackShake[#attackShake + 1] = { key = tagStruct(s[1]), tag = s[1], value = classOf(shakeName(s[2])) } end
    for _, s in ipairs(HIT_SHAKES) do hitShake[#hitShake + 1] = { key = tagStruct(s[1]), tag = s[1], value = classOf(shakeName(s[2])) } end
    world.tables = {
        m_AttackFreezeParams = tmap("m_AttackFreezeParams", attackFreeze), m_HitFreezeParams = tmap("m_HitFreezeParams", hitFreeze),
        m_AttackCameraShakeParams = tmap("m_AttackCameraShakeParams", attackShake), m_HitCameraShakeParams = tmap("m_HitCameraShakeParams", hitShake),
    }
    -- The default object of the script class UGenericMeleeFeedback. Script classes drop the U in their object
    -- names (in the game: G1R_MageBalance finds /Script/Angelscript.Default__FireBoltProjectileDefinition for
    -- the script class UFireBoltProjectileDefinition).
    world.feedback = ue:object(options.feedbackName or ("GenericMeleeFeedback " .. FEEDBACK_PATH), {})
    do
        local base = getmetatable(world.feedback)
        setmetatable(world.feedback, { __index = function(_, k)
            local map = world.tables[k]
            if map ~= nil then
                called("table " .. k)
                if world.tableMissing == k then return nil end
                return map
            end
            return base.__index[k]
        end })
    end
    if not options.noFeedback then ue.objects[FEEDBACK_PATH] = world.feedback end
    if not options.noNoneClass then ue.objects[NONE_PATH] = classOf("MatineeCameraShake_None") end

    local function entryOf(tableName, tag)
        for _, e in ipairs(world.tables[tableName].entries) do
            if e.tag == tag then return e end
        end
        return nil
    end
    -- the seconds of an entry, as the game has them now: freeze, blend-out
    function world.freeze(tableName, tag)
        local s = storeOf(entryOf(tableName, "Combat.HitType." .. tag).value)
        return s.m_FreezeDuration, s.m_BlendOutDuration, s.m_CustomTimeDilation
    end
    function world.shake(tableName, tag)
        local e = entryOf(tableName, tag:find("%.") and tag or ("Combat.HitType." .. tag))
        return e.value.__full:match("([%w_]+)$")
    end
    function world.setFreeze(tableName, tag, seconds, blend)
        local store = storeOf(entryOf(tableName, "Combat.HitType." .. tag).value)
        store.m_FreezeDuration = f32(seconds)
        if blend ~= nil then store.m_BlendOutDuration = f32(blend) end
    end
    -- UFeedbackData::GetHitFreezeParams (0x145a32720) / GetAttackFreezeParams (0x145a2f9d0): the entry of the hit
    -- type; a table without one answers { 0.25, 1.25, 1.25 }.
    local function params(tableName, tag)
        local e = entryOf(tableName, tag)
        if e == nil then return { m_CustomTimeDilation = 0.25, m_FreezeDuration = 1.25, m_BlendOutDuration = 1.25 } end
        return storeOf(e.value)
    end
    -- A melee blow with the hero in it, as the game's damage script handles it (GAS/Calculations/Damage.as):
    -- lines 419-431 the freeze - nothing when the duration of the one who is hit is not above 0, else
    -- ActiveFreezeFrame(dilation, duration, blend-out) for the attacker and for the one who is hit (the two
    -- tables change places for a deflected blow); lines 389-393 the attacker's camera shake when the table
    -- names a class. The shake of the one who is hit comes from the hit abilities' function 0x145b11b60
    -- (GetHitCameraShake). Returns { attacker = seconds, target = seconds, total = both with their blend-out,
    -- shake = class name, hitShake = class name }.
    function world.blow(tag)
        tag = "Combat.HitType." .. tag
        local hit, attack = params("m_HitFreezeParams", tag), params("m_AttackFreezeParams", tag)
        if tag == "Combat.HitType.Deflected" then hit, attack = attack, hit end
        local out = { attacker = 0, target = 0, blend = 0 }
        if hit.m_FreezeDuration > 0 then
            out.attacker, out.target, out.blend = attack.m_FreezeDuration, hit.m_FreezeDuration, hit.m_BlendOutDuration
        end
        local a, h = entryOf("m_AttackCameraShakeParams", tag), entryOf("m_HitCameraShakeParams", tag)
        out.shake = a and a.value.__full:match("([%w_]+)$") or nil
        out.hitShake = h and h.value.__full:match("([%w_]+)$") or nil
        return out
    end
    return world
end

local function start(case, options)
    options = options or {}
    options.module, options.hook = "melee", "MELEE_TEST"
    if options.prepare == nil then
        local gameOptions = options.game
        options.prepare = function(ue) return game(ue, gameOptions) end
    end
    local c = T.boot(case, options)
    c.S = c.hook and c.hook.state
    return c
end
local stop = T.stop
local function allOf(ue) return ue.calls.FindAllOf or 0 end
local function firstOf(ue) return ue.calls.FindFirstOf or 0 end
local function status(c) return table.concat(c.hook.status(), "|") end
-- how often a path was searched for
local function searched(ue, path)
    local n = 0
    for _, p in ipairs(ue.lookups) do if p == path then n = n + 1 end end
    return n
end
local function sum(t) local n = 0 for _, v in pairs(t) do n = n + v end return n end

-- what the game has in its freeze tables: every freeze and blend-out time is the game's own times `factor`,
-- and the time dilation is the game's own (exact = the very same numbers)
local FREEZE_TABLES = { "m_AttackFreezeParams", "m_HitFreezeParams" }
local SHAKE_TABLES = { "m_AttackCameraShakeParams", "m_HitCameraShakeParams" }
local function freezesAt(w, factor, exact, only)
    for column, name in ipairs(FREEZE_TABLES) do
        for _, row in ipairs((only == nil or only == name) and FREEZES or {}) do
            local original = row[column + 1]
            local freeze, blend, dilation = w.freeze(name, row[1]:match("([^%.]+)$"))
            local wantFreeze, wantBlend = f32(f32(original[2]) * factor), f32(f32(original[3]) * factor)
            if dilation ~= f32(original[1]) then return false end
            if exact then
                if freeze ~= wantFreeze or blend ~= wantBlend then return false end
            elseif not (near(freeze, wantFreeze) and near(blend, wantBlend)) then
                return false
            end
        end
    end
    return true
end
-- what the game has in its camera shake tables: the classes of the game's script (none = false), or the class
-- for no shake in every entry (none = true); plain: a game whose tables do not name that class anywhere
local function shakesAre(w, none, plain, noneName)
    for i, list in ipairs({ ATTACK_SHAKES, HIT_SHAKES }) do
        for _, s in ipairs(list) do
            local expected = s[2]
            if expected == "MatineeCameraShake_None" then
                if plain then expected = "MatineeCameraShake_Combat_Deflected" else expected = noneName or expected end
            end
            if none then expected = noneName or "MatineeCameraShake_None" end
            if w.shake(SHAKE_TABLES[i], s[1]) ~= expected then return false end
        end
    end
    return true
end
local function untouched(w) return freezesAt(w, 1, true) and shakesAre(w, false) end
local function reload(c, body)
    T.write(c.path, T.config(body))
    c.ue:fireConsole("melee reload")
end

local shipped = T.read(MOD .. "modules/melee/Scripts/config.lua")
local OFF = T.config('Config.FlowHelper = "off"')
local HALF = T.config("Config.HitStop = 50")
local NOSHAKE = T.config("Config.HitShake = false")
local ALL = T.config('Config.FlowHelper = "off"\nConfig.HitStop = 50\nConfig.HitShake = false')

-- ---------------------------------------------------------------------------
section("1. loading with the shipped settings")
do
    local c = start("load")
    local ue, w = c.ue, c.world
    check(c.ok, "the module loads (" .. tostring(c.err) .. ")")
    check(#ue.printed == 1 and ue.printed[1] == "[G1R_Melee] v1.0.0 loaded: nothing to change (flow helper left to the game, hit stop 100 %, camera shake on hits)\n",
        "one load line: " .. tostring(ue.printed[1]):gsub("\n", ""))
    check(#ue.loops == 2 and ue.loops[2].ms == 250 and math.type(ue.loops[2].ms) == "integer", "one game-thread loop of its own, every 250 ms")
    check(ue.console.melee ~= nil and ue.console.g1r_melee ~= nil and #ue.loadMapPre == 1 and #ue.loadMapPost == 1 and (ue.calls.RegisterHook or 0) == 0,
        "console commands melee and g1r_melee; the kit's hooks before and after a map load; no hook of its own")
    local v = c.hook.settings.values
    check(v.Enabled == true and v.FlowHelper == "game" and v.HitStop == 100 and v.HitShake == true and v.ShowMessage == true
        and v.FlowMethod == "auto" and v.CheckSeconds == 3 and v.VerifySeconds == 30 and v.ActWhilePaused == false, "the shipped file gives the documented defaults")
    c.seconds(60)
    check(#ue.lookups == 0 and allOf(ue) == 0 and firstOf(ue) == 0 and sum(w.calls) == 0 and w.fieldReads == 0 and w.walks == 0 and w.reads[21] == nil,
        "with every setting neutral the module does not look at the game at all: no search, no call, no table read in a minute")
    check(w.sloppy() == true and w.stores == 0 and near(w.freeze("m_HitFreezeParams", "Standard"), f32(0.05)) and w.shake("m_AttackCameraShakeParams", "Standard") == "MatineeCameraShake_Combat_Standard",
        "the game is untouched: flow helper, hit stop, camera shake")
    local lines = c.hook.status()
    check(#lines == 3 and lines[1] == "v1.0.0 | nothing to change (flow helper left to the game, hit stop 100 %, camera shake on hits)"
        and lines[2] == "nothing to change: the game is not looked at"
        and lines[3] == "changes: 0; flow helper set 0 time(s), put back 0; table values written 0, put back 0; looks 0 (0 while paused)", "the status says so, in three lines")
    check(T.read(c.path) == shipped and #ue.errors == 0, "the settings file is left as it is; no error")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("2. the flow helper: set the game's own way, kept as set, put back")
do
    local c = start("flow-off", { config = OFF, diag = true, widgets = true })
    local ue, w, F = c.ue, c.world, c.S.flow
    check(printed(ue, "[G1R_Melee] v1.0.0 loaded: flow helper off\n") ~= nil, "the load line names what is asked for")
    check(w.press("R01", "Right", "recovery") == "L01_NoCombo" and w.press("L01", "Left", "recovery") == "R01_NoCombo",
        "the game as it comes: the same direction again while a swing recovers starts the mirrored follow-up swing")
    check(sum(w.calls) == 0 and #ue.lookups == 0, "loading asks nothing of the game")
    c.ticks(1)
    check(w.sloppy() == false and w.called("SetValue") == 1 and w.called("flag write") == 0, "at the first look the option is set with the game's own SetValue, not by writing the value")
    check(w.subsystemCopy == false and w.profiles[0] == false and w.stores == 1, "so the game does what its menu does: its own copy, the profile's value, the profile stored once")
    check(w.called("GetValue") == 2, "read before, read back after (2 GetValue)")
    check(w.press("R01", "Right", "recovery") == "R01" and w.press("L01", "Left", "recovery") == "L01", "now the same direction again starts the same swing again")
    check(w.press("R01", "Left", "combo") == "R_L02" and w.press("T01", "Right", "combo") == "T_R02" and w.press("R01", "Right", "combo") == nil,
        "real combos (the right direction in the combo window) are what they were")
    check(printedCount(ue, "[G1R_Melee] changed in the game: flow helper off\n") == 1 and c.ui.note() == "Melee: flow helper off", "one line in the log, one note on screen")
    check(F.before["0"] == true and F.sets == 1 and F.value == false and F.way == "option object" and F.fails == 0, "the module remembers what the game had in this profile (on)")
    check(searched(ue, OPTION_PATH) == 1 and searched(ue, SETTINGS_PATH) == 0 and firstOf(ue) == 1, "one search for the option object, one for the profile; the settings object is not needed")
    c.seconds(60)
    check(w.called("SetValue") == 1 and w.called("GetValue") == 2 + 20 and w.stores == 1 and printedCount(ue, "changed in the game") == 1,
        "then it only looks: once every 3 seconds (20 GetValue in a minute), nothing is set again")
    check(searched(ue, OPTION_PATH) == 1 and firstOf(ue) == 1, "nothing is searched again")

    -- the player switches it on in the game's own menu
    w.gameSets(true)
    c.ticks(11)
    local before = w.sloppy()
    c.ticks(1)
    check(before == true and w.sloppy() == false and w.called("SetValue") == 2 and F.sets == 2, "changed in the game's own menu: set again at the next look (within 3 seconds)")
    check(F.before["0"] == true and c.ui.note() == "Melee: flow helper off" and printedCount(ue, "changed in the game: flow helper off") == 2, "what is remembered stays the first value seen; said again")

    -- back to "game": what the game had is put back, then the module is idle
    T.write(c.path, T.config('Config.FlowHelper = "game"'))
    ue:fireConsole("melee reload")
    check(printed(ue, "[G1R_Melee] settings changed (config.lua): nothing to change (flow helper left to the game, hit stop 100 %, camera shake on hits)\n") ~= nil, "the setting goes back to game: said")
    check(w.sloppy() == false, "nothing happens inside the settings callback")
    c.ticks(1)
    check(w.sloppy() == true and w.profiles[0] == true and w.called("SetValue") == 3 and F.backs == 1 and next(F.before) == nil, "at the next turn of the loop the game's value is back (on), the game's own way")
    check(printed(ue, "[G1R_Melee] changed in the game: flow helper as the game had it (on)\n") ~= nil and c.ui.note() == "Melee: flow helper as the game had it (on)", "said in the log and on screen")
    check(w.press("R01", "Right", "recovery") == "L01_NoCombo", "the mirrored follow-up swing is back")
    local calls, lookups = sum(w.calls), #ue.lookups
    c.seconds(60)
    check(sum(w.calls) == calls and #ue.lookups == lookups and has(status(c), "|nothing to change: the game is not looked at|"), "after that the game is not looked at any more")
    w.gameSets(false)
    c.seconds(10)
    check(w.sloppy() == false and sum(w.calls) == calls, "and the game's menu is the player's again: a change there stays")
    check(#ue.errors == 0 and w.escaped == 0, "no error")
    stop(c)

    -- on, where the game has off
    c = start("flow-on", { config = T.config('Config.FlowHelper = "on"'), game = { profiles = { [0] = false } } })
    w = c.world
    check(w.press("R01", "Right", "recovery") == "R01", "a profile with the flow helper off")
    c.ticks(1)
    check(w.sloppy() == true and w.profiles[0] == true and c.S.flow.before["0"] == false and printed(c.ue, "changed in the game: flow helper on") ~= nil, "\"on\" switches it on; remembered: off")
    check(w.press("R01", "Right", "recovery") == "L01_NoCombo", "the mirrored follow-up swing is there")
    T.menuSet(c, "Combat", "Mirrored follow-up swings", 1)
    c.ticks(2)
    check(w.sloppy() == false and printed(c.ue, "changed in the game: flow helper as the game had it (off)") ~= nil, "back to game in the in-game menu: off again, as the game had it")
    stop(c)

    -- the game has it as wanted already: nothing is written, nothing remembered, nothing to put back
    c = start("flow-same", { config = OFF, game = { profiles = { [0] = false } } })
    w = c.world
    c.seconds(10)
    check(w.called("SetValue") == 0 and w.stores == 0 and next(c.S.flow.before) == nil and c.S.flow.value == false and printed(c.ue, "changed in the game") == nil,
        "the game has it off already: looked at, nothing set, nothing said")
    T.write(c.path, T.config('Config.FlowHelper = "game"'))
    c.ue:fireConsole("melee reload")
    c.seconds(10)
    check(w.sloppy() == false and w.called("SetValue") == 0, "back to game: there is nothing to put back, it stays off")
    -- the player changes it later, the module sets it back and remembers the player's value
    T.write(c.path, OFF)
    c.ue:fireConsole("melee reload")
    c.ticks(1)
    w.gameSets(true)
    c.seconds(3)
    check(w.sloppy() == false and c.S.flow.before["0"] == true, "a value the game gets later (the player's choice in its menu) is what is remembered then")
    T.write(c.path, T.config("Config.Enabled = false\nConfig.FlowHelper = \"off\""))
    c.ue:fireConsole("melee reload")
    c.ticks(1)
    check(w.sloppy() == true and printed(c.ue, "settings changed (config.lua): switched off in the settings") ~= nil, "the module switched off: the value is put back as well")
    stop(c)
end

-- Something keeps switching the option back (found in review: the module set it again at every look, without
-- end - a stored profile, a log line and a note every 3 seconds).
do
    local c = start("flow-fight", { config = OFF, diag = true, widgets = true })
    local ue, w, F = c.ue, c.world, c.S.flow
    c.ticks(1)
    check(w.sloppy() == false and w.stores == 1 and F.sets == 1 and F.again == 0, "set once at the first look")
    -- twice in a row, then it holds: the player in the game's menu, twice - nothing is given up
    for _ = 1, 2 do
        w.gameSets(true)
        c.seconds(3)
    end
    check(w.sloppy() == false and F.sets == 3 and F.again == 2 and F.off == nil, "switched back twice: set again twice, counted")
    c.seconds(3)
    check(F.again == 0 and F.sets == 3, "a look that finds it as set ends the count")
    -- now at every look
    for _ = 1, 5 do
        w.gameSets(true)
        c.seconds(3)
    end
    check(w.sloppy() == false and F.sets == 8 and F.again == 5 and F.off == nil, "switched back five times in a row: set again each time (5 is the limit, not yet past it)")
    local stores, lines, sets = w.stores, #ue.printed, w.called("SetValue")
    w.gameSets(true)
    c.seconds(3)
    check(w.sloppy() == true and w.called("SetValue") == sets and F.sets == 8 and F.off == "something keeps switching it back" and F.again == 0 and next(F.before) == nil,
        "the sixth time in a row it is left as the game has it: nothing is set, nothing is left to put back")
    check(#ue.printed == lines + 1 and printedCount(ue, "[G1R_Melee] the flow helper was switched back 5 times in a row right after the mod set it: it is left as the game has it now (on). Choosing FlowHelper anew tries again.\n") == 1,
        "one line says so")
    check(c.fake.value("melee.flow.way") == "none" and c.fake.detail("melee.flow.way") == "something keeps switching it back", "the diagnostics get it as the way in use: none, with the reason")
    stores = w.stores
    local calls = sum(w.calls)
    for _ = 1, 200 do
        w.gameSets(true)
        c.seconds(3)
    end
    check(sum(w.calls) == calls and w.stores == stores + 200 and #ue.printed == lines + 1 and w.sloppy() == true,
        "ten minutes of the same: the module does not look at the option any more - no call, no line (the 200 stores are the game's own)")
    check(has(status(c), "something keeps switching it back"), "the status names the reason: " .. status(c))
    -- back to "game": nothing to put back, nothing said about it
    T.write(c.path, T.config('Config.FlowHelper = "game"'))
    ue:fireConsole("melee reload")
    c.seconds(3)
    check(w.sloppy() == true and w.called("SetValue") == sets and printed(ue, "could not be put back") == nil and F.off == nil, "the setting back at game: nothing is written, no complaint - the game's value stands already")
    -- choosing it anew tries again
    T.write(c.path, OFF)
    ue:fireConsole("melee reload")
    c.ticks(1)
    check(w.sloppy() == false and w.called("SetValue") == sets + 1 and F.before["0"] == true and F.again == 0, "FlowHelper chosen anew: it is set again, and what the game had is remembered again")
    check(#ue.errors == 0 and w.escaped == 0, "no error")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("3. the flow helper is kept per profile")
do
    local c = start("profiles", { config = OFF, game = { profiles = { [0] = true, [1] = true, [2] = false } } })
    local ue, w, F = c.ue, c.world, c.S.flow
    c.ticks(1)
    check(w.profiles[0] == false and F.before["0"] == true, "profile 0: set to off, on remembered")
    -- another save, another profile: the game puts that profile's value in
    w.loadProfile(1)
    check(w.sloppy() == true, "the game applies profile 1: its value (on) is in the settings object")
    c.seconds(3)
    check(w.sloppy() == false and w.profiles[1] == false and F.before["1"] == true and F.before["0"] == true and F.sets == 2, "within 3 seconds it is off again; remembered per profile")
    w.loadProfile(2)
    c.seconds(3)
    check(w.sloppy() == false and F.before["2"] == nil and F.sets == 2, "profile 2 has it off already: nothing set, nothing remembered")
    -- back to "game" while profile 2 is in use: nothing of this profile to put back; the others cannot be reached
    T.write(c.path, T.config('Config.FlowHelper = "game"'))
    ue:fireConsole("melee reload")
    c.ticks(1)
    check(w.sloppy() == false and w.profiles[2] == false and F.backs == 0 and next(F.before) == nil, "back to game in profile 2: its value stays off (it was off)")
    check(printed(ue, "[G1R_Melee] the flow helper of profile 0 stays as the mod set it (the game had it on); the game's own menu changes it\n") ~= nil
        and printed(ue, "the flow helper of profile 1 stays as the mod set it (the game had it on)") ~= nil, "the two other profiles keep the mod's value: said, one line each")
    check(w.profiles[0] == false and w.profiles[1] == false and printed(ue, "changed in the game: flow helper as") == nil and w.called("SetValue") == 2
        and printed(ue, "could not be") == nil, "nothing is written for them, and nothing for the profile in use, which has nothing to put back")
    local calls = sum(w.calls)
    c.seconds(30)
    check(sum(w.calls) == calls, "then the module is idle")
    stop(c)

    -- back to "game" in the profile that was changed
    c = start("profiles-back", { config = OFF, game = { profiles = { [0] = true, [1] = false } } })
    w, F = c.world, c.S.flow
    c.ticks(1)
    w.loadProfile(1)
    c.seconds(3)
    w.loadProfile(0)
    c.seconds(3)
    check(w.sloppy() == false and F.sets == 1 and F.before["0"] == true and F.before["1"] == nil, "profile 0 changed, profile 1 visited (it had off), back in profile 0")
    T.write(c.path, T.config('Config.FlowHelper = "game"'))
    c.ue:fireConsole("melee reload")
    c.ticks(1)
    check(w.sloppy() == true and w.profiles[0] == true and w.profiles[1] == false and F.backs == 1, "back to game: profile 0 gets its own value back (on), profile 1 keeps its own (off)")
    stop(c)

    -- the profile cannot be told: one memory for whatever profile is in use
    c = start("no-profile", { config = OFF, game = { noProfiles = true }, diag = true })
    w, F = c.world, c.S.flow
    c.ticks(1)
    check(w.sloppy() == false and F.before["?"] == true and c.fake.value("melee.profile") == "not readable", "the profile subsystem is not found: the value is remembered all the same")
    T.write(c.path, T.config('Config.FlowHelper = "game"'))
    c.ue:fireConsole("melee reload")
    c.ticks(1)
    check(w.sloppy() == true and next(F.before) == nil and #c.ue.errors == 0, "and put back")
    stop(c)
    c = start("profile-odd", { config = OFF, diag = true })
    c.world.persistent.m_CurrentProfileId = "zero"
    c.ticks(1)
    check(c.world.sloppy() == false and c.S.flow.before["?"] == true, "a profile number that is not a number: the same")
    c.world.persistent.m_CurrentProfileId = 3.0
    c.world.gameSets(true)
    c.seconds(3)
    check(c.S.flow.before["3"] == true and c.fake.value("melee.profile") == 3, "a profile number arrives as a plain number: profile 3")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("4. the flow helper: the two ways of setting it, and what can go wrong")
do
    -- the option object does not exist: after three looks the settings object is used
    local c = start("no-option", { config = OFF, game = { noOption = true }, diag = true })
    local ue, w, F = c.ue, c.world, c.S.flow
    c.ticks(1)
    check(w.sloppy() == true and F.fails == 1 and printed(ue, "[G1R_Melee] the flow helper could not be read through the game's option object (the game's option object was not found)\n") ~= nil,
        "no option object: said, nothing set at the first look")
    c.seconds(6)
    check(w.sloppy() == true and F.direct == true and F.fails == 0 and printed(ue, "[G1R_Melee] from now on the flow helper is set in the game's settings object itself; the game does not store that value in the profile\n") ~= nil,
        "after three looks in vain the other way is taken: said")
    c.seconds(3)
    check(w.sloppy() == false and w.called("flag write") == 1 and w.called("GetGothicGameUserSettings") == 3 and w.stores == 0 and w.profiles[0] == true,
        "the value is written into the settings object: the fight code goes by it, the profile is not touched")
    check(w.press("R01", "Right", "recovery") == "R01", "the flow helper is off")
    check(F.way == "settings object" and c.fake.value("melee.flow.way") == "settings object" and c.fake.value("melee.flow.write") == "ok" and F.before["0"] == true, "noted: which way works")
    check(searched(ue, OPTION_PATH) == 1 and searched(ue, SETTINGS_PATH) == 1 and printedCount(ue, "could not be read through the game's option object") == 1,
        "the option object was searched for once, and the problem said once")
    c.seconds(30)
    check(searched(ue, OPTION_PATH) == 1 and searched(ue, SETTINGS_PATH) == 1 and w.called("flag write") == 1, "nothing is searched or written again")
    -- the game applies the profile (on): set again, this way
    w.loadProfile(0)
    c.seconds(3)
    check(w.sloppy() == false and w.called("flag write") == 2, "the game puts the profile's value in: written again")
    T.write(c.path, T.config('Config.FlowHelper = "game"'))
    ue:fireConsole("melee reload")
    c.ticks(1)
    check(w.sloppy() == true and w.called("flag write") == 3 and F.backs == 1, "back to game: put back the same way")
    check(#ue.errors == 0, "no error")
    stop(c)

    -- the ways the option object can fail
    for _, case in ipairs({
        { "GetValue raises", function(w2) w2.getValue = function() error("GetValue failed (test)") end end, "read", "GetValue failed (test)" },
        { "GetValue answers something that is no yes or no", function(w2) w2.getValue = function() return "yes" end end, "read", "GetValue answered yes" },
        { "SetValue raises", function(w2) w2.setValue = function() error("SetValue failed (test)") end end, "set", "SetValue failed (test)" },
        { "SetValue changes nothing", function(w2) w2.setValue = function() end end, "set", "the value did not stay" },
    }) do
        c = start("option-fails", { config = OFF, diag = true })
        w, F = c.world, c.S.flow
        case[2](w)
        c.ticks(1)
        check(w.sloppy() == true and F.fails == 1 and next(F.before) == nil
            and printed(c.ue, ("[G1R_Melee] the flow helper could not be %s through the game's option object (%s)\n"):format(case[3], case[4])) ~= nil,
            case[1] .. ": said with the reason, the game's value stays, nothing is remembered as changed")
        c.seconds(9)
        check(w.sloppy() == false and F.direct == true and w.called("flag write") == 1 and F.before["0"] == true and #c.ue.errors == 0,
            case[1] .. ": after three tries the settings object is used, and that works")
        check(printedCount(c.ue, "could not be " .. case[3] .. " through the game's option object") == 1, case[1] .. ": said once")
        if case[3] == "set" then check(c.fake.values("melee.flow.write")[1] == "failed" and c.fake.value("melee.flow.write") == "ok", case[1] .. ": noted failed, then ok") end
        stop(c)
    end

    -- the option object has no such functions (another build of the game)
    c = start("option-bare", { config = OFF, diag = true })
    w, F = c.world, c.S.flow
    c.ue.objects[OPTION_PATH].GetValue, c.ue.objects[OPTION_PATH].SetValue = nil, nil
    c.ticks(1)
    check(w.sloppy() == true and F.fails == 1 and printedCount(c.ue, "[G1R_Melee] the flow helper could not be read through the game's option object (attempt to call a nil value") == 1
        and #c.ue.errors == 0, "the option object has no GetValue: said with the reason, no error")
    c.seconds(9)
    check(w.sloppy() == false and F.direct == true and c.fake.value("melee.flow.way") == "settings object", "after three looks the settings object is used")
    stop(c)

    -- the option object is gone later (its wrapper is no longer valid)
    c = start("option-gone", { config = OFF, diag = true })
    w, F = c.world, c.S.flow
    c.ticks(1)
    c.ue.objects[OPTION_PATH].__valid = false
    w.gameSets(true)
    c.seconds(12)
    check(w.sloppy() == false and F.direct == true and w.called("SetValue") == 1 and w.called("flag write") == 1 and searched(c.ue, OPTION_PATH) == 1
        and printedCount(c.ue, "the flow helper could not be read through the game's option object (the game's option object was not found)") == 1,
        "the option object is gone later: not searched for again; after three looks the settings object is used")
    stop(c)

    -- FlowMethod = "option": only the game's own way; when it does not work the flow helper is left alone
    c = start("option-only", { config = T.config('Config.FlowHelper = "off"\nConfig.FlowMethod = "option"'), game = { noOption = true }, diag = true })
    w, F = c.world, c.S.flow
    c.seconds(6.25)
    check(w.sloppy() == true and F.off == "the game's option object was not found" and F.direct == false and w.called("GetGothicGameUserSettings") == 0,
        "FlowMethod = option: after three looks in vain the flow helper is left as the game has it; the settings object is not touched")
    check(printed(c.ue, "[G1R_Melee] the flow helper is left as the game has it: it cannot be set in this game (the game's option object was not found)\n") ~= nil
        and c.fake.value("melee.flow.way") == "none" and c.fake.detail("melee.flow.way") == "the game's option object was not found", "said and noted")
    local lookups, asked = #c.ue.lookups, sum(w.calls)
    c.seconds(30)
    check(#c.ue.lookups == lookups and sum(w.calls) == asked and w.called("GetValue") == 0, "nothing is tried again: the game is not looked at any more")
    check(has(status(c), "|flow helper: wanted off, but left as the game has it (the game's option object was not found)|")
        and has(status(c), "|nothing left to do: the game is not looked at|"), "the status says why")
    -- another way is chosen: tried anew
    T.write(c.path, T.config('Config.FlowHelper = "off"\nConfig.FlowMethod = "direct"'))
    c.ue:fireConsole("melee reload")
    c.ticks(1)
    check(w.sloppy() == false and F.off == nil and w.called("flag write") == 1, "FlowMethod changed to direct: tried anew, and set through the settings object at once")
    stop(c)

    -- FlowMethod = "direct" from the start
    c = start("direct", { config = T.config('Config.FlowHelper = "off"\nConfig.FlowMethod = "direct"'), diag = true })
    w, F = c.world, c.S.flow
    c.ticks(1)
    check(w.sloppy() == false and w.called("SetValue") == 0 and w.called("GetValue") == 0 and searched(c.ue, OPTION_PATH) == 0 and w.stores == 0 and w.profiles[0] == true,
        "FlowMethod = direct: the value is written into the settings object; the option object is not even searched for, the game stores nothing")
    check(w.called("flag read") == 2 and w.called("flag write") == 1 and c.fake.value("melee.flow.way") == "settings object", "read, written, read back")
    stop(c)

    -- the ways the settings object can fail: then nothing is left to try
    for _, case in ipairs({
        { "the settings class is not found", { noOption = true, noSettingsClass = true }, nil, "the game's settings class was not found", "read" },
        { "the game has no settings object", { noOption = true }, function(w2) w2.noSettingsObject = true end, "the game has no settings object", "read" },
        { "the settings class cannot say where the settings object is", { noOption = true }, function(w2) w2.getSettingsRaises = true end, "GetGothicGameUserSettings failed (test)", "read" },
        { "the value cannot be read", { noOption = true }, function(w2) w2.flagUnreadable = true end, "m_FakeSloppyCombos could not be read", "read" },
        { "the write raises", { noOption = true }, function(w2) w2.flagReadOnly = true end, "the write raised an error", "set" },
        { "the write does not stay", { noOption = true }, function(w2) w2.flagDeaf = true end, "the value did not stay", "set" },
    }) do
        c = start("direct-fails", { config = OFF, game = case[2], diag = true })
        w, F = c.world, c.S.flow
        if case[3] then case[3](w) end
        c.seconds(16)
        check(w.sloppy() == true and F.off == case[4] and next(F.before) == nil and #c.ue.errors == 0,
            case[1] .. ": after three tries of each way the flow helper is left alone, nothing is remembered as changed")
        check(printedCount(c.ue, ("the flow helper could not be %s through the game's settings object (%s)"):format(case[5], case[4])) == 1
            and printedCount(c.ue, "the flow helper is left as the game has it: it cannot be set in this game (" .. case[4] .. ")") == 1, case[1] .. ": each said once")
        local calls, lookups2 = sum(w.calls), #c.ue.lookups
        c.seconds(30)
        check(sum(w.calls) == calls and #c.ue.lookups == lookups2 and c.S.looks == 6, case[1] .. ": after these six looks the game is not looked at any more")
        stop(c)
    end

    -- a write whose result cannot be read back: what was remembered is kept (the value may have changed)
    c = start("blind", { config = T.config('Config.FlowHelper = "off"\nConfig.FlowMethod = "direct"') })
    w, F = c.world, c.S.flow
    local reads = 0
    c.ticks(0)
    w.flagUnreadable = false
    local plain = w.settings
    -- the second read (the read back) fails
    local meta = getmetatable(plain)
    local index = meta.__index
    meta.__index = function(t, k)
        if k == "m_FakeSloppyCombos" then
            reads = reads + 1
            if reads == 2 then return nil end
        end
        return index(t, k)
    end
    c.ticks(1)
    check(w.sloppy() == false and F.before["0"] == true and F.fails == 1, "the read back fails after a write that did happen: the game's earlier value stays remembered")
    c.seconds(3)
    check(F.fails == 0 and F.value == false and F.sets == 0, "at the next look the value is as wanted: nothing more to do")
    T.write(c.path, T.config('Config.FlowHelper = "game"\nConfig.FlowMethod = "direct"'))
    c.ue:fireConsole("melee reload")
    c.ticks(1)
    check(w.sloppy() == true, "and back to game puts the remembered value back")
    stop(c)

    -- putting back fails
    c = start("back-fails", { config = OFF })
    w, F = c.world, c.S.flow
    c.ticks(1)
    w.setValue = function() error("SetValue failed (test)") end
    w.flagReadOnly = true
    T.write(c.path, T.config('Config.FlowHelper = "game"'))
    c.ue:fireConsole("melee reload")
    c.seconds(20)
    check(w.sloppy() == false and next(F.before) == nil and F.backs == 0 and #c.ue.errors == 0 and w.called("SetValue") == 4 and w.called("flag write") == 3,
        "putting back fails both ways (three tries each): the value stays as set, the module lets go of it")
    check(printedCount(c.ue, "[G1R_Melee] the flow helper could not be put back through the game's option object (SetValue failed (test))\n") == 1
        and printedCount(c.ue, "the flow helper could not be put back through the game's settings object (the write raised an error)") == 1
        and printedCount(c.ue, "[G1R_Melee] the flow helper could not be put back to on (the write raised an error); the game's own menu changes it\n") == 1, "each step said once")
    local calls = sum(w.calls)
    c.seconds(30)
    check(sum(w.calls) == calls, "then the module is idle")
    stop(c)

    -- the value cannot be read when it is to be put back: nothing is written blindly
    c = start("back-unreadable", { config = OFF })
    w, F = c.world, c.S.flow
    c.ticks(1)
    w.getValue = function() error("GetValue failed (test)") end
    reload(c, 'Config.FlowHelper = "game"')
    c.seconds(6.25)
    check(w.sloppy() == false and w.called("SetValue") == 1 and F.direct == true
        and printedCount(c.ue, "[G1R_Melee] the flow helper could not be read through the game's option object (GetValue failed (test))\n") == 1,
        "the value cannot be read when it is to be put back: nothing is written; after three looks the settings object is used")
    c.seconds(3)
    check(w.sloppy() == true and w.called("flag write") == 1 and w.called("SetValue") == 1 and next(F.before) == nil and F.backs == 1, "and through that it is put back")
    stop(c)

    -- a later write fails while the value can be read: what was remembered at the first change stays
    c = start("later-fail", { config = OFF })
    w, F = c.world, c.S.flow
    c.ticks(1)
    w.gameSets(true)
    w.setValue = function() end
    c.seconds(3)
    check(w.sloppy() == true and F.before["0"] == true and F.fails == 1, "a later write does not stay: what the game had at the first change stays remembered")
    stop(c)

    -- which setting makes the module try again after it has given up
    c = start("retry", { config = T.config('Config.FlowHelper = "off"\nConfig.FlowMethod = "option"'), game = { noOption = true } })
    w, F = c.world, c.S.flow
    c.seconds(10)
    local looks = c.S.looks
    check(looks == 3 and F.off ~= nil, "given up after three looks")
    reload(c, 'Config.FlowHelper = "off"\nConfig.FlowMethod = "option"\nConfig.ShowMessage = false')
    c.seconds(10)
    check(c.S.looks == looks and F.off ~= nil, "another setting changes: not tried again")
    reload(c, 'Config.FlowHelper = "on"\nConfig.FlowMethod = "option"\nConfig.ShowMessage = false')
    c.seconds(10)
    check(c.S.looks == looks + 3 and F.off ~= nil, "the flow helper is set anew (off -> on): tried again for three looks, given up again")
    reload(c, 'Config.Enabled = false\nConfig.FlowHelper = "on"\nConfig.FlowMethod = "option"\nConfig.ShowMessage = false')
    c.seconds(4)
    check(c.S.looks == looks + 3 and F.off == nil, "the module is switched off: nothing to do")
    reload(c, 'Config.FlowHelper = "on"\nConfig.FlowMethod = "option"\nConfig.ShowMessage = false')
    c.seconds(10)
    check(c.S.looks == looks + 6 and F.off ~= nil, "and on again: tried again")
    stop(c)

    -- the fall-back stays in use until the way of setting is chosen anew
    c = start("fallback-stays", { config = OFF, game = { noOption = true } })
    w, F = c.world, c.S.flow
    c.seconds(10)
    check(w.sloppy() == false and F.direct == true, "the option object is missing: the settings object is in use")
    reload(c, 'Config.FlowHelper = "off"\nConfig.ShowMessage = false')
    w.gameSets(true)
    c.seconds(4)
    check(w.sloppy() == false and F.direct == true and F.fails == 0 and w.called("flag write") == 2, "another setting changes: the settings object stays in use")
    stop(c)
    c = start("method-auto", { config = T.config('Config.FlowHelper = "off"\nConfig.FlowMethod = "direct"') })
    w, F = c.world, c.S.flow
    c.ticks(1)
    w.gameSets(true)
    reload(c, 'Config.FlowHelper = "off"\nConfig.FlowMethod = "auto"')
    c.ticks(1)
    check(w.sloppy() == false and w.called("SetValue") == 1 and w.called("flag write") == 1 and F.direct == false and F.way == "option object",
        "FlowMethod from direct to auto: the game's own way is used again")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("5. hit stop: the game's freeze times, in percent")
do
    local c = start("stop-half", { config = HALF, diag = true, widgets = true })
    local ue, w, S = c.ue, c.world, c.S
    local b = w.blow("Standard")
    check(near(b.attacker, 0.05) and near(b.target, 0.05) and near(b.blend, 0.05) and untouched(w),
        "the game as it comes: a standard blow stops both fighters for 0.05 s and lets them pick up speed over 0.05 s")
    check(printed(ue, "[G1R_Melee] v1.0.0 loaded: hit stop 50 %\n") ~= nil and w.walks == 0 and #ue.lookups == 0, "the load line names what is asked for; loading does not look at the game")
    c.ticks(1)
    check(freezesAt(w, 0.5), "at the first look every freeze and blend-out time of both tables is half the game's; the time dilation is the game's")
    b = w.blow("Standard")
    check(near(b.attacker, 0.025) and near(b.target, 0.025) and near(b.blend, 0.025), "a standard blow now stops both fighters for 0.025 s")
    b = w.blow("Deflected")
    check(near(b.attacker, 0.0165) and near(b.target, 0.0165), "a deflected blow (the two tables change places): 0.0165 s")
    check(searched(ue, FEEDBACK_PATH) == 1 and w.called("table m_AttackFreezeParams") == 1 and w.called("table m_HitFreezeParams") == 1 and w.walks == 6,
        "one search for the feedback object; each table is read, written and read back: three walks each")
    check(w.fieldReads == 72 and w.fieldWrites == 24 and w.called("key") == 12 and w.called("key name") == 12,
        "72 values read, 24 written; the key of each entry is read once (its name goes to the diagnostics)")
    check(w.called("table m_AttackCameraShakeParams") == 0 and w.called("table m_HitCameraShakeParams") == 0 and w.called("set") == 0 and shakesAre(w, false),
        "the camera shake tables are not looked at")
    check(printedCount(ue, "[G1R_Melee] changed in the game: hit stop 50 %\n") == 1 and c.ui.note() == "Melee: hit stop 50 %", "one line in the log, one note on screen")
    check(S.written == 24 and S.putBack == 0 and S.count.m_AttackFreezeParams == 6 and S.count.m_HitFreezeParams == 6 and S.feedback == "GenericMeleeFeedback " .. FEEDBACK_PATH,
        "the module holds: 24 values written, 6 entries per table, the object's name")
    local lines = c.hook.status()
    check(#lines == 5 and lines[1] == "v1.0.0 | hit stop 50 %" and lines[2] == "flow helper: left to the game" and lines[3] == "hit stop: 50 % of the game's in 12 of 12 entries"
        and lines[4] == "camera shake on hits: as the game has it"
        and lines[5] == "changes: 1 (last: hit stop 50 %); flow helper set 0 time(s), put back 0; table values written 24, put back 0; looks 1 (0 while paused)",
        "the status: " .. table.concat(lines, " | "))
    check(c.fake.value("melee.feedback") == "found" and c.fake.value("melee.stop.attack") == 6 and c.fake.value("melee.stop.hit") == 6 and c.fake.value("melee.stop.write") == "ok",
        "noted: the object, the entries of each table, the write")
    check(c.fake.detail("melee.stop.attack") == "Additive 0.033/0.033, Standard 0.05/0.05, Knockback 0.05/0.033, Parried 0.05/0.05, Deflected 0.033/0.033, Dot 0.033/0.033"
        and c.fake.detail("melee.stop.hit") == "Additive 0.033/0.033, Standard 0.05/0.05, Knockback 0.05/0.05, Parried 0.05/0.05, Deflected 0.033/0.033, Dot 0.033/0.033",
        "the notes say what the game had in each entry: " .. tostring(c.fake.detail("melee.stop.attack")))

    -- the minute after
    local reads, walks, lookups = w.fieldReads, w.walks, #ue.lookups
    c.seconds(60)
    check(S.looks == 21 and w.walks == walks + 4 and w.fieldReads == reads + 48 and w.fieldWrites == 24 and #ue.lookups == lookups,
        "in the minute after: 20 looks; the tables are read again every 30 seconds (one walk and 12 values each), nothing is written, nothing searched")
    check(freezesAt(w, 0.5) and printedCount(ue, "changed in the game") == 1 and w.called("key") == 12, "the values stay half the game's: nothing is halved twice; the keys are not read again")

    -- the game puts a value back to its own; later another one gets a value from elsewhere
    w.setFreeze("m_HitFreezeParams", "Standard", 0.05)
    c.seconds(29.75)
    check(near(w.freeze("m_HitFreezeParams", "Standard"), 0.05), "a value the game puts back to its own stays until the tables are read again")
    c.ticks(1)
    check(freezesAt(w, 0.5) and S.written == 25 and w.fieldWrites == 25 and printedCount(ue, "changed in the game: hit stop 50 %") == 2,
        "then it is half the game's again - worked out from the value remembered, not from the one found; said again")
    w.setFreeze("m_AttackFreezeParams", "Dot", 0.2)
    c.seconds(30)
    check(freezesAt(w, 0.5) and S.written == 26 and printedCount(ue, "changed in the game: hit stop 50 %") == 3, "so is a value that came from elsewhere")

    -- other percentages, each worked out from what the game had
    reload(c, "Config.HitStop = 200")
    check(freezesAt(w, 0.5) and printed(ue, "[G1R_Melee] settings changed (config.lua): hit stop 200 %\n") ~= nil, "the setting changes: nothing happens inside the settings callback")
    c.ticks(1)
    b = w.blow("Standard")
    check(freezesAt(w, 2) and near(b.attacker, 0.1) and near(b.blend, 0.1) and printed(ue, "changed in the game: hit stop 200 %") ~= nil and c.ui.note() == "Melee: hit stop 200 %",
        "200: twice the game's own times at the next turn of the loop")
    reload(c, "Config.HitStop = 0")
    c.ticks(1)
    b = w.blow("Standard")
    check(freezesAt(w, 0) and b.attacker == 0 and b.target == 0 and w.blow("Dot").target == 0 and #w.tables.m_HitFreezeParams.entries == 6,
        "0: nobody is stopped (the game's script skips a stop of no length); the entries are still there")
    reload(c, "Config.HitStop = 50")
    c.ticks(1)
    check(freezesAt(w, 0.5), "from 0 to 50: half the game's times (the remembered ones, not half of nothing)")
    reload(c, "Config.HitStop = 300")
    c.ticks(1)
    check(freezesAt(w, 3) and near(w.blow("Knockback").attacker, 0.15), "300: three times")

    -- back to 100
    local written = w.fieldWrites
    reload(c, "Config.HitStop = 100")
    c.ticks(1)
    check(untouched(w) and next(S.mem) == nil and S.putBack == 24 and w.fieldWrites == written + 24, "100: the very numbers the game had are back; nothing is remembered any more")
    check(printed(ue, "[G1R_Melee] changed in the game: hit stop as the game has it\n") ~= nil and c.ui.note() == "Melee: hit stop as the game has it", "said in the log and on screen")
    local calls
    calls, walks = sum(w.calls), w.walks
    c.seconds(60)
    check(sum(w.calls) == calls and w.walks == walks and has(status(c), "|nothing to change: the game is not looked at|"), "after that the game is not looked at any more")
    check(#ue.errors == 0 and w.escaped == 0 and searched(ue, FEEDBACK_PATH) == 1, "no error; the object was searched for once in all of this")
    stop(c)

    -- the game has no stop in some entries: nothing to write there
    c = start("stop-zero", { config = HALF })
    w = c.world
    w.setFreeze("m_HitFreezeParams", "Dot", 0)
    w.setFreeze("m_AttackFreezeParams", "Dot", 0)
    c.ticks(1)
    check(w.fieldWrites == 22 and w.freeze("m_HitFreezeParams", "Dot") == 0 and near(w.freeze("m_HitFreezeParams", "Standard"), 0.025), "a time of 0 stays 0 and is not written")
    stop(c)
    c = start("stop-all-zero", { config = HALF, diag = true })
    w = c.world
    for _, name in ipairs(FREEZE_TABLES) do
        for _, row in ipairs(FREEZES) do w.setFreeze(name, row[1]:match("([^%.]+)$"), 0, 0) end
    end
    c.ticks(1)
    check(w.fieldWrites == 0 and w.walks == 2 and c.fake.value("melee.stop.attack") == 6 and c.fake.value("melee.stop.write") == nil and printed(c.ue, "changed in the game") == nil
        and has(status(c), "|hit stop: 50 % of the game's in 12 of 12 entries|"), "a game without any hit stop: nothing to write, no change announced, no write noted")
    stop(c)
    c = start("stop-one", { config = HALF, diag = true })
    w = c.world
    for _, name in ipairs(FREEZE_TABLES) do
        for _, row in ipairs(FREEZES) do w.setFreeze(name, row[1]:match("([^%.]+)$"), 0, 0) end
    end
    w.setFreeze("m_HitFreezeParams", "Standard", 0.05, 0)
    c.ticks(1)
    check(w.fieldWrites == 1 and near(w.freeze("m_HitFreezeParams", "Standard"), 0.025) and c.fake.value("melee.stop.write") == "ok"
        and printedCount(c.ue, "[G1R_Melee] changed in the game: hit stop 50 %\n") == 1, "a game with a single hit stop value: that one is written, noted and announced")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("6. camera shake when a melee blow lands")
do
    local c = start("shake-off", { config = NOSHAKE, diag = true, widgets = true })
    local ue, w, S = c.ue, c.world, c.S
    local b = w.blow("Standard")
    check(b.shake == "MatineeCameraShake_Combat_Standard" and b.hitShake == "MatineeCameraShake_Combat_Standard" and w.blow("Deflected").hitShake == "MatineeCameraShake_None",
        "the game as it comes: a standard blow shakes the camera of the one who strikes and of the one who is hit; some kinds of blow name the class for no shake")
    check(printed(ue, "[G1R_Melee] v1.0.0 loaded: no camera shake on hits\n") ~= nil, "the load line names what is asked for")
    c.ticks(1)
    b = w.blow("Standard")
    check(shakesAre(w, true) and b.shake == "MatineeCameraShake_None" and b.hitShake == "MatineeCameraShake_None" and w.blow("Parried").shake == "MatineeCameraShake_None",
        "at the first look every entry of both tables names the game's class for no shake")
    check(w.called("set") == 10 and S.written == 10, "ten entries were changed; the three that named that class already were not")
    check(w.walks == 7 and w.called("table m_AttackCameraShakeParams") == 2 and w.called("table m_HitCameraShakeParams") == 1,
        "one walk to find that class in the first table, then each table is read, written and read back")
    check(searched(ue, FEEDBACK_PATH) == 1 and searched(ue, NONE_PATH) == 0 and S.none.from == "from the table" and S.none.name == "MatineeCameraShake_None",
        "the class is taken from the table itself: no search for it")
    check(c.fake.value("melee.shake.none_class") == "from the table" and c.fake.value("melee.shake.attack") == 7 and c.fake.value("melee.shake.hit") == 6 and c.fake.value("melee.shake.write") == "ok",
        "noted: where the class is from, the entries of each table, the write")
    check(c.fake.detail("melee.shake.attack") == "MeatBug SmashMeatBug, Additive Combat_Additive, Standard Combat_Standard, Knockback Combat_Standard, Parried Combat_Parried, Deflected Combat_Deflected, Dot None"
        and c.fake.detail("melee.shake.hit") == "Additive Combat_Additive, Standard Combat_Standard, Knockback Combat_Standard, Parried Combat_Parried, Deflected None, Dot None",
        "the notes say which class the game had in each entry (without the common start of their names): " .. tostring(c.fake.detail("melee.shake.hit")))
    check(w.fieldReads == 0 and w.fieldWrites == 0 and w.called("table m_AttackFreezeParams") == 0 and freezesAt(w, 1, true), "the freeze tables are not looked at")
    check(printedCount(ue, "[G1R_Melee] changed in the game: no camera shake on hits\n") == 1 and c.ui.note() == "Melee: no camera shake on hits" and printed(ue, "stays as the game has it") == nil,
        "one line in the log, one note on screen")
    local lines = c.hook.status()
    check(#lines == 5 and lines[1] == "v1.0.0 | no camera shake on hits" and lines[3] == "hit stop: as the game has it" and lines[4] == "camera shake on hits: none in 13 of 13 entries"
        and lines[5] == "changes: 1 (last: no camera shake on hits); flow helper set 0 time(s), put back 0; table values written 10, put back 0; looks 1 (0 while paused)",
        "the status: " .. table.concat(lines, " | "))

    local walks, lookups = w.walks, #ue.lookups
    c.seconds(60)
    check(w.walks == walks + 4 and w.called("set") == 10 and #ue.lookups == lookups and w.called("key") == 13, "in the minute after: the two tables are read again every 30 seconds, nothing is set, nothing searched")
    -- the game puts a class back
    w.tables.m_HitCameraShakeParams.entries[2].value = w.classes.MatineeCameraShake_Combat_Standard
    c.seconds(30)
    check(shakesAre(w, true) and w.called("set") == 11 and printedCount(ue, "changed in the game: no camera shake on hits") == 2, "an entry the game sets back to its own class is set again when the tables are read next")

    -- back on
    reload(c, "Config.HitShake = true")
    c.ticks(1)
    check(shakesAre(w, false) and w.called("set") == 21 and next(S.mem) == nil and S.putBack == 10, "back on: the ten entries name their own classes again; nothing is remembered any more")
    check(printed(ue, "[G1R_Melee] changed in the game: camera shake on hits as the game has it\n") ~= nil and c.ui.note() == "Melee: camera shake on hits as the game has it", "said in the log and on screen")
    local calls
    calls, walks = sum(w.calls), w.walks
    c.seconds(60)
    check(sum(w.calls) == calls and w.walks == walks and has(status(c), "|nothing to change: the game is not looked at|"), "after that the game is not looked at any more")
    -- off again: the class is known, the tables are not searched for it a second time
    reload(c, "Config.HitShake = false")
    c.ticks(1)
    check(shakesAre(w, true) and w.walks == walks + 6 and w.called("set") == 31, "off again: three walks per table - the class for no shake is still known")
    check(#ue.errors == 0 and w.escaped == 0, "no error")
    stop(c)

    -- a game whose tables do not name the class for no shake: it is found by its name
    c = start("shake-plain", { config = NOSHAKE, game = { plainShakes = true }, diag = true })
    ue, w, S = c.ue, c.world, c.S
    check(shakesAre(w, false, true), "a game in which no entry names the class for no shake")
    c.ticks(1)
    check(shakesAre(w, true) and w.called("set") == 13 and searched(ue, NONE_PATH) == 1 and S.none.from == "by name" and c.fake.value("melee.shake.none_class") == "by name",
        "the class is searched for by its name, once; all 13 entries are changed")
    check(w.walks == 8, "two walks in vain for the class, then three per table")
    reload(c, "Config.HitShake = true")
    c.ticks(1)
    reload(c, "Config.HitShake = false")
    c.ticks(1)
    check(shakesAre(w, true) and searched(ue, NONE_PATH) == 1, "on and off again: not searched a second time")
    -- the wrapper of that class goes stale: the shake is put back and left alone
    local saidBack = printedCount(ue, "changed in the game: camera shake on hits as the game has it")
    w.classes.MatineeCameraShake_None.__valid = false
    c.seconds(30)
    check(shakesAre(w, false, true) and S.none == false and next(S.mem) == nil, "the class is gone when the tables are read next: every entry gets its own class back")
    check(printedCount(ue, "[G1R_Melee] camera shake on hits stays as the game has it: the game's class for no shake (MatineeCameraShake_None) was not found\n") == 1
        and printedCount(ue, "changed in the game: camera shake on hits as the game has it") == saidBack and c.fake.value("melee.shake.none_class") == "gone",
        "said once, as a problem and not as a change; noted")
    local calls2, walks2 = sum(w.calls), w.walks
    c.seconds(60)
    check(sum(w.calls) == calls2 and w.walks == walks2 and has(status(c), "|camera shake on hits: wanted none, but left as the game has it (the game's class for no shake (MatineeCameraShake_None) was not found)|")
        and has(status(c), "|nothing left to do: the game is not looked at|"), "then the game is not looked at any more; the status says why")
    check(#ue.errors == 0 and w.escaped == 0, "no error")
    stop(c)

    -- the class cannot be found at all
    c = start("shake-no-class", { config = NOSHAKE, game = { plainShakes = true, noNoneClass = true }, diag = true })
    ue, w, S = c.ue, c.world, c.S
    c.ticks(1)
    check(shakesAre(w, false, true) and w.called("set") == 0 and S.none == false and c.fake.value("melee.shake.none_class") == "not found" and searched(ue, NONE_PATH) == 1,
        "no class for no shake, neither in the tables nor by name: nothing is changed; noted")
    check(printedCount(ue, "camera shake on hits stays as the game has it: the game's class for no shake (MatineeCameraShake_None) was not found") == 1 and w.walks == 2, "said once; two walks")
    local lookups2 = #ue.lookups
    calls2, walks2 = sum(w.calls), w.walks
    c.seconds(60)
    check(sum(w.calls) == calls2 and w.walks == walks2 and #ue.lookups == lookups2, "then the game is not looked at any more")
    reload(c, "Config.HitShake = true")
    c.ticks(1)
    reload(c, "Config.HitShake = false")
    c.seconds(10)
    check(searched(ue, NONE_PATH) == 1 and w.walks == walks2 + 2 and w.called("set") == 0
        and printedCount(ue, "camera shake on hits stays as the game has it") == 1, "the setting is set anew: the tables are looked through again, the name is not searched again, nothing is said twice")
    reload(c, "Config.Enabled = false\nConfig.HitShake = false")
    c.ticks(1)
    reload(c, "Config.HitShake = false")
    c.seconds(10)
    check(searched(ue, NONE_PATH) == 1 and w.walks == walks2 + 4 and S.none == false, "the module is switched off and on: looked through again as well")
    stop(c)

    -- the wrapper of that class names another object later (a new object at the same address)
    c = start("shake-stale", { config = NOSHAKE, game = { plainShakes = true }, diag = true })
    w, S = c.world, c.S
    c.ticks(1)
    w.classes.MatineeCameraShake_None.__full = "Class /Script/Angelscript.SomethingElse"
    c.seconds(30)
    check(shakesAre(w, false, true) and S.none == false and next(S.mem) == nil and c.fake.value("melee.shake.none_class") == "gone",
        "the wrapper of the class for no shake names another object when the tables are read next: treated as gone, every entry gets its own class back")
    stop(c)

    -- the hit stop is in hand while the class for no shake does not exist: the hit stop is looked after as usual
    c = start("no-class-busy", { config = T.config("Config.HitStop = 50\nConfig.HitShake = false"), game = { plainShakes = true, noNoneClass = true } })
    w = c.world
    c.seconds(61)
    check(freezesAt(w, 0.5) and shakesAre(w, false, true) and w.walks == 6 + 2 + 4 and printed(c.ue, "update error") == nil and #c.ue.errors == 0,
        "the hit stop is set while the class for no shake cannot be found: the tables of the hit stop are read every 30 seconds, the class is not looked for again")
    reload(c, "Config.HitStop = 50\nConfig.HitShake = false\nConfig.ShowMessage = false")
    c.ticks(1)
    check(w.walks == 12 + 2 and c.S.none == false, "another setting changes: the hit stop tables are read at once, the class is not looked for again")
    reload(c, "Config.Enabled = false\nConfig.HitStop = 50\nConfig.HitShake = false\nConfig.ShowMessage = false")
    c.ticks(1)
    check(shakesAre(w, false, true) and freezesAt(w, 1, true), "the module is switched off: the hit stop is put back")
    local walks3 = w.walks
    reload(c, "Config.HitStop = 50\nConfig.HitShake = false\nConfig.ShowMessage = false")
    c.ticks(1)
    check(w.walks == walks3 + 6 + 2 and freezesAt(w, 0.5), "and on again: the class is looked for again (two walks), the hit stop is set again")
    stop(c)

    -- an entry that names no class at all is left as it is
    c = start("shake-null", { config = NOSHAKE, diag = true })
    w = c.world
    local null = c.ue:invalid()
    w.tables.m_HitCameraShakeParams.entries[1].value = null
    c.ticks(1)
    check(w.tables.m_HitCameraShakeParams.entries[1].value == null and w.called("set") == 9 and c.fake.value("melee.shake.hit") == 6
        and has(c.fake.detail("melee.shake.hit"), "Additive no class, Standard Combat_Standard,"), "an entry that names no class is not written to; the note says so")
    reload(c, "Config.HitShake = true")
    c.ticks(1)
    check(w.tables.m_HitCameraShakeParams.entries[1].value == null and w.called("set") == 18 and w.shake("m_HitCameraShakeParams", "Standard") == "MatineeCameraShake_Combat_Standard",
        "and not when the shake is switched back on")
    stop(c)

    -- the class has the U of its script name
    c = start("shake-u", { config = NOSHAKE, game = { noneName = "UMatineeCameraShake_None" } })
    w = c.world
    c.ticks(1)
    check(shakesAre(w, true, false, "UMatineeCameraShake_None") and w.called("set") == 10 and c.S.none.name == "UMatineeCameraShake_None" and searched(c.ue, NONE_PATH) == 0,
        "a class object named with the U of the script class is recognised in the table as well")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("7. tables that cannot be read, written or read back: the game's values stay, one line, then nothing")
do
    local BOTH = T.config("Config.HitStop = 50\nConfig.HitShake = false")
    -- the hit stop tables. Each case: what is wrong in the game, the table and the reason the module names,
    -- walks through tables, write attempts, values written / put back.
    for _, case in ipairs({
        { "the first table cannot be read", function(w) w.tableMissing = "m_AttackFreezeParams" end, "m_AttackFreezeParams", "the table could not be read", 0, 0, 0, 0 },
        { "the second table cannot be read", function(w) w.tableMissing = "m_HitFreezeParams" end, "m_HitFreezeParams", "the table could not be read", 6, 24, 12, 12 },
        { "the walk raises an error", function(w) w.mapRaises = "m_AttackFreezeParams" end, "m_AttackFreezeParams", "ForEach of m_AttackFreezeParams failed (test)", 1, 0, 0, 0 },
        { "the walk of the second table raises an error", function(w) w.mapRaises = "m_HitFreezeParams" end, "m_HitFreezeParams", "ForEach of m_HitFreezeParams failed (test)", 7, 24, 12, 12 },
        { "the walk visits nothing", function(w) w.emptyMap = "m_AttackFreezeParams" end, "m_AttackFreezeParams", "the table is empty", 1, 0, 0, 0 },
        { "the values of the entries are not handed out", function(w) w.valueNil = "m_AttackFreezeParams" end, "m_AttackFreezeParams", "m_FreezeDuration of an entry is not a number", 1, 0, 0, 0 },
        { "one of the two numbers cannot be read", function(w) w.fieldUnreadable = "m_BlendOutDuration" end, "m_AttackFreezeParams", "m_BlendOutDuration of an entry is not a number", 1, 0, 0, 0 },
        { "writing raises an error", function(w) w.fieldRaises = true end, "m_AttackFreezeParams", "the property could not be written (test)", 4, 6, 0, 0 },
        { "what is written does not stay", function(w) w.fieldDeaf = true end, "m_AttackFreezeParams", "12 of 12 values did not stay", 5, 12, 0, 0 },
        { "one of the two numbers does not stay", function(w) w.fieldDeaf = "m_BlendOutDuration" end, "m_AttackFreezeParams", "6 of 12 values did not stay", 5, 18, 0, 0 },
        { "the entries are handed out as copies", function(w) w.copies = true end, "m_AttackFreezeParams", "12 of 12 values did not stay", 5, 12, 0, 0 },
        { "the walk that reads back fails", function(w) w.mapRaisesOn = { name = "m_AttackFreezeParams", walk = 3 } end, "m_AttackFreezeParams", "ForEach of m_AttackFreezeParams failed (test)", 5, 24, 0, 0 },
    }) do
        local c = start("stop-fails", { config = HALF, diag = true })
        local ue, w, S = c.ue, c.world, c.S
        case[2](w)
        c.ticks(1)
        local line = ("[G1R_Melee] hit stop stays as the game has it: the game's table %s could not be changed (%s); it is as the game had it\n"):format(case[3], case[4])
        check(untouched(w) and near(w.blow("Standard").attacker, 0.05), case[1] .. ": the game has its own values")
        check(printedCount(ue, line) == 1 and printed(ue, "changed in the game") == nil, case[1] .. ": said in one line, with the table and the reason; no change is announced")
        check(c.fake.value("melee.stop.write") == "failed" and c.fake.detail("melee.stop.write") == case[3] .. ": " .. case[4], case[1] .. ": noted")
        check(w.walks == case[5] and w.fieldWrites == case[6] and S.written == case[7] and S.putBack == case[8],
            ("%s: %d walks, %d writes tried (%d / %d)"):format(case[1], w.walks, w.fieldWrites, S.written, S.putBack))
        check(next(S.mem) == nil and S.broken[case[3]] == case[4] and w.escaped == 0 and #ue.errors == 0, case[1] .. ": nothing is remembered as changed; no error leaves a walk")
        local calls, walks, lookups = sum(w.calls), w.walks, #ue.lookups
        c.seconds(60)
        check(sum(w.calls) == calls and w.walks == walks and #ue.lookups == lookups and printedCount(ue, "could not be changed") == 1, case[1] .. ": then the game is not looked at any more")
        check(has(status(c), ("|hit stop: wanted 50 %% of the game's, but left as the game has it (%s: %s)|"):format(case[3], case[4]))
            and has(status(c), "|nothing left to do: the game is not looked at|"), case[1] .. ": the status says why")
        stop(c)
    end

    -- the setting is changed: tried anew - in vain while the problem is there, with success when it is gone
    local c = start("stop-again", { config = HALF, diag = true })
    local ue, w, S = c.ue, c.world, c.S
    w.fieldDeaf = true
    c.ticks(1)
    reload(c, "Config.HitStop = 60")
    c.ticks(1)
    check(untouched(w) and w.walks == 10 and printedCount(ue, "hit stop stays as the game has it") == 1 and S.broken.m_AttackFreezeParams ~= nil,
        "the setting is changed while the problem is there: tried once more, left alone again, not said twice")
    local walks = w.walks
    c.seconds(30)
    check(w.walks == walks, "and not tried again by itself")
    w.fieldDeaf = nil
    reload(c, "Config.HitStop = 70")
    c.ticks(1)
    check(freezesAt(w, 0.7) and next(S.broken) == nil and c.fake.value("melee.stop.write") == "ok" and printed(ue, "changed in the game: hit stop 70 %") ~= nil,
        "the problem is gone and the setting is changed: it works")
    check(table.concat(c.fake.values("melee.stop.write"), " ") == "failed ok", "noted: failed, then ok")
    stop(c)

    -- which setting makes a kind be tried again
    c = start("retry-kinds", { config = BOTH })
    ue, w, S = c.ue, c.world, c.S
    w.fieldDeaf, w.setDeaf = true, true
    c.ticks(1)
    local function walked() return w.called("ForEach m_AttackFreezeParams"), w.called("ForEach m_AttackCameraShakeParams") end
    local stopWalks, shakeWalks = walked()
    check(stopWalks == 5 and shakeWalks == 6 and S.broken.m_AttackFreezeParams ~= nil and S.broken.m_AttackCameraShakeParams ~= nil, "neither kind can be written: both are left alone")
    reload(c, "Config.HitStop = 50\nConfig.HitShake = false\nConfig.ShowMessage = false")
    c.seconds(4)
    local a, b = walked()
    check(a == stopWalks and b == shakeWalks, "another setting changes: neither is tried again")
    reload(c, "Config.HitStop = 60\nConfig.HitShake = false\nConfig.ShowMessage = false")
    c.seconds(4)
    a, b = walked()
    check(a == stopWalks + 5 and b == shakeWalks, "the hit stop setting changes: the hit stop is tried again, the camera shake is not")
    reload(c, "Config.HitStop = 60\nConfig.HitShake = true\nConfig.ShowMessage = false")
    c.ticks(1)
    reload(c, "Config.HitStop = 60\nConfig.HitShake = false\nConfig.ShowMessage = false")
    c.seconds(4)
    a, b = walked()
    check(a == stopWalks + 5 and b == shakeWalks + 5, "the camera shake setting changes: the camera shake is tried again, the hit stop is not")
    reload(c, "Config.Enabled = false\nConfig.HitStop = 60\nConfig.HitShake = false\nConfig.ShowMessage = false")
    c.ticks(1)
    reload(c, "Config.HitStop = 60\nConfig.HitShake = false\nConfig.ShowMessage = false")
    c.seconds(4)
    a, b = walked()
    check(a == stopWalks + 10 and b == shakeWalks + 10 and untouched(w) and printedCount(ue, "stays as the game has it") == 2 and #ue.errors == 0,
        "the module is switched off and on: both are tried again; all of it said once per kind")
    stop(c)

    -- the keys of the entries: read for the note only; when they cannot be read the entries are numbered
    for _, case in ipairs({
        { "the keys cannot be read", function(w) w.keysUnreadable = true end, "#1 0.033/0.033, #2 0.05/0.05, #3 0.05/0.033," },
        { "the name of a key cannot be turned into text", function(w) w.keyTextRaises = true end, "#1 0.033/0.033, #2 0.05/0.05," },
        { "the text of a key is no text", function(w) w.keyText = 5 end, "#1 0.033/0.033, #2 0.05/0.05," },
        { "the keys are empty tags", function(w) w.keyText = "None" end, "#1 0.033/0.033, #2 0.05/0.05," },
        { "the keys have no name", function(w) w.keyText = "" end, "#1 0.033/0.033, #2 0.05/0.05," },
        { "the names of the keys arrive as plain text", function(w) w.keyNamePlain = true end, "Additive 0.033/0.033, Standard 0.05/0.05, Knockback 0.05/0.033," },
    }) do
        c = start("stop-keys", { config = HALF, diag = true })
        case[2](c.world)
        c.ticks(1)
        check(freezesAt(c.world, 0.5) and has(c.fake.detail("melee.stop.attack"), case[3]) and c.world.escaped == 0 and c.fake.value("melee.stop.write") == "ok",
            case[1] .. ": the values are changed all the same; the note says: " .. tostring(c.fake.detail("melee.stop.attack")):sub(1, 40))
        stop(c)
    end

    -- writing stops working later, and the game puts a value back: the tables cannot be put back either
    c = start("stop-deaf-later", { config = HALF, diag = true })
    ue, w, S = c.ue, c.world, c.S
    c.ticks(1)
    w.fieldDeaf = true
    w.setFreeze("m_AttackFreezeParams", "Standard", 0.05)
    c.seconds(30)
    check(S.mem.m_AttackFreezeParams ~= nil and S.mem.m_HitFreezeParams ~= nil and freezesAt(w, 0.5, false, "m_HitFreezeParams") and w.escaped == 0 and #ue.errors == 0,
        "what is written no longer stays when the tables are read again: the mod's values are still in the game, and the module knows it")
    check(w.fieldWrites == 24 + 1 + 11 + 12 + 12, "one try to set the value again, one try per table to put everything back - no more")
    check(printedCount(ue, "[G1R_Melee] hit stop: the game's table m_AttackFreezeParams could not be put back as the game had it (1 of 1 values did not stay); "
        .. "values of the mod may still be in it - restart the game to be safe\n") == 1
        and printedCount(ue, "hit stop: the game's table m_HitFreezeParams could not be put back as the game had it (12 of 12 values did not stay)") == 1
        and printed(ue, "it is as the game had it") == nil, "said for each table, with the advice to restart the game")
    check(has(status(c), "|hit stop: values of the mod may still be in the game (m_AttackFreezeParams: 1 of 1 values did not stay) - restart the game to be safe|")
        and has(status(c), "|nothing left to do: the game is not looked at|"), "the status keeps saying so")
    stop(c)

    -- a table changes its shape after it was changed: nothing is written by position any more
    c = start("stop-grows", { config = HALF, diag = true })
    ue, w, S = c.ue, c.world, c.S
    c.ticks(1)
    w.growing = "m_AttackFreezeParams"
    c.seconds(30)
    check(near(w.freeze("m_AttackFreezeParams", "Standard"), 0.025) and w.fieldWrites == 24 + 12 and S.mem.m_AttackFreezeParams ~= nil and S.mem.m_HitFreezeParams == nil,
        "a table has one entry more when it is read again: nothing is written into it; the other table gets the game's values back")
    check(freezesAt(w, 1, true, "m_HitFreezeParams") and freezesAt(w, 0.5, false, "m_AttackFreezeParams"), "the other table has the very numbers of the game; the one that grew is as it was left")
    check(printedCount(ue, "[G1R_Melee] hit stop: the game's table m_AttackFreezeParams could not be put back as the game had it (the table has more entries than before); "
        .. "values of the mod may still be in it - restart the game to be safe\n") == 1 and w.escaped == 0 and #ue.errors == 0, "said, with the advice to restart the game")
    check(has(status(c), "|hit stop: values of the mod may still be in the game (m_AttackFreezeParams: the table has more entries than before) - restart the game to be safe|")
        and has(status(c), "|nothing left to do: the game is not looked at|"), "the status keeps saying so")
    local calls
    calls, walks = sum(w.calls), w.walks
    c.seconds(60)
    check(sum(w.calls) == calls and w.walks == walks, "then the game is not looked at any more")
    stop(c)

    c = start("stop-shrinks", { config = HALF, diag = true })
    ue, w, S = c.ue, c.world, c.S
    c.ticks(1)
    w.vanishing = "m_HitFreezeParams"
    c.seconds(30)
    check(near(w.freeze("m_HitFreezeParams", "Standard"), 0.025) and w.freeze("m_AttackFreezeParams", "Standard") == f32(0.05) and S.mem.m_HitFreezeParams ~= nil and w.fieldWrites == 24 + 12,
        "a table has one entry less when it is read again: nothing is written into it; the other table gets the game's values back")
    check(printedCount(ue, "hit stop: the game's table m_HitFreezeParams could not be put back as the game had it (the table has 5 entries where it had 6); values of the mod may still be in it") == 1,
        "said, with the numbers")
    -- the table has its old shape again and the setting is changed: the values are put back
    w.vanishing = nil
    reload(c, "Config.HitStop = 100")
    c.ticks(1)
    check(untouched(w) and next(S.mem) == nil and next(S.broken) == nil and printed(ue, "changed in the game: hit stop as the game has it") ~= nil and w.escaped == 0,
        "the table has its shape again and the setting is changed: the game's values are put back")
    stop(c)

    -- the camera shake tables
    for _, case in ipairs({
        { "setting a class raises an error", function(w) w.setRaises = true end, "m_AttackCameraShakeParams", "the value could not be set (test)", 5, 6 },
        { "a class that is set does not stay", function(w) w.setDeaf = true end, "m_AttackCameraShakeParams", "6 of 6 values did not stay", 6, 6 },
        { "the values of the entries are not handed out", function(w) w.valueNil = "m_AttackCameraShakeParams" end, "m_AttackCameraShakeParams", "no entry names a class", 3, 0 },
        { "the walk visits nothing", function(w) w.emptyMap = "m_AttackCameraShakeParams" end, "m_AttackCameraShakeParams", "the table is empty", 3, 0 },
        { "the second table cannot be read", function(w) w.tableMissing = "m_HitCameraShakeParams" end, "m_HitCameraShakeParams", "the table could not be read", 7, 12 },
    }) do
        c = start("shake-fails", { config = NOSHAKE, diag = true })
        ue, w, S = c.ue, c.world, c.S
        case[2](w)
        c.ticks(1)
        local line = ("[G1R_Melee] camera shake on hits stays as the game has it: the game's table %s could not be changed (%s); it is as the game had it\n"):format(case[3], case[4])
        check(untouched(w) and w.blow("Standard").shake == "MatineeCameraShake_Combat_Standard", case[1] .. ": the game has its own classes")
        check(printedCount(ue, line) == 1 and printed(ue, "changed in the game") == nil and c.fake.value("melee.shake.write") == "failed"
            and c.fake.detail("melee.shake.write") == case[3] .. ": " .. case[4], case[1] .. ": said in one line, noted; no change is announced")
        check(w.walks == case[5] and w.called("set") == case[6] and next(S.mem) == nil and w.escaped == 0 and #ue.errors == 0,
            ("%s: %d walks, %d classes set; nothing is remembered as changed"):format(case[1], w.walks, w.called("set")))
        calls, walks = sum(w.calls), w.walks
        c.seconds(60)
        check(sum(w.calls) == calls and w.walks == walks and has(status(c), ("|camera shake on hits: wanted none, but left as the game has it (%s: %s)|"):format(case[3], case[4])),
            case[1] .. ": then the game is not looked at any more; the status says why")
        stop(c)
    end

    -- a class the game had is gone when it is to be put back (a wrapper that went stale)
    c = start("shake-gone", { config = NOSHAKE, diag = true })
    ue, w, S = c.ue, c.world, c.S
    c.ticks(1)
    w.classes.MatineeCameraShake_Combat_Parried.__valid = false
    reload(c, "Config.HitShake = true")
    c.ticks(1)
    check(w.shake("m_AttackCameraShakeParams", "Standard") == "MatineeCameraShake_Combat_Standard" and w.shake("m_HitCameraShakeParams", "Additive") == "MatineeCameraShake_Combat_Additive"
        and w.shake("m_AttackCameraShakeParams", "Parried") == "MatineeCameraShake_None" and w.shake("m_HitCameraShakeParams", "Parried") == "MatineeCameraShake_None",
        "a class the game had is gone when the shake is switched back on: every other entry gets its class back, that one keeps the class for no shake")
    check(printedCount(ue, "[G1R_Melee] camera shake on hits: the game's table m_AttackCameraShakeParams could not be put back as the game had it (the class MatineeCameraShake_Combat_Parried is gone); "
        .. "values of the mod may still be in it - restart the game to be safe\n") == 1
        and printedCount(ue, "camera shake on hits: the game's table m_HitCameraShakeParams could not be put back as the game had it") == 1, "said for each of the two tables")
    check(S.mem.m_AttackCameraShakeParams ~= nil and S.mem.m_HitCameraShakeParams ~= nil and w.escaped == 0 and #ue.errors == 0 and printed(ue, "changed in the game: camera shake on hits as") == nil,
        "the module keeps what it remembers; no change is announced; no error")
    check(has(status(c), "|camera shake on hits: values of the mod may still be in the game (m_AttackCameraShakeParams: the class MatineeCameraShake_Combat_Parried is gone) - restart the game to be safe|")
        and has(status(c), "|nothing left to do: the game is not looked at|"), "the status says so")
    calls, walks = sum(w.calls), w.walks
    c.seconds(60)
    check(sum(w.calls) == calls and w.walks == walks, "then the game is not looked at any more")
    stop(c)

    -- the feedback object
    c = start("no-feedback", { config = BOTH, game = { noFeedback = true }, diag = true })
    ue, w, S = c.ue, c.world, c.S
    c.ticks(1)
    check(untouched(w) and w.walks == 0 and searched(ue, FEEDBACK_PATH) == 1 and S.noFeedback == true and c.fake.value("melee.feedback") == "not found" and c.fake.detail("melee.feedback") == nil,
        "the feedback object is not found: nothing is changed; noted")
    check(printedCount(ue, "[G1R_Melee] the game's melee feedback object (GenericMeleeFeedback) was not found: hit stop and camera shake stay as the game has them\n") == 1
        and printed(ue, "could not be changed") == nil and c.fake.value("melee.stop.write") == nil, "said once, and nothing else")
    local lookups
    calls, lookups = sum(w.calls), #ue.lookups
    c.seconds(60)
    check(sum(w.calls) == calls and #ue.lookups == lookups, "then the game is not looked at any more")
    local text = status(c)
    check(has(text, "|hit stop: wanted 50 % of the game's, but left as the game has it (the game's feedback object was not found)|")
        and has(text, "|camera shake on hits: wanted none, but left as the game has it (the game's feedback object was not found)|")
        and has(text, "|nothing left to do: the game is not looked at|"), "the status says why, for both")
    reload(c, "Config.HitStop = 60\nConfig.HitShake = false")
    c.seconds(10)
    check(searched(ue, FEEDBACK_PATH) == 1 and sum(w.calls) == calls and printedCount(ue, "was not found: hit stop and camera shake stay") == 1 and #ue.errors == 0,
        "a changed setting does not make it search again in this run")
    stop(c)

    c = start("other-feedback", { config = BOTH, game = { feedbackName = "GenericRangedFeedback /Script/Angelscript.Default__GenericRangedFeedback" }, diag = true })
    c.ticks(1)
    check(untouched(c.world) and c.world.walks == 0 and c.S.noFeedback == true and c.fake.value("melee.feedback") == "not found"
        and c.fake.detail("melee.feedback") == "GenericRangedFeedback /Script/Angelscript.Default__GenericRangedFeedback",
        "the search answers with another object: it is not used; the note names it")
    stop(c)

    c = start("feedback-gone", { config = BOTH, diag = true })
    ue, w, S = c.ue, c.world, c.S
    c.ticks(1)
    check(freezesAt(w, 0.5) and shakesAre(w, true) and printed(ue, "changed in the game: hit stop 50 %, no camera shake on hits") ~= nil, "both are changed in one look, said in one line")
    w.feedback.__valid = false
    c.seconds(30)
    check(S.noFeedback == true and next(S.mem) == nil and printedCount(ue, "the game's melee feedback object (GenericMeleeFeedback) was not found") == 1 and table.concat(c.fake.values("melee.feedback"), " ") == "found not found",
        "the object is gone when the tables are read next: said once, noted; what was remembered belonged to it")
    calls, walks = sum(w.calls), w.walks
    c.seconds(60)
    check(sum(w.calls) == calls and w.walks == walks and searched(ue, FEEDBACK_PATH) == 1 and #ue.errors == 0, "then the game is not looked at any more; it is not searched for again")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("8. all three at once; the module switched off and on")
do
    local c = start("all", { config = ALL, diag = true, widgets = true })
    local ue, w, S = c.ue, c.world, c.S
    check(printed(ue, "[G1R_Melee] v1.0.0 loaded: flow helper off, hit stop 50 %, no camera shake on hits\n") ~= nil, "the load line names all three")
    c.ticks(1)
    check(w.sloppy() == false and freezesAt(w, 0.5) and shakesAre(w, true), "one look sets all three")
    check(printedCount(ue, "[G1R_Melee] changed in the game: flow helper off, hit stop 50 %, no camera shake on hits\n") == 1
        and c.ui.note() == "Melee: flow helper off, hit stop 50 %, no camera shake on hits" and S.changes == 1, "one line in the log, one note on screen")
    local lines = c.hook.status()
    check(#lines == 5 and lines[1] == "v1.0.0 | flow helper off, hit stop 50 %, no camera shake on hits" and lines[2] == "flow helper: wanted off, the game has it off (through the option object)"
        and lines[3] == "hit stop: 50 % of the game's in 12 of 12 entries" and lines[4] == "camera shake on hits: none in 13 of 13 entries"
        and lines[5] == "changes: 1 (last: flow helper off, hit stop 50 %, no camera shake on hits); flow helper set 1 time(s), put back 0; table values written 34, put back 0; looks 1 (0 while paused)",
        "the status: " .. table.concat(lines, " | "))
    c.seconds(60)
    check(w.sloppy() == false and freezesAt(w, 0.5) and shakesAre(w, true) and S.changes == 1 and S.looks == 21, "a minute later: all as set, nothing changed again")

    -- the whole module off
    reload(c, "Config.Enabled = false\nConfig.FlowHelper = \"off\"\nConfig.HitStop = 50\nConfig.HitShake = false")
    check(printed(ue, "[G1R_Melee] settings changed (config.lua): switched off in the settings\n") ~= nil and w.sloppy() == false, "the module is switched off: said; nothing happens inside the settings callback")
    c.ticks(1)
    check(w.sloppy() == true and untouched(w) and next(S.mem) == nil and next(S.flow.before) == nil, "at the next turn of the loop everything is as the game had it")
    check(printedCount(ue, "[G1R_Melee] changed in the game: flow helper as the game had it (on), hit stop as the game has it, camera shake on hits as the game has it\n") == 1
        and c.ui.note() == "Melee: flow helper as the game had it (on), hit stop as the game has it, camera shake on hits as the game has it", "one line in the log, one note on screen")
    lines = c.hook.status()
    check(#lines == 3 and lines[1] == "v1.0.0 | switched off in the settings" and lines[2] == "nothing to change: the game is not looked at"
        and lines[3] == "changes: 2 (last: flow helper as the game had it (on), hit stop as the game has it, camera shake on hits as the game has it); "
        .. "flow helper set 1 time(s), put back 1; table values written 34, put back 34; looks 22 (0 while paused)", "the status: " .. table.concat(lines, " | "))
    local calls, walks, lookups = sum(w.calls), w.walks, #ue.lookups
    c.seconds(60)
    check(sum(w.calls) == calls and w.walks == walks and #ue.lookups == lookups and S.looks == 22, "switched off: the game is not looked at at all")
    w.gameSets(false)
    w.setFreeze("m_HitFreezeParams", "Standard", 0.01)
    c.seconds(30)
    check(w.sloppy() == false and near(w.freeze("m_HitFreezeParams", "Standard"), 0.01) and sum(w.calls) == calls, "what the game or the player changes now stays")
    w.gameSets(true)
    w.setFreeze("m_HitFreezeParams", "Standard", 0.05)

    -- on again, in the in-game menu
    T.menuSet(c, "Combat", "Melee clean-ups", true)
    c.ticks(2)
    check(w.sloppy() == false and freezesAt(w, 0.5) and shakesAre(w, true) and printed(ue, "[G1R_Melee] settings changed (in-game menu): flow helper off, hit stop 50 %, no camera shake on hits\n") ~= nil,
        "switched on again in the in-game menu: all three are set again")
    check(S.flow.sets == 2 and S.written == 68 and searched(ue, FEEDBACK_PATH) == 1 and searched(ue, OPTION_PATH) == 1 and w.escaped == 0 and #ue.errors == 0, "nothing was searched a second time; no error")
    stop(c)

    -- one of the three cannot be done: the other two are
    c = start("all-but-one", { config = ALL, diag = true })
    ue, w, S = c.ue, c.world, c.S
    w.setRaises = true
    c.ticks(1)
    check(w.sloppy() == false and freezesAt(w, 0.5) and shakesAre(w, false) and printed(ue, "[G1R_Melee] changed in the game: flow helper off, hit stop 50 %\n") ~= nil,
        "the camera shake tables cannot be written: the flow helper and the hit stop are set all the same")
    lines = c.hook.status()
    check(lines[4] == "camera shake on hits: wanted none, but left as the game has it (m_AttackCameraShakeParams: the value could not be set (test))" and #lines == 5, "the status says which one is left alone")
    c.seconds(60)
    check(w.called("set") == 6 and S.looks == 21 and w.sloppy() == false and freezesAt(w, 0.5), "the module keeps looking after the other two and leaves the third alone")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("9. no hero, the game paused, map loads")
do
    -- no hero: the main menu, before a game is loaded
    local c = start("no-hero", { config = ALL, game = { noController = true }, diag = true })
    local ue, w, S = c.ue, c.world, c.S
    c.seconds(30)
    check(w.sloppy() == true and untouched(w) and sum(w.calls) == 0 and #ue.lookups == 0 and firstOf(ue) == 0 and w.walks == 0,
        "no hero (the main menu): nothing is changed; none of the game's objects is searched for or read")
    check(S.looks == 10 and allOf(ue) == 2 * S.looks and S.hero == false, "the module looks every 3 seconds; what a look costs then is the kit's search for the hero")
    local lines = c.hook.status()
    check(#lines == 6 and lines[2] == "flow helper: wanted off, not looked at yet" and lines[3] == "hit stop: wanted 50 % of the game's, not looked at yet"
        and lines[4] == "camera shake on hits: wanted none, not looked at yet" and lines[5] == "nothing is changed at the moment: no game is running (the hero was not found)",
        "the status says what is waiting and why")
    check(#c.fake.notes == 0 and #c.fake.crumbs == 0, "nothing is noted yet")
    ue.allOf["GothicPlayerControllerBaseBP_C"] = { w.controllerDefault, w.controller }
    c.seconds(3)
    check(w.sloppy() == false and freezesAt(w, 0.5) and shakesAre(w, true) and S.hero == true, "a game is loaded: within 3 seconds all three are set")
    -- the hero is gone again and the module is switched off: putting back needs no hero
    ue.allOf["GothicPlayerControllerBaseBP_C"] = nil
    w.controller.__valid = false
    c.seconds(30)
    check(w.sloppy() == false and freezesAt(w, 0.5) and shakesAre(w, true) and S.hero == false, "the hero is gone (back in the main menu): what is set stays set")
    reload(c, "Config.Enabled = false")
    c.ticks(1)
    check(w.sloppy() == true and untouched(w) and next(S.mem) == nil and next(S.flow.before) == nil and #ue.errors == 0,
        "the module is switched off while there is no hero: everything is put back all the same")
    stop(c)

    -- only the hit stop is in hand when the hero goes; the camera shake is switched off then: that waits for a hero
    c = start("no-hero-later", { config = HALF })
    ue, w, S = c.ue, c.world, c.S
    c.ticks(1)
    ue.allOf["GothicPlayerControllerBaseBP_C"] = nil
    w.controller.__valid = false
    reload(c, "Config.HitStop = 50\nConfig.HitShake = false")
    c.seconds(10)
    check(freezesAt(w, 0.5) and shakesAre(w, false) and w.called("table m_AttackCameraShakeParams") == 0 and S.none == nil and S.hero == false,
        "a kind is set for the first time while there is no hero: its tables are not even read; what is in hand stays")
    w.controller.__valid = nil
    ue.allOf["GothicPlayerControllerBaseBP_C"] = { w.controllerDefault, w.controller }
    c.seconds(3.25)
    check(shakesAre(w, true) and freezesAt(w, 0.5) and S.hero == true, "the hero is back: what waited for him is done at that look, not at the next reading of the tables")
    stop(c)

    -- the game is paused
    c = start("paused", { config = ALL })
    ue, w, S = c.ue, c.world, c.S
    w.paused = true
    c.seconds(30)
    check(w.sloppy() == true and untouched(w) and S.looks == 10 and S.pausedLooks == 10 and w.called("IsGamePaused") == 10 and w.called("GetValue") == 0 and w.walks == 0
        and searched(ue, FEEDBACK_PATH) == 0, "the game is paused: nothing is changed and nothing of it is read - one question to the engine per look")
    check(has(status(c), "|nothing is changed at the moment: the game is paused|") and has(status(c), "looks 10 (10 while paused)"), "the status says so")
    w.paused = false
    c.seconds(3)
    check(w.sloppy() == false and freezesAt(w, 0.5) and shakesAre(w, true) and S.pausedLooks == 10, "the pause ends: all three are set within 3 seconds")
    w.paused = true
    reload(c, "Config.HitStop = 100")
    c.seconds(10)
    check(w.sloppy() == false and freezesAt(w, 0.5) and shakesAre(w, true), "a setting changed while the game is paused waits")
    check(has(status(c), "|flow helper: being put back|hit stop: being put back|camera shake on hits: being put back|nothing is changed at the moment: the game is paused|"),
        "the status says what is waiting to be put back")
    w.paused = false
    c.seconds(3)
    check(w.sloppy() == true and untouched(w), "and is acted on when the pause ends")
    stop(c)

    c = start("paused-act", { config = T.config('Config.FlowHelper = "off"\nConfig.HitStop = 50\nConfig.HitShake = false\nConfig.ActWhilePaused = true') })
    c.world.paused = true
    c.ticks(1)
    check(c.world.sloppy() == false and freezesAt(c.world, 0.5) and shakesAre(c.world, true) and c.world.called("IsGamePaused") == 0 and c.S.pausedLooks == 0,
        "ActWhilePaused = true: set although the game is paused; the engine is not even asked")
    stop(c)

    c = start("no-statics", { config = ALL, game = { noStatics = true } })
    c.world.paused = true
    c.seconds(10)
    check(c.world.sloppy() == false and freezesAt(c.world, 0.5) and searched(c.ue, STATICS_PATH) == 1 and #c.ue.errors == 0,
        "the engine cannot be asked whether the game is paused: that counts as not paused; searched for once")
    stop(c)

    -- map loads
    c = start("map-load", { config = ALL, diag = true })
    ue, w, S = c.ue, c.world, c.S
    c.ticks(1)
    local calls, walks, looks = sum(w.calls), w.walks, S.looks
    ue:fireLoadMapPre()
    -- while the map loads the game puts things back (in this model): the option, two numbers, one class
    w.gameSets(true)
    w.setFreeze("m_HitFreezeParams", "Standard", 0.05)
    w.setFreeze("m_AttackFreezeParams", "Standard", 0.05)
    w.tables.m_AttackCameraShakeParams.entries[3].value = w.classes.MatineeCameraShake_Combat_Standard
    c.seconds(10)
    check(sum(w.calls) == calls and w.walks == walks and S.looks == looks and w.sloppy() == true, "while a map loads the module does not look at the game at all")
    ue:fireLoadMapPost()
    c.ticks(1)
    check(w.sloppy() == false and freezesAt(w, 0.5) and shakesAre(w, true), "after the load everything is looked at with the first turn of the loop: what the game put back is set again")
    check(S.written == 34 + 3 and w.fieldWrites == 24 + 2 and w.called("set") == 11 and w.called("SetValue") == 2,
        "only what had changed is written (the option, two numbers, one class): nothing is applied a second time")
    check(printedCount(ue, "[G1R_Melee] changed in the game: flow helper off, hit stop 50 %, no camera shake on hits\n") == 2, "said again")
    walks = w.walks
    ue:fireLoadMapPre()
    ue:fireLoadMapPost()
    c.ticks(1)
    check(w.walks == walks + 4 and w.fieldWrites == 26 and w.called("set") == 11 and w.called("SetValue") == 2 and freezesAt(w, 0.5) and S.changes == 2,
        "a load during which the game changed nothing: the four tables are read once, nothing is written")
    check(searched(ue, FEEDBACK_PATH) == 1 and searched(ue, OPTION_PATH) == 1 and searched(ue, STATICS_PATH) == 1 and w.escaped == 0 and #ue.errors == 0, "nothing is searched by path a second time after a load; no error")
    c.seconds(29.75)
    check(w.walks == walks + 4, "the next reading of the tables is 30 seconds after the one that followed the load")
    c.ticks(1)
    check(w.walks == walks + 8, "then they are read again")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("10. settings while the game runs: the file, the in-game menu, the console")
do
    local c = start("settings", { widgets = true })
    local ue, w, S = c.ue, c.world, c.S
    local v = c.hook.settings.values
    local index = T.menuIndex(c)
    check(#index == 1 and index[1] == "G1R Combat", "the settings are on the page Combat of the in-game mod menu")
    local page = T.menuPage(c, "Combat")
    local titles, long = {}, {}
    for _, s in ipairs(page.sections) do titles[#titles + 1] = s.title .. ":" .. #s.items end
    check(table.concat(titles, "|") == "Melee: clean-ups:4|Melee: on screen:1", "its groups and their items: " .. table.concat(titles, "|"))
    local item = T.menuItem(c, "Combat", "Hit stop")
    check(item.kind == "num" and item.min == 0 and item.max == 300 and item.step == 10 and item.value == 100 and item.name == "Hit stop (% of the game's)"
        and item.desc == "freeze when a blow lands; 0 = none, 200 = twice", "hit stop: a number from 0 to 300 in steps of 10, with its short name and hint")
    item = T.menuItem(c, "Combat", "Mirrored follow-up swings")
    check(item.kind == "num" and item.min == 1 and item.max == 3 and item.step == 1 and item.value == 1 and item.desc == "1 = game, 2 = off, 3 = on",
        "the flow helper: a choice of three, in the menu a number with its meanings")
    check(T.menuItem(c, "Combat", "Camera shake").kind == "bool" and T.menuItem(c, "Combat", "Camera shake").value == true and T.menuItem(c, "Combat", "Melee clean-ups").value == true
        and T.menuItem(c, "Combat", "Note when one of these changed").desc == "a note when the mod changed or put one back", "switches are switches, with their short menu texts")
    for _, i in ipairs(page.items) do
        if #i.desc > 90 or has(i.desc, "...") then long[#long + 1] = i.name end
        if has(i.name, "FlowMethod") or has(i.name, "CheckSeconds") or has(i.name, "VerifySeconds") or has(i.name, "ActWhilePaused") then check(false, "a hidden setting is in the menu: " .. i.name) end
    end
    check(#long == 0 and #page.items == 5, "five settings in the menu, the hidden ones are not; no hint is cut off (" .. table.concat(long, ", ") .. ")")

    -- the file
    c.ticks(1)
    T.write(c.path, T.config("Config.HitStop = 50"))
    c.seconds(6)
    check(v.HitStop == 50 and printed(ue, "[G1R_Melee] settings changed (config.lua): hit stop 50 %\n") ~= nil and freezesAt(w, 0.5), "a changed config.lua is picked up within a few seconds and acted on")
    -- the in-game menu
    T.menuSet(c, "Combat", "Hit stop", 150)
    c.ticks(1)
    check(v.HitStop == 150 and freezesAt(w, 1.5) and printed(ue, "[G1R_Melee] settings changed (in-game menu): hit stop 150 %\n") ~= nil and has(T.read(c.path), "Config.HitStop = 150\n")
        and T.menuItem(c, "Combat", "Hit stop").value == 150, "an edit in the menu is acted on at once, written into config.lua and shown in the menu")
    T.menuSet(c, "Combat", "Mirrored follow-up swings", 2)
    c.ticks(1)
    check(v.FlowHelper == "off" and w.sloppy() == false and has(T.read(c.path), 'Config.FlowHelper = "off"\n'), "the flow helper set to 2 in the menu: off")
    T.menuSet(c, "Combat", "Mirrored follow-up swings", 3)
    c.ticks(1)
    check(v.FlowHelper == "on" and w.sloppy() == true and S.flow.before["0"] == true and S.flow.sets == 2, "3: on")
    T.menuSet(c, "Combat", "Mirrored follow-up swings", 1)
    c.ticks(1)
    check(v.FlowHelper == "game" and w.sloppy() == true and next(S.flow.before) == nil and S.flow.backs == 0 and w.called("SetValue") == 2,
        "1: game - the game has what it had before, so nothing is written")
    T.menuSet(c, "Combat", "Camera shake", false)
    T.menuSet(c, "Combat", "Hit stop", 100)
    c.ticks(1)
    check(v.HitShake == false and v.HitStop == 100 and shakesAre(w, true) and freezesAt(w, 1, true)
        and printed(ue, "[G1R_Melee] changed in the game: hit stop as the game has it, no camera shake on hits\n") ~= nil, "two edits at once: one look, one line")
    c.seconds(12)
    check(printedCount(ue, "settings changed (config.lua)") == 1, "what the settings service wrote itself is not taken for a change of the file")

    -- the console
    local before = #ue.printed
    check(ue:fireConsole("melee") == true and ue.printed[before + 1] == "[G1R_Melee] v1.0.0 | no camera shake on hits\n" and #ue.device.lines == #ue.printed - before
        and ue.device.lines[1] == "[G1R_Melee] v1.0.0 | no camera shake on hits" and #ue.printed - before == 5, "melee: the status, in the log and in the console window")
    check(ue:fireConsole("g1r_melee status") == true and ue:fireConsole("melee something") == true and #ue.printed - before == 15, "g1r_melee works too; an unknown word shows the status")
    check(c.hook.console(nil, nil, nil) == true and c.hook.console("melee reload", nil, nil) == true and c.hook.console("melee", { 2, {} }, {}) == true and #ue.errors == 0,
        "called with nothing, with the command line only, with parameters of another kind: handled")
    before = #ue.printed
    c.hook.console("melee reload", nil, nil)
    check(ue.printed[before + 1] == "[G1R_Melee] settings read: no camera shake on hits\n" and #ue.printed == before + 1, "with the command line only, the words are taken from it: melee reload reads the file")
    before = #ue.printed
    ue:fireConsole("melee RELOAD")
    check(ue.printed[before + 1] == "[G1R_Melee] settings read: no camera shake on hits\n" and #ue.printed == before + 1, "melee reload reads the file also when it has not changed; said in one line")
    os.remove(c.path)
    before = #ue.printed
    ue:fireConsole("melee reload")
    check(ue.printed[before + 1] == "[G1R_Melee] settings not read: config.lua not found\n" and v.HitShake == false, "melee reload without a file: said; the settings stay")
    T.write(c.path, "local Config = {}\nConfig.HitStop = \nreturn Config\n")
    c.seconds(6)
    check(printedCount(ue, "config.lua has an error, keeping the previous settings") == 1 and v.HitShake == false and shakesAre(w, true), "a file with an error: said once, the previous settings stay in force")
    stop(c)

    -- values that are out of range or of the wrong kind
    for _, case in ipairs({
        { "Config.HitStop = 500", "HitStop", 300 }, { "Config.HitStop = -20", "HitStop", 0 }, { 'Config.HitStop = "abc"', "HitStop", 100 }, { "Config.HitStop = 62.4", "HitStop", 62 },
        { 'Config.FlowHelper = "maybe"', "FlowHelper", "game" }, { "Config.FlowHelper = true", "FlowHelper", "game" }, { 'Config.HitShake = "no"', "HitShake", true },
        { "Config.Enabled = 0", "Enabled", true }, { "Config.CheckSeconds = 0", "CheckSeconds", 1 }, { "Config.CheckSeconds = 500", "CheckSeconds", 60 },
        { "Config.VerifySeconds = 1", "VerifySeconds", 5 }, { 'Config.FlowMethod = "magic"', "FlowMethod", "auto" }, { 'Config.ActWhilePaused = "yes"', "ActWhilePaused", false },
    }) do
        local c2 = start("range", { config = T.config(case[1]) })
        c2.seconds(4)
        check(c2.ok and c2.hook.settings.values[case[2]] == case[3] and #c2.ue.errors == 0 and printed(c2.ue, "update error") == nil, case[1] .. " -> " .. tostring(case[3]))
        stop(c2)
    end
    c = start("percent", { config = T.config("Config.HitStop = 62.4") })
    c.ticks(1)
    check(printed(c.ue, "[G1R_Melee] v1.0.0 loaded: hit stop 62 %\n") ~= nil and freezesAt(c.world, 0.62) and printed(c.ue, "changed in the game: hit stop 62 %") ~= nil, "a percentage with decimals is used as a whole number")
    stop(c)

    -- the hidden settings
    c = start("every-second", { config = T.config('Config.FlowHelper = "off"\nConfig.HitStop = 50\nConfig.CheckSeconds = 1\nConfig.VerifySeconds = 5') })
    c.ticks(1)
    local gets, walks = c.world.called("GetValue"), c.world.walks
    c.seconds(10)
    check(c.world.called("GetValue") == gets + 10 and c.world.walks == walks + 4 and c.S.looks == 11, "CheckSeconds = 1: a look every second; VerifySeconds = 5: the tables are read every 5 seconds")
    stop(c)

    -- files that are missing or broken at the start
    c = start("badstart", { config = "this is not lua\n" })
    c.seconds(4)
    check(c.ok and printed(c.ue, "[G1R_Melee] config.lua has an error (") ~= nil and c.hook.settings.values.HitStop == 100 and c.S.looks == 0 and T.read(c.path) == "this is not lua\n",
        "a broken file at the start: said, the default settings are used (nothing is changed); the file is left for its owner to repair")
    stop(c)
    c = start("nofile", { config = false })
    check(c.ok and printed(c.ue, "[G1R_Melee] config.lua was not there: written with the default settings\n") ~= nil and T.read(c.path) == shipped, "no file at the start: the default file is written")
    stop(c)
    c = start("noschema", { files = { ["Scripts/schema.lua"] = false } })
    check(c.ok and printed(c.ue, "[G1R_Melee] the settings could not be set up (schema.lua could not be read") ~= nil and #c.ue.loops == 1 and c.ue.console.melee == nil and c.hook.state == nil,
        "without schema.lua the module says so and does not start")
    stop(c)
    c = start("noloop", { config = ALL, mock = { without = { "LoopInGameThreadWithDelay" } } })
    check(c.ok and printed(c.ue, "[G1R_Melee] FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; the melee clean-ups are disabled.\n") ~= nil and printed(c.ue, "loaded:") == nil and #c.ue.errors == 0,
        "a UE4SS without game-thread loops: said, the module does not start")
    stop(c)
    c = start("noconsole", { config = ALL, mock = { without = { "RegisterConsoleCommandHandler" } } })
    c.ticks(1)
    check(c.ok and c.world.sloppy() == false and freezesAt(c.world, 0.5) and #c.ue.errors == 0, "a UE4SS without console commands: the module works without them")
    stop(c)

    -- the shipped files
    local schema = dofile(MOD .. "modules/melee/Scripts/schema.lua")
    local chunk = load(shipped, "=config.lua", "t", {})
    local values = chunk and chunk() or {}
    local keys = {}
    for k in pairs(values) do keys[#keys + 1] = k end
    table.sort(keys)
    check(table.concat(keys, ",") == "Enabled,FlowHelper,HitShake,HitStop,ShowMessage" and not shipped:find("\r", 1, true) and not shipped:find("[^\n\32-\126]"),
        "the shipped config.lua: five settings, plain ASCII, LF line ends (" .. table.concat(keys, ",") .. ")")
    check(values.Enabled == true and values.FlowHelper == "game" and values.HitStop == 100 and values.HitShake == true and values.ShowMessage == true, "its values are the neutral ones: nothing of the game is changed")
    local probe = start("default-text", {})
    check(probe.settings.defaultText(schema) == shipped, "the shipped config.lua is exactly what the schema generates (lua5.4 dev/tools/gen_config.lua melee)")
    stop(probe)
    local placed = schema.Page == "Combat" and schema.PageOrder == 10 and schema.Module == "melee"
    for _, g in ipairs(schema.Groups) do
        if not (g.Order >= 60 and g.Order <= 79 and g.Title:sub(1, 7) == "Melee: ") then placed = false end
    end
    check(placed, "the schema: page Combat (order 10), group orders 60 - 79, titles that start with Melee:")
end

-- ---------------------------------------------------------------------------
section("11. notes on screen and lines in the log")
do
    local c = start("quiet", { config = T.config('Config.FlowHelper = "off"\nConfig.HitStop = 50\nConfig.ShowMessage = false'), widgets = true })
    local ue, w = c.ue, c.world
    c.ticks(1)
    check(w.sloppy() == false and freezesAt(w, 0.5) and c.ui.note() == nil and c.ui.created == 0 and searched(ue, "/Script/UMG.Default__WidgetBlueprintLibrary") == 0
        and printedCount(ue, "[G1R_Melee] changed in the game: flow helper off, hit stop 50 %\n") == 1,
        "ShowMessage = false: the change is in the log, nothing on screen; what a note needs is not even searched for")
    T.menuSet(c, "Combat", "Note when one of these changed", true)
    T.menuSet(c, "Combat", "Hit stop", 60)
    c.ticks(1)
    check(c.ui.note() == "Melee: hit stop 60 %", "switched on while the game runs: the next change is shown")
    T.menuSet(c, "Combat", "Hit stop", 70)
    c.ticks(1)
    check(c.ui.note() == "Melee: hit stop 70 %", "a second change right after: its note takes the place of the first (one line)")
    T.menuSet(c, "Combat", "Note when one of these changed", false)
    c.ticks(1)
    check(c.ui.note() == nil, "switched off while a note is up: the note goes")
    stop(c)

    c = start("notes", { config = OFF, widgets = true, game = { profiles = { [0] = false } } })
    ue, w = c.ue, c.world
    c.ticks(1)
    check(searched(ue, "/Script/UMG.Default__WidgetBlueprintLibrary") == 1 and searched(ue, "/Script/UMG.TextBlock") == 1 and c.ui.created == 0 and c.ui.note() == nil,
        "ShowMessage = true: what a note needs is searched for when the hero is first found, not in a fight; no note while nothing changes")
    local lines = #ue.printed
    c.seconds(120)
    check(#ue.printed == lines and c.ui.note() == nil, "nothing is written to the log and nothing shown while nothing changes")
    w.gameSets(true)
    c.seconds(3)
    check(c.ui.note() == "Melee: flow helper off" and #ue.printed == lines + 1, "a change: one note, one line")
    c.seconds(4)
    check(c.ui.note() == nil, "the note leaves by itself")
    stop(c)

    -- no way of showing a note: the module does its work all the same
    c = start("no-widgets", { config = HALF })
    c.ticks(1)
    check(freezesAt(c.world, 0.5) and printed(c.ue, "[G1R_Melee] changed in the game: hit stop 50 %\n") ~= nil and #c.ue.errors == 0 and printed(c.ue, "update error") == nil,
        "notes cannot be shown in this game: the change is made and logged, no error")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("12. what the module costs")
do
    local c = start("cost", { config = ALL, widgets = true })
    local ue, w, S = c.ue, c.world, c.S
    check(#ue.lookups == 0 and allOf(ue) == 0 and firstOf(ue) == 0 and sum(w.calls) == 0, "loading: no search, nothing read")
    c.ticks(1)
    check(#ue.lookups == 9 and allOf(ue) == 1 and firstOf(ue) == 1,
        "the first look with all three set: nine searches by path (the engine's statics, six for notes, the option object, the feedback object), one search for the hero, one for the profile")
    check(w.walks == 13 and w.fieldReads == 72 and w.fieldWrites == 24 and w.called("set") == 10 and w.called("GetValue") == 2 and w.called("SetValue") == 1 and w.called("key") == 25,
        "13 walks through the four tables (25 entries), 72 numbers read and 24 written, 10 classes set, the option read twice and set once")
    local lookups, finds, firsts, walks, reads, gets, asked, state = #ue.lookups, allOf(ue), firstOf(ue), w.walks, w.fieldReads, w.called("GetValue"), w.called("IsGamePaused"), w.reads[21]
    c.seconds(60)
    check(#ue.lookups == lookups and allOf(ue) == finds and firstOf(ue) == firsts, "the minute after: no search of any kind")
    check(S.looks == 21 and w.called("GetValue") == gets + 20 and w.called("IsGamePaused") == asked + 20 and w.reads[21] - state <= 13,
        "20 looks: per look the option is read once and the engine asked once whether the game is paused; the kit checks the hero's attributes every 5 seconds")
    check(w.walks == walks + 8 and w.fieldReads == reads + 48 and w.fieldWrites == 24 and w.called("set") == 10 and w.called("SetValue") == 1 and w.called("key") == 25,
        "every 30 seconds the four tables are walked once each (24 numbers, 13 classes); nothing is written, no key is read again")
    stop(c)

    -- only the flow helper: the tables are never looked at
    c = start("cost-flow", { config = OFF })
    c.seconds(60)
    check(c.world.walks == 0 and searched(c.ue, FEEDBACK_PATH) == 0 and c.world.called("GetValue") == 2 + 19, "only the flow helper set: the feedback object is not even searched for")
    stop(c)
    -- only the tables: the option is never looked at
    c = start("cost-tables", { config = HALF })
    c.seconds(60)
    check(c.world.called("GetValue") == 0 and searched(c.ue, OPTION_PATH) == 0 and firstOf(c.ue) == 0 and c.world.walks == 6 + 2, "only the hit stop set: the option object and the profile are not searched for")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("13. what the diagnostics get")
do
    local c = start("diag", { config = ALL, diag = true, widgets = true })
    local ue, w = c.ue, c.world
    check(c.fake.versions[1] == "1.0.0" and #c.fake.status == 1 and #c.fake.dump == 1 and #c.fake.notes == 0, "at load: the version, a status function, a dump function; no note yet")
    c.ticks(1)
    local sequence = table.concat(c.fake.sequence(), " ")
    check(sequence == "melee.flow.game_value=on melee.profile=0 melee.flow.way=option object melee.flow.write=ok melee.feedback=found melee.stop.attack=6 melee.stop.write=ok melee.stop.hit=6 "
        .. "melee.shake.none_class=from the table melee.shake.attack=7 melee.shake.write=ok melee.shake.hit=6", "the notes of a session, each once: " .. sequence)
    check(#c.fake.crumbs == 2 and c.fake.crumbs[1] == "first write of the flow helper through the game's option object" and c.fake.crumbs[2] == "first walk through a table of the game",
        "the first call of the option's SetValue and the first walk through a table are announced before they are made (should the game go down inside, that line is the last)")
    check(#c.fake.events == 2 and c.fake.events[1] == "first write of the flow helper returned: no error" and c.fake.events[2] == "first walk through a table of the game returned: 6 entries",
        "and what came of them is recorded")
    c.seconds(120)
    w.gameSets(true)
    c.seconds(3)
    check(#c.fake.notes == 12 and #c.fake.crumbs == 2 and #c.fake.events == 2, "later looks, readings and writes add nothing: every note is made when its value changes")
    -- the status and the dump are built from what the module holds
    local calls, walks, lookups, finds, state = sum(w.calls), w.walks, #ue.lookups, allOf(ue), w.reads[21]
    local dump, lines
    for _ = 1, 20 do
        dump = c.fake.dump[1]()
        lines = c.fake.status[1]()
    end
    check(sum(w.calls) == calls and w.walks == walks and #ue.lookups == lookups and allOf(ue) == finds and w.reads[21] == state, "the status and the dump are built from what the module holds: no call into the game")
    local Fake = dofile(HERE .. "../markers/diag_fake.lua")
    local plain, where = Fake.plain(dump)
    check(plain and Fake.roundTrip(dump), "the dump is plain data (" .. tostring(where) .. ")")
    check(dump.version == "1.0.0" and dump.enabled == true and dump.flow_helper == "off" and dump.hit_stop == 50 and dump.hit_shake == false and dump.hero == true and dump.looks == c.S.looks
        and dump.flow.way == "option object" and dump.flow.game_value == "off" and dump.flow.before["0"] == "on" and dump.flow.set == 2 and dump.flow.given_up == nil
        and dump.tables_in_hand.m_AttackFreezeParams == 6 and dump.tables_in_hand.m_AttackCameraShakeParams == 7 and next(dump.tables_left_alone) == nil
        and dump.feedback_object == "GenericMeleeFeedback " .. FEEDBACK_PATH and dump.no_shake_class == "MatineeCameraShake_None" and dump.values_written == 34 and dump.feedback_missing == false,
        "the dump: the settings, what the game has, what is remembered")
    check(#lines == 5 and lines[1] == "v1.0.0 | flow helper off, hit stop 50 %, no camera shake on hits" and has(lines[5], "flow helper set 2 time(s)"), "the status function gives the status lines")
    stop(c)

    -- the dump of a module that has given things up
    c = start("diag-failed", { config = ALL, game = { noOption = true, noSettingsClass = true }, diag = true })
    c.world.fieldDeaf = true
    c.seconds(20)
    dump = c.fake.dump[1]()
    check(Fake.plain(dump) and dump.flow.given_up == "the game's settings class was not found" and dump.tables_left_alone.m_AttackFreezeParams == "12 of 12 values did not stay"
        and dump.tables_in_hand.m_AttackFreezeParams == nil and dump.tables_in_hand.m_AttackCameraShakeParams == 7 and dump.tables_in_hand.m_HitCameraShakeParams == 6,
        "the dump of a module that left two of the three alone says which and why")
    check(c.fake.neverRepeated("melee.flow.way") and c.fake.neverRepeated("melee.stop.write") and c.fake.value("melee.flow.way") == "none" and c.fake.value("melee.stop.write") == "failed",
        "its notes say the same")
    stop(c)

    -- without the diagnostics the module is the same module
    c = start("no-diag", { config = ALL })
    c.ticks(1)
    check(c.world.sloppy() == false and freezesAt(c.world, 0.5) and shakesAre(c.world, true) and rawget(_G, "G1R_DIAG") == nil and #c.ue.errors == 0, "without the diagnostics: the same module")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("14. nothing leaks; only config.lua is written")
do
    local known = {}
    local probe = T.Mock.new()
    probe:install()                 -- what the mock itself puts into _G does not count
    for k in pairs(_G) do known[k] = true end
    probe:uninstall()
    local given = { MELEE_TEST = true, ModRef = true, G1R_KIT = true, G1R_SETTINGS = true, G1R_DIAG = true, Key = true, ModifierKey = true, StaticConstructObject = true }
    local c = start("leak", { config = ALL, widgets = true, diag = true })
    c.ticks(1)
    reload(c, "Config.Enabled = false")
    c.ticks(1)
    T.menuSet(c, "Combat", "Melee clean-ups", true)
    c.seconds(40)
    c.ue:fireConsole("melee")
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
    check(has(T.read(c.path), "Config.Enabled = true\n"), "config.lua holds what the in-game menu set")
    local source = T.read(MOD .. "modules/melee/Scripts/main.lua")
    check(not source:find("StaticFindObject", 1, true) and not source:find("FindFirstOf", 1, true) and not source:find("FindAllOf", 1, true) and not source:find("RegisterHook", 1, true)
        and not source:find("NotifyOnNewObject", 1, true), "the module searches through the kit only and hooks nothing")
end

-- ---------------------------------------------------------------------------
section("15. through the megamod loader, with the real diagnostics")
do
    local TMP = T.TMP
    local root = TMP .. "/mega/G1R_MegaMod"
    T.sh("rm -rf " .. T.q(TMP .. "/mega") .. " && mkdir -p " .. T.q(root) .. " && cp -r " .. T.q(MOD .. "Scripts") .. " " .. T.q(root .. "/") .. " && mkdir -p " .. T.q(root .. "/modules")
        .. " && cp -r " .. T.q(MOD .. "modules/melee") .. " " .. T.q(root .. "/modules/"))
    -- only this module: the list of modules is cut down to it (the line the loader needs for it)
    T.write(root .. "/Scripts/core/modules.lua", 'return { { name = "melee", switch = "Melee" } }\n')
    T.write(root .. "/modules/melee/Scripts/config.lua", ALL)

    local function boot(options)
        local ue = T.Mock.new()
        ue:install()
        local ui = T.widgets(ue)
        local world = game(ue, options)
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
    check(c.ok and has(last(c), "loaded: melee ok | diagnostics normal"), "the loader loads the module: " .. last(c))
    check(rawget(_G, "MELEE_TEST") == nil and rawget(_G, "G1R_KIT") == nil and rawget(_G, "G1R_SETTINGS") == nil, "the test hook stays inert; the kit and the settings service are no globals")
    c.looks(2)
    check(w.sloppy() == false and freezesAt(w, 0.5) and shakesAre(w, true) and #ue.errors == 0 and c.ui.note() == "Melee: flow helper off, hit stop 50 %, no camera shake on hits",
        "all three are set as without the loader; the note is shown")
    check(c.mods.store["G1R_Melee:tables"] == "m_AttackFreezeParams,m_HitFreezeParams,m_AttackCameraShakeParams,m_HitCameraShakeParams",
        "the names of the four changed tables are in the UE4SS shared variable (the module reaches it from inside the loader's environment)")
    check(ue:fireConsole("g1r diag") == true, "g1r diag handled")
    local report = T.read(c.dir .. "/report-latest.txt") or ""
    check(has(report, "melee: loaded, version 1.0.0") and has(report, "[melee] v1.0.0 | flow helper off, hit stop 50 %, no camera shake on hits")
        and has(report, "[melee] flow helper: wanted off, the game has it off (through the option object)") and has(report, "[melee] hit stop: 50 % of the game's in 12 of 12 entries")
        and has(report, "[melee] camera shake on hits: none in 13 of 13 entries"), "report: the module's version and its status lines")
    check(has(report, "melee.flow.way = option object") and has(report, "melee.flow.write = ok") and has(report, "melee.flow.game_value = on") and has(report, "melee.profile = 0")
        and has(report, "melee.feedback = found") and has(report, "melee.stop.write = ok") and has(report, "melee.shake.write = ok") and has(report, "melee.shake.none_class = from the table"),
        "report: the notes of the module")
    check(has(report, "melee.stop.attack = 6 (Additive 0.033/0.033, Standard 0.05/0.05, Knockback 0.05/0.033, Parried 0.05/0.05, Deflected 0.033/0.033, Dot 0.033/0.033)")
        and has(report, "melee.stop.hit = 6 (Additive 0.033/0.033, Standard 0.05/0.05, Knockback 0.05/0.05,")
        and has(report, "melee.shake.attack = 7 (MeatBug SmashMeatBug, Additive Combat_Additive, Standard Combat_Standard, Knockback Combat_Standard, Parried Combat_Parried, Deflected Combat_Deflected, Dot None)")
        and has(report, "melee.shake.hit = 6 (Additive Combat_Additive, Standard Combat_Standard, Knockback Combat_Standard, Parried Combat_Parried, Deflected None, Dot None)"),
        "report: what the game had in every entry of the four tables, each note in full")
    check(has(report, "[melee] callbacks LoopInGameThreadWithDelay: 2 calls, 0 errors") and has(report, "[kit] lookups: 9 calls, 9 first-time, 0 not found")
        and has(report, "[melee] registered RegisterConsoleCommandHandler: 2 ok, 0 failed") and not has(report, "[melee] lookups"),
        "report: the module's loop and its two console commands; all nine searches are the kit's, the module makes none of its own")
    local log = newest(c, "session-")
    check(has(log, "[melee] [G1R_Melee] v1.0.0 loaded: flow helper off, hit stop 50 %, no camera shake on hits") and has(log, "[melee] [G1R_Melee] changed in the game: flow helper off, hit stop 50 %, no camera shake on hits"),
        "session log: the load line and the change")
    local crumbAt, eventAt = log:find("[melee] > first walk through a table of the game", 1, true), log:find("[melee] first walk through a table of the game returned: 6 entries", 1, true)
    check(crumbAt ~= nil and eventAt ~= nil and crumbAt < eventAt and has(log, "[melee] > first write of the flow helper through the game's option object")
        and has(log, "[kit] > lookup /Script/Angelscript.Default__GenericMeleeFeedback") and not has(log, "ERROR in "),
        "session log: the first write of the option and the first walk through a table are announced before they are made, as is every search; no error")
    check(ue:fireConsole("g1r dump") == true, "g1r dump handled")
    local okDump, dump = pcall(load(newest(c, "dump-"), "=dump", "t", {}))
    check(okDump and type(dump) == "table" and type(dump.melee) == "table" and dump.melee.hit_stop == 50 and dump.melee.flow.way == "option object" and dump.melee.tables_in_hand.m_HitFreezeParams == 6
        and dump.melee.values_written == 34 and dump._meta.refusedCount == 0, "dump: what the module holds")
    check(ue:fireConsole("g1r") == true and printed(ue, "[G1R_MegaMod] melee: loaded, version 1.0.0, 0 error(s), 12 note(s)") ~= nil, "g1r lists the module with its notes")
    check(ue:fireConsole("melee") == true and printed(ue, "[G1R_Melee] hit stop: 50 % of the game's in 12 of 12 entries\n") ~= nil, "the module's own console command works through the loader")
    -- settings through the loader: the in-game menu
    local item = T.menuItem(c, "Combat", "Hit stop")
    c.mods.store["SMM:cmd:G1R Combat"] = item.index .. "\31n200"
    c.looks(2)          -- the loader's loop takes the edit, the module's next turn acts on it
    check(printed(ue, "[G1R_Melee] settings changed (in-game menu): flow helper off, hit stop 200 %, no camera shake on hits") ~= nil and freezesAt(w, 2)
        and has(T.read(root .. "/modules/melee/Scripts/config.lua"), "Config.HitStop = 200\n"), "an edit in the in-game menu reaches the module through the loader's loop and is written into the module's config.lua")
    shutdown(c)

    -- switched off in the megamod's own settings
    T.write(root .. "/modules/melee/Scripts/config.lua", ALL)
    T.write(root .. "/Scripts/config.lua", T.config("Config.Modules = { Melee = false }"))
    c = boot()
    c.looks(4)
    check(has(last(c), "loaded: melee off |") and c.world.sloppy() == true and untouched(c.world) and c.mods.store["SMM:index"] == nil and sum(c.world.calls) == 0,
        "Config.Modules.Melee = false: the module is not loaded, nothing is changed, no page is registered with the in-game menu")
    shutdown(c)

    -- diagnostics off: the module runs as on its own
    T.write(root .. "/Scripts/config.lua", T.config('Config.Diagnostics = { Level = "off" }'))
    c = boot()
    c.looks(2)
    check(printed(c.ue, "melee ok | diagnostics off") ~= nil and c.world.sloppy() == false and freezesAt(c.world, 0.5) and shakesAre(c.world, true) and #c.ue.errors == 0,
        "diagnostics off: all three are set, no error")
    shutdown(c)

    -- the game is not as the module expects: through the loader that is no error either
    os.remove(root .. "/Scripts/config.lua")
    T.sh("cp " .. T.q(MOD .. "Scripts/config.lua") .. " " .. T.q(root .. "/Scripts/config.lua"))
    c = boot({ noOption = true, noSettingsClass = true, noFeedback = true })
    c.looks(80)
    check(c.world.sloppy() == true and untouched(c.world) and #c.ue.errors == 0 and c.ue:fireConsole("g1r diag") == true, "a game without the option object, the settings class and the feedback object: nothing is changed, no error")
    report = T.read(c.dir .. "/report-latest.txt") or ""
    check(has(report, "melee.flow.way = none (the game's settings class was not found)") and has(report, "melee.feedback = not found") and has(report, "count: 0 (0 distinct)")
        and has(report, "[melee] flow helper: wanted off, but left as the game has it (the game's settings class was not found)") and has(report, "[melee] nothing left to do: the game is not looked at"),
        "report: the notes and the status say what was not found")
    check(has(report, "3 not found, 0 repeated after not found"), "report: three searches in vain, none of them repeated")
    shutdown(c)

    -- a loader without its kit: the module says what it needs
    os.remove(root .. "/Scripts/core/kit.lua")
    c = boot()
    check(c.ok and printed(c.ue, "[G1R_MegaMod] core/kit.lua could not be used") ~= nil
        and printed(c.ue, "[G1R_Melee] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started") ~= nil,
        "core/kit.lua missing: the loader says so, the module says what it needs and does not start")
    c.looks(8)
    check(c.world.sloppy() == true and untouched(c.world) and #c.ue.errors == 0 and not has(table.concat(c.ue.printed), "failed to load"), "nothing is changed, no error")
    shutdown(c)
end

-- ---------------------------------------------------------------------------
section("16. the Lua mods are loaded again while the game runs: tables an earlier run left changed are left alone")
-- (Added by the review.) A reload of the Lua mods starts the module anew in the same game: the tables of the
-- feedback object still hold what the run before wrote, and a run that took those numbers for the game's own would
-- halve a halved hit stop again. UE4SS shared variables outlive the reload (facts K10; upstream LuaMod.hpp: a static
-- map of the DLL): the module keeps the names of the tables that may hold its values there.
do
    local GUARD = "G1R_Melee:tables"
    -- the same game (its objects as they are now), a new run of the Lua mods
    local function again(case, before, config, options)
        options = options or {}
        options.config = config
        if options.shared == nil then options.shared = before.mods and before.mods.store or nil end
        options.prepare = function(ue)
            for path, o in pairs(before.ue.objects) do ue.objects[path] = o end
            for class, o in pairs(before.ue.firstOf) do ue.firstOf[class] = o end
            for class, list in pairs(before.ue.allOf) do ue.allOf[class] = list end
            return before.world
        end
        return start(case, options)
    end
    local STALE_LINE = "[G1R_Melee] the Lua mods were reloaded while values of the mod were in the game's tables (m_AttackFreezeParams, m_HitFreezeParams): "
        .. "what the game had there is no longer known, so they are left as they are - restart the game to change them again\n"
    local STUCK = "|hit stop: values of the mod may still be in the game (m_AttackFreezeParams: the Lua mods were reloaded while values of the mod were in it) - restart the game to be safe|"

    -- the first run: what it keeps in the shared variable
    local first = start("reload-first", { config = OFF })
    local w = first.world
    first.seconds(10)
    check(w.sloppy() == false and first.mods.store[GUARD] == nil, "only the flow helper is set: no table holds a value of the module, the shared variable is not written at all")
    local sets, set = 0, first.mods.SetSharedVariable
    first.mods.SetSharedVariable = function(self, name, value)
        if name == GUARD then sets = sets + 1 end
        return set(self, name, value)
    end
    reload(first, 'Config.FlowHelper = "off"\nConfig.HitStop = 50')
    first.ticks(1)
    check(freezesAt(w, 0.5) and first.mods.store[GUARD] == "m_AttackFreezeParams,m_HitFreezeParams" and sets == 1,
        "the hit stop is set: the names of its two tables are kept in a UE4SS shared variable, at the look that wrote them")
    first.seconds(90)
    check(sets == 1, "written when the list changes, not at every look (a minute and a half of looks and readings: no further write)")
    reload(first, 'Config.FlowHelper = "off"\nConfig.HitStop = 50\nConfig.HitShake = false')
    first.ticks(1)
    check(first.mods.store[GUARD] == "m_AttackFreezeParams,m_HitFreezeParams,m_AttackCameraShakeParams,m_HitCameraShakeParams" and sets == 2, "the camera shake too: four names")
    reload(first, 'Config.FlowHelper = "off"\nConfig.HitShake = false')
    first.ticks(1)
    check(freezesAt(w, 1, true) and first.mods.store[GUARD] == "m_AttackCameraShakeParams,m_HitCameraShakeParams" and sets == 3, "the hit stop back at 100: its tables have the game's numbers and leave the list")
    reload(first, 'Config.FlowHelper = "off"')
    first.ticks(1)
    check(untouched(w) and first.mods.store[GUARD] == "" and sets == 4, "everything back: the list is empty")
    reload(first, 'Config.FlowHelper = "off"\nConfig.HitStop = 50')
    first.ticks(1)
    check(freezesAt(w, 0.5) and first.mods.store[GUARD] == "m_AttackFreezeParams,m_HitFreezeParams", "(the hit stop at 50 % again; then the Lua mods are reloaded)")
    stop(first)

    -- the second run, same settings: the tables are not read as the game's own
    local c = again("reload-same", first, T.config('Config.FlowHelper = "off"\nConfig.HitStop = 50'), { diag = true })
    local ue, S = c.ue, c.S
    check(printedCount(ue, STALE_LINE) == 1 and #ue.printed == 2, "the second run finds the two names: said in one line when it loads")
    check(S.stale.m_AttackFreezeParams ~= nil and S.stale.m_HitFreezeParams ~= nil and S.stale.m_AttackCameraShakeParams == nil and S.stale.m_HitCameraShakeParams == nil,
        "the two tables are marked for this run, the camera shake tables are not")
    local walks, writes = w.walks, w.fieldWrites
    c.seconds(60)
    check(freezesAt(w, 0.5) and w.fieldWrites == writes and w.walks == walks, "the hit stop stays half the game's (it is not halved again): the tables are neither read nor written")
    check(w.sloppy() == false and c.S.looks == 20, "the flow helper is looked after as usual")
    check(has(status(c), STUCK) and has(status(c), "|camera shake on hits: as the game has it|"), "the status says that values of the mod are in the game and that a restart is needed")
    local dump = c.fake.dump[1]()
    check(dump.tables_left_alone.m_AttackFreezeParams == "the Lua mods were reloaded while values of the mod were in it" and dump.tables_left_alone.m_HitFreezeParams ~= nil
        and dump.tables_left_alone.m_AttackCameraShakeParams == nil and next(dump.tables_in_hand) == nil, "so does the dump")
    -- no setting brings them back into the module's hands in this run
    reload(c, 'Config.FlowHelper = "off"\nConfig.HitStop = 200')
    c.seconds(4)
    reload(c, 'Config.Enabled = false\nConfig.HitStop = 200')
    c.seconds(4)
    reload(c, 'Config.FlowHelper = "off"\nConfig.HitStop = 100')
    c.seconds(4)
    reload(c, 'Config.FlowHelper = "off"\nConfig.HitStop = 50')
    c.seconds(40)
    check(freezesAt(w, 0.5) and w.fieldWrites == writes and w.walks == walks and printedCount(ue, "the Lua mods were reloaded") == 1 and printed(ue, "changed in the game: hit stop") == nil,
        "the hit stop set to 200, the module off and on, 100, 50: the tables are not touched in this run; not said twice")
    check(has(status(c), STUCK) and c.mods.store[GUARD] == "m_AttackFreezeParams,m_HitFreezeParams", "the status keeps saying so; the names stay in the shared variable")
    -- the other kind is the module's as ever
    reload(c, 'Config.FlowHelper = "off"\nConfig.HitStop = 50\nConfig.HitShake = false')
    c.ticks(1)
    check(shakesAre(w, true) and freezesAt(w, 0.5) and w.fieldWrites == writes and c.mods.store[GUARD] == "m_AttackFreezeParams,m_HitFreezeParams,m_AttackCameraShakeParams,m_HitCameraShakeParams",
        "the camera shake, which the run before had not changed, is switched off as usual; its tables join the list")
    reload(c, 'Config.FlowHelper = "off"\nConfig.HitStop = 50')
    c.ticks(1)
    check(shakesAre(w, false) and c.mods.store[GUARD] == "m_AttackFreezeParams,m_HitFreezeParams" and #ue.errors == 0 and w.escaped == 0,
        "and switched on again: its tables leave the list, the two of the run before stay in it")
    stop(c)

    -- a third run with neutral settings: still not the module's to put back
    local third = again("reload-neutral", c, shipped, { diag = true })
    check(printedCount(third.ue, STALE_LINE) == 1, "a third run (the shipped settings) is told the same: the names were handed on")
    walks = w.walks
    third.seconds(30)
    check(freezesAt(w, 0.5) and w.walks == walks and third.S.looks == 0 and has(status(third), STUCK) and has(status(third), "|nothing left to do: the game is not looked at|")
        and third.mods.store[GUARD] == "m_AttackFreezeParams,m_HitFreezeParams",
        "with everything neutral it does not look at the game; the status says what is left in the game; the list is kept for a run after it")
    stop(third)

    -- what the shared variable holds is not trusted blindly
    for _, case in ipairs({ { "a number", 5 }, { "names of other things", "m_Something,,x" }, { "an empty text", "" } }) do
        local odd = start("reload-odd", { config = HALF, shared = { [GUARD] = case[2] } })
        odd.ticks(1)
        check(odd.ok and freezesAt(odd.world, 0.5) and next(odd.S.stale) == nil and printed(odd.ue, "the Lua mods were reloaded") == nil and #odd.ue.errors == 0
            and odd.mods.store[GUARD] == "m_AttackFreezeParams,m_HitFreezeParams", "the shared variable holds " .. case[1] .. ": passed over, the module works as usual")
        stop(odd)
    end
    local one = start("reload-one", { config = T.config("Config.HitStop = 50\nConfig.HitShake = false"), shared = { [GUARD] = "x,m_HitCameraShakeParams" } })
    one.ticks(1)
    check(printed(one.ue, "in the game's tables (m_HitCameraShakeParams): what the game had there") ~= nil and freezesAt(one.world, 0.5) and shakesAre(one.world, false)
        and one.mods.store[GUARD] == "m_AttackFreezeParams,m_HitFreezeParams,m_HitCameraShakeParams",
        "a single name: that table is left alone (and with it its kind, which is changed as a whole); the hit stop is set")
    stop(one)

    -- a UE4SS without shared variables: the module works; a reload is then the known limit
    local bare = start("reload-noref", { config = HALF, noModRef = true })
    bare.ticks(1)
    check(bare.ok and freezesAt(bare.world, 0.5) and #bare.ue.errors == 0 and printed(bare.ue, "update error") == nil, "a UE4SS without shared variables: the module works as before")
    stop(bare)
    local bare2 = again("reload-noref-2", bare, HALF, { noModRef = true })
    bare2.ticks(1)
    check(freezesAt(bare2.world, 0.25) and #bare2.ue.errors == 0, "(then a reload of the Lua mods makes it halve the halved numbers - what the shared variable is there to prevent)")
    stop(bare2)
end

T.finish()
