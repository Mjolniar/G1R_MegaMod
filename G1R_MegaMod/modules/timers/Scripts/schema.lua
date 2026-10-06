-- Settings of the module timers: how long what is on you still lasts.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "timers"
Schema.Page = "Effect timers"
Schema.PageOrder = 91
Schema.Header = {
    "Effect timer settings (module timers of G1R_MegaMod)",
    'Easiest way to change these: the settings app, page "Interface > Effect timers", or the',
    "in-game mod menu. Changes are picked up while the game is running.",
}
Schema.Notes = {
    "A small box lists what is on you and how long it still lasts: healing and mana over time from food and potions, burning, frozen, electrified, wind, slowed, knocked out, asleep, afraid, charmed, the Light spell, and how long alcohol and swampweed still last. Each kind has its own switch. The box is only there while something is on you.",
    "The distances are counted from the corner the box sits in, in the screen's units (1920 x 1080). Move it up from the bottom left to stand above the health bar.",
}

Schema.Groups = {
    {
        Title = "What is shown",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "Effect timers (this whole part of the mod)",
              Comment = "Switches the box of timers on or off.",
              MenuLabel = "Effect timers" },
            { Key = "ShowFood", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Healing and mana over time (food, potions)",
              Comment = "Healing and mana that come over time from food and potions.",
              MenuLabel = "Healing and mana over time", Menu = "from food and potions" },
            { Key = "ShowElements", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Burning, frozen, electrified, wind, slowed",
              Comment = "What spells and fire do to you for a while.",
              MenuLabel = "Fire, ice, lightning, wind, slow", Menu = "burning, frozen, electrified, wind, slowed" },
            { Key = "ShowMind", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Knocked out, asleep, afraid, charmed",
              Comment = "Being knocked out, and sleep, fear or charm cast on you.",
              MenuLabel = "Knocked out, sleep, fear, charm", Menu = "knocked out, or sleep, fear, charm cast on you" },
            { Key = "ShowLight", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "The Light spell",
              Comment = "How long your Light spell still burns." },
            { Key = "ShowDrinks", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Alcohol and swampweed",
              Comment = "How long until alcohol and swampweed have worn off." },
            { Key = "ShowOthers", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Every other effect that lasts a while",
              Comment = { "Other effects of the game that last a while, by the game's own name for them (for the",
                          "curious; most are short)." },
              MenuLabel = "Every other effect with a time", Menu = "by the game's own name (for the curious)" },
        },
    },
    {
        Title = "Where",
        Items = {
            { Key = "Position", Kind = "choice", Default = "bottom left", Options = { "bottom left", "top left", "bottom right", "top right" }, Needs = "Enabled",
              Label = "The box sits in the corner",
              Comment = "The corner of the screen the box sits in." },
            { Key = "DistanceX", Kind = "number", Default = 24, Min = 0, Max = 1200, Step = 4, Decimals = 0, Needs = "Enabled",
              Label = "Distance from the side", Unit = "units",
              Comment = "How far the box is from the left or right edge of the screen.",
              Menu = "from the left or right edge of the screen" },
            { Key = "DistanceY", Kind = "number", Default = 200, Min = 0, Max = 800, Step = 4, Decimals = 0, Needs = "Enabled",
              Label = "Distance from the top or bottom", Unit = "units",
              Comment = "How far the box is from the top or bottom edge of the screen.",
              MenuLabel = "Distance from top/bottom (units)", Menu = "from the top or bottom edge of the screen" },
        },
    },
}

return Schema
