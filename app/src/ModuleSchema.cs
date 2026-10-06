using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.RegularExpressions;

namespace G1RRepopulateSettings;

// The settings of a module as its schema.lua describes them (dev/SETTINGS.md of the mod), and the
// rules of the game's settings service (Scripts/core/settings.lua, the reference) for the text of a
// config.lua: its default text, how a value is checked, how a number is written, how one line is
// changed. The game and this app must write the same bytes for the same change.
// All texts here are byte text (see ByteText) unless a member says "for the screen".

internal enum ItemKind { Bool, Number, Choice, Text, Key, Action }

internal sealed class SchemaItem
{
    public string Key = "";
    public ItemKind Kind;
    public object? Default;                     // bool | double | string; null for an action
    public double Min, Max;                     // numbers
    public decimal Step = 1;                    // numbers: the increment of the control
    public int Decimals;                        // numbers: places after the point, 0 = whole numbers
    public List<string> Options = new();        // choices
    public object? CommentRaw;                  // as in the schema: the lines above the value in config.lua
    public string? Needs;                       // key of the switch this item depends on
    public bool Hidden;
    /// <summary>The item's value in each of the five presets (bool | double | string), or null: the presets leave it alone.</summary>
    public List<object>? Tiers;

    // for the screen
    public string Label = "";
    public string Unit = "";
    public string Comment = "";                 // the tool tip
    public List<string> OptionLabels = new();

    /// <summary>Has a control in the app (and a line in the default config.lua).</summary>
    public bool Shown => !Hidden && Kind != ItemKind.Action;
}

internal sealed class SchemaGroup
{
    public object? TitleRaw;                    // as in the schema
    public string Title = "";                   // for the screen
    public string Hint = "";                    // for the screen
    public double Order = 100;
    public int Index;                           // position in the file, from 0
    public List<SchemaItem> Items = new();      // every item in file order, actions and hidden ones too
}

/// <summary>Why a schema.lua cannot be used. Reason is what the game's settings service says for the same schema.</summary>
internal sealed class SchemaException : Exception
{
    /// <summary>The file could not be evaluated at all (the game: "schema.lua could not be read" / "raised").</summary>
    public readonly bool Unreadable;
    /// <summary>A rule only this app has (the game's check lets the schema pass).</summary>
    public readonly bool AppRule;
    public readonly string Reason;

    public SchemaException(string reason, bool unreadable = false, bool appRule = false)
        : base(unreadable ? "schema.lua could not be read: " + reason : "schema.lua: " + reason)
    {
        Reason = reason;
        Unreadable = unreadable;
        AppRule = appRule;
    }
}

internal sealed class ModuleSchema
{
    public const int MaxDecimals = 15;

    public object? ModuleRaw, HeaderRaw;        // as in the schema
    public string? Page;                        // for the screen; null = the schema names none
    public double PageOrder = 100;
    public List<string> Notes = new();          // for the screen
    public List<SchemaGroup> Groups = new();
    public List<SchemaItem> Items = new();      // the items that have a value, in file order
    public Dictionary<string, SchemaItem> ByKey = new(StringComparer.Ordinal);
    /// <summary>What is wrong with the Tiers of items (those items are left out of the presets; the schema is used all the same).</summary>
    public List<string> TierProblems = new();
    /// <summary>What the module has to say about its values in the presets (Schema.PresetNote), for the text about them.</summary>
    public List<string> PresetNotes = new();

    private static bool IsNumber(object? v) => v is long || v is double;
    private static double Number(object? v) => v is long i ? i : (double)v!;

    // Lua: anything but nil and false counts as true
    private static bool Truthy(object? v) => v != null && !(v is bool b && !b);

    // tonumber(v): a number, or a text that is one
    private static double? ToNumber(object? v) => v switch
    {
        long i => i,
        double d => d,
        string s => LuaPlain.TextToNumber(s),
        _ => null,
    };

