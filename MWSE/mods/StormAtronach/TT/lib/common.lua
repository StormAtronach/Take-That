-- common.lua - Shared utilities and cross-module state tables
local common = {}

-- slowedActors: tracks actors currently under a TT slow effect.
--   Key  : refId string (ref.refId)
--   Value: { ref, startTime, duration, typeSlow, originalSpeed }
--   typeSlow: 1 = 25 % reduction, 2 = 50 %, 3 = 75 %, 4 = full stop
--   Iterated each simulate frame in main.lua; expired entries are removed there.
common.slowedActors = {}

-- parryingActors: set of NPCs currently in their parry reaction window.
--   Key  : tes3reference  Value: true
--   Entries are set in main.lua's onAttack and expired by a timer.simulate callback.
common.parryingActors = {}
local log = mwse.Logger.new({ moduleName = "common" })

--  Weapon Types
--  These values are available in Lua by their index in the tes3.weaponType table. For example, tes3.weaponType.bluntOneHand has a value of 3.
-- Index	            Value	Description
-- shortBladeOneHand	0	    Short Blade, One Handed
-- longBladeOneHand	    1	    Long Blade, One Handed
-- longBladeTwoClose	2	    Lon Blade, Two Handed
-- bluntOneHand	        3	    Blunt Weapon, One Handed
-- bluntTwoClose	    4   	Blunt Weapon, Two Handed (Warhammers)
-- bluntTwoWide	        5   	Blunt Weapon, Two Handed (Staffs)
-- spearTwoWide	        6   	Spear, Two Handed
-- axeOneHand	        7   	Axe, One Handed
-- axeTwoHand	        8	    Axe, Two Handed
-- marksmanBow	        9	    Marksman, Bows
-- marksmanCrossbow	    10	    Marksman, Crossbow
-- marksmanThrown	    11	    Marksman, Thrown
-- arrow	            12  	Arrows
-- bolt	            13	    Bolts

common.oneHandedWeaponTable = {
	[tes3.weaponType.shortBladeOneHand] = true,
	[tes3.weaponType.longBladeOneHand] = true,
	[tes3.weaponType.longBladeTwoClose] = false,
	[tes3.weaponType.bluntOneHand] = true,
	[tes3.weaponType.bluntTwoClose] = false,
	[tes3.weaponType.bluntTwoWide] = false,
	[tes3.weaponType.spearTwoWide] = false,
	[tes3.weaponType.axeOneHand] = true,
	[tes3.weaponType.axeTwoHand] = false,
	[tes3.weaponType.marksmanBow] = false,
	[tes3.weaponType.marksmanCrossbow] = false,
	[tes3.weaponType.marksmanThrown] = false,
	[tes3.weaponType.arrow] = false,
	[tes3.weaponType.bolt] = false,
	["kungFu"] = false,
}

--- Ranged weapon type lookup. True for any weapon that fires a projectile.
--- Used by parry and any other mechanic that needs to distinguish melee from ranged.
common.rangedWeaponTypes = {
	[tes3.weaponType.marksmanBow]      = true,
	[tes3.weaponType.marksmanCrossbow] = true,
	[tes3.weaponType.marksmanThrown]   = true,
}

--- Extract the bare filename (no extension, lowercased) from a mesh path.
--- Returns nil if path is nil or no filename component is found.
--- Examples: "r\\meshes\\goblin.nif" → "goblin", "goblin.nif" → "goblin"
function common.meshName(path)
	if not path then
		return nil
	end
	local name = path:match("[/\\]([^/\\]+)%.nif$") or path:match("^([^/\\]+)%.nif$")
	return name and name:lower()
end

--- Midpoint between two actors at 90 % of their respective heights.
--- Used for VFX spawn positions.
--- @param refA tes3reference
--- @param mobileA tes3mobileActor
--- @param refB tes3reference
--- @param mobileB tes3mobileActor
--- @return tes3vector3
function common.actorMidpoint(refA, mobileA, refB, mobileB)
	return (refA.position + tes3vector3.new(0, 0, mobileA.height * 0.9) +
	        refB.position + tes3vector3.new(0, 0, mobileB.height * 0.9)) * 0.5
end

--- Add or refresh a slow entry for an actor.
--- Preserves the actor's current speedMultiplier as originalSpeed so the slow factor
--- is applied multiplicatively rather than as an absolute value.
--- If the actor is already slowed, the previous originalSpeed is carried forward.
function common.slowActor(ref, duration, typeSlow)
	local animCtrl = ref.mobile and ref.mobile.animationController
	local prevEntry = common.slowedActors[ref.refId]
	local originalSpeed = (prevEntry and prevEntry.originalSpeed) or (animCtrl and animCtrl.speedMultiplier) or 1.0
	common.slowedActors[ref.refId] = {
		ref = ref,
		startTime = os.clock(),
		duration = duration,
		typeSlow = typeSlow,
		originalSpeed = originalSpeed,
	}
end

-- Roll a D20! Well, no, but the same thing. We check the skill level of the equipped weapon or hand to hand
function common.weaponSkillCheck(data)
	-- data.thisMobileActor     : Well, a mobileActor
	-- data.weapon              : And its weapon. Hopefully, a tes3weapon.type. Should be nil if nothing is equipped.
	-- data.valueToCheckAgainst : Pretty self explanatory. Optional
	-- Look, an initialization! How rare to find one in the wild:
	local skillLevel = 0
	local skillDC = data.valueToCheckAgainst or 0
	local skillList = {
		[tes3.weaponType.shortBladeOneHand] = tes3.skill.shortBlade,
		[tes3.weaponType.longBladeOneHand] = tes3.skill.longBlade,
		[tes3.weaponType.longBladeTwoClose] = tes3.skill.longBlade,
		[tes3.weaponType.bluntOneHand] = tes3.skill.bluntWeapon,
		[tes3.weaponType.bluntTwoClose] = tes3.skill.bluntWeapon,
		[tes3.weaponType.bluntTwoWide] = tes3.skill.bluntWeapon,
		[tes3.weaponType.spearTwoWide] = tes3.skill.spear,
		[tes3.weaponType.axeOneHand] = tes3.skill.axe,
		[tes3.weaponType.axeTwoHand] = tes3.skill.axe,
		[tes3.weaponType.marksmanBow] = tes3.skill.handToHand,
		[tes3.weaponType.marksmanCrossbow] = tes3.skill.handToHand,
		[tes3.weaponType.marksmanThrown] = tes3.skill.handToHand,
		[tes3.weaponType.arrow] = tes3.skill.handToHand,
		[tes3.weaponType.bolt] = tes3.skill.handToHand,
		["kungFu"] = tes3.skill.handToHand,
	}
	local weaponType = data.weapon or "kungFu"
	local skillID = skillList[weaponType] or tes3.skill.handToHand
	skillLevel = data.thisMobileActor:getSkillValue(skillID)
	log:trace("Executed weapon skill check: Skill %s, skillDC %s", skillLevel, skillDC)

	local output = { weaponSkill = skillLevel, check = skillLevel >= skillDC, skillID = skillID }

	return output
end

return common
