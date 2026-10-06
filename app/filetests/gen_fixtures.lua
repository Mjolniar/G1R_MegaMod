-- ============================================================================
-- Writes the fixtures of the settings app's tests: what the game's own code
-- (Scripts/core/settings.lua and kit.lua of G1R_MegaMod) gives for a list of
-- inputs. The app's tests (SelfTest.cs: --selftest of the exe, and filetests)
-- read the file and compare what the C# code gives for the same inputs.
--
--   lua5.4 gen_fixtures.lua <G1R_MegaMod folder> <output file> <scratch folder> [<cases file>]
--
-- Without a cases file: the built-in list of inputs (the fixtures the tests carry with them).
-- gen_fixtures.sh runs that and packs the result into ../src/SelfTestFixtures.txt.gz - run it
-- whenever settings.lua, kit.lua or the schema / config.lua of xp or general changed
-- ("filetests --live" says when the fixtures are out of date).
-- With a cases file: the inputs of that file instead (what "filetests --live" makes up at random):
--   schema <name> <text> | number <value> <decimals> | key <text> | patch <text> <key> <value text>
--   | read <schema> <text or \N> | apply <name> <schema> <text or \N> <steps> (set <pairs> <key> <value> ... | disk <text or \N> | reset) ...
-- and the output has the same records as the fixtures.
--
-- Format: one record per line, fields separated by tabs. In a field: \\ = a
-- backslash, \t \n \r, \xHH = any other byte below 32 or above 126, \N alone =
-- nothing (nil / no file). Lines that start with # are comments.
-- Needs a POSIX shell (mkdir, rm).
-- ============================================================================
local MOD, OUT, WORK, CASES = arg[1], arg[2], arg[3], arg[4]
if not (MOD and OUT and WORK) then
    io.stderr:write("usage: lua5.4 gen_fixtures.lua <G1R_MegaMod folder> <output file> <scratch folder> [<cases file>]\n")
    os.exit(2)
end
MOD = MOD:gsub("/*$", "") .. "/"
WORK = WORK:gsub("/*$", "") .. "/g1r-app-fixtures-" .. os.time() .. "/"        -- a folder of our own: it is removed at the end

G1R_KIT = dofile(MOD .. "Scripts/core/kit.lua")         -- the settings service asks the kit how keys are spelt
local KIT = G1R_KIT
local function freshSettings() return dofile(MOD .. "Scripts/core/settings.lua") end
local S = freshSettings()

local out = {}
local NIL = "\\N"
local function esc(s)
    if s == nil then return NIL end
    return (tostring(s):gsub("[%c\\\127-\255]", function(c)
        if c == "\\" then return "\\\\" end
        if c == "\t" then return "\\t" end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        return ("\\x%02X"):format(c:byte())
    end))
