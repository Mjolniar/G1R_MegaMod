-- ============================================================================
-- Settings of other mods (module othermods of G1R_MegaMod) - Gothic 1 Remake
--
-- Two numbers that belong to other mods: how far FocusNearbyPickups
-- highlights things (maxRadius in its FocusNearbyPickups.ini) and how far
-- G1R_AutoPickUpItemNative picks items up (AreaLootingRadius in its
-- G1R_AutoPickUpItemNative.ini). Each mod reads its file once, when the game
-- starts (OM1, OM2). The settings app writes the one line into the file when
-- it saves with the game closed; this module never writes those files. It
-- reads them (at the start and after a change of the settings) and says in
-- UE4SS.log and in the diagnostics whether they hold what the settings ask.
--
-- Settings: schema.lua describes them, config.lua holds them; the settings
-- app changes them. Not in the in-game menu: the other mods read their files
-- only when the game starts.
-- ============================================================================

local VERSION = "1.0.0"
local TAG = "G1R_OtherMods"

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
-- The two lines (dev/facts/othermods.md): the mod, its file below the Mods
-- folder, the key, the settings that ask for it, centimetres per metre.
-- ---------------------------------------------------------------------------
local LINES = {
    { what = "highlight", mod = "FocusNearbyPickups", host = "PLuaModLoader",
      file = "PLuaModLoader/Scripts/Mods/FocusNearbyPickups/FocusNearbyPickups.ini", key = "maxRadius",
      switch = "SetHighlight", setting = "HighlightMeters" },
    { what = "loot", mod = "G1R_AutoPickUpItemNative",
      file = "G1R_AutoPickUpItemNative/G1R_AutoPickUpItemNative.ini", key = "AreaLootingRadius",
      switch = "SetLoot", setting = "LootMeters" },
}
local SAME = 0.5            -- centimetres: two values closer than this are the same

local Settings, problem = SETTINGS.open({ module = "othermods", dir = SCRIPT_DIR, log = log, menu = false })
if not Settings then
    log("the settings could not be set up (" .. tostring(problem) .. "); not started")
    return
end
local Cfg = Settings.values

local S = { found = {} }        -- per line: the value its file holds now (centimetres), false = not there
local Noted = {}
local function note(key, value, detail)
    if DIAG and Noted[key] ~= value then
        Noted[key] = value
        DIAG.note(key, value, detail)
    end
end
local function metres(cm) return ("%.1f m"):format(cm / 100) end
local function wanted(line) return Cfg.Enabled == true and Cfg[line.switch] == true end

-- The value of `key` in an ini text (the first line "key = value" that is no comment), as a number; nil when the
-- key is not there or its value is no number.
local function valueOf(text, key)
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local k, v = line:gsub("\r$", ""):match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k == key then return tonumber(v) end
    end
    return nil
end

-- Looks at both files: what they hold, and whether that is what the settings ask.
local function look()
    for _, line in ipairs(LINES) do
        local value, why = nil, nil
        if type(MODS) ~= "table" or type(MODS.folder) ~= "string" then
            why = "the loader does not say where the other mods are"
        else
            local f = io.open(MODS.folder .. "/" .. line.file, "rb")
            if not f then
                why = "its settings file is not there"
            else
                local ok, text = pcall(f.read, f, "a")
                pcall(f.close, f)
                value = ok and type(text) == "string" and valueOf(text, line.key) or nil
                if value == nil then why = "the file has no number for " .. line.key end
            end
        end
        S.found[line.what] = value or false
        note("othermods." .. line.what .. "_file", value and tostring(value) or "not readable", value and line.mod or why)
        if wanted(line) then
            local want = Cfg[line.setting] * 100
            if not value then
                L.once(line.what .. ":unreadable", ("%s: %s - the setting cannot be checked"):format(line.mod, tostring(why)))
            elseif math.abs(value - want) >= SAME then
                L.once(line.what .. ":" .. want, ("%s reads %s = %g (%s) when the game starts; the setting asks for %s: the settings app writes it when it saves with the game closed")
                    :format(line.mod, line.key, value, metres(value), metres(want)))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Status, console, settings
-- ---------------------------------------------------------------------------
local function summary()
    if not Cfg.Enabled then return "switched off" end
    local parts = {}
    for _, line in ipairs(LINES) do
        parts[#parts + 1] = line.what .. " " .. (wanted(line) and metres(Cfg[line.setting] * 100) or "as the mod has it")
    end
    return table.concat(parts, ", ")
end
local function statusLines()
    local lines = { ("v%s | %s"):format(VERSION, summary()) }
    for _, line in ipairs(LINES) do
        local v = S.found[line.what]
        lines[#lines + 1] = ("%s reads %s"):format(line.mod, v and ("%s = %g (%s)"):format(line.key, v, metres(v)) or "nothing (its file or the key is not there)")
    end
    return lines
end

-- othermods           status
-- othermods reload    read config.lua now
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
        look()
        lines = statusLines()
    end
    for _, l in ipairs(lines) do
        log(l)
        if device ~= nil then pcall(function() device:Log("[" .. TAG .. "] " .. l) end) end
    end
    return true
end

Settings.onChange = function(_, _, why)
    look()
    log(("settings changed (%s): %s"):format(why == "file" and "config.lua" or tostring(why), summary()))
end

for _, name in ipairs({ "othermods", "g1r_othermods" }) do
    if type(RegisterConsoleCommandHandler) == "function" then
        pcall(RegisterConsoleCommandHandler, name, console)
    end
end

look()
log(("v%s loaded: %s"):format(VERSION, summary()))

if DIAG then
    pcall(function()
        DIAG.status(statusLines)
        DIAG.dump(function()
            return { version = VERSION, enabled = Cfg.Enabled, set_highlight = Cfg.SetHighlight, highlight_metres = Cfg.HighlightMeters,
                set_loot = Cfg.SetLoot, loot_metres = Cfg.LootMeters, highlight_file = S.found.highlight, loot_file = S.found.loot }
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "OTHERMODS_TEST")) == "table" then
    local T = rawget(_G, "OTHERMODS_TEST")
    T.state, T.console, T.status, T.look, T.settings = S, console, statusLines, look, Settings
end
