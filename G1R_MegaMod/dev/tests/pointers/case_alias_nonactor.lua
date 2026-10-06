-- Pointer-semantics test (from the independent review of 1.3): what chests.lua hands to the game's
-- GetContainerDataModule when the address of an unloaded, tracked container is
-- taken over by a Lua-wrapped object that is not an actor. Fake API as in
-- alias_test.lua (a wrapper is a pointer; valid = wrapped live object there).
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
  if v == nil then return setmetatable({}, { __index = function(_, kk) if kk == "IsValid" then return function() return false end end return nil end }) end  -- UE4SS: invalid object, not nil
  return v
end
local function wrap(addr) Wrapped[addr] = true; return setmetatable({ __addr = addr }, W) end
local function alloc(addr, o) assert(Memory[addr] == nil); Memory[addr] = o; return o end
local function free(addr) Memory[addr] = nil; Wrapped[addr] = nil end
local function arr(elems) return { ForEach = function(_, fn) for i, e in ipairs(elems) do if fn(i, { get = function() return e end }) == true then break end end end } end
local Defs = { IO_A_CHEST = { s = true, k = "chest", i = { { "ItFo_Apple", 3 } } } }
-- chest A whose cell is loaded but not activated yet: definition readable, no container module
alloc(103, { GetFullName = function() return "IO_A_CHEST /Script/Angelscript.Default__IO_A_CHEST" end })
alloc(102, { m_DataModules = arr({}) })
alloc(100, { GetFullName = function() return "InteractiveObjectActor /Game/Map.Chest_A" end,
  GetInteractiveObjectDefinition = function() return wrap(103) end,
  K2_GetActorLocation = function() return { X = 5000, Y = 5000, Z = 0 } end,
  m_DataModuleComponent = wrap(102) })
alloc(1, { K2_GetPawn = function() return wrap(2) end, GetFullName = function() return "GothicPlayerControllerBaseBP_C /Game/Map.PC" end })
alloc(2, { K2_GetActorLocation = function() return { X = 90000, Y = 90000, Z = 0 } end })
_G.FindAllOf = function(cls) if cls == "GothicPlayerControllerBaseBP_C" then return { wrap(1) } end return nil end
local handed = {}
alloc(9, { GetFullName = function() return "DataModuleLibrary /Script/G1R.Default__DataModuleLibrary" end,
  GetContainerDataModule = function(self, actor)
    local o = Memory[actor.__addr]
    local n = o and o.GetFullName and o.GetFullName() or "?"
    handed[n] = (handed[n] or 0) + 1
    return nil
  end })
_G.StaticFindObject = function() return wrap(9) end
_G.FindFirstOf = function() return nil end
local U = dofile(SRC .. "util.lua")
local K = dofile(SRC .. "chests.lua")
local State = { chests = {}, seen = {}, recent = {} }
K.init(U, {}, Defs, State)
local GAME = 86400 * 10
local function run(seconds)
  for _ = 1, math.floor(seconds / 0.25 + 0.5) do
    REAL = REAL + 0.25; GAME = GAME + 0.25 * 15
    local ok, err = pcall(K.tick, GAME, REAL)
    if not ok then io.write("    TICK ERROR: ", tostring(err), "\n") end
  end
end
K.onNewObject(wrap(100))
run(10)
io.write("== chest A is unloaded before it ever got a container module; a widget of another mod is created at the same address\n")
free(100); free(102)
alloc(100, { GetFullName = function() return "Image /Engine/Transient.GameEngine_0:GothicGameInstance_0.W_Map_Main_C_1.WidgetTree_0.Image_77" end })
wrap(100)
run(10)
for n, c in pairs(handed) do io.write(("   GetContainerDataModule was handed  %-90s %d time(s)\n"):format(n, c)) end
io.write("   ", K.statusLine(), "\n")
