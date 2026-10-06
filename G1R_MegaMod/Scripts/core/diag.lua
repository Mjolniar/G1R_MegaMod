-- ============================================================================
-- Diagnostics core: a flight recorder for the modules.
--
-- Everything is written below Scripts/diagnostics/ (see the README.txt there):
--   session-YYYYMMDD-HHMMSS.log   lines "HH:MM:SS [module] text" of this run
--   session-...-....report.txt    the report of this run (kept when the next run starts)
--   session-...-....ops           the last operations that called into the game (see "Operations")
--   report-latest.txt             modules, status, notes, counters, errors, last lines
--   report-YYYYMMDD-HHMMSS.txt    the same, on the console command "g1r diag"
--   dump-YYYYMMDD-HHMMSS.lua      what the modules' dump providers return ("g1r dump")
--   sessions.txt                  names of the session logs (plain Lua cannot list a folder)
--
-- Rules this file keeps:
--   * it never calls into the game and never searches for an object;
--   * no function here raises: every entry point runs inside pcall, file
--     errors are counted, and after three of them file output is switched off;
--   * normal lines are collected and written out on a timer; a breadcrumb or
--     an error is on disk before the call returns (open - append - close);
--   * an operation is a fixed-size record in a file that stays open and is not
--     buffered: it has left this process before the call returns, and costs a
--     few microseconds;
--   * all memory it uses is bounded.
-- ============================================================================

local Diag = { enabled = false, modules = {} }

local type, tostring, tonumber, pcall, next, ipairs, rawget = type, tostring, tonumber, pcall, next, ipairs, rawget
local io_open, os_remove = io.open, os.remove
local os_time, os_date, os_clock = os.time, os.date, os.clock
local fmt, concat, sort = string.format, table.concat, table.sort
local floor, mathtype = math.floor, math.type

local FOLDER = "Scripts/diagnostics"
local RING = 120                          -- recorder lines kept for reports
local FLUSH_AT = 500                      -- lines collected before an early write
local MAX_PENDING = 2000                  -- lines collected at most
local MAX_ERRORS = 50                     -- distinct errors kept with their traceback
local MAX_NOTES = 300                     -- notes per module
local MAX_NOTE_LINES = 20                 -- changes of one note that get a line
local MAX_PATHS = 5000                    -- lookup paths remembered
local MAX_MODULES = 32
local MAX_KINDS = 64                      -- counter kinds per module
local MAX_LINE = 2000                     -- characters of one recorder line
local MAX_SESSION_BYTES = 4 * 1024 * 1024 -- one session log
local SLOW_NOTED = 3                      -- slow calls per kind that get a line
local FAILED_WRITES = 3
local STATUS_LINES = 40                   -- lines taken from one status provider
local OPS_SLOTS = 256                     -- operations kept in the ring file
local OPS_WIDTH = 128                     -- bytes of one operation record, its line end included
local OPS_STATE_AT = 9                    -- where the state character of a record stands (counted from 0)
local OPS_TEXT = OPS_WIDTH - 32           -- characters of a record that are the operation's text
local DUMP_DEPTH = 8
local DUMP_VALUES = 200000
local SESSION_PATTERN = "^session%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%.log$"

local S = nil   -- the state of this run; nil until Diag.init

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
local function toText(v)
    if type(v) == "string" then return v end
    local ok, s = pcall(tostring, v)
    if ok and type(s) == "string" then return s end
    return "<" .. type(v) .. ">"
end

-- One physical line: no control characters, ASCII only, bounded.
local function oneLine(s)
    if #s > MAX_LINE then s = s:sub(1, MAX_LINE) .. " ..." end
    if s:find("[^\32-\126]") then
        s = s:gsub("\r", ""):gsub("\t", "    "):gsub("[^\32-\126]", "?")
    end
    return s
end

local function firstLine(s)
    return (toText(s):match("^[^\r\n]*") or "")
end

local function cut(s, n)
    if #s > n then return s:sub(1, n) .. "..." end
    return s
end

local function say(text)
    pcall(S.print, "[" .. S.name .. "] " .. text .. "\n")
end

