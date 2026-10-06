using System.Globalization;
using System.Text;

namespace G1RRepopulateSettings;

/// <summary>Build verification: --selftest (file layer) and --uitest (drives the real window off screen).</summary>
internal static partial class SelfTest
{
    private sealed class Report
    {
        public readonly List<string> Lines = new();
        public int Fails;
        public void Check(bool ok, string msg)
        {
            Lines.Add((ok ? "ok   " : "FAIL ") + msg);
            if (!ok) Fails++;
        }
        public void Info(string msg) => Lines.Add("     " + msg);
    }

    private static readonly UTF8Encoding Utf8 = new(false);

    /// <summary>
    /// File tests: config.lua of the repopulate module (the hand-written pages), the settings of the
    /// modules that describe them in a schema.lua (the generic pages; SelfTestModules.cs), and the
    /// modules installed around configPath.
    /// </summary>
    public static int Run(string? configPath, string reportPath)
    {
        var r = new Report();
        KeepGameIniAway(Path.GetDirectoryName(Path.GetFullPath(reportPath)) ?? ".");
        MainFileChecks(r, configPath, reportPath);
        ModuleChecks(r, reportPath);
        GameStartChecks(r, reportPath);
        OtherModsChecks(r, reportPath);
        InstalledModuleChecks(r, configPath);
        return Finish(r, reportPath);
    }

