-- ============================================================================
-- Magic balancing (module magic of G1R_MegaMod)
-- Set in the settings app or the in-game mod menu; changes count while the game runs.
-- 1.0 = the game's number. As shipped the module changes nothing.
-- ============================================================================
local Config = {}

-- ---- Magic: all spells ----
-- Off: every spell and price as the game has it.
Config.Enabled = true
-- 1.5 = half as much again, 0.5 = half.
Config.Damage = 1.0
-- To cast, and each second held. 0 = free.
Config.ManaCost = 1.0
-- Rounded, never 0 unless a multiplier is 0. Off: exact (2.5); the game's handling is unknown.
Config.WholeMana = true
-- 0.5 = twice as fast.
Config.CastTime = 1.0
-- Fire bolt, ice bolt, fire ball, ball lightning, storm of fire.
Config.ProjectileSpeed = 1.0
-- Sleep, charm, shrink, heal, pyrokinesis, chain lightning, telekinesis, control;
-- and the spread of storm fist, death to the undead, Uriziel's wave of death.
Config.Range = 1.0
-- How much a hit makes a foe stagger or fall.
Config.Stagger = 1.0
-- The game: 4 to 30 a step, by circle.
Config.HealAmount = 1.0
-- Fire bolt, fire ball, pyrokinesis, storm of fire, rain of fire.
Config.SchoolFire = 1.0
-- Ice bolt, ice block, ice wave.
Config.SchoolIce = 1.0
-- Ball lightning, chain lightning, Uriziel's wave of death, death to the undead.
Config.SchoolEnergy = 1.0
-- Fist of wind, storm fist, breath of death.
Config.SchoolWind = 1.0

-- ---- Magic: fire spells ----
-- The game: 35, up to 65 with the caster's circle.
Config.FireBoltDamage = 1.0
-- The game: 1 a shot. 0 = free.
Config.FireBoltMana = 1.0
-- The game: 0.1 s.
Config.FireBoltCastTime = 1.0
-- The game: 90 / 110 / 130 by charge.
Config.FireBallDamage = 1.0
-- The game: 1 / 2 / 2 by charge. 0 = free.
Config.FireBallMana = 1.0
-- The game: 0.4 / 0.6 / 0.8 s by charge.
Config.FireBallCastTime = 1.0
-- The game: 20, from the 5th circle 35.
Config.PyrokinesisDamage = 1.0
-- The game: 5, then 1 a second. 0 = free.
Config.PyrokinesisMana = 1.0
-- The game: 0.5 s.
Config.PyrokinesisCastTime = 1.0
-- The game: 250, in the 6th circle 300.
Config.StormOfFireDamage = 1.0
-- The game: 30. 0 = free.
Config.StormOfFireMana = 1.0
-- The game: 0.5 s.
Config.StormOfFireCastTime = 1.0
-- The game: 50 a hit.
Config.FireRainDamage = 1.0
-- The game: 20. 0 = free.
Config.FireRainMana = 1.0
-- The game: 0.1 s.
Config.FireRainCastTime = 1.0

-- ---- Magic: ice spells ----
-- The game: 20, up to 50 with the caster's circle.
Config.IceBoltDamage = 1.0
-- The game: 1 a shot. 0 = free.
Config.IceBoltMana = 1.0
-- The game: 0.1 s.
Config.IceBoltCastTime = 1.0
-- Also foes resistant to ice. Off: only when the ice counter fills (50).
Config.IceBoltFreeze = false
-- The game: 60, up to 100 with the caster's circle.
Config.IceBlockDamage = 1.0
-- The game: 3. 0 = free.
Config.IceBlockMana = 1.0
-- The game: 0.2 s.
Config.IceBlockCastTime = 1.0
-- Also foes resistant to ice. Off: only when the ice counter fills (50).
Config.IceBlockFreeze = false
-- The game: 120, in the 6th circle 150.
Config.IceWaveDamage = 1.0
-- The game: 15. 0 = free.
Config.IceWaveMana = 1.0
-- The game: 0.2 s.
Config.IceWaveCastTime = 1.0
-- Also foes resistant to ice. Off: only when the ice counter fills (50).
Config.IceWaveFreeze = false

-- ---- Magic: energy spells ----
-- The game: 70 / 90 / 110 / 150 by charge.
Config.BallLightningDamage = 1.0
-- The game: 5 / 1 / 1 / 2 by charge. 0 = free.
Config.BallLightningMana = 1.0
-- The game: 0.3 s, then 1.03 s a charge.
Config.BallLightningCastTime = 1.0
-- 0 = the game's (300 to 450 by charge). The speed multiplier comes on top.
Config.BallLightningSpeed = 0
-- The game: 20, up to 45 with the caster's circle.
Config.ChainLightningDamage = 1.0
-- The game: 5, then 1 a second. 0 = free.
Config.ChainLightningMana = 1.0
-- The game: 0.5 s.
Config.ChainLightningCastTime = 1.0
-- The game: 90.
Config.UrizielDamage = 1.0
-- The game: 40. 0 = free.
Config.UrizielMana = 1.0
-- The game: 0.3 s.
Config.UrizielCastTime = 1.0
-- The game: 500.
Config.DeathToTheUndeadDamage = 1.0
-- The game: 25. 0 = free.
Config.DeathToTheUndeadMana = 1.0
-- The game: 0.5 s.
Config.DeathToTheUndeadCastTime = 1.0

-- ---- Magic: wind spells ----
-- The game: 20, up to 70 with the caster's circle.
Config.WindFistDamage = 1.0
-- The game: 2. 0 = free.
Config.WindFistMana = 1.0
-- The game: 200 (storm fist 250). Heavy foes like orcs resist too little.
Config.WindFistStagger = 1.0
-- The game: 120, in the 6th circle 160.
Config.StormFistDamage = 1.0
-- The game: 10. 0 = free.
Config.StormFistMana = 1.0
-- The game: 0.5 s.
Config.StormFistCastTime = 1.0
-- The game: 150.
Config.BreathOfDeathDamage = 1.0
-- The game: 15. 0 = free.
Config.BreathOfDeathMana = 1.0
-- The game: 0.5 s.
Config.BreathOfDeathCastTime = 1.0

-- ---- Magic: fire bolt and ice bolt by the caster's circle ----
-- The game: 35 / 40 / 50 / 65.
Config.FireBoltSteps = false
-- The game: 35.
Config.FireBoltStep0 = 35
-- The game: 40.
Config.FireBoltStep2 = 40
-- The game: 50.
Config.FireBoltStep4 = 50
-- The game: 65.
Config.FireBoltStep6 = 65
-- The game: 20 / 30 / 40 / 50.
Config.IceBoltSteps = false
-- The game: 20.
Config.IceBoltStep0 = 20
-- The game: 30.
Config.IceBoltStep2 = 30
-- The game: 40.
Config.IceBoltStep4 = 40
-- The game: 50.
Config.IceBoltStep6 = 50

-- ---- Magic: learning the circles ----
-- Off: the game's prices.
Config.CircleCosts = false
-- The game: 5.
Config.CircleCostBasics = 5
-- The game: 10.
Config.CircleCost1 = 10
-- The game: 15.
Config.CircleCost2 = 15
-- The game: 20.
Config.CircleCost3 = 20
-- The game: 25.
Config.CircleCost4 = 25
-- The game: 30.
Config.CircleCost5 = 30
-- The game: 40.
Config.CircleCost6 = 40

-- ---- Magic: on screen, log ----
Config.ShowMessage = true
Config.LogChanges = false

return Config
