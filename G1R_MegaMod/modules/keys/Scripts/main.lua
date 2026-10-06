-- ============================================================================
-- List of keys (module keys of G1R_MegaMod) - Gothic 1 Remake, UE4SS Lua
--
-- A key of its own (F3 unless set otherwise) shows a small box at the top left
-- that lists the keys of this mod's modules (the kit knows every binding and
-- what it does) and the keys of the other mods it knows, read from their own
-- settings files each time the list comes up; the key hides it again. While
-- the pause menu is open, one small line there names that key (without a key:
-- the whole list).
--
-- The pause menu is looked at afresh at every look, from the controller the
-- kit hands out: its main widget, the stack the pause menu is shown in, the
-- widget that stack shows (KL1). Nothing of the menu is kept from one look to
-- the next (FACTS U17).
--
-- Settings: schema.lua describes them, config.lua holds them; the settings
-- app and the in-game mod menu change them while the game runs.
-- ============================================================================

local VERSION = "1.1.0"
local TAG = "G1R_Keys"

local KIT, SETTINGS, MODS = G1R_KIT, G1R_SETTINGS, G1R_MODS
-- Diagnostics handle of the loader; nil when the diagnostics are off, and then
-- nothing behind `if DIAG` runs.
local DIAG = G1R_DIAG
if type(KIT) ~= "table" or type(SETTINGS) ~= "table" then
    print("[" .. TAG .. "] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started" .. string.char(10))
    return
end
if DIAG then pcall(DIAG.version, VERSION) end

local pcall, type, tostring, ipairs = pcall, type, tostring, ipairs
local clock = KIT.clock
local L = KIT.logger(TAG, print)
local log = L.log

local SCRIPT_DIR = (function()
    local ok, src = pcall(function() return debug.getinfo(1, "S").source end)
    if ok and type(src) == "string" then
        local p = src:gsub("^@", ""):gsub(string.char(92), "/")
        local d = p:match("^(.*/)[^/]+$")
        if d then return d end
    end
    return "./"
end)()

-- ---------------------------------------------------------------------------
-- What the module knows about the game and the other mods (dev/facts/keys.md)
-- ---------------------------------------------------------------------------
local PLAYER_WIDGET = "m_Widget"            -- GothicPlayerControllerBase: the player's main widget (KL1)
local PAUSE_STACK = "Stack_PauseMenu"       -- PlayerWidget: the stack the pause menu is shown in (KL1)
local SHOWN = "DisplayedWidget"             -- CommonActivatableWidgetContainerBase: what the stack shows (KL1)
local ACTIVE = "bIsActive"                  -- CommonActivatableWidget (KL1)
local PAUSE_CLASS = "PauseMenuWidget"       -- /Script/G1R: the pause menu's class (KL1)
local BOX = { position = "top left", dx = 32, dy = 32, z = 1000 }      -- above the pause menu (KL3)
local RETRY = 1.0           -- seconds between two tries to put the list up when it could not be shown

-- The other mods whose keys are known (KL5 - KL9): their settings file below the Mods folder, how it is
-- written ("ini": name = value lines; "lua": name = "value" in a table of plain values), the keys in it and
-- what each does. `default`: what the mod takes when the file names no key; `when`: the key counts only
-- while that setting is on. A mod with no `file` has no keys. `host`: a mod run by another mod (PLuaModLoader
-- starts the folders below its Scripts/Mods that hold an enabled.txt).
local OTHERS = {
    { mod = "SharedModMenu", file = "SharedModMenu/Scripts/config.lua", form = "lua",
      keys = { { name = "menuKey", what = "the mod menu", default = "F2" } } },
    { mod = "HUDMap", file = "HUDMap/config.txt", form = "ini",
      keys = { { name = "hotkeyworld", what = "the HUD map on / off" }, { name = "hotkeyregion", what = "HUD map: region maps off / on" },
               { name = "hotkeymenu", what = "HUD map settings" } } },
    { mod = "FocusNearbyPickups", host = "PLuaModLoader", folder = "PLuaModLoader/Scripts/Mods/FocusNearbyPickups",
      file = "PLuaModLoader/Scripts/Mods/FocusNearbyPickups/FocusNearbyPickups.ini", form = "ini",
      keys = { { name = "toggleKey", what = "show what lies nearby" }, { name = "corpsesKey", what = "show corpses: on / off" },
               { name = "chestsKey", what = "show chests: on / off" }, { name = "quickLootKey", what = "take the item you look at", when = "quickLoot" } } },
    { mod = "G1R_AutoPickUpItemNative", file = "G1R_AutoPickUpItemNative/G1R_AutoPickUpItemNative.ini", form = "ini",
      keys = { { name = "HoldHotkey", what = "hold: pick up items nearby" }, { name = "HoldHotkey_Stealing", what = "hold: pick up items nearby, owned ones too" },
               { name = "ToggleHotkey", what = "pick up by itself: on / off" }, { name = "ToggleHotkey_Stealing", what = "pick up by itself, owned items too: on / off" } } },
    { mod = "G1R_PutAwayTorchRedux", file = "G1R_PutAwayTorchRedux/G1R_PutAwayTorchRedux.ini", form = "ini",
      keys = { { name = "Hotkey", what = "torch: tap to draw or put away, hold to drop" } } },
    { mod = "BystanderXP" }, { mod = "G1R_RenderBridge" }, { mod = "G1R_ShowItemValueNative" }, { mod = "PLuaModLoader" },
    { mod = "G1R_MegaMod" },
}

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local Settings, problem = SETTINGS.open({ module = "keys", dir = SCRIPT_DIR, log = log })
if not Settings then
    log("the settings could not be set up (" .. tostring(problem) .. "); not started")
    return
