-- Scenarios for NPCMarkers 2.4: the pictures the mod loads and the images that
-- show them. Loaded by harness.lua with what it needs from there.
--   * an image that does not take its picture is never shown, and is tried again
--   * a picture that is gone is loaded again, and every image that showed it takes the new loading - once
--   * no place in the canvas: nothing half-made is kept
--   * a world is loaded while pins are still being made
--   * a new map screen at the address and under the name of the old one
--   * the names of the people under the mouse are made within the update's allowance
--   * with the megamod's kit: pictures are kept alive for the whole run
local X = ...
local H, check, tick, notify, newMain, loadMod, freshSession = X.H, X.check, X.tick, X.notify, X.newMain, X.loadMod, X.freshSession
local ourPanel, States, addState, FIX, CFG, Created, obj = X.ourPanel, X.States, X.addState, X.FIX, X.CFG, X.Created, X.obj
local FK = dofile(X.HERE .. "diag_fake.lua")
local function say(text) print("== " .. text .. "\n") end
local logsAtStart = #H.logs
local function isPin(t) return type(t) == "table" and type(t.__path) == "string" and t.__path:find("/Pins/", 1, true) ~= nil end

-- the images of the mod's canvas on a map, by what they are
local function images(mapWidget)
  local panel = ourPanel(mapWidget)
  return panel and panel.__children or {}
end
-- no image is visible without a picture, and none shows a picture that is gone
local function allShownHavePictures(mapWidget)
  local shown, blank, stale = 0, 0, 0
  for _, img in ipairs(images(mapWidget)) do
    if img.vis ~= nil and img.vis ~= 1 then
      shown = shown + 1
      if img.tex == nil then blank = blank + 1
      elseif img.tex.__valid == false then stale = stale + 1 end
    end
  end
  return blank == 0 and stale == 0, shown, blank, stale
end
local function pins(T, mapWidget)
  local st = T.state(mapWidget)
  local n, visible = 0, 0
  for _, e in pairs(st and st.entries or {}) do
    n = n + 1
    if e.pin.vis ~= 1 then visible = visible + 1 end
  end
  return n, visible
end
local function labelsShown(T, mapWidget)
  local st = T.state(mapWidget)
  local n = 0
  for _, e in pairs(st and st.entries or {}) do if e.label and e.label.vis == 3 then n = n + 1 end end
  return n
end
local function load(dir, fake, kit, noNotify)
  rawset(_G, "G1R_DIAG", fake and fake.handle or nil)
  rawset(_G, "G1R_KIT", kit)
  X.quiet(true)
  local ok, T = pcall(loadMod, dir, noNotify)
  X.quiet(false)
  rawset(_G, "G1R_DIAG", nil)
  rawset(_G, "G1R_KIT", nil)
  if not ok then error(T, 0) end
  return T
end
local function reset()
  H.brushFail, H.brushSilent, H.brush, H.slotFail, H.brushCalls = nil, nil, nil, nil, 0
  freshSession()
end
local DIRALWAYS12 = X.modCopy("p_always", X.list12 .. "\nC.WorldPools = false; C.AreaLabels = 'always'; C.WorldLabels = 'always'")
local DIRSMALL = X.modCopy("p_small", "C.WorldPools = false; C.MaxNewWidgetsPerTick = 6")

