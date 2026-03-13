local common = require("StormAtronach.TT.lib.common")
local config = require("StormAtronach.TT.config")
local sounds = require("StormAtronach.TT.lib.sounds")
local log = mwse.Logger.new({ moduleName = "parry" })

-- Slow-mo state: nil when inactive, table during effect
local slowmoState = nil

-- On-strike enchantment blocker: set to the parried attacker's reference for one frame.
-- Any spellCasted from that reference with castType onStrike will be blocked.
local blockedEnchRef = nil

local function onSpellCasted_blockEnchant(e)
    if e.caster ~= blockedEnchRef then return end
    local source = e.source
    if source and source.castType == tes3.enchantmentType.onStrike then
        log:debug("Blocked on-strike enchantment from parried attacker %s", e.caster.id)
        e.block = true
    end
end

-- Per-frame handler: smoothsteps simulationTimeScalar through ease-in → hold → ease-out.
-- Timing uses os.clock() (wall clock) so ramp durations are real seconds regardless of scalar.
local function onSimulate_slowmo()
    if not slowmoState then return end
    local elapsed = os.clock() - slowmoState.startTime
    local ramp   = slowmoState.rampTime
    local hold   = slowmoState.holdTime
    local target = slowmoState.targetScalar
    local total  = ramp + hold + ramp

    local scalar
    if elapsed < ramp then
        local t = ramp > 0 and (elapsed / ramp) or 1.0
        t = t * t * (3 - 2 * t)  -- smoothstep
        scalar = 1.0 + (target - 1.0) * t
    elseif elapsed < ramp + hold then
        scalar = target
    elseif elapsed < total then
        local t = ramp > 0 and ((elapsed - ramp - hold) / ramp) or 1.0
        t = t * t * (3 - 2 * t)  -- smoothstep
        scalar = target + (1.0 - target) * t
    else
        tes3.worldController.simulationTimeScalar = 1.0
        event.unregister("simulate", onSimulate_slowmo)
        slowmoState = nil
        return
    end
    tes3.worldController.simulationTimeScalar = scalar
end

local parry = {
    name = "Parry",
    window = config.parry_window,
    cooldown = false,
    active = false
}

-- Parry outcome lookup table
-- Key: clamped opposed skill check result (defender level - attacker level), range [-1, 3].
-- All negative outcomes collapse to -1: the attacker dominated, both sides are rattled.
-- fatigueDrainKey: config key looked up at apply time so MCM changes take effect immediately.
local parryOutcomes = {
    [-1] = {
        attacker = { hitStun = true, knockDown = false, slowType = nil, fatigueDrainKey = "parry_fatigue_drain_neg" },
        defender = { hitStun = true, knockDown = false },
    },
    [0] = {
        attacker = { hitStun = true, knockDown = false, slowType = nil, fatigueDrainKey = "parry_fatigue_drain_0" },
        defender = { hitStun = false, knockDown = false },
    },
    [1] = {
        attacker = { hitStun = true, knockDown = false, slowType = 1, slowDuration = 1, fatigueDrainKey = "parry_fatigue_drain_1" },
        defender = { hitStun = false, knockDown = false },
    },
    [2] = {
        attacker = { hitStun = true, knockDown = false, slowType = 2, slowDuration = 1, fatigueDrainKey = "parry_fatigue_drain_2" },
        defender = { hitStun = false, knockDown = false },
    },
    [3] = {
        attacker = { hitStun = true, knockDown = true,  slowType = 3, slowDuration = 1, fatigueDrainKey = "parry_fatigue_drain_3" },
        defender = { hitStun = false, knockDown = false },
    },
}

--- Get the outcome for a given opposed skill check
--- @param opposedCheck number Defender skill level minus attacker skill level
--- @return table outcome The outcome data for attacker and defender
local function getOutcome(opposedCheck)
    local clamped = math.clamp(opposedCheck, -1, 3)
    return parryOutcomes[clamped]
end

--- Apply effects to an actor based on outcome data
--- @param mobile tes3mobileActor
--- @param reference tes3reference
--- @param effects table The effects to apply (hitStun, knockDown, slowType, slowDuration)
local function applyEffects(mobile, reference, effects)
    if effects.hitStun then
        -- knockDown is passed as a param to hitStun; tes3mobileActor has no standalone knockDown()
        mobile:hitStun({ knockDown = effects.knockDown or false })
        log:trace("Applied hitStun (knockDown=%s) to %s", tostring(effects.knockDown == true), reference)
    end

    if effects.slowType and config.parrySlowDown then
        common.slowActor(reference, effects.slowDuration or 1, effects.slowType)
        log:trace("Applied slowdown type %d to %s", effects.slowType, reference)
    end

    if effects.fatigueDrainKey and config.parry_fatigue_drain_enabled then
        local drain = config[effects.fatigueDrainKey] or 0
        if drain > 0 then
            tes3.modStatistic({ reference = reference, name = "fatigue", current = -drain })
            log:trace("Applied fatigue drain %d to %s", drain, reference)
        end
    end
