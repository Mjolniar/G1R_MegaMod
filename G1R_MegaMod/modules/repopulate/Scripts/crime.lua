-- G1R_Repopulate: crime switch.
--
-- How the game decides: every crime - on the player's side when it is
-- committed, and on each witness's side when it is noticed - starts by
-- looking up a rule class for the crime's tag in one table that lives on the
-- crime subsystems (CrimeDefinitions: crime tag -> rule class). The rule says
-- where the victims come from (a person, the owner of an area, the owner of
-- an object) and who writes the crime down.
--
-- Switching a kind of crime off puts a different, existing rule class into
-- its table entry: one that looks for victims where the game supplies none
-- for that crime (so the crime is thrown away as "no victim" before it is
-- written down) and that is never written down by a witness. Nothing is
-- removed from the table - the game expects every entry to be there.
-- Switching back on puts the original classes back.
--
-- The table is rebuilt by the game whenever a world is loaded, so the switch
-- is never stored in a save; it is applied again after every load. What is
-- stored in a save is the game's own crime memory, which "forget" cleans with
-- the game's own function.
--
-- One reaction does not pass through that table: an owner or guard who only
-- HEARS you use something that is owned (a chest, a door) walks over to the
-- noise and comments. It is a response module of its own. Every response
-- module lists the tags a character must own for the module to apply to it
-- (RequiredOwnedTags; the game checks them on every event). While its kind of
-- crime is switched off, the module is made to ask for the tag only the
-- player character owns, so it applies to nobody. This sits on the module's
-- class default object: one write covers everyone, and nothing of it is saved.
--
-- Never touched: hitting and killing, defeat bookkeeping, story fights.
-- While crime is left on (the default) this file does not touch the game.
--
-- The crime subsystems are asked from the engine at every check (util.lua,
-- "The engine's own way"): three plain calls, and nothing of them is kept
-- between two checks. Only when the engine cannot be asked are they searched
-- for among all objects and kept, as before 1.4 - spaced out, and checked by
-- name before use.
local M = {}

local pcall, type, tostring, pairs, ipairs = pcall, type, tostring, pairs, ipairs

-- Diagnostics handle of the megamod loader (nil when the mod runs on its own).
local DIAG = G1R_DIAG
local Noted = { gate = {} }  -- diagnostics: the values last noted

local U, Cfg

-- Rule classes used as stand-ins (both exist in the game, both are written
-- down by the criminal only):
--   EVENT looks for a personal victim  -> for crimes the game reports without one
--   ITEM  looks for the owner of an object -> for crimes the game reports without one
local EVENT = "CrimeDefinition_Pickpocket_Fail"
local ITEM = "CrimeDefinition_Theft"