    /// <summary>Letters, digits and _ (not a digit first): what can stand behind "Config.".</summary>
    public static bool IsKeyName(string s)
    {
        if (s.Length == 0) return false;
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            bool letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
            if (!letter && !(i > 0 && c >= '0' && c <= '9')) return false;
        }
        return true;
    }

    // a text of the schema for the screen: texts as they are, numbers as Lua would print them
    private static string? ScreenText(object? v) => v switch
    {
        string s => ByteText.ToUnicode(s),
        long or double => LuaPlain.ToText(v),
        _ => null,
    };

    // "text" or { "line", "line" } -> the lines
    private static List<string> Lines(object? v)
    {
        var list = new List<string>();
        if (v is string s) list.Add(s);
        else if (v is PlainTable t)
            foreach (object? l in t.Sequence()) list.Add(LuaPlain.ToText(l));
        return list;
    }

    /// <summary>Reads a schema.lua (byte text). Throws a SchemaException that says what is wrong.</summary>
    public static ModuleSchema FromText(string byteText)
    {
        object? root;
        try { root = LuaPlain.Run(byteText, hashLine: true, noNil: true); }
        catch (LuaPlainException ex) { throw new SchemaException(ex.Message, unreadable: true); }
        return FromValue(root);
    }

    /// <summary>
    /// The checks of the game's settings service (itemsOf in Scripts/core/settings.lua), in its order
    /// and with its words, then the one rule the app adds (Decimals).
    /// </summary>
    public static ModuleSchema FromValue(object? root)
    {
        if (root is not PlainTable top || top["Groups"] is not PlainTable groups) throw new SchemaException("the schema has no Groups");
        var schema = new ModuleSchema { ModuleRaw = top["Module"], HeaderRaw = top["Header"] };
        var actions = new HashSet<string>(StringComparer.Ordinal);
        var all = new List<(SchemaItem Item, PlainTable Raw)>();
        int gi = 0;
        foreach (object? g in groups.Sequence())
        {
            gi++;
            if (g is not PlainTable gt || gt["Items"] is not PlainTable gitems) throw new SchemaException("group " + gi.ToString(CultureInfo.InvariantCulture) + " has no Items");
            var group = new SchemaGroup { TitleRaw = gt["Title"], Index = gi - 1, Order = ToNumber(gt["Order"]) ?? 100 };
            if (double.IsNaN(group.Order)) group.Order = 100;
            group.Title = Truthy(group.TitleRaw) ? ByteText.ToUnicode(LuaPlain.ToText(group.TitleRaw)) : "";
            group.Hint = ScreenText(gt["Hint"]) ?? "";
            schema.Groups.Add(group);
            foreach (object? it in gitems.Sequence())
            {
                var raw = it as PlainTable;
                // "type(item) == "table" and item.Key or nil"
                if (raw == null || raw["Key"] is not string key || !IsKeyName(key))
                    throw new SchemaException("an item of group " + gi.ToString(CultureInfo.InvariantCulture) + " has no usable Key");
                if (schema.ByKey.ContainsKey(key) || actions.Contains(key)) throw new SchemaException("the key " + key + " is used twice");
                var item = new SchemaItem { Key = key };
                object? kind = raw["Kind"];
                switch (kind as string)
                {
                    case "bool": item.Kind = ItemKind.Bool; break;
                    case "number": item.Kind = ItemKind.Number; break;
                    case "choice": item.Kind = ItemKind.Choice; break;
                    case "text": item.Kind = ItemKind.Text; break;
                    case "key": item.Kind = ItemKind.Key; break;
                    case "action": item.Kind = ItemKind.Action; break;
                    default: throw new SchemaException(key + ": unknown Kind " + LuaPlain.ToText(kind));
                }
                object? def = raw["Default"];
                if (item.Kind == ItemKind.Bool)
                {
                    if (def is not bool) throw new SchemaException(key + ": Default must be true or false");
                    item.Default = def;
                }
                if (item.Kind == ItemKind.Number)
                {
                    object? min = raw["Min"], max = raw["Max"];
                    if (!IsNumber(def) || !IsNumber(min) || !IsNumber(max) || Number(min) > Number(max) || Number(def) < Number(min) || Number(def) > Number(max))
                        throw new SchemaException(key + ": Default, Min and Max must be numbers with Min <= Default <= Max");
                    item.Default = Number(def);
                    item.Min = Number(min);
                    item.Max = Number(max);
                }
                if (item.Kind == ItemKind.Choice)
                {
                    var options = raw["Options"] is PlainTable ot ? ot.Sequence() : null;
                    if (options == null || options.Count == 0) throw new SchemaException(key + ": Options are missing");
                    bool found = false;
                    foreach (object? o in options)
                    {
                        if (o is not string os) throw new SchemaException(key + ": Options must be texts");
                        if (def is string ds && ds == os) found = true;
                        item.Options.Add(os);
                        item.OptionLabels.Add(ByteText.ToUnicode(os));
                    }
                    if (!found) throw new SchemaException(key + ": Default is not one of the Options");
                    item.Default = def;
                }
                if (item.Kind == ItemKind.Text)
                {
                    if (def is not string) throw new SchemaException(key + ": Default must be a text");
                    item.Default = def;
                }
                if (item.Kind == ItemKind.Key)
                {
                    if (def is not string dk || KeyNames.Combo(dk) != dk)
                        throw new SchemaException(key + ": Default must be a key in its usual spelling (\"Y\", \"CTRL+Y\") or \"\"");
                    item.Default = def;
                }
                object? needs = raw["Needs"];
                if (needs != null && needs is not string) throw new SchemaException(key + ": Needs must name a key");
                item.Needs = needs as string;
                item.Hidden = Truthy(raw["Hidden"]);
                item.CommentRaw = raw["Comment"];
                group.Items.Add(item);
                all.Add((item, raw));
                if (item.Kind == ItemKind.Action) actions.Add(key);
                else
                {
                    schema.ByKey[key] = item;
                    schema.Items.Add(item);
                }
            }
        }
        foreach (var (item, _) in all)
            if (item.Needs != null && !(schema.ByKey.TryGetValue(item.Needs, out var sw) && sw.Kind == ItemKind.Bool))
                throw new SchemaException(item.Key + ": Needs names " + item.Needs + ", which is not a yes/no item");
        if (schema.Items.Count == 0) throw new SchemaException("the schema has no items");

        // ---- what only the app needs ----
        foreach (var (item, raw) in all)
        {
            item.Label = ScreenText(raw["Label"]) ?? item.Key;
            item.Unit = ScreenText(raw["Unit"]) ?? "";
            item.Comment = string.Join(" ", Lines(item.CommentRaw).Select(ByteText.ToUnicode));
            if (item.Kind != ItemKind.Number) continue;
            // The game: decimals = tonumber(Decimals) or 0; up to 0 = whole numbers. A value that is not
            // whole, or written as a float (2.0), makes the game's number format fail; more places than a
            // number has are of no use. The app refuses those.
            object? places = raw["Decimals"];
            double d = ToNumber(places) ?? 0;
            if (double.IsNaN(d) || d <= 0) item.Decimals = 0;
            else if (d != Math.Floor(d) || d > MaxDecimals || places is double || (places is string ps && !ps.Trim().All(ch => ch >= '0' && ch <= '9')))
                throw new SchemaException(item.Key + ": Decimals must be a whole number from 0 to " + MaxDecimals.ToString(CultureInfo.InvariantCulture), appRule: true);
            else item.Decimals = (int)d;
            item.Step = StepOf(ToNumber(raw["Step"]), item.Decimals);
        }
        // The presets (dev/SETTINGS.md section 7 of the mod): the item's value in each of the five. The game does
        // not read the field, so a Tiers that cannot be used is no reason to refuse the schema: the item is left
        // out of the presets and the page says so.
        foreach (var (item, raw) in all)
        {
            object? tiers = raw["Tiers"];
            if (tiers == null) continue;
            string? problem = Presets.Read(item, tiers, raw["Min"], raw["Max"], out var values);
            if (problem != null) schema.TierProblems.Add(problem);
            else item.Tiers = values;
        }
        string? page = Truthy(top["Page"]) ? ScreenText(top["Page"]) : null;
        schema.Page = string.IsNullOrWhiteSpace(page) ? null : page;
        double order = ToNumber(top["PageOrder"]) ?? 100;
        schema.PageOrder = double.IsNaN(order) ? 100 : order;
        foreach (string note in Lines(top["Notes"])) schema.Notes.Add(ByteText.ToUnicode(note));
        foreach (string note in Lines(top["PresetNote"])) schema.PresetNotes.Add(ByteText.ToUnicode(note));
        return schema;
    }

    // The increment of the number control: Step when it is a usable number, else 1; never finer than
    // the item's places, never 0.
    private static decimal StepOf(double? step, int decimals)
    {
        decimal unit = 1;
        for (int i = 0; i < decimals; i++) unit /= 10;
        if (step == null || double.IsNaN(step.Value) || step.Value <= 0 || step.Value > 1e15) return Math.Max(1m, unit);
        decimal s = decimal.Round((decimal)step.Value, decimals, MidpointRounding.AwayFromZero);
        return s < unit ? unit : s;
    }

    /// <summary>The name of the module as the game's default file header has it (Schema.Module).</summary>
    public string ModuleText => LuaPlain.ToText(ModuleRaw);

    // ------------------------------------------------------------------ the text of config.lua
    private static void CommentLines(List<string> lines, object? comment)
    {
        foreach (string l in Lines(comment)) lines.Add("-- " + l);
    }

    /// <summary>The text of a config.lua that holds the defaults (Settings.defaultText of the game).</summary>
    public string DefaultText()
    {
        var lines = new List<string>();
        string bar = "-- " + new string('=', 76);
        lines.Add(bar);
        if (Truthy(HeaderRaw)) CommentLines(lines, HeaderRaw);
        else lines.Add("-- Settings of the module " + LuaPlain.ToText(ModuleRaw));
        lines.Add(bar);
        lines.Add("local Config = {}");
        foreach (var group in Groups)
        {
            bool shown = false;
            foreach (var item in group.Items)
            {
                if (!item.Shown) continue;
                if (!shown)
                {
                    lines.Add("");
                    if (Truthy(group.TitleRaw)) lines.Add("-- ---- " + LuaPlain.ToText(group.TitleRaw) + " ----");
                    shown = true;
                }
                CommentLines(lines, item.CommentRaw);
                lines.Add("Config." + item.Key + " = " + SettingsRules.Literal(item, item.Default!));
            }
        }
        lines.Add("");
        lines.Add("return Config");
        return string.Join("\n", lines) + "\n";
    }
}

