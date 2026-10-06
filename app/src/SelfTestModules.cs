using System.Globalization;
using System.IO.Compression;
using System.Text;

namespace G1RRepopulateSettings;

// Tests of the generic part: the settings of the modules that describe them in a schema.lua.
// What the game's own code (Scripts/core/settings.lua, kit.lua) gives for the same inputs comes
// from the embedded fixtures, written by filetests/gen_fixtures.sh.
internal static partial class SelfTest
{
    // =====================================================================
    // fixtures
    // =====================================================================
    /// <summary>The records of the fixture file: fields of byte text, null = nothing (nil, no file).</summary>
    internal sealed class Fixtures
    {
        public readonly List<string?[]> Records = new();
        public IEnumerable<string?[]> Of(string kind) => Records.Where(r => r[0] == kind);

        /// <summary>The embedded fixture file as byte text.</summary>
        public static string EmbeddedText()
        {
            using var raw = typeof(SelfTest).Assembly.GetManifestResourceStream("SelfTestFixtures")
                ?? throw new InvalidOperationException("the fixtures are not in this build (SelfTestFixtures.txt.gz)");
            using var unzip = new GZipStream(raw, CompressionMode.Decompress);
            using var buffer = new MemoryStream();
            unzip.CopyTo(buffer);
            return ByteText.FromBytes(buffer.ToArray());
        }

        public static Fixtures Parse(string byteText)
        {
            var f = new Fixtures();
            foreach (string line in byteText.Split('\n'))
            {
                if (line.Length == 0 || line[0] == '#') continue;
                f.Records.Add(line.Split('\t').Select(Unescape).ToArray());
            }
            return f;
        }

        public static string? Unescape(string field)
        {
            if (field == "\\N") return null;
            if (!field.Contains('\\')) return field;
            var sb = new StringBuilder(field.Length);
            for (int i = 0; i < field.Length; i++)
            {
                char c = field[i];
                if (c != '\\') { sb.Append(c); continue; }
                char e = field[++i];
                if (e == 't') sb.Append('\t');
                else if (e == 'n') sb.Append('\n');
                else if (e == 'r') sb.Append('\r');
                else if (e == 'x') { sb.Append((char)int.Parse(field.AsSpan(i + 1, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture)); i += 2; }
                else sb.Append(e);
            }
            return sb.ToString();
        }

        /// <summary>The same escapes, for a case file a Lua script reads (filetests --live).</summary>
        public static string Escape(string? field)
        {
            if (field == null) return "\\N";
            var sb = new StringBuilder(field.Length + 8);
            foreach (char c in field)
            {
                if (c == '\\') sb.Append("\\\\");
                else if (c == '\t') sb.Append("\\t");
                else if (c == '\n') sb.Append("\\n");
                else if (c == '\r') sb.Append("\\r");
                else if (c < 32 || c > 126) sb.Append("\\x").Append(((int)c).ToString("X2", CultureInfo.InvariantCulture));
                else sb.Append(c);
            }
            return sb.ToString();
        }
    }

    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    // "b:true", "n:2.5", "s:text" -> the value
    internal static object TypedValue(string token)
    {
        if (token.StartsWith("b:", StringComparison.Ordinal)) return token == "b:true";
        if (token.StartsWith("n:", StringComparison.Ordinal))
        {
            string n = token[2..];
            if (n == "inf") return double.PositiveInfinity;
            if (n == "-inf") return double.NegativeInfinity;
            if (n.EndsWith("nan", StringComparison.Ordinal)) return double.NaN;
            return double.Parse(n, NumberStyles.Float, Inv);
        }
        return token[2..];
    }

    internal static string TypedText(object? v) => v switch
    {
        bool b => b ? "b:true" : "b:false",
        double d => "n:" + d.ToString("R", Inv),
        string s => "s:" + s,
        _ => "?",
    };

    // a text for a report line: on one line, not too long
    private static string Short(string? s, int max = 70)
    {
        if (s == null) return "(nothing)";
        s = Fixtures.Escape(s);
        return s.Length <= max ? s : s[..max] + "...";
    }

    // One line for a whole list of cases: how many, and the first ones that are wrong.
    private static void Cases(Report r, int count, List<string> wrong, string what)
    {
        r.Check(wrong.Count == 0 && count > 0, $"{count} {what}" + (wrong.Count > 0 ? $" - {wrong.Count} wrong: " + string.Join(" | ", wrong.Take(4)) : ""));
    }

    private static byte[]? BytesOf(string path) => File.Exists(path) ? File.ReadAllBytes(path) : null;
    private static string? ByteTextOf(string path) => File.Exists(path) ? ByteText.FromBytes(File.ReadAllBytes(path)) : null;

    private static void WriteByteText(string path, string? byteText)
    {
        if (byteText == null) File.Delete(path);
        else File.WriteAllBytes(path, ByteText.ToBytes(byteText));
    }

    // A module folder for a test: <dir>\<name>\Scripts with schema.lua and config.lua (null = none); old .bak / .tmp removed.
    private static ModuleSettings TestModule(string dir, string name, string schemaText, string? configText)
    {
        string scripts = Path.Combine(dir, name, "Scripts");
        Directory.CreateDirectory(scripts);
        WriteByteText(Path.Combine(scripts, "schema.lua"), schemaText);
        WriteByteText(Path.Combine(scripts, "config.lua"), configText);
        File.Delete(Path.Combine(scripts, "config.lua.bak"));
        File.Delete(Path.Combine(scripts, "config.lua.tmp"));
        var m = new ModuleSettings(name, scripts);
        m.ReadSchema();
        m.Load();
        return m;
    }

