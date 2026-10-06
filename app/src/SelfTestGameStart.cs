using System.Text;

namespace G1RRepopulateSettings;

internal static partial class SelfTest
{
    // =====================================================================
    // Game.ini (GameStart.cs): the logos at the start of the game
    // =====================================================================
    // The tests never touch the player's Game.ini: every test entry puts it below its own folder first.
    private static void KeepGameIniAway(string dir)
    {
        GameStart.IniPath = Path.Combine(Path.GetFullPath(dir), "gamestart-away", "Game.ini");
        GameStart.GameRuns = () => false;
    }

    private static bool Balanced(string text)
    {
        int depth = 0;
        bool quoted = false;
        foreach (char c in text)
        {
            if (c == '"') quoted = !quoted;
            else if (!quoted && c == '(') depth++;
            else if (!quoted && c == ')' && --depth < 0) return false;
        }
        return depth == 0 && !quoted;
    }

    private static void GameStartChecks(Report r, string reportPath)
    {
        string dir = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(reportPath)) ?? ".", "gamestart-work");
        string keptPath = GameStart.IniPath;
        var keptRuns = GameStart.GameRuns;
        bool runs = false;
        try
        {
            DeleteTree(dir);
            string ini = Path.Combine(dir, "G1R", "Saved", "Config", "Windows", "Game.ini");
            string backup = ini + GameStart.BackupSuffix;
            GameStart.IniPath = ini;
            GameStart.GameRuns = () => runs;
            var latin1 = Encoding.Latin1;
            string value = GameStart.Value;
            r.Check(value.StartsWith("(MinimumLoadingScreenDisplayTime=-1.000000,bAutoCompleteWhenLoadingCompletes=False,bMoviesAreSkippable=False,", StringComparison.Ordinal)
                && value.Contains(",PlaybackType=MT_LoadingLoop,MoviePaths=(\"LoopingEngineLoadScreen\"),bShuffle=False,", StringComparison.Ordinal)
                && !value.Contains("Alkimia_Logo", StringComparison.Ordinal) && !value.Contains("THQNordic_Logo", StringComparison.Ordinal)
                && !value.Contains("V_LegalScreen", StringComparison.Ordinal) && value.EndsWith(",Layout=ALSL_Classic)", StringComparison.Ordinal)
                && value.All(c => c >= ' ' && c <= '~') && Balanced(value),
                $"the value the app writes: the game's own start screen ({value.Length} characters, plain text, parentheses balanced) with only the three logos left out");
            string block(string nl) => GameStart.Begin + nl + GameStart.Section + nl + GameStart.Key + "=" + value + nl + GameStart.End + nl;

            // ---- no file, no folder
            r.Check(GameStart.Note(false) == "" && GameStart.Apply(false) == ("", false) && !File.Exists(ini) && !Directory.Exists(dir),
                "setting off, no file: nothing to say, nothing written, no folder made");
            r.Check(GameStart.Note(true) == "Game.ini: logos not skipped yet. Save with the game closed.", "setting on, no file: the page says so");
            runs = true;
            var (t1, w1) = GameStart.Apply(true);
            r.Check(w1 && t1 == "Game.ini not changed while the game runs: Save again once it is closed." && !File.Exists(ini),
                "while the game runs: nothing written, said as a warning");
            runs = false;
            var (t2, w2) = GameStart.Apply(true);
            r.Check(!w2 && t2 == "Game.ini: logos skipped from the next start." && File.Exists(ini)
                && latin1.GetString(File.ReadAllBytes(ini)) == block("\r\n") && !File.Exists(backup),
                "game closed: the folder and the file are made, holding exactly the app's four lines (CRLF); no backup of a file that was not there");
            var look = GameStart.Read(ini);
            r.Check(look.Ours && !look.Theirs && look.Problem == null && GameStart.Note(true) == "" && GameStart.Apply(true) == ("", false),
                "read back: the app's lines; saving again changes nothing");
            r.Check(GameStart.Note(false) == "Game.ini: logos still skipped. Save with the game closed.", "setting off while the lines are there: the page says so");
            runs = true;
            var (t3, w3) = GameStart.Apply(false);
            r.Check(w3 && t3.StartsWith("Game.ini not changed while the game runs", StringComparison.Ordinal) && GameStart.Read(ini).Ours, "taking the lines out waits for the game to be closed, too");
            runs = false;
            var (t4, w4) = GameStart.Apply(false);
            r.Check(!w4 && t4 == "Game.ini: lines taken out, logos play again from the next start." && !File.Exists(ini),
                "switched off: the file the app made goes again (it held nothing else)");

            // ---- a file of the player's: kept byte for byte, its first version kept beside it
            byte[] own = latin1.GetBytes("[/Script/Engine.Engine]\r\nbSmoothFrameRate=True\r\n; café ÿ\r\n");
            File.WriteAllBytes(ini, own);
            GameStart.Apply(true);
            byte[] after = File.ReadAllBytes(ini);
            r.Check(after.Take(own.Length).SequenceEqual(own) && latin1.GetString(after, own.Length, after.Length - own.Length) == block("\r\n")
                && File.ReadAllBytes(backup).SequenceEqual(own),
                "a file with lines of its own (and bytes that are no ASCII): the app's lines go behind them, the rest stays byte for byte; the first version is kept as Game.ini" + GameStart.BackupSuffix);
            GameStart.Apply(false);
            r.Check(File.Exists(ini) && File.ReadAllBytes(ini).SequenceEqual(own), "switched off: the file is again what it was, byte for byte");
            File.WriteAllBytes(ini, latin1.GetBytes("[x]\r\nA=2\r\n"));
            GameStart.Apply(true);
            r.Check(File.ReadAllBytes(backup).SequenceEqual(own), "the backup is the first version only: it is not written again");
            GameStart.Apply(false);
            File.Delete(backup);

            // ---- line ends, a last line without its end, an empty file
            File.WriteAllBytes(ini, latin1.GetBytes("[x]\nA=1"));
            GameStart.Apply(true);
            r.Check(latin1.GetString(File.ReadAllBytes(ini)) == "[x]\nA=1\n" + block("\n"), "a file with LF line ends and no end on its last line: that line gets one, the app's lines have LF");
            GameStart.Apply(false);
            r.Check(latin1.GetString(File.ReadAllBytes(ini)) == "[x]\nA=1\n", "switched off: the file keeps the line end it got");
            File.Delete(backup);
            File.WriteAllBytes(ini, Array.Empty<byte>());
            GameStart.Apply(true);
            r.Check(latin1.GetString(File.ReadAllBytes(ini)) == block("\r\n") && File.Exists(backup) && new FileInfo(backup).Length == 0, "an empty file: the app's lines, the empty file kept");
            GameStart.Apply(false);
            r.Check(File.Exists(ini) && new FileInfo(ini).Length == 0, "switched off: an empty file again (it was there before the app wrote it)");
            File.Delete(backup);
            File.Delete(ini);

            // ---- UTF-16 and UTF-8 with a mark: the way the engine and editors write
            string text16 = "[/Script/Engine.Engine]\r\nName=Łódź\r\n";
            byte[] utf16 = new byte[] { 0xFF, 0xFE }.Concat(Encoding.Unicode.GetBytes(text16)).ToArray();
            File.WriteAllBytes(ini, utf16);
            GameStart.Apply(true);
            byte[] u = File.ReadAllBytes(ini);
            r.Check(u[0] == 0xFF && u[1] == 0xFE && Encoding.Unicode.GetString(u, 2, u.Length - 2) == text16 + block("\r\n") && GameStart.Read(ini).Ours,
                "a file in UTF-16: the app's lines are written in UTF-16 behind its own, which stay as they are");
            GameStart.Apply(false);
            r.Check(File.ReadAllBytes(ini).SequenceEqual(utf16), "switched off: byte for byte the UTF-16 file it was");
            File.Delete(backup);
            byte[] utf8 = new byte[] { 0xEF, 0xBB, 0xBF }.Concat(Encoding.UTF8.GetBytes("[x]\r\nB=é\r\n")).ToArray();
            File.WriteAllBytes(ini, utf8);
            GameStart.Apply(true);
            GameStart.Apply(false);
            r.Check(File.ReadAllBytes(ini).SequenceEqual(utf8), "a file in UTF-8 with its mark: in and out, byte for byte");
            File.Delete(backup);

            // ---- the key set by somebody else
            string theirs = "[/Script/AsyncLoadingScreen.LoadingScreenSettings]\r\nStartupLoadingScreen=(MoviePaths=())\r\n";
            File.WriteAllBytes(ini, latin1.GetBytes(theirs));
            var (t5, w5) = GameStart.Apply(true);
            r.Check(w5 && t5 == "Game.ini has its own start screen line: left alone." && latin1.GetString(File.ReadAllBytes(ini)) == theirs
                && !File.Exists(backup) && GameStart.Note(true).StartsWith("Game.ini has its own start screen line", StringComparison.Ordinal),
                "the key set in the plugin's section by somebody else: left as it is, said on the page and the status line");
            r.Check(GameStart.Apply(false) == ("", false) && GameStart.Note(false) == "", "with the setting off it is nothing of the app's");
            File.WriteAllBytes(ini, latin1.GetBytes("[/script/asyncloadingscreen.loadingscreensettings]\r\n  +startuploadingscreen = (x)\r\n"));
            r.Check(GameStart.Read(ini).Theirs, "the section and the key in other cases and spacing, with a sign in front, are found as well");
            File.WriteAllBytes(ini, latin1.GetBytes("[/Script/AsyncLoadingScreen.LoadingScreenSettings]\r\n;StartupLoadingScreen=(x)\r\nOther=1\r\n[Other]\r\nStartupLoadingScreen=(x)\r\n"));
            r.Check(!GameStart.Read(ini).Theirs, "a comment, another key, the key in another section: not the key");
            File.WriteAllBytes(ini, latin1.GetBytes(block("\r\n") + theirs));
            var (t6, w6) = GameStart.Apply(true);
            r.Check(w6 && t6.StartsWith("Game.ini also has its own start screen line", StringComparison.Ordinal), "the app's lines, and the key set again behind them: said");
            File.Delete(ini);

            // ---- a Begin or End line left alone never takes lines of the player's with it
            string orphan = GameStart.Begin + "\r\n[x]\r\nA=1\r\n";
            File.WriteAllBytes(ini, latin1.GetBytes(orphan));
            r.Check(!GameStart.Read(ini).Ours, "only a Begin line: not the app's lines");
            GameStart.Apply(true);
            r.Check(GameStart.Read(ini).Ours, "the app's lines go behind it");
            GameStart.Apply(false);
            r.Check(latin1.GetString(File.ReadAllBytes(ini)) == orphan, "switched off: the lines in between stay");
            File.Delete(backup);
            string lonelyEnd = GameStart.End + "\r\n[x]\r\n";
            File.WriteAllBytes(ini, latin1.GetBytes(lonelyEnd));
            GameStart.Apply(true);
            r.Check(GameStart.Read(ini).Ours && GameStart.Apply(true) == ("", false), "an End line in front of everything: the app's lines are found behind it; saving again adds nothing");
            GameStart.Apply(false);
            r.Check(latin1.GetString(File.ReadAllBytes(ini)) == lonelyEnd, "switched off: as it was");
            File.Delete(backup);
            File.Delete(ini);

            // ---- what cannot be done
            Directory.CreateDirectory(ini);
            var (t7, w7) = GameStart.Apply(true);
            r.Check(w7 && t7.StartsWith("Game.ini could not be written: ", StringComparison.Ordinal) && !File.Exists(ini + ".tmp"),
                "a Game.ini that is a folder: cannot be written, said as a warning; nothing half-written is left behind (" + t7 + ")");
            Directory.Delete(ini);
            File.WriteAllBytes(ini, latin1.GetBytes("[x]\r\n"));
            using (new FileStream(ini, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            {
                // (only Windows keeps others out of a file that is open)
                if (OperatingSystem.IsWindows())
                {
                    var (t8, w8) = GameStart.Apply(true);
                    r.Check(w8 && t8.StartsWith("Game.ini could not be read: ", StringComparison.Ordinal) && GameStart.Note(true).StartsWith("Game.ini cannot be read (", StringComparison.Ordinal)
                        && GameStart.Note(false) == "" && GameStart.Apply(false) == ("", false), "a Game.ini another program holds open: cannot be read, said while the setting is on");
                }
            }
            r.Check(latin1.GetString(File.ReadAllBytes(ini)) == "[x]\r\n" && !File.Exists(backup), "and nothing was changed");
        }
        catch (Exception ex)
        {
            r.Check(false, "exception (Game.ini): " + ex);
        }
        finally
        {
            GameStart.IniPath = keptPath;
            GameStart.GameRuns = keptRuns;
            DeleteTree(dir);
        }
    }

    // =====================================================================
    // the other mods' settings files (OtherMods.cs)
    // =====================================================================
    private static void OtherModsChecks(Report r, string reportPath)
    {
        string mods = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(reportPath)) ?? ".", "othermods-work");
        var keptRuns = GameStart.GameRuns;
        bool runs = false;
        try
        {
            DeleteTree(mods);
            var latin1 = Encoding.Latin1;
            string fnp = Path.Combine(mods, "PLuaModLoader", "Scripts", "Mods", "FocusNearbyPickups", "FocusNearbyPickups.ini");
            string apu = Path.Combine(mods, "G1R_AutoPickUpItemNative", "G1R_AutoPickUpItemNative.ini");
            Directory.CreateDirectory(Path.GetDirectoryName(fnp)!);
            Directory.CreateDirectory(Path.GetDirectoryName(apu)!);
            string fnpText = "toggleKey=F6\n# maxRadius=5\nmaxRadiusFar=9\n  maxRadius = 1000.0  \nremoveOutlines=true\n";
            string apuText = "; AreaLootingRadius: Collection radius; 100 is about one metre\r\n\r\nAreaLootingRadius=500\r\nAreaLootingAreaAware=true\r\n";
            File.WriteAllBytes(fnp, latin1.GetBytes(fnpText));
            File.WriteAllBytes(apu, latin1.GetBytes(apuText));
            GameStart.GameRuns = () => runs;
            Dictionary<string, object> values(bool on, bool hl, double hm, bool loot, double lm) => new(StringComparer.Ordinal)
                { ["Enabled"] = on, ["SetHighlight"] = hl, ["HighlightMeters"] = hm, ["SetLoot"] = loot, ["LootMeters"] = lm };

            var (at, length) = OtherMods.Find(fnpText, "maxRadius");
            var (a2, l2) = OtherMods.Find(apuText, "AreaLootingRadius");
            r.Check(at > 0 && fnpText.Substring(at, length) == "1000.0" && apuText.Substring(a2, l2) == "500"
                && OtherMods.Find(fnpText, "nothing").At == -1 && OtherMods.Find("key=", "key") == (4, 0),
                "the value of a key: not in a comment, not a longer key, spaces and a CR at the end left out; a key that is not there; an empty value");

            r.Check(OtherMods.Apply(mods, values(true, false, 15, false, 7.5), true) == ("", false) && OtherMods.Note(mods, values(true, false, 15, false, 7.5), true) == ""
                && latin1.GetString(File.ReadAllBytes(fnp)) == fnpText, "both switches off: nothing to say, the files left as they are");
            r.Check(OtherMods.Note(mods, values(true, true, 15, true, 7.5), true) == "FocusNearbyPickups still has maxRadius = 1000.0: Save with the game closed.\nG1R_AutoPickUpItemNative still has AreaLootingRadius = 500: Save with the game closed.",
                "switched on with other numbers: the page says what each file still reads");
            runs = true;
            var (t1, w1) = OtherMods.Apply(mods, values(true, true, 15, true, 7.5), true);
            r.Check(w1 && t1 == "FocusNearbyPickups not changed while the game runs: Save again once it is closed. G1R_AutoPickUpItemNative not changed while the game runs: Save again once it is closed."
                && latin1.GetString(File.ReadAllBytes(fnp)) == fnpText, "while the game runs: nothing written, said");
            runs = false;
            var (t2, w2) = OtherMods.Apply(mods, values(true, true, 15, true, 7.5), true);
            r.Check(!w2 && t2 == "FocusNearbyPickups: maxRadius = 1500.0 from the next start. G1R_AutoPickUpItemNative: AreaLootingRadius = 750 from the next start."
                && latin1.GetString(File.ReadAllBytes(fnp)) == fnpText.Replace("1000.0", "1500.0") && latin1.GetString(File.ReadAllBytes(apu)) == apuText.Replace("=500", "=750")
                && latin1.GetString(File.ReadAllBytes(fnp + OtherMods.BackupSuffix)) == fnpText && latin1.GetString(File.ReadAllBytes(apu + OtherMods.BackupSuffix)) == apuText,
                "game closed: exactly the value of the one line changes (its spaces, the CRLF of the other file stay); the first versions are kept as .before-G1R_MegaMod");
            r.Check(Directory.GetFiles(Path.GetDirectoryName(fnp)!).Length == 2 && Directory.GetFiles(Path.GetDirectoryName(apu)!).Length == 2,
                "nothing else is left in the mods' folders (no .tmp, no .bak)");
            r.Check(OtherMods.Apply(mods, values(true, true, 15, true, 7.5), true) == ("", false) && OtherMods.Note(mods, values(true, true, 15, true, 7.5), true) == "",
                "saved again: nothing to do, nothing to say");
            OtherMods.Apply(mods, values(true, true, 0, true, 30), true);
            r.Check(latin1.GetString(File.ReadAllBytes(fnp + OtherMods.BackupSuffix)) == fnpText && latin1.GetString(File.ReadAllBytes(fnp)).Contains("maxRadius = 0.0  \n", StringComparison.Ordinal)
                && latin1.GetString(File.ReadAllBytes(apu)).Contains("AreaLootingRadius=3000\r\n", StringComparison.Ordinal), "other numbers: written again; the backup stays the first version");
            File.WriteAllBytes(apu, latin1.GetBytes("AreaLootingRadius=3000.0\n"));
            r.Check(OtherMods.Apply(mods, values(true, false, 0, true, 30), true) == ("", false), "a number written another way that is the same (3000.0 for 3000): left as it is");
            byte[] before = File.ReadAllBytes(fnp);
            r.Check(OtherMods.Apply(mods, values(true, false, 12, false, 3), true) == ("", false) && OtherMods.Apply(mods, values(false, true, 12, true, 3), true) == ("", false)
                && OtherMods.Apply(mods, values(true, true, 12, true, 3), false) == ("", false) && File.ReadAllBytes(fnp).SequenceEqual(before),
                "a switch off, the module off, the module not loaded: the files are left alone");
            r.Check(OtherMods.Apply(null, values(true, true, 12, true, 3), true) == ("", false) && OtherMods.Note(null, values(true, true, 12, true, 3), true) == "", "no megamod: nothing");
            File.Delete(apu);
            File.WriteAllBytes(fnp, latin1.GetBytes("toggleKey=F6\n"));
            var (t3, w3) = OtherMods.Apply(mods, values(true, true, 12, true, 3), true);
            r.Check(w3 && t3 == "FocusNearbyPickups: maxRadius is not in its settings file - not written. G1R_AutoPickUpItemNative: its settings file is not there - not written."
                && OtherMods.Note(mods, values(true, true, 12, true, 3), true) == "FocusNearbyPickups: maxRadius is not in its settings file.\nG1R_AutoPickUpItemNative: its settings file is not there."
                && latin1.GetString(File.ReadAllBytes(fnp)) == "toggleKey=F6\n" && !File.Exists(apu), "a file without the key, a file that is not there: said, nothing written or made");
            r.Check(OtherMods.ModsFolder(null) == null, "the Mods folder of no megamod: none");
        }
        catch (Exception ex)
        {
            r.Check(false, "exception (other mods' files): " + ex);
        }
        finally
        {
            GameStart.GameRuns = keptRuns;
            DeleteTree(mods);
        }
    }

