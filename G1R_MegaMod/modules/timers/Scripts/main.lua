-- ============================================================================
-- Effect timers (module timers of G1R_MegaMod) - Gothic 1 Remake, UE4SS Lua
--
-- A small box lists what is on the hero and how long it still lasts:
--   * the game's effects with a duration on his ability system - healing and
--     mana over time, burning, frozen, electrified, wind, slowed, knocked out,
--     asleep, afraid, charmed (TM1 - TM3): each effect's start and length are
--     read from the list the ability system keeps, the time from the world;
--   * the Light spell: its actor's own engine timer (TM4), else a count of the
--     module's own from the spell's length;
--   * alcohol and swampweed: how long until the level has worn off, from the
--     level and the rate it falls by (TM5).
-- Nothing is written into the game. Only what is read every half second.
--
-- Settings: schema.lua describes them, config.lua holds them; the settings
-- app and the in-game mod menu change them while the game runs.
-- ============================================================================

local VERSION = "1.0.1"
local TAG = "G1R_Timers"

local KIT, SETTINGS = G1R_KIT, G1R_SETTINGS
-- Diagnostics handle of the loader; nil when the diagnostics are off, and then
-- nothing behind `if DIAG` runs.
local DIAG = G1R_DIAG
if type(KIT) ~= "table" or type(SETTINGS) ~= "table" then
    print("[" .. TAG .. "] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started" .. string.char(10))
    return
end
if DIAG then pcall(DIAG.version, VERSION) end

local pcall, type, tostring, ipairs = pcall, type, tostring, ipairs
local floor, max, abs = math.floor, math.max, math.abs
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
-- What the module knows about the game (dev/facts/timers.md)
-- ---------------------------------------------------------------------------
local EFFECTS, LIST = "ActiveGameplayEffects", "GameplayEffects_Internal"     -- the ability system's list (TM1)
local STATICS = "/Script/Engine.Default__GameplayStatics"                     -- GetTimeSeconds(world) (TM2)
local SYSTEM = "/Script/Engine.Default__KismetSystemLibrary"                  -- K2_GetTimerRemainingTimeHandle (TM4)
local LIGHT_ACTOR = "LightSpellVisual"                                        -- the Light's actor, a child of the hero (TM4)
local LIGHT_CONFIG = "LightSpellConfig"                                       -- /Script/Angelscript: m_LifeSpan (TM4)
local DRINKS = {                                                              -- (TM5)
    { part = "Alcohol", level = "Alcohol", rate = "AlcoholDepletionRate", label = "Alcohol" },
    { part = "Swampweed", level = "Swampweed", rate = "SwampweedDepletionRate", label = "Swampweed" },
}
-- The game's effects with a duration, by the name of their class (TM3); the first that fits names the line.
local function has(n, part) return n:find(part, 1, true) ~= nil end
local KINDS = {
    { label = "Healing", group = "ShowFood", fits = function(n) return has(n, "Heal") and has(n, "Overtime") end },
    { label = "Mana", group = "ShowFood", fits = function(n) return has(n, "Mana") and has(n, "Overtime") end },
    { label = "Burning", group = "ShowElements", fits = function(n) return has(n, "Burn") or has(n, "Fire_Duration") end },
    { label = "Frozen", group = "ShowElements", fits = function(n) return has(n, "Freeze") or has(n, "IceStack") or has(n, "Frozen") end },
    { label = "Electrified", group = "ShowElements", fits = function(n) return has(n, "Electrified") or has(n, "Paralyz") end },
    { label = "Wind", group = "ShowElements", fits = function(n) return has(n, "Wind") end },
    { label = "Slowed", group = "ShowElements", fits = function(n) return has(n, "Slow") end },
    { label = "Knocked out", group = "ShowMind", fits = function(n) return n == "GE_Defeated" end },
    { label = "Asleep", group = "ShowMind", fits = function(n) return n == "GE_Sleep" end },
    { label = "Afraid", group = "ShowMind", fits = function(n) return n == "GE_Fear" end },
    { label = "Charmed", group = "ShowMind", fits = function(n) return n == "GE_Charm" end },
}
-- what only shows something, what only waits, what the levels of alcohol and swampweed tell already, a
-- spell's mana cost while it is cast or held (GE_ManaBurn and its kind: "Burn" in the name, but no fire),
-- what takes another effect away, and the abilities an equipped rune or scroll brings (TM3)
local SKIP = { "Visual", "Cooldown", "Depletion", "ManaBurn", "Mana_Channeling", "Mana_Aiming", "Removal", "UnBurn", "EquipAbilities" }
local LOOK_EVERY = 0.5      -- seconds between two looks
local TRIES = 3             -- failures in a row before a part is given up for this run

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local Settings, problem = SETTINGS.open({ module = "timers", dir = SCRIPT_DIR, log = log })
if not Settings then
    log("the settings could not be set up (" .. tostring(problem) .. "); not started")
    return
