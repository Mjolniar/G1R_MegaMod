-- Scenarios for main.lua's own parts, run in both modes of harness.lua: the
-- settings file (load, reload, what the summary says), the progress file
-- (which copy is read, when it is written), the times the mod waits (start
-- delay, map load, the hero put into the world again, the profile id), the
-- switches, the console command, the status lines, and what happens when a
-- part of the mod cannot be loaded. Loaded by harness.lua with a table of what
-- it needs from there.
local X = ...
local H, E, check, ticks, lastLog, countLogs = X.H, X.E, X.check, X.ticks, X.lastLog, X.countLogs
local setConfig, PDS, Pawn, DIR, ENGINE = X.setConfig, X.PDS, X.Pawn, X.DIR, X.ENGINE
local FK = E.FK
local RESTART = "/Script/Engine.PlayerController:ClientRestart"
local MODE = ENGINE and "ENGINE" or "search"
local STATE = DIR .. "state/"

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function fileText(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end
local function writeText(path, text) local f = assert(io.open(path, "wb")); f:write(text); f:close() end
local function exists(path) local f = io.open(path, "rb"); if f then f:close() end; return f ~= nil end
-- a fresh small world and the mod loaded anew, with a recording stand-in for the megamod's handle
local function start(before)
  E.freshWorld()
  if before then before() end
  local F = FK.new()
  local T = E.loadMod(F)
  return T, F
end
-- updates until the session has started (true) or `max` updates have passed (false)
local function untilStarted(T, max)
  for _ = 1, max or 400 do
    ticks(1)
    if T.session().started then return true end
  end
  return false
end
-- updates until the world is ready for the mod (the session's `ready`)
local function untilReady(T, max)
  for _ = 1, max or 400 do
    ticks(1)
    if T.session().ready then return true end
  end
  return false
end
local function noErrors() return countLogs("update error") + countLogs("settings reload error") + countLogs("crime update error") end
local function lifeLine(T)
  for _, l in ipairs(T.status()) do if l:find("^this run: ") then return l end end
  return ""
end
-- the settings file with every part switched off that would change the progress by itself
local QUIET_PARTS = {
  { "Config.Creatures = {\n    Enabled = true,", "Config.Creatures = {\n    Enabled = false," },
  { "Config.Herbs = {\n    Enabled = true,", "Config.Herbs = {\n    Enabled = false," },
  { "Config.WorldItems = {\n    Enabled = true,", "Config.WorldItems = {\n    Enabled = false," },
  { "Config.Chests = {\n    Enabled = true,", "Config.Chests = {\n    Enabled = false," },
}
local function with(list, ...)
  local out = {}
  for _, s in ipairs(list) do out[#out + 1] = s end
  for _, s in ipairs({ ... }) do out[#out + 1] = s end
  return out
end

-- ================================================================ a fresh run: what the status says before anything happened
print("== main: a fresh run - counters and status lines\n")
do
  local T, F = start()
  local life = T.life()
  local line = lifeLine(T)                   -- (search: the status asks for the game clock, which is a search)
  local walks = (T.util.walks())
  check(life.sessions == 0 and life.possessions == 0 and life.pauses == 0 and life.held == 0 and life.resets == (ENGINE and 1 or 0),
    ("a fresh run has counted nothing (%d sessions, %d resets, %d, %d, %d held)"):format(life.sessions, life.resets, life.possessions, life.pauses, life.held))
  local want = ENGINE
    and ("this run: 0 sessions, 1 reset (map load 1); hero put into the world again 0 times (no reset), 0 pauses; %d searches among all objects"):format(walks)
    or ("this run: 0 sessions, 0 resets; hero put into the world again 0 times (no reset), 0 pauses; %d searches among all objects"):format(walks)
  check(line == want, "status, the run so far: '" .. line .. "'")
  local lines = T.status()
  check(lines[3] == "world items: pending, 0 spots (0 herbs, 0 other, 0 vanilla)", "status before the item pass: '" .. tostring(lines[3]) .. "'")
  check(lines[2]:find("populated points 0;", 1, true) ~= nil and lines[2]:find("queue 0;", 1, true) ~= nil, "status: no populated point known yet")
  check(T.state.dirty == false and T.statePath() == nil, "no progress file is chosen before a session starts")
  -- the console command before a session: nothing to write, no error
  local written = 0
  local write = T.util.writeFile
  T.util.writeFile = function(...) written = written + 1; return write(...) end
  local ok, handled = pcall(T.console, "repop save", nil, nil)
  check(ok and handled == true and written == 0, "console 'save' before a session: handled, nothing written (" .. tostring(handled) .. ")")
  T.util.writeFile = write
end

-- ================================================================ the times the mod waits
print("== main: start delay, map load, the hero put into the world again\n")
do
  local T, F = start()
  -- the crime switch is asked a second after the world is ready, the session starts StartDelaySeconds after it
  local crimeAt = nil
  local crimeTick = T.crime.tick
  T.crime.tick = function(realNow, ...) if not crimeAt then crimeAt = H.real end; return crimeTick(realNow, ...) end
  check(untilReady(T), "the world gets ready")
  local readyAt = T.session().readyAt
  check(readyAt == H.real, "the moment the world got ready is kept")
  check(untilStarted(T), "the session starts")
  check(H.real - readyAt == 8.0, ("the session starts 8 s after the world got ready (%.2f)"):format(H.real - readyAt))
  check(crimeAt ~= nil and crimeAt - readyAt == 1.0, ("the crime switch is looked at 1 s after the world got ready (%s)"):format(tostring(crimeAt and crimeAt - readyAt)))
  T.crime.tick = crimeTick
  check(T.life().sessions == 1 and lifeLine(T):find("this run: 1 session, ", 1, true) == 1, "one session counted: '" .. lifeLine(T) .. "'")
  check(noErrors() == 0, "no error up to here")

  -- the hero is put into the world again: nothing for 3 s, counted as held updates
  ticks(40)
  local held0 = T.life().held
  H.hooks[RESTART]()
  ticks(11)
  check(T.life().held == held0 + 11, ("for 3 s the updates are held (%d of 11)"):format(T.life().held - held0))
  ticks(1)
  check(T.life().held == held0 + 11, "and the update at exactly 3 s runs again")
  check(T.life().possessions == 1 and lifeLine(T):find("put into the world again 1 time (no reset)", 1, true) ~= nil, "counted once: '" .. lifeLine(T) .. "'")
  -- twice, a second apart: 3 s after the second
  ticks(20)
  held0 = T.life().held
  H.hooks[RESTART]()
  ticks(4)
  H.hooks[RESTART]()
  ticks(11)
  check(T.life().held == held0 + 15, ("put into the world twice, 1 s apart: held until 3 s after the second (%d of 15)"):format(T.life().held - held0))
  ticks(1)
  check(T.life().held == held0 + 15 and lifeLine(T):find("put into the world again 3 times (no reset)", 1, true) ~= nil, "then it runs again: '" .. lifeLine(T) .. "'")
  check(T.life().resets == (ENGINE and 1 or 0) and T.life().sessions == 1, "none of that ended the session")

  -- a map load: nothing for 3 s
  ticks(20)
  local t0 = H.real
  E.mapLoad()
  check(untilReady(T), "(after a map load the world gets ready again)")
  -- (search: the clock is searched for when the 3 s are over, the controller a second later - searches are a second apart)
  check(T.session().readyAt - t0 == (ENGINE and 3.0 or 4.0), ("after a map load nothing is touched for 3 s (ready after %.2f s)"):format(T.session().readyAt - t0))
  check(T.util.mayWalk(t0 + 2.99) == false, "and no search among all objects for 3 s")
  check(untilStarted(T) and T.life().sessions == 2, "(the next session starts)")
  check(lifeLine(T):find(ENGINE and "this run: 2 sessions, 2 resets (map load 2);" or "this run: 2 sessions, 1 reset (map load 1);", 1, true) == 1,
    "status: '" .. lifeLine(T) .. "'")

  -- the game clock goes back: by 5 s it is the same world, by more it is another save
  ticks(8)
  local resets = T.life().resets
  H.game = H.game - 5
  ticks(1)
  check(T.life().resets == resets, "the clock goes back by 5 s: no new session")
  H.game = H.game - 5.25
  ticks(1)
  check(T.life().resets == resets + 1 and (lastLog("session reset") or ""):find("(the game clock went back: 5 s)", 1, true) ~= nil,
    "the clock goes back by more than 5 s: the session ends (" .. tostring(lastLog("session reset")) .. ")")
  check(T.session().ready == false, "the update that ends the session does nothing more: the world is looked at again at the next one")
  check(lifeLine(T):find(ENGINE and "3 resets (map load 2, the game clock went back 1);" or "2 resets (map load 1, the game clock went back 1);", 1, true) ~= nil,
    "status names both reasons: '" .. lifeLine(T) .. "'")
  check(noErrors() == 0, "no error in all of that")
end

-- the settings: start delay and settle time
do
  local T = start(function()
    setConfig({ { "Config.StartDelaySeconds = 8", "Config.StartDelaySeconds = 2\nConfig.SettleSeconds = 30.5" } })
  end)
  check(untilReady(T) and true, "(ready)")
  local readyAt = T.session().readyAt
  check(untilStarted(T) and H.real - readyAt == 2.0, ("StartDelaySeconds = 2: the session starts 2 s after the world got ready (%.2f)"):format(H.real - readyAt))
  ticks(20)
  local held0 = T.life().held
  H.hooks[RESTART]()
  ticks(125)
  check(T.life().held == held0 + 119, ("SettleSeconds = 30.5: 30 s at most (%d updates held, 119 expected)"):format(T.life().held - held0))
end
do
  local T = start(function() setConfig({ { "Config.StartDelaySeconds = 8", "Config.SettleSeconds = 0" } }) end)
  check(untilReady(T) and true, "(ready)")
  local readyAt = T.session().readyAt
  check(untilStarted(T) and H.real - readyAt == 8.0, ("no StartDelaySeconds in the file: 8 s (%.2f)"):format(H.real - readyAt))
  local held0 = T.life().held
  H.hooks[RESTART]()
  ticks(4)
  check(T.life().held == held0, "SettleSeconds = 0: nothing is held")
end
do
  -- no start delay: the update that finds the world ready only says so, the next one starts the session
  local T = start(function() setConfig({ { "Config.StartDelaySeconds = 8", "Config.StartDelaySeconds = 0" } }) end)
  check(untilReady(T) and T.session().started == false, "StartDelaySeconds = 0: the update that finds the world ready does nothing more")
  local readyAt = T.session().readyAt
  check(untilStarted(T) and noErrors() == 0, "StartDelaySeconds = 0: the session starts at a later update")
  if ENGINE then
    check(H.real - readyAt == 0.25, ("ENGINE: StartDelaySeconds = 0: at the next update (%.2f s)"):format(H.real - readyAt))
  end
end

-- ENGINE: the two map load hooks apart, and only the first one
if ENGINE then
  local T = start()
  check(untilStarted(T), "(session)")
  ticks(8)
  local t0 = H.real
  H.pre(E.engineParam)                       -- (only the first hook fires)
  check(untilReady(T) and T.session().readyAt - t0 == 3.0, ("ENGINE: only the first map load hook fires - 3 s all the same (%.2f)"):format((T.session().readyAt or 0) - t0))
  check(untilStarted(T), "(session)")
  ticks(8)
  t0 = H.real
  H.pre(E.engineParam)
  ticks(8)                                   -- (the load takes 2 s)
  check(T.session().ready == false, "ENGINE: nothing while the map loads")
  H.post(E.engineParam)
  check(T.util.mayWalk(t0 + 2 + 2.99) == false and T.util.mayWalk(t0 + 2 + 3.0) == true, "ENGINE: no search among all objects until 3 s after the second hook")
  check(untilReady(T) and T.session().readyAt - t0 == 5.0, ("ENGINE: the second hook 2 s after the first - 3 s from the second (%.2f)"):format((T.session().readyAt or 0) - t0))
  -- pauses
  check(untilStarted(T), "(session)")
  ticks(8)
  local held0 = T.life().held
  H.paused = true
  ticks(8)
  check(T.life().pauses == 1 and T.life().held == held0 and lifeLine(T):find(", 1 pause;", 1, true) ~= nil, "ENGINE: a pause is counted once: '" .. lifeLine(T) .. "'")
  H.paused = nil
  ticks(1)                                   -- (the update that sees the game running again)
  ticks(3)
  check(T.life().held == held0 + 3, ("ENGINE: when the game runs again the mod waits a second (%d of 3 updates held)"):format(T.life().held - held0))
  ticks(1)
  check(T.life().held == held0 + 3, "ENGINE: and then goes on")
  H.paused = true; ticks(2); H.paused = nil; ticks(8)
  check(T.life().pauses == 2 and lifeLine(T):find(", 2 pauses;", 1, true) ~= nil, "ENGINE: the second pause: '" .. lifeLine(T) .. "'")
  check(noErrors() == 0, "ENGINE: no error in all of that")
end

-- ENGINE: the engine hands out another player controller - the update that notices it ends the session, nothing more
if ENGINE then
  local T = start()
  check(untilStarted(T), "(session)")
  ticks(8)
  local resets, work = T.life().resets, 0
  local creatureTick = T.creatures.tick
  T.creatures.tick = function(...) work = work + 1; return creatureTick(...) end
  local other = X.obj("GothicPlayerControllerBaseBP_C /Game/Maps/MainMap.PC_9")
  other.K2_GetPawn = function() return Pawn end
  H.controllerNow = other
  local seen = false
  for _ = 1, 20 do
    work = 0
    ticks(1)
    if T.life().resets > resets then seen = true; break end
  end
  check(seen and (lastLog("session reset") or ""):find("(another player controller)", 1, true) ~= nil,
    "ENGINE: another player controller ends the session: " .. tostring(lastLog("session reset")))
  check(seen and T.session().ready == false and work == 0,
    ("ENGINE: and that update does nothing more (ready: %s, %d creature updates)"):format(tostring(T.session().ready), work))
  check(untilStarted(T) and noErrors() == 0, "ENGINE: the next session starts with it")
  T.creatures.tick = creatureTick
  H.controllerNow = nil
end


-- ================================================================ the profile id
print("== main: the profile id - waited for at a start, looked at while playing\n")
do
  -- not readable: asked every 5 s for 20 s, then the default progress file
  local T = start(function() PDS.m_CurrentProfileId = nil end)
  local asks = 0
  local subsystem = T.util.subsystem
  T.util.subsystem = function(kind, path)
    if path == "/Script/G1R.PersistentDataSubsystem" then asks = asks + 1 end
    return subsystem(kind, path)
  end
  check(untilReady(T) and true, "(ready)")
  local readyAt = T.session().readyAt
  check(untilStarted(T) and H.real - readyAt == 28.0, ("no profile id readable: the session starts 8 + 20 s after the world got ready (%.2f)"):format(H.real - readyAt))
  check(asks == 5, ("the id was asked for every 5 s: 5 times (%d)"):format(asks))
  check((lastLog("session started") or ""):find("state profile_default (not written): 0 populated", 1, true) ~= nil
    and countLogs("no progress file is read or written until it can be") == 1, "it starts without a progress file and says so")
  T.state.seen.WP_SOMEWHERE, T.state.dirty = true, true
  T.save(true)
  local none = io.open(STATE .. "profile_default.lua", "r")
  check(none == nil and T.statePath() == nil, "whose progress it is cannot be told: nothing is written (no profile_default.lua)")
  if none then none:close() end
  if ENGINE then
    check((H.finds.PersistentDataSubsystem or 0) == 0, "ENGINE: the engine was asked - the profile is not searched for among all objects")
  else
    check((H.finds.PersistentDataSubsystem or 0) == 5, ("search: one search among all objects per question (%d)"):format(H.finds.PersistentDataSubsystem or 0))
  end
  T.util.subsystem = subsystem
  PDS.m_CurrentProfileId = 2
  os.remove(STATE .. "profile_default.lua")
end
do
  -- a progress file is taken record by record: the ones of a shape this version does not write are left out
  local T = start(function()
  local f = io.open(STATE .. "profile_2.lua", "w")
  f:write([[return { version = 1, seen = { WP_A = true, WP_B = "yes", [5] = true },
  chests = { K1 = { d = 10, n = 20 }, K2 = { d = "x" }, K3 = { f = 5, z = 1 }, K4 = 7, K5 = { f = 3, p = true, r = false } },
  recent = { WP_C = { Wolf = { n = 1, t = 100 } }, WP_D = { Wolf = { n = "1", t = 100 } }, WP_E = 3, WP_F = { [7] = { n = 1, t = 2 } },
    WP_G = { Wolf = 5 } } }
]])
  f:close()
  end)
  check(untilStarted(T), "(session)")
  local st = T.state
  check(st.seen.WP_A == true and st.seen.WP_B == nil and st.chests.K1 ~= nil and st.chests.K5 ~= nil and st.chests.K2 == nil and st.chests.K3 == nil
    and st.chests.K4 == nil and st.recent.WP_C ~= nil and st.recent.WP_D == nil and st.recent.WP_E == nil and st.recent.WP_F == nil and st.recent.WP_G == nil,
    "records of a wrong shape are left out, the others are used")
  check(countLogs("held 9 record") == 1, "that is said once, with the count")
  os.remove(STATE .. "profile_2.lua")
  -- one wrong record among right ones, in each part: said each time; a right file: nothing said
  for _, case in ipairs({ { "chests", "chests = { K1 = { d = 1 }, K2 = { d = true } }, recent = {}" },
                          { "recent", "chests = {}, recent = { WP_C = { Wolf = { n = 1, t = 2 } }, WP_D = { Wolf = { n = 1 } } }" },
                          { "right", "chests = { K1 = { d = 1 } }, recent = { WP_C = { Wolf = { n = 1, t = 2 } } }" },
                          { "right, without recent", "chests = { K1 = { d = 1 } }" } }) do
    local T2 = start(function()
      local f = io.open(STATE .. "profile_2.lua", "w")
      f:write("return { version = 1, seen = { WP_A = true }, " .. case[2] .. " }")
      f:close()
    end)
    check(untilStarted(T2), "(session)")
    if case[1]:sub(1, 5) == "right" then
      check(countLogs("of a shape this version does not write") == 0, "a progress file of the right shape (" .. case[1] .. "): nothing is said")
    else
      check(countLogs("held 1 record") == 1, "one wrong record in " .. case[1] .. ": left out and said")
    end
    os.remove(STATE .. "profile_2.lua")
  end
end
do
  -- a progress file of a newer version of the mod: not read, and not written over
  local newer = "return { version = 2, seen = { WP_A = true }, chests = {}, recent = {} }"
  local T = start(function() local f = io.open(STATE .. "profile_2.lua", "w"); f:write(newer); f:close() end)
  local f
  check(untilStarted(T), "(session)")
  check(T.statePath() == nil and T.state.seen.WP_A == nil and countLogs("was written by a newer version of the mod") == 1,
    "a progress file of a newer version: not read, and said so")
  T.state.seen.WP_B, T.state.dirty = true, true
  T.save(true)
  f = io.open(STATE .. "profile_2.lua", "r"); local after = f:read("a"); f:close()
  check(after == newer, "and not written over")
  os.remove(STATE .. "profile_2.lua")
end
do
  -- the profile changes while playing
  local T = start()
  check(untilStarted(T), "(session)")
  local at = T.session().profileAt
  check(at == H.real, "the moment the profile was looked at is kept")
  ticks(20)
  PDS.m_CurrentProfileId = 3
  local resets = T.life().resets
  local seenAt = nil
  -- (what the parts do in the update that notices it)
  local work = 0
  local creatureTick, itemTick, chestTick = T.creatures.tick, T.items.tick, T.chests.tick
  T.creatures.tick = function(...) work = work + 1; return creatureTick(...) end
  T.items.tick = function(...) work = work + 1; return itemTick(...) end
  T.chests.tick = function(...) work = work + 1; return chestTick(...) end
  for _ = 1, 140 do
    work = 0
    ticks(1)
    if T.life().resets > resets then seenAt = H.real; break end
  end
  T.creatures.tick, T.items.tick, T.chests.tick = creatureTick, itemTick, chestTick
  if ENGINE then
    check(seenAt ~= nil and seenAt - at == 30.0, ("ENGINE: another profile is noticed at the next look, 30 s after the last (%s)"):format(tostring(seenAt and seenAt - at)))
    check(work == 0 and T.session().ready == false,
      ("ENGINE: the update that notices it ends the session and does nothing more (%d updates of the parts)"):format(work))
    check((lastLog("session reset") or ""):find("(the profile changed: profile_2 -> profile_3)", 1, true) ~= nil, "ENGINE: the session ends: " .. tostring(lastLog("session reset")))
    check(untilStarted(T) and (lastLog("session started") or ""):find("state profile_3.lua", 1, true) ~= nil, "ENGINE: and the next one runs on the other progress file")
    check((H.finds.PersistentDataSubsystem or 0) == 0, "ENGINE: none of that searched among all objects")
  else
    check(seenAt == nil and (H.finds.PersistentDataSubsystem or 0) == 1, "search: the profile is only looked at when a session starts (not searched for while playing)")
  end
  PDS.m_CurrentProfileId = 2
  for _, name in ipairs({ "profile_3.lua", "profile_3.lua.bak" }) do os.remove(STATE .. name) end
end

-- ================================================================ the switches
print("== main: the mod's switch and the switches of its parts\n")
do
  local function counted(T)
    local n = { creatures = 0, items = 0, chests = 0, crime = 0, crimeOn = nil }
    local c, i, k, cr = T.creatures.tick, T.items.tick, T.chests.tick, T.crime.tick
    T.creatures.tick = function(...) n.creatures = n.creatures + 1; return c(...) end
    T.items.tick = function(...) n.items = n.items + 1; return i(...) end
    T.chests.tick = function(...) n.chests = n.chests + 1; return k(...) end
    T.crime.tick = function(realNow, on) n.crime = n.crime + 1; n.crimeOn = on; return cr(realNow, on) end
    return n
  end
  local function run(subs)
    local T = start(function() setConfig(subs) end)
    local n = counted(T)
    check(untilStarted(T), "(session)")
    ticks(40)
    return n, T
  end
  local n = run({})
  check(n.creatures > 30 and n.items > 30 and n.chests > 30 and n.crime > 30 and n.crimeOn == true, "everything on: creatures, items, containers and the crime switch are run at every update")
  n = run({ { "Config.Enabled = true", "Config.Enabled = false" } })
  check(n.creatures == 0 and n.items == 0 and n.chests == 0, ("Enabled = false: creatures, items and containers are not run (%d / %d / %d)"):format(n.creatures, n.items, n.chests))
  check(n.crime > 30 and n.crimeOn == false, "Enabled = false: the crime switch is still looked after, and told that the mod is off")
  n = run({ QUIET_PARTS[1] })
  check(n.creatures == 0 and n.items > 30 and n.chests > 30, "creatures off: only they are not run")
  n = run({ QUIET_PARTS[4] })
  check(n.chests == 0 and n.items > 30 and n.creatures > 30, "containers off: only they are not run")
  n = run({ QUIET_PARTS[3] })
  check(n.items > 30, "other items off, herbs on: the item part is run")
  n = run({ QUIET_PARTS[2] })
  check(n.items > 30, "herbs off, other items on: the item part is run")
  local T
  n, T = run({ QUIET_PARTS[2], QUIET_PARTS[3] })
  check(n.items == 0 and n.creatures > 30 and n.chests > 30, "herbs and other items off: the item part is not run")
  check(T.status()[3] == "world items: pending, 0 spots (0 herbs, 0 other, 0 vanilla)", "and the status says so: " .. tostring(T.status()[3]))
  -- every species taken out: there is no roll to wait for
  local names, seen = {}, {}
  for _, p in pairs(X.CDB) do
    for _, sp in ipairs(p.s) do
      if not seen[sp.u] then seen[sp.u] = true; names[#names + 1] = ("%q"):format(sp.u) end
    end
  end
  table.sort(names)
  n, T = run({ { "ExcludeSpecies = {},", "ExcludeSpecies = { " .. table.concat(names, ", ") .. " }," } })
  check((T.status()[2] or ""):find("; rolls none$") ~= nil, "every species excluded: the status names no roll: " .. tostring(T.status()[2]))
  check((lastLog("loaded:") or ""):find("401 creature spawn points (0 creatures)", 1, true) ~= nil, "(and the load line counts no creature)")
end

-- ================================================================ the progress file: which copy is read
print("== main: the progress file - what a session start reads\n")
do
  local A, B, C = X.P_EMPTY, X.P_ELITE, X.P_HALF
  local GOOD = ('return {\n  ["version"] = 1,\n  ["seen"] = {\n    [%q] = true,\n    [%q] = true,\n    [%q] = true,\n  },\n  ["chests"] = {\n'
    .. '    ["IO_ZZ_NOWHERE_01@1,1"] = {\n      ["d"] = 1000.500,\n      ["n"] = 87400.500,\n      ["p"] = true,\n    },\n'
    .. '    ["IO_ZZ_NOWHERE_02@2,2"] = {\n      ["d"] = 2000.250,\n      ["n"] = 88400.250,\n    },\n'
    .. '    ["IO_ZZ_NOWHERE_03@3,3"] = {\n      ["f"] = 3000.125,\n    },\n  },\n  ["recent"] = {\n  },\n}\n'):format(A, B, C)
  local OLDER = ('return {\n  ["version"] = 1,\n  ["seen"] = {\n    [%q] = true,\n  },\n  ["chests"] = {\n  },\n  ["recent"] = {\n  },\n}\n'):format(A)
  local BROKEN = 'return {\n  ["version"] = 1,\n  ["seen"] = {\n    ["Cut_Off_He'
  local CUT = "the last write of the progress file profile_2.lua had been cut off"
  local BAK = "could not be read; it is kept as profile_2.lua.bad and the copy of the write before it %(profile_2.lua.bak%) is used"
  local ANEW = "could not be read and there is no earlier copy; it is kept as profile_2.lua.bad and progress starts anew"
  -- every part off, so that the session itself changes nothing of the progress
  local function begin(files)
    local T, F = start(function()
      setConfig(QUIET_PARTS)
      for name, text in pairs(files) do writeText(STATE .. name, text) end
    end)
    check(untilStarted(T), "(session)")
    return T, F, lastLog("session started") or ""
  end
  local function clean() os.execute("rm -f " .. STATE .. "profile_2.lua*") end

  -- the file as it should be
  local T, F, line = begin({ ["profile_2.lua"] = GOOD })
  check(line:find("state profile_2.lua: 3 populated spawn points known, 2 containers waiting, 1 restocked and not opened yet", 1, true) ~= nil, "a progress file is read: " .. line)
  local rec = T.state.chests["IO_ZZ_NOWHERE_01@1,1"]
  check(count(T.state.seen) == 3 and T.state.seen[A] == true and T.state.seen[C] == true and count(T.state.chests) == 3
    and type(rec) == "table" and rec.d == 1000.5 and rec.n == 87400.5 and rec.p == true and T.state.chests["IO_ZZ_NOWHERE_03@3,3"].f == 3000.125,
    "what it holds is what the mod knows now")
  check(countLogs(CUT) + countLogs(BAK) + countLogs(ANEW) == 0 and F.value("core.state_file") == nil and not exists(STATE .. "profile_2.lua.bad"),
    "nothing is said about the file, and no copy is set aside")
  check((T.status()[2] or ""):find("populated points 3;", 1, true) ~= nil, "status: 3 populated points: " .. tostring(T.status()[2]))
  check(T.state.dirty == false, "reading it does not count as a change")
  clean()

  -- no file
  T, F, line = begin({})
  check(line:find("state profile_2.lua: 0 populated spawn points known, 0 containers waiting, 0 restocked and not opened yet", 1, true) ~= nil, "no progress file: starts empty: " .. line)
  check(countLogs(CUT) + countLogs(BAK) + countLogs(ANEW) == 0 and F.value("core.state_file") == nil and not exists(STATE .. "profile_2.lua.bad"),
    "no progress file: nothing is said, nothing is set aside")
  clean()

  -- a write that was cut off between its two renames: the complete new copy lies next to where the file should be
  T, F, line = begin({ ["profile_2.lua.tmp"] = GOOD })
  check(line:find("3 populated spawn points known, 2 containers waiting, 1 restocked", 1, true) ~= nil and countLogs(CUT) == 1 and countLogs(BAK) + countLogs(ANEW) == 0,
    "the file is missing and a complete new copy is there: it is used, and that is said once: " .. line)
  check(fileText(STATE .. "profile_2.lua") == GOOD and not exists(STATE .. "profile_2.lua.tmp") and F.value("core.state_file") == "finished"
    and F.detail("core.state_file") == "profile_2.lua", "the copy is put in place (note core.state_file = finished)")
  clean()

  -- the file is damaged, the copy of the write before it is there
  T, F, line = begin({ ["profile_2.lua"] = BROKEN, ["profile_2.lua.bak"] = OLDER })
  check(line:find("1 populated spawn points known, 0 containers waiting, 0 restocked", 1, true) ~= nil and countLogs(BAK) == 1 and countLogs(CUT) + countLogs(ANEW) == 0,
    "a damaged file: the copy of the write before it is used, and that is said once: " .. line)
  check(fileText(STATE .. "profile_2.lua.bad") == BROKEN and T.state.seen[A] == true and F.value("core.state_file") == "backup", "the damaged file is kept as .bad (note: backup)")
  clean()

  -- the file is damaged and there is no earlier copy
  T, F, line = begin({ ["profile_2.lua"] = BROKEN })
  check(line:find("0 populated spawn points known, 0 containers waiting, 0 restocked", 1, true) ~= nil and countLogs(ANEW) == 1 and countLogs(CUT) + countLogs(BAK) == 0,
    "a damaged file without an earlier copy: progress starts anew, and that is said once: " .. line)
  check(fileText(STATE .. "profile_2.lua.bad") == BROKEN and count(T.state.seen) == 0 and F.value("core.state_file") == "unreadable", "the damaged file is kept as .bad (note: unreadable)")
  clean()

  -- a file of another shape: what is not a table is not taken over
  T, F, line = begin({ ["profile_2.lua"] = 'return { ["version"] = 1, ["seen"] = 5, ["chests"] = "none", ["recent"] = true }\n' })
  check(line:find("0 populated spawn points known, 0 containers waiting", 1, true) ~= nil and type(T.state.seen) == "table" and type(T.state.chests) == "table"
    and type(T.state.recent) == "table" and noErrors() == 0, "a file with other things in the places of the lists: empty lists, no error")
  clean()
end

-- ================================================================ the progress file: when it is written
print("== main: the progress file - when it is written\n")
do
  local T = start(function() setConfig(QUIET_PARTS) end)
  local writes, fail = {}, nil
  local write = T.util.writeFile
  T.util.writeFile = function(path, text)
    writes[#writes + 1] = H.real
    if fail then return false, fail end
    return write(path, text)
  end
  check(untilStarted(T), "(session)")
  local t0 = H.real                           -- (the update that starts the session is also the first look at whether to write)
  ticks(300)
  check(#writes == 0 and not exists(STATE .. "profile_2.lua"), ("nothing changed: nothing is written in 75 s (%d writes)"):format(#writes))
  -- a change: written at the next look, a minute after the last
  local last = t0 + 60.25
  while last + 60.25 <= H.real do last = last + 60.25 end
  T.state.seen.A_Point = true
  T.state.dirty = true
  local wrote = nil
  for _ = 1, 260 do
    ticks(1)
    if #writes > 0 then wrote = H.real; break end
  end
  check(wrote ~= nil and wrote == last + 60.25, ("a change is written at the next look, which comes every 60.25 s (%s after the one before)"):format(tostring(wrote and wrote - last)))
  local file = dofile(STATE .. "profile_2.lua")
  check(type(file) == "table" and file.version == 1 and file.seen.A_Point == true and type(file.chests) == "table" and type(file.recent) == "table",
    "the file: version 1, the three lists")
  check(T.state.dirty == false, "written: nothing is waiting any more")
  ticks(600)
  check(#writes == 1, ("and it is not written again while nothing changes (%d writes in the next 150 s)"):format(#writes - 1))
  -- a restock is written at once
  T.state.seen.B_Point = true
  T.state.dirty, T.state.urgent = true, true
  ticks(1)
  check(#writes == 2 and T.state.urgent == nil and dofile(STATE .. "profile_2.lua").seen.B_Point == true, "what is marked urgent (a restock) is written at the next update")
  -- the console command writes whether something changed or not
  T.console("repop save", nil, nil)
  check(#writes == 3 and (lastLog("state written to") or ""):find("state/profile_2.lua", 1, true) ~= nil, "console 'save': written at once: " .. tostring(lastLog("state written to")))
  -- a map load ends the session: written, changed or not
  E.mapLoad()
  check(#writes == 4, "a session that ends is written")
  check(untilStarted(T), "(next session)")
  -- a write that fails: said once, counted, tried again at the next look
  local n0 = #writes
  fail = "disk full"
  T.state.seen.C_Point = true
  T.state.dirty = true
  ticks(250)
  check(#writes == n0 + 1 and T.state.dirty == true and countLogs("could not write the progress file: disk full") == 1,
    ("a write that fails is said, and the change stays waiting (%d tries)"):format(#writes - n0))
  check(lifeLine(T):find("; 1 writes of the progress file failed", 1, true) ~= nil, "status: '" .. lifeLine(T) .. "'")
  ticks(245)
  check(#writes == n0 + 2 and countLogs("could not write the progress file: disk full") == 1 and lifeLine(T):find("; 2 writes of the progress file failed", 1, true) ~= nil,
    ("it is tried again a minute later, and not said again (%d tries): '%s'"):format(#writes - n0, lifeLine(T)))
  fail = nil
  ticks(245)
  check(#writes == n0 + 3 and T.state.dirty == false and dofile(STATE .. "profile_2.lua").seen.C_Point == true, "when writing works again the change is written")
  T.util.writeFile = write
  check(noErrors() == 0, "no error in all of that")
end

-- ================================================================ the settings file
print("== main: the settings file - what the summary says, a file that cannot be used, reloading\n")
do
  local DEFAULT = "creatures on 35%/24h (elite 15%/24h, 0 species with own settings, corpses removed) | herbs on 24h | items on 15%/day | containers on 30%/10% per day | crime on"
  local CUSTOM = {
    { "NormalChance = 0.35,", "NormalChance = 0.50," }, { "NormalEveryHours = 24,", "NormalEveryHours = 12," },
    { "EliteChance = 0.15,", "EliteChance = 0.25," }, { "EliteEveryHours = 24,", "EliteEveryHours = 48," },
    { "    Species = {\n    },", "    Species = {\n        [\"Wolf\"] = { Chance = 0.5 },\n        [\"Meatbug\"] = { Enabled = false },\n    }," },
    { "RemoveCorpsesOnRespawn = true,", "RemoveCorpsesOnRespawn = false," },
    { "RegrowHours = 24,", "RegrowHours = 36," }, { "DailyChance = 0.15,", "DailyChance = 0.20," },
    { "SettlementDailyChance = 0.30,", "SettlementDailyChance = 0.45," }, { "WildDailyChance = 0.10,", "WildDailyChance = 0.05," },
  }
  local CUSTOM_ON = "creatures on 50%/12h (elite 25%/48h, 2 species with own settings, corpses kept) | herbs on 36h | items on 20%/day | containers on 45%/5% per day | crime on"
  local CUSTOM_OFF = "creatures OFF 50%/12h (elite 25%/48h, 2 species with own settings, corpses kept) | herbs OFF 36h | items OFF 20%/day | containers OFF 45%/5% per day | crime on"
  local function summaryOf(line) return line and (line:match("| (creatures .*)\n$") or line:match("settings reloaded: (.*)\n$")) end

  -- the file as it ships
  local T = start()
  check(summaryOf(lastLog("loaded:")) == DEFAULT, "the load line sums up the settings: " .. tostring(summaryOf(lastLog("loaded:"))))
  check((T.status()[1] or ""):find("^v1%.5%.0 | day %d+ %d%d:%d%d | creatures on 35%%/24h ") ~= nil and (T.status()[1] or ""):sub(-#DEFAULT) == DEFAULT,
    "and so does the first status line: " .. tostring(T.status()[1]))
  -- other numbers, everything on / everything off
  setConfig(CUSTOM)
  local ok, why = T.reload(false)
  check(ok == true and why == nil and summaryOf(lastLog("settings reloaded:")) == CUSTOM_ON, "other numbers: " .. tostring(summaryOf(lastLog("settings reloaded:"))))
  setConfig(with(CUSTOM, table.unpack(QUIET_PARTS)))
  ok = T.reload(false)
  check(ok == true and summaryOf(lastLog("settings reloaded:")) == CUSTOM_OFF, "the parts switched off: " .. tostring(summaryOf(lastLog("settings reloaded:"))))
  -- a file that names nothing: the mod's own numbers
  writeText(DIR .. "config.lua", "return {}\n")
  ok = T.reload(false)
  check(ok == true and summaryOf(lastLog("settings reloaded:")) == DEFAULT, "a file that names no setting: the mod's own numbers: " .. tostring(summaryOf(lastLog("settings reloaded:"))))
  -- the same text again is not read as a change
  local n = countLogs("settings reloaded:")
  ok, why = T.reload(false)
  check(ok == false and why == "unchanged" and countLogs("settings reloaded:") == n, "an unchanged file is not loaded again")
  -- a file with an error: said once, the settings stay
  writeText(DIR .. "config.lua", "return { Enabled = \n")
  ok, why = T.reload(false)
  check(ok == false and tostring(why):find("config.lua:", 1, true) ~= nil and countLogs("config.lua has an error, keeping the previous settings: config.lua:") == 1,
    "a file with an error: not taken, and that is said: " .. tostring(why))
  ok, why = T.reload(false)
  check(ok == false and why == "still invalid" and countLogs("config.lua has an error, keeping the previous settings") == 1, "the same broken file is not looked at twice")
  local lines = {}
  local ar = { Log = function(self, text) lines[#lines + 1] = text end }
  local handled = T.console("repop reload", nil, ar)
  check(handled == true and #lines == 1 and lines[1]:find("^%[G1R_Repopulate%] settings not reloaded: config%.lua:") ~= nil,
    "console 'reload' with the broken file: " .. tostring(lines[1]))
  -- the file is gone
  os.remove(DIR .. "config.lua")
  n = countLogs("config.lua has an error")
  ok, why = T.reload(false)
  check(ok == false and why == "config.lua not found", "no file: " .. tostring(why))
  lines = {}
  T.console("repop reload", nil, ar)
  check(lines[1] == "[G1R_Repopulate] settings not reloaded: config.lua not found" and countLogs("config.lua has an error") == n,
    "console 'reload' without a file: " .. tostring(lines[1]))
  -- the console command reloads a file that has not changed
  setConfig({})
  T.reload(false)
  n = countLogs("settings reloaded:")
  lines = {}
  T.console("repop reload", nil, ar)
  check(lines[1] == "[G1R_Repopulate] settings reloaded" and countLogs("settings reloaded:") == n + 1, "console 'reload' loads the file again even when it has not changed")
  check(noErrors() == 0, "no error in all of that")
end

-- a settings file that cannot be used when the mod is loaded
do
  local function loadWith(text)
    E.freshWorld()
    if text then writeText(DIR .. "config.lua", text) else os.remove(DIR .. "config.lua") end
    local ok, T = pcall(E.loadMod, FK.new())
    return ok, T, lastLog("config.lua missing or invalid") or ""
  end
  local DEFAULT = "| creatures on 35%/24h (elite 15%/24h, 0 species with own settings, corpses removed) | herbs on 24h | items on 15%/day | containers on 30%/10% per day | crime on"
  for _, case in ipairs({
    { nil, "(config.lua not found); using defaults", "no settings file" },
    { "return { Enabled = \n", "(config.lua:2: ", "a settings file with a mistake in it" },
    { "local none = nil\nreturn none.Enabled\n", "(config.lua:2: attempt to index a nil value", "a settings file that fails when run" },
    { "return 5\n", "(config.lua did not return a table); using defaults", "a settings file that does not hold settings" },
  }) do
    local ok, T, line = loadWith(case[1])
    check(ok and line:find(case[2], 1, true) ~= nil and (lastLog("loaded:") or ""):find(DEFAULT, 1, true) ~= nil,
      ("%s: the mod loads with its own numbers and says why (%s)"):format(case[3], line:gsub("\n", "")))
    check(ok and untilStarted(T) and noErrors() == 0, ("%s: and a session starts"):format(case[3]))
  end
  setConfig({})
end

-- how often the file is looked at
do
  local function changed(n) return { { "Config.Verbose = false", "Config.Verbose = false\n-- change " .. n } } end
  local T = start()
  check(untilStarted(T), "(session)")
  -- find the moment of a look: the first change is picked up at one
  setConfig(changed(1))
  local n0 = countLogs("settings reloaded:")
  local look = nil
  for _ = 1, 70 do
    ticks(1)
    if countLogs("settings reloaded:") > n0 then look = H.real; break end
  end
  check(look ~= nil, "a changed settings file is picked up while the game runs")
  local function nextReload(max)
    local n = countLogs("settings reloaded:")
    for _ = 1, max do
      ticks(1)
      if countLogs("settings reloaded:") > n then return H.real end
    end
  end
  setConfig(changed(2))
  local at = nextReload(80)
  check(at ~= nil and at - look == 15.0, ("the file is looked at every 15 s (%s after the look before)"):format(tostring(at and at - look)))
  -- ReloadCheckSeconds = 5, then 1
  setConfig(with(changed(3), { "Config.ReloadCheckSeconds = 15", "Config.ReloadCheckSeconds = 5" }))
  look = nextReload(80)
  setConfig(with(changed(4), { "Config.ReloadCheckSeconds = 15", "Config.ReloadCheckSeconds = 1" }))
  at = nextReload(80)
  check(look ~= nil and at ~= nil and at - look == 5.0, ("ReloadCheckSeconds = 5: looked at 5 s later (%s)"):format(tostring(at and look and at - look)))
  look = at
  setConfig(with(changed(5), { "Config.ReloadCheckSeconds = 15", "Config.ReloadCheckSeconds = 0" }))
  at = nextReload(80)
  check(at ~= nil and at - look == 1.0, ("ReloadCheckSeconds = 1: looked at 1 s later (%s)"):format(tostring(at and at - look)))
  -- 0: never again
  setConfig(changed(6))
  check(nextReload(400) == nil, "ReloadCheckSeconds = 0: the file is not looked at any more")
  check(T.reload(false) == true, "(until it is asked for)")
  check(noErrors() == 0, "no error in all of that")
end
-- no ReloadCheckSeconds in the file: every 15 s all the same
do
  local NONE = { "Config.ReloadCheckSeconds = 15", "-- (no ReloadCheckSeconds)" }
  local function changed(n) return { NONE, { "Config.Verbose = false", "Config.Verbose = false\n-- change " .. n } } end
  local T = start(function() setConfig(changed(0)) end)
  check(untilStarted(T), "(session)")
  local function nextReload(max)
    local n = countLogs("settings reloaded:")
    for _ = 1, max do
      ticks(1)
      if countLogs("settings reloaded:") > n then return H.real end
    end
  end
  setConfig(changed(1))
  local look = nextReload(80)
  setConfig(changed(2))
  local at = nextReload(80)
  check(look ~= nil and at ~= nil and at - look == 15.0,
    ("no ReloadCheckSeconds in the file: looked at every 15 s (%s)"):format(tostring(at and look and at - look)))
end

-- Verbose: the file's own value counts for a part that names none
do
  local T = start(function()
    setConfig({ { "Config.Verbose = false", "Config.Verbose = true" }, { "Config.Chests = {\n    Enabled = true,", "Config.Chests = {\n    Enabled = true,\n    Verbose = false," } })
  end)
  local _, creatures, items, chests, crime = T.config()
  check(creatures.Verbose == true and items.Herbs.Verbose == true and items.WorldItems.Verbose == true and items.Verbose == true and crime.Verbose == true,
    "Verbose = true counts for every part that does not name its own")
  check(chests.Verbose == false, "a part's own Verbose = false stays")
end

-- ================================================================ the console command
print("== main: the console command\n")
do
  local T = start()
  check(untilStarted(T), "(session)")
  ticks(60)
  local lines = {}
  local ar = { Log = function(self, text) lines[#lines + 1] = text end }
  local n0 = #H.logs
  -- UE4SS hands the words after the command as a list
  check(T.console("repop now", { "now" }, ar) == true and lines[1] == "[G1R_Repopulate] creature cycle queued (runs on the next update)" and T.session().forceCreatures == true,
    "'now', the words as a list: " .. tostring(lines[1]))
  check(#H.logs == n0 + 1 and H.logs[#H.logs] == "[G1R_Repopulate] creature cycle queued (runs on the next update)\n", "the answer also goes to the log")
  ticks(1)
  check(T.session().forceCreatures == nil, "(the cycle was started)")
  lines = {}
  check(T.console("repop NOW", { "NOW" }, ar) == true and lines[1] == "[G1R_Repopulate] creature cycle queued (runs on the next update)", "capital letters count the same")
  ticks(1)
  -- or only the whole line
  lines = {}
  check(T.console("repop items", nil, ar) == true and lines[1] == "[G1R_Repopulate] world item pass queued", "'items', only the whole line given: " .. tostring(lines[1]))
  lines = {}
  check(T.console("repop crime", nil, ar) == true and #lines == 1 and lines[1]:find("^%[G1R_Repopulate%] crime: ") ~= nil, "'crime': " .. tostring(lines[1]))
  -- anything else: the status
  for _, words in ipairs({ { "repop", {} }, { "repop status", { "status" } }, { "repop whatever", nil } }) do
    lines = {}
    local status = T.status()
    check(T.console(words[1], words[2], ar) == true and #lines == #status and #status == 7 and lines[1] == "[G1R_Repopulate] " .. status[1]
      and lines[7] == "[G1R_Repopulate] " .. status[7], ("'%s': the %d status lines"):format(words[1], #lines))
  end
  -- without an output device nothing fails
  local ok, handled = pcall(T.console, "repop status", { "status" }, nil)
  check(ok and handled == true, "without an output device: handled")
  ok, handled = pcall(T.console, "repop status", nil, { Log = function() error("no console") end })
  check(ok and handled == true, "an output device that fails: handled all the same")
end

-- ================================================================ the status lines
print("== main: the status lines\n")
do
  local T = start()
  check(untilStarted(T), "(session)")
  ticks(60)
  local pass = lastLog("world items: %d+ spots set refillable") or ""
  local total, herbs, other, vanilla = pass:match("world items: (%d+) spots set refillable %((%d+) herbs/plants at 24h, (%d+) other items ~15%%/day, (%d+) vanilla refill spots%)")
  local status = T.status()
  check(total ~= nil and status[3] == ("world items: applied, %s spots (%s herbs, %s other, %s vanilla)"):format(total, herbs, other, vanilla),
    "world items: the numbers of the pass (" .. tostring(status[3]) .. ")")
  check(tonumber(total) > 2000 and tonumber(herbs) > 500 and tonumber(other) > 1000 and tonumber(vanilla) > 100, "(real numbers)")
  local seen = count(T.state.seen)
  check(seen > 0 and status[2]:find(("populated points %d;"):format(seen), 1, true) ~= nil, ("creatures: %d populated points (%s)"):format(seen, status[2]))
  -- when the next roll is due
  for _, case in ipairs({ { 15 * 86400 + 20 * 3600 + 240, "day 15 20:04", "3.9h" }, { 16 * 86400, "day 16 00:00", "24.0h" }, { 16 * 86400 + 23 * 3600 + 3540, "day 16 23:59", "0.0h" },
      { 2 * 86400 + 6 * 3600, "day 2 06:00", "18.0h" } }) do
    H.game = case[1]
    status = T.status()
    check(status[1]:find(" | " .. case[2] .. " | ", 1, true) ~= nil and status[2]:find("; rolls every 24h (next in " .. case[3] .. ")", 1, true) ~= nil,
      ("%s: the next roll in %s (%s)"):format(case[2], case[3], status[2]:match("rolls.*$") or "?"))
  end
  -- two kinds of rolls
  setConfig({ { "EliteEveryHours = 24,", "EliteEveryHours = 72," } })
  T.reload(false)
  H.game = 15 * 86400 + 20 * 3600
  status = T.status()
  check(status[2]:find("; rolls every 24h (next in 4.0h), every 72h (next in 52.0h)", 1, true) ~= nil, "two kinds of rolls, in order: " .. (status[2]:match("rolls.*$") or "?"))
  check(#status == 7 and status[4]:find("^containers: ") ~= nil and status[5]:find("^crime: ") ~= nil and status[6]:find("^objects in play: ") ~= nil
    and status[7]:find("^this run: ") ~= nil, "seven lines: version, creatures, world items, containers, crime, objects in play, the run")
end

-- ================================================================ a world that is not ready
print("== main: a world that is not ready\n")
do
  -- the game clock stands at zero (a world before the game has begun)
  local T = start()
  local game = H.game
  H.game = 0
  ticks(60)
  check(T.session().ready == false and lastLog("session started") == nil and noErrors() == 0, "the game clock at 0: the world does not count as ready, no error")
  H.game = 0.5
  check(untilReady(T, 20), "the game clock at 0.5 s: it has begun, the world counts as ready")
  H.game = game
  check(untilStarted(T), "the clock runs: the session starts")
  -- the hero is gone for a moment in the middle of a session
  ticks(40)
  local resets, sessions = T.life().resets, T.life().sessions
  rawset(Pawn, "__valid", false)
  ticks(8)
  check(T.session().ready == false and noErrors() == 0, "the hero is gone for a moment: nothing is done, no error")
  rawset(Pawn, "__valid", nil)
  check(untilReady(T) and T.session().started == true and T.life().resets == resets and T.life().sessions == sessions, "he is back: the same session goes on")
  local calls = 0
  local chestTick = T.chests.tick
  T.chests.tick = function(...) calls = calls + 1; return chestTick(...) end
  ticks(31)
  check(calls == 0, ("but the start delay is waited again before the world is touched (%d updates of the container part)"):format(calls))
  ticks(1)
  check(calls == 1, "and then it goes on")
  T.chests.tick = chestTick
  check(noErrors() == 0, "no error in all of that")
end

-- ================================================================ parts of the mod that cannot be loaded
print("== main: a part of the mod is missing\n")
do
  local TMP = DIR:gsub("Scripts/$", "")
  local function copyWithout(file)
    local dir = TMP .. "ScriptsWithout/"
    os.execute("rm -rf " .. dir .. " && cp -r " .. DIR .. " " .. dir .. " && rm -f " .. dir .. file)
    return dir
  end
  local function loadFrom(dir)
    E.freshWorld()
    H.loop, H.console = nil, nil
    _G.REPOP_TEST = {}
    local ok, err = pcall(dofile, dir .. "main.lua")
    return ok, err, _G.REPOP_TEST
  end
  for _, file in ipairs({ "world.lua", "creatures.lua", "items.lua", "chests.lua" }) do
    local ok, err, T = loadFrom(copyWithout(file))
    check(ok and countLogs("failed to load " .. file) == 1 and countLogs("FATAL: a module failed to load; mod disabled.") == 1 and H.loop == nil and H.console == nil
      and T.status == nil, ("%s missing: said, and the mod does nothing (%s)"):format(file, tostring(err)))
  end
  do
    local ok, err, T = loadFrom(copyWithout("util.lua"))
    check(ok and countLogs("failed to load util.lua") == 1 and H.loop == nil and T.status == nil, ("util.lua missing: said, and the mod does nothing (%s)"):format(tostring(err)))
  end
  do
    -- the crime switch is an extra: without it the rest works
    local ok, err, T = loadFrom(copyWithout("crime.lua"))
    check(ok and countLogs("crime.lua did not load; the crime switch is not available.") == 1 and type(H.loop) == "function" and T.crime == nil,
      ("crime.lua missing: said, the mod is loaded (%s)"):format(tostring(err)))
    check((lastLog("loaded:") or ""):find("| crime switch unavailable\n", 1, true) ~= nil, "the load line: " .. tostring((lastLog("loaded:") or ""):match("| crime.*$")))
    E.afterLoad()
    check(untilStarted(T) and noErrors() == 0, "a session starts, no error")
    ticks(40)
    local lines = {}
    T.console("repop crime", nil, { Log = function(self, text) lines[#lines + 1] = text end })
    check(T.status()[5] == "crime: switch unavailable (crime.lua did not load)" and lines[1] == "[G1R_Repopulate] crime: switch unavailable (crime.lua did not load)"
      and noErrors() == 0, "status and console say that the switch is not there: " .. tostring(T.status()[5]))
    check(T.reload(true) == true and (lastLog("settings reloaded:") or ""):find("| crime switch unavailable\n", 1, true) ~= nil and noErrors() == 0,
      "and the settings can still be reloaded: " .. tostring((lastLog("settings reloaded:") or ""):match("| crime.*$")))
  end
  do
    -- a UE4SS build without the timer the mod runs on
    local loop = _G.LoopInGameThreadWithDelay
    _G.LoopInGameThreadWithDelay = nil
    local ok, err, T = loadFrom(DIR)
    _G.LoopInGameThreadWithDelay = loop
    check(ok and countLogs("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; mod disabled.") == 1 and countLogs("loaded:") == 0 and T.status == nil,
      ("no timer function: said, and the mod does nothing (%s)"):format(tostring(err)))
  end
  os.execute("rm -rf " .. TMP .. "ScriptsWithout/")
  -- (the scenarios after this one load the mod anew)
  start()
end
print(("== main: cases of main_cases.lua done (%s)\n"):format(MODE))
