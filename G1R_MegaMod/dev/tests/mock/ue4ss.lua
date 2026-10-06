-- ============================================================================
-- A small mock of the UE4SS Lua globals for loader-level tests.
--
--   local Mock = dofile(".../dev/tests/mock/ue4ss.lua")
--   local ue = Mock.new()          -- options: { without = { "LoopAsync" }, anyHook = true, nilWhenMissing = true }
--   ue:install()                   -- sets the globals, print, os.clock / os.time / os.date
--   ... run the code under test ...
--   ue:tick()                      -- fires what was registered, the way UE4SS does
--   ue:uninstall()                 -- puts everything back
--
-- What the functions accept, what they return and what happens to a
-- callback's return value or error follows the UE4SS source (LuaMod.cpp):
--   LoopInGameThreadWithDelay(ms, f) -> handle; f(): return value ignored, an error is logged, the loop goes on
--   LoopAsync(ms, f): f() returning true ends the loop; so does an error
--   ExecuteWithDelay(ms, f), ExecuteAsync(f), ExecuteInGameThread(f [, method]): once, nothing returned
--   NotifyOnNewObject(path, f): f(object) returning true ends the notification
--   RegisterHook(path, pre [, post]) -> preId, postId; raises when the function does not exist;
--       pre(context, ...) / post(context, ...): one return value each is taken
--   RegisterLoadMapPreHook(f) / RegisterLoadMapPostHook(f): f(engine, world, url, pending, error) must return nil
--       or a boolean; an error in one callback skips the callbacks after it
--   RegisterConsoleCommandHandler(name, f) / ...GlobalHandler: f(fullCommand, parameters, device) must return a boolean
--   RegisterKeyBind(key, f) / (key, modifiers, f): f()
--   StaticFindObject(path) and FindFirstOf(class) return an object also when nothing is found (IsValid() == false);
--   FindAllOf(class) returns a list or nil
-- Errors UE4SS would write to its log are collected in ue.errors.
-- ============================================================================

local Mock = {}

local Object = {}
Object.__index = Object
function Object:IsValid() return self.__valid ~= false end
function Object:GetFullName() return self.__full end
function Object:GetAddress() return self.__address end

local FUNCTIONS = {
    "print", "StaticFindObject", "FindFirstOf", "FindAllOf", "StaticConstructObject", "FName",
    "RegisterHook", "NotifyOnNewObject", "LoopInGameThreadWithDelay", "LoopAsync", "ExecuteWithDelay",
    "ExecuteInGameThread", "ExecuteAsync", "RegisterLoadMapPreHook", "RegisterLoadMapPostHook",
    "RegisterConsoleCommandHandler", "RegisterConsoleCommandGlobalHandler", "RegisterKeyBind",
}

local function isInteger(v) return math.type(v) == "integer" end

