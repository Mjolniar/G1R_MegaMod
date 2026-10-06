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
    "Easiest way to change these: the settings app, page \"Combat\", or the",
    "in-game mod menu. Changes are picked up while the game is running.",
    "With every amount at 0 (the values the mod ships with) nothing regenerates.",
}
-- what the text about the presets (PRESETS.txt) says below this module's values; the game does not read it
Schema.PresetNote = "In preset 1 nothing regenerates (0 per step); the seconds, limits and waits there are the mod's defaults and count when an amount is set by hand."
Schema.Notes = {
    "Regeneration: every few seconds the hero gets an amount back - a share of his maximum, a fixed number of points, or both - until the chosen part of the maximum is reached. After mana was spent or damage was taken it waits for the time you set.",
    "Seconds are seconds of play: nothing regenerates in the pause menu or while a map loads, and sleeping or skipping time gives nothing extra. Amounts are whole points, as the game keeps them; fractions are carried over to the next step.",
    "A hero who is dead or lies unconscious never regenerates. Use one regeneration mod at a time: while the mod G1R_RegenMana is enabled, this module is not loaded.",
}

Schema.Groups = {
    {
        Title = "Mana regeneration",
        Order = 10,
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Tiers = "default",
              Label = "Regeneration of mana and health (this whole part of the mod)",
              Comment = "false = the module does nothing; mana and health stay as the game handles them.",
              MenuLabel = "Regeneration of mana and health", Menu = "off: mana and health as the game handles them" },
            { Key = "ManaEnabled", Kind = "bool", Default = true, Needs = "Enabled",
              Tiers = "default",
              Label = "Mana regenerates",
              Comment = "false = mana does not regenerate. With both amounts below at 0 it does not either." },
            { Key = "ManaPercent", Kind = "number", Default = 0, Min = 0, Max = 100, Step = 0.5, Decimals = 2,
              Tiers = { 0, 1, 2, 5, 100 },
              Label = "Share of the maximum per step", Unit = "%", Needs = "ManaEnabled",
              Comment = { "Each step restores this share of the hero's maximum mana, in percent.",
                          "0 = no share. Example: 2 with 60 maximum mana = 1.2 mana per step." },
              Menu = "each step restores this share of maximum mana" },
            { Key = "ManaFlat", Kind = "number", Default = 0, Min = 0, Max = 1000, Step = 1, Decimals = 1,
              Tiers = "default",
              Label = "Points per step", Unit = "mana", Needs = "ManaEnabled",
              Comment = "Each step also restores this many points of mana, whatever the maximum is. 0 = none.",
              Menu = "each step also restores this many mana points" },
            { Key = "ManaSeconds", Kind = "number", Default = 3, Min = 0.5, Max = 600, Step = 0.5, Decimals = 1,
              Tiers = { 3, 5, 3, 2, 0.5 },
              Label = "A step every", Unit = "seconds", Needs = "ManaEnabled",
              Comment = "The time between two steps, in seconds of play." },
            { Key = "ManaUpTo", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Decimals = 0,
              Tiers = { 100, 50, 75, 100, 100 },
              Label = "Mana regenerates up to", Unit = "% of the maximum", Needs = "ManaEnabled",
              Menu = "Regeneration stops at this part of the maximum mana.",
              Comment = { "Regeneration stops at this part of the maximum mana; the rest takes potions or sleep.",
                          "100 = up to the maximum." },
              MenuLabel = "Mana regenerates up to (% of max)" },
            { Key = "ManaPause", Kind = "number", Default = 10, Min = 0, Max = 3600, Step = 1, Decimals = 0,
              Tiers = { 10, 20, 15, 5, 0 },
              Label = "After mana was spent, wait", Unit = "seconds", Needs = "ManaEnabled",
              Comment = { "After mana went down (a spell), regeneration waits this long before it goes on.",
                          "0 = no waiting. The same wait runs once after a game was loaded." },
              MenuLabel = "Wait after mana was spent (seconds)", Menu = "after a spell, regeneration waits this long" },
            { Key = "ManaArmedPercent", Kind = "number", Default = 100, Min = 0, Max = 500, Step = 10, Decimals = 0,
              Tiers = { 100, 0, 50, 100, 100 },
              Label = "With a weapon or spell drawn", Unit = "% of the usual amount", Needs = "ManaEnabled",
              Menu = "% of the usual amount; 0 = nothing while drawn",
              Comment = { "While the hero holds a drawn weapon, his fists up or a spell ready, each step restores",
                          "this share of the usual amount. 100 = no difference, 0 = nothing, 50 = half." },
              MenuLabel = "With weapon or spell drawn (%)" },
        },
    },
    {
        Title = "Mana regeneration by magic circle", MenuTitle = "Mana by magic circle",
        Order = 14,
        Hint = "Mages can regenerate more than others. The four numbers say how much of the amount above each rank gets.",
        Items = {
            { Key = "ManaByCircle", Kind = "bool", Default = false, Needs = "ManaEnabled",
              Tiers = "default",
              Label = "The amount depends on the hero's magic circle",
              Comment = "false = everyone gets the same amount. true = the four numbers below apply.",
              MenuLabel = "Amount by the hero's magic circle" },
            { Key = "ManaCircleNone", Kind = "number", Default = 50, Min = 0, Max = 1000, Step = 5, Decimals = 0,
              Tiers = "default",
              Label = "Without any magic training", Unit = "%", Needs = "ManaByCircle",
              Comment = "The share of the amount a hero without any magic training gets, in percent.",
              Menu = "share of the amount without magic training" },
            { Key = "ManaCircleNovice", Kind = "number", Default = 75, Min = 0, Max = 1000, Step = 5, Decimals = 0,
              Tiers = "default",
              Label = "With the basics of magic (before the first circle)", Unit = "%", Needs = "ManaByCircle",
              Comment = "The share for a hero who has learned the basics of magic but no circle yet.",
              MenuLabel = "With the basics of magic (%)", Menu = "share with the basics of magic, before 1st circle" },
            { Key = "ManaCircleFirst", Kind = "number", Default = 100, Min = 0, Max = 1000, Step = 5, Decimals = 0,
              Tiers = "default",
              Label = "In the first circle", Unit = "%", Needs = "ManaByCircle",
              Comment = "The share for a mage of the first circle." },
            { Key = "ManaCircleStep", Kind = "number", Default = 10, Min = 0, Max = 500, Step = 5, Decimals = 0,
              Tiers = "default",
              Label = "Each further circle adds", Unit = "%", Needs = "ManaByCircle",
              Comment = { "Each circle above the first adds this many percent.",
                          "Example: 100 in the first circle and 10 here = 150 in the sixth." } },
        },
    },
    {
        Title = "Health regeneration",
        Order = 20,
        Items = {
            { Key = "HealthEnabled", Kind = "bool", Default = true, Needs = "Enabled",
              Tiers = "default",
              Label = "Health regenerates",
              Comment = "false = health does not regenerate. With both amounts below at 0 it does not either." },
            { Key = "HealthPercent", Kind = "number", Default = 0, Min = 0, Max = 100, Step = 0.5, Decimals = 2,
              Tiers = { 0, 0.5, 1, 3, 100 },
              Label = "Share of the maximum per step", Unit = "%", Needs = "HealthEnabled",
              Comment = { "Each step restores this share of the hero's maximum health, in percent.",
                          "0 = no share. Example: 1 with 150 maximum health = 1.5 health per step." },
              Menu = "each step restores this share of maximum health" },
            { Key = "HealthFlat", Kind = "number", Default = 0, Min = 0, Max = 1000, Step = 1, Decimals = 1,
              Tiers = "default",
              Label = "Points per step", Unit = "health", Needs = "HealthEnabled",
              Comment = "Each step also restores this many points of health, whatever the maximum is. 0 = none.",
              Menu = "each step also restores this many health points" },
            { Key = "HealthSeconds", Kind = "number", Default = 5, Min = 0.5, Max = 600, Step = 0.5, Decimals = 1,
              Tiers = { 5, 10, 5, 3, 0.5 },
              Label = "A step every", Unit = "seconds", Needs = "HealthEnabled",
              Comment = "The time between two steps, in seconds of play." },
            { Key = "HealthUpTo", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Decimals = 0,
              Tiers = { 100, 30, 50, 100, 100 },
              Label = "Health regenerates up to", Unit = "% of the maximum", Needs = "HealthEnabled",
              Menu = "Regeneration stops at this part of the maximum health.",
              Comment = { "Regeneration stops at this part of the maximum health; the rest takes food, potions or sleep.",
                          "100 = up to the maximum." },
              MenuLabel = "Health regenerates up to (% of max)" },
            { Key = "HealthPause", Kind = "number", Default = 20, Min = 0, Max = 3600, Step = 1, Decimals = 0,
              Tiers = { 20, 30, 30, 10, 0 },
              Label = "After damage, wait", Unit = "seconds", Needs = "HealthEnabled",
              Comment = { "After health went down (a hit, a fall), regeneration waits this long before it goes on.",
                          "0 = no waiting. The same wait runs once after a game was loaded." },
              Menu = "after a hit or fall, regeneration waits this long" },
            { Key = "HealthArmedPercent", Kind = "number", Default = 100, Min = 0, Max = 500, Step = 10, Decimals = 0,
              Tiers = { 100, 0, 50, 100, 100 },
              Label = "With a weapon or spell drawn", Unit = "% of the usual amount", Needs = "HealthEnabled",
              Menu = "% of the usual amount; 0 = nothing while drawn",
              Comment = { "While the hero holds a drawn weapon, his fists up or a spell ready, each step restores",
                          "this share of the usual amount. 100 = no difference, 0 = nothing, 50 = half." },
              MenuLabel = "With weapon or spell drawn (%)" },
        },
    },
    {
        Title = "Mana regeneration and health regeneration: on screen, log", MenuTitle = "Regeneration: screen, log",
        Order = 28,
        Items = {
            { Key = "ShowMessage", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "Show a short note when regeneration starts again and when it is complete",
              Menu = "a note when it starts again and when it is full",
              Comment = { "A short note on screen when mana or health starts to regenerate after a wait, and when it has",
                          "reached its limit. How notes look is set on the page \"General\"." },
              MenuLabel = "Note when regeneration starts/ends" },
            { Key = "LogSteps", Kind = "bool", Default = false, Needs = "Enabled",
              Label = "One line in UE4SS.log for every step",
              Comment = "One line in UE4SS.log for every step that restored something.",
              MenuLabel = "Log every step", Menu = "one line in UE4SS.log per step that restored some" },
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
