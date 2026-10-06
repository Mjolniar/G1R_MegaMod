using System.ComponentModel;
using System.Drawing.Drawing2D;

namespace G1RRepopulateSettings;

/// <summary>
/// The pane on the left of the window, in the style of the task pane of the Windows XP Explorer: a
/// blue gradient with boxes on it. A box has a header (its title and a round button that folds the
/// box away) and lines below it. A line is one of a set of choices (the categories of the settings:
/// the chosen one is bold), a link that does something when it is pressed, or plain text.
/// Keyboard: the pane takes the focus as one control. Up, Down, Home and End move along the choices
/// and links - a choice is chosen when it is reached -, Enter or Space presses a link.
/// </summary>
internal sealed class XpTaskPane : Control
{
    public enum Kind { Choice, Link, Text }

    /// <summary>One line of a box.</summary>
    public sealed class Entry
    {
        public Kind Kind;
        public string Text = "";
        public object? Tag;
        /// <summary>A star behind the text: something of it is not saved yet.</summary>
        public bool Marked;
        public bool Enabled = true;
        /// <summary>Text: one line, shortened in the middle when it does not fit (a path). Other text wraps.</summary>
        public bool OneLine;
        public string Tip = "";
        public Box Owner { get; internal set; } = null!;
        /// <summary>Where the line is (empty while its box is folded away).</summary>
        public Rectangle Bounds { get; internal set; }
    }

    /// <summary>One box of the pane.</summary>
    public sealed class Box
    {
        public string Title = "";
        public bool Folded;
        public readonly List<Entry> Entries = new();
        public Rectangle Header { get; internal set; }
        public Rectangle Body { get; internal set; }
    }

    private static readonly Color PaneTop = Xp.C(0x7BA2E7), PaneBottom = Xp.C(0x6375D6);
    private static readonly Color HeaderEnd = Xp.C(0xC6D3F7), BodyBack = Xp.C(0xD6DFF7);
    private static readonly Color LinkText = Xp.C(0x215DC6), LinkHot = Xp.C(0x428EFF), ChosenText = Xp.C(0x00138C);

    private readonly List<Box> _boxes = new();
    private Entry? _chosen, _focus, _hot, _down;
    private Box? _hotHeader;

    /// <summary>The user chose another choice (with the mouse or the keys).</summary>
    public event Action<Entry>? Choose;
    /// <summary>The user pressed a link.</summary>
    public event Action<Entry>? Press;

