# Facts: module wait

What has run in the game: the section "Seen in the game" at the end. Sources: the game executable (`re/redis_.py`, addresses of build
`Build83_CL174209`), the property layout (`usmap.py`), the script bindings (`re/binds_strings.txt`), the game's
scripts (`as-src`), the UE4SS source and the installed UE4SS.dll.

| # | What | Where | Status | Note key |
|---|---|---|---|---|
| W1 | The game's clock is `GameTimeSubsystem.CurrentGameTime.TotalSeconds` (a struct `InGameTime` with that one field, a double: game seconds since the game began; day = seconds / 86400, counted from 0). | `main.lua` `firstLook`, `secondLook`, `attempt` (through `KIT.gameSeconds`, facts K5) | IN-GAME for reading it (module repopulate, R1) | `wait.clock` |
| W2 | `GameTimeSubsystem:SkipTime(const FInGameTime& Duration)` is a native UFunction (one parameter, 8 bytes, const reference) that Lua can call. | `main.lua` `WAYS` | DISASM (`params.py SkipTime`); another author's mod (G1R_WaitOnT) calls it, but no log shows that call | `wait.way` |
| W3 | All SkipTime does: `clock = (double)(float)(clock + Duration.TotalSeconds)`, inside the call. No state is asked (not even whether the clock is frozen), nobody is told. The sum goes through single precision: the clock is then on a step of 1/32 s around day 4, of half a second from day 49, of one second from day 97, of two from day 194. | `main.lua` `attempt` (the clock is read right after the call), `remaining` (aims past the hour), `done` (what counts as "as asked") | DISASM (native function at `0x1459d2ec0`, six instructions) | `wait.applied`, `wait.moved` |
| W4 | A struct parameter can be given as a plain Lua table with the field names; UE4SS fills the struct from it (`{ TotalSeconds = seconds }`). A struct a function returns arrives as a Lua table too. | `main.lua` `WAYS` (first and second way) | SOURCE (UE4SS `LuaUObject.cpp`: `push_structproperty`, `convert_lua_table_to_struct`) + DISASM (the same error texts are in the installed UE4SS.dll); IN-GAME for other structs (module markers passes positions and colours as tables) | `wait.way` |
| W5 | The game's time library: default object `/Script/G1R.Default__FInGameTimeStatics` (class `UFInGameTimeStatics`), `FromSeconds(double) -> FInGameTime` (static, BlueprintCallable; also `FromMinutes`, `FromHours`, `FromDays`, `Make`). | `main.lua` `WAYS` (second way) | SOURCE (`binds_strings.txt` 80115 ff.) + DISASM (`params.py FromSeconds`: `Seconds:Double@0`, `ReturnValue:Struct@8`) | `wait.time_library` |
| W6 | Reading `subsystem.CurrentGameTime` gives a struct that points into the object: writing its `TotalSeconds` writes the clock - which is all SkipTime does (W3). | `main.lua` `WAYS` (third way) | SOURCE (UE4SS: a struct property read is `Operation::Get`) ; the same mechanism is IN-GAME for attributes (facts K3) | `wait.way` |
| W7 | The clock runs at `GameTimeSpeed` = 15 game seconds per real second (a day = 96 minutes). Two readings a quarter second apart differ by about 4 game seconds; more than 60 + 60 per real second is not the clock's own pace. The module does not rely on the 15: the pace it measures between a request's two readings is what it takes off, for the real time that passed, before a clock that moved only a look after the call counts as skipped (a stall is not a skip). | `main.lua` `secondLook` (`JUMP`, `JUMP_PER_SECOND`), `checkLook` (`LATE`) | SOURCE (`as-src/Environment/G1RGameTimeConfig.as`); DISASM for the tick (`0x1459d4410`: clock += DeltaTime x speed unless frozen) | `wait.clock_running` |
| W8 | The clock stands still while the game lets no time pass: a cutscene freezes it (`GothicCinematic`: `FreezeTime` at its start, `UnfreezeTime` and `SetCurrentClockTime(SavedTime)` at its end - a skip made meanwhile would be put back), and a paused engine does not step. | `main.lua` `secondLook` | DISASM (callers of `FreezeTime` / `UnfreezeTime`, `0x1457eb7b0` ff., `0x1457e1853` ff.); whether the game's menus stop the clock is UNKNOWN | `wait.clock_running` |
| W9 | What goes by the clock catches up at the game's next step after any jump: the subsystem's tick fires every clock-time alarm between the old and the new time (hour buckets, the span taken modulo a day) and every one-shot alarm up to the new time. The game makes such jumps itself: sleeping (native loop: `SkipTime` of at most one hour, then every character's daily routine simulation is forced to update, repeated) and the dream regions of the Sleeper temple (`AdvanceToClockTime`, one jump of up to a day, `as-src/Regions/Traits/SleeperTempleRegionTraits.as`). After a skip from this module nothing is forced: a character's day plan has its own alarm (`OnPotentialTaskSwitchFromTime`, every 600 game seconds), which is due at once. The hero's hourly needs (hunger, thirst, tiredness, sleep-time recovery: `GameplayAbilityPassiveHourlyEffectBase`, handler `OnNextHourlyEffectGameTimeReached`) apply their effect once for every period that fits into the skipped time: waiting counts in full, it is not rest. | header of `main.lua`, README | DISASM (`0x1459b5ff0`, `0x1459b6290`, the sleep loop near `0x145ab6ce9`, `0x14569b090`, `0x145b386a0`); how any of it looks in the game is UNKNOWN | - |
| W10 | The hero's pawn (`Character`) has `Mesh`, the mesh has `AnimScriptInstance`, and that animation object (`GothicAnimInstance`) has the yes/no properties `m_IsInCombat`, `bIsInConversation`, `bIsInCinematic`. `m_IsInCombat` is taken to follow the tag `State.Combat`, which the game gives with a drawn weapon (`as-src/GAS/Effects/Items/GE_Weapon_Equip.as`). | `main.lua` `heroState`, `FLAGS` | SOURCE (property layout); that the game keeps these values up to date for the hero is UNKNOWN | `wait.states` |
| W11 | A name that is neither a property nor a function gives an empty object from UE4SS, not nil and no error: a missing value is recognised by not being a boolean. | `main.lua` `heroState` | SOURCE (UE4SS `LuaUObject.cpp` `handle_unreal_property_value`) | `wait.states` |
| W12 | Key functions fire in this UE4SS build (facts K7). The in-game menu mod says in its settings file that function keys and the number pad are what this build delivers reliably; nothing is known about letter keys. | `main.lua` `bind`, `request` | UNKNOWN | `wait.key_press` |
| W13 | The in-game mod menu does not pause the game (it only takes the input and shows the cursor), so its buttons can skip time. | `main.lua` `Settings.onAction` | SOURCE (the menu mod's `render.lua`) | - |
| W14 | The loader does not load the module while a mod folder `G1R_WaitOnT` with `Scripts/main.lua` is enabled. A copy of that mod under another folder name cannot be seen; when it skips on the same key press, the clock jumps between this module's two readings and this module adds nothing (W7). | `Scripts/core/modules.lua`, `main.lua` `secondLook` | OFFLINE | `wait.clock_running` |

## Seen in the game

megamod 0.2.1, session of 2026-10-04 21:19 - 23:39 (140 minutes, report of 23:39; 0 errors); keys: Y = 30 minutes, OEM_SIX = until 08:00. Status at the end: "skips: 2; last: 6 hours
48 minutes, day 12 01:12 -> day 12 08:00, by SkipTime with a plain value (seen at once)".

| Note seen | What it settles |
|---|---|
| `wait.key_press = seen` | IN-GAME: a key registered with `RegisterKeyBind` fires in this build and the kit's loop on the game thread runs its action (facts K7) |
| `wait.clock = found`, `wait.clock_running = yes` | IN-GAME: W1, and the clock was running when the key was pressed |
| `wait.way = table` | IN-GAME: W2, W4 - `SkipTime` called with a plain Lua table `{ TotalSeconds = ... }` |
| `wait.applied = at once`, `wait.moved = as asked` | IN-GAME: W3 - the clock had moved by the asked amount right after the call |
| `wait.states = readable` | IN-GAME: the hero's states (fight, talk, cutscene) could be asked before the skip |

Not seen: a wait refused because of a fight, a talk or a cutscene; the other ways of calling `SkipTime` (never
needed); waits of more than one day.

## Diagnostics notes

| Note key | Expected | If it differs / what it settles |
|---|---|---|
| `wait.key_press` | `seen` | W12 / K7: noted when the first key press reaches the module. Not seen although a key is bound and was pressed = key functions do not fire in this build (or not for that key): use the menu buttons |
| `wait.clock` | `found` else `not found` | W1: not found = no time subsystem or no readable clock when a skip was asked for (no game loaded?) |
| `wait.states` | `readable` else `not readable` | W10: not readable = the hero's animation values could not be read (the detail names them); the switches that need them have no effect |
| `wait.clock_running` | `yes` else `standing still` or `jumped` | W7, W8: standing still = the clock did not move between the two readings (cutscene, pause); jumped = something else skipped time in that quarter second (the detail has the numbers) |
| `wait.way` | `table` else `library` or `clock` | W2, W4, W5, W6: which way moved the clock. library / clock = the ways before it left the clock where it was (UE4SS.log names why); none = nothing works, the detail lists every reason |
| `wait.applied` | `at once` else `a moment later` | W3: a moment later = the clock had not moved right after the call, only a look later |
| `wait.moved` | `as asked` | W3: differs = the clock moved by another amount than asked (the detail has both) |
| `wait.time_library` | `found` else `not found` | W5: only noted when the second way is tried |
