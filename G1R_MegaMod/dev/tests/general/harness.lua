-- ============================================================================
-- Offline tests of the module general (modules/general/Scripts/main.lua): the
-- settings for notes on screen, handed to the loader's kit.
--
--   lua5.4 harness.lua          (from any directory)
-- Last line: "general tests finished: N ok, M failure(s)"; exit code 0 / 1.
-- ============================================================================

local HERE = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local T = dofile(HERE .. "../lib/modtest.lua")
T.init("general")
local check, section, has, printed = T.check, T.section, T.has, T.printed

local function start(case, options)
    options = options or {}
    options.module, options.hook = "general", "GENERAL_TEST"
    return T.boot(case, options)
end
local shipped = T.read(T.MOD .. "modules/general/Scripts/config.lua")

section("1. loading with the shipped settings")
do
    local c = start("load", { widgets = true, diag = true })
    local ue, notes = c.ue, c.kit._test.notes
    check(c.ok and #ue.printed == 1 and ue.printed[1] == "[G1R_General] v1.1.0 loaded: notes in a box, top right, 3 s; gothic letters\n", "one load line: " .. tostring(ue.printed[1]):gsub("\n", ""))
    check(notes.style == "box" and notes.seconds == 3 and notes.position == "top right" and c.kit.letters() == "gothic", "the kit has the shipped note settings and letters")
    check(#ue.loops == 1 and #ue.lookups == 0 and (ue.calls.FindAllOf or 0) == 0 and (ue.calls.FindFirstOf or 0) == 0 and (ue.calls.RegisterHook or 0) == 0,
        "the module has no loop of its own, searches for nothing and hooks nothing")
    c.ticks(40)
    check((ue.calls.FindAllOf or 0) == 0 and #ue.lookups == 0 and c.world.reads[21] == nil and #ue.errors == 0, "it never looks at the game on its own")
    check(T.read(c.path) == shipped and c.settings.defaultText(dofile(T.MOD .. "modules/general/Scripts/schema.lua")) == shipped,
        "the shipped config.lua is what the schema generates, and is left as it is")
    check(c.fake.versions[1] == "1.1.0" and c.fake.status[1]()[1] == "v1.1.0 | notes in a box, top right, 3 s; gothic letters" and c.fake.dump[1]().note_style == "box"
        and c.fake.dump[1]().letters == "gothic", "version, status and dump for the diagnostics")
    T.stop(c)
end

section("2. the settings reach the kit: at load, from the file, from the in-game menu")
do
    local c = start("file", { widgets = true, config = T.config('Config.NoteStyle = "subtitle"\nConfig.NoteSeconds = 7\nConfig.NotePosition = "bottom left"') })
    local ue, notes = c.ue, c.kit._test.notes
    check(notes.style == "subtitle" and notes.seconds == 7 and notes.position == "bottom left" and printed(ue, "loaded: notes as the game's own line, 7 s") ~= nil, "a file with other values: handed to the kit at load")
    check(c.kit.notify("hello", "x") == true and #c.ui.subtitles == 1 and c.ui.subtitles[1].seconds == 7 and c.ui.created == 0, "a note is the game's own line, for 7 seconds")
    T.write(c.path, T.config('Config.NoteStyle = "off"'))
    c.ticks(20)
    check(notes.style == "off" and notes.seconds == 3 and printed(ue, "[G1R_General] settings changed (config.lua): notes off; gothic letters\n") ~= nil and c.kit.notify("hello", "x") == false,
        "the file changes while the game runs: picked up, said in the log; notes are off")
    T.menuSet(c, "General", "Notes are shown as", 1)
    T.menuSet(c, "General", "Corner of the box", 3)
    T.menuSet(c, "General", "A note stays for", 5)
    c.ticks(1)
    check(notes.style == "box" and notes.position == "bottom right" and notes.seconds == 5 and printed(ue, "settings changed (in-game menu): notes in a box, bottom right, 5 s") ~= nil,
        "three edits in the in-game menu: style and corner by their number, the seconds")
    local text = T.read(c.path)
    check(has(text, 'Config.NoteStyle = "box"\n') and has(text, 'Config.NotePosition = "bottom right"\n') and has(text, "Config.NoteSeconds = 5\n"), "and written into config.lua")
    check(c.kit.notify("boxed", "x") == true and c.ui.note() == "boxed" and c.ui.last("SetAnchors").args[1].Minimum.X == 1 and c.ui.last("SetAnchors").args[1].Minimum.Y == 1, "the next note is a box in the bottom right corner")
    -- the button of the in-game menu
    local page = T.menuPage(c, "General")
    check(#page.sections == 2 and page.sections[1].title == "Notes on screen" and page.sections[2].title == "Letters" and #page.items == 5 and page.items[4].kind == "action"
        and page.items[4].name == "Show a note now" and page.items[5].name == "Letters of the mod's texts" and page.items[5].kind == "num" and page.items[5].max == 3,
        "the page General of the in-game menu: three settings and a button, and the letters (1 to 3)")
    c.kit.hideToast()
    T.menuSet(c, "General", "Show a note now", true)
    c.ticks(1)
    check(c.ui.note() == "This is how a note looks", "the button shows a note")
    T.menuSet(c, "General", "Notes are shown as", 3)
    T.menuSet(c, "General", "Show a note now", true)
    c.ticks(1)
    check(notes.style == "off" and c.ui.note() == nil and printed(ue, "the note could not be shown") == nil, "with notes off the button shows nothing and that is no problem to report")
    T.stop(c)

    -- the letters: handed to the kit at load, from the file and from the in-game menu
    c = start("letters", { widgets = true, config = T.config('Config.Letters = "book"') })
    check(c.kit.letters() == "book" and printed(c.ue, "loaded: notes in a box, top right, 3 s; book letters") ~= nil, "letters from the file at load: book")
    T.write(c.path, T.config('Config.Letters = "plain"'))
    c.ticks(20)
    check(c.kit.letters() == "plain" and printed(c.ue, "settings changed (config.lua): notes in a box, top right, 3 s; plain letters") ~= nil, "changed in the file: plain")
    T.menuSet(c, "General", "Letters of the mod's texts", 1)
    c.ticks(1)
    check(c.kit.letters() == "gothic" and has(T.read(c.path), 'Config.Letters = "gothic"\n'), "the in-game menu: 1 = gothic, written into config.lua")
    T.stop(c)
    c = start("letters-bad", { config = T.config('Config.Letters = "fraktur"') })
    check(c.kit.letters() == "gothic" and printed(c.ue, "Letters = fraktur is not usable") ~= nil, "letters that are not one of the three: gothic, said in the log")
    T.stop(c)

    c = start("no-hero", { widgets = true, prepare = function(ue2) return T.newWorld(ue2, { noController = true }) end })
    T.menuSet(c, "General", "Show a note now", true)
    c.ticks(1)
    check(printed(c.ue, "[G1R_General] the note could not be shown (no game loaded?)\n") ~= nil and #c.ue.errors == 0, "the button without a game loaded: said in the log")
    T.stop(c)
    c = start("bad", { config = T.config('Config.NoteStyle = "banner"\nConfig.NoteSeconds = 99') })
    check(c.kit._test.notes.style == "box" and c.kit._test.notes.seconds == 10 and printed(c.ue, "NoteStyle = banner is not usable") ~= nil, "values that are not usable: the default style, the upper end of the seconds; said in the log")
    T.stop(c)
    c = start("no-schema", { files = { ["Scripts/schema.lua"] = false } })
    check(c.ok and printed(c.ue, "the settings could not be set up (schema.lua could not be read") ~= nil, "without schema.lua the module says so and does not start")
    T.stop(c)
end

section("3. nothing leaks")
do
    local known = {}
    local probe = T.Mock.new()
    probe:install()
    for k in pairs(_G) do known[k] = true end
    probe:uninstall()
    local given = { GENERAL_TEST = true, ModRef = true, G1R_KIT = true, G1R_SETTINGS = true, G1R_DIAG = true, Key = true, ModifierKey = true, StaticConstructObject = true }
    local c = start("leak", { widgets = true })
    c.ticks(8)
    local leaked = {}
    for k in pairs(_G) do
        if not known[k] and not given[k] then leaked[#leaked + 1] = tostring(k) end
    end
    T.stop(c)
    check(#leaked == 0, "the module defines no global (" .. table.concat(leaked, ", ") .. ")")
    local p = io.popen("ls -A " .. T.q(c.dir))
    local listing = p:read("a"):gsub("%s+", " ")
    p:close()
    -- (config.lua.bak is the settings layer's: the file before the last change, as the settings app keeps it)
    check(listing:gsub("config%.lua%.bak ", "") == "config.lua main.lua schema.lua ", "the module writes no file of its own (its folder holds: " .. listing .. ")")
end

T.finish()
