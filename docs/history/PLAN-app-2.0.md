# Plan: settings app 2.0 - reorganised window (megamod stays 0.2.1)

## Context

- The player asked for a rewrite of the settings UI, "organizing the settings and tabs". Today the app has one flat row
  of 11 tabs; the Combat page alone is 110 settings and 8 screens long; the "Scale all ..." controls sit above
  every page but only work on five of them; the map-pin settings (33 values) have no page at all.
- He cancelled the extra mod work ("reverse the additional mod work, keep the megamod functionality the same as
  before it began"). So: the megamod stays exactly 0.2.1 as installed; no new modules; no other mod is touched.
  Nothing was removed or changed in the game folder for that work; only local preparation exists and is undone
  in step 0.
- Layout chosen by him: **category pane on the left + tabs on the right**.
- Outcome: settings app 2.0.0, same files and same saving behaviour as 1.5.0, new window. Windows XP look kept.

## Step 0 - undo the cancelled mod work (first thing after approval)

- Mod source tree back to the 0.2.1 package: restore `Scripts/core/settings.lua`,
  `dev/tests/core/test_settings.lua`, `dev/MODULES.md`, `dev/SETTINGS.md` from
  `<proj>/megamod/G1R_MegaMod-0.2.1-dev.zip`; then check every file of
  `G1R_MegaMod` against the package manifest (423 files, 0 differ) and run
  `python3 dev/run_tests.py` (expect 17 suites, 5093 checks, as before).
- Working notes: `handoff/BRIEF-common.md` back to its round-1 text (copy is in `handoff/round2/`), remove
  `handoff/round2/` and `deploy/onlymegamod/`, take the round-2 paragraph out of `research/README.md`, note the
  cancellation in `PLAN.md`.
- PC project folder: delete the copies made for that work (`megamod\other-mods-20261003\`, its zip, the zip of
  the session logs). Keep `megamod\first-session-20261003-2044\` (UE4SS.log and megamod diagnostics of his
  first session with 0.2.1: all ten modules loaded, 0 errors).
- Game folder: nothing to undo. Check only: megamod files against the 0.2.1 manifest, `UE4SS.dll` hash.

## The new window

```
+- G1R_MegaMod Settings ------------------------------------- _ [] x -+
| Preset: [Your own settings - in use  v] [Apply preset]  Find: [____] |
|+-------------+ +Regeneration+ Magic + Fire + Ice + Energy + Wind + ..+|
|| Settings  ^ | | +- Mana -------------------------------------+     ||
||  Overview   | | | [x] Mana regenerates                        |     ||
||  World      | | | Share of the maximum per step   [ 2.00] %   |     ||
|| >Combat   * | | +---------------------------------------------+     ||
||  Resources  | | +- Health -----------------------------------+     ||
||  Hero       | | | ...                                         |     ||
||  Time       | | +---------------------------------------------+     ||
||  Map        | |                                                     ||
||  Interface  | |                                                     ||
|| Page tasks ^| |                                                     ||
||  Defaults   | |                                                     ||
||  for page   | |                                                     ||
|| Details   ^ | |                                                     ||
||  0.2.1 ...  | |                                                     ||
|+-------------+ +-----------------------------------------------------+|
| Unsaved changes - press Save.          [Defaults] [Revert] [ Save ]  |
+----------------------------------------------------------------------+
```

Left: an XP Explorer-style task pane (blue gradient, white rounded boxes with a header and chevron):
"Settings" = the categories (selected one bold, `*` when one of its pages has unsaved changes);
"Page tasks" = Defaults for this page, Open the mod folder; "Details" = megamod version, preset in use, file path.

| Category | Tabs | From |
|---|---|---|
| Overview | (one page) | one line per part of the mod with its on/off switch and a link to its page; preset in use; folder |
| World | Creatures, Herbs and items, Containers, Crime, Advanced | the five hand-written repopulate pages, unchanged inside; "Scale all chances / timers" shown only here |
| Combat | Regeneration, Magic, Fire spells, Ice spells, Energy spells, Wind spells, Circles, Melee | regen (4 groups); magic "all spells" + "on screen, log"; one tab per school; "bolt by circle" + "learning the circles"; melee |
| Resources | Mining | mining |
| Hero | Experience, Lock picking | xp, locks |
| Time | Waiting, Rules | wait: the four waits and their keys; "when not to wait", notes, log |
| Map | Map pins | NEW page for the markers settings (today only in config.lua): labels, hover, pin sizes, pools, colour key, who is shown |
| Interface | Notes on screen | general |

Rules:
- No tab longer than about two screens (longest: Regeneration, 22 settings).
- Group titles lose the prefix that only existed because modules shared a page ("Magic: fire spells" -> "Fire spells").
- Nothing can get lost: a group the table does not name goes to its module's first tab; a module / page the
  table does not know gets a category of its own (today's behaviour) - also what the test modules use.
- `Find`: typing lists matching settings (label, hint, key name) with "Category > Tab"; Enter / click opens the
  tab and puts the focus on the setting. Ctrl+F jumps to the box.
- "Defaults for this page" sets only the shown tab; the bottom buttons keep their meaning (everything).
- Presets, Save, Revert, .bak files, re-reading files changed outside, the "*" in the title: unchanged.
- The megamod's files, formats and the in-game menu: unchanged. Standalone layout (only the repopulate mod):
  the same window with the World category only.

## Implementation (all in `app/src/`, built on the PC as `repopulate-settings-2.0.0\`)

1. `NavModel.cs` (new): the table above as data (category, tab, module, group titles), the fallback rules, the
   title clean-up. Built from `MegaMod` (`ModuleSettings.cs`: `MegaMod.Find`, schemas) plus the fixed repopulate
   pages; replaces `MegaMod.Pages()` as the source of pages.
2. `XpNav.cs` (new): `XpTaskPane` (owner-drawn, keyboard usable) in the style of the existing controls
   (`XpTheme.cs`: `Xp` colours, `Xp.Round`); reuse `XpTabControl` for the right side, `XpTextBox` for Find.
3. `SchemaPages.cs`: build one content panel per nav tab instead of one `TabPage` per schema page
   (`Build`, `PageUi`); `BuildItem`, `Wanted`, `Save`, `ApplyTier`, `MatchesTier`, `RereadUntouched` stay as they
   are. Add: unsaved-per-tab, defaults-per-tab.
4. `MainForm.cs`: `BuildLayout` (pane + tab host instead of the single `_tabs`), the five page builders return
   a panel, the scale strip moves into the World category, Overview page, Find results, test accessors
   (`PageTitles` -> "Category/Tab", `SelectPage`, `SaveTabImages`).
5. Map pins: an embedded description of the markers settings (same `Config.Key = value` file format the generic
   pages already read and write line by line: `ModuleSettings` / `SettingsRules`); the two list settings
   (`HideIds`, `ExtraNPCs`) stay file-only. Ranges and choices taken from `modules/markers/Scripts/main.lua`.
6. Tests: `SelfTestModules.cs` UI sections and `SelfTest.cs` adapted; new checks: every shown setting of every
   module is on exactly one tab, no empty tab, fallback for unknown modules, Find, defaults per tab, unsaved
   marks, Map pins round trip (file text unchanged except the edited line). `filetests` (`LiveTests.cs`): the
   same coverage check against the real megamod tree.
7. `G1R_Repopulate_Settings.csproj`: version 2.0.0. Exe name, location and desktop shortcut stay.

## Verification

- Linux: `buildcheck` compiles with 0 warnings; `filetests --selftest`, `--live`, `--presets` (PRESETS.txt must
  come out identical: megamod unchanged).
- PC (game not started): `dotnet publish`; `--selftest`; `--uitest` (off-screen window: every category and tab,
  edit / save / revert, presets, Find, defaults per tab); `--snapshot` of every tab, on the test megamod and on
  the installed one - I look at every image and fix what is off; exe searched for personal paths.
- Install with `megamod\install_megamod.py --check --settings-app <exe>` then for real, game closed: megamod
  0 added / 0 replaced, app replaced, old app in a new backup folder with rollback script. Afterwards: megamod
  files against the manifest, his 11 settings files byte-identical, `UE4SS.dll` hash.
- Notes: `G1R_MegaMod-0.2.1-notes.md` gets a section for app 2.0.0.

## Not part of this

New megamod modules, any change to the megamod or to other mods, the in-game mod menu.