end
local Cfg = Settings.values

-- ---------------------------------------------------------------------------
-- State of this run
-- ---------------------------------------------------------------------------
local S = {
    shown = false,          -- the list is up
    lines = nil,            -- what it shows
    dirty = false,          -- the list is made anew at the next look (a setting changed while it was up)
    toggled = false,        -- the key asked for the list
    tryAt = 0,              -- when the list may be tried again after it could not be shown
    class = nil, classLooked = false,       -- the pause menu's class (looked up once, at a quiet moment)
    shows = 0, menus = 0,   -- how often the list came up; how often the pause menu was seen open
    menuOpen = false,       -- the pause menu was open at the last look
    key = "",               -- the key that shows the list ("" = none)
    showing = nil,          -- what the box shows: "list" or "line" (the line in the pause menu that names the key)
}
BOX.size = Cfg.TextSize
local Box = KIT.panel("keys", BOX)
local Noted = {}
local function note(key, value, detail)
    if DIAG and Noted[key] ~= value then
        Noted[key] = value
        DIAG.note(key, value, detail)
    end
end

-- ---------------------------------------------------------------------------
-- The lines: this mod's keys, then the other mods'
-- ---------------------------------------------------------------------------
local function readText(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local ok, text = pcall(f.read, f, "a")
    pcall(f.close, f)
    if ok and type(text) == "string" then return text end
    return nil
end
local function exists(path)
    local f = io.open(path, "rb")
    if not f then return false end
    pcall(f.close, f)
    return true
end
-- The value of `name` in a settings file ("" for a name with nothing behind it), or nil when it is not there.
local function valueOf(text, name, form)
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        if form == "lua" then
            local v = line:match("^%s*" .. name .. "%s*=%s*\"([^\"]*)\"")
            if v then return v end
        else
            local key, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if key == name then return (v:gsub("%s*[;#].*$", "")) end
        end
    end
    return nil
end
-- A key as the kit writes it ("Ctrl+N" -> "CTRL+N"); one the kit does not know as the mod has it.
local function keyText(v)
    local usual = KIT.keyCombo(v)
    if type(usual) == "string" and usual ~= "" then return usual end
    return v
end
local function on(v) return v ~= nil and (v:lower() == "true" or v == "1" or v:lower() == "yes") end

-- The names in UE4SS's mods.txt, as UE4SS reads them (lines with a ";" or of four characters or fewer are skipped).
local function namesInModsTxt()
    local text = readText(MODS.folder .. "/mods.txt")
    local names, seen = {}, {}
    if not text then return names end
    for line in (text:gsub("^\239\187\191", "") .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        if not line:find(";", 1, true) and #line > 4 then
            local name = line:gsub(" ", ""):match("^(.[^:]*):")
            if name and not seen[name:lower()] then
                seen[name:lower()] = true
                names[#names + 1] = name
            end
        end
    end
    return names
end

local function otherLines(out)
    if type(MODS) ~= "table" or type(MODS.runs) ~= "function" or type(MODS.folder) ~= "string" then
        L.once("mods", "the loader does not say where the other mods are: their keys are not listed")
        note("keys.other_mods", "not available")
        return
    end
    local known, mods = {}, {}
    for _, m in ipairs(OTHERS) do
        known[m.mod:lower()] = true
        local runs
        if m.host then runs = MODS.runs(m.host) and exists(MODS.folder .. "/" .. m.folder .. "/enabled.txt")
        else runs = MODS.runs(m.mod) end
        if runs and m.file then
            mods[#mods + 1] = m.mod
            local text = readText(MODS.folder .. "/" .. m.file)
            if not text then
                out[#out + 1] = m.mod .. ": keys not known (its settings file cannot be read)"
            else
                for _, k in ipairs(m.keys) do
                    local v = valueOf(text, k.name, m.form)
                    if (v == nil or v == "") and k.default then v = k.default end
                    if v and v ~= "" and (k.when == nil or on(valueOf(text, k.when, m.form))) then
                        out[#out + 1] = keyText(v) .. " - " .. k.what
                    end
                end
            end
        end
    end
    for _, name in ipairs(namesInModsTxt()) do
        if not known[name:lower()] and MODS.runs(name) then
            mods[#mods + 1] = name
            out[#out + 1] = name .. ": keys not known"
        end
    end
    note("keys.other_mods", tostring(#mods), table.concat(mods, ", "))
end

-- One line per key, this mod's first: "Y - wait 30 minutes".
local function buildLines()
    local out = {}
    for _, k in ipairs(KIT.keyList()) do out[#out + 1] = k.key .. " - " .. (k.label ~= "" and k.label or k.id) end
    if Cfg.OtherMods then otherLines(out) end
    if #out == 0 then out[1] = "no key is set" end
    return out
end

-- ---------------------------------------------------------------------------
-- The pause menu, looked at afresh at every look (KL1)
-- ---------------------------------------------------------------------------
local function isPauseMenu(widget)
    if not S.class then return true end         -- (the class is not known: what the pause stack shows counts)
    local ok, is = pcall(function() return widget:IsA(S.class) end)
    if not ok then
        L.once("isa", "the pause menu's class cannot be asked: whatever the pause menu's stack shows counts")
        note("keys.pause_class", "not asked", tostring(is))
        return true
    end
    return is == true
end
local function pauseMenuOpen()
    local ctrl = KIT.controller()
    if not ctrl then return false end
    local main = KIT.get(ctrl, PLAYER_WIDGET)
    if not KIT.valid(main) then
        note("keys.player_widget", "not found", KIT.classToken(ctrl))
        return false
    end
    note("keys.player_widget", "found", KIT.classToken(main))
    local stack = KIT.get(main, PAUSE_STACK)
    if not KIT.valid(stack) then
        note("keys.pause_stack", "not found", KIT.classToken(main))
        return false
    end
    note("keys.pause_stack", "found", KIT.classToken(stack))
    local shown = KIT.get(stack, SHOWN)
    if not KIT.valid(shown) or KIT.get(shown, ACTIVE) ~= true or not isPauseMenu(shown) then return false end
    note("keys.pause_menu", "open", KIT.classToken(shown))
    return true
end

-- ---------------------------------------------------------------------------
-- The loop
-- ---------------------------------------------------------------------------
local function hide()
    if S.shown then Box.hide() end
    S.shown, S.lines, S.showing = false, nil, nil
end
local function tick()
    if KIT.loading() or not Cfg.Enabled then return hide() end
    local open = false
    if Cfg.InPauseMenu then
        if not S.classLooked and KIT.controller() then
            S.classLooked = true
            S.class = KIT.findClass(PAUSE_CLASS, "G1R")
            note("keys.pause_class", S.class and "found" or "not found")
        end
        open = pauseMenuOpen()
    end
    if open and not S.menuOpen then S.menus = S.menus + 1 end
    S.menuOpen = open
    -- the whole list when the key asked for it (or in the pause menu when there is no key), else the line
    -- in the pause menu that names the key, else nothing
    local want = nil
    if S.toggled or (open and S.key == "") then want = "list" elseif open then want = "line" end
    if not want then return hide() end
    if S.shown and S.showing == want and not S.dirty then return end
    if not Box.available() or clock() < S.tryAt then return end
    S.dirty = false
    local lines = want == "list" and buildLines() or { S.key .. " - list of keys" }
    if Box.show(lines) then
        if want == "list" and S.showing ~= "list" then S.shows = S.shows + 1 end
        S.shown, S.lines, S.showing = true, lines, want
    else
        S.shown, S.lines, S.showing, S.tryAt = false, nil, nil, clock() + RETRY
    end
end

-- ---------------------------------------------------------------------------
-- Status (console, the loader's reports), console words, settings, the key
-- ---------------------------------------------------------------------------
local function summary()
    if not Cfg.Enabled then return "switched off" end
    local parts = {}
    parts[#parts + 1] = S.key ~= "" and ("key " .. S.key) or "no key"
    if not Cfg.InPauseMenu then parts[#parts + 1] = "nothing in the pause menu"
    elseif S.key ~= "" then parts[#parts + 1] = "its line in the pause menu"
    else parts[#parts + 1] = "the list in the pause menu" end
    parts[#parts + 1] = Cfg.OtherMods and "with the other mods' keys" or "this mod's keys only"
    parts[#parts + 1] = "letters " .. tostring(Cfg.TextSize)
    return table.concat(parts, ", ")
end
local function statusLines()
    local lines = { ("v%s | %s"):format(VERSION, summary()) }
    lines[#lines + 1] = ("the list came up %d time(s); the pause menu was seen open %d time(s)"):format(S.shows, S.menus)
    if not Box.available() then lines[#lines + 1] = "the box cannot be shown in this run" end
    return lines
end

-- keys           status and the list
-- keys reload    read config.lua now
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
        for _, l in ipairs(buildLines()) do lines[#lines + 1] = l end
    end
    for _, l in ipairs(lines) do
        log(l)
        if device ~= nil then pcall(function() device:Log("[" .. TAG .. "] " .. l) end) end
    end
    return true
end

local function bindKey()
    local ok, result = KIT.bindKey("keys:show", Cfg.ListKey, function() S.toggled = not S.toggled end)
    if ok then
        S.key = result
    else
        S.key = ""
        L.once("key:" .. tostring(Cfg.ListKey) .. ":" .. tostring(result), ("the key %s could not be bound (%s); the pause menu and the console show the whole list")
            :format(tostring(Cfg.ListKey), tostring(result)))
    end
end
bindKey()
KIT.describeKey("keys:show", "show or hide this list")

Settings.onChange = function(_, changed, why)
    for _, key in ipairs(changed) do
        if key == "ListKey" then bindKey() end
        if key == "TextSize" and Box.resize(Cfg.TextSize) then S.shown, S.lines, S.showing = false, nil, nil end
    end
    S.dirty = true
    log(("settings changed (%s): %s"):format(why == "menu" and "in-game menu" or (why == "file" and "config.lua" or tostring(why)), summary()))
end

-- ---------------------------------------------------------------------------
-- Registration (each exactly once)
-- ---------------------------------------------------------------------------
KIT.onWorldChange(function()
    S.toggled, S.shown, S.lines, S.showing, S.menuOpen = false, false, nil, nil, false       -- (the kit forgets the box itself)
end)
for _, name in ipairs({ "keys", "g1r_keys" }) do
    if type(RegisterConsoleCommandHandler) == "function" then
        pcall(RegisterConsoleCommandHandler, name, console)
    end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; the list of keys is not shown.")
else
    LoopInGameThreadWithDelay(250, function()
        local ok, err = pcall(tick)
        if not ok then L.once("tick:" .. tostring(err), "update error: " .. tostring(err)) end
    end)
end

log(("v%s loaded: %s"):format(VERSION, summary()))

if DIAG then
    pcall(function()
        DIAG.status(statusLines)
        DIAG.dump(function()
            return {
                version = VERSION, enabled = Cfg.Enabled, in_pause_menu = Cfg.InPauseMenu, key = S.key, other_mods = Cfg.OtherMods,
                size = Box.size, shown = S.shown, showing = S.showing, shows = S.shows, menus = S.menus, toggled = S.toggled,
                box = Box.available(), class = S.class ~= nil, lines = S.lines,
            }
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "KEYS_TEST")) == "table" then
    local T = rawget(_G, "KEYS_TEST")
    T.state, T.console, T.status, T.tick, T.settings, T.lines = S, console, statusLines, tick, Settings, buildLines
end
