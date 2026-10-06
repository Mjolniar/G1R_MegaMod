-- Checks the presets (difficulty tiers) in the modules' schema.lua files: the field Tiers of an item
-- (dev/SETTINGS.md section 7). The game does not read that field; the settings app does.
--
--   lua5.4 dev/tools/presets.lua            check every module; exit code 1 when something is wrong
--   lua5.4 dev/tools/presets.lua xp magic   only these modules
--   lua5.4 dev/tools/presets.lua --list     also print every item with its five values
--
-- For tests: set the global PRESETS_LIB before dofile - the file then returns its functions and
-- does nothing else.
local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local MOD = HERE .. "../../"

local P = {}
P.COUNT = 5         -- the presets, from 1 (the game itself, the hardest) to 5 (as easy as the settings allow)

-- A number as config.lua holds it for an item: with at most Decimals places (whole when there are none).
local function fits(item, v)
    local decimals = tonumber(item.Decimals) or 0
    if decimals <= 0 then return v == math.floor(v) end
    local scaled = v * 10 ^ decimals
    return math.abs(scaled - math.floor(scaled + 0.5)) < 1e-6
end

-- The five values of an item, or nil when it has none, or nil and what is wrong with its Tiers.
function P.tiersOf(item)
    local tiers = item.Tiers
    if tiers == nil then return nil end
    local key = tostring(item.Key)
    if item.Kind ~= "bool" and item.Kind ~= "number" and item.Kind ~= "choice" then
        return nil, key .. ": Tiers are for yes/no, number and choice items"
    end
    if item.Hidden then return nil, key .. ": a hidden item cannot have Tiers (the app has no control for it)" end
    if tiers == "default" then
        local values = {}
        for i = 1, P.COUNT do values[i] = item.Default end
        return values
    end
    if type(tiers) ~= "table" then return nil, key .. ": Tiers must be " .. P.COUNT .. " values or \"default\"" end
    local n = 0
    for k in pairs(tiers) do
        if math.type(k) ~= "integer" or k < 1 or k > P.COUNT then return nil, key .. ": Tiers must be " .. P.COUNT .. " values or \"default\"" end
        n = n + 1
    end
    if n ~= P.COUNT then return nil, key .. ": Tiers must be " .. P.COUNT .. " values or \"default\"" end
    for i = 1, P.COUNT do
        local v = tiers[i]
        if item.Kind == "bool" then
            if type(v) ~= "boolean" then return nil, key .. ": tier " .. i .. " must be true or false" end
        elseif item.Kind == "number" then
            if type(v) ~= "number" or v ~= v or v < item.Min or v > item.Max then
                return nil, key .. ": tier " .. i .. " must be a number from " .. tostring(item.Min) .. " to " .. tostring(item.Max)
            end
            if not fits(item, v) then return nil, key .. ": tier " .. i .. " has more places than Decimals allows" end
        else
            local found = false
            for _, o in ipairs(item.Options) do
                if o == v then found = true end
            end
            if not found then return nil, key .. ": tier " .. i .. " is not one of the Options" end
        end
    end
    if tiers[1] ~= item.Default then return nil, key .. ": tier 1 is the game itself - it must be the item's Default" end
    return { tiers[1], tiers[2], tiers[3], tiers[4], tiers[5] }
end

-- Every item of a schema that has Tiers: { { item = , values = { v1 .. v5 }, group = title }, ... } and the problems.
function P.read(schema)
    local list, problems = {}, {}
    if type(schema) ~= "table" or type(schema.Groups) ~= "table" then return list, { "the schema has no Groups" } end
    for _, group in ipairs(schema.Groups) do
        for _, item in ipairs(type(group) == "table" and type(group.Items) == "table" and group.Items or {}) do
            if type(item) == "table" then
                local values, why = P.tiersOf(item)
                if values then
                    list[#list + 1] = { item = item, values = values, group = group.Title }
                elseif why then
                    problems[#problems + 1] = why
                end
            end
        end
    end
    return list, problems
end

function P.valueText(v)
    if type(v) == "boolean" then return v and "yes" or "no" end
    if type(v) == "number" then
        if v == math.floor(v) then return ("%d"):format(v) end
        return (("%.3f"):format(v):gsub("0+$", ""))
    end
    return tostring(v)
end

function P.modules(root)
    local names = {}
    local p = io.popen('ls "' .. root .. 'modules"')
    for name in p:lines() do names[#names + 1] = name end
    p:close()
    return names
end

function P.schemaOf(root, name)
    local chunk = loadfile(root .. "modules/" .. name .. "/Scripts/schema.lua", "t", {})
    if not chunk then return nil end
    local ok, schema = pcall(chunk)
    if ok then return schema end
    return nil
end

if rawget(_G, "PRESETS_LIB") then return P end

-- ---------------------------------------------------------------------------------------------------------------
local list, wanted = false, {}
for _, a in ipairs(arg) do
    if a == "--list" then list = true else wanted[#wanted + 1] = a end
end
if #wanted == 0 then wanted = P.modules(MOD) end
local bad = 0
for _, name in ipairs(wanted) do
    local schema = P.schemaOf(MOD, name)
    if schema then
        local items, problems = P.read(schema)
        for _, why in ipairs(problems) do
            io.write(name, ": ", why, "\n")
            bad = bad + 1
        end
        local moving = 0
        for _, e in ipairs(items) do
            for i = 2, P.COUNT do
                if e.values[i] ~= e.values[1] then
                    moving = moving + 1
                    break
                end
            end
        end
        io.write(name, ": ", #items, " item(s) with Tiers (", moving, " that differ between the presets, ", #items - moving, " put back to their default)\n")
        if list then
            for _, e in ipairs(items) do
                local texts = {}
                for i = 1, P.COUNT do texts[i] = P.valueText(e.values[i]) end
                io.write(("    %-24s %s\n"):format(e.item.Key, table.concat(texts, " | ")))
            end
        end
    end
end
os.exit(bad == 0 and 0 or 1)
