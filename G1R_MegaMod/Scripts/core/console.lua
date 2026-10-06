-- ============================================================================
-- Console command "g1r" (UE4SS console / in-game console):
--   g1r          status: one line per module (plus the lines the module
--                gives) and the state of the diagnostics
--   g1r diag     writes a diagnostics report and shows where it is
--   g1r dump     writes what the modules know (their dump providers) to a file
--   g1r help     this list
-- The answers go to UE4SS.log. The modules keep their own commands.
-- ============================================================================

local Console = {}

local type, tostring, pcall, ipairs = type, tostring, pcall, ipairs

local HELP = {
    "commands:",
    "  g1r          status of the modules and of the diagnostics",
    "  g1r diag     write a diagnostics report (Scripts/diagnostics/report-<date>-<time>.txt)",
    "  g1r dump     write the modules' state to a file (Scripts/diagnostics/dump-<date>-<time>.lua)",
    "  g1r help     this list",
}

-- diag: the diagnostics core (or the loader's stand-in); out: function(text)
-- that writes one line to the log. Returns the handler UE4SS calls with
-- (full command, list of the words after the command, output device).
function Console.handler(diag, out)
    local function answer(fullCommand, parameters)
        local words = {}
        if type(parameters) == "table" then
            for _, p in ipairs(parameters) do words[#words + 1] = tostring(p) end
        elseif type(fullCommand) == "string" then
            for w in fullCommand:gmatch("%S+") do words[#words + 1] = w end
            table.remove(words, 1)
        end
        local word = (words[1] or "status"):lower()
        if word == "status" then
            for _, l in ipairs(diag.status()) do out(l) end
        elseif word == "diag" or word == "report" then
            local path, inMod = diag.report(true)
            if path then out("report written: " .. tostring(inMod))
            else out("no report written: " .. tostring(inMod or "unknown reason")) end
        elseif word == "dump" then
            local path, inMod = diag.dump()
            if path then out("dump written: " .. tostring(inMod))
            else out("no dump written: " .. tostring(inMod or "unknown reason")) end
        elseif word == "help" or word == "?" then
            for _, l in ipairs(HELP) do out(l) end
        else
            out("unknown command '" .. word .. "'")
            for _, l in ipairs(HELP) do out(l) end
        end
    end
    return function(fullCommand, parameters)
        local ok, err = pcall(answer, fullCommand, parameters)
        if not ok then pcall(out, "console command failed: " .. tostring(err)) end
        return true   -- the command is ours; UE4SS expects true or false
    end
end

-- Registers the command. Returns true, or false and the reason.
function Console.register(diag, out)
    if type(RegisterConsoleCommandHandler) ~= "function" then
        return false, "this UE4SS build has no RegisterConsoleCommandHandler"
    end
    local ok, err = pcall(RegisterConsoleCommandHandler, "g1r", Console.handler(diag, out))
    if not ok then return false, tostring(err) end
    return true
end

return Console
