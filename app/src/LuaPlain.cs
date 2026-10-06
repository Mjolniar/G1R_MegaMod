using System.Globalization;
using System.Text;

namespace G1RRepopulateSettings;

/// <summary>
/// "Byte text": the content of a file as a string with one char per byte (Latin-1). The files of the
/// modules (schema.lua, config.lua) are handled as bytes, the way the game's Lua handles them: nothing
/// is lost or changed by decoding, and Lua's rules (white space, upper case, control characters) are
/// rules about bytes. Text for the screen is decoded as UTF-8, text typed in the app is encoded as UTF-8.
/// </summary>
internal static class ByteText
{
    private static readonly UTF8Encoding Utf8 = new(false);

    public static string FromBytes(byte[] bytes) => Encoding.Latin1.GetString(bytes);

    public static byte[] ToBytes(string byteText)
    {
        var bytes = new byte[byteText.Length];
        for (int i = 0; i < byteText.Length; i++)
        {
            char c = byteText[i];
            if (c > 255) throw new InvalidOperationException("text that is not byte text was about to be written");
            bytes[i] = (byte)c;
        }
        return bytes;
    }

    /// <summary>Text as the user sees or types it -> its UTF-8 bytes as byte text.</summary>
    public static string FromUnicode(string text) => Encoding.Latin1.GetString(Utf8.GetBytes(text));

    /// <summary>Byte text -> text for the screen (bytes that are not UTF-8 show as U+FFFD).</summary>
    public static string ToUnicode(string byteText) => Utf8.GetString(ToBytes(byteText));

    /// <summary>The UTF-8 byte order mark some editors put in front of a file.</summary>
    public const string Bom = "\u00EF\u00BB\u00BF";

    /// <summary>Lua's %s, C's isspace in the C locale: space, tab, line feed, vertical tab, form feed, carriage return.</summary>
    public static bool IsSpace(char c) => c == ' ' || (c >= '\t' && c <= '\r');
}

/// <summary>
/// A Lua table of plain values. Keys: texts (byte text), whole numbers (long), other numbers (double),
/// true / false. Values: null (nil), bool, long (a Lua integer), double (a Lua float), string (byte
/// text), PlainTable.
/// </summary>
internal sealed class PlainTable
{
    private readonly List<object?> _array = new();                  // t[1] .. t[n]: the entries written without a key
    private readonly Dictionary<object, object?> _hash = new();

    // Lua: a float key with a whole value is the same key as that integer.
    private static object Normal(object key) =>
        key is double d && d == Math.Floor(d) && d >= -9.2233720368547758E+18 && d < 9.2233720368547758E+18 ? (long)d : key;

    public object? Get(object key)
    {
        key = Normal(key);
        if (key is long i && i >= 1 && i <= _array.Count) return _array[(int)(i - 1)];
        return _hash.TryGetValue(key, out object? v) ? v : null;
    }

    public void Set(object key, object? value)
    {
        key = Normal(key);
        if (key is long i && i >= 1 && i <= _array.Count) { _array[(int)(i - 1)] = value; return; }
        if (value == null) _hash.Remove(key); else _hash[key] = value;
    }

    /// <summary>An entry written without a key: { a, b }.</summary>
    public void Append(object? value) => _array.Add(value);

    /// <summary>How many entries the table holds, of any key.</summary>
    public int EntryCount => _array.Count(v => v != null) + _hash.Count;

    /// <summary>The field with this name (nil = null).</summary>
    public object? this[string name] => _hash.TryGetValue(name, out object? v) ? v : null;

    /// <summary>What Lua's ipairs walks over: t[1], t[2], ... up to the first nil.</summary>
    public List<object?> Sequence()
    {
        var list = new List<object?>();
        for (long i = 1; ; i++)
        {
            object? v = Get(i);
            if (v == null) return list;
            list.Add(v);
        }
    }
}

