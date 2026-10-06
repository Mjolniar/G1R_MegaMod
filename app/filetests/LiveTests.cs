using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace G1RRepopulateSettings;

// filetests --live: the app's code against the game's own Lua code (Scripts/core/settings.lua and
// kit.lua of the megamod), run with lua5.4 through gen_fixtures.lua:
//   1. the fixtures the tests carry (src/SelfTestFixtures.txt.gz) are what that code gives today;
//   2. every module of the megamod that has a schema.lua: same verdict, same default text, same
//      values read from its shipped config.lua;
//   3. cases made up at random (numbers, keys, schemas, single-line changes, config.lua texts,
//      sequences of changes): the same answers.
internal static partial class SelfTest
{
    private sealed class Rng
    {
        private readonly Random _r;
        public Rng(int seed) { _r = new Random(seed); }
        public int Next(int n) => _r.Next(n);
        public double Unit() => _r.NextDouble();
        public bool Chance(double p) => _r.NextDouble() < p;
        public T Pick<T>(params T[] items) => items[_r.Next(items.Length)];
        public T From<T>(IReadOnlyList<T> items) => items[_r.Next(items.Count)];
    }

    private static string CaseLine(params string?[] fields) => string.Join("\t", fields.Select(Fixtures.Escape));

    // "\n" line ends on every OS: the generator splits lines at "\n" only, so a "\r" from File.WriteAllLines on
    // Windows stays on the last field (a closing "reset" step then reads as "reset\r")
    private static void WriteCases(string path, IEnumerable<string> lines) =>
        File.WriteAllText(path, string.Concat(lines.Select(l => l + "\n")));

    private static string FindGenerator()
    {
        string dir = AppContext.BaseDirectory;
        for (int i = 0; i < 6 && dir != null; i++)
        {
            string candidate = Path.Combine(dir, "gen_fixtures.lua");
            if (File.Exists(candidate)) return candidate;
            dir = Path.GetDirectoryName(dir.TrimEnd(Path.DirectorySeparatorChar))!;
        }
        throw new FileNotFoundException("gen_fixtures.lua was not found above " + AppContext.BaseDirectory);
    }

