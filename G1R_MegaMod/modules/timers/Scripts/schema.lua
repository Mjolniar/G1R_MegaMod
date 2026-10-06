-- Settings of the module timers: how long what is on you still lasts.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "timers"
Schema.Page = "Effect timers"
Schema.PageOrder = 91
Schema.Header = {
    "Effect timer settings (module timers of G1R_MegaMod)",
    "Set in the settings app or the in-game mod menu; changes count while the game runs.",
}
Schema.Notes = {
    "A small box lists what is on you and how long it lasts. It shows only while something is on you.",
    "Distances are in screen units (1920 x 1080), from the box's corner. Move it up to sit above the health bar.",
}

Schema.Groups = {
    {
        Title = "What is shown",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "Effect timers" },
            { Key = "ShowFood", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Healing and mana over time",
              Comment = "From food and potions." },
            { Key = "ShowElements", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Burning, frozen, electrified, wind, slowed",
              MenuLabel = "Fire, ice, lightning, wind, slow", Menu = "burning, frozen, electrified, wind, slowed" },
            { Key = "ShowMind", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Knocked out, asleep, afraid, charmed",
              MenuLabel = "Knocked out, sleep, fear, charm", Menu = "knocked out, asleep, afraid, charmed" },
            { Key = "ShowLight", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "The Light spell" },
            { Key = "ShowDrinks", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Alcohol and swampweed" },
            { Key = "ShowOthers", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Every other effect with a time",
              Comment = "By the game's own name. Most are short." },
        },
    },
    {
        Title = "Where",
        Items = {
            { Key = "Position", Kind = "choice", Default = "bottom left", Options = { "bottom left", "top left", "bottom right", "top right" }, Needs = "Enabled",
              Label = "Corner of the box" },
            { Key = "DistanceX", Kind = "number", Default = 24, Min = 0, Max = 1200, Step = 4, Decimals = 0, Needs = "Enabled",
              Label = "Distance from the side", Unit = "units" },
            { Key = "DistanceY", Kind = "number", Default = 200, Min = 0, Max = 800, Step = 4, Decimals = 0, Needs = "Enabled",
              Label = "Distance from top or bottom", Unit = "units" },
        },
    },
}

return Schema
