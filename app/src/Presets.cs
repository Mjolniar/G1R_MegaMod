using System.Globalization;
using System.Text;

namespace G1RRepopulateSettings;

/// <summary>
/// The five presets of the "Preset" box above the pages: sets of settings from the game itself
/// (1, the hardest) to as easy as the settings allow (5). A preset sets everything that makes the
/// game easier or harder, on every page. For the modules that describe their settings in a
/// schema.lua the values stand in the schema (the field Tiers of an item, dev/SETTINGS.md section 7
/// of the mod - the game does not read it); for the repopulate module, whose pages are written by
/// hand, they stand here.
/// </summary>
internal static class Presets
{
    public const int Count = 5;
    public static readonly string[] Names = { "1 - Base game (hardest)", "2 - Relaxed", "3 - Easy", "4 - Very easy", "5 - Easiest" };

    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    // =====================================================================
    // schema items: the field Tiers
    // =====================================================================
    /// <summary>
    /// The five values of an item (bool | double | string), or what is wrong with its Tiers - in the
    /// words of dev/tools/presets.lua of the mod, which checks the same rules. rawMin / rawMax: Min and
    /// Max as the schema has them (for the message).
    /// </summary>
    public static string? Read(SchemaItem item, object? tiers, object? rawMin, object? rawMax, out List<object>? values)
    {
        values = null;
        string key = item.Key;
        string five = key + ": Tiers must be " + Count.ToString(Inv) + " values or \"default\"";
        if (item.Kind != ItemKind.Bool && item.Kind != ItemKind.Number && item.Kind != ItemKind.Choice) return key + ": Tiers are for yes/no, number and choice items";
        if (item.Hidden) return key + ": a hidden item cannot have Tiers (the app has no control for it)";
        var list = new List<object>();
        if (tiers is string word)
        {
            if (word != "default") return five;
            for (int i = 0; i < Count; i++) list.Add(item.Default!);
            values = list;
            return null;
        }
        if (tiers is not PlainTable table) return five;
        var given = table.Sequence();
        if (given.Count != Count || table.EntryCount != Count) return five;
        for (int i = 0; i < Count; i++)
        {
            object? v = given[i];
            string tier = key + ": tier " + (i + 1).ToString(Inv);
            switch (item.Kind)
            {
                case ItemKind.Bool:
                    if (v is not bool) return tier + " must be true or false";
                    list.Add(v);
                    break;
                case ItemKind.Number:
                    {
                        double? n = v switch { long l => l, double d => d, _ => null };
                        if (n == null || double.IsNaN(n.Value) || n.Value < item.Min || n.Value > item.Max)
                            return tier + " must be a number from " + LuaPlain.ToText(rawMin) + " to " + LuaPlain.ToText(rawMax);
                        // as config.lua holds a value of this item: with at most Decimals places
                        double scaled = n.Value * Math.Pow(10, Math.Max(0, item.Decimals));
                        if (Math.Abs(scaled - Math.Floor(scaled + 0.5)) >= 1e-6) return tier + " has more places than Decimals allows";
                        list.Add(SettingsRules.Checked(item, n.Value, out _));
                        break;
                    }
                default:
                    if (v is not string choice || !item.Options.Contains(choice, StringComparer.Ordinal)) return tier + " is not one of the Options";
                    list.Add(choice);
                    break;
            }
        }
        if (!SettingsRules.Same(list[0], item.Default)) return key + ": tier 1 is the game itself - it must be the item's Default";
        values = list;
        return null;
    }

    // =====================================================================
    // the repopulate module
    // =====================================================================
    /// <summary>
    /// What a preset sets in the repopulate module's config.lua, besides three switches that are on in every preset
    /// (the module itself, loot spots, forgetting old crimes). Per-species settings stay as they are.
    /// </summary>
    public sealed class Repop
    {
        public bool Creatures; public double NormalChance; public int NormalHours; public double EliteChance; public int EliteHours;
        public bool Herbs; public int RegrowHours;
        public bool Items; public double ItemChance;
        public bool Chests; public double SettlementChance, WildChance;
        /// <summary>true = the game's own rules; false = the kinds below are switched off.</summary>
        public bool Crime; public bool NoTheft, NoTrespassing, NoWeapons;
    }

