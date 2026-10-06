-- ============================================================================
-- Offline tests of the module mount (modules/mount/Scripts/main.lua).
--
--   lua5.4 harness.lua          (from any directory)
--
-- The module runs on the loader's kit and settings service; ../lib/modtest.lua
-- sets both up the way the loader does and replaces UE4SS by ../mock/ue4ss.lua.
-- The game is the model below: the hero's ability system with its gameplay
-- tags, the game's lookup of a character by its unique name (the default
-- object of GothicNPCState), the scavenger's state with its own ability
-- system, place, routine and character, the two script classes the module
-- asks for, and the HUD with its part that keeps the name widgets (M9).
-- Everything modelled says where it is known from (dev/facts/mount.md);
-- nothing of it has been seen in the game.
-- Last line: "mount tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("mount")
local check, section, has, printed, printedCount = T.check, T.section, T.has, T.printed, T.printedCount

local NPC_CDO = "/Script/G1R.Default__GothicNPCState"
local FEAR = "/Script/Angelscript.GE_Fear"
local IDLE = "/Script/Angelscript.DailyRoutine_Scavenger_Rideable_Idle"

-- ---------------------------------------------------------------------------
-- The game model
-- ---------------------------------------------------------------------------
local function tagText(tag) return type(tag) == "table" and tag.TagName and tag.TagName.__s or nil end

