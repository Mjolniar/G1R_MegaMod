-- ============================================================================
-- Offline tests of the module wait (modules/wait/Scripts/main.lua).
--
--   lua5.4 harness.lua          (from any directory)
--
-- The module runs on the loader's kit and settings service; ../lib/modtest.lua
-- sets both up the way the loader does and replaces UE4SS by ../mock/ue4ss.lua.
-- The game is the model below: the time subsystem with its clock and SkipTime,
-- the time library, the pause question, the hero's pawn with its mesh and its
-- animation values. Every modelled behaviour says where it is known from
-- (DISASM / SOURCE as in dev/facts/wait.md); nothing of it has been seen in the
-- game. The last section runs the module through the real loader with the real
-- diagnostics.
-- Last line: "wait tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("wait")
local check, section, has, printed, printedCount = T.check, T.section, T.has, T.printed, T.printedCount
local MOD = T.MOD

local DAY = 86400
local SPEED = 15                        -- game seconds per real second (SOURCE: as-src Environment/G1RGameTimeConfig.as)
local START = 4 * DAY + 14 * 3600       -- day 4, 14:00:00
local LOOK = 0.25 * SPEED               -- what the clock gains by itself between two looks: 3.75 game seconds
local SUBSYSTEM = "GameTimeSubsystem /Game/Maps/World.World:PersistentLevel.G1RGameState_0.GameTimeSubsystem_0"
local LIBRARY = "/Script/G1R.Default__FInGameTimeStatics"
local STATICS = "/Script/Engine.Default__GameplayStatics"

-- The game keeps the sum in single precision (DISASM: SkipTime, cvtpd2ps / cvtps2pd).
local function single(x) return (string.unpack("f", string.pack("f", x))) end

-- ---------------------------------------------------------------------------
-- The game model
-- ---------------------------------------------------------------------------
-- A struct value the game made itself (the real API hands out userdata for it).
local Made = {}

-- An object as UE4SS shows it. `props`: its properties (a value, or a function
-- that gives the value at each read); `fns`: its functions. A name that is
-- neither gives an EMPTY OBJECT, not nil (SOURCE: LuaUObject.cpp
-- handle_unreal_property_value); calling that raises.
local function gameObject(ue, w, fullName, props, fns)
    local o = ue:object(fullName, {})
    local base = getmetatable(o).__index
    return setmetatable(o, {
        __index = function(_, k)
            if base[k] ~= nil then return base[k] end
            if fns and fns[k] ~= nil then return fns[k] end
            local p = props and props[k]
            if p == nil then return w.empty end
            w.read[k] = (w.read[k] or 0) + 1
            if type(p) == "function" then return p() end
            return p
        end,
        __newindex = function(_, k, v)
            if props and props[k] ~= nil and type(props[k]) ~= "function" then props[k] = v else rawset(o, k, v) end
        end,
    })
end

-- o: start (clock at the beginning), skip, library, libraryGives, clockWrite, flags, noSubsystem, noController,
--    noMesh, noAnimation, noStatics, clockUnreadable, clockByFunction
-- Only skip = "ok", libraryGives = "table" and clockWrite = "ok" are what the executable and the UE4SS source
-- show; every other value is a way one of those assumptions can turn out wrong in the game.
--   skip         "ok"      SkipTime adds to the clock inside the call (DISASM 0x1459d2ec0)
--                "deaf"    a plain table as argument arrives as an empty value (zero): the conversion table ->
--                          struct does not work in such a build; a value the game made itself is understood
--                "late"    the clock moves at the game's next step
--                "dead"    the call goes through and the clock never moves
--                "raises"  the call raises
--                "missing" there is no such function
--   library      "ok" | "missing" | "raises";  libraryGives "table" (SOURCE: a struct return value arrives as a
--                Lua table) | "struct" (a value only the game understands) | "nothing" (nil)
--   clockWrite   "ok" (a struct property read points into the object: writing its field writes the clock) |
--                "copy" (the read hands out a copy: a write goes nowhere) | "raises"
local function newWorld(ue, o)
    o = o or {}
    local w = T.newWorld(ue, { noController = o.noController })
    w.o = o
    w.empty = ue:invalid()
    w.read = {}                 -- property name -> number of reads
    w.calls = { SkipTime = 0, FromSeconds = 0, IsGamePaused = 0 }
    w.writes = 0
    w.seconds = o.start or START
    w.frozen, w.paused = false, false
    w.pending = {}
    function w.reads()
        local n = 0
        for _, v in pairs(w.read) do n = n + v end
        return n
    end

    -- the clock: reading or writing TotalSeconds of the struct the property read hands out
    local function clockStruct()
        local store = (o.clockWrite == "copy") and { value = w.seconds } or nil
        return setmetatable({}, {
            __index = function(_, k)
                if k ~= "TotalSeconds" then return nil end
                w.read.TotalSeconds = (w.read.TotalSeconds or 0) + 1
                if w.diesAtRead == w.read.TotalSeconds then        -- the subsystem is destroyed right after this reading
                    w.subsystem.__valid = false
                    ue.firstOf["GameTimeSubsystem"] = nil
                end
                if o.clockUnreadable then return w.empty end
                if store then return store.value end
                return w.seconds
            end,
            __newindex = function(_, k, v)
                if k ~= "TotalSeconds" then error("no such field (test)", 0) end
                w.writes = w.writes + 1
                if o.clockWrite == "raises" then error("the property is read-only (test)", 0) end
                if store then store.value = v else w.seconds = v end
            end,
        })
    end
    local subsystemFns = {}
    if o.skip ~= "missing" then
        subsystemFns.SkipTime = function(_, ...)
            w.calls.SkipTime = w.calls.SkipTime + 1
            -- SOURCE: LuaUObject.cpp call_ufunction_from_lua counts the parameters
            if select("#", ...) ~= 1 then error("UFunction expected 1 parameters, received " .. select("#", ...), 0) end
            local duration = ...
            local seconds
            if type(duration) == "table" and getmetatable(duration) == Made then
                seconds = duration.value
            elseif type(duration) == "table" then
                -- SOURCE: convert_lua_table_to_struct takes the fields by name, a missing one stays zero
                seconds = duration.TotalSeconds
                if seconds == nil or o.skip == "deaf" then seconds = 0 end
                if type(seconds) ~= "number" then error("TotalSeconds is not a number (test)", 0) end
            elseif duration == nil then
                seconds = 0         -- SOURCE: push_structproperty leaves the (zeroed) parameter alone for nil
            else
                error("Parameter must be of type 'StructProperty' or table", 0)
            end
            w.asked = seconds
            if o.skip == "raises" then error("SkipTime failed (test)", 0) end
            if o.skip == "dead" then return end
            if o.skip == "late" then
                w.pending[#w.pending + 1] = seconds
                return
            end
            w.seconds = single(w.seconds + seconds)
        end
    end
    local subsystemProps = { CurrentGameTime = clockStruct, GameTimeSpeed = 15.0 }
    if o.clockByFunction then
        -- the clock cannot be read as a property, only through the game's function (the kit's third form)
        subsystemProps.CurrentGameTime = nil
        subsystemFns.GetCurrentGameTime = function() return { TotalSeconds = w.seconds } end
    end
    w.subsystem = gameObject(ue, w, SUBSYSTEM, subsystemProps, subsystemFns)
    if not o.noSubsystem then ue.firstOf["GameTimeSubsystem"] = w.subsystem end

    if o.library ~= "missing" then
        ue.objects[LIBRARY] = gameObject(ue, w, "FInGameTimeStatics " .. LIBRARY, {}, {
            FromSeconds = function(_, seconds)
                w.calls.FromSeconds = w.calls.FromSeconds + 1
                if o.library == "raises" then error("FromSeconds failed (test)", 0) end
                if o.libraryGives == "struct" then return setmetatable({ value = seconds }, Made) end
                if o.libraryGives == "nothing" then return nil end
                return { TotalSeconds = seconds }
            end,
        })
    end
    if not o.noStatics then
        ue.objects[STATICS] = gameObject(ue, w, "GameplayStatics " .. STATICS, {}, {
            IsGamePaused = function(_, world)       -- the engine's pause question, as the kit asks it (facts K6)
                w.calls.IsGamePaused = w.calls.IsGamePaused + 1
                return world == w.world and w.paused
            end,
        })
    end

    -- the hero's pawn -> Mesh -> AnimScriptInstance -> yes/no values (SOURCE: property layout)
    w.flags = { m_IsInCombat = false, bIsInConversation = false, bIsInCinematic = false }
    for k, v in pairs(o.flags or {}) do
        if v == "missing" then w.flags[k] = nil else w.flags[k] = v end
    end
    local flagProps = {}
    for _, k in ipairs({ "m_IsInCombat", "bIsInConversation", "bIsInCinematic" }) do
        if w.flags[k] ~= nil then flagProps[k] = function() return w.flags[k] end end
    end
    w.animation = gameObject(ue, w, "BipedLocomotionAnimInstance_C /Game/Maps/World.World:PersistentLevel.GothicCharacter_C_7.CharacterMesh0.Anim_0", flagProps)
    w.mesh = gameObject(ue, w, "SkeletalMeshComponent /Game/Maps/World.World:PersistentLevel.GothicCharacter_C_7.CharacterMesh0",
        { AnimScriptInstance = function() if o.noAnimation then return w.empty end return w.animation end })
    w.pawn = gameObject(ue, w, "GothicCharacter_C /Game/Maps/World.World:PersistentLevel.GothicCharacter_C_7",
        (not o.noMesh) and { Mesh = function() return w.mesh end } or {})
    rawset(w.controller, "Pawn", w.pawn)

    -- one step of the game: a quarter second. DISASM (tick 0x1459d4410): the clock gains DeltaTime x speed
    -- unless it is frozen; a paused game does not step.
    function w.step(dt)
        for _, s in ipairs(w.pending) do w.seconds = single(w.seconds + s) end
        w.pending = {}
        if not w.frozen and not w.paused then w.seconds = w.seconds + dt * SPEED end
    end
    return w
end

-- ---------------------------------------------------------------------------
-- Running the module
-- ---------------------------------------------------------------------------
local function start(case, options)
    options = options or {}
    options.module, options.hook = "wait", "WAIT_TEST"
    local worldOptions = options.world
    options.prepare = function(ue) return newWorld(ue, worldOptions) end
    local c = T.boot(case, options)
    c.S = c.hook and c.hook.state
    -- one look: the game steps a quarter second, then every loop runs
    function c.looks(n)
        for _ = 1, n or 1 do
            c.world.step(0.25)
            c.ue:advance(0.25)
            c.ue:tick()
        end
    end
    function c.t() return c.world.seconds end
    function c.gone() return c.world.seconds - (c.world.o.start or START) end       -- game seconds since the start
    return c
