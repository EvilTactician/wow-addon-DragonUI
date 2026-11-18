-- Licensed under the MIT License; see LICENSE.

local addon = select(2, ...)
local TM = addon.TalentModule
local ns = TM.ns

-- Public talent-build API for other addons (e.g. JournalGearBIS saving its recommended builds).
-- Kept small and stable on purpose: callers rely on DragonUI.API, never on DragonUI's internals.
-- Saved builds land in the same storage as imported ones, so they can be renamed, edited,
-- deleted, shared and followed as a plan like any other.

local floor, min, max = math.floor, math.min, math.max

local NAME_LIMIT = 40
local INDEX_LIMIT = 255

addon.API = addon.API or {}
local API = addon.API
API.version = 1

-- Cut to `limit` bytes without splitting a UTF-8 character.
local function cutName(text, limit)
    if #text <= limit then return text end
    local cut = limit
    while cut > 0 do
        local byte = text:byte(cut + 1)
        if not byte or byte < 128 or byte >= 192 then break end
        cut = cut - 1
    end
    return text:sub(1, cut)
end

local function readName(raw)
    if type(raw) ~= "string" then return nil end
    local name = ns.Trim(cutName(ns.Trim(ns.Scrub(raw)), NAME_LIMIT))
    if name == "" then return nil end
    return name
end

-- Clamped like a build code's level: 10 to the level cap; nil when absent or not a number.
local function readLevel(raw)
    local level = tonumber(raw)
    if not level or level ~= level then return nil end
    return min(ns.LevelCap(), max(10, floor(level)))
end

local function isWhole(value)
    return type(value) == "number" and value == value and value == floor(value)
end

-- A fresh copy of the caller's ranks, or nil plus a reason. A rank of 0 is the same as absent.
local function readRanks(raw)
    if type(raw) ~= "table" then return nil, "ranks must be a table" end
    local ranks, total = { {}, {}, {} }, 0
    for tree, list in pairs(raw) do
        if not isWhole(tree) or tree < 1 or tree > 3 then return nil, "ranks has more than 3 trees" end
        if type(list) ~= "table" then return nil, "a tree's ranks must be a table" end
        for index, rank in pairs(list) do
            if not isWhole(index) or index < 1 or index > INDEX_LIMIT then
                return nil, "a talent index is not a whole number"
            end
            if not isWhole(rank) or rank < 0 or rank > 9 then
                return nil, "a rank is not a whole number from 1 to 9"
            end
            if rank > 0 then
                ranks[tree][index] = rank
                total = total + rank
            end
        end
    end
    if total < 1 then return nil, "no points" end
    if total > ns.PointCeiling() then return nil, "too many points" end
    return ranks
end

local function sameRanks(a, b)
    for tree = 1, 3 do
        local left, right = type(a[tree]) == "table" and a[tree] or {}, type(b[tree]) == "table" and b[tree] or {}
        for index, rank in pairs(left) do
            if (tonumber(rank) or 0) ~= (tonumber(right[index]) or 0) then return false end
        end
        for index, rank in pairs(right) do
            if (tonumber(rank) or 0) ~= (tonumber(left[index]) or 0) then return false end
        end
    end
    return true
end

local function findBuild(classToken, name, ranks)
    for _, build in ipairs(ns.BuildBucket(classToken)) do
        if build.name == name and type(build.ranks) == "table" and sameRanks(build.ranks, ranks) then
            return true
        end
    end
    return false
end

-- Own-class builds are stored after fitting them to the live trees (ranks above a talent's maximum
-- are lowered), so a repeat call is compared in that form too, not only as given.
local function fittedRanks(classToken, ranks)
    if classToken ~= ns.PlayerClass() then return nil end
    local data = ns.TreeData()
    if not data then return nil end
    local copy = { ranks = { {}, {}, {} } }
    for tree = 1, 3 do
        for index, rank in pairs(ranks[tree] or {}) do copy.ranks[tree][index] = rank end
    end
    ns.NormalizeBuild(copy, data)
    return copy.ranks
end

-- True when that class already has a stored build with this exact name and these exact ranks.
function API.HasTalentBuild(classToken, name, ranks)
    if type(classToken) ~= "string" or not ns.KNOWN_CLASS[classToken] then return false end
    local cleanName = readName(name)
    local cleanRanks = cleanName and readRanks(ranks)
    if not cleanRanks then return false end
    if findBuild(classToken, cleanName, cleanRanks) then return true end
    local fitted = fittedRanks(classToken, cleanRanks)
    return fitted ~= nil and findBuild(classToken, cleanName, fitted)
end

-- ranks: { [tree] = { [talent index] = rank } }, by GetTalentInfo's index order: the same as a build's ranks.
-- Returns "saved", "exists", or nil plus a short reason.
function API.SaveTalentBuild(classToken, name, ranks, reqLevel)
    if type(classToken) ~= "string" or not ns.KNOWN_CLASS[classToken] then
        return nil, "not a known class"
    end
    local cleanName = readName(name)
    if not cleanName then return nil, "no name" end
    local cleanRanks, reason = readRanks(ranks)
    if not cleanRanks then return nil, reason end

    if API.HasTalentBuild(classToken, cleanName, cleanRanks) then
        return "exists"
    end
    -- KeepBuild shows the usual "Build saved" notice; no editor, the player is in another window.
    local record = ns.KeepBuild({
        class = classToken,
        name = cleanName,
        ranks = cleanRanks,
        reqLevel = readLevel(reqLevel),
    })
    if record then return "saved" end
    return nil, "doesn't fit your talent trees"
end
