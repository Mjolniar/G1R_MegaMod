using System.Globalization;
using System.Text;

namespace G1RRepopulateSettings;

internal sealed class SpeciesOverride
{
    public double? Chance;
    public int? EveryHours;
    public bool? Enabled;
    public bool IsEmpty => Chance == null && EveryHours == null && Enabled == null;
    public SpeciesOverride Clone() => (SpeciesOverride)MemberwiseClone();
}

/// <summary>All values of config.lua (defaults = the shipped balanced settings).</summary>
internal sealed class Settings
{
    // general
    public bool Enabled = true;
    public int StartDelaySeconds = 8;
    public bool Verbose = false;
    public int ReloadCheckSeconds = 15;

    // creatures
    public bool CreaturesEnabled = true;
    public double NormalChance = 0.35;
    public int NormalEveryHours = 24;
    public double EliteChance = 0.15;
    public int EliteEveryHours = 24;
    public List<string> EliteSpecies = new() { "ShadowBeast", "ShadowBeastForest", "ShadowBeastCave", "Swampshark", "SkeletonMage", "Troll" };
    public SortedDictionary<string, SpeciesOverride> Species = new(StringComparer.Ordinal);
    public List<string> ExcludeSpecies = new();
    public List<string> ExcludePointPrefixes = new();
    public bool RemoveCorpsesOnRespawn = true;
    public int MinPlayerDistance = 4000;
    public int MaxSpawnsPerCycle = 150;
    public int MaxCatchUpCycles = 3;
    public double SpawnIntervalSeconds = 0.6;
    public int CensusStatesPerTick = 60;

    // herbs
    public bool HerbsEnabled = true;
    public int RegrowHours = 24;

    // other world items
    public bool WorldItemsEnabled = true;
    public double DailyChance = 0.15;
    public int MaxDays = 30;

    // containers
    public bool ChestsEnabled = true;
    public double SettlementDailyChance = 0.30;
    public double WildDailyChance = 0.10;
    public bool IncludeLootObjects = true;
    public int MaxCatchUpDays = 3;
    public int RetroactiveDays = 3;
    public int CheckRadius = 2500;

    // crime switch (Enabled = the game's own rules)
    public bool CrimeEnabled = true;
    public bool CrimeDisableTheft = true;
    public bool CrimeDisableTrespassing = true;
    public bool CrimeDisableWeapons = true;
    public bool CrimeForgetOld = true;

    // keys this app does not know, per section ("" = top level), kept on save
    public Dictionary<string, List<KeyValuePair<string, object?>>> Extra = new();

    public Settings Clone()
    {
        var c = (Settings)MemberwiseClone();
        c.EliteSpecies = new List<string>(EliteSpecies);
        c.Species = new SortedDictionary<string, SpeciesOverride>(StringComparer.Ordinal);
        foreach (var kv in Species) c.Species[kv.Key] = kv.Value.Clone();
        c.ExcludeSpecies = new List<string>(ExcludeSpecies);
        c.ExcludePointPrefixes = new List<string>(ExcludePointPrefixes);
        c.Extra = Extra.ToDictionary(kv => kv.Key, kv => new List<KeyValuePair<string, object?>>(kv.Value));
        return c;
    }

    // ------------------------------------------------------------------ ranges
    public void Clamp()
    {
        StartDelaySeconds = Math.Clamp(StartDelaySeconds, 0, 600);
        ReloadCheckSeconds = Math.Clamp(ReloadCheckSeconds, 0, 3600);
        NormalChance = Math.Clamp(NormalChance, 0, 1);
        EliteChance = Math.Clamp(EliteChance, 0, 1);
        NormalEveryHours = Math.Clamp(NormalEveryHours, 1, 8760);
        EliteEveryHours = Math.Clamp(EliteEveryHours, 1, 8760);
        foreach (var o in Species.Values)
        {
            if (o.Chance != null) o.Chance = Math.Clamp(o.Chance.Value, 0, 1);
            if (o.EveryHours != null) o.EveryHours = Math.Clamp(o.EveryHours.Value, 1, 8760);
        }
        MinPlayerDistance = Math.Clamp(MinPlayerDistance, 0, 50000);
        MaxSpawnsPerCycle = Math.Clamp(MaxSpawnsPerCycle, 1, 2000);
        MaxCatchUpCycles = Math.Clamp(MaxCatchUpCycles, 1, 30);
        SpawnIntervalSeconds = Math.Clamp(SpawnIntervalSeconds, 0.05, 30);
        CensusStatesPerTick = Math.Clamp(CensusStatesPerTick, 5, 5000);
        RegrowHours = Math.Clamp(RegrowHours, 1, 8760);
        DailyChance = Math.Clamp(DailyChance, 0, 1);
        MaxDays = Math.Clamp(MaxDays, 1, 365);
        SettlementDailyChance = Math.Clamp(SettlementDailyChance, 0, 1);
        WildDailyChance = Math.Clamp(WildDailyChance, 0, 1);
        MaxCatchUpDays = Math.Clamp(MaxCatchUpDays, 1, 30);
        RetroactiveDays = Math.Clamp(RetroactiveDays, 0, 30);
        CheckRadius = Math.Clamp(CheckRadius, 100, 20000);
    }

