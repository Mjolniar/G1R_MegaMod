-- Pointer-semantics test (from the independent review of 1.3): chests.lua against a fake API in which a
-- wrapper is a POINTER, as in UE4SS: IsValid() is true when the address holds a
-- live object that Lua has wrapped (LuaUObject.hpp:761-773), whatever object
-- that is. Property / method access goes to the object that lives at the
-- address now. Separate from harness.lua; nothing of the game is run.
local SRC = os.getenv("G1R_REPOP_SRC") or ((debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./") .. "../../../modules/repopulate/Scripts/")
local logs = {}
_G.print = function(s) logs[#logs + 1] = s; io.write("    LOG ", s) end
local REAL = 1000.0
os.clock = function() return REAL end

local Memory, Wrapped = {}, {}          -- addr -> object ; addr -> true (in UE4SS's set of wrapped live objects)
local W = {}
W.__index = function(self, k)
  if k == "IsValid" then return function(s) return Memory[s.__addr] ~= nil and Wrapped[s.__addr] == true end end
  local o = Memory[self.__addr]
  if o == nil then error("USE AFTER FREE at " .. tostring(self.__addr) .. " (." .. tostring(k) .. ")") end
  local v = o[k]
  if type(v) == "function" then return function(_, ...) return v(o, ...) end end
  return v
end
local function wrap(addr) Wrapped[addr] = true; return setmetatable({ __addr = addr }, W) end
local function alloc(addr, o) assert(Memory[addr] == nil, "address in use"); Memory[addr] = o; o.__addr = addr; return o end
local function free(addr) Memory[addr] = nil; Wrapped[addr] = nil end      -- NotifyUObjectDeleted removes it from the set

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

local Defs = {
  IO_A_CHEST = { s = false, k = "chest", i = { { "ItFo_Apple", 3 }, { "ItMi_Ore", 20 } } },
  IO_B_CHEST = { s = false, k = "chest", i = { { "ItFo_Beer", 2 } } },
}
local added = {}
-- a chest actor at actorAddr with its container module at dmAddr
local function spawnChest(defName, x, y, items, actorAddr, dmAddr, compAddr, cdoAddr)
  local cdo = alloc(cdoAddr, { GetFullName = function() return defName .. " /Script/Angelscript.Default__" .. defName end, m_Inventory = inventory(Defs[defName].i) })
  local dm = alloc(dmAddr, { __items = items, __owner = defName,
    GetFullName = function() return "DataModule_Container /Game/Map.Chest_" .. defName .. ".DM" end,
    m_DefaultInventory = inventory(Defs[defName].i),
    HasItemMain = function(self, cls, n, out) local c = self.__items[Memory[cls.__addr].__item] or 0; out.hasItemCount = c; return c >= n end,
    Multicast_AddNewItem = function(self, inv, cls, n, payload, predicted)
      local name = Memory[cls.__addr].__item
      self.__items[name] = (self.__items[name] or 0) + n
      added[#added + 1] = ("%d x %s into the chest of %s"):format(n, name, self.__owner)
    end })
  local comp = alloc(compAddr, { m_DataModules = arr({ wrap(dmAddr) }) })
  local actor = alloc(actorAddr, { GetFullName = function() return "Interactive_Chest_C /Game/Map.Chest_" .. defName end,
    GetInteractiveObjectDefinition = function() return wrap(cdoAddr) end,
    K2_GetActorLocation = function() return { X = x, Y = y, Z = 0 } end,
    m_DataModuleComponent = wrap(compAddr) })
  return wrap(actorAddr)
end

local PlayerPos = { 0, 0, 0 }
alloc(1, { K2_GetPawn = function() return wrap(2) end, GetFullName = function() return "GothicPlayerControllerBaseBP_C /Game/Map.PC" end })
alloc(2, { K2_GetActorLocation = function() return { X = PlayerPos[1], Y = PlayerPos[2], Z = 0 } end })
_G.FindAllOf = function(cls)
  if cls == "GothicPlayerControllerBaseBP_C" then return { wrap(1) } end
  return nil
end
_G.StaticFindObject = function() return setmetatable({ __addr = -1 }, W) end
_G.FindFirstOf = function() return setmetatable({ __addr = -1 }, W) end

local U = dofile(SRC .. "util.lua")
local K = dofile(SRC .. "chests.lua")
local State = { chests = {}, seen = {}, recent = {} }
K.init(U, { RetroactiveDays = 3, Random = function() return 0.0 end }, Defs, State)   -- every roll wins
local GAME = 86400 * 10
local function run(seconds)
  local steps = math.floor(seconds / 0.25 + 0.5)
  for _ = 1, steps do
    REAL = REAL + 0.25; GAME = GAME + 0.25 * 15
    local ok, err = pcall(K.tick, GAME, REAL)
    if not ok then io.write("    TICK ERROR: ", tostring(err), "\n") end
  end
end
local function items(addr) local t = {} for k, v in pairs(Memory[addr].__items) do t[#t + 1] = k .. "=" .. v end table.sort(t) return table.concat(t, ", ") end

print("== 1. chest A (looted: 0 apples, 0 ore) is loaded far from the player; it is found and gets a record\n")
PlayerPos = { 50000, 50000, 0 }
local A = spawnChest("IO_A_CHEST", 1000, 1000, { ItFo_Apple = 0, ItMi_Ore = 0 }, 100, 200, 300, 400)
K.onNewObject(A)
run(4)        -- tracked after 2 s, first check: missing -> retro record; a roll follows within 5 s
print(("   record of A: %s\n"):format(U.serialize(State.chests):gsub("%s+", " ")))
print("== 2. A is streamed out (its memory is freed) BEFORE the restock; in the same moment chest B is streamed in at the same addresses\n")
free(100); free(200); free(300); free(400)
local B = spawnChest("IO_B_CHEST", 90000, 90000, { ItFo_Beer = 2 }, 100, 200, 300, 400)   -- B is complete (2 beer)
K.onNewObject(B)                                                                       -- the notification wraps B: address 100 is 'valid' again
run(30)
print(("   contents of chest B now: %s\n"):format(items(200)))
print(("   records: %s\n"):format(U.serialize(State.chests):gsub("%s+", " ")))
for _, a in ipairs(added) do print("   ADDED " .. a .. "\n") end
print(K.statusLine() .. "\n")
