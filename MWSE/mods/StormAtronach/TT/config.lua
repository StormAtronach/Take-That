-- Set up the configuration
local default_config = {
    log_level               = mwse.logLevel.error,
    enabled                 = true,
    block_enabled           = true,
    parry_enabled           = true,
    dodge_enabled           = true,
    spellbatting_enabled    = true,
    name                    = "Take That",
    hotkey                  = {keyCode = tes3.scanCode.b},
    parrySlowDown           = false,
    damageMultiplierPlayer  = false,
    damageMultiplierNPC     = false,
    damageMultiplier        = 1.5,
    hitChanceModPlayer      = false,
    hitChanceModNPC         = false,
    hitChanceMultiplier     = 1.0,
    block_cool_down_time    = 1.5,
    parry_cool_down_time    = 0.1,
    dodge_cool_down_time    = 1,
    block_fatigue_cost      = 25.0, -- fatigue drained per second while holding block
    parry_min_swing          = 0,
    bat_min_skill           = 25,
    bat_range               = 250, -- Player batting search radius (game units)
    -- NPC spell batting
    npc_spellbat_enabled    = true,
    npc_spellbat_chance     = 60,  -- flat % chance per projectile cast
    block_shield_base_pc    = 50,
    block_shield_skill_mult = 0.5,
    block_weapon_base_pc    = 20,
    block_weapon_skill_mult = 0.6,
    -- NPC parry
    enemy_parry_active      = true,
    enemy_min_attackSwing   = 0.5,
    -- Force counter: auto-release the player's charged attack when an NPC starts attacking them
    force_counter_enabled   = false,
    force_counter_cooldown  = 1.0,
    -- Alternative mechanic for the weapon block
    block_skill_bonus_active        = false,
    block_weapon_blockSkill_bonus   = 0.2,
    -- Deactivating vanilla blocking
    vanilla_blocking_cap    = 0,
    -- Training
    block_skill_gain        = 5,
    parry_skill_gain        = 3,
    dodge_skill_gain        = 5,
    -- Visual
    parry_light_magnitude   = 20,
    parry_light_duration    = 0.25,
    -- Parry slow-mo
    parry_slowmo_enabled    = false,
    parry_slowmo_duration   = 0.25, -- real-time seconds the slow-mo lasts
    parry_slowmo_scalar     = 0.5,  -- simulationTimeScalar during slow-mo (0.3 = 30% speed)
    parry_slowmo_ramp_time  = 0.1,  -- real-time seconds for ease-in and ease-out transition
    allow_vanilla_block = true,
    -- Momentum: master toggle
    momentum_enabled            = true,
    -- Momentum: GMST overrides
    fatigueReturnBase           = 0.85,
    fatigueReturnMult           = 0.30,
    fatigueAttackBase           = 4.0,
    -- Momentum: fatigue scalar
    fatigueExponent             = 0.4,
    fatigueSpeedFloor           = 0.3,
    -- Momentum: weight scalar
    referenceStrength           = 75,
    strengthFloor               = 0.35,
    strengthCeiling             = 1.5,
    weightPenaltyStrength       = 0.8,
    maxWeaponWeight             = 60.0,
    -- Momentum: recovery phase
    recoveryMinDuration         = 0.4,
    recoveryMaxDuration         = 1.6,
    recoverySpeedMin            = 0.50,
    recoveryEaseExp             = 2.0,
    -- Momentum: global floor
    absoluteSpeedFloor          = 0.3,
    -- NPC visual reactions (dodge/parry animations on miss)
    npc_dodge_enabled           = true,
    npc_react_use_weapon_anims  = false,
    -- Parry weapon damage: both weapons take condition damage on a successful parry,
    -- scaled as a fraction of the physical damage the attacker would have dealt.
    parry_weapon_damage_enabled            = true,
    parry_weapon_damage_fraction_attacker  = 0.25,  -- fraction of blocked damage lost by attacker's weapon
    parry_weapon_damage_fraction_defender  = 0.10,  -- fraction of blocked damage lost by defender's weapon
    -- Collision parry
    parry_collision_mode       = false,  -- use weapon-segment collision to trigger parry (both actors must be swinging)
    parry_collision_threshold  = 30,     -- game units; weapon segments closer than this trigger collision
    parry_collision_vfx_at_point = true, -- spawn sparks at the collision point (frustum-checked); false = always use height-midpoint
    -- Debug
    parry_debug_always_active = false,  -- keep parry window open indefinitely (testing only)
    parry_debug_mode = false, -- show weapon segment lines and collision sphere each frame (collision mode only)
    -- Parry fatigue drain: attacker loses fatigue scaled to the skill-gap outcome
    parry_fatigue_drain_enabled = true,
    parry_fatigue_drain_neg = 20,  -- attacker dominated (outcome < 0)
    parry_fatigue_drain_0   = 25,  -- evenly matched
    parry_fatigue_drain_1   = 28,  -- defender +1 tier advantage
    parry_fatigue_drain_2   = 38,  -- defender +2 tier advantage
    parry_fatigue_drain_3   = 50,  -- defender +3 tier advantage (decisive)
}
local config        = mwse.loadConfig("sa_TT_config", default_config) ---@cast config table
config.confPath     = "sa_TT_config"
config.default      = default_config
local log = mwse.Logger.new({
    modName = config.modName,
    level = config.log_level,
    moduleName = "Config"
})
return config