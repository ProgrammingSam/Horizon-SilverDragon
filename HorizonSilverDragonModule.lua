--[[
    Horizon - SilverDragon - Module
    Registers HorizonSilverDragon as a named sub-module of HorizonSuite's Focus
    module and exposes SetWaypoint for TomTom-aware waypoint setting.
]]

local horizon = _G.HorizonSuite
local SD      = _G.HorizonSilverDragon
if not horizon or not SD then return end

-- ============================================================================
-- MODULE REGISTRATION
-- ============================================================================

if not horizon.focus then horizon.focus = {} end
local sd = {}
horizon.focus.sd = sd

-- ============================================================================
-- WAYPOINT
-- ============================================================================

--- Set a waypoint for the given entry, preferring TomTom when sd_useTomTom is on.
--- @param entry table  { title, vignetteMapID, vignetteX, vignetteY }
function sd.SetWaypoint(entry)
    local mapID = entry.vignetteMapID
    local x, y  = entry.vignetteX, entry.vignetteY
    local name  = entry.title or "Rare"
    if not mapID or not x or not y then return end
    if horizon.GetDB("sd_useTomTom", false) then
        local TomTom = rawget(_G, "TomTom")
        if TomTom and TomTom.AddWaypoint then
            pcall(TomTom.AddWaypoint, TomTom, mapID, x, y,
                { title = name, persistent = false, minimap = true, world = true, crazy = true })
            return
        end
    end
    if C_Map and C_Map.SetUserWaypoint and UiMapPoint then
        local uiMapPoint = UiMapPoint.CreateFromCoordinates(mapID, x, y)
        if uiMapPoint then
            pcall(C_Map.SetUserWaypoint, uiMapPoint)
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
            end
        end
    end
end
