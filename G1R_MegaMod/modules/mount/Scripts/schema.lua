-- Settings of the module mount: the scavenger you ride.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "mount"
Schema.Page = "Mount"
Schema.PageOrder = 11
Schema.Header = {
    "Mount settings (module mount of G1R_MegaMod)",
    "Set in the settings app or the in-game mod menu; changes count while the game runs.",
}
Schema.Notes = {
    "When the scavenger does not come to a whistle, the cause is one of three: a riding block left on you (camps, no-riding areas), the scavenger fears you (you hit it), or the whistle reached nobody. Every whistle is logged; the fix below can put it right.",
}

Schema.Groups = {
    {
        Title = "Its name",
        Items = {
            { Key = "Name", Kind = "text", Default = "",
              Label = "Name of your scavenger",
              Comment = "Empty = the game's name. At most 40 letters. Wild scavengers keep theirs." },
        },
    },
    {
        Title = "Your scavenger",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "Watch the whistle",
              Comment = "Logs every whistle and looks again later." },
            { Key = "AutoFix", Kind = "choice", Default = "full", Options = { "full", "safe", "off" }, Needs = "Enabled",
              Label = "When it did not come",
              Comment = { "full: takes the riding block off you, fear off the scavenger, and puts it back to its",
                          "routine; whistle again. safe: the same, but leaves the riding block (camps mean it). off: only logged." } },
            { Key = "WaitSeconds", Kind = "number", Default = 8, Min = 4, Max = 20, Step = 1, Decimals = 0, Needs = "Enabled",
              Label = "Look again after", Unit = "seconds" },
            { Key = "FixKey", Kind = "key", Default = "",
              Label = "Key that puts the scavenger right",
              Comment = "Does what \"full\" does, at once. \"\" = none. Console: mount fix." },
            { Key = "ShowNotes", Kind = "bool", Default = true,
              Label = "Note when something was put right" },
            { Key = "Report", Kind = "action", Label = "Report the scavenger now",
              Comment = "A line about you and the scavenger, logged and shown." },
            { Key = "Fix", Kind = "action", Label = "Put the scavenger right now",
              Comment = "Does what \"full\" does." },
        },
    },
}

return Schema
