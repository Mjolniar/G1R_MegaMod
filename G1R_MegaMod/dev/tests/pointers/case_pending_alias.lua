-- Pointer-semantics test (from the review of 2026-10-05, its check "pending_alias_*"): a new object is
-- announced, and before the mod has looked at it for the first time it is freed and something else lives
-- at its address - an object of another mod, or another container. The mod must not ask the newcomer for
-- the first object's definition. Fake API as in case_alias_nonactor.lua (a wrapper is a pointer).
--   lua5.4 case_pending_alias.lua foreign|other_chest moving|paused
local KIND, CLOCK = arg and arg[1] or "foreign", arg and arg[2] or "moving"
local SRC = os.getenv("G1R_REPOP_SRC") or ((debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./") .. "../../../modules/repopulate/Scripts/")
_G.print = function(s) io.write("    LOG ", s) end
local REAL = 1000.0
os.clock = function() return REAL end
local Memory, Wrapped = {}, {}
local BAD = 0
local W = {}
W.__index = function(self, k)
  if k == "IsValid" then return function(s) return Memory[s.__addr] ~= nil and Wrapped[s.__addr] == true end end
  local o = Memory[self.__addr]
  if o == nil then error("USE AFTER FREE") end
  if k == "GetInteractiveObjectDefinition" and o.replacement then
    BAD = BAD + 1
    error("member lookup on the object that took the place of the announced one")
  end
  local v = o[k]
  if type(v) == "function" then return function(_, ...) return v(o, ...) end end
  if v == nil then return setmetatable({}, { __index = function(_, kk) if kk == "IsValid" then return function() return false end end return nil end }) end
  return v
end
local function wrap(addr) Wrapped[addr] = true; return setmetatable({ __addr = addr }, W) end
local function alloc(addr, o) assert(Memory[addr] == nil); Memory[addr] = o; return o end
local function free(addr) Memory[addr] = nil; Wrapped[addr] = nil end
local function arr(elems) return { ForEach = function(_, fn) for i, e in ipairs(elems) do if fn(i, { get = function() return e end }) == true then break end end end } end
local Defs = { IO_A_CHEST = { s = true, k = "chest", i = { { "ItFo_Apple", 3 } } } }
alloc(103, { GetFullName = function() return "IO_A_CHEST /Script/Angelscript.Default__IO_A_CHEST" end })
alloc(102, { m_DataModules = arr({}) })
alloc(100, { GetFullName = function() return "InteractiveObjectActor /Game/Map.Chest_A" end,
  GetInteractiveObjectDefinition = function() return wrap(103) end,
  K2_GetActorLocation = function() return { X = 5000, Y = 5000, Z = 0 } end,
  m_DataModuleComponent = wrap(102) })
alloc(1, { K2_GetPawn = function() return wrap(2) end, GetFullName = function() return "GothicPlayerControllerBaseBP_C /Game/Map.PC" end })
alloc(2, { K2_GetActorLocation = function() return { X = 90000, Y = 90000, Z = 0 } end })
_G.FindAllOf = function(cls) if cls == "GothicPlayerControllerBaseBP_C" then return { wrap(1) } end return nil end
alloc(9, { GetFullName = function() return "DataModuleLibrary /Script/G1R.Default__DataModuleLibrary" end, GetContainerDataModule = function() return nil end })
_G.StaticFindObject = function() return wrap(9) end
_G.FindFirstOf = function() return nil end
local U = dofile(SRC .. "util.lua")
local K = dofile(SRC .. "chests.lua")
K.init(U, {}, Defs, { chests = {}, seen = {}, recent = {} })
local GAME = 86400 * 10
local function run(seconds)
  for _ = 1, math.floor(seconds / 0.25 + 0.5) do
    REAL = REAL + 0.25
    if CLOCK ~= "paused" then GAME = GAME + 0.25 * 15 end      -- (paused: the mod's updates go on, the game clock stands)
    local ok, err = pcall(K.tick, GAME, REAL)
    if not ok then io.write("    TICK ERROR: ", tostring(err), "\n") end
  end
end
K.onNewObject(wrap(100))
free(100)
alloc(100, { replacement = true, GetFullName = function()
  return KIND == "foreign" and "Image /Engine/Transient.Reused" or "InteractiveObjectActor /Game/Map.Chest_B"
end })
wrap(100)
run(10)
io.write(("%s, game clock %s: definition asked of the newcomer %d time(s)\n"):format(KIND, CLOCK, BAD))