    /// <summary>Where the tips of the lines are shown (the window's tool tip).</summary>
    [Browsable(false), DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public ToolTip? Tips { get; set; }

    public XpTaskPane()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw
            | ControlStyles.Selectable | ControlStyles.StandardClick, true);
        Font = Xp.UiFont;
        TabStop = true;
        Width = 186;
    }

    public IReadOnlyList<Box> Boxes => _boxes;

    public Box AddBox(string title)
    {
        var box = new Box { Title = title };
        _boxes.Add(box);
        return box;
    }

    public Entry Add(Box box, Kind kind, string text, object? tag = null)
    {
        var entry = new Entry { Kind = kind, Text = text, Tag = tag, Owner = box };
        box.Entries.Add(entry);
        return entry;
    }

    /// <summary>The chosen choice. Setting it does not raise Choose.</summary>
    [Browsable(false), DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public Entry? Chosen
    {
        get => _chosen;
        set
        {
            if (_chosen == value) return;
            // (the focus follows the choice while it stands on a choice: the keys go on from where the window is)
            if (_focus == null || _focus.Kind == Kind.Choice) _focus = value;
            _chosen = value;
            Invalidate();
        }
    }

    /// <summary>The line the keys act on (it carries the focus mark while the pane has the focus).</summary>
    public Entry? Focused2 => _focus;

    /// <summary>Texts, marks or the set of lines changed: lay out and paint again.</summary>
    public void Changed()
    {
        Arrange();
        Invalidate();
    }

    private int Px(float v) => (int)Math.Round(v * Xp.Scale(this));

    private IEnumerable<Entry> Reachable() => _boxes.Where(b => !b.Folded).SelectMany(b => b.Entries).Where(e => e.Kind != Kind.Text && e.Enabled);

    // =====================================================================
    // layout
    // =====================================================================
    private static string Shown(Entry e) => e.Marked ? e.Text + " *" : e.Text;

    private void Arrange()
    {
        int margin = Px(12), headerHeight = Px(25), gap = Px(14), padX = Px(12), padTop = Px(9), padBottom = Px(10), between = Px(5);
        int width = Math.Max(Px(60), Width - 2 * margin), inner = Math.Max(Px(30), width - 2 * padX);
        int lineHeight = Math.Max(Px(15), TextRenderer.MeasureText("Ag", Xp.UiBold, Size.Empty, TextFormatFlags.NoPadding).Height + Px(2));
        int y = margin;
        foreach (var box in _boxes)
        {
            box.Header = new Rectangle(margin, y, width, headerHeight);
            y += headerHeight;
            if (box.Folded)
            {
                box.Body = Rectangle.Empty;
                foreach (var e in box.Entries) e.Bounds = Rectangle.Empty;
            }
            else
            {
                int top = y, at = y + padTop;
                foreach (var e in box.Entries)
                {
                    int height = lineHeight;
                    if (e.Kind == Kind.Text && !e.OneLine)
                        height = Math.Max(lineHeight, TextRenderer.MeasureText(Shown(e), Xp.UiFont, new Size(inner, 0), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding).Height);
                    e.Bounds = new Rectangle(margin + padX, at, inner, height);
                    at += height + between;
                }
                y = (box.Entries.Count > 0 ? at - between : at) + padBottom;
                box.Body = new Rectangle(margin, top, width, y - top);
            }
            y += gap;
        }
    }

    /// <summary>The height the boxes need (the pane is not scrolled: what does not fit is cut off).</summary>
    public int NeededHeight
    {
        get
        {
            Arrange();
            var last = _boxes.LastOrDefault();
            return last == null ? 0 : (last.Folded ? last.Header.Bottom : last.Body.Bottom) + Px(12);
        }
    }

    protected override void OnLayout(LayoutEventArgs levent)
    {
        base.OnLayout(levent);
        Arrange();
    }

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        Arrange();
    }

    // =====================================================================
    // painting
    // =====================================================================
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        Xp.VGradient(g, ClientRectangle, PaneTop, PaneBottom);
        float s = Xp.Scale(this);
        foreach (var box in _boxes)
        {
            DrawHeader(g, box, s);
            if (box.Folded) continue;
            using (var back = new SolidBrush(BodyBack)) g.FillRectangle(back, box.Body);
            using (var edge = new Pen(Color.White))
            {
                g.DrawLine(edge, box.Body.Left, box.Body.Top, box.Body.Left, box.Body.Bottom - 1);
                g.DrawLine(edge, box.Body.Right - 1, box.Body.Top, box.Body.Right - 1, box.Body.Bottom - 1);
                g.DrawLine(edge, box.Body.Left, box.Body.Bottom - 1, box.Body.Right - 1, box.Body.Bottom - 1);
            }
            foreach (var entry in box.Entries) DrawEntry(g, entry);
        }
    }

    private void DrawHeader(Graphics g, Box box, float s)
    {
        var r = box.Header;
        if (r.Width <= 0) return;
        var old = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = Xp.RoundTop(new RectangleF(r.X, r.Y, r.Width, r.Height), 4f * s))
        using (var fill = new LinearGradientBrush(new Rectangle(r.X - 1, r.Y, r.Width + 2, r.Height), Color.White, HeaderEnd, LinearGradientMode.Horizontal))
            g.FillPath(fill, path);
        bool hot = _hotHeader == box;
        // the round button: two chevrons that point up while the box is open, down while it is folded away
        int size = Px(17);
        var button = new RectangleF(r.Right - size - Px(5), r.Y + (r.Height - size) / 2f, size, size);
        using (var face = new SolidBrush(Color.White)) g.FillEllipse(face, button);
        using (var rim = new Pen(hot ? LinkHot : Xp.C(0x9BB7EC))) g.DrawEllipse(rim, button);
        using (var stroke = new Pen(hot ? LinkHot : LinkText, Math.Max(1.2f, 1.25f * s)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
        {
            float cx = button.X + button.Width / 2f, cy = button.Y + button.Height / 2f, w = 3f * s, h = 2.4f * s;
            for (int i = 0; i < 2; i++)
            {
                float y = cy + (i == 0 ? -3.7f * s : 0.5f * s);
                PointF[] v = box.Folded
                    ? new[] { new PointF(cx - w, y), new PointF(cx, y + h), new PointF(cx + w, y) }
                    : new[] { new PointF(cx - w, y + h), new PointF(cx, y), new PointF(cx + w, y + h) };
                g.DrawLines(stroke, v);
            }
        }
        g.SmoothingMode = old;
        var text = new Rectangle(r.X + Px(11), r.Y, Math.Max(0, r.Width - size - Px(20)), r.Height);
        TextRenderer.DrawText(g, box.Title, Xp.UiBold, text, hot ? LinkHot : LinkText,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }

    private void DrawEntry(Graphics g, Entry entry)
    {
        var r = entry.Bounds;
        if (r.Width <= 0) return;
        if (entry.Kind == Kind.Text)
        {
            var flags = entry.OneLine
                ? TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.PathEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding
                : TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;
            TextRenderer.DrawText(g, Shown(entry), Xp.UiFont, r, Color.Black, flags);
            return;
        }
        bool chosen = entry.Kind == Kind.Choice && entry == _chosen;
        bool hot = entry == _hot && entry.Enabled;
        Font font = chosen ? Xp.UiBold : Xp.UiFont;
        Color color = !entry.Enabled ? Xp.DisabledText : chosen ? ChosenText : hot ? LinkHot : LinkText;
        var size = TextRenderer.MeasureText(Shown(entry), font, Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
        TextRenderer.DrawText(g, Shown(entry), font, r, color,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding);
        int textWidth = Math.Min(size.Width, r.Width);
        if (hot && !chosen)
        {
            int y = r.Y + (r.Height + size.Height) / 2 - Px(1);
            using var line = new Pen(color);
            g.DrawLine(line, r.X, y, r.X + textWidth - 1, y);
        }
        if (Focused && ShowFocusCues && entry == _focus)
            ControlPaint.DrawFocusRectangle(g, new Rectangle(r.X - Px(3), r.Y - 1, Math.Min(r.Width + Px(6), textWidth + Px(7)), r.Height + 2), Color.Black, BodyBack);
    }

    // =====================================================================
    // mouse
    // =====================================================================
    public Entry? EntryAt(Point p) => _boxes.Where(b => !b.Folded).SelectMany(b => b.Entries).FirstOrDefault(e => e.Bounds.Contains(p));
    private Box? HeaderAt(Point p) => _boxes.FirstOrDefault(b => b.Header.Contains(p));

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var entry = EntryAt(e.Location);
        var header = entry == null ? HeaderAt(e.Location) : null;
        if (entry == _hot && header == _hotHeader) return;
        bool tipChanged = entry != _hot;
        _hot = entry;
        _hotHeader = header;
        Cursor = header != null || (entry != null && entry.Kind != Kind.Text && entry.Enabled) ? Cursors.Hand : Cursors.Default;
        if (tipChanged) Tips?.SetToolTip(this, entry?.Tip is { Length: > 0 } tip ? tip : null);
        Invalidate();
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        if (_hot == null && _hotHeader == null) return;
        _hot = null;
        _hotHeader = null;
        Cursor = Cursors.Default;
        Invalidate();
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        Focus();
        _down = EntryAt(e.Location);
        var header = _down == null ? HeaderAt(e.Location) : null;
        if (header != null) Fold(header, !header.Folded);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        var entry = EntryAt(e.Location);
        if (e.Button == MouseButtons.Left && entry != null && entry == _down) Activate(entry);
        _down = null;
    }

    /// <summary>Folds a box away or opens it.</summary>
    public void Fold(Box box, bool folded)
    {
        if (box.Folded == folded) return;
        box.Folded = folded;
        if (folded && _focus != null && _focus.Owner == box) _focus = Reachable().FirstOrDefault(x => x == _chosen) ?? Reachable().FirstOrDefault();
        Changed();
    }

    /// <summary>What a click on the line, or Enter on it, does: a choice is chosen, a link pressed.</summary>
    public void Activate(Entry entry)
    {
        if (!entry.Enabled || entry.Kind == Kind.Text) return;
        _focus = entry;
        if (entry.Kind == Kind.Choice)
        {
            if (entry != _chosen)
            {
                _chosen = entry;
                Invalidate();
                Choose?.Invoke(entry);
            }
        }
        else Press?.Invoke(entry);
        Invalidate();
    }

    // =====================================================================
    // keys
    // =====================================================================
    protected override bool IsInputKey(Keys keyData)
    {
        Keys key = keyData & Keys.KeyCode;
        return key is Keys.Up or Keys.Down or Keys.Home or Keys.End || base.IsInputKey(keyData);
    }

    /// <summary>A key pressed on the pane. Returns whether the pane used it.</summary>
    public bool TakeKey(Keys key)
    {
        var lines = Reachable().ToList();
        if (lines.Count == 0) return false;
        int at = _focus != null ? lines.IndexOf(_focus) : -1;
        int to;
        switch (key)
        {
            case Keys.Up: to = at < 0 ? lines.Count - 1 : Math.Max(0, at - 1); break;
            case Keys.Down: to = at < 0 ? 0 : Math.Min(lines.Count - 1, at + 1); break;
            case Keys.Home: to = 0; break;
            case Keys.End: to = lines.Count - 1; break;
            case Keys.Enter:
            case Keys.Space:
                if (at < 0) return false;
                Activate(lines[at]);
                return true;
            default: return false;
        }
        var target = lines[to];
        _focus = target;
        if (target.Kind == Kind.Choice) Activate(target);        // (a choice is chosen when the keys reach it, as in a list)
        Invalidate();
        return true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (!e.Control && !e.Alt && TakeKey(e.KeyCode))
        {
            e.Handled = true;
            e.SuppressKeyPress = true;
        }
        base.OnKeyDown(e);
    }

    protected override void OnGotFocus(EventArgs e)
    {
        if (_focus == null || !Reachable().Contains(_focus)) _focus = Reachable().FirstOrDefault(x => x == _chosen) ?? Reachable().FirstOrDefault();
        Invalidate();
        base.OnGotFocus(e);
    }

    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
}

/// <summary>Something the Find box can go to: a tab, or a setting on a tab.</summary>
internal sealed class FindEntry
{
    /// <summary>The name shown: the label of a setting, or the path of a tab.</summary>
    public string Label = "";
    /// <summary>What is searched, in lower case: name, hint, key, group, page.</summary>
    public string Words = "";
    public NavTab Tab = null!;
    /// <summary>The control to go to (null: the tab itself).</summary>
    public Control? Target;
    /// <summary>The line of the list.</summary>
    public string Shown => Target == null ? Tab.Path : Label + "   -   " + Tab.Path;
}

/// <summary>
/// The list below the Find box: what was found, one line each - the name on the left, the page on
/// the right. The line under the mouse, or the one the arrow keys moved to, is selected; a click
/// (or Enter in the box) goes there. More than fits: the last line says how many more there are.
/// </summary>
internal sealed class FindList : Control
{
    public const int MaxLines = 12;
    private readonly List<FindEntry> _entries = new();
    private int _selected = -1, _total;

    public event Action<FindEntry>? Picked;

    public FindList()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        SetStyle(ControlStyles.Selectable, false);
        Font = Xp.UiFont;
        TabStop = false;
    }

    /// <summary>The lines shown.</summary>
    public IReadOnlyList<FindEntry> Entries => _entries;
    /// <summary>How many were found (the list shows the first MaxLines of them).</summary>
    public int Total => _total;
    public FindEntry? Selected => _selected >= 0 && _selected < _entries.Count ? _entries[_selected] : null;

    private int RowHeight => Math.Max((int)Math.Round(18 * Xp.Scale(this)), Font.Height + 4);
    private int Rows => Math.Max(1, _entries.Count) + (_total > _entries.Count ? 1 : 0);
    public int NeededHeight => Rows * RowHeight + 2;

    public void Show(List<FindEntry> found)
    {
        _total = found.Count;
        _entries.Clear();
        _entries.AddRange(found.Take(MaxLines));
        _selected = _entries.Count > 0 ? 0 : -1;
        Invalidate();
    }

    public void Select(int line)
    {
        if (line < 0 || line >= _entries.Count) return;
        _selected = line;
        Invalidate();
    }

    public void Step(int by)
    {
        if (_entries.Count == 0) return;
        _selected = Math.Clamp((_selected < 0 ? (by > 0 ? -1 : _entries.Count) : _selected) + by, 0, _entries.Count - 1);
        Invalidate();
    }

    private int LineAt(Point p)
    {
        int line = (p.Y - 1) / RowHeight;
        return p.Y >= 1 && line >= 0 && line < _entries.Count ? line : -1;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        int line = LineAt(e.Location);
        if (line >= 0 && line != _selected) { _selected = line; Invalidate(); }
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        int line = LineAt(e.Location);
        if (e.Button == MouseButtons.Left && line >= 0) Picked?.Invoke(_entries[line]);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        using (var back = new SolidBrush(Color.White)) g.FillRectangle(back, ClientRectangle);
        int h = RowHeight, pad = (int)Math.Round(6 * Xp.Scale(this));
        const TextFormatFlags Line = TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix;
        if (_entries.Count == 0)
            TextRenderer.DrawText(g, "Nothing found.", Font, new Rectangle(pad, 1, Width - 2 * pad, h), Xp.Hint, Line | TextFormatFlags.Left);
        for (int i = 0; i < _entries.Count; i++)
        {
            var row = new Rectangle(1, 1 + i * h, Width - 2, h);
            bool selected = i == _selected;
            if (selected) { using var sel = new SolidBrush(Xp.Selection); g.FillRectangle(sel, row); }
            var entry = _entries[i];
            string path = entry.Tab.Path;
            int pathWidth = entry.Target == null ? 0 : Math.Min(TextRenderer.MeasureText(path, Font, Size.Empty, TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix).Width + pad, row.Width / 2);
            var left = new Rectangle(row.X + pad, row.Y, Math.Max(0, row.Width - 2 * pad - pathWidth), h);
            TextRenderer.DrawText(g, entry.Label, Font, left, selected ? Color.White : Color.Black, Line | TextFormatFlags.Left);
            if (entry.Target != null)
                TextRenderer.DrawText(g, path, Font, new Rectangle(row.Right - pad - pathWidth, row.Y, pathWidth, h), selected ? Color.White : Xp.Hint, Line | TextFormatFlags.Right);
        }
        if (_total > _entries.Count)
            TextRenderer.DrawText(g, $"... and {_total - _entries.Count} more: type more of the name.", Font, new Rectangle(pad, 1 + _entries.Count * h, Width - 2 * pad, h), Xp.Hint, Line | TextFormatFlags.Left);
        using var border = new Pen(Xp.FieldBorder);
        g.DrawRectangle(border, 0, 0, Width - 1, Height - 1);
    }
}