    public static readonly Repop[] ForRepopulate =
    {
        // 1: the game itself - nothing comes back, the crime system as the game has it (the numbers are the mod's
        //    usual ones: they count again as soon as a part is switched on by hand)
        new() { Creatures = false, NormalChance = 0.35, NormalHours = 24, EliteChance = 0.15, EliteHours = 24, Herbs = false, RegrowHours = 24,
                Items = false, ItemChance = 0.15, Chests = false, SettlementChance = 0.30, WildChance = 0.10,
                Crime = true, NoTheft = true, NoTrespassing = true, NoWeapons = true },
        // 2: the world fills up again slowly
        new() { Creatures = true, NormalChance = 0.15, NormalHours = 48, EliteChance = 0.05, EliteHours = 72, Herbs = true, RegrowHours = 72,
                Items = true, ItemChance = 0.05, Chests = true, SettlementChance = 0.10, WildChance = 0.03,
                Crime = true, NoTheft = true, NoTrespassing = true, NoWeapons = true },
        // 3: the mod's usual pace; nobody minds a drawn weapon
        new() { Creatures = true, NormalChance = 0.35, NormalHours = 24, EliteChance = 0.15, EliteHours = 24, Herbs = true, RegrowHours = 24,
                Items = true, ItemChance = 0.15, Chests = true, SettlementChance = 0.30, WildChance = 0.10,
                Crime = false, NoTheft = false, NoTrespassing = false, NoWeapons = true },
        // 4: fast; trespassing is no crime either
        new() { Creatures = true, NormalChance = 0.60, NormalHours = 24, EliteChance = 0.30, EliteHours = 24, Herbs = true, RegrowHours = 12,
                Items = true, ItemChance = 0.30, Chests = true, SettlementChance = 0.50, WildChance = 0.25,
                Crime = false, NoTheft = false, NoTrespassing = true, NoWeapons = true },
        // 5: herbs every hour, items and containers every day, no crime at all. Creatures twice a day: the
        //    shortest interval (1 hour) would only crowd the paths again, which makes nothing easier.
        new() { Creatures = true, NormalChance = 1.00, NormalHours = 12, EliteChance = 1.00, EliteHours = 12, Herbs = true, RegrowHours = 1,
                Items = true, ItemChance = 1.00, Chests = true, SettlementChance = 1.00, WildChance = 1.00,
                Crime = false, NoTheft = true, NoTrespassing = true, NoWeapons = true },
    };

    /// <summary>Sets the repopulate settings of a preset (tier 1 .. 5).</summary>
    public static void Apply(Settings s, int tier)
    {
        var p = ForRepopulate[tier - 1];
        s.Enabled = true;
        s.IncludeLootObjects = true;        // loot spots restock with the containers
        s.CrimeForgetOld = true;            // what was done of the kinds a preset allows is forgotten
        s.CreaturesEnabled = p.Creatures; s.NormalChance = p.NormalChance; s.NormalEveryHours = p.NormalHours;
        s.EliteChance = p.EliteChance; s.EliteEveryHours = p.EliteHours;
        s.HerbsEnabled = p.Herbs; s.RegrowHours = p.RegrowHours;
        s.WorldItemsEnabled = p.Items; s.DailyChance = p.ItemChance;
        s.ChestsEnabled = p.Chests; s.SettlementDailyChance = p.SettlementChance; s.WildDailyChance = p.WildChance;
        s.CrimeEnabled = p.Crime; s.CrimeDisableTheft = p.NoTheft; s.CrimeDisableTrespassing = p.NoTrespassing; s.CrimeDisableWeapons = p.NoWeapons;
    }

    private static bool Close(double a, double b) => Math.Abs(a - b) < 1e-9;

