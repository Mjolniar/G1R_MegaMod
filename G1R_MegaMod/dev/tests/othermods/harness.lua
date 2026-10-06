-- ============================================================================
-- Offline tests of the module othermods (modules/othermods/Scripts/main.lua).
--
--   lua5.4 harness.lua          (from any directory)
--
-- The module runs on the loader's kit and settings service (../lib/modtest.lua,
-- ../mock/ue4ss.lua). A Mods folder of the tests holds the two other mods'
-- settings files as they are on the PC (dev/facts/othermods.md OM1, OM2);
-- G1R_MODS is the loader's look at it.
-- Last line: "othermods tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*/)") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("othermods")
local check, section, printed, printedCount = T.check, T.section, T.printed, T.printedCount
local NL = string.char(10)

local MODSDIR = T.TMP .. "/Mods"
local FNP = "PLuaModLoader/Scripts/Mods/FocusNearbyPickups/FocusNearbyPickups.ini"
local APU = "G1R_AutoPickUpItemNative/G1R_AutoPickUpItemNative.ini"
local FILES = {
    [FNP] = table.concat({ "toggleKey=F6", "viewHalfAngleDeg=35.0", "", "actionThicknessMult=2.69", "maxRadius=1000.0", "removeOutlines=true", "" }, NL),
    [APU] = table.concat({ "; AreaLootingRadius: Collection radius; 100 is about one metre", "", "AreaLootingRadius=500", "AreaLootingAreaAware=true", "" }, NL),
}
local function writeMods(changes)
    T.sh("rm -rf " .. T.q(MODSDIR) .. " && mkdir -p " .. T.q(MODSDIR))
    local files = {}
    for path, text in pairs(FILES) do files[path] = text end
    for path, text in pairs(changes or {}) do files[path] = text end
    for path, text in pairs(files) do
        if text then
            local dir = (MODSDIR .. "/" .. path):match("^(.*)/[^/]*$")
            T.sh("mkdir -p " .. T.q(dir))
            T.write(MODSDIR .. "/" .. path, text)
        end
    end
end
local function boot(case, config, mods, o)
    o = o or {}
    writeMods(mods)
    if o.noMods then rawset(_G, "G1R_MODS", nil) else rawset(_G, "G1R_MODS", { folder = MODSDIR, runs = function() return true end }) end
    return T.boot(case, { module = "othermods", hook = "OTHERMODS_TEST", config = config, diag = o.diag ~= false })
end
local function stop(c)
    rawset(_G, "G1R_MODS", nil)
    T.stop(c)
end
local function cfg(lines) return T.config(table.concat(lines, NL)) end
local function status(c) return table.concat(c.hook.status(), " | ") end