/// <summary>
/// The key names of UE4SS with their Windows virtual-key codes, and the usual spelling of a key
/// combination ("ctrl + y" -> "CTRL+Y"). The reference is keyCombo in Scripts/core/kit.lua of the mod
/// (dev/SETTINGS.md section 6).
/// </summary>
internal static class KeyNames
{
    public const int Ctrl = 0x11, Shift = 0x10, Alt = 0x12;

    public static readonly (string Name, int Code)[] All =
    {
        ("MIDDLE_MOUSE_BUTTON", 4), ("XBUTTON_ONE", 5), ("XBUTTON_TWO", 6), ("BACKSPACE", 8), ("TAB", 9), ("RETURN", 13), ("PAUSE", 19),
        ("CAPS_LOCK", 20), ("SPACE", 32), ("PAGE_UP", 33), ("PAGE_DOWN", 34), ("END", 35), ("HOME", 36), ("LEFT_ARROW", 37), ("UP_ARROW", 38),
        ("RIGHT_ARROW", 39), ("DOWN_ARROW", 40), ("INS", 45), ("DEL", 46), ("ZERO", 48), ("ONE", 49), ("TWO", 50), ("THREE", 51), ("FOUR", 52),
        ("FIVE", 53), ("SIX", 54), ("SEVEN", 55), ("EIGHT", 56), ("NINE", 57), ("A", 65), ("B", 66), ("C", 67), ("D", 68), ("E", 69), ("F", 70), ("G", 71),
        ("H", 72), ("I", 73), ("J", 74), ("K", 75), ("L", 76), ("M", 77), ("N", 78), ("O", 79), ("P", 80), ("Q", 81), ("R", 82), ("S", 83), ("T", 84), ("U", 85),
        ("V", 86), ("W", 87), ("X", 88), ("Y", 89), ("Z", 90), ("NUM_ZERO", 96), ("NUM_ONE", 97), ("NUM_TWO", 98), ("NUM_THREE", 99),
        ("NUM_FOUR", 100), ("NUM_FIVE", 101), ("NUM_SIX", 102), ("NUM_SEVEN", 103), ("NUM_EIGHT", 104), ("NUM_NINE", 105), ("MULTIPLY", 106),
        ("ADD", 107), ("SUBTRACT", 109), ("DECIMAL", 110), ("DIVIDE", 111), ("F1", 112), ("F2", 113), ("F3", 114), ("F4", 115), ("F5", 116),
        ("F6", 117), ("F7", 118), ("F8", 119), ("F9", 120), ("F10", 121), ("F11", 122), ("F12", 123), ("NUM_LOCK", 144), ("SCROLL_LOCK", 145),
        ("OEM_ONE", 186), ("OEM_PLUS", 187), ("OEM_COMMA", 188), ("OEM_MINUS", 189), ("OEM_PERIOD", 190), ("OEM_TWO", 191),
        ("OEM_THREE", 192), ("OEM_FOUR", 219), ("OEM_FIVE", 220), ("OEM_SIX", 221), ("OEM_SEVEN", 222), ("OEM_EIGHT", 223), ("OEM_102", 226),
    };

