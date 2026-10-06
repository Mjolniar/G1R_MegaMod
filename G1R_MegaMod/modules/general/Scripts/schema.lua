-- Settings of the module general: what the other modules share on screen.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "general"
Schema.Page = "General"
Schema.PageOrder = 5
Schema.Header = {
    "General settings (module general of G1R_MegaMod)",
    "Easiest way to change these: the settings app, page \"General\", or the",
    "in-game mod menu. Changes are picked up while the game is running.",
}
Schema.Notes = {
    "Several parts of the mod can show a short note (experience added, time skipped, ore mined). This page says how such a note looks; whether a part shows one at all is that part's own switch.",
    "The letters are those of the boxes the mod puts on screen: the notes, the list of keys, the effect timers. The names on the map screens have a setting of their own (page Map > Map pins; the game's own letters by default).",
}

Schema.Groups = {
    {
        Title = "Notes on screen",
        Items = {
            { Key = "NoteStyle", Kind = "choice", Default = "box", Options = { "box", "subtitle", "off" },
              Label = "Notes are shown as",
              Comment = { "\"box\" = a small box in a corner of the screen; \"subtitle\" = the game's own line at the top",
                          "of the screen (also used when the box cannot be shown); \"off\" = no notes at all." } },
            { Key = "NotePosition", Kind = "choice", Default = "top right", Options = { "top right", "top left", "bottom right", "bottom left" },
              Label = "The box sits in the corner",
              Comment = "The corner of the screen the box sits in." },
            { Key = "NoteSeconds", Kind = "number", Default = 3, Min = 1, Max = 10, Step = 1, Decimals = 0,
              Label = "A note stays for", Unit = "seconds",
              Comment = "How long a note stays on screen, in seconds (1 to 10)." },
            { Key = "TestNote", Kind = "action", Label = "Show a note now",
              Comment = "Shows a note, to see how it looks." },
        },
    },
    {
        Title = "Letters",
        Items = {
            { Key = "Letters", Kind = "choice", Default = "gothic", Options = { "gothic", "book", "plain" },
              Label = "Letters of the mod's texts",
              Comment = { "\"gothic\" = the game's blackletter, as in its headlines; \"book\" = the game's letters for running",
                          "text; \"plain\" = the engine's plain letters (as up to version 0.2.3). The names on the map",
                          "screens have a setting of their own (module markers, NameLetters)." } },
        },
    },
}

return Schema