    private static void MainFileChecks(Report r, string? configPath, string reportPath)
    {
        try
        {
            r.Check(configPath != null && File.Exists(configPath), "config.lua found: " + configPath);
            if (configPath == null) return;
            string text = File.ReadAllText(configPath).Replace("\r\n", "\n");
            var warnings = new List<string>();
            var s = Settings.FromText(text, warnings);
            r.Check(warnings.Count == 0, "parsed without warnings" + (warnings.Count > 0 ? ": " + string.Join("; ", warnings) : ""));

            string defaults = new Settings().ToLua();
            r.Check(defaults == text, "the app writes the shipped default config.lua byte for byte (only meaningful while the file holds the defaults)");
            if (defaults != text)
            {
                var a = defaults.Split('\n'); var b = text.Split('\n');
                for (int i = 0; i < Math.Max(a.Length, b.Length); i++)
                {
                    string x = i < a.Length ? a[i] : "<eof>", y = i < b.Length ? b[i] : "<eof>";
                    if (x != y) { r.Info($"first difference at line {i + 1}:\n       app : {x}\n       file: {y}"); break; }
                }
            }

            string once = s.ToLua();
            var s2 = Settings.FromText(once, new List<string>());
            r.Check(s2.ToLua() == once, "current file: write -> read -> write is stable");

            var e = s.Clone();
            e.NormalChance = 0.5;
            e.EliteEveryHours = 36;
            e.Species["Wolf"] = new SpeciesOverride { Chance = 0.6, EveryHours = 12 };
            e.Species["Meatbug"] = new SpeciesOverride { Enabled = false };
            e.Species["Some Name"] = new SpeciesOverride { Chance = 0.125 };
            e.ExcludePointPrefixes = new List<string> { "OC_", "NC_" };
            e.EliteSpecies = new List<string> { "ShadowBeast", "Snapper" };
            e.Extra[""] = new() { new("TestRootValue", 1.0) };
            e.Extra["Creatures"] = new() { new("EvidenceScanSeconds", 300.0), new("RecentSpawnHours", 30.0) };
            e.CrimeEnabled = false;
            e.CrimeDisableWeapons = false;
            e.CrimeForgetOld = false;
            e.Extra["Crime"] = new() { new("CheckSeconds", 5.0) };
            string edited = e.ToLua();
            var e2 = Settings.FromText(edited, new List<string>());
            r.Check(e2.ToLua() == edited, "edited settings: write -> read -> write is stable");
            r.Check(e2.NormalChance == 0.5 && e2.EliteEveryHours == 36, "group values kept");
            r.Check(e2.Species.TryGetValue("Wolf", out var w) && w.Chance == 0.6 && w.EveryHours == 12 && w.Enabled == null, "species override (chance + interval) kept");
            r.Check(e2.Species.TryGetValue("Meatbug", out var m) && m.Enabled == false && m.Chance == null, "species switched off kept");
            r.Check(e2.Species.TryGetValue("Some Name", out var sn) && sn.Chance == 0.125, "names with spaces and 3-decimal chances kept");
            r.Check(string.Join(",", e2.ExcludePointPrefixes) == "OC_,NC_" && string.Join(",", e2.EliteSpecies) == "ShadowBeast,Snapper", "lists kept in order");
            r.Check(e2.Extra.TryGetValue("Creatures", out var ex) && ex.Count == 2 && ex[0].Key == "EvidenceScanSeconds"
                && e2.Extra.TryGetValue("", out var rx) && rx.Count == 1
                && e2.Extra.TryGetValue("Crime", out var cx) && cx.Count == 1, "unknown settings kept");
            r.Check(!e2.CrimeEnabled && e2.CrimeDisableTheft && e2.CrimeDisableTrespassing && !e2.CrimeDisableWeapons && !e2.CrimeForgetOld,
                "crime switch kept (off, weapons still count, old crimes kept)");
            r.Check(new Settings().CrimeEnabled, "crime is on by default");

            // a settings file written before the crime switch existed (1.1): no Crime section
            int c0 = defaults.IndexOf("-- Crime: how people", StringComparison.Ordinal);
            int c1 = defaults.IndexOf("return Config", StringComparison.Ordinal);
            r.Check(c0 > 0 && c1 > c0, "default file contains the Crime section");
            if (c0 > 0 && c1 > c0)
            {
                string old11 = defaults.Remove(c0, c1 - c0).Replace("settings (v1.2)", "settings (v1.1)").Replace("NormalChance = 0.35", "NormalChance = 0.45");
                var ow = new List<string>();
                var o = Settings.FromText(old11, ow);
                r.Check(ow.Count == 0 && o.CrimeEnabled && o.CrimeDisableTheft && o.CrimeForgetOld && o.NormalChance == 0.45,
                    "a 1.1 settings file (no Crime section) reads without warnings: crime on, other values kept");
                string up = o.ToLua();
                r.Check(up.Contains("Config.Crime = {\n    Enabled = true,") && up.Contains("NormalChance = 0.45") && up.Contains("settings (v1.2)"),
                    "and is written back with the Crime section added");
            }
            string dir = Path.GetDirectoryName(Path.GetFullPath(reportPath)) ?? ".";
            File.WriteAllText(Path.Combine(dir, "selftest-edited-config.lua"), edited, Utf8);
            r.Info("edited sample written to selftest-edited-config.lua");

            try
            {
                Settings.FromText("local Config = {}\nConfig.Enabled = = true\nreturn Config\n", new List<string>());
                r.Check(false, "syntax errors are reported");
            }
            catch (LuaParseException pe) { r.Check(pe.Message.StartsWith("line 2:"), "syntax errors are reported with the line: " + pe.Message); }
            var bad = new List<string>();
            var sb = Settings.FromText("local Config = {}\nConfig.Creatures = { NormalChance = \"lots\", NormalEveryHours = 99999 }\nreturn Config\n", bad);
            r.Check(bad.Count == 1 && sb.NormalChance == 0.35 && sb.NormalEveryHours == 8760, "wrong types fall back to defaults, out-of-range values are clamped");
            var bom = Settings.FromText("\uFEFF" + text, new List<string>());
            r.Check(bom.ToLua() == s.ToLua(), "a byte order mark at the start is accepted");

            var cat = SpeciesCatalog.Load(Paths.DataFile(configPath, "creature_points.lua"), out string? err);
            r.Check(err == null && cat.Count == 30, $"species list: {cat.Count} species");
            r.Check(cat.Sum(c => c.Creatures) == 814 && cat.Sum(c => c.Points) == 402, $"creatures {cat.Sum(c => c.Creatures)}, species-points {cat.Sum(c => c.Points)}");
            r.Check(cat.Count(c => c.EliteInData) == 3, "3 species are elite in the data (Shadow Beast, Skeleton Mage, Swampshark)");
            r.Check(cat.Select(c => c.Display).Distinct().Count() == cat.Count, "display names are unique");
            foreach (var c in cat) r.Info($"{c.Display,-28} {c.Unique,-22} {c.Creatures,4} creatures {c.Points,4} points{(c.EliteInData ? "  elite" : "")}");
        }
        catch (Exception ex)
        {
            r.Check(false, "exception: " + ex);
        }
    }

#if !FILETESTS
    // A copy of the repopulate settings with data\creature_points.lua in the folder `scripts`.
    private static string CopyRepopulateFiles(string configPath, string scripts)
    {
        Directory.CreateDirectory(Path.Combine(scripts, "data"));
        string cfg = Path.Combine(scripts, "config.lua");
        File.Copy(configPath, cfg, true);
        File.Copy(Paths.DataFile(configPath, "creature_points.lua"), Path.Combine(scripts, "data", "creature_points.lua"), true);
        if (File.Exists(cfg + ".bak")) File.Delete(cfg + ".bak");
        return cfg;
    }