    // other spellings people use
    private static readonly Dictionary<string, string> Aliases = new(StringComparer.Ordinal)
    {
        ["0"] = "ZERO", ["1"] = "ONE", ["2"] = "TWO", ["3"] = "THREE", ["4"] = "FOUR", ["5"] = "FIVE", ["6"] = "SIX",
        ["7"] = "SEVEN", ["8"] = "EIGHT", ["9"] = "NINE", ["NUM0"] = "NUM_ZERO", ["NUM1"] = "NUM_ONE", ["NUM2"] = "NUM_TWO",
        ["NUM3"] = "NUM_THREE", ["NUM4"] = "NUM_FOUR", ["NUM5"] = "NUM_FIVE", ["NUM6"] = "NUM_SIX", ["NUM7"] = "NUM_SEVEN", ["NUM8"] = "NUM_EIGHT",
        ["NUM9"] = "NUM_NINE", ["INSERT"] = "INS", ["DELETE"] = "DEL", ["ENTER"] = "RETURN", ["PGUP"] = "PAGE_UP", ["PGDN"] = "PAGE_DOWN",
        ["PAGEUP"] = "PAGE_UP", ["PAGEDOWN"] = "PAGE_DOWN", ["UP"] = "UP_ARROW", ["DOWN"] = "DOWN_ARROW", ["LEFT"] = "LEFT_ARROW",
        ["RIGHT"] = "RIGHT_ARROW", ["MOUSE3"] = "MIDDLE_MOUSE_BUTTON", ["MOUSE4"] = "XBUTTON_ONE", ["MOUSE5"] = "XBUTTON_TWO",
        ["CAPSLOCK"] = "CAPS_LOCK", ["NUMLOCK"] = "NUM_LOCK", ["SCROLLLOCK"] = "SCROLL_LOCK",
    };

