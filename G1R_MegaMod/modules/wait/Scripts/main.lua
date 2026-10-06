-- ============================================================================
-- Waiting (module wait of G1R_MegaMod) - Gothic 1 Remake, UE4SS Lua
--
-- Skips game time: a short and a long step in minutes and two times of day
-- ("until morning", "until evening"), each with a key of its own, a button in
-- the in-game mod menu and a console word (wait 30, wait until 8).
--
-- How it works: the game's clock is one number (seconds since the game
-- began) in its time subsystem, and the game's own SkipTime adds to it -
-- nothing else; everything that goes by the clock (day plans of the people,
-- timers) catches up at the game's next step, as after sleeping in a bed.
-- A key, a button or a console word only leaves a request. The module's loop
-- then looks at the game: is a hero there, is the game paused, has he a
-- weapon drawn, is he talking, is the clock running. A quarter second later
-- it reads the clock again (standing still = the game lets no time pass now;
-- jumped = somebody else has just skipped time), skips, and reads the clock
-- once more to see that it really moved. A way of skipping that leaves the
-- clock where it was is not used again in this run and the next one is tried:
--   1. SkipTime with a plain value { TotalSeconds = seconds }
--   2. SkipTime with a value made by the game's time library (FromSeconds)
--   3. writing the clock itself (which is all that SkipTime does)
-- The next way is only tried after another look has shown the clock still
-- unmoved, so one request never skips twice.
--
-- While nothing is asked the module does not look at the game at all.
--
-- One wait key at a time: the loader does not load this module while the mod
-- G1R_WaitOnT is enabled.
--
-- Settings: schema.lua describes them, config.lua holds them; the settings
-- app and the in-game mod menu change them while the game runs.
-- ============================================================================

local VERSION = "1.0.1"
local TAG = "G1R_Wait"

local KIT, SETTINGS = G1R_KIT, G1R_SETTINGS
-- Diagnostics handle of the loader; nil when the diagnostics are off, and then
-- nothing behind `if DIAG` runs.
local DIAG = G1R_DIAG
if type(KIT) ~= "table" or type(SETTINGS) ~= "table" then
    print("[" .. TAG .. "] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started\n")
    return
end
if DIAG then pcall(DIAG.version, VERSION) end

local pcall, type, tostring, tonumber, ipairs = pcall, type, tostring, tonumber, ipairs
local floor, max, abs = math.floor, math.max, math.abs
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
-- What the module knows about the game (dev/facts/wait.md)
-- ---------------------------------------------------------------------------
local DAY = 86400                       -- game seconds in a day
local SUBSYSTEM = "GameTimeSubsystem"   -- the game's clock: CurrentGameTime.TotalSeconds, SkipTime(FInGameTime)
local LIBRARY = "FInGameTimeStatics"    -- /Script/G1R: FromSeconds(seconds) -> FInGameTime
local LOOK_GAP = 0.125                  -- real seconds that must lie between the two clock readings of a request
local JUMP, JUMP_PER_SECOND = 60, 60    -- more game seconds than this between the two readings is not the clock's own pace
local LATE = 30                         -- game seconds a skip that shows a look later must at least amount to (beyond the clock's own pace)
local SAY_AGAIN = 10                    -- real seconds before the same reason for not skipping is logged again
local SINGLE = 16777216                 -- 2^24: up to here single precision (SkipTime rounds to it) is exact to the second

-- The four waits. `n` is the number in the kit's key binding ("wait.1" ...):
-- the kit runs bindings in that order when two of them have the same key.
local WAITS = {
    { n = 1, name = "short wait", key = "ShortKey", minutes = "ShortMinutes", button = "SkipShort" },
    { n = 2, name = "long wait", key = "LongKey", minutes = "LongMinutes", button = "SkipLong" },
    { n = 3, name = "wait until morning", key = "MorningKey", hour = "MorningHour", button = "SkipMorning" },
    { n = 4, name = "wait until evening", key = "EveningKey", hour = "EveningHour", button = "SkipEvening" },
}

-- The hero's animation holds what he is doing as yes/no values (property
-- layout of GothicAnimInstance). One per switch of the group "When not to wait".
local FLAGS = {
    { setting = "NotInFight", property = "m_IsInCombat", reason = "fight" },
    { setting = "NotInConversation", property = "bIsInConversation", reason = "talk" },
    { setting = "NotInCutscene", property = "bIsInCinematic", reason = "cutscene" },
}

