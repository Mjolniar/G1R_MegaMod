-- Settings of the module mount: the scavenger you ride.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "mount"
Schema.Page = "Mount"
Schema.PageOrder = 11
Schema.Header = {
    "Mount settings (module mount of G1R_MegaMod)",
    "Easiest way to change these: the settings app, page \"Mount\", or the",
    "in-game mod menu. Changes are picked up while the game is running.",
}
Schema.Notes = {
    "Your scavenger sometimes does not come when you whistle. The game has three ways to that: you carry the game's riding block (set inside camps and other no-riding areas; it can stay on you after a missed exit), the scavenger fears you (one of your own hits landed on it), or the whistle reached nobody. This module writes down what it finds at every whistle, and can put it right.",
}

Schema.Groups = {
    {
        Title = "Its name",
        Items = {
            { Key = "Name", Kind = "text", Default = "",
              Label = "Name of your scavenger",
              Comment = { "Shown over your scavenger instead of the game's name; empty = the game's name.",
                          "At most 40 letters. Wild scavengers keep theirs." } },
        },
    },
    {
        Title = "Your scavenger",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "Watch the whistle",
              Comment = { "Every whistle for the scavenger is written to the log with what the game says about you and",
                          "about it, and again a few seconds later with how far away it is then." },
              Menu = "every whistle is logged, and looked at again later" },
            { Key = "AutoFix", Kind = "choice", Default = "full", Options = { "full", "safe", "off" }, Needs = "Enabled",
              Label = "When it did not come",
              Comment = { "What is done when the scavenger has not come closer a few seconds after a whistle.",
                          "\"full\" = a riding block on you is taken off, fear is taken off the scavenger and it is put",
                          "back to its idle routine - whistle again; \"safe\" = the same without touching the riding",
                          "block (inside a camp the game means it); \"off\" = only written down." } },
            { Key = "WaitSeconds", Kind = "number", Default = 8, Min = 4, Max = 20, Step = 1, Decimals = 0, Needs = "Enabled",
              Label = "Look again after", Unit = "seconds",
              Comment = "How long after a whistle the scavenger's distance is looked at again (4 to 20 seconds).",
              Menu = "how long after a whistle it looks again (4 to 20)" },
            { Key = "FixKey", Kind = "key", Default = "",
              Label = "Key that puts the scavenger right",
              Comment = { "A key that does what \"full\" does, at once and whether a whistle was seen or not",
                          "(\"\" = none). The console words do the same: mount, mount fix." } },
            { Key = "ShowNotes", Kind = "bool", Default = true,
              Label = "Say on screen what was done",
              Comment = "A short note on screen when something was put right." },
            { Key = "Report", Kind = "action", Label = "Report the scavenger now",
              Comment = "Writes one line about you and the scavenger to the log (and shows it).",
              Menu = "one line about you and the scavenger (also shown)" },
            { Key = "Fix", Kind = "action", Label = "Put the scavenger right now",
              Comment = "Does what \"full\" does, now." },
        },
    },
}

return Schema
