-- ============================================================================
-- Test library for the modules that run on the loader's kit and settings
-- service (dev/MODULES.md). A harness looks like this:
--
--   local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
--   local T = dofile(HERE .. "../lib/modtest.lua")
--   T.init("xp")                                   -- suite name
--   local c = T.boot("case-name", { module = "xp", hook = "XP_TEST", config = T.config("Config.Multiplier = 4.0") })
--   c.ticks(4)                                     -- four looks, a quarter second apart
--   T.check(c.world.value("Experience") == 6702, "what the check is about")
--   T.stop(c)
--   T.finish()
--
-- T.boot copies Scripts/core and the module into a temp folder (below
-- G1R_TEST_TMP or /tmp/g1r-tests), installs the UE4SS mock (../mock/ue4ss.lua),
-- builds a small model of the game (a player controller with a player state,
-- an ability system and attribute sets), loads the kit and the settings
-- service the way the loader does, registers the loader's quarter-second loop
-- and runs the module's main.lua. Nothing is written into the mod itself.
-- Needs a POSIX shell (cp, mkdir, rm).
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local MOD = HERE .. "../../../"
local Mock = dofile(HERE .. "../mock/ue4ss.lua")
local Fake = dofile(HERE .. "../markers/diag_fake.lua")

local T = { MOD = MOD, Mock = Mock, oks = 0, fails = 0, suite = "module", TMP = nil }

function T.init(suite)
    T.suite = suite
    T.TMP = (os.getenv("G1R_TEST_TMP") or "/tmp/g1r-tests") .. "/" .. suite
    T.sh("rm -rf " .. T.q(T.TMP) .. " && mkdir -p " .. T.q(T.TMP))
end
function T.check(condition, text)
    if condition then
        T.oks = T.oks + 1
        io.write("ok   ", text, "\n")
    else
        T.fails = T.fails + 1
        io.write("FAIL ", text, "\n")
    end
    return condition
end
function T.section(text) io.write("== ", text, "\n") end
function T.finish()
    io.write(("%s tests finished: %d ok, %d failure(s)\n"):format(T.suite, T.oks, T.fails))
    os.exit(T.fails == 0 and 0 or 1)
end

function T.q(path) return "'" .. path:gsub("'", "'\\''") .. "'" end
function T.sh(command)
    if not os.execute(command) then error("command failed: " .. command) end
end
function T.read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
end
function T.write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end
function T.has(text, plain) return text ~= nil and text:find(plain, 1, true) ~= nil end
function T.printed(ue, plain)
    for _, l in ipairs(ue.printed) do if T.has(l, plain) then return l end end
    return nil
end
function T.printedCount(ue, plain)
    local n = 0
    for _, l in ipairs(ue.printed) do if T.has(l, plain) then n = n + 1 end end
    return n
end
-- A config.lua with these lines.
function T.config(body)
    return "local Config = {}\n" .. (body or "") .. "\nreturn Config\n"
end

-- ---------------------------------------------------------------------------
-- The game model
-- ---------------------------------------------------------------------------
-- An array property as UE4SS hands it out: ForEach(function(index, element)),
-- elements with :get(); returning true ends the loop.
function T.array(items)
    return {
        items = items,
        GetArrayNum = function(self) return #self.items end,
        ForEach = function(self, f)
            for i, v in ipairs(self.items) do
                if f(i, { get = function() return v end }) == true then break end
            end
        end,
    }
end