-- Paths below the mod folder are recorded as <mod>/...: shorter, and a
-- diagnostics file that is passed on does not show where the game is installed.
-- Lua shortens a long file name in its messages to "..." and the end of the
-- name; those are brought to the same form.
local function scrub(s)
    local root = S.root
    if #root >= 4 then
        local a, b = s:find(root, 1, true)
        if a then
            local out, from = {}, 1
            while a do
                out[#out + 1] = s:sub(from, a - 1)
                out[#out + 1] = "<mod>"
                from = b + 1
                a, b = s:find(root, from, true)
            end
            out[#out + 1] = s:sub(from)
            s = concat(out)
        end
    end
    if s:find("...", 1, true) then
        s = s:gsub("%.%.%.[^\n\t]-[/\\](modules/[%w_]+/Scripts/)", "<mod>/%1")
        s = s:gsub("%.%.%.[^\n\t]-[/\\](Scripts/core/)", "<mod>/%1")
        s = s:gsub("%.%.%.[^\n\t]-[/\\](Scripts/main%.lua)", "<mod>/%1")
    end
    return s
end

local function stamp()
    local t = os_time()
    if t ~= S.stampTime then
        S.stampTime = t
        S.stampText = os_date("%H:%M:%S", t)
    end
    return S.stampText
end

local function number(v, default, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return default end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function settingsOf(given)
    if type(given) ~= "table" then given = {} end
    local level = given.Level
    if level == false then level = "off" end
    level = type(level) == "string" and level:lower() or "normal"
    if level ~= "off" and level ~= "normal" and level ~= "verbose" then level = "normal" end
    return {
        Level = level,
        SessionFiles = floor(number(given.SessionFiles, 5, 1, 100)),
        FlushSeconds = number(given.FlushSeconds, 20, 1, 3600),
        ReportMinutes = number(given.ReportMinutes, 5, 1, 1440),
        SlowCallMs = number(given.SlowCallMs, 30, 1, 60000),
    }
end

-- ---------------------------------------------------------------------------
-- Files (errors are counted, never raised)
-- ---------------------------------------------------------------------------
local function writeFailed(err)
    S.writeFailures = S.writeFailures + 1
    S.lastWriteError = scrub(oneLine(toText(err)))   -- the message names the file
    if S.fileOutput and S.writeFailures >= FAILED_WRITES then
        S.fileOutput = false
        S.pending, S.pendingCount = {}, 0
        say("diagnostics: file output switched off after " .. FAILED_WRITES .. " failed writes (" .. S.lastWriteError .. ")")
    end
end

local function writeFile(path, mode, text)
    if not S.fileOutput then return false end
    local f, err = io_open(path, mode)
    if not f then
        writeFailed(err)
        return false
    end
    local ok, werr = f:write(text)
    local closed, cerr = f:close()
    if not ok then
        writeFailed(werr)
        return false
    end
    if not closed then
        writeFailed(cerr)
        return false
    end
    S.writes = S.writes + 1
    return true
end

local function readLines(path)
    local f = io_open(path, "r")
    if not f then return nil end
    local list = {}
    for l in f:lines() do
        list[#list + 1] = (l:gsub("%s+$", ""))
        if #list >= 1000 then break end
    end
    f:close()
    return list
end

-- ---------------------------------------------------------------------------
-- Recorder
-- ---------------------------------------------------------------------------
local function flush()
    if S.pendingCount == 0 then return true end
    if not S.fileOutput or S.sizeLimit then
        S.pending, S.pendingCount = {}, 0
        return false
    end
    local text = concat(S.pending, "\n", 1, S.pendingCount) .. "\n"
    if not writeFile(S.sessionPath, "a", text) then return false end
    S.pending, S.pendingCount = {}, 0
    S.bytes = S.bytes + #text
    if S.bytes > MAX_SESSION_BYTES then
        S.sizeLimit = true
        writeFile(S.sessionPath, "a", stamp() .. " [diag] this session log is full; later lines are only kept for the reports\n")
    end
    return true
end

-- fileOnly: goes to the session log but not into the lines kept for reports.
local function put(module, text, fileOnly)
    local line = stamp() .. " [" .. module .. "] " .. oneLine(text)
    S.lineCount = S.lineCount + 1
    if not fileOnly then
        S.ringCount = S.ringCount + 1
        S.ring[(S.ringCount - 1) % RING + 1] = line
    end
    if not S.fileOutput or S.sizeLimit then return end
    if S.pendingCount >= FLUSH_AT then flush() end
    if S.pendingCount >= MAX_PENDING then
        S.dropped = S.dropped + S.pendingCount
        S.pending, S.pendingCount = {}, 0
    end
    S.pendingCount = S.pendingCount + 1
    S.pending[S.pendingCount] = line
end

local function moduleName(module)
    if type(module) == "string" and module ~= "" then return module end
    return "?"
end

local function record(module, text, prefix, fileOnly)
    text = toText(text):gsub("%s+$", "")
    if text == "" then return false end
    if not text:find("\n", 1, true) then
        put(module, prefix .. text, fileOnly)
        return true
    end
    local first = true
    for part in text:gmatch("[^\n]+") do
        put(module, first and (prefix .. part) or ("    " .. part), fileOnly)
        first = false
    end
    return true
end

local function line(module, text, fileOnly)
    if not S.on then return end
    if not record(moduleName(module), text, "", fileOnly) then return end
    if S.immediate or S.crumbOpen then
        S.crumbOpen = false
        flush()
    end
end

-- A breadcrumb is on disk before this returns. The line recorded after it is
-- written at once as well, so that a breadcrumb at the end of a session log
-- means: the game ended inside what the breadcrumb announces.
local function crumb(module, text, fileOnly)
    if not S.on then return end
    if not record(moduleName(module), text, "> ", fileOnly) then return end
    flush()
    S.crumbOpen = true
end

-- ---------------------------------------------------------------------------
-- Operations: what was the mod doing when the game ended?
--
-- A crash of the game cannot be caught from Lua, and a line that is written
-- on a timer is not there when it happens. So a module announces every step
-- that calls into the game (a search among all objects, a batch of calls on
-- objects it kept) with op() and takes the announcement back with done().
-- Both are a few bytes written at a fixed place of a small file that stays
-- open and is not buffered: the bytes have left this process before the call
-- returns, so they are still there when the process dies a moment later (a
-- power cut is another matter). The file is a ring of the last OPS_SLOTS
-- operations, one fixed-size line each:
--     00000042 > 12:19:44 repopulate containers: 25 new objects
--              ^ ">" begun, "=" finished
-- When the newest record of a session that ended still says ">", the game
-- went down inside that operation. An older ">" is an operation that raised
-- a Lua error before it could be taken back.
-- ---------------------------------------------------------------------------
local function opsFailed(why)
    S.opsFailures = S.opsFailures + 1
    S.opsWhy = scrub(oneLine(toText(why)))
    if S.opsFailures >= FAILED_WRITES and S.ops then
        local f = S.ops
        S.ops = nil
        pcall(function() f:close() end)
    end
end

local function opsOpen()
    if not S.fileOutput then return end
    local f, err = io_open(S.opsPath, "w+b")
    if not f then
        S.opsWhy = scrub(oneLine(toText(err)))
        return
    end
    pcall(function() f:setvbuf("no") end)
    S.ops = f
end

local function opsWrite(offset, text)
    local f = S.ops
    local ok, a, b = pcall(function()
        local at, err = f:seek("set", offset)
        if not at then return nil, err end
        return f:write(text)
    end)
    if ok and a then return true end
    opsFailed(ok and b or a)
    return false
end

-- Announces an operation. Returns its number (for opDone), or nil.
local function opBegin(module, text)
    if not S.on or not S.ops then return nil end
    text = oneLine(toText(text))
    if #text > OPS_TEXT then text = text:sub(1, OPS_TEXT) end
    local seq = S.opSeq + 1
    S.opSeq = seq
    local record = fmt("%08d > %s %-10.10s %s", seq % 100000000, stamp(), moduleName(module), text)
    record = record .. (" "):rep(OPS_WIDTH - 1 - #record) .. "\n"
    if not opsWrite(((seq - 1) % OPS_SLOTS) * OPS_WIDTH, record) then return nil end
    return seq
end

local function opDone(seq)
    if not S.on or not S.ops or type(seq) ~= "number" then return end
    if seq < 1 or seq > S.opSeq or S.opSeq - seq >= OPS_SLOTS then return end      -- its place holds a later operation by now
    opsWrite(((seq - 1) % OPS_SLOTS) * OPS_WIDTH + OPS_STATE_AT, "=")
end

-- ---------------------------------------------------------------------------
-- Per-module records
-- ---------------------------------------------------------------------------
local function mod(module)
    local name = moduleName(module)
    local m = S.mods[name]
    if m then return m end
    if #S.modOrder >= MAX_MODULES then
        name = "?"
        m = S.mods[name]
        if m then return m end
    end
    m = {
        name = name, errors = 0, misuse = 0,
        notes = {}, noteOrder = {},
        lookups = { calls = 0, first = 0, notFound = 0, repeated = 0, raised = 0, ms = 0, slowMs = 0 },
        finds = {}, findOrder = {},
        callbacks = {}, callbackOrder = {},
        registrations = {}, registrationOrder = {},
    }
    S.mods[name] = m
    S.modOrder[#S.modOrder + 1] = name
    return m
end

local function counter(map, order, kind, new)
    local c = map[kind]
    if c then return c end
    if #order >= MAX_KINDS then
        kind = "(other)"
        c = map[kind]
        if c then return c end
    end
    c = new
    map[kind] = c
    order[#order + 1] = kind
    return c
end

local function count(module, kind, ms, ok, where)
    if not S.on then return end
    local m = mod(module)
    kind = toText(kind)
    local c = m.callbacks[kind] or counter(m.callbacks, m.callbackOrder, kind, { calls = 0, errors = 0, slow = 0, maxMs = 0, ms = 0 })
    ms = tonumber(ms) or 0
    c.calls = c.calls + 1
    c.ms = c.ms + ms
    if ms > c.maxMs then c.maxMs = ms end
    if ok == false then c.errors = c.errors + 1 end
    if ms > S.settings.SlowCallMs then
        c.slow = c.slow + 1
        if c.slow <= SLOW_NOTED or S.verbose then
            line(m.name, fmt("slow callback: %s took %.1f ms%s", toText(where or kind), ms,
                (c.slow == SLOW_NOTED and not S.verbose) and " (further slow calls of this kind are only counted)" or ""))
        end
    end
end

local function find(module, kind, ms)
    if not S.on then return end
    local m = mod(module)
    kind = toText(kind)
    local c = m.finds[kind] or counter(m.finds, m.findOrder, kind, { calls = 0, ms = 0, maxMs = 0 })
    ms = tonumber(ms) or 0
    c.calls = c.calls + 1
    c.ms = c.ms + ms
    if ms > c.maxMs then c.maxMs = ms end
end

-- true when a search for this path was answered with an object earlier in
-- this run (the loader's cache then answers it without walking all objects).
local function seen(path)
    return S ~= nil and S.found[path] == true
end

-- raised: the error text when StaticFindObject itself raised (wrong arguments).
local function lookup(module, path, found, ms, raised)
    if not S.on then return end
    local m = mod(module)
    local l = m.lookups
    ms = tonumber(ms) or 0
    l.calls = l.calls + 1
    l.ms = l.ms + ms
    if raised ~= nil then
        l.raised = l.raised + 1
        if l.raised <= SLOW_NOTED or S.verbose then
            line(m.name, "lookup " .. (type(path) == "string" and path or "(not a plain path)") .. ": RAISED: " .. firstLine(raised))
        end
        return
    end
    if type(path) ~= "string" then
        -- a call in another form than StaticFindObject(path): counted and timed only
        if not found then l.notFound = l.notFound + 1 end
        if ms > l.slowMs then l.slowMs, l.slowPath = ms, "(not a plain path)" end
        return
    end
    if ms > l.slowMs then l.slowMs, l.slowPath = ms, path end
    if S.found[path] == true then
        -- found earlier in this run: the loader's cache answered
        if found then
            if S.verbose then line(m.name, fmt("lookup %s: found again, %.1f ms", path, ms)) end
            return
        end
        l.notFound = l.notFound + 1
        S.found[path] = nil
        S.missed[path] = 1
        line(m.name, fmt("lookup %s: NOT FOUND any more, %.1f ms", path, ms))
        return
    end
    -- every search from here on walked all objects
    local misses = S.missed[path]
    if misses then l.repeated = l.repeated + 1 else l.first = l.first + 1 end
    if found then
        if misses then
            S.missed[path] = nil
            S.found[path] = true
        elseif S.pathCount < MAX_PATHS then
            S.pathCount = S.pathCount + 1
            S.found[path] = true
        end
        line(m.name, fmt("lookup %s: found%s, %.1f ms", path,
            misses and (" (after " .. misses .. " search(es) without a result)") or "", ms))
        return
    end
    l.notFound = l.notFound + 1
    if misses then
        S.missed[path] = misses + 1
        line(m.name, fmt("lookup %s: NOT FOUND again (search number %d for this path; each one walks all objects), %.1f ms",
            path, misses + 1, ms))
        return
    end
    if S.pathCount < MAX_PATHS then
        S.pathCount = S.pathCount + 1
        S.missed[path] = 1
    end
    line(m.name, fmt("lookup %s: NOT FOUND, %.1f ms", path, ms))
end

-- Result of a registration call (RegisterHook, NotifyOnNewObject, ...).
local function registration(module, kind, where, ok, err, always)
    if not S.on then return end
    local m = mod(module)
    kind = toText(kind)
    local r = m.registrations[kind] or counter(m.registrations, m.registrationOrder, kind, { ok = 0, failed = 0 })
    if ok then
        r.ok = r.ok + 1
        if always or S.verbose then line(m.name, toText(where) .. ": registered") end
        return
    end
    r.failed = r.failed + 1
    local text = toText(where) .. ": FAILED: " .. scrub(firstLine(err))
    if not r.first then r.first = text end
    line(m.name, text)
    flush()
end

-- quiet: the caller has written its own line to UE4SS.log already.
local function failure(module, where, trace, quiet)
    if not S.on then return end
    local m = mod(module)
    m.errors = m.errors + 1
    S.errorTotal = S.errorTotal + 1
    trace = scrub(toText(trace))
    local first = firstLine(trace)
    local key = m.name .. "\n" .. first
    local e = S.errorIndex[key]
    if e then
        e.count = e.count + 1
        e.last = stamp()
        return
    end
    if #S.errors >= MAX_ERRORS then
        S.errorsNotKept = S.errorsNotKept + 1
        return
    end
    e = { module = m.name, where = oneLine(toText(where)), first = oneLine(first), trace = trace, count = 1, at = stamp() }
    e.last = e.at
    S.errors[#S.errors + 1] = e
    S.errorIndex[key] = e
    record(m.name, trace, "ERROR in " .. e.where .. ": ")
    flush()
    S.crumbOpen = false
    -- once per distinct error also in UE4SS.log, which would otherwise not show it
    if not quiet then say("error in " .. m.name .. " (" .. e.where .. "): " .. e.first) end
end

-- ---------------------------------------------------------------------------
-- Module handle (G1R_DIAG inside a module)
-- ---------------------------------------------------------------------------
local function misuse(m, text)
    m.misuse = m.misuse + 1
    if not m.misuseFirst then
        m.misuseFirst = text
        line(m.name, "diagnostics call ignored: " .. text)
    end
end

local function note(m, key, value, detail)
    if type(key) ~= "string" or key == "" then return misuse(m, "note: the key must be a text") end
    local v = cut(oneLine(toText(value)), 300)
    local n = m.notes[key]
    if n == nil then
        if #m.noteOrder >= MAX_NOTES then return misuse(m, "note: more than " .. MAX_NOTES .. " keys") end
        n = { first = v, value = v, changes = 0, at = stamp() }
        if detail ~= nil then n.detail = cut(oneLine(toText(detail)), 300) end
        m.notes[key] = n
        m.noteOrder[#m.noteOrder + 1] = key
        line(m.name, "note " .. key .. " = " .. v .. (n.detail and (" (" .. n.detail .. ")") or ""))
        return
    end
    if n.value == v then return end
    local old = n.value
    n.value = v
    n.changes = n.changes + 1
    n.changedAt = stamp()
    n.detail = detail ~= nil and cut(oneLine(toText(detail)), 300) or nil
    if n.changes <= MAX_NOTE_LINES then
        line(m.name, "note " .. key .. " = " .. v .. (n.detail and (" (" .. n.detail .. ")") or "") .. " [was " .. old .. "]"
            .. (n.changes == MAX_NOTE_LINES and " (further changes of this note are only counted)" or ""))
    end
end

local function handle(module)
    if not S.on then return nil end
    local m = mod(module)
    if m.handle then return m.handle end
    local function guarded(f)
        return function(...)
            local ok, err = pcall(f, ...)
            if not ok then
                S.internal = S.internal + 1
                S.internalFirst = S.internalFirst or toText(err)
            end
        end
    end
    local h = {}
    h.note = guarded(function(key, value, detail) note(m, key, value, detail) end)
    h.event = guarded(function(text)
        if text == nil then return misuse(m, "event: no text") end
        line(m.name, text)
    end)
    h.crumb = guarded(function(text)
        if text == nil then return misuse(m, "crumb: no text") end
        crumb(m.name, text)
    end)
    h.status = guarded(function(fn)
        if type(fn) ~= "function" then return misuse(m, "status: a function is expected") end
        m.status = fn
    end)
    h.dump = guarded(function(fn)
        if type(fn) ~= "function" then return misuse(m, "dump: a function is expected") end
        m.dump = fn
    end)
    h.version = guarded(function(text)
        if text == nil then return misuse(m, "version: no text") end
        m.version = cut(oneLine(toText(text)), 60)
    end)
    -- an operation that calls into the game: op(text) -> number, done(number)
    h.op = function(text)
        local ok, seq = pcall(opBegin, m.name, text)
        if ok then return seq end
        S.internal = S.internal + 1
        S.internalFirst = S.internalFirst or toText(seq)
        return nil
    end
    h.done = guarded(opDone)
    m.handle = h
    return h
end

-- Calls a provider a module registered. The call is announced in the session
-- log first: a provider is module code and may read from the game.
local function provider(m, which)
    local fn = m[which]
    if type(fn) ~= "function" then return nil, "no provider" end
    for _, r in ipairs(Diag.modules) do
        -- a module that did not load completely is not asked for anything
        if r.name == m.name and r.state == "failed" then return nil, "the module did not load" end
    end
    crumb("diag", which .. " provider of " .. m.name, true)
    local ok, result = pcall(fn)
    line("diag", which .. " provider of " .. m.name .. (ok and " returned" or " failed"), true)
    if not ok then
        failure(m.name, which .. " provider", result)
        return nil, "provider failed: " .. firstLine(result)
    end
    return result
end

local function statusOf(m)
    local list, why = provider(m, "status")
    if list == nil then
        if why == "no provider" or why == "the module did not load" then return {} end
        return { "(" .. why .. ")" }
    end
    if type(list) ~= "table" then return { cut(oneLine(toText(list)), 500) } end
    local out = {}
    for i = 1, #list do
        if i > STATUS_LINES then
            out[#out + 1] = "(" .. (#list - STATUS_LINES) .. " more lines)"
            break
        end
        out[#out + 1] = cut(oneLine(toText(list[i])), 500)
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Status (console) and report
-- ---------------------------------------------------------------------------
local function resultText(r)
    if r.state == "ok" then return "loaded" end
    if r.state == "off" then return "switched off in config.lua" end
    if r.state == "separate" then return "not loaded - the separate mod " .. toText(r.error) .. " is installed and enabled" end
    if r.state == "absent" then return "not installed (its main.lua is not there)" end
    return "FAILED" .. (r.error and (" - " .. cut(oneLine(scrub(firstLine(r.error))), 300)) or "")
end

local function fileText()
    if not S.on then return "off" end
    if not S.fileOutput then return "file output off (" .. toText(S.lastWriteError or "?") .. ")" end
    if S.sizeLimit then return FOLDER .. "/" .. S.sessionFile .. " (full)" end
    return FOLDER .. "/" .. S.sessionFile
end

-- The part of the load line after "diagnostics ".
local function summary()
    if not S.on then return "off" end
    if not S.fileOutput then return S.level .. ", no file output (" .. toText(S.lastWriteError or "?") .. ")" end
    return S.level .. " -> " .. FOLDER .. "/" .. S.sessionFile
end

local function noteCount()
    local n = 0
    for _, name in ipairs(S.modOrder) do n = n + #S.mods[name].noteOrder end
    return n
end

local function statusLines()
    local out = {}
    out[#out + 1] = fmt("%s v%s, %.1f minutes since load", S.name, S.version, (os_time() - S.startTime) / 60)
    for _, r in ipairs(Diag.modules) do
        local name = toText(r.name)
        local m = S.mods[name]
        local text = name .. ": " .. resultText(r)
        if m then
            if m.version then text = text .. ", version " .. m.version end
            if S.on then text = text .. ", " .. m.errors .. " error(s), " .. #m.noteOrder .. " note(s)" end
        end
        out[#out + 1] = text
        if m and S.on then
            for _, l in ipairs(statusOf(m)) do out[#out + 1] = "  " .. l end
        end
    end
    if not S.on then
        out[#out + 1] = "diagnostics: off (Config.Diagnostics.Level in Scripts/config.lua)"
        return out
    end
    out[#out + 1] = fmt("diagnostics: %s, %s, %d line(s), %d error(s), %d note(s)%s",
        S.level, fileText(), S.lineCount, S.errorTotal, noteCount(),
        S.internal > 0 and (", " .. S.internal .. " internal problem(s)") or "")
    return out
end

-- plain: without asking the modules for their status lines.
local function buildReport(plain)
    local out = {}
    local function add(s) out[#out + 1] = s end
    local now = os_time()
    add(S.name .. " v" .. S.version .. " - diagnostics report")
    add("time: " .. os_date("%Y-%m-%d %H:%M:%S", now))
    add(fmt("minutes since load: %.1f", (now - S.startTime) / 60))
    add("level: " .. S.level)
    add("session log: " .. S.sessionFile .. fmt(" (%d lines recorded, %d bytes written)", S.lineCount, S.bytes))
    add("file output: " .. (S.fileOutput and "on" or "off") .. fmt(" (%d failed writes%s)", S.writeFailures,
        S.lastWriteError and (", last: " .. S.lastWriteError) or ""))
    add("operations: " .. S.opSeq .. " announced" .. (S.ops and (" (" .. S.sessionBase .. ".ops)")
        or (" - not recorded" .. (S.opsWhy and (": " .. S.opsWhy) or ""))))
    if S.dropped > 0 then add("lines not written: " .. S.dropped) end
    if S.internal > 0 then add("internal problems of the diagnostics: " .. S.internal .. " (first: " .. oneLine(toText(S.internalFirst)) .. ")") end

    add("")
    add("== modules ==")
    for _, r in ipairs(Diag.modules) do
        local name = toText(r.name)
        local m = S.mods[name]
        add(name .. ": " .. resultText(r) .. ((m and m.version) and (", version " .. m.version) or ""))
    end
    if #Diag.modules == 0 then add("(none)") end

    add("")
    add("== status ==")
    local any = false
    if plain then
        add("(the modules are not asked while the mod is loading; see the next report)")
        any = true
    else
        for _, name in ipairs(S.modOrder) do
            local m = S.mods[name]
            if m.status then
                for _, l in ipairs(statusOf(m)) do
                    add("[" .. name .. "] " .. l)
                    any = true
                end
            end
        end
    end
    if not any then add("(no module gave status lines)") end

    add("")
    add("== notes ==")
    any = false
    for _, name in ipairs(S.modOrder) do
        local m = S.mods[name]
        if #m.noteOrder > 0 then
            add("[" .. name .. "]")
            local keys = {}
            for i, k in ipairs(m.noteOrder) do keys[i] = k end
            sort(keys)
            for _, k in ipairs(keys) do
                local n = m.notes[k]
                local text = k .. " = " .. n.value .. (n.detail and (" (" .. n.detail .. ")") or "") .. " [first seen " .. n.at .. "]"
                if n.changes > 0 then
                    text = text .. fmt(" [changed %d time(s), last %s, first value: %s]", n.changes, n.changedAt, n.first)
                end
                add(text)
                any = true
            end
        end
        if m.misuse > 0 then
            add("[" .. name .. "] " .. m.misuse .. " diagnostics call(s) ignored (first: " .. toText(m.misuseFirst) .. ")")
            any = true
        end
    end
    if not any then add("(none)") end

    add("")
    add("== counters ==")
    any = false
    for _, name in ipairs(S.modOrder) do
        local m = S.mods[name]
        local l = m.lookups
        if l.calls > 0 then
            add(fmt("[%s] lookups: %d calls, %d first-time, %d not found, %d repeated after not found, %.1f ms total, slowest %.1f ms %s%s",
                name, l.calls, l.first, l.notFound, l.repeated, l.ms, l.slowMs, toText(l.slowPath or "-"),
                l.raised > 0 and fmt(", %d call(s) raised", l.raised) or ""))
            any = true
        end
        for _, kind in ipairs(m.findOrder) do
            local c = m.finds[kind]
            add(fmt("[%s] %s: %d calls, %.1f ms total, max %.1f ms", name, kind, c.calls, c.ms, c.maxMs))
            any = true
        end
        for _, kind in ipairs(m.callbackOrder) do
            local c = m.callbacks[kind]
            add(fmt("[%s] callbacks %s: %d calls, %d errors, %d slow, max %.1f ms, %.1f ms total", name, kind, c.calls, c.errors, c.slow, c.maxMs, c.ms))
            any = true
        end
        for _, kind in ipairs(m.registrationOrder) do
            local r = m.registrations[kind]
            add(fmt("[%s] registered %s: %d ok, %d failed%s", name, kind, r.ok, r.failed, r.first and (" (first: " .. oneLine(r.first) .. ")") or ""))
            any = true
        end
    end
    if not any then add("(none)") end

    add("")
    add("== errors ==")
    add(fmt("count: %d (%d distinct%s)", S.errorTotal, #S.errors,
        S.errorsNotKept > 0 and (", " .. S.errorsNotKept .. " more not kept") or ""))
    for _, e in ipairs(S.errors) do
        add(fmt("[%s] %d x in %s, first %s, last %s", e.module, e.count, e.where, e.at, e.last))
        for part in e.trace:gmatch("[^\n]+") do add("    " .. oneLine(part)) end
    end

    add("")
    local n = S.ringCount < RING and S.ringCount or RING
    add("== last " .. n .. " recorder lines ==")
    for i = S.ringCount - n + 1, S.ringCount do
        add(S.ring[(i - 1) % RING + 1])
    end
    add("")
    return concat(out, "\n")
end

local function report(stamped, plain)
    if not S.on then return nil, "diagnostics are off" end
    flush()
    if not S.fileOutput then return nil, "file output is off (" .. toText(S.lastWriteError or "?") .. ")" end
    local text = buildReport(plain)
    S.lastReport = os_time()
    local name = "report-latest.txt"
    local ok = writeFile(S.dir .. "/" .. name, "w", text)
    -- the same under the session's own name: report-latest.txt is rewritten by the next game start, and the
    -- report of a session that ended badly is the one that is wanted afterwards
    writeFile(S.dir .. "/" .. S.sessionBase .. ".report.txt", "w", text)
    if stamped then
        name = os_date("report-%Y%m%d-%H%M%S.txt", os_time())
        ok = writeFile(S.dir .. "/" .. name, "w", text)
    end
    if not ok then return nil, "the report could not be written (" .. toText(S.lastWriteError or "?") .. ")" end
    S.reports = S.reports + 1
    return S.dir .. "/" .. name, FOLDER .. "/" .. name
end

-- ---------------------------------------------------------------------------
-- Dump
-- ---------------------------------------------------------------------------
local function quote(s)
    return '"' .. s:gsub('[%c"\\\127-\255]', function(c) return fmt("\\%03d", c:byte()) end) .. '"'
end

-- A number as Lua source that reads back as the same value of the same kind.
local function numberText(v)
    if mathtype(v) == "integer" then
        if v == math.mininteger then return "(-9223372036854775807-1)" end   -- the literal itself would be read as a float
        return fmt("%d", v)
    end
    if v ~= v then return "(0/0)" end
    if v == math.huge then return "(1/0)" end
    if v == -math.huge then return "(-1/0)" end
    local s = fmt("%.14g", v)
    if tonumber(s) ~= v then s = fmt("%.17g", v) end
    if not s:find("[%.eEnN]") then s = s .. ".0" end   -- stays a float
    return s
end

local function keyLess(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta == "number" end
    return a < b
end

local function refuse(ctx, path, why)
    if #ctx.refused < 50 then ctx.refused[#ctx.refused + 1] = path .. ": " .. why end
    ctx.refusedCount = ctx.refusedCount + 1
end

-- Writes v as Lua source. What cannot be written (a table that contains
-- itself, more than DUMP_DEPTH levels, something that is not plain data) is
-- refused: a marker text takes its place and the refusal is listed.
local function serialize(v, out, indent, depth, path, ctx)
    local t = type(v)
    if t == "string" then
        out[#out + 1] = quote(v)
    elseif t == "number" then
        out[#out + 1] = numberText(v)
    elseif t == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif t == "table" then
        if ctx.open[v] then
            refuse(ctx, path, "cycle")
            out[#out + 1] = quote("<refused: cycle>")
            return
        end
        if depth > DUMP_DEPTH then
            refuse(ctx, path, "deeper than " .. DUMP_DEPTH .. " levels")
            out[#out + 1] = quote("<refused: depth>")
            return
        end
        local keys = {}
        for k in next, v do
            local kt = type(k)
            if kt == "string" or (kt == "number" and k == k) then
                keys[#keys + 1] = k
            else
                refuse(ctx, path, "key of type " .. kt)
            end
        end
        if #keys == 0 then
            out[#out + 1] = "{}"
            return
        end
        sort(keys, keyLess)
        ctx.open[v] = true
        out[#out + 1] = "{\n"
        for _, k in ipairs(keys) do
            ctx.values = ctx.values + 1
            if ctx.values > DUMP_VALUES then
                refuse(ctx, path, "more than " .. DUMP_VALUES .. " values")
                break
            end
            local isText = type(k) == "string"
            out[#out + 1] = indent .. "  [" .. (isText and quote(k) or numberText(k)) .. "] = "
            serialize(rawget(v, k), out, indent .. "  ", depth + 1, path .. "." .. (isText and k or numberText(k)), ctx)
            out[#out + 1] = ",\n"
        end
        out[#out + 1] = indent .. "}"
        ctx.open[v] = nil
    else
        refuse(ctx, path, "value of type " .. t)
        out[#out + 1] = quote("<refused: " .. t .. ">")
    end
end

local function dump()
    if not S.on then return nil, "diagnostics are off" end
    flush()
    if not S.fileOutput then return nil, "file output is off (" .. toText(S.lastWriteError or "?") .. ")" end
    local now = os_time()
    local ctx = { open = {}, values = 0, refused = {}, refusedCount = 0 }
    local body, states = {}, {}
    local names = {}
    for i, name in ipairs(S.modOrder) do names[i] = name end
    sort(names)
    for _, name in ipairs(names) do
        local m = S.mods[name]
        if m.dump then
            local data, why = provider(m, "dump")
            if type(data) == "table" then
                body[#body + 1] = "  [" .. quote(name) .. "] = "
                serialize(data, body, "  ", 1, name, ctx)
                body[#body + 1] = ",\n"
                states[name] = "dumped"
            elseif data == nil then
                states[name] = why or "the provider returned nothing"
            else
                states[name] = "the provider returned a " .. type(data) .. ", not a table"
            end
        end
    end
    local meta = {
        mod = S.name, version = S.version,
        time = os_date("%Y-%m-%d %H:%M:%S", now),
        minutes = floor((now - S.startTime) / 6 + 0.5) / 10,
        modules = states,
        refused = ctx.refused,
        refusedCount = ctx.refusedCount,
    }
    local out = { "-- " .. S.name .. " v" .. S.version .. " dump, " .. meta.time .. "\nreturn {\n  [\"_meta\"] = " }
    serialize(meta, out, "  ", 1, "_meta", { open = {}, values = 0, refused = {}, refusedCount = 0 })
    out[#out + 1] = ",\n"
    out[#out + 1] = concat(body)
    out[#out + 1] = "}\n"
    local name = os_date("dump-%Y%m%d-%H%M%S.lua", now)
    if not writeFile(S.dir .. "/" .. name, "w", concat(out)) then
        return nil, "the dump could not be written (" .. toText(S.lastWriteError or "?") .. ")"
    end
    line("diag", "dump written: " .. name .. (ctx.refusedCount > 0 and (" (" .. ctx.refusedCount .. " value(s) refused)") or ""))
    return S.dir .. "/" .. name, FOLDER .. "/" .. name
end

-- ---------------------------------------------------------------------------
-- Timer (called once per second by the loader)
-- ---------------------------------------------------------------------------
local function tick()
    if not S.on then return end
    local now = os_time()
    if now < S.lastFlush then S.lastFlush = now end
    if now < S.lastReport then S.lastReport = now end
    if now - S.lastFlush >= S.settings.FlushSeconds then
        S.lastFlush = now
        flush()
    end
    if now - S.lastReport >= S.settings.ReportMinutes * 60 then
        S.lastReport = now
        report(false)
    end
end

-- ---------------------------------------------------------------------------
-- Start of a run
-- ---------------------------------------------------------------------------
-- Session logs are named in sessions.txt; those beyond SessionFiles are
-- deleted (only names of the form session-YYYYMMDD-HHMMSS.log, only in the
-- diagnostics folder).
local function prune()
    local index = S.dir .. "/sessions.txt"
    local names, have = {}, {}
    for _, l in ipairs(readLines(index) or {}) do
        if l:match(SESSION_PATTERN) and not have[l] and l ~= S.sessionFile then
            have[l] = true
            names[#names + 1] = l
        end
    end
    names[#names + 1] = S.sessionFile
    local keep = S.settings.SessionFiles
    local first = #names - keep + 1
    if first < 1 then first = 1 end
    local kept = {}
    for i, n in ipairs(names) do
        if i < first then
            os_remove(S.dir .. "/" .. n)
            -- what belongs to that session log (names derived from its name, nothing else)
            local base = n:sub(1, -5)
            os_remove(S.dir .. "/" .. base .. ".report.txt")
            os_remove(S.dir .. "/" .. base .. ".ops")
            S.pruned = S.pruned + 1
        else
            kept[#kept + 1] = n
        end
    end
    writeFile(index, "w", concat(kept, "\n") .. "\n")
end

local function init(root, settings, realPrint, version)
    local s = settingsOf(settings)
    local now = os_time()
    if type(root) ~= "string" or root == "" then root = "." end
    if type(version) ~= "table" then version = {} end
    S = {
        root = root,
        dir = root .. "/" .. FOLDER,
        print = type(realPrint) == "function" and realPrint or print,
        name = type(version.name) == "string" and version.name or "mod",
        version = type(version.version) == "string" and version.version or "?",
        settings = s,
        level = s.Level,
        on = s.Level ~= "off",
        verbose = s.Level == "verbose",
        immediate = s.Level == "verbose",
        startTime = now,
        startClock = os_clock(),
        lastFlush = now,
        lastReport = now,
        sessionBase = os_date("session-%Y%m%d-%H%M%S", now),
        opSeq = 0, opsFailures = 0,
        pending = {}, pendingCount = 0,
        ring = {}, ringCount = 0, lineCount = 0,
        fileOutput = true, writeFailures = 0, writes = 0, bytes = 0, dropped = 0, pruned = 0, reports = 0,
        mods = {}, modOrder = {},
        errors = {}, errorIndex = {}, errorTotal = 0, errorsNotKept = 0,
        found = {}, missed = {}, pathCount = 0,
        internal = 0,
    }
    S.sessionFile = S.sessionBase .. ".log"
    S.sessionPath = S.dir .. "/" .. S.sessionFile
    S.opsPath = S.dir .. "/" .. S.sessionBase .. ".ops"
    Diag.enabled = S.on
    if not S.on then
        S.fileOutput = false
        return true
    end
    record("loader", fmt("session start: %s v%s, %s, diagnostics %s", S.name, S.version, os_date("%Y-%m-%d %H:%M:%S", now), S.level), "")
    flush()
    prune()
    opsOpen()
    return true
end

-- ---------------------------------------------------------------------------
-- Entry points: none of them raises, whatever happens inside
-- ---------------------------------------------------------------------------
local function entry(f)
    return function(...)
        if S == nil then return nil, "the diagnostics are not started" end
        local ok, a, b = pcall(f, ...)
        if ok then return a, b end
        S.internal = S.internal + 1
        S.internalFirst = S.internalFirst or toText(a)
        return nil, "internal problem of the diagnostics"
    end
end

function Diag.init(root, settings, realPrint, version)
    local ok, result = pcall(init, root, settings, realPrint, version)
    if ok and result == true then return true end
    Diag.enabled = false
    if S then S.on, S.fileOutput = false, false end
    return false, toText(result)
end

Diag.line = entry(line)                  -- (module, text) recorder line, written on the next timed flush
Diag.crumb = entry(crumb)                -- (module, text) recorder line, on disk before this returns
Diag.error = entry(failure)              -- (module, where, traceback, quiet)
Diag.count = entry(count)                -- (module, kind, ms, ok, where) one callback call
Diag.find = entry(find)                  -- (module, kind, ms) one FindAllOf / FindFirstOf call
Diag.lookup = entry(lookup)              -- (module, path, found, ms, raised) one StaticFindObject call
Diag.op = entry(opBegin)                 -- (module, text) -> number: an operation that calls into the game begins
Diag.opDone = entry(opDone)              -- (number) it returned
Diag.registration = entry(registration)  -- (module, kind, where, ok, err, always) one registration call
Diag.tick = entry(tick)                  -- timed flush and report
Diag.flush = entry(function() if S.on then return flush() end end)
Diag.report = entry(report)              -- (stamped, plain) -> path, path inside the mod folder
Diag.dump = entry(dump)                  -- -> path, path inside the mod folder
Diag.handle = entry(handle)              -- (module) -> G1R_DIAG of that module
Diag.summary = entry(summary)            -- text for the load line
Diag.seen = seen                         -- (path) -> found earlier in this run
function Diag.status()                   -- -> list of lines for the console
    if S == nil then return {} end
    local ok, list = pcall(statusLines)
    if ok and type(list) == "table" then return list end
    S.internal = S.internal + 1
    S.internalFirst = S.internalFirst or toText(list)
    return { "diagnostics: internal problem (" .. oneLine(toText(list)) .. ")" }
end
-- Without a timer every line is written at once.
Diag.immediate = entry(function(on) S.immediate = (on ~= false) or S.verbose end)

return Diag
