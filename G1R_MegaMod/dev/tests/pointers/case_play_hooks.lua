-- Pointer-semantics test for 1.4: what the mod does with a kept object after
-- the game has taken it out of play, freed it, and another mod's object lives
-- at its address. Fake API as in case_alias_test.lua: a wrapper is a POINTER;
-- IsValid() is true when the address holds a live object that Lua has wrapped,
-- whatever object that is; reading freed memory is an error.
--   lua5.4 case_play_hooks.lua hooks   the game's begin / end of play calls arrive (world.lua follows them)
--   lua5.4 case_play_hooks.lua old     they do not exist (UE4SS's "new object" notification, as before 1.4)
-- Second argument "stale": nothing new is created at the freed addresses, but
-- UE4SS still has the pointers in its set of wrapped objects - the state of
-- the crash of 2026-10-05 12:19 (UE4SS.dll +0x249cc0: IsValid() is "the
-- pointer is in the set, and the object's index, read from its memory, names
-- a reachable entry"; on a freed block that index is whatever lies there). A
-- member access then reads freed memory: in the game an access violation, here
-- counted.
local MODE = arg and arg[1] or "hooks"
local STALE = arg and arg[2] == "stale"
local Crash = { n = 0, members = {} }
local SRC = os.getenv("G1R_REPOP_SRC") or ((debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./") .. "../../../modules/repopulate/Scripts/")
_G.print = function(s) io.write("    LOG ", s) end
local REAL = 1000.0
os.clock = function() return REAL end

local Memory, Wrapped = {}, {}
local Foreign = { asked = 0, read = 0, members = {} }      -- what was asked of / read from objects of another mod
local W = {}
W.__index = function(self, k)
  if k == "GetAddress" then return function(s) return s.__addr end end      -- the wrapper's own pointer: no memory is read
  local o = Memory[self.__addr]
  if k == "IsValid" then
    return function(s)
      if o and o.foreign then Foreign.asked = Foreign.asked + 1 end
      if STALE then return Wrapped[s.__addr] == true end
      return Memory[s.__addr] ~= nil and Wrapped[s.__addr] == true
    end
  end
  if o == nil then
    Crash.n = Crash.n + 1
    Crash.members[k] = (Crash.members[k] or 0) + 1
    error("USE AFTER FREE at " .. tostring(self.__addr) .. " (." .. tostring(k) .. ")")
  end
  if o.foreign then
    Foreign.read = Foreign.read + 1
    Foreign.members[k] = (Foreign.members[k] or 0) + 1
  end
  if k == "IsA" then return function(_, class) return o.__class ~= nil and class ~= nil and o.__class == class.__addr end end
  local v = o[k]
  if type(v) == "function" then return function(_, ...) return v(o, ...) end end
  return v
end
local function wrap(addr) Wrapped[addr] = true; return setmetatable({ __addr = addr }, W) end
local function alloc(addr, o) assert(Memory[addr] == nil, "address in use"); Memory[addr] = o; o.__addr = addr; return o end
local function free(addr) Memory[addr] = nil; Wrapped[addr] = nil end

local function arr(elems) return { ForEach = function(_, fn) for i, e in ipairs(elems) do if fn(i, { get = function() return e end }) == true then break end end end } end
local ItemClass = {}
local nextAddr = 5000
local function itemClass(name)
  if not ItemClass[name] then
    nextAddr = nextAddr + 1
    alloc(nextAddr, { GetFullName = function() return "ASClass /Script/Angelscript." .. name end, __item = name })
    ItemClass[name] = wrap(nextAddr)
  end
  return ItemClass[name]
end
local function inventory(list)
  local slots = {}
  for _, it in ipairs(list) do slots[#slots + 1] = { m_SlotData = { m_ItemDefinition = itemClass(it[1]), m_ItemCount = it[2] } } end
  return { m_Values = { Items = arr({ { m_Slots = arr(slots) } }) } }
end

local IO_CLASS, STATE_CLASS = 7001, 7002
alloc(IO_CLASS, { GetFullName = function() return "Class /Script/G1R.InteractiveObjectActor" end })
alloc(STATE_CLASS, { GetFullName = function() return "Class /Script/G1R.GothicCharacterState" end })
local Defs = { IO_A_CHEST = { s = false, k = "chest", i = { { "ItFo_Apple", 3 }, { "ItMi_Ore", 20 } } } }
local added = {}
local function spawnChest(defName, x, y, items, actorAddr, dmAddr, compAddr, cdoAddr)
  alloc(cdoAddr, { GetFullName = function() return defName .. " /Script/Angelscript.Default__" .. defName end, m_Inventory = inventory(Defs[defName].i) })
  alloc(dmAddr, { __items = items, __owner = defName,
    GetFullName = function() return "DataModule_Container /Game/Map.Chest_" .. defName .. ".DM" end,
    m_DefaultInventory = inventory(Defs[defName].i),
    HasItemMain = function(self, cls, n, out) local c = self.__items[Memory[cls.__addr].__item] or 0; out.hasItemCount = c; return c >= n end,
    Multicast_AddNewItem = function(self, inv, cls, n, payload, predicted)
      local name = Memory[cls.__addr].__item
      self.__items[name] = (self.__items[name] or 0) + n
      added[#added + 1] = ("%d x %s into the chest of %s"):format(n, name, self.__owner)
    end })
  alloc(compAddr, { m_DataModules = arr({ wrap(dmAddr) }) })
  alloc(actorAddr, { __class = IO_CLASS, GetFullName = function() return "Interactive_Chest_C /Game/Map.Chest_" .. defName end,
    GetInteractiveObjectDefinition = function() return wrap(cdoAddr) end,
    K2_GetActorLocation = function() return { X = x, Y = y, Z = 0 } end,
    m_DataModuleComponent = wrap(compAddr) })
  return wrap(actorAddr)
end

local PlayerPos = { 50000, 50000, 0 }
alloc(1, { K2_GetPawn = function() return wrap(2) end, GetFullName = function() return "GothicPlayerControllerBaseBP_C /Game/Map.PC" end })
alloc(2, { K2_GetActorLocation = function() return { X = PlayerPos[1], Y = PlayerPos[2], Z = 0 } end })
_G.FindAllOf = function(cls)
  if cls == "GothicPlayerControllerBaseBP_C" then return { wrap(1) } end
  return nil
end
_G.StaticFindObject = function(path)
  if path == "/Script/G1R.InteractiveObjectActor" then return wrap(IO_CLASS) end
  if path == "/Script/G1R.GothicCharacterState" then return wrap(STATE_CLASS) end
  return setmetatable({ __addr = -1 }, W)
end
_G.FindFirstOf = function() return setmetatable({ __addr = -1 }, W) end
local Hook = {}
if MODE == "hooks" then
  _G.RegisterBeginPlayPostHook = function(f) Hook.began = f end
  _G.RegisterEndPlayPreHook = function(f) Hook.ended = f end
end
local function param(v) return { get = function() return v end } end

local U = dofile(SRC .. "util.lua")
local World = dofile(SRC .. "world.lua")
local K = dofile(SRC .. "chests.lua")
local State = { chests = {}, seen = {}, recent = {} }
World.init(U)
World.listen({ began = K.onBegan, ended = K.onEnded })
World.reset()       -- the map load every game begins with (main.lua's hook): the list of actors in play starts here
K.init(U, { RetroactiveDays = 3, Random = function() return 0.0 end }, Defs, State, World)   -- every roll wins
-- an actor enters / leaves the world the way the mod gets to know of it
local function enters(wrapper)
  if Hook.began then Hook.began(param(wrapper)) else K.onNewObject(wrapper) end
end
local function leaves(addr)
  if Hook.ended then Hook.ended(param(wrap(addr)), param(0)) end
end
local GAME = 86400 * 10
local function run(seconds)
  for _ = 1, math.floor(seconds / 0.25 + 0.5) do
    REAL = REAL + 0.25; GAME = GAME + 0.25 * 15
    local ok, err = pcall(K.tick, GAME, REAL)
    if not ok then io.write("    TICK ERROR: ", tostring(err), "\n") end
  end
end
local function items(addr) local t = {} for k, v in pairs(Memory[addr].__items) do t[#t + 1] = k .. "=" .. v end table.sort(t) return table.concat(t, ", ") end

io.write("== 1. chest A (looted) is in play far from the hero; it is found and wins its roll, the hero stands next to it\n")
enters(spawnChest("IO_A_CHEST", 1000, 1000, { ItFo_Apple = 0, ItMi_Ore = 0 }, 100, 200, 300, 400))
run(4)
PlayerPos = { 1100, 1000, 0 }       -- next to it: the restock waits
run(8)
io.write(("   record of A: %s\n"):format(U.serialize(State.chests):gsub("%s+", " ")))
io.write("== 2. A leaves play and is freed; objects of another mod are created at its addresses and wrapped\n")
leaves(100)
free(100); free(200); free(300); free(400)
for _, addr in ipairs({ 100, 200, 300, 400 }) do
  if STALE then
    Wrapped[addr] = true          -- freed, nothing new there, and the pointer is in UE4SS's set (again)
  else
    alloc(addr, { foreign = true, GetFullName = function() return "Image /Engine/Transient.GameEngine_0:W_Other_C_1.WidgetTree_0.Image_" .. addr end })
    wrap(addr)
  end
end
PlayerPos = { 50000, 50000, 0 }
run(60)
local members = {}
for k, n in pairs(Foreign.members) do members[#members + 1] = k .. " x" .. n end
table.sort(members)
io.write(("   the other mod's objects: asked whether they are valid %d time(s), read %d time(s) (%s)\n"):format(Foreign.asked, Foreign.read, table.concat(members, ", ")))
local freed = {}
for k, n in pairs(Crash.members) do freed[#freed + 1] = k .. " x" .. n end
table.sort(freed)
io.write(("   freed memory was read %d time(s) (%s)\n"):format(Crash.n, table.concat(freed, ", ")))
for _, a in ipairs(added) do io.write("   ADDED EARLY " .. a .. "\n") end
for _, addr in ipairs({ 100, 200, 300, 400 }) do Wrapped[addr] = Memory[addr] ~= nil or nil end
io.write("== 3. A comes into play again, at other addresses\n")
enters(spawnChest("IO_A_CHEST", 1000, 1000, { ItFo_Apple = 0, ItMi_Ore = 0 }, 110, 210, 310, 410))
run(30)
io.write(("   contents of chest A now: %s\n"):format(items(210)))
io.write(("   objects in play as the mod has them: %s\n"):format(World.statusLine()))
io.write("   ", K.statusLine(), "\n")
