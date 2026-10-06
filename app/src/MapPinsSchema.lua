-- ============================================================================
-- The settings of the module "markers" (the pins on the map screens), described
-- for the settings app in the form of a schema.lua (dev/SETTINGS.md of the mod).
--
-- This file is part of the settings app, not of the mod: the module has no
-- schema.lua, reads its Scripts/config.lua itself when the game starts and
-- checks nothing but the kind of a value. So the ranges below are what the
-- app's controls offer, not rules of the game; a value in the file that lies
-- outside them stays as it is until it is changed in the app.
-- Not described: Config.HideIds and Config.ExtraNPCs (lists; edited in the file).
-- ============================================================================
local Schema = {}

Schema.Module = "markers"
Schema.Page = "Map"
Schema.PageOrder = 60
Schema.Notes = {
    "The map pins read their settings when the game starts: a change made here counts from the next start of the game.",
    "Sizes and distances are in map units. One unit is one pixel on a 1920 x 1080 screen; the world map is 1600 units wide, a camp map 1400.",
    "Two lists are edited in the file itself (modules\\markers\\Scripts\\config.lua of the mod): Config.HideIds, people who are never shown, and Config.ExtraNPCs, people to add. The app leaves them as they are.",
}

Schema.Groups = {
    {
        Title = "Names on the maps",
        Order = 10,
        Hint = "always: every name, stacked where it is crowded. auto: the names that fit without covering other names or pins; the rest appear when you hover a pin. hover: names only while the mouse is over a pin. off: no names (the lists on hovering still work).",
        Items = {
            { Key = "AreaLabels", Kind = "choice", Default = "auto", Options = { "always", "auto", "hover", "off" },
              Label = "Names on the camp maps" },
            { Key = "WorldLabels", Kind = "choice", Default = "hover", Options = { "always", "auto", "hover", "off" },
              Label = "Names on the world map" },
            { Key = "LabelScale", Kind = "number", Default = 0.39, Min = 0.1, Max = 2, Decimals = 2, Step = 0.01,
              Label = "Scale of the names",
              Comment = "The names are images; 0.39 is the size they were made for." },
            { Key = "LabelGap", Kind = "number", Default = 2, Min = 0, Max = 50,
              Label = "Gap between a pin and its name", Unit = "units" },
            { Key = "NameLetters", Kind = "choice", Default = "game", Options = { "game", "gothic" },
              Label = "Letters of the names",
              Comment = "game: the game's own text letters. gothic: blackletter." },
        },
    },
    {
        Title = "Hovering a pin",
        Order = 20,
        Hint = "Hovering a pin makes it and every pin around it solid and lists their names under the mouse, teachers and traders first.",
        Items = {
            { Key = "HoverNames", Kind = "bool", Default = true,
              Label = "List the names around a hovered pin" },
            { Key = "HoverGroupRadius", Kind = "number", Default = 1.25, Min = 0.25, Max = 10, Decimals = 2, Step = 0.25, Needs = "HoverNames",
              Label = "\"Around\" means within", Unit = "pin sizes" },
            { Key = "HoverListMax", Kind = "number", Default = 12, Min = 1, Max = 100, Needs = "HoverNames",
              Label = "A list has at most", Unit = "names" },
            { Key = "HoverPinScale", Kind = "number", Default = 1.4, Min = 1, Max = 4, Decimals = 2, Step = 0.1, Needs = "HoverNames",
              Label = "The hovered pin grows to", Unit = "times its size" },
        },
    },
    {
        Title = "Pins",
        Order = 30,
        Items = {
            { Key = "PinLook", Kind = "choice", Default = "drawn", Options = { "drawn", "classic" },
              Label = "Look of the pins and names",
              Comment = "drawn: inked onto the map by hand, in the colours of its watercolours; the names written in ink. classic: coloured dots in black rings, the names on white plates." },
            { Key = "AreaPinSize", Kind = "number", Default = 23, Min = 4, Max = 128,
              Label = "Teachers and traders on the camp maps", Unit = "units" },
            { Key = "WorldPinSize", Kind = "number", Default = 16, Min = 4, Max = 128,
              Label = "Teachers and traders on the world map", Unit = "units" },
            { Key = "OtherPinScale", Kind = "number", Default = 0.8, Min = 0.1, Max = 2, Decimals = 2, Step = 0.05,
              Label = "The pins of everyone else are", Unit = "times that size" },
            { Key = "AreaPinOpacity", Kind = "number", Default = 0.75, Min = 0.05, Max = 1, Decimals = 2, Step = 0.05,
              Label = "Opacity on the camp maps until hovered", Unit = "(1 = solid)" },
            { Key = "WorldPinOpacity", Kind = "number", Default = 0.6, Min = 0.05, Max = 1, Decimals = 2, Step = 0.05,
              Label = "Opacity on the world map until hovered", Unit = "(1 = solid)" },
        },
    },
    {
        Title = "Who is shown",
        Order = 40,
        Hint = "Teachers and traders are always shown.",
        Items = {
            { Key = "ShowOtherNPCs", Kind = "bool", Default = true,
              Label = "People who are neither teachers nor traders" },
            { Key = "OtherNPCsOnWorldMap", Kind = "bool", Default = true, Needs = "ShowOtherNPCs",
              Label = "Those people on the world map too (off: on the camp maps only)" },
            { Key = "ShowOrcs", Kind = "bool", Default = true,
              Label = "Orcs (Ur-Shak, Tarrok, the orcs of the Free Mine, ...)" },
            { Key = "HideDeadNPCs", Kind = "bool", Default = true,
              Label = "Hide people who are dead or gone" },
            { Key = "ShowFallbackPins", Kind = "bool", Default = true,
              Label = "A pale pin at the usual place for people the game has not created yet",
              Comment = "Only for the people whose usual place is known." },
            { Key = "FallbackOpacity", Kind = "number", Default = 0.55, Min = 0.05, Max = 1, Decimals = 2, Step = 0.05, Needs = "ShowFallbackPins",
              Label = "Opacity of such a pin", Unit = "(1 = solid)" },
        },
    },
    {
        Title = "People standing together (world map)",
        Order = 50,
        Hint = "On the world map people standing close together are drawn as one badge with their number; hovering the badge lists everyone there. A small blue or yellow dot on a badge means a teacher or a trader is among them.",
        Items = {
            { Key = "WorldPools", Kind = "bool", Default = true,
              Label = "One badge for people standing together" },
            { Key = "PoolLinkDistance", Kind = "number", Default = 26, Min = 1, Max = 400, Needs = "WorldPools",
              Label = "Two people stand together within", Unit = "units" },
            { Key = "PoolMinSize", Kind = "number", Default = 4, Min = 2, Max = 50, Needs = "WorldPools",
              Label = "A badge takes at least", Unit = "people (fewer keep their own pins)" },
            { Key = "PoolPinSize", Kind = "number", Default = 26, Min = 8, Max = 128, Needs = "WorldPools",
              Label = "Size of a badge", Unit = "units" },
            { Key = "PoolOpacity", Kind = "number", Default = 0.9, Min = 0.05, Max = 1, Decimals = 2, Step = 0.05, Needs = "WorldPools",
              Label = "Opacity of a badge until hovered", Unit = "(1 = solid)" },
            { Key = "PoolListRows", Kind = "number", Default = 16, Min = 4, Max = 60, Needs = "WorldPools",
              Label = "Names per column in the list of a badge" },
            { Key = "PoolListMax", Kind = "number", Default = 96, Min = 1, Max = 500, Needs = "WorldPools",
              Label = "The list of a badge has at most", Unit = "names" },
        },
    },
    {
        Title = "Colour key",
        Order = 60,
        Hint = "The colour key sits at the bottom left of the map screen, on the row of the game's own buttons when there is room to their left.",
        Items = {
            { Key = "ShowLegend", Kind = "bool", Default = true,
              Label = "Show the colour key" },
            { Key = "LegendScale", Kind = "number", Default = 1.0, Min = 0.25, Max = 3, Decimals = 2, Step = 0.05, Needs = "ShowLegend",
              Label = "Size of the colour key", Unit = "times" },
            { Key = "LegendAvoidButtons", Kind = "bool", Default = true, Needs = "ShowLegend",
              Label = "Keep clear of the game's buttons (a little smaller, or below their row, when the room is short)",
              Comment = "Off: always at the two distances below." },
            { Key = "LegendLeft", Kind = "number", Default = 100, Min = 0, Max = 3000, Needs = "ShowLegend",
              Label = "Distance from the left edge", Unit = "units" },
            { Key = "LegendBottom", Kind = "number", Default = 50, Min = 0, Max = 2000, Needs = "ShowLegend",
              Label = "Distance from the bottom edge", Unit = "units" },
        },
    },
    {
        Title = "Advanced",
        Order = 70,
        Items = {
            { Key = "RefreshSeconds", Kind = "number", Default = 2.0, Min = 0.2, Max = 60, Decimals = 1, Step = 0.5,
              Label = "While a map is open, positions are read again every", Unit = "seconds" },
            { Key = "MaxNewWidgetsPerTick", Kind = "number", Default = 24, Min = 1, Max = 500,
              Label = "New pins and names made per step",
              Comment = "Spreads the first opening of a map over a few frames instead of one long hitch." },
            { Key = "ApplyCorrection", Kind = "bool", Default = true,
              Label = "Use the game's correction for its hand-drawn maps (leave this on)" },
            { Key = "HideOutsideAreaMask", Kind = "bool", Default = true,
              Label = "Camp maps: hide pins that fall outside the drawn parchment" },
            { Key = "HideOnBackgroundMap", Kind = "bool", Default = true,
              Label = "Hide pins on the dimmed world map behind an open camp map" },
            { Key = "Verbose", Kind = "bool", Default = false,
              Label = "Extra lines in UE4SS.log (who is hidden and why, once per map)" },
        },
    },
}

return Schema