end
local function record(...)
    local fields = { ... }
    for i = 1, select("#", ...) do fields[i] = esc(fields[i]) end
    out[#out + 1] = table.concat(fields, "\t")
end
local function comment(text) out[#out + 1] = "# " .. text end

local function sh(cmd) return os.execute(cmd) end
local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
end
local function writeFile(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end
-- the folder of a case: one folder for all of them, emptied each time
local function folder()
    local dir = WORK .. "case/"
    os.remove(dir .. "config.lua")
    os.remove(dir .. "config.lua.tmp")
    return dir
end
sh("mkdir -p " .. q(WORK .. "case"))

-- a number so that it reads back as the same number of the same kind
local function numberSource(v)
    if math.type(v) == "integer" then return ("%d"):format(v) end
    if v ~= v then return "(0/0)" end
    if v == math.huge then return "1e999" end
    if v == -math.huge then return "-1e999" end
    local s = ("%.17g"):format(v)
    if not s:find("[%.eEn]") then s = s .. ".0" end
    return s
end
local function typed(v)
    if type(v) == "boolean" then return "b:" .. tostring(v) end
    if type(v) == "number" then return "n:" .. ("%.17g"):format(v) end
    if type(v) == "string" then return "s:" .. v end
    error("no typed form for a " .. type(v))
end

-- A Lua table of plain values as the text of a schema.lua.
local FIELD_ORDER = { "Module", "Page", "PageOrder", "Header", "Notes", "Groups", "Title", "Order", "Hint", "Items", "Key", "Kind", "Default", "Min", "Max",
    "Step", "Decimals", "Options", "Label", "Unit", "Needs", "Hidden", "Menu", "Comment" }
local function source(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "string" then
        return '"' .. v:gsub("[%c\\\"]", function(c)
            if c == "\\" then return "\\\\" end
            if c == '"' then return '\\"' end
            if c == "\n" then return "\\n" end
            if c == "\t" then return "\\t" end
            return ("\\%03d"):format(c:byte())
        end) .. '"'
    end
    if t == "number" then return numberSource(v) end
    if t == "boolean" then return tostring(v) end
    assert(t == "table", "a schema holds plain values only")
    local parts, seen = {}, {}
    for i, item in ipairs(v) do
        parts[#parts + 1] = source(item, indent .. "    ")
        seen[i] = true
    end
    local keys = {}
    for _, k in ipairs(FIELD_ORDER) do
        if v[k] ~= nil then keys[#keys + 1] = k; seen[k] = true end
    end
    local others = {}
    for k in pairs(v) do
        if not seen[k] then others[#others + 1] = k end
    end
    table.sort(others)
    for _, k in ipairs(others) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. " = " .. source(v[k], indent .. "    ") end
    if #parts == 0 then return "{}" end
    local long = false
    for _, p in ipairs(parts) do
        if p:find("[{\n]") then long = true end
    end
    if not long then return "{ " .. table.concat(parts, ", ") .. " }" end
    return "{\n" .. indent .. "    " .. table.concat(parts, ",\n" .. indent .. "    ") .. ",\n" .. indent .. "}"
end
local function schemaSource(schema)
    return "-- a test schema\nlocal Schema = " .. source(schema) .. "\n\nreturn Schema\n"
end
local function loadSchema(text)
    -- as the game does it: loadfile (which skips a byte order mark and a first line with #), no libraries
    local path = WORK .. "schema.lua"
    writeFile(path, text)
    local chunk, err = loadfile(path, "t", {})
    if not chunk then return false, (tostring(err):gsub("^.-schema%.lua:", "schema.lua:")) end
    local ok, result = pcall(chunk)
    if not ok then return false, (tostring(result):gsub("^.-schema%.lua:", "schema.lua:")) end
    return true, result
end
-- the table of a schema text that is known to be good
local function goodSchema(text)
    local ok, schema = loadSchema(text)
    assert(ok and type(schema) == "table", tostring(schema))
    return schema
end


-- ---------------------------------------------------------------------------
-- One case each: the input, and what the game's code gives for it
-- ---------------------------------------------------------------------------
local function numberCase(v, decimals)
    local ok, text = pcall(S.numberText, v, decimals)
    record("number", ("%.17g"):format(v), decimals, ok and text or nil)
end
local function keyCase(text)
    local usual, code, modifiers = KIT.keyCombo(text)
    record("key", text, usual, usual and usual ~= "" and code or "", usual and table.concat(modifiers, ",") or "")
end
local function patchCase(text, key, valueText)
    record("patch", text, key, valueText, S.patch(text, key, valueText))
end

local SchemaTexts = {}
local function schemaCase(name, text)
    local loaded, schema = loadSchema(text)
    if not loaded then
        record("schema", name, text, "unreadable", schema)
        return
    end
    local items, reason = S.itemsOf(schema)
    if not items then
        record("schema", name, text, "bad", reason)
        return
    end
    local ok, default = pcall(S.defaultText, schema)
    if not ok then
        record("schema", name, text, "raises", (tostring(default):gsub("^.-settings%.lua:%d+: ", "")))
        return
    end
    SchemaTexts[name] = text
    record("schema", name, text, "ok", default)
end
local function opened(name, text)
    local dir = folder()
    if text then writeFile(dir .. "config.lua", text) end
    local logs = {}
    local service = freshSettings()         -- its own state per case
    local schema = goodSchema(SchemaTexts[name])
    local o = assert(service.open({ module = name, dir = dir, schema = schema, log = function(l) logs[#logs + 1] = l end, menu = false }))
    return o, dir, logs
end
local function valueFields(o)
    local fields = {}
    for _, item in ipairs(o.items) do
        fields[#fields + 1] = item.Key
        fields[#fields + 1] = typed(o.values[item.Key])
    end
    return fields
end
local function readCase(name, text)
    local o, _, logs = opened(name, text)
    local status, fixed = "ok", {}
    for _, l in ipairs(logs) do
        if l:find("config.lua has an error (", 1, true) then status = "invalid" end
        if l:find("config.lua was not there", 1, true) then status = "missing" end
        local key = l:match("^config%.lua: ([%w_]+) = ")
        if key then fixed[#fixed + 1] = key end
    end
    record("read", name, text, status, table.concat(fixed, ","), table.unpack(valueFields(o)))
end
local function scenario(name, schemaName, file, steps)
    local o, dir = opened(schemaName, file)
    local path = dir .. "config.lua"
    local fields = { "apply", name, schemaName, file == nil and NIL or file, #steps }
    local function add(v) fields[#fields + 1] = v == nil and NIL or v end
    for _, step in ipairs(steps) do
        if step.disk ~= nil then
            add("disk")
            if step.disk then
                writeFile(path, step.disk)
                add(step.disk)
            else
                os.remove(path)
                add(nil)
            end
            o:reload(true)          -- the game has looked at the file again (it does every 5 seconds)
        elseif step.reset then
            local keys = o:reset()
            add("reset")
            add(table.concat(keys, ","))
            add(readFile(path))
        else
            local keys = {}
            for k in pairs(step.set) do keys[#keys + 1] = k end
            table.sort(keys)
            add("set")
            add(#keys)
            for _, k in ipairs(keys) do
                add(k)
                add(typed(step.set[k]))
            end
            local changedKeys = o:apply(step.set, "test")
            add(table.concat(changedKeys, ","))
            add(readFile(path))
        end
    end
    for i = 1, #fields do fields[i] = fields[i] == NIL and NIL or esc(fields[i]) end
    out[#out + 1] = table.concat(fields, "\t")
end

-- ---------------------------------------------------------------------------
-- The inputs of a cases file
-- ---------------------------------------------------------------------------
local function unesc(field)
    if field == nil or field == NIL then return nil end
    local parts, i = {}, 1
    while true do
        local j = field:find("\\", i, true)
        if not j then
            parts[#parts + 1] = field:sub(i)
            break
        end
        parts[#parts + 1] = field:sub(i, j - 1)
        local c = field:sub(j + 1, j + 1)
        if c == "x" then
            parts[#parts + 1] = string.char(tonumber(field:sub(j + 2, j + 3), 16))
            i = j + 4
        else
            parts[#parts + 1] = (c == "t" and "\t") or (c == "n" and "\n") or (c == "r" and "\r") or c
            i = j + 2
        end
    end
    return table.concat(parts)
end
local function untyped(token)
    local tag, rest = token:sub(1, 2), token:sub(3)
    if tag == "b:" then return rest == "true" end
    if tag == "s:" then return rest end
    if rest == "Infinity" or rest == "inf" then return math.huge end
    if rest == "-Infinity" or rest == "-inf" then return -math.huge end
    return tonumber(rest) or (0 / 0)
end
local function runCases(path)
    for line in io.lines(path) do
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local raw = {}
            for field in (line .. "\t"):gmatch("([^\t]*)\t") do raw[#raw + 1] = field end
            local function F(i) return unesc(raw[i]) end
            local kind = raw[1]
            if kind == "schema" then
                schemaCase(F(2), F(3))
            elseif kind == "number" then
                numberCase(untyped("n:" .. F(2)), tonumber(F(3)))
            elseif kind == "key" then
                keyCase(F(2) or "")
            elseif kind == "patch" then
                patchCase(F(2) or "", F(3), F(4))
            elseif kind == "read" then
                readCase(F(2), F(3))
            elseif kind == "apply" then
                local steps, i = {}, 6
                for _ = 1, tonumber(F(5)) do
                    local what = F(i)
                    i = i + 1
                    if what == "disk" then
                        local text = F(i)
                        i = i + 1
                        if text == nil then steps[#steps + 1] = { disk = false } else steps[#steps + 1] = { disk = text } end
                    elseif what == "reset" then
                        steps[#steps + 1] = { reset = true }
                    else
                        local values = {}
                        local pairsCount = tonumber(F(i))
                        i = i + 1
                        for _ = 1, pairsCount do
                            values[F(i)] = untyped(F(i + 1))
                            i = i + 2
                        end
                        steps[#steps + 1] = { set = values }
                    end
                end
                scenario(F(2), F(3), F(4), steps)
            else
                error("a line of the cases file starts with " .. tostring(kind))
            end
        end
    end
end

if CASES then
    runCases(CASES)
else

-- ---------------------------------------------------------------------------
-- 1. numbers as they are written
-- ---------------------------------------------------------------------------
comment("number <value %.17g> <decimals> <text>")
for _, k in ipairs({ { 3, 0 }, { 2.5, 0 }, { 2.4, 0 }, { -1.5, 0 }, { -2.5, 0 }, { 0.49999999999999994, 0 }, { 1, 2 }, { 2.5, 2 }, { 0.75, 2 }, { 2.126, 2 }, { 10, 1 },
    { 100, 2 }, { -0.001, 2 }, { 0.5, 3 }, { 1234.5678, 3 }, { -2.5, 1 }, { 0.125, 2 }, { 0.375, 2 }, { 0.625, 2 }, { 0.875, 2 }, { 0.25, 1 }, { 0.35, 1 },
    { 0.45, 1 }, { 2.675, 2 }, { 1.005, 2 }, { 1.115, 2 }, { 0.1, 15 }, { 1 / 3, 15 }, { 123456789.125, 2 }, { 1e15, 2 }, { 1e15, 0 }, { 99999.999, 2 },
    { 0.999, 2 }, { 0.995, 2 }, { -0.995, 2 }, { -0.004, 2 }, { -0.005, 2 }, { 5e-324, 3 }, { 2 ^ 53, 0 }, { 2 ^ 53 + 2, 1 }, { 9e18, 0 }, { -9e18, 0 },
    { 4.35, 1 }, { 7.0, 3 }, { 0.0, 2 }, { -0.0, 2 }, { -0.0, 0 }, { 100000000, 0 }, { 0.0625, 3 }, { 0.1875, 3 }, { 1e300, 2 }, { 12.5, 0 }, { 13.5, 0 } }) do
    assert(pcall(S.numberText, k[1], k[2]))
    numberCase(k[1], k[2])
end

-- ---------------------------------------------------------------------------
-- 2. key names and key combinations
-- ---------------------------------------------------------------------------
comment("keyname <name> <virtual-key code>      (every name the kit knows)")
for _, name in ipairs(KIT.keyNames()) do
    local usual, code = KIT.keyCombo(name)
    assert(usual == name)
    record("keyname", name, code)
end
comment("key <text> <usual spelling or \\N> <code> <modifier codes>")
local keyTexts = { "", " ", "\t \n", "Y", "y", "ctrl+y", "ctrl + y", "CTRL+Y", "Ctrl+Shift+Alt+F5", "alt+shift+ctrl+f5", "shift+alt+f5", "SHIFT+ALT+F5", "strg+1", "Strg+Shift+F5",
    "control+x", "CONTROL + SHIFT + X", "ctrl+ctrl+y", "y+ctrl", "y+ctrl+alt", "delete", "DELETE", "insert", "enter", "pgup", "pgdn", "pageup", "pagedown", "up", "down",
    "left", "right", "mouse3", "mouse4", "mouse5", "capslock", "numlock", "scrolllock", "0", "9", "num0", "num9", "NUM5", "ctrl+0", "CTRL", "ctrl", "ctrl+shift",
    "A+B", "CTRL+NOKEY", "nokey", "ESC", "ESCAPE", "LEFT_MOUSE_BUTTON", "RIGHT_MOUSE_BUTTON", "LWIN", "WIN", "F13", "F0", "+", "++", "Y+", "+Y", "CTRL++Y", "ctrl+",
    "a;b", "a b", "c t r l + y", "\196\177", "\195\164", "\194\160Y", "oem_102", "OEM_THREE", "ctrl+oem_minus", "f12", "F1", "f10", "tab", "space", "backspace", "return",
    "pause", "caps_lock", "home", "end", "ins", "del", "multiply", "add", "subtract", "decimal", "divide", "num_lock", "scroll_lock", "middle_mouse_button",
    "xbutton_one", "xbutton_two", "alt+tab", "shift+space", "Y ", " Y", "ctrl\t+\ty", "ALT+ALT", "SHIFT+SHIFT+A", "ctrl-y", "ctrl_y", "CTRL+Y+", "1+2" }
for _, text in ipairs(keyTexts) do keyCase(text) end

-- ---------------------------------------------------------------------------
-- 3. schemas
-- ---------------------------------------------------------------------------
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

-- Every kind of item, every field: the page the UI test builds and drives.
local ALLKINDS = [==[
-- Every kind of setting: the test module of the settings app.
local Schema = {}

Schema.Module = "allkinds"
Schema.Page = "All kinds"
Schema.PageOrder = 95
Schema.Header = {
    "Every kind of setting (test module of the settings app)",
}
Schema.Notes = {
    "First note of the module: it stands below the groups.",
    "Second note, a longer one, to see how a paragraph that does not fit into one line of the window is wrapped: words, words, words, words, words, words, words, words, words, words, words, words, words, words, words, words, words, words, words.",
}

Schema.Groups = {
    {
        Title = "Switches", Order = 10,
        Hint = "The hint of the group stands under its title.",
        Items = {
            { Key = "Enabled", Kind = "bool", Default = true, Label = "The whole thing is on",
              Comment = "The switch the others need." },
            { Key = "Feature", Kind = "bool", Default = false, Label = "A feature of it", Needs = "Enabled",
              Tiers = { false, false, true, true, true },
              Comment = { "A switch that needs the first one,", "with a comment of two lines." } },
            { Key = "Plain", Kind = "bool", Default = false, Tiers = "default" },
        },
    },
    {
        Title = "Numbers", Order = 20,
        Items = {
            { Key = "Whole", Kind = "number", Default = 5, Min = -10, Max = 1000, Step = 5, Label = "A whole number", Unit = "pieces",
              Tiers = { 5, 10, 20, 500, 1000 },
              Comment = "Whole numbers: no Decimals." },
            { Key = "Tenth", Kind = "number", Default = 1.5, Min = 0, Max = 10, Step = 0.5, Decimals = 1, Label = "One place", Unit = "seconds",
              Tiers = { 1.5, 2.0, 2.5, 5.0, 10.0 },
              Needs = "Feature", Comment = "Needs the feature." },
            -- (Tiers the app cannot use: two values, on a text, on a hidden item - the presets leave these three alone)
            { Key = "Fine", Kind = "number", Default = 0.125, Min = -1, Max = 1, Step = 0.005, Decimals = 3, Label = "Three places", Needs = "Enabled",
              Tiers = { 0.125, 0.5 } },
            { Key = "Large", Kind = "number", Default = 50000, Min = 1, Max = 100000000, Step = 1000, Decimals = 0, Label = "A large number", Unit = "units" },
        },
    },
    {
        Title = "Lists and texts", Order = 30,
        Items = {
            { Key = "Mode", Kind = "choice", Default = "second choice", Options = { "first", "second choice", "the third and longest of the choices" },
              Tiers = { "second choice", "first", "first", "the third and longest of the choices", "the third and longest of the choices" },
              Label = "One of", Comment = "A drop-down list." },
            { Key = "Greeting", Kind = "text", Default = "say \"hi\" \\ there", Label = "A text", Needs = "Enabled", Tiers = "default",
              Comment = "Any text on one line." },
            { Key = "Empty", Kind = "text", Default = "", Label = "A text that starts empty" },
        },
    },
    {
        Title = "Keys", Order = 40,
        Hint = "Click a box and press the key.",
        Items = {
            { Key = "Hotkey", Kind = "key", Default = "CTRL+Y", Label = "Do it with", Comment = "A key with a modifier." },
            { Key = "Other", Kind = "key", Default = "", Label = "The other thing with", Needs = "Feature", Comment = "No key at first." },
            { Key = "Now", Kind = "action", Label = "Do it now", Comment = "A button of the in-game menu: not in the app." },
        },
    },
    {
        Title = "Advanced",
        Items = {
            { Key = "Secret", Kind = "number", Default = 7, Min = 0, Max = 100, Hidden = true, Tiers = "default" },
            { Key = "SecretText", Kind = "text", Default = "x", Hidden = true },
        },
    },
    {
        -- a group without a title, last on the page by its Order
        Order = 200,
        Items = {
            { Key = "Last", Kind = "bool", Default = true, Label = "A switch in a group without a title" },
        },
    },
}

return Schema
]==]

-- Texts as a schema.lua can be written by hand: other ways to write the same values.
local HANDWRITTEN = [=====[
#!/usr/bin/lua  (a first line with # is skipped when Lua loads a file)
--[==[ a long
comment ]==]
local Schema = { Module = 'hand', Page = [[By hand]], PageOrder = 0x10; }
Schema.Header = "One line"            -- a text instead of a list
Schema.Notes = 'One note';
Schema.Groups = {}
Schema.Groups[1] = {
    Title = "T\x41\65\u{41}\z
             B", Order = "15",
    Items = {
        { Key = "A", Kind = "number", Default = 1e1, Min = -.5e1, Max = 0x20, Decimals = "1", Step = .5, Label = 'A' },
        { Key = "B", Kind = "choice", Default = 'x"y', Options = { 'x"y', "z\\", [[w]] }, Unit = 5 },
        { Key = "C", Kind = "bool", Default = false, ["Needs"] = other },      -- a name that is not set yet: nothing
        { ["Key"] = "D", Kind = "text", Default = [=[
two]] words]=], Hidden = false };
    };
}
local other = { Key = "E", Kind = "key", Default = "" }
Schema.Groups[1].Items[5] = other
Schema.Groups[2] = { Items = { { Key = "F", Kind = "number", Default = -3, Min = -3, Max = -3, Decimals = -2 } } }
return Schema, "a second value is dropped"
]=====]

comment("schema <name> <text of schema.lua> ok <default config.lua> | bad <reason> | raises <Lua's message> | unreadable <Lua's message>")
local function changed(name, change)
    local s = schemaA()
    change(s)
    local text = schemaSource(s)
    -- the text must give the table it was made from
    local back = goodSchema(text)
    local a, ra = S.itemsOf(s)
    local b, rb = S.itemsOf(back)
    assert((a == nil) == (b == nil) and (a ~= nil or ra == rb), name .. ": the text of the schema does not read back as the schema")
    schemaCase(name, text)
end

changed("A", function() end)
schemaCase("allkinds", ALLKINDS)
schemaCase("hand", HANDWRITTEN)
local mutations = {
    { "no Groups", function(s) s.Groups = nil end },
    { "Groups is a text", function(s) s.Groups = "x" end },
    { "a group without Items", function(s) s.Groups[2].Items = nil end },
    { "a group that is a number", function(s) s.Groups[3] = 5 end },
    { "an item without a key", function(s) s.Groups[1].Items[1].Key = nil end },
    { "an item that is a text", function(s) s.Groups[1].Items[2] = "Amount" end },
    { "a key with a space", function(s) s.Groups[1].Items[1].Key = "My Key" end },
    { "a key that starts with a digit", function(s) s.Groups[1].Items[1].Key = "1st" end },
    { "an empty key", function(s) s.Groups[1].Items[1].Key = "" end },
    { "a key that is a number", function(s) s.Groups[1].Items[1].Key = 5 end },
    { "a key with an umlaut", function(s) s.Groups[1].Items[1].Key = "Gr\195\182\195\159e" end },
    { "a key with an underscore and digits", function(s) s.Groups[1].Items[1].Key = "_On_2"; s.Groups[1].Items[2].Needs = "_On_2" end },
    { "a key twice", function(s) s.Groups[2].Items[1].Key = "Amount" end },
    { "an action with the key of a value", function(s) s.Groups[2].Items[4].Key = "Count" end },
    { "a value with the key of an action", function(s) table.insert(s.Groups[3].Items, { Key = "Now", Kind = "bool", Default = true }) end },
    { "an unknown kind", function(s) s.Groups[1].Items[1].Kind = "slider" end },
    { "no kind", function(s) s.Groups[1].Items[1].Kind = nil end },
    { "a kind that is a number", function(s) s.Groups[1].Items[1].Kind = 5 end },
    { "a kind that is a float", function(s) s.Groups[1].Items[1].Kind = 2.5 end },
    { "a kind that is true", function(s) s.Groups[1].Items[1].Kind = true end },
    { "a kind in upper case", function(s) s.Groups[1].Items[1].Kind = "Bool" end },
    { "a switch with a number as default", function(s) s.Groups[1].Items[1].Default = 1 end },
    { "a switch without a default", function(s) s.Groups[1].Items[1].Default = nil end },
    { "a number without Min", function(s) s.Groups[1].Items[2].Min = nil end },
    { "a number without Max", function(s) s.Groups[1].Items[2].Max = nil end },
    { "a default above Max", function(s) s.Groups[1].Items[2].Default = 11 end },
    { "a default below Min", function(s) s.Groups[1].Items[3].Default = 0 end },
    { "Min above Max", function(s) s.Groups[1].Items[3].Min = 10 end },
    { "a number with a text as default", function(s) s.Groups[1].Items[3].Default = "3" end },
    { "a number with a text as Min", function(s) s.Groups[1].Items[3].Min = "1" end },
    { "a choice without options", function(s) s.Groups[2].Items[1].Options = {} end },
    { "a choice whose options are a text", function(s) s.Groups[2].Items[1].Options = "abc" end },
    { "a choice with a number as option", function(s) s.Groups[2].Items[1].Options = { "a", 2 } end },
    { "a choice with a number as option behind the default", function(s) s.Groups[2].Items[1].Options = { "b", 2 } end },
    { "a choice whose default is no option", function(s) s.Groups[2].Items[1].Default = "z" end },
    { "a choice whose default is a number", function(s) s.Groups[2].Items[1].Default = 1 end },
    { "a choice with named options only", function(s) s.Groups[2].Items[1].Options = { one = "a" } end },
    { "a text with a number as default", function(s) s.Groups[2].Items[2].Default = 5 end },
    { "a key in another spelling", function(s) s.Groups[2].Items[3].Default = "ctrl+y" end },
    { "a key that is none", function(s) s.Groups[2].Items[3].Default = "CTRL+NOKEY" end },
    { "a key that is a number", function(s) s.Groups[2].Items[3].Default = 5 end },
    { "Needs that is no text", function(s) s.Groups[1].Items[2].Needs = true end },
    { "Needs that is a number", function(s) s.Groups[1].Items[2].Needs = 1 end },
    { "Needs an unknown key", function(s) s.Groups[1].Items[2].Needs = "Nothing" end },
    { "Needs an empty key", function(s) s.Groups[1].Items[2].Needs = "" end },
    { "Needs a number", function(s) s.Groups[1].Items[2].Needs = "Count" end },
    { "Needs an action", function(s) s.Groups[1].Items[2].Needs = "Now" end },
    { "an action that needs an unknown key", function(s) s.Groups[2].Items[4].Needs = "Nothing" end },
    { "only actions", function(s) s.Groups = { { Items = { { Key = "Go", Kind = "action" } } } } end },
    { "no groups at all", function(s) s.Groups = {} end },
    { "two things wrong: the first one is named", function(s) s.Groups[1].Items[1].Default = 1; s.Groups[1].Items[2].Min = nil end },
    -- accepted
    { "no key at all (\"\")", function(s) s.Groups[2].Items[3].Default = "" end },
    { "a default at Min", function(s) s.Groups[1].Items[2].Default = 0 end },
    { "a default at Max", function(s) s.Groups[1].Items[2].Default = 10 end },
    { "Min equal to Max", function(s) s.Groups[1].Items[3].Min, s.Groups[1].Items[3].Max = 3, 3 end },
    { "an action that needs a switch", function(s) s.Groups[2].Items[4].Needs = "Enabled" end },
    { "a switch that needs a later switch", function(s) s.Groups[1].Items[1].Needs = "Late"; table.insert(s.Groups[3].Items, { Key = "Late", Kind = "bool", Default = false }) end },
    { "a hidden switch that is needed", function(s) s.Groups[1].Items[1].Hidden = true end },
    { "no Header", function(s) s.Header = nil end },
    { "no Header and no Module", function(s) s.Header = nil; s.Module = nil end },
    { "a Header that is one text", function(s) s.Header = "One line only" end },
    { "a Header that is a number", function(s) s.Header = 5 end },
    { "a Header that is false", function(s) s.Header = false end },
    { "an empty Header", function(s) s.Header = {} end },
    { "a Header with a number in it", function(s) s.Header = { "a", 5, 2.5, true } end },
    { "a group without a title", function(s) s.Groups[1].Title = nil end },
    { "a group with an empty title", function(s) s.Groups[1].Title = "" end },
    { "a group whose title is a number", function(s) s.Groups[1].Title = 5 end },
    { "a group whose title is a float", function(s) s.Groups[1].Title = 2.5; s.Groups[2].Title = 3.0; s.Groups[3].Title = 1e100 end },
    { "a group whose title is false", function(s) s.Groups[1].Title = false end },
    { "a comment that is a number", function(s) s.Groups[1].Items[1].Comment = 5 end },
    { "a comment with no lines", function(s) s.Groups[1].Items[1].Comment = {} end },
    { "a text with a line break and a tab", function(s) s.Groups[2].Items[2].Default = "line\nbreak\ttab\127end\1" end },
    { "a text with an umlaut", function(s) s.Groups[2].Items[2].Default = "Gr\195\182\195\159e \226\130\172" end },
    { "a text that is not UTF-8", function(s) s.Groups[2].Items[2].Default = "Gr\246\223e" end },
    { "an option with a quote", function(s) s.Groups[2].Items[1].Options = { "a \"b\"", "c\\d", "b" } end },
    { "a hidden item that counts as hidden for any value", function(s) s.Groups[1].Items[3].Hidden = 0; s.Groups[2].Items[1].Hidden = "no" end },
    { "Hidden = false is shown", function(s) s.Groups[3].Items[1].Hidden = false end },
    { "everything of a group hidden", function(s) for _, i in ipairs(s.Groups[1].Items) do i.Hidden = true end end },
    { "Decimals as a text", function(s) s.Groups[1].Items[2].Decimals = "1" end },
    { "Decimals below 0", function(s) s.Groups[1].Items[2].Decimals = -1 end },
    { "Decimals that is true", function(s) s.Groups[1].Items[2].Decimals = true end },
    { "Decimals 15", function(s) s.Groups[1].Items[2].Decimals = 15 end },
    { "a number with decimals whose default has more", function(s) s.Groups[1].Items[2].Default = 0.125 end },
    { "whole numbers with a default that is none", function(s) s.Groups[1].Items[3].Default = 2.5 end },
    { "a negative range", function(s) s.Groups[1].Items[2].Min, s.Groups[1].Items[2].Max, s.Groups[1].Items[2].Default = -5, -1, -2.5 end },
    { "a large whole number", function(s) s.Groups[1].Items[3].Max, s.Groups[1].Items[3].Default = 100000000, 50000 end },
    -- the game's number format fails on these (the app refuses them as a schema)
    { "Decimals as a float", function(s) s.Groups[1].Items[2].Decimals = 2.0 end },
    { "Decimals that are not whole", function(s) s.Groups[1].Items[2].Decimals = 2.5 end },
    { "Decimals as a text with a point", function(s) s.Groups[1].Items[2].Decimals = "2.0" end },
}
for _, m in ipairs(mutations) do changed(m[1], m[2]) end

-- texts Lua does not take, or takes and the app does not (plain values only)
comment("the same, from texts that are not plain values or not Lua at all")
local broken = {
    { "an empty file", "" },
    { "only a comment", "-- nothing here\n" },
    { "returns a number", "return 5\n" },
    { "returns nothing", "local Schema = {}\n" },
    { "a syntax error", "local Schema = {\nreturn Schema\n" },
    { "an unfinished text", "local Schema = { Module = \"xp }\nreturn Schema\n" },
    { "an unfinished long comment", "--[[ never closed\nlocal Schema = {}\nreturn Schema\n" },
    { "a field of nothing", "local t = nil\nreturn t.x\n" },
    { "a call", "os.exit(1)\n" },
    { "text after return", "local Schema = {}\nreturn Schema\nlocal x = 1\n" },
    { "a number with a letter", "local Schema = { PageOrder = 3x }\nreturn Schema\n" },
    { "an unknown escape", "local Schema = { Module = \"a\\qb\" }\nreturn Schema\n" },
}
for _, b in ipairs(broken) do schemaCase(b[1], b[2]) end
-- valid Lua that is more than plain values: the game takes these, the app must refuse them with a reason
comment("plain <name> <text of schema.lua>      (Lua takes it; the app refuses it: not plain values)")
local good = schemaSource(schemaA())
local notPlain = {
    { "arithmetic", (good:gsub("Default = 3,", "Default = 1 + 2,")) },
    { "joined texts", (good:gsub("Label = \"Count\"", "Label = \"Co\" .. \"unt\"")) },
    { "a value in brackets", (good:gsub("Default = 3,", "Default = (3),")) },
    { "a comparison", (good:gsub("Default = true,", "Default = 1 == 1,")) },
    { "not", (good:gsub("Default = true,", "Default = not false,")) },
    { "and / or", (good:gsub("Default = true,", "Default = true and true,")) },
    { "the length of a text", (good:gsub("Default = 3,", "Default = #\"abc\",")) },
    { "a method of a text", (good:gsub("Label = \"Count\"", "Label = (\"count\"):upper()")) },
    { "a control structure", "local Schema = {}\nif true then Schema.Groups = {} end\nreturn Schema\n" },
    { "a function", "local Schema = { Groups = function() end }\nreturn Schema\n" },
    { "nil in a schema", (good:gsub("PageOrder = 10,", "PageOrder = nil,")) },
    { "two minus signs", (good:gsub("Default = 3,", "Default = - -3,")) },
}
for _, p in ipairs(notPlain) do
    local loaded, schema = loadSchema(p[2])
    assert(loaded and type(schema) == "table", p[1] .. ": Lua does not take it")
    assert(p[2] ~= good, p[1] .. ": the text was not changed")
    record("plain", p[1], p[2])
end

-- ---------------------------------------------------------------------------
-- 4. the shipped schemas of the mod
-- ---------------------------------------------------------------------------
comment("real <module> <text of schema.lua> <text of the shipped config.lua> <Settings.defaultText>")
for _, name in ipairs({ "general", "xp" }) do
    local dir = MOD .. "modules/" .. name .. "/Scripts/"
    local text = assert(readFile(dir .. "schema.lua"), "no schema.lua of " .. name)
    local default = assert(S.defaultText(goodSchema(text)))
    SchemaTexts[name] = text
    record("real", name, text, assert(readFile(dir .. "config.lua")), default)
end

-- ---------------------------------------------------------------------------
-- 5. changing one line
-- ---------------------------------------------------------------------------
comment("patch <text> <key> <value text> <result>")
local patches = {
    { "local Config = {}\nConfig.A = 1\nConfig.B = 2\nreturn Config\n", "A", "5" },
    { "Config.A = 1\nreturn Config\n", "A", "5" },
    { "\nConfig.A = 1\nreturn Config\n", "A", "5" },
    { "local Config = {}\n\t  Config.A   =   1   -- old\nreturn Config\n", "A", "5" },
    { "x\r\nConfig.A = 1\r\nreturn Config\r\n", "A", "5" },
    { "-- Config.A = 1\nConfig.A = 2\nreturn Config\n", "A", "5" },
    { "Config.A = 1\nConfig.B = 2\nConfig.A = 3\nreturn Config\n", "A", "5" },
    { "Config.AB = 1\nConfig.BA = 2\nreturn Config\n", "A", "5" },
    { "x = Config.A == 1\nreturn Config\n", "A", "5" },
    { "local Config = {}\r\nreturn Config\r\n", "A", "5" },
    { "local Config = {}\nreturn Config", "A", "5" },
    { "local Config = {}\n  return   Config  \n\n\n", "A", "5" },
    { "return Config\nlocal x\nreturn Config\n", "A", "5" },
    { "Config.B = 1\n\n\nreturn Config\n", "A", "5" },
    { "Config.B = 1\r\n  \r\nreturn Config\r\n", "A", "5" },
    { "\n\nreturn Config\n", "A", "5" },
    { "local Config = {}\n", "A", "5" },
    { "local Config = {}", "A", "5" },
    { "", "A", "5" },
    { "Config.A = \"x\"\nreturn Config\n", "A", "\"a%1b\"" },
    -- more
    { "return Config\n", "A", "5" },
    { "return Config", "A", "5" },
    { "  return Config\n", "A", "5" },
    { "\nreturn Config", "A", "5" },
    { "\r\nreturn Config\r\n", "A", "5" },
    { "local Config = {}\nreturn Config -- the end\n", "A", "5" },
    { "local Config = {}\nreturn Config2\n", "A", "5" },
    { "local Config = {}\nreturn\tConfig\n", "A", "5" },
    { "local Config = {}\nreturn\n\nConfig\n", "A", "5" },
    { "local Config = {}\nreturnConfig\n", "A", "5" },
    { "local Config = {}\nreturn config\n", "A", "5" },
    { "local Config = {}\nreturn Config\n-- after\n", "A", "5" },
    { "local Config = {}\nreturn Config\n\t \r\n\11\12", "A", "5" },
    { "local Config = {}\n-- return Config\nreturn Config\n", "A", "5" },
    { "local Config = {}\nreturn Config\nreturn Config\n", "A", "5" },
    { "local Config = {}\rConfig.A = 1\rreturn Config\r", "A", "5" },
    { "local Config = {}\rreturn Config\r", "A", "5" },
    { "local Config = {}\n\rConfig.A = 1\n\rreturn Config\n\r", "A", "5" },
    { "Config.A = 1", "A", "5" },
    { "Config.A=1", "A", "5" },
    { "Config.A =", "A", "5" },
    { "Config.A", "A", "5" },
    { "Config.A\t\t= 1 -- note\r\nreturn Config\r\n", "A", "5" },
    { "Config . A = 1\nreturn Config\n", "A", "5" },
    { "Config.A == 1\nreturn Config\n", "A", "5" },
    { "Config.a = 1\nreturn Config\n", "A", "5" },
    { "Config.A.B = 1\nreturn Config\n", "A", "5" },
    { "Config.A_ = 1\nConfig._A = 1\nConfig.A1 = 1\nreturn Config\n", "A", "5" },
    { "    Config.A = 1\n\tConfig.A = 2\n  \t Config.A = 3 -- last\nreturn Config\n", "A", "5" },
    { "Config.A = 1\nConfig.A = 2", "A", "5" },
    { "Config.A = 1\n\nConfig.A = 2\n\n", "A", "5" },
    { "\239\187\191Config.A = 1\nreturn Config\n", "A", "5" },
    { "\239\187\191local Config = {}\nConfig.A = 1\nreturn Config\n", "A", "5" },
    { "--[[\nConfig.A = 1\n]]\nlocal Config = {}\nreturn Config\n", "A", "5" },
    { "local Config = {}\nConfig.B = 1 Config.A = 2\nreturn Config\n", "A", "5" },
    { "local Config = { A = 1 }\nreturn Config\n", "A", "5" },
    { "local Config = {}\n\n\n", "A", "5" },
    { "local Config = {}\r\n", "A", "5" },
    { "local Config = {}\r\nConfig.B = 1", "A", "5" },
    { "a\r\nb\nreturn Config\n", "A", "5" },
    { "a\nb\r\n\r\nreturn Config\r\n", "A", "5" },
    { " \n\t\nreturn Config\n", "A", "5" },
    { "Config.B = 1 \t \n \nreturn Config\n", "A", "5" },
    { "Config.B = 1\160\nreturn Config\n", "A", "5" },
    { "Config.B = \"\195\160\"\nreturn Config\n", "A", "5" },
    { "Config.B = 1\n\11\nreturn Config\n", "A", "5" },
    { "local Config = {}\nConfig.Name = \"x\"\nreturn Config\n", "Name", "\"say \\\"hi\\\" \\\\ there\"" },
    { "local Config = {}\nConfig.Name = \"x\"\nreturn Config\n", "Name", "\"\"" },
    { "local Config = {}\nConfig.Long_Key_9 = 1\nreturn Config\n", "Long_Key_9", "true" },
    { "local Config = {}\nConfig.A = 1\nreturn Config\n", "B", "false" },
    { "local Config = {}\n\n-- ---- Main ----\nConfig.A = 1\n\n-- ---- Look ----\nConfig.C = 3\n\nreturn Config\n", "B", "2" },
}
for _, p in ipairs(patches) do patchCase(p[1], p[2], p[3]) end

-- ---------------------------------------------------------------------------
-- 6. reading a config.lua
-- ---------------------------------------------------------------------------
comment("read <schema> <text of config.lua or \\N> <ok | invalid | missing> <keys that were corrected> <key> <value> ...")
local function lines(...) return "local Config = {}\n" .. table.concat({ ... }, "\n") .. "\nreturn Config\n" end
local reads = {
    lines(),
    lines("Config.Enabled = false", "Config.Amount = 4", "Config.Count = 5", "Config.Style = \"c\"", "Config.Name = \"x\"", "Config.Hotkey = \"SHIFT+F5\"", "Config.Secret = 8"),
    "\239\187\191" .. lines("Config.Enabled = false", "Config.Amount = 99", "Config.Count = \"x\"", "Config.Style = \"c\"", "Config.Other = 5", "Config.Secret = 8", "Config.Hotkey = \"shift+f5\""),
    lines("Config.Enabled = false", "Config.Amount = 4"):gsub("\n", "\r\n"),
    lines("Config.Amount = 4"):gsub("\n", "\r"),
    -- switches
    lines("Config.Enabled = \"yes\""), lines("Config.Enabled = 0"), lines("Config.Enabled = nil"), lines("Config.Enabled = {}"), lines("Config.Enabled = \"true\""),
    -- numbers
    lines("Config.Amount = 4.25"), lines("Config.Amount = 0"), lines("Config.Amount = 10"), lines("Config.Amount = 11"), lines("Config.Amount = 10.01"),
    lines("Config.Amount = -1"), lines("Config.Amount = 2.126"), lines("Config.Amount = 2.125"), lines("Config.Amount = 2.135"), lines("Config.Amount = 0.125"),
    lines("Config.Amount = 0.375"), lines("Config.Amount = 1e0"), lines("Config.Amount = 0x4"), lines("Config.Amount = .5"), lines("Config.Amount = 5."),
    lines("Config.Amount = 1e999"), lines("Config.Amount = -1e999"), lines("Config.Amount = -0.001"), lines("Config.Amount = -0.0"), lines("Config.Amount = 0x.8p1"),
    lines("Config.Amount = 0xA.8p0"), lines("Config.Amount = 0x1p-1"), lines("Config.Amount = 2,5"), lines("Config.Amount = 2, 5"), lines("Config.Amount = \"2,5\""),
    lines("Config.Amount = \"3\""), lines("Config.Amount = \" 3.5 \""), lines("Config.Amount = \"0x4\""), lines("Config.Amount = \"1e0\""), lines("Config.Amount = \"0x1p1\""),
    lines("Config.Amount = \"five\""), lines("Config.Amount = \"\""), lines("Config.Amount = \"inf\""), lines("Config.Amount = \"nan\""), lines("Config.Amount = \"+4\""),
    lines("Config.Amount = \"- 4\""), lines("Config.Amount = \"4.\""), lines("Config.Amount = \".4\""), lines("Config.Amount = \"4e\""), lines("Config.Amount = \"4 5\""),
    lines("Config.Amount = \"\\t4\\n\""), lines("Config.Amount = true"), lines("Config.Amount = {}"), lines("Config.Amount = { 4 }"),
    lines("Config.Count = 3"), lines("Config.Count = 3.4"), lines("Config.Count = 3.5"), lines("Config.Count = 4.5"), lines("Config.Count = 99"), lines("Config.Count = 4.0"),
    lines("Config.Count = -5"), lines("Config.Count = \"5\""), lines("Config.Count = \"5.5\""), lines("Config.Count = 0.5"), lines("Config.Count = 0.49999999999999994"),
    lines("Config.Count = 8.5"), lines("Config.Count = 9.4999"), lines("Config.Count = 9223372036854775807"), lines("Config.Count = 9223372036854775808"),
    lines("Config.Count = 0xffffffffffffffff"), lines("Config.Count = 0x7"),
    lines("Config.Secret = 100"), lines("Config.Secret = 100.5"), lines("Config.Secret = \"12\""),
    -- choices
    lines("Config.Style = \"a\""), lines("Config.Style = \"d\""), lines("Config.Style = 1"), lines("Config.Style = \"A\""), lines("Config.Style = \" a\""), lines("Config.Style = 'c'"),
    lines("Config.Style = [[c]]"), lines("Config.Style = true"),
    -- texts
    lines("Config.Name = \"\""), lines("Config.Name = 5"), lines("Config.Name = \"a\\tb\\nc\""), lines("Config.Name = 'single \"quotes\"'"), lines("Config.Name = [[long\ntext]]"),
    lines("Config.Name = [==[\nfirst line break skipped]] ]=] ]==]"), lines("Config.Name = \"\\65\\066\\x43\\u{44}\\u{20AC}\\z\n     E\""), lines("Config.Name = \"line \\\ncontinued\""),
    lines("Config.Name = \"Gr\195\182\195\159e\""), lines("Config.Name = \"Gr\246\223e\""), lines("Config.Name = \"\\a\\b\\f\\v\\r\\\\\\\"\\'\""), lines("Config.Name = \"\\255\\0x\""),
    lines("Config.Name = false"), lines("Config.Name = \"\\u{7FFFFFFF}\\u{800}\\u{10FFFF}\\u{7F}\\u{80}\""),
    -- keys
    lines("Config.Hotkey = \"ctrl + y\""), lines("Config.Hotkey = \"strg+shift+f5\""), lines("Config.Hotkey = \"\""), lines("Config.Hotkey = \"delete\""),
    lines("Config.Hotkey = \"CTRL+NOKEY\""), lines("Config.Hotkey = \"CTRL\""), lines("Config.Hotkey = \"A+B\""), lines("Config.Hotkey = 5"), lines("Config.Hotkey = \" \""),
    lines("Config.Hotkey = \"alt+ctrl+shift+num5\""), lines("Config.Hotkey = \"\196\177\""),
    -- other ways to write a file
    "local Config = { Enabled = false, Amount = 4, }\nreturn Config\n",
    "local C = {}\nC.Amount = 4\nreturn C\n",
    "Config = {}\nConfig.Amount = 4\nreturn Config\n",
    "return { Amount = 4, Count = 5 }\n",
    "return { Amount = 4, Count = 5 }",
    "local Config = {}\nConfig.Amount = 4\nreturn Config;",
    "local Config = {};;\nConfig.Amount = 4; Config.Count = 5;\n;return Config\n",
    "local Config = {} Config.Amount = 4 Config.Count = 5 return Config",
    "local Config = {}\nConfig[\"Amount\"] = 4\nConfig['Count'] = 5\nreturn Config\n",
    "local Config = {}\nConfig.Amount, Config.Count = 4, 5\nreturn Config\n",
    "local Config = {}\nConfig.Amount, Config.Count = 4\nreturn Config\n",
    "local Config = {}\nConfig.Amount = 4, 5, 6\nreturn Config\n",
    "local Config = {}\nConfig.Amount, Config.Amount = 4, 5\nreturn Config\n",
    "local a, b = 4\nlocal Config = { Amount = a, Count = b }\nreturn Config\n",
    "local a, b = 4, 5, 6\nlocal Config = { Amount = a, Count = b }\nreturn Config\n",
    "local Config = {}\nConfig.Amount = 4\nConfig.Amount = 5\nreturn Config\n",
    "local Config = {}\nConfig.Amount = 4\nConfig.Amount = nil\nreturn Config\n",
    "local Config = {}\nlocal Other = Config\nOther.Amount = 4\nreturn Config\n",
    "local Config = {}\nlocal Config = {}\nConfig.Amount = 4\nreturn Config\n",
    "local Config = {}\nConfig.Amount = 4\nlocal Config = {}\nreturn Config\n",
    "Config = { Amount = 4 }\nlocal Config = { Amount = 5 }\nreturn Config\n",
    "local Config = { Amount = 5 }\nConfig = { Amount = 4 }\nreturn Config\n",
    "local x = 4\nlocal Config = {}\nConfig.Amount = x\nConfig.Count = y\nreturn Config\n",
    "local Config = {}\nConfig.Sub = { Amount = 4, List = { 1, 2, 3 } }\nConfig.Amount = Config.Sub.Amount\nConfig.Count = Config.Sub.List[3]\nreturn Config\n",
    "local Config = {}\nConfig.Sub = {}\nConfig.Sub.Deep = {}\nConfig.Sub.Deep.Amount = 4\nConfig.Amount = Config.Sub.Deep.Amount\nreturn Config\n",
    "local Config = {}\nConfig.T = { 1, 2, nil, 4, [\"a b\"] = 1, [5] = 2, [2.5] = 3, [true] = 4; x = 5 }\nConfig.Amount = Config.T[1]\nConfig.Count = Config.T[\"a b\"] \nreturn Config\n",
    "local Config = {}\nConfig.T = { [1] = 7, 8 }\nConfig.Count = Config.T[1]\nreturn Config\n",
    "local Config = {}\nConfig.T = { 4, 5 }\nConfig.T[1] = 6\nConfig.T[3] = 7\nConfig.Amount = Config.T[1]\nConfig.Count = Config.T[3]\nreturn Config\n",
    "local Config = {}\nConfig.T = { [1.0] = 4 }\nConfig.Amount = Config.T[1]\nreturn Config\n",
    "local Config = {}\nlocal t = { a = { b = { 4 } } }\nConfig.Amount = t.a.b[1]\nConfig.Count = t.a.c\nreturn Config\n",
    "local Config = {}\nlocal t = {}\nConfig.Count = t[nil]\nConfig.Amount = 4\nreturn Config\n",
    "--[[ a\nlong comment ]] local Config = {} --[==[ another ]==]\nConfig.Amount = 4 -- a comment\n--[[\nConfig.Amount = 5\n]]\nreturn Config\n",
    "-- only comments in front\n\n\nlocal Config = {}\nConfig.Amount = - 4\nConfig.Count = -3\nreturn Config\n",
    "local Config = {}\nConfig.Amount = 4\nreturn Config, 5\n",
    "local Config = {}\nConfig.Amount = 4\nreturn Config\n\n\n-- the end\n",
    "local\tConfig={}Config.Amount=4;return Config",
    "local Config = {}\nConfig.Amount = 4\nreturn Config\n\26",
    -- not usable for both
    "this is not lua\n",
    "return 5\n",
    "return\n",
    "return nil\n",
    "return \"Config\"\n",
    "",
    "\n\n",
    "local Config = {}\nConfig.Amount = 4\n",
    "local Config = {}\nConfig.Amount = \nreturn Config\n",
    "local Config = {}\nlocal t = nil\nConfig.Amount = t.x\nreturn Config\n",
    "local Config = {}\nConfig.Sub.Amount = 4\nreturn Config\n",
    "local Config = {}\nConfig.Amount = 4\nreturn Config\nConfig.Count = 5\n",
    "local Config = {}\nConfig.Amount = 4\nreturn Config\nreturn Config\n",
    "local Config = {}\nConfig.Amount = 4x\nreturn Config\n",
    "local Config = {}\nConfig.Amount = 1..2\nreturn Config\n",
    "local Config = {}\nConfig.Amount = 0x\nreturn Config\n",
    "local Config = {}\nConfig.Amount = 1e\nreturn Config\n",
    "local Config = {}\nConfig.Name = \"unfinished\nreturn Config\n",
    "local Config = {}\nConfig.Name = \"bad \\q escape\"\nreturn Config\n",
    "local Config = {}\nConfig.Name = \"\\256\"\nreturn Config\n",
    "local Config = {}\nConfig.Name = \"\\xZZ\"\nreturn Config\n",
    "local Config = {}\nConfig.Name = \"\\u{110000000}\"\nreturn Config\n",
    "local Config = {}\nConfig.Name = [[never closed\nreturn Config\n",
    "local Config = {}\n--[[ never closed\nreturn Config\n",
    "local Config = {}\nConfig.end = 4\nreturn Config\n",
    "local Config = {}\nConfig.T = { [nil] = 4 }\nreturn Config\n",
    "local Config = {}\nlocal t = {}\nt[nil] = 4\nreturn Config\n",
    "local Config = {}\nConfig.T = { 1, 2\nreturn Config\n",
    "local Config = {}\nConfig.T = { 1 2 }\nreturn Config\n",
    "local Config = {}\nConfig.Amount == 4\nreturn Config\n",
    "local Config = {}\nConfig.Amount = = 4\nreturn Config\n",
    "local Config = {}\nConfig.Amount 4\nreturn Config\n",
    "local Config = {}\n= 4\nreturn Config\n",
    "local Config = {}\n5 = 4\nreturn Config\n",
    "local Config = {}\nConfig.Amount = 4 5\nreturn Config\n",
    "local Config = {}\nConfig.5 = 4\nreturn Config\n",
    "local Config = {}\nlocal 5 = 4\nreturn Config\n",
    "local Config = {}\nlocal = 4\nreturn Config\n",
    "local Config = {}\nConfig.Amount = @\nreturn Config\n",
    "local Config = {}\nlocal x = 5\nConfig.Amount = x.y\nreturn Config\n",
    "local Config = {}\nlocal x = true\nx.y = 5\nreturn Config\n",
    "local Config = {}\nConfig.Amount = \"a\" \"b\"\nreturn Config\n",
    "local Config = {}}\nreturn Config\n",
    "\239\187\191\239\187\191local Config = {}\nreturn Config\n",
    "#!/usr/bin/lua\nlocal Config = {}\nreturn Config\n",
}
readCase("A", nil)
for _, text in ipairs(reads) do readCase("A", text) end
readCase("allkinds", nil)
readCase("allkinds", lines("Config.Fine = 0.1255", "Config.Tenth = 9.96", "Config.Whole = -10.5", "Config.Large = 1e8", "Config.Mode = \"the third and longest of the choices\"",
    "Config.Other = \"shift+num0\"", "Config.SecretText = \"y\"", "Config.Greeting = \"\"", "Config.Last = false"))
readCase("hand", lines("Config.A = 31.96", "Config.B = \"z\\\\\"", "Config.D = 'q'", "Config.E = 'mouse4'", "Config.F = 0"))
readCase("xp", readFile(MOD .. "modules/xp/Scripts/config.lua"))
readCase("xp", lines("Config.Multiplier = 4", "Config.LargeGainFrom = 250.5", "Config.MaxGain = 20000", "Config.CheckMilliseconds = 10"))
readCase("general", readFile(MOD .. "modules/general/Scripts/config.lua"))
readCase("general", lines("Config.NoteStyle = \"subtitle\"", "Config.NotePosition = \"bottom left\"", "Config.NoteSeconds = 12"))

-- valid Lua that is more than plain values: the game reads these, the app must call them not valid
comment("code <text of config.lua>      (Lua takes it; the app: not valid, because it is more than plain values)")
for _, text in ipairs({
    lines("Config.Amount = 2 + 2"), lines("Config.Amount = 2 * 2"), lines("Config.Amount = (4)"), "local Config = {}\nConfig.Amount = 4\nreturn (Config)\n", lines("Config.Name = \"a\" .. \"b\""), lines("Config.Enabled = not true"),
    lines("Config.Enabled = 1 == 1"), lines("Config.Enabled = true and false"), lines("Config.Amount = #\"four\""), lines("Config.Amount = 8 / 2"), lines("Config.Amount = 2 ^ 2"),
    lines("Config.Amount = 9 // 2"), lines("Config.Amount = 9 % 5"), lines("Config.Amount = -(-4)"), lines("Config.Amount = - -4"), lines("Config.Name = (\"x\"):rep(3)"),
    lines("Config.Amount = 4 < 5"), lines("Config.Amount = 1 << 2"), lines("Config.Amount = ~3"), lines("Config.Amount = 4 or 5"), lines("if true then Config.Amount = 4 end"),
    lines("do Config.Amount = 4 end"), lines("for i = 1, 4 do Config.Amount = i end"), lines("local function f() return 4 end", "Config.Amount = f()"),
    lines("Config.F = function() end"), lines("local x <const> = 4", "Config.Amount = x"), lines("Config.Amount = (\"4\") + 0"), lines("goto done", "::done::"),
    lines("while false do end"), lines("repeat until true"), lines("local s = \"abc\"", "Config.Amount = s.len"),
}) do
    assert(S._test.parse(text), "not valid Lua: " .. text)
    record("code", text)
end

-- ---------------------------------------------------------------------------
-- 7. changing values (the module's settings, as the game changes them)
-- ---------------------------------------------------------------------------
comment("apply <name> <schema> <text of config.lua at the start or \\N> <steps> then per step:")
comment("  set <pairs> <key> <value> ... <changed keys> <text of config.lua after it or \\N> | disk <text or \\N> | reset <changed keys> <text after it>")
local function set(values) return { set = values } end
local TEXT_A = assert(S.defaultText(goodSchema(SchemaTexts.A)))
local NOTES = "-- my notes\nlocal Config = {}\n  Config.Extra = 1\nConfig.Enabled = true\nConfig.Amount = 2.5 -- was 3\nConfig.Mine = \"keep\"\nreturn Config\n"

scenario("one value", "A", TEXT_A, { set({ Amount = 4 }) })
scenario("the same value again", "A", TEXT_A, { set({ Amount = 4 }), set({ Amount = 4 }), set({ Amount = 4.001 }) })
scenario("nothing changes", "A", TEXT_A, { set({ Amount = 2.5, Enabled = true, Style = "b", Hotkey = "ctrl+y" }) })
scenario("every kind", "A", TEXT_A, { set({ Enabled = false, Amount = 7.25, Count = 9, Style = "c", Name = "new \"text\" \\ here", Hotkey = "SHIFT+ALT+F5" }) })
scenario("comments, unknown keys and their order stay", "A", NOTES, { set({ Amount = 4 }), set({ Amount = 50 }),
    set({ Count = 4.6, Style = "c", Enabled = false, Unknown = 1, Hotkey = "alt+f1" }), set({ Secret = 9 }), { reset = true } })
scenario("values out of range and of the wrong kind", "A", TEXT_A, { set({ Amount = 99 }), set({ Amount = -5, Count = 100 }), set({ Count = 0 }),
    set({ Style = "z" }), set({ Amount = "7.5" }), set({ Hotkey = "nokey" }), set({ Enabled = "no" }), set({ Count = 2.5 }), set({ Amount = 3.14159 }) })
scenario("keys without a line", "A", "local Config = {}\nreturn Config\n", { set({ Hotkey = "F5" }), set({ Enabled = false, Name = "n", Count = 5, Style = "a", Amount = 1 }) })
scenario("keys without a line, all at once", "A", "local Config = {}\n\n\nreturn Config\n", { set({ Hotkey = "F5", Enabled = false, Name = "n", Count = 5, Style = "a", Amount = 1, Secret = 1 }) })
scenario("line ends of Windows", "A", (TEXT_A:gsub("\n", "\r\n")), { set({ Amount = 4, Style = "a" }), set({ Secret = 9 }) })
scenario("line ends of Windows, a line is added", "A", "local Config = {}\r\nConfig.Enabled = true\r\n\r\nreturn Config\r\n", { set({ Amount = 4, Style = "a" }) })
scenario("a byte order mark", "A", "\239\187\191" .. TEXT_A, { set({ Amount = 4 }), set({ Enabled = false }) })
scenario("a byte order mark in front of the key's line", "A", "\239\187\191Config = {}\nConfig.Amount = 3\nreturn Config\n", { set({ Amount = 4 }) })
scenario("a key twice", "A", "local Config = {}\nConfig.Amount = 1\nConfig.Count = 2\nConfig.Amount = 3\nreturn Config\n", { set({ Amount = 4 }), set({ Count = 5 }) })
scenario("indentation and a comment behind the value", "A", "local Config = {}\n\t  Config.Amount   =   1   -- old\n    Config.Style = 'a' -- one\nreturn Config\n",
    { set({ Amount = 4, Style = "c" }) })
scenario("a value the file has in another spelling", "A", "local Config = {}\nConfig.Amount = 4.000\nConfig.Hotkey = 'ctrl + y'\nConfig.Count = '5'\nreturn Config\n",
    { set({ Amount = 4, Hotkey = "CTRL+Y", Count = 5 }), set({ Amount = 5 }) })
scenario("a value the file has out of range", "A", "local Config = {}\nConfig.Amount = 99\nConfig.Count = 0\nreturn Config\n",
    { set({ Amount = 10, Count = 1 }), set({ Amount = 9 }) })
scenario("no return line", "A", "Config = {}\nConfig.Amount = 3", { set({ Count = 4 }) })
scenario("no file", "A", nil, { set({ Amount = 4 }) })
scenario("no file, nothing changes, then something", "A", nil, { set({ Amount = 2.5 }), set({ Style = "c", Secret = 3 }) })
scenario("the file goes away", "A", NOTES, { set({ Amount = 4, Secret = 9 }), { disk = false }, set({ Amount = 7.5 }), { disk = "broken (\n" }, set({ Amount = 8 }) })
scenario("a broken file from the start", "A", "this is not lua\n", { set({ Count = 4 }) })
scenario("a broken file from the start, nothing changes", "A", "this is not lua\n", { set({ Count = 3 }) })
scenario("a file that returns no table", "A", "return 5\n", { set({ Count = 4, Hotkey = "" }) })
scenario("the other side changes the file", "A", TEXT_A, { set({ Amount = 4 }), { disk = (TEXT_A:gsub("Config.Count = 3", "Config.Count = 8"):gsub("Config.Amount = 2.5", "Config.Amount = 4.0")) },
    set({ Style = "c" }), { disk = (TEXT_A:gsub("Config.Count = 3", "Config.Count = 6 -- by hand")) }, set({ Count = 6, Amount = 2.5, Style = "b" }), set({ Count = 7 }) })
scenario("the other side adds comments and keys", "A", TEXT_A, { { disk = "-- mine\n" .. TEXT_A:gsub("\nreturn Config", "Config.Mine = { 1, 2 }\n\nreturn Config") }, set({ Enabled = false }) })
scenario("the other side breaks the file", "A", TEXT_A, { set({ Amount = 4, Secret = 5 }), { disk = "local Config = {\n" }, set({ Count = 5 }) })
scenario("reset", "A", NOTES, { set({ Amount = 4, Count = 5, Secret = 9, Hotkey = "" }), { reset = true }, { reset = true } })
scenario("a line in a comment block", "A", "local Config = {}\n--[[\nConfig.Amount = 1\n]]\nreturn Config\n", { set({ Amount = 4 }) })
scenario("return Config in a comment at the end", "A", "local Config = {}\nreturn Config\n--[[\nreturn Config\n]]\n", { set({ Amount = 4 }), set({ Amount = 5 }) })
scenario("texts", "A", TEXT_A, { set({ Name = "" }), set({ Name = "tab\there, line\nbreak, bell\7, del\127" }), set({ Name = "Gr\195\182\195\159e \226\130\172 100 %" }),
    set({ Name = "a\\b\"c" }), set({ Name = "%1 %%" }), set({ Name = 5 }) })
scenario("all kinds", "allkinds", nil, { set({ Feature = true, Whole = 995, Tenth = 9.96, Fine = -0.9995, Large = 100000000, Mode = "first", Greeting = "", Empty = "full",
    Hotkey = "", Other = "ctrl+shift+alt+middle_mouse_button", Last = false }), set({ Fine = 0.0004, Tenth = 0.04, Whole = -9.5, Secret = 100, SecretText = "y" }), { reset = true } })
scenario("xp: the player's values", "xp", readFile(MOD .. "modules/xp/Scripts/config.lua"), { set({ Multiplier = 4 }), set({ LargeGainFrom = 500, LargeGainMultiplier = 2.5, ShowMessage = false }),
    set({ MaxGain = 20000 }), set({ Enabled = false, LogGains = true }), { reset = true } })
scenario("general", "general", readFile(MOD .. "modules/general/Scripts/config.lua"), { set({ NoteStyle = "subtitle", NotePosition = "bottom left", NoteSeconds = 10 }), set({ NoteSeconds = 0 }) })

end

sh("rm -rf " .. q(WORK))
local f = assert(io.open(OUT, "wb"))
f:write(CASES and "# What the game's code gives for the cases of a cases file.\n" or "# Fixtures of the settings app's tests - written by filetests/gen_fixtures.lua, do not edit.\n",
    table.concat(out, "\n"), "\n")
f:close()
io.write(#out, " lines written to ", OUT, "\n")