    // Runs the generator (with the built-in inputs, or with a cases file) and returns its output as byte text.
    private static string RunGenerator(string generator, string megamod, string dir, string? casesFile)
    {
        string output = Path.Combine(dir, casesFile == null ? "fixtures.txt" : Path.GetFileNameWithoutExtension(casesFile) + ".out");
        var info = new ProcessStartInfo("lua5.4") { RedirectStandardError = true, RedirectStandardOutput = true, UseShellExecute = false };
        info.ArgumentList.Add(generator);
        info.ArgumentList.Add(megamod);
        info.ArgumentList.Add(output);
        info.ArgumentList.Add(dir);
        if (casesFile != null) info.ArgumentList.Add(casesFile);
        using var p = Process.Start(info) ?? throw new InvalidOperationException("lua5.4 could not be started");
        string err = p.StandardError.ReadToEnd();
        p.StandardOutput.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0) throw new InvalidOperationException("lua5.4 gen_fixtures.lua failed: " + err.Trim());
        return ByteText.FromBytes(File.ReadAllBytes(output));
    }

    public static int RunLive(string megamod, string reportPath, int seed)
    {
        var r = new Report();
        string dir = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(reportPath)) ?? ".", "live-work");
        try
        {
            DeleteTree(dir);
            Directory.CreateDirectory(dir);
            string generator = FindGenerator();
            megamod = Path.GetFullPath(megamod);
            r.Info($"the game's code: {megamod}; random cases from seed {seed}");

            // 1. the fixtures
            string embedded = Fixtures.EmbeddedText();
            string fresh = RunGenerator(generator, megamod, dir, null);
            r.Check(fresh == embedded, "the fixtures in the app (src/SelfTestFixtures.txt.gz) are what the game's code gives today"
                + (fresh == embedded ? $" ({fresh.Length} bytes)" : " - they are out of date: run filetests/gen_fixtures.sh, build again, run the tests again"));
            var fx = Fixtures.Parse(embedded);
            var schemas = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var rec in fx.Of("schema")) if (rec[3] == "ok" && rec[1] is "A" or "allkinds" or "hand") schemas[rec[1]!] = rec[2]!;
            foreach (var rec in fx.Of("real")) schemas[rec[1]!] = rec[2]!;

            // 2. the modules of the megamod as they are now
            var cases = new List<string>();
            var installed = new List<(string Name, string Schema, string? Config)>();
            string modules = Path.Combine(megamod, "modules");
            foreach (string moduleDir in Directory.GetDirectories(modules).OrderBy(d => d, StringComparer.Ordinal))
            {
                string schemaPath = Path.Combine(moduleDir, "Scripts", "schema.lua");
                if (!File.Exists(schemaPath)) continue;
                string name = "module " + Path.GetFileName(moduleDir);
                installed.Add((name, ByteText.FromBytes(File.ReadAllBytes(schemaPath)), ByteTextOf(Path.Combine(moduleDir, "Scripts", "config.lua"))));
                cases.Add(CaseLine("schema", name, installed[^1].Schema));
            }
            string casesPath = Path.Combine(dir, "modules.cases");
            WriteCases(casesPath, cases);
            var answers = Fixtures.Parse(RunGenerator(generator, megamod, dir, casesPath));
            var wrong = new List<string>();
            var reasons = new SortedSet<string>(StringComparer.Ordinal);
            int n = CompareSchemas(answers, wrong, out int good, out int bad, out int unreadable, reasons);
            Cases(r, n, wrong, $"schema.lua files of the megamod's modules ({string.Join(", ", installed.Select(m => m.Name[7..]))}): the app and the game agree on each "
                + $"({good} usable, {bad + unreadable} not) and on its default config.lua");
            foreach (var m in installed)
            {
                if (SchemaVerdict(m.Schema, out var schema) != "ok") { r.Info($"  {m.Name}: its schema is not usable"); continue; }
                schemas[m.Name] = m.Schema;
                r.Info($"  {m.Name}: the shipped config.lua " + (m.Config == null ? "is missing" : m.Config == schema!.DefaultText() ? "is the default text of its schema" : "DIFFERS from the default text of its schema"));
            }

            // 2b. the presets: the app reads the Tiers of the schemas as the mod's own check does (dev/tools/presets.lua),
            //     and the mod's PRESETS.txt is the text the app makes of them
            var megaNow = MegaMod.Find(Path.Combine(megamod, "modules", "repopulate", "Scripts", "config.lua"));
            string tool = Path.Combine(megamod, "dev", "tools", "presets.lua");
            if (megaNow == null) r.Check(false, "the megamod was not found around modules/repopulate/Scripts/config.lua");
            else if (!File.Exists(tool)) r.Info("  (this megamod has no dev/tools/presets.lua: the presets are not compared)");
            else
            {
                var lua = new ProcessStartInfo("lua5.4") { RedirectStandardError = true, RedirectStandardOutput = true, UseShellExecute = false };
                lua.ArgumentList.Add(tool);
                lua.ArgumentList.Add("--list");
                using var p = Process.Start(lua) ?? throw new InvalidOperationException("lua5.4 could not be started");
                string theirs = p.StandardOutput.ReadToEnd();
                p.StandardError.ReadToEnd();
                p.WaitForExit();
                var ours = new StringBuilder();
                int withTiers = 0;
                foreach (var m in megaNow.Modules)
                {
                    if (m.Schema == null || m.Described) continue;      // (a module the app describes itself has no schema.lua for the mod's check to read)
                    var items = m.Schema.Groups.SelectMany(x => x.Items).Where(i => i.Tiers != null).ToList();
                    int moving = items.Count(i => i.Tiers!.Any(v => !SettingsRules.Same(v, i.Tiers![0])));
                    ours.Append(m.Name).Append(": ").Append(items.Count.ToString(Inv)).Append(" item(s) with Tiers (").Append(moving.ToString(Inv))
                        .Append(" that differ between the presets, ").Append((items.Count - moving).ToString(Inv)).Append(" put back to their default)\n");
                    foreach (var item in items)
                        ours.Append("    ").Append(item.Key.PadRight(24)).Append(' ').Append(string.Join(" | ", item.Tiers!.Select(v => v switch
                        {
                            bool b => b ? "yes" : "no",
                            double d => d == Math.Floor(d) ? ((long)d).ToString(Inv) : d.ToString("0.###", Inv),
                            _ => v.ToString(),
                        }))).Append('\n');
                    withTiers += items.Count;
                    foreach (string problem in m.Schema.TierProblems) ours.Append(m.Name).Append(": ").Append(problem).Append('\n');
                }
                r.Check(p.ExitCode == 0 && theirs == ours.ToString() && withTiers > 0,
                    $"the presets: the app reads the same five values for each of {withTiers} settings as the mod's own check (dev/tools/presets.lua --list), and neither finds a Tiers that cannot be used"
                    + (theirs == ours.ToString() ? "" : " - they differ:\n--- the mod's check\n" + theirs + "--- the app\n" + ours));
                string docPath = Path.Combine(megamod, "PRESETS.txt");
                string doc = Presets.Document(megaNow);
                string? shipped = File.Exists(docPath) ? File.ReadAllText(docPath) : null;
                r.Check(shipped == doc, "PRESETS.txt of the mod is the text the app makes of the presets"
                    + (shipped == doc ? "" : shipped == null ? " - the file is missing: filetests --presets <megamod> <megamod>/PRESETS.txt" : " - it is out of date: filetests --presets <megamod> <megamod>/PRESETS.txt"));
            }

            // 2c. the window's layout for this megamod, and the app's own description of the map pin settings
            if (megaNow != null)
            {
                var nav = NavModel.Build(megaNow);
                var layoutProblems = nav.Problems(megaNow);
                var schemaTabs = nav.Tabs.Where(t => t.Kind == NavKind.Schema).ToList();
                var longest = schemaTabs.OrderByDescending(NavModel.SettingsOn).First();
                var unknown = megaNow.Modules.Where(m => NavModel.PlaceOf(m.Name) == null).Select(m => m.Name).ToList();
                var unplaced = megaNow.Modules.Where(m => m.Schema != null && NavModel.PlaceOf(m.Name) is { } place
                    && place.Groups.Keys.Any(title => !m.Schema.Groups.Any(g => g.Title == title))).Select(m => m.Name).ToList();
                r.Check(nav.Describe() == "Overview: Overview | World: Creatures, Herbs and items, Containers, Crime, Advanced"
                        + " | Combat: Regeneration, Magic, Fire spells, Ice spells, Energy spells, Wind spells, Circles, Melee | Resources: Mining | Hero: Experience, Lock picking, Mount, Movement"
                        + " | Time: Waiting, Rules | Map: Map pins, People, Colour key, Advanced | Interface: Notes on screen, Game start, Key list, Effect timers | Other mods: Other mods"
                    && layoutProblems.Count == 0 && NavModel.SettingsOn(longest) <= 26 && unknown.Count == 0 && unplaced.Count == 0,
                    $"the window's layout for this megamod: nine categories, {nav.Tabs.Count()} tabs; every group of shown settings on exactly one tab; no tab has more than 26 settings "
                    + $"(the longest: {longest.Path}, {NavModel.SettingsOn(longest)}); every module is one the app's table knows, and every group the table names exists: " + nav.Describe()
                    + (layoutProblems.Count > 0 ? " - problems: " + string.Join("; ", layoutProblems) : "")
                    + (unknown.Count > 0 ? " - modules the table does not know (they get a place by their schema's Page): " + string.Join(", ", unknown) : "")
                    + (unplaced.Count > 0 ? " - the table names groups these modules do not have: " + string.Join(", ", unplaced) : ""));
                r.Info("  settings per tab: " + string.Join(", ", schemaTabs.Select(t => t.Path + " " + NavModel.SettingsOn(t).ToString(Inv))));

                string markersScripts = Path.Combine(megamod, "modules", AppSchemas.Markers, "Scripts");
                string? shippedPins = File.Exists(Path.Combine(markersScripts, "config.lua")) ? ByteText.FromBytes(File.ReadAllBytes(Path.Combine(markersScripts, "config.lua"))) : null;
                string code = File.Exists(Path.Combine(markersScripts, "main.lua")) ? ByteText.FromBytes(File.ReadAllBytes(Path.Combine(markersScripts, "main.lua"))) : "";
                var pins = ModuleSchema.FromText(AppSchemas.MarkersSchema);
                // what the module reads: cfg("Key", default) and Config.Key
                var read = System.Text.RegularExpressions.Regex.Matches(code, "cfg\\(\"([A-Za-z_][A-Za-z0-9_]*)\"").Select(m => m.Groups[1].Value)
                    .Concat(System.Text.RegularExpressions.Regex.Matches(code, "\\bConfig\\.([A-Za-z_][A-Za-z0-9_]*)").Select(m => m.Groups[1].Value)).Distinct(StringComparer.Ordinal).ToList();
                var notRead = pins.Items.Select(i => i.Key).Where(k => !read.Contains(k)).ToList();
                var notDescribed = read.Where(k => !pins.ByKey.ContainsKey(k)).OrderBy(k => k, StringComparer.Ordinal).ToList();
                // where the code names a plain default for a key, it is the default the app shows
                var otherDefault = new List<string>();
                foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(code, "cfg\\(\"([A-Za-z_][A-Za-z0-9_]*)\",\\s*(-?[0-9.]+|true|false)\\)"))
                {
                    if (!pins.ByKey.TryGetValue(m.Groups[1].Value, out var item)) continue;
                    string literal = m.Groups[2].Value;
                    object value = literal == "true" ? true : literal == "false" ? false : double.Parse(literal, Inv);
                    if (!SettingsRules.Same(value, item.Default)) otherDefault.Add($"{item.Key}: the code has {literal}");
                }
                r.Check(shippedPins == AppSchemas.MarkersDefault && code.Length > 0 && notRead.Count == 0 && notDescribed.SequenceEqual(new[] { "ExtraNPCs", "HideIds", "NPCs", "PinSize" }) && otherDefault.Count == 0,
                    $"the map pins: the config.lua in the app is the one this megamod ships; the module reads every one of the {pins.Items.Count} settings the app describes; what it reads and the app "
                    + "does not describe is the three lists (ExtraNPCs, HideIds, NPCs) and PinSize, the old name of AreaPinSize; the defaults in its code are the ones the app shows"
                    + (shippedPins != AppSchemas.MarkersDefault ? " - the shipped config.lua DIFFERS from src/MapPinsConfig.lua" : "")
                    + (notRead.Count > 0 ? " - not read by the module: " + string.Join(", ", notRead) : "")
                    + (!notDescribed.SequenceEqual(new[] { "ExtraNPCs", "HideIds", "NPCs", "PinSize" }) ? " - read and not described: " + string.Join(", ", notDescribed) : "")
                    + (otherDefault.Count > 0 ? " - other defaults: " + string.Join("; ", otherDefault) : ""));
            }

            // 2d. the module intro: the app writes the lines into Game.ini that the module looks for, and leaves out the logos the module counts
            string introMain = Path.Combine(megamod, "modules", GameStart.Module, "Scripts", "main.lua");
            if (!File.Exists(introMain)) r.Info("  (this megamod has no module intro: Game.ini is not compared)");
            else
            {
                string introCode = File.ReadAllText(introMain);
                var mark = System.Text.RegularExpressions.Regex.Match(introCode, "local MARK = \"([^\"]+)\"");
                var logoList = System.Text.RegularExpressions.Regex.Match(introCode, "local LOGOS = \\{([^}]*)\\}");
                var logos = System.Text.RegularExpressions.Regex.Matches(logoList.Groups[1].Value, "\"([^\"]+)\"").Select(m => m.Groups[1].Value).ToList();
                string startValue = GameStart.Value;
                r.Check(mark.Success && GameStart.Begin == "; ---- " + mark.Groups[1].Value + " (begin) ----" && GameStart.End == "; ---- " + mark.Groups[1].Value + " (end) ----"
                    && logos.Count == 3 && logos.All(n => !startValue.Contains("\"" + n + "\"", StringComparison.Ordinal))
                    && startValue.Contains("MoviePaths=(\"LoopingEngineLoadScreen\")", StringComparison.Ordinal),
                    "the module intro: the two lines the app writes around its line in Game.ini are the ones the module looks for, and the start list the app writes has none of the logos "
                    + "the module counts (" + string.Join(", ", logos) + ")");
            }

            // 3. cases made up at random
            var g = new Rng(seed);
            cases = new List<string>();
            foreach (var kv in schemas) cases.Add(CaseLine("schema", kv.Key, kv.Value));
            for (int i = 0; i < 400; i++) cases.Add(CaseLine("schema", "random " + i.ToString(Inv), RandomSchema(g)));
            foreach (var m in installed) if (schemas.ContainsKey(m.Name)) cases.Add(CaseLine("read", m.Name, m.Config));
            for (int i = 0; i < 1500; i++)
            {
                double v = RandomNumber(g);
                cases.Add(CaseLine("number", v.ToString("R", Inv), g.Pick(0, 0, 1, 1, 2, 2, 2, 3, 3, 4, 6, 9, 15).ToString(Inv)));
            }
            for (int i = 0; i < 1500; i++) cases.Add(CaseLine("key", RandomKeyText(g)));
            string[] keys = { "A", "AB", "B", "A_1", "Amount", "a" };
            for (int i = 0; i < 4000; i++)
                cases.Add(CaseLine("patch", RandomLines(g, keys), g.Pick(keys), g.Pick("5", "true", "\"x y\"", "2.5", "\"a%1b\"", "\"\\\\ \\\"\"", "\"\"")));
            var parsed = schemas.ToDictionary(kv => kv.Key, kv => ModuleSchema.FromText(kv.Value), StringComparer.Ordinal);
            var names = parsed.Keys.OrderBy(k => k, StringComparer.Ordinal).ToList();
            for (int i = 0; i < 2500; i++)
            {
                string name = g.Chance(0.5) ? "A" : g.From(names);
                cases.Add(CaseLine("read", name, RandomConfig(g, parsed[name])));
            }
            for (int i = 0; i < 700; i++)
            {
                string name = g.Chance(0.4) ? "A" : g.From(names);
                cases.Add(RandomScenario(g, "random " + i.ToString(Inv), name, parsed[name]));
            }
            casesPath = Path.Combine(dir, "random.cases");
            WriteCases(casesPath, cases);
            answers = Fixtures.Parse(RunGenerator(generator, megamod, dir, casesPath));
            var usable = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var rec in answers.Of("schema")) if (rec[3] == "ok") usable[rec[1]!] = rec[2]!;

            wrong = new List<string>();
            reasons = new SortedSet<string>(StringComparer.Ordinal);
            n = CompareSchemas(answers, wrong, out good, out bad, out unreadable, reasons);
            Cases(r, n, wrong, $"schemas, most of them made up at random: {good} usable ones give the game's default text, {bad} are refused with the game's reason ({reasons.Count} different reasons), "
                + $"{unreadable} are refused because the game's number format fails on their Decimals");
            wrong = new List<string>();
            n = CompareNumbers(answers, wrong);
            Cases(r, n, wrong, "random numbers with 0 to 15 places are written as the game writes them");
            wrong = new List<string>();
            n = CompareKeys(answers, wrong);
            Cases(r, n, wrong, "random spellings of key combinations give what the kit's keyCombo gives");
            wrong = new List<string>();
            n = ComparePatches(answers, wrong);
            int replaced = answers.Of("patch").Count(rec => (rec[4] ?? "").Split('\n').Length == (rec[1] ?? "").Split('\n').Length);
            Cases(r, n, wrong, $"random texts with one line changed give the game's text ({replaced} with the key's line found, {n - replaced} with a line added)");
            wrong = new List<string>();
            n = CompareReads(answers, usable, Path.Combine(dir, "files"), wrong, out int invalid, out int corrected);
            Cases(r, n, wrong, $"random config.lua texts are read as the game reads them ({invalid} not usable for both, {corrected} with corrected values)");
            wrong = new List<string>();
            n = CompareApplies(answers, usable, Path.Combine(dir, "files"), wrong, out int steps, out int written);
            Cases(r, n, wrong, $"random sequences of changes ({steps} changes, {written} of them write the file): the app's config.lua equals the game's byte for byte after every change");
        }
        catch (Exception ex)
        {
            r.Check(false, "exception: " + ex);
        }
        finally
        {
            // G1R_KEEP_LIVE=1 keeps the cases and the game's answers (live-work next to the report) for a look
            if (Environment.GetEnvironmentVariable("G1R_KEEP_LIVE") != "1") DeleteTree(dir);
        }
        return Finish(r, reportPath);
    }

    // =====================================================================
    // making up cases
    // =====================================================================
    private static double RandomNumber(Rng g)
    {
        double sign = g.Chance(0.3) ? -1 : 1;
        switch (g.Next(8))
        {
            case 0: return sign * g.Next(2000);
            case 1: return sign * g.Next(4000) / 8.0;               // exact ties with up to three places
            case 2: return sign * g.Next(64000) / 64.0;
            case 3: return sign * g.Next(100000) / 1000.0;
            case 4: return sign * g.Next(100000) / 100.0;
            case 5: return sign * g.Unit() * Math.Pow(10, g.Next(14) - 4);
            case 6: return sign * (g.Next(1000) + 0.5 + (g.Chance(0.5) ? 0 : (g.Chance(0.5) ? 1e-9 : -1e-9)));
            default: return sign * Math.Round(g.Unit() * 1000, g.Next(6));
        }
    }

    private static readonly string[] SomeKeys = { "Y", "y", "F5", "f12", "NUM_FIVE", "num5", "0", "9", "delete", "DEL", "enter", "pgup", "up", "mouse3", "capslock", "SPACE", "tab", "oem_102", "A", "z", "home" };

    private static string RandomKeyText(Rng g)
    {
        if (g.Chance(0.05)) return g.Pick("", " ", "+", "nokey", "ESC", "CTRL", "LWIN", "ctrl+shift", "\t", "A+B", "F13");
        var parts = new List<string>();
        int modifiers = g.Next(4);
        for (int i = 0; i < modifiers; i++) parts.Add(g.Pick("ctrl", "CTRL", "Ctrl", "strg", "control", "shift", "SHIFT", "Shift", "alt", "ALT"));
        string key = g.Chance(0.5) ? g.From(SomeKeys) : g.From(KeyNames.All).Name;
        if (g.Chance(0.3)) key = key.ToLowerInvariant();
        parts.Insert(g.Chance(0.8) ? parts.Count : g.Next(parts.Count + 1), key);
        if (g.Chance(0.04)) parts.Add(g.Pick("B", "", "nokey"));
        string plus = g.Pick("+", "+", "+", " + ", " +", "+ ", "\t+");
        return (g.Chance(0.05) ? " " : "") + string.Join(plus, parts) + (g.Chance(0.05) ? " " : "");
    }

    // a line of a config.lua, or something like one
    private static string RandomLine(Rng g, string[] keys)
    {
        switch (g.Next(12))
        {
            case 0: case 1: case 2: case 3:
                return g.Pick("", "", " ", "\t", "  \t", "    ") + "Config." + g.Pick(keys) + g.Pick("", " ", " ", "  ", "\t") + "=" + g.Pick("", " ", " ")
                    + g.Pick("1", "2.5", "\"x\"", "true", "{ 1, 2 }", "", "= 1", "\"a = b\"") + g.Pick("", "", " -- note", "   ", ";");
            case 4: return "-- Config." + g.Pick(keys) + " = 1";
            case 5: return g.Pick("local Config = {}", "Config = {}", "local Config = { A = 1 }");
            case 6: return g.Pick("", "", "  ", "\t", " \t ");
            case 7: case 8:
                return g.Pick("", "", " ", "\t", "    ") + "return" + g.Pick(" ", " ", "  ", "\t", "") + "Config" + g.Pick("", "", " ", " -- end", "2", ";", " ;");
            case 9: return g.Pick("return", "Config", "x = Config.A == 1", "-- return Config", "local x = 1", "return {}", "returnConfig", "return config");
            case 10: return "Config." + g.Pick(keys);
            default: return g.Pick("-- a comment", "--[[", "]]", "Config.Other = 5", "Config.A.B = 1", "Config . A = 1");
        }
    }

    private static string RandomLines(Rng g, string[] keys)
    {
        int n = g.Next(9);
        string eol = g.Pick("\n", "\n", "\n", "\r\n", "\r\n", "\r", "mixed");
        var sb = new StringBuilder(g.Chance(0.05) ? ByteText.Bom : "");
        for (int i = 0; i < n; i++)
        {
            sb.Append(RandomLine(g, keys));
            if (i < n - 1 || !g.Chance(0.2)) sb.Append(eol == "mixed" ? g.Pick("\n", "\r\n", "\r", "\n\r") : eol);
        }
        if (g.Chance(0.15)) sb.Append(g.Pick("\n", "\n\n", " ", "\t\n", "\r\n\r\n", "\v", "\f\n"));
        return sb.ToString();
    }

    private static readonly string[] Words =
    {
        "", "x", "hello world", "say \"hi\"", "back\\slash", "tab\there", "line\nbreak", "Gr\u00C3\u00B6\u00C3\u009Fe", "%1 %d", "100 %", "-- not a comment", "]] ]=]", "'single'", "a=b",
        "\u007F", "\u0001", "return Config", "Config.A = 1", "a\\", "\\\"", "  spaces  ", "\u00E2\u0082\u00AC", "\u00FF\u00FE", "1", "true",
    };

    // a text as Lua source, written in one of the ways Lua has
    private static string LuaString(Rng g, string text)
    {
        int style = g.Next(10);
        if (style >= 8 && !text.Contains(']') && !text.Contains('\r') && !text.StartsWith('\n') && !text.Any(c => c < 32 && c != '\n' && c != '\t'))
            return g.Chance(0.5) ? "[[" + text + "]]" : "[==[" + text + "]==]";
        char q = style < 6 ? '"' : '\'';
        var sb = new StringBuilder().Append(q);
        foreach (char c in text)
        {
            if (c == q || c == '\\') sb.Append('\\').Append(c);
            else if (c == '\n') sb.Append(g.Pick("\\n", "\\010", "\\x0A", "\\\n"));
            else if (c == '\t') sb.Append(g.Pick("\\t", "\\009", "\t"));
            else if (c < 32 || c == 127) sb.Append('\\').Append(((int)c).ToString("000", Inv));
            else if (c > 127 && g.Chance(0.3)) sb.Append("\\x").Append(((int)c).ToString("X2", Inv));
            else if (g.Chance(0.03)) sb.Append('\\').Append(((int)c).ToString("000", Inv));
            else sb.Append(c);
        }
        return sb.Append(q).ToString();
    }

    private static string RandomNumberLiteral(Rng g, SchemaItem? item)
    {
        if (g.Chance(0.08)) return g.Pick("1e999", "-1e999", "0x.8p1", "0x10", "1e1", "\"abc\"", "\"\"", "\"0x10\"", "\"5,5\"", "\"1e1\"", "2,5", "0xA", ".5", "5.", "3.0", "0x1p1", "\"0x1p1\"");
        double min = item != null && item.Kind == ItemKind.Number ? item.Min : 0, max = item != null && item.Kind == ItemKind.Number ? item.Max : 10;
        if (double.IsInfinity(min) || Math.Abs(min) > 1e12) min = -1000;
        if (double.IsInfinity(max) || Math.Abs(max) > 1e12) max = 1000;
        double v = g.Next(10) switch
        {
            0 => min, 1 => max, 2 => min - 1, 3 => max + 1, 4 => max + 0.004, 5 => min + (max - min) / 2,
            6 => Math.Round(min + (max - min) * g.Unit()), 7 => Math.Round(min + (max - min) * g.Unit(), 1),
            8 => min + Math.Round((max - min) * 8 * g.Unit()) / 8, _ => Math.Round(min + (max - min) * g.Unit(), g.Next(5)),
        };
        bool whole = v == Math.Floor(v) && Math.Abs(v) < 1e15;
        string text = g.Next(8) switch
        {
            0 when whole => ((long)v).ToString(Inv),
            1 => v.ToString("F3", Inv),
            2 => (v * 10).ToString("R", Inv) + "e-1",
            3 when whole && v >= 0 => "0x" + ((long)v).ToString("X", Inv),
            4 => g.Pick("\"", "'") is var quote ? quote + g.Pick("", " ") + v.ToString("R", Inv) + g.Pick("", " ") + quote : "",
            _ => v.ToString("R", Inv),
        };
        if (text.Contains('E')) text = v.ToString("F6", Inv);       // (an exponent written by .NET: keep it simple)
        return text.StartsWith('-') && g.Chance(0.2) ? "- " + text[1..] : text;
    }

    // the Lua source of a value for an item: mostly of its kind, sometimes of another
    private static string RandomLiteral(Rng g, SchemaItem? item)
    {
        int kind = item == null || g.Chance(0.15) ? g.Next(6) : (int)item.Kind;
        switch (kind)
        {
            case 0: return g.Pick("true", "false");
            case 1: return RandomNumberLiteral(g, item);
            case 2: return LuaString(g, item != null && item.Kind == ItemKind.Choice && g.Chance(0.7) ? g.From(item.Options) : g.Pick("a", "b", "c", "d", "", "first", "A"));
            case 3: return LuaString(g, g.From(Words));
            case 4: return LuaString(g, RandomKeyText(g));
            default: return g.Pick("nil", "{}", "{ 1, 2 }", "{ a = 1 }", "{ [\"k\"] = true, 5; 6 }", "{ nil, 2 }", "{ { 1 }, { 2 } }");
        }
    }

    // the text of a config.lua of plain values for the schema, written in many ways; now and then one that is not usable
    private static string RandomConfig(Rng g, ModuleSchema schema)
    {
        string table = g.Pick("Config", "Config", "Config", "C", "cfg");
        var lines = new List<string>();
        int locals = 0;
        if (g.Chance(0.15)) lines.Add(g.Pick("-- settings", "--[[ a block\ncomment ]]", "--[==[ x ]==]", ""));
        string header = g.Next(8) switch
        {
            0 => table + " = {}",
            1 => "local " + table + " = { " + string.Join(", ", schema.Items.Where(_ => g.Chance(0.4)).Select(i => i.Key + " = " + RandomLiteral(g, i))) + " }",
            _ => "local " + table + " = {}",
        };
        lines.Add(header);
        var targets = schema.Items.Where(_ => g.Chance(0.6)).ToList();
        if (g.Chance(0.3) && schema.Items.Count > 0) targets.Add(g.From(schema.Items));      // a key twice
        foreach (var item in targets.OrderBy(_ => g.Next(1000)))
        {
            string v = RandomLiteral(g, item), k = item.Key, name = "t" + (++locals).ToString(Inv);
            lines.Add(g.Next(14) switch
            {
                0 => table + "[\"" + k + "\"] = " + v,
                1 => table + "['" + k + "'] = " + v,
                2 => "  " + table + "." + k + "=" + v,
                3 => table + "." + k + " = " + v + ";",
                4 => table + "." + k + " = " + v + " -- comment",
                5 => "local " + name + " = " + v + "\n" + table + "." + k + " = " + name,
                6 => "local " + name + " = { x = " + v + " }\n" + table + "." + k + " = " + name + ".x",
                7 => "local " + name + " = { " + v + " }\n" + table + "." + k + " = " + name + "[1]",
                8 => table + "." + k + ", " + table + ".Extra1 = " + v + ", 1",
                9 => table + "\t.\t" + k + "\t=\t" + v,
                _ => table + "." + k + " = " + v,
            });
            if (g.Chance(0.1)) lines.Add(g.Pick("", "-- note", table + ".Unknown = 5", table + ".Sub = { Deep = { 1 } }", "--[[ " + table + "." + k + " = 0 ]]", ";"));
        }
        string footer = "return " + table + g.Pick("", "", ";", " -- end");
        if (g.Chance(0.12))
        {
            // not usable, for Lua and for the app alike
            switch (g.Next(9))
            {
                case 0: footer = ""; break;
                case 1: lines.Add("@@"); break;
                case 2: lines.Add(table + ".Missing1.X = 1"); break;
                case 3: lines.Add("local nothing = nil\n" + table + ".Z = nothing.x"); break;
                case 4: lines.Add("= 1"); break;
                case 5: lines.Add(table + ".T = { 1, 2"); break;
                case 6: lines.Add(table + ".S = \"abc"); break;
                case 7: footer += "\n" + table + ".Late = 1"; break;
                default: footer = "return 5"; break;
            }
        }
        if (footer.Length > 0) lines.Add(footer);
        string eol = g.Pick("\n", "\n", "\n", "\r\n", "\r");
        string text = string.Join("\n", lines) + g.Pick("\n", "\n", "", "\n\n", "\n-- the end\n");
        if (eol != "\n") text = text.Replace("\n", eol);
        return (g.Chance(0.05) ? ByteText.Bom : "") + text;
    }

    // the default text with things done to it that a player or an editor does
    private static string? RandomFile(Rng g, ModuleSchema schema)
    {
        int kind = g.Next(100);
        if (kind < 8) return null;
        string text = schema.DefaultText();
        if (kind < 28) return text;
        if (kind < 33) return g.Pick("this is not lua\n", "return 5\n", "local Config = {\n", "", "local Config = {}\n");
        if (kind < 55) return RandomConfig(g, schema);
        var lines = text.Split('\n').ToList();      // the last entry is the empty one behind the final line end
        int LineOf(string key) => lines.FindIndex(l => l.StartsWith("Config." + key + " = ", StringComparison.Ordinal));
        int ReturnLine() => lines.FindLastIndex(l => l.StartsWith("return Config", StringComparison.Ordinal));
        string eol = "\n";
        bool bom = false;
        int changes = 1 + g.Next(4);
        for (int c = 0; c < changes; c++)
        {
            var item = g.From(schema.Items);
            int at = LineOf(item.Key), ret = ReturnLine();
            switch (g.Next(12))
            {
                case 0: case 1: case 2:
                    if (at >= 0) lines[at] = "Config." + item.Key + " = " + RandomLiteral(g, item);
                    else if (ret >= 0) lines.Insert(ret, "Config." + item.Key + " = " + RandomLiteral(g, item));
                    break;
                case 3: eol = "\r\n"; break;
                case 4: if (at >= 0) lines.RemoveAt(at); break;
                case 5: if (ret >= 0) lines.Insert(g.Chance(0.5) ? ret : Math.Max(0, ret - 1), "Config." + item.Key + " = " + RandomLiteral(g, item)); break;
                case 6: if (at >= 0) lines[at] = g.Pick("    ", "\t", " ") + lines[at] + g.Pick("", " -- mine", "  "); break;
                case 7: if (ret >= 0) lines.Insert(g.Next(ret + 1), g.Pick("Config.Mine = 5", "-- a note of mine", "Config.Other = { 1, 2 }", "")); break;
                case 8: if (lines.Count > 1 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1); break;
                case 9: if (ret >= 0) lines.Insert(ret, ""); break;
                case 10: if (ret >= 0 && g.Chance(0.3)) lines.RemoveAt(ret); break;
                default: bom = true; break;
            }
        }
        return (bom ? ByteText.Bom : "") + string.Join(eol, lines);
    }

    private static object? RandomValue(Rng g, SchemaItem item)
    {
        if (g.Chance(0.06)) return g.Pick<object?>(true, 5.0, "text", double.NaN, double.PositiveInfinity, "3.5", "", -1.0);
        switch (item.Kind)
        {
            case ItemKind.Bool: return g.Chance(0.5);
            case ItemKind.Number:
                {
                    double min = Math.Max(item.Min, -1e9), max = Math.Min(item.Max, 1e9);
                    return g.Next(8) switch
                    {
                        0 => min, 1 => max, 2 => max + 1 + g.Next(100), 3 => min - 0.5,
                        4 => Math.Round(min + (max - min) * g.Unit()), 5 => Math.Round(min + (max - min) * g.Unit(), item.Decimals),
                        6 => min + Math.Round((max - min) * 16 * g.Unit()) / 16, _ => min + (max - min) * g.Unit(),
                    };
                }
            case ItemKind.Choice: return g.Chance(0.85) ? g.From(item.Options) : g.Pick("zz", "", "A");
            case ItemKind.Key: return g.Chance(0.5) ? RandomKeyText(g) : g.Pick("", "Y", "CTRL+Y", "SHIFT+ALT+F5", "F9", "NUM_FIVE");
            default: return g.From(Words);
        }
    }

    private static string RandomScenario(Rng g, string name, string schemaName, ModuleSchema schema)
    {
        var fields = new List<string?> { "apply", name, schemaName, RandomFile(g, schema) };
        int steps = 1 + g.Next(5);
        fields.Add(steps.ToString(Inv));
        for (int s = 0; s < steps; s++)
        {
            int kind = g.Next(100);
            if (kind < 15) { fields.Add("disk"); fields.Add(RandomFile(g, schema)); }
            else if (kind < 23) fields.Add("reset");
            else
            {
                var values = new Dictionary<string, object?>(StringComparer.Ordinal);
                int count = 1 + g.Next(4);
                for (int i = 0; i < count; i++)
                {
                    var item = g.From(schema.Items);
                    values[item.Key] = RandomValue(g, item);
                }
                if (g.Chance(0.05)) values["Nope"] = 1.0;
                fields.Add("set");
                fields.Add(values.Count.ToString(Inv));
                foreach (var kv in values.OrderBy(kv => kv.Key, StringComparer.Ordinal))
                {
                    fields.Add(kv.Key);
                    fields.Add(TypedText(kv.Value));
                }
            }
        }
        return CaseLine(fields.ToArray());
    }

    // ------------------------------------------------------------------ schemas
    private static string Q(string text) => "\"" + text.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n") + "\"";

    private static string RandomSchema(Rng g)
    {
        var sb = new StringBuilder("-- a schema made up at random\nlocal Schema = {}\n");
        if (g.Chance(0.8)) sb.Append("Schema.Module = " + Q(g.Pick("mod", "alpha", "x y")) + "\n");
        if (g.Chance(0.7)) sb.Append("Schema.Page = " + Q(g.Pick("Combat", "Time", "A, B")) + "\n");
        if (g.Chance(0.5)) sb.Append("Schema.PageOrder = " + g.Pick("10", "\"20\"", "5.5", "true") + "\n");
        switch (g.Next(8))
        {
            case 0: break;
            case 1: sb.Append("Schema.Header = \"One line\"\n"); break;
            case 2: sb.Append("Schema.Header = " + g.Pick("5", "false", "{}", "{ \"a\", 5, 2.5, true }") + "\n"); break;
            default: sb.Append("Schema.Header = { \"First line\", \"second \\\"line\\\"\" }\n"); break;
        }
        if (g.Chance(0.4)) sb.Append("Schema.Notes = " + g.Pick("{ \"a note\", \"another\" }", "\"one note\"", "{}") + "\n");
        if (g.Chance(0.03)) { sb.Append("Schema.Groups = " + g.Pick("\"x\"", "5", "{}") + "\nreturn Schema\n"); return sb.ToString(); }
        sb.Append("Schema.Groups = {\n");
        string[] pool = { "Enabled", "Amount", "Count", "Style", "Name", "Hotkey", "Extra", "On2", "_x", "K9", "Feature", "Speed" };
        var free = pool.OrderBy(_ => g.Next(1000)).ToList();
        var switches = new List<string>();
        int groups = 1 + g.Next(4);
        for (int gi = 0; gi < groups; gi++)
        {
            sb.Append("    { ");
            switch (g.Next(8))
            {
                case 0: break;
                case 1: sb.Append("Title = " + g.Pick("5", "false", "\"\"", "2.5") + ", "); break;
                default: sb.Append("Title = " + Q(g.Pick("Main", "Look", "On \"screen\"", "Advanced")) + ", "); break;
            }
            if (g.Chance(0.5)) sb.Append("Order = " + g.Pick("10", "20", "\"15\"", "100", "true") + ", ");
            if (g.Chance(0.3)) sb.Append("Hint = \"a hint\", ");
            if (g.Chance(0.03)) { sb.Append("},\n"); continue; }
            sb.Append("Items = {\n");
            int items = g.Next(5);
            for (int ii = 0; ii < items; ii++)
            {
                string key = free.Count > 0 && !g.Chance(0.03) ? free[0] : g.From(pool);
                if (free.Count > 0 && free[0] == key) free.RemoveAt(0);
                var f = new List<string>();
                bool badDecimals = false;
                if (g.Chance(0.02)) f.Add("Key = " + g.Pick("\"my key\"", "\"\"", "5", "\"9x\""));
                else if (!g.Chance(0.01)) f.Add("Key = " + Q(key));
                string kind = g.Pick("bool", "bool", "number", "number", "number", "choice", "text", "key", "action");
                if (g.Chance(0.03)) f.Add("Kind = " + g.Pick("\"slider\"", "5", "true", "\"Bool\""));
                else if (!g.Chance(0.01)) f.Add("Kind = " + Q(kind));
                switch (kind)
                {
                    case "bool":
                        if (!g.Chance(0.04)) f.Add("Default = " + (g.Chance(0.93) ? g.Pick("true", "false") : g.Pick("1", "\"true\"")));
                        if (g.Chance(0.5)) switches.Add(key);
                        break;
                    case "number":
                        {
                            double min = g.Pick(0, -5, 1, 0.5, -0.25, 10), max = min + g.Pick(0, 1, 10, 100, 0.5, 1000000);
                            double def = g.Pick(min, max, (min + max) / 2, min + (max - min) / 8);
                            string D(double v) => v.ToString("R", Inv);
                            if (g.Chance(0.9)) { f.Add("Default = " + D(def)); f.Add("Min = " + D(min)); f.Add("Max = " + D(max)); }
                            else
                            {
                                f.Add("Default = " + g.Pick(D(max + 1), D(min - 1), "\"3\"", D(def)));
                                if (g.Chance(0.6)) f.Add("Min = " + g.Pick(D(min), D(max + 5), "\"0\""));
                                if (g.Chance(0.6)) f.Add("Max = " + D(max));
                            }
                            if (g.Chance(0.7))
                            {
                                // (a float or a fraction as Decimals makes the game's number format fail when it writes the value)
                                badDecimals = g.Chance(0.05);
                                f.Add("Decimals = " + (badDecimals ? g.Pick("2.0", "2.5", "\"1.0\"") : g.Pick("0", "1", "2", "3", "\"1\"", "-1", "true", "15", "4")));
                            }
                            if (g.Chance(0.6)) f.Add("Step = " + g.Pick("1", "0.5", "0.25", "5", "0", "-1", "\"2\"", "true", "0.001"));
                            break;
                        }
                    case "choice":
                        {
                            string[] options = { "a", "b", "the third", "say \"x\"", "back\\slash", "" };
                            var chosen = options.Where(_ => g.Chance(0.5)).ToList();
                            if (chosen.Count == 0) chosen.Add("a");
                            if (g.Chance(0.05)) f.Add("Options = " + g.Pick("{}", "{ \"a\", 2 }", "\"abc\"", "{ one = \"a\" }"));
                            else if (!g.Chance(0.02)) f.Add("Options = { " + string.Join(", ", chosen.Select(Q)) + " }");
                            f.Add("Default = " + (g.Chance(0.9) ? Q(g.From(chosen)) : g.Pick("\"zz\"", "1", "true")));
                            break;
                        }
                    case "text":
                        if (!g.Chance(0.03)) f.Add("Default = " + (g.Chance(0.95) ? Q(g.Pick("", "x", "say \"hi\" \\ there", "two\nlines", "100 %")) : g.Pick("5", "true")));
                        break;
                    case "key":
                        if (!g.Chance(0.03)) f.Add("Default = " + (g.Chance(0.9) ? Q(g.Pick("", "Y", "CTRL+Y", "SHIFT+ALT+F5", "NUM_FIVE", "CTRL+SHIFT+ALT+OEM_102")) : g.Pick("\"ctrl+y\"", "\"NOKEY\"", "5", "\"ALT+CTRL+Y\"")));
                        break;
                }
                if (g.Chance(0.25) && switches.Count > 0) f.Add("Needs = " + Q(g.From(switches)));
                else if (g.Chance(0.05)) f.Add("Needs = " + g.Pick("\"Nothing\"", "true", "5", "\"\"", Q(g.From(pool))));
                if (!badDecimals && g.Chance(0.2)) f.Add("Hidden = " + g.Pick("true", "true", "true", "false", "0", "\"no\""));
                if (g.Chance(0.7)) f.Add("Label = " + Q(g.Pick("A label", "Every gain counts", "say \"x\"")));
                if (g.Chance(0.3)) f.Add("Unit = " + g.Pick("\"times\"", "\"%\"", "5"));
                if (g.Chance(0.55)) f.Add("Comment = " + g.Pick("\"One line.\"", "{ \"First line,\", \"second line.\" }", "5", "{}", "\"with \\\"quotes\\\" and a \\\\ backslash\""));
                sb.Append("        " + (g.Chance(0.02) ? "\"not an item\"" : "{ " + string.Join(", ", f.OrderBy(_ => g.Next(1000))) + " }") + ",\n");
            }
            sb.Append("    } },\n");
        }
        sb.Append("}\nreturn Schema\n");
        return sb.ToString();
    }
}