    // ------------------------------------------------------------------ reading
    private static readonly string[] RootKeys = { "Enabled", "StartDelaySeconds", "Verbose", "ReloadCheckSeconds", "Creatures", "Herbs", "WorldItems", "Chests", "Crime" };
    private static readonly string[] CreatureKeys =
    {
        "Enabled", "NormalChance", "NormalEveryHours", "EliteChance", "EliteEveryHours", "EliteSpecies", "Species",
        "ExcludeSpecies", "ExcludePointPrefixes", "RemoveCorpsesOnRespawn", "MinPlayerDistance", "MaxSpawnsPerCycle",
        "MaxCatchUpCycles", "SpawnIntervalSeconds", "CensusStatesPerTick",
    };
    private static readonly string[] HerbKeys = { "Enabled", "RegrowHours" };
    private static readonly string[] ItemKeys = { "Enabled", "DailyChance", "MaxDays" };
    private static readonly string[] ChestKeys =
        { "Enabled", "SettlementDailyChance", "WildDailyChance", "IncludeLootObjects", "MaxCatchUpDays", "RetroactiveDays", "CheckRadius" };
    private static readonly string[] CrimeKeys = { "Enabled", "DisableTheft", "DisableTrespassing", "DisableWeapons", "ForgetOldCrimes" };

    public static Settings FromText(string text, List<string> warnings) => FromLua(LuaLite.ParseConfig(text), warnings);