    private static readonly Dictionary<string, string> ModifierAliases = new(StringComparer.Ordinal)
    {
        ["CONTROL"] = "CTRL", ["STRG"] = "CTRL", ["CTRL"] = "CTRL", ["SHIFT"] = "SHIFT", ["ALT"] = "ALT",
    };

    private static readonly Dictionary<string, int> Codes = All.ToDictionary(k => k.Name, k => k.Code, StringComparer.Ordinal);
    private static readonly Dictionary<int, string> Names = All.ToDictionary(k => k.Code, k => k.Name);

    /// <summary>The UE4SS name of a virtual-key code, or null for a key that cannot be bound.</summary>
    public static string? NameOf(int virtualKey) => Names.TryGetValue(virtualKey, out string? n) ? n : null;

    /// <summary>Modifiers in the usual order and one key name: "CTRL+SHIFT+F5".</summary>
    public static string Build(bool ctrl, bool shift, bool alt, string keyName) =>
        (ctrl ? "CTRL+" : "") + (shift ? "SHIFT+" : "") + (alt ? "ALT+" : "") + keyName;

    /// <summary>
    /// A key combination as text -> its usual spelling; "" (no key) -> ""; null when it names no key.
    /// code: the key's virtual-key code; modifiers: the codes of CTRL, SHIFT, ALT that are held.
    /// </summary>
    public static string? Combo(string text, out int code, out List<int> modifiers)
    {
        code = 0;
        modifiers = new List<int>();
        var sb = new StringBuilder(text.Length);
        foreach (char c in text)
        {
            if (ByteText.IsSpace(c)) continue;
            sb.Append(c >= 'a' && c <= 'z' ? (char)(c - 32) : c);      // upper case for ASCII letters only, as the game's Lua does it
        }
        string compact = sb.ToString();
        if (compact.Length == 0) return "";
        bool ctrl = false, shift = false, alt = false;
        string? key = null;
        foreach (string p in compact.Split('+'))
        {
            if (ModifierAliases.TryGetValue(p, out string? modifier))
            {
                if (modifier == "CTRL") ctrl = true; else if (modifier == "SHIFT") shift = true; else alt = true;
                continue;
            }
            string part = Aliases.TryGetValue(p, out string? usual) ? usual : p;
            if (!Codes.ContainsKey(part)) return null;      // unknown key
            if (key != null) return null;                   // more than one key
            key = part;
        }
        if (key == null) return null;                       // only modifier keys
        if (ctrl) modifiers.Add(Ctrl);
        if (shift) modifiers.Add(Shift);
        if (alt) modifiers.Add(Alt);
        code = Codes[key];
        return Build(ctrl, shift, alt, key);
    }

    public static string? Combo(string text) => Combo(text, out _, out _);
}

