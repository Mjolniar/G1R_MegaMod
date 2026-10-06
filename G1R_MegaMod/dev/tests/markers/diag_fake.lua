-- Test helper for a module's diagnostics hooks (megamod SPEC 5.3 and 4):
--   * a recording stand-in for the handle a module sees as G1R_DIAG
--   * a check that a dump is plain data (and survives being written out as Lua)
--   * a small sandbox built the way the loader builds a module's environment
-- The same file sits in dev/tests/repopulate and dev/tests/markers, so that each
-- suite runs on its own. No game, no UE4SS: plain Lua 5.4.
local K = {}

-- A handle that stores what it is given. F.handle goes into G1R_DIAG.
function K.new()
  local F = { notes = {}, count = {}, last = {}, events = {}, crumbs = {}, versions = {}, status = {}, dump = {}, ops = {} }
  F.handle = {
    -- an operation is announced before it runs and taken back when it has returned
    op = function(text)
      F.ops[#F.ops + 1] = { text = text, done = false }
      return #F.ops
    end,
    done = function(token)
      local o = F.ops[token]
      if o then o.done = true end
    end,
    note = function(key, value, detail)
      F.notes[#F.notes + 1] = { key = key, value = value, detail = detail }
      F.count[key] = (F.count[key] or 0) + 1
      F.last[key] = { value = value, detail = detail }
    end,
    event = function(text) F.events[#F.events + 1] = text end,
    crumb = function(text) F.crumbs[#F.crumbs + 1] = text end,
    status = function(fn) F.status[#F.status + 1] = fn end,
    dump = function(fn) F.dump[#F.dump + 1] = fn end,
    version = function(text) F.versions[#F.versions + 1] = text end,
  }
  -- every value a key was noted with, in order
  function F.values(key)
    local out = {}
    for _, n in ipairs(F.notes) do
      if n.key == key then out[#out + 1] = n.value end
    end
    return out
  end
  -- the latest value / detail of a key
  function F.value(key) return F.last[key] and F.last[key].value end
  function F.detail(key) return F.last[key] and F.last[key].detail end
  -- true when a key was never noted twice in a row with the same value and detail
  function F.neverRepeated(key)
    local prev = nil
    for _, n in ipairs(F.notes) do
      if n.key == key then
        if prev and n.value == prev.value and n.detail == prev.detail then return false end
        prev = n
      end
    end
    return true
  end
  -- "key=value" of every note, in order (to compare two runs)
  function F.sequence()
    local out = {}
    for i, n in ipairs(F.notes) do out[i] = tostring(n.key) .. "=" .. tostring(n.value) end
    return out
  end
  -- the operations that were announced and not taken back (in order), and how many texts match a pattern
  function F.openOps()
    local out = {}
    for _, o in ipairs(F.ops) do if not o.done then out[#out + 1] = o.text end end
    return out
  end
  function F.opCount(pattern)
    local n = 0
    for _, o in ipairs(F.ops) do if o.text:find(pattern) then n = n + 1 end end
    return n
  end
  function F.crumbCount(text)
    local n = 0
    for _, c in ipairs(F.crumbs) do if c == text then n = n + 1 end end
    return n
  end
  return F
end

-- Is v plain data? Only strings, numbers (finite), booleans and tables with
-- string / integer keys; no table reached twice (so no cycle and nothing
-- shared); not deeper than maxDepth tables. Returns true, or false and where.
function K.plain(v, maxDepth)
  maxDepth = maxDepth or 6
  local seen = {}
  local function walk(x, path, depth)
    local t = type(x)
    if t == "string" or t == "boolean" then return true end
    if t == "number" then
      if x ~= x or x == math.huge or x == -math.huge then return false, path .. ": not a finite number" end
      return true
    end
    if t ~= "table" then return false, path .. ": a " .. t end
    if seen[x] then return false, path .. ": table reached a second time" end
    seen[x] = true
    if depth > maxDepth then return false, path .. ": deeper than " .. maxDepth .. " tables" end
    if getmetatable(x) ~= nil then return false, path .. ": table with a metatable" end
    for k, val in pairs(x) do
      local kt = type(k)
      if not (kt == "string" or (kt == "number" and math.type(k) == "integer")) then
        return false, path .. ": key of type " .. kt
      end
      local ok, where = walk(val, path .. "." .. tostring(k), depth + 1)
      if not ok then return false, where end
    end
    return true
  end
  return walk(v, "dump", 1)
end

-- Lua source text of a plain value (keys in a fixed order).
function K.serialize(v)
  local out = {}
  local function ser(x, indent)
    local t = type(x)
    if t == "table" then
      local keys = {}
      for k in pairs(x) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b)
        if type(a) ~= type(b) then return type(a) == "number" end
        return a < b
      end)
      out[#out + 1] = "{\n"
      for _, k in ipairs(keys) do
        out[#out + 1] = indent .. "  [" .. (type(k) == "string" and string.format("%q", k) or tostring(k)) .. "] = "
        ser(x[k], indent .. "  ")
        out[#out + 1] = ",\n"
      end
      out[#out + 1] = indent .. "}"
    elseif t == "string" then
      out[#out + 1] = string.format("%q", x)
    elseif t == "number" then
      out[#out + 1] = math.type(x) == "integer" and tostring(x) or string.format("%.17g", x)
    else
      out[#out + 1] = tostring(x)
    end
  end
  ser(v, "")
  return "return " .. table.concat(out) .. "\n"
end

local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
K.same = same

-- Written out as Lua and read back: the same data again?
function K.roundTrip(v)
  local text = K.serialize(v)
  local chunk, err = load(text, "=dump", "t", {})
  if not chunk then return false, err, text end
  local ok, back = pcall(chunk)
  if not ok then return false, back, text end
  return same(v, back), "differs after reading it back", text
end

-- The names in a table (for "nothing new in _G" checks).
function K.keys(t)
  local set = {}
  for k in pairs(t) do set[k] = true end
  return set
end
function K.newKeys(t, before)
  local out = {}
  for k in pairs(t) do
    if not before[k] then out[#out + 1] = tostring(k) end
  end
  table.sort(out)
  return out
end

-- A module environment as SPEC section 4 describes it: standard globals
-- copied in, everything else read through to _G, the module's own files
-- (dofile / loadfile) sharing the environment. `extra` is put in on top
-- (G1R_DIAG, print, a test hook table). Returns the environment and a
-- function that loads and runs a file in it.
K.STANDARD = { "pairs", "ipairs", "next", "select", "type", "tostring", "tonumber", "pcall", "xpcall", "error", "assert",
  "rawget", "rawset", "rawequal", "rawlen", "setmetatable", "getmetatable", "math", "string", "table", "os", "io",
  "coroutine", "utf8", "debug", "load" }
function K.sandbox(extra)
  local env = {}
  for _, name in ipairs(K.STANDARD) do env[name] = _G[name] end
  env._G = env
  env.loadfile = function(path, mode, e)
    if e == nil then e = env end
    return loadfile(path, mode, e)
  end
  env.dofile = function(path)
    local chunk, err = loadfile(path, "bt", env)
    if not chunk then error(err, 2) end
    return chunk()
  end
  for k, v in pairs(extra or {}) do env[k] = v end
  setmetatable(env, { __index = _G })
  local function run(path)
    local chunk, err = loadfile(path, "bt", env)
    if not chunk then return false, err end
    return xpcall(chunk, debug.traceback)
  end
  return env, run
end

return K
