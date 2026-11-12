-- Copyright (c) 2026 NeticSoul. Licensed under the MIT License; see LICENSE.

local addon = select(2, ...)
local L = addon.L

-- =============================================================================
-- DRAGONUI LOOT ROLL MODULE
-- Moves GroupLootContainer (the parent of all roll frames) to a custom position.
-- Uses the same approach as DragonflightUI: reposition the container, not the
-- individual GroupLootFrame1-4.  This keeps Blizzard's internal frame stacking
-- intact and survives /reload without breaking roll functionality.
-- =============================================================================

local LootRollModule = {
    initialized = false,
    applied = false,
}
addon.LootRollModule = LootRollModule

-- Loot Roll is not registered as a toggleable module — it always runs.
-- Position is managed via Editor Mode only.

-- =============================================================================
-- DEFAULT POSITION
-- =============================================================================
local DEFAULTS = {
    anchor = "BOTTOM",
    x = 0,
    y = 200,
}

-- =============================================================================
-- CONFIG
-- =============================================================================
local function GetLootRollConfig()
    if not (addon.db and addon.db.profile and addon.db.profile.lootroll) then
        return DEFAULTS.x, DEFAULTS.y, DEFAULTS.anchor
    end
    local cfg = addon.db.profile.lootroll
    return cfg.x or DEFAULTS.x, cfg.y or DEFAULTS.y, cfg.anchor or DEFAULTS.anchor
end

-- =============================================================================
-- POSITION HELPERS
-- =============================================================================

local function IsAtDefaultPosition(x, y, point)
    local defaults = addon.defaults and addon.defaults.profile.lootroll or DEFAULTS
    return point == defaults.anchor and math.abs(x - defaults.x) <= 1 and math.abs(y - defaults.y) <= 1
end

--- Move the invisible anchor frame to the saved (or default) position.
local function UpdateAnchorPosition()
    local anchor = LootRollModule.anchorFrame
    if not anchor then return end
    local x, y, point = GetLootRollConfig()
    local lift = 0
    if IsAtDefaultPosition(x, y, point) then
        lift = (addon.GetPetbarStackLift and addon.GetPetbarStackLift() or 0)
            + (addon.GetGCDStackLift and addon.GetGCDStackLift() or 0)
    end
    -- Position presets read this frame back; they subtract the lift so it is never saved as a move.
    anchor.DragonUI_LayoutOffset = lift > 0 and { 0, lift } or nil
    anchor:ClearAllPoints()
    anchor:SetPoint(point, UIParent, point, x, y + lift)
end

--- Attach GroupLootContainer to the bottom of our anchor frame.
--- Blizzard keeps managing frames *inside* the container; we only move
--- the container itself.
--- Falls back to repositioning individual GroupLootFrame1-4 if the
--- container global doesn't exist on this client.
local attachingContainer = false  -- re-entrancy guard
local fallbackHooksInstalled = false

local function AttachContainer()
    local anchor = LootRollModule.anchorFrame
    if not anchor then return end

    if GroupLootContainer then
        -- Preferred path: move the whole container
        GroupLootContainer.ignoreFramePositionManager = true

        -- Guard against our own SetPoint hook re-entering
        attachingContainer = true
        GroupLootContainer:ClearAllPoints()
        GroupLootContainer:SetPoint("BOTTOM", anchor, "BOTTOM", 0, 0)
        attachingContainer = false
    else
        -- Fallback: reposition individual frames (older clients without container)
        attachingContainer = true
        for i = 1, NUM_GROUP_LOOT_FRAMES or 4 do
            local frame = _G["GroupLootFrame" .. i]
            if frame then
                frame:ClearAllPoints()
                if i == 1 then
                    frame:SetPoint("BOTTOM", anchor, "BOTTOM", 0, 0)
                else
                    local prev = _G["GroupLootFrame" .. (i - 1)]
                    frame:SetPoint("BOTTOM", prev, "TOP", 0, 4)
                end
            end
        end
        attachingContainer = false
    end
end

