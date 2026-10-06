-- ============================================================================
-- Settings of the modules: one description (schema.lua) per module drives
--   * the module's config.lua (its default text, reading, checking, changing),
--   * the page in the settings app (the app reads the same schema.lua),
--   * the entry in the in-game mod menu (the mod "SharedModMenu", if installed).
--
--   local S = G1R_SETTINGS.open({ module = "xp", dir = SCRIPT_DIR, log = log, onChange = f })
--   S.values.Multiplier        always there, always of the right kind and in range
--   S:set("Multiplier", 2)     checks the value, writes it into config.lua, calls onChange
--
-- A changed config.lua is read again while the game runs; values changed in
-- the in-game menu are written into config.lua. Only the line of a changed
-- value is rewritten; comments and everything else in the file stay.
--
-- The schema (see dev/SETTINGS.md): Module, Page, PageOrder, Header, Groups =
-- { { Title, Hint, Items = { { Key, Kind = "bool" | "number" | "choice" |
-- "text" | "key" | "action", Default, Min, Max, Step, Decimals, Options,
-- Label, Unit, Comment, Needs, Hidden } } } }. An "action" has no value: it
-- is a button in the in-game menu (the module's onAction gets its key).
--
-- The in-game menu is reached through UE4SS shared variables (the menu mod's
-- published format: "SMM:index", "SMM:schema:<name>", "SMM:values:<name>",
-- "SMM:cmd:<name>"). Without that mod the variables are simply never read.
-- Nothing here calls into the game. The loader runs this file in an
-- environment of its own ("settings") and calls Settings.tick() four times a
-- second on the game thread.
-- ============================================================================

local Settings = {}

local pcall, type, tostring, tonumber, ipairs, pairs, load = pcall, type, tostring, tonumber, ipairs, pairs, load
local floor, min, max, huge = math.floor, math.min, math.max, math.huge
local concat, sort = table.concat, table.sort
local clock = os.clock

local RELOAD_SECONDS = 5            -- how often a module's config.lua is looked at
local Opened = {}                   -- settings objects, in the order they were opened
local Print = print
local KIT = G1R_KIT                 -- for the spelling of keys; nil when the kit could not be loaded

-- ---------------------------------------------------------------------------
-- Text helpers
-- ---------------------------------------------------------------------------
local function readText(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
end
-- Writes a file so that a complete copy of it exists at every moment. The
-- new text goes into "<path>.tmp" and is read back; only then the file that
-- is there becomes "<path>.bak" (the settings app keeps the file before its
-- own save under the same name) and the new one takes its place. Plain Lua
-- cannot replace a file in one step on Windows - os.rename does not overwrite -
-- so between the two renames the file itself is missing for an instant; the
-- settings app waits when it sees that, and a start after a crash at that
-- instant finds the complete "<path>.tmp" (recover, below).
-- base: what the file held when the new text was made from it (a string, or
-- false for "there was no file"). When the file holds something else by now -
-- the settings app saved in between - nothing is written and the reason is
-- "changed". nil: not looked at.
-- Returns true, or false and what went wrong; the old file is then untouched
-- or back in its place.
local function writeText(path, text, base)
    local tmp, bak = path .. ".tmp", path .. ".bak"
    local f, err = io.open(tmp, "wb")
    if not f then return false, "cannot open " .. tmp .. (err and (": " .. tostring(err)) or "") end
    local okWrite, errWrite = f:write(text)
    local okClose, errClose = f:close()
    if not okWrite then
        os.remove(tmp)
        return false, "writing failed: " .. tostring(errWrite)
    end
    if not okClose then
        os.remove(tmp)
        return false, "closing failed: " .. tostring(errClose)
    end
    if readText(tmp) ~= text then           -- what is on disk must be what was meant
        os.remove(tmp)
        return false, "the new file does not read back"
    end
    local now = readText(path)
    if base ~= nil and now ~= (base or nil) then
        os.remove(tmp)
        return false, "changed"
    end
    if now ~= nil then
        os.remove(bak)
        local okAside, errAside = os.rename(path, bak)
        if not okAside then
            os.remove(tmp)
            return false, "the file that is there cannot be moved aside: " .. tostring(errAside)
        end
    end
    local ok, errPlace = os.rename(tmp, path)
    if not ok then
        if now ~= nil then os.rename(bak, path) end         -- the old file goes back
        os.remove(tmp)
        return false, "the new file cannot be put in place: " .. tostring(errPlace)
    end
    return true
end
-- A write that was cut off between its two renames (see writeText): the file
-- is missing and "<path>.tmp" holds the complete new text. It is put in place.
-- `usable`: a function that says whether a text is a file of the expected
-- kind. Returns the text, or nil when there was nothing to finish.
local function recover(path, usable)
    if readText(path) ~= nil then return nil end
    local tmp = path .. ".tmp"
    local text = readText(tmp)
    if text == nil or not usable(text) then return nil end
    if not os.rename(tmp, path) then return nil end
    return text
end
Settings._writeText, Settings._recover, Settings._readText = writeText, recover, readText

-- A number as it is written into config.lua: whole numbers plain, others with
-- at most `decimals` places and at least one ("1.0", "2.5", "0.75").
local function numberText(v, decimals)
    decimals = tonumber(decimals) or 0
    if decimals <= 0 then return ("%d"):format(floor(v + 0.5)) end
    local s = ("%." .. decimals .. "f"):format(v)
    s = s:gsub("0+$", "")
    if s:sub(-1) == "." then s = s .. "0" end
    if s == "-0.0" then s = "0.0" end
    return s
end
local function literal(item, v)
    if item.Kind == "bool" then return v and "true" or "false" end
    if item.Kind == "number" then return numberText(v, item.Decimals) end
    return '"' .. tostring(v):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("[%c]", " ") .. '"'
end
Settings.numberText = numberText

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
local KINDS = { bool = true, number = true, choice = true, text = true, key = true, action = true }

-- The usual spelling of a key combination ("ctrl + y" -> "CTRL+Y", "" = no
-- key), or nil when it names no key.
local function keyText(text)
    if type(text) ~= "string" then return nil end
    if KIT and type(KIT.keyCombo) == "function" then return (KIT.keyCombo(text)) end
    local compact = text:gsub("%s+", ""):upper()       -- without the kit only the spelling is tidied
    if compact:find("[^%w_+]") then return nil end
    return compact
end
Settings.keyText = keyText

-- Checks a schema and returns its items with a value in file order, the same
-- by key, and the actions by key - or nil and what is wrong.
local function itemsOf(schema)
    if type(schema) ~= "table" or type(schema.Groups) ~= "table" then return nil, "the schema has no Groups" end
    local items, byKey, actions = {}, {}, {}
    for gi, group in ipairs(schema.Groups) do
        if type(group) ~= "table" or type(group.Items) ~= "table" then return nil, "group " .. gi .. " has no Items" end
        for _, item in ipairs(group.Items) do
            local key = type(item) == "table" and item.Key or nil
            if type(key) ~= "string" or not key:match("^[%a_][%w_]*$") then return nil, "an item of group " .. gi .. " has no usable Key" end
            if byKey[key] or actions[key] then return nil, "the key " .. key .. " is used twice" end
            if not KINDS[item.Kind] then return nil, key .. ": unknown Kind " .. tostring(item.Kind) end
            if item.Kind == "bool" and type(item.Default) ~= "boolean" then return nil, key .. ": Default must be true or false" end
            if item.Kind == "number" then
                if type(item.Default) ~= "number" or type(item.Min) ~= "number" or type(item.Max) ~= "number" or item.Min > item.Max
                    or item.Default < item.Min or item.Default > item.Max then
                    return nil, key .. ": Default, Min and Max must be numbers with Min <= Default <= Max"
                end
            end
            if item.Kind == "choice" then
                local found = false
                if type(item.Options) ~= "table" or #item.Options == 0 then return nil, key .. ": Options are missing" end
                for _, o in ipairs(item.Options) do
                    if type(o) ~= "string" then return nil, key .. ": Options must be texts" end
                    if o == item.Default then found = true end
                end
                if not found then return nil, key .. ": Default is not one of the Options" end
            end
            if item.Kind == "text" and type(item.Default) ~= "string" then return nil, key .. ": Default must be a text" end
            if item.Kind == "key" and (type(item.Default) ~= "string" or keyText(item.Default) ~= item.Default) then
                return nil, key .. ": Default must be a key in its usual spelling (\"Y\", \"CTRL+Y\") or \"\""
            end
            if item.Needs ~= nil and type(item.Needs) ~= "string" then return nil, key .. ": Needs must name a key" end
            if item.Kind == "action" then
                actions[key] = item
            else
                byKey[key] = item
                items[#items + 1] = item
            end
        end
    end
    for _, group in ipairs(schema.Groups) do
        for _, item in ipairs(group.Items) do
            if item.Needs and not (byKey[item.Needs] and byKey[item.Needs].Kind == "bool") then
                return nil, item.Key .. ": Needs names " .. item.Needs .. ", which is not a yes/no item"
            end
        end
    end
    if #items == 0 then return nil, "the schema has no items" end
    return items, byKey, actions
end
Settings.itemsOf = itemsOf

local function commentLines(out, comment)
    if type(comment) == "string" then comment = { comment } end
    if type(comment) ~= "table" then return end
    for _, l in ipairs(comment) do out[#out + 1] = "-- " .. tostring(l) end
end

-- The text of a config.lua that holds the defaults (what the mod ships).
function Settings.defaultText(schema)
    local items, why = itemsOf(schema)
    if not items then return nil, why end
    local out = {}
    local bar = "-- " .. ("="):rep(76)
    out[#out + 1] = bar
    commentLines(out, schema.Header or { "Settings of the module " .. tostring(schema.Module) })
    out[#out + 1] = bar
    out[#out + 1] = "local Config = {}"
    for _, group in ipairs(schema.Groups) do
        local shown = false
        for _, item in ipairs(group.Items) do
            if not item.Hidden and item.Kind ~= "action" then
                if not shown then
                    out[#out + 1] = ""
                    if group.Title then out[#out + 1] = "-- ---- " .. tostring(group.Title) .. " ----" end
                    shown = true
                end
                commentLines(out, item.Comment)
                out[#out + 1] = "Config." .. item.Key .. " = " .. literal(item, item.Default)
            end
        end
    end
    out[#out + 1] = ""
    out[#out + 1] = "return Config"
    return concat(out, "\n") .. "\n"
end

-- ---------------------------------------------------------------------------
-- Values
-- ---------------------------------------------------------------------------
-- A value of the right kind and in range for the item, and whether the given
-- one had to be changed for that.
local function checked(item, v)
    if item.Kind == "bool" then
        if type(v) == "boolean" then return v, false end
        return item.Default, v ~= nil
    elseif item.Kind == "number" then
        local n = tonumber(v)
        if n == nil or n ~= n then return item.Default, v ~= nil end
        local c = max(item.Min, min(item.Max, n))
        local decimals = tonumber(item.Decimals) or 0
        if decimals <= 0 then
            c = floor(c + 0.5)
        else
            c = tonumber(numberText(c, decimals))       -- as it stands in the file
        end
        return c, c ~= n or type(v) ~= "number"
    elseif item.Kind == "choice" then
        for _, o in ipairs(item.Options) do
            if o == v then return v, false end
        end
        return item.Default, v ~= nil
    elseif item.Kind == "key" then
        local usual = keyText(v)
        if usual ~= nil then return usual, false end       -- another spelling of a key is no mistake
        return item.Default, v ~= nil
    end
    if type(v) == "string" then return v, false end
    return item.Default, v ~= nil
end

local function parse(text)
    if type(text) ~= "string" then return nil, "config.lua not found" end
    text = text:gsub("^\239\187\191", "")       -- byte order mark of some editors
    local chunk, err = load(text, "=config.lua", "t", {})
    if not chunk then return nil, err end
    local ok, v = pcall(chunk)
    if not ok then return nil, v end
    if type(v) ~= "table" then return nil, "config.lua did not return a table" end
    return v
end

-- Sets the value of one key in the text of a config.lua: the last line
-- "Config.<Key> = ..." (the one Lua goes by) gets the new value; without such
-- a line one is added below the last line with text in front of "return
-- Config". Everything else stays as it is.
local function patch(text, key, valueText)
    local line = "Config." .. key .. " = " .. valueText
    local pattern = "Config%." .. key .. "[ \t]*=[^\r\n]*"
    local s, e = text:find("^[ \t]*" .. pattern)
    local from = 1
    while true do
        local s2, e2 = text:find("\n[ \t]*" .. pattern, from)
        if not s2 then break end
        s, e, from = s2 + 1, e2, e2
    end
    if s then
        local indent = text:sub(s, e):match("^[ \t]*")
        return text:sub(1, s - 1) .. indent .. line .. text:sub(e + 1)
    end
    local newline = text:find("\r\n", 1, true) and "\r\n" or "\n"
    local rs = text:find("\n[ \t]*return%s+Config[^\n]*%s*$")
    if rs then
        -- after the last line with text in front of the return: empty lines stay in front of it
        local head = text:sub(1, rs)
        local body = head:gsub("%s*$", "")
        if body == "" then return line .. newline .. text end
        return body .. newline .. line .. head:sub(#body + 1) .. text:sub(rs + 1)
    end
    if text ~= "" and text:sub(-1) ~= "\n" then text = text .. newline end
    return text .. line .. newline
end
Settings.patch = patch

-- ---------------------------------------------------------------------------
-- The in-game mod menu (shared variables)
-- ---------------------------------------------------------------------------
local GS, RS, FS = "\29", "\30", "\31"
local Menu = { pages = {}, order = {}, dirty = {}, available = nil }

local function shared(name)
    local ok, v = pcall(function() return ModRef:GetSharedVariable(name) end)
    if ok then return v end
    return nil
end
local function share(name, value)
    return (pcall(function() ModRef:SetSharedVariable(name, value) end))
end
local function clean(s) return (tostring(s):gsub("[\29\30\31]", " ")) end        -- the separators of the format
-- The menu mod draws every row on one line and cuts what is longer than its columns (its viewmath.lua):
-- an item's name after 35 characters, its hint after 54, the name of a tab or a sub-tab after 28. The
-- texts published here are made to fit; the schemas give short texts where their own are longer
-- (MenuLabel, Menu, MenuTitle).
local NAME_MAX, HINT_MAX, TAB_MAX = 35, 54, 28
-- A text cut to n characters at a word, with three dots (only for a text a schema did not make short enough).
local function fit(s, n)
    if #s <= n then return s end
    local head = s:sub(1, n - 3)
    if s:sub(n - 2, n - 2):find("%S") then         -- the cut falls inside a word: back to the word break before it
        local word = head:match("^(.*%S)%s+%S*$")
        if word and #word >= n // 2 then head = word end
    end
    return (head:gsub("%s+$", "")) .. "..."
end
-- A page's name in the menu's list (that list is separated by commas).
local function menuName(page) return "G1R " .. (clean(page):gsub(",", " ")) end
-- An item's name: its MenuLabel, else its Label with the unit behind it when that fits.
local function menuLabel(item)
    if type(item.MenuLabel) == "string" then return fit(clean(item.MenuLabel), NAME_MAX) end
    local label = clean(item.Label or item.Key)
    if item.Unit then
        local full = label .. " (" .. clean(item.Unit) .. ")"
        if #full <= NAME_MAX then return full end
    end
    return fit(label, NAME_MAX)
end
-- The hint beside an item. A choice: its options by number when they fit, else the option it has now.
-- Anything else: its Menu text, else the first sentence of its comment.
local function menuHint(item, value)
    if item.Kind == "choice" then
        local names = {}
        for i, o in ipairs(item.Options) do names[#names + 1] = i .. " = " .. clean(o) end
        local list = concat(names, ", ")
        if #list <= HINT_MAX then return list end
        for i, o in ipairs(item.Options) do
            if o == value then return fit(("now: %s (%d of %d)"):format(clean(o), i, #item.Options), HINT_MAX) end
        end
        return fit(list, HINT_MAX)
    end
    if type(item.Menu) == "string" then return fit(clean(item.Menu), HINT_MAX) end
    local comment = type(item.Comment) == "table" and concat(item.Comment, " ") or tostring(item.Comment or "")
    local first = comment:match("^(.-[%.!?])%s") or comment
    return fit(clean(first), HINT_MAX)
end
-- A group's sub-tab: its MenuTitle, else its Title without the page's name in front ("Mining: how long a
-- vein lasts" under the tab "G1R Mining" is "How long a vein lasts").
local function menuTitle(group, pageTitle)
    if type(group.MenuTitle) == "string" then return fit(clean(group.MenuTitle), TAB_MAX) end
    local title = clean(group.Title or "")
    local rest = title:match("^" .. clean(pageTitle):gsub("%p", "%%%0") .. ":%s*(%S.*)$")
    if rest then title = rest:sub(1, 1):upper() .. rest:sub(2) end
    return fit(title, TAB_MAX)
end
local function menuItems(page)          -- flat list of { object, item } in menu order
    local flat = {}
    for _, section in ipairs(page.sections) do
        for _, entry in ipairs(section.entries) do flat[#flat + 1] = entry end
    end
    return flat
end
local function menuKind(item)
    if item.Kind == "bool" then return "bool" end
    if item.Kind == "number" or item.Kind == "choice" then return "num" end
    if item.Kind == "action" then return "action" end
    return nil                          -- texts and keys cannot be edited in the menu
end
local function menuValue(entry)
    local item, v = entry.item, entry.object.values[entry.item.Key]
    if item.Kind == "action" then return "x" end
    if item.Kind == "bool" then return v and "b1" or "b0" end
    if item.Kind == "choice" then
        for i, o in ipairs(item.Options) do
            if o == v then return "n" .. i end
        end
        return "n1"
    end
    return "n" .. tostring(v)
end

-- Publishes the page's schema when its text is not the one published last (a choice's hint can follow its
-- value). Returns true when it was published.
local function publishSchema(page)
    local sections = {}
    for _, section in ipairs(page.sections) do
        local parts = { section.menuTitle or "" }
        for _, entry in ipairs(section.entries) do
            local item = entry.item
            local lo, hi, step = "", "", ""
            if item.Kind == "number" then
                lo, hi, step = tostring(item.Min), tostring(item.Max), tostring(item.Step or 1)
            elseif item.Kind == "choice" then
                lo, hi, step = "1", tostring(#item.Options), "1"
            end
            parts[#parts + 1] = concat({ menuLabel(item), menuKind(item), lo, hi, step, menuHint(item, entry.object.values[item.Key]) }, FS)
        end
        sections[#sections + 1] = concat(parts, RS)
    end
    local text = concat(sections, GS)
    if text == page.published then return false end
    if not share("SMM:schema:" .. page.name, text) then return false end
    page.published = text
    return true
end
local function publishValues(page)
    local tokens = {}
    for _, entry in ipairs(menuItems(page)) do tokens[#tokens + 1] = menuValue(entry) end
    share("SMM:values:" .. page.name, concat(tokens, RS))
end
local function register(page)
    local index = shared("SMM:index")
    if type(index) ~= "string" then index = "" end
    for name in index:gmatch("[^,]+") do
        if name == page.name then return end
    end
    share("SMM:index", index == "" and page.name or (index .. "," .. page.name))
end

-- Puts a settings object into its page of the menu.
local function addToMenu(object)
    if Menu.available == nil then
        local ok, has = pcall(function() return ModRef.GetSharedVariable ~= nil and ModRef.SetSharedVariable ~= nil end)
        Menu.available = ok and has == true
    end
    if not Menu.available then return end
    local schema = object.schema
    local title = tostring(schema.Page or schema.Module or object.module)
    local page = Menu.pages[title]
    if not page then
        page = { title = title, name = menuName(title), sections = {} }      -- the menu shows its pages in the order they were registered
        Menu.pages[title] = page
        Menu.order[#Menu.order + 1] = page
    end
    for _, group in ipairs(schema.Groups) do
        local entries = {}
        for _, item in ipairs(group.Items) do
            if not item.Hidden and menuKind(item) then entries[#entries + 1] = { object = object, item = item } end
        end
        if #entries > 0 then
            page.sections[#page.sections + 1] = { title = group.Title, menuTitle = menuTitle(group, title), order = tonumber(group.Order) or 100,
                module = object.module, entries = entries, seq = #page.sections }
        end
    end
    sort(page.sections, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        if a.module ~= b.module then return a.module < b.module end
        return a.seq < b.seq
    end)
    publishSchema(page)
    publishValues(page)
    register(page)
    share("SMM:refresh", (tonumber(shared("SMM:refresh")) or 0) + 1)
end

-- Edits the menu queued for a page: "index FS value" records.
local function takeCommands(page)
    local key = "SMM:cmd:" .. page.name
    local text = shared(key)
    if type(text) ~= "string" or text == "" then return end
    share(key, "")                      -- first, so that a failing edit is not applied again and again
    local flat = menuItems(page)
    local changes = {}                  -- object -> { key = value }
    local order = {}                    -- the objects in the order of their first edit
    local actions = {}                  -- { object, key }, in the order they were asked for
    for record in text:gmatch("[^\30]+") do
        local index, token = record:match("^(%d+)\31(.*)$")
        local entry = flat[tonumber(index) or 0]
        if entry then
            local item, value = entry.item, nil
            local tag, rest = token:sub(1, 1), token:sub(2)
            if item.Kind == "action" then
                actions[#actions + 1] = { entry.object, item.Key }
            elseif item.Kind == "bool" and tag == "b" then
                value = rest == "1"
            elseif item.Kind == "number" and tag == "n" then
                value = tonumber(rest)
            elseif item.Kind == "choice" and tag == "n" then
                value = item.Options[floor((tonumber(rest) or 0) + 0.5)]
            end
            if value ~= nil then
                if not changes[entry.object] then
                    changes[entry.object] = {}
                    order[#order + 1] = entry.object
                end
                changes[entry.object][item.Key] = value
            end
        end
    end
    for _, object in ipairs(order) do object:apply(changes[object], "menu") end
    for _, a in ipairs(actions) do
        local object, key = a[1], a[2]
        if type(object.onAction) == "function" then
            local ok, err = pcall(object.onAction, key, "menu")
            if not ok then object.log("the action " .. key .. " failed: " .. tostring(err)) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- A module's settings
-- ---------------------------------------------------------------------------
local Object = {}
Object.__index = Object

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    sort(keys)
    return keys
end

-- Tells the module that values changed. The values are in place whatever the
-- module does with them; an error in its function is logged, not passed on
-- (the callers are the loader's loop and the in-game menu).
local function told(self, changed, why)
    if type(self.onChange) ~= "function" then return end
    local ok, err = pcall(self.onChange, self.values, changed, why)
    if not ok then self.log("the changed settings (" .. concat(changed, ", ") .. ") could not be applied: " .. tostring(err)) end
end

-- Takes the values of a parsed file. Returns the keys whose value changed.
function Object:take(parsed, text)
    local changed = {}
    for _, item in ipairs(self.items) do
        local v, fixed = checked(item, parsed[item.Key])
        if fixed and self.complained[item.Key] ~= tostring(parsed[item.Key]) then
            self.complained[item.Key] = tostring(parsed[item.Key])
            self.log(("config.lua: %s = %s is not usable; %s is used"):format(item.Key, tostring(parsed[item.Key]), literal(item, v)))
        end
        if self.values[item.Key] ~= v then
            self.values[item.Key] = v
            changed[#changed + 1] = item.Key
        end
    end
    -- "2,5" is valid Lua and means 2: said once per file text
    if type(text) == "string" and text:find("=%s*%-?%d+,%d") and self.commaText ~= text then
        self.commaText = text
        self.log("config.lua: a number seems to be written with a comma (2,5); Lua reads that as 2 - write 2.5")
    end
    return changed
end

-- Reads config.lua again when its text changed (force: in any case).
function Object:reload(force)
    local text = readText(self.path)
    if text == nil then return false, "config.lua not found" end
    if not force and text == self.text then return false, "unchanged" end
    if not force and text == self.badText then return false, "still invalid" end
    local parsed, err = parse(text)
    if not parsed then
        self.badText = text
        self.log("config.lua has an error, keeping the previous settings: " .. tostring(err))
        return false, err
    end
    self.text, self.badText = text, nil
    local changed = self:take(parsed, text)
    if #changed > 0 then
        Menu.dirty[self] = true
        told(self, changed, "file")
    end
    return true, changed
end

-- Sets several values: { Key = value }. Checks them, writes the lines into
-- config.lua and tells the module. Returns the keys that changed.
function Object:apply(values, why)
    local changed = {}
    for _, key in ipairs(sortedKeys(values)) do
        local item = self.byKey[key]
        if item then
            local v = checked(item, values[key])
            if self.values[key] ~= v then
                self.values[key] = v
                changed[#changed + 1] = key
            end
        end
    end
    if #changed == 0 then return changed end
    local text, ok, err
    for _ = 1, 2 do
        local base = readText(self.path)
        text = base
        if text == nil or not parse(text) then
            -- no usable file: a complete one is written (a file that cannot be read stays next to it as config.lua.bak)
            text = Settings.defaultText(self.schema) or "local Config = {}\n\nreturn Config\n"
            for _, item in ipairs(self.items) do
                if self.values[item.Key] ~= item.Default then text = patch(text, item.Key, literal(item, self.values[item.Key])) end
            end
        else
            local set = {}
            for _, key in ipairs(changed) do set[key] = true end
            for _, item in ipairs(self.items) do        -- in the order of the schema: new lines stand as the default file has them
                if set[item.Key] then text = patch(text, item.Key, literal(item, self.values[item.Key])) end
            end
        end
        ok, err = writeText(self.path, text, base or false)
        -- "changed": the settings app saved between the reading and the writing - the lines are put into its file
        if ok or err ~= "changed" then break end
    end
    if ok then
        self.text, self.badText = text, nil
    else
        if err == "changed" then err = "another program keeps changing it" end
        self.log("config.lua could not be written (" .. tostring(err) .. "); the change holds until the game is closed")
    end
    Menu.dirty[self] = true
    told(self, changed, why or "set")
    return changed
end
function Object:set(key, value, why)
    return #self:apply({ [key] = value }, why) > 0
end
-- Puts every setting that is shown back to its default. Returns the keys that changed.
function Object:reset(why)
    local values = {}
    for _, item in ipairs(self.items) do
        if not item.Hidden then values[item.Key] = item.Default end
    end
    return self:apply(values, why or "reset")
end

-- spec: module (name), dir (folder with config.lua and schema.lua, ending in
-- a slash), schema (table; default: dir .. "schema.lua"), log (function),
-- onChange (function(values, changedKeys, why)), onAction (function(key,
-- why): a button of the in-game menu was pressed), menu (false = not in the
-- in-game menu). Returns the settings object, or nil and the reason.
function Settings.open(spec)
    if type(spec) ~= "table" or type(spec.dir) ~= "string" then return nil, "Settings.open needs a table with dir" end
    local log = type(spec.log) == "function" and spec.log or function(text) Print("[G1R_MegaMod] " .. tostring(text) .. "\n") end
    local schema = spec.schema
    if schema == nil then
        local chunk, err = loadfile(spec.dir .. "schema.lua", "t", {})
        if not chunk then return nil, "schema.lua could not be read: " .. tostring(err) end
        local ok, result = pcall(chunk)
        if not ok then return nil, "schema.lua raised: " .. tostring(result) end
        schema = result
    end
    local items, byKey, actions = itemsOf(schema)
    if not items then return nil, "schema.lua: " .. tostring(byKey) end
    local object = setmetatable({
        module = tostring(spec.module or schema.Module or "?"), schema = schema, items = items, byKey = byKey, actions = actions,
        path = spec.dir .. "config.lua", values = {}, log = log, onChange = spec.onChange, onAction = spec.onAction, complained = {},
        checkAt = clock() + RELOAD_SECONDS,
    }, Object)
    for _, item in ipairs(items) do object.values[item.Key] = item.Default end
    local text = readText(object.path)
    if text == nil then
        text = recover(object.path, function(candidate) return parse(candidate) ~= nil end)
        if text ~= nil then log("the last write of config.lua had been cut off; its complete new copy was put in place") end
    end
    if text == nil then
        -- no file yet: the defaults are written, so that there is something to edit
        local default = Settings.defaultText(schema)
        if default and writeText(object.path, default, false) then
            object.text = default
            log("config.lua was not there: written with the default settings")
        else
            log("config.lua not found and could not be written; using the default settings")
        end
    else
        local parsed, err = parse(text)
        if parsed then
            object.text = text
            object:take(parsed, text)
        else
            object.badText = text
            log("config.lua has an error (" .. tostring(err) .. "); using the default settings")
        end
    end
    Opened[#Opened + 1] = object
    if spec.menu ~= false then pcall(addToMenu, object) end
    return object
end

-- Four times a second, on the game thread: edits from the in-game menu, and
-- now and then a look at the files.
function Settings.tick()
    local now = clock()
    for _, object in ipairs(Opened) do
        if now >= object.checkAt then
            object.checkAt = now + RELOAD_SECONDS
            local ok, err = pcall(object.reload, object, false)
            if not ok then object.log("settings reload error: " .. tostring(err)) end
        end
    end
    if Menu.available then
        for _, page in ipairs(Menu.order) do
            pcall(takeCommands, page)
            local dirty = false
            for _, section in ipairs(page.sections) do
                for _, entry in ipairs(section.entries) do
                    if Menu.dirty[entry.object] then dirty = true end
                end
            end
            if dirty then
                pcall(publishValues, page)
                -- a choice whose hint names the option it has: the menu reads the page again
                local ok, published = pcall(publishSchema, page)
                if ok and published then share("SMM:refresh", (tonumber(shared("SMM:refresh")) or 0) + 1) end
            end
        end
        for object in pairs(Menu.dirty) do Menu.dirty[object] = nil end
    end
end

function Settings.init(printFunction)
    if type(printFunction) == "function" then Print = printFunction end
end

-- Offline test access.
Settings._test = { opened = Opened, menu = Menu, checked = checked, parse = parse, literal = literal, keyText = keyText,
    fit = fit, menuLabel = menuLabel, menuHint = menuHint, menuTitle = menuTitle, limits = { name = NAME_MAX, hint = HINT_MAX, tab = TAB_MAX } }

return Settings