#if !FILETESTS
    // The window with a megamod that has the module "intro": the setting on the page, Save, Game.ini, the note.
    private const string IntroSchema =
        "local Schema = {}\nSchema.Module = \"intro\"\nSchema.Page = \"Game start\"\nSchema.PageOrder = 90\n"
        + "Schema.Header = { \"Game start\" }\nSchema.Notes = { \"Notes.\" }\n"
        + "Schema.Groups = {\n    { Title = \"What plays at the start\", Items = {\n"
        + "        { Key = \"Enabled\", Kind = \"bool\", Default = true, Label = \"Game start\" },\n"
        + "        { Key = \"SkipLogos\", Kind = \"bool\", Default = false, Needs = \"Enabled\", Label = \"Skip the logos when the game starts\" },\n"
        + "        { Key = \"SkipNewGameFilm\", Kind = \"bool\", Default = false, Needs = \"Enabled\", Label = \"Skip the film of a new game\" },\n"
        + "    } },\n}\nreturn Schema\n";

    private static void GameStartUiChecks(Report r, string configPath, string dir)
    {
        string keptPath = GameStart.IniPath;
        var keptRuns = GameStart.GameRuns;
        bool runs = false;
        string root = Path.Combine(dir, "gamestart-mega");
        try
        {
            DeleteTree(root);
            string cfg = CopyRepopulateFiles(configPath, Path.Combine(root, "modules", "repopulate", "Scripts"));
            Directory.CreateDirectory(Path.Combine(root, "Scripts"));
            string scripts = Path.Combine(root, "modules", GameStart.Module, "Scripts");
            Directory.CreateDirectory(scripts);
            WriteByteText(Path.Combine(scripts, "schema.lua"), IntroSchema);
            WriteByteText(Path.Combine(scripts, "config.lua"), ModuleSchema.FromText(IntroSchema).DefaultText());
            string ini = Path.Combine(dir, "gamestart-ui", "Game.ini");
            if (File.Exists(ini)) File.Delete(ini);
            GameStart.IniPath = ini;
            GameStart.GameRuns = () => runs;
            using var form = new MainForm(cfg, testMode: true);
            form.ShowForTest();
            var g = form.Generic;
            var box = g.Find(GameStart.Module, "SkipLogos")?.Input as XpCheckBox ?? throw new InvalidOperationException("the page has no box for SkipLogos");
            var tab = form.Nav.Find("Interface/Game start") ?? throw new InvalidOperationException("there is no tab Interface/Game start: " + form.Nav.Describe());
            var module = g.Modules.First(m => m.Name == GameStart.Module);
            Label NoteLabel() => g.PageOf(tab)!.FileNotes[module];
            r.Check(!box.Checked && NoteLabel().Text == "" && !form.StatusText.Contains("Game.ini", StringComparison.Ordinal),
                "the module intro on its tab Interface > Game start: the logos are not skipped, nothing to say about Game.ini");
            box.Checked = true;
            runs = true;
            bool saved = form.SaveFile();
            r.Check(saved && !File.Exists(ini) && form.StatusText.Contains("Game.ini not changed while the game runs", StringComparison.Ordinal)
                && NoteLabel().Text == "Game.ini: logos not skipped yet. Save with the game closed.",
                "saved while the game runs: config.lua is written, Game.ini is not; the status line and the tab say so (" + form.StatusText + ")");
            runs = false;
            saved = form.SaveFile();
            r.Check(saved && GameStart.Read(ini).Ours && form.StatusText.Contains("Game.ini: logos skipped from the next start.", StringComparison.Ordinal)
                && NoteLabel().Text == "", "saved again with the game closed: Game.ini gets the app's lines; the note on the tab is gone (" + form.StatusText + ")");
            box.Checked = false;
            saved = form.SaveFile();
            r.Check(saved && !File.Exists(ini) && form.StatusText.Contains("logos play again from the next start", StringComparison.Ordinal),
                "switched off and saved: the lines are taken out (" + form.StatusText + ")");
            var enabled = g.Find(GameStart.Module, "Enabled")?.Input as XpCheckBox ?? throw new InvalidOperationException("the page has no box for Enabled");
            box.Checked = true;
            enabled.Checked = false;
            form.SaveFile();
            r.Check(!File.Exists(ini) && !form.StatusText.Contains("Game.ini", StringComparison.Ordinal), "the whole part switched off: the logos are not skipped, nothing written");
            form.Close();
        }
        catch (Exception ex)
        {
            r.Check(false, "exception (Game.ini in the window): " + ex);
        }
        finally
        {
            GameStart.IniPath = keptPath;
            GameStart.GameRuns = keptRuns;
        }
    }
#endif
}
