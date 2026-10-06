using System.Diagnostics;
using System.Text;

namespace G1RRepopulateSettings;

/// <summary>
/// The module "intro" of the megamod: skipping the logos at the start of the game. The logos are the start list of
/// the game's loading screen plugin (StartupLoadingScreen in the game's packed DefaultGame.ini); the game reads the
/// player's Game.ini (...\AppData\Local\G1R\Saved\Config\Windows) on top of the packed files. The app writes that key
/// there - the packed value with only the three logos left out (StartupLoadingScreen.txt) - between two comment
/// lines of its own, when it saves with the game closed, and takes exactly those lines out again when the setting
/// is off. Nothing else of the file changes: its bytes stay as they are. The first version of a file the app
/// changes is kept next to it (Game.ini.before-G1R_MegaMod). The mod itself only reads the file (dev/facts/intro.md
/// of the mod, IN1 - IN3).
/// </summary>
internal static class GameStart
{
    public const string Module = "intro";
    public const string Begin = "; ---- G1R_MegaMod: skip the logos at game start (begin) ----";
    public const string End = "; ---- G1R_MegaMod: skip the logos at game start (end) ----";
    public const string Section = "[/Script/AsyncLoadingScreen.LoadingScreenSettings]";
    public const string Key = "StartupLoadingScreen";
    public const string BackupSuffix = ".before-G1R_MegaMod";

    /// <summary>Where Game.ini is (the tests put it elsewhere).</summary>
    internal static string IniPath = DefaultPath();

    /// <summary>Whether the game runs (the tests answer it themselves).</summary>
    internal static Func<bool> GameRuns = GameProcessRuns;

