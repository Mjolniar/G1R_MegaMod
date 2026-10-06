-- ============================================================================
-- Mana and health regeneration (module regen of G1R_MegaMod) - Gothic 1 Remake,
-- UE4SS Lua
--
-- Every few seconds the hero gets some mana and some health back: a share of
-- his maximum, a fixed number of points, or both, until the chosen part of the
-- maximum is reached. After the value went down (a spell, a hit) regeneration
-- waits for the time set. Mana can depend on the hero's magic circle, and both
-- can run slower (or not at all) while a weapon or spell is drawn.
--
-- How it works. Twice a second the module looks at the hero's Mana and Health
-- (attributes of his player state). Time is counted in real seconds, and only
-- while a game runs: not during a map load, not while the engine is paused,
-- not while the game's own clock stands still; a look never counts for more
-- than two look intervals, so a stall, a sleep or a skipped day cannot pour
-- out hours of regeneration. The game keeps both values as whole numbers (it
-- rounds them itself), so the module adds whole points and carries the
-- fraction over to the next step.
--
-- The value is changed the way the game changes it: the attribute set's own
-- function TrySetAttributeBaseValue hands the new value to the ability system,
-- which rounds and clamps it and tells the bars on screen. Only when that does
-- not work the two numbers are written directly (the bars then follow with the
-- next change the game makes itself). Every write is read back.
--
-- The game blocks casting with a tag "State.OutMana" when a spell has used up
-- the mana, and takes the tag off only when one of its own effects (a potion)
-- brings mana back. Mana that comes back through this module would stay
-- blocked, so after a step from zero the module takes the tag off with the
-- same function the game uses (RemoveTag of the hero's ability system).
--
-- Never: a hero who is dead, unconscious or being restored from a save gets
-- nothing; nothing goes above the limit or the maximum; while every amount is
-- 0 or the module is switched off the game is not looked at at all.
--
-- One regeneration at a time: the loader does not load this module while the
-- mod G1R_RegenMana is enabled.
--
-- Settings: schema.lua describes them, config.lua holds them; the settings
-- app and the in-game mod menu change them while the game runs.
-- ============================================================================

local VERSION = "1.0.0"
local TAG = "G1R_Regen"

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
local floor, abs, min, max = math.floor, math.abs, math.min, math.max
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
-- The two things that regenerate, and what the game calls them
-- ---------------------------------------------------------------------------
local MANA = {
    key = "Mana", word = "mana", top = "MaxMana",           -- AttributeSet_Mana: Mana, MaxMana
    on = "ManaEnabled", percent = "ManaPercent", flat = "ManaFlat", seconds = "ManaSeconds", upTo = "ManaUpTo",
    pause = "ManaPause", armed = "ManaArmedPercent",        -- its settings
    foundBy = "regen.mana.set_found_by", readable = "regen.mana.readable", write = "regen.mana.write",     -- its diagnostics notes
    slot = "regen.mana",                                    -- the place of its note on screen
}
local HEALTH = {
    key = "Health", word = "health", top = "MaxHealth",     -- AttributeSet_Health: Health, MaxHealth
    on = "HealthEnabled", percent = "HealthPercent", flat = "HealthFlat", seconds = "HealthSeconds", upTo = "HealthUpTo",
    pause = "HealthPause", armed = "HealthArmedPercent",
    foundBy = "regen.health.set_found_by", readable = "regen.health.readable", write = "regen.health.write",
    slot = "regen.health",
}
local BOTH = { MANA, HEALTH }

-- Gameplay tags of the game (native tags of the executable, see dev/facts/regen.md)
local TAG_OUT_OF_MANA = "State.OutMana"         -- the block on casting
local TAG_ARMED = "State.Combat"                -- a weapon, the fists or a spell is drawn
local TAGS_DOWN = { "State.Dead", "State.Defeated", "State.RestoringSave" }

local TRIES = 3                 -- failures in a row before a way of doing something is given up for this run
local RETRY_SECONDS = 5         -- a value that cannot be read is asked for again after this long
local CLOCK_PATIENCE = 10       -- seconds without a readable game clock before it is left alone

-- ---------------------------------------------------------------------------
-- State of this run
-- ---------------------------------------------------------------------------
-- What is known about one of the two values. forget() puts the first part back to "nothing is watched".
local function forget(st)
    st.setName, st.via = nil, nil       -- full name of the attributes the value was last read from; how they were found
    st.value, st.top = nil, nil         -- the value and its maximum at the last look / step
    st.last = nil                       -- the value at the last look (nil = the next look only takes the value)
    st.pause = 0                        -- seconds of waiting left after a loss
    st.waited = 0                       -- seconds counted towards the next step
    st.carry = 0                        -- the fraction of a point that was not added yet
    st.phase, st.why = nil, nil         -- "wait" / "run" / "full" / "down", and why the hero gets nothing
    st.resting = true                   -- nothing was added since the last wait or limit: the next added step says so on screen
end
local function newState()
    local st = {
        failed = 0,             -- steps in a row that could not be written
        givenUp = false,        -- three such steps: not tried again in this run
        unreadableUntil = 0,    -- a value that could not be read is not asked for before this clock value
        steps = 0, added = 0, losses = 0,
    }
    forget(st)
    return st
end
local S = {
    gameFails = 0,              -- failures in a row of the game's own way of setting a value
    direct = false,             -- Method "auto" has fallen back to the direct write for this run
    tagFails = 0, tagsOff = false,
    tagYes = false,             -- a tag question was answered with yes at least once in this run: the answers are real
    clearFails = 0, cleared = 0,
    how = nil,                  -- how the last value was written
    counted = 0,                -- seconds of play counted in this run
    pausedLooks = 0,            -- looks that counted nothing because the engine was paused
    stoodLooks = 0,             -- looks that counted nothing because the game's clock stood still
    Mana = newState(), Health = newState(),
}
-- Nothing is watched: the next look at the game starts afresh.
local function rest()
    forget(S.Mana)
    forget(S.Health)
    S.awake = false             -- the module is looking at the game
    S.nextLook = 0              -- the clock value of the next look
    S.lookAt = nil              -- the clock value of the last look that counts (nil = the next one counts no time)
    S.halt = nil                -- why the last look counted no time (nil = it did, or nothing says why not)
    S.game = nil                -- the game's own clock at the last look
    S.blindSince = nil          -- since when the game's clock cannot be read (nil = it can)
    S.clockOff = false          -- it could not be read for ten seconds: not asked for again in this world
end
rest()
local Noted = {}
local function note(key, value, detail)
    if DIAG and Noted[key] ~= value then
        Noted[key] = value
        DIAG.note(key, value, detail)
    end
end

-- The first line of an error text, without the "file:line:" in front (the path of the game folder says nothing
-- about the problem and does not belong into a log).
local function reason(text) return ((tostring(text):match("^[^\r\n]*") or ""):gsub("^.-:%d+: ", "")) end
-- A number as short as it can be written: 2, 0.5, 1.25
local function num(v) return (("%.2f"):format(v):gsub("%.?0+$", "")) end
local function whole(v) return floor(v + 0.5) end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local Settings, problem = SETTINGS.open({ module = "regen", dir = SCRIPT_DIR, log = log })
if not Settings then
    log("the settings could not be set up (" .. tostring(problem) .. "); not started")
    return
end
local Cfg = Settings.values

-- True when this resource has something to regenerate.
local function active(r)
    return Cfg[r.on] and (Cfg[r.percent] > 0 or Cfg[r.flat] > 0) and Cfg[r.upTo] > 0
end
-- True while there is nothing to regenerate at all: the game is not looked at.
local function idle()
    return not Cfg.Enabled or not (active(MANA) or active(HEALTH))
end
local function describe(r)
    local amount
    if Cfg[r.flat] > 0 and Cfg[r.percent] > 0 then
        amount = ("+%s and +%s%%"):format(num(Cfg[r.flat]), num(Cfg[r.percent]))
    elseif Cfg[r.percent] > 0 then
        amount = ("+%s%%"):format(num(Cfg[r.percent]))
    else
        amount = "+" .. num(Cfg[r.flat])
    end
    local text = ("%s %s every %s s up to %d%%, pause %d s"):format(r.word, amount, num(Cfg[r.seconds]), Cfg[r.upTo], Cfg[r.pause])
    if Cfg[r.armed] ~= 100 then text = text .. (", %d%% with a weapon drawn"):format(Cfg[r.armed]) end
    if r == MANA and Cfg.ManaByCircle then text = text .. ", by magic circle" end
    return text
end
local function summary()
    if not Cfg.Enabled then return "switched off in the settings" end
    if idle() then return "nothing to regenerate (every amount is 0 or switched off)" end
    local parts = {}
    for _, r in ipairs(BOTH) do
        if active(r) then parts[#parts + 1] = describe(r) end
    end
    return table.concat(parts, "; ")
end

-- ---------------------------------------------------------------------------
-- Names and tags as the game takes them: an FName, and a gameplay tag as a
-- table with its name. Made once per text and kept.
-- ---------------------------------------------------------------------------
local Names, Tags = {}, {}
local function nameOf(text)
    local n = Names[text]
    if n == nil then
        local ok, made = pcall(function() return FName(text) end)
        n = (ok and made ~= nil) and made or false
        Names[text] = n
    end
    return n or nil
end
local function tagOf(text)
    local t = Tags[text]
    if t == nil then
        local n = nameOf(text)
        t = n and { TagName = n } or false
        Tags[text] = t
    end
    return t or nil
end

-- The hero's ability system (it holds his gameplay tags), or nil.
local function ability()
    local state = KIT.playerState()
    local system = state and KIT.get(state, "AbilitySystemComponent") or nil
    if KIT.valid(system) then return system end
    return nil
end

-- Does the hero's ability system have this tag (or one below it)? true /
-- false, or nil when that cannot be asked.
local function hasTag(system, text)
    if S.tagsOff then return nil end
    local ok, result = false, "the hero has no ability system"
    if system ~= nil then
        local tag = tagOf(text)
        if tag then ok, result = KIT.try(system, "HasGameplayTag", tag) else result = "this UE4SS build has no FName" end
    end
    if ok and type(result) == "boolean" then
        S.tagFails = 0
        -- a no is also what comes back when the question does not arrive as it was asked: only a yes shows that
        -- the answers are real
        if result then S.tagYes = true end
        note("regen.tags", S.tagYes and "readable" or "only no so far")
        return result
    end
    S.tagFails = S.tagFails + 1
    if S.tagFails >= TRIES then
        S.tagsOff = true
        local why = reason(ok and ("the answer was " .. tostring(result)) or result)
        L.once("tags", "the hero's gameplay tags cannot be asked (" .. why
            .. "); what cannot be told without them: a drawn weapon, unconsciousness, the block on casting")
        note("regen.tags", "not readable", why)
    end
    return nil
end

-- Why the hero gets nothing now, or nil. The game marks a dead, an
-- unconscious and a just-being-restored hero with tags; no health is the same
-- by the number (and all there is to go by when the tags cannot be asked).
local function down(system, r, value)
    if r == HEALTH and value <= 0 then return "no health" end
    local known = true
    for _, text in ipairs(TAGS_DOWN) do
        local has = hasTag(system, text)
        if has then return text end
        if has == nil then
            known = false
            break
        end
    end
    if r == MANA and not known then
        local health = KIT.attribute("Health", "Health")
        if health ~= nil and health <= 0 then return "no health" end
    end
    return nil
end

-- The share of the amount the hero's magic circle gives (1 = all of it).
-- MagicianLevel: -1 without training, 0 with the basics, 1 to 6 the circles.
local function circleShare(set)
    local level = KIT.readAttribute(set, "MagicianLevel")
    if level == nil then
        L.once("circle", "the hero's magic circle could not be read; mana regenerates as without the circle setting")
        note("regen.circle", "not readable")
        return 1
    end
    level = whole(level)
    note("regen.circle", tostring(level))
    if level < 0 then return Cfg.ManaCircleNone / 100 end
    if level < 1 then return Cfg.ManaCircleNovice / 100 end
    return (Cfg.ManaCircleFirst + (level - 1) * Cfg.ManaCircleStep) / 100
end

-- ---------------------------------------------------------------------------
-- Changing the hero's value
-- ---------------------------------------------------------------------------
-- The game's block on casting: set by the game when a spell used up the mana,
-- taken off by the game only when one of its own effects brings mana back.
-- `before`: the mana the step started from.
local function clearBlock(system, before)
    if not Cfg.ManaClearBlock or S.clearFails >= TRIES then return end
    local has = hasTag(system, TAG_OUT_OF_MANA)
    if has == false and before <= 0 and not S.tagYes then
        -- mana came back from zero, the block is not there, and no tag has answered yes in this run: either the
        -- game sets no block at zero mana, or the questions about the hero's tags do not arrive. Noted with a
        -- value of its own (the diagnostics then do not say "as expected") and said once
        note("regen.mana.block", "not set at zero mana")
        L.once("block:zero", "mana came back from zero, but the game's block on casting (out of mana) was not found: either this game sets none at zero mana,"
            .. " or the hero's tags cannot be read - then regenerated mana cannot be cast until a mana potion is drunk, and ManaArmedPercent / HealthArmedPercent"
            .. " have no effect. To find out which, send UE4SS.log and the megamod's Scripts\\diagnostics folder")
    elseif has == false and not Noted["regen.mana.block"] then
        -- "not set" is only noted while nothing else was: once the block has been taken off the note stays "cleared"
        note("regen.mana.block", "not set")
    end
    if not has then return end
    local ok, result = KIT.try(system, "RemoveTag", tagOf(TAG_OUT_OF_MANA))
    if ok and hasTag(system, TAG_OUT_OF_MANA) == false then
        S.clearFails, S.cleared = 0, S.cleared + 1
        note("regen.mana.block", "cleared")
        if Cfg.LogSteps then log("the game's block on casting (out of mana) was taken off") end
        return
    end
    S.clearFails = S.clearFails + 1
    local why = ok and "the tag is still there" or reason(result)
    L.once("block", "the game's block on casting (out of mana) could not be taken off (" .. why
        .. "); a mana potion takes it off")
    note("regen.mana.block", "still set", why)
end

-- Brings the hero's value from `value` to `target`. Returns the value as it
-- is afterwards and how it was written, or nil and why not.
local function give(r, set, value, base, target)
    local newBase = base + (target - value)
    local method, why = Cfg.Method, nil
    if method == "game" or (method == "auto" and not S.direct) then
        local name = nameOf(r.key)
        local ok, result = false, "this UE4SS build has no FName"
        if name then ok, result = KIT.try(set, "TrySetAttributeBaseValue", name, newBase) end
        local now = KIT.readAttribute(set, r.key)
        if now ~= nil and abs(now - value) >= 0.001 then
            S.gameFails = 0             -- it moved: the game took the value (rounded and clamped by its own rules)
            return now, "ability system"
        end
        if not ok then why = "the call failed: " .. reason(result)
        elseif result ~= true then why = "the game refused (" .. tostring(result) .. ")"
        else why = "the value did not change" end
        S.gameFails = S.gameFails + 1
        L.once("game:" .. why, ("the game's own way of setting %s did not work (%s)"):format(r.word, why))
        if method == "game" then return nil, why end
        if S.gameFails >= TRIES then
            S.direct = true
            L.once("direct", "from now on the values are written directly; the bars on screen follow with the game's next own change")
        end
    end
    local wrote = pcall(function()
        local attribute = set[r.key]
        attribute.BaseValue = newBase
        attribute.CurrentValue = target
    end)
    local now, nowBase = KIT.readAttribute(set, r.key)
    -- the game keeps these numbers in single precision: what comes back may differ in the last digits
    local slack = max(0.001, abs(target) * 0.000001)
    if wrote and now ~= nil and nowBase ~= nil and abs(now - target) <= slack and abs(nowBase - newBase) <= slack then
        return now, "direct write"
    end
    -- it did not arrive as written: what did arrive is taken back, so that the value stays as the game had it
    pcall(function()
        local attribute = set[r.key]
        attribute.BaseValue = base
        attribute.CurrentValue = value
    end)
    return nil, wrote and "the value did not stay" or "the write raised an error"
end

local function show(r, text)
    if Cfg.ShowMessage then KIT.notify(text, r.slot) end
end

local function unreadable(r, st, what)
    L.once("unreadable:" .. what, ("the hero's %s could not be read from %s"):format(what, tostring(st.setName)))
    note(r.readable, "no", what)
    forget(st)
    st.unreadableUntil = clock() + RETRY_SECONDS
end

-- A step is due: works out the amount and adds it.
local function step(r, st, set, value, base)
    local top = KIT.readAttribute(set, r.top)           -- the maximum as it is now (the game's own limit)
    if top == nil then return unreadable(r, st, r.top) end
    note(r.readable, "yes")
    st.top = top
    local limit = floor(top * Cfg[r.upTo] / 100)
    if value >= limit then
        st.carry, st.phase, st.resting = 0, "full", true
        return
    end
    local system = ability()
    local why = down(system, r, value)
    if why then
        st.phase, st.why, st.resting = "down", why, true
        return
    end
    local amount = Cfg[r.flat] + top * Cfg[r.percent] / 100
    if r == MANA and Cfg.ManaByCircle then amount = amount * circleShare(set) end
    if Cfg[r.armed] ~= 100 and hasTag(system, TAG_ARMED) then amount = amount * Cfg[r.armed] / 100 end
    st.phase = "run"
    st.carry = st.carry + amount
    local points = floor(st.carry + 0.000001)
    if points < 1 then return end
    local target = min(value + points, limit)
    st.carry = st.carry - points
    local now, how = give(r, set, value, base, target)
    if now == nil then
        st.carry, st.failed = 0, st.failed + 1
        st.last = KIT.readAttribute(set, r.key)       -- the next look starts from what is really there
        L.once("write:" .. r.key, ("%s could not be written (%s); it stays as the game has it"):format(r.word, how))
        note(r.write, "failed", how)
        if st.failed >= TRIES then
            st.givenUp = true
            log(("%s regeneration is given up for this run: %d steps in a row could not be written"):format(r.word, st.failed))
        end
        return
    end
    st.failed, st.value, st.last = 0, now, now
    st.steps, st.added = st.steps + 1, st.added + (now - value)
    S.how = how
    note(r.write, how)
    if st.steps == 1 and DIAG then
        DIAG.event(("first %s step: %d -> %d of %d, by %s, found through the %s"):format(r.word, whole(value), whole(now), whole(top), how, tostring(st.via)))
    end
    if Cfg.LogSteps then
        log(("%s %+d -> %d of %d (%s)"):format(r.word, whole(now - value), whole(now), whole(top), how))
    end
    local started = st.resting
    st.resting = false
    if now >= limit then
        st.phase = "full"
        show(r, ("%s has regenerated (%d of %d)"):format(r.key, whole(now), whole(top)))
    elseif started then
        show(r, ("%s regenerates again"):format(r.key))
    end
    if r == MANA then clearBlock(system, value) end
end

-- One look at one resource; `seconds` is the time that counts since the last look.
local function look(r, st, set, via, seconds)
    local name = KIT.fullName(set)
    if name ~= st.setName then
        -- other attributes than at the last look: a new game, a loaded save, another map. Nothing is
        -- given until the usual wait is over (a save may still be filling the values in).
        forget(st)
        st.setName, st.via, st.phase = name, via, "wait"
        st.pause = max(Cfg[r.pause], Cfg.SettleSeconds)
        seconds = 0             -- the wait starts with this look
        note(r.foundBy, via)
        if Cfg.ShowMessage then KIT.prepareNotes() end      -- searches now, not in a fight
    end
    local value, base = KIT.readAttribute(set, r.key)
    if value == nil then return unreadable(r, st, r.key) end
    local last = st.last
    st.value, st.last = value, value
    if last ~= nil and last - value >= 0.5 then
        -- it went down: a spell, a hit. The wait starts again; a longer wait that still runs (the one after
        -- the hero was found) is not cut short by it.
        st.pause, st.waited, st.phase, st.resting = max(st.pause, Cfg[r.pause]), 0, "wait", true
        st.losses = st.losses + 1
    end
    -- a wait never runs longer than the settings allow now (it was made shorter while it ran)
    st.pause = min(st.pause, max(Cfg[r.pause], Cfg.SettleSeconds))
    if st.pause > 0 then
        st.pause = max(st.pause - seconds, 0)
        return
    end
    st.waited = st.waited + seconds
    local every = Cfg[r.seconds]
    if st.waited < every then return end
    st.waited = st.waited - every
    if st.waited >= every then st.waited = 0 end        -- the interval was made shorter meanwhile: no burst of steps
    step(r, st, set, value, base or value)
end

-- ---------------------------------------------------------------------------
-- The loop
-- ---------------------------------------------------------------------------
local function tick()
    if KIT.loading() then
        S.lookAt = nil
        return
    end
    if idle() then
        if S.awake then rest() end
        return
    end
    local now = clock()
    if now < S.nextLook then return end
    S.nextLook = now + Cfg.LookSeconds - 0.001
    S.awake = true
    S.halt = nil

    -- the hero's attributes (asked from the kit at every look: it checks that they are still his)
    local sets, vias, found = {}, {}, false
    for _, r in ipairs(BOTH) do
        local st = S[r.key]
        if active(r) and not st.givenUp and now >= st.unreadableUntil then
            sets[r.key], vias[r.key] = KIT.attributeSet(r.key)
        end
        if sets[r.key] then found = true
        elseif st.setName ~= nil then forget(st) end
    end
    if not found then
        S.lookAt = nil
        return
    end

    -- the time that counts since the last look
    if Cfg.StopWhenPaused and KIT.paused() then
        note("regen.engine_pause", "seen")
        S.lookAt, S.halt = nil, "the engine is paused"
        S.pausedLooks = S.pausedLooks + 1
        return
    end
    local seconds = 0
    if S.lookAt ~= nil then seconds = min(now - S.lookAt, 2 * Cfg.LookSeconds) end
    S.lookAt = now
    if Cfg.StopWhenClockStands and not S.clockOff then
        local game = KIT.gameSeconds()
        if game == nil then
            -- no clock to go by: time counts. After ten seconds without one it is not asked for again in this world.
            S.blindSince = S.blindSince or now
            if now - S.blindSince >= CLOCK_PATIENCE then
                S.clockOff = true
                note("regen.game_clock", "not readable")
            end
        else
            S.blindSince = nil
            note("regen.game_clock", "readable")
            if game == S.game then
                seconds = 0
                S.halt = "the game's clock stands still"
                S.stoodLooks = S.stoodLooks + 1
                note("regen.clock_stood", "seen")
            end
            S.game = game
        end
    end
    S.counted = S.counted + seconds

    for _, r in ipairs(BOTH) do
        if sets[r.key] then look(r, S[r.key], sets[r.key], vias[r.key], seconds) end
    end
end

Settings.onChange = function(_, changed, why)
    log(("settings changed (%s): %s"):format(why == "menu" and "in-game menu" or (why == "file" and "config.lua" or tostring(why)), summary()))
    if not Cfg.ShowMessage then
        KIT.hideToast(MANA.slot)
        KIT.hideToast(HEALTH.slot)
    end
    for _, key in ipairs(changed) do
        -- another way of writing, or a resource switched on again: what was given up is tried anew
        if key == "Method" then S.gameFails, S.direct = 0, false end
        for _, r in ipairs(BOTH) do
            if key == "Method" or key == r.on then S[r.key].failed, S[r.key].givenUp = 0, false end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Status (console command regen, the loader's reports). Built from what the
-- module holds; it does not call into the game.
-- ---------------------------------------------------------------------------
local function stateLine(r)
    local st = S[r.key]
    if not Cfg.Enabled or not Cfg[r.on] then return r.word .. ": switched off" end
    if not active(r) then return r.word .. ": nothing to regenerate (the amount is 0)" end
    if st.givenUp then return r.word .. ": given up for this run (the value could not be written)" end
    if st.value == nil then return r.word .. ": the hero's " .. r.word .. " has not been found yet (no game loaded?)" end
    local text = ("%s %d"):format(r.word, whole(st.value))
    if st.top ~= nil then text = text .. (" of %d"):format(whole(st.top)) end
    if st.pause > 0 then return text .. (": waiting %d s after a loss or a load"):format(whole(st.pause)) end
    if st.phase == "full" then return text .. ": at its limit" end
    if st.phase == "down" then return text .. ": the hero gets nothing now (" .. tostring(st.why) .. ")" end
    return text .. (": regenerating, next step in %s s"):format(num(max(Cfg[r.seconds] - st.waited, 0)))
end
local function statusLines()
    local lines = { ("v%s | %s"):format(VERSION, summary()) }
    if idle() then
        lines[#lines + 1] = "nothing to regenerate: the game is not looked at"
    else
        lines[#lines + 1] = stateLine(MANA)
        lines[#lines + 1] = stateLine(HEALTH)
        if S.halt then lines[#lines + 1] = "time is not counted at the moment: " .. S.halt end
    end
    local m, h = S.Mana, S.Health
    lines[#lines + 1] = ("restored: mana %+d in %d steps, health %+d in %d steps%s%s"):format(whole(m.added), m.steps, whole(h.added), h.steps,
        S.how and ("; written by " .. S.how) or "", S.cleared > 0 and ("; casting block taken off " .. S.cleared .. " time(s)") or "")
    lines[#lines + 1] = ("time counted: %d s; looks that counted nothing: %d in the engine's pause, %d with the game's clock standing still"):format(
        floor(S.counted), S.pausedLooks, S.stoodLooks)
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

-- ---------------------------------------------------------------------------
-- Registration (each exactly once)
-- ---------------------------------------------------------------------------
KIT.onWorldChange(function() rest() end)
for _, name in ipairs({ "regen", "g1r_regen" }) do
    if type(RegisterConsoleCommandHandler) == "function" then
        pcall(RegisterConsoleCommandHandler, name, console)
    end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; regeneration is disabled.")
    return
end
LoopInGameThreadWithDelay(250, function()
    local ok, err = pcall(tick)
    if not ok then L.once("tick:" .. tostring(err), "update error: " .. tostring(err)) end
end)

log(("v%s loaded: %s"):format(VERSION, summary()))

if DIAG then
    pcall(function()
        DIAG.status(statusLines)
        DIAG.dump(function()
            local out = {
                version = VERSION, enabled = Cfg.Enabled, method = Cfg.Method, written_by = S.how,
                direct_fallback = S.direct, game_way_failures = S.gameFails, tags_unusable = S.tagsOff,
                casting_block_cleared = S.cleared, looking = S.awake, show_message = Cfg.ShowMessage, log_steps = Cfg.LogSteps,
                seconds_counted = S.counted, looks_engine_paused = S.pausedLooks, looks_clock_stood = S.stoodLooks, not_counting = S.halt,
                stop_when_paused = Cfg.StopWhenPaused, stop_when_clock_stands = Cfg.StopWhenClockStands,
                settle_seconds = Cfg.SettleSeconds, look_seconds = Cfg.LookSeconds, clear_block = Cfg.ManaClearBlock,
                by_circle = Cfg.ManaByCircle,
                circle = { none = Cfg.ManaCircleNone, novice = Cfg.ManaCircleNovice, first = Cfg.ManaCircleFirst, step = Cfg.ManaCircleStep },
            }
            for _, r in ipairs(BOTH) do
                local st = S[r.key]
                out[r.word] = {
                    enabled = Cfg[r.on], percent = Cfg[r.percent], flat = Cfg[r.flat], seconds = Cfg[r.seconds], up_to = Cfg[r.upTo],
                    pause = Cfg[r.pause], armed_percent = Cfg[r.armed],
                    attributes = st.setName, found_through = st.via, value = st.value, maximum = st.top, phase = st.phase, why = st.why,
                    pause_left = st.pause, waited = st.waited, carry = st.carry, steps = st.steps, added = st.added, losses = st.losses,
                    failed_steps = st.failed, given_up = st.givenUp,
                }
            end
            return out
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "REGEN_TEST")) == "table" then
    local T = rawget(_G, "REGEN_TEST")
    T.state, T.console, T.status, T.tick, T.settings, T.num = S, console, statusLines, tick, Settings, num
end
