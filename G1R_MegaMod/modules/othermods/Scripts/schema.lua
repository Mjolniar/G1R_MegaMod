-- Settings of the module othermods: settings of two other mods, written into their own files by the settings app.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "othermods"
Schema.Page = "Other mods"
Schema.PageOrder = 95
Schema.Header = {
    "Settings of other mods (module othermods of G1R_MegaMod)",
    'Easiest way to change these: the settings app, page "Other mods". The app writes',
    "them into the other mods' own settings files when it saves with the game closed;",
    "they count from the next start of the game.",
}
Schema.Notes = {
    "These numbers belong to two other mods: FocusNearbyPickups (in PLuaModLoader) and G1R_AutoPickUpItemNative. Each reads its own settings file once, when the game starts. When you press Save with the game closed, this app writes exactly that one line into the mod's file and nothing else (the first version of the file is kept next to it as .before-G1R_MegaMod). It counts from the next start of the game.",
    "A switch that is off leaves the mod's file as it is. These settings are not in the in-game mod menu: the other mods read their files only when the game starts.",
}

Schema.Groups = {
    {
        Title = "Highlight (FocusNearbyPickups)",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "Settings of other mods (this whole part of the mod)",
              Comment = "Switches the settings below on or off; off leaves the other mods' files as they are." },
            { Key = "SetHighlight", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Set how far things are highlighted",
              Comment = { "Writes the distance below into FocusNearbyPickups.ini (its maxRadius) when the settings app",
                          "saves with the game closed. Off: the file is left as it is." } },
            { Key = "HighlightMeters", Kind = "number", Default = 10, Min = 0, Max = 50, Step = 0.5, Decimals = 1, Needs = "SetHighlight",
              Label = "Highlight things up to", Unit = "metres",
              Comment = { "How far away FocusNearbyPickups highlights things, in metres (0 = no limit; the mod's own",
                          "value is 10)." } },
        },
    },
    {
        Title = "Picking up (G1R_AutoPickUpItemNative)",
        Items = {
            { Key = "SetLoot", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Set how far items are picked up",
              Comment = { "Writes the distance below into G1R_AutoPickUpItemNative.ini (its AreaLootingRadius) when the",
                          "settings app saves with the game closed. Off: the file is left as it is." } },
            { Key = "LootMeters", Kind = "number", Default = 5, Min = 0.5, Max = 30, Step = 0.5, Decimals = 1, Needs = "SetLoot",
              Label = "Pick items up within", Unit = "metres",
              Comment = "How far away G1R_AutoPickUpItemNative picks items up, in metres (the mod's own value is 5)." },
        },
    },
}

return Schema
