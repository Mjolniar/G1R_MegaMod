-- Settings of the module locks, described once: the default config.lua, the page
-- in the settings app and the entry in the in-game mod menu are made from this.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "locks"
Schema.Page = "Lock picking"
Schema.PageOrder = 40
Schema.Header = {
    "Lock picking that follows the hero's skill (module locks of G1R_MegaMod)",
    "Easiest way to change these: the settings app, page \"Lock picking\", or the",
    "in-game mod menu. Changes are picked up while the game is running; they take",
    "effect with the next lock (never in the middle of one).",
}
-- what the text about the presets (PRESETS.txt) says below this module's values; the game does not read it
Schema.PresetNote = "Wrong moves: 0 = the game's own number (2 untrained, 4 skilled, 6 master). The presets use fixed numbers of connections, which count for doors and chests alike; \"safe\" (as many as the lock stays openable with) is only used for the master, where the game's own number is the floor."
Schema.Notes = {
    "The pieces of a lock are connected: moving one drags others along. The game takes connections away as the hero's lock picking skill grows - none for the untrained, the first one for the skilled, the first two for a master. Here you choose that number for each of the three skill levels.",
    "\"none\", \"1\", \"2\" and \"all\" leave every lock solvable that a chest or a door of the game has (332 locks, each checked move by move). Other fixed numbers are not offered: 78 of those locks cannot be opened any more with some number between 3 and all of their connections taken away.",
    "\"half\" and \"safe\" go by the lock, for chests: half of its connections, or as many as the lock is proven to stay solvable with (for three locks in four that is all of them) - never fewer than the game takes away itself. Doors, and any lock the module does not know in time, are left as the game has them.",
    "A lock pick wears with every move a piece cannot make and breaks after 2 (untrained), 4 (skilled) or 6 (master) such moves. That number can be set too. (The game also takes a worn pick away when the hero leaves a lock without opening it; that stays as it is.)",
    "The game keeps both numbers in its saves. Switching the module off, or setting a level back to \"as the game has it\", puts the game's own numbers back at once. If changed numbers were left in a save (the game was closed while the module had them changed, and the module stays off afterwards): the in-game mod menu has the button \"Put the game's own values back now\" on this page, and the console command locks restore does the same.",
    "Use one such mod at a time: while the mod SkillfulLocks is enabled, this module is not loaded.",
}

