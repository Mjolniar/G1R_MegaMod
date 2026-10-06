-- Settings of the module movement: how fast the hero walks, runs and swims, and how fast your scavenger runs.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "movement"
Schema.Page = "Movement"
Schema.PageOrder = 12
Schema.Header = {
    "Movement settings (module movement of G1R_MegaMod)",
    "Set in the settings app or the in-game mod menu; changes count while the game runs.",
}
Schema.Notes = {
    "Each speed is the game's own times the multiplier. 1.00 = as in the game. Back to 1.00, or this part off, puts the game's speeds back.",
}

Schema.Groups = {
    {
        Title = "Speeds",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "Movement speeds",
              Comment = "Off: the game's own speeds." },
            { Key = "HeroSpeed", Kind = "number", Default = 1.0, Min = 0.5, Max = 3.0, Step = 0.05, Decimals = 2, Needs = "Enabled",
              Label = "Hero on foot", Unit = "times",
              Comment = "Walking, running, sneaking (0.50 to 3.00)." },
            { Key = "SwimSpeed", Kind = "number", Default = 1.0, Min = 0.5, Max = 3.0, Step = 0.05, Decimals = 2, Needs = "Enabled",
              Label = "Swimming", Unit = "times",
              Comment = "0.50 to 3.00." },
            { Key = "MountSpeed", Kind = "number", Default = 1.0, Min = 0.5, Max = 3.0, Step = 0.05, Decimals = 2, Needs = "Enabled",
              Label = "Your scavenger", Unit = "times",
              Comment = "Ridden and following you (0.50 to 3.00)." },
            { Key = "LogChanges", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Log every speed change" },
        },
    },
}

return Schema
