-- Licensed under the MIT License; see LICENSE.

local addon = select(2, ...)
local NP = addon.Nameplates
local C = NP.const

-- Heal prediction, absorb shields and missing health on your target's nameplate.
-- The target's plate is the only one 3.3.5 lets us tie to a unit for certain, so all the work
-- is for one plate: painted when its health ticks, when a heal or shield on the target changes,
-- and when the target changes. Uses the heal and absorb libraries the unit frames already load.

NP.targetheals = NP.targetheals or {}
local H = NP.targetheals

local ART = "Interface\\AddOns\\DragonUI\\Textures\\UnitFrames\\Layers\\"
local FILL = C.MINA_TEX .. "bar-fill"
local PREDICT_HORIZON = 5

local current           -- plate data of the target's plate, while one is shown
local healLib, absorbLib
local predictOn, missingOn = false, false

local function Libraries()
    if healLib == nil and type(LibStub) == "table" then
        healLib = LibStub:GetLibrary("LibHealComm-4.0", true) or false
        absorbLib = LibStub:GetLibrary("AbsorbsMonitor-1.0", true) or false
    end
end

-- =============================================================================
-- WIDGETS
-- =============================================================================

local function Ensure(plateData)
    local layers = plateData.minaHeals
    if layers then return layers end
    local bar = plateData.minaHp
    if not bar then return nil end

    -- Above the fill, below the bar border (bar level + 2).
    local holder = CreateFrame("Frame", nil, bar)
    holder:SetAllPoints(bar)
    holder:SetFrameLevel(bar:GetFrameLevel() + 1)
    holder:EnableMouse(false)

    local function layer(drawLayer, path, r, g, b)
        local tex = holder:CreateTexture(nil, drawLayer)
        tex:SetTexture(path)
        if r then tex:SetVertexColor(r, g, b) end
        tex:Hide()
        return tex
    end

    layers = { holder = holder }
    -- Same colours as the unit frames: your own heals brighter than everyone else's.
    layers.mine = layer("BORDER", FILL, 0.0, 0.827, 0.765)
    layers.other = layer("BORDER", FILL, 0.0, 0.631, 0.557)
    layers.absorb = layer("ARTWORK", ART .. "Shield-Fill")
    layers.overshield = layer("OVERLAY", ART .. "Shield-Overshield")
    layers.overshield:SetBlendMode("ADD")
    layers.overshield:SetPoint("TOPLEFT", holder, "TOPRIGHT", -7, 0)
    layers.overshield:SetPoint("BOTTOMLEFT", holder, "BOTTOMRIGHT", -7, 0)
    layers.overshield:SetWidth(16)

    local missing = holder:CreateFontString(nil, "OVERLAY")
    local font = NP.config.GetNameplateFont and NP.config.GetNameplateFont() or STANDARD_TEXT_FONT
    missing:SetFont(font, 9, "OUTLINE")
    missing:SetTextColor(1, 0.25, 0.25)
    missing:SetPoint("LEFT", holder, "RIGHT", 4, 0)
    missing:Hide()
    layers.missing = missing

    plateData.minaHeals = layers
    return layers
end

local function HideLayers(plateData)
    local layers = plateData and plateData.minaHeals
    if not layers then return end
    layers.mine:Hide()
    layers.other:Hide()
    layers.absorb:Hide()
    layers.overshield:Hide()
    layers.missing:Hide()
end

-- From the bar's left edge, `offset` to `offset + width` (both fractions of the bar).
local function Place(tex, holder, offset, width, barWidth)
    if width <= 0 then
        tex:Hide()
        return
    end
    tex:ClearAllPoints()
    tex:SetPoint("TOPLEFT", holder, "TOPLEFT", offset * barWidth, 0)
    tex:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", offset * barWidth, 0)
    tex:SetWidth(width * barWidth)
    tex:SetTexCoord(offset, offset + width, 0, 1)
    tex:Show()
end

local function Abbreviate(value)
    if addon.TextSystem and addon.TextSystem.AbbreviateLargeNumbers then
        return addon.TextSystem.AbbreviateLargeNumbers(value)
    end
    return tostring(math.floor(value))
end

-- =============================================================================
-- PAINT
-- =============================================================================

