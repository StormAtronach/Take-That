local block = {
    name     = "Block",
    active   = false,
    cooldown = false,   -- kept for resetCooldownsAndTables iteration compatibility
}

local nifAnim = require("StormAtronach.TT.lib.nifAnim")
local common  = require("StormAtronach.TT.lib.common")
local config  = require("StormAtronach.TT.config")
local log     = mwse.Logger.new({ moduleName = "block" })

-- ── Animation config ───────────────────────────────────────────────────────────

-- How quickly the block animation raises (per second) and snaps back on release.
-- Lower raise frequency = slower guard stance entry.
local raiseFrequency  = 2.0
local lowerFrequency  = 3.0  -- snap back faster than raise: feels responsive

-- Current animation position in [0, ceiling]; ceiling is the NIF's highKeyFrame.
local blockTime      = 0
local highTimeShield = 0.7  -- updated by loadControllers() from actual NIF data
local highTimeWeapon = 0.7

-- Transition tracking — only used for logging to avoid per-frame spam
local prevIsHeld = false
local prevActive = false

-- ── Controller sets ────────────────────────────────────────────────────────────
-- One record per loadout × perspective combination.
-- shield = shield equipped or bare-handed (no weapon, no shield)
-- weapon = weapon without shield
-- 1st/3rd = first-person or third-person camera perspective
--
-- Why "Bip01 Pelvis" as root (not "Bip01"): the block animations only affect the
-- upper body. Cloning from the pelvis subtree avoids capturing root-node translation
-- controllers that would interfere with character movement.
--
-- `controllers` and `highTime` are filled by loadControllers() and nil until then.
local sets = {
    shield1st = { mesh = "sa\\Block1st.nif",          controllers = nil, highTime = 0 },
    shield3rd  = { mesh = "sa\\Block.nif",             controllers = nil, highTime = 0 },
    weapon1st = { mesh = "sa\\BlockingWeapon1st.nif",  controllers = nil, highTime = 0 },
    weapon3rd  = { mesh = "sa\\BlockingWeapon.nif",    controllers = nil, highTime = 0 },
}

-- The controller set latched at the start of a block; never switched mid-block
-- so a shield→weapon change mid-guard doesn't cause a jarring animation pop.
local activeSet = nil

-- ── Private helpers ────────────────────────────────────────────────────────────

-- Load one set and wire controllers to the given scene node.
local function loadSet(s, sceneNode)
    local c, h = nifAnim.loadControllers(s.mesh, "Bip01 Pelvis")
    s.controllers = #c > 0 and c or nil
    s.highTime    = h
    if s.controllers then
        nifAnim.setTargets(s.controllers, sceneNode)
        nifAnim.setActive(s.controllers, false)
    else
        log:warn("No controllers — %s", s.mesh)
    end
end

-- ── Public API ─────────────────────────────────────────────────────────────────