function Mock.new(options)
    options = options or {}
    local ue = {
        options = options,
        printed = {},          -- one text per print call
        errors = {},           -- what UE4SS would log as an error
        calls = {},            -- name -> number of calls
        lookups = {},          -- paths given to StaticFindObject, in order
        objects = {},          -- path -> object (StaticFindObject)
        firstOf = {},          -- class -> object (FindFirstOf)
        allOf = {},            -- class -> list (FindAllOf)
        functions = {},        -- path -> true: RegisterHook accepts it
        cost = {},             -- name -> seconds the fake clock advances per call
        loops = {}, asyncLoops = {}, delayed = {}, hooks = {}, notifications = {},
        console = {}, globalConsole = {}, loadMapPre = {}, loadMapPost = {}, keys = {},
        device = { lines = {} },
        clock = 100.0,                                     -- os.clock()
        time = os.time({ year = 2026, month = 10, day = 1, hour = 12, min = 0, sec = 0 }),   -- os.time()
        nextAddress = 0, nextHandle = 0, nextId = 0,
        globals = {},
    }
    function ue.device:Log(text) self.lines[#self.lines + 1] = tostring(text) end

    local function called(name)
        ue.calls[name] = (ue.calls[name] or 0) + 1
        if ue.cost[name] then ue.clock = ue.clock + ue.cost[name] end
    end
    local function noOverload(name) error("\nNo overload found for function '" .. name .. "'.", 0) end

    function ue:object(fullName, fields)
        local o = fields or {}
        self.nextAddress = self.nextAddress + 1
        o.__full, o.__address = fullName, self.nextAddress
        return setmetatable(o, Object)
    end
    function ue:invalid() return setmetatable({ __valid = false, __full = "None", __address = 0 }, Object) end
    function ue:advance(seconds) self.clock, self.time = self.clock + seconds, self.time + seconds end

    local G = ue.globals
    G.print = function(...)
        local n = select("#", ...)
        local parts = {}
        for i = 1, n do parts[i] = tostring((select(i, ...))) end
        ue.printed[#ue.printed + 1] = table.concat(parts, "\t\t")
        if options.echo then io.write("    LOG ", ue.printed[#ue.printed]) end
    end
    G.FName = function(s) return { __s = s, ToString = function() return s end } end
    G.StaticConstructObject = function(class, outer)
        called("StaticConstructObject")
        return ue:object(tostring(class and class.__full or "Object") .. "_Instance")
    end
    G.StaticFindObject = function(...)
        called("StaticFindObject")
        if select("#", ...) == 0 then error("Function 'StaticFindObject' cannot be called with 0 parameters.", 0) end
        local path = ...
        if type(path) ~= "string" then
            path = select(3, ...)
            if type(path) ~= "string" then noOverload("StaticFindObject") end
        end
        ue.lookups[#ue.lookups + 1] = path
        local o = ue.objects[path]
        if o ~= nil then return o end
        if options.nilWhenMissing then return nil end
        return ue:invalid()
    end
    G.FindFirstOf = function(class)
        called("FindFirstOf")
        if type(class) ~= "string" then noOverload("FindFirstOf") end
        local o = ue.firstOf[class]
        if o ~= nil then return o end
        if options.nilWhenMissing then return nil end
        return ue:invalid()
    end
    G.FindAllOf = function(class)
        called("FindAllOf")
        if type(class) ~= "string" then noOverload("FindAllOf") end
        return ue.allOf[class]
    end
    G.RegisterHook = function(path, pre, post)
        called("RegisterHook")
        if type(path) ~= "string" or type(pre) ~= "function" then noOverload("RegisterHook") end
        if not (options.anyHook or ue.functions[path]) then
            error("Tried to register a hook with Lua function 'RegisterHook' but no UFunction with the specified name was found.\nFunction Name: " .. path, 0)
        end
        ue.nextId = ue.nextId + 2
        local list = ue.hooks[path] or {}
        ue.hooks[path] = list
        list[#list + 1] = { pre = pre, post = type(post) == "function" and post or nil, preId = ue.nextId - 1, postId = ue.nextId }
        return ue.nextId - 1, ue.nextId
    end
    G.NotifyOnNewObject = function(path, callback)
        called("NotifyOnNewObject")
        if type(path) ~= "string" or type(callback) ~= "function" then noOverload("NotifyOnNewObject") end
        if path:find(" ", 1, true) then error("Param #1 for NotifyOnNewObject cannot contain spaces; Param value: '" .. path .. "'", 0) end
        if not path:find(".", 1, true) then error("Param #1 for NotifyOnNewObject must contain at least two parts; Param value: '" .. path .. "'", 0) end
        local list = ue.notifications[path] or {}
        ue.notifications[path] = list
        list[#list + 1] = callback
    end
    G.LoopInGameThreadWithDelay = function(ms, callback)
        called("LoopInGameThreadWithDelay")
        if not isInteger(ms) or type(callback) ~= "function" then noOverload("LoopInGameThreadWithDelay") end
        ue.nextHandle = ue.nextHandle + 1
        ue.loops[#ue.loops + 1] = { ms = ms, callback = callback, handle = ue.nextHandle }
        return ue.nextHandle
    end
    G.LoopAsync = function(ms, callback)
        called("LoopAsync")
        if not isInteger(ms) or type(callback) ~= "function" then noOverload("LoopAsync") end
        ue.asyncLoops[#ue.asyncLoops + 1] = { ms = ms, callback = callback }
    end
    G.ExecuteWithDelay = function(ms, callback)
        called("ExecuteWithDelay")
        if not isInteger(ms) or type(callback) ~= "function" then noOverload("ExecuteWithDelay") end
        ue.delayed[#ue.delayed + 1] = { kind = "ExecuteWithDelay", ms = ms, callback = callback }
    end
    G.ExecuteAsync = function(callback)
        called("ExecuteAsync")
        if type(callback) ~= "function" then noOverload("ExecuteAsync") end
        ue.delayed[#ue.delayed + 1] = { kind = "ExecuteAsync", callback = callback }
    end
    G.ExecuteInGameThread = function(callback, method)
        called("ExecuteInGameThread")
        if type(callback) ~= "function" then noOverload("ExecuteInGameThread") end
        ue.delayed[#ue.delayed + 1] = { kind = "ExecuteInGameThread", callback = callback, method = method }
    end
    G.RegisterLoadMapPreHook = function(callback)
        called("RegisterLoadMapPreHook")
        if type(callback) ~= "function" then noOverload("RegisterLoadMapPreHook") end
        ue.loadMapPre[#ue.loadMapPre + 1] = callback
    end
    G.RegisterLoadMapPostHook = function(callback)
        called("RegisterLoadMapPostHook")
        if type(callback) ~= "function" then noOverload("RegisterLoadMapPostHook") end
        ue.loadMapPost[#ue.loadMapPost + 1] = callback
    end
    local function consoleRegistration(name, store)
        return function(command, callback)
            called(name)
            if type(command) ~= "string" or type(callback) ~= "function" then noOverload(name) end
            local list = store[command] or {}
            store[command] = list
            list[#list + 1] = callback
        end
    end
    G.RegisterConsoleCommandHandler = consoleRegistration("RegisterConsoleCommandHandler", ue.console)
    G.RegisterConsoleCommandGlobalHandler = consoleRegistration("RegisterConsoleCommandGlobalHandler", ue.globalConsole)
    G.RegisterKeyBind = function(key, a, b)
        called("RegisterKeyBind")
        local callback = type(a) == "function" and a or (type(a) == "table" and type(b) == "function" and b) or nil
        if not isInteger(key) or not callback then noOverload("RegisterKeyBind") end
        if key < 0 or key > 255 then error("Parameter #1 for function 'RegisterKeyBind' must be an integer between 0 and 255", 0) end
        ue.keys[#ue.keys + 1] = { key = key, modifiers = type(a) == "table" and a or nil, callback = callback }
    end
    for _, name in ipairs(options.without or {}) do G[name] = nil end

    -- ------------------------------------------------------------------ firing
    local function logged(what, ok, err)
        if not ok then ue.errors[#ue.errors + 1] = what .. ": " .. tostring(err) end
        return ok
    end

    -- Game-thread loops, each once. Returns how many ran.
    function ue:tick(times)
        local n = 0
        for _ = 1, times or 1 do
            for _, l in ipairs(self.loops) do
                logged("LoopInGameThreadWithDelay", pcall(l.callback))
                n = n + 1
            end
        end
        return n
    end
    function ue:tickAsync()
        local keep = {}
        for _, l in ipairs(self.asyncLoops) do
            local ok, result = pcall(l.callback)
            logged("LoopAsync", ok, result)
            if ok and result ~= true then keep[#keep + 1] = l end
        end
        self.asyncLoops = keep
        return #keep
    end
    function ue:runDelayed()
        local list = self.delayed
        self.delayed = {}
        for _, d in ipairs(list) do logged(d.kind, pcall(d.callback)) end
        return #list
    end
    -- Returns a list with one entry { pre = value, post = value } per registration.
    function ue:fireHook(path, ...)
        local out = {}
        for _, h in ipairs(self.hooks[path] or {}) do
            local entry = {}
            local ok, result = pcall(h.pre, ...)
            if logged("RegisterHook", ok, result) then entry.pre = result end
            if h.post then
                ok, result = pcall(h.post, ...)
                if logged("RegisterHook (post)", ok, result) then entry.post = result end
            end
            out[#out + 1] = entry
        end
        return out
    end
    function ue:fireNotify(path, object)
        local keep, n = {}, 0
        for _, callback in ipairs(self.notifications[path] or {}) do
            local ok, result = pcall(callback, object)
            logged("NotifyOnNewObject", ok, result)
            n = n + 1
            if not (ok and result == true) then keep[#keep + 1] = callback end
        end
        self.notifications[path] = keep
        return n
    end
    local function fireLoadMap(list, ...)
        local args = table.pack(...)
        local override
        local ok, err = pcall(function()
            for _, callback in ipairs(list) do
                local result = callback(table.unpack(args, 1, args.n))
                if result ~= nil then
                    if type(result) ~= "boolean" then error("A callback for 'LoadMap' must return bool or nil", 0) end
                    override = result
                end
            end
        end)
        logged("LoadMap", ok, err)
        return override
    end
    function ue:fireLoadMapPre(...) return fireLoadMap(self.loadMapPre, ...) end
    function ue:fireLoadMapPost(...) return fireLoadMap(self.loadMapPost, ...) end
    local function fireConsole(store, commandLine, device)
        local words = {}
        for w in commandLine:gmatch("%S+") do words[#words + 1] = w end
        local list = store[words[1] or ""]
        if not list then return nil end
        local parameters = {}
        for i = 2, #words do parameters[i - 1] = words[i] end
        local handled = false
        local ok, err = pcall(function()
            for _, callback in ipairs(list) do
                local result = callback(commandLine, parameters, device)
                if type(result) ~= "boolean" then error("A custom console command handle must return true or false", 0) end
                handled = result
            end
        end)
        if not logged("console", ok, err) then return false end
        return handled
    end
    -- nil when no handler has that name, otherwise what the handler returned (false after an error).
    function ue:fireConsole(commandLine) return fireConsole(self.console, commandLine, self.device) end
    function ue:fireGlobalConsole(commandLine) return fireConsole(self.globalConsole, commandLine, self.device) end
    function ue:fireKey(key)
        local n = 0
        for _, k in ipairs(self.keys) do
            if k.key == key then
                logged("RegisterKeyBind", pcall(k.callback))
                n = n + 1
            end
        end
        return n
    end

    -- --------------------------------------------------------- install / remove
    function ue:install(target)
        target = target or _G
        assert(not self.installed, "the mock is installed already")
        self.installed = { target = target, values = {}, clock = os.clock, time = os.time, date = os.date }
        for _, name in ipairs(FUNCTIONS) do
            self.installed.values[name] = rawget(target, name)
            rawset(target, name, G[name])
        end
        local realTime, realDate = os.time, os.date
        os.clock = function() return ue.clock end
        os.time = function(t)
            if t ~= nil then return realTime(t) end
            return math.floor(ue.time)
        end
        os.date = function(format, t)
            if t == nil then t = math.floor(ue.time) end
            return realDate(format, t)
        end
        return self
    end
    function ue:uninstall()
        local i = self.installed
        if not i then return end
        for _, name in ipairs(FUNCTIONS) do rawset(i.target, name, i.values[name]) end
        os.clock, os.time, os.date = i.clock, i.time, i.date
        self.installed = nil
    end

    return ue
end

return Mock
