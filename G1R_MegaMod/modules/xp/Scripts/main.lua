-- ============================================================================
-- Experience multiplier (module xp of G1R_MegaMod) - Gothic 1 Remake, UE4SS Lua
--
-- Every experience gain of the hero counts as many times as the settings say
-- (fights, quests, lock picking - any source); gains from a chosen size on can
-- have a multiplier of their own.
--
-- How it works: the hero's experience is a number in the level progression
-- attributes of his player state. A few times per second the module looks at
-- that number. When it has gone up by a plausible amount, the difference to
-- "gain x multiplier" is added. The game does the levelling itself: a level
-- that the added experience makes possible is given with the next gain,
-- because that is when the game compares experience and level. The game's own
-- "+ experience" display shows the amount before the multiplier.
--
-- Not multiplied: what happens in the first seconds after the hero's
-- attributes were found (a loaded save may still be filling them in), a jump
-- larger than MaxGain, and what was gained while the module was off or every
-- multiplier was 1. While nothing is to be multiplied the module does not
-- look at the game at all.
--
-- One experience multiplier at a time: the loader does not load this module
-- while the mod EXPModifier is enabled; a copy of that mod under another
-- folder name is recognised by its entry in the mod menu's list or by a value
-- it announces, and then this module adds nothing for the rest of the run.
--
-- Settings: schema.lua describes them, config.lua holds them; the settings
-- app and the in-game mod menu change them while the game runs.
-- ============================================================================

local VERSION = "1.0.0"
local TAG = "G1R_XP"

local KIT, SETTINGS = G1R_KIT, G1R_SETTINGS
-- Diagnostics handle of the loader; nil when the diagnostics are off, and then
-- nothing behind `if DIAG` runs.
local DIAG = G1R_DIAG
if type(KIT) ~= "table" or type(SETTINGS) ~= "table" then
    print("[" .. TAG .. "] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started\n")
    return
end
if DIAG then pcall(DIAG.version, VERSION) end

local pcall, type, tostring, ipairs = pcall, type, tostring, ipairs
local floor, abs = math.floor, math.abs
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
-- State of this run
-- ---------------------------------------------------------------------------
local LEDGER = "EXPModifier_lastWrite"      -- the shared variable the mod EXPModifier announces its writes in
local MENU_INDEX = "SMM:index"              -- the mod menu's list of mods that registered with it

local S = {
    setName = nil,              -- full name of the attributes the experience was last read from
    via = nil,                  -- how they were found: "player state" / "scan"
    armedAt = 0,                -- gains count from this moment on (settle time after the attributes were found)
    settleFrom = nil,           -- experience at the first look at these attributes (nil once the wait is over)
    settleMoved = false,        -- the number changed during the wait
    last = nil,                 -- experience at the last look (nil = the next look only takes the value)
    signature = nil,            -- the multipliers in use at the last look
    level = nil, total = nil,
    other = false,              -- another experience multiplier is at work: this module stands down
    ownLedger = nil, ledgerAtStart = nil,
    unreadableUntil = 0,
    gains = 0, added = 0, lastGain = nil, skipped = 0, failedWrites = 0,
}
local Noted = {}
local function note(key, value, detail)
    if DIAG and Noted[key] ~= value then
        Noted[key] = value
        DIAG.note(key, value, detail)
    end
end

local function times(m) return (("x%.2f"):format(m):gsub("0$", "")) end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local Settings, problem = SETTINGS.open({ module = "xp", dir = SCRIPT_DIR, log = log })
if not Settings then
    log("the settings could not be set up (" .. tostring(problem) .. "); not started")
    return
end
local Cfg = Settings.values

-- The multiplier for a gain of this size (only asked while not idle).
local function factorFor(gain)
    if Cfg.LargeGainFrom > 0 and gain >= Cfg.LargeGainFrom then return Cfg.LargeGainMultiplier end
    return Cfg.Multiplier
end
-- True while there is nothing to multiply at all.
local function idle()
    if not Cfg.Enabled or S.other then return true end
    return Cfg.Multiplier == 1 and (Cfg.LargeGainFrom <= 0 or Cfg.LargeGainMultiplier == 1)
end
local function summary()
    if not Cfg.Enabled then return "switched off in the settings" end
    if S.other then return "standing down: another experience multiplier is active" end
    if idle() then return "multiplier x1.0 (experience unchanged)" end
    local text = "multiplier " .. times(Cfg.Multiplier)
    if Cfg.LargeGainFrom > 0 then
        text = text .. (", gains from %d on %s"):format(Cfg.LargeGainFrom, times(Cfg.LargeGainMultiplier))
    end
    return text
end
Settings.onChange = function(_, changed, why)
    log(("settings changed (%s): %s"):format(why == "menu" and "in-game menu" or (why == "file" and "config.lua" or tostring(why)), summary()))
    if not Cfg.ShowMessage then KIT.hideToast("xp") end
