local config = require("StormAtronach.TT.config")
local sounds = require("StormAtronach.TT.sounds")
local log = mwse.Logger.new({ moduleName = "npcDodge" })

local this = {}

local anims = {
    dodgeLeft  = "sa\\dodgingL.nif",
    dodgeRight = "sa\\dodgingR.nif",
    block      = "sa\\Block.nif",
    parry      = "sa\\BlockingWeapon.nif",
}

-- activeAnimations is keyed by tes3reference (unique per actor, no ID collisions)
local activeAnimations = {}
local sparksObject = nil

-- Controller utility: loads, retargets, drives NIF controllers without tes3.playAnimation
local CU = {}

function CU.loadControllers(meshPath, rootName)
    local controllers = {}
    local nif = tes3.loadMesh(meshPath)
    if not nif then
        log:warn("CU.loadControllers: mesh not found — %s", meshPath)
        return controllers
    end
    local pelvis = nif:getObjectByName(rootName or "Bip01 Pelvis")
    if not pelvis then
        log:warn("CU.loadControllers: root bone not found in %s", meshPath)
        return controllers
    end
    local root = pelvis:clone()
    for node in table.traverse({root}) do
        if node.controller then
            table.insert(controllers, { name = node.name, controller = node.controller })
        end
    end
    log:debug("CU.loadControllers: %d controllers from %s", #controllers, meshPath)
    return controllers
end

function CU.setTarget(controllers, ref)
    local root = ref.sceneNode
    for _, entry in pairs(controllers) do
        entry.controller:setTarget(root:getObjectByName(entry.name))
    end
end

function CU.setActive(controllers, state)
    for _, entry in pairs(controllers) do
        entry.controller.active = state
    end
end

function CU.detach(controllers)
    for _, entry in pairs(controllers) do
        entry.controller:setTarget(nil)
    end
end

function CU.updateControllers(controllers, time)
    for _, entry in pairs(controllers) do
        local c = entry.controller
        if c.target then
            c.target:update({ controllers = true, time = time })
        end
    end
end

-- Runs every simulate frame while animations are active; self-unregisters when done
local function simulateAnim()
    for ref, animList in pairs(activeAnimations) do
        for i = #animList, 1, -1 do
            local anim = animList[i]
            -- Guard: NPC may have been deactivated between frames
            if not ref.mobile then
                CU.detach(anim.controllers)
                table.remove(animList, i)
            else
                anim.timer = anim.timer + tes3.worldController.deltaTime
                CU.updateControllers(anim.controllers, math.min(anim.timer, anim.highKeyFrame))
                if anim.timer >= anim.highKeyFrame then
                    CU.setActive(anim.controllers, false)
                    CU.detach(anim.controllers)
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

local function playAnim(ref, animPath)
    local controllers = CU.loadControllers(animPath)
    if #controllers == 0 then
        log:warn("playAnim: no controllers for %s, skipping", animPath)
        return
    end
    log:debug("playAnim: %s on %s", animPath, ref.id)

    -- Dedup check before retargeting to avoid orphaned scene-node references
    local animList = activeAnimations[ref]
    if animList then
        for _, instance in ipairs(animList) do
            if instance.animPath == animPath then return end
        end
    else
        activeAnimations[ref] = {}
        animList = activeAnimations[ref]
    end

    CU.setTarget(controllers, ref)
    CU.setActive(controllers, true)  -- set once here; only cleared on cleanup

    table.insert(animList, {
        controllers  = controllers,
        animPath     = animPath,
        timer        = 0,
        highKeyFrame = 0.5,
    })

    if not event.isRegistered("simulated", simulateAnim) then
        event.register("simulated", simulateAnim, { priority = -10000, unregisterOnLoad = true })
    end
end

--- Intercepts calcHitChance: on a miss, plays a reaction animation on the NPC.
--- Hit/miss probability is preserved (same roll the engine would make).
--- Priority -200 ensures this runs after the main mod's hit-chance multiplier (-100).
--- @param e calcHitChanceEventData
local function dodgeOrHit(e)
    if not config.npc_dodge_enabled then return end
    if e.attacker ~= tes3.player then return end
    if not (e.target and e.targetMobile and e.targetMobile.canMove) then return end

    local roll = math.random(1, 100)
    local isHit = roll <= e.hitChance
    log:debug("dodgeOrHit: target=%s hitChance=%d roll=%d → %s",
        e.target.id, e.hitChance, roll, isHit and "HIT" or "MISS")
    if isHit then
        e.hitChance = 100
        return
    end

    -- Miss: pick a reaction based on which side the target sees the player
    e.hitChance = 0
    local direction = tes3.mobilePlayer:getViewToActor(e.targetMobile)
    local goLeft = (direction == nil) and (math.random(1, 2) == 1) or (direction >= 0)
    local dodgeMesh = goLeft and anims.dodgeLeft or anims.dodgeRight
    log:debug("dodgeOrHit: direction=%s goLeft=%s", tostring(direction), tostring(goLeft))

    if config.npc_react_use_weapon_anims and math.random(1, 2) == 1 then
        local reactionMesh = goLeft and anims.parry or anims.block
        log:debug("dodgeOrHit: weapon reaction — %s", reactionMesh)
        playAnim(e.target, reactionMesh)
        if sparksObject then
            local a = e.attackerMobile
            local t = e.targetMobile
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
