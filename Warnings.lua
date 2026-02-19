-- SustainMonitor: Warning System - Distinct Alerts, Potion Tracking, Heavy Attack
SustainMonitor = SustainMonitor or {}
local SM = SustainMonitor

---------------------------------------------------------------------------
-- Warning Levels
---------------------------------------------------------------------------
local WARNING_NONE   = 0
local WARNING_YELLOW = 1
local WARNING_ORANGE = 2
local WARNING_RED    = 3

---------------------------------------------------------------------------
-- Sound helpers (read from saved vars, fallback to defaults)
---------------------------------------------------------------------------
local function GetSoundWarning()
    local sv = SM.savedVars
    local key = sv and sv.soundWarning or "GENERAL_ALERT_ERROR"
    return SOUNDS[key] or SOUNDS.GENERAL_ALERT_ERROR
end

local function GetSoundHeavyAttack()
    local sv = SM.savedVars
    local key = sv and sv.soundHeavyAttack or "CHAMPION_POINT_GAINED"
    return SOUNDS[key] or SOUNDS.CHAMPION_POINT_GAINED
end

local function GetSoundPotionReady()
    local sv = SM.savedVars
    local key = sv and sv.soundPotionReady or "QUEST_COMPLETED"
    return SOUNDS[key] or SOUNDS.QUEST_COMPLETED
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local lastWarningLevel   = {}
local flashActive        = {}
local flashTimers        = {}
local flashState         = {}
local FLASH_INTERVAL_MS  = 250

-- Potion state
local potionCooldownEnd  = 0
local potionCooldownDur  = 0
local potionIsOnCooldown = false
local potionWasOnCooldown = false

-- Heavy Attack state
local lastHASuggestionTime = 0
local HA_COOLDOWN_MS       = 3000   -- 3s cooldown (was 5s, too slow for fast drain)

---------------------------------------------------------------------------
-- Debug helper
---------------------------------------------------------------------------
local function Debug(msg)
    local sv = SM.savedVars
    if sv and sv.debugMode then
        d("|c999999[SM Debug]|r " .. tostring(msg))
    end
end

---------------------------------------------------------------------------
-- Initialization
---------------------------------------------------------------------------
function SM.InitWarnings()
    lastWarningLevel    = {}
    flashActive         = {}
    flashTimers         = {}
    flashState          = {}
    potionCooldownEnd   = 0
    potionCooldownDur   = 0
    potionIsOnCooldown  = false
    potionWasOnCooldown = false
    lastHASuggestionTime = 0

    -- On init, check if potion is already on cooldown
    SM.PollPotionCooldown()
end

---------------------------------------------------------------------------
-- Get warning level
---------------------------------------------------------------------------
function SM.GetWarningLevel(timeToEmpty, burnRate)
    if burnRate >= 0 then return WARNING_NONE end
    if timeToEmpty < 0 then return WARNING_NONE end

    local sv = SM.savedVars
    if not sv or not sv.warningEnabled then return WARNING_NONE end

    if timeToEmpty < sv.warningThreshold3 then
        return WARNING_RED
    elseif timeToEmpty < sv.warningThreshold2 then
        return WARNING_ORANGE
    elseif timeToEmpty < sv.warningThreshold1 then
        return WARNING_YELLOW
    end

    return WARNING_NONE
end

---------------------------------------------------------------------------
-- Check warnings per resource
---------------------------------------------------------------------------
function SM.CheckWarnings(powerType)
    local sv = SM.savedVars
    if not sv or not sv.warningEnabled then return end

    local res = SM.GetResourceData(powerType)
    if not res then return end

    local level = SM.GetWarningLevel(res.timeToEmpty, res.burnRate)
    local prevLevel = lastWarningLevel[powerType] or WARNING_NONE

    if sv.warningSound and level >= WARNING_ORANGE and level > prevLevel then
        PlaySound(GetSoundWarning())
        Debug("Resource warning lvl " .. level .. " for powerType " .. tostring(powerType))
    end

    if sv.warningFlash then
        if level >= WARNING_RED then
            if not flashActive[powerType] then
                flashActive[powerType] = true
                flashTimers[powerType] = GetGameTimeMilliseconds()
                flashState[powerType]  = true
            end
        else
            if flashActive[powerType] then
                flashActive[powerType] = false
                SM.SetRowAlpha(powerType, 1)
            end
        end
    end

    lastWarningLevel[powerType] = level
end