function H.Paint(plateData)
    if plateData ~= current then return end
    local bar = plateData.minaHp
    local guid = UnitGUID("target")
    if not (bar and bar:IsShown() and guid) then
        HideLayers(plateData)
        return
    end
    local layers = Ensure(plateData)
    if not layers then return end

    local health, maxHealth = UnitHealth("target"), UnitHealthMax("target")
    if not maxHealth or maxHealth <= 0 or UnitIsDeadOrGhost("target") then
        HideLayers(plateData)
        return
    end
    local barWidth = bar:GetWidth()
    local _, barMax = bar:GetMinMaxValues()
    -- Start where the fill ends, from the bar's own values so the two always meet.
    local filled = (barMax and barMax > 0) and (bar:GetValue() / barMax) or (health / maxHealth)
    if filled > 1 then filled = 1 elseif filled < 0 then filled = 0 end
    local room = 1 - filled

    if predictOn then
        Libraries()
        local all, mine, shield = 0, 0, 0
        if healLib then
            local horizon = GetTime() + PREDICT_HORIZON
            all = healLib:GetHealAmount(guid, healLib.ALL_HEALS, horizon) or 0
            local me = UnitGUID("player")
            if me then
                mine = healLib:GetHealAmount(guid, healLib.CASTED_HEALS, horizon, me) or 0
            end
            local modifier = healLib:GetHealModifier(guid) or 1
            all, mine = all * modifier, mine * modifier
        end
        if absorbLib and absorbLib.Unit_Total then
            shield = absorbLib.Unit_Total(guid) or 0
        end
        if mine > all then mine = all end
        local mineW = math.min(mine / maxHealth, room)
        local otherW = math.min((all - mine) / maxHealth, room - mineW)
        local shieldW = math.min(shield / maxHealth, room - mineW - otherW)
        Place(layers.mine, layers.holder, filled, mineW, barWidth)
        Place(layers.other, layers.holder, filled + mineW, otherW, barWidth)
        Place(layers.absorb, layers.holder, filled + mineW + otherW, shieldW, barWidth)
        if shield > 0 and health + all + shield >= maxHealth then
            layers.overshield:Show()
        else
            layers.overshield:Hide()
        end
    else
        layers.mine:Hide()
        layers.other:Hide()
        layers.absorb:Hide()
        layers.overshield:Hide()
    end

    -- Missing health is for healing, so only on units you can't attack.
    local deficit = maxHealth - health
    if missingOn and deficit > 0 and not UnitCanAttack("player", "target") then
        layers.missing:SetText("-" .. Abbreviate(deficit))
        layers.missing:Show()
    else
        layers.missing:Hide()
    end
end

-- Called with each plate's target state when the target changes or a plate refreshes.
function H.SyncTarget(plateData, isTargeted)
    if isTargeted and (predictOn or missingOn) then
        if current and current ~= plateData then HideLayers(current) end
        current = plateData
        H.Paint(plateData)
    elseif current == plateData then
        current = nil
        HideLayers(plateData)
    elseif plateData.minaHeals then
        HideLayers(plateData)
    end
end

-- A recycled plate belongs to someone else now.
function H.Release(plateData)
    if current == plateData then current = nil end
    HideLayers(plateData)
end

function H.IsCurrent(plateData)
    return plateData == current
end

-- =============================================================================
-- LIBRARY CALLBACKS
-- =============================================================================

local listener = {}
local listening = false

local function RepaintIfTarget(guid)
    if current and guid and guid == UnitGUID("target") then
        H.Paint(current)
    end
end

local function OnHealTargeted(_, _, _, _, _, ...)
    for i = 1, select("#", ...) do
        RepaintIfTarget((select(i, ...)))
    end
end
local function OnGuid(_, guid) RepaintIfTarget(guid) end
local function OnAbsorbApplied(_, _, _, destGUID) RepaintIfTarget(destGUID) end

local HEAL_TARGET_EVENTS = { "HealComm_HealStarted", "HealComm_HealUpdated", "HealComm_HealDelayed", "HealComm_HealStopped" }
local HEAL_GUID_EVENTS = { "HealComm_ModifierChanged", "HealComm_GUIDDisappeared" }
local ABSORB_GUID_EVENTS = { "EffectUpdated", "EffectRemoved", "UnitUpdated", "UnitCleared", "AreaCreated", "AreaCleared" }

local function Listen(on)
    if on == listening then return end
    Libraries()
    listening = on
    if healLib and type(healLib.RegisterCallback) == "function" then
        for _, event in ipairs(HEAL_TARGET_EVENTS) do
            if on then healLib.RegisterCallback(listener, event, OnHealTargeted)
            else pcall(healLib.UnregisterCallback, listener, event) end
        end
        for _, event in ipairs(HEAL_GUID_EVENTS) do
            if on then healLib.RegisterCallback(listener, event, OnGuid)
            else pcall(healLib.UnregisterCallback, listener, event) end
        end
    end
    if absorbLib and type(absorbLib.RegisterCallback) == "function" then
        if on then absorbLib.RegisterCallback(listener, "EffectApplied", OnAbsorbApplied)
        else pcall(absorbLib.UnregisterCallback, listener, "EffectApplied") end
        for _, event in ipairs(ABSORB_GUID_EVENTS) do
            if on then absorbLib.RegisterCallback(listener, event, OnGuid)
            else pcall(absorbLib.UnregisterCallback, listener, event) end
        end
    end
end

-- Settings changed (engine refresh).
function H.Refresh(cfg)
    predictOn = NP.config.IsModuleEnabled() and cfg.targetHealPrediction == true
    missingOn = NP.config.IsModuleEnabled() and cfg.targetMissingHealth == true
    Listen(predictOn)
    if current then
        if predictOn or missingOn then
            H.Paint(current)
        else
            HideLayers(current)
            current = nil
        end
    end
end

-- The old target's plate lets go at once; the new one is found when the engine resolves it.
local targetWatch = CreateFrame("Frame")
targetWatch:RegisterEvent("PLAYER_TARGET_CHANGED")
targetWatch:SetScript("OnEvent", function()
    if current then
        HideLayers(current)
        current = nil
    end
end)

-- The friendly target marker used to switch friendly plates on itself; that is now its own
-- setting, so profiles that had it keep it.
addon.package:Subscribe(function()
    local cfg = NP.config.GetCfg()
    if cfg.targetMarkerFriendly ~= nil then
        if cfg.targetMarkerFriendly == true and cfg.showTargetMarker == true then
            cfg.friendlyTargetPlate = true
        end
        cfg.targetMarkerFriendly = nil
    end
end, "PLAYER_LOGIN")
