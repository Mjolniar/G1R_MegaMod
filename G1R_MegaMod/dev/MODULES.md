# Writing a module

A module is one feature of the mod in a folder of its own: `modules/<name>/Scripts/main.lua` with its settings
(`schema.lua`, `config.lua`) and a `README.txt`, a test suite in `dev/tests/<name>/harness.lua` and a facts file
`dev/facts/<name>.md`. The loader runs it in an environment of its own and gives it these things:

| Global | What | Reference |
|---|---|---|
| `G1R_KIT` | access to the game: guarded calls, searches that never repeat, the hero, keys, notes on screen | section 3 |
| `G1R_SETTINGS` | the module's settings: file, settings app, in-game menu | `dev/SETTINGS.md` |
| `G1R_DIAG` | the recorder (nil when the diagnostics are off) | `dev/AI_GUIDE.md` section 5 |
| `G1R_MODS` | the other mods: `folder` (the Mods folder, for reading their settings files) and `runs(name)` (UE4SS starts that mod: the loader's read-only look, as for `separate`) | `Scripts/main.lua` |

`modules/xp` (one value of the hero, watched and changed) and `modules/general` (settings only) are the worked
examples; `dev/tests/xp/harness.lua` shows what a suite covers. Read `dev/AI_GUIDE.md` and `dev/FACTS.md` first:
**nobody can run the game while writing this**, and one careless object search has crashed it before.

## 1. What every module does

1. **Every feature is a setting.** A switch for each thing the module does, a number with a sensible range for each
   amount. The shipped defaults leave the game as it is (a multiplier of 1, a bonus of 0): installing the mod
   changes nothing until the player sets something. Settings the player rarely needs are `Hidden`. A setting that
   makes the game easier or harder names its value in the five presets of the settings app (`Tiers`, dev/SETTINGS.md
   section 7); the suite `presets` asks for that decision for every setting of a module that has presets.
2. **Settings take effect while the game runs**, from the file, the settings app and the in-game menu alike, and
   never change what the player already has (no retroactive effect on a save). What a setting changed in the
   game's own data is put back when the setting goes back.
3. **Idle when neutral.** With `Enabled = false`, or with every feature at its neutral value, the module does not
   look at the game at all: no search, no property read, no hook that was not registered yet. The loop still
   runs; its first line returns.
4. **Nothing while a map loads or the game is paused**: `if KIT.loading() then return end` first in the loop;
   `KIT.paused()` where time must not pass in a menu.
5. **Searches go through the kit** (`findOnce`, `findClass`, `findDefault`, `subsystem`, `hookOnce`,
   `attributeSet`), which keeps every answer by path, found or not (FACTS U1, U2), and asks the engine where the
   engine can be asked (FACTS U14, U17). A module never calls `StaticFindObject`, `FindFirstOf`, `FindAllOf`,
   `RegisterHook` or `RegisterKeyBind` itself. A subsystem of the game is asked with `KIT.subsystem(kind, class,
   place)`, not searched with `firstOf`. The one exception is a `FindAllOf` the module cannot do without: only
   after the game's own lists gave nothing, spaced out by seconds, never per frame, counted in the harness.
6. **Objects of the game are asked for each time, not kept.** What the kit hands out (`controller`, `playerState`,
   `subsystem`, `attributeSet`) is fresh or checked on every call - ask the kit at every look instead of keeping
   the object. A wrapper the module keeps from one look to the next for an object the game can destroy is not
   made safe by `KIT.valid(o)` and a comparison of its full name (FACTS U5, U15 - U17); where that is all there is,
   do both before every use and drop everything at a map load (`KIT.onWorldChange`).
7. **Every call into the game is guarded** (`KIT.get`, `KIT.call`, `KIT.try`, or `pcall`). A callback never lets an
   error out. A write is read back (`KIT.writeAttribute` does it); when it did not stay, the module says so once
   and leaves the game's value alone.
8. **Never index an array property at or past its length** (it grows the game's array, FACTS U6): `KIT.each`,
   `KIT.count`.
9. **A hook does as little as possible**: read its parameters, note what is needed, return. The work happens in
   the module's loop. Hook only functions the facts file names with their source; never one that runs every frame.
10. **One loop** (`LoopInGameThreadWithDelay`), at the slowest rate that does the job (250 ms is the usual).
11. **Logging**: one load line (`v<version> loaded: <what is on>`), a line when settings change, a line **once**
    for each kind of problem (`L.once`). Lines for single events only behind a `Log...` setting.
12. **Diagnostics**: `DIAG.version`, `DIAG.status` (the lines of the console command, built from what the module
    holds - no call into the game), `DIAG.dump`, and a `DIAG.note` for every assumption about the game, made when
    its value changes (not at every look). Each note key is a row in the module's facts file.
13. **Another mod that does the same job**: the loader does not load the module while that mod's folder is
    installed and enabled (`separate` in `Scripts/core/modules.lua`). When the other mod can be recognised while
    running (a shared variable, a registration), the module stands down for the rest of the run instead of acting
    twice.
14. **No global variables, plain ASCII, no personal paths, no file written** except through the settings service.
    The lint (`python3 dev/tools/lint.py`) checks this.
15. **A console command** named after the module (`xp`) and `g1r_<name>`: without a word the status, `reload`
    reads the settings now. The handler returns `true`.
16. **A test hook**: `if type(rawget(_G, "<NAME>_TEST")) == "table" then ... end` at the end hands the tests the
    module's state and functions. Inert in the game.

## 2. The skeleton

    local VERSION = "1.0.0"
    local TAG = "G1R_Thing"

    local KIT, SETTINGS = G1R_KIT, G1R_SETTINGS
    local DIAG = G1R_DIAG                       -- nil when the diagnostics are off; every use behind `if DIAG`
    if type(KIT) ~= "table" or type(SETTINGS) ~= "table" then
        print("[" .. TAG .. "] this module needs the loader of G1R_MegaMod (its kit and its settings service); not started\n")
        return
    end
    if DIAG then pcall(DIAG.version, VERSION) end

    local L = KIT.logger(TAG, print)            -- print: the module's own, so the lines are recorded as its own
    local log = L.log
    local SCRIPT_DIR = ...                      -- the folder of this file, with "/" at the end (see modules/xp)

    local Settings, problem = SETTINGS.open({ module = "thing", dir = SCRIPT_DIR, log = log })
    if not Settings then
        log("the settings could not be set up (" .. tostring(problem) .. "); not started")
        return
    end
    local Cfg = Settings.values                 -- always complete and in range; read it where the value is needed

    local function idle() return not Cfg.Enabled or (Cfg.Amount == 0 and not Cfg.Other) end
    Settings.onChange = function(values, changedKeys, why) ... end      -- put back what a setting had changed
    Settings.onAction = function(key) ... end                           -- a button of the in-game menu

    local function tick()
        if KIT.loading() then return end
        if idle() then return end
        ...
    end

    for _, name in ipairs({ "thing", "g1r_thing" }) do
        if type(RegisterConsoleCommandHandler) == "function" then pcall(RegisterConsoleCommandHandler, name, console) end
    end
    if type(LoopInGameThreadWithDelay) ~= "function" then
        log("FATAL: this UE4SS build lacks LoopInGameThreadWithDelay; <the feature> is disabled.")
        return
    end
    LoopInGameThreadWithDelay(250, function()
        local ok, err = pcall(tick)
        if not ok then L.once("tick:" .. tostring(err), "update error: " .. tostring(err)) end
    end)
    log(("v%s loaded: %s"):format(VERSION, summary()))

## 3. The kit (`G1R_KIT`)

Nothing in the kit raises. `nil` / `false` means "not now" - try again at the next look.

| Function | What it gives |
|---|---|
| `valid(o)` | true for an object that says it exists |
| `gone(o)` | true for a wrapper whose object is gone (structs and plain values pass) |
| `get(o, "Prop")` | the property, or nil (no object, gone, the read raised) |
| `call(o, "Fn", ...)` | the function's first result, or nil |
| `try(o, "Fn", ...)` | `true, result` or `false, reason` - when it matters whether the call worked |
| `fullName(o)`, `classToken(o)` | `"Class /Path.Object"` and its first word |
| `unwrap(e)` | the value behind an array / map element (`e:get()`), or `e` itself |
| `number(v)` | `v` when it is a finite number, else nil |
| `each(array, f)`, `count(array)` | `f(value, index)` for every element (return true to stop); the length |
| `findOnce(path)` | `StaticFindObject`, once per path and run |
| `findClass(name, place)`, `findDefault(name, place)` | a class / its default object; `place`: `"G1R"` (native), `"Angelscript"` (the game's scripts), `"Engine"`, `"UMG"` - give it: every wrong place costs a walk through all objects |
| `subsystem(kind, class, place)` | a subsystem, asked from the engine: `kind` = `"world"`, `"instance"` (of the game instance) or `"state"` (the game's own game-state subsystems: clock, quests, weather); used for 5 s, then asked again. Without the engine object, or while this way has not answered once in the run (10 s), `firstOf` does the work |
| `firstOf(class)` | the first live object of a class, by a search among all objects; kept and checked, searched at most every 3 s. For what the engine cannot hand out |
| `engine()`, `gameInstance()` | the engine object (handed to the kit at a map load, never searched for) and the game instance, or nil |
| `keepAlive(object)` | puts an object the module made itself (an imported picture) on the game instance's list of referenced objects, reads it back -> `true`, or `false, reason`. It then lives until the game is closed: only for the few things made once per run |
| `warm(paths)` | looks paths up now that would otherwise be looked up at their first use -> how many are known. Call it from `KIT.onWorldChange` at a map load, not when the module is loaded |
| `hookOnce(path, pre, post)` | `RegisterHook` once per path and run -> `true`, or `false, reason`; can be called when a setting is first switched on |
| `controller()`, `playerState()`, `pawn()`, `world()` | the hero's objects (playerState also returns its full name). The controller is asked from the engine anew at every look; `world()` is the world the game shows |
| `attributeSet(part)` | the hero's `AttributeSet_<part>` object, how it was found, when |
| `attributeSetOf(state, part)` | the `AttributeSet_<part>` of another character's state (an NPC, the scavenger) and its full name, from that state's own list - asked anew at every call |
| `readAttribute(set, name)` | current value, base value |
| `writeAttribute(set, name, value)` | writes both and reads back -> `true`, or `false, reason` |
| `attribute(part, name)` | current value, base value, the set - in one call |
| `onWorldChange(f)` | `f("before")` / `f("after")` around a map load: drop what you kept |
| `loading()` | true between the two (at most 20 s) |
| `paused()` | true while the engine says the game is paused |
| `gameSeconds()` | the game's clock in game seconds (86400 a day; jumps when the hero sleeps; whether it stands still in the game's menus is not known - K5, K6) |
| `keyCombo(text)` | `"ctrl+y"` -> `"CTRL+Y"`, key code, modifier codes; nil and why for no key |
| `bindKey(id, text, action, cooldown)` | runs `action` on the game thread when the key is pressed; call again with the id to move it to another key (`""` = none) -> `true, usual spelling` or `false, reason` |
| `describeKey(id, label)` / `keyList()` | what a binding does, in a few words (a text or a function asked when the list is made), for the list of keys; `keyList()` = the bindings that have a key: `{ id, key, label }` |
| `notify(text, slot, seconds)` | a short note the way the player chose on the page "General" (box, the game's own line, off); `slot`: the module's name, so that its next note replaces this one |
| `prepareNotes()` | does the searches a note needs; call it once when the hero was found, not in a fight |
| `panel(id, options)` | a box of lines of the module's own in the notes' look (`position`, `dx`, `dy`, `z` = layer, `size` = the letters, 6-40, default 12): `.show(lines)`, `.hide()`, `.resize(n)` (built anew at the next show), `.available()`; built when first shown, again after a map change |
| `logger(tag, print)` | `{ log(text), once(key, text) }` |
| `clock()` | seconds (os.clock) |

Hero attributes (property layout, `AttributeSet_<part>`): Health (`Health`, `MaxHealth`), Mana (`Mana`, `MaxMana`,
`MagicianLevel`), LevelProgression (`Level`, `Experience`, `SkillPoints` ...), Strength, Dexterity, Lockpicking,
Pickpocketing, Fatigue, Oxygen, Sleep, Armor, Movement, Alcohol, Swampweed. Each attribute is a
`GameplayAttributeData` with `BaseValue` and `CurrentValue`. Writing both is known to stick for `Experience`
(FACTS X3); a direct write does not run the game's own reactions to a change (X4).

## 4. Settings

`schema.lua` describes them once (`dev/SETTINGS.md`): the default `config.lua` (`lua5.4 dev/tools/gen_config.lua
<name>` writes it; the tests check that the shipped file is that text), the page in the settings app and the entry in
the in-game menu come from it. Pages and where a module's groups go:

| Page (`Schema.Page`) | `PageOrder` | Modules, and the `Order` of their groups |
|---|---|---|
| General | 5 | general |
| Combat | 10 | regen 10 - 29 (mana, health), magic 30 - 59, melee 60 - 79 |
| Resources | 20 | mining 10 - 29 |
| Experience | 30 | xp |
| Lock picking | 40 | locks |
| Time | 50 | wait |
| Mount | 11 | mount |

- The first item of a module is `Enabled` (a switch for the whole module, default `true`); features have their own
  switch or a neutral number; items that depend on a switch name it in `Needs`.
- `Label`: what stands in front of the control, as a player would say it ("Every gain counts", unit "times").
  `Comment`: the lines above the value in config.lua; write the first sentence so that it stands alone - it is
  the hint in the in-game menu.
- A key the player presses: `Kind = "key"` (`Default = "Y"`, `"CTRL+F5"`, `""` for none), bound with
  `KIT.bindKey("<module>.<what>", Cfg.Key, action)` at load and again in `onChange` when that key changed, and
  described once with `KIT.describeKey(id, "what it does")` for the list of keys (module keys).
- Something to do now: `Kind = "action"` (a button in the in-game menu), handled in `Settings.onAction`.
- Notes on screen: one switch per module (`ShowMessage`), shown with `KIT.notify(text, "<module>")`. How notes
  look is the player's choice on the page General.
- Groups of one module on a shared page start their titles with the feature ("Mana regeneration", "Health
  regeneration"), because groups of several modules stand next to each other.

## 5. Tests (`dev/tests/<name>/harness.lua`)

`dev/tests/lib/modtest.lua` loads the kit and the settings service the way the loader does, installs the UE4SS mock
and a small game model (controller -> player state -> ability system -> attribute sets, widgets, shared variables)
and runs the module:

    local T = dofile(HERE .. "../lib/modtest.lua")
    T.init("thing")
    local c = T.boot("case", { module = "thing", hook = "THING_TEST", config = T.config("Config.Amount = 2"), widgets = true, diag = true })
    c.ticks(4)                 c.seconds(10)            -- looks a quarter second apart
    c.world.add("Mana", -5)    c.world.value("Mana")    -- the game changes / holds a value
    c.press("CTRL+Y")                                   -- a key, as UE4SS delivers it; the action runs at the next tick
    T.menuSet(c, "Combat", "Mana per tick", 3)          -- an edit in the in-game menu (by the item's label)
    c.ui.note()   c.ui.subtitles                        -- what is on screen
    c.fake.value("thing.key")                           -- diagnostics notes (with diag = true)
    c.ue.calls.FindAllOf   #c.ue.lookups   c.world.reads   -- what was asked of the game: count it
    T.stop(c)
    T.finish()

Extend the model in the harness for what the module needs (`prepare = function(ue) local w = T.newWorld(ue) ...
return w end`), and say in a comment where each modelled behaviour is known from. A suite covers at least:

- loading with the shipped settings: the load line, nothing searched, nothing read, the game untouched;
- every feature doing its job, with the numbers checked by hand;
- every setting: off / neutral / the ends of its range / changed while running (file and in-game menu) and what
  that does to a game in progress; switching off puts back what was changed;
- what must never happen: acting during a map load or a pause, twice on the same thing, on another object than
  the hero's, on stale or replaced objects, after another mod took the job;
- things that are missing or fail: a class not found, a function that raises, a write that does not stay - said
  once, no error out, no search repeated (count them);
- cost: how many searches and reads per minute while idle (0) and while working;
- the diagnostics: each note with its value, made once; status and dump built without touching the game;
- nothing leaks into `_G`, no file but config.lua is written;
- the shipped `config.lua` equals `Settings.defaultText(schema)`.

Then break the code on purpose: `python3 dev/tools/mutate.py modules/<name>/Scripts/main.lua --suite <name>` lists
changes the suite does not notice. Add a check for each, or explain it in
`dev/tests/<name>/mutations_accepted.txt` (see the xp one). A model that is kinder than the game hides defects:
when the real API can fail in a way the model cannot, add that way to the model.

## 6. Facts (`dev/facts/<name>.md`)

    # Facts: module <name>

    | # | What | Where | Status | Note key |
    |---|---|---|---|---|
    | T1 | <what the code assumes about the game> | `main.lua` `function` | SOURCE (<where it is from>) | `thing.key` |

    ## Diagnostics notes

    | Note key | Expected | If it differs / what it settles |
    |---|---|---|
    | `thing.key` | `usual value` else `fallback the code handles` | T1: what it means when it differs |

Status words as in `dev/FACTS.md`; never write IN-GAME without a log line that shows it. `python3
dev/tools/diagread.py` compares the notes of a play session with these tables; the `tools` suite checks that the
tables and the code name the same keys.

## 7. Adding the module to the mod

- a line in `Scripts/core/modules.lua` (`name`, `switch`, `separate`: folder names of mods that do the same job);
- `modules/<name>/README.txt` for the player: what it does, every setting, what is not tested in the game;
- a paragraph in the mod's `README.txt` and `CHANGELOG.txt`;
- `python3 dev/run_tests.py` green, lint without warnings.
