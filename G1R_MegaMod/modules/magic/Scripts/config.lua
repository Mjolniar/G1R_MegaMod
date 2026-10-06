-- ============================================================================
-- Magic balancing (module magic of G1R_MegaMod)
-- Easiest way to change these: the settings app, page "Combat", or the
-- in-game mod menu. Changes are picked up while the game is running.
-- A multiplier of 1.0 leaves the game's own number alone; with every setting as
-- shipped the module does not touch the game at all.
-- ============================================================================
local Config = {}

-- ---- Magic: all spells ----
-- false = the module does nothing; every spell and every price is as the game has it.
Config.Enabled = true
-- Damage of every damage spell. 1.0 = unchanged, 1.5 = half as much again, 0.5 = half.
-- It holds for everyone who casts with the hero's runes and scrolls, human mages included.
Config.Damage = 1.0
-- What a spell costs to cast, and what a held spell costs each second. 1.0 = unchanged, 0 = free.
Config.ManaCost = 1.0
-- true = a changed mana cost is rounded to whole points. It never becomes 0 unless a multiplier is 0.
-- The game counts mana in whole points. false = the exact product is written (2 x 1.25 = 2.5);
-- what the game makes of half a point is not known.
Config.WholeMana = true
-- The time a spell takes to cast, or to charge to its next level. 1.0 = unchanged, 0.5 = twice as fast.
Config.CastTime = 1.0
-- How fast fire bolt, ice bolt, fire ball, ball lightning and the storm of fire fly. 1.0 = unchanged.
Config.ProjectileSpeed = 1.0
-- How far a target spell finds its target and how far three area spells spread. 1.0 = unchanged.
-- Target spells: sleep, charm, shrink, heal, pyrokinesis, chain lightning, telekinesis, control.
-- Area spells: storm fist, death to the undead, Uriziel's wave of death. Other spells keep their reach.
Config.Range = 1.0
-- How much of a foe's steadiness a spell hit takes away (what makes him stagger or fall). 1.0 = unchanged.
Config.Stagger = 1.0
-- The health a step of the heal spell gives back. 1.0 = unchanged.
-- The game has 4 to 30, by the caster's circle.
Config.HealAmount = 1.0
-- Damage of the five fire spells, on top of the multiplier for all spells. 1.0 = unchanged.
-- Fire bolt, fire ball, pyrokinesis, storm of fire, rain of fire.
Config.SchoolFire = 1.0
-- Damage of the three ice spells, on top of the multiplier for all spells. 1.0 = unchanged.
-- Ice bolt, ice block, ice wave.
Config.SchoolIce = 1.0
-- Damage of the four energy spells, on top of the multiplier for all spells. 1.0 = unchanged.
-- Ball lightning, chain lightning, Uriziel's wave of death, death to the undead.
Config.SchoolEnergy = 1.0
-- Damage of the three wind spells, on top of the multiplier for all spells. 1.0 = unchanged.
-- Fist of wind, storm fist, breath of death.
Config.SchoolWind = 1.0

-- ---- Magic: fire spells ----
-- Damage of the fire bolt, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 35, up to 65 with the caster's circle.
Config.FireBoltDamage = 1.0
-- Mana cost of the fire bolt, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 1 a shot.
Config.FireBoltMana = 1.0
-- Casting time of the fire bolt, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 0.1 s.
Config.FireBoltCastTime = 1.0
-- Damage of the fire ball, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 90 / 110 / 130 by charge.
Config.FireBallDamage = 1.0
-- Mana cost of the fire ball, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 1 / 2 / 2 by charge.
Config.FireBallMana = 1.0
-- Charging time of the fire ball, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 0.4 / 0.6 / 0.8 s by charge.
Config.FireBallCastTime = 1.0
-- Damage of pyrokinesis, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 20, from the 5th circle 35.
Config.PyrokinesisDamage = 1.0
-- Mana cost of pyrokinesis, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 5, then 1 a second.
Config.PyrokinesisMana = 1.0
-- Casting time of pyrokinesis, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 0.5 s.
Config.PyrokinesisCastTime = 1.0
-- Damage of the storm of fire, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 250, in the 6th circle 300.
Config.StormOfFireDamage = 1.0
-- Mana cost of the storm of fire, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 30.
Config.StormOfFireMana = 1.0
-- Casting time of the storm of fire, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 0.5 s.
Config.StormOfFireCastTime = 1.0
-- Damage of the rain of fire, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 50 a hit.
Config.FireRainDamage = 1.0
-- Mana cost of the rain of fire, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 20.
Config.FireRainMana = 1.0
-- Casting time of the rain of fire, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 0.1 s.
Config.FireRainCastTime = 1.0

