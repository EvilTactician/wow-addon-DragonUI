-- Copyright (c) 2026 NeticSoul. Licensed under the MIT License; see LICENSE.

local addon = select(2, ...)
local NP = addon.Nameplates
local C = NP.const

-- Nameplates threat: glow and aggro bar tint.

NP.threat = NP.threat or {}

function NP.threat.IsThreatPlate(plateData)
    if not plateData then
        return false
    end
    local reaction, unitType = NP.native_style.GetPlateReaction(plateData)
    if not reaction or reaction == "FRIENDLY" then
        return false
    end
    -- Players have no threat table (status stays 0), so DPS/tank tints would only bury the class color.
    return not (unitType == "PLAYER" and plateData.classKey ~= nil)
end

function NP.threat.GetAggroStatus(threat)
    if not threat or not threat.GetVertexColor then
        return 0
    end
    if threat.IsShown and not threat:IsShown() then
        return 0
    end
    local r, g, _ = threat:GetVertexColor()
    if not r or r == 0 then
        return 0
    end
    if g and g < 0.5 then
        return 3
    end
    if g and g < 0.9 then
        return 2
    end
    return 1
end

-- Suppress in arena; native threat vs players is misleading.
function NP.threat.IsThreatSuppressedContext()
    return NP.module.inArena == true
end

-- With unit token: UnitDetailedThreatSituation; else native glow color buckets.
-- Memoize per tick; threat tint/glow/scan share unit resolution.
function NP.threat.ResolveAggroStatus(plateData)
    if not plateData then
        return 0
    end
    local tick = NP.module._engineFrame
    if tick and plateData._aggroStatusTick == tick then
        return plateData._aggroStatus
    end
    local status
    local unit = NP.identity and NP.identity.ResolvePlateCastUnit
        and NP.identity.ResolvePlateCastUnit(plateData)
    if unit and UnitExists(unit) and not UnitIsUnit(unit, "player") and UnitDetailedThreatSituation then
        local _, detailed = UnitDetailedThreatSituation("player", unit)
        if detailed ~= nil then
            status = detailed
        end
    end
    if status == nil then
        status = NP.threat.GetAggroStatus(plateData.threat)
    end
    if tick then
        plateData._aggroStatusTick = tick
        plateData._aggroStatus = status
    end
    return status
end

function NP.threat.IsTankMode()
    return NP.config.GetCfg().tankMode == true
end

-- Mutually exclusive with tankMode; tank wins if both are somehow true.
function NP.threat.IsDpsMode()
    local cfg = NP.config.GetCfg()
    return cfg.dpsMode == true and cfg.tankMode ~= true
end

-- Tank "lost aggro" only when the hostile is already engaged (needs unit token).
local function ResolveTankLostColor(plateData)
    local unit = NP.identity and NP.identity.ResolvePlateCastUnit
        and NP.identity.ResolvePlateCastUnit(plateData)
    if unit and UnitExists(unit) and UnitAffectingCombat(unit) then
        return C.AGGRO_COLORS.tankLost
    end
    return nil
end

-- Any aggro warns; tank: holding is safe; DPS: LOW/MEDIUM/HIGH = green/yellow/red, no token gate.
local function ResolveAggroColor(plateData, status)
    if NP.threat.IsDpsMode() then
        if status >= 3 then
            return C.AGGRO_COLORS.dpsDanger
        elseif status >= 1 then
            return C.AGGRO_COLORS.dpsWarning
        end
        return C.AGGRO_COLORS.dpsSafe
    end
    if status <= 0 then
        if NP.threat.IsTankMode() then
            return ResolveTankLostColor(plateData)
        end
        return nil
    end
    if NP.threat.IsTankMode() then
        if status == 3 then
            return C.AGGRO_COLORS.tankHolding
        elseif status == 2 then
            return C.AGGRO_COLORS.tankWarning
        end
        return nil
    end
    if NP.config.IsRetailSkin() and NP.config.GetCfg().retailThreatColors ~= false then
        return status == 3 and C.AGGRO_COLORS_RETAIL.tanking or C.AGGRO_COLORS_RETAIL.warning
    end
    if status == 3 then
        return C.AGGRO_COLORS.tanking
    elseif status == 2 then
        return C.AGGRO_COLORS.losing
    end
    return C.AGGRO_COLORS.gaining
