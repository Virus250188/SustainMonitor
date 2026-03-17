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

-- Potion type detection
local potionRestores = nil  -- nil = unknown/fallback, or { [POWERTYPE_X] = restoreAmount, ... }

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
-- Potion Type Detection
---------------------------------------------------------------------------

--- Scan the current quickslot potion to determine which resources it restores
function SM.ScanPotionType()
    potionRestores = nil  -- reset to fallback

    local slotIndex = GetCurrentQuickslot()
    if not slotIndex then
        Debug("ScanPotionType: no quickslot index")
        if SM.LogEntry then SM.LogEntry("POTION_SCAN", { error = "no_quickslot" }) end
        return
    end

    -- Get item link (try with HOTBAR_CATEGORY_QUICKSLOT_WHEEL first)
    local itemLink
    if HOTBAR_CATEGORY_QUICKSLOT_WHEEL then
        local ok, link = pcall(GetSlotItemLink, slotIndex, HOTBAR_CATEGORY_QUICKSLOT_WHEEL)
        if ok and link and link ~= "" then itemLink = link end
    end
    if not itemLink then
        local ok, link = pcall(GetSlotItemLink, slotIndex)
        if ok and link and link ~= "" then itemLink = link end
    end

    if not itemLink or itemLink == "" then
        Debug("ScanPotionType: no item link found")
        if SM.LogEntry then SM.LogEntry("POTION_SCAN", { error = "no_item_link", slot = slotIndex }) end
        return
    end

    -- Get on-use description
    -- API: GetItemLinkOnUseAbilityInfo(link) → hasAbility, header, description, cooldown, ...
    local ok, hasAbility, abilityHeader, abilityDescription = pcall(GetItemLinkOnUseAbilityInfo, itemLink)

    -- Log ALL return values for debugging
    if SM.LogEntry then
        SM.LogEntry("POTION_SCAN_RAW", {
            ok = tostring(ok),
            hasAbil = tostring(hasAbility),
            header = tostring(abilityHeader),
            desc = tostring(abilityDescription),
        })
    end

    if not ok or not hasAbility or not abilityDescription or abilityDescription == "" then
        Debug("ScanPotionType: no on-use description. ok=" .. tostring(ok)
            .. " hasAbil=" .. tostring(hasAbility)
            .. " desc=" .. tostring(abilityDescription))
        if SM.LogEntry then SM.LogEntry("POTION_SCAN", { error = "no_description" }) end
        return
    end

    Debug("ScanPotionType: description = " .. tostring(abilityDescription))

    -- Build localized resource name patterns (works in all languages: EN, DE, FR, etc.)
    -- SI_ATTRIBUTES: 1=Health, 2=Magicka, 3=Stamina (localized by game client)
    local magickaName = GetString and SI_ATTRIBUTES2 and GetString(SI_ATTRIBUTES2)
    local staminaName = GetString and SI_ATTRIBUTES3 and GetString(SI_ATTRIBUTES3)
    local healthName  = GetString and SI_ATTRIBUTES1 and GetString(SI_ATTRIBUTES1)

    -- Log what SI_ATTRIBUTES resolved to
    if SM.LogEntry then
        SM.LogEntry("POTION_SCAN_NAMES", {
            mag = tostring(magickaName),
            stam = tostring(staminaName),
            hp = tostring(healthName),
        })
    end

    -- Collect all search terms per resource type (localized + English fallbacks)
    local searchTerms = {
        { names = {}, powerType = POWERTYPE_MAGICKA },
        { names = {}, powerType = POWERTYPE_STAMINA },
        { names = {}, powerType = POWERTYPE_HEALTH },
    }

    -- Localized names
    if magickaName and magickaName ~= "" then searchTerms[1].names[#searchTerms[1].names + 1] = magickaName end
    if staminaName and staminaName ~= "" then searchTerms[2].names[#searchTerms[2].names + 1] = staminaName end
    if healthName  and healthName  ~= "" then searchTerms[3].names[#searchTerms[3].names + 1] = healthName  end

    -- English fallbacks (always add, deduplicated later)
    searchTerms[1].names[#searchTerms[1].names + 1] = "Magicka"
    searchTerms[2].names[#searchTerms[2].names + 1] = "Stamina"
    searchTerms[3].names[#searchTerms[3].names + 1] = "Health"

    -- German fallbacks (common terms)
    searchTerms[2].names[#searchTerms[2].names + 1] = "Ausdauer"
    searchTerms[3].names[#searchTerms[3].names + 1] = "Leben"
    searchTerms[3].names[#searchTerms[3].names + 1] = "Gesundheit"

    -- French fallbacks
    searchTerms[2].names[#searchTerms[2].names + 1] = "Endurance"
    searchTerms[3].names[#searchTerms[3].names + 1] = "Vie"

    -- Parse description for resource restore amounts
    -- Strip ESO color/link codes first: |cXXXXXX, |r, |H...|h, |h, etc.
    local cleanDesc = string.gsub(abilityDescription, "|[cC]%x%x%x%x%x%x", "")
    cleanDesc = string.gsub(cleanDesc, "|[rR]", "")
    cleanDesc = string.gsub(cleanDesc, "|[hH].-|[hH]", "")
    cleanDesc = string.gsub(cleanDesc, "|[tT].-|[tT]", "")

    if SM.LogEntry then
        SM.LogEntry("POTION_SCAN_CLEAN", { cleanDesc = cleanDesc })
    end

    local parsed = {}
    local lowerDesc = string.lower(cleanDesc)

    for _, entry in ipairs(searchTerms) do
        for _, name in ipairs(entry.names) do
            if not parsed[entry.powerType] then
                local lowerName = string.lower(name)
                -- Pattern: number (with possible separators like . , or spaces) followed by resource name
                local numStr = string.match(lowerDesc, "(%d[%d,%.%s]*)%s*" .. lowerName)
                if numStr then
                    -- Strip EVERYTHING that is not a digit
                    numStr = string.gsub(numStr, "%D", "")
                    local amount = tonumber(numStr)
                    if amount and amount > 0 then
                        parsed[entry.powerType] = amount
                        Debug("ScanPotionType: matched '" .. name .. "' = " .. tostring(amount))
                    end
                end
            end
        end
    end

    -- Only set potionRestores if we found something
    if next(parsed) then
        potionRestores = parsed
        for pt, amount in pairs(potionRestores) do
            local ptName = "?"
            if pt == POWERTYPE_MAGICKA then ptName = "Magicka"
            elseif pt == POWERTYPE_STAMINA then ptName = "Stamina"
            elseif pt == POWERTYPE_HEALTH then ptName = "Health" end
            Debug("ScanPotionType: restores " .. ptName .. " = " .. tostring(amount))
        end
        if SM.LogEntry then SM.LogEntry("POTION_SCAN_OK", parsed) end
    else
        Debug("ScanPotionType: could not parse '" .. tostring(abilityDescription) .. "' (using fallback)")
        if SM.LogEntry then SM.LogEntry("POTION_SCAN_FAIL", { desc = abilityDescription }) end
    end
end

--- Returns the restore amount for a powerType, or nil if not restored.
--- Returns true if potion type is unknown (fallback behavior).
function SM.PotionRestoresResource(powerType)
    if potionRestores == nil then return true end  -- unknown = assume yes (fallback)
    return potionRestores[powerType]  -- returns amount or nil
end

--- Determines whether a potion alert should fire for the given powerType.
--- Uses smart threshold when potion restore amount is known, falls back to TTE check.
function SM.ShouldAlertPotion(powerType)
    local restoreAmount = SM.PotionRestoresResource(powerType)
    if not restoreAmount then return false end
    if restoreAmount == true then
        -- Fallback: unknown potion, use old TTE-based check
        local sv = SM.savedVars
        local res = SM.GetResourceData(powerType)
        return res and res.timeToEmpty >= 0 and res.timeToEmpty < (sv.warningThreshold1 or 10)
    end
    -- Smart check: alert only when player can fully use the potion (no overheal waste)
    local res = SM.GetResourceData(powerType)
    if not res then return false end
    local threshold = res.max - restoreAmount
    return res.current <= threshold
end

--- Accessor for debug dump
function SM.GetPotionRestores()
    return potionRestores
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
    lastPotionAlertTime  = 0

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
    if SM.IsPlayerDead and SM.IsPlayerDead() then return end
    local sv = SM.savedVars
    if not sv or not sv.warningEnabled then return end

    -- Resource Focus filter: skip warnings for non-focused resources
    local focus = SM.GetFocusedResource and SM.GetFocusedResource()
    if focus and powerType ~= focus then return end

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
    if SM.IsPlayerDead and SM.IsPlayerDead() then return end
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
    if SM.IsPlayerDead and SM.IsPlayerDead() then return end
    local sv = SM.savedVars
    if not sv then return end

    local remaining = SM.GetPotionCooldownRemaining()
    local isOnCD = remaining > 0

    -- Detect transition: cooldown -> ready
    if potionWasOnCooldown and not isOnCD then
        Debug("Potion became READY")
        local resourceLow = false
        local focus = SM.GetFocusedResource and SM.GetFocusedResource()
        for _, pt in ipairs({ POWERTYPE_MAGICKA, POWERTYPE_STAMINA }) do
            if (not focus or pt == focus) and SM.ShouldAlertPotion(pt) then
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
-- Potion Alert (Priority 1: fires BEFORE heavy attack suggestion)
-- Shows "USE POTION" when potion is ready and resource needs it
---------------------------------------------------------------------------
local lastPotionAlertTime = 0
local POTION_ALERT_COOLDOWN_MS = 3000

function SM.CheckPotionAlert()
    if SM.IsPlayerDead and SM.IsPlayerDead() then return end
    local sv = SM.savedVars
    if not sv then return end
    if not SM.IsInCombat() then return end

    local now = GetGameTimeMilliseconds()
    if now - lastPotionAlertTime < POTION_ALERT_COOLDOWN_MS then return end

    -- Only check when potion is ready
    local potionReady = SM.GetPotionCooldownRemaining() <= 0
    if not potionReady then return end

    -- Resource Focus filter
    local focus = SM.GetFocusedResource and SM.GetFocusedResource()
    local resourcesToCheck = { POWERTYPE_MAGICKA, POWERTYPE_STAMINA }
    if focus and focus ~= POWERTYPE_HEALTH then
        resourcesToCheck = { focus }
    end

    for _, powerType in ipairs(resourcesToCheck) do
        if SM.ShouldAlertPotion(powerType) then
            lastPotionAlertTime = now
            Debug("Potion alert: resource low enough to benefit from potion")
            if SM.LogEntry then SM.LogEntry("POTION_PROMPT", { reason = "resource_low", pt = powerType }) end
            if sv.warningSound then
                PlaySound(GetSoundPotionReady())
            end
            if SM.ShowActionPrompt then
                local potionColor = (sv and sv.colorPotion) or { 0, 0.75, 1, 1 }
                SM.ShowActionPrompt(SM.L.PROMPT_USE_POTION, potionColor, 2500, true)
            end
            return  -- one alert at a time
        end
    end
end

---------------------------------------------------------------------------
-- Heavy Attack Suggestion (Priority 2: only when potion is on CD)
---------------------------------------------------------------------------
function SM.CheckHeavyAttack()
    if SM.IsPlayerDead and SM.IsPlayerDead() then return end
    local sv = SM.savedVars
    if not sv or not sv.haEnabled then return end
    if not SM.IsInCombat() then return end

    -- Priority rule: if potion is ready, CheckPotionAlert handles it → skip HA
    local potionReady = SM.GetPotionCooldownRemaining() <= 0
    if potionReady then return end

    local now = GetGameTimeMilliseconds()
    if now - lastHASuggestionTime < HA_COOLDOWN_MS then return end

    local haThreshold   = sv.haThreshold or 8
    local haResourcePct = sv.haResourcePct or 50
    local CRITICAL_PCT  = 3   -- below this you can't cast abilities

    -- Resource Focus filter: only check the focused resource (if set)
    local focus = SM.GetFocusedResource and SM.GetFocusedResource()
    local resourcesToCheck = { POWERTYPE_MAGICKA, POWERTYPE_STAMINA }
    if focus and focus ~= POWERTYPE_HEALTH then
        resourcesToCheck = { focus }
    end

    for _, powerType in ipairs(resourcesToCheck) do
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

    -- Potion type detection info
    if potionRestores then
        for pt, amount in pairs(potionRestores) do
            local ptName = "?"
            if pt == POWERTYPE_MAGICKA then ptName = "Magicka"
            elseif pt == POWERTYPE_STAMINA then ptName = "Stamina"
            elseif pt == POWERTYPE_HEALTH then ptName = "Health" end
            d("  Potion restores: " .. ptName .. " = " .. tostring(amount))
        end
    else
        d("  Potion type: unknown (using fallback)")
    end

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

    -- Show raw potion description for debugging
    local dumpSlot = GetCurrentQuickslot()
    if dumpSlot then
        local dumpLink
        if HOTBAR_CATEGORY_QUICKSLOT_WHEEL then
            local ok2, link2 = pcall(GetSlotItemLink, dumpSlot, HOTBAR_CATEGORY_QUICKSLOT_WHEEL)
            if ok2 and link2 and link2 ~= "" then dumpLink = link2 end
        end
        if not dumpLink then
            local ok2, link2 = pcall(GetSlotItemLink, dumpSlot)
            if ok2 and link2 and link2 ~= "" then dumpLink = link2 end
        end
        if dumpLink then
            local ok2, hasAbil, hdr, desc = pcall(GetItemLinkOnUseAbilityInfo, dumpLink)
            d("  Potion raw desc: " .. tostring(desc))
            d("  Potion hasAbility: " .. tostring(hasAbil))
        end
    end

    -- Resource Focus info
    local focusVal = SM.savedVars and SM.savedVars.resourceFocus or "?"
    local focusPT = SM.GetFocusedResource and SM.GetFocusedResource() or "nil"
    d("  Resource Focus: setting=" .. tostring(focusVal) .. " resolved=" .. tostring(focusPT))

    d("  HOTBAR_CATEGORY_QUICKSLOT_WHEEL = " .. tostring(HOTBAR_CATEGORY_QUICKSLOT_WHEEL))
    d("  ITEM_SOUND_CATEGORY_POTION = " .. tostring(ITEM_SOUND_CATEGORY_POTION))
    d("|cAAD1FF[SM Debug Dump]|r --------")
end
