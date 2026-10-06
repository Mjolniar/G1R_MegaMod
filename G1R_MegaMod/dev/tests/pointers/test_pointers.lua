-- Runs the pointer-semantics tests of the container module and checks their output.
-- These tests use a fake API in which an object wrapper is a pointer, as in UE4SS:
-- IsValid() is true when the address holds a live object that Lua has wrapped, whatever
-- object that is, and freed addresses are handed out again. harness.lua does not model that.
-- Each case_*.lua is a small program of its own (a fake API with real pointer behaviour, the real util.lua and
-- chests.lua of the repopulate module, one situation); this file runs them and reads what they print.
-- Usage: lua5.4 test_pointers.lua      (last line: pointer tests finished: N ok, M failure(s))
local HERE = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./")
local LUA = os.getenv("G1R_LUA") or arg[-1] or "lua5.4"
local oks, fails = 0, 0
local function check(c, msg)
  if c then oks = oks + 1; io.write("  ok   ", msg, "\n") else fails = fails + 1; io.write("  FAIL ", msg, "\n") end
end
-- the module under test: G1R_REPOP_SRC, or found from this file's place
local SRC = os.getenv("G1R_REPOP_SRC")
if not SRC then
  for _, rel in ipairs({ "../../../modules/repopulate/Scripts/" }) do
    local f = io.open(HERE .. rel .. "chests.lua", "r")
    if f then f:close(); SRC = HERE .. rel; break end
  end
end
assert(SRC, "module sources not found; set G1R_REPOP_SRC")
local function run(script, args)
  local p = io.popen(('G1R_REPOP_SRC="%s" "%s" "%s%s" %s 2>&1'):format(SRC, LUA, HERE, script, args or ""))
  local out = p:read("a")
  p:close()
  return out
end

-- 1. containers streaming in and out with address reuse: nothing lands in a wrong container
for seed = 1, 8 do
  local out = run("case_stream_test.lua", "reuse " .. seed)
  local opened, anomalies = out:match("(%d+) chest openings"), out:match("anomalies (%d+)")
  check(anomalies == "0" and out:find("use%-after%-free errors 0") and not out:find("TICK ERROR") and tonumber(opened or 0) > 5,
    ("streaming with address reuse, seed %d: no item in a wrong container (%s)"):format(seed, (out:match("^[^\n]*") or "?")))
end
do
  local out = run("case_stream_test.lua", "fresh 1")
  check(out:match("anomalies (%d+)") == "0" and not out:find("TICK ERROR"), "streaming without address reuse: " .. (out:match("^[^\n]*") or "?"))
end

-- 2. a tracked container is unloaded and another one gets its address before the restock
do
  local out = run("case_alias_test.lua")
  check(out:find("contents of chest B now: ItFo_Beer=2", 1, true) and not out:find("ADDED", 1, true),
    "another container at the address of an unloaded one is not given its items")
  check(out:find('%["IO_A_CHEST@10,10"%] = {[^}]*%["p"%] = true') ~= nil, "the unloaded container keeps its won roll for when it is loaded again")
end

-- 3. the address of an unloaded container is taken by an object that is not an actor
do
  local out = run("case_alias_nonactor.lua")
  local n = tonumber(out:match("was handed%s+InteractiveObjectActor[^\n]-(%d+) time") or "0")
  check(out:find("containers: ", 1, true) and not out:find("was handed%s+Image") and n >= 1 and n <= 6,
    ("the game's module function is never handed a foreign object, and the real one only a few times (%d)"):format(n))
end

-- 4. a container that is looked at before the game has placed it
do
  local out = run("case_origin_test.lua")
  check(not out:find("@0,0", 1, true) and out:find('60 s after looting: records return { %["IO_A_CHEST@12,10"%]') ~= nil,
    "not registered under the world origin; the looting is noticed under its real position")
  check(out:find("containers: ", 1, true) and not out:find("ADDED", 1, true) and not out:find("restocked IO_A_CHEST", 1, true),
    "and it is not restocked minutes after it was looted")
  out = run("case_origin_test2.lua")
  check(out:find('60 s after looting: records return { %["IO_A_CHEST@512,510"%]') ~= nil and not out:find("ADDED", 1, true),
    "same far from the origin")
