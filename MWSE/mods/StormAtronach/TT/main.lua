-- Take That! — main.lua
-- Entry point: wires all events and orchestrates the block/parry/dodge/spellbatting mechanics.

local common        = require("StormAtronach.TT.lib.common")
local config        = require("StormAtronach.TT.config")
local actorState    = require("StormAtronach.TT.lib.actorState")
local scalars       = require("StormAtronach.TT.lib.scalars")
local gmst          = require("StormAtronach.TT.lib.gmst")
local npcDodge      = require("StormAtronach.TT.mechanics.npcDodge")
local log = mwse.Logger.new()

-- Variables

local slowTypeToSpeed = { [1] = 0.75, [2] = 0.5, [3] = 0.25, [4] = 0.0 }


-- ── Memory patches (HrnChamd - Axemagister) ──────────────────────────────────────────────
-- These patches rewrite engine bytecode to give NPCs a swing charge animation and
-- the ability to hold a charged swing, matching what the player can already do.
-- Written by HrnChamd; included here with permission.
---@ diagnostic disable
mwse.memory.writeBytes{address = 0x541530, bytes = { 0x8B, 0x15, 0xDC, 0x67, 0x7C, 0x00, 0xD9, 0x42, 0x2C, 0x8B, 0x41, 0x3C, 0xD8, 0x88, 0xDC, 0x04, 0x00, 0x00, 0x8B, 0x51, 0x38, 0x8D, 0x82, 0xCC, 0x00, 0x00, 0x00, 0xD8, 0x40, 0x08, 0xD9, 0x58, 0x08, 0xC7, 0x41, 0x10, 0x00, 0x00, 0x80, 0xBF, 0xC6, 0x40, 0x11, 0x03, 0xD9, 0x41, 0x2C, 0xD8, 0x1D, 0x68, 0x64, 0x74, 0x00, 0xDF, 0xE0, 0xF6, 0xC4, 0x40, 0x75, 0x0B, 0x8B, 0x41, 0x2C, 0x89 } }
mwse.memory.writeBytes{address = 0x5414E0, bytes = { 0x8B, 0x46, 0x3C, 0xD8, 0x88, 0xDC, 0x04, 0x00, 0x00, 0x8B, 0x46, 0x38, 0xD8, 0x80, 0xD4, 0x00, 0x00, 0x00, 0xD9, 0x98, 0xD4, 0x00, 0x00, 0x00, 0xD9, 0x46, 0x20, 0xD8, 0x1D, 0x68, 0x64, 0x74, 0x00, 0xDF, 0xE0, 0xF6, 0xC4, 0x40, 0x75, 0x1F, 0x8B, 0x46, 0x3C, 0xD9, 0x40, 0x5C, 0x8B, 0x0D, 0xDC, 0x67, 0x7C, 0x00, 0xD8, 0x41, 0x2C, 0xD8, 0x5E, 0x20, 0xDF, 0xE0, 0xF6, 0xC4, 0x01, 0x75, 0x06, 0x8B, 0x56, 0x20, 0x89, 0x56, 0x10, 0x5E, 0x5B, 0xC2, 0x04, 0x00 } }
mwse.memory.writeBytes{address = 0x54147A, bytes = { 0x8B, 0x90, 0x88, 0x03, 0, 0, 0x0A, 0x90, 0x28, 0x02, 0, 0, 0x85, 0xD2, 0x75, 0x04, 0x84, 0xDB, 0x75, 0x3D } }
mwse.memory.writeBytes{address = 0x5414B4, bytes = { 0xD9, 0x46, 0x20, 0xD8, 0x66, 0x18, 0xDE, 0xF9, 0xEB, 0x03 } }
---@ diagnostic enable

-- New Mechanics

local mechanics = {}
mechanics.block = require("StormAtronach.TT.mechanics.block")
mechanics.parry = require("StormAtronach.TT.mechanics.parry")
mechanics.dodge = require("StormAtronach.TT.mechanics.dodge")
mechanics.spellbatting = require("StormAtronach.TT.mechanics.spellbatting")

-- New time manipulation
-- State for smooth parrySlowDown transition.
-- phase: "in" (easing 1→target), "hold" (at target, indefinite), "out" (easing back to 1)
local mainSlowmoState = nil