    private static void DeleteTree(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir, true); } catch { }
    }

    // =====================================================================
    // the checks (everything but the window)
    // =====================================================================
    private static void ModuleChecks(Report r, string reportPath)
    {
        string dir = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(reportPath)) ?? ".", "selftest-modules");
        r.Info("settings of the modules (schema.lua / config.lua), compared with what the game's settings service gives:");
        Fixtures fx;
        var schemas = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            fx = Fixtures.Parse(Fixtures.EmbeddedText());
            foreach (var rec in fx.Of("schema")) if (rec[3] == "ok") schemas[rec[1]!] = rec[2]!;
            foreach (var rec in fx.Of("real")) schemas[rec[1]!] = rec[2]!;
            r.Check(fx.Records.Count > 500 && schemas.ContainsKey("A") && schemas.ContainsKey("allkinds") && schemas.ContainsKey("xp") && schemas.ContainsKey("general"),
                $"fixtures read: {fx.Records.Count} records");
        }
        catch (Exception ex)
        {
            r.Check(false, "the fixtures could not be read: " + ex.Message);
            return;
        }
        DeleteTree(dir);
        void run(string what, Action a)
        {
            try { a(); }
            catch (Exception ex) { r.Check(false, $"exception ({what}): " + ex); }
        }
        run("plain Lua", () => PlainLuaChecks(r));
        run("numbers", () => NumberChecks(r, fx));
        run("keys", () => KeyChecks(r, fx));
        run("schemas", () => SchemaChecks(r, fx, schemas));
        run("patch", () => PatchChecks(r, fx));
        run("reading", () => ReadChecks(r, fx, schemas, dir));
        run("changing", () => ApplyChecks(r, fx, schemas, dir));
        run("saving", () => SaveChecks(r, schemas, dir));
        run("finding", () => FindChecks(r, fx, schemas, dir));
        run("presets", () => PresetChecks(r, schemas));
        run("the way of the UI test", () => WalkChecks(r, fx, dir));
        run("the map pins", () => MapPinChecks(r, dir));
        DeleteTree(dir);
    }

    // ------------------------------------------------------------------ the reader of plain Lua
    private static string? LuaError(string text, bool schema = false)
    {
        try { LuaPlain.Run(text, hashLine: schema, noNil: schema); return null; }
        catch (LuaPlainException ex) { return ex.Message; }
    }

    private static void PlainLuaChecks(Report r)
    {
        r.Check(LuaPlain.Run("local t = { 1, 'two', three = 3 }\nreturn t") is PlainTable t && t.Get(1L) is long one && one == 1 && (string?)t.Get(2L) == "two"
            && t["three"] is long three && three == 3 && t.Get(3L) == null && t.Sequence().Count == 2,
            "plain Lua: a table with entries and fields; whole numbers stay whole numbers");
        r.Check(LuaPlain.Run("return 3") is long && LuaPlain.Run("return 3.0") is double && LuaPlain.Run("return 0x10") is long h && h == 16
            && LuaPlain.Run("return 9223372036854775808") is double big && big == 9223372036854775808.0 && LuaPlain.Run("return 0xffffffffffffffff") is long m1 && m1 == -1
            && LuaPlain.Run("return -0x10") is long nh && nh == -16 && LuaPlain.Run("return 1e2") is double e2 && e2 == 100 && LuaPlain.Run("return .5") is double half && half == 0.5
            && LuaPlain.Run("return 0x.8p1") is double hf && hf == 1.0 && LuaPlain.Run("return 0xA.8p0") is double hf2 && hf2 == 10.5 && LuaPlain.Run("return 1e999") is double inf && double.IsPositiveInfinity(inf),
            "plain Lua: numbers as Lua reads them (3 whole, 3.0 float, hexadecimal, too large for 64 bits = float, exponent, hexadecimal fraction, 1e999 = infinity)");
        r.Check((string?)LuaPlain.Run("return \"a\\tb\\n\\65\\x42\\u{43}\\z   \n  D\\\\\\\"\"") == "a\tb\nABCD\\\"" && (string?)LuaPlain.Run("return [[\nline 1\r\nline 2]]") == "line 1\nline 2"
            && (string?)LuaPlain.Run("return [==[a]]b]=]c]==]") == "a]]b]=]c" && (string?)LuaPlain.Run("return 'it''s'" .Replace("''", "\\'")) == "it's"
            && (string?)LuaPlain.Run("return \"\\u{20AC}\"") == "\u00E2\u0082\u00AC",
            "plain Lua: texts with Lua's escapes, long brackets (first line break skipped, line ends as \\n), \\u{20AC} as its UTF-8 bytes");
        string[] wrong =
        {
            "return 1 + 1", "return 'a' .. 'b'", "return (1)", "return not true", "return f()", "return #'x'", "local function f() end return {}", "if true then end return {}",
            "return function() end", "return 1 == 1", "return - -1", "return {} .. {}", "x = 'a' 'b' return {}", "return 2 ^ 2", "return 1 < 2", "return ('x'):rep(2)",
        };
        var notRefused = wrong.Where(w => LuaError(w) == null).ToList();
        r.Check(notRefused.Count == 0, $"plain Lua: {wrong.Length} texts with arithmetic, joined texts, calls, functions, control structures are refused" + (notRefused.Count > 0 ? ": " + string.Join(" | ", notRefused) : ""));
        string? e3 = LuaError("local Config = {}\n-- a comment\nConfig.A = = 1\nreturn Config\n");
        string? e5 = LuaError("local Config = {}\r\n--[[ a\r\nlong comment ]]\r\nConfig.A = [[x\r\ny]]\r\nConfig.B = \r\nreturn Config\r\n");
        string? eCr = LuaError("local Config = {}\rConfig.A = 1 +\rreturn Config\r");
        r.Check(e3 != null && e3.StartsWith("line 3:", StringComparison.Ordinal) && e5 != null && e5.StartsWith("line 7:", StringComparison.Ordinal) && eCr != null && eCr.StartsWith("line 2:", StringComparison.Ordinal),
            $"plain Lua: an error names its line, whatever the line ends are (\\n, \\r\\n, \\r): \"{e3}\", \"{e5}\", \"{eCr}\"");
        r.Check(LuaError("return nil") == null && LuaError("return nil", schema: true) != null && LuaError("#!first line\nreturn {}") != null && LuaError("#!first line\nreturn {}", schema: true) == null
            && LuaError(ByteText.Bom + "return {}") == null, "plain Lua: a schema holds no nil; a first line with # is skipped for a schema only; a byte order mark is skipped");
        string deep = new string('{', 300) + new string('}', 300);
        r.Check(LuaError("return " + deep) is string tooDeep && tooDeep.Contains("nested too deeply") && LuaError("return " + new string('{', 150) + new string('}', 150)) == null,
            "plain Lua: tables nested 300 deep are refused (no stack overflow), 150 deep are read");
        (double Value, string Text)[] shown =
        {
            (5.0, "5.0"), (2.5, "2.5"), (1e100, "1e+100"), (1.0 / 3, "0.33333333333333"), (-0.0, "-0.0"), (1e15, "1e+15"), (1e14, "1e+14"), (123456.789, "123456.789"),
            (1e-5, "1e-05"), (0.0001, "0.0001"), (-2.5e-10, "-2.5e-10"), (100, "100.0"), (double.PositiveInfinity, "inf"), (double.NegativeInfinity, "-inf"),
        };
        var badText = shown.Where(s => LuaPlain.ToText(s.Value) != s.Text).Select(s => s.Text + " comes as " + LuaPlain.ToText(s.Value)).ToList();
        r.Check(badText.Count == 0 && LuaPlain.ToText(5L) == "5" && LuaPlain.ToText(true) == "true" && LuaPlain.ToText(null) == "nil",
            "plain Lua: numbers are printed as Lua prints them (5, 5.0, 1e+100, 0.33333333333333)" + (badText.Count > 0 ? ": " + string.Join("; ", badText) : ""));
        (string Text, double? Value)[] numbers =
        {
            ("5.", 5), (".5", 0.5), (" 3 ", 3), ("0x10", 16), ("1e2", 100), ("+5", 5), ("-5", -5), ("- 5", null), ("", null), (" ", null), ("0x", null), ("inf", null), ("nan", null),
            ("5,5", null), ("0x1p4", 16), ("1e", null), ("3 4", null), ("\t3\n", 3), ("abc", null), ("0x1P-1", 0.5), ("1E+2", 100), ("--5", null), ("5e", null), (".", null), ("0X1F", 31),
        };
        var badNumber = numbers.Where(n => LuaPlain.TextToNumber(n.Text) != n.Value).Select(n => "\"" + Short(n.Text) + "\"").ToList();
        r.Check(badNumber.Count == 0, $"plain Lua: {numbers.Length} texts as numbers, the way Lua's tonumber takes them" + (badNumber.Count > 0 ? " - wrong: " + string.Join(", ", badNumber) : ""));
    }

    // ------------------------------------------------------------------ numbers
    // The records of one kind against what the app's code gives: the number of records, and what is wrong.
    internal static int CompareNumbers(Fixtures fx, List<string> wrong)
    {
        int n = 0;
        foreach (var rec in fx.Of("number"))
        {
            n++;
            double v = (double)TypedValue("n:" + rec[1]);
            int decimals = int.Parse(rec[2]!, Inv);
            string got = SettingsRules.NumberText(v, decimals);
            if (got != rec[3]) wrong.Add($"{rec[1]} with {decimals} places gives {got}, not {rec[3]}");
        }
        return n;
    }

    private static void NumberChecks(Report r, Fixtures fx)
    {
        var wrong = new List<string>();
        int n = CompareNumbers(fx, wrong);
        Cases(r, n, wrong, "numbers are written as the game writes them (whole ones plain and rounded half up, others with at least one and at most the given places, exact ties to the even digit)");

        var culture = CultureInfo.CurrentCulture;
        try
        {
            // what is written must not depend on the PC's number format: a culture with a decimal comma
            var comma = (CultureInfo)CultureInfo.InvariantCulture.Clone();
            comma.NumberFormat.NumberDecimalSeparator = ",";
            comma.NumberFormat.NumberGroupSeparator = ".";
            CultureInfo.CurrentCulture = comma;
            bool commaInUse = 2.5.ToString() == "2,5";
            r.Check(commaInUse && SettingsRules.NumberText(2.5, 2) == "2.5" && SettingsRules.NumberText(1234.5, 1) == "1234.5" && SettingsRules.NumberText(1000000, 0) == "1000000"
                && LuaPlain.TextToNumber("2.5") == 2.5 && LuaPlain.Run("return 2.5") is double d && d == 2.5 && LuaPlain.ToText(2.5) == "2.5",
                "numbers are read and written with a point on a PC with a decimal comma too");
        }
        finally { CultureInfo.CurrentCulture = culture; }
    }

    // ------------------------------------------------------------------ keys
    // dev/SETTINGS.md section 6, typed from the document: the names UE4SS uses with their virtual-key codes
    private static List<(string Name, int Code)> DocumentedKeys()
    {
        var list = new List<(string, int)>();
        for (int i = 0; i < 26; i++) list.Add((((char)('A' + i)).ToString(), 0x41 + i));
        string[] digits = { "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE" };
        for (int i = 0; i < 10; i++) { list.Add((digits[i], 0x30 + i)); list.Add(("NUM_" + digits[i], 0x60 + i)); }
        for (int i = 1; i <= 12; i++) list.Add(("F" + i.ToString(Inv), 0x70 + i - 1));
        list.AddRange(new (string, int)[]
        {
            ("BACKSPACE", 0x08), ("TAB", 0x09), ("RETURN", 0x0D), ("PAUSE", 0x13), ("CAPS_LOCK", 0x14), ("SPACE", 0x20),
            ("PAGE_UP", 0x21), ("PAGE_DOWN", 0x22), ("END", 0x23), ("HOME", 0x24), ("INS", 0x2D), ("DEL", 0x2E),
            ("LEFT_ARROW", 0x25), ("UP_ARROW", 0x26), ("RIGHT_ARROW", 0x27), ("DOWN_ARROW", 0x28),
            ("MULTIPLY", 0x6A), ("ADD", 0x6B), ("SUBTRACT", 0x6D), ("DECIMAL", 0x6E), ("DIVIDE", 0x6F), ("NUM_LOCK", 0x90), ("SCROLL_LOCK", 0x91),
            ("MIDDLE_MOUSE_BUTTON", 0x04), ("XBUTTON_ONE", 0x05), ("XBUTTON_TWO", 0x06),
            ("OEM_ONE", 0xBA), ("OEM_PLUS", 0xBB), ("OEM_COMMA", 0xBC), ("OEM_MINUS", 0xBD), ("OEM_PERIOD", 0xBE), ("OEM_TWO", 0xBF), ("OEM_THREE", 0xC0),
            ("OEM_FOUR", 0xDB), ("OEM_FIVE", 0xDC), ("OEM_SIX", 0xDD), ("OEM_SEVEN", 0xDE), ("OEM_EIGHT", 0xDF), ("OEM_102", 0xE2),
        });
        return list;
    }

    internal static int CompareKeys(Fixtures fx, List<string> wrong)
    {
        int n = 0;
        foreach (var rec in fx.Of("key"))
        {
            n++;
            string text = rec[1] ?? "";
            string? usual = KeyNames.Combo(text, out int code, out var modifiers);
            string codeText = usual != null && usual.Length > 0 ? code.ToString(Inv) : "";
            string modifierText = string.Join(",", modifiers.Select(m => m.ToString(Inv)));
            if (usual != rec[2] || codeText != (rec[3] ?? "") || modifierText != (rec[4] ?? ""))
                wrong.Add($"\"{Short(text)}\" gives {usual ?? "nothing"} {codeText} [{modifierText}], not {rec[2] ?? "nothing"} {rec[3]} [{rec[4]}]");
        }
        return n;
    }

    private static void KeyChecks(Report r, Fixtures fx)
    {
        var wrong = new List<string>();
        int n = 0;
        var fromKit = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var rec in fx.Of("keyname"))
        {
            n++;
            string name = rec[1]!;
            int code = int.Parse(rec[2]!, Inv);
            fromKit[name] = code;
            string? usual = KeyNames.Combo(name, out int gotCode, out var modifiers);
            if (usual != name || gotCode != code || modifiers.Count != 0 || KeyNames.NameOf(code) != name) wrong.Add($"{name} ({code}): {usual} {gotCode}, name of the code: {KeyNames.NameOf(code)}");
        }
        Cases(r, n, wrong, "key names of the game's kit: each is known with its virtual-key code, and each code gives its name back");

        var documented = DocumentedKeys();
        var notAsDocumented = documented.Where(k => KeyNames.NameOf(k.Code) != k.Name || !fromKit.TryGetValue(k.Name, out int c) || c != k.Code).Select(k => k.Name).ToList();
        r.Check(notAsDocumented.Count == 0 && documented.Count == KeyNames.All.Length && documented.Count == fromKit.Count && KeyNames.All.Select(k => k.Code).Distinct().Count() == KeyNames.All.Length,
            $"the {documented.Count} key names of dev/SETTINGS.md section 6 with their codes are exactly the ones the app and the kit know" + (notAsDocumented.Count > 0 ? ": " + string.Join(", ", notAsDocumented) : ""));

        wrong = new List<string>();
        n = CompareKeys(fx, wrong);
        Cases(r, n, wrong, "spellings of key combinations give the usual one (or none) with the key's code and the modifiers' codes, as the kit's keyCombo does");

        r.Check(KeyNames.Combo("alt+shift+ctrl+f5") == "CTRL+SHIFT+ALT+F5" && KeyNames.Combo("ALT+CTRL+Y") == "CTRL+ALT+Y" && KeyNames.Combo("shift+ctrl+y") == "CTRL+SHIFT+Y"
            && KeyNames.Combo("alt + shift + y") == "SHIFT+ALT+Y" && KeyNames.Build(true, true, true, "F5") == "CTRL+SHIFT+ALT+F5" && KeyNames.Build(false, false, false, "Y") == "Y"
            && KeyNames.Build(false, true, false, "Y") == "SHIFT+Y" && KeyNames.Build(true, false, true, "Y") == "CTRL+ALT+Y",
            "modifiers are written in the order CTRL, SHIFT, ALT, in whatever order they were given");
        KeyNames.Combo("CTRL+SHIFT+ALT+Y", out int y, out var held);
        r.Check(y == 0x59 && held.SequenceEqual(new[] { 0x11, 0x10, 0x12 }) && KeyNames.Ctrl == 0x11 && KeyNames.Shift == 0x10 && KeyNames.Alt == 0x12,
            "the modifiers' codes: CTRL 0x11, SHIFT 0x10, ALT 0x12");
        int[] cannot = { 0x01, 0x02, 0x1B, 0x5B, 0x5C, 0x5D, 0x10, 0x11, 0x12, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x2C, 0x7C, 0x00, 0xFF };
        string[] noKey = { "ESC", "ESCAPE", "LEFT_MOUSE_BUTTON", "RIGHT_MOUSE_BUTTON", "MOUSE1", "MOUSE2", "LWIN", "RWIN", "WIN", "CTRL", "SHIFT", "ALT", "F13" };
        r.Check(cannot.All(c => KeyNames.NameOf(c) == null) && noKey.All(k => KeyNames.Combo(k) == null),
            "keys that cannot be bound have no name: the left and right mouse buttons, Escape, the Windows keys, the modifiers alone, F13");
    }

    // ------------------------------------------------------------------ schemas
    private static string SchemaVerdict(string text, out ModuleSchema? schema)
    {
        schema = null;
        try { schema = ModuleSchema.FromText(text); return "ok"; }
        catch (SchemaException ex) { return ex.Unreadable ? "unreadable" : ex.AppRule ? "raises" : "bad " + ex.Reason; }
    }

    internal static int CompareSchemas(Fixtures fx, List<string> wrong, out int good, out int bad, out int unreadable, SortedSet<string> reasons)
    {
        int n = 0;
        good = 0; bad = 0; unreadable = 0;
        foreach (var rec in fx.Of("schema"))
        {
            n++;
            string name = rec[1]!, text = rec[2]!, status = rec[3]!;
            string verdict = SchemaVerdict(text, out var schema);
            if (status == "ok")
            {
                good++;
                if (verdict != "ok") wrong.Add($"{name}: refused ({verdict})");
                else if (schema!.DefaultText() != rec[4]) wrong.Add($"{name}: the default text differs from the game's");
            }
            else if (status == "bad")
            {
                bad++;
                reasons.Add(rec[4]!);
                if (verdict != "bad " + rec[4]) wrong.Add($"{name}: \"{verdict}\" instead of \"bad {rec[4]}\"");
            }
            else
            {
                unreadable++;
                if (verdict != status) wrong.Add($"{name}: \"{verdict}\" instead of {status}");
            }
        }
        return n;
    }

    private static void SchemaChecks(Report r, Fixtures fx, Dictionary<string, string> schemas)
    {
        var wrong = new List<string>();
        var reasons = new SortedSet<string>(StringComparer.Ordinal);
        int n = CompareSchemas(fx, wrong, out int good, out int bad, out int unreadable, reasons);
        Cases(r, n, wrong, $"schemas: {good} usable ones give the game's default config.lua byte for byte, {bad} with one thing wrong are refused with the game's reason ({reasons.Count} different reasons), "
            + $"{unreadable} that Lua cannot run or whose Decimals the game cannot write are refused");

        wrong = new List<string>();
        n = 0;
        foreach (var rec in fx.Of("plain"))
        {
            n++;
            if (SchemaVerdict(rec[2]!, out _) != "unreadable") wrong.Add(rec[1]!);
        }
        Cases(r, n, wrong, "schemas that are valid Lua but more than plain values (arithmetic, joined texts, calls, nil, ...) are refused");

        foreach (var rec in fx.Of("real"))
        {
            string name = rec[1]!;
            string verdict = SchemaVerdict(rec[2]!, out var schema);
            string? text = schema?.DefaultText();
            r.Check(verdict == "ok" && text == rec[4] && text == rec[3],
                $"module {name}: its schema is read, and the default text made from it is the shipped config.lua and the game's Settings.defaultText, byte for byte ({text?.Length} bytes)"
                + (verdict != "ok" ? ": " + verdict : ""));
        }

        // what the page is built from
        var a = ModuleSchema.FromText(schemas["allkinds"]);
        SchemaItem item(string key) => a.ByKey[key];
        r.Check(a.Page == "All kinds" && a.PageOrder == 95 && a.Notes.Count == 2 && a.Groups.Count == 6 && a.Items.Count == 15 && a.Items[0].Key == "Enabled" && a.Items[14].Key == "Last"
            && !a.ByKey.ContainsKey("Now") && a.Groups[3].Items.Count == 3 && a.Groups[3].Items[2].Kind == ItemKind.Action && !a.Groups[3].Items[2].Shown,
            "schema with every kind: page, page order, notes, 6 groups, 15 items with a value in file order; the action has no value and is not shown");
        r.Check(a.Groups[0].Title == "Switches" && a.Groups[0].Order == 10 && a.Groups[0].Hint == "The hint of the group stands under its title." && a.Groups[4].Title == "Advanced" && a.Groups[4].Order == 100
            && a.Groups[4].Items.All(i => i.Hidden && !i.Shown) && a.Groups[5].Title == "" && a.Groups[5].Order == 200 && a.Groups[1].Hint == "",
            "groups: title, hint, Order (100 when none is given), a group without a title, a group of hidden items");
        r.Check(item("Enabled").Kind == ItemKind.Bool && (bool)item("Enabled").Default! && item("Enabled").Label == "The whole thing is on" && item("Enabled").Comment == "The switch the others need."
            && item("Feature").Needs == "Enabled" && item("Feature").Comment == "A switch that needs the first one, with a comment of two lines." && item("Plain").Label == "Plain" && item("Plain").Comment == "",
            "switches: default, label (the key when there is none), the comment as one text, Needs");
        var whole = item("Whole"); var tenth = item("Tenth"); var fine = item("Fine"); var large = item("Large");
        r.Check(whole.Kind == ItemKind.Number && (double)whole.Default! == 5 && whole.Min == -10 && whole.Max == 1000 && whole.Step == 5 && whole.Decimals == 0 && whole.Unit == "pieces"
            && (double)tenth.Default! == 1.5 && tenth.Min == 0 && tenth.Max == 10 && tenth.Step == 0.5m && tenth.Decimals == 1 && tenth.Needs == "Feature"
            && (double)fine.Default! == 0.125 && fine.Min == -1 && fine.Max == 1 && fine.Step == 0.005m && fine.Decimals == 3 && fine.Unit == ""
            && large.Max == 100000000 && large.Step == 1000 && large.Decimals == 0,
            "numbers: default, Min, Max, Step, Decimals, Unit");
        var mode = item("Mode");
        r.Check(mode.Kind == ItemKind.Choice && (string)mode.Default! == "second choice" && mode.Options.SequenceEqual(new[] { "first", "second choice", "the third and longest of the choices" })
            && mode.OptionLabels.SequenceEqual(mode.Options) && item("Greeting").Kind == ItemKind.Text && (string)item("Greeting").Default! == "say \"hi\" \\ there" && (string)item("Empty").Default! == ""
            && item("Hotkey").Kind == ItemKind.Key && (string)item("Hotkey").Default! == "CTRL+Y" && (string)item("Other").Default! == "" && item("Secret").Hidden && item("SecretText").Hidden,
            "choices with their options, texts, keys, hidden items");

        var h = ModuleSchema.FromText(schemas["hand"]);
        r.Check(h.Page == "By hand" && h.PageOrder == 16 && h.Notes.SequenceEqual(new[] { "One note" }) && h.Groups.Count == 2 && h.Groups[0].Title == "TAAAB" && h.Groups[0].Order == 15
            && h.Items.Select(i => i.Key).SequenceEqual(new[] { "A", "B", "C", "D", "E", "F" }) && (double)h.ByKey["A"].Default! == 10 && h.ByKey["A"].Min == -5 && h.ByKey["A"].Max == 32
            && h.ByKey["A"].Decimals == 1 && h.ByKey["A"].Step == 0.5m && h.ByKey["B"].Options.SequenceEqual(new[] { "x\"y", "z\\", "w" }) && h.ByKey["B"].Unit == "5"
            && h.ByKey["C"].Needs == null && (string)h.ByKey["D"].Default! == "two]] words" && !h.ByKey["D"].Hidden && h.ByKey["E"].Kind == ItemKind.Key
            && h.ByKey["F"].Decimals == 0 && h.ByKey["F"].Min == -3 && h.ByKey["F"].Max == -3,
            "a schema written in other ways (single quotes, long brackets, escapes, hexadecimal and exponent numbers, entries set one by one, a first line with #, a second return value): the same values as in the game");

        // steps and decimals the app has to make something of
        (string Fields, int Decimals, decimal Step)[] steps =
        {
            ("Decimals = 2, Step = 0.25", 2, 0.25m), ("Decimals = 2", 2, 1m), ("Step = 0.5", 0, 1m), ("Step = 2.5", 0, 3m), ("Decimals = 1, Step = 0.01", 1, 0.1m), ("Decimals = 3, Step = 0", 3, 1m),
            ("Decimals = 2, Step = -1", 2, 1m), ("Decimals = 1, Step = \"0.5\"", 1, 0.5m), ("Decimals = 1, Step = true", 1, 1m), ("Decimals = 0, Step = 10", 0, 10m), ("Decimals = \"3\"", 3, 1m),
            ("Decimals = -2, Step = 1e30", 0, 1m),
        };
        var badStep = new List<string>();
        foreach (var s in steps)
        {
            var one = ModuleSchema.FromText("return { Groups = { { Items = { { Key = \"N\", Kind = \"number\", Default = 1, Min = 0, Max = 10, " + s.Fields + " } } } } }").ByKey["N"];
            if (one.Decimals != s.Decimals || one.Step != s.Step) badStep.Add($"{s.Fields}: {one.Decimals} places, step {one.Step.ToString(Inv)}");
        }
        r.Check(badStep.Count == 0, $"{steps.Length} number items: Step is the increment when it is a usable number (rounded to the item's places, never 0), else 1" + (badStep.Count > 0 ? ": " + string.Join("; ", badStep) : ""));
        string decimals16 = SchemaVerdict("return { Groups = { { Items = { { Key = \"N\", Kind = \"number\", Default = 1, Min = 0, Max = 10, Decimals = 16 } } } } }", out _);
        r.Check(decimals16 == "raises", "more than 15 Decimals are refused by the app (a rule of its own; the game would take them): " + decimals16);
    }

    // ------------------------------------------------------------------ changing one line
    internal static int ComparePatches(Fixtures fx, List<string> wrong)
    {
        int n = 0;
        foreach (var rec in fx.Of("patch"))
        {
            n++;
            string got = SettingsRules.Patch(rec[1] ?? "", rec[2]!, rec[3]!);
            if (got != (rec[4] ?? "")) wrong.Add($"\"{Short(rec[1], 200)}\" {rec[2]} = {rec[3]} gives \"{Short(got, 200)}\", not \"{Short(rec[4], 200)}\"");
        }
        return n;
    }

    private static void PatchChecks(Report r, Fixtures fx)
    {
        var wrong = new List<string>();
        int n = ComparePatches(fx, wrong);
        Cases(r, n, wrong, "single-line changes give the game's text: first line, indentation, CRLF, commented line, key twice (the last), longer keys, where a missing line goes, "
            + "return Config in every form, no return line, a byte order mark");
    }

    // ------------------------------------------------------------------ reading a config.lua
    internal static int CompareReads(Fixtures fx, Dictionary<string, string> schemas, string dir, List<string> wrong, out int invalid, out int corrected)
    {
        int n = 0;
        invalid = 0; corrected = 0;
        foreach (var rec in fx.Of("read"))
        {
            n++;
            string name = rec[1]!;
            string? text = rec[2];
            var m = TestModule(dir, "read", schemas[name], text);
            string status = m.FileProblem == null ? "ok" : m.FileProblem == ModuleSettings.NotThere ? "missing" : "invalid";
            if (rec[3] == "invalid") invalid++;
            var problems = new List<string>();
            if (status != rec[3]) problems.Add($"{status} instead of {rec[3]} ({m.FileProblem})");
            string fixedKeys = string.Join(",", m.CorrectedKeys);
            if (fixedKeys != (rec[4] ?? "")) problems.Add($"corrected [{fixedKeys}] instead of [{rec[4]}]");
            if (fixedKeys.Length > 0) corrected++;
            if ((rec.Length - 5) / 2 != m.Schema!.Items.Count) problems.Add("another number of items");
            for (int i = 5; i + 1 < rec.Length; i += 2)
            {
                object want = TypedValue(rec[i + 1]!);
                if (!m.Values.TryGetValue(rec[i]!, out object? have) || !SettingsRules.Same(have, want)) problems.Add($"{rec[i]} = {Short(TypedText(have), 30)} instead of {Short(rec[i + 1], 30)}");
            }
            if (ByteTextOf(m.ConfigPath) != text) problems.Add("the file was touched");
            if (problems.Count > 0) wrong.Add($"\"{Short(text, 300)}\" ({name}): " + string.Join(", ", problems.Take(3)));
        }
        return n;
    }

    private static void ReadChecks(Report r, Fixtures fx, Dictionary<string, string> schemas, string dir)
    {
        var wrong = new List<string>();
        int n = CompareReads(fx, schemas, dir, wrong, out int invalid, out int corrected);
        Cases(r, n, wrong, $"config.lua texts are read as the game reads them: every value, which ones had to be corrected ({corrected} files), which files are not usable ({invalid}); "
            + "clamping, rounding, numbers as text, choices, keys, a byte order mark, every way to write plain values");

        wrong = new List<string>();
        n = 0;
        foreach (var rec in fx.Of("code"))
        {
            n++;
            var m = TestModule(dir, "read", schemas["A"], rec[1]);
            bool defaults = m.Schema!.Items.All(i => SettingsRules.Same(m.Values[i.Key], i.Default));
            if (m.FileProblem == null || m.FileProblem == ModuleSettings.NotThere || !defaults || !m.FileProblem.Contains("line ")) wrong.Add($"\"{Short(rec[1], 60)}\": {m.FileProblem ?? "read"}");
        }
        Cases(r, n, wrong, "config.lua texts with more than plain values (arithmetic, calls, control structures) count as not valid in the app: the defaults are shown and the problem names the line "
            + "(the game's Lua runs these - dev/SETTINGS.md section 2 calls them invalid)");

        var withComma = TestModule(dir, "read", schemas["A"], "local Config = {}\nConfig.Amount = 2,5\nreturn Config\n");
        var out0 = TestModule(dir, "read", schemas["A"], "local Config = {}\nConfig.Amount = 99\nConfig.Count = \"x\"\nConfig.Style = { 1 }\nreturn Config\n");
        r.Check(withComma.Warnings.Count == 1 && withComma.Warnings[0].Contains("written with a comma (2,5)") && (double)withComma.Values["Amount"] == 2
            && out0.Warnings.SequenceEqual(new[] { "Amount = 99 is not usable; 10.0 is used", "Count = x is not usable; 3 is used", "Style = a table is not usable; \"b\" is used" }),
            "what was corrected is said in words: " + string.Join(" | ", out0.Warnings.Concat(withComma.Warnings)));
    }

    // ------------------------------------------------------------------ changing values
    internal static int CompareApplies(Fixtures fx, Dictionary<string, string> schemas, string dir, List<string> wrong, out int steps, out int written)
    {
        int n = 0;
        steps = 0; written = 0;
        foreach (var rec in fx.Of("apply"))
        {
            n++;
            string name = rec[1]!;
            var m = TestModule(dir, "apply", schemas[rec[2]!], rec[3]);
            string tmp = m.ConfigPath + ".tmp";
            int count = int.Parse(rec[4]!, Inv), f = 5;
            for (int step = 1; step <= count; step++)
            {
                string kind = rec[f++]!;
                if (kind == "disk")
                {
                    WriteByteText(m.ConfigPath, rec[f++]);       // the other side: the game's menu, an editor
                    // The game has looked at the file after every such change. The app's Save finds a changed file
                    // by itself; only a file that is changed again before the next save has to be looked at here.
                    if (step < count && rec[f] == "disk") m.Reread();
                    continue;
                }
                var wanted = new Dictionary<string, object?>(StringComparer.Ordinal);
                if (kind == "set")
                {
                    int pairs = int.Parse(rec[f++]!, Inv);
                    for (int i = 0; i < pairs; i++, f += 2) wanted[rec[f]!] = TypedValue(rec[f + 1]!);
                }
                else foreach (var item in m.Schema!.Items.Where(i => i.Shown)) wanted[item.Key] = item.Default;      // reset
                string expectChanged = rec[f++] ?? "";
                string? expectText = rec[f++];
                string? before = ByteTextOf(m.ConfigPath);
                bool wrote = m.Save(wanted, out var changed);
                string? after = ByteTextOf(m.ConfigPath);
                steps++;
                string where = $"{name}, step {step}";
                if (string.Join(",", changed) != expectChanged) wrong.Add($"{where}: changed [{string.Join(",", changed)}] instead of [{expectChanged}]");
                else if (expectChanged.Length == 0 ? (wrote || after != before) : (!wrote || after != expectText))
                    wrong.Add($"{where}: the file is \"{Short(after, 400)}\" instead of \"{Short(expectChanged.Length == 0 ? before : expectText, 400)}\"");
                else if (File.Exists(tmp)) wrong.Add($"{where}: a temporary file was left behind");
                if (wrote) written++;
            }
        }
        return n;
    }

    private static void ApplyChecks(Report r, Fixtures fx, Dictionary<string, string> schemas, string dir)
    {
        var wrong = new List<string>();
        int n = CompareApplies(fx, schemas, dir, wrong, out int steps, out int written);
        Cases(r, n, wrong, $"scenarios with {steps} changes ({written} of them write the file): the app's config.lua equals the game's byte for byte after every change - only the changed lines, "
            + "the last matching line, missing lines in schema order in front of return Config, CRLF kept, comments and unknown keys kept, a missing or broken file replaced by the default text "
            + "with the non-default values, the other side's changes kept, reset");
    }

    // ------------------------------------------------------------------ saving one module's file
    private static void SaveChecks(Report r, Dictionary<string, string> schemas, string dir)
    {
        string textA = ModuleSchema.FromText(schemas["A"]).DefaultText();
        Dictionary<string, object?> want(params (string Key, object? Value)[] pairs) => pairs.ToDictionary(p => p.Key, p => p.Value, StringComparer.Ordinal);

        var m = TestModule(dir, "save", schemas["A"], textA);
        string bak = m.ConfigPath + ".bak", tmp = m.ConfigPath + ".tmp";
        bool first = m.Save(want(), out _);
        bool second = m.Save(want(("Amount", 2.5), ("Enabled", true), ("Style", "b"), ("Hotkey", "CTRL+Y"), ("Name", "say \"hi\" \\ there"), ("Count", 3.0)), out var none);
        r.Check(!first && !second && none.Count == 0 && ByteTextOf(m.ConfigPath) == textA && !File.Exists(bak) && !File.Exists(tmp), "saving without a changed value writes nothing (no .bak, no .tmp)");

        bool wrote = m.Save(want(("Amount", 4.0)), out var changed);
        string expected = textA.Replace("Config.Amount = 2.5\n", "Config.Amount = 4.0\n");
        r.Check(wrote && changed.SequenceEqual(new[] { "Amount" }) && ByteTextOf(m.ConfigPath) == expected && ByteTextOf(bak) == textA && !File.Exists(tmp) && (double)m.Values["Amount"] == 4,
            "a changed value is written (temporary file, then replaced); the previous file is kept as config.lua.bak");
        r.Check(!m.Save(want(("Amount", 4.0)), out _) && ByteTextOf(bak) == textA && !m.ChangedOnDisk(), "saving the same value again leaves the file and its .bak alone");

        // the other side writes the file between reading and saving
        string theirs = expected.Replace("Config.Count = 3\n", "Config.Count = 8\n").Replace("Config.Enabled = true\n", "Config.Enabled = false -- by the game\n");
        WriteByteText(m.ConfigPath, theirs);
        bool seen = m.ChangedOnDisk();
        wrote = m.Save(want(("Style", "c")), out changed);
        r.Check(seen && wrote && changed.SequenceEqual(new[] { "Style" }) && ByteTextOf(m.ConfigPath) == theirs.Replace("Config.Style = \"b\"\n", "Config.Style = \"c\"\n")
            && (double)m.Values["Count"] == 8 && !(bool)m.Values["Enabled"] && (string)m.Values["Style"] == "c",
            "a file changed on disk since it was read is read again before the line is changed: the other side's values and comments stay, and the app has them afterwards");
        WriteByteText(m.ConfigPath, theirs.Replace("Config.Count = 8\n", "Config.Count = 9\n"));
        wrote = m.Save(want(("Count", 9.0)), out changed);
        r.Check(!wrote && changed.Count == 0 && (double)m.Values["Count"] == 9 && !m.ChangedOnDisk(), "a value the other side has set already is not written again; the app has the file's values afterwards");

        // values the schema does not allow never reach the file
        m = TestModule(dir, "save", schemas["allkinds"], null);
        var garbage = want(("Enabled", "yes"), ("Feature", 1.0), ("Plain", null), ("Whole", 1e9), ("Tenth", -3.0), ("Fine", 0.12345), ("Large", double.NaN), ("Mode", "no such choice"),
            ("Greeting", "two\nlines\tand a tab"), ("Empty", 5.0), ("Hotkey", "ESCAPE"), ("Other", "ctrl+nokey"), ("Secret", 1000.0), ("SecretText", true), ("Now", true), ("Unknown", 1.0), ("Last", false));
        wrote = m.Save(garbage, out changed);
        string? saved = ByteTextOf(m.ConfigPath);
        var back = TestModule(dir, "save2", schemas["allkinds"], saved);
        var illegal = new List<string>();
        foreach (var item in back.Schema!.Items)
        {
            object v = back.Values[item.Key];
            bool ok = item.Kind switch
            {
                ItemKind.Bool => v is bool,
                ItemKind.Number => v is double d && d >= item.Min && d <= item.Max && SettingsRules.NumberText(d, item.Decimals) == SettingsRules.Literal(item, d),
                ItemKind.Choice => v is string s && item.Options.Contains(s),
                ItemKind.Key => v is string k && KeyNames.Combo(k) == k,
                _ => v is string t && !t.Any(c => c < 32),
            };
            if (!ok) illegal.Add(item.Key);
        }
        r.Check(wrote && back.FileProblem == null && back.CorrectedKeys.Count == 0 && illegal.Count == 0
            && string.Join(",", changed) == "Fine,Greeting,Last,Secret,Tenth,Whole" && saved != null && saved.Contains("Config.Whole = 1000\n") && saved.Contains("Config.Tenth = 0.0\n")
            && saved.Contains("Config.Fine = 0.123\n") && saved.Contains("Config.Greeting = \"two lines and a tab\"\n") && saved.Contains("Config.Secret = 100\n")
            && saved.Contains("Config.Mode = \"second choice\"\n") && saved.Contains("Config.Hotkey = \"CTRL+Y\"\n") && !saved.Contains("Now") && !saved.Contains("Unknown") && !saved.Contains("nan"),
            "values a schema does not allow never reach the file: numbers are pulled into the range and rounded, a wrong kind / choice / key leaves the value as it was, a text stays on one line, "
            + "unknown keys and actions are ignored - the saved file reads back without a correction" + (illegal.Count > 0 ? "; not allowed: " + string.Join(", ", illegal) : ""));

        // a file that cannot be written
        m = TestModule(dir, "save", schemas["A"], textA);
        Directory.CreateDirectory(tmp);         // the temporary file cannot be created: a folder has its name
        string? failure = null;
        try { m.Save(want(("Amount", 4.0)), out _); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { failure = ex.GetType().Name; }
        Directory.Delete(tmp);
        bool intact = ByteTextOf(m.ConfigPath) == textA && (double)m.Values["Amount"] == 2.5;
        wrote = m.Save(want(("Amount", 4.0)), out changed);
        r.Check(failure != null && intact && wrote && ByteTextOf(m.ConfigPath) == expected,
            $"a file that cannot be written is an error for the caller ({failure}); nothing changed, and the same save works once it can be written");
        string gone = Path.Combine(dir, "save", "no-such-folder");
        var lost = new ModuleSettings("lost", gone);
        lost.ReadSchema();
        r.Check(lost.Schema == null && lost.SchemaProblem != null && lost.SchemaProblem.StartsWith("schema.lua could not be read: ", StringComparison.Ordinal) && !lost.Save(want(("Amount", 4.0)), out _),
            "a module folder that is gone: the schema problem is reported, nothing is written, nothing is thrown");

        // missing and broken files
        m = TestModule(dir, "save", schemas["A"], null);
        bool missing = m.FileProblem == ModuleSettings.NotThere && !m.Save(want(("Amount", 2.5)), out _) && !File.Exists(m.ConfigPath);
        wrote = m.Save(want(("Amount", 4.0)), out _);
        r.Check(missing && wrote && ByteTextOf(m.ConfigPath) == expected && !File.Exists(bak) && m.FileProblem == null,
            "no config.lua: the defaults are shown and the module says so; nothing is written until a value changes, then the default text with that value (nothing to keep as .bak)");
        m = TestModule(dir, "save", schemas["A"], "local Config = {}\nConfig.Amount = = 4\nreturn Config\n");
        bool broken = m.FileProblem != null && m.FileProblem.StartsWith("config.lua has an error (line 2: ", StringComparison.Ordinal) && (double)m.Values["Amount"] == 2.5;
        string problem = m.FileProblem ?? "";
        wrote = m.Save(want(("Count", 5.0)), out _);
        r.Check(broken && wrote && ByteTextOf(m.ConfigPath) == textA.Replace("Config.Count = 3\n", "Config.Count = 5\n") && ByteTextOf(bak) == "local Config = {}\nConfig.Amount = = 4\nreturn Config\n" && m.FileProblem == null,
            "a config.lua with an error: the defaults are shown and the problem names the line (\"" + problem + "\"); a changed value replaces the file (the broken one is kept as .bak)");

        // a line the rule changes but Lua does not read
        m = TestModule(dir, "save", schemas["A"], "local Config = {}\n--[[\nConfig.Amount = 1\n]]\nreturn Config\n");
        wrote = m.Save(want(("Amount", 4.0)), out _);
        r.Check(wrote && (double)m.Values["Amount"] == 4 && m.Warnings.Any(w => w.StartsWith("Amount: the saved value does not arrive", StringComparison.Ordinal)),
            "a key whose only line stands in a comment block: the line is changed as the rule says (the game does the same), and the app says that the value does not arrive");

        // the running game replaces the file: it writes config.lua.tmp, removes config.lua and renames
        m = TestModule(dir, "save", schemas["A"], expected);
        File.Move(m.ConfigPath, tmp);               // the game is in the middle of that ...
        int waits = 0;
        var pause = ModuleSettings.Pause;
        bool waited, leftBehind;
        try
        {
            ModuleSettings.Pause = _ => { if (++waits == 1) File.Move(tmp, m.ConfigPath); };        // ... and through with it while the app waits
            waited = !m.Reread() && m.FileProblem == null && waits == 1 && (double)m.Values["Amount"] == 4;
            File.Move(m.ConfigPath, tmp);           // a .tmp somebody left behind, and no config.lua
            leftBehind = m.Reread() && m.FileProblem == ModuleSettings.NotThere && waits == 3 && (double)m.Values["Amount"] == 4;
        }
        finally { ModuleSettings.Pause = pause; }
        wrote = m.Save(want(("Count", 5.0)), out _);
        r.Check(waited && leftBehind && wrote && !File.Exists(tmp) && ByteTextOf(m.ConfigPath) == expected.Replace("Config.Count = 3\n", "Config.Count = 5\n"),
            "a config.lua that is missing for a moment while the game replaces it (its config.lua.tmp is there) is waited for; a .tmp left behind is not waited for for long, "
            + "and the next Save writes the file with the values the app has");

        // a module whose config.lua was never read here
        string scripts = Path.GetDirectoryName(m.ConfigPath)!;
        string now = ByteTextOf(m.ConfigPath)!;
        var fresh = new ModuleSettings("save", scripts);
        fresh.ReadSchema();
        bool read = fresh.Reread() && (double)fresh.Values["Amount"] == 4 && (double)fresh.Values["Count"] == 5 && fresh.Values.Count == fresh.Schema!.Items.Count;
        fresh = new ModuleSettings("save", scripts);
        fresh.ReadSchema();
        wrote = fresh.Save(want(("Count", 6.0), ("Amount", 4.0)), out changed);
        r.Check(read && wrote && changed.SequenceEqual(new[] { "Count" }) && ByteTextOf(m.ConfigPath) == now.Replace("Config.Count = 5\n", "Config.Count = 6\n"),
            "a module whose file was not read before: looking at it again, or saving, starts from the file as a first read does");
    }

    // ------------------------------------------------------------------ finding the modules, the pages
    private static string TinySchema(string module, string? page, int? pageOrder, params (string Title, int? Order)[] groups)
    {
        var sb = new StringBuilder("local Schema = {}\nSchema.Module = \"" + module + "\"\n");
        if (page != null) sb.Append("Schema.Page = \"" + page + "\"\n");
        if (pageOrder != null) sb.Append("Schema.PageOrder = " + pageOrder.Value.ToString(Inv) + "\n");
        sb.Append("Schema.Groups = {\n");
        for (int i = 0; i < groups.Length; i++)
            sb.Append("    { Title = \"" + groups[i].Title + "\", " + (groups[i].Order != null ? "Order = " + groups[i].Order!.Value.ToString(Inv) + ", " : "")
                + "Items = { { Key = \"K" + (i + 1).ToString(Inv) + "\", Kind = \"bool\", Default = true, Label = \"" + groups[i].Title + "\" } } },\n");
        return sb.Append("}\nreturn Schema\n").ToString();
    }

    private static void FindChecks(Report r, Fixtures fx, Dictionary<string, string> schemas, string dir)
    {
        string find = Path.Combine(dir, "find");
        string mega = Path.Combine(find, "G1R_MegaMod");
        string modules = Path.Combine(mega, "modules");
        void file(string path, string? byteText)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            WriteByteText(path, byteText ?? "");
        }
        string repopulate = Path.Combine(modules, "repopulate", "Scripts", "config.lua");
        var real = fx.Of("real").ToDictionary(x => x[1]!, x => x[3]!);
        string keyTwice = fx.Of("schema").First(x => x[1] == "a key twice")[2]!;
        string syntaxError = fx.Of("schema").First(x => x[1] == "a syntax error")[2]!;
        file(Path.Combine(mega, "Scripts", "config.lua"), "local Config = {}\nreturn Config\n");          // the loader's own settings
        file(Path.Combine(mega, "Scripts", "main.lua"), "");
        file(repopulate, new Settings().ToLua());
        file(Path.Combine(modules, "repopulate", "Scripts", "schema.lua"), TinySchema("repopulate", "Repopulate", 1, ("never shown", null)));
        file(Path.Combine(modules, "xp", "Scripts", "schema.lua"), schemas["xp"]);
        file(Path.Combine(modules, "xp", "Scripts", "config.lua"), real["xp"]);
        file(Path.Combine(modules, "general", "Scripts", "schema.lua"), schemas["general"]);
        file(Path.Combine(modules, "general", "Scripts", "config.lua"), real["general"]);
        file(Path.Combine(modules, "markers", "Scripts", "config.lua"), "local Config = {}\nreturn Config\n");     // the map pins: no schema.lua, described by the app
        file(Path.Combine(modules, "markers", "Scripts", "main.lua"), "");
        file(Path.Combine(modules, "plain", "Scripts", "config.lua"), "local Config = {}\nreturn Config\n");       // a module without a schema
        file(Path.Combine(modules, "plain", "Scripts", "main.lua"), "");
        Directory.CreateDirectory(Path.Combine(modules, "empty"));
        file(Path.Combine(modules, "notes.txt"), "a file in the modules folder");
        file(Path.Combine(modules, "broken", "Scripts", "schema.lua"), keyTwice);
        file(Path.Combine(modules, "unreadable", "Scripts", "schema.lua"), syntaxError);
        file(Path.Combine(modules, "zeta", "Scripts", "schema.lua"), TinySchema("zeta", "P", 20, ("z-late", 101), ("z-none", null), ("z-early", 99), ("z-20a", 20), ("z-20b", 20), ("z-20c", 20), ("z-20d", 20), ("z-20e", 20)));
        file(Path.Combine(modules, "alpha", "Scripts", "schema.lua"), TinySchema("alpha", "P", 40, ("a-20", 20), ("a-none", null)));
        file(Path.Combine(modules, "zulu", "Scripts", "schema.lua"), TinySchema("zulu", "Zulu", 30, ("only", null)));
        file(Path.Combine(modules, "nopage", "Scripts", "schema.lua"), TinySchema("nopage", null, null, ("only", null)));
        file(Path.Combine(find, "outside", "Scripts", "schema.lua"), TinySchema("outside", "Outside", 1, ("never", null)));    // beside the megamod
        file(Path.Combine(find, "Scripts", "schema.lua"), TinySchema("above", "Above", 1, ("never", null)));

        var found = MegaMod.Find(repopulate);
        string names = found == null ? "(no megamod)" : string.Join(", ", found.Modules.Select(m => m.Name));
        r.Check(found != null && names == "alpha, broken, general, markers, nopage, unreadable, xp, zeta, zulu" && Path.GetFullPath(found.Root) == Path.GetFullPath(mega),
            "megamod layout: the modules with a schema.lua next to the repopulate module are found, by name, and the module the app describes itself (markers, the map pins) - "
            + "not the repopulate module itself, not another module without a schema, not a folder without Scripts, nothing outside the megamod: " + names);
        if (found != null)
        {
            var broken = found.Modules.First(m => m.Name == "broken");
            var unreadable = found.Modules.First(m => m.Name == "unreadable");
            r.Check(broken.Schema == null && broken.SchemaProblem == "schema.lua: the key Amount is used twice" && unreadable.Schema == null
                && unreadable.SchemaProblem != null && unreadable.SchemaProblem.StartsWith("schema.lua could not be read: line 2: ", StringComparison.Ordinal)
                && found.Modules.Where(m => m != broken && m != unreadable).All(m => m.Schema != null && m.SchemaProblem == null),
                $"a broken schema next to good ones: only that module is affected (\"{broken.SchemaProblem}\", \"{unreadable.SchemaProblem}\")");
            var nav = NavModel.Build(found);
            string layout = nav.Describe();
            r.Check(layout == "Overview: Overview | World: Creatures, Herbs and items, Containers, Crime, Advanced | Hero: Experience | Map: Map pins, People, Colour key, Advanced"
                    + " | Interface: Notes on screen | P: P | Zulu: Zulu | nopage: nopage | broken: broken | unreadable: unreadable",
                "the window's layout, categories with their tabs: the modules the app's table knows where it puts them (xp under Hero, the map pins under Map, general under Interface); "
                + "a module it does not know in a category named after its page, by PageOrder (the lowest of a page's modules), then by name; a schema without a Page: named after its module; "
                + "a module whose schema cannot be used: a category of its own behind those: " + layout);
            var layoutProblems = nav.Problems(found);
            r.Check(layoutProblems.Count == 0, "every group of shown settings is on exactly one tab, every module's notes stand once, no tab is empty"
                + (layoutProblems.Count > 0 ? " - not: " + string.Join("; ", layoutProblems) : ""));
            var p = nav.Find("P/P")!;
            string order = string.Join(" ", p.Groups.Select(g => g.Title));
            r.Check(order == "a-20 z-20a z-20b z-20c z-20d z-20e z-early a-none z-none z-late" && p.Order == 20 && p.Modules.Select(m => m.Name).SequenceEqual(new[] { "alpha", "zeta" }),
                "two modules on one tab: their groups by Order (none = 100), then module name, then order in the file: " + order);
            var problemTab = nav.Find("broken/broken")!;
            r.Check(problemTab.Kind == NavKind.Problem && problemTab.Problem == "The settings of the module broken cannot be shown: schema.lua: the key Amount is used twice." && problemTab.Rows.Count == 0
                && nav.Find("unreadable/unreadable")!.Problem!.StartsWith("The settings of the module unreadable cannot be shown: schema.lua could not be read: line 2: ", StringComparison.Ordinal)
                && nav.Tabs.Where(x => x.Kind == NavKind.Schema).All(x => x.Groups.Any()),
                "the tab of a module whose schema cannot be used says in one sentence what is wrong: " + problemTab.Problem);
            var experience = nav.Find("Hero/Experience")!;
            var notes = nav.Find("Interface/Notes on screen")!;
            r.Check(experience.Groups.Count() == 4 && experience.Groups.All(g => g.Module.Name == "xp") && experience.Groups.Select(g => g.Title).SequenceEqual(
                    new[] { "Experience multiplier", "Large gains (quests)", "On screen", "Log" }) && notes.Groups.Count() == 2 && notes.Modules.Single().Name == "general"
                    && nav.ShownModules().Select(m => m.Name).SequenceEqual(new[] { "xp", "markers", "general", "alpha", "zeta", "zulu", "nopage" }),
                "the tabs of the modules xp and general: a group of hidden items only (Advanced) is not on a tab; the modules in the order of the tabs: " + string.Join(", ", nav.ShownModules().Select(m => m.Name)));
            // the separate mod G1R_Repopulate: its five pages and nothing else
            r.Check(NavModel.Build(null).Describe() == "World: Creatures, Herbs and items, Containers, Crime, Advanced", "without a megamod the layout is the five pages of the repopulate mod: " + NavModel.Build(null).Describe());
            foreach (var m in found.Modules) m.Load();
            r.Check(found.Modules.Where(m => m.Schema != null && (real.ContainsKey(m.Name) || m.Described)).All(m => m.FileProblem == null && m.Warnings.Count == 0)
                && found.Modules.Where(m => m.Schema != null && !real.ContainsKey(m.Name) && !m.Described).All(m => m.FileProblem == ModuleSettings.NotThere),
                "their config.lua files are read; a module without one says so");
        }

        // other layouts: no generic pages
        string standalone = Path.Combine(find, "Mods", "G1R_Repopulate", "Scripts", "config.lua");
        file(standalone, new Settings().ToLua());
        file(Path.Combine(find, "Mods", "Other", "Scripts", "schema.lua"), TinySchema("other", "Other", 1, ("never", null)));
        string loose = Path.Combine(find, "loose", "modules", "repopulate", "Scripts", "config.lua");
        file(loose, new Settings().ToLua());
        file(Path.Combine(find, "loose", "modules", "xp", "Scripts", "schema.lua"), schemas["xp"]);
        string odd = Path.Combine(find, "odd", "modules", "repopulate", "Data", "config.lua");
        file(odd, new Settings().ToLua());
        Directory.CreateDirectory(Path.Combine(find, "odd", "Scripts"));
        r.Check(MegaMod.Find(standalone) == null && MegaMod.Find(loose) == null && MegaMod.Find(odd) == null && MegaMod.Find(null) == null && MegaMod.Find("") == null
            && MegaMod.Find(Path.Combine(find, "no", "such", "folder", "at", "all", "config.lua")) == null,
            "standalone layout (Mods\\G1R_Repopulate\\Scripts\\config.lua), a modules folder without the loader beside it, a settings file that is not in a Scripts folder, no file at all: no megamod, no generic pages");

        // the settings file of the repopulate module is found from where the exe sits
        bool same(string? a, string b) => a != null && string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.Ordinal);
        string emptyFolder = Path.Combine(find, "nothing-here");
        Directory.CreateDirectory(emptyFolder);
        r.Check(same(Paths.FindConfig(Path.Combine(modules, "repopulate")), repopulate) && same(Paths.FindConfig(mega), repopulate) && same(Paths.FindConfig(find), repopulate)
            && same(Paths.FindConfig(Path.Combine(find, "Mods", "G1R_Repopulate")), standalone) && same(Paths.FindConfig(Path.Combine(find, "Mods")), standalone)
            && Paths.FindConfig(emptyFolder) == null,
            "the repopulate settings are found from the exe's folder: in modules\\repopulate, in the megamod's own folder (not the loader's Scripts\\config.lua), in the Mods folder, in the standalone mod; nowhere else");
    }

    // =====================================================================
    // the presets (Presets.cs): Tiers in a schema, the values for the repopulate module
    // =====================================================================
    private static string TierText(IEnumerable<object>? values) =>
        values == null ? "none" : string.Join(" | ", values.Select(v => v switch { bool b => b ? "yes" : "no", double d => d.ToString("0.###", Inv), _ => v.ToString() }));

    private static void PresetChecks(Report r, Dictionary<string, string> schemas)
    {
        // one item K with these fields (and a plain second item, so that a schema whose K has no value is still one)
        (string? Problem, List<object>? Values) read(string fields)
        {
            var schema = ModuleSchema.FromText("local Schema = {}\nSchema.Groups = { { Items = { { Key = \"K\", " + fields
                + " }, { Key = \"Other\", Kind = \"bool\", Default = false } } } }\nreturn Schema\n");
            return (schema.TierProblems.Count > 0 ? schema.TierProblems[0] : null, schema.Groups[0].Items[0].Tiers);
        }
        const string Number = "Kind = \"number\", Default = 1.0, Min = 0, Max = 10, Decimals = 2";
        const string Five = "K: Tiers must be 5 values or \"default\"";

        var none = read(Number);
        var numbers = read(Number + ", Tiers = { 1, 2, 3.25, 4, 10 }");
        var same = read(Number + ", Tiers = \"default\"");
        var yesNo = read("Kind = \"bool\", Default = false, Tiers = { false, false, true, true, true }");
        var choice = read("Kind = \"choice\", Default = \"a\", Options = { \"a\", \"b\" }, Tiers = { \"a\", \"a\", \"b\", \"b\", \"b\" }");
        r.Check(none.Problem == null && none.Values == null && numbers.Problem == null && TierText(numbers.Values) == "1 | 2 | 3.25 | 4 | 10" && numbers.Values!.All(v => v is double)
            && same.Problem == null && TierText(same.Values) == "1 | 1 | 1 | 1 | 1" && TierText(yesNo.Values) == "no | no | yes | yes | yes" && TierText(choice.Values) == "a | a | b | b | b",
            "Tiers of an item: five values of its kind, or \"default\" (the default five times); an item without Tiers is left alone by the presets");

        // what cannot be used, in the words of the mod's own check (dev/tools/presets.lua)
        var cases = new (string Fields, string Problem, string What)[]
        {
            (Number + ", Tiers = 5", Five, "a number instead of a list"),
            (Number + ", Tiers = \"neutral\"", Five, "another word"),
            (Number + ", Tiers = { 1, 2, 3, 4 }", Five, "four values"),
            (Number + ", Tiers = { 1, 2, 3, 4, 5, 6 }", Five, "six values"),
            (Number + ", Tiers = { 1, 2, 3, 4, 5, Name = \"x\" }", Five, "a named entry"),
            (Number + ", Tiers = { 1, 2, 3, 4, 11 }", "K: tier 5 must be a number from 0 to 10", "a number above the range"),
            (Number + ", Tiers = { 1, -1, 3, 4, 5 }", "K: tier 2 must be a number from 0 to 10", "a number below the range"),
            (Number + ", Tiers = { 1, 2, \"3\", 4, 5 }", "K: tier 3 must be a number from 0 to 10", "a text among numbers"),
            (Number + ", Tiers = { 1, 2, 3.125, 4, 5 }", "K: tier 3 has more places than Decimals allows", "more places than Decimals"),
            ("Kind = \"number\", Default = 1.0, Min = 0, Max = 10, Tiers = { 1, 2.5, 3, 4, 5 }", "K: tier 2 has more places than Decimals allows", "a fraction in a whole-number item"),
            (Number + ", Tiers = { 2, 2, 3, 4, 5 }", "K: tier 1 is the game itself - it must be the item's Default", "a first value that is not the default"),
            ("Kind = \"bool\", Default = true, Tiers = { true, 1, true, true, true }", "K: tier 2 must be true or false", "a number in a yes/no item"),
            ("Kind = \"choice\", Default = \"a\", Options = { \"a\", \"b\" }, Tiers = { \"a\", \"a\", \"c\", \"b\", \"b\" }", "K: tier 3 is not one of the Options", "a choice that is not offered"),
            ("Kind = \"text\", Default = \"\", Tiers = \"default\"", "K: Tiers are for yes/no, number and choice items", "a text item"),
            ("Kind = \"key\", Default = \"\", Tiers = \"default\"", "K: Tiers are for yes/no, number and choice items", "a key"),
            ("Kind = \"action\", Tiers = \"default\"", "K: Tiers are for yes/no, number and choice items", "a button"),
            (Number + ", Hidden = true, Tiers = \"default\"", "K: a hidden item cannot have Tiers (the app has no control for it)", "a hidden item"),
        };
        var wrong = new List<string>();
        foreach (var c in cases)
        {
            var got = read(c.Fields);
            if (got.Problem != c.Problem || got.Values != null) wrong.Add(c.What + ": " + (got.Problem ?? "taken: " + TierText(got.Values)));
        }
        Cases(r, cases.Length, wrong, "Tiers that cannot be used: the schema is used all the same (the game does not read the field), the item is left out of the presets, and the reason is the one the mod's own check gives");

        // the test module with every kind of setting
        var all = ModuleSchema.FromText(schemas["allkinds"]);
        string tiers(string key) => TierText(all.Groups.SelectMany(g => g.Items).First(i => i.Key == key).Tiers);
        r.Check(tiers("Feature") == "no | no | yes | yes | yes" && tiers("Plain") == "no | no | no | no | no" && tiers("Whole") == "5 | 10 | 20 | 500 | 1000"
            && tiers("Tenth") == "1.5 | 2 | 2.5 | 5 | 10" && tiers("Mode") == "second choice | first | first | the third and longest of the choices | the third and longest of the choices"
            && tiers("Large") == "none" && tiers("Fine") == "none" && tiers("Greeting") == "none" && tiers("Secret") == "none"
            && string.Join(" / ", all.TierProblems) == "Fine: Tiers must be 5 values or \"default\" / Greeting: Tiers are for yes/no, number and choice items / Secret: a hidden item cannot have Tiers (the app has no control for it)",
            "the test module: five of its settings are part of the presets, three have Tiers that cannot be used: " + string.Join(" / ", all.TierProblems));
        var xp = ModuleSchema.FromText(schemas["xp"]);
        r.Check(xp.TierProblems.Count == 0 && TierText(xp.ByKey["Multiplier"].Tiers) == "1 | 1.5 | 2 | 4 | 10" && TierText(xp.ByKey["Enabled"].Tiers) == "yes | yes | yes | yes | yes"
            && xp.ByKey["ShowMessage"].Tiers == null && xp.ByKey["LogGains"].Tiers == null,
            "the module xp: the multiplier is 1 / 1.5 / 2 / 4 / 10 in the five presets, the module is on in each; the note and the log switch are left alone");

        // the repopulate module: the values stand in the app
        var problems = new List<string>();
        for (int tier = 1; tier <= Presets.Count; tier++)
        {
            var s = new Settings { CreaturesEnabled = tier == 1, NormalChance = 0.77, RegrowHours = 5, CrimeEnabled = tier != 1, Enabled = false, IncludeLootObjects = false, CrimeForgetOld = false };
            s.Species["Wolf"] = new SpeciesOverride { Chance = 0.6, EveryHours = 12 };
            s.ExcludeSpecies.Add("Meatbug");
            s.RemoveCorpsesOnRespawn = false;
            Presets.Apply(s, tier);
            for (int other = 1; other <= Presets.Count; other++)
                if (Presets.Matches(s, other) != (other == tier)) problems.Add($"after preset {tier}: matches {other} = {Presets.Matches(s, other)}");
            if (!s.Enabled || !s.IncludeLootObjects || !s.CrimeForgetOld || s.Species.Count != 1 || s.Species["Wolf"].EveryHours != 12 || s.ExcludeSpecies.Count != 1 || s.RemoveCorpsesOnRespawn)
                problems.Add($"preset {tier}: the mod's own switch, loot spots and forgetting old crimes must be on, per-species settings and the other settings must stay");
            // written and read again it is still that preset
            var back = Settings.FromText(s.ToLua(), new List<string>());
            if (!Presets.Matches(back, tier)) problems.Add($"preset {tier} does not survive config.lua");
            s.DailyChance += 0.01;
            if (Presets.Matches(s, tier)) problems.Add($"preset {tier}: one changed value must end the match");
            // each of the three switches a preset turns on is part of it
            foreach (string off in new[] { "Enabled", "IncludeLootObjects", "CrimeForgetOld" })
            {
                var t = back.Clone();
                if (off == "Enabled") t.Enabled = false; else if (off == "IncludeLootObjects") t.IncludeLootObjects = false; else t.CrimeForgetOld = false;
                if (Presets.Matches(t, tier)) problems.Add($"preset {tier}: with {off} switched off it must not match");
            }
        }
        var p = Presets.ForRepopulate;
        bool first = !p[0].Creatures && !p[0].Herbs && !p[0].Items && !p[0].Chests && p[0].Crime;
        bool last = p[4].Creatures && p[4].NormalChance == 1 && p[4].EliteChance == 1 && p[4].RegrowHours == 1 && p[4].ItemChance == 1 && p[4].SettlementChance == 1 && p[4].WildChance == 1
            && !p[4].Crime && p[4].NoTheft && p[4].NoTrespassing && p[4].NoWeapons;
        bool rising = true;
        for (int i = 2; i < Presets.Count; i++)
        {
            var a = p[i - 1];
            var b = p[i];
            // from preset 2 on nothing gets harder: chances do not fall, waits do not grow, no crime comes back
            if (b.NormalChance < a.NormalChance || b.EliteChance < a.EliteChance || b.ItemChance < a.ItemChance || b.SettlementChance < a.SettlementChance || b.WildChance < a.WildChance
                || b.NormalHours > a.NormalHours || b.EliteHours > a.EliteHours || b.RegrowHours > a.RegrowHours
                || !b.Creatures || !b.Herbs || !b.Items || !b.Chests || (b.Crime && !a.Crime)
                || (!a.Crime && a.NoTheft && !(b.NoTheft && !b.Crime)) || (!a.Crime && a.NoTrespassing && !b.NoTrespassing) || (!a.Crime && a.NoWeapons && !b.NoWeapons)) rising = false;
        }
        r.Check(problems.Count == 0 && Presets.Names.Length == Presets.Count && p.Length == Presets.Count && first && last && rising,
            "the repopulate module in the five presets: 1 = nothing comes back and the game's own crime rules, 5 = every chance at 100 %, herbs every hour, no crime; "
            + "from 2 to 5 nothing gets harder; every preset switches the module, loot spots and forgetting old crimes on; a preset leaves per-species settings and the other settings alone and survives config.lua"
            + (problems.Count > 0 ? " - " + string.Join("; ", problems) : ""));

        // the document
        string doc = Presets.Document(null);
        r.Check(doc.StartsWith("G1R_MegaMod - the five presets of the settings app\n", StringComparison.Ordinal) && doc.Contains("  Creatures.NormalChance        35 %      15 %      35 %      60 %      100 %\n")
            && doc.Contains("  Crime: theft                  crime     crime     crime     crime     allowed\n") && doc.Contains("On in every preset: Chests.IncludeLootObjects")
            && doc.Replace('\n', ' ').Contains("or on \"Your own settings\" when they are at none of the five.") && doc.Split('\n').All(l => l.Length <= 96) && !doc.Contains('\r'),
            "the text about the presets (PRESETS.txt of the mod) lists the repopulate settings of each preset");
    }

    // =====================================================================
    // the map pins: a module without a schema.lua, described by the app (AppSchemas)
    // =====================================================================
    private static void MapPinChecks(Report r, string dir)
    {
        string shipped = AppSchemas.MarkersDefault;
        var schema = ModuleSchema.FromText(AppSchemas.MarkersSchema);
        var parsed = SettingsRules.Parse(shipped, out string? why);
        var notDefault = new List<string>();
        if (parsed != null)
            foreach (var item in schema.Items)
            {
                if (parsed[item.Key] == null) { notDefault.Add(item.Key + " (not in the file)"); continue; }
                object v = SettingsRules.Checked(item, parsed[item.Key], out bool corrected);
                if (corrected || SettingsRules.Literal(item, v) != SettingsRules.Literal(item, item.Default!)) notDefault.Add(item.Key);
            }
        var keys = System.Text.RegularExpressions.Regex.Matches(shipped, "(?m)^Config\\.([A-Za-z_][A-Za-z0-9_]*)\\s*=").Select(m => m.Groups[1].Value).Distinct(StringComparer.Ordinal).ToList();
        var undescribed = keys.Where(k => !schema.ByKey.ContainsKey(k)).ToList();
        r.Check(parsed != null && notDefault.Count == 0 && undescribed.SequenceEqual(new[] { "HideIds", "ExtraNPCs" }) && schema.Items.All(i => i.Shown) && schema.Items.Count == keys.Count - 2
            && schema.TierProblems.Count == 0 && schema.Items.All(i => i.Tiers == null),
            $"the app's description of the map pin settings fits the config.lua the mod ships: {schema.Items.Count} settings, each with the file's value as its default; "
            + "not described are the two lists (HideIds, ExtraNPCs); no setting of it is part of a preset"
            + (parsed == null ? " - the file cannot be read: " + why : "") + (notDefault.Count > 0 ? " - not the default: " + string.Join(", ", notDefault) : "")
            + (!undescribed.SequenceEqual(new[] { "HideIds", "ExtraNPCs" }) ? " - not described: " + string.Join(", ", undescribed) : ""));

        // the rule that changes a value and leaves the rest of its line alone
        var cases = new (string Text, string Key, string Value, string Expected)[]
        {
            ("Config.A = 1 -- note\n", "A", "2", "Config.A = 2 -- note\n"),
            ("Config.S = \"a -- b\"  -- the real note\n", "S", "\"x\"", "Config.S = \"x\"  -- the real note\n"),
            ("Config.S = 'it''s'\n", "S", "\"x\"", "Config.S = \"x\"'s'\n"),
            ("Config.S = \"a \\\" b\" -- n\n", "S", "\"\"", "Config.S = \"\" -- n\n"),
            ("Config.A = 1\nConfig.A = 2 -- the last one counts\n", "A", "9", "Config.A = 1\nConfig.A = 9 -- the last one counts\n"),
            ("  Config.A   =   -5;  -- x\r\nreturn Config\r\n", "A", "7", "  Config.A   =   7;  -- x\r\nreturn Config\r\n"),
            ("Config.A = true", "A", "false", "Config.A = false"),
            ("Config.A = 0.75--close\n", "A", "0.5", "Config.A = 0.5--close\n"),
            ("Config.AB = 1\nConfig.A = 2\n", "A", "3", "Config.AB = 1\nConfig.A = 3\n"),
            // nothing this rule knows the end of, or no line at all: the whole line is written, as the game does it
            ("Config.T = { 1, 2 } -- a list\n", "T", "5", SettingsRules.Patch("Config.T = { 1, 2 } -- a list\n", "T", "5")),
            ("Config.A = \"no end\n", "A", "1", SettingsRules.Patch("Config.A = \"no end\n", "A", "1")),
            ("local Config = {}\nreturn Config\n", "A", "1", SettingsRules.Patch("local Config = {}\nreturn Config\n", "A", "1")),
            ("-- Config.A = 1\nreturn Config\n", "A", "2", SettingsRules.Patch("-- Config.A = 1\nreturn Config\n", "A", "2")),
        };
        var wrong = new List<string>();
        foreach (var c in cases)
        {
            string got = SettingsRules.PatchValue(c.Text, c.Key, c.Value);
            if (got != c.Expected) wrong.Add($"\"{Short(c.Text, 60)}\" {c.Key} = {c.Value}: \"{Short(got, 80)}\"");
        }
        Cases(r, cases.Length, wrong, "a value changed in a line with a note behind it: only the value is replaced - a number, a text (also one with -- or a quote in it), yes / no; the last line of a key counts; "
            + "indentation, spaces, a semicolon and the line end stay; a table, a text without its end, a key without a line: the line is written the way the game writes one");

        // the module's file
        string scripts = Path.Combine(dir, "pins", "modules", AppSchemas.Markers, "Scripts");
        Directory.CreateDirectory(scripts);
        string path = Path.Combine(scripts, "config.lua");
        WriteByteText(path, shipped);
        var m = AppSchemas.For(AppSchemas.Markers, scripts) ?? throw new InvalidOperationException("the app does not describe the module markers");
        m.ReadSchema();
        m.Load();
        bool read = m.Described && m.Schema != null && m.FileProblem == null && m.Warnings.Count == 0 && m.Schema.Items.All(i => SettingsRules.Same(m.Values[i.Key], i.Default))
            && m.DefaultText() == shipped && AppSchemas.For("xp", scripts) == null && AppSchemas.For(AppSchemas.Markers, Path.Combine(dir, "pins", "nowhere")) == null;
        var scale = m.Schema!.ByKey["LabelScale"];
        bool saved = m.Save(new Dictionary<string, object?> { ["AreaPinSize"] = 30.0, ["WorldLabels"] = "auto", ["ShowLegend"] = false, ["LabelScale"] = 0.5 }, out var changed);
        string expected = Swap1(wrong, shipped, "Config.AreaPinSize = 23   -- camp maps", "Config.AreaPinSize = 30   -- camp maps");
        expected = Swap1(wrong, expected, "Config.WorldLabels = \"hover\"  -- world map", "Config.WorldLabels = \"auto\"  -- world map");
        expected = Swap1(wrong, expected, "Config.ShowLegend = true\n", "Config.ShowLegend = false\n");
        expected = Swap1(wrong, expected, "Config.LabelScale = 0.39\n", "Config.LabelScale = " + SettingsRules.Literal(scale, 0.5) + "\n");
        string? now = ByteTextOf(path);
        r.Check(read && saved && wrong.Count == 0 && changed.OrderBy(k => k, StringComparer.Ordinal).SequenceEqual(new[] { "AreaPinSize", "LabelScale", "ShowLegend", "WorldLabels" })
            && now == expected && ByteTextOf(path + ".bak") == shipped && !File.Exists(path + ".tmp") && m.Warnings.Count == 0 && m.FileProblem == null
            && !m.Save(new Dictionary<string, object?> { ["AreaPinSize"] = 30.0 }, out _),
            "the map pins' config.lua: read with its shipped values; four changed values replace four values - the notes behind them, the comments, the two lists and every other line stay "
            + "as they are; the file before is kept as .bak; the same value again writes nothing" + (now == expected ? "" : ": " + Short(now, 900)) + (wrong.Count > 0 ? " - " + string.Join("; ", wrong) : ""));

        // what the player wrote by hand
        string hand = Swap1(wrong, Swap1(wrong, shipped, "Config.AreaLabels = \"auto\"    -- camp maps", "Config.AreaLabels = \"ALWAYS\"    -- camp maps"), "Config.AreaPinSize = 23   -- camp maps", "Config.AreaPinSize = 500   -- huge");
        WriteByteText(path, hand);
        m.Load();
        bool shown = m.FileProblem == null && (string)m.Values["AreaLabels"] == "always" && SettingsRules.Same(m.Values["AreaPinSize"], 128.0) && m.Warnings.Count == 1
            && m.Warnings[0] == "AreaPinSize = 500 is outside what this page can show: it shows 128, and the file keeps its value until you change it here";
        bool other = m.Save(new Dictionary<string, object?> { ["HoverNames"] = false }, out var changed2) && changed2.SequenceEqual(new[] { "HoverNames" });
        string expectedHand = Swap1(wrong, hand, "Config.HoverNames = true\n", "Config.HoverNames = false\n");
        now = ByteTextOf(path);
        r.Check(shown && other && wrong.Count == 0 && now == expectedHand,
            "a value written by hand: a choice in capitals is taken as the module takes it; a number outside what the page can show is shown at the nearest end and the page says so - "
            + "saving another setting leaves that line as it is" + (m.Warnings.Count > 0 ? ": " + m.Warnings[0] : "") + (now == expectedHand ? "" : " - the file: " + Short(now, 600)));

        // a file that does not have the line, and no file at all
        WriteByteText(path, "local Config = {}\nreturn Config\n");
        m.Load();
        string tinyState = $"problem {m.FileProblem ?? "none"}, {m.Warnings.Count} warning(s)";
        bool tiny = m.FileProblem == null && m.Warnings.Count == 0 && m.Save(new Dictionary<string, object?> { ["AreaPinSize"] = 30.0 }, out _);
        string tinyText = ByteTextOf(path) ?? "";
        m.Load();
        tiny = tiny && m.FileProblem == null && SettingsRules.Same(m.Values["AreaPinSize"], 30.0) && tinyText == "local Config = {}\nConfig.AreaPinSize = 30\nreturn Config\n";
        File.Delete(path);
        if (File.Exists(path + ".bak")) File.Delete(path + ".bak");
        m.Load();
        bool none = m.FileProblem == ModuleSettings.NotThere && m.Save(new Dictionary<string, object?> { ["AreaPinSize"] = 30.0 }, out _)
            && ByteTextOf(path) == Swap1(wrong, shipped, "Config.AreaPinSize = 23   -- camp maps", "Config.AreaPinSize = 30   -- camp maps") && !File.Exists(path + ".bak");
        r.Check(tiny && none && wrong.Count == 0, $"a file without the line of a setting gets the line ({tiny}); no file: the shipped text with the changed value is written ({none})"
            + (tiny ? "" : $" - {tinyState}; the file: \"{Short(tinyText, 300)}\""));
    }

    // text with `from` replaced by `to`; from must be there exactly once (else it is noted in `missing`)
    private static string Swap1(List<string> missing, string text, string from, string to)
    {
        int at = text.IndexOf(from, StringComparison.Ordinal);
        if (at < 0 || text.IndexOf(from, at + 1, StringComparison.Ordinal) >= 0) missing.Add("not there exactly once: " + from.TrimEnd('\n'));
        return text.Replace(from, to, StringComparison.Ordinal);
    }

    // =====================================================================
    // the modules installed around the settings file
    // =====================================================================
    private static void InstalledModuleChecks(Report r, string? configPath)
    {
        try
        {
            var mega = MegaMod.Find(configPath);
            if (mega == null)
            {
                r.Info("no megamod around the settings file (standalone layout): the app shows no generic pages here");
                return;
            }
            r.Info($"megamod found: {mega.Modules.Count} module(s) with a schema.lua");
            foreach (var m in mega.Modules)
            {
                r.Check(m.Schema != null, $"installed module {m.Name}: schema.lua is usable" + (m.Schema == null ? " - " + m.SchemaProblem : ""));
                if (m.Schema == null) continue;
                // the default text of the schema must read back as the defaults, without a correction
                string text = m.Schema.DefaultText();
                var parsed = SettingsRules.Parse(text, out string? problem);
                var notDefault = new List<string>();
                if (parsed != null)
                    foreach (var item in m.Schema.Items.Where(i => i.Shown))
                    {
                        object v = SettingsRules.Checked(item, parsed[item.Key], out bool corrected);
                        if (corrected || SettingsRules.Literal(item, v) != SettingsRules.Literal(item, item.Default!)) notDefault.Add(item.Key);
                    }
                r.Check(parsed != null && notDefault.Count == 0, $"installed module {m.Name}: the default config.lua of its schema reads back as its defaults"
                    + (parsed == null ? " - " + problem : notDefault.Count > 0 ? " - not: " + string.Join(", ", notDefault) : ""));
                m.Load();
                int shown = m.Schema.Items.Count(i => i.Shown);
                string state = m.FileProblem ?? (ByteTextOf(m.ConfigPath) == text ? "config.lua holds the defaults"
                    : m.Schema.Items.Count(i => !SettingsRules.Same(m.Values[i.Key], i.Default)).ToString(Inv) + " value(s) differ from the defaults");
                r.Info($"  {m.Name}: page \"{m.Schema.Page ?? m.Name}\", {m.Schema.Groups.Count} group(s), {shown} setting(s) shown, {m.Schema.Items.Count - shown} hidden; {state}"
                    + (m.Warnings.Count > 0 ? "; corrected: " + string.Join("; ", m.Warnings) : ""));
            }
            var nav = NavModel.Build(mega);
            r.Info("  layout: " + nav.Describe());
            var layoutProblems = nav.Problems(mega);
            var longest = nav.Tabs.Where(t => t.Kind == NavKind.Schema).OrderByDescending(NavModel.SettingsOn).FirstOrDefault();
            r.Check(layoutProblems.Count == 0, "installed modules: every group of shown settings is on exactly one tab, every module's notes stand once, no tab is empty"
                + (longest != null ? $" (the longest tab: {longest.Path}, {NavModel.SettingsOn(longest)} settings)" : "")
                + (layoutProblems.Count > 0 ? " - not: " + string.Join("; ", layoutProblems) : ""));
            var usable = mega.Modules.Where(m => m.Schema != null).ToList();
            var tierProblems = usable.SelectMany(m => m.Schema!.TierProblems.Select(p => m.Name + ": " + p)).ToList();
            var covered = usable.Select(m => (m.Name, Count: m.Schema!.Groups.SelectMany(g => g.Items).Count(i => i.Tiers != null))).Where(x => x.Count > 0).ToList();
            r.Check(tierProblems.Count == 0, "installed modules: the presets - " + (covered.Count == 0 ? "no module names values for them (the presets set the repopulate pages only)"
                : string.Join(", ", covered.Select(x => $"{x.Name} {x.Count}")) + " setting(s) have a value for each of the five")
                + (tierProblems.Count > 0 ? " - not usable: " + string.Join("; ", tierProblems) : ""));
        }
        catch (Exception ex)
        {
            r.Check(false, "exception (installed modules): " + ex);
        }
    }

    // =====================================================================
    // the walk over the pages made from schemas: what the UI test (--uitest) does, and its rehearsal without a window
    // =====================================================================
    // A second module on the page of the module with every kind: its group stands between the groups of that one
    // (Order 15), its keys have the names of keys there (keys are a module's own), it has a note of its own.
    private const string SecondSchema =
        "local Schema = {}\nSchema.Module = \"second\"\nSchema.Page = \"All kinds\"\nSchema.PageOrder = 95\n"
        + "Schema.Header = { \"A second module on the same page\" }\n"
        + "Schema.Notes = { \"" + Walk.SecondNote + "\" }\n"
        + "Schema.Groups = {\n    { Title = \"Second module\", Order = 15, Items = {\n"
        + "        { Key = \"Enabled\", Kind = \"bool\", Default = true, Label = \"On & running (the second module)\", Comment = \"A tool tip with an & in it.\" },\n"
        + "        { Key = \"Whole\", Kind = \"number\", Default = 2, Min = 1, Max = 5, Label = \"Speed of the second module\", Needs = \"Enabled\", Tiers = { 2, 3, 3, 4, 5 } },\n"
        + "    } },\n}\nreturn Schema\n";

    // The megamod of the UI test in `root`: the loader's folder and, in modules\, xp and general (schema.lua and the
    // shipped config.lua as the fixtures have them), allkinds (a schema with every kind of setting, no config.lua
    // yet), second (a small module on the page of allkinds, no config.lua yet), markers (a module without a
    // schema), broken (a schema with a key twice). Returns the module names.
    private static List<string> WriteTestModules(string root)
    {
        var fx = Fixtures.Parse(Fixtures.EmbeddedText());
        void file(string module, string name, string byteText)
        {
            string scripts = Path.Combine(root, "modules", module, "Scripts");
            Directory.CreateDirectory(scripts);
            WriteByteText(Path.Combine(scripts, name), byteText);
        }
        Directory.CreateDirectory(Path.Combine(root, "Scripts"));
        WriteByteText(Path.Combine(root, "Scripts", "main.lua"), "-- (the loader's folder is what makes this a megamod)\n");
        foreach (var rec in fx.Of("real"))
        {
            file(rec[1]!, "schema.lua", rec[2]!);
            file(rec[1]!, "config.lua", rec[3]!);
        }
        file("allkinds", "schema.lua", fx.Of("schema").First(x => x[1] == "allkinds")[2]!);
        file("second", "schema.lua", SecondSchema);
        file("markers", "config.lua", "local Config = {}\nreturn Config\n");
        file("broken", "schema.lua", fx.Of("schema").First(x => x[1] == "a key twice")[2]!);
        return new List<string> { "xp", "general", "allkinds", "second", "markers", "broken" };
    }

    /// <summary>
    /// What the UI test looks for along its way: the tabs and what is on them, and the files after every
    /// Save - made from the default texts by replacing lines. The rehearsal (WalkChecks) goes the same way
    /// through the modules' settings without a window, so that these expectations are checked wherever
    /// the tests run, not only on a PC with a screen.
    /// </summary>
    private sealed class Walk
    {
        // the categories of the pane with their tabs (the hand-written pages of the repopulate module under World)
        public const string Layout = "Overview: Overview | World: Creatures, Herbs and items, Containers, Crime, Advanced | Hero: Experience | Map: Map pins, People, Colour key, Advanced"
            + " | Interface: Notes on screen | All kinds: All kinds | broken: broken";
        public const string Modules = "xp, markers, general, allkinds, second";    // the modules on the tabs, in the order of the tabs = the order they are saved in
        public const string All = "All kinds/All kinds", Experience = "Hero/Experience", General = "Interface/Notes on screen", Broken = "broken/broken";     // tabs the tests go to
        public const string AllBoxes = "Switches | Second module | Numbers | Lists and texts | Keys | ";
        public const string XpBoxes = "Experience multiplier | Large gains (quests) | On screen | Log";
        public const string GeneralBoxes = "Notes on screen | Letters";
        public const string FirstHint = "The hint of the group stands under its title.", SecondHint = "Click a box and press the key.";
        public const string SecondNote = "A note of the second module: it stands below that module's group & keeps its ampersand.";
        public const string BrokenSentence = "The settings of the module broken cannot be shown: schema.lua: the key Amount is used twice.";
        public const string Typed = "Gr\u00F6\u00DFe \"x\" \\ y";             // typed into a text box (saved as UTF-8)
        public const string Garbage = "local Config = {\n";                     // a config.lua with an error
        public const string ErrorStart = "config.lua has an error (line ";

        /// <summary>The lines that were to be replaced and were not there exactly once (must stay empty).</summary>
        public readonly List<string> Missing = new();
        public readonly string XpShipped, GeneralShipped, AllDefault;           // the default texts (xp, general: the shipped config.lua)
        public readonly string XpSaved, GeneralSaved, AllSaved;                 // after the first Save
        public readonly string XpTheirs, XpMerged;                              // the other side wrote xp's file; Save changes one line of that
        public readonly string GeneralTheirs, GeneralTheirsLater, GeneralMerged;
        public readonly string XpDefaults;                                      // after Defaults and Save
        public readonly string GeneralRepaired;                                 // the file with an error, replaced by Save
        public readonly string SecondDefault, SecondSaved;                      // the second module on the page of allkinds: its default text; one value changed

        public Walk(Fixtures fx)
        {
            var real = fx.Of("real").ToDictionary(x => x[1]!, x => x[3]!);
            XpShipped = real["xp"];
            GeneralShipped = real["general"];
            AllDefault = fx.Of("schema").First(x => x[1] == "allkinds")[4]!;
            XpSaved = Swap(XpShipped, ("Config.Multiplier = 1.0\n", "Config.Multiplier = 4.0\n"), ("Config.LargeGainFrom = 0\n", "Config.LargeGainFrom = 250\n"),
                ("Config.ShowMessage = true\n", "Config.ShowMessage = false\n"), ("Config.LogGains = false\n", "Config.LogGains = true\n"));
            GeneralSaved = Swap(GeneralShipped, ("Config.NoteStyle = \"box\"\n", "Config.NoteStyle = \"subtitle\"\n"), ("Config.NoteSeconds = 3\n", "Config.NoteSeconds = 7\n"));
            AllSaved = Swap(AllDefault,
                ("Config.Feature = false\n", "Config.Feature = true\n"), ("Config.Whole = 5\n", "Config.Whole = 995\n"), ("Config.Tenth = 1.5\n", "Config.Tenth = 2.3\n"),
                ("Config.Fine = 0.125\n", "Config.Fine = -1.0\n"), ("Config.Large = 50000\n", "Config.Large = 100000000\n"),
                ("Config.Mode = \"second choice\"\n", "Config.Mode = \"the third and longest of the choices\"\n"),
                ("Config.Greeting = \"say \\\"hi\\\" \\\\ there\"\n", "Config.Greeting = \"Gr\u00C3\u00B6\u00C3\u009Fe \\\"x\\\" \\\\ y\"\n"),      // the UTF-8 bytes of Typed
                ("Config.Empty = \"\"\n", "Config.Empty = \"full\"\n"), ("Config.Hotkey = \"CTRL+Y\"\n", "Config.Hotkey = \"\"\n"),
                ("Config.Other = \"\"\n", "Config.Other = \"CTRL+NUM_FIVE\"\n"), ("Config.Last = true\n", "Config.Last = false\n"));
            XpTheirs = Swap(XpSaved, ("Config.Multiplier = 4.0\n", "Config.Multiplier = 2.5 -- set in the game\n")) + "-- a line of the player\n";
            XpMerged = Swap(XpTheirs, ("Config.LogGains = true\n", "Config.LogGains = false\n"));
            GeneralTheirs = Swap(GeneralSaved, ("Config.NoteSeconds = 7\n", "Config.NoteSeconds = 9\n"));
            GeneralTheirsLater = Swap(GeneralTheirs, ("Config.NoteSeconds = 9\n", "Config.NoteSeconds = 4\n"));
            GeneralMerged = Swap(GeneralTheirsLater, ("Config.NoteStyle = \"subtitle\"\n", "Config.NoteStyle = \"off\"\n"));
            XpDefaults = XpShipped + "-- a line of the player\n";
            GeneralRepaired = Swap(GeneralShipped, ("Config.NoteSeconds = 3\n", "Config.NoteSeconds = 5\n"));
            SecondDefault = ModuleSchema.FromText(SecondSchema).DefaultText();
            SecondSaved = Swap(SecondDefault, ("Config.Whole = 2\n", "Config.Whole = 4\n"));
        }

        /// <summary>The hints and notes on the page All kinds, from top to bottom (notes: the notes of the module allkinds).</summary>
        public static IEnumerable<string> AllTexts(IEnumerable<string> notes) => new[] { FirstHint, SecondNote, SecondHint }.Concat(notes);

        private string Swap(string text, params (string From, string To)[] lines)
        {
            foreach (var (from, to) in lines)
            {
                int at = text.IndexOf(from, StringComparison.Ordinal);
                if (at < 0 || text.IndexOf(from, at + 1, StringComparison.Ordinal) >= 0) Missing.Add(from.TrimEnd('\n'));
                text = text.Replace(from, to, StringComparison.Ordinal);
            }
            return text;
        }

        /// <summary>The values the UI test sets before its first Save, as the pages hand them to a module.</summary>
        public static Dictionary<string, object?> FirstEdits(string module) => module switch
        {
            "xp" => new() { ["Multiplier"] = 4.0, ["LargeGainFrom"] = 250.0, ["ShowMessage"] = false, ["LogGains"] = true },
            "general" => new() { ["NoteStyle"] = "subtitle", ["NoteSeconds"] = 7.0 },
            "second" => new(),          // nothing: its file must not be written
            "markers" => new(),         // nothing either
            _ => new()
            {
                ["Feature"] = true, ["Whole"] = 995.0, ["Tenth"] = 2.3, ["Fine"] = -1.0, ["Large"] = 100000000.0, ["Mode"] = "the third and longest of the choices",
                ["Greeting"] = ByteText.FromUnicode(Typed), ["Empty"] = "full", ["Hotkey"] = "", ["Other"] = "CTRL+NUM_FIVE", ["Last"] = false,
            },
        };
    }

    // The way of the UI test (SchemaPageChecks) through its megamod, without the window: what is on the tabs, the
    // values the test sets, and the files after every Save - against the same expectations (Walk).
    private static void WalkChecks(Report r, Fixtures fx, string dir)
    {
        string root = Path.Combine(dir, "walk");
        string repopulate = Path.Combine(root, "modules", "repopulate", "Scripts", "config.lua");
        Directory.CreateDirectory(Path.GetDirectoryName(repopulate)!);
        File.WriteAllText(repopulate, new Settings().ToLua());
        WriteTestModules(root);
        var w = new Walk(fx);
        r.Check(w.Missing.Count == 0, "the files the UI test (--uitest) expects are made from the default texts by replacing lines"
            + (w.Missing.Count > 0 ? " - not there exactly once: " + string.Join("; ", w.Missing) : ""));

        var mega = MegaMod.Find(repopulate) ?? throw new InvalidOperationException("the megamod of the UI test is not found");
        var nav = NavModel.Build(mega);
        string tabs = nav.Describe();
        if (tabs != Walk.Layout)
        {
            r.Check(false, "the megamod of the UI test has the layout " + Walk.Layout + " - not: " + tabs);
            return;
        }
        NavTab page(string key) => nav.Find(key) ?? throw new InvalidOperationException("no tab " + key);
        string boxes(string key) => string.Join(" | ", page(key).Groups.Select(g => g.Title));
        // the hints and notes of a tab from top to bottom
        List<string> texts(string key) => page(key).Rows.SelectMany(x => x.Group == null ? x.Module.Schema!.Notes : x.Group.Hint.Length > 0 ? new List<string> { x.Group.Hint } : new List<string>()).ToList();
        var modules = nav.ShownModules();
        if (string.Join(", ", modules.Select(m => m.Name)) != Walk.Modules)
        {
            r.Check(false, "the megamod of the UI test has the modules " + Walk.Modules + " on its tabs - not: " + string.Join(", ", modules.Select(m => m.Name)));
            return;
        }
        ModuleSettings general = modules.First(m => m.Name == "general"), xp = modules.First(m => m.Name == "xp"), all = modules.First(m => m.Name == "allkinds"),
            second = modules.First(m => m.Name == "second"), markers = modules.First(m => m.Name == "markers");
        var layoutProblems = nav.Problems(mega);
        r.Check(boxes(Walk.All) == Walk.AllBoxes && boxes(Walk.Experience) == Walk.XpBoxes && boxes(Walk.General) == Walk.GeneralBoxes
            && texts(Walk.All).SequenceEqual(Walk.AllTexts(all.Schema!.Notes)) && all.Schema.Notes.Count == 2 && texts(Walk.Experience).Count == 4 && texts(Walk.General).Count == 2
            && page(Walk.Broken).Problem == Walk.BrokenSentence && !page(Walk.Broken).Groups.Any() && layoutProblems.Count == 0,
            "the megamod of the UI test: the layout " + tabs + " with the group boxes, hints and notes the UI test looks for; two modules share a tab - "
            + "the group of the second stands among the groups of the first by its Order, its note below its group"
            + (layoutProblems.Count > 0 ? " - layout: " + string.Join("; ", layoutProblems) : ""));

        SchemaItem item(ModuleSettings m, string key) => m.Schema!.ByKey[key];
        bool allowed(ModuleSettings m, string key, params object[] values) => values.All(v => SettingsRules.Same(SettingsRules.Checked(item(m, key), v, out bool corrected), v) && !corrected);
        bool number(string key, double min, double max, decimal step, int decimals, double standard)
        {
            var i = item(all, key);
            return i.Kind == ItemKind.Number && i.Min == min && i.Max == max && i.Step == step && i.Decimals == decimals && SettingsRules.Same(i.Default, standard);
        }
        string needs = string.Join(" ", all.Schema!.Items.Where(i => i.Needs != null).Select(i => i.Key + "<" + i.Needs));
        r.Check(allowed(xp, "Multiplier", 4.0, 2.5, 7.0, 1.0) && allowed(xp, "LargeGainFrom", 250.0, 0.0) && allowed(general, "NoteSeconds", 7.0, 9.0, 4.0, 5.0, 3.0)
            && allowed(general, "NoteStyle", "box", "subtitle", "off")
            && number("Whole", -10, 1000, 5, 0, 5) && number("Tenth", 0, 10, 0.5m, 1, 1.5) && number("Fine", -1, 1, 0.005m, 3, 0.125) && number("Large", 1, 100000000, 1000, 0, 50000)
            && allowed(all, "Whole", 995.0) && allowed(all, "Tenth", 2.3) && allowed(all, "Fine", -1.0) && allowed(all, "Large", 100000000.0)
            && item(all, "Mode").Options.SequenceEqual(new[] { "first", "second choice", "the third and longest of the choices" }) && (string)item(all, "Mode").Default! == "second choice"
            && (string)item(all, "Greeting").Default! == "say \"hi\" \\ there" && (string)item(all, "Hotkey").Default! == "CTRL+Y" && (string)item(all, "Other").Default! == ""
            && needs == "Feature<Enabled Tenth<Feature Fine<Enabled Greeting<Enabled Other<Feature"
            && item(second, "Whole").Needs == "Enabled" && allowed(second, "Whole", 4.0, 2.0) && SettingsRules.Same(item(second, "Enabled").Default, true),
            "its schemas allow the values the UI test sets and have the switches it greys with (Needs): " + needs + "; the second module has keys of the same names (Enabled, Whole)");

        // the first Save
        foreach (var m in modules) m.Load();
        bool before = all.FileProblem == ModuleSettings.NotThere && second.FileProblem == ModuleSettings.NotThere && xp.FileProblem == null && general.FileProblem == null
            && markers.Described && markers.FileProblem == null && modules.All(m => m.Warnings.Count == 0);
        var written = modules.Where(m => m.Save(Walk.FirstEdits(m.Name), out _)).Select(m => m.Name).ToList();
        string path(string module) => Path.Combine(root, "modules", module, "Scripts", "config.lua");
        string? xpNow = ByteTextOf(xp.ConfigPath), generalNow = ByteTextOf(general.ConfigPath), allNow = ByteTextOf(all.ConfigPath);
        r.Check(before && written.SequenceEqual(new[] { "xp", "general", "allkinds" }) && xpNow == w.XpSaved && generalNow == w.GeneralSaved && allNow == w.AllSaved
            && ByteTextOf(xp.ConfigPath + ".bak") == w.XpShipped && ByteTextOf(general.ConfigPath + ".bak") == w.GeneralShipped && !File.Exists(all.ConfigPath + ".bak")
            && new[] { "xp", "general", "allkinds", "second", "broken", "markers" }.All(n => !File.Exists(path(n) + ".tmp")) && !File.Exists(path("broken")) && !File.Exists(path("second"))
            && all.FileProblem == null && modules.All(m => !m.Save(Walk.FirstEdits(m.Name), out _)) && ByteTextOf(xp.ConfigPath + ".bak") == w.XpShipped,
            "the first Save of the UI test: the three files are the default texts with the edited lines (a typed text as UTF-8), the previous files are kept as .bak, "
            + "nothing is written for the module nobody touched, saving again writes nothing"
            + (xpNow != w.XpSaved ? "; xp: " + Short(xpNow, 600) : "") + (generalNow != w.GeneralSaved ? "; general: " + Short(generalNow, 600) : "") + (allNow != w.AllSaved ? "; allkinds: " + Short(allNow, 1500) : ""));

        // the other side writes too
        WriteByteText(xp.ConfigPath, w.XpTheirs);
        bool oneLine = xp.Save(new Dictionary<string, object?> { ["LogGains"] = false }, out var changed) && changed.SequenceEqual(new[] { "LogGains" })
            && ByteTextOf(xp.ConfigPath) == w.XpMerged && SettingsRules.Same(xp.Values["Multiplier"], 2.5);
        WriteByteText(general.ConfigPath, w.GeneralTheirs);
        bool reread = general.Reread() && SettingsRules.Same(general.Values["NoteSeconds"], 9.0) && !general.Reread();
        WriteByteText(general.ConfigPath, w.GeneralTheirsLater);
        bool merged = general.Save(new Dictionary<string, object?> { ["NoteStyle"] = "off" }, out _) && ByteTextOf(general.ConfigPath) == w.GeneralMerged && SettingsRules.Same(general.Values["NoteSeconds"], 4.0);
        r.Check(oneLine && reread && merged,
            $"the other side writes the files too: Save changes its own line only ({oneLine}), a file that changed is read again ({reread}), the changes of both sides end up in the file ({merged})");
        bool own = second.Save(new Dictionary<string, object?> { ["Whole"] = 4.0 }, out _) && ByteTextOf(second.ConfigPath) == w.SecondSaved && ByteTextOf(all.ConfigPath) == w.AllSaved
            && SettingsRules.Same(all.Values["Whole"], 995.0);
        r.Check(own, "two modules on one page with keys of the same name: a value of the second module goes into its own file, the first module's file and value stay");

        // Revert, then Defaults (every shown setting that is not at its default) and Save
        foreach (var m in modules) m.Load();
        bool reverted = SettingsRules.Same(xp.Values["Multiplier"], 2.5) && SettingsRules.Same(all.Values["Greeting"], ByteText.FromUnicode(Walk.Typed));
        foreach (var m in modules)
            m.Save(m.Schema!.Items.Where(i => i.Shown && !SettingsRules.Same(m.Values[i.Key], i.Default)).ToDictionary(i => i.Key, i => (object?)i.Default, StringComparer.Ordinal), out _);
        r.Check(reverted && ByteTextOf(xp.ConfigPath) == w.XpDefaults && ByteTextOf(general.ConfigPath) == w.GeneralShipped && ByteTextOf(all.ConfigPath) == w.AllDefault
            && ByteTextOf(second.ConfigPath) == w.SecondDefault,
            "Revert reads the files again; Defaults and Save make them the default texts again - the player's own line stays");

        // a config.lua with an error
        WriteByteText(general.ConfigPath, Walk.Garbage);
        general.Load();
        string problem = general.FileProblem ?? "";
        bool said = problem.StartsWith(Walk.ErrorStart, StringComparison.Ordinal) && general.Schema!.Items.All(i => SettingsRules.Same(general.Values[i.Key], i.Default))
            && ByteTextOf(general.ConfigPath) == Walk.Garbage;
        bool repaired = general.Save(new Dictionary<string, object?> { ["NoteSeconds"] = 5.0 }, out _) && ByteTextOf(general.ConfigPath) == w.GeneralRepaired
            && ByteTextOf(general.ConfigPath + ".bak") == Walk.Garbage && general.FileProblem == null;
        r.Check(said && repaired, "a config.lua with an error: the defaults are used and the file is left alone; a changed value replaces it by the default text with that value "
            + "(the file with the error is kept as .bak): " + problem);
    }

