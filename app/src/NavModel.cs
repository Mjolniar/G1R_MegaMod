using System.Globalization;

namespace G1RRepopulateSettings;

/// <summary>
/// The modules whose settings the app describes itself: a module that has no schema.lua and reads
/// its config.lua on its own. Today that is the module "markers" (the pins on the map screens).
/// The description (MapPinsSchema.lua, in the form of a schema.lua) and the module's shipped
/// config.lua (MapPinsConfig.lua) are part of the app. A module that brings a schema.lua of its
/// own is always shown from that.
/// </summary>
internal static class AppSchemas
{
    public const string Markers = "markers";

    /// <summary>An embedded text file of the app as byte text.</summary>
    public static string Resource(string name)
    {
        using var raw = typeof(AppSchemas).Assembly.GetManifestResourceStream(name)
            ?? throw new InvalidOperationException("this build has no " + name);
        using var buffer = new MemoryStream();
        raw.CopyTo(buffer);
        return ByteText.FromBytes(buffer.ToArray());
    }

    public static string MarkersSchema => Resource("MapPinsSchema");
    public static string MarkersDefault => Resource("MapPinsConfig");

    /// <summary>The module in this folder when it is one the app describes itself (its Scripts folder is there), else null. Never throws.</summary>
    public static ModuleSettings? For(string moduleName, string scriptsFolder)
    {
        try
        {
            if (!string.Equals(moduleName, Markers, StringComparison.OrdinalIgnoreCase) || !Directory.Exists(scriptsFolder)) return null;
            return new ModuleSettings(moduleName, scriptsFolder, MarkersSchema, MarkersDefault);
        }
        catch { return null; }
    }
}

internal enum NavKind
{
    /// <summary>The first page: one line per part of the mod.</summary>
    Overview,
    /// <summary>One of the five hand-written pages of the repopulate module.</summary>
    Repopulate,
    /// <summary>Groups of settings from the modules' schemas.</summary>
    Schema,
    /// <summary>One sentence about a module whose schema cannot be used.</summary>
    Problem,
}

/// <summary>One tab of the window.</summary>
internal sealed class NavTab
{
    public NavCategory Category = null!;
    public string Title = "";
    public NavKind Kind;
    /// <summary>Kind Problem: why the settings of a module cannot be shown.</summary>
    public string? Problem;
    /// <summary>The modules with something on this tab, by name.</summary>
    public readonly List<ModuleSettings> Modules = new();
    /// <summary>
    /// The tab from top to bottom: a group with the title it is shown under, or (Group = null) the notes of a
    /// module - they stand below the last of that module's groups on the tab that is the module's own.
    /// </summary>
    public readonly List<(ModuleSettings Module, SchemaGroup? Group, string Title)> Rows = new();
    public double Order = 100;      // (tabs the table does not name: by this, then by title)

    /// <summary>"Combat/Fire spells": names the tab in tests, images and messages.</summary>
    public string Key => Category.Title + "/" + Title;
    /// <summary>"Combat > Fire spells", for the screen.</summary>
    public string Path => Category.Title == Title ? Title : Category.Title + " > " + Title;
    public IEnumerable<(ModuleSettings Module, SchemaGroup Group, string Title)> Groups => Rows.Where(r => r.Group != null).Select(r => (r.Module, r.Group!, r.Title));
}

/// <summary>One entry of the pane on the left: a set of tabs.</summary>
internal sealed class NavCategory
{
    public string Title = "";
    public readonly List<NavTab> Tabs = new();
    public double Order = 100;      // (categories the table does not name: by this, then by title)
    public bool Known;              // named by the table
}

/// <summary>
/// How the settings are laid out in the window: categories (the pane on the left), each with its tabs.
///
/// The megamod's schemas name one page per module, or one for several ("Combat" for regeneration,
/// magic and melee - 110 settings). The table below sorts the groups of the known modules into
/// categories and tabs of a size that can be read; the title of a group loses the prefix it only had
/// because several modules shared a page ("Magic: fire spells" is "Fire spells" on the tab of that
/// name). Nothing can get lost: a group the table does not name goes to the tab that is its
/// module's own, and a module the table does not know gets what its schema asks for - the tab of the
/// known module whose page it names, a tab of its own in the category it names, or a category of
/// its own.
/// </summary>
internal sealed class NavModel
{
    public const string Overview = "Overview", World = "World";
    public static readonly string[] RepopulateTabs = { "Creatures", "Herbs and items", "Containers", "Crime", "Advanced" };

