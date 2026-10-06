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
    "Easiest way to change these: the settings app, page \"Resources\", or the",
    "in-game mod menu. Changes are picked up while the game is running.",
    "With the values the mod ships with, mining stays exactly as the game has it.",
}
-- what the text about the presets (PRESETS.txt) says below this module's values; the game does not read it
Schema.PresetNote = "In preset 1 the numbers are not used (YieldEnabled is off): the game gives 3 ore a swing. StrengthPerOre / DexterityPerOre: one more ore for every so many points, 0 = the attribute does not count."
Schema.Notes = {
    "The game itself: one swing of the pickaxe gives 3 ore, and 1 ore when 5 or fewer are left in the vein. A vein holds 5, 10 or 15 ore and never refills.",
    "Ore per swing: base amount + 1 for every so many points of Strength + 1 for every so many points of Dexterity + the bonus of a trained or master miner, kept between \"at least\" and \"at most\". A swing never gives more than the vein holds, unless veins never run out.",
    "\"Veins never run out\": the vein you swing at is filled up again, also one you emptied earlier. \"A vein lasts ... times as long\": part of what a swing takes is put back into the vein.",
    "A changed setting counts from the next swing on and never changes ore you already have. Use one mining mod at a time: while the mod BetterMining is enabled, this module is not loaded.",
}

