using System.Globalization;
using System.Text;

namespace G1RRepopulateSettings;

/// <summary>A Lua table: named fields (in file order) plus list items.</summary>
internal sealed class LuaTable
{
    public readonly List<string> Order = new();
    private readonly Dictionary<string, object?> _fields = new(StringComparer.Ordinal);
    public readonly List<object?> Items = new();

    public IEnumerable<string> Keys => Order;
    public bool Has(string key) => _fields.ContainsKey(key);
    public object? Get(string key) => _fields.TryGetValue(key, out var v) ? v : null;

    public void Set(string key, object? value)
    {
        if (!_fields.ContainsKey(key)) Order.Add(key);
        _fields[key] = value;
    }
}

internal sealed class LuaParseException : Exception
{
    public LuaParseException(string message, int line) : base($"line {line}: {message}") { }
}

/// <summary>
/// Reads and writes the small Lua subset used by config.lua:
///   local Config = {}
///   Config.Key = value            (also Config.A.B = value)
///   return Config
/// Values: numbers, strings, true/false/nil and table constructors.
/// </summary>
internal static class LuaLite
{
    private enum K { Name, Str, Num, Sym, End }

    private readonly record struct Tok(K Kind, string Text, double Num, int Line);

    private static List<Tok> Lex(string s)
    {
        var toks = new List<Tok>();
        int i = 0, line = 1;
        if (s.Length > 0 && s[0] == '\uFEFF') i = 1;
        while (i < s.Length)
        {
            char c = s[i];
            if (c == '\n') { line++; i++; continue; }
            if (char.IsWhiteSpace(c)) { i++; continue; }
            if (c == '-' && i + 1 < s.Length && s[i + 1] == '-')
            {
                i += 2;
                int lvl = LongBracketLevel(s, i);
                if (lvl >= 0)
                {
                    string close = "]" + new string('=', lvl) + "]";
                    int end = s.IndexOf(close, i, StringComparison.Ordinal);
                    if (end < 0) throw new LuaParseException("unfinished long comment", line);
                    for (int j = i; j < end; j++) if (s[j] == '\n') line++;
                    i = end + close.Length;
                }
                else
                {
                    while (i < s.Length && s[i] != '\n') i++;
                }
                continue;
            }
            if (c == '"' || c == '\'')
            {
                char q = c;
                i++;
                var sb = new StringBuilder();
                while (true)
                {
                    if (i >= s.Length || s[i] == '\n') throw new LuaParseException("unfinished string", line);
                    char d = s[i];
                    if (d == q) { i++; break; }
                    if (d == '\\' && i + 1 < s.Length)
                    {
                        char e = s[i + 1];
                        i += 2;
                        switch (e)
                        {
                            case 'n': sb.Append('\n'); break;
                            case 't': sb.Append('\t'); break;
                            case 'r': sb.Append('\r'); break;
                            case '\\': sb.Append('\\'); break;
                            case '"': sb.Append('"'); break;
                            case '\'': sb.Append('\''); break;
                            default:
                                if (char.IsDigit(e))
                                {
                                    int code = e - '0', n = 1;
                                    while (n < 3 && i < s.Length && char.IsDigit(s[i])) { code = code * 10 + (s[i] - '0'); i++; n++; }
                                    sb.Append((char)code);
                                }
                                else sb.Append(e);
                                break;
                        }
                        continue;
                    }
                    sb.Append(d);
                    i++;
                }
                toks.Add(new Tok(K.Str, sb.ToString(), 0, line));
                continue;
            }
            if (char.IsDigit(c) || (c == '.' && i + 1 < s.Length && char.IsDigit(s[i + 1])))
            {
                int st = i;
                if (c == '0' && i + 1 < s.Length && (s[i + 1] == 'x' || s[i + 1] == 'X'))
                {
                    i += 2;
                    while (i < s.Length && Uri.IsHexDigit(s[i])) i++;
                    toks.Add(new Tok(K.Num, s[st..i], Convert.ToInt64(s[(st + 2)..i], 16), line));
                    continue;
                }
                while (i < s.Length && (char.IsDigit(s[i]) || s[i] == '.')) i++;
                if (i < s.Length && (s[i] == 'e' || s[i] == 'E'))
                {
                    i++;
                    if (i < s.Length && (s[i] == '+' || s[i] == '-')) i++;
                    while (i < s.Length && char.IsDigit(s[i])) i++;
                }
                string t = s[st..i];
                if (!double.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out double v))
                    throw new LuaParseException($"bad number '{t}'", line);
                toks.Add(new Tok(K.Num, t, v, line));
                continue;
            }
            if (char.IsLetter(c) || c == '_')
            {
                int st = i;
                while (i < s.Length && (char.IsLetterOrDigit(s[i]) || s[i] == '_')) i++;
                toks.Add(new Tok(K.Name, s[st..i], 0, line));
                continue;
            }
            if ("{}[]=,;.-()".IndexOf(c) >= 0)
            {
                toks.Add(new Tok(K.Sym, c.ToString(), 0, line));
                i++;
                continue;
            }
            throw new LuaParseException($"unexpected character '{c}'", line);
        }
        toks.Add(new Tok(K.End, "", 0, line));
        return toks;
    }

    // "[[" or "[==[" at position i: returns the level, else -1
    private static int LongBracketLevel(string s, int i)
    {
        if (i >= s.Length || s[i] != '[') return -1;
        int j = i + 1, lvl = 0;
        while (j < s.Length && s[j] == '=') { lvl++; j++; }
        return j < s.Length && s[j] == '[' ? lvl : -1;
    }

    private sealed class Parser
    {
        private readonly List<Tok> _t;
        private int _p;
        public Parser(List<Tok> t) { _t = t; }
        private Tok Peek => _t[_p];
        private Tok Next() => _t[_p++];

        private bool IsSym(string s) => Peek.Kind == K.Sym && Peek.Text == s;
        private bool IsName(string s) => Peek.Kind == K.Name && Peek.Text == s;

        private void Expect(string sym)
        {
            if (!IsSym(sym)) throw new LuaParseException($"'{sym}' expected near '{Peek.Text}'", Peek.Line);
            _p++;
        }

        private string ExpectName()
        {
            if (Peek.Kind != K.Name) throw new LuaParseException($"name expected near '{Peek.Text}'", Peek.Line);
            return Next().Text;
        }

        public LuaTable Chunk()
        {
            string? rootName = null;
            LuaTable? root = null;
            while (Peek.Kind != K.End)
            {
                if (IsSym(";")) { _p++; continue; }
                if (IsName("local"))
                {
                    _p++;
                    string name = ExpectName();
                    Expect("=");
                    object? v = Expr();
                    if (v is not LuaTable lt) throw new LuaParseException("the settings table must be a table", Peek.Line);
                    rootName = name;
                    root = lt;
                    continue;
                }
                if (IsName("return"))
                {
                    _p++;
                    int line = Peek.Line;
                    string name = ExpectName();
                    if (root == null || name != rootName) throw new LuaParseException($"'return {name}' does not return the settings table", line);
                    if (IsSym(";")) _p++;
                    if (Peek.Kind != K.End) throw new LuaParseException("text after 'return'", Peek.Line);
                    return root;
                }
                if (Peek.Kind == K.Name)
                {
                    int line = Peek.Line;
                    string name = Next().Text;
                    if (root == null || name != rootName) throw new LuaParseException($"unknown name '{name}'", line);
                    var path = new List<string>();
                    while (IsSym("."))
                    {
                        _p++;
                        path.Add(ExpectName());
                    }
                    if (path.Count == 0) throw new LuaParseException("assignment to the settings table itself", line);
                    Expect("=");
                    object? v = Expr();
                    LuaTable target = root;
                    for (int k = 0; k < path.Count - 1; k++)
                    {
                        if (target.Get(path[k]) is not LuaTable sub)
                        {
                            sub = new LuaTable();
                            target.Set(path[k], sub);
                        }
                        target = sub;
                    }
                    target.Set(path[^1], v);
                    continue;
                }
                throw new LuaParseException($"unexpected '{Peek.Text}'", Peek.Line);
            }
            throw new LuaParseException("missing 'return Config' at the end", Peek.Line);
        }

        private object? Expr()
        {
            Tok t = Peek;
            switch (t.Kind)
            {
                case K.Num: _p++; return t.Num;
                case K.Str: _p++; return t.Text;
                case K.Name:
                    _p++;
                    if (t.Text == "true") return true;
                    if (t.Text == "false") return false;
                    if (t.Text == "nil") return null;
                    throw new LuaParseException($"unsupported value '{t.Text}' (only plain numbers, text, true/false and tables)", t.Line);
                case K.Sym:
                    if (t.Text == "-")
                    {
                        _p++;
                        if (Peek.Kind != K.Num) throw new LuaParseException("number expected after '-'", Peek.Line);
                        return -Next().Num;
                    }
                    if (t.Text == "{") return Table();
                    break;
            }
            throw new LuaParseException($"value expected near '{t.Text}'", t.Line);
        }

        private LuaTable Table()
        {
            Expect("{");
            var tbl = new LuaTable();
            while (!IsSym("}"))
            {
                if (Peek.Kind == K.End) throw new LuaParseException("'}' expected", Peek.Line);
                if (IsSym("["))
                {
                    _p++;
                    object? key = Expr();
                    Expect("]");
                    Expect("=");
                    object? v = Expr();
                    string ks = key switch
                    {
                        string s => s,
                        double d => d.ToString(CultureInfo.InvariantCulture),
                        _ => throw new LuaParseException("table keys must be text or numbers", Peek.Line),
                    };
                    tbl.Set(ks, v);
                }
                else if (Peek.Kind == K.Name && _t[_p + 1].Kind == K.Sym && _t[_p + 1].Text == "=")
                {
                    string name = Next().Text;
                    _p++;
                    tbl.Set(name, Expr());
                }
                else
                {
                    tbl.Items.Add(Expr());
                }
                if (IsSym(",") || IsSym(";")) { _p++; continue; }
                if (!IsSym("}")) throw new LuaParseException($"',' or '}}' expected near '{Peek.Text}'", Peek.Line);
            }
            Expect("}");
            return tbl;
        }
    }

    public static LuaTable ParseConfig(string text) => new Parser(Lex(text)).Chunk();

    // ------------------------------------------------------------------ writing
    public static string Str(string s)
    {
        var sb = new StringBuilder("\"");
        foreach (char c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 32) sb.Append('\\').Append(((int)c).ToString(CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.Append('"').ToString();
    }

    public static string Num(double v)
    {
        if (double.IsNaN(v) || double.IsInfinity(v)) return "0";
        if (Math.Abs(v - Math.Round(v)) < 1e-9 && Math.Abs(v) < 1e15)
            return ((long)Math.Round(v)).ToString(CultureInfo.InvariantCulture);
        return v.ToString("0.0#####", CultureInfo.InvariantCulture);
    }

    /// <summary>Chance-style number: at least two decimals (0.30, 0.15, 0.125).</summary>
    public static string Chance(double v) => Math.Round(v, 4).ToString("0.00##", CultureInfo.InvariantCulture);

    public static bool IsIdent(string s) =>
        s.Length > 0 && (char.IsLetter(s[0]) || s[0] == '_') && s.All(ch => char.IsLetterOrDigit(ch) || ch == '_')
        && s is not ("and" or "break" or "do" or "else" or "elseif" or "end" or "false" or "for" or "function" or "goto"
            or "if" or "in" or "local" or "nil" or "not" or "or" or "repeat" or "return" or "then" or "true" or "until" or "while");

    public static string Value(object? v, string indent = "")
    {
        switch (v)
        {
            case null: return "nil";
            case bool b: return b ? "true" : "false";
            case double d: return Num(d);
            case int i: return i.ToString(CultureInfo.InvariantCulture);
            case string s: return Str(s);
            case LuaTable t:
                {
                    if (!t.Keys.Any() && t.Items.Count == 0) return "{}";
                    var parts = new List<string>();
                    foreach (object? item in t.Items) parts.Add(Value(item, indent + "    "));
                    foreach (string k in t.Keys)
                        parts.Add((IsIdent(k) ? k : "[" + Str(k) + "]") + " = " + Value(t.Get(k), indent + "    "));
                    return "{ " + string.Join(", ", parts) + " }";
                }
            default: return "nil";
        }
    }
}