-- options: noMount (the lookup finds nothing), noLookup (no default object), lookupRaises, noFName,
--          tagsRaise (HasGameplayTag raises), dead, removed, mountFar (cm), heroTags, mountTags,
--          removeTagFails, fearRemovalFails, routineRaises, noFearClass, noIdleClass;
--          the HUD (M9): noHud, partsRaise (the HUD's list cannot be walked), noWidgetList, widgetsRaise,
--          widgetFirst (the widget list maps widget -> character), byState (the list's other object is the
--          scavenger's state), byComponent (a part of its character), noGetCharacter (only PawnPrivate),
--          nameReadRaises, nameTextRaises (the text read cannot be turned into a string), nameSetRaises,
--          nameNoKeep (the text block does not keep a text), noTextLibrary, noNamePart (the HUD's list has no
--          name part), brokenPart (an entry of the HUD's list without an address), noPartObjects (the search
--          among all objects finds none).
--          While a case runs: world.names (the entries of the widget list), world.nameWidget(n, character, text).
local function newWorld(ue, o)
    o = o or {}
    local world = T.newWorld(ue, {})
    world.hero.tags = {}
    for _, t in ipairs(o.heroTags or {}) do world.hero.tags[t] = true end
    world.calls = {}
    local function called(name) world.calls[name] = (world.calls[name] or 0) + 1 end
    -- the hero's ability system: HasGameplayTag / RemoveTag (M3; regen's facts G7, G8)
    rawset(world.hero.component, "HasGameplayTag", function(self, tag)
        called("hero:HasGameplayTag")
        if o.tagsRaise then error("invalid receiver") end
        if o.tagsText then return "yes" end
        return world.hero.tags[tagText(tag)] == true
    end)
    rawset(world.hero.component, "RemoveTag", function(self, tag)
        called("hero:RemoveTag")
        if not o.removeTagFails then world.hero.tags[tagText(tag)] = nil end
    end)
    -- where the hero stands
    world.heroAt = { X = 1000, Y = 2000, Z = 0 }
    rawset(world.pawn, "K2_GetActorLocation", function() return { X = world.heroAt.X, Y = world.heroAt.Y, Z = world.heroAt.Z } end)
    -- the scavenger: its state, its ability system with tags, its place, its routine
    local m = { tags = {}, routine = nil, dead = o.dead == true, removed = o.removed == true }
    for _, t in ipairs(o.mountTags or {}) do m.tags[t] = true end
    m.at = { X = world.heroAt.X + (o.mountFar or 400), Y = world.heroAt.Y + (o.mountSide or 0), Z = 0 }
    if o.noPlace then rawset(world.pawn, "K2_GetActorLocation", function() return nil end) end
    m.component = ue:object("GothicAbilitySystemComponent /Game/Maps/World.World:PersistentLevel.GothicNPCState_77.AbilitySystemComponent", {
        HasGameplayTag = function(self, tag)
            called("mount:HasGameplayTag")
            if o.tagsRaise then error("invalid receiver") end
            return m.tags[tagText(tag)] == true
        end,
        RemoveActiveGameplayEffectBySourceEffect = function(self, class, instigator, stacks)
            called("mount:RemoveActiveGameplayEffectBySourceEffect")
            world.fearRemoval = { class = class, instigator = instigator, stacks = stacks }
            if not o.fearRemovalFails and class == ue.objects[FEAR] then m.tags["Debuff.Fear"] = nil end
        end,
    })
    m.state = ue:object("GothicNPCState /Game/Maps/World.World:PersistentLevel.GothicNPCState_77", {
        AbilitySystemComponent = m.component,
        GetCharacterLocation = function() return { X = m.at.X, Y = m.at.Y, Z = m.at.Z } end,
        IsDead = function() return m.dead end,
        GetRemovedFromWorld = function() return m.removed end,
        ExchangeDailyRoutineToClass = function(self, class)
            called("mount:ExchangeDailyRoutineToClass")
            if o.routineRaises then error("no routine") end
            m.routine = class
        end,
    })
    world.mount = m
    -- its character (GetCharacter of the state: DISASM, binds; PawnPrivate: usmap)
    m.character = ue:object("BP_Scavenger_Adult_Rideable_C /Game/Maps/World.World:PersistentLevel.BP_Scavenger_Adult_Rideable_C_3", {})
    if not o.noGetCharacter then rawset(m.state, "GetCharacter", function() return m.character end) end
    rawset(m.state, "PawnPrivate", m.character)
    -- the HUD (M9): MyHUD -> m_Controllers (soft class reference -> part) -> the name part -> m_Widgets
    local function mapOf(name, entries, raises, softKeys)
        return {
            ForEach = function(self, f)
                called(name .. ":ForEach")
                if raises() then error(name .. " cannot be walked (test)") end
                for _, e in ipairs(entries) do
                    f({ get = function() if softKeys then error("unsupported property type SoftClassProperty") end return e[1] end },
                      { get = function() return e[2] end })
                end
            end,
        }
    end
    world.names = {}
    function world.nameWidget(n, character, text)
        local w = { text = text, sets = 0 }
        w.block = ue:object("TextBlock /Engine/Transient.GameEngine_0:GothicGameInstance_0.W_DisplayName_GothicFont_C_" .. n .. ".WidgetTree.Text_CharacterName", {
            GetText = function()
                called("name:GetText")
                if o.nameReadRaises then error("GetText failed (test)") end
                if o.nameTextRaises then return { ToString = function() error("ToString failed (test)") end } end
                return { ToString = function() return w.text end }
            end,
            SetText = function(_, t)
                called("name:SetText")
                if o.nameSetRaises then error("SetText failed (test)") end
                w.sets = w.sets + 1
                if not o.nameNoKeep then w.text = t.text end
            end,
        })
        w.widget = ue:object("W_DisplayName_GothicFont_C /Engine/Transient.GameEngine_0:GothicGameInstance_0.W_DisplayName_GothicFont_C_" .. n,
            { Text_CharacterName = w.block })
        w.character = character
        if o.widgetFirst then w.entry = { w.widget, character } else w.entry = { character, w.widget } end
        world.names[#world.names + 1] = w.entry
        return w
    end
    world.namePart = ue:object("HUDDisplayNameGothicFontController /Engine/Transient.GameEngine_0:GothicGameInstance_0.HUDDisplayNameGothicFontController_0", {
        m_PlayerController = world.controller,
        m_Widgets = (not o.noWidgetList) and mapOf("widgets", world.names, function() return o.widgetsRaise or world.widgetsRaise end) or nil,
    })
    world.parts = {
        { "/Script/G1R.HUDCrosshairController", ue:object("HUDCrosshairController /Engine/Transient.GameEngine_0:GothicGameInstance_0.HUDCrosshairController_0", {}) },
        { "/Script/G1R.HUDDisplayNameGothicFontController", world.namePart },
        { "/Script/G1R.HUDMapController", ue:object("HUDMapController /Engine/Transient.GameEngine_0:GothicGameInstance_0.HUDMapController_0", {}) },
    }
    if o.noNamePart then table.remove(world.parts, 2) end
    if o.brokenPart then table.insert(world.parts, 1, { "/Script/G1R.Broken", {} }) end
    world.hud = ue:object("GothicHUD /Game/Maps/World.World:PersistentLevel.GothicHUD_0", {
        m_Controllers = mapOf("parts", world.parts, function() return o.partsRaise end, true),
    })
    if not o.noHud then rawset(world.controller, "MyHUD", world.hud) end
    -- all objects of the part's class (FindAllOf): this controller's first, then the default object and the parts of
    -- two controllers of earlier worlds
    local function oldPart(n)
        return ue:object("HUDDisplayNameGothicFontController /Engine/Transient.GameEngine_0:GothicGameInstance_0.HUDDisplayNameGothicFontController_" .. n,
            { m_PlayerController = ue:object("GothicPlayerControllerBaseBP_C /Game/Maps/Old.Old:PersistentLevel.GothicPlayerControllerBaseBP_C_" .. n, {}) })
    end
    local findAll = rawget(_G, "FindAllOf")       -- (the searches for the part counted on their own: the kit searches too)
    rawset(_G, "FindAllOf", function(class)
        if class == "HUDDisplayNameGothicFontController" then called("search:part") end
        return findAll(class)
    end)
    if not o.noPartObjects then
        ue.allOf["HUDDisplayNameGothicFontController"] = {
            world.namePart,
            ue:object("HUDDisplayNameGothicFontController /Script/G1R.Default__HUDDisplayNameGothicFontController", { m_PlayerController = world.controller }),
            oldPart(9),
            oldPart(11),
        }
    end
    -- the game's lookup by unique name (M2: markers uses it in the game)
    if not o.noLookup then
        ue.objects[NPC_CDO] = ue:object("GothicNPCState " .. NPC_CDO, {
            FindNPCByUniqueName = function(self, ctx, name)
                called("FindNPCByUniqueName")
                if o.lookupRaises then error("bad context") end
                world.lookedUp = { ctx = ctx, name = name and name.__s }
                if o.noMount or (name and name.__s ~= "Scavenger_Adult_Rideable") then return ue:object("None", { __valid = false }) end
                return m.state
            end,
        })
    end
    world.paused = false
    ue.objects["/Script/Engine.Default__GameplayStatics"] = ue:object("GameplayStatics /Script/Engine.Default__GameplayStatics", {
        IsGamePaused = function(_, w) return world.paused end })
    if not o.noFearClass then ue.objects[FEAR] = ue:object("Class " .. FEAR, {}) end
    if not o.noIdleClass then ue.objects[IDLE] = ue:object("Class " .. IDLE, {}) end
    if o.noFName then world.fnameOff = true end
    return world
end

local function boot(case, o, config)
    o = o or {}
    local widgets = o.widgets ~= false
    if o.noTextLibrary then widgets = { missing = "/Script/Engine.Default__KismetTextLibrary" } end
    local ctx = T.boot(case, { module = "mount", hook = "MOUNT_TEST", config = config, diag = o.diag, widgets = widgets,
        prepare = function(ue) return newWorld(ue, o) end })
    if o.noFName then rawset(_G, "FName", nil) end
    return ctx
end
local function whistle(ctx)       -- the game puts Action.CallMount on the hero for 3 s (M3)
    ctx.world.hero.tags["Action.CallMount"] = true
    ctx.ticks(1)
    ctx.ticks(11)
    ctx.world.hero.tags["Action.CallMount"] = nil
end
local function mountAt(ctx, cm) ctx.world.mount.at.X = ctx.world.heroAt.X + cm end

-- ================================================================ load
section("load")
do
    local c = boot("load")
    check(c.ok, "the module loads (" .. tostring(c.err) .. ")")
    check(printed(c.ue, "[G1R_Mount] v1.1.0 loaded: whistles watched, after 8 s put right (full)") ~= nil, "load line: " .. tostring(printed(c.ue, "loaded:")))
    check(c.ue.console.mount ~= nil and c.ue.console.g1r_mount ~= nil, "console words mount / g1r_mount registered")
    check(#c.ue.loops == 2, "its loop and the loader's (" .. #c.ue.loops .. ")")
    c.ticks(8)
    check((c.world.calls["hero:HasGameplayTag"] or 0) >= 8 and (c.world.calls["FindNPCByUniqueName"] or 0) == 0,
        "while nothing happens only the hero's whistle tag is asked for; the scavenger is not looked up")
    T.stop(c)
end

-- ================================================================ a whistle, the scavenger comes
section("a whistle: written down; it comes - nothing is put right")
do
    local c = boot("comes", { mountFar = 3000 })
    whistle(c)
    local line = printed(c.ue, "whistle 1:")
    check(line ~= nil and has(line, "you: riding block no, mounted no | scavenger: 30 m away, fears you no"), "the whistle line: " .. tostring(line))
    check(c.world.lookedUp and c.world.lookedUp.name == "Scavenger_Adult_Rideable" and c.world.lookedUp.ctx == c.world.controller,
        "the scavenger is looked up by its unique name with the player controller as context")
    check(c.hook.state.whistles == 1 and c.hook.state.pending ~= nil, "one whistle, a second look is due")
    mountAt(c, 2500)                       -- 5 m closer
    c.seconds(8)
    local later = printed(c.ue, "whistle 1, 8 s later:")
    check(later ~= nil and has(later, "scavenger: 25 m away"), "the second look 8 s later: " .. tostring(later))
    check((c.world.calls["hero:RemoveTag"] or 0) == 0 and (c.world.calls["mount:ExchangeDailyRoutineToClass"] or 0) == 0 and c.hook.state.fixes == 0,
        "it came closer: nothing is put right")
    check(c.hook.state.pending == nil, "(the whistle is dealt with)")
    local notes = 0
    for _, call in ipairs(c.ui.calls) do if call.name == "SetText" then notes = notes + 1 end end
    check(notes == 0, "no note on screen for a whistle that worked")
    -- a second whistle while it is right here
    mountAt(c, 200)
    whistle(c)
    c.seconds(8)
    check(printed(c.ue, "whistle 2, 8 s later:") ~= nil and c.hook.state.fixes == 0, "whistle 2: it is 2 m away - nothing to put right")
    -- he mounts: nothing to do either
    c.world.hero.tags["State.Mounted"] = true
    mountAt(c, 5000)
    whistle(c)
    c.seconds(8)
    check(c.hook.state.fixes == 0 and has(printed(c.ue, "whistle 3:"), "mounted yes"), "whistle 3 while mounted: nothing to put right")
    T.stop(c)
end

-- the distance is the straight line, and "? m" without a place
do
    local c = boot("side", { mountFar = 3000, mountSide = 4000 })
    whistle(c)
    check(has(printed(c.ue, "whistle 1:"), "scavenger: 50 m away"), "the distance is the straight line (30 / 40 -> 50 m)")
    T.stop(c)
    c = boot("noplace", { mountFar = 3000, noPlace = true })
    whistle(c)
    check(has(printed(c.ue, "whistle 1:"), "scavenger: ? m away"), "without the hero's place: ? m")
    c.seconds(8)
    check(c.hook.state.fixes == 0 and #c.ue.errors == 0 and printed(c.ue, "not put right: how far away the scavenger is could not be read") ~= nil
        and (c.world.calls["mount:ExchangeDailyRoutineToClass"] or 0) == 0, "no distance: nothing is done (a working routine is not touched), said")
    T.stop(c)
end

-- ================================================================ it does not come: the riding block
section("it does not come: the riding block is on the hero - full takes it off")
do
    local c = boot("block", { mountFar = 3000, heroTags = { "State.RidingBlocked" }, diag = true })
    whistle(c)
    check(has(printed(c.ue, "whistle 1:"), "you: riding block yes"), "the whistle line names the block")
    c.seconds(8)
    local fixed = printed(c.ue, "put right (after whistle 1):")
    check(fixed ~= nil and has(fixed, "riding block taken off you, scavenger put back to its idle routine - whistle again"), "put right: " .. tostring(fixed))
    check(c.world.hero.tags["State.RidingBlocked"] == nil and (c.world.calls["hero:RemoveTag"] or 0) == 1, "the block is gone from the hero (one RemoveTag)")
    check(c.world.mount.routine == c.ue.objects[IDLE] and (c.world.calls["mount:RemoveActiveGameplayEffectBySourceEffect"] or 0) == 0,
        "the scavenger is put back to its idle routine; no fear to take off")
    check(c.hook.state.fixes == 1 and c.hook.state.fixed.done[1] == "riding block taken off you", "counted")
    local note = nil
    for _, call in ipairs(c.ui.calls) do if call.name == "SetText" then note = call.args and call.args[1] and call.args[1].text end end
    check(note ~= nil and has(tostring(note), "Scavenger: riding block taken off you, scavenger put back to its idle routine - whistle again"), "a note on screen: " .. tostring(note))
    check(c.fake.value("mount.whistle_with_block") == "seen" and c.fake.value("mount.came") == "no" and c.fake.value("mount.block_removed") == "works"
        and c.fake.value("mount.routine_reset") == "works" and c.fake.value("mount.lookup") == "works" and c.fake.value("mount.tags") == "readable",
        "notes: whistle_with_block, came = no, block_removed, routine_reset, lookup, tags")
    T.stop(c)
end

-- ================================================================ safe / off
section("\"safe\" leaves the riding block; \"off\" only writes down")
do
    local c = boot("safe", { mountFar = 3000, heroTags = { "State.RidingBlocked" } }, T.config('Config.AutoFix = "safe"'))
    whistle(c)
    c.seconds(8)
    check(c.world.hero.tags["State.RidingBlocked"] == true and (c.world.calls["hero:RemoveTag"] or 0) == 0, "safe: the block stays")
    check(c.world.mount.routine == c.ue.objects[IDLE] and has(printed(c.ue, "put right (after whistle 1):"), "scavenger put back to its idle routine - whistle again"),
        "safe: the routine is still reset")
    T.stop(c)
    c = boot("off", { mountFar = 3000, heroTags = { "State.RidingBlocked" } }, T.config('Config.AutoFix = "off"'))
    whistle(c)
    c.seconds(8)
    check(printed(c.ue, "whistle 1, 8 s later:") ~= nil and printed(c.ue, "put right") == nil and c.hook.state.fixes == 0
        and (c.world.calls["mount:ExchangeDailyRoutineToClass"] or 0) == 0, "off: both lines, nothing done")
    check(printed(c.ue, "loaded: whistles watched, after 8 s only written down") ~= nil, "load line says so")
    T.stop(c)
end

-- ================================================================ fear
section("it does not come: it fears the hero")
do
    local c = boot("fear", { mountFar = 4000, mountTags = { "Debuff.Fear" }, diag = true })
    whistle(c)
    check(has(printed(c.ue, "whistle 1:"), "scavenger: 40 m away, fears you yes"), "the whistle line names the fear")
    mountAt(c, 6000)                       -- it runs away
    c.seconds(8)
    local fixed = printed(c.ue, "put right (after whistle 1):")
    check(fixed ~= nil and has(fixed, "fear taken off the scavenger, scavenger put back to its idle routine - whistle again"), "put right: " .. tostring(fixed))
    check(c.world.fearRemoval and c.world.fearRemoval.class == c.ue.objects[FEAR] and c.world.fearRemoval.instigator == nil and c.world.fearRemoval.stacks == -1,
        "the fear effect is removed by its class, no instigator, all stacks")
    check(c.world.mount.tags["Debuff.Fear"] == nil and (c.world.calls["hero:RemoveTag"] or 0) == 0, "the fear is gone; the hero's tags were not touched")
    check(c.fake.value("mount.fear_removed") == "works", "note mount.fear_removed = works")
    T.stop(c)
end

-- ================================================================ nothing to put right
section("not found, dead, removed")
do
    local c = boot("nomount", { noMount = true })
    whistle(c)
    check(has(printed(c.ue, "whistle 1:"), "scavenger: not in the world"), "the whistle line: not in the world")
    c.seconds(8)
    check(printed(c.ue, "not put right: the scavenger was not found and you carry no riding block") ~= nil and c.hook.state.fixes == 0, "not found, no block: nothing done, said")
    T.stop(c)
    c = boot("nomount-block", { noMount = true, heroTags = { "State.RidingBlocked" } })
    whistle(c)
    c.seconds(8)
    check(c.world.hero.tags["State.RidingBlocked"] == nil and has(printed(c.ue, "put right (after whistle 1):"), "riding block taken off you - whistle again"),
        "not found, but the block is on the hero: the block is taken off")
    local note = nil
    for _, call in ipairs(c.ui.calls) do if call.name == "SetText" then note = call.args[1] and call.args[1].text end end
    check(note == "Scavenger: riding block taken off you - whistle again", "a note for the one thing done: " .. tostring(note))
    T.stop(c)
    c = boot("dead", { mountFar = 3000, dead = true })
    whistle(c)
    check(has(printed(c.ue, "whistle 1:"), "scavenger: 30 m away, dead, fears you no"), "a dead scavenger is named as dead")
    c.seconds(8)
    check((c.world.calls["mount:ExchangeDailyRoutineToClass"] or 0) == 0 and has(printed(c.ue, "put right (after whistle 1):"), "put right (after whistle 1): nothing to put right - you:"),
        "dead: its routine is not touched - nothing to put right")
    local notes = 0
    for _, call in ipairs(c.ui.calls) do if call.name == "SetText" then notes = notes + 1 end end
    check(notes == 0, "and no note on screen")
    local dev = c.ue.device
    c.ue:fireConsole("mount fix")
    check(has(dev.lines[#dev.lines], "nothing was put right"), "console fix with nothing to do: " .. tostring(dev.lines[#dev.lines]))
    T.stop(c)
end

-- ================================================================ what the game refuses
section("what cannot be done is said once; the module runs on")
do
    local c = boot("remove-fails", { mountFar = 3000, heroTags = { "State.RidingBlocked" }, removeTagFails = true, diag = true })
    whistle(c)
    c.seconds(8)
    check(has(printed(c.ue, "put right (after whistle 1):"), "the riding block could not be taken off you (it is still there)")
        and c.fake.value("mount.block_removed") == "fails", "RemoveTag leaves the tag: said, noted")
    T.stop(c)
    c = boot("routine-raises", { mountFar = 3000, mountTags = { "Debuff.Fear" }, routineRaises = true, fearRemovalFails = true, diag = true })
    whistle(c)
    c.seconds(8)
    local line = printed(c.ue, "put right (after whistle 1):")
    check(has(line, "fear could not be taken off the scavenger (it is still there)") and has(line, "the scavenger's routine could not be changed (") and has(line, "no routine)"),
        "fear removal and the routine fail: both said - " .. tostring(line))
    check(c.fake.value("mount.fear_removed") == "fails" and c.fake.value("mount.routine_reset") == "fails", "noted")
    T.stop(c)
    c = boot("no-classes", { mountFar = 3000, mountTags = { "Debuff.Fear" }, noFearClass = true, noIdleClass = true, diag = true })
    whistle(c)
    c.seconds(8)
    line = printed(c.ue, "put right (after whistle 1):")
    check(has(line, "put right (after whistle 1): the fear effect's class was not found; the idle routine's class was not found") and not has(line, "whistle again"),
        "classes not found: said, nothing else - " .. tostring(line))
    check(c.fake.value("mount.fear_removed") == "not available" and c.fake.value("mount.routine_reset") == "not available", "noted as not available")
    T.stop(c)
    -- the lookup fails three times: given up, said once
    c = boot("lookup-raises", { lookupRaises = true, diag = true })
    for _ = 1, 3 do whistle(c); c.seconds(8) end
    check(printedCount(c.ue, "the game's lookup of characters by name fails (") == 1 and printed(c.ue, "bad context") ~= nil and c.hook.state.lookupOff == true
        and c.fake.value("mount.lookup") == "fails", "three failures of the lookup: given up, said once")
    whistle(c)
    check(has(printed(c.ue, "whistle 4:"), "scavenger: lookup given up") and (c.world.calls["FindNPCByUniqueName"] or 0) == 3, "and not tried again")
    local dev = c.ue.device
    c.ue:fireConsole("mount")
    check(#dev.lines == 4 and has(dev.lines[3], "last look: you: riding block no") and dev.lines[4] == "[G1R_Mount] the scavenger cannot be looked up in this run",
        "status: the last look and that the lookup was given up")
    T.stop(c)
    c = boot("no-lookup", { noLookup = true, diag = true })
    whistle(c)
    check(printedCount(c.ue, "the game's lookup of characters by name was not found") == 1 and c.fake.value("mount.lookup") == "not available", "no default object: said once")
    T.stop(c)
    -- the tags cannot be asked: nothing can be done, the loop costs nothing
    c = boot("tags-raise", { tagsRaise = true, diag = true })
    c.ticks(8)
    check(printedCount(c.ue, "gameplay tags cannot be asked for (") == 1 and printed(c.ue, "invalid receiver") ~= nil and c.hook.state.tagsOff == true
        and c.fake.value("mount.tags") == "not readable" and (c.world.calls["hero:HasGameplayTag"] or 0) == 3, "HasGameplayTag raises: given up after 3, said once")
    c.ticks(8)
    check((c.world.calls["hero:HasGameplayTag"] or 0) == 3, "and not asked again")
    T.stop(c)
    local dev = c.ue.device
    c.ue:fireConsole("mount")
    check(#dev.lines == 3 and dev.lines[3] == "[G1R_Mount] gameplay tags cannot be asked for in this run", "status says so in its third line")
    T.stop(c)
    c = boot("tags-text", { tagsText = true, diag = true })
    c.ticks(8)
    check(c.hook.state.tagsOff == true and printedCount(c.ue, "gameplay tags cannot be asked for (the answer was yes)") == 1, "an answer that is no yes/no: given up after 3, said once")
    T.stop(c)
    c = boot("only-no", { diag = true })
    c.ticks(2)
    check(c.fake.value("mount.tags") == "only no so far", "while every question was answered with no: note mount.tags = only no so far")
    T.stop(c)
    c = boot("no-fname", { noFName = true })
    c.ticks(4)
    check(printedCount(c.ue, "gameplay tags cannot be asked for (this UE4SS build has no FName)") == 1 and c.hook.state.tagsOff == true, "no FName: said once, given up")
    T.stop(c)
end

-- ================================================================ console, key, menu, settings
section("console words, the key, the menu buttons, settings")
do
    local c = boot("console", { mountFar = 3000, heroTags = { "State.RidingBlocked" }, mountTags = { "Debuff.Fear" } }, T.config('Config.FixKey = "F9"'))
    check(printed(c.ue, "loaded: whistles watched, after 8 s put right (full), key F9") ~= nil, "the key is in the load line")
    check(#c.kit.keyList() == 1 and c.kit.keyList()[1].key == "F9" and c.kit.keyList()[1].label == "put the scavenger right", "for the list of keys (module keys) the key says what it does")
    local dev = c.ue.device
    check(c.ue:fireConsole("mount") == true and #c.ue.errors == 0, "mount: handled (true is returned)")
    check(#dev.lines == 2 and has(dev.lines[1], "[G1R_Mount] v1.1.0 | whistles watched") and has(dev.lines[2], "whistles seen: 0; put right: 0"), "mount: two status lines")
    dev.lines = {}
    c.hook.console("mount report", nil, dev)
    check(#dev.lines == 1 and has(dev.lines[1], "scavenger: 30 m away, fears you yes"), "the whole line given, no word list: parsed the same")
    local notes = 0
    for _, call in ipairs(c.ui.calls) do if call.name == "SetText" then notes = notes + 1 end end
    check(notes == 1, "mount report shows the line on screen")
    dev.lines = {}
    c.ue:fireConsole("mount report")
    check(#dev.lines == 1 and has(dev.lines[1], "you: riding block yes, mounted no | scavenger: 30 m away, fears you yes"), "mount report: " .. tostring(dev.lines[1]))
    dev.lines = {}
    c.ue:fireConsole("mount fix")
    check(#dev.lines == 1 and has(dev.lines[1], "riding block taken off you, fear taken off the scavenger, scavenger put back to its idle routine - whistle again"),
        "mount fix: " .. tostring(dev.lines[1]))
    check(c.world.hero.tags["State.RidingBlocked"] == nil and c.world.mount.tags["Debuff.Fear"] == nil and c.world.mount.routine == c.ue.objects[IDLE], "and it was done")
    dev.lines = {}
    c.ue:fireConsole("mount fix")
    check(has(dev.lines[1], "scavenger put back to its idle routine - whistle again"), "a second fix: only the routine (nothing else to take off)")
    dev.lines = {}
    c.ue:fireConsole("mount whatever")
    check(has(dev.lines[2], "whistles seen: 0; put right: 2; last: scavenger put back to its idle routine"), "status counts the fixes: " .. tostring(dev.lines[2]))
    -- the key
    c.world.hero.tags["State.RidingBlocked"] = true
    local fired = c.press("F9")
    c.ticks(1)
    check(fired == 1 and c.world.hero.tags["State.RidingBlocked"] == nil and printed(c.ue, "put right (key):") ~= nil, "the key puts it right")
    -- the menu buttons
    c.world.hero.tags["State.RidingBlocked"] = true
    c.hook.settings.onAction("Fix")
    check(c.world.hero.tags["State.RidingBlocked"] == nil and printed(c.ue, "put right (menu):") ~= nil, "the menu button puts it right")
    c.hook.settings.onAction("Report")
    check(printed(c.ue, "report: you: riding block no") ~= nil, "the menu button reports")
    -- settings change: the key moves, the watch can be switched off
    T.write(c.path, T.config('Config.FixKey = "F10"\nConfig.Enabled = false'))
    c.seconds(6)
    check(c.hook.state.key == "F10" and printed(c.ue, "settings changed (config.lua): the whistle is not watched") ~= nil, "settings changed: key F10, not watched")
    c.world.hero.tags["Action.CallMount"] = true
    c.ticks(4)
    check(c.hook.state.whistles == 0, "not watched: a whistle is not seen")
    dev.lines = {}
    c.ue:fireConsole("mount reload")
    check(has(dev.lines[1], "settings read: the whistle is not watched"), "mount reload")
    T.stop(c)
end

-- ================================================================ paused
section("nothing is done while the game is paused")
do
    local c = boot("paused", { mountFar = 3000, heroTags = { "State.RidingBlocked" } })
    whistle(c)
    c.world.paused = true
    c.seconds(12)
    check(c.hook.state.fixes == 0 and printed(c.ue, "8 s later") == nil and c.hook.state.pending ~= nil, "paused after a whistle: no second look, nothing done")
    c.world.paused = false
    c.ticks(1)
    check(c.hook.state.fixes == 1 and printed(c.ue, "whistle 1, 8 s later:") ~= nil, "the game runs again: the look follows at once")
    T.stop(c)
end

-- ================================================================ a world change / loading
section("a map load forgets a pending whistle; a whistle in progress counts once the watch is back")
do
    local c = boot("worldchange", { mountFar = 3000, heroTags = { "State.RidingBlocked" } })
    whistle(c)
    check(c.hook.state.pending ~= nil, "(pending)")
    for _, f in ipairs(c.ue.loadMapPre) do f() end
    check(c.hook.state.pending == nil, "a map load drops the pending whistle")
    c.world.hero.tags["Action.CallMount"] = true     -- (the whistle tag is on while the map loads: counted once the load is over)
    c.ticks(2)
    check(c.hook.state.whistles == 1, "(nothing is seen while the map loads)")
    for _, f in ipairs(c.ue.loadMapPost) do f() end
    c.ticks(2)
    check(c.hook.state.whistles == 2, "a whistle that was on when the load ended is counted")
    c.world.hero.tags["Action.CallMount"] = nil
    T.stop(c)
    c = boot("unwatched", { mountFar = 3000 }, T.config("Config.Enabled = false"))
    c.world.hero.tags["Action.CallMount"] = true
    c.ticks(2)
    T.write(c.path, T.config("Config.Enabled = true"))
    c.seconds(6)
    check(c.hook.state.whistles == 1, "a whistle that is on when the watch is switched on is counted")
    T.stop(c)
end

-- ================================================================ its name (M9)
section("its name: the name widget over the scavenger gets the player's name")
local function nameCfg(name) return T.config(('Config.Name = "%s"'):format(name)) end
local function sets(c) return c.world.calls["name:SetText"] or 0 end
do
    -- the shipped setting: nothing of the HUD is looked at
    local c = boot("name-default")
    c.world.nameWidget(1, c.world.mount.character, "Scavenger")
    c.ticks(12)
    check((c.world.calls["parts:ForEach"] or 0) == 0 and sets(c) == 0 and c.hook.state.name.want == "", "no name set: the HUD is not looked at")
    T.stop(c)

    c = boot("name", { diag = true }, nameCfg("Rex"))
    check(printed(c.ue, "[G1R_Mount] v1.1.0 loaded: whistles watched, after 8 s put right (full); its name: \"Rex\"") ~= nil, "the load line names it: " .. tostring(printed(c.ue, "loaded:")))
    c.ticks(4)
    check((c.world.calls["parts:ForEach"] or 0) == 4 and (c.world.calls["widgets:ForEach"] or 0) == 4 and (c.world.calls["FindNPCByUniqueName"] or 0) == 0,
        "no name widget shown: the HUD's list and the widget list are walked at every look, the scavenger is not looked up")
    check(c.fake.value("mount.name_hud") == "found" and c.fake.value("mount.name_way") == "the HUD's list", "notes: the name part found through the HUD's list")
    local wild = c.world.nameWidget(1, c.ue:object("GothicCharacter_C /Game/Maps/World.World:PersistentLevel.BP_Scavenger_Adult_C_12", {}), "Scavenger")
    local own = c.world.nameWidget(2, c.world.mount.character, "Scavenger")
    c.ticks(1)
    check(own.text == "Rex" and wild.text == "Scavenger" and own.sets == 1 and wild.sets == 0, "its widget shows \"Rex\"; the wild scavenger's keeps the game's name")
    check(c.hook.state.name.rewritten == 0 and c.fake.value("mount.name_rewritten") == nil, "(the first write is no rewrite by the game)")
    check(c.world.lookedUp and c.world.lookedUp.name == "Scavenger_Adult_Rideable", "(the scavenger was looked up by its unique name)")
    check(c.fake.value("mount.name_set") == "works" and c.fake.detail("mount.name_set") == "its character" and c.fake.value("mount.name_entry") == "character -> widget",
        "notes: set, found as its character, the list maps character -> widget")
    check(printedCount(c.ue, "its name: \"Rex\" is shown over the scavenger (the game's own: \"Scavenger\"; found as its character)") == 1, "said once in the log")
    c.ticks(8)
    check(sets(c) == 1 and own.text == "Rex", "while it shows the name nothing is written again")
    own.text = "Scavenger"                        -- the game writes its own again
    c.ticks(1)
    check(own.text == "Rex" and c.hook.state.name.rewritten == 1 and c.fake.value("mount.name_rewritten") == "seen", "the game wrote its own again: put back, counted, noted")
    check(printedCount(c.ue, "is shown over the scavenger") == 1, "(not said again)")
    local dev = c.ue.device
    c.ue:fireConsole("mount")
    check(dev.lines[3] == "[G1R_Mount] its name: \"Rex\", written 2 time(s); the game wrote its own again 1 time(s)", "the status names it: " .. tostring(dev.lines[3]))
    -- another name
    T.write(c.path, nameCfg("Max"))
    c.seconds(6)
    check(own.text == "Max" and wild.text == "Scavenger" and c.hook.state.name.original == "Scavenger" and c.hook.state.name.rewritten == 1,
        "another name: shown; the game's own is still known as \"Scavenger\"")
    check(printed(c.ue, "settings changed (config.lua): whistles watched, after 8 s put right (full); its name: \"Max\"") ~= nil, "the change is logged")
    -- no name: the game's own back, then nothing is looked at any more
    T.write(c.path, nameCfg(""))
    c.seconds(6)
    check(own.text == "Scavenger" and c.hook.state.name.restored == 1 and c.hook.state.name.written == nil
        and printedCount(c.ue, "its name: the game's own (\"Scavenger\") is back") == 1, "no name: the game's own is put back, said")
    local walks = c.world.calls["parts:ForEach"]
    c.ticks(8)
    check(c.world.calls["parts:ForEach"] == walks and own.text == "Scavenger", "and the HUD is not looked at any more")
    local okDump, dump = pcall(c.fake.dump[1])
    check(okDump and dump.name and dump.name.written == 3 and dump.name.restored == 1 and dump.name.rewritten_by_the_game == 1 and dump.name.given_up == false,
        "the dump holds the counts of the name")
    T.stop(c)
end

-- the name as given: trimmed, control characters as spaces, at most 40 letters
do
    local c = boot("name-text")
    local function want(v) c.hook.settings.values.Name = v; return c.hook.wantedName() end
    check(want("  Rex  ") == "Rex", "outer spaces go")
    check(want("Rex\tthe\nGreat") == "Rex the Great", "control characters become spaces")
    check(want(("a"):rep(45)) == ("a"):rep(40), "45 letters: cut to 40")
    check(want(("a"):rep(40)) == ("a"):rep(40), "40 letters: kept")
    check(want(("\195\164"):rep(45)) == ("\195\164"):rep(40), "letters of two bytes (UTF-8) count as one: cut to 40 letters")
    check(want(("a"):rep(39) .. " bbbb") == ("a"):rep(39), "a cut after a space: the space goes too")
    check(want(42) == "" and want(nil) == "", "not a text: no name")
    T.stop(c)
end

-- the ways the widget list can stand for the scavenger
do
    local c = boot("name-widget-first", { widgetFirst = true, diag = true }, nameCfg("Rex"))
    local own = c.world.nameWidget(1, c.world.mount.character, "Scavenger")
    c.ticks(1)
    check(own.text == "Rex" and c.fake.value("mount.name_entry") == "widget -> character", "a list widget -> character works the same, noted")
    T.stop(c)
    c = boot("name-by-state", { diag = true }, nameCfg("Rex"))
    own = c.world.nameWidget(1, c.world.mount.state, "Scavenger")
    c.ticks(1)
    check(own.text == "Rex" and c.fake.detail("mount.name_set") == "its state", "the list's other object is its state: found as its state")
    T.stop(c)
    c = boot("name-by-component", { diag = true }, nameCfg("Rex"))
    local component = c.ue:object("WidgetComponent /Game/Maps/World.World:PersistentLevel.BP_Scavenger_Adult_Rideable_C_3.NameWidget", {
        GetOwner = function() return c.world.mount.character end })
    own = c.world.nameWidget(1, component, "Scavenger")
    c.ticks(1)
    check(own.text == "Rex" and c.fake.detail("mount.name_set") == "a part of its character", "a part of its character: found through its owner")
    T.stop(c)
    c = boot("name-pawn-private", { noGetCharacter = true, diag = true }, nameCfg("Rex"))
    own = c.world.nameWidget(1, c.world.mount.character, "Scavenger")
    c.ticks(1)
    check(own.text == "Rex" and c.fake.detail("mount.name_set") == "its character", "without GetCharacter: its character through PawnPrivate")
    T.stop(c)
    c = boot("name-wild-only", {}, nameCfg("Rex"))
    local wild = c.world.nameWidget(1, c.ue:object("GothicCharacter_C /Game/Maps/World.World:PersistentLevel.BP_Scavenger_Adult_C_12", {
        GetOwner = function() return c.ue:object("AIController /Game/Maps/World.World:PersistentLevel.AIController_4", {}) end }), "Scavenger")
    c.ticks(8)
    check(wild.text == "Scavenger" and sets(c) == 0 and (c.world.calls["FindNPCByUniqueName"] or 0) == 8, "only a wild scavenger shown: never touched")
    T.stop(c)
    c = boot("name-not-found", { noMount = true }, nameCfg("Rex"))
    own = c.world.nameWidget(1, c.world.mount.character, "Scavenger")
    c.ticks(8)
    check(own.text == "Scavenger" and c.hook.state.name.fails == 0 and not c.hook.state.name.off, "the scavenger not in the world: nothing done, no failure")
    T.stop(c)
end

-- the second way: the HUD's list cannot be walked
do
    local c = boot("name-search", { partsRaise = true, diag = true }, nameCfg("Rex"))
    local own = c.world.nameWidget(1, c.world.mount.character, "Scavenger")
    c.ticks(1)
    check(own.text == "Rex" and c.fake.value("mount.name_way") == "search" and has(c.fake.detail("mount.name_way"), "the HUD's list cannot be walked (")
        and has(c.fake.detail("mount.name_way"), "parts cannot be walked (test))"),
        "the search finds the part of this controller (not the default object, not the one of an old controller); noted with why")
    local searches = c.world.calls["search:part"] or 0
    c.ticks(16)                                   -- 4 s
    local more = (c.world.calls["search:part"] or 0) - searches
    check(more == 2, "at most one search every 2 s (" .. more .. " in 4 s)")
    T.stop(c)
    c = boot("name-search-none", { partsRaise = true, noPartObjects = true, diag = true }, nameCfg("Rex"))
    own = c.world.nameWidget(1, c.world.mount.character, "Scavenger")
    c.ticks(32)                                   -- 8 s: four searches
    check(own.text == "Scavenger" and c.hook.state.name.fails == 0 and not c.hook.state.name.off and c.fake.value("mount.name_hud") == "not found"
        and has(c.fake.detail("mount.name_hud"), "the HUD's list cannot be walked ("), "the search finds nothing: no failure, the note says why")
    T.stop(c)
    c = boot("name-no-part", { noNamePart = true, diag = true }, nameCfg("Rex"))
    own = c.world.nameWidget(1, c.world.mount.character, "Scavenger")
    c.ticks(8)
    check(own.text == "Scavenger" and c.fake.value("mount.name_hud") == "not found" and c.fake.detail("mount.name_hud") == "the HUD has no name part"
        and (c.world.calls["search:part"] or 0) == 0 and c.hook.state.name.fails == 0, "the HUD's list has no name part (yet): nothing done, no search, no failure")
    T.stop(c)
    c = boot("name-broken-part", { brokenPart = true, diag = true }, nameCfg("Rex"))
    own = c.world.nameWidget(1, c.world.mount.character, "Scavenger")
    c.ticks(1)
    check(own.text == "Rex" and c.fake.value("mount.name_way") == "the HUD's list", "an entry of the HUD's list without an address is passed over")
    T.stop(c)
    c = boot("name-no-hud", { noHud = true, diag = true }, nameCfg("Rex"))
    c.ticks(8)
    check(c.fake.value("mount.name_hud") == "not found" and c.fake.detail("mount.name_hud") == "no HUD" and not c.hook.state.name.off and c.hook.state.name.fails == 0,
        "no HUD (main menu): nothing to do, no failure")
    T.stop(c)
end

-- what fails is counted; three in a row: given up, said once
do
    local cases = {
        { "name-set-raises", { nameSetRaises = true }, "SetText failed (test)" },
        { "name-no-keep", { nameNoKeep = true }, "the widget does not keep the text" },
        { "name-read-raises", { nameReadRaises = true }, "the name on the widget cannot be read" },
        { "name-text-raises", { nameTextRaises = true }, "the name on the widget cannot be read" },
        { "name-widgets-raise", { widgetsRaise = true }, "the widget list cannot be walked (", "widgets cannot be walked (test))" },
        { "name-no-list", { noWidgetList = true }, "the name part has no widget list" },
        { "name-no-texts", { noTextLibrary = true }, "texts cannot be made" },
    }
    for _, case in ipairs(cases) do
        local o = case[2]
        o.diag = true
        local c = boot(case[1], o, nameCfg("Rex"))
        local own = c.world.nameWidget(1, c.world.mount.character, "Scavenger")
        c.ticks(2)
        check(not c.hook.state.name.off and c.fake.value("mount.name_set") == "fails" and has(c.fake.detail("mount.name_set"), case[3])
            and has(c.fake.detail("mount.name_set"), case[4] or case[3]),
            case[1] .. ": two failures - not given up yet, noted: " .. tostring(c.fake.detail("mount.name_set")))
        c.ticks(1)
        check(c.hook.state.name.off and printedCount(c.ue, "the scavenger's name cannot be shown (") == 1 and has(printed(c.ue, "the scavenger's name cannot be shown ("), case[3])
            and has(printed(c.ue, "the scavenger's name cannot be shown ("), case[4] or case[3]),
            case[1] .. ": the third - given up, said once")
        local walks = c.world.calls["parts:ForEach"] or 0
        c.ticks(8)
        check((c.world.calls["parts:ForEach"] or 0) == walks and own.text == "Scavenger", case[1] .. ": not looked at again, the game's name stays")
        local dev = c.ue.device
        c.ue:fireConsole("mount")
        check(dev.lines[3] == "[G1R_Mount] its name: given up for this run", case[1] .. ": the status says so")
        T.stop(c)
    end
    -- a success in between starts the count anew
    local c = boot("name-fail-once", { diag = true }, nameCfg("Rex"))
    local own = c.world.nameWidget(1, c.world.mount.character, "Scavenger")
    c.world.widgetsRaise = true
    c.ticks(2)
    c.world.widgetsRaise = false
    c.ticks(1)
    check(own.text == "Rex" and c.hook.state.name.fails == 0, "two failures, then it works: the count starts anew")
    T.stop(c)
end

-- the name emptied while the game's own is shown already: nothing to put back
do
    local c = boot("name-emptied", {}, nameCfg("Rex"))
    local own = c.world.nameWidget(1, c.world.mount.character, "Scavenger")
    c.ticks(1)
    check(own.text == "Rex", "(shown)")
    c.hook.settings.values.Name = ""
    own.text = "Scavenger"                        -- the game wrote its own in the meantime
    c.ticks(1)
    check(sets(c) == 1 and c.hook.state.name.restored == 0 and c.hook.state.name.written == nil and printed(c.ue, "is back") == nil,
        "the game's own is there already: nothing written, nothing said")
    T.stop(c)
end

-- a map load, pause, the whistle watch switched off
do
    local c = boot("name-world", {}, nameCfg("Rex"))
    local own = c.world.nameWidget(1, c.world.mount.character, "Scavenger")
    c.ticks(1)
    check(own.text == "Rex", "(shown)")
    for _, f in ipairs(c.ue.loadMapPre) do f() end
    check(c.hook.state.name.written == nil and c.hook.state.name.original == nil, "a map load forgets what was written (a new HUD has new widgets)")
    c.world.names[1] = nil
    local again = c.world.nameWidget(2, c.world.mount.character, "Scavenger")
    for _, f in ipairs(c.ue.loadMapPost) do f() end
    c.ticks(2)
    check(again.text == "Rex" and c.hook.state.name.original == "Scavenger", "the new widget gets the name")
    T.stop(c)
    c = boot("name-paused", {}, nameCfg("Rex"))
    own = c.world.nameWidget(1, c.world.mount.character, "Scavenger")
    c.world.paused = true
    c.ticks(8)
    check(own.text == "Scavenger" and (c.world.calls["parts:ForEach"] or 0) == 0, "paused: nothing is looked at")
    c.world.paused = false
    c.ticks(1)
    check(own.text == "Rex", "the game runs again: shown")
    T.stop(c)
    c = boot("name-unwatched", {}, T.config('Config.Name = "Rex"\nConfig.Enabled = false'))
    own = c.world.nameWidget(1, c.world.mount.character, "Scavenger")
    c.ticks(2)
    check(own.text == "Rex" and (c.world.calls["hero:HasGameplayTag"] or 0) == 0, "the whistle not watched: the name is still shown (and the whistle is not asked for)")
    check(printed(c.ue, "loaded: the whistle is not watched; its name: \"Rex\"") ~= nil, "the load line says both")
    T.stop(c)
end

-- ================================================================ through the real loader
section("through the loader with the real diagnostics")
do
    local c = boot("loader", { mountFar = 3000, heroTags = { "State.RidingBlocked" }, diag = true })
    whistle(c)
    local okPending, early = pcall(c.fake.dump[1])
    check(okPending and early.pending == true and early.whistles == 1, "the dump between the two looks: pending")
    c.seconds(8)
    local okStatus, status = pcall(c.fake.status[1])
    check(okStatus and type(status) == "table" and has(status[1], "v1.1.0 | whistles watched") and has(status[2], "whistles seen: 1; put right: 1; last: riding block taken off you"),
        "status lines for the report: " .. tostring(okStatus and status[2] or status))
    local okDump, dump = pcall(c.fake.dump[1])
    local Fake = dofile(HERE .. "../markers/diag_fake.lua")
    check(okDump and Fake.plain(dump, 4) and dump.whistles == 1 and dump.fixes == 1 and dump.auto_fix == "full" and dump.tags_readable == true
        and dump.lookup_works == true and dump.last_fix.done[1] == "riding block taken off you", "the dump is plain data and holds the counts")
    check(c.fake.versions[1] == "1.1.0", "the version was handed to the diagnostics")
    T.stop(c)
end

T.finish()