internal sealed class LuaPlainException : Exception
{
    public LuaPlainException(string message, int line) : base($"line {line}: {message}") { }
}

/// <summary>
/// Runs a Lua file of plain values the way Lua would and returns what it returns (schema.lua, a
/// module's config.lua):
///   local Config = {}            local names, with or without a value
///   Config.Key = value           assignments to names, fields (a.b.c) and entries (a["b"], a[1])
///   return Config
/// Values: nil, true, false, numbers (also hexadecimal whole numbers and negative ones), texts in
/// single or double quotes or long brackets with all of Lua's escapes, tables { a, b, Key = value,
/// ["key"] = value }, and names / fields that were set before. Comments (-- and --[[ ]]) and
/// semicolons are skipped. Everything else Lua has - arithmetic, joining texts, comparisons,
/// function calls, functions, control structures - is refused: the files of the settings are plain
/// values (dev/SETTINGS.md), and what cannot be read here counts as not valid.
/// Whatever is accepted gives the values Lua gives.
/// </summary>
internal static class LuaPlain
{
    private const string PlainOnly = "only plain values are allowed here (no arithmetic, no joined texts, no function calls)";
    private const int MaxDepth = 200;       // Lua's own limit for nested constructors is about this

    private enum K { Name, Str, Int, Num, Sym, End }

    private readonly record struct Tok(K Kind, string Text, long Int, double Num, int Line);

    private static readonly HashSet<string> Reserved = new(StringComparer.Ordinal)
    {
        "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil",
        "not", "or", "repeat", "return", "then", "true", "until", "while",
    };

    public static bool IsReserved(string name) => Reserved.Contains(name);