    /// <summary>
    /// Drives the real window off screen on copies of the settings, in dir:
    /// megamod\ - the megamod layout: the repopulate settings (a copy of configPath) in
    ///   modules\repopulate\Scripts, next to test modules with a schema.lua (xp and general as the tests
    ///   carry them, a module with every kind of setting, a second one on that module's page, one
    ///   without a schema, one with a broken one).
    ///   First the hand-written pages are driven, then the pages made from the schemas (and one image
    ///   per tab is saved: uitest-*.png).
    /// standalone\ - the layout of the separate mod G1R_Repopulate: no pages of other modules.
    /// </summary>
    public static int RunUi(string? configPath, string dir)
    {
        var r = new Report();
        try
        {
            if (configPath == null || !File.Exists(configPath)) { r.Check(false, "config.lua not found"); return Finish(r, Path.Combine(dir, "uitest-report.txt")); }
            Directory.CreateDirectory(dir);
            KeepGameIniAway(dir);
            string root = Path.Combine(dir, "megamod");
            DeleteTree(root);
            string cfg = CopyRepopulateFiles(configPath, Path.Combine(root, "modules", "repopulate", "Scripts"));
            var modules = WriteTestModules(root);
            var untouched = modules.ToDictionary(m => m, m => ByteTextOf(Path.Combine(root, "modules", m, "Scripts", "config.lua")));

            // ---- the hand-written pages of the repopulate module
            var log = new List<string>();
            using (var form = new MainForm(cfg, testMode: true))
                form.RunUiScript(log);
            foreach (string l in log) r.Info(l);

            var w = new List<string>();
            var s = Settings.FromText(File.ReadAllText(cfg), w);
            r.Check(w.Count == 0, "saved file reads back without warnings");
            r.Check(File.Exists(cfg + ".bak"), "previous version kept as config.lua.bak");
            r.Check(Near(s.NormalChance, 1.0) && s.NormalEveryHours == 12, $"normal: 50 % x2 = 100 %, 24 h x0.5 = 12 h -> {s.NormalChance} / {s.NormalEveryHours}");
            r.Check(Near(s.EliteChance, 0.3) && s.EliteEveryHours == 18, $"elite: 15 % x2 = 30 %, 36 h x0.5 = 18 h -> {s.EliteChance} / {s.EliteEveryHours}");
            r.Check(s.Species.TryGetValue("Wolf", out var wolf) && Near(wolf.Chance ?? -1, 1.0) && wolf.EveryHours == 6,
                $"Wolf own settings: 60 % x2 capped at 100 %, 12 h x0.5 = 6 h -> {wolf?.Chance} / {wolf?.EveryHours}");
            r.Check(s.Species.TryGetValue("Meatbug", out var mb) && mb.Enabled == false, "Meatbug switched off");
            r.Check(s.EliteSpecies.Contains("Snapper") && !s.EliteSpecies.Contains("Swampshark") && s.EliteSpecies.Contains("ShadowBeast")
                && s.EliteSpecies.Contains("Troll"), "elite list: Snapper added, Swampshark removed, others and unknown names kept: " + string.Join(", ", s.EliteSpecies));
            r.Check(!s.RemoveCorpsesOnRespawn && s.RetroactiveDays == 5, "corpses kept, retroactive 5 days");
            r.Check(string.Join(",", s.ExcludePointPrefixes) == "OC_,NC_", "point prefixes: " + string.Join(",", s.ExcludePointPrefixes));
            r.Check(Near(s.DailyChance, 0.3) && Near(s.SettlementDailyChance, 0.6) && Near(s.WildDailyChance, 0.2) && s.RegrowHours == 12,
                $"items 30 %, containers 60 % / 20 %, herbs 12 h -> {s.DailyChance} {s.SettlementDailyChance} {s.WildDailyChance} {s.RegrowHours}");
            int overrides = s.Species.Count;
            r.Check(overrides == 2, $"only the two edited species have entries ({overrides})");
            r.Check(!s.CrimeEnabled && s.CrimeDisableTheft && s.CrimeDisableTrespassing && !s.CrimeDisableWeapons && s.CrimeForgetOld,
                $"crime: system off, theft and trespassing off, weapons still count, forget on -> {s.CrimeEnabled} {s.CrimeDisableTheft} {s.CrimeDisableTrespassing} {s.CrimeDisableWeapons} {s.CrimeForgetOld}");
            r.Check(log.Any(l => l.Contains("kinds locked while on = True, editable while off = True")), "crime kinds are only editable while the system is off");
            r.Check(log.Any(l => l.Contains("Off: nobody reacts to theft, trespassing. Hitting or killing people still counts.")), "crime state text follows the boxes");


            // the megamod around the file: its title, the pages of the other modules behind the hand-written ones
            r.Check(log.Contains("pages: " + Walk.Layout),
                "megamod layout: the overview, the five hand-written pages under World, the tabs made from the schemas in their categories, and last the page of the module with a broken schema");
            r.Check(log.Contains("title at start: \"G1R_MegaMod Settings\"") && log.Contains("title before save 1: \"G1R_MegaMod Settings *\"")
                && log.Contains("title after save 1: \"G1R_MegaMod Settings\""), "in the megamod layout the title is G1R_MegaMod Settings, with the star while there are unsaved changes");
            r.Check(modules.All(m => ByteTextOf(Path.Combine(root, "modules", m, "Scripts", "config.lua")) == untouched[m]
                    && !File.Exists(Path.Combine(root, "modules", m, "Scripts", "config.lua.bak")) && !File.Exists(Path.Combine(root, "modules", m, "Scripts", "config.lua.tmp")))
                && log.Any(l => l.StartsWith("save 1: ") && !l.Contains("Also saved")) && log.Any(l => l.StartsWith("save 2: ") && !l.Contains("Also saved")),
                "saving changes of the repopulate pages leaves the other modules' files alone (nothing written, no .bak)");

            // ---- the pages made from the schemas
            using (var form = new MainForm(cfg, testMode: true))
                SchemaPageChecks(r, form, root, dir);

            // ---- the layout of the separate mod: no megamod, no pages of other modules
            string standalone = Path.Combine(dir, "standalone");
            DeleteTree(standalone);
            string cfg2 = CopyRepopulateFiles(configPath, Path.Combine(standalone, "G1R_Repopulate", "Scripts"));
            string other = Path.Combine(standalone, "Other", "Scripts");
            Directory.CreateDirectory(other);
            File.WriteAllText(Path.Combine(other, "schema.lua"), TinySchema("other", "Other", 1, ("never shown", null)), Utf8);
            bool corpsesBefore = Settings.FromText(File.ReadAllText(cfg2), new List<string>()).RemoveCorpsesOnRespawn;
            var log2 = new List<string>();
            using (var form = new MainForm(cfg2, testMode: true))
                form.RunUiScriptStandalone(log2);
            foreach (string l in log2) r.Info(l);
            r.Check(log2.Any(l => l.Contains("pages: World: Creatures, Herbs and items, Containers, Crime, Advanced; title at start: \"G1R_Repopulate Settings\"")),
                "standalone layout: the title is G1R_Repopulate Settings and there are the five hand-written pages only (a schema.lua in a folder next to the mod is not picked up)");
            r.Check(log2.Any(l => l.Contains("title after an edit: \"G1R_Repopulate Settings *\"")) && log2.Any(l => l.Contains("saved, title: \"G1R_Repopulate Settings\"")),
                "the star follows that title too");
            r.Check(Settings.FromText(File.ReadAllText(cfg2), new List<string>()).RemoveCorpsesOnRespawn != corpsesBefore && File.Exists(cfg2 + ".bak"),
                "config.lua of that copy was saved (previous version kept as config.lua.bak)");
            r.Check(!log2.Any(l => l.Contains("Also saved")) && Directory.GetFiles(other).Length == 1, "nothing was written next to it");

            // ---- the module intro: its setting, Save, Game.ini (below the test folder)
            GameStartUiChecks(r, configPath, dir);
        }
        catch (Exception ex)
        {
            r.Check(false, "exception: " + ex);
        }
        return Finish(r, Path.Combine(dir, "uitest-report.txt"));
    }
#endif

