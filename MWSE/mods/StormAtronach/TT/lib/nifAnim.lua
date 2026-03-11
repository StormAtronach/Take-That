-- nifAnim.lua — Shared NIF controller utilities for Take That!
--
-- All three animation modules (block, dodge, npcDodge) drive character animations by
-- cloning a bone subtree out of a loaded NIF, then retargeting each bone controller to
-- the matching live scene node on the target actor. This file consolidates that pattern
-- so each module no longer needs its own copy of the helpers.
--
-- Design notes:
--   • Controllers are collected by traversing the CLONED subtree (the "phantom") so the
--     originals inside the tes3.loadMesh cache are never mutated.
--   • setTargets() accepts an optional `phantom` node. When supplied, the "Bip01"
--     controller is aimed at the phantom rather than the live scene node. This is needed
--     by dodge.lua, which reads the phantom's XY translation each frame to derive the
--     physical movement delta. All other bones are still wired to the live scene graph.
--   • update() drives every controller individually. For block/npcDodge (no phantom)
--     only updating the root would suffice because child bones propagate automatically;
--     but for dodge (phantom root is outside the scene graph) we must update all targets
--     explicitly. Updating all is always correct and the per-frame cost is negligible.
local log = mwse.Logger.new({ moduleName = "nifAnim" })

-- Shared update params table — reused every frame to avoid GC pressure
local _updateParams = { controllers = true, time = 0 }

local nifAnim = {}

-- ── Load ───────────────────────────────────────────────────────────────────────

-- Clone the subtree rooted at `rootName` inside `meshPath` and harvest all bone
-- controllers from it. Returns:
--   controllers : array of { name = string, controller = niTimeController }
--   highKeyFrame: highest keyframe timestamp found across all controllers (seconds)
--   phantom     : the cloned root niNode (kept alive so controllers stay valid)
--
-- Returns an empty array and 0 on any failure; callers should check #controllers > 0.
function nifAnim.loadControllers(meshPath, rootName)
    local controllers = {}
    local highKeyFrame = 0
    local nif = tes3.loadMesh(meshPath)
    if not nif then
        log:warn("loadControllers: mesh not found — %s", meshPath)
        return controllers, 0, nil
    end
    local rootBone = nif:getObjectByName(rootName or "Bip01 Pelvis")
    if not rootBone then
        log:warn("loadControllers: bone '%s' not found in %s", rootName or "Bip01 Pelvis", meshPath)
        return controllers, 0, nil
    end
    local phantom = rootBone:clone()
    for node in table.traverse({ phantom }) do
        if node.controller then
            table.insert(controllers, { name = node.name, controller = node.controller })
            if node.controller.highKeyFrame and node.controller.highKeyFrame > highKeyFrame then
                highKeyFrame = node.controller.highKeyFrame
            end
        end
    end
    log:debug("loadControllers: %d controllers, highKeyFrame=%.4f — %s", #controllers, highKeyFrame, meshPath)
    return controllers, highKeyFrame, phantom
end

-- ── Target management ──────────────────────────────────────────────────────────

-- Wire each controller to the matching live node in `sceneNode` by name.
-- Exception: if `phantom` is provided and an entry is named "Bip01", that
-- controller is aimed at the phantom instead (for translation extraction).
-- Nodes missing from the scene graph are silently skipped.
function nifAnim.setTargets(controllers, sceneNode, phantom)
    for _, entry in ipairs(controllers) do
        if phantom and entry.name == "Bip01" then
            entry.controller:setTarget(phantom)
        else
            local node = sceneNode:getObjectByName(entry.name)
            if node then entry.controller:setTarget(node) end
        end
    end
end

-- Sever all controller → target links.
-- Called when an NPC is deactivated so controllers cannot write into a
-- freed or recycled scene node.
function nifAnim.detach(controllers)
    for _, entry in ipairs(controllers) do
        entry.controller:setTarget(nil)
    end
end

-- ── Activation ────────────────────────────────────────────────────────────────

-- Activate or deactivate every controller in the list.
-- Inactive controllers are not driven by the engine's own time; TT drives them
-- manually via update(). Active controllers let the engine drive them at absolute
-- game time — so we always call update() BEFORE setActive(true) to position the
-- bones first, then hand off control.
function nifAnim.setActive(controllers, state)
    for _, entry in ipairs(controllers) do
        entry.controller.active = state
    end
end

-- ── Update ─────────────────────────────────────────────────────────────────────

-- Drive all controllers to `time` by calling node:update() on every target.
-- Each update call propagates to the node's children automatically, but because
-- the phantom root is not attached to the scene graph, it must be updated through
-- its own controller target reference rather than through the root node walk.
function nifAnim.update(controllers, time)
    _updateParams.time = time
    for _, entry in ipairs(controllers) do
        if entry.controller.target then
            entry.controller.target:update(_updateParams)
        end
    end
end

-- Convenience: deactivate all controllers and rewind to time 0.
-- Used in every cleanup path (animation complete, interrupted, mod toggled).
function nifAnim.reset(controllers)
    nifAnim.setActive(controllers, false)
    nifAnim.update(controllers, 0)
end

-- ── Blending ───────────────────────────────────────────────────────────────────

-- Capture the current bone transforms into a snapshot table (the vanilla idle pose).
-- Must be called AFTER setTargets but BEFORE setActive so the snapshot reflects the
-- unmodified game pose, not a partially animated one.
-- Returns: { [boneName] = { t = tes3vector3, r = niQuaternion }, ... }
function nifAnim.captureSnapshot(controllers)
    local snap = {}
    for _, entry in ipairs(controllers) do
        local node = entry.controller.target
        if node then
            local q = niQuaternion.new(1, 0, 0, 0)
            q:fromRotation(node.rotation)
            snap[entry.name] = {
                t = tes3vector3.new(node.translation.x, node.translation.y, node.translation.z),
                r = q,
            }
        end
    end
    return snap
end

-- Lerp translations and slerp rotations from `snap` (vanilla pose) toward the
-- current controller-driven pose.
-- alphaR: rotation blend weight [0 = fully vanilla, 1 = fully animated]
-- alphaT: translation blend weight [0 = fully vanilla, 1 = fully animated]
function nifAnim.blendIn(controllers, snap, alphaR, alphaT, blendTranslation, blendRotation)
    -- Default both blend axes to true when not specified
    if blendTranslation == nil then blendTranslation = true end
    if blendRotation    == nil then blendRotation    = true end
    for _, entry in ipairs(controllers) do
        local node = entry.controller.target
        local s    = snap[entry.name]
        if node and s then
            if blendTranslation then
                local nt = node.translation
                node.translation = s.t + (nt - s.t) * alphaT
            end
            if blendRotation then
                local qCurrent = niQuaternion.new()
                qCurrent:fromRotation(node.rotation)
                local rResult = tes3matrix33.new()
                rResult:fromQuaternion(s.r:slerp(qCurrent, alphaR))
                node.rotation = rResult
            end
        end
    end
end

return nifAnim