local function onSimulate_mainSlowmo()
    if not mainSlowmoState then return end
    local elapsed = os.clock() - mainSlowmoState.phaseStart
    local ramp = config.parry_slowmo_ramp_time
    if mainSlowmoState.phase == "in" then
        local target = mainSlowmoState.targetScalar
        if elapsed >= ramp then
            tes3.worldController.simulationTimeScalar = target
            mainSlowmoState.phase = "hold"
        else
            local t = ramp > 0 and (elapsed / ramp) or 1.0
            t = t * t * (3 - 2 * t)
            tes3.worldController.simulationTimeScalar = 1.0 + (target - 1.0) * t
        end
    elseif mainSlowmoState.phase == "out" then
        local fromScalar = mainSlowmoState.fromScalar
        if elapsed >= ramp then
            tes3.worldController.simulationTimeScalar = 1.0
            event.unregister("simulate", onSimulate_mainSlowmo)
            mainSlowmoState = nil
        else
            local t = ramp > 0 and (elapsed / ramp) or 1.0
            t = t * t * (3 - 2 * t)
            tes3.worldController.simulationTimeScalar = fromScalar + (1.0 - fromScalar) * t
        end
    end
end

--- @param e attackStartEventData
local function parrySlowDown(e)
    if not config.parrySlowDown then return end
    if e.reference == tes3.player then
        -- Player attacks: start ease-out from wherever we currently are
        if mainSlowmoState and mainSlowmoState.phase ~= "out" then
            mainSlowmoState.phase = "out"
            mainSlowmoState.phaseStart = os.clock()
            mainSlowmoState.fromScalar = tes3.worldController.simulationTimeScalar
        end
    elseif tes3.mobilePlayer.animationController:calculateAttackSwing() > 0.9 then
        -- NPC attacks while player is power-charging: start ease-in
        if mainSlowmoState == nil then
            mainSlowmoState = { phase = "in", phaseStart = os.clock(), targetScalar = 0.5 }
            event.register("simulate", onSimulate_mainSlowmo)
        end
    end
end

--- @param e attackHitEventData
local function resetTimescale(e)
    if not config.parrySlowDown then return end
    -- Trigger ease-out from wherever we currently are
    if mainSlowmoState and mainSlowmoState.phase ~= "out" then
        mainSlowmoState.phase = "out"
        mainSlowmoState.phaseStart = os.clock()
        mainSlowmoState.fromScalar = tes3.worldController.simulationTimeScalar
    end
end


-- Functions

local function deactivate(mechanic)
    if mechanic then
        mechanic.active = false
        log:debug("Active flag reset for %s", mechanic.name)
    else
        for _, m in pairs(mechanics) do
            m.active = false
        end
        log:debug("Active flags reset (all)")
    end
end



-- ── Collision-parry geometry helpers ─────────────────────────────────────────
-- Returns the weapon attachment node for a reference (hilt bone or hand bone).
local function getWeaponNode(ref)
    if not ref or not ref.sceneNode then return nil end
    return ref.sceneNode:getObjectByName("Weapon")
        or ref.sceneNode:getObjectByName("Bip01 R Hand")
end

-- Estimates the tip of a weapon using the object bounding box + world transform.
local function estimateTip(weaponNode, ref)
    local meshNode = weaponNode:getObjectByName("Weapon") or weaponNode
    local wt  = meshNode.worldTransform
    local mob = ref and ref.mobile
    local rw  = mob and mob.readiedWeapon
    local box = rw and rw.object and rw.object.boundingBox
    if not box then return wt.translation end
    local localTip = (box.max:length() >= box.min:length()) and box.max or box.min
    local rotated  = tes3vector3.new(0, 0, localTip.y)
    return wt.translation + wt.rotation * (rotated * wt.scale)
end

-- Segment-to-segment closest distance; also returns the midpoint of the closest pair.
local function segSegDist(a1, a2, b1, b2)
    local u  = a2 - a1
    local v  = b2 - b1
    local w0 = a1 - b1
    local a  = u:dot(u)
    local b  = u:dot(v)
    local c  = v:dot(v)
    local d  = u:dot(w0)
    local e  = v:dot(w0)
    local denom = a * c - b * b
    local s, t
    if denom < 1e-8 then
        s = 0
        t = (b > c) and (d / b) or (e / c)
    else
        s = (b * e - c * d) / denom
        t = (a * e - b * d) / denom
    end
    s = math.max(0, math.min(1, s))
    t = math.max(0, math.min(1, t))
    local pa  = a1 + u * s
    local pb  = b1 + v * t
    return pa:distance(pb), (pa + pb) * 0.5