    /// <summary>The categories the table names, in the order of the pane.</summary>
    public static readonly string[] KnownCategories = { Overview, World, "Combat", "Resources", "Hero", "Time", "Map", "Interface", "Other mods" };

    /// <summary>A module the table knows: its category, the tab that is its own, what it is called on the overview, and where its groups go.</summary>
    public sealed class Place
    {
        public string Module = "", Category = "", Tab = "", Part = "";
        /// <summary>The tabs of this module in their order (its own first unless listed otherwise).</summary>
        public string[] Tabs = Array.Empty<string>();
        /// <summary>Group title as the schema has it -> (tab, title shown).</summary>
        public Dictionary<string, (string Tab, string Title)> Groups = new(StringComparer.Ordinal);
    }

    private static Place P(string module, string category, string tab, string part, string[]? tabs, params (string Group, string Tab, string Title)[] groups)
    {
        var p = new Place { Module = module, Category = category, Tab = tab, Part = part, Tabs = tabs ?? new[] { tab } };
        foreach (var g in groups) p.Groups[g.Group] = (g.Tab, g.Title);
        return p;
    }

    /// <summary>The table. The order of the entries is the order of the tabs inside a category.</summary>
    public static readonly Place[] Known =
    {
        P("regen", "Combat", "Regeneration", "Regeneration of mana and health", null,
            ("Mana regeneration and health regeneration: on screen, log", "Regeneration", "On screen, log")),
        P("magic", "Combat", "Magic", "Magic balancing", new[] { "Magic", "Fire spells", "Ice spells", "Energy spells", "Wind spells", "Circles" },
            ("Magic: all spells", "Magic", "All spells"),
            ("Magic: on screen, log", "Magic", "On screen, log"),
            ("Magic: fire spells", "Fire spells", "Fire spells"),
            ("Magic: ice spells", "Ice spells", "Ice spells"),
            ("Magic: energy spells", "Energy spells", "Energy spells"),
            ("Magic: wind spells", "Wind spells", "Wind spells"),
            ("Magic: fire bolt and ice bolt by the caster's circle", "Circles", "Fire bolt and ice bolt by the caster's circle"),
            ("Magic: learning the circles", "Circles", "Learning the circles")),
        P("melee", "Combat", "Melee", "Melee clean-ups", null,
            ("Melee: clean-ups", "Melee", "Clean-ups"),
            ("Melee: on screen", "Melee", "On screen")),
        P("mining", "Resources", "Mining", "Mining rework", null,
            ("Mining: ore per swing", "Mining", "Ore per swing"),
            ("Mining: how long a vein lasts", "Mining", "How long a vein lasts"),
            ("Mining: on screen and in the log", "Mining", "On screen and in the log")),
        P("xp", "Hero", "Experience", "Experience multiplier", null),
        P("locks", "Hero", "Lock picking", "Lock picking by skill", null),
        P("mount", "Hero", "Mount", "The scavenger you ride", null),
        P("movement", "Hero", "Movement", "Walking, swimming and riding speed", null),
        P("wait", "Time", "Waiting", "Skipping time", new[] { "Waiting", "Rules" },
            ("When not to wait", "Rules", "When not to wait"),
            ("On screen", "Rules", "On screen"),
            ("Log", "Rules", "Log")),
        P(AppSchemas.Markers, "Map", "Map pins", "Map pins", new[] { "Map pins", "People", "Colour key", "Advanced" },
            ("Who is shown", "People", "Who is shown"),
            ("People standing together (world map)", "People", "People standing together (world map)"),
            ("Colour key", "Colour key", "Colour key"),
            ("Advanced", "Advanced", "Advanced")),
        P("general", "Interface", "Notes on screen", "Notes on screen", null),
        P("intro", "Interface", "Game start", "Logos and the film of a new game", null),
        P("keys", "Interface", "Key list", "The list of your keys", null),
        P("timers", "Interface", "Effect timers", "How long effects on you last", null),
        P("othermods", "Other mods", "Other mods", "Two distances of other mods", null),
    };

