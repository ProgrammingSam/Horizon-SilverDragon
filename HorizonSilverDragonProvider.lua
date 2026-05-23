--[[
    Horizon - SilverDragon - Provider
    Builds normalized Focus entry tables from the active SilverDragon alert
    and registers itself with HorizonSuite's external entry provider system.
]]

local horizon = _G.HorizonSuite
local SD      = _G.HorizonSilverDragon
if not horizon or not SD then return end

-- ============================================================================
-- ENTRY BUILDER
-- ============================================================================

--- Return the Focus entry list for the current active SilverDragon alert.
--- Returns an empty table when the module is disabled, the integration is
--- toggled off, or no alert is active.
--- @return table
local function CollectSilverDragonEntries()
    if not horizon.GetDB("sd_enabled", false) then return {} end

    if #SD.alertOrder == 0 or SD.alertIndex == 0 then return {} end
    local npcID = SD.alertOrder[SD.alertIndex]
    local alert = npcID and SD.alertQueue[npcID]
    if not alert then return {} end

    local color = horizon.GetQuestColor and horizon.GetQuestColor("SILVERDRAGON")
                  or { r = 0.96, g = 0.56, b = 0.08 }

    local objectives = {}

    if horizon.GetDB("sd_showCoords", true) and alert.x and alert.y then
        objectives[#objectives + 1] = {
            text     = ("%.1f, %.1f"):format(alert.x * 100, alert.y * 100),
            finished = false,
            noBullet = true,
            sdCoord  = true,
        }
    end

    if horizon.GetDB("sd_showSeenAgo", true) and alert.seenAt then
        local text = horizon.FormatTimeAgo and horizon.FormatTimeAgo(alert.seenAt)
        if text then
            objectives[#objectives + 1] = { text = text, finished = false, noBullet = true, rareSeenAgo = true }
        end
    end

    return {
        {
            entryKey       = "silverdragon:" .. tostring(alert.npcID),
            questID        = nil,
            title          = alert.name or ("NPC #" .. tostring(alert.npcID)),
            objectives     = objectives,
            color          = color,
            category       = "SILVERDRAGON",
            isComplete     = false,
            isSuperTracked = false,
            isNearby       = true,
            isRare         = true,
            creatureID     = tonumber(alert.npcID),
            vignetteMapID  = alert.mapID,
            vignetteX      = alert.x,
            vignetteY      = alert.y,
            zoneName       = alert.zoneName,
            sdIsDead       = alert.is_dead,
            sdSource       = alert.source,
            sdAlertIndex   = SD.alertIndex,
            sdAlertTotal   = #SD.alertOrder,
            vignetteAtlas  = "VignetteKillElite",
            noEntryNumber  = true,
        },
    }
end

-- ============================================================================
-- REGISTRATION
-- ============================================================================

if horizon.RegisterFocusEntryProvider then
    horizon.RegisterFocusEntryProvider(CollectSilverDragonEntries)
end