end
local stop = T.stop
local function allOf(ue) return ue.calls.FindAllOf or 0 end
local function firstOf(ue) return ue.calls.FindFirstOf or 0 end
local function status(c) return table.concat(c.hook.status(), "|") end
local function hhmm(t)
    local s = math.floor(t % DAY)
    return ("%02d:%02d"):format(s // 3600, s % 3600 // 60)
end
local function config(body) return T.config(body) end
local shipped = T.read(MOD .. "modules/wait/Scripts/config.lua")
local KEY_Y = config('Config.ShortKey = "Y"')

-- ---------------------------------------------------------------------------
section("1. loading with the shipped settings")
do
    local c = start("load")
    local ue, w = c.ue, c.world
    check(c.ok, "the module loads (" .. tostring(c.err) .. ")")
    check(#ue.printed == 1 and ue.printed[1] == "[G1R_Wait] v1.0.1 loaded: no key bound (buttons in the in-game menu; console: wait 30, wait until 8)\n",
        "one load line: " .. tostring(ue.printed[1]):gsub("\n", ""))
    check(#ue.loops == 2 and ue.loops[2].ms == 250 and math.type(ue.loops[2].ms) == "integer", "one game-thread loop of its own, every 250 ms")
    check(ue.console.wait ~= nil and ue.console.g1r_wait ~= nil and #ue.loadMapPre == 1 and #ue.loadMapPost == 1, "console commands wait and g1r_wait; the kit's hooks before and after a map load")
    check((ue.calls.RegisterKeyBind or 0) == 0 and (ue.calls.RegisterHook or 0) == 0, "no key is registered with UE4SS and nothing is hooked")
    check(#ue.lookups == 0 and allOf(ue) == 0 and firstOf(ue) == 0 and w.reads() == 0, "loading searches for nothing and reads nothing")
    local v = c.hook.settings.values
    check(v.Enabled == true and v.Cooldown == 2 and v.ShortKey == "" and v.ShortMinutes == 30 and v.LongKey == "" and v.LongMinutes == 240
        and v.MorningKey == "" and v.MorningHour == 8 and v.EveningKey == "" and v.EveningHour == 20, "the shipped file gives the documented defaults: no key, 30 minutes, 4 hours, 8 and 20 o'clock, 2 s cooldown")
    check(v.NotInFight == true and v.NotInConversation == true and v.NotInCutscene == true and v.NotWhenClockStopped == true
        and v.ShowMessage == true and v.ShowRefused == false and v.LogSkips == false, "every reason not to wait is on, the note after a skip is on, the note for a skip not taken and the log are off")
    c.looks(240)        -- a minute
    check(c.gone() == 240 * LOOK and w.calls.SkipTime == 0 and w.writes == 0 and #ue.errors == 0, "a minute of play: the clock runs at its own pace, nothing is skipped")
    check(#ue.lookups == 0 and allOf(ue) == 0 and firstOf(ue) == 0 and w.reads() == 0 and w.calls.IsGamePaused == 0,
        "with nothing asked the module does not look at the game at all: 0 searches, 0 reads, 0 calls")
    local lines = c.hook.status()
    check(#lines == 3 and lines[1] == "v1.0.1 | no key bound (buttons in the in-game menu; console: wait 30, wait until 8)"
        and lines[2] == "short wait: 30 minutes, no key | long wait: 4 hours, no key | wait until morning: until 08:00, no key | wait until evening: until 20:00, no key"
        and lines[3] == "skips: 0", "the status in three lines: " .. tostring(lines[2]))
    check(T.read(c.path) == shipped, "the settings file is left as it is")
    check(#ue.printed == 1, "and nothing more is logged")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("2. a skip by key: 30 minutes")
do
    local c = start("key", { config = KEY_Y, widgets = true, diag = true })
    local ue, w, S = c.ue, c.world, c.S
    check(printed(ue, "[G1R_Wait] v1.0.1 loaded: Y = 30 minutes\n") ~= nil, "the load line names the key and what it skips")
    check(ue.calls.RegisterKeyBind == 1 and ue.keys[1].key == 89 and ue.keys[1].modifiers == nil and #ue.loops == 3,
        "Y is registered with UE4SS once (code 89, no modifier); the kit's key loop runs besides the module's")
    c.looks(8)
    check(w.reads() == 0 and allOf(ue) == 0 and firstOf(ue) == 0 and #ue.lookups == 0, "a bound key alone does not make the module look at the game")
    check(c.press("Y") == 1 and w.calls.SkipTime == 0 and w.reads() == 0 and S.job == nil, "the press itself (on UE4SS's own thread) touches nothing")
    c.looks(1)
    check(S.job ~= nil and S.job.stage == "second" and w.calls.SkipTime == 0 and c.gone() == 9 * LOOK,
        "first look: the request is taken up, the clock is read, nothing is skipped yet")
    check(allOf(ue) == 1 and firstOf(ue) == 1 and #ue.lookups == 1 and ue.lookups[1] == STATICS and w.calls.IsGamePaused == 1,
        "it costs one search for the hero's controller, one for the clock and one by path for the pause question")
    c.looks(1)
    check(w.calls.SkipTime == 1 and w.asked == 1800 and c.gone() == 10 * LOOK + 1800, "second look, a quarter second later: SkipTime is called once with 1800 seconds; the clock is 30 minutes further")
    check(S.job == nil and S.skips == 1 and S.works == "table" and w.calls.FromSeconds == 0 and w.writes == 0,
        "the plain value did it: the time library is not asked, the clock is not written")
    check(c.ui.note() == "30 minutes later - 14:30", "the note: " .. tostring(c.ui.note()))
    check(printed(ue, "[G1R_Wait] skipped 30 minutes, day 4 14:00 -> day 4 14:30, by SkipTime with a plain value (seen at once)\n") ~= nil,
        "the first skip of a run is logged: what, from when to when, how")
    check(c.fake.value("wait.key_press") == "seen" and c.fake.value("wait.clock") == "found" and c.fake.value("wait.states") == "readable"
        and c.fake.value("wait.clock_running") == "yes" and c.fake.value("wait.way") == "table" and c.fake.value("wait.applied") == "at once"
        and c.fake.value("wait.moved") == "as asked", "the diagnostics note: a key press arrived, the clock, the hero's state, the way that worked")
    check(#c.fake.crumbs == 1 and c.fake.crumbs[1] == "first call: SkipTime with a plain value" and c.fake.events[1] == "first call returned: no error",
        "the first call of SkipTime in a run is announced on disk before it is made, and its return is recorded")
    check(#c.fake.events == 2 and c.fake.events[2] == "first skip: 30 minutes, day 4 14:00 -> day 4 14:30, by SkipTime with a plain value (seen at once)", "and the first skip as an event")
    -- what a request reads: pawn -> Mesh, AnimScriptInstance, three values - at the first look and once more right
    -- before the call; the clock three times
    check(w.read.Mesh == 2 and w.read.AnimScriptInstance == 2 and w.read.m_IsInCombat == 2 and w.read.bIsInConversation == 2 and w.read.bIsInCinematic == 2,
        "the hero's state costs five property reads, asked twice per request: at the first look and right before the call")
    check(w.read.CurrentGameTime == 3 and w.read.TotalSeconds == 3 and w.reads() == 16, "the clock is read three times: first look, second look (the value the skip starts from), after the call (16 reads in all)")
    local searches = #ue.lookups
    c.looks(40)
    check(w.calls.SkipTime == 1 and w.reads() == 16 and #ue.lookups == searches and allOf(ue) == 1 and firstOf(ue) == 1 and #ue.errors == 0,
        "afterwards the module is idle again: nothing read, nothing searched, no error")
    check(c.gone() == 50 * LOOK + 1800, "and the clock runs on at its own pace from where the skip put it")
    -- the second skip of the run
    c.press("Y")
    c.looks(2)
    check(w.calls.SkipTime == 2 and c.gone() == 52 * LOOK + 3600 and S.skips == 2 and c.ui.note() == "30 minutes later - 15:03", "a second press skips again: " .. tostring(c.ui.note()))
    check(allOf(ue) == 1 and firstOf(ue) == 1 and #ue.lookups == searches and w.reads() == 32, "without any new search (16 reads again)")
    check(printedCount(ue, "skipped 30 minutes") == 1 and #c.fake.events == 2 and #c.fake.crumbs == 1, "later skips are not logged (LogSkips is off), not announced and no event")
    check(c.fake.count["wait.way"] == 1 and c.fake.count["wait.key_press"] == 1 and c.fake.count["wait.clock_running"] == 1, "a note is made once, not at every skip")
    local lines = c.hook.status()
    check(#lines == 3 and lines[1] == "v1.0.1 | Y = 30 minutes" and has(lines[2], "short wait: 30 minutes, key Y | long wait: 4 hours, no key")
        and lines[3] == "skips: 2; last: 30 minutes, day 4 14:33 -> day 4 15:03, by SkipTime with a plain value (seen at once)", "the status names the key and the last skip: " .. tostring(lines[3]))
    check(w.value("Health") == 80 and w.value("Mana") == 10 and w.value("Experience") == 6702, "nothing of the hero is touched")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("3. the four waits and what they skip")
do
    local FOUR = config('Config.ShortKey = "Y"\nConfig.LongKey = "F6"\nConfig.MorningKey = "F7"\nConfig.EveningKey = "CTRL+F8"\nConfig.Cooldown = 0')
    local c = start("long", { config = FOUR, widgets = true })
    local ue, w = c.ue, c.world
    check(printed(ue, "loaded: Y = 30 minutes, F6 = 4 hours, F7 = until 08:00, CTRL+F8 = until 20:00\n") ~= nil, "four keys: the load line lists them in order")
    check(ue.calls.RegisterKeyBind == 4 and ue.keys[4].key == 119 and ue.keys[4].modifiers[1] == 17 and #ue.keys[4].modifiers == 1,
        "four registrations; CTRL+F8 as key 119 with the modifier CTRL (17)")
    local labels = {}
    for _, k in ipairs(c.kit.keyList()) do labels[#labels + 1] = k.key .. " = " .. k.label end
    check(table.concat(labels, "; ") == "Y = wait 30 minutes; F6 = wait 240 minutes; F7 = wait until 8:00; CTRL+F8 = wait until 20:00",
        "for the list of keys (module keys) each key says what it does: " .. table.concat(labels, "; "))
    c.press("F6")
    c.looks(2)
    check(w.asked == 14400 and c.gone() == 2 * LOOK + 14400 and c.ui.note() == "4 hours later - 18:00", "the long wait: 240 minutes -> " .. tostring(c.ui.note()))
    stop(c)

    c = start("morning", { config = FOUR, widgets = true })
    w = c.world
    c.press("F7")
    c.looks(2)
    -- at 14:00:07.5 the next 08:00 is 17:59:52.5 away; the module aims one second past the hour
    check(w.asked == 64793.5 and c.t() == 5 * DAY + 8 * 3600 + 1, "until morning from 14:00:07: 64793.5 seconds, the clock stands at 08:00:01 of the next day")
    check(c.ui.note() == "18 hours later - 08:00", "the note rounds to minutes: " .. tostring(c.ui.note()))
    c.looks(4)
    c.press("F7")
    c.looks(2)
    check(c.t() == 6 * DAY + 8 * 3600 + 1 and hhmm(c.t()) == "08:00" and c.ui.note() == "24 hours later - 08:00",
        "pressed again a moment after eight: the next eight o'clock is tomorrow's (" .. tostring(c.ui.note()) .. ")")
    stop(c)

    c = start("evening", { config = FOUR, widgets = true })
    w = c.world
    c.press("CTRL+F8")
    c.looks(2)
    check(w.asked == 21593.5 and c.t() == 4 * DAY + 20 * 3600 + 1 and c.ui.note() == "6 hours later - 20:00", "until evening, the same day: " .. tostring(c.ui.note()))
    check(c.press("F8") == 0, "(the key without CTRL is not bound)")
    stop(c)

    -- "until 8" asked just before 08:00. Whether the hour is today's or tomorrow's is decided at the first look
    -- (here a quarter second = 3.75 game seconds after the press, unless said otherwise); the skip is made a look
    -- later. (Found in review: the aim used to be worked out at the second look - a press up to 8 game seconds
    -- before the hour skipped a whole day.)
    local EIGHT = 4 * DAY + 8 * 3600
    c = start("before-10", { config = FOUR, world = { start = EIGHT - 10 }, widgets = true })
    c.press("F7")
    c.looks(1)
    check(c.S.job ~= nil and c.S.job.stage == "second" and c.S.job.target == EIGHT + 1 and c.t() == EIGHT - 6.25,
        "pressed 10 s before 08:00: at the first look (6.25 s before the hour) the aim is fixed - today's 08:00:01")
    c.looks(1)
    check(c.world.asked == 3.5 and c.t() == EIGHT + 1 and c.S.skips == 1 and c.ui.note() == "less than a minute later - 08:00",
        "a look later what is left is skipped: 3.5 seconds, the clock stands at 08:00:01 (" .. tostring(c.ui.note()) .. ")")
    stop(c)
    c = start("before-6", { config = FOUR, world = { start = EIGHT - 6 }, widgets = true })
    c.press("F7")
    c.looks(1)
    check(c.S.job ~= nil and c.S.job.target == EIGHT + 1 and c.t() == EIGHT - 2.25, "pressed 6 s before 08:00: at the first look (2.25 s before the hour) the aim is today's 08:00:01")
    c.looks(1)
    check(c.S.job == nil and c.S.skips == 0 and c.S.refused == 1 and c.S.lastRefusal == "the clock has reached that hour by itself meanwhile"
        and c.world.calls.SkipTime == 0 and c.world.writes == 0 and c.t() == EIGHT + 1.5 and c.ui.note() == nil,
        "at the second look the clock is past the aim by itself: the request ends, nothing is skipped - not a day")
    check(printedCount(c.ue, "[G1R_Wait] no time skipped: the clock has reached that hour by itself meanwhile\n") == 1, "the log says why")
    c.looks(8)
    check(c.gone() == 10 * LOOK and c.world.calls.SkipTime == 0, "and nothing follows: the clock runs at its own pace")
    stop(c)
    -- 3 s before the hour, and the module's loop takes the press up at once (its look comes 1/16 s after the press)
    c = start("before-3", { config = FOUR, world = { start = EIGHT - 3 }, widgets = true })
    c.press("F7")
    c.world.step(0.0625)
    c.ue:advance(0.0625)
    c.ue:tick()
    check(c.S.job ~= nil and c.S.job.stage == "second" and c.S.job.target == EIGHT + 1 and c.t() == EIGHT - 2.0625,
        "pressed 3 s before 08:00 and taken up at once (first look 2.06 s before the hour): the aim is today's 08:00:01")
    c.looks(1)
    check(c.S.job == nil and c.S.skips == 0 and c.S.refused == 1 and c.world.calls.SkipTime == 0 and c.t() == EIGHT + 1.6875, "the hour passes before the skip: nothing is skipped - not a day")
    stop(c)
    -- the limit of that rule: the module is not told when a key was pressed, it learns of the press when its loop
    -- runs. A press the loop takes up only after the hour is a wait until tomorrow (README: "decided at the first look")
    c = start("before-3-late", { config = FOUR, world = { start = EIGHT - 3 }, widgets = true })
    c.press("F7")
    c.looks(1)
    check(c.S.job ~= nil and c.S.job.target == EIGHT + DAY + 1 and c.t() == EIGHT + 0.75,
        "pressed 3 s before 08:00 but taken up a quarter second later (first look 0.75 s AFTER the hour): the aim is tomorrow's 08:00:01")
    c.looks(1)
    check(c.world.asked == DAY - 3.5 and c.t() == EIGHT + DAY + 1 and c.ui.note() == "24 hours later - 08:00", "(and that is skipped: " .. tostring(c.ui.note()) .. ")")
    stop(c)

    -- Mostly the module does learn of a press before the hour is past: the kit hands a press on within 50 ms,
    -- the module's own look comes up to a quarter second later. Then the first reading stands past the hour by
    -- less than the clock gained since the request, which shows a look later, when the clock's pace is known:
    -- the hour was still ahead when the key was pressed, so nothing is left to skip.
    local function pumped(name, startAt, options)
        local cc = start(name, { config = (options and options.config) or FOUR, world = { start = startAt }, widgets = true })
        if options and options.frozen then cc.world.frozen = true end
        cc.press("F7")
        cc.world.step(0.05)
        cc.ue:advance(0.05)
        cc.kit._test.pumpKeys()     -- the kit's 50 ms pump hands the press on; the module's own loop is not due yet
        return cc
    end
    -- the rest of the quarter second, then the module's look (and every other loop)
    local function lookAfterPump(cc)
        cc.world.step(0.2)
        cc.ue:advance(0.2)
        cc.ue:tick()
    end
    c = pumped("before-3-pump", EIGHT - 3)
    check(c.S.job ~= nil and c.S.job.stage == "first" and c.t() == EIGHT - 2.25, "pressed 3 s before 08:00, handed on by the kit 50 ms later: the request waits for the module's look")
    lookAfterPump(c)
    check(c.S.job ~= nil and c.S.job.stage == "second" and c.S.job.target == EIGHT + DAY + 1 and c.t() == EIGHT + 0.75,
        "the first look comes 0.75 s after the hour: by that reading alone the hour would be tomorrow's")
    c.looks(1)
    check(c.S.job == nil and c.S.skips == 0 and c.S.refused == 1 and c.S.lastRefusal == "the clock has reached that hour by itself meanwhile"
        and c.world.calls.SkipTime == 0 and c.world.writes == 0 and c.ui.note() == nil,
        "a look later the pace is known (15): the clock gained 3 s since the request and stood only 0.75 s past the hour - reached, nothing is skipped")
    stop(c)
    c = pumped("after-1-pump", EIGHT + 1)
    lookAfterPump(c)
    c.looks(1)
    check(c.S.skips == 1 and c.t() == EIGHT + DAY + 1 and c.ui.note() == "24 hours later - 08:00",
        "pressed 1 s after 08:00 (the first look stands 4.75 s past the hour, the clock gained 3 s since the request): the hour had passed, so it is tomorrow's - " .. tostring(c.ui.note()))
    stop(c)
    -- on both sides of the line, 0.15 game seconds (a hundredth of a second) from it: what counts is where the
    -- clock stood when the request was made
    c = pumped("just-before-pump", EIGHT - 0.9)
    lookAfterPump(c)
    check(math.abs(c.t() - (EIGHT + 2.85)) < 1e-6, "(the request is made 0.15 s before the hour; the first look stands 2.85 s past it)")
    c.looks(1)
    check(c.S.job == nil and c.S.skips == 0 and c.S.refused == 1 and c.world.calls.SkipTime == 0, "the hour was still ahead at the request: reached, nothing is skipped")
    stop(c)
    c = pumped("just-after-pump", EIGHT - 0.6)
    lookAfterPump(c)
    check(math.abs(c.t() - (EIGHT + 3.15)) < 1e-6, "(the request is made 0.15 s after the hour; the first look stands 3.15 s past it)")
    c.looks(1)
    check(c.S.skips == 1 and c.S.refused == 0 and c.t() == EIGHT + DAY + 1, "the hour had passed at the request: tomorrow's hour, a day is skipped")
    stop(c)
    -- a clock that stands still has no pace: nothing counts as reached - not even a clock standing on the hour itself
    c = pumped("stand-pump", EIGHT, { config = config('Config.MorningKey = "F7"\nConfig.NotWhenClockStopped = false\nConfig.Cooldown = 0'), frozen = true })
    lookAfterPump(c)
    check(c.t() == EIGHT and c.S.job ~= nil and c.S.job.target == EIGHT + DAY + 1, "a clock standing on 08:00:00 (NotWhenClockStopped off): the aim is tomorrow's 08:00:01")
    c.looks(1)
    check(c.S.skips == 1 and c.S.refused == 0 and c.t() == EIGHT + DAY + 1, "the request is not taken for reached: the wait until tomorrow is made")
    stop(c)

    -- the amount of an "until": pure arithmetic, by hand
    c = start("until", {})
    local remaining = c.hook.remaining
    check(remaining({ minutes = 30 }, START) == 1800 and remaining({ minutes = 1 }, 5) == 60 and remaining({ minutes = 1440 }, START) == DAY,
        "minutes are minutes x 60, wherever the clock stands")
    check(remaining({ hour = 8 }, 4 * DAY + 7 * 3600) == 3601, "until 8 at 07:00:00: 3600 seconds and one past the hour")
    check(remaining({ hour = 8 }, 4 * DAY + 8 * 3600) == DAY + 1, "until 8 at 08:00:00 sharp: a whole day")
    check(remaining({ hour = 8 }, 4 * DAY + 8 * 3600 - 1) == 2, "until 8 one second before: 2 seconds")
    check(remaining({ hour = 8 }, 4 * DAY + 8 * 3600 + 0.5) == DAY + 0.5, "until 8 half a second after: tomorrow")
    check(remaining({ hour = 0 }, 4 * DAY + 23 * 3600) == 3601 and remaining({ hour = 23 }, 4 * DAY) == 23 * 3600 + 1 and remaining({ hour = 0 }, 0) == DAY + 1,
        "hour 0 is midnight, hour 23 is 23:00")
    local job = { hour = 20 }
    local first = remaining(job, START)
    check(first == 6 * 3600 + 1 and job.target == 4 * DAY + 20 * 3600 + 1 and remaining(job, START + 10) == first - 10,
        "the moment aimed at is fixed when it is first worked out: ten seconds later it is ten seconds nearer")
    -- far into a game the clock is kept to 2 seconds: aim further past the hour
    local late = 300 * DAY + 7 * 3600
    local amount = remaining({ hour = 8 }, late)
    check(math.abs(amount - (3600 + (300 * DAY + 8 * 3600) / 16777216)) < 1e-6 and amount > 3601.5, "on day 300 the aim is 1.55 seconds past the hour (" .. amount .. ")")
    check(single(late + amount) >= 300 * DAY + 8 * 3600 and single(late + amount) - (300 * DAY + 8 * 3600) <= 4,
        "so that the rounding of the game's SkipTime lands at or after the hour: " .. single(late + amount) - 300 * DAY)
    -- texts
    local span, clockText, dayText = c.hook.span, c.hook.clockText, c.hook.dayText
    check(span(1800) == "30 minutes" and span(60) == "1 minute" and span(3600) == "1 hour" and span(5400) == "1 hour 30 minutes"
        and span(7260) == "2 hours 1 minute" and span(DAY) == "24 hours" and span(7200) == "2 hours", "spans: minutes, hours, both, singular and plural")
    check(span(29) == "less than a minute" and span(30) == "1 minute" and span(89) == "1 minute" and span(90) == "2 minutes" and span(3570) == "1 hour"
        and span(3569) == "59 minutes" and span(0) == "less than a minute", "a span is rounded to the nearest minute; below half a minute it is 'less than a minute'")
    check(clockText(0) == "00:00" and clockText(52200) == "14:30" and clockText(DAY - 1) == "23:59" and clockText(4 * DAY + 3661) == "01:01"
        and clockText(59.9) == "00:00" and clockText(3599.99) == "00:59", "the clock as hours and minutes, cut off like a clock, not rounded")
    check(dayText(START) == "day 4 14:00" and dayText(0) == "day 0 00:00" and dayText(DAY - 0.5) == "day 0 23:59" and dayText(11 * DAY + 7 * 3600 + 5 * 60) == "day 11 07:05",
        "with the day counted from the start of the game (day 0), as the rest of the mod writes it")
    stop(c)

    -- the three ways all land at or after the hour, also from a crooked clock
    for _, case in ipairs({
        { "plain value", {}, 4 * DAY + 3 * 3600 + 1234.5678 },
        { "plain value, day 300", {}, 300 * DAY + 3 * 3600 + 1234.5678 },
        { "time library", { skip = "deaf", libraryGives = "struct" }, 4 * DAY + 3 * 3600 + 1234.5678 },
        { "written clock", { skip = "dead" }, 4 * DAY + 3 * 3600 + 1234.5678 },
        { "written clock, day 300", { skip = "dead" }, 300 * DAY + 3 * 3600 + 1234.5678 },
    }) do
        local options = case[2]
        options.start = case[3]
        local d = start("land", { config = FOUR, world = options, widgets = true })
        d.press("F7")
        d.looks(6)
        local day = math.floor(case[3] / DAY)
        check(d.S.skips == 1 and d.t() >= day * DAY + 8 * 3600 and d.t() < day * DAY + 8 * 3600 + 30 and has(d.ui.note() or "", " - 08:00"),
            "until 08:00 by the " .. case[1] .. ": the clock stands at " .. hhmm(d.t()) .. ", " .. ("%.2f"):format(d.t() - day * DAY - 8 * 3600) .. " s past the hour")
        stop(d)
    end
end

-- ---------------------------------------------------------------------------
section("4. one press, one skip: cooldown, held keys, two waits at once")
do
    local c = start("cooldown", { config = KEY_Y, widgets = true })
    local ue, w, S = c.ue, c.world, c.S
    c.press("Y")
    c.looks(2)
    check(w.calls.SkipTime == 1, "the first press skips")
    c.looks(6)          -- 1.5 s after the skip
    c.press("Y")
    c.looks(1)          -- 1.75 s
    check(S.job == nil and S.refused == 1 and printed(ue, "[G1R_Wait] no time skipped: the last skip was a moment ago\n") ~= nil,
        "a press 1.75 seconds after a skip is not taken (cooldown 2 s): said in the log")
    local reads = w.reads()
    c.looks(2)
    check(w.calls.SkipTime == 1 and w.reads() == reads, "nothing is skipped and the game is not looked at for it")
    check(c.ui.note() == "30 minutes later - 14:30", "the note of the skip stays up: a press too soon is not shown on screen")
    stop(c)

    c = start("cooldown-edge", { config = KEY_Y })
    w, S = c.world, c.S
    c.press("Y")
    c.looks(2)
    c.looks(7)          -- 1.75 s after the skip
    c.press("Y")
    c.looks(1)          -- the press is taken up 2.0 s after the skip
    check(S.job ~= nil and S.refused == 0, "a press exactly 2.0 seconds after the skip is taken")
    c.looks(1)
    check(w.calls.SkipTime == 2 and c.gone() == 11 * LOOK + 3600, "and skips")
    stop(c)

    -- the key held down: UE4SS reports it again and again
    c = start("held", { config = KEY_Y })
    ue, w, S = c.ue, c.world, c.S
    for _ = 1, 40 do
        c.press("Y")
        c.looks(1)
    end
    check(w.calls.SkipTime == 4 and c.gone() == 40 * LOOK + 4 * 1800, "Y held for ten seconds: four skips (one every 2.5 s), never two for one moment")
    check(printedCount(ue, "no time skipped: the last skip was a moment ago") == 1 and S.refused == 16, "the presses in between are counted; the reason is logged once in ten seconds, not sixteen times")
    stop(c)

    c = start("no-cooldown", { config = config('Config.ShortKey = "Y"\nConfig.Cooldown = 0') })
    w, S = c.world, c.S
    for _ = 1, 8 do
        c.press("Y")
        c.looks(1)
    end
    check(w.calls.SkipTime == 4 and S.refused == 0 and c.gone() == 8 * LOOK + 4 * 1800, "cooldown 0 and the key held: a skip every half second (a request takes two looks), none refused")
    stop(c)

    -- two waits on one key
    c = start("same-key", { config = config('Config.ShortKey = "Y"\nConfig.LongKey = "Y"\nConfig.MorningKey = "F7"') })
    ue, w, S = c.ue, c.world, c.S
    check(printedCount(ue, "[G1R_Wait] the short wait and the long wait have the same key Y: a press takes the short wait\n") == 1, "two waits with the same key: said at the start")
    check(ue.calls.RegisterKeyBind == 2, "(the key is registered with UE4SS once)")
    c.press("Y")
    c.looks(2)
    check(w.calls.SkipTime == 1 and w.asked == 1800 and c.gone() == 2 * LOOK + 1800 and S.refused == 1, "one press, one skip: the short wait; the long one is not taken")
    check(printed(ue, "no time skipped: another skip is still under way") ~= nil, "(the log says why)")
    c.looks(10)
    c.press("Y")
    c.press("F7")
    c.looks(2)
    check(w.calls.SkipTime == 2 and S.skips == 2 and S.refused == 3 and S.job == nil, "two different keys in the same moment: one of the waits is taken, one skip (the other two are not)")
    -- a second key while the first request is between its two looks
    c.looks(10)
    c.press("Y")
    c.looks(1)
    c.press("F7")
    c.looks(1)
    check(w.calls.SkipTime == 3 and w.asked == 1800 and S.job == nil, "a key pressed while a request is under way is not taken; the request goes on")
    c.looks(4)
    check(w.calls.SkipTime == 3 and #ue.errors == 0, "and nothing follows later")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("5. where no time is skipped: what the hero is doing")
do
    local function refused(case, worldOptions, body, reason, prepare)
        local c = start(case, { config = config('Config.ShortKey = "Y"' .. (body or "")), world = worldOptions, widgets = true, diag = true })
        if prepare then prepare(c) end
        c.press("Y")
        c.looks(4)
        local ok = c.world.calls.SkipTime == 0 and c.world.writes == 0 and c.gone() == 4 * LOOK and c.S.job == nil and c.S.skips == 0 and c.S.refused == 1
            and printedCount(c.ue, "[G1R_Wait] no time skipped: " .. reason .. "\n") == 1 and #c.ue.errors == 0 and c.ui.note() == nil
        return ok, c
    end
    local ok, c = refused("fight", { flags = { m_IsInCombat = true } }, nil, "the hero has a weapon drawn")
    check(ok, "a weapon drawn: nothing is skipped, the reason is in the log, nothing on screen")
    check(c.S.job == nil and has(status(c), "|not skipped: 1 time; last reason: the hero has a weapon drawn"), "the status counts it")
    check(c.world.read.CurrentGameTime == 1, "(the clock was read once: the request ended at its first look)")
    c.world.flags.m_IsInCombat = false
    c.press("Y")
    c.looks(2)
    check(c.world.calls.SkipTime == 1 and c.ui.note() == "30 minutes later - 14:30", "weapon put away: the next press skips")
    stop(c)

    -- between the looks the hero can draw a weapon or begin a talk: the states are asked again right before every
    -- call that moves the clock
    c = start("fight-between", { config = config('Config.ShortKey = "Y"'), widgets = true, diag = true })
    c.press("Y")
    c.looks(1)
    check(c.S.job ~= nil and c.S.job.stage == "second", "(first look done, the hero at peace)")
    c.world.flags.m_IsInCombat = true
    c.looks(3)
    check(c.world.calls.SkipTime == 0 and c.world.writes == 0 and c.S.job == nil and c.S.skips == 0 and c.S.refused == 1
        and printedCount(c.ue, "[G1R_Wait] no time skipped: the hero has a weapon drawn\n") == 1,
        "a weapon drawn after the first look: the second look skips nothing")
    stop(c)
    c = start("talk-before-fallback", { config = config('Config.ShortKey = "Y"'), world = { skip = "deaf", libraryGives = "struct" }, widgets = true, diag = true })
    c.press("Y")
    c.looks(2)
    check(c.world.calls.SkipTime == 1 and c.S.job ~= nil and c.S.job.stage == "check", "(the first way was called and did nothing)")
    c.world.flags.bIsInConversation = true
    c.looks(2)
    check(c.world.calls.SkipTime == 1 and c.world.calls.FromSeconds == 0 and c.S.job == nil and c.S.skips == 0 and c.S.refused == 1
        and printedCount(c.ue, "[G1R_Wait] no time skipped: the hero is in a conversation\n") == 1,
        "a conversation begun before the next way is tried: it is not tried")
    stop(c)

    ok, c = refused("talk", { flags = { bIsInConversation = true } }, nil, "the hero is in a conversation")
    check(ok, "in a conversation: nothing is skipped")
    stop(c)
    ok, c = refused("cutscene", { flags = { bIsInCinematic = true } }, nil, "a cutscene is playing")
    check(ok, "in a cutscene: nothing is skipped")
    stop(c)
    ok, c = refused("two", { flags = { bIsInConversation = true, bIsInCinematic = true } }, nil, "the hero is in a conversation")
    check(ok and c.S.flags.talk == true and c.S.flags.cutscene == true and c.S.flags.fight == false, "talking in a cutscene: one reason is given, all three values are kept for the diagnostics")
    stop(c)

    -- each switch
    for _, case in ipairs({
        { "NotInFight", "m_IsInCombat", "a weapon drawn" },
        { "NotInConversation", "bIsInConversation", "a conversation" },
        { "NotInCutscene", "bIsInCinematic", "a cutscene" },
    }) do
        local d = start("switch", { config = config('Config.ShortKey = "Y"\nConfig.' .. case[1] .. " = false"), world = { flags = { [case[2]] = true } } })
        d.press("Y")
        d.looks(2)
        check(d.world.calls.SkipTime == 1 and d.S.refused == 0 and d.world.read[case[2]] == nil and d.world.reads() == 14,
            case[1] .. " = false: " .. case[3] .. " does not stop the skip, and that value is not even read (14 reads: the others asked twice)")
        stop(d)
    end
    c = start("no-switch", { config = config('Config.ShortKey = "Y"\nConfig.NotInFight = false\nConfig.NotInConversation = false\nConfig.NotInCutscene = false'),
        world = { flags = { m_IsInCombat = true, bIsInConversation = true, bIsInCinematic = true } }, diag = true })
    c.press("Y")
    c.looks(2)
    check(c.world.calls.SkipTime == 1 and c.world.read.Mesh == nil and c.world.read.AnimScriptInstance == nil and c.world.reads() == 6,
        "all three off: the hero's animation is not looked at (6 reads: the clock three times)")
    check(c.fake.value("wait.states") == nil, "and nothing is noted about it")
    stop(c)

    -- the game is paused
    ok, c = refused("paused", nil, nil, "the game is paused", function(d) d.world.paused = true end)
    check(c.world.calls.SkipTime == 0 and c.gone() == 0 and c.S.refused == 1 and printedCount(c.ue, "no time skipped: the game is paused") == 1, "the game paused: nothing is skipped")
    check(c.world.read.CurrentGameTime == nil and c.world.calls.IsGamePaused == 1, "(asked once, before anything is read)")
    c.world.paused = false
    c.press("Y")
    c.looks(2)
    check(c.world.calls.SkipTime == 1, "no longer paused: the next press skips")
    stop(c)
    c = start("pause-unknown", { config = KEY_Y, world = { noStatics = true } })
    c.world.paused = true
    c.press("Y")
    c.looks(3)
    check(c.S.refused == 1 and c.world.calls.SkipTime == 0 and printed(c.ue, "the game's clock is standing still") ~= nil and #c.ue.lookups == 1,
        "a game where the pause question cannot be asked: a paused game is still noticed, by its clock standing still (one search by path, not repeated)")
    stop(c)
    -- paused, or the hero gone, between the first look and the skip: asked again right before the call (the rule
    -- for a standing clock is off here, so that only this question can stop it)
    c = start("pause-between", { config = config('Config.ShortKey = "Y"\nConfig.NotWhenClockStopped = false') })
    c.press("Y")
    c.looks(1)
    c.world.paused = true
    c.looks(3)
    check(c.S.refused == 1 and c.world.calls.SkipTime == 0 and c.S.job == nil and printedCount(c.ue, "no time skipped: the game is paused") == 1,
        "paused after the first look: nothing is skipped")
    stop(c)
    c = start("hero-gone-between", { config = KEY_Y })
    c.press("Y")
    c.looks(1)
    c.world.pawn.__valid = false
    c.looks(3)
    check(c.S.refused == 1 and c.world.calls.SkipTime == 0 and c.S.job == nil and printedCount(c.ue, "no time skipped: the hero was not found") == 1,
        "the hero gone after the first look: nothing is skipped")
    stop(c)

    -- no hero
    c = start("no-controller", { config = KEY_Y, world = { noController = true }, diag = true })
    for _ = 1, 3 do
        c.press("Y")
        c.looks(2)
    end
    check(c.S.refused == 3 and c.world.calls.SkipTime == 0 and printedCount(c.ue, "[G1R_Wait] no time skipped: the hero was not found (no game loaded?)\n") == 1,
        "no player controller (a menu): three presses, nothing skipped, one line")
    check(allOf(c.ue) == 2 and firstOf(c.ue) == 0 and c.world.reads() == 0, "the controller is searched for once in three seconds (both class names), not at every press; the clock is not looked for")
    stop(c)
    c = start("no-pawn", { config = KEY_Y })
    rawset(c.world.controller, "Pawn", nil)
    rawset(c.world.controller, "K2_GetPawn", function() return c.world.empty end)
    c.press("Y")
    c.looks(2)
    check(c.S.refused == 1 and c.world.calls.SkipTime == 0 and printed(c.ue, "the hero was not found") ~= nil and #c.ue.errors == 0, "a controller without a pawn: nothing skipped")
    stop(c)

    -- the hero's state cannot be read: the switches have no effect, and that is said
    for _, case in ipairs({
        { "no-mesh", { noMesh = true }, "the hero's animation" },
        { "no-animation", { noAnimation = true }, "the hero's animation" },
        { "no-flag", { flags = { m_IsInCombat = "missing" } }, "m_IsInCombat" },
        { "no-flags", { flags = { m_IsInCombat = "missing", bIsInConversation = "missing", bIsInCinematic = "missing" } }, "m_IsInCombat, bIsInConversation, bIsInCinematic" },
    }) do
        local d = start(case[1], { config = config('Config.ShortKey = "Y"\nConfig.Cooldown = 0'), world = case[2], diag = true })
        d.press("Y")
        d.looks(2)
        d.press("Y")
        d.looks(2)
        check(d.world.calls.SkipTime == 2 and d.S.refused == 0 and #d.ue.errors == 0, case[1] .. ": the skips are taken all the same")
        check(printedCount(d.ue, "[G1R_Wait] what the hero is doing could not be read (" .. case[3] .. "): the switches under \"When not to wait\" that need it have no effect\n") == 1
            and d.fake.value("wait.states") == "not readable" and d.fake.detail("wait.states") == case[3] and d.fake.count["wait.states"] == 1,
            case[1] .. ": said once in the log and noted (" .. case[3] .. ")")
        stop(d)
    end
    c = start("one-flag-left", { config = KEY_Y, world = { flags = { m_IsInCombat = "missing", bIsInConversation = true } } })
    c.press("Y")
    c.looks(2)
    check(c.S.refused == 1 and c.world.calls.SkipTime == 0 and printed(c.ue, "no time skipped: the hero is in a conversation") ~= nil,
        "one value missing, another says no: the one that can be read still counts")
    stop(c)
    -- a value that is not yes/no is not taken for a yes
    c = start("odd-flag", { config = KEY_Y, world = { flags = { m_IsInCombat = 1, bIsInConversation = "yes" } }, diag = true })
    c.press("Y")
    c.looks(2)
    check(c.world.calls.SkipTime == 1 and c.fake.detail("wait.states") == "m_IsInCombat, bIsInConversation", "a number or a text where yes/no belongs is 'not readable', never a reason")
    stop(c)

    -- no clock
    c = start("no-clock", { config = KEY_Y, world = { noSubsystem = true }, diag = true })
    for _ = 1, 3 do
        c.press("Y")
        c.looks(2)
    end
    check(c.S.refused == 3 and printedCount(c.ue, "[G1R_Wait] no time skipped: the game's clock was not found\n") == 1 and c.fake.value("wait.clock") == "not found" and c.fake.count["wait.clock"] == 1,
        "no time subsystem: nothing skipped, one line, one note")
    check(firstOf(c.ue) == 1 and c.world.read.Mesh == nil, "it is searched for once in three seconds, not at every press; the hero's state is not read")
    stop(c)
    c = start("clock-unreadable", { config = KEY_Y, world = { clockUnreadable = true } })
    c.press("Y")
    c.looks(2)
    check(c.S.refused == 1 and c.world.calls.SkipTime == 0 and printed(c.ue, "the game's clock was not found") ~= nil and #c.ue.errors == 0, "a clock whose value is not a number: nothing skipped, no error")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("6. the clock between the two looks: standing still, jumping")
do
    -- DISASM: a cutscene freezes the game's clock (FreezeTime) and puts the time of day back when it ends;
    -- SkipTime itself does not ask whether the clock is frozen.
    local c = start("frozen", { config = KEY_Y, widgets = true, diag = true })
    local ue, w, S = c.ue, c.world, c.S
    w.frozen = true
    c.press("Y")
    c.looks(1)
    check(S.job ~= nil and S.job.stage == "second" and w.calls.SkipTime == 0, "a frozen clock: the first look finds nothing wrong")
    c.looks(1)
    check(S.job == nil and w.calls.SkipTime == 0 and c.gone() == 0 and S.refused == 1
        and printedCount(ue, "[G1R_Wait] no time skipped: the game's clock is standing still (a cutscene or a menu)\n") == 1,
        "the second look sees that the clock has not moved: nothing is skipped")
    check(c.fake.value("wait.clock_running") == "standing still" and c.ui.note() == nil, "noted for the diagnostics; nothing on screen")
    w.frozen = false
    c.press("Y")
    c.looks(2)
    check(w.calls.SkipTime == 1 and c.fake.value("wait.clock_running") == "yes" and table.concat(c.fake.values("wait.clock_running"), ",") == "standing still,yes",
        "the clock runs again: the next press skips, and the note changes")
    stop(c)

    c = start("frozen-allowed", { config = config('Config.ShortKey = "Y"\nConfig.NotWhenClockStopped = false'), widgets = true, diag = true })
    w = c.world
    w.frozen = true
    c.press("Y")
    c.looks(2)
    check(w.calls.SkipTime == 1 and c.gone() == 1800 and c.ui.note() == "30 minutes later - 14:30" and c.fake.value("wait.clock_running") == "standing still",
        "NotWhenClockStopped = false: the skip is taken although the clock stands still (and that is still noted)")
    stop(c)

    c = start("slow", { config = KEY_Y })
    w = c.world
    c.press("Y")
    c.looks(1)
    w.frozen = true
    w.seconds = w.seconds + 0.375       -- slow motion: a tenth of the usual pace
    c.looks(1)
    check(w.calls.SkipTime == 1 and c.S.refused == 0, "a clock that gained a third of a second between the looks is running: the skip is taken")
    stop(c)

    c = start("went-back", { config = KEY_Y })
    w = c.world
    c.press("Y")
    c.looks(1)
    w.seconds = w.seconds - 500         -- an earlier save was loaded without a map change
    c.looks(1)
    check(w.calls.SkipTime == 0 and c.S.refused == 1 and printed(c.ue, "the game's clock is standing still") ~= nil, "a clock that went back between the looks is not a running clock either")
    stop(c)

    -- somebody else skips time on the same press (the hero goes to bed; another mod with the same key)
    c = start("jumped", { config = KEY_Y, widgets = true, diag = true })
    ue, w, S = c.ue, c.world, c.S
    c.press("Y")
    c.looks(1)
    w.seconds = w.seconds + 1800
    c.looks(1)
    check(w.calls.SkipTime == 0 and c.gone() == 2 * LOOK + 1800 and S.job == nil and S.refused == 1, "the clock jumps 30 minutes between the two looks: this module adds nothing - one press, one skip")
    check(printedCount(ue, "[G1R_Wait] no time skipped: the clock has just jumped on its own (sleeping, or another mod that skips time)\n") == 1
        and c.fake.value("wait.clock_running") == "jumped" and c.fake.detail("wait.clock_running") == "1804 game seconds in 0.25 s", "said in the log and noted with the numbers")
    stop(c)
    -- where a jump begins: more than 60 game seconds plus 60 per real second between the looks
    local function between(extra, gapLooks)
        local d = start("jump-edge", { config = KEY_Y })
        d.press("Y")
        d.looks(1)
        d.world.seconds = d.world.seconds + extra
        d.looks(gapLooks or 1)
        local skipped, refusedCount = d.world.calls.SkipTime, d.S.refused
        stop(d)
        return skipped, refusedCount
    end
    local skipped, refusedCount = between(75 - LOOK)
    check(skipped == 1 and refusedCount == 0, "75 game seconds in a quarter second is still the clock's own doing (a fast clock): the skip is taken")
    skipped, refusedCount = between(75.2 - LOOK)
    check(skipped == 0 and refusedCount == 1, "75.2 are a jump")

    -- the two readings must be apart in time: a loop that runs early waits for its next turn
    c = start("gap", { config = KEY_Y })
    w, S = c.world, c.S
    c.press("Y")
    c.looks(1)
    w.step(0.0625)
    c.ue:advance(0.0625)
    c.ue:tick()
    check(S.job ~= nil and S.job.stage == "second" and w.calls.SkipTime == 0, "a look 0.06 s after the first reading does not read again")
    w.step(0.0625)
    c.ue:advance(0.0625)
    c.ue:tick()
    check(S.job == nil and w.calls.SkipTime == 1, "0.125 s after it the clock is read and the skip made")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("7. the ways of moving the clock, and the check that it moved")
do
    -- a build whose SkipTime does not understand a plain table
    local c = start("deaf", { config = config('Config.ShortKey = "Y"\nConfig.Cooldown = 0'), world = { skip = "deaf", libraryGives = "struct" }, widgets = true, diag = true })
    local ue, w, S = c.ue, c.world, c.S
    c.press("Y")
    c.looks(2)
    check(w.calls.SkipTime == 1 and w.asked == 0 and c.gone() == 2 * LOOK and S.job ~= nil and S.job.stage == "check" and S.skips == 0,
        "SkipTime with a plain value is called and the clock stays: nothing else is called at once")
    check(w.calls.FromSeconds == 0 and #ue.lookups == 1 and c.ui.note() == nil, "the time library is not touched yet, nothing is shown")
    c.looks(1)
    check(w.calls.SkipTime == 2 and w.calls.FromSeconds == 1 and w.asked == 1800 and c.gone() == 3 * LOOK + 1800 and S.job == nil and S.skips == 1,
        "a look later the clock has still not moved: the second way (a value from the game's time library) is tried and moves it")
    check(ue.lookups[2] == LIBRARY and #ue.lookups == 8, "one search by path for the library (and six for the note)")
    check(printedCount(ue, "[G1R_Wait] SkipTime with a plain value does not move the game's clock (the clock stayed where it was)\n") == 1, "the way that did nothing is named in the log, once")
    check(printed(ue, "skipped 30 minutes, day 4 14:00 -> day 4 14:30, by SkipTime with a value from the game's time library (seen at once)") ~= nil
        and c.ui.note() == "30 minutes later - 14:30", "log line and note name what happened")
    check(S.works == "library" and S.failed.table == "the clock stayed where it was" and c.fake.value("wait.way") == "library" and c.fake.value("wait.time_library") == "found",
        "remembered: the library way works, the plain value does not")
    c.press("Y")
    c.looks(2)
    check(w.calls.SkipTime == 3 and w.calls.FromSeconds == 2 and c.gone() == 5 * LOOK + 3600 and #ue.lookups == 8,
        "the next skip goes the working way at once: one call, no new search, the dead way is not tried again")
    check(has(status(c), "|SkipTime with a plain value does not work here: the clock stayed where it was"), "the status says which way does not work")
    stop(c)

    -- neither form of SkipTime: the clock itself is written
    c = start("write", { config = KEY_Y, world = { skip = "deaf" }, widgets = true, diag = true })
    ue, w, S = c.ue, c.world, c.S
    c.press("Y")
    c.looks(3)
    check(w.calls.SkipTime == 2 and w.writes == 0 and S.job ~= nil, "the library gives a plain table too (as the UE4SS source says): the second way does nothing either")
    c.looks(1)
    check(w.writes == 1 and c.gone() == 4 * LOOK + 1800 and S.skips == 1 and S.works == "clock" and c.fake.value("wait.way") == "clock",
        "third way: the clock is written, once, 1800 seconds on from where it stood")
    check(printed(ue, "skipped 30 minutes, day 4 14:00 -> day 4 14:30, by writing the clock (seen at once)") ~= nil
        and printedCount(ue, "does not move the game's clock") == 2, "both dead ways are named, the skip is logged")
    stop(c)
    c = start("write-wrapped", { config = KEY_Y, world = { skip = "dead" } })
    -- the form the kit calls "property (wrapped)": the property read gives a holder with :get()
    local struct = c.world.subsystem.CurrentGameTime
    getmetatable(c.world.subsystem).__index = (function(old)
        return function(t, k)
            if k == "CurrentGameTime" then return { get = function() return struct end } end
            return old(t, k)
        end
    end)(getmetatable(c.world.subsystem).__index)
    c.press("Y")
    c.looks(4)
    check(c.world.writes == 1 and c.gone() == 4 * LOOK + 1800 and c.S.works == "clock", "a clock value that comes wrapped is unwrapped before it is written")
    stop(c)

    -- no SkipTime at all, no library
    c = start("missing", { config = KEY_Y, world = { skip = "missing", library = "missing" }, diag = true })
    ue, w, S = c.ue, c.world, c.S
    c.press("Y")
    c.looks(4)
    check(S.skips == 1 and S.works == "clock" and c.gone() == 4 * LOOK + 1800 and #ue.errors == 0, "a game without SkipTime and without the library: the written clock does it, no error out")
    check(has(S.failed.table, "attempt to call") and S.failed.library == "the game's time library was not found" and c.fake.value("wait.time_library") == "not found",
        "why each way failed is kept: the call raised; the library was not found")
    check(table.concat(c.fake.crumbs, "|") == "first call: SkipTime with a plain value|first call: SkipTime with a value from the game's time library|first call: writing the clock"
        and has(c.fake.events[1], "first call returned: ") and has(c.fake.events[1], "attempt to call") and c.fake.events[2] == "first call returned: the game's time library was not found"
        and c.fake.events[3] == "first call returned: no error" and #c.fake.events == 4, "each way is announced before its first call, and what came back is recorded")
    local searches = 0
    for _, p in ipairs(ue.lookups) do if p == LIBRARY then searches = searches + 1 end end
    c.looks(8)
    c.press("Y")
    c.looks(2)
    check(searches == 1 and S.skips == 2 and #ue.lookups == 4 and ue.lookups[2] == LIBRARY, "the library is searched for once in the run, found or not")
    stop(c)
    c = start("raises", { config = KEY_Y, world = { skip = "raises", library = "raises" } })
    c.press("Y")
    c.looks(4)
    check(c.S.skips == 1 and c.S.works == "clock" and c.S.failed.table == "SkipTime failed (test)" and c.S.failed.library == "FromSeconds: FromSeconds failed (test)" and #c.ue.errors == 0,
        "calls that raise: caught, the reasons kept, the third way works")
    stop(c)

    c = start("library-nothing", { config = KEY_Y, world = { skip = "deaf", libraryGives = "nothing" } })
    c.press("Y")
    c.looks(4)
    check(c.S.skips == 1 and c.S.works == "clock" and c.world.calls.FromSeconds == 1 and c.world.calls.SkipTime == 2 and c.S.failed.library == "the clock stayed where it was"
        and c.gone() == 4 * LOOK + 1800 and #c.ue.errors == 0, "a library that hands back nothing: SkipTime gets an empty value and does nothing; the written clock does it")
    stop(c)

    -- nothing works
    c = start("broken", { config = KEY_Y, world = { skip = "dead", clockWrite = "copy" }, widgets = true, diag = true })
    ue, w, S = c.ue, c.world, c.S
    c.press("Y")
    c.looks(4)
    check(S.job ~= nil and not S.broken and w.calls.SkipTime == 2 and w.writes == 1, "three ways tried in four looks, each once")
    c.looks(1)
    check(S.broken == true and S.job == nil and S.skips == 0 and c.gone() == 5 * LOOK, "none moved the clock: the module gives up for this run; the clock is where the game has it")
    check(printedCount(ue, "[G1R_Wait] skipping time does not work in this game: none of the 3 ways moved the clock. No more skips are tried until the game is started again.\n") == 1
        and printedCount(ue, "does not move the game's clock") == 3, "said once, with each way named before it")
    check(c.fake.value("wait.way") == "none" and c.fake.detail("wait.way") == "table: the clock stayed where it was; library: the clock stayed where it was; clock: the clock stayed where it was",
        "noted for the diagnostics with the reason of every way")
    local reads, calls = w.reads(), w.calls.SkipTime
    c.looks(8)
    c.press("Y")
    c.looks(3)
    c.ue:fireConsole("wait 30")
    c.looks(3)
    check(w.reads() == reads and w.calls.SkipTime == calls and w.writes == 1 and S.refused == 3 and printedCount(ue, "no time skipped: skipping time does not work in this game (see earlier in this log)") == 1,
        "later presses and console words are not taken and the game is not looked at any more")
    check(has(status(c), "v1.0.1 | skipping time does not work in this game|") and has(status(c), "|writing the clock does not work here: the clock stayed where it was"), "the status says so")
    stop(c)
    c = start("broken-write", { config = KEY_Y, world = { skip = "missing", library = "missing", clockWrite = "raises" } })
    c.press("Y")
    c.looks(5)
    check(c.S.broken == true and c.S.failed.clock == "the property is read-only (test)" and #c.ue.errors == 0, "a clock that cannot be written: the error is the reason, nothing gets out")
    stop(c)

    -- a game that applies the skip a moment later
    c = start("late", { config = config('Config.ShortKey = "Y"\nConfig.Cooldown = 0'), world = { skip = "late" }, widgets = true, diag = true })
    ue, w, S = c.ue, c.world, c.S
    c.press("Y")
    c.looks(2)
    check(w.calls.SkipTime == 1 and c.gone() == 2 * LOOK and S.job ~= nil and S.skips == 0, "the call is made and the clock has not moved yet: the module waits a look")
    c.looks(1)
    check(w.calls.SkipTime == 1 and w.calls.FromSeconds == 0 and w.writes == 0 and c.gone() == 3 * LOOK + 1800 and S.skips == 1 and S.works == "table",
        "a look later the clock is 30 minutes on: the way works, no second way was called - one press, one skip")
    check(c.fake.value("wait.applied") == "a moment later" and c.fake.value("wait.moved") == nil and c.ui.note() == "30 minutes later - 14:30"
        and printed(ue, "by SkipTime with a plain value (seen a moment later)") ~= nil, "noted as applied a moment later; note and log as usual")
    c.press("Y")
    c.looks(3)
    check(w.calls.SkipTime == 2 and c.gone() == 6 * LOOK + 3600 and S.skips == 2 and next(S.failed) == nil, "and so every time; no way is marked as failed")
    stop(c)
    -- a late skip must be worth at least half the amount and 30 game seconds, counted beyond what the clock gains
    -- by itself in the real time since the call (its pace is taken from the two readings of the request)
    c = start("late-short", { config = KEY_Y, world = { skip = "dead", clockWrite = "copy" } })
    w = c.world
    c.press("Y")
    c.looks(2)
    w.seconds = w.seconds + 899
    c.looks(1)
    check(c.S.failed.table ~= nil and c.S.skips == 0, "899 of 1800 seconds beyond the clock's own pace a look later: not this module's skip")
    stop(c)
    c = start("late-half", { config = KEY_Y, world = { skip = "dead", clockWrite = "copy" } })
    w = c.world
    c.press("Y")
    c.looks(2)
    w.seconds = w.seconds + 900
    c.looks(1)
    check(c.S.skips == 1 and c.S.works == "table", "900 of 1800: taken as this module's skip")
    stop(c)
    c = start("late-small", { config = KEY_Y, world = { skip = "dead", clockWrite = "copy" } })
    w = c.world
    c.hook.request({ minutes = 1 }, "console")
    c.looks(2)
    w.seconds = w.seconds + 29.5
    c.looks(1)
    check(c.S.failed.table ~= nil and c.S.skips == 0, "of a one-minute skip, 29.5 seconds beyond the clock's own pace a look later are not enough")
    stop(c)
    c = start("late-small2", { config = KEY_Y, world = { skip = "dead", clockWrite = "copy" } })
    w = c.world
    c.hook.request({ minutes = 1 }, "console")
    c.looks(2)
    w.seconds = w.seconds + 30
    c.looks(1)
    check(c.S.skips == 1, "30 are")
    stop(c)
    -- the game stalls for three seconds between the call and the look after it: the clock gains 45 game seconds by
    -- itself. (Found in review: with a way that does nothing that was taken for a one-minute skip that came late.)
    c = start("stall-dead", { config = KEY_Y, world = { skip = "dead", clockWrite = "copy" } })
    w = c.world
    c.hook.request({ minutes = 1 }, "console")
    c.looks(2)
    w.step(3)
    c.ue:advance(3)
    c.ue:tick()
    check(c.gone() == 2 * LOOK + 45 and c.S.skips == 0 and c.S.failed.table == "the clock stayed where it was" and c.S.works == nil,
        "a way that does nothing and a stall of 3 s before the next look: the 45 seconds are the clock's own - no skip is counted, the way is marked")
    stop(c)
    c = start("stall-late", { config = KEY_Y, world = { skip = "late" } })
    w = c.world
    c.hook.request({ minutes = 1 }, "console")
    c.looks(2)
    w.step(3)
    c.ue:advance(3)
    c.ue:tick()
    check(c.gone() == 2 * LOOK + 45 + 60 and c.S.skips == 1 and c.S.works == "table" and next(c.S.failed) == nil,
        "a skip that really comes late, with the same stall: 60 seconds beyond the clock's own 45 - counted, the way works")
    stop(c)
    -- a clock that stands still gains nothing by itself: what shows a look later is all the skip's
    c = start("late-frozen", { config = config('Config.ShortKey = "Y"\nConfig.NotWhenClockStopped = false'), world = { skip = "dead", clockWrite = "copy" } })
    w = c.world
    w.frozen = true
    c.hook.request({ minutes = 1 }, "console")
    c.looks(2)
    w.seconds = w.seconds + 30
    c.looks(1)
    check(c.gone() == 30 and c.S.skips == 1 and c.S.works == "table", "the clock stands still (and that is allowed): 30 seconds a look later are a one-minute skip that came late")
    stop(c)
    -- a clock that went back between the two readings has no pace of its own either (never a negative one)
    c = start("late-went-back", { config = config('Config.ShortKey = "Y"\nConfig.NotWhenClockStopped = false'), world = { skip = "dead", clockWrite = "copy" } })
    w = c.world
    c.hook.request({ minutes = 1 }, "console")
    c.looks(1)
    w.seconds = w.seconds - 500
    c.looks(2)
    check(c.S.job ~= nil and c.S.job.pace == 0 and c.S.skips == 0 and c.S.failed.table == "the clock stayed where it was",
        "the clock went back 500 s between the looks (and that is allowed): a way that does nothing is not taken for a skip a look later")
    stop(c)

    -- at once: at least half the amount
    c = start("half", { config = KEY_Y, world = { skip = "missing", library = "missing", clockWrite = "copy" }, diag = true })
    w = c.world
    getmetatable(w.subsystem).__index = (function(old)
        return function(t, k)
            if k == "SkipTime" then return function(_, d) w.calls.SkipTime = w.calls.SkipTime + 1 w.seconds = w.seconds + d.TotalSeconds * w.share end end
            return old(t, k)
        end
    end)(getmetatable(w.subsystem).__index)
    w.share = 0.5
    c.press("Y")
    c.looks(2)
    check(c.S.skips == 1 and c.S.job == nil and c.fake.value("wait.applied") == "at once", "a clock that moved by half of what was asked counts as moved")
    check(c.fake.value("wait.moved") == "differs" and c.fake.detail("wait.moved") == "asked 1800 s, moved 900 s"
        and printedCount(c.ue, "[G1R_Wait] the clock moved by 900 seconds where 1800 were asked for\n") == 1, "but it is noted and said that the amount differs")
    w.share = 0.4999
    c.looks(8)
    c.press("Y")
    c.looks(2)
    check(c.S.skips == 1 and c.S.job ~= nil and c.S.job.stage == "check", "less than half does not")
    stop(c)
    -- "as asked": within what single precision can be off
    for _, case in ipairs({ { 2, "as asked" }, { -2, "as asked" }, { 2.5, "differs" }, { -2.5, "differs" } }) do
        local d = start("exact", { config = KEY_Y, world = { skip = "missing", library = "missing", clockWrite = "copy" }, diag = true })
        local dw = d.world
        getmetatable(dw.subsystem).__index = (function(old)
            return function(t, k)
                if k == "SkipTime" then return function(_, dur) dw.seconds = dw.seconds + dur.TotalSeconds + case[1] end end
                return old(t, k)
            end
        end)(getmetatable(dw.subsystem).__index)
        d.press("Y")
        d.looks(2)
        check(d.fake.value("wait.moved") == case[2], ("a skip that lands %+.1f s off is noted as '%s'"):format(case[1], case[2]))
        stop(d)
    end
    c = start("exact-late-day", { config = KEY_Y, world = { start = 400 * DAY + 0.3 }, diag = true })
    c.press("Y")
    c.looks(2)
    check(c.S.skips == 1 and c.fake.value("wait.moved") == "as asked" and math.abs(c.gone() - 2 * LOOK - 1800) <= 2,
        "on day 400 the game's own rounding moves the clock by up to 2 s (" .. (c.gone() - 2 * LOOK - 1800) .. " here): still 'as asked'")
    stop(c)

    -- a way that worked stops working
    c = start("stops", { config = config('Config.ShortKey = "Y"\nConfig.Cooldown = 0'), diag = true })
    w, S = c.world, c.S
    c.press("Y")
    c.looks(2)
    check(S.works == "table" and S.skips == 1, "the plain value works")
    w.o.skip = "dead"
    c.press("Y")
    c.looks(5)
    check(S.works == "clock" and S.skips == 2 and S.failed.table ~= nil and S.failed.library ~= nil and c.gone() == 7 * LOOK + 3600 and table.concat(c.fake.values("wait.way"), ",") == "table,clock",
        "then SkipTime goes dead: the other ways are tried in turn, the clock moves once, the note changes")
    stop(c)

    -- "until 8" while the first way does nothing and the clock passes the moment aimed at by itself before the
    -- next way is tried. (Found in review: what was left to skip came out negative - the clock was put back,
    -- every way was blamed for it and the module gave up for the run.)
    -- `ahead`: game seconds to 08:00 at the second look. The aim is one second past the hour and a look adds
    -- 3.75 s, so what is left at the retry is ahead - 2.75.
    local HOUR8 = 4 * DAY + 8 * 3600
    for _, case in ipairs({ { ahead = 1, left = -1.75 }, { ahead = 2.75, left = 0 } }) do
        c = start("until-passed", { config = config('Config.MorningKey = "F7"\nConfig.ShortKey = "Y"\nConfig.Cooldown = 0\nConfig.ShowRefused = true'),
            world = { skip = "deaf", libraryGives = "struct", start = HOUR8 - case.ahead - 2 * LOOK }, widgets = true })
        ue, w, S = c.ue, c.world, c.S
        c.press("F7")
        c.looks(2)
        check(w.calls.SkipTime == 1 and S.job ~= nil and S.job.stage == "check" and S.job.target == HOUR8 + 1 and c.t() == HOUR8 - case.ahead,
            ("until 8 asked %s s before the hour, the plain value does nothing: the request waits a look (aim: 08:00:01)"):format(case.ahead))
        local back = false
        for _ = 1, 4 do
            local was = c.t()
            c.looks(1)
            if c.t() < was + LOOK then back = true end
        end
        check(S.job == nil and not S.broken and S.refused == 1 and S.lastRefusal == "the clock has reached that hour by itself meanwhile" and S.skips == 0,
            ("a look later the clock is %s s past the aim by itself: the request ends, nothing is given up"):format(-case.left))
        check(w.calls.SkipTime == 1 and w.calls.FromSeconds == 0 and w.writes == 0 and w.asked == 0 and not back and c.t() == HOUR8 - case.ahead + 4 * LOOK,
            "no way is called with an amount of zero or less: the clock is never put back and runs at its own pace")
        check(S.failed.table ~= nil and S.failed.library == nil and S.failed.clock == nil and printedCount(ue, "does not move the game's clock") == 1,
            "only the way that really did nothing is marked; the ways that were not tried are not blamed")
        check(printedCount(ue, "[G1R_Wait] no time skipped: the clock has reached that hour by itself meanwhile\n") == 1
            and c.ui.note() == "Cannot wait now: the clock has reached that hour by itself meanwhile", "said in the log, and on screen with ShowRefused")
        c.press("Y")
        c.looks(2)
        check(S.skips == 1 and S.works == "library" and w.asked == 1800 and c.t() == HOUR8 - case.ahead + 6 * LOOK + 1800, "the next wait goes the second way at once and works")
        stop(c)
    end
    c = start("until-nearly", { config = config('Config.MorningKey = "F7"'), world = { skip = "deaf", libraryGives = "struct", start = HOUR8 - 3.25 - 2 * LOOK } })
    c.press("F7")
    c.looks(3)
    check(c.S.skips == 1 and c.S.works == "library" and c.world.asked == 0.5 and c.t() == HOUR8 + 1 and c.S.refused == 0,
        "half a second short of the aim at the retry: the second way skips that half second (the clock stands at 08:00:01)")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("8. objects that go away, errors")
do
    local c = start("replaced", { config = config('Config.ShortKey = "Y"\nConfig.Cooldown = 0'), diag = true })
    local ue, w, S = c.ue, c.world, c.S
    c.press("Y")
    c.looks(2)
    -- the subsystem is destroyed and another object gets its address (FACTS U5): the wrapper looks alive again
    local old = w.subsystem
    old.__full = "StaticMeshActor /Game/Maps/World.World:PersistentLevel.StaticMeshActor_12"
    local calls = w.calls.SkipTime
    ue.firstOf["GameTimeSubsystem"] = nil
    c.press("Y")
    c.looks(2)
    check(w.calls.SkipTime == calls and S.refused == 1 and printed(ue, "the game's clock was not found") ~= nil, "a kept subsystem that now names another object is not called")
    local fresh = newWorld(ue, { start = 9 * DAY })       -- a new time subsystem (the hero's objects stay the old ones)
    ue.allOf["GothicPlayerControllerBaseBP_C"] = { w.controller }
    c.world = fresh
    c.looks(12)
    c.press("Y")
    c.looks(2)
    check(fresh.calls.SkipTime == 1 and fresh.seconds == 9 * DAY + 14 * LOOK + 1800 and w.calls.SkipTime == calls and firstOf(ue) >= 2,
        "the clock of the new subsystem is found by a new search and skipped; the old object is left alone")
    stop(c)

    c = start("gone-between", { config = KEY_Y })
    ue, w, S = c.ue, c.world, c.S
    c.press("Y")
    c.looks(1)
    w.subsystem.__valid = false
    ue.firstOf["GameTimeSubsystem"] = nil
    c.looks(1)
    check(S.job == nil and S.refused == 1 and w.calls.SkipTime == 0 and #ue.errors == 0, "the subsystem goes away between the two looks: the request ends, no error")
    stop(c)
    c = start("gone-check", { config = KEY_Y, world = { skip = "dead" } })
    ue, w, S = c.ue, c.world, c.S
    c.press("Y")
    c.looks(2)
    w.subsystem.__valid = false
    ue.firstOf["GameTimeSubsystem"] = nil
    c.looks(1)
    check(S.job == nil and S.refused == 1 and next(S.failed) == nil and not S.broken and #ue.errors == 0,
        "it goes away before the check a look later: the request ends; no way is blamed for it")
    stop(c)

    -- the subsystem dies in the middle of a look: after n more questions whether it still exists
    for n = 0, 12 do
        local d = start("dies", { config = KEY_Y })
        d.press("Y")
        d.looks(1)
        local left = n
        rawset(d.world.subsystem, "IsValid", function()
            left = left - 1
            return left >= 0
        end)
        d.looks(3)
        local moved = d.gone() - 4 * LOOK
        if not (printedCount(d.ue, "update error") == 0 and #d.ue.errors == 0 and d.S.job == nil and (moved == 0 or moved == 1800)
            and (d.S.skips == 1 or (d.S.refused == 1 and d.S.lastRefusal == "the game's clock was not found"))) then
            check(false, "the subsystem goes away after " .. n .. " more questions: skips " .. d.S.skips .. ", not skipped " .. d.S.refused .. ", moved " .. moved
                .. ", " .. tostring(printed(d.ue, "update error")))
        end
        if n == 12 then check(d.S.skips == 1, "a subsystem that goes away at any point of a look ends the request cleanly (13 points tried; after the skip it no longer matters)") end
        stop(d)
    end

    -- exactly between the second reading and the call
    c = start("dies-before-call", { config = KEY_Y, diag = true })
    c.world.diesAtRead = 2
    c.press("Y")
    c.looks(2)
    check(c.S.job == nil and c.S.refused == 1 and c.S.lastRefusal == "the game's clock was not found" and c.world.calls.SkipTime == 0,
        "the subsystem is gone when the call is due: the request ends there")
    check(#c.fake.crumbs == 0 and next(c.S.called) == nil and next(c.S.failed) == nil, "no call is announced that is not made; no way is blamed")
    stop(c)

    -- a clock that can only be read through the game's function, not as a property
    c = start("clock-function", { config = KEY_Y, world = { clockByFunction = true }, diag = true })
    c.press("Y")
    c.looks(2)
    check(c.S.skips == 1 and c.S.works == "table" and c.gone() == 2 * LOOK + 1800 and c.kitFake.value("kit.game_time_source") == "function",
        "a clock that is only readable through GetCurrentGameTime(): the skip is made and checked all the same")
    stop(c)
    c = start("clock-function-dead", { config = KEY_Y, world = { clockByFunction = true, skip = "dead" } })
    c.press("Y")
    c.looks(5)
    check(c.S.broken == true and c.world.writes == 0 and c.S.failed.clock == "the clock is not readable as a property" and c.gone() == 5 * LOOK and #c.ue.errors == 0
        and rawget(c.world.empty, "TotalSeconds") == nil, "with such a clock the third way has nothing to write to: it says so and writes nothing anywhere")
    stop(c)

    -- an error inside the module's own step
    c = start("tick-error", { config = KEY_Y })
    c.expectErrors = true        -- this case provokes an error inside the loop
    ue, S = c.ue, c.S
    S.job = { stage = "second" }        -- a request with nothing in it
    c.looks(3)
    check(#ue.errors == 0 and S.job == nil and printedCount(ue, "[G1R_Wait] update error: ") == 1, "an error in the module's step is caught, said once, and the request is dropped")
    c.press("Y")
    c.looks(2)
    check(c.world.calls.SkipTime == 1, "the module goes on working")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("9. settings while the game runs: the file, the in-game menu")
do
    local c = start("file", { config = KEY_Y, widgets = true })
    local ue, w, S = c.ue, c.world, c.S
    local v = c.hook.settings.values
    T.write(c.path, config('Config.ShortKey = "Y"\nConfig.ShortMinutes = 45'))
    c.looks(20)
    check(v.ShortMinutes == 45 and printed(ue, "[G1R_Wait] settings changed (config.lua): Y = 45 minutes\n") ~= nil, "a changed file is picked up within 5 seconds and said in the log")
    c.press("Y")
    c.looks(2)
    check(w.asked == 2700 and c.ui.note() == "45 minutes later - 14:46", "the next press skips the new amount: " .. tostring(c.ui.note()))
    -- the key moves
    T.write(c.path, config('Config.ShortKey = "f9"\nConfig.ShortMinutes = 45'))
    c.looks(20)
    check(v.ShortKey == "F9" and S.keys[1] == "F9" and ue.calls.RegisterKeyBind == 2 and printed(ue, "settings changed (config.lua): F9 = 45 minutes") ~= nil,
        "the key is changed to F9 (written f9): bound while the game runs")
    local calls = w.calls.SkipTime
    check(c.press("Y") == 1, "(UE4SS still reports the old key: a registration cannot be taken back)")
    c.looks(3)
    check(w.calls.SkipTime == calls and S.job == nil and S.refused == 0, "the old key does nothing any more")
    c.press("F9")
    c.looks(2)
    check(w.calls.SkipTime == calls + 1, "the new key skips")
    -- a key with modifiers, in another spelling
    T.write(c.path, config('Config.ShortKey = "ctrl + shift + y"'))
    c.looks(20)
    check(v.ShortKey == "CTRL+SHIFT+Y" and S.keys[1] == "CTRL+SHIFT+Y" and printed(ue, "settings changed (config.lua): CTRL+SHIFT+Y = 30 minutes") ~= nil, "ctrl + shift + y is taken as CTRL+SHIFT+Y")
    c.press("CTRL+SHIFT+Y")
    c.looks(2)
    check(w.calls.SkipTime == calls + 2 and w.asked == 1800, "and skips (the minutes are back at their default: the line is gone from the file)")
    -- no key any more
    T.write(c.path, config('Config.ShortKey = ""'))
    c.looks(20)
    c.press("CTRL+SHIFT+Y")
    c.press("F9")
    c.press("Y")
    c.looks(3)
    check(S.keys[1] == "" and w.calls.SkipTime == calls + 2 and printed(ue, "settings changed (config.lua): no key bound (buttons in the in-game menu; console: wait 30, wait until 8)") ~= nil,
        "the key taken away: no key skips any more, the log says so")
    check(ue.calls.RegisterKeyBind == 3, "three keys were registered with UE4SS in this run, each once")
    -- back to Y: the registration from the start is used again
    T.write(c.path, config('Config.ShortKey = "Y"\nConfig.LongKey = "Y"'))
    c.looks(20)
    check(ue.calls.RegisterKeyBind == 3 and printedCount(ue, "the short wait and the long wait have the same key Y: a press takes the short wait") == 1,
        "two waits get the same key while the game runs: said once; nothing new is registered")
    c.looks(20)
    c.press("Y")
    c.looks(2)
    check(w.calls.SkipTime == calls + 3 and w.asked == 1800, "one press, the short wait")
    check(#ue.errors == 0, "no error in all of this")
    stop(c)

    -- values out of range, of the wrong kind
    c = start("range", { config = config('Config.ShortKey = "banana"\nConfig.ShortMinutes = 0\nConfig.LongMinutes = 5000\nConfig.MorningHour = 24\nConfig.EveningHour = -1\nConfig.Cooldown = 99\nConfig.LongKey = 7') })
    v = c.hook.settings.values
    check(v.ShortKey == "" and v.ShortMinutes == 1 and v.LongMinutes == 1440 and v.MorningHour == 23 and v.EveningHour == 0 and v.Cooldown == 60 and v.LongKey == "",
        "values out of range are pulled inside (1 and 1440 minutes, hours 0 and 23, 60 s); a key that is none is no key")
    check(printed(c.ue, "config.lua: ShortKey = banana is not usable") ~= nil and (c.ue.calls.RegisterKeyBind or 0) == 0, "said in the log; nothing is registered")
    check(has(status(c), "short wait: 1 minute, no key | long wait: 24 hours, no key | wait until morning: until 23:00, no key | wait until evening: until 00:00, no key"), "the status shows what is in use")
    stop(c)
    c = start("fraction", { config = config('Config.ShortKey = "Y"\nConfig.ShortMinutes = 2.6\nConfig.MorningHour = 7.4\nConfig.Cooldown = 0.26') })
    v = c.hook.settings.values
    check(v.ShortMinutes == 3 and v.MorningHour == 7 and v.Cooldown == 0.3, "minutes and hours are whole numbers, the cooldown has one decimal place")
    c.press("Y")
    c.looks(2)
    check(c.world.asked == 180, "2.6 minutes are 3")
    c.press("Y")
    c.looks(1)
    check(c.S.refused == 1, "a press a quarter second after the skip is inside a cooldown of 0.3 s")
    c.looks(1)
    c.press("Y")
    c.looks(2)
    check(c.world.calls.SkipTime == 2, "one half a second after it is not")
    stop(c)

    -- the in-game mod menu
    c = start("menu", { config = KEY_Y, widgets = true })
    ue, w, S = c.ue, c.world, c.S
    v = c.hook.settings.values
    local index = T.menuIndex(c)
    check(#index == 1 and index[1] == "G1R Time", "the module's page is registered with the in-game mod menu as G1R Time")
    local page = T.menuPage(c, "Time")
    local titles = {}
    for _, s in ipairs(page.sections) do titles[#titles + 1] = s.title .. ":" .. #s.items end
    check(table.concat(titles, "|") == "Waiting:2|Short wait:2|Long wait:2|Wait until morning:2|Wait until evening:2|When not to wait:4|On screen:2|Log:1",
        "its sections and their items (keys cannot be set in the menu): " .. table.concat(titles, "|"))
    local item = T.menuItem(c, "Time", "The short wait skips")
    check(item.kind == "num" and item.min == 1 and item.max == 1440 and item.step == 5 and item.value == 30 and item.name == "The short wait skips (minutes)", "the short wait: 1 to 1440 minutes in steps of 5")
    item = T.menuItem(c, "Time", "Morning is at")
    check(item.kind == "num" and item.min == 0 and item.max == 23 and item.step == 1 and item.value == 8 and item.name == "Morning is at (o'clock)", "the morning hour: 0 to 23")
    item = T.menuItem(c, "Time", "Time between two skips (seconds)")
    check(item.min == 0 and item.max == 60 and item.step == 0.5 and item.value == 2, "the cooldown: 0 to 60 seconds in steps of 0.5")
    check(T.menuItem(c, "Time", "Wait the short time now").kind == "action" and T.menuItem(c, "Time", "Wait until evening now").kind == "action"
        and T.menuItem(c, "Time", "Not with a weapon drawn").kind == "bool", "buttons are buttons, switches are switches")
    for _, i in ipairs(page.items) do
        if has(i.name, "Key for") then check(false, "a key is in the menu: " .. i.name) end
    end
    T.menuSet(c, "Time", "The short wait skips", 60)
    c.looks(1)
    check(v.ShortMinutes == 60 and printed(ue, "[G1R_Wait] settings changed (in-game menu): Y = 1 hour\n") ~= nil and has(T.read(c.path), "Config.ShortMinutes = 60\n"),
        "an edit in the menu is applied at the next look, said in the log and written into config.lua")
    c.press("Y")
    c.looks(2)
    check(w.asked == 3600 and c.ui.note() == "1 hour later - 15:00", "and used: " .. tostring(c.ui.note()))
    w.flags.m_IsInCombat = true
    T.menuSet(c, "Time", "Not with a weapon drawn", false)
    T.menuSet(c, "Time", "Time between two skips (seconds)", 0)
    c.looks(1)
    c.press("Y")
    c.looks(2)
    check(v.NotInFight == false and v.Cooldown == 0 and w.calls.SkipTime == 2, "two edits at once: the weapon no longer stops a skip, the cooldown is off")
    -- the module switched off: silent
    T.menuSet(c, "Time", "Skip time (keys, buttons, console)", false)
    c.looks(1)
    check(v.Enabled == false and printed(ue, "settings changed (in-game menu): switched off in the settings") ~= nil, "switched off in the menu")
    local reads, lines = w.reads(), #ue.printed
    c.press("Y")
    c.looks(3)
    T.menuSet(c, "Time", "Wait the short time now", true)
    c.looks(3)
    check(w.calls.SkipTime == 2 and w.reads() == reads and #ue.printed == lines and S.refused == 0 and S.job == nil and S.asked.key == 2 and S.asked.menu == 0,
        "switched off: key and button do nothing, nothing is read, nothing is logged, nothing is counted")
    check(has(status(c), "v1.0.1 | switched off in the settings|"), "the status says it is off")
    -- switched off while a request is under way
    T.menuSet(c, "Time", "Skip time (keys, buttons, console)", true)
    c.looks(1)
    c.press("Y")
    c.looks(1)
    check(S.job ~= nil, "(switched on again; a request is under way)")
    T.menuSet(c, "Time", "Skip time (keys, buttons, console)", false)
    c.looks(2)
    check(S.job == nil and w.calls.SkipTime == 2, "switching off drops a request that was under way")
    stop(c)

    c = start("off-at-start", { config = config('Config.ShortKey = "Y"\nConfig.Enabled = false') })
    check(printed(c.ue, "loaded: switched off in the settings") ~= nil, "Enabled = false at the start: the load line says so")
    c.press("Y")
    c.looks(4)
    check(c.world.calls.SkipTime == 0 and c.world.reads() == 0 and allOf(c.ue) == 0 and firstOf(c.ue) == 0 and #c.ue.lookups == 0 and #c.ue.printed == 1,
        "the key does nothing; the game is not looked at; nothing is logged")
    T.write(c.path, KEY_Y)
    c.looks(20)
    c.press("Y")
    c.looks(2)
    check(c.world.calls.SkipTime == 1 and printed(c.ue, "settings changed (config.lua): Y = 30 minutes") ~= nil, "switched on while the game runs: the key works")
    stop(c)

    c = start("badstart", { config = "this is not lua\n" })
    check(c.ok and printed(c.ue, "config.lua has an error (") ~= nil and c.hook.settings.values.ShortMinutes == 30 and c.hook.settings.values.ShortKey == "", "a broken file at the start: said, default settings")
    stop(c)
    c = start("nofile", { config = false })
    check(c.ok and printed(c.ue, "config.lua was not there: written with the default settings") ~= nil and T.read(c.path) == shipped, "no file at the start: the default file is written")
    stop(c)
    c = start("noschema", { files = { ["Scripts/schema.lua"] = false } })
    check(c.ok and printed(c.ue, "the settings could not be set up (schema.lua could not be read") ~= nil and #c.ue.loops == 1 and c.ue.console.wait == nil,
        "without schema.lua the module says so and does not start")
    stop(c)

    -- the shipped files
    local schema = dofile(MOD .. "modules/wait/Scripts/schema.lua")
    local chunk = load(shipped, "=config.lua", "t", {})
    local values = chunk and chunk() or {}
    local keys = {}
    for k in pairs(values) do keys[#keys + 1] = k end
    table.sort(keys)
    check(table.concat(keys, ",") == "Cooldown,Enabled,EveningHour,EveningKey,LogSkips,LongKey,LongMinutes,MorningHour,MorningKey,NotInConversation,NotInCutscene,NotInFight,NotWhenClockStopped,ShortKey,ShortMinutes,ShowMessage,ShowRefused"
        and not shipped:find("\r", 1, true) and not shipped:find("[^\n\32-\126]"), "the shipped config.lua: seventeen settings, plain ASCII, LF line ends")
    local probe = start("default-text", {})
    check(probe.settings.defaultText(schema) == shipped, "the shipped config.lua is exactly what the schema generates (lua5.4 dev/tools/gen_config.lua wait)")
    check(schema.Page == "Time" and schema.PageOrder == 50 and schema.Module == "wait", "the page is Time, at position 50")
    stop(probe)
end

-- ---------------------------------------------------------------------------
section("10. the console")
do
    local c = start("console", { config = config('Config.LogSkips = false'), widgets = true })
    local ue, w, S = c.ue, c.world, c.S
    local before = #ue.printed
    check(ue:fireConsole("wait") == true and #ue.errors == 0, "wait: handled (a boolean is returned)")
    check(ue.printed[before + 1] == "[G1R_Wait] v1.0.1 | no key bound (buttons in the in-game menu; console: wait 30, wait until 8)\n" and #ue.printed == before + 3
        and ue.printed[before + 3] == "[G1R_Wait] skips: 0\n", "without a word: the status, three lines")
    check(#ue.device.lines == 3 and ue.device.lines[1] == "[G1R_Wait] v1.0.1 | no key bound (buttons in the in-game menu; console: wait 30, wait until 8)", "the same lines go to the console window")
    check(w.reads() == 0 and allOf(ue) == 0, "the status does not look at the game")
    -- wait <minutes>
    before = #ue.printed
    check(ue:fireConsole("wait 30") == true and ue.printed[before + 1] == "[G1R_Wait] 30 minutes: asked for; the result follows in this log\n" and S.job ~= nil and w.reads() == 0,
        "wait 30: the request is left for the loop; the console word itself does not touch the game")
    c.looks(2)
    check(w.asked == 1800 and c.gone() == 2 * LOOK + 1800 and c.ui.note() == "30 minutes later - 14:30" and S.asked.console == 1,
        "the skip follows within half a second, with no key bound at all")
    c.looks(8)
    before = #ue.printed
    ue:fireConsole("wait 90")
    c.looks(2)
    check(w.asked == 5400 and ue.printed[before + 1] == "[G1R_Wait] 1 hour 30 minutes: asked for; the result follows in this log\n"
        and has(ue.printed[before + 2], "[G1R_Wait] skipped 1 hour 30 minutes, day 4 14:30 -> day 4 16:00, by SkipTime with a plain value (seen at once)"),
        "wait 90: a skip asked for at the console is always logged, also when it is not the first")
    -- wait until <hour>
    c.looks(8)
    before = #ue.printed
    ue:fireConsole("wait until 8")
    c.looks(2)
    check(ue.printed[before + 1] == "[G1R_Wait] until 08:00: asked for; the result follows in this log\n" and hhmm(c.t()) == "08:00" and c.t() == 5 * DAY + 8 * 3600 + 1
        and c.ui.note() == "15 hours 59 minutes later - 08:00", "wait until 8: " .. tostring(c.ui.note()))
    c.looks(8)
    ue:fireConsole("wait until 0")
    c.looks(2)
    check(c.t() == 6 * DAY + 1 and hhmm(c.t()) == "00:00", "wait until 0 is midnight")
    c.looks(8)
    ue:fireConsole("wait UNTIL 23")
    c.looks(2)
    check(c.t() == 6 * DAY + 23 * 3600 + 1, "wait UNTIL 23 (capitals are fine)")
    -- what is not an amount
    local skips = w.calls.SkipTime
    c.looks(8)
    for _, words in ipairs({ "wait 0", "wait 1441", "wait 2.5", "wait -5", "wait 1e9" }) do
        before = #ue.printed
        ue:fireConsole(words)
        check(ue.printed[before + 1] == "[G1R_Wait] wait <minutes>: whole minutes from 1 to 1440 (wait 30)\n" and S.job == nil, words .. ": not an amount, the console says what is")
    end
    for _, words in ipairs({ "wait until", "wait until 24", "wait until -1", "wait until 7.5", "wait until morning" }) do
        before = #ue.printed
        ue:fireConsole(words)
        check(ue.printed[before + 1] == "[G1R_Wait] wait until <hour>: an hour from 0 to 23 (wait until 8)\n" and S.job == nil, words .. ": not an hour, the console says what is")
    end
    c.looks(4)
    check(w.calls.SkipTime == skips and S.refused == 0, "none of these skipped anything or counts as a skip not taken")
    ue:fireConsole("wait 1")
    c.looks(2)
    check(w.asked == 60 and c.ui.note() == "1 minute later - 23:01", "wait 1: the smallest amount (" .. tostring(c.ui.note()) .. ")")
    c.looks(8)
    ue:fireConsole("wait 1440")
    c.looks(2)
    check(w.asked == DAY and has(c.ui.note(), "24 hours later - 23:0"), "wait 1440: the largest")
    -- too soon
    before = #ue.printed
    ue:fireConsole("wait 45")
    check(ue.printed[before + 2] == "[G1R_Wait] 45 minutes: not skipped - the last skip was a moment ago\n" and S.job == nil, "wait 45 right after a skip: the console says why not")
    -- reload, other spellings
    T.write(c.path, config('Config.ShortKey = "Y"\nConfig.ShortMinutes = 10'))
    check(ue:fireConsole("wait reload") == true and c.hook.settings.values.ShortMinutes == 10 and printed(ue, "[G1R_Wait] settings read: Y = 10 minutes\n") ~= nil, "wait reload reads the file at once")
    before = #ue.printed
    ue:fireConsole("wait reload")
    check(ue.printed[before + 1] == "[G1R_Wait] settings read: Y = 10 minutes\n", "wait reload reads the file also when it has not changed")
    before = #ue.printed
    check(ue:fireConsole("g1r_wait") == true and has(ue.printed[before + 1], "v1.0.1 | Y = 10 minutes") and ue:fireConsole("wait something") == true and has(ue.printed[#ue.printed - 1], "skips: 7; last: 24 hours, day 6 23:02 -> day 7 23:02, by")
        and ue.printed[#ue.printed] == "[G1R_Wait] not skipped: 1 time; last reason: the last skip was a moment ago\n",
        "g1r_wait works too; an unknown word shows the status")
    check(c.hook.console(nil, nil, nil) == true and c.hook.console("wait", { 2.5, {} }, {}) == true and #ue.errors == 0, "called with nothing, or with parameters of another kind: handled")
    c.looks(12)
    skips = w.calls.SkipTime
    check(c.hook.console("wait 5", nil, nil) == true and S.job ~= nil, "with the command line only, the words are taken from it")
    c.looks(2)
    check(w.calls.SkipTime == skips + 1 and w.asked == 300, "(wait 5 skips five minutes)")
    stop(c)

    c = start("console-off", { config = config("Config.Enabled = false") })
    local before2 = #c.ue.printed
    c.ue:fireConsole("wait 30")
    c.looks(3)
    check(c.ue.printed[before2 + 1] == "[G1R_Wait] 30 minutes: not skipped - switched off in the settings\n" and c.world.calls.SkipTime == 0 and c.S.refused == 0 and c.S.asked.console == 0,
        "the module switched off: the console says so, nothing is skipped")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("11. the buttons of the in-game menu")
do
    local c = start("buttons", { config = config("Config.Cooldown = 0"), widgets = true, diag = true })
    local ue, w, S = c.ue, c.world, c.S
    check((ue.calls.RegisterKeyBind or 0) == 0, "no key is bound")
    T.menuSet(c, "Time", "Wait the short time now", true)
    c.looks(1)
    check(S.job ~= nil and w.calls.SkipTime == 0, "the button leaves a request")
    c.looks(1)
    check(w.asked == 1800 and c.ui.note() == "30 minutes later - 14:30" and S.asked.menu == 1 and c.fake.value("wait.key_press") == nil,
        "the short wait by button: " .. tostring(c.ui.note()) .. " (no key press is noted)")
    T.menuSet(c, "Time", "Wait the long time now", true)
    c.looks(2)
    check(w.asked == 14400 and c.ui.note() == "4 hours later - 18:30", "the long wait by button: " .. tostring(c.ui.note()))
    T.menuSet(c, "Time", "Wait until morning now", true)
    c.looks(2)
    check(hhmm(c.t()) == "08:00" and c.t() == 5 * DAY + 8 * 3600 + 1, "until morning by button")
    T.menuSet(c, "Time", "Wait until evening now", true)
    c.looks(2)
    check(hhmm(c.t()) == "20:00" and c.t() == 5 * DAY + 20 * 3600 + 1 and S.skips == 4 and S.asked.menu == 4, "until evening by button")
    -- amount and button in the same edit
    T.menuSet(c, "Time", "Evening is at", 22)
    T.menuSet(c, "Time", "Wait until evening now", true)
    c.looks(2)
    check(c.t() == 5 * DAY + 22 * 3600 + 1, "an hour changed and its button pressed in one go: the new hour is used")
    T.menuSet(c, "Time", "Wait the short time now", true)
    T.menuSet(c, "Time", "Wait the long time now", true)
    c.looks(2)
    check(S.skips == 6 and w.asked == 1800 and S.refused == 1, "two buttons in the same moment: one skip")
    check(#ue.errors == 0, "no error")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("12. what is shown and what is logged")
do
    -- the note after a skip
    local c = start("note", { config = KEY_Y, widgets = true })
    local ue, w, ui = c.ue, c.world, c.ui
    c.press("Y")
    c.looks(2)
    check(ui.created == 1 and ui.note() == "30 minutes later - 14:30" and ui.last("SetVisibility", ui.widget).args[1] == 3, "the note is the kit's box, shown without taking clicks")
    c.looks(11)
    check(ui.note() ~= nil, "still up after 2.75 seconds")
    c.looks(1)
    check(ui.note() == nil, "gone after 3 (the time set on the page General)")
    c.press("Y")
    c.looks(2)
    T.write(c.path, config('Config.ShortKey = "Y"\nConfig.NotInFight = false\nConfig.ShowRefused = true'))
    ue:fireConsole("wait reload")
    check(ui.note() == "30 minutes later - 15:01" and c.hook.settings.values.NotInFight == false and c.hook.settings.values.ShowRefused == true,
        "other settings change while the note is up (one switched off, the other note switched on): it stays")
    T.write(c.path, config('Config.ShortKey = "Y"\nConfig.ShowMessage = false'))
    local up = ui.note() ~= nil
    ue:fireConsole("wait reload")
    check(up and ui.note() == nil, "ShowMessage = false while the note is up: it is hidden at once")
    c.looks(12)
    local widgetCalls = #ui.calls
    c.press("Y")
    c.looks(2)
    check(w.calls.SkipTime == 3 and #ui.calls == widgetCalls and ui.note() == nil, "ShowMessage = false: the skip is made, nothing is shown")
    stop(c)

    c = start("note-subtitle", { config = KEY_Y, widgets = true })
    c.kit.configureNotes({ style = "subtitle", seconds = 5 })
    c.press("Y")
    c.looks(2)
    local s = c.ui.subtitles[1]
    check(#c.ui.subtitles == 1 and s.text == "30 minutes later - 14:30" and s.seconds == 5 and c.ui.created == 0, "notes set to the game's own line (page General): the note goes there")
    stop(c)
    c = start("note-off", { config = KEY_Y, widgets = true })
    c.kit.configureNotes({ style = "off" })
    c.press("Y")
    c.looks(2)
    check(c.world.calls.SkipTime == 1 and c.ui.created == 0 and #c.ui.subtitles == 0 and #c.ue.lookups == 1, "notes switched off altogether: the skip is made, nothing is shown or searched for it")
    stop(c)
    c = start("note-none", { config = KEY_Y })       -- a game without any of the widget classes
    c.press("Y")
    c.looks(2)
    check(c.world.calls.SkipTime == 1 and c.S.skips == 1 and #c.ue.errors == 0 and c.kit.toastAvailable() == false, "no way to show a note: the skip is made all the same")
    stop(c)

    -- the note for a skip that was not taken
    c = start("refused-note", { config = config('Config.ShortKey = "Y"\nConfig.ShowRefused = true'), world = { flags = { m_IsInCombat = true } }, widgets = true })
    ue, w, ui = c.ue, c.world, c.ui
    c.press("Y")
    c.looks(2)
    check(ui.note() == "Cannot wait now: the hero has a weapon drawn", "ShowRefused = true: the reason is shown (" .. tostring(ui.note()) .. ")")
    T.write(c.path, config('Config.ShortKey = "Y"\nConfig.ShowRefused = false'))
    ue:fireConsole("wait reload")
    check(ui.note() == nil, "ShowRefused = false while that note is up: hidden at once")
    T.write(c.path, config('Config.ShortKey = "Y"\nConfig.ShowRefused = true'))
    ue:fireConsole("wait reload")
    w.flags.m_IsInCombat = false
    c.press("Y")
    c.looks(2)
    check(ui.note() == "30 minutes later - 14:30", "a skip that is taken replaces it with the usual note")
    c.press("Y")
    c.looks(2)
    check(c.S.refused == 2 and ui.note() == "30 minutes later - 14:30", "a press during the cooldown is not shown, also with ShowRefused: the note of the skip stays")
    w.paused = true
    c.looks(8)
    c.press("Y")
    c.looks(2)
    check(ui.note() == "Cannot wait now: the game is paused", "another reason is shown: " .. tostring(ui.note()))
    stop(c)
    c = start("refused-quiet", { config = config('Config.ShortKey = "Y"\nConfig.LongKey = "Y"\nConfig.ShowRefused = true'), widgets = true })
    c.press("Y")
    c.looks(1)
    check(c.S.refused == 1 and c.ui.note() == nil and c.ui.created == 0, "'another skip is under way' is not shown either")
    stop(c)

    -- the log
    c = start("log", { config = config('Config.ShortKey = "Y"\nConfig.Cooldown = 0\nConfig.LogSkips = true') })
    ue, w = c.ue, c.world
    for _ = 1, 3 do
        c.press("Y")
        c.looks(2)
    end
    check(printedCount(ue, "[G1R_Wait] skipped 30 minutes, day 4 1") == 3 and printed(ue, "skipped 30 minutes, day 4 15:00 -> day 4 15:30, by SkipTime with a plain value (seen at once)") ~= nil,
        "LogSkips = true: every skip gets its line")
    stop(c)
    c = start("log-reasons", { config = config('Config.ShortKey = "Y"\nConfig.Cooldown = 0'), world = { flags = { m_IsInCombat = true } } })
    ue, w = c.ue, c.world
    for _ = 1, 19 do        -- 9.5 seconds
        c.press("Y")
        c.looks(2)
    end
    check(c.S.refused == 19 and printedCount(ue, "no time skipped: the hero has a weapon drawn") == 1, "the same reason nineteen times in 9.5 seconds: one line")
    w.flags.m_IsInCombat, w.flags.bIsInConversation = false, true
    c.press("Y")
    c.looks(2)
    check(printedCount(ue, "no time skipped: the hero is in a conversation") == 1, "another reason gets its own line at once")
    w.flags.m_IsInCombat, w.flags.bIsInConversation = true, false
    c.press("Y")
    c.looks(2)
    check(printedCount(ue, "no time skipped: the hero has a weapon drawn") == 2, "the first reason again, 10.5 seconds after its line: a second line")
    c.press("Y")
    c.looks(2)
    check(printedCount(ue, "no time skipped: the hero has a weapon drawn") == 2 and c.S.refused == 22, "and not a third right after")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("13. map loads, and a UE4SS that lacks something")
do
    local c = start("load-map", { config = config('Config.ShortKey = "Y"\nConfig.Cooldown = 0\nConfig.ShowRefused = true'), widgets = true })
    local ue, w, S = c.ue, c.world, c.S
    c.press("Y")
    c.looks(1)
    check(S.job ~= nil, "a request is under way")
    ue:fireLoadMapPre("engine", "world", "url", nil, "")
    check(S.job == nil, "a map load begins: the request is dropped")
    local reads = w.reads()
    c.press("Y")
    c.looks(4)
    check(w.calls.SkipTime == 0 and w.reads() == reads and S.asked.key == 1, "a key pressed during the load does not reach the module (the kit drops it); nothing is read")
    T.menuSet(c, "Time", "Wait the short time now", true)
    c.looks(2)
    check(w.calls.SkipTime == 0 and w.reads() == reads and S.refused == 1 and printed(ue, "[G1R_Wait] no time skipped: a map is loading\n") ~= nil,
        "a button during the load: not taken, said in the log, the game is not looked at")
    check(c.ui.note() == nil and c.ui.created == 0, "and nothing is put on screen during a load, even with ShowRefused")
    S.job = { stage = "first" }
    c.looks(2)
    check(S.job ~= nil and w.reads() == reads, "even a request that were there would not be worked on during a load")
    S.job = nil
    -- the new world: other objects
    w.subsystem.__valid, w.controller.__valid, w.pawn.__valid = false, false, false
    local fresh = newWorld(ue, { start = 7 * DAY })
    c.world = fresh
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.press("Y")
    c.looks(2)
    check(fresh.calls.SkipTime == 1 and fresh.seconds == 7 * DAY + 2 * LOOK + 1800 and w.calls.SkipTime == 0 and S.skips == 1, "after the load the clock of the new world is found and skipped")
    check(c.ui.note() == "30 minutes later - 00:30", "the note is shown in the new world: " .. tostring(c.ui.note()))
    -- a request under way when the load ends
    c.press("Y")
    c.looks(1)
    ue:fireLoadMapPost("engine", "world", "url", nil, "")
    c.looks(2)
    check(S.job == nil and fresh.calls.SkipTime == 1, "a change of the world drops a request at its end too")
    stop(c)

    c = start("no-post-hook", { config = KEY_Y, mock = { without = { "RegisterLoadMapPostHook" } } })
    c.press("Y")
    c.looks(1)
    c.ue:fireLoadMapPre("engine", "world", "url", nil, "")
    c.looks(2)
    check(c.S.job == nil and c.world.calls.SkipTime == 0, "a UE4SS without the hook after a map load: the request is dropped at the load all the same")
    c.press("Y")
    c.looks(2)
    check(c.world.calls.SkipTime == 1 and #c.ue.errors == 0, "and the module goes on afterwards")
    stop(c)

    c = start("no-loop", { config = KEY_Y, mock = { without = { "LoopInGameThreadWithDelay" } } })
    check(c.ok and printed(c.ue, "[G1R_Wait] FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; waiting is disabled.\n") ~= nil and #c.ue.errors == 0,
        "a UE4SS without the game-thread loop: said, the module does not start")
    check(printed(c.ue, "[G1R_Wait] the key Y for the short wait could not be bound (this UE4SS build has no key bindings); the button in the in-game menu and the console still work\n") ~= nil,
        "(and the key cannot be bound either)")
    c.ue:fireConsole("wait 30")
    check(printed(c.ue, "[G1R_Wait] 30 minutes: not skipped - skipping time does not work in this game (see earlier in this log)\n") ~= nil and #c.ue.errors == 0,
        "a console word is answered, not left waiting for a loop that is not there")
    stop(c)

    c = start("no-keys", { config = KEY_Y, mock = { without = { "RegisterKeyBind" } }, widgets = true })
    check(c.ok and printedCount(c.ue, "the key Y for the short wait could not be bound (this UE4SS build has no key bindings)") == 1
        and printed(c.ue, "loaded: no key bound (buttons in the in-game menu") ~= nil, "a UE4SS without key bindings: said once; the load line says no key is bound")
    T.menuSet(c, "Time", "Wait the short time now", true)
    c.looks(2)
    check(c.world.calls.SkipTime == 1 and c.ui.note() == "30 minutes later - 14:30", "the button still skips")
    T.write(c.path, config('Config.ShortKey = "F9"'))
    c.looks(20)
    check(printedCount(c.ue, "could not be bound") == 2 and printed(c.ue, "the key F9 for the short wait could not be bound") ~= nil, "another key that cannot be bound is said too")
    stop(c)
    -- a UE4SS that refuses one registration
    do
        local Mock = T.Mock
        local realNew = Mock.new
        Mock.new = function(options)
            local ue = realNew(options)
            local register = ue.globals.RegisterKeyBind
            ue.globals.RegisterKeyBind = function(key, ...)
                if key == 89 then error("the key is taken (test)", 0) end
                return register(key, ...)
            end
            return ue
        end
        c = start("key-raises", { config = config('Config.ShortKey = "Y"\nConfig.LongKey = "F6"') })
        Mock.new = realNew
        check(c.ok and printed(c.ue, "[G1R_Wait] the key Y for the short wait could not be bound (the key could not be registered (the key is taken (test))); the button in the in-game menu and the console still work\n") ~= nil
            and printed(c.ue, "loaded: F6 = 4 hours\n") ~= nil and c.S.keys[1] == "" and c.S.keys[2] == "F6", "a registration that raises: that key is left out, the other one works")
        c.press("F6")
        c.looks(2)
        check(c.world.asked == 14400, "(F6 skips)")
        stop(c)
    end
end

-- ---------------------------------------------------------------------------
section("14. nothing leaks, only config.lua is written; the diagnostics")
do
    local known = {}
    local probe = T.Mock.new()
    probe:install()                 -- what the mock itself puts into _G does not count
    for k in pairs(_G) do known[k] = true end
    probe:uninstall()
    local given = { WAIT_TEST = true, ModRef = true, G1R_KIT = true, G1R_SETTINGS = true, G1R_DIAG = true, Key = true, ModifierKey = true, StaticConstructObject = true }
    local c = start("leak", { config = config('Config.ShortKey = "Y"\nConfig.MorningKey = "F7"'), widgets = true, diag = true, world = { flags = { bIsInConversation = true } } })
    local w = c.world
    c.press("Y")
    c.looks(4)
    w.flags.bIsInConversation = false
    c.press("Y")
    c.looks(40)
    local leaked = {}
    for k in pairs(_G) do
        if not known[k] and not given[k] then leaked[#leaked + 1] = tostring(k) end
    end
    local sequence = table.concat(c.fake.sequence(), " ")
    local dump = c.fake.dump[1] and c.fake.dump[1]() or nil
    local statusLines = c.fake.status[1] and c.fake.status[1]() or {}
    local reads, lookups, finds, firsts = w.reads(), #c.ue.lookups, allOf(c.ue), firstOf(c.ue)
    for _ = 1, 20 do
        c.fake.dump[1]()
        c.fake.status[1]()
    end
    check(w.reads() == reads and #c.ue.lookups == lookups and allOf(c.ue) == finds and firstOf(c.ue) == firsts, "the status and the dump are built from what the module holds: no call into the game")
    stop(c)
    local leftAfter = {}
    for k in pairs(_G) do if not known[k] then leftAfter[#leftAfter + 1] = tostring(k) end end
    check(#leaked == 0 and #leftAfter == 0, "the module defines no global (" .. table.concat(leaked, ", ") .. ")")
    local p = io.popen("ls -A " .. T.q(c.dir))
    local listing = p:read("a"):gsub("%s+", " ")
    p:close()
    -- (config.lua.bak is the settings layer's: the file before the last change, as the settings app keeps it)
    check(listing:gsub("config%.lua%.bak ", "") == "config.lua main.lua schema.lua ", "the module writes no file of its own (its folder holds: " .. listing .. ")")
    check(sequence == "wait.key_press=seen wait.clock=found wait.states=readable wait.clock_running=yes wait.way=table wait.applied=at once wait.moved=as asked",
        "the notes of a session, each once: " .. sequence)
    check(c.fake.versions[1] == "1.0.1" and #c.fake.events == 2 and #c.fake.crumbs == 1, "version, the first call and the first skip go to the diagnostics")
    local Fake = dofile(HERE .. "../markers/diag_fake.lua")
    local plain, where = Fake.plain(dump)
    check(plain and Fake.roundTrip(dump), "the dump is plain data (" .. tostring(where) .. ")")
    check(dump.version == "1.0.1" and dump.enabled == true and dump.cooldown == 2 and dump.skips == 1 and dump.not_skipped == 1 and dump.last_reason == "the hero is in a conversation"
        and dump.way == "table" and dump.broken == false and dump.asked_by_key == 2 and dump.asked_by_menu == 0 and dump.asked_by_console == 0 and dump.under_way == false,
        "it holds what the module did: skips, skips not taken and why, the way, who asked")
    check(dump.waits["short wait"].key == "Y" and dump.waits["short wait"].minutes == 30 and dump.waits["short wait"].hour == nil and dump.waits["wait until morning"].key == "F7"
        and dump.waits["wait until morning"].hour == 8 and dump.waits["long wait"].key == "" and dump.waits["wait until evening"].hour == 20, "the four waits with key and amount")
    check(dump.hero_weapon_drawn == false and dump.hero_in_conversation == false and dump.hero_in_cutscene == false and dump.not_in_fight == true and dump.not_when_clock_stopped == true
        and dump.show_message == true and dump.show_refused == false and dump.log_skips == false and next(dump.failed_ways) == nil
        and has(dump.last_skip, "30 minutes, day 4 14:00 -> day 4 14:30"), "the switches and what the hero's animation said at the last request")
    check(#statusLines == 4 and statusLines[1] == "v1.0.1 | Y = 30 minutes, F7 = until 08:00" and statusLines[4] == "not skipped: 1 time; last reason: the hero is in a conversation",
        "the status function gives the status lines")
    -- a request under way shows in status and dump
    c = start("under-way", { config = KEY_Y, diag = true })
    c.press("Y")
    c.looks(1)
    local under = c.hook.status()
    check(#under == 4 and under[4] == "a skip is under way" and under[3] == "skips: 0" and c.fake.dump[1]().under_way == true, "a request between its two looks shows in the status (a fourth line) and in the dump")
    stop(c)
end

-- ---------------------------------------------------------------------------
section("14b. many things at random: one request, at most one skip")
do
    -- a small generator of its own, so that every run does the same
    local seed = 12345
    local function random(n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed // 65536 % n + 1
    end
    local KEYS = { "Y", "F6", "F7", "F8" }
    local total = { skips = 0, refused = 0, looks = 0 }
    for round = 1, 12 do
        local variant = ({ {}, { skip = "late" }, { skip = "deaf", libraryGives = "struct" }, { skip = "dead" } })[(round - 1) % 4 + 1]
        local c = start("random", { world = variant, widgets = true, diag = true,
            config = config('Config.ShortKey = "Y"\nConfig.LongKey = "F6"\nConfig.MorningKey = "F7"\nConfig.EveningKey = "F8"\nConfig.Cooldown = ' .. (round % 3) .. '\nConfig.ShowRefused = true') })
        local ue, w, S = c.ue, c.world, c.S
        local bad = nil
        local jobAge, lastMove, natural, skipped = 0, -100, 0, 0
        for step = 1, 300 do
            local r = random(20)
            if r <= 6 then c.press(KEYS[random(4)])
            elseif r == 7 then c.press(KEYS[random(4)]) c.press(KEYS[random(4)])
            elseif r == 8 then T.menuSet(c, "Time", "Wait the short time now", true)
            elseif r == 9 then ue:fireConsole("wait " .. random(120))
            elseif r == 10 then w.flags.m_IsInCombat = random(5) == 1
            elseif r == 11 then w.flags.bIsInConversation = random(5) == 1
            elseif r == 12 then w.paused = random(5) == 1
            elseif r == 13 then w.frozen = random(5) == 1
            elseif r == 14 then
                ue:fireLoadMapPre("engine", "world", "url", nil, "")
                c.looks(random(3))
                ue:fireLoadMapPost("engine", "world", "url", nil, "")
            end
            local before, skipsBefore = w.seconds, S.skips
            local running = not w.frozen and not w.paused
            c.looks(1)
            total.looks = total.looks + 1
            local moved = w.seconds - before - (running and LOOK or 0)
            if math.abs(moved) > 2 then
                -- the clock jumped in this look: it must be one skip of this module, of an amount that can be asked for
                skipped = skipped + 1
                if moved < 58 or moved > DAY + 4 then bad = bad or ("step " .. step .. ": the clock moved by " .. moved) end
                if step - lastMove < 2 then bad = bad or ("step " .. step .. ": two jumps of the clock within two looks") end
                lastMove = step
            end
            if S.skips - skipsBefore > 1 then bad = bad or ("step " .. step .. ": two skips counted in one look") end
            jobAge = S.job and jobAge + 1 or 0
            if jobAge > 6 then bad = bad or ("step " .. step .. ": a request is still under way after " .. jobAge .. " looks") end
            if #ue.errors > 0 or printed(ue, "update error") then bad = bad or ("step " .. step .. ": an error: " .. tostring(ue.errors[1] or printed(ue, "update error"))) end
        end
        if skipped ~= S.skips then bad = bad or ("the clock jumped " .. skipped .. " times, the module counts " .. S.skips .. " skips") end
        if S.broken then bad = bad or "the module gave up" end
        total.skips, total.refused = total.skips + S.skips, total.refused + S.refused
        if bad then check(false, "round " .. round .. " (" .. tostring(variant.skip or "ok") .. "): " .. bad) end
        stop(c)
    end
    check(total.skips > 100 and total.refused > 100, ("twelve rounds of 300 random looks (keys, buttons, console words, fights, pauses, cutscenes, map loads; four kinds of game): %d skips, %d not taken - "
        .. "every jump of the clock is one counted skip, never two close together, no request left hanging, no error"):format(total.skips, total.refused))
end

-- ---------------------------------------------------------------------------
section("15. through the megamod loader, with the real diagnostics")
do
    local TMP = T.TMP
    local root = TMP .. "/mega/G1R_MegaMod"
    T.sh("rm -rf " .. T.q(TMP .. "/mega") .. " && mkdir -p " .. T.q(root) .. " && cp -r " .. T.q(MOD .. "Scripts") .. " " .. T.q(root .. "/") .. " && mkdir -p " .. T.q(root .. "/modules")
        .. " && cp -r " .. T.q(MOD .. "modules/wait") .. " " .. T.q(root .. "/modules/"))
    -- only this module: the list of modules is cut down to it
    T.write(root .. "/Scripts/core/modules.lua", 'return { { name = "wait", switch = "Wait", separate = { "G1R_WaitOnT" } } }\n')
    T.write(root .. "/modules/wait/Scripts/config.lua", KEY_Y)

    local function boot()
        local ue = T.Mock.new()
        ue:install()
        local ui = T.widgets(ue)
        local world = newWorld(ue)
        local mods = T.shared()
        rawset(_G, "ModRef", mods)
        local ok, err = pcall(dofile, root .. "/Scripts/main.lua")
        local c = { ue = ue, ui = ui, world = world, mods = mods, ok = ok, err = err, dir = root .. "/Scripts/diagnostics" }
        function c.looks(n)
            for _ = 1, n do
                world.step(0.25)
                ue:advance(0.25)
                ue:tick()
            end
        end
        function c.gone() return world.seconds - START end
        return c
    end
    local function shutdown(c)
        c.ue:uninstall()
        rawset(_G, "ModRef", nil)
        rawset(_G, "StaticConstructObject", nil)
    end
    local function newest(c, prefix)
        local found
        local p = io.popen("ls " .. T.q(c.dir))
        -- (a session has three files: the log is the one meant by "session-")
        for name in p:lines() do if name:sub(1, #prefix) == prefix and (prefix ~= "session-" or name:sub(-4) == ".log") then found = name end end
        p:close()
        return T.read(c.dir .. "/" .. tostring(found)) or ""
    end
    local function last(c) return tostring(c.ue.printed[#c.ue.printed]):gsub("\n", "") end

    local c = boot()
    local ue, w = c.ue, c.world
    check(c.ok and has(last(c), "loaded: wait ok | diagnostics normal"), "the loader loads the module: " .. last(c))
    check(rawget(_G, "WAIT_TEST") == nil and rawget(_G, "G1R_KIT") == nil and rawget(_G, "G1R_SETTINGS") == nil, "the test hook stays inert; the kit and the settings service are no globals")
    check(printed(ue, "[G1R_Wait] v1.0.1 loaded: Y = 30 minutes\n") ~= nil and ue.calls.RegisterKeyBind == 1, "the module's load line; Y is registered")
    c.looks(4)
    check(ue:fireKey(89) == 1, "Y is pressed")
    c.looks(2)
    check(w.calls.SkipTime == 1 and c.gone() == 6 * LOOK + 1800 and #ue.errors == 0 and c.ui.note() == "30 minutes later - 14:30", "the skip is made as without the loader, the note is shown")
    check(ue:fireConsole("g1r diag") == true, "g1r diag handled")
    local report = T.read(c.dir .. "/report-latest.txt") or ""
    check(has(report, "wait: loaded, version 1.0.1") and has(report, "[wait] v1.0.1 | Y = 30 minutes")
        and has(report, "[wait] skips: 1; last: 30 minutes, day 4 14:00 -> day 4 14:30, by SkipTime with a plain value (seen at once)"), "report: the module's version and its status lines")
    check(has(report, "wait.key_press = seen") and has(report, "wait.clock = found") and has(report, "wait.states = readable") and has(report, "wait.clock_running = yes")
        and has(report, "wait.way = table") and has(report, "wait.applied = at once") and has(report, "wait.moved = as asked") and has(report, "kit.game_time_source = property")
        and has(report, "kit.toast = shown"), "report: the notes of the module and of the kit")
    check(has(report, "[wait] callbacks LoopInGameThreadWithDelay: 6 calls, 0 errors") and has(report, "[kit] lookups: 7 calls, 7 first-time, 0 not found"),
        "report: the module's loop and the kit's searches are counted (seven by path: the pause question and six for the note)")
    local log = newest(c, "session-")
    check(has(log, "[wait] first skip: 30 minutes, day 4 14:00 -> day 4 14:30, by SkipTime with a plain value (seen at once)") and has(log, "[wait] [G1R_Wait] v1.0.1 loaded: Y = 30 minutes")
        and has(log, "[wait] [G1R_Wait] skipped 30 minutes") and not has(log, "ERROR in "), "session log: the load line, the first skip, no error")
    check(has(log, "[wait] > first call: SkipTime with a plain value\n") and has(log, "[wait] first call returned: no error\n"),
        "session log: the first call of SkipTime is a breadcrumb (on disk before the call), followed by its return")
    check(ue:fireConsole("g1r dump") == true, "g1r dump handled")
    local okDump, dump = pcall(load(newest(c, "dump-"), "=dump", "t", {}))
    check(okDump and type(dump) == "table" and type(dump.wait) == "table" and dump.wait.skips == 1 and dump.wait.way == "table" and dump.wait.asked_by_key == 1
        and dump.wait.waits["short wait"].key == "Y" and dump._meta.refusedCount == 0, "dump: what the module holds")
    check(ue:fireConsole("g1r") == true and printed(ue, "[G1R_MegaMod] wait: loaded, version 1.0.1, 0 error(s), 7 note(s)") ~= nil, "g1r lists the module with its notes")
    -- the button and an edit through the loader's loop
    c.looks(8)
    local ctx = { mods = c.mods }
    T.menuSet(ctx, "Time", "The short wait skips", 20)
    T.menuSet(ctx, "Time", "Wait the short time now", true)
    c.looks(3)          -- the loader's own loop runs after the module's: the request is taken up one look later
    check(printed(ue, "[G1R_Wait] settings changed (in-game menu): Y = 20 minutes") ~= nil and w.calls.SkipTime == 2 and w.asked == 1200
        and has(T.read(root .. "/modules/wait/Scripts/config.lua"), "Config.ShortMinutes = 20\n"), "an edit and a button of the in-game menu reach the module through the loader's loop")
    check(ue:fireConsole("wait") == true and printed(ue, "[G1R_Wait] skips: 2; last: 20 minutes") ~= nil, "the module's own console command works beside the loader's")
    shutdown(c)

    -- the other author's mod is installed and enabled next to the megamod: the module is not loaded
    T.write(root .. "/modules/wait/Scripts/config.lua", KEY_Y)
    T.sh("mkdir -p " .. T.q(TMP .. "/mega/G1R_WaitOnT/Scripts"))
    T.write(TMP .. "/mega/G1R_WaitOnT/Scripts/main.lua", "-- another mod\n")
    T.write(TMP .. "/mega/G1R_WaitOnT/enabled.txt", "")
    c = boot()
    check(c.ok and has(last(c), "wait left to the separate mod G1R_WaitOnT")
        and printed(c.ue, "module wait not loaded: the separate mod G1R_WaitOnT is installed and enabled") ~= nil,
        "G1R_WaitOnT enabled next to the megamod: " .. last(c))
    c.looks(2)
    check((c.ue.calls.RegisterKeyBind or 0) == 0 and c.ue.console.wait == nil and c.mods.store["SMM:index"] == nil and c.world.reads() == 0,
        "no key is registered, no console word, no page in the in-game menu: one wait key at a time")
    shutdown(c)
    os.remove(TMP .. "/mega/G1R_WaitOnT/enabled.txt")
    c = boot()
    check(has(last(c), "wait ok"), "the same folder without enabled.txt and without a line in mods.txt: the module is loaded")
    shutdown(c)
    T.write(TMP .. "/mega/mods.txt", "G1R_WaitOnT : 1\r\n")
    c = boot()
    check(has(last(c), "wait left to the separate mod G1R_WaitOnT"), "enabled through mods.txt: not loaded")
    shutdown(c)
    os.remove(TMP .. "/mega/mods.txt")
    T.sh("rm -rf " .. T.q(TMP .. "/mega/G1R_WaitOnT"))

    -- switched off in the megamod's own settings
    T.write(root .. "/Scripts/config.lua", T.config("Config.Modules = { Wait = false }"))
    c = boot()
    check(has(last(c), "loaded: wait off |"), "Config.Modules.Wait = false: the module is not loaded")
    shutdown(c)

    -- diagnostics off: the module runs as on its own
    T.write(root .. "/Scripts/config.lua", T.config('Config.Diagnostics = { Level = "off" }'))
    c = boot()
    c.ue:fireKey(89)
    c.looks(2)
    check(printed(c.ue, "wait ok | diagnostics off") ~= nil and c.world.calls.SkipTime == 1 and c.gone() == 2 * LOOK + 1800 and #c.ue.errors == 0, "diagnostics off: the skip is made, no error")
    shutdown(c)

    -- a loader without its kit: the module says what it needs
    os.remove(root .. "/Scripts/core/kit.lua")
    c = boot()
    check(c.ok and printed(c.ue, "[G1R_MegaMod] core/kit.lua could not be used") ~= nil
        and printed(c.ue, "[G1R_Wait] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started") ~= nil,
        "core/kit.lua missing: the loader says so, the module says what it needs and does not start")
    check(has(last(c), "wait ok") and not has(table.concat(c.ue.printed), "failed to load"), "that is not an error of the module: " .. last(c))
    c.looks(4)
    check(c.world.calls.SkipTime == 0 and #c.ue.errors == 0, "and nothing is skipped, no error")
    shutdown(c)
end

T.finish()