Schema.Groups = {
    {
        Title = "Lock picking",
        Order = 10,
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Tiers = "default",
              Label = "Change lock picking by the hero's skill",
              Comment = "false = the module does nothing; locks and lock picks are as the game has them.",
              MenuLabel = "Lock picking by skill", Menu = "off: locks and picks as the game has them" },
        },
    },
    {
        Title = "Connections taken away",
        Order = 20,
        Hint = "How many of a lock's connections are taken away, for each level of the lock picking skill. The game: untrained none, skilled 1, master 2.",
        Items = {
            { Key = "UntrainedConnections", Kind = "choice", Default = "as the game has it",
              Tiers = { "as the game has it", "1", "2", "2", "all" },
              Options = { "as the game has it", "none", "1", "2", "half", "safe", "all" },
              Label = "Untrained", Needs = "Enabled",
              Comment = { "Connections taken away from a lock while the hero is untrained in lock picking.",
                          "\"as the game has it\" (none), \"none\", \"1\", \"2\", \"all\" (every piece moves alone), or - for chests,",
                          "by the lock - \"half\" (half of the lock's connections) or \"safe\" (as many as the lock is proven",
                          "to stay solvable with)." } },
            { Key = "SkilledConnections", Kind = "choice", Default = "as the game has it",
              Tiers = { "as the game has it", "2", "2", "all", "all" },
              Options = { "as the game has it", "none", "1", "2", "half", "safe", "all" },
              Label = "Skilled", Needs = "Enabled",
              Comment = { "The same while the hero is skilled (first level of the skill).",
                          "\"as the game has it\" (1), \"none\", \"1\", \"2\", \"half\", \"safe\" or \"all\"." } },
            { Key = "MasterConnections", Kind = "choice", Default = "as the game has it",
              Tiers = { "as the game has it", "as the game has it", "safe", "all", "all" },
              Options = { "as the game has it", "none", "1", "2", "half", "safe", "all" },
              Label = "Master", Needs = "Enabled",
              Comment = { "The same while the hero is a master (second level of the skill).",
                          "\"as the game has it\" (2), \"none\", \"1\", \"2\", \"half\", \"safe\" or \"all\"." } },
        },
    },
    {
        Title = "Lock picks",
        Order = 30,
        Hint = "A move that a piece cannot make wears the lock pick. The game lets a pick take 2 (untrained), 4 (skilled) or 6 (master) such moves before it breaks.",
        Items = {
            { Key = "PicksNeverBreak", Kind = "bool", Default = false,
              Tiers = { false, false, false, false, true },
              Label = "Lock picks do not break", Needs = "Enabled",
              Comment = { "true = a lock pick does not break, whatever the hero's skill.",
                          "The three numbers below are not used then. (A pick that has made a wrong move is still used up",
                          "when the hero leaves the lock without opening it: that is the game's own rule.)" },
              Menu = "a pick never breaks, whatever the skill" },
            { Key = "UntrainedWrongMoves", Kind = "number", Default = 0, Min = 0, Max = 99, Step = 1, Decimals = 0,
              Tiers = { 0, 4, 6, 10, 99 },
              Label = "Untrained: wrong moves before a pick breaks", Unit = "0 = as the game has it: 2", Needs = "Enabled",
              Comment = { "Wrong moves a lock pick takes before it breaks while the hero is untrained.",
                          "0 = as the game has it (2). From 1 to 99." },
              MenuLabel = "Untrained: wrong moves per pick", Menu = "moves before a pick breaks; 0 = the game's (2)" },
            { Key = "SkilledWrongMoves", Kind = "number", Default = 0, Min = 0, Max = 99, Step = 1, Decimals = 0,
              Tiers = { 0, 6, 8, 15, 99 },
              Label = "Skilled: wrong moves before a pick breaks", Unit = "0 = as the game has it: 4", Needs = "Enabled",
              Comment = "The same while the hero is skilled. 0 = as the game has it (4).",
              MenuLabel = "Skilled: wrong moves per pick", Menu = "moves before a pick breaks; 0 = the game's (4)" },
            { Key = "MasterWrongMoves", Kind = "number", Default = 0, Min = 0, Max = 99, Step = 1, Decimals = 0,
              Tiers = { 0, 8, 10, 20, 99 },
              Label = "Master: wrong moves before a pick breaks", Unit = "0 = as the game has it: 6", Needs = "Enabled",
              Comment = "The same while the hero is a master. 0 = as the game has it (6).",
              MenuLabel = "Master: wrong moves per pick", Menu = "moves before a pick breaks; 0 = the game's (6)" },
        },
    },
    {
        Title = "On screen",
        Order = 40,
        Items = {
            { Key = "ShowMessage", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Show a short note when a lock was changed",
              Comment = { "A short note on screen when the hero starts on a lock that this module changed.",
                          "How notes look is set on the page \"General\"." },
              MenuLabel = "Note when a lock was changed", Menu = "a short note when you start on a changed lock" },
        },
    },
    {
        Title = "Log",
        Order = 50,
        Items = {
            { Key = "LogLocks", Kind = "bool", Default = false,
              Label = "One line in UE4SS.log for every lock the hero starts on",
              Comment = "One line in UE4SS.log for every lock the hero starts on, with what was changed for it.",
              MenuLabel = "Log every lock you start on", Menu = "one line in UE4SS.log, with what was changed" },
        },
    },
    {
        Title = "Repair",
        Order = 60,
        Hint = "For a save that was made while this module had changed the numbers, when the module is to stay off afterwards.",
        Items = {
            -- a button of the in-game mod menu (the settings app cannot reach into the game); console: locks restore
            { Key = "RestoreNow", Kind = "action", Label = "Put the game's own values back now",
              Comment = "Writes the game's own numbers for the hero's skill level, once. Works while the module changes nothing.",
              Menu = "writes the game's numbers for your skill, once" },
        },
    },
    {
        Title = "Advanced",
        Items = {
            -- not shown in the app or the menu, not in the shipped file; can be added to config.lua by hand
            { Key = "LookSeconds", Kind = "number", Default = 1, Min = 0.25, Max = 10, Decimals = 2, Hidden = true },
        },
    },
}

return Schema