    public static Place? PlaceOf(string module) => Array.Find(Known, p => string.Equals(p.Module, module, StringComparison.OrdinalIgnoreCase));

    public readonly List<NavCategory> Categories = new();
    public IEnumerable<NavTab> Tabs => Categories.SelectMany(c => c.Tabs);
    public NavTab? Find(string key) => Tabs.FirstOrDefault(t => t.Key == key);

    /// <summary>The layout in one line: "Overview: Overview | World: Creatures, Herbs and items, ... | Combat: Regeneration, ...".</summary>
    public string Describe() => string.Join(" | ", Categories.Select(c => c.Title + ": " + string.Join(", ", c.Tabs.Select(t => t.Title))));

    /// <summary>The modules with settings on the tabs, in the order of the tabs (the order they are saved in).</summary>
    public List<ModuleSettings> ShownModules()
    {
        var list = new List<ModuleSettings>();
        foreach (var t in Tabs)
            if (t.Kind == NavKind.Schema)
                foreach (var m in t.Rows.Select(r => r.Module))
                    if (m.Schema != null && !list.Contains(m)) list.Add(m);
        return list;
    }

    /// <summary>How many settings a tab shows.</summary>
    public static int SettingsOn(NavTab tab) => tab.Groups.Sum(g => g.Group.Items.Count(i => i.Shown));

    /// <summary>
    /// What is wrong with the layout for this megamod (nothing, if the code above is right): a group of shown
    /// settings that is on no tab or on two, a tab or a category with nothing on it, notes of a module that stand
    /// nowhere or twice, a module whose schema cannot be used without the sentence that says so, two tabs of one name.
    /// </summary>
    public List<string> Problems(MegaMod mega)
    {
        var problems = new List<string>();
        var tabs = Tabs.ToList();
        foreach (var m in mega.Modules)
        {
            if (m.Schema == null)
            {
                if (!tabs.Any(t => t.Kind == NavKind.Problem && t.Modules.Contains(m) && t.Problem != null && t.Problem.Contains(m.Name, StringComparison.Ordinal)))
                    problems.Add($"{m.Name}: no tab says that its settings cannot be shown");
                continue;
            }
            foreach (var g in m.Schema.Groups)
            {
                bool shows = g.Items.Any(i => i.Shown);
                int on = tabs.Sum(t => t.Rows.Count(r => r.Module == m && r.Group == g));
                if (on != (shows ? 1 : 0)) problems.Add($"{m.Name}: the group \"{g.Title}\" ({(shows ? "shown" : "nothing to show")}) is on {on} tab(s)");
            }
            int notes = tabs.Sum(t => t.Rows.Count(r => r.Module == m && r.Group == null));
            if (notes != (m.Schema.Notes.Count > 0 ? 1 : 0)) problems.Add($"{m.Name}: its notes stand on {notes} tab(s)");
            var home = HomeOf(m);
            bool shown = m.Schema.Groups.Any(g => g.Items.Any(i => i.Shown)) || m.Schema.Notes.Count > 0;
            if (shown && (home == null || !home.Modules.Contains(m))) problems.Add($"{m.Name}: it has no tab of its own");
            if (notes == 1 && home != null && !home.Rows.Any(r => r.Module == m && r.Group == null)) problems.Add($"{m.Name}: its notes are not on its own tab");
        }
        foreach (var t in tabs)
        {
            if (t.Kind == NavKind.Schema && t.Rows.Count == 0) problems.Add($"the tab {t.Key} has nothing on it");
            if (t.Kind == NavKind.Problem && string.IsNullOrEmpty(t.Problem)) problems.Add($"the tab {t.Key} does not say what is wrong");
            if (t.Kind == NavKind.Schema && t.Rows.Any(r => !t.Modules.Contains(r.Module))) problems.Add($"the tab {t.Key} does not name all its modules");
        }
        foreach (var c in Categories)
            if (c.Tabs.Count == 0) problems.Add($"the category {c.Title} has no tab");
        foreach (var twice in tabs.GroupBy(t => t.Key, StringComparer.Ordinal).Where(g => g.Count() > 1)) problems.Add($"two tabs are called {twice.Key}");
        foreach (var twice in Categories.GroupBy(c => c.Title, StringComparer.Ordinal).Where(g => g.Count() > 1)) problems.Add($"two categories are called {twice.Key}");
        return problems;
    }

