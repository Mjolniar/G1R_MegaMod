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
    "Set in the settings app or the in-game mod menu; changes count while the game runs.",
}
Schema.Notes = {
    "These change how a blow looks and feels, not what it does. Neutral values or this part off put the game's back.",
    "Flow helper: the game's own option, kept in your profile. off / on here also set the game's menu entry; game leaves it to that menu.",
}

Schema.Groups = {
    {
        Title = "Melee: clean-ups",
        Order = 60,
        Hint = "Neutral values: game, 100, on.",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Label = "Melee clean-ups",
              Comment = "Off: what it changed is put back." },
            { Key = "FlowHelper", Kind = "choice", Default = "game", Options = { "game", "off", "on" }, Needs = "Enabled",
              Label = "Mirrored follow-up swings (flow helper)",
              Comment = { "The game's option \"fake sloppy combos\": on, the same direction again chains mirrored swings.",
                          "off: only real combos chain. game: left as the game has it." },
              MenuLabel = "Mirrored follow-up swings" },
            { Key = "HitStop", Kind = "number", Default = 100, Min = 0, Max = 300, Step = 10, Decimals = 0, Needs = "Enabled",
              Label = "Hit stop: freeze when a blow lands", Unit = "% of the game's",
              Comment = "100 = unchanged, 0 = none, 200 = twice as long.",
              MenuLabel = "Hit stop (% of the game's)" },
            { Key = "HitShake", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Camera shake on melee hits",
              Comment = "Off: no jolt on melee hits. Other shakes stay." },
        },
    },
    {
        Title = "Melee: on screen",
        Order = 70,
        Items = {
            { Key = "ShowMessage", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Note when one of these changed" },
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