    private static bool IsDigit(char c) => c >= '0' && c <= '9';
    private static bool IsHex(char c) => IsDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    private static bool IsNameStart(char c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
    private static bool IsNameChar(char c) => IsNameStart(c) || IsDigit(c);
    private static int HexValue(char c) => IsDigit(c) ? c - '0' : (c | 0x20) - 'a' + 10;

    // =====================================================================
    // text -> tokens
    // =====================================================================
    private sealed class Lexer
    {
        private readonly string _s;
        private int _i;
        private int _line = 1;
        public readonly List<Tok> Tokens = new();

        public Lexer(string s, int start) { _s = s; _i = start; }

        private char Cur => _i < _s.Length ? _s[_i] : '\0';
        private bool AtEnd => _i >= _s.Length;
        private char At(int offset) => _i + offset < _s.Length ? _s[_i + offset] : '\0';

        // a line end: \n, \r, \r\n or \n\r count as one
        private void NewLine()
        {
            char old = _s[_i++];
            if (!AtEnd && (Cur == '\n' || Cur == '\r') && Cur != old) _i++;
            _line++;
        }

        // "[[" or "[==[" at the current position: its level, else -1
        private int LongBracketLevel()
        {
            if (Cur != '[') return -1;
            int j = _i + 1, level = 0;
            while (j < _s.Length && _s[j] == '=') { level++; j++; }
            return j < _s.Length && _s[j] == '[' ? level : -1;
        }

        // reads [[ ... ]] from the opening bracket on; text = null for a comment
        private string? LongBracket(int level, bool keep, string what)
        {
            int startLine = _line;
            _i += level + 2;
            if (!AtEnd && (Cur == '\n' || Cur == '\r')) NewLine();     // a line end right after the opening is not part of the text
            var sb = keep ? new StringBuilder() : null;
            while (true)
            {
                if (AtEnd) throw new LuaPlainException("unfinished " + what, startLine);
                char c = Cur;
                if (c == ']')
                {
                    int j = _i + 1, n = 0;
                    while (j < _s.Length && _s[j] == '=') { n++; j++; }
                    if (n == level && j < _s.Length && _s[j] == ']') { _i = j + 1; return sb?.ToString(); }
                    sb?.Append(c);
                    _i++;
                }
                else if (c == '\n' || c == '\r') { NewLine(); sb?.Append('\n'); }
                else { sb?.Append(c); _i++; }
            }
        }

        public void Run()
        {
            while (true)
            {
                if (AtEnd) { Tokens.Add(new Tok(K.End, "<end of file>", 0, 0, _line)); return; }
                char c = Cur;
                if (c == '\n' || c == '\r') { NewLine(); continue; }
                if (ByteText.IsSpace(c)) { _i++; continue; }
                if (c == '-' && At(1) == '-')
                {
                    _i += 2;
                    int level = LongBracketLevel();
                    if (level >= 0) LongBracket(level, false, "long comment");
                    else while (!AtEnd && Cur != '\n' && Cur != '\r') _i++;
                    continue;
                }
                if (c == '"' || c == '\'') { Quoted(c); continue; }
                if (c == '[')
                {
                    int level = LongBracketLevel();
                    if (level >= 0)
                    {
                        int line = _line;
                        Tokens.Add(new Tok(K.Str, LongBracket(level, true, "long text")!, 0, 0, line));
                        continue;
                    }
                }
                if (IsDigit(c) || (c == '.' && IsDigit(At(1)))) { Number(); continue; }
                if (IsNameStart(c))
                {
                    int st = _i;
                    while (!AtEnd && IsNameChar(Cur)) _i++;
                    Tokens.Add(new Tok(K.Name, _s[st.._i], 0, 0, _line));
                    continue;
                }
                // operators of more than one character are one token, so that "a == b" is not read as "a = ..."
                string sym = c.ToString();
                foreach (string op in new[] { "...", "..", "==", "~=", "<=", ">=", "//", "::", "<<", ">>" })
                    if (string.CompareOrdinal(_s, _i, op, 0, op.Length) == 0) { sym = op; break; }
                Tokens.Add(new Tok(K.Sym, sym, 0, 0, _line));
                _i += sym.Length;
            }
        }

        private void Quoted(char quote)
        {
            int line = _line;
            _i++;
            var sb = new StringBuilder();
            while (true)
            {
                if (AtEnd || Cur == '\n' || Cur == '\r') throw new LuaPlainException("unfinished text (the closing quote is missing)", line);
                char c = Cur;
                if (c == quote) { _i++; break; }
                if (c != '\\') { sb.Append(c); _i++; continue; }
                _i++;
                if (AtEnd) throw new LuaPlainException("unfinished text (the closing quote is missing)", line);
                char e = Cur;
                switch (e)
                {
                    case 'a': sb.Append('\a'); _i++; break;
                    case 'b': sb.Append('\b'); _i++; break;
                    case 'f': sb.Append('\f'); _i++; break;
                    case 'n': sb.Append('\n'); _i++; break;
                    case 'r': sb.Append('\r'); _i++; break;
                    case 't': sb.Append('\t'); _i++; break;
                    case 'v': sb.Append('\v'); _i++; break;
                    case '\\': case '"': case '\'': sb.Append(e); _i++; break;
                    case '\n': case '\r': NewLine(); sb.Append('\n'); break;
                    case 'x':
                        if (!IsHex(At(1)) || !IsHex(At(2))) throw new LuaPlainException("\\x needs two hexadecimal digits", _line);
                        sb.Append((char)(HexValue(At(1)) * 16 + HexValue(At(2))));
                        _i += 3;
                        break;
                    case 'z':
                        _i++;
                        while (!AtEnd && ByteText.IsSpace(Cur))
                        {
                            if (Cur == '\n' || Cur == '\r') NewLine(); else _i++;
                        }
                        break;
                    case 'u':
                        {
                            if (At(1) != '{' || !IsHex(At(2))) throw new LuaPlainException("\\u needs a code in braces: \\u{20AC}", _line);
                            _i += 2;
                            ulong code = 0;
                            while (IsHex(Cur))
                            {
                                code = code * 16 + (ulong)HexValue(Cur);
                                if (code > 0x7FFFFFFF) throw new LuaPlainException("\\u{...}: the code is too large", _line);
                                _i++;
                            }
                            if (Cur != '}') throw new LuaPlainException("\\u{...}: the closing brace is missing", _line);
                            _i++;
                            AppendUtf8(sb, (uint)code);
                            break;
                        }
                    default:
                        if (IsDigit(e))
                        {
                            int code = 0, n = 0;
                            while (n < 3 && IsDigit(Cur)) { code = code * 10 + (Cur - '0'); _i++; n++; }
                            if (code > 255) throw new LuaPlainException("a \\ddd escape is larger than 255", _line);
                            sb.Append((char)code);
                            break;
                        }
                        throw new LuaPlainException("\\" + e + " is not an escape Lua knows", _line);
                }
            }
            Tokens.Add(new Tok(K.Str, sb.ToString(), 0, 0, line));
        }

        // Lua's own encoding (UTF-8 extended to 31 bits), as byte text
        private static void AppendUtf8(StringBuilder sb, uint x)
        {
            if (x < 0x80) { sb.Append((char)x); return; }
            Span<char> buff = stackalloc char[8];
            int n = 1;
            uint mfb = 0x3f;        // the largest value that fits into the first byte
            do
            {
                buff[8 - n++] = (char)(0x80 | (x & 0x3f));
                x >>= 6;
                mfb >>= 1;
            } while (x > mfb);
            buff[8 - n] = (char)(((~mfb << 1) | x) & 0xFF);
            for (int k = 8 - n; k < 8; k++) sb.Append(buff[k]);
        }

        private void Number()
        {
            int st = _i, line = _line;
            bool hex = Cur == '0' && (At(1) == 'x' || At(1) == 'X');
            if (hex) _i += 2;
            while (!AtEnd)
            {
                char c = Cur;
                bool exponent = hex ? (c == 'p' || c == 'P') : (c == 'e' || c == 'E');
                if (exponent)
                {
                    _i++;
                    if (!AtEnd && (Cur == '+' || Cur == '-')) _i++;
                }
                else if (IsHex(c) || c == '.') _i++;
                else break;
            }
            if (!AtEnd && IsNameStart(Cur)) _i++;       // a letter that touches a number spoils it
            string t = _s[st.._i];
            if (hex)
            {
                if (!TryHex(t[2..], out bool isWhole, out long wholeHex, out double floatHex)) throw new LuaPlainException($"'{t}' is not a number", line);
                Tokens.Add(isWhole ? new Tok(K.Int, t, wholeHex, 0, line) : new Tok(K.Num, t, 0, floatHex, line));
                return;
            }
            if (t.All(IsDigit))
            {
                // a whole number; one that does not fit into 64 bits becomes a float
                if (long.TryParse(t, NumberStyles.None, CultureInfo.InvariantCulture, out long whole))
                {
                    Tokens.Add(new Tok(K.Int, t, whole, 0, line));
                    return;
                }
            }
            if (!IsDecimalFloat(t)) throw new LuaPlainException($"'{t}' is not a number", line);
            Tokens.Add(new Tok(K.Num, t, 0, double.Parse(t, NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent, CultureInfo.InvariantCulture), line));
        }
    }

    /// <summary>
    /// A hexadecimal number without its "0x": digits only = a whole number (it wraps around at 64 bits,
    /// as in Lua); digits [. digits] [p [+-] decimal digits] = a float (C99). More than 16 significant
    /// hexadecimal digits are cut off, not rounded.
    /// </summary>
    internal static bool TryHex(string body, out bool isWhole, out long whole, out double value)
    {
        isWhole = false; whole = 0; value = 0;
        if (body.Length > 0 && body.All(IsHex))
        {
            ulong v = 0;
            foreach (char d in body) v = unchecked(v * 16 + (ulong)HexValue(d));
            isWhole = true;
            whole = unchecked((long)v);
            value = whole;
            return true;
        }
        int i = 0, digits = 0, exponent = 0, kept = 0;
        ulong mantissa = 0;
        bool fraction = false;
        for (; i < body.Length; i++)
        {
            char c = body[i];
            if (c == '.') { if (fraction) return false; fraction = true; continue; }
            if (!IsHex(c)) break;
            digits++;
            if (mantissa == 0 && c == '0') { if (fraction) exponent -= 4; continue; }     // zeros in front carry no digits
            if (kept < 16) { mantissa = mantissa * 16 + (ulong)HexValue(c); kept++; if (fraction) exponent -= 4; }
            else if (!fraction) exponent += 4;
        }
        if (digits == 0) return false;
        if (i < body.Length)
        {
            if (body[i] != 'p' && body[i] != 'P') return false;
            i++;
            bool negative = false;
            if (i < body.Length && (body[i] == '+' || body[i] == '-')) { negative = body[i] == '-'; i++; }
            int e = 0, n = 0;
            for (; i < body.Length && IsDigit(body[i]); i++, n++) e = Math.Min(100000, e * 10 + (body[i] - '0'));
            if (n == 0 || i != body.Length) return false;
            exponent += negative ? -e : e;
        }
        value = Math.ScaleB((double)mantissa, exponent);
        return true;
    }

    /// <summary>digits [. digits] [e [+-] digits] with at least one digit in front of the exponent: what C's strtod takes as a decimal number.</summary>
    internal static bool IsDecimalFloat(string t)
    {
        int i = 0, digits = 0;
        while (i < t.Length && IsDigit(t[i])) { i++; digits++; }
        if (i < t.Length && t[i] == '.')
        {
            i++;
            while (i < t.Length && IsDigit(t[i])) { i++; digits++; }
        }
        if (digits == 0) return false;
        if (i < t.Length && (t[i] == 'e' || t[i] == 'E'))
        {
            i++;
            if (i < t.Length && (t[i] == '+' || t[i] == '-')) i++;
            int exp = 0;
            while (i < t.Length && IsDigit(t[i])) { i++; exp++; }
            if (exp == 0) return false;
        }
        return i == t.Length;
    }

    // =====================================================================
    // tokens -> values
    // =====================================================================
    private sealed class Runner
    {
        private readonly List<Tok> _t;
        private readonly bool _noNil;
        private int _p;
        private int _depth;
        private readonly Dictionary<string, object?> _locals = new(StringComparer.Ordinal);
        private readonly Dictionary<string, object?> _globals = new(StringComparer.Ordinal);

        public Runner(List<Tok> tokens, bool noNil) { _t = tokens; _noNil = noNil; }

        private Tok Peek => _t[_p];
        private Tok Next() => _t[_p++];
        private bool IsSym(string s) => Peek.Kind == K.Sym && Peek.Text == s;
        private bool IsName(string s) => Peek.Kind == K.Name && Peek.Text == s;

        private static string Shown(Tok t) => t.Kind == K.Str ? "a text" : "'" + t.Text + "'";

        private void Expect(string sym)
        {
            if (!IsSym(sym)) throw new LuaPlainException($"'{sym}' expected near {Shown(Peek)}", Peek.Line);
            _p++;
        }

        private string ExpectName()
        {
            if (Peek.Kind != K.Name || Reserved.Contains(Peek.Text)) throw new LuaPlainException($"a name expected near {Shown(Peek)}", Peek.Line);
            return Next().Text;
        }

        private object? Lookup(string name) =>
            _locals.TryGetValue(name, out object? v) ? v : _globals.TryGetValue(name, out v) ? v : null;

        private static string TypeName(object? v) => v switch
        {
            null => "nil", bool => "boolean", long or double => "number", string => "string", _ => "table",
        };

        private static object? Index(object? container, object? key, int line)
        {
            if (container is not PlainTable t)
                throw new LuaPlainException(container is string ? PlainOnly : $"a {TypeName(container)} value is used like a table", line);
            return key == null ? null : t.Get(key);
        }

        // one place a value can be assigned to: a name, or an entry of a table
        private readonly record struct Target(string? Name, PlainTable? Table, object? Key, int Line);

        public object? Chunk()
        {
            while (true)
            {
                Tok t = Peek;
                if (t.Kind == K.End) return null;                   // no return: the file gives nothing
                if (IsSym(";")) { _p++; continue; }
                if (IsName("local")) { _p++; Local(); continue; }
                if (IsName("return"))
                {
                    _p++;
                    object? result = null;
                    if (Peek.Kind != K.End && !IsSym(";")) result = ExprList()[0];
                    if (IsSym(";")) _p++;
                    if (Peek.Kind != K.End) throw new LuaPlainException($"nothing may follow the return line (found {Shown(Peek)})", Peek.Line);
                    return result;
                }
                if (t.Kind == K.Name && !Reserved.Contains(t.Text)) { Assignment(); continue; }
                if (t.Kind == K.Name) throw new LuaPlainException($"'{t.Text}': {PlainOnly}", t.Line);
                throw new LuaPlainException($"unexpected {Shown(t)}", t.Line);
            }
        }

        private void Local()
        {
            if (IsName("function")) throw new LuaPlainException("'function': " + PlainOnly, Peek.Line);
            var names = new List<string> { ExpectName() };
            if (IsSym("<")) throw new LuaPlainException("attributes of local names (<const>) are not supported", Peek.Line);
            while (IsSym(","))
            {
                _p++;
                names.Add(ExpectName());
                if (IsSym("<")) throw new LuaPlainException("attributes of local names (<const>) are not supported", Peek.Line);
            }
            List<object?> values = new();
            if (IsSym("=")) { _p++; values = ExprList(); }
            for (int i = 0; i < names.Count; i++) _locals[names[i]] = i < values.Count ? values[i] : null;
        }

        private Target Var()
        {
            Tok first = Peek;
            string name = ExpectName();
            if (!IsSym(".") && !IsSym("[")) return new Target(name, null, null, first.Line);
            object? container = Lookup(name);
            while (true)
            {
                int line = Peek.Line;
                object? key;
                if (IsSym(".")) { _p++; key = ExpectName(); }
                else { _p++; key = Expr(); Expect("]"); }
                if (IsSym(".") || IsSym("["))
                {
                    container = Index(container, key, line);
                    continue;
                }
                if (container is not PlainTable table)
                    throw new LuaPlainException(container is string ? PlainOnly : $"a {TypeName(container)} value is used like a table", line);
                return new Target(null, table, key, line);
            }
        }

        private void Assignment()
        {
            var targets = new List<Target> { Var() };
            while (IsSym(","))
            {
                _p++;
                targets.Add(Var());
            }
            if (!IsSym("="))
            {
                Tok t = Peek;
                if (t.Kind == K.Str || (t.Kind == K.Sym && t.Text is "(" or "{" or ":")) throw new LuaPlainException(PlainOnly, t.Line);
                throw new LuaPlainException($"'=' expected near {Shown(t)}", t.Line);
            }
            _p++;
            var values = ExprList();
            // Lua stores from the last name to the first
            for (int i = targets.Count - 1; i >= 0; i--)
            {
                Target target = targets[i];
                object? value = i < values.Count ? values[i] : null;
                if (target.Table != null)
                {
                    if (target.Key == null) throw new LuaPlainException("a table entry needs a key (the key is nil)", target.Line);
                    if (target.Key is double d && double.IsNaN(d)) throw new LuaPlainException("a table entry needs a key (the key is not a number)", target.Line);
                    target.Table.Set(target.Key, value);
                }
                else if (_locals.ContainsKey(target.Name!)) _locals[target.Name!] = value;
                else if (value == null) _globals.Remove(target.Name!);
                else _globals[target.Name!] = value;
            }
        }

        private List<object?> ExprList()
        {
            var list = new List<object?> { Expr() };
            while (IsSym(","))
            {
                _p++;
                list.Add(Expr());
            }
            return list;
        }

        private object? Expr()
        {
            object? v = Simple();
            // Lua would go on with an operator here
            Tok t = Peek;
            if (t.Kind == K.Sym && t.Text is "+" or "-" or "*" or "/" or "//" or "%" or "^" or ".." or "==" or "~=" or "<" or ">" or "<=" or ">="
                    or "&" or "|" or "~" or "<<" or ">>" or "#" or "...")
                throw new LuaPlainException($"'{t.Text}': {PlainOnly}", t.Line);
            if (t.Kind == K.Name && t.Text is "and" or "or" or "not") throw new LuaPlainException($"'{t.Text}': {PlainOnly}", t.Line);
            return v;
        }

        private object? Simple()
        {
            Tok t = Peek;
            switch (t.Kind)
            {
                case K.Int: _p++; return t.Int;
                case K.Num: _p++; return t.Num;
                case K.Str: _p++; return t.Text;
                case K.Name:
                    if (t.Text == "true") { _p++; return true; }
                    if (t.Text == "false") { _p++; return false; }
                    if (t.Text == "nil")
                    {
                        if (_noNil) throw new LuaPlainException("nil is not a value a schema can hold", t.Line);
                        _p++;
                        return null;
                    }
                    if (Reserved.Contains(t.Text)) throw new LuaPlainException($"'{t.Text}': {PlainOnly}", t.Line);
                    {
                        // a name that was set before, or one of its fields
                        _p++;
                        object? v = Lookup(t.Text);
                        while (IsSym(".") || IsSym("["))
                        {
                            int line = Peek.Line;
                            object? key;
                            if (IsSym(".")) { _p++; key = ExpectName(); }
                            else { _p++; key = Expr(); Expect("]"); }
                            v = Index(v, key, line);
                        }
                        Tok after = Peek;
                        if (after.Kind == K.Str || (after.Kind == K.Sym && after.Text is "(" or "{" or ":"))
                            throw new LuaPlainException(PlainOnly, after.Line);
                        return v;
                    }
                case K.Sym:
                    if (t.Text == "-")
                    {
                        _p++;
                        Tok n = Peek;
                        if (n.Kind == K.Int) { _p++; return unchecked(-n.Int); }
                        if (n.Kind == K.Num) { _p++; return -n.Num; }
                        throw new LuaPlainException($"a number expected after '-' ({PlainOnly})", n.Line);
                    }
                    if (t.Text == "{") return Table();
                    if (t.Text is "(" or "#" or "~" or "...") throw new LuaPlainException($"'{t.Text}': {PlainOnly}", t.Line);
                    break;
            }
            throw new LuaPlainException($"a value expected near {Shown(t)}", t.Line);
        }

        private PlainTable Table()
        {
            int open = Peek.Line;
            Expect("{");
            if (++_depth > MaxDepth) throw new LuaPlainException("tables are nested too deeply", open);
            var table = new PlainTable();
            var positional = new List<object?>();
            while (!IsSym("}"))
            {
                if (Peek.Kind == K.End) throw new LuaPlainException($"'}}' expected (the table opened in line {open} is not closed)", Peek.Line);
                if (IsSym("["))
                {
                    int line = Peek.Line;
                    _p++;
                    object? key = Expr();
                    Expect("]");
                    Expect("=");
                    object? v = Expr();
                    if (key == null) throw new LuaPlainException("a table entry needs a key (the key is nil)", line);
                    table.Set(key, v);
                }
                else if (Peek.Kind == K.Name && !Reserved.Contains(Peek.Text) && _t[_p + 1].Kind == K.Sym && _t[_p + 1].Text == "=")
                {
                    string name = Next().Text;
                    _p++;
                    table.Set(name, Expr());
                }
                else positional.Add(Expr());
                if (IsSym(",") || IsSym(";")) { _p++; continue; }
                if (!IsSym("}")) throw new LuaPlainException($"',' or '}}' expected near {Shown(Peek)}", Peek.Line);
            }
            Expect("}");
            _depth--;
            // the entries without a key are stored last: they win over [1] = ...
            foreach (object? v in positional) table.Append(v);
            return table;
        }
    }

    /// <summary>
    /// Runs the text (byte text; a byte order mark in front is skipped) and returns what it returns.
    /// hashLine: skip a first line that starts with '#', as Lua does for a file it loads.
    /// noNil: nil is refused (a schema holds no nil).
    /// </summary>
    public static object? Run(string byteText, bool hashLine = false, bool noNil = false)
    {
        int start = byteText.StartsWith(ByteText.Bom, StringComparison.Ordinal) ? ByteText.Bom.Length : 0;
        if (hashLine && start < byteText.Length && byteText[start] == '#')
            while (start < byteText.Length && byteText[start] != '\n') start++;     // the line end stays: line numbers are right
        var lexer = new Lexer(byteText, start);
        lexer.Run();
        return new Runner(lexer.Tokens, noNil).Chunk();
    }

    // =====================================================================
    // Lua's own conversions
    // =====================================================================
    /// <summary>
    /// Lua's tonumber for a text: white space around it is allowed, a sign, decimal or hexadecimal
    /// whole numbers, decimal numbers with a fraction and an exponent. null = not a number ("", "abc",
    /// "1e", "inf", "nan", "5,5").
    /// </summary>
    public static double? TextToNumber(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && ByteText.IsSpace(s[a])) a++;
        while (b > a && ByteText.IsSpace(s[b - 1])) b--;
        if (a == b) return null;
        bool negative = false;
        if (s[a] == '-') { negative = true; a++; }
        else if (s[a] == '+') a++;
        string t = s[a..b];
        if (t.Length == 0) return null;
        if (t.Length >= 2 && t[0] == '0' && (t[1] == 'x' || t[1] == 'X'))
        {
            if (!TryHex(t[2..], out _, out _, out double hex)) return null;
            return negative ? -hex : hex;
        }
        if (!IsDecimalFloat(t)) return null;
        double n = double.Parse(t, NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent, CultureInfo.InvariantCulture);
        return negative ? -n : n;
    }

