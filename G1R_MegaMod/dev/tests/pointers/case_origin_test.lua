-- Pointer-semantics test (from the independent review of 1.3): chests.lua against a fake API in which
--  (1) an actor's location reads 0,0,0 until its level has been added to the
--      world (components registered), REG seconds after construction, and its
--      container module is created at that moment (as 0x145a42f20 does);
--  (2) a wrapper is a pointer (valid = some wrapped live object at the address).
-- Separate from harness.lua; nothing of the game is run.
local SRC = os.getenv("G1R_REPOP_SRC") or ((debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./") .. "../../../modules/repopulate/Scripts/")
_G.print = function(s) io.write("    LOG ", s) end
local REAL = 1000.0
os.clock = function() return REAL end
local Memory, Wrapped = {}, {}
local W = {}
W.__index = function(self, k)
  if k == "IsValid" then return function(s) return Memory[s.__addr] ~= nil and Wrapped[s.__addr] == true end end
  local o = Memory[self.__addr]
  if o == nil then error("USE AFTER FREE") end
  local v = o[k]
  if type(v) == "function" then return function(_, ...) return v(o, ...) end end
  return v
end
local function wrap(addr) Wrapped[addr] = true; return setmetatable({ __addr = addr }, W) end
local function alloc(addr, o) assert(Memory[addr] == nil); Memory[addr] = o; return o end
local function free(addr) Memory[addr] = nil; Wrapped[addr] = nil end
local function arr(elems) return { ForEach = function(_, fn) for i, e in ipairs(elems) do if fn(i, { get = function() return e end }) == true then break end end end } end
local ItemClass, nextAddr = {}, 5000
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
local Defs = { IO_A_CHEST = { s = true, k = "chest", i = { { "ItFo_Apple", 3 }, { "ItMi_Ore", 20 } } } }
local added = {}
local Saved = nil            -- what the game holds for the chest (the player's looting is "saved" here)
local function spawnChest(x, y, regDelay, base)
  local born = REAL
  local function registered() return REAL >= born + regDelay end
  local cdo = alloc(base + 3, { GetFullName = function() return "IO_A_CHEST /Script/Angelscript.Default__IO_A_CHEST" end, m_Inventory = inventory(Defs.IO_A_CHEST.i) })
  local contents = Saved or { ItFo_Apple = 3, ItMi_Ore = 20 }
  Saved = contents
  local dm = alloc(base + 1, { __items = contents,
    GetFullName = function() return "DataModule_Container /Game/Map.Chest.DM" end,
    m_DefaultInventory = inventory(Defs.IO_A_CHEST.i),
    HasItemMain = function(self, cls, n, out) local c = self.__items[Memory[cls.__addr].__item] or 0; out.hasItemCount = c; return c >= n end,
    Multicast_AddNewItem = function(self, inv, cls, n)
      local name = Memory[cls.__addr].__item
      self.__items[name] = (self.__items[name] or 0) + n
      added[#added + 1] = ("%d x %s at real %.0f"):format(n, name, REAL)
    end })
  alloc(base + 2, { __mods = function() if registered() then return arr({ wrap(base + 1) }) end return arr({}) end })
  Memory[base + 2] = setmetatable({}, { __index = function(_, k) if k == "m_DataModules" then if registered() then return arr({ wrap(base + 1) }) end return arr({}) end end })
  alloc(base, { GetFullName = function() return "InteractiveObjectActor /Game/Map.Chest_A" end,
    GetInteractiveObjectDefinition = function() return wrap(base + 3) end,
    K2_GetActorLocation = function() if registered() then return { X = x, Y = y, Z = 0 } end return { X = 0, Y = 0, Z = 0 } end,
    m_DataModuleComponent = wrap(base + 2) })
  return wrap(base)
end
local function unload(base) for i = 0, 3 do free(base + i) end end
local PlayerPos = { 0, 0, 0 }
alloc(1, { K2_GetPawn = function() return wrap(2) end, GetFullName = function() return "GothicPlayerControllerBaseBP_C /Game/Map.PC" end })
alloc(2, { K2_GetActorLocation = function() return { X = PlayerPos[1], Y = PlayerPos[2], Z = 0 } end })
_G.FindAllOf = function(cls) if cls == "GothicPlayerControllerBaseBP_C" then return { wrap(1) } end return nil end
local libCalls = 0
alloc(9, { GetContainerDataModule = function() libCalls = libCalls + 1; return nil end, GetFullName = function() return "DataModuleLibrary /Script/G1R.Default__DataModuleLibrary" end })
_G.StaticFindObject = function() return wrap(9) end
_G.FindFirstOf = function() return nil end
local U = dofile(SRC .. "util.lua")
local K = dofile(SRC .. "chests.lua")
local State = { chests = {}, seen = {}, recent = {} }
local rolls = { 0.5 }        -- 0.5 < 0.657 (three catch-up rolls at 30 %), > 0.30 (one daily roll)
K.init(U, { RetroactiveDays = 3, Random = function() return 0.5 end }, Defs, State)
local GAME = 86400 * 10
local function run(seconds)
  for _ = 1, math.floor(seconds / 0.25 + 0.5) do
    REAL = REAL + 0.25; GAME = GAME + 0.25 * 15
    local ok, err = pcall(K.tick, GAME, REAL)
    if not ok then io.write("    TICK ERROR: ", tostring(err), "\n") end
  end
end
local function dump(label) io.write(("   %s: records %s | chest holds apples=%d ore=%d\n"):format(label, (U.serialize(State.chests):gsub("%s+", " ")), Saved.ItFo_Apple, Saved.ItMi_Ore)) end
local REG = tonumber(arg and arg[1]) or 5
io.write(("== registration %s s after construction (the mod looks 2 s after construction)\n"):format(REG))
PlayerPos = { 1000, 1000, 0 }                 -- the player stands next to where the chest will be
local A = spawnChest(1200, 1000, REG, 100)    -- full chest, cell streaming in
K.onNewObject(A)
run(20)
dump("after stream-in, chest full")
io.write("== the player takes everything (standing 200 units from the chest), stays 60 s\n")
Saved.ItFo_Apple, Saved.ItMi_Ore = 0, 0
run(60)
dump("60 s after looting")
io.write("== the player walks away; the cell is unloaded and loaded again 120 s later (registered at once this time)\n")
PlayerPos = { 90000, 90000, 0 }
run(30); unload(100); run(120)
local A2 = spawnChest(1200, 1000, 0, 200)
K.onNewObject(A2)
run(30)
dump("30 s after the reload")
for _, a in ipairs(added) do io.write("   ADDED ", a, "\n") end
io.write("   ", K.statusLine(), "\n")