    public static Settings FromLua(LuaTable root, List<string> warnings)
    {
        var s = new Settings();
        s.Enabled = B(root, "Enabled", s.Enabled, warnings, "Enabled");
        s.StartDelaySeconds = I(root, "StartDelaySeconds", s.StartDelaySeconds, warnings, "StartDelaySeconds");
        s.Verbose = B(root, "Verbose", s.Verbose, warnings, "Verbose");
        s.ReloadCheckSeconds = I(root, "ReloadCheckSeconds", s.ReloadCheckSeconds, warnings, "ReloadCheckSeconds");
        KeepExtra(s, "", root, RootKeys);

        var c = Section(root, "Creatures", warnings);
        s.CreaturesEnabled = B(c, "Enabled", s.CreaturesEnabled, warnings, "Creatures.Enabled");
        s.NormalChance = D(c, "NormalChance", s.NormalChance, warnings, "Creatures.NormalChance");
        s.NormalEveryHours = I(c, "NormalEveryHours", s.NormalEveryHours, warnings, "Creatures.NormalEveryHours");
        s.EliteChance = D(c, "EliteChance", s.EliteChance, warnings, "Creatures.EliteChance");
        s.EliteEveryHours = I(c, "EliteEveryHours", s.EliteEveryHours, warnings, "Creatures.EliteEveryHours");
        if (c.Has("EliteSpecies")) s.EliteSpecies = L(c, "EliteSpecies", warnings, "Creatures.EliteSpecies");
        s.ExcludeSpecies = L(c, "ExcludeSpecies", warnings, "Creatures.ExcludeSpecies");
        s.ExcludePointPrefixes = L(c, "ExcludePointPrefixes", warnings, "Creatures.ExcludePointPrefixes");
        s.RemoveCorpsesOnRespawn = B(c, "RemoveCorpsesOnRespawn", s.RemoveCorpsesOnRespawn, warnings, "Creatures.RemoveCorpsesOnRespawn");
        s.MinPlayerDistance = I(c, "MinPlayerDistance", s.MinPlayerDistance, warnings, "Creatures.MinPlayerDistance");
        s.MaxSpawnsPerCycle = I(c, "MaxSpawnsPerCycle", s.MaxSpawnsPerCycle, warnings, "Creatures.MaxSpawnsPerCycle");
        s.MaxCatchUpCycles = I(c, "MaxCatchUpCycles", s.MaxCatchUpCycles, warnings, "Creatures.MaxCatchUpCycles");
        s.SpawnIntervalSeconds = D(c, "SpawnIntervalSeconds", s.SpawnIntervalSeconds, warnings, "Creatures.SpawnIntervalSeconds");
        s.CensusStatesPerTick = I(c, "CensusStatesPerTick", s.CensusStatesPerTick, warnings, "Creatures.CensusStatesPerTick");
        if (c.Get("Species") is LuaTable sp)
        {
            foreach (string name in sp.Keys)
            {
                if (sp.Get(name) is not LuaTable o) { warnings.Add($"Creatures.Species[\"{name}\"] is not a table; ignored"); continue; }
                var so = new SpeciesOverride();
                if (o.Get("Chance") is double ch) so.Chance = ch;
                if (o.Get("EveryHours") is double h) so.EveryHours = (int)Math.Round(h);
                if (o.Get("Enabled") is bool en) so.Enabled = en;
                if (!so.IsEmpty) s.Species[name] = so;
            }
        }
        KeepExtra(s, "Creatures", c, CreatureKeys);

        var hb = Section(root, "Herbs", warnings);
        s.HerbsEnabled = B(hb, "Enabled", s.HerbsEnabled, warnings, "Herbs.Enabled");
        s.RegrowHours = I(hb, "RegrowHours", s.RegrowHours, warnings, "Herbs.RegrowHours");
        KeepExtra(s, "Herbs", hb, HerbKeys);

        var wi = Section(root, "WorldItems", warnings);
        s.WorldItemsEnabled = B(wi, "Enabled", s.WorldItemsEnabled, warnings, "WorldItems.Enabled");
        s.DailyChance = D(wi, "DailyChance", s.DailyChance, warnings, "WorldItems.DailyChance");
        s.MaxDays = I(wi, "MaxDays", s.MaxDays, warnings, "WorldItems.MaxDays");
        KeepExtra(s, "WorldItems", wi, ItemKeys);

        var k = Section(root, "Chests", warnings);
        s.ChestsEnabled = B(k, "Enabled", s.ChestsEnabled, warnings, "Chests.Enabled");
        s.SettlementDailyChance = D(k, "SettlementDailyChance", s.SettlementDailyChance, warnings, "Chests.SettlementDailyChance");
        s.WildDailyChance = D(k, "WildDailyChance", s.WildDailyChance, warnings, "Chests.WildDailyChance");
        s.IncludeLootObjects = B(k, "IncludeLootObjects", s.IncludeLootObjects, warnings, "Chests.IncludeLootObjects");
        s.MaxCatchUpDays = I(k, "MaxCatchUpDays", s.MaxCatchUpDays, warnings, "Chests.MaxCatchUpDays");
        s.RetroactiveDays = I(k, "RetroactiveDays", s.RetroactiveDays, warnings, "Chests.RetroactiveDays");
        s.CheckRadius = I(k, "CheckRadius", s.CheckRadius, warnings, "Chests.CheckRadius");
        KeepExtra(s, "Chests", k, ChestKeys);

        // a settings file from before the crime switch has no such section: crime stays on
        var cr = Section(root, "Crime", warnings);
        s.CrimeEnabled = B(cr, "Enabled", s.CrimeEnabled, warnings, "Crime.Enabled");
        s.CrimeDisableTheft = B(cr, "DisableTheft", s.CrimeDisableTheft, warnings, "Crime.DisableTheft");
        s.CrimeDisableTrespassing = B(cr, "DisableTrespassing", s.CrimeDisableTrespassing, warnings, "Crime.DisableTrespassing");
        s.CrimeDisableWeapons = B(cr, "DisableWeapons", s.CrimeDisableWeapons, warnings, "Crime.DisableWeapons");
        s.CrimeForgetOld = B(cr, "ForgetOldCrimes", s.CrimeForgetOld, warnings, "Crime.ForgetOldCrimes");
        KeepExtra(s, "Crime", cr, CrimeKeys);

        s.Clamp();
        return s;
    }

