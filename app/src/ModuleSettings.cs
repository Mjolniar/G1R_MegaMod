using System.Globalization;

namespace G1RRepopulateSettings;

/// <summary>
/// One module of the megamod that describes its settings in Scripts\schema.lua: the schema, the
/// values of its Scripts\config.lua, and saving changed values into that file the way the game's
/// settings service does it (dev/SETTINGS.md section 2).
/// </summary>
internal sealed class ModuleSettings
{
    public const string NotThere = "config.lua is not there yet";

    /// <summary>The name of the module's folder.</summary>
    public readonly string Name;
    public readonly string SchemaPath, ConfigPath;

    /// <summary>null while SchemaProblem says why the schema cannot be used.</summary>
    public ModuleSchema? Schema { get; private set; }
    public string? SchemaProblem { get; private set; }

    /// <summary>Why the values are not from the file (it is missing, cannot be read, has an error); null = they are.</summary>
    public string? FileProblem { get; private set; }

    /// <summary>What was corrected when the file was read (a value out of range, of the wrong kind), for the screen.</summary>
    public List<string> Warnings { get; } = new();

    /// <summary>The keys whose value in the file had to be corrected, in the order of the schema.</summary>
    public List<string> CorrectedKeys { get; } = new();

    /// <summary>The checked values by key, hidden items included: what the game uses for this file.</summary>
    public Dictionary<string, object> Values { get; private set; } = new(StringComparer.Ordinal);

    private string? _diskText;      // config.lua as it was last read or written (byte text); null = there was none

    // A module the app describes itself (AppSchemas): the schema text and the default config.lua stand in the app.
    private readonly string? _ownSchema, _ownDefault;

    public ModuleSettings(string name, string scriptsFolder)
    {
        Name = name;
        SchemaPath = Path.Combine(scriptsFolder, "schema.lua");
        ConfigPath = Path.Combine(scriptsFolder, "config.lua");
    }

    /// <summary>
    /// A module that has no schema.lua and reads its config.lua itself (the map pins): the app carries the
    /// description of its settings (schemaText, in the form of a schema.lua) and its shipped config.lua
    /// (defaultText). Its file keeps its own form: a changed value replaces the value in its line and
    /// nothing else (SettingsRules.PatchValue), so the notes behind the values stay.
    /// </summary>
    public ModuleSettings(string name, string scriptsFolder, string schemaText, string defaultText) : this(name, scriptsFolder)
    {
        _ownSchema = schemaText;
        _ownDefault = defaultText;
    }

    /// <summary>The app describes this module's settings itself: the game's settings service does not know them, and the module does not check them.</summary>
    public bool Described => _ownSchema != null;

    /// <summary>The text of a config.lua that holds the defaults: the one the schema gives, or the shipped file of a module the app describes itself.</summary>
    public string DefaultText() => _ownDefault ?? Schema!.DefaultText();