    public static string DefaultPath()
    {
        try { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "G1R", "Saved", "Config", "Windows", "Game.ini"); }
        catch { return ""; }
    }

    // The game's program (G1R-Win64-Shipping.exe), or the small starter some shops put in front of it (G1R.exe).
    private static bool GameProcessRuns()
    {
        foreach (string name in new[] { "G1R-Win64-Shipping", "G1R" })
        {
            try
            {
                var found = Process.GetProcessesByName(name);
                bool any = found.Length > 0;
                foreach (var p in found) p.Dispose();
                if (any) return true;
            }
            catch { return true; }      // (when it cannot be told, the file is not touched)
        }
        return false;
    }

    /// <summary>The value of the key: the game's own, with only the three logos left out (an embedded file of the app).</summary>
    public static string Value => AppSchemas.Resource("StartupLoadingScreen");

    /// <summary>What Game.ini says.</summary>
    internal sealed class Look
    {
        public bool Exists;
        /// <summary>The app's lines are there.</summary>
        public bool Ours;
        /// <summary>The key is set in the plugin's section outside the app's lines (by the player or another tool).</summary>
        public bool Theirs;
        /// <summary>Why the file could not be read; null = it could.</summary>
        public string? Problem;
        // the file as text that gives its bytes back unchanged, and how
        public string Text = "";
        public bool Utf16;
        public string Mark = "";        // the byte order mark the file starts with ("" = none)
    }

    private static readonly Encoding Latin1 = Encoding.Latin1;

    /// <summary>Reads Game.ini. Never throws.</summary>
    public static Look Read(string path)
    {
        var look = new Look();
        try
        {
            if (!File.Exists(path)) return look;
            look.Exists = true;
            byte[] bytes = File.ReadAllBytes(path);
            if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
            {
                look.Utf16 = true;
                look.Mark = "﻿";
                look.Text = Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
            }
            else if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            {
                look.Mark = "ï»¿";
                look.Text = Latin1.GetString(bytes, 3, bytes.Length - 3);
            }
            else look.Text = Latin1.GetString(bytes);
            var lines = Lines(look.Text);
            var (begin, end) = Block(lines);
            look.Ours = begin >= 0;
            string section = "";
            for (int i = 0; i < lines.Count; i++)
            {
                string line = lines[i].Trim();
                if (line.StartsWith('[') && line.EndsWith(']')) { section = line; continue; }
                if (begin >= 0 && i >= begin && i <= end) continue;
                if (!string.Equals(section, Section, StringComparison.OrdinalIgnoreCase)) continue;
                int eq = line.IndexOf('=');
                if (eq <= 0 || line.StartsWith(';')) continue;
                string key = line[..eq].Trim().TrimStart('+', '-', '.', '!');
                if (string.Equals(key, Key, StringComparison.OrdinalIgnoreCase)) look.Theirs = true;
            }
        }
        catch (Exception ex) { look.Problem = ex.Message; }
        return look;
    }

    // The lines of a text, each with its line end.
    private static List<string> Lines(string text)
    {
        var lines = new List<string>();
        int from = 0;
        while (from < text.Length)
        {
            int at = text.IndexOf('\n', from);
            if (at < 0) { lines.Add(text[from..]); break; }
            lines.Add(text[from..(at + 1)]);
            from = at + 1;
        }
        return lines;
    }

    // The app's lines: the first End line that has a Begin line in front of it, and the last such Begin line;
    // (-1, -1) when there are none. (A Begin or End line left alone by a hand never takes other lines with it.)
    private static (int Begin, int End) Block(List<string> lines)
    {
        int begin = -1;
        for (int i = 0; i < lines.Count; i++)
        {
            string line = lines[i].Trim();
            if (line == Begin) begin = i;
            else if (line == End && begin >= 0) return (begin, i);
        }
        return (-1, -1);
    }

    private static byte[] Bytes(Look look, string text) =>
        look.Utf16 ? Encoding.Unicode.GetBytes(look.Mark + text) : Latin1.GetBytes(look.Mark + text);

    /// <summary>
    /// What there is to say about Game.ini while the settings say `want` (the logos are skipped), for the page of the
    /// module and the status line: "" when the file is as it should be. Never throws.
    /// </summary>
    public static string Note(bool want)
    {
        var look = Read(IniPath);
        if (look.Problem != null) return want ? "Game.ini cannot be read (" + look.Problem + "): whether the logos are skipped is not known." : "";
        if (want && look.Theirs) return "Game.ini sets the start screen of the game itself (not through this app): it is left as it is, and the logos may still play.";
        if (want && !look.Ours) return "Game.ini does not skip the logos yet: press Save with the game closed.";
        if (!want && look.Ours) return "Game.ini still skips the logos: press Save with the game closed to take that out.";
        return "";
    }

    /// <summary>
    /// Brings Game.ini in line with the settings (want: the logos are skipped). Returns what there is to say on the
    /// status line ("" when nothing had to change) and whether it is a warning. Never throws.
    /// </summary>
    public static (string Text, bool Warn) Apply(bool want)
    {
        string path = IniPath;
        var look = Read(path);
        if (look.Problem != null) return want ? ("Game.ini could not be read: " + look.Problem + ".", true) : ("", false);
        if (want == look.Ours)
            return want && look.Theirs ? ("Game.ini sets the start screen of the game itself as well (not through this app): the logos may still play.", true) : ("", false);
        if (want && look.Theirs) return ("Game.ini sets the start screen of the game itself (not through this app): it is left as it is.", true);
        if (GameRuns()) return ("Game.ini is not changed while the game runs: press Save again once it is closed (the logos count from the next start of the game).", true);
        try
        {
            // the first change of a file the app did not make: that file is kept beside it
            if (want && look.Exists && !File.Exists(path + BackupSuffix)) File.Copy(path, path + BackupSuffix);
            string text;
            if (want)
            {
                string nl = look.Text.Contains("\r\n") || !look.Text.Contains('\n') ? "\r\n" : "\n";
                text = look.Text + (look.Text.Length > 0 && !look.Text.EndsWith('\n') ? nl : "")
                    + Begin + nl + Section + nl + Key + "=" + Value + nl + End + nl;
            }
            else
            {
                var lines = Lines(look.Text);
                var (begin, end) = Block(lines);
                lines.RemoveRange(begin, end - begin + 1);
                text = string.Concat(lines);
            }
            if (!want && text.Length == 0 && !File.Exists(path + BackupSuffix))
            {
                // the file held nothing but the app's lines: it goes, as it was before the app wrote it
                File.Delete(path);
            }
            else
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                SettingsFile.WriteBytes(path, Bytes(look, text));
            }
            var back = Read(path);
            if (back.Problem != null || back.Ours != want) return ("Game.ini was written, but it does not read back as it should.", true);
            return want ? ("Game.ini: the logos are skipped from the next start of the game.", false)
                : ("Game.ini: the app's lines are taken out, the logos play again from the next start of the game.", false);
        }
        catch (Exception ex)
        {
            return ("Game.ini could not be written: " + ex.Message, true);
        }
    }
}