end

-- Combat-only aggro bar tint; nil out of combat or with no threat status.
function NP.threat.GetAggroBarTint(plateData)
    if not NP.module.playerInCombat or NP.threat.IsThreatSuppressedContext()
        or not NP.threat.IsThreatPlate(plateData) then
        return nil
    end
    local status = NP.threat.ResolveAggroStatus(plateData)
    local c = ResolveAggroColor(plateData, status)
    if not c then
        return nil
    end
    return c[1], c[2], c[3]
end

function NP.threat.ApplyThreatGlow(plateData)
    local cfg = NP.config.GetCfg()
    if cfg.threatGlow == false then
        if plateData.minaThreatTex then
            plateData.minaThreatTex:Hide()
        end
        return
    end

    local threat = plateData.threat
    local glow = plateData.minaThreatTex
    local hp = plateData.minaHp
    if not threat or not glow or not hp then return end

    -- Modern style draws threat as retail's scrolling aggro flare instead (retail_chrome).
    -- Driven from here so it tracks threat transitions, not just target changes.
    if NP.config.IsRetailSkin() then
        glow:Hide()
        if threat.SetTexCoord then
            threat:SetTexCoord(0, 0, 0, 0)
        end
        if NP.retail_chrome and NP.retail_chrome.SyncFlare then
            NP.retail_chrome.SyncFlare(plateData)
        end
        return
    end

    -- Blizzard may restore threat texcoords on aggro change.
    if threat.SetTexCoord then
        threat:SetTexCoord(0, 0, 0, 0)
    end

    local inCombat = NP.module.playerInCombat and true or false
    if not inCombat or NP.threat.IsThreatSuppressedContext()
        or not NP.threat.IsThreatPlate(plateData) then
        glow:Hide()
        return
    end

    local status = NP.threat.ResolveAggroStatus(plateData)
    local c = ResolveAggroColor(plateData, status)
    if c then
        glow:SetVertexColor(c[1], c[2], c[3], 0.75)
        glow:SetAlpha(plateData._lastAppliedVisualAlpha or 1.0)
        glow:Show()
    else
        glow:Hide()
    end
end

-- Threat text: the tooltip's number, plus the tank's lead over the next unit.

