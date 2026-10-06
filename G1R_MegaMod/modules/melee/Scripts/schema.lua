-- Settings of the module melee, described once: the default config.lua, the
-- groups on the page "Combat" of the settings app and of the in-game mod menu
-- are made from this.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "melee"
Schema.Page = "Combat"
Schema.PageOrder = 10
Schema.Header = {
    "Melee clean-ups (module melee of G1R_MegaMod)",
    "Easiest way to change these: the settings app, page \"Combat\", or the",
    "in-game mod menu. Changes are picked up while the game is running.",
    "With the values the mod ships with nothing of the game is changed.",
}
Schema.Notes = {
    "Melee clean-ups change how a blow looks and feels, not what it does: damage, real combos and their timing stay the game's. What the mod changed is put back when a switch returns to its neutral value or this part is switched off.",
    "The flow helper is an option of the game itself, kept per profile and stored by the game. While it is set to \"off\" or \"on\" here, the game's own menu entry follows this setting; \"game\" hands it back to the game's menu.",
}

Schema.Groups = {
    {
        Title = "Melee: clean-ups",
        Order = 60,
        Hint = "Three things that make close combat look and feel the way it does. Neutral values: game, 100, on.",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "Melee clean-ups (this whole part of the mod)",
              Comment = "false = the module does nothing; what it had changed in the game is put back.",
              MenuLabel = "Melee clean-ups", Menu = "off: what it changed in the game is put back" },
            { Key = "FlowHelper", Kind = "choice", Default = "game", Options = { "game", "off", "on" }, Needs = "Enabled",
              Label = "Mirrored follow-up swings (the game's own flow helper)",
              Comment = { "The game's own option \"fake sloppy combos\" (close combat flow helper). With it on, pressing",
                          "the same attack direction again while a swing ends starts a mirrored follow-up swing:",
                          "hammering one direction looks like a chain. With it off the same swing simply starts",
                          "again, and chains only come from real combos (the right direction at the right moment).",
                          "\"game\" = the mod leaves the option as the game has it. \"off\" / \"on\" = the mod sets it, and",
                          "sets it again when the game or its own menu changes it; the game stores it in your profile." },
              MenuLabel = "Mirrored follow-up swings" },
            { Key = "HitStop", Kind = "number", Default = 100, Min = 0, Max = 300, Step = 10, Decimals = 0, Needs = "Enabled",
              Label = "Hit stop: the freeze when a blow lands", Unit = "% of the game's",
              Menu = "freeze when a blow lands; 0 = none, 200 = twice",
              Comment = { "When a melee blow lands, both fighters stand still for a moment (about a twentieth of a",
                          "second) and then pick up speed again. This is the length of that stop in percent of the",
                          "game's own: 100 = unchanged, 0 = no stop at all, 50 = half as long, 200 = twice as long." },
              MenuLabel = "Hit stop (% of the game's)" },
            { Key = "HitShake", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Camera shake when a melee blow lands",
              Comment = { "false = the camera does not jolt when a melee blow lands or the hero is hit by one.",
                          "Other camera shakes stay (the game's own option \"camera shake\" switches all of them)." },
              MenuLabel = "Camera shake on melee hits", Menu = "off: no jolt when a blow lands or hits you" },
        },
    },
    {
        Title = "Melee: on screen",
        Order = 70,
        Items = {
            { Key = "ShowMessage", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Show a short note when the mod changed one of these in the game",
              Comment = { "A note on screen when the mod has changed one of the three in the game or put it back.",
                          "How notes look is set on the page \"General\"." },
              MenuLabel = "Note when one of these changed", Menu = "a note when the mod changed or put one back" },
        },
    },
    {
        Title = "Melee: advanced",
        Order = 78,
        Items = {
            -- not shown in the app or the menu, not in the shipped file; can be added to config.lua by hand
            -- how the flow helper is set: "auto" = through the game's own option object, through the game's settings
            -- object when that does not work; "option" = only the option object (the game stores the value in the
            -- profile); "direct" = only the settings object (nothing is stored)
            { Key = "FlowMethod", Kind = "choice", Default = "auto", Options = { "auto", "option", "direct" }, Hidden = true },
            -- how often the module looks whether the flow helper is still as set
            { Key = "CheckSeconds", Kind = "number", Default = 3, Min = 1, Max = 60, Decimals = 0, Hidden = true },
            -- how often the module reads the hit stop and camera shake values again to see that they are still in place
            { Key = "VerifySeconds", Kind = "number", Default = 30, Min = 5, Max = 3600, Decimals = 0, Hidden = true },
            -- true = the module also changes things while the engine says the game is paused (a menu is open)
            { Key = "ActWhilePaused", Kind = "bool", Default = false, Hidden = true },
        },
    },
}

return Schema
