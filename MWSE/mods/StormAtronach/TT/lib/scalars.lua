-- scalars.lua — Speed multiplier components for the momentum system
--
-- composite() multiplies three independent scalars:
--   fatigueScalar  : ratio of current/max fatigue raised to a configurable exponent.
--                    A drained actor moves noticeably slower; full fatigue = 1.0.
--   weightScalar   : precomputed per-actor in actorState.updateWeightScalar().
--                    Heavy weapons relative to strength reduce this below 1.0.
--   recoveryScalar : ease-out curve during the post-attack recovery window.
--                    Peaks right after a swing, then eases back to 1.0.
--
-- An absolute floor prevents any actor from being frozen (divide-by-near-zero safety).

local config = require("StormAtronach.TT.config")

local this = {}

-- Computes the fatigue-based speed scalar for a mobile
-- Returns a value between fatigueSpeedFloor and 1.0
function this.fatigueScalar(mobile)
    local max = mobile.fatigue.base
    if max <= 0 then return config.fatigueSpeedFloor end
    local ratio = math.clamp(mobile.fatigue.current / max, 0, 1)
    local scaled = ratio ^ config.fatigueExponent
    return math.max(scaled, config.fatigueSpeedFloor)
end

-- Computes the recovery phase scalar from actor state
-- Returns a value between recoverySpeedMin and 1.0
-- Marks recovery as complete and returns 1.0 once duration has elapsed
function this.recoveryScalar(actorState)
    if not actorState.inRecovery then return 1.0 end
    local elapsed = os.clock() - actorState.recoveryStartTime
    local t = math.clamp(elapsed / actorState.recoveryDuration, 0, 1)
    if t >= 1.0 then
        actorState.inRecovery = false
        return 1.0
    end
    -- ease-out curve: recovery accelerates toward the end
    local eased = 1.0 - (1.0 - t) ^ config.recoveryEaseExp
    return math.lerp(config.recoverySpeedMin, 1.0, eased)
end

-- Combines all scalars into a final speed multiplier
-- Applies the absolute floor as a safety clamp
function this.composite(fatigueScalar, weightScalar, recoveryScalar)
    local result = fatigueScalar * weightScalar * recoveryScalar
    return math.max(result, config.absoluteSpeedFloor)
end

return this
