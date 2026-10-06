-- Settings of the module keys: the list of your keys, shown and hidden by a key.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "keys"
Schema.Page = "Key list"
Schema.PageOrder = 92
Schema.Header = {
    "Key list settings (module keys of G1R_MegaMod)",
    "Set in the settings app or the in-game mod menu; changes count while the game runs.",
}
Schema.Notes = {
    "The key (F3) shows or hides a small list of your keys at the top left, in the pause menu and while you play.",
    "Other mods' keys are read from their files: SharedModMenu, HUDMap, FocusNearbyPickups, G1R_AutoPickUpItemNative, G1R_PutAwayTorchRedux. Others show \"keys not known\".",
}

Schema.Groups = {
    {
        Title = "List of keys",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "List of keys" },
            { Key = "ListKey", Kind = "key", Default = "F3", Needs = "Enabled",
              Label = "Key that shows or hides the list",
              Comment = "\"\" = no key: the pause menu shows the whole list." },
            { Key = "InPauseMenu", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Key line in the pause menu",
              Comment = "A small line at the top left naming the key." },
            { Key = "OtherMods", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Keys of other mods too" },
            { Key = "TextSize", Kind = "number", Default = 10, Min = 8, Max = 16, Step = 1, Decimals = 0, Needs = "Enabled",
              Label = "Size of the letters",
              Comment = "Notes use 12 (8 to 16)." },
            { Key = "ShowKey", Kind = "key", Default = "", Hidden = true,
              Comment = "The key of version 1.0.0; ListKey has taken its place." },
        },
    },
}

return Schema
