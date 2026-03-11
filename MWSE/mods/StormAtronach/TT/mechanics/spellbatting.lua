-- spellbatting.lua — Spell projectile reflection for Take That!
--
-- Three reflection paths:
--   1. Player bat (activateBatting): scans incomingProjectiles for the closest
--      spell within bat_range and reflects it immediately on a full-power swing.
--   2. NPC organic bat (onAttack): any non-player actor that swings naturally while
--      a spell is nearby has a configurable chance to reflect it.
--   3. NPC scheduled bat (npcBatCallback): when the player fires a spell, a raycast
--      finds the likely target NPC; a timer fires when the spell would arrive and
--      forces a weapon attack + reflection if the NPC passes the chance roll.
--
-- Safe handles:
--   All stored references to tes3mobileSpellProjectile use tes3.makeSafeObjectHandle()
--   because projectiles can be freed by the engine between the frame they are tracked
--   and the frame (or timer callback) where they are accessed.
--
-- Guard table (processedReflections):
--   Ensures VFX, sound, and chain-scheduling fire only once per projectile, even if
--   multiple bat paths reach handleReflection() in the same frame.

local public = {}

local common = require("StormAtronach.TT.lib.common")
local config = require("StormAtronach.TT.config")
local log = mwse.Logger.new({ moduleName = "spellbat" })

-- Guard table: ensures reflection VFX and chain-scheduling fire only once per projectile.
local processedReflections = {}

-- Tracks all spell projectiles while in flight, for player batting and chain reflection.
-- Populated by onMobileActivated; cleared on expire or on successful player bat.
local incomingProjectiles = {}

-- The Colour of Magic already attaches sa_trail to projectiles; skip our VFX if it's active.
local tcomActive = tes3.isLuaModActive("sa.tcom")

-- Reflects a projectile by setting impulseVelocity (which is additive with the engine's own
-- velocity each frame). Supplying 2× the desired direction cancels the engine's contribution
-- (-V) and nets to the reflected direction (+V). Returns the reflected velocity vector.
-- Also pushes the projectile back along its incoming direction so that the velocity reversal
-- takes effect before the engine can register a collision on the next frame.
local function reflectProjectile(mob)
    local vel = mob.velocity
    local speed = vel:length()
    if speed > 0 then
        mob.reference.position = mob.position - vel * (50 / speed)
    end
    mob.impulseVelocity = vel * -2
    return vel * -1
end

-- Forward declaration so spellBatting (below) and npcBatCallback can reference it
-- before the full definition appears after scheduleNpcBat.
local handleReflection

-- ── Player Spell Batting ──────────────────────────────────────────────────────

-- Window of opportunity: scans incoming projectiles for the closest one within config.bat_range
-- and reflects it directly, without requiring any magic status effect on the player.
local function spellBatting()
    local playerPos = tes3.player.position
    local closestRef, closestMob, closestDist = nil, nil, config.bat_range
    for ref, handle in pairs(incomingProjectiles) do
        if handle:valid() then
            local mob = handle:getObject()
            local dist = mob.position:distance(playerPos)
            if dist < closestDist then
                closestRef, closestMob, closestDist = ref, mob, dist
            end
        end
    end
    if not closestMob then return end
    local reflectedVel = reflectProjectile(closestMob)
    handleReflection(closestMob, reflectedVel)
    if closestRef then incomingProjectiles[closestRef] = nil end
    local spellName = closestMob.spellInstance and closestMob.spellInstance.source.name or "?"
    log:debug("Player batted '%s' (fired by %s) at range %.0f",
        spellName,
        closestMob.firingReference and closestMob.firingReference.id or "?",
        closestDist)
end

function public.activateBatting()
    local playerWeapon   = tes3.mobilePlayer.readiedWeapon
    local weaponType     = playerWeapon and playerWeapon.object.type or nil
    local areYouGoodEnough = common.weaponSkillCheck({
        thisMobileActor    = tes3.mobilePlayer,
        weapon             = weaponType,
        valueToCheckAgainst = config.bat_min_skill,
    })
    -- Note to self: Yes, it would be great to have different weapon attack times and such for
    -- timing this properly. Alas, that's too much work, and probably does not add to the fun.
    if tes3.mobilePlayer.actionData.attackSwing == 1 and areYouGoodEnough.check then
        spellBatting()
    end
end

-- ── NPC Spell Batting ─────────────────────────────────────────────────────────

-- Shared callback: reflects the tracked projectile when the bat window opens.
local function npcBatCallback(mobHandle, targetHandle, label)
    return function()
        if not targetHandle:valid() then return end
        local targetRef = targetHandle:getObject()
        if not targetRef.mobile then return end
        if not mobHandle:valid() then return end
        local mob = mobHandle:getObject()
        if math.random(100) > config.npc_spellbat_chance then
            log:debug("%s: chance failed for %s", label, targetRef.id)
            return
        end
        if targetRef.object.objectType ~= tes3.objectType.npc then return end
        if not targetRef.mobile.canAct then return end
        targetRef.mobile:forceWeaponAttack()
        local reflectedVel = reflectProjectile(mob)
        handleReflection(mob, reflectedVel, targetRef.mobile)
        local spellName = mob.spellInstance and mob.spellInstance.source.name or "?"
        log:debug("NPC %s batted '%s' (%s)", targetRef.id, spellName, label)
    end
