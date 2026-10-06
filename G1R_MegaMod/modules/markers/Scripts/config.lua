-- ============================================================================
-- NPCMarkers 2.3 configuration (rebuilt local version)
-- Pins follow each NPC's real position and use the game's own map projection.
-- The NPC list itself is in npcs.lua (all named NPCs of the game).
-- ============================================================================
local Config = {}

-- Labels:
--   "always" = every name, stacked when crowded
--   "auto"   = names that fit without covering other names or pins;
--              the rest appear when you hover a pin
--   "hover"  = names only while the mouse is over a pin
--   "off"    = no names (hover lists still work while HoverNames = true)
Config.AreaLabels = "auto"    -- camp maps
Config.WorldLabels = "hover"  -- world map
-- Letters of the names: "game" = the game's own text letters, "gothic" =
-- blackletter.
Config.NameLetters = "game"

-- Hovering a pin makes it and every pin around it opaque and lists their
-- names under the hovered pin (teachers/traders first by distance).
Config.HoverNames = true
Config.HoverGroupRadius = 1.25  -- "around" = within this many pin sizes
Config.HoverListMax = 12        -- at most this many names per list
Config.HoverPinScale = 1.4      -- the hovered pin grows by this factor

-- Look of the pins, badges, names and colour key: "drawn" = inked onto the
-- map by hand in the colours of its watercolours, the names written in
-- ink; "classic" = coloured dots in black rings, names on white plates.
Config.PinLook = "drawn"

-- Pin sizes in map canvas units (teachers/traders; others are smaller).
-- One unit is one pixel on a 1920x1080 screen; the world map is 1600 units
-- wide, a camp map 1400.
Config.AreaPinSize = 23   -- camp maps
Config.WorldPinSize = 16  -- world map
Config.OtherPinScale = 0.8
-- Pin opacity until hovered (1 = solid).
Config.AreaPinOpacity = 0.75
Config.WorldPinOpacity = 0.6
-- Label image scale and gap to the pin (canvas units).
Config.LabelScale = 0.39
Config.LabelGap = 2

-- World map: people standing close together are drawn as one badge with
-- their number (a "pool"); hovering the badge lists everyone there, teachers
-- and traders first. A small blue / yellow dot on the badge means a teacher /
-- trader is among them. People on their own keep their own pin.
Config.WorldPools = true
Config.PoolLinkDistance = 26  -- two people this close (canvas units) are at the same place
Config.PoolMinSize = 4        -- fewer people than this keep their own pins
Config.PoolPinSize = 26       -- badge size
Config.PoolOpacity = 0.9      -- badge opacity until hovered
Config.PoolListRows = 16      -- names per column in a pool's list
Config.PoolListMax = 96       -- at most this many names per list

-- Colour key at the bottom-left of the map screen. It goes on the row of
-- the game's own buttons when there is room to their left, is made a little
-- smaller when the room is short, and goes below that row otherwise
-- (LegendAvoidButtons = false: always at LegendLeft / LegendBottom).
Config.ShowLegend = true
Config.LegendScale = 1.0
Config.LegendLeft = 100
Config.LegendBottom = 50
Config.LegendAvoidButtons = true

-- Which NPCs to show.
Config.ShowOtherNPCs = true        -- false = teachers and traders only
Config.OtherNPCsOnWorldMap = true  -- false = other NPCs only on camp maps
Config.ShowOrcs = true             -- Ur-Shak, Tarrok, the free-mine orcs, ...
-- Unique ids (see npcs.lua) to never show, e.g. { "NC_ORG_Lares_801" }.
Config.HideIds = {}
-- Extra NPCs by unique id, e.g.
--   { id = "SOME_UNIQUE_ID", name = "Someone", kind = "teacher" }
-- (kind: "teacher", "trader", "both" or "other"; no label image unless
--  label = "Assets/Labels/<file>.png" is given).
Config.ExtraNPCs = {}

-- Seconds between position refreshes while a map is open.
Config.RefreshSeconds = 2.0
-- New pin/label widgets created per update step (spreads the first map
-- open over a few frames instead of one long hitch).
Config.MaxNewWidgetsPerTick = 24

-- When an NPC's live state cannot be found (not yet created by the game),
-- show a semi-transparent pin at that NPC's usual routine spot instead
-- (only NPCs with a known spot, see "fallback" in npcs.lua).
Config.ShowFallbackPins = true
Config.FallbackOpacity = 0.55

-- Hide pins of dead or removed NPCs.
Config.HideDeadNPCs = true

-- Apply the game's hand-drawn-map correction texture (should stay true).
Config.ApplyCorrection = true
-- On camp/area maps, hide pins that fall outside the drawn parchment.
Config.HideOutsideAreaMask = true
-- Hide pins on the dimmed world map shown behind an open area map.
Config.HideOnBackgroundMap = true

-- Extra diagnostic lines in UE4SS.log (hidden NPCs and why, once per map).
Config.Verbose = false

return Config
