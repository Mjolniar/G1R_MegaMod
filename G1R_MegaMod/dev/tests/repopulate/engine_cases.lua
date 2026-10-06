-- Scenarios of harness.lua's "engine" mode only: what 1.4 does with the engine
-- object, the game's begin / end of play calls and the things that end a
-- session. Loaded by harness.lua with a table of what it needs from there
-- (the harness is one long chunk at Lua's limit of local variables).
local X = ...
local H, E, check, ticks, lastLog, countLogs = X.H, X.E, X.check, X.ticks, X.lastLog, X.countLogs
local setConfig, setRandom, obj, addState, States = X.setConfig, X.setRandom, X.obj, X.addState, X.States
local makeChest, streamIn, streamOut, playerOpens, takeDefaults, isFull = X.makeChest, X.streamIn, X.streamOut, X.playerOpens, X.takeDefaults, X.isFull
local CDB, KDB, PDS, Pawn, DIR = X.CDB, X.KDB, X.PDS, X.Pawn, X.DIR
local NEW_IO = "/Script/G1R.InteractiveObjectActor"
local RESTART = "/Script/Engine.PlayerController:ClientRestart"
local FK = E.FK

-- two more kinds of settlement chests (besides the two of the small world)
local EXTRA = {}
for _, name in ipairs(H.KNAMES) do
  local d = KDB[name]
  if name ~= X.settleName and name ~= X.wildName and d.s and d.k == "chest" and #d.i >= 2 then EXTRA[#EXTRA + 1] = name end
end
local function nextBoundary(hours) return (math.floor(H.game / (hours * 3600)) + 1) * hours * 3600 end
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function finds()
  local out = {}
  for cls, n in pairs(H.finds) do out[#out + 1] = cls .. " x" .. n end
  table.sort(out)
  return table.concat(out, ", ")
end
local function tracked(T) return (select(2, T.chests.stats())) end
local function fileText(name)
  local f = io.open(DIR .. "state/" .. name, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end
-- a fresh small world, the mod loaded with a recording stand-in for the megamod's handle, a session started
local function start(before)
  E.freshWorld()
  if before then before() end
  local F = FK.new()
  local T = E.loadMod(F)
  return T, F
end

-- ================================================================ start: the engine answers, nothing is searched
print("== ENGINE: a session starts without a single search among all objects\n")
local T, F = start()
local w0 = (T.util.walks())
ticks(4)
check(lastLog("session started") == nil, "nothing during the start delay")
ticks(44)
check(lastLog("session started") ~= nil and (lastLog("world items:") or ""):find("spots set refillable") ~= nil and tracked(T) == 2,
  "session started, item spots set, the two containers known")
check(F.value("core.engine") == "handed over at a map load" and F.detail("core.engine") == "GothicGameEngine", "note core.engine: handed over at a map load")
check(F.value("core.controller_by") == "engine" and F.value("core.game_time_by") == "engine" and F.value("items.manager_by") == "engine"
  and F.value("core.play_hooks") == "in use", "notes: controller, clock and world point manager come from the engine; the play hooks are in use")
check(F.value("core.profile") == 2 and (lastLog("session started") or ""):find("state profile_2.lua", 1, true) ~= nil, "the profile id comes from the engine too")
check((T.util.walks()) == w0 and next(H.finds) == nil, ("no search among all objects up to here (%d since the mod started; %s)"):format((T.util.walks()) - w0, finds()))
check(H.engine.controller > 0 and H.engine.subsystem > 0 and H.engine.manager > 0 and H.engine.paused > 0, "(the engine's libraries and the game's getter were asked)")
check(F.opCount("^items: set the refill values") == 1 and F.opCount("^containers: look at new objects") >= 1 and #F.openOps() == 0,
  ("what touches the game is announced before and taken back after (%d operations, %d open)"):format(#F.ops, #F.openOps()))
ticks(1300)    -- 325 s: an evidence scan among them
check(next(H.finds) == nil and F.opCount("^creatures: look at populated points") >= 1,
  "five minutes of play, with a look at the populated spawn points: still nothing searched (" .. finds() .. ")")

-- ================================================================ the hero is put into the world again
print("== ENGINE: mounting and dismounting do not end the session\n")
local S = E.small().settle
H.player = { S.pos[1] + 1500, S.pos[2], 0 }      -- near the settlement chest: it is looked at all the time
ticks(12)
local resets0, sessions0, items0 = countLogs("session reset"), countLogs("session started"), countLogs("world items:")
local has0 = H.io.hasCalls
ticks(8)
check(H.io.hasCalls > has0, "(control: the container next to the hero is looked at every few updates)")
H.hooks[RESTART]()                               -- he mounts
local c0, s0, m0, p0
c0, s0, m0, p0, has0 = H.engine.controller, H.engine.subsystem, H.engine.manager, H.engine.paused, H.io.hasCalls
ticks(11)                                        -- 2.75 s
check(H.engine.controller == c0 and H.engine.subsystem == s0 and H.engine.manager == m0 and H.engine.paused == p0 and H.io.hasCalls == has0,
  "for 3 s after the hero was put into the world again nothing of the game is asked or touched")
ticks(12)
check(H.io.hasCalls > has0, "then the mod goes on")
check(countLogs("session reset") == resets0 and countLogs("session started") == sessions0 and countLogs("world items:") == items0,
  "no reset, no new session, the 3974 item spots are not gone through again")
for _ = 1, 20 do H.hooks[RESTART](); ticks(14) end
check(countLogs("session reset") == resets0 and countLogs("session started") == sessions0 and countLogs("world items:") == items0 and next(H.finds) == nil,
  "twenty more in 70 s: the same (" .. finds() .. ")")
check(T.life().possessions == 21 and T.status()[7]:find("hero put into the world again 21 times %(no reset%)") ~= nil, "counted: " .. T.status()[7])
-- a setting for the waiting time
setConfig({ { "return Config", "Config.SettleSeconds = 0\nreturn Config" } })
T.reload(false)
has0 = H.io.hasCalls
H.hooks[RESTART]()
ticks(8)
check(H.io.hasCalls > has0, "Config.SettleSeconds = 0: no waiting")
setConfig({})
T.reload(false)

-- ================================================================ the game is paused
print("== ENGINE: nothing is touched while the game is paused\n")
ticks(48)
has0 = H.io.hasCalls
H.paused = true
local asks0, pauseAsks0, ctrl0 = H.engine.subsystem, H.engine.paused, H.engine.controller
ticks(100)
check(H.io.hasCalls == has0 and T.life().pauses == 1, "25 s paused: the container next to the hero is not looked at")
check(H.engine.subsystem == asks0 and H.engine.controller == ctrl0 and H.engine.paused == pauseAsks0 + 100,
  ("nothing else is asked of the game either - not its clock, not the hero: one question per update, whether it is still paused (%d)"):format(H.engine.paused - pauseAsks0))
local W2 = makeChest(EXTRA[1], 100500, -99000, KDB[EXTRA[1]].i)   -- (objects still enter and leave play while paused)
streamOut(W2)
H.paused = false
ticks(3)
check(H.io.hasCalls == has0, "resumed: a second goes by first")
ticks(8)
check(H.io.hasCalls > has0 and tracked(T) == 2, "then the mod goes on; the object that came and went during the pause was never looked at")

-- ================================================================ what does end a session
print("== ENGINE: what ends a session\n")
resets0, sessions0 = T.life().resets, countLogs("session started")
E.mapLoad()
check(T.life().resets == resets0 + 1 and (lastLog("session reset") or ""):find("%(map load%)") ~= nil, "a map load: " .. tostring(lastLog("session reset")))
ticks(52)
check(countLogs("session started") == sessions0 + 1 and tracked(T) == 2, "and a new session starts, the containers of the world are known again")
H.game = H.game - 3
ticks(2)
check(T.life().resets == resets0 + 1, "the game clock 3 s back: nothing")
H.game = H.game + 5 * 3600
ticks(2)
check(T.life().resets == resets0 + 1, "the game clock 5 hours on (sleeping, waiting): nothing")
H.game = H.game - 100
ticks(2)
check(T.life().resets == resets0 + 2 and (lastLog("session reset") or ""):find("%(the game clock went back: 100 s%)") ~= nil,
  "the game clock 100 s back: " .. tostring(lastLog("session reset")))
ticks(52)
check(countLogs("session started") == sessions0 + 2, "and a new session starts")
local other = obj("GothicPlayerControllerBaseBP_C /Game/Maps/MainMap.PC_7")
other.K2_GetPawn = function() return Pawn end
H.controllerNow = other
ticks(4)
check(T.life().resets == resets0 + 3 and (lastLog("session reset") or ""):find("%(another player controller%)") ~= nil,
  "the engine hands out another player controller: " .. tostring(lastLog("session reset")))
ticks(52)
check(countLogs("session started") == sessions0 + 3, "and a new session starts")
local before2 = fileText("profile_2.lua")
PDS.m_CurrentProfileId = 3
ticks(130)
check(T.life().resets == resets0 + 4 and (lastLog("session reset") or ""):find("%(the profile changed: profile_2 %-> profile_3%)") ~= nil,
  "another profile (looked at every 30 s): " .. tostring(lastLog("session reset")))
ticks(52)
check((lastLog("session started") or ""):find("state profile_3.lua", 1, true) ~= nil and before2 ~= nil and fileText("profile_2.lua") ~= nil,
  "the new session works on the other profile's progress file; the first one's was written before")
PDS.m_CurrentProfileId = 2
ticks(130); ticks(52)
check(T.status()[7]:find("5 resets %(another player controller 1, map load 2, the game clock went back 1, the profile changed 2%)") ~= nil
  or T.status()[7]:find("resets %(another player controller 1, map load %d, the game clock went back 1, the profile changed 2%)") ~= nil,
  "the reasons are counted: " .. T.status()[7])
check(next(H.finds) == nil, "and all of that without a search among all objects (" .. finds() .. ")")

-- ================================================================ objects that leave play
print("== ENGINE: an object that leaves play is dropped at once\n")
T, F = start()
ticks(52)
S = E.small().settle
H.player = { S.pos[1] + 1500, S.pos[2], 0 }
ticks(8)
local touched0 = #E.touched
-- one that leaves before the mod ever looked at it
local early = makeChest(EXTRA[1], 100500, -99000, KDB[EXTRA[1]].i)
streamOut(early)
-- one the mod knows and looks at every few updates
streamOut(S)
ticks(40)
check(tracked(T) == 1 and #E.touched == touched0, ("both dropped without a touch after their end of play (%d known, %d accesses)"):format(tracked(T), #E.touched - touched0))
-- it comes back: a new object, a new entry, the old record of its progress
playerOpens(E.small().wild, takeDefaults(E.small().wild))
streamIn(S)
ticks(8)
check(tracked(T) == 2, "the container that streams in again is known a moment after it began play (no notification, no search needed)")
-- another object begins play at the address of one whose end of play was not announced
H.play.silentEnd = true
local addrOld = S.actor.__addr
streamOut(S)
H.play.silentEnd = nil
H.play.silentBegin = true
local twin = makeChest(EXTRA[2], 100500, -98000, KDB[EXTRA[2]].i)
H.play.silentBegin = nil
twin.actor.__addr = addrOld
E.beginPlay(twin.actor)
ticks(12)
check(tracked(T) == 2 and T.world.stats().missed == 0, "an object that begins play at the address of a kept one replaces it (the kept one is not asked anything)")
H.player = { twin.pos[1] + 1500, twin.pos[2], 0 }
playerOpens(twin, takeDefaults(twin))
ticks(12)
setRandom(0.2); H.game = H.game + 86400 + 60; ticks(40)
check(isFull(twin) and (lastLog("restocked") or ""):find(EXTRA[2], 1, true) ~= nil, "and it is the new object that is looked at and restocked (" .. tostring(lastLog("restocked")) .. ")")
setRandom(0.0)

-- ================================================================ the game does not announce an end of play
print("== ENGINE: ends of play that are not announced\n")
T, F = start()
ticks(52)
local many = {}
do
  local n = 0
  for _, name in ipairs(H.KNAMES) do
    if n < 22 and name ~= X.settleName and name ~= X.wildName and KDB[name].k == "chest" then
      n = n + 1
      many[n] = makeChest(name, 600000 + n * 1000, -600000, KDB[name].i)
    end
  end
end
ticks(40)
check(tracked(T) == 24, "24 containers known (" .. tracked(T) .. ")")
H.play.silentEnd = true
for _, ch in ipairs(many) do streamOut(ch) end
H.play.silentEnd = nil
ticks(120)
check(lastLog("begin / end of play calls are not used any more %(20 kept objects were gone without the game having said so%)") ~= nil
  and F.value("core.play_hooks") == "not used",
  "after 20 kept objects that were gone without an end of play the calls are not relied on any more: " .. tostring(F.detail("core.play_hooks")))
check(T.status()[6] == "objects in play: not followed (20 kept objects were gone without the game having said so)", "status: " .. tostring(T.status()[6]))
check(tracked(T) == 2, "the objects that are gone are dropped all the same (" .. tracked(T) .. " known)")
-- the mod works the way it did before 1.4: notifications, one search, every object checked by name
-- (and asks kept objects whether they are still there: the traps of this harness are off from here)
E.trapOff = true
S = E.small().settle
streamOut(S); ticks(12); streamIn(S); H.notify[NEW_IO](S.actor)
playerOpens(S, takeDefaults(S)); ticks(12)
setRandom(0.2); H.game = H.game + 86400 + 60; ticks(40)
check(isFull(S), "containers still work: a looted one is restocked")
setRandom(0.0)
H.game = nextBoundary(24) + 10; ticks(120)
check(lastLog("creature cycle") ~= nil and (H.finds.GothicCharacterState or 0) >= 1, "creature cycles still work (" .. finds() .. ")")

-- ================================================================ states the game never announced
print("== ENGINE: the list of states in play is compared with a search at every count\n")
T, F = start()
ticks(52)
H.game = nextBoundary(24) + 10; ticks(120)
check((F.value("creatures.states_in_play") or ""):find("^%d+ found: %d+ in play, 0 have left play, 0 never announced; 0 in play and not found$") ~= nil,
  "a count: every state the search finds is in play (" .. tostring(F.value("creatures.states_in_play")) .. ")")
check(F.value("core.play_hooks") == "in use" and (H.finds.GothicCharacterState or 0) == 1, "the count is the one thing that searches (" .. finds() .. ")")
-- two states the mod was never told of: tolerated, and not touched
H.play.silentBegin = true
local quiet1 = addState(CDB[X.P_EMPTY].s[1].u, X.P_EMPTY, 901)
local quiet2 = addState(CDB[X.P_EMPTY].s[1].u, X.P_EMPTY, 902)
H.play.silentBegin = nil
local idCalls = 0
for _, st in ipairs({ quiet1, quiet2 }) do
  local get = st.GetCharacterGlobalId
  st.GetCharacterGlobalId = function(self) idCalls = idCalls + 1; return get(self) end
end
H.game = nextBoundary(24) + 10; ticks(120)
check((F.value("creatures.states_in_play") or ""):find("2 never announced") ~= nil and F.value("core.play_hooks") == "in use" and idCalls == 0,
  "two states that never began play: noted, not counted, not touched (" .. tostring(F.value("creatures.states_in_play")) .. ")")
-- many: the announcements are not relied on any more, and the count is done the old way
H.play.silentBegin = true
for i = 1, 30 do addState(CDB[X.P_EMPTY].s[1].u, X.P_EMPTY, 910 + i) end
H.play.silentBegin = nil
H.spawns = {}
for k in pairs(T.state.recent) do T.state.recent[k] = nil end
H.game = nextBoundary(24) + 10; ticks(160)
E.trapOff = true
check(F.value("core.play_hooks") == "not used" and (F.detail("core.play_hooks") or ""):find("^32 of %d+ character states were never announced$") ~= nil,
  "32 of them: " .. tostring(F.detail("core.play_hooks")))
local atEmpty = 0
for _, sp in ipairs(H.spawns) do if sp.point == X.P_EMPTY then atEmpty = atEmpty + 1 end end
check(lastLog("creature cycle") ~= nil and idCalls > 0 and atEmpty == 0, "that count looks at every state, the unannounced ones too: the point they stand at is not refilled")

-- ================================================================ a state leaves play while it is waited for
print("== ENGINE: states that leave play during a count or before their corpse is removed\n")
T, F = start()
ticks(52)
for i = 1, 200 do addState(CDB[X.farName].s[1].u, X.farName, 300 + i, { pos = { CDB[X.farName].x, CDB[X.farName].y, 0 } }) end
local late = addState(CDB[X.P_EMPTY].s[1].u, X.P_EMPTY, 990, { dead = true })      -- the last one in the search's list
touched0 = #E.touched
H.game = nextBoundary(24) + 10
ticks(1)
while F.opCount("^creatures: count, states") == 0 do ticks(1) end
check(T.creatures.diag().census_running == true, "(a count over " .. #States .. " states takes several updates)")
E.removeState(late)
ticks(40)
check(T.creatures.diag().census_running == false and T.creatures.diag().stats.skipped >= 1 and #E.touched == touched0,
  ("a state that left play while the count ran is passed over without a touch (%d passed over)"):format(T.creatures.diag().stats.skipped))
-- the corpse of a dead creature is noted by the count and removed when its successor appears - unless it has left play by then
for k in pairs(T.state.recent) do T.state.recent[k] = nil end
local corpse
for _, st in ipairs(States) do if st.__valid ~= false and st.__id and st.__id:find(X.P_ELITE, 1, true) and st.__dead then corpse = st end end
corpse.__removed = false                                         -- (the first count's respawn took it away: it lies there again)
H.player = { CDB[X.P_ELITE].x + 500, CDB[X.P_ELITE].y, 0 }       -- the hero stands at the point: its respawn waits
H.spawns, H.removed = {}, 0
T.console("repop now", nil, nil)
ticks(60)
local spawnedThere = 0
for _, sp in ipairs(H.spawns) do if sp.point == X.P_ELITE then spawnedThere = spawnedThere + 1 end end
check(corpse ~= nil and spawnedThere == 0, "(a respawn waits while the hero stands at its point)")
E.removeState(corpse)                                             -- the game removes the corpse itself in the meantime
touched0 = #E.touched
H.player = { 100000, -100000, 0 }
ticks(160, 0.5)
spawnedThere = 0
for _, sp in ipairs(H.spawns) do if sp.point == X.P_ELITE then spawnedThere = spawnedThere + 1 end end
check(spawnedThere == 1 and #E.touched == touched0, "the creature comes back, and the corpse that has left play since the count is not touched")

-- ================================================================ where a corpse lies is not known
print("== creatures: a corpse is only removed when its distance to the hero is known\n")
T, F = start()
ticks(52)
local corpse2
for _, st in ipairs(States) do if st.__id and st.__id:find(X.P_EMPTY, 1, true) and st.__dead then corpse2 = st end end
local where = corpse2.GetCharacterLocation
corpse2.GetCharacterLocation = function() return nil end
H.spawns, H.removed = {}, 0
H.game = nextBoundary(24) + 10; ticks(160)
spawnedThere = 0
for _, sp in ipairs(H.spawns) do if sp.point == X.P_EMPTY then spawnedThere = spawnedThere + 1 end end
check(spawnedThere == 1 and corpse2.__removed ~= true and F.value("creatures.corpse_kept") == "distance to the player not known",
  "the creature came back; its predecessor's corpse, whose place cannot be read, stays (" .. tostring(F.detail("creatures.corpse_kept")) .. ")")
check(T.creatures.diag().stats.corpsesKept == 1, "counted")
corpse2.GetCharacterLocation = where

-- ================================================================ spawn point scripts
print("== ENGINE: the script of a spawn point comes from the game's world point manager\n")
check(F.value("creatures.point_scripts_by") == "manager" and H.finds.WorldPointScript == nil and H.configsGrown == 0,
  "note creatures.point_scripts_by = manager; no search for script objects (" .. finds() .. ")")
local viaPoint, viaLibrary = 0, 0
for _, sp in ipairs(H.spawns) do if sp.how == "point" then viaPoint = viaPoint + 1 else viaLibrary = viaLibrary + 1 end end
check(viaPoint >= 2 and viaLibrary >= 1, ("respawns went through the point's script (%d) and, where a point has none, through the library (%d)"):format(viaPoint, viaLibrary))
-- the manager's list holds no script objects (another game version): the old way
T, F = start(function()
  for _, c in ipairs(X.Configs) do c.__script, c.m_WorldPointScriptInstance = c.m_WorldPointScriptInstance, nil end
end)
ticks(52)
H.spawns = {}
H.game = nextBoundary(24) + 10; ticks(200)
viaPoint = 0
for _, sp in ipairs(H.spawns) do if sp.how == "point" then viaPoint = viaPoint + 1 end end
check(viaPoint >= 2 and F.value("creatures.point_scripts_by") == "search" and H.finds.WorldPointScript == 1,
  ("no script objects in the manager's list: they are searched for as before, once (%d respawns at their points; %s)"):format(viaPoint, finds()))
for _, c in ipairs(X.Configs) do c.m_WorldPointScriptInstance, c.__script = c.__script, nil end

-- ================================================================ an engine way that answers nothing
print("== ENGINE: a way that has never answered is not believed for long\n")
T, F = start(function() H.noClock, H.noManager = true, true end)
ticks(40)
check(lastLog("session started") == nil and next(H.finds) == nil, "the engine's library has no game clock: for 10 s that is taken as it is")
ticks(80)
check(F.value("core.game_time_by") == "search (the engine's own way answered nothing)" and H.finds.GameTimeSubsystem == 1,
  "then the clock is searched for as before 1.4, and the note says so")
ticks(120)
check(lastLog("session started") ~= nil and (lastLog("world items:") or ""):find("spots set refillable") ~= nil
  and F.value("items.manager_by") == "search (the game's own getter answered nothing)" and H.finds.WorldPointManager == 1,
  "the same for the world point manager: the item spots are set (" .. finds() .. ")")
H.noClock, H.noManager = nil, nil
-- a way that has answered before is believed: "none" then means none
T, F = start()
ticks(52)
H.noManager = true
T.items.reset()
ticks(200)
check(H.finds.WorldPointManager == nil and countLogs("world items: no WorldPointManager") == 1,
  "the getter answered before and now has no manager: nothing is searched for, the mod waits (" .. finds() .. ")")
H.noManager = nil
ticks(44)
check(countLogs("spots set refillable") == 2, "and goes on when it is there again")

-- ================================================================ begin of play arrives, end of play never does
print("== ENGINE: hooks that do not fire\n")
T, F = start(function() H.play.noEnds, E.trapOff = true, true end)
do
  -- a world of 250 objects begins play; the map load that put it there ended nothing
  local n = 0
  for _, name in ipairs(H.KNAMES) do
    if n < 250 and name ~= X.settleName and name ~= X.wildName then
      n = n + 1
      makeChest(name, 700000 + n * 1000, -700000, KDB[name].i)
    end
  end
end
ticks(52)
check(F.value("core.play_hooks") == "in use" and tracked(T) >= 100 and H.finds.InteractiveObjectActor == nil,
  ("in the first world nothing can be said about ends of play (none may have been due): the calls are in use (%d containers known)"):format(tracked(T)))
-- the world is unloaded: every one of its actors ends play - and the mod hears of none
E.mapLoad()
ticks(52)
check(F.value("core.play_hooks") == "not used" and F.detail("core.play_hooks") == "no end of play call arrived",
  "a world of many actors was unloaded and not one end of play arrived: the calls are not relied on any more (" .. tostring(F.detail("core.play_hooks")) .. ")")
ticks(40)
check(tracked(T) >= 100 and (H.finds.InteractiveObjectActor or 0) == 1, ("the containers are found by the one search of the old way (%d known)"):format(tracked(T)))
H.play.noEnds = nil

-- ================================================================ the mod is started in a running game
-- No map load is seen before the hero is there: the engine object was not handed over, the actors in play
-- began play before the mod's hooks existed. Everything works as before 1.4 until the next map load.
print("== ENGINE: the mod is started in a running game\n")
E.freshWorld()
do
  F = FK.new()
  rawset(_G, "G1R_DIAG", F.handle)
  _G.REPOP_TEST = {}
  dofile(DIR .. "main.lua")
  rawset(_G, "G1R_DIAG", nil)
  T = _G.REPOP_TEST
  E.trapOff = true          -- (the objects of this world are checked the old way: by asking them)
  local searched = H.sfo.lib + H.sfo.ai + H.sfo.item + H.sfo.other
  local asked = H.engine.controller + H.engine.subsystem + H.engine.manager
  ticks(60)
  check(lastLog("session started") ~= nil and F.value("core.engine") == nil and F.value("core.paths_found") == nil
    and F.value("core.play_hooks") == "waiting for a map load" and searched == 0,
    "no map load was seen: no engine object, no path looked up ahead, the game's begin / end of play calls are not used yet (" .. tostring(F.value("core.play_hooks")) .. ")")
  check(tracked(T) == 2 and H.finds.InteractiveObjectActor == 1 and (H.finds.GothicPlayerControllerBaseBP_C or 0) >= 1
    and H.engine.controller + H.engine.subsystem + H.engine.manager == asked,
    ("the session starts the old way: hero, clock, profile, containers are searched for, the engine is not asked (%s)"):format(finds()))
  check((T.status()[6] or ""):find("followed from the next map load on", 1, true) ~= nil, "the status says so: " .. tostring(T.status()[6]))
  -- a container that streams in begins play - not followed yet - and is announced by UE4SS, as before 1.4
  local late = makeChest(EXTRA[1], 101500, -100500, KDB[EXTRA[1]].i)
  H.notify[NEW_IO](late.actor)
  ticks(40)
  check(tracked(T) == 3, "a container that streams in is taken from UE4SS's announcement of new objects")
  local begins = H.play.begins
  -- the next map load: from here on the mod is where a freshly started game puts it
  E.trapOff = nil
  local walks = {}
  for k, v in pairs(H.finds) do walks[k] = v end
  E.mapLoad()
  ticks(60)
  local a, b = tostring(F.value("core.paths_found")):match("^(%d+) of (%d+) found$")
  check(F.value("core.engine") == "handed over at a map load" and a ~= nil and a == b and tonumber(a) >= 12 and F.value("core.play_hooks") == "in use",
    ("the next map load hands the engine object over, the paths are looked up, the calls are in use (%s)"):format(tostring(F.value("core.paths_found"))))
  local same = true
  for k, v in pairs(H.finds) do if walks[k] ~= v and k ~= "GothicCharacterState" then same = false end end
  check(lastLog("session started") ~= nil and tracked(T) == 3 and same and H.play.begins > begins and H.engine.controller + H.engine.subsystem + H.engine.manager > asked + 3,
    ("the session of the new world starts without a search among all objects but the creature count's (%s)"):format(finds()))
end

-- ================================================================ the two classes are not there
print("== ENGINE: the classes of the two kinds of actors are not found\n")
do
  local io, st = E.paths["/Script/G1R.InteractiveObjectActor"], E.paths["/Script/G1R.GothicCharacterState"]
  E.paths["/Script/G1R.InteractiveObjectActor"], E.paths["/Script/G1R.GothicCharacterState"] = nil, nil
  local asked = H.engine.controller + H.engine.subsystem
  T, F = start(function() E.trapOff = true end)
  E.paths["/Script/G1R.InteractiveObjectActor"], E.paths["/Script/G1R.GothicCharacterState"] = io, st
  ticks(60)
  local a, b = tostring(F.value("core.paths_found")):match("^(%d+) of (%d+) found$")
  check(F.value("core.play_hooks") == "not available" and F.detail("core.play_hooks") == "the classes of the game were not found" and a ~= nil and b - a == 2,
    ("neither class is found at the first map load: the calls are not used, and the count of paths shows it (%s)"):format(tostring(F.value("core.paths_found"))))
  check(lastLog("session started") ~= nil and tracked(T) == 2 and H.finds.InteractiveObjectActor == 1 and H.engine.controller + H.engine.subsystem > asked + 2,
    ("containers are found the old way; the engine is still asked for what it hands out (%s)"):format(finds()))
  local late = makeChest(EXTRA[1], 101500, -100500, KDB[EXTRA[1]].i)
  H.notify[NEW_IO](late.actor)
  ticks(40)
  local byPath = H.sfo.other
  E.mapLoad()
  ticks(60)
  check(tracked(T) == 3 and F.value("core.play_hooks") == "not available" and H.sfo.other == byPath and F.count["core.paths_found"] == 1,
    "a later map load does not look for the classes again (nor for any other path)")
  E.trapOff = nil
end