---------------------------------------------------------------------------
-- Flash update
---------------------------------------------------------------------------
function SM.UpdateFlash()
    local sv = SM.savedVars
    if not sv or not sv.warningFlash then return end

    local now = GetGameTimeMilliseconds()
    for powerType, active in pairs(flashActive) do
        if active then
            local lastToggle = flashTimers[powerType] or 0
            if now - lastToggle >= FLASH_INTERVAL_MS then
                flashState[powerType] = not flashState[powerType]
                flashTimers[powerType] = now
                SM.SetRowAlpha(powerType, flashState[powerType] and 1 or 0.2)
            end
        end
    end
end

--- Set row alpha via stored control reference (no GetControlByName needed)
function SM.SetRowAlpha(powerType, alpha)
    if SM.GetRowControl then
        local rowCtrl = SM.GetRowControl(powerType)
        if rowCtrl then rowCtrl:SetAlpha(alpha) end
    end
end

---------------------------------------------------------------------------
-- Potion cooldown: POLLING approach (reliable fallback)
---------------------------------------------------------------------------
function SM.PollPotionCooldown()
    local slotIndex = GetCurrentQuickslot()
    if not slotIndex then return end

    -- Try with HOTBAR_CATEGORY_QUICKSLOT_WHEEL first (post-High Isle)
    local ok, remain, duration, global
    if HOTBAR_CATEGORY_QUICKSLOT_WHEEL then
        ok, remain, duration, global = pcall(GetSlotCooldownInfo, slotIndex, HOTBAR_CATEGORY_QUICKSLOT_WHEEL)
    end
    if not ok or not remain then
        -- Fallback without second parameter (older API)
        ok, remain, duration, global = pcall(GetSlotCooldownInfo, slotIndex)
    end

    if ok and remain and remain > 0 and not global then
        potionCooldownEnd = GetGameTimeMilliseconds() + remain
        potionCooldownDur = duration or remain
        potionIsOnCooldown = true
        Debug("Potion poll: on CD, " .. remain .. "ms remaining")
    elseif ok and remain and remain <= 0 then
        if potionIsOnCooldown then
            potionIsOnCooldown = false
            Debug("Potion poll: CD ended")
        end
    end
end

---------------------------------------------------------------------------
-- Potion cooldown: Event-driven detection (for accurate timing)
---------------------------------------------------------------------------
function SM.OnPotionUsed(eventCode, itemSoundCategory)
    -- ITEM_SOUND_CATEGORY_POTION might be nil on some API versions
    local POTION_CATEGORY = ITEM_SOUND_CATEGORY_POTION
    if POTION_CATEGORY and itemSoundCategory ~= POTION_CATEGORY then return end
    -- If constant doesn't exist, try to detect via cooldown change
    if not POTION_CATEGORY then return end

    Debug("Potion used event fired!")

    -- Brief poll to get past GCD
    EVENT_MANAGER:RegisterForUpdate(SM.name .. "PotionDetect", 20, function()
        local slotIndex = GetCurrentQuickslot()
        if not slotIndex then
            EVENT_MANAGER:UnregisterForUpdate(SM.name .. "PotionDetect")
            return
        end

        local ok, remain, duration, global
        if HOTBAR_CATEGORY_QUICKSLOT_WHEEL then
            ok, remain, duration, global = pcall(GetSlotCooldownInfo, slotIndex, HOTBAR_CATEGORY_QUICKSLOT_WHEEL)
        end
        if not ok or not remain then
            ok, remain, duration, global = pcall(GetSlotCooldownInfo, slotIndex)
        end

        if ok and not global then
            EVENT_MANAGER:UnregisterForUpdate(SM.name .. "PotionDetect")
            if remain and remain > 0 then
                potionCooldownEnd = GetGameTimeMilliseconds() + remain
                potionCooldownDur = duration or remain
                potionIsOnCooldown = true
                Debug("Potion event: CD started, " .. remain .. "ms, dur=" .. tostring(duration))
            end
        end
    end)
end

---------------------------------------------------------------------------
-- Get remaining potion cooldown (dual: cached + poll fallback)
---------------------------------------------------------------------------
function SM.GetPotionCooldownRemaining()
    -- Check cached event-driven state first
    if potionIsOnCooldown then
        local remaining = potionCooldownEnd - GetGameTimeMilliseconds()
        if remaining > 0 then
            return remaining
        end
        potionIsOnCooldown = false
    end

    -- Polling fallback: always check the actual quickslot state
    local slotIndex = GetCurrentQuickslot()
    if slotIndex then
        local ok, remain, duration, global
        if HOTBAR_CATEGORY_QUICKSLOT_WHEEL then
            ok, remain, duration, global = pcall(GetSlotCooldownInfo, slotIndex, HOTBAR_CATEGORY_QUICKSLOT_WHEEL)
        end
        if not ok or not remain then
            ok, remain, duration, global = pcall(GetSlotCooldownInfo, slotIndex)
        end
        if ok and remain and remain > 0 and not global then
            -- Update cached state
            potionCooldownEnd = GetGameTimeMilliseconds() + remain
            potionCooldownDur = duration or remain
            potionIsOnCooldown = true
            return remain
        end
    end

    return 0