    private static LuaTable Section(LuaTable root, string name, List<string> warnings)
    {
        object? v = root.Get(name);
        if (v is LuaTable t) return t;
        if (v != null) warnings.Add($"{name} is not a table; defaults used");
        return new LuaTable();
    }

    private static void KeepExtra(Settings s, string section, LuaTable t, string[] known)
    {
        var list = new List<KeyValuePair<string, object?>>();
        foreach (string key in t.Keys)
            if (Array.IndexOf(known, key) < 0) list.Add(new(key, t.Get(key)));
        if (list.Count > 0) s.Extra[section] = list;
    }

    private static bool B(LuaTable t, string key, bool def, List<string> w, string path)
    {
        object? v = t.Get(key);
        if (v == null) return def;
        if (v is bool b) return b;
        w.Add($"{path} should be true or false; default used");
        return def;
    }

    private static double D(LuaTable t, string key, double def, List<string> w, string path)
    {
        object? v = t.Get(key);
        if (v == null) return def;
        if (v is double d && !double.IsNaN(d)) return d;
        w.Add($"{path} should be a number; default used");
        return def;
    }

    private static int I(LuaTable t, string key, int def, List<string> w, string path)
    {
        object? v = t.Get(key);
        if (v == null) return def;
        if (v is double d && !double.IsNaN(d) && Math.Abs(d) < int.MaxValue) return (int)Math.Round(d);
        w.Add($"{path} should be a number; default used");
        return def;
    }

    private static List<string> L(LuaTable t, string key, List<string> w, string path)
    {
        var list = new List<string>();
        object? v = t.Get(key);
        if (v == null) return list;
        if (v is LuaTable lt)
        {
            foreach (object? item in lt.Items)
                if (item is string s) list.Add(s); else w.Add($"{path}: non-text entry ignored");
            return list;
        }
        w.Add($"{path} should be a list like {{ \"A\", \"B\" }}; ignored");
        return list;
    }

