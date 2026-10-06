# Settings: one description per module

Every module written for the loader's kit describes its settings once, in `modules/<name>/Scripts/schema.lua`.
Three things are made from that description and must agree with it:

1. `modules/<name>/Scripts/config.lua` - the player's settings file. Its default text is generated
   (`lua5.4 dev/tools/gen_config.lua <name>`), the game reads it through `G1R_SETTINGS` (`Scripts/core/settings.lua`).
2. A page (tab) in the settings app. The app reads `schema.lua` itself and builds the page from it.
3. An entry in the in-game mod menu (the mod SharedModMenu), when that mod is installed.

All settings are picked up while the game runs: a changed `config.lua` within about 5 seconds, a change in the
in-game menu at once (and it is written into `config.lua`).

## 1. schema.lua

A Lua file of plain values (no functions, no calls, no arithmetic, no string concatenation): `local Schema = {}`,
assignments `Schema.X = value`, `return Schema`. Values: `true` / `false`, numbers, double-quoted strings (escapes
`\"` and `\\` only), tables written `{ a, b }` or `{ Key = value }`, nested. Comments with `--`.

    Schema.Module    = "xp"                  name of the module's folder
    Schema.Page      = "Experience"          the tab this module's groups appear on (several modules can share a page)
    Schema.PageOrder = 30                    position of the tab: lower numbers further left (default 100)
    Schema.Header    = { "line", ... }       comment block at the top of config.lua
    Schema.Notes     = { "text", ... }       hint paragraphs shown at the bottom of the module's groups in the app
    Schema.Groups    = { group, ... }

A group: `{ Title = "On screen", Order = 20, Hint = "text under the title", MenuTitle = "short", Items = { item, ... } }`
(`MenuTitle`: optional sub-tab name in the in-game menu, at most 28 characters; default the title without the page's
name in front of it.)
(`Order`: position on the page among all groups of that page, default 100; groups with the same number are ordered
by module name, then by their order in the file.)

An item:

| Field | Meaning |
|---|---|
| `Key` | name in config.lua (`Config.<Key>`): letters, digits, `_`; unique in the module |
| `Kind` | `"bool"`, `"number"`, `"choice"`, `"text"`, `"key"` or `"action"` |
| `Default` | the value the mod ships with (of the kind; an action has none) |
| `Min`, `Max` | numbers only, both required; values outside are pulled inside |
| `Step` | numbers: increment of the control in the app and in the menu (default 1) |
| `Decimals` | numbers: places after the point; 0 or absent = whole numbers (values are rounded half up) |
| `Options` | choices: list of texts; the value is one of them |
| `Label` | text in front of the control (`bool`: the check box text; `action`: the button text) |
| `Unit` | text behind a number control ("seconds", "times", "%") |
| `Comment` | text or list of lines: the comment above the value in config.lua and the tool tip in the app |
| `Menu` | optional short hint for the in-game menu (default: the first sentence of `Comment`); at most 54 characters |
| `MenuLabel` | optional short name for the in-game menu (default: `Label` with ` (Unit)` behind it); at most 35 characters |
| `Needs` | key of a `bool` item of the same module: the control is greyed while that item is off |
| `Hidden` | `true`: accepted in config.lua, but not shown in the app or the menu and not written into the default file |
| `Tiers` | the item's value in each of the five presets of the settings app (section 7); the game does not read it |

Kinds:

- `bool`: `true` / `false`.
- `number`: with `Min`, `Max`, `Step`, `Decimals`.
- `choice`: one of `Options`, stored as its text.
- `text`: any text (one line).
- `key`: a key combination the player presses, stored as text: `""` (no key) or modifiers `CTRL`, `SHIFT`, `ALT` (in
  that order) and one key name, joined by `+`: `"Y"`, `"CTRL+Y"`, `"SHIFT+ALT+F5"`. Key names (section 6) are UE4SS's.
  Other spellings (`ctrl + y`, `Strg+1`, `Delete`) are accepted when read and written back in the usual one.
- `action`: no value. A button in the in-game menu; the module's `onAction(key)` runs. Not in config.lua, not in
  the settings app (the app cannot reach into the game).

## 2. config.lua

    -- ============================================================================
    -- <Header lines>
    -- ============================================================================
    local Config = {}

    -- ---- <Group title> ----
    -- <comment lines of the item>
    Config.<Key> = <value>
    ...

    return Config

Line ends are LF. Values: `true` / `false`; whole numbers plain (`3`); numbers with decimals with at least one and
at most `Decimals` places, trailing zeros removed (`1.0`, `2.5`, `0.75`); texts, choices and keys in double quotes
with `\\` and `\"` escaped. Hidden items and actions are not written; a group with nothing to write has no title
line. `Settings.defaultText(schema)` produces exactly this text; the shipped `config.lua` of a module must equal it
(the tests check).

Reading is tolerant: a missing key has its default; a value of the wrong kind falls back to the default; a number
outside `Min..Max` is pulled inside; a whole-number item gets rounded; a number written as text (`"3"`) is taken as
the number. Keys that the schema does not know are ignored by the game and kept by every writer. The file runs
without access to Lua's libraries: anything but plain values makes it invalid, and an invalid file leaves the
previous values (at the start: the defaults) in place.

