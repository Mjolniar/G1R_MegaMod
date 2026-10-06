-- ============================================================================
-- G1R_Repopulate settings (v1.2)
-- Easiest way to change them: G1R_Repopulate_Settings.exe in this mod's folder.
-- Changes are picked up while the game is running (within about 15 seconds).
--
-- Chances: 0.35 = 35 %. Hours are in-game hours: one in-game day is about
-- 96 real minutes (the game clock runs 15x real time); sleeping counts too.
-- ============================================================================
local Config = {}

Config.Enabled = true
-- Seconds to wait after a save is loaded before anything runs.
Config.StartDelaySeconds = 8
-- Extra lines in UE4SS.log (each respawn / restock).
Config.Verbose = false
-- How often (real seconds) this file is checked for changes while playing; 0 = never.
Config.ReloadCheckSeconds = 15

-- Creatures: wolves, scavengers, molerats, bloodflies, snappers, lurkers,
-- goblins, skeletons, zombies, minecrawlers, harpies, ... at their own spawn
-- points. Never: humans, orcs (and orc dogs), named / boss / quest creatures,
-- event spawns, the Sleeper Temple.
Config.Creatures = {
    Enabled = true,
    -- Each missing creature: NormalChance every NormalEveryHours in-game hours.
    NormalChance = 0.35,
    NormalEveryHours = 24,
    -- Elite species use their own chance and interval.
    EliteChance = 0.15,
    EliteEveryHours = 24,
    EliteSpecies = { "ShadowBeast", "ShadowBeastForest", "ShadowBeastCave", "Swampshark", "SkeletonMage", "Troll" },
    -- Per-species settings (override the group values above), e.g.
    --   ["Wolf"] = { Chance = 0.50, EveryHours = 12 },
    --   ["Meatbug"] = { Enabled = false },
    Species = {
    },
    -- Unique names never to respawn, e.g. { "Meatbug" }.
    ExcludeSpecies = {},
    -- Spawn point name prefixes never to respawn, e.g. { "OC_" }.
    ExcludePointPrefixes = {},
    -- Remove one corpse of the same kind from the spot when a creature comes back.
    RemoveCorpsesOnRespawn = true,
    -- A creature only appears (and a corpse only vanishes) while you are at
    -- least this far away (cm; 4000 = 40 m).
    MinPlayerDistance = 4000,
    -- Safety limit per cycle and catch-up after long sleeps.
    MaxSpawnsPerCycle = 150,
    MaxCatchUpCycles = 3,
    SpawnIntervalSeconds = 0.6,
    CensusStatesPerTick = 60,
}

-- Herbs, plants, berries, mushrooms lying in the world.
Config.Herbs = {
    Enabled = true,
    RegrowHours = 24,
}

-- Every other item lying in the world (food, drinks, tools, weapons, ore,
-- potions, ...), except quest / unique / key / map / writing items and items
-- placed by story events. Behaves like a DailyChance roll per in-game day.
Config.WorldItems = {
    Enabled = true,
    DailyChance = 0.15,
    MaxDays = 30,
}

-- Chests, crates, corpses and other containers: their original contents
-- (minus quest / unique / key / map items) come back after you emptied them.
Config.Chests = {
    Enabled = true,
    SettlementDailyChance = 0.30,   -- Old Camp, New Camp, Swamp Camp, Bandit Camp, Old/Free Mine
    WildDailyChance = 0.10,         -- everywhere else
    IncludeLootObjects = true,      -- corpses, bags and similar loot spots
    MaxCatchUpDays = 3,
    -- Containers already emptied before the mod saw them (e.g. looted before
    -- it was installed) roll right away as if emptied this many days ago.
    RetroactiveDays = 3,
    CheckRadius = 2500,             -- cm: containers this close are checked for missing items
}

-- Crime: how people react to what you do. Enabled = true is the game's own
-- behaviour. With Enabled = false the kinds marked true below are switched
-- off: nobody reacts to them, and what you already did of those kinds is
-- forgotten. Hitting or killing people always counts, and story fights are
-- not touched. People who are already after you carry on until that ends.
Config.Crime = {
    Enabled = true,
    DisableTheft = true,            -- stealing, pickpocketing, lockpicking, using other people's things
    DisableTrespassing = true,      -- other people's huts and areas, sneaking around
    DisableWeapons = true,          -- drawn weapons or fists, threatening people, blocking their way
    ForgetOldCrimes = true,         -- also forget what you already did of those kinds
}

return Config