section("load: the shipped settings leave the files alone")
do
    local before = { T.read(MODSDIR .. "/" .. FNP) }
    local c = boot("load")
    check(c.ok and printed(c.ue, "[G1R_OtherMods] v1.0.0 loaded: highlight as the mod has it, loot as the mod has it") ~= nil, "load line: " .. tostring(printed(c.ue, "loaded:")))
    check(c.ue.console.othermods ~= nil and c.ue.console.g1r_othermods ~= nil and #c.ue.loops == 1, "console words registered; no loop of its own")
    local index = c.mods.store["SMM:index"]
    check(index == nil or not T.has(index, "Other mods"), "not in the in-game menu")
    check(c.fake.value("othermods.highlight_file") == "1000.0" and c.fake.detail("othermods.highlight_file") == "FocusNearbyPickups"
        and c.fake.value("othermods.loot_file") == "500" and c.fake.detail("othermods.loot_file") == "G1R_AutoPickUpItemNative", "noted: what the two files hold")
    check(T.searches(c) == 0 and #c.ue.lookups == 0 and printed(c.ue, "reads") == nil, "the game is not looked at; nothing to say")
    check(T.read(MODSDIR .. "/" .. FNP) == FILES[FNP] and T.read(MODSDIR .. "/" .. APU) == FILES[APU] and before[1] == nil, "the files are left as they are")
    check(status(c) == "v1.0.0 | highlight as the mod has it, loot as the mod has it | FocusNearbyPickups reads maxRadius = 1000 (10.0 m) | G1R_AutoPickUpItemNative reads AreaLootingRadius = 500 (5.0 m)",
        "status: " .. status(c))
    stop(c)
end

section("the settings ask for other values")
do
    local c = boot("other", cfg({ "Config.SetHighlight = true", "Config.HighlightMeters = 15", "Config.SetLoot = true", "Config.LootMeters = 5" }))
    check(printed(c.ue, "loaded: highlight 15.0 m, loot 5.0 m") ~= nil, "load line names the distances")
    check(printedCount(c.ue, "FocusNearbyPickups reads maxRadius = 1000 (10.0 m) when the game starts; the setting asks for 15.0 m: the settings app writes it when it saves with the game closed") == 1,
        "a distance the file does not hold yet: said once")
    check(printed(c.ue, "G1R_AutoPickUpItemNative reads") == nil, "one the file holds already: nothing to say")
    check(T.read(MODSDIR .. "/" .. FNP) == FILES[FNP], "the module does not write the file")
    T.write(c.path, cfg({ "Config.SetHighlight = true", "Config.HighlightMeters = 0", "Config.SetLoot = true", "Config.LootMeters = 7.5" }))
    c.seconds(6)
    check(printed(c.ue, "settings changed (config.lua): highlight 0.0 m, loot 7.5 m") ~= nil, "a change is said")
    check(printed(c.ue, "the setting asks for 0.0 m") ~= nil and printed(c.ue, "G1R_AutoPickUpItemNative reads AreaLootingRadius = 500 (5.0 m) when the game starts; the setting asks for 7.5 m") ~= nil,
        "and the files are looked at again")
    stop(c)

    c = boot("close", cfg({ "Config.SetHighlight = true", "Config.HighlightMeters = 10" }), { [FNP] = "maxRadius=1000.4" .. NL })
    check(printed(c.ue, "reads maxRadius") == nil, "a value within half a centimetre is the same")
    stop(c)
    c = boot("half", cfg({ "Config.SetHighlight = true", "Config.HighlightMeters = 10" }), { [FNP] = "maxRadius=1000.5" .. NL })
    check(printed(c.ue, "reads maxRadius = 1000.5") ~= nil, "half a centimetre off: another value")
    stop(c)
end

section("what cannot be read")
do
    local c = boot("missing", cfg({ "Config.SetHighlight = true", "Config.SetLoot = true" }), { [APU] = false, [FNP] = "maxRadius=far" .. NL })
    check(c.fake.value("othermods.loot_file") == "not readable" and c.fake.detail("othermods.loot_file") == "its settings file is not there"
        and printedCount(c.ue, "G1R_AutoPickUpItemNative: its settings file is not there - the setting cannot be checked") == 1, "a file that is not there: noted, said once")
    check(c.fake.value("othermods.highlight_file") == "not readable" and c.fake.detail("othermods.highlight_file") == "the file has no number for maxRadius"
        and printed(c.ue, "FocusNearbyPickups: the file has no number for maxRadius") ~= nil, "a value that is no number: the same")
    check(T.has(status(c), "G1R_AutoPickUpItemNative reads nothing (its file or the key is not there)"), "status says so")
    stop(c)
    c = boot("nomods", cfg({ "Config.SetLoot = true" }), nil, { noMods = true })
    check(c.ok and c.fake.detail("othermods.loot_file") == "the loader does not say where the other mods are", "without the loader's look at the Mods folder: said")
    stop(c)
    c = boot("off", cfg({ "Config.Enabled = false", "Config.SetLoot = true", "Config.LootMeters = 9" }))
    check(printed(c.ue, "loaded: switched off") ~= nil and printed(c.ue, "reads AreaLootingRadius") == nil, "switched off: nothing is asked of the files")
    stop(c)
    -- the key only in a comment, then for real; spaces around the =
    c = boot("comment", cfg({ "Config.SetLoot = true", "Config.LootMeters = 6" }), { [APU] = "; AreaLootingRadius=900" .. NL .. "  AreaLootingRadius = 450  " .. NL })
    check(c.fake.value("othermods.loot_file") == "450", "a key in a comment is not the key; spaces around the value do not count")
    stop(c)
end

section("console and diagnostics")
do
    local c = boot("console", cfg({ "Config.SetLoot = true", "Config.LootMeters = 6" }))
    T.write(MODSDIR .. "/" .. APU, "AreaLootingRadius=600" .. NL)
    check(c.ue:fireConsole("othermods") == true and c.ue.device.lines[3] == "[G1R_OtherMods] G1R_AutoPickUpItemNative reads AreaLootingRadius = 600 (6.0 m)",
        "console: the files are looked at again and the status said (" .. tostring(c.ue.device.lines[3]) .. ")")
    local handler = c.ue.console.othermods[1]
    local before = #c.ue.printed
    check(handler("othermods", { "reload" }, nil) == true and T.has(c.ue.printed[before + 1], "settings read: highlight as the mod has it, loot 6.0 m"), "parameters: reload")
    before = #c.ue.printed
    check(handler("othermods reload", nil, nil) == true and T.has(c.ue.printed[before + 1], "settings read: "), "no parameters: the words of the whole line")
    before = #c.ue.printed
    check(handler("othermods", nil, nil) == true and T.has(c.ue.printed[before + 1], "[G1R_OtherMods] v1.0.0 | "), "no parameters, no word: the status")
    check(#c.fake.versions == 1 and c.fake.versions[1] == "1.0.0" and #c.fake.status == 1 and #c.fake.dump == 1, "version, status and dump handed to the diagnostics")
    local d = c.fake.dump[1]()
    check(d.version == "1.0.0" and d.set_loot == true and d.loot_metres == 6 and d.loot_file == 600 and d.highlight_file == 1000 and d.set_highlight == false, "the dump")
    stop(c)
    c = boot("nodiag", nil, nil, { diag = false })
    check(c.ok and printed(c.ue, "loaded:") ~= nil, "without diagnostics it loads the same")
    stop(c)
end

section("load: without the loader, a schema that cannot be used")
do
    local ue = T.Mock.new()
    ue:install()
    local ok = pcall(dofile, T.MOD .. "modules/othermods/Scripts/main.lua")
    check(ok and T.printed(ue, "[G1R_OtherMods] this module needs the loader of G1R_MegaMod") ~= nil, "started on its own: says so")
    ue:uninstall()
    ue = T.Mock.new()
    ue:install()
    rawset(_G, "G1R_KIT", {})
    ok = pcall(dofile, T.MOD .. "modules/othermods/Scripts/main.lua")
    check(ok and T.printed(ue, "[G1R_OtherMods] this module needs the loader of G1R_MegaMod") ~= nil, "the kit alone: the same")
    rawset(_G, "G1R_KIT", nil)
    ue:uninstall()
    writeMods()
    rawset(_G, "G1R_MODS", { folder = MODSDIR, runs = function() return true end })
    local c = T.boot("badschema", { module = "othermods", hook = "OTHERMODS_TEST", diag = true, files = { ["Scripts/schema.lua"] = "return 5" .. NL } })
    check(c.ok and printed(c.ue, "[G1R_OtherMods] the settings could not be set up (") ~= nil and c.ue.console.othermods == nil, "a schema that cannot be used: said, nothing registered")
    stop(c)
end

T.finish()