-- ---- Magic: ice spells ----
-- Damage of the ice bolt, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 20, up to 50 with the caster's circle.
Config.IceBoltDamage = 1.0
-- Mana cost of the ice bolt, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 1 a shot.
Config.IceBoltMana = 1.0
-- Casting time of the ice bolt, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 0.1 s.
Config.IceBoltCastTime = 1.0
-- true = every hit of the ice bolt freezes at once, also foes with ice resistance.
-- false = as the game has it: a hit freezes only when its damage fills the foe's ice counter (50 points).
Config.IceBoltFreeze = false
-- Damage of the ice block, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 60, up to 100 with the caster's circle.
Config.IceBlockDamage = 1.0
-- Mana cost of the ice block, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 3.
Config.IceBlockMana = 1.0
-- Casting time of the ice block, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 0.2 s.
Config.IceBlockCastTime = 1.0
-- true = every hit of the ice block freezes at once, also foes with ice resistance.
-- false = as the game has it: a hit freezes only when its damage fills the foe's ice counter (50 points).
Config.IceBlockFreeze = false
-- Damage of the ice wave, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 120, in the 6th circle 150.
Config.IceWaveDamage = 1.0
-- Mana cost of the ice wave, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 15.
Config.IceWaveMana = 1.0
-- Casting time of the ice wave, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 0.2 s.
Config.IceWaveCastTime = 1.0
-- true = every hit of the ice wave freezes at once, also foes with ice resistance.
-- false = as the game has it: a hit freezes only when its damage fills the foe's ice counter (50 points).
Config.IceWaveFreeze = false

-- ---- Magic: energy spells ----
-- Damage of the ball lightning, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 70 / 90 / 110 / 150 by charge.
Config.BallLightningDamage = 1.0
-- Mana cost of the ball lightning, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 5 / 1 / 1 / 2 by charge.
Config.BallLightningMana = 1.0
-- Charging time of the ball lightning, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 0.3 s, then 1.03 s a charge.
Config.BallLightningCastTime = 1.0
-- The speed of the ball at every charge level. 0 = as the game has it (300 to 450, rising with the charge).
-- The multiplier for the flight speed of all spells comes on top.
Config.BallLightningSpeed = 0
-- Damage of the chain lightning, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 20, up to 45 with the caster's circle.
Config.ChainLightningDamage = 1.0
-- Mana cost of the chain lightning, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 5, then 1 a second.
Config.ChainLightningMana = 1.0
-- Casting time of the chain lightning, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 0.5 s.
Config.ChainLightningCastTime = 1.0
-- Damage of Uriziel's wave of death, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 90.
Config.UrizielDamage = 1.0
-- Mana cost of Uriziel's wave of death, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 40.
Config.UrizielMana = 1.0
-- Casting time of Uriziel's wave of death, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 0.3 s.
Config.UrizielCastTime = 1.0
-- Damage of death to the undead, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 500.
Config.DeathToTheUndeadDamage = 1.0
-- Mana cost of death to the undead, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 25.
Config.DeathToTheUndeadMana = 1.0
-- Casting time of death to the undead, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 0.5 s.
Config.DeathToTheUndeadCastTime = 1.0

