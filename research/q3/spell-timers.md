# On-screen timers for spell effects - feasibility (task #91, 2026-10-05)

Request: "investigate if it's possible to add an onscreen timer for spell effects and for how long they'll last,
like light."

Verdict: possible. Light with parts that have run in the game; the general list of timed effects needs three
engine calls no mod has made in this game yet (first session decides, each with a fallback).

## Light (SOURCE: as-src)

- `Spells/Spell_Light.as`: `ULightSpellConfig.m_LifeSpan = 300.0` (UPROPERTY, seconds), default object
  `/Script/Angelscript.Default__LightSpellConfig`. Writable like the magic module's other config values
  -> "how long Light lasts" could be a setting of the module magic.
- `GAS/Abilities/Spells/Visuals/Light/LightVisual.as`: `ALightSpellVisual` (blueprint
  `/Game/Items/Magic/Light/BP_LightSpellVisual.BP_LightSpellVisual_C`), attached to the caster.
  `Initialize()` -> `SetUpConfig()`: `TaskTimer = System::SetTimerDelegate(DoDestroy, lifeSpan)`;
  `TaskTimer` is a UPROPERTY `FTimerHandle` (`Handle: UInt64`). After a load the remaining time comes from the
  save: `m_LastTimeSpan` (UPROPERTY) is used instead of `m_LifeSpan`. `m_AccumulatedTime` (the running remaining
  time) is NOT a UPROPERTY: not readable.
- The timer is paused while the caster talks (`State.Conversation` tag event -> `PauseTimerHandle`), ended when the
  hero goes to sleep (`OnPlayerGoToSleep` -> `DoDestroy`), and by casting Light again (`CastToCancelSpell`).
- While the light is on the caster's ability system has the effect `UGE_Spell_Light` (infinite) and the tag
  `State.Spell.Light` (script tag: the string is not in the executable; `GameplayTag::State_Spell_Light`).

Ways to the remaining time:
1. Engine timer: `KismetSystemLibrary:K2_GetTimerRemainingTimeHandle(WorldContextObject, Handle) -> float`
   (DISASM: params.py, 0x149818e80, flags 0x14022403) with the actor's `TaskTimer`; `K2_IsTimerPausedHandle` too.
   Exact, follows pauses and saves. Struct parameter from Lua: UNKNOWN in game.
