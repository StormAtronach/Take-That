local config = require("StormAtronach.TT.config")
local gmst   = require("StormAtronach.TT.lib.gmst")

local function modActivation()
    event.trigger("stormatronach:modActivation")
end

--- @param self mwseMCMInfo|mwseMCMHyperlink
local function center(self)
	self.elements.info.absolutePosAlignX = 0.5
end

local authors = {
	{
		name = "Storm Atronach",
		url = "https://next.nexusmods.com/profile/StormAtronach0",
	},
}

--- Adds default text to sidebar. Has a list of all the authors that contributed to the mod.
--- @param container mwseMCMSideBarPage
local function createSidebar(container)
	container.sidebar:createInfo({
		text =      "Take That!\n\n" ..
                    "A modern combat mod with blocking, parrying, dodging, and spell batting. \n" ..
                    "Tweak the settings below to customize your experience. \n" ..
                    "Please visit the Nexus page for more information and support.\n\nMade by:",
		postCreate = center,
	})
	for _, author in ipairs(authors) do
		container.sidebar:createHyperlink({
			text = author.name,
			url = author.url,
			postCreate = center,
		})
	end
end

local function registerModConfig()
	local template = mwse.mcm.createTemplate({
		name = "Take That!",
		config = config,
		defaultConfig = config.default,
		showDefaultSetting = true,
	})
	template:register()
	template:saveOnClose(config.confPath, config)

	-- -------------------------------------------------------------------------
	-- Main Settings
	-- -------------------------------------------------------------------------
	local page = template:createSideBarPage({
		label = "Main Settings",
		showReset = true,
	}) --[[@as mwseMCMSideBarPage]]
	createSidebar(page)

	page:createOnOffButton{
		label = "Enable Mod",
		description = "Toggle the mod on or off.",
		configKey = "enabled",
		callback = modActivation,
	}
	page:createOnOffButton{
		label = "Enable Block",
		description = "Toggle the blocking mechanic on or off.",
		configKey = "block_enabled",
		callback = modActivation,
	}
	page:createOnOffButton{
		label = "Enable Parry",
		description = "Toggle the parry mechanic on or off.",
		configKey = "parry_enabled",
		callback = modActivation,
	}
	page:createOnOffButton{
		label = "Enable Dodge",
		description = "Toggle the dodge mechanic on or off.",
		configKey = "dodge_enabled",
		callback = modActivation,
	}
	page:createOnOffButton{
		label = "Enable Spell Batting",
		description = "Toggle the spell batting mechanic on or off.",
		configKey = "spellbatting_enabled",
		callback = modActivation,
	}

	page:createKeyBinder{
		label = "Block Hotkey",
		description = "Choose a hotkey for starting the block. Mouse buttons are allowed, as well as combinations (shift+stuff, ctrl+stuff, etc.)",
		allowCombinations = true,
		allowModifierKeys = true,
		allowMouse        = true,
		configKey         = "hotkey",
	}

	local npcReactions = page:createCategory{ label = "NPC Visual Reactions" }
	npcReactions:createOnOffButton{
		label = "Enable NPC Visual Reactions",
		description = "When the player misses an NPC, the NPC plays a dodge or parry animation as eye candy. Does not affect hit/miss probability.",
		configKey = "npc_dodge_enabled",
	}
	npcReactions:createOnOffButton{
		label = "Also use block/parry animations",
		description = "When enabled, misses have a 50% chance of triggering a block or parry animation (with spark VFX and sound) instead of a sidestep. Disabled by default — dodge-only is subtler.",
		configKey = "npc_react_use_weapon_anims",
	}

	local training = page:createCategory{ label = "Training" }
	training:createSlider{
		label = "XP gain from blocking",
		description = "XP gain from blocking. Vanilla per succesful block is 2.5",
		min = 0, max = 10, step = 0.5, jump = 0.5, decimalPlaces = 1,
		configKey = "block_skill_gain",
	}
	training:createSlider{
		label = "XP gain from parrying",
		description = "XP gain from parrying. Vanilla per succesful attack is 1-2 depending on the weapon",
		min = 0, max = 10, step = 0.5, jump = 0.5, decimalPlaces = 1,
		configKey = "parry_skill_gain",
	}
	training:createSlider{
		label = "XP gain from dodging",
		description = "XP gain from dodging. I am using 5, but there is no equivalent in vanilla.",
		min = 0, max = 10, step = 0.5, jump = 0.5, decimalPlaces = 1,
		configKey = "dodge_skill_gain",
	}

	page:createLogLevelOptions({
		configKey = "log_level",
		defaultSetting = mwse.logLevel.error,
	})

	-- -------------------------------------------------------------------------
	-- Block
	-- -------------------------------------------------------------------------
	local blockSettings = template:createSideBarPage({
		label = "Block",
		showReset = true,
	}) --[[@as mwseMCMSideBarPage]]
	createSidebar(blockSettings)

	blockSettings:createSlider{
		label = "Block Cooldown (seconds)",
		description = "This is the cooldown for blocking. It is not the same as the block window.",
		min = 1, max = 10, step = 0.1, jump = 0.1, decimalPlaces = 1,
		configKey = "block_cool_down_time",
	}
	blockSettings:createSlider{
		label = "Block Fatigue Cost (per second)",
		description = "Fatigue drained per second while holding the block key. Set to 0 to disable fatigue cost.",
		min = 0, max = 250, step = 0.5, jump = 1, decimalPlaces = 1,
		configKey = "block_fatigue_cost",
	}

	local blockDamage = blockSettings:createCategory{ label = "Damage Reduction" }
	blockDamage:createSlider{
		label = "Shield Block Base %",
		description = "This is the base damage reduction when blocking with a shield.",
		min = 0, max = 100, step = 1, jump = 5,
		configKey = "block_shield_base_pc",
	}
	blockDamage:createSlider{
		label = "Shield Block Skill Multiplier",
		description = "0.5 means 50% of the block skill is added to the damage reduction formula.",
		min = 0, max = 2, step = 0.1, jump = 0.1, decimalPlaces = 1,
		configKey = "block_shield_skill_mult",
	}
	blockDamage:createSlider{
		label = "Weapon Block Base %",
		description = "This is the base damage reduction when blocking with a weapon.",
		min = 0, max = 100, step = 1, jump = 5,
		configKey = "block_weapon_base_pc",
	}
	blockDamage:createSlider{
		label = "Weapon Block Skill Multiplier",
		description = "0.6 means 60% of the weapon skill is added to the damage reduction formula.",
		min = 0, max = 2, step = 0.1, jump = 0.1, decimalPlaces = 1,
		configKey = "block_weapon_skill_mult",
	}
	blockDamage:createOnOffButton{
		label = "Block Skill also contributes to weapon block",
		description = "If this is enabled, the block skill will also contribute to the damage reduction when using weapon block. Also, blocking will grant experience to the block skill instead of the weapon skill.",
		configKey = "block_skill_bonus_active",
	}
	blockDamage:createSlider{
		label = "Block Skill Bonus (weapon block)",
		description = "0.2 means 20% of the block skill is added to the damage reduction formula when weapon blocking.",
		min = 0, max = 2, step = 0.1, jump = 0.1, decimalPlaces = 1,
		configKey = "block_weapon_blockSkill_bonus",
	}

	local blockVanilla = blockSettings:createCategory{ label = "Vanilla Blocking" }
	blockVanilla:createSlider{
		label = "Vanilla Blocking Cap %",
		description = "Set to 0 to disable vanilla blocking entirely. Set to 50 to allow full vanilla block chance.",
		min = 0, max = 50, step = 1, jump = 1,
		configKey = "vanilla_blocking_cap",
	}
	blockVanilla:createOnOffButton{
		label = "Allow vanilla blocking while attacking",
		description = "If this is enabled, the vanilla automatic blocking mechanic will work while you are holding an attack at full power, ignoring the Vanilla Blocking cap%.",
		configKey = "allow_vanilla_block",
	}

	-- -------------------------------------------------------------------------
	-- Parry
	-- -------------------------------------------------------------------------
	local parrySettings = template:createSideBarPage({
		label = "Parry",
		showReset = true,
	}) --[[@as mwseMCMSideBarPage]]
	createSidebar(parrySettings)

	local parryCollision = parrySettings:createCategory{ label = "Collision Parry" }
	parryCollision:createOnOffButton{
		label = "Enable Collision-Based Parry",
		description = "When enabled, a parry triggers only when both actors are mid-swing and their weapon segments come within the collision threshold. Replaces the time-window and event-window modes.",
		configKey = "parry_collision_mode",
	}
	parryCollision:createOnOffButton{
		label = "Sparks at Collision Point",
		description = "When enabled, the parry spark VFX appears at the actual weapon collision point (frustum-checked; falls back to height-midpoint if off-screen). When disabled, sparks always appear at the height-midpoint between the two actors.",
		configKey = "parry_collision_vfx_at_point",
	}
	parryCollision:createSlider{
		label = "Collision Threshold (game units)",
		description = "How close two weapon segments must be to register a collision parry. Smaller values require more precise positioning.",
		min = 1, max = 50, step = 1, jump = 5,
		configKey = "parry_collision_threshold",
	}

	local parryMinSwing = parrySettings:createCategory{ label = "Minimum Swing" }
	parryMinSwing:createSlider{
		label = "Player Minimum Swing",
		description = "The minimum charge the player must have on their swing to be eligible to parry. 0 allows parrying from any swing state.",
		min = 0.0, max = 1.0, step = 0.1, jump = 0.1, decimalPlaces = 1,
		configKey = "parry_min_swing",
	}
	parryMinSwing:createSlider{
		label = "NPC Minimum Swing",
		description = "The minimum swing that the NPC will need to achieve to parry your attack. NPC swing is randomized by the game engine.",
		min = 0.0, max = 1.0, step = 0.1, jump = 0.1, decimalPlaces = 1,
		configKey = "enemy_min_attackSwing",
	}

	local parryNPC = parrySettings:createCategory{ label = "NPC Parry" }
	parryNPC:createOnOffButton{
		label = "NPC Parry Active",
		description = "If this is enabled, NPCs will be able to parry your attacks.",
		configKey = "enemy_parry_active",
	}

	local forceCounter = parrySettings:createCategory{ label = "Force Counter Attack" }
	forceCounter:createOnOffButton{
		label = "Enable Force Counter Attack",
		description = "When an NPC starts attacking you while you have a weapon drawn and are mid-swing, your charged attack is automatically released.",
		configKey = "force_counter_enabled",
	}
	forceCounter:createSlider{
		label = "Force Counter Cooldown (seconds)",
		description = "Minimum time between force counter activations.",
		min = 0.1, max = 3.0, step = 0.1, jump = 0.5, decimalPlaces = 1,
		configKey = "force_counter_cooldown",
	}

	local parryVisual = parrySettings:createCategory{ label = "Visual Feedback" }
	parryVisual:createSlider{
		label = "Parry Light Magnitude",
		description = "The magnitude of the light effect when parrying. Set to 0 to disable.",
		min = 0, max = 100, step = 1, jump = 5, decimalPlaces = 1,
		configKey = "parry_light_magnitude",
	}
	parryVisual:createSlider{
		label = "Parry Light Duration",
		description = "How long the parry light flash lasts in seconds.",
		min = 0, max = 0.5, step = 0.1, jump = 0.1, decimalPlaces = 1,
		configKey = "parry_light_duration",
	}
	parryVisual:createOnOffButton{
		label = "Enable Parry Slowdown",
		description = "Toggle actor slowdown on parry. Deactivate if using Chronomancy from Halls of the Colossus.",
		configKey = "parrySlowDown",
	}
	parryVisual:createOnOffButton{
		label = "Enable Parry Slow-Mo",
		description = "When the player successfully parries an attack, time briefly slows down for a hit-stop effect. Uses real time, so it is not affected by the simulation time scale.",
		configKey = "parry_slowmo_enabled",
	}
	parryVisual:createSlider{
		label = "Parry Slow-Mo Duration (seconds)",
		description = "How long the slow-mo effect lasts in real-time seconds.",
		min = 0.05, max = 1.0, step = 0.05, jump = 0.1, decimalPlaces = 2,
		configKey = "parry_slowmo_duration",
	}
	parryVisual:createSlider{
		label = "Parry Slow-Mo Speed",
		description = "Simulation speed during the slow-mo effect. 0.3 = 30% of normal speed.",
		min = 0.05, max = 0.9, step = 0.05, jump = 0.1, decimalPlaces = 2,
		configKey = "parry_slowmo_scalar",
	}
	parryVisual:createSlider{
		label = "Parry Slow-Mo Transition (seconds)",
		description = "Real-time seconds to ease in and out of the slow-mo effect. 0 = instant snap.",
		min = 0.0, max = 0.5, step = 0.01, jump = 0.05, decimalPlaces = 2,
		configKey = "parry_slowmo_ramp_time",
	}

	local parryWeaponDmg = parrySettings:createCategory{ label = "Weapon Damage on Parry" }
	parryWeaponDmg:createOnOffButton{
		label = "Enable Weapon Damage",
		description = "When enabled, both weapons take condition damage on a successful parry, proportional to the physical damage that was blocked.",
		configKey = "parry_weapon_damage_enabled",
	}
	parryWeaponDmg:createSlider{
		label = "Attacker Weapon Damage Fraction",
		description = "Fraction of the blocked physical damage applied as condition loss to the attacker's weapon. 0.25 = 25% of blocked damage.",
		min = 0.0, max = 1.0, step = 0.05, jump = 0.1, decimalPlaces = 2,
		configKey = "parry_weapon_damage_fraction_attacker",
	}
	parryWeaponDmg:createSlider{
		label = "Defender Weapon Damage Fraction",
		description = "Fraction of the blocked physical damage applied as condition loss to the defender's weapon. 0.10 = 10% of blocked damage.",
		min = 0.0, max = 1.0, step = 0.05, jump = 0.1, decimalPlaces = 2,
		configKey = "parry_weapon_damage_fraction_defender",
	}

	local parryFatigue = parrySettings:createCategory{ label = "Fatigue Drain on Attacker" }
	parryFatigue:createOnOffButton{
		label = "Enable Parry Fatigue Drain",
		description = "When enabled, a successful parry drains the attacker's fatigue. The amount scales with the skill-gap outcome.",
		configKey = "parry_fatigue_drain_enabled",
	}
	parryFatigue:createSlider{
		label = "Drain: attacker dominated (outcome < 0)",
		description = "Fatigue drained from the attacker when they outclass the defender. The parry was clumsy but the clash still costs effort.",
		min = 0, max = 100, step = 1, jump = 5,
		configKey = "parry_fatigue_drain_neg",
	}
	parryFatigue:createSlider{
		label = "Drain: evenly matched (outcome = 0)",
		description = "Fatigue drained from the attacker when both sides are equally skilled.",
		min = 0, max = 100, step = 1, jump = 5,
		configKey = "parry_fatigue_drain_0",
	}
	parryFatigue:createSlider{
		label = "Drain: defender +1 tier advantage",
		description = "Fatigue drained from the attacker when the defender has a slight skill edge.",
		min = 0, max = 100, step = 1, jump = 5,
		configKey = "parry_fatigue_drain_1",
	}
	parryFatigue:createSlider{
		label = "Drain: defender +2 tier advantage",
		description = "Fatigue drained from the attacker when the defender has a clear skill edge.",
		min = 0, max = 100, step = 1, jump = 5,
		configKey = "parry_fatigue_drain_2",
	}
	parryFatigue:createSlider{
		label = "Drain: defender +3 tier advantage (decisive)",
		description = "Fatigue drained from the attacker when the defender decisively outclasses them.",
		min = 0, max = 100, step = 1, jump = 5,
		configKey = "parry_fatigue_drain_3",
	}

	local parryDebug = parrySettings:createCategory{ label = "Debug" }
	parryDebug:createOnOffButton{
		label = "Parry Always Active",
		description = "DEBUG: Once triggered by a swing, the player's parry window never closes. Useful for testing parry outcomes without precise timing.",
		configKey = "parry_debug_always_active",
	}
	parryDebug:createOnOffButton{
		label = "Parry Debug Mode",
		description = "DEBUG: Each frame, draws red/green lines along both weapon segments and spawns a sphere at the collision midpoint when a collision parry fires. Collision mode only.",
		configKey = "parry_debug_mode",
	}

	-- -------------------------------------------------------------------------
	-- Dodge
	-- -------------------------------------------------------------------------
	local dodgeSettings = template:createSideBarPage({
		label = "Dodge",
		showReset = true,
	}) --[[@as mwseMCMSideBarPage]]
	createSidebar(dodgeSettings)

	dodgeSettings:createSlider{
		label = "Dodge Cooldown (seconds)",
		description = "This is the cooldown for dodging. It is not the same as the dodge window.",
		min = 1, max = 10, step = 0.1, jump = 0.1, decimalPlaces = 1,
		configKey = "dodge_cool_down_time",
	}

	-- -------------------------------------------------------------------------
	-- Spell Batting
	-- -------------------------------------------------------------------------
	local spellBattingSettings = template:createSideBarPage({
		label = "Spell Batting",
		showReset = true,
	}) --[[@as mwseMCMSideBarPage]]
	createSidebar(spellBattingSettings)

	spellBattingSettings:createSlider{
		label = "Spell Batting Minimum Skill",
		description = "This is the minimum skill required to use spell batting. It just feels unrealistic to be able to bat spells with 0 skill, but it is your choice.",
		min = 0, max = 100, step = 1, jump = 5,
		configKey = "bat_min_skill",
	}
	spellBattingSettings:createSlider{
		label = "Spell Batting Range (units)",
		description = "How close an incoming spell must be to the player when the bat activates. Lower values require more precise timing.",
		min = 50, max = 500, step = 10, jump = 50,
		configKey = "bat_range",
	}

	local npcBatting = spellBattingSettings:createCategory{ label = "NPC Spell Batting" }
	npcBatting:createOnOffButton{
		label = "Enable NPC Spell Batting",
		description = "When enabled, NPCs have a chance to reflect projectile spells cast at them while they are mid-swing. Uses a raycast at cast time to detect the aimed target, then the projectile's actual velocity to time the reflect window.",
		configKey = "npc_spellbat_enabled",
	}
	npcBatting:createSlider{
		label = "NPC Spell Batting Chance (%)",
		description = "Flat percentage chance for an NPC to successfully bat an incoming spell. Rolled once per projectile cast.",
		min = 0, max = 100, step = 5, jump = 10,
		configKey = "npc_spellbat_chance",
	}

	-- -------------------------------------------------------------------------
	-- Re-balancing
	-- -------------------------------------------------------------------------
	local balancing = template:createSideBarPage({
		label = "Re-balancing",
		showReset = true,
	}) --[[@as mwseMCMSideBarPage]]
	createSidebar(balancing)

	local balDamage = balancing:createCategory{ label = "Damage Multiplier" }
	balDamage:createOnOffButton{
		label = "Enable for player attacks",
		description = "Enable a damage multiplier for player attacks. This is to speed up combat since parries can reduce the effective DPS on both sides, making each hit count more.",
		configKey = "damageMultiplierPlayer",
	}
	balDamage:createOnOffButton{
		label = "Enable for NPC/creature attacks",
		description = "Enable a damage multiplier for NPC and creature attacks. This is to speed up combat since parries can reduce the effective DPS on both sides, making each hit count more.",
		configKey = "damageMultiplierNPC",
	}
	balDamage:createSlider{
		label = "Damage Multiplier",
		description = "Multiplier applied to physical attacks (not ranged). Intended to give more weight to attacks that land, compensating for the DPS reduction from parries.",
		min = 1, max = 5, step = 0.1, jump = 0.1, decimalPlaces = 1,
		configKey = "damageMultiplier",
	}

	local balHitChance = balancing:createCategory{ label = "Hit Chance Multiplier" }
	balHitChance:createOnOffButton{
		label = "Enable for player attacks",
		description = "Enable a hit chance multiplier for player attacks.",
		configKey = "hitChanceModPlayer",
	}
	balHitChance:createOnOffButton{
		label = "Enable for NPC/creature attacks",
		description = "Enable a hit chance multiplier for NPC and creature attacks.",
		configKey = "hitChanceModNPC",
	}
	balHitChance:createSlider{
		label = "Hit Chance Multiplier",
		description = "Multiplier applied to physical attack hit chance (not ranged). Intended to give more weight to attacks that land.",
		min = 1, max = 5, step = 0.1, jump = 0.1, decimalPlaces = 1,
		configKey = "hitChanceMultiplier",
	}

	-- -------------------------------------------------------------------------
	-- Fatigue GMSTs
	-- -------------------------------------------------------------------------
	local gmstPage = template:createSideBarPage({
		label = "Fatigue GMSTs",
		showReset = true,
	}) --[[@as mwseMCMSideBarPage]]
	createSidebar(gmstPage)

	-- Forward declarations so button callbacks can call setVariableValue() after the sliders exist.
	local sliderReturnBase, sliderReturnMult, sliderAttackBase ---@type mwseMCMSlider, mwseMCMSlider, mwseMCMSlider

	local function refreshGmstSliders()
		if sliderReturnBase then sliderReturnBase:setVariableValue(config.fatigueReturnBase) end
		if sliderReturnMult then sliderReturnMult:setVariableValue(config.fatigueReturnMult) end
		if sliderAttackBase then sliderAttackBase:setVariableValue(config.fatigueAttackBase) end
	end

	gmstPage:createOnOffButton{
		label = "Enable GMST Overrides",
		description = "When enabled, Take That! overwrites the following GMST fFatigueReturnBase, fFatigueReturnMult, and fFatigueAttackBase with the values configured below. Opt-in: disabled by default to avoid conflicts.",
		configKey = "gmst_enabled",
		callback = function()
			if config.gmst_enabled then
				gmst.apply()
			else
				gmst.restoreVanilla()
			end
		end,
	}
	gmstPage:createButton{
		buttonText = "Restore vanilla GMSTs",
		description = "Writes the values of fFatigueReturnBase, fFatigueReturnMult, and fFatigueAttackBase that were active when the game was loaded (before any Take That! changes) back to the engine.",
		callback = function()
			gmst.restoreVanilla()
			refreshGmstSliders()
		end,
	}
	gmstPage:createButton{
		buttonText = "Restore mod default GMSTs",
		description = "Writes Take That!'s recommended default values for fFatigueReturnBase, fFatigueReturnMult, and fFatigueAttackBase back to the engine.",
		callback = function()
			gmst.restoreDefaults()
			refreshGmstSliders()
		end,
	}
	sliderReturnBase = gmstPage:createSlider{
		label = "Fatigue Return Base",
		description = "GMST: Base rate at which fatigue recovers. Higher values restore fatigue faster. Vanilla default is 2.50.",
		min = 0.0, max = 5.0, step = 0.05, jump = 0.5, decimalPlaces = 2,
		configKey = "fatigueReturnBase",
	}
	sliderReturnMult = gmstPage:createSlider{
		label = "Fatigue Return Multiplier",
		description = "GMST: Multiplier applied on top of the base fatigue recovery rate. Vanilla default is 0.02.",
		min = 0.0, max = 1.0, step = 0.01, jump = 0.1, decimalPlaces = 2,
		configKey = "fatigueReturnMult",
	}
	sliderAttackBase = gmstPage:createSlider{
		label = "Fatigue Attack Base",
		description = "GMST: Base fatigue cost per attack. Vanilla default is 2.0.",
		min = 0.0, max = 20.0, step = 0.1, jump = 1.0, decimalPlaces = 1,
		configKey = "fatigueAttackBase",
	}

	-- -------------------------------------------------------------------------
	-- Momentum
	-- -------------------------------------------------------------------------
	local momentumSettings = template:createSideBarPage({
		label = "Momentum",
		showReset = true,
	}) --[[@as mwseMCMSideBarPage]]
	createSidebar(momentumSettings)

	momentumSettings:createOnOffButton{
		label = "Enable Momentum",
		description = "Scales animation speed based on fatigue, weapon weight, and post-attack recovery. Requires reloading the game cell to take full effect.",
		configKey = "momentum_enabled",
	}

	local momFatigue = momentumSettings:createCategory{ label = "Fatigue" }
	momFatigue:createSlider{
		label = "Fatigue Speed Floor",
		description = "Minimum animation speed when fatigue is completely depleted.",
		min = 0.1, max = 1.0, step = 0.05, jump = 0.1, decimalPlaces = 2,
		configKey = "fatigueSpeedFloor",
	}

	local momWeight = momentumSettings:createCategory{ label = "Weapon Weight" }
	momWeight:createSlider{
		label = "Reference Strength",
		description = "Strength value at which weapon weight feels baseline. Actors with higher strength are penalised less by heavy weapons.",
		min = 1, max = 100, step = 1, jump = 5,
		configKey = "referenceStrength",
	}
	momWeight:createSlider{
		label = "Weight Penalty",
		description = "How much weapon weight can slow the actor at baseline strength. 0 = weight has no effect.",
		min = 0.0, max = 1.0, step = 0.05, jump = 0.1, decimalPlaces = 2,
		configKey = "weightPenaltyStrength",
	}

	local momRecovery = momentumSettings:createCategory{ label = "Recovery" }
	momRecovery:createSlider{
		label = "Recovery Min Duration (seconds)",
		description = "Slowdown duration after a light tap attack (zero charge, low weight).",
		min = 0.1, max = 1.0, step = 0.05, jump = 0.1, decimalPlaces = 2,
		configKey = "recoveryMinDuration",
	}
	momRecovery:createSlider{
		label = "Recovery Max Duration (seconds)",
		description = "Slowdown duration after a full-charge heavy-weapon attack.",
		min = 0.5, max = 3.0, step = 0.1, jump = 0.1, decimalPlaces = 1,
		configKey = "recoveryMaxDuration",
	}
	momRecovery:createSlider{
		label = "Recovery Speed Min",
		description = "Animation speed at the bottom of the recovery phase.",
		min = 0.1, max = 1.0, step = 0.05, jump = 0.1, decimalPlaces = 2,
		configKey = "recoverySpeedMin",
	}

	local momGlobal = momentumSettings:createCategory{ label = "Global" }
	momGlobal:createSlider{
		label = "Absolute Speed Floor",
		description = "Hard minimum for the composite speed multiplier. No actor can animate slower than this regardless of other factors.",
		min = 0.1, max = 0.8, step = 0.05, jump = 0.1, decimalPlaces = 2,
		configKey = "absoluteSpeedFloor",
	}
end
event.register("modConfigReady", registerModConfig)
