-- Settings of the module mining, described once: the default config.lua, the
-- groups on the page "Resources" of the settings app and of the in-game mod
-- menu are made from this.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "mining"
Schema.Page = "Resources"
Schema.PageOrder = 20
Schema.Header = {
    "Mining rework (module mining of G1R_MegaMod)",
    "Set in the settings app or the in-game mod menu; changes count while the game runs.",
}
-- what the text about the presets (PRESETS.txt) says below this module's values; the game does not read it
Schema.PresetNote = "In preset 1 the numbers are not used (YieldEnabled is off): the game gives 3 ore a swing. StrengthPerOre / DexterityPerOre: one more ore for every so many points, 0 = the attribute does not count."
Schema.Notes = {
    "The game: 3 ore a swing, 1 when 5 or fewer are left. A vein holds 5, 10 or 15 and never refills.",
    "Ore per swing = base + 1 per so many Strength + 1 per so many Dexterity + miner bonus, kept between at least and at most. Never more than the vein holds, unless veins never run out.",
    "Counts from the next swing. Not loaded while the mod BetterMining is enabled.",
}

Schema.Groups = {
    {
        Title = "Mining",
        Order = 10,
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Tiers = "default",
              Label = "Mining rework",
              Comment = "Off: mining as the game has it." },
        },
    },
    {
        Title = "Mining: ore per swing",
        Order = 12,
        Hint = "Off: 3 ore a swing, as in the game. On: the numbers below decide.",
        Items = {
            { Key = "YieldEnabled", Kind = "bool", Default = false, Needs = "Enabled",
              Tiers = { false, true, true, true, true },
              Label = "Ore per swing from the numbers" },
            { Key = "BaseAmount", Kind = "number", Default = 3, Min = 0, Max = 100, Step = 1, Decimals = 0,
              Tiers = { 3, 3, 4, 6, 100 },
              Label = "Base amount", Unit = "ore", Needs = "YieldEnabled",
              Comment = "The game: 3." },
            { Key = "StrengthPerOre", Kind = "number", Default = 0, Min = 0, Max = 200, Step = 1, Decimals = 1,
              Tiers = { 0, 0, 0, 0, 1 },
              Label = "One more ore for every", Unit = "points of Strength (0 = none)", Needs = "YieldEnabled",
              Comment = "0 = Strength does not count. 4 with Strength 30 = 7 more ore.",
              MenuLabel = "+1 ore per Strength points", Menu = "one more ore for every so many; 0 = none" },
            { Key = "DexterityPerOre", Kind = "number", Default = 0, Min = 0, Max = 200, Step = 1, Decimals = 1,
              Tiers = { 0, 0, 0, 0, 1 },
              Label = "One more ore for every", Unit = "points of Dexterity (0 = none)", Needs = "YieldEnabled",
              Comment = "0 = Dexterity does not count. 6 with Dexterity 20 = 3 more ore.",
              MenuLabel = "+1 ore per Dexterity points", Menu = "one more ore for every so many; 0 = none" },
            { Key = "TrainedBonus", Kind = "number", Default = 0, Min = 0, Max = 100, Step = 1, Decimals = 0,
              Tiers = { 0, 1, 2, 3, 100 },
              Label = "A trained miner gets", Unit = "ore more", Needs = "YieldEnabled" },
            { Key = "MasterBonus", Kind = "number", Default = 0, Min = 0, Max = 100, Step = 1, Decimals = 0,
              Tiers = { 0, 2, 4, 6, 100 },
              Label = "A master miner gets", Unit = "ore more", Needs = "YieldEnabled",
              Comment = "Instead of the trained bonus." },
            { Key = "ExtraChance", Kind = "number", Default = 0, Min = 0, Max = 100, Step = 5, Decimals = 0,
              Tiers = { 0, 25, 50, 100, 100 },
              Label = "Chance of one more ore", Unit = "%", Needs = "YieldEnabled" },
            { Key = "MinAmount", Kind = "number", Default = 1, Min = 0, Max = 100, Step = 1, Decimals = 0,
              Tiers = { 1, 1, 2, 3, 100 },
              Label = "A swing gives at least", Unit = "ore", Needs = "YieldEnabled",
              Comment = "If the vein holds that much. 0 = a weak hero can get nothing." },
            { Key = "MaxAmount", Kind = "number", Default = 100, Min = 1, Max = 1000, Step = 1, Decimals = 0,
              Tiers = { 100, 100, 100, 100, 1000 },
              Label = "A swing gives at most", Unit = "ore", Needs = "YieldEnabled" },
            { Key = "LowVeinRule", Kind = "bool", Default = true, Needs = "YieldEnabled",
              Tiers = { true, true, false, false, false },
              Label = "Nearly empty vein gives less",
              Comment = "5 or fewer ore left: 1 per swing, as in the game." },
        },
    },
    {
        Title = "Mining: how long a vein lasts", MenuTitle = "How long a vein lasts",
        Order = 16,
        Hint = "The game: a vein holds 5, 10 or 15 ore and stays empty.",
        Items = {
            { Key = "EndlessVeins", Kind = "bool", Default = false, Needs = "Enabled",
              Tiers = { false, false, false, false, true },
              Label = "Veins never run out",
              Comment = "Refills the vein you swing at, also mined-out ones." },
            { Key = "VeinLastsTimes", Kind = "number", Default = 1, Min = 1, Max = 50, Step = 1, Decimals = 0,
              Tiers = { 1, 2, 3, 10, 50 },
              Label = "A vein lasts", Unit = "times as long (1 = as in the game)", Needs = "Enabled",
              Comment = "Part of each swing is put back. Not used while veins never run out.",
              MenuLabel = "A vein lasts (times as long)", Menu = "1 = as in the game" },
        },
    },
    {
        Title = "Mining: on screen and in the log", MenuTitle = "Mining: screen and log",
        Order = 20,
        Items = {
            { Key = "ShowMessage", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Note when a swing gave more/less",
              Comment = "Than the game would have given." },
            { Key = "LogSwings", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Log every swing" },
        },
    },
    {
        Title = "Mining: advanced",
        Order = 24,
        Items = {
            -- not shown in the app or the menu, not in the shipped file; can be added to config.lua by hand
            { Key = "VeinMethod", Kind = "choice", Default = "auto", Options = { "auto", "function", "slot" }, Hidden = true },
            { Key = "RefreshSeconds", Kind = "number", Default = 5, Min = 1, Max = 60, Decimals = 0, Hidden = true },
            { Key = "CheckMilliseconds", Kind = "number", Default = 250, Min = 50, Max = 2000, Decimals = 0, Hidden = true },
        },
    },
}

return Schema