#if !FILETESTS
    // =====================================================================
    // the pages made from schemas, in the real window (--uitest)
    // =====================================================================
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    // one notch of the mouse wheel on a control, as Windows delivers it (up = away from the user)
    private static void Wheel(Control control, bool up) =>
        SendMessage(control.Handle, 0x020A, (IntPtr)unchecked((int)(up ? 0x00780000 : 0xFF880000)), IntPtr.Zero);

    private static void SchemaPageChecks(Report r, MainForm form, string root, string dir)
    {
        try
        {
            var w = new Walk(Fixtures.Parse(Fixtures.EmbeddedText()));
            string PathOf(string module) => Path.Combine(root, "modules", module, "Scripts", "config.lua");

            form.ShowForTest();
            var g = form.Generic;
            T Input<T>(string module, string key) where T : Control =>
                g.Find(module, key)?.Input as T ?? throw new InvalidOperationException($"the setting {module}.{key} has no {typeof(T).Name}");

            // ---- 1. the pages and their controls
            r.Check(form.Nav.Describe() == Walk.Layout && form.Text == "G1R_MegaMod Settings" && string.Join(", ", g.Modules.Select(m => m.Name)) == Walk.Modules
                && form.CurrentPage == "Overview/Overview" && form.Pane.Chosen?.Text == "Overview"
                && form.Pane.Boxes[0].Entries.Select(e => e.Text).SequenceEqual(form.Nav.Categories.Select(c => c.Title)),
                "the window: a pane on the left with the categories, the tabs of the chosen one on the right - the overview first; the tabs made from schemas where the layout puts them "
                + "(xp under Hero, the map pins under Map, general under Interface, the test module's page All kinds - which two modules share - and the module with the broken schema in categories of their own): "
                + form.Nav.Describe() + $" [title \"{form.Text}\", modules {string.Join(", ", g.Modules.Select(m => m.Name))}, page {form.CurrentPage}, chosen {form.Pane.Chosen?.Text}, "
                + $"pane {string.Join(", ", form.Pane.Boxes[0].Entries.Select(e => e.Text))}]");
            var wrong = new List<string>();
            int count = 0;
            foreach (var m in g.Modules)
                foreach (var group in m.Schema!.Groups)
                    foreach (var item in group.Items)
                    {
                        var ui = g.Find(m.Name, item.Key);
                        string id = m.Name + "." + item.Key;
                        if (!item.Shown)
                        {
                            if (ui != null) wrong.Add(id + " is shown, but is hidden or an action");
                            continue;
                        }
                        count++;
                        if (ui == null) { wrong.Add(id + " has no control"); continue; }
                        var labels = ui.Row.OfType<Label>().Select(l => l.Text).ToList();
                        bool labelled = labels.Contains(item.Label) && (item.Unit.Length == 0 || labels.Contains(item.Unit));
                        bool ok = item.Kind switch
                        {
                            ItemKind.Bool => ui.Input is XpCheckBox box && box.Text == SchemaPages.Amp(item.Label) && box.Checked == (bool)item.Default!,
                            ItemKind.Number => ui.Input is XpNumericUpDown n && n.Minimum == (decimal)item.Min && n.Maximum == (decimal)item.Max && n.Increment == item.Step
                                && n.DecimalPlaces == item.Decimals && n.Value == (decimal)(double)item.Default! && labelled,
                            ItemKind.Choice => ui.Input is XpComboBox c && c.DropDownStyle == ComboBoxStyle.DropDownList && c.Items.Cast<object>().Select(o => o.ToString()).SequenceEqual(item.OptionLabels.Select(SchemaPages.Amp))
                                && c.SelectedIndex == item.Options.IndexOf((string)item.Default!) && labelled,
                            ItemKind.Text => ui.Input is XpTextBox t && t.Box.Text == ByteText.ToUnicode((string)item.Default!) && labelled,
                            _ => ui.Input is XpKeyBox k && k.Value == (string)item.Default! && ui.Clear != null && ui.Clear.Text == "Clear" && ui.Hint != null && labelled,
                        };
                        if (!ok) wrong.Add(id + ": not the control its schema asks for (" + ui.Input.GetType().Name + ")");
                        else if (form.TipOf(ui.Input) != SchemaPages.Amp(item.Comment)) wrong.Add(id + ": its tool tip is not its comment");
                        else if (ui.Row.OfType<Label>().Any(l => l.UseMnemonic)) wrong.Add(id + ": an & in its label would be taken for the mark of a shortcut key");
                        else if (!ui.Row.Contains(ui.Input)) wrong.Add(id + ": the control is not in its row");
                    }
            Cases(r, count, wrong, "settings of the test modules: each has its control - a check box with its label; a number box with Min, Max, Step, Decimals and the unit behind it; "
                + "a drop-down list with the options; a text box; a key box with a Clear button - showing the default, with the comment as tool tip (an & in a text is an ampersand: "
                + "doubled where the control paints its text itself); hidden settings and actions have none");

            var pages = g.Pages.ToDictionary(p => p.Model.Key);
            var all = pages[Walk.All];
            var allkinds = g.Modules.First(m => m.Name == "allkinds");
            string Boxes(string title) => string.Join(" | ", pages[title].Groups.Select(b => b.Text));
            r.Check(Boxes(Walk.All) == Walk.AllBoxes && Boxes(Walk.Experience) == Walk.XpBoxes && Boxes(Walk.General) == Walk.GeneralBoxes,
                "group boxes: one per group that shows something, in the order of the groups' Order - the group of the second module among those of the first; a group of hidden settings has none");
            // (the labels of a page in the order they were made = from top to bottom)
            r.Check(all.Texts.Select(l => l.Text).SequenceEqual(Walk.AllTexts(allkinds.Schema!.Notes))
                && all.Groups[0].Controls.Count == 1 && all.Groups[0].Controls[0] is TableLayoutPanel firstGroup && firstGroup.Controls[0] == all.Texts[0]
                && all.Texts[1].Parent is TableLayoutPanel secondNotes && secondNotes.Parent == all.Groups[1].Parent
                && secondNotes.Parent!.Controls.GetChildIndex(secondNotes) == secondNotes.Parent.Controls.GetChildIndex(all.Groups[1]) + 1
                && pages[Walk.Experience].Texts.Count == 4 && pages[Walk.General].Texts.Count == 2,
                "the hint of a group is the first line in its box; the notes of a module stand below the last of its groups (the note of the second module right below its box)");
            var brokenPage = pages[Walk.Broken];
            r.Check(brokenPage.Scroll == null && brokenPage.Texts.Count == 1 && brokenPage.Texts[0].Text == Walk.BrokenSentence
                && !MainForm.Descendants(brokenPage.Tab).Any(c => c is ButtonBase || c is UpDownBase || c is TextBoxBase || c is ListControl || c is XpKeyBox),
                "the page of the module with the broken schema says in one sentence what is wrong and has no controls: " + brokenPage.Texts[0].Text);
            r.Check(all.FileNotes[allkinds].Text == "Module allkinds: config.lua is not there yet - the default values are shown. It is written when you change a value and save."
                && all.FileNotes.Count == 2 && all.FileNotes.Values.Count(l => l.Text.StartsWith("Module second: config.lua is not there yet", StringComparison.Ordinal)) == 1
                && pages[Walk.Experience].FileNotes.Values.All(l => l.Text.Length == 0) && pages[Walk.General].FileNotes.Values.All(l => l.Text.Length == 0)
                && g.Pages.Sum(p => p.FileNotes.Count) == g.Modules.Count,
                "a module without a config.lua says so on the tab that is its own (every module has one such place): " + all.FileNotes[allkinds].Text);

            // ---- 2. Needs
            form.SelectPage(Walk.All);
            var enabled = Input<XpCheckBox>("allkinds", "Enabled");
            var feature = Input<XpCheckBox>("allkinds", "Feature");
            var whole = Input<XpNumericUpDown>("allkinds", "Whole");
            var tenth = Input<XpNumericUpDown>("allkinds", "Tenth");
            var fine = Input<XpNumericUpDown>("allkinds", "Fine");
            var large = Input<XpNumericUpDown>("allkinds", "Large");
            var mode = Input<XpComboBox>("allkinds", "Mode");
            var greeting = Input<XpTextBox>("allkinds", "Greeting");
            var empty = Input<XpTextBox>("allkinds", "Empty");
            var hotkey = Input<XpKeyBox>("allkinds", "Hotkey");
            var other = Input<XpKeyBox>("allkinds", "Other");
            var last = Input<XpCheckBox>("allkinds", "Last");
            bool GreyOf(string module, string key) => g.Find(module, key)!.Row.All(c => c is Label ? c.ForeColor == Xp.DisabledText : !c.Enabled);
            bool LiveOf(string module, string key) => g.Find(module, key)!.Row.All(c => c is Label ? c.ForeColor != Xp.DisabledText : c.Enabled);
            bool Grey(string key) => GreyOf("allkinds", key);
            bool Live(string key) => LiveOf("allkinds", key);
            bool start = Live("Enabled") && Live("Feature") && Live("Plain") && Live("Whole") && Grey("Tenth") && Live("Fine") && Live("Greeting") && Live("Hotkey") && Grey("Other");
            feature.Checked = true;
            bool featureOn = Live("Tenth") && Live("Other") && form.Text == "G1R_MegaMod Settings *";
            enabled.Checked = false;
            bool allOff = Grey("Feature") && Grey("Fine") && Grey("Greeting") && Grey("Tenth") && Grey("Other") && Live("Whole") && Live("Plain") && Live("Hotkey") && Live("Enabled");
            // the second module has a switch of the same name: each module's settings go by its own
            var secondEnabled = Input<XpCheckBox>("second", "Enabled");
            bool ownSwitch = LiveOf("second", "Whole") && LiveOf("second", "Enabled");
            enabled.Checked = true;
            secondEnabled.Checked = false;
            ownSwitch = ownSwitch && GreyOf("second", "Whole") && Live("Feature") && Live("Fine");
            secondEnabled.Checked = true;
            feature.Checked = false;
            bool back = Live("Feature") && Grey("Tenth") && Live("Fine") && Grey("Other") && LiveOf("second", "Whole") && !g.HasChanges;
            r.Check(start && featureOn && allOff && ownSwitch && back,
                $"Needs: a setting is greyed (its control off, its labels grey) while its switch is off, and while that switch is itself greyed - at the start {start}, feature on {featureOn}, "
                + $"the main switch off {allOff}, the switch of the same name in the other module on the page is another one {ownSwitch}, back {back}; the first change puts the star into the title");

            // ---- 3. values changed through the controls (what the modules get of this: Walk.FirstEdits)
            Input<XpNumericUpDown>("xp", "Multiplier").Value = 4.0m;
            Input<XpNumericUpDown>("xp", "LargeGainFrom").Value = 250;
            Input<XpCheckBox>("xp", "ShowMessage").Checked = false;
            Input<XpCheckBox>("xp", "LogGains").Checked = true;
            var style = Input<XpComboBox>("general", "NoteStyle");
            style.SelectedIndex = style.Items.IndexOf("subtitle");
            var seconds = Input<XpNumericUpDown>("general", "NoteSeconds");
            seconds.Value = 7;
            feature.Checked = true;
            whole.Value = 995;
            tenth.Value = 2.26m;            // one place: shown and taken as 2.3
            fine.Value = -0.9995m;          // three places: -1.000
            large.Value = 100000000;
            mode.SelectedIndex = 2;
            greeting.Box.Text = Walk.Typed;
            empty.Box.Text = "full";
            last.Checked = false;
            bool ranges = whole.Minimum == -10 && whole.Maximum == 1000 && whole.Increment == 5 && tenth.Maximum == 10 && fine.Minimum == -1 && large.Maximum == 100000000;

            // the key boxes
            var otherUi = g.Find("allkinds", "Other")!;
            other.StartListening();
            bool listening = other.Listening && other.ShownText == "Press a key ...";
            bool modifierOnly = !other.TakeKey(Keys.ControlKey | Keys.Control) && other.Listening && other.ShownText == "CTRL+...";
            bool windowsKey = !other.TakeKey(Keys.LWin) && other.Listening && other.Hint.Contains("Windows keys cannot be bound") && otherUi.Hint!.Text == other.Hint;
            bool noName = !other.TakeKey(Keys.F13 | Keys.Shift) && other.Listening && other.Hint.Contains("cannot be bound") && other.Value == "";
            bool leftMouse = !other.TakeKey(Keys.LButton) && other.Listening && other.Hint.Contains("mouse buttons cannot be bound");
            bool escape = !other.TakeKey(Keys.Escape) && !other.Listening && other.Value == "" && other.Hint.Contains("Escape cannot be bound") && other.ShownText == "(no key)";
            other.StartListening();
            bool taken = other.TakeKey(Keys.NumPad5 | Keys.Control) && !other.Listening && other.Value == "CTRL+NUM_FIVE" && other.Hint == "" && otherUi.Hint!.Text == "" && other.ShownText == "CTRL+NUM_FIVE";
            bool idle = !other.TakeKey(Keys.A) && other.Value == "CTRL+NUM_FIVE";
            hotkey.StartListening();
            bool threeModifiers = hotkey.TakeKey(Keys.F5 | Keys.Alt | Keys.Shift | Keys.Control) && hotkey.Value == "CTRL+SHIFT+ALT+F5";
            hotkey.StartListening();
            bool mouseButton = hotkey.TakeKey(Keys.MButton | Keys.Shift) && hotkey.Value == "SHIFT+MIDDLE_MOUSE_BUTTON";
            hotkey.StartListening();
            bool tabKey = hotkey.TakeKey(Keys.Tab) && hotkey.Value == "TAB";
            hotkey.StartListening();
            g.Find("allkinds", "Hotkey")!.Clear!.PerformClick();
            bool cleared = hotkey.Value == "" && !hotkey.Listening && hotkey.ShownText == "(no key)";
            r.Check(listening && modifierOnly && windowsKey && noName && leftMouse && escape && taken && idle && threeModifiers && mouseButton && tabKey && cleared,
                $"key box: listens after a click ({listening}); CTRL alone is not a key yet ({modifierOnly}); the Windows key ({windowsKey}), a key without a name ({noName}) and the left mouse button "
                + $"({leftMouse}) are refused with a hint and the box keeps listening; Escape gives up and leaves the key as it was ({escape}); CTRL + numpad 5 is taken as CTRL+NUM_FIVE ({taken}); "
                + $"a key pressed while the box does not listen is not taken ({idle}); CTRL+SHIFT+ALT+F5 in that order ({threeModifiers}); the middle mouse button ({mouseButton}); Tab ({tabKey}); "
                + $"the Clear button sets no key ({cleared})");

            // ---- 4. Save: the files
            bool noteBefore = all.FileNotes[allkinds].Text.Length > 0;
            bool saved = form.SaveFile();
            r.Check(w.Missing.Count == 0, "(the expected texts of the test are made from the default texts by replacing lines" + (w.Missing.Count > 0 ? " - not there exactly once: " + string.Join("; ", w.Missing) + ")" : ")"));
            string? xpNow = ByteTextOf(PathOf("xp")), generalNow = ByteTextOf(PathOf("general")), allNow = ByteTextOf(PathOf("allkinds"));
            r.Check(saved && xpNow == w.XpSaved, "Save: config.lua of xp is the shipped file with four lines changed (Multiplier 4.0, LargeGainFrom 250, ShowMessage false, LogGains true)"
                + (xpNow == w.XpSaved ? "" : ": " + Short(xpNow, 600)));
            r.Check(generalNow == w.GeneralSaved, "Save: config.lua of general is the shipped file with two lines changed (NoteStyle \"subtitle\", NoteSeconds 7)" + (generalNow == w.GeneralSaved ? "" : ": " + Short(generalNow, 600)));
            r.Check(allNow == w.AllSaved, "Save: config.lua of the module with every kind did not exist and is now the default text with eleven values put in "
                + "(switches, 995, 2.3 for a typed 2.26, -1.0 for a typed -0.9995, 100000000, a choice, a text with umlauts and quotes as UTF-8, a text, no key, CTRL+NUM_FIVE)"
                + (allNow == w.AllSaved ? "" : ": " + Short(allNow, 1500)));
            r.Check(ranges && ByteTextOf(PathOf("xp") + ".bak") == w.XpShipped && ByteTextOf(PathOf("general") + ".bak") == w.GeneralShipped && !File.Exists(PathOf("allkinds") + ".bak")
                && new[] { "xp", "general", "allkinds", "second", "broken", "markers" }.All(m => !File.Exists(PathOf(m) + ".tmp")) && !File.Exists(PathOf("broken")) && !File.Exists(PathOf("second")),
                "the previous files are kept as config.lua.bak, no temporary file is left, nothing is written for the module with the broken schema and for the module nobody touched");
            r.Check(form.LastWritten.SequenceEqual(new[] { "xp", "general", "allkinds" }) && form.Text == "G1R_MegaMod Settings" && form.StatusText.Contains("Also saved: xp, general, allkinds.")
                && !g.HasChanges && tenth.Value == 2.3m && fine.Value == -1m && hotkey.Value == "" && noteBefore && all.FileNotes[allkinds].Text.Length == 0,
                "after Save: the star is gone, the status names the modules that were written, the controls show what is in the files, the note about the missing file is gone: " + form.StatusText);

            bool again = form.SaveFile();
            r.Check(again && form.LastWritten.Count == 0 && ByteTextOf(PathOf("xp")) == w.XpSaved && ByteTextOf(PathOf("xp") + ".bak") == w.XpShipped && ByteTextOf(PathOf("allkinds")) == w.AllSaved
                && !File.Exists(PathOf("allkinds") + ".bak") && !form.StatusText.Contains("Also saved"),
                "Save without a change on these pages does not write their files again");
            var secondWhole = Input<XpNumericUpDown>("second", "Whole");
            secondWhole.Value = 4;
            saved = form.SaveFile();
            r.Check(saved && form.LastWritten.SequenceEqual(new[] { "second" }) && ByteTextOf(PathOf("second")) == w.SecondSaved && ByteTextOf(PathOf("allkinds")) == w.AllSaved && whole.Value == 995
                && all.FileNotes.Values.All(l => l.Text.Length == 0),
                "two modules on one page with keys of the same name: a value of the second module goes into its own file (written now for the first time), the first module's file and value stay");

            // ---- 5. the other side (the game's menu, an editor) writes a file too
            WriteByteText(PathOf("xp"), w.XpTheirs);
            Input<XpCheckBox>("xp", "LogGains").Checked = false;
            saved = form.SaveFile();
            r.Check(saved && ByteTextOf(PathOf("xp")) == w.XpMerged && form.LastWritten.SequenceEqual(new[] { "xp" }) && Input<XpNumericUpDown>("xp", "Multiplier").Value == 2.5m,
                "a file that changed on disk since the app read it: Save changes its own line only - the other side's value and comments stay - and the page shows the other side's value afterwards");
            WriteByteText(PathOf("general"), w.GeneralTheirs);
            form.ComeToFront();
            bool reread = seconds.Value == 9 && form.Text == "G1R_MegaMod Settings" && form.StatusText.Contains("Read again") && form.StatusText.Contains("general");
            style.SelectedIndex = style.Items.IndexOf("off");
            WriteByteText(PathOf("general"), w.GeneralTheirsLater);
            form.ComeToFront();
            bool kept = seconds.Value == 9 && style.SelectedIndex == style.Items.IndexOf("off") && form.Text == "G1R_MegaMod Settings *";
            saved = form.SaveFile();
            r.Check(reread && kept && saved && ByteTextOf(PathOf("general")) == w.GeneralMerged && seconds.Value == 4,
                $"when the window comes to the front, a module whose file changed outside the app is read again ({reread}) - not while it has unsaved changes here ({kept}); those are merged by Save");

            // ---- 6. Revert and Defaults
            Input<XpNumericUpDown>("xp", "Multiplier").Value = 7;
            greeting.Box.Text = "something else";
            bool dirty = form.Text == "G1R_MegaMod Settings *" && g.HasChanges;
            form.PressRevert();
            r.Check(dirty && form.Text == "G1R_MegaMod Settings" && !g.HasChanges && Input<XpNumericUpDown>("xp", "Multiplier").Value == 2.5m && greeting.Box.Text == Walk.Typed
                && ByteTextOf(PathOf("general")) == w.GeneralMerged, "Revert reads the files again and throws the changes on these pages away (nothing is written)");
            form.PressDefaults();
            bool defaultsShown = g.HasChanges && form.Text == "G1R_MegaMod Settings *" && Input<XpNumericUpDown>("xp", "Multiplier").Value == 1.0m && seconds.Value == 3 && !feature.Checked
                && whole.Value == 5 && mode.SelectedIndex == 1 && greeting.Box.Text == "say \"hi\" \\ there" && hotkey.Value == "CTRL+Y" && other.Value == "" && last.Checked
                && secondWhole.Value == 2 && ByteTextOf(PathOf("general")) == w.GeneralMerged;
            saved = form.SaveFile();
            r.Check(defaultsShown && saved && ByteTextOf(PathOf("xp")) == w.XpDefaults && ByteTextOf(PathOf("general")) == w.GeneralShipped && ByteTextOf(PathOf("allkinds")) == w.AllDefault
                    && ByteTextOf(PathOf("second")) == w.SecondDefault,
                "Defaults puts every setting on these pages back to its default (nothing is written until Save); after Save the files are the default texts again - the player's own line stays");

            // ---- 7. a config.lua with an error
            WriteByteText(PathOf("general"), Walk.Garbage);
            form.PressRevert();
            string note = pages[Walk.General].FileNotes.Values.First().Text;
            bool said = note.StartsWith("Module general: " + Walk.ErrorStart, StringComparison.Ordinal) && note.Contains("the default values are shown") && seconds.Value == 3
                && form.StatusText.Contains("the settings file of general needs a look");
            bool untouchedFile = ByteTextOf(PathOf("general")) == Walk.Garbage;
            seconds.Value = 5;
            saved = form.SaveFile();
            r.Check(said && untouchedFile && saved && ByteTextOf(PathOf("general")) == w.GeneralRepaired
                && ByteTextOf(PathOf("general") + ".bak") == Walk.Garbage && pages[Walk.General].FileNotes.Values.First().Text.Length == 0,
                "a config.lua with an error: the page says so and shows the defaults, the file is left alone; a changed value replaces it by the default text with that value (the broken file is kept as .bak): " + note);

            // ---- 8. scrolling, the top bar
            var normalSize = form.Size;
            form.Size = form.MinimumSize;
            form.SelectPage(Walk.All);
            Application.DoEvents();
            var scroll = all.Scroll!;
            scroll.Arrange();
            var content = scroll.Controls.OfType<TableLayoutPanel>().First();
            int furthest = scroll.ContentHeight - scroll.ClientSize.Height;
            bool scrolls = scroll.Scrolls && scroll.Bar.Visible && furthest > 0 && scroll.Offset == 0 && content.Top == 0 && content.Width == scroll.ClientSize.Width - scroll.Bar.Width;
            decimal wholeBefore = whole.Value;
            int modeBefore = mode.SelectedIndex;
            Wheel(whole, up: false);
            int afterNumber = scroll.Offset;
            Wheel(mode, up: false);
            int afterList = scroll.Offset;
            bool wheelDown = afterNumber > 0 && afterList >= afterNumber && content.Top == -scroll.Offset && whole.Value == wholeBefore && mode.SelectedIndex == modeBefore;
            Wheel(enabled, up: true);
            Wheel(enabled, up: true);
            Wheel(enabled, up: true);
            bool wheelUp = scroll.Offset == 0 && content.Top == 0;
            // a control is inside the part of the page that can be seen
            bool Inside(Control control)
            {
                int top = 0;
                for (Control? c = control; c != null && c != content; c = c.Parent) top += c.Top;
                return top - scroll.Offset >= 0 && top + control.Height - scroll.Offset <= scroll.ClientSize.Height;
            }
            scroll.ScrollTo(int.MaxValue);
            bool toEnd = scroll.Offset == furthest && content.Top == -furthest;
            scroll.EnsureVisible(enabled);          // the first control of the page, from its end
            bool firstSeen = Inside(enabled);
            scroll.ScrollTo(0);
            scroll.EnsureVisible(last);             // the last one, from its start
            bool lastSeen = Inside(last) && scroll.Offset >= 0 && scroll.Offset <= furthest;
            scroll.ScrollTo(0);
            r.Check(scrolls && wheelDown && wheelUp && toEnd && firstSeen && lastSeen,
                $"a page longer than the window scrolls with the XP scroll bar ({scrolls}: {scroll.ContentHeight} px of content in {scroll.ClientSize.Height}); the mouse wheel over a number box or a list "
                + $"scrolls the page and leaves their values alone ({wheelDown}); the wheel over other controls scrolls too ({wheelUp}); the page scrolls to its end ({toEnd}); "
                + $"a control that gets the focus is scrolled into view - the first one from the end ({firstSeen}), the last one from the start ({lastSeen})");
            form.SelectPage("Creatures");
            bool onRepopulate = form.ScaleShown && form.PresetEnabled;
            form.SelectPage(Walk.Experience);
            bool onGeneric = !form.ScaleShown && form.PresetEnabled;
            form.SelectPage("Overview/Overview");
            bool onOverview = !form.ScaleShown && form.PresetEnabled;
            form.SelectPage("Advanced");
            r.Check(onRepopulate && onGeneric && onOverview && form.ScaleShown && form.CurrentPage == "World/Advanced",
                "the mass changes (repopulate only) stand above the tabs of the category World and nowhere else; the presets set every page and stay usable");

            // ---- 9. one image per tab
            form.Size = normalSize;
            Application.DoEvents();
            var images = form.SaveTabImages(dir, "uitest");
            r.Check(images.Count >= form.PageTitles.Count && images.All(f => new FileInfo(f).Length > 2000), $"{images.Count} images of the tabs written: " + string.Join(", ", images.Select(Path.GetFileName)));

            // ---- 10. the presets
            string repopulatePath = Path.Combine(root, "modules", "repopulate", "Scripts", "config.lua");
            var plain = Input<XpCheckBox>("allkinds", "Plain");
            var secondSpeed = Input<XpNumericUpDown>("second", "Whole");
            var xpMultiplier = Input<XpNumericUpDown>("xp", "Multiplier");
            var xpNote = Input<XpCheckBox>("xp", "ShowMessage");
            var tenthBox = tenth;
            var fineBox = fine;
            form.PressRevert();
            form.SelectPage(Walk.Experience);
            // the files are at none of the five: the box stands on its first line, and there is nothing to apply
            bool ownAtStart = form.PresetMarked == 0 && form.PresetSelected == 0 && !form.PresetApplyEnabled && form.PresetText == "Your own settings  - in use";
            decimal fineBefore = fineBox.Value, largeBefore = large.Value;
            bool xpNoteBefore = xpNote.Checked;
            string hotkeyBefore = hotkey.Value;
            form.OwnSettingsForTest("Wolf", "60", "12");       // a species with settings of its own: the presets leave it alone
            int speciesBefore = form.SettingsForTest().Species.Count;
            form.ApplyPresetForTest(4);
            var at4 = form.SettingsForTest();
            bool repopulate4 = Presets.Matches(at4, 4) && speciesBefore == 1 && at4.Species.Count == 1 && at4.Species.TryGetValue("Wolf", out var wolfKept)
                && Near(wolfKept.Chance ?? -1, 0.6) && wolfKept.EveryHours == 12;
            bool generic4 = xpMultiplier.Value == 4m && feature.Checked && !plain.Checked && whole.Value == 500 && tenthBox.Value == 5.0m && mode.SelectedIndex == 2 && secondSpeed.Value == 4;
            bool untouched4 = fineBox.Value == fineBefore && large.Value == largeBefore && xpNote.Checked == xpNoteBefore && hotkey.Value == hotkeyBefore;
            string status4 = form.StatusText;
            bool said4 = status4.StartsWith("Preset \"4 - Very easy\" set on all pages (per-species settings kept) - press Save.", StringComparison.Ordinal)
                && status4.Contains("Left out: allkinds: Fine: Tiers must be 5 values or \"default\"; allkinds: Greeting: Tiers are for yes/no, number and choice items; allkinds: Secret: a hidden item cannot have Tiers");
            bool box4 = form.PresetMarked == 4 && form.PresetSelected == 4 && form.PresetApplyEnabled && form.PresetText == "4 - Very easy  - in use";
            r.Check(ownAtStart && repopulate4 && generic4 && untouched4 && said4 && box4 && form.Text.EndsWith("*", StringComparison.Ordinal),
                $"with settings that are none of the presets the box stands on \"Your own settings\" and its button is greyed ({ownAtStart}). Apply preset 4: the repopulate pages have its values, per-species settings kept ({repopulate4}); "
                + $"every setting of the other modules that names values for the presets has its fourth ({generic4}); settings without them, notes and keys stay ({untouched4}); "
                + $"the box stands on the preset and marks it as in use ({box4}), nothing is written yet: " + status4);
            saved = form.SaveFile();
            var onDisk = Settings.FromText(File.ReadAllText(repopulatePath), new List<string>());
            string xpText = ByteTextOf(PathOf("xp")) ?? "", allText = ByteTextOf(PathOf("allkinds")) ?? "", secondText = ByteTextOf(PathOf("second")) ?? "";
            r.Check(saved && Presets.Matches(onDisk, 4) && xpText.Contains("\nConfig.Multiplier = 4.0\n") && allText.Contains("\nConfig.Feature = true\n") && allText.Contains("\nConfig.Whole = 500\n")
                && allText.Contains("\nConfig.Tenth = 5.0\n") && allText.Contains("\nConfig.Mode = \"the third and longest of the choices\"\n") && secondText.Contains("\nConfig.Whole = 4\n")
                && form.PresetMarked == 4 && form.PresetSelected == 4,
                "Save writes the preset into every module's config.lua (repopulate, xp, the two test modules); the box still marks it");
            string imageInUse = form.SaveWindowImage(Path.Combine(dir, "uitest-10-preset-in-use.png"));
            xpMultiplier.Value = 3m;
            int markedOwn = form.PresetMarked, selectedOwn = form.PresetSelected;
            bool applyOwn = form.PresetApplyEnabled;
            string imageOwn = form.SaveWindowImage(Path.Combine(dir, "uitest-10-own-settings.png"));
            xpMultiplier.Value = 4m;
            int markedBack = form.PresetMarked, selectedBack = form.PresetSelected;
            bool follows = markedOwn == 0 && selectedOwn == 0 && !applyOwn && markedBack == 4 && selectedBack == 4 && form.PresetApplyEnabled
                && new FileInfo(imageInUse).Length > 2000 && new FileInfo(imageOwn).Length > 2000;
            // a line picked by hand is the user's choice of what to apply: it stays while the settings move, and its button applies it
            form.PickPresetForTest(2);
            bool pickedOnly = form.PresetSelected == 2 && form.PresetMarked == 4 && form.PresetApplyEnabled && xpMultiplier.Value == 4m && form.PresetText == "2 - Relaxed";
            xpMultiplier.Value = 3m;
            bool pickStays = form.PresetSelected == 2 && form.PresetMarked == 0;
            xpMultiplier.Value = 4m;
            pickStays = pickStays && form.PresetSelected == 2 && form.PresetMarked == 4;
            form.PressApplyPreset();
            bool pressed = form.PresetSelected == 2 && form.PresetMarked == 2 && xpMultiplier.Value == 1.5m && Presets.Matches(form.SettingsForTest(), 2)
                && form.StatusText.StartsWith("Preset \"2 - Relaxed\" set on all pages", StringComparison.Ordinal);
            form.PickPresetForTest(0);
            form.PressApplyPreset();        // the first line is no preset: its button is greyed and does nothing
            bool ownInert = !form.PresetApplyEnabled && form.PresetMarked == 2 && xpMultiplier.Value == 1.5m;
            form.PickPresetForTest(2);
            r.Check(follows && pickedOnly && pickStays && pressed && ownInert,
                $"one changed value and the box moves to \"Your own settings\", set back it returns to the preset ({follows}: {markedOwn}/{selectedOwn}, {markedBack}/{selectedBack}); "
                + $"picking another line changes nothing by itself ({pickedOnly}) and stays picked while the settings move ({pickStays}); the button applies the picked preset ({pressed}); "
                + $"with \"Your own settings\" picked the button is greyed and does nothing ({ownInert}); images: {Path.GetFileName(imageInUse)}, {Path.GetFileName(imageOwn)}");
            form.ApplyPresetForTest(1);
            bool box1 = form.PresetMarked == 1 && form.PresetSelected == 1;
            var at1 = form.SettingsForTest();
            bool base1 = Presets.Matches(at1, 1) && !at1.CreaturesEnabled && !at1.HerbsEnabled && !at1.WorldItemsEnabled && !at1.ChestsEnabled && at1.CrimeEnabled
                && xpMultiplier.Value == 1m && !feature.Checked && whole.Value == 5 && tenthBox.Value == 1.5m && mode.SelectedIndex == 1 && secondSpeed.Value == 2;
            form.ApplyPresetForTest(5);
            var at5 = form.SettingsForTest();
            bool easiest = Presets.Matches(at5, 5) && at5.NormalChance == 1 && at5.RegrowHours == 1 && !at5.CrimeEnabled && at5.CrimeDisableTheft
                && xpMultiplier.Value == 10m && whole.Value == 1000 && tenthBox.Value == 10.0m && secondSpeed.Value == 5 && form.PresetMarked == 5 && form.PresetSelected == 5;
            form.PickPresetForTest(3);      // a line picked and not applied is forgotten by Revert
            form.PressRevert();
            r.Check(base1 && box1 && easiest && form.PresetMarked == 4 && form.PresetSelected == 4 && xpMultiplier.Value == 4m,
                $"preset 1 is the game itself - nothing comes back, the crime rules of the game, every schema setting at its default ({base1}), and the box stands on it ({box1}); "
                + $"preset 5 puts everything at its limit ({easiest}); Revert reads the files again: preset 4, and the box stands on it whatever was picked before");

            // ---- 11. the pane on the left: categories, keys, the star of unsaved changes
            form.ChooseCategory("Hero");
            bool chosen = form.CurrentPage == Walk.Experience && form.Pane.Chosen?.Text == "Hero" && !form.ScaleShown;
            form.SelectPage("World/Crime");
            form.ChooseCategory("Hero");
            form.ChooseCategory("World");
            bool remembered = form.CurrentPage == "World/Crime" && form.ScaleShown && form.Pane.Chosen?.Text == "World";
            form.ChooseCategory("Overview");
            bool keyDown = form.Pane.TakeKey(Keys.Down) && form.CurrentPage == "World/Crime" && form.Pane.TakeKey(Keys.Down) && form.CurrentPage == Walk.Experience;
            bool keyEnd = form.Pane.TakeKey(Keys.Home) && form.CurrentPage == "Overview/Overview" && form.Pane.TakeKey(Keys.Up) && form.CurrentPage == "Overview/Overview";
            bool cleanMarks = form.MarkedCategories.Count == 0 && form.Text == "G1R_MegaMod Settings";
            xpMultiplier.Value = 3m;
            bool heroMarked = form.MarkedCategories.SequenceEqual(new[] { "Hero" }) && form.Pane.Boxes[0].Entries.Single(e => e.Marked).Text == "Hero";
            whole.Value = 7;
            form.OwnSettingsForTest("Snapper", "50", "10");
            bool threeMarked = form.MarkedCategories.SequenceEqual(new[] { "World", "Hero", "All kinds" });
            xpMultiplier.Value = 4m;        // back to what the file has
            bool heroBack = form.MarkedCategories.SequenceEqual(new[] { "World", "All kinds" }) && form.Text == "G1R_MegaMod Settings *";
            form.PressRevert();
            bool marksGone = form.MarkedCategories.Count == 0 && form.Text == "G1R_MegaMod Settings";
            r.Check(chosen && remembered && keyDown && keyEnd && cleanMarks && heroMarked && threeMarked && heroBack && marksGone,
                $"the pane: choosing a category shows its tabs ({chosen}) - on the tab it was left on ({remembered}); Down goes to the next category ({keyDown}), Home to the first, Up stops there ({keyEnd}); "
                + $"a category carries a star while one of its pages shows something that is not in the files - none at first ({cleanMarks}), Hero after a change there ({heroMarked}), "
                + $"three categories after three changes ({threeMarked}), not Hero any more once its value is back ({heroBack}), none after Revert ({marksGone})");

            // ---- 12. "Defaults for this page" (pane, Page tasks)
            form.SelectPage(Walk.Experience);
            xpMultiplier.Value = 7m;
            xpNote.Checked = !xpNote.Checked;
            seconds.Value = 9;              // (the module general: another tab)
            bool canDefault = form.PageDefaultsEnabled;
            form.PressPageDefaults();
            bool thisPage = xpMultiplier.Value == 1.0m && xpNote.Checked && seconds.Value == 9 && form.StatusText == "Defaults set on the page \"Hero > Experience\" - press Save."
                && form.MarkedCategories.SequenceEqual(new[] { "Hero", "Interface" });
            form.SelectPage("World/Containers");
            form.PressPageDefaults();
            var afterContainers = form.SettingsForTest();
            bool worldPage = Near(afterContainers.SettlementDailyChance, 0.30) && Near(afterContainers.WildDailyChance, 0.10) && afterContainers.RetroactiveDays == 3
                && Near(afterContainers.NormalChance, 0.6) && afterContainers.Species.ContainsKey("Wolf") && form.MarkedCategories.Contains("World");
            form.SelectPage("World/Creatures");
            form.PressPageDefaults();
            var afterCreatures = form.SettingsForTest();
            bool creaturesPage = Near(afterCreatures.NormalChance, 0.35) && afterCreatures.Species.Count == 0 && afterCreatures.EliteSpecies.SequenceEqual(new Settings().EliteSpecies)
                && Near(afterCreatures.SettlementDailyChance, 0.30);        // (what was set on the page Containers stays)
            form.SelectPage("Overview/Overview");
            bool notOnOverview = !form.PageDefaultsEnabled;
            string statusBefore = form.StatusText;
            form.PressPageDefaults();
            notOnOverview = notOnOverview && form.StatusText == statusBefore;
            form.SelectPage(Walk.Broken);
            bool notOnProblem = !form.PageDefaultsEnabled;
            form.PressRevert();
            r.Check(canDefault && thisPage && worldPage && creaturesPage && notOnOverview && notOnProblem && xpMultiplier.Value == 4m,
                $"\"Defaults for this page\" sets the settings of the tab shown and no other - a tab made from a schema ({thisPage}), the page Containers ({worldPage}: the creatures keep the preset's values, "
                + $"the species their own), the page Creatures ({creaturesPage}: the per-species settings are cleared, the elite list is the default one); the overview ({notOnOverview}) and a page that only "
                + $"says what is wrong ({notOnProblem}) have nothing to set; nothing is written");

            // ---- 13. the overview: a switch per part of the mod, the same one as on the part's page
            form.SelectPage("Overview/Overview");
            var switches = form.OverviewSwitches;
            var xpMain = Input<XpCheckBox>("xp", "Enabled");
            var xpSwitch = switches.FirstOrDefault(x => x.There == xpMain);
            bool four = switches.Count == 4 && xpSwitch.Here != null && switches.Count(x => x.There == enabled || x.There == secondEnabled) == 2
                && switches.All(x => x.Here.Checked == x.There.Checked);
            bool was = xpMain.Checked;
            xpSwitch.Here!.Checked = !was;
            bool thereFollows = xpMain.Checked == !was && form.Text == "G1R_MegaMod Settings *" && form.MarkedCategories.SequenceEqual(new[] { "Hero" });
            xpMain.Checked = was;
            bool hereFollows = xpSwitch.Here.Checked == was && form.MarkedCategories.Count == 0;
            bool modWas = form.SettingsForTest().Enabled;
            switches[0].Here.Checked = !modWas;
            bool modFollows = form.SettingsForTest().Enabled == !modWas && switches[0].There.Checked == !modWas && form.MarkedCategories.SequenceEqual(new[] { "World" });
            form.PressRevert();
            bool rereadSwitches = switches.All(x => x.Here.Checked == x.There.Checked) && switches[0].Here.Checked == modWas && form.MarkedCategories.Count == 0;
            bool presetLines = form.OverviewPresetText == "Preset in use: 4 - Very easy." && form.DetailPresetText == "Preset 4 - Very easy";
            xpMultiplier.Value = 3m;
            presetLines = presetLines && form.OverviewPresetText == "Your own settings (none of the five presets)." && form.DetailPresetText == "Your own settings";
            form.PressRevert();
            r.Check(four && thereFollows && hereFollows && modFollows && rereadSwitches && presetLines,
                $"the overview has a switch for every part of the mod that has one (the repopulate module and three test modules: {four}); it is the switch of the part's own page - "
                + $"the page follows the overview ({thereFollows}), the overview the page ({hereFollows}), the same for the repopulate module's switch on the page Advanced ({modFollows}); "
                + $"Revert reads them again ({rereadSwitches}); the overview and the pane say which preset the settings are at ({presetLines})");

            // ---- 14. Find
            var multiplierUi = g.Find("xp", "Multiplier")!;
            var found = form.FindForTest("every gain");
            bool byName = found.Count >= 1 && found[0] == "Every gain counts (times)   -   Hero > Experience";
            var gone = form.GoToFound(0);
            bool went = gone == multiplierUi.Input && form.CurrentPage == Walk.Experience && form.FindText == "" && !form.FindListShown;
            found = form.FindForTest("LARGEGAINFROM");
            bool byKey = found.Count >= 1 && found[0].StartsWith("Large gain from", StringComparison.Ordinal);
            found = form.FindForTest("count as emptied");
            bool onRepopulatePage = found.Count >= 1 && found[0].StartsWith("Containers already empty", StringComparison.Ordinal) && found[0].EndsWith("   -   World > Containers", StringComparison.Ordinal);
            gone = form.GoToFound(0);
            onRepopulatePage = onRepopulatePage && gone is NumericUpDown && form.CurrentPage == "World/Containers";
            found = form.FindForTest("crime");
            int crimeTab = found.IndexOf("World > Crime");
            bool tabFound = crimeTab >= 0 && form.GoToFound(crimeTab) == null && form.CurrentPage == "World/Crime";
            found = form.FindForTest("colour key size");
            bool described = found.Count == 1 && found[0] == "Size of the colour key (times)   -   Map > Colour key";
            found = form.FindForTest("zzzz");
            bool nothing = found.Count == 0 && form.FindListShown && form.FindCount == 0;
            found = form.FindForTest("e");
            bool many = found.Count == FindList.MaxLines && form.FindCount > FindList.MaxLines;
            form.FindForTest("   ");
            bool hidden = !form.FindListShown;
            form.Size = form.MinimumSize;
            Application.DoEvents();
            var lastUi = g.Find("allkinds", "Last")!;
            found = form.FindForTest(lastUi.Item.Label);
            gone = found.Count >= 1 ? form.GoToFound(0) : null;
            scroll.Arrange();
            bool scrolledTo = gone == lastUi.Input && form.CurrentPage == Walk.All && scroll.Scrolls && Inside(last);
            scroll.ScrollTo(0);
            form.Size = normalSize;
            Application.DoEvents();
            r.Check(byName && went && byKey && onRepopulatePage && tabFound && described && nothing && many && hidden && scrolledTo && form.Text == "G1R_MegaMod Settings",
                $"Find: a part of a setting's name lists it with its page ({byName}) and Enter goes there - the tab is opened, the box emptied ({went}); the name of its key finds it too ({byKey}); "
                + $"what stands on the five hand-written pages is found as well ({onRepopulatePage}); a tab is found by its name ({tabFound}); the map pins by theirs ({described}); "
                + $"a text nothing has says so ({nothing}); more than {FindList.MaxLines} hits: the first {FindList.MaxLines} and how many more ({many}); an empty box shows no list ({hidden}); "
                + $"a setting far down a long page is scrolled into view ({scrolledTo}); Find changes no setting");

            // ---- 15. the map pins: their file keeps its form
            string markersPath = PathOf("markers");
            WriteByteText(markersPath, AppSchemas.MarkersDefault);
            form.PressRevert();
            var pinSize = Input<XpNumericUpDown>("markers", "AreaPinSize");
            var worldNames = Input<XpComboBox>("markers", "WorldLabels");
            bool shippedShown = pinSize.Value == 23 && worldNames.SelectedIndex == worldNames.Items.IndexOf("hover") && pages["Map/Map pins"].FileNotes.Values.All(l => l.Text.Length == 0)
                && g.Items.Where(i => i.Module.Name == "markers").All(i => i.Module.Described);
            pinSize.Value = 30;
            worldNames.SelectedIndex = worldNames.Items.IndexOf("auto");
            bool mapMarked = form.MarkedCategories.SequenceEqual(new[] { "Map" });
            saved = form.SaveFile();
            string expectedPins = AppSchemas.MarkersDefault.Replace("Config.AreaPinSize = 23   -- camp maps", "Config.AreaPinSize = 30   -- camp maps", StringComparison.Ordinal)
                .Replace("Config.WorldLabels = \"hover\"  -- world map", "Config.WorldLabels = \"auto\"  -- world map", StringComparison.Ordinal);
            r.Check(shippedShown && mapMarked && saved && form.LastWritten.SequenceEqual(new[] { "markers" }) && expectedPins != AppSchemas.MarkersDefault
                && ByteTextOf(markersPath) == expectedPins && ByteTextOf(markersPath + ".bak") == AppSchemas.MarkersDefault && pinSize.Value == 30,
                "the map pins (a module without a schema.lua, described by the app): the pages show what its config.lua has; a changed value replaces the value in its line and nothing else - "
                + "the notes behind the values, the two lists and every other line stay; the file before is kept as config.lua.bak");
        }
        catch (Exception ex)
        {
            r.Check(false, "exception (pages made from schemas): " + ex);
        }
        finally
        {
            try { form.Close(); } catch { }
        }
    }
#endif
}
