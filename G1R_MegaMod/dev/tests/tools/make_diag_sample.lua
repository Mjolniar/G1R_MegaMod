-- Writes sample diagnostics with the mod's real recorder (Scripts/core/diag.lua), for the tests of
-- dev/tools/diagread.py:   lua5.4 make_diag_sample.lua <mod folder> <output folder>
-- <output>/a/Scripts/diagnostics : a session with notes, searches, an error, operations, a report and a dump
-- <output>/b/Scripts/diagnostics : a session that ends inside a search (the last line is a breadcrumb, and the
--                                  newest operation was never finished)
-- <output>/c/Scripts/diagnostics : two sessions: the game went down inside an operation, and was started again
local MOD, OUT = arg[1], arg[2]
assert(MOD and OUT, "usage: make_diag_sample.lua <mod folder> <output folder>")

-- a clock of our own: the files get fixed times
local now = os.time({ year = 2026, month = 10, day = 3, hour = 20, min = 15, sec = 0 })
local realTime, realDate = os.time, os.date
os.time = function(t) if t ~= nil then return realTime(t) end return now end
os.date = function(format, t) return realDate(format, t or now) end

local function start(root)
  os.execute('mkdir -p "' .. root .. '/Scripts/diagnostics"')
  local Diag = dofile(MOD .. "/Scripts/core/diag.lua")
  assert(Diag.init(root, { Level = "normal" }, function() end, { name = "G1R_MegaMod", version = "0.1.0" }) == true)
  return Diag
end

-- session a
local D = start(OUT .. "/a")
D.modules[1] = { name = "repopulate", state = "ok" }
D.modules[2] = { name = "markers", state = "ok" }
local R, M = D.handle("repopulate"), D.handle("markers")
R.version("1.3.0-local")
M.version("2.3.0-local")
D.line("repopulate", "[G1R_Repopulate] v1.3.0-local loaded: sample")
D.line("loader", "v0.1.0 loaded: repopulate ok, markers ok")
R.status(function() return { "creatures: 2 cycles", "containers: 3 here" } end)
R.dump(function() return { version = "1.3.0-local", containers = { { kind = "IO_NC_CHEST_01", x = 1.5, y = -2, checked = true } }, classes = { "ItFo_Beer", "ItMi_Nugget" } } end)
M.dump(function() return { version = "2.3.0-local", pins = {}, facts = { { key = "markers.legend", value = "shrunk" } } } end)
R.note("core.profile", 0, "profile_0.lua")
R.note("containers.definition_source", "getter", "IO_NC_CHEST_01")
R.note("containers.data_module_source", "library", "IO_NC_CHEST_01")
R.note("containers.count_form", "yes-no only")
R.note("creatures.spawn_via", "point", "OC_MEATBUG_SPAWN_1")
now = now + 30
R.note("creatures.spawn_via", "library", "OC_WOLF_SPAWN_2")
M.note("markers.map_found_by", "notification")
M.note("markers.self_test.world", "0.3 / 0.1 UI px (raw / corrected, map width 1600)", "box W_Box_1 [registered]")
M.note("markers.unknown_key", "something")
for _, path in ipairs({ "/Script/G1R.Default__DataModuleLibrary", "/Script/Angelscript.SpawnAIAgentDefinition_Wolf" }) do
  D.crumb("repopulate", "lookup " .. path)
  D.lookup("repopulate", path, true, 2.5)
end
D.lookup("repopulate", "/Script/G1R.Default__DataModuleLibrary", true, 0.1)        -- found again: the cache answers
D.crumb("repopulate", "lookup /Script/Angelscript.RoutineX")
D.lookup("repopulate", "/Script/Angelscript.RoutineX", false, 41.0)
D.crumb("repopulate", "lookup /Script/Angelscript.RoutineX")
D.lookup("repopulate", "/Script/Angelscript.RoutineX", false, 39.0)                -- a repeated search
-- operations: one finished, one that raised before it could be taken back, one finished
R.done(R.op("containers: look at new objects (3 waiting)"))
M.op("markers: refresh Map_World")
R.done(R.op("FindAllOf GothicCharacterState"))
D.count("markers", "LoopInGameThreadWithDelay", 55.0, true, "LoopInGameThreadWithDelay 150")
D.error("markers", "LoopInGameThreadWithDelay 150", "main.lua:10: attempt to index a nil value (local 'st')\nstack traceback:\n\tmain.lua:10: in function 'tick'")
now = now + 300
D.tick()
D.report(true)
D.dump()
D.flush()

-- session b: the game goes down inside a search
now = now + 3600
local D2 = start(OUT .. "/b")
D2.modules[1] = { name = "repopulate", state = "ok" }
D2.line("loader", "v0.1.0 loaded: repopulate ok, markers off")
D2.line("repopulate", "[G1R_Repopulate] session started")
D2.flush()
local R2 = D2.handle("repopulate")
R2.done(R2.op("containers: look at new objects (1 waiting)"))
R2.op("search by path /Script/Angelscript.SpawnAIAgentDefinition_Lurker")
D2.crumb("repopulate", "lookup /Script/Angelscript.SpawnAIAgentDefinition_Lurker")

-- folder c: the game goes down inside a search among all objects; twenty minutes later it is started again
now = now + 3600
local D3 = start(OUT .. "/c")
D3.modules[1] = { name = "repopulate", state = "ok" }
D3.line("loader", "v0.1.0 loaded: repopulate ok, markers off")
local R3 = D3.handle("repopulate")
for i = 1, 300 do R3.done(R3.op("creatures: count step " .. i)) end
R3.op("FindAllOf CrimeProcessingSubsystem_Human")
D3.line("repopulate", "[G1R_Repopulate] crime: looking at the rule sets")
D3.flush()
now = now + 1200
local D4 = start(OUT .. "/c")
D4.modules[1] = { name = "repopulate", state = "ok" }
D4.line("loader", "v0.1.0 loaded: repopulate ok, markers off")
local R4 = D4.handle("repopulate")
R4.done(R4.op("containers: look at new objects (2 waiting)"))
now = now + 300
D4.tick()
D4.flush()
print("sample diagnostics written")
