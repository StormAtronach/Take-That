-- gmst.lua — GMST overrides for the momentum system
--
-- Applied only when momentum is enabled (on tes3.event.loaded in main.lua).
-- These values deliberately slow fatigue regeneration and raise the per-attack
-- cost so the momentum speed scalar has a meaningful effect in practice.
-- All three are restored to vanilla defaults when the game is closed; MWSE
-- does not persist GMST changes between sessions.

local config = require("StormAtronach.TT.config")
local log = mwse.Logger.new({ moduleName = "gmst" })

local this = {}

function this.apply()
    tes3.findGMST(tes3.gmst.fFatigueReturnBase).value = config.fatigueReturnBase
    tes3.findGMST(tes3.gmst.fFatigueReturnMult).value = config.fatigueReturnMult
    tes3.findGMST(tes3.gmst.fFatigueAttackBase).value = config.fatigueAttackBase
    log:debug("GMSTs applied — ReturnBase=%.2f ReturnMult=%.2f AttackBase=%.1f",
        config.fatigueReturnBase, config.fatigueReturnMult, config.fatigueAttackBase)
end

return this
