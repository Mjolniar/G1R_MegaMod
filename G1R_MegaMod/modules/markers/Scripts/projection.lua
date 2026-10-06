-- NPCMarkers projection: pure Lua, no Unreal calls (unit-tested offline).
--
-- Mirrors Gothic 1 Remake's own map math, recovered from the shipping
-- G1R-Win64-Shipping.exe (CL174209):
--   UMapData::GetNormalized2DPositionAndRotationFromActor
--       pos = BoxTransform.InverseTransformPosition(ActorLocation).XY * 0.02
--       (the bounding-box actor is a 100-unit cube; pos is -1..1 inside it)
--   UMapWidget position correction (scale member = 0.6f)
--       pixel  = (pos + 1) / 2 * CorrectionTextureSize, truncated
--       offset = (R, G) / 255 * 1.2 - 0.6   (B channel is an area mask)
--       pos'   = pos + offset
--   Marker UV on the map canvas = (pos' + 1) / 2

local P = {}

local rad, sin, cos, abs = math.rad, math.sin, math.cos, math.abs

local function trunc(x)
    if x >= 0 then return math.floor(x) end
    return math.ceil(x)
end
P.trunc = trunc

-- Unreal FRotationMatrix axes for a rotator in degrees.
function P.Axes(pitch, yaw, roll)
    local p, y, r = rad(pitch or 0), rad(yaw or 0), rad(roll or 0)
    local SP, CP, SY, CY, SR, CR = sin(p), cos(p), sin(y), cos(y), sin(r), cos(r)
    local X = { CP * CY, CP * SY, SP }
    local Y = { SR * SP * CY - CR * SY, SR * SP * SY + CR * CY, -SR * CP }
    return X, Y
end

-- box = { loc = {x,y,z}, rot = {pitch,yaw,roll}, scale = {x,y,z} }
-- Returns the game's normalized map position (-1..1 inside the box).
function P.Normalize(box, x, y, z)
    local dx, dy, dz = x - box.loc[1], y - box.loc[2], (z or 0) - box.loc[3]
    local AX, AY = P.Axes(box.rot[1], box.rot[2], box.rot[3])
    local lx = dx * AX[1] + dy * AX[2] + dz * AX[3]
    local ly = dx * AY[1] + dy * AY[2] + dz * AY[3]
    local sx, sy = box.scale[1], box.scale[2]
    lx = (abs(sx) > 1e-8) and (lx / sx) or 0.0
    ly = (abs(sy) > 1e-8) and (ly / sy) or 0.0
    return lx * 0.02, ly * 0.02
end

-- Correction data: "NMC1", u16 W, u16 H, then per row: u16 runs, runs * (u16 len, u8 R, u8 G, u8 B)
function P.ParseCorrection(bytes)
    if type(bytes) ~= "string" or bytes:sub(1, 4) ~= "NMC1" then return nil, "bad header" end
    local W, H, pos = string.unpack("<I2I2", bytes, 5)
    local rowOff = {}
    for y = 0, H - 1 do
        rowOff[y] = pos
        local n = string.unpack("<I2", bytes, pos)
        pos = pos + 2 + n * 5
        if pos > #bytes + 1 then return nil, "truncated at row " .. y end
    end
    return { W = W, H = H, bytes = bytes, rowOff = rowOff }
end

function P.LoadCorrection(path)
    local f = io.open(path, "rb")
    if not f then return nil, "missing " .. tostring(path) end
    local bytes = f:read("a")
    f:close()
    return P.ParseCorrection(bytes)
end

-- Raw texel at integer pixel (x, y); returns R, G, B.
function P.Texel(corr, x, y)
    local bytes = corr.bytes
    local pos = corr.rowOff[y]
    local n = string.unpack("<I2", bytes, pos)
    pos = pos + 2
    local acc = 0
    for _ = 1, n do
        local len, r, g, b = string.unpack("<I2BBB", bytes, pos)
        acc = acc + len
        if x < acc then return r, g, b end
        pos = pos + 5
    end
    return 128, 128, 0
end

-- Applies the game's correction to a normalized position.
-- Returns corrected x, y, mask byte (B) and whether a texel was sampled.
function P.Correct(corr, x, y, scale)
    if not corr then return x, y, 0, false end
    scale = scale or 0.6
    local W, H = corr.W, corr.H
    local px = (x + 1.0) * 0.5 * W
    local py = (y + 1.0) * 0.5 * H
    local idx = trunc(py) * W + trunc(px)
    if idx < 0 or idx >= W * H then return x, y, 0, false end
    local r, g, b = P.Texel(corr, idx % W, idx // W)
    local ox = r / 255.0 * (2.0 * scale) - scale
    local oy = g / 255.0 * (2.0 * scale) - scale
    return x + ox, y + oy, b, true
end

-- Area mask (B channel) at a normalized position; >= 128 means "not drawn on this map".
-- The game performs this test at the corrected position.
function P.Mask(corr, x, y)
    if not corr then return 0 end
    local W, H = corr.W, corr.H
    local idx = trunc((y + 1.0) * 0.5 * H) * W + trunc((x + 1.0) * 0.5 * W)
    if idx < 0 or idx >= W * H then return 255 end
    local _, _, b = P.Texel(corr, idx % W, idx // W)
    return b
end

function P.ToUV(x, y)
    return (x + 1.0) * 0.5, (y + 1.0) * 0.5
end

-- Full pipeline for one world location. Returns u, v, info or nil, reason.
function P.Project(box, corr, wx, wy, wz, opts)
    opts = opts or {}
    local x, y = P.Normalize(box, wx, wy, wz)
    if x < -1.0 or x > 1.0 or y < -1.0 or y > 1.0 then
        return nil, "outside"
    end
    local cx, cy, mask, sampled = x, y, 0, false
    if opts.correct ~= false then
        cx, cy, mask, sampled = P.Correct(corr, x, y, opts.scale)
    end
    if opts.useMask and corr and P.Mask(corr, cx, cy) >= 128 then
        return nil, "masked"
    end
    local u, v = P.ToUV(cx, cy)
    if u < 0 or u > 1 or v < 0 or v > 1 then
        return nil, "outside"
    end
    return u, v, { rawX = x, rawY = y, corrX = cx, corrY = cy, mask = mask, sampled = sampled }
end

return P
