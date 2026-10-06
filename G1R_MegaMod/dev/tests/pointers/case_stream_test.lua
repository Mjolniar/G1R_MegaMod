-- Pointer-semantics test (from the independent review of 1.3): chests.lua under streaming with a pointer-style fake API.
-- mode "reuse": freed actor / module addresses are handed out again (LIFO), as a binned allocator does
-- mode "fresh": every object gets a new address (what the coordinator's harness models)
local MODE = arg[1] or "reuse"
local SEED = tonumber(arg[2] or "1")
local SRC = os.getenv("G1R_REPOP_SRC") or ((debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./") .. "../../../modules/repopulate/Scripts/")
local logs = {}
_G.print = function(s) logs[#logs + 1] = s end
local REAL = 1000.0
os.clock = function() return REAL end
local Memory, Wrapped = {}, {}
local uaf = 0
local W = {}
W.__index = function(self, k)
  if k == "IsValid" then return function(s) return Memory[s.__addr] ~= nil and Wrapped[s.__addr] == true end end
  local o = Memory[self.__addr]
  if o == nil then uaf = uaf + 1; error("USE AFTER FREE (." .. tostring(k) .. ")") end
  local v = o[k]
  if type(v) == "function" then return function(_, ...) return v(o, ...) end end
  return v
end
local function wrap(addr) Wrapped[addr] = true; return setmetatable({ __addr = addr }, W) end
local nextAddr, freeActor, freeDm = 10000, {}, {}
local function newAddr(pool)
  if MODE == "reuse" and #pool > 0 then return table.remove(pool) end
  nextAddr = nextAddr + 1
  return nextAddr
end
local function arr(elems) return { ForEach = function(_, fn) for i, e in ipairs(elems) do if fn(i, { get = function() return e end }) == true then break end end end } end
local ItemClass = {}
local function itemClass(name)
  if not ItemClass[name] then
    nextAddr = nextAddr + 1
    Memory[nextAddr] = { GetFullName = function() return "ASClass /Script/Angelscript." .. name end, __item = name }
    ItemClass[name] = wrap(nextAddr)
  end
  return ItemClass[name]
end
local function inventory(list)
  local slots = {}
  for _, it in ipairs(list) do slots[#slots + 1] = { m_SlotData = { m_ItemDefinition = itemClass(it[1]), m_ItemCount = it[2] } } end
  return { m_Values = { Items = arr({ { m_Slots = arr(slots) } }) } }
end
local NCHEST = 40
local Defs, Chests = {}, {}
for i = 1, NCHEST do
  local name = ("IO_T_CHEST_%02d"):format(i)
  Defs[name] = { s = (i % 2 == 0), k = "chest", i = { { ("ItT_%02d_A"):format(i), 3 }, { ("ItT_%02d_B"):format(i), 5 }, { "ItMi_Ore", 10 } } }
  Chests[i] = { name = name, x = (i % 8) * 6000, y = math.floor(i / 8) * 6000, saved = nil, live = nil, loaded = false }
end
local anomalies = {}
local function anomaly(s) anomalies[#anomalies + 1] = s end
local function defaultsOf(c) local t = {} for _, it in ipairs(Defs[c.name].i) do t[it[1]] = it[2] end return t end
local function copy(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
local K, U
local function streamIn(c)
  c.live = copy(c.saved or defaultsOf(c))
  c.actorAddr, c.dmAddr = newAddr(freeActor), newAddr(freeDm)
  local def = Defs[c.name]
  nextAddr = nextAddr + 1; local cdoAddr = nextAddr
  Memory[cdoAddr] = { GetFullName = function() return c.name .. " /Script/Angelscript.Default__" .. c.name end, m_Inventory = inventory(def.i) }
  Wrapped[cdoAddr] = true
  local dmWrap
  Memory[c.dmAddr] = { GetFullName = function() return "DataModule_Container /Game/Map.Chest_" .. c.name .. ".DM" end,
    m_DefaultInventory = inventory(def.i),
    HasItemMain = function(self, cls, n, out) local cnt = c.live[Memory[cls.__addr].__item] or 0; out.hasItemCount = cnt; return cnt >= n end,
    Multicast_AddNewItem = function(self, inv, cls, n, payload, predicted)
      local item = Memory[cls.__addr].__item
      local want = defaultsOf(c)[item]
      if not want then anomaly(("t=%.0f: %d x %s added to %s, which never holds that item"):format(REAL, n, item, c.name)) end
      c.live[item] = (c.live[item] or 0) + n
      if want and c.live[item] > want then anomaly(("t=%.0f: %s in %s above its default (%d > %d)"):format(REAL, item, c.name, c.live[item], want)) end
      c.addedSinceOpen = true
    end }
  nextAddr = nextAddr + 1; local compAddr = nextAddr
  Memory[compAddr] = { m_DataModules = arr({ wrap(c.dmAddr) }) }
  Memory[c.actorAddr] = { GetFullName = function() return "Interactive_Chest_C /Game/Map.Chest_" .. c.name end,
    GetInteractiveObjectDefinition = function() return wrap(cdoAddr) end,
    K2_GetActorLocation = function() return { X = c.x, Y = c.y, Z = 0 } end,
    m_DataModuleComponent = wrap(compAddr) }
  c.loaded = true
  K.onNewObject(wrap(c.actorAddr))            -- NotifyOnNewObject wraps the new actor
end
local function streamOut(c)
  Memory[c.actorAddr], Wrapped[c.actorAddr] = nil, nil
  Memory[c.dmAddr], Wrapped[c.dmAddr] = nil, nil
  freeActor[#freeActor + 1] = c.actorAddr
  freeDm[#freeDm + 1] = c.dmAddr
  c.loaded, c.live = false, nil
end
local PlayerPos = { 0, 0, 0 }
Memory[1] = { K2_GetPawn = function() return wrap(2) end, GetFullName = function() return "GothicPlayerControllerBaseBP_C /Game/Map.PC" end }
Memory[2] = { K2_GetActorLocation = function() return { X = PlayerPos[1], Y = PlayerPos[2], Z = 0 } end }
_G.FindAllOf = function(cls) if cls == "GothicPlayerControllerBaseBP_C" then return { wrap(1) } end return nil end
_G.StaticFindObject = function() return setmetatable({ __addr = -1 }, W) end
_G.FindFirstOf = function() return setmetatable({ __addr = -1 }, W) end
U = dofile(SRC .. "util.lua")
K = dofile(SRC .. "chests.lua")
local State = { chests = {}, seen = {}, recent = {} }
math.randomseed(SEED)
K.init(U, { RetroactiveDays = 3 }, Defs, State)
local GAME = 86400 * 10
local tickErrors = {}
local function tick()
  REAL = REAL + 0.25; GAME = GAME + 0.25 * 15
  local ok, err = pcall(K.tick, GAME, REAL)
  if not ok then tickErrors[tostring(err):gsub("^.-:%d+: ", "")] = true end
end
-- the player walks between "cells" of 8 chests; cells near the player are loaded
local function cellOf(i) return math.floor((i - 1) / 8) end
local cur = 0
local opened, restockSeen = 0, 0
for step = 1, 4000 do
  if step % 240 == 1 then          -- every minute: move to another cell; load it and a neighbour, unload the rest
    cur = math.random(0, 4)
    local nb = (cur + 1) % 5
    for i, c in ipairs(Chests) do
      local want = cellOf(i) == cur or cellOf(i) == nb
      if c.loaded and not want then streamOut(c) end
    end
    for i, c in ipairs(Chests) do
      local want = cellOf(i) == cur or cellOf(i) == nb
      if not c.loaded and want then streamIn(c) end
    end
    local c0 = Chests[cur * 8 + 1]
    PlayerPos = { c0.x + 3000, c0.y + 3000, 0 }
    GAME = GAME + 86400 * 0.5          -- and half a day passes (sleep)
  end
  if step % 240 == 121 then        -- now and then the player opens a chest in the current cell and takes everything
    local i = cur * 8 + math.random(1, 8)
    local c = Chests[i]
    if c.loaded then
      PlayerPos = { c.x + 50, c.y, 0 }
      for k in pairs(c.live) do c.live[k] = 0 end
      c.saved = copy(c.live); c.addedSinceOpen = false
      opened = opened + 1
    end
  end
  if step % 240 == 141 then local c0 = Chests[cur * 8 + 1]; PlayerPos = { c0.x + 3000, c0.y + 3000, 0 } end
  tick()
end
local restocked = 0
for _, l in ipairs(logs) do if l:find("restocked IO_", 1, true) then restocked = restocked + 1 end end
io.write(("mode=%s seed=%d: %d chest openings, %d 'restocked' log lines, use-after-free errors %d, anomalies %d\n"):format(MODE, SEED, opened, restocked, uaf, #anomalies))
for i = 1, math.min(6, #anomalies) do io.write("   ", anomalies[i], "\n") end
for e in pairs(tickErrors) do io.write("   TICK ERROR: ", e, "\n") end
io.write("   ", K.statusLine(), "\n")
