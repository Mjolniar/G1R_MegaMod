-- The two places of the mod that write files the player's progress and settings live in:
--   modules/repopulate/Scripts/util.lua   U.writeFile / U.readTable / U.keepBad   (Scripts/state/profile_<id>.lua)
--   Scripts/core/settings.lua             writeText / recover                     (config.lua of a module)
-- Both write "<file>.tmp", read it back, move the file that is there to "<file>.bak" and put the new one in
-- its place. This suite makes every step fail in turn - on real files in a temporary folder, with file
-- functions that behave like Windows (a rename does not overwrite) - and looks at what is on disk afterwards:
-- a complete old or new copy must always be there, and the function must say truthfully what happened.
-- A crash is an error raised from inside a file function: nothing after it runs.
--   lua5.4 test_writer.lua        (last line: writer tests finished: N ok, M failure(s))
local HERE = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./")
local ROOT = HERE .. "../../../"
local TMP = (os.getenv("G1R_TEST_TMP") or "/tmp/g1r-tests") .. "/writer/"
os.execute("rm -rf " .. TMP .. " && mkdir -p " .. TMP)
local oks, fails = 0, 0
local function check(c, msg)
  if c then oks = oks + 1; if os.getenv("SHOWOK") == "1" then io.write("  ok   ", msg, "\n") end
  else fails = fails + 1; io.write("  FAIL ", msg, "\n") end
end

-- ---------------------------------------------------------------- file functions that can fail
local real = { open = io.open, rename = os.rename, remove = os.remove }
local CRASH = {}                 -- raised to end a write where a crash would end it
local Fault, Calls = {}, { rename = 0, open = 0 }
local function exists(path)
  local f = real.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end
local function read(path)
  local f = real.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end
local function write(path, text)
  local f = assert(real.open(path, "wb"))
  f:write(text)
  f:close()