-- (Re)load all four NIF controller sets and wire them to the current player nodes.
-- Must be called after every game load because player scene nodes are recreated.
function block.loadControllers()
    loadSet(sets.shield1st, tes3.player1stPerson.sceneNode)
    loadSet(sets.shield3rd,  tes3.player.sceneNode)
    loadSet(sets.weapon1st, tes3.player1stPerson.sceneNode)
    loadSet(sets.weapon3rd,  tes3.player.sceneNode)

    -- Cache the high-key times (used as the ceiling for blockTime)
    highTimeShield = math.max(sets.shield1st.highTime, sets.shield3rd.highTime)
    highTimeWeapon = math.max(sets.weapon1st.highTime, sets.weapon3rd.highTime)

    activeSet    = nil
    blockTime    = 0
    block.active = false

    log:debug("Block controllers loaded — shield1st:%d shield3rd:%d weapon1st:%d weapon3rd:%d",
        sets.shield1st.controllers and #sets.shield1st.controllers or 0,
        sets.shield3rd.controllers  and #sets.shield3rd.controllers  or 0,
        sets.weapon1st.controllers and #sets.weapon1st.controllers or 0,
        sets.weapon3rd.controllers  and #sets.weapon3rd.controllers  or 0)
end

-- Reset all block state. Nils controllers so loadControllers must follow.
-- Called from resetState on game load and MCM toggle.
function block.reset()
    for _, s in pairs(sets) do
        if s.controllers then
            nifAnim.setActive(s.controllers, false)
            s.controllers = nil
            s.highTime    = 0
        end
    end
    activeSet    = nil
    blockTime    = 0
    block.active = false
    -- Re-enable attack/magic in case we reset while block was raised
    local mp = tes3.mobilePlayer
    if mp then
        mp.attackDisabled = false
        mp.magicDisabled  = false
    end
end

-- Called on tes3.event.simulate: enforce attack + magic lock while block is raised.
-- Registered separately from onSimulated so it runs at normal priority.
function block.onSimulate()
    if block.active then
        local mp = tes3.mobilePlayer
        mp.attackDisabled = true
        mp.magicDisabled  = true
    end
end

-- Per-frame block driver. Registered on tes3.event.simulated (post-simulation)
-- so the bone transforms persist after the engine has finished its own update pass.
function block.onSimulated()
    if not sets.shield1st.controllers then return end

    local wc = tes3.worldController
    local mp = tes3.mobilePlayer

    -- ── Key poll ──────────────────────────────────────────────────────────────
    -- Poll block key every frame (keyboard or configured mouse button).
    local isHeld = false
    if config.hotkey.keyCode then
        isHeld = wc.inputController:isKeyDown(config.hotkey.keyCode)
    elseif config.hotkey.mouseButton ~= nil then
        isHeld = wc.inputController:isMouseButtonDown(config.hotkey.mouseButton)
    end
    -- Cannot raise block while in a menu
    if isHeld and tes3.menuMode() then isHeld = false end

    if isHeld ~= prevIsHeld then
        log:debug("Block key: %s (attacking=%s menuMode=%s)",
            isHeld and "HELD" or "released",
            tostring(mp.isAttackingOrCasting), tostring(tes3.menuMode()))
        prevIsHeld = isHeld
    end

    -- ── Controller selection ───────────────────────────────────────────────────
    -- Shield animation when: shield equipped, or bare-handed (no weapon, no shield).
    -- This uses the same animation for "proper" shield blocking and unarmed deflection.
    local hasShield    = mp.readiedShield ~= nil
    local hasWeapon    = mp.readiedWeapon ~= nil
    local useShieldAnim = hasShield or (not hasWeapon)
    local key = (useShieldAnim and "shield" or "weapon") .. (tes3.is3rdPerson() and "3rd" or "1st")
    local chosen = sets[key]

    -- ── Animation time ────────────────────────────────────────────────────────
    local ceiling = useShieldAnim and highTimeShield or highTimeWeapon
    if isHeld then
        blockTime = math.min(blockTime + wc.deltaTime * raiseFrequency, ceiling)
    else
        blockTime = math.max(blockTime - wc.deltaTime * lowerFrequency, 0)
    end
    block.active = blockTime > 0

    if block.active ~= prevActive then
        log:debug("Block %s (blockTime=%.3f 3rdPerson=%s hasShield=%s)",
            block.active and "RAISED" or "LOWERED", blockTime,
            tostring(tes3.is3rdPerson()), tostring(hasShield))
        prevActive = block.active
    end

    if not block.active then
        -- Snap bones back to rest before releasing so the next block starts clean
        if activeSet then
            nifAnim.reset(activeSet.controllers)
            activeSet = nil
        end
        mp.attackDisabled = false
        mp.magicDisabled  = false
        return
    end

    -- Latch the controller set at the start of a new block; never switch mid-block.
    -- Why: switching sets mid-animation would briefly show bones in two states.
    if not activeSet then
        activeSet = chosen
    end

    -- Update BEFORE activating: positions bones at the correct time, then the engine
    -- takes over. Matches the livecoding pattern — prevents the engine from
    -- auto-driving at absolute game time on the first frame.
    if activeSet and activeSet.controllers then
        nifAnim.update(activeSet.controllers, blockTime)
        nifAnim.setActive(activeSet.controllers, true)
    end

    -- Drain fatigue while blocking (configurable rate per second)
    if config.block_fatigue_cost > 0 then
        mp.fatigue.current = math.max(0, mp.fatigue.current - config.block_fatigue_cost * wc.deltaTime)
    end
end

-- ── Damage handler ─────────────────────────────────────────────────────────────

--- @param e damageEventData
function block.onDamage(e)
    -- Only handle physical attack damage to the player
    if e.source ~= tes3.damageSource.attack then return end
    if e.reference ~= tes3.player then return end

    local originalDamage = e.damage
    log:trace("onDamage: original damage %s", originalDamage)

    local reductionFactor = 0
    local oneHanded = false
    local weapon    = nil

    if not block.active then return end

    local doYouHaveShield = tes3.mobilePlayer.readiedShield ~= nil
    local doYouHaveWeapon = tes3.mobilePlayer.readiedWeapon ~= nil
    log:trace("onDamage: shield=%s weapon=%s", tostring(doYouHaveShield), tostring(doYouHaveWeapon))

    if doYouHaveWeapon then
        weapon    = tes3.mobilePlayer.readiedWeapon ---@cast weapon tes3equipmentStack
        oneHanded = common.oneHandedWeaponTable[weapon.object.type]
        log:trace("onDamage: weapon oneHanded=%s", tostring(oneHanded))
    end

    -- ── Branch 1: Sword and board ─────────────────────────────────────────────
    if doYouHaveShield and oneHanded then
        local blockSkill = tes3.mobilePlayer:getSkillValue(tes3.skill.block)
        log:trace("onDamage: shield block, skill=%s", blockSkill)

        reductionFactor = math.clamp(config.block_shield_base_pc + config.block_shield_skill_mult * blockSkill, 0, 100)
        e.damage = math.floor(originalDamage * (1 - reductionFactor / 100))

        -- Transfer absorbed damage to the shield's condition
        local shield = tes3.mobilePlayer.readiedShield
        if shield and shield.itemData and shield.itemData.condition then
            shield.itemData.condition = math.max(0, math.ceil(
                shield.itemData.condition - originalDamage * reductionFactor / 100))
        end

        e.attacker:hitStun()
        local slowDownType = math.floor(blockSkill / 25)
        if slowDownType > 0 then
            common.slowActor(e.attackerReference, 2, math.min(slowDownType, 4))
        end

        tes3.playSound{ sound = "steamRIGHT" }
        tes3.mobilePlayer:exerciseSkill(tes3.skill.block, config.block_skill_gain)

        local VFXspark = tes3.getObject("AXE_sa_VFX_WSparks") --[[@as tes3static]]
        if VFXspark and e.attackerReference and e.attacker and e.mobile then
            local midPos = (e.attackerReference.position + tes3vector3.new(0, 0, e.attacker.height * 0.9)
                          + e.reference.position         + tes3vector3.new(0, 0, e.mobile.height  * 0.9)) / 2
            tes3.createVisualEffect{ object = VFXspark, repeatCount = 1, position = midPos }
        end

        if e.damage <= 0 then e.block = true end
        return
    end

    -- ── Branch 2: Weapon-only block (no shield, or two-handed weapon) ──────────
    if doYouHaveWeapon then
        local mySkillCheck = common.weaponSkillCheck({ thisMobileActor = tes3.mobilePlayer, weapon = weapon and weapon.object.type })
        local mySkill      = mySkillCheck.weaponSkill
        local blockSkill   = tes3.mobilePlayer:getSkillValue(tes3.skill.block)
        log:trace("onDamage: weapon block, weaponSkill=%s blockSkill=%s", mySkill, blockSkill)

        if config.block_skill_bonus_active then
            reductionFactor = math.clamp(config.block_shield_base_pc + config.block_weapon_skill_mult * mySkill + config.block_weapon_blockSkill_bonus * blockSkill, 0, 100)
        else
            reductionFactor = math.clamp(config.block_weapon_base_pc + config.block_weapon_skill_mult * mySkill, 0, 100)
        end

        e.damage = math.floor(originalDamage * (100 - reductionFactor) / 100)

        local readiedWeapon = tes3.mobilePlayer.readiedWeapon
        if readiedWeapon and readiedWeapon.itemData and readiedWeapon.itemData.condition then
            readiedWeapon.itemData.condition = math.max(0, math.ceil(
                readiedWeapon.itemData.condition - originalDamage * reductionFactor / 100))
        end

        -- Skill-tier outcome: higher skill → better counter-attack
        local skillLevel = math.clamp(math.floor(mySkill / 25), 0, 4)
        local outcome    = math.random(0, skillLevel)
        log:trace("onDamage: weapon block outcome=%d skillLevel=%d", outcome, skillLevel)
        if outcome == 0 then
            e.attacker:hitStun()
        elseif outcome == 1 then
            e.attacker:hitStun()
            common.slowActor(e.attackerReference, 2, 1)
        elseif outcome == 2 then
            e.attacker:hitStun()
            common.slowActor(e.attackerReference, 2, 2)
            e.attacker:applyDamage({ damage = originalDamage * 0.2, applyArmor = true })
        elseif outcome == 3 then
            e.attacker:hitStun({ knockDown = true })
            common.slowActor(e.attackerReference, 2, 3)
            e.attacker:applyDamage({ damage = originalDamage * 0.4, applyArmor = true })
        elseif outcome == 4 then
            e.attacker:hitStun({ knockDown = true })
            common.slowActor(e.attackerReference, 2, 4)
            e.attacker:applyDamage({ damage = originalDamage * 0.6, applyArmor = true })
        end

        tes3.playSound{ sound = "repair fail" }
        if config.block_skill_bonus_active then
            tes3.mobilePlayer:exerciseSkill(tes3.skill.block, config.block_skill_gain)
        else
            tes3.mobilePlayer:exerciseSkill(mySkillCheck.skillID, config.block_skill_gain)
        end

        local VFXspark = tes3.getObject("AXE_sa_VFX_WSparks") --[[@as tes3static]]
        if VFXspark and e.attackerReference and e.attacker and e.mobile then
            local midPos = (e.attackerReference.position + tes3vector3.new(0, 0, e.attacker.height * 0.9)
                          + e.reference.position         + tes3vector3.new(0, 0, e.mobile.height  * 0.9)) / 2
            tes3.createVisualEffect{ object = VFXspark, repeatCount = 1, position = midPos }
        end

        if e.damage <= 0 then e.block = true end
        return
    end

    -- ── Branch 3: Hand-to-hand (unarmed, no shield) ───────────────────────────
    if (not doYouHaveShield) and (not doYouHaveWeapon) then
        local kungFuSkill = tes3.mobilePlayer:getSkillValue(tes3.skill.handToHand)
        local kungFu      = math.clamp(math.floor(kungFuSkill / 25), 0, 4)
        local outcome     = math.random(0, kungFu)
        log:trace("onDamage: kung fu outcome=%d skill=%s", outcome, kungFuSkill)

        if outcome == 0 then
            e.attacker:hitStun()
        elseif outcome == 1 then
            e.attacker:hitStun()
            common.slowActor(e.attackerReference, 2, 1)
        elseif outcome == 2 then
            e.attacker:hitStun({ knockDown = true })
            common.slowActor(e.attackerReference, 2, 2)
            e.damage = e.damage * 0.5
        elseif outcome == 3 then
            tes3.applyMagicSource({
                reference = e.attackerReference,
                bypassResistances = true,
                effects = { { id = tes3.effect.paralyze, min = 100, max = 100, duration = 5 } },
                name = "Nerve attack",
            })
            e.damage = e.damage * 0.25
        elseif outcome == 4 then
            tes3.applyMagicSource({
                reference = e.attackerReference,
                bypassResistances = true,
                effects = {
                    { id = tes3.effect.paralyze, min = 100, max = 100, duration = 5 },
                    { id = tes3.effect.poison,   min = 20,  max = 20,  duration = 5 },
                },
                name = "Death touch",
            })
            e.damage = 0
        end

        tes3.playSound{ sound = "Spell Failure Alteration" }
        tes3.mobilePlayer:exerciseSkill(tes3.skill.handToHand, config.block_skill_gain)

        if e.damage <= 0 then e.block = true end
        return
    end
end

-- ── Keybind intercept ──────────────────────────────────────────────────────────

-- Suppress the use/attack keybind while blocking. keybindTested fires each time
-- the engine polls a keybind; blocking it makes the engine treat the key as not pressed,
-- preventing both weapon attacks and spellcasting while the guard is raised.
function block.onKeybindTested(e)
    if not block.active then return end
    if e.keybind == tes3.keybind.use or e.keybind == tes3.keybind.readyMagic then
        e.block = true
    end
end

return block