end

---------------------------------------------------------------------------
-- Potion state transitions (called from periodic update)
---------------------------------------------------------------------------
function SM.UpdatePotionState()
    local sv = SM.savedVars
    if not sv then return end

    local remaining = SM.GetPotionCooldownRemaining()
    local isOnCD = remaining > 0

    -- Detect transition: cooldown -> ready
    if potionWasOnCooldown and not isOnCD then
        Debug("Potion became READY")
        local resourceLow = false
        for _, pt in ipairs({ POWERTYPE_MAGICKA, POWERTYPE_STAMINA }) do
            local res = SM.GetResourceData(pt)
            if res and res.timeToEmpty >= 0 and res.timeToEmpty < (sv.warningThreshold1 or 10) then
                resourceLow = true
                break
            end
        end

        if resourceLow then
            if sv.warningSound then
                PlaySound(GetSoundPotionReady())
                Debug("Playing POTION READY sound")
            end
            if SM.ShowActionPrompt then
                local potionColor = (sv and sv.colorPotion) or { 0, 0.75, 1, 1 }
                SM.ShowActionPrompt(SM.L.PROMPT_USE_POTION, potionColor, 2500)
            end
        end
    end

    potionWasOnCooldown = isOnCD
end

---------------------------------------------------------------------------
-- Heavy Attack Suggestion
---------------------------------------------------------------------------
function SM.CheckHeavyAttack()
    local sv = SM.savedVars
    if not sv or not sv.haEnabled then return end
    if not SM.IsInCombat() then return end

    local now = GetGameTimeMilliseconds()
    if now - lastHASuggestionTime < HA_COOLDOWN_MS then return end

    local haThreshold   = sv.haThreshold or 8
    local haResourcePct = sv.haResourcePct or 50
    local CRITICAL_PCT  = 3   -- below this you can't cast abilities

    for _, powerType in ipairs({ POWERTYPE_MAGICKA, POWERTYPE_STAMINA }) do
        local res = SM.GetResourceData(powerType)
        if res and res.burnRate < -1 then
            -- Trigger condition: TTE-based OR casts-based (whichever fires first)
            local tteTrigger = res.timeToEmpty >= 0
                and res.timeToEmpty < haThreshold
                and res.currentPercent < haResourcePct
            local castsTrigger = res.castsRemaining and res.castsRemaining >= 0
                and res.castsRemaining <= 2
                and res.currentPercent < haResourcePct

            if tteTrigger or castsTrigger then

                lastHASuggestionTime = now

                -- Log the trigger decision
                if SM.LogEntry then
                    SM.LogEntry("HA_TRIGGER", {
                        pt = powerType,
                        pct = math.floor(res.currentPercent * 10) / 10,
                        tte = math.floor(res.timeToEmpty * 10) / 10,
                        casts = res.castsRemaining,
                        rate = math.floor(res.burnRate),
                        tteTrig = tteTrigger and 1 or 0,
                        castsTrig = castsTrigger and 1 or 0,
                    })
                end

                -- Potion ready? → show "USE POTION" (blinking) instead of Heavy Attack
                local potionReady = SM.GetPotionCooldownRemaining() <= 0
                if potionReady then
                    Debug("Potion READY -> showing potion prompt instead of HA")
                    if SM.LogEntry then SM.LogEntry("POTION_PROMPT", { reason = "ready_during_HA" }) end
                    if sv.warningSound then
                        PlaySound(GetSoundPotionReady())
                    end
                    if SM.ShowActionPrompt then
                        local potionColor = (sv and sv.colorPotion) or { 0, 0.75, 1, 1 }
                        SM.ShowActionPrompt(SM.L.PROMPT_USE_POTION, potionColor, 2500, true)
                    end
                    return
                end

                -- Heavy Attack: RED + blink if critically low (<3% or 0 casts), GOLD otherwise
                local isCritical = res.currentPercent < CRITICAL_PCT
                    or (res.castsRemaining and res.castsRemaining <= 0)
                local colorRed = (sv and sv.colorWarningRed) or { 1, 0, 0, 1 }
                local colorYellow = (sv and sv.colorWarningYellow) or { 1, 0.84, 0, 1 }
                local color = isCritical and colorRed or colorYellow
                Debug(string.format("Heavy Attack: PT=%s pct=%.1f%% casts=%s %s",
                    tostring(powerType), res.currentPercent,
                    tostring(res.castsRemaining), isCritical and "CRITICAL" or "normal"))
                if SM.LogEntry then SM.LogEntry("HA_PROMPT", { pt = powerType, critical = isCritical and 1 or 0 }) end

                if sv.warningSound then
                    PlaySound(GetSoundHeavyAttack())
                end

                if SM.ShowActionPrompt then
                    SM.ShowActionPrompt(SM.L.PROMPT_HEAVY_ATTACK, color, 2000, isCritical)
                end
                return
            end
        end
    end
