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

--- Resolve a mob name from npcID via SilverDragon's NameForMob API.
--- That function checks SD's hardcoded mob database (ns.mobdb) and a
--- tooltip-hyperlink cache; it covers all known rares immediately.
--- Returns nil on a true cache miss (very uncommon custom/unknown NPCs).
--- @param npcID number
--- @return string|nil
local function ResolveMobName(npcID)
    if not npcID then return nil end
    local core = _G.SilverDragon
    if core and core.NameForMob then
        return core:NameForMob(npcID)
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

            -- If the name wasn't in SD's cache yet, retry after 1 s.
            if not name then
                C_Timer.After(1, function()
                    local alert = SD.alertQueue[npcID]
                    if not alert or alert.name then return end
                    local c = _G.SilverDragon
                    local resolved = c and c.NameForMob and c:NameForMob(npcID)
                    if resolved then
                        alert.name = resolved
                        if horizon.ScheduleRefresh then horizon.ScheduleRefresh() end
                    end
                end)
            end

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

    -- Suppress SilverDragon's native popup while the Focus integration is active.
    -- ClickTarget.Announce is registered via LibCallbackHandler (not AceEvent), so
    -- Module:Disable() won't unregister it. Instead we replace ShowFrame once with
    -- a wrapper that short-circuits when SD._suppressPopup is set. No hooksecurefunc,
    -- no touching restricted frames, no taint.
    local clickTarget = core:GetModule("ClickTarget", true)
    if clickTarget and clickTarget.ShowFrame then
        local origShowFrame = clickTarget.ShowFrame
        clickTarget.ShowFrame = function(self, data)
            if SD._suppressPopup then return end
            return origShowFrame(self, data)
        end
    end
    SD.ApplyPopupSuppression(horizon.GetDB("sd_enabled", false))

    -- Fired when SilverDragon clears its popup (user dismissed or timer expired).
    -- When the Focus integration is active we own the alert lifecycle, so we
    -- ignore this event and let the user dismiss via the Focus tracker instead.
    -- (SD's animFade → HideWhenPossible → PopupHide still fires, but we skip it
    -- to avoid also clearing our queue prematurely and to sidestep the known
    -- SD+TomTom stack-overflow caused by their re-entrant waypoint callbacks.)
    core.RegisterCallback(SD, "PopupHide", function()
        if horizon.GetDB("sd_enabled", false) then return end
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
