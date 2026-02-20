-- SustainMonitor: Main Entry-Point - Initialization & Event Registration
SustainMonitor = SustainMonitor or {}
local SM = SustainMonitor

---------------------------------------------------------------------------
-- Combat Log Constants
---------------------------------------------------------------------------
local LOG_MAX_ENTRIES = 2000   -- max entries per combat to keep file size sane
local LOG_SNAPSHOT_MS = 500    -- resource snapshot interval for log
local logSnapshotTimer = 0
local combatStartMs    = 0

---------------------------------------------------------------------------
-- EVENT_ADD_ON_LOADED handler
---------------------------------------------------------------------------
local function OnAddonLoaded(eventCode, addonName)
    if addonName ~= SM.name then return end

    -- Unregister this one-time event
    EVENT_MANAGER:UnregisterForEvent(SM.name .. "Load", EVENT_ADD_ON_LOADED)

    -- Load saved variables
    SM.savedVars = ZO_SavedVars:NewAccountWide("SustainMonitorSV", 1, GetWorldName(), SM.defaults)

    -- Load combat log saved variable (separate file for easy sharing)
    SM.logVars = ZO_SavedVars:NewAccountWide("SustainMonitorLog", 1, GetWorldName(), { entries = {}, info = "" })

    -- Initialize modules
    SM.InitCore()
    SM.InitWarnings()
    SM.CreateHUD()
    SM.InitSettings()
    SM.RegisterSlashCommands()

    -- Register gameplay events
    SM.RegisterEvents()

    -- Startup message
    d("|cAAD1FF[Sustain Monitor]|r v" .. SM.version .. " loaded.")
end