    /// <summary>The repopulate settings are exactly what the preset sets (also where a value has no effect while its part is off).</summary>
    public static bool Matches(Settings s, int tier)
    {
        var p = ForRepopulate[tier - 1];
        return s.Enabled && s.IncludeLootObjects && s.CrimeForgetOld
            && s.CreaturesEnabled == p.Creatures && Close(s.NormalChance, p.NormalChance) && s.NormalEveryHours == p.NormalHours
            && Close(s.EliteChance, p.EliteChance) && s.EliteEveryHours == p.EliteHours
            && s.HerbsEnabled == p.Herbs && s.RegrowHours == p.RegrowHours
            && s.WorldItemsEnabled == p.Items && Close(s.DailyChance, p.ItemChance)
            && s.ChestsEnabled == p.Chests && Close(s.SettlementDailyChance, p.SettlementChance) && Close(s.WildDailyChance, p.WildChance)
            && s.CrimeEnabled == p.Crime && s.CrimeDisableTheft == p.NoTheft && s.CrimeDisableTrespassing == p.NoTrespassing && s.CrimeDisableWeapons == p.NoWeapons;
    }

    // =====================================================================
    // the document (PRESETS.txt of the mod)
    // =====================================================================
    private static string YesNo(bool b) => b ? "yes" : "no";
    private static string Percent(double share) => (share * 100).ToString("0.##", Inv) + " %";

    private static string ValueText(object value) => value switch
    {
        bool b => YesNo(b),
        double d => d.ToString("0.###", Inv),
        string s => s == "as the game has it" ? "game" : ByteText.ToUnicode(s),
        _ => "?",
    };

    private const int NameWidth = 30, ColumnWidth = 10;

    private static void Row(StringBuilder sb, string name, IReadOnlyList<string> values)
    {
        sb.Append("  ").Append(name.PadRight(NameWidth));
        for (int i = 0; i < values.Count; i++) sb.Append(i == values.Count - 1 ? values[i] : values[i].PadRight(ColumnWidth));
        sb.Append('\n');
    }

    private static void Head(StringBuilder sb, string title)
    {
        sb.Append('\n').Append(title).Append('\n');
        Row(sb, "", new[] { "1", "2", "3", "4", "5" });
    }

    private static void Wrapped(StringBuilder sb, string indent, string text, int width = 76)
    {
        var line = new StringBuilder(indent);
        foreach (string word in text.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (line.Length + word.Length + 1 > width && line.Length > indent.Length)
            {
                sb.Append(line.ToString().TrimEnd()).Append('\n');
                line.Clear().Append(indent);
            }
            line.Append(word).Append(' ');
        }
        if (line.Length > indent.Length) sb.Append(line.ToString().TrimEnd()).Append('\n');
    }