end

-- 5. an announced object is replaced before the mod has looked at it for the first time (review of 2026-10-05)
for _, kind in ipairs({ "foreign", "other_chest" }) do
  for _, clock in ipairs({ "moving", "paused" }) do
    local out = run("case_pending_alias.lua", kind .. " " .. clock)
    check(out:match("definition asked of the newcomer (%d+) time") == "0" and not out:find("TICK ERROR", 1, true),
      ("replaced before the first look (%s, game clock %s): the newcomer is not asked for a definition"):format(kind, clock))
  end
end

-- 6. objects that leave play (1.4): with the game's begin / end of play calls nothing of them is touched again
do
  local function numbers(out)
    local asked, read = out:match("asked whether they are valid (%d+) time%(s%), read (%d+) time")
    return tonumber(asked), tonumber(read), tonumber(out:match("freed memory was read (%d+) time")), out:find("contents of chest A now: ItFo_Apple=3, ItMi_Ore=20", 1, true) ~= nil
  end
  local asked, read, freed, restocked = numbers(run("case_play_hooks.lua", "hooks"))
  check(asked == 0 and read == 0 and freed == 0 and restocked,
    ("play calls, another mod's objects at the freed addresses: not asked, not read (%s / %s); the container is restocked when it is in play again"):format(tostring(asked), tostring(read)))
  asked, read, freed, restocked = numbers(run("case_play_hooks.lua", "hooks stale"))
  check(asked == 0 and read == 0 and freed == 0 and restocked,
    ("play calls, freed addresses that UE4SS still lists: freed memory is not read (%s reads)"):format(tostring(freed)))
  -- the way before 1.4, for comparison: it asks the newcomer its name - and reads freed memory in the second case
  asked, read, freed, restocked = numbers(run("case_play_hooks.lua", "old"))
  check(asked ~= nil and asked > 0 and read ~= nil and read > 0 and freed == 0 and restocked,
    ("(without the calls the newcomers are asked whether they are valid and for their names: %s / %s - nothing is put into them)"):format(tostring(asked), tostring(read)))
  local out = run("case_play_hooks.lua", "old stale")
  asked, read, freed, restocked = numbers(out)
  check(freed ~= nil and freed > 0 and not out:find("ADDED EARLY", 1, true),
    ("(without the calls, freed addresses that UE4SS still lists: freed memory IS read, %s time(s) - the crash of 2026-10-05 12:19; the calls are what prevents it)"):format(tostring(freed)))
end

-- 7. the helpers of util.lua: an object that cannot say it is valid is not used (review of 2026-10-05)
do
  local U = dofile(SRC .. "util.lua")
  for _, state in ipairs({ "throws", "false", "missing" }) do
    local lookups = 0
    local o = setmetatable({}, { __index = function(_, k)
      if k == "IsValid" then
        if state == "throws" then return function() error("invalid receiver") end end
        if state == "false" then return function() return false end end
        return nil
      end
      lookups = lookups + 1
      return function() return "unsafe" end
    end })
    U.call(o, "Danger"); U.try(o, "Danger"); U.fullName(o); U.classToken(o); U.objectToken(o)
    check(lookups == 0, ("IsValid %s: no member is looked up through call / try / fullName (%d lookups)"):format(state, lookups))
  end
  check(U.get({ TotalSeconds = 123 }, "TotalSeconds") == 123, "a plain struct value (no IsValid) is still read")
  local echo = { IsValid = function() return true end, Echo = function(self, ...) return select("#", ...), (select(3, ...)) end }
  local ok, n, last = U.try(echo, "Echo", 1, nil, 3)
  check(ok and n == 3 and last == 3 and U.call(echo, "Echo", 1, nil, 3) == 3, "valid objects are called with every argument, nil ones included")
  local gone = { IsValid = function() return false end, Value = 5 }
  check(U.get(gone, "Value") == nil and U.gone(gone) == true and U.gone({}) == false, "get: nothing is read from an object that says it is gone")
  local reads = 0
  local raising = setmetatable({}, { __index = function(_, k)
    if k == "IsValid" then return function() error("invalid receiver") end end
    reads = reads + 1
    return 7
  end })
  check(U.gone(raising) == true and U.get(raising, "Value") == nil and reads == 0, "get: an object whose IsValid raises is taken as gone - nothing of it is read")
  local opaque = setmetatable({}, { __index = function() error("unreadable") end })
  check(U.gone(opaque) == true and U.get(opaque, "Value") == nil, "get: an object whose methods cannot even be looked up is taken as gone")
  check(U.address({ GetAddress = function() return 4711 end }) == 4711 and U.address(nil) == nil and U.address({}) == nil, "address: the wrapper's own pointer, or nil")