end

-- ---------------------------------------------------------------------------
-- Another experience multiplier in the same game (UE4SS shared variables are
-- one store for all Lua mods)
-- ---------------------------------------------------------------------------
local function sharedValue(name)
    local ok, v = pcall(function() return ModRef:GetSharedVariable(name) end)
    if ok then return v end
    return nil
end
local function ledgerGet()
    local v = sharedValue(LEDGER)
    if type(v) == "number" then return v end
    return nil
end
local function ledgerSet(v)
    local ok = pcall(function() ModRef:SetSharedVariable(LEDGER, v) end)
    if ok then S.ownLedger = v end
end
-- What the ledger held when this run of the module started (left by an earlier run of the Lua mods).
S.ledgerAtStart = ledgerGet()

-- EXPModifier puts its name into the mod menu's list as soon as it is loaded,
-- whatever its folder is called, and announces every value it writes.
local function otherAtWork()
    local index = sharedValue(MENU_INDEX)
    if type(index) == "string" then
        for name in index:gmatch("[^,]+") do
            if name == "EXPModifier" then return "it is registered with the mod menu" end
        end
    end
    local ledger = ledgerGet()
    if ledger ~= nil and (S.ownLedger == nil or abs(ledger - S.ownLedger) >= 0.5)
        and (S.ledgerAtStart == nil or abs(ledger - S.ledgerAtStart) >= 0.5) then
        return "it announced a write"
    end
    return nil
end
local function standDown(why)
    if S.other then return end
    S.other = true
    log("another experience multiplier (the mod EXPModifier) is active - " .. tostring(why)
        .. ": this module adds nothing until the game is started without it")
    note("xp.other_multiplier", "EXPModifier", why)
end

-- ---------------------------------------------------------------------------
-- The note on screen
-- ---------------------------------------------------------------------------
local function show(message)
    if Cfg.ShowMessage then KIT.notify(message, "xp") end
end

-- ---------------------------------------------------------------------------
-- The loop
-- ---------------------------------------------------------------------------
local function rest()
    -- nothing is watched: the next look at the game starts afresh
    S.setName, S.last = nil, nil
end

local function tick()
    if KIT.loading() then return end
    if idle() then
        if S.setName ~= nil then rest() end
        return
    end
    local now = clock()
    if now < S.unreadableUntil then return end
    local set, via = KIT.attributeSet("LevelProgression")
    if not set then
        if S.setName ~= nil then rest() end
        return
    end
    local name = KIT.fullName(set)
    if name ~= S.setName then
        -- other attributes than at the last look: a new game, another world, a loaded save. A save may
        -- still be filling them in, so gains only count after a short while.
        S.setName, S.via, S.last, S.settleFrom, S.settleMoved = name, via, nil, nil, false
        S.armedAt = now + Cfg.SettleSeconds
        note("xp.set_found_by", via)
        if Cfg.ShowMessage then KIT.prepareNotes() end      -- searches now, not in a fight
    end
    local experience = KIT.readAttribute(set, "Experience")
    if experience == nil then
        L.once("unreadable", "the hero's experience could not be read from " .. tostring(name))
        note("xp.readable", "no", name)
        S.unreadableUntil = now + 5
        rest()
        return
    end
    note("xp.readable", "yes")
    S.level = KIT.readAttribute(set, "Level") or S.level
    S.total = experience

    -- what was gained under other multipliers is never multiplied afterwards
    local signature = ("%s/%s/%s"):format(Cfg.Multiplier, Cfg.LargeGainFrom, Cfg.LargeGainMultiplier)
    if signature ~= S.signature then
        S.signature, S.last = signature, nil
    end
    local last = S.last
    S.last = experience
    if last == nil then
        S.settleFrom = S.settleFrom or experience
        return
    end
    if now < S.armedAt then
        if experience ~= last then S.settleMoved = true end
        return
    end
    if S.settleFrom ~= nil then
        -- the first look after the wait: did the number move in that time?
        if S.settleMoved then
            note("xp.changed_while_settling", "yes", ("%d -> %d"):format(floor(S.settleFrom + 0.5), floor(last + 0.5)))
        else
            note("xp.changed_while_settling", "no")
        end
        S.settleFrom = nil
    end
    if experience <= last + 0.001 then return end       -- unchanged, or less (a loaded save)

    local why = otherAtWork()
    if why then
        standDown(why)
        return
    end
    note("xp.other_multiplier", "none")

    local gain = experience - last
    if gain > Cfg.MaxGain then
        S.skipped = S.skipped + 1
        if Cfg.LogGains then
            log(("experience went from %d to %d: more than MaxGain, taken as a loaded save and not multiplied"):format(floor(last + 0.5), floor(experience + 0.5)))
        end
        return
    end
    local m = factorFor(gain)
    local counted = floor(gain * m + 0.5 + 0.000000001)      -- what the gain is worth, rounded half up
    local target = last + counted
    if abs(target - experience) < 0.5 then return end        -- nothing to add (a multiplier of 1, or after rounding)
    local ok, problemText = KIT.writeAttribute(set, "Experience", target)
    if ok then
        S.last, S.total = target, target
        ledgerSet(target)
        S.gains = S.gains + 1
        S.added = S.added + (target - experience)
        local base = floor(gain + 0.5)
        S.lastGain = ("%d -> %d"):format(base, counted)
        note("xp.write", "ok")
        if S.gains == 1 and DIAG then
            DIAG.event(("first gain: %d -> %d (%s), experience now %d, found through the %s"):format(base, counted, times(m), floor(target + 0.5), tostring(S.via)))
        end
        if Cfg.LogGains then
            log(("gained %d -> %d (%s); experience now %d"):format(base, counted, times(m), floor(target + 0.5)))
        end
        show(("%+d experience  (%d -> %d, %s)"):format(floor(target - experience + 0.5), base, counted, times(m)))
    else
        -- the number is left as the game has it; the next look starts from what is really there
        S.failedWrites = S.failedWrites + 1
        local actual = KIT.readAttribute(set, "Experience")
        S.last, S.total = actual, actual or S.total
        L.once("write", "the experience could not be written (" .. tostring(problemText) .. "); the gain stays as the game gave it")
        note("xp.write", "failed", problemText)
    end
