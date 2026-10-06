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
    "Counts from the next start of the game.",
    "Units: one pixel on a 1920 x 1080 screen. The world map is 1600 wide, a camp map 1400.",
    "Config.HideIds (never shown) and Config.ExtraNPCs (added) are edited in modules\\markers\\Scripts\\config.lua itself.",
}

Schema.Groups = {
    {
        Title = "Names on the maps",
        Order = 10,
        Hint = "always: every name. auto: names that fit; the rest on hover. hover: only on hover. off: none.",
        Items = {
            { Key = "AreaLabels", Kind = "choice", Default = "auto", Options = { "always", "auto", "hover", "off" },
              Label = "Names on the camp maps" },
            { Key = "WorldLabels", Kind = "choice", Default = "hover", Options = { "always", "auto", "hover", "off" },
              Label = "Names on the world map" },
            { Key = "LabelScale", Kind = "number", Default = 0.39, Min = 0.1, Max = 2, Decimals = 2, Step = 0.01,
              Label = "Scale of the names",
              Comment = "0.39 = the size the pictures were made for." },
            { Key = "LabelGap", Kind = "number", Default = 2, Min = 0, Max = 50,
              Label = "Gap between a pin and its name", Unit = "units" },
            { Key = "NameLetters", Kind = "choice", Default = "game", Options = { "game", "gothic" },
              Label = "Letters of the names",
              Comment = "game: the game's text letters. gothic: blackletter." },
        },
    },
    {
        Title = "Hovering a pin",
        Order = 20,
        Hint = "Hovering a pin lists the names around it, teachers and traders first.",
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
              Comment = "drawn: ink and watercolour, as the map. classic: coloured dots, names on white plates." },
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
              Label = "Those people on the world map too" },
            { Key = "ShowOrcs", Kind = "bool", Default = true,
              Label = "Orcs (Ur-Shak, Tarrok, the orcs of the Free Mine, ...)" },
            { Key = "HideDeadNPCs", Kind = "bool", Default = true,
              Label = "Hide people who are dead or gone" },
            { Key = "ShowFallbackPins", Kind = "bool", Default = true,
              Label = "Pale pin at the usual place of people not created yet",
              Comment = "Only where the usual place is known." },
            { Key = "FallbackOpacity", Kind = "number", Default = 0.55, Min = 0.05, Max = 1, Decimals = 2, Step = 0.05, Needs = "ShowFallbackPins",
              Label = "Opacity of such a pin", Unit = "(1 = solid)" },
        },
    },
    {
        Title = "People standing together (world map)",
        Order = 50,
        Hint = "One badge with their number; hover it for the list. A blue or yellow dot: a teacher or trader among them.",
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
        Hint = "At the bottom left of the map screen.",
        Items = {
            { Key = "ShowLegend", Kind = "bool", Default = true,
              Label = "Show the colour key" },
            { Key = "LegendScale", Kind = "number", Default = 1.0, Min = 0.25, Max = 3, Decimals = 2, Step = 0.05, Needs = "ShowLegend",
              Label = "Size of the colour key", Unit = "times" },
            { Key = "LegendAvoidButtons", Kind = "bool", Default = true, Needs = "ShowLegend",
              Label = "Keep clear of the game's buttons",
              Comment = "Shrinks or moves below them when short of room. Off: always at the distances below." },
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
              Comment = "Spreads the first opening of a map over a few frames." },
            { Key = "ApplyCorrection", Kind = "bool", Default = true,
              Label = "Use the game's correction for its drawn maps (leave on)" },
            { Key = "HideOutsideAreaMask", Kind = "bool", Default = true,
              Label = "Camp maps: hide pins that fall outside the drawn parchment" },
            { Key = "HideOnBackgroundMap", Kind = "bool", Default = true,
              Label = "Hide pins on the dimmed world map behind an open camp map" },
            { Key = "Verbose", Kind = "bool", Default = false,
              Label = "Extra lines in UE4SS.log (who is hidden and why)" },
        },
    },
}

return Schema
