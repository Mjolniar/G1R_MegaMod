-- Offline integration harness for NPCMarkers: emulates the UE4SS Lua API
-- surface the mod uses and runs the real main.lua against fixtures.
-- Expected positions for the 12 reference NPCs come from an independent
-- Python reimplementation (fixture.lua); the full-list scenario checks
-- against projection.lua (itself verified against Python, 4,890 vectors).
local REAL_CLOCK = os.clock
-- Paths: the module under test is found relative to this file; G1R_MARKERS_SRC / G1R_TEST_TMP override.
local HERE = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./")
local SRC = os.getenv("G1R_MARKERS_SRC") or (HERE .. "../../../modules/markers/Scripts/")
local TMPROOT = (os.getenv("G1R_TEST_TMP") or "/tmp/g1r-tests")
local TMP = TMPROOT .. "/h23/"
local FIX = dofile(HERE .. "fixture.lua")
-- the version the module says it is (texts of it are compared below)
local VER = (function() local f = assert(io.open(SRC .. "main.lua", "r")); local t = f:read("a"); f:close(); return t:match('local VERSION = "([^"]+)"') end)()
local VERP = VER:gsub("%p", "%%%0")
local NO_PICTURES = "pictures: 0 loaded (0 kept alive for the whole run), 0 loaded again; images: 0 did not take their picture, 0 given a new loading of it"
local Proj = dofile(SRC .. "projection.lua")
local LAYOUT_OUT = TMPROOT .. "/h23_layout.tsv"

-- mod copies with test configs -------------------------------------------------
os.execute("rm -rf " .. TMP .. " && mkdir -p " .. TMP)
local function modCopy(name, extraConfig)
  local d = TMP .. name .. "/"
  os.execute(("mkdir -p %s && cp -r %s* %s"):format(d, SRC, d))
  if extraConfig then
    local f = io.open(d .. "config.lua", "w")
    f:write("local C = dofile('" .. SRC .. "config.lua')\n" .. extraConfig .. "\nreturn C\n")
    f:close()
  end
  return d