-- Group tokens built once, so the lead scan allocates nothing.
local PARTY_THREAT_UNITS = { "pet" }
for i = 1, 4 do
    PARTY_THREAT_UNITS[#PARTY_THREAT_UNITS + 1] = "party" .. i
    PARTY_THREAT_UNITS[#PARTY_THREAT_UNITS + 1] = "partypet" .. i
end
local RAID_THREAT_UNITS = {}
for i = 1, 40 do
    RAID_THREAT_UNITS[#RAID_THREAT_UNITS + 1] = "raid" .. i
    RAID_THREAT_UNITS[#RAID_THREAT_UNITS + 1] = "raidpet" .. i
end

-- Updates per plate per second; the threat list itself only moves on server ticks.
local THREAT_TEXT_INTERVAL = 0.2
-- Below the tank: yellow while safe, orange from this share of the pull threshold.
local THREAT_TEXT_WARN_PCT = 80
local THREAT_TEXT_COLORS = {
    tanking = { 1.0, 0.1, 0.1 },
    warning = { 1.0, 0.5, 0.0 },
    safe = { 1.0, 0.85, 0.1 },
}

-- Highest raw threat any other group member or pet holds on `unit`.
local function NextHighestThreat(unit)
    local units, count
    local raid = GetNumRaidMembers()
    if raid > 0 then
        units, count = RAID_THREAT_UNITS, raid * 2
    else
        units, count = PARTY_THREAT_UNITS, 1 + GetNumPartyMembers() * 2
    end
    local best = 0
    for i = 1, count do
        local member = units[i]
        if UnitExists(member) and not UnitIsUnit(member, "player") then
            local _, _, _, _, value = UnitDetailedThreatSituation(member, unit)
            if value and value > best then
                best = value
            end
        end
    end
    return best
end

local function HideThreatText(plateData)
    local text = plateData.minaThreatText
    if text and plateData._threatTextShown ~= false then
        plateData._threatTextShown = false
        plateData._threatTextValue = nil
        -- After the name its width shortens the name, so hidden text must also be empty.
        text:SetText("")
        text:Hide()
    end
end

-- Not tanking: the tooltip's number (100% = you pull). Tanking: your threat over the next
-- unit's, so 135% is a 35% lead. Only plates matched to a unit have live data; others hide.
function NP.threat.SyncThreatText(plateData, force)
    local text = plateData and plateData.minaThreatText
    if not text then return end
    local plate = plateData.plate
    if not NP.module._threatTextEnabled or not NP.module.playerInCombat
        or not (plate and plate:IsShown())
        or NP.threat.IsThreatSuppressedContext() or not NP.threat.IsThreatPlate(plateData)
        or NP.gather.IsHeadlineActive(plateData) or NP.gather.IsTotemIconOnlyActive(plateData) then
        HideThreatText(plateData)
        return
    end
    local now = GetTime()
    if not force and plateData._threatTextAt and now < plateData._threatTextAt then
        return
    end
    plateData._threatTextAt = now + THREAT_TEXT_INTERVAL

    local unit = NP.identity.ResolvePlateCastUnit(plateData)
    if not unit or not UnitExists(unit) or UnitIsUnit(unit, "player") then
        HideThreatText(plateData)
        return
    end
    local isTanking, _, scaled, _, value = UnitDetailedThreatSituation("player", unit)
    if not scaled then
        -- Not on its threat list.
        HideThreatText(plateData)
        return
    end
    local pct, color
    if isTanking then
        local second = NextHighestThreat(unit)
        pct = (second > 0 and value) and (value / second * 100) or scaled
        color = THREAT_TEXT_COLORS.tanking
    else
        pct = scaled
        color = scaled >= THREAT_TEXT_WARN_PCT and THREAT_TEXT_COLORS.warning or THREAT_TEXT_COLORS.safe
    end
    pct = math.floor(pct + 0.5)

    if plateData._threatTextValue ~= pct or plateData._threatTextColor ~= color
        or plateData._threatTextShown ~= true then
        plateData._threatTextValue, plateData._threatTextColor = pct, color
        plateData._threatTextShown = true
        text:SetText(pct .. "%")
        text:SetTextColor(color[1], color[2], color[3])
        text:Show()
    end
end

NP.widgets.Register("ThreatText", {
    Ensure = function(plateData)
        return plateData and plateData.minaThreatText ~= nil
    end,
    Layout = function(plateData)
        return plateData and plateData.minaHp ~= nil
    end,
    Sync = function(plateData)
        NP.threat.SyncThreatText(plateData)
    end,
    Hide = function(plateData)
        if plateData then
            HideThreatText(plateData)
        end
    end,
})

NP.widgets.Register("ThreatGlow", {
    Ensure = function(plateData)
        return plateData and plateData.minaThreatTex ~= nil
    end,
    Layout = function(plateData)
        return plateData and plateData.minaHp ~= nil
    end,
    Sync = function(plateData)
        NP.threat.ApplyThreatGlow(plateData)
    end,
    Hide = function(plateData)
        if plateData and plateData.minaThreatTex then
            plateData.minaThreatTex:Hide()
        end
    end,
})