**Changing values (game and app do it the same way):** only the lines of changed keys are rewritten.

- The line of a key is the **last** line that matches `^[ \t]*Config\.<Key>[ \t]*=` (so not a commented one; the
  last, because that is the one Lua goes by when a key stands twice). It becomes `<same indentation>Config.<Key> =
  <value>`; the rest of that line (a comment behind the value) is dropped, its line end kept.
- A key without a line gets one directly below the last line with text in front of the last `return Config` line
  (empty lines in front of the return stay in front of it), with the file's line ending (CRLF when the file has one,
  else LF). Without a `return Config` line it is appended.
- Several keys at once: in the order of the schema.
- Nothing else in the file changes - comments, unknown keys and their order stay.
- A file that does not exist or cannot be parsed is replaced by the default text with every value that is not the
  default put in by the rule above.
- The game writes to `config.lua.tmp` and renames it over the file.

## 3. The in-game menu (SharedModMenu's shared variables)

The settings service registers one menu entry per page, named `G1R <Page>` (a comma in a page name becomes a
space), with one section per group (all modules of the page, ordered by `Order`, module name, file order). The menu
shows its entries in the order they were registered, which is the order the modules are loaded in. The menu mod draws every row on one line and cuts a name after 35 characters, a hint after 54 and a tab or
sub-tab after 28 (its `viewmath.lua`); the service publishes texts that fit (MenuLabel / Menu / MenuTitle, else a cut
at a word with three dots) and `dev/tests/core/test_settings.lua` (9b) checks every module's texts. `bool` items
appear as switches, `number` items with their `Min` / `Max` / `Step`, `choice` items as a number 1..n (the hint lists
the options when they fit, else names the one it has: "now: x (i of n)", published again when it changes), `action` items as a button. `text`, `key` and hidden items do not appear; a group without any item
for the menu has no section.

    SMM:index            comma separated names of everything registered ("G1R Experience" is appended once)
    SMM:schema:<name>    sections separated by \29; in a section the title and the items separated by \30;
                         an item: name \31 kind ("bool" | "num" | "action") \31 min \31 max \31 step \31 hint
                         (name: Label, with " (Unit)" behind it; the characters \29 \30 \31 become spaces)
    SMM:values:<name>    one token per item, separated by \30: "b1" / "b0", "n<number>", "x" (an action)
    SMM:cmd:<name>       edits queued by the menu: records "index \31 token" separated by \30; the service empties
                         the variable, checks the values, applies them, writes config.lua and publishes the values
    SMM:refresh          a counter the service raises when it has registered a page

## 4. In a module

    local KIT, SETTINGS, DIAG = G1R_KIT, G1R_SETTINGS, G1R_DIAG
    local Settings = SETTINGS.open({ module = "xp", dir = SCRIPT_DIR, log = log })   -- reads schema.lua and config.lua
    local Cfg = Settings.values           -- always complete; read it wherever the value is needed (it changes in place)
    Settings.onChange = function(values, changedKeys, why) ... end    -- why: "file" | "menu" | "set" | "reset" | yours
    Settings.onAction = function(key, why) ... end                    -- a button of the in-game menu
    Settings:set("Multiplier", 2, "console")   -- checks, writes the line into config.lua, calls onChange -> changed?
    Settings:apply({ A = 1, B = 2 }, "why")    -- several at once -> the keys that changed, sorted
    Settings:reset()                            -- every shown setting back to its default
    Settings:reload(true)                       -- read config.lua now -> true, changed keys | false, reason

`SETTINGS.open` returns nil and the reason when schema.lua cannot be used. The service looks at the files and at
the menu's edits by itself (the loader calls it four times a second on the game thread). A module never parses
config.lua on its own and never writes it except through `set` / `apply` / `reset`.

Rules for settings: every feature of a module has a switch; every number that shapes behaviour is a setting with a
sensible range; the defaults leave the game as it is; a module with `Enabled = false` (or with all features at
their neutral values) does not touch the game at all; a changed setting takes effect without a restart and never
changes what the player already has.

## 5. In the settings app

The app looks for `modules\*\Scripts\schema.lua` next to the module it sits in (megamod layout). It builds one tab
per `Page` (tabs ordered by `PageOrder`, then name): a group box per group (ordered by `Order`, then module name,
then file order) with its items - `bool`: check box; `number`: numeric control with `Min` / `Max` / `Step` /
`Decimals` and the unit behind it; `choice`: drop-down list; `text`: text box; `key`: a box that takes the next key
combination pressed (and a button to clear it) - `Comment` as tool tip, `Hint` under the group title, `Notes` at the
bottom, `Needs` greys the control. `action` and hidden items are not shown. Save rewrites only the changed lines
(section 2). The hand-written pages of the module `repopulate` stay as they are.

## 6. Key names