    /// <summary>
    /// The presets as a text: what each one sets, for every module. The mod ships it as PRESETS.txt
    /// ("filetests --presets" writes it, "filetests --live" checks that it is up to date).
    /// </summary>
    public static string Document(MegaMod? mega)
    {
        var sb = new StringBuilder();
        sb.Append("G1R_MegaMod - the five presets of the settings app\n");
        sb.Append("==================================================\n\n");
        Wrapped(sb, "", "Above its pages the settings app has a box \"Preset\" with five sets of settings, from the game itself to as easy as the settings allow. "
            + "\"Apply preset\" sets everything that makes the game easier or harder, on all pages at once; nothing is written until you press Save. "
            + "The box stands on the preset your settings are at (\"- in use\"), or on \"Your own settings\" when they are at none of the five.");
        sb.Append('\n');
        sb.Append("  1 - Base game (hardest)   The game as it is: nothing comes back, nothing\n");
        sb.Append("                            regenerates, every number is the game's own.\n");
        sb.Append("  2 - Relaxed               A little of everything.\n");
        sb.Append("  3 - Easy                  The pace the mod is usually played at.\n");
        sb.Append("  4 - Very easy\n");
        sb.Append("  5 - Easiest               Every setting at the end of its range that makes\n");
        sb.Append("                            the game easier.\n\n");
        Wrapped(sb, "", "A preset does not touch: keys, notes on screen and log switches, the melee clean-ups, waiting, the map markers, "
            + "respawn settings of single species, the technical settings (page \"Advanced\") and what is not in the app. "
            + "It switches the parts it sets on (a module that was switched off in its own settings is on again).");
        sb.Append('\n');
        Wrapped(sb, "", "Below: the name of each setting as it stands in the module's config.lua, and its value in the five presets.");

        Head(sb, "Respawn and crime (module repopulate)");
        var r = ForRepopulate;
        Row(sb, "Creatures.Enabled", r.Select(p => YesNo(p.Creatures)).ToArray());
        Row(sb, "Creatures.NormalChance", r.Select(p => Percent(p.NormalChance)).ToArray());
        Row(sb, "Creatures.NormalEveryHours", r.Select(p => p.NormalHours.ToString(Inv)).ToArray());
        Row(sb, "Creatures.EliteChance", r.Select(p => Percent(p.EliteChance)).ToArray());
        Row(sb, "Creatures.EliteEveryHours", r.Select(p => p.EliteHours.ToString(Inv)).ToArray());
        Row(sb, "Herbs.Enabled", r.Select(p => YesNo(p.Herbs)).ToArray());
        Row(sb, "Herbs.RegrowHours", r.Select(p => p.RegrowHours.ToString(Inv)).ToArray());
        Row(sb, "WorldItems.Enabled", r.Select(p => YesNo(p.Items)).ToArray());
        Row(sb, "WorldItems.DailyChance", r.Select(p => Percent(p.ItemChance)).ToArray());
        Row(sb, "Chests.Enabled", r.Select(p => YesNo(p.Chests)).ToArray());
        Row(sb, "Chests.SettlementDailyChance", r.Select(p => Percent(p.SettlementChance)).ToArray());
        Row(sb, "Chests.WildDailyChance", r.Select(p => Percent(p.WildChance)).ToArray());
        Row(sb, "Crime: theft", r.Select(p => p.Crime || !p.NoTheft ? "crime" : "allowed").ToArray());
        Row(sb, "Crime: trespassing", r.Select(p => p.Crime || !p.NoTrespassing ? "crime" : "allowed").ToArray());
        Row(sb, "Crime: drawn weapons", r.Select(p => p.Crime || !p.NoWeapons ? "crime" : "allowed").ToArray());
        Wrapped(sb, "  ", "On in every preset: Chests.IncludeLootObjects (loot spots restock with the containers) and Crime.ForgetOldCrimes "
            + "(what was done of the kinds a preset allows is forgotten).");
        Wrapped(sb, "  ", "In preset 1 the chances and hours are the mod's usual ones; they count again when a part is switched on by hand. "
            + "In preset 5 creatures come back twice a day: the shortest interval the settings allow (1 hour) would only crowd the paths again.");

        if (mega != null)
        {
            // in the order of the app's pages, and on a page in the order of the modules' groups
            var modules = mega.Modules.Where(m => m.Schema != null)
                .OrderBy(m => m.Schema!.PageOrder).ThenBy(m => m.Schema!.Groups.Count > 0 ? m.Schema!.Groups.Min(g => g.Order) : 0).ThenBy(m => m.Name, StringComparer.Ordinal);
            foreach (var module in modules)
            {
                var items = module.Schema!.Groups.SelectMany(g => g.Items).Where(i => i.Tiers != null).ToList();
                if (items.Count == 0) continue;
                var moving = items.Where(i => i.Tiers!.Any(v => !SettingsRules.Same(v, i.Tiers![0]))).ToList();
                Head(sb, (module.Schema.Page ?? module.Name) + " (module " + module.Name + ")");
                foreach (var item in moving) Row(sb, item.Key, item.Tiers!.Select(ValueText).ToArray());
                if (moving.Any(i => i.Tiers!.Any(v => v is string t && t == "as the game has it"))) sb.Append("  (game = as the game has it)\n");
                foreach (string note in module.Schema.PresetNotes) Wrapped(sb, "  ", note);
                var still = items.Except(moving).Select(i => i.Key).ToList();
                const int Named = 6;
                if (still.Count > Named + 2)
                    Wrapped(sb, "  ", "Put back to their defaults by every preset: " + string.Join(", ", still.Take(Named)) + " and " + (still.Count - Named).ToString(Inv)
                        + " more - every setting of the module that is not listed above, except its notes and log switches.");
                else if (still.Count > 0) Wrapped(sb, "  ", "Put back to their defaults by every preset: " + string.Join(", ", still) + ".");
            }
        }
        return sb.ToString();
    }
}