end

-- Spawns a debug sphere at `pos` for 2 seconds using the mwse widgets.nif unitSphere.
-- Reuses the same scene node across calls (identified by name "TT_collision_sphere").
local function spawnDebugSphere(pos)
    local root = tes3.worldController.vfxManager.worldVFXRoot
    local sphere = root:getObjectByName("TT_collision_sphere") --[[@as niTriShape?]]
    if not sphere then
        sphere = tes3.loadMesh("mwse\\widgets.nif"):getObjectByName("unitSphere"):clone() --[[@as niTriShape]]
        sphere.name = "TT_collision_sphere"
        root:attachChild(sphere, true)
    end
    sphere.appCulled  = false
    sphere.translation = pos
    sphere.scale       = 5
    sphere:update()
    sphere:updateEffects()
    sphere:updateProperties()
    timer.start({ duration = 2.0, callback = function()
        sphere.appCulled = true
        sphere:update()
    end })
end

-- Spawns the parry spark VFX. When config.parry_collision_vfx_at_point is true and
-- checkFrustum is true, tries to spawn at `pos` (frustum-checked). Falls back to the
-- height-midpoint between refA and refB in all other cases.
local function spawnParryVFX(pos, checkFrustum, refA, refB)
    local VFXspark = tes3.getObject("AXE_sa_VFX_WSparks") ---@cast VFXspark tes3physicalObject
    if not VFXspark then return end
    local spawnPos
    if checkFrustum and config.parry_collision_vfx_at_point then
        local camera = tes3.worldController.worldCamera.cameraData.camera
        ---@diagnostic disable-next-line: undefined-field
        if camera:worldPointToScreenPoint(pos) then
            spawnPos = pos
        end
    end
    if not spawnPos then
        local mA, mB = refA.mobile, refB.mobile
        if mA and mB then
        spawnPos = (refA.position + tes3vector3.new(0,0,mA.height*0.9)
                  + refB.position + tes3vector3.new(0,0,mB.height*0.9)) * 0.5
        end
    end
    if spawnPos then
    tes3.createVisualEffect{ object = VFXspark, repeatCount = 1, position = spawnPos }
    end
end

-- Keyed by reference; contains the reference while that actor is mid-swing.
-- Populated on `attack`, cleared on `attackHit` (or resetState).
local activeWeaponTrackers = {}
local onSimulate_collisionParry  -- forward declaration

local function addWeaponTracker(ref)
    if not next(activeWeaponTrackers) then
        event.register(tes3.event.simulate, onSimulate_collisionParry)
    end
    activeWeaponTrackers[ref] = true
end

local function removeWeaponTracker(ref)
    activeWeaponTrackers[ref] = nil
    if not next(activeWeaponTrackers) then
        event.unregister(tes3.event.simulate, onSimulate_collisionParry)
    end
end

