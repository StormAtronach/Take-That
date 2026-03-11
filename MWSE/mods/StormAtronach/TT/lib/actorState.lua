-- actorState.lua — Per-actor momentum state for the momentum system
--
-- Only NPCs with a weapon equipped are tracked. Creatures are excluded because
-- their movement is driven differently; unarmed actors are excluded because the
-- weight scalar is undefined without a weapon.
--
-- State per actor:
--   cachedWeightScalar  : precomputed speed penalty from weapon weight vs strength.
--                         Cached on activation and refreshed on equip/unequip.
--   inAttack / peakSwing: attack phase tracking (used by scalars.recoveryScalar).
--   inRecovery / recoveryStartTime / recoveryDuration : post-attack slowdown window.
--
-- state is keyed by tes3reference so there are no ID collisions between actors
-- sharing the same base object.

local config = require("StormAtronach.TT.config")
local log = mwse.Logger.new({ moduleName = "actorState" })

local this = {}
local state = {}

-- Returns the full state table, used by the simulate loop in main.lua
function this.getAllState()
    return state
end

-- Returns the state entry for a specific reference, or nil if not tracked
function this.get(ref)
    return state[ref]
end

-- Called when a mobile becomes active in the world
function this.activate(mobile)
    -- Guard against projectiles and other non-actor mobiles
    if not mobile.actorType then return end
    -- Momentum system only applies to NPCs with a weapon equipped
    if mobile.actorType == tes3.actorType.creature then return end
    if not mobile.readiedWeapon then return end
    local ref = mobile.reference
    state[ref] = {
        cachedWeightScalar = 1.0,
        inAttack = false,
        peakSwing = 0,
        inRecovery = false,
        recoveryStartTime = nil,
        recoveryDuration = 0,
    }
    this.updateWeightScalar(ref)
    log:debug("Activated: %s", ref.id)
end

-- Called when a mobile is deactivated, cleans up state
function this.deactivate(mobile)
    log:debug("Deactivated: %s", mobile.reference.id)
    state[mobile.reference] = nil
end

-- Recomputes and caches the weight scalar for a reference
-- Should be called on activation and whenever equipment changes
function this.updateWeightScalar(ref)
    local s = state[ref]
    if not s then return end
    local mobile = ref.mobile
    if not mobile then return end

    local weight = 0
    local weapon = mobile.readiedWeapon
    if weapon then
        weight = weapon.object.weight
    end

    local attribute = this.getHandlingAttribute(mobile)
    local strengthMult = math.clamp(
        attribute / config.referenceStrength,
        config.strengthFloor,
        config.strengthCeiling
    )
    local normalizedWeight = weight / config.maxWeaponWeight
    -- Clamp to [0,1]: extreme MCM settings (high penalty, low strength) could produce negatives
    s.cachedWeightScalar = math.clamp(1.0 - (normalizedWeight * config.weightPenaltyStrength) / strengthMult, 0.0, 1.0)
    log:debug("Weight scalar for %s: %.3f (weapon=%.1f, attr=%d)", ref.id, s.cachedWeightScalar, weight, attribute)
end

-- Returns the relevant handling attribute for the actor type
-- NPCs and the player use strength; creatures use their combat statistic
function this.getHandlingAttribute(mobile)
    if mobile.actorType == tes3.actorType.creature then
        return mobile.combat.current
    else
        return mobile.attributes[tes3.attribute.strength + 1].current
    end
end

-- Begins a recovery phase for the given reference
-- swingCharge: 0.0 to 1.0, how charged the attack was
-- weaponWeight: raw weapon weight, 0 for unarmed
function this.startRecovery(ref, swingCharge, weaponWeight)
    local s = state[ref]
    if not s then return end
    local normalizedWeight = math.clamp(weaponWeight / config.maxWeaponWeight, 0, 1)
    local duration = math.lerp(
        config.recoveryMinDuration,
        config.recoveryMaxDuration,
        swingCharge * normalizedWeight
    )
    s.inRecovery = true
    s.recoveryStartTime = os.clock()
    s.recoveryDuration = duration
    log:debug("Recovery started for %s: swing=%.2f weight=%.1f duration=%.2fs", ref.id, swingCharge, weaponWeight, duration)
end

return this