local function R(group, orig, off) return { g = group, orig = orig, off = off } end
-- key: crime tag, lower case, dots as underscores
local RULES = {
    crime_theft                              = R("Theft", "CrimeDefinition_Theft", EVENT),
    crime_pickpocket_fail                    = R("Theft", "CrimeDefinition_Pickpocket_Fail", ITEM),
    crime_pickpocket_success                 = R("Theft", "CrimeDefinition_Pickpocket_Success", ITEM),
    crime_lockpicking                        = R("Theft", "CrimeDefinition_Lockpicking", EVENT),
    crime_ignoredwarning_lockpicking         = R("Theft", "CrimeDefinition_IgnoredWarning_Lockpicking", ITEM),
    crime_interaction                        = R("Theft", "CrimeDefinition_Interaction", EVENT),
    crime_ignoredwarning_interaction         = R("Theft", "CrimeDefinition_IgnoredWarning_Interaction", ITEM),

    crime_trespassing_onguild                = R("Trespassing", "CrimeDefinition_Crime_Trespassing", EVENT),
    crime_trespassing_onperson               = R("Trespassing", "CrimeDefinition_Crime_Trespassing", EVENT),
    crime_ignoredwarning_trespassing         = R("Trespassing", "CrimeDefinition_IgnoredWarning_Trespassing", ITEM),
    crime_creeping                           = R("Trespassing", "CrimeDefinition_Creeping", ITEM),

    crime_threateningweapondrawn             = R("Weapons", "CrimeDefinition_ThreateningWeaponDrawn", ITEM),
    crime_fistsdrawn                         = R("Weapons", "CrimeDefinition_FistsDrawn", ITEM),
    crime_threateningweapontooclose          = R("Weapons", "CrimeDefinition_ThreateningWeaponTooClose", ITEM),
    crime_fiststooclose                      = R("Weapons", "CrimeDefinition_FistsTooClose", ITEM),
    crime_directthreat_weapon                = R("Weapons", "CrimeDefinition_DirectThreat_Weapon", ITEM),
    crime_directthreat_fists                 = R("Weapons", "CrimeDefinition_DirectThreat_Fists", ITEM),
    crime_ignoredwarning_weapondrawn         = R("Weapons", "CrimeDefinition_IgnoredWarning_WeaponDrawn", ITEM),
    crime_ignoredwarning_fistsdrawn          = R("Weapons", "CrimeDefinition_IgnoredWarning_FistsDrawn", ITEM),
    crime_ignoredwarning_directthreat_weapon = R("Weapons", "CrimeDefinition_IgnoredWarning_DirectThreat_Weapon", ITEM),
    crime_ignoredwarning_directthreat_fists  = R("Weapons", "CrimeDefinition_IgnoredWarning_DirectThreat_Fists", ITEM),
    crime_blockingpath                       = R("Weapons", "CrimeDefinition_BlockingPath", ITEM),
}
-- Response modules that react to noises instead of crimes (see above).
local GATES = {
    { name = "AIARM_ToInvestigateSuspiciousSound_Interaction", g = "Theft" },        -- heard using an owned thing
    { name = "AIARM_ToInvestigateSuspiciousSound_Trespassing", g = "Trespassing" },  -- heard in an owned place
}
local GATE_TAG = "Character.Player"
local GATE_TRIES = 3         -- attempts per run before a module that does not take the tag is left alone
local GROUPS = { "Theft", "Trespassing", "Weapons" }
local GROUP_TEXT = { Theft = "theft", Trespassing = "trespassing", Weapons = "weapons" }
local SUBSYSTEMS = { "CrimeProcessingSubsystem", "CrimeProcessingSubsystem_Human", "CrimeProcessingSubsystem_Orc" }
-- the same three as classes (game scripts: the two rule sets for humans and orcs derive from the first)
local SUBSYSTEM_PATHS = {
    "/Script/Angelscript.CrimeProcessingSubsystem",
    "/Script/Angelscript.CrimeProcessingSubsystem_Human",
    "/Script/Angelscript.CrimeProcessingSubsystem_Orc",
}
local MEMORY_PATH = "/Script/G1R.CrimeMemorySubsystem"
M.paths = { SUBSYSTEM_PATHS[1], SUBSYSTEM_PATHS[2], SUBSYSTEM_PATHS[3], MEMORY_PATH }

local CHECK_SECONDS = 10     -- re-check the rule tables of known subsystems
local FIND_SECONDS = 300     -- the old way: look for subsystems again (one object scan each)
local PENDING_SECONDS = 1    -- look again this soon while the subsystems are not there yet
local FORGET_SECONDS = 30    -- look at the player's crime list again
local MAX_TRIES = 3          -- attempts per session before a switch that does not take is left alone

-- Survives session resets (class objects live as long as the game runs).
local ClassCache = {}
local NotFound = {}          -- name -> true: searched for once in this run and not there (not searched again)
local GateState = {}         -- module name -> { cdo, tries, closed, why }
local Touched = false        -- this run has changed a rule table at least once
local GateTouched = false    -- this run has closed a module at least once
local Forgotten = 0          -- crimes removed during this run

-- Per session
local Insts, Mems = {}, nil
local InstsBy, MemsBy = nil, nil     -- "engine" / "search": where the two came from last
local LastFind, LastCheck, LastForget = -1e9, -1e9, -1e9
local Dirty = true
local Tries = 0
local Reported = nil
local Now = { sig = "", rules = 0, sets = 0, problem = nil, pending = false, gates = 0, gateWhy = nil }

