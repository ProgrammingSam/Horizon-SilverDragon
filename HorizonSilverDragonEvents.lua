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

        local mobKey   = "mob:" .. npcID
        local mapID    = zone
        local zoneName = ResolveZoneName(mapID)
        local name     = ResolveMobName(npcID)

        local existingIdx
        for i, k in ipairs(SD.alertOrder) do
            if k == mobKey then existingIdx = i; break end
        end

        if existingIdx then
            -- Update existing alert and navigate to it; preserve original seenAt.
            local alert = SD.alertQueue[mobKey]
            alert.mapID    = mapID
            alert.x        = x
            alert.y        = y
            alert.zoneName = zoneName
            alert.is_dead  = is_dead
            alert.source   = source
            if name then alert.name = name end
            SD.alertIndex = existingIdx
        else
            SD.alertQueue[mobKey] = {
                type     = "mob",
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
            SD.alertOrder[#SD.alertOrder + 1] = mobKey
            SD.alertIndex = #SD.alertOrder
            StartSeenAgoTimer()

            -- If the name wasn't in SD's cache yet, retry after 1 s.
            if not name then
                C_Timer.After(1, function()
                    local alert = SD.alertQueue[mobKey]
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

    -- Fired when SilverDragon detects a loot container vignette (chests, rare loot objects).
    core.RegisterCallback(SD, "SeenLoot", function(_, name, vignetteID, uiMapID, x, y, vignetteGUID)
        if not SD.GetDB("enabled", true) then return end
        if not vignetteID then return end
        if not horizon.GetDB("sd_showLoot", true) then return end

        local lootKey = "loot:" .. vignetteID

        local existingIdx
        for i, k in ipairs(SD.alertOrder) do
            if k == lootKey then existingIdx = i; break end
        end

        if existingIdx then
            local alert = SD.alertQueue[lootKey]
            alert.mapID        = uiMapID
            alert.x            = x
            alert.y            = y
            alert.vignetteGUID = vignetteGUID
            if name then alert.name = name end
            SD.alertIndex = existingIdx
        else
            SD.alertQueue[lootKey] = {
                type         = "loot",
                vignetteID   = vignetteID,
                name         = name,
                mapID        = uiMapID,
                x            = x,
                y            = y,
                vignetteGUID = vignetteGUID,
                seenAt       = GetTime(),
            }
            SD.alertOrder[#SD.alertOrder + 1] = lootKey
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

        if horizon.ScheduleRefresh then horizon.ScheduleRefresh() end
    end)

    -- Suppress SilverDragon's native popup while the Focus integration is active.
    -- ClickTarget.Announce is registered via LibCallbackHandler (not AceEvent), so
    -- Module:Disable() won't unregister it. Instead we replace ShowFrame once with
    -- a wrapper that short-circuits when SD._suppressPopup is set. No hooksecurefunc,
    -- no touching restricted frames, no taint.
    -- Suppress SD's native popup by patching Enqueue rather than ShowFrame.
    -- Patching ShowFrame caused it to return nil, which table.insert then placed
    -- in self.stack, corrupting the sequence and crashing subsequent ipairs
    -- iterations in Enqueue with "attempt to index a number value".
    -- Blocking Enqueue means ProcessQueue/ShowFrame are never called, so the
    -- stack stays clean regardless of what SD does internally.
    local clickTarget = core:GetModule("ClickTarget", true)
    if clickTarget and clickTarget.Enqueue then
        local origEnqueue = clickTarget.Enqueue
        clickTarget.Enqueue = function(self, data)
            if SD._suppressPopup then return end
            return origEnqueue(self, data)
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
-- KILL DETECTION
-- Auto-prune mob alerts when the rare is killed (combat log) or a loot
-- alert's vignette disappears (looted by anyone nearby).
-- ============================================================================

local function PruneMobByNpcID(npcID)
    local mobKey = "mob:" .. npcID
    for i, k in ipairs(SD.alertOrder) do
        if k == mobKey then
            table.remove(SD.alertOrder, i)
            SD.alertQueue[mobKey] = nil
            if SD.alertIndex > i then
                SD.alertIndex = SD.alertIndex - 1
            elseif SD.alertIndex >= i then
                SD.alertIndex = math.max(0, math.min(SD.alertIndex, #SD.alertOrder))
            end
            if #SD.alertOrder == 0 then SD.alertIndex = 0 end
            if horizon.ScheduleRefresh then horizon.ScheduleRefresh() end
            return
        end
    end
end

local killFrame = CreateFrame("Frame")
killFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
killFrame:RegisterEvent("VIGNETTES_UPDATED")
killFrame:SetScript("OnEvent", function(_, event)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        -- UNIT_DIED fires for enemies in your combat log — covers kills you or your group land.
        local _, subevent, _, _, _, _, _, destGUID = CombatLogGetCurrentEventInfo()
        if subevent ~= "UNIT_DIED" then return end
        if not destGUID then return end
        -- Extract npcID from Creature GUID: Creature-0-realmID-serverID-instanceID-npcID-spawnUID
        local npcID = tonumber(destGUID:match("Creature%-0%-%d+%-%d+%-%d+%-(%d+)%-"))
        if npcID then PruneMobByNpcID(npcID) end

    elseif event == "VIGNETTES_UPDATED" then
        -- Prune loot alerts whose vignette has disappeared (chest looted by anyone nearby).
        if #SD.alertOrder == 0 then return end
        local activeGUIDs = {}
        if C_VignetteInfo and C_VignetteInfo.GetVignettes then
            for _, guid in ipairs(C_VignetteInfo.GetVignettes()) do
                activeGUIDs[guid] = true
            end
        end
        local changed = false
        for i = #SD.alertOrder, 1, -1 do
            local k = SD.alertOrder[i]
            local alert = SD.alertQueue[k]
            if alert and alert.type == "loot" and alert.vignetteGUID and not activeGUIDs[alert.vignetteGUID] then
                table.remove(SD.alertOrder, i)
                SD.alertQueue[k] = nil
                if SD.alertIndex >= i then
                    SD.alertIndex = math.max(0, SD.alertIndex - 1)
                end
                changed = true
            end
        end
        if changed then
            if #SD.alertOrder == 0 then SD.alertIndex = 0 end
            if horizon.ScheduleRefresh then horizon.ScheduleRefresh() end
        end
    end
end)

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