-- Why no time was skipped. `quiet`: never shown on screen (the key was simply
-- pressed again; during a map load there is no screen to show it on).
local REASONS = {
    busy = { text = "another skip is still under way", quiet = true },
    cooldown = { text = "the last skip was a moment ago", quiet = true },
    loading = { text = "a map is loading", quiet = true },
    broken = { text = "skipping time does not work in this game (see earlier in this log)" },
    nohero = { text = "the hero was not found (no game loaded?)" },
    paused = { text = "the game is paused" },
    noclock = { text = "the game's clock was not found" },
    fight = { text = "the hero has a weapon drawn" },
    talk = { text = "the hero is in a conversation" },
    cutscene = { text = "a cutscene is playing" },
    stopped = { text = "the game's clock is standing still (a cutscene or a menu)" },
    jumped = { text = "the clock has just jumped on its own (sleeping, or another mod that skips time)" },
    reached = { text = "the clock has reached that hour by itself meanwhile" },
}

-- ---------------------------------------------------------------------------
-- State of this run
-- ---------------------------------------------------------------------------
local S = {
    job = nil,                  -- the skip that was asked for and is not finished yet
    lastAt = nil,               -- when the last skip was finished (for the cooldown)
    works = nil,                -- name of the way that moved the clock
    failed = {},                -- name of a way -> why it left the clock where it was
    called = {},                -- name of a way -> it has been called in this run
    broken = false,             -- every way failed: nothing is tried again in this run
    skips = 0, refused = 0,
    last = nil,                 -- the last skip, as text
    lastRefusal = nil,          -- the last reason for not skipping
    saidAt = {},                -- reason -> when it was logged last
    keys = {},                  -- number of a wait -> its key ("" = none)
    asked = { key = 0, menu = 0, console = 0 },
    flags = {},                 -- what the hero's animation said at the last request
}
local Noted = {}
local function note(key, value, detail)
    if DIAG and Noted[key] ~= value then
        Noted[key] = value
        DIAG.note(key, value, detail)
    end
end