local function cfg(key, default)
    local v = Cfg and Cfg[key]
    if v == nil then return default end
    return v
end

local function norm(tag) return (tag:lower():gsub("%.", "_")) end

-- Crime tags are a hierarchy ("Crime.DirectThreat.Weapon.Melee" is judged by
-- the rule for "Crime.DirectThreat.Weapon"), exactly as the game looks them up.
local function ruleFor(tag)
    local t = tag
    while t and t ~= "" do
        local rule = RULES[norm(t)]
        if rule then return rule end
        t = t:match("^(.*)%.[^%.]*$")
    end
    return nil
end

local function tagName(k)
    local s = U.unwrap(k)
    local name = U.fname(U.get(s, "TagName"))
    if name == nil or name == "" or name == "None" then return nil end
    return name
end

local function className(cls)
    if not U.valid(cls) then return nil end
    local n = U.objectToken(cls)
    if not n then return nil end
    return (n:gsub("^UCrimeDefinition_", "CrimeDefinition_"))
end

local function classFor(name)
    local c = ClassCache[name]
    if c ~= nil and className(c) == name then return c end
    ClassCache[name] = nil
    -- by name: once per run at most (in this UE4SS build every such search
    -- walks all objects in memory); normally the rule tables supply the class
    if NotFound[name] then return nil end
    for _, path in ipairs({ "/Script/Angelscript." .. name, "/Script/Angelscript.U" .. name }) do
        c = U.findStatic(path)
        if c and className(c) == name then
            ClassCache[name] = c
            return c
        end
    end
    NotFound[name] = true
    return nil
end

