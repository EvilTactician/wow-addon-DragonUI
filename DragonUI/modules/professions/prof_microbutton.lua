-- Copyright (c) 2026 NeticSoul. Licensed under the MIT License; see LICENSE.

local addon = select(2, ...)

-- micromenu.lua captures its button list at file scope, so modules.xml loads this before it.
if _G.ProfessionMicroButton then return end

local ICON = addon._dir .. "Professions\\MicroButton"

local btn = CreateFrame("Button", "ProfessionMicroButton", UIParent)
btn:SetSize(32, 40)
btn:SetPoint("CENTER")
btn:Hide()

-- layoutMicroButtons re-points all four; they only have to exist for its getters to return one.
btn:SetNormalTexture(ICON)
btn:SetPushedTexture(ICON)
btn:SetDisabledTexture(ICON)
btn:SetHighlightTexture(ICON)
btn:GetHighlightTexture():SetBlendMode("ADD")

-- The Key Bindings window reads BINDING_NAME_* globals, not AceLocale.
local BINDING = "DRAGONUI_TOGGLE_PROFESSIONS"
_G["BINDING_NAME_" .. BINDING] = TRADE_SKILLS

btn:RegisterForClicks("LeftButtonUp")
btn:SetScript("OnClick", function()
    if addon.ToggleProfessionsBook then addon.ToggleProfessionsBook() end
end)
-- Like Character Info: title with its key, and a description line when beginner tooltips are on.
-- The key is DragonUI's binding, or Retail Professions' (it takes K on first run when K is free).
local BINDING_SOURCES = { BINDING, "RETAILPROFESSIONS_BOOK" }
btn.tooltipText = TRADE_SKILLS
btn.newbieText = addon.L["Your professions and secondary skills: craft, and see what to train and level next."]
btn:SetScript("OnEnter", function(self)
    -- Rebuilt per hover rather than cached: a rebind would otherwise show the old key until reload.
    local text = self.tooltipText
    if MicroButtonTooltipText then
        for _, action in ipairs(BINDING_SOURCES) do
            if GetBindingKey(action) then
                text = MicroButtonTooltipText(text, action)
                break
            end
        end
    end
    GameTooltip_AddNewbieTip(self, text, 1.0, 1.0, 1.0, self.newbieText)
end)
btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- With the module off, or yielding to another professions addon, there is no Overview to open.
local function wanted()
    local cfg = addon:GetModuleConfig("professions")
    local P = addon.Professions
    return addon:IsModuleEnabled("professions") and not (cfg and cfg.micro_button == false) and not (P and P.YieldsTo())
end

-- The micro menu skips flagged buttons; one switched back on needs its skin pass, not just the layout one.
function addon.RefreshProfessionsMicroButton(live)
    local show = wanted() and true or false
    btn.dragonUISuppressed = (not show) or nil
    if not show then
        btn:Hide()
        if addon.RefreshMicromenu then addon.RefreshMicromenu() end
    elseif live and addon.RefreshMicromenuButtons then
        addon.RefreshMicromenuButtons()
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function() addon.RefreshProfessionsMicroButton(false) end)
