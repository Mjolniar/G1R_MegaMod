-- Settings of the module intro: what plays when the game starts.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "intro"
Schema.Page = "Game start"
Schema.PageOrder = 90
Schema.Header = {
    "Game start settings (module intro of G1R_MegaMod)",
    "Set in the settings app. Skipping the logos is a line in the game's Game.ini:",
    "the app writes it on Save with the game closed; it counts from the next start.",
}
Schema.Notes = {
    "Logos: written into the game's Game.ini on Save, with the game closed. Counts from the next start. The loading picture still shows.",
    "New game film: replaced by the usual loading screen. Loading a save is not touched.",
    "Not in the in-game mod menu.",
}

Schema.Groups = {
    {
        Title = "What plays at the start",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "Game start (this whole part)" },
            { Key = "SkipLogos", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Skip the logos when the game starts",
              Comment = "Alkimia, THQ Nordic, the legal screen. Counts from the next start." },
            { Key = "SkipNewGameFilm", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Skip the film of a new game" },
        },
    },
}

return Schema
