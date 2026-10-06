-- Offline harness for G1R_Repopulate: emulates the UE4SS Lua API surface the
-- mod uses and runs the real scripts against generated game state.
-- Two modes (G1R_REPOP_MODE, set by ../repopulate_engine/harness.lua):
--   "search" (this suite): the engine cannot be asked and the game's begin /
--       end of play calls are not there - no engine object is handed over, the
--       hooks do not exist. Everything is found by searches among all objects,
--       which the mod spaces out (one per second). The mod before 1.4 worked
--       this way, and 1.4 falls back to it.
--   "engine": the map load hooks hand over the engine object, the engine's
--       function libraries and the game's getters answer, and the begin / end
--       of play hooks fire for every actor. What the mod does in the game.
-- Every scenario runs in both; what differs between them is marked ENGINE.
-- (E holds what the two modes need - the main chunk is close to Lua's limit of 200 local variables)
local E = { mode = rawget(_G, "G1R_REPOP_MODE") or os.getenv("G1R_REPOP_MODE") or "search" }
local ENGINE = E.mode == "engine"
-- Paths: the module under test is found relative to this file; G1R_REPOP_SRC / G1R_TEST_TMP override.
local SRC = os.getenv("G1R_REPOP_SRC")
  or ((debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./") .. "../../../modules/repopulate/Scripts/")
local TMP = (os.getenv("G1R_TEST_TMP") or "/tmp/g1r-tests") .. "/repop_h" .. (ENGINE and "_engine" or "") .. "/"
os.execute("rm -rf " .. TMP .. " && mkdir -p " .. TMP .. " && cp -r " .. SRC .. " " .. TMP)
local DIR = TMP .. "Scripts/"

local H = { logs = {}, real = 1000.0, game = 86400 * 3 + 9 * 3600, rnd = nil }
-- Test-only container kinds with items of their own, appended to the copy of
-- the data the mod loads: what the mod knows about them is under the test's
-- control, whatever it learned from the real kinds before.
H.TEST_KINDS = 12
do
  local f = assert(io.open(DIR .. "data/chests.lua", "r")); local text = f:read("a"); f:close()
  local cut = text:match("^.*()}")
  local extra = {}
  for i = 1, H.TEST_KINDS do
    extra[#extra + 1] = ('  ["IO_ZZ_TESTCHEST_%02d"] = { s = true, k = "chest", i = { { "ItZz_Test_%02d_A", 2 }, { "ItZz_Test_%02d_B", 1 }, { "ItZz_Test_%02d_C", 5 } } },\n')
      :format(i, i, i, i)
  end
  f = assert(io.open(DIR .. "data/chests.lua", "w")); f:write(text:sub(1, cut - 1), table.concat(extra), "}\n"); f:close()
end
-- deterministic randomness: math.random() (no arguments) returns RNDV
local RNDV = 0.0
local ORIG_RANDOM = math.random
math.random = function(a, b) if a == nil then return RNDV end return ORIG_RANDOM(a, b) end
local function setRandom(v) RNDV = v end
local QUIET = os.getenv("QUIET") == "1"
_G.print = function(s) H.logs[#H.logs + 1] = s; if not QUIET then io.write("    LOG ", s) end end
os.clock = function() return H.real end

local fails, oks = 0, 0
local SHOWOK = os.getenv("SHOWOK") == "1"
local function check(c, msg)
  if c then oks = oks + 1; if SHOWOK then io.write("  ok   " .. msg .. "\n") end
  else fails = fails + 1; io.write("  FAIL " .. msg .. "\n") end
end
local function lastLog(pat)
  for i = #H.logs, 1, -1 do if H.logs[i]:find(pat) then return H.logs[i] end end
end

-- ---------------------------------------------------------------- objects
local addr = 0
local Base = {}
Base.__index = Base
function Base:IsValid() return self.__valid ~= false end
function Base:GetFullName() return self.__full end
function Base:GetAddress() return rawget(self, "__addr") end
function Base:IsA(class) local isa = rawget(self, "__isa"); return isa ~= nil and isa[class] == true end
local function obj(full, t)
  t = t or {}
  addr = addr + 1
  t.__full = full
  t.__addr = addr
  return setmetatable(t, Base)
end
local function FN(s) return { ToString = function() return s end, __s = s } end
_G.FName = function(s) return FN(s) end

-- struct wrapper semantics: reading/writing fields of a table
local function struct(t) return t end

-- The two kinds of actors the mod follows, and the game's begin / end of play
-- calls for them (ENGINE; in the other mode the hooks do not exist and
-- nothing is announced).
E.IOClass = obj("Class /Script/G1R.InteractiveObjectActor")
E.StateClass = obj("Class /Script/G1R.GothicCharacterState")
H.play = { began = nil, ended = nil, inPlay = {}, begins = 0, ends = 0 }
function E.param(v) return { get = function() return v end } end
function E.beginPlay(o)
  if not ENGINE or H.play.inPlay[o] or o.__valid == false or H.play.silentBegin then return end
  H.play.inPlay[o] = true
  if H.play.began then
    H.play.begins = H.play.begins + 1
    H.play.began(E.param(o))
  end
end
-- ENGINE: an object that has left play is not the mod's to touch. Its fields
-- are taken away and every access is written down (the harness keeps what it
-- needs under names starting with "__"); the list must stay empty.
E.touched = {}
function E.trap(o)
  if not ENGINE or o == nil or E.trapOff then return end       -- (trapOff: the mod has stopped relying on the calls)
  local keep = {}
  for k, v in pairs(o) do if type(k) == "string" and k:sub(1, 2) == "__" then keep[k] = v end end
  for k in pairs(o) do o[k] = nil end
  for k, v in pairs(keep) do rawset(o, k, v) end
  setmetatable(o, { __index = function(self, k)
    if type(k) == "string" and k:sub(1, 2) == "__" then return nil end
    if k == "GetAddress" then return function(this) return rawget(this, "__addr") end end     -- (the wrapper's own pointer)
    E.touched[#E.touched + 1] = tostring(rawget(self, "__full")) .. " : " .. tostring(k)
    if k == "IsValid" then return function() return false end end
    if k == "GetFullName" then return function() return "None" end end
    return nil
  end })
end
function E.endPlay(o)
  if not ENGINE or not H.play.inPlay[o] then return end
  H.play.inPlay[o] = nil
  if H.play.ended and not H.play.silentEnd and not H.play.noEnds then
    H.play.ends = H.play.ends + 1
    H.play.ended(E.param(o), E.param(0))
  end
end

-- game time
local TimeSub = obj("GameTimeSubsystem /Script/G1R.GameTimeSubsystem_0")
TimeSub.CurrentGameTime = {}
setmetatable(TimeSub.CurrentGameTime, { __index = function(_, k) if k == "TotalSeconds" then return H.game end end })

-- player
H.player = { 100000, -100000, 0 }
local Pawn = obj("BP_Hero_C /Game/Maps/MainMap.Hero")
Pawn.K2_GetActorLocation = function() return { X = H.player[1], Y = H.player[2], Z = H.player[3] } end
local World = obj("World /Game/Maps/MainMap.MainMap")
local Ctrl = obj("GothicPlayerControllerBaseBP_C /Game/Maps/MainMap.PC_0")
Ctrl.K2_GetPawn = function() return Pawn end
Ctrl.GetWorld = function() return World end
local PDS = obj("PersistentDataSubsystem /Script/G1R.PDS_0", { m_CurrentProfileId = 2 })

-- data
local CDB = dofile(SRC .. "data/creature_points.lua")
local IDB = dofile(SRC .. "data/item_points.lua")
local KDB = dofile(DIR .. "data/chests.lua")
-- the real kinds in a fixed order (picks below must not depend on table order)
H.KNAMES = {}
for n in pairs(KDB) do if not n:find("^IO_ZZ_") then H.KNAMES[#H.KNAMES + 1] = n end end
table.sort(H.KNAMES)

-- ---------------------------------------------------------------- world points / items
local Configs = {}
local function addConfig(name, refillable, hours)
  local c = { m_Name = FN(name), m_ItemSpawnConfig = { m_Refillable = refillable or false, m_RefillHours = hours or 0, m_IsActive = true } }
  Configs[#Configs + 1] = c
  return c
end
for name, spot in pairs(IDB) do addConfig(name, spot.p == "keep", spot.r) end
for name in pairs(CDB) do addConfig(name, false, 0) end
local unknown = addConfig("Spawner_QUEST_Item_99", false, 0)
local herbName, looseName, keepName
for name, spot in pairs(IDB) do
  if spot.p == "herb" and not herbName then herbName = name end
  if spot.p == "loose" and not looseName then looseName = name end
  if spot.p == "keep" and spot.r > 0 and not keepName then keepName = name end
end
local function cfgByName(name)
  for _, c in ipairs(Configs) do if c.m_Name.__s == name then return c end end
end
H.wrapElements = false
-- (a TArray as this UE4SS build presents it: an index past the end would add an element - counted, must stay 0)
H.configsGrown = 0
local ConfigArray = setmetatable({
  ForEach = function(self, fn)
    for i, c in ipairs(Configs) do
      if H.wrapElements then fn(i, { get = function() return c end }) else fn(i, c) end
    end
  end,
  GetArrayNum = function() return #Configs end,
}, { __index = function(_, k)
  if type(k) ~= "number" then return nil end
  if k > #Configs or k < 1 then H.configsGrown = H.configsGrown + 1; return nil end
  local c = Configs[k]
  if H.wrapElements then return { get = function() return c end } end
  return c
end })
local Manager = obj("WorldPointManager /Script/G1R.WorldPointManager_0", { m_WorldPointConfigs = ConfigArray })

-- ---------------------------------------------------------------- creatures
local States = {}
local function addState(unique, point, idx, opts)
  opts = opts or {}
  local p = CDB[point]
  local s = obj("GothicNPCState /Game/Maps/MainMap.GothicNPCState_" .. (#States + 1))
  s.__id = opts.id or (unique .. "-" .. point .. "-" .. idx)
  s.__unique = unique
  s.__dead = opts.dead or false
  s.__pos = opts.pos or { p.x + 100, p.y + 50, p.z }
  s.GetCharacterGlobalId = function(self) return FN(self.__id) end
  s.GetCharacterUniqueName = function(self) return FN(self.__unique) end
  s.IsDead = function(self) return self.__dead end
  s.GetRemovedFromWorld = function(self) return self.__removed == true end
  s.RemoveFromWorld = function(self) self.__removed = true; H.removed = (H.removed or 0) + 1 end
  s.GetCharacterLocation = function(self) return { X = self.__pos[1], Y = self.__pos[2], Z = self.__pos[3] } end
  s.__isa = { [E.StateClass] = true }
  States[#States + 1] = s
  E.beginPlay(s)
  return s
end
-- a character state the game destroys: it leaves play, and its object is gone
function E.removeState(s)
  local announced = ENGINE and H.play.inPlay[s] and not H.play.silentEnd
  E.endPlay(s)
  s.__valid = false
  if announced then E.trap(s) end
end
-- humans in the world (ignored)
for i = 1, 30 do
  local s = obj("GothicNPCState /Game/Maps/MainMap.Human_" .. i)
  s.GetCharacterGlobalId = function() return FN("OC_GRD_Guard" .. i .. "-Spawn-1") end
  s.GetCharacterUniqueName = function() return FN("OC_GRD_Guard" .. i) end
  s.IsDead = function() return false end
  s.GetRemovedFromWorld = function() return false end
  s.GetCharacterLocation = function() return { X = 0, Y = 0, Z = 0 } end
  s.__isa = { [E.StateClass] = true }
  States[#States + 1] = s
end
-- pick test points
local function pointWith(pred)
  local names = {}
  for n, p in pairs(CDB) do if pred(n, p) then names[#names + 1] = n end end
  table.sort(names)
  return names
end
local multi = pointWith(function(n, p) return #p.s == 1 and p.s[1].n >= 3 and not p.s[1].e and not p.ch end)
local single = pointWith(function(n, p) return #p.s == 1 and p.s[1].n == 1 and not p.s[1].e and not p.ch end)
local elites = pointWith(function(n, p) for _, s in ipairs(p.s) do if s.e then return true end end return false end)
local P_FULL, P_HALF, P_EMPTY, P_NEVER, P_SPATIAL = multi[1], multi[2], single[1], single[2], multi[3]
local P_ELITE = elites[1]
-- full point: all alive
for i = 1, CDB[P_FULL].s[1].n do addState(CDB[P_FULL].s[1].u, P_FULL, i) end
-- half point: one alive, rest dead
addState(CDB[P_HALF].s[1].u, P_HALF, 1)
for i = 2, CDB[P_HALF].s[1].n do addState(CDB[P_HALF].s[1].u, P_HALF, i, { dead = true }) end
-- empty point: one dead
addState(CDB[P_EMPTY].s[1].u, P_EMPTY, 1, { dead = true })
-- spatial point: creatures alive but with ids without a point token (e.g. spawned by a library call)
for i = 1, CDB[P_SPATIAL].s[1].n do
  addState(CDB[P_SPATIAL].s[1].u, P_SPATIAL, i, { id = CDB[P_SPATIAL].s[1].u .. "-AIScript-" .. i })
end
-- elite point: dead
addState(CDB[P_ELITE].s[1].u, P_ELITE, 1, { dead = true })
-- a far-away living creature so the census knows states are global
local farName = multi[#multi]
addState(CDB[farName].s[1].u, farName, 1, { pos = { CDB[farName].x, CDB[farName].y, 0 } })
-- (P_NEVER has no states at all: never visited)

-- world point script instances (one per DB point except one, to test the library fallback)
local Instances = {}
H.spawns = {}
local NO_INSTANCE = P_HALF
for name, p in pairs(CDB) do
  if name ~= NO_INSTANCE then
    local inst = obj(p.c .. " /Script/G1R.WorldPointManager_0:" .. p.c .. "_0")
    inst.SpawnAIAgent = function(self, def, routine)
      if H.noneAt == name then return FN("None") end      -- (the point's script spawned nothing)
      if H.nilAt == name then                             -- (spawned, but the name handed back cannot be read)
        H.spawns[#H.spawns + 1] = { how = "point", point = name, def = def.__full, routine = routine and routine.__full }
        return nil
      end
      H.spawns[#H.spawns + 1] = { how = "point", point = name, def = def.__full, routine = routine and routine.__full }
      H.spawnedNames["spawned-" .. name] = true
      return FN("spawned-" .. name)
    end
    Instances[#Instances + 1] = inst
    cfgByName(name).m_WorldPointScriptInstance = inst      -- what the game's manager keeps for the point
  end
end
-- the game's lookup of a character by its unique name (GothicNPCState's default object): it knows the names the
-- points' spawns handed back, unless H.npcFind says otherwise for a name; H.noNpcLookup: the object is not there
H.spawnedNames, H.npcLookups = {}, 0
H.noNpcLookup = not ENGINE    -- the plain run keeps the way before 0.3.0, the engine run has the lookup
H.npcCDO = obj("GothicNPCState /Script/G1R.Default__GothicNPCState")
H.npcCDO.FindNPCByUniqueName = function(self, ctrl, name)
  local s = type(name) == "table" and name.__s or tostring(name)
  H.npcLookups = H.npcLookups + 1
  if H.npcFind and H.npcFind(s) == false then return nil end
  if H.spawnedNames[s] then return obj("GothicCharacterState /Game/Maps/World.World:PersistentLevel." .. s) end
  return nil
end
local AILib = obj("AIScriptLibrary /Script/G1R.Default__AIScriptLibrary")
AILib.SpawnAIAgent = function(self, world, def, pos)
  H.spawns[#H.spawns + 1] = { how = "library", def = def.__full, pos = pos }
  return obj("SpawningRequest /Engine/Transient.SpawningRequest_1")
end

-- ---------------------------------------------------------------- containers
-- Modelled on the game (CL174209): the definition property on the actor is
-- empty for chests; the definition comes from the actor's getter (the class
-- default object of the IO_* class) or from the copy on the interactive
-- component. The container module counts through HasItemMain (out parameter
-- must be a table), Server_AddNewItem does nothing in a single-player game,
-- Multicast_AddNewItem adds when LocalPredicted is false. The game saves a
-- container's contents only when the player opens it; an unloaded container
-- comes back with the saved contents (or its defaults).
--
-- Item classes: the game keeps a container's default contents on its data
-- module (m_DefaultInventory) and on the definition object (m_Inventory), as
-- m_Values.Items[*].m_Slots[*].m_SlotData.{m_ItemDefinition, m_ItemCount}.
-- Reading m_ItemDefinition there works but costs one debug line in UE4SS.log
-- per read (H.io.logged counts them). m_InventoryType / m_Capacity next to
-- the slots, and m_InteractiveObjectDefinition / m_ItemDefinition on the
-- actor, must not be read at all (H.io.banned). The game's lists also hold
-- the quest / key items that data/chests.lua leaves out.
H.io = { banned = 0, logged = 0, hasCalls = 0, serverCalls = 0, multiCalls = 0, predicted = 0, outMode = "count",
         addFails = false, addPartial = false, hasThrows = false, noGetter = false, noComponent = false }
H.sfo = { lib = 0, item = 0, other = 0, ai = 0 }
H.savedInv = {}
local BANNED = { m_InteractiveObjectDefinition = true, m_ItemDefinition = true, m_InventoryType = true, m_Capacity = true }
local IOMeta = { __index = function(_, k)
  if BANNED[k] then H.io.banned = H.io.banned + 1; return nil end
  return Base[k]
end }
local ActorsIO = {}
local Chests = {}
local function copyItems(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
local function shortClass(cls) return cls.__full:match("%.([%w_]+)$") end
do
local ItemClasses = {}
function H.itemClass(name)
  local c = ItemClasses[name]
  if not c then c = obj("ASClass /Script/Angelscript." .. name); ItemClasses[name] = c end
  return c
end
-- a TArray as UE4SS presents it (ForEach stops when the callback returns true)
function H.uArray(elems)
  return { ForEach = function(self, fn)
    for i, e in ipairs(elems) do
      local r
      if H.wrapElements then r = fn(i, { get = function() return e end }) else r = fn(i, e) end
      if r == true then break end
    end
  end }
end
-- one inventory (ReplicatedInventoryMap) holding the given { name, count } list
function H.inventoryOf(list, instances)
  local slots = {}
  for _, it in ipairs(list) do
    local name, count = it[1], it[2]
    local data = setmetatable({}, { __index = function(_, k)
      if k == "m_ItemDefinition" then
        H.io.logged = H.io.logged + 1
        local cls = H.itemClass(name)
        if instances then
          local inst = obj(name .. " /Script/Angelscript.Default__" .. name)
          inst.GetClass = function() return cls end
          return inst
        end
        return cls
      elseif k == "m_ItemCount" then return count end
    end })
    slots[#slots + 1] = { m_SlotData = data, m_Id = #slots }
  end
  local container = setmetatable({ m_Slots = H.uArray(slots) }, { __index = function(_, k)
    if BANNED[k] then H.io.banned = H.io.banned + 1 end
    return nil
  end })
  return { m_Values = { Items = H.uArray(#list > 0 and { container } or {}) } }
end
end
local function streamIn(ch)
  local a = obj("Interactive_Chest_C /Game/Maps/MainMap.Chest_" .. ch.name)
  setmetatable(a, { __index = function(self, k)
    if k == "m_DataModuleComponent" then
      if H.io.noComponent then return nil end
      return rawget(self, "__comp")
    end
    if BANNED[k] then H.io.banned = H.io.banned + 1; return nil end
    return Base[k]
  end })
  a.__pos = ch.pos
  a.__readyAt = ch.readyAfter and (H.real + ch.readyAfter) or nil
  a.K2_GetActorLocation = function(self) return { X = self.__pos[1], Y = self.__pos[2], Z = self.__pos[3] } end
  local cdo = obj((ch.className or ch.name) .. " /Script/Angelscript.Default__" .. (ch.className or ch.name))
  -- what the game's own list holds: the data list, minus an omitted item, plus a quest item the data leaves out
  local gameList = {}
  for _, it in ipairs(ch.list) do if it[1] ~= ch.omit then gameList[#gameList + 1] = it end end
  gameList[#gameList + 1] = { "ItKe_Quest_Key_99", 1 }
  cdo.m_Inventory = H.inventoryOf(ch.noDefinitionList and {} or gameList, ch.instances)
  a.GetInteractiveObjectDefinition = function(self)
    if H.io.noGetter then error("attempt to call a nil value (method 'GetInteractiveObjectDefinition')") end
    if self.__readyAt and H.real < self.__readyAt then return obj("None", { __valid = false }) end
    return cdo
  end
  a.m_InteractiveComponent = obj("InteractiveComponent /Game/Maps/MainMap.Chest_" .. ch.name .. ".Interactive")
  a.m_InteractiveComponent.m_InteractItem = obj((ch.className or ch.name) .. " /Game/Maps/MainMap.Chest_" .. ch.name .. ".Item_0")
  a.m_InteractiveComponent.m_InteractItem.IsValid = function() return not (a.__readyAt and H.real < a.__readyAt) end
  local dm = obj("DataModule_Container /Game/Maps/MainMap.Chest_" .. ch.name .. ".DataModule_Container_0")
  dm.__items = copyItems(H.savedInv[ch.name] or ch.defaults)
  dm.m_DefaultInventory = H.inventoryOf(ch.noModuleDefaults and {} or gameList, ch.instances)
  setmetatable(dm, { __index = function(self, k)
    if k == "m_Inventory" then            -- what is in it right now
      if ch.noCurrentList then return H.inventoryOf({}) end
      local now = {}
      for name, n in pairs(self.__items) do if n > 0 then now[#now + 1] = { name, n } end end
      table.sort(now, function(x, y) return x[1] < y[1] end)
      return H.inventoryOf(now, ch.instances)
    end
    if BANNED[k] then H.io.banned = H.io.banned + 1; return nil end
    return Base[k]
  end })
  local comp = obj("DataModuleComponent /Game/Maps/MainMap.Chest_" .. ch.name .. ".DataModuleComponent_0")
  comp.m_DataModules = H.uArray({ obj("DataModule_Lock /Game/Maps/MainMap.Chest_" .. ch.name .. ".DataModule_Lock_0"), dm })
  a.__comp = comp
  rawset(a, "m_DataModuleComponent", nil)
  dm.HasItemMain = function(self, cls, n, out)
    H.io.hasCalls = H.io.hasCalls + 1
    if H.io.hasThrows then error("Tried calling UFunction without a registered handler for parameter") end
    if type(out) ~= "table" then error("Tried storing reference to a Lua table for an 'Out' parameter when calling a UFunction but no table was on the stack") end
    local total = self.__items[shortClass(cls)] or 0
    if H.io.outMode == "count" then out.hasItemCount = total
    elseif H.io.outMode == "wrapped" then out.hasItemCount = { get = function() return total end } end
    return total >= n
  end
  dm.Server_AddNewItem = function(self, inv, cls, n, payload)
    H.io.serverCalls = H.io.serverCalls + 1      -- does nothing in a single-player game
  end
  dm.Multicast_AddNewItem = function(self, inv, cls, n, payload, predicted)
    assert(inv == 1 and type(payload) == "table" and type(predicted) == "boolean", "Multicast_AddNewItem: wrong parameters")
    H.io.multiCalls = H.io.multiCalls + 1
    if predicted then H.io.predicted = H.io.predicted + 1; return end
    if H.io.addFails or H.io.addFailsFor == ch.name then return end
    if H.io.addPartial and H.io.addPartial ~= shortClass(cls) then return end
    if H.io.addPartialFor == ch.name and KDB[ch.name].i[1][1] ~= shortClass(cls) then return end
    local short = shortClass(cls)
    self.__items[short] = (self.__items[short] or 0) + n
    H.added = (H.added or 0) + n
  end
  a.__dm = dm
  a.__isa = { [E.IOClass] = true }
  ch.actor = a
  ActorsIO[#ActorsIO + 1] = a
  E.beginPlay(a)
  return a
end
local function streamOut(ch)
  local announced = ENGINE and H.play.inPlay[ch.actor] and not H.play.silentEnd
  E.endPlay(ch.actor)
  ch.actor.__valid = false
  ch.actor.__dm.__valid = false
  if announced then E.trap(ch.actor.__dm); E.trap(ch.actor.__comp); E.trap(ch.actor) end
  for i, a in ipairs(ActorsIO) do if a == ch.actor then table.remove(ActorsIO, i); break end end
end
-- the player opens the container, optionally takes / stores things, closes it:
-- the game writes the contents into its save data
local function playerOpens(ch, change)
  local items = ch.actor.__dm.__items
  if change then change(items) end
  H.savedInv[ch.name] = copyItems(items)
end
local function takeDefaults(ch)
  return function(items) for _, it in ipairs(ch.list) do items[it[1]] = 0 end end
end
local function makeChest(name, x, y, contents, opts)
  local defaults = {}
  for _, it in ipairs(contents) do defaults[it[1]] = it[2] end
  local ch = { name = name, pos = { x, y, 100 }, defaults = defaults, list = contents }
  for k, v in pairs(opts or {}) do ch[k] = v end
  Chests[#Chests + 1] = ch
  streamIn(ch)
  return ch
end
local function isFull(ch)
  for _, it in ipairs(ch.list) do if (ch.actor.__dm.__items[it[1]] or 0) ~= it[2] then return false end end
  return true
end
local DMLib = obj("DataModuleLibrary /Script/G1R.Default__DataModuleLibrary")
DMLib.GetContainerDataModule = function(self, actor) return actor.__dm end
local chairs = {}
for i = 1, 5 do
  local c = obj("Interactive_Chair_01_C /Game/Maps/MainMap.Chair_" .. i)
  setmetatable(c, IOMeta)
  local cdo = obj("IO_OC_CHAIR_" .. i .. " /Script/Angelscript.Default__IO_OC_CHAIR_" .. i)
  c.GetInteractiveObjectDefinition = function() return cdo end
  c.K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end
  c.__isa = { [E.IOClass] = true }
  chairs[#chairs + 1] = c
  ActorsIO[#ActorsIO + 1] = c
end
local settleName, wildName
for _, n in ipairs(H.KNAMES) do
  local d = KDB[n]
  if d.s and d.k == "chest" and not settleName then settleName = n end
  if not d.s and d.k == "chest" and not wildName then wildName = n end
end
local Settle = makeChest(settleName, 100500, -100500, KDB[settleName].i)
local Wild = makeChest(wildName, 300000, -100000, KDB[wildName].i)

-- ---------------------------------------------------------------- crime system
-- The rule table the game builds (generated from the game scripts) and a
-- model of the two places where the game consults it.
local CM = dofile((debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./") .. "crime_model.lua")
local CrimeClasses = {}
local function crimeClass(name)
  local c = CrimeClasses[name]
  if not c then c = obj("ASClass /Script/Angelscript." .. name); CrimeClasses[name] = c end
  return c
end
local function shortOf(cls) return cls.__full:match("%.([%w_]+)$") end
H.crime = { setThrows = false, setIgnored = false, addThrows = false, noForEach = false, scans = 0, baseMatchesAll = false, addCalls = 0 }
-- TMap<FGameplayTag, TSubclassOf<UCrimeDefinition>> as UE4SS presents it:
-- ForEach(function(key, value)) with key:get() -> struct, value:get()/:set(UClass)
local function makeCrimeMap()
  local map = { __pairs = {} }
  for _, e in ipairs(CM.vanilla) do map.__pairs[#map.__pairs + 1] = { tag = e[1], cls = crimeClass(e[2]) } end
  function map:ForEach(fn)
    if H.crime.noForEach then error("attempt to call a nil value (method 'ForEach')") end
    for _, p in ipairs(self.__pairs) do
      local keyStruct = { TagName = FN(p.tag) }
      local k = { get = function() return keyStruct end }
      local v = {
        get = function() return p.cls end,
        set = function(_, c)
          if H.crime.setThrows then error("push_classproperty: Value must be UClass or nil") end
          if H.crime.setIgnored then return end
          assert(type(c) == "table" and c.__full and c.__full:find("CrimeDefinition_", 1, true), "set: not a rule class")
          p.cls = c
        end,
      }
      if fn(k, v) == true then break end
    end
  end
  function map:Add(keyStruct, c)
    if H.crime.addThrows then error("Tried interacting with a map with an unsupported value type") end
    assert(type(c) == "table" and c.__full and c.__full:find("CrimeDefinition_", 1, true), "Add: not a rule class")
    H.crime.addCalls = (H.crime.addCalls or 0) + 1
    if H.crime.addDuplicates then   -- a scripting layer whose key hash differs from the game's
      self.__pairs[#self.__pairs + 1] = { tag = keyStruct.TagName.__s, cls = c, dup = true }
      return
    end
    for _, p in ipairs(self.__pairs) do
      if p.tag == keyStruct.TagName.__s then p.cls = c; return end
    end
    error("Add: key not in the table (the mod must never add entries)")
  end
  function map:Remove(keyStruct)
    for i = #self.__pairs, 1, -1 do
      local p = self.__pairs[i]
      if p.tag == keyStruct.TagName.__s and (p.dup or not H.crime.addDuplicates) then table.remove(self.__pairs, i); return end
    end
  end
  return map
end
-- Response modules that react to noises: class default objects with a
-- RequiredOwnedTags container. TArray as this UE4SS build presents it: an
-- index past the end ADDS zeroed elements (also on a read), elements are
-- struct wrappers whose fields can be written, Empty() clears.
H.gate = { reads = 0, grown = 0, grow = true, fieldSet = true, tableSet = true, noCdo = false, emptyThrows = false }
local function makeTagArray(initial)
  local arr = { __items = {} }
  for _, n in ipairs(initial or {}) do arr.__items[#arr.__items + 1] = { TagName = FN(n) } end
  function arr:GetArrayNum() H.gate.reads = H.gate.reads + 1; return #self.__items end
  function arr:Empty()
    if H.gate.emptyThrows then error("Empty is not available") end
    self.__items = {}
  end
  return setmetatable(arr, {
    __index = function(t, k)
      if type(k) ~= "number" then return nil end
      H.gate.reads = H.gate.reads + 1
      local n = #t.__items
      if k > n then
        if not H.gate.grow then error("TArray index out of range.") end
        for i = n + 1, k do t.__items[i] = { TagName = FN("None") } end
        H.gate.grown = H.gate.grown + (k - n)
      end
      local e = t.__items[k]
      return setmetatable({}, {
        __index = function(_, f) return e[f] end,
        __newindex = function(_, f, v)
          if not H.gate.fieldSet then error("struct member cannot be written") end
          e[f] = v
        end })
    end,
    __newindex = function(t, k, v)
      if type(k) ~= "number" then rawset(t, k, v); return end
      if not H.gate.tableSet then error("array element cannot be written") end
      local n = #t.__items
      if k > n then
        for i = n + 1, k do t.__items[i] = { TagName = FN("None") } end
        H.gate.grown = H.gate.grown + (k - n)
      end
      t.__items[k] = { TagName = v.TagName }
    end })
end
local GateCDO = {}
for _, name in ipairs({ "AIARM_ToInvestigateSuspiciousSound_Interaction", "AIARM_ToInvestigateSuspiciousSound_Trespassing" }) do
  GateCDO[name] = obj(name .. " /Script/Angelscript.Default__" .. name,
    { RequiredOwnedTags = { GameplayTags = makeTagArray(), ParentTags = makeTagArray() } })
end
local function gateTagsOf(name)
  local t = {}
  for _, e in ipairs(GateCDO[name].RequiredOwnedTags.GameplayTags.__items) do t[#t + 1] = e.TagName.__s end
  return table.concat(t, ",")
end
-- the game's check (UAIAssessmentResponseModule::IsApplicableToCharacter):
-- every required tag must be among the character's own tags
local function moduleApplies(name, ownTags)
  for _, e in ipairs(GateCDO[name].RequiredOwnedTags.GameplayTags.__items) do
    local found = false
    for _, tg in ipairs(ownTags) do if tg == e.TagName.__s then found = true end end
    if not found then return false end
  end
  return true
end
local NPC_TAGS = { "Guild.NewCamp", "Species.Human", "Character.NPC", "CampRole.Guard" }
local GI, GT = "AIARM_ToInvestigateSuspiciousSound_Interaction", "AIARM_ToInvestigateSuspiciousSound_Trespassing"

local crimeGen = 0
local CrimeSubs = {}
local function makeCrimeWorld()
  crimeGen = crimeGen + 1
  for _, old in pairs(CrimeSubs) do old.__valid = false end
  CrimeSubs = {
    base = obj("CrimeProcessingSubsystem /Game/Maps/MainMap.MainMap:CrimeProcessingSubsystem_" .. crimeGen, { CrimeDefinitions = makeCrimeMap() }),
    human = obj("CrimeProcessingSubsystem_Human /Game/Maps/MainMap.MainMap:CrimeProcessingSubsystem_Human_" .. crimeGen, { CrimeDefinitions = makeCrimeMap() }),
    orc = obj("CrimeProcessingSubsystem_Orc /Game/Maps/MainMap.MainMap:CrimeProcessingSubsystem_Orc_" .. crimeGen, { CrimeDefinitions = makeCrimeMap() }),
  }
end
makeCrimeWorld()
local CrimeCDO = obj("CrimeProcessingSubsystem_Human /Script/Angelscript.Default__CrimeProcessingSubsystem_Human", { CrimeDefinitions = makeCrimeMap() })
local function crimeFind(cls)
  H.crime.scans = H.crime.scans + 1
  if H.crime.noWorld then return {} end
  if cls == "CrimeProcessingSubsystem" then
    if H.crime.baseMatchesAll then return { CrimeCDO, CrimeSubs.base, CrimeSubs.human, CrimeSubs.orc } end
    return { CrimeSubs.base }
  end
  if cls == "CrimeProcessingSubsystem_Human" then return { CrimeCDO, CrimeSubs.human } end
  if cls == "CrimeProcessingSubsystem_Orc" then return { CrimeSubs.orc } end
  return {}
end
-- the game's lookup: the rule for a tag, walking up the tag hierarchy
local function crimeDef(map, tag)
  local t = tag
  while t do
    for _, p in ipairs(map.__pairs) do
      if p.tag == t then return CM.defs[shortOf(p.cls)], shortOf(p.cls) end
    end
    t = t:match("^(.*)%.[^%.]*$")
  end
end
-- the game's MakeNewCrimeRegisterData: is there a victim for this report?
local function crimeValid(map, tag, a)
  local d = crimeDef(map, tag)
  assert(d, "the game would dereference a missing rule for " .. tag)
  if d.src == 3 then return a.victim == true, d end
  if d.src == 0 then return a.area == true, d end
  return a.object == true, d
end
-- does a witness write the crime down itself? (the criminal is never the witness here)
local function witnessWrites(map, tag, a)
  local valid, d = crimeValid(map, tag, a)
  return valid and (a.force == true or d.mode == 1 or d.mode == 3 or (d.mode == 2 and a.self == true)), valid
end
-- what the game passes when the PLAYER commits the act
local PLAYER_ACTS = {
  { "Crime.Theft", object = true },
  { "Crime.Interaction", object = true },
  { "Crime.Lockpicking", object = true },
  { "Crime.Trespassing.OnPerson", area = true },
  { "Crime.Trespassing.OnGuild", area = true },
  { "Crime.FistsDrawn", area = true },
  { "Crime.ThreateningWeaponDrawn", area = true },
  { "Crime.Pickpocket.Fail", victim = true },
  { "Crime.Pickpocket.Success", victim = true },
  { "Crime.DirectThreat.Weapon.Melee", victim = true },
  { "Crime.DirectThreat.Weapon.Ranged", victim = true },
  { "Crime.DirectThreat.Weapon.Magic.HighThreat", victim = true },
  { "Crime.DirectThreat.Fists", victim = true },
}
local PLAYER_VIOLENCE = {
  { "Crime.Assault.Fists", victim = true }, { "Crime.Assault.Weapon.Melee", victim = true },
  { "Crime.Assault.Weapon.Ranged", victim = true }, { "Crime.Assault.Weapon.Magic.HighThreat", victim = true },
  { "Crime.Murder", victim = true }, { "Crime.DefeatedAgain", victim = true },
  { "Crime.Anti.Defeated.Self", victim = true }, { "Crime.Anti.Defeated.Other", victim = true },
}
-- what a WITNESS passes; "?" = can be either, so both are tried
local WITNESS_ACTS = {
  { "Crime.Theft", victim = "?", area = "?", object = true },
  { "Crime.Pickpocket.Success", victim = true, self = "?", area = "?", object = "?" },
  { "Crime.Pickpocket.Fail", victim = true, self = "?", area = "?", object = "?" },
  { "Crime.Interaction", victim = false, area = "?", object = true },
  { "Crime.Lockpicking", victim = false, area = "?", object = true },
  { "Crime.IgnoredWarning.Interaction", victim = true, self = true, area = "?", object = "?" },
  { "Crime.IgnoredWarning.Lockpicking", victim = true, self = true, area = "?", object = "?" },
  { "Crime.Trespassing.OnGuild", victim = false, area = true, object = false, force = "?", quiet = true },
  { "Crime.Trespassing.OnPerson", victim = false, area = true, object = false, force = "?", quiet = true },
  { "Crime.IgnoredWarning.Trespassing", victim = true, self = true, area = "?", object = false, quiet = true },
  { "Crime.Creeping", victim = true, self = true, area = "?", object = false, quiet = true },
  { "Crime.ThreateningWeaponDrawn", victim = "?", area = "?", object = false, quiet = true },
  { "Crime.FistsDrawn", victim = "?", area = "?", object = false, quiet = true },
  { "Crime.ThreateningWeaponTooClose", victim = true, self = true, area = "?", object = false, quiet = true },
  { "Crime.FistsTooClose", victim = true, self = true, area = "?", object = false, quiet = true },
  { "Crime.IgnoredWarning.WeaponDrawn", victim = true, self = true, area = "?", object = false, quiet = true },
  { "Crime.IgnoredWarning.FistsDrawn", victim = true, self = true, area = "?", object = false, quiet = true },
  { "Crime.DirectThreat.Weapon.Melee", victim = true, self = "?", area = "?", object = false, quiet = true },
  { "Crime.DirectThreat.Weapon.Ranged", victim = true, self = "?", area = "?", object = false, quiet = true },
  { "Crime.DirectThreat.Weapon.Magic.LowThreat", victim = true, self = "?", area = "?", object = false, quiet = true },
  { "Crime.DirectThreat.Fists", victim = true, self = "?", area = "?", object = false, quiet = true },
  { "Crime.IgnoredWarning.DirectThreat.Weapon", victim = true, self = true, area = "?", object = false, quiet = true },
  { "Crime.IgnoredWarning.DirectThreat.Fists", victim = true, self = true, area = "?", object = false, quiet = true },
  { "Crime.BlockingPath", victim = true, self = true, area = "?", object = false, quiet = true },
}
local function expand(act)
  local out = { {} }
  for _, f in ipairs({ "victim", "self", "area", "object", "force" }) do
    local nxt = {}
    for _, base in ipairs(out) do
      local vals = act[f] == "?" and { true, false } or { act[f] == true }
      for _, v in ipairs(vals) do
        local c = {}
        for k2, v2 in pairs(base) do c[k2] = v2 end
        c[f] = v
        nxt[#nxt + 1] = c
      end
    end
    out = nxt
  end
  return out
end
local function crimeMaps() return { CrimeSubs.base.CrimeDefinitions, CrimeSubs.human.CrimeDefinitions, CrimeSubs.orc.CrimeDefinitions } end
local function vanillaMap(map)
  if #map.__pairs ~= #CM.vanilla then return false end
  for i, e in ipairs(CM.vanilla) do
    if map.__pairs[i].tag ~= e[1] or shortOf(map.__pairs[i].cls) ~= e[2] then return false end
  end
  return true
end
local function countSwitched(map)
  local n = 0
  for i, e in ipairs(CM.vanilla) do if shortOf(map.__pairs[i].cls) ~= e[2] then n = n + 1 end end
  return n
end
-- the game's crime memory
local PlayerState = obj("GothicPlayerState /Game/Maps/MainMap.MainMap:GothicPlayerState_0")
local OtherState = obj("GothicNPCState /Game/Maps/MainMap.MainMap:GothicNPCState_Thief")
Pawn.PlayerState = PlayerState
local CrimeMem = obj("CrimeMemorySubsystem /Game/Maps/MainMap.MainMap:CrimeMemorySubsystem_0")
CrimeMem.__crimes, CrimeMem.__next = {}, 1
H.crime.listCalls, H.crime.getCalls = 0, 0
local function addCrime(tag, by)
  local id = CrimeMem.__next
  CrimeMem.__next = id + 1
  CrimeMem.__crimes[id] = { tag = tag, by = by or PlayerState }
  return id
end
CrimeMem.GetAllCrimesCommitedBy = function(self, who)
  H.crime.listCalls = H.crime.listCalls + 1
  local ids = {}
  for id, c in pairs(self.__crimes) do if c.by == who then ids[#ids + 1] = id end end
  table.sort(ids)
  if H.crime.wrapIds then
    for i, id in ipairs(ids) do ids[i] = { get = function() return id end } end
  end
  return ids
end
CrimeMem.GetCrimeByID = function(self, out, id)
  H.crime.getCalls = H.crime.getCalls + 1
  assert(type(out) == "table", "GetCrimeByID: the out parameter must be a Lua table")
  assert(math.type(id) == "integer", "GetCrimeByID: id must be an integer")
  local c = self.__crimes[id]
  if not c then return false end
  out.ID, out.CrimeType, out.bIsForgiven = id, { TagName = FN(c.tag) }, false
  return true
end
CrimeMem.RemoveCrime = function(self, id)
  assert(math.type(id) == "integer", "RemoveCrime: id must be an integer")
  if self.__crimes[id] then self.__crimes[id] = nil; return true end
  return false
end
local CrimeMemCDO = obj("CrimeMemorySubsystem /Script/G1R.Default__CrimeMemorySubsystem")
local function crimeTags(by)
  local t = {}
  for _, c in pairs(CrimeMem.__crimes) do if c.by == (by or PlayerState) then t[#t + 1] = c.tag end end
  table.sort(t)
  return table.concat(t, " ")
end

-- ---------------------------------------------------------------- UE4SS globals
H.finds = {}       -- class -> searches among all objects (FindAllOf / FindFirstOf)
_G.FindFirstOf = function(cls)
  H.finds[cls] = (H.finds[cls] or 0) + 1
  if cls == "GameTimeSubsystem" then
    if H.menu then return nil end       -- (H.menu: the main menu - a world without a game clock)
    return TimeSub
  end
  if cls == "WorldPointManager" then return Manager end
  if cls == "PersistentDataSubsystem" then return PDS end
end
_G.FindAllOf = function(cls)
  H.findAll = (H.findAll or 0) + 1
  H.finds[cls] = (H.finds[cls] or 0) + 1
  if cls == "GothicPlayerControllerBaseBP_C" then return { Ctrl } end
  if cls == "GothicCharacterState" then return States end
  if cls == "PersistentDataSubsystem" then return { obj("PersistentDataSubsystem /Script/G1R.Default__PersistentDataSubsystem", { m_CurrentProfileId = 0 }), PDS } end
  if cls == "WorldPointScript" then return Instances end
  if cls == "InteractiveObjectActor" then return ActorsIO end
  if cls:find("CrimeProcessingSubsystem", 1, true) then return crimeFind(cls) end
  if cls == "CrimeMemorySubsystem" then H.crime.scans = H.crime.scans + 1; return { CrimeMemCDO, CrimeMem } end
  return nil
end
_G.StaticFindObject = function(path)
  if path == "/Script/G1R.Default__GothicNPCState" then
    H.sfo.npc = (H.sfo.npc or 0) + 1
    if H.noNpcLookup then return nil end
    return H.npcCDO
  end
  if path == "/Script/G1R.Default__AIScriptLibrary" then
    H.sfo.ai = H.sfo.ai + 1
    if H.noAiLib then return nil end
    return AILib
  end
  if path == "/Script/G1R.Default__DataModuleLibrary" then H.sfo.lib = H.sfo.lib + 1; return DMLib end
  if path:match("^/Script/[%w_]+%.U?It%a%a_") then H.sfo.item = H.sfo.item + 1 else H.sfo.other = H.sfo.other + 1 end
  local gate = path:match("^/Script/Angelscript%.Default__(AIARM_[%w_]+)$")
  if gate then
    if H.gate.noCdo then return nil end
    return GateCDO[gate]
  end
  local short = path:match("^/Script/Angelscript%.([%w_]+)$")
  if short and short:match("^CrimeDefinition_") then
    if H.crime.noStatic or not CM.defs[short] then return nil end
    return crimeClass(short)
  end
  if short and not short:match("^U") then return obj("Class /Script/Angelscript." .. short) end
  return nil
end
_G.StaticConstructObject = function(cls, outer) return obj(cls.__full:gsub("^Class ", "") .. "_Instance") end
H.notify = {}
_G.NotifyOnNewObject = function(path, cb) H.notify[path] = cb end
_G.LoopInGameThreadWithDelay = function(ms, cb) H.loop = cb; H.loopMs = ms end
_G.RegisterLoadMapPreHook = function(cb) H.pre = cb end
_G.RegisterHook = function(path, cb) H.hooks = H.hooks or {}; H.hooks[path] = cb end
_G.RegisterConsoleCommandHandler = function(name, cb) H.console = H.console or {}; H.console[name] = cb end

-- ENGINE: the engine object the map load hooks hand over, the function
-- libraries and getters that answer without a search, the classes they are
-- asked with, and the begin / end of play hooks.
H.engine = { controller = 0, subsystem = 0, manager = 0, paused = 0 }   -- calls answered
E.paths = {}
if ENGINE then
  local Engine = obj("GothicGameEngine /Engine/Transient.GothicGameEngine_0")
  Engine.GameViewport = obj("GameViewportClient /Engine/Transient.GothicGameEngine_0:GameViewportClient_0", { World = World })
  E.engineParam = E.param(Engine)
  local Statics = obj("GameplayStatics /Script/Engine.Default__GameplayStatics")
  Statics.GetPlayerController = function(self, world, index)
    assert(world == World and index == 0, "GetPlayerController: wrong parameters")
    H.engine.controller = H.engine.controller + 1
    if H.noController then return nil end
    return H.controllerNow or Ctrl
  end
  Statics.IsGamePaused = function(self, world)
    H.engine.paused = H.engine.paused + 1
    return H.paused == true
  end
  local Classes = {}
  local function class(path) local c = obj("Class " .. path); Classes[c] = path; E.paths[path] = c; return c end
  class("/Script/G1R.GameTimeSubsystem"); class("/Script/G1R.PersistentDataSubsystem"); class("/Script/G1R.CrimeMemorySubsystem")
  class("/Script/Angelscript.CrimeProcessingSubsystem"); class("/Script/Angelscript.CrimeProcessingSubsystem_Human")
  class("/Script/Angelscript.CrimeProcessingSubsystem_Orc")
  local function subsystem(kind)
    return function(self, world, cls)
      assert(world == World, "subsystem getter: not the world")
      H.engine.subsystem = H.engine.subsystem + 1
      local path = Classes[cls]
      assert(path, "subsystem getter: not a class object")
      if kind == "state" and path == "/Script/G1R.GameTimeSubsystem" then
        if H.noClock or H.menu then return nil end
        return TimeSub
      end
      if kind == "instance" and path == "/Script/G1R.PersistentDataSubsystem" then return PDS end
      if kind == "world" then
        if H.crime.noWorld then return nil end
        if path == "/Script/G1R.CrimeMemorySubsystem" then return H.crimeMemory() end
        local subs = H.crimeSubs()
        if path == "/Script/Angelscript.CrimeProcessingSubsystem" then return subs.base end
        if path == "/Script/Angelscript.CrimeProcessingSubsystem_Human" then return subs.human end
        if path == "/Script/Angelscript.CrimeProcessingSubsystem_Orc" then return subs.orc end
      end
      return nil
    end
  end
  E.paths["/Script/Engine.Default__GameplayStatics"] = Statics
  E.paths["/Script/Engine.Default__SubsystemBlueprintLibrary"] = obj("SubsystemBlueprintLibrary /Script/Engine.Default__SubsystemBlueprintLibrary",
    { GetWorldSubsystem = subsystem("world"), GetGameInstanceSubsystem = subsystem("instance") })
  E.paths["/Script/GameStateSubsystem.Default__GameStateSubsystemBlueprintLibrary"] =
    obj("GameStateSubsystemBlueprintLibrary /Script/GameStateSubsystem.Default__GameStateSubsystemBlueprintLibrary", { GetGameStateSubsystem = subsystem("state") })
  E.paths["/Script/G1R.Default__WorldPointManager"] = obj("WorldPointManager /Script/G1R.Default__WorldPointManager", {
    GetInstance = function(self, world)
      assert(world == World, "GetInstance: not the world")
      H.engine.manager = H.engine.manager + 1
      if H.noManager then return nil end
      return Manager
    end })
  E.paths["/Script/G1R.InteractiveObjectActor"] = E.IOClass
  E.paths["/Script/G1R.GothicCharacterState"] = E.StateClass
  local found = _G.StaticFindObject
  _G.StaticFindObject = function(path)
    local o = E.paths[path]
    if o ~= nil then H.sfo.other = H.sfo.other + 1; return o end
    return found(path)
  end
  _G.RegisterLoadMapPostHook = function(cb) H.post = cb end
  _G.RegisterBeginPlayPostHook = function(cb) H.play.began = cb end
  _G.RegisterEndPlayPreHook = function(cb) H.play.ended = cb end
end
H.crimeSubs = function() return CrimeSubs end
H.crimeMemory = function() return CrimeMem end
-- A map load as the mod sees it. ENGINE: both hooks get the engine object, and
-- every actor of the old world ends play before the actors of the new one
-- begin it (the harness keeps its objects: the "new" world holds the same ones).
function E.mapLoad()
  if not ENGINE then H.pre(); return end
  H.pre(E.engineParam)
  for o in pairs(H.play.inPlay) do E.endPlay(o) end
  for _, a in ipairs(ActorsIO) do E.beginPlay(a) end
  for _, st in ipairs(States) do E.beginPlay(st) end
  if H.post then H.post(E.engineParam) end
end
-- After the mod's scripts were loaded: in the game the first map load follows (the mod starts before it).
function E.afterLoad()
  if not ENGINE then return end
  H.play.inPlay = {}
  E.mapLoad()
end

_G.REPOP_TEST = {}
dofile(DIR .. "main.lua")
local T = _G.REPOP_TEST
check(H.sfo.lib + H.sfo.ai + H.sfo.item + H.sfo.other == 0, "loading the mod searches nothing by path")
E.afterLoad()
-- What the mod asked for by path at the first map load (a quiet moment; in the plain run there is none: the
-- mod is in a running game and looks a path up when it is needed, as 1.3 did). The counts below start here.
H.sfoStart, H.sfo = H.sfo, { lib = 0, item = 0, other = 0, ai = 0 }
if ENGINE then
  check(H.sfoStart.lib == 1 and H.sfoStart.ai == 1 and H.sfoStart.item == 0 and H.sfoStart.other >= 8,
    ("ENGINE: at the first map load the mod looks up the two game libraries and the engine's objects by path (%d + %d + %d)"):format(H.sfoStart.lib, H.sfoStart.ai, H.sfoStart.other))
end
check(H.loop and H.loopMs == 250, "driver loop registered")
check(H.notify["/Script/G1R.InteractiveObjectActor"] ~= nil, "container notification registered")
check(H.console and H.console.repop, "console command registered")
local ld = lastLog("loaded:")
check(#H.KNAMES == 528, "528 container kinds in the data (" .. #H.KNAMES .. ")")
check(ld and ld:find("401 creature spawn points %(814 creatures%)") and ld:find("2495 item spots") and ld:find((#H.KNAMES + H.TEST_KINDS) .. " containers"), "load line: data counts (plus the test kinds)")

local function tick(realDt, gameDt)
  H.real = H.real + (realDt or 0.25)
  H.game = H.game + (gameDt or 0)
  H.loop()
end
local function ticks(n, realDt, gameDt) for _ = 1, n do tick(realDt, gameDt) end end


local CFG_TEXT = (function() local f = io.open(SRC .. "config.lua", "r"); local t = f:read("a"); f:close(); return t end)()
-- write DIR/config.lua = original text with plain substitutions applied
local function setConfig(subs)
  local t = CFG_TEXT
  for _, s in ipairs(subs or {}) do
    local a, b = t:find(s[1], 1, true)
    assert(a, "config pattern not found: " .. s[1])
    t = t:sub(1, a - 1) .. s[2] .. t:sub(b + 1)
  end
  local f = io.open(DIR .. "config.lua", "w"); f:write(t); f:close()
end
local function speciesBlock(body) return { "    Species = {\n    },", "    Species = {\n" .. body .. "    }," } end
local function countLogs(pat) local n = 0 for _, l in ipairs(H.logs) do if l:find(pat) then n = n + 1 end end return n end

-- ================================================================ start
print("== start: nothing before the delay, then state + item pass\n")
ticks(4)
check(lastLog("session started") == nil, "nothing during the start delay")
-- (searches are a second apart: the clock, the controller, then 8 s, the profile, the creature states, the item spots)
ticks(52)
check(lastLog("session started") ~= nil, "session started after the delay")
local it = lastLog("world items:")
check(it and it:find("spots set refillable"), "world item pass ran: " .. tostring(it))
local hc, lc, kc = cfgByName(herbName).m_ItemSpawnConfig, cfgByName(looseName).m_ItemSpawnConfig, cfgByName(keepName).m_ItemSpawnConfig
check(hc.m_Refillable == true and hc.m_RefillHours == 24, "herb spot: refillable, 24 h")
check(lc.m_Refillable == true and lc.m_RefillHours >= 24 and lc.m_RefillHours % 24 == 0 and lc.m_RefillHours <= 30 * 24, "loose spot: refillable, whole days (" .. lc.m_RefillHours .. " h)")
check(kc.m_Refillable == true and kc.m_RefillHours <= IDB[keepName].r, "vanilla refill spot: never slower than vanilla")
check(unknown.m_ItemSpawnConfig.m_Refillable == false and unknown.m_ItemSpawnConfig.m_RefillHours == 0, "quest / unlisted spot untouched")
check(cfgByName(P_FULL).m_ItemSpawnConfig.m_Refillable == false, "creature points untouched by the item pass")
-- distribution of loose hours ~ geometric(0.15), drawn from spot-name hashes
local function looseHours()
  local t = {}
  for name, spot in pairs(IDB) do if spot.p == "loose" then t[name] = cfgByName(name).m_ItemSpawnConfig.m_RefillHours end end
  return t
end
local sum, cnt, oneDay = 0, 0, 0
local H1 = looseHours()
for _, h in pairs(H1) do
  sum, cnt = sum + h / 24, cnt + 1
  if h == 24 then oneDay = oneDay + 1 end
end
check(sum / cnt > 5.0 and sum / cnt < 8.0, ("loose spots average %.2f days (expected ~6.6)"):format(sum / cnt))
check(oneDay / cnt > 0.11 and oneDay / cnt < 0.19, ("%.1f %% of loose spots come back after one day (expected ~15 %%)"):format(100 * oneDay / cnt))

print("== items: draws are fixed per spot and profile (reloads do not re-roll)\n")
setRandom(0.77)   -- must not matter: draws come from hashes
T.items.reset(); ticks(41)
local H2 = looseHours()
local same = true
for k, v in pairs(H1) do if H2[k] ~= v then same = false end end
check(same, "same hours after re-applying")
T.items.setSeed("profile_99"); T.items.reset(); ticks(41)
local H3, diff = looseHours(), 0
for k, v in pairs(H1) do if H3[k] ~= v then diff = diff + 1 end end
check(diff > cnt * 0.5, ("another profile draws differently (%d of %d spots differ)"):format(diff, cnt))
T.items.setSeed("profile_2"); T.items.reset(); ticks(41)

-- wrapped elements (param wrappers with :get()) also work
T.items.reset(); H.wrapElements = true
hc.m_RefillHours = 0
ticks(41)
check(hc.m_RefillHours == 24, "item pass works with wrapped array elements")
H.wrapElements = false

print("== items: turning a group off restores the game's values\n")
setConfig({ { "Config.WorldItems = {\n    Enabled = true,", "Config.WorldItems = {\n    Enabled = false," } })
check(T.reload(false) == true, "settings reloaded (world items off)")
ticks(41)
check(lc.m_Refillable == false and lc.m_RefillHours == 0, "loose spot back to vanilla (not refillable)")
check(kc.m_Refillable == true and kc.m_RefillHours == IDB[keepName].r, "vanilla refill spot back to its own hours")
check(hc.m_Refillable == true and hc.m_RefillHours == 24, "herbs unaffected")
check((lastLog("world items:") or ""):find("restored to the game's values"), "restore logged")
setConfig({ { "    RegrowHours = 24,", "    RegrowHours = 48," } })
check(T.reload(false) == true, "settings reloaded (herbs 48 h, world items on)")
ticks(41)
check(hc.m_RefillHours == 48 and lc.m_Refillable == true and lc.m_RefillHours == H1[looseName], "herbs 48 h, loose spot gets the same draw back")
setConfig({})
T.reload(false); ticks(41)
check(hc.m_RefillHours == 24, "defaults back")

print("== items: a pass writes only what differs; a spot that raised is tried again")
do
local herbCfg = cfgByName(herbName)
local plain, writes, failing = herbCfg.m_ItemSpawnConfig, 0, 0
herbCfg.m_ItemSpawnConfig = setmetatable({}, {
  __index = function(_, k) if failing > 0 then failing = failing - 1; error("spot raised on purpose") end return plain[k] end,
  __newindex = function(_, k, v) writes = writes + 1; plain[k] = v end })
T.items.reset(); ticks(41)
check(writes == 0 and plain.m_RefillHours == 24 and plain.m_Refillable == true and select(2, T.items.stats()) == true
  and (lastLog("world items:") or ""):find(", 0 written now,", 1, true) ~= nil,
  "a spot already set as wanted is not written again (" .. writes .. " writes)")
plain.m_RefillHours = 5
T.items.reset(); ticks(41)
check(writes == 2 and plain.m_RefillHours == 24 and (lastLog("world items:") or ""):find(", 1 written now,", 1, true) ~= nil,
  "a spot the game changed is written again, both values (" .. writes .. " writes), and the log says so")
plain.m_RefillHours, failing = 5, 1
T.items.reset(); ticks(41)
local s1, done1 = T.items.stats()
check(done1 == false and s1.errors == 1 and plain.m_RefillHours == 5 and lc.m_Refillable == true, "one spot raised: the others are set, the pass is not done")
ticks(41)
local s2, done2 = T.items.stats()
check(done2 == true and s2.errors == 0 and plain.m_RefillHours == 24, "ten seconds later the whole list is looked at again and the spot is set")
failing = 1e9
T.items.reset(); ticks(41)
local _, doneA = T.items.stats()
ticks(41)
local _, doneB = T.items.stats()
ticks(41)
local _, doneC = T.items.stats()
check(doneA == false and doneB == false and doneC == true, "a spot that keeps raising: given up after three passes in a row (then the pass counts as done)")
failing = 0
herbCfg.m_ItemSpawnConfig = plain
end

-- ================================================================ creatures
print("== creatures: census at the next 24 h boundary (normal and elite both every 24 h)\n")
function KU_dist(a, b) local dx, dy = a[1] - b[1], a[2] - b[2]; return dx * dx + dy * dy end
local function nextBoundary(hours) return (math.floor(H.game / (hours * 3600)) + 1) * hours * 3600 end
local function countAt(pt) local n = 0 for _, s in ipairs(H.spawns) do if s.point == pt then n = n + 1 end end return n end
-- no test spot may be within 40 m of the parked player position
local PARK = { 100000, -100000, 0 }
for _, pt in ipairs({ P_FULL, P_HALF, P_EMPTY, P_SPATIAL, P_ELITE }) do
  assert(KU_dist({ CDB[pt].x, CDB[pt].y }, PARK) > 6000 * 6000, "test point too close to the parked player: " .. pt)
end
setRandom(0.0)
H.spawns, H.removed = {}, 0
H.game = nextBoundary(24) + 10
ticks(80)
local cyc = lastLog("creature cycle")
check(cyc ~= nil and cyc:find("due 24h x1"), "creature cycle logged: " .. tostring(cyc))
local seen = T.state.seen
check(seen[P_FULL] and seen[P_HALF] and seen[P_EMPTY] and seen[P_SPATIAL], "points with creatures (alive or dead) marked populated")
check(not seen[P_NEVER], "never-visited point not marked")
local per = {}
for _, s in ipairs(H.spawns) do per[s.point or "library"] = (per[s.point or "library"] or 0) + 1 end
check((per[P_FULL] or 0) == 0, "full point: nothing spawned")
check((per[P_SPATIAL] or 0) == 0, "point populated by token-less creatures: nothing spawned (spatial census)")
check((per[P_NEVER] or 0) == 0, "never-visited point: nothing spawned")
check((per[P_EMPTY] or 0) == 1, "emptied single point: 1 spawned at its own world point")
check((per["library"] or 0) == CDB[P_HALF].s[1].n - 1, ("half point without script instance: %d spawned through the library"):format(per["library"] or 0))
local libSpawn
for _, s in ipairs(H.spawns) do if s.how == "library" then libSpawn = s end end
check(libSpawn and math.abs(libSpawn.pos.X - CDB[P_HALF].x) < 300 and math.abs(libSpawn.pos.Y - CDB[P_HALF].y) < 300, "library spawn placed at the spawn point")
check(CDB[P_HALF].s[1].n - 1 >= 2 and H.sfo.ai == (ENGINE and 0 or 1),
  ("the AI script library was looked up once for all %d of them - at the first map load, or when it was first needed (%d searches since the start)"):format(CDB[P_HALF].s[1].n - 1, H.sfo.ai))
check(countAt(P_ELITE) == 1, "elite (every 24 h now) respawned in the same cycle")
-- corpses: one removed per respawn, from the same spot and species
local emptyState
for _, s in ipairs(States) do if s.__id and s.__id:find(P_EMPTY, 1, true) then emptyState = s end end
check(emptyState and emptyState.__removed == true, "corpse at the emptied point removed when its successor appeared")
local halfRemoved = 0
for _, s in ipairs(States) do if s.__id and s.__id:find(P_HALF, 1, true) and s.__removed then halfRemoved = halfRemoved + 1 end end
check(halfRemoved == CDB[P_HALF].s[1].n - 1, ("half point: %d corpses removed for %d respawns"):format(halfRemoved, CDB[P_HALF].s[1].n - 1))
check(H.removed == CDB[P_HALF].s[1].n - 1 + 2, "no other corpse touched (" .. H.removed .. ")")
local living = 0
for _, s in ipairs(States) do if s.__id and s.__id:find(P_HALF, 1, true) and not s.__dead and s.__removed then living = living + 1 end end
check(living == 0, "living creatures never removed")
check(T.status()[2]:find(("%d corpses removed"):format(H.removed)), "status counts removed corpses")

print("== creatures: rolls fail at 0.99\n")
setRandom(0.99)
H.spawns = {}
H.game = nextBoundary(24) + 10
ticks(80)
check(#H.spawns == 0, "no spawns when every roll fails")

print("== creatures: player too close -> wait\n")
setRandom(0.0)
H.spawns = {}
H.player = { CDB[P_EMPTY].x + 500, CDB[P_EMPTY].y, 0 }
H.game = nextBoundary(24) + 10
ticks(80)
check(countAt(P_EMPTY) == 0, "no spawn while the player stands at the spot")
local knownAt = Pawn.K2_GetActorLocation
Pawn.K2_GetActorLocation = function() return nil end
ticks(120, 0.5)
check(countAt(P_EMPTY) == 0, "no spawn while it cannot be read where the player is (not known is not far away)")
Pawn.K2_GetActorLocation = knownAt
H.player = { PARK[1], PARK[2], 0 }
ticks(120, 0.5)
check(countAt(P_EMPTY) == 1, "spawned after the player left (" .. countAt(P_EMPTY) .. ")")

print("== creatures: catch-up after long sleep\n")
H.spawns = {}
H.game = nextBoundary(24) + 3 * 86400 + 10
ticks(80)
local cyc2 = lastLog("creature cycle")
check(cyc2 and cyc2:find("due 24h x3"), "a 3+ day sleep counts as 3 catch-up cycles: " .. tostring(cyc2))

print("== creatures: per-species interval (elite species every 14 h)\n")
local eliteU = CDB[P_ELITE].s[1].u
setConfig({ speciesBlock(('        ["%s"] = { EveryHours = 14 },\n'):format(eliteU)) })
check(T.reload(false) == true and (lastLog("settings reloaded") or ""):find("1 species with own settings"), "override loaded")
for k in pairs(T.state.recent) do T.state.recent[k] = nil end
local eliteState
for _, s in ipairs(States) do if s.__id and s.__id:find(P_ELITE, 1, true) then eliteState = s end end
eliteState.__dead, eliteState.__removed = true, false
for _, s in ipairs(States) do if s.__id and s.__id:find(P_EMPTY, 1, true) then s.__dead, s.__removed = true, false end end
ticks(1)   -- the new 14 h interval starts counting (in play this happens right after the reload)
local t14 = nextBoundary(14)
while t14 % 86400 == 0 or math.floor(t14 / 86400) ~= math.floor(H.game / 86400) do
  -- stay within the current day so no 24 h boundary is crossed
  if t14 % 86400 ~= 0 and math.floor(t14 / 86400) ~= math.floor(H.game / 86400) then break end
  t14 = t14 + 14 * 3600
end
H.spawns = {}
H.game = t14 + 10
ticks(80)
local c3 = lastLog("creature cycle")
check(c3 and c3:find("due 14h x1") and not c3:find("24h"), "14 h cycle for the overridden species only: " .. tostring(c3))
local elitePts, normalPts = 0, 0
for _, s in ipairs(H.spawns) do
  local p = CDB[s.point or ""]
  if p then if p.s[1].u == eliteU then elitePts = elitePts + 1 else normalPts = normalPts + 1 end end
end
check(elitePts >= 1 and normalPts == 0, ("14 h cycle respawns that species only (%d elite, %d other)"):format(elitePts, normalPts))
check(eliteState.__removed == true, "its corpse removed too")
-- a 24 h boundary that is not a 14 h boundary: normal species roll, the elite does not
for k in pairs(T.state.recent) do T.state.recent[k] = nil end
eliteState.__dead, eliteState.__removed = true, false
local t24 = nextBoundary(24)
while t24 % (14 * 3600) == 0 do t24 = t24 + 86400 end
H.spawns = {}
H.game = t24 + 10
ticks(120, 0.5)
local c4 = lastLog("creature cycle")
check(c4 and c4:find("due 24h x1") and not c4:find("14h"), "24 h cycle: " .. tostring(c4))
check(countAt(P_ELITE) == 0 and countAt(P_EMPTY) == 1, "24 h cycle: normal species back, overridden elite waits for its own interval")

print("== creatures: species switched off\n")
local emptyU = CDB[P_EMPTY].s[1].u
setConfig({ speciesBlock(('        ["%s"] = { Enabled = false },\n'):format(emptyU)) })
T.reload(false)
for k in pairs(T.state.recent) do T.state.recent[k] = nil end
for _, s in ipairs(States) do if s.__id and s.__id:find(P_EMPTY, 1, true) then s.__dead, s.__removed = true, false end end
eliteState.__dead, eliteState.__removed = true, false
H.spawns = {}
T.console("repop now", nil, nil)
ticks(120, 0.5)
check(countAt(P_EMPTY) == 0, "switched-off species not respawned")
check(countAt(P_ELITE) == 1, "other species still respawn")
local stillDead = true
for _, s in ipairs(States) do if s.__id and s.__id:find(P_EMPTY, 1, true) and s.__removed then stillDead = false end end
check(stillDead, "corpse of a species that does not respawn stays")

print("== creatures: corpse next to the player stays; corpse removal can be switched off\n")
setConfig({})
T.reload(false)
local P_CORPSE, P_KEEP = single[4], single[5]
local corpse = addState(CDB[P_CORPSE].s[1].u, P_CORPSE, 1, { dead = true, pos = { CDB[P_CORPSE].x + 6000, CDB[P_CORPSE].y, 0 } })
H.player = { CDB[P_CORPSE].x + 6500, CDB[P_CORPSE].y, 0 }
for k in pairs(T.state.recent) do T.state.recent[k] = nil end
H.spawns = {}
T.console("repop now", nil, nil)
ticks(160, 0.5)
check(countAt(P_CORPSE) == 1, "creature respawned 65 m away from the player")
check(corpse.__removed ~= true, "its corpse 5 m from the player was left alone")
H.player = { PARK[1], PARK[2], 0 }
setConfig({ { "    RemoveCorpsesOnRespawn = true,", "    RemoveCorpsesOnRespawn = false," } })
T.reload(false)
local keepCorpse = addState(CDB[P_KEEP].s[1].u, P_KEEP, 1, { dead = true })
H.spawns = {}
T.console("repop now", nil, nil)
ticks(160, 0.5)
check(countAt(P_KEEP) == 1 and keepCorpse.__removed ~= true, "RemoveCorpsesOnRespawn = false keeps corpses")
setConfig({})
T.reload(false)

print("== creatures: a corpse goes once the game's lookup has found the creature that came back")
do
  H.player = { PARK[1], PARK[2], 0 }
  local P_LOST, P_NONE = single[6], single[7]
  local lost = addState(CDB[P_LOST].s[1].u, P_LOST, 1, { dead = true })
  local s0 = T.creatures.stats()
  local confirmedBefore, unconfirmedBefore = s0.confirmed, s0.unconfirmed
  H.npcFind = function(s) return s ~= "spawned-" .. P_LOST end
  for k in pairs(T.state.recent) do T.state.recent[k] = nil end
  H.spawns = {}
  T.console("repop now", nil, nil)
  ticks(160, 0.5)
  H.npcFind = nil
  if H.noNpcLookup then
    check(countAt(P_LOST) == 1 and lost.__removed == true and T.creatures.stats().confirmed == 0,
      "without the game's lookup by unique name the corpse goes at once, as before (nothing confirmed)")
  else
    check(confirmedBefore > 0, "(the lookup by unique name has found spawned creatures before: " .. confirmedBefore .. ")")
    check(countAt(P_LOST) == 1 and lost.__removed ~= true and T.creatures.stats().unconfirmed == unconfirmedBefore + 1,
      "the creature was spawned but the lookup does not find it: its corpse stays")
    local noneCorpse = addState(CDB[P_NONE].s[1].u, P_NONE, 1, { dead = true })
    H.noneAt = P_NONE
    for k in pairs(T.state.recent) do T.state.recent[k] = nil end
    H.spawns = {}
    local failedBefore = T.creatures.stats().failed
    T.console("repop now", nil, nil)
    ticks(160, 0.5)
    H.noneAt = nil
    check(countAt(P_NONE) == 0 and noneCorpse.__removed ~= true and T.creatures.stats().failed > failedBefore and T.state.recent[P_NONE] == nil,
      '"None" handed back: no spawn counted, its corpse stays, no recent spawn noted')

    -- the look for the creature, step by step (an entry is put in the way spawnStep puts it)
    local K, S = T.creatures.confirmState(), T.creatures.stats()
    local uL = CDB[P_LOST].s[1].u
    local function clear() for i = #K.pending, 1, -1 do K.pending[i] = nil end end
    local function push(name, age, extra)
      local e = { name = name, point = P_LOST, unique = uL, at = H.real - age }
      for k, v in pairs(extra or {}) do e[k] = v end
      K.pending[#K.pending + 1] = e
      return e
    end
    clear(); K.works = true
    local n0, c0 = H.npcLookups, S.confirmed
    push("spawned-" .. P_LOST, 1.5)
    tick()
    check(H.npcLookups == n0 and #K.pending == 1, "not looked up before 2 s after the spawn")
    tick()
    check(H.npcLookups == n0 + 1 and #K.pending == 0 and S.confirmed == c0 + 1 and lost.__removed == true,
      "at 2 s it is looked up; found: counted once, and now its corpse goes")
    H.spawnedNames["spawned-" .. P_NONE] = true
    local c2 = S.confirmed
    push("spawned-" .. P_NONE, 3, { probe = true, point = P_NONE, unique = CDB[P_NONE].s[1].u })
    tick()
    check(S.confirmed == c2 + 1 and #K.pending == 0 and noneCorpse.__removed ~= true,
      "one of the first spawns of a run found: its corpse went at the spawn already, no second one goes")
    H.npcFind = function(s) return s ~= "nobody" end
    local u0 = S.unconfirmed
    push("nobody", 1.75)
    tick()
    local n1 = H.npcLookups
    ticks(3)
    check(H.npcLookups == n1, "not found: not asked again within the second")
    tick()
    check(H.npcLookups == n1 + 1 and #K.pending == 1, "asked again a second later")
    clear()
    push("nobody", 19.75, { tried = H.real - 5 })
    tick()
    check(#K.pending == 0 and S.unconfirmed == u0 + 1, "given up 20 s after the spawn: not found, its corpse stays")
    clear()
    local c1 = S.confirmed
    push("spawned-" .. P_LOST, 0.5); push("spawned-" .. P_LOST, 3); push("spawned-" .. P_LOST, 3)
    tick()
    check(#K.pending == 1 and S.confirmed == c1 + 2, "two entries that are due are both done in one update, one not due yet waits")
    clear()
    -- the first spawns of a run, before the lookup is known: three of them are looked up, then it is decided
    clear(); K.works, K.misses = nil, 0
    push("nobody", 19.75, { probe = true, tried = H.real - 5 }); push("nobody", 19.75, { probe = true, tried = H.real - 5 })
    tick()
    check(K.misses == 2 and K.works == nil, "two of the first spawns not found: not decided yet")
    push("nobody", 19.75, { probe = true, tried = H.real - 5 })
    tick()
    check(K.misses == 3 and K.works == false, "the third not found either: the lookup does not know these names (corpses go at once again)")
    -- a lookup that raises, a found creature after that, a lookup object gone, no controller, a search not due yet
    clear(); K.works = true
    H.npcFind = function(s) if s == "boom" then error("lookup raised on purpose") end return true end
    push("boom", 3)
    tick()
    check(K.works == false and #K.pending == 0, "the lookup raised: corpses go at once again, the entry is done")
    push("spawned-" .. P_LOST, 3)
    tick()
    check(K.works == true, "a creature found later: the lookup is used again")
    H.npcFind = nil
    H.npcCDO.__valid = false
    push("spawned-" .. P_LOST, 3)
    tick()
    check(K.works == false and #K.pending == 0, "the lookup's object gone: not available, the entry is done")
    H.npcCDO.__valid = nil
    clear(); K.works = true
    local realController = T.util.controller
    T.util.controller = function(...) if debug.traceback():find("lookUp", 1, true) then return nil end return realController(...) end
    push("spawned-" .. P_LOST, 3)
    tick()
    check(#K.pending == 1, "no controller to ask with: the entry waits")
    T.util.controller = realController
    clear()
    local realMayWalk, oldLookup = T.util.mayWalk, K.lookup
    K.lookup = nil
    T.util.mayWalk = function(...) if debug.traceback():find("lookUp", 1, true) then return false end return realMayWalk(...) end
    push("spawned-" .. P_LOST, 3)
    tick()
    check(#K.pending == 1 and K.lookup == nil, "the lookup not searched for yet and no search due: the entry waits")
    T.util.mayWalk = realMayWalk
    ticks(40)
    check(#K.pending == 0 and K.lookup == oldLookup, "searched for once a search is due, then used")
    -- how many of the first spawns are looked up, and a name that cannot be read
    clear(); K.works, K.probes, K.misses = nil, 0, 0
    for k in pairs(T.state.recent) do T.state.recent[k] = nil end
    H.spawns = {}
    H.npcFind = function() return false end       -- (not found while they come: nothing is decided by a find)
    T.console("repop now", nil, nil)
    ticks(160, 0.5)
    H.npcFind = nil
    check(#H.spawns > 3 and K.probes == 3 and K.misses == 3 and K.works == false, "of the first spawns of a run, three are looked up; none found: decided against the lookup (" .. #H.spawns .. " spawned, " .. K.probes .. " looked up)")
    clear(); K.works = true
    local P_NIL = single[8]
    local nilCorpse = addState(CDB[P_NIL].s[1].u, P_NIL, 1, { dead = true })
    H.nilAt = P_NIL
    for k in pairs(T.state.recent) do T.state.recent[k] = nil end
    H.spawns = {}
    T.console("repop now", nil, nil)
    ticks(160, 0.5)
    H.nilAt = nil
    check(countAt(P_NIL) == 1 and nilCorpse.__removed == true, "a spawn whose name cannot be read: its corpse goes at once, as before")
  end
end

print("== creatures: how long a respawn waits for the player to move away")
do
  setConfig({ { "    MinPlayerDistance = 4000,", "    MinPlayerDistance = 4000," .. string.char(10) .. "    MaxDeferrals = 2," } })
  T.reload(false)
  local S = T.creatures.stats()
  local function missingNear(p)
    -- first everything else that is missing comes (the player away), so that this point's job is the only one
    H.player = { PARK[1], PARK[2], 0 }
    T.console("repop now", nil, nil)
    ticks(160, 0.5)
    for _, s in ipairs(States) do if s.__id and s.__id:find(p, 1, true) then s.__dead, s.__removed = true, false end end
    T.state.recent[p] = nil       -- (only this point: the harness's spawns leave no creature, the recent list stands for them)
    T.state.seen[p] = true        -- (a point the mod has seen populated)
    H.player = { CDB[p].x + 500, CDB[p].y, 0 }
    local d0 = S.deferred
    T.console("repop now", nil, nil)
    local n = 0
    while S.deferred == d0 and n < 600 do tick(); n = n + 1 end
    return d0
  end
  local P_D1, P_D2, P_D3 = single[9], single[10], single[11]
  H.spawns = {}
  local d0 = missingNear(P_D1)
  check(S.deferred == d0 + 1 and countAt(P_D1) == 0, "the player at the spot: the respawn waits (counted once)")
  ticks(79)
  H.player = { PARK[1], PARK[2], 0 }
  ticks(2)
  check(countAt(P_D1) == 1, "looked at again 20 s later: the player has gone, it comes")
  d0 = missingNear(P_D2)
  ticks(80)
  check(S.deferred == d0 + 2 and countAt(P_D2) == 0, "(MaxDeferrals = 2: a second wait)")
  ticks(40)
  H.player = { PARK[1], PARK[2], 0 }
  ticks(80)
  check(countAt(P_D2) == 1, "after two waits it still comes")
  d0 = missingNear(P_D3)
  ticks(176)
  H.player = { PARK[1], PARK[2], 0 }
  ticks(160)
  check(countAt(P_D3) == 0, "a third time near: the respawn is given up (the next cycle brings it back)")
  setConfig({})
  T.reload(false)
end

print("== settings: picked up automatically while playing\n")
setConfig({ { "    NormalChance = 0.35,", "    NormalChance = 0.50," } })
local before = countLogs("settings reloaded")
ticks(70)   -- 17.5 s
check(countLogs("settings reloaded") == before + 1, "changed config.lua reloaded within 15 s")
local _, ccfg = T.config()
check(ccfg.NormalChance == 0.50, "new chance active")
local f = io.open(DIR .. "config.lua", "w"); f:write("local Config = {\n  oops = \n"); f:close()
ticks(70)
check(countLogs("has an error, keeping the previous settings") == 1, "broken config.lua reported once")
ticks(70)
check(countLogs("has an error, keeping the previous settings") == 1, "not reported again while unchanged")
local _, ccfg2 = T.config()
check(ccfg2.NormalChance == 0.50, "previous settings kept")
setConfig({})
ticks(70)
local _, ccfg3 = T.config()
check(ccfg3.NormalChance == 0.35, "fixed config.lua reloaded")

print("== creatures: evidence scans between cycles\n")
local P_EV = single[3]
check(not T.state.seen[P_EV], "evidence point unknown at first")
local evs = addState(CDB[P_EV].s[1].u, P_EV, 1)
ticks(6 * 60 * 4 + 40)  -- > 5 real minutes
check(T.state.seen[P_EV], "evidence scan marked the populated point")
E.removeState(evs)      -- killed and removed before the next cycle
setRandom(0.0)
H.spawns = {}
H.player = { PARK[1], PARK[2], 0 }
H.game = nextBoundary(24) + 10
ticks(160, 0.5)
check(countAt(P_EV) == 1, "point cleared between cycles still refills (" .. countAt(P_EV) .. ")")

print("== creatures: recent respawns count as present for 30 h\n")
setRandom(0.0)
T.creatures.reset()
for k in pairs(T.state.recent) do T.state.recent[k] = nil end
for _, s in ipairs(States) do if s.__id and s.__id:find(P_EMPTY, 1, true) then s.__dead, s.__removed = true, false end end
H.spawns = {}
H.game = nextBoundary(24) + 10
ticks(4)
H.game = nextBoundary(24) + 10
ticks(120, 0.5)
check(countAt(P_EMPTY) == 1 and T.state.recent[P_EMPTY] ~= nil, "respawned once and remembered")
H.spawns = {}
T.console("repop now", nil, nil)
ticks(120, 0.5)
check(countAt(P_EMPTY) == 0, "forced cycle within 30 h: not spawned again although the census still sees it missing")
H.game = H.game + 31 * 3600
T.console("repop now", nil, nil)
ticks(120, 0.5)
check(countAt(P_EMPTY) == 1, "after 30 h the remembered spawn expires and the point refills again")
T.state.recent[P_EMPTY] = { [CDB[P_EMPTY].s[1].u] = { n = 1, t = H.game + 50 * 86400 } }
H.spawns = {}
T.console("repop now", nil, nil)
ticks(120, 0.5)
check(countAt(P_EMPTY) == 1, "entries from an older save's future are ignored")

-- ================================================================ containers
print("== containers\n")
local rwKey
do
local NEW_IO = "/Script/G1R.InteractiveObjectActor"
local function recOf(name) for k, r in pairs(T.state.chests) do if k:find(name .. "@", 1, true) == 1 then return r, k end end end
local function chestStats() return (T.chests.stats()) end
T.chests.reset()
H.player = { Settle.pos[1] + 200, Settle.pos[2], 0 }
ticks(30)
check(select(2, T.chests.stats()) == 2, "two containers recognised through the game's getter (chairs ignored)")
check(next(T.state.chests) == nil, "full containers: nothing recorded")
check((lastLog("containers: 2 here") or "") ~= "", "one line in the log after the first pass: " .. tostring(lastLog("containers: ")))
-- loot the settlement chest completely, and store an own item
playerOpens(Settle, function(items) takeDefaults(Settle)(items); items["ItMw_PlayerStash"] = 3 end)
ticks(4)
local srec, key = recOf(settleName)
check(srec and srec.d and not srec.r and not srec.f, "looted chest noticed within a second (normal daily rolls)")
check(lastLog("containers: first emptied container noticed %(" .. settleName) ~= nil, "first emptied container is logged")
setRandom(0.2)
H.game = H.game + 86400 + 60
ticks(30)
srec = recOf(settleName)
check(srec and srec.p == true and not isFull(Settle), "roll won (0.2 < 30 %), but nothing is put in while the player stands 2 m away")
H.player = { Settle.pos[1] + 1500, Settle.pos[2], 0 }
ticks(30)
srec = recOf(settleName)
check(isFull(Settle), "restocked once the player has moved away: original contents back")
check(srec and srec.f and not srec.d and not srec.p, "remembered as restocked, not opened yet")
check(Settle.actor.__dm.__items["ItMw_PlayerStash"] == 3, "player's own items untouched")
check(H.io.serverCalls == 0 and H.io.predicted == 0, "added with the game's hosting-side call only (Multicast_AddNewItem, not predicted)")
check(lastLog("restocked " .. settleName .. " %(settlement%)") ~= nil, "restock logged")
check(chestStats().refilled == 1, "counted as one restock")
ticks(40)
check(recOf(settleName) and recOf(settleName).f and isFull(Settle), "stays as it is while loaded (no second restock, note kept)")

print("== containers: a restock the game has not saved yet\n")
-- the game only saves a container when it is opened: unloaded and loaded
-- again, the chest is back in its looted state
local addedBefore = H.added
streamOut(Settle)
ticks(12)
streamIn(Settle)
check(not isFull(Settle), "model: the chest streams back in with its saved (looted) contents")
H.notify[NEW_IO](Settle.actor)
setRandom(0.99)             -- no roll could succeed now
ticks(60)
check(isFull(Settle) and recOf(settleName) and recOf(settleName).f, "same items put back without a new roll, note kept")
check(chestStats().restored == 1 and chestStats().refilled == 1, "counted as put back, not as a new restock")
check(Settle.actor.__dm.__items["ItMw_PlayerStash"] == 3, "player's own items still there")
-- the player opens it and takes nothing: now the game has saved the full chest
playerOpens(Settle)
streamOut(Settle)
ticks(12)
streamIn(Settle)
H.notify[NEW_IO](Settle.actor)
ticks(60)
check(isFull(Settle) and recOf(settleName) == nil, "after the player opened it the game keeps the contents; the note is dropped")
-- restock again, then the player loots it while it is loaded
playerOpens(Settle, takeDefaults(Settle))
ticks(8)
setRandom(0.2)
H.game = H.game + 86400 + 60
ticks(40)
check(isFull(Settle) and recOf(settleName).f, "restocked a second time")
playerOpens(Settle, takeDefaults(Settle))
ticks(8)
srec = recOf(settleName)
check(srec and srec.d and not srec.f and srec.n > H.game, "looted again while loaded: back to waiting for the daily roll")
setRandom(0.99)
streamOut(Settle); ticks(12); streamIn(Settle); H.notify[NEW_IO](Settle.actor); ticks(60)
check(not isFull(Settle), "and nothing is put back for a container that is merely waiting")
setRandom(0.2)

print("== containers: wild chests, rolls while unloaded\n")
H.player = { Wild.pos[1] + 1500, Wild.pos[2], 0 }
playerOpens(Wild, takeDefaults(Wild))
ticks(10)
local wrec, wkey = recOf(wildName)
check(wrec ~= nil, "emptied wild chest recorded")
H.game = H.game + 86400 + 60
ticks(30)
check(recOf(wildName) and not recOf(wildName).p and not recOf(wildName).f, "wild chest: 0.2 roll loses against 10 %")
setRandom(0.05)
H.game = H.game + 86400 + 60
ticks(30)
check(isFull(Wild) and recOf(wildName).f, "wild chest restocked after a later won roll")
playerOpens(Wild, takeDefaults(Wild))
ticks(10)
streamOut(Wild)
H.player = { 0, 0, 0 }
ticks(10)
H.game = H.game + 86400 + 60
ticks(30)
check(recOf(wildName) and recOf(wildName).p == true, "roll happens while the container is not loaded")
streamIn(Wild)
H.notify[NEW_IO](Wild.actor)
ticks(60)
check(isFull(Wild) and recOf(wildName).f, "restocked when it streamed back in")

print("== containers: looted before the mod saw them (retroactive)\n")
local settle2, wild2, settle3, settle4, settle5, settle6
for _, n in ipairs(H.KNAMES) do
  local d = KDB[n]
  if n ~= settleName and n ~= wildName and d.k == "chest" and #d.i >= 2 then
    if d.s and not settle2 then settle2 = n
    elseif d.s and not settle3 then settle3 = n
    elseif d.s and not settle4 then settle4 = n
    elseif d.s and not settle5 then settle5 = n
    elseif d.s and not settle6 then settle6 = n
    elseif not d.s and not wild2 then wild2 = n end
  end
end
local function emptied(name) local t = {} for _, it in ipairs(KDB[name].i) do t[it[1]] = 0 end return t end
H.savedInv[settle2] = emptied(settle2)          -- looted in an earlier game session
H.savedInv[wild2] = emptied(wild2)
local RS = makeChest(settle2, 150000, -150000, KDB[settle2].i)
local RW = makeChest(wild2, 160000, -150000, KDB[wild2].i)
setRandom(0.5)
H.notify[NEW_IO](RS.actor)
H.notify[NEW_IO](RW.actor)
H.player = { 0, 0, 0 }
local tRetro = H.game
ticks(80)
check(isFull(RS) and recOf(settle2) and recOf(settle2).f, "settlement container found empty: restocked right away (3-day catch-up 66 % > 0.5)")
local rwRec
rwRec, rwKey = recOf(wild2)
check(rwRec and rwRec.r == true and not rwRec.p and not rwRec.f, "wild container found empty: retro roll lost (27 % < 0.5), stays waiting")
check(rwRec and rwRec.n >= tRetro + 86400 - 120, "then rolls daily as usual")
check(chestStats().retro == 2, "2 containers counted as found already emptied")
setConfig({ { "    RetroactiveDays = 3,", "    RetroactiveDays = 0," } })
T.reload(false)
H.savedInv[settle3] = emptied(settle3)
local RS3 = makeChest(settle3, 170000, -150000, KDB[settle3].i)
H.notify[NEW_IO](RS3.actor)
setRandom(0.0)
ticks(80)
local r3 = recOf(settle3)
check(r3 and not r3.r and not r3.p and not r3.f and r3.n > H.game, "RetroactiveDays = 0: clock starts when first seen")
setConfig({})
T.reload(false)

print("== containers: finding the definition\n")
local seenBefore = select(2, T.chests.stats())
local LATE = makeChest(settle4, 180000, -150000, KDB[settle4].i, { readyAfter = 9 })
H.notify[NEW_IO](LATE.actor)
ticks(12)      -- 3 s: looked at once, not ready
check(select(2, T.chests.stats()) == seenBefore, "definition not there yet: not registered")
ticks(60)      -- ready after 9 s, next looks at 4 s / 8 s / 16 s
check(select(2, T.chests.stats()) == seenBefore + 1, "looked at again later and registered")
H.io.noGetter = true
local COMP = makeChest(settle5, 190000, -150000, KDB[settle5].i)
H.notify[NEW_IO](COMP.actor)
ticks(20)
H.io.noGetter = false
check(select(2, T.chests.stats()) == seenBefore + 2, "getter unavailable: definition taken from the interactive component")
local MIXED = makeChest(settle6, 200000, -150000, KDB[settle6].i, { className = settle6:sub(1, 3) .. settle6:sub(4):lower() })
H.notify[NEW_IO](MIXED.actor)
ticks(20)
check(select(2, T.chests.stats()) == seenBefore + 3, "class name in different letter case still matches (" .. MIXED.className .. ")")
check(H.io.banned == 0, "none of the properties this UE4SS build logs on every read was touched (" .. H.io.banned .. ")")

print("== containers: when adding or counting does not work\n")
H.player = { LATE.pos[1] + 1500, LATE.pos[2], 0 }
playerOpens(LATE, takeDefaults(LATE))
ticks(40)
check(recOf(settle4) and recOf(settle4).d, "emptied container noticed")
H.player = { 0, 0, 0 }
setRandom(0.0)
H.game = H.game + 86400 + 60
H.io.addFails = true
local failed0 = chestStats().failed
ticks(600)                         -- far away: the round robin gets to it
H.io.addFails = false
local lrec = recOf(settle4)
check(not isFull(LATE) and lrec and lrec.d and not lrec.p and not lrec.f, "nothing arrived: not marked as restocked, back to waiting")
check(lastLog("restocking " .. settle4 .. " did not work %(0 of") ~= nil, "failure logged with the numbers")
check(chestStats().failed > failed0, "counted as failed")
local failed1 = chestStats().failed
local multiAfterFail = H.io.multiCalls
H.game = H.game + 86400 + 60
ticks(600)
check(H.io.multiCalls == multiAfterFail and not isFull(LATE), "not tried again on that container in this session")
-- part of it arrives
H.player = { COMP.pos[1] + 1500, COMP.pos[2], 0 }
playerOpens(COMP, takeDefaults(COMP))
ticks(40)
H.player = { 0, 0, 0 }
H.game = H.game + 86400 + 60
H.io.addPartial = KDB[settle5].i[1][1]
ticks(600)
H.io.addPartial = false
check(not isFull(COMP) and recOf(settle5) and recOf(settle5).d and not recOf(settle5).f and chestStats().failed == failed1 + 1,
  "only part arrived: treated as failed, container keeps waiting")
-- counting variants
local cobj = H.itemClass(KDB[settleName].i[1][1])
local want1 = KDB[settleName].i[1][2]
Settle.actor.__dm.__items[KDB[settleName].i[1][1]] = want1
check(T.chests._countOne(Settle.actor.__dm, cobj, want1) == want1, "count from the game's out parameter")
H.io.outMode = "wrapped"
check(T.chests._countOne(Settle.actor.__dm, cobj, want1) == want1, "count delivered as a parameter object")
H.io.outMode = "none"
Settle.actor.__dm.__items[KDB[settleName].i[1][1]] = 37
check(T.chests._countOne(Settle.actor.__dm, cobj, 50) == 37 and T.chests._countOne(Settle.actor.__dm, cobj, 20) == 20, "no count returned: yes / no answers narrow it down")
Settle.actor.__dm.__items[KDB[settleName].i[1][1]] = 0
check(T.chests._countOne(Settle.actor.__dm, cobj, 5) == 0, "(empty)")
H.io.outMode = "count"
H.io.hasThrows = true
check(T.chests._countOne(Settle.actor.__dm, cobj, 5) == nil, "function not callable: no count")
streamOut(MIXED); ticks(12); streamIn(MIXED); H.notify[NEW_IO](MIXED.actor)
local recsBefore = 0
for _ in pairs(T.state.chests) do recsBefore = recsBefore + 1 end
ticks(80)
H.io.hasThrows = false
local recsAfter = 0
for _ in pairs(T.state.chests) do recsAfter = recsAfter + 1 end
check(recOf(settle6) == nil and recsAfter == recsBefore and chestStats().unreadable >= 1, "container that cannot be counted is left alone (no record)")
check(countLogs("cannot be counted") == 1, "and that is said once")
check(H.io.banned == 0, "still no read of a logged property")
-- a note from a later point in time than the loaded save: dropped
Settle.actor.__dm.__items[KDB[settleName].i[1][1]] = want1
do
  local _, skey = recOf(settleName)
  if skey then T.state.chests[skey] = nil end
  playerOpens(Settle, takeDefaults(Settle))
  streamOut(Settle); ticks(12); streamIn(Settle); H.notify[NEW_IO](Settle.actor)
  local kk = ("%s@%d,%d"):format(settleName, math.floor(Settle.pos[1] / 100 + 0.5), math.floor(Settle.pos[2] / 100 + 0.5))
  T.state.chests[kk] = { f = H.game + 5 * 86400 }
  setRandom(0.99)
  H.player = { 0, 0, 0 }
  ticks(600)
  local r = recOf(settleName)
  check(r and r.r == true and not r.f and not isFull(Settle), "restock note from the future of a loaded save is dropped; the container starts over")
  setRandom(0.2)
end
check((T.status()[4] or ""):find("^containers: %d+ here %(%d+ objects looked at%), %d+ waiting to restock"), "status line: " .. tostring(T.status()[4]))

print("== containers: item classes come from the game's own container data\n")
;(function()
  check(H.sfo.item == 0, "no item class was searched for by name (" .. H.sfo.item .. " searches)")
  check(H.sfo.lib == 0, "the function library is not searched while the object's own module list works (" .. H.sfo.lib .. ")")
  check(H.io.logged > 0, "the classes were read from slot data (" .. H.io.logged .. " reads so far)")
  check(H.io.banned == 0, "no read of a property that must not be read")
  local known = T.chests._classes()
  local nKnown = 0
  for _ in pairs(known) do nKnown = nKnown + 1 end
  check(nKnown > 0 and known["ItKe_Quest_Key_99"] == nil, "only items the data lists are kept (" .. nKnown .. " classes)")
  -- bounded: nothing is read again while nothing new shows up
  local before = H.io.logged
  H.player = { Settle.pos[1] + 1500, Settle.pos[2], 0 }
  ticks(400)
  check(H.io.logged == before, "no further slot reads while nothing new shows up (+" .. (H.io.logged - before) .. ")")
  local TWIN = makeChest(settleName, 100500, -90000, KDB[settleName].i)
  H.notify[NEW_IO](TWIN.actor)
  H.player = { TWIN.pos[1] + 1500, TWIN.pos[2], 0 }
  ticks(60)
  check(H.io.logged == before, "a second container of a kind already read costs no reads (+" .. (H.io.logged - before) .. ")")

  local nextKind = 0
  local function fresh()
    nextKind = nextKind + 1
    assert(nextKind <= H.TEST_KINDS, "not enough test kinds")
    return ("IO_ZZ_TESTCHEST_%02d"):format(nextKind)
  end
  local function lootAndWin(ch)
    H.player = { ch.pos[1] + 1500, ch.pos[2], 0 }
    ticks(40)
    playerOpens(ch, takeDefaults(ch))
    ticks(10)
    setRandom(0.0)
    H.game = H.game + 86400 + 60
    ticks(80)
    setRandom(0.2)
  end
  local y = -200000
  local function place(name, opts)
    y = y - 10000
    local ch = makeChest(name, 400000, y, KDB[name].i, opts)
    H.notify[NEW_IO](ch.actor)
    return ch
  end

  -- the container's module has no default list: the definition's own list is used
  local nA = fresh()
  local A = place(nA, { noModuleDefaults = true })
  lootAndWin(A)
  check(isFull(A) and recOf(nA) and recOf(nA).f, "module without default list: classes from the definition's own list, restocked")

  -- neither list readable, container still full when first seen: classes from what is in it
  local nB = fresh()
  local B = place(nB, { noModuleDefaults = true, noDefinitionList = true })
  lootAndWin(B)
  check(isFull(B) and recOf(nB) and recOf(nB).f, "no default list at all: classes learned from the contents while the container was full")

  -- nothing readable and already empty: left alone, said once, nothing searched
  local nC = fresh()
  H.savedInv[nC] = emptied(nC)
  local unreadable0 = chestStats().unreadable
  local C = place(nC, { noModuleDefaults = true, noDefinitionList = true, noCurrentList = true })
  H.player = { C.pos[1] + 1500, C.pos[2], 0 }
  ticks(80)
  check(recOf(nC) == nil and not isFull(C) and chestStats().unreadable == unreadable0 + 1, "no class readable: container left alone, no record")
  check(countLogs("item classes of " .. nC .. " cannot be read from the game's data") == 1, "and that is said once")
  local nC2 = fresh()
  H.savedInv[nC2] = emptied(nC2)
  local C2 = place(nC2, { noModuleDefaults = true, noDefinitionList = true, noCurrentList = true })
  H.player = { C2.pos[1] + 1500, C2.pos[2], 0 }
  ticks(80)
  check(countLogs("cannot be read from the game's data") == 1, "a second such container adds no line")

  -- an item the game's list does not hold: left out, the rest is restocked
  local nD = fresh()
  local omitted = KDB[nD].i[1][1]
  local D = place(nD, { omit = omitted })
  D.actor.__dm.__items[omitted] = nil
  lootAndWin(D)
  local restOk = true
  for i, it in ipairs(KDB[nD].i) do
    if i > 1 and (D.actor.__dm.__items[it[1]] or 0) ~= it[2] then restOk = false end
  end
  check(restOk and (D.actor.__dm.__items[omitted] or 0) == 0 and recOf(nD) and recOf(nD).f, "item missing from the game's list is left out, the others are restocked")
  check(countLogs(omitted .. " is not in the game's list for " .. nD) == 1, "and that is said once: " .. tostring(lastLog("is not in the game's list")))
  ticks(200)
  check(countLogs("is not in the game's list") == 1, "not repeated on later checks")

  -- slots handing out objects of the item class instead of the class
  local nE = fresh()
  local E = place(nE, { instances = true })
  lootAndWin(E)
  check(isFull(E), "slot holds an object of the item class: its class is used")

  -- array elements arriving as parameter objects
  local nF = fresh()
  H.wrapElements = true
  local F = place(nF)
  lootAndWin(F)
  H.wrapElements = false
  check(isFull(F), "works with wrapped array elements")

  -- the object's module list not available: the game's library function, searched once
  local nG = fresh()
  H.io.noComponent = true
  local G = place(nG)
  lootAndWin(G)
  check(isFull(G) and H.sfo.lib == (ENGINE and 0 or 1), "module list unavailable: the library is used (looked up once: at the first map load, or now; searches since the start: " .. H.sfo.lib .. ")")
  local nG2 = fresh()
  local G2 = place(nG2)
  lootAndWin(G2)
  H.io.noComponent = false
  check(isFull(G2) and H.sfo.lib == (ENGINE and 0 or 1), "and it is not searched for again (" .. H.sfo.lib .. ")")

  -- names
  local first = KDB[settleName].i[1][1]
  check(T.chests._itemNameOf(obj("ASClass /Script/Angelscript." .. first)) == first, "class name as in the data")
  check(T.chests._itemNameOf(obj("ASClass /Script/Angelscript.U" .. first)) == first, "class object named with a leading U")
  check(T.chests._itemNameOf(obj("ASClass /Script/Angelscript." .. first:upper())) == first, "class name in another letter case")
  check(T.chests._itemNameOf(obj("ASClass /Script/Angelscript.ItKe_Quest_Key_99")) == nil, "an item the data does not list")
  local someClass = H.itemClass(first)
  check(T.chests._asClass(someClass) == someClass, "a class object is taken as it is")
  check(T.chests._asClass(obj("None", { __valid = false })) == nil, "an invalid object gives no class")

  print("== containers: putting a restock back, and what happens when adding does not work\n")
  -- a restock the game has not saved is not put back while the player stands at the container
  local nH = fresh()
  local HC = place(nH)
  lootAndWin(HC)
  check(isFull(HC) and recOf(nH) and recOf(nH).f, "(restocked, not opened)")
  streamOut(HC); ticks(12)
  H.player = { HC.pos[1] + 200, HC.pos[2], 0 }        -- 2 m away when it is loaded again
  streamIn(HC); H.notify[NEW_IO](HC.actor)
  local restored0 = chestStats().restored
  ticks(60)
  check(not isFull(HC) and recOf(nH) and recOf(nH).f and chestStats().restored == restored0,
    "the restock is not put back while the player stands at the container")
  H.player = { HC.pos[1] + 1500, HC.pos[2], 0 }
  ticks(40)
  check(isFull(HC) and recOf(nH) and recOf(nH).f and chestStats().restored == restored0 + 1, "put back once the player has moved away")
  streamOut(HC); ticks(12)
  H.player = { HC.pos[1] + 200, HC.pos[2], 0 }
  streamIn(HC); H.notify[NEW_IO](HC.actor)
  ticks(30)
  H.player = { 0, 0, 0 }
  ticks(600)
  check(isFull(HC) and chestStats().restored == restored0 + 2, "also when the player leaves the area altogether")

  -- a put-back that arrives only in part
  local nI = fresh()
  local IC = place(nI)
  lootAndWin(IC)
  check(isFull(IC) and recOf(nI) and recOf(nI).f, "(restocked, not opened)")
  streamOut(IC); ticks(12)
  H.player = { IC.pos[1] + 1500, IC.pos[2], 0 }
  H.io.addPartialFor = nI
  streamIn(IC); H.notify[NEW_IO](IC.actor)
  local failed0, restored1 = chestStats().failed, chestStats().restored
  ticks(60)
  check(not isFull(IC) and chestStats().restored == restored1 and chestStats().failed == failed0 + 1,
    "a put-back that arrives only in part is not counted as put back")
  check(countLogs("putting the restock of " .. nI .. " back did not work %(%d+ of %d+ item") == 1,
    "and it is logged: " .. tostring(lastLog("putting the restock")))
  local multi0 = H.io.multiCalls
  streamOut(IC); ticks(12); streamIn(IC); H.notify[NEW_IO](IC.actor)
  ticks(80)
  H.io.addPartialFor = nil
  ticks(40)
  check(H.io.multiCalls == multi0 and not isFull(IC), "not tried again in this run, also after the container was unloaded and loaded again")

  -- a restock that does not arrive
  local nJ = fresh()
  local JC = place(nJ)
  H.player = { JC.pos[1] + 1500, JC.pos[2], 0 }
  ticks(40)
  playerOpens(JC, takeDefaults(JC))
  ticks(10)
  H.io.addFailsFor = nJ
  setRandom(0.0)
  H.game = H.game + 86400 + 60
  ticks(80)
  check(not isFull(JC) and countLogs("restocking " .. nJ .. " did not work %(0 of") == 1, "a restock that does not arrive is logged")
  H.io.addFailsFor = nil
  local multi1 = H.io.multiCalls
  streamOut(JC); ticks(12); streamIn(JC); H.notify[NEW_IO](JC.actor)
  H.game = H.game + 86400 + 60
  ticks(120)
  setRandom(0.2)
  check(H.io.multiCalls == multi1 and not isFull(JC) and recOf(nJ) and not recOf(nJ).f,
    "and the container is not tried again in this run, even after it was unloaded, loaded and won another roll")

  check(H.sfo.item == 0, "still no item class searched for by name")
  check(H.io.banned == 0, "still no read of a property that must not be read")
  check(H.io.logged < 400, "slot reads stay small (" .. H.io.logged .. " in the whole run)")
end)()
end

-- ================================================================ state file
print("== state file\n")
T.console("repop save", nil, nil)
local st = dofile(DIR .. "state/profile_2.lua")
check(type(st) == "table" and st.seen and st.seen[P_FULL] and st.chests and st.chests[rwKey], "state written per profile and readable")

-- ================================================================ session reset on time rewind
print("== load an earlier save\n")
H.game = H.game - 5 * 86400
ticks(2)
ticks(45)
local sl = lastLog("session started")
check(sl and sl:find("populated spawn points known"), "new session after time went back, state reloaded")

-- ================================================================ crime switch
print("== crime switch: left on\n")
local OFF_ALL = { "Config.Crime = {\n    Enabled = true,", "Config.Crime = {\n    Enabled = false," }
local function allMaps(pred) for _, m in ipairs(crimeMaps()) do if not pred(m) then return false end end return true end
check(allMaps(vanillaMap) and H.crime.scans == 0 and H.crime.listCalls == 0,
  "crime left on: the mod never looked at the crime system (" .. H.crime.scans .. " scans)")
check(T.status()[5] == "crime: the game's own rules", "status: crime on (" .. tostring(T.status()[5]) .. ")")
for _, a in ipairs(PLAYER_ACTS) do
  check(crimeValid(CrimeSubs.human.CrimeDefinitions, a[1], a) == true, "game model: " .. a[1] .. " is a crime with the game's own table")
end
local RULES = T.crime._rules
local nRules = 0
for key, rule in pairs(RULES) do
  nRules = nRules + 1
  local found = false
  for _, e in ipairs(CM.vanilla) do
    if e[1]:lower():gsub("%.", "_") == key then
      found = true
      check(e[2] == rule.orig, "rule table: " .. key .. " original class matches the game (" .. e[2] .. ")")
      check(CM.defs[rule.off] and CM.defs[rule.off].mode == 0, "rule table: stand-in for " .. key .. " is never written down by witnesses")
    end
  end
  check(found, "rule table: " .. key .. " exists in the game's table")
end
check(nRules == 22, "22 crime kinds can be switched (" .. nRules .. ")")
check(T.crime._ruleFor("Crime.DirectThreat.Weapon.Melee") == RULES.crime_directthreat_weapon
  and T.crime._ruleFor("Crime.Assault.Weapon.Melee") == nil and T.crime._ruleFor("Crime.Murder") == nil
  and T.crime._ruleFor("Crime.Dialogue.RealFight.Fists.Loot") == nil and T.crime._ruleFor("Crime") == nil,
  "sub-kinds follow their parent rule; violence and story fights have none")

-- a settings file from 1.1 has no Crime section at all
do
  local a = CFG_TEXT:find("-- Crime: how people", 1, true)
  local b = CFG_TEXT:find("return Config", 1, true)
  setConfig({ { CFG_TEXT:sub(a, b - 1), "" } })
  T.reload(false)
  check((lastLog("settings reloaded: ") or ""):find("| crime on$") or (lastLog("settings reloaded: ") or ""):find("| crime on%s*$"),
    "settings file without a Crime section: crime stays on")
  ticks(8)
  check(allMaps(vanillaMap) and H.crime.scans == 0, "(and nothing is touched)")
  setConfig({})
  T.reload(false)
end

print("== crime switch: off\n")
local cTheft = addCrime("Crime.Theft")
local cTresp = addCrime("Crime.Trespassing.OnGuild")
local cThreat = addCrime("Crime.DirectThreat.Weapon.Melee")
addCrime("Crime.Assault.Weapon.Melee")
addCrime("Crime.Murder")
addCrime("Crime.Dialogue.RealFight.Fists.Loot.Permanent")
addCrime("Crime.Theft", OtherState)
local KEPT = "Crime.Assault.Weapon.Melee Crime.Dialogue.RealFight.Fists.Loot.Permanent Crime.Murder"
setConfig({ OFF_ALL })
T.reload(false)
check((lastLog("settings reloaded: ") or ""):find("crime OFF %(theft, trespassing, weapons%)"), "summary line shows crime off")
ticks(2)
check(allMaps(function(m) return #m.__pairs == #CM.vanilla and countSwitched(m) == 22 end), "22 entries switched in each of the 3 rule tables, none added or removed")
check(allMaps(function(m)
  for i, e in ipairs(CM.vanilla) do
    local rule = RULES[e[1]:lower():gsub("%.", "_")]
    local now = shortOf(m.__pairs[i].cls)
    if rule and now ~= rule.off then return false end
    if not rule and now ~= e[2] then return false end
  end
  return true
end), "exactly the listed kinds carry their stand-in; violence and story fights untouched")
check(lastLog("crime: OFF for theft, trespassing, weapons %- 66 rules switched in 3 rule sets, 2 noise reactions off") ~= nil, "log line for the switch")
if ENGINE then
  check(crimeTags() == KEPT and H.crime.scans == 0, "ENGINE: rule sets and crime memory come from the engine in the same update; nothing is searched for")
else
  check(crimeTags() ~= KEPT, "the crime memory is not searched for in the same update as the rule sets (searches among all objects are spaced)")
end
ticks(6)
check(crimeTags() == KEPT, "earlier theft / trespassing / threat crimes forgotten, violence and story kept (" .. crimeTags() .. ")")
check(crimeTags(OtherState) == "Crime.Theft", "other people's crimes are not touched")
check(lastLog("crime: 3 earlier crimes forgotten") ~= nil, "log line for the forgotten crimes")
check((T.status()[5] or ""):find("crime: OFF for theft, trespassing, weapons %(66 rules in 3 rule sets, 2 noise reactions off%), 3 earlier crimes forgotten"), "status: crime off (" .. tostring(T.status()[5]) .. ")")
local function modelOff(groupOff)
  local good = true
  for _, m in ipairs(crimeMaps()) do
    for _, a in ipairs(PLAYER_ACTS) do
      local rule = T.crime._ruleFor(a[1])
      local valid = crimeValid(m, a[1], a)
      if groupOff[rule.g] and valid then good = false; io.write("    MODEL player still commits " .. a[1] .. "\n") end
      if not groupOff[rule.g] and not valid then good = false; io.write("    MODEL player no longer commits " .. a[1] .. "\n") end
    end
    for _, a in ipairs(PLAYER_VIOLENCE) do
      if not crimeValid(m, a[1], a) then good = false; io.write("    MODEL violence lost: " .. a[1] .. "\n") end
    end
    for _, a in ipairs(WITNESS_ACTS) do
      local rule = T.crime._ruleFor(a[1])
      if groupOff[rule.g] then
        for _, c in ipairs(expand(a)) do
          local writes, valid = witnessWrites(m, a[1], c)
          if writes then good = false; io.write("    MODEL a witness still writes down " .. a[1] .. "\n") end
          if a.quiet and valid then good = false; io.write("    MODEL frequent event not dropped early: " .. a[1] .. "\n") end
        end
      end
    end
  end
  return good
end
check(modelOff({ Theft = true, Trespassing = true, Weapons = true }),
  "game model: no switched-off act is written down by the player or a witness; violence still is")

print("== crime switch: steady state\n")
local g0, s0, l0 = H.crime.getCalls, H.crime.scans, H.crime.listCalls
ticks(160)   -- 40 s
check(H.crime.getCalls == g0, "unchanged crime list is not inspected again")
check(H.crime.scans == s0, "no further object scans while the subsystems stay valid")
check(H.crime.listCalls > l0 and H.crime.listCalls <= l0 + 2, "crime list looked at about every 30 s (" .. (H.crime.listCalls - l0) .. " in 40 s)")
local cNew = addCrime("Crime.Pickpocket.Success")   -- e.g. came in with a loaded save
ticks(130)
check(CrimeMem.__crimes[cNew] == nil and crimeTags() == KEPT, "a crime of a switched-off kind that shows up later is forgotten too")
H.crime.wrapIds = true
local cNew2 = addCrime("Crime.Lockpicking")
ticks(130)
H.crime.wrapIds = false
check(CrimeMem.__crimes[cNew2] == nil, "crime ids delivered as parameter objects are handled")
T.console("repop crime", nil, nil)
check((lastLog("crime: OFF for") or ""):find("5 earlier crimes forgotten this run"), "console: repop crime")

print("== crime switch: only some kinds\n")
setConfig({ OFF_ALL, { "DisableWeapons = true,", "DisableWeapons = false," } })
T.reload(false)
ticks(2)
check(allMaps(function(m) return countSwitched(m) == 11 end), "weapons back to the game's rules, theft and trespassing still off")
check(lastLog("crime: OFF for theft, trespassing %- 33 rules switched in 3 rule sets, 2 noise reactions off") ~= nil, "log line for the partial switch")
check(modelOff({ Theft = true, Trespassing = true }), "game model: drawn weapons and threats count again, theft and trespassing do not")
setConfig({ OFF_ALL, { "ForgetOldCrimes = true,", "ForgetOldCrimes = false," } })
T.reload(false)
local cKeep = addCrime("Crime.Theft")
ticks(130)
check(CrimeMem.__crimes[cKeep] ~= nil and allMaps(function(m) return countSwitched(m) == 22 end), "ForgetOldCrimes = false: switch applies, crime memory is left alone")
CrimeMem.__crimes[cKeep] = nil

print("== crime switch: a world is loaded (the game rebuilds its tables)\n")
setConfig({ OFF_ALL })
T.reload(false)
ticks(2)
local oldHuman = CrimeSubs.human
E.mapLoad()
makeCrimeWorld()
check(allMaps(vanillaMap), "fresh world: the game's own tables")
local cSave = addCrime("Crime.Theft")   -- the loaded save still knows a theft
ticks(8)
check(allMaps(vanillaMap), "nothing is touched while the map is loading")
ticks(16)
check(allMaps(function(m) return countSwitched(m) == 22 end), "switch applied again about a second after the world is ready (before the start delay)")
ticks(8)
check(lastLog("session started") ~= nil and CrimeMem.__crimes[cSave] == nil, "theft from the loaded save forgotten")
check(vanillaMap(oldHuman.CrimeDefinitions) == false and oldHuman.__valid == false, "(the old world's table is gone with its world)")
ticks(40)

print("== crime switch: mod switched off as a whole / back on\n")
setConfig({ OFF_ALL, { "Config.Enabled = true", "Config.Enabled = false" } })
T.reload(false)
ticks(2)
check(allMaps(vanillaMap), "Config.Enabled = false also gives the crime rules back")
check(lastLog("crime: back to the game's own rules") ~= nil, "log line for the restore")
setConfig({ OFF_ALL })
T.reload(false)
ticks(2)
check(allMaps(function(m) return countSwitched(m) == 22 end), "and off again when the mod is enabled")
setConfig({})
T.reload(false)
ticks(2)
check(allMaps(vanillaMap), "crime back on: all three tables are exactly the game's own again")
check(T.status()[5] == "crime: the game's own rules", "status after the restore")
s0, l0 = H.crime.scans, H.crime.listCalls
ticks(1300)   -- 325 s
check(H.crime.scans == s0 and H.crime.listCalls == l0, "after the restore the crime system is left alone again")

print("== crime switch: when the scripting layer behaves differently\n")
H.crime.setThrows = true
setConfig({ OFF_ALL })
T.reload(false)
ticks(2)
check(allMaps(function(m) return countSwitched(m) == 22 end) and lastLog("crime: OFF for theft, trespassing, weapons") ~= nil,
  "value:set() refused -> entries written with map:Add instead")
setConfig({})
T.reload(false)
ticks(2)
check(allMaps(vanillaMap), "and restored the same way")
H.crime.setThrows = false
H.crime.setIgnored, H.crime.addThrows = true, true
local cStay = addCrime("Crime.Theft")
setConfig({ OFF_ALL })
T.reload(false)
ticks(2)
check(allMaps(vanillaMap), "neither way works: tables unchanged")
check((lastLog("crime: switch not applied completely") or ""):find("22 rules kept their old value"), "and that is said in the log")
check((T.status()[5] or ""):find("crime: switch not applied completely"), "and in the status")
check(CrimeMem.__crimes[cStay] ~= nil, "nothing is forgotten while the switch is not in place")
H.crime.setIgnored, H.crime.addThrows = false, false
ticks(44)
check(allMaps(function(m) return countSwitched(m) == 22 end) and CrimeMem.__crimes[cStay] == nil, "retried a few seconds later, then applied and forgotten")
setConfig({})
T.reload(false)
ticks(2)
H.crime.noForEach = true
setConfig({ OFF_ALL })
T.reload(false)
ticks(2)
check((T.status()[5] or ""):find("the rule table cannot be read"), "table not readable: reported, nothing done")
H.crime.noForEach = false
ticks(44)
check(allMaps(function(m) return countSwitched(m) == 22 end), "applied once it is readable")
setConfig({})
T.reload(false)
ticks(2)
check(allMaps(vanillaMap), "restored")
-- an entry that is neither the game's class nor a stand-in (other mod, game update)
local hm = CrimeSubs.human.CrimeDefinitions
local theftIdx
for i, p in ipairs(hm.__pairs) do if p.tag == "Crime.Theft" then theftIdx = i end end
hm.__pairs[theftIdx].cls = obj("ASClass /Script/Angelscript.CrimeDefinition_TheftV2")
setConfig({ OFF_ALL })
T.reload(false)
ticks(2)
check(shortOf(hm.__pairs[theftIdx].cls) == "CrimeDefinition_TheftV2" and countSwitched(CrimeSubs.orc.CrimeDefinitions) == 22,
  "an unfamiliar entry is left alone, the rest is switched")
check((lastLog("crime: OFF for") or ""):find("65 rules switched in 3 rule sets, 2 noise reactions off, unfamiliar entries left alone: 1"), "and mentioned: " .. tostring(lastLog("crime: OFF for")))
setConfig({})
T.reload(false)
ticks(2)
hm.__pairs[theftIdx].cls = crimeClass("CrimeDefinition_Theft")
check(allMaps(vanillaMap), "restored")
-- value:set() does nothing and map:Add() adds a second pair instead of replacing the first
H.crime.setIgnored, H.crime.addDuplicates = true, true
setConfig({ OFF_ALL })
T.reload(false)
ticks(2)
check(allMaps(vanillaMap), "pairs added next to the game's entries are taken out again: tables exactly as before")
check((T.status()[5] or ""):find("entries can be neither changed nor replaced %(table left as it was%)"), "and reported (" .. tostring(T.status()[5]) .. ")")
local a0 = H.crime.addCalls
ticks(400)   -- 100 s
check(H.crime.addCalls - a0 == 2 * 22 * 3 and lastLog("crime: left alone after 3 tries") ~= nil,
  "a switch that does not take is tried 3 times, then the game's tables are left alone (" .. (H.crime.addCalls - a0) .. " further writes)")
check((T.status()[5] or ""):find("left alone after 3 tries"), "status says so")
H.crime.setIgnored, H.crime.addDuplicates = false, false
ticks(100)
check(allMaps(vanillaMap), "no further tries by itself")
T.console("repop crime", nil, nil)
ticks(2)
check(allMaps(function(m) return countSwitched(m) == 22 end), "saving the settings again / repop crime tries once more (and now it takes)")
setConfig({})
T.reload(false)
ticks(2)
check(allMaps(vanillaMap), "(back to the game's own tables)")
-- tags that do not look like the game's (a different game version)
for _, m in ipairs(crimeMaps()) do for _, pr in ipairs(m.__pairs) do pr.tag = "Game." .. pr.tag end end
setConfig({ OFF_ALL })
T.reload(false)
ticks(2)
check((T.status()[5] or ""):find("the crime rules were not recognised %(77 entries, e%.g%. Game%.Crime%.[%w%.]+ = CrimeDefinition_"),
  "unknown tags: nothing changed, the log says what was read (" .. tostring(T.status()[5]) .. ")")
check(allMaps(function(m) return countSwitched(m) == 0 end), "(tables unchanged)")
for _, m in ipairs(crimeMaps()) do for _, pr in ipairs(m.__pairs) do pr.tag = pr.tag:gsub("^Game%.", "") end end
setConfig({})
T.reload(false)
ticks(2)
-- class objects not remembered (script layer restarted while switched): looked up by name
setConfig({ OFF_ALL })
T.reload(false)
ticks(2)
T.crime._forgetClasses()
setConfig({})
T.reload(false)
ticks(2)
check(allMaps(vanillaMap), "original classes found by name when they are not remembered")
setConfig({ OFF_ALL })
T.reload(false)
ticks(2)
T.crime._forgetClasses()
H.crime.noStatic = true
setConfig({})
T.reload(false)
ticks(2)
check((T.status()[5] or ""):find("rule class CrimeDefinition_[%w_]+ not found"), "class not found: reported (" .. tostring(T.status()[5]) .. ")")
H.crime.noStatic = false
local searchesBefore = H.sfo.other
ticks(44)
check(not allMaps(vanillaMap) and H.sfo.other == searchesBefore, "a class that was not found is not searched for again in this run (" .. (H.sfo.other - searchesBefore) .. " searches)")
T.crime._forgetClasses()          -- a new run
T.console("repop crime", nil, nil)
ticks(44)
check(allMaps(vanillaMap), "restored once the classes are found")
-- the crime memory does not answer as expected: said once, nothing removed
setConfig({ OFF_ALL })
T.reload(false)
ticks(2)
local cOdd = addCrime("Crime.Theft")
local realGet = CrimeMem.GetCrimeByID
CrimeMem.GetCrimeByID = function() error("UFunction expected 3 parameters, received 2") end
ticks(130)
check(CrimeMem.__crimes[cOdd] ~= nil and countLogs("crime: an earlier crime could not be looked at") == 1, "crime entries unreadable: kept, said once")
CrimeMem.GetCrimeByID = realGet
local cOdd2 = addCrime("Crime.Theft")
ticks(130)
check(CrimeMem.__crimes[cOdd] == nil and CrimeMem.__crimes[cOdd2] == nil, "and forgotten once they can be read")
local realList = CrimeMem.GetAllCrimesCommitedBy
CrimeMem.GetAllCrimesCommitedBy = function() error("no such function") end
ticks(130)
check(countLogs("crime: your crime list could not be read") == 1, "crime list unreadable: said once")
CrimeMem.GetAllCrimesCommitedBy = realList
Pawn.PlayerState = nil
local cOdd3 = addCrime("Crime.Theft")
T.reload(true)
ticks(130)
check(CrimeMem.__crimes[cOdd3] ~= nil and countLogs("crime: the player state was not found") == 1, "player state missing: nothing forgotten, said once")
Pawn.PlayerState = PlayerState
ticks(130)
check(CrimeMem.__crimes[cOdd3] == nil, "forgotten when the player state is there")
setConfig({})
T.reload(false)
ticks(2)
-- no crime subsystem (yet): wait without scanning all the time
setConfig({ OFF_ALL })
T.reload(false)
E.mapLoad()
makeCrimeWorld()
H.crime.noWorld = true
s0 = H.crime.scans
ticks(260)   -- 65 s
check((T.status()[5] or ""):find("waiting for the game world"), "no subsystem found: waiting (" .. tostring(T.status()[5]) .. ")")
check(H.crime.scans - s0 <= 25, "and scanning at most every 15 s (" .. (H.crime.scans - s0) .. " scans in 65 s)")
H.crime.noWorld = false
ticks(100)
check(allMaps(function(m) return countSwitched(m) == 22 end), "applied when the subsystems appear")
-- one scan is enough when the base class name returns the subclasses as well
H.crime.baseMatchesAll = true
E.mapLoad()
makeCrimeWorld()
s0 = H.crime.scans
ticks(40)
check(allMaps(function(m) return countSwitched(m) == 22 end) and H.crime.scans - s0 == (ENGINE and 0 or 2),
  (ENGINE and "ENGINE: no scan at all, got " or "base-name lookup returning all subsystems: one scan (+1 for the crime memory), got ") .. (H.crime.scans - s0))
H.crime.baseMatchesAll = false
setConfig({})
T.reload(false)
ticks(2)
check(allMaps(vanillaMap) and CrimeCDO.CrimeDefinitions and vanillaMap(CrimeCDO.CrimeDefinitions), "everything back to the game's own rules; class defaults never touched")
ticks(40)

-- ================================================================ crime switch: reactions to noises
print("== crime switch: reactions to noises (response modules)\n")
do
  -- state at this point: crime on again, everything restored
  check(gateTagsOf(GI) == "" and gateTagsOf(GT) == "", "crime on: both modules carry the game's own (empty) tag list")
  check(moduleApplies(GI, NPC_TAGS) and moduleApplies(GT, NPC_TAGS), "game model: people react to noises at owned things / in owned places")
  local r0, g0 = H.gate.reads, H.gate.grown
  ticks(200)
  check(H.gate.reads == r0, "crime on: the modules are not looked at")
  setConfig({ OFF_ALL })
  T.reload(false)
  ticks(2)
  check(gateTagsOf(GI) == "Character.Player" and gateTagsOf(GT) == "Character.Player", "crime off: both modules ask for the player-only tag (" .. gateTagsOf(GI) .. ")")
  check(not moduleApplies(GI, NPC_TAGS) and not moduleApplies(GT, NPC_TAGS), "game model: no character other than the player passes, so nobody walks over")
  check(moduleApplies(GI, { "Character.Player", "Species.Human" }), "(the tag is one the player really owns)")
  check(H.gate.grown == g0 + 2, "exactly one entry added per module")
  ticks(400)   -- 100 s of re-checks
  check(H.gate.grown == g0 + 2 and gateTagsOf(GI) == "Character.Player", "re-checks never add entries")
  check((T.status()[5] or ""):find("2 noise reactions off"), "status mentions them")
  -- a world is loaded: class defaults survive, nothing is doubled
  E.mapLoad()
  makeCrimeWorld()
  ticks(40)
  check(gateTagsOf(GI) == "Character.Player" and gateTagsOf(GT) == "Character.Player" and H.gate.grown == g0 + 2, "after a world load: still one entry each")
  ticks(40)
  -- only theft off: the trespassing module goes back to the game's own
  setConfig({ OFF_ALL, { "DisableTrespassing = true,", "DisableTrespassing = false," }, { "DisableWeapons = true,", "DisableWeapons = false," } })
  T.reload(false)
  ticks(2)
  check(gateTagsOf(GI) == "Character.Player" and gateTagsOf(GT) == "", "only theft off: the noise reaction for owned things is off, the one for owned places is the game's")
  check((lastLog("crime: OFF for theft ") or ""):find("1 noise reaction off"), "log: " .. tostring(lastLog("crime: OFF for theft ")))
  setConfig({ OFF_ALL, { "DisableTheft = true,", "DisableTheft = false," } })
  T.reload(false)
  ticks(2)
  check(gateTagsOf(GI) == "" and gateTagsOf(GT) == "Character.Player", "theft on again, trespassing off: the other way round")
  setConfig({})
  T.reload(false)
  ticks(2)
  check(gateTagsOf(GI) == "" and gateTagsOf(GT) == "", "crime on: both lists empty again")
  check(T.status()[5] == "crime: the game's own rules", "status after the restore")
  r0 = H.gate.reads
  ticks(400)
  check(H.gate.reads == r0, "and the modules are left alone again")

  -- struct members cannot be written: the whole entry is written instead
  H.gate.fieldSet = false
  setConfig({ OFF_ALL })
  T.reload(false)
  ticks(2)
  H.gate.fieldSet = true
  check(gateTagsOf(GI) == "Character.Player" and gateTagsOf(GT) == "Character.Player", "member write refused -> entry written as a whole")
  setConfig({})
  T.reload(false)
  ticks(2)
  check(gateTagsOf(GI) == "" and gateTagsOf(GT) == "", "(restored)")

  -- neither way works: the half-made entry is taken out again, three tries, then left alone
  H.gate.fieldSet, H.gate.tableSet = false, false
  setConfig({ OFF_ALL })
  T.reload(false)
  ticks(2)
  check(gateTagsOf(GI) == "" and gateTagsOf(GT) == "", "entry cannot be written: the lists are left exactly as the game made them")
  check(allMaps(function(m) return countSwitched(m) == 22 end), "the rule tables are switched all the same")
  check((lastLog("crime: noise reaction not switched") or ""):find("did not take the tag"), "and it is said: " .. tostring(lastLog("crime: noise reaction not switched")))
  check((T.status()[5] or ""):find("0 noise reactions off %- AIARM_ToInvestigateSuspiciousSound_Interaction did not take the tag"), "status: " .. tostring(T.status()[5]))
  local grownBefore = H.gate.grown
  ticks(400)
  check(H.gate.grown <= grownBefore + 4, "tried three times per module, then left alone (" .. (H.gate.grown - grownBefore) .. " more attempts)")
  check(countLogs("crime: noise reaction not switched") == 1, "said once")
  H.gate.fieldSet, H.gate.tableSet = true, true
  setConfig({})
  T.reload(false)
  ticks(2)
  check(gateTagsOf(GI) == "" and gateTagsOf(GT) == "" and allMaps(vanillaMap), "(restored)")

  -- this build would not add entries at all
  H.gate.grow = false
  setConfig({ OFF_ALL })
  T.reload(false)
  ticks(2)
  H.gate.grow = true
  check(gateTagsOf(GI) == "" and (T.status()[5] or ""):find("did not take the tag %(.-index out of range"), "no entry can be added: reported with the reason (" .. tostring(T.status()[5]) .. ")")
  setConfig({})
  T.reload(false)
  ticks(2)

  -- a module that already asks for something else is not ours to change
  GateCDO[GI].RequiredOwnedTags.GameplayTags = makeTagArray({ "State.Flying" })
  setConfig({ OFF_ALL })
  T.reload(false)
  ticks(2)
  check(gateTagsOf(GI) == "State.Flying" and gateTagsOf(GT) == "Character.Player", "module with other tags: left alone, the other one is switched")
  check((T.status()[5] or ""):find("already asks for other tags %(State%.Flying%)"), "and reported: " .. tostring(T.status()[5]))
  setConfig({})
  T.reload(false)
  ticks(2)
  check(gateTagsOf(GI) == "State.Flying" and gateTagsOf(GT) == "", "(restore does not touch it either)")
  GateCDO[GI].RequiredOwnedTags.GameplayTags = makeTagArray()

  -- module class not present (another game version)
  H.gate.noCdo = true
  setConfig({ OFF_ALL, { "DisableTrespassing = true,", "DisableTrespassing = false," } })
  T.reload(false)
  ticks(2)
  H.gate.noCdo = false
  check(allMaps(function(m) return countSwitched(m) == 18 end), "module not found: rule tables still switched")
  setConfig({})
  T.reload(false)
  ticks(2)
  check(gateTagsOf(GI) == "" and gateTagsOf(GT) == "" and allMaps(vanillaMap), "everything back to the game's own")
  ticks(40)
end

-- ================================================================ console / status
T.console("repop reload", nil, nil)
check((lastLog("settings reloaded: ") or ""):find("creatures on 35%%/24h %(elite 15%%/24h"), "console reload + summary line")
local lines = T.status()
check(#lines == 7 and lines[2]:find("creatures:") and lines[2]:find("every 24h") and lines[4]:find("containers:") and lines[5]:find("^crime:"), "status lines")
if ENGINE then (function()      -- (a function of its own: the main chunk is at Lua's limit of local variables)
  local nIO, nSt, nBegin, nEnd = lines[6]:match("^objects in play: (%d+) interactive objects, (%d+) character states %(the game announced (%d+) begins and (%d+) ends of play%)$")
  local inPlayIO, inPlaySt = 0, 0
  for o in pairs(H.play.inPlay) do if o.__isa[E.IOClass] then inPlayIO = inPlayIO + 1 else inPlaySt = inPlaySt + 1 end end
  check(tonumber(nIO) == inPlayIO and tonumber(nSt) == inPlaySt and tonumber(nBegin) == H.play.begins and tonumber(nEnd) == H.play.ends,
    ("ENGINE status: the objects in play as the game announced them (%s; the world holds %d and %d, %d begins, %d ends)"):format(tostring(lines[6]), inPlayIO, inPlaySt, H.play.begins, H.play.ends))
end)() else
  check(lines[6] == "objects in play: not followed (this UE4SS build has no begin / end of play hooks)", "status: the game's begin / end of play calls are not there in this run (" .. tostring(lines[6]) .. ")")
end
check(lines[7]:find("^this run: %d+ sessions?, %d+ resets? %(.-map load %d+.-%); hero put into the world again %d+ times? %(no reset%), 0 pauses; %d+ searches among all objects$") ~= nil,
  "status: sessions, resets with their reasons, searches (" .. tostring(lines[7]) .. ")")
for _, l in ipairs(lines) do io.write("    STATUS ", l, "\n") end
local errs = 0
for _, l in ipairs(H.logs) do
  if (l:find("error") or l:find("failed") or l:find("FATAL")) and not l:find("has an error, keeping") and not l:find("spot raised on purpose", 1, true) and not l:find("Respawn failed (none)", 1, true) then errs = errs + 1; io.write("    ERR ", l) end
end
check(errs == 0, "no error lines")

-- ================================================================ diagnostics hooks (megamod loader)
-- Everything above ran the mod on its own (no G1R_DIAG), as it is installed today. From here on the real scripts
-- are loaded again in a small fresh world: once as before, and then with a recording stand-in for the handle the
-- megamod loader passes in (diag_fake.lua), to see that the hooks report the right things and change nothing.
;(function()
  local FK = dofile((debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./") .. "diag_fake.lua")
  local mainLogs = H.logs
  local NEW_IO = "/Script/G1R.InteractiveObjectActor"
  local W            -- the small world of the current run: { settle = chest, wild = chest, y = next free place }

  -- every note key the brief defines for this module
  local KEYS = {}
  for _, k in ipairs({ "core.profile", "core.game_time_source", "items.configs_set", "creatures.states_class",
      "creatures.ids_carry_point_names", "creatures.far_states_visible", "creatures.class_lookup", "creatures.spawn_via",
      "creatures.corpse_removed", "containers.definition_source", "containers.data_module_source",
      "containers.classes_source", "containers.count_form", "containers.restock_result", "containers.putback_result",
      "crime.rule_tables", "crime.forgotten", "crime.noise_module.Interaction", "crime.noise_module.Trespassing",
      -- 1.4: how the mod gets at the game's objects (this file: by searches), what it looked up at its start
      "core.paths_found", "core.play_hooks", "core.engine", "core.controller_by", "core.game_time_by", "core.state_file",
      "items.manager_by", "crime.subsystems_by", "creatures.states_in_play", "creatures.point_scripts_by", "creatures.corpse_kept",
      "creatures.spawn_confirm" }) do
    KEYS[k] = true
  end

  local function freshWorld()
    H.logs = {}
    H.real, H.game = 500000.0, 86400 * 50 + 9 * 3600
    H.player = { PARK[1], PARK[2], 0 }
    setRandom(0.0)
    H.spawns, H.removed, H.added, H.findAll = {}, 0, 0, 0
    H.wrapElements = false
    -- creatures: the picture the harness starts with
    for i = #States, 1, -1 do States[i] = nil end
    for i = 1, CDB[P_FULL].s[1].n do addState(CDB[P_FULL].s[1].u, P_FULL, i) end
    addState(CDB[P_HALF].s[1].u, P_HALF, 1)
    for i = 2, CDB[P_HALF].s[1].n do addState(CDB[P_HALF].s[1].u, P_HALF, i, { dead = true }) end
    addState(CDB[P_EMPTY].s[1].u, P_EMPTY, 1, { dead = true })
    for i = 1, CDB[P_SPATIAL].s[1].n do
      addState(CDB[P_SPATIAL].s[1].u, P_SPATIAL, i, { id = CDB[P_SPATIAL].s[1].u .. "-AIScript-" .. i })
    end
    addState(CDB[P_ELITE].s[1].u, P_ELITE, 1, { dead = true })
    addState(CDB[farName].s[1].u, farName, 1, { pos = { CDB[farName].x, CDB[farName].y, 0 } })
    -- world item spots as the game has them
    for _, c in ipairs(Configs) do
      local spot = IDB[c.m_Name.__s]
      c.m_ItemSpawnConfig.m_Refillable = spot ~= nil and spot.p == "keep"
      c.m_ItemSpawnConfig.m_RefillHours = spot and spot.r or 0
    end
    -- containers: the chairs and two chests
    for i = #ActorsIO, 1, -1 do ActorsIO[i] = nil end
    for _, c in ipairs(chairs) do ActorsIO[#ActorsIO + 1] = c end
    H.savedInv = {}
    H.io = { banned = 0, logged = 0, hasCalls = 0, serverCalls = 0, multiCalls = 0, predicted = 0, outMode = "count",
             addFails = false, addPartial = false, hasThrows = false, noGetter = false, noComponent = false }
    H.sfo = { lib = 0, item = 0, other = 0, ai = 0 }
    -- crime system: a new world with the game's own tables, nothing remembered
    makeCrimeWorld()
    for name in pairs(GateCDO) do GateCDO[name].RequiredOwnedTags.GameplayTags = makeTagArray() end
    CrimeMem.__crimes, CrimeMem.__next = {}, 1
    H.crime = { setThrows = false, setIgnored = false, addThrows = false, noForEach = false, scans = 0, baseMatchesAll = false,
                addCalls = 0, listCalls = 0, getCalls = 0 }
    H.gate = { reads = 0, grown = 0, grow = true, fieldSet = true, tableSet = true, noCdo = false, emptyThrows = false }
    Pawn.PlayerState = PlayerState
    PDS.m_CurrentProfileId = 2
    -- files: default settings, no progress file
    os.execute("rm -f " .. DIR .. "state/profile_*")
    setConfig({})
    H.finds, H.findAll = {}, 0
    H.paused, H.noManager, H.noClock, H.noController, H.controllerNow, H.menu = nil, nil, nil, nil, nil, nil
    H.play.silentEnd, H.play.silentBegin, H.play.noEnds, E.trapOff = nil, nil, nil, nil
    W = { settle = makeChest(settleName, 100500, -100500, KDB[settleName].i),
          wild = makeChest(wildName, 300000, -100000, KDB[wildName].i), y = -200000 }
  end
  E.freshWorld, E.FK, E.small = freshWorld, FK, function() return W end

  -- the handle is taken once, while the scripts load
  local function loadMod(fake)
    rawset(_G, "G1R_DIAG", fake and fake.handle or nil)
    _G.REPOP_TEST = {}
    dofile(DIR .. "main.lua")
    rawset(_G, "G1R_DIAG", nil)
    E.afterLoad()
    return _G.REPOP_TEST
  end
  E.loadMod = loadMod

  -- every call into the emulated UE4SS functions and the two object methods the mod uses everywhere, while fn runs
  local function counted(fn)
    local calls, saved = {}, {}
    for _, name in ipairs({ "FindAllOf", "FindFirstOf", "StaticFindObject", "StaticConstructObject" }) do
      local f = _G[name]
      saved[name] = f
      _G[name] = function(a, ...)
        local k = name .. "(" .. (type(a) == "string" and a or "object") .. ")"
        calls[k] = (calls[k] or 0) + 1
        return f(a, ...)
      end
    end
    local isValid, fullName = Base.IsValid, Base.GetFullName
    Base.IsValid = function(self) calls.IsValid = (calls.IsValid or 0) + 1; return isValid(self) end
    Base.GetFullName = function(self) calls.GetFullName = (calls.GetFullName or 0) + 1; return fullName(self) end
    local ok, err = pcall(fn)
    for name, f in pairs(saved) do _G[name] = f end
    Base.IsValid, Base.GetFullName = isValid, fullName
    if not ok then error(err, 0) end
    local keys, out = {}, {}
    for k in pairs(calls) do keys[#keys + 1] = k end
    table.sort(keys)
    for i, k in ipairs(keys) do out[i] = k .. " x" .. calls[k] end
    return out
  end

  -- One representative stretch of play: session start, a creature cycle, a chest that is looted, restocked,
  -- unloaded and put back, the crime switch off and on again, a save being loaded.
  local function play(T, mark)
    local S = W.settle
    ticks(4); ticks(40)                                           -- start delay, progress file, world item pass, containers
    H.game = nextBoundary(24) + 10; ticks(80)                     -- creature cycle
    playerOpens(S, takeDefaults(S)); ticks(4)                     -- the chest 7 m away is looted
    setRandom(0.2); H.game = H.game + 86400 + 60; ticks(40)       -- its roll wins: restocked
    streamOut(S); ticks(12); streamIn(S); H.notify[NEW_IO](S.actor)
    setRandom(0.99); ticks(60)                                    -- unloaded and loaded again: the restock is put back
    addCrime("Crime.Theft"); addCrime("Crime.Trespassing.OnGuild"); addCrime("Crime.Murder")
    setConfig({ OFF_ALL }); T.reload(false); ticks(8)             -- crime off
    if mark then mark("quiet") end
    ticks(1300)                                                   -- 325 s in which nothing changes (re-checks, an evidence scan)
    if mark then mark("quiet end") end
    setConfig({}); T.reload(false); ticks(8)                      -- crime on again
    E.mapLoad(); makeCrimeWorld(); ticks(60)                          -- a save is loaded: a new session starts
    T.console("repop save", nil, nil)
    T.console("repop status", nil, nil)
  end

  local function signature(T, calls)
    local sig = {}
    for _, l in ipairs(H.logs) do sig[#sig + 1] = "log: " .. l end
    for _, l in ipairs(T.status()) do sig[#sig + 1] = "status: " .. l end
    local how = {}
    for i, s in ipairs(H.spawns) do how[i] = s.how .. ":" .. tostring(s.point or "") end
    sig[#sig + 1] = ("spawned %d (%s), corpses removed %d, items added %d"):format(#H.spawns, table.concat(how, " "), H.removed, H.added)
    sig[#sig + 1] = ("containers: reads of forbidden properties %d, slot reads %d, HasItemMain %d, Server_AddNewItem %d, Multicast_AddNewItem %d (predicted %d)")
      :format(H.io.banned, H.io.logged, H.io.hasCalls, H.io.serverCalls, H.io.multiCalls, H.io.predicted)
    sig[#sig + 1] = ("searches by path: library %d, item classes %d, other %d; FindAllOf %d"):format(H.sfo.lib, H.sfo.item, H.sfo.other, H.findAll)
    sig[#sig + 1] = ("crime: scans %d, list calls %d, entry calls %d, map adds %d; tag list reads %d, entries added %d")
      :format(H.crime.scans, H.crime.listCalls, H.crime.getCalls, H.crime.addCalls, H.gate.reads, H.gate.grown)
    for _, c in ipairs(calls) do sig[#sig + 1] = "calls: " .. c end
    sig[#sig + 1] = "progress: " .. FK.serialize({ seen = T.state.seen, chests = T.state.chests, recent = T.state.recent })
    local f = io.open(DIR .. "state/profile_2.lua", "r")
    sig[#sig + 1] = "progress file: " .. (f and f:read("a") or "missing")
    if f then f:close() end
    return sig
  end

  local function runPlay(fake, mark)
    freshWorld()
    local T
    local calls = counted(function()
      T = loadMod(fake)
      play(T, mark)
    end)
    return T, signature(T, calls)
  end

  local function firstLog(pat)
    for _, l in ipairs(H.logs) do if l:find(pat) then return l end end
  end
  local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
  local function list(t) local s = {} for i, v in ipairs(t) do s[i] = tostring(v) end return table.concat(s, " > ") end

  -- ---------------------------------------------------------------- same behaviour with and without the handle
  print("== diagnostics hooks: the same stretch of play without and with the megamod's handle\n")
  local wasQuiet = QUIET
  QUIET = true                       -- the first of the two runs is not shown
  local _, sigA = runPlay(nil)
  QUIET = wasQuiet
  local F = FK.new()
  local marks = {}
  local T, sigB = runPlay(F, function(name) marks[name] = #F.notes end)
  local notesOfPlay = #F.notes       -- (the stand-in is given more further down)
  local firstDiff
  for i = 1, math.max(#sigA, #sigB) do
    if sigA[i] ~= sigB[i] then firstDiff = i; break end
  end
  check(firstDiff == nil and #sigA > 40, ("with the handle present the mod logs, counts, calls and stores exactly the same (%d lines compared%s)")
    :format(#sigA, firstDiff and (", first difference in line " .. firstDiff .. ":\n      without: " .. tostring(sigA[firstDiff])
      .. "\n      with:    " .. tostring(sigB[firstDiff])) or ""))
  local cst = T.chests.stats()
  check(#H.spawns >= 4 and H.removed >= 3 and cst.refilled == 1 and cst.restored >= 1 and countLogs("crime: OFF for theft, trespassing, weapons") == 1
    and countLogs("crime: back to the game's own rules") == 1 and countLogs("session started") == 2,
    ("(the stretch did what it is meant to: %d respawns, %d corpses removed, %d restock, %d put back, crime off and on, 2 sessions)")
      :format(#H.spawns, H.removed, cst.refilled, cst.restored))

  -- ---------------------------------------------------------------- what was registered
  print("== diagnostics hooks: version, status, dump\n")
  local loadLine = firstLog("%] v%S+ loaded:") or ""
  check(#F.versions == 1 and type(F.versions[1]) == "string" and loadLine:find("v" .. F.versions[1] .. " loaded:", 1, true) ~= nil,
    "version registered once: the one in the load line (" .. tostring(F.versions[1]) .. ")")
  check(#F.status == 1 and #F.dump == 1 and type(F.status[1]) == "function" and type(F.dump[1]) == "function",
    "status and dump providers registered once each")
  -- neither may touch the game: calls into the emulated API and reads of the game clock are counted
  local clockReads = 0
  local clockMeta = getmetatable(TimeSub.CurrentGameTime)
  local clockIndex = clockMeta.__index
  clockMeta.__index = function(t, k) clockReads = clockReads + 1; return clockIndex(t, k) end
  local lines, dump
  local touched = counted(function() lines = F.status[1](); dump = F.dump[1]() end)
  check(#touched == 0 and clockReads == 0, ("status and dump are built without touching the game (%d kinds of calls, %d clock reads)"):format(#touched, clockReads))
  local own = T.status()
  check(clockReads > 0, "(control: the mod's own status command does read the game clock)")
  clockMeta.__index = clockIndex
  check(type(lines) == "table" and #lines == 7 and FK.same(lines, own), "status provider returns the lines of the mod's status command")
  check(type(lines) == "table" and tostring(lines[1]):find("^v" .. F.versions[1]:gsub("%p", "%%%0") .. " | day %d+ %d%d:%d%d | creatures on"),
    "(first line: " .. tostring(type(lines) == "table" and lines[1]) .. ")")

  local okPlain, where = FK.plain(dump, 4)
  check(okPlain, "dump is plain data: strings, numbers, booleans and tables, no table reached twice, at most 4 tables deep" .. (okPlain and "" or (" - " .. tostring(where))))
  local okBack, why = FK.roundTrip(dump)
  check(okBack, "dump can be written out as Lua and read back unchanged" .. (okBack and "" or (" - " .. tostring(why))))
  dump = type(dump) == "table" and dump or {}
  local dc, dk, dr = dump.containers or {}, dump.creatures or {}, dump.crime or {}
  check(dump.version == F.versions[1] and dump.profile == "profile_2" and dump.session_started == true and dump.game_seconds == H.game,
    "dump: version, profile, session, in-game time of the last update")
  local row
  for _, r in ipairs(dc.tracked or {}) do if r.kind == settleName then row = r end end
  check(#(dc.tracked or {}) == 2 and row and row.key == settleName .. "@1005,-1005" and row.x == 100500 and row.y == -100500 and row.z == 100
    and row.checked == true and row.failed == false and row.type == "chest" and row.settlement == true and row.definition == "getter",
    "dump: tracked containers with kind, key, position, checked, failed")
  local classSet, sorted = {}, true
  for i, n in ipairs(dc.item_classes or {}) do
    classSet[n] = true
    if i > 1 and dc.item_classes[i - 1] >= n then sorted = false end
  end
  local allKnown = true
  for _, n in ipairs({ settleName, wildName }) do
    for _, it in ipairs(KDB[n].i) do if not classSet[it[1]] then allKnown = false end end
  end
  check(allKnown and sorted and #dc.item_classes == count(T.chests._classes()), ("dump: the %d known item class names, in order"):format(#(dc.item_classes or {})))
  check(type(dc.records) == "table" and #dc.records == count(T.state.chests) and type(dc.stats) == "table" and dc.stats.refilled == cst.refilled
    and dc.stats.restored == cst.restored and dc.stats.seen == cst.seen, ("dump: container records of the progress file (%d) and the session numbers"):format(#(dc.records or {})))
  local seenOk = dk.points_seen == count(T.state.seen) and #(dk.seen or {}) == dk.points_seen
  for _, n in ipairs(dk.seen or {}) do if not T.state.seen[n] then seenOk = false end end
  local cstats, queue, _, farSeen = T.creatures.stats()
  check(seenOk and dk.points_known == 401 and dk.queue == queue and type(dk.stats) == "table" and dk.stats.spawned == cstats.spawned and dk.stats.cycles == cstats.cycles
    and dk.far_states_visible == farSeen and dk.ids_carry_point_names == true and dk.census_running == false and #(dk.intervals or {}) == 1 and dk.intervals[1].hours == 24,
    ("dump: creature census summary (%s points seen populated, queue %s, numbers, roll intervals)"):format(tostring(dk.points_seen), tostring(dk.queue)))
  local lurker, classRows = nil, #(dk.classes or {}) >= 3
  for _, c in ipairs(dk.classes or {}) do
    if c.name == CDB[P_EMPTY].s[1].d then lurker = c end
    if type(c.name) ~= "string" or type(c.found) ~= "boolean" then classRows = false end
  end
  check(classRows and lurker and lurker.found == true, ("dump: the %d classes looked up so far and whether they were found"):format(#(dk.classes or {})))
  check(dr.status == own[5] and dr.sig == "" and dr.rules == 0 and dr.forgotten == 2 and dr.pending == false, "dump: crime status (" .. tostring(dr.status) .. ")")

  -- ---------------------------------------------------------------- the notes of that stretch
  print("== diagnostics hooks: what the stretch of play reported\n")
  local function noted(key, value, detail, what)
    local v, d = F.value(key), F.detail(key)
    local okDetail = detail == nil or d == detail or (type(d) == "string" and type(detail) == "string" and detail:sub(1, 1) == "^" and d:find(detail) ~= nil)
    if type(detail) == "table" then       -- one of several
      okDetail = false
      for _, one in ipairs(detail) do if d == one then okDetail = true end end
      detail = table.concat(detail, " or ")
    end
    check(v == value and okDetail, ("note %s = %s%s%s (got %s / %s)"):format(key, tostring(value), detail and (" (" .. tostring(detail) .. ")") or "",
      what and (": " .. what) or "", tostring(v), tostring(d)))
  end
  local function times(key, n, what)
    check((F.count[key] or 0) == n and F.neverRepeated(key), ("note %s passed on %d time(s)%s (got %d: %s)"):format(key, n, what and (" " .. what) or "",
      F.count[key] or 0, list(F.values(key))))
  end
  local unknownKeys = {}
  for k in pairs(F.count) do if not KEYS[k] then unknownKeys[#unknownKeys + 1] = tostring(k) end end
  table.sort(unknownKeys)
  check(#unknownKeys == 0, "only note keys of the list are used (" .. table.concat(unknownKeys, ", ") .. ")")
  check(marks.quiet ~= nil and marks.quiet == marks["quiet end"], ("no note at all during 325 s in which nothing changed (%s before, %s after)"):format(tostring(marks.quiet), tostring(marks["quiet end"])))

  noted("core.profile", 2, "profile_2.lua")
  times("core.profile", 1, "although the progress file was loaded for two sessions")
  noted("core.game_time_source", "property")
  times("core.game_time_source", 1, "although the clock is read on every update")
  check(countLogs("spots set refillable") >= 2, "(the world item pass ran " .. countLogs("spots set refillable") .. " times)")
  noted("items.configs_set", "2495 spots", "0 ms")
  times("items.configs_set", 1)
  check(countLogs("creature cycle") >= 2, "(" .. countLogs("creature cycle") .. " creature cycles and an evidence scan)")
  noted("creatures.states_class", "GothicCharacterState", #States)
  times("creatures.states_class", 1)
  noted("creatures.ids_carry_point_names", true, "^%d+ ids matched a spawn point$")
  times("creatures.ids_carry_point_names", 1)
  noted("creatures.far_states_visible", true, "^farthest living creature seen %d+ m away$")
  times("creatures.far_states_visible", 1)
  noted("creatures.class_lookup", "found", "^SpawnAIAgentDefinition_%w+$")
  times("creatures.class_lookup", 1, "although three classes were looked up")
  local changes, vias, last = 0, {}, nil
  for _, s in ipairs(H.spawns) do
    vias[s.how] = true
    if s.how ~= last then changes, last = changes + 1, s.how end
  end
  check(vias.point and vias.library, "(respawns went through the spawn point's script and through the library)")
  times("creatures.spawn_via", changes, "- once per change of the way, not once per respawn")
  local viaOk = true
  for _, n in ipairs(F.notes) do
    if n.key == "creatures.spawn_via" and not ((n.value == "point" or n.value == "library") and CDB[n.detail]) then viaOk = false end
  end
  check(viaOk, "note creatures.spawn_via = point | library, with the spawn point as detail")
  noted("creatures.corpse_removed", true, "^%S+ at %S+$")
  noted("creatures.spawn_confirm", ENGINE and "works" or "not available", "^%S+ at %S+$")
  times("creatures.corpse_removed", 1, "although " .. H.removed .. " corpses were removed")
  -- (which of the two chests is looked at first is not fixed)
  noted("containers.definition_source", "getter", { settleName, wildName }, "the first container recognised")
  times("containers.definition_source", 1)
  noted("containers.data_module_source", "module list", { settleName, wildName })
  times("containers.data_module_source", 1)
  noted("containers.classes_source", "default inventory", "^" .. settleName .. ": 3 learned, 4 slots read$")
  times("containers.classes_source", 1, "although two kinds of container were read")
  noted("containers.count_form", "count")
  times("containers.count_form", 1, "in " .. H.io.hasCalls .. " counts")
  noted("containers.restock_result", "complete", settleName .. ": 4 of 4")
  times("containers.restock_result", 1)
  noted("containers.putback_result", "complete", settleName .. ": 4 of 4")
  times("containers.putback_result", 1)
  check(list(F.values("crime.rule_tables")) == "66 rules in 3 sets > 0 rules in 3 sets", "note crime.rule_tables: switched, then the game's own again (" .. list(F.values("crime.rule_tables")) .. ")")
  noted("crime.rule_tables", "0 rules in 3 sets", "nothing switched off")
  noted("crime.forgotten", 2)
  times("crime.forgotten", 1)
  check(list(F.values("crime.noise_module.Interaction")) == "closed > open" and list(F.values("crime.noise_module.Trespassing")) == "closed > open",
    "notes crime.noise_module.Interaction / .Trespassing: closed, then open again")
  check(F.crumbCount("U.findStatic /Script/G1R.Default__AIScriptLibrary") == 1 and vias.library and #F.crumbs >= 4,
    ("a line before every search by path that is not answered yet, none for a path found before (%d lines; the library path once in %d library respawns)")
      :format(#F.crumbs, #H.spawns))
  local crumbsOk = true
  for _, c in ipairs(F.crumbs) do if not c:find("^U%.findStatic /Script/") then crumbsOk = false end end
  check(crumbsOk and #F.events == 0, "each of those lines names the path")

  -- ---------------------------------------------------------------- the other values of each note
  print("== diagnostics hooks: the other values\n")
  local savedCur = TimeSub.CurrentGameTime
  TimeSub.CurrentGameTime = { get = function() return { TotalSeconds = H.game } end }
  ticks(3)
  noted("core.game_time_source", "property (wrapped)")
  TimeSub.CurrentGameTime = nil
  TimeSub.GetCurrentGameTime = function() return { TotalSeconds = H.game } end
  ticks(3)
  noted("core.game_time_source", "function")
  TimeSub.GetCurrentGameTime = nil
  TimeSub.CurrentGameTime = savedCur
  ticks(3)
  check(list(F.values("core.game_time_source")) == "property > property (wrapped) > function > property", "note core.game_time_source follows the way the clock is read")

  -- character states only found under the other class name
  local realFindAll = _G.FindAllOf
  _G.FindAllOf = function(cls)
    if cls == "GothicCharacterState" then return {} end
    if cls == "GothicNPCState" then return States end
    return realFindAll(cls)
  end
  T.console("repop now", nil, nil); ticks(40)
  _G.FindAllOf = realFindAll
  noted("creatures.states_class", "GothicNPCState", #States)

  -- a spawn definition class that does not exist
  local P_X = single[4]
  local hidden = CDB[P_X].s[1].d
  addState(CDB[P_X].s[1].u, P_X, 1, { dead = true })
  local realStatic = _G.StaticFindObject
  _G.StaticFindObject = function(path)
    if path:find(hidden, 1, true) then return nil end
    return realStatic(path)
  end
  setRandom(0.0)
  local failed0 = (T.creatures.stats()).failed
  T.console("repop now", nil, nil); ticks(160, 0.5)
  noted("creatures.states_class", "GothicCharacterState", #States)
  noted("creatures.class_lookup", "not found", hidden)
  times("creatures.class_lookup", 2, "- the first class found and the first one not found")
  noted("creatures.spawn_via", "failed", "no-class at " .. P_X)
  check((T.creatures.stats()).failed == failed0 + 1, "(the respawn failed)")
  local c1 = F.crumbCount("U.findStatic /Script/Angelscript." .. hidden)
  local c2 = F.crumbCount("U.findStatic /Script/Angelscript.U" .. hidden)
  local c3 = F.crumbCount("U.findStatic /Script/G1R." .. hidden)
  check(c1 == 1 and c2 == 1 and c3 == 1, ("a line before each of the three searches for the missing class (%d / %d / %d)"):format(c1, c2, c3))
  local nCrumbs, nVia = #F.crumbs, F.count["creatures.spawn_via"]
  T.console("repop now", nil, nil); ticks(160, 0.5)
  _G.StaticFindObject = realStatic
  check(#F.crumbs == nCrumbs and (T.creatures.stats()).failed == failed0 + 2 and F.count["creatures.spawn_via"] == nVia and F.count["creatures.class_lookup"] == 2,
    "the same failure again: no further search, line or note")

  -- containers (creatures switched off: nothing else goes on)
  setConfig({ { "Config.Creatures = {\n    Enabled = true,", "Config.Creatures = {\n    Enabled = false," } })
  T.reload(false)
  local kindNo = 0
  local function freshKind()
    kindNo = kindNo + 1
    assert(kindNo <= H.TEST_KINDS, "not enough test kinds")
    return ("IO_ZZ_TESTCHEST_%02d"):format(kindNo)
  end
  local function place(name, contents, opts)
    W.y = W.y - 10000
    local ch = makeChest(name, 500000, W.y, contents or KDB[name].i, opts)
    H.notify[NEW_IO](ch.actor)
    return ch
  end
  local function visit(ch) H.player = { ch.pos[1] + 1500, ch.pos[2], 0 }; ticks(40) end
  local function lootAndWin(ch)
    visit(ch)
    playerOpens(ch, takeDefaults(ch)); ticks(10)
    setRandom(0.0); H.game = H.game + 86400 + 60; ticks(80); setRandom(0.99)
  end
  local function reload(ch) streamOut(ch); ticks(12); streamIn(ch); H.notify[NEW_IO](ch.actor); ticks(60) end
  local function emptied(name) local t = {} for _, it in ipairs(KDB[name].i) do t[it[1]] = 0 end return t end

  local kA = freshKind()
  visit(place(kA, nil, { noModuleDefaults = true }))
  noted("containers.classes_source", "definition list", kA .. ": 3 learned, 4 slots read", "the container's module holds no default list")
  local kB = freshKind()
  visit(place(kB, nil, { noModuleDefaults = true, noDefinitionList = true }))
  noted("containers.classes_source", "current contents", kB .. ": 3 learned, 3 slots read", "no default list anywhere, container still full")
  local kC = freshKind()
  H.savedInv[kC] = emptied(kC)
  visit(place(kC, nil, { noModuleDefaults = true, noDefinitionList = true, noCurrentList = true }))
  noted("containers.classes_source", "none", kC .. ": 0 learned, 0 slots read", "nothing readable")
  local kE = freshKind()
  visit(place(kE))
  noted("containers.classes_source", "default inventory", kE .. ": 3 learned, 4 slots read")
  local kD = freshKind()
  visit(place(kD, {}))                 -- the game's lists for it hold nothing the data knows
  noted("containers.classes_source", "none", kD .. ": 0 learned, 2 slots read, e.g. ItKe_Quest_Key_99 is not in the data", "lists readable, items unknown")
  check(list(F.values("containers.classes_source")) == "default inventory > definition list > current contents > none > default inventory > none",
    "note containers.classes_source follows the list that taught the classes")

  H.io.noComponent = true
  local kF = freshKind()
  visit(place(kF))
  H.io.noComponent = false
  noted("containers.data_module_source", "library", kF, "the object's own module list is not available")
  check(F.crumbCount("U.findStatic /Script/G1R.Default__DataModuleLibrary") == 1, "(with a line before the search for the library)")
  local kG = freshKind()
  visit(place(kG))
  noted("containers.data_module_source", "module list", kG)
  times("containers.data_module_source", 3)

  local dm = W.settle.actor.__dm
  local cls = H.itemClass(KDB[settleName].i[1][1])
  H.io.outMode = "wrapped"; T.chests._countOne(dm, cls, 2); T.chests._countOne(dm, cls, 2)
  noted("containers.count_form", "wrapped count")
  H.io.outMode = "none"; T.chests._countOne(dm, cls, 2); T.chests._countOne(dm, cls, 2)
  noted("containers.count_form", "yes-no only")
  H.io.outMode = "count"; H.io.hasThrows = true; T.chests._countOne(dm, cls, 2); T.chests._countOne(dm, cls, 2)
  noted("containers.count_form", "call failed", "^.*registered handler")
  H.io.hasThrows = false; T.chests._countOne(dm, cls, 2)
  check(list(F.values("containers.count_form")) == "count > wrapped count > yes-no only > call failed > count", "note containers.count_form follows the form the count comes back in")

  local kH = freshKind()
  H.io.addFailsFor = kH
  lootAndWin(place(kH))
  H.io.addFailsFor = nil
  noted("containers.restock_result", "nothing arrived", kH .. ": 0 of 8")
  local kI = freshKind()
  H.io.addPartialFor = kI
  lootAndWin(place(kI))
  H.io.addPartialFor = nil
  noted("containers.restock_result", "partial", kI .. ": 2 of 8")
  lootAndWin(W.wild)
  check(isFull(W.wild), "(a chest restocked completely)")
  noted("containers.restock_result", "complete", wildName .. ": 30 of 30")
  local kJ = freshKind()
  local J = place(kJ)
  lootAndWin(J)
  times("containers.restock_result", 4, "- the same result twice in a row is not passed on again")
  H.io.addPartialFor = kJ
  reload(J)
  H.io.addPartialFor = nil
  noted("containers.putback_result", "partial", kJ .. ": 2 of 8")
  local kK = freshKind()
  local Kc = place(kK)
  lootAndWin(Kc)
  H.io.addFailsFor = kK
  reload(Kc)
  H.io.addFailsFor = nil
  noted("containers.putback_result", "nothing arrived", kK .. ": 0 of 8")
  reload(W.wild)
  check(isFull(W.wild), "(a restock put back completely)")
  noted("containers.putback_result", "complete", wildName .. ": 30 of 30")
  check(list(F.values("containers.putback_result")) == "complete > partial > nothing arrived > complete", "note containers.putback_result follows what arrived")
  times("containers.definition_source", 1, "- only the first container recognised in a run")
  check(H.io.banned == 0, "still no read of a property that must not be read (" .. H.io.banned .. ")")

  -- crime switch: problems and waiting
  setConfig({})
  T.reload(false); ticks(2)
  H.player = { PARK[1], PARK[2], 0 }
  H.crime.noForEach = true
  setConfig({ OFF_ALL }); T.reload(false); ticks(8)      -- (the rule sets are searched for when a search is due)
  check(tostring(F.value("crime.rule_tables")):find("^the rule table cannot be read") ~= nil, "note crime.rule_tables carries the problem text (" .. tostring(F.value("crime.rule_tables")) .. ")")
  H.crime.noForEach = false
  ticks(44)
  noted("crime.rule_tables", "66 rules in 3 sets", "off: theft, trespassing, weapons")
  setConfig({ OFF_ALL, { "DisableTheft = true,", "DisableTheft = false," }, { "DisableTrespassing = true,", "DisableTrespassing = false," } })
  T.reload(false); ticks(2)
  noted("crime.rule_tables", "33 rules in 3 sets", "off: weapons")
  setConfig({ OFF_ALL, { "DisableWeapons = true,", "DisableWeapons = false," } })
  T.reload(false); ticks(2)
  noted("crime.rule_tables", "33 rules in 3 sets", "off: theft, trespassing", "same numbers, other kinds: passed on again")
  E.mapLoad(); makeCrimeWorld()
  H.crime.noWorld = true
  ticks(100)
  noted("crime.rule_tables", "no crime subsystem found yet", "off: theft, trespassing")
  H.crime.noWorld = false
  ticks(100)
  noted("crime.rule_tables", "33 rules in 3 sets", "off: theft, trespassing")
  setConfig({})
  T.reload(false); ticks(2)
  check(gateTagsOf(GI) == "" and gateTagsOf(GT) == "" and F.value("crime.noise_module.Interaction") == "open" and F.value("crime.noise_module.Trespassing") == "open",
    "(crime on again: both noise modules open)")
  H.gate.fieldSet, H.gate.tableSet = false, false
  local gi0 = F.count["crime.noise_module.Interaction"]
  setConfig({ OFF_ALL }); T.reload(false); ticks(2)
  ticks(400)                           -- three tries, then left alone
  H.gate.fieldSet, H.gate.tableSet = true, true
  check(tostring(F.value("crime.noise_module.Interaction")):find("AIARM_ToInvestigateSuspiciousSound_Interaction did not take the tag", 1, true) ~= nil
    and tostring(F.value("crime.noise_module.Trespassing")):find("did not take the tag", 1, true) ~= nil,
    "notes crime.noise_module.* carry the reason a module was not switched (" .. tostring(F.value("crime.noise_module.Interaction")) .. ")")
  check(F.count["crime.noise_module.Interaction"] == gi0 + 1, "the reason is passed on once for the three tries")
  setConfig({}); T.reload(false); ticks(2)
  setConfig({ OFF_ALL }); T.reload(false); ticks(2)
  noted("crime.noise_module.Interaction", "closed")
  noted("crime.noise_module.Trespassing", "closed")
  local cTheft = addCrime("Crime.Theft")
  ticks(130)
  check(CrimeMem.__crimes[cTheft] == nil, "(another theft forgotten)")
  noted("crime.forgotten", 3)
  times("crime.forgotten", 2)
  setConfig({}); T.reload(false); ticks(2)
  local repeated = {}
  for k in pairs(F.count) do
    if not F.neverRepeated(k) then repeated[#repeated + 1] = k end
    if not KEYS[k] then unknownKeys[#unknownKeys + 1] = tostring(k) end
  end
  table.sort(repeated)
  check(#repeated == 0 and #unknownKeys == 0, ("in the whole run no note was passed on twice in a row unchanged (%d notes of %d keys%s)")
    :format(#F.notes, count(F.count), #repeated > 0 and (", repeated: " .. table.concat(repeated, ", ")) or ""))
  local d2 = F.dump[1]()
  local ok2, where2 = FK.plain(d2, 4)
  local back2 = FK.roundTrip(d2)
  local failedRows, leftOut = 0, type(d2) == "table" and d2.containers.left_out or {}
  for _, r in ipairs(type(d2) == "table" and d2.containers.tracked or {}) do if r.failed then failedRows = failedRows + 1 end end
  check(ok2 and back2 and failedRows >= 4, ("the dump is still plain data after all that (%s tracked containers, %d of them failed%s)")
    :format(tostring(ok2 and #d2.containers.tracked), failedRows, ok2 and "" or (": " .. tostring(where2))))

  -- ---------------------------------------------------------------- a run that starts differently
  print("== diagnostics hooks: facts that are settled at the first look\n")
  freshWorld()
  for i = #States, 1, -1 do States[i] = nil end
  for i = 1, CDB[P_SPATIAL].s[1].n do          -- creatures whose ids name no spawn point, all close to the player
    addState(CDB[P_SPATIAL].s[1].u, P_SPATIAL, i, { id = CDB[P_SPATIAL].s[1].u .. "-AIScript-" .. i })
  end
  H.player = { CDB[P_SPATIAL].x + 5000, CDB[P_SPATIAL].y, 0 }
  PDS.m_CurrentProfileId = nil                 -- no profile id readable
  H.io.noGetter = true                         -- the game's getter for the definition is not there
  local F2 = FK.new()
  local T2 = loadMod(F2)
  ticks(4); ticks(52)
  check(lastLog("session started") == nil, "the id of the profile is not readable: the session does not start on the default progress file at once")
  ticks(84)                                    -- it waits 20 s for the id (asked every 5 s), then starts
  check(countLogs("no progress file is read or written until it can be") == 1, "after 20 s it starts without a progress file and says so")
  H.game = nextBoundary(24) + 10; ticks(80)
  H.io.noGetter = false
  PDS.m_CurrentProfileId = 2
  local function noted2(key, value, detail)
    local v, d = F2.value(key), F2.detail(key)
    local okDetail = detail == nil or d == detail or (type(d) == "string" and type(detail) == "string" and detail:sub(1, 1) == "^" and d:find(detail) ~= nil)
    if type(detail) == "table" then
      okDetail = false
      for _, one in ipairs(detail) do if d == one then okDetail = true end end
      detail = table.concat(detail, " or ")
    end
    check(v == value and okDetail, ("note %s = %s%s (got %s / %s)"):format(key, tostring(value), detail and (" (" .. detail .. ")") or "", tostring(v), tostring(d)))
  end
  check((lastLog("session started") or ""):find("state profile_default (not written)", 1, true) ~= nil and io.open(DIR .. "state/profile_default.lua") == nil,
    "(session started without a progress file: none is written)")
  noted2("core.profile", "default", "not written")
  noted2("creatures.ids_carry_point_names", false, "^sample ids: " .. CDB[P_SPATIAL].s[1].u .. "%-AIScript%-1, ")
  noted2("creatures.far_states_visible", false, "^farthest living creature seen %d+ m away$")
  noted2("containers.definition_source", "component", { settleName, wildName })
  check((F2.count["core.profile"] or 0) == 1 and (F2.count["creatures.ids_carry_point_names"] or 0) == 1 and (F2.count["creatures.far_states_visible"] or 0) == 1
    and (F2.count["containers.definition_source"] or 0) == 1, "each of them passed on once")
  local d3 = F2.dump[1]()
  check(FK.plain(d3, 4) and type(d3) == "table" and d3.profile == "profile_default" and d3.creatures.far_states_visible == false and d3.creatures.ids_carry_point_names == false
    and d3.containers.tracked[1] and d3.containers.tracked[1].definition == "component", "and the dump shows the same")
  os.remove(DIR .. "state/profile_default.lua")

  -- ---------------------------------------------------------------- util.lua on its own: lines before searches
  print("== diagnostics hooks: lines before searches by path (util.lua)\n")
  do
    local F3 = FK.new()
    rawset(_G, "G1R_DIAG", F3.handle)
    local U3 = dofile(DIR .. "util.lua")
    rawset(_G, "G1R_DIAG", nil)
    local found, missing = "/Script/G1R.Default__AIScriptLibrary", "/Script/Angelscript.UNoSuchClass"
    check(U3.findStatic(found) ~= nil and U3.findStatic(found) ~= nil and U3.findStatic(found) ~= nil and F3.crumbCount("U.findStatic " .. found) == 1,
      "a path that is found: one line before the first search, none before the next ones")
    check(U3.findStatic(missing) == nil and U3.findStatic(missing) == nil and F3.crumbCount("U.findStatic " .. missing) == 2,
      "a path that is not found: a line before every search (each of them walks all objects)")
    local U4 = dofile(DIR .. "util.lua")
    check(U4.findStatic(found) ~= nil and U4.findStatic(missing) == nil and #F3.crumbs == 3, "without the handle: the same answers, no lines")
  end

  -- ---------------------------------------------------------------- through a module environment like the loader's
  print("== diagnostics hooks: the mod inside a module environment (megamod SPEC section 4)\n")
  freshWorld()
  local F4 = FK.new()
  local hook = {}
  local before = FK.keys(_G)
  local env, run = FK.sandbox({ G1R_DIAG = F4.handle, REPOP_TEST = hook, print = _G.print })
  local envBefore = FK.keys(env)
  rawset(_G, "REPOP_TEST", nil)
  local okRun, errRun = run(DIR .. "main.lua")
  E.afterLoad()
  check(okRun, "main.lua loads in an environment of its own" .. (okRun and "" or (": " .. tostring(errRun))))
  check(type(hook.status) == "function" and rawget(_G, "REPOP_TEST") == nil and rawget(_G, "G1R_DIAG") == nil,
    "it sees G1R_DIAG and its test hook there, not in the real globals")
  if okRun and type(hook.reload) == "function" then
    ticks(4); ticks(40)
    H.game = nextBoundary(24) + 10; ticks(80)
    playerOpens(W.settle, takeDefaults(W.settle)); ticks(4)
    setRandom(0.2); H.game = H.game + 86400 + 60; ticks(40)
    addCrime("Crime.Theft")
    setConfig({ OFF_ALL }); hook.reload(false); ticks(8)
    setConfig({}); hook.reload(false); ticks(8)
    hook.console("repop status", nil, nil)
    check(lastLog("session started") ~= nil and #H.spawns >= 4 and isFull(W.settle) and (hook.chests.stats()).refilled == 1 and CrimeMem.__next == 2 and count(CrimeMem.__crimes) == 0,
      ("it works there: session, %d respawns, a restock, crime switch"):format(#H.spawns))
    local files = {}
    for _, k in ipairs({ "core.game_time_source", "core.profile", "items.configs_set", "creatures.states_class", "containers.definition_source", "crime.rule_tables" }) do
      if not F4.count[k] then files[#files + 1] = k end
    end
    check(#files == 0 and #F4.versions == 1 and #F4.status == 1 and #F4.dump == 1 and #F4.crumbs >= 4,
      "every file of the mod got the handle through the shared environment (notes from util, main, items, creatures, chests, crime" .. (#files > 0 and ("; missing: " .. table.concat(files, ", ")) or "") .. ")")
  end
  local newGlobals, newInEnv = FK.newKeys(_G, before), FK.newKeys(env, envBefore)
  check(#newGlobals == 0, "nothing new in the real globals after loading and running it (" .. table.concat(newGlobals, ", ") .. ")")
  check(#newInEnv == 0, "and the mod defines no global of its own either (" .. table.concat(newInEnv, ", ") .. ")")
  rawset(_G, "REPOP_TEST", nil)

  -- ---------------------------------------------------------------- the megamod's own recorder and module loader
  -- The same stretch of play once more, with the real Scripts/core/diag.lua and Scripts/core/sandbox.lua
  -- instead of the stand-in: what the mod does must stay the same, and the files the recorder writes must
  -- show the session (they are what is looked at after a real play session).
  print("== diagnostics: the stretch of play through the megamod's module loader and recorder\n")
  ;(function()
    local CORE = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./") .. "../../../Scripts/core/"
    local root = TMP .. "megamod"
    os.execute("rm -rf " .. root .. " && mkdir -p " .. root .. "/Scripts/diagnostics")
    local said = {}
    local Diag = dofile(CORE .. "diag.lua")
    local Sandbox = dofile(CORE .. "sandbox.lua")
    local started = Diag.init(root, { Level = "normal" }, function(text) said[#said + 1] = text end, { name = "G1R_MegaMod", version = "0.0.0-test" })
    Sandbox.init(Diag, _G.print)
    check(started == true and Diag.enabled == true, "the recorder starts in a folder of the test")
    freshWorld()
    local hook2 = {}
    local wasQuiet2 = QUIET
    QUIET = true
    local calls = counted(function()
      local env2 = Sandbox.environment("repopulate")
      env2.REPOP_TEST = hook2
      local chunk = assert(loadfile(DIR .. "main.lua", nil, env2))
      chunk()
      E.afterLoad()
      play(hook2)
    end)
    QUIET = wasQuiet2
    local sigC = signature(hook2, calls)
    -- the loader asks IsValid() of what a search by path returned, the stand-in did not: that count differs
    local function without(sig)
      local out = {}
      for _, l in ipairs(sig) do if not l:find("^calls: IsValid") then out[#out + 1] = l end end
      return out
    end
    local b, c = without(sigB), without(sigC)
    local diffAt
    for i = 1, math.max(#b, #c) do if b[i] ~= c[i] then diffAt = i; break end end
    check(diffAt == nil and #c > 40, ("the mod logs, counts, calls and stores exactly what it did with the stand-in (%d lines compared%s)")
      :format(#c, diffAt and (", first difference in line " .. diffAt .. ":\n      stand-in: " .. tostring(b[diffAt]) .. "\n      loader:   " .. tostring(c[diffAt])) or ""))
    Diag.flush()
    local reportPath = Diag.report(true)
    local dumpPath = Diag.dump()
    local function readAll(path)
      local f = path and io.open(path, "r")
      if not f then return nil end
      local text = f:read("a")
      f:close()
      return text
    end
    local report, dumpText = readAll(reportPath), readAll(dumpPath)
    local sessionName = report and report:match("session log: (session%-%d+%-%d+%.log)")
    local log = sessionName and readAll(root .. "/Scripts/diagnostics/" .. sessionName)
    check(report ~= nil and dumpText ~= nil and log ~= nil, "session log, report and dump are written")
    report, dumpText, log = report or "", dumpText or "", log or ""
    check(log:find("[repopulate] [G1R_Repopulate] v" .. F.versions[1] .. " loaded: ", 1, true) ~= nil and log:find("[repopulate] [G1R_Repopulate] session started", 1, true) ~= nil,
      "session log: what the mod printed, under its module name")
    -- the notes in the session log are the facts the stand-in was given, in the same order
    local noted = {}
    for key, value in log:gmatch("%[repopulate%] note (%S+) = ([^\n]*)") do
      value = value:gsub(" %[was .-%]$", ""):gsub(" %(further changes of this note are only counted%)$", "")
      noted[#noted + 1] = key .. "=" .. value
    end
    local want = {}
    for i = 1, notesOfPlay do
      local n = F.notes[i]
      want[#want + 1] = tostring(n.key) .. "=" .. tostring(n.value) .. (n.detail ~= nil and (" (" .. tostring(n.detail) .. ")") or "")
    end
    local noteDiff
    for i = 1, math.max(#noted, #want) do if noted[i] ~= want[i] then noteDiff = i; break end end
    check(noteDiff == nil and #noted >= 15, ("session log: the %d notes of the stretch, as the stand-in got them%s"):format(#noted,
      noteDiff and (" - first difference at " .. noteDiff .. ": '" .. tostring(noted[noteDiff]) .. "' / '" .. tostring(want[noteDiff]) .. "'") or ""))
    -- searches by path: each announced on disk before it ran, none repeated
    local nCalls, nFirst, nMissing, nRepeated = report:match("%[repopulate%] lookups: (%d+) calls, (%d+) first%-time, (%d+) not found, (%d+) repeated after not found")
    nCalls, nFirst, nMissing, nRepeated = tonumber(nCalls), tonumber(nFirst), tonumber(nMissing), tonumber(nRepeated)
    local crumbs, results = 0, 0
    for _ in log:gmatch("%[repopulate%] > lookup /") do crumbs = crumbs + 1 end
    for _ in log:gmatch("%[repopulate%] lookup /[^\n]-: f?o?u?n?d?N?O?T? ?F?O?U?N?D?,") do results = results + 1 end
    check(nCalls ~= nil and nFirst >= 5 and nRepeated == 0, ("report: %s searches by path, %s of them first-time, %s not found, %s repeated after not found")
      :format(tostring(nCalls), tostring(nFirst), tostring(nMissing), tostring(nRepeated)))
    check(crumbs == nFirst and results == nFirst, ("session log: a breadcrumb before each first-time search and its result after it (%d / %d of %s)"):format(crumbs, results, tostring(nFirst)))
    check(not log:find("NOT FOUND again", 1, true) and not log:find("ERROR in ", 1, true) and report:find("\ncount: 0 %(0 distinct%)") ~= nil and #said == 0,
      "no repeated search, no error recorded, nothing said to UE4SS.log by the recorder")
    local loops, loopErrors = report:match("%[repopulate%] callbacks LoopInGameThreadWithDelay: (%d+) calls, (%d+) errors")
    check(tonumber(loops or 0) > 1500 and loopErrors == "0" and report:find("%[repopulate%] registered RegisterHook: 1 ok, 0 failed") ~= nil
      and report:find("%[repopulate%] registered RegisterConsoleCommandHandler: 2 ok, 0 failed") ~= nil
      and report:find("%[repopulate%] callbacks RegisterLoadMapPreHook: " .. (ENGINE and 2 or 1) .. " calls, 0 errors") ~= nil,
      ("report: %s timer calls and the map-load callback went through the guard without an error; hook and console commands registered once"):format(tostring(loops)))
    if ENGINE then
      local nB, eB = report:match("%[repopulate%] callbacks RegisterBeginPlayPostHook: (%d+) calls, (%d+) errors")
      local nE, eE = report:match("%[repopulate%] callbacks RegisterEndPlayPreHook: (%d+) calls, (%d+) errors")
      check(tonumber(nB or 0) > 20 and eB == "0" and tonumber(nE or 0) > 2 and eE == "0"
        and report:find("%[repopulate%] registered RegisterBeginPlayPostHook: 1 ok, 0 failed") ~= nil
        and report:find("%[repopulate%] registered RegisterEndPlayPreHook: 1 ok, 0 failed") ~= nil
        and report:find("%[repopulate%] callbacks RegisterLoadMapPostHook: 2 calls, 0 errors") ~= nil,
        ("ENGINE report: the begin / end of play callbacks went through the guard too (%s and %s calls, no error)"):format(tostring(nB), tostring(nE)))
    end
    check(report:find("== status ==\n[repopulate] v" .. F.versions[1] .. " | day ", 1, true) ~= nil and report:find("repopulate: loaded, version " .. F.versions[1], 1, true) == nil
      and report:find("%[repopulate%]\ncontainers%.") ~= nil, "report: the mod's status lines and its notes")
    local chunk = load(dumpText, "=dump", "t", {})
    local okDump, dump = pcall(chunk or error)
    check(okDump and type(dump) == "table" and type(dump.repopulate) == "table" and dump._meta.modules.repopulate == "dumped" and dump._meta.refusedCount == 0,
      "dump: loads, holds the mod's table, nothing in it was refused")
    local shown = {}
    for k in pairs(okDump and dump.repopulate or {}) do shown[#shown + 1] = tostring(k) end
    table.sort(shown)
    check(#shown >= 4, "dump: " .. table.concat(shown, ", "))
  end)()
  H.logs = mainLogs
end)()

-- ================================================================ the game's AI script library is missing
-- A fresh load of the mod (what it remembers about searches is kept per run): the point without a script
-- instance has creatures to bring back, and the library that would do it cannot be found.
print("== creatures: the AI script library cannot be found\n")
;(function()
  local keepLogs = H.logs
  H.logs = {}
  H.noAiLib = true
  H.sfo.ai = 0
  for _, name in ipairs({ "profile_2.lua", "profile_2.lua.tmp" }) do os.remove(DIR .. "state/" .. name) end
  _G.REPOP_TEST = {}
  dofile(DIR .. "main.lua")
  local T2 = _G.REPOP_TEST
  E.afterLoad()
  local want = CDB[P_HALF].s[1].n - 1
  for i = 1, want do addState(CDB[P_HALF].s[1].u, P_HALF, 500 + i, { dead = true }) end
  setRandom(0.0)
  H.spawns = {}
  local cycles = 0
  for _ = 1, 3 do
    H.game = (math.floor(H.game / 86400) + 1) * 86400 + 10
    ticks(80)
    cycles = cycles + 1
  end
  local viaLibrary, atPoint = 0, 0
  for _, sp in ipairs(H.spawns) do
    if sp.how == "library" then viaLibrary = viaLibrary + 1 end
    if sp.point == P_HALF then atPoint = atPoint + 1 end
  end
  local failedLines = 0
  for _, l in ipairs(H.logs) do if l:find("no%-spawner") then failedLines = failedLines + 1 end end
  check(viaLibrary == 0 and atPoint == 0, "nothing can be spawned at the point without a script instance")
  check(H.sfo.ai == 1, ("the library was searched for once in %d creature cycles with %d creatures to bring back each (%d searches)"):format(cycles, want, H.sfo.ai))
  check(failedLines >= 1, ("and the failure is logged (%d line(s))"):format(failedLines))
  local _, queue = T2.creatures.stats()
  check(type(T2.status) == "function" and #T2.status() >= 4, "the mod keeps running (status lines)")
  H.noAiLib = false
  H.logs = keepLogs
end)()

-- ================================================================ the main menu: a world without a game clock
-- Version 1.3 searched for the clock among all objects at every update while there was none: 9325 times in the
-- 40 minutes one logged session sat in the main menu.
print("== the main menu: no game clock - it is looked for now and then, not at every update\n")
;(function()
  E.freshWorld()
  H.menu = true
  local T2 = E.loadMod(E.FK.new())
  H.finds = {}
  local started = countLogs("session started")
  ticks(2400)                           -- ten minutes
  local n = H.finds.GameTimeSubsystem or 0
  local others = 0
  for cls, c in pairs(H.finds) do if cls ~= "GameTimeSubsystem" and cls ~= "GothicPlayerControllerBaseBP_C" then others = others + c end end
  check(n == 10 and others == 0 and countLogs("session started") == started,
    ("ten minutes without a game clock: it is searched for %d times, with growing pauses; nothing else is searched for (%d), no session starts (%d)")
      :format(n, others, countLogs("session started") - started))
  ticks(2400)
  check((H.finds.GameTimeSubsystem or 0) - n == 5, ("and every two minutes after that (%d in the next ten)"):format((H.finds.GameTimeSubsystem or 0) - n))
  -- a save is loaded: a map load, and the clock is there
  H.menu = nil
  n = H.finds.GameTimeSubsystem or 0
  E.mapLoad()
  ticks(80)
  check(countLogs("session started") == started + 1 and (H.finds.GameTimeSubsystem or 0) - n == (ENGINE and 0 or 1),
    ("a game is loaded: the clock is there at once (%s), the session starts"):format(ENGINE and "the engine hands it out" or "one search"))
  check(type(T2.status) == "function", "(the mod runs on)")
end)()

-- What the scenario files below need from this one (the main chunk is at Lua's limit of local variables).
E.X = {
  H = H, E = E, check = check, ticks = ticks, lastLog = lastLog, countLogs = countLogs, setConfig = setConfig, setRandom = setRandom,
  obj = obj, addState = addState, States = States, makeChest = makeChest, streamIn = streamIn, streamOut = streamOut,
  playerOpens = playerOpens, takeDefaults = takeDefaults, isFull = isFull, CDB = CDB, KDB = KDB, PDS = PDS, Pawn = Pawn, DIR = DIR,
  Configs = Configs, settleName = settleName, wildName = wildName,
  P_EMPTY = P_EMPTY, P_ELITE = P_ELITE, P_HALF = P_HALF, farName = farName,
  ENGINE = ENGINE, HERE = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"),
}

-- ================================================================ main.lua's own parts, both modes (main_cases.lua)
assert(loadfile(E.X.HERE .. "main_cases.lua"))(E.X)

-- ================================================================ ENGINE: scenarios of their own (engine_cases.lua)
if ENGINE then assert(loadfile(E.X.HERE .. "engine_cases.lua"))(E.X) end

-- ================================================================ ENGINE: the whole run
if ENGINE then (function()
  local seen, kinds = {}, {}
  for _, t in ipairs(E.touched) do if not seen[t] then seen[t] = true; kinds[#kinds + 1] = t end end
  check(#E.touched == 0, ("ENGINE: in the whole run nothing of an object was touched after it had left play (%d accesses%s)")
    :format(#E.touched, #kinds > 0 and (": " .. table.concat(kinds, "; ", 1, math.min(#kinds, 6))) or ""))
  check(H.configsGrown == 0, "ENGINE: the manager's list of points was never read past its end (" .. H.configsGrown .. ")")
  local classes = {}
  for cls, n in pairs(H.finds) do classes[#classes + 1] = cls .. " x" .. n end
  table.sort(classes)
  io.write("    searches among all objects in the whole run: " .. table.concat(classes, ", ") .. "\n")
end)() end

print(("== harness finished: %d ok, %d failure(s)\n"):format(oks, fails))
os.exit(fails == 0 and 0 or 1)
