-- Settings of the module locks, described once: the default config.lua, the page
-- in the settings app and the entry in the in-game mod menu are made from this.
-- (Plain values only - the settings app reads this file too. See dev/SETTINGS.md.)
local Schema = {}

Schema.Module = "locks"
Schema.Page = "Lock picking"
Schema.PageOrder = 40
Schema.Header = {
    "Lock picking that follows the hero's skill (module locks of G1R_MegaMod)",
    "Set in the settings app or the in-game mod menu; changes count from the next lock.",
}
-- what the text about the presets (PRESETS.txt) says below this module's values; the game does not read it
Schema.PresetNote = "Wrong moves: 0 = the game's own number (2 untrained, 4 skilled, 6 master). The presets use fixed numbers of connections, which count for doors and chests alike; \"safe\" (as many as the lock stays openable with) is only used for the master, where the game's own number is the floor."
Schema.Notes = {
    "Lock pieces are connected: moving one drags others. The game takes connections away as the skill grows: none untrained, 1 skilled, 2 master.",
    "none, 1, 2 and all keep every lock of the game solvable (all 332 checked). half and safe go by the lock, chests only: half its connections, or as many as it stays solvable with. Doors stay as the game has them.",
    "Switching off, or a level back to \"as the game has it\", puts the game's numbers back at once. For a save left with changed numbers: the menu button below, or console locks restore.",
    "Not loaded while the mod SkillfulLocks is enabled.",
}

Schema.Groups = {
    {
        Title = "Lock picking",
        Order = 10,
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true,
              Tiers = "default",
              Label = "Lock picking by skill",
              Comment = "Off: locks and picks as the game has them." },
        },
    },
    {
        Title = "Connections taken away",
        Order = 20,
        Hint = "For each skill level. The game: untrained none, skilled 1, master 2.",
        Items = {
            { Key = "UntrainedConnections", Kind = "choice", Default = "as the game has it",
              Tiers = { "as the game has it", "1", "2", "2", "all" },
              Options = { "as the game has it", "none", "1", "2", "half", "safe", "all" },
              Label = "Untrained", Needs = "Enabled",
              Comment = "The game: none. all = every piece moves alone. half / safe: chests only." },
            { Key = "SkilledConnections", Kind = "choice", Default = "as the game has it",
              Tiers = { "as the game has it", "2", "2", "all", "all" },
              Options = { "as the game has it", "none", "1", "2", "half", "safe", "all" },
              Label = "Skilled", Needs = "Enabled",
              Comment = "The game: 1." },
            { Key = "MasterConnections", Kind = "choice", Default = "as the game has it",
              Tiers = { "as the game has it", "as the game has it", "safe", "all", "all" },
              Options = { "as the game has it", "none", "1", "2", "half", "safe", "all" },
              Label = "Master", Needs = "Enabled",
              Comment = "The game: 2." },
        },
    },
    {
        Title = "Lock picks",
        Order = 30,
        Hint = "A wrong move wears the pick. The game: it breaks after 2 (untrained), 4 (skilled) or 6 (master).",
        Items = {
            { Key = "PicksNeverBreak", Kind = "bool", Default = false,
              Tiers = { false, false, false, false, true },
              Label = "Lock picks do not break", Needs = "Enabled",
              Comment = "The numbers below are then not used." },
            { Key = "UntrainedWrongMoves", Kind = "number", Default = 0, Min = 0, Max = 99, Step = 1, Decimals = 0,
              Tiers = { 0, 4, 6, 10, 99 },
              Label = "Untrained: wrong moves per pick", Unit = "0 = the game's: 2", Needs = "Enabled",
              Comment = "0 = the game's (2). 1 to 99.",
              MenuLabel = "Untrained: wrong moves per pick",
              Menu = "moves before a pick breaks; 0 = the game's (2)" },
            { Key = "SkilledWrongMoves", Kind = "number", Default = 0, Min = 0, Max = 99, Step = 1, Decimals = 0,
              Tiers = { 0, 6, 8, 15, 99 },
              Label = "Skilled: wrong moves per pick", Unit = "0 = the game's: 4", Needs = "Enabled",
              Comment = "0 = the game's (4). 1 to 99.",
              MenuLabel = "Skilled: wrong moves per pick",
              Menu = "moves before a pick breaks; 0 = the game's (4)" },
            { Key = "MasterWrongMoves", Kind = "number", Default = 0, Min = 0, Max = 99, Step = 1, Decimals = 0,
              Tiers = { 0, 8, 10, 20, 99 },
              Label = "Master: wrong moves per pick", Unit = "0 = the game's: 6", Needs = "Enabled",
              Comment = "0 = the game's (6). 1 to 99.",
              MenuLabel = "Master: wrong moves per pick",
              Menu = "moves before a pick breaks; 0 = the game's (6)" },
        },
    },
    {
        Title = "On screen",
        Order = 40,
        Items = {
            { Key = "ShowMessage", Kind = "bool", Default = true, Needs = "Enabled",
              Label = "Note when a lock was changed" },
        },
    },
    {
        Title = "Log",
        Order = 50,
        Items = {
            { Key = "LogLocks", Kind = "bool", Default = false,
              Label = "Log every lock you start on" },
        },
    },
    {
        Title = "Repair",
        Order = 60,
        Hint = "For a save made while the numbers were changed, when the module stays off.",
        Items = {
            -- a button of the in-game mod menu (the settings app cannot reach into the game); console: locks restore
            { Key = "RestoreNow", Kind = "action", Label = "Put the game's own values back now",
              Comment = "Writes the game's numbers for your skill, once." },
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
