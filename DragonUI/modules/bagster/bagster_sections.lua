-- Licensed under the MIT License; see LICENSE.
-- Adapted from BagsterSections.lua in NethanosGit's DragonUI_Extensions
-- (https://github.com/NethanosGit/DragonUI_Extensions).

-- Sectioned inventory (optional, off by default): replaces the inventory's category tabs with one view
-- where the items are split into labelled sections: a top row (Hearthstone, Potion, Food, Consumable,
-- Devices, Quest), then Equipment (Armor, Weapon, Trinket), Crafting, Miscellaneous, and Empty (one slot
-- showing how many are free). Section titles fold on click. The rarity filter, search and bag column stay.
-- Inventory only; the bank keeps its tabs. Stored as modules.bagster.sections (+ sections_collapsed).
local addon = select(2, ...)
local mod = addon.BagsterModule
if not (mod and mod.ItemFrame and mod.Frame and mod.SideFilter and mod.BottomFilter and mod.ItemSlot) then
    return
end

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local pairs, ipairs, wipe, tonumber = pairs, ipairs, wipe, tonumber

local ItemFrame, Frame, ItemSlot = mod.ItemFrame, mod.Frame, mod.ItemSlot

-- ============================================================================
-- SETTINGS
-- ============================================================================

local function IsSectioned()
    local cfg = mod.GetModuleConfig()
    return cfg ~= nil and cfg.sections == true
end

local function Active(frame)
    return frame ~= nil and not frame.isBank and IsSectioned()
end

local function Collapsed()
    local cfg = mod.GetModuleConfig()
    if not cfg then return {} end
    cfg.sections_collapsed = cfg.sections_collapsed or {}
    return cfg.sections_collapsed
end

-- Options toggle: rebuild the inventory frame's tabs and items for the new mode.
local function SetBagsterSections(value)
    local cfg = mod.GetModuleConfig()
    if not cfg then return end
    cfg.sections = value and true or false
    for _, f in pairs(mod.frames or {}) do
        if not f.isBank and f.sideFilter then
            f:UpdateSets()
            f:UpdateClampInsets()
            if f.itemFrame then
                f.itemFrame:Regenerate()
                f.itemFrame:RequestLayout()
            end
        end
    end
end
addon.SetBagsterSections = SetBagsterSections

-- ============================================================================
-- TABS OFF, NO CATEGORY FILTER
-- ============================================================================

local origSideUpdate = mod.SideFilter.UpdateFilters
function mod.SideFilter:UpdateFilters()
    if Active(self:GetParent()) then
        self:Hide()
        return
    end
    return origSideUpdate(self)
end

local origBottomUpdate = mod.BottomFilter.UpdateFilters
function mod.BottomFilter:UpdateFilters()
    local parent = self:GetParent()
    if Active(parent) then
        self:Hide()
        parent:UpdateClampInsets()
        return
    end
    return origBottomUpdate(self)
end

local origSetCategory = Frame.SetCategory
function Frame:SetCategory(name)
    if Active(self) then
        self:SetFilter("rule", nil)
        self:SetFilter("subRule", nil)
        return
    end
    return origSetCategory(self, name)
end

local origSetSubCategory = Frame.SetSubCategory
function Frame:SetSubCategory(name)
    if Active(self) then
        self:SetFilter("subRule", nil)
        return
    end
    return origSetSubCategory(self, name)
end

-- The Empty section shows one slot carrying the free-slot total; keep the count when the slot refreshes.
local origItemUpdate = ItemSlot.Update
function ItemSlot:Update()
    origItemUpdate(self)
    if self._sectionEmptyCount then
        SetItemButtonCount(self, self._sectionEmptyCount)
    end
end

-- Sectioned inventory: icon 2px smaller on every side and drawn over the slot ring, so the ring frames it.
-- Inset 0 puts back the grid's look: icon filling the slot, ring on top. The count stays above both.
local function SetInset(item, inset)
    if (item._sectionInset or 0) == inset then return end
    local name = item:GetName()
    local icon = name and _G[name .. "IconTexture"]
    if not icon then return end
    item._sectionInset = inset
    local ring = item._dragonuiSlotBorder
    local count = _G[name .. "Count"]
    if ring then ring:SetDrawLayer("BORDER", inset > 0 and 0 or 1) end
    icon:SetDrawLayer("BORDER", inset > 0 and 1 or 0)
    if count then count:SetDrawLayer("BORDER", 2) end
    icon:ClearAllPoints()
    icon:SetPoint("TOPLEFT", item, "TOPLEFT", inset, -inset)
    icon:SetPoint("BOTTOMRIGHT", item, "BOTTOMRIGHT", -inset, inset)
end

-- Slots are pooled and may come back on the bank: drop everything the sections put on them.
local origItemFree = ItemSlot.Free
function ItemSlot:Free()
    self._sectionKey = nil
    self._sectionEmptyCount = nil
    SetInset(self, 0)
    return origItemFree(self)
end

-- ============================================================================
-- CLASSIFICATION
-- ============================================================================

local HEARTHSTONE_ID = 6948

local labels
local function Labels()
    if labels then return labels end
    local L = addon.L
    local enUS = (GetLocale() == "enUS")
    local consumables = { GetAuctionItemSubClasses(4) }
    labels = {
        hearth     = GetItemInfo(HEARTHSTONE_ID) or "Hearthstone",
        potion     = enUS and "Potion" or consumables[2] or "Potion",
        food       = enUS and "Food" or consumables[1] or "Food",
        consumable = mod.L.Consumable or "Consumable",
        devices    = mod.L.Devices or "Devices",
        quest      = mod.L.Quest or "Quest",
        equipment  = mod.GetSetDisplayName("Equipment"),
        armor      = mod.L.Armor or "Armor",
        weapon     = mod.L.Weapon or "Weapon",
        trinket    = INVTYPE_TRINKET or "Trinket",
        crafting   = (L and L["Crafting"]) or "Crafting",
        tradegood  = mod.L.TradeGood or "Trade Goods",
        gem        = mod.L.Gem or "Gem",
        recipe     = mod.L.Recipe or "Recipe",
        misc       = mod.L.Misc or "Miscellaneous",
        empty      = EMPTY or "Empty",
    }
    -- Names GetItemInfo reports for the consumable subtypes that get their own column.
    labels.potionSub = { Potion = true, [consumables[2] or "Potion"] = true }
    labels.foodSub = { ["Food & Drink"] = true, [consumables[1] or "Food & Drink"] = true }
    return labels
end

-- Bucket key for an item link; nil link means an empty slot.
local function Classify(link)
    if not link then return "empty" end
    local id = tonumber(link:match("item:(%d+)"))
    if id == HEARTHSTONE_ID then return "hearth" end

    local _, _, _, _, _, itype, subType, _, equipLoc = GetItemInfo(link)
    if not itype then return "misc" end

    local L = Labels()
    if itype == mod.L.Quest then
        return "quest"
    elseif itype == mod.L.Consumable then
        if L.potionSub[subType] then return "potion" end
        if L.foodSub[subType] then return "food" end
        return "consumable"
    elseif itype == mod.L.TradeGood then
        if subType == mod.L.Devices or subType == mod.L.Explosives then return "devices" end
        return "tradegood"
    elseif itype == mod.L.Armor then
        return (equipLoc == "INVTYPE_TRINKET") and "trinket" or "armor"
    elseif itype == mod.L.Weapon then
        return "weapon"
    elseif itype == mod.L.Gem then
        return "gem"
    elseif itype == mod.L.Recipe then
        return "recipe"
    end
    return "misc"
end

local function ToIndex(bag, slot)
    return (bag < 0 and bag * 100 - slot) or (bag * 100 + slot)
end

-- A slot whose item changes kind (looted into an empty slot, used up, swapped for another kind) must move
-- to another section; Bagster only re-lays out when slots appear or vanish, so ask for it here.
local origUpdateSlot = ItemFrame.UpdateSlot
function ItemFrame:UpdateSlot(bag, slot, link)
    local changed = origUpdateSlot(self, bag, slot, link)
    if not changed and self._sectioned then
        local item = self.items[ToIndex(bag, slot)]
        if item and item._sectionKey ~= Classify(link or self:GetItemLink(bag, slot)) then
            self:RequestLayout()
        end
    end
    return changed
end

-- ============================================================================
-- HEADERS (pooled, parented to the item frame)
-- ============================================================================

local HEAD_H, LABEL_H = 22, 14
local LINE_GAP, SECTION_GAP, BLOCK_GAP = 4, 8, 0.4
local MIN_SCALE, SCALE_STEP = 0.7, 0.05

local function SetArrow(tex, collapsed)
    local fui = addon.ForeverUI
    if fui and fui.SetAtlas then
        fui.SetAtlas(tex, collapsed and "common-button-dropdown-closed" or "common-button-dropdown-open", false)
    end
    tex:SetSize(18, 18)
end

local function Header_OnClick(btn)
    if not btn.sectionKey then return end
    local state = Collapsed()
    state[btn.sectionKey] = not state[btn.sectionKey] or nil
    btn:GetParent():RequestLayout()
end

local function AcquireHeader(self, index)
    local pool = self._sectionHeaders
    if not pool then
        pool = {}
        self._sectionHeaders = pool
    end
    local h = pool[index]
    if not h then
        h = CreateFrame("Button", nil, self)
        h.indicator = h:CreateTexture(nil, "ARTWORK")
        h.indicator:SetPoint("LEFT", h, "LEFT", 0, 0)
        h.label = h:CreateFontString(nil, "ARTWORK")
        local hover = h:CreateTexture(nil, "HIGHLIGHT")
        hover:SetAllPoints(h)
        hover:SetTexture(1, 1, 1, 0.07)
        h.hover = hover
        h:SetScript("OnClick", Header_OnClick)
        pool[index] = h
    end
    return h
end

local function HideHeaders(self)
    local pool = self._sectionHeaders
    if not pool then return end
    for _, h in ipairs(pool) do h:Hide() end
end

-- ============================================================================
-- LAYOUT
-- ============================================================================

-- sections: { { key, title, collapsible, blocks = { { key, label, items } } } }. Places everything (or only
-- measures when apply is false) at scale s and returns the height used.
local function Flow(self, sections, s, size, width, apply, placed)
    local cell = size * s
    local cols = max(1, floor(width / cell))
    local collapsed = Collapsed()
    local y, headerIndex = 0, 0

    local function Header(x, top, w, text, big, key, isCollapsed, collapsible, truncate)
        headerIndex = headerIndex + 1
        local h = AcquireHeader(self, headerIndex)
        h.sectionKey = (big and collapsible) and key or nil
        h:ClearAllPoints()
        -- Small category labels sit 2px higher than their row.
        h:SetPoint("TOPLEFT", self, "TOPLEFT", x, -top + (big and 0 or 2))
        h:SetSize(w, big and HEAD_H or LABEL_H)
        h.label:ClearAllPoints()
        if big and collapsible then
            h.label:SetFontObject(GameFontNormal)
            h.label:SetPoint("LEFT", h, "LEFT", 22, 0)
            SetArrow(h.indicator, isCollapsed)
            h.indicator:Show()
            h.hover:Show()
            h:EnableMouse(true)
        elseif big then
            h.label:SetFontObject(GameFontNormal)
            h.label:SetPoint("LEFT", h, "LEFT", 4, 0)
            h.indicator:Hide()
            h.hover:Hide()
            h:EnableMouse(false)
        else
            h.label:SetFontObject(GameFontNormalSmall)
            h.label:SetPoint("LEFT", h, "LEFT", 1, 0)
            h.indicator:Hide()
            h.hover:Hide()
            h:EnableMouse(false)
        end
        h.label:SetText(text)
        if truncate then
            -- Cut the label to the block width and end it with "...".
            local len = #text
            while len > 1 and h.label:GetStringWidth() > w do
                len = len - 1
                h.label:SetText(text:sub(1, len) .. "...")
            end
        end
        h:Show()
    end

    for _, sec in ipairs(sections) do
        local isCollapsed = sec.collapsible and collapsed[sec.key]
        if sec.title then
            if apply then Header(0, y, width, sec.title, true, sec.key, isCollapsed, sec.collapsible) end
            y = y + HEAD_H
        end
        if not isCollapsed then
            local used, lineH = 0, 0
            for _, block in ipairs(sec.blocks) do
                local n = #block.items
                local w = min(n, cols)
                if used > 0 and used + w > cols then
                    y = y + lineH + LINE_GAP
                    used, lineH = 0, 0
                end
                local labelH = block.label and LABEL_H or 0
                local rows = ceil(n / w)
                if apply then
                    if block.label then
                        -- Only the Hearthstone label is cut to its one-slot block; the others show in full.
                        local cut = (block.key == "hearth")
                        Header(used * cell, y, cut and (w * cell - 2) or max(w * cell, 40), block.label, false, nil, nil, nil, cut)
                    end
                    for i, item in ipairs(block.items) do
                        local col, row = (i - 1) % w, floor((i - 1) / w)
                        item:ClearAllPoints()
                        item:SetScale(s)
                        item:SetPoint("TOPLEFT", self, "TOPLEFT",
                            (used + col) * cell / s, -(y + labelH + row * cell) / s)
                        item:Show()
                        placed[item] = true
                    end
                end
                used = used + w + BLOCK_GAP
                lineH = max(lineH, labelH + rows * cell)
            end
            y = y + lineH
        end
        y = y + SECTION_GAP
    end
    return y - SECTION_GAP
end

local SECTION_DEFS = {
    { "top", nil, false, { { "hearth" }, { "potion" }, { "food" }, { "consumable" }, { "devices" }, { "quest" } } },
    { "equipment", "equipment", true, { { "armor" }, { "weapon" }, { "trinket" } } },
    { "crafting", "crafting", true, { { "tradegood" }, { "gem" }, { "recipe" } } },
    { "misc", "misc", true, { { "misc", false } } },
}

-- Scratch tables reused between layouts (layouts only run when the inventory actually changes).
local buckets, emptyItems, placed, sections = {}, {}, {}, {}

local function SectionLayout(self, parent)
    local width, height = self:GetWidth(), self:GetHeight()
    if width <= 0 or height <= 0 then return end

    local cfg = mod.GetModuleConfig()
    local spacing = (cfg and cfg.item_spacing) or 2
    local size = 37 + spacing
    local cap = (cfg and cfg.item_scale) or 1

    -- Items in bag order, bucketed by kind.
    local L = Labels()
    for _, list in pairs(buckets) do wipe(list) end
    wipe(emptyItems)
    local items = self.items
    for _, bag in ipairs(self.bags) do
        local numSlots = self:GetBagSize(bag)
        if numSlots > 0 and parent:IsShowingBag(bag) then
            -- Empty keyring slots only take keys: not free bag space, so neither counted nor shown.
            local keyring = (bag == KEYRING_CONTAINER)
            for slot = 1, numSlots do
                local item = items[ToIndex(bag, slot)]
                if item then
                    local key = Classify(self:GetItemLink(bag, slot))
                    item._sectionKey = key
                    SetInset(item, 2)
                    if key == "empty" then
                        if not keyring then emptyItems[#emptyItems + 1] = item end
                    else
                        local list = buckets[key]
                        if not list then
                            list = {}
                            buckets[key] = list
                        end
                        list[#list + 1] = item
                    end
                end
            end
        end
    end

    wipe(sections)
    local function Add(key, title, collapsible, blockDefs)
        local blocks
        for _, def in ipairs(blockDefs) do
            local list = buckets[def[1]]
            if list and #list > 0 then
                blocks = blocks or {}
                -- def[2] == false: no small label (the section title already says it).
                blocks[#blocks + 1] = { key = def[1], label = def[2] ~= false and L[def[1]] or nil, items = list }
            end
        end
        if blocks then
            sections[#sections + 1] = { key = key, title = title, collapsible = collapsible, blocks = blocks }
        end
    end

    for _, def in ipairs(SECTION_DEFS) do
        Add(def[1], def[2] and L[def[2]], def[3], def[4])
    end

    -- Empty: one slot standing for all of them, labelled with the total.
    local emptyCount = #emptyItems
    local emptyRep = emptyItems[1]
    if emptyRep then
        sections[#sections + 1] = { key = "empty", collapsible = false,
            blocks = { { key = "empty", label = L.empty, items = { emptyRep } } } }
    end

    -- Largest scale that fits; below the floor the frame grows instead.
    local s = max(cap, MIN_SCALE)
    local total
    while true do
        total = Flow(self, sections, s, size, width, false)
        if total <= height or s <= MIN_SCALE then break end
        s = max(MIN_SCALE, s - SCALE_STEP)
    end

    wipe(placed)
    HideHeaders(self)
    Flow(self, sections, s, size, width, true, placed)

    for _, item in pairs(items) do
        if not placed[item] then item:Hide() end
        if item ~= emptyRep and item._sectionEmptyCount then
            -- No longer the Empty stand-in (it may hold an item now): show its own count again.
            item._sectionEmptyCount = nil
            item:Update()
        end
    end
    if emptyRep then
        emptyRep._sectionEmptyCount = emptyCount
        SetItemButtonCount(emptyRep, emptyCount)
    end
    wipe(placed)

    if total > height + 1 then
        local target = min(parent:GetHeight() + (total - height), UIParent:GetHeight() * 0.9)
        if target > parent:GetHeight() + 1 then
            parent:SetHeight(target)
        end
    end
end

local origLayout = ItemFrame.Layout
function ItemFrame:Layout()
    local parent = self:GetParent()
    if parent and Active(parent) then
        self._sectioned = true
        SectionLayout(self, parent)
        return
    end
    -- Classic grid: drop the section extras before it takes over.
    if self._sectioned then
        self._sectioned = nil
        HideHeaders(self)
        for _, item in pairs(self.items) do
            item._sectionKey = nil
            SetInset(item, 0)
            if item._sectionEmptyCount then
                item._sectionEmptyCount = nil
                item:Update()
            end
        end
    end
    return origLayout(self)
end