-- An object that records every method call made on it (ui.calls) and whose
-- unknown methods do nothing. `returns` maps a method name to a function.
function T.recorder(ue, log, fullName, fields, returns)
    local o = ue:object(fullName, fields or {})
    local base = getmetatable(o)
    return setmetatable(o, { __index = function(_, k)
        if base.__index[k] ~= nil then return base.__index[k] end
        if type(k) ~= "string" or k:sub(1, 2) == "__" then return nil end
        return function(self, ...)
            log[#log + 1] = { object = self, name = k, args = { ... } }
            if returns and returns[k] then return returns[k](self, ...) end
            return nil
        end
    end })
end

local function attribute(v) return { BaseValue = v, CurrentValue = v } end

-- A hero: player state number n with attribute sets. `values` gives the
-- attributes, e.g. { Experience = 6702, Level = 4, Health = 80, MaxHealth = 100,
-- Mana = 10, MaxMana = 30 } (those are the defaults).
function T.hero(ue, world, n, values)
    values = values or {}
    local prefix = ("/Game/Maps/World.World:PersistentLevel.GothicPlayerState_%d"):format(n)
    local function set(class, id, fields)
        return ue:object(("AttributeSet_%s %s.AttributeSet_%s_%d"):format(class, prefix, class, id), fields)
    end
    local h = { n = n }
    h.progression = set("LevelProgression", n + 1, {
        Level = attribute(values.Level or 4.0), Experience = attribute(values.Experience or 6702.0),
        SkillPoints = attribute(values.SkillPoints or 0.0) })
    h.health = set("Health", n + 2, { Health = attribute(values.Health or 80.0), MaxHealth = attribute(values.MaxHealth or 100.0) })
    h.mana = set("Mana", n + 3, { Mana = attribute(values.Mana or 10.0), MaxMana = attribute(values.MaxMana or 30.0) })
    h.set = h.progression
    h.component = ue:object("GothicAbilitySystemComponent " .. prefix .. ".AbilitySystemComponent", {
        SpawnedAttributes = T.array({ h.health, h.mana, h.progression }) })
    h.state = ue:object("GothicPlayerState " .. prefix, {})
    world.reads = world.reads or {}
    rawset(h.state, "__component", h.component)
    local meta = getmetatable(h.state)
    setmetatable(h.state, { __index = function(t, k)
        if k == "AbilitySystemComponent" then
            world.reads[n] = (world.reads[n] or 0) + 1      -- how often the state was asked for its ability system
            return rawget(t, "__component")
        end
        return meta.__index[k]
    end })
    return h
end

function T.controllerOf(ue, n, state, fields)
    fields = fields or {}
    fields.PlayerState = state
    return ue:object(("GothicPlayerControllerBaseBP_C /Game/Maps/World.World:PersistentLevel.GothicPlayerControllerBaseBP_C_%d"):format(n), fields)
end

-- A world with a hero. options: values (attributes of the hero), noController.
function T.newWorld(ue, options)
    options = options or {}
    local world = { reads = {} }
    world.hero = T.hero(ue, world, 21, options.values)
    world.pawn = ue:object("GothicCharacter_C /Game/Maps/World.World:PersistentLevel.GothicCharacter_C_7", {})
    world.world = ue:object("World /Game/Maps/World.World", {})
    world.controller = T.controllerOf(ue, 5, world.hero.state, {
        Pawn = world.pawn,
        K2_GetPawn = function() return world.pawn end,
        GetWorld = function() return world.world end,
    })
    world.controllerDefault = ue:object("GothicPlayerControllerBaseBP_C /Game/Blueprints/GothicPlayerControllerBaseBP.Default__GothicPlayerControllerBaseBP_C", {})
    if not options.noController then
        ue.allOf["GothicPlayerControllerBaseBP_C"] = { world.controllerDefault, world.controller }
    end
    local function find(name, who)
        local h = who or world.hero
        for _, s in ipairs({ h.progression, h.health, h.mana }) do
            if rawget(s, name) ~= nil then return s[name] end
        end
        error("the model has no attribute " .. tostring(name))
    end
    -- the game changes an attribute (both values, as an instant effect does)
    function world.add(name, amount, who)
        local a = find(name, who)
        a.BaseValue, a.CurrentValue = a.BaseValue + amount, a.CurrentValue + amount
    end
    function world.set(name, value, who)
        local a = find(name, who)
        a.BaseValue, a.CurrentValue = value, value
    end
    function world.value(name, who) return find(name, who).CurrentValue end
    function world.base(name, who) return find(name, who).BaseValue end
    return world
end

-- The widget side for notes on screen. Every method call on a widget is
-- recorded in ui.calls. options: missing = a path that does not exist,
-- failing = a method name that raises.
function T.widgets(ue, options)
    options = options or {}
    local ui = { calls = {}, created = 0, constructed = 0, subtitles = {} }
    local returns = {
        AddChildToCanvas = function() return T.recorder(ue, ui.calls, "CanvasPanelSlot /Engine/Transient.Slot_" .. #ui.calls) end,
        SetContent = function() return T.recorder(ue, ui.calls, "BorderSlot /Engine/Transient.Slot_" .. #ui.calls) end,
        IsInViewport = function(self) return rawget(self, "__inViewport") == true end,
        AddToViewport = function(self) rawset(self, "__inViewport", true) end,
    }
    if options.failing then
        returns[options.failing] = function() error(options.failing .. " failed (test)") end
    end
    local classes = {
        ["/Script/UMG.UserWidget"] = "Class /Script/UMG.UserWidget",
        ["/Script/UMG.CanvasPanel"] = "Class /Script/UMG.CanvasPanel",
        ["/Script/UMG.Border"] = "Class /Script/UMG.Border",
        ["/Script/UMG.TextBlock"] = "Class /Script/UMG.TextBlock",
    }
    for path, name in pairs(classes) do
        if path ~= options.missing then ue.objects[path] = ue:object(name, {}) end
    end
    if options.missing ~= "/Script/UMG.Default__WidgetBlueprintLibrary" then
        ue.objects["/Script/UMG.Default__WidgetBlueprintLibrary"] = ue:object("WidgetBlueprintLibrary /Script/UMG.Default__WidgetBlueprintLibrary", {
            Create = function(_, context, class, owner)
                ui.created = ui.created + 1
                ui.createArgs = { context, class, owner }
                ui.tree = T.recorder(ue, ui.calls, "WidgetTree /Engine/Transient.UserWidget_" .. ui.created .. ".WidgetTree", nil, returns)
                ui.widget = T.recorder(ue, ui.calls, "UserWidget /Engine/Transient.UserWidget_" .. ui.created, { WidgetTree = ui.tree }, returns)
                return ui.widget
            end,
        })
    end
    if options.missing ~= "/Script/Engine.Default__KismetTextLibrary" then
        ue.objects["/Script/Engine.Default__KismetTextLibrary"] = ue:object("KismetTextLibrary /Script/Engine.Default__KismetTextLibrary", {
            Conv_StringToText = function(_, text) return { text = text } end,
        })
    end
    if options.missing ~= "/Script/G1R.Default__ConversationStatics" then
        ue.objects["/Script/G1R.Default__ConversationStatics"] = ue:object("ConversationStatics /Script/G1R.Default__ConversationStatics", {
            ShowTopSubtitle = function(_, world, title, message, seconds)
                ui.subtitles[#ui.subtitles + 1] = { world = world, title = title and title.text, text = message and message.text, seconds = seconds }
            end,
        })
    end
    ue.globals.StaticConstructObject = function(class, outer)
        ui.constructed = ui.constructed + 1
        local kind = class.__full:match("([%w_]+)$")
        local o = T.recorder(ue, ui.calls, kind .. " /Engine/Transient." .. kind .. "_" .. ui.constructed,
            kind == "TextBlock" and { Font = { Size = 24, TypefaceFontName = "Bold" } } or {}, returns)
        ui[kind] = ui[kind] or {}
        table.insert(ui[kind], o)
        return o
    end
    rawset(_G, "StaticConstructObject", ue.globals.StaticConstructObject)
    function ui.last(name, object)
        for i = #ui.calls, 1, -1 do
            local c = ui.calls[i]
            if c.name == name and (object == nil or c.object == object) then return c end
        end
        return nil
    end
    function ui.count(name)
        local n = 0
        for _, c in ipairs(ui.calls) do if c.name == name then n = n + 1 end end
        return n
    end
    -- the text of the note that is up right now, or nil
    function ui.note()
        local shown = ui.widget and ui.last("SetVisibility", ui.widget)
        if not shown or shown.args[1] ~= 3 then return nil end
        local set = ui.last("SetText")
        return set and set.args[1] and set.args[1].text or nil
    end
    return ui
end

-- UE4SS shared variables: one store for every mod of the process.
function T.shared()
    local store = {}
    return {
        store = store,
        SetSharedVariable = function(_, name, value) store[name] = value end,
        GetSharedVariable = function(_, name) return store[name] end,
    }
end

-- ---------------------------------------------------------------------------
-- Running a module
-- ---------------------------------------------------------------------------
-- options:
--   module     folder name below modules/ (required)
--   hook       name of the global table the module fills for the tests ("XP_TEST")
--   config     text of config.lua (default: the shipped file); false = no file
--   files      { ["relative/path/in/the/module"] = text | false }
--   mock       options of the UE4SS mock
--   prepare    function(ue) -> world (default: T.newWorld(ue))
--   widgets    true or options of T.widgets: the widget side exists (ctx.ui)
--   noModRef   no shared variables
--   shared     { name = value }: shared variables that are there before anything is loaded
--   diag       true: the module (and the kit) get a recording G1R_DIAG (ctx.diag: the module's, ctx.kitDiag)
--   keys       table for the global `Key` (default: A-Z, F1-F12, digits) - RegisterKeyBind is mocked by ../mock
function T.boot(case, options)
    options = options or {}
    local name = assert(options.module, "T.boot needs options.module")
    local root = T.TMP .. "/" .. case .. "/G1R_MegaMod"
    local dir = root .. "/modules/" .. name .. "/Scripts"
    T.sh("rm -rf " .. T.q(T.TMP .. "/" .. case) .. " && mkdir -p " .. T.q(root .. "/Scripts") .. " " .. T.q(root .. "/modules")
        .. " && cp -r " .. T.q(MOD .. "Scripts/core") .. " " .. T.q(root .. "/Scripts/")
        .. " && cp -r " .. T.q(MOD .. "modules/" .. name) .. " " .. T.q(root .. "/modules/"))
    if options.config == false then
        os.remove(dir .. "/config.lua")
    elseif options.config then
        T.write(dir .. "/config.lua", options.config)
    end
    for path, text in pairs(options.files or {}) do
        if text == false then os.remove(root .. "/modules/" .. name .. "/" .. path) else T.write(root .. "/modules/" .. name .. "/" .. path, text) end
    end
    local ue = Mock.new(options.mock)
    ue:install()
    local ctx = { ue = ue, root = root, dir = dir, path = dir .. "/config.lua", case = case }
    if options.widgets then ctx.ui = T.widgets(ue, type(options.widgets) == "table" and options.widgets or nil) end
    if options.prepare then ctx.world = options.prepare(ue) else ctx.world = T.newWorld(ue) end
    if not options.noModRef then
        ctx.mods = T.shared()
        for key, value in pairs(options.shared or {}) do ctx.mods.store[key] = value end
        rawset(_G, "ModRef", ctx.mods)
    end
    if rawget(_G, "Key") == nil then
        local keys = options.keys
        if not keys then
            keys = {}
            for c = string.byte("A"), string.byte("Z") do keys[string.char(c)] = c end
            for i = 1, 12 do keys["F" .. i] = 111 + i end
            ctx.keys = keys
        end
        rawset(_G, "Key", keys)
        rawset(_G, "ModifierKey", { SHIFT = 16, CONTROL = 17, ALT = 18 })
        ctx.ownKey = true
    end
    if options.diag then
        ctx.kitFake, ctx.fake = Fake.new(), Fake.new()
        rawset(_G, "G1R_DIAG", ctx.kitFake.handle)
    end
    ctx.kit = dofile(root .. "/Scripts/core/kit.lua")
    rawset(_G, "G1R_DIAG", nil)
    rawset(_G, "G1R_KIT", ctx.kit)                      -- the settings service asks the kit how keys are spelt
    ctx.settings = dofile(root .. "/Scripts/core/settings.lua")
    -- the loader's own loop for the two services
    if type(rawget(_G, "LoopInGameThreadWithDelay")) == "function" then
        LoopInGameThreadWithDelay(250, function()
            ctx.settings.tick()
            ctx.kit.tick()
        end)
    end
    rawset(_G, "G1R_KIT", ctx.kit)
    rawset(_G, "G1R_SETTINGS", ctx.settings)
    if options.diag then rawset(_G, "G1R_DIAG", ctx.fake.handle) end
    if options.hook then rawset(_G, options.hook, {}) end
    ctx.hookName = options.hook
    ctx.ok, ctx.err = pcall(dofile, dir .. "/main.lua")
    ctx.hook = options.hook and rawget(_G, options.hook) or nil
    function ctx.ticks(n, seconds)
        for _ = 1, n or 1 do
            ue:advance(seconds or 0.25)
            ue:tick()
        end
    end
    function ctx.seconds(n) ctx.ticks(math.floor(n * 4 + 0.5)) end
    -- a key press as UE4SS delivers it (on its own thread), then the next look of every loop
    function ctx.press(combo)
        local _, code, modifiers = ctx.kit.keyCombo(combo)
        assert(code, "unknown key " .. tostring(combo))
        local fired = 0
        for _, k in ipairs(ue.keys) do
            local same = k.key == code and #(k.modifiers or {}) == #modifiers
            for i, m in ipairs(modifiers) do if same and k.modifiers[i] ~= m then same = false end end
            if same then
                k.callback()
                fired = fired + 1
            end
        end
        return fired
    end
    return ctx
end

-- The searches by path of a case, without the kit's own: at the first map load a case fires, the kit looks
-- its own paths up (Kit.paths; dev/tests/core/test_kit.lua, section 17). Returns the number of the others,
-- and the number of the kit's own.
function T.searches(ctx)
    local own = {}
    for _, path in ipairs(ctx.kit.paths or {}) do own[path] = true end
    local others, kits = 0, 0
    for _, path in ipairs(ctx.ue.lookups) do
        if own[path] then kits = kits + 1 else others = others + 1 end
    end
    return others, kits
end

-- ---------------------------------------------------------------------------
-- The in-game mod menu, as the menu mod sees it (shared variables)
-- ---------------------------------------------------------------------------
local function split(text, separator)
    local out, from = {}, 1
    if text == nil or text == "" then return out end
    while true do
        local at = text:find(separator, from, true)
        if not at then
            out[#out + 1] = text:sub(from)
            return out
        end
        out[#out + 1] = text:sub(from, at - 1)
        from = at + 1
    end
end
-- The names registered with the menu, in order.
function T.menuIndex(ctx) return split(ctx.mods.store["SMM:index"], ",") end
-- A page as the menu reads it: { name, sections = { { title, items = { { name, kind, min, max, step, desc,
-- index (position among all items of the page), token (its value as sent), value } } } } }, or nil.
function T.menuPage(ctx, page)
    local name = "G1R " .. page
    local schema = ctx.mods.store["SMM:schema:" .. name]
    if type(schema) ~= "string" or schema == "" then return nil end
    local tokens = split(ctx.mods.store["SMM:values:" .. name], "\30")
    local out = { name = name, sections = {}, items = {} }
    local index = 0
    for _, sectionText in ipairs(split(schema, "\29")) do
        local parts = split(sectionText, "\30")
        local section = { title = parts[1], items = {} }
        for i = 2, #parts do
            local f = split(parts[i], "\31")
            index = index + 1
            local token = tokens[index]
            local value = nil
            if token and token:sub(1, 1) == "b" then value = token:sub(2) == "1"
            elseif token and token:sub(1, 1) == "n" then value = tonumber(token:sub(2)) end
            local item = { name = f[1], kind = f[2], min = tonumber(f[3]), max = tonumber(f[4]), step = tonumber(f[5]), desc = f[6],
                index = index, token = token, value = value, section = section.title }
            section.items[#section.items + 1] = item
            out.items[#out.items + 1] = item
        end
        out.sections[#out.sections + 1] = section
    end
    return out
end
-- The item of a page whose name starts with `label`, or nil.
function T.menuItem(ctx, page, label)
    local p = T.menuPage(ctx, page)
    if not p then return nil end
    for _, item in ipairs(p.items) do
        if item.name:sub(1, #label) == label then return item end
    end
    return nil
end
-- Queues an edit the way the menu does: a boolean, a number, or true for an action. The
-- settings service takes it at its next look (ctx.ticks(1)).
function T.menuSet(ctx, page, label, value)
    local item = assert(T.menuItem(ctx, page, label), "the menu page " .. page .. " has no item " .. label)
    local token = item.kind == "action" and "x" or (type(value) == "boolean" and (value and "b1" or "b0") or ("n" .. tostring(value)))
    local key = "SMM:cmd:G1R " .. page
    local queued = ctx.mods.store[key]
    local record = item.index .. "\31" .. token
    ctx.mods.store[key] = (type(queued) == "string" and queued ~= "") and (queued .. "\30" .. record) or record
    return item
end

-- Ends a case. An error inside a module's loop is caught by the module and only logged ("update error: ..."),
-- and one inside a callback ends up in the mock's list of errors: both are failures of the case unless it
-- says that it provokes them (ctx.expectErrors = true before T.stop).
function T.stop(ctx)
    if not ctx.expectErrors then
        for _, line in ipairs(ctx.ue.printed) do
            if line:find("update error", 1, true) then
                T.check(false, "case " .. tostring(ctx.case) .. ": no error inside the module's loop (" .. line:gsub("%s+$", ""):sub(1, 200) .. ")")
                break
            end
        end
    end
    ctx.ue:uninstall()
    for _, name in ipairs({ "ModRef", "G1R_KIT", "G1R_SETTINGS", "G1R_DIAG", "StaticConstructObject" }) do rawset(_G, name, nil) end
    if ctx.hookName then rawset(_G, ctx.hookName, nil) end
    if ctx.ownKey then
        rawset(_G, "Key", nil)
        rawset(_G, "ModifierKey", nil)
    end
end

return T
