-- Settings of the module xp, described once: the default config.lua, the page
-- in the settings app and the entry in the in-game mod menu are made from this.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "xp"
Schema.Page = "Experience"
Schema.PageOrder = 30
Schema.Header = {
    "Experience multiplier (module xp of G1R_MegaMod)",
    "Easiest way to change these: the settings app, page \"Experience\", or the",
    "in-game mod menu. Changes are picked up while the game is running.",
}
Schema.Notes = {
    "Works for every source of experience. The game's own \"+ experience\" display shows the amount before the multiplier; your total is the multiplied one.",
    "A level that the added experience makes possible is given with your next gain. Loading a save or changing a multiplier never changes experience you already have.",
    "Use one experience multiplier at a time: while the mod EXPModifier is enabled, this module is not loaded.",
}

Schema.Groups = {
    {
        Title = "Experience multiplier",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Tiers = "default",
              Label = "Multiply the experience the hero gains",
              Comment = "false = the module does nothing; experience stays as the game gives it.",
              MenuLabel = "Multiply experience gains", Menu = "off: experience as the game gives it" },
            { Key = "Multiplier", Kind = "number", Default = 1.0, Min = 0, Max = 10, Step = 0.25, Decimals = 2,
              Tiers = { 1, 1.5, 2, 4, 10 },
              Label = "Every gain counts", Unit = "times", Needs = "Enabled",
              Comment = { "Every experience gain counts this many times: 2.0 = double, 0.5 = half,",
                          "1.0 = unchanged. From 0 to 10." },
              Menu = "2.0 = double, 0.5 = half, 1.0 = unchanged" },
        },
    },
    {
        Title = "Large gains (quests)",
        Hint = "Fights give small amounts, quests large ones. With a size set here, gains of at least that size use their own multiplier.",
        Items = {
            { Key = "LargeGainFrom", Kind = "number", Default = 0, Min = 0, Max = 100000, Step = 50, Decimals = 0,
              Tiers = "default",
              Label = "A gain counts as large from", Unit = "experience (0 = no difference)", Needs = "Enabled",
              Comment = { "Gains of at least this size use LargeGainMultiplier instead of Multiplier.",
                          "0 = every gain uses Multiplier." },
              MenuLabel = "Large gain from (experience)", Menu = "gains this big use the large multiplier; 0 = none" },
            { Key = "LargeGainMultiplier", Kind = "number", Default = 1.0, Min = 0, Max = 10, Step = 0.25, Decimals = 2,
              Tiers = "default",
              Label = "A large gain counts", Unit = "times", Needs = "Enabled",
              Comment = "The multiplier for large gains (only used when LargeGainFrom is above 0).",
              Menu = "only used when 'large gain from' is above 0" },
        },
    },
    {
        Title = "On screen",
        Items = {
            { Key = "ShowMessage", Kind = "bool", Default = true,
              Label = "Show a short note when experience was added",
              Comment = "A short note on screen when experience was added. How notes look is set on the page \"General\".",
              MenuLabel = "Note when experience was added" },
        },
    },
    {
        Title = "Log",
        Items = {
            { Key = "LogGains", Kind = "bool", Default = false,
              Label = "One line in UE4SS.log for every experience gain",
              Comment = "One line in UE4SS.log for every experience gain.",
              MenuLabel = "Log every experience gain" },
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