    /// <summary>
    /// Lua's tostring for a plain value. Floats: C's "%.14g" (exact ties in the 15th digit may round
    /// the other way), and ".0" behind a float that looks like a whole number.
    /// </summary>
    public static string ToText(object? v)
    {
        switch (v)
        {
            case null: return "nil";
            case bool b: return b ? "true" : "false";
            case long i: return i.ToString(CultureInfo.InvariantCulture);
            case string s: return s;
            case double d:
                {
                    if (double.IsNaN(d)) return "nan";
                    if (double.IsInfinity(d)) return d > 0 ? "inf" : "-inf";
                    string e = d.ToString("E13", CultureInfo.InvariantCulture);         // d.ddddddddddddde+XXX
                    int ePos = e.IndexOf('E');
                    int exponent = int.Parse(e[(ePos + 1)..], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
                    string text;
                    if (exponent < -4 || exponent >= 14)
                    {
                        string mantissa = e[..ePos].TrimEnd('0').TrimEnd('.');
                        text = mantissa + "e" + (exponent < 0 ? "-" : "+") + Math.Abs(exponent).ToString("00", CultureInfo.InvariantCulture);
                    }
                    else
                    {
                        text = d.ToString("F" + (13 - exponent).ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
                        if (text.Contains('.')) text = text.TrimEnd('0').TrimEnd('.');
                    }
                    if (text.All(ch => IsDigit(ch) || ch == '-')) text += ".0";
                    return text;
                }
            default: return "table";
        }
    }
}
