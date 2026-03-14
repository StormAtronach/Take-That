-- gmst.lua — GMST overrides for the momentum system
--
-- Applied only when gmst_enabled is true (on tes3.event.loaded in main.lua).
-- These values deliberately slow fatigue regeneration and raise the per-attack
-- cost so the momentum speed scalar has a meaningful effect in practice.
-- All three are restored to vanilla defaults when the game is closed; MWSE
-- does not persist GMST changes between sessions.

local config = require("StormAtronach.TT.config")
local log = mwse.Logger.new({ moduleName = "gmst" })

local this = {}

-- Vanilla GMST values captured once per session, before apply() is first called.
local vanilla = nil  ---@type { fatigueReturnBase: number, fatigueReturnMult: number, fatigueAttackBase: number }?

--- Captures the current (vanilla) GMST values before any mod overrides them.
--- Call this once per session before apply(). Safe to call multiple times — only captures once.
function this.captureVanilla()
    if vanilla then return end
    vanilla = {
        fatigueReturnBase = tes3.findGMST(tes3.gmst.fFatigueReturnBase).value --[[@as number]],
        fatigueReturnMult = tes3.findGMST(tes3.gmst.fFatigueReturnMult).value --[[@as number]],
        fatigueAttackBase = tes3.findGMST(tes3.gmst.fFatigueAttackBase).value --[[@as number]],
    }
    log:debug("Vanilla GMSTs captured — ReturnBase=%.2f ReturnMult=%.2f AttackBase=%.1f",
        vanilla.fatigueReturnBase, vanilla.fatigueReturnMult, vanilla.fatigueAttackBase)
end

--- Applies the current config GMST values to the engine.
function this.apply()
    tes3.findGMST(tes3.gmst.fFatigueReturnBase).value = config.fatigueReturnBase
    tes3.findGMST(tes3.gmst.fFatigueReturnMult).value = config.fatigueReturnMult
    tes3.findGMST(tes3.gmst.fFatigueAttackBase).value = config.fatigueAttackBase
    log:debug("GMSTs applied — ReturnBase=%.2f ReturnMult=%.2f AttackBase=%.1f",
        config.fatigueReturnBase, config.fatigueReturnMult, config.fatigueAttackBase)
end

--- Restores the vanilla GMST values captured at load time.
--- Also writes them back into config so the MCM sliders reflect the live engine state on next open.
function this.restoreVanilla()
    if not vanilla then
        log:warn("restoreVanilla: no vanilla values captured — call captureVanilla() first")
        return
    end
    tes3.findGMST(tes3.gmst.fFatigueReturnBase).value = vanilla.fatigueReturnBase
    tes3.findGMST(tes3.gmst.fFatigueReturnMult).value = vanilla.fatigueReturnMult
    tes3.findGMST(tes3.gmst.fFatigueAttackBase).value = vanilla.fatigueAttackBase
    config.fatigueReturnBase = vanilla.fatigueReturnBase
    config.fatigueReturnMult = vanilla.fatigueReturnMult
    config.fatigueAttackBase = vanilla.fatigueAttackBase
    log:debug("Vanilla GMSTs restored — ReturnBase=%.2f ReturnMult=%.2f AttackBase=%.1f",
        vanilla.fatigueReturnBase, vanilla.fatigueReturnMult, vanilla.fatigueAttackBase)
end

--- Restores the mod's default GMST values to the engine.
--- Also writes them back into config so the MCM sliders reflect the live engine state on next open.
--- Resets the config GMST values to the mod's defaults without touching the live engine values.
--- apply() will push them to the engine on next load if gmst_enabled is true.
function this.restoreDefaults()
    local d = config.default
    config.fatigueReturnBase = d.fatigueReturnBase
    config.fatigueReturnMult = d.fatigueReturnMult
    config.fatigueAttackBase = d.fatigueAttackBase
    log:debug("GMST defaults written to config — ReturnBase=%.2f ReturnMult=%.2f AttackBase=%.1f",
        d.fatigueReturnBase, d.fatigueReturnMult, d.fatigueAttackBase)
end

return this
