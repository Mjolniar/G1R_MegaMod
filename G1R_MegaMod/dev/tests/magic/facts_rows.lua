-- ============================================================================
-- The rows `magic.original.<Name>` of the table "Diagnostics notes" in
-- dev/facts/magic.md, made from game.lua (the numbers of the game's scripts):
--
--   lua5.4 dev/tests/magic/facts_rows.lua        prints the 84 rows
--
-- harness.lua loads this file too and checks that the facts file holds exactly
-- these rows, and that a session in which every object is looked at notes a
-- text each row accepts. So the model, the facts file and what
-- dev/tools/diagread.py compares a play session with cannot drift apart.
--
-- What the scripts do not set (the class default of m_Speed and of
-- m_SuperArmorDamageBase) is written as "any number" (a pattern for
-- diagread.py): the module only multiplies what it reads there.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local Game = dofile(HERE .. "game.lua")

local R = {}
local ANY = "[0-9.]+"

-- What the note may say: an exact text, or "re:^...$" where the scripts leave a number open.
function R.expected(o)
    local text = Game.originalText(o)
    if o.base == nil or not (o.guess.speed or o.guess.stagger) then return text end
    return "re:^" .. text:match("^(.-), speed ") .. ", speed " .. (o.guess.speed and ANY or Game.num(o.speed))
        .. ", stagger " .. (o.guess.stagger and ANY or Game.num(o.stagger)) .. "$"
end

-- A pattern of the facts tables (what stands behind "re:") as a Lua pattern. Only what these tables use:
-- ^ at the start, $ at the end, sets like [0-9.] with +, "\(" for a character meant literally.
function R.luaPattern(re)
    local out, i = {}, 1
    while i <= #re do
        local c = re:sub(i, i)
        if c == "[" then
            local close = re:find("]", i, true)
            out[#out + 1] = re:sub(i, close)
            i = close
        elseif c == "\\" then
            i = i + 1
            out[#out + 1] = "%" .. re:sub(i, i)
        elseif c == "+" or (c == "^" and i == 1) or (c == "$" and i == #re) then
            out[#out + 1] = c
        elseif c:find("%p") then
            out[#out + 1] = "%" .. c
        else
            out[#out + 1] = c
        end
        i = i + 1
    end
    return table.concat(out)
end

-- Does a noted text fit an alternative of a facts row (an exact text or "re:...")? As dev/tools/diagread.py decides it.
function R.fits(expected, noted)
    if type(noted) ~= "string" then return false end
    if expected:sub(1, 3) ~= "re:" then return noted == expected end
    return noted:find(R.luaPattern(expected:sub(4))) ~= nil
end

-- The rows `magic...` of a facts file: key -> { expected = { alternatives }, fallback = { alternatives } }.
function R.read(text)
    local rows, count = {}, 0
    for line in text:gmatch("[^\n]+") do
        local key, cell = line:match("^| `(magic%.[%w_.]+)` | (.-) | ")
        if key then
            local first, second = cell, ""
            local at = cell:find(" else ", 1, true)
            if at then first, second = cell:sub(1, at - 1), cell:sub(at + 6) end
            local row = { expected = {}, fallback = {} }
            for alternative in first:gmatch("`([^`]+)`") do row.expected[#row.expected + 1] = alternative end
            for alternative in second:gmatch("`([^`]+)`") do row.fallback[#row.fallback + 1] = alternative end
            rows[key] = row
            count = count + 1
        end
    end
    return rows, count
end

local function meaning(o)
    local seen = o.seen and ("; IN-GAME (UE4SS.log of 2026-10-01, another author's mod on this installation): " .. o.seen) or ""
    if o.base ~= nil then
        local open = {}
        if o.guess.speed then open[#open + 1] = "speed" end
        if o.guess.stagger then open[#open + 1] = "stagger" end
        return "M4, M6, M7: base damage, damage from each step of the caster's circle on, flight speed, force against a foe's stance" .. seen
            .. (#open > 0 and ("; " .. table.concat(open, " and ") .. ": not set by the scripts, any number") or "")
    elseif o.levels ~= nil then
        return "M9: per level mana to cast, casting time, mana a second" .. (o.reach and "; M10: its reach" or "") .. (o.heal and "; M11: health by the caster's circle" or "") .. seen
    elseif o.stacks ~= nil then
        return "M13: the flag of each ice counter of the hit effect (false = a hit freezes only when its damage fills the counter)" .. seen
    end
    return "M12: learning points" .. seen
end

-- The rows, in the order of game.lua.
function R.rows()
    local rows = {}
    for _, list in ipairs({ Game.definitions, Game.configs, Game.effects, Game.skills }) do
        for _, o in ipairs(list) do
            rows[#rows + 1] = ("| `magic.original.%s` | `%s` | %s |"):format(o.name, R.expected(o), meaning(o))
        end
    end
    return rows
end

if type(arg) == "table" and type(arg[0]) == "string" and arg[0]:find("facts_rows%.lua$") then
    for _, row in ipairs(R.rows()) do print(row) end
end

return R