end

---------------------------------------------------------------------------
-- Sound test (called via /sm sounds)
---------------------------------------------------------------------------
function SM.PlayTestSounds()
    local sv = SM.savedVars
    local wKey = sv and sv.soundWarning or "GENERAL_ALERT_ERROR"
    local hKey = sv and sv.soundHeavyAttack or "CHAMPION_POINT_GAINED"
    local pKey = sv and sv.soundPotionReady or "QUEST_COMPLETED"

    d("|cAAD1FF[SM]|r Playing test sounds (current config)...")
    d("|cAAD1FF[SM]|r Sound 1/3: |cFF4444Resource Warning|r (" .. wKey .. ")")
    PlaySound(GetSoundWarning())

    zo_callLater(function()
        d("|cAAD1FF[SM]|r Sound 2/3: |cFFD700Heavy Attack|r (" .. hKey .. ")")
        PlaySound(GetSoundHeavyAttack())
    end, 1500)

    zo_callLater(function()
        d("|cAAD1FF[SM]|r Sound 3/3: |c00BFFFPotion Ready|r (" .. pKey .. ")")
        PlaySound(GetSoundPotionReady())
    end, 3000)

    zo_callLater(function()
        d("|cAAD1FF[SM]|r Sound test complete. Change sounds in Settings > Warnings.")
    end, 4500)
end

---------------------------------------------------------------------------
-- Debug dump (called via /sm debug)
---------------------------------------------------------------------------
function SM.DumpDebugInfo()
    d("|cAAD1FF[SM Debug Dump]|r --------")
    d("  Style: " .. tostring(SM.savedVars and SM.savedVars.displayStyle))
    d("  In Combat: " .. tostring(SM.IsInCombat()))

    for _, pt in ipairs({ POWERTYPE_MAGICKA, POWERTYPE_STAMINA, POWERTYPE_HEALTH }) do
        local res = SM.GetResourceData(pt)
        if res then
            local avgCost = SM.GetActiveBarAvgCost and SM.GetActiveBarAvgCost(pt) or 0
            local smartCost = SM.GetSmartCost and SM.GetSmartCost(pt) or 0
            d(string.format("  PT %s: %d/%d (%.0f%%) rate=%.0f/s tte=%.1fs casts=%s avg=%.0f smart=%.0f regen=%.0f",
                tostring(pt), res.current, res.max, res.currentPercent,
                res.burnRate, res.timeToEmpty, tostring(res.castsRemaining),
                avgCost, smartCost, res.regenRate))
        end
    end

    local potionRemain = SM.GetPotionCooldownRemaining()
    d(string.format("  Potion: %s (cached=%s, remain=%dms)",
        potionRemain > 0 and "ON COOLDOWN" or "READY",
        tostring(potionIsOnCooldown), potionRemain))

    local slot = GetCurrentQuickslot()
    d("  Quickslot index: " .. tostring(slot))
    if slot then
        local ok, remain, dur, global
        if HOTBAR_CATEGORY_QUICKSLOT_WHEEL then
            ok, remain, dur, global = pcall(GetSlotCooldownInfo, slot, HOTBAR_CATEGORY_QUICKSLOT_WHEEL)
            d(string.format("  GetSlotCooldownInfo(+wheel): ok=%s remain=%s dur=%s global=%s",
                tostring(ok), tostring(remain), tostring(dur), tostring(global)))
        end
        ok, remain, dur, global = pcall(GetSlotCooldownInfo, slot)
        d(string.format("  GetSlotCooldownInfo(no wheel): ok=%s remain=%s dur=%s global=%s",
            tostring(ok), tostring(remain), tostring(dur), tostring(global)))
    end

    d("  HOTBAR_CATEGORY_QUICKSLOT_WHEEL = " .. tostring(HOTBAR_CATEGORY_QUICKSLOT_WHEEL))
    d("  ITEM_SOUND_CATEGORY_POTION = " .. tostring(ITEM_SOUND_CATEGORY_POTION))
    d("|cAAD1FF[SM Debug Dump]|r --------")
end
