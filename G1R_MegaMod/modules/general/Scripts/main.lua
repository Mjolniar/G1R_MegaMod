-- ============================================================================
-- General settings (module general of G1R_MegaMod) - Gothic 1 Remake, UE4SS Lua
--
-- What the other modules share on screen: how a short note looks (a small box
-- in a corner, the game's own line at the top, or not at all), where the box
-- sits and how long a note stays. This module only hands those settings to
-- the loader's kit; it does not look at the game.
--
-- Settings: schema.lua describes them, config.lua holds them; the settings
-- app and the in-game mod menu change them while the game runs.
-- ============================================================================

local VERSION = "1.1.0"
local TAG = "G1R_General"

local KIT, SETTINGS = G1R_KIT, G1R_SETTINGS
local DIAG = G1R_DIAG
if type(KIT) ~= "table" or type(SETTINGS) ~= "table" then
    print("[" .. TAG .. "] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started\n")
    return
end
if DIAG then pcall(DIAG.version, VERSION) end

local pcall, type, tostring = pcall, type, tostring
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

local Settings, problem = SETTINGS.open({ module = "general", dir = SCRIPT_DIR, log = log })
if not Settings then
    log("the settings could not be set up (" .. tostring(problem) .. "); not started")
    return
end
local Cfg = Settings.values

local function summary()
    local letters = "; " .. tostring(Cfg.Letters) .. " letters"
    if Cfg.NoteStyle == "off" then return "notes off" .. letters end
    if Cfg.NoteStyle == "subtitle" then return ("notes as the game's own line, %d s"):format(Cfg.NoteSeconds) .. letters end
    return ("notes in a box, %s, %d s"):format(Cfg.NotePosition, Cfg.NoteSeconds) .. letters
end
local function apply()
    KIT.configureNotes({ style = Cfg.NoteStyle, seconds = Cfg.NoteSeconds, position = Cfg.NotePosition })
    if type(KIT.configureLetters) == "function" then KIT.configureLetters(Cfg.Letters) end
end
Settings.onChange = function(_, _, why)
    apply()
    log(("settings changed (%s): %s"):format(why == "menu" and "in-game menu" or (why == "file" and "config.lua" or tostring(why)), summary()))
end
Settings.onAction = function(key)
    if key == "TestNote" then
        if not KIT.notify("This is how a note looks", "general") and Cfg.NoteStyle ~= "off" then
            log("the note could not be shown (no game loaded?)")
        end
    end
end

apply()
log(("v%s loaded: %s"):format(VERSION, summary()))

if DIAG then
    pcall(function()
        DIAG.status(function() return { ("v%s | %s"):format(VERSION, summary()) } end)
        DIAG.dump(function()
            return { version = VERSION, note_style = Cfg.NoteStyle, note_position = Cfg.NotePosition, note_seconds = Cfg.NoteSeconds, letters = Cfg.Letters }
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "GENERAL_TEST")) == "table" then
    local T = rawget(_G, "GENERAL_TEST")
    T.settings, T.summary = Settings, summary
end
