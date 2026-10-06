-- Settings of the module keys: the list of your keys, shown and hidden by a key.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "keys"
Schema.Page = "Key list"
Schema.PageOrder = 92
Schema.Header = {
    "Key list settings (module keys of G1R_MegaMod)",
    'Easiest way to change these: the settings app, page "Interface > Key list", or the',
    "in-game mod menu. Changes are picked up while the game is running.",
}
Schema.Notes = {
    "Press the key (F3 unless it is set otherwise) and a small box at the top left lists your keys; press it again and the box goes - in the pause menu and while you play. While the pause menu is open, one small line there names that key.",
    "The list shows the keys of this mod's modules that have a key set, and the keys of the other mods it knows, read from their settings files each time the list comes up: SharedModMenu, HUDMap, FocusNearbyPickups (in PLuaModLoader), G1R_AutoPickUpItemNative and G1R_PutAwayTorchRedux. Another mod that UE4SS starts is named with \"keys not known\". The box takes no clicks.",
}

Schema.Groups = {
    {
        Title = "List of keys",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "List of keys (this whole part of the mod)",
              Comment = "Switches the list of keys on or off.",
              MenuLabel = "List of keys" },
            { Key = "ListKey", Kind = "key", Default = "F3", Needs = "Enabled",
              Label = "Key that shows or hides the list",
              Comment = { "The list comes up when this key is pressed and goes when it is pressed again, in the pause",
                          "menu and while you play; a map load hides it as well. \"\" = no key: the pause menu then",
                          "shows the whole list." } },
            { Key = "InPauseMenu", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "In the pause menu: a line that names the key",
              Comment = "While the pause menu is open, a small line at its top left says which key shows the list.",
              MenuLabel = "Key line in the pause menu", Menu = "a small line at the top left of the pause menu" },
            { Key = "OtherMods", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "List the keys of the other mods too",
              Comment = { "The keys of the other mods the list knows, read from their settings files each time the list",
                          "comes up; another mod that runs is named with \"keys not known\"." },
              Menu = "the keys of the other mods it knows" },
            { Key = "TextSize", Kind = "number", Default = 10, Min = 8, Max = 16, Step = 1, Decimals = 0, Needs = "Enabled",
              Label = "Size of the letters",
              Comment = "The size of the letters of the list and of its line in the pause menu (the notes have 12).",
              Menu = "of the list and its line (the notes have 12)" },
            { Key = "ShowKey", Kind = "key", Default = "", Hidden = true,
              Comment = "The key of version 1.0.0 (none by default); ListKey has taken its place." },
        },
    },
}

return Schema
