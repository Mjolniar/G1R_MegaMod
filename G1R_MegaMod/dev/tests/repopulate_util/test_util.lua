-- Unit tests of the repopulate module's util.lua: the small helpers, the spacing
-- of searches among all objects, the engine's own way to the objects that are
-- there once, the game clock and the progress file's text form. Each part is
-- loaded fresh (util.lua keeps what it found for the whole run) and runs
-- against a few lines of stand-in for the UE4SS functions it uses.
-- Usage: lua5.4 test_util.lua      (last line: util tests finished: N ok, M failure(s))
local HERE = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./")
local SRC = os.getenv("G1R_REPOP_SRC") or (HERE .. "../../../modules/repopulate/Scripts/")
local TMP = (os.getenv("G1R_TEST_TMP") or "/tmp/g1r-tests") .. "/repop_util/"
os.execute("rm -rf " .. TMP .. " && mkdir -p " .. TMP)

local oks, fails = 0, 0
local SHOWOK = os.getenv("SHOWOK") == "1"
local function check(c, msg)
  if c then oks = oks + 1; if SHOWOK then io.write("  ok   ", msg, "\n") end
  else fails = fails + 1; io.write("  FAIL ", msg, "\n") end
end

-- ---------------------------------------------------------------- stand-ins
local NOW = 1000.0
os.clock = function() return NOW end
local Logs = {}
_G.print = function(s) Logs[#Logs + 1] = s end
local function logged(pat) local n = 0 for _, l in ipairs(Logs) do if l:find(pat) then n = n + 1 end end return n end

local Base = {}
Base.__index = Base
function Base:IsValid() return rawget(self, "__valid") ~= false end
function Base:GetFullName() return rawget(self, "__full") end
local function obj(full, t)
  t = t or {}
  t.__full = full
  return setmetatable(t, Base)
end

-- What the three search functions answer and how often they were asked.
local Finds, Answers = {}, { first = {}, all = {}, path = {} }
local function count(kind, key) Finds[kind .. ":" .. tostring(key)] = (Finds[kind .. ":" .. tostring(key)] or 0) + 1 end
local function asked(kind, key) return Finds[kind .. ":" .. tostring(key)] or 0 end
_G.FindFirstOf = function(cls)
  count("first", cls)
  local a = Answers.first[cls]
  if type(a) == "function" then return a() end
  return a
end
_G.FindAllOf = function(cls)
  count("all", cls)
  local a = Answers.all[cls]
  if type(a) == "function" then return a() end
  return a
end
_G.StaticFindObject = function(path)
  count("path", path)
  local a = Answers.path[path]
  if type(a) == "function" then return a() end
  return a
end

-- A fresh util.lua. `diag`: a table that collects the notes (the megamod's handle), or nil (the mod on its own).
local function fresh(diag)
  Finds, Answers = {}, { first = {}, all = {}, path = {} }
  Logs = {}
  rawset(_G, "G1R_DIAG", diag)
  local U = dofile(SRC .. "util.lua")
  rawset(_G, "G1R_DIAG", nil)
  return U
end
local function diagFake()
  local d = { notes = {}, crumbs = {} }
  d.note = function(key, value, detail) d.notes[#d.notes + 1] = { key = key, value = value, detail = detail } end
  d.crumb = function(text) d.crumbs[#d.crumbs + 1] = text end
  d.last = function(key) for i = #d.notes, 1, -1 do if d.notes[i].key == key then return d.notes[i].value end end end
  return d
end

-- ================================================================ 1. the small helpers
do
  local U = fresh()
  -- error lines: each key once, 20 in a run, the 20th says that no more follow
  for i = 1, 3 do U.logError("same", "one error") end
  check(logged("one error") == 1, "logError: the same key is logged once")
  for i = 2, 30 do U.logError("key" .. i, "error number " .. i) end
  check(logged("error number") == 19 and #Logs == 20, ("logError: 20 error lines in a run (%d)"):format(#Logs))
  check(Logs[20]:find("error number 20 (further errors suppressed)", 1, true) ~= nil and not Logs[19]:find("suppressed", 1, true),
    "logError: the 20th line says that further errors are not shown")
  check(Logs[1] == "[G1R_Repopulate] one error\n", "log: the module's name in front, a line break behind")
  U.logOnce("once", "said once"); U.logOnce("once", "said once")
  check(logged("said once") == 1, "logOnce: once per key")

  -- try: why a call was not made
  local ok, why = U.try(nil, "Anything")
  check(ok == false and why == "nil object", "try: no object - false, 'nil object'")
  ok, why = U.try(obj("X /a.b", { __valid = false }), "Anything")
  check(ok == false and why == "object validation failed", "try: an object that is gone - false, 'object validation failed'")
  check(U.valid(nil) == false and U.valid(obj("X /a.b")) == true, "valid: nil is not valid")

  -- num
  check(U.num(5) == 5 and U.num(2.5) == 2.5 and U.num("12") == 12 and math.type(U.num("12")) == "integer" and U.num("x") == nil and U.num(nil) == nil
    and U.num({}) == nil, "num: numbers as they are, numerals turned into numbers, anything else nil")

  -- names
  check(U.fullName(obj("Chest /Game/Map.Chest_1")) == "Chest /Game/Map.Chest_1", "fullName: the name")
  check(U.fullName(setmetatable({}, { __index = { IsValid = function() return true end, GetFullName = function() error("lost") end } })) == nil,
    "fullName: a call that fails gives nil, not the error text")
  check(U.fullName(setmetatable({}, { __index = { IsValid = function() return true end, GetFullName = function() return 17 end } })) == nil,
    "fullName: an answer that is not text gives nil")
  check(U.classToken(obj("Chest /Game/Map.Chest_1")) == "Chest", "classToken: the first word")
  check(U.objectToken(obj("Chest /Game/Map.Chest_1")) == "Chest_1" and U.objectToken(obj("X /Script/G1R.Default__WorldPointManager")) == "WorldPointManager",
    "objectToken: the last part of the path, without Default__")
  check(U.objectToken(obj("JustAName")) == "JustAName", "objectToken: a name without a class in front is taken as it is")
  check(U.isDefault(obj("X /Script/G1R.Default__WorldPointManager")) == true and U.isDefault(obj("X /Game/Map.Manager_0")) == false
    and U.isDefault(nil) == false, "isDefault: by the name")
  check(U.address({ GetAddress = function() return "0x10" end }) == nil and U.address({ GetAddress = function() return 4711 end }) == 4711,
    "address: only a number is an address")

  -- FName
  check(U.fname("abc") == "abc" and U.fname(nil) == nil and U.fname({ ToString = function() return "name" end }) == "name", "fname: text, nil, a name object")
  check(U.fname({ ToString = function() error("gone") end }) == nil and U.fname({ ToString = function() return 5 end }) == nil,
    "fname: a failing or non-text ToString gives nil")

  -- vectors
  local x, y, z = U.vec3({ X = 1, Y = 2, Z = 3 })
  check(x == 1 and y == 2 and z == 3, "vec3: three numbers")
  check(U.vec3({ X = 1, Y = 2 }) == nil and U.vec3({ X = 1, Z = 3 }) == nil and U.vec3({ Y = 2, Z = 3 }) == nil and U.vec3(nil) == nil
    and U.vec3({ X = "a", Y = 2, Z = 3 }) == nil, "vec3: nil unless all three are numbers")
  check(U.dist2(0, 0, 3, 4) == 25 and U.dist2(1, 1, 1, 1) == 0, "dist2: the squared distance")

  -- unwrap
  local inner = {}
  check(U.unwrap({ get = function() return inner end }) == inner and U.unwrap(inner) == inner and U.unwrap(nil) == nil, "unwrap: the value behind :get(), or the value itself")

  -- the chance that at least one of k rolls at p wins
  check(U.catchUp(0.5, 1) == 0.5 and math.abs(U.catchUp(0.5, 2) - 0.75) < 1e-12 and math.abs(U.catchUp(0.1, 3) - 0.271) < 1e-12, "catchUp: 1 - (1 - p) ^ k")
  check(U.catchUp(0.5, 0) == 0 and U.catchUp(1, 0) == 0 and U.catchUp(0.5, -1) == 0, "catchUp: no roll, no chance")
  check(U.catchUp(1, 1) == 1 and U.catchUp(1.5, 2) == 1 and U.catchUp(1, 5) == 1, "catchUp: a chance of 1 or more is 1")
  check(U.catchUp(0, 3) == 0 and U.catchUp(-0.5, 2) == 0, "catchUp: a chance of 0 or less is 0")
end

-- ================================================================ 2. searches among all objects are spaced out
do
  local U = fresh()
  local walks, putOff = U.walks()
  check(walks == 0 and putOff == 0, "walks: none counted at the start")
  check(U.mayWalk(NOW) == true, "mayWalk: yes when nothing speaks against it")
  Answers.first.Thing = obj("Thing /Game/Map.Thing_0")
  check(U.findFirst("Thing") == Answers.first.Thing and (U.walks()) == 1, "findFirst: the object, one walk counted")
  check(U.mayWalk(NOW) == false and U.mayWalk(NOW + 0.99) == false and U.mayWalk(NOW + 1.0) == true, "mayWalk: no second walk within a second")
  Answers.first.Gone = obj("Thing /Game/Map.Thing_1", { __valid = false })
  check(U.findFirst("Gone") == nil and U.findFirst("Missing") == nil and (U.walks()) == 3, "findFirst: an object that is gone, or none, is nil; each search is a walk")
  Answers.first.Throws = function() error("no such class") end
  check(U.findFirst("Throws") == nil, "findFirst: a search that fails gives nil")
  Answers.all.Things = { 1, 2 }
  check(#U.findAll("Things") == 2 and #U.findAll("Nothing") == 0 and (U.walks()) == 6, "findAll: the list, or an empty one; each search is a walk")
  Answers.path["/A.B"] = obj("B /A.B")
  check(U.findStatic("/A.B") == Answers.path["/A.B"] and (U.walks()) == 7, "findStatic: a first search by path is a walk")
  check(U.findStatic("/A.B") == Answers.path["/A.B"] and (U.walks()) == 7, "findStatic: a path that was found before is not counted again")
  check(U.findStatic("/No.Such") == nil and U.findStatic("/No.Such") == nil and (U.walks()) == 9, "findStatic: a path that is not there is a walk every time")

  -- quiet: no walk for a while
  U = fresh()
  U.quiet(3, NOW)
  check(U.mayWalk(NOW + 2.99) == false and U.mayWalk(NOW + 3.0) == true, "quiet: no walk for the given seconds")
  U.quiet(10, NOW); U.quiet(1, NOW)
  check(U.mayWalk(NOW + 9.99) == false and U.mayWalk(NOW + 10) == true, "quiet: a shorter quiet does not end a longer one")
  U = fresh()
  U.quiet(nil, NOW)
  check(U.mayWalk(NOW) == true, "quiet: without seconds nothing is held back")
  U.quiet(5)                                  -- (no time given: counted from now)
  check(U.mayWalk(NOW + 4.99) == false and U.mayWalk(NOW + 5) == true, "quiet: counted from now when no time is given")
  U = fresh()
  NOW = 2000.0
  U.quiet(2, 1500.0)                          -- (a time is given: that one counts, not the clock)
  check(U.mayWalk(1501.99) == false and U.mayWalk(1502.0) == true, "quiet: counted from the time given")
  NOW = 1000.0

  -- a walk waits for a calm moment, 20 seconds at most
  U = fresh()
  local calm = false
  local askedAt = {}
  U.setCalm(function(t) askedAt[#askedAt + 1] = t; return calm end)
  check(U.mayWalk(NOW) == false and askedAt[1] == NOW and select(2, U.walks()) == 1, "calm: a walk is put off while the world is not calm (counted)")
  check(U.mayWalk(NOW + 19.99) == false and select(2, U.walks()) == 2, "calm: still put off after 19.99 s")
  check(U.mayWalk(NOW + 20.0) == true and select(2, U.walks()) == 2, "calm: after 20 s it goes ahead although the world is not calm")
  -- the wait is over with that yes: the next wish waits anew
  check(U.mayWalk(NOW + 20.25) == false and U.mayWalk(NOW + 40.0) == false and U.mayWalk(NOW + 40.25) == true, "calm: the next wish waits its own 20 s")
  -- a calm moment ends the wait at once
  check(U.mayWalk(NOW + 50) == false, "(not calm again: put off)")
  calm = true
  check(U.mayWalk(NOW + 51) == true, "calm: a calm moment lets the walk through")
  -- a wish nobody came back for does not let a later walk through at once
  calm = false
  check(U.mayWalk(NOW + 100) == false, "(a wish at 100 s, not calm)")
  calm = true
  check(U.mayWalk(NOW + 101) == true, "(calm at 101 s: yes - and the caller does not walk)")
  calm = false
  check(U.mayWalk(NOW + 500) == false and U.mayWalk(NOW + 519.99) == false and U.mayWalk(NOW + 520) == true,
    "calm: a wish from long ago does not shorten the wait of a new one")
  -- a walk ends the wait as well
  check(U.mayWalk(NOW + 600) == false, "(a wish at 600 s)")
  NOW = 1000.0 + 605
  U.findAll("Things")
  check(U.mayWalk(NOW + 0.5) == false and U.mayWalk(NOW + 1.0) == false and U.mayWalk(NOW + 20.99) == false and U.mayWalk(NOW + 21.0) == true,
    "calm: after a walk the wait is counted anew")
  -- a map load drops a waiting wish
  check(U.mayWalk(NOW + 100) == false, "(a wish 100 s later)")
  U.resetCaches()
  check(U.mayWalk(NOW + 119.5) == false and U.mayWalk(NOW + 139.49) == false and U.mayWalk(NOW + 139.5) == true, "calm: a map load drops a waiting wish")
  NOW = 1000.0

  -- a search by path, once per path and run
  U = fresh()
  Answers.path["/Lib.A"] = obj("A /Lib.A")
  U.quiet(5, NOW)
  local o, why = U.findOnce("/Lib.A")
  check(o == nil and why == "later" and asked("path", "/Lib.A") == 0, "findOnce: not while walks are held back - 'later', nothing searched")
  o = U.findOnce("/Lib.A", true)
  check(o == Answers.path["/Lib.A"] and asked("path", "/Lib.A") == 1, "findOnce: with `now` the search is not put off")
  check(U.findOnce("/Lib.A") == o and asked("path", "/Lib.A") == 1, "findOnce: found once - the kept answer, no second search")
  rawset(o, "__valid", false)
  check(U.findOnce("/Lib.A") == nil and U.findOnce("/Lib.A", true) == nil and asked("path", "/Lib.A") == 1, "findOnce: found once and gone since - nil, not searched again")
  check(U.findOnce("/Lib.None", true) == nil and U.findOnce("/Lib.None", true) == nil and asked("path", "/Lib.None") == 1,
    "findOnce: a path that is not there is searched for once")
  Answers.path["/Lib.B"], Answers.path["/Lib.C"] = obj("B /Lib.B"), obj("C /Lib.C")
  check(U.warm({ "/Lib.B", "/Lib.None", "/Lib.C" }) == 2 and asked("path", "/Lib.None") == 1, "warm: how many of the paths are there")
end

-- ================================================================ 3. the engine's own way
-- An engine object as UE4SS hands it to the map load hooks, with a world, and the libraries by path.
local function engineWorld(U, opts)
  opts = opts or {}
  local world = obj("World /Game/Maps/MainMap.MainMap")
  local engine = obj(opts.engineName or "GothicGameEngine /Engine/Transient.GothicGameEngine_0")
  engine.GameViewport = obj("GameViewportClient /Engine/Transient.GameViewportClient_0", { World = world })
  local calls = { controller = 0, subsystem = 0, manager = 0, paused = 0 }
  local answer = { controller = nil, subsystem = nil, manager = nil, paused = false }
  Answers.path["/Script/Engine.Default__GameplayStatics"] = obj("GameplayStatics /Script/Engine.Default__GameplayStatics", {
    GetPlayerController = function(self, w, index) calls.controller = calls.controller + 1; assert(w == world and index == 0); return answer.controller end,
    IsGamePaused = function(self, w) calls.paused = calls.paused + 1; assert(w == world); return answer.paused end })
  local function getter(self, w, cls) calls.subsystem = calls.subsystem + 1; assert(w == world); return answer.subsystem end
  Answers.path["/Script/Engine.Default__SubsystemBlueprintLibrary"] = obj("SubsystemBlueprintLibrary /Script/Engine.Default__SubsystemBlueprintLibrary",
    { GetWorldSubsystem = getter, GetGameInstanceSubsystem = getter })
  Answers.path["/Script/GameStateSubsystem.Default__GameStateSubsystemBlueprintLibrary"] =
    obj("GameStateSubsystemBlueprintLibrary /Script/GameStateSubsystem.Default__GameStateSubsystemBlueprintLibrary", { GetGameStateSubsystem = getter })
  Answers.path["/Script/G1R.Default__WorldPointManager"] = obj("WorldPointManager /Script/G1R.Default__WorldPointManager",
    { GetInstance = function(self, w) calls.manager = calls.manager + 1; assert(w == world); return answer.manager end })
  Answers.path["/Script/G1R.GameTimeSubsystem"] = obj("Class /Script/G1R.GameTimeSubsystem")
  Answers.path["/Script/G1R.PersistentDataSubsystem"] = obj("Class /Script/G1R.PersistentDataSubsystem")
  if not opts.noEngine then U.setEngine({ get = function() return engine end }) end
  -- (the mod looks its paths up at the first map load: main.lua, firstMapLoad)
  local paths = {}
  for path in pairs(Answers.path) do paths[#paths + 1] = path end
  U.warm(paths)
  Finds = {}
  return { world = world, engine = engine, calls = calls, answer = answer }
end

do
  -- what is taken for the engine object
  local D = diagFake()
  local U = fresh(D)
  check(U.engine() == nil and U.engineWorld() == nil and U.paused() == nil, "engine: none before a map load has handed one over")
  U.setEngine(nil)
  U.setEngine({ get = function() return nil end })
  U.setEngine(obj("GothicGameEngine /Engine/Transient.GothicGameEngine_0", { __valid = false, GameViewport = {} }))
  check(U.engine() == nil, "setEngine: nothing, or an object that is gone, is not taken")
  U.setEngine(setmetatable({ GameViewport = {} }, { __index = { IsValid = function() return true end, GetFullName = function() return nil end } }))
  check(U.engine() == nil, "setEngine: an object without a name is not taken")
  U.setEngine(obj("GothicGameEngine /Script/G1R.Default__GothicGameEngine", { GameViewport = {} }))
  check(U.engine() == nil, "setEngine: a class default object is not taken")
  U.setEngine(obj("World /Game/Maps/MainMap.MainMap", { GameViewport = {} }))
  check(U.engine() == nil, "setEngine: an object of another class is not taken")
  U.setEngine(obj("GothicGameEngine /Engine/Transient.GothicGameEngine_0"))
  check(U.engine() == nil and D.last("core.engine") == nil, "setEngine: an engine without a game window is not taken")
  local W = engineWorld(U)
  check(U.engine() == W.engine and U.engineWorld() == W.world and D.last("core.engine") == "handed over at a map load", "setEngine: the engine object, and its world")
  -- kept while it lives; another one is taken when it is gone
  local second = obj("GothicGameEngine /Engine/Transient.GothicGameEngine_1", { GameViewport = obj("V /Engine/Transient.V_1", { World = obj("World /Game/Other.Other") }) })
  U.setEngine(second)
  check(U.engine() == W.engine, "setEngine: the engine object that was taken is kept while it lives")
  rawset(W.engine, "__valid", false)
  U.setEngine(second)
  check(U.engine() == second, "setEngine: when it is gone, the next one handed over is taken")
  rawset(second, "__valid", false)
  check(U.engine() == nil and U.engineWorld() == nil, "engine: an engine object that is gone is not used")
  local third = obj("GothicGameEngine /Engine/Transient.GothicGameEngine_2", { GameViewport = obj("V /Engine/Transient.V_2", { World = obj("World /Game/W.W", { __valid = false }) }) })
  U.setEngine(third)
  check(U.engine() == third and U.engineWorld() == nil, "engineWorld: a world that is gone is nil")
end

do
  -- subsystems and the world point manager: only real, living objects; the first "none" is not believed for long
  local U = fresh()
  local W = engineWorld(U)
  local sub, asked1 = U.subsystem("nonsense", "/Script/G1R.GameTimeSubsystem")
  check(sub == nil and asked1 == false, "subsystem: an unknown kind cannot be asked")
  sub, asked1 = U.subsystem("state", "/Script/G1R.NoSuchClass")
  check(sub == nil and asked1 == false and W.calls.subsystem == 0, "subsystem: a class that is not found cannot be asked for")
  W.answer.subsystem = obj("GameTimeSubsystem /Script/G1R.Default__GameTimeSubsystem")
  sub, asked1 = U.subsystem("state", "/Script/G1R.GameTimeSubsystem")
  check(sub == nil and asked1 == true and W.calls.subsystem == 1, "subsystem: a class default object is not an answer")
  W.answer.subsystem = obj("GameTimeSubsystem /Game/Maps/MainMap.GameTimeSubsystem_0", { __valid = false })
  sub = U.subsystem("state", "/Script/G1R.GameTimeSubsystem")
  check(sub == nil, "subsystem: an object that is gone is not an answer")
  -- "none" is final for 10 s, then the caller may search
  NOW = 1000.0 + 9.99
  sub, asked1 = U.subsystem("state", "/Script/G1R.GameTimeSubsystem")
  check(sub == nil and asked1 == true, "subsystem: a 'none' is believed for 10 s")
  NOW = 1000.0 + 10.0
  sub, asked1 = U.subsystem("state", "/Script/G1R.GameTimeSubsystem")
  check(sub == nil and asked1 == false, "subsystem: after 10 s of 'none' the caller is told to search")
  -- once it has answered, its "none" is final
  local clock = obj("GameTimeSubsystem /Game/Maps/MainMap.GameTimeSubsystem_0")
  W.answer.subsystem = clock
  sub, asked1 = U.subsystem("state", "/Script/G1R.GameTimeSubsystem")
  check(sub == clock and asked1 == true, "subsystem: the object")
  W.answer.subsystem = nil
  NOW = 1000.0 + 500
  sub, asked1 = U.subsystem("state", "/Script/G1R.GameTimeSubsystem")
  NOW = 1000.0 + 520
  local sub2, asked2 = U.subsystem("state", "/Script/G1R.GameTimeSubsystem")
  check(sub == nil and asked1 == true and sub2 == nil and asked2 == true, "subsystem: a way that has answered once is believed when it says 'none', for as long as it does")
  -- a map load: the 'none' of a way that has not answered yet is counted from the load
  local kind, askedK = U.subsystem("instance", "/Script/G1R.PersistentDataSubsystem")
  NOW = 1000.0 + 529
  U.resetCaches()
  NOW = 1000.0 + 531
  kind, askedK = U.subsystem("instance", "/Script/G1R.PersistentDataSubsystem")
  check(kind == nil and askedK == true, "subsystem: after a map load a 'none' is believed for 10 s again")
  NOW = 1000.0

  W.answer.manager = obj("WorldPointManager /Script/G1R.Default__WorldPointManager")
  local m, askedM = U.worldPointManager()
  check(m == nil and askedM == true and W.calls.manager == 1, "worldPointManager: a class default object is not an answer")
  W.answer.manager = obj("WorldPointManager /Game/Maps/MainMap.WorldPointManager_0", { __valid = false })
  check(U.worldPointManager() == nil, "worldPointManager: an object that is gone is not an answer")
  W.answer.manager = obj("WorldPointManager /Game/Maps/MainMap.WorldPointManager_0")
  check(U.worldPointManager() == W.answer.manager, "worldPointManager: the object")

  check(U.paused() == false and W.calls.paused == 1, "paused: the engine's answer")
  W.answer.paused = true
  check(U.paused() == true, "paused: true while the game is paused")
  W.answer.paused = "yes"
  check(U.paused() == nil, "paused: an answer that is not true or false is nil")

  -- the world: the engine's, else the controller's
  local other = obj("World /Game/Other.Other")
  W.answer.controller = obj("PC /Game/Maps/MainMap.PC_0", { GetWorld = function() return other end })
  check(U.world() == W.world, "world: the engine's own world comes first")
end

do
  -- without the engine object nothing can be asked: the callers search as they did before
  local U = fresh()
  local m, askedM = U.worldPointManager()
  check(m == nil and askedM == false, "worldPointManager: without the engine object the caller is told to search")
  local sub, askedS = U.subsystem("state", "/Script/G1R.GameTimeSubsystem")
  check(sub == nil and askedS == false, "subsystem: without the engine object the caller is told to search")
  local world = obj("World /Game/Maps/MainMap.MainMap")
  Answers.all.PlayerController = { obj("GothicPlayerControllerBaseBP_C /Game/Maps/MainMap.PC_0", { GetWorld = function() return world end }) }
  check(U.world() == world, "world: without the engine object it is the controller's world")
  local want = { "/Script/Engine.Default__GameplayStatics", "/Script/G1R.Default__WorldPointManager", "/Script/Engine.Default__SubsystemBlueprintLibrary",
    "/Script/GameStateSubsystem.Default__GameStateSubsystemBlueprintLibrary", "/Script/G1R.GameTimeSubsystem", "/Script/G1R.PersistentDataSubsystem" }
  local same = #U.paths == #want
  for i, path in ipairs(want) do if U.paths[i] ~= path then same = false end end
  check(same, "paths: the six paths this file asks UE4SS for (" .. table.concat(U.paths, ", ") .. ")")
end

do
  -- the player controller, asked from the engine
  local D = diagFake()
  local U = fresh(D)
  local W = engineWorld(U)
  local pc = obj("GothicPlayerControllerBaseBP_C /Game/Maps/MainMap.PC_0", { K2_GetPawn = function() return nil end })
  W.answer.controller = pc
  check(U.controller() == pc and W.calls.controller == 1 and U.controllerName() == "GothicPlayerControllerBaseBP_C /Game/Maps/MainMap.PC_0"
    and D.last("core.controller_by") == "engine", "controller: the engine's answer, noted")
  NOW = 1000.0 + 0.49
  check(U.controller() == pc and W.calls.controller == 1, "controller: not asked again within half a second")
  NOW = 1000.0 + 0.5
  check(U.controller() == pc and W.calls.controller == 2, "controller: asked again after half a second")
  -- in between, the kept one is only used while it is the same object
  rawset(pc, "__full", "Image /Game/UI.Image_7")          -- (another object at its address)
  NOW = 1000.0 + 0.6
  check(U.controller() == nil and W.calls.controller == 2 and U.controllerName() == nil, "controller: a kept one that is another object now is dropped")
  rawset(pc, "__full", "GothicPlayerControllerBaseBP_C /Game/Maps/MainMap.PC_0")
  NOW = 1000.0 + 2
  check(U.controller() == pc, "(found again)")
  rawset(pc, "__valid", false)
  NOW = 1000.0 + 2.1
  check(U.controller() == nil, "controller: a kept one that is gone is dropped")
  rawset(pc, "__valid", nil)
  -- a class default object or an object without a name is not the controller
  NOW = 1000.0 + 10
  W.answer.controller = obj("PlayerController /Script/Engine.Default__PlayerController")
  check(U.controller() == nil, "controller: a class default object is not an answer")
  NOW = 1000.0 + 11
  W.answer.controller = setmetatable({}, { __index = { IsValid = function() return true end, GetFullName = function() return nil end } })
  check(U.controller() == nil, "controller: an object without a name is not an answer")
  -- the pawn: through the function, else the property
  NOW = 1000.0 + 20
  local pawn = obj("BP_Hero_C /Game/Maps/MainMap.Hero")
  W.answer.controller = obj("GothicPlayerControllerBaseBP_C /Game/Maps/MainMap.PC_1", { K2_GetPawn = function() return pawn end })
  check(U.pawn() == pawn, "pawn: what the controller's function hands out")
  NOW = 1000.0 + 21
  W.answer.controller = obj("GothicPlayerControllerBaseBP_C /Game/Maps/MainMap.PC_2", { K2_GetPawn = function() return nil end, Pawn = pawn })
  check(U.pawn() == pawn, "pawn: else the controller's property")
  NOW = 1000.0 + 22
  W.answer.controller = obj("GothicPlayerControllerBaseBP_C /Game/Maps/MainMap.PC_3", { K2_GetPawn = function() return nil end })
  check(U.pawn() == nil and U.playerPos() == nil, "pawn: none - nil, and no position")
  NOW = 1000.0 + 23
  pawn.K2_GetActorLocation = function() return { X = 10, Y = 20, Z = 30 } end
  W.answer.controller = obj("GothicPlayerControllerBaseBP_C /Game/Maps/MainMap.PC_4", { K2_GetPawn = function() return pawn end })
  local x, y, z = U.playerPos()
  check(x == 10 and y == 20 and z == 30, "playerPos: the pawn's place")
  NOW = 1000.0
end

do
  -- the engine never answers with a controller: after 10 s it is searched for, at most every 2 s
  local D = diagFake()
  local U = fresh(D)
  local W = engineWorld(U)
  local real = obj("GothicPlayerControllerBaseBP_C /Game/Maps/MainMap.PC_0")
  local default = obj("GothicPlayerControllerBaseBP_C /Game/Maps.Default__GothicPlayerControllerBaseBP_C")
  check(U.controller() == nil and asked("all", "GothicPlayerControllerBaseBP_C") == 0, "controller: the engine's 'none' is believed at first (main menu, a map is loading)")
  NOW = 1000.0 + 9.49
  check(U.controller() == nil and asked("all", "GothicPlayerControllerBaseBP_C") == 0 and W.calls.controller == 2, "controller: no search before 10 s of 'none'")
  NOW = 1000.0 + 10.0
  check(U.controller() == nil and asked("all", "GothicPlayerControllerBaseBP_C") == 1 and asked("all", "PlayerController") == 1,
    "controller: after 10 s of 'none' it is searched for (both classes)")
  NOW = 1000.0 + 11.5                          -- (a walk would be allowed again: more than a second since the last one)
  check(U.controller() == nil and asked("all", "GothicPlayerControllerBaseBP_C") == 1, "controller: not searched for again within 2 s")
  NOW = 1000.0 + 12.0
  Answers.all.GothicPlayerControllerBaseBP_C = { default }
  check(U.controller() == nil and asked("all", "GothicPlayerControllerBaseBP_C") == 2, "controller: searched for again after 2 s; a class default object is not it")
  NOW = 1000.0 + 14.0
  Answers.all.GothicPlayerControllerBaseBP_C = { real, default }
  check(U.controller() == real and D.last("core.controller_by") == "search (the engine's own way answered nothing)",
    "controller: found by the search, whatever its place in the list; the note says the engine answered nothing")
  NOW = 1000.0
  -- without an engine object: searched for at once, and held back like every walk
  D = diagFake()
  U = fresh(D)
  Answers.all.PlayerController = { default, real }
  U.quiet(5, NOW)
  check(U.controller() == nil and asked("all", "PlayerController") == 0, "controller: no search while walks are held back")
  NOW = 1000.0 + 5
  check(U.controller() == real and D.last("core.controller_by") == "search", "controller: without the engine object it is searched for; the note says 'search'")
  NOW = 1000.0
end

-- ================================================================ 4. the game clock
do
  local function clock(name, seconds)
    return obj(name, { CurrentGameTime = { TotalSeconds = seconds } })
  end
  local D = diagFake()
  local U = fresh(D)
  -- without the engine: searched for; a search that finds none is followed by a pause of 2, 4, 8 ... s
  check(U.gameSeconds() == nil and asked("first", "GameTimeSubsystem") == 1, "clock: searched for when the engine cannot be asked")
  NOW = 1000.0 + 1.99
  check(U.gameSeconds() == nil and asked("first", "GameTimeSubsystem") == 1, "clock: after a search without a clock, none for 2 s")
  NOW = 1000.0 + 2.0
  check(U.gameSeconds() == nil and asked("first", "GameTimeSubsystem") == 2, "clock: the second search after 2 s")
  NOW = 1000.0 + 5.99
  check(U.gameSeconds() == nil and asked("first", "GameTimeSubsystem") == 2, "clock: then none for 4 s")
  NOW = 1000.0 + 6.0
  local c1 = clock("GameTimeSubsystem /Game/Maps/MainMap.GameTimeSubsystem_0", 5000)
  Answers.first.GameTimeSubsystem = c1
  check(U.gameSeconds() == 5000 and asked("first", "GameTimeSubsystem") == 3 and D.last("core.game_time_by") == "search" and D.last("core.game_time_source") == "property",
    "clock: found by the third search; its seconds")
  NOW = 1000.0 + 6.25
  check(U.gameSeconds() == 5000 and asked("first", "GameTimeSubsystem") == 3, "clock: the kept object is used")
  -- another object at its address: dropped and searched for at once (as far as walks are a second apart)
  rawset(c1, "__full", "Image /Game/UI.Image_3")
  c1.CurrentGameTime = { TotalSeconds = 77 }
  local c2 = clock("GameTimeSubsystem /Game/Maps/MainMap.GameTimeSubsystem_1", 6000)
  Answers.first.GameTimeSubsystem = c2
  NOW = 1000.0 + 6.5
  check(U.gameSeconds() == nil and asked("first", "GameTimeSubsystem") == 3, "clock: a kept object that is another object now is not read (and walks are a second apart)")
  NOW = 1000.0 + 7.0
  check(U.gameSeconds() == 6000 and asked("first", "GameTimeSubsystem") == 4, "clock: lost after it was found - searched for again without a pause")
  -- a map load starts the pauses anew
  Answers.first.GameTimeSubsystem = nil
  U.resetTime()
  NOW = 1000.0 + 20
  check(U.gameSeconds() == nil and asked("first", "GameTimeSubsystem") == 5, "(after a map load: searched for, none)")
  NOW = 1000.0 + 21.9
  check(U.gameSeconds() == nil and asked("first", "GameTimeSubsystem") == 5, "(pause of 2 s)")
  NOW = 1000.0 + 22.0
  check(U.gameSeconds() == nil and asked("first", "GameTimeSubsystem") == 6, "clock: after a map load the first pause is 2 s again")
  NOW = 1000.0 + 23.5
  U.resetTime()
  check(U.gameSeconds() == nil and asked("first", "GameTimeSubsystem") == 7, "clock: a map load ends a running pause")
  NOW = 1000.0

  -- the mod on its own (no megamod handle): the three forms are read all the same
  for _, form in ipairs({ { CurrentGameTime = { TotalSeconds = 11 } }, { CurrentGameTime = { get = function() return { TotalSeconds = 11 } end } },
      { GetCurrentGameTime = function() return { TotalSeconds = 11 } end } }) do
    U = fresh()
    Answers.first.GameTimeSubsystem = obj("GameTimeSubsystem /Game/M.C_0", form)
    local ok, t = pcall(U.gameSeconds)
    check(ok and t == 11, "clock: read without the megamod's handle (" .. tostring(t) .. ")")
  end
  -- the three forms the clock's time comes in
  U = fresh(D)
  Answers.first.GameTimeSubsystem = obj("GameTimeSubsystem /Game/M.C_0", { CurrentGameTime = { get = function() return { TotalSeconds = 42 } end } })
  check(U.gameSeconds() == 42 and D.last("core.game_time_source") == "property (wrapped)", "clock: the time behind a wrapper")
  U = fresh(D)
  Answers.first.GameTimeSubsystem = obj("GameTimeSubsystem /Game/M.C_0", { GetCurrentGameTime = function() return { TotalSeconds = 43 } end })
  check(U.gameSeconds() == 43 and D.last("core.game_time_source") == "function", "clock: the time from the function")
  U = fresh(D)
  Answers.first.GameTimeSubsystem = obj("GameTimeSubsystem /Game/M.C_0")
  check(U.gameSeconds() == nil, "clock: no time readable - nil")

  -- with the engine: asked from it; the note says so; no search while its answer counts
  D = diagFake()
  U = fresh(D)
  local W = engineWorld(U)
  W.answer.subsystem = clock("GameTimeSubsystem /Game/Maps/MainMap.GameTimeSubsystem_0", 9000)
  check(U.gameSeconds() == 9000 and asked("first", "GameTimeSubsystem") == 0 and D.last("core.game_time_by") == "engine", "clock: the engine hands it out, nothing is searched")
  rawset(W.answer.subsystem, "__full", "Image /Game/UI.Image_9")      -- (dropped: asked for again, the same way)
  W.answer.subsystem = clock("GameTimeSubsystem /Game/Maps/MainMap.GameTimeSubsystem_1", 9001)
  local byNotes = 0
  check(U.gameSeconds() == 9001, "(the clock is another object: asked for again)")
  for _, n in ipairs(D.notes) do if n.key == "core.game_time_by" then byNotes = byNotes + 1 end end
  check(byNotes == 1, ("notes: how a thing was found is noted when it changes, not every time (%d)"):format(byNotes))
  -- the engine's own way stops answering before it ever... (a fresh run: it never answers)
  D = diagFake()
  U = fresh(D)
  W = engineWorld(U)
  check(U.gameSeconds() == nil and asked("first", "GameTimeSubsystem") == 0, "clock: the engine's 'none' is believed at first")
  NOW = 1000.0 + 10
  Answers.first.GameTimeSubsystem = clock("GameTimeSubsystem /Game/Maps/MainMap.GameTimeSubsystem_0", 9100)
  check(U.gameSeconds() == 9100 and D.last("core.game_time_by") == "search (the engine's own way answered nothing)",
    "clock: after 10 s of 'none' it is searched for, and the note says the engine answered nothing")
  NOW = 1000.0
end

-- ================================================================ 5. the progress file's text
do
  local U = fresh()
  local function back(text) return assert(load(text, "=text", "t", {}))() end
  local t = { version = 1, seen = { Point_A = true, ["Point B"] = true }, chests = { ["IO_X@1,-2"] = { d = 1174481.492, n = 1433681, p = true, r = false } },
    recent = { Point_A = { Wolf = 3 } }, note = "a \"quoted\" text\nwith a line break", [7] = "seven", [8] = { 1.5, 2, "three" } }
  local text = U.serialize(t)
  local r = back(text)
  check(text:sub(1, 7) == "return " and text:sub(-2) == "}\n", "serialize: 'return {...}' and a line break at the end")
  check(r.version == 1 and math.type(r.version) == "integer" and r.seen.Point_A == true and r.seen["Point B"] == true, "serialize: whole numbers, true, names with a blank")
  check(r.chests["IO_X@1,-2"].d == 1174481.492 and r.chests["IO_X@1,-2"].n == 1433681 and r.chests["IO_X@1,-2"].p == true and r.chests["IO_X@1,-2"].r == false,
    "serialize: numbers with three decimals, false")
  check(r.note == t.note and r[7] == "seven" and r[8][1] == 1.5 and r[8][2] == 2 and r[8][3] == "three" and r.recent.Point_A.Wolf == 3,
    "serialize: texts with quotes and line breaks, number keys, lists, tables in tables")
  check(text:find('%["d"%] = 1174481%.492,\n') ~= nil and text:find('%["n"%] = 1433681,\n') ~= nil and text:find("%[7%] = \"seven\",\n") ~= nil,
    "serialize: the written form (%.3f for a fraction, a whole number as it is, a number key without quotes)")
  check(U.serialize(t) == text, "serialize: the same table gives the same text (keys in a fixed order)")
  -- what cannot be written is left out; numbers that are no numbers become 0
  local odd = { f = function() end, co = coroutine.create(function() end), ok = 1, nan = 0 / 0, inf = math.huge, minf = -math.huge }
  r = back(U.serialize(odd))
  local keys = 0
  for _ in pairs(r) do keys = keys + 1 end
  check(keys == 4 and r.ok == 1 and r.nan == 0 and r.inf == 0 and r.minf == 0, "serialize: functions and the like are left out; nan and infinity become 0")
  check(U.serialize("text") == 'return "text"\n' and U.serialize(5) == "return 5\n" and U.serialize(2.5) == "return 2.500\n" and U.serialize(true) == "return true\n"
    and U.serialize(nil) == "return nil\n" and U.serialize(print) == "return nil\n", "serialize: a single value")
  -- a table inside itself, or deeper than 12 levels: written as nil and counted; the text stays readable
  local loop = { a = 1 }
  loop.self, loop.inner = loop, { back = loop }
  local loopText, loopDropped = U.serialize(loop)
  r = back(loopText)
  check(r.a == 1 and r.self == nil and type(r.inner) == 'table' and r.inner.back == nil and loopDropped == 2,
    'serialize: a table inside itself is written as nil and counted (' .. tostring(loopDropped) .. ')')
  local deep = {}
  local cur = deep
  for i = 1, 20 do cur.next = { i = i }; cur = cur.next end
  local deepText, deepDropped = U.serialize(deep)
  local levels, c3 = 0, back(deepText)
  while c3.next do levels = levels + 1; c3 = c3.next end
  check(deepDropped == 1 and levels == 11, 'serialize: deeper than 12 levels is cut there (' .. levels .. ' levels kept, ' .. tostring(deepDropped) .. ' counted)')
  check(select(2, U.serialize({ version = 1, seen = { A = true }, chests = { K = { d = 1 } }, recent = { P = { W = { n = 1, t = 2 } } } })) == 0,
    'serialize: the tables of a progress file: nothing counted')

  -- reading text
  check(U.readText(TMP .. "no-such-file.txt") == nil, "readText: a file that is not there is nil")
  local path = TMP .. "table.lua"
  check(U.writeFile(path, text) == true and U.readText(path) == text, "writeFile / readText: the text comes back")
  local got = U.readTable(path)
  check(type(got) == "table" and got.chests["IO_X@1,-2"].d == 1174481.492, "readTable: the table comes back")
  local f = io.open(TMP .. "broken.lua", "wb"); f:write("return { this is not Lua"); f:close()
  local nothing, why = U.readTable(TMP .. "broken.lua")
  check(nothing == nil and why == "unreadable", "readTable: text that is not Lua is 'unreadable'")
  f = io.open(TMP .. "number.lua", "wb"); f:write("return 5"); f:close()
  nothing, why = U.readTable(TMP .. "number.lua")
  check(nothing == nil and why == "unreadable", "readTable: a file that does not hold a table is 'unreadable'")
  nothing, why = U.readTable(TMP .. "no-such-file.lua")
  check(nothing == nil and why == "missing", "readTable: a file that is not there is 'missing'")
end

io.write(("util tests finished: %d ok, %d failure(s)\n"):format(oks, fails))
os.exit(fails == 0 and 0 or 1)