-- =============================================================================
-- HOOKS  (installed once, survive reload because we re-install on PLAYER_LOGIN)
-- =============================================================================
local hookInstalled = false
local function InstallHooks()
    if hookInstalled then return end

    if GroupLootContainer then
        -- Hook SetPoint on the container so if anything (Blizzard or another
        -- addon) tries to reposition it, we immediately correct.
        hooksecurefunc(GroupLootContainer, "SetPoint", function()
            if not LootRollModule.applied then return end
            if attachingContainer then return end   -- our own call
            AttachContainer()
        end)
    end

    -- Also hook GroupLootContainer_Update if it exists
    if GroupLootContainer_Update then
        hooksecurefunc("GroupLootContainer_Update", function()
            if not LootRollModule.applied then return end
            AttachContainer()
        end)
    end

    -- Fallback: hook individual frame openers for clients without the container
    if not GroupLootContainer and GroupLootFrame_OpenNewFrame then
        hooksecurefunc("GroupLootFrame_OpenNewFrame", function()
            if not LootRollModule.applied then return end
            AttachContainer()
        end)
    end

    -- Fallback: also self-correct each frame directly, so a reposition while
    -- a roll is already open (not just on new-frame-open) gets caught too.
    if not GroupLootContainer and not fallbackHooksInstalled then
        fallbackHooksInstalled = true
        for i = 1, NUM_GROUP_LOOT_FRAMES or 4 do
            local frame = _G["GroupLootFrame" .. i]
            if frame then
                hooksecurefunc(frame, "SetPoint", function()
                    if not LootRollModule.applied then return end
                    if attachingContainer then return end
                    AttachContainer()
                end)
            end
        end
    end

    hookInstalled = true
end

-- Stores where the user left the anchor (drag or editor panel), re-anchored to its screen quadrant.
local function SaveAnchorPosition(f)
    local point, x, y = addon.GetQuadrantAnchor(f)
    if point then
        f:ClearAllPoints()
        f:SetPoint(point, UIParent, point, x, y)
        f:SetUserPlaced(false)

        -- Save to DB
        if addon.db and addon.db.profile then
            if not addon.db.profile.lootroll then
                addon.db.profile.lootroll = {}
            end
            addon.db.profile.lootroll.anchor = point
            addon.db.profile.lootroll.x = x
            addon.db.profile.lootroll.y = y
        end

        -- Re-attach container to new position
        AttachContainer()
    end
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================
function LootRollModule:Initialize()
    if self.initialized then return end

    -- Create invisible anchor frame the user drags in editor mode
    local anchor = CreateFrame("Frame", "DragonUI_LootRollAnchor", UIParent)
    local refFrame = GroupLootContainer or _G["GroupLootFrame1"]
    local w = refFrame and refFrame:GetWidth() or 240
    local h = refFrame and refFrame:GetHeight() or 28
    anchor:SetSize(w, h)
    anchor:EnableMouse(false)
    anchor:SetMovable(false)

    -- Add nineslice overlay for editor mode
    if addon.AddNineslice then
        addon.AddNineslice(anchor)
        addon.SetNinesliceState(anchor, false)
        addon.HideNineslice(anchor)
    end

    -- Create text label for editor mode
    local L = addon.L
    local fontString = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fontString:SetPoint("CENTER")
    fontString:SetText(L and L["Loot Roll"] or "Loot Roll")
    fontString:Hide()
    anchor.editorText = fontString

    self.anchorFrame = anchor

    -- Position anchor & attach container
    UpdateAnchorPosition()
    InstallHooks()
    AttachContainer()

    -- Register with Editor Mode
    if addon.RegisterEditableFrame then
        addon:RegisterEditableFrame({
            name = "lootroll",
            frame = anchor,
            configPath = nil, -- Custom save logic in OnDragStop
            onNudge = function()
                SaveAnchorPosition(anchor)
            end,
            showTest = function()
                LootRollModule:ShowEditorTest()
            end,
            hideTest = function()
                LootRollModule:HideEditorTest()
            end,
            onHide = function()
                UpdateAnchorPosition()
                AttachContainer()
            end,
            resetPosition = function()
                local cfg = addon.db and addon.db.profile and addon.db.profile.lootroll
                local defaults = addon.defaults and addon.defaults.profile.lootroll
                if not (cfg and defaults) then return end
                cfg.anchor, cfg.x, cfg.y = defaults.anchor, defaults.x, defaults.y
                UpdateAnchorPosition()
                AttachContainer()
            end,
            isDefaultPosition = function()
                return IsAtDefaultPosition(GetLootRollConfig())
            end,
            module = LootRollModule
        })
    end

    self.initialized = true
    self.applied = true
end

-- =============================================================================
-- APPLY / RESTORE
-- =============================================================================
function LootRollModule:ApplySystem()
    if not self.initialized then
        self:Initialize()
        return
    end

    UpdateAnchorPosition()
    AttachContainer()
    self.applied = true
