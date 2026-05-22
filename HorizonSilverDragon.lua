--[[
    Horizon - SilverDragon
    Namespace, version, and DB access helpers.
    Requires HorizonSuite. SilverDragon is optional; gracefully absent.
]]

local horizon = _G.HorizonSuite
if not horizon then return end

-- ============================================================================
-- NAMESPACE
-- ============================================================================

local SD = {}
_G.HorizonSilverDragon = SD

SD.ADDON_NAME = "Horizon-SilverDragon"
SD.VERSION    = "1.0.0"
SD.DB_PREFIX  = "sd_"

-- ============================================================================
-- DB HELPERS (stored inside HorizonSuite's HorizonDB via its GetDB/SetDB)
-- ============================================================================

--- Read a setting from HorizonSuite's DB under the sd_ namespace.
--- @param key string
--- @param default any
--- @return any
function SD.GetDB(key, default)
    return horizon.GetDB(SD.DB_PREFIX .. key, default)
end

--- Write a setting into HorizonSuite's DB under the sd_ namespace.
--- @param key string
--- @param value any
function SD.SetDB(key, value)
    horizon.SetDB(SD.DB_PREFIX .. key, value)
end

-- ============================================================================
-- ALERT QUEUE STATE
-- Populated by HorizonSilverDragonEvents and consumed by HorizonSilverDragonProvider.
-- Initialized here so Provider and Module can safely read them before Events loads.
-- ============================================================================

SD.alertQueue = {}  -- [npcID] = alertData
SD.alertOrder = {}  -- ordered list of npcIDs (insertion order)
SD.alertIndex = 0   -- 1-based index into alertOrder for current display
