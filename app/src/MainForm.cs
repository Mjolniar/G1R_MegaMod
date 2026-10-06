using System.Diagnostics;
using System.Globalization;

namespace G1RRepopulateSettings;

internal sealed class MainForm : XpForm
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    private readonly string _configPath;
    // the megamod the settings file sits in (modules\repopulate\Scripts\config.lua); null = the standalone mod
    private readonly MegaMod? _mega;
    // the layout: the categories of the pane on the left, each with its tabs
    private readonly NavModel _nav;
    // the tabs made from the schema.lua of the megamod's other modules (none in the standalone mod)
    private readonly SchemaPages _generic;
    // "G1R_MegaMod Settings" in the megamod layout, else "G1R_Repopulate Settings"
    private readonly string _title;
    private Settings _s = new();
    private List<SpeciesInfo> _catalog = new();
    private string? _catalogError;
    private List<string> _warnings = new();
    private bool _loading;
    private bool _dirty;
    private bool _testMode;

    // ---------------------------------------------------------------- top bar (the presets, for every page; Find)
    private readonly FlowLayoutPanel _topBar = new() { AutoSize = true, WrapContents = false, Margin = new Padding(0), Anchor = AnchorStyles.Left };
    private readonly XpComboBox _preset = new() { Width = 214 };
    private readonly XpButton _presetApply = Btn("Apply preset");
    private readonly XpTextBox _find = new(190) { Anchor = AnchorStyles.Left, Margin = new Padding(3, 4, 0, 3) };
    private readonly FindList _findList = new() { Visible = false };
    private List<FindEntry>? _findIndex;

    // ---------------------------------------------------------------- the pane on the left and the tabs on the right
    private readonly XpTaskPane _pane = new() { Dock = DockStyle.Fill };
    private readonly Panel _tabHost = new() { Dock = DockStyle.Fill, Margin = new Padding(0) };
    private readonly Dictionary<NavCategory, XpTabControl> _tabsOf = new();
    private readonly Dictionary<NavTab, TabPage> _pageOf = new();
    private readonly Dictionary<TabPage, NavTab> _tabOf = new();
    private readonly Dictionary<NavCategory, XpTaskPane.Entry> _entryOf = new();
    private NavCategory? _category;     // the category shown
    private NavTab? _current;           // the tab shown
    private XpTaskPane.Entry? _taskDefaults, _taskFolder, _detailPreset;
    private string _baseline = "";      // the repopulate settings as the file has them (Settings.Fingerprint)
    // the mass changes of the repopulate pages: a strip above the tabs, shown in the category World only
    private readonly FlowLayoutPanel _scaleBar = new() { AutoSize = true, WrapContents = false, Dock = DockStyle.Fill, Margin = new Padding(0, 0, 0, 4) };
    private readonly List<Control> _scaleControls = new();
    // the first page: per part of the mod its switch (the same switch as on the part's own page)
    private readonly List<(XpCheckBox Here, XpCheckBox There)> _overviewSwitches = new();
    private readonly Label _overviewPreset = Info();
    private bool _mirroring;
    private const string InUse = "  - in use";                 // behind the line of the box the settings are at
    private const string OwnName = "Your own settings";        // the first line of the box: the settings are at none of the presets
    private int _presetState = -1;                             // the line the box was last marked at (0 = own settings, 1 to 5 = that preset); -1 = not yet
    private readonly NumericUpDown _scaleChance = Nud(10, 1000, 0, 10, 64);
    private readonly XpButton _scaleChanceApply = Btn("Apply");
    private readonly NumericUpDown _scaleTime = Nud(10, 1000, 0, 10, 64);
    private readonly XpButton _scaleTimeApply = Btn("Apply");

    // ---------------------------------------------------------------- bottom bar
    private readonly Label _status = new() { AutoSize = false, Dock = DockStyle.Fill, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft, Height = 26 };
    private readonly XpButton _save = Btn("Save");
    private readonly XpButton _revert = Btn("Revert");
    private readonly XpButton _defaults = Btn("Defaults");
    private readonly ToolTip _tip = new() { AutoPopDelay = 20000, InitialDelay = 400 };
    private readonly XpVScrollBar _gridScroll = new() { Dock = DockStyle.Right };

    // ---------------------------------------------------------------- creatures
    private readonly XpCheckBox _crOn = Chk("Creatures respawn at their own spawn points");
    private readonly NumericUpDown _nChance = Pct(), _eChance = Pct();
    private readonly NumericUpDown _nHours = Hours(), _eHours = Hours();
    private readonly Label _nAvg = Info(), _eAvg = Info();
    private readonly XpCheckBox _corpses = Chk("Remove a corpse of the same kind when a creature comes back");
    private readonly NumericUpDown _minDist = Nud(0, 500, 0, 5, 64);
    private readonly DataGridView _grid = new();
    private readonly XpButton _clearSpecies = Btn("Clear all species settings");
    private readonly XpButton _allOn = Btn("All species respawn");

    // ---------------------------------------------------------------- herbs / items
    private readonly XpCheckBox _herbsOn = Chk("Herbs, plants, berries and mushrooms regrow");
    private readonly NumericUpDown _regrow = Hours();
    private readonly Label _herbsAvg = Info();
    private readonly XpCheckBox _itemsOn = Chk("Other items lying in the world come back");
    private readonly NumericUpDown _itemChance = Pct();
    private readonly NumericUpDown _maxDays = Nud(1, 365, 0, 1, 64);
    private readonly Label _itemsAvg = Info();

    // ---------------------------------------------------------------- containers
    private readonly XpCheckBox _chestsOn = Chk("Emptied containers restock their original contents");
    private readonly NumericUpDown _settle = Pct(), _wild = Pct();
    private readonly Label _settleAvg = Info(), _wildAvg = Info();
    private readonly XpCheckBox _loot = Chk("Also corpses, bags and other loot spots in the world");
    private readonly NumericUpDown _catchUpDays = Nud(1, 30, 0, 1, 64);
    private readonly NumericUpDown _retroDays = Nud(0, 30, 0, 1, 64);
    private readonly NumericUpDown _checkRadius = Nud(1, 200, 0, 5, 64);

    // ---------------------------------------------------------------- crime
    private readonly XpCheckBox _crimeOn = Chk("Crime system on");
    private readonly XpCheckBox _crimeTheft = Chk("Stealing, pickpocketing, lockpicking, using others' things");
    private readonly XpCheckBox _crimeTresp = Chk("Entering others' huts and areas, sneaking");
    private readonly XpCheckBox _crimeWeapons = Chk("Drawn weapons or fists, threats, blocking the way");
    private readonly XpCheckBox _crimeForget = Chk("Also forget what you already did");
    private readonly Label _crimeState = Info();

    // ---------------------------------------------------------------- advanced
    private readonly XpCheckBox _modOn = Chk("Mod enabled (off: it does nothing)");
    private readonly NumericUpDown _startDelay = Nud(0, 600, 0, 1, 64);
    private readonly XpCheckBox _verbose = Chk("Log every respawn / restock to UE4SS.log");
    private readonly NumericUpDown _reloadSecs = Nud(0, 3600, 0, 5, 64);
    private readonly NumericUpDown _maxSpawns = Nud(1, 2000, 0, 10, 64);
    private readonly NumericUpDown _catchUpCycles = Nud(1, 30, 0, 1, 64);
    private readonly NumericUpDown _spawnInterval = Nud(0.1m, 30, 1, 0.1m, 64);
    private readonly NumericUpDown _censusSpeed = Nud(5, 5000, 0, 10, 64);
    private readonly XpTextBox _prefixes = new(360);
    private readonly Label _unknownElite = Info();
    private readonly Label _pathLabel = Info();

    public MainForm(string configPath, bool testMode = false)
    {
        _configPath = configPath;
        _mega = MegaMod.Find(configPath);
        _title = _mega != null ? "G1R_MegaMod Settings" : "G1R_Repopulate Settings";
        _testMode = testMode;
        _nav = NavModel.Build(_mega);
        _generic = new SchemaPages(_nav, _tip, MarkDirty);
        _generic.ExtraNote = m => m.Name == GameStart.Module ? _gameNote : m.Name == OtherMods.Module ? _otherNote : "";
        SuspendLayout();
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        Text = _title;
        Font = Xp.UiFont;
        Size = new Size(1140, 780);
        MinimumSize = new Size(1040, 690);
        StartPosition = FormStartPosition.CenterScreen;
        Icon = AppIcon.Load();
        Xp.Tooltip(_tip);

        BuildLayout();
        WireEvents();
        ResumeLayout(false);
        PerformLayout();
        LoadFromFile(initial: true);
        // the window opens on its first page: the overview in a megamod, the creatures in the separate mod
        ShowCategory(_nav.Categories[0]);
        Shown += (_, _) => { _grid.CurrentCell = null; _grid.ClearSelection(); FitTabs(); };
    }

    // A category can have many tabs (Combat: eight): the window is never narrower than the longest row of
    // tabs (below that width Windows shows its own scroll arrows beside the tabs).
    private void FitTabs()
    {
        try
        {
            int widest = 0;
            foreach (var category in _nav.Categories)
            {
                int row = Px(8);
                foreach (var tab in category.Tabs)
                    row += TextRenderer.MeasureText(tab.Title, Xp.UiFont, Size.Empty, TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix).Width + Px(22);
                widest = Math.Max(widest, row);
            }
            int needed = widest + (Width - _tabHost.Width) + Px(6);
            needed = Math.Min(needed, Screen.FromControl(this).WorkingArea.Width);
            if (needed > MinimumSize.Width) MinimumSize = new Size(needed, MinimumSize.Height);
            if (WindowState == FormWindowState.Normal && Width < needed) Width = needed;
        }
        catch { }
    }

    // =====================================================================
    // control factories
    // =====================================================================
    internal static XpNumericUpDown Nud(decimal min, decimal max, int decimals, decimal inc, int width) => new()
    {
        Minimum = min, Maximum = max, DecimalPlaces = decimals, Increment = inc, Width = width,
        TextAlign = HorizontalAlignment.Right, Anchor = AnchorStyles.Left,
    };
    private static XpNumericUpDown Pct() => Nud(0, 100, 1, 5, 64);
    private static XpNumericUpDown Hours() => Nud(1, 8760, 0, 1, 64);
    internal static XpCheckBox Chk(string text) => new() { Text = text, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(3, 5, 3, 3) };
    private static XpButton Btn(string text) => new() { Text = text, Margin = new Padding(3, 3, 3, 3) };
    internal static XpButton SmallBtn(string text) => new() { Text = text, MinimumSize = new Size(34, 23), Margin = new Padding(3, 3, 3, 3) };
    internal static Label Info() => new() { AutoSize = true, ForeColor = Xp.Hint, Anchor = AnchorStyles.Left, Margin = new Padding(3, 6, 3, 3), Font = Xp.UiFont };
    internal static Label Lbl(string text) => new() { Text = text, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(3, 6, 3, 3), Font = Xp.UiFont };
    internal static Label Note(string text, int maxWidth = 900) => new()
    {
        Text = text, AutoSize = true, MaximumSize = new Size(maxWidth, 0), ForeColor = Xp.Hint,
        Anchor = AnchorStyles.Left, Margin = new Padding(3, 4, 3, 6), Font = Xp.UiFont,
    };

    internal static FlowLayoutPanel Row(params Control[] controls)
    {
        var f = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Dock = DockStyle.Top, Margin = new Padding(0) };
        f.Controls.AddRange(controls);
        return f;
    }

    internal static TableLayoutPanel Stack(params Control[] controls)
    {
        var t = new TableLayoutPanel { ColumnCount = 1, Dock = DockStyle.Fill, AutoSize = true, Padding = new Padding(8) };
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (var c in controls)
        {
            t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            t.Controls.Add(c);
        }
        // empty last row takes any spare height, so the rows above stay together
        t.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        t.Controls.Add(new Panel { Height = 0, Margin = Padding.Empty }, 0, controls.Length);
        return t;
    }

    internal static XpGroupBox Group(string title, Control content)
    {
        var g = new XpGroupBox { Text = title, Dock = DockStyle.Fill, AutoSize = true, Padding = new Padding(8, 6, 8, 8), Margin = new Padding(3, 3, 3, 8) };
        content.Dock = DockStyle.Fill;
        g.Controls.Add(content);
        return g;
    }

    // =====================================================================
    // layout
    // =====================================================================
    private void BuildLayout()
    {
        var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Padding = new Padding(8, 8, 8, 6), BackColor = Xp.Face };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        Controls.Add(root);

        // top bar: the presets (they set every page) on the left, Find on the right
        _preset.Items.Add(OwnName);
        foreach (string name in Presets.Names) _preset.Items.Add(name);
        _preset.SelectedIndex = 0;
        _presetApply.Enabled = false;
        _topBar.Controls.AddRange(new Control[] { Lbl("Preset:"), _preset, _presetApply });
        string presetTip = "Five sets of settings: 1 = the game itself (hardest), 5 = easiest. Sets every page at once.\n"
            + "Keys, notes, logs, melee, waiting, map pins and per-species settings stay.\n"
            + "Shows the preset in use, or \"" + OwnName + "\".";
        _tip.SetToolTip(_preset, presetTip);
        _tip.SetToolTip(_presetApply, presetTip);
        var findBar = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0), Anchor = AnchorStyles.Right };
        var findLabel = Lbl("Find:");
        findBar.Controls.AddRange(new Control[] { findLabel, _find });
        string findTip = "Type a word to find a setting by name, hint or key.\nEnter or a click goes to it. Ctrl+F comes here.";
        _tip.SetToolTip(_find, findTip);
        _tip.SetToolTip(_find.Box, findTip);
        _tip.SetToolTip(findLabel, findTip);
        var top = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 3, RowCount = 1, Margin = new Padding(0, 0, 0, 4) };
        top.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        top.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        top.Controls.Add(_topBar, 0, 0);
        top.Controls.Add(findBar, 2, 0);
        root.Controls.Add(top, 0, 0);

        // the mass changes of the repopulate pages: above the tabs of the category World
        _scaleControls.AddRange(new Control[]
        {
            Lbl("Scale all chances to"), _scaleChance, Lbl("%"), _scaleChanceApply,
            new Label { Width = 10 },
            Lbl("Scale all timers to"), _scaleTime, Lbl("%"), _scaleTimeApply,
        });
        _scaleBar.Controls.AddRange(_scaleControls.ToArray());
        _scaleChance.Value = 100;
        _scaleTime.Value = 100;
        _tip.SetToolTip(_scaleChanceApply, "Multiplies every chance. 200 % = twice as likely.");
        _tip.SetToolTip(_scaleTimeApply, "Multiplies every interval. 50 % = twice as often.");

        // the pages: one tab control per category; the one of the chosen category is shown
        foreach (var category in _nav.Categories)
        {
            var tabs = new XpTabControl { Dock = DockStyle.Fill, Visible = false };
            foreach (var tab in category.Tabs)
            {
                TabPage page = tab.Kind switch
                {
                    NavKind.Overview => OverviewPage(),
                    NavKind.Repopulate => RepopulatePage(tab.Title),
                    _ => _generic.PageOf(tab)!.Tab,
                };
                _pageOf[tab] = page;
                _tabOf[page] = tab;
                tabs.TabPages.Add(page);
            }
            tabs.SelectedIndexChanged += (_, _) => { if (_category == category) CurrentChanged(); };
            _tabsOf[category] = tabs;
            _tabHost.Controls.Add(tabs);
        }

        // the pane on the left
        var settings = _pane.AddBox("Settings");
        foreach (var category in _nav.Categories) _entryOf[category] = _pane.Add(settings, XpTaskPane.Kind.Choice, category.Title, category);
        var tasks = _pane.AddBox("Page tasks");
        _taskDefaults = _pane.Add(tasks, XpTaskPane.Kind.Link, "Defaults for this page");
        _taskDefaults.Tip = "Defaults for the page shown. Nothing is written until Save.";
        _taskFolder = _pane.Add(tasks, XpTaskPane.Kind.Link, "Open the mod folder");
        var details = _pane.AddBox("Details");
        string version = _mega?.Version() ?? "";
        _pane.Add(details, XpTaskPane.Kind.Text, _mega != null ? "G1R_MegaMod" + (version.Length > 0 ? " " + version : "") : "G1R_Repopulate");
        _detailPreset = _pane.Add(details, XpTaskPane.Kind.Text, "");
        var file = _pane.Add(details, XpTaskPane.Kind.Text, ModFolder());
        file.OneLine = true;
        file.Tip = ModFolder();
        _pane.Tips = _tip;
        _pane.Choose += entry => { if (entry.Tag is NavCategory category) ShowCategory(category); };
        _pane.Press += entry =>
        {
            if (entry == _taskDefaults) DefaultsForPage();
            else if (entry == _taskFolder) OpenModFolder();
        };

        var paneFrame = new XpBorderPanel { Dock = DockStyle.Fill, Margin = new Padding(0, 0, 8, 0) };
        paneFrame.Controls.Add(_pane);
        var right = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, Margin = new Padding(0) };
        right.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        right.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        right.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        right.Controls.Add(_scaleBar, 0, 0);
        right.Controls.Add(_tabHost, 0, 1);
        var body = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Margin = new Padding(0) };
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 196));
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        body.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        body.Controls.Add(paneFrame, 0, 0);
        body.Controls.Add(right, 1, 0);
        root.Controls.Add(body, 0, 1);

        var bottom = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 2 };
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var buttons = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Anchor = AnchorStyles.Right };
        buttons.Controls.AddRange(new Control[] { _defaults, _revert, _save });
        bottom.Controls.Add(_status, 0, 0);
        bottom.Controls.Add(buttons, 1, 0);
        root.Controls.Add(bottom, 0, 2);
        AcceptButton = _save;

        // the list of what Find found lies over the pages, below the box
        Controls.Add(_findList);
        _findList.BringToFront();
    }

    // The megamod's folder (the separate mod: the folder of G1R_Repopulate), for the pane and the overview.
    private string ModFolder()
    {
        if (_mega != null) return _mega.Root;
        try { return Path.GetDirectoryName(Path.GetDirectoryName(Path.GetFullPath(_configPath)) ?? "") ?? _configPath; }
        catch { return _configPath; }
    }

    private void OpenModFolder()
    {
        if (_testMode) return;
        try { Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + _configPath + "\"") { UseShellExecute = true }); }
        catch (Exception ex) { XpMessageBox.Show(this, ex.Message, _title, MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    private TabPage RepopulatePage(string title) => title switch
    {
        "Creatures" => CreaturesPage(),
        "Herbs and items" => ItemsPage(),
        "Containers" => ContainersPage(),
        "Crime" => CrimePage(),
        _ => AdvancedPage(),
    };

    // =====================================================================
    // the pane and the tabs
    // =====================================================================
    /// <summary>Shows a category - on the tab given, else on the tab it was last on.</summary>
    private void ShowCategory(NavCategory category, NavTab? tab = null)
    {
        var tabs = _tabsOf[category];
        _category = category;
        if (tab != null && _pageOf.TryGetValue(tab, out var page) && tabs.SelectedTab != page) tabs.SelectedTab = page;
        foreach (var (other, control) in _tabsOf)
            if (other != category && control.Visible) control.Visible = false;
        if (!tabs.Visible) tabs.Visible = true;
        tabs.BringToFront();
        CurrentChanged();
    }

    // the tab that is shown has changed: the pane and the strip above the tabs follow
    private void CurrentChanged()
    {
        if (_category == null) return;
        var tabs = _tabsOf[_category];
        // (a tab control that was never shown has no selected tab yet: it will open on its first)
        var page = tabs.SelectedTab ?? (tabs.TabCount > 0 ? tabs.TabPages[0] : null);
        _current = page != null && _tabOf.TryGetValue(page, out var tab) ? tab : null;
        bool world = _current?.Kind == NavKind.Repopulate;
        if (_scaleBar.Visible != world) _scaleBar.Visible = world;
        _scaleShown = world;
        if (_taskDefaults != null) _taskDefaults.Enabled = _current != null && HasDefaults(_current);
        _pane.Chosen = _entryOf[_category];
        _pane.Changed();
    }

    private bool _scaleShown;

    // a page whose settings can be set to their defaults
    private bool HasDefaults(NavTab tab) => tab.Kind == NavKind.Repopulate || (tab.Kind == NavKind.Schema && _generic.PageOf(tab) is { } page && page.Items.Count > 0);

    // The star behind a category of the pane: one of its pages shows something that is not in the files.
    private void UpdateMarks()
    {
        bool changed = false;
        string now = "";
        try { now = _s.Fingerprint(); } catch { }
        foreach (var (category, entry) in _entryOf)
        {
            bool marked = category.Tabs.Any(t => t.Kind == NavKind.Repopulate) ? now != _baseline : category.Tabs.Any(_generic.HasChangesOn);
            if (entry.Marked == marked) continue;
            entry.Marked = marked;
            changed = true;
        }
        if (changed) _pane.Changed();
    }

    // what the file of the repopulate module holds now is what the pages show now
    private void TakeBaseline()
    {
        ReadControls();
        _baseline = _s.Fingerprint();
    }

    private void DefaultsForPage()
    {
        var tab = _current;
        if (tab == null || !HasDefaults(tab)) return;
        if (!_testMode && XpMessageBox.Show(this, "Set the settings on the page \"" + tab.Path + "\" to their default values?"
                + (tab.Title == "Creatures" && tab.Kind == NavKind.Repopulate ? " The per-species settings are cleared." : "")
                + "\n\nNothing is written until you press Save.",
                _title, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
        if (tab.Kind == NavKind.Repopulate)
        {
            ReadControls();
            RepopulateDefaults(tab.Title);
            RefreshControls();
        }
        else _generic.SetDefaults(tab);
        MarkDirty();
        _status.Text = "Defaults set on the page \"" + tab.Path + "\" - press Save.";
    }

    // the settings of one of the five repopulate pages as a new settings file has them
    private void RepopulateDefaults(string title)
    {
        var d = new Settings();
        switch (title)
        {
            case "Creatures":
                _s.CreaturesEnabled = d.CreaturesEnabled;
                _s.NormalChance = d.NormalChance;
                _s.NormalEveryHours = d.NormalEveryHours;
                _s.EliteChance = d.EliteChance;
                _s.EliteEveryHours = d.EliteEveryHours;
                _s.RemoveCorpsesOnRespawn = d.RemoveCorpsesOnRespawn;
                _s.MinPlayerDistance = d.MinPlayerDistance;
                _s.EliteSpecies = d.EliteSpecies;
                _s.Species = d.Species;
                _s.ExcludeSpecies = d.ExcludeSpecies;
                break;
            case "Herbs and items":
                _s.HerbsEnabled = d.HerbsEnabled;
                _s.RegrowHours = d.RegrowHours;
                _s.WorldItemsEnabled = d.WorldItemsEnabled;
                _s.DailyChance = d.DailyChance;
                _s.MaxDays = d.MaxDays;
                break;
            case "Containers":
                _s.ChestsEnabled = d.ChestsEnabled;
                _s.SettlementDailyChance = d.SettlementDailyChance;
                _s.WildDailyChance = d.WildDailyChance;
                _s.IncludeLootObjects = d.IncludeLootObjects;
                _s.MaxCatchUpDays = d.MaxCatchUpDays;
                _s.RetroactiveDays = d.RetroactiveDays;
                _s.CheckRadius = d.CheckRadius;
                break;
            case "Crime":
                _s.CrimeEnabled = d.CrimeEnabled;
                _s.CrimeDisableTheft = d.CrimeDisableTheft;
                _s.CrimeDisableTrespassing = d.CrimeDisableTrespassing;
                _s.CrimeDisableWeapons = d.CrimeDisableWeapons;
                _s.CrimeForgetOld = d.CrimeForgetOld;
                break;
            default:
                _s.Enabled = d.Enabled;
                _s.StartDelaySeconds = d.StartDelaySeconds;
                _s.Verbose = d.Verbose;
                _s.ReloadCheckSeconds = d.ReloadCheckSeconds;
                _s.MaxSpawnsPerCycle = d.MaxSpawnsPerCycle;
                _s.MaxCatchUpCycles = d.MaxCatchUpCycles;
                _s.SpawnIntervalSeconds = d.SpawnIntervalSeconds;
                _s.CensusStatesPerTick = d.CensusStatesPerTick;
                _s.ExcludePointPrefixes = d.ExcludePointPrefixes;
                break;
        }
    }

    // =====================================================================
    // Find
    // =====================================================================
    // Everything Find can go to: the tabs, the settings made from schemas, and what stands on the five repopulate pages.
    private List<FindEntry> FindIndex()
    {
        if (_findIndex != null) return _findIndex;
        var index = new List<FindEntry>();
        foreach (var tab in _nav.Tabs)
        {
            index.Add(new FindEntry { Label = tab.Path, Words = (tab.Path + " " + tab.Category.Title).ToLowerInvariant(), Tab = tab });
            if (tab.Kind == NavKind.Repopulate && _pageOf.TryGetValue(tab, out var page)) IndexRepopulate(index, tab, page);
            else if (_generic.PageOf(tab) is { } ui)
            {
                foreach (var item in ui.Items)
                {
                    string label = item.Item.Label + (item.Item.Unit.Length > 0 && item.Item.Kind == ItemKind.Number ? " (" + item.Item.Unit + ")" : "");
                    string words = string.Join(" ", new[] { item.Item.Label, item.Item.Unit, item.Item.Comment, item.Item.Key, item.GroupTitle, tab.Path, item.Module.Name }
                        .Concat(item.Item.OptionLabels));
                    index.Add(new FindEntry { Label = label, Words = words.ToLowerInvariant(), Tab = tab, Target = item.Input });
                }
            }
        }
        return _findIndex = index;
    }

    private void IndexRepopulate(List<FindEntry> index, NavTab tab, TabPage page)
    {
        var added = new List<(FindEntry Entry, string Group)>();
        void add(string label, Control target)
        {
            string group = "";
            for (Control? a = target.Parent; a != null && a != page; a = a.Parent)
                if (a is XpGroupBox box) { group = box.Text; break; }
            var entry = new FindEntry { Label = label, Words = (label + " " + group + " " + tab.Path).ToLowerInvariant(), Tab = tab, Target = target };
            index.Add(entry);
            added.Add((entry, group));
        }
        foreach (var c in Descendants(page))
        {
            if (c is XpCheckBox check) add(check.Text, check);
            else if (c is FlowLayoutPanel row && row.Controls.Cast<Control>().FirstOrDefault(x => x is NumericUpDown || x is XpTextBox) is { } input)
                add(string.Join(" ", row.Controls.Cast<Control>().Select(x => x is Label l ? l.Text : x is NumericUpDown || x is XpTextBox ? "..." : "").Where(t => t.Length > 0)), input);
        }
        if (tab.Title == "Creatures") add("Species list: respawns, elite, own chance and interval per species", _grid);
        // two lines of a page that read the same (the chance of normal and of elite creatures) say which group they are in
        foreach (var same in added.GroupBy(x => x.Entry.Label, StringComparer.Ordinal).Where(g => g.Count() > 1))
            foreach (var (entry, group) in same)
                if (group.Length > 0) entry.Label = group + " - " + entry.Label;
    }

    /// <summary>What Find lists for a text, best first (all of it; the list shows the first lines).</summary>
    private List<FindEntry> FindMatches(string text)
    {
        string query = text.Trim().ToLowerInvariant();
        var words = query.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return new List<FindEntry>();
        var found = FindIndex().Where(e => words.All(w => e.Words.Contains(w, StringComparison.Ordinal))).ToList();
        // a name that starts with the text first, then names that contain it, then what only mentions it; settings before tabs
        int rank(FindEntry e)
        {
            string label = e.Label.ToLowerInvariant();
            return (label.StartsWith(query, StringComparison.Ordinal) ? 0 : label.Contains(query, StringComparison.Ordinal) ? 2 : 4) + (e.Target == null ? 1 : 0);
        }
        return found.OrderBy(rank).ToList();       // (a stable sort: within a rank the order of the pages)
    }

    private void FindNow()
    {
        if (_loading) return;
        string text = _find.Box.Text;
        if (text.Trim().Length == 0) { HideFindList(); return; }
        _findList.Show(FindMatches(text));
        PlaceFindList();
        if (!_findList.Visible) _findList.Visible = true;
        _findList.BringToFront();
    }

    private void PlaceFindList()
    {
        var below = PointToClient(_find.PointToScreen(new Point(0, _find.Height)));
        int width = Math.Min(Px(560), Math.Max(Px(200), ClientSize.Width - Px(24)));
        int left = Math.Max(Px(8), below.X + _find.Width - width);
        _findList.Bounds = new Rectangle(left, below.Y + 1, width, _findList.NeededHeight);
    }

    private void HideFindList()
    {
        if (_findList.Visible) _findList.Visible = false;
    }

    /// <summary>Opens the tab of something Find found and goes to the setting.</summary>
    private void GoTo(FindEntry entry)
    {
        HideFindList();
        bool was = _loading;
        _loading = true;                // (emptying the box is no search)
        try { _find.Box.Text = ""; }
        finally { _loading = was; }
        ShowCategory(entry.Tab.Category, entry.Tab);
        _lastFound = entry;
        var target = entry.Target;
        if (target == null) { _tabsOf[entry.Tab.Category].Focus(); return; }
        _generic.Items.FirstOrDefault(i => i.Input == target)?.Page.Scroll?.EnsureVisible(target);
        try { (target is XpTextBox box ? box.Box : target).Focus(); } catch { }
    }

    private FindEntry? _lastFound;

    // Ctrl+F goes to the Find box; while it has the focus, Up and Down move in the list, Enter goes to the
    // line (and does not press Save), Escape empties the box.
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == (Keys.Control | Keys.F))
        {
            _find.Box.Focus();
            _find.Box.SelectAll();
            return true;
        }
        if (_find.Box.Focused || _findList.Focused)
        {
            switch (keyData)
            {
                case Keys.Down: _findList.Step(1); return true;
                case Keys.Up: _findList.Step(-1); return true;
                case Keys.Enter:
                    if (_findList.Visible && _findList.Selected is { } entry) GoTo(entry);
                    return true;
                case Keys.Escape:
                    _find.Box.Text = "";
                    HideFindList();
                    return true;
            }
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    // =====================================================================
    // the first page
    // =====================================================================
    private static LinkLabel Link(string text, Action go)
    {
        var link = new LinkLabel
        {
            Text = text, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(12, 6, 3, 3), Font = Xp.UiFont, UseMnemonic = false,
            LinkColor = Xp.C(0x215DC6), ActiveLinkColor = Xp.C(0x428EFF), VisitedLinkColor = Xp.C(0x215DC6), LinkBehavior = LinkBehavior.HoverUnderline, BackColor = Color.Transparent,
        };
        link.LinkClicked += (_, _) => go();
        return link;
    }

    // A switch on the overview is the switch on the part's own page, a second time: each follows the other.
    private XpCheckBox Mirror(string text, XpCheckBox there)
    {
        var here = Chk(SchemaPages.Amp(text));
        here.Checked = there.Checked;
        here.CheckedChanged += (_, _) =>
        {
            if (_mirroring || there.Checked == here.Checked) return;
            there.Checked = here.Checked;       // (the page's own switch says that something changed)
        };
        there.CheckedChanged += (_, _) =>
        {
            if (here.Checked == there.Checked) return;
            _mirroring = true;
            try { here.Checked = there.Checked; }
            finally { _mirroring = false; }
        };
        _overviewSwitches.Add((here, there));
        return here;
    }

    private TabPage OverviewPage()
    {
        var page = new TabPage(NavModel.Overview) { Padding = new Padding(4), UseVisualStyleBackColor = false, BackColor = Xp.Page };
        var off = _mega?.SwitchedOff() ?? new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var parts = new TableLayoutPanel { ColumnCount = 3, AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0) };
        parts.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        parts.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        parts.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        int row = 0;
        void add(Control name, NavTab? target, string module, string? state)
        {
            parts.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            parts.Controls.Add(name, 0, row);
            if (target != null) parts.Controls.Add(Link(target.Path, () => ShowCategory(target.Category, target)), 1, row);
            string text = state ?? (off.Contains(module) ? "not loaded: switched off in the mod's own Scripts\\config.lua" : "");
            if (text.Length > 0)
            {
                var note = Info();
                note.Text = text;
                note.ForeColor = Xp.C(0xB55A00);
                note.Margin = new Padding(12, 6, 3, 3);
                parts.Controls.Add(note, 2, row);
            }
            row++;
        }
        // the repopulate module: its switch stands on the page Advanced
        var world = _nav.Tabs.FirstOrDefault(t => t.Kind == NavKind.Repopulate);
        add(Mirror("The world fills up again: creatures, herbs, items, containers; the crime switch", _modOn), world, "repopulate", null);
        // the other modules, in the order of the pane
        var listed = new HashSet<ModuleSettings>();
        foreach (var tab in _nav.Tabs)
        {
            foreach (var module in tab.Modules)
            {
                if (!listed.Add(module)) continue;
                string part = NavModel.PlaceOf(module.Name)?.Part ?? module.Name;
                var home = _nav.HomeOf(module) ?? tab;
                if (module.Schema == null)
                {
                    var broken = Lbl(part);
                    broken.UseMnemonic = false;
                    broken.Margin = new Padding(3 + 17, 7, 3, 5);
                    add(broken, tab, module.Name, "its settings cannot be shown (see its page)");
                    continue;
                }
                var main = _generic.Find(module.Name, "Enabled");
                if (main != null && main.Input is XpCheckBox there) add(Mirror(part, there), home, module.Name, null);
                else
                {
                    var name = Lbl(part);
                    name.UseMnemonic = false;
                    name.Margin = new Padding(3 + 17, 7, 3, 5);       // in line with the texts of the check boxes, a row as high as theirs
                    add(name, home, module.Name, null);
                }
            }
        }
        var rows = new List<Control>();
        var wrapped = new List<Label>();        // the notes: they wrap at the page's width
        Label Wrapped(Label label) { wrapped.Add(label); return label; }
        if (_mega != null)
        {
            rows.Add(Group("Parts of the mod", Stack(
                parts,
                Wrapped(Note("Each tick is the part's own switch. A part that is off does nothing.")))));
            rows.Add(Group("Difficulty", Stack(
                _overviewPreset,
                Wrapped(Note("\"Preset\" above sets every page at once: 1 = the game itself, 5 = easiest.")))));
        }
        var folder = Info();
        folder.Text = ModFolder();
        folder.ForeColor = Color.Black;
        var open = Btn("Open the mod folder");
        open.Click += (_, _) => OpenModFolder();
        rows.Add(Group("Files", Stack(
            folder,
            Row(open),
            Wrapped(Note("Settings live in each module's config.lua. Save writes what changed and keeps config.lua.bak. "
                + "A running game reads it within seconds (map pins: at the next start).")))));
        // in a scroll panel like the module pages: in the smallest window (and with every further part) the page is higher than the tab
        var scroll = new XpScrollPanel { Dock = DockStyle.Fill, BackColor = Xp.Page };
        foreach (var label in wrapped) scroll.Wrap(label, 80);
        scroll.SetContent(Stack(rows.ToArray()));
        page.Controls.Add(scroll);
        return page;
    }

    private TabPage CreaturesPage()
    {
        var page = new TabPage("Creatures") { Padding = new Padding(4), UseVisualStyleBackColor = false, BackColor = Xp.Page };

        var groups = new TableLayoutPanel { ColumnCount = 2, Dock = DockStyle.Fill, AutoSize = true, Margin = new Padding(0) };
        groups.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        groups.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        // (two groups side by side beside the pane: short rows, the titles say what they are about)
        groups.Controls.Add(Group("Normal creatures: each missing one", Stack(
            Row(Lbl("Chance:"), _nChance, Lbl("% every"), _nHours, Lbl("in-game hours")),
            _nAvg)), 0, 0);
        groups.Controls.Add(Group("Elite creatures (tick \"Elite\" in the list): each missing one", Stack(
            Row(Lbl("Chance:"), _eChance, Lbl("% every"), _eHours, Lbl("in-game hours")),
            _eAvg)), 1, 0);

        BuildGrid();
        var gridPanel = new XpBorderPanel { Dock = DockStyle.Fill, Height = 300, BackColor = Color.White };
        gridPanel.Controls.Add(_grid);
        gridPanel.Controls.Add(_gridScroll);

        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, Padding = new Padding(6) };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        void add(Control c, bool fill = false)
        {
            layout.RowStyles.Add(fill ? new RowStyle(SizeType.Percent, 100) : new RowStyle(SizeType.AutoSize));
            layout.Controls.Add(c);
        }
        add(_crOn);
        add(groups);
        add(Row(_corpses));
        add(Row(Lbl("Only while you are at least"), _minDist, Lbl("m away from the spot")));
        add(Note("Per species: untick \"Respawns\" to stop it; tick \"Own settings\" for its own chance and interval. "
            + "Humans, orcs, named, boss and quest creatures never respawn."));
        add(gridPanel, fill: true);
        add(Row(_clearSpecies, _allOn));
        page.Controls.Add(layout);
        return page;
    }

    private TabPage ItemsPage()
    {
        var page = new TabPage("Herbs and items") { Padding = new Padding(4), UseVisualStyleBackColor = false, BackColor = Xp.Page };
        var herbs = Group("Herbs, plants, berries, mushrooms", Stack(
            _herbsOn,
            Row(Lbl("They grow back"), _regrow, Lbl("in-game hours after you picked them")),
            _herbsAvg));
        var items = Group("Other items lying in the world", Stack(
            _itemsOn,
            Row(Lbl("Refill chance per day:"), _itemChance, Lbl("%, at the latest after"), _maxDays, Lbl("days")),
            _itemsAvg));
        var notes = Stack(
            Note("Never: quest, unique, key, map and writing items, or story items."),
            Note("Items come back when you next pass by. Spots emptied before the mod count too."),
            Note("Off: the game's own behaviour."));
        var layout = Stack(herbs, items, notes);
        page.Controls.Add(layout);
        return page;
    }

    private TabPage ContainersPage()
    {
        var page = new TabPage("Containers") { Padding = new Padding(4), UseVisualStyleBackColor = false, BackColor = Xp.Page };
        var chances = Group("Chance per in-game day for an emptied container", Stack(
            Row(Lbl("In the camps and mines:"), _settle, Lbl("%")),
            _settleAvg,
            Row(Lbl("Everywhere else:"), _wild, Lbl("%")),
            _wildAvg));
        var more = Group("Details", Stack(
            _loot,
            Row(Lbl("After a long absence, catch up at most"), _catchUpDays, Lbl("days of rolls")),
            Row(Lbl("Containers already empty at first sight count as emptied"), _retroDays, Lbl("days ago (0 = from then)")),
            Row(Lbl("Containers within"), _checkRadius, Lbl("m of you are checked for missing items"))));
        var notes = Stack(
            Note("Only the original contents come back (no quest, unique, key or map items). Your own items stay."),
            Note("Taking from an owned chest is theft, as in the game. The Crime tab can switch theft off."));
        page.Controls.Add(Stack(_chestsOn, chances, more, notes));
        return page;
    }

    private TabPage CrimePage()
    {
        var page = new TabPage("Crime") { Padding = new Padding(4), UseVisualStyleBackColor = false, BackColor = Xp.Page };
        var main = Group("Crime", Stack(
            _crimeOn,
            _crimeState));
        var kinds = Group("With the crime system off, nobody reacts to", Stack(
            _crimeTheft,
            _crimeTresp,
            _crimeWeapons,
            _crimeForget));
        var notes = Stack(
            Note("Hitting or killing people always counts. Story fights are not touched."),
            Note("People already after you carry on until that ends."),
            Note("Counts within about 15 seconds of saving. Not stored in saves; forgotten crimes stay forgotten once you save."),
            Note("While the crime system is on, the mod leaves it alone."));
        page.Controls.Add(Stack(main, kinds, notes));
        return page;
    }

    private TabPage AdvancedPage()
    {
        var page = new TabPage("Advanced") { Padding = new Padding(4), UseVisualStyleBackColor = false, BackColor = Xp.Page };
        var general = Group("General", Stack(
            _modOn,
            Row(Lbl("Wait"), _startDelay, Lbl("seconds after loading a save")),
            _verbose,
            Row(Lbl("Re-read these settings every"), _reloadSecs, Lbl("seconds (0 = only at game start)"))));
        var creatures = Group("Creature respawning", Stack(
            Row(Lbl("At most"), _maxSpawns, Lbl("respawns per cycle")),
            Row(Lbl("After a long sleep, catch up at most"), _catchUpCycles, Lbl("cycles")),
            Row(Lbl("Seconds between two respawns:"), _spawnInterval),
            Row(Lbl("Characters checked per update:"), _censusSpeed),
            Row(Lbl("Never respawn at spawn points starting with (comma separated):"), _prefixes),
            _unknownElite));
        var openFolder = Btn("Open the mod folder");
        openFolder.Click += (_, _) => OpenModFolder();
        var file = Group("Settings file", Stack(_pathLabel, Row(openFolder)));
        page.Controls.Add(Stack(general, creatures, file));
        return page;
    }

    private void BuildGrid()
    {
        _grid.Dock = DockStyle.Fill;
        _grid.AllowUserToAddRows = false;
        _grid.AllowUserToDeleteRows = false;
        _grid.AllowUserToResizeRows = false;
        _grid.AllowUserToOrderColumns = false;
        _grid.RowHeadersVisible = false;
        _grid.MultiSelect = false;
        _grid.SelectionMode = DataGridViewSelectionMode.CellSelect;
        _grid.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
        _grid.BackgroundColor = Color.White;
        _grid.BorderStyle = BorderStyle.None;
        _grid.EditMode = DataGridViewEditMode.EditOnEnter;
        _grid.ScrollBars = ScrollBars.None;
        // XP list view look
        _grid.Font = Xp.UiFont;
        _grid.EnableHeadersVisualStyles = false;
        _grid.ColumnHeadersBorderStyle = DataGridViewHeaderBorderStyle.None;
        _grid.ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.DisableResizing;
        _grid.ColumnHeadersHeight = 24;
        _grid.ColumnHeadersDefaultCellStyle.BackColor = Xp.C(0xEBEAE3);
        _grid.ColumnHeadersDefaultCellStyle.ForeColor = Color.Black;
        _grid.ColumnHeadersDefaultCellStyle.Font = Xp.UiFont;
        _grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = Xp.C(0xEBEAE3);
        _grid.CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal;
        _grid.GridColor = Xp.GridLine;
        _grid.RowTemplate.Height = 20;
        _grid.DefaultCellStyle.BackColor = Color.White;
        _grid.DefaultCellStyle.ForeColor = Color.Black;
        _grid.DefaultCellStyle.Font = Xp.UiFont;
        // like an XP list: the blue selection only shows while the list has the focus
        void selectionColors(bool focused)
        {
            _grid.DefaultCellStyle.SelectionBackColor = focused ? Xp.Selection : Color.White;
            _grid.DefaultCellStyle.SelectionForeColor = focused ? Color.White : Color.Black;
        }
        selectionColors(false);
        _grid.Enter += (_, _) => selectionColors(true);
        _grid.Leave += (_, _) => selectionColors(false);
        _grid.CellPainting += PaintGridCell;
        _gridScroll.Width = SystemInformation.VerticalScrollBarWidth;
        _gridScroll.ValueChanged += (_, _) =>
        {
            if (_grid.RowCount == 0) return;
            int v = Math.Clamp(_gridScroll.Value, 0, _grid.RowCount - 1);
            if (_grid.FirstDisplayedScrollingRowIndex != v) _grid.FirstDisplayedScrollingRowIndex = v;
        };
        _grid.MouseWheel += (_, e) =>
        {
            if (e is HandledMouseEventArgs h) h.Handled = true;
            _gridScroll.Value -= Math.Sign(e.Delta) * 3;
        };
        _grid.Scroll += (_, _) => SyncGridScroll();
        _grid.Resize += (_, _) => SyncGridScroll();
        _grid.CurrentCellChanged += (_, _) => SyncGridScroll();

        DataGridViewTextBoxColumn TextCol(string name, string header, float weight, bool ro, bool right = false)
        {
            var c = new DataGridViewTextBoxColumn
            {
                Name = name, HeaderText = header, FillWeight = weight, ReadOnly = ro, SortMode = DataGridViewColumnSortMode.NotSortable,
            };
            if (right) c.DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
            return c;
        }
        DataGridViewCheckBoxColumn CheckCol(string name, string header, float weight) => new()
        {
            Name = name, HeaderText = header, FillWeight = weight, SortMode = DataGridViewColumnSortMode.NotSortable,
        };

        _grid.Columns.Add(TextCol("name", "Species", 20, true));
        _grid.Columns.Add(TextCol("count", "Creatures", 9, true, true));
        _grid.Columns.Add(TextCol("points", "Points", 7, true, true));
        _grid.Columns.Add(CheckCol("elite", "Elite", 6));
        _grid.Columns.Add(CheckCol("on", "Respawns", 10));
        _grid.Columns.Add(CheckCol("own", "Own settings", 12));
        _grid.Columns.Add(TextCol("chance", "Chance %", 10, false, true));
        _grid.Columns.Add(TextCol("hours", "Every (h)", 9, false, true));
        _grid.Columns.Add(TextCol("avg", "Back after (average)", 20, true));
        _grid.Columns["count"]!.ToolTipText = "Creatures of this species at the mod's spawn points.";
        _grid.Columns["points"]!.ToolTipText = "Spawn points this species uses.";
        _grid.Columns["avg"]!.ToolTipText = "Average time until it is back: game time and real time (the clock runs 15x).";
        _grid.Columns["elite"]!.ToolTipText = "Elite species use the elite chance and interval.";
        _grid.Columns["own"]!.ToolTipText = "Its own chance and interval instead of its group's.";
    }

    private void SyncGridScroll()
    {
        int rows = _grid.RowCount;
        int visible = Math.Max(1, _grid.DisplayedRowCount(false));
        _gridScroll.Maximum = Math.Max(1, rows);
        _gridScroll.LargeChange = visible;
        _gridScroll.Visible = rows > visible;
        if (_grid.FirstDisplayedScrollingRowIndex >= 0) _gridScroll.SetSilently(_grid.FirstDisplayedScrollingRowIndex);
    }

    // XP look for the species list: list-view style headers and XP check boxes
    private void PaintGridCell(object? sender, DataGridViewCellPaintingEventArgs e)
    {
        var g = e.Graphics;
        if (g == null) return;
        float s = Xp.Scale(this);
        if (e.RowIndex == -1 && e.ColumnIndex >= 0)
        {
            var r = e.CellBounds;
            Xp.VGradient(g, r, Color.White, Xp.C(0xEBEAE3));
            using (var p1 = new Pen(Xp.C(0xE2DECD))) g.DrawLine(p1, r.Left, r.Bottom - 3, r.Right, r.Bottom - 3);
            using (var p2 = new Pen(Xp.C(0xD6D2C2))) g.DrawLine(p2, r.Left, r.Bottom - 2, r.Right, r.Bottom - 2);
            using (var p3 = new Pen(Xp.C(0xCBC7B8))) g.DrawLine(p3, r.Left, r.Bottom - 1, r.Right, r.Bottom - 1);
            using (var sep = new Pen(Xp.C(0xC7C5B2))) g.DrawLine(sep, r.Right - 2, r.Top + 4, r.Right - 2, r.Bottom - 6);
            using (var sepL = new Pen(Color.White)) g.DrawLine(sepL, r.Right - 1, r.Top + 4, r.Right - 1, r.Bottom - 6);
            var col = _grid.Columns[e.ColumnIndex];
            var flags = TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis |
                (col is DataGridViewCheckBoxColumn ? TextFormatFlags.HorizontalCenter
                 : col.DefaultCellStyle.Alignment == DataGridViewContentAlignment.MiddleRight ? TextFormatFlags.Right : TextFormatFlags.Left);
            TextRenderer.DrawText(g, col.HeaderText, Xp.UiFont, new Rectangle(r.X + 5, r.Y, r.Width - 12, r.Height - 2), Color.Black, flags);
            e.Handled = true;
            return;
        }
        if (e.RowIndex >= 0 && e.ColumnIndex >= 0 && _grid.Columns[e.ColumnIndex] is DataGridViewCheckBoxColumn)
        {
            e.PaintBackground(e.CellBounds, true);
            int box = Math.Max(13, (int)Math.Round(13 * s));
            var br = new Rectangle(e.CellBounds.X + (e.CellBounds.Width - box) / 2, e.CellBounds.Y + (e.CellBounds.Height - box) / 2, box, box);
            bool hot = _grid.RectangleToScreen(e.CellBounds).Contains(Cursor.Position);
            Xp.DrawCheckBox(g, br, Bool(e.Value), hot, false, true);
            e.Handled = true;
        }
    }

    // =====================================================================
    // events
    // =====================================================================
    private void WireEvents()
    {
        foreach (var n in new[] { _nChance, _eChance, _nHours, _eHours, _minDist, _regrow, _itemChance, _maxDays, _settle, _wild,
                     _catchUpDays, _retroDays, _checkRadius, _startDelay, _reloadSecs, _maxSpawns, _catchUpCycles, _spawnInterval, _censusSpeed })
            n.ValueChanged += (_, _) => Changed(groupValuesChanged: n == _nChance || n == _eChance || n == _nHours || n == _eHours);
        foreach (var c in new[] { _crOn, _corpses, _herbsOn, _itemsOn, _chestsOn, _loot, _modOn, _verbose,
                     _crimeOn, _crimeTheft, _crimeTresp, _crimeWeapons, _crimeForget })
            c.CheckedChanged += (_, _) => Changed();
        _prefixes.Box.TextChanged += (_, _) => Changed();

        _grid.CurrentCellDirtyStateChanged += (_, _) =>
        {
            if (_grid.IsCurrentCellDirty && _grid.CurrentCell is DataGridViewCheckBoxCell)
                _grid.CommitEdit(DataGridViewDataErrorContexts.Commit);
        };
        _grid.CellValueChanged += GridValueChanged;
        _grid.CellValidating += GridValidating;
        _grid.CellEndEdit += (_, e) => { _grid.Rows[e.RowIndex].ErrorText = ""; };
        _grid.CellBeginEdit += (_, e) =>
        {
            string col = _grid.Columns[e.ColumnIndex].Name;
            if ((col == "chance" || col == "hours") && !(Bool(_grid.Rows[e.RowIndex].Cells["own"].Value))) e.Cancel = true;
        };
        _grid.DataError += (_, e) => { e.ThrowException = false; };
        _grid.CellMouseEnter += (_, e) => { if (e.RowIndex >= 0 && e.ColumnIndex >= 0 && _grid.Columns[e.ColumnIndex] is DataGridViewCheckBoxColumn) _grid.InvalidateCell(e.ColumnIndex, e.RowIndex); };
        _grid.CellMouseLeave += (_, e) => { if (e.RowIndex >= 0 && e.ColumnIndex >= 0 && _grid.Columns[e.ColumnIndex] is DataGridViewCheckBoxColumn) _grid.InvalidateCell(e.ColumnIndex, e.RowIndex); };

        _presetApply.Click += (_, _) => ApplyPreset(_preset.SelectedIndex - 1);
        _preset.SelectedIndexChanged += (_, _) => _presetApply.Enabled = _preset.SelectedIndex > 0;     // the first line is no preset: nothing to apply
        _scaleChanceApply.Click += (_, _) => ScaleChances((double)_scaleChance.Value / 100.0);
        _scaleTimeApply.Click += (_, _) => ScaleTimers((double)_scaleTime.Value / 100.0);
        _clearSpecies.Click += (_, _) =>
        {
            ReadControls();
            var known = new HashSet<string>(_catalog.Select(c => c.Unique), StringComparer.Ordinal);
            foreach (string k in _s.Species.Keys.Where(known.Contains).ToList()) _s.Species.Remove(k);
            _s.ExcludeSpecies.RemoveAll(known.Contains);
            RefreshControls();
            MarkDirty();
        };
        _allOn.Click += (_, _) =>
        {
            ReadControls();
            foreach (var o in _s.Species.Values) o.Enabled = null;
            foreach (string k in _s.Species.Where(kv => kv.Value.IsEmpty).Select(kv => kv.Key).ToList()) _s.Species.Remove(k);
            _s.ExcludeSpecies.Clear();
            RefreshControls();
            MarkDirty();
        };

        _save.Click += (_, _) => SaveFile();
        _revert.Click += (_, _) =>
        {
            if (_dirty && !_testMode && XpMessageBox.Show(this, _generic.Items.Count > 0 ? "Throw away your changes and read the settings files again?" : "Throw away your changes and reload config.lua?",
                    _title, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
            LoadFromFile(initial: false);
        };
        _defaults.Click += (_, _) =>
        {
            var categories = _generic.Pages.Where(p => p.Items.Count > 0).Select(p => p.Model.Category.Title).Distinct(StringComparer.Ordinal).ToList();
            string others = categories.Count > 0 ? "\n\nThe settings on the pages of " + string.Join(", ", categories) + " get their default values too." : "";
            if (!_testMode && XpMessageBox.Show(this, "Set everything to the default values (creatures 35 % / 24 h, elites 15 % / 24 h, herbs 24 h, items 15 % per day, containers 30 % / 10 % per day, crime system on"
                    + ") and clear all per-species settings?" + others + "\n\nNothing is written until you press Save. (One page only: \"Defaults for this page\" in the pane on the left.)",
                    _title, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
            var extra = _s.Extra;
            _s = new Settings { Extra = extra };
            RefreshControls();
            _generic.SetDefaults();
            MarkDirty();
        };
        FormClosing += (_, e) =>
        {
            if (!_dirty || _testMode) return;
            var r = XpMessageBox.Show(this, _generic.Items.Count > 0 ? "Save your changes?" : "Save your changes to config.lua?", _title, MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (r == DialogResult.Cancel) e.Cancel = true;
            else if (r == DialogResult.Yes && !SaveFile()) e.Cancel = true;
        };

        // Find: the list follows the text; it goes away when neither the box nor the list has the focus
        _find.Box.TextChanged += (_, _) => FindNow();
        _find.Box.GotFocus += (_, _) => { if (_find.Box.Text.Trim().Length > 0) FindNow(); };
        _find.Box.LostFocus += (_, _) => BeginInvoke(new Action(() => { if (!_find.Box.Focused && !_findList.Focused) HideFindList(); }));
        _findList.LostFocus += (_, _) => BeginInvoke(new Action(() => { if (!_find.Box.Focused && !_findList.Focused) HideFindList(); }));
        _findList.Picked += GoTo;
        Resize += (_, _) => { if (_findList.Visible) PlaceFindList(); };
        // The game writes the other modules' files too (its in-game menu): when the window comes to the front,
        // a module whose file changed, and on whose settings nothing was changed here, shows the file's values.
        Activated += (_, _) =>
        {
            if (_loading) return;
            var reread = _generic.RereadUntouched();
            if (reread.Count > 0 && !_dirty) MarkClean("Read again, changed outside the app: " + string.Join(", ", reread) + ".");
            LookAtFiles();
        };
    }

    private void Changed(bool groupValuesChanged = false)
    {
        if (_loading) return;
        if (groupValuesChanged)
        {
            // rows without own settings show their group's values
            _loading = true;
            try
            {
                foreach (DataGridViewRow r in _grid.Rows)
                {
                    if (Bool(r.Cells["own"].Value)) continue;
                    bool elite = Bool(r.Cells["elite"].Value);
                    r.Cells["chance"].Value = FmtPct((double)(elite ? _eChance.Value : _nChance.Value) / 100.0);
                    r.Cells["hours"].Value = ((int)(elite ? _eHours.Value : _nHours.Value)).ToString(Inv);
                }
            }
            finally { _loading = false; }
        }
        ReadControls();
        MarkDirty();
    }

    private void GridValueChanged(object? sender, DataGridViewCellEventArgs e)
    {
        if (_loading || e.RowIndex < 0) return;
        var row = _grid.Rows[e.RowIndex];
        string col = _grid.Columns[e.ColumnIndex].Name;
        _loading = true;
        try
        {
            if (col == "own" || col == "elite")
            {
                bool own = Bool(row.Cells["own"].Value);
                if (!own)
                {
                    bool elite = Bool(row.Cells["elite"].Value);
                    row.Cells["chance"].Value = FmtPct((double)(elite ? _eChance.Value : _nChance.Value) / 100.0);
                    row.Cells["hours"].Value = ((int)(elite ? _eHours.Value : _nHours.Value)).ToString(Inv);
                }
                StyleRow(row);
            }
            else if (col == "chance" && TryPct(row.Cells["chance"].Value, out double p))
                row.Cells["chance"].Value = FmtPct(p);
            else if (col == "hours" && TryHours(row.Cells["hours"].Value, out int h))
                row.Cells["hours"].Value = h.ToString(Inv);
            else if (col == "on")
                StyleRow(row);
        }
        finally { _loading = false; }
        ReadControls();
        MarkDirty();
    }

    private void GridValidating(object? sender, DataGridViewCellValidatingEventArgs e)
    {
        string col = _grid.Columns[e.ColumnIndex].Name;
        var row = _grid.Rows[e.RowIndex];
        if (col == "chance" && !TryPct(e.FormattedValue, out _))
        {
            row.ErrorText = "Chance: a number from 0 to 100";
            e.Cancel = true;
        }
        else if (col == "hours" && !TryHours(e.FormattedValue, out _))
        {
            row.ErrorText = "Interval: whole in-game hours from 1 to 8760";
            e.Cancel = true;
        }
    }

    // =====================================================================
    // model <-> controls
    // =====================================================================
    private static bool Bool(object? v) => v is bool b && b;

    private static string FmtPct(double chance) => (Math.Round(chance * 1000) / 10).ToString("0.#", Inv);

    private static bool TryPct(object? v, out double chance)
    {
        chance = 0;
        string s = (v?.ToString() ?? "").Trim().TrimEnd('%').Trim().Replace(',', '.');
        if (!double.TryParse(s, NumberStyles.Float, Inv, out double pct) || pct < 0 || pct > 100) return false;
        chance = Math.Round(pct * 10) / 1000.0;
        return true;
    }

    private static bool TryHours(object? v, out int hours)
    {
        hours = 0;
        string s = (v?.ToString() ?? "").Trim().TrimEnd('h').Trim();
        if (!double.TryParse(s, NumberStyles.Float, Inv, out double d) || d < 1 || d > 8760) return false;
        hours = (int)Math.Round(d);
        return true;
    }

    private static decimal Clamp(NumericUpDown n, double v) => Math.Min(n.Maximum, Math.Max(n.Minimum, (decimal)Math.Round(v, n.DecimalPlaces)));

    private bool IsElite(string unique) => _s.EliteSpecies.Contains(unique);

    private void StyleRow(DataGridViewRow row)
    {
        bool own = Bool(row.Cells["own"].Value);
        bool on = Bool(row.Cells["on"].Value);
        foreach (string c in new[] { "chance", "hours" })
        {
            row.Cells[c].ReadOnly = !own;
            row.Cells[c].Style.ForeColor = own && on ? Color.Black : Xp.DisabledText;
        }
        row.Cells["name"].Style.ForeColor = on ? Color.Black : Xp.DisabledText;
    }

    private void RefreshControls()
    {
        _loading = true;
        try
        {
            _modOn.Checked = _s.Enabled;
            _startDelay.Value = Clamp(_startDelay, _s.StartDelaySeconds);
            _verbose.Checked = _s.Verbose;
            _reloadSecs.Value = Clamp(_reloadSecs, _s.ReloadCheckSeconds);

            _crOn.Checked = _s.CreaturesEnabled;
            _nChance.Value = Clamp(_nChance, _s.NormalChance * 100);
            _nHours.Value = Clamp(_nHours, _s.NormalEveryHours);
            _eChance.Value = Clamp(_eChance, _s.EliteChance * 100);
            _eHours.Value = Clamp(_eHours, _s.EliteEveryHours);
            _corpses.Checked = _s.RemoveCorpsesOnRespawn;
            _minDist.Value = Clamp(_minDist, _s.MinPlayerDistance / 100.0);
            _maxSpawns.Value = Clamp(_maxSpawns, _s.MaxSpawnsPerCycle);
            _catchUpCycles.Value = Clamp(_catchUpCycles, _s.MaxCatchUpCycles);
            _spawnInterval.Value = Clamp(_spawnInterval, _s.SpawnIntervalSeconds);
            _censusSpeed.Value = Clamp(_censusSpeed, _s.CensusStatesPerTick);
            _prefixes.Box.Text = string.Join(", ", _s.ExcludePointPrefixes);

            _herbsOn.Checked = _s.HerbsEnabled;
            _regrow.Value = Clamp(_regrow, _s.RegrowHours);
            _itemsOn.Checked = _s.WorldItemsEnabled;
            _itemChance.Value = Clamp(_itemChance, _s.DailyChance * 100);
            _maxDays.Value = Clamp(_maxDays, _s.MaxDays);

            _chestsOn.Checked = _s.ChestsEnabled;
            _settle.Value = Clamp(_settle, _s.SettlementDailyChance * 100);
            _wild.Value = Clamp(_wild, _s.WildDailyChance * 100);
            _loot.Checked = _s.IncludeLootObjects;
            _catchUpDays.Value = Clamp(_catchUpDays, _s.MaxCatchUpDays);
            _retroDays.Value = Clamp(_retroDays, _s.RetroactiveDays);
            _checkRadius.Value = Clamp(_checkRadius, _s.CheckRadius / 100.0);

            _crimeOn.Checked = _s.CrimeEnabled;
            _crimeTheft.Checked = _s.CrimeDisableTheft;
            _crimeTresp.Checked = _s.CrimeDisableTrespassing;
            _crimeWeapons.Checked = _s.CrimeDisableWeapons;
            _crimeForget.Checked = _s.CrimeForgetOld;

            _grid.Rows.Clear();
            foreach (var sp in _catalog)
            {
                bool elite = IsElite(sp.Unique);
                _s.Species.TryGetValue(sp.Unique, out var o);
                bool on = o?.Enabled != false && !_s.ExcludeSpecies.Contains(sp.Unique);
                bool own = o != null && (o.Chance != null || o.EveryHours != null);
                double ch = o?.Chance ?? (elite ? _s.EliteChance : _s.NormalChance);
                int h = o?.EveryHours ?? (elite ? _s.EliteEveryHours : _s.NormalEveryHours);
                int i = _grid.Rows.Add(sp.Display, sp.Creatures, sp.Points, elite, on, own, FmtPct(ch), h.ToString(Inv), "");
                var row = _grid.Rows[i];
                row.Tag = sp;
                row.Cells["name"].ToolTipText = sp.Unique;
                StyleRow(row);
            }

            var known = new HashSet<string>(_catalog.Select(c => c.Unique), StringComparer.Ordinal);
            var otherElite = _s.EliteSpecies.Where(n => !known.Contains(n)).ToList();
            var otherSpecies = _s.Species.Keys.Where(n => !known.Contains(n)).ToList();
            var parts = new List<string>();
            if (otherElite.Count > 0) parts.Add("Elite names without spawn points in this mod (kept): " + string.Join(", ", otherElite));
            if (otherSpecies.Count > 0) parts.Add("Per-species settings for names not in the list (kept): " + string.Join(", ", otherSpecies));
            _unknownElite.Text = string.Join("\n", parts);
            _pathLabel.Text = _configPath;
        }
        finally { _loading = false; }
        UpdateDerived();
        SyncGridScroll();
        _grid.ClearSelection();
    }

    private void ReadControls()
    {
        _s.Enabled = _modOn.Checked;
        _s.StartDelaySeconds = (int)_startDelay.Value;
        _s.Verbose = _verbose.Checked;
        _s.ReloadCheckSeconds = (int)_reloadSecs.Value;

        _s.CreaturesEnabled = _crOn.Checked;
        _s.NormalChance = (double)_nChance.Value / 100.0;
        _s.NormalEveryHours = (int)_nHours.Value;
        _s.EliteChance = (double)_eChance.Value / 100.0;
        _s.EliteEveryHours = (int)_eHours.Value;
        _s.RemoveCorpsesOnRespawn = _corpses.Checked;
        _s.MinPlayerDistance = (int)Math.Round(_minDist.Value * 100);
        _s.MaxSpawnsPerCycle = (int)_maxSpawns.Value;
        _s.MaxCatchUpCycles = (int)_catchUpCycles.Value;
        _s.SpawnIntervalSeconds = (double)_spawnInterval.Value;
        _s.CensusStatesPerTick = (int)_censusSpeed.Value;
        _s.ExcludePointPrefixes = _prefixes.Box.Text.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(p => p.Length > 0).Distinct(StringComparer.Ordinal).ToList();

        _s.HerbsEnabled = _herbsOn.Checked;
        _s.RegrowHours = (int)_regrow.Value;
        _s.WorldItemsEnabled = _itemsOn.Checked;
        _s.DailyChance = (double)_itemChance.Value / 100.0;
        _s.MaxDays = (int)_maxDays.Value;

        _s.ChestsEnabled = _chestsOn.Checked;
        _s.SettlementDailyChance = (double)_settle.Value / 100.0;
        _s.WildDailyChance = (double)_wild.Value / 100.0;
        _s.IncludeLootObjects = _loot.Checked;
        _s.MaxCatchUpDays = (int)_catchUpDays.Value;
        _s.RetroactiveDays = (int)_retroDays.Value;
        _s.CheckRadius = (int)Math.Round(_checkRadius.Value * 100);

        _s.CrimeEnabled = _crimeOn.Checked;
        _s.CrimeDisableTheft = _crimeTheft.Checked;
        _s.CrimeDisableTrespassing = _crimeTresp.Checked;
        _s.CrimeDisableWeapons = _crimeWeapons.Checked;
        _s.CrimeForgetOld = _crimeForget.Checked;

        // species list -> elite list and per-species settings
        var known = new HashSet<string>(_catalog.Select(c => c.Unique), StringComparer.Ordinal);
        var rowElite = new Dictionary<string, bool>(StringComparer.Ordinal);
        foreach (DataGridViewRow r in _grid.Rows)
        {
            if (r.Tag is not SpeciesInfo sp) continue;
            rowElite[sp.Unique] = Bool(r.Cells["elite"].Value);
            bool on = Bool(r.Cells["on"].Value);
            bool own = Bool(r.Cells["own"].Value);
            var o = new SpeciesOverride();
            if (!on) o.Enabled = false;
            if (own)
            {
                if (TryPct(r.Cells["chance"].Value, out double p)) o.Chance = p;
                if (TryHours(r.Cells["hours"].Value, out int h)) o.EveryHours = h;
            }
            if (o.IsEmpty) _s.Species.Remove(sp.Unique); else _s.Species[sp.Unique] = o;
            _s.ExcludeSpecies.Remove(sp.Unique);
        }
        var elite = new List<string>();
        foreach (string n in _s.EliteSpecies)
            if ((!known.Contains(n) || (rowElite.TryGetValue(n, out bool isE) && isE)) && !elite.Contains(n)) elite.Add(n);
        foreach (var kv in rowElite)
            if (kv.Value && !elite.Contains(kv.Key)) elite.Add(kv.Key);
        if (rowElite.Count > 0) _s.EliteSpecies = elite;
        UpdateDerived();
    }

    // =====================================================================
    // derived numbers
    // =====================================================================
    // In-game hours -> "2.4 in-game days (about 3.8 h of play)"; the clock runs 15x real time.
    private static string Span(double gameHours)
    {
        string game = gameHours < 48 ? $"{gameHours.ToString("0.#", Inv)} in-game hours" : $"{(gameHours / 24).ToString("0.#", Inv)} in-game days";
        double real = gameHours / 15.0;
        string play = real < 1 ? $"{Math.Max(1, Math.Round(real * 60)).ToString("0", Inv)} min of play" : $"{real.ToString("0.#", Inv)} h of play";
        return $"{game} (about {play})";
    }

    // Average time from death to return: first boundary after ~h/2, then one roll per interval.
    private static string CreatureAvg(double p, int h, bool on)
    {
        if (!on) return "never (off)";
        if (p <= 0) return "never (0 %)";
        return Span(h / p - h / 2.0);
    }

    // Short form for the list: "2.4 days (3.8 h real)"
    private static string CreatureAvgShort(double p, int h, bool on)
    {
        if (!on) return "never (off)";
        if (p <= 0) return "never (0 %)";
        double gameHours = h / p - h / 2.0;
        string game = gameHours < 48 ? $"{gameHours.ToString("0.#", Inv)} h" : $"{(gameHours / 24).ToString("0.#", Inv)} days";
        double real = gameHours / 15.0;
        string play = real < 1 ? $"{Math.Max(1, Math.Round(real * 60)).ToString("0", Inv)} min real" : $"{real.ToString("0.#", Inv)} h real";
        return $"{game} ({play})";
    }

    private void UpdateDerived()
    {
        bool crOn = _s.CreaturesEnabled;
        _nAvg.Text = "Back after " + CreatureAvg(_s.NormalChance, _s.NormalEveryHours, crOn) + " on average.";
        _eAvg.Text = "Back after " + CreatureAvg(_s.EliteChance, _s.EliteEveryHours, crOn) + " on average.";
        foreach (DataGridViewRow r in _grid.Rows)
        {
            if (r.Tag is not SpeciesInfo) continue;
            bool on = crOn && Bool(r.Cells["on"].Value);
            TryPct(r.Cells["chance"].Value, out double p);
            TryHours(r.Cells["hours"].Value, out int h);
            r.Cells["avg"].Value = CreatureAvgShort(p, Math.Max(1, h), on);
        }
        _herbsAvg.Text = _s.HerbsEnabled ? $"Picked plants are back after {Span(_s.RegrowHours)}." : "Plants do not regrow (game default).";
        if (_s.WorldItemsEnabled && _s.DailyChance > 0)
        {
            double p = _s.DailyChance;
            double days = (1 - Math.Pow(1 - p, _s.MaxDays)) / p;
            _itemsAvg.Text = $"An emptied spot is refilled after {Span(days * 24)} on average, never later than {_s.MaxDays} days.";
        }
        else _itemsAvg.Text = _s.WorldItemsEnabled ? $"Spots are refilled after {_s.MaxDays} days." : "Items do not come back (game default).";
        _settleAvg.Text = _s.ChestsEnabled ? (_s.SettlementDailyChance > 0 ? $"Restocked after {Span(24 / _s.SettlementDailyChance)} on average." : "Never restocked.") : "Off.";
        _wildAvg.Text = _s.ChestsEnabled ? (_s.WildDailyChance > 0 ? $"Restocked after {Span(24 / _s.WildDailyChance)} on average." : "Never restocked.") : "Off.";

        // crime: the kinds only matter while the system is off
        bool crimeOff = !_s.CrimeEnabled;
        foreach (var c in new[] { _crimeTheft, _crimeTresp, _crimeWeapons, _crimeForget }) c.Enabled = crimeOff;
        var kinds = new List<string>();
        if (_s.CrimeDisableTheft) kinds.Add("theft");
        if (_s.CrimeDisableTrespassing) kinds.Add("trespassing");
        if (_s.CrimeDisableWeapons) kinds.Add("drawn weapons");
        _crimeForget.Enabled = crimeOff && kinds.Count > 0;
        if (!crimeOff) _crimeState.Text = "On: the game's own rules.";
        else if (kinds.Count == 0) _crimeState.Text = "Off, but nothing ticked below: crime as the game has it.";
        else if (!_s.Enabled) _crimeState.Text = "Off for " + string.Join(", ", kinds) + " - but the mod is disabled (Advanced): the game's rules apply.";
        else _crimeState.Text = "Off: nobody reacts to " + string.Join(", ", kinds) + ". Hitting or killing people still counts.";
        _crimeState.ForeColor = crimeOff && kinds.Count > 0 && _s.Enabled ? Xp.C(0xB55A00) : Xp.Hint;

    }

    private void MarkDirty()
    {
        _dirty = true;
        Text = _title + " *";
        _status.Text = "Unsaved changes - press Save.";
        _status.ForeColor = Color.Black;
        MarkPresetInUse();
        UpdateMarks();
    }

    private void MarkClean(string message, bool warn = false)
    {
        _dirty = false;
        Text = _title;
        _status.Text = message;
        _status.ForeColor = warn ? Xp.C(0xB55A00) : Xp.Hint;
        MarkPresetInUse();
        UpdateMarks();
    }

    // =====================================================================
    // presets and mass changes
    // =====================================================================
    /// <summary>The preset (1 to 5) whose values every setting it covers has right now, or 0: the player's own mix.</summary>
    private int PresetInUse()
    {
        for (int tier = 1; tier <= Presets.Count; tier++)
            if (Presets.Matches(_s, tier) && _generic.MatchesTier(tier)) return tier;
        return 0;
    }

    // The box says where the settings are: at one of the presets or at none ("Your own settings"). That line carries
    // "- in use", and the box stands on it and follows it - until the user picks another line, which is his choice of
    // what to apply and stays.
    private void MarkPresetInUse()
    {
        if (_preset.Items.Count != Presets.Count + 1) return;
        int now;
        try { now = PresetInUse(); } catch { now = 0; }
        bool was = _loading;
        _loading = true;
        try
        {
            int selected = _preset.SelectedIndex;
            bool follows = _presetState < 0 || selected == _presetState;
            for (int i = 0; i <= Presets.Count; i++)
            {
                string text = (i == 0 ? OwnName : Presets.Names[i - 1]) + (i == now ? InUse : "");
                if (!string.Equals(_preset.Items[i] as string, text, StringComparison.Ordinal)) _preset.Items[i] = text;
            }
            int want = follows ? now : selected;
            if (_preset.SelectedIndex != want) _preset.SelectedIndex = want;
            _presetState = now;
        }
        finally { _loading = was; }
        _presetApply.Enabled = _preset.SelectedIndex > 0;
        _preset.Invalidate();
        // the pane and the first page say it too
        string name = now == 0 ? OwnName : Presets.Names[now - 1];
        string line = now == 0 ? "Your own settings (none of the five presets)." : "Preset in use: " + name + ".";
        if (_overviewPreset.Text != line) _overviewPreset.Text = line;
        if (_detailPreset != null && _mega != null)
        {
            string detail = now == 0 ? OwnName : "Preset " + name;
            if (_detailPreset.Text != detail) { _detailPreset.Text = detail; _pane.Changed(); }
        }
    }

    private void ApplyPreset(int index)
    {
        if (index < 0 || index >= Presets.Count) return;
        string name = Presets.Names[index];
        var pages = new List<string> { NavModel.World + " (Creatures, Herbs and items, Containers, Crime)" };
        pages.AddRange(_generic.TierCategories());
        if (!_testMode && XpMessageBox.Show(this, "Set everything that makes the game easier or harder to the preset \"" + name + "\"?\n\n"
                + "Pages: " + string.Join(", ", pages) + ".\n"
                + "Keys, notes, log switches, melee clean-ups, waiting, the map pins and per-species settings stay as they are.\n\n"
                + "Nothing is written until you press Save.",
                _title, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
        ReadControls();
        Presets.Apply(_s, index + 1);
        RefreshControls();
        _generic.ApplyTier(index + 1);
        MarkDirty();
        var problems = _generic.TierProblems();
        _status.Text = $"Preset \"{name}\" set on all pages (per-species settings kept) - press Save."
            + (problems.Count > 0 ? " Left out: " + string.Join("; ", problems) + "." : "");
    }

    private void ScaleChances(double f)
    {
        ReadControls();
        static double S(double v, double f) => Math.Clamp(Math.Round(v * f, 3), 0, 1);
        _s.NormalChance = S(_s.NormalChance, f);
        _s.EliteChance = S(_s.EliteChance, f);
        _s.DailyChance = S(_s.DailyChance, f);
        _s.SettlementDailyChance = S(_s.SettlementDailyChance, f);
        _s.WildDailyChance = S(_s.WildDailyChance, f);
        foreach (var o in _s.Species.Values) if (o.Chance != null) o.Chance = S(o.Chance.Value, f);
        RefreshControls();
        _scaleChance.Value = 100;
        MarkDirty();
        _status.Text = $"All chances scaled to {Math.Round(f * 100)} % - press Save.";
    }

    private void ScaleTimers(double f)
    {
        ReadControls();
        static int S(int v, double f) => (int)Math.Clamp(Math.Round(v * f), 1, 8760);
        _s.NormalEveryHours = S(_s.NormalEveryHours, f);
        _s.EliteEveryHours = S(_s.EliteEveryHours, f);
        _s.RegrowHours = S(_s.RegrowHours, f);
        foreach (var o in _s.Species.Values) if (o.EveryHours != null) o.EveryHours = S(o.EveryHours.Value, f);
        RefreshControls();
        _scaleTime.Value = 100;
        MarkDirty();
        _status.Text = $"All timers scaled to {Math.Round(f * 100)} % - press Save.";
    }

    // =====================================================================
    // file
    // =====================================================================
    private void LoadFromFile(bool initial)
    {
        _catalog = SpeciesCatalog.Load(Paths.DataFile(_configPath, "creature_points.lua"), out _catalogError);
        _warnings = new List<string>();
        string? problem = null;
        try
        {
            string text = File.ReadAllText(_configPath);
            _s = Settings.FromText(text, _warnings);
        }
        catch (Exception ex)
        {
            problem = ex is LuaParseException ? "config.lua has an error (" + ex.Message + ")" : "config.lua could not be read: " + ex.Message;
        }
        if (problem != null)
        {
            if (_testMode) throw new InvalidOperationException(problem);
            var r = XpMessageBox.Show(this, problem + "\n\nStart from the default settings? (Nothing is written until you press Save; the old file is kept as config.lua.bak.)",
                _title, MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (r != DialogResult.Yes)
            {
                if (initial) { BeginInvoke(new Action(Close)); }
                return;
            }
            _s = new Settings();
        }
        _generic.Load();        // the other modules' files: never fails; what is wrong with a file stands on its page
        _presetState = -1;      // the box starts at the line the files are at, whatever was picked in it before
        RefreshControls();
        TakeBaseline();
        if (problem != null) { _baseline = ""; MarkDirty(); _status.Text = "Defaults loaded because config.lua had an error - press Save to replace it."; return; }
        string msg = "Loaded " + _configPath;
        if (_catalogError != null) msg += " | species list unavailable: " + _catalogError;
        if (_warnings.Count > 0) msg += $" | {_warnings.Count} value(s) were invalid and replaced by defaults (hover for details)";
        var noted = _generic.ModulesWithNotes();
        if (noted.Count > 0) msg += " | the settings file of " + string.Join(", ", noted) + " needs a look (see its page)";
        string gameNote = LookAtFiles();
        if (gameNote.Length > 0) msg += " | " + gameNote;
        _tip.SetToolTip(_status, _warnings.Count > 0 ? string.Join("\n", _warnings) : null);
        MarkClean(msg, warn: _warnings.Count > 0 || _catalogError != null || noted.Count > 0 || gameNote.Length > 0);
    }

    // ---- the modules "intro" (skipping the logos is a line in the game's Game.ini, GameStart.cs) and "othermods" (two
    //      lines in other mods' settings files, OtherMods.cs): files the app writes when it saves with the game closed
    private string _gameNote = "", _otherNote = "";

    private ModuleSettings? ModuleNamed(string name) => _mega?.Modules.FirstOrDefault(x => x.Name == name && x.Schema != null && x.Values.Count > 0);
    private bool LoadedByTheLoader(string name) => _mega != null && !_mega.SwitchedOff().Contains(name);

    /// <summary>Whether the saved settings say the logos are skipped; null when this megamod has no such module.</summary>
    private bool? LogosWanted()
    {
        var m = ModuleNamed(GameStart.Module);
        if (m == null || !m.Schema!.ByKey.ContainsKey("SkipLogos")) return null;
        if (_mega!.SwitchedOff().Contains(GameStart.Module)) return false;      // the loader does not load the module
        return m.Values.TryGetValue("Enabled", out var on) && on is true && m.Values.TryGetValue("SkipLogos", out var skip) && skip is true;
    }

    /// <summary>Looks at Game.ini and the other mods' files again and shows what there is to say on the modules' pages. Returns that ("" = nothing).</summary>
    private string LookAtFiles()
    {
        _gameNote = LogosWanted() is bool want ? GameStart.Note(want) : "";
        var other = ModuleNamed(OtherMods.Module);
        _otherNote = other != null ? OtherMods.Note(OtherMods.ModsFolder(_mega), other.Values, LoadedByTheLoader(OtherMods.Module)) : "";
        _generic.RefreshNotes();
        return string.Join(" ", new[] { _gameNote, _otherNote.Replace("\n", " ") }.Where(t => t.Length > 0));
    }

    /// <summary>The modules whose settings file the last Save wrote (the repopulate module's file is written by every Save).</summary>
    internal IReadOnlyList<string> LastWritten { get; private set; } = Array.Empty<string>();

    public bool SaveFile()
    {
        if (_grid.IsCurrentCellInEditMode && !_grid.EndEdit())
        {
            _status.Text = "Fix the highlighted value first.";
            return false;
        }
        ReadControls();
        string text = _s.ToLua();
        try
        {
            // verify that what we write reads back the same
            var check = Settings.FromText(text, new List<string>());
            if (check.Fingerprint() != _s.Fingerprint()) throw new InvalidOperationException("the written settings did not read back identically");

            SettingsFile.Write(_configPath, text);
        }
        catch (Exception ex)
        {
            if (!_testMode) XpMessageBox.Show(this, "Could not save config.lua:\n" + ex.Message, _title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            _status.Text = "Not saved: " + ex.Message;
            return false;
        }
        // the other modules: only the lines of changed values are rewritten (dev/SETTINGS.md section 2 of the mod)
        var written = new List<string>();
        var failed = new List<string>();
        _generic.Save(written, failed);
        LastWritten = written;
        // the logos at the start of the game: the line in Game.ini follows the saved settings (only with the game closed)
        var (gameText, gameWarn) = LogosWanted() is bool want ? GameStart.Apply(want) : ("", false);
        var otherModule = ModuleNamed(OtherMods.Module);
        var (otherText, otherWarn) = otherModule != null ? OtherMods.Apply(OtherMods.ModsFolder(_mega), otherModule.Values, LoadedByTheLoader(OtherMods.Module)) : ("", false);
        LookAtFiles();
        if (failed.Count > 0)
        {
            if (!_testMode) XpMessageBox.Show(this, "config.lua of the repopulate module was saved, but these settings could not be saved:\n" + string.Join("\n", failed), _title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            _status.Text = "Not saved: " + string.Join("; ", failed);
            return false;
        }
        RefreshControls();
        TakeBaseline();
        string when = DateTime.Now.ToString("HH:mm:ss", Inv);
        MarkClean((_s.ReloadCheckSeconds > 0
            ? $"Saved {when}. A running game picks this up within about {_s.ReloadCheckSeconds} seconds (UE4SS.log: \"settings reloaded\")."
            : $"Saved {when}. The game uses it the next time it starts.") + (written.Count > 0 ? " Also saved: " + string.Join(", ", written) + "." : "")
            + (gameText.Length > 0 ? " " + gameText : "") + (otherText.Length > 0 ? " " + otherText : ""),
            warn: _generic.ModulesWithNotes().Count > 0 || gameWarn || otherWarn);
        return true;
    }

    // =====================================================================
    // off-screen rendering and UI self test (--snapshot / --uitest)
    // =====================================================================
    // A window that is only shown to be drawn or tested never takes the keyboard from whatever the user is doing.
    protected override bool ShowWithoutActivation => _testMode;

    private void ShowOffscreen()
    {
        _testMode = true;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(-32000, -32000);
        ShowInTaskbar = false;
        Opacity = 0;
        Show();
        Application.DoEvents();
        _grid.CurrentCell = null;
        _grid.ClearSelection();
    }

    // --snapshot-screen: the window is shown at the top left of the screen and its picture is taken from the
    // screen - for systems on which a window cannot be drawn while it is off screen.
    private bool _fromScreen;

    public bool RenderSnapshots(string dir, bool fromScreen = false, bool smallest = false)
    {
        Directory.CreateDirectory(dir);
        if (smallest) Size = MinimumSize;       // (--smallest: the pictures show the window at its smallest size)
        if (fromScreen)
        {
            _testMode = true;
            _fromScreen = true;
            StartPosition = FormStartPosition.Manual;
            Location = Point.Empty;
            ShowInTaskbar = false;
            Show();
            Application.DoEvents();
            _grid.CurrentCell = null;
            _grid.ClearSelection();
        }
        else ShowOffscreen();
        var files = SaveTabImages(dir, "settings");
        // the list of Find, and the star of unsaved changes (nothing is saved: the window is closed without)
        try
        {
            int next = files.Count + 1;
            _find.Box.Text = "chance";
            Application.DoEvents();
            SaveWindowImage(Path.Combine(dir, $"settings-{next.ToString("00", Inv)}-find.png"));
            _find.Box.Text = "";
            HideFindList();
            var world = _nav.Tabs.FirstOrDefault(t => t.Kind == NavKind.Repopulate && t.Title == "Crime");
            if (world != null)
            {
                ShowCategory(world.Category, world);
                _crimeOn.Checked = !_crimeOn.Checked;
                Application.DoEvents();
                SaveWindowImage(Path.Combine(dir, $"settings-{(next + 1).ToString("00", Inv)}-unsaved.png"));
            }
        }
        catch { }
        _dirty = false;
        Close();
        return true;
    }

    // the window as a picture: drawn into a bitmap, or (--snapshot-screen) copied from the screen
    private Bitmap Grab()
    {
        var bmp = new Bitmap(Width, Height);
        if (_fromScreen)
        {
            Refresh();
            Application.DoEvents();
            Thread.Sleep(60);
            Application.DoEvents();
            using var g = Graphics.FromImage(bmp);
            g.CopyFromScreen(Location, Point.Empty, Size);
        }
        else DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
        return bmp;
    }

    // "Lock picking" -> "lock-picking"
    private static string Slug(string title)
    {
        var sb = new System.Text.StringBuilder();
        foreach (char c in title.ToLowerInvariant())
        {
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) sb.Append(c);
            else if (sb.Length > 0 && sb[^1] != '-') sb.Append('-');
        }
        string slug = sb.ToString().Trim('-');
        return slug.Length > 0 ? slug : "page";
    }

    /// <summary>
    /// One PNG of the window per tab, in the order of the pane: &lt;prefix&gt;-&lt;number&gt;-&lt;category&gt;-&lt;tab&gt;.png.
    /// A page made from schemas that is longer than the window gets one more image per window height
    /// ("-part2", ...). The window must be shown (off screen). Returns the files.
    /// </summary>
    internal List<string> SaveTabImages(string dir, string prefix)
    {
        var files = new List<string>();
        var before = _current;
        int number = 0;
        foreach (var tab in _nav.Tabs.ToList())
        {
            number++;
            ShowCategory(tab.Category, tab);
            Application.DoEvents();
            var scroll = _generic.PageOf(tab)?.Scroll;
            string name = tab.Category.Title == tab.Title ? Slug(tab.Title) : Slug(tab.Category.Title) + "-" + Slug(tab.Title);
            int parts = 1;
            if (scroll != null)
            {
                scroll.Arrange();
                if (scroll.Scrolls) parts = Math.Clamp((int)Math.Ceiling(scroll.ContentHeight / (double)Math.Max(1, scroll.ClientSize.Height)), 1, 8);
            }
            for (int part = 1; part <= parts; part++)
            {
                if (scroll != null)
                {
                    scroll.ScrollTo((part - 1) * scroll.ClientSize.Height);
                    Application.DoEvents();
                }
                using var bmp = Grab();
                string file = Path.Combine(dir, $"{prefix}-{number.ToString("00", Inv)}-{name}{(part > 1 ? "-part" + part.ToString(Inv) : "")}.png");
                bmp.Save(file, System.Drawing.Imaging.ImageFormat.Png);
                files.Add(file);
            }
            scroll?.ScrollTo(0);
        }
        if (before != null) ShowCategory(before.Category, before);
        return files;
    }

    // ---- what the UI self test (SelfTest.RunUi) reaches for
    internal SchemaPages Generic => _generic;
    internal string StatusText => _status.Text;
    /// <summary>The strip with the mass changes of the repopulate pages is shown (it belongs to the category World).</summary>
    internal bool ScaleShown => _scaleShown && _scaleControls.Where(c => c is not Label).All(c => c.Enabled);
    internal NavModel Nav => _nav;
    internal XpTaskPane Pane => _pane;
    /// <summary>The tab shown, as "Category/Tab".</summary>
    internal string CurrentPage => _current?.Key ?? "";
    /// <summary>The categories of the pane that carry the star of unsaved changes.</summary>
    internal List<string> MarkedCategories => _entryOf.Where(x => x.Value.Marked).Select(x => x.Key.Title).ToList();
    /// <summary>The link "Defaults for this page" of the pane can be pressed.</summary>
    internal bool PageDefaultsEnabled => _taskDefaults != null && _taskDefaults.Enabled;
    internal void PressPageDefaults() { if (_taskDefaults != null) _pane.Activate(_taskDefaults); }
    /// <summary>The switches of the first page with the switch each stands for.</summary>
    internal IReadOnlyList<(XpCheckBox Here, XpCheckBox There)> OverviewSwitches => _overviewSwitches;
    internal string OverviewPresetText => _overviewPreset.Text;
    internal string DetailPresetText => _detailPreset?.Text ?? "";
    /// <summary>Types into the Find box and returns the lines of the list ("name   -   Category > Tab").</summary>
    internal List<string> FindForTest(string text)
    {
        _find.Box.Text = text;
        Application.DoEvents();
        return _findList.Visible ? _findList.Entries.Select(e => e.Shown).ToList() : new List<string>();
    }
    internal int FindCount => _findList.Visible ? _findList.Total : 0;
    internal bool FindListShown => _findList.Visible;
    /// <summary>Goes to a line of the Find list as Enter does; returns the control gone to (null: a tab).</summary>
    internal Control? GoToFound(int line)
    {
        _findList.Select(line);
        if (_findList.Selected is not { } entry) throw new InvalidOperationException("the Find list has no line " + line);
        GoTo(entry);
        Application.DoEvents();
        return _lastFound?.Target;
    }
    internal string FindText => _find.Box.Text;
    /// <summary>The box can be used, and its button exactly while a preset is picked in it.</summary>
    internal bool PresetEnabled => _topBar.Enabled && _preset.Enabled && _presetApply.Enabled == (_preset.SelectedIndex > 0);
    internal bool PresetApplyEnabled => _presetApply.Enabled;
    internal void ApplyPresetForTest(int tier) => ApplyPreset(tier - 1);
    /// <summary>Picks a line of the box the way the user does (0 = own settings, 1 to 5 = that preset) and presses its button.</summary>
    internal void PickPresetForTest(int line) { _preset.SelectedIndex = line; Application.DoEvents(); }
    internal void PressApplyPreset() => _presetApply.PerformClick();
    /// <summary>The lines of the box that carry "- in use" (0 = own settings, 1 to 5 = that preset): exactly one.</summary>
    internal List<int> PresetMarks => Enumerable.Range(0, _preset.Items.Count).Where(i => (_preset.Items[i] as string ?? "").EndsWith(InUse, StringComparison.Ordinal)).ToList();
    /// <summary>The line the box marks as in use (0 = own settings, 1 to 5 = that preset), or -1 when it is not exactly one.</summary>
    internal int PresetMarked => PresetMarks.Count == 1 ? PresetMarks[0] : -1;
    /// <summary>The line the box stands on (0 = own settings, 1 to 5 = that preset).</summary>
    internal int PresetSelected => _preset.SelectedIndex;
    internal string PresetText => _preset.SelectedItem as string ?? "";
    /// <summary>One PNG of the window as it is.</summary>
    internal string SaveWindowImage(string file)
    {
        Application.DoEvents();
        using var bmp = Grab();
        bmp.Save(file, System.Drawing.Imaging.ImageFormat.Png);
        return file;
    }
    /// <summary>The repopulate settings as the pages show them now.</summary>
    internal Settings SettingsForTest() { ReadControls(); return _s.Clone(); }
    /// <summary>Gives a species settings of its own, the way it is done in the list of the Creatures page.</summary>
    internal void OwnSettingsForTest(string unique, string chance, string hours)
    {
        var row = RowOf(unique);
        row.Cells["own"].Value = true;
        row.Cells["chance"].Value = chance;
        row.Cells["hours"].Value = hours;
    }
    /// <summary>The tabs as "Category/Tab", in the order of the pane.</summary>
    internal List<string> PageTitles => _nav.Tabs.Select(t => t.Key).ToList();
    internal void ShowForTest() => ShowOffscreen();
    internal void PressDefaults() => _defaults.PerformClick();
    internal void PressRevert() => _revert.PerformClick();
    internal string TipOf(Control control) => _tip.GetToolTip(control) ?? "";
    /// <summary>What the window does when it comes to the front: files changed outside the app are read again.</summary>
    internal void ComeToFront() => OnActivated(EventArgs.Empty);

    private DataGridViewRow RowOf(string unique) =>
        _grid.Rows.Cast<DataGridViewRow>().First(r => r.Tag is SpeciesInfo sp && sp.Unique == unique);

    /// <summary>Shows a tab, named "Category/Tab" (the five repopulate pages also by their title alone).</summary>
    internal void SelectPage(string key)
    {
        var tab = _nav.Find(key) ?? _nav.Tabs.FirstOrDefault(t => t.Kind == NavKind.Repopulate && t.Title == key)
            ?? throw new InvalidOperationException("there is no page \"" + key + "\"");
        ShowCategory(tab.Category, tab);
        Application.DoEvents();
    }

    /// <summary>Chooses a category in the pane, as a click on it does.</summary>
    internal void ChooseCategory(string title)
    {
        var entry = _entryOf.FirstOrDefault(x => x.Key.Title == title).Value ?? throw new InvalidOperationException("there is no category \"" + title + "\"");
        _pane.Activate(entry);
        Application.DoEvents();
    }

    internal static IEnumerable<Control> Descendants(Control root)
    {
        foreach (Control c in root.Controls)
        {
            yield return c;
            foreach (var d in Descendants(c)) yield return d;
        }
    }

    /// <summary>Drives the real controls and saves; the caller checks the files.</summary>
    public void RunUiScript(List<string> log)
    {
        ShowOffscreen();
        log.Add("pages: " + _nav.Describe());
        log.Add($"title at start: \"{Text}\"");
        // group values through the number boxes
        _nChance.Value = 50;
        _eHours.Value = 36;
        // a species with its own settings, one switched off, one made elite
        var wolf = RowOf("Wolf");
        wolf.Cells["own"].Value = true;
        wolf.Cells["chance"].Value = "60";
        wolf.Cells["hours"].Value = "12";
        RowOf("Meatbug").Cells["on"].Value = false;
        RowOf("Snapper").Cells["elite"].Value = true;
        RowOf("Swampshark").Cells["elite"].Value = false;
        _corpses.Checked = false;
        _retroDays.Value = 5;
        _prefixes.Box.Text = "OC_, NC_";
        // crime: kinds are locked while the system is on; switch it off, keep weapons counting
        bool lockedWhileOn = !_crimeTheft.Enabled && !_crimeWeapons.Enabled && !_crimeForget.Enabled;
        _crimeOn.Checked = false;
        bool freeWhileOff = _crimeTheft.Enabled && _crimeTresp.Enabled && _crimeWeapons.Enabled && _crimeForget.Enabled;
        _crimeWeapons.Checked = false;
        log.Add($"crime tab: kinds locked while on = {lockedWhileOn}, editable while off = {freeWhileOff}, state text = \"{_crimeState.Text}\"");
        log.Add("edits made: normal 50 %, elite every 36 h, Wolf 60 %/12 h, Meatbug off, Snapper elite, Swampshark normal, corpses kept, retro 5 days, prefixes OC_/NC_, crime off except weapons");
        log.Add($"title before save 1: \"{Text}\"");
        if (!SaveFile()) { log.Add("save 1 failed: " + _status.Text); return; }
        log.Add("save 1: " + _status.Text);
        log.Add($"title after save 1: \"{Text}\"");
        // mass changes: chances x2 (capped at 100 %), timers x50 %
        _scaleChance.Value = 200;
        ScaleChances((double)_scaleChance.Value / 100);
        _scaleTime.Value = 50;
        ScaleTimers((double)_scaleTime.Value / 100);
        if (!SaveFile()) { log.Add("save 2 failed: " + _status.Text); return; }
        log.Add("save 2: " + _status.Text);
        Close();
    }

    /// <summary>Second pass of the UI test, in the layout of the separate mod (no megamod around the file): no pages of other modules.</summary>
    public void RunUiScriptStandalone(List<string> log)
    {
        ShowOffscreen();
        log.Add($"standalone: pages: {_nav.Describe()}; title at start: \"{Text}\"");
        _corpses.Checked = !_corpses.Checked;
        log.Add($"standalone: title after an edit: \"{Text}\"");
        if (!SaveFile()) { log.Add("standalone: save failed: " + _status.Text); return; }
        log.Add($"standalone: saved, title: \"{Text}\", status: {_status.Text}");
        Close();
    }
}

// The app's icon with all its sizes (the title bar takes the 16-pixel picture, the task bar a larger one). It is in
// the exe twice: as the exe's own icon, which Explorer and shortcuts show, and as a resource for the window.
internal static class AppIcon
{
    public static Icon? Load()
    {
        try
        {
            using var s = typeof(AppIcon).Assembly.GetManifestResourceStream("AppIcon");
            if (s != null) return new Icon(s);
        }
        catch { }
        try { return Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { return null; }
    }
}