---------------------------------------------------------------------------
-- Combat Log: Write entry
---------------------------------------------------------------------------
function SM.LogEntry(entryType, data)
    local sv = SM.savedVars
    if not sv or not sv.debugMode then return end
    if not SM.logVars then return end

    local entries = SM.logVars.entries
    if not entries then return end
    if #entries >= LOG_MAX_ENTRIES then return end

    local now = GetGameTimeMilliseconds()
    local entry = {
        t  = now - combatStartMs,    -- relative time in ms since combat start
        ty = entryType,               -- entry type string
    }
    -- Merge data fields into entry
    if data then
        for k, v in pairs(data) do
            entry[k] = v
        end
    end
    entries[#entries + 1] = entry
end

---------------------------------------------------------------------------
-- Combat Log: Record resource snapshot (called periodically)
---------------------------------------------------------------------------
function SM.LogResourceSnapshot()
    local sv = SM.savedVars
    if not sv or not sv.debugMode then return end

    local now = GetGameTimeMilliseconds()
    if now - logSnapshotTimer < LOG_SNAPSHOT_MS then return end
    logSnapshotTimer = now

    for _, pt in ipairs({ POWERTYPE_MAGICKA, POWERTYPE_STAMINA, POWERTYPE_HEALTH }) do
        local res = SM.GetResourceData(pt)
        if res then
            SM.LogEntry("SNAPSHOT", {
                pt   = pt,
                cur  = res.current,
                max  = res.max,
                pct  = math.floor(res.currentPercent * 10) / 10,
                rate = math.floor(res.burnRate),
                tte  = math.floor(res.timeToEmpty * 10) / 10,
                cst  = res.castsRemaining or -1,
            })
        end
    end
end

---------------------------------------------------------------------------
-- Combat Log: Start new combat encounter
---------------------------------------------------------------------------
function SM.LogCombatStart()
    local sv = SM.savedVars
    if not sv or not sv.debugMode then return end
    if not SM.logVars then return end

    -- Clear previous log and start fresh
    SM.logVars.entries = {}
    combatStartMs = GetGameTimeMilliseconds()
    logSnapshotTimer = 0

    -- Record header info
    SM.logVars.info = string.format("Combat started at %s, style=%s",
        tostring(GetTimeString()), tostring(sv.displayStyle))

    SM.LogEntry("COMBAT_START", {
        ts = GetTimeString(),
    })

    -- Log initial resource state
    for _, pt in ipairs({ POWERTYPE_MAGICKA, POWERTYPE_STAMINA, POWERTYPE_HEALTH }) do
        local res = SM.GetResourceData(pt)
        if res then
            SM.LogEntry("INITIAL_STATE", {
                pt   = pt,
                cur  = res.current,
                max  = res.max,
                pct  = math.floor(res.currentPercent * 10) / 10,
                regen = res.regenRate,
            })
        end
    end

    -- Log equipped abilities and their costs
    SM.LogEntry("ABILITY_COSTS", {
        note = "See ABILITY_SCAN entries from ScanAbilityCosts for details",
    })
end

---------------------------------------------------------------------------
-- Combat Log: End combat encounter
---------------------------------------------------------------------------
function SM.LogCombatEnd()
    local sv = SM.savedVars
    if not sv or not sv.debugMode then return end

    SM.LogEntry("COMBAT_END", {
        ts = GetTimeString(),
        duration_ms = GetGameTimeMilliseconds() - combatStartMs,
    })

    local count = SM.logVars and SM.logVars.entries and #SM.logVars.entries or 0
    d(string.format("|cAAD1FF[SM]|r Combat log: %d entries recorded. Type /reloadui to save to disk.", count))
end

---------------------------------------------------------------------------
-- Combat Event handler: track ability usage
---------------------------------------------------------------------------
function SM.OnCombatEvent(eventCode, result, isError, abilityName, abilityGraphic,
    abilityActionSlotType, sourceName, sourceType, targetName, targetType,
    hitValue, powerType, damageType, log, sourceUnitId, targetUnitId, abilityId)

    -- Only track when player is the source
    if sourceType ~= COMBAT_UNIT_TYPE_PLAYER then return end

    -- Track ability usage for smart cost prediction (always, not just debug)
    if result == ACTION_RESULT_BEGIN and SM.TrackAbilityUsage then
        SM.TrackAbilityUsage(abilityId)
    end

    -- Debug combat log (only in debug mode)
    local sv = SM.savedVars
    if not sv or not sv.debugMode then return end

    -- Only log meaningful results (ability start, damage, heal, resource change)
    if result ~= ACTION_RESULT_BEGIN
        and result ~= ACTION_RESULT_EFFECT_GAINED
        and result ~= ACTION_RESULT_DAMAGE
        and result ~= ACTION_RESULT_CRITICAL_DAMAGE
        and result ~= ACTION_RESULT_HEAL
        and result ~= ACTION_RESULT_CRITICAL_HEAL
        and result ~= ACTION_RESULT_POWER_ENERGIZE
        and result ~= ACTION_RESULT_HOT_TICK
        and result ~= ACTION_RESULT_DOT_TICK then
        return
    end

    SM.LogEntry("COMBAT", {
        ability  = abilityName,
        id       = abilityId,
        result   = result,
        value    = hitValue,
        pt       = powerType,
        target   = targetName,
    })
end

---------------------------------------------------------------------------
-- Register gameplay events
---------------------------------------------------------------------------
function SM.RegisterEvents()
    local em = EVENT_MANAGER

    -- Power updates (filtered to player only for performance)
    em:RegisterForEvent(SM.name .. "Power", EVENT_POWER_UPDATE, SM.OnPowerUpdate)
    em:AddFilterForEvent(SM.name .. "Power", EVENT_POWER_UPDATE,
        REGISTER_FILTER_UNIT_TAG, "player")

    -- Combat state
    em:RegisterForEvent(SM.name .. "Combat", EVENT_PLAYER_COMBAT_STATE, SM.OnCombatState)

    -- Player activated (login, zone change, resurrect)
    em:RegisterForEvent(SM.name .. "Activated", EVENT_PLAYER_ACTIVATED, SM.OnPlayerActivated)

    -- Player death / alive
    em:RegisterForEvent(SM.name .. "Dead",  EVENT_PLAYER_DEAD,  SM.OnPlayerDead)
    em:RegisterForEvent(SM.name .. "Alive", EVENT_PLAYER_ALIVE, SM.OnPlayerAlive)

    -- Potion usage detection (event-driven for accurate cooldown tracking)
    em:RegisterForEvent(SM.name .. "ItemUsed", EVENT_INVENTORY_ITEM_USED, SM.OnPotionUsed)

    -- Bar swap / ability slot changes (rescan ability costs)
    if EVENT_ACTION_SLOTS_FULL_UPDATE then
        em:RegisterForEvent(SM.name .. "Slots", EVENT_ACTION_SLOTS_FULL_UPDATE, SM.OnActionSlotsUpdated)
    end

    -- Combat events (ability tracking for combat log)
    if EVENT_COMBAT_EVENT then
        em:RegisterForEvent(SM.name .. "CombatLog", EVENT_COMBAT_EVENT, SM.OnCombatEvent)
        em:AddFilterForEvent(SM.name .. "CombatLog", EVENT_COMBAT_EVENT,
            REGISTER_FILTER_SOURCE_COMBAT_UNIT_TYPE, COMBAT_UNIT_TYPE_PLAYER)
    end
end

---------------------------------------------------------------------------
-- Bootstrap: register the addon loaded event
---------------------------------------------------------------------------
EVENT_MANAGER:RegisterForEvent(SM.name .. "Load", EVENT_ADD_ON_LOADED, OnAddonLoaded)