end

-- Public refresh helper used by position presets and profile operations.
function addon.RefreshLootRoll()
    if not LootRollModule.initialized then
        LootRollModule:Initialize()
        return
    end

    UpdateAnchorPosition()
    AttachContainer()
end

function LootRollModule:RestoreSystem()
    if not self.applied then return end
    -- Give the container back to Blizzard's position manager
    if GroupLootContainer then
        GroupLootContainer.ignoreFramePositionManager = nil
    end
    self.applied = false
    -- Note: we don't restore individual frame positions because Blizzard
    -- will recalculate them on the next GroupLootContainer_Update / roll event.
end

-- =============================================================================
-- EDITOR MODE
-- =============================================================================
function LootRollModule:ShowEditorTest()
    local frame = self.anchorFrame
    if not frame then return end

    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")

    -- Show nineslice
    if frame.NineSlice and addon.ShowNineslice then
        addon.SetNinesliceState(frame, false)
        addon.ShowNineslice(frame)
    end

    if frame.editorText then
        frame.editorText:Show()
    end

    -- Click to select in editor panel
    frame:SetScript("OnMouseDown", function(f, button)
        if button == "LeftButton" and addon.SelectEditorFrame then
            addon.SelectEditorFrame(f)
        end
    end)

    frame:SetScript("OnDragStart", function(f)
        f.DragonUI_LayoutOffset = nil
        f:StartMoving()
        -- Ensure selected
        if addon.selectedEditorFrame ~= f and addon.SelectEditorFrame then
            addon.SelectEditorFrame(f)
        end
        -- Clear green tint while dragging (show default drag nineslice)
        if addon.ClearSelectionTint then
            addon.ClearSelectionTint(f)
        end
    end)

    frame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        f:SetScript("OnUpdate", nil)
        -- Re-apply green tint after drop (frame stays selected)
        if addon.ApplySelectionTint then
            addon.ApplySelectionTint(f)
        end

        SaveAnchorPosition(f)
    end)
end

function LootRollModule:HideEditorTest()
    local frame = self.anchorFrame
    if not frame then return end

    frame:SetMovable(false)
    frame:EnableMouse(false)
    frame:SetScript("OnDragStart", nil)
    frame:SetScript("OnDragStop", nil)
    frame:SetScript("OnMouseDown", nil)

    if frame.NineSlice and addon.HideNineslice then
        addon.HideNineslice(frame)
    end
    if frame.editorText then
        frame.editorText:Hide()
    end
end

-- =============================================================================
-- EVENTS
-- =============================================================================
addon.package:Subscribe(function()
    LootRollModule:Initialize()
end, "PLAYER_LOGIN")

-- Re-attach after zone changes, reloads, etc. (same as DragonflightUI pattern)
addon.package:Subscribe(function()
    if LootRollModule.applied then
        AttachContainer()
    end
end, "PLAYER_ENTERING_WORLD")

-- =============================================================================
-- AUTO ROLL (Auto Greed/DE)
-- =============================================================================

local ROLL_GREED, ROLL_DISENCHANT, GREEN_QUALITY = 2, 3, 2

local function AutoRollOnLoot(_, _, rollID)
    local cfg = addon.db and addon.db.profile and addon.db.profile.lootroll
    if not (cfg and cfg.autoRoll) then return end

    if UnitLevel("player") ~= (MAX_PLAYER_LEVEL or 80) then return end

    local _, _, _, quality, bindOnPickUp, _, canGreed, canDisenchant = GetLootRollItemInfo(rollID)
    if quality ~= GREEN_QUALITY or bindOnPickUp then return end

    if canDisenchant then
        RollOnLoot(rollID, ROLL_DISENCHANT)
    elseif canGreed then
        RollOnLoot(rollID, ROLL_GREED)
    end
end

addon.package:Subscribe(AutoRollOnLoot, "START_LOOT_ROLL")

-- =============================================================================
-- BIG PASS BUTTON
-- Blizzard's Pass is the small close cross in the corner. This turns it into a red cross the
-- size of Need, Greed and Disenchant, beside Need in the gap the rest of the row leaves.
-- Only its look and place change: the button and its click (pass) stay Blizzard's.
-- =============================================================================

local PASS_ART = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local PASS_INSET = -1 -- the cross art has empty margins; a little bleed matches the dice
local passOriginals = {}

