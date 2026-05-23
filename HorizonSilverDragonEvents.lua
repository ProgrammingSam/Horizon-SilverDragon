--[[
    Horizon - SilverDragon - Events
    Registers callbacks on SilverDragon's LibCallbackHandler event system once
    both addons are loaded, tracks an ordered queue of active alerts, and asks
    HorizonSuite to refresh the Focus tracker whenever an alert appears or clears.
]]

local horizon = _G.HorizonSuite
local SD      = _G.HorizonSilverDragon
if not horizon or not SD then return end

-- ============================================================================
-- CONSTANTS
-- ============================================================================

local SD_MAX_ALERTS_MIN     = 1
local SD_MAX_ALERTS_MAX     = 10
local SD_MAX_ALERTS_DEFAULT = 4

-- ============================================================================
-- NAVIGATION
-- ============================================================================

SD.NavigatePrev = function()
    if #SD.alertOrder == 0 then return end
    SD.alertIndex = SD.alertIndex - 1
    if SD.alertIndex < 1 then SD.alertIndex = #SD.alertOrder end
    if horizon.ScheduleRefresh then horizon.ScheduleRefresh() end
end

SD.NavigateNext = function()
    if #SD.alertOrder == 0 then return end
    SD.alertIndex = SD.alertIndex + 1
    if SD.alertIndex > #SD.alertOrder then SD.alertIndex = 1 end
    if horizon.ScheduleRefresh then horizon.ScheduleRefresh() end
end

-- ============================================================================
-- HELPERS
-- ============================================================================

--- Resolve the zone name for a given uiMapID.
--- @param mapID number|nil
--- @return string|nil
local function ResolveZoneName(mapID)
    if not mapID or not (C_Map and C_Map.GetMapInfo) then return nil end
    local info = C_Map.GetMapInfo(mapID)
    return info and info.name or nil
end

--- Resolve a mob name from npcID.
--- SilverDragon's "Seen" callback does not pass a name; we attempt several
--- sources in order: SilverDragon's own mob DB, the game's creature cache.
--- Returns nil when the name is not yet available (async cache miss).
--- @param npcID number
--- @return string|nil
local function ResolveMobName(npcID)
    if not npcID then return nil end
    -- SilverDragon mob database (populated by its data modules).
    local core = _G.SilverDragon
    if core and core.db and core.db.global and core.db.global.mobs then
        local mob = core.db.global.mobs[npcID]
        if mob and mob.name then return mob.name end
    end
    -- Fallback: game creature cache (available when the NPC is in render range).
    if C_TooltipInfo and C_TooltipInfo.GetUnit then
        -- Cannot query by npcID directly; skip — caller will retry on next refresh.
    end
    return nil
end

-- ============================================================================
-- CALLBACK REGISTRATION
-- ============================================================================

-- ============================================================================
-- SEEN-AGO TIMER
-- Fires every 60 s while the queue is non-empty to keep "X ago" text fresh.
-- ============================================================================

local seenAgoTimerActive = false

local function RunSeenAgoTick()
    if #SD.alertOrder == 0 then
        seenAgoTimerActive = false
        return
    end
    if horizon.ScheduleRefresh then horizon.ScheduleRefresh() end
    C_Timer.After(60, RunSeenAgoTick)
end

local function StartSeenAgoTimer()
    if seenAgoTimerActive then return end
    seenAgoTimerActive = true
    C_Timer.After(60, RunSeenAgoTick)
end

-- ============================================================================
-- CALLBACK REGISTRATION
-- ============================================================================

local registered = false

local function RegisterSilverDragonCallbacks()
    if registered then return end
    local core = _G.SilverDragon
    if not core or not core.RegisterCallback then return end
    registered = true

    -- Fired each time SilverDragon detects a rare NPC.
    core.RegisterCallback(SD, "Seen", function(_, npcID, zone, x, y, is_dead, source)
        if not SD.GetDB("enabled", true) then return end
        if not npcID then return end

        local mapID    = zone
        local zoneName = ResolveZoneName(mapID)
        local name     = ResolveMobName(npcID)

        local existingIdx
        for i, id in ipairs(SD.alertOrder) do
            if id == npcID then existingIdx = i; break end
        end

        if existingIdx then
            -- Update existing alert and navigate to it; preserve original seenAt.
            local alert = SD.alertQueue[npcID]
            alert.mapID    = mapID
            alert.x        = x
            alert.y        = y
            alert.zoneName = zoneName
            alert.is_dead  = is_dead
            alert.source   = source
            if name then alert.name = name end
            SD.alertIndex = existingIdx
        else
            SD.alertQueue[npcID] = {
                npcID    = npcID,
                name     = name,
                mapID    = mapID,
                x        = x,
                y        = y,
                zoneName = zoneName,
                is_dead  = is_dead,
                source   = source,
                seenAt   = GetTime(),
            }
            SD.alertOrder[#SD.alertOrder + 1] = npcID
            SD.alertIndex = #SD.alertOrder
            StartSeenAgoTimer()

            -- FIFO trim: drop oldest entries when queue exceeds the configured limit.
            local maxAlerts = math.max(SD_MAX_ALERTS_MIN,
                math.min(SD_MAX_ALERTS_MAX,
                    horizon.GetDB("sd_maxAlerts", SD_MAX_ALERTS_DEFAULT)))
            while #SD.alertOrder > maxAlerts do
                local removed = table.remove(SD.alertOrder, 1)
                SD.alertQueue[removed] = nil
                SD.alertIndex = SD.alertIndex - 1
            end
            if SD.alertIndex < 1 then SD.alertIndex = 1 end
        end

        local alert = SD.alertQueue[SD.alertOrder[SD.alertIndex]]
        local sdModule = horizon.focus and horizon.focus.sd
        if horizon.GetDB("sd_autoWaypoint", false) and sdModule and sdModule.SetWaypoint and alert then
            pcall(sdModule.SetWaypoint, { title = alert.name, vignetteMapID = alert.mapID, vignetteX = alert.x, vignetteY = alert.y })
        end

        if horizon.ScheduleRefresh then horizon.ScheduleRefresh() end
    end)

    -- Fired when SilverDragon clears its popup (user dismissed or timer expired).
    core.RegisterCallback(SD, "PopupHide", function()
        if #SD.alertOrder > 0 then
            SD.alertQueue = {}
            SD.alertOrder = {}
            SD.alertIndex = 0
            seenAgoTimerActive = false
            if horizon.ScheduleRefresh then horizon.ScheduleRefresh() end
        end
    end)
end

-- ============================================================================
-- EVENT FRAME
-- ============================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(_, _, addonName)
    if addonName == "SilverDragon" or addonName == SD.ADDON_NAME then
        C_Timer.After(0, RegisterSilverDragonCallbacks)
    end
end)

-- Safety net: if SilverDragon was already loaded before us.
C_Timer.After(0, RegisterSilverDragonCallbacks)