end

-- ---------------------------------------------------------------------------
-- Status (console command xp, the loader's reports). Built from what the
-- module holds; it does not call into the game.
-- ---------------------------------------------------------------------------
local function whole(v) return floor(v + 0.5) end
local function statusLines()
    local lines = { ("v%s | %s"):format(VERSION, summary()) }
    if S.setName ~= nil and S.total ~= nil then
        lines[#lines + 1] = ("experience %d%s, found through the %s"):format(whole(S.total),
            S.level and (", level " .. whole(S.level)) or "", tostring(S.via))
    elseif idle() then
        lines[#lines + 1] = "nothing to multiply: the game is not looked at"
    else
        lines[#lines + 1] = "the hero's experience has not been found yet (no game loaded?)"
    end
    lines[#lines + 1] = ("gains multiplied: %d (%+d experience in total)%s%s"):format(S.gains, whole(S.added),
        S.lastGain and ("; last: " .. S.lastGain) or "", S.skipped > 0 and ("; " .. S.skipped .. " jump(s) taken as a loaded save") or "")
    if S.failedWrites > 0 then lines[#lines + 1] = ("writes that did not work: %d"):format(S.failedWrites) end
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
    local word = (args[1] or ""):lower()
    local value = tonumber(word)
    if word == "reload" then
        local ok, why = Settings:reload(true)
        lines = { ok and ("settings read: " .. summary()) or ("settings not read: " .. tostring(why)) }
    elseif value ~= nil then
        Settings:set("Multiplier", value, "console")       -- "xp 2.5" sets the multiplier and writes it into config.lua
        lines = { "multiplier set: " .. summary() }
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
-- The hero is put into the world again (a loaded save, a respawn): what the
-- experience does in the next moments is not a gain.
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
        rest()
    end)
end)
for _, name in ipairs({ "xp", "g1r_xp" }) do
    if type(RegisterConsoleCommandHandler) == "function" then
        pcall(RegisterConsoleCommandHandler, name, console)
    end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; the experience multiplier is disabled.")
    return
end
LoopInGameThreadWithDelay(Cfg.CheckMilliseconds, function()
    local ok, err = pcall(tick)
    if not ok then L.once("tick:" .. tostring(err), "update error: " .. tostring(err)) end
end)

if otherAtWork() then standDown(otherAtWork()) end
log(("v%s loaded: %s"):format(VERSION, summary()))

if DIAG then
    pcall(function()
        DIAG.status(statusLines)
        DIAG.dump(function()
            return {
                version = VERSION,
                enabled = Cfg.Enabled, multiplier = Cfg.Multiplier,
                large_gain_from = Cfg.LargeGainFrom, large_gain_multiplier = Cfg.LargeGainMultiplier,
                show_message = Cfg.ShowMessage,
                log_gains = Cfg.LogGains, max_gain = Cfg.MaxGain, settle_seconds = Cfg.SettleSeconds,
                found_through = S.via, attributes = S.setName, experience = S.total, level = S.level,
                gains = S.gains, added = S.added, last_gain = S.lastGain, skipped_jumps = S.skipped,
                failed_writes = S.failedWrites, other_multiplier = S.other,
            }
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "XP_TEST")) == "table" then
    local T = rawget(_G, "XP_TEST")
    T.state, T.console, T.status, T.tick, T.settings, T.times = S, console, statusLines, tick, Settings, times
end
