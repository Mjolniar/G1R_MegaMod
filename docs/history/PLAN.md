# Megamod plan (working notes; re-read after a context break)

## User decisions (2026-10-02, verbatim where quoted)
- "I would make our own versions of those mods into the megamod." -> megamod replaces the separate mods. DONE for
  G1R_Repopulate + NPCMarkers: megamod 0.1.1 installed 07:04, AUDIT OK (22 checks), backup
  `megamod-install-backup-20261002-070457` (rollback script inside). Nothing tested in game.
- "Also include our own xp multiplier in the settings mod" -> module xp; settings in the settings app AND in the
  in-game mod menu (SharedModMenu, third-party, stays installed; its protocol is shared variables `SMM:*`).
- Question card answers: EXPModifier -> "Yes, replace it" (retire to backup, carry 4x over).
  More mods -> own versions of SkillfulLocks, Skip Time (G1R_WaitOnT), BetterMining, G1R_MageBalance.
- "Heavilly patch and change functionallity to all of them, making them all changeable in functionallity within the
  settings menu." -> our versions are NOT ports: changed / extended behaviour, every feature switchable and
  tunable in the settings (app + in-game menu).
- "Always allow running command" / "Get preapproval now" -> user approved the tool kinds (PowerShell on the PC,
  commit / stage / list in the project folder). He is probably away: work unattended, no blocking questions.
- Standing: never launch the game; keep UE4SS AngelScript Fix 0.4 (UE4SS.dll sha256 e1909f98...1dcaa3); never use the
  manager's Install/Update UE4SS; backups + save hash compare; preserve HUDMap / Skip Time / EXP 4x settings
  (carry them into our modules); curt reports; UI theming = Windows XP style.

## Stages
- 0.2.0: settings core (schema-driven, app + in-game menu), kit, module xp on it, generic pages in the app,
  installer: update + retire EXPModifier (4x carried over). Install, audit.
- 0.3.0: modules locks (SkillfulLocks), wait (G1R_WaitOnT), mining (BetterMining), mage (G1R_MageBalance), each with
  schema; installer retires the four third-party mods and carries their settings over. Install, audit.
- Notes for the PC project folder at the end of each stage (megamod notes).

## Facts found today (details in dev/FACTS.md 4b)
- XP: attribute `Experience` of `AttributeSet_LevelProgression` in the player state; write BaseValue + CurrentValue
  (IN-GAME via EXPModifier log). Level check only on the game's own effect (native, after GE execute).
  `m_ExperienceMultiplier` (difficulty) scales the XP NEEDED per level, not gains.
- UE4SS: mods.txt lines without a folder are skipped silently (seen in log). Windows PowerShell started from
  PowerShell 7's environment has no Get-FileHash (PSModulePath) -> rollback script hashes through .NET.
- PC tool: every PowerShell call must answer within 60 s; longer jobs keep running, poll their output file.
- Mod manager (ISKL G1L 0.8.1) keeps mods.json + mods.txt; it adopted a manually installed mod before (removed its
  enabled.txt, listed it). mods.txt / mods.json are left untouched by our installers.

## Review of module xp (agent, 2026-10-02) - to apply
double multiplication with a second multiplier between two looks (stand down on any foreign ledger value and when
`SMM:index` lists EXPModifier); false stand-down after a Lua restart (ledger value present at start is not foreign);
saved experience arriving after the first look (settle time, note key); controller without player state;
attributes replaced under the same state; write check of both values; unreadable experience (log before forget,
back off); passive while off / x1.0; note: IsInViewport re-add, font before AddToViewport, lookups at a calm
moment; LOADING_LIMIT shorter; decimal comma warning; mods.txt name compared case-insensitively;
README promises; tests that cannot fail (harness ~305, ~982) and uncovered mutations.
Scratch of the reviewer: /tmp/review-xp/ (may be gone).