2. Own count: starts when `HasGameplayTag({TagName=FName("State.Spell.Light")})` turns yes (that call is IN-GAME:
   locks / mining / regen), length from `m_LifeSpan`, counted on `GameplayStatics:GetTimeSeconds(world)` (stops with
   the game's pause), held while `State.Conversation`. After a load: `m_LastTimeSpan` of the actor.
Finding the actor without a search among all objects: `NotifyOnNewObject("/Script/Angelscript.LightSpellVisual")`
(IN-GAME for other classes), or `hero:GetAttachedActors(out, true, true)` (DISASM 0x1497b6230).

## Timed gameplay effects (GAS)

Functions in the executable (params.py):
- `AbilitySystemComponent:GetActiveEffectsWithAllTags(Tags: GameplayTagContainer) -> Array<ActiveGameplayEffectHandle>`
  (0x14985d0b0), `GetActiveEffects(Query: GameplayEffectQuery)` (0x14985d070, 408-byte struct: avoid),
  `GetGameplayEffectCount(Class, nil, bool) -> int` (0x14985d1f0: plain parameters).
- `AbilitySystemBlueprintLibrary`: `GetActiveGameplayEffectRemainingDuration(WorldContextObject, Handle) -> float`
  (0x14985a4a0), `...TotalDuration`, `...StartTime`, `...ExpectedEndTime`, `...StackCount`,
  `GetGameplayEffectFromActiveEffectHandle(Handle) -> GameplayEffect` (0x14985a9e0), `...DebugString`.
- Handle struct: `ActiveGameplayEffectHandle { Handle: Int, bPassedFiltersAndWasExecuted: Bool }`.
All UNKNOWN in game (struct in, array of structs out).

Effects with a duration (SOURCE: as-src, DurationPolicy 2):
- on the hero from items: `GE_Item_Heal_Overtime`, `GE_Item_Mana_Overtime` (duration set by the item,
  `GE.Param.Duration`), `GE_Item_AlcoholDrugDepletion_Overtime`, `GE_Item_SwampweedDrugDepletion_Overtime`
- elemental: `GE_Burn` 10 s, `GE_Damage_Fire_Duration` 1 s / `_5s_Burning`, `GE_Freeze` (`_5Secs`,
  `GE_IceStack_Freeze` 8 s), `GE_Electrified`, `GE_Wind` 5 s, `GE_Slowdown`
- mind spells on a target: `GE_Sleep` (config 30 s), `GE_Charm` (60 s), `GE_Fear` (10 s) - on the target's
  ability system, not the hero's
- cooldowns: call mount 3 s, wall climbing 0.5 s, freeze 5 s, transform cast 1.5 s (not worth a timer)
Not timed by the game (nothing to count down): transformation (until cancelled), summoned creatures
(`GE_Summoned` infinite), shrink, control / telekinesis / pyrokinesis (held spells).

## Drawing

`Scripts/core/kit.lua` builds its note box from Lua (UserWidget, CanvasPanel, Border, TextBlock; IN-GAME). A list
that stays is the same kind of widget without the expiry; the font task (#87) covers it.

## Plan for #92

Module `timers` (or part of `general`): list in a corner, one line per effect, "Light 4:32"; settings: on / off,
corner, which groups (Light; food and potions; burning / frozen / ...; effects on the target in focus), warn colour
below N seconds. First session: notes say which way each timer came from (`timers.light_by = engine timer |
own count`, `timers.effects = readable | not readable`).

## The player's choice (2026-10-05 19:40, verbatim)

"On you: heal / mana over time from food and potions, alcohol, swampweed, burning (10 s), frozen (5-8 s),
electrified, wind (5 s), slowed. - all would be good, as well as any other over times that you could think of.
Toggles in the menu. Display very small in bottom left of screen, or over health bar"

So for #92:
- Timers: Light; heal / mana over time (food: `Items/GenericItems/FoodGeneric.as`, durations 1 - 75 s per item via
  `GE.Param.Duration`); alcohol and swampweed; burning, frozen, electrified, wind, slowed; other over-times found.
- A toggle per timer (group) in the in-game mod menu and in the settings app; one switch for the whole list.
- Very small text. Position setting: bottom left of the screen (default) / above the health bar.

More sources found (SOURCE):
- Alcohol / swampweed are levels, not durations: `AttributeSet_Alcohol.Alcohol` falls by `AlcoholDepletionRate` every
  second (`GE_AlcoholDepletion`, infinite, period 1 s; -20 per second while swimming); states Tipsy / Intoxicated /
  Drunk by level (`GE_AlcoholDebuff*`: Strength +10 / +15 %, Toughness +15 / +25 %, Dexterity -10 %, max mana
  -15 / -40 %, Drunk: max health +15 %, weapon skill untrained). Time until sober = level / rate: plain attribute
  reads (the kind regen already does IN-GAME). Same shape for swampweed (`Debuffs/Drugs/Swampweed/GE_Swampweed.as`).
- Defeated (knocked out): `GE_Defeated` has a duration (set by the caller) -> "up again in ...".
- Sleep / fear / charm cast on the hero are duration effects on his own ability system.
- Hunger / thirst: passive abilities `GAS/Abilities/Passive/GA_Hunger.as`, `GA_Thirst.as` (look at them: a level
  that falls over time?). Breath under water: not looked at yet.
- Our own: the regen module's wait after a loss (mana 15 s, health 30 s in his settings).
- The player's bars: native widget class `/Script/G1R.PlayerBarHealthMana` (`GameplayAttributeProgressBarWidget`,
  `m_CurrentValueAttribute` tells health from mana, `m_Visibility` EGothicHUDBarVisibility,
  `m_TimeOnScreenOnDynamic`): its place on screen from its cached geometry; announced by NotifyOnNewObject. When it
  cannot be read: bottom left.
- Gothic font (#87): the HUD has `/Game/UI/Crosshair/W_DisplayName_GothicFont.W_DisplayName_GothicFont_C`
  (`UHUDDisplayNameGothicFontController`): its text block's font object is the game's Gothic font.