    // ------------------------------------------------------------------ writing
    // Same layout and comments as the shipped config.lua; values filled in.
    private const string Template = """
-- ============================================================================
-- G1R_Repopulate settings (v1.2)
-- Easiest way to change them: G1R_Repopulate_Settings.exe in this mod's folder.
-- Changes are picked up while the game is running (within about 15 seconds).
--
-- Chances: 0.35 = 35 %. Hours are in-game hours: one in-game day is about
-- 96 real minutes (the game clock runs 15x real time); sleeping counts too.
-- ============================================================================
local Config = {}

Config.Enabled = @Enabled@
-- Seconds to wait after a save is loaded before anything runs.
Config.StartDelaySeconds = @StartDelaySeconds@
-- Extra lines in UE4SS.log (each respawn / restock).
Config.Verbose = @Verbose@
-- How often (real seconds) this file is checked for changes while playing; 0 = never.
Config.ReloadCheckSeconds = @ReloadCheckSeconds@
@ExtraRoot@
-- Creatures: wolves, scavengers, molerats, bloodflies, snappers, lurkers,
-- goblins, skeletons, zombies, minecrawlers, harpies, ... at their own spawn
-- points. Never: humans, orcs (and orc dogs), named / boss / quest creatures,
-- event spawns, the Sleeper Temple.
Config.Creatures = {
    Enabled = @CreaturesEnabled@,
    -- Each missing creature: NormalChance every NormalEveryHours in-game hours.
    NormalChance = @NormalChance@,
    NormalEveryHours = @NormalEveryHours@,
    -- Elite species use their own chance and interval.
    EliteChance = @EliteChance@,
    EliteEveryHours = @EliteEveryHours@,
    EliteSpecies = @EliteSpecies@,
    -- Per-species settings (override the group values above), e.g.
    --   ["Wolf"] = { Chance = 0.50, EveryHours = 12 },
    --   ["Meatbug"] = { Enabled = false },
    Species = {
@SpeciesLines@    },
    -- Unique names never to respawn, e.g. { "Meatbug" }.
    ExcludeSpecies = @ExcludeSpecies@,
    -- Spawn point name prefixes never to respawn, e.g. { "OC_" }.
    ExcludePointPrefixes = @ExcludePointPrefixes@,
    -- Remove one corpse of the same kind from the spot when a creature comes back.
    RemoveCorpsesOnRespawn = @RemoveCorpsesOnRespawn@,
    -- A creature only appears (and a corpse only vanishes) while you are at
    -- least this far away (cm; 4000 = 40 m).
    MinPlayerDistance = @MinPlayerDistance@,
    -- Safety limit per cycle and catch-up after long sleeps.
    MaxSpawnsPerCycle = @MaxSpawnsPerCycle@,
    MaxCatchUpCycles = @MaxCatchUpCycles@,
    SpawnIntervalSeconds = @SpawnIntervalSeconds@,
    CensusStatesPerTick = @CensusStatesPerTick@,
@ExtraCreatures@}

-- Herbs, plants, berries, mushrooms lying in the world.
Config.Herbs = {
    Enabled = @HerbsEnabled@,
    RegrowHours = @RegrowHours@,
@ExtraHerbs@}

-- Every other item lying in the world (food, drinks, tools, weapons, ore,
-- potions, ...), except quest / unique / key / map / writing items and items
-- placed by story events. Behaves like a DailyChance roll per in-game day.
Config.WorldItems = {
    Enabled = @WorldItemsEnabled@,
    DailyChance = @DailyChance@,
    MaxDays = @MaxDays@,
@ExtraWorldItems@}

-- Chests, crates, corpses and other containers: their original contents
-- (minus quest / unique / key / map items) come back after you emptied them.
Config.Chests = {
    Enabled = @ChestsEnabled@,
    SettlementDailyChance = @SettlementDailyChance@,   -- Old Camp, New Camp, Swamp Camp, Bandit Camp, Old/Free Mine
    WildDailyChance = @WildDailyChance@,         -- everywhere else
    IncludeLootObjects = @IncludeLootObjects@,      -- corpses, bags and similar loot spots
    MaxCatchUpDays = @MaxCatchUpDays@,
    -- Containers already emptied before the mod saw them (e.g. looted before
    -- it was installed) roll right away as if emptied this many days ago.
    RetroactiveDays = @RetroactiveDays@,
    CheckRadius = @CheckRadius@,             -- cm: containers this close are checked for missing items
@ExtraChests@}

-- Crime: how people react to what you do. Enabled = true is the game's own
-- behaviour. With Enabled = false the kinds marked true below are switched
-- off: nobody reacts to them, and what you already did of those kinds is
-- forgotten. Hitting or killing people always counts, and story fights are
-- not touched. People who are already after you carry on until that ends.
Config.Crime = {
    Enabled = @CrimeEnabled@,
    DisableTheft = @CrimeDisableTheft@,            -- stealing, pickpocketing, lockpicking, using other people's things
    DisableTrespassing = @CrimeDisableTrespassing@,      -- other people's huts and areas, sneaking around
    DisableWeapons = @CrimeDisableWeapons@,          -- drawn weapons or fists, threatening people, blocking their way
    ForgetOldCrimes = @CrimeForgetOld@,         -- also forget what you already did of those kinds
@ExtraCrime@}

return Config

""";

    private static string Bool(bool b) => b ? "true" : "false";
    private static string Int(int i) => i.ToString(CultureInfo.InvariantCulture);

    private static string List(IEnumerable<string> items)
    {
        var l = items.ToList();
        return l.Count == 0 ? "{}" : "{ " + string.Join(", ", l.Select(LuaLite.Str)) + " }";
    }

    private string ExtraLines(string section, string indent, bool topLevel)
    {
        if (!Extra.TryGetValue(section, out var list) || list.Count == 0) return "";
        var sb = new StringBuilder();
        sb.Append(indent).Append("-- other settings found in this file (kept as they were)\n");
        foreach (var kv in list)
        {
            string key = LuaLite.IsIdent(kv.Key) ? kv.Key : "[" + LuaLite.Str(kv.Key) + "]";
            if (topLevel)
                sb.Append("Config.").Append(kv.Key).Append(" = ").Append(LuaLite.Value(kv.Value)).Append('\n');
            else
                sb.Append(indent).Append(key).Append(" = ").Append(LuaLite.Value(kv.Value)).Append(",\n");
        }
        return sb.ToString();
    }

