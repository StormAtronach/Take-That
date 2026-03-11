-- dodge.lua — Player dodge mechanic for Take That!
--
-- Two triggers:
--   1. Double-tap the configured back key (default S) while weapon is drawn.
--   2. An NPC or creature begins attacking the player while the player holds the back key.
--
-- Both triggers call triggerDodge(), which:
--   • Starts a cooldown timer to prevent rapid re-triggering.
--   • Computes a dodge window duration from acrobatics skill + armour weight.
--   • Plays the dodge_back NIF animation (bones driven per-frame by onSimulate_dodgeAnim).
--   • Fires the custom "TT:dodgeTriggered" event so main.lua can call activate()
--     without dodge.lua needing a reference to that function.
--
-- Animation approach (same pattern as block.lua / npcDodge.lua, via nifAnim):
--   • Bip01 is cloned into a "phantom" node kept outside the scene graph.
--   • All other bone controllers target the live player scene node.
--   • Each frame: drive controllers to current time, read the phantom's XY translation
--     delta, and push that delta into movementRootNode to physically move the character.
--   • The translation is deferred by one frame (stored as pendingDx/pendingDy and
--     applied next frame) to eliminate a one-frame jitter caused by the controller
--     update and the node update happening in the same simulation tick.

local nifAnim = require("StormAtronach.TT.lib.nifAnim")
local config  = require("StormAtronach.TT.config")
local log     = mwse.Logger.new({ moduleName = "dodge" })

local dodge = {
    name     = "Dodge",
    cooldown = false,
    active   = false,
    window   = nil,
}

-- ── Debug toggles ─────────────────────────────────────────────────────────────
-- Set either flag true to test trigger logic without the corresponding side-effect.
local DEBUG_SKIP_ANIMATION   = false  -- skip NIF controller playback
local DEBUG_SKIP_TRANSLATION = false  -- skip movementRootNode writes

-- ── Animation database ────────────────────────────────────────────────────────
-- One record per dodge direction. Each record holds both the source NIF path and
-- the runtime controller state populated by loadControllers().
--
-- left/right NIFs are loaded now, ready for future directional dodge triggers.
-- Why "Bip01" as root (not "Bip01 Pelvis"): we clone the full skeleton so the
-- phantom captures the root XY translation for physical movement extraction.
local animations = {
    back  = { path = "sa\\dodge_back.nif",  controllers = {}, highTime = 0, phantom = nil },
    left  = { path = "sa\\dodge_left.nif",  controllers = {}, highTime = 0, phantom = nil },
    right = { path = "sa\\dodge_right.nif", controllers = {}, highTime = 0, phantom = nil },
}

-- Armor weight class → contribution to dodge window duration.
-- Unarmoured gets the largest bonus (most mobile); heavy armour gets none.
local armorBonus = {
    [tes3.armorWeightClass.light]  = 0.35,
    [tes3.armorWeightClass.medium] = 0.2,
    [tes3.armorWeightClass.heavy]  = 0,
}

-- ── Animation playback ────────────────────────────────────────────────────────

-- Holds the state for the currently playing dodge animation, or nil when idle.
-- Fields: controllers, phantom, highTime, time, prevX, prevY, pendingDx, pendingDy
local animState = nil

local function onSimulate_dodgeAnim()
    if not animState then
        event.unregister(tes3.event.simulated, onSimulate_dodgeAnim)
        return
    end

    animState.time = animState.time + tes3.worldController.deltaTime

    if animState.time >= animState.highTime then
        -- Animation complete: rewind bones and release controllers
        nifAnim.reset(animState.controllers)
        animState = nil
        event.unregister(tes3.event.simulated, onSimulate_dodgeAnim)
        return
    end

    -- Apply the translation delta computed last frame.
    -- Why deferred: computing AND applying in the same frame causes a one-tick jitter
    -- because the controller update and the scene-graph update happen in the same pass.
    -- Storing this frame's delta and applying it next frame smooths the movement out.
    if not DEBUG_SKIP_TRANSLATION then
        local pdx = animState.pendingDx
        local pdy = animState.pendingDy
        if pdx * pdx + pdy * pdy >= 1e-8 then
            local rootNode = tes3.is3rdPerson() and tes3.player or tes3.player1stPerson
            local mrt = rootNode.animationData and rootNode.animationData.movementRootNode
            if mrt then
                local t = mrt.translation
                t.x = t.x - pdx
                t.y = t.y - pdy
            end
        end
    end

    -- Drive all bone controllers to the current animation time.
    if not DEBUG_SKIP_ANIMATION then
        nifAnim.update(animState.controllers, animState.time)
    end

    -- Sample the phantom's new XY position and store the delta for next frame.
    -- The phantom is the cloned Bip01 subtree; its translation represents the
    -- root movement the NIF author baked into the animation.
    local phantom = animState.phantom
    local tx = phantom.translation.x --[[@as number]]
    local ty = phantom.translation.y --[[@as number]]
    animState.pendingDx = tx - animState.prevX
    animState.pendingDy = ty - animState.prevY
    animState.prevX     = tx
    animState.prevY     = ty
end

-- Stop any currently playing animation immediately (used on interruption and reset).
local function stopCurrentAnim()
    if not animState then return end
    nifAnim.reset(animState.controllers)
    animState = nil
    event.unregister(tes3.event.simulated, onSimulate_dodgeAnim)
end