local function firstLine(text) return (tostring(text):match("^[^\r\n]*") or "") end
local function count(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end
-- 1800 -> "30 minutes", 9000 -> "2 hours 30 minutes"
local function span(seconds)
    local minutes = floor(seconds / 60 + 0.5)
    if minutes < 1 then return "less than a minute" end
    local hours = floor(minutes / 60)
    minutes = minutes - hours * 60
    if hours == 0 then return count(minutes, "minute") end
    if minutes == 0 then return count(hours, "hour") end
    return count(hours, "hour") .. " " .. count(minutes, "minute")
end
-- The clock as the game shows it: 52200 -> "14:30"
local function clockText(t)
    local s = floor(t % DAY)
    local hours = floor(s / 3600)
    local minutes = floor((s - hours * 3600) / 60)
    return ("%02d:%02d"):format(hours, minutes)
end
local function dayText(t) return ("day %d %s"):format(floor(t / DAY), clockText(t)) end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local Settings, problem = SETTINGS.open({ module = "wait", dir = SCRIPT_DIR, log = log })
if not Settings then
    log("the settings could not be set up (" .. tostring(problem) .. "); not started")
    return
end
local Cfg = Settings.values

-- What a wait skips, as text: "30 minutes" / "until 08:00"
local function amountText(w)
    if w.minutes then return span(Cfg[w.minutes] * 60) end
    return ("until %02d:00"):format(Cfg[w.hour])
end
local function summary()
    if not Cfg.Enabled then return "switched off in the settings" end
    if S.broken then return "skipping time does not work in this game" end
    local parts = {}
    for _, w in ipairs(WAITS) do
        local key = S.keys[w.n]
        if key and key ~= "" then parts[#parts + 1] = key .. " = " .. amountText(w) end
    end
    if #parts == 0 then return "no key bound (buttons in the in-game menu; console: wait 30, wait until 8)" end
    return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------------------
-- Not skipping, and saying why
-- ---------------------------------------------------------------------------
local function refuse(code)
    local reason = REASONS[code]
    S.refused = S.refused + 1
    S.lastRefusal = reason.text
    local now = clock()
    if S.saidAt[code] == nil or now - S.saidAt[code] >= SAY_AGAIN then
        S.saidAt[code] = now
        log("no time skipped: " .. reason.text)
    end
    if Cfg.ShowRefused and not reason.quiet then KIT.notify("Cannot wait now: " .. reason.text, "wait") end
    return reason.text
end
-- The request in work ends without a skip.
local function drop(code)
    S.job = nil
    return refuse(code)
end

-- ---------------------------------------------------------------------------
-- A request: from a key, a button of the in-game menu or the console. It does
-- not look at the game; the loop takes it up at its next turn.
-- spec: { minutes = n } or { hour = h }. Returns true, or false and why not.
-- ---------------------------------------------------------------------------
local function request(spec, source)
    if not Cfg.Enabled then return false, "switched off in the settings" end
    S.asked[source] = S.asked[source] + 1
    if source == "key" then note("wait.key_press", "seen") end
    local code = nil
    if S.job ~= nil then
        code = "busy"
    elseif S.broken then
        code = "broken"
    elseif KIT.loading() then
        code = "loading"
    elseif S.lastAt ~= nil and clock() - S.lastAt < Cfg.Cooldown then
        code = "cooldown"
    end
    if code then return false, refuse(code) end
    S.job = { minutes = spec.minutes, hour = spec.hour, source = source, stage = "first", at = clock() }
    return true
end
local function requestWait(w, source)
    if w.minutes then return request({ minutes = Cfg[w.minutes] }, source) end
    return request({ hour = Cfg[w.hour] }, source)
end

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------
local function bind(w)
    local ok, result = KIT.bindKey("wait." .. w.n, Cfg[w.key], w.press)
    if ok then
        S.keys[w.n] = result
    else
        S.keys[w.n] = ""
        L.once("key:" .. w.n .. ":" .. tostring(Cfg[w.key]) .. ":" .. tostring(result), ("the key %s for the %s could not be bound (%s); the button in the in-game menu and the console still work")
            :format(tostring(Cfg[w.key]), w.name, tostring(result)))
    end
end
-- Two waits with the same key: one press can only be one skip.
local function sameKeys()
    for i, a in ipairs(WAITS) do
        for j = i + 1, #WAITS do
            local b = WAITS[j]
            if S.keys[a.n] ~= "" and S.keys[a.n] == S.keys[b.n] then
                L.once("same:" .. a.n .. b.n .. S.keys[a.n], ("the %s and the %s have the same key %s: a press takes the %s"):format(a.name, b.name, S.keys[a.n], a.name))
            end
        end
    end
end
for _, w in ipairs(WAITS) do
    w.press = function() requestWait(w, "key") end
    bind(w)
    -- what the key does, for the list of keys (module keys)
    KIT.describeKey("wait." .. w.n, function()
        if w.minutes then return ("wait %g minutes"):format(Cfg[w.minutes]) end
        return ("wait until %g:00"):format(Cfg[w.hour])
    end)
end
sameKeys()

Settings.onChange = function(_, changed, why)
    for _, key in ipairs(changed) do
        for _, w in ipairs(WAITS) do
            if w.key == key then bind(w) end
        end
        if (key == "ShowMessage" or key == "ShowRefused") and not Cfg[key] then KIT.hideToast("wait") end
    end
    sameKeys()
    if not Cfg.Enabled then S.job = nil end
    log(("settings changed (%s): %s"):format(why == "menu" and "in-game menu" or (why == "file" and "config.lua" or tostring(why)), summary()))
end
Settings.onAction = function(key)
    for _, w in ipairs(WAITS) do
        if w.button == key then requestWait(w, "menu") end
    end
end

-- ---------------------------------------------------------------------------
-- What the hero is doing: the reason not to skip now, or nil. Only the values
-- whose switch is on are read.
-- ---------------------------------------------------------------------------
local function heroState(pawn)
    local wanted = false
    for _, f in ipairs(FLAGS) do
        if Cfg[f.setting] then wanted = true end
    end
    S.flags = {}
    if not wanted then return nil end
    local animation = KIT.get(KIT.get(pawn, "Mesh"), "AnimScriptInstance")
    local reason, unreadable = nil, nil
    if not KIT.valid(animation) then
        unreadable = "the hero's animation"
    else
        for _, f in ipairs(FLAGS) do
            if Cfg[f.setting] then
                local value = KIT.get(animation, f.property)
                if type(value) ~= "boolean" then
                    unreadable = (unreadable and (unreadable .. ", ") or "") .. f.property
                else
                    S.flags[f.reason] = value
                    if value and reason == nil then reason = f.reason end
                end
            end
        end
    end
    if unreadable then
        note("wait.states", "not readable", unreadable)
        L.once("states:" .. unreadable, "what the hero is doing could not be read (" .. unreadable .. "): the switches under \"When not to wait\" that need it have no effect")
    else
        note("wait.states", "readable")
    end
    return reason
end

-- Asked again right before every call that moves the clock: between two looks the hero can draw a weapon, begin a
-- talk or the game be paused. Why not to skip now, or nil.
local function stillFine()
    local pawn = KIT.pawn()
    if not pawn then return "nohero" end
    if KIT.paused() then return "paused" end
    return heroState(pawn)
end

-- ---------------------------------------------------------------------------
-- The ways of moving the clock, in the order they are tried. Each returns
-- whether its call went through, and the error when not. Whether the clock
-- moved is checked by the caller.
-- ---------------------------------------------------------------------------
local WAYS = {
    { name = "table", text = "SkipTime with a plain value",
      call = function(subsystem, seconds)
          return KIT.try(subsystem, "SkipTime", { TotalSeconds = seconds })
      end },
    { name = "library", text = "SkipTime with a value from the game's time library",
      call = function(subsystem, seconds)
          local library = KIT.findDefault(LIBRARY, "G1R")
          note("wait.time_library", library and "found" or "not found")
          if not library then return false, "the game's time library was not found" end
          local made, duration = KIT.try(library, "FromSeconds", seconds)
          if not made then return false, "FromSeconds: " .. firstLine(duration) end
          return KIT.try(subsystem, "SkipTime", duration)
      end },
    { name = "clock", text = "writing the clock",
      call = function(subsystem, seconds, before)
          local current = KIT.get(subsystem, "CurrentGameTime")
          if KIT.number(KIT.get(current, "TotalSeconds")) == nil then current = KIT.unwrap(current) end
          -- only a value whose seconds can be read is written to
          if KIT.number(KIT.get(current, "TotalSeconds")) == nil then return false, "the clock is not readable as a property" end
          return pcall(function() current.TotalSeconds = before + seconds end)
      end },
}
-- The first way that has not failed in this run (the one that worked last time).
local function nextWay()
    for _, way in ipairs(WAYS) do
        if S.failed[way.name] == nil then return way end
    end
    return nil
end

-- Game seconds a request still has to skip when the clock is at `t`.
local function remaining(job, t)
    if job.minutes then return job.minutes * 60.0 end
    if job.target == nil then
        local ahead = (job.hour * 3600 - t) % DAY       -- to the next time the clock shows that hour
        if ahead == 0 then ahead = DAY end
        -- SkipTime rounds the clock to single precision: aim a little past the hour, never before it
        job.target = t + ahead + max(1, (t + ahead) / SINGLE)
    end
    return job.target - t
end

-- ---------------------------------------------------------------------------
-- The skip
-- ---------------------------------------------------------------------------
local function done(job, after, applied, now)
    local way, moved = job.way, after - job.before
    S.job, S.lastAt, S.works = nil, now, way.name
    S.skips = S.skips + 1
    note("wait.way", way.name)
    note("wait.applied", applied)
    if applied == "at once" then
        if abs(moved - job.seconds) <= 1 + max(1, after / SINGLE) then
            note("wait.moved", "as asked")
        else
            note("wait.moved", "differs", ("asked %.0f s, moved %.0f s"):format(job.seconds, moved))
            L.once("moved", ("the clock moved by %.0f seconds where %.0f were asked for"):format(moved, job.seconds))
        end
    end
    local what = span(job.seconds)
    local line = ("%s, %s -> %s, by %s (seen %s)"):format(what, dayText(job.before), dayText(after), way.text, applied)
    S.last = line
    if S.skips == 1 and DIAG then DIAG.event("first skip: " .. line) end
    local tell = S.skips == 1 or Cfg.LogSkips or job.source == "console"
    if tell then log("skipped " .. line) end
    if Cfg.ShowMessage then KIT.notify(what .. " later - " .. clockText(after), "wait") end
end

-- Calls the first way that has not failed and reads the clock again. `before`:
-- the clock as the caller has just read it.
local function attempt(job, now, before)
    local subsystem = KIT.subsystem("state", SUBSYSTEM, "G1R")
    if not subsystem then return drop("noclock") end
    local way = nextWay()
    local seconds = remaining(job, before)
    -- an "until" request: the clock can have passed the moment aimed at by itself - between the two looks, or
    -- while a way that did nothing was tried. Then nothing is left to skip: an amount of zero or less would put
    -- the clock back, and no way could be seen to work
    if seconds <= 0 then return drop("reached") end
    job.way, job.before, job.seconds, job.stage, job.calledAt = way, before, seconds, "check", now
    -- the first call of a way in a run is announced on disk before it is made: should the game go down
    -- inside it, the diagnostics end with that line
    local first = DIAG ~= nil and not S.called[way.name]
    S.called[way.name] = true
    if first then DIAG.crumb("first call: " .. way.text) end
    local ok, why = way.call(subsystem, seconds, before)
    job.problem = (not ok) and firstLine(why) or nil
    if first then DIAG.event("first call returned: " .. (job.problem or "no error")) end
    local after = KIT.gameSeconds()
    if after ~= nil and after - before >= seconds * 0.5 then done(job, after, "at once", now) end
end

-- First look: is this a moment to skip time at all? Takes the first reading of the clock.
local function firstLook(job, now)
    local pawn = KIT.pawn()
    if not pawn then return drop("nohero") end
    if KIT.paused() then return drop("paused") end
    local t = KIT.gameSeconds()
    note("wait.clock", t and "found" or "not found")
    if t == nil then return drop("noclock") end
    local state = heroState(pawn)
    if state then return drop(state) end
    job.first, job.firstAt, job.stage = t, now, "second"
    -- an "until" request: whether its hour is today's or tomorrow's is decided now, with this first reading
    -- (the moment aimed at is kept in the request). An hour the clock reaches by itself before the skip is
    -- made ends the request there ("reached") instead of turning into a skip of a whole day
    remaining(job, t)
end

-- Second look: is the clock running at its own pace? Then the skip.
local function secondLook(job, now)
    local t = KIT.gameSeconds()
    if t == nil then return drop("noclock") end
    local passed = t - job.first
    if passed > JUMP + JUMP_PER_SECOND * (now - job.firstAt) then
        note("wait.clock_running", "jumped", ("%.0f game seconds in %.2f s"):format(passed, now - job.firstAt))
        return drop("jumped")
    end
    if passed <= 0 then
        note("wait.clock_running", "standing still")
        if Cfg.NotWhenClockStopped then return drop("stopped") end
    else
        note("wait.clock_running", "yes")
    end
    job.pace = max(passed, 0) / (now - job.firstAt)        -- the clock's own pace: game seconds per real second
    -- an "until" request made a moment before its hour: the clock reached the hour between the request and the
    -- first look, and the first reading took the hour for tomorrow's. With the pace known it shows - the first
    -- reading stood past the hour by less than the clock gained since the request. Nothing is left to skip.
    if job.hour and (job.first - job.hour * 3600) % DAY < job.pace * (job.firstAt - job.at) then return drop("reached") end
    local stop = stillFine()
    if stop then return drop(stop) end
    attempt(job, now, t)
end

-- A look after a call that had not moved the clock at once: has it moved now?
-- If not, that way does nothing in this game and the next one is tried.
local function checkLook(job, now)
    local after = KIT.gameSeconds()
    if after == nil then return drop("noclock") end
    -- what the clock gained beyond its own pace since the call: a stall before this look is not a skip
    local gained = after - job.before - job.pace * (now - job.calledAt)
    if gained >= max(job.seconds * 0.5, LATE) then return done(job, after, "a moment later", now) end
    local way = job.way
    local why = job.problem or "the clock stayed where it was"
    S.failed[way.name] = why
    S.works = nil
    L.once("way:" .. way.name, way.text .. " does not move the game's clock (" .. why .. ")")
    if nextWay() == nil then
        S.broken = true
        local tried = {}
        for _, w in ipairs(WAYS) do tried[#tried + 1] = w.name .. ": " .. tostring(S.failed[w.name]) end
        note("wait.way", "none", table.concat(tried, "; "))
        L.once("broken", "skipping time does not work in this game: none of the " .. #WAYS .. " ways moved the clock. No more skips are tried until the game is started again.")
        return drop("broken")
    end
    local stop = stillFine()
    if stop then return drop(stop) end
    attempt(job, now, after)
end

local function tick()
    if KIT.loading() then return end
    local job = S.job
    if job == nil then return end           -- nothing asked: the game is not looked at
    local now = clock()
    if job.stage == "first" then
        firstLook(job, now)
    elseif job.stage == "second" then
        if now - job.firstAt >= LOOK_GAP then secondLook(job, now) end
    else
        checkLook(job, now)
    end
end

-- ---------------------------------------------------------------------------
-- Status (console command wait, the loader's reports). Built from what the
-- module holds; it does not call into the game.
-- ---------------------------------------------------------------------------
local function statusLines()
    local lines = { ("v%s | %s"):format(VERSION, summary()) }
    local waits = {}
    for _, w in ipairs(WAITS) do
        local key = S.keys[w.n]
        waits[#waits + 1] = ("%s: %s, %s"):format(w.name, amountText(w), (key and key ~= "") and ("key " .. key) or "no key")
    end
    lines[#lines + 1] = table.concat(waits, " | ")
    lines[#lines + 1] = ("skips: %d%s"):format(S.skips, S.last and ("; last: " .. S.last) or "")
    if S.refused > 0 then
        lines[#lines + 1] = ("not skipped: %s; last reason: %s"):format(count(S.refused, "time"), tostring(S.lastRefusal))
    end
    for _, way in ipairs(WAYS) do
        if S.failed[way.name] then
            lines[#lines + 1] = ("%s does not work here: %s"):format(way.text, S.failed[way.name])
        end
    end
    if S.job then lines[#lines + 1] = "a skip is under way" end
    return lines
end

-- wait            status
-- wait reload     read config.lua now
-- wait 30         skip 30 minutes
-- wait until 8    skip to the next 08:00
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
    local spec, what = nil, nil
    if word == "reload" then
        local ok, why = Settings:reload(true)
        lines = { ok and ("settings read: " .. summary()) or ("settings not read: " .. tostring(why)) }
    elseif word == "until" then
        local hour = tonumber(args[2])
        if hour and hour == floor(hour) and hour >= 0 and hour <= 23 then
            spec, what = { hour = hour }, ("until %02d:00"):format(hour)
        else
            lines = { "wait until <hour>: an hour from 0 to 23 (wait until 8)" }
        end
    elseif tonumber(word) ~= nil then
        local minutes = tonumber(word)
        if minutes == floor(minutes) and minutes >= 1 and minutes <= 1440 then
            spec, what = { minutes = minutes }, span(minutes * 60)
        else
            lines = { "wait <minutes>: whole minutes from 1 to 1440 (wait 30)" }
        end
    else
        lines = statusLines()
    end
    if spec then
        local ok, why = request(spec, "console")
        lines = { ok and (what .. ": asked for; the result follows in this log") or (what .. ": not skipped - " .. tostring(why)) }
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
-- A request does not survive a change of the world.
KIT.onWorldChange(function() S.job = nil end)
for _, name in ipairs({ "wait", "g1r_wait" }) do
    if type(RegisterConsoleCommandHandler) == "function" then
        pcall(RegisterConsoleCommandHandler, name, console)
    end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    S.broken = true         -- nothing would take a request up: none is accepted
    log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; waiting is disabled.")
    return
end
LoopInGameThreadWithDelay(250, function()
    local ok, err = pcall(tick)
    if not ok then
        S.job = nil
        L.once("tick:" .. tostring(err), "update error: " .. tostring(err))
    end
end)

log(("v%s loaded: %s"):format(VERSION, summary()))

if DIAG then
    pcall(function()
        DIAG.status(statusLines)
        DIAG.dump(function()
            local waits = {}
            for _, w in ipairs(WAITS) do
                waits[w.name] = { key = S.keys[w.n] or "", minutes = w.minutes and Cfg[w.minutes] or nil, hour = w.hour and Cfg[w.hour] or nil }
            end
            local failed = {}
            for _, way in ipairs(WAYS) do failed[way.name] = S.failed[way.name] end
            return {
                version = VERSION, enabled = Cfg.Enabled, cooldown = Cfg.Cooldown, waits = waits,
                not_in_fight = Cfg.NotInFight, not_in_conversation = Cfg.NotInConversation, not_in_cutscene = Cfg.NotInCutscene,
                not_when_clock_stopped = Cfg.NotWhenClockStopped, show_message = Cfg.ShowMessage, show_refused = Cfg.ShowRefused,
                log_skips = Cfg.LogSkips,
                skips = S.skips, last_skip = S.last, not_skipped = S.refused, last_reason = S.lastRefusal,
                way = S.works, failed_ways = failed, broken = S.broken,
                asked_by_key = S.asked.key, asked_by_menu = S.asked.menu, asked_by_console = S.asked.console,
                hero_weapon_drawn = S.flags.fight, hero_in_conversation = S.flags.talk, hero_in_cutscene = S.flags.cutscene,
                under_way = S.job ~= nil,
            }
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "WAIT_TEST")) == "table" then
    local T = rawget(_G, "WAIT_TEST")
    T.state, T.console, T.status, T.tick, T.settings = S, console, statusLines, tick, Settings
    T.request, T.span, T.clockText, T.dayText, T.remaining, T.ways, T.reasons = request, span, clockText, dayText, remaining, WAYS, REASONS
end
