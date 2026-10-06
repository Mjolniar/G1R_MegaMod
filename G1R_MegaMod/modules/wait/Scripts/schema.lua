-- Settings of the module wait, described once: the default config.lua, the page
-- in the settings app and the entry in the in-game mod menu are made from this.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "wait"
Schema.Page = "Time"
Schema.PageOrder = 50
Schema.Header = {
    "Waiting: skip game time with a key (module wait of G1R_MegaMod)",
    "Set in the settings app or the in-game mod menu; changes count while the game runs.",
    "A key is written as \"Y\", \"F6\", \"CTRL+Y\", \"SHIFT+NUM_FIVE\"; \"\" = no key.",
}
Schema.Notes = {
    "Four waits, each with its own key: short, long, until morning, until evening. No keys are set as shipped.",
    "Also: the buttons in the in-game menu (G1R Time), and the console words \"wait 30\" and \"wait until 8\".",
    "Only the clock moves, as when sleeping. No rest, no healing.",
}

Schema.Groups = {
    {
        Title = "Waiting",
        Order = 10,
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "Skip time (keys, buttons, console)",
              Comment = "Off: nothing skips time." },
            { Key = "Cooldown", Kind = "number", Default = 2, Min = 0, Max = 60, Step = 0.5, Decimals = 1,
              Label = "Time between two skips", Unit = "seconds", Needs = "Enabled",
              Comment = "Keeps a held key from skipping twice (0 to 60)." },
        },
    },
    {
        Title = "Short wait",
        Order = 20,
        Items = {
            { Key = "ShortKey", Kind = "key", Default = "", Needs = "Enabled",
              Label = "Key for the short wait" },
            { Key = "ShortMinutes", Kind = "number", Default = 30, Min = 1, Max = 1440, Step = 5, Decimals = 0,
              Label = "The short wait skips", Unit = "minutes", Needs = "Enabled",
              Comment = "Game minutes (1 to 1440 = a day)." },
            { Key = "SkipShort", Kind = "action", Label = "Wait the short time now" },
        },
    },
    {
        Title = "Long wait",
        Order = 30,
        Items = {
            { Key = "LongKey", Kind = "key", Default = "", Needs = "Enabled",
              Label = "Key for the long wait" },
            { Key = "LongMinutes", Kind = "number", Default = 240, Min = 1, Max = 1440, Step = 30, Decimals = 0,
              Label = "The long wait skips", Unit = "minutes", Needs = "Enabled",
              Comment = "Game minutes (1 to 1440 = a day)." },
            { Key = "SkipLong", Kind = "action", Label = "Wait the long time now" },
        },
    },
    {
        Title = "Wait until morning",
        Order = 40,
        Items = {
            { Key = "MorningKey", Kind = "key", Default = "", Needs = "Enabled",
              Label = "Key for waiting until morning" },
            { Key = "MorningHour", Kind = "number", Default = 8, Min = 0, Max = 23, Step = 1, Decimals = 0,
              Label = "Morning is at", Unit = "o'clock", Needs = "Enabled",
              Comment = "The next time the clock shows this hour (0 to 23)." },
            { Key = "SkipMorning", Kind = "action", Label = "Wait until morning now" },
        },
    },
    {
        Title = "Wait until evening",
        Order = 50,
        Items = {
            { Key = "EveningKey", Kind = "key", Default = "", Needs = "Enabled",
              Label = "Key for waiting until evening" },
            { Key = "EveningHour", Kind = "number", Default = 20, Min = 0, Max = 23, Step = 1, Decimals = 0,
              Label = "Evening is at", Unit = "o'clock", Needs = "Enabled",
              Comment = "The next time the clock shows this hour (0 to 23)." },
            { Key = "SkipEvening", Kind = "action", Label = "Wait until evening now" },
        },
    },
    {
        Title = "When not to wait",
        Order = 60,
        Hint = "Never while a map loads or the game is paused.",
        Items = {
            { Key = "NotInFight", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Not with a weapon drawn" },
            { Key = "NotInConversation", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Not in a conversation" },
            { Key = "NotInCutscene", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Not in a cutscene" },
            { Key = "NotWhenClockStopped", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Not while the clock stands still",
              Comment = "Cutscenes, some menus. The game would undo the skip." },
        },
    },
    {
        Title = "On screen",
        Order = 70,
        Items = {
            { Key = "ShowMessage", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Note after a skip",
              Comment = "How long, and the time now." },
            { Key = "ShowRefused", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Say why a skip was not taken",
              Comment = "The reason is in UE4SS.log in any case." },
        },
    },
    {
        Title = "Log",
        Order = 80,
        Items = {
            { Key = "LogSkips", Kind = "bool", Default = false,
              Label = "Log every skip",
              Comment = "The first skip of a run is always logged." },
        },
    },
}

return Schema
