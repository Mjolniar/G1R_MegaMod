-- Settings of the module wait, described once: the default config.lua, the page
-- in the settings app and the entry in the in-game mod menu are made from this.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "wait"
Schema.Page = "Time"
Schema.PageOrder = 50
Schema.Header = {
    "Waiting: skip game time with a key (module wait of G1R_MegaMod)",
    "Easiest way to change these: the settings app, page \"Time\", or the",
    "in-game mod menu. Changes are picked up while the game is running.",
    "A key is written as \"Y\", \"F6\", \"CTRL+Y\", \"SHIFT+NUM_FIVE\"; \"\" = no key.",
}
Schema.Notes = {
    "Four ways to wait, each with a key of its own: a short and a long step in minutes, and two times of day (\"until morning\", \"until evening\"). A key can be any key with CTRL, SHIFT or ALT; the mod ships without keys.",
    "Without a key: the buttons in the in-game mod menu (page \"G1R Time\") and the console words \"wait 30\" and \"wait until 8\" do the same.",
    "Waiting only moves the game's clock, the way sleeping in a bed does: people take up what their day plans for the new hour, timers run on. It gives no rest and heals nothing.",
}

Schema.Groups = {
    {
        Title = "Waiting",
        Order = 10,
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "Skip time with keys, buttons and the console",
              Comment = "false = the module does nothing; its keys, buttons and console words skip no time.",
              MenuLabel = "Skip time (keys, buttons, console)", Menu = "off: no key, button or console word skips time" },
            { Key = "Cooldown", Kind = "number", Default = 2, Min = 0, Max = 60, Step = 0.5, Decimals = 1,
              Label = "At least this long between two skips", Unit = "seconds", Needs = "Enabled",
              Comment = { "Seconds that must pass after a skip before the next one is taken (0 to 60).",
                          "Keeps a held or doubly pressed key from skipping twice." },
              MenuLabel = "Time between two skips (seconds)", Menu = "seconds after a skip before the next (0 to 60)" },
        },
    },
    {
        Title = "Short wait",
        Order = 20,
        Items = {
            { Key = "ShortKey", Kind = "key", Default = "", Needs = "Enabled",
              Label = "Key for the short wait",
              Comment = "The key for the short wait (\"\" = none)." },
            { Key = "ShortMinutes", Kind = "number", Default = 30, Min = 1, Max = 1440, Step = 5, Decimals = 0,
              Label = "The short wait skips", Unit = "minutes", Needs = "Enabled",
              Comment = "Minutes of game time the short wait skips (1 to 1440; 1440 = a whole day).",
              Menu = "game minutes (1 to 1440; 1440 = a whole day)" },
            { Key = "SkipShort", Kind = "action", Label = "Wait the short time now",
              Comment = "Skips the minutes of the short wait now." },
        },
    },
    {
        Title = "Long wait",
        Order = 30,
        Items = {
            { Key = "LongKey", Kind = "key", Default = "", Needs = "Enabled",
              Label = "Key for the long wait",
              Comment = "The key for the long wait (\"\" = none)." },
            { Key = "LongMinutes", Kind = "number", Default = 240, Min = 1, Max = 1440, Step = 30, Decimals = 0,
              Label = "The long wait skips", Unit = "minutes", Needs = "Enabled",
              Comment = "Minutes of game time the long wait skips (1 to 1440; 240 = four hours).",
              Menu = "game minutes (1 to 1440; 240 = four hours)" },
            { Key = "SkipLong", Kind = "action", Label = "Wait the long time now",
              Comment = "Skips the minutes of the long wait now." },
        },
    },
    {
        Title = "Wait until morning",
        Order = 40,
        Items = {
            { Key = "MorningKey", Kind = "key", Default = "", Needs = "Enabled",
              Label = "Key for waiting until morning",
              Comment = "The key that skips to the morning hour (\"\" = none)." },
            { Key = "MorningHour", Kind = "number", Default = 8, Min = 0, Max = 23, Step = 1, Decimals = 0,
              Label = "Morning is at", Unit = "o'clock", Needs = "Enabled",
              Comment = { "The hour (0 to 23) this wait skips to. That is the next time the clock shows that",
                          "hour: today if it is still ahead, otherwise tomorrow." } },
            { Key = "SkipMorning", Kind = "action", Label = "Wait until morning now",
              Comment = "Skips to the morning hour now." },
        },
    },
    {
        Title = "Wait until evening",
        Order = 50,
        Items = {
            { Key = "EveningKey", Kind = "key", Default = "", Needs = "Enabled",
              Label = "Key for waiting until evening",
              Comment = "The key that skips to the evening hour (\"\" = none)." },
            { Key = "EveningHour", Kind = "number", Default = 20, Min = 0, Max = 23, Step = 1, Decimals = 0,
              Label = "Evening is at", Unit = "o'clock", Needs = "Enabled",
              Comment = "The hour (0 to 23) this wait skips to, like the morning hour.",
              Menu = "the hour (0 to 23) this wait skips to" },
            { Key = "SkipEvening", Kind = "action", Label = "Wait until evening now",
              Comment = "Skips to the evening hour now." },
        },
    },
    {
        Title = "When not to wait",
        Order = 60,
        Hint = "While a map loads, or with the game paused when the key is pressed, no time is skipped in any case.",
        Items = {
            { Key = "NotInFight", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Not with a weapon drawn (a fight)",
              Comment = "true = no time is skipped while the hero has a weapon drawn.",
              Menu = "no skip while you have a weapon drawn" },
            { Key = "NotInConversation", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Not in a conversation",
              Comment = "true = no time is skipped while the hero is talking to somebody.",
              Menu = "no skip while you talk to somebody" },
            { Key = "NotInCutscene", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Not in a cutscene",
              Comment = "true = no time is skipped while a cutscene is playing." },
            { Key = "NotWhenClockStopped", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Not while the game's clock stands still",
              Comment = { "true = no time is skipped while the game itself lets no time pass (cutscenes, some menus).",
                          "The game puts its clock back after a cutscene, so a skip there would be lost." },
              MenuLabel = "Not while the clock stands still", Menu = "no skip in cutscenes and menus that stop time" },
        },
    },
    {
        Title = "On screen",
        Order = 70,
        Items = {
            { Key = "ShowMessage", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Show a short note after a skip",
              Comment = "A short note after a skip: how long, and what time it is now. How notes look is set on the page \"General\".",
              Menu = "how long, and what time it is now" },
            { Key = "ShowRefused", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Also say on screen why a skip was not taken",
              Comment = "A short note when a skip was not taken, with the reason. The reason is in UE4SS.log in any case.",
              MenuLabel = "Say why a skip was not taken", Menu = "a short note with the reason" },
        },
    },
    {
        Title = "Log",
        Order = 80,
        Items = {
            { Key = "LogSkips", Kind = "bool", Default = false,
              Label = "One line in UE4SS.log for every skip",
              Comment = "One line in UE4SS.log for every skip. The first skip after the game started is always written.",
              MenuLabel = "Log every skip" },
        },
    },
}

return Schema