    public string ToLua()
    {
        Clamp();
        var species = new StringBuilder();
        foreach (var kv in Species)
        {
            var o = kv.Value;
            if (o.IsEmpty) continue;
            var parts = new List<string>();
            if (o.Chance != null) parts.Add("Chance = " + LuaLite.Chance(o.Chance.Value));
            if (o.EveryHours != null) parts.Add("EveryHours = " + Int(o.EveryHours.Value));
            if (o.Enabled != null) parts.Add("Enabled = " + Bool(o.Enabled.Value));
            species.Append("        [").Append(LuaLite.Str(kv.Key)).Append("] = { ").Append(string.Join(", ", parts)).Append(" },\n");
        }
        // top-level extras must be valid identifiers to be written as Config.X
        string extraRoot = "";
        if (Extra.TryGetValue("", out var rootExtra))
        {
            rootExtra.RemoveAll(kv => !LuaLite.IsIdent(kv.Key));
            extraRoot = ExtraLines("", "", true);
        }
        var map = new Dictionary<string, string>
        {
            ["Enabled"] = Bool(Enabled),
            ["StartDelaySeconds"] = Int(StartDelaySeconds),
            ["Verbose"] = Bool(Verbose),
            ["ReloadCheckSeconds"] = Int(ReloadCheckSeconds),
            ["ExtraRoot"] = extraRoot,
            ["CreaturesEnabled"] = Bool(CreaturesEnabled),
            ["NormalChance"] = LuaLite.Chance(NormalChance),
            ["NormalEveryHours"] = Int(NormalEveryHours),
            ["EliteChance"] = LuaLite.Chance(EliteChance),
            ["EliteEveryHours"] = Int(EliteEveryHours),
            ["EliteSpecies"] = List(EliteSpecies),
            ["SpeciesLines"] = species.ToString(),
            ["ExcludeSpecies"] = List(ExcludeSpecies),
            ["ExcludePointPrefixes"] = List(ExcludePointPrefixes),
            ["RemoveCorpsesOnRespawn"] = Bool(RemoveCorpsesOnRespawn),
            ["MinPlayerDistance"] = Int(MinPlayerDistance),
            ["MaxSpawnsPerCycle"] = Int(MaxSpawnsPerCycle),
            ["MaxCatchUpCycles"] = Int(MaxCatchUpCycles),
            ["SpawnIntervalSeconds"] = LuaLite.Num(SpawnIntervalSeconds),
            ["CensusStatesPerTick"] = Int(CensusStatesPerTick),
            ["ExtraCreatures"] = ExtraLines("Creatures", "    ", false),
            ["HerbsEnabled"] = Bool(HerbsEnabled),
            ["RegrowHours"] = Int(RegrowHours),
            ["ExtraHerbs"] = ExtraLines("Herbs", "    ", false),
            ["WorldItemsEnabled"] = Bool(WorldItemsEnabled),
            ["DailyChance"] = LuaLite.Chance(DailyChance),
            ["MaxDays"] = Int(MaxDays),
            ["ExtraWorldItems"] = ExtraLines("WorldItems", "    ", false),
            ["ChestsEnabled"] = Bool(ChestsEnabled),
            ["SettlementDailyChance"] = LuaLite.Chance(SettlementDailyChance),
            ["WildDailyChance"] = LuaLite.Chance(WildDailyChance),
            ["IncludeLootObjects"] = Bool(IncludeLootObjects),
            ["MaxCatchUpDays"] = Int(MaxCatchUpDays),
            ["RetroactiveDays"] = Int(RetroactiveDays),
            ["CheckRadius"] = Int(CheckRadius),
            ["ExtraChests"] = ExtraLines("Chests", "    ", false),
            ["CrimeEnabled"] = Bool(CrimeEnabled),
            ["CrimeDisableTheft"] = Bool(CrimeDisableTheft),
            ["CrimeDisableTrespassing"] = Bool(CrimeDisableTrespassing),
            ["CrimeDisableWeapons"] = Bool(CrimeDisableWeapons),
            ["CrimeForgetOld"] = Bool(CrimeForgetOld),
            ["ExtraCrime"] = ExtraLines("Crime", "    ", false),
        };
        string text = Template.Replace("\r\n", "\n");
        foreach (var kv in map) text = text.Replace("@" + kv.Key + "@", kv.Value);
        // an empty @ExtraRoot@ line would leave a blank line: keep the shipped layout
        text = text.Replace("Config.ReloadCheckSeconds = " + map["ReloadCheckSeconds"] + "\n\n\n", "Config.ReloadCheckSeconds = " + map["ReloadCheckSeconds"] + "\n\n");
        return text;
    }

    // ------------------------------------------------------------------ comparisons (self test)
    public string Fingerprint()
    {
        var c = Clone();
        c.Extra = new();
        return c.ToLua();
    }
}