-- ================================================================ an image that does not take its picture
say("pictures: an image that does not take its picture is not shown, and is tried again")
reset()
local T = load(X.DIR12)
local main = newMain("MainP1", nil, nil, FIX.expect.ocA.__player)
main.Map_Area.__visible = false
local failing = 3
H.brushFail = function(_, t) if failing > 0 and isPin(t) then failing = failing - 1; return true end end
notify(main)
tick(); tick()
local n, visible = pins(T, main.Map_World)
check(n == 9 and visible == 9 and #images(main.Map_World) == 9, ("three calls did not go through: 9 pins are there, nothing half-made is in the canvas (%d pins, %d images)"):format(n, #images(main.Map_World)))
check((allShownHavePictures(main.Map_World)), "no image is shown without a picture")
tick(2.5)
n, visible = pins(T, main.Map_World)
check(n == 12 and visible == 12 and (allShownHavePictures(main.Map_World)), "the three are made at the next refresh")
local tex = T.pictures()
check(tex.bindFailed == 3, "counted: 3 images did not take their picture (" .. tostring(tex.bindFailed) .. ")")
H.brushFail = nil

-- names: the call keeps failing for the name pictures, then works again
reset()
T = load(DIRALWAYS12)
main = newMain("MainP2", nil, nil, FIX.expect.ocA.__player)
main.Map_Area.__visible = false
H.brushFail = function(_, t) return t.__path ~= nil and t.__path:find("/Labels/", 1, true) ~= nil end
notify(main)
for _ = 1, 10 do tick(2.5) end
local okPictures, shown = allShownHavePictures(main.Map_World)
check(pins(T, main.Map_World) == 12 and labelsShown(T, main.Map_World) == 0 and okPictures and #images(main.Map_World) == 12,
  ("name pictures are not taken for ten refreshes: the pins are there, no name is shown blank, the canvas does not grow (%d images)"):format(#images(main.Map_World)))
local attempts = H.brushCalls
check(attempts <= 12 + 10 * CFG.MaxNewWidgetsPerTick, ("and the tries stay within the allowance of each refresh (%d calls)"):format(attempts))
H.brushFail = nil
tick(2.5); tick(2.5)
check(labelsShown(T, main.Map_World) == 12 and (allShownHavePictures(main.Map_World)), "the call works again: all 12 names are shown")

-- the call returns and has set nothing: seen where the image's brush can be read back
reset()
H.brush = true
local F = FK.new()
T = load(X.DIR12, F)
main = newMain("MainP3", nil, nil, FIX.expect.ocA.__player)
main.Map_Area.__visible = false
local silent, pinCalls = 2, 0
H.brushSilent = function(_, t)
  if not isPin(t) then return false end
  pinCalls = pinCalls + 1
  if pinCalls >= 5 and silent > 0 then silent = silent - 1; return true end       -- (the fifth and sixth pin)
end
notify(main)
tick(); tick()
n = pins(T, main.Map_World)
check(n == 10 and (allShownHavePictures(main.Map_World)) and F.value("markers.image_binding") == "read back from the image's brush",
  ("the call says nothing and sets nothing (twice): found by reading the brush back - those two pins are not made (%d)"):format(n))
tick(2.5)
check(pins(T, main.Map_World) == 12, "and are made at the next refresh")
H.brushSilent, H.brush = nil, nil
F = FK.new()
T = load(X.DIR12, F)
main = newMain("MainP3b", nil, nil, FIX.expect.ocA.__player)
main.Map_Area.__visible = false
notify(main)
tick(); tick()
check(F.value("markers.image_binding") == "taken from the call (the brush cannot be read back)" and pins(T, main.Map_World) == 12,
  "where the brush cannot be read back the call's success is what counts (noted)")

-- ================================================================ no place in the canvas
say("pictures: no place in the canvas - nothing half-made is kept")
reset()
T = load(X.DIR12)
main = newMain("MainP4", nil, nil, FIX.expect.ocA.__player)
main.Map_Area.__visible = false
local noPlace, imageAdds = 4, 0
H.slotFail = function(_, child)
  if child.__class ~= "Image" then return false end
  imageAdds = imageAdds + 1
  if imageAdds >= 4 and noPlace > 0 then noPlace = noPlace - 1; return true end       -- (four pins in a row)
end
notify(main)
tick(); tick()
n = pins(T, main.Map_World)
local st = T.state(main.Map_World)
local orphans = 0
for _, e in pairs(st.entries) do if e.pin.__parent ~= ourPanel(main.Map_World) then orphans = orphans + 1 end end
check(noPlace == 0 and n == 8 and orphans == 0 and #images(main.Map_World) == n, ("four images got no place: 8 pins, and no entry without an image in the canvas (%d pins, %d images)"):format(n, #images(main.Map_World)))
H.slotFail = nil
tick(2.5); tick(2.5)
check(pins(T, main.Map_World) == 12 and #images(main.Map_World) == 12, "they are made at the next refreshes; the other pins were never disturbed")

-- ================================================================ a picture that is gone
say("pictures: a picture that is gone is loaded again and every image that showed it takes the new loading")
reset()
T = load(DIRALWAYS12)
main = newMain("MainP5", nil, nil, FIX.expect.ocA.__player)
main.Map_Area.__visible = false
notify(main)
tick(); tick(2.5)
st = T.state(main.Map_World)
check(labelsShown(T, main.Map_World) == 12, "(12 pins with their names)")
-- one name picture
local diego = st.entries["OC_STT_Diego"]
local oldName = diego.label.tex
oldName.__valid = false
local imports0 = H.imports
tick(2.5)
check(diego.label.tex ~= oldName and diego.label.tex.__valid ~= false and diego.label.vis == 3 and H.imports == imports0 + 1,
  "a name picture is gone: loaded again once, and the name image - still valid, still in its place - shows the new loading")
check(diego.labelW == diego.label.tex.Blueprint_GetSizeX() and diego.labelH == diego.label.tex.Blueprint_GetSizeY(), "with the new loading's size")
-- a picture that many pins share; one of them is hidden while it is replaced
local shared, users = nil, {}
for _, e in pairs(st.entries) do
  local path = e.pin.tex.__path
  users[path] = users[path] or {}
  table.insert(users[path], e)
end
for path, list in pairs(users) do if not shared or #list > #users[shared] then shared = path end end
local group = users[shared]
check(#group >= 3, ("(%d pins share %s)"):format(#group, tostring(shared):match("([^/]+)$")))
local hidden = group[1]
H.npcMode[hidden.def.id] = "dead"
tick(2.5)
check(hidden.pin.vis == 1, "(one of them is hidden: its person is dead)")
local oldPin = hidden.pin.tex
oldPin.__valid = false
local calls = {}
for _, e in ipairs(group) do calls[e] = e.pin.brushCalls end
imports0 = H.imports
tick(2.5); tick(2.5)
local once, current = true, nil
for i = 2, #group do
  local e = group[i]
  if e.pin.brushCalls ~= calls[e] + 1 or e.pin.tex == oldPin or e.pin.tex.__valid == false then once = false end
  current = current or e.pin.tex
  if e.pin.tex ~= current then once = false end
end
check(once and H.imports == imports0 + 1, "the shared picture is gone: loaded again once, every shown pin takes the new loading exactly once")
check(hidden.pin.brushCalls == calls[hidden] and hidden.pin.vis == 1, "the hidden pin is left alone while it is hidden")
H.npcMode[hidden.def.id] = nil
tick(2.5); tick(2.5)
check(hidden.pin.vis ~= 1 and hidden.pin.tex == current and hidden.pin.brushCalls == calls[hidden] + 1, "and takes the new loading, once, before it is shown again")
check((allShownHavePictures(main.Map_World)), "no image shows a picture that is gone")
tex = T.pictures()
check(tex.again == 2 and tex.rebound == #group + 1, ("counted: 2 pictures loaded again, %d images given a new loading (%s)"):format(#group + 1, tostring(tex.rebound)))

-- ================================================================ a world is loaded while pins are still being made
say("pictures: a world is loaded while pins are still being made")
reset()
T = load(X.DIRFULL)
main = newMain("MainP6", "Area", "Area.NewCamp", nil)
notify(main)
tick(); tick()
local made = #images(main.Map_World) + #images(main.Map_Area)
st = T.state(main.Map_World)
check(made > 0 and st ~= nil and (st.pending or T.state(main.Map_Area).pending), ("(the first updates made %d images, more are waiting)"):format(made))
-- the old screen and everything on it is destroyed with its world
local touched = 0
local function kill(o)
  if type(o) ~= "table" or o.__dead then return end
  o.__dead, o.__valid = true, false
  for _, fn in ipairs({ "SetVisibility", "SetColorAndOpacity", "SetBrushFromTexture", "IsHovered", "RemoveFromParent", "AddChildToCanvas",
      "AddChildToOverlay", "GetParent", "IsVisible", "IsActivated", "GetDesiredSize" }) do
    o[fn] = function() touched = touched + 1 end
  end
  if o.Slot then
    o.Slot.__valid = false
    for fn in pairs(o.Slot.calls) do o.Slot[fn] = function() touched = touched + 1 end end
  end
  for _, c in ipairs(o.__children or {}) do kill(c) end
end
local oldWorld, oldArea = main.Map_World, main.Map_Area
local oldTextures = {}
for _, img in ipairs(images(oldWorld)) do if img.tex then oldTextures[img.tex] = true end end
H.pre()
kill(oldWorld.__general); kill(oldArea.__general); kill(main.__content); kill(oldWorld); kill(oldArea); kill(main)
for t in pairs(oldTextures) do t.__valid = false end      -- nothing shows them any more: the game destroys them
H.post()
local main2 = newMain("MainP6b", "Area", "Area.NewCamp", nil)
notify(main2)
for _ = 1, 40 do tick() end
check(touched == 0, ("nothing of the old world's screen is touched after the load (%d calls)"):format(touched))
local nWorld = pins(T, main2.Map_World)
check(nWorld > 20 and (allShownHavePictures(main2.Map_World)) and (allShownHavePictures(main2.Map_Area)),
  ("the new world's screen gets its pins, with pictures loaded for it (%d on the world map)"):format(nWorld))
local reused = 0
for _, img in ipairs(images(main2.Map_World)) do if img.tex and oldTextures[img.tex] then reused = reused + 1 end end
check(reused == 0, "no picture of the old world's screens is used again")

-- ================================================================ a new map screen at the address and under the name of the old one
say("pictures: a new map screen at the address and under the name of the old one")
reset()
T = load(X.DIR12)
main = newMain("MainSame", nil, nil, FIX.expect.ocA.__player)
main.Map_Area.__visible = false
notify(main)
tick(); tick(2.5)
local stOld = T.state(main.Map_World)
local panelOld = ourPanel(main.Map_World)
touched = 0
oldWorld = main.Map_World
kill(oldWorld.__general); kill(main.__content); kill(main.Map_Area); kill(oldWorld); kill(main)
tick(); tick()
main2 = newMain("MainSame", nil, nil, FIX.expect.ocA.__player)       -- the same names ...
main2.__addr, main2.Map_World.__addr, main2.Map_Area.__addr = main.__addr, oldWorld.__addr, main.Map_Area.__addr   -- ... and addresses
main2.Map_Area.__visible = false
notify(main2)
for _ = 1, 20 do tick() end
local stNew = T.state(main2.Map_World)
local onNew = 0
for _, e in pairs(stNew and stNew.entries or {}) do if e.pin.__parent == ourPanel(main2.Map_World) then onNew = onNew + 1 end end
check(stNew ~= nil and stNew ~= stOld and ourPanel(main2.Map_World) ~= panelOld and onNew == 12 and touched == 0,
  ("the new screen gets a state of its own: 12 pins in its own canvas, nothing of the old screen is touched (%d on it, %d calls)"):format(onNew, touched))
check(#X.legendsOf(main2) == 1, "and its own colour key")

-- ================================================================ the names of the people under the mouse
say("pictures: the names of the people under the mouse are made within the update's allowance")
reset()
T = load(DIRSMALL)          -- all 181 people, no pools, 6 new images or pictures per update
main = newMain("MainHover", "Area", "Area.NewCamp", nil)
main.Map_Area.__visible = false
notify(main)
local ticks = 0
repeat tick(); ticks = ticks + 1 until not T.state(main.Map_World).pending or ticks > 400
st = T.state(main.Map_World)
check(not st.pending, ("(all pins of the world map made, %d updates of 6)"):format(ticks))
-- the pin with the most others around it
local cw, ch = 1600, 900
local r = CFG.HoverGroupRadius * CFG.WorldPinSize
local best, bestN = nil, 0
for _, e in ipairs(st.hoverList) do
  local c = 0
  for _, o in ipairs(st.hoverList) do
    local dx, dy = (o.u - e.u) * cw, (o.v - e.v) * ch
    if dx * dx + dy * dy <= r * r then c = c + 1 end
  end
  if c > bestN then best, bestN = e, c end
end
local want = math.min(bestN, CFG.HoverListMax)
check(want >= 6, ("(%d pins lie within reach of %s)"):format(bestN, tostring(best and best.def.name)))
local function namesShown(group)
  local c = 0
  for _, e in ipairs(group.members) do if e.label and e.label.vis == 3 and e.labelSlot.calls.SetZOrder == 6 then c = c + 1 end end
  return c
end
local imports1, created1 = H.imports, Created.images
best.pin.hover = true
local steps, maxPerTick, series, inOrder = 0, 0, {}, true
repeat
  local i0, c0 = H.imports, Created.images
  tick()
  steps = steps + 1
  maxPerTick = math.max(maxPerTick, (H.imports - i0) + (Created.images - c0))
  local g = st.group
  local shownNow = g and namesShown(g) or 0
  series[#series + 1] = shownNow
  -- the names that are shown are the first ones of the list, in its order
  if g then
    for i = 1, shownNow do
      local e = g.members[i]
      if not (e.label and e.label.vis == 3) then inOrder = false end
    end
  end
until (st.group and not st.group.short and namesShown(st.group) >= want) or steps > 40
check(st.group ~= nil and namesShown(st.group) == want, ("all %d names are shown in the end (%s)"):format(want, table.concat(series, " ")))
check(maxPerTick <= 6, ("never more than the allowance of 6 new images and pictures in one update (%d)"):format(maxPerTick))
check(steps >= 3 and inOrder, ("they come a few per update, in the order of the list (%d updates)"):format(steps))
-- the mouse moves on before the list is complete, and comes back
best.pin.hover = false
tick()
local imports2, created2 = H.imports, Created.images
best.pin.hover = true
tick()
check(st.group ~= nil and namesShown(st.group) == want and H.imports == imports2 and Created.images == created2,
  "the mouse leaves and comes back: the names are there at once, nothing is loaded or made again")
best.pin.hover = false
tick()
-- a quick sweep over many pins makes no more than the allowance per update either
imports1, created1 = H.imports, Created.images
maxPerTick = 0
for i = 1, 30 do
  local e = st.hoverList[(i * 7) % #st.hoverList + 1]
  e.pin.hover = true
  local i0, c0 = H.imports, Created.images
  tick()
  maxPerTick = math.max(maxPerTick, (H.imports - i0) + (Created.images - c0))
  e.pin.hover = false
end
tick()
check(maxPerTick <= 6 and st.group == nil, ("the mouse sweeps over 30 pins: at most 6 per update (%d)"):format(maxPerTick))

-- ================================================================ with the megamod's kit
say("pictures: with the megamod's kit they are kept alive for the whole run")
reset()
local kept, keepCalls, refuse = {}, 0, 0
local controllerAsked = 0
local kit = {
  keepAlive = function(o)
    keepCalls = keepCalls + 1
    if refuse > 0 then refuse = refuse - 1; return false, "no game instance yet" end
    kept[o] = true
    return true
  end,
  controller = function() controllerAsked = controllerAsked + 1; return X.Ctrl end,
}
F = FK.new()
H.findAllBy = {}
T = load(X.DIR12, F, kit)
main = newMain("MainKit", nil, nil, FIX.expect.ocA.__player)
main.Map_Area.__visible = false
notify(main)
tick(); tick(2.5)
tex = T.pictures()
local allKept = true
for _, img in ipairs(images(main.Map_World)) do if not kept[img.tex] then allKept = false end end
check(pins(T, main.Map_World) == 12 and allKept and tex.kept == tex.loaded and tex.loaded > 0
  and F.value("markers.textures_kept") == "for the whole run (the game instance refers to them)",
  ("every picture is handed to the kit when it is loaded (%d loaded, %d kept)"):format(tex.loaded, tex.kept))
check(controllerAsked > 0 and (H.findAllBy["GothicPlayerControllerBaseBP_C"] or 0) == 0, "the player controller comes from the kit: not searched for")
-- a map load and a new screen: the pictures are still there and are used again
local before = {}
for _, img in ipairs(images(main.Map_World)) do before[img.tex] = true end
imports0 = H.imports
H.pre(); H.post()
main2 = newMain("MainKit2", nil, nil, FIX.expect.ocA.__player)
main2.Map_Area.__visible = false
notify(main2)
tick(); tick(2.5)
local same = true
for _, img in ipairs(images(main2.Map_World)) do if not before[img.tex] then same = false end end
check(pins(T, main2.Map_World) == 12 and same and H.imports == imports0, "after a map load the new screen shows the same pictures: nothing is loaded again")
-- the kit cannot keep one yet (no game instance): that picture belongs to its screen until the kit takes it
reset()
kept, refuse = {}, 2
F = FK.new()
T = load(X.DIR12, F, kit)
main = newMain("MainKit3", nil, nil, FIX.expect.ocA.__player)
main.Map_Area.__visible = false
notify(main)
tick(); tick(2.5); tick(2.5)
tex = T.pictures()
check(pins(T, main.Map_World) == 12 and tex.kept == tex.loaded, ("pictures the kit could not take at first are handed over at a later use (%d of %d kept)"):format(tex.kept, tex.loaded))

-- ================================================================ a person's state object is asked for at every refresh
say("markers: a person's state object comes fresh from the game at every refresh")
reset()
T = load(X.DIR12)
main = newMain("MainState", nil, nil, FIX.expect.ocA.__player)
main.Map_Area.__visible = false
notify(main)
tick(); tick(2.5)
local id = "OC_STT_Diego"
local c0 = H.staticCalls[id] or 0
local old = States[id]
-- the game replaces the state object (the person was unloaded and loaded again); the old object is gone
local oldTouched = 0
old.__valid = false
for _, fn in ipairs({ "GetCharacterLocation", "IsDead", "GetRemovedFromWorld", "GetCharacterUniqueName" }) do
  old[fn] = function() oldTouched = oldTouched + 1 end
end
local moved = { FIX.live[id][1] + 800, FIX.live[id][2], FIX.live[id][3] }
addState(id, moved)
st = T.state(main.Map_World)
local anchorsBefore = st.entries[id].pinSlot.count.SetAnchors
tick(2.5); tick(2.5)
check((H.staticCalls[id] or 0) - c0 == 2 and oldTouched == 0 and st.entries[id].pinSlot.count.SetAnchors == anchorsBefore + 1,
  ("two refreshes: the game is asked for the state twice, the old object is never touched, the pin follows the new one (%d lookups)"):format((H.staticCalls[id] or 0) - c0))
States[id].__pos = FIX.live[id]
reset()

-- ================================================================ a kit that cannot keep pictures; a new screen without a map load
say("pictures: a kit that cannot keep them - they belong to their map screen, as without the kit")
for _, how in ipairs({ "says no", "raises", "is not there" }) do
  reset()
  local asked = 0
  local kitNo = { controller = function() return X.Ctrl end,
    keepAlive = function()
      asked = asked + 1
      if how == "raises" then error("the list cannot be written") end
      return false, "the game instance's list cannot be added to"
    end }
  if how == "is not there" then kitNo = nil end
  F = FK.new()
  T = load(X.DIR12, F, kitNo)
  main = newMain("MainNoKeep_" .. how, nil, nil, FIX.expect.ocA.__player)
  main.Map_Area.__visible = false
  notify(main)
  tick(); tick(2.5)
  tex = T.pictures()
  check(pins(T, main.Map_World) == 12 and tex.kept == 0 and tex.loaded > 0 and (kitNo == nil or asked >= tex.loaded)
    and F.value("markers.textures_kept") == "per map screen",
    ("the kit %s: no picture counts as kept alive (%d loaded, %d kept), noted"):format(how, tex.loaded, tex.kept))
  -- The map is closed and opened again: the game makes a new screen. The pictures of the first one are still
  -- there as objects - the game destroys them some time later - and must not be given to an image of the new one.
  local first = {}
  for _, img in ipairs(images(main.Map_World)) do first[img.tex] = true end
  for _, img in ipairs(X.legendsOf(main)) do if img.tex then first[img.tex] = true end end
  touched = 0
  kill(main.Map_World.__general); kill(main.__content); kill(main.Map_Area); kill(main.Map_World); kill(main)
  imports0 = H.imports
  main2 = newMain("MainNoKeep2_" .. how, nil, nil, FIX.expect.ocA.__player)
  main2.Map_Area.__visible = false
  notify(main2)
  tick(); tick(2.5)
  local again = 0
  for _, img in ipairs(images(main2.Map_World)) do if first[img.tex] then again = again + 1 end end
  check(pins(T, main2.Map_World) == 12 and again == 0 and H.imports > imports0 and (allShownHavePictures(main2.Map_World)) and touched == 0,
    ("a new map screen in the same world: its pictures are loaded for it (%d), none of the earlier screen's is given to a new image"):format(H.imports - imports0))
end

-- ================================================================ how often the brush is read back
say("pictures: the brush is read back for the first images of a run, and for every picture that is not kept alive")
local kitYes = { keepAlive = function() return true end, controller = function() return X.Ctrl end }
-- kept alive, brush readable: eight checks, then the call's success is enough
reset()
H.brush = true
F = FK.new()
T = load(DIRALWAYS12, F, kitYes)
main = newMain("MainChecks1", nil, nil, FIX.expect.ocA.__player)
main.Map_Area.__visible = false
notify(main)
tick(); tick(2.5); tick(2.5)
tex = T.pictures()
check(H.brushCalls > 20 and tex.checked == 8 and tex.bindFailed == 0 and F.value("markers.image_binding") == "read back from the image's brush"
  and (H.matchSize or 0) == 0, ("pictures kept alive: %d images were given a picture, the brush was read back for the first 8 (%d); no image is asked to take the picture's size"):format(H.brushCalls, tex.checked))
-- brush not readable: eight tries, then it is not asked for any more
reset()
F = FK.new()
T = load(DIRALWAYS12, F)
main = newMain("MainChecks2", nil, nil, FIX.expect.ocA.__player)
main.Map_Area.__visible = false
notify(main)
tick(); tick(2.5); tick(2.5)
tex = T.pictures()
check(H.brushCalls > 20 and tex.checked == 8 and F.value("markers.image_binding") == "taken from the call (the brush cannot be read back)" and F.count["markers.image_binding"] == 1,
  ("a brush that cannot be read back: asked for 8 times (%d), then no more; noted once"):format(tex.checked))
-- not kept alive, brush readable: every image is checked
reset()
H.brush = true
T = load(DIRALWAYS12)
main = newMain("MainChecks3", nil, nil, FIX.expect.ocA.__player)
main.Map_Area.__visible = false
local late, calls3 = nil, 0
H.brushSilent = function(img, t)
  calls3 = calls3 + 1
  if calls3 == 20 then late = img; return true end      -- the twentieth image: the call returns and has set nothing
end
notify(main)
tick(); tick(2.5)
tex = T.pictures()
check(late ~= nil and tex.checked == H.brushCalls and tex.bindFailed == 1 and (allShownHavePictures(main.Map_World)) and (late.vis == nil or late.vis == 1),
  ("pictures that are not kept alive: the brush is read back every time (%d of %d) - the twentieth image did not take its picture and is not shown"):format(tex.checked, H.brushCalls))
H.brushSilent = nil
tick(2.5); tick(2.5)
check(pins(T, main.Map_World) == 12 and labelsShown(T, main.Map_World) == 12 and (allShownHavePictures(main.Map_World)) and T.pictures().bindFailed == 1,
  "it is made at a later refresh; nothing else was counted as failed")

-- ================================================================ an image that does not take the new loading of its picture
say("pictures: an image that does not take the new loading of its picture is hidden until it does")
for _, how in ipairs({ "the call raises", "the call sets nothing" }) do
  reset()
  H.brush = true
  T = load(DIRALWAYS12)
  main = newMain("MainRebind_" .. how:gsub(" ", "_"), nil, nil, FIX.expect.ocA.__player)
  main.Map_Area.__visible = false
  notify(main)
  tick(); tick(2.5)
  st = T.state(main.Map_World)
  local who = st.entries["OC_STT_Diego"]
  check(who.label.vis == 3 and who.label.tex.__valid ~= false, "(a name is shown)")
  local gone = who.label.tex
  gone.__valid = false                      -- its picture is destroyed
  local refuse = true
  local function mine(img) return refuse and img == who.label end
  if how == "the call raises" then H.brushFail = mine else H.brushSilent = mine end
  local failed0 = T.pictures().bindFailed
  tick(2.5)
  check(who.label.vis ~= 3 and who.label.tex == gone and T.pictures().bindFailed == failed0 + 1 and (allShownHavePictures(main.Map_World)),
    ("its picture is gone and %s: the name is hidden, not shown with what it had (visibility %s)"):format(how, tostring(who.label.vis)))
  tick(2.5)
  check(who.label.vis ~= 3 and (allShownHavePictures(main.Map_World)), "and stays hidden while that goes on")
  refuse = false
  tick(2.5); tick(2.5)
  check(who.label.vis == 3 and who.label.tex ~= gone and who.label.tex.__valid ~= false and (allShownHavePictures(main.Map_World)), "the image takes the picture again: the name is back")
  H.brushFail, H.brushSilent = nil, nil
end

-- ================================================================ a picture file that is not there
say("pictures: a picture file that cannot be loaded")
do
  local dir = X.modCopy("p_missing", X.list12 .. "\nC.WorldPools = false")
  reset()
  F = FK.new()
  T = load(dir, F)
  -- the kind of pin most of the twelve people have
  local kinds = { teacher = "pin_teacher.png", trader = "pin_merchant.png", both = "pin_both.png" }
  local byFile = {}
  for _, def in ipairs(T.npcs) do
    local file = kinds[def.kind] or (def.orc and "pin_orc.png") or "pin_other.png"
    byFile[file] = (byFile[file] or 0) + 1
  end
  local file, n = nil, 0
  for f, c in pairs(byFile) do if c > n or (c == n and f < file) then file, n = f, c end end
  os.remove(dir .. "Assets/Pins/" .. file)
  os.remove(dir .. "Assets/Drawn/Pins/" .. file)        -- (the drawn look falls back to the classic picture, which is gone too)
  main = newMain("MainMissing", nil, nil, FIX.expect.ocA.__player)
  main.Map_Area.__visible = false
  local logs0 = #H.logs
  notify(main)
  tick(); tick(2.5)
  local function said()
    local c = 0
    for i = logs0 + 1, #H.logs do if H.logs[i]:find("Could not load image Assets/Pins/" .. file, 1, true) then c = c + 1 end end
    return c
  end
  check(n >= 1 and n < 12 and pins(T, main.Map_World) == 12 - n and (allShownHavePictures(main.Map_World)) and said() == 1,
    ("%s cannot be loaded: the %d people with that pin get none, the others theirs; said once"):format(file, n))
  -- loading it is tried again after 30 seconds, not before
  local t0 = H.now
  imports0 = H.imports
  local tries, at = 0, {}
  for i = 1, 26 do
    tick(2.5)
    if H.imports > imports0 then
      tries = tries + (H.imports - imports0)
      at[#at + 1] = ("%.1f"):format(H.now - t0)
      imports0 = H.imports
    end
  end
  check(tries == 2 and said() == 1 and pins(T, main.Map_World) == 12 - n, ("it is tried again every 30 seconds, not at every refresh (tries at +%s s), and not said again"):format(table.concat(at, ", +")))
  check(tostring(F.value("markers.textures")):find("^%d+ loaded, 1 failed$") ~= nil, "noted: " .. tostring(F.value("markers.textures")))
end

-- ================================================================ no player controller yet
say("pictures: without a player controller nothing is loaded, and nothing is marked as failed")
do
  reset()
  local have = false
  local kitLate = { keepAlive = function() return true end, controller = function() if have then return X.Ctrl end return nil end }
  H.findAllBy = {}
  T = load(X.DIR12, nil, kitLate)
  main = newMain("MainNoCtrl", nil, nil, FIX.expect.ocA.__player)
  main.Map_Area.__visible = false
  local logs0 = #H.logs
  imports0 = H.imports
  notify(main)
  tick(); tick(2.5); tick(2.5)
  local complaints = 0
  for i = logs0 + 1, #H.logs do if H.logs[i]:find("Could not load image", 1, true) then complaints = complaints + 1 end end
  check(pins(T, main.Map_World) == 0 and H.imports == imports0 and complaints == 0 and (H.findAllBy["GothicPlayerControllerBaseBP_C"] or 0) == 0
    and (H.findAllBy["PlayerController"] or 0) == 0,
    "the kit has no player controller: no picture is loaded, none is said to be missing, and the controller is not searched for from here")
  have = true
  tick(2.5); tick(2.5)
  check(pins(T, main.Map_World) == 12 and (allShownHavePictures(main.Map_World)), "the controller is there: the pins are made at the next refreshes (no half minute of waiting)")
end

-- ================================================================ a map load that is never reported as over
say("markers: while a map loads nothing is touched; a load that never reports its end counts as over after 30 seconds")
do
  reset()
  T = load(X.DIR12)
  main = newMain("MainLoading", nil, nil, FIX.expect.ocA.__player)
  main.Map_Area.__visible = false
  H.pre()                                   -- a map load begins ...
  notify(main)
  for _ = 1, 11 do tick(2.5) end            -- ... and for 27.5 seconds nothing says that it is over
  check(ourPanel(main.Map_World) == nil and #images(main.Map_World) == 0, "27.5 seconds into a map load: the map screen that was announced is not touched")
  tick(2.5)
  tick()
  check(ourPanel(main.Map_World) ~= nil and pins(T, main.Map_World) == 12, "30 seconds: the load counts as over, the pins are made")
  H.post()
  -- a UE4SS without the hook after a map load: nothing would ever end the wait, so there is none
  local post = _G.RegisterLoadMapPostHook
  _G.RegisterLoadMapPostHook = nil
  reset()
  T = load(X.DIR12)
  _G.RegisterLoadMapPostHook = post
  main = newMain("MainNoPost", nil, nil, FIX.expect.ocA.__player)
  main.Map_Area.__visible = false
  H.pre()
  notify(main)
  tick(); tick()
  check(pins(T, main.Map_World) == 12, "a UE4SS without the hook after a map load: the mod does not wait after one")
  T = load(X.DIR12)       -- (the following scenarios run with both hooks again)
  reset()
end

-- ================================================================ a UE4SS without the game-thread loop
say("markers: a UE4SS without LoopInGameThreadWithDelay")
do
  local loop = _G.LoopInGameThreadWithDelay
  _G.LoopInGameThreadWithDelay = nil
  _G.NPCMARKERS_TEST = {}
  local logs0 = #H.logs
  X.quiet(true)
  local okLoad, errLoad = pcall(dofile, X.DIR12 .. "main.lua")
  X.quiet(false)
  _G.LoopInGameThreadWithDelay = loop
  local fatal = 0
  for i = #H.logs, logs0 + 1, -1 do
    if H.logs[i]:find("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; markers disabled.", 1, true) then fatal = fatal + 1 end
  end
  check(okLoad and fatal == 1, "the mod says that it cannot run and does not raise (" .. tostring(errLoad) .. ")")
  T = load(X.DIR12)
  reset()
end

-- ================================================================ the pictures of the pools
say("pictures: every pool size has its picture")
do
  T = load(X.DIR12)
  local missing = {}
  local function there(rel)
    local f = io.open(X.DIR12 .. rel, "rb")
    if f then f:close() end
    return f ~= nil
  end
  for size = 2, 99 do
    local rel = T.poolImage(size)
    if rel ~= ("Assets/Drawn/Pools/pool_%d.png"):format(size) or not there(rel) or not there(("Assets/Pools/pool_%d.png"):format(size)) then missing[#missing + 1] = size end
  end
  check(#missing == 0, "pools of 2 to 99 people: a picture with their number, drawn (the default look) and classic (" .. table.concat(missing, ", ") .. ")")
  check(T.poolImage(100) == "Assets/Drawn/Pools/pool_more.png" and T.poolImage(181) == "Assets/Drawn/Pools/pool_more.png" and there("Assets/Drawn/Pools/pool_more.png")
    and there("Assets/Pools/pool_more.png"), "more than 99: the picture for 'more'")
  reset()
end

-- ================================================================ the game's own lookup of a person, after a map load
say("markers: once the game's lookup of a person has worked, a person it does not know is not searched for among all objects")
do
  reset()
  T = load(X.DIR12)
  main = newMain("MainLookup", nil, nil, FIX.expect.ocA.__player)
  main.Map_Area.__visible = false
  notify(main)
  tick(); tick(2.5)
  check(pins(T, main.Map_World) == 12, "(12 people found by the game's lookup)")
  H.findAllBy = {}
  -- a map load; in the new world the game does not know any of the twelve yet
  H.pre(); H.post()
  for _, def in ipairs(T.npcs) do H.npcMode[def.id] = "missing" end
  main2 = newMain("MainLookup2", nil, nil, FIX.expect.ocA.__player)
  main2.Map_Area.__visible = false
  notify(main2)
  for _ = 1, 6 do tick(2.5) end
  check((H.findAllBy["GothicNPCState"] or 0) == 0 and (H.findAllBy["GothicCharacterState"] or 0) == 0,
    "after a map load the lookup answers for nobody: no search among all objects is made for them (the lookup has worked in this run)")
  for _, def in ipairs(T.npcs) do H.npcMode[def.id] = nil end
  for _ = 1, 6 do tick(2.5) end
  check(pins(T, main2.Map_World) == 12, "they are in the world again: found by the lookup, pins made")
  reset()
end

-- ================================================================ a new screen before the old one was seen gone
say("pictures: a map screen is closed and a new one made at its address within one update")
do
  -- the same, on a new screen, as the scenario "a new map screen at the address and under the name of the old one" - but
  -- no update of the mod falls between the two screens (how = "announced"), or the screens are found by a search
  -- (how = "searched for": a UE4SS without announcements)
  local function sameAddress(how)
    reset()
    T = load(X.DIR12, nil, nil, how == "searched for" and "none" or nil)
    main = newMain("MainQuick", nil, nil, FIX.expect.ocA.__player)
    main.Map_Area.__visible = false
    if how == "announced" then notify(main) else X.registry["W_Map_Main_C"] = { main } end
    tick(); tick(2.5); tick(2.5)
    local stOld, panelOld, worldOld = T.state(main.Map_World), ourPanel(main.Map_World), main.Map_World
    check(stOld ~= nil and pins(T, worldOld) == 12, ("(%s: the first screen has its 12 pins)"):format(how))
    touched = 0
    kill(worldOld.__general); kill(main.__content); kill(main.Map_Area); kill(worldOld); kill(main)
    main2 = newMain("MainQuick", nil, nil, FIX.expect.ocA.__player)
    main2.__addr, main2.Map_World.__addr, main2.Map_Area.__addr = main.__addr, worldOld.__addr, main.Map_Area.__addr
    main2.Map_Area.__visible = false
    if how == "announced" then
      notify(main2)                         -- (no update since the old screen went)
      for _ = 1, 20 do tick() end
    else
      X.registry["W_Map_Main_C"] = { main2 }
      for _ = 1, 16 do tick(2.5) end        -- (the next searches: 10 and 30 seconds after the first update)
    end
    X.registry["W_Map_Main_C"] = nil
    local stNew = T.state(main2.Map_World)
    local onNew = 0
    for _, e in pairs(stNew and stNew.entries or {}) do if e.pin.__parent == ourPanel(main2.Map_World) then onNew = onNew + 1 end end
    check(stNew ~= nil and stNew ~= stOld and ourPanel(main2.Map_World) ~= nil and ourPanel(main2.Map_World) ~= panelOld and onNew == 12 and touched == 0,
      ("%s: the new screen gets a state of its own - 12 pins in its own canvas, nothing of the old screen is touched (%d on it, %d calls)")
        :format(how, onNew, touched))
    check(#X.legendsOf(main2) == 1, "and its own colour key")
  end
  sameAddress("announced")
  sameAddress("searched for")
  T = load(X.DIR12)
  reset()
end

-- ================================================================ the class's default object is not a map screen
say("markers: the default object of the map screen's class is not a map screen")
do
  for _, how in ipairs({ "announced", "searched for" }) do
    reset()
    T = load(X.DIR12, nil, nil, how == "searched for" and "none" or nil)
    local cdo = newMain("Default__W_Map_Main_C", nil, nil, FIX.expect.ocA.__player)
    cdo.Map_Area.__visible = false
    main = newMain("MainReal", nil, nil, FIX.expect.ocA.__player)
    main.Map_Area.__visible = false
    if how == "announced" then notify(cdo); notify(main) else X.registry["W_Map_Main_C"] = { cdo, main } end
    tick(); tick(2.5); tick(2.5)
    X.registry["W_Map_Main_C"] = nil
    check(ourPanel(cdo.Map_World) == nil and T.state(cdo.Map_World) == nil and #X.legendsOf(cdo) == 0 and pins(T, main.Map_World) == 12,
      ("%s together with a screen: nothing is made on the default object, the screen has its pins"):format(how))
  end
  -- a screen that is announced and gone again before the mod's next update: only asked whether it is still there
  reset()
  T = load(X.DIR12)
  local gone = newMain("MainGone", nil, nil, FIX.expect.ocA.__player)
  local asked = 0
  gone.__valid = false
  gone.GetFullName = function() asked = asked + 1; return "W_Map_Main_C /Engine/Transient.MainGone" end
  gone.GetAddress = function() asked = asked + 1; return gone.__addr end
  local _, _, screens0 = T.pictures()
  notify(gone)
  tick(); tick(2.5)
  local _, _, screens1 = T.pictures()
  check(asked == 0 and screens1 == screens0 and ourPanel(gone.Map_World) == nil,
    ("a screen that is gone before the next update: neither its name nor its address is asked for, and it does not count as a new screen (%d calls)"):format(asked))
  T = load(X.DIR12)
  reset()
end

-- ================================================================ no loader for picture files
say("pictures: the engine's loader for picture files is not found")
do
  reset()
  H.noPictureLoader, H.loaderLookups = true, 0
  T = load(X.DIR12)
  main = newMain("MainNoLoader", nil, nil, FIX.expect.ocA.__player)
  main.Map_Area.__visible = false
  local logs0 = #H.logs
  imports0 = H.imports
  notify(main)
  for _ = 1, 14 do tick(2.5) end
  local said, complaints = 0, 0
  for i = logs0 + 1, #H.logs do
    if H.logs[i]:find("loader for picture files (KismetRenderingLibrary) was not found: no pins can be shown", 1, true) then said = said + 1 end
    if H.logs[i]:find("Could not load image", 1, true) or H.logs[i]:find("Update error", 1, true) then complaints = complaints + 1 end
  end
  check(pins(T, main.Map_World) == 0 and #images(main.Map_World) == 0 and H.imports == imports0,
    "no pin is made and no image without a picture is put on the map")
  check(said == 1 and complaints == 0 and H.loaderLookups == 1,
    ("the mod says so once, names no single picture as missing and looks for the loader once (said %d times, %d other lines, %d lookups)"):format(said, complaints, H.loaderLookups))
  H.noPictureLoader = nil
  T = load(X.DIR12)
  reset()
end

-- ================================================================ a player controller without a world
say("pictures: a player controller that has no world yet")
do
  reset()
  T = load(X.DIR12)
  main = newMain("MainNoWorld", nil, nil, FIX.expect.ocA.__player)
  main.Map_Area.__visible = false
  local getWorld = X.Ctrl.GetWorld
  X.Ctrl.GetWorld = function() return nil end
  local logs0 = #H.logs
  imports0 = H.imports
  notify(main)
  tick(); tick(2.5); tick(2.5)
  local complaints = 0
  for i = logs0 + 1, #H.logs do if H.logs[i]:find("Could not load image", 1, true) then complaints = complaints + 1 end end
  check(pins(T, main.Map_World) == 0 and H.imports == imports0 and complaints == 0, "no picture is loaded and none is said to be missing")
  X.Ctrl.GetWorld = getWorld
  tick(2.5); tick(2.5)
  check(pins(T, main.Map_World) == 12 and (allShownHavePictures(main.Map_World)), "the world is there: the pins are made at the next refreshes (no half minute of waiting)")
  reset()
end

-- ================================================================ the letters of the names, the look of the pictures
say("pictures: the names in the game's letters, or in blackletter when NameLetters says so; the drawn look")
do
  local ids = {}
  for id in pairs(FIX.live) do ids[#ids + 1] = id end
  table.sort(ids)
  local function shownNames()
    local n, gothic, plain, sized = 0, 0, 0, 0
    local st = T.state(main.Map_World)
    for _, e in pairs(st and st.entries or {}) do
      local path = e.label and e.label.vis == 3 and e.label.tex and e.label.tex.__path
      if path then
        n = n + 1
        if path:find("/LabelsGothic/", 1, true) then gothic = gothic + 1 elseif path:find("/Labels/", 1, true) then plain = plain + 1 end
        if e.labelW == e.label.tex.Blueprint_GetSizeX() and e.labelH == e.label.tex.Blueprint_GetSizeY() then sized = sized + 1 end
      end
    end
    return n, gothic, plain, sized
  end
  local function showAll(dir, name, kit)
    reset()
    T = load(dir, nil, kit)
    main = newMain(name, nil, nil, FIX.expect.ocA.__player)
    main.Map_Area.__visible = false
    notify(main)
    for _ = 1, 4 do tick(2.5) end
  end
  local ALWAYS = X.list12 .. "\nC.WorldPools = false; C.AreaLabels = 'always'; C.WorldLabels = 'always'"
  -- by default the game's letters, whatever the megamod's letters are
  showAll(X.modCopy("p_letters", ALWAYS), "MainLetters", { letters = function() return "gothic" end })
  local n, gothic, plain, sized = shownNames()
  check(n == 12 and gothic == 0 and plain == 12 and sized == 12,
    ("the names on the map in the game's letters (the plain pictures), also while the megamod's letters are gothic (%d %d %d %d)"):format(n, gothic, plain, sized))
  -- NameLetters = gothic: the blackletter pictures
  local dir = X.modCopy("p_letters_g", ALWAYS .. "; C.NameLetters = 'gothic'")
  os.remove(dir .. "Assets/LabelsGothic/" .. ids[1] .. ".png")         -- one person without a blackletter picture
  showAll(dir, "MainLetters2", nil)
  n, gothic, plain, sized = shownNames()
  check(n == 12 and gothic == 11 and plain == 1 and sized == 12,
    ("NameLetters = gothic: eleven names in their blackletter pictures, the one without such a picture in the plain one, each at its picture's size (%d %d %d %d)"):format(n, gothic, plain, sized))
  -- the drawn look: a picture of Assets/Drawn where there is one, else the classic one
  local function drawnCopy(name, extra)
    local d = X.modCopy(name, ALWAYS .. (extra or ""))
    os.execute("rm -rf '" .. d .. "Assets/Drawn' && mkdir -p '" .. d .. "Assets/Drawn/Pins' '" .. d .. "Assets/Drawn/Labels'")
    os.execute("cp '" .. d .. "Assets/Pins/pin_teacher.png' '" .. d .. "Assets/Drawn/Pins/pin_teacher.png'")
    for i = 1, 3 do os.execute("cp '" .. d .. "Assets/Labels/" .. ids[i] .. ".png' '" .. d .. "Assets/Drawn/Labels/" .. ids[i] .. ".png'") end
    return d
  end
  local function looks()
    local drawnPins, classicPins, drawnNames = 0, 0, 0
    local st = T.state(main.Map_World)
    for _, e in pairs(st and st.entries or {}) do
      local p = e.pin and e.pin.tex and e.pin.tex.__path
      if p then if p:find("/Drawn/Pins/", 1, true) then drawnPins = drawnPins + 1 elseif p:find("/Pins/", 1, true) then classicPins = classicPins + 1 end end
      local l = e.label and e.label.vis == 3 and e.label.tex and e.label.tex.__path
      if l and l:find("/Drawn/Labels/", 1, true) then drawnNames = drawnNames + 1 end
    end
    return drawnPins, classicPins, drawnNames
  end
  showAll(drawnCopy("p_drawn"), "MainDrawn", nil)
  local dp, cp, dn = looks()
  check(dp + cp == 12 and dp >= 1 and cp >= 1 and dn == 3,
    ("the drawn look (the default): the pictures of Assets/Drawn where there are some, the classic ones else (%d drawn pins, %d classic, %d drawn names)"):format(dp, cp, dn))
  showAll(drawnCopy("p_classic", "; C.PinLook = 'classic'"), "MainClassic", nil)
  dp, cp, dn = looks()
  check(dp == 0 and cp == 12 and dn == 0, ("PinLook = classic: the classic pictures only (%d %d %d)"):format(dp, cp, dn))
  reset()
end

-- the scenarios above make pins fail on purpose: the mod's line about it is expected here, and only here
do
  local expected, kept = 0, {}
  for i, line in ipairs(H.logs) do
    if i > logsAtStart and line:find("could not be created %(see image errors above%)") then expected = expected + 1 else kept[#kept + 1] = line end
  end
  check(expected >= 1, ("pins that could not be made are said in the log (%d lines)"):format(expected))
  for i = #H.logs, 1, -1 do H.logs[i] = nil end
  for i, line in ipairs(kept) do H.logs[i] = line end
end
