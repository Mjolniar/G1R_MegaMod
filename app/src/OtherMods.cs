using System.Globalization;
using System.Text;

namespace G1RRepopulateSettings;

/// <summary>
/// The module "othermods" of the megamod: two numbers of other mods, written into those mods' own settings files.
/// FocusNearbyPickups (a child mod of PLuaModLoader) reads maxRadius from its FocusNearbyPickups.ini and
/// G1R_AutoPickUpItemNative reads AreaLootingRadius from its G1R_AutoPickUpItemNative.ini, each once when the game
/// starts (Unreal units: 100 = 1 m). When a switch of the module says so, the app changes exactly the value of that
/// one line, with the game closed; the rest of the file stays byte for byte, the first version of a file it changes
/// is kept as .before-G1R_MegaMod, and a switch that is off leaves the file alone (dev/facts/othermods.md of the mod,
/// OM1 - OM3). The mod itself only reads the files.
/// </summary>
internal static class OtherMods
{
    public const string Module = "othermods";
    public const string BackupSuffix = ".before-G1R_MegaMod";
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    /// <summary>One line: the mod, its file below the Mods folder, the key, the module's switch and number, how the number is written.</summary>
    internal sealed record Line(string Mod, string File, string Key, string Switch, string Setting, Func<double, string> Write);

    public static readonly Line[] Lines =
    {
        new("FocusNearbyPickups", "PLuaModLoader/Scripts/Mods/FocusNearbyPickups/FocusNearbyPickups.ini", "maxRadius", "SetHighlight", "HighlightMeters",
            m => Math.Round(m * 100, 1).ToString("0.0", Inv)),
        new("G1R_AutoPickUpItemNative", "G1R_AutoPickUpItemNative/G1R_AutoPickUpItemNative.ini", "AreaLootingRadius", "SetLoot", "LootMeters",
            m => Math.Round(m * 100).ToString("0", Inv)),
    };

    /// <summary>The Mods folder a megamod stands in, or null.</summary>
    public static string? ModsFolder(MegaMod? mega)
    {
        try { return mega == null ? null : Path.GetDirectoryName(Path.GetFullPath(mega.Root)); }
        catch { return null; }
    }

    // The value of `key` in an ini text: where it starts and how long it is (the line's own spaces and line end not
    // counted); (-1, 0) when no line that is not a comment sets the key.
    internal static (int At, int Length) Find(string text, string key)
    {
        int from = 0;
        while (from <= text.Length)
        {
            int end = text.IndexOf('\n', from);
            if (end < 0) end = text.Length;
            int i = from;
            while (i < end && (text[i] == ' ' || text[i] == '\t')) i++;
            if (i < end && text[i] != ';' && text[i] != '#' && string.CompareOrdinal(text, i, key, 0, key.Length) == 0)
            {
                int j = i + key.Length;
                while (j < end && (text[j] == ' ' || text[j] == '\t')) j++;
                if (j < end && text[j] == '=')
                {
                    j++;
                    while (j < end && (text[j] == ' ' || text[j] == '\t')) j++;
                    int k = end;
                    while (k > j && (text[k - 1] == ' ' || text[k - 1] == '\t' || text[k - 1] == '\r')) k--;
                    return (j, k - j);
                }
            }
            if (end >= text.Length) break;
            from = end + 1;
        }
        return (-1, 0);
    }

    private static bool Wanted(Line line, IReadOnlyDictionary<string, object> values, bool moduleOn) =>
        moduleOn && values.TryGetValue("Enabled", out var on) && on is true && values.TryGetValue(line.Switch, out var set) && set is true
        && values.TryGetValue(line.Setting, out var metres) && metres is double;

    // What the file holds for the line now: its text, the value's place, and whether that is the number wanted; or why not.
    private static (string? Text, int At, int Length, bool Same, string? Problem) Look(string path, Line line, double metres)
    {
        if (!File.Exists(path)) return (null, -1, 0, false, "its settings file is not there");
        string text = Encoding.Latin1.GetString(File.ReadAllBytes(path));
        var (at, length) = Find(text, line.Key);
        if (at < 0) return (text, -1, 0, false, line.Key + " is not in its settings file");
        string now = text.Substring(at, length);
        bool same = double.TryParse(now, NumberStyles.Float, Inv, out double value) && Math.Abs(value - metres * 100) < 0.5;
        return (text, at, length, same, null);
    }

    /// <summary>
    /// What there is to say about the two files while the saved settings are `values` (moduleOn: the loader loads the
    /// module), for the module's page: "" when every file holds what the settings ask. Never throws.
    /// </summary>
    public static string Note(string? modsFolder, IReadOnlyDictionary<string, object> values, bool moduleOn)
    {
        if (modsFolder == null) return "";
        var said = new List<string>();
        foreach (var line in Lines)
        {
            if (!Wanted(line, values, moduleOn)) continue;
            try
            {
                var look = Look(Path.Combine(modsFolder, line.File), line, (double)values[line.Setting]);
                if (look.Problem != null) said.Add($"{line.Mod}: {look.Problem}.");
                else if (!look.Same) said.Add($"{line.Mod} still has {line.Key} = {look.Text!.Substring(look.At, look.Length)}: Save with the game closed.");
            }
            catch (Exception ex) { said.Add($"{line.Mod}: its settings file cannot be read ({ex.Message})."); }
        }
        return string.Join("\n", said);
    }

    /// <summary>
    /// Writes the lines the saved settings ask for (with the game closed). Returns the text for the status line ("" when
    /// nothing had to change) and whether it is a warning. Never throws.
    /// </summary>
    public static (string Text, bool Warn) Apply(string? modsFolder, IReadOnlyDictionary<string, object> values, bool moduleOn)
    {
        if (modsFolder == null) return ("", false);
        var said = new List<string>();
        bool warn = false;
        foreach (var line in Lines)
        {
            if (!Wanted(line, values, moduleOn)) continue;
            string path = Path.Combine(modsFolder, line.File);
            double metres = (double)values[line.Setting];
            try
            {
                var look = Look(path, line, metres);
                if (look.Problem != null)
                {
                    said.Add($"{line.Mod}: {look.Problem} - not written.");
                    warn = true;
                    continue;
                }
                if (look.Same) continue;
                if (GameStart.GameRuns())
                {
                    said.Add($"{line.Mod} not changed while the game runs: Save again once it is closed.");
                    warn = true;
                    continue;
                }
                string target = line.Write(metres);
                if (!File.Exists(path + BackupSuffix)) File.Copy(path, path + BackupSuffix);
                string text = look.Text!;
                Replace(path, Encoding.Latin1.GetBytes(text[..look.At] + target + text[(look.At + look.Length)..]));
                if (!Look(path, line, metres).Same)
                {
                    said.Add($"{line.Mod}: written, but does not read back right.");
                    warn = true;
                    continue;
                }
                said.Add($"{line.Mod}: {line.Key} = {target} from the next start.");
            }
            catch (Exception ex)
            {
                said.Add($"{line.Mod}: not written ({ex.Message}).");
                warn = true;
            }
        }
        return (string.Join(" ", said), warn);
    }

    // Writes a file of another mod: a temporary file next to it, then put in its place (nothing else is left there).
    private static void Replace(string path, byte[] bytes)
    {
        string tmp = path + ".tmp";
        try
        {
            File.WriteAllBytes(tmp, bytes);
            File.Replace(tmp, path, null, ignoreMetadataErrors: true);
        }
        catch
        {
            try { File.Delete(tmp); } catch { }
            throw;
        }
    }
}
