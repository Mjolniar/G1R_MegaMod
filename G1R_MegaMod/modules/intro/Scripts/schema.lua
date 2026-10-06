-- Settings of the module intro: what plays when the game starts.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "intro"
Schema.Page = "Game start"
Schema.PageOrder = 90
Schema.Header = {
    "Game start settings (module intro of G1R_MegaMod)",
    'Easiest way to change these: the settings app, page "Interface > Game start".',
    "Skipping the logos is a line in the game's own Game.ini: the settings app",
    "writes it when it saves with the game closed; it counts from the next start.",
}
Schema.Notes = {
    "The logos at the start of the game (Alkimia, THQ Nordic, the legal screen) are a list in the game's own settings. Skipping them is a line in the file Game.ini in the game's settings folder (%LOCALAPPDATA%\\G1R\\Saved\\Config\\Windows): this app writes it when you press Save with the game closed, and takes it out again when you switch the setting off. It counts from the next start of the game; the game's loading picture still shows while the menu loads.",
    "The film of a new game: when you start a new game, the game shows its usual loading screen instead of the film. Loading a save is not touched. (The game itself also lets you skip the film: hold Space, Esc or the left mouse button for a second.)",
    "These two settings are not in the in-game mod menu: the logos cannot be changed while the game runs.",
}

Schema.Groups = {
    {
        Title = "What plays at the start",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "Game start (this whole part of the mod)",
              Comment = "Switches the two settings below on or off." },
            { Key = "SkipLogos", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Skip the logos when the game starts",
              Comment = { "The logos at the start of the game (Alkimia, THQ Nordic, the legal screen) are skipped. The",
                          "settings app writes this into the game's Game.ini when it saves with the game closed; it",
                          "counts from the next start of the game." } },
            { Key = "SkipNewGameFilm", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Skip the film of a new game",
              Comment = { "When you start a new game, its film is not played: the game shows its usual loading screen",
                          "instead. Loading a save is not touched." } },
        },
    },
}

return Schema