Schema.Groups = {
    {
        Title = "Mining",
        Order = 10,
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Tiers = "default",
              Label = "Mining rework (this whole part of the mod)",
              Comment = "false = the module does nothing; mining stays as the game has it.",
              MenuLabel = "Mining rework", Menu = "off: mining stays as the game has it" },
        },
    },
    {
        Title = "Mining: ore per swing",
        Order = 12,
        Hint = "The game gives 3 ore per swing (1 when the vein is nearly empty). With the switch on, the numbers below decide.",
        Items = {
            { Key = "YieldEnabled", Kind = "bool", Default = false, Needs = "Enabled",
              Tiers = { false, true, true, true, true },
              Label = "Work out the ore per swing from the numbers below",
              Comment = { "true = the ore a swing gives is worked out from the numbers below.",
                          "false = a swing gives what the game gives (3 ore)." },
              MenuLabel = "Ore per swing from the numbers", Menu = "on: the ore a swing gives comes from below" },
            { Key = "BaseAmount", Kind = "number", Default = 3, Min = 0, Max = 100, Step = 1, Decimals = 0,
              Tiers = { 3, 3, 4, 6, 100 },
              Label = "Base amount", Unit = "ore", Needs = "YieldEnabled",
              Comment = "Every swing starts with this much ore. 3 = what the game gives. From 0 to 100." },
            { Key = "StrengthPerOre", Kind = "number", Default = 0, Min = 0, Max = 200, Step = 1, Decimals = 1,
              Tiers = { 0, 0, 0, 0, 1 },
              Label = "One more ore for every", Unit = "points of Strength (0 = none)", Needs = "YieldEnabled",
              Comment = { "One more ore for every so many points of the hero's Strength. 0 = Strength does not count.",
                          "Example: 4 with Strength 30 = 7 more ore per swing." },
              MenuLabel = "+1 ore per Strength points", Menu = "one more ore for every so many; 0 = none" },
            { Key = "DexterityPerOre", Kind = "number", Default = 0, Min = 0, Max = 200, Step = 1, Decimals = 1,
              Tiers = { 0, 0, 0, 0, 1 },
              Label = "One more ore for every", Unit = "points of Dexterity (0 = none)", Needs = "YieldEnabled",
              Comment = { "One more ore for every so many points of the hero's Dexterity. 0 = Dexterity does not count.",
                          "Example: 6 with Dexterity 20 = 3 more ore per swing." },
              MenuLabel = "+1 ore per Dexterity points", Menu = "one more ore for every so many; 0 = none" },
            { Key = "TrainedBonus", Kind = "number", Default = 0, Min = 0, Max = 100, Step = 1, Decimals = 0,
              Tiers = { 0, 1, 2, 3, 100 },
              Label = "A trained miner gets", Unit = "ore more", Needs = "YieldEnabled",
              Comment = "A hero who has learned mining gets this much more ore per swing. 0 = no difference.",
              Menu = "more ore per swing after learning mining" },
            { Key = "MasterBonus", Kind = "number", Default = 0, Min = 0, Max = 100, Step = 1, Decimals = 0,
              Tiers = { 0, 2, 4, 6, 100 },
              Label = "A master miner gets", Unit = "ore more", Needs = "YieldEnabled",
              Menu = "more ore per swing (instead of the trained bonus)",
              Comment = { "A hero who has mastered mining gets this much more ore per swing, instead of the",
                          "bonus of a trained miner. 0 = no difference." } },
            { Key = "ExtraChance", Kind = "number", Default = 0, Min = 0, Max = 100, Step = 5, Decimals = 0,
              Tiers = { 0, 25, 50, 100, 100 },
              Label = "Chance of one more ore", Unit = "%", Needs = "YieldEnabled",
              Comment = "The chance that a swing gives one more ore, in percent. 0 = never, 100 = always.",
              Menu = "chance that a swing gives one more ore" },
            { Key = "MinAmount", Kind = "number", Default = 1, Min = 0, Max = 100, Step = 1, Decimals = 0,
              Tiers = { 1, 1, 2, 3, 100 },
              Label = "A swing gives at least", Unit = "ore", Needs = "YieldEnabled",
              Comment = { "A swing never gives less than this, as long as the vein holds that much.",
                          "0 = a weak hero can go away empty-handed. A nearly empty vein gives 1 all the same",
                          "while the game's rule for it (below) is on." },
              Menu = "never less, as long as the vein holds that much" },
            { Key = "MaxAmount", Kind = "number", Default = 100, Min = 1, Max = 1000, Step = 1, Decimals = 0,
              Tiers = { 100, 100, 100, 100, 1000 },
              Label = "A swing gives at most", Unit = "ore", Needs = "YieldEnabled",
              Comment = "A swing never gives more than this, whatever the numbers above add up to.",
              Menu = "never more, whatever the numbers above add up to" },
            { Key = "LowVeinRule", Kind = "bool", Default = true, Needs = "YieldEnabled",
              Tiers = { true, true, false, false, false },
              Label = "A nearly empty vein gives less (the game's rule)",
              Comment = { "true = a vein with 5 or fewer ore left gives 1 ore per swing, as in the game.",
                          "false = it gives the same as a full vein, down to the last ore." },
              MenuLabel = "Nearly empty vein gives less", Menu = "5 or fewer ore left: 1 per swing, as in the game" },
        },
    },
    {
        Title = "Mining: how long a vein lasts", MenuTitle = "How long a vein lasts",
        Order = 16,
        Hint = "The game's veins hold 5, 10 or 15 ore and stay empty once they are mined out.",
        Items = {
            { Key = "EndlessVeins", Kind = "bool", Default = false, Needs = "Enabled",
              Tiers = { false, false, false, false, true },
              Label = "Veins never run out",
              Menu = "the vein refills; every swing gives the full amount",
              Comment = { "true = the vein the hero swings at is filled up again: it never runs out, and every swing",
                          "gives the full amount. A vein that was mined out earlier comes back as well." } },
            { Key = "VeinLastsTimes", Kind = "number", Default = 1, Min = 1, Max = 50, Step = 1, Decimals = 0,
              Tiers = { 1, 2, 3, 10, 50 },
              Label = "A vein lasts", Unit = "times as long (1 = as in the game)", Needs = "Enabled",
              Menu = "this many times the ore before empty; 1 = the game's",
              Comment = { "A vein gives this many times as much ore before it is empty: of what a swing takes,",
                          "the fitting part is put back. 1 = as the game has it. Not used while veins never run out." },
              MenuLabel = "A vein lasts (times as long)" },
        },
    },
    {
        Title = "Mining: on screen and in the log", MenuTitle = "Mining: screen and log",
        Order = 20,
        Items = {
            { Key = "ShowMessage", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Show a short note when a swing gave more or less than the game would",
              Comment = { "A short note on screen when a swing gave more or less ore than the game would have given.",
                          "How notes look is set on the page \"General\"." },
              MenuLabel = "Note when a swing gave more/less", Menu = "a note when a swing gave other ore than the game's" },
            { Key = "LogSwings", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "One line in UE4SS.log for every swing",
              Comment = "One line in UE4SS.log for every swing of the pickaxe the module sees.",
              MenuLabel = "Log every swing", Menu = "one line in UE4SS.log per swing of the pickaxe" },
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