end
local Cfg = Settings.values

-- ---------------------------------------------------------------------------
-- State of this run
-- ---------------------------------------------------------------------------
local S = {
    lookAt = -1e9, lines = nil, shown = false,
    box = nil, boxKey = nil,
    fails = { effects = 0, timer = 0 }, effectsOff = false, timerOff = false,
    light = nil,            -- the own count of a Light: { name, start, span }
}
local Noted = {}
local function note(key, value, detail)
    if DIAG and Noted[key] ~= value then
        Noted[key] = value
        DIAG.note(key, value, detail)
    end
end

local function firstLine(text) return (tostring(text):match("^[^\r\n]*") or "") end
-- "7 s", "4:32"
local function clockText(seconds)
    local s = floor(seconds + 0.5)
    if s < 60 then return s .. " s" end
    return ("%d:%02d"):format(s // 60, s % 60)
end
local function line(label, seconds) return label .. " " .. clockText(seconds) end

-- The world's time in seconds (it stands while the game is paused), or nil.
local function worldTime()
    local world = KIT.world()
    local statics = world and KIT.findOnce(STATICS) or nil
    local t = statics and KIT.number(KIT.call(statics, "GetTimeSeconds", world)) or nil
    note("timers.world_time", t and "works" or "not readable")
    return t
end

-- ---------------------------------------------------------------------------
-- The game's effects with a duration (TM1 - TM3)
-- ---------------------------------------------------------------------------
-- "GE_Burn" for the class default object of GE_Burn (a blueprint's "_C" left out).
local function effectName(def)
    local class = KIT.classToken(def)
    if not class then return nil end
    return (class:gsub("_C$", ""))
end
local function skipped(name)
    for _, part in ipairs(SKIP) do
        if has(name, part) then return true end
    end
    return false
end
local function kindOf(name)
    for _, kind in ipairs(KINDS) do
        if kind.fits(name) then return kind end
    end
    return nil
end
local function effectsFailed(why)
    S.fails.effects = S.fails.effects + 1
    if S.fails.effects >= TRIES then
        S.effectsOff = true
        note("timers.effects", "not readable", why)
        L.once("effects", "the hero's effects cannot be read (" .. tostring(why) .. "); their timers are not shown in this run")
    end
end
local function effectLines(out)
    if S.effectsOff or not (Cfg.ShowFood or Cfg.ShowElements or Cfg.ShowMind or Cfg.ShowOthers) then return end
    local state = KIT.playerState()
    local system = state and KIT.get(state, "AbilitySystemComponent") or nil
    if not KIT.valid(system) then return end
    local list = KIT.get(KIT.get(system, EFFECTS), LIST)
    if list == nil then return effectsFailed("no list of effects") end
    local now = worldTime()
    if now == nil then return effectsFailed("the world's time cannot be read") end
    local best, others = {}, {}
    local n = KIT.each(list, function(e)
        local spec = KIT.get(e, "Spec")
        local duration, start = KIT.number(KIT.get(spec, "Duration")), KIT.number(KIT.get(e, "StartWorldTime"))
        if not duration or duration <= 0 or not start then return end
        local left = start + duration - now
        local name = effectName(KIT.get(spec, "Def"))
        if left <= 0 or not name or skipped(name) then return end
        local kind = kindOf(name)
        if kind then
            if Cfg[kind.group] then best[kind.label] = max(best[kind.label] or 0, left) end
        elseif Cfg.ShowOthers then
            local label = name:gsub("^GE_", ""):gsub("_", " ")
            others[label] = max(others[label] or 0, left)
        end
    end)
    if n == nil then return effectsFailed("the list of effects cannot be walked") end
    S.fails.effects = 0
    note("timers.effects", "readable")
    for _, kind in ipairs(KINDS) do
        if best[kind.label] then out[#out + 1] = line(kind.label, best[kind.label]) end
    end
    local labels = {}
    for label in pairs(others) do labels[#labels + 1] = label end
    table.sort(labels)
    for _, label in ipairs(labels) do out[#out + 1] = line(label, others[label]) end
end

-- ---------------------------------------------------------------------------
-- The Light spell (TM4)
-- ---------------------------------------------------------------------------
local function lightActor()
    local pawn = KIT.pawn()
    local children = pawn and KIT.get(pawn, "Children") or nil
    local found = nil
    if children ~= nil then
        KIT.each(children, function(a)
            local class = KIT.classToken(a)
            if class and has(class, LIGHT_ACTOR) then
                found = a
                return true
            end
        end)
    end
    return found
end
-- How long a Light lasts when it is first seen: what a loaded one had left, else the spell's length.
local function lightSpan(light)
    local last = KIT.number(KIT.get(light, "m_LastTimeSpan"))
    if last and last > 0 then return last end
    return KIT.number(KIT.get(KIT.findDefault(LIGHT_CONFIG, "Angelscript"), "m_LifeSpan")) or 300
end
local function lightLines(out)
    if not Cfg.ShowLight then return end
    local light = lightActor()
    if not light then
        S.light = nil
        return
    end
    if not S.timerOff then
        local ok, raw = KIT.try(KIT.findOnce(SYSTEM), "K2_GetTimerRemainingTimeHandle", KIT.world(), KIT.get(light, "TaskTimer"))
        local v = ok and KIT.number(raw) or nil
        if v then
            S.fails.timer, S.light = 0, nil
            note("timers.light_by", "engine timer")
            -- 0 or less: the Light has gone out (the game clears its timer and keeps the actor 5 s while it fades)
            if v > 0 then out[#out + 1] = line("Light", v) end
            return
        end
        S.fails.timer = S.fails.timer + 1
        if S.fails.timer >= TRIES then
            S.timerOff = true
            note("timers.light_by", "own count", ok and ("the timer said " .. tostring(raw)) or firstLine(raw))
        end
    end
    -- the module's own count, from when it first saw this Light
    local name, now = KIT.fullName(light), worldTime()
    if S.light == nil or S.light.name ~= name then S.light = { name = name, start = now, span = lightSpan(light) } end
    local left = (now and S.light.start) and S.light.span - (now - S.light.start) or nil
    if left and left > 0 then out[#out + 1] = line("Light", left) end
end

-- ---------------------------------------------------------------------------
-- Alcohol and swampweed (TM5)
-- ---------------------------------------------------------------------------
local function drinkLines(out)
    if not Cfg.ShowDrinks then return end
    for _, d in ipairs(DRINKS) do
        local set = KIT.attributeSet(d.part)
        local level = set and KIT.readAttribute(set, d.level) or nil
        local rate = set and KIT.readAttribute(set, d.rate) or nil
        if set then note("timers.drinks", (level and rate) and "readable" or "not readable", d.part) end
        if level and rate and level > 0 and abs(rate) > 0 then out[#out + 1] = line(d.label, level / abs(rate)) end
    end
end

-- ---------------------------------------------------------------------------
-- The box, the loop
-- ---------------------------------------------------------------------------
local function box()
    local key = ("timers:%s:%d:%d"):format(Cfg.Position, Cfg.DistanceX, Cfg.DistanceY)
    if S.boxKey ~= key then
        if S.box then S.box.hide() end
        local right, bottom = has(Cfg.Position, "right"), has(Cfg.Position, "bottom")
        S.box, S.boxKey = KIT.panel(key, { position = Cfg.Position, dx = right and -Cfg.DistanceX or Cfg.DistanceX,
            dy = bottom and -Cfg.DistanceY or Cfg.DistanceY, z = 40 }), key
        S.shown = false
    end
    return S.box
end
local function hide()
    if S.shown and S.box then S.box.hide() end
    S.shown, S.lines = false, nil
end
local function tick()
    if KIT.loading() or not Cfg.Enabled then return hide() end
    local now = clock()
    if now < S.lookAt then return end
    S.lookAt = now + LOOK_EVERY
    if not KIT.controller() then return hide() end
    local lines = {}
    effectLines(lines)
    lightLines(lines)
    drinkLines(lines)
    if #lines == 0 then return hide() end
    S.lines = lines
    local b = box()
    if b.available() then S.shown = b.show(lines) end
end

-- ---------------------------------------------------------------------------
-- Status (console, the loader's reports), console words, settings
-- ---------------------------------------------------------------------------
local function summary()
    if not Cfg.Enabled then return "switched off" end
    local on = {}
    for _, g in ipairs({ { "ShowFood", "food" }, { "ShowElements", "elements" }, { "ShowMind", "mind" }, { "ShowLight", "light" }, { "ShowDrinks", "drinks" }, { "ShowOthers", "others" } }) do
        if Cfg[g[1]] then on[#on + 1] = g[2] end
    end
    return ("%s; %s, %d / %d"):format(#on > 0 and table.concat(on, ", ") or "nothing shown", Cfg.Position, Cfg.DistanceX, Cfg.DistanceY)
end
local function statusLines()
    local lines = { ("v%s | %s"):format(VERSION, summary()) }
    lines[#lines + 1] = S.lines and ("on screen: " .. table.concat(S.lines, ", ")) or "nothing on screen"
    if S.effectsOff then lines[#lines + 1] = "the hero's effects cannot be read in this run" end
    if S.timerOff then lines[#lines + 1] = "the Light is counted by the module" end
    return lines
end

-- timers           status
-- timers reload    read config.lua now
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

Settings.onChange = function(_, _, why)
    S.lookAt = -1e9
    log(("settings changed (%s): %s"):format(why == "menu" and "in-game menu" or (why == "file" and "config.lua" or tostring(why)), summary()))
end

-- ---------------------------------------------------------------------------
-- Registration (each exactly once)
-- ---------------------------------------------------------------------------
KIT.onWorldChange(function()
    S.shown, S.lines, S.light, S.lookAt = false, nil, nil, -1e9      -- (the kit forgets the box itself)
end)
for _, name in ipairs({ "timers", "g1r_timers" }) do
    if type(RegisterConsoleCommandHandler) == "function" then
        pcall(RegisterConsoleCommandHandler, name, console)
    end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; no timers are shown.")
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
                version = VERSION, enabled = Cfg.Enabled, position = Cfg.Position, lines = S.lines, shown = S.shown,
                effects_off = S.effectsOff, timer_off = S.timerOff, light = S.light and S.light.span or nil,
            }
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "TIMERS_TEST")) == "table" then
    local T = rawget(_G, "TIMERS_TEST")
    T.state, T.console, T.status, T.tick, T.settings = S, console, statusLines, tick, Settings
end