    /// <summary>Reads schema.lua. Never throws: what is wrong ends up in SchemaProblem.</summary>
    public void ReadSchema()
    {
        Schema = null;
        SchemaProblem = null;
        try
        {
            Schema = ModuleSchema.FromText(_ownSchema ?? ByteText.FromBytes(File.ReadAllBytes(SchemaPath)));
        }
        catch (SchemaException ex) { SchemaProblem = ex.Message; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { SchemaProblem = "schema.lua could not be read: " + ex.Message; }
        catch (Exception ex) { SchemaProblem = "schema.lua could not be used: " + ex.Message; }
    }

    private Dictionary<string, object> Defaults()
    {
        var values = new Dictionary<string, object>(StringComparer.Ordinal);
        foreach (var item in Schema!.Items) values[item.Key] = item.Default!;
        return values;
    }

    // config.lua as byte text; null when there is none. Other failures (no access, in use) are the caller's.
    // The running game writes the file too (config.lua.tmp, remove config.lua, rename): the file is opened so
    // that the game can replace it meanwhile, and a file that is missing while its .tmp lies there is waited
    // for a moment - it is on its way.
    private string? ReadDisk()
    {
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                using var file = new FileStream(ConfigPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var buffer = new MemoryStream();
                file.CopyTo(buffer);
                return ByteText.FromBytes(buffer.ToArray());
            }
            catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException)
            {
                if (attempt >= 3 || !File.Exists(ConfigPath + ".tmp")) return null;
            }
            catch (IOException) when (attempt < 3) { }       // in use just now
            Pause(30);
        }
    }

    /// <summary>Waits so many milliseconds (the tests put the other side's writing here).</summary>
    internal static Action<int> Pause = Thread.Sleep;

    // a value of the file for a message
    private static string ShownValue(object? v) => v is PlainTable ? "a table" : ByteText.ToUnicode(SettingsRules.OnOneLine(LuaPlain.ToText(v)));

    // What the text of a config.lua says: its values checked against the schema (put into `values`), and
    // what had to be corrected. false and the problem when the text is not usable; `values` is then untouched.
    private bool Evaluate(string text, Dictionary<string, object> values, List<string> warnings, List<string> correctedKeys, out string? problem)
    {
        var parsed = SettingsRules.Parse(text, out string? why);
        if (parsed == null)
        {
            problem = "config.lua has an error (" + why + ")";
            return false;
        }
        problem = null;
        foreach (var item in Schema!.Items)
        {
            object? given = parsed[item.Key];
            // (a module the app describes itself takes a choice in any case, as the module does)
            if (Described && item.Kind == ItemKind.Choice && given is string word && item.Options.Contains(word.ToLowerInvariant(), StringComparer.Ordinal)) given = word.ToLowerInvariant();
            object v = SettingsRules.Checked(item, given, out bool corrected);
            if (corrected)
            {
                correctedKeys.Add(item.Key);
                // The game's settings service uses the corrected value. A module that reads its file itself uses what
                // the file says: there the page only cannot show it.
                warnings.Add(Described
                    ? $"{item.Key} = {ShownValue(given)} is outside what this page can show: it shows {ByteText.ToUnicode(SettingsRules.Literal(item, v))}, and the file keeps its value until you change it here"
                    : $"{item.Key} = {ShownValue(given)} is not usable; {ByteText.ToUnicode(SettingsRules.Literal(item, v))} is used");
            }
            values[item.Key] = v;
        }
        if (SettingsRules.HasCommaNumber(text)) warnings.Add("a number seems to be written with a comma (2,5); Lua reads that as 2 - write 2.5");
        return true;
    }

    // Takes the values of the file as it is now (null = there is none). A file that is not usable leaves the values as they are.
    private void Take(string? disk)
    {
        _diskText = disk;
        Warnings.Clear();
        CorrectedKeys.Clear();
        if (disk == null) FileProblem = NotThere;
        else
        {
            Evaluate(disk, Values, Warnings, CorrectedKeys, out string? problem);
            FileProblem = problem;
        }
    }

    /// <summary>
    /// Reads config.lua: its values, checked against the schema. A file that is missing, cannot be
    /// read or is not valid gives the defaults, and FileProblem says so. Never throws.
    /// </summary>
    public void Load()
    {
        Warnings.Clear();
        CorrectedKeys.Clear();
        FileProblem = null;
        _diskText = null;
        if (Schema == null) return;
        Values = Defaults();
        try { Take(ReadDisk()); }
        catch (Exception ex) { FileProblem = "config.lua could not be read (" + ex.Message + ")"; }
    }

    /// <summary>
    /// Looks at config.lua again, the way the running game does every few seconds: when the file
    /// changed since it was last read or written here, its values are taken; a file that is gone or
    /// not usable leaves the values as they are (FileProblem says so). Returns whether the file had
    /// changed. Never throws.
    /// </summary>
    public bool Reread()
    {
        if (Schema == null) return false;
        if (Values.Count == 0) Values = Defaults();     // never read before
        try
        {
            string? disk = ReadDisk();
            if (string.Equals(disk, _diskText, StringComparison.Ordinal)) return false;
            Take(disk);
            return true;
        }
        catch { return false; }
    }

    /// <summary>
    /// Writes the wanted values (by key; values as the controls give them) into config.lua: only the
    /// lines of keys whose value changes are rewritten. When the file changed on disk since it was
    /// read (the game writes it too), it is read again first, so that the other side's changes stay.
    /// Returns whether the file was written; changed = the keys whose value changed. Throws when the
    /// file cannot be read or written; then nothing was written.
    /// </summary>
    public bool Save(IReadOnlyDictionary<string, object?> wanted, out List<string> changed)
    {
        changed = new List<string>();
        if (Schema == null || wanted.Count == 0) return false;
        if (Values.Count == 0) Values = Defaults();     // never read before
        string? disk = ReadDisk();
        // changed by the other side: its values are the ones the wanted values are compared with
        if (!string.Equals(disk, _diskText, StringComparison.Ordinal)) Take(disk);
        var memory = new Dictionary<string, object>(Values, StringComparer.Ordinal);
        string? text = SettingsRules.Apply(Schema, disk, memory, wanted, out changed, _ownDefault, keepTail: Described);
        if (text == null) return false;
        SettingsFile.WriteBytes(ConfigPath, ByteText.ToBytes(text));
        // as in the game: the values are the ones that were set, the file is the text that was written
        _diskText = text;
        Values = memory;
        Warnings.Clear();
        CorrectedKeys.Clear();
        var arrived = new Dictionary<string, object>(StringComparer.Ordinal);
        if (Evaluate(text, arrived, Warnings, CorrectedKeys, out string? problem))
        {
            // a line the rule changed that Lua does not go by (it stands in a comment block, say)
            foreach (string key in changed)
            {
                var item = Schema.ByKey[key];
                if (SettingsRules.Literal(item, arrived[key]) != SettingsRules.Literal(item, memory[key]))
                    Warnings.Add($"{key}: the saved value does not arrive - the line of this key in config.lua is not the one Lua reads");
            }
        }
        FileProblem = problem;
        return true;
    }

    /// <summary>What the file holds now differs from what was last read or written here.</summary>
    public bool ChangedOnDisk()
    {
        if (Schema == null) return false;
        try { return !string.Equals(ReadDisk(), _diskText, StringComparison.Ordinal); }
        catch { return false; }
    }
}

