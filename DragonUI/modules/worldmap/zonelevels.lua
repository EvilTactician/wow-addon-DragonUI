-- Copyright (c) 2026 NeticSoul. Licensed under the MIT License; see LICENSE.

local addon = select(2, ...)
local WM = addon.WorldMap
local L = addon.L

-- AreaTable.dbc carries one exploration level and no range, so this list is kept by hand.
-- Keyed by GetMapInfo()'s map file, like fogdata and graveyarddata. Cities are left out on purpose.
WM.ZoneLevels = {
    ["Elwynn"] = { 1, 10 }, ["DunMorogh"] = { 1, 10 }, ["Tirisfal"] = { 1, 10 },
    ["Durotar"] = { 1, 10 }, ["Mulgore"] = { 1, 10 }, ["Teldrassil"] = { 1, 10 },
    ["EversongWoods"] = { 1, 10 }, ["AzuremystIsle"] = { 1, 10 },
    ["Westfall"] = { 10, 20 }, ["LochModan"] = { 10, 20 }, ["Silverpine"] = { 10, 20 },
    ["Darkshore"] = { 10, 20 }, ["Ghostlands"] = { 10, 20 }, ["BloodmystIsle"] = { 10, 20 },
    ["Barrens"] = { 10, 25 }, ["Redridge"] = { 15, 25 }, ["StonetalonMountains"] = { 15, 27 },
    ["Ashenvale"] = { 18, 30 }, ["Duskwood"] = { 18, 30 }, ["Hilsbrad"] = { 20, 30 },
    ["Wetlands"] = { 20, 30 }, ["ThousandNeedles"] = { 25, 35 },
    ["Alterac"] = { 30, 40 }, ["Arathi"] = { 30, 40 }, ["Desolace"] = { 30, 40 },
    ["Stranglethorn"] = { 30, 45 }, ["Badlands"] = { 35, 45 },
    ["SwampOfSorrows"] = { 35, 45 }, ["Dustwallow"] = { 35, 45 },
    ["Hinterlands"] = { 40, 50 }, ["Feralas"] = { 40, 50 }, ["Tanaris"] = { 40, 50 },
    ["SearingGorge"] = { 43, 50 }, ["BlastedLands"] = { 45, 55 }, ["Aszhara"] = { 45, 55 },
    ["Felwood"] = { 48, 55 }, ["UngoroCrater"] = { 48, 55 },
    ["BurningSteppes"] = { 50, 58 }, ["WesternPlaguelands"] = { 51, 58 },
    ["EasternPlaguelands"] = { 53, 60 }, ["ScarletEnclave"] = { 55, 58 },
    ["DeadwindPass"] = { 55, 60 }, ["Silithus"] = { 55, 60 },
    ["Winterspring"] = { 55, 60 }, ["Moonglade"] = { 55, 60 },
    ["Hellfire"] = { 58, 63 }, ["Zangarmarsh"] = { 60, 64 }, ["TerokkarForest"] = { 62, 65 },
    ["Nagrand"] = { 64, 67 }, ["BladesEdgeMountains"] = { 65, 68 },
    ["Netherstorm"] = { 67, 70 }, ["ShadowmoonValley"] = { 67, 70 }, ["Sunwell"] = { 70, 70 },
    ["BoreanTundra"] = { 68, 72 }, ["HowlingFjord"] = { 68, 72 },
    ["Dragonblight"] = { 71, 75 }, ["GrizzlyHills"] = { 73, 75 }, ["ZulDrak"] = { 74, 77 },
    ["SholazarBasin"] = { 76, 78 }, ["CrystalsongForest"] = { 77, 80 },
    ["TheStormPeaks"] = { 77, 80 }, ["IcecrownGlacier"] = { 77, 80 },
    ["HrothgarsLanding"] = { 77, 80 }, ["LakeWintergrasp"] = { 77, 80 },
}

local function difficultyHex(level)
    local color = GetQuestDifficultyColor(level)
    return string.format("|cff%02x%02x%02x", math.floor(color.r * 255 + 0.5),
        math.floor(color.g * 255 + 0.5), math.floor(color.b * 255 + 0.5))
end

local function rangeText(minLevel, maxLevel)
    if maxLevel and maxLevel > minLevel then
        return string.format(LFD_LEVEL_FORMAT_RANGE, minLevel, maxLevel)
    end
    return string.format(LFD_LEVEL_FORMAT_SINGLE, minLevel)
end

function WM.ZoneLevelSuffix(mapFile)
    if WM:Config().zoneLevels == false then return "" end
    local range = mapFile and WM.ZoneLevels[mapFile]
    if not range then return "" end
    return " " .. difficultyHex(range[2]) .. rangeText(range[1], range[2]) .. "|r"
