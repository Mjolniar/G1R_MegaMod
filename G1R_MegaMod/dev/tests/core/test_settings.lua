-- ============================================================================
-- Offline tests of the settings service (Scripts/core/settings.lua): schema
-- checks, the text of config.lua, reading and changing it, the in-game menu
-- (the menu mod's shared variables).
--
--   lua5.4 test_settings.lua     (from any directory)
--
-- Every case loads the file afresh (it keeps its state in upvalues), with the
-- kit beside it as in the game. Needs a POSIX shell (mkdir, rm, chmod).
-- Last line: "core/settings tests finished: N ok, M failure(s)".
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("core-settings")
T.suite = "core/settings"
local check, section, has = T.check, T.section, T.has
local CORE = T.MOD .. "Scripts/core/"

-- A fresh service. options: noKit, noModRef, shared (initial shared variables).
local function fresh(options)
    options = options or {}
    local ue = T.Mock.new()
    ue:install()
    local c = { ue = ue, logs = {} }
    if not options.noModRef then
        c.mods = T.shared()
        for k, v in pairs(options.shared or {}) do c.mods.store[k] = v end
        rawset(_G, "ModRef", c.mods)
    end
    if not options.noKit then
        c.kit = dofile(CORE .. "kit.lua")
        rawset(_G, "G1R_KIT", c.kit)
    end
    c.S = dofile(CORE .. "settings.lua")
    function c.log(text) c.logs[#c.logs + 1] = text end
    function c.logged(plain)
        local n = 0
        for _, l in ipairs(c.logs) do if has(l, plain) then n = n + 1 end end
        return n
    end
    function c.ticks(n)
        for _ = 1, n or 1 do
            ue:advance(0.25)
            c.S.tick()
        end
    end
    return c
end
local function done(c)
    c.ue:uninstall()
    rawset(_G, "ModRef", nil)
    rawset(_G, "G1R_KIT", nil)
end
local caseNumber = 0
local function folder()
    caseNumber = caseNumber + 1
    local dir = T.TMP .. "/case" .. caseNumber .. "/"
    T.sh("mkdir -p " .. T.q(dir))
    return dir
end

local function schemaA()
    return {
        Module = "alpha", Page = "Combat", PageOrder = 10,
        Header = { "Alpha settings", "second line" },
        Groups = {
            { Title = "Main", Order = 20, Items = {
                { Key = "Enabled", Kind = "bool", Default = true, Label = "Switch it on", Comment = "false = off. More words here." },
                { Key = "Amount", Kind = "number", Default = 2.5, Min = 0, Max = 10, Step = 0.5, Decimals = 2, Label = "Amount", Unit = "times",
                  Needs = "Enabled", Comment = { "First line of the comment,", "second line." } },
                { Key = "Count", Kind = "number", Default = 3, Min = 1, Max = 9, Label = "Count" },
            } },
            { Title = "Look", Order = 10, Items = {
                { Key = "Style", Kind = "choice", Default = "b", Options = { "a", "b", "c" }, Label = "Style", Comment = "One of three." },
                { Key = "Name", Kind = "text", Default = "say \"hi\" \\ there", Label = "Name" },
                { Key = "Hotkey", Kind = "key", Default = "CTRL+Y", Label = "Key" },
                { Key = "Now", Kind = "action", Label = "Do it now", Comment = "Runs the thing." },
            } },
            { Title = "Advanced", Items = {
                { Key = "Secret", Kind = "number", Default = 7, Min = 0, Max = 100, Hidden = true },
            } },
        },
    }
end
local TEXT_A = table.concat({
    "-- ============================================================================",
    "-- Alpha settings",
    "-- second line",
    "-- ============================================================================",
    "local Config = {}",
    "",
    "-- ---- Main ----",
    "-- false = off. More words here.",
    "Config.Enabled = true",
    "-- First line of the comment,",
    "-- second line.",
    "Config.Amount = 2.5",
    "Config.Count = 3",
    "",
    "-- ---- Look ----",
    "-- One of three.",
    "Config.Style = \"b\"",
    "Config.Name = \"say \\\"hi\\\" \\\\ there\"",
    "Config.Hotkey = \"CTRL+Y\"",
    "",
    "return Config",
    "",
}, "\n")

-- ---------------------------------------------------------------------------
section("1. numbers as they are written into config.lua")
do
    local c = fresh()
    local n = c.S.numberText
    local cases = { { 3, 0, "3" }, { 2.5, 0, "3" }, { 2.4, 0, "2" }, { -1.5, 0, "-1" }, { 3, nil, "3" }, { 1, 2, "1.0" }, { 2.5, 2, "2.5" }, { 0.75, 2, "0.75" },
        { 2.126, 2, "2.13" }, { 10, 1, "10.0" }, { 100, 2, "100.0" }, { -0.001, 2, "0.0" }, { 0.5, 3, "0.5" }, { 1234.5678, 3, "1234.568" }, { -2.5, 1, "-2.5" } }
    local bad = {}
    for _, k in ipairs(cases) do
        local got = n(k[1], k[2])
        if got ~= k[3] then bad[#bad + 1] = ("%s with %s places gives %s, not %s"):format(k[1], tostring(k[2]), got, k[3]) end
    end
    check(#bad == 0, #cases .. " numbers: whole ones plain, others with at least one and at most the given places (" .. table.concat(bad, "; ") .. ")")
    check(select("#", n(1, 2)) == 1, "one value is returned")
    done(c)
end

-- ---------------------------------------------------------------------------
section("2. the schema is checked")
do
    local c = fresh()
    local function why(change)
        local s = schemaA()
        change(s)
        local items, reason = c.S.itemsOf(s)
        return items == nil and reason or "accepted"
    end
    local items, byKey, actions = c.S.itemsOf(schemaA())
    check(items ~= nil and #items == 7 and items[1].Key == "Enabled" and items[7].Key == "Secret" and byKey.Amount == items[2] and byKey.Now == nil and actions.Now ~= nil,
        "a good schema: seven items with a value in file order, by key, and the action apart")
    local cases = {
        { "no Groups", function(s) s.Groups = nil end, "the schema has no Groups" },
        { "a group without Items", function(s) s.Groups[2].Items = nil end, "group 2 has no Items" },
        { "an item without a key", function(s) s.Groups[1].Items[1].Key = nil end, "an item of group 1 has no usable Key" },
        { "a key with a space", function(s) s.Groups[1].Items[1].Key = "My Key" end, "an item of group 1 has no usable Key" },
        { "a key twice", function(s) s.Groups[2].Items[1].Key = "Amount" end, "the key Amount is used twice" },
        { "an action with the key of a value", function(s) s.Groups[2].Items[4].Key = "Count" end, "the key Count is used twice" },
        { "a value with the key of an action", function(s) table.insert(s.Groups[3].Items, { Key = "Now", Kind = "bool", Default = true }) end, "the key Now is used twice" },
        { "an unknown kind", function(s) s.Groups[1].Items[1].Kind = "slider" end, "Enabled: unknown Kind slider" },
        { "a switch with a number as default", function(s) s.Groups[1].Items[1].Default = 1 end, "Enabled: Default must be true or false" },
        { "a number without Min", function(s) s.Groups[1].Items[2].Min = nil end, "Amount: Default, Min and Max must be numbers with Min <= Default <= Max" },
        { "a number without Max", function(s) s.Groups[1].Items[2].Max = nil end, "Amount: Default, Min and Max must be numbers with Min <= Default <= Max" },
        { "a default above Max", function(s) s.Groups[1].Items[2].Default = 11 end, "Amount: Default, Min and Max must be numbers with Min <= Default <= Max" },
        { "a default below Min", function(s) s.Groups[1].Items[3].Default = 0 end, "Count: Default, Min and Max must be numbers with Min <= Default <= Max" },
        { "Min above Max", function(s) s.Groups[1].Items[3].Min = 10 end, "Count: Default, Min and Max must be numbers with Min <= Default <= Max" },
        { "a number with a text as default", function(s) s.Groups[1].Items[3].Default = "3" end, "Count: Default, Min and Max must be numbers with Min <= Default <= Max" },
        { "a choice without options", function(s) s.Groups[2].Items[1].Options = {} end, "Style: Options are missing" },
        { "a choice with a number as option", function(s) s.Groups[2].Items[1].Options = { "a", 2 } end, "Style: Options must be texts" },
        { "a choice whose default is no option", function(s) s.Groups[2].Items[1].Default = "z" end, "Style: Default is not one of the Options" },
        { "a text with a number as default", function(s) s.Groups[2].Items[2].Default = 5 end, "Name: Default must be a text" },
        { "a key in another spelling", function(s) s.Groups[2].Items[3].Default = "ctrl+y" end, "Hotkey: Default must be a key in its usual spelling (\"Y\", \"CTRL+Y\") or \"\"" },
        { "a key that is none", function(s) s.Groups[2].Items[3].Default = "CTRL+NOKEY" end, "Hotkey: Default must be a key in its usual spelling (\"Y\", \"CTRL+Y\") or \"\"" },
        { "Needs that is no text", function(s) s.Groups[1].Items[2].Needs = true end, "Amount: Needs must name a key" },
        { "Needs an unknown key", function(s) s.Groups[1].Items[2].Needs = "Nothing" end, "Amount: Needs names Nothing, which is not a yes/no item" },
        { "Needs a number", function(s) s.Groups[1].Items[2].Needs = "Count" end, "Amount: Needs names Count, which is not a yes/no item" },
        { "an action that needs an unknown key", function(s) s.Groups[2].Items[4].Needs = "Nothing" end, "Now: Needs names Nothing, which is not a yes/no item" },
        { "only actions", function(s) s.Groups = { { Items = { { Key = "Go", Kind = "action" } } } } end, "the schema has no items" },
        { "no key at all (\"\")", function(s) s.Groups[2].Items[3].Default = "" end, "accepted" },
        { "a default at Min", function(s) s.Groups[1].Items[2].Default = 0 end, "accepted" },
        { "a default at Max", function(s) s.Groups[1].Items[2].Default = 10 end, "accepted" },
        { "Min equal to Max", function(s) s.Groups[1].Items[3].Min, s.Groups[1].Items[3].Max = 3, 3 end, "accepted" },
        { "an action that needs a switch", function(s) s.Groups[2].Items[4].Needs = "Enabled" end, "accepted" },
    }
    local bad = {}
    for _, k in ipairs(cases) do
        local got = why(k[2])
        if got ~= k[3] then bad[#bad + 1] = k[1] .. ": " .. tostring(got) end
    end
    check(#bad == 0, #cases .. " schemas with one thing wrong each are refused with the reason (" .. table.concat(bad, "; ") .. ")")
    check(c.S.itemsOf(nil) == nil and c.S.itemsOf(5) == nil and select(2, c.S.itemsOf({})) == "the schema has no Groups", "nothing, a number, an empty table: refused")
    done(c)
end

-- ---------------------------------------------------------------------------
section("3. the default config.lua")
do
    local c = fresh()
    local text = c.S.defaultText(schemaA())
    check(text == TEXT_A, "the text for the sample schema is exactly the documented layout")
    if text ~= TEXT_A then io.write(tostring(text), "\n") end
    check(not has(text, "Secret") and not has(text, "Advanced") and not has(text, "Now"), "hidden items and their group title are left out, actions too")
    local chunk = load(text, "=config", "t", {})
    local values = chunk and chunk() or {}
    check(values.Enabled == true and values.Amount == 2.5 and values.Count == 3 and values.Style == "b" and values.Name == "say \"hi\" \\ there" and values.Hotkey == "CTRL+Y",
        "read back as Lua it gives the defaults (quotes and backslashes in a text survive)")
    local s = schemaA()
    s.Header = nil
    check(has(c.S.defaultText(s), "-- Settings of the module alpha\n"), "without a Header the top says which module the file belongs to")
    s = schemaA()
    s.Groups[1].Title = nil
    check(not has(c.S.defaultText(s), "-- ----  ----") and has(c.S.defaultText(s), "local Config = {}\n\n-- false = off."), "a group without a title has no title line")
    s = schemaA()
    s.Groups[2].Items[2].Default = "line\nbreak\ttab"
    check(has(c.S.defaultText(s), 'Config.Name = "line break tab"\n'), "control characters in a text become spaces: the value stays on its line")
    local nothing, reason = c.S.defaultText({ Groups = {} })
    check(nothing == nil and reason == "the schema has no items", "a schema that is not usable gives no text but the reason")
    done(c)
end

-- ---------------------------------------------------------------------------
section("4. values are checked against the schema")
do
    local c = fresh()
    local items, byKey = c.S.itemsOf(schemaA())
    local checked = c.S._test.checked
    local function is(key, given, value, fixed)
        local v, f = checked(byKey[key], given)
        return v == value and f == fixed and math.type(v) == math.type(value)
    end
    check(is("Enabled", true, true, false) and is("Enabled", false, false, false) and is("Enabled", "yes", true, true) and is("Enabled", 0, true, true) and is("Enabled", nil, true, false),
        "a switch: true and false as they are; anything else gives the default and counts as fixed; nothing gives the default without complaint")
    check(is("Amount", 4, 4.0, false) and is("Amount", 4.25, 4.25, false) and is("Amount", 0, 0.0, false) and is("Amount", 10, 10.0, false) and is("Amount", 11, 10.0, true)
        and is("Amount", 10.01, 10.0, true) and is("Amount", -1, 0.0, true), "a number in range stays; outside it is pulled to the nearer end and counts as fixed")
    check(select(1, checked(byKey.Amount, 2.126)) == 2.13 and select(2, checked(byKey.Amount, 2.126)) == true and select(1, checked(byKey.Amount, 2.5)) == 2.5
        and select(2, checked(byKey.Amount, 2.5)) == false, "more places than Decimals are rounded (2.126 -> 2.13)")
    local tenth = { Key = "Tenth", Kind = "number", Default = 1, Min = 0, Max = 10, Decimals = 1 }
    check(select(1, checked(tenth, 2.46)) == 2.5 and select(1, checked(tenth, 2.44)) == 2.4 and select(1, checked(tenth, 7)) == 7, "one place after the point: 2.46 -> 2.5")
    check(is("Count", 3, 3, false) and is("Count", 3.4, 3, true) and is("Count", 3.5, 4, true) and is("Count", 99, 9, true) and is("Count", 4.0, 4, false),
        "a whole-number item: rounded half up, and a whole number of Lua's integer kind comes out (UE4SS wants that for intervals)")
    check(is("Count", "5", 5, true) and is("Count", "five", 3, true) and is("Count", 0 / 0, 3, true) and is("Count", nil, 3, false) and is("Count", math.huge, 9, true) and is("Count", {}, 3, true),
        "a number as text is taken as the number; a word, not-a-number or a table give the default; infinity the upper end")
    check(is("Style", "a", "a", false) and is("Style", "c", "c", false) and is("Style", "d", "b", true) and is("Style", 1, "b", true) and is("Style", nil, "b", false),
        "a choice: one of the options, else the default")
    check(is("Name", "x", "x", false) and is("Name", "", "", false) and is("Name", 5, "say \"hi\" \\ there", true) and is("Name", nil, "say \"hi\" \\ there", false), "a text: any text, else the default")
    check(is("Hotkey", "CTRL+Y", "CTRL+Y", false) and is("Hotkey", "ctrl + y", "CTRL+Y", false) and is("Hotkey", "strg+shift+f5", "CTRL+SHIFT+F5", false)
        and is("Hotkey", "", "", false) and is("Hotkey", "delete", "DEL", false), "a key: any spelling of a key becomes the usual one, without complaint; \"\" is no key")
    check(is("Hotkey", "CTRL+NOKEY", "CTRL+Y", true) and is("Hotkey", "CTRL", "CTRL+Y", true) and is("Hotkey", "A+B", "CTRL+Y", true) and is("Hotkey", 5, "CTRL+Y", true)
        and is("Hotkey", nil, "CTRL+Y", false), "what names no key gives the default")
    done(c)
    c = fresh({ noKit = true })
    check(c.S.keyText("ctrl + y") == "CTRL+Y" and c.S.keyText("") == "" and c.S.keyText("a;b") == nil and c.S.keyText(5) == nil,
        "without the kit only the spelling of a key is tidied (upper case, no spaces)")
    done(c)
end

-- ---------------------------------------------------------------------------
section("5. changing one line of a config.lua")
do
    local c = fresh()
    local patch = c.S.patch
    check(patch("local Config = {}\nConfig.A = 1\nConfig.B = 2\nreturn Config\n", "A", "5") == "local Config = {}\nConfig.A = 5\nConfig.B = 2\nreturn Config\n", "the line of the key gets the new value, nothing else changes")
    check(patch("Config.A = 1\nreturn Config\n", "A", "5") == "Config.A = 5\nreturn Config\n", "also when it is the first line of the file")
    check(patch("\nConfig.A = 1\nreturn Config\n", "A", "5") == "\nConfig.A = 5\nreturn Config\n", "or the second, after an empty first line")
    check(patch("local Config = {}\n\t  Config.A   =   1   -- old\nreturn Config\n", "A", "5") == "local Config = {}\n\t  Config.A = 5\nreturn Config\n", "the indentation stays, the rest of the line goes")
    check(patch("x\r\nConfig.A = 1\r\nreturn Config\r\n", "A", "5") == "x\r\nConfig.A = 5\r\nreturn Config\r\n", "CRLF line ends stay")
    check(patch("-- Config.A = 1\nConfig.A = 2\nreturn Config\n", "A", "5") == "-- Config.A = 1\nConfig.A = 5\nreturn Config\n", "a commented line is not the key's line")
    check(patch("Config.A = 1\nConfig.B = 2\nConfig.A = 3\nreturn Config\n", "A", "5") == "Config.A = 1\nConfig.B = 2\nConfig.A = 5\nreturn Config\n", "a key that stands twice: the last line is changed (the one Lua goes by)")
    check(patch("Config.AB = 1\nConfig.BA = 2\nreturn Config\n", "A", "5") == "Config.AB = 1\nConfig.BA = 2\nConfig.A = 5\nreturn Config\n", "a longer key that starts or ends the same is another key; a missing line is put in front of return Config")
    check(patch("x = Config.A == 1\nreturn Config\n", "A", "5") == "x = Config.A == 1\nConfig.A = 5\nreturn Config\n", "a line that only mentions the key is not its line")
    check(patch("local Config = {}\r\nreturn Config\r\n", "A", "5") == "local Config = {}\r\nConfig.A = 5\r\nreturn Config\r\n", "an inserted line gets the file's line ending")
    check(patch("local Config = {}\nreturn Config", "A", "5") == "local Config = {}\nConfig.A = 5\nreturn Config", "a file without a line break at its end")
    check(patch("local Config = {}\n  return   Config  \n\n\n", "A", "5") == "local Config = {}\nConfig.A = 5\n  return   Config  \n\n\n", "return Config with spaces and empty lines after it")
    check(patch("return Config\nlocal x\nreturn Config\n", "A", "5") == "return Config\nlocal x\nConfig.A = 5\nreturn Config\n", "in front of the last return Config")
    check(patch("Config.B = 1\n\n\nreturn Config\n", "A", "5") == "Config.B = 1\nConfig.A = 5\n\n\nreturn Config\n"
        and patch("Config.B = 1\r\n  \r\nreturn Config\r\n", "A", "5") == "Config.B = 1\r\nConfig.A = 5\r\n  \r\nreturn Config\r\n",
        "empty lines in front of return Config stay in front of it: the new line joins the lines above")
    check(patch("\n\nreturn Config\n", "A", "5") == "Config.A = 5\n\n\nreturn Config\n", "a file that is nothing but return Config")
    check(patch("local Config = {}\n", "A", "5") == "local Config = {}\nConfig.A = 5\n" and patch("local Config = {}", "A", "5") == "local Config = {}\nConfig.A = 5\n" and patch("", "A", "5") == "Config.A = 5\n",
        "without return Config the line is added at the end")
    check(patch("Config.A = \"x\"\nreturn Config\n", "A", "\"a%1b\"") == "Config.A = \"a%1b\"\nreturn Config\n", "a value with a percent sign is written as it is")
    check(select("#", patch("Config.A = 1\n", "A", "5")) == 1, "one value is returned")
    done(c)
end

-- ---------------------------------------------------------------------------
section("6. opening a module's settings")
do
    local c = fresh()
    local dir = folder()
    local o, why = c.S.open({ module = "alpha", dir = dir, log = c.log })
    check(o == nil and has(why, "schema.lua could not be read"), "no schema.lua: nothing is opened, the reason is given")
    T.write(dir .. "schema.lua", "local t = nil\nreturn t.x")
    o, why = c.S.open({ module = "alpha", dir = dir, log = c.log })
    check(o == nil and has(why, "schema.lua raised") and has(why, "nil value"), "a schema.lua that raises: the same")
    T.write(dir .. "schema.lua", "return { Groups = {} }")
    o, why = c.S.open({ module = "alpha", dir = dir, log = c.log })
    check(o == nil and why == "schema.lua: the schema has no items", "a schema.lua that is not usable: the reason names the schema")
    T.write(dir .. "schema.lua", "os.exit(1)")
    o, why = c.S.open({ module = "alpha", dir = dir, log = c.log })
    check(o == nil and has(why, "schema.lua raised"), "schema.lua runs without Lua's libraries")
    check(c.S.open(nil) == nil and c.S.open({}) == nil and select(2, c.S.open({ dir = 5 })) == "Settings.open needs a table with dir", "called without a folder: refused")

    -- the schema given as a table; no config.lua yet
    o = c.S.open({ module = "alpha", dir = dir, schema = schemaA(), log = c.log })
    check(o ~= nil and T.read(dir .. "config.lua") == TEXT_A and c.logged("config.lua was not there: written with the default settings") == 1, "no config.lua: the default file is written, said in the log")
    check(o.values.Enabled == true and o.values.Amount == 2.5 and o.values.Count == 3 and o.values.Style == "b" and o.values.Hotkey == "CTRL+Y" and o.values.Secret == 7 and o.values.Now == nil
        and o.module == "alpha", "the values are the defaults, hidden ones included; an action has no value")
    done(c)

    -- a file with values, unknown keys, wrong kinds
    c = fresh()
    dir = folder()
    local text = "\239\187\191local Config = {}\nConfig.Enabled = false\nConfig.Amount = 99\nConfig.Count = \"x\"\nConfig.Style = \"c\"\nConfig.Other = 5\nConfig.Secret = 8\nConfig.Hotkey = \"shift+f5\"\nreturn Config\n"
    T.write(dir .. "config.lua", text)
    o = c.S.open({ module = "alpha", dir = dir, schema = schemaA(), log = c.log })
    check(o.values.Enabled == false and o.values.Amount == 10 and o.values.Count == 3 and o.values.Style == "c" and o.values.Secret == 8 and o.values.Other == nil and o.values.Hotkey == "SHIFT+F5",
        "a file (with a byte order mark): its values are taken, checked; a key the schema does not know is ignored")
    check(c.logged("config.lua: Amount = 99 is not usable; 10.0 is used") == 1 and c.logged("config.lua: Count = x is not usable; 3 is used") == 1 and #c.logs == 2,
        "what had to be changed is said in the log, once each; another spelling of a key is not")
    check(T.read(dir .. "config.lua") == text, "the file itself is not touched by reading it")
    done(c)

    c = fresh()
    dir = folder()
    T.write(dir .. "config.lua", "this is not lua\n")
    o = c.S.open({ module = "alpha", dir = dir, schema = schemaA(), log = c.log })
    check(o ~= nil and o.values.Amount == 2.5 and c.logged("config.lua has an error (") == 1 and T.read(dir .. "config.lua") == "this is not lua\n", "a broken file: the defaults are used, said in the log, the file is left alone")
    done(c)
    c = fresh()
    dir = folder()
    T.write(dir .. "config.lua", "return 5\n")
    o = c.S.open({ module = "alpha", dir = dir, schema = schemaA(), log = c.log })
    check(o.values.Amount == 2.5 and c.logged("config.lua did not return a table") == 1, "a file that returns no table: the same")
    done(c)
    c = fresh()
    dir = folder()
    T.write(dir .. "config.lua", "local Config = {}\nConfig.Amount = 2,5\nreturn Config\n")
    o = c.S.open({ module = "alpha", dir = dir, schema = schemaA(), log = c.log })
    check(o.values.Amount == 2 and c.logged("a number seems to be written with a comma (2,5); Lua reads that as 2 - write 2.5") == 1, "2,5: Lua reads 2; the log says what to write instead")
    done(c)

    -- no log function: the lines go to print with the mod's name
    c = fresh()
    dir = folder()
    c.S.init(function(text) c.logs[#c.logs + 1] = "PRINT " .. text end)
    o = c.S.open({ module = "alpha", dir = dir, schema = schemaA() })
    check(c.logs[1] == "PRINT [G1R_MegaMod] config.lua was not there: written with the default settings\n", "without a log function the lines go to the print function the loader gave")
    done(c)

    -- a folder that cannot be written
    c = fresh()
    dir = folder()
    o = c.S.open({ module = "alpha", dir = dir .. "missing/", schema = schemaA(), log = c.log })
    check(o ~= nil and o.values.Amount == 2.5 and c.logged("config.lua not found and could not be written; using the default settings") == 1, "a folder that cannot be written: the defaults are used, said in the log")
    done(c)
end

-- ---------------------------------------------------------------------------
section("7. the file changes while the game runs")
do
    local c = fresh()
    local dir = folder()
    local changes = {}
    local o = c.S.open({ module = "alpha", dir = dir, schema = schemaA(), log = c.log, onChange = function(values, keys, why)
        changes[#changes + 1] = { keys = table.concat(keys, ","), why = why, amount = values.Amount }
    end })
    local values = o.values
    local ok, why = o:reload()
    check(ok == false and why == "unchanged" and #changes == 0, "reload on an unchanged file: nothing happens")
    T.write(dir .. "config.lua", "local Config = {}\nConfig.Amount = 4\nConfig.Style = \"a\"\nreturn Config\n")
    c.ticks(19)
    check(#changes == 0, "the file is not looked at more often than every 5 seconds")
    c.ticks(1)
    check(#changes == 1 and changes[1].keys == "Amount,Style" and changes[1].why == "file" and changes[1].amount == 4 and values.Amount == 4 and o.values == values,
        "a changed file: the module is told which keys changed and why; the values table is the same table")
    c.ticks(40)
    check(#changes == 1, "an unchanged file is not reported again")
    T.write(dir .. "config.lua", "local Config = {}\nConfig.Amount = 4\nConfig.Style = \"a\"\n-- a comment\nreturn Config\n")
    c.ticks(20)
    check(#changes == 1, "a file whose text changed but not its values: the module is not told")
    T.write(dir .. "config.lua", "local Config = {}\nConfig.Amount = 4\nConfig.Style = \"a\"\nConfig.Count = 2\nreturn Config\n")
    c.ticks(1)
    check(#changes == 1, "after a look at the file the next one is 5 seconds later again")
    c.ticks(19)
    check(#changes == 2 and changes[2].keys == "Count", "a change of one value: the module is told that key")
    T.write(dir .. "config.lua", "local Config = {}\nConfig.Amount = \nreturn Config\n")
    c.ticks(60)
    check(c.logged("config.lua has an error, keeping the previous settings: config.lua:3: unexpected symbol near 'return'") == 1 and values.Amount == 4 and #changes == 2,
        "a file with an error: said once with Lua's message (not every 5 seconds), the previous values stay")
    ok, why = o:reload()
    check(ok == false and why == "still invalid", "reload says that it is still the broken file")
    T.write(dir .. "config.lua", "local Config = {}\nlocal t = nil\nConfig.Amount = t.x\nreturn Config\n")
    ok, why = o:reload(true)
    check(ok == false and has(why, "attempt to index a nil value") and c.logged("keeping the previous settings: config.lua:3: attempt to index a nil value") == 1,
        "a file that raises when it runs: reload returns false and Lua's message, which is in the log too")
    os.remove(dir .. "config.lua")
    c.ticks(20)
    ok, why = o:reload(true)
    check(values.Amount == 4 and ok == false and why == "config.lua not found" and #c.ue.errors == 0 and c.logged("config.lua has an error") == 2, "a file that is gone: the values stay, and that is not an error of the file")
    T.write(dir .. "config.lua", "local Config = {}\nreturn Config\n")
    c.ticks(20)
    check(#changes == 3 and changes[3].keys == "Amount,Count,Style" and values.Amount == 2.5 and values.Style == "b", "a key that is no longer in the file has its default again")
    o.onChange = function() error("the module's function fails") end
    T.write(dir .. "config.lua", "local Config = {}\nConfig.Count = 5\nreturn Config\n")
    c.ticks(20)
    check(values.Count == 5 and c.logged("the changed settings (Count) could not be applied: ") == 1 and c.logged("the module's function fails") == 1 and #c.ue.errors == 0,
        "a failing function of the module does not stop the service: the value is in place, the error is in the log once")
    o.onChange = "not a function"
    T.write(dir .. "config.lua", "local Config = {}\nConfig.Count = 7\nreturn Config\n")
    c.ticks(20)
    check(values.Count == 7 and c.logged("could not be applied") == 1 and #c.ue.errors == 0, "something that is not a function in its place is not called")
    o.onChange = nil
    T.write(dir .. "config.lua", "local Config = {}\nConfig.Count = 6\nreturn Config\n")
    ok, why = o:reload(true)
    check(ok == true and type(why) == "table" and why[1] == "Count" and values.Count == 6, "reload(true) reads at once and returns the keys that changed")
    done(c)
end

-- ---------------------------------------------------------------------------
section("8. the game changes values")
do
    local c = fresh()
    local dir = folder()
    local changes = {}
    local o = c.S.open({ module = "alpha", dir = dir, schema = schemaA(), log = c.log, onChange = function(values, keys, why)
        changes[#changes + 1] = { keys = table.concat(keys, ","), why = why }
    end })
    local original = "-- my notes\nlocal Config = {}\n  Config.Extra = 1\nConfig.Enabled = true\nConfig.Amount = 2.5 -- was 3\nConfig.Mine = \"keep\"\nreturn Config\n"
    T.write(dir .. "config.lua", original)
    o:reload(true)
    check(o:set("Amount", 4) == true and o.values.Amount == 4, "set: the value changes")
    check(T.read(dir .. "config.lua") == original:gsub("Config.Amount = 2.5 %-%- was 3", "Config.Amount = 4.0"), "in config.lua only that line changes: comments, unknown keys and their order stay")
    check(#changes == 1 and changes[1].keys == "Amount" and changes[1].why == "set", "the module is told (why: set)")
    check(o:set("Amount", 4) == false and #changes == 1, "the same value again: nothing is written, nobody is told")
    check(o:set("Amount", 50, "console") == true and o.values.Amount == 10 and changes[2].why == "console" and has(T.read(dir .. "config.lua"), "Config.Amount = 10.0\n"),
        "a value outside the range is pulled inside before it is written; the reason given is passed on")
    check(o:set("Nothing", 5) == false and o:set("Now", true) == false and o.values.Nothing == nil, "a key the schema does not know, or an action: ignored")
    local keys = o:apply({ Count = 4.6, Style = "c", Enabled = false, Unknown = 1, Hotkey = "alt+f1" }, "menu")
    check(table.concat(keys, ",") == "Count,Enabled,Hotkey,Style" and o.values.Count == 5 and o.values.Style == "c" and o.values.Enabled == false and o.values.Hotkey == "ALT+F1",
        "apply: several values at once, checked; the keys that changed come back sorted")
    local text = T.read(dir .. "config.lua")
    check(has(text, "Config.Enabled = false\n") and has(text, "Config.Count = 5\nConfig.Style = \"c\"\nConfig.Hotkey = \"ALT+F1\"\nreturn Config\n") and has(text, "Config.Mine = \"keep\"\n"),
        "keys that had no line get one in front of return Config, in the order of the schema")
    check(#changes == 3 and changes[3].keys == "Count,Enabled,Hotkey,Style" and changes[3].why == "menu", "one call of the module's function for the whole change")
    check(io.open(dir .. "config.lua.tmp", "rb") == nil, "no temporary file is left behind")
    c.ticks(40)
    check(#changes == 3, "what the service wrote itself is not taken for a change of the file")
    check(o:set("Secret", 9) == true and has(T.read(dir .. "config.lua"), "Config.Secret = 9\n"), "a hidden setting can be set and is then written")

    -- reset
    keys = o:reset()
    check(table.concat(keys, ",") == "Amount,Count,Enabled,Hotkey,Style" and o.values.Amount == 2.5 and o.values.Hotkey == "CTRL+Y" and o.values.Secret == 9 and changes[#changes].why == "reset",
        "reset: every shown setting is back at its default, hidden ones stay")
    check(has(T.read(dir .. "config.lua"), "Config.Amount = 2.5\n") and has(T.read(dir .. "config.lua"), "Config.Mine = \"keep\"\n"), "and written; the rest of the file stays")

    -- no usable file: a complete one is written
    os.remove(dir .. "config.lua")
    o:set("Amount", 7.5)
    local expected = TEXT_A:gsub("Config.Amount = 2.5", "Config.Amount = 7.5"):gsub("\n\nreturn Config\n", "\nConfig.Secret = 9\n\nreturn Config\n")
    check(T.read(dir .. "config.lua") == expected, "no config.lua any more: the default file with every value that is not the default")
    T.write(dir .. "config.lua", "broken (\n")
    o:set("Amount", 8)
    check(T.read(dir .. "config.lua") == expected:gsub("Config.Amount = 7.5", "Config.Amount = 8.0"), "a broken config.lua is replaced the same way")

    -- a file that cannot be written
    T.sh("chmod a-w " .. T.q(dir) .. " && chmod a-w " .. T.q(dir .. "config.lua"))
    local readOnly = io.open(dir .. "probe", "wb") == nil       -- false when the tests run as root
    local before = #changes
    o:set("Amount", 9)
    T.sh("chmod u+w " .. T.q(dir) .. " && chmod u+w " .. T.q(dir .. "config.lua"))
    if readOnly then
        check(o.values.Amount == 9 and #changes == before + 1 and c.logged("config.lua could not be written (") == 1 and has(T.read(dir .. "config.lua"), "Config.Amount = 8.0"),
            "a file that cannot be written: the value holds for this run, the module is told, the log says so")
    else
        check(o.values.Amount == 9 and #changes == before + 1, "(the tests run as root: a folder cannot be made read-only; the value holds and the module is told)")
    end
    os.remove(dir .. "probe")
    o.onChange = function() error("fails") end
    local logsBefore = #c.logs
    check(o:set("Amount", 1) == true and o.values.Amount == 1 and #c.logs == logsBefore + 1 and has(c.logs[#c.logs], "the changed settings (Amount) could not be applied: ") and has(c.logs[#c.logs], "fails"),
        "a failing function of the module does not stop a change: the value is set and written, the error is one line in the log")
    done(c)
end

-- ---------------------------------------------------------------------------
section("9. the in-game mod menu: what is published")
do
    local GS, RS, FS = "\29", "\30", "\31"
    local c = fresh({ shared = { ["SMM:index"] = "HUDMap", ["SMM:refresh"] = 4 } })
    local dir = folder()
    local o = c.S.open({ module = "alpha", dir = dir, schema = schemaA(), log = c.log })
    local store = c.mods.store
    check(store["SMM:index"] == "HUDMap,G1R Combat" and store["SMM:refresh"] == 5, "the page is added to the menu's list (what was there stays) and the menu is asked to read again")
    local schema = store["SMM:schema:G1R Combat"]
    local expected = table.concat({
        table.concat({ "Look", table.concat({ "Style", "num", "1", "3", "1", "1 = a, 2 = b, 3 = c" }, FS), table.concat({ "Do it now", "action", "", "", "", "Runs the thing." }, FS) }, RS),
        table.concat({ "Main", table.concat({ "Switch it on", "bool", "", "", "", "false = off." }, FS), table.concat({ "Amount (times)", "num", "0", "10", "0.5", "First line of the comment, second line." }, FS),
            table.concat({ "Count", "num", "1", "9", "1", "" }, FS) }, RS),
    }, GS)
    check(schema == expected, "the schema as the menu mod reads it: sections by Order, the items with kind, range, step and a short hint; texts, keys and hidden items are not in it")
    if schema ~= expected then io.write((schema:gsub("[\29\30\31]", "|")), "\n", (expected:gsub("[\29\30\31]", "|")), "\n") end
    check(store["SMM:values:G1R Combat"] == table.concat({ "n2", "x", "b1", "n2.5", "n3" }, RS), "the values: a choice as the number of its option, an action as x, a switch as b1 / b0, numbers as n...")

    -- a second module on the same page, a third on another
    local s2 = { Module = "beta", Page = "Combat", PageOrder = 99, Groups = {
        { Title = "Second", Order = 15, Items = { { Key = "On", Kind = "bool", Default = false, Label = "Beta on", Menu = "short hint" } } },
        { Title = "Same order", Order = 20, Items = { { Key = "N", Kind = "number", Default = 1, Min = 0, Max = 5, Label = "N" } } },
        { Title = "Texts only", Items = { { Key = "T", Kind = "text", Default = "x" } } },
    } }
    local dir2 = folder()
    local o2 = c.S.open({ module = "beta", dir = dir2, schema = s2, log = c.log })
    local page = T.menuPage(c, "Combat")
    local order = {}
    for _, s in ipairs(page.sections) do order[#order + 1] = s.title end
    check(table.concat(order, "|") == "Look|Second|Main|Same order", "two modules on one page: their groups in one list by Order, then module name; a group without menu items is left out")
    check(store["SMM:index"] == "HUDMap,G1R Combat" and store["SMM:refresh"] == 6, "the page is in the list once; the menu is asked to read again")
    check(T.menuItem(c, "Combat", "Beta on").desc == "short hint" and T.menuItem(c, "Combat", "Beta on").value == false and T.menuItem(c, "Combat", "N").index == 7,
        "an item's Menu text is its hint; items are numbered through the whole page")
    local s3 = { Module = "gamma", Groups = { { Items = { { Key = "X", Kind = "bool", Default = true, Label = "A, B" .. FS .. "C" } } } } }
    local o3 = c.S.open({ module = "gamma", dir = folder(), schema = s3, log = c.log })
    check(store["SMM:index"] == "HUDMap,G1R Combat,G1R gamma" and T.menuItem(c, "gamma", "A, B C") ~= nil and T.menuPage(c, "gamma").sections[1].title == "",
        "a schema without a Page gets a page named after its module; separators of the format are taken out of texts")
    local s4 = { Module = "delta", Page = "One, two", Groups = { { Items = { { Key = "X", Kind = "bool", Default = true } } } } }
    c.S.open({ module = "delta", dir = folder(), schema = s4, log = c.log })
    check(store["SMM:index"] == "HUDMap,G1R Combat,G1R gamma,G1R One  two" and T.menuItem(c, "One  two", "X") ~= nil, "a comma in a page name would split the menu's list: it becomes a space; an item without a Label shows its key")
    local s5 = { Module = "quiet", Page = "Quiet", Groups = { { Items = { { Key = "X", Kind = "bool", Default = true } } } } }
    c.S.open({ module = "quiet", dir = folder(), schema = s5, log = c.log, menu = false })
    check(store["SMM:schema:G1R Quiet"] == nil and not has(store["SMM:index"], "Quiet"), "menu = false: the module is not in the menu")
    done(c)

    c = fresh({ noModRef = true })
    o = c.S.open({ module = "alpha", dir = folder(), schema = schemaA(), log = c.log })
    c.ticks(30)
    check(o ~= nil and o:set("Amount", 3) == true and c.S._test.menu.available == false and #c.S._test.menu.order == 0 and #c.ue.errors == 0,
        "a UE4SS without shared variables: the settings work, there is no menu and nothing is prepared for one")
    done(c)
    c = fresh({ noModRef = true })
    rawset(_G, "ModRef", { GetSharedVariable = function() return nil end })
    o = c.S.open({ module = "alpha", dir = folder(), schema = schemaA(), log = c.log })
    check(c.S._test.menu.available == false, "shared variables that can be read but not written: no menu either")
    done(c)

    -- names and the order of groups
    c = fresh()
    local function tiny(module, page, groups)
        local s = { Module = module, Page = page, Groups = {} }
        for i, g in ipairs(groups) do
            s.Groups[i] = { Title = g[1], Order = g[2], Items = { { Key = "K" .. i, Kind = "bool", Default = true, Label = g[1] } } }
        end
        return s
    end
    local z = c.S.open({ module = "zeta", dir = folder(), schema = tiny("zeta", "P", { { "z-late", 101 }, { "z-none", nil }, { "z-early", 99 }, { "z-20a", 20 }, { "z-20b", 20 }, { "z-20c", 20 }, { "z-20d", 20 }, { "z-20e", 20 } }), log = c.log })
    check(c.mods.store["SMM:refresh"] == 1, "the first page: the menu's refresh counter starts at 1")
    local a = c.S.open({ module = "alpha", dir = folder(), schema = tiny("alpha", "P", { { "a-20", 20 }, { "a-none", nil } }), log = c.log })
    order = {}
    for _, sec in ipairs(T.menuPage(c, "P").sections) do order[#order + 1] = sec.title end
    check(table.concat(order, " ") == "a-20 z-20a z-20b z-20c z-20d z-20e z-early a-none z-none z-late",
        "groups by Order (none = 100), then by module name whichever was opened first, then in the order of the file: " .. table.concat(order, " "))
    local named = c.S.open({ module = "given", dir = folder(), schema = { Module = "inner", Groups = { { Items = { { Key = "X", Kind = "bool", Default = true } } } } }, log = c.log })
    local bare = c.S.open({ dir = folder(), schema = { Groups = { { Items = { { Key = "X", Kind = "bool", Default = true } } } } }, log = c.log })
    local fromSchema = c.S.open({ dir = folder(), schema = { Module = "inner2", Groups = { { Items = { { Key = "X", Kind = "bool", Default = true } } } } }, log = c.log })
    check(named.module == "given" and fromSchema.module == "inner2" and bare.module == "?", "a module's name: the one given to open, else the schema's, else a question mark")
    check(T.menuPage(c, "inner") ~= nil and T.menuPage(c, "inner2") ~= nil and T.menuPage(c, "?") ~= nil, "a page without a name is named after the schema's module, else after the name given")
    -- hints
    local long = ("word "):rep(20)          -- 100 characters, no sentence end
    local hints = c.S.open({ module = "hints", dir = folder(), log = c.log, schema = { Module = "hints", Groups = { { Items = {
        { Key = "A", Kind = "bool", Default = true, Label = "A", Comment = long },
        { Key = "B", Kind = "bool", Default = true, Label = "B", Comment = ("x"):rep(54) },
        { Key = "C", Kind = "bool", Default = true, Label = "C", Comment = ("x"):rep(55) },
        { Key = "D", Kind = "bool", Default = true, Label = "D", Comment = "Is it on? Yes. No." },
        { Key = "E", Kind = "bool", Default = true, Label = "E", Comment = "Version 2.5 of it! More." },
        { Key = "F", Kind = "bool", Default = true, Label = "F", Comment = "A long comment that the short menu text stands in for. More.", Menu = "the short one" },
        { Key = "G", Kind = "bool", Default = true, Label = "G", Menu = ("y"):rep(60) },
    } } } } })
    check(T.menuItem(c, "hints", "A").desc == ("word "):rep(10):sub(1, 49) .. "..." and T.menuItem(c, "hints", "B").desc == ("x"):rep(54)
        and T.menuItem(c, "hints", "C").desc == ("x"):rep(51) .. "...",
        "the menu mod cuts a hint after 54 characters: a longer one is cut at a word, with three dots (without a word break at 51); 54 fit")
    check(T.menuItem(c, "hints", "D").desc == "Is it on?" and T.menuItem(c, "hints", "E").desc == "Version 2.5 of it!", "the hint is the first sentence of the comment (a point inside a number does not end it)")
    check(T.menuItem(c, "hints", "F").desc == "the short one" and T.menuItem(c, "hints", "G").desc == ("y"):rep(51) .. "...", "a Menu text stands for the comment; a Menu text that is too long is cut as well")
    done(c)
end

section("9b. the in-game mod menu: texts that fit its columns")
do
    local c = fresh()
    local L = c.S._test.limits
    check(L.name == 35 and L.hint == 54 and L.tab == 28, "the menu mod's columns: names up to 35 characters, hints up to 54, tabs and sub-tabs up to 28")
    local fit = c.S._test.fit
    check(fit("short", 10) == "short" and fit("one two three four", 10) == "one two..." and fit("one two three four", 12) == "one two..."
        and fit("abcdefghijkl", 10) == "abcdefg..." and fit("a bcdefghijkl", 10) == "a bcdef..." and fit(("x"):rep(10), 10) == ("x"):rep(10)
        and fit("ab   cdefgh", 8) == "ab..." and fit("ab cd ef gh", 9) == "ab cd..."
        and fit("abcde fghijk", 10) == "abcde..." and fit("abcd efghijk", 10) == "abcd ef...",
        "a cut ends at a word: where it falls inside one, at the word break before it when that leaves at least half the room (else inside the word); spaces before the dots go")
    local s = { Module = "texts", Page = "Texts", Groups = {
        { Title = "Texts: the long part", Items = {
            { Key = "A", Kind = "number", Default = 1, Min = 0, Max = 5, Label = "Short", Unit = "seconds" },
            { Key = "B", Kind = "number", Default = 1, Min = 0, Max = 5, Label = "A label that is just long enough", Unit = "times" },
            { Key = "C", Kind = "number", Default = 1, Min = 0, Max = 5, Label = "A label that is far too long for the column", Unit = "times", MenuLabel = "Short form (times)" },
            { Key = "D", Kind = "bool", Default = true, Label = "A label that is far too long for the column of names" },
            { Key = "E", Kind = "bool", Default = true, Label = "x", MenuLabel = ("m"):rep(40) },
        } },
        { Title = "A title that is far too long for a sub-tab", Items = { { Key = "F", Kind = "bool", Default = true, Label = "F" } } },
        { Title = "A long title with a short one", MenuTitle = "Short title", Items = { { Key = "G", Kind = "bool", Default = true, Label = "G" } } },
        { Title = "Texts:", Items = { { Key = "H", Kind = "bool", Default = true, Label = "H" } } },
    } }
    c.S.open({ module = "texts", dir = folder(), schema = s, log = c.log })
    local page = T.menuPage(c, "Texts")
    local names, titles = {}, {}
    for _, it in ipairs(page.items) do names[#names + 1] = it.name end
    for _, sec in ipairs(page.sections) do titles[#titles + 1] = sec.title end
    check(names[1] == "Short (seconds)" and names[2] == "A label that is just long enough" and names[3] == "Short form (times)",
        "a name: the label with its unit when that fits, the label alone when only it fits, the MenuLabel when there is one: " .. table.concat(names, " | "))
    check(names[4] == "A label that is far too long for..." and names[5] == ("m"):rep(32) .. "...", "a label (or MenuLabel) longer than 35 characters is cut at a word")
    check(titles[1] == "The long part" and titles[2] == "A title that is far too..." and titles[3] == "Short title" and titles[4] == "Texts:",
        "a sub-tab: the page's name in front of the title is left out, a long title is cut at a word, a MenuTitle stands for the title; a title that is only the page's name stays: " .. table.concat(titles, " | "))
    for _, n in ipairs(names) do check(#n <= 35, "no name is longer than the column: " .. n) end
    local a22, b22 = ("a"):rep(22), ("b"):rep(22)
    check(c.S._test.menuLabel({ Label = "Label of exactly 27 letters", Unit = "times" }) == "Label of exactly 27 letters (times)"
        and c.S._test.menuHint({ Kind = "choice", Options = { a22, b22 } }, a22) == "1 = " .. a22 .. ", 2 = " .. b22,
        "exactly at the column: a name with its unit of 35 characters and a list of options of 54 are shown whole")
    done(c)

    -- a choice whose options do not fit: the hint names the option it has, and follows it
    c = fresh({ shared = { ["SMM:refresh"] = 10 } })
    local dir = folder()
    local choices = { Module = "pick", Page = "Pick", Groups = { { Title = "Main", Items = {
        { Key = "Corner", Kind = "choice", Default = "bottom left", Options = { "top right", "top left", "bottom right", "bottom left" }, Label = "Corner" },
        { Key = "Mode", Kind = "choice", Default = "b", Options = { "a", "b" }, Label = "Mode" },
        { Key = "N", Kind = "number", Default = 1, Min = 0, Max = 9, Label = "N" },
    } } } }
    local o = c.S.open({ module = "pick", dir = dir, schema = choices, log = c.log })
    local store = c.mods.store
    check(T.menuItem(c, "Pick", "Corner").desc == "now: bottom left (4 of 4)" and T.menuItem(c, "Pick", "Mode").desc == "1 = a, 2 = b",
        "a choice whose list of options is longer than the hint column shows the option it has now; a short list is shown whole")
    check(store["SMM:refresh"] == 11, "opening the page asks the menu to read it")
    T.menuSet(c, "Pick", "Corner", 2)
    c.ticks(1)
    check(o.values.Corner == "top left" and T.menuItem(c, "Pick", "Corner").desc == "now: top left (2 of 4)" and store["SMM:refresh"] == 12,
        "an edit in the menu: the hint names the new option, and the menu is asked to read the page again")
    T.menuSet(c, "Pick", "N", 5)
    c.ticks(1)
    check(o.values.N == 5 and store["SMM:refresh"] == 12, "a change that leaves every text as it is: the values are published, the page is not read again")
    T.menuSet(c, "Pick", "Mode", 1)
    c.ticks(1)
    check(o.values.Mode == "a" and store["SMM:refresh"] == 12, "a choice whose hint is its whole list: no new texts either")
    T.write(dir .. "config.lua", "local Config = {}\nConfig.Corner = \"top right\"\nreturn Config\n")
    c.ticks(20)
    check(T.menuItem(c, "Pick", "Corner").desc == "now: top right (1 of 4)" and store["SMM:refresh"] == 13, "a changed file: the same")
    -- the schema cannot be published: the menu is not asked to read it
    local set = c.mods.SetSharedVariable
    c.mods.SetSharedVariable = function(self, name, value)
        if name == "SMM:schema:G1R Pick" then error("refused") end
        return set(self, name, value)
    end
    T.menuSet(c, "Pick", "Corner", 3)
    c.ticks(1)
    check(o.values.Corner == "bottom right" and store["SMM:refresh"] == 13 and T.menuItem(c, "Pick", "Corner").desc == "now: top right (1 of 4)" and #c.ue.errors == 0,
        "the page's schema cannot be published: the value is set, the menu is not asked to read the page again")
    c.mods.SetSharedVariable = set
    store["SMM:refresh"] = nil
    T.menuSet(c, "Pick", "Corner", 2)
    c.ticks(1)
    check(T.menuItem(c, "Pick", "Corner").desc == "now: top left (2 of 4)" and store["SMM:refresh"] == 1, "published again; a refresh counter that is not there starts at 1")
    store["SMM:schema:G1R Pick"] = "taken away"
    c.ticks(30)
    check(store["SMM:schema:G1R Pick"] == "taken away", "while no text changes, the page's schema is not published again")
    done(c)

    -- every module of the mod: nothing it publishes is cut
    local p = io.popen("ls " .. T.q(T.MOD .. "modules"))
    local modules = {}
    for m in p:lines() do modules[#modules + 1] = m end
    p:close()
    local shown, cut = 0, {}
    for _, m in ipairs(modules) do
        local path = T.MOD .. "modules/" .. m .. "/Scripts/schema.lua"
        local f = io.open(path)
        local main = T.read(T.MOD .. "modules/" .. m .. "/Scripts/main.lua") or ""
        if f then
            f:close()
            local schema = dofile(path)
            local inMenu = not main:find("menu%s*=%s*false")
            if inMenu then
                local tab = "G1R " .. tostring(schema.Page or schema.Module)
                if #tab > L.tab then cut[#cut + 1] = m .. " tab: " .. tab end
                for _, g in ipairs(schema.Groups) do
                    local any = false
                    for _, item in ipairs(g.Items) do
                        if not item.Hidden and (item.Kind == "bool" or item.Kind == "number" or item.Kind == "choice" or item.Kind == "action") then
                            any = true
                            shown = shown + 1
                            local name = item.MenuLabel or ((item.Label or item.Key) .. (item.Unit and (" (" .. item.Unit .. ")") or ""))
                            if #name > L.name then cut[#cut + 1] = m .. "." .. item.Key .. " name: " .. name end
                            if item.Kind == "choice" then
                                for _, o in ipairs(item.Options) do
                                    local now = ("now: %s (%d of %d)"):format(o, #item.Options, #item.Options)
                                    if #now > L.hint then cut[#cut + 1] = m .. "." .. item.Key .. " option: " .. o end
                                end
                            else
                                local comment = type(item.Comment) == "table" and table.concat(item.Comment, " ") or tostring(item.Comment or "")
                                local hint = item.Menu or (comment:match("^(.-[%.!?])%s") or comment)
                                if #hint > L.hint then cut[#cut + 1] = m .. "." .. item.Key .. " hint: " .. hint end
                            end
                        end
                    end
                    if any then
                        local title = c.S._test.menuTitle({ Title = g.Title, MenuTitle = g.MenuTitle }, schema.Page or schema.Module)
                        if title:sub(-3) == "..." then cut[#cut + 1] = m .. " sub-tab: " .. tostring(g.Title) end
                    end
                end
            end
        end
    end
    check(shown > 150, "the modules' schemas were read (" .. shown .. " items in the menu)")
    check(#cut == 0, "every name, hint, tab and sub-tab the mod publishes fits the menu's columns (" .. #cut .. " do not)")
    for i = 1, math.min(#cut, 400) do io.write("    does not fit: ", cut[i], "\n") end
end

-- ---------------------------------------------------------------------------
section("10. the in-game mod menu: edits")
do
    local RS, FS = "\30", "\31"
    local c = fresh()
    local dir = folder()
    local changes, actions = {}, {}
    local o = c.S.open({ module = "alpha", dir = dir, schema = schemaA(), log = c.log,
        onChange = function(_, keys, why) changes[#changes + 1] = table.concat(keys, ",") .. "/" .. why end,
        onAction = function(key, why) actions[#actions + 1] = key .. "/" .. tostring(why) end })
    local s2 = { Module = "beta", Page = "Combat", Groups = { { Title = "Second", Order = 15, Items = { { Key = "On", Kind = "bool", Default = false, Label = "Beta on" } } } } }
    local changes2 = {}
    local o2 = c.S.open({ module = "beta", dir = folder(), schema = s2, log = c.log, onChange = function(_, keys, why) changes2[#changes2 + 1] = table.concat(keys, ",") .. "/" .. why end })
    local store = c.mods.store
    local CMD = "SMM:cmd:G1R Combat"
    -- page order: 1 Style, 2 Do it now, 3 Beta on, 4 Switch it on, 5 Amount, 6 Count
    T.menuSet(c, "Combat", "Amount", 7.5)
    check(o.values.Amount == 2.5, "an edit waits in the queue until the service looks")
    c.ticks(1)
    check(o.values.Amount == 7.5 and changes[1] == "Amount/menu" and store[CMD] == "" and has(T.read(dir .. "config.lua"), "Config.Amount = 7.5\n"),
        "then it is applied: the value, the module's function (why: menu), config.lua, and the queue is empty")
    check(T.menuItem(c, "Combat", "Amount").value == 7.5, "the menu gets the new value")
    T.menuSet(c, "Combat", "Switch it on", false)
    T.menuSet(c, "Combat", "Style", 3)
    T.menuSet(c, "Combat", "Count", 4.4)
    T.menuSet(c, "Combat", "Beta on", true)
    c.ticks(1)
    check(o.values.Enabled == false and o.values.Style == "c" and o.values.Count == 4 and o2.values.On == true, "four edits in one look, for two modules: a switch, a choice by its number, a number (rounded)")
    check(#changes == 2 and changes[2] == "Count,Enabled,Style/menu" and #changes2 == 1 and changes2[1] == "On/menu", "each module is told once")
    check(store["SMM:values:G1R Combat"] == table.concat({ "n3", "x", "b1", "b0", "n7.5", "n4" }, RS), "the values of the page after that")
    T.menuSet(c, "Combat", "Do it now", true)
    c.ticks(1)
    check(#actions == 1 and actions[1] == "Now/menu" and #changes == 2, "an action: the module's onAction gets the key; no value changes")
    o.onAction = function() error("the action fails") end
    T.menuSet(c, "Combat", "Do it now", true)
    c.ticks(1)
    check(c.logged("the action Now failed") == 1 and #c.ue.errors == 0, "an action that fails: said in the log, nothing else")
    o.onAction = nil
    T.menuSet(c, "Combat", "Do it now", true)
    c.ticks(1)
    check(#c.ue.errors == 0 and store[CMD] == "", "an action nobody listens to: nothing happens")

    -- edits that are not usable
    store[CMD] = table.concat({ "99" .. FS .. "n1", "0" .. FS .. "b1", "x" .. FS .. "n1", "5", "5" .. FS, "5" .. FS .. "b1", "4" .. FS .. "n1", "1" .. FS .. "n9", "1" .. FS .. "nx", "6" .. FS .. "nine" }, RS)
    c.ticks(1)
    check(o.values.Amount == 7.5 and o.values.Enabled == false and o.values.Style == "c" and o.values.Count == 4 and #changes == 2 and store[CMD] == "" and #c.ue.errors == 0,
        "an item number that does not exist, a record without a value, the wrong kind of value for the item, a choice number without an option, not a number: all ignored")
    store[CMD] = "5" .. RS .. "1" .. FS .. "b1" .. RS .. "6" .. FS .. "n7"
    c.ticks(1)
    check(o.values.Count == 7 and o.values.Style == "c", "a record that is not usable does not take the ones after it with it; a switch value for a choice is ignored")
    store[CMD] = "5" .. FS .. "n999" .. RS .. "1" .. FS .. "n1.4" .. RS .. "1" .. FS .. "n1.6"
    c.ticks(1)
    check(o.values.Amount == 10 and o.values.Style == "b", "a number outside the range is pulled inside; of two edits of one item the later counts; a choice number is rounded")
    store[CMD] = 5
    c.ticks(1)
    check(store[CMD] == 5 and #c.ue.errors == 0, "a queue that is no text is left alone")

    -- a change from elsewhere reaches the menu
    o:set("Count", 2)
    check(T.menuItem(c, "Combat", "Count").value == 7, "a value changed by the game is published at the next look,")
    c.ticks(1)
    check(T.menuItem(c, "Combat", "Count").value == 2, "not before")
    T.write(dir .. "config.lua", "local Config = {}\nConfig.Count = 8\nreturn Config\n")
    c.ticks(20)
    check(T.menuItem(c, "Combat", "Count").value == 8 and T.menuItem(c, "Combat", "Amount").value == 2.5, "so is a changed file")
    local values = store["SMM:values:G1R Combat"]
    store["SMM:values:G1R Combat"] = "untouched"
    c.ticks(40)
    check(store["SMM:values:G1R Combat"] == "untouched", "while nothing changes nothing is published")
    done(c)
end

T.finish()
