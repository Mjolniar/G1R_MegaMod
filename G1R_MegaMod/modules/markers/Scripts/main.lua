-- ============================================================================
-- NPCMarkers 2.4 for Gothic 1 Remake (UE4SS Lua)
--
-- Rebuilt locally from the "Active NPCMarkers" idea (Nexus mod 270) using
-- facts recovered with the GORE toolkit and the game's own executable:
--   * pins follow each NPC's live AGothicNPCState position
--     (AGothicNPCState::FindNPCByUniqueName + GetCharacterLocation)
--   * positions are projected exactly like the game projects the player
--     marker: bounding-box inverse transform, then the per-map correction
--     texture (see projection.lua)
--   * world map AND camp/area maps each use their own box + correction
--   * pins and labels live in a separate canvas owned by this mod, so the
--     game's own custom-marker logic and hover animations never touch them
--   * every named NPC of the game is listed (npcs.lua, generated from the
--     game's character definitions, localization and glossary)
--   * world map: people standing close together are drawn as one "pool"
--     (a badge with their number); hovering it lists everyone there
--
-- Design limits: one persistent game-thread loop, one NotifyOnNewObject
-- registration, no per-action ExecuteWithDelay callbacks, every Unreal call
-- wrapped in pcall, widgets created lazily with a per-tick budget.
--
-- 2.4: what an image shows is settled at every step.
--   * The pictures the mod loads are kept alive for the whole run where that
--     can be had (the megamod's kit puts them on the game instance's list of
--     referenced objects), so a kept picture cannot have been destroyed.
--     Without it a picture belongs to the map screen it was loaded for.
--   * A picture counts as shown by an image only when the call that sets it
--     went through; an image that does not take its picture is not shown
--     (2.3 could leave a white box, and went on as if all were well).
--   * Every image remembers which loading of its picture it shows and takes
--     the current one when that has changed.
--   * The names of the people under the mouse are made within the same
--     budget of new images per update as everything else.
--   * A person's state object is asked from the game at every refresh and
--     not kept.
-- ============================================================================

local MOD = "NPCMarkers"
local VERSION = "2.7.0"

local print, pairs, ipairs, pcall, type, tostring, tonumber = print, pairs, ipairs, pcall, type, tostring, tonumber
local math, string, table, os = math, string, table, os

local function log(msg) print("[" .. MOD .. "] " .. tostring(msg) .. "\n") end
local Logged = {}

-- Diagnostics handle of the megamod loader; nil when the mod runs on its own,
-- and then nothing behind `if DIAG` runs. It only records what the mod sees.
local DIAG = G1R_DIAG
-- The megamod's shared helpers (nil when the mod runs on its own): the engine's
-- own way to the player controller, and a way to keep objects alive.
local KIT = G1R_KIT
-- An operation that touches the game is announced before it runs and taken
-- back when it has returned (megamod diagnostics; nothing without them).
local function opBegin(text)
    if DIAG and DIAG.op then return DIAG.op(text) end
    return nil
end
local function opEnd(token)
    if token ~= nil and DIAG and DIAG.done then DIAG.done(token) end
end
-- What the diagnostics remember: the facts noted so far (also shown in the
-- dump) and the cheap values that tell whether a fact changed.
local Obs = { facts = {}, details = {}, canvas = {}, texGen = 0, texNoted = 0, texAt = 0 }
-- A fact is passed on when it is new or changed (only called behind `if DIAG`).
function Obs.note(key, value, detail)
    if Obs.facts[key] == value and Obs.details[key] == detail then return end
    Obs.facts[key], Obs.details[key] = value, detail
    DIAG.note(key, value, detail)
end
if DIAG then pcall(DIAG.version, VERSION) end
local function logOnce(key, msg)
    if Logged[key] then return end
    Logged[key] = true
    log(msg)
end
-- Runtime errors: each distinct message once, at most 10 per session.
local ErrorCount = 0
local function logError(key, msg)
    if Logged[key] or ErrorCount >= 10 then return end
    ErrorCount = ErrorCount + 1
    logOnce(key, msg .. (ErrorCount == 10 and " (further errors suppressed)" or ""))
end

-- ---------------------------------------------------------------------------
-- Paths, config, projection module, NPC list
-- ---------------------------------------------------------------------------
local SCRIPT_DIR = (function()
    local ok, src = pcall(function() return debug.getinfo(1, "S").source end)
    if ok and type(src) == "string" then
        local p = src:gsub("^@", ""):gsub("\\", "/")
        local d = p:match("^(.*/)[^/]+$")
        if d then return d end
    end
    return "./"
end)()

local okP, Proj = pcall(dofile, SCRIPT_DIR .. "projection.lua")
if not okP or type(Proj) ~= "table" then
    log("FATAL: projection.lua failed to load: " .. tostring(Proj))
    return
end

local okC, Config = pcall(dofile, SCRIPT_DIR .. "config.lua")
if not okC or type(Config) ~= "table" then
    log("config.lua failed to load (" .. tostring(Config) .. "); using defaults")
    Config = {}
end
local function cfg(key, default)
    local v = Config[key]
    if v == nil then return default end
    if type(default) == "number" then return tonumber(v) or default end
    return v
end

-- Label modes: "always" (every label, stacked when crowded), "auto" (labels
-- that fit without covering other labels or pins; the rest on hover),
-- "hover" (names only while the mouse is over a pin), "off".
local function modeOf(v, default)
    v = tostring(v == nil and default or v):lower()
    if v ~= "always" and v ~= "auto" and v ~= "hover" and v ~= "off" then v = default end
    return v
end
local AreaLabels = modeOf(Config.AreaLabels, "auto")
local WorldLabels = modeOf(Config.WorldLabels, "hover")

local KIND_ALIASES = { merchant = "trader", trade = "trader", teach = "teacher" }
local function loadNpcList()
    local list, source
    if type(Config.NPCs) == "table" then
        list, source = Config.NPCs, "config.lua"
    else
        local ok, data = pcall(dofile, SCRIPT_DIR .. "npcs.lua")
        if ok and type(data) == "table" then
            list, source = data, "npcs.lua"
        else
            log("npcs.lua failed to load (" .. tostring(data) .. "); only ExtraNPCs will be shown.")
            list, source = {}, "none"
        end
    end
    local hide = {}
    if type(Config.HideIds) == "table" then
        for _, id in ipairs(Config.HideIds) do hide[tostring(id):lower()] = true end
    end
    local showOthers = cfg("ShowOtherNPCs", true) ~= false
    local showOrcs = cfg("ShowOrcs", true) ~= false
    local out, seen = {}, {}
    local function add(def)
        if type(def) ~= "table" or type(def.id) ~= "string" or def.id == "" then return end
        local key = def.id:lower()
        if seen[key] or hide[key] then return end
        local kind = tostring(def.kind or "other"):lower()
        kind = KIND_ALIASES[kind] or kind
        local important = (kind == "teacher" or kind == "trader" or kind == "both")
        if not important and not showOthers then return end
        if def.orc == true and not showOrcs then return end
        seen[key] = true
        out[#out + 1] = {
            id = def.id, name = def.name or def.id, kind = kind, orc = def.orc == true,
            important = important, label = def.label, fallback = def.fallback, area = def.area,
        }
    end
    for _, d in ipairs(list) do add(d) end
    if type(Config.ExtraNPCs) == "table" then
        for _, d in ipairs(Config.ExtraNPCs) do add(d) end
    end
    -- teachers / traders first: their pins and labels get placed first
    local important, others = {}, {}
    for _, d in ipairs(out) do
        if d.important then important[#important + 1] = d else others[#others + 1] = d end
    end
    for _, d in ipairs(others) do important[#important + 1] = d end
    return important, source
end
local NPCs, NpcSource = loadNpcList()
local ImportantCount = 0
for _, d in ipairs(NPCs) do if d.important then ImportantCount = ImportantCount + 1 end end

-- Map tag -> bundled correction data (exported from the game's
-- *_CorrectionTexture assets with GORE; identical bytes to the cooked mips).
local TAG_CORRECTION = {
    ["Area"] = "Overworld",
    ["Area.OldCamp"] = "OldCamp",
    ["Area.NewCamp"] = "NewCamp",
    ["Area.SwampCamp"] = "SwampCamp",
    ["Area.OrcEnclave"] = "OrcCamp",
    ["Area.SleeperTemple"] = "SleepersTemple",
}
local CorrectionCache = {}
local function correctionFor(tag)
    local name = TAG_CORRECTION[tag]
    if not name then return nil end
    local c = CorrectionCache[name]
    if c == nil then
        local data, err = Proj.LoadCorrection(SCRIPT_DIR .. "data/corr_" .. name .. ".bin")
        if not data then
            logOnce("corr:" .. name, "Correction data for " .. name .. " unavailable: " .. tostring(err))
            data = false
        end
        CorrectionCache[name] = data
        c = data
    end
    return c or nil
end

-- ---------------------------------------------------------------------------
-- Unreal helpers (all guarded)
-- ---------------------------------------------------------------------------
local function isValidOf(o) return o:IsValid() end
local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(isValidOf, o)
    return ok and v == true
end
-- An object wrapper is a pointer, and UE4SS reads the object's memory on every
-- member access without asking whether the object still exists (the game
-- destroys the map screen and its widgets when it likes). So a wrapper is
-- asked first: true when its object is gone. Wrappers without IsValid, or
-- with an always-true one (structs, arrays, parameters), pass.
local function gone(o)
    local ok, v = pcall(isValidOf, o)
    return ok and v == false
end
local function get(o, key)
    if o == nil or gone(o) then return nil end
    local ok, v = pcall(function() return o[key] end)
    if ok then return v end
    return nil
end
local function call(o, fn, ...)
    if o == nil or gone(o) then return nil end
    local args = { ... }
    local ok, v = pcall(function() return o[fn](o, table.unpack(args)) end)
    if ok then return v end
    return nil
end
-- A method of a kept widget or slot, result not needed: nothing is touched
-- when the object is gone.
local function invoke(o, fn, ...) return o[fn](o, ...) end
local function wcall(o, fn, ...)
    if o == nil or gone(o) then return false end
    return pcall(invoke, o, fn, ...)
end
local function callBool(o, fn, ...)
    local v = call(o, fn, ...)
    if type(v) == "boolean" then return v end
    return nil
end
local function addrOf(o)
    local ok, v = pcall(function() return tostring(o:GetAddress()) end)
    return ok and v or tostring(o)
end
local function fullName(o)
    if o == nil or gone(o) then return "?" end
    local ok, v = pcall(function() return o:GetFullName() end)
    return ok and v or "?"
end
local function shortName(o)
    local n = fullName(o)
    return n:match("([^%.:]+)$") or n
end
local function num(v)
    if type(v) == "number" then return v end
    return tonumber(v)
end
local function vec3(v)
    if v == nil then return nil end
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    if ok then
        x, y, z = num(x), num(y), num(z)
        if x and y and z then return x, y, z end
    end
    return nil
end
local function vec2(v)
    if v == nil then return nil end
    local ok, x, y = pcall(function() return v.X, v.Y end)
    if ok then
        x, y = num(x), num(y)
        if x and y then return x, y end
    end
    return nil
end
local function tagString(tag)
    if tag == nil then return nil end
    local ok, s = pcall(function() return tag.TagName:ToString() end)
    if ok and type(s) == "string" then return s end
    return nil
end
local function findStatic(path)
    local ok, o = pcall(StaticFindObject, path)
    if ok and valid(o) then return o end
    return nil
end
-- Engine / game objects that exist for the whole run (classes, class default
-- objects): searched for once per path, found or not. In this UE4SS build a
-- search that is not answered from its cache walks every object in memory.
local StaticOnce = {}
local function findStaticOnce(path)
    local o = StaticOnce[path]
    if o == false then return nil end
    if o ~= nil and valid(o) then return o end
    -- such a search can walk every object in memory: with the megamod loader
    -- a line goes to disk first
    if DIAG then DIAG.crumb("findStaticOnce " .. tostring(path)) end
    o = findStatic(path)
    StaticOnce[path] = o or false
    return o
end
local function findAll(className)
    local ok, list = pcall(FindAllOf, className)
    if ok and type(list) == "table" then return list end
    return {}
end

local CachedController
local function getController()
    -- the megamod's kit asks the engine (no search among all objects, nothing kept for long);
    -- where the kit has none, there is none to be searched for from here
    if KIT and type(KIT.controller) == "function" then
        local ok, c = pcall(KIT.controller)
        if ok and valid(c) then return c end
        return nil
    end
    if valid(CachedController) then return CachedController end
    for _, cls in ipairs({ "GothicPlayerControllerBaseBP_C", "PlayerController" }) do
        local list = findAll(cls)
        for i = #list, 1, -1 do
            local c = list[i]
            if valid(c) and not fullName(c):find("Default__", 1, true) then
                CachedController = c
                return c
            end
        end
    end
    return nil
end
local function getPawn(ctrl)
    local p = call(ctrl, "K2_GetPawn")
    if valid(p) then return p end
    p = get(ctrl, "Pawn")
    if valid(p) then return p end
    return nil
end

-- ---------------------------------------------------------------------------
-- Textures (PNG files; failed imports are retried after 30 s, not every
-- refresh)
--
-- An imported picture is an object of the game that nothing refers to: the
-- game destroys it when no image shows it any more. A Lua variable does not
-- keep it, and a kept variable cannot always tell that its object is gone
-- (dev/FACTS.md, U17). So:
--   * with the megamod's kit every picture is put on the game instance's list
--     of referenced objects when it is loaded. It then lives as long as the
--     game runs, and the record here is good for the whole run.
--   * without it (the mod on its own, or the list cannot be written) a record
--     is used only for the map screen it was loaded for, and only while its
--     object says it is valid and still has its name.
-- Every loading gets a number (`serial`). An image remembers the number of
-- the loading it shows; when the record of its file carries another number,
-- the image is given the new picture before it is shown again.
-- ---------------------------------------------------------------------------
local Textures, TextureFail = {}, {}
local TexSerial = 0             -- counts loadings
local ScreenGen = 0             -- counts map screens (pictures that are not kept alive belong to one)
local Tex = { loaded = 0, kept = 0, again = 0, bindFailed = 0, rebound = 0, checked = 0 }
local KeepNoted = nil           -- diagnostics: how pictures are kept, as last noted
local function keepAlive(tex)
    if not (KIT and type(KIT.keepAlive) == "function") then return false end
    local ok, held = pcall(KIT.keepAlive, tex)
    return ok and held == true
end
-- Is the record still the picture it was? (asked once per update at most)
local function usable(t, now)
    if t.okAt == now then return true end
    local ok
    if t.held then
        ok = valid(t.tex)       -- (it cannot have been destroyed: this only guards against the unexpected)
    else
        ok = t.gen == ScreenGen and valid(t.tex) and fullName(t.tex) == t.full
        if ok and keepAlive(t.tex) then t.held = true; Tex.kept = Tex.kept + 1 end
    end
    if ok then t.okAt = now end
    return ok
end
-- The record of a file when it is loaded and usable, without loading anything.
local function cachedTexture(rel, now)
    local t = Textures[rel]
    if t and usable(t, now) then return t end
    return nil
end
local function loadTexture(rel, now)
    local t = Textures[rel]
    if t then
        if usable(t, now) then return t end
        Textures[rel] = nil     -- its object is gone: loaded again below, under a new number
        Tex.again = Tex.again + 1
    end
    if TextureFail[rel] and now - TextureFail[rel] < 30.0 then return nil end
    local lib = findStaticOnce("/Script/Engine.Default__KismetRenderingLibrary")
    if not lib then
        logOnce("tex:loader", "The engine's loader for picture files (KismetRenderingLibrary) was not found: no pins can be shown")
        return nil
    end
    local ctrl = getController()
    if not ctrl then return nil end
    local world = call(ctrl, "GetWorld")
    if not valid(world) then return nil end
    local path = SCRIPT_DIR .. rel
    local ok, tex = pcall(function() return lib:ImportFileAsTexture2D(world, path) end)
    if not ok or not valid(tex) then
        TextureFail[rel] = now
        if DIAG then Obs.texGen, Obs.texAt = Obs.texGen + 1, now end
        logOnce("tex:" .. rel, "Could not load image " .. rel .. " (" .. tostring(tex) .. ")")
        return nil
    end
    local w = num(call(tex, "Blueprint_GetSizeX")) or 64
    local h = num(call(tex, "Blueprint_GetSizeY")) or 64
    TexSerial = TexSerial + 1
    t = { tex = tex, w = w, h = h, rel = rel, serial = TexSerial, gen = ScreenGen, full = fullName(tex), held = keepAlive(tex), okAt = now }
    Tex.loaded = Tex.loaded + 1
    if t.held then Tex.kept = Tex.kept + 1 end
    Textures[rel] = t
    TextureFail[rel] = nil
    if DIAG then
        Obs.texGen, Obs.texAt = Obs.texGen + 1, now
        local how = t.held and "for the whole run (the game instance refers to them)" or "per map screen"
        if how ~= KeepNoted then
            KeepNoted = how
            Obs.note("markers.textures_kept", how)
        end
    end
    return t
end
-- Shows a picture in an image. The game's function has no result: the picture
-- counts as shown when the call went through. Where this UE4SS build hands
-- out an image's brush, the brush is read back as well - for the first images
-- of a run, and for every picture that is not kept alive - and must name this
-- picture. That check only counts once it has been seen to work (a brush that
-- named the picture just set); until then it decides nothing.
local BRUSH_CHECKS = 8
local BrushReadable = nil       -- learned: true = a brush was read back and named its picture; false = it cannot be had
local function bind(img, t)
    if not wcall(img, "SetBrushFromTexture", t.tex, false) then
        Tex.bindFailed = Tex.bindFailed + 1
        return false
    end
    if BrushReadable == false or (BrushReadable and t.held and Tex.checked >= BRUSH_CHECKS) then return true end
    Tex.checked = Tex.checked + 1
    local shown = get(get(img, "Brush"), "ResourceObject")
    local names = shown ~= nil and valid(shown) and addrOf(shown) == addrOf(t.tex)
    if names then
        if not BrushReadable then
            BrushReadable = true
            if DIAG then Obs.note("markers.image_binding", "read back from the image's brush") end
        end
        return true
    end
    if BrushReadable then
        Tex.bindFailed = Tex.bindFailed + 1      -- the brush names something else, or nothing: the image would be a white box
        return false
    end
    if Tex.checked >= BRUSH_CHECKS then
        BrushReadable = false
        if DIAG then Obs.note("markers.image_binding", "taken from the call (the brush cannot be read back)") end
    end
    return true
end
-- Makes sure the image shows the record `t`: holder[key] is the number of the
-- loading it shows. Returns false when the image does not take the picture
-- (it must not be shown then).
local function show(holder, key, img, t)
    if holder[key] == t.serial then return true end
    if bind(img, t) then
        if holder[key] ~= nil then Tex.rebound = Tex.rebound + 1 end
        holder[key] = t.serial
        return true
    end
    holder[key] = nil
    return false
end
-- diagnostics only: the number of images loaded / not loadable, counted once
-- the loading has been quiet for a moment
function Obs.textures()
    Obs.texNoted = Obs.texGen
    local loaded, failed = 0, 0
    for _ in pairs(Textures) do loaded = loaded + 1 end
    for _ in pairs(TextureFail) do failed = failed + 1 end
    Obs.note("markers.textures", ("%d loaded, %d failed"):format(loaded, failed))
end
-- Pixel size of a bundled PNG, read from its header (no texture import), so
-- a name list can be laid out before its images are loaded.
local PngSizes = {}
local function pngSize(rel)
    local s = PngSizes[rel]
    if s == nil then
        s = false
        local f = io.open(SCRIPT_DIR .. rel, "rb")
        if f then
            local head = f:read(24)
            f:close()
            if type(head) == "string" and #head == 24 and head:sub(2, 4) == "PNG" then
                local ok, w, h = pcall(string.unpack, ">I4I4", head, 17)
                if ok and w and h and w > 0 and h > 0 then s = { w, h } end
            end
        end
        PngSizes[rel] = s
    end
    if s then return s[1], s[2] end
    return nil
end

-- The look of the pictures (setting PinLook): "drawn" - inked onto the map by
-- hand, the pictures of Assets/Drawn/ (the same names and sizes) - or
-- "classic", the coloured dots of before. A drawn picture that is not there is
-- the classic one.
local DrawnRel = {}
local function look(rel)
    if not rel or cfg("PinLook", "drawn") ~= "drawn" then return rel end
    local drawn = DrawnRel[rel]
    if drawn == nil then
        drawn = rel:gsub("^Assets/", "Assets/Drawn/")
        if drawn == rel or not pngSize(drawn) then drawn = false end
        DrawnRel[rel] = drawn
    end
    return drawn or rel
end

local PIN_IMAGES = {
    teacher = "Assets/Pins/pin_teacher.png",
    trader = "Assets/Pins/pin_merchant.png",
    both = "Assets/Pins/pin_both.png",
}
local function pinImageFor(def)
    return look(PIN_IMAGES[def.kind] or (def.orc and "Assets/Pins/pin_orc.png") or "Assets/Pins/pin_other.png")
end
local function poolImageFor(n)
    if n > 99 then return look("Assets/Pools/pool_more.png") end
    return look(("Assets/Pools/pool_%d.png"):format(n))
end

-- The name picture of a person, in the letters of the names on the map
-- (setting NameLetters): "game" - the game's own text letters, Assets/Labels -
-- or "gothic" - blackletter, Assets/LabelsGothic (the same file name) when that
-- picture is there; then in the look of the pictures.
local GothicLabels = {}
local function labelRel(def)
    local rel = def.label
    if not rel then return rel end
    if cfg("NameLetters", "game") == "gothic" then
        local gothic = GothicLabels[rel]
        if gothic == nil then
            gothic = rel:gsub("^Assets/Labels/", "Assets/LabelsGothic/")
            if gothic == rel or not pngSize(gothic) then gothic = false end
            GothicLabels[rel] = gothic
        end
        rel = gothic or rel
    end
    return look(rel)
end

-- ---------------------------------------------------------------------------
-- Bounding boxes (the same actors the game registers for each map)
-- ---------------------------------------------------------------------------
local BoxCache = { at = -1e9, list = {} }
local function allBoxes(now)
    if now - BoxCache.at < 5.0 and #BoxCache.list > 0 then return BoxCache.list end
    local out, seen = {}, {}
    for _, cls in ipairs({ "ActorMapBoundingBox", "W_MapBoundingBox_C" }) do
        for _, a in pairs(findAll(cls)) do
            if valid(a) and not fullName(a):find("Default__", 1, true) then
                local key = addrOf(a)
                if not seen[key] then
                    seen[key] = true
                    out[#out + 1] = { actor = a, tag = tagString(get(a, "ZoneTagMap")), name = shortName(a) }
                end
            end
        end
    end
    BoxCache.at, BoxCache.list = now, out
    return out
end

local function boxTransform(actor)
    local lx, ly, lz = vec3(call(actor, "K2_GetActorLocation"))
    local rot = call(actor, "K2_GetActorRotation")
    local sx, sy, sz = vec3(call(actor, "GetActorScale3D"))
    if not lx or not rot or not sx then return nil end
    local ok, p, yw, r = pcall(function() return rot.Pitch, rot.Yaw, rot.Roll end)
    if not ok then return nil end
    p, yw, r = num(p), num(yw), num(r)
    if not p or not yw or not r then return nil end
    return { loc = { lx, ly, lz }, rot = { p, yw, r }, scale = { sx, sy, sz } }
end

-- Exact box registered for this tag in UMapData::m_AreaBoxesDataMap, when
-- this UE4SS build can iterate that TMap. Returns nil when unknown.
local TMapUnreadable = false
local function registeredBox(mapData, tag)
    if not valid(mapData) or TMapUnreadable then return nil, false end
    local map = get(mapData, "m_AreaBoxesDataMap")
    if map == nil then TMapUnreadable = true; return nil, false end
    local found, keysRead = nil, 0
    local ok = pcall(function()
        map:ForEach(function(k, v)
            local key = k
            pcall(function() if k.get then key = k:get() end end)
            local val = v
            pcall(function() if v.get then val = v:get() end end)
            local s = tagString(key)
            if s then keysRead = keysRead + 1 end
            if s == tag then found = val end
        end)
    end)
    if not ok then
        TMapUnreadable = true
        logOnce("tmap", "UMapData box table not readable in this UE4SS build; using tag match + player calibration.")
        return nil, false
    end
    if valid(found) then return found, true end
    return nil, keysRead > 0
end

-- Player self-test: predicts the game's own player marker with a box and
-- compares against UMapWidget::m_PlayerPosMapOriginal / Corrected.
local function playerError(mapWidget, mapCfg, box, corr)
    local inMap = get(mapCfg, "IsPlayerInMap")
    if inMap == false then return nil end
    local sx, sy = vec2(get(mapCfg, "UICustomSize"))
    local ox, oy = vec2(get(mapWidget, "m_PlayerPosMapOriginal"))
    local qx, qy = vec2(get(mapWidget, "m_PlayerPosMapCorrected"))
    if not sx or sx <= 0 or sy <= 0 or not ox or (ox == 0 and oy == 0) then return nil end
    local pawn = getPawn(getController())
    local px, py, pz = vec3(call(pawn, "K2_GetActorLocation"))
    if not px then return nil end
    local x, y = Proj.Normalize(box, px, py, pz)
    local eo = math.sqrt(((x + 1) * 0.5 * sx - ox) ^ 2 + ((y + 1) * 0.5 * sy - oy) ^ 2)
    local ec = nil
    if qx and corr then
        local cx, cy = Proj.Correct(corr, x, y, 0.6)
        ec = math.sqrt(((cx + 1) * 0.5 * sx - qx) ^ 2 + ((cy + 1) * 0.5 * sy - qy) ^ 2)
    end
    return eo, ec, sx
end

local function selectBox(mapWidget, mapCfg, tag, corr, now)
    local mapData = get(mapWidget, "m_MapData")
    local reg, readable = registeredBox(mapData, tag)
    local cands = {}
    local worldBox = (tag == "Area") and get(mapData, "m_WorldMapBoundingBox") or nil
    if valid(reg) then
        cands[1] = { actor = reg, src = "registered" }
    elseif valid(worldBox) then
        -- the world map is not in the area table; the game uses this box
        -- (avoids a full object scan every few seconds)
        cands[1] = { actor = worldBox, src = "world-box" }
    else
        for _, b in ipairs(allBoxes(now)) do
            if b.tag == tag then cands[#cands + 1] = { actor = b.actor, src = "tag" } end
        end
        if #cands == 0 then
            local world = get(mapData, "m_WorldMapBoundingBox")
            if valid(world) then cands[1] = { actor = world, src = "world-fallback" }
            else
                for _, b in ipairs(allBoxes(now)) do
                    if b.tag == "Area" then cands[#cands + 1] = { actor = b.actor, src = "world-tag" } end
                end
            end
        end
    end
    local best, bestErr, bestCorrErr, scale
    for _, c in ipairs(cands) do
        c.box = boxTransform(c.actor)
        if c.box then
            local eo, ec, s = playerError(mapWidget, mapCfg, c.box, corr)
            c.err, c.cerr = eo, ec
            if eo and (bestErr == nil or eo < bestErr) then best, bestErr, bestCorrErr, scale = c, eo, ec, s end
        end
    end
    if not best then
        -- No calibration data: prefer a streamed-in native box (it registers
        -- after the persistent one), else the first usable candidate.
        for _, c in ipairs(cands) do
            if c.box and not shortName(c.actor):find("W_MapBoundingBox", 1, true) then best = c; break end
        end
        if not best then
            for _, c in ipairs(cands) do if c.box then best = c; break end end
        end
    end
    if not best then return nil end
    return best.box, {
        name = shortName(best.actor), src = best.src, candidates = #cands,
        err = bestErr, cerr = bestCorrErr, uiWidth = scale, tmap = readable,
    }
end
-- ---------------------------------------------------------------------------
-- NPC lookup
-- ---------------------------------------------------------------------------
local NpcRetry, LocMemo = {}, {}
local StaticLookupOk, StaticLookupBroken = false, false
local NpcCDO = nil
local ScanIndex = { at = -1e9, map = {} }
local MISSING_RETRY = 10.0 -- seconds before an unknown NPC is looked up again
local LOCATION_MEMO = 0.5  -- world and area map share one lookup per NPC

local function scanStates(now)
    if now - ScanIndex.at < 10.0 then return ScanIndex.map end
    local map = {}
    for _, cls in ipairs({ "GothicNPCState", "GothicCharacterState" }) do
        for _, s in pairs(findAll(cls)) do
            if valid(s) and not fullName(s):find("Default__", 1, true) then
                local uname
                local n = call(s, "GetCharacterUniqueName")
                if n ~= nil then pcall(function() uname = n:ToString() end) end
                if not uname then
                    local g = get(s, "CharacterGlobalId")
                    if g ~= nil then pcall(function() uname = g:ToString() end) end
                end
                if type(uname) == "string" and uname ~= "" then
                    map[uname:lower()] = map[uname:lower()] or s
                end
            end
        end
    end
    ScanIndex.at, ScanIndex.map = now, map
    return map
end

-- A person's state object. The game's own lookup hands it out fresh every
-- time it is needed (once per refresh and person: npcLocation keeps the
-- position for half a second, not the object) - a state object is an actor of
-- the world and can be gone the next moment. Only when that lookup does not
-- exist are the states searched for among all objects and kept, for ten
-- seconds at most and asked whether they are valid before every use.
local function findNpcState(def, ctrl, now)
    local retry = NpcRetry[def.id]
    if retry and now < retry then return nil end
    if not StaticLookupBroken and ctrl then
        if not valid(NpcCDO) then NpcCDO = findStaticOnce("/Script/G1R.Default__GothicNPCState") end
        if NpcCDO and FName ~= nil then
            local name = def.fname
            if name == nil then name = FName(def.id); def.fname = name end      -- (a name is a plain value: kept)
            local ok, st = pcall(function() return NpcCDO:FindNPCByUniqueName(ctrl, name) end)
            if ok then
                if valid(st) then
                    StaticLookupOk = true
                    if DIAG and Obs.facts["markers.state_lookup"] ~= "FindNPCByUniqueName" then
                        Obs.note("markers.state_lookup", "FindNPCByUniqueName")
                    end
                    NpcRetry[def.id] = nil
                    return st
                end
                if StaticLookupOk then
                    -- the game's own lookup works and does not know this NPC
                    -- (not in the world yet, or removed): ask again later
                    NpcRetry[def.id] = now + MISSING_RETRY
                    return nil
                end
            else
                StaticLookupBroken = true
                logOnce("static-lookup", "FindNPCByUniqueName unavailable (" .. tostring(st) .. "); scanning NPC states instead.")
                if DIAG and Obs.facts["markers.state_lookup"] ~= "scan" then
                    Obs.note("markers.state_lookup", "scan", "FindNPCByUniqueName unavailable (" .. tostring(st) .. ")")
                end
            end
        else
            StaticLookupBroken = true
            logOnce("static-missing", "GothicNPCState lookup not found; scanning NPC states instead.")
            if DIAG and Obs.facts["markers.state_lookup"] ~= "scan" then
                Obs.note("markers.state_lookup", "scan", "GothicNPCState lookup not found")
            end
        end
    end
    local st = scanStates(now)[def.id:lower()]
    if valid(st) then
        if DIAG and Obs.facts["markers.state_lookup"] ~= "scan" then
            Obs.note("markers.state_lookup", "scan",
                (ctrl and "FindNPCByUniqueName gave nothing for " or "no player controller for FindNPCByUniqueName; scanned for ") .. def.id)
        end
        NpcRetry[def.id] = nil
        return st
    end
    NpcRetry[def.id] = now + MISSING_RETRY
    return nil
end

local function npcLocation(def, ctrl, now)
    local m = LocMemo[def.id]
    if m and now - m.at >= 0 and now - m.at < LOCATION_MEMO then return m.loc, m.mode end
    local loc, mode = nil, "missing"
    local st = findNpcState(def, ctrl, now)
    if st then
        if cfg("HideDeadNPCs", true) ~= false
            and (callBool(st, "IsDead") == true or callBool(st, "GetRemovedFromWorld") == true) then
            mode = "dead"
        else
            local x, y, z = vec3(call(st, "GetCharacterLocation"))
            if not x then x, y, z = vec3(call(st, "K2_GetActorLocation")) end
            if x and not (x == 0 and y == 0 and z == 0) then loc, mode = { x, y, z }, "live" end
        end
    end
    if not loc and mode ~= "dead" and cfg("ShowFallbackPins", true) ~= false and type(def.fallback) == "table" then
        loc, mode = def.fallback, "approx"
    end
    if m then m.at, m.loc, m.mode = now, loc, mode
    else LocMemo[def.id] = { at = now, loc = loc, mode = mode } end
    return loc, mode
end

-- ---------------------------------------------------------------------------
-- Widgets: one owned canvas per map widget; a pin per NPC on that map, a
-- label where it fits, and a name list for the pins under the mouse
-- (all created lazily)
-- ---------------------------------------------------------------------------
local VIS_VISIBLE, VIS_COLLAPSED, VIS_HIT_INVISIBLE, VIS_SELF_HIT_INVISIBLE = 0, 1, 3, 4
local Z_PIN_OTHER, Z_PIN, Z_LABEL, Z_PIN_GROUP, Z_PIN_OWNER, Z_HOVER = 1, 2, 3, 4, 5, 6
local Z_POOL, Z_POOL_DOT, Z_OWNER_DOT = 3, 4, 6
local Z_LIST_EDGE, Z_LIST_FILL, Z_LIST = 1, 2, 3     -- inside the list canvas

local function anchors(u, v) return { Minimum = { X = u, Y = v }, Maximum = { X = u, Y = v } } end

local function newWidget(className, outer)
    local cls = findStaticOnce(className)
    if not cls or not valid(outer) then return nil end
    local ok, w = pcall(StaticConstructObject, cls, outer)
    if ok and valid(w) then return w end
    return nil
end

local function isChildOf(w, panel)
    local p = call(w, "GetParent")
    return valid(p) and valid(panel) and addrOf(p) == addrOf(panel)
end

local function ensurePanel(st, mapWidget)
    if valid(st.panel) and valid(st.general) and isChildOf(st.panel, st.general) then return true end
    st.panel, st.general, st.entries, st.hoverList, st.group = nil, nil, {}, {}, nil
    st.pools = {}
    local custom = get(mapWidget, "CanvasPanel_CustomMarkers")
    local general = call(custom, "GetParent")
    local tree = get(mapWidget, "WidgetTree")
    if not valid(general) or not valid(tree) then
        logOnce("panel:" .. st.id, "Map widget layout not ready (" .. st.which .. ").")
        return false
    end
    local panel = newWidget("/Script/UMG.CanvasPanel", tree)
    if not panel then logOnce("panel-create", "Could not create the marker canvas."); return false end
    local slot = call(general, "AddChildToCanvas", panel)
    if not valid(slot) then logOnce("panel-add", "Could not attach the marker canvas."); return false end
    pcall(function()
        slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
        slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        slot:SetAlignment({ X = 0, Y = 0 })
    end)
    wcall(panel, "SetVisibility", VIS_SELF_HIT_INVISIBLE)
    st.panel, st.general, st.tree, st.panelVis = panel, general, tree, VIS_SELF_HIT_INVISIBLE
    return true
end

local function setPanelVisible(st, on)
    if not valid(st.panel) then return end
    local want = on and VIS_SELF_HIT_INVISIBLE or VIS_COLLAPSED
    if st.panelVis ~= want then
        wcall(st.panel, "SetVisibility", want)
        st.panelVis = want
    end
end

local function setVis(w, holder, key, vis)
    if holder[key] ~= vis then
        wcall(w, "SetVisibility", vis)
        holder[key] = vis
    end
end

-- New images and loaded pictures per update: one allowance for everything
-- the mod makes in it - pins, names, badges on both maps, and the names of
-- the people under the mouse. `short` says that the caller ran out.
local TickBudget = { at = -1, left = 0, short = false }
local function tickBudget(now)
    if TickBudget.at ~= now then
        TickBudget.at, TickBudget.left = now, math.max(1, math.floor(cfg("MaxNewWidgetsPerTick", 24)))
    end
    TickBudget.short = false
    return TickBudget
end

-- A new image in the marker canvas that shows the picture `texInfo`: either
-- all of it worked - the image exists, shows its picture and has its place in
-- the canvas - or there is no image (what was made of it is taken out again).
local function makeImage(st, texInfo, z, alignY)
    local img = newWidget("/Script/UMG.Image", st.tree)
    if not img then return nil end
    wcall(img, "SetVisibility", VIS_COLLAPSED)
    if not bind(img, texInfo) then return nil end       -- (not in the canvas yet: nothing to take out)
    local slot = call(st.panel, "AddChildToCanvas", img)
    if not valid(slot) then wcall(img, "RemoveFromParent"); return nil end
    wcall(slot, "SetAutoSize", false)
    wcall(slot, "SetAlignment", { X = 0.5, Y = alignY })
    wcall(slot, "SetPosition", { X = 0, Y = 0 })
    wcall(slot, "SetZOrder", z)
    return img, slot
end

local function hideEntry(e)
    setVis(e.pin, e, "pinVis", VIS_COLLAPSED)
    if e.label then setVis(e.label, e, "labelVis", VIS_COLLAPSED) end
    e.shown, e.autoPos = false, nil
end

-- The pin of a person on this map: made when it is not there, and showing
-- the current loading of its picture. nil: not now (the caller hides nothing
-- else for it; it is tried again at the next refresh).
local function ensureEntry(st, def, now, budget)
    local e = st.entries[def.id]
    if e and valid(e.pin) and valid(e.pinSlot) then
        local pinTex = cachedTexture(pinImageFor(def), now)
        if pinTex and e.pinTex == pinTex.serial then return e end
        -- its picture was loaded again (or is gone): the pin takes the current one, or is not shown
        if budget.left <= 0 then budget.short = true; hideEntry(e); return nil end
        pinTex = pinTex or loadTexture(pinImageFor(def), now)
        budget.left = budget.left - 1
        if pinTex and show(e, "pinTex", e.pin, pinTex) then return e end
        hideEntry(e)
        return nil
    end
    if e then
        wcall(e.pin, "RemoveFromParent")
        if e.label then wcall(e.label, "RemoveFromParent") end
        st.entries[def.id] = nil
    end
    if budget.left <= 0 then budget.short = true; return nil end
    local pinTex = loadTexture(pinImageFor(def), now)
    if not pinTex then return nil end
    budget.left = budget.left - 1
    local z = def.important and Z_PIN or Z_PIN_OTHER
    local pin, slot = makeImage(st, pinTex, z, 0.5)
    if not pin then return nil end
    e = { def = def, pin = pin, pinSlot = slot, pinVis = VIS_COLLAPSED, z = z, baseZ = z, pinTex = pinTex.serial }
    st.entries[def.id] = e
    return e
end

-- Label texture (dimensions decide whether a label fits); imports count
-- against the per-step budget.
local function labelTexture(e, now, budget)
    local rel = labelRel(e.def)
    if not rel then return nil end
    local t = cachedTexture(rel, now)
    if t then return t end
    if budget then
        if budget.left <= 0 then budget.short = true; return nil end
        budget.left = budget.left - 1
    end
    return loadTexture(rel, now)
end

-- The name image of a pin: made when it is not there, and showing the
-- current loading of its picture, with that picture's size. false: there is
-- no name to show now - a name image that does not take its picture stays
-- hidden, it is never shown blank.
local function ensureLabel(st, e, now, budget, z)
    local lt = labelTexture(e, now, budget)
    if e.label then
        if valid(e.label) and valid(e.labelSlot) then
            if lt and e.labelTex == lt.serial then return true end
            if lt and show(e, "labelTex", e.label, lt) then
                e.labelW, e.labelH = lt.w, lt.h
                return true
            end
            setVis(e.label, e, "labelVis", VIS_COLLAPSED)
            return false
        end
        wcall(e.label, "RemoveFromParent")
        e.label, e.labelSlot, e.lpos, e.labelAlpha, e.labelZ, e.labelTex = nil, nil, nil, nil, nil, nil
    end
    if not lt then return false end
    if budget then
        if budget.left <= 0 then budget.short = true; return false end
        budget.left = budget.left - 1
    end
    local img, slot = makeImage(st, lt, z, 0)
    if not img then return false end
    e.label, e.labelSlot, e.labelW, e.labelH, e.labelVis, e.labelZ, e.labelTex = img, slot, lt.w, lt.h, VIS_COLLAPSED, z, lt.serial
    return true
end

local function setPinZ(e, z)
    if e.z ~= z then
        wcall(e.pinSlot, "SetZOrder", z)
        e.z = z
    end
end
local function setLabelZ(e, z)
    if e.label and e.labelZ ~= z then
        wcall(e.labelSlot, "SetZOrder", z)
        e.labelZ = z
    end
end

local function setPinLook(e, alpha, size)
    if e.alpha ~= alpha then
        wcall(e.pin, "SetColorAndOpacity", { R = 1, G = 1, B = 1, A = alpha })
        e.alpha = alpha
    end
    if e.size ~= size then
        wcall(e.pinSlot, "SetSize", { X = size, Y = size })
        e.size = size
    end
end

local function placePin(e, u, v, size, alpha, vis)
    if e.u ~= u or e.v ~= v then
        wcall(e.pinSlot, "SetAnchors", anchors(u, v))
        e.u, e.v = u, v
    end
    setPinLook(e, alpha, size)
    setVis(e.pin, e, "pinVis", vis)
    e.shown = true
end

-- Label anchored at (au, av) (its own pin, or the hovered pin for a name
-- list), offset (dx, dy) in canvas units, top-centre aligned.
local function placeLabel(e, au, av, dx, dy, lw, lh, vis)
    local p = e.lpos
    if not p then p = {}; e.lpos = p end
    if p.u ~= au or p.v ~= av then
        wcall(e.labelSlot, "SetAnchors", anchors(au, av))
        p.u, p.v = au, av
    end
    if p.dx ~= dx or p.dy ~= dy then
        wcall(e.labelSlot, "SetPosition", { X = dx, Y = dy })
        p.dx, p.dy = dx, dy
    end
    if p.w ~= lw or p.h ~= lh then
        wcall(e.labelSlot, "SetSize", { X = lw, Y = lh })
        p.w, p.h = lw, lh
    end
    local a = e.baseAlpha or 1.0
    if e.labelAlpha ~= a then
        wcall(e.label, "SetColorAndOpacity", { R = 1, G = 1, B = 1, A = a })
        e.labelAlpha = a
    end
    setVis(e.label, e, "labelVis", vis)
end

-- Label placement: below the pin, else above, right, left, free of other
-- labels and pins. "auto" stops there (no label; the name shows on hover);
-- "always" then accepts pin overlap, then stacks below.
local ORDERS = {
    [1] = { 1, 2, 3, 4 }, [2] = { 2, 1, 3, 4 }, [3] = { 3, 1, 2, 4 }, [4] = { 4, 1, 2, 3 },
}
local function candidateOffset(k, s, gap, lw, lh)
    if k == 1 then return 0, s * 0.5 + gap end
    if k == 2 then return 0, -(s * 0.5 + gap + lh) end
    if k == 3 then return s * 0.5 + gap + lw * 0.5, -lh * 0.5 end
    return -(s * 0.5 + gap + lw * 0.5), -lh * 0.5
end
local function hits(list, x0, y0, x1, y1, skip)
    for i = 1, #list do
        local r = list[i]
        if r ~= skip and x0 < r[3] and x1 > r[1] and y0 < r[4] and y1 > r[2] then return r end
    end
    return nil
end
local function layoutLabel(cx, cy, s, gap, lw, lh, labels, pins, ownPin, prefer, strict)
    local order = ORDERS[prefer or 1] or ORDERS[1]
    for pass = 1, strict and 1 or 2 do
        for i = 1, 4 do
            local k = order[i]
            local dx, dy = candidateOffset(k, s, gap, lw, lh)
            local x0, y0 = cx + dx - lw * 0.5, cy + dy
            local x1, y1 = x0 + lw, y0 + lh
            if not hits(labels, x0, y0, x1, y1) and (pass == 2 or not hits(pins, x0, y0, x1, y1, ownPin)) then
                return dx, dy, k
            end
        end
    end
    if strict then return nil end
    local dy = s * 0.5 + gap
    for _ = 1, 16 do
        local x0, y0 = cx - lw * 0.5, cy + dy
        local r = hits(labels, x0, y0, x0 + lw, y0 + lh)
        if not r then break end
        dy = r[4] + 1 - cy
    end
    return 0, dy, 1
end

-- ---------------------------------------------------------------------------
-- Pools (world map): people standing close together are one badge with
-- their number. Membership is plain proximity: two people closer than
-- PoolLinkDistance belong to the same place, and so does everyone linked to
-- either of them; a place with at least PoolMinSize people becomes a pool.
-- ---------------------------------------------------------------------------
-- The game's camp-name buttons on the world map (W_Map_Main, CanvasPanel_
-- CampsNames): centre offset from the map centre and size, in canvas units.
-- They are drawn above the map and take the mouse, so a pool badge is never
-- placed under one.
local CAMP_LABELS = {
    { "Button_OldCamp", 39.0, -24.6875, 142.0, 50.625 },
    { "Button_NewCamp", -347.36365, -144.09091, 155.27272, 51.818184 },
    { "Button_SwampCamp", 485.63635, 123.90909, 155.27272, 51.818184 },
    { "Button_OrcCamp", -110.36364, 243.90909, 155.27272, 51.818184 },
    { "Button_SleepersTemple", -614.36365, 327.9091, 155.27272, 51.818184 },
}
local function campLabelRects(st, cw, ch)
    local rects = {}
    local main = st.main
    for _, c in ipairs(CAMP_LABELS) do
        local shown = true
        if valid(main) then
            local b = get(main, c[1])
            if valid(b) and callBool(b, "IsVisible") == false then shown = false end
        end
        if shown then
            local x, y = cw * 0.5 + c[2], ch * 0.5 + c[3]
            rects[#rects + 1] = { x - c[4] * 0.5, y - c[5] * 0.5, x + c[4] * 0.5, y + c[5] * 0.5 }
        end
    end
    if DIAG and #rects ~= Obs.camps then
        Obs.camps = #rects
        Obs.note("markers.camp_names", #rects .. " shown")
    end
    return rects
end

-- Badge centre: the middle of its people, moved just below (or above) a camp
-- name it would touch, and kept inside the map.
local function badgePosition(cx, cy, r, rects, cw, ch)
    for _, R in ipairs(rects) do
        if cx + r > R[1] and cx - r < R[3] and cy + r > R[2] and cy - r < R[4] then
            local below, above = R[4] + r + 2, R[2] - r - 2
            if cy >= (R[2] + R[4]) * 0.5 then
                cy = (below + r <= ch) and below or above
            else
                cy = (above - r >= 0) and above or below
            end
        end
    end
    if cx < r then cx = r elseif cx > cw - r then cx = cw - r end
    if cy < r then cy = r elseif cy > ch - r then cy = ch - r end
    return math.floor(cx + 0.5), math.floor(cy + 0.5)
end

-- items: { def, u, v, mode, cx, cy } in NPC-list order. Returns the pools and
-- sets item.pool on their members.
local function buildPools(st, items, cw, ch)
    local n = #items
    local minSize = math.max(2, math.floor(cfg("PoolMinSize", 4)))
    if n < minSize then return {} end
    local link = cfg("PoolLinkDistance", 26)
    local l2 = link * link
    local parent = {}
    for i = 1, n do parent[i] = i end
    local function find(i)
        while parent[i] ~= i do
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end
    for i = 1, n - 1 do
        local a = items[i]
        for j = i + 1, n do
            local b = items[j]
            local dx, dy = a.cx - b.cx, a.cy - b.cy
            if dx * dx + dy * dy <= l2 then
                local ra, rb = find(i), find(j)
                if ra < rb then parent[rb] = ra elseif rb < ra then parent[ra] = rb end
            end
        end
    end
    local groups, order = {}, {}
    for i = 1, n do
        local r = find(i)
        local g = groups[r]
        if not g then g = {}; groups[r] = g; order[#order + 1] = r end
        g[#g + 1] = items[i]
    end
    local radius = cfg("PoolPinSize", 26) * 0.5
    local rects = campLabelRects(st, cw, ch)
    local pools = {}
    for _, r in ipairs(order) do
        local g = groups[r]
        if #g >= minSize then
            local sx, sy, teach, trade = 0, 0, false, false
            for _, it in ipairs(g) do
                sx, sy = sx + it.cx, sy + it.cy
                local k = it.def.kind
                if k == "teacher" or k == "both" then teach = true end
                if k == "trader" or k == "both" then trade = true end
            end
            local cx, cy = badgePosition(sx / #g, sy / #g, radius, rects, cw, ch)
            -- the first member in list order names the pool, so its badge
            -- widget is reused from refresh to refresh
            local pool = { key = g[1].def.id, items = g, n = #g, cx = cx, cy = cy, teach = teach, trade = trade }
            for _, it in ipairs(g) do it.pool = pool end
            pools[#pools + 1] = pool
        end
    end
    return pools
end

local function ensurePool(st, key, texRel, now, budget)
    local p = st.pools[key]
    if p and valid(p.pin) and valid(p.pinSlot) then return p end
    if p then
        wcall(p.pin, "RemoveFromParent")
        for _, d in pairs(p.dots) do wcall(d.pin, "RemoveFromParent") end
        st.pools[key] = nil
    end
    if budget.left <= 0 then budget.short = true; return nil end
    local tex = loadTexture(texRel, now)
    if not tex then return nil end
    budget.left = budget.left - 1
    local pin, slot = makeImage(st, tex, Z_POOL, 0.5)
    if not pin then return nil end
    p = { isPool = true, key = key, pin = pin, pinSlot = slot, pinVis = VIS_COLLAPSED, z = Z_POOL, baseZ = Z_POOL,
        tex = texRel, pinTex = tex.serial, dots = {}, baseAlpha = 1.0, def = { id = key, name = "pool" } }
    st.pools[key] = p
    return p
end

-- Two small dots on a badge: blue when a teacher is among its people,
-- yellow for a trader. They follow the badge's size and never take the mouse.
local DOT_IMAGES = { teach = "Assets/Pins/pin_teacher.png", trade = "Assets/Pins/pin_merchant.png" }
local function placePoolDots(st, p, size, z, now, budget)
    for which, base in pairs(DOT_IMAGES) do
        local rel = look(base)
        local d = p.dots[which]
        if not p[which] or not p.shown then
            if d then setVis(d.pin, d, "pinVis", VIS_COLLAPSED) end
        else
            if not (d and valid(d.pin) and valid(d.pinSlot)) and budget then
                d = nil
                if budget.left > 0 then
                    local tex = loadTexture(rel, now)
                    if tex then
                        budget.left = budget.left - 1
                        local pin, slot = makeImage(st, tex, Z_POOL_DOT, 0.5)
                        if pin then d = { pin = pin, pinSlot = slot, pinVis = VIS_COLLAPSED, z = Z_POOL_DOT, pinTex = tex.serial } end
                    end
                else
                    budget.short = true
                end
                p.dots[which] = d
            end
            -- (a dot whose picture was loaded again takes the current one, or is not shown)
            local dotOk = d and valid(d.pin) and valid(d.pinSlot)
            if dotOk then
                local tex = cachedTexture(rel, now) or (budget and loadTexture(rel, now)) or nil
                if not (tex and show(d, "pinTex", d.pin, tex)) then
                    setVis(d.pin, d, "pinVis", VIS_COLLAPSED)
                    dotOk = false
                end
            end
            if dotOk then
                if d.u ~= p.u or d.v ~= p.v then
                    wcall(d.pinSlot, "SetAnchors", anchors(p.u, p.v))
                    d.u, d.v = p.u, p.v
                end
                local off = size * 0.36 * (which == "teach" and -1 or 1)
                local ds = size * 0.42
                if d.off ~= off or d.ds ~= ds then
                    wcall(d.pinSlot, "SetPosition", { X = off, Y = -size * 0.36 })
                    wcall(d.pinSlot, "SetSize", { X = ds, Y = ds })
                    d.off, d.ds = off, ds
                end
                if d.z ~= z then
                    wcall(d.pinSlot, "SetZOrder", z)
                    d.z = z
                end
                setVis(d.pin, d, "pinVis", VIS_HIT_INVISIBLE)
            end
        end
    end
end

-- Badges for this refresh; badges of pools that no longer exist are hidden
-- (and kept for reuse). Returns the number of pools shown and of people in them.
local function syncPools(st, pools, now, budget, hoverable, hoverList, pinRects, cw, ch)
    local used, count, people = {}, 0, 0
    local size = cfg("PoolPinSize", 26)
    local alpha = cfg("PoolOpacity", 0.9)
    for _, pool in ipairs(pools) do
        local texRel = poolImageFor(pool.n)
        local p = ensurePool(st, pool.key, texRel, now, budget)
        -- the badge shows the picture of its number - the current loading of it; a badge that does
        -- not take it is left out of this refresh (it would show another number, or nothing)
        if p then
            local tex = loadTexture(texRel, now)
            if p.tex ~= texRel then p.pinTex = nil end
            if tex and show(p, "pinTex", p.pin, tex) then
                p.tex = texRel
            else
                if p.shown then
                    setVis(p.pin, p, "pinVis", VIS_COLLAPSED)
                    p.shown = false
                    placePoolDots(st, p, p.idleSize or size, Z_POOL_DOT, now, nil)
                end
                p = nil
            end
        end
        if p then
            used[pool.key] = true
            p.items, p.n, p.cx, p.cy, p.teach, p.trade = pool.items, pool.n, pool.cx, pool.cy, pool.teach, pool.trade
            p.idleSize, p.idleAlpha = size, alpha
            placePin(p, pool.cx / cw, pool.cy / ch, size, alpha, hoverable and VIS_VISIBLE or VIS_HIT_INVISIBLE)
            setPinZ(p, Z_POOL)
            placePoolDots(st, p, size, Z_POOL_DOT, now, budget)
            if hoverable then hoverList[#hoverList + 1] = p end
            local h = size * 0.5
            pinRects[#pinRects + 1] = { pool.cx - h, pool.cy - h, pool.cx + h, pool.cy + h }
            count, people = count + 1, people + pool.n
        end
    end
    for key, p in pairs(st.pools) do
        if not used[key] and p.shown then
            setVis(p.pin, p, "pinVis", VIS_COLLAPSED)
            p.shown = false
            placePoolDots(st, p, p.idleSize or size, Z_POOL_DOT, now, nil)
        end
    end
    return count, people
end

-- ---------------------------------------------------------------------------
-- Name list of a pool: rows of [kind dot][name] in columns on a plain
-- backdrop, next to the badge. On the world map it lives in a canvas of its
-- own above the game's camp names; its row images are reused for every pool.
-- ---------------------------------------------------------------------------
local function ensureListCanvas(st)
    local L = st.list
    if L and valid(L.canvas) and valid(L.parent) and isChildOf(L.canvas, L.parent) then return L end
    st.list = nil
    local canvas, parent, tree
    local overlay = call(st.widget, "GetParent")
    local mainTree = get(st.main, "WidgetTree")
    if valid(overlay) and valid(mainTree) and fullName(overlay):match("^Overlay ") then
        canvas = newWidget("/Script/UMG.CanvasPanel", mainTree)
        local slot = canvas and call(overlay, "AddChildToOverlay", canvas)
        if valid(slot) then
            wcall(slot, "SetHorizontalAlignment", 0)   -- HAlign_Fill
            wcall(slot, "SetVerticalAlignment", 0)     -- VAlign_Fill
            wcall(canvas, "SetVisibility", VIS_HIT_INVISIBLE)
            parent, tree = overlay, mainTree
            if DIAG and Obs.facts["markers.pool_list_canvas"] ~= "own canvas" then
                Obs.note("markers.pool_list_canvas", "own canvas")
            end
        else
            if canvas then wcall(canvas, "RemoveFromParent") end
            canvas = nil
        end
    end
    if not canvas then
        -- no overlay above the map: use the marker canvas (a camp name may
        -- then cover part of a list)
        if not (valid(st.panel) and valid(st.general) and valid(st.tree)) then return nil end
        canvas, parent, tree = st.panel, st.general, st.tree
        logOnce("list-canvas", "Pool lists are drawn in the marker canvas (map screen layout not as expected).")
        if DIAG and Obs.facts["markers.pool_list_canvas"] ~= "marker canvas" then
            Obs.note("markers.pool_list_canvas", "marker canvas")
        end
    end
    L = { canvas = canvas, parent = parent, tree = tree, rows = {} }
    st.list = L
    return L
end

-- An image placed by absolute position in a canvas (top-left anchored).
local function canvasImage(canvas, tree, z)
    local img = newWidget("/Script/UMG.Image", tree)
    if not img then return nil end
    wcall(img, "SetVisibility", VIS_COLLAPSED)
    local slot = call(canvas, "AddChildToCanvas", img)
    if not valid(slot) then wcall(img, "RemoveFromParent"); return nil end
    wcall(slot, "SetAutoSize", false)
    wcall(slot, "SetAnchors", anchors(0, 0))
    wcall(slot, "SetAlignment", { X = 0, Y = 0 })
    wcall(slot, "SetZOrder", z)
    return { img = img, slot = slot, vis = VIS_COLLAPSED }
end
-- Returns false when the image does not take its picture (it is hidden then).
local function placeCanvasImage(w, x, y, wd, ht, tex, alpha)
    if tex and not show(w, "texSerial", w.img, tex) then
        if w.vis ~= VIS_COLLAPSED then
            wcall(w.img, "SetVisibility", VIS_COLLAPSED)
            w.vis = VIS_COLLAPSED
        end
        return false
    end
    if w.x ~= x or w.y ~= y then
        wcall(w.slot, "SetPosition", { X = x, Y = y })
        w.x, w.y = x, y
    end
    if w.w ~= wd or w.h ~= ht then
        wcall(w.slot, "SetSize", { X = wd, Y = ht })
        w.w, w.h = wd, ht
    end
    alpha = alpha or 1.0
    if w.alpha ~= alpha then
        wcall(w.img, "SetColorAndOpacity", { R = 1, G = 1, B = 1, A = alpha })
        w.alpha = alpha
    end
    if w.vis ~= VIS_HIT_INVISIBLE then
        wcall(w.img, "SetVisibility", VIS_HIT_INVISIBLE)
        w.vis = VIS_HIT_INVISIBLE
    end
    return true
end
local function hideCanvasImage(w)
    if w and w.vis ~= VIS_COLLAPSED then
        wcall(w.img, "SetVisibility", VIS_COLLAPSED)
        w.vis = VIS_COLLAPSED
    end
end

-- Rows are filled a few per update step (new images and name textures are
-- what costs time the first time a big pool is opened).
local function fillPoolList(st, now)
    local g = st.group
    if not g or not g.pool then return end
    local L = ensureListCanvas(st)
    if not L then g.next = #g.rows + 1; return end
    -- (a map screen is open, nothing else is going on: three steps' worth)
    local left = 3 * math.max(4, math.floor(cfg("MaxNewWidgetsPerTick", 24)))
    if not g.backdrop then
        local edge = loadTexture(look("Assets/Pools/list_edge.png"), now)
        local fill = loadTexture(look("Assets/Pools/list_fill.png"), now)
        if not (L.edge and valid(L.edge.img)) then L.edge = canvasImage(L.canvas, L.tree, Z_LIST_EDGE) end
        if not (L.fill and valid(L.fill.img)) then L.fill = canvasImage(L.canvas, L.tree, Z_LIST_FILL) end
        if edge and fill and L.edge and L.fill then
            placeCanvasImage(L.edge, g.x0, g.y0, g.w, g.h, edge, 1.0)
            placeCanvasImage(L.fill, g.x0 + 1, g.y0 + 1, g.w - 2, g.h - 2, fill, 1.0)
        end
        g.backdrop = true      -- one attempt; names are readable without it
    end
    while g.next <= #g.rows do
        local i = g.next
        local row = g.rows[i]
        local w = L.rows[i]
        if not (w and valid(w.icon.img) and valid(w.label.img)) then
            if left < 2 then return end
            local icon = canvasImage(L.canvas, L.tree, Z_LIST)
            local label = canvasImage(L.canvas, L.tree, Z_LIST)
            if not icon or not label then g.next = #g.rows + 1; return end
            w = { icon = icon, label = label }
            L.rows[i] = w
            left = left - 2
        end
        local labelTex = nil
        local labelPath = labelRel(row.def)
        if labelPath then
            if not cachedTexture(labelPath, now) then
                if left < 1 then return end
                left = left - 1
            end
            labelTex = loadTexture(labelPath, now)
        end
        local iconTex = loadTexture(pinImageFor(row.def), now)
        if iconTex then
            placeCanvasImage(w.icon, row.x, row.y + (g.rowH - g.icon) * 0.5, g.icon, g.icon, iconTex, row.alpha)
        else
            hideCanvasImage(w.icon)
        end
        if labelTex and row.lw > 0 then
            placeCanvasImage(w.label, row.x + g.icon + g.gapX, row.y + (g.rowH - row.lh) * 0.5, row.lw, row.lh, labelTex, row.alpha)
        else
            hideCanvasImage(w.label)
        end
        g.next = i + 1
    end
end

local KIND_RANK = { both = 1, teacher = 2, trader = 3 }
local function openPoolList(st, p, now)
    local big = (p.idleSize or p.size or 26) * cfg("HoverPinScale", 1.4)
    p.group = "owner"
    setPinLook(p, 1.0, big)
    setPinZ(p, Z_PIN_OWNER)
    placePoolDots(st, p, big, Z_OWNER_DOT, now, nil)
    -- teachers and traders first, then by name
    local people = {}
    for _, it in ipairs(p.items or {}) do people[#people + 1] = it end
    table.sort(people, function(a, b)
        local ra, rb = KIND_RANK[a.def.kind] or 9, KIND_RANK[b.def.kind] or 9
        if ra ~= rb then return ra < rb end
        local na, nb = tostring(a.def.name):lower(), tostring(b.def.name):lower()
        if na ~= nb then return na < nb end
        return a.def.id < b.def.id
    end)
    local n = math.min(#people, math.max(1, math.floor(cfg("PoolListMax", 96))))
    local ls = st.labelScale or 0.39
    local icon, pad, gapX, colGap = 12, 6, 4, 12
    local perCol = math.max(4, math.floor(cfg("PoolListRows", 16)))
    local cols = math.ceil(n / perCol)
    local rows = math.ceil(n / cols)
    local sizes, rowH = {}, icon
    for i = 1, n do
        local w, h
        if people[i].def.label then w, h = pngSize(labelRel(people[i].def)) end
        w, h = (w or 0) * ls, (h or 0) * ls
        sizes[i] = { w, h }
        if h > rowH then rowH = h end
    end
    rowH = rowH + 1
    local colW, total = {}, 0
    for c = 1, cols do
        local mw = 0
        for i = (c - 1) * rows + 1, math.min(c * rows, n) do
            if sizes[i][1] > mw then mw = sizes[i][1] end
        end
        colW[c] = icon + gapX + mw
        total = total + colW[c]
    end
    local W = pad * 2 + total + colGap * (cols - 1)
    local Hh = pad * 2 + rows * rowH - 1
    -- beside the badge (right, else left), else below / above it; inside the map
    local cw, ch = st.canvasW or 1600, st.canvasH or 900
    local r = big * 0.5
    local px, py = p.u * cw, p.v * ch
    local x0, y0
    if px + r + 8 + W <= cw - 6 then
        x0 = px + r + 8
    elseif px - r - 8 - W >= 6 then
        x0 = px - r - 8 - W
    end
    if x0 then
        y0 = py - Hh * 0.5
        if y0 + Hh > ch - 6 then y0 = ch - 6 - Hh end
        if y0 < 6 then y0 = 6 end
    else
        x0 = math.max(6, math.min(cw - 6 - W, px - W * 0.5))
        if py + r + 8 + Hh <= ch - 6 then y0 = py + r + 8 else y0 = math.max(6, py - r - 8 - Hh) end
    end
    x0, y0 = math.floor(x0 + 0.5), math.floor(y0 + 0.5)
    local fallback = cfg("FallbackOpacity", 0.55)
    local list, idx = {}, 0
    local x = x0 + pad
    for c = 1, cols do
        for rI = 1, rows do
            idx = idx + 1
            if idx > n then break end
            local it = people[idx]
            list[idx] = { def = it.def, x = x, y = y0 + pad + (rI - 1) * rowH, lw = sizes[idx][1], lh = sizes[idx][2],
                alpha = (it.mode == "approx") and fallback or 1.0 }
        end
        x = x + colW[c] + colGap
    end
    st.group = { owner = p, pool = true, members = {}, rows = list, next = 1, x0 = x0, y0 = y0, w = W, h = Hh,
        icon = icon, gapX = gapX, rowH = rowH - 1, more = #people - n }
    fillPoolList(st, now)
end

local function closePoolList(st, g)
    local p = g.owner
    p.group = nil
    if valid(p.pin) and valid(p.pinSlot) then
        setPinLook(p, p.idleAlpha or 1.0, p.idleSize or p.size)
        setPinZ(p, p.baseZ)
        placePoolDots(st, p, p.idleSize or p.size, Z_POOL_DOT, 0, nil)
    end
    local L = st.list
    if L then
        for i = 1, #g.rows do
            local w = L.rows[i]
            if w then hideCanvasImage(w.icon); hideCanvasImage(w.label) end
        end
        hideCanvasImage(L.edge)
        hideCanvasImage(L.fill)
    end
    st.last = -1e9      -- positions were held while the list was open
end

-- ---------------------------------------------------------------------------
-- Hover: the pin under the mouse and every pin within HoverGroupRadius of
-- it become opaque, and their names are listed under the hovered pin. A
-- hovered pool badge lists its people instead.
-- ---------------------------------------------------------------------------
local PanelHoverWorks = nil -- learned: does the canvas report hover of its pins?

local function idleAlphaOf(st, e)
    if e.isPool then return e.idleAlpha or 1.0 end
    return (e.baseAlpha or 1.0) * (st.idleAlpha or 1.0)
end

local function restoreLabel(e)
    if not e.label then return end
    local a = e.autoPos
    if a and e.shown then
        setLabelZ(e, Z_LABEL)
        placeLabel(e, e.u, e.v, a[1], a[2], a[3], a[4], VIS_HIT_INVISIBLE)
    else
        setVis(e.label, e, "labelVis", VIS_COLLAPSED)
    end
end

local function clearGroup(st)
    local g = st.group
    st.group = nil
    if not g then return end
    if g.pool then closePoolList(st, g); return end
    for _, e in ipairs(g.members) do
        e.group = nil
        if valid(e.pin) and valid(e.pinSlot) then
            setPinLook(e, idleAlphaOf(st, e), e.idleSize or e.size)
            setPinZ(e, e.baseZ)
        end
        if e.label and valid(e.label) then restoreLabel(e) end
    end
    for _, e in ipairs(g.covered or {}) do
        e.covered = nil
        if e.label and valid(e.label) and not e.group then restoreLabel(e) end
    end
end

local function layoutGroup(st, now)
    local g = st.group
    if not g or g.pool then return end
    local owner = g.owner
    local ls, gap, ch = st.labelScale or 0.39, st.gap or 2, st.canvasH or 900
    -- The names are made within the update's allowance of new images. A name
    -- that has to wait holds back the ones after it, so the list grows in its
    -- order, a few names per update (updateHover comes back while it is short).
    local budget = tickBudget(now)
    local items, total = {}, 0
    g.short = false
    for _, e in ipairs(g.members) do
        if e.shown then
            if ensureLabel(st, e, now, budget, Z_HOVER) then
                local lw, lh = e.labelW * ls, e.labelH * ls
                items[#items + 1] = { e = e, w = lw, h = lh }
                total = total + lh + 1
            elseif budget.short then
                g.short = true
                break
            end
        end
    end
    local start = (owner.size or 0) * 0.5 + gap
    local below = owner.v * ch + start + total <= ch
    local y = below and start or -(start + total)
    local maxW = 0
    for _, it in ipairs(items) do
        setLabelZ(it.e, Z_HOVER)
        placeLabel(it.e, owner.u, owner.v, 0, y, it.w, it.h, VIS_HIT_INVISIBLE)
        y = y + it.h + 1
        if it.w > maxW then maxW = it.w end
    end
    -- hide automatic labels the list would cover; they return afterwards
    local cw = st.canvasW or 1600
    local ox, oy = owner.u * cw, owner.v * ch
    local lx0, lx1 = ox - maxW * 0.5, ox + maxW * 0.5
    local ly0 = oy + (below and start or -(start + total))
    local ly1 = ly0 + total
    local prev = {}
    for _, e in ipairs(g.covered or {}) do prev[e] = true; e.covered = nil end
    local covered = {}
    for _, e in ipairs(st.hoverList or {}) do
        local a = e.autoPos
        if not e.group and e.label and e.shown and a then
            local x0 = e.u * cw + a[1] - a[3] * 0.5
            local y0 = e.v * ch + a[2]
            if #items > 0 and x0 < lx1 and x0 + a[3] > lx0 and y0 < ly1 and y0 + a[4] > ly0 then
                covered[#covered + 1] = e
                e.covered = true
                setVis(e.label, e, "labelVis", VIS_COLLAPSED)
            elseif prev[e] then
                restoreLabel(e)
            end
            prev[e] = nil
        end
    end
    for e in pairs(prev) do
        if e.label and valid(e.label) and not e.group then restoreLabel(e) end
    end
    g.covered = covered
end

local function buildGroup(st, owner, now)
    if owner.isPool then openPoolList(st, owner, now); return end
    local cw, ch = st.canvasW or 1600, st.canvasH or 900
    local ox, oy = owner.u * cw, owner.v * ch
    local r = cfg("HoverGroupRadius", 1.25) * (st.pinBase or 23)
    local r2 = r * r
    local cands = {}
    for _, e in ipairs(st.hoverList or {}) do
        if e.shown and not e.isPool then
            local d2 = -1
            if e ~= owner then
                local dx, dy = e.u * cw - ox, e.v * ch - oy
                d2 = dx * dx + dy * dy
            end
            if d2 <= r2 then cands[#cands + 1] = { e = e, d = d2 } end
        end
    end
    table.sort(cands, function(a, b) return a.d < b.d end)
    local maxN = math.max(1, math.floor(cfg("HoverListMax", 12)))
    local grow = cfg("HoverPinScale", 1.4)
    local members = {}
    for i = 1, math.min(#cands, maxN) do
        local e = cands[i].e
        members[i] = e
        local isOwner = (e == owner)
        e.group = isOwner and "owner" or "member"
        local size = e.idleSize or e.size
        setPinLook(e, e.baseAlpha or 1.0, isOwner and size * grow or size)
        setPinZ(e, isOwner and Z_PIN_OWNER or Z_PIN_GROUP)
    end
    st.group = { owner = owner, members = members }
    layoutGroup(st, now)
end

local function updateHover(st, now)
    local open = st.group
    if open and open.pool and open.next <= #open.rows then fillPoolList(st, now) end
    if open and not open.pool and open.short then layoutGroup(st, now) end
    local list = st.hoverList
    if not list or #list == 0 then
        if st.group then clearGroup(st) end
        return
    end
    local cur = st.group and st.group.owner
    if cur and cur.shown and callBool(cur.pin, "IsHovered") == true then return end
    if PanelHoverWorks and not cur and callBool(st.panel, "IsHovered") ~= true then return end
    local found
    for i = 1, #list do
        local e = list[i]
        if e ~= cur and e.shown and callBool(e.pin, "IsHovered") == true then found = e; break end
    end
    if cur then clearGroup(st) end
    if found then
        if PanelHoverWorks == nil then
            PanelHoverWorks = callBool(st.panel, "IsHovered") == true
            log("Hover detected on " .. (found.isPool and ("a pool of " .. tostring(found.n)) or tostring(found.def.name))
                .. " (" .. (PanelHoverWorks and "canvas fast path" or "per-pin polling") .. ").")
            if DIAG then Obs.note("markers.hover_path", PanelHoverWorks and "canvas fast path" or "per-pin polling") end
        end
        buildGroup(st, found, now)
    end
end

-- ---------------------------------------------------------------------------
-- Map refresh
-- ---------------------------------------------------------------------------
local States, Mains, Pending, Legends = {}, {}, {}, {}
local MainGen = {}          -- address of a map screen -> how many screens were made there (told by their announcement)
local Loading, LoadingSince = false, 0

local function refresh(st, mapWidget, mapCfg, key, now)
    st.last = now
    if key ~= st.key then st.key, st.announce = key, true end
    -- the marker canvas is gone (map widget rebuilt): close what was open in it
    if st.group and not (valid(st.panel) and valid(st.general) and isChildOf(st.panel, st.general)) then
        pcall(clearGroup, st)
    end
    if not ensurePanel(st, mapWidget) then return end
    setPanelVisible(st, true)
    -- an open pool list (and the map under it) stays as it is until the
    -- mouse leaves the badge
    if st.group and st.group.pool then return end

    local tag = tagString(get(mapCfg, "MapTag")) or "?"
    local isArea = tag ~= "Area"
    local corr = cfg("ApplyCorrection", true) ~= false and correctionFor(tag) or nil
    -- Size of the map canvas in layout units: the size the game positions
    -- its own markers in (UICustomSize: 1600x900 world map, 1400x860 camp
    -- maps). The size box around the map image asks for more on the world
    -- map (3840x2160) than the screen gives it, so it is only a fallback.
    local canvasW, canvasH = vec2(get(mapCfg, "UICustomSize"))
    local canvasSrc = "UICustomSize"      -- which of the three gave the size (for the diagnostics)
    if not canvasW or canvasW <= 0 or not canvasH or canvasH <= 0 then
        local sizeBox = get(mapWidget, "MapImageSizeBox")
        canvasW = num(get(sizeBox, "WidthOverride")) or 0
        canvasH = num(get(sizeBox, "HeightOverride")) or 0
        canvasSrc = "size box"
        if canvasW <= 0 or canvasH <= 0 or canvasW > 1600 then canvasW, canvasH, canvasSrc = 1600, 900, "default" end
    end
    if DIAG then
        local kind = isArea and "area" or "world"
        local c = Obs.canvas[kind]
        if not c or c[1] ~= canvasW or c[2] ~= canvasH or c[3] ~= canvasSrc then
            Obs.canvas[kind] = { canvasW, canvasH, canvasSrc }
            Obs.note("markers.canvas_size." .. kind,
                ("%dx%d"):format(math.floor(canvasW + 0.5), math.floor(canvasH + 0.5)), canvasSrc)
        end
    end

    -- Sizes are fixed canvas units per map type, like the game's markers.
    local pinBase = isArea and cfg("AreaPinSize", cfg("PinSize", 23)) or cfg("WorldPinSize", 16)
    local otherPin = pinBase * cfg("OtherPinScale", 0.8)
    local idleAlpha = isArea and cfg("AreaPinOpacity", 0.75) or cfg("WorldPinOpacity", 0.6)
    local lmode = isArea and AreaLabels or WorldLabels
    local hoverable = cfg("HoverNames", true) ~= false
    local hoverGrow = cfg("HoverPinScale", 1.4)
    local labelScale = cfg("LabelScale", 0.39)
    local gap = cfg("LabelGap", 2)
    st.canvasW, st.canvasH, st.labelScale, st.gap = canvasW, canvasH, labelScale, gap
    st.idleAlpha, st.pinBase = idleAlpha, pinBase

    local budget0 = { left = 0, short = false }
    local box, info = selectBox(mapWidget, mapCfg, tag, corr, now)
    if not box then
        clearGroup(st)
        for _, e in pairs(st.entries) do hideEntry(e) end
        syncPools(st, {}, now, budget0, false, {}, {}, canvasW, canvasH)
        st.hoverList, st.pending = {}, false
        logOnce("nobox:" .. tag, "No bounding box available for map " .. tag .. "; pins hidden.")
        return
    end

    local ctrl = getController()
    local opts = {
        correct = cfg("ApplyCorrection", true) ~= false,
        useMask = cfg("HideOutsideAreaMask", true) ~= false and isArea,
        scale = 0.6,
    }
    local budget = tickBudget(now)
    local fallbackAlpha = cfg("FallbackOpacity", 0.55)
    local showOthersOnWorld = cfg("OtherNPCsOnWorldMap", true) ~= false
    local announce = st.announce
    local verbose = announce and cfg("Verbose", false) == true
    local reasons = verbose and {} or nil
    local live, approx, hidden, waiting, labelsShown = 0, 0, 0, 0, 0
    local shown, pinRects, labelRects, hoverList = {}, {}, {}, {}

    -- pass 1: where everyone is on this map
    local items = {}
    for _, def in ipairs(NPCs) do
        local u, v, why, mode
        if not isArea and not def.important and not showOthersOnWorld then
            why = "world-map-off"
        else
            local loc
            loc, mode = npcLocation(def, ctrl, now)
            if loc then
                u, v = Proj.Project(box, corr, loc[1], loc[2], loc[3], opts)
                if not u then why = v end
            else
                why = mode
            end
        end
        if u then
            items[#items + 1] = { def = def, u = u, v = v, mode = mode, cx = u * canvasW, cy = v * canvasH }
            if mode == "live" then live = live + 1 else approx = approx + 1 end
        else
            local e = st.entries[def.id]
            if e then hideEntry(e) end
            hidden = hidden + 1
            if reasons then reasons[#reasons + 1] = def.id .. ":" .. tostring(why) end
        end
    end

    -- world map: people standing close together share one badge
    local pools = {}
    if not isArea and cfg("WorldPools", true) ~= false then
        pools = buildPools(st, items, canvasW, canvasH)
    end

    -- badges first (few, and they stand for many people), then single pins
    local poolCount, poolPeople = syncPools(st, pools, now, budget, hoverable, hoverList, pinRects, canvasW, canvasH)
    for _, it in ipairs(items) do
        local def = it.def
        local e = st.entries[def.id]
        if it.pool then
            if e then hideEntry(e) end
        else
            e = ensureEntry(st, def, now, budget)
            if e then
                local size = def.important and pinBase or otherPin
                e.baseAlpha, e.idleSize = (it.mode == "approx") and fallbackAlpha or 1.0, size
                if DIAG then e.mode = it.mode end
                local alpha, psize = e.baseAlpha * idleAlpha, size
                if e.group then
                    alpha = e.baseAlpha
                    if e.group == "owner" then psize = size * hoverGrow end
                end
                placePin(e, it.u, it.v, psize, alpha, hoverable and VIS_VISIBLE or VIS_HIT_INVISIBLE)
                local h = size * 0.5
                local rect = { it.cx - h, it.cy - h, it.cx + h, it.cy + h }
                pinRects[#pinRects + 1] = rect
                shown[#shown + 1] = { e = e, cx = it.cx, cy = it.cy, rect = rect }
                if hoverable then hoverList[#hoverList + 1] = e end
            else
                waiting = waiting + 1
            end
        end
    end

    -- pass 2: labels where they fit (teachers / traders first)
    for _, item in ipairs(shown) do
        local e = item.e
        local pos = nil
        if lmode == "always" or lmode == "auto" then
            local lt = labelTexture(e, now, budget)
            if lt then
                local lw, lh = lt.w * labelScale, lt.h * labelScale
                local dx, dy, k = layoutLabel(item.cx, item.cy, e.idleSize, gap, lw, lh, labelRects, pinRects,
                    item.rect, e.lcand, lmode == "auto")
                if dx then
                    e.lcand = k
                    pos = e.autoPos or {}
                    pos[1], pos[2], pos[3], pos[4] = dx, dy, lw, lh
                    local x0, y0 = item.cx + dx - lw * 0.5, item.cy + dy
                    labelRects[#labelRects + 1] = { x0, y0, x0 + lw, y0 + lh }
                end
            end
        end
        e.autoPos = pos
        if not e.group and not e.covered then
            if pos then
                if ensureLabel(st, e, now, budget, Z_LABEL) then
                    setLabelZ(e, Z_LABEL)
                    placeLabel(e, e.u, e.v, pos[1], pos[2], pos[3], pos[4], VIS_HIT_INVISIBLE)
                    labelsShown = labelsShown + 1
                end
            elseif e.label then
                setVis(e.label, e, "labelVis", VIS_COLLAPSED)
            end
        end
    end
    st.hoverList = hoverList
    st.pending = budget.short
    local pending = st.pending
    if st.group then
        if not hoverable or not st.group.owner.shown then clearGroup(st) else layoutGroup(st, now) end
    end
    if DIAG then
        -- the numbers of this refresh, for the status lines and the dump
        local o = st.obs
        if not o then o = {}; st.obs = o end
        o.tag, o.src, o.live, o.approx, o.hidden = tag, canvasSrc, live, approx, hidden
        o.pins, o.pools, o.people, o.labels = #shown, poolCount, poolPeople, labelsShown
    end

    budget.short = pending
    if announce and not st.pending then
        st.announce = false
        local cal = ""
        if info.err then
            cal = (" | self-test vs game player marker: %.1f / %.1f UI px (raw / corrected, map width %d)")
                :format(info.err, info.cerr or -1, math.floor((info.uiWidth or 0) + 0.5))
            if DIAG then
                Obs.note("markers.self_test." .. (isArea and "area" or "world"), cal:match("player marker: (.*)$"),
                    ("box %s [%s]"):format(tostring(info.name), tostring(info.src)))
            end
        end
        local line = ("%s map %s (%s): box %s [%s, %d candidate(s)] | people %d live, %d approximate, %d hidden | %d single pins, %d pools with %d people, %d labels (%s) | canvas %dx%d, pin %.0f units%s")
            :format(st.which, tag, shortName(mapCfg), info.name, info.src, info.candidates, live, approx, hidden,
                #shown, poolCount, poolPeople, labelsShown, lmode, math.floor(canvasW + 0.5), math.floor(canvasH + 0.5), pinBase, cal)
        log(line)
        if DIAG then Obs.lastRefresh = line end
        if reasons and #reasons > 0 then log("  hidden: " .. table.concat(reasons, ", ")) end
    end
    if waiting > 0 and not budget.short then
        logOnce("waiting:" .. tag, ("%d pin(s) on %s could not be created (see image errors above)."):format(waiting, tag))
    end
end

local function processMap(mapWidget, which, now, main)
    local id = addrOf(mapWidget)
    local full = fullName(mapWidget)
    local st = States[id]
    -- a new map widget can get the address of one the game destroyed: what is
    -- kept for the old one (pins, lists) belongs to objects that are gone. It
    -- is told by its name, and by the map screen it belongs to having been
    -- made anew (a new screen can get the old one's address and its name).
    local screen = MainGen[addrOf(main)]
    if st and (st.full ~= full or st.screen ~= screen) then st = nil end
    if not st then
        st = { id = id, full = full, screen = screen, which = which, entries = {}, pools = {}, hoverList = {}, last = -1e9 }
        States[id] = st
    end
    st.widget, st.main = mapWidget, main
    local visible = callBool(mapWidget, "IsVisible")
    local background = cfg("HideOnBackgroundMap", true) ~= false and get(mapWidget, "IsBackground") == true
    if visible == false or background then
        if st.group then clearGroup(st) end
        setPanelVisible(st, false)
        st.active = false
        return
    end
    local mapCfg = get(mapWidget, "m_ActiveMapData")
    if not valid(mapCfg) then
        if st.group then clearGroup(st) end
        setPanelVisible(st, false)
        st.active = false
        return
    end
    local key = fullName(mapCfg)
    if not st.active or key ~= st.key or st.pending or (now - st.last) >= cfg("RefreshSeconds", 2.0) then
        local op = opBegin("markers: refresh " .. tostring(which) .. " " .. tostring(key:match("([^%.:/]+)$") or key))
        local ok, err = pcall(refresh, st, mapWidget, mapCfg, key, now)
        opEnd(op)
        if not ok then
            st.pending = false
            logError("refresh:" .. tostring(err), "Map refresh failed: " .. tostring(err))
        end
    end
    st.active = true
    local op = opBegin("markers: pins under the mouse on " .. tostring(which) .. " (" .. #(st.hoverList or {}) .. " pins)")
    local ok, err = pcall(updateHover, st, now)
    opEnd(op)
    if not ok then logError("hover:" .. tostring(err), "Hover update failed: " .. tostring(err)) end
end

-- Colour key at the bottom-left of the map screen. It sits in a canvas of
-- this mod inside the screen's content overlay, so its size is exactly what
-- is set here. The game's own button row occupies the bottom right: the key
-- goes on that row when there is room to its left, is made smaller when the
-- room is a little short, and goes below the row otherwise.
local function buttonRowSize(main)
    for _, name in ipairs({ "Button_Close", "Button_Marker", "Button_Filters", "Button_Back" }) do
        local b = get(main, name)
        if valid(b) then
            local row = call(b, "GetParent")
            if valid(row) then
                local w, h = vec2(call(row, "GetDesiredSize"))
                if w and h and w >= 0 and h >= 0 then return w, h end
            end
        end
    end
    return nil
end

-- diagnostics only: where the colour key ended up, noted when that changes
-- ("on the button row" | "shrunk" | "below the row" | "fixed position" | "not shown")
function Obs.legend(where, w, h, why)
    if where == Obs.legendWhere and w == Obs.legendW and h == Obs.legendH and why == Obs.legendWhy then return end
    Obs.legendWhere, Obs.legendW, Obs.legendH, Obs.legendWhy = where, w, h, why
    Obs.note("markers.legend", where, w and ("%.1fx%.1f"):format(w, h) or why)
end
-- diagnostics only: the size of the game's button row ("not found" when it has none)
function Obs.buttonRow(w, h)
    if Obs.rowSeen and w == Obs.rowW and h == Obs.rowH then return end
    Obs.rowSeen, Obs.rowW, Obs.rowH = true, w, h
    Obs.note("markers.button_row", (w and h) and ("%dx%d"):format(math.floor(w + 0.5), math.floor(h + 0.5)) or "not found")
end

local function updateLegend(main, now)
    if cfg("ShowLegend", true) == false or #NPCs == 0 then
        if DIAG then Obs.legend("not shown", nil, nil, #NPCs == 0 and "no NPC to show" or "switched off in config.lua") end
        return
    end
    local key = addrOf(main)
    local mainFull = fullName(main)
    local L = Legends[key]
    if L and L.mainFull ~= mainFull then L = nil end          -- another screen at the address of an old one
    if L and L.failedAt and now - L.failedAt < 30.0 then return end
    if not (L and L.img and valid(L.img.img) and valid(L.canvas) and valid(L.overlay) and isChildOf(L.canvas, L.overlay)) then
        Legends[key] = { failedAt = now, mainFull = mainFull }
        local overlay = get(main, "Overlay_Content")
        if not valid(overlay) then overlay = call(call(get(main, "Map_World"), "GetParent"), "GetParent") end
        if not valid(overlay) or not fullName(overlay):match("^Overlay ") then
            logOnce("legend-parent", "Colour key: map screen layout not as expected; key not shown.")
            if DIAG then Obs.legend("not shown", nil, nil, "map screen layout not as expected") end
            return
        end
        local tree = get(main, "WidgetTree")
        local tex = loadTexture(look("Assets/legend.png"), now)
        if not tex or not valid(tree) then
            if DIAG then Obs.legend("not shown", nil, nil, tex and "no widget tree" or "image not loaded") end
            return
        end
        local canvas = newWidget("/Script/UMG.CanvasPanel", tree)
        if not canvas then
            if DIAG then Obs.legend("not shown", nil, nil, "canvas not created") end
            return
        end
        local slot = call(overlay, "AddChildToOverlay", canvas)
        if not valid(slot) then
            wcall(canvas, "RemoveFromParent")
            logOnce("legend-add", "Colour key: could not attach the key.")
            if DIAG then Obs.legend("not shown", nil, nil, "could not attach the key") end
            return
        end
        wcall(slot, "SetHorizontalAlignment", 0)   -- HAlign_Fill
        wcall(slot, "SetVerticalAlignment", 0)     -- VAlign_Fill
        wcall(canvas, "SetVisibility", VIS_HIT_INVISIBLE)
        local img = canvasImage(canvas, tree, 1)
        if not img then
            wcall(canvas, "RemoveFromParent")
            if DIAG then Obs.legend("not shown", nil, nil, "image widget not created") end
            return
        end
        wcall(img.slot, "SetAnchors", anchors(0, 1))        -- from the bottom-left corner
        wcall(img.slot, "SetAlignment", { X = 0, Y = 1 })
        L = { canvas = canvas, overlay = overlay, img = img, tex = tex, at = -1e9, mainFull = mainFull }
        Legends[key] = L
    end
    if now - L.at < 1.0 then return end
    L.at = now
    local base = cfg("LegendScale", 1.0) * 0.5      -- the image is drawn at 2x
    local w, h = L.tex.w * base, L.tex.h * base
    local left, bottom = cfg("LegendLeft", 100), cfg("LegendBottom", 50)
    local y = bottom
    local placed = "fixed position"     -- how the key was placed (for the diagnostics)
    if cfg("LegendAvoidButtons", true) ~= false then
        local rowW, rowH = buttonRowSize(main)
        if DIAG then Obs.buttonRow(rowW, rowH) end
        rowW, rowH = rowW or 900, rowH or 44
        local contentW = vec2(call(L.overlay, "GetDesiredSize"))
        if not contentW or contentW < 800 then contentW = 1600 end
        -- the row is right-aligned 100 units from the edge and drawn at 0.9
        local rowLeft = contentW - 100 - rowW * 0.95
        local room = rowLeft - 16 - left
        placed = "on the button row"
        if w > room and room >= w * 0.72 then
            w, h = room, h * room / w
            placed = "shrunk"
        end
        if w <= room then
            y = bottom + math.max(0, (rowH - h) * 0.5)              -- centred on the row
        else
            y = math.max(4, (bottom + rowH * 0.05 - h) * 0.5)       -- in the strip below the row
            placed = "below the row"
        end
    end
    local legendTex = loadTexture(look("Assets/legend.png"), now)
    if not (legendTex and placeCanvasImage(L.img, left, -y, w, h, legendTex, 1.0)) then
        hideCanvasImage(L.img)
        if DIAG then Obs.legend("not shown", nil, nil, "image not loaded") end
        return
    end
    L.tex = legendTex
    L.where = { left, y, w, h }
    if DIAG then
        L.placed = placed
        Obs.legend(placed, w, h)
    end
end

local function processMain(main, now)
    local active = callBool(main, "IsActivated")
    if active == nil then active = callBool(main, "IsVisible") end
    if not active then
        for _, which in ipairs({ "Map_World", "Map_Area" }) do
            local w = get(main, which)
            if w then
                local st = States[addrOf(w)]
                if st then
                    if st.group then pcall(clearGroup, st) end
                    st.active = false
                end
            end
        end
        return
    end
    local ok, err = pcall(updateLegend, main, now)
    if not ok then logError("legend:" .. tostring(err), "Colour key failed: " .. tostring(err)) end
    for _, which in ipairs({ "Map_World", "Map_Area" }) do
        local w = get(main, which)
        if valid(w) then processMap(w, which, now, main) end
    end
end

local function rememberMain(main, how)
    if not valid(main) then return end
    local n = fullName(main)
    if n:find("Default__", 1, true) then return end
    local key = addrOf(main)
    if how == "notification" or Mains[key] == nil then
        -- a map screen that was not there before (the game makes one for every opening): what is kept
        -- of an earlier one at this address is not its, and pictures that are not kept alive were the
        -- earlier screens'
        MainGen[key] = (MainGen[key] or 0) + 1
        ScreenGen = ScreenGen + 1
        Legends[key] = nil
    end
    Mains[key] = main
    if DIAG and Obs.facts["markers.map_found_by"] ~= how then Obs.note("markers.map_found_by", how) end
end

-- How a map screen is found. The game makes one for every opening and UE4SS
-- announces every new object of its class (NotifyOnNewObject): with that
-- registered, nothing is searched for. A search for the screen is a walk
-- through all objects of the game in the middle of play - up to 2.3 it was
-- made a few times after every map load and then every 30 s while no map
-- was known, and in a logged session of 140 minutes it never found a screen
-- the announcement had not brought (megamod: dev/FACTS.md, M14, U14).
-- Only where the announcement cannot be had are screens searched for, on
-- the old schedule.
local NotifyOk = false          -- UE4SS took the registration (set at the end of this file)
local DISCOVERY_STEPS = { 2.0, 10.0, 30.0 }
local DiscoveryBase, DiscoveryStep, NextDiscover = nil, 1, 0
local function scheduleDiscovery(now)
    if DiscoveryBase == nil then DiscoveryBase = now end
    local step = DISCOVERY_STEPS[DiscoveryStep]
    if step then
        NextDiscover = DiscoveryBase + step
        DiscoveryStep = DiscoveryStep + 1
    else
        NextDiscover = now + 30.0
    end
end

local function tick()
    local now = os.clock()
    if Loading then
        if now - LoadingSince < 30.0 then return end
        Loading = false -- failsafe if the post-load hook never fires
    end
    if #Pending > 0 then
        local list = Pending
        Pending = {}
        for _, m in ipairs(list) do rememberMain(m, "notification") end
    end
    local any = false
    for id, main in pairs(Mains) do
        if valid(main) then any = true else Mains[id] = nil end
    end
    if not NotifyOk then
        if DiscoveryBase == nil then scheduleDiscovery(now) end
        if not any and now >= NextDiscover then
            scheduleDiscovery(now)
            for _, m in pairs(findAll("W_Map_Main_C")) do rememberMain(m, "scan") end
        end
    end
    for _, main in pairs(Mains) do processMain(main, now) end
    if DIAG and Obs.texGen ~= Obs.texNoted and now - Obs.texAt >= 2.0 then Obs.textures() end
end

local function resetSession()
    States, Mains, Pending, Legends = {}, {}, {}, {}
    MainGen = {}
    NpcRetry, LocMemo = {}, {}
    -- pictures that are kept alive stay loaded for the run; the others were the old world's screens'
    ScreenGen = ScreenGen + 1
    for rel, t in pairs(Textures) do
        if not t.held then Textures[rel] = nil end
    end
    TextureFail = {}
    -- (StaticLookupOk stays: that the game's own lookup of a person works is true for the whole run, and
    -- without it the first person the game does not know after a map load would be searched for among all
    -- objects - megamod: dev/FACTS.md, M15)
    StaticLookupBroken, NpcCDO = false, nil
    ScanIndex = { at = -1e9, map = {} }
    BoxCache = { at = -1e9, list = {} }
    CachedController = nil
    DiscoveryBase, DiscoveryStep, NextDiscover = nil, 1, 0
end

-- ---------------------------------------------------------------------------
-- Registration (each exactly once)
-- ---------------------------------------------------------------------------
local HavePostHook = false
if type(RegisterLoadMapPostHook) == "function" then
    HavePostHook = pcall(RegisterLoadMapPostHook, function()
        Loading = false
    end)
end
if type(RegisterLoadMapPreHook) == "function" then
    pcall(RegisterLoadMapPreHook, function()
        if HavePostHook then
            Loading, LoadingSince = true, os.clock()
        end
        resetSession()
    end)
end
if type(NotifyOnNewObject) == "function" then
    NotifyOk = pcall(NotifyOnNewObject, "/Game/UI/ManagementUI/Map/W_Map_Main.W_Map_Main_C", function(obj)
        Pending[#Pending + 1] = obj
    end)
end
if DIAG then
    if NotifyOk then Obs.note("markers.map_screens", "announced") else Obs.note("markers.map_screens", "searched for", "UE4SS did not take the registration") end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; markers disabled.")
    return
end
LoopInGameThreadWithDelay(150, function()
    local ok, err = pcall(tick)
    if not ok then logError("tick:" .. tostring(err), "Update error: " .. tostring(err)) end
end)

log(("v%s loaded: %d named NPCs (%d teachers/traders) from %s | labels: camp maps=%s, world map=%s | pins %s / %s units | world-map pools %s"):format(
    VERSION, #NPCs, ImportantCount, NpcSource, AreaLabels, WorldLabels,
    tostring(cfg("AreaPinSize", cfg("PinSize", 23))), tostring(cfg("WorldPinSize", 16)),
    cfg("WorldPools", true) ~= false and ("on (from %d people, %s units apart)"):format(math.max(2, math.floor(cfg("PoolMinSize", 4))),
        tostring(cfg("PoolLinkDistance", 26))) or "off"))

-- Megamod diagnostics: status lines for its reports and a picture of the map
-- states for its dump command. Both are built from what the mod already holds
-- (plain Lua values of the last refresh); neither touches the game.
if DIAG then
    local function mapStates()
        local list = {}
        for _, st in pairs(States) do list[#list + 1] = st end
        table.sort(list, function(a, b)
            if a.which ~= b.which then return tostring(a.which) < tostring(b.which) end
            return tostring(a.id) < tostring(b.id)
        end)
        return list
    end
    pcall(function()
        DIAG.status(function()
            local lines = {
                ("v%s | %d named NPCs (%d teachers/traders) from %s"):format(VERSION, #NPCs, ImportantCount, NpcSource),
                "last map refresh: " .. (Obs.lastRefresh or "none yet"),
            }
            local any = false
            for _, st in ipairs(mapStates()) do
                local o = st.obs
                if o then
                    any = true
                    lines[#lines + 1] = ("%s %s%s: %d single pins, %d pools with %d people, %d labels | people %d live, %d approximate, %d hidden")
                        :format(tostring(st.which), tostring(o.tag), st.active and "" or " (closed)",
                            o.pins, o.pools, o.people, o.labels, o.live, o.approx, o.hidden)
                end
            end
            if not any then lines[#lines + 1] = "no map refreshed yet since the last load" end
            lines[#lines + 1] = ("pictures: %d loaded (%d kept alive for the whole run), %d loaded again; images: %d did not take their picture, %d given a new loading of it")
                :format(Tex.loaded, Tex.kept, Tex.again, Tex.bindFailed, Tex.rebound)
            return lines
        end)
        DIAG.dump(function()
            local maps, pins, pools, legend, facts = {}, {}, {}, {}, {}
            for i, st in ipairs(mapStates()) do
                local o = st.obs or {}
                local cw, ch = st.canvasW, st.canvasH
                maps[i] = {
                    which = tostring(st.which), map = st.key, tag = o.tag, active = st.active == true,
                    canvas_w = cw, canvas_h = ch, canvas_source = o.src, pin_size = st.pinBase,
                    single_pins = o.pins, pools = o.pools, people_in_pools = o.people, labels = o.labels,
                    live = o.live, approximate = o.approx, hidden = o.hidden,
                }
                if cw and ch then
                    for _, def in ipairs(NPCs) do
                        local e = st.entries[def.id]
                        if e and e.shown and e.u and e.v then
                            pins[#pins + 1] = {
                                map = i, id = def.id, name = tostring(def.name), kind = def.kind,
                                x = e.u * cw, y = e.v * ch, mode = e.mode == "approx" and "approximate" or "live",
                            }
                        end
                    end
                    local keys = {}
                    for key, p in pairs(st.pools) do
                        if p.shown then keys[#keys + 1] = key end
                    end
                    table.sort(keys)
                    for _, key in ipairs(keys) do
                        local p = st.pools[key]
                        local ids = {}
                        for j, it in ipairs(p.items or {}) do ids[j] = it.def.id end
                        pools[#pools + 1] = {
                            map = i, count = p.n, x = p.cx, y = p.cy, members = ids,
                            teacher = p.teach == true, trader = p.trade == true,
                        }
                    end
                end
            end
            local lkeys = {}
            for key, L in pairs(Legends) do
                if L.where then lkeys[#lkeys + 1] = key end
            end
            table.sort(lkeys)
            for _, key in ipairs(lkeys) do
                local L = Legends[key]
                legend[#legend + 1] = { placed = L.placed, left = L.where[1], bottom = L.where[2], w = L.where[3], h = L.where[4] }
            end
            local fkeys = {}
            for key in pairs(Obs.facts) do fkeys[#fkeys + 1] = key end
            table.sort(fkeys)
            for _, key in ipairs(fkeys) do
                facts[#facts + 1] = { key = key, value = Obs.facts[key], detail = Obs.details[key] }
            end
            return { version = VERSION, npcs = #NPCs, maps = maps, pins = pins, pools = pools, legend = legend, facts = facts,
                pictures = { loaded = Tex.loaded, kept_alive = Tex.kept, loaded_again = Tex.again, not_taken = Tex.bindFailed,
                    given_new_loading = Tex.rebound, brush_read_back = BrushReadable == true, map_screens = ScreenGen } }
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "NPCMARKERS_TEST")) == "table" then
    local T = rawget(_G, "NPCMARKERS_TEST")
    T.state = function(w) return States[addrOf(w)] end
    T.npcs = NPCs
    T.legend = function(main) return Legends[addrOf(main)] end
    T.pngSize = pngSize
    T.pictures = function() return Tex, Textures, ScreenGen end
    T.poolImage = poolImageFor
end