-- Begin playing the animation for the given direction.
local function startDodgeAnim(dir)
    local anim = animations[dir]
    if not anim or #anim.controllers == 0 or not anim.phantom then
        log:warn("startDodgeAnim: no data for direction '%s'", dir)
        return
    end
    -- Cancel any animation already running (e.g. second trigger during cooldown window)
    stopCurrentAnim()

    nifAnim.setActive(anim.controllers, true)
    nifAnim.update(anim.controllers, 0)

    local pt = anim.phantom.translation --[[@as tes3vector3]]
    animState = {
        controllers = anim.controllers,
        phantom     = anim.phantom,
        highTime    = anim.highTime,
        time        = 0,
        prevX       = pt.x,
        prevY       = pt.y,
        pendingDx   = 0,
        pendingDy   = 0,
    }
    -- Use simulated (post-sim) so bone transforms persist after the engine's own pass
    event.register(tes3.event.simulated, onSimulate_dodgeAnim)
    log:debug("startDodgeAnim: %s (highTime=%.4f)", dir, anim.highTime)
end

-- ── Public: load / reset ───────────────────────────────────────────────────────

-- (Re)load all three directional NIFs and retarget their controllers onto the
-- current player scene node. Must be called after every game load because the
-- player scene node is recreated on load.
function dodge.loadControllers()
    local sceneNode = tes3.player and tes3.player.sceneNode
    if not sceneNode then
        log:warn("loadControllers: player sceneNode not available")
        return
    end
    for _, anim in pairs(animations) do
        local c, h, phantom = nifAnim.loadControllers(anim.path, "Bip01")
        anim.controllers = c
        anim.highTime    = h
        anim.phantom     = phantom
        if #c > 0 and phantom then
            -- Bip01 → phantom (for translation extraction); all others → live scene node
            nifAnim.setTargets(c, sceneNode, phantom)
            nifAnim.setActive(c, false)
        end
    end
end

-- Stop any active animation. Called on game load and mod toggle.
function dodge.reset()
    stopCurrentAnim()
end

-- ── Trigger logic ─────────────────────────────────────────────────────────────

local function triggerDodge()
    log:debug("triggerDodge: called (cooldown=%s)", tostring(dodge.cooldown))
    if dodge.cooldown then return end
    dodge.cooldown = true
    timer.start({
        duration = math.max(config.dodge_cool_down_time, 1),
        callback = function() dodge.cooldown = false end,
        type     = timer.simulate,
    })

    -- Dodge window: acrobatics tier (0–4) + armour class contribution
    -- Range: 0.1 s (heavy armour, novice acrobatics) → 1.0 s (unarmoured, master)
    local acrobaticsSkill        = tes3.mobilePlayer:getSkillValue(tes3.skill.acrobatics)
    local acrobaticsLevel        = math.clamp(math.floor(acrobaticsSkill / 25), 0, 4)
    local acrobaticsContribution = 0.1 + acrobaticsLevel / 10
    local chestItem = tes3.getEquippedItem({
        actor      = tes3.player,
        objectType = tes3.objectType.armor,
        slot       = tes3.armorSlot.cuirass,
    })
    local wc = chestItem and chestItem.object.weightClass
    local armorContribution = (wc and armorBonus[wc]) or 0.5  -- 0.5 = unarmoured bonus
    local dodgeDuration = math.max(0.1, math.min(acrobaticsContribution + armorContribution, 1))
    log:debug("triggerDodge: duration=%.2f (acrobatics=%.2f armor=%.2f)",
        dodgeDuration, acrobaticsContribution, armorContribution)

    startDodgeAnim("back")
    event.trigger("TT:dodgeTriggered", { duration = dodgeDuration })
end

-- ── Trigger 1: double-tap back key ────────────────────────────────────────────

-- Resolved in dodge.init() from the configured keybind
local backKeyCode = nil

-- Double-tap detection state
local lastBackPress   = nil
local doubleTapWindow = 0.3  -- seconds: maximum gap between two taps to count as a double-tap

local function onKeyDown_back(e)
    log:debug("onKeyDown_back: keyCode=%d backKeyCode=%s", e.keyCode, tostring(backKeyCode))
    if e.keyCode ~= backKeyCode then return end
    if tes3ui.menuMode() then return end
    if not tes3.mobilePlayer then return end
    if not tes3.mobilePlayer.weaponDrawn then return end

    local now = os.clock()
    if lastBackPress and (now - lastBackPress) < doubleTapWindow then
        log:debug("onKeyDown_back: double-tap confirmed (gap=%.3fs)", now - lastBackPress)
        lastBackPress = nil
        triggerDodge()
    else
        log:debug("onKeyDown_back: first tap recorded (t=%.3f)", now)
        lastBackPress = now
    end
end

-- ── Trigger 2: incoming attack while holding back ─────────────────────────────

-- Called from main.lua's onAttack handler when e.targetMobile == tes3.mobilePlayer.
-- Uses isKeyDown instead of listening to keyDown events because the back key may
-- already have been pressed and held before the attack event fires.
function dodge.onIncomingAttack()
    log:debug("onIncomingAttack: called (backKeyCode=%s)", tostring(backKeyCode))
    if not tes3.mobilePlayer then return end
    if not backKeyCode then return end
    local held = tes3.worldController.inputController:isKeyDown(backKeyCode)
    log:debug("onIncomingAttack: backKey held=%s", tostring(held))
    if not held then return end
    triggerDodge()
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

function dodge.init()
    local binding = tes3.getInputBinding(tes3.keybind.back)
    if not binding then
        log:warn("dodge.init: could not resolve back keybind")
        return
    end
    backKeyCode = binding.code
    log:debug("dodge.init: back key code=%d", backKeyCode)
    event.register(tes3.event.keyDown, onKeyDown_back)
end

function dodge.shutdown()
    dodge.reset()
    event.unregister(tes3.event.keyDown, onKeyDown_back)
end

return dodge