end

-- An expansion's top level: a raid reads that single level, and nothing reads above it.
local TOP_LEVEL = { [0] = 60, [1] = 70, [2] = 80 }
local LEVEL_CEILING = 80

-- "Level 25-36", "Level 60", as the Journal writes them.
local function journalRange(minLevel, maxLevel)
    if maxLevel and maxLevel > minLevel then
        return string.format(L["Level %d-%d"], minLevel, maxLevel)
    end
    return string.format(L["Level %d"], minLevel)
end

-- One version (Onyxia and Naxxramas have a 40 player Classic one and a Wrath one), coloured by
-- its best level for dungeons ("~31", or the low end of "~32-40") and its single level for raids.
local function versionText(version, labelPlayers)
    local minLevel = math.min(tonumber(version.minLevel) or 0, LEVEL_CEILING)
    local maxLevel = math.min(tonumber(version.maxLevel) or minLevel, LEVEL_CEILING)
    if minLevel <= 0 then return nil end
    local text, colourLevel
    if version.raid then
        local level = math.max(minLevel, maxLevel)
        text, colourLevel = journalRange(level, level), level
    else
        text = journalRange(minLevel, maxLevel)
        if version.best then
            text = text .. string.format(L[", best %s"], version.best)
            colourLevel = tonumber(tostring(version.best):match("(%d+)"))
        end
        colourLevel = math.min(colourLevel or maxLevel, LEVEL_CEILING)
    end
    if labelPlayers and version.players then
        text = text .. " " .. string.format(L["(%d player)"], version.players)
    end
    return difficultyHex(colourLevel) .. text .. "|r"
end

-- The Journal (Journal.API 3) works the levels out from the realm's own bosses and quests, so with
-- it loaded the map reads the same numbers as its tiles. Nil when it isn't there or hasn't loaded yet.
local function journalLevelText(lfgID)
    local journal = _G.Journal
    if type(journal) ~= "table" or (tonumber(journal.API) or 0) < 3 or type(journal.InstanceLevels) ~= "function" then
        return nil
    end
    local ok, versions = pcall(journal.InstanceLevels, lfgID)
    if not ok or type(versions) ~= "table" or #versions == 0 then return nil end
    local parts = {}
    for i, version in ipairs(versions) do
        -- Only the older version is named by its size: "Level 60 (40 player), Level 80".
        local part = versionText(version, #versions > 1 and i < #versions)
        if part then parts[#parts + 1] = part end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

-- Not minLevel/maxLevel: those are the gate to enter, so every level-cap raid reads "70 - 83". The
-- recommended band is what the instance was built for, capped because its top runs past the cap too.
-- A raid reads its expansion's top level alone.
local function lfgLevelText(lfgID, isRaid)
    local _, _, _, _, recLevel, minLevel, maxLevel, expansion = GetLFGDungeonInfo(lfgID)
    if isRaid and TOP_LEVEL[expansion] then
        local level = TOP_LEVEL[expansion]
        return difficultyHex(level) .. journalRange(level, level) .. "|r"
    end
    if not minLevel or minLevel <= 0 then
        if not recLevel or recLevel <= 0 then return end
        recLevel = math.min(recLevel, LEVEL_CEILING)
        return rangeText(recLevel, recLevel)
    end
    local cap = (MAX_PLAYER_LEVEL or 0) > 0 and math.min(MAX_PLAYER_LEVEL, LEVEL_CEILING) or LEVEL_CEILING
    if maxLevel and maxLevel > cap then maxLevel = cap end
    if minLevel > cap then minLevel = cap end
    if maxLevel and maxLevel < minLevel then maxLevel = minLevel end
    return rangeText(minLevel, maxLevel)
end

function WM.DungeonLevelText(lfgID, isRaid)
    if not lfgID or WM:Config().zoneLevels == false then return end
    return journalLevelText(lfgID) or lfgLevelText(lfgID, isRaid)
end

-- The Journal answers from the realm after login, and again when its list reloads: redraw the pins
-- then, so the map doesn't keep the fallback text. It loads after DragonUI (it lists us as an
-- optional dependency), so this hooks in at login. Registering also asks it to load its list.
local journalHook = CreateFrame("Frame")
journalHook:RegisterEvent("PLAYER_LOGIN")
journalHook:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    local journal = _G.Journal
    if type(journal) ~= "table" or (tonumber(journal.API) or 0) < 3 or type(journal.OnInstanceLevels) ~= "function" then
        return
    end
    journal.OnInstanceLevels(function()
        if WM.RefreshMapPins and WorldMapFrame and WorldMapFrame:IsShown() then WM.RefreshMapPins() end
    end)
end)
