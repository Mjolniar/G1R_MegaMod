-- Settings of the module xp, described once: the default config.lua, the page
-- in the settings app and the entry in the in-game mod menu are made from this.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "xp"
Schema.Page = "Experience"
Schema.PageOrder = 30
Schema.Header = {
    "Experience multiplier (module xp of G1R_MegaMod)",
    "Set in the settings app or the in-game mod menu; changes count while the game runs.",
}
Schema.Notes = {
    "Counts for every source of experience. The game's \"+ experience\" shows the amount before the multiplier.",
    "Never changes experience you already have.",
    "Not loaded while the mod EXPModifier is enabled.",
}

Schema.Groups = {
    {
        Title = "Experience multiplier",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Tiers = "default",
              Label = "Multiply experience gains",
              Comment = "Off: experience as the game gives it." },
            { Key = "Multiplier", Kind = "number", Default = 1.0, Min = 0, Max = 10, Step = 0.25, Decimals = 2,
              Tiers = { 1, 1.5, 2, 4, 10 },
              Label = "Every gain counts", Unit = "times", Needs = "Enabled",
              Comment = "2 = double, 0.5 = half, 1 = unchanged (0 to 10)." },
        },
    },
    {
        Title = "Large gains (quests)",
        Hint = "Quests give large amounts. Gains of at least this size use their own multiplier.",
        Items = {
            { Key = "LargeGainFrom", Kind = "number", Default = 0, Min = 0, Max = 100000, Step = 50, Decimals = 0,
              Tiers = "default",
              Label = "Large gain from", Unit = "experience (0 = off)", Needs = "Enabled",
              Comment = "Gains of at least this size use the large multiplier. 0 = off.",
              MenuLabel = "Large gain from (experience)", Menu = "gains this big use the large multiplier; 0 = off" },
            { Key = "LargeGainMultiplier", Kind = "number", Default = 1.0, Min = 0, Max = 10, Step = 0.25, Decimals = 2,
              Tiers = "default",
              Label = "A large gain counts", Unit = "times", Needs = "Enabled",
              Comment = "Used while 'Large gain from' is above 0." },
        },
    },
    {
        Title = "On screen",
        Items = {
            { Key = "ShowMessage", Kind = "bool", Default = true,
              Label = "Note when experience was added" },
        },
    },
    {
        Title = "Log",
        Items = {
            { Key = "LogGains", Kind = "bool", Default = false,
              Label = "Log every experience gain" },
        },
    },
    {
        Title = "Advanced",
        Items = {
            -- not shown in the app or the menu, not in the shipped file; can be added to config.lua by hand
            { Key = "MaxGain", Kind = "number", Default = 50000, Min = 1, Max = 100000000, Decimals = 0, Hidden = true },
            { Key = "SettleSeconds", Kind = "number", Default = 10, Min = 0, Max = 120, Decimals = 0, Hidden = true },
            { Key = "CheckMilliseconds", Kind = "number", Default = 250, Min = 50, Max = 5000, Decimals = 0, Hidden = true },
        },
    },
}

return Schema
