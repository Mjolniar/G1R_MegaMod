-- Settings of the module general: what the other modules share on screen.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "general"
Schema.Page = "General"
Schema.PageOrder = 5
Schema.Header = {
    "General settings (module general of G1R_MegaMod)",
    "Set in the settings app or the in-game mod menu; changes count while the game runs.",
}
Schema.Notes = {
    "How the mod's notes look (experience added, time skipped, ore mined). Each part has its own switch for showing them.",
    "Letters: for the notes, the key list and the effect timers. Map names have their own setting (Map > Map pins).",
}

Schema.Groups = {
    {
        Title = "Notes on screen",
        Items = {
            { Key = "NoteStyle", Kind = "choice", Default = "box", Options = { "box", "subtitle", "off" },
              Label = "Notes are shown as",
              Comment = "box: a small box in a corner. subtitle: the game's line at the top. off: no notes." },
            { Key = "NotePosition", Kind = "choice", Default = "top right", Options = { "top right", "top left", "bottom right", "bottom left" },
              Label = "Corner of the box" },
            { Key = "NoteSeconds", Kind = "number", Default = 3, Min = 1, Max = 10, Step = 1, Decimals = 0,
              Label = "A note stays for", Unit = "seconds" },
            { Key = "TestNote", Kind = "action", Label = "Show a note now" },
        },
    },
    {
        Title = "Letters",
        Items = {
            { Key = "Letters", Kind = "choice", Default = "gothic", Options = { "gothic", "book", "plain" },
              Label = "Letters of the mod's texts",
              Comment = "gothic: the game's blackletter. book: the game's text letters. plain: the engine's letters." },
        },
    },
}

return Schema
