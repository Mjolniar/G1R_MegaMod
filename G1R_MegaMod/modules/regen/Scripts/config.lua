-- ============================================================================
-- Mana and health regeneration (module regen of G1R_MegaMod)
-- Easiest way to change these: the settings app, page "Combat", or the
-- in-game mod menu. Changes are picked up while the game is running.
-- With every amount at 0 (the values the mod ships with) nothing regenerates.
-- ============================================================================
local Config = {}

-- ---- Mana regeneration ----
-- false = the module does nothing; mana and health stay as the game handles them.
Config.Enabled = true
-- false = mana does not regenerate. With both amounts below at 0 it does not either.
Config.ManaEnabled = true
-- Each step restores this share of the hero's maximum mana, in percent.
-- 0 = no share. Example: 2 with 60 maximum mana = 1.2 mana per step.
Config.ManaPercent = 0.0
-- Each step also restores this many points of mana, whatever the maximum is. 0 = none.
Config.ManaFlat = 0.0
-- The time between two steps, in seconds of play.
Config.ManaSeconds = 3.0
-- Regeneration stops at this part of the maximum mana; the rest takes potions or sleep.
-- 100 = up to the maximum.
Config.ManaUpTo = 100
-- After mana went down (a spell), regeneration waits this long before it goes on.
-- 0 = no waiting. The same wait runs once after a game was loaded.
Config.ManaPause = 10
-- While the hero holds a drawn weapon, his fists up or a spell ready, each step restores
-- this share of the usual amount. 100 = no difference, 0 = nothing, 50 = half.
Config.ManaArmedPercent = 100

-- ---- Mana regeneration by magic circle ----
-- false = everyone gets the same amount. true = the four numbers below apply.
Config.ManaByCircle = false
-- The share of the amount a hero without any magic training gets, in percent.
Config.ManaCircleNone = 50
-- The share for a hero who has learned the basics of magic but no circle yet.
Config.ManaCircleNovice = 75
-- The share for a mage of the first circle.
Config.ManaCircleFirst = 100
-- Each circle above the first adds this many percent.
-- Example: 100 in the first circle and 10 here = 150 in the sixth.
Config.ManaCircleStep = 10

-- ---- Health regeneration ----
-- false = health does not regenerate. With both amounts below at 0 it does not either.
Config.HealthEnabled = true
-- Each step restores this share of the hero's maximum health, in percent.
-- 0 = no share. Example: 1 with 150 maximum health = 1.5 health per step.
Config.HealthPercent = 0.0
-- Each step also restores this many points of health, whatever the maximum is. 0 = none.
Config.HealthFlat = 0.0
-- The time between two steps, in seconds of play.
Config.HealthSeconds = 5.0
-- Regeneration stops at this part of the maximum health; the rest takes food, potions or sleep.
-- 100 = up to the maximum.
Config.HealthUpTo = 100
-- After health went down (a hit, a fall), regeneration waits this long before it goes on.
-- 0 = no waiting. The same wait runs once after a game was loaded.
Config.HealthPause = 20
-- While the hero holds a drawn weapon, his fists up or a spell ready, each step restores
-- this share of the usual amount. 100 = no difference, 0 = nothing, 50 = half.
Config.HealthArmedPercent = 100

-- ---- Mana regeneration and health regeneration: on screen, log ----
-- A short note on screen when mana or health starts to regenerate after a wait, and when it has
-- reached its limit. How notes look is set on the page "General".
Config.ShowMessage = false
-- One line in UE4SS.log for every step that restored something.
Config.LogSteps = false

return Config
