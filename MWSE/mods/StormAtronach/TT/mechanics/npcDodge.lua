-- npcDodge.lua — NPC visual reactions to missed player attacks
--
-- When the player swings at an NPC and misses, this module intercepts calcHitChance,
-- re-rolls the hit/miss decision, and plays a short reactive animation on the NPC:
--   • Dodge left / dodge right (directional, based on where the player stands relative
--     to the NPC's facing direction).
--   • Weapon parry or weapon block pose (50 % chance when npc_react_use_weapon_anims is on).
--
-- Animation approach — direct drive:
--   • Clone the "Bip01 Pelvis" subtree from the NIF to get a controllers list.
--   • Wire each controller directly to the matching live bone on the NPC's scene node,
--     filtering out any bones in BLEND_EXCLUDE or under a BLEND_SUBTREE_EXCLUDE root.
--   • Each frame: drive all wired controllers to the current animation time.
--   • On completion: deactivate and detach all controllers.
--
-- BLEND_EXCLUDE: individual bones skipped during wiring.
-- BLEND_SUBTREE_EXCLUDE: bones whose entire descendant subtrees are skipped.
--
-- Why priority -200: runs after main mod's hit-chance multiplier at -100.
-- The roll is re-performed here so TT owns the final hit/miss decision.

local nifAnim = require("StormAtronach.TT.lib.nifAnim")
local config  = require("StormAtronach.TT.config")
local sounds  = require("StormAtronach.TT.lib.sounds")
local log     = mwse.Logger.new({ moduleName = "npcDodge" })

local this = {}

-- ── Animation source paths ────────────────────────────────────────────────────

local animPaths = {
    dodgeLeft  = "sa\\dodgingL.nif",
    dodgeRight = "sa\\dodgingR.nif",
    block      = "sa\\Block.nif",
    parry      = "sa\\BlockingWeapon.nif",
}

-- ── Bone exclusion lists ──────────────────────────────────────────────────────

-- Individual bones not wired to the NPC; their controllers are discarded.
local BLEND_EXCLUDE = {
    -- ["Bip01"] = true,  -- character root: position/orientation owned by engine
}

-- Subtree roots: the named bone AND all its descendants are excluded.
-- Expanded into a flat skip set once per animation (buildSkipSet).
local BLEND_SUBTREE_EXCLUDE = {
    ["Bip01 R Clavicle"] = true,  -- right arm/hand/weapon — driven by combat engine
}

-- Build a flat name→true set for every bone that is a descendant of a
-- BLEND_SUBTREE_EXCLUDE root inside `phantom`.
local function buildSkipSet(phantom)
    local skipSet = {}
    for node in table.traverse({ phantom }) do
        if node.name and BLEND_SUBTREE_EXCLUDE[node.name] then
            for desc in table.traverse({ node }) do
                if desc.name then skipSet[desc.name] = true end
            end
        end
    end
    return skipSet
end

-- ── Active animations ─────────────────────────────────────────────────────────

local activeAnimations = {}
local sparksObject = nil

-- ── Resolve ───────────────────────────────────────────────────────────────────

-- Load the NIF, clone the Bip01 Pelvis subtree, and wire each non-excluded
-- controller directly to the matching live bone on the NPC's scene node.
-- Returns: controllers (wired, active), startTime, duration.
-- Returns empty table on failure.
local function resolveAnim(ref, animPath)
    if not (ref.sceneNode and ref.sceneNode:getObjectByName("Bip01")) then
        log:debug("resolveAnim: no Bip01 on %s, skipping", ref.id)
        return {}, 0, 0
    end

    local controllers, highKeyFrame, phantom = nifAnim.loadControllers(animPath, "Bip01 Pelvis")
    if #controllers == 0 then
        log:warn("resolveAnim: no controllers in %s", animPath)
        return {}, 0, 0
    end

    local skipSet = buildSkipSet(phantom)

    -- Wire non-excluded controllers to NPC live bones; discard excluded ones.
    local wired = {}
    for _, entry in ipairs(controllers) do
        if not BLEND_EXCLUDE[entry.name] and not skipSet[entry.name] then
            local bone = ref.sceneNode:getObjectByName(entry.name)
            if bone then
                entry.controller:setTarget(bone)
                entry.controller.active = true
                table.insert(wired, entry)
            end
        end
    end

    local duration = math.min(highKeyFrame > 0 and highKeyFrame or 0.5, 0.5)
    log:debug("resolveAnim: wired %d/%d controllers, duration=%.4f", #wired, #controllers, duration)
    return wired, 0, duration
end

-- ── Per-frame simulate loop ────────────────────────────────────────────────────

local function rotFP(node) return node and node.rotation and node.rotation.x.x or 0 end

local function simulateAnim()
    for ref, animList in pairs(activeAnimations) do
        for i = #animList, 1, -1 do
            local anim = animList[i]
            -- Guard: NPC deactivated between frames
            if not ref.mobile then
                nifAnim.setActive(anim.controllers, false)
                nifAnim.detach(anim.controllers)
                table.remove(animList, i)
            else
                anim.timer = anim.timer + tes3.worldController.deltaTime
                local elapsed = math.min(anim.timer, anim.duration)
                local t       = anim.startTime + elapsed

                -- Diagnostic: log rotation fingerprints for first 3 frames
                local dbg = (anim.logFrame or 0) < 3
                if dbg then
                    local probes = { "Bip01 Pelvis", "Bip01 Spine1", "Bip01 L Thigh" }
                    for _, name in ipairs(probes) do
                        local nb = ref.sceneNode:getObjectByName(name)
                        log:debug("PRE  t=%.3f  %-20s  npc.rot00=%.4f", t, name, rotFP(nb))
                    end
                end

                -- Drive wired controllers directly onto NPC live bones.
                nifAnim.update(anim.controllers, t)

                if dbg then
                    local probes = { "Bip01 Pelvis", "Bip01 Spine1", "Bip01 L Thigh" }
                    for _, name in ipairs(probes) do
                        local nb = ref.sceneNode:getObjectByName(name)
                        log:debug("POST t=%.3f  %-20s  npc.rot00=%.4f", t, name, rotFP(nb))
                    end
                    anim.logFrame = (anim.logFrame or 0) + 1
                end

                if anim.timer >= anim.duration then
                    nifAnim.setActive(anim.controllers, false)
                    nifAnim.detach(anim.controllers)
                    table.remove(animList, i)
                end
            end
        end
        if #animList == 0 then
            activeAnimations[ref] = nil
        end
    end
    if next(activeAnimations) == nil then
        event.unregister("simulated", simulateAnim)
    end
end

-- ── Play ───────────────────────────────────────────────────────────────────────

local function playAnim(ref, animPath)
    local controllers, startTime, duration = resolveAnim(ref, animPath)
    if #controllers == 0 then
        log:warn("playAnim: no wired controllers for %s on %s, skipping", animPath, ref.id)
        return
    end
    log:debug("playAnim: %s on %s (start=%.4f dur=%.4f)", animPath, ref.id, startTime, duration)

    -- Dedup: skip if this NIF is already playing on this actor
    local animList = activeAnimations[ref]
    if animList then
        for _, instance in ipairs(animList) do
            if instance.animPath == animPath then return end
        end
    else
        activeAnimations[ref] = {}
        animList = activeAnimations[ref]
    end

    table.insert(animList, {
        controllers = controllers,
        animPath    = animPath,
        timer       = 0,
        startTime   = startTime,
        duration    = duration,
    })

    if not event.isRegistered("simulated", simulateAnim) then
        event.register("simulated", simulateAnim, { priority = -10000, unregisterOnLoad = true })
    end
end

-- ── calcHitChance handler ─────────────────────────────────────────────────────

--- @param e calcHitChanceEventData
local function dodgeOrHit(e)
    if not config.npc_dodge_enabled then return end
    if e.attacker ~= tes3.player then return end
    if not (e.target and e.targetMobile and e.targetMobile.canMove) then return end

    local roll  = math.random(1, 100)
    local isHit = roll <= e.hitChance
    log:debug("dodgeOrHit: target=%s hitChance=%d roll=%d → %s",
        e.target.id, e.hitChance, roll, isHit and "HIT" or "MISS")

    if isHit then
        e.hitChance = 100
        return
    end

    e.hitChance = 0
    local direction = tes3.mobilePlayer:getViewToActor(e.targetMobile)
    local goLeft
    if direction == nil then
        goLeft = math.random(2) == 1
    else
        goLeft = direction >= 0
    end
    local dodgeMesh = goLeft and animPaths.dodgeLeft or animPaths.dodgeRight
    log:debug("dodgeOrHit: direction=%s goLeft=%s", tostring(direction), tostring(goLeft))

    if config.npc_react_use_weapon_anims and math.random(1, 2) == 1 then
        local reactionMesh = goLeft and animPaths.parry or animPaths.block
        log:debug("dodgeOrHit: weapon reaction — %s", reactionMesh)
        playAnim(e.target, reactionMesh)
        if sparksObject and e.attackerMobile and e.targetMobile then
            local a   = e.attackerMobile
            local t   = e.targetMobile
            local mid = (e.attacker.position + tes3vector3.new(0, 0, a.height * 0.9)
                       + e.target.position   + tes3vector3.new(0, 0, t.height * 0.9)) / 2
            tes3.createVisualEffect{ object = sparksObject, repeatCount = 1, position = mid }
        end
        sounds.playRandom("parry", e.target, 1)
    else
        log:debug("dodgeOrHit: dodge — %s", dodgeMesh)
        playAnim(e.target, dodgeMesh)
    end
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

function this.init()
    sparksObject = tes3.createObject{
        objectType  = tes3.objectType.static,
        id          = "sa_VFX_NPCReact",
        mesh        = "sa\\spark.nif",
        getIfExists = true,
    }
    event.register(tes3.event.calcHitChance, dodgeOrHit, { priority = -200 })
end

function this.shutdown()
    event.unregister(tes3.event.calcHitChance, dodgeOrHit)
    event.unregister("simulated", simulateAnim)
    activeAnimations = {}
end

return this