/// <summary>The rules of Scripts/core/settings.lua for values and for the text of a config.lua.</summary>
internal static class SettingsRules
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    // ------------------------------------------------------------------ numbers
    // C's "%.<places>f" for a finite number: the exact value, rounded half to even.
    private static string Fixed(double v, int places)
    {
        long bits = BitConverter.DoubleToInt64Bits(v);
        bool negative = bits < 0;
        int exponent = (int)((bits >> 52) & 0x7FF);
        long fraction = bits & 0xFFFFFFFFFFFFFL;
        BigInteger mantissa;
        int power;
        if (exponent == 0) { mantissa = fraction; power = -1074; }
        else { mantissa = fraction | (1L << 52); power = exponent - 1075; }
        BigInteger numerator = mantissa * BigInteger.Pow(10, places), denominator = BigInteger.One;
        if (power >= 0) numerator <<= power; else denominator <<= -power;
        BigInteger q = BigInteger.DivRem(numerator, denominator, out BigInteger r);
        int half = (r * 2).CompareTo(denominator);
        if (half > 0 || (half == 0 && !q.IsEven)) q += 1;
        string digits = q.ToString(Inv).PadLeft(places + 1, '0');
        return (negative ? "-" : "") + digits[..^places] + "." + digits[^places..];
    }

    /// <summary>
    /// A number as it is written into config.lua: whole numbers plain (rounded half up), others with
    /// at most `decimals` places and at least one ("1.0", "2.5", "0.75").
    /// </summary>
    public static string NumberText(double v, int decimals)
    {
        if (double.IsNaN(v)) return "nan";
        if (decimals <= 0)
        {
            double whole = Math.Floor(v + 0.5);
            if (double.IsInfinity(whole)) return whole > 0 ? "inf" : "-inf";
            // (beyond 64 bits the game's Lua raises an error; the app writes the digits)
            return Math.Abs(whole) < 9.2e18 ? ((long)whole).ToString(Inv) : new BigInteger(whole).ToString(Inv);
        }
        if (double.IsInfinity(v)) return v > 0 ? "inf" : "-inf";
        string s = Fixed(v, decimals).TrimEnd('0');
        if (s.EndsWith('.')) s += "0";
        return s == "-0.0" ? "0.0" : s;
    }

    /// <summary>A text in double quotes: \ and " escaped, control characters replaced by spaces (the value stays on its line).</summary>
    public static string Quoted(string text)
    {
        var sb = new StringBuilder(text.Length + 2).Append('"');
        foreach (char c in text)
        {
            if (c == '\\') sb.Append("\\\\");
            else if (c == '"') sb.Append("\\\"");
            else if (c < 32 || c == 127) sb.Append(' ');
            else sb.Append(c);
        }
        return sb.Append('"').ToString();
    }

    /// <summary>A text as Quoted writes it, without the quotes and escapes: what is read back from the file.</summary>
    public static string OnOneLine(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (char c in text) sb.Append(c < 32 || c == 127 ? ' ' : c);
        return sb.ToString();
    }

    /// <summary>The value of an item as it stands in config.lua.</summary>
    public static string Literal(SchemaItem item, object value) => item.Kind switch
    {
        ItemKind.Bool => (bool)value ? "true" : "false",
        ItemKind.Number => NumberText((double)value, item.Decimals),
        _ => Quoted((string)value),
    };

    // ------------------------------------------------------------------ values
    /// <summary>Lua's == for the values an item can have.</summary>
    public static bool Same(object? a, object? b) => a switch
    {
        bool x => b is bool y && x == y,
        double x => b is double y && x == y,
        string x => b is string y && string.Equals(x, y, StringComparison.Ordinal),
        _ => false,
    };

    /// <summary>
    /// A value of the right kind and in range for the item (what the game uses for a value read from
    /// config.lua), and whether the given one had to be changed for that. given: null (the key is not
    /// in the file), bool, long, double, string or PlainTable.
    /// </summary>
    public static object Checked(SchemaItem item, object? given, out bool corrected)
    {
        switch (item.Kind)
        {
            case ItemKind.Bool:
                if (given is bool) { corrected = false; return given; }
                break;
            case ItemKind.Number:
                {
                    double? n = given switch { long i => i, double d => d, string s => LuaPlain.TextToNumber(s), _ => null };
                    if (n == null || double.IsNaN(n.Value)) break;
                    double c = Math.Max(item.Min, Math.Min(item.Max, n.Value));
                    if (item.Decimals <= 0) c = Math.Floor(c + 0.5);
                    else
                    {
                        double? asWritten = LuaPlain.TextToNumber(NumberText(c, item.Decimals));       // as it stands in the file
                        if (asWritten == null) break;
                        c = asWritten.Value;
                    }
                    corrected = c != n.Value || given is string;
                    return c;
                }
            case ItemKind.Choice:
                if (given is string choice && item.Options.Contains(choice, StringComparer.Ordinal)) { corrected = false; return choice; }
                break;
            case ItemKind.Key:
                if (given is string keyText && KeyNames.Combo(keyText) is string usual) { corrected = false; return usual; }     // another spelling of a key is no mistake
                break;
            case ItemKind.Text:
                if (given is string) { corrected = false; return given; }
                break;
        }
        corrected = given != null;
        return item.Default!;
    }

    public static object Checked(SchemaItem item, object? given) => Checked(item, given, out _);

    // ------------------------------------------------------------------ reading a config.lua
    /// <summary>
    /// The table a config.lua returns, or null and why it is not usable (a syntax error, anything but
    /// plain values, no table returned).
    /// </summary>
    public static PlainTable? Parse(string byteText, out string? problem)
    {
        problem = null;
        try
        {
            if (LuaPlain.Run(byteText) is PlainTable t) return t;
            problem = "it does not return a table";
        }
        catch (LuaPlainException ex) { problem = ex.Message; }
        return null;
    }

    // "2,5" is valid Lua and means 2
    private static readonly Regex CommaNumber = new("=[ \\t\\n\\v\\f\\r]*-?[0-9]+,[0-9]", RegexOptions.CultureInvariant);
    public static bool HasCommaNumber(string byteText) => CommaNumber.IsMatch(byteText);

    // ------------------------------------------------------------------ changing one line
    // "[ \t]*Config.<Key>[ \t]*=<rest of the line>" at pos: the end of the line (without its line end)
    private static bool KeyLineAt(string text, int pos, string name, out int end)
    {
        end = 0;
        int p = pos;
        while (p < text.Length && (text[p] == ' ' || text[p] == '\t')) p++;
        if (string.CompareOrdinal(text, p, name, 0, name.Length) != 0) return false;
        p += name.Length;
        while (p < text.Length && (text[p] == ' ' || text[p] == '\t')) p++;
        if (p >= text.Length || text[p] != '=') return false;
        p++;
        while (p < text.Length && text[p] != '\r' && text[p] != '\n') p++;
        end = p;
        return true;
    }

    // "[ \t]*return<white space>Config<rest of the line>" at pos, with nothing but white space after that line
    private static bool ReturnLineAt(string text, int pos)
    {
        int p = pos;
        while (p < text.Length && (text[p] == ' ' || text[p] == '\t')) p++;
        if (string.CompareOrdinal(text, p, "return", 0, 6) != 0) return false;
        p += 6;
        int spaces = 0;
        while (p < text.Length && ByteText.IsSpace(text[p])) { p++; spaces++; }
        if (spaces == 0 || string.CompareOrdinal(text, p, "Config", 0, 6) != 0) return false;
        p += 6;
        while (p < text.Length && text[p] != '\n') p++;
        while (p < text.Length && ByteText.IsSpace(text[p])) p++;
        return p == text.Length;
    }

    /// <summary>
    /// Sets the value of one key in the text of a config.lua (patch in the game's settings.lua): the
    /// last line "Config.&lt;Key&gt; = ..." (the one Lua goes by) gets the new value; without such a line
    /// one is added below the last line with text in front of the last "return Config". Everything
    /// else stays as it is.
    /// </summary>
    // The last line "Config.<Key> = ..." of the text (the one Lua goes by): where it starts and where it ends (without its line end).
    private static bool LastKeyLine(string text, string name, out int s, out int e)
    {
        s = -1; e = -1;
        if (KeyLineAt(text, 0, name, out int end)) { s = 0; e = end; }
        for (int from = 0; ;)
        {
            int nl = text.IndexOf('\n', from);
            if (nl < 0) break;
            if (KeyLineAt(text, nl + 1, name, out end)) { s = nl + 1; e = end; from = end; }
            else from = nl + 1;
        }
        return s >= 0;
    }

    // Where the plain value that starts at v ends (a text in quotes, a number, true, false), or -1 when it is
    // nothing this rule knows the end of (a table, a long bracket, nothing at all). e: the end of the line.
    private static int ValueEnd(string text, int v, int e)
    {
        if (v >= e) return -1;
        char c = text[v];
        if (c == '"' || c == '\'')
        {
            for (int p = v + 1; p < e; p++)
            {
                if (text[p] == '\\') { p++; continue; }
                if (text[p] == c) return p + 1;
            }
            return -1;
        }
        if (c == '{' || c == '[' || c == '(') return -1;
        int q = v;
        while (q < e && text[q] != ' ' && text[q] != '\t' && text[q] != ';' && text[q] != ',' && !(text[q] == '-' && q + 1 < e && text[q + 1] == '-')) q++;
        if (q == v || (q == v + 1 && (c == '-' || c == '+'))) return -1;       // nothing, or a sign that stands apart from its number
        return q;
    }

    /// <summary>
    /// As Patch, for a file whose lines carry notes behind their values ("Config.Size = 23  -- camp maps"; the
    /// settings of a module the app describes itself, see AppSchemas): in the key's last line only the value is
    /// replaced - what stands in front of it and behind it stays. Where the value is nothing this rule knows
    /// the end of, and where the key has no line, the text is what Patch gives.
    /// </summary>
    public static string PatchValue(string text, string key, string valueText)
    {
        string name = "Config." + key;
        if (!LastKeyLine(text, name, out int s, out int e)) return Patch(text, key, valueText);
        int p = s;
        while (p < e && (text[p] == ' ' || text[p] == '\t')) p++;
        p += name.Length;
        while (p < e && (text[p] == ' ' || text[p] == '\t')) p++;
        p++;        // the = sign
        while (p < e && (text[p] == ' ' || text[p] == '\t')) p++;
        int end = ValueEnd(text, p, e);
        if (end < 0) return Patch(text, key, valueText);
        return text[..p] + valueText + text[end..];
    }

    public static string Patch(string text, string key, string valueText)
    {
        string line = "Config." + key + " = " + valueText;
        string name = "Config." + key;
        if (LastKeyLine(text, name, out int s, out int e))
        {
            int indent = s;
            while (indent < e && (text[indent] == ' ' || text[indent] == '\t')) indent++;
            return text[..indent] + line + text[e..];
        }
        string newline = text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
        int rs = -1;
        for (int from = 0; ;)
        {
            int nl = text.IndexOf('\n', from);
            if (nl < 0) break;
            if (ReturnLineAt(text, nl + 1)) { rs = nl; break; }
            from = nl + 1;
        }
        if (rs >= 0)
        {
            // below the last line with text in front of the return: empty lines stay in front of it
            string head = text[..(rs + 1)];
            int bodyLength = head.Length;
            while (bodyLength > 0 && ByteText.IsSpace(head[bodyLength - 1])) bodyLength--;
            if (bodyLength == 0) return line + newline + text;
            return head[..bodyLength] + newline + line + head[bodyLength..] + text[(rs + 1)..];
        }
        if (text.Length > 0 && text[^1] != '\n') text += newline;
        return text + line + newline;
    }

    // ------------------------------------------------------------------ changing values (apply in the game's settings.lua)
    /// <summary>
    /// Sets several values: memory (the checked values the module has now, by key; changed in place)
    /// takes the wanted ones, and the text of config.lua for that is returned - null when no value
    /// changed. diskText: the file as it is now (null = there is none). Only the lines of changed keys
    /// are rewritten, in the order of the schema; a file that is missing or not usable is replaced by
    /// the default text with every value that is not the default.
    /// defaultText: the default text when it is not the one the schema gives; keepTail: lines are changed
    /// with PatchValue (both: for a module the app describes itself - the game's settings service has neither).
    /// </summary>
    public static string? Apply(ModuleSchema schema, string? diskText, Dictionary<string, object> memory, IReadOnlyDictionary<string, object?> wanted, out List<string> changed,
        string? defaultText = null, bool keepTail = false)
    {
        Func<string, string, string, string> patch = keepTail ? PatchValue : Patch;
        changed = new List<string>();
        foreach (string key in wanted.Keys.OrderBy(k => k, StringComparer.Ordinal))
        {
            if (!schema.ByKey.TryGetValue(key, out var item)) continue;
            object v = Checked(item, wanted[key]);
            if (Same(memory[key], v)) continue;
            memory[key] = v;
            changed.Add(key);
        }
        if (changed.Count == 0) return null;
        string text;
        if (diskText == null || Parse(diskText, out _) == null)
        {
            // no usable file: a complete one is written
            text = defaultText ?? schema.DefaultText();
            foreach (var item in schema.Items)
                if (!Same(memory[item.Key], item.Default)) text = patch(text, item.Key, Literal(item, memory[item.Key]));
        }
        else
        {
            text = diskText;
            var set = new HashSet<string>(changed, StringComparer.Ordinal);
            foreach (var item in schema.Items)      // in the order of the schema: new lines stand as the default file has them
                if (set.Contains(item.Key)) text = patch(text, item.Key, Literal(item, memory[item.Key]));
        }
        return text;
    }
}
