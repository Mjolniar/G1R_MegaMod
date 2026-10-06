-- Writes (or checks) the default config.lua of the modules that have a schema.lua:
--
--   lua5.4 dev/tools/gen_config.lua            write modules/*/Scripts/config.lua from schema.lua
--   lua5.4 dev/tools/gen_config.lua --check    only compare; exit code 1 when a file differs
--   lua5.4 dev/tools/gen_config.lua xp mage    only these modules
--
-- The text comes from Scripts/core/settings.lua (Settings.defaultText), the same code the game uses
-- when a module has no config.lua yet.
local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local MOD = HERE .. "../../"
G1R_KIT = dofile(MOD .. "Scripts/core/kit.lua")         -- the settings service asks the kit how keys are spelt
local Settings = dofile(MOD .. "Scripts/core/settings.lua")

local check, wanted = false, {}
for _, a in ipairs(arg) do
    if a == "--check" then check = true else wanted[#wanted + 1] = a end
end
if #wanted == 0 then
    local p = io.popen('ls "' .. MOD .. 'modules"')
    for name in p:lines() do wanted[#wanted + 1] = name end
    p:close()
end
local bad = 0
for _, name in ipairs(wanted) do
    local dir = MOD .. "modules/" .. name .. "/Scripts/"
    local chunk = loadfile(dir .. "schema.lua", "t", {})
    if chunk then
        local schema = chunk()
        local text, why = Settings.defaultText(schema)
        if not text then
            io.write(name, ": schema.lua is not usable: ", tostring(why), "\n")
            bad = bad + 1
        else
            local f = io.open(dir .. "config.lua", "rb")
            local have = f and f:read("a") or nil
            if f then f:close() end
            if have == text then
                io.write(name, ": config.lua is the default text of its schema\n")
            elseif check then
                io.write(name, ": config.lua DIFFERS from the default text of its schema\n")
                bad = bad + 1
            else
                f = assert(io.open(dir .. "config.lua", "wb"))
                f:write(text)
                f:close()
                io.write(name, ": config.lua written\n")
            end
        end
    end
end
os.exit(bad == 0 and 0 or 1)
