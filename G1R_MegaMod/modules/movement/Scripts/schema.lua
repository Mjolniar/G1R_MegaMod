-- Settings of the module movement: how fast the hero walks, runs and swims, and how fast your scavenger runs.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "movement"
Schema.Page = "Movement"
Schema.PageOrder = 12
Schema.Header = {
    "Movement settings (module movement of G1R_MegaMod)",
    'Easiest way to change these: the settings app, page "Movement", or the',
    "in-game mod menu. Changes are picked up while the game is running.",
}
Schema.Notes = {
    "On foot: the hero's own speed factor times the multiplier (walking, running, sneaking). Swimming: the game's three swimming speeds of the hero times the multiplier. The scavenger: its own speed factor times the multiplier - when you ride it, and also when it follows you. 1.00 leaves the game as it is; going back to 1.00, or switching this part off, puts the game's own values back.",
}

Schema.Groups = {
    {
        Title = "Speeds",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "Movement speeds (this whole part of the mod)",
              Comment = "Switches the speed multipliers below on or off; off puts the game's own speeds back.",
              MenuLabel = "Movement speeds", Menu = "off: the game's own speeds are put back" },
            { Key = "HeroSpeed", Kind = "number", Default = 1.0, Min = 0.5, Max = 3.0, Step = 0.05, Decimals = 2, Needs = "Enabled",
              Label = "Speed of the hero on foot", Unit = "times",
              Comment = { "How fast the hero walks, runs and sneaks: his own speed factor times this (1.00 = as the game",
                          "has it, 0.50 to 3.00)." },
              Menu = "his own speed factor times this; 1 = as in the game" },
            { Key = "SwimSpeed", Kind = "number", Default = 1.0, Min = 0.5, Max = 3.0, Step = 0.05, Decimals = 2, Needs = "Enabled",
              Label = "Swimming speed", Unit = "times",
              Comment = { "How fast the hero swims: the game's three swimming speeds times this (1.00 = as the game has",
                          "it, 0.50 to 3.00)." },
              Menu = "the game's swimming speeds times this; 1 = same" },
            { Key = "MountSpeed", Kind = "number", Default = 1.0, Min = 0.5, Max = 3.0, Step = 0.05, Decimals = 2, Needs = "Enabled",
              Label = "Speed of your scavenger", Unit = "times",
              Comment = { "How fast the scavenger you ride runs: its own speed factor times this (1.00 = as the game has",
                          "it, 0.50 to 3.00). It runs that much faster when it follows you, too." },
              Menu = "its own speed factor times this; 1 = as in the game" },
            { Key = "LogChanges", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "One line in UE4SS.log for every speed changed or put back",
              Comment = "A line in UE4SS.log whenever a speed of the game is changed or put back.",
              MenuLabel = "Log every speed change", Menu = "a line in UE4SS.log when a speed changes or goes back" },
        },
    },
}

return Schema
