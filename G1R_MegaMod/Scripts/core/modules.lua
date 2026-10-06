-- The modules of the mod, in the order they are loaded.
--   name      the folder below modules/
--   switch    the key in Config.Modules of Scripts/config.lua (false there: the module is not loaded)
--   separate  folder names of mods that do the same job on their own: the module's former self, or
--             another author's mod that acts on the same things in the game. While one of them is
--             installed and enabled next to this mod, the module is not loaded (both would act).
-- The order is also the order of the pages in the in-game mod menu.
return {
    { name = "repopulate", switch = "Repopulate", separate = { "G1R_Repopulate" } },
    { name = "markers", switch = "Markers", separate = { "NPCMarkers" } },
    { name = "general", switch = "General" },
    { name = "regen", switch = "Regen", separate = { "G1R_RegenMana" } },
    { name = "magic", switch = "Magic", separate = { "G1R_MageBalance" } },
    { name = "melee", switch = "Melee" },
    { name = "mining", switch = "Mining", separate = { "BetterMining" } },
    { name = "xp", switch = "Xp", separate = { "EXPModifier" } },
    { name = "locks", switch = "Locks", separate = { "SkillfulLocks" } },
    { name = "wait", switch = "Wait", separate = { "G1R_WaitOnT" } },
    { name = "mount", switch = "Mount" },
    { name = "movement", switch = "Movement" },
    { name = "intro", switch = "Intro" },
    { name = "keys", switch = "Keys" },
    { name = "timers", switch = "Timers" },
    { name = "othermods", switch = "OtherMods" },
}