    /// <summary>The tab that is a module's own (where its notes stand), or null when nothing of it is shown.</summary>
    public NavTab? HomeOf(ModuleSettings module) => _home.TryGetValue(module, out var tab) ? tab : null;
    private readonly Dictionary<ModuleSettings, NavTab> _home = new();

    private NavCategory Category(string title, double order)
    {
        var c = Categories.Find(x => string.Equals(x.Title, title, StringComparison.Ordinal));
        if (c == null)
        {
            c = new NavCategory { Title = title, Order = order, Known = Array.IndexOf(KnownCategories, title) >= 0 };
            Categories.Add(c);
        }
        c.Order = Math.Min(c.Order, order);
        return c;
    }

    private NavTab Tab(string category, string title, NavKind kind, double order)
    {
        var c = Category(category, order);
        var t = c.Tabs.Find(x => string.Equals(x.Title, title, StringComparison.Ordinal));
        if (t == null)
        {
            t = new NavTab { Category = c, Title = title, Kind = kind, Order = order };
            c.Tabs.Add(t);
        }
        t.Order = Math.Min(t.Order, order);
        return t;
    }

    // the title of the page a schema names, as the tabs of the first versions had it
    private static string PageOf(ModuleSettings m) =>
        m.Schema?.Page ?? (m.Schema?.ModuleRaw is string name && name.Trim().Length > 0 ? ByteText.ToUnicode(name) : m.Name);

    private static string Capital(string s) => s.Length == 0 ? s : char.ToUpper(s[0], CultureInfo.InvariantCulture) + s[1..];