end



-- Deferred outcome state — keyed by reference, supports multiple simultaneous parries
local pendingAttackerOutcomes = {}  -- [attackerRef] = outcome
local pendingDefenderOutcomes = {}  -- [defenderRef] = outcome
local attackerGuardTimers     = {}  -- [attackerRef] = timer
local defenderGuardTimers     = {}  -- [defenderRef] = timer

local ATTACKER_GUARD = 1.0   -- safety expiry for the next-frame callback
local DEFENDER_GUARD = 1.0   -- 

local function onDefenderAttackHit(e)
    local key = e.reference.id
    local p = pendingDefenderOutcomes[key]
    if not p then return end
    pendingDefenderOutcomes[key] = nil
    if defenderGuardTimers[key] then
        defenderGuardTimers[key]:cancel()
        defenderGuardTimers[key] = nil
    end
    if not p.defenderHandle:valid() then
        log:debug("Defender outcome expired: reference invalid")
        return
    end
    applyEffects(p.defenderMobile, p.defenderHandle:getObject(), p.defenderEffects)
end

--- Apply condition damage to a weapon
--- @param actor tes3mobileActor
--- @param damageAmount number
local function damageWeapon(actor, damageAmount)
    local weapon = actor.readiedWeapon
    if not weapon then return end
    
    local itemData = weapon.itemData
    if not itemData then
        -- Create item data if it doesn't exist
        itemData = tes3.addItemData({
            to = actor.reference,
            item = weapon.object,
        })
    end
    
    if itemData and itemData.condition then
        itemData.condition = math.max(0, itemData.condition - damageAmount)
        log:trace("Weapon condition reduced by %d to %d", damageAmount, itemData.condition)
    end
end


--- @param e attackHitEventData
function parry.attackHitCallback(e)
    log:trace("Parry attackHit event started")

    -- Guard: only parry attacks between actors who are in combat with each other.
    -- Prevents parrying stray hits from actors fighting someone else.
    -- If the player is involved (as attacker or defender) we assume combat intent and skip the check,
    -- since the player mobile does not maintain hostileActors reliably.
    local playerInvolved = e.mobile == tes3.mobilePlayer or e.targetMobile == tes3.mobilePlayer
    if not playerInvolved then
        local inCombatWithDefender = false
        for _, hostile in ipairs(e.mobile.hostileActors) do
            if hostile == e.targetMobile then
                inCombatWithDefender = true
                break
            end
        end
        if not inCombatWithDefender then
            log:debug("Parry skipped: %s is not in combat with %s", e.reference.id, e.targetReference.id)
            return
        end
    end

    local blockedDamage = e.mobile.actionData.physicalDamage
    e.mobile.actionData.physicalDamage = 0

    -- Block on-strike enchantment from parried attacker for this frame
    local aw = e.mobile.readiedWeapon
    if aw and aw.object.enchantment and aw.object.enchantment.castType == tes3.enchantmentType.onStrike then
        blockedEnchRef = e.reference
        event.register("spellCasted", onSpellCasted_blockEnchant)
        timer.delayOneFrame(function()
            event.unregister("spellCasted", onSpellCasted_blockEnchant)
            blockedEnchRef = nil
        end)
    end

