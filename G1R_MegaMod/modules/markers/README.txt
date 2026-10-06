Module "markers" (NPCMarkers 2.7) - Gothic 1 Remake, UE4SS Lua
===============================================================

What it does
  Open the map (M). Every named NPC of the game (181, see Scripts/npcs.lua)
  is shown where that NPC actually is right now:
    blue pin            teacher        name "(T)- Name"
    gold pin            trader         name "(M)- Name"
    blue/gold pin       both           name "(T/M)- Name"
    red pin (smaller)   other named NPC
    green pin (smaller) orc
  The look (setting PinLook): "drawn" (default) - the pins are inked onto the
  map by hand, an ink ring around a watercolour wash in the old pigments
  (woad blue, ochre, red ochre, verdigris), the groups' numbers written in
  ink in a double ring, the names in ink on a patch of cleared paper, the
  colour key on a strip of parchment - the look of the game's own maps;
  "classic" - the coloured dots in black rings and the white name plates.
  The names are in the game's own text letters (Noto Serif; setting
  NameLetters "gothic" for blackletter).
  A small colour key sits at the bottom-left of the map screen, left of
  the game's own buttons (below them when there is no room).
  Works on the world map and on the camp maps (Old Camp, New Camp, Swamp
  Camp, Orc Enclave, Sleeper Temple). Dead NPCs are hidden. NPCs the game
  has not created yet are hidden, except a few with a known routine spot,
  which are shown faded there.

Overlap handling
  World map: people standing close together are one badge with their
  number (a "pool"; from 4 people, at most 26 map units apart from the next
  one). Hover the badge: everyone there is listed next to it, teachers and
  traders first. A blue / yellow dot on the badge means a teacher / trader
  is among them. A badge never sits under one of the game's camp names.
  People on their own keep a pin of their own (semi-transparent, no
  permanent name).
  Camp maps: normal pins, slightly transparent; a name is shown only where
  it fits without covering another name or pin.
  Hover any pin: it and every pin around it turn solid and their names are
  listed under the mouse (names the list would cover are hidden meanwhile).

Changes
  2.7  the drawn look (PinLook "drawn", the default): the pictures of
       Scripts/Assets/Drawn (469, the same names and sizes as the classic
       ones; drawn by dev/tools/drawn/drawn.py); a picture that is not there
       is the classic one. PinLook and NameLetters in config.lua and the
       settings app (page Map > Map pins)
  2.6  the names on the map in the game's own text letters again, whatever
       the megamod's letters are (setting NameLetters: "game", or "gothic"
       for the blackletter pictures of 2.5)
  2.5  the names in blackletter pictures while the megamod's letters are
       gothic
  2.4  stability: the pictures of the pins are kept alive for the whole
       game run (a pin could be painted with a picture the game had thrown
       away - a crash of 2026-10-04); a pin or name is shown only once its
       image has taken its picture (no white boxes); the name list of a
       crowded spot is built over several updates; the map screen is no
       longer searched for among all objects (UE4SS announces every new
       one), nor are people the game does not know right after a map load.
       Nothing looks different.
  2.3  world map: pools with a name list on hover, pins 16 instead of 8
       units (sizes were computed for a 3840-wide map; it is 1600 wide);
       colour key at its intended size (was drawn twice as large) and clear
       of the game's button row
  2.2  tiny world-map pins, transparency until hovered, hover name lists,
       names only where they fit on camp maps, colour key
  2.1  same pin size on all maps (was 2.7x on the world map); all 181 named
       NPCs (was 12); names from the game's localization, teacher/trader
       roles from its glossary; lazy widget creation
  2.0  pins at the NPCs' live positions with the game's own map projection

How pins are placed
  Same math the game uses for the player arrow (recovered from
  G1R-Win64-Shipping.exe with the help of the GORE toolkit):
    position = map bounding box inverse transform of the NPC location * 0.02
    corrected = position + (R,G of the map's correction texture)/255*1.2 - 0.6
  The correction textures are bundled in Scripts/data (exported with GORE).
  Pins live in their own canvas on the map, so the game's markers, filters,
  hover animations and saves are never touched. Nothing is written to saves.

Settings: Scripts/config.lua
  PinLook                      "drawn" (default) | "classic"
  NameLetters                  "game" (default) | "gothic"
  AreaLabels, WorldLabels      "always" | "auto" | "hover" | "off"
  HoverNames, HoverGroupRadius, HoverListMax, HoverPinScale
  AreaPinSize, WorldPinSize, OtherPinScale, AreaPinOpacity, WorldPinOpacity
  WorldPools, PoolLinkDistance, PoolMinSize, PoolPinSize, PoolOpacity,
  PoolListRows, PoolListMax
  LabelScale, LabelGap, ShowLegend, LegendScale, LegendLeft, LegendBottom,
  LegendAvoidButtons
  ShowOtherNPCs, OtherNPCsOnWorldMap, ShowOrcs, HideIds, ExtraNPCs
  RefreshSeconds, MaxNewWidgetsPerTick, ShowFallbackPins, FallbackOpacity,
  HideDeadNPCs, Verbose

Log lines to look for in UE4SS.log
  [NPCMarkers] v2.7.0 loaded: 181 named NPCs (52 teachers/traders) ...
  [NPCMarkers] Map_World map Area (...): ... | N single pins, N pools with
               N people ... | canvas 1600x900, pin 16 units
  [NPCMarkers] Hover detected on <name | a pool of N> (canvas fast path |
               per-pin polling)
  The self-test numbers (A / B UI px) compare this mod's math with the
  game's own player arrow; values near 0 mean an exact match.
