-- ============================================================================
-- The scavenger you ride (module mount of G1R_MegaMod) - Gothic 1 Remake,
-- UE4SS Lua
--
-- Reported 2026-10-05: "sometimes my scavenger won't come to me when called;
-- fixed on restart". The game's follow routine of the rideable scavenger
-- (dev/facts/mount.md) gives up or never starts when
--   1. the hero carries the tag State.RidingBlocked - the game puts it on him
--      inside camps and other no-riding areas and takes it off when he leaves;
--      a missed exit leaves it on him until a reload,
--   2. the scavenger fears the hero (one of his own hits landed on it: it
--      marks him as enemy and runs from him instead of following), or
--   3. the whistle reached nobody (the routine waits for a caller for ever).
-- None of these is caused by this mod (nothing in it touches riding, the
-- hero's tags - but the out-of-mana block - or the scavenger); all three
-- are states of the running game, gone after a restart.
--
-- What this module does:
--   * At every whistle (the game puts Action.CallMount on the hero for 3 s)
--     one line goes to the log: the hero's riding block, whether he is
--     mounted, the scavenger's distance, whether it is dead or fears him.
--     WaitSeconds later a second line says how far it is then.
--   * When it has not come closer by then, AutoFix puts it right: the riding
--     block is taken off the hero ("full" only), fear is taken off the
--     scavenger, and it is put back to its idle routine (which makes it
--     friendly to the player again). Whistle again.
--   * A key and the console words `mount` / `mount fix` do the same at once.
--   * Its name (asked for 2026-10-06: "a way to rename the scavenger in game
--     to a custom name in the settings app"): the name the game shows over
--     the scavenger is replaced by the player's (setting Name; "" = the
--     game's own). Wild scavengers keep theirs.
-- The scavenger is found through the game's own lookup by its unique name
-- (no search among all objects). Nothing is done while the game is paused
-- or a map loads. Each call into the game is guarded; what cannot be asked
-- is said once and left alone.
--
-- Settings: schema.lua describes them, config.lua holds them; the settings
-- app and the in-game mod menu change them while the game runs.
-- ============================================================================

local VERSION = "1.1.0"
local TAG = "G1R_Mount"

local KIT, SETTINGS = G1R_KIT, G1R_SETTINGS
local DIAG = G1R_DIAG
if type(KIT) ~= "table" or type(SETTINGS) ~= "table" then
    print("[" .. TAG .. "] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started\n")
    return
end
if DIAG then pcall(DIAG.version, VERSION) end

local pcall, type, tostring, ipairs = pcall, type, tostring, ipairs
local floor, sqrt = math.floor, math.sqrt
local clock = KIT.clock
local L = KIT.logger(TAG, print)
local log = L.log

local SCRIPT_DIR = (function()
    local ok, src = pcall(function() return debug.getinfo(1, "S").source end)
    if ok and type(src) == "string" then
        local p = src:gsub("^@", ""):gsub("\\", "/")
        local d = p:match("^(.*/)[^/]+$")
        if d then return d end
    end
    return "./"
end)()

-- ---------------------------------------------------------------------------
-- What the module knows about the game (dev/facts/mount.md)
-- ---------------------------------------------------------------------------
local MOUNT_NAME = "Scavenger_Adult_Rideable"       -- the unique name of the rideable scavenger's definition (M1)
local NPC_STATE_DEFAULT = "GothicNPCState"          -- its default object answers FindNPCByUniqueName(controller, name) (M2)
local IDLE_ROUTINE = "DailyRoutine_Scavenger_Rideable_Idle"   -- the routine it is put back to (M5)
local FEAR_EFFECT = "GE_Fear"                       -- the effect behind Debuff.Fear (M4)
local TAGS = {                                      -- gameplay tags asked for (M3)
    blocked = "State.RidingBlocked",
    whistle = "Action.CallMount",
    mounted = "State.Mounted",
    riding = "State.Riding",
    fear = "Debuff.Fear",
}
local CAME_CLOSER = 100                             -- cm less than at the whistle counts as "on its way"
local NEAR = 600                                    -- cm; this close it is here, whatever it does (the routine stops at 3 m, M5)
local TRIES = 3                                     -- failures of a question before it is given up for this run
local NAME_PART = "HUDDisplayNameGothicFontController"   -- the HUD's part that keeps the name widgets (M9)
local NAME_TEXT = "Text_CharacterName"              -- the text block of a name widget (M9)
local NAME_MAX = 40                                 -- letters of a name
local NAME_SEARCH_EVERY = 2                         -- seconds between searches for the HUD's part when the HUD's list cannot be walked

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local Settings, problem = SETTINGS.open({ module = "mount", dir = SCRIPT_DIR, log = log })
if not Settings then
    log("the settings could not be set up (" .. tostring(problem) .. "); not started")
    return
end
local Cfg = Settings.values

-- ---------------------------------------------------------------------------
-- State of this run
-- ---------------------------------------------------------------------------
local S = {
    whistling = false,          -- the hero had Action.CallMount at the last look
    whistles = 0,               -- whistles seen
    pending = nil,              -- { at, distance, blocked } of the last whistle, until the second look
    fixes = 0, fixed = {},      -- fixes done; what the last one did
    lastReport = nil,           -- the last report line
    lookupFails = 0, lookupOff = false,
    tagFails = 0, tagsOff = false, tagYes = false,
    key = "",
    name = {                    -- its name (M9)
        cfg = nil, want = "",   -- Cfg.Name as last seen; the name to show
        written = nil,          -- the name this module put on the widget (until the game's own is back)
        original = nil,         -- the game's own name, as the widget showed it
        last = nil,             -- address of the widget written to last
        shown = 0, restored = 0, rewritten = 0,
        fails = 0, off = false,
        parts = {},             -- address of an entry of the HUD's list -> whether it is the name part
        searchAt = 0,
    },
}
local Noted = {}
local function note(key, value, detail)
    if DIAG and Noted[key] ~= value then
        Noted[key] = value
        DIAG.note(key, value, detail)
    end
end
local function firstLine(text) return (tostring(text):match("^[^\r\n]*") or "") end
local function metres(cm) return ("%d m"):format(floor(cm / 100 + 0.5)) end

-- ---------------------------------------------------------------------------
-- The game: tags, the hero, the scavenger
-- ---------------------------------------------------------------------------
local Names, Tags = {}, {}
local function nameOf(text)
    local n = Names[text]
    if n == nil then
        local ok, made = pcall(function() return FName(text) end)
        n = (ok and made ~= nil) and made or false
        Names[text] = n
    end
    return n or nil
end
local function tagOf(text)
    local t = Tags[text]
    if t == nil then
        local n = nameOf(text)
        t = n and { TagName = n } or false
        Tags[text] = t
    end
    return t or nil
end
-- The ability system of a character state (it holds the gameplay tags), or nil.
local function systemOf(state)
    local system = state and KIT.get(state, "AbilitySystemComponent") or nil
    if KIT.valid(system) then return system end
    return nil
end
-- Does this ability system have the tag (or one below it)? true / false, or nil when that cannot be asked.
local function hasTag(system, text)
    if S.tagsOff or system == nil then return nil end
    local tag = tagOf(text)
    if not tag then
        S.tagsOff = true
        L.once("tags", "gameplay tags cannot be asked for (this UE4SS build has no FName); nothing can be told about the hero or the scavenger")
        note("mount.tags", "not readable", "no FName")
        return nil
    end
    local ok, result = KIT.try(system, "HasGameplayTag", tag)
    if ok and type(result) == "boolean" then
        S.tagFails = 0
        if result then S.tagYes = true end
        note("mount.tags", S.tagYes and "readable" or "only no so far")
        return result
    end
    S.tagFails = S.tagFails + 1
    if S.tagFails >= TRIES then
        S.tagsOff = true
        local why = ok and ("the answer was " .. tostring(result)) or firstLine(result)
        L.once("tags", "gameplay tags cannot be asked for (" .. why .. "); nothing can be told about the hero or the scavenger")
        note("mount.tags", "not readable", why)
    end
    return nil
end
local function heroSystem() return systemOf(KIT.playerState()) end

-- The scavenger's character state, through the game's own lookup by unique
-- name (the default object of GothicNPCState, M2). nil, and why, when it is
-- not there or cannot be asked for.
local function mountState()
    if S.lookupOff then return nil, "lookup given up" end
    local ctrl = KIT.controller()
    if not ctrl then return nil, "no hero" end
    local cdo = KIT.findDefault(NPC_STATE_DEFAULT, "G1R")
    local name = nameOf(MOUNT_NAME)
    if not cdo or not name then
        S.lookupOff = true
        L.once("lookup", "the game's lookup of characters by name was not found; nothing can be told about the scavenger")
        note("mount.lookup", "not available", cdo and "no FName" or "GothicNPCState default object not found")
        return nil, "lookup not available"
    end
    local ok, st = KIT.try(cdo, "FindNPCByUniqueName", ctrl, name)
    if not ok then
        S.lookupFails = S.lookupFails + 1
        if S.lookupFails >= TRIES then
            S.lookupOff = true
            L.once("lookup", "the game's lookup of characters by name fails (" .. firstLine(st) .. "); nothing can be told about the scavenger")
            note("mount.lookup", "fails", firstLine(st))
        end
        return nil, "lookup failed"
    end
    S.lookupFails = 0
    if not KIT.valid(st) then
        note("mount.lookup", "works")
        return nil, "not in the world"
    end
    note("mount.lookup", "works")
    return st
end

local function heroPos()
    local pawn = KIT.pawn()
    if not pawn then return nil end
    local v = KIT.call(pawn, "K2_GetActorLocation")
    local x, y = KIT.get(v, "X"), KIT.get(v, "Y")
    if type(x) == "number" and type(y) == "number" then return x, y end
    return nil
end
local function statePos(st)
    local v = KIT.call(st, "GetCharacterLocation")
    local x, y = KIT.get(v, "X"), KIT.get(v, "Y")
    if type(x) == "number" and type(y) == "number" then return x, y end
    return nil
end

-- One look at the hero and the scavenger: a table of findings and its text.
local function look()
    local f = { found = false }
    local hero = heroSystem()
    f.heroSystem = hero ~= nil
    f.blocked = hasTag(hero, TAGS.blocked)
    f.mounted = hasTag(hero, TAGS.mounted) == true or hasTag(hero, TAGS.riding) == true
    f.whistle = hasTag(hero, TAGS.whistle)
    local st, why = mountState()
    if st then
        f.found, f.state = true, st
        f.dead = KIT.call(st, "IsDead") == true
        f.removed = KIT.call(st, "GetRemovedFromWorld") == true
        local system = systemOf(st)
        f.mountSystem = system ~= nil
        f.fear = hasTag(system, TAGS.fear)
        local hx, hy = heroPos()
        local mx, my = statePos(st)
        if hx and mx then
            local dx, dy = hx - mx, hy - my
            f.distance = sqrt(dx * dx + dy * dy)
        end
    else
        f.why = why
    end
    local parts = {}
    local function yn(v) if v == nil then return "?" end return v and "yes" or "no" end
    parts[#parts + 1] = "you: riding block " .. yn(f.blocked) .. ", mounted " .. yn(f.mounted)
    if f.found then
        parts[#parts + 1] = ("scavenger: %s away%s%s, fears you %s"):format(f.distance and metres(f.distance) or "? m",
            f.dead and ", dead" or "", f.removed and ", removed" or "", yn(f.fear))
    else
        parts[#parts + 1] = "scavenger: " .. tostring(f.why)
    end
    f.text = table.concat(parts, " | ")
    return f
end

-- ---------------------------------------------------------------------------
-- Putting it right
-- ---------------------------------------------------------------------------
-- `full`: the riding block too. Returns what was done (a list of texts).
local function fix(full, why)
    local done, failed = {}, {}
    local f = look()
    S.fixes = S.fixes + 1
    if full and f.blocked == true then
        local hero = heroSystem()
        local ok, result = KIT.try(hero, "RemoveTag", tagOf(TAGS.blocked))
        if ok and hasTag(hero, TAGS.blocked) == false then
            done[#done + 1] = "riding block taken off you"
            note("mount.block_removed", "works")
        else
            failed[#failed + 1] = "the riding block could not be taken off you (" .. (ok and "it is still there" or firstLine(result)) .. ")"
            note("mount.block_removed", "fails", ok and "still there" or firstLine(result))
        end
    end
    if f.found and not f.dead then
        local system = systemOf(f.state)
        if f.fear == true then
            local class = KIT.findClass(FEAR_EFFECT, "Angelscript")
            if class then
                local ok, result = KIT.try(system, "RemoveActiveGameplayEffectBySourceEffect", class, nil, -1)
                if ok and hasTag(system, TAGS.fear) == false then
                    done[#done + 1] = "fear taken off the scavenger"
                    note("mount.fear_removed", "works")
                else
                    failed[#failed + 1] = "fear could not be taken off the scavenger (" .. (ok and "it is still there" or firstLine(result)) .. ")"
                    note("mount.fear_removed", "fails", ok and "still there" or firstLine(result))
                end
            else
                failed[#failed + 1] = "the fear effect's class was not found"
                note("mount.fear_removed", "not available", "GE_Fear not found")
            end
        end
        local routine = KIT.findClass(IDLE_ROUTINE, "Angelscript")
        if routine then
            local ok, result = KIT.try(f.state, "ExchangeDailyRoutineToClass", routine)
            if ok then
                done[#done + 1] = "scavenger put back to its idle routine"
                note("mount.routine_reset", "works")
            else
                failed[#failed + 1] = "the scavenger's routine could not be changed (" .. firstLine(result) .. ")"
                note("mount.routine_reset", "fails", firstLine(result))
            end
        else
            failed[#failed + 1] = "the idle routine's class was not found"
            note("mount.routine_reset", "not available", "DailyRoutine_Scavenger_Rideable_Idle not found")
        end
    end
    S.fixed = { done = done, failed = failed, at = clock(), why = why }
    local text
    if #done == 0 and #failed == 0 then
        text = (f.found and "nothing to put right" or ("nothing to put right (scavenger: " .. tostring(f.why) .. ")")) .. " - " .. f.text
    else
        text = table.concat(done, ", ")
        if #done > 0 then text = text .. " - whistle again" end
        if #failed > 0 then text = (text ~= "" and (text .. "; ") or "") .. table.concat(failed, "; ") end
    end
    log(("put right (%s): %s"):format(why, text))
    if Cfg.ShowNotes and #done > 0 then KIT.notify("Scavenger: " .. table.concat(done, ", ") .. " - whistle again", "mount") end
    return done, failed, f
end

local function report(why)
    local f = look()
    S.lastReport = f.text
    log(("%s: %s"):format(why, f.text))
    if Cfg.ShowNotes and why == "report" then KIT.notify("Scavenger: " .. f.text, "mount", 6) end
    return f
end

-- ---------------------------------------------------------------------------
-- Its name (M9). The game makes the name it shows over a character from its
-- text table, by the character's unique name - nothing a script can change.
-- So the text of the name widget over the scavenger is changed: the HUD's
-- part HUDDisplayNameGothicFontController keeps the name widgets of the
-- characters it names (m_Widgets); the one of this scavenger gets the
-- player's name. Everything is found anew at every look, from the hero's
-- controller down (dev/FACTS.md, U17).
-- ---------------------------------------------------------------------------
-- The name to show: Cfg.Name without control characters and outer spaces,
-- at most NAME_MAX letters ("" = the game's own).
local function wantedName()
    local n = type(Cfg.Name) == "string" and Cfg.Name or ""
    n = n:gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local letters = 0
    for at in n:gmatch("()[^\128-\191]") do                 -- (the first byte of each UTF-8 letter)
        letters = letters + 1
        if letters > NAME_MAX then
            n = n:sub(1, at - 1):gsub("%s+$", "")
            break
        end
    end
    return n
end
local function textOf(v)
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    return nil
end
-- Calls visit(key, value) for every entry of a map property, the entries as
-- UE4SS hands them out; the whole callback inside pcall (an error that leaves
-- the callback of ForEach is not caught around the walk, melee M12).
-- true, or nil and what went wrong.
local function walk(map, visit)
    local trouble = nil
    local ok, err = pcall(function()
        map:ForEach(function(key, value)
            if trouble then return end
            local fine, why = pcall(visit, key, value)
            if not fine then trouble = firstLine(why) end
        end)
    end)
    if not ok then return nil, firstLine(err) end
    if trouble then return nil, trouble end
    return true
end
local function nameFails(why)
    S.name.fails = S.name.fails + 1
    note("mount.name_set", "fails", why)
    if S.name.fails >= TRIES then
        S.name.off = true
        L.once("name", "the scavenger's name cannot be shown (" .. why .. "); the game's own stays")
    end
end
-- The HUD's part with the name widgets. First way: the HUD's own list of its
-- parts (m_Controllers; only the values are read - its keys are soft
-- references). Second way, when that list cannot be walked: a search among
-- all objects of the part's class, at most every NAME_SEARCH_EVERY seconds,
-- the one of this controller. nil and why when there is none.
local function namePart(ctrl)
    local hud = KIT.get(ctrl, "MyHUD")
    if not KIT.valid(hud) then return nil, "no HUD" end
    local list = KIT.get(hud, "m_Controllers")
    local found, why = nil, nil
    if list ~= nil then
        local ok
        ok, why = walk(list, function(_, value)
            if found then return end
            local part = KIT.unwrap(value)
            local at = KIT.addressOf(part)
            if not at then return end
            local known = S.name.parts[at]
            if known == nil then
                local class = KIT.classToken(part)
                known = class ~= nil and class:sub(1, #NAME_PART) == NAME_PART
                S.name.parts[at] = known
            end
            if known and KIT.valid(part) then found = part end
        end)
        if ok then
            note("mount.name_way", "the HUD's list")
            if found then return found end
            return nil, "the HUD has no name part"
        end
        why = "the HUD's list cannot be walked (" .. why .. ")"
    else
        why = "the HUD's list cannot be read"
    end
    note("mount.name_way", "search", why)
    local now = clock()
    if now < S.name.searchAt then return nil, why end
    S.name.searchAt = now + NAME_SEARCH_EVERY
    local ok, all = pcall(FindAllOf, NAME_PART)
    if ok and type(all) == "table" then
        local mine = KIT.addressOf(ctrl)
        for i = #all, 1, -1 do
            local part = all[i]
            local name = KIT.valid(part) and KIT.fullName(part) or nil
            if name and not KIT.isDefaultName(name) and KIT.addressOf(KIT.get(part, "m_PlayerController")) == mine then return part end
        end
    end
    return nil, why
end
-- The scavenger's own objects by address: its state and its character.
local function scavengerIds(st)
    local ids = {}
    local a = KIT.addressOf(st)
    if a then ids[a] = "its state" end
    local character = KIT.call(st, "GetCharacter")
    if not KIT.valid(character) then character = KIT.get(st, "PawnPrivate") end
    local b = KIT.valid(character) and KIT.addressOf(character) or nil
    if b then ids[b] = "its character" end
    return ids
end
-- Whether an object of the widget list stands for the scavenger: how ("its
-- state", "its character", "a part of its character"), or nil.
local function ofScavenger(o, ids)
    local a = KIT.addressOf(o)
    if a and ids[a] then return ids[a] end
    local owner = KIT.call(o, "GetOwner")
    local b = KIT.valid(owner) and KIT.addressOf(owner) or nil
    if b and ids[b] then return "a part of " .. ids[b] end
    return nil
end
-- Puts `text` on a name text block; true, or nil and why.
local function putName(block, text)
    local made = KIT.text(text)
    if made == nil then return nil, "texts cannot be made" end
    local ok, err = KIT.try(block, "SetText", made)
    if not ok then return nil, firstLine(err) end
    if textOf(KIT.call(block, "GetText")) ~= text then return nil, "the widget does not keep the text" end
    return true
end
-- One look: the name widget of the scavenger, if the HUD shows one, gets the
-- player's name (or the game's own back once the setting is "").
local function nameLook()
    local n = S.name
    local ctrl = KIT.controller()
    if not ctrl then return end
    local part, why = namePart(ctrl)
    if not part then
        note("mount.name_hud", "not found", why)
        return
    end
    note("mount.name_hud", "found")
    local widgets = KIT.get(part, "m_Widgets")
    if widgets == nil then
        n.parts = {}                -- (whatever was taken for the part is looked at anew)
        nameFails("the name part has no widget list")
        return
    end
    local entries = {}
    local ok, err = walk(widgets, function(key, value)
        entries[#entries + 1] = { KIT.unwrap(key), KIT.unwrap(value) }
    end)
    if not ok then nameFails("the widget list cannot be walked (" .. err .. ")"); return end
    if #entries == 0 then return end
    local st = mountState()
    if not st then return end
    local ids = scavengerIds(st)
    for _, e in ipairs(entries) do
        local widget, other = e[2], e[1]
        local block = KIT.get(widget, NAME_TEXT)
        if not KIT.valid(block) then
            widget, other = e[1], e[2]
            block = KIT.get(widget, NAME_TEXT)
        end
        if KIT.valid(block) then
            note("mount.name_entry", widget == e[2] and "character -> widget" or "widget -> character", KIT.classToken(other))
            local how = ofScavenger(other, ids)
            if how then
                local shown = textOf(KIT.call(block, "GetText"))
                if shown == nil then nameFails("the name on the widget cannot be read"); return end
                local at = KIT.addressOf(widget)
                if n.want ~= "" then
                    if shown ~= n.want then
                        if shown ~= n.written then
                            if n.last == at then                   -- (last is set and cleared together with written)
                                n.rewritten = n.rewritten + 1          -- the game wrote its own over ours
                                note("mount.name_rewritten", "seen", n.rewritten .. " time(s)")
                            end
                            n.original = shown
                        end
                        local put, failed = putName(block, n.want)
                        if not put then nameFails(failed); return end
                        n.written, n.last, n.shown, n.fails = n.want, at, n.shown + 1, 0
                        note("mount.name_set", "works", how)
                        L.once("name-shown", ("its name: \"%s\" is shown over the scavenger (the game's own: \"%s\"; found as %s)")
                            :format(n.want, tostring(n.original), how))
                    end
                elseif n.written ~= nil then
                    if shown == n.written and n.original then
                        local put, failed = putName(block, n.original)
                        if not put then nameFails(failed); return end
                        n.restored = n.restored + 1
                        log(("its name: the game's own (\"%s\") is back"):format(n.original))
                    end
                    n.written, n.last = nil, nil
                end
                return
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- The loop: its name, whistles
-- ---------------------------------------------------------------------------
local function nameNow()
    if Cfg.Name ~= S.name.cfg then S.name.cfg, S.name.want = Cfg.Name, wantedName() end
    return S.name.want
end
local function tick()
    if KIT.loading() then S.pending, S.whistling = nil, false; return end
    if KIT.paused() == true then return end
    if not S.name.off and (nameNow() ~= "" or S.name.written ~= nil) then
        local ok, err = pcall(nameLook)
        if not ok then nameFails(firstLine(err)) end
    end
    if not Cfg.Enabled then S.pending, S.whistling = nil, false; return end
    local hero = heroSystem()
    if not hero then S.whistling = false; return end
    local whistle = hasTag(hero, TAGS.whistle)
    if whistle == nil then return end
    local now = clock()
    if whistle and not S.whistling then
        -- a whistle: written down, looked at again WaitSeconds later
        S.whistles = S.whistles + 1
        local f = report("whistle " .. S.whistles)
        if f.blocked == true then note("mount.whistle_with_block", "seen", "the game let the hero whistle with the riding block on him") end
        S.pending = { at = now, distance = f.distance, found = f.found, blocked = f.blocked, n = S.whistles }
    end
    S.whistling = whistle
    local p = S.pending
    if p and now - p.at >= Cfg.WaitSeconds then
        S.pending = nil
        local f = report(("whistle %d, %d s later"):format(p.n, Cfg.WaitSeconds))
        if f.mounted then return end                                -- he is riding: it came
        if f.found and f.distance == nil then
            -- whether it is on its way cannot be told: a routine that may be working is not touched
            note("mount.came", "not known", f.text)
            if Cfg.AutoFix ~= "off" then log("not put right: how far away the scavenger is could not be read") end
            return
        end
        local came = f.found and (f.distance <= NEAR or (p.distance ~= nil and f.distance <= p.distance - CAME_CLOSER))
        if came then
            note("mount.came", "yes")
            return
        end
        note("mount.came", "no", f.text)
        if Cfg.AutoFix == "off" then return end
        if not f.found and f.blocked ~= true then
            log("not put right: the scavenger was not found and you carry no riding block")
            return
        end
        fix(Cfg.AutoFix == "full", "after whistle " .. p.n)
    end
end

-- ---------------------------------------------------------------------------
-- Status (console, the loader's reports), console words, key, settings
-- ---------------------------------------------------------------------------
local function summary()
    local name = nameNow()
    local named = name ~= "" and ("; its name: \"" .. name .. "\"") or ""
    if not Cfg.Enabled then return "the whistle is not watched" .. named end
    return ("whistles watched, after %d s %s%s"):format(Cfg.WaitSeconds,
        Cfg.AutoFix == "off" and "only written down" or ("put right (" .. Cfg.AutoFix .. ")"),
        S.key ~= "" and (", key " .. S.key) or "") .. named
end
local function statusLines()
    local lines = { ("v%s | %s"):format(VERSION, summary()) }
    lines[#lines + 1] = ("whistles seen: %d; put right: %d%s"):format(S.whistles, S.fixes,
        S.fixed.done and (#S.fixed.done > 0 and ("; last: " .. table.concat(S.fixed.done, ", ")) or "") or "")
    local n = S.name
    if n.off then
        lines[#lines + 1] = "its name: given up for this run"
    elseif nameNow() ~= "" then
        lines[#lines + 1] = ("its name: \"%s\", written %d time(s)%s"):format(n.want, n.shown,
            n.rewritten > 0 and ("; the game wrote its own again %d time(s)"):format(n.rewritten) or "")
    end
    if S.lastReport then lines[#lines + 1] = "last look: " .. S.lastReport end
    if S.tagsOff then lines[#lines + 1] = "gameplay tags cannot be asked for in this run" end
    if S.lookupOff then lines[#lines + 1] = "the scavenger cannot be looked up in this run" end
    return lines
end

-- mount            status
-- mount report     one look at you and the scavenger
-- mount fix        put it right now (as "full")
-- mount reload     read config.lua now
local function console(fullCommand, params, device)
    local args = {}
    if type(params) == "table" then
        for _, p in ipairs(params) do args[#args + 1] = tostring(p) end
    elseif type(fullCommand) == "string" then
        for w in fullCommand:gmatch("%S+") do args[#args + 1] = w end
        table.remove(args, 1)
    end
    local lines
    local word = (args[1] or ""):lower()
    if word == "reload" then
        local ok, why = Settings:reload(true)
        lines = { ok and ("settings read: " .. summary()) or ("settings not read: " .. tostring(why)) }
    elseif word == "report" then
        lines = { report("report").text }
    elseif word == "fix" then
        local done, failed = fix(true, "console")
        lines = { #done > 0 and (table.concat(done, ", ") .. " - whistle again") or "nothing was put right" }
        for _, t in ipairs(failed) do lines[#lines + 1] = t end
    else
        lines = statusLines()
    end
    for _, l in ipairs(lines) do
        log(l)
        if device ~= nil then pcall(function() device:Log("[" .. TAG .. "] " .. l) end) end
    end
    return true
end

local function bindKey()
    local ok, result = KIT.bindKey("mount:fix", Cfg.FixKey, function() fix(true, "key") end)
    if ok then
        S.key = result
    else
        S.key = ""
        L.once("key:" .. tostring(Cfg.FixKey) .. ":" .. tostring(result), ("the key %s could not be bound (%s); the console words still work")
            :format(tostring(Cfg.FixKey), tostring(result)))
    end
end
bindKey()
KIT.describeKey("mount:fix", "put the scavenger right")        -- (for the list of keys, module keys)
Settings.onChange = function(_, changed, why)
    for _, key in ipairs(changed) do
        if key == "FixKey" then bindKey() end
    end
    if not Cfg.Enabled then S.pending, S.whistling = nil, false end
    log(("settings changed (%s): %s"):format(why == "menu" and "in-game menu" or (why == "file" and "config.lua" or tostring(why)), summary()))
end
Settings.onAction = function(key)
    if key == "Report" then report("report") end
    if key == "Fix" then fix(true, "menu") end
end

-- ---------------------------------------------------------------------------
-- Registration (each exactly once)
-- ---------------------------------------------------------------------------
KIT.onWorldChange(function()
    S.pending, S.whistling = nil, false
    local n = S.name        -- a new HUD: new widgets with the game's own name
    n.parts, n.written, n.last, n.original, n.searchAt = {}, nil, nil, nil, 0
end)
for _, name in ipairs({ "mount", "g1r_mount" }) do
    if type(RegisterConsoleCommandHandler) == "function" then
        pcall(RegisterConsoleCommandHandler, name, console)
    end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; the whistle is not watched (the console words still work).")
else
    LoopInGameThreadWithDelay(250, function()
        local ok, err = pcall(tick)
        if not ok then
            S.pending = nil
            L.once("tick:" .. tostring(err), "update error: " .. tostring(err))
        end
    end)
end

log(("v%s loaded: %s"):format(VERSION, summary()))

if DIAG then
    pcall(function()
        DIAG.status(statusLines)
        DIAG.dump(function()
            return {
                version = VERSION, enabled = Cfg.Enabled, auto_fix = Cfg.AutoFix, wait_seconds = Cfg.WaitSeconds,
                key = S.key, show_notes = Cfg.ShowNotes,
                whistles = S.whistles, fixes = S.fixes, last_fix = S.fixed, last_look = S.lastReport,
                tags_readable = not S.tagsOff, lookup_works = not S.lookupOff, pending = S.pending ~= nil,
                name = { wanted = S.name.want, written = S.name.shown, restored = S.name.restored,
                         rewritten_by_the_game = S.name.rewritten, given_up = S.name.off },
            }
        end)
    end)
end

-- Offline test harness hook (inert in game: the global does not exist there).
if type(rawget(_G, "MOUNT_TEST")) == "table" then
    local T = rawget(_G, "MOUNT_TEST")
    T.state, T.console, T.status, T.tick, T.settings = S, console, statusLines, tick, Settings
    T.look, T.fix, T.report, T.tags = look, fix, report, TAGS
    T.nameLook, T.wantedName = nameLook, wantedName
end