onSimulate_collisionParry = function()
    -- Need at least two actors swinging simultaneously
    local refs = {}
    for ref in pairs(activeWeaponTrackers) do refs[#refs + 1] = ref end
    if #refs < 2 then return end

    for i = 1, #refs do
        for j = i + 1, #refs do
            local refA = refs[i]
            local refB = refs[j]

            -- NPC-to-NPC guard: skip if they are not in combat with each other.
            -- Player involvement bypasses the check (player mobile does not maintain hostileActors).
            local playerInvolved = refA == tes3.player or refB == tes3.player
            if not playerInvolved then
                local mobA = refA.mobile
                local inCombat = false
                if mobA then
                    for _, hostile in ipairs(mobA.hostileActors) do
                        if hostile == refB.mobile then inCombat = true; break end
                    end
                end
                if not inCombat then goto nextPair end
            end

            local nodeA = getWeaponNode(refA)
            local nodeB = getWeaponNode(refB)
            if not nodeA or not nodeB then goto nextPair end

            local posA = nodeA.worldTransform.translation
            local tipA = estimateTip(nodeA, refA)
            local posB = nodeB.worldTransform.translation
            local tipB = estimateTip(nodeB, refB)

            local dist, mid = segSegDist(posA, tipA, posB, tipB)
            log:debug("Collision probe: %s vs %s  dist=%.1f", refA.id, refB.id, dist)

            if dist < config.parry_collision_threshold then
                log:debug("Collision parry triggered: %s vs %s at dist=%.1f", refA.id, refB.id, dist)

                -- Spawn sparks at the collision point (frustum-checked; falls back to height-midpoint)
                spawnParryVFX(mid, true, refA, refB)

                -- Activate parry flags for both sides
                mechanics.parry.collisionMid = mid  -- consumed by attackHitCallback for VFX placement
                if refA == tes3.player or refB == tes3.player then
                    common.parryingActors[tes3.player] = true
                end
                if config.enemy_parry_active then
                    if refA ~= tes3.player then common.parryingActors[refA] = true end
                    if refB ~= tes3.player then common.parryingActors[refB] = true end
                end

                -- Remove both from tracking so this pair cannot re-trigger
                removeWeaponTracker(refA)
                removeWeaponTracker(refB)
                return  -- refs table is now stale; let the next frame re-evaluate remaining pairs
            end

            ::nextPair::
        end
    end
end

local function resetState()
    -- Cancel any in-progress slow-mo and reset timescale
    if mainSlowmoState then
        event.unregister("simulate", onSimulate_mainSlowmo)
        mainSlowmoState = nil
    end
    tes3.worldController.simulationTimeScalar = 1

        for _, mechanic in pairs(mechanics) do
        mechanic.cooldown = false
    end
    log:debug("Cooldowns reset")

    -- Clear shared tables in-place to preserve references held by interop consumers
    table.clear(common.slowedActors)
    table.clear(common.parryingActors)
    table.clear(activeWeaponTrackers)
    event.unregister(tes3.event.simulate, onSimulate_collisionParry)
    log:debug("Tables reset")

    -- Reset and reload block/dodge controllers so they target the fresh player scene node
    mechanics.block.reset()
    mechanics.block.loadControllers()
    mechanics.dodge.reset()
    mechanics.dodge.loadControllers()

    -- And the animation reset just in case
   local animReference = tes3.mobilePlayer.is3rdPerson and tes3.player or tes3.player1stPerson
   tes3.playAnimation({
       reference = animReference,
       group = 0,
   })
   log:debug("Animation reset")

end

local function activate(e)
    local mechanic = e.data.mechanic
    deactivate(mechanic)
    mechanic.active = true
    if mechanic.window then
        timer.start({duration = mechanic.window, callback = function()
            if not (mechanic == mechanics.parry and config.parry_debug_always_active) then
                deactivate(mechanic)
            end
        end, type = timer.simulate})
        log:debug("Window started for %s. Duration: %s seconds", mechanic.name, mechanic.window)
    end
end

-- Momentum event handlers

local function onMobileActivated(e)
    if not config.momentum_enabled then return end
    actorState.activate(e.mobile)
    log:debug("Momentum state created for %s", e.mobile.reference.id)
end

local function onMobileDeactivated(e)
    actorState.deactivate(e.mobile)
    log:debug("Momentum state removed for %s", e.mobile.reference.id)
end

local function onEquip(e)
    log:debug("Equip on %s — scheduling weight scalar update", e.reference.id)
    timer.delayOneFrame(function() actorState.updateWeightScalar(e.reference) end)
end

local function onUnequip(e)
    log:debug("Unequip on %s — scheduling weight scalar update", e.reference.id)
    timer.delayOneFrame(function() actorState.updateWeightScalar(e.reference) end)
end

local function onAttackStart_momentum(e)
    local s = actorState.get(e.reference)
    if not s then return end
    s.inAttack = true
    s.peakSwing = 0
    log:debug("Attack swing started by %s", e.reference.id)
end

-- On the simulate event, apply momentum scalars and manage the slow table
local function onSimulate_slow()
    -- Step 1: apply momentum + TT slow factor to all momentum-tracked actors
    if config.momentum_enabled then
        for ref, s in pairs(actorState.getAllState()) do
            local mobile = ref.mobile
            if not (mobile and mobile.animationController) then goto nextActor end
            local momentum = scalars.composite(
                scalars.fatigueScalar(mobile),
                s.cachedWeightScalar,
                scalars.recoveryScalar(s)
            )
            local slowEntry = common.slowedActors[ref]
            local ttFactor = slowEntry and (slowTypeToSpeed[slowEntry.typeSlow] or 0.75) or 1.0
            mobile.animationController.speedMultiplier = momentum * ttFactor
            ::nextActor::
        end
    end

    -- Step 2: expire slow entries; restore speed for actors not covered by momentum
    if next(common.slowedActors) == nil then return end
    local slowedActorsAux = {}
    for actor_ref, actor in pairs(common.slowedActors) do
        local startTime = actor.startTime
        local duration  = actor.duration
        local typeSlow  = actor.typeSlow

        if not (startTime and duration and typeSlow) then
            log:error("Values error. Actor ref = %s, Start time = %s, duration = %s, type = %s", actor_ref, startTime, duration, typeSlow)
            goto continue
        end

        if os.clock() - startTime < duration then
            slowedActorsAux[actor_ref] = actor
            -- Momentum off: write slow directly (momentum on handles it in step 1)
            if not config.momentum_enabled then
                local animController = actor_ref.mobile and actor_ref.mobile.animationController
                if animController then
                    local base = actor.originalSpeed or 1.0
                    animController.speedMultiplier = base * (slowTypeToSpeed[typeSlow] or 0.75)
                end
            end
        else
            -- Expired: only restore speed for actors not covered by momentum
            if not (config.momentum_enabled and actorState.get(actor_ref)) then
                local animController = actor_ref.mobile and actor_ref.mobile.animationController
                if animController then animController.speedMultiplier = actor.originalSpeed or 1.0 end
            end
        end

        ::continue::
    end
    common.slowedActors = slowedActorsAux
end

--- @param e attackHitEventData
local function attackHitCallback(e)
    local TS = tes3.getSimulationTimestamp()
    local ID = e.reference.id
    log:trace("Attack hit event, ID: %s, TS: %s",ID,TS)

    -- Collision mode: remove attacker from weapon tracking
    if activeWeaponTrackers[e.reference] then
        removeWeaponTracker(e.reference)
    end

    if not e.targetReference or not e.targetMobile then
        log:debug("attackHit fired with no target: attacker=%s", ID)
        if not (e.reference == tes3.player and config.parry_debug_always_active) then
            common.parryingActors[e.reference] = nil
        end
        return
    end

        -- Is the target the player
        local lookOutPlayer = e.targetReference == tes3.player

        -- Clear attacker's own parry window when their attack resolves (before any early returns)
        if not (e.reference == tes3.player and config.parry_debug_always_active) then
            common.parryingActors[e.reference] = nil
        end

        -- Dodge stream
        if lookOutPlayer and mechanics.dodge.active then
            e.mobile.actionData.physicalDamage = 0
            common.slowActor(e.reference, 2, 2)
            -- Play sound
            tes3.playSound{ sound = "enchant fail" }
            -- Grant experience
            tes3.mobilePlayer:exerciseSkill(tes3.skill.acrobatics, config.dodge_skill_gain)
            return
        end

        -- Parry stream: defender must have an active parry flag; NPC-as-defender requires enemy_parry_active
        if config.parry_enabled and common.parryingActors[e.targetReference] then
            if e.targetReference == tes3.player or config.enemy_parry_active then
                mechanics.parry.attackHitCallback(e)
            end
        end

end

-- Parry mechanic - with hit chance manipulation
--- @param e calcHitChanceEventData
local function onCalcHitChance(e)
    local TS = tes3.getSimulationTimestamp()
    local ID = e.attacker.id
    log:trace("Calc hit chance event, ID: %s, TS: %s", ID,TS)

    -- If the attacker is the player, and the balancing of hitchance is enabled, let's multiply the hitchance by that value
    if e.attacker == tes3.player and config.hitChanceModPlayer then
        e.hitChance = (config.hitChanceMultiplier > 0) and e.hitChance*config.hitChanceMultiplier or e.hitChance
    elseif e.attacker ~= tes3.player and config.hitChanceModNPC then
        e.hitChance = (config.hitChanceMultiplier > 0) and e.hitChance*config.hitChanceMultiplier or e.hitChance
    end
end

--- @param e attackEventData
local function onAttack(e)
    local TS = tes3.getSimulationTimestamp()
    local ID = e.reference.id
    log:trace("Attack event,ID: %s, TS: %s",ID,TS)
    -- Check if it is the player. Would love to add that to NPCs but they'll need an AI upgrade to be able to do this
    local playerIsThatYou   = e.reference == tes3.player
    -- Check if the attack is fully drawn. Currently set to 0
    local areYouReady       = tes3.mobilePlayer.actionData.attackSwing >= config.parry_min_swing

    -- Power attacking!
    if config.parry_enabled and config.parry_collision_mode then
        -- Collision mode: track any armed attacker; compute per-frame segment distances
        local mob = e.reference.mobile
        if mob and mob.readiedWeapon then
            addWeaponTracker(e.reference)
            log:debug("Collision tracking started for %s", e.reference.id)
        end
    elseif config.parry_enabled and not config.parry_collision_mode then
        local mob = e.reference.mobile
        local swing = mob and mob.actionData.attackSwing or 0
        if mob and mob.readiedWeapon then
            if playerIsThatYou and areYouReady then
                common.parryingActors[tes3.player] = true
                log:trace("Player parry window opened")
            elseif not playerIsThatYou and config.enemy_parry_active and swing >= config.enemy_min_attackSwing then
                common.parryingActors[e.reference] = true
                log:trace("NPC parry window opened for %s", e.reference.id)
            end
        end
    end

    -- Spell batting
    if playerIsThatYou and areYouReady then
        mechanics.spellbatting.activateBatting()
    end

    -- Incoming attack dodge trigger
    if not playerIsThatYou and e.targetReference and (e.targetReference == tes3.player or e.targetReference == tes3.player1stPerson) then
        mechanics.dodge.onIncomingAttack()
    end

    -- Momentum recovery
    if config.momentum_enabled then
        local s = actorState.get(e.reference)
        if s then
            local swing = e.mobile.animationController:calculateAttackSwing()
            if swing == 0 then swing = 0.5 end  -- creatures don't charge
            local weight = e.mobile.readiedWeapon and e.mobile.readiedWeapon.object.weight or 0
            actorState.startRecovery(e.reference, swing, weight)
        end
    end

end

--- @param e damageEventData
local function onDamage(e)
    local TS = tes3.getSimulationTimestamp()
    local ID = e.reference.id
    log:trace("Damage event, ID: %s, TS: %s",ID,TS)
    -- Damage multiplier stream for the player attacks
    if e.source == tes3.damageSource.attack and e.attackerReference == tes3.player and config.damageMultiplierPlayer and not e.projectile then
        local oldDamage = e.damage or 0
        e.damage = (e.damage*config.damageMultiplier) or 0
        local newDamage = e.damage or 0
        log:trace("Damage by the player modified. Original damage: %s, new damage: %s",oldDamage,newDamage)
    end
    -- Damage multiplier stream for NPC attacks
    if e.source == tes3.damageSource.attack and e.attackerReference ~= tes3.player and config.damageMultiplierNPC and not e.projectile then
        local oldDamage = e.damage or 0
        e.damage = (e.damage*config.damageMultiplier) or 0
        local newDamage = e.damage or 0
        log:trace("Damage by an NPC modified. Original damage: %s, new damage: %s",oldDamage,newDamage)
    end



    mechanics.block.onDamage(e)
end


-- Capping the vanilla block chance
---@param e calcBlockChanceEventData
local function calcBlockChanceCallback(e)
    local TS = tes3.getSimulationTimestamp()
    local ID = e.target.id
    log:trace("Calc block chance event, ID: %s, TS: %s",ID,TS)

    if e.target ~= tes3.player then return end
    local playerAttacking = tes3.mobilePlayer.actionData.attackSwing == 1
    local allowVanillaBlock = config.allow_vanilla_block
    if e.blockChance > config.vanilla_blocking_cap and not (playerAttacking and allowVanillaBlock) then
        e.blockChance = config.vanilla_blocking_cap
    end
end


-- Initializing the mod. Setting priority lower than Poleplay (it is -10 there)
-- Registers all events. Called once on tes3.event.initialized, and again after
-- modActivation() tears everything down (for MCM toggle on → re-enable).
local function initialized()
    -- ── Combat core ───────────────────────────────────────────────────────────
    event.register(tes3.event.calcHitChance,  onCalcHitChance,       { priority = -100 })
    event.register(tes3.event.damage,         onDamage,              { priority = -100 })
    event.register(tes3.event.attack,         onAttack,              { priority = -100 })
    event.register(tes3.event.calcBlockChance, calcBlockChanceCallback, { priority = -100 })
    event.register(tes3.event.attackHit,      attackHitCallback)

    -- ── Block ──────────────────────────────────────────────────────────────────
    if config.block_enabled then
        event.register("keybindTested", mechanics.block.onKeybindTested)
        event.register("simulate",      mechanics.block.onSimulate)
        event.register("simulated",     mechanics.block.onSimulated, { priority = -10000 })
    end

    -- ── Dodge ──────────────────────────────────────────────────────────────────
    if config.dodge_enabled then
        mechanics.dodge.init()
        mechanics.dodge.loadControllers()
        event.register("TT:dodgeTriggered", function(e)
            mechanics.dodge.window = e.duration
            activate({ data = { mechanic = mechanics.dodge } })
        end)
    end

    -- ── Parry slow-motion ──────────────────────────────────────────────────────
    if config.parry_enabled then
        event.register(tes3.event.attackStart, parrySlowDown)
        event.register(tes3.event.attackHit,   resetTimescale)
    end

    -- ── Spell batting ──────────────────────────────────────────────────────────
    if config.spellbatting_enabled then
        event.register(tes3.event.mobileActivated, mechanics.spellbatting.onMobileActivated)
        event.register(tes3.event.attack,          mechanics.spellbatting.onAttack)
        event.register("projectileExpire",         mechanics.spellbatting.onProjectileExpire)
    end

    -- ── Momentum ───────────────────────────────────────────────────────────────
    event.register(tes3.event.simulate,          onSimulate_slow)
    event.register(tes3.event.mobileActivated,   onMobileActivated)
    event.register(tes3.event.mobileDeactivated, onMobileDeactivated)
    event.register(tes3.event.equip,             onEquip)
    event.register("unequipped",                 onUnequip)
    event.register(tes3.event.attackStart,       onAttackStart_momentum)

    -- ── NPC reactions + VFX ───────────────────────────────────────────────────
    npcDodge.init()
    local sparks = tes3.createObject{ objectType = tes3.objectType.static, id = "AXE_sa_VFX_WSparks", mesh = "e\\spark.nif" }
    tes3.createObject{ objectType = tes3.objectType.static, id = "sa_trail", mesh = "sa\\trail.nif", getIfExists = true }

    log:debug("Take That! initialized. Sparks VFX: %s", sparks and "OK" or "FAILED")
end

-- Unregisters all events (for MCM toggle). Calls resetState() to stop any active
-- animations / timers, then re-calls initialized() if the mod was toggled back on.
local function modActivation()
    log:debug("Take That! toggled: %s", config.enabled and "ON" or "OFF")

    -- ── Unregister (mirrors initialized() above) ───────────────────────────────
    event.unregister(tes3.event.calcHitChance,       onCalcHitChance)
    event.unregister(tes3.event.damage,              onDamage)
    event.unregister(tes3.event.attack,              onAttack)
    event.unregister(tes3.event.calcBlockChance,     calcBlockChanceCallback)
    event.unregister(tes3.event.attackHit,           attackHitCallback)

    event.unregister("keybindTested",                mechanics.block.onKeybindTested)
    event.unregister("simulate",                     mechanics.block.onSimulate)
    event.unregister("simulated",                    mechanics.block.onSimulated)

    mechanics.dodge.shutdown()

    event.unregister(tes3.event.attackStart,         parrySlowDown)
    event.unregister(tes3.event.attackHit,           resetTimescale)

    event.unregister(tes3.event.mobileActivated,     mechanics.spellbatting.onMobileActivated)
    event.unregister(tes3.event.attack,              mechanics.spellbatting.onAttack)
    event.unregister("projectileExpire",             mechanics.spellbatting.onProjectileExpire)

    event.unregister(tes3.event.simulate,            onSimulate_slow)
    event.unregister(tes3.event.mobileActivated,     onMobileActivated)
    event.unregister(tes3.event.mobileDeactivated,   onMobileDeactivated)
    event.unregister(tes3.event.equip,               onEquip)
    event.unregister("unequipped",                   onUnequip)
    event.unregister(tes3.event.attackStart,         onAttackStart_momentum)

    npcDodge.shutdown()
    resetState()

    if config.enabled then initialized() end
end

event.register(tes3.event.loaded, deactivate)
event.register(tes3.event.loaded, resetState)
event.register(tes3.event.loaded, function()
    if config.momentum_enabled then gmst.apply() end
end)
event.register(tes3.event.initialized, initialized)
event.register("stormatronach:modActivation", modActivation)
require("StormAtronach.TT.mcm")