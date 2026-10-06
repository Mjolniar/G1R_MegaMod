using System.ComponentModel;
using System.Globalization;

namespace G1RRepopulateSettings;

/// <summary>
/// A box that takes the next key combination pressed: click it (or press Enter / Space on it), then
/// press the key - with CTRL, SHIFT, ALT held or not. The combination is kept in the usual spelling
/// of the mod ("Y", "CTRL+Y", "SHIFT+ALT+F5"; "" = no key). Escape leaves the box as it was; a key
/// that has no name in UE4SS is refused, and Hint says so. The middle and the two extra mouse
/// buttons can be bound by pressing them on the box while it listens.
/// </summary>
internal sealed class XpKeyBox : Control
{
    private const int WM_SYSKEYUP = 0x0105, WM_SYSCHAR = 0x0106;
    private const string Waiting = "Press a key ...";
    private const string None = "(no key)";

    private string _value = "";
    private string _partial = "";       // the modifiers held so far, while listening
    private string _hint = "";
    private bool _listening;

    public event EventHandler? ValueChanged;
    public event EventHandler? HintChanged;

    public XpKeyBox()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw
            | ControlStyles.Selectable | ControlStyles.StandardClick, true);
        Font = Xp.UiFont;
        TabStop = true;
        Size = new Size(230, 21);
        Anchor = AnchorStyles.Left;
    }

    /// <summary>The key combination in its usual spelling; "" = no key. Anything that names no key is ignored.</summary>
    [Browsable(false), DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public string Value
    {
        get => _value;
        set
        {
            string? usual = KeyNames.Combo(value ?? "");
            if (usual == null || usual == _value) return;
            _value = usual;
            Invalidate();
            ValueChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>What the box has to say about the last key it did not take ("" = nothing).</summary>
    public string Hint => _hint;

    /// <summary>The next key press is taken as the new combination.</summary>
    public bool Listening => _listening;

    /// <summary>The text the box shows.</summary>
    public string ShownText => _listening ? (_partial.Length > 0 ? _partial : Waiting) : _value.Length == 0 ? None : _value;

    private void SetHint(string text)
    {
        if (_hint == text) return;
        _hint = text;
        HintChanged?.Invoke(this, EventArgs.Empty);
    }

    public void StartListening()
    {
        if (!Enabled || _listening) return;
        _listening = true;
        _partial = "";
        SetHint("");
        Invalidate();
    }

    public void StopListening()
    {
        if (!_listening) return;
        _listening = false;
        _partial = "";
        Invalidate();
    }

    /// <summary>
    /// A key press while the box listens (the virtual-key code with the flags of the modifiers held).
    /// Returns whether it was taken as the new combination.
    /// </summary>
    public bool TakeKey(Keys keyData)
    {
        if (!_listening) return false;
        int code = (int)(keyData & Keys.KeyCode);
        bool ctrl = (keyData & Keys.Control) != 0, shift = (keyData & Keys.Shift) != 0, alt = (keyData & Keys.Alt) != 0;
        if (code is 0x10 or 0x11 or 0x12 or (>= 0xA0 and <= 0xA5))
        {
            // CTRL, SHIFT or ALT alone: the key itself is still to come
            _partial = KeyNames.Build(ctrl, shift, alt, "...");
            Invalidate();
            return false;
        }
        if (code == 0x1B)
        {
            StopListening();
            SetHint("Escape cannot be bound.");
            return false;
        }
        string? name = KeyNames.NameOf(code);
        if (name == null)
        {
            _partial = "";
            SetHint(code is 0x5B or 0x5C ? "The Windows keys cannot be bound."
                : code is 0x01 or 0x02 ? "The left and right mouse buttons cannot be bound."
                : "That key cannot be bound.");
            Invalidate();
            return false;       // still listening
        }
        StopListening();
        SetHint("");
        Value = KeyNames.Build(ctrl, shift, alt, name);
        return true;
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (!Enabled) return;
        if (e.Button == MouseButtons.Left)
        {
            Focus();
            StartListening();
        }
        else if (_listening)
        {
            int code = e.Button switch { MouseButtons.Middle => 0x04, MouseButtons.XButton1 => 0x05, MouseButtons.XButton2 => 0x06, MouseButtons.Right => 0x02, _ => 0 };
            if (code != 0) TakeKey((Keys)code | ModifierKeys);
        }
    }

    // a modifier was let go without a key: the box shows the ones still held
    private void ShowHeld()
    {
        Keys held = ModifierKeys;
        bool ctrl = (held & Keys.Control) != 0, shift = (held & Keys.Shift) != 0, alt = (held & Keys.Alt) != 0;
        _partial = ctrl || shift || alt ? KeyNames.Build(ctrl, shift, alt, "...") : "";
        Invalidate();
    }

    protected override void OnKeyUp(KeyEventArgs e)
    {
        if (_listening) ShowHeld();
        base.OnKeyUp(e);
    }

    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { StopListening(); Invalidate(); base.OnLostFocus(e); }

    protected override void OnEnabledChanged(EventArgs e)
    {
        if (!Enabled) { StopListening(); SetHint(""); }
        Invalidate();
        base.OnEnabledChanged(e);
    }

    // Every key goes through here before anything else looks at it: while the box listens it takes
    // them all - Tab, Enter, the arrows, ALT combinations and F10 too.
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        // A key that is held down comes again and again: only its first press counts (else Enter held a
        // little too long would open the box and be taken as the key at once).
        bool held = (msg.LParam.ToInt64() & 0x40000000) != 0;
        if (_listening)
        {
            int code = (int)(keyData & Keys.KeyCode);
            bool modifier = code is 0x10 or 0x11 or 0x12 or (>= 0xA0 and <= 0xA5);
            if (!held || modifier) TakeKey(keyData);
            return true;
        }
        if (keyData == Keys.Enter || keyData == Keys.Space)
        {
            if (!held) StartListening();
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void WndProc(ref Message m)
    {
        // an ALT pressed for the box must not open the window's menu
        if (_listening && (m.Msg == WM_SYSKEYUP || m.Msg == WM_SYSCHAR))
        {
            if (m.Msg == WM_SYSKEYUP) ShowHeld();
            return;
        }
        base.WndProc(ref m);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        Color back = !Enabled ? Xp.C(0xF5F4EA) : _listening ? Xp.TooltipBack : Color.White;
        using (var b = new SolidBrush(back)) g.FillRectangle(b, ClientRectangle);
        Color color = !Enabled ? Xp.DisabledText : !_listening && _value.Length == 0 ? Xp.Hint : Color.Black;
        var tr = new Rectangle(4, 0, Math.Max(0, Width - 8), Height);
        TextRenderer.DrawText(g, ShownText, Font, tr, color,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        using var p = new Pen(!Enabled ? Xp.DisabledBorder : _listening ? Xp.C(0xF8B330) : Xp.FieldBorder);
        g.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
        if (Focused && !_listening && ShowFocusCues)
            ControlPaint.DrawFocusRectangle(g, Rectangle.Inflate(ClientRectangle, -2, -2), Color.Black, back);
    }
}

/// <summary>
/// The tabs made from the modules' schemas (dev/SETTINGS.md section 5 of the mod), laid out as the
/// navigation model says (NavModel: which group stands on which tab, under which title): per group
/// a group box with its hint, per item a control - switch: check box; number: number box with the
/// unit behind it; choice: drop-down list; text: text box; key: key box with a button that clears
/// it. The comment of an item is its tool tip; an item that needs a switch is greyed while that
/// switch is off - also when the switch stands on another tab; the notes of a module stand below
/// the last of its groups on the tab that is the module's own. A tab that is longer than the
/// window scrolls.
/// Every control remembers what the app put into it. What is saved are the controls that no
/// longer show that: a control nobody touched never causes a write, whatever its file held.
/// </summary>
internal sealed class SchemaPages
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    private static readonly Color Warning = Xp.C(0xB55A00);

    /// <summary>One setting on a page.</summary>
    internal sealed class ItemUi
    {
        public ModuleSettings Module = null!;
        public SchemaItem Item = null!;
        /// <summary>XpCheckBox, XpNumericUpDown, XpComboBox, XpTextBox or XpKeyBox, by the item's kind.</summary>
        public Control Input = null!;
        /// <summary>What is greyed with the item: the input, its labels, the button of a key box.</summary>
        public readonly List<Control> Row = new();
        /// <summary>What the app put into the control: bool, decimal, int (index of the choice) or string.</summary>
        public object Shown = false;
        public Label? Hint;         // key boxes: what the box says about a key it did not take
        public XpButton? Clear;     // key boxes: sets no key
        /// <summary>The tab the setting stands on, and the title of its group box there.</summary>
        public PageUi Page = null!;
        public string GroupTitle = "";
    }

    /// <summary>One tab.</summary>
    internal sealed class PageUi
    {
        public NavTab Model = null!;
        public TabPage Tab = null!;
        /// <summary>null on a page that only says why a module's settings cannot be shown.</summary>
        public XpScrollPanel? Scroll;
        public readonly List<XpGroupBox> Groups = new();
        /// <summary>
        /// Per module whose own tab this is: what there is to say about its config.lua (hidden while there is nothing).
        /// </summary>
        public readonly Dictionary<ModuleSettings, Label> FileNotes = new();
        public readonly List<Label> Texts = new();      // hints, notes, the problem sentence
        public readonly List<ItemUi> Items = new();     // the settings on this tab
    }

    public readonly List<PageUi> Pages = new();
    public readonly List<ItemUi> Items = new();
    private readonly Dictionary<(ModuleSettings, string), ItemUi> _byKey = new();
    private readonly List<ModuleSettings> _modules = new();
    // what went wrong while a module's values were put into its controls (nothing on these pages may take the window down)
    private readonly Dictionary<ModuleSettings, string> _showProblems = new();
    private readonly ToolTip _tip;
    private readonly Action _changed;
    private bool _loading;

    private readonly NavModel _nav;

    /// <summary>
    /// nav: the layout (in the standalone layout it has no tabs made from schemas: no pages here).
    /// changed: called when the user changed a value.
    /// </summary>
    public SchemaPages(NavModel nav, ToolTip tip, Action changed)
    {
        _nav = nav;
        _tip = tip;
        _changed = changed;
        foreach (var model in nav.Tabs)
        {
            if (model.Kind != NavKind.Schema && model.Kind != NavKind.Problem) continue;
            PageUi page;
            try { page = Build(model, null); }
            catch (Exception ex)
            {
                // a tab that cannot be built must not take the app down: it says so instead
                page = Build(model, $"The page {model.Path} cannot be shown: {ex.Message}.");
            }
            Pages.Add(page);
        }
        // the modules with controls, in the order of the tabs (the order they are saved in)
        foreach (var ui in Items)
            if (!_modules.Contains(ui.Module)) _modules.Add(ui.Module);
        // (a module that shows nothing but notes has no file to look after)
    }

    /// <summary>The modules whose settings are on the pages, in the order of the tabs.</summary>
    public IReadOnlyList<ModuleSettings> Modules => _modules;

    public ItemUi? Find(string module, string key) => Items.FirstOrDefault(i => i.Module.Name == module && i.Item.Key == key);

    /// <summary>The page of a tab of the layout (null for the tabs that are not made here).</summary>
    public PageUi? PageOf(NavTab tab) => Pages.FirstOrDefault(p => p.Model == tab);

    // =====================================================================
    // building
    // =====================================================================
    private static TabPage NewTab(string title) => new(title) { Padding = new Padding(4), UseVisualStyleBackColor = false, BackColor = Xp.Page };

    // An "&" in a text of a schema is an ampersand, not the mark of a shortcut key: labels are told so,
    // and for the controls that paint their text themselves it is doubled.
    internal static string Amp(string text) => text.Replace("&", "&&");
    private static Label Plain(Label label)
    {
        label.UseMnemonic = false;
        return label;
    }

    // problem: the sentence of a tab that could not be built (the tab then only says so)
    private PageUi Build(NavTab model, string? problem)
    {
        var ui = new PageUi { Model = model, Tab = NewTab(model.Title) };
        problem ??= model.Kind == NavKind.Problem ? model.Problem ?? "The settings cannot be shown." : null;
        if (problem != null)
        {
            var sentence = Plain(MainForm.Note(problem, 620));       // (wraps inside the narrowest window)
            sentence.ForeColor = Warning;
            ui.Texts.Add(sentence);
            ui.Tab.Controls.Add(MainForm.Stack(sentence));
            return ui;
        }
        var scroll = new XpScrollPanel { Dock = DockStyle.Fill, BackColor = Xp.Page };
        var rows = new List<Control>();
        foreach (var module in model.Modules)
        {
            // what there is to say about a module's file stands on the tab that is the module's own
            if (_nav.HomeOf(module) != model) continue;
            var fileNote = Plain(MainForm.Note(""));
            fileNote.ForeColor = Warning;
            fileNote.Visible = false;
            scroll.Wrap(fileNote, 40);
            ui.FileNotes[module] = fileNote;
            rows.Add(fileNote);
        }
        var built = new List<ItemUi>();
        foreach (var (module, group, title) in model.Rows)
        {
            if (group == null)
            {
                // the notes of the module, below the last of its groups
                var notes = new List<Control>();
                foreach (string text in module.Schema!.Notes)
                {
                    var note = Plain(MainForm.Note(text));
                    scroll.Wrap(note, 60);
                    ui.Texts.Add(note);
                    notes.Add(note);
                }
                rows.Add(MainForm.Stack(notes.ToArray()));
                continue;
            }
            var groupRows = new List<Control>();
            if (group.Hint.Length > 0)
            {
                var hint = Plain(MainForm.Note(group.Hint));
                scroll.Wrap(hint, 80);
                ui.Texts.Add(hint);
                groupRows.Add(hint);
            }
            int before = built.Count;
            foreach (var item in group.Items)
                if (item.Shown) groupRows.Add(BuildItem(module, item, scroll, built));
            for (int i = before; i < built.Count; i++) { built[i].Page = ui; built[i].GroupTitle = title; }
            var box = MainForm.Group(Amp(title), MainForm.Stack(groupRows.ToArray()));
            ui.Groups.Add(box);
            rows.Add(box);
        }
        scroll.SetContent(MainForm.Stack(rows.ToArray()));
        ui.Scroll = scroll;
        ui.Tab.Controls.Add(scroll);
        // only a page that was built completely has its items in the lists
        foreach (var item in built)
        {
            Items.Add(item);
            ui.Items.Add(item);
            _byKey[(item.Module, item.Item.Key)] = item;
        }
        return ui;
    }

    // a number of the schema as a value the number box can hold
    private static decimal ToDecimal(double v)
    {
        const double Limit = 7.9e27;
        if (double.IsNaN(v)) return 0;
        return (decimal)Math.Clamp(v, -Limit, Limit);
    }

    private void Tip(Control control, string text)
    {
        if (text.Length == 0) return;
        _tip.SetToolTip(control, Amp(text));
        foreach (Control child in control.Controls) _tip.SetToolTip(child, Amp(text));        // the parts of a number box, the box of a text box
    }

    // The wheel scrolls the page and never changes the value of a number box or a list on it.
    private static void WheelScrolls(Control control, XpScrollPanel scroll)
    {
        control.MouseWheel += (_, e) =>
        {
            if (e is HandledMouseEventArgs h)
            {
                if (h.Handled) return;
                h.Handled = true;
            }
            scroll.ScrollByWheel(e.Delta);
        };
    }

    private Control BuildItem(ModuleSettings module, SchemaItem item, XpScrollPanel scroll, List<ItemUi> built)
    {
        var ui = new ItemUi { Module = module, Item = item };
        Control row;
        Label Label(string text)
        {
            var label = Plain(MainForm.Lbl(text));
            ui.Row.Add(label);
            Tip(label, item.Comment);
            return label;
        }
        switch (item.Kind)
        {
            case ItemKind.Bool:
                {
                    var box = MainForm.Chk(Amp(item.Label));
                    box.CheckedChanged += (_, _) => Changed();
                    ui.Input = box;
                    row = box;
                    break;
                }
            case ItemKind.Number:
                {
                    decimal min = ToDecimal(item.Min), max = ToDecimal(item.Max);
                    int digits = Math.Max(min.ToString("F" + item.Decimals.ToString(Inv), Inv).Length, max.ToString("F" + item.Decimals.ToString(Inv), Inv).Length);
                    var number = MainForm.Nud(min, max, item.Decimals, item.Step, Math.Clamp(34 + 7 * digits, 64, 260));
                    number.ValueChanged += (_, _) => Changed();
                    WheelScrolls(number, scroll);
                    ui.Input = number;
                    var parts = new List<Control> { Label(item.Label), number };
                    if (item.Unit.Length > 0) parts.Add(Label(item.Unit));
                    row = MainForm.Row(parts.ToArray());
                    break;
                }
            case ItemKind.Choice:
                {
                    int longest = item.OptionLabels.Count == 0 ? 0 : item.OptionLabels.Max(o => o.Length);
                    var list = new XpComboBox { Width = Math.Clamp(44 + 7 * longest, 110, 420), Anchor = AnchorStyles.Left };
                    foreach (string option in item.OptionLabels) list.Items.Add(Amp(option));
                    list.SelectedIndexChanged += (_, _) => Changed();
                    WheelScrolls(list, scroll);
                    ui.Input = list;
                    row = MainForm.Row(Label(item.Label), list);
                    break;
                }
            case ItemKind.Text:
                {
                    var text = new XpTextBox(280) { Anchor = AnchorStyles.Left };
                    text.Box.TextChanged += (_, _) => Changed();
                    ui.Input = text;
                    row = MainForm.Row(Label(item.Label), text);
                    break;
                }
            default:    // a key
                {
                    var key = new XpKeyBox();
                    var clear = MainForm.SmallBtn("Clear");
                    var hint = MainForm.Info();
                    key.ValueChanged += (_, _) => Changed();
                    key.HintChanged += (_, _) => hint.Text = key.Hint;
                    clear.Click += (_, _) =>
                    {
                        key.StopListening();
                        key.Value = "";
                    };
                    _tip.SetToolTip(clear, "No key: nothing is bound.");
                    ui.Input = key;
                    ui.Clear = clear;
                    ui.Hint = hint;
                    ui.Row.Add(clear);
                    row = MainForm.Row(Label(item.Label), key, clear, hint);
                    break;
                }
        }
        ui.Row.Add(ui.Input);
        Tip(ui.Input, item.Comment);
        // the control that gets the focus is scrolled into view
        ui.Input.Enter += (_, _) => scroll.EnsureVisible(ui.Input);
        built.Add(ui);
        return row;
    }

    // =====================================================================
    // values <-> controls
    // =====================================================================
    // what a control shows now: bool, decimal, int or string
    private static object Current(ItemUi ui)
    {
        switch (ui.Item.Kind)
        {
            case ItemKind.Bool: return ((XpCheckBox)ui.Input).Checked;
            case ItemKind.Number:
                {
                    // as the box shows it: a typed 2.345 is shown, and taken, as 2.35
                    var number = (NumericUpDown)ui.Input;
                    return decimal.Round(number.Value, number.DecimalPlaces, MidpointRounding.AwayFromZero);
                }
            case ItemKind.Choice: return ((XpComboBox)ui.Input).SelectedIndex;
            case ItemKind.Text: return ((XpTextBox)ui.Input).Box.Text;
            default: return ((XpKeyBox)ui.Input).Value;
        }
    }

    // puts a value of the item's kind (bool, double, byte text) into its control
    private static void SetControl(ItemUi ui, object value)
    {
        switch (ui.Item.Kind)
        {
            case ItemKind.Bool:
                ((XpCheckBox)ui.Input).Checked = value is bool on && on;
                break;
            case ItemKind.Number:
                {
                    // the number as config.lua has it
                    var number = (NumericUpDown)ui.Input;
                    if (!decimal.TryParse(SettingsRules.NumberText(value is double d ? d : 0, ui.Item.Decimals), NumberStyles.Float, Inv, out decimal shown)) shown = number.Minimum;
                    _ = number.Value;       // digits typed but not yet taken by the box are taken first: they must not come back after this
                    number.Value = Math.Min(number.Maximum, Math.Max(number.Minimum, shown));
                    break;
                }
            case ItemKind.Choice:
                {
                    var list = (XpComboBox)ui.Input;
                    int index = value is string choice ? ui.Item.Options.IndexOf(choice) : -1;
                    if (index >= 0 && index < list.Items.Count) list.SelectedIndex = index;
                    break;
                }
            case ItemKind.Text:
                ((XpTextBox)ui.Input).Box.Text = ByteText.ToUnicode(SettingsRules.OnOneLine(value as string ?? ""));
                break;
            default:
                {
                    var key = (XpKeyBox)ui.Input;
                    key.StopListening();
                    key.Value = value as string ?? "";
                    break;
                }
        }
    }

    // the value a control stands for, as the module's settings take it (null = nothing to take)
    private static object? ValueOf(ItemUi ui, object current)
    {
        switch (ui.Item.Kind)
        {
            case ItemKind.Bool: return current;
            case ItemKind.Number: return (double)(decimal)current;
            case ItemKind.Choice:
                {
                    int index = (int)current;
                    return index >= 0 && index < ui.Item.Options.Count ? ui.Item.Options[index] : null;
                }
            case ItemKind.Text: return ByteText.FromUnicode((string)current);
            default: return current;
        }
    }

    /// <summary>The values the user changed on the pages, for one module (by key).</summary>
    public Dictionary<string, object?> Wanted(ModuleSettings module)
    {
        var wanted = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var ui in Items)
        {
            if (ui.Module != module) continue;
            object current = Current(ui);
            if (current.Equals(ui.Shown)) continue;
            object? value = ValueOf(ui, current);
            if (value != null) wanted[ui.Item.Key] = value;
        }
        return wanted;
    }

    /// <summary>The user changed something on the pages that is not saved yet.</summary>
    public bool HasChanges => Items.Any(ui => !Current(ui).Equals(ui.Shown));

    /// <summary>The same for one tab of the layout.</summary>
    public bool HasChangesOn(NavTab tab) => PageOf(tab) is PageUi page && page.Items.Any(ui => !Current(ui).Equals(ui.Shown));

    // the controls of a module show its values, and remember that they do
    private void Show(ModuleSettings module)
    {
        _loading = true;
        _showProblems.Remove(module);
        try
        {
            foreach (var ui in Items)
            {
                if (ui.Module != module) continue;
                try
                {
                    SetControl(ui, module.Values[ui.Item.Key]);
                    if (ui.Hint != null) ui.Hint.Text = "";
                }
                catch (Exception ex) { _showProblems[module] = $"{ui.Item.Key} could not be shown ({ex.Message})"; }
                ui.Shown = Current(ui);     // whatever the control shows now: only what the user changes from here on is saved
            }
        }
        finally { _loading = false; }
    }

    private void Changed()
    {
        if (_loading) return;
        UpdateEnabled();
        _changed();
    }

    // Is the switch on - and the switches it needs itself?
    private bool IsOn(ModuleSettings module, string key, HashSet<string> seen)
    {
        if (!seen.Add(key)) return true;        // switches that need each other in a circle
        if (!module.Schema!.ByKey.TryGetValue(key, out var item)) return true;
        bool on = _byKey.TryGetValue((module, key), out var ui) && ui.Input is XpCheckBox box
            ? box.Checked
            : module.Values.TryGetValue(key, out object? v) && v is bool b && b;      // a hidden switch: as its file has it
        return on && (item.Needs == null || IsOn(module, item.Needs, seen));
    }

    /// <summary>Greys every item whose switch (Needs) is off, or is itself greyed.</summary>
    public void UpdateEnabled()
    {
        foreach (var ui in Items)
        {
            if (ui.Item.Needs == null) continue;
            bool on = IsOn(ui.Module, ui.Item.Needs, new HashSet<string>(StringComparer.Ordinal));
            foreach (var c in ui.Row)
            {
                if (c is Label) c.ForeColor = on ? Color.Empty : Xp.DisabledText;
                else c.Enabled = on;
            }
        }
    }

    // What there is to say about a module's config.lua, on its page.
    private static string FileNote(ModuleSettings m)
    {
        var lines = new List<string>();
        if (m.Schema == null) return "";
        if (m.FileProblem != null)
        {
            bool defaults = m.Schema!.Items.All(i => SettingsRules.Same(m.Values[i.Key], i.Default));
            string shown = defaults ? "the default values are shown" : "the values shown are the ones read before";
            lines.Add(m.FileProblem == ModuleSettings.NotThere
                ? $"Module {m.Name}: config.lua is not there yet - {shown}. It is written when you change a value and save."
                : $"Module {m.Name}: {m.FileProblem} - {shown}. When you change a value and save, the file is replaced (the old one is kept as config.lua.bak).");
        }
        foreach (string w in m.Warnings) lines.Add($"Module {m.Name}, config.lua: {w}");
        return string.Join("\n", lines);
    }

    private string NoteOf(ModuleSettings m)
    {
        string text = FileNote(m) + (_showProblems.TryGetValue(m, out string? problem) ? (FileNote(m).Length > 0 ? "\n" : "") + $"Module {m.Name}: {problem}" : "");
        string extra = ExtraNote?.Invoke(m) ?? "";
        return extra.Length == 0 ? text : text.Length == 0 ? extra : text + "\n" + extra;
    }

    /// <summary>More to say on a module's own tab than its file gives ("" = nothing): the module "intro" and Game.ini.</summary>
    public Func<ModuleSettings, string>? ExtraNote;

    /// <summary>Shows the notes of the modules again (after ExtraNote has something new to say).</summary>
    public void RefreshNotes() => UpdateNotes();

    private void UpdateNotes()
    {
        foreach (var page in Pages)
        {
            if (page.Scroll == null) continue;
            foreach (var (module, label) in page.FileNotes)
            {
                string text = NoteOf(module);
                if (label.Text != text) label.Text = text;
                label.Visible = text.Length > 0;        // (set, not compared: Visible reads as false on a tab that is not shown)
            }
            page.Scroll.Arrange();
        }
    }

    // =====================================================================
    // what the window does with the pages
    // =====================================================================
    /// <summary>Reads every module's config.lua and shows its values. Never throws.</summary>
    public void Load()
    {
        foreach (var module in _modules)
        {
            module.Load();
            Show(module);
        }
        UpdateEnabled();
        UpdateNotes();
    }

    /// <summary>Every setting on the pages gets its default (hidden settings stay). Nothing is written.</summary>
    public void SetDefaults() => SetDefaults(Items);

    /// <summary>Every setting on one tab gets its default. Nothing is written. Returns how many settings the tab has.</summary>
    public int SetDefaults(NavTab tab)
    {
        if (PageOf(tab) is not PageUi page) return 0;
        SetDefaults(page.Items);
        return page.Items.Count;
    }

    private void SetDefaults(IEnumerable<ItemUi> items)
    {
        _loading = true;
        try
        {
            foreach (var ui in items) SetControl(ui, ui.Item.Default!);
        }
        finally { _loading = false; }
        UpdateEnabled();
    }

    // ---- the presets (Presets.cs): the items whose schema gives them a value for each of the five
    /// <summary>What is wrong with the Tiers in the modules' schemas ("module: problem"); the presets leave those items alone.</summary>
    public List<string> TierProblems() =>
        _modules.Where(m => m.Schema != null).SelectMany(m => m.Schema!.TierProblems.Select(p => m.Name + ": " + p)).ToList();

    /// <summary>The categories that have settings a preset sets, in the order of the pane.</summary>
    public List<string> TierCategories() =>
        Pages.Where(p => p.Items.Any(ui => ui.Item.Tiers != null)).Select(p => p.Model.Category.Title).Distinct(StringComparer.Ordinal).ToList();

    /// <summary>Every setting a preset covers shows the preset's value (tier 1 to 5). Nothing is written. Returns how many were set.</summary>
    public int ApplyTier(int tier)
    {
        int count = 0;
        _loading = true;
        try
        {
            foreach (var ui in Items)
            {
                if (ui.Item.Tiers == null) continue;
                SetControl(ui, ui.Item.Tiers[tier - 1]);
                count++;
            }
        }
        finally { _loading = false; }
        UpdateEnabled();
        return count;
    }

    /// <summary>Every setting a preset covers shows exactly the preset's value.</summary>
    public bool MatchesTier(int tier)
    {
        foreach (var ui in Items)
        {
            if (ui.Item.Tiers == null) continue;
            if (!SettingsRules.Same(ValueOf(ui, Current(ui)), ui.Item.Tiers[tier - 1])) return false;
        }
        return true;
    }

    /// <summary>
    /// Saves the changed values, module by module. written: the modules whose file was written;
    /// failed: "module: why" for those that could not be saved (their controls keep what the user
    /// set, so that saving can be tried again).
    /// </summary>
    public void Save(List<string> written, List<string> failed)
    {
        foreach (var module in _modules)
        {
            var wanted = Wanted(module);
            if (wanted.Count == 0) continue;
            try
            {
                if (module.Save(wanted, out _)) written.Add(module.Name);
            }
            catch (Exception ex)
            {
                failed.Add($"{module.Name}: {ex.Message}");
                continue;
            }
            Show(module);
        }
        UpdateEnabled();
        UpdateNotes();
    }

    /// <summary>
    /// Looks at the files again (the game writes them too, from its in-game menu): a module whose
    /// file changed on disk, and on whose settings the user changed nothing, shows the file's values.
    /// Returns the names of those modules.
    /// </summary>
    public List<string> RereadUntouched()
    {
        var reread = new List<string>();
        foreach (var module in _modules)
        {
            if (Wanted(module).Count > 0 || !module.Reread()) continue;
            Show(module);
            reread.Add(module.Name);
        }
        if (reread.Count > 0)
        {
            UpdateEnabled();
            UpdateNotes();
        }
        return reread;
    }

    /// <summary>For the status line: the modules whose config.lua has something to say (a problem, corrected values).</summary>
    public List<string> ModulesWithNotes() => _modules.Where(m => m.FileProblem != null && m.FileProblem != ModuleSettings.NotThere || m.Warnings.Count > 0).Select(m => m.Name).ToList();
}
