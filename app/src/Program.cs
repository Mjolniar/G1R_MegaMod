// G1R_Repopulate Settings / G1R_MegaMod Settings - edits the settings files of
// the UE4SS mod (Gothic 1 Remake). The running game re-reads them within seconds.
//
// Standalone mod (Mods\G1R_Repopulate): the exe sits in the mod folder and edits
// Scripts\config.lua next to it. Window title "G1R_Repopulate Settings".
// Megamod (Mods\G1R_MegaMod): the exe sits in modules\repopulate and edits
// Scripts\config.lua next to it (the repopulate module, on the hand-written pages)
// and the Scripts\config.lua of every other module that describes its settings in
// a Scripts\schema.lua (..\<module>\Scripts\; one generic page per "Page" of those
// schemas, see dev/SETTINGS.md of the mod). Window title "G1R_MegaMod Settings".
//
//   G1R_Repopulate_Settings.exe                     open the editor
//   G1R_Repopulate_Settings.exe --config <file>     edit another config.lua (of the repopulate module; a megamod around it is used too)
//   G1R_Repopulate_Settings.exe --selftest <report> run the file tests, write a report, exit 0/1
//   G1R_Repopulate_Settings.exe --snapshot <dir>    render every tab to PNG (off screen) and exit
//   G1R_Repopulate_Settings.exe --snapshot-screen <dir>  the same, with the window shown and its picture taken from the screen
//                                                   (--smallest with either: the window at its smallest size)
//   G1R_Repopulate_Settings.exe --uitest <dir>      drive the window off screen on copies, write a report, exit 0/1
//   G1R_Repopulate_Settings.exe --migrate <in> <out>  rewrite a settings file of an earlier version in the current layout
namespace G1RRepopulateSettings;

#if !FILETESTS
internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        string? configPath = null, snapshotDir = null, selfTestReport = null, uiTestDir = null, migrateIn = null, migrateOut = null;
        bool fromScreen = false, smallest = false;
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i].ToLowerInvariant();
            string? next = i + 1 < args.Length ? args[i + 1] : null;
            if (a == "--config" && next != null) { configPath = next; i++; }
            else if (a == "--snapshot" && next != null) { snapshotDir = next; i++; }
            else if (a == "--snapshot-screen" && next != null) { snapshotDir = next; fromScreen = true; i++; }
            else if (a == "--smallest") smallest = true;
            else if (a == "--selftest" && next != null) { selfTestReport = next; i++; }
            else if (a == "--uitest" && next != null) { uiTestDir = next; i++; }
            else if (a == "--migrate" && next != null && i + 2 < args.Length) { migrateIn = next; migrateOut = args[i + 2]; i += 2; }
        }

        if (migrateIn != null && migrateOut != null)
            return SelfTest.Migrate(migrateIn, migrateOut);

        configPath ??= Paths.FindConfig();

        if (selfTestReport != null)
            return SelfTest.Run(configPath, selfTestReport);

        ApplicationConfiguration.Initialize();

        if (uiTestDir != null)
            return SelfTest.RunUi(configPath, uiTestDir);

        if (configPath == null || !File.Exists(configPath))
        {
            using var dlg = new OpenFileDialog
            {
                Title = "Find G1R_Repopulate\\Scripts\\config.lua",
                Filter = "G1R_Repopulate settings (config.lua)|config.lua|Lua files (*.lua)|*.lua",
                CheckFileExists = true,
            };
            if (snapshotDir != null || dlg.ShowDialog() != DialogResult.OK) return 2;
            configPath = dlg.FileName;
        }

        using var form = new MainForm(configPath, testMode: snapshotDir != null);
        if (snapshotDir != null)
            return form.RenderSnapshots(snapshotDir, fromScreen, smallest) ? 0 : 1;
        Application.Run(form);
        return 0;
    }
}
#endif

internal static class Paths
{
    // Standalone mod: the app lives in the mod folder (Mods\G1R_Repopulate) and the settings are
    // in Scripts\config.lua next to it. Megamod: the app lives in modules\repopulate of the mod
    // folder, with the same Scripts\config.lua next to it. The other candidates find the file
    // from the megamod's own folder, from a subfolder of the mod and from the Mods folder.
    // (The megamod's other modules are found from this file: MegaMod.Find.)
    public static string? FindConfig() => FindConfig(AppContext.BaseDirectory);

    public static string? FindConfig(string baseDir)
    {
        string[] candidates =
        {
            Path.Combine(baseDir, "Scripts", "config.lua"),
            Path.Combine(baseDir, "modules", "repopulate", "Scripts", "config.lua"),
            Path.Combine(baseDir, "..", "Scripts", "config.lua"),
            Path.Combine(baseDir, "G1R_Repopulate", "Scripts", "config.lua"),
            Path.Combine(baseDir, "G1R_MegaMod", "modules", "repopulate", "Scripts", "config.lua"),
        };
        foreach (string c in candidates)
        {
            try { if (File.Exists(c) && !IsLoaderSettings(c)) return Path.GetFullPath(c); } catch { }
        }
        return null;
    }

    // The megamod's own folder has a Scripts\config.lua too: the loader's settings (which modules
    // run, diagnostics). It is the one with a modules folder beside its Scripts folder, and it is
    // never taken for the repopulate settings.
    private static bool IsLoaderSettings(string configPath)
    {
        string? scripts = Path.GetDirectoryName(Path.GetFullPath(configPath));
        string? modFolder = scripts != null ? Path.GetDirectoryName(scripts) : null;
        return modFolder != null && Directory.Exists(Path.Combine(modFolder, "modules"));
    }

    public static string DataFile(string configPath, string name) =>
        Path.Combine(Path.GetDirectoryName(configPath) ?? ".", "data", name);
}

internal static class SettingsFile
{
    private static readonly System.Text.UTF8Encoding Utf8 = new(false);

    // How every settings file is written: temp file, then replace. The previous file stays
    // next to it as <name>.bak.
    public static void Write(string path, string text) => WriteBytes(path, Utf8.GetBytes(text));

    public static void WriteBytes(string path, byte[] bytes)
    {
        string tmp = path + ".tmp";
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                File.WriteAllBytes(tmp, bytes);
                if (File.Exists(path)) File.Replace(tmp, path, path + ".bak", ignoreMetadataErrors: true);
                else File.Move(tmp, path);
                return;
            }
            catch (IOException) when (attempt < 3)
            {
                // the running game looks at its settings files every few seconds: in that instant a file cannot be replaced
                Thread.Sleep(40);
            }
            catch
            {
                try { File.Delete(tmp); } catch { }     // nothing is left behind when the file could not be written
                throw;
            }
        }
    }
}