end

-- Shared raycast + schedule logic. direction should already be normalised.
local function scheduleNpcBat(mob, direction, label)
    local speed = mob.velocity and mob.velocity:length() or 0
    if speed <= 0 then return end
    local hit = tes3.rayTest({
        position    = mob.position,
        direction   = direction,
        maxDistance = 5000,
        ignore      = { tes3.player },
    })
    if not (hit and hit.reference and hit.reference.mobile
            and hit.reference ~= tes3.player) then return end
    local targetRef = hit.reference
    local distance  = hit.intersection:distance(mob.position)
    local eta       = distance / speed
    log:debug("%s: %s speed=%.0f dist=%.0f eta=%.2fs",
        label, targetRef.id, speed, distance, eta)
    timer.start({
        duration = math.max(0.05, eta),
        type     = timer.simulate,
        callback = npcBatCallback(tes3.makeSafeObjectHandle(mob), tes3.makeSafeObjectHandle(targetRef), label),
    })
end

-- Registered on mobileActivated in main.lua.
-- Spell projectiles have no firingWeapon; skip arrows, bolts, thrown weapons.
-- All spell projectiles are tracked for player batting (enables chain reflection).
-- Player-fired spells additionally schedule an NPC bat window.
function public.onMobileActivated(e)
    local mob = e.mobile
    if mob.firingWeapon ~= nil then return end
    if not mob.spellInstance then
        log:trace("onMobileActivated: skipping %s (no spellInstance)", e.reference and e.reference.id or "?")
        return
    end
    log:trace("onMobileActivated: tracking spell '%s' fired by %s",
        mob.spellInstance.source.name,
        mob.firingReference and mob.firingReference.id or "?")
    incomingProjectiles[e.reference] = tes3.makeSafeObjectHandle(mob)
    if mob.firingReference == tes3.player and config.npc_spellbat_enabled then
        local speed = mob.velocity and mob.velocity:length() or 0
        if speed > 0 then
            scheduleNpcBat(mob, mob.velocity * (1 / speed), "NPC spellbat")
        end
    end
end

-- Registered on attack in main.lua.
-- When any non-player actor performs a natural weapon attack, scan incomingProjectiles
-- for the closest spell within bat_range and reflect it. This covers creatures (excluded
-- from forced-attack batting) and any NPC that swings at the right moment organically.
function public.onAttack(e)
    if not config.npc_spellbat_enabled then return end
    local attacker = e.mobile
    if not attacker or attacker == tes3.mobilePlayer then return end
    if math.random(100) > config.npc_spellbat_chance then return end
    local attackerPos = attacker.position
    local closestMob, closestRef, closestDist = nil, nil, config.bat_range
    for ref, handle in pairs(incomingProjectiles) do
        if handle:valid() then
            local mob = handle:getObject()
            local dist = mob.position:distance(attackerPos)
            if dist < closestDist then
                closestMob, closestRef, closestDist = mob, ref, dist
            end
        end
    end
    if not closestMob then return end
    if closestRef then incomingProjectiles[closestRef] = nil end
    local reflectedVel = reflectProjectile(closestMob)
    handleReflection(closestMob, reflectedVel, attacker)
    local spellName = closestMob.spellInstance and closestMob.spellInstance.source.name or "?"
    log:debug("%s naturally batted '%s' at range %.0f",
        e.reference and e.reference.id or "?", spellName, closestDist)
end

-- ── Reflected Spell Batting ───────────────────────────────────────────────

-- Core reflection handler. Called by all bat functions.
-- vel is the reflected velocity vector (already negated); falls back to mob.velocity.
-- reflector is the mobile that performed the bat; defaults to tes3.mobilePlayer.
handleReflection = function(mob, vel, reflector)
    if not (mob and mob.reference) then return end
    -- Process each projectile only once.
    if processedReflections[mob.reference] then return end
    processedReflections[mob.reference] = true
    -- Sparks at the reflection point
    tes3.createVisualEffect{ object = "AXE_sa_VFX_WSparks", repeatCount = 1, position = mob.position:copy() }
    tes3.playSound{ sound = "mysticism area", position = mob.position:copy() }
    -- Trail VFX on the reflected projectile (skip if TCoM is active — it handles sa_trail itself)
    if not tcomActive then
        local vfx = tes3.createVisualEffect({
            reference = mob.reference,
            object    = "sa_trail",
            lifespan  = 1,
        })
        if vfx then
            log:debug("Spellbat trail VFX attached to %s", mob.reference.id)
        end
    end
    mob.firingMobile = reflector or tes3.mobilePlayer

    if not config.npc_spellbat_enabled then return end
    local speed = vel and vel:length() or 0
    if speed <= 0 then return end
    scheduleNpcBat(mob, vel * (1 / speed), "Reflected spellbat")
end

function public.onProjectileExpire(e)
    local ref = e.mobile and e.mobile.reference
    if not ref then return end
    processedReflections[ref] = nil
    incomingProjectiles[ref]  = nil
end


return public