end
io.open = function(path, mode)
  mode = mode or "r"
  if not mode:find("[wa+]") then return real.open(path, mode) end
  Calls.open = Calls.open + 1
  if Fault.open then return nil, path .. ": Permission denied", 13 end
  local f, err, code = real.open(path, mode)
  if not f then return nil, err, code end
  local handle = {}
  function handle:write(text)
    if Fault.write == "nil" then return nil, "No space left on device", 28 end
    if Fault.write == "short" then f:write(text:sub(1, #text // 2)); return self end        -- says yes, wrote half
    if Fault.write == "crash" then f:write(text:sub(1, #text // 2)); f:close(); error(CRASH) end
    f:write(text)
    return self
  end
  function handle:close()
    local ok = f:close()
    if Fault.close then return nil, "Input/output error", 5 end
    return ok
  end
  function handle:setvbuf(...) return f:setvbuf(...) end
  function handle:seek(...) return f:seek(...) end
  function handle:flush() return f:flush() end
  return handle
end
os.rename = function(from, to)
  Calls.rename = Calls.rename + 1
  if Fault.crashAtRename == Calls.rename then error(CRASH) end
  if Fault.renameFails == Calls.rename then return nil, from .. ": Permission denied", 13 end
  if exists(to) then return nil, to .. ": File exists", 17 end       -- Windows: a rename does not overwrite
  return real.rename(from, to)
end
local function fault(t)
  Fault, Calls = t or {}, { rename = 0, open = 0 }
end
-- runs fn; a crash inside ends it. Returns "crash" or what fn returned.
local function attempt(fn, ...)
  local results = table.pack(pcall(fn, ...))
  if not results[1] then
    if results[2] == CRASH then return "crash" end
    error(results[2], 0)
  end
  return table.unpack(results, 2, results.n)
end

-- ---------------------------------------------------------------- the two writers
_G.print = function() end
local U = dofile(ROOT .. "modules/repopulate/Scripts/util.lua")
local Settings = dofile(ROOT .. "Scripts/core/settings.lua")
local OLD = U.serialize({ version = 1, seen = { A = true }, chests = {}, recent = {} })
local NEW = U.serialize({ version = 1, seen = { A = true, B = true }, chests = {}, recent = {} })
local function seenB(t) return type(t) == "table" and type(t.seen) == "table" and t.seen.B == true end
local function usable(text)
  local chunk = load(text, "=file", "t", {})
  return chunk ~= nil and pcall(chunk)
end
local WRITERS = {
  { name = "repopulate util.lua", write = function(path, text) return U.writeFile(path, text) end },
  { name = "core settings.lua", write = function(path, text) return Settings._writeText(path, text) end },
}
local n = 0
local function place()          -- a new file name in the temporary folder
  n = n + 1
  return TMP .. "file" .. n .. ".lua"
end

for _, w in ipairs(WRITERS) do
  local function case(title, setup, faults, expect)
    local path = place()
    if setup ~= false then write(path, OLD) end
    if type(setup) == "function" then setup(path) end
    fault(faults)
    local ok, why = attempt(w.write, path, NEW)
    fault()
    local now, bak, tmp = read(path), read(path .. ".bak"), read(path .. ".tmp")
    local complete = now == OLD or now == NEW or bak == OLD or tmp == NEW
    check(complete, ("%s - %s: a complete old or new copy is on disk"):format(w.name, title))
    expect(ok, why, now, bak, tmp, path)
  end

  -- everything works
  case("first write", false, nil, function(ok, why, now, bak, tmp)
    check(ok == true and now == NEW and bak == nil and tmp == nil, w.name .. " - first write: the file is there, nothing else")
  end)
  case("a file is there", true, nil, function(ok, why, now, bak, tmp)
    check(ok == true and now == NEW and bak == OLD and tmp == nil, w.name .. " - a file is there: replaced, the one before is kept as .bak")
  end)
  case("a .bak of an earlier write is there", function(path) write(path .. ".bak", "older") end, nil, function(ok, why, now, bak)
    check(ok == true and now == NEW and bak == OLD, w.name .. " - an older .bak is replaced by the file before this write")
  end)
  case("a stale .tmp is there", function(path) write(path .. ".tmp", "half of someth") end, nil, function(ok, why, now, bak, tmp)
    check(ok == true and now == NEW and tmp == nil, w.name .. " - a stale .tmp does not get in the way")
  end)

  -- every step fails once
  local function unchanged(title, faults, reason)
    case(title, true, faults, function(ok, why, now, bak, tmp)
      check(ok == false and type(why) == "string" and why:find(reason, 1, true) ~= nil,
        ("%s - %s: the function says no and why (%s)"):format(w.name, title, tostring(why)))
      check(now == OLD and tmp == nil, ("%s - %s: the old file is in its place, no .tmp is left"):format(w.name, title))
    end)
  end
  unchanged("the new file cannot be opened", { open = true }, "cannot open")
  unchanged("writing fails (disk full)", { write = "nil" }, "writing failed")
  unchanged("writing says yes and writes half", { write = "short" }, "does not read back")
  unchanged("closing fails", { close = true }, "closing failed")
  unchanged("the old file cannot be moved aside (in use)", { renameFails = 1 }, "cannot be moved aside")
  unchanged("the new file cannot be put in place", { renameFails = 2 }, "cannot be put in place")

  -- the process dies at each step
  case("crash while the new file is written", true, { write = "crash" }, function(ok, why, now, bak, tmp)
    check(ok == "crash" and now == OLD and tmp ~= nil and tmp ~= NEW, w.name .. " - crash while writing: the old file is untouched (half a .tmp lies next to it)")
  end)
  case("crash before the old file is moved", true, { crashAtRename = 1 }, function(ok, why, now, bak, tmp)
    check(ok == "crash" and now == OLD and tmp == NEW, w.name .. " - crash before the first rename: the old file is untouched")
  end)
  case("crash between the two renames", true, { crashAtRename = 2 }, function(ok, why, now, bak, tmp)
    check(ok == "crash" and now == nil and bak == OLD and tmp == NEW,
      w.name .. " - crash between the renames: the file is missing, the old one is the .bak and the complete new one the .tmp")
  end)
  -- and the next write after any of them works
  for _, faults in ipairs({ { write = "crash" }, { crashAtRename = 1 }, { crashAtRename = 2 } }) do
    local path = place()
    write(path, OLD)
    fault(faults)
    attempt(w.write, path, NEW)
    fault()
    local ok = w.write(path, NEW)
    check(ok == true and read(path) == NEW and read(path .. ".tmp") == nil, w.name .. " - the next write after a crash works and leaves no .tmp")
  end
end

-- ---------------------------------------------------------------- reading the progress file back (repopulate)
do
  local function state(setup)
    local path = place()
    setup(path)
    return path, U.readTable(path)
  end
  local path, t, how = state(function(p) write(p, NEW) end)
  check(seenB(t) and how == nil, "progress file: read as it is")
  path, t, how = state(function() end)
  check(t == nil and how == "missing", "no file: 'missing' (progress starts anew)")
  path, t, how = state(function(p) write(p .. ".bak", OLD) end)
  check(t == nil and how == "missing" and read(path .. ".bak") == OLD, "no file but a .bak (the player removed the file): 'missing' - the copy before is not taken")
  path, t, how = state(function(p) write(p .. ".bak", OLD); write(p .. ".tmp", NEW) end)
  check(seenB(t) and how == "finished" and read(path) == NEW and read(path .. ".tmp") == nil,
    "the state a crash between the two renames leaves: the complete new copy is put in place ('finished')")
  path, t, how = state(function(p) write(p .. ".bak", OLD); write(p .. ".tmp", NEW:sub(1, #NEW // 2)) end)
  check(t == nil and how == "missing", "no file, half a .tmp (a crash while writing, then the file was removed): 'missing'")
  path, t, how = state(function(p) write(p, NEW:sub(1, #NEW // 2)); write(p .. ".bak", OLD) end)
  check(type(t) == "table" and not seenB(t) and how == "backup", "a file that cannot be read, with a .bak: the copy of the write before it ('backup')")
  check(U.keepBad(path) == true and read(path .. ".bad") == NEW:sub(1, #NEW // 2) and read(path) == nil, "keepBad: the unreadable file is kept as .bad")
  check(U.writeFile(path, NEW) == true and read(path) == NEW and read(path .. ".bak") == OLD, "the next write puts the new file in place and leaves the good .bak alone")
  write(path, "garbage again")
  check(U.keepBad(path) == false and read(path .. ".bad") == NEW:sub(1, #NEW // 2) and read(path) == nil, "keepBad a second time: the first .bad stays, the unreadable file is removed")
  path, t, how = state(function(p) write(p, "return 5") end)
  check(t == nil and how == "unreadable", "a file that is not a table and no .bak: 'unreadable'")
  path, t, how = state(function(p) write(p, "this is not Lua") ; write(p .. ".bak", "nor is this") end)
  check(t == nil and how == "unreadable", "file and .bak both unreadable: 'unreadable'")
  -- a file that names something outside (it is run with no access to anything)
  path, t, how = state(function(p) write(p, "os.remove('" .. TMP .. "file1.lua') return { seen = {} }") end)
  check(t == nil and how == "unreadable" and read(TMP .. "file1.lua") ~= nil, "a progress file runs with no access to anything: one that calls a function is 'unreadable'")
end

-- ---------------------------------------------------------------- the settings writer: another program in between, a cut-off write
do
  local path = place()
  write(path, OLD)
  local ok, why = Settings._writeText(path, NEW, OLD)
  check(ok == true and read(path) == NEW, "settings: the file still holds what the new text was made from - written")
  write(path, OLD)
  ok, why = Settings._writeText(path, NEW, "something else")
  check(ok == false and why == "changed" and read(path) == OLD and read(path .. ".tmp") == nil, "settings: the file was changed in between - not written, reason 'changed'")
  ok, why = Settings._writeText(path, NEW, false)
  check(ok == false and why == "changed" and read(path) == OLD, "settings: a file appeared where there was none - not written")
  local fresh = place()
  ok = Settings._writeText(fresh, NEW, false)
  check(ok == true and read(fresh) == NEW, "settings: no file expected, none there - written")
  -- recover
  local cut = place()
  write(cut .. ".tmp", NEW); write(cut .. ".bak", OLD)
  check(Settings._recover(cut, usable) == NEW and read(cut) == NEW and read(cut .. ".tmp") == nil, "settings: a write cut off between its renames is finished at the next start")
  local half = place()
  write(half .. ".tmp", "local Config = {")
  check(Settings._recover(half, usable) == nil and read(half) == nil, "settings: half a .tmp is not taken for a file")
  local there = place()
  write(there, OLD); write(there .. ".tmp", NEW)
  check(Settings._recover(there, usable) == nil and read(there) == OLD, "settings: a file that is there is not replaced by a .tmp lying next to it")
end

-- ---------------------------------------------------------------- settings objects on top of it
do
  local SCHEMA = { Module = "alpha", Page = "Test", Groups = { { Title = "Group", Items = {
    { Key = "Amount", Kind = "number", Default = 2.5, Min = 0, Max = 10, Decimals = 1, Label = "Amount" },
    { Key = "On", Kind = "bool", Default = true, Label = "On" } } } } }
  local logs = {}
  local function open(dir)
    return Settings.open({ module = "alpha", dir = dir, schema = SCHEMA, log = function(text) logs[#logs + 1] = text end, menu = false })
  end
  local function logged(text) local c = 0 for _, l in ipairs(logs) do if l:find(text, 1, true) then c = c + 1 end end return c end
  local dir = TMP .. "alpha/"
  os.execute("mkdir -p " .. dir)
  local o = open(dir)
  local default = read(dir .. "config.lua")
  check(o ~= nil and default ~= nil and read(dir .. "config.lua.bak") == nil, "settings object: no config.lua - the default one is written (no .bak)")
  check(o:set("Amount", 7.5) and read(dir .. "config.lua"):find("Config.Amount = 7.5", 1, true) ~= nil and read(dir .. "config.lua.bak") == default,
    "a changed value: the line is rewritten, the file before is kept as config.lua.bak")
  -- the write fails: said once per change, the value holds, the file is as it was
  local before = read(dir .. "config.lua")
  fault({ write = "nil" })
  o:set("Amount", 8)
  fault()
  check(o.values.Amount == 8 and read(dir .. "config.lua") == before and logged("config.lua could not be written (writing failed") == 1,
    "the write fails: the value holds for this run, the file is untouched, the log says why")
  -- the settings app saves between the mod's reading and writing: the mod's line goes into the app's file
  local appText = before:gsub("Config.On = true", "Config.On = false")
  local realRead = Settings._readText
  o:set("Amount", 7.5)                                   -- (file and object agree again)
  local base = read(dir .. "config.lua")
  local swapped = false
  local openReal = io.open
  io.open = function(path, mode)
    -- the first write of config.lua.tmp is the moment "between": the app's save lands just before it
    if not swapped and path == dir .. "config.lua.tmp" then
      swapped = true
      write(dir .. "config.lua", (base:gsub("Config.On = true", "Config.On = false")))
    end
    return openReal(path, mode)
  end
  o:set("Amount", 9)
  io.open = openReal
  local final = read(dir .. "config.lua")
  check(swapped and final:find("Config.Amount = 9.0", 1, true) ~= nil and final:find("Config.On = false", 1, true) ~= nil,
    "the settings app saved in between: its change and the mod's are both in the file")
  -- a broken file is replaced by a complete one, and kept
  write(dir .. "config.lua", "broken (\n")
  o:set("Amount", 3)
  check(read(dir .. "config.lua"):find("Config.Amount = 3.0", 1, true) ~= nil and read(dir .. "config.lua.bak") == "broken (\n",
    "a config.lua that cannot be read is replaced by a complete one and kept as config.lua.bak")
  -- a cut-off write is finished when the settings are opened
  local dir2 = TMP .. "beta/"
  os.execute("mkdir -p " .. dir2)
  write(dir2 .. "config.lua.tmp", (default:gsub("Config.Amount = 2.5", "Config.Amount = 6.0")))
  write(dir2 .. "config.lua.bak", default)
  local o2 = open(dir2)
  check(o2 ~= nil and o2.values.Amount == 6 and read(dir2 .. "config.lua.tmp") == nil and logged("the last write of config.lua had been cut off") == 1,
    "open: a write that was cut off between its renames is finished, and its values are used")
end

io.write(("writer tests finished: %d ok, %d failure(s)\n"):format(oks, fails))
os.exit(fails == 0 and 0 or 1)