    /// <summary>
    /// The layout for a megamod (null = the separate mod G1R_Repopulate: its five pages and nothing else).
    /// Never throws for any set of schemas.
    /// </summary>
    public static NavModel Build(MegaMod? mega)
    {
        var nav = new NavModel();
        if (mega != null) nav.Tab(Overview, Overview, NavKind.Overview, -2);
        foreach (string title in RepopulateTabs) nav.Tab(World, title, NavKind.Repopulate, -1);
        if (mega == null) return nav;

        // where a module's groups go: (category, own tab, group -> tab and title)
        var modules = mega.Modules.OrderBy(m => m.Name, StringComparer.Ordinal).ToList();
        var placed = new List<(ModuleSettings Module, string Category, string Own, Place? Place, double Order)>();
        foreach (var m in modules)
        {
            var place = PlaceOf(m.Name);
            double order = m.Schema?.PageOrder ?? 1000;
            if (place != null) { placed.Add((m, place.Category, place.Tab, place, order)); continue; }
            string page = PageOf(m);
            // a module the table does not know: the tab of the known module whose page it names ...
            var shared = Array.Find(Known, p => modules.Any(k => k.Schema != null && string.Equals(k.Name, p.Module, StringComparison.OrdinalIgnoreCase)
                && string.Equals(PageOf(k), page, StringComparison.Ordinal)) && Array.IndexOf(KnownCategories, page) < 0);
            if (m.Schema != null && shared != null) placed.Add((m, shared.Category, shared.Tab, null, order));
            // ... a tab of its own in the category it names ...
            else if (m.Schema != null && Array.IndexOf(KnownCategories, page) >= 0 && page != Overview && page != World)
                placed.Add((m, page, Capital(m.Schema.ModuleRaw is string raw && raw.Trim().Length > 0 ? ByteText.ToUnicode(raw) : m.Name), null, order));
            // ... or a category of its own (a module whose schema cannot be used: named after its folder, behind the others)
            else placed.Add((m, m.Schema != null ? page : m.Name, m.Schema != null ? page : m.Name, null, m.Schema != null ? order : 1000));
        }

        // the tabs of the known modules first, in the order of the table
        foreach (var place in Known)
        {
            var entry = placed.FirstOrDefault(x => x.Place == place);
            if (entry.Module?.Schema == null) continue;
            foreach (string tab in place.Tabs) nav.Tab(place.Category, tab, NavKind.Schema, -1);
        }

        var groups = new List<(NavTab Tab, ModuleSettings Module, SchemaGroup Group, string Title)>();
        foreach (var (m, category, own, place, order) in placed)
        {
            if (m.Schema == null)
            {
                var problem = nav.Tab(category, own, NavKind.Problem, order);
                if (problem.Kind != NavKind.Problem)
                {
                    // (the tab of that name shows other modules: the sentence gets a tab of its own)
                    problem = nav.Tab(category, own + " (" + m.Name + ")", NavKind.Problem, order);
                }
                problem.Problem = (problem.Problem != null ? problem.Problem + "\n" : "") + $"The settings of the module {m.Name} cannot be shown: {m.SchemaProblem}.";
                problem.Modules.Add(m);
                continue;
            }
            foreach (var g in m.Schema.Groups)
            {
                if (!g.Items.Any(i => i.Shown)) continue;
                string tab = own, title = g.Title;
                if (place != null && place.Groups.TryGetValue(g.Title, out var to)) { tab = to.Tab; title = to.Title; }
                var t = nav.Tab(category, tab, NavKind.Schema, order);
                if (t.Kind != NavKind.Schema) t = nav.Tab(category, tab + " (" + m.Name + ")", NavKind.Schema, order);
                groups.Add((t, m, g, title));
            }
        }

        // on a tab: the groups by Order, then module name, then order in the file; the notes of a module below the
        // last of its groups on the tab that is its own (the first tab with groups of it, if that one has none)
        foreach (var tab in nav.Tabs.ToList())
        {
            var sorted = groups.Where(x => x.Tab == tab).OrderBy(x => x.Group.Order).ThenBy(x => x.Module.Name, StringComparer.Ordinal).ThenBy(x => x.Group.Index).ToList();
            foreach (var x in sorted)
            {
                tab.Rows.Add((x.Module, x.Group, x.Title));
                if (!tab.Modules.Contains(x.Module)) tab.Modules.Add(x.Module);
            }
        }
        foreach (var (m, category, own, _, order) in placed)
        {
            if (m.Schema == null) continue;
            var home = nav.Tabs.FirstOrDefault(t => t.Kind == NavKind.Schema && t.Category.Title == category && t.Title == own && t.Modules.Contains(m))
                ?? nav.Tabs.FirstOrDefault(t => t.Kind == NavKind.Schema && t.Modules.Contains(m));
            if (home == null)
            {
                // a module with nothing to show but notes
                if (m.Schema.Notes.Count == 0) continue;
                home = nav.Tab(category, own, NavKind.Schema, order);
                if (home.Kind != NavKind.Schema) continue;
                home.Modules.Add(m);
            }
            nav._home[m] = home;
            if (m.Schema.Notes.Count == 0) continue;
            int last = home.Rows.FindLastIndex(r => r.Module == m);
            if (last < 0) home.Rows.Add((m, null, ""));
            else home.Rows.Insert(last + 1, (m, null, ""));
        }
        foreach (var tab in nav.Tabs) tab.Modules.Sort((a, b) => string.CompareOrdinal(a.Name, b.Name));

        // tabs and categories without anything on them are not shown; the order: the table's, then PageOrder, then name
        foreach (var c in nav.Categories)
        {
            c.Tabs.RemoveAll(t => t.Kind == NavKind.Schema && t.Rows.Count == 0);
            var known = c.Tabs.Where(t => t.Order < 0).ToList();
            var others = c.Tabs.Where(t => t.Order >= 0).OrderBy(t => t.Order).ThenBy(t => t.Title, StringComparer.Ordinal).ToList();
            c.Tabs.Clear();
            c.Tabs.AddRange(known);
            c.Tabs.AddRange(others);
        }
        nav.Categories.RemoveAll(c => c.Tabs.Count == 0);
        var named = KnownCategories.Select(title => nav.Categories.Find(c => c.Title == title)).Where(c => c != null).Select(c => c!).ToList();
        var rest = nav.Categories.Where(c => !named.Contains(c)).OrderBy(c => c.Order).ThenBy(c => c.Title, StringComparer.Ordinal).ToList();
        nav.Categories.Clear();
        nav.Categories.AddRange(named);
        nav.Categories.AddRange(rest);
        return nav;
    }
}