---- Now, for the opposed skill check
    -- Get weapon types
    local attackerWeapon = e.mobile.readiedWeapon
    local attackerWeaponType = attackerWeapon and attackerWeapon.object.type or nil

    local defenderWeapon = e.targetMobile.readiedWeapon
    local defenderWeaponType = defenderWeapon and defenderWeapon.object.type or nil


    -- Calculate skill levels (0-4 based on skill/25)
    local attackerSkillCheck = common.weaponSkillCheck({
        thisMobileActor = e.mobile,
        weapon = attackerWeaponType
    })
    local attackerSkillLevel = math.floor(attackerSkillCheck.weaponSkill / 25)

    local defenderSkillCheck = common.weaponSkillCheck({
        thisMobileActor = e.targetMobile,
        weapon = defenderWeaponType
    })
    local defenderSkillLevel = math.floor(defenderSkillCheck.weaponSkill / 25)
    
    -- Calculate opposed check
    local opposedCheck = defenderSkillLevel - attackerSkillLevel
    log:debug("Parry opposed check: defender(%d) - attacker(%d) = %d", 
        defenderSkillLevel, attackerSkillLevel, opposedCheck)

    log:debug(string.format("Parry skill check: %s - %s = %s", defenderSkillLevel, attackerSkillLevel, opposedCheck))
    
    -- Get and apply outcome
    local outcome = getOutcome(opposedCheck)

    -- Weapon condition damage scaled to blocked physical damage
    if config.parry_weapon_damage_enabled and blockedDamage > 0 then
        local dmgAttacker = blockedDamage * config.parry_weapon_damage_fraction_attacker
        local dmgDefender = blockedDamage * config.parry_weapon_damage_fraction_defender
        damageWeapon(e.mobile,       dmgAttacker)
        damageWeapon(e.targetMobile, dmgDefender)
        log:debug("Weapon damage: attacker=%.1f defender=%.1f (blocked=%.1f)", dmgAttacker, dmgDefender, blockedDamage)
    end

    -- Defer attacker effects to the next frame
    local aKey    = e.reference.id
    local aHandle = tes3.makeSafeObjectHandle(e.reference)
    if attackerGuardTimers[aKey] then
        attackerGuardTimers[aKey]:cancel()
        attackerGuardTimers[aKey] = nil
    end
    pendingAttackerOutcomes[aKey] = {
        attackerMobile  = e.mobile,
        attackerEffects = outcome.attacker,
    }
    timer.delayOneFrame(function()
        local p = pendingAttackerOutcomes[aKey]
        if not p then return end
        pendingAttackerOutcomes[aKey] = nil
        if attackerGuardTimers[aKey] then
            attackerGuardTimers[aKey]:cancel()
            attackerGuardTimers[aKey] = nil
        end
        if not aHandle:valid() then
            log:debug("Attacker outcome expired: reference invalid")
            return
        end
        applyEffects(p.attackerMobile, aHandle:getObject(), p.attackerEffects)
    end)
    attackerGuardTimers[aKey] = timer.start({ duration = ATTACKER_GUARD, callback = function()
        if pendingAttackerOutcomes[aKey] then
            log:debug("Attacker outcome guard expired")
            pendingAttackerOutcomes[aKey] = nil
        end
        attackerGuardTimers[aKey] = nil
    end })

    -- Defer defender effects to their own next attackHit
    local dKey    = e.targetReference.id
    local dHandle = tes3.makeSafeObjectHandle(e.targetReference)
    if defenderGuardTimers[dKey] then
        defenderGuardTimers[dKey]:cancel()
        defenderGuardTimers[dKey] = nil
    end
    pendingDefenderOutcomes[dKey] = {
        defenderMobile  = e.targetMobile,
        defenderEffects = outcome.defender,
        defenderHandle  = dHandle,
    }
    defenderGuardTimers[dKey] = timer.start({ duration = DEFENDER_GUARD, callback = function()
        if pendingDefenderOutcomes[dKey] then
            log:debug("Defender outcome guard expired")
            pendingDefenderOutcomes[dKey] = nil
        end
        defenderGuardTimers[dKey] = nil
    end })

    -- Play a sound
    sounds.playRandom("parry",e.reference,1)
    if e.targetReference == tes3.player then
        -- Grant experience
        tes3.mobilePlayer:exerciseSkill(defenderSkillCheck.skillID, config.parry_skill_gain)
        -- Smooth slow-mo hit-stop. Allow restart on chained parries (slowmoState ~= nil),
        -- but skip if another mod has already set the scalar (guard: scalar must be 1).
        if config.parry_slowmo_enabled and (slowmoState ~= nil or tes3.worldController.simulationTimeScalar == 1) then
            if slowmoState then
                event.unregister("simulate", onSimulate_slowmo)
            end
            slowmoState = {
                startTime    = os.clock(),
                rampTime     = config.parry_slowmo_ramp_time,
                holdTime     = config.parry_slowmo_duration,
                targetScalar = config.parry_slowmo_scalar,
            }
            event.register("simulate", onSimulate_slowmo)
        end
        log:trace("Player parry mechanic finished")
    else
        log:trace("NPC parry mechanic finished")
    end

    local ar = e.reference
    local a  = e.mobile
    local tr = e.targetReference
    local t  = e.targetMobile
    -- VFX
    local VFXspark = tes3.getObject("AXE_sa_VFX_WSparks") ---@cast VFXspark tes3physicalObject
    tes3.createVisualEffect{object = VFXspark, repeatCount = 1, position = (ar.position + tes3vector3.new(0,0,a.height*0.9) + tr.position + tes3vector3.new(0,0,t.height*0.9)) / 2}



    -- Brief shimmer for visual feedback
     tes3.applyMagicSource({
                reference = e.targetReference,
                bypassResistances = true,
                effects = { { id = tes3.effect.light, min = config.parry_light_magnitude, max = config.parry_light_magnitude, duration = config.parry_light_duration } },
                name = "Parried!",
                })


end


parry.outcomes = parryOutcomes

event.register("attackHit", onDefenderAttackHit)

return parry