    /// <summary>
    /// --migrate: read a settings file written by any earlier version and write it in the current layout
    /// (same values, new sections with their defaults). A short report goes next to the output file.
    /// Exit code 0 = written and verified, 3 = the input could not be read, 1 = anything else.
    /// </summary>
    public static int Migrate(string inPath, string outPath)
    {
        var r = new Report();
        string reportPath = outPath + ".migrate-report.txt";
        try
        {
            string text;
            Settings s;
            var warnings = new List<string>();
            try
            {
                text = File.ReadAllText(inPath);
                s = Settings.FromText(text, warnings);
            }
            catch (Exception ex)
            {
                r.Check(false, "input not readable: " + ex.Message);
                Finish(r, reportPath);
                return 3;
            }
            r.Check(true, "read " + inPath);
            foreach (string w in warnings) r.Info("warning: " + w);
            string written = s.ToLua();
            var back = Settings.FromText(written, new List<string>());
            r.Check(back.ToLua() == written, "written settings read back identically");
            string defaults = new Settings().ToLua();
            r.Info(written == defaults ? "values: all defaults" : "values: differ from the defaults (kept)");
            r.Info($"crime: Enabled = {s.CrimeEnabled}, DisableTheft = {s.CrimeDisableTheft}, DisableTrespassing = {s.CrimeDisableTrespassing}, DisableWeapons = {s.CrimeDisableWeapons}, ForgetOldCrimes = {s.CrimeForgetOld}");
            if (r.Fails == 0) File.WriteAllText(outPath, written, Utf8);
            r.Check(r.Fails == 0 && File.Exists(outPath), "wrote " + outPath);
        }
        catch (Exception ex)
        {
            r.Check(false, "exception: " + ex);
        }
        return Finish(r, reportPath);
    }

    private static bool Near(double a, double b) => Math.Abs(a - b) < 1e-9;

    private static int Finish(Report r, string path)
    {
        r.Lines.Add(r.Fails == 0 ? "ALL OK" : $"{r.Fails} FAILURE(S)");
        try { File.WriteAllLines(path, r.Lines, Utf8); } catch { }
        return r.Fails == 0 ? 0 : 1;
    }
}