/// <summary>
/// The megamod the app sits in: ...\G1R_MegaMod\modules\repopulate\ next to the other modules
/// (...\modules\&lt;name&gt;\Scripts\schema.lua and config.lua) and the loader (...\G1R_MegaMod\Scripts).
/// </summary>
internal sealed class MegaMod
{
    public readonly string Root;
    /// <summary>The modules with a schema.lua, and those the app describes itself (AppSchemas), by name. (Their schemas are read, their values are not.)</summary>
    public readonly List<ModuleSettings> Modules = new();

    private MegaMod(string root) { Root = root; }

    private static bool Named(string? path, string name) =>
        path != null && string.Equals(Path.GetFileName(path), name, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// The megamod around the repopulate module's settings file, or null in any other layout (the
    /// separate mod G1R_Repopulate, a file picked by hand). Only that megamod's own modules folder is
    /// looked at. Never throws.
    /// </summary>
    public static MegaMod? Find(string? repopulateConfigPath)
    {
        try
        {
            if (string.IsNullOrEmpty(repopulateConfigPath)) return null;
            string? scripts = Path.GetDirectoryName(Path.GetFullPath(repopulateConfigPath));
            string? module = scripts != null ? Path.GetDirectoryName(scripts) : null;
            string? modules = module != null ? Path.GetDirectoryName(module) : null;
            string? root = modules != null ? Path.GetDirectoryName(modules) : null;
            if (root == null || !Named(scripts, "Scripts") || !Named(modules, "modules")) return null;
            if (!Directory.Exists(Path.Combine(root, "Scripts"))) return null;      // the loader: what makes the folder the megamod
            var mega = new MegaMod(root);
            foreach (string dir in Directory.GetDirectories(modules!))
            {
                // the module whose settings the hand-written pages edit has no generic page
                if (string.Equals(Path.GetFullPath(dir), module, StringComparison.OrdinalIgnoreCase)) continue;
                string moduleScripts = Path.Combine(dir, "Scripts");
                // a module with a schema.lua, or one the app describes itself (the map pins)
                var m = File.Exists(Path.Combine(moduleScripts, "schema.lua")) ? new ModuleSettings(Path.GetFileName(dir), moduleScripts)
                    : AppSchemas.For(Path.GetFileName(dir), moduleScripts);
                if (m == null) continue;
                m.ReadSchema();
                mega.Modules.Add(m);
            }
            mega.Modules.Sort((a, b) => string.CompareOrdinal(a.Name, b.Name));
            return mega;
        }
        catch { return null; }
    }

    // ------------------------------------------------------------------ what the loader says (read-only; never throws)
    /// <summary>The megamod's version ("0.2.1") from Scripts\core\version.lua, or "" when it cannot be read.</summary>
    public string Version()
    {
        try
        {
            if (LuaPlain.Run(ByteText.FromBytes(File.ReadAllBytes(Path.Combine(Root, "Scripts", "core", "version.lua")))) is PlainTable t && t["version"] is string v)
                return ByteText.ToUnicode(v);
        }
        catch { }
        return "";
    }

    /// <summary>
    /// The modules the loader does not load at all because their switch in the megamod's own Scripts\config.lua
    /// (Config.Modules) is false - by folder name. The switch names come from Scripts\core\modules.lua. A file
    /// that is missing or cannot be read gives nothing (the loader then loads every module).
    /// </summary>
    public HashSet<string> SwitchedOff()
    {
        var off = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            if (LuaPlain.Run(ByteText.FromBytes(File.ReadAllBytes(Path.Combine(Root, "Scripts", "core", "modules.lua")))) is not PlainTable list) return off;
            if (SettingsRules.Parse(ByteText.FromBytes(File.ReadAllBytes(Path.Combine(Root, "Scripts", "config.lua"))), out _) is not PlainTable config) return off;
            if (config["Modules"] is not PlainTable switches) return off;
            foreach (object? entry in list.Sequence())
                if (entry is PlainTable m && m["name"] is string name && m["switch"] is string key && switches[key] is bool on && !on) off.Add(name);
        }
        catch { }
        return off;
    }
}