local function StyleArt(texture, offsetX, offsetY)
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT", PASS_INSET + offsetX, -PASS_INSET + offsetY)
    texture:SetPoint("BOTTOMRIGHT", -PASS_INSET + offsetX, PASS_INSET + offsetY)
end

-- The frame art behind the old close cross; left on its own it is an empty box in the corner.
local function SetCornerShown(frame, shown)
    for _, region in ipairs({ frame:GetRegions() }) do
        local texture = region.GetTexture and region:GetTexture()
        local name = region:GetName()
        if (type(texture) == "string" and texture:lower():find("corner"))
            or (name and name:find("Corner$")) then
            if shown then region:Show() else region:Hide() end
        end
    end
end

local function PlacePass(frame, pass)
    local name = frame:GetName()
    local need, greed, de = _G[name .. "RollButton"], _G[name .. "GreedButton"], _G[name .. "DisenchantButton"]
    local dx = need:GetWidth() + 5
    local deX, greedX = de and de:GetCenter(), greed:GetCenter()
    if deX and greedX then dx = deX - greedX end
    pass:ClearAllPoints()
    pass:SetPoint("CENTER", need, "CENTER", dx, 0)
end

local function MakePassBig(frame, pass)
    local need = _G[frame:GetName() .. "RollButton"]
    local greed = _G[frame:GetName() .. "GreedButton"]
    if not (need and greed) then return end

    if not passOriginals[pass] then
        local saved = { width = pass:GetWidth(), height = pass:GetHeight(), points = {} }
        for i = 1, pass:GetNumPoints() do saved.points[i] = { pass:GetPoint(i) } end
        local normal, pushed, highlight = pass:GetNormalTexture(), pass:GetPushedTexture(), pass:GetHighlightTexture()
        saved.normal = normal and normal:GetTexture()
        saved.pushed = pushed and pushed:GetTexture()
        saved.highlight = highlight and highlight:GetTexture()
        passOriginals[pass] = saved
    end

    -- Level with Need, in Disenchant's column, so the four make a square. Measured each time the
    -- window shows, as positions are only known once it is on screen.
    PlacePass(frame, pass)
    if not passOriginals[pass].hooked then
        passOriginals[pass].hooked = true
        frame:HookScript("OnShow", function(self)
            if passOriginals[pass].big then PlacePass(self, pass) end
        end)
    end
    passOriginals[pass].big = true
    SetCornerShown(frame, false)
    pass:SetWidth(need:GetWidth())
    pass:SetHeight(need:GetHeight())

    pass:SetNormalTexture(PASS_ART)
    pass:SetPushedTexture(PASS_ART)
    pass:SetHighlightTexture(PASS_ART, "ADD")
    StyleArt(pass:GetNormalTexture(), 0, 0)
    StyleArt(pass:GetPushedTexture(), 1, -1)
    pass:GetPushedTexture():SetVertexColor(0.75, 0.75, 0.75)
    StyleArt(pass:GetHighlightTexture(), 0, 0)
    pass:GetHighlightTexture():SetAlpha(0.4)
end

local function RestorePass(pass)
    local saved = passOriginals[pass]
    if not saved then return end
    saved.big = false
    SetCornerShown(pass:GetParent(), true)
    pass:ClearAllPoints()
    for _, p in ipairs(saved.points) do pass:SetPoint(unpack(p)) end
    pass:SetWidth(saved.width)
    pass:SetHeight(saved.height)
    pass:SetNormalTexture(saved.normal)
    pass:SetPushedTexture(saved.pushed)
    pass:SetHighlightTexture(saved.highlight, "ADD")
    for _, texture in ipairs({ pass:GetNormalTexture(), pass:GetPushedTexture(), pass:GetHighlightTexture() }) do
        if texture then
            texture:ClearAllPoints()
            texture:SetAllPoints(pass)
            texture:SetVertexColor(1, 1, 1)
            texture:SetAlpha(1)
        end
    end
end

function addon.RefreshLootRollPassButton()
    local cfg = addon.db and addon.db.profile and addon.db.profile.lootroll
    local big = not cfg or cfg.bigPass ~= false
    for i = 1, NUM_GROUP_LOOT_FRAMES or 4 do
        local frame = _G["GroupLootFrame" .. i]
        local pass = frame and _G[frame:GetName() .. "PassButton"]
        if pass then
            if big then MakePassBig(frame, pass) else RestorePass(pass) end
        end
    end
end

addon.package:Subscribe(function()
    addon.RefreshLootRollPassButton()
end, "PLAYER_LOGIN")
