--- Take That! — interop.lua
--- Public API for other mods. Use include() to avoid hard dependency:
---   local TT = include("StormAtronach.TT.interop")
---   if TT then ... end

local config = require("StormAtronach.TT.config")
local common = require("StormAtronach.TT.lib.common")
local parry  = require("StormAtronach.TT.mechanics.parry")

local interop = {}

--- Parry outcome lookup table, keyed by opposed skill check result (-1 to 3).
--- Modify entries at any time to change what happens when a parry resolves.
--- @type table
interop.parryOutcomes = parry.outcomes

--- Set of actors whose parry window is currently active, keyed by tes3reference.
--- A truthy value means the actor is ready to parry an incoming hit this frame.
--- @type table<tes3reference, boolean>
interop.parryingActors = common.parryingActors

--- Enable or disable a mechanic by name. Takes effect immediately.
--- @param name string  "block" | "parry" | "dodge" | "spellbatting"
--- @param enabled boolean
function interop.setMechanicEnabled(name, enabled)
    local key = name .. "_enabled"
    assert(config[key] ~= nil, ("Take That interop: unknown mechanic '%s'"):format(name))
    config[key] = enabled
    event.trigger("stormatronach:modActivation")
end

--- Returns whether a mechanic is currently enabled.
--- @param name string
--- @return boolean
function interop.isMechanicEnabled(name)
    return config[name .. "_enabled"] == true
end

return interop