## Settings app
Source copy: app/src (agent added a hand-written Experience page, ExperienceSettings.cs,
megamod-aware paths, title switch, tests; Linux file tests ALL OK; UI not run). Built on the PC with
`dotnet publish -c Release -o publish` in `repopulate-settings\`; `--selftest`, `--uitest`, `--snapshot`.
Next: generic pages from each module's schema.lua (replaces the hand-written Experience page).

## State 2026-10-02 (after the foundation; re-read this first after a context break)
- Decision: ONE release 0.2.0 with every module (no separate 0.3.0): foundation + general + xp + regen + magic +
  melee + mining + locks + wait; installer retires EXPModifier, G1R_RegenMana (native), G1R_MageBalance,
  BetterMining, SkillfulLocks, G1R_WaitOnT with the player's values carried over; per-mod restore.
- Foundation DONE and green (python3 dev/run_tests.py: 10 suites, 2415 checks, lint 0): Scripts/core/kit.lua
  (guarded access, findOnce/findClass/findDefault/firstOf/hookOnce, hero + attributes, loading/paused/gameSeconds,
  keys with game-thread pump, notes: box with lines + slots, subtitle, notify/configureNotes), core/settings.lua
  (schema kinds bool/number/choice/text/key/action, patch = last line / insert below last text line, menu bridge),
  core/modules.lua (module list; loader guards incl. native dlls/main.dll, case-insensitive mods.txt, state absent),
  modules/general (note style/position/seconds), modules/xp on the kit, dev/MODULES.md (contract),
  dev/SETTINGS.md, dev/facts/{kit,xp}.md, dev/tests/lib/modtest.lua, dev/tests/core/*, dev/tools/mutate.py
  (mutation check with --accept files). Mutation: xp 146 killed / 14 accepted, settings 411 / 10, kit 627 / 56.
- Agents (briefs: handoff/BRIEF-common.md; reports: handoff/<name>/REPORT.md): modules regen,
  magic, melee, mining, locks, wait; settings app (generic schema pages, app); installer
  (deploy, table-driven take-overs). After they return: review each (independent review agents),
  integrate (core/modules.lua, README, CHANGELOG, facts), full test run, build package, PC: build app, rehearsal,
  --check, install, audit, notes. Never launch the game.
- Research kit for agents: research/README.md, usmap.py, thirdparty/G1R_RegenMana.ini.

## State 2026-10-03 13:00 MDT - 0.2.0 INSTALLED on the PC (re-read this first after a context break)
- Modules written (2026-10-02) and independently reviewed (2026-10-03, reports handoff/review-*/REPORT.md): 7
  defects fixed by the reviewers (locks 3, regen 2, wait 1, melee 1); lead follow-ups applied: kit (a set is kept
  under the name it was found by), settings (a failing onChange is logged), wait (W-B "until" boundary incl. the
  press-before-the-hour rule, W-D), regen (R-C diagnostics: `regen.mana.block = not set at zero mana`,
  `regen.tags = only no so far`), melee (brake after 5 re-sets in a row), magic (halves rounded up, small raw product
  not 0), mining / locks wording. Docs: README, CHANGELOG, xp README, AI_GUIDE, facts/kit, MODULES.
- Tests: python3 dev/run_tests.py -> 16 suites, 5030 checks, lint 0/0. Mutation 0 survived: kit, settings, wait,
  melee, magic (regen, locks, mining by the reviewers).
- Installer: five converters by a worker (handoff/converters/REPORT.md); sim 332 checks on the live tree and on the
  exact package; rehearsal on the PC (copies of the real folders, PowerShell 5.1 + 7.6.6): 72 checks ALL OK.
- Package: G1R_MegaMod-0.2.0-dev.zip sha256 6e021d832e32545962b032ebb6f88150ba9f896dfb1d05d0674b2b620a40efcc
  (420 files), plain zip 6bbc9df1...; built with --forbid-file and --foreign (5 other mods' files: none included).
- Settings app 1.4.0 built on the PC (repopulate-settings-1.4.0\publish, sha256 cfeb3ea4...): --selftest 104 ALL OK,
  --uitest 45 ALL OK, --snapshot viewed (pages General, Combat, Resources, Experience, Lock picking, Time).
- INSTALLED 2026-10-03 12:36: update 0.1.1 -> 0.2.0, six mods retired with settings carried over (EXPModifier,
  SkillfulLocks, G1R_WaitOnT, BetterMining, G1R_MageBalance, G1R_RegenMana), app installed. Backup + rollback:
  megamod-install-backup-20261003-123613 (ROLLBACK-megamod-install.ps1, -Only <Mod>). AUDIT OK (42 checks): UE4SS.dll
  e1909f98..., mods.txt, mods.json, 43 saves, 92 other files unchanged. The installed files start in the mock with
  all ten modules ok and the player's values in the load lines. The game was not started.
- NOT DONE / open: nothing has run in the game. Review items left open (see notes file on the PC,
  G1R_MegaMod-0.2.0-notes.md): melee profile corner cases (#4 - #6), magic status count / first-search burst /
  prepareNotes, wait `moved = differs`, regen run-long switches, locks write-that-does-not-stay, mining tagsOff.
  Kit suggestions of the module authors (ability-system / tag helpers, TrySetAttributeBaseValue helper) not applied.
- Next session: fetch UE4SS.log + Mods\G1R_MegaMod\Scripts\diagnostics\ after the player has played; read with
  dev/tools/diagread.py and loganalyze.py; update dev/FACTS.md and dev/facts/*.md statuses.

## 2026-10-03 13:15 - app icon and desktop shortcut
- Icon drawn by icon/make_icon.py (XP style: steel gear + blue ore crystals; every size drawn on its
  own; .ico with 256 as PNG, 128..16 as 32-bit bitmaps). On the PC: megamod\icon\.
- Settings app 1.4.1: ApplicationIcon + embedded resource "AppIcon" (MainForm: AppIcon.Load()). Built on the PC in
  repopulate-settings-1.4.1\ (sha256 a791d276..., 1011466 bytes): --selftest 104 ALL OK, --uitest 45 ALL OK, snapshot
  shows the icon in the title bar. Installed with install_megamod.py --settings-app (backup
  megamod-install-backup-20261003-131347, AUDIT OK 29 checks).
- Desktop: new shortcut "G1R_MegaMod Settings.lnk" (icon = exe,0); the old "G1R_Repopulate Settings.lnk" moved to
  megamod\old-shortcut\ (the installer's SHORTCUT constant still names the old file: it only matters if the separate mod
  G1R_Repopulate is ever retired again).

## 2026-10-03 14:35 - presets remade: megamod 0.2.1 + settings app 1.5.0 INSTALLED
- User: "Remake the presets, with a set of settings from base game being the hardest to the easiest it could possibly
  be in the settings, with 5 tiers." -> five presets "1 - Base game (hardest)", "2 - Relaxed", "3 - Easy",
  "4 - Very easy", "5 - Easiest", for ALL pages (the old four were respawn only).
- Where the values are: schema item field `Tiers = { v1..v5 }` or `Tiers = "default"` in modules regen, magic, mining,
  xp, locks (125 items; the game ignores the field), `Schema.PresetNote`; repopulate's in the app (`Presets.cs`,
  `ForRepopulate`; every preset also switches on the module, Chests.IncludeLootObjects, Crime.ForgetOldCrimes).
  Not in the presets: general, melee, wait, markers, keys, notes, logs, per-species settings, page Advanced.
  Rules + checker: dev/SETTINGS.md section 7, dev/tools/presets.lua, suite dev/tests/presets (63 checks).
  PRESETS.txt (top level of the mod) is written by `filetests --presets` and checked by `filetests --live`.
- App 1.5.0: box "Preset" with six lines - "Your own settings" (settings at none of the five; nothing to apply) and
  the five; the line the settings are at carries "- in use" and the box follows it until another line is picked.
  Built on the PC in repopulate-settings-1.5.0\ (sha256 41dab5aa..., 1052938 bytes): --selftest 111, --uitest 49
  ALL OK, snapshots viewed (test megamod and the installed one).
- Megamod 0.2.1: game side = 0.2.0 + version string + the Tiers fields (schemas compared: same apart from Tiers /
  PresetNote; default config.lua files identical). Tests: 17 suites, 5093 checks, lint 0/0. Package
  G1R_MegaMod-0.2.1-dev.zip sha256 1ff1bc8a54ba13d15e243d083da595ce98d9b0e34729ac6ffbd86e6f1a71e7c9 (423 files).
- sim_megamod.py: an update that retires nothing makes no folder `retired` (the PC's state now) - two checks made
  to accept that; Linux 332 checks ALL OK; rehearsal on the PC (megamod\rehearsal-0.2.1, copies of the real folders,
  both PowerShells) 47 checks ALL OK.
- INSTALLED 14:32: 3 added, 11 replaced, 12 player files kept, app 1.4.1 -> 1.5.0. Backup + rollback:
  megamod-install-backup-20261003-143256. AUDIT OK (29 checks). The 11 player settings files have the hashes of the
  0.2.0 install; copy of them: megamod\settings-before-presets-20261003\. Offline start of package + his files: ten
  modules ok. No preset was applied: his settings are "Your own settings". The game was not started.
- PC TOOL TRAP: device_commit_files can deliver the PREVIOUS content of a staged path when that path was committed
  before and its file changed since (seen twice: app sources at 14:19, the 0.2.0 notes at 13:15). Always commit a
  changed file from a NEW staged folder (outputs/<name>-b, -c ...) and compare SHA-256 on the PC afterwards.

## 2026-10-03 21:05 - ROUND 2: megamod must cover every other mod - CANCELLED BY THE USER (see the section after this one; nothing below is to be done)
User, in order (verbatim): "Make sure just the gothic megamod is running when I launch the game on steam" ->
"Closed" (he closed the game for it) -> "make sure to remove nothing that the megamod doesnt cover" -> "And if it has
gaps, we need to add them into the megamod".
Meaning: the goal is megamod alone, but a mod is taken out only once the megamod does its job. NOTHING was removed
(a park script was written and tested on a mock only: deploy/onlymegamod/, not on the PC, superseded).

FIRST IN-GAME SESSION of the megamod (0.2.1, 2026-10-03 20:44 - 20:59, started by the player through his launcher):
all ten modules loaded, 0 errors; IN-GAME now: magic 73 values in 33 objects kept, locks (master, minigame seen, note
box shown), xp x4 (16 gains), repopulate containers restocked (3, 49 items) + crime off + 2496 item spots, markers
pins / pools / hover, regen readable, mining config written and kept. Logs: research/session1/ (PC:
megamod\first-session-20261003-2044\). FACTS statuses still to be updated from it (dev/tools/diagread.py).

Still installed besides the megamod (copies of 2026-10-03: research/othermods/, PC: megamod\other-mods-20261003\):
| Mod | Job | Megamod module to write |
| BystanderXP (native) | XP for kills the hero did not land: XPPercent=100, Range=5000 | bystander (page Experience) |
| G1R_AutoPickUpItemNative (native) | hold R / toggle X collects items in 5 m; owner rules; filter Torch | pickup (page Items) |
| G1R_PutAwayTorchRedux (native) | key T: tap = draw / put away the torch, hold = drop | torch (page Items) |
| G1R_ShowItemValueNative (native) | trade screen: "42 (37)" + colours | values (page Trade) |
| G1R_RenderBridge (native) | drawing helper of the native mods | none (goes with its clients) |
| HUDMap (native + Lua) | HUD minimap: square, top right, north up, region maps, pins, key N | minimap (page Map) |
| PLuaModLoader + FocusNearbyPickups (Lua) | F6: outlines on nearby pickups | highlight (page Items) |
| SharedModMenu (Lua) | in-game mod menu, F2 (hosts the megamod's pages) | menu (own in-game window) |
| SB_P pak = "Snappier Blocking" (zemsta) | block starts at once (transition animations) | melee: block transition speed |
Launcher: ISKL G1L 0.8.1 (C:\Users\...\Desktop\Gothic 1 Remake Mod Manager); it rewrites mods.txt + mods.json at
every PLAY (from its memory; user-managed = folders in Mods), starts the game through steam://rungameid/1297900,
keeps lines of missing folders. UE4SS starts a mod when mods.txt says ": 1" OR the folder has enabled.txt.
Steam: no launch options. No other loader, no Engine.ini tweaks, one pak mod (SB_P).

Plan: megamod 0.3.0 = the modules above (each with settings in the app, fail-safe, own switch, stands down while the
other mod is enabled), installer take-overs + converters for the player's values, retire each mod when its module is
in. Authors = worker agents (briefs: handoff/BRIEF-common.md + handoff/round2/<name>.md), then reviewers, then
installer worker. Install only with the game closed; never start the game. UI drawn in the game: Windows XP style
(The player's general rule).

### 21:25 - user: "DO a planning phase, add a rewrite of the UI of the settings menu as well, organinzing the settings and tabs"
-> plan mode: research + plan for his approval BEFORE any worker is started. Scope now: (1) megamod modules for
the nine remaining mods, (2) rewrite of the settings UI (settings app; the in-game window follows the same order),
with the settings and tabs reorganised.
Prepared already (kept): core `G1R_SETTINGS.pages()` / `runAction()` + 13 tests (core/settings 136 checks; all 17
suites green, 5106 checks); dev/MODULES.md (pages table, rule 17 Windows XP look in the game), dev/SETTINGS.md
(pages API); handoff/BRIEF-common.md (round 2), handoff/round2/<name>.md (eight assignments: bystander, pickup,
torch, highlight, values, minimap, menu, melee-block); research/README.md (snapshot + session1).
Feasibility seeds (params.py: all native UFunctions, callable from Lua): HandleDeath / HandleDefeated
(AIAgentCharacter), GothicCharacterState:FindAllInRadiusAround / IsDead / IsDefeated, Server_/Multicast_PickWorldItem
(interactiveActor, destroy, niagara, hasWater, waterZ, canQuick), InventoryComponent:AddItemOfClass /
TakeOutItemOfKind / CountItemsOfClass, AbilityTask_PutAwayItem:TaskPutAwayItem, GetItemValueByPos,
DiscreteItemViewWidget:SetListItemsBP, AreaTagRegionTrait:FindAreaTagAtLocation. HUDMap is built from UMG widgets
(Image:SetBrushFromTexture, SetRenderTransformAngle) with the game's own map textures.
Nothing of this is on the PC. No worker has been started.

## 2026-10-03 21:40 - ROUND 2 CANCELLED, SETTINGS APP 2.0 (re-read this first after a context break)
User (verbatim): "Honestly, nevermind, reverse the additional mod work, keep the megamod functionality the same as
before it began, but do continue with the UI redo." Layout he chose: "Category pane + tabs". He rejected the three
Explore agent calls: NO AGENTS for this work.
-> megamod stays EXACTLY 0.2.1 as installed. No new module. No other mod is removed, parked or touched.
-> approved plan: /root/.claude/plans/ethereal-herding-bee.md (settings app 2.0.0: category pane on the left, XP
   tabs on the right, Overview, Find, defaults per page, unsaved marks, Map pins page for the markers settings).

Step 0 done (undo of the round-2 preparation):
- mod source: Scripts/core/settings.lua, dev/tests/core/test_settings.lua, dev/MODULES.md, dev/SETTINGS.md restored
  from G1R_MegaMod-0.2.1-dev.zip; tree == manifest (423 files OK); tests 17 suites / 5093 checks.
- handoff/BRIEF-common.md = round-1 text again; handoff/round2/, deploy/onlymegamod/, research/othermods/ removed;
  research/README.md without the round-2 snapshot paragraph (research/session1/ kept: first in-game session logs).
- PC project folder (21:38): megamod\other-mods-20261003\, its zip and first-session-20261003-2044.zip deleted;
  megamod\first-session-20261003-2044\ kept. Game folder: nothing was ever changed for round 2.
- PC check (megamod\audit-step0.out.txt): game not running; UE4SS.dll e1909f98... unchanged; package 423 files ==
  manifest; 411 package files in Mods\G1R_MegaMod, 0 differ; 12 player files as before; app 1.5.0 (41dab5aa...).
  The audit's 5 FAIL lines are the traces of his own play session at 20:44 (diagnostics, config.lua.bak,
  state/profile_0.lua, mods.txt/mods.json rewritten by his launcher, saves changed) - not ours, nothing to fix.

## 2026-10-05 14:05 - OTHER AGENT HARDENING PACKAGE + PRODUCTION QUEUE (re-read this first after a context break)
User (verbatim): "For your review as well, roll into production queue (The linked folder, analyze all documentation
within). Also, see if you can add modifiers for swimming speed and the mounted scavenger speed, add those tasks to the
workflow." + path <home>\Documents\the other agent\2026-09-30\inst\outputs\claude-hardening-review-20261004\
Claude review and source bundle.zip
Local copy: research/re-toolsview/bundle (the zip, sha256 ddb38515...) and research/re-toolsview/docs (top-level files +
evidence folders). PC copy for staging: megamod\review-20261005\ (bundle.zip, docs.zip).

STATE OF THE PC (changed since 10-03, NOT by me):
- Seven crashes 10-04 / 10-05 (A Focus RootComponent, B physics worker, C + E container getter lookup, D map hover,
  F FindAllOf in crime refresh, G ProcessEvent on a dead receiver while riding).
- the other agent deployed a two-file hotfix into the live megamod on 10-05 12:28 (game closed): modules/repopulate/Scripts/
  util.lua (28ca4df7...) and chests.lua (07e7375b...); originals 470f458d... / e9e263d3... Diff:
  review/bundle/minimal-hotfix-20261005/Minimal correction.diff. KEEP IT (do not apply twice, do not roll back).
- the other agent also patched FocusNearbyPickups.lua (another mod) on 10-04 17:22.
- His settings now: XP x10 (LargeGainMultiplier 2), wait Y = 30 min, OEM_SIX = until 08:00, crime OFF, containers
  50 % / 15 %, mining custom, regen on, magic custom, locks skilled safe / master all. Loader config still the old
  form (Config.Modules = { Repopulate = true, Markers = true }). PRESERVE ALL OF IT.
- Rules of the package: no deploy / launch / stop / reload while he may be playing; keep the AngelScript loader;
  no hex patches; keep every feature.

MY FINDINGS (own reading of logs + source, beyond the package):
1. TRIGGER: repopulate resets its whole session on every PlayerController:ClientRestart (main.lua RegisterHook).
   76 restarts in the 7 logged sessions; the game clock never went back - they are mount / dismount / sleep, not
   loads. Each reset: crime re-applied at once (5 FindAllOf), 8 s later session start = ~14 object walks
   (FindAllOf / FindFirstOf: PersistentDataSubsystem, WorldPointManager, InteractiveObjectActor, GothicCharacterState,
   GameTimeSubsystem ...) + 3974-config item pass + every container re-tracked. Crash E 20 s after one, F inside the
   crime walk 20 s after one, G 1-2 s after one.
2. RACE: the engine frees UObjects on a worker thread (gc.MultithreadedDestructionEnabled; the cvar is in the exe:
   registered at 0x140c868e0, variable 0x149b9f37c, read in IncrementalDestroyGarbage 0x1412c3449 at every purge
   call: the purger object [0x149b9f640] is replaced when the setting differs). UE4SS walks GUObjectArray on the game
   thread without the array lock (ForEachUObject at UE4SS+0x372130: reads Object, then a flag, then IsA) -> a
   concurrent free gives a garbage class pointer = crash F (and U2 of FACTS). Lua IsValid then use has the same hole.
   Mitigation inside the mod: set the cvar to 0 once per process at a moment no purge is running (LoadMapPost:
   LoadMap has just done a full purge), read it back with GetConsoleVariableIntValue. A swap mid-purge would be
   unsafe (the engine's own check is compiled out in shipping) - hence the timing rule.
3. VALIDITY: UE4SS IsValid = pointer in its registry and not unreachable. A destroyed actor (streamed out, marked
   garbage) stays "valid" until collected. KismetSystemLibrary:IsValid(Object) (exe 0x149818a80) is the engine's
   own test and rejects it at once.
4. ACQUISITION WITHOUT WALKS (all in the exe, params.py): GameplayStatics GetPlayerController / GetPlayerPawn /
   GetPlayerCharacter / GetGameInstance / GetAllActorsOfClass / GetActorOfClass, SubsystemBlueprintLibrary
   GetWorldSubsystem / GetGameInstanceSubsystem, KismetSystemLibrary SphereOverlapActors / ExecuteConsoleCommand /
   GetConsoleVariableIntValue / CollectGarbage.
5. MARKERS (crash D): a new W_Map_Main_C per map opening (found by notification each time); textures are cached
   for the whole session and re-bound to the new screen's images. Fix: textures belong to one screen instance;
   binding is checked; ensureLabel reconciles; hover label work budgeted (F19-F21).
6. the other agent findings: F01-F06, F19-F22 confirmed against the source; F08-F18 valid secondary; F07 (Auto Pickup /
   physics) is not the megamod's.

FEASIBILITY (game scripts, usmap):
- Swimming: /Script/Angelscript LocomotionSpeedSettings_Swim_Laying_Player.m_Speeds (Map EWalkSpeed -> float:
  Walking 100, Running 150, Sprinting 220), hero only. Also UAS_LocomotionSpeedModifierSettings_InWater_Ground_Player
  (wading 0.6 above 60 cm). Write = CDO map values, as magic / mining do.
- Mounted scavenger: speed table of the adult scavenger is shared with wild ones (Ground_Stand_Scavenger_Adult
  120 / 320 / 750). Per-character attribute AttributeSet_Movement.SpeedModifier (1.0; GA_Fatigue moves it by 5 %)
  on the ridden scavenger = clean scope. While riding the controller possesses the mount (ClientRestart on mount and
  dismount). GothicMountComponent has m_riderCharacter / m_mountCharacter / m_PlayerController.

PRODUCTION QUEUE (order: stability first - his game crashes; tell him, he can reorder):
Q1  megamod 0.2.2 "stability": (a) no session reset on ClientRestart (reset only: map load, clock went back,
    profile changed), reasons logged; (b) crime: no rediscovery storm, cached subsystems, min interval;
    (c) settle time after possession change / map load before any object walk, one walk per tick, breadcrumb before
    each; (d) worker-thread destruction off (loader, default on, readback, note); (e) engine IsValid in the
    validity helpers; (f) markers textures per screen + checked binding + hover budget; (g) diagnostics: report kept
    per session, reset counters; (h) writers (util.lua, core/settings.lua) verify write / close / rename, keep the old
    file until the new one is in place; + tests (the other agent's checks ported). Built on the LIVE state (hotfix kept).
Q2  settings app 2.0 (approved plan ethereal-herding-bee.md): model layer written (NavModel.cs, AppSchemas,
    MapPinsSchema.lua, PatchValue); MainForm / SchemaPages / tests still at 1.5.0 -> the tree does not compile yet.
Q3  megamod 0.3.0: containers without kept object references (key-based, engine queries), engine lookups instead of
    walks everywhere, creatures (unknown distance = no corpse removal; confirmed spawn), items partial state, wait
    re-checks before skipping, module start guard, marker cache identity; NEW module "movement": swimming speed
    multiplier, mounted scavenger speed multiplier (neutral 1.0; schema Page "Hero" -> app shows Hero > Movement).
Install rule unchanged: game closed, backup + rollback + audit, never launched by me.


## 2026-10-05 16:30 - Q1 (0.2.2) REVISED DESIGN + WHERE THE CODE STANDS (re-read after a context break)
DISASSEMBLY OF THE INSTALLED UE4SS.dll (copy: <proj>/re/UE4SS-installed-copy.dll;
helpers: scratchpad/dll/lib.py):
- FindAllOf / ForEachUObject (RVA 0x372130) skip items flagged Unreachable or with a null object. Left-over race =
  free + index reuse between two reads.
- Lua UObject IsValid (0x249cc0) = pointer in UE4SS's own set of wrapped pointers (added when a wrapper is made,
  removed by the engine's delete listener = ConditionalFinishDestroy, game thread) AND item(InternalIndex) not
  unreachable. On a freed, not reused block InternalIndex is overwritten -> the test rests on set membership only.
  Crash G receiver = FMallocBinned2 free-block header; crash F = memory reused by UTF-16 text. So a wrapper kept
  across ticks for a streaming actor CANNOT be trusted by IsValid or by a name check (the the other agent hotfix's name check
  passes on a freed, not reused block).
- Present in the DLL: RegisterBeginPlayPre/PostHook, RegisterEndPlayPre/PostHook, RegisterInitGameStatePre/PostHook,
  ExecuteInGameThread(+WithDelay, AfterFrames), LoopInGameThreadAfterFrames, IsInGameThread, FindObject(s),
  ForEachUObject; members IsA, GetAddress, GetClass, GetOuter, GetWorld, GetLevel, HasAnyFlags, HasAnyInternalFlags.
  LoadMap hook parameters = (Engine, World, URL, PendingGame, Error) wrappers with :get(); BeginPlay (Context);
  EndPlay (Context, Reason). Hooks call Lua on the game thread; Lua has one interpreter lock.
- Runtime image base 0x7ff6f3ff0000; GUObjectArray file VA 0x149bb25c0; member offsets as printed in UE4SS.log.

DESIGN OF 0.2.2 AS BUILT (differs from the queue text above in d and e):
(a) no reset on ClientRestart. Reset only: map load, game clock back > 5 s, profile changed, controller name
    changed. Settle time after a possession change; idle while the engine is paused; reasons always logged.
(b) the engine object comes from the LoadMap hook parameter (never searched): world = Engine.GameViewport.World,
    controller = GameplayStatics:GetPlayerController(world, 0), subsystems = engine / game libraries, world point
    manager = WorldPointManager:GetInstance(world). Old searches stay as the fallback, spaced (U.mayWalk 1 s, U.quiet).
(c) BeginPlay post / EndPlay pre hooks keep registries of interactive objects and character states (world.lua);
    an actor is dropped at EndPlay; fallback to the old way when the hooks are missing or prove unreliable.
(d) black box: "operations" ring file per session (fixed-size records, unbuffered) + report copy per session.
(e) gc.MultithreadedDestructionEnabled: OPT-IN ONLY (Config.Engine.FreeObjectsOnGameThread, default false) + an
    always-on observation note. Reason: timing safety of the switch cannot be shown without a test run; benefit
    narrower than first thought (the walk already skips unreachable items). TELL THE USER in one sentence.
    Engine IsValid in the helpers: marginal after (c) -> not added broadly.
(f) markers: imported textures kept alive via GameInstance.ReferencedObjects (Kit.keepAlive, read-back; fallback =
    cache per map-screen generation), checked binding, ensureLabel reconciliation, hover budget, NPC states
    re-acquired per refresh.
(g) honest writers (.tmp, read-back, .bak kept, backup fallback, .bad).
(h) creatures: evidence scans from the registry once it was verified against one walk; full census by a gated
    walk + cross-check; `Dead` entries with address; unknown distance -> no corpse removal. crime: subsystems fresh
    from the engine per check, recheck() only marks dirty, legacy walk gated. items: no periodic manager walk.

CODE STATE (source G1R_MegaMod, version file still 0.2.1):
DONE  Scripts/core/diag.lua (operations ring, per-session report), sandbox.lua (new registrations, searches
      announced as operations), Scripts/main.lua (Kit.setup), core/kit.lua (engine, subsystem, keepAlive,
      controller, objectDestruction), melee + wait (Kit.subsystem), dev/facts/kit.md (K12-K16 + notes), 7 harness
      helpers (*.log only), repopulate util.lua, world.lua (new), chests.lua, main.lua (version, profileKey,
      loadState, saveState).
TODO  repopulate main.lua (session handling, hooks, World.init / listen, status), creatures.lua, crime.lua,
      items.lua, markers main.lua, core/settings.lua writeText, Scripts/config.lua (Config.Engine), mock + harnesses
      (+ port the other agent verify_hotfix checks, fix 3 order-dependent repopulate checks), lint globals / allow list,
      diagread (.ops), FACTS (U14+, crash table A-G), docs, version 0.2.2, package, rehearsal, install (game
      closed, never launched), notes.


## 2026-10-05 (later) - Q1 (0.2.2) CODE STATE, supersedes the DONE / TODO list above
ALL SOURCE CHANGES OF 0.2.2 ARE IN; `python3 dev/run_tests.py` = 19 suites, 5985 checks, 0 failed, lint clean.
Added since the list above:
- repopulate main.lua (sessions: no reset on ClientRestart; resets only map load / clock back > 5 s / other
  controller / profile changed; idle while paused; status lines 6 + 7), creatures / crime / items / chests on the
  engine's ways and the play-hook registry, core/settings.lua verified writer, Config.Engine, markers 2.4.0.
- kit: doubt rule (`lastWord`): an engine "none" is final only once that way has answered in the run, else after
  10 s the search of 0.2.1 does the work (not counted while a map loads). Kit.controller asks the engine anew at
  every look (answer used 0.2 s). Kit.subsystem falls back to Kit.firstOf the same way. Note values
  "search (the engine's own way answered nothing)".
- WHEN PATHS ARE LOOKED UP (changed on purpose): NOT when the mod is loaded (UE4SS starts mods on its own thread
  while the engine initialises) but in the hook before the FIRST MAP LOAD the mod sees (game thread, engine
  complete, no world to play in yet). Kit: Kit.paths (6), answers final. Repopulate: main.lua firstMapLoad ->
  U.warm (U.paths + Crime.paths + World.paths + 2 libraries), answers kept found-or-not. world.lua resolves its two
  classes in W.reset() of the first map load; the registry is used from the first map load on; a mod started in a
  running game: note core.play_hooks = "waiting for a map load", old way until the next map load.
  Note keys: kit.paths_found, core.paths_found ("N of N found"). Loading the mod searches nothing (tests say so).
- tests: core/test_kit sections 13-17 (engine object, controller, subsystems, keepAlive, paths + object
  destruction), engine_cases.lua + 2 scenarios (started in a running game; classes not found), loader tests
  (START_SEARCHES = 0), T.searches(ctx) in dev/tests/lib/modtest.lua (searches without the kit's own).
- kit.object_destruction keeps "game thread (set by this mod)" at later map loads.
STILL TO DO FOR 0.2.2 (in this order):
 1. mutation checks: world.lua + session code of repopulate main.lua (suite repopulate_engine), kit engine section
    (suite core), markers texture code (suite markers).
 2. dev/tools/diagread.py: .ops ring ("in flight at the end"), per-session reports; tools suite.
 3. docs: dev/facts/*.md status upgrades from the in-game notes, Scripts/diagnostics/README.txt, CHANGELOG.txt,
    README.txt (Config.SettleSeconds, Config.Engine, .bak files, resetting progress), dev/AI_GUIDE.md, module
    READMEs; Scripts/core/version.lua -> 0.2.2.
 4. package (dev/tools/build_release.py), installer rehearsal on copies (new player-side files: state/*.bak /
    .tmp / .bad, config.lua.bak, diagnostics/*.ops, *.report.txt; hotfix state of util.lua / chests.lua on the PC),
    install with the game closed (backup, rollback, audit; commit from a NEW staged folder and compare SHA-256),
    notes, report (one sentence: object-destruction switch is off by default and why). NEVER launch the game.


## 2026-10-05 18:10 MDT - Q1 (0.2.2): steps 1-3 DONE, step 4 next (re-read this after a context break)
State: `python3 dev/run_tests.py` = 19 suites + lint, 6168 checks, 0 failed. Version file 0.2.2.
THE GAME WAS RUNNING ON THE PC at 17:30 (PIDs 26396 / 27600, started 15:42:38, megamod 0.2.1 + the other agent hotfix:
util.lua 28CA4DF7..., chests.lua 07E7375B...). NOTHING IS INSTALLED WHILE IT RUNS; never launch or stop it.
Added after the note above:
- Live session read from the PC (copies: megamod\live-session-20261005-1542\): 0.2.1 walked all objects in the main
  menu - repopulate FindFirstOf 9325 (clock, every update, 40 min), markers FindAllOf 86 (map screen), mining
  FindAllOf 43 (ability, once a minute). The menu has a hero, no game clock, no mining ability.
- repopulate: clock search pauses 2, 4, 8 ... 120 s (util.lua TimeSearchMisses; reset by U.resetTime at a map load);
  tick asks U.paused() BEFORE the clock / controller; world.lua W.check judges "no end of play call" only for a
  world with >= 200 begins that a map load took away (Mark table); FACTS R27.
- mining: the hero's own ability list is read at pauses up to 60 s (as 0.2.1), the search among all objects at
  pauses of its own up to 600 s (S.scanAt / S.scanPause); facts M23.
- markers 2.4: no map-screen scans when NotifyOnNewObject is registered (note markers.map_screens); StaticLookupOk
  kept across map loads; a missing KismetRenderingLibrary is said once; new scenarios in pictures_cases.lua
  (screen at the old address within one update / by search, class default object, screen gone before the update,
  no picture loader, controller without world). Mutation: lines 360-505 and 2120-2245 = 0 unexplained
  (dev/tests/markers/mutations_accepted.txt).
- suites world (91 checks, mutation 0 unexplained), tools (diagread: .ops, session reports, --session).
- docs done: CHANGELOG 0.2.2, README ("What has run in the game"), module READMEs, facts (R26, R27, M14, M15, M23,
  kit K13-K17), diagnostics README, AI_GUIDE, MODULES.
Running in the background: mutation of repopulate util.lua and main.lua against both repopulate suites from the
snapshot <scratchpad>/snap1 (results <scratchpad>/mut/{util,main}_{engine,search}2.txt; bg2_done.txt when finished).
A survivor counts only when it survives BOTH suites.
STILL TO DO: (4) quote the final suite / check counts in CHANGELOG + README; build_release.py (--check; plain and
--with-dev; --forbid-file release-forbid.txt; --foreign for the 5 zips in <scratchpad>/foreign);
installer PACKAGE constant -> 0.2.2; sim_megamod.py; rehearsal on copies on the PC; --check on the PC; install ONLY
with the game closed (backup, rollback, audit, UE4SS.dll + saves hashes, settings files untouched; stage from a NEW
folder name, compare SHA-256); notes file G1R_MegaMod-0.2.2-notes.md; report (one sentence: Config.Engine.
FreeObjectsOnGameThread is off by default and why). Then Q2 (settings app 2.0), Q3 (0.3.0: hardening rest + module
movement).


## 2026-10-05 18:17 MDT - megamod 0.2.2 INSTALLED on the PC (re-read this first after a context break)
- The game ended on its own at about 17:57 (no crash folder; session 15:42 - 17:57 with 0.2.1 + hotfix, 130 min in
  the report, 0 errors). Evidence copies: megamod\live-session-20261005-1542\ (final log, report, UE4SS.log,
  profile_0-after-session.lua).
- Tests: 19 suites + lint, 6168 checks, 0 failed. Package G1R_MegaMod-0.2.2-dev.zip sha256
  f88a655f074c63860ec0422fe8b7bd469d85bc61b5c0fc7e179a6ea4692ce187 (433 files; plain zip 25da8638...; built with
  --forbid-file and --foreign x5). Against 0.2.1: 10 added, 0 removed, 62 changed (29 outside dev/).
- Installer: only PACKAGE changed (install_megamod.py sha256 13cfca47...; audit / sim unchanged). Linux sim 332 ALL OK
  (source tree and exact package). PC rehearsal megamod\rehearsal-0.2.2\ (copies of the real folders, PowerShell 5.1 +
  7.6.6): 47 checks ALL OK.
- INSTALLED 18:17: update 0.2.1 -> 0.2.2, 10 added, 61 replaced, 350 same, 12 player files kept, 14 other files left
  alone (5 config.lua.bak, settings exe, profile_0.lua, 7 diagnostics files). Backup + rollback:
  megamod-install-backup-20261005-181741 (its `replaced` folder holds the hotfix util.lua 28CA4DF7... / chests.lua
  07E7375B...). AUDIT OK (29 checks): UE4SS.dll e1909f98..., mods.txt, mods.json, 55 saves, 92 other files unchanged.
- Offline start of the package with his 11 settings files + his progress file: ten modules ok, 0 errors (xp x10,
  Y = 30 minutes, containers 50 % / 15 %, mana up to 100 %); his profile_0.lua is read by 1.4 (401 points, 92
  containers waiting, 82 restocked and not opened). Copies: megamod\settings-before-0.2.2-20261005\.
- Notes: G1R_MegaMod-0.2.2-notes.md (outputs + project folder on the PC, sha256 2c9e66da...). User told (message).
- The game was NOT started. 0.2.2 has NOT run in the game.
- STILL RUNNING / TO DO: mutation results of repopulate util.lua / main.lua (snapshot = installed code); a finding
  that changes code -> 0.2.3 (install only with the game closed). Then: read the first 0.2.2 session when there is
  one (UE4SS.log, diagnostics incl. .ops); dev archive megamod-dev-archive-0.2.2.zip; Q2 settings app 2.0 (tasks
  #63-#68, plan /root/.claude/plans/ethereal-herding-bee.md); Q3 megamod 0.3.0 (#80-#82).


## 2026-10-05 18:25 - NEW QUEUE ITEM (user, verbatim): "Add into the list an option in the megamod to skip the intro"
-> tasks #83 (feasibility: what plays at start - startup movies / logo screens / new-game intro cutscene - and what a
   UE4SS Lua mod can skip; mods start ~1 s after injection, while the engine initialises) and #84 (setting, tests,
   settings app). Queue place: Q3 megamod 0.3.0, next to module "movement". Neutral default = off (the game as it is).
   Which intro he means is not said: settle it in the feasibility step (most likely the logo / intro movies at game
   start; the new-game cutscene is the other candidate) and say in the report which one the option covers.


## 2026-10-05 18:35 - TWO MORE QUEUE ITEMS (user, verbatim):
"Add while megamod is installed, a spot in the menu in the top left when you hit escape and you're in the pause menu
where it shows you all of your modded keybinds and what they do, or a keybind that reveals that list. Have it be
fairly unobtrusive, and also change all the in-game mod text to the gothic text, or as close as you can get."
-> tasks #85 / #86 (key list: pause menu top left and / or a key; unobtrusive; megamod's own keys from the kit's key
   registry; other mods' keys: their settings read only where they can be read, else a list the player edits),
   #87 / #88 (the game's own font for every text the megamod shows: note box, key list, wait's buttons; map pin names
   and lists are pictures made beforehand - draw as text with the game's font, or make anew in the closest font that
   may be used; SharedModMenu's pages are another author's drawing).
Queue order now: Q2 settings app 2.0 -> Q3 megamod 0.3.0 = hardening rest (#80), movement speeds (#81, #82), skip
intro (#83, #84), key list (#85, #86), Gothic font (#87, #88). He was told the order; he can change it.


## 2026-10-05 18:40 - ONE MORE QUEUE ITEM (user, verbatim): "Also add task to allow changing of the distance of auto
highlight and auto loot"
-> tasks #89 (feasibility) / #90 (settings, tests, app). On the PC: highlight = FocusNearbyPickups (another author's
   Lua, repaired by the other agent 10-04; where it is loaded from: find out), loot = G1R_AutoPickUpItemNative (another author's
   native mod, Mods\G1R_AutoPickUpItemNative). Both must keep working. Find where each distance comes from (the mod's
   own setting / a constant in its code / a value of the game) and take the way that touches the least. Queue: Q3.

## 2026-10-05 19:25 MDT - NEW QUEUE ITEM: on-screen timers for spell effects (tasks #91 done, #92 open)

User, verbatim: "investigate if it's possible to add an onscreen timer for spell effects and for how long they'll
last, like light." Feasibility done: `research/q3/spell-timers.md`. Possible. Light: 300 s timer on the light actor
(`ALightSpellVisual.TaskTimer`, config `LightSpellConfig.m_LifeSpan`), tag `State.Spell.Light` on the hero; engine
timer call or own count. Other timed effects through the ability system's query functions (in the executable, not
yet called from Lua in the game). Goes into megamod 0.3.0 unless he says otherwise.

## 2026-10-05 19:05 MDT - megamod 0.2.2 in the game (first session, started 18:24:47)

40 minutes at 19:04:54: 0 errors, all ten modules loaded. Notes: `kit.engine` / `core.engine` handed over at a map
load; `core.play_hooks = in use` (17180 begins, 8935 ends of play, 0 errors); controller, game clock, profile, crime
subsystems, item manager all `engine`; `kit.paths_found = 6 of 6`, `core.paths_found = 14 of 14`. repopulate: 16
searches in the whole run (all first-time path lookups), no FindAllOf / FindFirstOf. The menu was left after 10 s, so
the clock fallback (R27) did not run. Map pins (2.4) not exercised: no map opened. Copies on the PC:
`megamod\first-session-0.2.2-20261005-1824\`. Idea for 0.3.0: magic's "look N (check)" line every minute fills the
recorder's last-120 window - record it only when something changed.

Mutation follow-up (util.lua / main.lua of repopulate), in work: cross run left 123 / 160 survivors; most are nil
guards with a nil-safe continuation or texts. Real gaps: state file load / save conditions, settings reload timing,
master switch, console, summary texts, walk spacing (calm wait), engine object refusals. One weakness found so far:
`U.mayWalk` keeps `WantedSince` after a wish that was dropped (map load), so a later walk in a not-calm moment is
not put off. Fix + tests go into the next package.

Settings app 2.0: written, verified under Wine on Linux (selftest 121, uitest 54, pictures of all 24 tabs). Linux
build tools: `<cloud home>/dotnet` (SDK 8.0.404), `<scratchpad>/wine-run.sh`. Waits for a closed game: build on the
PC, selftest / uitest / snapshots there, install with `install_megamod.py --settings-app`.

2026-10-05 19:40 - #92 spec from the user (verbatim in `research/q3/spell-timers.md`): all own timed effects + other
over-times found, a toggle per timer in the in-game menu (and settings app), very small, bottom left or above the
health bar.

2026-10-05 20:10 - feasibility of #83 (skip intro), #85 (key list), #87 (Gothic font), #89 (highlight / loot
distance) written down: `research/q3/feasibility-0.3.0.md`. All four possible; skip intro and the two distances
work through files read at game start (next start), key list and font through the mod's own widgets.

## 2026-10-05 20:10 MDT - HANDOFF: read `PLAN-NEXT.md` first (replaces this log as the thing to work from)

Mount module written (untested), repopulate util fix + new suites in the tree, app 2.0 verified on Linux; queue and
exact next steps in `PLAN-NEXT.md`. The player asked for one cohesive plan and a model switch (to Opus 5.5).

## 2026-10-05 20:32 MDT - megamod 0.2.3 INSTALLED (mount module); read `PLAN-NEXT.md` first after a context break
0.2.2 session ended 19:47 without a crash (82 min, 0 errors). 0.2.3: 443 files, 10 added / 10 replaced / 411 same,
backup megamod-install-backup-20261005-203211, AUDIT OK 29, UE4SS.dll unchanged. Notes: G1R_MegaMod-0.2.3-notes.md.
