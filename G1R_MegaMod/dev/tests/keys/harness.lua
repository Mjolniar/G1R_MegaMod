-- ============================================================================
-- Offline tests of the module keys (modules/keys/Scripts/main.lua).
--
--   lua5.4 harness.lua          (from any directory)
--
-- The module runs on the loader's kit and settings service; ../lib/modtest.lua
-- sets both up the way the loader does and replaces UE4SS by ../mock/ue4ss.lua.
-- The game is the model below: the controller's main widget with the stack
-- the pause menu is shown in (dev/facts/keys.md KL1), the pause menu's class,
-- the widgets of the box (../lib/modtest.lua T.widgets), and a Mods folder of
-- the tests with the other mods' settings files as they are on the PC
-- (KL5 - KL9); G1R_MODS is the loader's look at it (KL4).
-- Last line: "keys tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*/)") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("keys")
local check, section, printed, printedCount = T.check, T.section, T.printed, T.printedCount
local NL, CRLF = string.char(10), string.char(13, 10)

local PAUSE_CLASS = "/Script/G1R.PauseMenuWidget"

-- ---------------------------------------------------------------------------
-- A Mods folder of the tests
-- ---------------------------------------------------------------------------
local MODSDIR = T.TMP .. "/Mods"
local FILES = {
    ["SharedModMenu/Scripts/config.lua"] = table.concat({ "-- the keys that open and drive the shared in-game menu", "return {",
        '    -- the key that toggles the menu open/closed', '    menuKey = "F2",', "    keys = {", '        itemPrev = "NUM_EIGHT",', "    },", "}", "" }, NL),
    ["HUDMap/config.txt"] = table.concat({ "# HUD map", "[keys]", "hotkeyworld = N", "hotkeyregion = ", "hotkeymenu = Ctrl+N   # the settings window", "" }, CRLF),
    ["PLuaModLoader/Scripts/Mods/FocusNearbyPickups/FocusNearbyPickups.ini"] = table.concat({ "[FocusNearbyPickups]", "toggleKey=F6", "# a comment line", "corpsesKey=",
        "chestsKey=", "quickLoot=false", "quickLootKey=V", "" }, CRLF),
    ["PLuaModLoader/Scripts/Mods/FocusNearbyPickups/enabled.txt"] = "",
    ["G1R_AutoPickUpItemNative/G1R_AutoPickUpItemNative.ini"] = table.concat({ "; HoldHotkey: Hold to collect", "HoldHotkey=R", "HoldHotkey_Stealing=", "ToggleHotkey=X",
        "ToggleHotkey_Stealing=", "" }, CRLF),
    ["G1R_PutAwayTorchRedux/G1R_PutAwayTorchRedux.ini"] = table.concat({ "; Hotkey: Tap to draw or put away", "Hotkey=T", "" }, CRLF),
    ["mods.txt"] = table.concat({ "; a comment", "BPModLoaderMod : 0", "SharedModMenu : 1", "HUDMap : 1", "OtherMod : 1", "Keybinds : 0", "OtherMod : 1", "" }, CRLF),
}
-- The mods that run (as the loader's look would say); set per case.
local Running
local function writeMods(changes)
    T.sh("rm -rf " .. T.q(MODSDIR) .. " && mkdir -p " .. T.q(MODSDIR))
    local files = {}
    for path, text in pairs(FILES) do files[path] = text end
    for path, text in pairs(changes or {}) do files[path] = text end
    for path, text in pairs(files) do
        if text then
            local dir = (MODSDIR .. "/" .. path):match("^(.*)/[^/]*$")
            T.sh("mkdir -p " .. T.q(dir))
            T.write(MODSDIR .. "/" .. path, text)
        end
    end
end
local function defaultRunning()
    return { SharedModMenu = true, HUDMap = true, PLuaModLoader = true, G1R_AutoPickUpItemNative = true, G1R_PutAwayTorchRedux = true,
        BystanderXP = true, G1R_RenderBridge = true, G1R_ShowItemValueNative = true, G1R_MegaMod = true, OtherMod = true }
end
local ModsService = {
    folder = MODSDIR,
    runs = function(name)
        if type(name) ~= "string" then return false end
        return Running[name] == true
    end,
}

-- ---------------------------------------------------------------------------
-- The game model
-- ---------------------------------------------------------------------------
-- options: noMainWidget, noStack, noClass, isaRaises. While a case runs: world.open(true / false) opens and
-- closes the pause menu, world.options(true) shows the Options page on the same stack, world.main / world.stack.
local function newWorld(ue, o)
    o = o or {}
    local world = T.newWorld(ue)
    world.reads = world.reads or {}
    world.isa = 0
    if not o.noClass then ue.objects[PAUSE_CLASS] = ue:object("Class " .. PAUSE_CLASS, {}) end
    local class = ue.objects[PAUSE_CLASS]
    local function activatable(name, isPause)
        return ue:object(name, { bIsActive = false, IsA = function(self, c)
            world.isa = world.isa + 1
            if o.isaRaises then error("IsA is not there") end
            return isPause and c == class
        end })
    end
    world.pause = activatable("W_PauseMenu_C /Engine/Transient.GameEngine_0:BP_GameInstance_C_0.W_PauseMenu_C_0", true)
    world.page = activatable("W_Options_C /Engine/Transient.GameEngine_0:BP_GameInstance_C_0.W_Options_C_0", false)
    world.stack = ue:object("CommonActivatableWidgetStack /Engine/Transient.W_Player_C_0.WidgetTree.Stack_PauseMenu", { DisplayedWidget = nil })
    world.main = ue:object("W_Player_C /Engine/Transient.W_Player_C_0", { Stack_PauseMenu = (not o.noStack) and world.stack or nil })
    if not o.noMainWidget then world.controller.m_Widget = world.main end
    function world.open(yes)
        if yes then
            world.stack.DisplayedWidget = world.pause
            world.pause.bIsActive = true
        else
            world.pause.bIsActive = false
            world.stack.DisplayedWidget = nil
        end
    end
    function world.options(yes)
        world.pause.bIsActive = not yes
        world.page.bIsActive = yes
        world.stack.DisplayedWidget = yes and world.page or world.pause
    end
    function world.load(during)
        ue:fireLoadMapPre(world.engine or "engine", "world", "url", nil, "")
        if during then during() end
        ue:fireLoadMapPost(world.engine or "engine", "world", "url", nil, "")
    end
    return world
end

local function boot(case, o, config, mods)
    o = o or {}
    writeMods(mods)
    Running = o.running or defaultRunning()
    if o.noMods then rawset(_G, "G1R_MODS", nil) else rawset(_G, "G1R_MODS", ModsService) end
    local c = T.boot(case, { module = "keys", hook = "KEYS_TEST", config = config, diag = o.diag ~= false,
        widgets = o.widgets == nil and true or o.widgets, prepare = function(ue) return newWorld(ue, o) end })
    return c
end
local function stop(c)
    rawset(_G, "G1R_MODS", nil)
    T.stop(c)
end
local function cfg(lines) return T.config(table.concat(lines, NL)) end
local function status(c) return table.concat(c.hook.status(), " | ") end
-- what the box shows now, or nil when it is not up
local function box(c)
    local P = c.kit.panel("keys")
    if not P.shown then return nil end
    local set = c.ui.last("SetText", P.text)
    return set and set.args[1] and set.args[1].text or nil
end
-- a key press, a moment after the one before
local function press(c, key)
    c.ue:advance(1)
    c.press(key)
    c.ticks(1)
end
local LINE = "F3 - list of keys"
local OWN_LINES = "F3 - show or hide this list" .. NL .. "Y - wait 30 minutes"
local OTHERS_LINES = table.concat({ "F2 - the mod menu", "N - the HUD map on / off", "CTRL+N - HUD map settings", "F6 - show what lies nearby",
    "R - hold: pick up items nearby", "X - pick up by itself: on / off", "T - torch: tap to draw or put away, hold to drop", "OtherMod: keys not known" }, NL)
local LOADED = "key F3, its line in the pause menu, with the other mods' keys, letters 10"

-- ================================================================ load
section("load")
do
    local c = boot("load")
    check(c.ok, "the module loads (" .. tostring(c.err) .. ")")
    check(printed(c.ue, "[G1R_Keys] v1.1.0 loaded: " .. LOADED) ~= nil, "load line: " .. tostring(printed(c.ue, "loaded:")))
    check(c.ue.console.keys ~= nil and c.ue.console.g1r_keys ~= nil, "console words keys / g1r_keys registered")
    check(#c.ue.loops == 3 and c.ue.loops[3].ms == 250, "its loop (four times a second), the kit's loop for keys (its key is bound) and the loader's")
    local page = T.menuPage(c, "Key list")
    check(page ~= nil and #page.items == 4 and page.items[1].name == "List of keys" and page.items[2].name == "Key line in the pause menu"
        and page.items[3].name == "Keys of other mods too" and page.items[4].name == "Size of the letters" and page.items[4].kind == "num"
        and page.items[4].min == 8 and page.items[4].max == 16, "in the in-game menu: three switches and the size of the letters (keys are set in the settings app or config.lua)")
    check(c.kit.boundKey("keys:show") == "F3" and #c.kit.keyList() == 1 and c.kit.keyList()[1].label == "show or hide this list", "its key by default: F3, which shows or hides the list")
    c.seconds(5)
    check(c.kit.panel("keys").shown == false and c.ui.created == 0, "the pause menu is closed: no box")
    check(c.fake.value("keys.pause_class") == "found" and c.fake.value("keys.player_widget") == "found" and c.fake.detail("keys.player_widget") == "W_Player_C"
        and c.fake.value("keys.pause_stack") == "found" and c.fake.value("keys.pause_menu") == nil, "noted: the class, the main widget, its pause stack; no open pause menu")
    stop(c)
end

section("load: a schema that cannot be used")
do
    writeMods()
    Running = defaultRunning()
    rawset(_G, "G1R_MODS", ModsService)
    local c = T.boot("badschema", { module = "keys", hook = "KEYS_TEST", diag = true, widgets = true, files = { ["Scripts/schema.lua"] = "return 5" .. NL },
        prepare = function(u) return newWorld(u) end })
    check(c.ok and printed(c.ue, "[G1R_Keys] the settings could not be set up (") ~= nil and printed(c.ue, "); not started") ~= nil
        and #c.ue.loops == 1 and c.ue.console.keys == nil, "a schema that cannot be used: said, nothing registered")
    stop(c)
end

-- ================================================================ the pause menu
section("the pause menu: a line that names the key; the key shows the list")
do
    local c = boot("pause")
    c.kit.bindKey("wait.1", "Y", function() end)
    c.kit.describeKey("wait.1", "wait 30 minutes")
    c.kit.bindKey("mount:fix", "", function() end)
    c.ticks(2)
    c.world.open(true)
    c.ticks(1)
    check(box(c) == LINE, "the pause menu open: one line that names the key: " .. tostring(box(c)))
    check(c.ui.last("AddToViewport").args[1] == 1000 and c.ui.last("SetPosition").args[1].X == 32 and c.ui.last("SetPosition").args[1].Y == 32
        and c.ui.last("SetAlignment").args[1].X == 0 and c.kit.panel("keys").text.Font.Size == 10, "at the top left (32 / 32), on layer 1000, letters of size 10")
    check(c.fake.value("keys.pause_menu") == "open" and c.fake.detail("keys.pause_menu") == "W_PauseMenu_C" and c.fake.value("keys.other_mods") == nil
        and c.hook.state.shows == 0, "noted: the pause menu open; for the line the other mods' files are not read")
    press(c, "F3")
    check(box(c) == OWN_LINES .. NL .. OTHERS_LINES, "the key: the list - this mod's keys with what they do, then the other mods' keys:" .. NL .. tostring(box(c)))
    check(c.hook.state.shows == 1 and c.fake.value("keys.other_mods") == "6"
        and c.fake.detail("keys.other_mods") == "SharedModMenu, HUDMap, FocusNearbyPickups, G1R_AutoPickUpItemNative, G1R_PutAwayTorchRedux, OtherMod", "counted; the six other mods noted")
    local texts = c.ui.count("SetText")
    T.write(MODSDIR .. "/G1R_PutAwayTorchRedux/G1R_PutAwayTorchRedux.ini", "Hotkey=U" .. CRLF)
    c.ticks(8)
    check(c.ui.count("SetText") == texts and T.has(box(c), "T - torch"), "while it is up the list is left as it is (the files are not read again)")
    press(c, "F3")
    check(box(c) == LINE and c.hook.state.shows == 1 and c.ui.created == 1, "the key again: back to the line, in the same box")
    -- displayed, but not active
    c.world.pause.bIsActive = false
    c.ticks(1)
    check(box(c) == nil, "the pause menu shown by its stack but not active: nothing")
    c.world.pause.bIsActive = true
    c.ticks(1)
    check(box(c) == LINE, "active again: the line")
    c.world.open(false)
    c.ticks(1)
    check(box(c) == nil and c.ui.last("SetVisibility", c.kit.panel("keys").widget).args[1] == 1, "the pause menu closed: the line goes")
    c.world.open(true)
    c.ticks(1)
    check(box(c) == LINE and c.hook.state.menus == 3 and c.ui.created == 1, "opened again: the line again, in the same box")
    -- the Options page on the same stack
    c.world.options(true)
    c.ticks(1)
    check(box(c) == nil, "another page on the pause menu's stack: nothing")
    c.world.options(false)
    c.ticks(1)
    check(box(c) == LINE, "back to the pause menu: the line again")
    -- the list asked for in the pause menu stays when the game goes on
    press(c, "F3")
    c.world.open(false)
    c.ticks(2)
    check(box(c) ~= nil and T.has(box(c), "Y - wait 30 minutes"), "the list asked for in the pause menu stays while you play")
    press(c, "F3")
    check(box(c) == nil, "until the key hides it")
    -- a changed file is read anew each time the list comes up
    T.write(MODSDIR .. "/G1R_PutAwayTorchRedux/G1R_PutAwayTorchRedux.ini", "Hotkey=G" .. CRLF)
    press(c, "F3")
    check(T.has(box(c), "G - torch: tap to draw or put away, hold to drop") and c.hook.state.shows == 3, "a mod's settings file is read each time the list comes up")
    press(c, "F3")
    check(status(c) == "v1.1.0 | " .. LOADED .. " | the list came up 3 time(s); the pause menu was seen open 4 time(s)", "status: " .. status(c))
    -- a map load
    c.world.open(true)
    press(c, "F3")
    c.world.load(function()
        c.ticks(2)
        check(c.kit.panel("keys").shown == false, "while a map loads nothing is shown")
    end)
    check(c.hook.state.shown == false and c.hook.state.toggled == false, "a map load: the box is forgotten (the kit forgets it), the key starts anew")
    c.ticks(1)
    check(box(c) == LINE and c.ui.created == 2 and c.hook.state.menus == 6, "after it, with the pause menu open: the line, in a new box, counted as a new opening")
    stop(c)
end

section("the pause menu: what is not there")
do
    local c = boot("nomain", { noMainWidget = true })
    c.world.open(true)
    c.seconds(2)
    check(box(c) == nil and c.fake.value("keys.player_widget") == "not found" and c.fake.detail("keys.player_widget") == "GothicPlayerControllerBaseBP_C", "no main widget: noted, no line")
    stop(c)
    c = boot("nostack", { noStack = true })
    c.world.open(true)
    c.seconds(2)
    check(box(c) == nil and c.fake.value("keys.pause_stack") == "not found" and c.fake.detail("keys.pause_stack") == "W_Player_C", "no pause stack: noted, no line")
    stop(c)
    c = boot("noclass", { noClass = true })
    c.world.options(true)
    c.ticks(1)
    check(box(c) == LINE and c.fake.value("keys.pause_class") == "not found" and c.world.isa == 0, "the class not found: whatever the pause stack shows counts (not asked)")
    stop(c)
    c = boot("isaraises", { isaRaises = true })
    c.world.open(true)
    c.ticks(2)
    check(box(c) == LINE and c.fake.value("keys.pause_class") == "not asked" and T.has(tostring(c.fake.detail("keys.pause_class")), "IsA is not there")
        and printedCount(c.ue, "the pause menu's class cannot be asked") == 1, "IsA cannot be asked: counts as the pause menu, said once")
    stop(c)
    -- no hero
    c = boot("nohero", {})
    c.ue.allOf["GothicPlayerControllerBaseBP_C"] = nil
    c.world.open(true)
    c.seconds(2)
    check(box(c) == nil and c.hook.state.classLooked == false and c.hook.state.menus == 0 and c.fake.value("keys.player_widget") == nil,
        "no hero: nothing is looked at, not even the class; the pause menu does not count as open")
    stop(c)
end

-- ================================================================ the key
section("the key: shows and hides the list while you play")
do
    local c = boot("key", {}, cfg({ 'Config.ListKey = "k"' }))
    check(printed(c.ue, "loaded: key K, its line in the pause menu, with the other mods' keys, letters 10") ~= nil and c.kit.boundKey("keys:show") == "K", "another key (K)")
    c.ticks(1)
    press(c, "K")
    check(box(c) ~= nil and T.has(box(c), "K - show or hide this list"), "pressed: the list comes up, with its own key in it")
    press(c, "K")
    check(box(c) == nil, "pressed again: it goes")
    press(c, "K")
    c.world.load()
    c.ticks(2)
    check(box(c) == nil and c.hook.state.toggled == false, "a map load hides it, and the key starts anew")
    c.world.open(true)
    c.ticks(1)
    check(box(c) == "K - list of keys", "the line in the pause menu names that key")
    -- a key UE4SS does not take: the pause menu shows the whole list
    rawset(_G, "RegisterKeyBind", function() error("refused", 0) end)
    T.write(c.path, cfg({ 'Config.ListKey = "J"' }))
    c.seconds(6)
    check(c.kit.boundKey("keys:show") == "" and printedCount(c.ue, "the key J could not be bound (the key could not be registered (refused)); the pause menu and the console show the whole list") == 1
        and T.has(status(c), "| no key, the list in the pause menu,"), "a key UE4SS refuses: said once, no key")
    check(box(c) ~= nil and T.has(box(c), "F2 - the mod menu") and not T.has(box(c), "list of keys"), "the pause menu shows the whole list then")
    stop(c)

    -- no key at all
    c = boot("nokey", {}, cfg({ 'Config.ListKey = ""' }))
    c.kit.bindKey("wait.1", "Y", function() end)
    c.kit.describeKey("wait.1", "wait 30 minutes")
    check(printed(c.ue, "loaded: no key, the list in the pause menu, with the other mods' keys, letters 10") ~= nil and #c.kit.keyList() == 1, "no key: said so")
    c.world.open(true)
    c.ticks(1)
    check(box(c) == "Y - wait 30 minutes" .. NL .. OTHERS_LINES and c.hook.state.shows == 1, "the pause menu shows the whole list (there is no key to ask for it)")
    c.world.open(false)
    c.ticks(1)
    check(box(c) == nil, "and it goes with the pause menu")
    stop(c)

    -- the key of version 1.0.0 in a file
    c = boot("oldkey", {}, cfg({ 'Config.ShowKey = "K"' }))
    check(c.kit.boundKey("keys:show") == "F3" and c.fake.value("keys.pause_menu") == nil and printed(c.ue, "ShowKey") == nil and #c.ue.errors == 0,
        "the setting ShowKey of version 1.0.0 is accepted and left alone (the key is ListKey's: F3), nothing is said about it")
    stop(c)
end

-- ================================================================ the size of the letters
section("the size of the letters")
do
    local c = boot("size", {}, cfg({ "Config.TextSize = 12" }))
    c.world.open(true)
    c.ticks(1)
    check(box(c) == LINE and c.kit.panel("keys").text.Font.Size == 12 and printed(c.ue, "letters 12") ~= nil, "letters of size 12")
    T.write(c.path, cfg({ "Config.TextSize = 14" }))
    c.seconds(6)
    check(box(c) == LINE and c.kit.panel("keys").size == 14 and c.kit.panel("keys").text.Font.Size == 14 and c.ui.created == 2,
        "changed while the line is up: the box is built anew with the new size and shown again")
    T.write(c.path, cfg({ "Config.TextSize = 30" }))
    c.seconds(6)
    check(c.kit.panel("keys").size == 16, "a size above 16 is 16")
    stop(c)
end

-- ================================================================ settings
section("settings: the other mods, the pause menu, off, a change while it is up")
do
    local c = boot("own", {}, cfg({ "Config.OtherMods = false" }))
    c.world.open(true)
    c.ticks(1)
    press(c, "F3")
    check(box(c) == "F3 - show or hide this list", "the other mods' keys off: this mod's keys only")
    check(printed(c.ue, "this mod's keys only") ~= nil and c.fake.value("keys.other_mods") == nil, "load line says so; the other mods are not looked at")
    T.write(c.path, cfg({ "Config.OtherMods = true" }))
    c.seconds(6)
    check(box(c) ~= nil and T.has(box(c), "F2 - the mod menu"), "switched on while the list is up: it is made anew")
    press(c, "F3")
    T.write(c.path, cfg({ "Config.InPauseMenu = false" }))
    c.seconds(6)
    check(box(c) == nil and printed(c.ue, "settings changed (config.lua): key F3, nothing in the pause menu,") ~= nil, "no line in the pause menu: nothing there")
    press(c, "F3")
    check(box(c) ~= nil and T.has(box(c), "F3 - show or hide this list"), "the key still shows the list")
    T.write(c.path, cfg({ "Config.Enabled = false" }))
    c.seconds(6)
    check(box(c) == nil and printed(c.ue, "settings changed (config.lua): switched off") ~= nil, "switched off")
    stop(c)

    c = boot("disabled", {}, cfg({ "Config.Enabled = false" }))
    c.world.open(true)
    press(c, "F3")
    c.seconds(3)
    check(box(c) == nil and c.fake.value("keys.player_widget") == nil and c.hook.state.classLooked == false and T.searches(c) == 0, "Enabled = false: nothing is looked at, the key does nothing")
    stop(c)

    c = boot("nopause", {}, cfg({ "Config.InPauseMenu = false" }))
    c.world.open(true)
    c.seconds(3)
    check(box(c) == nil and c.fake.value("keys.player_widget") == nil and c.hook.state.classLooked == false, "no line in the pause menu: the pause menu is not looked at")
    stop(c)
end

-- ================================================================ the other mods
section("the other mods: what is read, what is not there")
do
    -- not running, a file that cannot be read, the quick loot key, defaults
    local running = defaultRunning()
    running.HUDMap, running.OtherMod = false, false
    local c = boot("mods", { running = running }, nil, {
        ["G1R_AutoPickUpItemNative/G1R_AutoPickUpItemNative.ini"] = false,
        ["PLuaModLoader/Scripts/Mods/FocusNearbyPickups/FocusNearbyPickups.ini"] = "toggleKey=Gamepad_RightShoulder" .. CRLF .. "quickLoot=true" .. CRLF .. "quickLootKey=V" .. CRLF,
        ["SharedModMenu/Scripts/config.lua"] = "return {" .. NL .. '    menuKey = "",' .. NL .. "}" .. NL,
    })
    local lines = table.concat(c.hook.lines(), NL)
    check(lines == table.concat({ "F3 - show or hide this list", "F2 - the mod menu", "Gamepad_RightShoulder - show what lies nearby",
        "V - take the item you look at", "G1R_AutoPickUpItemNative: keys not known (its settings file cannot be read)",
        "T - torch: tap to draw or put away, hold to drop" }, NL),
        "a mod that does not run is left out; an empty menuKey is F2; a pad button as written; the quick-loot key while quick loot is on; a file that cannot be read is said:" .. NL .. lines)
    stop(c)
    -- a menu key of its own, none at all, quick loot as 1 or yes, a settings file that is a folder
    c = boot("mods2", {}, nil, {
        ["SharedModMenu/Scripts/config.lua"] = "return {" .. NL .. '    -- menuKey = "F9",' .. NL .. '    menuKey = "F4",' .. NL .. '    menuKey = "F5",' .. NL .. "}" .. NL,
        ["PLuaModLoader/Scripts/Mods/FocusNearbyPickups/FocusNearbyPickups.ini"] = "quickLoot=1" .. CRLF .. "quickLootKey=V" .. CRLF,
        ["G1R_PutAwayTorchRedux/G1R_PutAwayTorchRedux.ini"] = false,
    })
    T.sh("mkdir -p " .. T.q(MODSDIR .. "/G1R_PutAwayTorchRedux/G1R_PutAwayTorchRedux.ini"))
    local l2 = table.concat(c.hook.lines(), NL)
    check(T.has(l2, "F4 - the mod menu") and not T.has(l2, "F5") and not T.has(l2, "F9") and T.has(l2, "V - take the item you look at")
        and T.has(l2, "G1R_PutAwayTorchRedux: keys not known (its settings file cannot be read)"),
        "the first line that sets the menu key counts (not a comment); quick loot written as 1; a settings file that is a folder cannot be read:" .. NL .. l2)
    stop(c)
    c = boot("mods3", {}, nil, { ["SharedModMenu/Scripts/config.lua"] = "return {}" .. NL,
        ["PLuaModLoader/Scripts/Mods/FocusNearbyPickups/FocusNearbyPickups.ini"] = "quickLoot = Yes" .. CRLF .. "quickLootKey=V" .. CRLF })
    local l3 = table.concat(c.hook.lines(), NL)
    check(T.has(l3, "F2 - the mod menu") and T.has(l3, "V - take the item you look at"), "no menu key in the file: F2; quick loot written as Yes")
    stop(c)
    c = boot("mods4", {}, nil, { ["PLuaModLoader/Scripts/Mods/FocusNearbyPickups/FocusNearbyPickups.ini"] = "quickLoot=off" .. CRLF .. "quickLootKey=V" .. CRLF })
    check(not T.has(table.concat(c.hook.lines(), NL), "take the item"), "quick loot off: its key is not listed")
    stop(c)
    -- the PLuaModLoader child without its enabled.txt
    c = boot("plua", {}, nil, { ["PLuaModLoader/Scripts/Mods/FocusNearbyPickups/enabled.txt"] = false })
    check(not T.has(table.concat(c.hook.lines(), NL), "show what lies nearby"), "a PLuaModLoader child without enabled.txt is not running")
    stop(c)
    running = defaultRunning()
    running.PLuaModLoader = false
    c = boot("plua-off", { running = running })
    check(not T.has(table.concat(c.hook.lines(), NL), "show what lies nearby"), "nor is one while PLuaModLoader does not run")
    stop(c)
    -- no mods.txt
    c = boot("nomodstxt", {}, nil, { ["mods.txt"] = false })
    check(not T.has(table.concat(c.hook.lines(), NL), "OtherMod"), "without mods.txt only the mods of the table are looked at")
    stop(c)
    -- mods.txt with a byte order mark, spaces, a line too short
    c = boot("modstxt", {}, nil, { ["mods.txt"] = string.char(239, 187, 191) .. "Other Mod : 1" .. CRLF .. "AB:1" .. CRLF .. "ABC:1" .. CRLF .. "SharedModMenu : 1" .. CRLF })
    Running.OtherMod, Running.AB, Running.ABC = true, true, true
    local l = table.concat(c.hook.lines(), NL)
    check(T.has(l, "OtherMod: keys not known") and not T.has(l, NL .. "AB: keys") and T.has(l, NL .. "ABC: keys not known") and not T.has(l, "SharedModMenu: keys not known"),
        "mods.txt as UE4SS reads it: a byte order mark, spaces in the name; a line of four characters or fewer is passed over, one of five is not; a mod of the table is not called unknown")
    stop(c)
    -- a G1R_MODS without its function
    c = boot("halfmods", {})
    rawset(_G, "G1R_MODS", nil)
    stop(c)
    writeMods()
    Running = defaultRunning()
    rawset(_G, "G1R_MODS", { folder = MODSDIR })
    c = T.boot("halfmods2", { module = "keys", hook = "KEYS_TEST", diag = true, widgets = true, prepare = function(u) return newWorld(u) end })
    c.ticks(1)
    press(c, "F3")
    check(box(c) == "F3 - show or hide this list" and c.fake.value("keys.other_mods") == "not available", "the loader's look without its function: as without it")
    stop(c)
    -- no G1R_MODS
    c = boot("nomods", { noMods = true })
    c.kit.bindKey("wait.1", "Y", function() end)
    local own = table.concat(c.hook.lines(), NL)
    c.hook.lines()
    check(own == "F3 - show or hide this list" .. NL .. "Y - wait.1" and printedCount(c.ue, "the loader does not say where the other mods are: their keys are not listed") == 1
        and c.fake.value("keys.other_mods") == "not available", "without the loader's look at the Mods folder: this mod's keys only (a key without a description by its name), said once")
    stop(c)
    -- no key of any kind
    c = boot("nokeys", {}, cfg({ 'Config.ListKey = ""', "Config.OtherMods = false" }))
    c.world.open(true)
    c.ticks(1)
    check(box(c) == "no key is set", "no key at all: says so")
    stop(c)
end

-- ================================================================ the box
section("the box: not available, no hero for a moment")
do
    local c = boot("nobox", { widgets = { missing = "/Script/UMG.Border" } })
    c.world.open(true)
    c.ticks(2)
    check(box(c) == nil and c.kit.panel("keys").available() == false and printedCount(c.ue, 'the box "keys" is not available (not found: /Script/UMG.Border)') == 1,
        "the box cannot be built: said once by the kit")
    check(status(c) == "v1.1.0 | " .. LOADED .. " | the list came up 0 time(s); the pause menu was seen open 1 time(s) | the box cannot be shown in this run",
        "status says so: " .. status(c))
    local texts = c.ui.count("SetText")
    press(c, "F3")
    c.seconds(5)
    check(c.hook.state.shows == 0 and c.ui.count("SetText") == texts, "and it is not tried again")
    stop(c)

    c = boot("retry", {})
    c.world.open(true)
    local controller = c.world.controller
    -- the kit gives no hero to the box for a moment: tried again a second later, not at every look
    local P = c.kit.panel("keys")
    local real = P.show
    local tries = 0
    P.show = function(lines)
        tries = tries + 1
        if tries <= 2 then return false end
        return real(lines)
    end
    c.ticks(1)
    check(box(c) == nil and tries == 1, "the box could not be shown: false")
    c.ticks(3)
    check(tries == 1, "not tried again within a second")
    c.ticks(1)
    check(tries == 2, "a second later: tried again")
    c.ticks(4)
    check(tries == 3 and box(c) == LINE and controller ~= nil, "and shown when it can be")
    stop(c)
end

-- ================================================================ console, diagnostics
section("console and diagnostics")
do
    local c = boot("console")
    c.kit.bindKey("wait.1", "Y", function() end)
    c.kit.describeKey("wait.1", "wait 30 minutes")
    check(c.ue:fireConsole("keys") == true and c.ue.device.lines[1] == "[G1R_Keys] v1.1.0 | " .. LOADED
        and c.ue.device.lines[3] == "[G1R_Keys] F3 - show or hide this list" and c.ue.device.lines[4] == "[G1R_Keys] Y - wait 30 minutes", "console: the status and the list")
    local handler = c.ue.console.keys[1]
    local before = #c.ue.printed
    check(handler("keys", { "reload" }, nil) == true and T.has(c.ue.printed[before + 1], "settings read: key F3"), "parameters: reload")
    before = #c.ue.printed
    check(handler("keys reload", nil, nil) == true and T.has(c.ue.printed[before + 1], "settings read: "), "no parameters: the words of the whole line")
    before = #c.ue.printed
    check(handler("keys", nil, nil) == true and T.has(c.ue.printed[before + 1], "[G1R_Keys] v1.1.0 | "), "no parameters, no word: the status")
    check(#c.fake.versions == 1 and c.fake.versions[1] == "1.1.0" and #c.fake.status == 1 and #c.fake.dump == 1, "version, status and dump handed to the diagnostics")
    c.world.open(true)
    c.ticks(1)
    local d = c.fake.dump[1]()
    check(d.version == "1.1.0" and d.shown == true and d.showing == "line" and d.shows == 0 and d.menus == 1 and d.box == true and d.class == true and d.key == "F3"
        and d.size == 10 and d.lines[1] == LINE, "the dump: what is on, what happened, the lines")
    press(c, "F3")
    d = c.fake.dump[1]()
    check(d.showing == "list" and d.shows == 1 and d.lines[2] == "Y - wait 30 minutes", "the dump with the list up")
    check(c.fake.neverRepeated("keys.player_widget") and c.fake.neverRepeated("keys.pause_stack") and c.fake.neverRepeated("keys.pause_menu"), "no note is repeated with the same value")
    stop(c)

    c = boot("nodiag", { diag = false })
    c.world.open(true)
    c.ticks(2)
    check(c.ok and box(c) == LINE, "without diagnostics it works the same")
    stop(c)

    -- broken loop: an error inside is caught and said once
    c = boot("raise")
    c.world.controller.m_Widget = setmetatable({}, { __index = function() error("broken widget") end })
    c.world.open(true)
    c.ticks(1)
    check(box(c) == nil and #c.ue.errors == 0, "a widget that raises when it is read: nothing shown, nothing reaches UE4SS")
    stop(c)
end

section("without the loader")
do
    local ue = T.Mock.new()
    ue:install()
    local ok = pcall(dofile, T.MOD .. "modules/keys/Scripts/main.lua")
    check(ok and T.printed(ue, "[G1R_Keys] this module needs the loader of G1R_MegaMod") ~= nil and #ue.loops == 0, "started on its own: says so, registers nothing")
    ue:uninstall()
    ue = T.Mock.new()
    ue:install()
    rawset(_G, "G1R_KIT", {})
    ok = pcall(dofile, T.MOD .. "modules/keys/Scripts/main.lua")
    check(ok and T.printed(ue, "[G1R_Keys] this module needs the loader of G1R_MegaMod") ~= nil and #ue.loops == 0, "the kit alone: the same")
    rawset(_G, "G1R_KIT", nil)
    ue:uninstall()
end

T.finish()