The names UE4SS uses, with their Windows virtual-key codes (what the settings app gets from a key press):

    A - Z                0x41 - 0x5A         ZERO ... NINE          0x30 - 0x39
    F1 - F12             0x70 - 0x7B         NUM_ZERO ... NUM_NINE  0x60 - 0x69
    BACKSPACE 0x08   TAB 0x09   RETURN 0x0D   PAUSE 0x13   CAPS_LOCK 0x14   SPACE 0x20
    PAGE_UP 0x21   PAGE_DOWN 0x22   END 0x23   HOME 0x24   INS 0x2D   DEL 0x2E
    LEFT_ARROW 0x25   UP_ARROW 0x26   RIGHT_ARROW 0x27   DOWN_ARROW 0x28
    MULTIPLY 0x6A   ADD 0x6B   SUBTRACT 0x6D   DECIMAL 0x6E   DIVIDE 0x6F   NUM_LOCK 0x90   SCROLL_LOCK 0x91
    MIDDLE_MOUSE_BUTTON 0x04   XBUTTON_ONE 0x05   XBUTTON_TWO 0x06
    OEM_ONE 0xBA   OEM_PLUS 0xBB   OEM_COMMA 0xBC   OEM_MINUS 0xBD   OEM_PERIOD 0xBE   OEM_TWO 0xBF   OEM_THREE 0xC0
    OEM_FOUR 0xDB   OEM_FIVE 0xDC   OEM_SIX 0xDD   OEM_SEVEN 0xDE   OEM_EIGHT 0xDF   OEM_102 0xE2

(ZERO ... NINE are ZERO, ONE, TWO, THREE, FOUR, FIVE, SIX, SEVEN, EIGHT, NINE.) Modifiers: `CTRL` 0x11, `SHIFT`
0x10, `ALT` 0x12. The left and right mouse buttons, Escape and the Windows keys cannot be bound. `G1R_KIT.keyCombo`
(`Scripts/core/kit.lua`) is the reference: it also takes the spellings `0` - `9`, `NUM0` - `NUM9`, `INSERT`,
`DELETE`, `ENTER`, `PGUP`, `PGDN`, `UP`, `DOWN`, `LEFT`, `RIGHT`, `MOUSE3` - `MOUSE5`, `CONTROL`, `STRG`.
A key bound without a modifier does not fire while CTRL, SHIFT or ALT is held, and the other way round.

## 7. Presets (the settings app's "Preset" box)

Five sets of settings, from the game itself to as easy as the settings allow:

    1 - Base game (hardest)     2 - Relaxed     3 - Easy     4 - Very easy     5 - Easiest

"Apply preset" sets, on every page, each setting that names a value for the presets. Nothing is written until Save.
The box stands on the preset the settings are at ("- in use"), or on its first line, "Your own settings", when they
are at none of the five; it follows the settings until another line is picked, and with the first line picked there
is nothing to apply. The game knows nothing of presets: they are values in `config.lua` like any others.

A setting takes part through the field `Tiers` of its item:

    Tiers = { 1, 1.5, 2, 4, 10 }      the value in preset 1, 2, 3, 4, 5
    Tiers = "default"                 the item's Default in every preset (a preset puts the setting back to neutral)

Rules (checked by `lua5.4 dev/tools/presets.lua`, by the suite `presets` and by the app, in the same words):

- Only `bool`, `number` and `choice` items that are not `Hidden`. Five values of the item's kind: numbers within
  `Min` .. `Max` with at most `Decimals` places, choices out of `Options`.
- The first value is the item's `Default`: preset 1 is the game itself, and the defaults leave the game as it is.
- Preset 5 is the end of the range that makes the game easier; from preset 2 on a number moves in one direction only.
- In a module that has presets, every setting on its page has `Tiers`, except the switches for notes and log lines
  (`ShowMessage`, `Log...`): a new setting needs the decision. Settings that are fine tuning (the multipliers of single
  spells) are `"default"`: every preset puts them back to neutral, and the presets work through the general ones.
- The switch of the module and of its parts is `"default"` with `Default = true`: a preset switches on what it sets.
- Not part of the presets: keys, texts, notes, logs, and modules that do not change how hard the game is
  (general, melee, wait, markers).

`Schema.PresetNote = "text"` (or a list of lines): what `PRESETS.txt` says below the module's values.

A `Tiers` that breaks a rule does not make the schema unusable (the game ignores the field); the app leaves that
setting out of the presets and says so when a preset is applied.

The repopulate module has no schema: its five sets stand in the app (`Presets.cs`, `ForRepopulate`). Besides them
every preset switches on the module itself, `Chests.IncludeLootObjects` and `Crime.ForgetOldCrimes` (`Presets.Apply`).
A preset counts as in use when every value it sets has its value - also a value that has no effect while its part
is off.

`PRESETS.txt` (top level of the mod) lists every value of the five presets. It is written by the app's file tests
and checked by them against the schemas and the app:

    filetests --presets <G1R_MegaMod> <G1R_MegaMod>/PRESETS.txt       write it
    filetests --live <G1R_MegaMod> <report>                           checks it (and that the app and
                                                                      dev/tools/presets.lua read the same values)
