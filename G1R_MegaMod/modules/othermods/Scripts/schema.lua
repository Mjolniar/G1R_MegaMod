-- Settings of the module othermods: settings of two other mods, written into their own files by the settings app.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "othermods"
Schema.Page = "Other mods"
Schema.PageOrder = 95
Schema.Header = {
    "Settings of other mods (module othermods of G1R_MegaMod)",
    "Set in the settings app. It writes them into the other mods' files on Save with",
    "the game closed; they count from the next start of the game.",
}
Schema.Notes = {
    "Written into the other mod's file on Save, with the game closed: that one line only. The first version is kept as .before-G1R_MegaMod. Counts from the next start.",
    "A switch that is off leaves the file alone. Not in the in-game mod menu.",
}

Schema.Groups = {
    {
        Title = "Highlight (FocusNearbyPickups)",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "Settings of other mods (this whole part)",
              Comment = "Off: the other mods' files are left alone." },
            { Key = "SetHighlight", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Set how far things are highlighted",
              Comment = "Writes FocusNearbyPickups.ini maxRadius." },
            { Key = "HighlightMeters", Kind = "number", Default = 10, Min = 0, Max = 50, Step = 0.5, Decimals = 1, Needs = "SetHighlight",
              Label = "Highlight things up to", Unit = "metres",
              Comment = "0 = no limit. The mod's own: 10." },
        },
    },
    {
        Title = "Picking up (G1R_AutoPickUpItemNative)",
        Items = {
            { Key = "SetLoot", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Set how far items are picked up",
              Comment = "Writes G1R_AutoPickUpItemNative.ini AreaLootingRadius." },
            { Key = "LootMeters", Kind = "number", Default = 5, Min = 0.5, Max = 30, Step = 0.5, Decimals = 1, Needs = "SetLoot",
              Label = "Pick items up within", Unit = "metres",
              Comment = "The mod's own: 5." },
        },
    },
}

return Schema