end

-- 8. counting what is in a container: a failed call is "unknown", never a made-up lower count (review of 2026-10-05)
do
  local function count(mode)
    local U = dofile(SRC .. "util.lua")
    local K = dofile(SRC .. "chests.lua")
    K.init(U, {}, {}, { chests = {}, seen = {}, recent = {} })
    local calls = 0
    local cls = { IsValid = function() return mode ~= "invalid_class" end }
    local dm = { IsValid = function() if mode == "invalid_receiver" then error("invalid receiver") end return true end }
    dm.HasItemMain = function(self, c, n, out)
      calls = calls + 1
      if mode == "fallback_failure" and calls > 1 then error("lost receiver during fallback") end
      if mode == "healthy_count" then out.hasItemCount = 3 end
      return n <= 3
    end
    return K._countOne(dm, cls, 8), calls
  end
  local got, calls = count("invalid_receiver")
  check(got == nil and calls == 0, "counting: the module cannot say it is valid - unknown, the game is not called")
  got, calls = count("invalid_class")
  check(got == nil and calls == 0, "counting: the item class is gone - unknown, the game is not called")
  got = count("fallback_failure")
  check(got == nil, "counting: a call fails while counting down - unknown, not a lower count")
  check((count("healthy_count")) == 3 and (count("healthy_fallback")) == 3, "counting: 3 of 8 by the count the game hands out, and by asking 'at least n?'")
end

-- 9. a long queue of objects that are not due yet: 25 looked at per update, and the due one at its end is reached
for _, n in ipairs({ 100, 1000, 10000 }) do
  local K = dofile(SRC .. "chests.lua")
  local dueLookups = 0
  local U2 = { fullName = function(o) return o.name end, valid = function(o) return o ~= nil end, findAll = function() return {} end,
    get = function() return nil end, mayWalk = function() return true end, op = function() end, done = function() end,
    call = function(o, k) if k == "GetInteractiveObjectDefinition" then dueLookups = dueLookups + 1 end end }
  K.init(U2, {}, {}, { chests = {}, seen = {}, recent = {} })
  local saved = os.clock
  os.clock = function() return 1000 end
  for i = 1, n do K.onNewObject({ name = "InteractiveObjectActor /Game/Chest_" .. i }) end
  os.clock = saved
  local queue
  for i = 1, 100 do
    local name, value = debug.getupvalue(K.tick, i)
    if name == "PendingActors" then queue = value; break end
    if name == nil then break end
  end
  local inspected = 0
  if queue then
    for i, p in ipairs(queue) do
      local due = (i == n) and 990 or 1e9          -- only the last one is due
      p.due = nil
      setmetatable(p, { __index = function(_, k) if k == "due" then inspected = inspected + 1; return due end end })
    end
    K.tick(0, 1000)
  end
  local first = inspected
  for _ = 2, math.ceil(n / 25) + 1 do K.tick(0, 1000) end
  check(queue ~= nil and #queue >= n - 1 and first == 25, ("%d waiting objects: 25 are looked at in one update (%d)"):format(n, first))
  check(dueLookups > 0, ("%d waiting objects: the one that is due, at the end of the queue, is reached"):format(n))
end

io.write(("pointer tests finished: %d ok, %d failure(s)\n"):format(oks, fails))
os.exit(fails == 0 and 0 or 1)
