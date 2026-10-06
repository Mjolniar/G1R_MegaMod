-- Settings of the module regen, described once: the default config.lua, the
-- groups on the page "Combat" of the settings app and of the in-game mod menu
-- are made from this.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "regen"
Schema.Page = "Combat"
Schema.PageOrder = 10
Schema.Header = {
    "Mana and health regeneration (module regen of G1R_MegaMod)",
    "Set in the settings app or the in-game mod menu; changes count while the game runs.",
    "With every amount at 0 (as shipped) nothing regenerates.",
}
-- what the text about the presets (PRESETS.txt) says below this module's values; the game does not read it
Schema.PresetNote = "In preset 1 nothing regenerates (0 per step); the seconds, limits and waits there are the mod's defaults and count when an amount is set by hand."
Schema.Notes = {
    "Every step gives back a share of the maximum, fixed points, or both, up to the limit. After a spell or damage it waits first.",
    "Seconds of play: nothing in the pause menu, while loading, or for sleeping. Not while dead or unconscious.",
    "Not loaded while the mod G1R_RegenMana is enabled.",
}

Schema.Groups = {
    {
        Title = "Mana regeneration",
        Order = 10,
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Tiers = "default",
              Label = "Regeneration of mana and health",
              Comment = "Off: mana and health as the game handles them." },
            { Key = "ManaEnabled", Kind = "bool", Default = true, Needs = "Enabled",
              Tiers = "default",
              Label = "Mana regenerates" },
            { Key = "ManaPercent", Kind = "number", Default = 0, Min = 0, Max = 100, Step = 0.5, Decimals = 2,
              Tiers = { 0, 1, 2, 5, 100 },
              Label = "Share of the maximum per step", Unit = "%", Needs = "ManaEnabled",
              Comment = "0 = none. 2 with 60 maximum mana = 1.2 per step.",
              Menu = "share of maximum mana per step; 0 = none" },
            { Key = "ManaFlat", Kind = "number", Default = 0, Min = 0, Max = 1000, Step = 1, Decimals = 1,
              Tiers = "default",
              Label = "Points per step", Unit = "mana", Needs = "ManaEnabled",
              Comment = "0 = none." },
            { Key = "ManaSeconds", Kind = "number", Default = 3, Min = 0.5, Max = 600, Step = 0.5, Decimals = 1,
              Tiers = { 3, 5, 3, 2, 0.5 },
              Label = "A step every", Unit = "seconds", Needs = "ManaEnabled" },
            { Key = "ManaUpTo", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Decimals = 0,
              Tiers = { 100, 50, 75, 100, 100 },
              Label = "Mana regenerates up to", Unit = "% of the maximum", Needs = "ManaEnabled",
              MenuLabel = "Mana regenerates up to (% of max)" },
            { Key = "ManaPause", Kind = "number", Default = 10, Min = 0, Max = 3600, Step = 1, Decimals = 0,
              Tiers = { 10, 20, 15, 5, 0 },
              Label = "After mana was spent, wait", Unit = "seconds", Needs = "ManaEnabled",
              Comment = "0 = no wait. Also runs once after loading.",
              MenuLabel = "Wait after mana was spent (seconds)" },
            { Key = "ManaArmedPercent", Kind = "number", Default = 100, Min = 0, Max = 500, Step = 10, Decimals = 0,
              Tiers = { 100, 0, 50, 100, 100 },
              Label = "With a weapon or spell drawn", Unit = "% of the usual amount", Needs = "ManaEnabled",
              Comment = "100 = no difference, 0 = nothing.",
              MenuLabel = "With weapon or spell drawn (%)" },
        },
    },
    {
        Title = "Mana regeneration by magic circle", MenuTitle = "Mana by magic circle",
        Order = 14,
        Hint = "Share of the amount above for each magic rank.",
        Items = {
            { Key = "ManaByCircle", Kind = "bool", Default = false, Needs = "ManaEnabled",
              Tiers = "default",
              Label = "Amount by the hero's magic circle" },
            { Key = "ManaCircleNone", Kind = "number", Default = 50, Min = 0, Max = 1000, Step = 5, Decimals = 0,
              Tiers = "default",
              Label = "Without any magic training", Unit = "%", Needs = "ManaByCircle" },
            { Key = "ManaCircleNovice", Kind = "number", Default = 75, Min = 0, Max = 1000, Step = 5, Decimals = 0,
              Tiers = "default",
              Label = "With the basics of magic", Unit = "%", Needs = "ManaByCircle",
              Comment = "Before the first circle." },
            { Key = "ManaCircleFirst", Kind = "number", Default = 100, Min = 0, Max = 1000, Step = 5, Decimals = 0,
              Tiers = "default",
              Label = "In the first circle", Unit = "%", Needs = "ManaByCircle" },
            { Key = "ManaCircleStep", Kind = "number", Default = 10, Min = 0, Max = 500, Step = 5, Decimals = 0,
              Tiers = "default",
              Label = "Each further circle adds", Unit = "%", Needs = "ManaByCircle",
              Comment = "100 in the first and 10 here = 150 in the sixth." },
        },
    },
    {
        Title = "Health regeneration",
        Order = 20,
        Items = {
            { Key = "HealthEnabled", Kind = "bool", Default = true, Needs = "Enabled",
              Tiers = "default",
              Label = "Health regenerates" },
            { Key = "HealthPercent", Kind = "number", Default = 0, Min = 0, Max = 100, Step = 0.5, Decimals = 2,
              Tiers = { 0, 0.5, 1, 3, 100 },
              Label = "Share of the maximum per step", Unit = "%", Needs = "HealthEnabled",
              Comment = "0 = none. 1 with 150 maximum health = 1.5 per step.",
              Menu = "share of maximum health per step; 0 = none" },
            { Key = "HealthFlat", Kind = "number", Default = 0, Min = 0, Max = 1000, Step = 1, Decimals = 1,
              Tiers = "default",
              Label = "Points per step", Unit = "health", Needs = "HealthEnabled",
              Comment = "0 = none." },
            { Key = "HealthSeconds", Kind = "number", Default = 5, Min = 0.5, Max = 600, Step = 0.5, Decimals = 1,
              Tiers = { 5, 10, 5, 3, 0.5 },
              Label = "A step every", Unit = "seconds", Needs = "HealthEnabled" },
            { Key = "HealthUpTo", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Decimals = 0,
              Tiers = { 100, 30, 50, 100, 100 },
              Label = "Health regenerates up to", Unit = "% of the maximum", Needs = "HealthEnabled",
              MenuLabel = "Health regenerates up to (% of max)" },
            { Key = "HealthPause", Kind = "number", Default = 20, Min = 0, Max = 3600, Step = 1, Decimals = 0,
              Tiers = { 20, 30, 30, 10, 0 },
              Label = "After damage, wait", Unit = "seconds", Needs = "HealthEnabled",
              Comment = "0 = no wait. Also runs once after loading." },
            { Key = "HealthArmedPercent", Kind = "number", Default = 100, Min = 0, Max = 500, Step = 10, Decimals = 0,
              Tiers = { 100, 0, 50, 100, 100 },
              Label = "With a weapon or spell drawn", Unit = "% of the usual amount", Needs = "HealthEnabled",
              Comment = "100 = no difference, 0 = nothing.",
              MenuLabel = "With weapon or spell drawn (%)" },
        },
    },
    {
        Title = "Mana regeneration and health regeneration: on screen, log", MenuTitle = "Regeneration: screen, log",
        Order = 28,
        Items = {
            { Key = "ShowMessage", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Note when regeneration starts/ends",
              Comment = "When it starts after a wait and when it is full." },
            { Key = "LogSteps", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Log every step" },
        },
    },
    {
        Title = "Advanced",
        Order = 29,
        Items = {
            -- not shown in the app or the menu, not in the shipped file; can be added to config.lua by hand
            -- how the hero's value is changed: "auto" = the game's own way, a direct write when that does not work;
            -- "game" = only the game's own way; "direct" = only the direct write (the bars on screen lag behind)
            { Key = "Method", Kind = "choice", Default = "auto", Options = { "auto", "game", "direct" }, Hidden = true },
            -- true = when mana comes back from zero, the game's "out of mana" block on casting is taken off
            { Key = "ManaClearBlock", Kind = "bool", Default = true, Hidden = true },
            -- true = no time passes while the engine says the game is paused
            { Key = "StopWhenPaused", Kind = "bool", Default = true, Hidden = true },
            -- true = no time passes while the game's own clock stands still
            { Key = "StopWhenClockStands", Kind = "bool", Default = true, Hidden = true },
            -- the shortest wait after the hero's attributes were found (a loaded game may still be filling them in)
            { Key = "SettleSeconds", Kind = "number", Default = 5, Min = 0, Max = 120, Decimals = 0, Hidden = true },
            -- how often the module looks at the hero's values
            { Key = "LookSeconds", Kind = "number", Default = 0.5, Min = 0.25, Max = 5, Decimals = 2, Hidden = true },
        },
    },
}

return Schema