-- Which groups are to be switched off right now.
local function wanted(masterOn)
    local off, names = {}, {}
    if masterOn and cfg("Enabled", true) == false then
        for _, g in ipairs(GROUPS) do
            if cfg("Disable" .. g, true) ~= false then
                off[g] = true
                names[#names + 1] = GROUP_TEXT[g]
            end
        end
    end
    return off, table.concat(names, ", ")
end

function M.describe(masterOn)
    local _, sig = wanted(masterOn ~= false)
    if sig == "" then return "on" end
    return "OFF (" .. sig .. ")"
end

-- ---------------------------------------------------------------------------
-- Rule tables
-- ---------------------------------------------------------------------------
local function readMap(o)
    local map = U.get(o, "CrimeDefinitions")
    if map == nil then return nil, "no rule table on the crime subsystem" end
    local entries, n = {}, 0
    local ok, err = pcall(function()
        map:ForEach(function(k, v)
            local tag = tagName(k)
            if tag then
                n = n + 1
                local cls = U.unwrap(v)
                entries[norm(tag)] = { tag = tag, cls = cls, name = className(cls) }
            end
        end)
    end)
    if not ok then return nil, "the rule table cannot be read (" .. tostring(err) .. ")" end
    if n == 0 then return nil, "the rule table is empty or unreadable" end
    return entries, n, map
end

local function remember(entries)
    for _, e in pairs(entries) do
        if e.name and ClassCache[e.name] == nil then ClassCache[e.name] = e.cls end
    end
end

-- Bring one subsystem's table to the wanted state. Returns a result table,
-- or nil and a reason when nothing could be done.
local function applyTo(o, off)
    local entries, total, map = readMap(o)
    if not entries then return nil, total end
    remember(entries)
    local res = { known = 0, off = 0, changed = 0, bad = 0, unknown = 0 }
    local plan, planned = {}, 0
    for key, rule in pairs(RULES) do
        local e = entries[key]
        if e then
            local want = off[rule.g] and rule.off or rule.orig
            if e.name == want then
                res.known = res.known + 1
            elseif e.name == rule.orig or e.name == rule.off then
                res.known = res.known + 1
                plan[key] = want
                planned = planned + 1
            else
                res.unknown = res.unknown + 1   -- not ours and not the game's: leave it alone
            end
        end
    end
    if res.known == 0 then
        -- say what was read, so the cause can be seen in the log
        local sample = {}
        for _, e in pairs(entries) do
            if #sample < 3 then sample[#sample + 1] = e.tag .. " = " .. tostring(e.name) end
        end
        table.sort(sample)
        return nil, ("the crime rules were not recognised (%d entries, e.g. %s)"):format(total, table.concat(sample, "; "))
    end
    if planned > 0 then
        local classes = {}
        for _, want in pairs(plan) do
            if classes[want] == nil then
                local c = classFor(want)
                if not c then return nil, "rule class " .. want .. " not found" end
                classes[want] = c
            end
        end
        local why
        local ok, err = pcall(function()
            map:ForEach(function(k, v)
                local tag = tagName(k)
                local want = tag and plan[norm(tag)]
                if want then
                    local ok2, err2 = pcall(function() v:set(classes[want]) end)
                    if not ok2 then why = why or tostring(err2) end
                end
            end)
        end)
        if not ok then why = why or tostring(err) end
        Touched = true
        local after = readMap(o)
        if not after then return nil, "the rule table could not be read back" end
        -- second way for entries that did not take: write the pair again
        local left = {}
        for key, want in pairs(plan) do
            if not (after[key] and after[key].name == want) then left[key] = want end
        end
        if next(left) ~= nil then
            local keys = {}
            pcall(function()
                map:ForEach(function(k)
                    local tag = tagName(k)
                    local key = tag and norm(tag)
                    if key and left[key] then keys[key] = U.unwrap(k) end
                end)
            end)
            for key, ks in pairs(keys) do
                local ok3, err3 = pcall(function() map:Add(ks, classes[left[key]]) end)
                if not ok3 then why = why or tostring(err3) end
            end
            local again, count = readMap(o)
            if again and count > total then
                -- the table grew: the pairs were added next to the game's own
                -- entries instead of replacing them (the game would still find
                -- its own). Take them out again and leave the table alone.
                for _, ks in pairs(keys) do pcall(function() map:Remove(ks) end) end
                local undone, count2 = readMap(o)
                why = (undone and count2 == total) and "entries can be neither changed nor replaced (table left as it was)"
                    or "entries were added and could not be taken out again - restart the game to be safe"
                res.bad = planned
                res.why = why
                res.off = 0
                return res
            end
            after = again or after
        end
        for key, want in pairs(plan) do
            if after[key] and after[key].name == want then
                res.changed = res.changed + 1
            else
                res.bad = res.bad + 1
            end
        end
        if res.bad > 0 then res.why = why or "the entries did not change" end
        entries = after
    end
    for key, rule in pairs(RULES) do
        local e = entries[key]
        if e and e.name == rule.off then res.off = res.off + 1 end
    end
    return res
end

local function findInstances()
    local seen, out = {}, {}
    local function scan(cls)
        for _, o in ipairs(U.findAll(cls)) do
            if U.valid(o) then
                local full = U.fullName(o)
                if full and not full:find("Default__", 1, true) and not seen[full] then
                    seen[full] = true
                    out[#out + 1] = { o = o, full = full }
                end
            end
        end
    end
    for i, cls in ipairs(SUBSYSTEMS) do
        scan(cls)
        -- one scan is enough when the base name already returned the subclasses
        if i == 1 then
            local human, orc = false, false
            for _, inst in ipairs(out) do
                local token = inst.full:match("^(%S+)") or ""
                if token:find("_Human", 1, true) then human = true end
                if token:find("_Orc", 1, true) then orc = true end
            end
            if human and orc then break end
        end
    end
    if #out == 0 then
        scan("UCrimeProcessingSubsystem_Human")
        scan("UCrimeProcessingSubsystem_Orc")
    end
    return out
end

-- The three subsystems, fresh from the engine. nil: the engine cannot be
-- asked; an empty list: they are not there (yet).
local function engineInstances()
    local out, seen = {}, {}
    for _, path in ipairs(SUBSYSTEM_PATHS) do
        local o, asked = U.subsystem("world", path)
        if not asked then return nil end
        if not o then return {} end      -- a world has all three or none
        local full = U.fullName(o)
        if not full then return {} end
        if not seen[full] then
            seen[full] = true
            out[#out + 1] = { o = o, full = full }
        end
    end
    return out
end

-- Returns true when a search was wanted and is not due yet (asked again on the next update).
local function refreshInstances(realNow)
    local fresh = engineInstances()
    if fresh then
        Insts, InstsBy = fresh, "engine"
        if #fresh > 0 then U.way("crime.subsystems_by", "engine") end
        return false
    end
    -- the old way: kept between two checks while they are the same objects
    if InstsBy == "engine" then Insts = {} end
    InstsBy = "search"
    local alive = {}
    for _, inst in ipairs(Insts) do
        if U.valid(inst.o) and U.fullName(inst.o) == inst.full then alive[#alive + 1] = inst end
    end
    local lost = #alive ~= #Insts
    Insts = alive
    -- a search among all objects: at most every 15 s while nothing is found, and only when one is due
    local since = realNow - LastFind
    if ((#Insts == 0 or lost) and since >= 15) or since >= FIND_SECONDS then
        if not U.mayWalk(realNow) then return #Insts == 0 end
        LastFind = realNow
        local op = U.op("crime: search for the crime subsystems")
        Insts = findInstances()
        U.done(op)
        if #Insts > 0 then U.way("crime.subsystems_by", "search") end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Noise reactions (response modules gated through RequiredOwnedTags)
-- ---------------------------------------------------------------------------
-- The tag list of a module: array, number of entries, their names. Entries
-- are only ever read inside the array's length (this UE4SS build adds an
-- element when an index past the end is touched).
local function gateTags(cdo)
    local arr = U.get(U.get(cdo, "RequiredOwnedTags"), "GameplayTags")
    if arr == nil then return nil end
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    if not ok or type(n) ~= "number" then return nil end
    local names = {}
    for i = 1, n do
        local e = U.unwrap(U.get(arr, i))
        names[i] = U.fname(U.get(e, "TagName")) or "?"
    end
    return arr, n, names
end

-- Brings one module to the wanted state. Returns closed (bool) or nil, reason.
local function applyGate(gate, closed)
    local st = GateState[gate.name]
    if not st then st = { tries = 0 }; GateState[gate.name] = st end
    if not U.valid(st.cdo) then
        -- searched for once per run at most (a search walks all objects)
        if st.missing then return nil, "module " .. gate.name .. " not found" end
        st.cdo = U.findStatic("/Script/Angelscript.Default__" .. gate.name)
        if not st.cdo then
            st.missing = true
            return nil, "module " .. gate.name .. " not found"
        end
    end
    local arr, n, names = gateTags(st.cdo)
    if not arr then return nil, "the tag list of " .. gate.name .. " cannot be read" end
    local ours = n == 1 and (names[1] == GATE_TAG or names[1] == "None" or names[1] == "?")
    if n > 0 and not ours then
        return nil, ("%s already asks for other tags (%s); left alone"):format(gate.name, table.concat(names, ", "))
    end
    if closed then
        if n == 1 and names[1] == GATE_TAG then return true end
        -- the list is empty (or holds our unfinished entry): entry 1 is ours
        local ok, err = pcall(function()
            local e = U.unwrap(arr[1])
            e.TagName = FName(GATE_TAG)
        end)
        GateTouched = true
        local _, n2, names2 = gateTags(st.cdo)
        if n2 == 1 and names2[1] == GATE_TAG then return true end
        if n2 == 1 then
            -- second way: write the whole entry
            pcall(function() arr[1] = { TagName = FName(GATE_TAG) } end)
            _, n2, names2 = gateTags(st.cdo)
            if n2 == 1 and names2[1] == GATE_TAG then return true end
        end
        -- it did not take: leave the list as the game made it
        if n2 and n2 > 0 then pcall(function() arr:Empty() end) end
        local _, n3 = gateTags(st.cdo)
        return nil, ("%s did not take the tag%s%s"):format(gate.name, ok and "" or (" (" .. tostring(err) .. ")"),
            n3 == 0 and "" or "; its tag list could not be emptied again - restart the game to be safe")
    end
    if n == 0 then return false end
    local ok, err = pcall(function() arr:Empty() end)
    local _, n2 = gateTags(st.cdo)
    if n2 == 0 then return false end
    return nil, ("%s could not be given back to the game%s"):format(gate.name, ok and "" or (" (" .. tostring(err) .. ")"))
end

-- All modules; returns how many are closed and the first problem.
local function applyGates(off)
    local closedCount, why = 0, nil
    for _, gate in ipairs(GATES) do
        local want = off[gate.g] == true
        local st = GateState[gate.name]
        if want or (st and st.closed ~= false) then
            if st and st.tries >= GATE_TRIES then
                why = why or st.why
            else
                local ok, res, reason = pcall(applyGate, gate, want)
                st = GateState[gate.name] or { tries = 0 }
                GateState[gate.name] = st
                if not ok then res, reason = nil, tostring(res) end
                if res == nil then
                    st.tries = st.tries + 1
                    st.why = reason
                    why = why or reason
                else
                    st.tries, st.why, st.closed = 0, nil, res
                    if res then closedCount = closedCount + 1 end
                end
                if DIAG then
                    local value = res == true and "closed" or (res == false and "open" or tostring(reason))
                    if value ~= Noted.gate[gate.name] then
                        Noted.gate[gate.name] = value
                        DIAG.note("crime.noise_module." .. (gate.name:match("([^_]+)$") or gate.name), value)
                    end
                end
            end
        end
    end
    return closedCount, why
end

-- ---------------------------------------------------------------------------
-- Forgetting what the player already did (the game's own crime memory)
-- ---------------------------------------------------------------------------
local function playerState()
    local s = U.get(U.pawn(), "PlayerState")
    if U.valid(s) then return s end
    s = U.get(U.controller(), "PlayerState")
    if U.valid(s) then return s end
    return nil
end

-- The game's crime memory: { o = subsystem, full = its name, sig = what was looked at last }.
local function memories()
    local o, asked = U.subsystem("world", MEMORY_PATH)
    if asked then
        local full = o and U.fullName(o) or nil
        if not full then return {} end
        -- the same object as at the last look keeps its mark of what was looked at
        if Mems and MemsBy == "engine" and #Mems == 1 and Mems[1].full == full then
            Mems[1].o = o
        else
            Mems = { { o = o, full = full, sig = nil } }
        end
        MemsBy = "engine"
        return Mems
    end
    -- the old way: kept while it is the same object, else searched for (when a search is due)
    if Mems and MemsBy == "search" then
        local ok = #Mems > 0
        for _, m in ipairs(Mems) do
            if not (U.valid(m.o) and U.fullName(m.o) == m.full) then ok = false end
        end
        if ok then return Mems end
    end
    Mems, MemsBy = nil, nil
    if not U.mayWalk() then return nil end      -- not now: asked again at the next look
    Mems, MemsBy = {}, "search"
    local op = U.op("crime: search for the crime memory")
    for _, found in ipairs(U.findAll("CrimeMemorySubsystem")) do
        local full = U.valid(found) and U.fullName(found) or nil
        if full and not full:find("Default__", 1, true) then Mems[#Mems + 1] = { o = found, full = full, sig = nil } end
    end
    U.done(op)
    return Mems
end

local function crimeIds(mem, state)
    local ok, list = U.try(mem.o, "GetAllCrimesCommitedBy", state)
    if not ok or type(list) ~= "table" then
        U.logOnce("crime-list", "crime: your crime list could not be read, so nothing is forgotten (" .. tostring(list) .. ")")
        return nil
    end
    local ids = {}
    for i = 1, #list do
        local id = U.num(U.unwrap(list[i]))
        if id then ids[#ids + 1] = math.floor(id) end
    end
    return ids
end

local function forget(off, sig)
    local state = playerState()
    if not state then
        U.logOnce("crime-state", "crime: the player state was not found, so earlier crimes are not forgotten")
        return 0
    end
    local removed = 0
    local mems = memories()
    if not mems then return nil end
    for _, mem in ipairs(mems) do
        local ids = crimeIds(mem, state)
        if ids then
            -- only look closer when the list (or what is switched off) changed
            local listSig = sig .. "|" .. table.concat(ids, ",")
            if listSig ~= mem.sig then
                local kept = {}
                for _, id in ipairs(ids) do
                    local entry = {}
                    local ok, found = U.try(mem.o, "GetCrimeByID", entry, id)
                    if not ok then
                        U.logOnce("crime-entry", "crime: an earlier crime could not be looked at, so it is kept (" .. tostring(found) .. ")")
                    end
                    local tag = ok and found ~= false and U.fname(U.get(U.get(entry, "CrimeType"), "TagName")) or nil
                    local rule = tag and ruleFor(tag)
                    if rule and off[rule.g] then
                        local ok2, done = U.try(mem.o, "RemoveCrime", id)
                        if ok2 and done ~= false then
                            removed = removed + 1
                            if cfg("Verbose", false) then U.log(("crime: forgot %s (#%d)"):format(tag, id)) end
                        else
                            kept[#kept + 1] = id
                        end
                    else
                        kept[#kept + 1] = id
                    end
                end
                mem.sig = sig .. "|" .. table.concat(kept, ",")
            end
        end
    end
    return removed
end

-- ---------------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------------
local function report(text)
    if text ~= Reported then
        Reported = text
        U.log(text)
    end
end

-- diagnostics only: the state of the rule tables, noted when it changes
local function noteTables(rules, sets, problem, sig)
    if rules == Noted.rules and sets == Noted.sets and problem == Noted.problem and sig == Noted.sig then return end
    Noted.rules, Noted.sets, Noted.problem, Noted.sig = rules, sets, problem, sig
    DIAG.note("crime.rule_tables", problem or ("%d rules in %d sets"):format(rules, sets),
        sig ~= "" and ("off: " .. sig) or "nothing switched off")
end

function M.tick(realNow, masterOn)
    local off, sig = wanted(masterOn ~= false)
    if sig == "" and not Touched and not GateTouched then
        if Now.sig ~= "" or Now.pending or Now.problem then
            Now = { sig = "", rules = 0, sets = 0, problem = nil, pending = false, gates = 0 }
        end
        return
    end
    if not Dirty and realNow - LastCheck < CHECK_SECONDS then return end
    if Tries >= MAX_TRIES then return end   -- it did not take; stop poking the game's tables
    LastCheck = realNow
    Dirty = false

    local waiting = refreshInstances(realNow)
    if #Insts == 0 then
        Now = { sig = sig, rules = 0, sets = 0, problem = nil, pending = true, gates = 0 }
        if waiting then
            Dirty = true                                            -- a search is not due yet: the next update asks again
        else
            if DIAG then noteTables(0, 0, "no crime subsystem found yet", sig) end
            LastCheck = realNow - CHECK_SECONDS + PENDING_SECONDS  -- looked at again soon
        end
        return
    end
    local op = U.op(("crime: check %d rule table(s)"):format(#Insts))
    local rules, sets, changed, bad, unknown, problem = 0, 0, 0, 0, 0, nil
    for _, inst in ipairs(Insts) do
        local ok, res, why = pcall(applyTo, inst.o, off)
        if not ok then
            problem = problem or tostring(res)
        elseif not res then
            problem = problem or tostring(why)
        else
            sets = sets + 1
            rules = rules + res.off
            changed = changed + res.changed
            bad = bad + res.bad
            unknown = unknown + res.unknown
            if res.bad > 0 then problem = problem or (("%d rules kept their old value: %s"):format(res.bad, tostring(res.why))) end
        end
    end
    -- the noise reactions follow the rule tables: closed for what is off, the
    -- game's own again for everything else
    local gates, gateWhy = applyGates(off)
    U.done(op)
    if gateWhy then U.logOnce("crime-gate:" .. gateWhy, "crime: noise reaction not switched (" .. gateWhy .. ")") end
    Now = { sig = sig, rules = rules, sets = sets, problem = problem, pending = false, unknown = unknown,
        gates = gates, gateWhy = gateWhy }
    if DIAG then noteTables(rules, sets, problem, sig) end

    if problem then
        Tries = Tries + 1
        report(("crime: switch not applied completely (%s)%s"):format(problem,
            sig ~= "" and "; the game's own rules stay active where it did not take" or ""))
        if Tries >= MAX_TRIES then
            U.log(("crime: left alone after %d tries; saving the settings again or loading a game tries once more"):format(Tries))
        end
    elseif sig ~= "" then
        Tries = 0
        report(("crime: OFF for %s - %d rules switched in %d rule set%s, %d noise reaction%s off%s"):format(sig, rules, sets,
            sets == 1 and "" or "s", gates, gates == 1 and "" or "s",
            unknown > 0 and (", unfamiliar entries left alone: %d"):format(unknown) or ""))
    else
        Tries = 0
        if changed > 0 or Reported ~= nil then report("crime: back to the game's own rules") end
        -- every live rule table is the game's again: nothing left to watch
        if rules == 0 and bad == 0 then Touched = false end
        if gates == 0 and not gateWhy then GateTouched = false end
    end

    if sig ~= "" and not problem and cfg("ForgetOldCrimes", true) ~= false
        and (changed > 0 or realNow - LastForget >= FORGET_SECONDS) then
        LastForget = realNow
        local opForget = U.op("crime: look at the player's crime list")
        local ok, n = pcall(forget, off, sig)
        U.done(opForget)
        if ok and n == nil then
            -- the crime memory could not be looked up right now: again in a moment
            LastForget = -1e9
            LastCheck = realNow - CHECK_SECONDS + PENDING_SECONDS
        elseif ok and type(n) == "number" and n > 0 then
            Forgotten = Forgotten + n
            U.log(("crime: %d earlier crime%s forgotten"):format(n, n == 1 and "" or "s"))
            if DIAG then DIAG.note("crime.forgotten", Forgotten) end
        elseif not ok then
            U.logError("crime-forget:" .. tostring(n), "crime: earlier crimes could not be looked up: " .. tostring(n))
        end
    end
end

function M.statusLine()
    if Now.pending then
        return ("crime: OFF wanted for %s, waiting for the game world"):format(Now.sig)
    end
    if Now.problem then
        return ("crime: switch not applied completely (%s)%s"):format(Now.problem,
            Tries >= MAX_TRIES and (" - left alone after %d tries"):format(Tries) or "")
    end
    if Now.sig ~= "" then
        return ("crime: OFF for %s (%d rules in %d rule sets, %d noise reactions off%s), %d earlier crimes forgotten this run")
            :format(Now.sig, Now.rules, Now.sets, Now.gates or 0,
                Now.gateWhy and (" - " .. Now.gateWhy) or "", Forgotten)
    end
    return "crime: the game's own rules" .. ((Touched or GateTouched) and " (restored)" or "")
end

function M.stats()
    return { sig = Now.sig, rules = Now.rules, sets = Now.sets, problem = Now.problem, pending = Now.pending,
        forgotten = Forgotten, touched = Touched, gates = Now.gates or 0, gateWhy = Now.gateWhy, gateTouched = GateTouched }
end

-- Called when the settings change: apply on the next update.
function M.init(util, config)
    U, Cfg = util, config or {}
    Dirty = true
    Tries = 0
    LastForget = -1e9
    for _, st in pairs(GateState) do st.tries = 0 end
    if Mems then for _, m in ipairs(Mems) do m.sig = nil end end
end

-- Called when the world became ready again without a full reset: the rule
-- tables are looked at on the next update (nothing is searched for because of
-- it, and the log is not repeated).
function M.recheck()
    Dirty = true
end

-- Called when a world is (re)loaded: the game has rebuilt its rule tables.
function M.reset()
    Insts, Mems = {}, nil
    InstsBy, MemsBy = nil, nil
    LastFind, LastCheck, LastForget = -1e9, -1e9, -1e9
    Dirty = true
    Tries = 0
    Reported = nil
    Now = { sig = "", rules = 0, sets = 0, problem = nil, pending = false, gates = 0 }
end

-- for the offline tests
M._rules = RULES
M._ruleFor = function(tag) return ruleFor(tag) end
M._forgetClasses = function()
    ClassCache, NotFound = {}, {}
    for _, st in pairs(GateState) do st.missing = nil end
end
M._gates = GATES
M._gateTag = GATE_TAG

return M
