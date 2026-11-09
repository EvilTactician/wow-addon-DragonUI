-- Copyright (c) 2026 NeticSoul. Licensed under the MIT License; see LICENSE.

local addon = select(2, ...)

local label

local function enabled()
    local settings = addon.db and addon.db.profile.minimap
    return settings and settings.ping_sender ~= false and addon:IsModuleEnabled("minimap")
end

local function onPing(_, _, unit)
    if not (unit and enabled()) or UnitIsUnit(unit, "player") then
        if label then label:SetText("") end
        return
    end
    if not label then
        -- On the ping itself, so it fades and hides along with it.
        label = MinimapPing:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOP", MinimapPing, "CENTER", 0, -12)
    end
    local _, class = UnitClass(unit)
    local color = class and RAID_CLASS_COLORS[class] or NORMAL_FONT_COLOR
    label:SetText(UnitName(unit))
    label:SetTextColor(color.r, color.g, color.b)
end

local events = CreateFrame("Frame")
events:RegisterEvent("MINIMAP_PING")
events:SetScript("OnEvent", onPing)

-- 3.3.5 places the ping once and leaves it, so it slid along with the player. The client still
-- tracks the pinged spot, so the ping follows it each frame as older clients' Minimap_OnUpdate did.
MinimapPing:HookScript("OnUpdate", function(self)
    if not (((self.timer or 0) > 0 or self.fadeOut) and addon:IsModuleEnabled("minimap")) then return end
    local x, y = Minimap:GetPingPosition()
    x, y = x * Minimap:GetWidth(), y * Minimap:GetHeight()
    -- Same edge rule as Minimap_SetPing: off the minimap it hides rather than sit on the border.
    if sqrt(x * x + y * y) < Minimap:GetWidth() / 2 then
        self:SetPoint("CENTER", Minimap, "CENTER", x, y)
    else
        self:Hide()
    end
end)
