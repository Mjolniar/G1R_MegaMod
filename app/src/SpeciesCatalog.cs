using System.Text.RegularExpressions;

namespace G1RRepopulateSettings;

internal sealed class SpeciesInfo
{
    public string Unique = "";
    public string Display = "";
    public int Creatures;
    public int Points;
    public bool EliteInData;
}

/// <summary>Species handled by the mod, read from Scripts\data\creature_points.lua.</summary>
internal static class SpeciesCatalog
{
    // English in-game names (game localization), keyed by the creatures' unique names.
    private static readonly Dictionary<string, string> Names = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Biter"] = "Biter",
        ["Biter_OrcGraveyard"] = "Biter (orc graveyard)",
        ["Bloodfly"] = "Bloodfly",
        ["Bloodhound"] = "Bloodhound",
        ["GoblinWarrior"] = "Goblin Warrior",
        ["Goblin_Black"] = "Black Goblin",
        ["Goblin_Green"] = "Goblin",
        ["Harpy"] = "Harpy",
        ["Lizard"] = "Lizard",
        ["LizardFire"] = "Fire Lizard",
        ["Lurker"] = "Lurker",
        ["Meatbug"] = "Meatbug",
        ["Minecrawler"] = "Minecrawler",
        ["Minecrawler Nymph"] = "Minecrawler Nymph",
        ["Minecrawler Warrior"] = "Minecrawler Warrior",
        ["Molerat"] = "Molerat",
        ["Razor"] = "Razor",
        ["ScavengerYoung"] = "Juvenile Scavenger",
        ["Scavenger_Adult"] = "Adult Scavenger",
        ["Scavenger_Medium"] = "Scavenger",
        ["ShadowBeast"] = "Shadow Beast",
        ["ShadowBeastForest"] = "Shadow Beast (forest)",
        ["ShadowBeastCave"] = "Shadow Beast (cave)",
        ["Skeleton"] = "Skeleton",
        ["Skeleton Scout"] = "Skeleton Scout",
        ["SkeletonMage"] = "Skeleton Mage",
        ["SkeletonWarrior"] = "Skeleton Warrior",
        ["Snapper"] = "Snapper",
        ["Swampshark"] = "Swampshark",
        ["Troll"] = "Troll",
        ["Tundra Wolf"] = "Tundra Wolf",
        ["Wolf"] = "Wolf",
        ["Zombie"] = "Zombie",
    };

    public static string DisplayName(string unique)
    {
        if (Names.TryGetValue(unique, out string? n)) return n;
        // "Scavenger_Adult" -> "Scavenger Adult", "SkeletonMage" -> "Skeleton Mage"
        string s = unique.Replace('_', ' ');
        s = Regex.Replace(s, "(?<=[a-z])(?=[A-Z])", " ");
        return s;
    }

    private static readonly Regex PointLine = new("^\\s*\\[\"([^\"]+)\"\\]\\s*=\\s*\\{", RegexOptions.Compiled);
    private static readonly Regex Entry = new("u = \"([^\"]+)\", e = (true|false), n = (\\d+)", RegexOptions.Compiled);

    public static List<SpeciesInfo> Load(string creaturePointsPath, out string? error)
    {
        error = null;
        var map = new Dictionary<string, SpeciesInfo>(StringComparer.Ordinal);
        try
        {
            foreach (string line in File.ReadLines(creaturePointsPath))
            {
                if (!PointLine.IsMatch(line)) continue;
                var seenHere = new HashSet<string>(StringComparer.Ordinal);
                foreach (Match m in Entry.Matches(line))
                {
                    string u = m.Groups[1].Value;
                    if (!map.TryGetValue(u, out var info))
                    {
                        info = new SpeciesInfo { Unique = u, Display = DisplayName(u) };
                        map[u] = info;
                    }
                    info.Creatures += int.Parse(m.Groups[3].Value);
                    if (m.Groups[2].Value == "true") info.EliteInData = true;
                    if (seenHere.Add(u)) info.Points++;
                }
            }
        }
        catch (Exception ex)
        {
            error = ex.Message;
        }
        // same display name twice: add the unique name
        foreach (var g in map.Values.GroupBy(i => i.Display, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1))
            foreach (var i in g) i.Display = $"{i.Display} ({i.Unique})";
        return map.Values.OrderBy(i => i.Display, StringComparer.OrdinalIgnoreCase).ToList();
    }
}