end
local IDS12 = {}
for id in pairs(FIX.live) do IDS12[#IDS12 + 1] = id end
table.sort(IDS12)
local list12 = "local all = dofile('" .. SRC .. "npcs.lua'); local keep = {"
for _, id in ipairs(IDS12) do list12 = list12 .. "['" .. id .. "']=true," end
list12 = list12 .. "}; C.NPCs = {}; for _, d in ipairs(all) do if keep[d.id] then C.NPCs[#C.NPCs+1] = d end end"
-- the 12-NPC scenarios check single pins: pools off there
local DIR12 = modCopy("m12", list12 .. "\nC.WorldPools = false")
local DIR12NOAVOID = modCopy("m12na", list12 .. "\nC.WorldPools = false; C.LegendAvoidButtons = false")
local DIRALWAYS = modCopy("malways", list12 .. "\nC.WorldPools = false; C.AreaLabels = 'always'; C.WorldLabels = 'always'")
local DIRFULLALWAYS = modCopy("mfullalways", "C.AreaLabels = 'always'")
local DIRFULL = modCopy("mfull", nil)
local DIRFULLNOPOOL = modCopy("mfullnopool", "C.WorldPools = false")

-- mock objects ------------------------------------------------------------------
local H = { logs = {}, now = 100.0, staticCalls = {} }
local addr = 0x1000
local Base = {}
Base.__index = Base
function Base:IsValid() return self.__valid ~= false end
function Base:GetAddress() return self.__addr end
function Base:GetFullName() return self.__class .. " " .. (self.__path or "/Engine/Transient.") .. self.__name end
function Base:GetParent() return self.__parent end
function Base:RemoveFromParent()
  if self.__parent then
    local kids = self.__parent.__children
    for i = #kids, 1, -1 do if kids[i] == self then table.remove(kids, i) end end
  end
  self.__parent = nil
end
local function obj(class, name, t)
  t = t or {}
  addr = addr + 8
  t.__class, t.__name, t.__addr = class, name or (class .. "_" .. addr), addr
  return setmetatable(t, Base)
end
local function FNameObj(s) return { ToString = function() return s end, __s = s } end
local function tag(s) return { TagName = FNameObj(s) } end
local function vec(x, y, z) return { X = x, Y = y, Z = z } end

local Created = { images = 0, canvases = 0 }
local SlotCalls = 0
local function newSlot(owner, child)
  local s = obj("CanvasPanelSlot")
  s.calls, s.count = {}, {}
  for _, fn in ipairs({ "SetAnchors", "SetAlignment", "SetPosition", "SetSize", "SetAutoSize", "SetOffsets", "SetZOrder",
      "SetHorizontalAlignment", "SetVerticalAlignment", "SetPadding" }) do
    s[fn] = function(self, v) self.calls[fn] = v; self.count[fn] = (self.count[fn] or 0) + 1; SlotCalls = SlotCalls + 1 end
  end
  s.child, s.owner = child, owner
  return s
end
local function newCanvas(name)
  local c = obj("CanvasPanel", name)
  c.__children = {}
  c.AddChildToCanvas = function(self, child)
    -- (H.slotFail(canvas, child) -> true: this call gives no place in the canvas)
    if H.slotFail and H.slotFail(self, child) then
      return obj("CanvasPanelSlot", "None", { __valid = false })
    end
    child.__parent = self
    table.insert(self.__children, child)
    child.Slot = newSlot(self, child)
    return child.Slot
  end
  c.SetVisibility = function(self, v) self.vis = v end
  c.IsHovered = function(self)
    if H.panelHover == "never" then return false end
    for _, k in ipairs(self.__children) do if k.hover then return true end end
    return false
  end
  return c
end
local function newOverlay(name)
  local o = obj("Overlay", name)
  o.__children = {}
  o.GetDesiredSize = function() return { X = 1600.0, Y = 900.0 } end
  o.AddChildToOverlay = function(self, child)
    child.__parent = self
    table.insert(self.__children, child)
    child.Slot = newSlot(self, child)
    return child.Slot
  end
  return o
end
local function newImage(name)
  local i = obj("Image", name)
  -- H.brushFail(image, texture) -> true: the call raises; H.brushSilent(...) -> true: it returns and has set
  -- nothing; H.brush: the image's brush can be read back (Brush.ResourceObject), as in the game
  i.SetBrushFromTexture = function(self, t, matchSize)
    self.brushCalls = (self.brushCalls or 0) + 1
    H.brushCalls = (H.brushCalls or 0) + 1
    if matchSize ~= false then H.matchSize = (H.matchSize or 0) + 1 end       -- (the mod sizes its images itself)
    if H.brushFail and H.brushFail(self, t) then error("SetBrushFromTexture: the call did not go through") end
    if H.brushSilent and H.brushSilent(self, t) then return end
    self.tex = t
    if self.Brush then self.Brush.ResourceObject = t end
  end
  if H.brush then i.Brush = {} end
  i.SetVisibility = function(self, v) self.vis = v; self.visCalls = (self.visCalls or 0) + 1 end
  i.SetColorAndOpacity = function(self, c) self.color = c end
  i.IsHovered = function(self) return self.hover == true end
  i.SetBrushSize = function(self, v) self.brushSize = v end
  i.SetDesiredSizeOverride = function(self, v) self.desired = v end
  return i
end

local function pngSize(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local d = f:read(32); f:close()
  return string.unpack(">I4I4", d, 17)
end
local KRL = obj("KismetRenderingLibrary", "Default__KismetRenderingLibrary")
H.imports = 0
KRL.ImportFileAsTexture2D = function(self, world, path)
  local w, h = pngSize(path)
  H.imports = H.imports + 1
  if not w then return obj("Texture2D", "None", { __valid = false }) end
  local t = obj("Texture2D", path:match("([^/]+)$"))
  t.__path = path
  t.Blueprint_GetSizeX = function() return w end
  t.Blueprint_GetSizeY = function() return h end
  return t
end

local World = obj("World", "MainMap")
local Pawn = obj("BP_Hero_C", "Hero")
Pawn.K2_GetActorLocation = function() return vec(table.unpack(FIX.player)) end
local Ctrl = obj("GothicPlayerControllerBaseBP_C", "PC_0")
Ctrl.GetWorld = function() return World end
Ctrl.K2_GetPawn = function() return Pawn end

local Boxes = {}
for _, b in ipairs(FIX.boxes) do
  local a = obj(b.type == "W_MapBoundingBox_C" and "W_MapBoundingBox_C" or "ActorMapBoundingBox", b.name)
  a.ZoneTagMap = tag(b.tag)
  a.K2_GetActorLocation = function() return vec(b.loc[1], b.loc[2], b.loc[3]) end
  a.K2_GetActorRotation = function() return { Pitch = b.rot[1], Yaw = b.rot[2], Roll = b.rot[3] } end
  a.GetActorScale3D = function() return vec(b.scale[1], b.scale[2], b.scale[3]) end
  a.__tag, a.__type, a.__box = b.tag, b.type, { loc = b.loc, rot = b.rot, scale = b.scale }
  Boxes[#Boxes + 1] = a
end
local function boxBy(tagName, typ)
  for _, a in ipairs(Boxes) do if a.__tag == tagName and (not typ or a.__type == typ) then return a end end
end

H.npcMode = {}
local States = {}
local registry = {}
local function register(cls, o) registry[cls] = registry[cls] or {}; table.insert(registry[cls], o) end
local function addState(id, p)
  local s = obj("GothicNPCState", "GothicNPCState_" .. id)
  s.__pos = p
  s.GetCharacterLocation = function(self) return vec(self.__pos[1], self.__pos[2], self.__pos[3]) end
  s.IsDead = function() return H.npcMode[id] == "dead" end
  s.GetRemovedFromWorld = function() return false end
  s.GetCharacterUniqueName = function() return FNameObj(id) end
  States[id] = s
  register("GothicNPCState", s)
  return s
end
for id, p in pairs(FIX.live) do addState(id, p) end
local NpcCDO = obj("GothicNPCState", "Default__GothicNPCState")
H.staticBroken = false
NpcCDO.FindNPCByUniqueName = function(self, ctx, fname)
  if H.staticBroken then error("static call unsupported") end
  local id = fname.__s
  H.staticCalls[id] = (H.staticCalls[id] or 0) + 1
  if H.npcMode[id] == "missing" or not States[id] then return obj("GothicNPCState", "None", { __valid = false }) end
  return States[id]
end

local function newMapData(tmapMode)
  local md = obj("MapData", "MapData_0")
  md.m_WorldMapBoundingBox = boxBy("Area")
  if tmapMode == "readable" then
    md.m_AreaBoxesDataMap = {
      ForEach = function(self, fn)
        local function rp(v) return { get = function() return v end } end
        fn(rp(tag("Area")), rp(boxBy("Area")))
        fn(rp(tag("Area.OldCamp")), rp(boxBy("Area.OldCamp", "ActorMapBoundingBox")))
        fn(rp(tag("Area.NewCamp")), rp(boxBy("Area.NewCamp")))
      end,
    }
  else
    md.m_AreaBoxesDataMap = {}
  end
  return md
end
local function newMapWidget(name, tagName, canvasW, canvasH, playerExpect, md, uiW, uiH)
  uiW, uiH = uiW or 1600.0, uiH or 900.0
  local w = obj("W_Map_C", name)
  local general = newCanvas("CanvasPanel_General")
  local custom = newCanvas("CanvasPanel_CustomMarkers")
  general:AddChildToCanvas(custom)
  w.__general = general
  w.CanvasPanel_CustomMarkers = custom
  w.WidgetTree = obj("WidgetTree", name .. ".WidgetTree")
  w.MapImageSizeBox = obj("SizeBox", "MapImageSizeBox", { WidthOverride = canvasW, HeightOverride = canvasH })
  w.m_ActiveMapData = obj("UIMapConfigWorldHuman", "Cfg_" .. tagName,
    { MapTag = tag(tagName), UICustomSize = { X = uiW, Y = uiH }, IsPlayerInMap = playerExpect ~= nil })
  w.m_MapData = md
  if playerExpect then
    -- the fixture's player positions are in a 1600x900 UI; the game gives them in the map's own UI size
    local fx, fy = uiW / 1600.0, uiH / 900.0
    w.m_PlayerPosMapOriginal = { X = playerExpect.orig[1] * fx, Y = playerExpect.orig[2] * fy }
    w.m_PlayerPosMapCorrected = { X = playerExpect.corr[1] * fx, Y = playerExpect.corr[2] * fy }
  end
  w.IsBackground = false
  w.IsVisible = function() return w.__visible ~= false end
  w.__canvas = { uiW, uiH }       -- the layout size (what the pins are placed in)
  return w
end

register("GothicPlayerControllerBaseBP_C", Ctrl)
for _, a in ipairs(Boxes) do register(a.__type == "W_MapBoundingBox_C" and "W_MapBoundingBox_C" or "ActorMapBoundingBox", a) end

local QUIET = false
_G.print = function(s) H.logs[#H.logs + 1] = s; if not QUIET then io.write("    LOG ", s) end end
_G.FName = function(s) return { __s = s, ToString = function() return s end } end
_G.StaticFindObject = function(path)
  if path == "/Script/Engine.Default__KismetRenderingLibrary" then
    H.loaderLookups = (H.loaderLookups or 0) + 1
    if H.noPictureLoader then return nil end
    return KRL
  end
  if path == "/Script/G1R.Default__GothicNPCState" then return NpcCDO end
  if path == "/Script/UMG.CanvasPanel" then return obj("Class", "CanvasPanel") end
  if path == "/Script/UMG.Image" then return obj("Class", "Image") end
  return nil
end
_G.FindAllOf = function(cls)
  H.findAll = (H.findAll or 0) + 1; H.findAllBy = H.findAllBy or {}; H.findAllBy[cls] = (H.findAllBy[cls] or 0) + 1
  local list = registry[cls]
  if cls ~= "GothicNPCState" or not list then return list end
  local out = {}
  for _, o in ipairs(list) do
    local id = o.__name:gsub("^GothicNPCState_", "")
    if H.npcMode[id] ~= "missing" then out[#out + 1] = o end
  end
  return out
end
_G.StaticConstructObject = function(cls, outer)
  if cls.__name == "CanvasPanel" then Created.canvases = Created.canvases + 1; return newCanvas() end
  if cls.__name == "Image" then Created.images = Created.images + 1; return newImage() end
  error("unexpected class " .. tostring(cls.__name))
end
H.notify = {}
_G.NotifyOnNewObject = function(path, cb) H.notify[path] = cb end
_G.LoopInGameThreadWithDelay = function(ms, cb) H.loop = cb; H.loopMs = ms end
_G.RegisterLoadMapPreHook = function(cb) H.pre = cb end
_G.RegisterLoadMapPostHook = function(cb) H.post = cb end
os.clock = function() return H.now end

-- noNotify: "none" = this UE4SS has no NotifyOnNewObject, "raises" = it does not take the registration
local function loadMod(dir, noNotify)
  _G.NPCMARKERS_TEST = {}
  H.loop = nil
  local announce = _G.NotifyOnNewObject
  H.notify = {}
  if noNotify == "none" then _G.NotifyOnNewObject = nil end
  if noNotify == "raises" then _G.NotifyOnNewObject = function() error("NotifyOnNewObject: the class was not found") end end
  local ok, err = pcall(dofile, dir .. "main.lua")
  _G.NotifyOnNewObject = announce
  if not ok then error(err, 0) end
  assert(H.loop and H.loopMs == 150, "loop not registered")
  assert(noNotify or H.notify["/Game/UI/ManagementUI/Map/W_Map_Main.W_Map_Main_C"], "notify not registered")
  return _G.NPCMARKERS_TEST
end
local function notify(main) H.notify["/Game/UI/ManagementUI/Map/W_Map_Main.W_Map_Main_C"](main) end
local function tick(seconds)
  H.now = H.now + (seconds or 0.15)
  H.loop()
end

local fails, oks = 0, 0
local function check(cond, msg)
  if cond then oks = oks + 1; if not QUIET then print("  ok   " .. msg .. "\n") end
  else fails = fails + 1; io.write("  FAIL " .. msg .. "\n") end
end
local function close(a, b, eps) return a and b and math.abs(a - b) <= (eps or 1e-9) end
local function lastLogMatching(pat)
  for i = #H.logs, 1, -1 do if H.logs[i]:find(pat) then return H.logs[i] end end
end
local function ourPanel(mapWidget)
  for _, c in ipairs(mapWidget.__general.__children) do
    if c ~= mapWidget.CanvasPanel_CustomMarkers then return c end
  end
end
local function anchorIs(slot, u, v, eps)
  local a = slot and slot.calls.SetAnchors
  return a and close(a.Minimum.X, u, eps) and close(a.Minimum.Y, v, eps)
    and close(a.Maximum.X, u, eps) and close(a.Maximum.Y, v, eps)
end

-- verify the 12 reference NPCs against the Python-computed fixture ---------
local CFG = dofile(SRC .. "config.lua")
local function verify12(T, mapWidget, expectKey, label, o)
  o = o or {}
  local isArea = o.isArea == true
  local lmode = o.labels or (isArea and "auto" or "hover")
  local panel = ourPanel(mapWidget)
  check(panel ~= nil, label .. ": mod canvas attached to CanvasPanel_General")
  if not panel then return 0, 0 end
  check(#mapWidget.CanvasPanel_CustomMarkers.__children == 0, label .. ": game's own marker canvas untouched")
  local st = T.state(mapWidget)
  local e = FIX.expect[expectKey]
  local visible, labels = 0, 0
  local size = isArea and CFG.AreaPinSize or CFG.WorldPinSize
  local idle = isArea and CFG.AreaPinOpacity or CFG.WorldPinOpacity
  for _, def in ipairs(T.npcs) do
    local en = st and st.entries[def.id]
    local mode = H.npcMode[def.id] or "live"
    local want
    if mode == "missing" then want = e[def.id].approx elseif mode == "dead" then want = nil else want = e[def.id].live end
    if want then
      local ok = en and en.pin.__parent == panel and anchorIs(en.pinSlot, want[1], want[2]) and en.pin.vis == 0
      check(ok, ("%s: %s pin at uv %.5f,%.5f, hoverable"):format(label, def.id, want[1], want[2]))
      check(en and close(en.pinSlot.calls.SetSize.X, size) and close(en.pinSlot.calls.SetSize.Y, size),
        ("%s: %s pin size %g canvas units"):format(label, def.id, size))
      local alpha = (mode == "missing" and CFG.FallbackOpacity or 1.0) * idle
      check(en and en.pin.color and close(en.pin.color.A, alpha), ("%s: %s pin opacity %.3f until hovered"):format(label, def.id, alpha))
      local lab = en and en.label
      if lmode == "always" or (lmode == "auto" and en and en.autoPos) then
        check(lab and anchorIs(en.labelSlot, want[1], want[2]) and lab.vis == 3 and en.labelSlot.calls.SetAlignment.Y == 0,
          label .. ": " .. def.id .. " label shown at its pin")
        if lab then
          local tw, th = pngSize(lab.tex.__path)
          check(close(en.labelSlot.calls.SetSize.X, tw * CFG.LabelScale) and close(en.labelSlot.calls.SetSize.Y, th * CFG.LabelScale),
            label .. ": " .. def.id .. " label size = image x LabelScale")
          labels = labels + 1
        end
      else
        check(lab == nil or lab.vis == 1, label .. ": " .. def.id .. " no label until hovered")
      end
      visible = visible + 1
    else
      check(not en or en.pin.vis == 1, label .. ": " .. def.id .. " hidden (" .. mode .. ")")
    end
  end
  return visible, labels
end

local function freshSession() H.pre(); H.post(); H.npcMode = {}; H.staticBroken = false end
local function newMain(name, worldTag, areaTag, areaPlayer, tmap, worldW, worldH)
  local md = newMapData(tmap or "readable")
  local main = obj("W_Map_Main_C", name)
  main.IsActivated = function() return main.__active ~= false end
  main.WidgetTree = obj("WidgetTree", name .. ".WidgetTree")
  -- world map: the size box asks for 3840x2160, the layout is 1600x900
  main.Map_World = newMapWidget(name .. "_World", worldTag or "Area", worldW or 3840, worldH or 2160, FIX.expect.world.__player, md, 1600.0, 900.0)
  main.Map_Area = newMapWidget(name .. "_Area", areaTag or "Area.OldCamp", 1400, 860, areaPlayer, md, 1400.0, 860.0)
  main.__content = newOverlay("Overlay_Content")
  main.Overlay_Content = main.__content
  local holder = newOverlay("Overlay_WorldMap")
  main.__content:AddChildToOverlay(holder)
  holder:AddChildToOverlay(main.Map_World)
  main.__worldOverlay = holder
  local holderA = newOverlay("Overlay_AreaMap")
  main.__content:AddChildToOverlay(holderA)
  holderA:AddChildToOverlay(main.Map_Area)
  -- the game's button row (bottom right) and camp-name buttons
  local row = obj("HorizontalBox", "HBox_WorldMap")
  row.GetDesiredSize = function() return { X = H.rowW or 900.0, Y = H.rowH or 44.0 } end
  if not H.noButtonRow then
    main.Button_Close = obj("W_GenericButton_C", "Button_Close")
    main.Button_Close.__parent = row
  end
  for _, n in ipairs({ "Button_OldCamp", "Button_NewCamp", "Button_SwampCamp", "Button_OrcCamp", "Button_SleepersTemple" }) do
    local b = obj("W_Map_Slot_C", n)
    b.IsVisible = function() return not (H.campHidden and H.campHidden[n]) end
    main[n] = b
  end
  return main
end
-- the colour key: an image in a canvas of the mod inside the content overlay
local function legendsOf(main)
  local out = {}
  for _, c in ipairs(main.__content.__children) do
    if c.__class == "CanvasPanel" then
      for _, k in ipairs(c.__children) do if k.__class == "Image" then out[#out + 1] = k; k.__legendCanvas = c end end
    end
  end
  return out
end
-- the canvas pool lists are drawn in (above the camp names)
local function listCanvasOf(main)
  for _, c in ipairs(main.__worldOverlay.__children) do if c.__class == "CanvasPanel" then return c end end
end
local function restorePos(id) States[id].__pos = FIX.live[id] end

-- ========================== 12 reference NPCs ==================================
local T = loadMod(DIR12)
check(lastLogMatching("v" .. VERP .. " loaded: 12 named NPCs %(12 teachers/traders%) from config%.lua | labels: camp maps=auto, world map=hover | pins 23 / 16 units | world%-map pools off") ~= nil,
  "load line: 12 NPCs, camp labels auto, world labels hover, pins 23 / 16, pools off")

print("== scenario 1: world map: translucent pins, names on hover, colour key\n")
local main = newMain("Main1", nil, nil, FIX.expect.ocA.__player)
main.__active = false
main.Map_Area.__visible = false
notify(main)
tick(); tick()
check(ourPanel(main.Map_World) == nil and #legendsOf(main) == 0, "nothing created while map closed")
main.__active = true
tick()
local vis = verify12(T, main.Map_World, "world", "world")
check(vis == 12, "world: all 12 NPC pins visible (got " .. tostring(vis) .. ")")
local l = lastLogMatching("Map_World map Area")
check(l and l:find("registered") and l:find("12 live") and l:find("12 single pins, 0 pools") and l:find("0 labels %(hover%)") and l:find("canvas 1600x900, pin 16 units"),
  "world: summary log (registered box, 12 live, 12 single pins, 0 labels, canvas 1600x900, pin 16 units)")
local e1, e2; if l then e1, e2 = l:match("marker: ([%d%.%-]+) / ([%d%.%-]+) UI px") end
check(e1 and tonumber(e1) < 0.05 and tonumber(e2) < 0.05, "world: self-test < 0.05 UI px (" .. tostring(e1) .. "/" .. tostring(e2) .. ")")
local lg = legendsOf(main)
check(#lg == 1, "colour key: one image, in a canvas of the mod inside the map screen overlay")
local LEGW, LEGH = pngSize(SRC .. "Assets/legend.png")
LEGW, LEGH = LEGW / 2, LEGH / 2      -- the image is drawn at 2x
local function legendAt(img, x, bottom, w, h, what)
  local c = img.Slot.calls
  local a, al, p, sz = c.SetAnchors, c.SetAlignment, c.SetPosition, c.SetSize
  check(a and a.Minimum.X == 0 and a.Minimum.Y == 1 and a.Maximum.X == 0 and a.Maximum.Y == 1 and al and al.X == 0 and al.Y == 1,
    what .. ": anchored at the bottom-left corner")
  check(p and close(p.X, x, 0.01) and close(p.Y, -bottom, 0.01), (what .. ": %g from the left, %.1f above the bottom (got %s / %s)"):format(x, bottom, tostring(p and p.X), tostring(p and -p.Y)))
  check(sz and close(sz.X, w, 0.01) and close(sz.Y, h, 0.01), (what .. ": drawn at %.1f x %.1f units (got %s x %s)"):format(w, h, tostring(sz and sz.X), tostring(sz and sz.Y)))
end
if lg[1] then
  local cs = lg[1].__legendCanvas.Slot.calls
  check(cs.SetHorizontalAlignment == 0 and cs.SetVerticalAlignment == 0 and lg[1].__legendCanvas.vis == 3 and lg[1].vis == 3,
    "colour key: its canvas fills the screen content, click-through")
  -- button row 900 wide: its left end is at 1600 - 100 - 900 * 0.95 = 645, so 529 units are free
  local room = 1600 - 100 - 900 * 0.95 - 16 - 100
  check(LEGW > room and room >= LEGW * 0.72, ("fixture: key %.0f wide, room %.0f"):format(LEGW, room))
  local h = LEGH * room / LEGW
  legendAt(lg[1], 100, 50 + (44 - h) / 2, room, h, "colour key (room a little short)")
end
local imports = H.imports
tick(); tick(2.5); tick(2.5)
check(H.imports == imports and #legendsOf(main) == 1, "no texture reloads / duplicate keys between refreshes")
-- the game's button row gets shorter / longer (other map, other input device)
H.rowW = 700
tick(1.2)
legendAt(lg[1], 100, 50 + (44 - LEGH) / 2, LEGW, LEGH, "colour key (enough room): full size, centred on the button row")
H.rowW = 1300
tick(1.2)
legendAt(lg[1], 100, (50 + 44 * 0.05 - LEGH) / 2, LEGW, LEGH, "colour key (no room): full size in the strip below the button row")
check((50 + 44 * 0.05 - LEGH) / 2 + LEGH <= 50 + 44 * 0.05 + 1e-9, "(that strip is below the row's lower edge)")
H.rowW = nil
tick(1.2)
lg[1].__legendCanvas:RemoveFromParent(); tick(0.15)
check(#legendsOf(main) == 1 and legendsOf(main)[1] ~= lg[1], "colour key re-attached if removed")

print("== scenario 1b: no redundant widget updates when nobody moves\n")
local st = T.state(main.Map_World)
local before, visBefore = SlotCalls, 0
for _, en in pairs(st.entries) do visBefore = visBefore + (en.pin.visCalls or 0) end
tick(2.5)
local visAfter = 0
for _, en in pairs(st.entries) do visAfter = visAfter + (en.pin.visCalls or 0) end
check(SlotCalls == before and visAfter == visBefore, ("steady refresh: 0 slot / visibility calls (got %d / %d)"):format(SlotCalls - before, visAfter - visBefore))
States["OC_STT_Diego"].__pos = { FIX.live["OC_STT_Diego"][1] + 500, FIX.live["OC_STT_Diego"][2], FIX.live["OC_STT_Diego"][3] }
local diego = st.entries["OC_STT_Diego"]
local dc = diego.pinSlot.count.SetAnchors
before = SlotCalls
tick(2.5)
check(diego.pinSlot.count.SetAnchors == dc + 1 and SlotCalls - before == 1, ("moved NPC: only its pin re-anchored (%d calls)"):format(SlotCalls - before))
restorePos("OC_STT_Diego")
tick(2.5)

print("== scenario 2: Old Camp area map: normal pins, labels where they fit\n")
main.Map_Area.__visible = true
tick()
local _, nl = verify12(T, main.Map_Area, "ocA", "oldcamp(reg)", { isArea = true })
check(nl >= 1, "oldcamp: " .. nl .. " labels placed")
l = lastLogMatching("Map_Area map Area.OldCamp")
check(l and l:find("ActorMapBoundingBox") and l:find("registered") and l:find("%(auto%)") and l:find("canvas 1400x860, pin 23 units") and l:find("0 pools"),
  "oldcamp: registered cell box, auto labels, canvas 1400x860, pin 23 units, no pools on camp maps")

print("== scenario 3: hover groups\n")
-- put Scorpio next to Diego (about 3.5 world-map canvas units apart)
local dpos = FIX.live["OC_STT_Diego"]
States["OC_GRD_Scorpio_205"].__pos = { dpos[1] + 200, dpos[2], dpos[3] }
main.Map_Area.__visible = false
tick(2.5)
st = T.state(main.Map_World)
diego = st.entries["OC_STT_Diego"]
local scorpio = st.entries["OC_GRD_Scorpio_205"]
local isHoveredCalls = 0
local function countHover()
  local n = 0
  for _, en in pairs(st.entries) do n = n + (en.pin.__hoverCalls or 0) end
  return n
end
for _, en in pairs(st.entries) do
  local pin = en.pin
  local f = pin.IsHovered
  pin.IsHovered = function(self) self.__hoverCalls = (self.__hoverCalls or 0) + 1; return f(self) end
end
diego.pin.hover = true
tick(0.15)
local g = st.group
check(g and g.owner == diego and #g.members == 2, "world: hovering Diego groups the 2 overlapping pins (" .. (g and #g.members or 0) .. ")")
check(lastLogMatching("Hover detected on Diego %(canvas fast path%)") ~= nil, "hover detection logged once (fast path learned)")
check(close(diego.pin.color.A, 1) and close(scorpio.pin.color.A, 1), "group pins become opaque")
check(close(diego.pinSlot.calls.SetSize.X, CFG.WorldPinSize * CFG.HoverPinScale) and diego.pinSlot.calls.SetZOrder == 5, "hovered pin grows and moves on top")
check(diego.label and scorpio.label and diego.label.vis == 3 and scorpio.label.vis == 3, "both names shown")
check(anchorIs(diego.labelSlot, diego.u, diego.v) and anchorIs(scorpio.labelSlot, diego.u, diego.v), "name list anchored at the hovered pin")
local p1, p2 = diego.labelSlot.calls.SetPosition, scorpio.labelSlot.calls.SetPosition
check(p1 and p2 and p2.Y >= p1.Y + diego.labelSlot.calls.SetSize.Y and diego.labelSlot.calls.SetZOrder == 6,
  "names stacked under the hovered pin (hovered first), on top of everything")
local otherEn = st.entries["XT_DMB_Xardas_404"]
check(close(otherEn.pin.color.A, CFG.WorldPinOpacity), "pins outside the group stay translucent")
tick(2.5) -- a refresh while hovered keeps the group
check(st.group and close(diego.pin.color.A, 1) and diego.label.vis == 3 and close(diego.pinSlot.calls.SetSize.X, CFG.WorldPinSize * CFG.HoverPinScale),
  "refresh while hovering keeps the group")
diego.pin.hover = false
tick(0.15)
check(st.group == nil and close(diego.pin.color.A, CFG.WorldPinOpacity) and close(scorpio.pin.color.A, CFG.WorldPinOpacity)
  and close(diego.pinSlot.calls.SetSize.X, CFG.WorldPinSize) and diego.pinSlot.calls.SetZOrder == 2
  and diego.label.vis == 1 and scorpio.label.vis == 1, "mouse leaves: pins translucent and small again, names hidden")
local hc = countHover()
for _ = 1, 10 do tick(0.15) end
check(countHover() == hc, "nothing hovered: no per-pin hover polling (canvas fast path)")
scorpio.pin.hover = true; tick(0.15)
check(st.group and st.group.owner == scorpio and #st.group.members == 2, "hovering Scorpio switches the group")
scorpio.pin.hover = false; tick(0.15)
-- camp map: labels that were placed automatically come back after hover
main.Map_World.IsBackground = true
main.Map_Area.__visible = true
tick(2.5)
local sa = T.state(main.Map_Area)
local dA, sA = sa.entries["OC_STT_Diego"], sa.entries["OC_GRD_Scorpio_205"]
local hadAuto = sA and sA.autoPos and { sA.autoPos[1], sA.autoPos[2] }
dA.pin.hover = true; tick(0.15)
check(sa.group and #sa.group.members >= 2 and anchorIs(sA.labelSlot, dA.u, dA.v), "camp map: hover lists nearby names under the hovered pin")
dA.pin.hover = false; tick(0.15)
if hadAuto then
  local p = sA.labelSlot.calls.SetPosition
  check(anchorIs(sA.labelSlot, sA.u, sA.v) and close(p.X, hadAuto[1]) and close(p.Y, hadAuto[2]) and sA.label.vis == 3 and sA.labelSlot.calls.SetZOrder == 3,
    "camp map: automatic label returns to its own pin after hover")
else
  check(sA.label == nil or sA.label.vis == 1, "camp map: label hidden again after hover")
end
main.Map_World.IsBackground = false
restorePos("OC_GRD_Scorpio_205")

print("== scenario 4: TMap unreadable, calibration chooses between two Old Camp boxes\n")
freshSession()
local main2 = newMain("Main2", nil, nil, FIX.expect.ocW.__player, "unreadable")
notify(main2)
tick(1.0)
verify12(T, main2.Map_Area, "ocW", "oldcamp(calibrated)", { isArea = true })
l = lastLogMatching("Map_Area map Area.OldCamp")
check(l and l:find("W_MapBoundingBox") and l:find("2 candidate"), "oldcamp: calibration picked persistent W_ box out of 2")
check(lastLogMatching("not readable") ~= nil, "unreadable TMap logged once")
verify12(T, main2.Map_World, "world", "world(world-box)")

print("== scenario 5: dead / missing NPCs, retry interval, scan fallback\n")
H.npcMode["OC_STT_Diego"] = "dead"
tick(2.5)
verify12(T, main2.Map_World, "world", "world(dead)")
freshSession()
H.npcMode = { ["UL_OSL_UrShak_2200"] = "missing" }
local mainM = newMain("MainM", nil, nil, FIX.expect.ocA.__player)
mainM.Map_Area.__visible = false
notify(mainM)
tick(1.0)
verify12(T, mainM.Map_World, "world", "world(missing->approx)")
local c0 = H.staticCalls["UL_OSL_UrShak_2200"] or 0
local fa0 = H.findAll or 0
for _ = 1, 15 do tick(2.0) end
local c1 = H.staticCalls["UL_OSL_UrShak_2200"] - c0
check(c1 >= 2 and c1 <= 4, ("missing NPC looked up every ~10 s (%d lookups in 30 s)"):format(c1))
check((H.findAll or 0) - fa0 == 0, ("no full object scans while the map is open (%d)"):format((H.findAll or 0) - fa0))
H.npcMode = {}
for _ = 1, 6 do tick(2.0) end
verify12(T, mainM.Map_World, "world", "world(missing->found again)")
freshSession()
H.staticBroken = true
local main3 = newMain("Main3", nil, nil, FIX.expect.ocA.__player)
main3.Map_Area.__visible = false
notify(main3)
tick(1.0)
check(verify12(T, main3.Map_World, "world", "world(scan)") == 12, "scan fallback finds all NPC states")
check(lastLogMatching("FindNPCByUniqueName unavailable") ~= nil, "static-lookup failure logged")

print("== scenario 6: canvas detached externally, background map\n")
local ours = ourPanel(main3.Map_World)
ours:RemoveFromParent()
tick(2.5)
check(ourPanel(main3.Map_World) ~= nil and ourPanel(main3.Map_World) ~= ours, "canvas recreated after detach")
verify12(T, main3.Map_World, "world", "world(recreated)")
main3.Map_World.IsBackground = true
tick(0.2)
check(ourPanel(main3.Map_World).vis == 1, "pins collapsed on background world map")
main3.Map_World.IsBackground = false
tick(0.2)
check(ourPanel(main3.Map_World).vis == 4, "pins restored when world map is foreground")

print("== scenario 7: the map screen is announced by UE4SS; it is searched for only where that cannot be had\n")
local scans = 0
local realFind = _G.FindAllOf
_G.FindAllOf = function(cls) if cls == "W_Map_Main_C" then scans = scans + 1 end return realFind(cls) end
-- (a) the announcement is registered: no search among all objects, whatever happens
T = loadMod(DIR12)
freshSession()
local main4 = newMain("Main4", nil, nil, FIX.expect.ocA.__player)
main4.Map_Area.__visible = false
registry["W_Map_Main_C"] = { main4 }
for _ = 1, 400 do tick(0.15) end                    -- a minute without a map
freshSession()                                      -- a map load
for _ = 1, 400 do tick(0.15) end
check(scans == 0 and ourPanel(main4.Map_World) == nil, "with the announcement registered the map screen is never searched for: not after a start or a map load, not while no map is open (scans=" .. scans .. ")")
notify(main4)
tick(0.15); tick(0.15)
check(scans == 0 and ourPanel(main4.Map_World) ~= nil, "the screen the game announces gets its pins")
main4.__valid = false
for _ = 1, 400 do tick(0.15) end
check(scans == 0, "nor after that screen is gone (scans=" .. scans .. ")")
-- (b) no announcements in this UE4SS: the old schedule
for _, how in ipairs({ "none", "raises" }) do
  scans = 0
  T = loadMod(DIR12, how)
  freshSession()
  main4 = newMain("Main4" .. how, nil, nil, FIX.expect.ocA.__player)
  main4.Map_Area.__visible = false
  registry["W_Map_Main_C"] = { main4 }
  tick(0.15)
  check(ourPanel(main4.Map_World) == nil and scans == 0, "announcements " .. how .. ": no scan in the first 2 s")
  for _ = 1, 15 do tick(0.15) end
  check(scans == 1 and ourPanel(main4.Map_World) ~= nil, "found by one scan at ~2 s (scans=" .. scans .. ")")
  for _ = 1, 100 do tick(0.15) end
  check(scans == 1, "no further scans once a map widget is tracked (scans=" .. scans .. ")")
  main4.__valid = false
  registry["W_Map_Main_C"] = nil
  for _ = 1, 440 do tick(0.15) end                  -- 66 s more without a map (the start was 17.4 s ago)
  check(scans == 4, "while no map screen is known it is searched for now and then: 10 and 30 s after the start, then every 30 s (scans=" .. scans .. ")")
end
_G.FindAllOf = realFind
registry["W_Map_Main_C"] = nil

print("== scenario 8: canvas does not report child hover -> per-pin polling still works\n")
freshSession()
H.panelHover = "never"
T = loadMod(DIR12)
local mainP = newMain("MainP", nil, nil, FIX.expect.ocA.__player)
mainP.Map_Area.__visible = false
notify(mainP)
tick(1.0)
st = T.state(mainP.Map_World)
st.entries["OC_STT_Diego"].pin.hover = true; tick(0.15)
check(st.group and st.group.owner.def.id == "OC_STT_Diego" and st.entries["OC_STT_Diego"].label.vis == 3, "hover works without the canvas fast path")
check(lastLogMatching("per%-pin polling") ~= nil, "logged: per-pin polling")
st.entries["OC_STT_Diego"].pin.hover = false; tick(0.15)
check(st.group == nil, "group cleared")
H.panelHover = nil

print("== scenario 9: 'always' label mode (old behaviour, stacked)\n")
freshSession()
T = loadMod(DIRALWAYS)
local mainA = newMain("MainA", nil, nil, FIX.expect.ocA.__player)
notify(mainA)
tick(1.0); tick(0.15); tick(0.15)
local v9, l9 = verify12(T, mainA.Map_World, "world", "world(always)", { labels = "always" })
check(v9 == 12 and l9 == 12, "always: 12 labels on the world map")

-- ========================== full NPC list ======================================
print("== scenario 10: all named NPCs (npcs.lua), New Camp + world map\n")
freshSession()
local NPCLIST = dofile(SRC .. "npcs.lua")
local spots = {}
for line in io.lines(HERE .. "spots.txt") do
  local n, x, y, z = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
  if n then spots[#spots + 1] = { n = n, x = tonumber(x), y = tonumber(y), z = tonumber(z) } end
end
local NCBOX = boxBy("Area.NewCamp").__box
local NCCORR = Proj.LoadCorrection(SRC .. "data/corr_NewCamp.bin")
local WBOX = boxBy("Area").__box
local WCORR = Proj.LoadCorrection(SRC .. "data/corr_Overworld.bin")
local ncSpots, worldSpots, ocSpots = {}, {}, {}
for _, s in ipairs(spots) do
  if Proj.Project(NCBOX, NCCORR, s.x, s.y, s.z, { useMask = true, scale = 0.6 }) and (s.n:find("NC_") or s.n:find("_NC")) then
    ncSpots[#ncSpots + 1] = s
  elseif Proj.Project(WBOX, WCORR, s.x, s.y, s.z, { scale = 0.6 }) then
    worldSpots[#worldSpots + 1] = s
    if s.n:find("OC_") or s.n:find("_OC") then ocSpots[#ocSpots + 1] = s end
  end
end
check(#ncSpots > 60 and #ocSpots > 60, ("fixture: %d New Camp / %d Old Camp spots"):format(#ncSpots, #ocSpots))
-- New Camp / Bandit Camp NPCs on New Camp spots, Old Camp NPCs on Old Camp
-- spots (dense on the world map), everyone else spread over the world
local nNC, nOC, nW = 0, 0, 0
for _, d in ipairs(NPCLIST) do
  local s
  if d.id:match("^NC_") or d.id:match("^BC_") then
    nNC = nNC + 1; s = ncSpots[(nNC * 37) % #ncSpots + 1]
  elseif d.id:match("^OC") then
    nOC = nOC + 1; s = ocSpots[(nOC * 13) % #ocSpots + 1]
  else
    nW = nW + 1; s = worldSpots[(nW * 7919) % #worldSpots + 1]
  end
  if States[d.id] then States[d.id].__pos = { s.x, s.y, s.z } else addState(d.id, { s.x, s.y, s.z }) end
end
H.npcMode["NC_ORG_Lares_801"] = "dead"
H.npcMode["NC_SLD_Lee_700"] = "missing"

local function runFull(dir, areaMode)
  QUIET = true
  local TT = loadMod(dir)
  QUIET = false
  local mainF = newMain("MainF_" .. areaMode, "Area", "Area.NewCamp", nil)
  notify(mainF)
  local ticks, maxPerTick = 0, 0
  repeat
    local c = Created.images
    tick(0.15)
    ticks = ticks + 1
    maxPerTick = math.max(maxPerTick, Created.images - c)
    local a, w = TT.state(mainF.Map_Area), TT.state(mainF.Map_World)
  until (a and not a.pending and w and not w.pending) or ticks > 60
  check(maxPerTick <= 2 * CFG.MaxNewWidgetsPerTick + 1, ("[%s] widget creation budget respected (max %d per tick, %d ticks)"):format(areaMode, maxPerTick, ticks))
  check(ticks <= 25, ("[%s] all pins created within %d ticks (%.1f s)"):format(areaMode, ticks, ticks * 0.15))
  return TT, mainF
end

local function rectsOf(TT, mapWidget)
  local stx = TT.state(mapWidget)
  local cw, chh = mapWidget.__canvas[1], mapWidget.__canvas[2]
  local labels, pins = {}, {}
  for _, def in ipairs(TT.npcs) do
    local en = stx.entries[def.id]
    if en and en.pin.vis ~= 1 then
      local h = en.size * 0.5
      pins[#pins + 1] = { en.u * cw - h, en.v * chh - h, en.u * cw + h, en.v * chh + h, def.id }
      if en.label and en.label.vis == 3 then
        local a, p, sz = en.labelSlot.calls.SetAnchors.Minimum, en.labelSlot.calls.SetPosition, en.labelSlot.calls.SetSize
        local x0 = a.X * cw + p.X - sz.X * 0.5
        local y0 = a.Y * chh + p.Y
        labels[#labels + 1] = { x0, y0, x0 + sz.X, y0 + sz.Y, def.id }
      end
    end
  end
  return labels, pins
end
local function overlapCount(A, B, sameSet)
  local n = 0
  for i = 1, #A do
    for j = sameSet and i + 1 or 1, #B do
      local a, b = A[i], B[j]
      if a[5] ~= b[5] and a[1] < b[3] - 1e-6 and a[3] > b[1] + 1e-6 and a[2] < b[4] - 1e-6 and a[4] > b[2] + 1e-6 then n = n + 1 end
    end
  end
  return n
end

local function verifyFull(TT, mapWidget, box, corr, isArea, label)
  local stx = TT.state(mapWidget)
  local shown, bad = 0, 0
  for _, def in ipairs(TT.npcs) do
    local s = States[def.id]
    local mode = H.npcMode[def.id] or "live"
    local u, v
    if mode == "live" then u, v = Proj.Project(box, corr, s.__pos[1], s.__pos[2], s.__pos[3], { useMask = isArea, scale = 0.6 }) end
    local en = stx.entries[def.id]
    if u then
      shown = shown + 1
      local size = (isArea and CFG.AreaPinSize or CFG.WorldPinSize) * (def.important and 1 or CFG.OtherPinScale)
      local alpha = isArea and CFG.AreaPinOpacity or CFG.WorldPinOpacity
      if not (en and en.pin.vis == 0 and anchorIs(en.pinSlot, u, v) and close(en.pinSlot.calls.SetSize.X, size) and close(en.pin.color.A, alpha)) then bad = bad + 1 end
    elseif en and en.pin.vis ~= 1 then
      bad = bad + 1
    end
  end
  check(bad == 0, ("%s: %d pins exactly where projection.lua puts them (size, opacity), %d wrong"):format(label, shown, bad))
  return shown
end

-- densest pin = the one with the most neighbours inside the hover radius
local function densest(TT, mapWidget, isArea)
  local stx = TT.state(mapWidget)
  local cw, chh = mapWidget.__canvas[1], mapWidget.__canvas[2]
  local r = CFG.HoverGroupRadius * (isArea and CFG.AreaPinSize or CFG.WorldPinSize)
  local best, bestN = nil, -1
  for _, a in ipairs(stx.hoverList) do
    local n = 0
    for _, b in ipairs(stx.hoverList) do
      local dx, dy = (a.u - b.u) * cw, (a.v - b.v) * chh
      if dx * dx + dy * dy <= r * r then n = n + 1 end
    end
    if n > bestN then best, bestN = a, n end
  end
  return best, bestN
end

local LAYOUT = io.open(LAYOUT_OUT, "w")
local function dump(tag, TT, mapWidget)
  local stx = TT.state(mapWidget)
  for _, def in ipairs(TT.npcs) do
    local x = stx.entries[def.id]
    if x and x.pin.vis ~= 1 then
      local lab = ""
      if x.label and x.label.vis == 3 then
        local a, p, sz = x.labelSlot.calls.SetAnchors.Minimum, x.labelSlot.calls.SetPosition, x.labelSlot.calls.SetSize
        lab = ("%s\t%.6f\t%.6f\t%.3f\t%.3f\t%.3f\t%.3f\t%d"):format(def.label, a.X, a.Y, p.X, p.Y, sz.X, sz.Y, x.labelZ or 3)
      end
      LAYOUT:write(("%s\t%s\t%s\t%s\t%.6f\t%.6f\t%.3f\t%.3f\t%d\t%s\n"):format(tag, def.id, def.kind, tostring(def.orc), x.u, x.v, x.size, x.alpha or 1, x.z or 1, lab))
    end
  end
end

-- hover the densest cluster of single pins on a map
local function hoverDensest(TT, mw, isArea, tagName)
  tick(2.5)
  local own, n = densest(TT, mw, isArea)
  own.pin.hover = true
  tick(0.15)
  local stx = TT.state(mw)
  local g = stx.group
  check(g and g.owner == own and #g.members == math.min(n, CFG.HoverListMax),
    ("%s: hovering the densest cluster (%s) lists %d names"):format(tagName, own.def.name, g and #g.members or 0))
  local lab = rectsOf(TT, mw)
  local list = {}
  for _, r in ipairs(lab) do
    local en = stx.entries[r[5]]
    if en.group then list[#list + 1] = r end
  end
  check(#list == #g.members and overlapCount(list, list, true) == 0, ("%s: %d stacked names, no overlaps"):format(tagName, #list))
  check(overlapCount(lab, lab, true) == 0, ("%s: names under the list are hidden while it is open (%d visible names, 0 overlaps)"):format(tagName, #lab))
  dump(tagName .. "_hover", TT, mw)
  own.pin.hover = false
  tick(0.15)
  check(stx.group == nil, tagName .. ": hover cleared")
end

-- world map without pools: every NPC has its own pin (the 2.2 behaviour)
local TN, mainN = runFull(DIRFULLNOPOOL, "nopool")
verifyFull(TN, mainN.Map_World, WBOX, WCORR, false, "world map (pools off)")
mainN.Map_Area.__visible = false
hoverDensest(TN, mainN.Map_World, false, "World (pools off)")
freshSession()
H.npcMode["NC_ORG_Lares_801"] = "dead"
H.npcMode["NC_SLD_Lee_700"] = "missing"

local TF, mainF = runFull(DIRFULL, "auto")
local ld = lastLogMatching("loaded:")
check(ld and ld:find("181 named NPCs %(52 teachers/traders%) from npcs%.lua") and ld:find("world%-map pools on %(from 4 people, 26 units apart%)"),
  "load line: 181 NPCs, 52 teachers/traders, pools on")
local shownA = verifyFull(TF, mainF.Map_Area, NCBOX, NCCORR, true, "New Camp map")
check(shownA >= 40, "New Camp map shows " .. shownA .. " named NPCs")
local labA, pinA = rectsOf(TF, mainF.Map_Area)
check(overlapCount(labA, labA, true) == 0 and overlapCount(labA, pinA, false) == 0,
  ("New Camp (auto): %d of %d names placed, 0 overlapping other names or pins"):format(#labA, shownA))
local labW = rectsOf(TF, mainF.Map_World)
check(#labW == 0, "world map: no permanent names (hover only)")
local stA = TF.state(mainF.Map_Area)
check(stA.entries["NC_ORG_Lares_801"] == nil or stA.entries["NC_ORG_Lares_801"].pin.vis == 1, "dead NPC hidden")
check(stA.entries["NC_SLD_Lee_700"] == nil or stA.entries["NC_SLD_Lee_700"].pin.vis == 1, "missing NPC without fallback hidden")
dump("NewCamp_idle", TF, mainF.Map_Area)
dump("World_idle", TF, mainF.Map_World)

mainF.Map_Area.__visible = true
hoverDensest(TF, mainF.Map_Area, true, "NewCamp")
local labA2, pinA2 = rectsOf(TF, mainF.Map_Area)
check(#labA2 == #labA and overlapCount(labA2, labA2, true) == 0 and overlapCount(labA2, pinA2, false) == 0,
  "New Camp: automatic names restored after hover, still no overlaps")

local nPools, nPeople, nSingles
local verifyPools
do
-- ========================== pools on the world map =============================
print("== scenario 10b: world map pools\n")
mainF.Map_Area.__visible = false
tick(2.5); tick(0.15); tick(0.15)
local CAMPS = {
  Button_OldCamp = { 39.0, -24.6875, 142.0, 50.625 },
  Button_NewCamp = { -347.36365, -144.09091, 155.27272, 51.818184 },
  Button_SwampCamp = { 485.63635, 123.90909, 155.27272, 51.818184 },
  Button_OrcCamp = { -110.36364, 243.90909, 155.27272, 51.818184 },
  Button_SleepersTemple = { -614.36365, 327.9091, 155.27272, 51.818184 },
}
local function campRects()
  local out = {}
  for n, c in pairs(CAMPS) do
    if not (H.campHidden and H.campHidden[n]) then
      out[#out + 1] = { 800 + c[1] - c[3] / 2, 450 + c[2] - c[4] / 2, 800 + c[1] + c[3] / 2, 450 + c[2] + c[4] / 2, n }
    end
  end
  return out
end
-- independent model: where everyone is, and which people hang together
local function expectedPlaces(TT, mapWidget)
  local cw, chh = mapWidget.__canvas[1], mapWidget.__canvas[2]
  local pts = {}
  for _, def in ipairs(TT.npcs) do
    local st = States[def.id]
    local mode = H.npcMode[def.id] or "live"
    local pos = st and st.__pos
    if mode == "missing" then pos = def.fallback end
    local u, v
    if mode ~= "dead" and pos then u, v = Proj.Project(WBOX, WCORR, pos[1], pos[2], pos[3], { scale = 0.6 }) end
    if u then pts[#pts + 1] = { def = def, u = u, v = v, x = u * cw, y = v * chh } end
  end
  local L2 = CFG.PoolLinkDistance ^ 2
  local seen, places = {}, {}
  for i = 1, #pts do
    if not seen[i] then
      local stack, members = { i }, {}
      seen[i] = true
      while #stack > 0 do
        local a = table.remove(stack)
        members[#members + 1] = a
        for j = 1, #pts do
          if not seen[j] and (pts[a].x - pts[j].x) ^ 2 + (pts[a].y - pts[j].y) ^ 2 <= L2 then
            seen[j] = true
            stack[#stack + 1] = j
          end
        end
      end
      table.sort(members)
      local list = {}
      for _, m in ipairs(members) do list[#list + 1] = pts[m] end
      places[#places + 1] = list
    end
  end
  return places, cw, chh
end
local function texName(img) return img.tex and img.tex.__path and img.tex.__path:match("([^/]+)$") end
verifyPools = function(TT, mapWidget, label)
  local stx = TT.state(mapWidget)
  local places, cw, chh = expectedPlaces(TT, mapWidget)
  local rects = campRects()
  local nPools, nPeople, nSingles, bad, underLabel, biggest = 0, 0, 0, 0, 0, nil
  local r = CFG.PoolPinSize / 2
  for _, place in ipairs(places) do
    if #place >= CFG.PoolMinSize then
      nPools, nPeople = nPools + 1, nPeople + #place
      local sx, sy, teach, trade = 0, 0, false, false
      for _, m in ipairs(place) do
        sx, sy = sx + m.x, sy + m.y
        if m.def.kind == "teacher" or m.def.kind == "both" then teach = true end
        if m.def.kind == "trader" or m.def.kind == "both" then trade = true end
      end
      local cx, cy = sx / #place, sy / #place
      local p = stx.pools[place[1].def.id]
      local ok = p and p.pin.vis == 0 and p.pin.__parent == ourPanel(mapWidget)
        and texName(p.pin) == (#place > 99 and "pool_more.png" or ("pool_%d.png"):format(#place))
        and close(p.pinSlot.calls.SetSize.X, CFG.PoolPinSize) and close(p.pin.color.A, CFG.PoolOpacity)
      if ok then
        local a = p.pinSlot.calls.SetAnchors.Minimum
        local mx, my = a.X * cw, a.Y * chh
        -- never touching a camp name; otherwise at the middle of its people
        local touches, wasUnder = false, false
        for _, R in ipairs(rects) do
          if mx + r > R[1] and mx - r < R[3] and my + r > R[2] and my - r < R[4] then touches = true end
          if cx + r > R[1] and cx - r < R[3] and cy + r > R[2] and cy - r < R[4] then wasUnder = true end
        end
        if touches then ok = false end
        if wasUnder then
          underLabel = underLabel + 1
          if math.abs(mx - cx) > 0.51 or math.abs(my - cy) > 60 then ok = false end
        elseif math.abs(mx - cx) > 0.51 or math.abs(my - cy) > 0.51 then
          ok = false
        end
        if mx < r - 1e-6 or mx > cw - r + 1e-6 or my < r - 1e-6 or my > chh - r + 1e-6 then ok = false end
        -- dots for teachers / traders
        local dT, dM = p.dots.teach, p.dots.trade
        if teach ~= (dT ~= nil and dT.pin.vis == 3) or trade ~= (dM ~= nil and dM.pin.vis == 3) then ok = false end
        if dT and dT.pin.vis == 3 and texName(dT.pin) ~= "pin_teacher.png" then ok = false end
        if dM and dM.pin.vis == 3 and texName(dM.pin) ~= "pin_merchant.png" then ok = false end
      end
      for _, m in ipairs(place) do
        local en = stx.entries[m.def.id]
        if en and en.pin.vis ~= 1 then ok = false end       -- pooled people have no pin of their own
        if en and en.label and en.label.vis ~= 1 then ok = false end
      end
      if not ok then bad = bad + 1; io.write("    BAD pool of ", #place, " at ", place[1].def.id, "\n") end
      if not biggest or #place > #biggest.place then biggest = { place = place, p = p } end
    else
      for _, m in ipairs(place) do
        nSingles = nSingles + 1
        local en = stx.entries[m.def.id]
        local size = CFG.WorldPinSize * (m.def.important and 1 or CFG.OtherPinScale)
        if not (en and en.pin.vis == 0 and anchorIs(en.pinSlot, m.u, m.v) and close(en.pinSlot.calls.SetSize.X, size)) then
          bad = bad + 1; io.write("    BAD single ", m.def.id, "\n")
        end
      end
    end
  end
  local visiblePools = 0
  for _, p in pairs(stx.pools) do if p.pin.vis ~= 1 then visiblePools = visiblePools + 1 end end
  check(bad == 0 and visiblePools == nPools,
    ("%s: %d pools with %d people and %d single pins, all as the independent model says (%d wrong, %d badges visible)")
      :format(label, nPools, nPeople, nSingles, bad, visiblePools))
  return nPools, nPeople, nSingles, underLabel, biggest
end
local underLabel, biggest
nPools, nPeople, nSingles, underLabel, biggest = verifyPools(TF, mainF.Map_World, "world map")
check(nPools >= 2 and nPeople >= 100 and nSingles >= 5, ("fixture: %d pools, %d people in pools, %d on their own"):format(nPools, nPeople, nSingles))
check(underLabel >= 1, ("%d pool(s) would sit under a camp name and were moved off it"):format(underLabel))
local lw = lastLogMatching("Map_World map Area")
check(lw and lw:find(("%d single pins, %d pools with %d people"):format(nSingles, nPools, nPeople)) and lw:find("canvas 1600x900, pin 16 units"),
  "world: summary log counts pools and single pins: " .. tostring(lw and lw:match("| %d+ single pins[^|]+")))
check(#rectsOf(TF, mainF.Map_World) == 0, "world map: no permanent names")
-- camp names not shown yet (not discovered): badges sit in the middle of their people
H.campHidden = { Button_OldCamp = true, Button_NewCamp = true, Button_SwampCamp = true, Button_OrcCamp = true, Button_SleepersTemple = true }
tick(2.5)
local _, _, _, under2 = verifyPools(TF, mainF.Map_World, "world map (camp names hidden)")
check(under2 == 0, "no camp names shown: nothing to avoid")
H.campHidden = nil
tick(2.5)
verifyPools(TF, mainF.Map_World, "world map (camp names shown again)")

print("== scenario 10c: hovering a pool lists everyone there\n")
local stW = TF.state(mainF.Map_World)
local bp = biggest.p
local function listRows(st, main)
  local canvas = listCanvasOf(main)
  local rows = {}
  if not canvas then return rows, nil end
  for _, img in ipairs(canvas.__children) do
    if img.vis == 3 and img.Slot.calls.SetZOrder == 3 then
      local p, sz = img.Slot.calls.SetPosition, img.Slot.calls.SetSize
      rows[#rows + 1] = { p.X, p.Y, p.X + sz.X, p.Y + sz.Y, texName(img), img = img }
    end
  end
  return rows, canvas
end
local function backdrop(canvas)
  local e, f
  for _, img in ipairs(canvas.__children) do
    if img.vis == 3 and img.Slot.calls.SetZOrder == 1 then e = img end
    if img.vis == 3 and img.Slot.calls.SetZOrder == 2 then f = img end
  end
  return e, f
end
local imagesBefore = Created.images
bp.pin.hover = true
local maxNew, steps = 0, 0
repeat
  local c = Created.images
  tick(0.15)
  steps = steps + 1
  maxNew = math.max(maxNew, Created.images - c)
until (stW.group and stW.group.pool and stW.group.next > #stW.group.rows) or steps > 40
local g = stW.group
check(g and g.pool and g.owner == bp, "hovering the biggest pool (" .. #biggest.place .. " people) opens its list")
check(maxNew <= 3 * CFG.MaxNewWidgetsPerTick and steps <= 5, ("list filled within %d update steps, at most %d new images per step"):format(steps, maxNew))
local rows, canvas = listRows(stW, mainF)
check(canvas ~= nil and canvas.__parent == mainF.__worldOverlay and canvas.vis == 3, "list canvas sits in the world-map overlay (above the camp names), click-through")
do
  local kids = mainF.__worldOverlay.__children
  check(kids[#kids] == canvas and kids[1] == mainF.Map_World, "(added after the map, so it is drawn on top)")
end
local n = #biggest.place
check(#rows == 2 * n, ("%d rows: one kind dot and one name each (%d images)"):format(n, #rows))
-- expected order: teacher+trader, teachers, traders, then the rest; by name
local RANK = { both = 1, teacher = 2, trader = 3 }
local want = {}
for _, m in ipairs(biggest.place) do want[#want + 1] = m.def end
table.sort(want, function(a, b)
  local ra, rb = RANK[a.kind] or 9, RANK[b.kind] or 9
  if ra ~= rb then return ra < rb end
  if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
  return a.id < b.id
end)
local PIN_OF = { teacher = "pin_teacher.png", trader = "pin_merchant.png", both = "pin_both.png" }
local okOrder, okGeo = true, true
local names, perCol = {}, {}
for i, def in ipairs(want) do
  local w = stW.list.rows[i]
  local wantIcon = PIN_OF[def.kind] or (def.orc and "pin_orc.png") or "pin_other.png"
  if not (w and texName(w.icon.img) == wantIcon and texName(w.label.img) == def.label:match("([^/]+)$")) then okOrder = false end
  if w then
    local lp, ls = w.label.img.Slot.calls.SetPosition, w.label.img.Slot.calls.SetSize
    local ip, is = w.icon.img.Slot.calls.SetPosition, w.icon.img.Slot.calls.SetSize
    local shown = w.label.img.tex and w.label.img.tex.__path      -- the picture the row shows (the drawn one in the default look)
    local tw, th = pngSize(shown or (SRC .. def.label))
    if not (close(ls.X, tw * CFG.LabelScale) and close(ls.Y, th * CFG.LabelScale) and close(is.X, 12) and ip.X < lp.X and ip.X + is.X <= lp.X) then okGeo = false end
    names[#names + 1] = { lp.X, lp.Y, lp.X + ls.X, lp.Y + ls.Y, def.id }
    perCol[lp.X] = (perCol[lp.X] or 0) + 1
  end
end
check(okOrder, "rows in order: teachers and traders first, then by name; each with its own kind dot and name image")
check(okGeo, "names at image size x LabelScale, dot left of its name")
local maxRows, nCols = 0, 0
for _, c in pairs(perCol) do maxRows = math.max(maxRows, c); nCols = nCols + 1 end
check(maxRows <= CFG.PoolListRows and nCols == math.ceil(n / CFG.PoolListRows), ("%d columns of at most %d names"):format(nCols, maxRows))
check(overlapCount(names, names, true) == 0, "no two names overlap")
local edge, fill = backdrop(canvas)
check(edge and fill and texName(edge) == "list_edge.png" and texName(fill) == "list_fill.png", "plain backdrop behind the names")
if edge then
  local ep, es = edge.Slot.calls.SetPosition, edge.Slot.calls.SetSize
  local inside = true
  for _, r in ipairs(rows) do
    if r[1] < ep.X or r[2] < ep.Y or r[3] > ep.X + es.X + 1e-6 or r[4] > ep.Y + es.Y + 1e-6 then inside = false end
  end
  check(inside, "every row lies on the backdrop")
  check(ep.X >= 6 - 1e-6 and ep.Y >= 6 - 1e-6 and ep.X + es.X <= 1600 - 6 + 1e-6 and ep.Y + es.Y <= 900 - 6 + 1e-6, "the list stays inside the map")
  local a = bp.pinSlot.calls.SetAnchors.Minimum
  local bx, by, br = a.X * 1600, a.Y * 900, CFG.PoolPinSize * CFG.HoverPinScale / 2
  check(not (bx + br > ep.X and bx - br < ep.X + es.X and by + br > ep.Y and by - br < ep.Y + es.Y), "the list does not cover its badge")
end
check(close(bp.pinSlot.calls.SetSize.X, CFG.PoolPinSize * CFG.HoverPinScale) and close(bp.pin.color.A, 1) and bp.pinSlot.calls.SetZOrder == 5,
  "hovered badge grows, turns solid, moves on top")
-- while the list is open nothing moves
local someone = biggest.place[2].def.id
local keepPos = States[someone].__pos
States[someone].__pos = { keepPos[1] + 40000, keepPos[2] + 40000, keepPos[3] }
local slotCalls = SlotCalls
tick(2.5); tick(0.15)
check(stW.group == g and SlotCalls == slotCalls, "refresh while the list is open changes nothing (0 slot calls)")
bp.pin.hover = false
tick(0.15)
rows = listRows(stW, mainF)
edge, fill = backdrop(canvas)
check(stW.group == nil and #rows == 0 and not edge and not fill, "mouse leaves: list and backdrop hidden")
check(close(bp.pinSlot.calls.SetSize.X, CFG.PoolPinSize) and close(bp.pin.color.A, CFG.PoolOpacity) and bp.pinSlot.calls.SetZOrder == 3,
  "badge back to its normal size, opacity and layer")
tick(0.15)
verifyPools(TF, mainF.Map_World, "world map (after the list closed, one person walked off)")
States[someone].__pos = keepPos
tick(2.5)
-- a second pool reuses the row images
local other
for _, p in pairs(stW.pools) do if p ~= bp and p.pin.vis == 0 and (not other or p.n > other.n) then other = p end end
if other then
  local made = Created.images
  other.pin.hover = true
  for _ = 1, 12 do tick(0.15) end
  local rows2 = listRows(stW, mainF)
  check(stW.group and stW.group.owner == other and #rows2 == 2 * other.n and Created.images == made,
    ("another pool (%d people): its list reuses the existing row images (%d created)"):format(other.n, Created.images - made))
  other.pin.hover = false
  tick(0.15)
  check(#listRows(stW, mainF) == 0, "and is hidden again")
end
-- the marker canvas disappears while a list is open (map widget rebuilt by the game)
bp.pin.hover = true
for _ = 1, 6 do tick(0.15) end
check(stW.group and stW.group.pool and #listRows(stW, mainF) > 0, "list open again")
local oldPanel = ourPanel(mainF.Map_World)
oldPanel:RemoveFromParent()
bp.pin.hover = false
tick(2.5)
check(ourPanel(mainF.Map_World) ~= nil and ourPanel(mainF.Map_World) ~= oldPanel and #listRows(stW, mainF) == 0 and stW.group == nil,
  "marker canvas rebuilt: the open list is closed, nothing is left on screen")
do
  local n = 0
  for _, p in pairs(TF.state(mainF.Map_World).pools) do if p.pin.vis == 0 then n = n + 1 end end
  check(n == nPools, ("badges are created first, in the same update step (%d of %d)"):format(n, nPools))
end
for _ = 1, 8 do tick(0.15) end
stW = TF.state(mainF.Map_World)
local _, _, _, _, biggest2 = verifyPools(TF, mainF.Map_World, "world map (after the rebuild)")
bp = biggest2.p
dump("World_pools", TF, mainF.Map_World)
do
  -- for the picture: badges and the biggest list
  local f = io.open(TMPROOT .. "/h23_pools.tsv", "w")
  for _, p in pairs(stW.pools) do
    if p.pin.vis ~= 1 then
      local a = p.pinSlot.calls.SetAnchors.Minimum
      f:write(("pool\t%.3f\t%.3f\t%d\t%s\t%s\n"):format(a.X * 1600, a.Y * 900, p.n, tostring(p.teach), tostring(p.trade)))
    end
  end
  for _, def in ipairs(TF.npcs) do
    local en = stW.entries[def.id]
    if en and en.pin.vis ~= 1 then f:write(("pin\t%.3f\t%.3f\t%.2f\t%s\n"):format(en.u * 1600, en.v * 900, en.size, texName(en.pin))) end
  end
  bp.pin.hover = true
  for _ = 1, 12 do tick(0.15) end
  local e2 = backdrop(canvas)
  local ep, es = e2.Slot.calls.SetPosition, e2.Slot.calls.SetSize
  f:write(("list\t%.3f\t%.3f\t%.3f\t%.3f\n"):format(ep.X, ep.Y, es.X, es.Y))
  for _, r in ipairs(listRows(stW, mainF)) do f:write(("row\t%.3f\t%.3f\t%.3f\t%.3f\t%s\n"):format(r[1], r[2], r[3] - r[1], r[4] - r[2], r[5])) end
  local a = bp.pinSlot.calls.SetAnchors.Minimum
  f:write(("hover\t%.3f\t%.3f\t%d\n"):format(a.X * 1600, a.Y * 900, bp.n))
  f:close()
  bp.pin.hover = false
  tick(0.15)
end
mainF.Map_Area.__visible = true
tick(2.5)
end
LAYOUT:close()

local t0 = REAL_CLOCK()
for _ = 1, 20 do tick(2.0) end
local per = (REAL_CLOCK() - t0) / 20 * 1000
print(("== steady refresh of both maps with %d NPCs: %.2f ms Lua time per refresh\n"):format(#TF.npcs, per))
check(per < 20, "refresh cost acceptable")

print("== scenario 11: full list, camp labels 'always'\n")
freshSession()
local TA, mainFA = runFull(DIRFULLALWAYS, "always")
local shownAA = verifyFull(TA, mainFA.Map_Area, NCBOX, NCCORR, true, "New Camp map (always)")
local labAA = rectsOf(TA, mainFA.Map_Area)
check(#labAA == shownAA and overlapCount(labAA, labAA, true) == 0, ("always: %d of %d names on New Camp, %d name overlaps"):format(#labAA, shownAA, overlapCount(labAA, labAA, true)))

print("== scenario 12: colour key variants\n")
freshSession()
H.noButtonRow = true
T = loadMod(DIR12)
do
  local mainK = newMain("MainK", nil, nil, FIX.expect.ocA.__player)
  mainK.Map_Area.__visible = false
  notify(mainK)
  tick(1.0); tick(1.2)
  local k = legendsOf(mainK)
  check(#k == 1, "button row not found: the key is still shown")
  local room = 1600 - 100 - 900 * 0.95 - 16 - 100
  if k[1] then legendAt(k[1], 100, 50 + (44 - LEGH * room / LEGW) / 2, room, LEGH * room / LEGW, "colour key (row size unknown: a usual row is assumed)") end
end
H.noButtonRow = nil
freshSession()
T = loadMod(DIR12NOAVOID)
do
  local mainK2 = newMain("MainK2", nil, nil, FIX.expect.ocA.__player)
  mainK2.Map_Area.__visible = false
  notify(mainK2)
  H.rowW = 1300
  tick(1.0); tick(1.2)
  local k = legendsOf(mainK2)
  if k[1] then legendAt(k[1], 100, 50, LEGW, LEGH, "colour key (LegendAvoidButtons = false): fixed place and size") end
  check(#k == 1, "one key")
end
H.rowW = nil

print("== scenario 13: pool size limits\n")
freshSession()
do
  local d = modCopy("mpool2", "C.PoolMinSize = 2; C.PoolLinkDistance = 40")
  QUIET = true
  local TP = loadMod(d)
  QUIET = false
  local mainP2 = newMain("MainP2", "Area", "Area.NewCamp", nil)
  mainP2.Map_Area.__visible = false
  notify(mainP2)
  for _ = 1, 20 do tick(0.15) end
  local saveMin, saveLink = CFG.PoolMinSize, CFG.PoolLinkDistance
  CFG.PoolMinSize, CFG.PoolLinkDistance = 2, 40
  local np2, pp2, ns2 = verifyPools(TP, mainP2.Map_World, "world map (pools from 2 people, 40 units)")
  CFG.PoolMinSize, CFG.PoolLinkDistance = saveMin, saveLink
  check(np2 > nPools and ns2 < nSingles, ("smaller minimum, wider link: more pools (%d), fewer single pins (%d)"):format(np2, ns2))
end

-- ========================== the game destroys the map screen ====================
-- In UE4SS an object wrapper is a pointer: a member call on a wrapper whose object was deleted
-- reads freed memory, and a new object can get the address of a deleted one. The fakes below
-- count every call that reaches a deleted widget or slot. (Scenario from the independent review.)
print("== scenario 14: map screen destroyed while a pool list is open; new screen at the same address\n")
;(function()
  freshSession()
  local TD, mainD = runFull(DIRFULL, "auto")
  mainD.Map_Area.__visible = false
  tick(2.5); tick(0.15); tick(0.15)
  local _, _, _, _, big = verifyPools(TD, mainD.Map_World, "world map (before the screen is destroyed)")
  local stD = TD.state(mainD.Map_World)
  big.p.pin.hover = true
  for _ = 1, 12 do tick(0.15) end
  local shown = 0
  for _, img in ipairs(listCanvasOf(mainD).__children) do if img.vis == 3 then shown = shown + 1 end end
  check(stD.group and stD.group.pool and shown > 10, ("a pool list is open (%d images shown)"):format(shown))
  local dead, deadCalls, total = {}, {}, 0
  local function kill(o, what)
    if type(o) ~= "table" or dead[o] then return end
    dead[o] = true
    o.__valid = false
    for _, fn in ipairs({ "SetVisibility", "SetColorAndOpacity", "SetBrushFromTexture", "IsHovered", "RemoveFromParent",
                          "AddChildToCanvas", "AddChildToOverlay", "GetParent", "IsVisible", "GetDesiredSize" }) do
      o[fn] = function() deadCalls[what .. ":" .. fn] = (deadCalls[what .. ":" .. fn] or 0) + 1; total = total + 1 end
    end
    if o.Slot then
      o.Slot.__valid = false
      for fn in pairs(o.Slot.calls) do
        o.Slot[fn] = function() deadCalls[what .. " slot:" .. fn] = (deadCalls[what .. " slot:" .. fn] or 0) + 1; total = total + 1 end
      end
    end
    for _, c in ipairs(o.__children or {}) do kill(c, what) end
  end
  local oldWorld = mainD.Map_World
  -- the whole screen goes away (closed with the mouse on the badge)
  kill(ourPanel(oldWorld), "marker canvas")
  kill(listCanvasOf(mainD), "list canvas")
  for _, c in ipairs(mainD.__content.__children) do kill(c, "content") end
  kill(oldWorld.__general, "map canvas")
  oldWorld.__valid, mainD.Map_Area.__valid, mainD.__valid = false, false, false
  tick(0.15); tick(0.15)
  -- a new screen; its world-map widget is allocated where the old one was
  local main2 = newMain("MainAfterDestroy")
  main2.Map_World.__addr = oldWorld.__addr
  main2.Map_Area.__visible = false
  notify(main2)
  local okRun, err = pcall(function() for _ = 1, 40 do tick(0.15) end end)
  check(okRun, "the mod keeps running on the new screen (" .. tostring(err) .. ")")
  local worst = {}
  for k, n in pairs(deadCalls) do worst[#worst + 1] = k .. " x" .. n end
  table.sort(worst)
  check(total == 0, ("no call reaches a deleted widget or slot (%d: %s)"):format(total, table.concat(worst, ", ")))
  local stNew = TD.state(main2.Map_World)
  local pools, pins = 0, 0
  if stNew then
    for _ in pairs(stNew.pools) do pools = pools + 1 end
    for _ in pairs(stNew.entries) do pins = pins + 1 end
  end
  check(stNew ~= nil and stNew ~= stD and stNew.group == nil and pools > 0 and pins > 0 and ourPanel(main2.Map_World) ~= nil,
    ("the new screen gets a state of its own with pins and pools (%d pins, %d pools)"):format(pins, pools))
  check(#legendsOf(main2) == 1, "and its own colour key")
end)()

-- ========================== diagnostics hooks (megamod loader) ==================
-- Everything above ran the mod on its own (no G1R_DIAG), as it is installed today. From here on the real script is
-- loaded with a recording stand-in for the handle the megamod loader passes in (diag_fake.lua), to see that the
-- hooks report the right things, report each thing once, and change nothing the mod does.
print("== scenario 15: diagnostics hooks (notes, status, dump), and nothing else changes\n")
;(function()
  local FK = dofile(HERE .. "diag_fake.lua")
  local MAIN_PATH = "/Game/UI/ManagementUI/Map/W_Map_Main.W_Map_Main_C"
  -- every note key the module may use
  local KEYS = {}
  for _, k in ipairs({ "markers.map_found_by", "markers.state_lookup", "markers.canvas_size.world", "markers.canvas_size.area",
      "markers.self_test.world", "markers.self_test.area", "markers.hover_path", "markers.pool_list_canvas", "markers.legend",
      "markers.button_row", "markers.camp_names", "markers.textures", "markers.textures_kept", "markers.image_binding", "markers.map_screens" }) do
    KEYS[k] = true
  end
  -- the handle is taken once, while the script loads
  local function loadWith(dir, fake, noNotify)
    rawset(_G, "G1R_DIAG", fake and fake.handle or nil)
    QUIET = true
    local ok, TT = pcall(loadMod, dir, noNotify)
    QUIET = false
    rawset(_G, "G1R_DIAG", nil)
    if not ok then error(TT, 0) end
    return TT
  end
  local function onlyKnownKeys(F)
    for _, n in ipairs(F.notes) do
      if not KEYS[n.key] then return false, tostring(n.key) end
    end
    return true, "-"
  end
  local function neverRepeated(F)
    for k in pairs(F.count) do
      if not F.neverRepeated(k) then return false, k end
    end
    return true, "-"
  end
  local function crumbsOnce(F)
    for _, c in ipairs(F.crumbs) do
      if F.crumbCount(c) ~= 1 then return false, c end
    end
    return true, "-"
  end

  -- ---- 12 reference NPCs, both maps of one screen
  freshSession()
  local F = FK.new()
  local imports0 = H.imports
  local TD = loadWith(DIR12, F)
  check(#F.versions == 1 and F.versions[1] == VER and #F.status == 1 and #F.dump == 1
    and type(F.status[1]) == "function" and type(F.dump[1]) == "function", "version, status provider and dump provider are registered once, at load")
  check(#F.notes == 1 and F.value("markers.map_screens") == "announced", "one thing is noted before the game shows anything: how map screens are found")
  do
    local lines = F.status[1]()
    check(type(lines) == "table" and #lines == 4 and lines[1] == "v" .. VER .. " | 12 named NPCs (12 teachers/traders) from config.lua"
      and lines[2] == "last map refresh: none yet" and lines[3] == "no map refreshed yet since the last load" and lines[4] == NO_PICTURES,
      "status before any map was open")
    local d = F.dump[1]()
    check(type(d) == "table" and d.version == VER and d.npcs == 12 and #d.maps == 0 and #d.pins == 0 and #d.pools == 0 and #d.legend == 0 and #d.facts == 1,
      "dump before any map was open: version and NPC count, empty lists, the one fact noted so far")
  end
  local mainD = newMain("MainDiag1", nil, nil, FIX.expect.ocA.__player)
  notify(mainD)
  tick(1.0); tick(0.15); tick(0.15)
  check(F.value("markers.map_found_by") == "notification" and F.count["markers.map_found_by"] == 1, "map_found_by = notification")
  check(F.value("markers.map_screens") == "announced" and F.count["markers.map_screens"] == 1 and F.detail("markers.map_screens") == nil, "map_screens = announced (noted when the mod is loaded)")
  check(F.value("markers.state_lookup") == "FindNPCByUniqueName" and F.count["markers.state_lookup"] == 1, "state_lookup = FindNPCByUniqueName (noted once, not per NPC)")
  check(F.value("markers.canvas_size.world") == "1600x900" and F.detail("markers.canvas_size.world") == "UICustomSize"
    and F.value("markers.canvas_size.area") == "1400x860" and F.detail("markers.canvas_size.area") == "UICustomSize",
    "canvas_size.world = 1600x900, canvas_size.area = 1400x860, both from UICustomSize")
  local stw, sta = F.value("markers.self_test.world"), F.value("markers.self_test.area")
  check(type(stw) == "string" and stw:match("^%d+%.%d / %d+%.%d UI px %(raw / corrected, map width 1600%)$") ~= nil
    and tostring(F.detail("markers.self_test.world")):match("^box .+ %[registered%]$") ~= nil, "self_test.world: the text of the log line, with the box used (" .. tostring(stw) .. ")")
  check(type(sta) == "string" and sta:match("UI px %(raw / corrected, map width 1400%)$") ~= nil, "self_test.area likewise (" .. tostring(sta) .. ")")
  do
    local l = lastLogMatching("Map_World map Area")
    check(l ~= nil and stw ~= nil and l:find(stw, 1, true) ~= nil, "(the same numbers as in the log line)")
  end
  local room = 1600 - 100 - 900 * 0.95 - 16 - 100
  check(F.value("markers.button_row") == "900x44" and F.value("markers.legend") == "shrunk"
    and F.detail("markers.legend") == ("%.1fx%.1f"):format(room, LEGH * room / LEGW), "button_row = 900x44; legend = shrunk, with its size (" .. tostring(F.detail("markers.legend")) .. ")")
  check(F.value("markers.textures") == nil, "textures: not noted while images are still being loaded")
  tick(2.5)
  check(F.value("markers.textures") == ("%d loaded, 0 failed"):format(H.imports - imports0) and F.count["markers.textures"] == 1,
    "textures: noted once the loading has been quiet (" .. tostring(F.value("markers.textures")) .. ")")
  -- hover: learned once
  local stD = TD.state(mainD.Map_Area)
  mainD.Map_World.IsBackground = true
  tick(2.5)
  local dA = stD.entries["OC_STT_Diego"]
  dA.pin.hover = true; tick(0.15)
  check(stD.group ~= nil and F.value("markers.hover_path") == "canvas fast path", "hover_path = canvas fast path")
  dA.pin.hover = false; tick(0.15)
  mainD.Map_World.IsBackground = false
  tick(2.5)
  -- the row gets shorter, longer
  H.rowW = 700; tick(1.2)
  check(F.value("markers.button_row") == "700x44" and F.value("markers.legend") == "on the button row"
    and F.detail("markers.legend") == ("%.1fx%.1f"):format(LEGW, LEGH), "legend = on the button row when there is room (button_row = 700x44)")
  H.rowW = 1300; tick(1.2)
  check(F.value("markers.button_row") == "1300x44" and F.value("markers.legend") == "below the row", "legend = below the row when there is none")
  H.rowW = nil; tick(1.2)
  check(F.value("markers.legend") == "shrunk" and F.count["markers.legend"] == 4, "and back: every change of place is noted, nothing else")
  -- steady state: nothing is noted again
  local n0 = #F.notes
  for _ = 1, 40 do tick(0.15) end
  for _ = 1, 6 do tick(2.5) end
  check(#F.notes == n0, ("steady state: 46 more updates, no note (%d)"):format(#F.notes - n0))
  check(onlyKnownKeys(F), "only keys of the list are used (" .. tostring(select(2, onlyKnownKeys(F))) .. ")")
  check(neverRepeated(F), "no key is noted twice in a row with the same value (" .. tostring(select(2, neverRepeated(F))) .. ")")
  check(#F.crumbs >= 3 and crumbsOnce(F) and F.crumbCount("findStaticOnce /Script/Engine.Default__KismetRenderingLibrary") == 1
    and F.crumbCount("findStaticOnce /Script/G1R.Default__GothicNPCState") == 1,
    ("a breadcrumb before each search by path, once per path (%d)"):format(#F.crumbs))
  -- status and dump with both maps refreshed
  do
    local lines = F.status[1]()
    local l = lastLogMatching("map Area")
    local world, area
    for _, x in ipairs(lines) do
      if x:find("^Map_World Area: ") then world = x end
      if x:find("^Map_Area Area%.OldCamp: ") then area = x end
    end
    check(#lines == 5 and lines[5]:find("^pictures: %d+ loaded %(0 kept alive for the whole run%), 0 loaded again; images: 0 did not take their picture, 0 given a new loading of it$") ~= nil
      and lines[2] == "last map refresh: " .. tostring(l):gsub("^%[NPCMarkers%] ", ""):gsub("\n$", ""), "status: version line, the last refresh line as logged")
    check(world == "Map_World Area: 12 single pins, 0 pools with 0 people, 0 labels | people 12 live, 0 approximate, 0 hidden" and area ~= nil
      and area:find(" single pins, 0 pools with 0 people, ") ~= nil, "status: one line per map with its counts")
    for _, x in ipairs(lines) do if type(x) ~= "string" then check(false, "status lines are texts") end end
    local d = F.dump[1]()
    local okPlain, where = FK.plain(d, 6)
    check(okPlain, "dump: plain data, nothing shared, no cycle (" .. tostring(where) .. ")")
    local okTrip, why = FK.roundTrip(d)
    check(okTrip, "dump: written out as Lua and read back, it is the same (" .. tostring(why) .. ")")
    check(#d.maps == 2 and d.maps[1].which == "Map_Area" and d.maps[2].which == "Map_World" and d.maps[2].canvas_w == 1600 and d.maps[2].canvas_h == 900
      and d.maps[2].canvas_source == "UICustomSize" and d.maps[2].pin_size == 16 and d.maps[1].canvas_w == 1400 and d.maps[1].pin_size == 23
      and d.maps[2].single_pins == 12 and d.maps[2].live == 12 and d.maps[2].active == true, "dump: both map states with canvas size, pin size and counts")
    local stW = TD.state(mainD.Map_World)
    local want, got, bad = 0, 0, 0
    for _, def in ipairs(TD.npcs) do
      local en = stW.entries[def.id]
      if en and en.pin.vis ~= 1 then want = want + 1 end
    end
    for _, pn in ipairs(d.pins) do
      if pn.map == 2 then
        got = got + 1
        local en = stW.entries[pn.id]
        if not (en and close(pn.x, en.u * 1600, 1e-6) and close(pn.y, en.v * 900, 1e-6) and pn.mode == "live" and type(pn.name) == "string" and pn.kind ~= nil) then bad = bad + 1 end
      end
    end
    check(want == 12 and got == want and bad == 0, ("dump: the %d world-map pins with id, name, kind and place in canvas units (%d wrong)"):format(got, bad))
    check(#d.legend == 1 and d.legend[1].placed == "shrunk" and d.legend[1].left == 100 and close(d.legend[1].w, room, 0.01), "dump: where the colour key is")
    local okFacts = #d.facts > 0
    for _, f in ipairs(d.facts) do
      if F.value(f.key) ~= f.value or F.detail(f.key) ~= f.detail then okFacts = false end
    end
    local nKeys = 0
    for _ in pairs(F.count) do nKeys = nKeys + 1 end
    check(okFacts and #d.facts == nKeys, ("dump: the noted facts with their latest values (%d)"):format(#d.facts))
  end
  -- a second map screen in the same session shows the same facts: none of them is noted again
  do
    local nBefore = #F.notes
    mainD.__active = false
    local mainD2 = newMain("MainDiag1b", nil, nil, FIX.expect.ocA.__player)
    notify(mainD2)
    tick(1.0); tick(0.15); tick(1.2); tick(2.5)
    local st2 = TD.state(mainD2.Map_World)
    check(st2 ~= nil and lastLogMatching("Map_World map Area") ~= nil and #F.notes == nBefore,
      ("another map screen with the same answers: its refresh is logged, nothing is noted again (%d new notes)"):format(#F.notes - nBefore))
  end
  -- a map load: the mod forgets the screen; what was noted stays noted
  n0 = #F.notes
  freshSession()
  for _ = 1, 10 do tick(0.15) end
  check(#F.notes == n0 and #F.status[1]() == 4 and #F.dump[1]().maps == 0, "after a map load: no note, status and dump show no map")

  -- ---- other answers of the game
  freshSession()
  F = FK.new()
  H.panelHover, H.noButtonRow, H.staticBroken = "never", true, true
  TD = loadWith(DIR12, F, "none")
  H.staticBroken = true          -- (loading the mod does not reset the harness switches, freshSession does)
  local mainS = newMain("MainDiag2", nil, nil, FIX.expect.ocA.__player)
  mainS.Map_Area.__visible = false
  mainS.Map_World.m_ActiveMapData.UICustomSize = nil
  registry["W_Map_Main_C"] = { mainS }
  for _ = 1, 20 do tick(0.15) end
  registry["W_Map_Main_C"] = nil
  check(F.value("markers.map_found_by") == "scan" and F.value("markers.map_screens") == "searched for" and F.detail("markers.map_screens") == "UE4SS did not take the registration",
    "map_found_by = scan, map_screens = searched for (a UE4SS without announcements)")
  check(F.value("markers.state_lookup") == "scan" and tostring(F.detail("markers.state_lookup")):find("FindNPCByUniqueName unavailable", 1, true) ~= nil
    and F.count["markers.state_lookup"] == 1, "state_lookup = scan, with the reason")
  check(F.value("markers.canvas_size.world") == "1600x900" and F.detail("markers.canvas_size.world") == "default",
    "canvas_size.world: no UICustomSize and a size box that asks for more than the screen -> the default")
  check(F.value("markers.button_row") == "not found" and F.value("markers.legend") == "shrunk", "button_row = not found (a usual row is assumed for the key)")
  local stS = TD.state(mainS.Map_World)
  stS.entries["OC_STT_Diego"].pin.hover = true; tick(0.15)
  check(F.value("markers.hover_path") == "per-pin polling", "hover_path = per-pin polling")
  stS.entries["OC_STT_Diego"].pin.hover = false; tick(0.15)
  H.panelHover, H.noButtonRow = nil, nil
  check(onlyKnownKeys(F) and neverRepeated(F) and crumbsOnce(F), "again: known keys only, nothing repeated")

  freshSession()
  F = FK.new()
  TD = loadWith(modCopy("mdiagbox", list12 .. "\nC.WorldPools = false; C.LegendAvoidButtons = false"), F)
  local mainB = newMain("MainDiag3", nil, nil, FIX.expect.ocA.__player, nil, 1500, 800)
  mainB.Map_Area.__visible = false
  mainB.Map_World.m_ActiveMapData.UICustomSize = nil
  notify(mainB)
  tick(1.0); tick(1.2)
  check(F.value("markers.canvas_size.world") == "1500x800" and F.detail("markers.canvas_size.world") == "size box", "canvas_size.world from the size box when UICustomSize is missing")
  check(F.value("markers.legend") == "fixed position" and F.detail("markers.legend") == ("%.1fx%.1f"):format(LEGW, LEGH) and F.value("markers.button_row") == nil,
    "legend = fixed position with LegendAvoidButtons = false (the button row is not looked at)")

  freshSession()
  F = FK.new()
  TD = loadWith(modCopy("mdiagnokey", list12 .. "\nC.WorldPools = false; C.ShowLegend = false"), F)
  local mainN2 = newMain("MainDiag4", nil, nil, FIX.expect.ocA.__player)
  mainN2.Map_Area.__visible = false
  notify(mainN2)
  tick(1.0); tick(1.2); tick(1.2)
  check(F.value("markers.legend") == "not shown" and F.detail("markers.legend") == "switched off in config.lua" and F.count["markers.legend"] == 1 and #legendsOf(mainN2) == 0,
    "legend = not shown (switched off), noted once")

  -- ---- full list: pools, camp names, the list of a pool
  freshSession()
  H.npcMode["NC_ORG_Lares_801"] = "dead"
  H.npcMode["NC_SLD_Lee_700"] = "missing"          -- no usual place known: hidden
  H.npcMode["UL_ORG_Aidan_859"] = "missing"        -- shown at his usual place
  F = FK.new()
  TD = loadWith(DIRFULL, F)
  local mainP = newMain("MainDiag5", "Area", "Area.NewCamp", nil)
  mainP.Map_Area.__visible = false
  notify(mainP)
  for _ = 1, 30 do tick(0.15) end
  tick(2.5); tick(0.15)
  local np, npeople, nsingle, _, big = verifyPools(TD, mainP.Map_World, "world map (diagnostics on)")
  check(F.value("markers.camp_names") == "5 shown" and F.count["markers.camp_names"] == 1, "camp_names = 5 shown")
  H.campHidden = { Button_OldCamp = true, Button_NewCamp = true }
  tick(2.5)
  check(F.value("markers.camp_names") == "3 shown" and F.count["markers.camp_names"] == 2, "camp_names follows what the game shows")
  H.campHidden = nil
  tick(2.5)
  local stP = TD.state(mainP.Map_World)
  big.p.pin.hover = true
  for _ = 1, 12 do tick(0.15) end
  check(stP.group and stP.group.pool and F.value("markers.pool_list_canvas") == "own canvas" and F.count["markers.pool_list_canvas"] == 1, "pool_list_canvas = own canvas")
  check(F.value("markers.hover_path") == "canvas fast path", "hover_path learned from a pool as well")
  big.p.pin.hover = false
  tick(0.15); tick(2.5)
  do
    local lines = F.status[1]()
    local found = false
    for _, x in ipairs(lines) do
      if x == ("Map_World Area: %d single pins, %d pools with %d people, 0 labels | people %d live, 1 approximate, 2 hidden")
          :format(nsingle, np, npeople, nsingle + npeople - 1) then found = true end
    end
    if not found then for _, x in ipairs(lines) do io.write("    STATUS ", x, "\n") end end
    check(found and nsingle + npeople == 179, "status: pools and single pins of the world map as the independent model says; 1 approximate, 2 hidden")
    local d = F.dump[1]()
    local okPlain, where = FK.plain(d, 6)
    local okTrip = FK.roundTrip(d)
    check(okPlain and okTrip, "dump with pools: plain data that survives being written out (" .. tostring(where) .. ")")
    local worldIndex
    for i, m in ipairs(d.maps) do if m.which == "Map_World" then worldIndex = i end end
    local pools, members, singles, bad = 0, 0, 0, 0
    for _, pl in ipairs(d.pools) do
      if pl.map == worldIndex then
        pools, members = pools + 1, members + #pl.members
        if pl.count ~= #pl.members then bad = bad + 1 end
        local p = stP.pools[pl.members[1]]
        for _, id in ipairs(pl.members) do if stP.pools[id] then p = stP.pools[id] end end
        local a = p and p.pinSlot.calls.SetAnchors.Minimum
        if not (a and close(pl.x, a.X * 1600, 0.01) and close(pl.y, a.Y * 900, 0.01)) then bad = bad + 1 end
      end
    end
    for _, pn in ipairs(d.pins) do if pn.map == worldIndex then singles = singles + 1 end end
    check(pools == np and members == npeople and singles == nsingle and bad == 0,
      ("dump: %d pools with their %d members and place, %d single pins (%d wrong)"):format(pools, members, singles, bad))
    local approx, aidan, hiddenShown = 0, nil, 0
    for _, pn in ipairs(d.pins) do
      if pn.mode == "approximate" then approx = approx + 1 end
      if pn.id == "UL_ORG_Aidan_859" then aidan = pn.mode end
      if pn.id == "NC_SLD_Lee_700" or pn.id == "NC_ORG_Lares_801" then hiddenShown = hiddenShown + 1 end
    end
    for _, pl in ipairs(d.pools) do
      for _, id in ipairs(pl.members) do
        if id == "UL_ORG_Aidan_859" then aidan = "in a pool" end
        if id == "NC_SLD_Lee_700" or id == "NC_ORG_Lares_801" then hiddenShown = hiddenShown + 1 end
      end
    end
    check(hiddenShown == 0 and ((aidan == "approximate" and approx == 1) or (aidan == "in a pool" and approx == 0)),
      "dump: the NPC shown at his usual place is marked approximate (" .. tostring(aidan) .. "); the dead and the unknown one are not in it")
  end
  -- no overlay above the map: the list goes into the marker canvas
  freshSession()
  H.npcMode["NC_ORG_Lares_801"] = "dead"
  H.npcMode["NC_SLD_Lee_700"] = "missing"
  F = FK.new()
  TD = loadWith(DIRFULL, F)
  local mainQ = newMain("MainDiag6", "Area", "Area.NewCamp", nil)
  mainQ.Map_Area.__visible = false
  mainQ.Map_World.__parent = nil
  notify(mainQ)
  for _ = 1, 30 do tick(0.15) end
  tick(2.5); tick(0.15)
  local _, _, _, _, bigQ = verifyPools(TD, mainQ.Map_World, "world map (no overlay above the map)")
  bigQ.p.pin.hover = true
  for _ = 1, 12 do tick(0.15) end
  check(F.value("markers.pool_list_canvas") == "marker canvas", "pool_list_canvas = marker canvas when the screen has no overlay above the map")
  bigQ.p.pin.hover = false
  tick(0.15)
  check(onlyKnownKeys(F) and neverRepeated(F) and crumbsOnce(F), "full list: known keys only, nothing repeated, one breadcrumb per path")

  -- ---- the same session with and without the handle: the mod does the same
  -- load: a function that loads the mod and returns its test hook
  local function session(load)
    freshSession()
    H.npcMode["NC_ORG_Lares_801"] = "dead"
    H.npcMode["NC_SLD_Lee_700"] = "missing"
    local static0 = 0
    for _, n in pairs(H.staticCalls) do static0 = static0 + n end
    local c0 = { SlotCalls, Created.images, Created.canvases, H.imports, H.findAll or 0 }
    local TT = load()
    local main = newMain("MainSame", "Area", "Area.NewCamp", nil)
    notify(main)
    for _ = 1, 40 do tick(0.15) end
    tick(2.5)
    main.Map_Area.__visible = false
    tick(2.5); tick(0.15)
    local stx = TT.state(main.Map_World)
    local keys = {}
    for k in pairs(stx.pools) do keys[#keys + 1] = k end
    table.sort(keys)
    local pool = stx.pools[keys[1]]
    pool.pin.hover = true
    for _ = 1, 12 do tick(0.15) end
    local open = stx.group ~= nil and stx.group.pool ~= nil
    pool.pin.hover = false
    tick(0.15); tick(2.5)
    main.Map_Area.__visible = true
    tick(2.5)
    local out = { "list opened: " .. tostring(open) }
    for _, which in ipairs({ "Map_World", "Map_Area" }) do
      local sx = TT.state(main[which])
      for _, def in ipairs(TT.npcs) do
        local en = sx.entries[def.id]
        if en then
          local c = en.pinSlot.calls
          out[#out + 1] = ("%s %s vis=%s at=%.6f,%.6f size=%.3f alpha=%.3f z=%s label=%s"):format(which, def.id, tostring(en.pin.vis),
            c.SetAnchors and c.SetAnchors.Minimum.X or -1, c.SetAnchors and c.SetAnchors.Minimum.Y or -1, c.SetSize and c.SetSize.X or -1,
            en.pin.color and en.pin.color.A or -1, tostring(c.SetZOrder), tostring(en.label and en.label.vis))
        end
      end
      local pk = {}
      for k in pairs(sx.pools) do pk[#pk + 1] = k end
      table.sort(pk)
      for _, k in ipairs(pk) do
        local p = sx.pools[k]
        local a = p.pinSlot.calls.SetAnchors.Minimum
        out[#out + 1] = ("%s pool %s n=%d vis=%s at=%.6f,%.6f"):format(which, k, p.n, tostring(p.pin.vis), a.X, a.Y)
      end
    end
    for _, img in ipairs(legendsOf(main)) do
      local c = img.Slot.calls
      out[#out + 1] = ("key %.3f %.3f %.3f %.3f"):format(c.SetPosition.X, c.SetPosition.Y, c.SetSize.X, c.SetSize.Y)
    end
    local static1 = 0
    for _, n in pairs(H.staticCalls) do static1 = static1 + n end
    out[#out + 1] = ("calls: %d slot, %d images, %d canvases, %d imports, %d FindAllOf, %d FindNPCByUniqueName"):format(
      SlotCalls - c0[1], Created.images - c0[2], Created.canvases - c0[3], H.imports - c0[4], (H.findAll or 0) - c0[5], static1 - static0)
    local logged = 0
    for _ in ipairs(H.logs) do logged = logged + 1 end
    return table.concat(out, "\n"), #out, out[#out]
  end
  local logs0 = #H.logs
  local plain, nPlain, callsPlain = session(function() return loadWith(DIRFULL, nil) end)
  local logsPlain = #H.logs - logs0
  logs0 = #H.logs
  F = FK.new()
  local withDiag, _, callsDiag = session(function() return loadWith(DIRFULL, F) end)
  local logsDiag = #H.logs - logs0
  local notesOfSession = #F.notes
  check(nPlain > 100 and plain == withDiag, ("same session with and without G1R_DIAG: every pin, badge and the key end up the same (%d lines compared)"):format(nPlain))
  check(callsPlain == callsDiag, "and the mod made the same calls: " .. tostring(callsDiag))
  check(logsPlain == logsDiag and #F.notes > 5, ("and logged the same number of lines (%d); with the handle %d facts were noted"):format(logsDiag, #F.notes))

  -- ---- the megamod's own recorder and module loader (Scripts/core/diag.lua, sandbox.lua) instead of the stand-in
  print("== scenario 16: the same session through the megamod's module loader and recorder\n")
  ;(function()
    local CORE = HERE .. "../../../Scripts/core/"
    local root = TMP .. "megamod"
    os.execute("rm -rf " .. root .. " && mkdir -p " .. root .. "/Scripts/diagnostics")
    local said = {}
    local Diag = dofile(CORE .. "diag.lua")
    local Sandbox = dofile(CORE .. "sandbox.lua")
    local started = Diag.init(root, { Level = "normal" }, function(text) said[#said + 1] = text end, { name = "G1R_MegaMod", version = "0.0.0-test" })
    Sandbox.init(Diag, _G.print)
    check(started == true and Diag.enabled == true, "the recorder starts in a folder of the test")
    logs0 = #H.logs
    local hook2 = {}
    local viaCore, _, callsCore = session(function()
      QUIET = true
      H.loop = nil
      local env2 = Sandbox.environment("markers")
      env2.NPCMARKERS_TEST = hook2
      local chunk = assert(loadfile(DIRFULL .. "main.lua", nil, env2))
      chunk()
      QUIET = false
      return hook2
    end)
    check(viaCore == plain and callsCore == callsPlain and #H.logs - logs0 == logsPlain,
      "every pin, badge and the key end up as without the megamod; same calls, same number of log lines")
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
    check(log:find("[markers] [NPCMarkers] v" .. VER .. " loaded: 181 named NPCs", 1, true) ~= nil and log:find("[markers] [NPCMarkers] Map_World map Area", 1, true) ~= nil,
      "session log: what the mod printed, under its module name")
    local noted, want = {}, {}
    for key, value in log:gmatch("%[markers%] note (%S+) = ([^\n]*)") do
      value = value:gsub(" %[was .-%]$", ""):gsub(" %(further changes of this note are only counted%)$", "")
      noted[#noted + 1] = key .. "=" .. value
    end
    for i = 1, notesOfSession do
      local n = F.notes[i]
      want[#want + 1] = tostring(n.key) .. "=" .. tostring(n.value) .. (n.detail ~= nil and (" (" .. tostring(n.detail) .. ")") or "")
    end
    local noteDiff
    for i = 1, math.max(#noted, #want) do if noted[i] ~= want[i] then noteDiff = i; break end end
    check(noteDiff == nil and #noted >= 10, ("session log: the %d notes of the session, as the stand-in got them%s"):format(#noted,
      noteDiff and (" - first difference at " .. noteDiff .. ": '" .. tostring(noted[noteDiff]) .. "' / '" .. tostring(want[noteDiff]) .. "'") or ""))
    local nCalls, nFirst, nMissing, nRepeated = report:match("%[markers%] lookups: (%d+) calls, (%d+) first%-time, (%d+) not found, (%d+) repeated after not found")
    nCalls, nFirst, nMissing, nRepeated = tonumber(nCalls), tonumber(nFirst), tonumber(nMissing), tonumber(nRepeated)
    local crumbs = 0
    for _ in log:gmatch("%[markers%] > lookup /") do crumbs = crumbs + 1 end
    check(nCalls == 4 and nFirst == 4 and nMissing == 0 and nRepeated == 0 and crumbs == 4,
      ("report: %s searches by path in the whole session (4 paths, each once), %s not found, %s repeated; %d breadcrumbs on disk"):format(
        tostring(nCalls), tostring(nMissing), tostring(nRepeated), crumbs))
    check(not log:find("NOT FOUND again", 1, true) and not log:find("ERROR in ", 1, true) and report:find("\ncount: 0 %(0 distinct%)") ~= nil and #said == 0,
      "no repeated search, no error recorded, nothing said to UE4SS.log by the recorder")
    local loops, loopErrors = report:match("%[markers%] callbacks LoopInGameThreadWithDelay: (%d+) calls, (%d+) errors")
    check(tonumber(loops or 0) >= 50 and loopErrors == "0" and report:find("%[markers%] callbacks NotifyOnNewObject: 1 calls, 0 errors") ~= nil
      and report:find("%[markers%] registered LoopInGameThreadWithDelay: 1 ok, 0 failed") ~= nil,
      ("report: %s timer calls and the notification went through the guard without an error"):format(tostring(loops)))
    check(report:find("== status ==\n%[markers%] v" .. VERP .. " | 181 named NPCs") ~= nil and report:find("%[markers%]\nmarkers%.button_row = 900x44") ~= nil,
      "report: the mod's status lines and its notes")
    local chunk = load(dumpText, "=dump", "t", {})
    local okDump, dump = pcall(chunk or error)
    local m = okDump and type(dump) == "table" and dump.markers or {}
    check(okDump and type(dump.markers) == "table" and dump._meta.modules.markers == "dumped" and dump._meta.refusedCount == 0,
      "dump: loads, holds the mod's table, nothing in it was refused")
    check(type(m.maps) == "table" and #m.maps == 2 and #m.pins > 50 and #m.pools >= 2 and #m.legend == 1 and #m.facts >= 8,
      ("dump: %d maps, %d pins, %d pools, the key, %d facts"):format(#(m.maps or {}), #(m.pins or {}), #(m.pools or {}), #(m.facts or {})))
  end)()

  -- ---- loaded the way the loader does it: an environment of its own
  freshSession()
  F = FK.new()
  local hook = {}
  local before = FK.keys(_G)
  local env, run = FK.sandbox({ G1R_DIAG = F.handle, NPCMARKERS_TEST = hook, print = _G.print })
  H.loop = nil
  QUIET = true
  local okRun, errRun = run(DIRFULL .. "main.lua")
  QUIET = false
  check(okRun, "the mod loads in an environment of its own (" .. tostring(errRun) .. ")")
  check(type(hook.state) == "function" and rawget(_G, "G1R_DIAG") == nil and #F.versions == 1 and #F.status == 1 and #F.dump == 1,
    "it sees G1R_DIAG and its test hook there, not in the real globals")
  local leaked = FK.newKeys(_G, before)
  check(#leaked == 0, "and defines no real global (" .. table.concat(leaked, ", ") .. ")")
  local mainE = newMain("MainDiag7", "Area", "Area.NewCamp", nil)
  mainE.Map_Area.__visible = false
  notify(mainE)
  for _ = 1, 30 do tick(0.15) end
  tick(2.5)
  local stE = hook.state(mainE.Map_World)
  local pinsE = 0
  if stE then for _ in pairs(stE.entries) do pinsE = pinsE + 1 end end
  check(stE ~= nil and pinsE > 10 and F.value("markers.map_found_by") == "notification", ("and works there (%d pins on the world map)"):format(pinsE))
  _G.NPCMARKERS_TEST = nil
end)()

-- ========================== pictures and what shows them (2.4) ==================
assert(loadfile(HERE .. "pictures_cases.lua"))({
  H = H, check = check, tick = tick, notify = notify, newMain = newMain, loadMod = loadMod, freshSession = freshSession,
  ourPanel = ourPanel, legendsOf = legendsOf, listCanvasOf = listCanvasOf, States = States, addState = addState, FIX = FIX, CFG = CFG,
  Created = Created, obj = obj, Ctrl = Ctrl, modCopy = modCopy, list12 = list12, lastLogMatching = lastLogMatching, SRC = SRC, HERE = HERE,
  registry = registry,
  DIR12 = DIR12, DIRFULL = DIRFULL, DIRFULLNOPOOL = DIRFULLNOPOOL, quiet = function(on) QUIET = on end,
})

local errs = 0
for _, s in ipairs(H.logs) do if s:find("^%[NPCMarkers%]") and (s:find("failed") or s:find("[Ee]rror")) then errs = errs + 1; io.write("    ERR ", s) end end
check(errs == 0, "no error lines logged")
print(("== h23 finished: %d ok, %d failure(s)\n"):format(oks, fails))
os.exit(fails == 0 and 0 or 1)