-- ---- Magic: wind spells ----
-- Damage of the fist of wind, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 20, up to 70 with the caster's circle.
Config.WindFistDamage = 1.0
-- Mana cost of the fist of wind, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 2.
Config.WindFistMana = 1.0
-- How hard the fist of wind staggers, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 200; a storm fist has 250. Orcs and other heavy foes stand firm against too little.
Config.WindFistStagger = 1.0
-- Damage of the storm fist, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 120, in the 6th circle 160.
Config.StormFistDamage = 1.0
-- Mana cost of the storm fist, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 10.
Config.StormFistMana = 1.0
-- Casting time of the storm fist, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 0.5 s.
Config.StormFistCastTime = 1.0
-- Damage of the breath of death, on top of the multipliers for all spells and its kind. 1.0 = unchanged.
-- The game has 150.
Config.BreathOfDeathDamage = 1.0
-- Mana cost of the breath of death, on top of the multiplier for all spells. 1.0 = unchanged, 0 = free.
-- The game has 15.
Config.BreathOfDeathMana = 1.0
-- Casting time of the breath of death, on top of the multiplier for all spells. 1.0 = unchanged.
-- The game has 0.5 s.
Config.BreathOfDeathCastTime = 1.0

-- ---- Magic: fire bolt and ice bolt by the caster's circle ----
-- true = the four numbers below are the damage of the fire bolt. The multipliers still apply.
-- false = the game's own numbers (35 / 40 / 50 / 65).
Config.FireBoltSteps = false
-- Damage of the fire bolt of a caster below the 2nd circle (the game has 35).
Config.FireBoltStep0 = 35
-- Damage of the fire bolt of a caster of the 2nd or 3rd circle (the game has 40).
Config.FireBoltStep2 = 40
-- Damage of the fire bolt of a caster of the 4th or 5th circle (the game has 50).
Config.FireBoltStep4 = 50
-- Damage of the fire bolt of a caster of the 6th circle (the game has 65).
Config.FireBoltStep6 = 65
-- true = the four numbers below are the damage of the ice bolt. The multipliers still apply.
-- false = the game's own numbers (20 / 30 / 40 / 50).
Config.IceBoltSteps = false
-- Damage of the ice bolt of a caster below the 2nd circle (the game has 20).
Config.IceBoltStep0 = 20
-- Damage of the ice bolt of a caster of the 2nd or 3rd circle (the game has 30).
Config.IceBoltStep2 = 30
-- Damage of the ice bolt of a caster of the 4th or 5th circle (the game has 40).
Config.IceBoltStep4 = 40
-- Damage of the ice bolt of a caster of the 6th circle (the game has 50).
Config.IceBoltStep6 = 50

-- ---- Magic: learning the circles ----
-- true = the numbers below are what the magic circles cost. false = the game's own prices.
Config.CircleCosts = false
-- Learning points a teacher takes for the basics of magic (the game has 5).
Config.CircleCostBasics = 5
-- Learning points a teacher takes for the 1st circle (the game has 10).
Config.CircleCost1 = 10
-- Learning points a teacher takes for the 2nd circle (the game has 15).
Config.CircleCost2 = 15
-- Learning points a teacher takes for the 3rd circle (the game has 20).
Config.CircleCost3 = 20
-- Learning points a teacher takes for the 4th circle (the game has 25).
Config.CircleCost4 = 25
-- Learning points a teacher takes for the 5th circle (the game has 30).
Config.CircleCost5 = 30
-- Learning points a teacher takes for the 6th circle (the game has 40).
Config.CircleCost6 = 40

-- ---- Magic: on screen, log ----
-- A short note on screen when a change of these settings has been carried into the game.
-- How notes look is set on the page "General".
Config.ShowMessage = true
-- One line in UE4SS.log for every value that is changed or put back.
Config.LogChanges = false

return Config
