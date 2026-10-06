-- ============================================================================
-- Tests of the loader and the core (Scripts/main.lua, Scripts/core/*.lua).
--
--   lua5.4 test_loader.lua          (from any directory)
--
-- The mod's Scripts/ folder is copied into a temp mod folder for every case
-- (below G1R_TEST_TMP or /tmp/g1r-tests), together with tiny modules written
-- by the test, or with the real modules. UE4SS is replaced by
-- ../mock/ue4ss.lua. Nothing is written into the mod itself.
-- Needs a POSIX shell (cp, mkdir, rm, ls, mv), like the module harnesses.
-- Last line: "loader tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local MOD = HERE .. "../../../"
local TMP = (os.getenv("G1R_TEST_TMP") or "/tmp/g1r-tests") .. "/loader"
local Mock = dofile(HERE .. "../mock/ue4ss.lua")
local VER = dofile(MOD .. "Scripts/core/version.lua").version         -- the tests follow the mod's own version file
local VERP = VER:gsub("%.", "%%.")                                       -- the same, for use inside a pattern
-- ... and the mod's own list of modules: "repopulate ok, markers ok, ..." as the load line has it
local MODULE_LIST = dofile(MOD .. "Scripts/core/modules.lua")
local NAMES = {}
for i, m in ipairs(MODULE_LIST) do NAMES[i] = m.name end
local function summary(states)          -- states: { name = "off" | "FAILED" | ... }; every other module "ok"
    local parts = {}
    for i, name in ipairs(NAMES) do parts[i] = name .. " " .. ((states or {})[name] or "ok") end
    return table.concat(parts, ", ")
end
local ALL_OK = summary()
-- What the loader's start searches by path: nothing. (The kit looks its own paths up at the first map load:
-- dev/tests/core/test_kit.lua, section 17.) The cases below count searches and operations from there.
local START_SEARCHES = 0

local oks, fails = 0, 0
local function check(condition, text)
    if condition then
        oks = oks + 1
        io.write("ok   ", text, "\n")
    else
        fails = fails + 1
        io.write("FAIL ", text, "\n")
    end
    return condition
end
local function section(text) io.write("== ", text, "\n") end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local H = {}

function H.q(path) return "'" .. path:gsub("'", "'\\''") .. "'" end
function H.sh(command)
    local ok = os.execute(command)
    if not ok then error("command failed: " .. command) end
end
function H.read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
end
function H.write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end
function H.exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end
function H.list(dir)
    local out = {}
    local p = io.popen("ls -1 " .. H.q(dir) .. " 2>/dev/null")
    if p then
        for l in p:lines() do out[#out + 1] = l end
        p:close()
    end
    table.sort(out)
    return out
end
function H.lines(text)
    local out = {}
    for l in (text or ""):gmatch("[^\r\n]+") do out[#out + 1] = l end
    return out
end
function H.count(text, plain)
    local n, from = 0, 1
    while true do
        local a, b = (text or ""):find(plain, from, true)
        if not a then return n end
        n, from = n + 1, b + 1
    end
end
function H.has(text, plain) return text ~= nil and text:find(plain, 1, true) ~= nil end
function H.printed(ue, plain)
    for _, l in ipairs(ue.printed) do
        if l:find(plain, 1, true) then return l end
    end
    return nil
end
function H.printedCount(ue, plain)
    local n = 0
    for _, l in ipairs(ue.printed) do
        if l:find(plain, 1, true) then n = n + 1 end
    end
    return n
end
-- The lines of one part of a report ("== name ==" up to the next "== ").
function H.part(report, name)
    local out, inside = {}, false
    for _, l in ipairs(H.lines(report)) do
        if l:sub(1, 3) == "== " then
            inside = l:sub(4, 3 + #name) == name
        elseif inside then
            out[#out + 1] = l
        end
    end
    return out
end
function H.find(list, plain)
    for _, l in ipairs(list) do
        if l:find(plain, 1, true) then return l end
    end
    return nil
end
function H.same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then
        if a ~= a and b ~= b then return true end   -- nan
        return a == b
    end
    for k, v in pairs(a) do
        if not H.same(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- A module that only shows its environment to the test (TEST is a global of
-- the test, reached through the environment's fallback to _G).
function H.probe(name, extra)
    return ([[
local NAME = %q
TEST[NAME] = { env = _G, diag = G1R_DIAG, source = debug.getinfo(1, "S").source, loaded = true,
    print = print, find = StaticFindObject, loop = LoopInGameThreadWithDelay }
print("[Fake_" .. NAME .. "] v1 loaded\n")
%s
]]):format(name, extra or "")
end

-- A temp mod folder: the real Scripts/ plus modules given as source text.
--   options.folder     name of the mod folder (default "TempMod")
--   options.modules    { name = source | false }; default: a probe for each module of core/modules.lua
--   options.files      { ["modules/x/Scripts/y.lua"] = text, ... } written after the copy (false = removed)
--   options.real       copy the real modules/ instead
function H.mod(case, options)
    options = options or {}
    local root = TMP .. "/" .. case .. "/" .. (options.folder or "TempMod")
    H.sh("rm -rf " .. H.q(TMP .. "/" .. case) .. " && mkdir -p " .. H.q(root) .. " && cp -r " .. H.q(MOD .. "Scripts") .. " " .. H.q(root .. "/"))
    if options.real then
        H.sh("cp -r " .. H.q(MOD .. "modules") .. " " .. H.q(root .. "/"))
    else
        local modules = options.modules or {}
        for _, name in ipairs(NAMES) do
            local source = modules[name]
            if source == nil then source = H.probe(name) end
            if source then
                H.sh("mkdir -p " .. H.q(root .. "/modules/" .. name .. "/Scripts"))
                H.write(root .. "/modules/" .. name .. "/Scripts/main.lua", source)
            end
        end
    end
    for path, text in pairs(options.files or {}) do
        if text == false then
            os.remove(root .. "/" .. path)
        else
            H.write(root .. "/" .. path, text)
        end
    end
    return root
end

-- Runs the loader of a temp mod with a fresh mock.
--   options.mock      options of the mock
--   options.time      fake start time (os.time value)
--   options.prepare   function(ue) called after the mock is installed, before the loader runs
function H.start(root, options)
    options = options or {}
    local ue = Mock.new(options.mock)
    if options.time then ue.time = options.time end
    ue:install()
    if options.prepare then options.prepare(ue) end
    _G.TEST = {}
    _G.G1R_LOADER_TEST = {}
    local ctx = { ue = ue, root = root, dir = root .. "/Scripts/diagnostics", t0 = ue.time }
    ctx.session = ctx.dir .. "/" .. os.date("session-%Y%m%d-%H%M%S.log", ctx.t0)
    ctx.ok, ctx.err = pcall(dofile, options.main or (root .. "/Scripts/main.lua"))
    ctx.T, ctx.M = _G.G1R_LOADER_TEST, _G.TEST
    ctx.diag = ctx.T.diag
    return ctx
end
function H.stop(ctx)
    ctx.ue:uninstall()
    _G.TEST, _G.G1R_LOADER_TEST = nil, nil
end
function H.seconds(ctx, n)   -- n seconds pass, the registered game-thread loops run once per second
    for _ = 1, n do
        ctx.ue:advance(1)
        ctx.ue:tick()
    end
end
function H.config(body)
    return "local Config = {}\n" .. body .. "\nreturn Config\n"
end

local LOAD_LINE = "^%[G1R_MegaMod%] v" .. VERP .. " loaded: " .. ALL_OK .. " | diagnostics normal %-> Scripts/diagnostics/session%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%.log\n$"

local tests = {}

-- ---------------------------------------------------------------------------
-- The mock itself (what the other tests rely on)
-- ---------------------------------------------------------------------------
function tests.mock()
    section("mock: fires callbacks the way UE4SS does")
    local ue = Mock.new()
    ue:install()
    local n = 0
    local handle = LoopInGameThreadWithDelay(250, function() n = n + 1 return true end)
    ue:tick(3)
    check(math.type(handle) == "integer" and n == 3, "game-thread loop: handle returned, return value of the callback ignored")
    LoopInGameThreadWithDelay(100, function() error("x") end)
    ue:tick()
    check(#ue.errors == 1 and #ue.loops == 2, "game-thread loop: an error is logged and the loop stays")
    local a = 0
    LoopAsync(100, function() a = a + 1 return a >= 2 end)
    ue:tickAsync() ue:tickAsync() ue:tickAsync()
    check(a == 2 and #ue.asyncLoops == 0, "LoopAsync: ends when the callback returns true")
    LoopAsync(100, function() error("y") end)
    ue:tickAsync()
    check(#ue.asyncLoops == 0 and #ue.errors == 2, "LoopAsync: ends after an error")
    check(not pcall(LoopInGameThreadWithDelay, 2.5, function() end) and not pcall(LoopAsync, 100, 5), "wrong argument types raise")
    check(not pcall(RegisterHook, "/Script/X.Y:Z", function() end), "RegisterHook on an unknown function raises")
    ue.functions["/Script/X.Y:Z"] = true
    local pre, post = RegisterHook("/Script/X.Y:Z", function() return 1 end, function() return 2 end)
    local fired = ue:fireHook("/Script/X.Y:Z", {})
    check(pre == 1 and post == 2 and fired[1].pre == 1 and fired[1].post == 2, "RegisterHook: two ids, pre and post callback results")
    RegisterConsoleCommandHandler("c", function() return "yes" end)
    check(ue:fireConsole("c 1 2") == false and ue.errors[#ue.errors]:find("must return true or false", 1, true), "console handler must return a boolean")
    check(ue:fireConsole("unknown") == nil, "console: no handler -> nil")
    local missing = StaticFindObject("/Script/No.Thing")
    check(missing ~= nil and missing:IsValid() == false and FindFirstOf("Nothing"):IsValid() == false and FindAllOf("Nothing") == nil,
        "finders: 'not found' is an invalid object (StaticFindObject, FindFirstOf) or nil (FindAllOf)")
    local order = {}
    RegisterLoadMapPreHook(function() order[#order + 1] = 1 error("z") end)
    RegisterLoadMapPreHook(function() order[#order + 1] = 2 end)
    ue:fireLoadMapPre()
    check(#order == 1, "load-map hooks: an error in one callback skips the ones after it")
    ue:advance(5)
    check(os.clock() == 105.0 and os.date("%H:%M:%S") == "12:00:05" and os.time() == ue.time, "fake clock drives os.clock, os.time and os.date")
    print("a", 1)
    check(ue.printed[#ue.printed] == "a\t\t1", "print is captured")
    ue:uninstall()
    check(rawget(_G, "StaticFindObject") == nil and rawget(_G, "LoopAsync") == nil and os.clock() ~= 105.0, "uninstall puts everything back")
end

-- ---------------------------------------------------------------------------
-- Loader
-- ---------------------------------------------------------------------------
function tests.loader()
    section("loader: root, load line, test hook")
    local root = H.mod("basic", { folder = "Some Folder" })
    local c = H.start(root)
    check(c.ok, "the loader runs (" .. tostring(c.err) .. ")")
    check(c.T.root == root and c.T.scripts == root .. "/Scripts", "root comes from the script path, whatever the folder is called")
    check(c.T.name == "G1R_MegaMod" and c.T.version == VER and VER:match("^%d+%.%d+%.%d+$") ~= nil, "name and version come from core/version.lua")
    local line = c.ue.printed[#c.ue.printed]
    check(line:match(LOAD_LINE) ~= nil, "load line: " .. line:gsub("\n", ""))
    check(H.has(line, os.date("session-%Y%m%d-%H%M%S.log", c.t0)), "load line names the session log of this run")
    check(c.M.repopulate.loaded and c.M.markers.loaded, "both modules ran")
    check(c.M.repopulate.source == "@" .. root .. "/modules/repopulate/Scripts/main.lua", "a module's chunk is named after its file (it finds its folder from that)")
    check(H.exists(c.session), "session log exists right after loading")
    local log = H.read(c.session)
    check(H.has(log, "[repopulate] [Fake_repopulate] v1 loaded") and H.has(log, "[markers] [Fake_markers] v1 loaded")
        and H.has(log, "[loader] v" .. VER .. " loaded: repopulate ok, markers ok"), "the load lines of the modules and of the loader are on disk after loading")
    check(#c.ue.loops == 2 and c.ue.loops[1].ms == 250 and c.ue.loops[2].ms == 1000, "the loader's own loops: four times a second for the shared services, once per second for the diagnostics")
    check(c.ue.console.g1r ~= nil and #c.ue.console.g1r == 1, "console command g1r registered")
    local kept = {}
    for i, r in ipairs(c.diag.modules) do kept[i] = r.name .. " " .. r.state end
    check(table.concat(kept, ", ") == ALL_OK, "load results kept in the order of core/modules.lua: " .. table.concat(kept, ", "))
    check(rawget(_G, "G1R_DIAG") == nil, "G1R_DIAG is not a global")
    H.stop(c)

    section("loader: name and version are taken from core/version.lua only")
    root = H.mod("version", { files = { ["Scripts/core/version.lua"] = 'return { name = "OtherName", version = "9.8.7" }\n' } })
    c = H.start(root)
    line = c.ue.printed[#c.ue.printed]
    check(H.has(line, "[OtherName] v9.8.7 loaded: " .. ALL_OK .. " | diagnostics normal") and line:sub(1, 11) == "[OtherName]", "load line uses them")
    check(H.has(H.read(c.dir .. "/report-latest.txt"), "OtherName v9.8.7 - diagnostics report"), "report header uses them")
    check(c.ue:fireConsole("g1r help") == true and H.printed(c.ue, "[OtherName] commands:") ~= nil, "console output uses them")
    H.stop(c)

    section("loader: core/version.lua missing")
    root = H.mod("noversion", { folder = "FolderName", files = { ["Scripts/core/version.lua"] = false } })
    c = H.start(root)
    check(c.ok and H.printed(c.ue, "[FolderName] core/version.lua could not be read") ~= nil, "one log line, the folder name is used")
    check(H.printed(c.ue, "[FolderName] v? loaded: repopulate ok, markers ok") ~= nil, "modules still run")
    H.stop(c)

    section("loader: a module that raises at load")
    root = H.mod("raise", { modules = { repopulate = 'TEST.before = true\nerror("boom at load")\n' } })
    c = H.start(root)
    check(c.ok, "the loader itself does not raise")
    check(c.M.before == true and c.M.markers and c.M.markers.loaded, "the next module is loaded")
    line = c.ue.printed[#c.ue.printed]
    check(H.has(line, "loaded: repopulate FAILED, markers ok"), "load line says FAILED")
    local reported = H.printed(c.ue, "module repopulate failed to load:")
    check(reported ~= nil and H.has(reported, "main.lua:2: boom at load") and H.printedCount(c.ue, "boom at load") == 1, "reported once in the log, with file and line")
    check(c.diag.modules[1].state == "failed" and H.has(c.diag.modules[1].error, "stack traceback"), "load result holds the error with its traceback")
    log = H.read(c.session)
    check(H.has(log, "[repopulate] ERROR in load: ") and H.has(log, "boom at load") and H.has(log, "stack traceback:"), "session log holds the error with the traceback")
    local report = H.read(c.dir .. "/report-latest.txt")
    check(H.find(H.part(report, "modules"), "repopulate: FAILED - ") ~= nil and H.find(H.part(report, "modules"), "markers: loaded") ~= nil, "report: module list shows it")
    check(H.find(H.part(report, "errors"), "count: 1 (1 distinct)") ~= nil, "report: counted as an error")
    H.stop(c)

    section("loader: what a module registered before it raised does nothing afterwards")
    root = H.mod("raise-after-register", { modules = { repopulate = [[
TEST.calls = 0
RegisterConsoleCommandHandler("inert", function() TEST.calls = TEST.calls + 1; return true end)
RegisterKeyBind(120, function() TEST.calls = TEST.calls + 1 end)
LoopInGameThreadWithDelay(100, function() TEST.calls = TEST.calls + 1 end)
error("boom after registering")
]] } })
    c = H.start(root)
    check(c.ok and H.has(c.ue.printed[#c.ue.printed], "loaded: repopulate FAILED, markers ok"), "(the module raised after three registrations)")
    c.ue:fireConsole("inert")
    c.ue:fireKey(120)
    c.ue:tick(5)
    check(c.M.calls == 0, "none of its callbacks runs: console command, key and loop stay registered (UE4SS cannot take them back) but do nothing")
    check(c.M.markers and c.M.markers.loaded, "the next module is not touched by it")
    H.stop(c)

    section("loader: a module file that is missing or does not compile")
    root = H.mod("missing", { modules = { repopulate = false, markers = "this is not lua\n" } })
    c = H.start(root)
    check(c.ok and H.has(c.ue.printed[#c.ue.printed], "loaded: " .. summary({ repopulate = "not installed", markers = "FAILED" })), "one reported as not installed, one as FAILED; the loader goes on")
    check(H.printed(c.ue, "module repopulate") == nil and c.diag.modules[1].state == "absent" and H.has(H.read(c.session), "module repopulate: not installed (modules/repopulate/Scripts/main.lua is not there)"),
        "a module whose main.lua is not there was taken out: no line in UE4SS.log, one in the session log")
    c.ue:fireConsole("g1r")
    check(H.printed(c.ue, "repopulate: not installed (its main.lua is not there)") ~= nil, "g1r shows it")
    check(H.printed(c.ue, "module markers failed to load:") ~= nil and H.has(H.printed(c.ue, "module markers failed to load:"), "main.lua:1:"), "syntax error: reason logged")
    H.stop(c)

    section("loader: config.lua missing, broken, not a table, or reaching for globals")
    local broken = {
        missing = false,
        broken = "local Config = {\n",
        ["not a table"] = "return 5\n",
        globals = "os.exit(3)\nreturn {}\n",
    }
    local kinds = {}
    for k in pairs(broken) do kinds[#kinds + 1] = k end
    table.sort(kinds)
    for _, kind in ipairs(kinds) do
        root = H.mod("config", { files = { ["Scripts/config.lua"] = broken[kind] } })
        c = H.start(root)
        check(c.ok and H.printedCount(c.ue, "config.lua missing or invalid (") == 1, kind .. ": one log line")
        check(c.ue.printed[#c.ue.printed]:match(LOAD_LINE) ~= nil, kind .. ": defaults (both modules, diagnostics normal)")
        H.stop(c)
    end
    root = H.mod("config", { files = { ["Scripts/config.lua"] = H.config('Config.Diagnostics = { Level = "LOUD", SessionFiles = "many", FlushSeconds = -5, ReportMinutes = {}, SlowCallMs = 0/0 }') } })
    c = H.start(root)
    check(c.ok and c.ue.printed[#c.ue.printed]:match(LOAD_LINE) ~= nil, "values of the wrong kind: defaults for each")
    H.stop(c)

    section("loader: a module switched off")
    root = H.mod("off", { files = { ["Scripts/config.lua"] = H.config("Config.Modules = { Repopulate = false, Markers = true }") } })
    c = H.start(root)
    check(c.M.repopulate == nil and c.M.markers ~= nil, "the module is not loaded")
    check(H.has(c.ue.printed[#c.ue.printed], "loaded: repopulate off, markers ok"), "load line says off")
    check(c.diag.modules[1].state == "off", "load result says off")
    check(c.ue:fireConsole("g1r") == true and H.printed(c.ue, "repopulate: switched off in config.lua") ~= nil, "g1r shows it")
    H.stop(c)

    section("loader: the same thing is installed as a separate mod")
    -- the temp mod sits in <case>/TempMod: <case>/ plays the Mods folder
    local function mods(case, files)
        local r = H.mod(case)
        for path, text in pairs(files) do
            local dir = (TMP .. "/" .. case .. "/" .. path):match("^(.*)/[^/]*$")
            H.sh("mkdir -p " .. H.q(dir))
            H.write(TMP .. "/" .. case .. "/" .. path, text)
        end
        return r
    end
    root = mods("separate1", { ["G1R_Repopulate/Scripts/main.lua"] = "-- the separate mod\n", ["G1R_Repopulate/enabled.txt"] = "" })
    c = H.start(root)
    check(c.ok and c.M.repopulate == nil and c.M.markers ~= nil, "enabled by enabled.txt: the module is not loaded, the other one is")
    check(H.printedCount(c.ue, "module repopulate not loaded: the separate mod G1R_Repopulate is installed and enabled") == 1
        and H.has(c.ue.printed[#c.ue.printed], "loaded: " .. summary({ repopulate = "left to the separate mod G1R_Repopulate" }) .. " | diagnostics normal"),
        "one log line, and the load line says it")
    c.ue:fireConsole("g1r")
    check(H.printed(c.ue, "repopulate: not loaded - the separate mod G1R_Repopulate is installed and enabled") ~= nil
        and H.has(H.read(c.dir .. "/report-latest.txt"), "repopulate: not loaded - the separate mod G1R_Repopulate is installed and enabled"),
        "g1r and the report show it")
    H.stop(c)
    root = mods("separate2", { ["NPCMarkers/Scripts/main.lua"] = "-- the separate mod\n",
        ["mods.txt"] = "; a comment\r\nCheatManagerEnablerMod : 0\r\n  NPCMarkers : 1\r\nG1R_Repopulate : 1\r\n" })
    c = H.start(root)
    check(c.ok and c.M.markers == nil and c.M.repopulate ~= nil and H.has(c.ue.printed[#c.ue.printed], "repopulate ok, markers left to the separate mod NPCMarkers"),
        "enabled in mods.txt: not loaded (a line for a mod whose folder is not there changes nothing)")
    H.stop(c)
    root = mods("separate3", { ["NPCMarkers/Scripts/main.lua"] = "-- the separate mod\n", ["G1R_Repopulate/readme.txt"] = "left-over folder\n",
        ["mods.txt"] = "NPCMarkers : 0\nG1R_Repopulate : 1\nNPCMarkersExtra : 1\n; NPCMarkers : 1\n" })
    c = H.start(root)
    check(c.ok and c.M.markers ~= nil and c.M.repopulate ~= nil and c.ue.printed[#c.ue.printed]:match(LOAD_LINE) ~= nil,
        "switched off in mods.txt, or a folder without the mod's script: the modules are loaded")
    H.stop(c)
    root = mods("separate4", { ["NPCMarkers/Scripts/main.lua"] = "-- the separate mod\n", ["G1R_Repopulate/Scripts/main.lua"] = "-- the separate mod\n",
        ["mods.txt"] = "NPCMarkers:1\n  G1R_Repopulate  :   1 \n" })
    c = H.start(root)
    check(c.ok and c.M.markers == nil and c.M.repopulate == nil, "mods.txt is read the way UE4SS reads it: spaces do not count")
    H.stop(c)
    -- lines UE4SS itself does not take: a ";" anywhere in the line, a tab in the name (only spaces are removed)
    root = mods("separate7", { ["NPCMarkers/Scripts/main.lua"] = "-- the separate mod\n", ["G1R_Repopulate/Scripts/main.lua"] = "-- the separate mod\n",
        ["mods.txt"] = "NPCMarkers : 1 ; switched on for a test\r\nG1R_Repopulate\t: 1\r\n" })
    c = H.start(root)
    check(c.ok and c.M.markers ~= nil and c.M.repopulate ~= nil and c.ue.printed[#c.ue.printed]:match(LOAD_LINE) ~= nil,
        "a line with a ';' in it and a name with a tab are lines UE4SS does not start a mod from: the modules are loaded")
    H.stop(c)
    -- a byte order mark at the start of the file; the flag is what follows the last colon
    root = mods("separate8", { ["NPCMarkers/Scripts/main.lua"] = "-- the separate mod\n", ["G1R_Repopulate/Scripts/main.lua"] = "-- the separate mod\n",
        ["mods.txt"] = "\239\187\191NPCMarkers : 1\r\nG1R_Repopulate : 1 : 0\r\n" })
    c = H.start(root)
    check(c.ok and c.M.markers == nil and c.M.repopulate ~= nil and H.has(c.ue.printed[#c.ue.printed], "repopulate ok, markers left to the separate mod NPCMarkers"),
        "a byte order mark before the first line is skipped; with two colons the text after the last one decides")
    H.stop(c)
    root = mods("separate9", { ["NPCMarkers/Scripts/main.lua"] = "-- the separate mod\n", ["G1R_Repopulate/Scripts/main.lua"] = "-- the separate mod\n",
        ["mods.txt"] = "NPCMarkers : 0 : 1\nG1R_Repopulate : 10\n" })
    c = H.start(root)
    check(c.ok and c.M.markers == nil and c.M.repopulate == nil, "on when the text after the last colon starts with 1")
    H.stop(c)
    root = mods("separate6", { ["NPCMarkers/Scripts/main.lua"] = "-- the separate mod\n", ["NPCMarkers/enabled.txt"] = "", ["mods.txt"] = "NPCMarkers : 0\n" })
    c = H.start(root)
    check(c.ok and c.M.markers == nil, "enabled.txt in the folder is enough, whatever mods.txt says (UE4SS starts such a mod)")
    H.stop(c)
    root = mods("separate5", { ["NPCMarkers/Scripts/main.lua"] = "-- the separate mod\n", ["NPCMarkers/enabled.txt"] = "" })
    H.write(root .. "/Scripts/config.lua", H.config("Config.Modules = { Repopulate = true, Markers = false }"))
    c = H.start(root)
    check(c.ok and c.M.markers == nil and H.printedCount(c.ue, "not loaded: the separate mod") == 0 and H.has(c.ue.printed[#c.ue.printed], "markers off"),
        "a module that is switched off anyway is reported as off")
    H.stop(c)

    section("loader: diagnostics core cannot be loaded")
    local variants = {
        { "file missing", false },
        { "syntax error", "return {\n" },
        { "raises", 'error("no diag today")\n' },
        { "returns no table", "return 1\n" },
        { "init says no", 'return { modules = {}, init = function() return false, "not today" end }\n' },
        { "init raises", 'return { modules = {}, init = function() error("init broke") end }\n' },
    }
    for _, v in ipairs(variants) do
        root = H.mod("nodiag", { files = { ["Scripts/core/diag.lua"] = v[2] } })
        c = H.start(root)
        check(c.ok and H.printedCount(c.ue, "diagnostics not available (") == 1, v[1] .. ": one log line")
        check(c.M.repopulate and c.M.markers and c.M.repopulate.loaded and c.M.markers.loaded, v[1] .. ": modules still run")
        check(H.has(c.ue.printed[#c.ue.printed], "loaded: " .. ALL_OK .. " | diagnostics unavailable"), v[1] .. ": load line says unavailable")
        check(c.M.repopulate.diag == nil and c.M.repopulate.find == c.ue.globals.StaticFindObject and c.M.repopulate.print == c.ue.globals.print,
            v[1] .. ": no G1R_DIAG, plain API")
        check(#H.list(c.dir) == 1 and #c.ue.loops == 1 and c.ue.loops[1].ms == 250, v[1] .. ": nothing written, no timer for the diagnostics (the loop of the shared services runs)")
        check(c.ue:fireConsole("g1r") == true and H.printed(c.ue, "diagnostics: not available") ~= nil and H.printed(c.ue, "repopulate: loaded") ~= nil,
            v[1] .. ": g1r still answers")
        check(c.ue:fireConsole("g1r diag") == true and H.printed(c.ue, "no report written: the diagnostics are not available") ~= nil, v[1] .. ": g1r diag answers")
        H.stop(c)
    end

    section("loader: Level = \"off\"")
    root = H.mod("leveloff", { files = { ["Scripts/config.lua"] = H.config('Config.Diagnostics = { Level = "off" }') } })
    c = H.start(root)
    check(c.ok and H.has(c.ue.printed[#c.ue.printed], "loaded: " .. ALL_OK .. " | diagnostics off"), "load line says off")
    check(c.diag.enabled == false, "Diag.enabled is false")
    check(c.M.repopulate.diag == nil and rawget(c.M.repopulate.env, "G1R_DIAG") == nil, "no G1R_DIAG inside the modules")
    check(c.M.repopulate.find == c.ue.globals.StaticFindObject and c.M.repopulate.loop == c.ue.globals.LoopInGameThreadWithDelay
        and c.M.repopulate.print == c.ue.globals.print and rawget(c.M.repopulate.env, "RegisterHook") == nil, "no wrappers: the modules see the plain API")
    check(#c.ue.loops == 1 and c.ue.loops[1].ms == 250, "no timer registered for the diagnostics")
    c.M.repopulate.env.print("line while off\n")
    c.diag.line("x", "y") c.diag.crumb("x", "y") c.diag.error("x", "w", "t") c.diag.count("x", "k", 1, true) c.diag.lookup("x", "p", true, 1)
    H.seconds(c, 400)
    check(c.ue:fireConsole("g1r") == true and H.printed(c.ue, "diagnostics: off") ~= nil and H.printed(c.ue, "repopulate: loaded") ~= nil, "g1r still answers")
    check(c.ue:fireConsole("g1r diag") == true and H.printed(c.ue, "no report written: diagnostics are off") ~= nil, "g1r diag writes nothing and says why")
    check(c.ue:fireConsole("g1r dump") == true and H.printed(c.ue, "no dump written: diagnostics are off") ~= nil, "g1r dump writes nothing and says why")
    local files = H.list(c.dir)
    check(#files == 1 and files[1] == "README.txt", "no file was written (" .. table.concat(files, ", ") .. ")")
    H.stop(c)

    section("loader: core/sandbox.lua or core/console.lua cannot be loaded")
    root = H.mod("nosandbox", { files = { ["Scripts/core/sandbox.lua"] = "return nil\n" },
        modules = { repopulate = 'LEAK = 1\nTEST.r = { env = _G, sees = dofile(debug.getinfo(1, "S").source:match("^@(.*/)") .. "part.lua") }\n' },
        })
    H.write(root .. "/modules/repopulate/Scripts/part.lua", "return LEAK\n")
    c = H.start(root)
    check(c.ok and H.printedCount(c.ue, "core/sandbox.lua could not be used (") == 1, "sandbox: one log line")
    check(c.M.r ~= nil and c.M.markers ~= nil and H.has(c.ue.printed[#c.ue.printed], "repopulate ok, markers ok"), "sandbox: modules still run")
    check(rawget(_G, "LEAK") == nil and c.M.r.sees == 1, "sandbox: the stand-in still keeps globals inside the module and shares them with its files")
    H.stop(c)
    root = H.mod("noconsole", { files = { ["Scripts/core/console.lua"] = false } })
    c = H.start(root)
    check(c.ok and H.printedCount(c.ue, "console command g1r not available (") == 1 and c.ue.console.g1r == nil, "console: one log line, no command")
    check(c.M.repopulate and c.M.markers and c.ue.printed[#c.ue.printed]:match(LOAD_LINE) ~= nil, "console: modules and diagnostics still run")
    H.stop(c)
    root = H.mod("noconsolefn")
    c = H.start(root, { mock = { without = { "RegisterConsoleCommandHandler", "LoopInGameThreadWithDelay" } } })
    check(c.ok and H.printedCount(c.ue, "console command g1r not available (") == 1, "UE4SS without RegisterConsoleCommandHandler: one log line")
    c.M.repopulate.env.print("written at once\n")
    check(H.has(H.read(c.session), "no timer for the diagnostics") and H.has(H.read(c.session), "written at once"),
        "UE4SS without LoopInGameThreadWithDelay: said in the session log, lines are written at once")
    H.stop(c)

    section("loader: a script path with Windows separators")
    root = H.mod("winpath")
    H.write(root .. "/modules/repopulate/Scripts/main.lua", [[
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("^(.*/)[^/]+$")
TEST.win = { source = debug.getinfo(1, "S").source, dir = dir, part = dofile(dir .. "part.lua") }
]])
    H.write(root .. "/modules/repopulate/Scripts/part.lua", "return 'part loaded'\n")
    local WIN = "C:\\Games\\G1R\\Binaries\\Win64\\ue4ss\\Mods\\WinMod"      -- an invented path (lint:allow-path)
    local function translate(path)
        if type(path) ~= "string" then return path end
        if path:sub(1, #WIN) == WIN then path = root .. path:sub(#WIN + 1) end
        local forward = path:gsub("^C:/Games/G1R/Binaries/Win64/ue4ss/Mods/WinMod", root)
        return (forward:gsub("\\", "/"))
    end
    local realLoadfile, realOpen, realRemove = loadfile, io.open, os.remove
    local opened = {}
    c = H.start(root, {
        prepare = function()
            _G.loadfile = function(path, ...) opened[#opened + 1] = path return realLoadfile(translate(path), ...) end
            io.open = function(path, ...) opened[#opened + 1] = path return realOpen(translate(path), ...) end
            os.remove = function(path) return realRemove(translate(path)) end
        end,
        main = nil,
    })
    H.stop(c)
    _G.loadfile, io.open, os.remove = realLoadfile, realOpen, realRemove
    -- the loader was run from the real path above; now run it the way UE4SS names it
    local text = H.read(root .. "/Scripts/main.lua")
    local ue = Mock.new()
    ue:install()
    _G.TEST, _G.G1R_LOADER_TEST = {}, {}
    opened = {}
    _G.loadfile = function(path, ...)
        opened[#opened + 1] = path
        local chunk, err = realLoadfile(translate(path), ...)
        if chunk then
            -- name the chunk the way the path was given
            local source = H.read(translate(path))
            local rest = table.pack(...)
            if rest.n >= 2 then chunk = load(source, "@" .. path, rest[1], rest[2]) else chunk = load(source, "@" .. path) end
        end
        return chunk, err
    end
    io.open = function(path, ...) opened[#opened + 1] = path return realOpen(translate(path), ...) end
    os.remove = function(path) return realRemove(translate(path)) end
    local okRun, errRun = pcall(load(text, "@" .. WIN .. "\\Scripts\\main.lua"))
    _G.loadfile, io.open, os.remove = realLoadfile, realOpen, realRemove
    local T, M = _G.G1R_LOADER_TEST, _G.TEST
    check(okRun, "the loader runs (" .. tostring(errRun) .. ")")
    check(T.root == WIN and T.scripts == WIN .. "\\Scripts", "the prefix is kept exactly as given")
    local good = true
    -- allowed: the prefix as given (the mod folder, or its Scripts folder), then only '/'
    for _, p in ipairs(opened) do
        if p:sub(1, #WIN) == WIN then
            local rest = p:sub(#WIN + 1)
            if rest:sub(1, 8) == "\\Scripts" then rest = rest:sub(9) end
            if rest:find("\\", 1, true) then good = false end
        end
    end
    check(good and #opened > 5, "everything the loader adds to that prefix uses '/'")
    check(M.win ~= nil and M.win.source == "@" .. WIN .. "/modules/repopulate/Scripts/main.lua" and M.win.part == "part loaded",
        "a module finds its folder and its files from such a path")
    check(H.printed(ue, "loaded: " .. ALL_OK .. " | diagnostics normal -> Scripts/diagnostics/session-") ~= nil, "load line as usual")
    check(H.exists(root .. "/Scripts/diagnostics/report-latest.txt"), "diagnostics files are written below that prefix")
    ue:uninstall()
    _G.TEST, _G.G1R_LOADER_TEST = nil, nil

    section("loader: nothing can be found at all")
    ue = Mock.new()
    ue:install()
    _G.G1R_LOADER_TEST = {}
    local LOST = "D:\\Nowhere\\Mods\\Lost"      -- an invented path (lint:allow-path)
    local okNone, errNone = pcall(load(text, "@" .. LOST .. "\\Scripts\\main.lua"))
    check(okNone, "the loader does not raise (" .. tostring(errNone) .. ")")
    check(_G.G1R_LOADER_TEST.root == LOST and H.printed(ue, "[Lost] v? loaded: no modules | diagnostics unavailable") ~= nil
        and H.printedCount(ue, "[Lost] core/modules.lua could not be read (") == 1, "load line with the folder name, no modules (their list could not be read), diagnostics unavailable")
    ue:uninstall()
    _G.G1R_LOADER_TEST = nil
end

-- ---------------------------------------------------------------------------
-- The shared services (kit, settings) and the list of modules
-- ---------------------------------------------------------------------------
function tests.services()
    section("services: the kit and the settings service")
    -- a module that shows what it is given
    local probe = H.probe("repopulate", [[
TEST.repopulate.kit, TEST.repopulate.settings = G1R_KIT, G1R_SETTINGS
TEST.repopulate.rawKit = rawget(_G, "G1R_KIT")
]])
    local root = H.mod("services", { modules = { repopulate = probe } })
    local c = H.start(root)
    local M = c.M.repopulate
    check(c.ok and type(c.T.kit) == "table" and type(c.T.settings) == "table", "the loader loads both")
    check(M.kit == c.T.kit and M.settings == c.T.settings and M.rawKit == c.T.kit, "every module finds them in its environment as G1R_KIT and G1R_SETTINGS")
    check(rawget(_G, "G1R_KIT") == nil and rawget(_G, "G1R_SETTINGS") == nil, "they are no globals of the Lua state (other mods do not see them)")
    check(type(c.T.kit.findOnce) == "function" and type(c.T.settings.open) == "function" and c.T.settings.keyText("ctrl + y") == "CTRL+Y", "the settings service has the kit beside it (it asks it how keys are spelt)")
    local log = H.read(c.session)
    check(H.has(log, "[kit] registered") == false and not H.has(log, "ERROR in "), "loading them leaves no error in the session log")
    -- the loop: both are called four times a second, counted for the loader
    local kitTicks, settingsTicks = 0, 0
    local kitTick, settingsTick = c.T.kit.tick, c.T.settings.tick
    c.T.kit.tick = function() kitTicks = kitTicks + 1 return kitTick() end
    c.T.settings.tick = function() settingsTicks = settingsTicks + 1 return settingsTick() end
    for _ = 1, 8 do
        c.ue:advance(0.25)
        c.ue:tick()
    end
    check(kitTicks == 8 and settingsTicks == 8 and #c.ue.errors == 0, "the loader's loop calls both, every time")
    c.T.settings.tick = function() error("the settings service fails") end
    c.ue:advance(0.25)
    c.ue:tick()
    check(kitTicks == 9 and #c.ue.errors == 0, "one of them failing does not stop the other, and nothing reaches UE4SS")
    c.ue:fireConsole("g1r diag")
    local report = H.read(c.dir .. "/report-latest.txt")
    check(H.find(H.part(report, "counters"), "[loader] callbacks services: 9 calls, 1 errors") ~= nil, "report: the loop is counted with its failures (" .. tostring(H.find(H.part(report, "counters"), "services")) .. ")")
    check(H.find(H.part(report, "counters"), "[kit] registered RegisterLoadMapPreHook: 1 ok, 0 failed") ~= nil, "report: what the kit registers is counted as the kit's")
    H.stop(c)

    section("services: one of them cannot be loaded")
    for _, v in ipairs({
        { "kit.lua missing", { ["Scripts/core/kit.lua"] = false }, "core/kit.lua could not be used (", true, false },
        { "kit.lua raises", { ["Scripts/core/kit.lua"] = "error('kit broke')\n" }, "core/kit.lua could not be used (", true, false },
        { "kit.lua returns no table", { ["Scripts/core/kit.lua"] = "return 5\n" }, "core/kit.lua could not be used (", true, false },
        { "settings.lua missing", { ["Scripts/core/settings.lua"] = false }, "core/settings.lua could not be used (", false, true },
        { "settings.lua does not compile", { ["Scripts/core/settings.lua"] = "return {\n" }, "core/settings.lua could not be used (", false, true },
    }) do
        root = H.mod("service-broken", { modules = { repopulate = probe }, files = v[2] })
        c = H.start(root)
        check(c.ok and H.printedCount(c.ue, v[3]) == 1 and c.ue.printed[#c.ue.printed]:match(LOAD_LINE) ~= nil, v[1] .. ": one log line, the modules are loaded all the same")
        check((c.M.repopulate.kit ~= nil) == v[5] and (c.M.repopulate.settings ~= nil) == v[4] and (c.T.kit ~= nil) == v[5], v[1] .. ": the modules get the one that could be loaded")
        for _ = 1, 4 do
            c.ue:advance(0.25)
            c.ue:tick()
        end
        check(#c.ue.errors == 0 and #c.ue.loops == 2, v[1] .. ": the loop runs with what is there")
        check(H.has(H.read(c.session), "[" .. (v[5] and "settings" or "kit") .. "] ERROR in load: "), v[1] .. ": recorded as an error of that service")
        H.stop(c)
    end
    root = H.mod("service-none", { files = { ["Scripts/core/kit.lua"] = false, ["Scripts/core/settings.lua"] = false } })
    c = H.start(root)
    check(c.ok and #c.ue.loops == 1 and c.ue.loops[1].ms == 1000 and c.ue.printed[#c.ue.printed]:match(LOAD_LINE) ~= nil, "neither can be loaded: no loop for them, the modules are loaded")
    H.stop(c)
    root = H.mod("service-nosandbox", { modules = { repopulate = probe }, files = { ["Scripts/core/sandbox.lua"] = false } })
    c = H.start(root)
    check(c.ok and c.M.repopulate.kit == c.T.kit and c.T.kit ~= nil and c.M.repopulate.settings == c.T.settings and rawget(_G, "G1R_KIT") == nil,
        "without core/sandbox.lua the modules still get both, and still not as globals")
    H.stop(c)
    root = H.mod("service-noloop", {})
    c = H.start(root, { mock = { without = { "LoopInGameThreadWithDelay" } } })
    check(c.ok and c.T.kit ~= nil and c.ue.printed[#c.ue.printed]:find("loaded: " .. ALL_OK, 1, true) ~= nil, "a UE4SS without the game-thread loop: both are loaded, the modules too")
    H.stop(c)

    section("modules: the list in core/modules.lua")
    local function list(body) return "return {\n" .. body .. "\n}\n" end
    local function mods(case, modulesFile, files)
        local r = H.mod(case, { files = { ["Scripts/core/modules.lua"] = modulesFile } })
        for path, text in pairs(files or {}) do
            local dir = (TMP .. "/" .. case .. "/" .. path):match("^(.*)/[^/]*$")
            H.sh("mkdir -p " .. H.q(dir))
            H.write(TMP .. "/" .. case .. "/" .. path, text)
        end
        return r
    end
    local function last(ctx) return ctx.ue.printed[#ctx.ue.printed] end
    root = mods("list-order", list('{ name = "markers", switch = "Markers" },\n{ name = "repopulate" },'))
    c = H.start(root)
    check(c.ok and H.has(last(c), "loaded: markers ok, repopulate ok | diagnostics normal") and c.M.xp == nil, "the modules of the list are loaded in its order; one that is not in the list is not loaded")
    H.stop(c)
    root = mods("list-switch", list('{ name = "markers", switch = "Markers" },\n{ name = "repopulate" },'))
    H.write(root .. "/Scripts/config.lua", H.config("Config.Modules = { Markers = false, Repopulate = false }"))
    c = H.start(root)
    check(H.has(last(c), "loaded: markers off, repopulate ok"), "a module without a switch cannot be switched off in config.lua")
    H.stop(c)
    for _, v in ipairs({ { "missing", false }, { "does not compile", "return {\n" }, { "returns no table", "return 5\n" }, { "raises", "error('boom')\n" } }) do
        root = H.mod("list-broken", { files = { ["Scripts/core/modules.lua"] = v[2] } })
        c = H.start(root)
        check(c.ok and H.printedCount(c.ue, "core/modules.lua could not be read (") == 1 and H.has(last(c), "loaded: no modules | diagnostics normal") and c.M.repopulate == nil,
            "core/modules.lua " .. v[1] .. ": said, no module is loaded, the loader itself runs")
        check(c.ue:fireConsole("g1r") == true, "core/modules.lua " .. v[1] .. ": g1r answers")
        H.stop(c)
    end
    root = mods("list-empty", "return {}\n")
    c = H.start(root)
    check(c.ok and H.has(last(c), "loaded: no modules | diagnostics normal"), "an empty list: no modules")
    H.stop(c)

    section("modules: other mods that do the same job")
    local two = list('{ name = "repopulate", switch = "Repopulate", separate = { "FirstMod", "SecondMod" } },\n{ name = "markers", switch = "Markers", separate = "PlainName" },\n{ name = "xp" },')
    root = mods("sep-second", two, { ["SecondMod/Scripts/main.lua"] = "-- another mod\n", ["SecondMod/enabled.txt"] = "", ["FirstMod/readme.txt"] = "no script here\n" })
    c = H.start(root)
    check(H.has(last(c), "loaded: repopulate left to the separate mod SecondMod, markers ok, xp ok"), "several names: the one that is installed and enabled is named")
    H.stop(c)
    root = mods("sep-both", two, { ["SecondMod/Scripts/main.lua"] = "-- another mod\n", ["SecondMod/enabled.txt"] = "", ["FirstMod/scripts/main.lua"] = "-- another mod\n", ["mods.txt"] = "FirstMod : 1\n" })
    c = H.start(root)
    check(H.has(last(c), "loaded: repopulate left to the separate mod FirstMod, markers ok, xp ok") and H.printedCount(c.ue, "module repopulate not loaded") == 1, "both enabled: the first of the list is named, in one line")
    H.stop(c)
    root = mods("sep-plain", two, { ["PlainName/Scripts/main.lua"] = "-- another mod\n", ["PlainName/enabled.txt"] = "" })
    c = H.start(root)
    check(H.has(last(c), "loaded: repopulate ok, markers left to the separate mod PlainName, xp ok"), "a single name written as a text works too")
    H.stop(c)
    root = mods("sep-native", two, { ["FirstMod/dlls/main.dll"] = "MZ", ["FirstMod/enabled.txt"] = "" })
    c = H.start(root)
    check(H.has(last(c), "loaded: repopulate left to the separate mod FirstMod"), "a native mod (dlls/main.dll instead of Scripts/main.lua) with enabled.txt counts")
    H.stop(c)
    root = mods("sep-native-txt", two, { ["FirstMod/dlls/main.dll"] = "MZ", ["mods.txt"] = "FirstMod : 1\r\n" })
    c = H.start(root)
    check(H.has(last(c), "loaded: repopulate left to the separate mod FirstMod"), "so does one enabled in mods.txt")
    H.stop(c)
    root = mods("sep-native-off", two, { ["FirstMod/dlls/main.dll"] = "MZ", ["FirstMod/dlls/other.dll"] = "MZ", ["mods.txt"] = "FirstMod : 0\r\n" })
    c = H.start(root)
    check(H.has(last(c), "loaded: repopulate ok, markers ok, xp ok"), "a native mod that is switched off does not")
    H.stop(c)
    root = mods("sep-case", two, { ["FirstMod/Scripts/main.lua"] = "-- another mod\n", ["mods.txt"] = "firstmod : 1\r\nPLAINNAME : 1\r\n" })
    c = H.start(root)
    check(H.has(last(c), "loaded: repopulate left to the separate mod FirstMod, markers ok"), "the name in mods.txt is compared without regard to case (a line for a mod whose folder is not there changes nothing)")
    H.stop(c)
    root = mods("sep-similar", two, { ["FirstMod/Scripts/main.lua"] = "-- another mod\n", ["mods.txt"] = "FirstModPlus : 1\r\nMyFirstMod : 1\r\nFirstMo : 1\r\n" })
    c = H.start(root)
    check(H.has(last(c), "loaded: repopulate ok, markers ok, xp ok"), "names that only contain the name, or are a part of it, are other mods")
    H.stop(c)

    section("modules: what they may know of the other mods (G1R_MODS)")
    local look = H.probe("repopulate", [[
TEST.repopulate.mods = G1R_MODS
TEST.repopulate.raw = rawget(_G, "G1R_MODS")
TEST.repopulate.runs = { G1R_MODS.runs("OtherMod"), G1R_MODS.runs("OffMod"), G1R_MODS.runs("NoMod"), G1R_MODS.runs(5), G1R_MODS.runs("NativeMod"), G1R_MODS.runs("ListedMod") }
local f = io.open(G1R_MODS.folder .. "/OtherMod/config.txt", "rb")
TEST.repopulate.read = f and f:read("a") or nil
if f then f:close() end
]])
    root = H.mod("mods-service", { modules = { repopulate = look } })
    for path, text in pairs({ ["OtherMod/Scripts/main.lua"] = "-- another mod\n", ["OtherMod/enabled.txt"] = "", ["OtherMod/config.txt"] = "key = N\n",
        ["OffMod/Scripts/main.lua"] = "-- another mod\n", ["NativeMod/dlls/main.dll"] = "MZ", ["NativeMod/enabled.txt"] = "",
        ["ListedMod/Scripts/main.lua"] = "-- another mod\n", ["mods.txt"] = "ListedMod : 1\r\nOffMod : 0\r\n" }) do
        local dir = (TMP .. "/mods-service/" .. path):match("^(.*)/[^/]*$")
        H.sh("mkdir -p " .. H.q(dir))
        H.write(TMP .. "/mods-service/" .. path, text)
    end
    c = H.start(root)
    local R = c.M.repopulate
    check(c.ok and type(R.mods) == "table" and R.raw == R.mods and rawget(_G, "G1R_MODS") == nil, "every module finds G1R_MODS in its environment; it is no global of the Lua state")
    check(R.runs[1] == true and R.runs[2] == false and R.runs[3] == false and R.runs[4] == false and R.runs[5] == true and R.runs[6] == true,
        "runs(folder): a mod with enabled.txt runs, one switched off in mods.txt or not there does not, a name that is no text is no mod; a native mod and one enabled in mods.txt run")
    check(R.read == "key = N\n", "folder: the Mods folder (a mod's files are read from there)")
    H.stop(c)
end

-- ---------------------------------------------------------------------------
-- Sandbox
-- ---------------------------------------------------------------------------
function tests.sandbox()
    section("sandbox: environment of a module")
    local root = H.mod("sandbox", { modules = {
        repopulate = [[
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*/)[^/]+$")
GLOBAL_A = "from repopulate"
function helperA() return "helper" end
_G.VIA_G = 7
SHARED = 5
local r = { env = _G, diag = G1R_DIAG }
TEST.r = r
r.part = { dofile(dir .. "part.lua") }
r.fromPart = FROM_PART
r.chunkShared = loadfile(dir .. "reads.lua")()
r.chunkOwn = loadfile(dir .. "reads.lua", "t", { SHARED = "explicit" })()
r.chunkEmpty = loadfile(dir .. "reads.lua", "t", {})()
r.missing = { loadfile(dir .. "nothing.lua") }
r.dofileMissing = { pcall(dofile, dir .. "nothing.lua") }
r.dofileBroken = { pcall(dofile, dir .. "broken.lua") }
r.loaded = load("return SHARED", "=text", "t", {})()
r.loadedGlobal = load("return SHARED")()
r.load = load
r.standard = {}
for _, k in ipairs({ "pairs", "ipairs", "next", "select", "type", "tostring", "tonumber", "pcall", "xpcall", "error", "assert", "rawget",
    "rawset", "rawequal", "rawlen", "setmetatable", "getmetatable", "math", "string", "table", "os", "io", "coroutine", "utf8", "debug", "load" }) do
    r.standard[k] = rawget(_G, k)
end
r.viaFallback = { require = require, collectgarbage = collectgarbage, version = _VERSION }
r.gIsEnv = (_G._G == _G) and rawget(_G, "GLOBAL_A") == "from repopulate"
r.realLoader = rawget(_G, "G1R_LOADER_TEST")
LoopInGameThreadWithDelay(250, function() r.late = LATE_GLOBAL end)
]],
        markers = [[
TEST.m = { env = _G, diag = G1R_DIAG, seesA = GLOBAL_A, seesHelper = helperA, seesShared = SHARED, seesViaG = VIA_G }
GLOBAL_B = "from markers"
]],
    } })
    H.write(root .. "/modules/repopulate/Scripts/part.lua", "FROM_PART = SHARED + 1\nreturn 'a', nil, 'c'\n")
    H.write(root .. "/modules/repopulate/Scripts/reads.lua", "return SHARED\n")
    H.write(root .. "/modules/repopulate/Scripts/broken.lua", "error('inside the file')\n")
    local realLoad, realRequire = load, require
    local c = H.start(root)
    local r, m = c.M.r, c.M.m
    check(c.ok and r ~= nil and m ~= nil and H.has(c.ue.printed[#c.ue.printed], "repopulate ok, markers ok"), "both modules loaded")
    check(rawget(_G, "GLOBAL_A") == nil and rawget(_G, "helperA") == nil and rawget(_G, "SHARED") == nil and rawget(_G, "FROM_PART") == nil
        and rawget(_G, "GLOBAL_B") == nil, "a module's globals do not reach _G")
    check(rawget(_G, "VIA_G") == nil and rawget(r.env, "VIA_G") == 7, "writing through _G stays inside the module as well")
    check(m.seesA == nil and m.seesHelper == nil and m.seesShared == nil and m.seesViaG == nil, "another module does not see them")
    check(rawget(r.env, "GLOBAL_A") == "from repopulate" and rawget(m.env, "GLOBAL_B") == "from markers" and r.env ~= m.env, "each module has its own environment")
    check(r.fromPart == 6 and rawget(r.env, "FROM_PART") == 6, "a file loaded with dofile shares the module's environment")
    check(#r.part == 3 and r.part[1] == "a" and r.part[2] == nil and r.part[3] == "c", "dofile passes on what the file returns")
    check(r.chunkShared == 5, "loadfile without an environment: the module's environment")
    check(r.chunkOwn == "explicit" and r.chunkEmpty == nil, "loadfile with an explicit environment: that one")
    check(r.missing[1] == nil and type(r.missing[2]) == "string" and H.has(r.missing[2], "nothing.lua"), "loadfile: nil and a message for a missing file")
    check(r.dofileMissing[1] == false and H.has(tostring(r.dofileMissing[2]), "cannot open"), "dofile raises for a missing file")
    check(r.dofileBroken[1] == false and H.has(tostring(r.dofileBroken[2]), "inside the file"), "dofile passes an error of the file on")
    check(r.load == realLoad and r.loaded == nil and r.loadedGlobal == nil, "load is the original (text loaded with it does not get the module's environment)")
    local allThere = true
    for _, k in ipairs({ "pairs", "ipairs", "next", "select", "type", "tostring", "tonumber", "pcall", "xpcall", "error", "assert", "rawget",
        "rawset", "rawequal", "rawlen", "setmetatable", "getmetatable", "math", "string", "table", "os", "io", "coroutine", "utf8", "debug", "load" }) do
        if r.standard[k] == nil or r.standard[k] ~= _G[k] then allThere = false end
    end
    check(allThere, "standard globals are in the environment itself")
    check(r.viaFallback.require == realRequire and r.viaFallback.collectgarbage == collectgarbage and r.viaFallback.version == _VERSION, "everything else is reached through _G")
    check(r.gIsEnv == true and r.realLoader == nil, "_G inside a module is its environment")
    check(type(r.diag) == "table" and type(r.diag.note) == "function" and type(r.diag.event) == "function" and type(r.diag.crumb) == "function"
        and type(r.diag.status) == "function" and type(r.diag.dump) == "function" and type(r.diag.version) == "function", "G1R_DIAG is there inside a module, with its six functions")
    check(rawget(_G, "G1R_DIAG") == nil and r.diag ~= m.diag and type(m.diag) == "table", "G1R_DIAG is absent from _G; each module has its own")
    _G.LATE_GLOBAL = 42
    c.ue:tick()
    check(r.late == 42, "a global defined in _G after loading is visible to the module")
    _G.LATE_GLOBAL = nil
    c.ue:tick()
    check(r.late == nil, "and follows _G")
    H.stop(c)

    section("sandbox: only functions that exist are wrapped")
    root = H.mod("without")
    c = H.start(root, { mock = { without = { "LoopAsync", "RegisterKeyBind", "FindFirstOf", "ExecuteAsync" } } })
    local env = c.M.repopulate.env
    check(rawget(env, "LoopAsync") == nil and env.LoopAsync == nil and rawget(env, "RegisterKeyBind") == nil and rawget(env, "FindFirstOf") == nil
        and rawget(env, "ExecuteAsync") == nil, "missing functions stay missing")
    check(type(rawget(env, "RegisterHook")) == "function" and type(rawget(env, "FindAllOf")) == "function" and rawget(env, "RegisterHook") ~= c.ue.globals.RegisterHook,
        "the others are wrapped")
    check(env.FName == c.ue.globals.FName and env.StaticConstructObject == c.ue.globals.StaticConstructObject and rawget(env, "FName") == nil,
        "functions without a callback or a search pass through")
    H.stop(c)
end

-- ---------------------------------------------------------------------------
-- Wrappers
-- ---------------------------------------------------------------------------
function tests.wrappers()
    section("wrappers: callbacks of every wrapped function")
    local root = H.mod("wrappers")
    local c = H.start(root, { mock = { anyHook = true } })
    local ue, env = c.ue, c.M.repopulate.env
    local seen = {}
    local function callback(tag)
        return function(...)
            seen[tag] = table.pack(...)
            return "r1", nil, tag, nil
        end
    end
    -- name, arguments before the callback, where the mock keeps the callback, the place named in the diagnostics
    local cases = {
        { "LoopInGameThreadWithDelay", { 250 }, function() return ue.loops[#ue.loops].callback end, "LoopInGameThreadWithDelay 250" },
        { "LoopAsync", { 500 }, function() return ue.asyncLoops[#ue.asyncLoops].callback end, "LoopAsync 500" },
        { "ExecuteWithDelay", { 100 }, function() return ue.delayed[#ue.delayed].callback end, "ExecuteWithDelay 100" },
        { "ExecuteInGameThread", {}, function() return ue.delayed[#ue.delayed].callback end, "ExecuteInGameThread" },
        { "ExecuteAsync", {}, function() return ue.delayed[#ue.delayed].callback end, "ExecuteAsync" },
        { "NotifyOnNewObject", { "/Script/G1R.Thing" }, function() local l = ue.notifications["/Script/G1R.Thing"] return l[#l] end, "NotifyOnNewObject /Script/G1R.Thing" },
        { "RegisterHook", { "/Script/G1R.Thing:Do" }, function() local l = ue.hooks["/Script/G1R.Thing:Do"] return l[#l].pre end, "RegisterHook /Script/G1R.Thing:Do" },
        { "RegisterLoadMapPreHook", {}, function() return ue.loadMapPre[#ue.loadMapPre] end, "RegisterLoadMapPreHook" },
        { "RegisterLoadMapPostHook", {}, function() return ue.loadMapPost[#ue.loadMapPost] end, "RegisterLoadMapPostHook" },
        { "RegisterConsoleCommandHandler", { "cmd" }, function() local l = ue.console.cmd return l[#l] end, "RegisterConsoleCommandHandler cmd" },
        { "RegisterConsoleCommandGlobalHandler", { "gcmd" }, function() local l = ue.globalConsole.gcmd return l[#l] end, "RegisterConsoleCommandGlobalHandler gcmd" },
        { "RegisterKeyBind", { 65 }, function() return ue.keys[#ue.keys].callback end, "RegisterKeyBind 65" },
    }
    for _, case in ipairs(cases) do
        local name, before, stored, where = case[1], case[2], case[3], case[4]
        check(type(rawget(env, name)) == "function" and rawget(env, name) ~= ue.globals[name], name .. ": wrapped inside the module")
        local cb = callback(name)
        local args = { table.unpack(before) }
        args[#args + 1] = cb
        local results = table.pack(env[name](table.unpack(args)))
        local guard = stored()
        check(type(guard) == "function" and guard ~= cb, name .. ": UE4SS got a guard, not the callback itself")
        local object = {}
        local out = table.pack(guard(object, nil, 3, nil))
        local got = seen[name]
        check(got ~= nil and got.n == 4 and got[1] == object and got[2] == nil and got[3] == 3 and got[4] == nil, name .. ": the callback gets its arguments")
        check(out.n == 4 and out[1] == "r1" and out[2] == nil and out[3] == name and out[4] == nil, name .. ": every return value is passed on")
        if name == "LoopInGameThreadWithDelay" then
            check(results.n == 1 and math.type(results[1]) == "integer", name .. ": the registration's return value (handle) is passed on")
        elseif name == "RegisterHook" then
            check(results.n == 2 and math.type(results[1]) == "integer" and results[2] == results[1] + 1, name .. ": the registration's return values (two ids) are passed on")
        else
            check(results.n == 0, name .. ": the registration returns nothing, as the original")
        end
        -- an error in the callback
        local failing = function() error("boom in " .. name) end
        args[#args] = failing
        env[name](table.unpack(args))
        guard = stored()
        local printedBefore = #ue.printed
        local ok, r1 = pcall(guard, 1, 2)
        local n = select("#", guard(1, 2))
        check(ok and r1 == nil and n == 0, name .. ": an error in the callback is caught, nothing is returned")
        local log = H.read(c.session)
        check(H.count(log, "ERROR in " .. where .. ": ") == 1 and H.count(log, "boom in " .. name) == 1, name .. ": recorded once, with its place (" .. where .. ")")
        check(H.printedCount(ue, "error in repopulate (" .. where .. "): ") == 1 and #ue.printed == printedBefore + 1, name .. ": one line in UE4SS.log for the first occurrence only")
    end
    local log = H.read(c.session)
    check(H.count(log, "stack traceback:") == #cases, "each error has its traceback in the session log")
    check(H.has(log, "in upvalue 'callback'") or H.has(log, "in function <"), "the traceback names the place of the error")
    c.ue:fireConsole("g1r diag")
    local report = H.read(c.dir .. "/report-latest.txt")
    local errors = H.part(report, "errors")
    check(H.find(errors, "count: " .. (2 * #cases) .. " (" .. #cases .. " distinct)") ~= nil, "report: every error counted, one entry per distinct error")
    check(H.find(errors, "[repopulate] 2 x in RegisterHook /Script/G1R.Thing:Do, first 12:00:00, last 12:00:00") ~= nil, "report: repeats counted on the first entry")
    local counters = H.part(report, "counters")
    for _, case in ipairs(cases) do
        local l = H.find(counters, "[repopulate] callbacks " .. case[1] .. ": ")
        check(l ~= nil and H.has(l, ": 3 calls, 2 errors, 0 slow, max 0.0 ms"), case[1] .. ": calls and errors counted (" .. tostring(l) .. ")")
        l = H.find(counters, "[repopulate] registered " .. case[1] .. ": ")
        check(l ~= nil and H.has(l, ": 2 ok, 0 failed"), case[1] .. ": registrations counted")
    end
    H.stop(c)

    section("wrappers: through the mock, the way UE4SS calls them")
    root = H.mod("fired")
    c = H.start(root, { mock = { anyHook = true } })
    ue, env = c.ue, c.M.repopulate.env
    local got = {}
    env.LoopAsync(100, function() got.async = (got.async or 0) + 1 return got.async >= 2 end)
    ue:tickAsync() ue:tickAsync() ue:tickAsync()
    check(got.async == 2 and #ue.asyncLoops == 0, "LoopAsync: 'true' from the callback still ends the loop")
    env.NotifyOnNewObject("/Script/G1R.Thing", function(o) got.notify = o return true end)
    ue:fireNotify("/Script/G1R.Thing", "the object") ue:fireNotify("/Script/G1R.Thing", "again")
    check(got.notify == "the object", "NotifyOnNewObject: 'true' from the callback still ends the notification")
    env.RegisterConsoleCommandHandler("say", function(full, parameters, device) got.console = { full, parameters, device } return true end)
    check(ue:fireConsole("say a b") == true and got.console[1] == "say a b" and got.console[2][1] == "a" and got.console[2][2] == "b" and got.console[3] == ue.device,
        "console handler: command, parameters and device arrive, 'true' goes back")
    env.RegisterConsoleCommandHandler("fail", function() error("console boom") end)
    local before = #ue.errors
    check(ue:fireConsole("fail") == false and #ue.errors == before + 1 and H.has(ue.errors[#ue.errors], "must return true or false"),
        "console handler that raises: UE4SS sees no return value (its own message), the error itself is in the diagnostics")
    env.RegisterLoadMapPreHook(function() error("pre boom") end)
    env.RegisterLoadMapPreHook(function(engine, world) got.pre = { engine, world } end)
    before = #ue.errors
    check(ue:fireLoadMapPre("engine", "world") == nil and got.pre ~= nil and got.pre[2] == "world" and #ue.errors == before,
        "load-map hooks: with the guard an error in one callback no longer skips the next")
    env.RegisterHook("/Script/G1R.Thing:Do", function(context, a) got.hookPre = { context, a } return "override" end, function(context, a) got.hookPost = { context, a } end)
    local fired = ue:fireHook("/Script/G1R.Thing:Do", "ctx", "param")
    check(fired[1].pre == "override" and fired[1].post == nil and got.hookPre[2] == "param" and got.hookPost[1] == "ctx", "RegisterHook: pre and post callback both guarded, return value of the pre callback goes back")
    env.RegisterHook("/Script/G1R.Thing:Post", function() end, function() error("post boom") end)
    ue:fireHook("/Script/G1R.Thing:Post")
    check(H.has(H.read(c.session), "ERROR in RegisterHook /Script/G1R.Thing:Post (post): "), "RegisterHook: an error in the post callback is recorded as such")
    env.RegisterKeyBind(66, { 1, 2 }, function() got.key = true end)
    check(ue:fireKey(66) == 1 and got.key == true and type(ue.keys[#ue.keys].modifiers) == "table", "RegisterKeyBind with modifier keys: the last argument is the callback")
    env.ExecuteInGameThread(function() got.game = true end, 1)
    check(ue.delayed[#ue.delayed].method == 1 and ue:runDelayed() == 1 and got.game == true, "ExecuteInGameThread: arguments after the callback are passed on")
    env.LoopInGameThreadWithDelay(100, function()
        if not got.nested then
            got.nested = true
            env.ExecuteWithDelay(10, function() error("nested boom") end)
        end
    end)
    ue:tick() ue:runDelayed()
    check(H.has(H.read(c.session), "ERROR in ExecuteWithDelay 10: ") and #ue.errors == before + 0, "a callback registered from inside a callback is guarded too")
    H.stop(c)

    section("wrappers: a registration that raises")
    root = H.mod("regfail")
    local atCall = {}
    c = H.start(root, { prepare = function(ue2)
        local original = ue2.globals.RegisterHook
        _G.RegisterHook = function(...)
            atCall[#atCall + 1] = H.read(ue2.sessionProbe) or ""
            return original(...)
        end
        ue2.sessionProbe = TMP .. "/regfail/TempMod/Scripts/diagnostics/" .. os.date("session-%Y%m%d-%H%M%S.log", ue2.time)
    end })
    ue, env = c.ue, c.M.repopulate.env
    local ok, err = pcall(env.RegisterHook, "/Script/Missing.Class:Function", function() end)
    local _, plain = pcall(ue.globals.RegisterHook, "/Script/Missing.Class:Function", function() end)
    check(ok == false and err == plain and H.has(err, "no UFunction with the specified name was found"), "RegisterHook on a missing function still raises, with the original message")
    check(#atCall == 1 and H.has(atCall[1], "[repopulate] > RegisterHook /Script/Missing.Class:Function"), "the breadcrumb was on disk before RegisterHook ran")
    local log = H.read(c.session)
    check(H.has(log, "[repopulate] RegisterHook /Script/Missing.Class:Function: FAILED: Tried to register a hook"), "the failure is in the session log at once")
    ue.functions["/Script/G1R.Real:Function"] = true
    local id1, id2 = env.RegisterHook("/Script/G1R.Real:Function", function() end)
    check(id1 ~= nil and id2 ~= nil and H.has(H.read(c.session), "[repopulate] RegisterHook /Script/G1R.Real:Function: registered"), "a successful RegisterHook closes its breadcrumb at once")
    ok, err = pcall(env.LoopInGameThreadWithDelay, 2.5, function() end)
    check(ok == false and H.has(tostring(err), "No overload found for function 'LoopInGameThreadWithDelay'"), "other registrations raise as the original does")
    ok = pcall(env.NotifyOnNewObject, "no dot here", function() end)
    check(ok == false and H.has(H.read(c.session), "NotifyOnNewObject no dot here: FAILED: "), "and that is recorded as well")
    c.ue:fireConsole("g1r diag")
    local counters = H.part(H.read(c.dir .. "/report-latest.txt"), "counters")
    local l = H.find(counters, "[repopulate] registered RegisterHook: ")
    check(l ~= nil and H.has(l, "1 ok, 1 failed (first: RegisterHook /Script/Missing.Class:Function: FAILED: Tried to register a hook"), "report: registrations ok / failed with the first failure")
    check(H.find(H.part(H.read(c.dir .. "/report-latest.txt"), "errors"), "count: 0 (0 distinct)") ~= nil, "a failed registration is not counted as an error of a callback")
    H.stop(c)

    section("wrappers: StaticFindObject")
    root = H.mod("lookup")
    atCall = {}
    c = H.start(root, { prepare = function(ue2)
        local original = ue2.globals.StaticFindObject
        local probe = TMP .. "/lookup/TempMod/Scripts/diagnostics/" .. os.date("session-%Y%m%d-%H%M%S.log", ue2.time)
        _G.StaticFindObject = function(...)
            atCall[#atCall + 1] = H.read(probe) or ""
            return original(...)
        end
    end })
    ue, env = c.ue, c.M.repopulate.env
    check(#atCall == START_SEARCHES and (ue.calls.StaticFindObject or 0) == START_SEARCHES and H.count(H.read(c.session), "> lookup ") == START_SEARCHES,
        "starting the loader, the kit and the modules searches nothing by path")
    local thing = ue:object("Class /Script/G1R.Thing")
    ue.objects["/Script/G1R.Thing"] = thing
    ue.cost.StaticFindObject = 0.004
    local result = table.pack(env.StaticFindObject("/Script/G1R.Thing"))
    check(result.n == 1 and result[1] == thing, "the object is passed on unchanged")
    check(#atCall == 1 and H.has(atCall[1], "[repopulate] > lookup /Script/G1R.Thing") and not H.has(atCall[1], "lookup /Script/G1R.Thing: found"),
        "first search for a path: the breadcrumb is on disk before the search runs")
    log = H.read(c.session)
    check(H.has(log, "[repopulate] lookup /Script/G1R.Thing: found, 4.0 ms"), "the result follows the breadcrumb on disk, with the time")
    env.StaticFindObject("/Script/G1R.Thing") env.StaticFindObject("/Script/G1R.Thing")
    log = H.read(c.session)
    check(H.count(log, "> lookup /Script/G1R.Thing") == 1 and #atCall == 3, "no breadcrumb for a path that was found earlier")
    local other = c.M.markers.env.StaticFindObject("/Script/G1R.Thing")
    check(other == thing and H.count(H.read(c.session), "> lookup /Script/G1R.Thing") == 1, "also not when another module asks for it")
    local missing = env.StaticFindObject("/Script/G1R.Missing")
    check(missing ~= nil and missing:IsValid() == false, "'not found' comes back as UE4SS gives it (an invalid object)")
    log = H.read(c.session)
    check(H.has(log, "[repopulate] > lookup /Script/G1R.Missing") and H.has(log, "[repopulate] lookup /Script/G1R.Missing: NOT FOUND, 4.0 ms"), "not found: breadcrumb and result")
    env.StaticFindObject("/Script/G1R.Missing")
    log = H.read(c.session)
    check(H.count(log, "> lookup /Script/G1R.Missing") == 2 and H.has(log, "lookup /Script/G1R.Missing: NOT FOUND again (search number 2 for this path"),
        "a repeated search for a path that was not found gets its breadcrumb again and is called out")
    ue.objects["/Script/G1R.Missing"] = ue:object("Class /Script/G1R.Missing")
    env.StaticFindObject("/Script/G1R.Missing")
    check(H.has(H.read(c.session), "lookup /Script/G1R.Missing: found (after 2 search(es) without a result)"), "found later: said so")
    ue.objects["/Script/G1R.Nil"] = nil
    c.ue.options.nilWhenMissing = true
    check(env.StaticFindObject("/Script/G1R.Nil") == nil and H.has(H.read(c.session), "lookup /Script/G1R.Nil: NOT FOUND"), "nil counts as not found too")
    c.ue.options.nilWhenMissing = nil
    local byClass = env.StaticFindObject(nil, nil, "/Script/G1R.Thing")
    check(byClass == thing and H.count(H.read(c.session), "> lookup /Script/G1R.Thing") == 1, "the form with class and outer is passed on and counted, without a breadcrumb")
    local okNone, errNone = pcall(env.StaticFindObject)
    check(okNone == false and errNone == "Function 'StaticFindObject' cannot be called with 0 parameters.", "an error of StaticFindObject itself reaches the caller unchanged")
    c.diag.flush()
    check(H.has(H.read(c.session), "[repopulate] lookup (not a plain path): RAISED: Function 'StaticFindObject' cannot be called with 0 parameters."), "and is recorded")
    ue.cost.FindAllOf, ue.cost.FindFirstOf = 0.002, 0.001
    local list = { ue:object("A"), ue:object("B") }
    ue.allOf.Things = list
    ue.firstOf.Thing = list[1]
    check(env.FindAllOf("Things") == list and env.FindAllOf("Nothing") == nil and env.FindFirstOf("Thing") == list[1] and env.FindFirstOf("Nothing"):IsValid() == false,
        "FindAllOf / FindFirstOf: results passed on unchanged")
    c.ue:fireConsole("g1r diag")
    counters = H.part(H.read(c.dir .. "/report-latest.txt"), "counters")
    l = H.find(counters, "[repopulate] lookups: ")
    check(l ~= nil and H.has(l, "lookups: 9 calls, 3 first-time, 3 not found, 2 repeated after not found, 36.0 ms total, slowest 4.0 ms /Script/G1R.") and H.has(l, ", 1 call(s) raised"),
        "report: lookups counted (calls / first-time / not found / repeated / time / slowest path): " .. tostring(l))
    l = H.find(counters, "[markers] lookups: ")
    check(l ~= nil and H.has(l, "lookups: 1 calls, 0 first-time, 0 not found, 0 repeated after not found, 4.0 ms total"), "report: counted per module")
    l = H.find(counters, "[repopulate] FindAllOf: ")
    check(l ~= nil and H.has(l, "FindAllOf: 2 calls, 4.0 ms total, max 2.0 ms"), "report: FindAllOf calls and time")
    l = H.find(counters, "[repopulate] FindFirstOf: ")
    check(l ~= nil and H.has(l, "FindFirstOf: 2 calls, 2.0 ms total, max 1.0 ms"), "report: FindFirstOf calls and time")
    check(ue.calls.StaticFindObject == 10 and ue.calls.FindAllOf == 2 and ue.calls.FindFirstOf == 2, "the wrappers made no search of their own (10 searches by path asked for, 10 made)")
    H.stop(c)

    section("wrappers: slow callbacks, print")
    root = H.mod("slow")
    c = H.start(root)
    ue, env = c.ue, c.M.repopulate.env
    local cost = 0.05
    env.LoopInGameThreadWithDelay(250, function() ue.clock = ue.clock + cost end)
    local loop = ue.loops[#ue.loops].callback
    loop() loop() loop() loop()
    cost = 0.029         -- just below the limit of 30 ms: not slow
    loop()
    cost = 0.001
    loop()
    c.ue:fireConsole("g1r diag")
    report = H.read(c.dir .. "/report-latest.txt")
    l = H.find(H.part(report, "counters"), "[repopulate] callbacks LoopInGameThreadWithDelay: ")
    check(l ~= nil and H.has(l, ": 6 calls, 0 errors, 4 slow, max 50.0 ms, 230.0 ms total"), "slow calls are counted, the longest and the total time are kept (" .. tostring(l) .. ")")
    log = H.read(c.session)
    check(H.count(log, "[repopulate] slow callback: LoopInGameThreadWithDelay 250 took 50.0 ms") == 3, "the first three are noted with their place")
    check(H.count(log, "further slow calls of this kind are only counted") == 1, "then they are only counted")
    env.print("one", 2, nil)
    env.print()
    env.print("[Mod] a line\n")
    env.print("first\nsecond\n\n")
    check(ue.printed[#ue.printed - 3] == "one\t\t2\t\tnil" and ue.printed[#ue.printed] == "first\nsecond\n\n", "print reaches the real print unchanged")
    c.diag.flush()
    log = H.read(c.session)
    check(H.has(log, "[repopulate] one    2    nil") and H.has(log, "[repopulate] [Mod] a line\n") and H.has(log, "[repopulate] first\n") and H.has(log, "[repopulate]     second\n"),
        "and is recorded: one line per line, without the trailing line break")
    H.stop(c)
end

-- ---------------------------------------------------------------------------
-- Diagnostics files
-- ---------------------------------------------------------------------------
function tests.files()
    section("files: session log lines, timed flush, immediate writes")
    local root = H.mod("flush")
    local c = H.start(root)
    local env, D = c.M.repopulate.env, c.M.repopulate.diag
    local base = H.read(c.session)
    env.print("[Fake] buffered line\n")
    D.event("an event")
    check(H.read(c.session) == base, "a normal line is not written at once")
    H.seconds(c, 19)
    check(H.read(c.session) == base, "nor 19 seconds later")
    H.seconds(c, 1)
    local log = H.read(c.session)
    check(H.has(log, "12:00:00 [repopulate] [Fake] buffered line\n") and H.has(log, "12:00:00 [repopulate] an event\n"), "after FlushSeconds (20) it is on disk, with the time it was recorded")
    check(H.printed(c.ue, "an event") == nil, "an event is not printed to UE4SS.log")
    env.print("[Fake] second buffered line\n")
    H.seconds(c, 19)
    check(not H.has(H.read(c.session), "second buffered line"), "the next flush is again 20 seconds later")
    H.seconds(c, 1)
    check(H.has(H.read(c.session), "12:00:20 [repopulate] [Fake] second buffered line\n"), "and happens then")
    env.print("[Fake] pending before the crumb\n")
    D.crumb("about to do something risky")
    log = H.read(c.session)
    check(H.has(log, "[repopulate] > about to do something risky\n"), "a breadcrumb is on disk when the call returns")
    local a = log:find("pending before the crumb", 1, true)
    local b = log:find("> about to do something risky", 1, true)
    check(a ~= nil and b ~= nil and a < b, "lines recorded before it are written with it, in order")
    env.print("[Fake] right after the crumb\n")
    check(H.has(H.read(c.session), "right after the crumb"), "the line after a breadcrumb is written at once (it shows the step was survived)")
    env.print("[Fake] later\n")
    check(not H.has(H.read(c.session), "[Fake] later"), "later lines wait for the timer again")
    env.LoopInGameThreadWithDelay(100, function() error("immediate error") end)
    c.ue.loops[#c.ue.loops].callback()
    log = H.read(c.session)
    check(H.has(log, "ERROR in LoopInGameThreadWithDelay 100: ") and H.has(log, "immediate error") and H.has(log, "[Fake] later"), "an error is written at once (with what was pending)")
    local good, total = true, 0
    for _, l in ipairs(H.lines(H.read(c.session))) do
        total = total + 1
        if not l:match("^%d%d:%d%d:%d%d %[[%w_]+%] .+") then good = false end
        if l:find("[^\32-\126]") then good = false end
    end
    check(good and total > 10, "every line of the session log has the form 'HH:MM:SS [module] text' (" .. total .. " lines)")
    check(H.lines(H.read(c.session))[1]:match("^12:00:00 %[loader%] session start: G1R_MegaMod v" .. VERP .. ", 2026%-10%-01 12:00:00, diagnostics normal$") ~= nil, "first line: session start")
    H.stop(c)

    section("files: what is not plain ASCII, long lines")
    root = H.mod("ascii")
    c = H.start(root)
    env, D = c.M.repopulate.env, c.M.repopulate.diag
    env.print("[Fake] B\195\164r\tand\ttabs\r\n")
    D.event(("x"):rep(5000))
    D.note("umlaut", "\195\188ber", "d\195\169tail")
    c.diag.flush()
    log = H.read(c.session)
    check(H.has(log, "[repopulate] [Fake] B??r    and    tabs\n"), "other bytes become '?', tabs become spaces")
    local longest = 0
    for _, l in ipairs(H.lines(log)) do if #l > longest then longest = #l end end
    check(longest > 1900 and longest < 2100, "a very long line is cut (" .. longest .. " characters)")
    c.ue:fireConsole("g1r diag")
    local report = H.read(c.dir .. "/report-latest.txt")
    check(report:find("[^\10\32-\126]") == nil, "the report is plain ASCII")
    H.stop(c)

    section("files: old session logs are pruned to SessionFiles")
    root = H.mod("prune", { files = { ["Scripts/config.lua"] = H.config("Config.Diagnostics = { SessionFiles = 2 }") } })
    H.write(root .. "/Scripts/diagnostics/session-notes.log", "not a session log\n")
    H.write(root .. "/Scripts/diagnostics/session-20200101-000000.log", "a session log nobody listed\n")
    local t0 = os.time({ year = 2026, month = 10, day = 1, hour = 12, min = 0, sec = 0 })
    local names = {}
    for i = 1, 4 do
        if i == 3 then
            -- someone edited the list: other names must never be deleted
            local index = H.read(root .. "/Scripts/diagnostics/sessions.txt")
            H.write(root .. "/Scripts/diagnostics/sessions.txt", "../config.lua\nREADME.txt\nsession-notes.log\n" .. index .. index)
        end
        c = H.start(root, { time = t0 + i * 3600 })
        names[i] = os.date("session-%Y%m%d-%H%M%S.log", t0 + i * 3600)
        check(H.exists(root .. "/Scripts/diagnostics/" .. names[i]), "run " .. i .. ": its session log exists")
        H.stop(c)
    end
    local d = root .. "/Scripts/diagnostics/"
    check(not H.exists(d .. names[1]) and not H.exists(d .. names[2]) and H.exists(d .. names[3]) and H.exists(d .. names[4]), "only the newest two session logs are left")
    check(H.read(d .. "sessions.txt") == names[3] .. "\n" .. names[4] .. "\n", "sessions.txt lists exactly those")
    check(H.exists(d .. "README.txt") and H.exists(d .. "session-notes.log") and H.exists(d .. "report-latest.txt") and H.exists(root .. "/Scripts/config.lua"),
        "nothing else was deleted, whatever sessions.txt said")
    check(H.exists(d .. "session-20200101-000000.log"), "a session log that is not in sessions.txt stays (the mod cannot list the folder)")

    section("files: report-latest.txt on schedule")
    root = H.mod("schedule", { modules = { repopulate = H.probe("repopulate", 'G1R_DIAG.status(function() return { "status line of the module" } end)') } })
    c = H.start(root)
    report = H.read(c.dir .. "/report-latest.txt")
    check(report ~= nil and H.has(report, "time: 2026-10-01 12:00:00") and H.has(report, "minutes since load: 0.0"), "written when the mod is loaded")
    check(H.find(H.part(report, "status"), "the modules are not asked while the mod is loading") ~= nil and not H.has(report, "status line of the module"),
        "at load the modules are not asked for their status")
    H.seconds(c, 299)
    check(H.read(c.dir .. "/report-latest.txt") == report, "not rewritten before ReportMinutes (5) are over")
    H.seconds(c, 1)
    local second = H.read(c.dir .. "/report-latest.txt")
    check(second ~= report and H.has(second, "time: 2026-10-01 12:05:00") and H.has(second, "minutes since load: 5.0"), "rewritten after 5 minutes")
    check(H.find(H.part(second, "status"), "[repopulate] status line of the module") ~= nil, "now with the status lines of the modules")
    H.seconds(c, 300)
    check(H.has(H.read(c.dir .. "/report-latest.txt"), "time: 2026-10-01 12:10:00"), "and again 5 minutes later")
    local stamped = 0
    for _, f in ipairs(H.list(c.dir)) do if f:match("^report%-%d") then stamped = stamped + 1 end end
    check(stamped == 0, "the timer writes no stamped report")
    -- the report is written inside the 600th call of the timer, which is counted when it has ended
    check(H.find(H.part(H.read(c.dir .. "/report-latest.txt"), "counters"), "[loader] callbacks timer: 599 calls, 0 errors") ~= nil, "the timer's own cost is counted")
    H.stop(c)

    section("files: content of a report")
    root = H.mod("report", { modules = {
        repopulate = H.probe("repopulate", [[
G1R_DIAG.version("1.2.3-test")
G1R_DIAG.status(function() return { "first status line", "second status line" } end)
G1R_DIAG.note("containers.defaults", "module list", "IO_NC_CHEST_01")
G1R_DIAG.note("plain.note", true)
]]),
        markers = 'error("markers broke")\n',
    }, files = { ["Scripts/config.lua"] = H.config("Config.Modules = { Repopulate = true, Markers = true }") } })
    c = H.start(root, { mock = { anyHook = true } })
    local ue = c.ue
    env = c.M.repopulate.env
    ue.cost.StaticFindObject, ue.cost.FindAllOf, ue.cost.FindFirstOf = 0.003, 0.002, 0.001
    ue.objects["/Script/G1R.Found"] = ue:object("Class /Script/G1R.Found")
    env.StaticFindObject("/Script/G1R.Found")
    env.StaticFindObject("/Script/G1R.NotThere")
    env.FindAllOf("X") env.FindFirstOf("Y")
    env.LoopInGameThreadWithDelay(250, function() ue.clock = ue.clock + 0.04 error("tick broke") end)
    ue.loops[#ue.loops].callback()
    ue.loops[#ue.loops].callback()
    for i = 1, 150 do c.M.repopulate.diag.event("event number " .. i) end
    ue:advance(90)
    check(ue:fireConsole("g1r diag") == true, "g1r diag handled")
    report = H.read(c.dir .. "/report-latest.txt")
    local lines = H.lines(report)
    check(lines[1] == "G1R_MegaMod v" .. VER .. " - diagnostics report" and lines[2] == "time: 2026-10-01 12:01:30" and lines[3] == "minutes since load: 1.5",
        "header: mod name / version, real time, minutes since load")
    local order, last = { "== modules ==", "== status ==", "== notes ==", "== counters ==", "== errors ==", "== last 120 recorder lines ==" }, 0
    local inOrder = true
    for _, title in ipairs(order) do
        local at
        for i, l in ipairs(lines) do if l == title then at = i break end end
        if not at or at < last then inOrder = false break end
        last = at
    end
    check(inOrder, "parts in the order: modules, status, notes, counters, errors, last recorder lines")
    local part = H.part(report, "modules")
    check(part[1] == "repopulate: loaded, version 1.2.3-test" and part[2] ~= nil and part[2]:find("^markers: FAILED %- .*main%.lua:1: markers broke$") ~= nil,
        "modules: loaded or not, with the error")
    part = H.part(report, "status")
    check(#part == 2 and part[1] == "[repopulate] first status line" and part[2] == "[repopulate] second status line", "status lines of the modules")
    part = H.part(report, "notes")
    check(part[1] == "[repopulate]" and part[2] == "containers.defaults = module list (IO_NC_CHEST_01) [first seen 12:00:00]" and part[3] == "plain.note = true [first seen 12:00:00]",
        "notes as 'key = value (detail) [first seen HH:MM:SS]'")
    part = H.part(report, "counters")
    check(H.find(part, "[repopulate] lookups: 2 calls, 2 first-time, 1 not found, 0 repeated after not found, 6.0 ms total, slowest 3.0 ms /Script/G1R.") ~= nil,
        "counters: lookups (calls / first-time / not found / total ms / slowest path)")
    check(H.find(part, "[repopulate] FindAllOf: 1 calls, 2.0 ms total") ~= nil and H.find(part, "[repopulate] FindFirstOf: 1 calls, 1.0 ms total") ~= nil,
        "counters: FindAllOf and FindFirstOf (calls / total ms)")
    check(H.find(part, "[repopulate] callbacks LoopInGameThreadWithDelay: 2 calls, 2 errors, 2 slow, max 40.0 ms") ~= nil,
        "counters: callbacks per kind (calls / errors / slow / max ms)")
    part = H.part(report, "errors")
    check(part[1] == "count: 3 (2 distinct)", "errors: count")
    check(H.find(part, "[repopulate] 2 x in LoopInGameThreadWithDelay 250, first 12:00:00, last 12:00:00") ~= nil and H.find(part, "tick broke") ~= nil
        and H.find(part, "    stack traceback:") ~= nil and H.find(part, "[markers] 1 x in load, ") ~= nil, "errors: first traceback of each, with the number of repeats")
    part = H.part(report, "last 120 recorder lines")
    check(#part == 120 and H.has(part[120], "[repopulate] event number 150") and H.has(part[1], "[repopulate] event number 31"), "the last 120 recorder lines, oldest first")
    check(report:find("[^\10\32-\126]") == nil, "plain ASCII")
    check(not H.has(report, "TempMod") and not H.has(H.read(c.session), "TempMod") and H.has(report, "<mod>/modules/markers/Scripts/main.lua:1: markers broke")
        and H.has(report, "<mod>/Scripts/core/sandbox.lua:"),
        "the mod's own paths are written as <mod>/... (also where Lua shortened them): neither report nor session log shows where the mod is installed")
    local stampedName = "report-20261001-120130.txt"
    check(H.read(c.dir .. "/" .. stampedName) == report, "g1r diag also writes the stamped report with the same content")
    check(H.printed(ue, "[G1R_MegaMod] report written: Scripts/diagnostics/" .. stampedName) ~= nil, "and prints its path inside the mod folder")
    H.stop(c)

    section("files: dump")
    root = H.mod("dump", { modules = {
        repopulate = H.probe("repopulate", "G1R_DIAG.dump(function() return TEST.dumpData end)"),
        markers = H.probe("markers", "G1R_DIAG.dump(function() return TEST.markersDump() end)"),
    } })
    c = H.start(root)
    ue = c.ue
    local nested = { level = 1 }
    local at = nested
    for i = 2, 7 do      -- with the module's own table: eight levels, the most that is written
        at.next = { level = i }
        at = at.next
    end
    local shared = { "used", "twice" }
    local data = {
        text = 'quotes " and \\ and\nline breaks\tand \195\164 bytes \0 too',
        integer = 42, negative = -7, float = 0.1, big = 2 ^ 53, third = 1 / 3, whole = 3.0, least = math.mininteger, most = math.maxinteger,
        huge = math.huge, tiny = -math.huge, nan = 0 / 0,
        yes = true, no = false, empty = {},
        list = { "a", "b", { "c" } },
        [1.5] = "float key", [10] = "integer key", [-3] = "negative key",
        ["key with \"quotes\""] = 1,
        nested = nested,
        one = shared, two = shared,
    }
    _G.TEST.dumpData = data
    _G.TEST.markersDump = function() return { pins = { { id = "a", x = 1.25, y = -2 } } } end
    ue:advance(42)
    check(ue:fireConsole("g1r dump") == true, "g1r dump handled")
    local name = "dump-20261001-120042.lua"
    check(H.printed(ue, "[G1R_MegaMod] dump written: Scripts/diagnostics/" .. name) ~= nil, "the path inside the mod folder is printed")
    local text = H.read(c.dir .. "/" .. name)
    check(text ~= nil and text:find("[^\10\32-\126]") == nil and text:match("^%-%- G1R_MegaMod v" .. VERP .. " dump, 2026%-10%-01 12:00:42\nreturn {\n") ~= nil,
        "the dump is an ASCII Lua file: a comment line, then 'return { ... }'")
    local chunk = load(text or "", "=dump", "t", {})
    local okDump, dump = pcall(chunk or error)
    check(chunk ~= nil and okDump and type(dump) == "table", "it loads in an empty environment")
    check(H.same(dump.repopulate, data), "what the provider returned comes back exactly (nested tables, all number kinds, awkward text, keys)")
    local r1 = dump.repopulate or {}
    check(math.type(r1.whole) == "float" and math.type(r1.big) == "float" and math.type(r1.integer) == "integer" and math.type(r1.least) == "integer"
        and r1.third == 1 / 3 and r1.float == 0.1, "numbers keep their kind and their exact value")
    check(H.same(dump.markers, { pins = { { id = "a", x = 1.25, y = -2 } } }), "one table per module")
    check(dump._meta.mod == "G1R_MegaMod" and dump._meta.version == VER and dump._meta.time == "2026-10-01 12:00:42" and dump._meta.minutes == 0.7
        and dump._meta.modules.repopulate == "dumped" and dump._meta.modules.markers == "dumped" and dump._meta.refusedCount == 0, "_meta says what was dumped")
    -- what cannot be written
    local cyclic = { name = "outer", inner = { name = "inner" } }
    cyclic.inner.back = cyclic
    cyclic.self = cyclic
    local deep = {}
    at = deep
    for _ = 1, 12 do
        at.next = {}
        at = at.next
    end
    _G.TEST.dumpData = { ok = "kept", cyclic = cyclic, deep = deep, fn = function() end, thread = coroutine.create(function() end), [true] = "boolean key",
        [{}] = "table key" }
    _G.TEST.markersDump = function() error("provider broke") end
    ue:advance(1)
    check(ue:fireConsole("g1r dump") == true, "g1r dump with data that cannot be written: handled")
    text = H.read(c.dir .. "/dump-20261001-120043.lua")
    chunk = load(text or "", "=dump", "t", {})
    okDump, dump = pcall(chunk or error)
    check(chunk ~= nil and okDump and type(dump) == "table", "the file is still valid Lua")
    local r = okDump and dump.repopulate or {}
    check(r.ok == "kept" and r.cyclic.name == "outer" and r.cyclic.inner.name == "inner", "what can be written is written")
    check(r.cyclic.self == "<refused: cycle>" and r.cyclic.inner.back == "<refused: cycle>", "a table that contains itself is refused where the cycle closes")
    local depth, walk = 0, r.deep
    while type(walk) == "table" do depth, walk = depth + 1, walk.next end
    check(walk == "<refused: depth>" and depth == 7, "levels below the eighth are refused (" .. depth .. " levels of 'deep' written)")
    check(r.fn == "<refused: function>" and r.thread == "<refused: thread>", "values that are not plain data are refused")
    local meta = okDump and dump._meta or { refused = {}, modules = {} }
    local listed = table.concat(meta.refused, " | ")
    check(meta.refusedCount == 7 and H.has(listed, "repopulate.cyclic.self: cycle") and H.has(listed, "repopulate.cyclic.inner.back: cycle")
        and H.has(listed, ": deeper than 8 levels") and H.has(listed, "repopulate.fn: value of type function") and H.has(listed, "repopulate: key of type boolean")
        and H.has(listed, "repopulate: key of type table"), "_meta lists every refusal with its place (" .. tostring(meta.refusedCount) .. ")")
    check(dump.markers == nil and H.has(tostring(meta.modules.markers), "provider failed: ") and H.has(tostring(meta.modules.markers), "provider broke"),
        "a provider that raises: no table for the module, the reason in _meta")
    check(H.has(H.read(c.session), "[markers] ERROR in dump provider: ") and H.printed(ue, "error in markers (dump provider): ") ~= nil, "and the error is recorded")
    _G.TEST.dumpData = "not a table"
    _G.TEST.markersDump = function() return nil end
    ue:advance(1)
    ue:fireConsole("g1r dump")
    okDump, dump = pcall(load(H.read(c.dir .. "/dump-20261001-120044.lua") or "", "=dump", "t", {}))
    check(okDump and dump.repopulate == nil and dump._meta.modules.repopulate == "the provider returned a string, not a table"
        and dump._meta.modules.markers == "the provider returned nothing", "a provider that returns no table: said in _meta")
    log = H.read(c.session)
    check(H.count(log, "[diag] > dump provider of repopulate") == 3 and H.count(log, "[diag] dump provider of repopulate returned") == 3,
        "each call of a provider is announced in the session log and closed")
    H.stop(c)

    section("files: the diagnostics folder cannot be written")
    for _, how in ipairs({ "is a file", "is missing" }) do
        root = H.mod("unwritable", { modules = { repopulate = H.probe("repopulate", [[
G1R_DIAG.note("a.note", "kept in memory")
G1R_DIAG.crumb("a breadcrumb")
TEST.repopulate.handle = LoopInGameThreadWithDelay(250, function() TEST.repopulate.ticks = (TEST.repopulate.ticks or 0) + 1 end)
StaticFindObject("/Script/G1R.Thing")
]]) } })
        H.sh("rm -rf " .. H.q(root .. "/Scripts/diagnostics"))
        if how == "is a file" then H.write(root .. "/Scripts/diagnostics", "in the way\n") end
        c = H.start(root)
        ue = c.ue
        check(c.ok, how .. ": the loader does not raise (" .. tostring(c.err) .. ")")
        check(c.M.repopulate.loaded and c.M.markers.loaded and math.type(c.M.repopulate.handle) == "integer", how .. ": the modules are loaded")
        check(H.printedCount(ue, "diagnostics: file output switched off after 3 failed writes (<mod>/Scripts/diagnostics/") == 1, how .. ": said once in the log, without the folder of the game")
        check(H.has(ue.printed[#ue.printed], "loaded: " .. ALL_OK .. " | diagnostics normal, no file output ("), how .. ": the load line says so")
        H.seconds(c, 400)
        c.M.repopulate.env.print("[Fake] still printing\n")
        c.M.repopulate.diag.crumb("still fine")
        c.M.repopulate.env.LoopInGameThreadWithDelay(100, function() error("still caught") end)
        ue.loops[#ue.loops].callback()
        check(c.M.repopulate.ticks == 400 and #ue.errors == 0, how .. ": the modules' callbacks run, nothing raises")
        check(H.printedCount(ue, "file output switched off") == 1 and H.printed(ue, "error in repopulate (LoopInGameThreadWithDelay 100): ") ~= nil, how .. ": errors are still caught and logged")
        check(ue:fireConsole("g1r") == true and H.printed(ue, "repopulate: loaded, 1 error(s), 1 note(s)") ~= nil and H.printed(ue, "diagnostics: normal, file output off (") ~= nil,
            how .. ": g1r shows what is kept in memory and that file output is off")
        check(ue:fireConsole("g1r diag") == true and H.printed(ue, "no report written: file output is off (") ~= nil
            and ue:fireConsole("g1r dump") == true and H.printed(ue, "no dump written: file output is off (") ~= nil, how .. ": g1r diag / dump say why nothing is written")
        if how == "is a file" then
            check(H.read(root .. "/Scripts/diagnostics") == "in the way\n", how .. ": the file in the way is untouched")
        else
            check(not H.exists(root .. "/Scripts/diagnostics"), how .. ": nothing was created")
        end
        H.stop(c)
    end

    section("files: a session log that grows without end")
    root = H.mod("full")
    c = H.start(root)
    local D2 = c.M.repopulate.diag
    local long = ("y"):rep(1990)
    for _ = 1, 2300 do D2.event(long) end
    c.diag.flush()
    local size = #H.read(c.session)
    check(size > 4 * 1024 * 1024 and size < 5.2 * 1024 * 1024 and H.has(H.read(c.session), "[diag] this session log is full"), "it stops at about 4 MB and says so (" .. size .. " bytes)")
    D2.event("after the limit")
    D2.crumb("crumb after the limit")
    c.diag.flush()
    check(#H.read(c.session) == size, "nothing more is written to it")
    check(c.ue:fireConsole("g1r diag") == true and H.has(H.read(c.dir .. "/report-latest.txt"), "crumb after the limit"), "reports still show the latest lines")
    H.stop(c)

    section("files: verbose")
    root = H.mod("verbose", { files = { ["Scripts/config.lua"] = H.config('Config.Diagnostics = { Level = "Verbose" }') } })
    c = H.start(root, { mock = { anyHook = true } })
    env = c.M.repopulate.env
    check(H.has(c.ue.printed[#c.ue.printed], "| diagnostics verbose -> Scripts/diagnostics/session-"), "load line says verbose")
    env.print("[Fake] at once\n")
    check(H.has(H.read(c.session), "[Fake] at once"), "every line is written at once")
    c.ue.objects["/Script/G1R.Thing"] = c.ue:object("Class /Script/G1R.Thing")
    env.StaticFindObject("/Script/G1R.Thing") env.StaticFindObject("/Script/G1R.Thing")
    env.NotifyOnNewObject("/Script/G1R.Thing", function() end)
    log = H.read(c.session)
    check(H.has(log, "lookup /Script/G1R.Thing: found again") and H.has(log, "NotifyOnNewObject /Script/G1R.Thing: registered"), "repeated searches and registrations get a line")
    H.stop(c)
end

-- ---------------------------------------------------------------------------
-- Module handle (G1R_DIAG)
-- ---------------------------------------------------------------------------
function tests.handle()
    section("handle: note")
    local root = H.mod("handle")
    local c = H.start(root)
    local ue, D, M2 = c.ue, c.M.repopulate.diag, c.M.markers.diag
    local function logText() c.diag.flush() return H.read(c.session) end
    check(select("#", D.note("containers.defaults", "module list", "IO_NC_CHEST_01")) == 0, "note returns nothing")
    local log = logText()
    check(H.has(log, "12:00:00 [repopulate] note containers.defaults = module list (IO_NC_CHEST_01)\n"), "first value: one line in the session log")
    D.note("containers.defaults", "module list", "IO_NC_CHEST_01")
    D.note("containers.defaults", "module list", "another detail")
    D.note("containers.defaults", "module list")
    check(H.count(logText(), "note containers.defaults") == 1, "the same value again: nothing is recorded (also when only the detail differs)")
    ue:advance(65)
    D.note("containers.defaults", "library", "DataModuleLibrary")
    log = logText()
    check(H.has(log, "12:01:05 [repopulate] note containers.defaults = library (DataModuleLibrary) [was module list]\n"), "a changed value is written to the session log with the old one")
    ue:advance(5)
    D.note("containers.defaults", "module list")
    D.note("a.boolean", true)
    D.note("a.number", 3)
    D.note("a.float", 0.5, 12)
    D.note("a.nil")
    M2.note("markers.map_found_by", "notification")
    ue:fireConsole("g1r diag")
    local notes = H.part(H.read(c.dir .. "/report-latest.txt"), "notes")
    check(H.find(notes, "containers.defaults = module list [first seen 12:00:00] [changed 2 time(s), last 12:01:10, first value: module list]") ~= nil,
        "report: latest value, first seen, number of changes, first value")
    check(H.find(notes, "a.boolean = true [first seen 12:01:10]") ~= nil and H.find(notes, "a.number = 3 [first seen 12:01:10]") ~= nil
        and H.find(notes, "a.float = 0.5 (12) [first seen 12:01:10]") ~= nil and H.find(notes, "a.nil = nil [first seen 12:01:10]") ~= nil, "values of any simple kind")
    local headerR, headerM, noteM
    for i, l in ipairs(notes) do
        if l == "[repopulate]" then headerR = i end
        if l == "[markers]" then headerM = i end
        if l:find("markers.map_found_by = notification", 1, true) then noteM = i end
    end
    check(headerR and headerM and noteM and headerR < headerM and headerM < noteM, "notes are grouped by module")
    for i = 1, 30 do D.note("flapping", i % 2 == 0 and "a" or "b") end
    check(H.count(logText(), "note flapping = ") == 21 and H.count(logText(), "further changes of this note are only counted") == 1, "a value that keeps changing gets 20 change lines, then it is only counted")

    section("handle: event, crumb, status, dump, version")
    check(select("#", D.event("something happened")) == 0 and H.printed(ue, "something happened") == nil and H.has(logText(), "[repopulate] something happened\n"),
        "event: in the session log, not in UE4SS.log")
    D.event(12345)
    check(H.has(logText(), "[repopulate] 12345\n"), "event: other values are written as text")
    check(select("#", D.crumb("before the risky step")) == 0 and H.has(H.read(c.session), "[repopulate] > before the risky step\n"), "crumb: on disk at once")
    D.status(function() return { "status A", "status B" } end)
    M2.status(function() error("status broke") end)
    D.version("7.7.7")
    D.dump(function() return { value = 1 } end)
    local before = #ue.printed
    check(ue:fireConsole("g1r") == true, "g1r handled")
    local shown = {}
    for i = before + 1, #ue.printed do shown[#shown + 1] = ue.printed[i] end
    check(H.find(shown, "[G1R_MegaMod] repopulate: loaded, version 7.7.7, ") ~= nil and H.find(shown, "[G1R_MegaMod]   status A\n") ~= nil
        and H.find(shown, "[G1R_MegaMod]   status B\n") ~= nil, "status and version are shown by g1r")
    check(H.find(shown, "[G1R_MegaMod]   (provider failed: ") ~= nil and H.has(H.read(c.session), "[markers] ERROR in status provider: "), "a status function that raises is caught and recorded")
    D.status(function() return "one text instead of a list" end)
    M2.status(function() local t = {} for i = 1, 60 do t[i] = "line " .. i end return t end)
    ue:fireConsole("g1r diag")
    local status = H.part(H.read(c.dir .. "/report-latest.txt"), "status")
    check(H.find(status, "[repopulate] one text instead of a list") ~= nil and H.find(status, "[markers] line 40") ~= nil and H.find(status, "[markers] line 41") == nil
        and H.find(status, "[markers] (20 more lines)") ~= nil, "status: a text is taken as one line, a long list is cut")
    check(H.find(H.part(H.read(c.dir .. "/report-latest.txt"), "modules"), "repopulate: loaded, version 7.7.7") ~= nil, "version is in the report")

    section("handle: wrong arguments")
    local calls = {
        function() D.note() end, function() D.note(123, "v") end, function() D.note({}, "v") end, function() D.note("", "v") end,
        function() D.note(D, "key", "value") end, function() D:note("key", "value") end,
        function() D.note("table.value", {}) end, function() D.note("fn.value", print, function() end) end,
        function() D.note("bad.tostring", setmetatable({}, { __tostring = function() error("no text") end })) end,
        function() D.event() end, function() D.event(nil) end, function() D.event({}) end, function() D.event(setmetatable({}, { __tostring = function() error("no") end })) end,
        function() D.crumb() end, function() D.crumb(false) end,
        function() D.status() end, function() D.status("text") end, function() D.status({}) end,
        function() D.dump() end, function() D.dump(5) end,
        function() D.version() end, function() D.version({}) end, function() D.version(1.5) end,
    }
    local raised = 0
    for _, f in ipairs(calls) do
        if not pcall(f) then raised = raised + 1 end
    end
    check(raised == 0, "no handle function raises, whatever it is given (" .. #calls .. " calls)")
    ue:fireConsole("g1r diag")
    local report = H.read(c.dir .. "/report-latest.txt")
    check(H.find(H.part(report, "notes"), "[repopulate] 15 diagnostics call(s) ignored (first: note: the key must be a text)") ~= nil, "ignored calls are counted and shown in the report")
    check(H.has(logText(), "[repopulate] diagnostics call ignored: note: the key must be a text"), "the first one is in the session log")
    check(H.find(H.part(report, "status"), "[repopulate] one text instead of a list") ~= nil, "a wrong call does not replace what was registered before")
    for i = 1, 320 do D.note("many." .. i, i) end
    ue:fireConsole("g1r diag")
    report = H.read(c.dir .. "/report-latest.txt")
    check(H.find(H.part(report, "notes"), "many.290 = 290") ~= nil and H.find(H.part(report, "notes"), "many.300 = 300") == nil, "the number of notes of a module is limited (300)")
    H.stop(c)

    section("core: functions called with anything")
    root = H.mod("core")
    c = H.start(root)
    local G = c.diag
    local odd = { nil, false, 1, "", "text", {}, function() end, 0 / 0, setmetatable({}, { __tostring = function() error("no") end }) }
    raised = 0
    for _, name in ipairs({ "line", "crumb", "error", "count", "find", "lookup", "registration", "handle", "seen", "immediate" }) do
        for i = 1, #odd + 1 do
            for j = 1, #odd + 1 do
                if not pcall(G[name], odd[i], odd[j], odd[(i + j) % (#odd + 1) + 1], odd[(i * j) % (#odd + 1) + 1]) then raised = raised + 1 end
            end
        end
    end
    for _, name in ipairs({ "tick", "flush", "status", "summary", "report", "dump" }) do
        for i = 1, #odd + 1 do
            if not pcall(G[name], odd[i], odd[i]) then raised = raised + 1 end
        end
    end
    check(raised == 0, "no core function raises")
    check(c.ue:fireConsole("g1r") == true and c.ue:fireConsole("g1r diag") == true, "and the diagnostics still work afterwards")
    report = H.read(c.dir .. "/report-latest.txt")
    check(report ~= nil and not H.has(report, "internal problems of the diagnostics"), "without an internal problem")
    H.stop(c)

    section("core: before it is started")
    local fresh = dofile(MOD .. "Scripts/core/diag.lua")
    raised = 0
    for _, name in ipairs({ "line", "crumb", "error", "count", "find", "lookup", "registration", "tick", "flush", "report", "dump", "handle", "summary", "status", "seen", "immediate" }) do
        if not pcall(fresh[name], "m", "x", 1, true) then raised = raised + 1 end
    end
    check(raised == 0 and fresh.enabled == false and fresh.handle("m") == nil and #fresh.status() == 0, "every function is harmless and nothing is on")
end

-- ---------------------------------------------------------------------------
-- Console
-- ---------------------------------------------------------------------------
function tests.console()
    section("console: g1r, g1r diag, g1r dump, g1r help, unknown word")
    local root = H.mod("console", { modules = { repopulate = H.probe("repopulate", [[
G1R_DIAG.version("1.0-test")
G1R_DIAG.status(function() return { "containers: 3 here" } end)
G1R_DIAG.dump(function() return { n = 3 } end)
G1R_DIAG.note("a", "b")
]]) } })
    local c = H.start(root)
    local ue = c.ue
    local function answer(command, direct)
        local before = #ue.printed
        local result
        if direct then result = ue.console.g1r[1](table.unpack(direct, 1, 3)) else result = ue:fireConsole(command) end
        local out = {}
        for i = before + 1, #ue.printed do out[#out + 1] = ue.printed[i] end
        return result, out
    end
    local function allPrefixed(out)
        for _, l in ipairs(out) do
            if l:sub(1, 14) ~= "[G1R_MegaMod] " or l:sub(-1) ~= "\n" then return false end
        end
        return #out > 0
    end
    ue:advance(90)
    local result, out = answer("g1r")
    check(result == true and #ue.errors == 0, "g1r: handled (true)")
    check(allPrefixed(out), "g1r: every line starts with [G1R_MegaMod] and ends with a line break")
    check(out[1] == "[G1R_MegaMod] G1R_MegaMod v" .. VER .. ", 1.5 minutes since load\n", "g1r: first line with version and time since load")
    local expected = { out[1] }
    for _, name in ipairs(NAMES) do
        if name == "repopulate" then
            expected[#expected + 1] = "[G1R_MegaMod] repopulate: loaded, version 1.0-test, 0 error(s), 1 note(s)\n"
            expected[#expected + 1] = "[G1R_MegaMod]   containers: 3 here\n"
        else
            expected[#expected + 1] = "[G1R_MegaMod] " .. name .. ": loaded, 0 error(s), 0 note(s)\n"
        end
    end
    local STATUS_LINES = #expected + 1
    check(table.concat(out, "", 1, #expected) == table.concat(expected), "g1r: one line per module in the order of core/modules.lua, followed by the module's own status lines")
    local lastLine = out[STATUS_LINES]
    check(lastLine ~= nil and lastLine:find("^%[G1R_MegaMod%] diagnostics: normal, Scripts/diagnostics/session%-20261001%-120000%.log, %d+ line%(s%), 0 error%(s%), 1 note%(s%)\n$") ~= nil
        and #out == STATUS_LINES, "g1r: diagnostics summary last (" .. tostring(lastLine):gsub("\n", "") .. ")")
    result, out = answer("g1r status")
    check(result == true and #out == STATUS_LINES, "g1r status: the same")
    result, out = answer("g1r diag")
    check(result == true and #out == 1 and out[1] == "[G1R_MegaMod] report written: Scripts/diagnostics/report-20261001-120130.txt\n"
        and H.exists(c.dir .. "/report-20261001-120130.txt"), "g1r diag: writes a stamped report and prints its path")
    result, out = answer("g1r dump")
    check(result == true and #out == 1 and out[1] == "[G1R_MegaMod] dump written: Scripts/diagnostics/dump-20261001-120130.lua\n"
        and H.exists(c.dir .. "/dump-20261001-120130.lua"), "g1r dump: writes a dump and prints its path")
    result, out = answer("g1r help")
    check(result == true and allPrefixed(out) and #out == 5 and H.find(out, "g1r diag") and H.find(out, "g1r dump") and H.find(out, "g1r help"), "g1r help: the list of commands")
    result, out = answer("g1r frobnicate now")
    check(result == true and allPrefixed(out) and out[1] == "[G1R_MegaMod] unknown command 'frobnicate'\n" and #out == 6, "unknown word: said, followed by the list of commands; still handled")
    result, out = answer("g1r DIAG")
    check(result == true and H.find(out, "report written: ") ~= nil, "the word may be written in capitals")
    result, out = answer(nil, { "g1r help", nil, nil })
    check(result == true and #out == 5, "without a parameter list the command line itself is read")
    result, out = answer(nil, { nil, nil, nil })
    check(result == true and #out == STATUS_LINES, "without anything: status")
    result, out = answer(nil, { "g1r", { 1, 2 }, {} })
    check(result == true and H.find(out, "unknown command '1'") ~= nil, "parameters of another kind do not break it")
    check(#ue.errors == 0, "UE4SS saw a boolean every time")
    local registered = {}
    for name in pairs(ue.console) do registered[#registered + 1] = name end
    check(#registered == 1 and registered[1] == "g1r" and next(ue.globalConsole) == nil, "the loader registers the command g1r and no other")
    H.stop(c)
end

-- ---------------------------------------------------------------------------
-- The real modules through the loader
-- ---------------------------------------------------------------------------
function tests.real()
    section("real modules: loaded through the loader, the game gives nothing")
    local root = H.mod("real", { real = true })
    local stateBefore = table.concat(H.list(root .. "/modules/repopulate/Scripts/state"), ",")
    local c = H.start(root, { prepare = function(ue) ue.functions["/Script/Engine.PlayerController:ClientRestart"] = true end })
    local ue = c.ue
    check(c.ok, "the loader runs (" .. tostring(c.err) .. ")")
    local line = ue.printed[#ue.printed]
    check(line:match(LOAD_LINE) ~= nil, "load line: " .. line:gsub("\n", ""))
    check(H.printed(ue, "[G1R_Repopulate] v") ~= nil and H.has(H.printed(ue, "[G1R_Repopulate] v") or "", " loaded: "), "repopulate printed its load line")
    check(H.printed(ue, "[NPCMarkers] v") ~= nil and H.has(H.printed(ue, "[NPCMarkers] v") or "", " loaded: "), "markers printed its load line")
    local log = H.read(c.session)
    check(log:find("%[repopulate%] %[G1R_Repopulate%] v[%w%.%-]+ loaded: ") ~= nil and log:find("%[markers%] %[NPCMarkers%] v[%w%.%-]+ loaded: ") ~= nil,
        "both load lines are in the session log")
    check(not H.has(log, "ERROR in ") and not H.has(log, "FATAL"), "no error recorded while loading")
    check(H.printed(ue, "[G1R_XP] v") ~= nil and H.has(H.printed(ue, "[G1R_XP] v") or "", " loaded: "), "xp printed its load line")
    check(#ue.loops == 17, "seventeen loops: one per module that has one (all but general and othermods), the loader's two, the kit's for keys (keys binds F3) (" .. #ue.loops .. ")")
    check(ue.console.repop ~= nil and ue.console.g1r_repopulate ~= nil and ue.console.xp ~= nil and ue.console.g1r_xp ~= nil and ue.console.g1r ~= nil,
        "console commands: repop, g1r_repopulate, xp, g1r_xp, g1r")
    check(rawget(_G, "REPOP_TEST") == nil and rawget(_G, "NPCMARKERS_TEST") == nil and rawget(_G, "XP_TEST") == nil, "the modules' test hooks stay inert")
    local leaked = {}
    for k in pairs(_G) do
        if type(k) == "string" and not _G.KNOWN_GLOBALS[k] then leaked[#leaked + 1] = k end
    end
    table.sort(leaked)
    check(#leaked == 0, "the modules defined no real global (" .. table.concat(leaked, ", ") .. ")")
    for _ = 1, 240 do
        ue:advance(0.25)
        ue:tick()
    end
    check(#ue.errors == 0, "60 seconds of ticks: no error reached UE4SS (" .. tostring(ue.errors[1]) .. ")")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    ue:fireNotify("/Script/G1R.InteractiveObjectActor", ue:invalid())
    ue:fireNotify("/Game/UI/ManagementUI/Map/W_Map_Main.W_Map_Main_C", ue:invalid())
    ue:fireHook("/Script/Engine.PlayerController:ClientRestart", ue:invalid())
    for _ = 1, 160 do
        ue:advance(0.25)
        ue:tick()
    end
    check(#ue.errors == 0, "map load, new objects, player restart, 40 more seconds: no error reached UE4SS (" .. tostring(ue.errors[1]) .. ")")
    check(ue:fireConsole("repop") == true and ue:fireConsole("g1r") == true and ue:fireConsole("g1r diag") == true and ue:fireConsole("g1r dump") == true and #ue.errors == 0,
        "repop, g1r, g1r diag, g1r dump: handled")
    local report = H.read(c.dir .. "/report-latest.txt")
    check(H.find(H.part(report, "errors"), "count: 0 (0 distinct)") ~= nil, "report: no error recorded")
    check(H.find(H.part(report, "modules"), "repopulate: loaded") ~= nil and H.find(H.part(report, "modules"), "markers: loaded") ~= nil
        and H.find(H.part(report, "modules"), "xp: loaded") ~= nil, "report: the three modules loaded")
    local counters = H.part(report, "counters")
    check(H.find(counters, "[repopulate] callbacks LoopInGameThreadWithDelay: 400 calls, 0 errors") ~= nil
        and H.find(counters, "[markers] callbacks LoopInGameThreadWithDelay: 400 calls, 0 errors") ~= nil
        and H.find(counters, "[xp] callbacks LoopInGameThreadWithDelay: 400 calls, 0 errors") ~= nil, "report: the three loops ran 400 times without an error")
    check(H.find(counters, "[repopulate] registered RegisterHook: 1 ok, 0 failed") ~= nil, "report: repopulate's hook registered")
    local dumpName
    for _, f in ipairs(H.list(c.dir)) do if f:match("^dump%-") then dumpName = f end end
    local okDump, dump = pcall(load(H.read(c.dir .. "/" .. tostring(dumpName)) or "error()", "=dump", "t", {}))
    check(okDump and type(dump) == "table" and type(dump._meta) == "table" and dump._meta.refusedCount == 0, "the dump loads and nothing in it was refused")
    check(table.concat(H.list(root .. "/modules/repopulate/Scripts/state"), ",") == stateBefore, "no progress file was written (no game world)")
    log = H.read(c.session)
    check(not H.has(log, "ERROR in ") and not H.has(log, "diagnostics call ignored"), "session log: no error, no wrong diagnostics call")
    H.stop(c)

    section("real modules: diagnostics off")
    root = H.mod("realoff", { real = true, files = { ["Scripts/config.lua"] = H.config('Config.Diagnostics = { Level = "off" }') } })
    c = H.start(root, { prepare = function(ue2) ue2.functions["/Script/Engine.PlayerController:ClientRestart"] = true end })
    ue = c.ue
    check(c.ok and H.has(ue.printed[#ue.printed], "loaded: " .. ALL_OK .. " | diagnostics off"), "the modules load without G1R_DIAG")
    for _ = 1, 80 do
        ue:advance(0.25)
        ue:tick()
    end
    check(#ue.errors == 0 and #ue.loops == 16 and #H.list(c.dir) == 1, "they tick without an error, nothing is written (" .. #ue.loops .. " loops)")
    H.stop(c)
end

-- ---------------------------------------------------------------------------
-- Operations: what was going on when the game ended (session-<stamp>.ops),
-- and the report of every session
-- ---------------------------------------------------------------------------
tests.operations = function()
    local WIDTH, SLOTS = 128, 256
    local function records(path)
        local text = H.read(path) or ""
        local out = {}
        for i = 1, #text // WIDTH do out[i] = text:sub((i - 1) * WIDTH + 1, i * WIDTH) end
        return out, #text
    end

    section("operations: announced before, taken back after")
    local root = H.mod("ops")
    local c = H.start(root)
    local ue, D, M2 = c.ue, c.M.repopulate.diag, c.M.markers.diag
    local base = c.dir .. "/" .. os.date("session-%Y%m%d-%H%M%S", c.t0)
    -- (K0: the operations of the loader's start - none; the numbers below count on from there)
    local list, size = records(base .. ".ops")
    local K0 = #list
    check(H.exists(base .. ".ops") and size == 0 and K0 == START_SEARCHES, "the operations file of the session is there from the start, empty")
    local function num(n) return ("%08d"):format(K0 + n) end
    local n1 = D.op("containers: look at new objects (25 waiting)")
    list, size = records(base .. ".ops")
    check(n1 == K0 + 1 and size == (K0 + 1) * WIDTH and list[K0 + 1] == (num(1) .. " > 12:00:00 repopulate containers: look at new objects (25 waiting)" .. (" "):rep(WIDTH)):sub(1, WIDTH - 1) .. "\n",
        "op(text) returns a number; the record is in the file when the call returns: number, '>', time, module, text, one fixed-size line")
    check(select("#", D.done(n1)) == 0, "done returns nothing")
    list = records(base .. ".ops")
    check(list[K0 + 1]:sub(10, 10) == "=" and list[K0 + 1]:sub(1, 9) == num(1) .. " " and list[K0 + 1]:sub(11) == (" 12:00:00 repopulate containers: look at new objects (25 waiting)" .. (" "):rep(WIDTH)):sub(1, WIDTH - 11) .. "\n",
        "done(number) turns the '>' into '=' and changes nothing else")
    ue:advance(7)
    local n2 = M2.op("markers: refresh Map_World")
    local n3 = D.op(("x"):rep(300) .. "\nsecond line \200")
    list, size = records(base .. ".ops")
    check(n2 == K0 + 2 and n3 == K0 + 3 and size == (K0 + 3) * WIDTH and list[K0 + 2]:find("^" .. num(2) .. " > 12:00:07 markers    markers: refresh Map_World +\n$") ~= nil,
        "every module's operations go into the same file, in the order they began")
    check(#list[K0 + 3] == WIDTH and list[K0 + 3]:sub(-1) == "\n" and list[K0 + 3]:find("[^\10\32-\126]") == nil and list[K0 + 3]:sub(32) == ("x"):rep(WIDTH - 32) .. "\n",
        "a long text is cut to the record's size (96 characters); nothing but plain ASCII gets in")
    D.done(n3)
    list = records(base .. ".ops")
    check(list[K0 + 2]:sub(10, 10) == ">" and list[K0 + 3]:sub(10, 10) == "=", "an operation that was not taken back stays '>' (the game went down in it, or it raised)")
    -- wrong use
    check(D.op() ~= nil and D.op({}) ~= nil, "op with no text or with a table still announces something")
    D.done(nil); D.done(tostring(n3)); D.done(0); D.done(99999); D.done(-1); D.done(K0 + 2.5)
    list, size = records(base .. ".ops")
    check(size == (K0 + 5) * WIDTH and list[K0 + 2]:sub(10, 10) == ">", "done with anything that is not the number of an operation does nothing")
    local report = H.read(c.diag.report(true))
    check(H.has(report, "operations: " .. (K0 + 5) .. " announced (" .. os.date("session-%Y%m%d-%H%M%S", c.t0) .. ".ops)"), "the report says how many and names the file")
    H.stop(c)

    section("operations: the file is a ring of the last 256")
    root = H.mod("opsring")
    c = H.start(root)
    D = c.M.repopulate.diag
    base = c.dir .. "/" .. os.date("session-%Y%m%d-%H%M%S", c.t0)
    K0 = #(records(base .. ".ops"))
    local numbers = {}
    for i = 1, 300 do numbers[i] = D.op("operation " .. i) end
    list, size = records(base .. ".ops")
    check(size == SLOTS * WIDTH and #list == SLOTS, "after 300 operations the file holds 256 records (" .. size .. " bytes)")
    -- operation number n stands in place ((n - 1) mod 256) + 1; the module's operation i has the number K0 + i
    local last, oldest = K0 + 300 - SLOTS, K0 + 300 - SLOTS + 1        -- the place of the newest record, the place (and number) of the oldest left
    check(K0 == START_SEARCHES and list[1]:find(("^00000257 > .- operation %d "):format(257 - K0)) ~= nil and list[last]:find(("^%08d > .- operation 300 "):format(K0 + 300)) ~= nil
        and list[oldest]:find(("^%08d > .- operation %d "):format(oldest, oldest - K0)) ~= nil,
        "the newest overwrite the oldest in place: record 257 stands where 1 stood, the one after the newest is the oldest left")
    D.done(numbers[1]); D.done(numbers[last - K0])
    list = records(base .. ".ops")
    check(list[K0 + 1]:sub(10, 10) == ">" and list[last]:sub(10, 10) == ">" and tonumber(list[K0 + 1]:sub(1, 8)) == K0 + 1 + SLOTS,
        "done for an operation whose place holds a later one changes nothing")
    D.done(numbers[300]); D.done(numbers[oldest - K0])
    list = records(base .. ".ops")
    check(list[last]:sub(10, 10) == "=" and list[oldest]:sub(10, 10) == "=", "done for the ones still there works")
    -- the newest record is the one with the highest number: that is how the file is read after a crash
    local newest, state = 0, nil
    for _, r in ipairs(list) do
        local number = tonumber(r:sub(1, 8))
        if number > newest then newest, state = number, r:sub(10, 10) end
    end
    check(newest == K0 + 300 and state == "=", "the record with the highest number is the last operation, with its state")
    H.stop(c)

    section("operations: searches among all objects announce themselves")
    root = H.mod("opsfind")
    c = H.start(root)
    ue = c.ue
    local env = c.M.repopulate.env
    base = c.dir .. "/" .. os.date("session-%Y%m%d-%H%M%S", c.t0)
    local atCall = {}
    local originalAll, originalFirst = ue.globals.FindAllOf, ue.globals.FindFirstOf
    ue.allOf.GothicCharacterState = { ue:object("GothicCharacterState /Game/Map.State_1") }
    -- (the wrappers were made when the module was loaded: what they call is looked at through the mock's own tables)
    local seen = nil
    ue.allOf.Probe = setmetatable({}, { __len = function() seen = (records(base .. ".ops")) return 0 end })
    K0 = #(records(base .. ".ops"))
    local function num(n) return ("%08d"):format(K0 + n) end
    local found = env.FindAllOf("GothicCharacterState")
    list = records(base .. ".ops")
    check(type(found) == "table" and #found == 1 and #list == K0 + 1 and list[K0 + 1]:find("^" .. num(1) .. " = 12:00:00 repopulate FindAllOf GothicCharacterState +\n$") ~= nil,
        "FindAllOf through a module's environment: one operation, taken back when the search returned")
    env.FindFirstOf("GameTimeSubsystem")
    list = records(base .. ".ops")
    check(#list == K0 + 2 and list[K0 + 2]:find("^" .. num(2) .. " = 12:00:00 repopulate FindFirstOf GameTimeSubsystem +\n$") ~= nil, "FindFirstOf: the same")
    local okCall, errCall = pcall(env.FindAllOf, 5)
    list = records(base .. ".ops")
    check(not okCall and tostring(errCall):find("No overload found") ~= nil and #list == K0 + 3 and list[K0 + 3]:sub(10, 10) == "=",
        "a search that raises: the error reaches the module unchanged, the operation is taken back")
    ue.objects["/Script/G1R.Thing"] = ue:object("Class /Script/G1R.Thing")
    env.StaticFindObject("/Script/G1R.Thing")
    env.StaticFindObject("/Script/G1R.Thing")
    list = records(base .. ".ops")
    check(#list == K0 + 4 and list[K0 + 4]:find("^" .. num(4) .. " = 12:00:00 repopulate search by path /Script/G1R.Thing +\n$") ~= nil,
        "a search by path that was not answered before is an operation too; the second one, answered from the loader's cache, is not")
    H.stop(c)

    section("operations: the file cannot be written")
    root = H.mod("opsfail")
    H.sh("mkdir -p " .. H.q(root .. "/Scripts/diagnostics/" .. os.date("session-%Y%m%d-%H%M%S", os.time({ year = 2026, month = 10, day = 1, hour = 12, min = 0, sec = 0 })) .. ".ops"))
    c = H.start(root)       -- (a folder stands where the file should be)
    D = c.M.repopulate.diag
    check(c.ok and D.op("anything") == nil and select("#", D.done(1)) == 0, "op returns nil, done does nothing, the modules run on")
    report = H.read(c.diag.report(true))
    check(H.has(report, "operations: 0 announced - not recorded"), "the report says that operations are not recorded")
    check(H.find(H.lines(H.read(c.session) or ""), "[repopulate]") ~= nil, "the session log is written as usual")
    H.stop(c)

    section("operations: diagnostics off")
    root = H.mod("opsoff", { files = { ["Scripts/config.lua"] = H.config('Config.Diagnostics = { Level = "off" }') } })
    c = H.start(root)
    check(c.M.repopulate.diag == nil and #H.list(c.dir) == 1, "no handle, no operations file (the folder holds only its README.txt)")
    H.stop(c)

    section("reports: one per session, kept with its session log")
    root = H.mod("sessionreport", { files = { ["Scripts/config.lua"] = H.config("Config.Diagnostics = { SessionFiles = 2 }") } })
    local t0 = os.time({ year = 2026, month = 10, day = 1, hour = 12, min = 0, sec = 0 })
    local bases = {}
    for i = 1, 4 do
        c = H.start(root, { time = t0 + i * 3600 })
        bases[i] = os.date("session-%Y%m%d-%H%M%S", t0 + i * 3600)
        c.M.repopulate.diag.op("operation of run " .. i)
        H.seconds(c, 300)
        local own, latest = H.read(c.dir .. "/" .. bases[i] .. ".report.txt"), H.read(c.dir .. "/report-latest.txt")
        check(own ~= nil and own == latest and H.has(own, "minutes since load: 5.0"), "run " .. i .. ": every scheduled report is also written as the session's own report")
        H.stop(c)
    end
    local d = root .. "/Scripts/diagnostics/"
    check(H.exists(d .. bases[3] .. ".report.txt") and H.exists(d .. bases[3] .. ".ops") and H.exists(d .. bases[4] .. ".report.txt") and H.exists(d .. bases[4] .. ".ops"),
        "the reports and operations files of the sessions that are kept are there after the next start")
    check(H.has(H.read(d .. bases[3] .. ".report.txt"), "operations: " .. (START_SEARCHES + 1) .. " announced (" .. bases[3] .. ".ops)") and (H.read(d .. bases[3] .. ".ops") or ""):find("operation of run 3", 1, true) ~= nil,
        "the report of the session before the last one still tells of that session")
    local left = {}
    for _, f in ipairs(H.list(d)) do
        if f:find(bases[1], 1, true) or f:find(bases[2], 1, true) then left[#left + 1] = f end
    end
    check(#left == 0, "the session logs that were pruned took their reports and operations files with them (" .. table.concat(left, ", ") .. ")")
end

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------
H.sh("rm -rf " .. H.q(TMP) .. " && mkdir -p " .. H.q(TMP))
local before = table.concat(H.list(MOD .. "Scripts/diagnostics"), ",")
_G.KNOWN_GLOBALS = {}
for k in pairs(_G) do _G.KNOWN_GLOBALS[k] = true end
for _, k in ipairs({ "TEST", "G1R_LOADER_TEST", "print", "StaticFindObject", "FindFirstOf", "FindAllOf", "StaticConstructObject", "FName", "RegisterHook",
    "NotifyOnNewObject", "LoopInGameThreadWithDelay", "LoopAsync", "ExecuteWithDelay", "ExecuteInGameThread", "ExecuteAsync", "RegisterLoadMapPreHook",
    "RegisterLoadMapPostHook", "RegisterConsoleCommandHandler", "RegisterConsoleCommandGlobalHandler", "RegisterKeyBind" }) do
    _G.KNOWN_GLOBALS[k] = true
end

for _, name in ipairs({ "mock", "loader", "services", "sandbox", "wrappers", "files", "operations", "handle", "console", "real" }) do
    local ok, err = xpcall(tests[name], debug.traceback)
    -- a test that stopped half way may have left the mock in place
    if rawget(_G, "RegisterHook") ~= nil or rawget(_G, "TEST") ~= nil then
        io.write("     (cleaning up after '" .. name .. "')\n")
        for _, k in ipairs({ "TEST", "G1R_LOADER_TEST", "StaticFindObject", "FindFirstOf", "FindAllOf", "StaticConstructObject", "FName", "RegisterHook",
            "NotifyOnNewObject", "LoopInGameThreadWithDelay", "LoopAsync", "ExecuteWithDelay", "ExecuteInGameThread", "ExecuteAsync", "RegisterLoadMapPreHook",
            "RegisterLoadMapPostHook", "RegisterConsoleCommandHandler", "RegisterConsoleCommandGlobalHandler", "RegisterKeyBind" }) do
            rawset(_G, k, nil)
        end
    end
    if not ok then check(false, "test group '" .. name .. "' ran to its end: " .. tostring(err)) end
end

section("the mod itself")
local after = table.concat(H.list(MOD .. "Scripts/diagnostics"), ",")
check(after == before and after == "README.txt", "the mod's own Scripts/diagnostics/ holds only its README.txt (" .. after .. ")")

io.write(("loader tests finished: %d ok, %d failure(s)\n"):format(oks, fails))
os.exit(fails == 0 and 0 or 1)
