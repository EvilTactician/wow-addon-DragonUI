-- Licensed under the MIT License; see LICENSE.

-- Party auras: one line of debuffs then buffs under each party frame, like later expansions.
-- Event-driven (UNIT_AURA for party1-4 only); nothing runs per frame. The "RAID" filter is the
-- client's own: buffs you can cast, debuffs you can dispel.

local addon = select(2, ...)
local UF = addon.UF

local PA = {}
UF.PartyAuras = PA

local _G = _G
local MAX_MEMBERS = 4
local MAX_SCAN = 40

-- Frame units, from the top of the party frame.
local BAR_CLEARANCE = 4   -- below the mana bar, clear of the art's bottom edge
-- PartyMemberFrame_UpdatePet puts the pet frame (64 wide, with its debuffs inside) 23 in and
-- 43 down, right where the rows start; with a pet out the rows begin just right of it instead,
-- centred on its 18px portrait (3 down from its top).
local PET_RIGHT = 23 + 64 + 2
local PET_PORTRAIT_MIDDLE = 43 + 3 + 9
local GAP = 2
local GROUP_GAP = 6       -- between the last debuff and the first buff

local BORDER_TEX = "Interface\\Buttons\\UI-Debuff-Overlays"
local MINE_COLOR = { 1, 0.82, 0 }

local BUFF_FILTERS = { all = nil, mine = "PLAYER", castable = "RAID" }

-- Editor preview art: one debuff of each dispel type, then common raid buffs.
local PREVIEW_DEBUFFS = {
    { "Interface\\Icons\\Spell_Shadow_ShadowWordPain", "Magic" },
    { "Interface\\Icons\\Spell_Shadow_CurseOfSargeras", "Curse" },
    { "Interface\\Icons\\Ability_Creature_Disease_02", "Disease" },
    { "Interface\\Icons\\Spell_Nature_CorrosiveBreath", "Poison" },
}
local PREVIEW_BUFFS = {
    "Interface\\Icons\\Spell_Holy_WordFortitude",
    "Interface\\Icons\\Spell_Nature_Regeneration",
    "Interface\\Icons\\Spell_Holy_MagicalSentry",
    "Interface\\Icons\\Spell_Holy_FistOfJustice",
    "Interface\\Icons\\Spell_Holy_Renew",
}

local UNIT_INDEX = { party1 = 1, party2 = 2, party3 = 3, party4 = 4 }

local holders = {}
-- Auras already shown by a first pass, name -> expiration; wiped, never reallocated.
local seen = {}

local function Cfg()
    return UF.GetConfig("party")
end

local function RowCount(cfg)
    return (cfg.auras_debuffs and 1 or 0) + (cfg.auras_buffs and 1 or 0)
end

local function IconSize(cfg)
    return tonumber(cfg.auras_size) or 14
end

-- The mana bar from the frame art in use: its left edge and where the rows start under it.
local function BarRowStart()
    local mana = UF.GetFrameSkin().party.bars.mana
    return mana.x, -mana.y + mana.h + BAR_CLEARANCE
end

-- Where the first row starts, beside the pet's portrait when the member has a pet out.
local function RowTop(size, withPet)
    local _, top = BarRowStart()
    if withPet then
        top = math.max(top, PET_PORTRAIT_MIDDLE - size / 2)
    end
    return top
end

-- Whether a member's pet frame sits under its frame, where the aura line would go.
local function PetUnderFrame(pet)
    return pet and pet:IsShown() and not (UF.IsPartyPetBeside and UF.IsPartyPetBeside())
end

-- The smallest top-to-top step that clears the frame and the aura line; 0 when off. A pet under
-- the frame adds no line of its own: the auras sit beside it, lined up with its portrait.
function PA.GetReserve()
    local cfg = Cfg()
    if RowCount(cfg) == 0 then
        return 0
    end
    local size = IconSize(cfg)
    local petUnder = GetCVar("showPartyPets") == "1" and not (UF.IsPartyPetBeside and UF.IsPartyPetBeside())
    return RowTop(size, petUnder) + size + GAP
end

-- ===============================================================
-- ICONS
-- ===============================================================

local function IconOnEnter(self)
    -- Faded-out party frames keep their icons under the mouse; no tooltips from invisible ones.
    if not self.unit or self:GetEffectiveAlpha() < 0.05 then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    if self.harmful then
        GameTooltip:SetUnitDebuff(self.unit, self.index, self.filter)
    else
        GameTooltip:SetUnitBuff(self.unit, self.index, self.filter)
    end
end

local function IconOnLeave()
    GameTooltip:Hide()
end

local function CreateIcon(row)
    local icon = CreateFrame("Button", nil, row)
    icon.texture = icon:CreateTexture(nil, "ARTWORK")
    icon.texture:SetAllPoints(icon)
    icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    icon.cooldown = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
    icon.cooldown:SetAllPoints(icon)
    icon.cooldown:SetReverse(true)

    -- Above the swipe, so the border and stack count are never covered by it.
    local overlay = CreateFrame("Frame", nil, icon)
    overlay:SetAllPoints(icon)
    overlay:SetFrameLevel(icon.cooldown:GetFrameLevel() + 1)
    icon.border = overlay:CreateTexture(nil, "OVERLAY")
    icon.border:SetTexture(BORDER_TEX)
    icon.border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
    icon.border:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
    icon.border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
    icon.count = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    icon.count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, -1)

    icon:SetScript("OnEnter", IconOnEnter)
    icon:SetScript("OnLeave", IconOnLeave)
    icon:Hide()
    return icon
end

local function GetIcon(row, index)
    local icon = row.icons[index]
    if not icon then
        icon = CreateIcon(row)
        row.icons[index] = icon
        row.laidOut = nil
    end
    return icon
end

-- Resending identical cooldown values restarts the swipe, so only real changes reach it.
local function SetTimer(icon, showTimer, duration, expires)
    if showTimer and duration and duration > 0 and expires then
        local start = expires - duration
        if icon.cdStart ~= start or icon.cdDuration ~= duration then
            icon.cdStart, icon.cdDuration = start, duration
            icon.cooldown:SetCooldown(start, duration)
        end
        icon.cooldown:Show()
    else
        icon.cdStart, icon.cdDuration = nil, nil
        icon.cooldown:Hide()
    end
end

local function ShowIcon(icon, unit, index, filter, harmful, texture, count, borderColor, showTimer, duration, expires)
    icon.unit, icon.index, icon.filter, icon.harmful = unit, index, filter, harmful
    icon.texture:SetTexture(texture)
    icon.count:SetText((count and count > 1) and count or "")
    if borderColor then
        icon.border:SetVertexColor(borderColor[1] or borderColor.r, borderColor[2] or borderColor.g,
            borderColor[3] or borderColor.b)
        icon.border:Show()
    else
        icon.border:Hide()
    end
    SetTimer(icon, showTimer, duration, expires)
    icon:Show()
end

local function HideFrom(row, first)
    for i = first, #row.icons do
        local icon = row.icons[i]
        icon.unit = nil
        icon:Hide()
    end
end

local function DebuffColor(debuffType)
    return DebuffTypeColor[debuffType or "none"] or DebuffTypeColor["none"]
end

-- ===============================================================
-- LAYOUT
-- ===============================================================

local function LayoutRow(row, size)
    if row.laidOut == size then return end
    row.laidOut = size
    for i, icon in ipairs(row.icons) do
        icon:SetSize(size, size)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", row, "TOPLEFT", (i - 1) * (size + GAP), 0)
    end
end

local function GetHolder(index)
    local holder = holders[index]
    if holder then return holder end
    local frame = _G["PartyMemberFrame" .. index]
    if not frame then return nil end
    holder = CreateFrame("Frame", nil, frame)
    holder:SetSize(1, 1)
    holder.frame = frame
    holder.debuffs = CreateFrame("Frame", nil, holder)
    holder.debuffs:SetSize(1, 1)
    holder.debuffs.icons = {}
    holder.buffs = CreateFrame("Frame", nil, holder)
    holder.buffs:SetSize(1, 1)
    holder.buffs.icons = {}
    holders[index] = holder
    return holder
end

-- Buffs follow the debuffs on the same line, and start it while a member has none.
local function PlaceBuffRow(holder, size, debuffs)
    local x = debuffs > 0 and debuffs * (size + GAP) - GAP + GROUP_GAP or 0
    if holder.buffsX == x then return end
    holder.buffsX = x
    holder.buffs:ClearAllPoints()
    holder.buffs:SetPoint("TOPLEFT", holder, "TOPLEFT", x, 0)
end

-- Right under the bars; beside the member's pet portrait while its pet sits under the frame.
local function PlaceHolder(holder, cfg)
    local pet = _G[holder.frame:GetName() .. "PetFrame"]
    local withPet = PetUnderFrame(pet)
    local size = IconSize(cfg)
    local x = BarRowStart()
    if withPet then
        x = math.max(x, PET_RIGHT)
    end
    holder:ClearAllPoints()
    holder:SetPoint("TOPLEFT", holder.frame, "TOPLEFT", x, -RowTop(size, withPet))
    holder.debuffs:ClearAllPoints()
    holder.debuffs:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
    holder.buffsX = nil
    PlaceBuffRow(holder, size, 0)
end

-- Blizzard's four debuffs beside the frame would repeat the row, so they go invisible meanwhile.
local function SyncBlizzardDebuffs(index, hide)
    for i = 1, 4 do
        local debuff = _G["PartyMemberFrame" .. index .. "Debuff" .. i]
        if debuff then
            debuff:SetAlpha(hide and 0 or 1)
            debuff:EnableMouse(not hide)
        end
    end
end

-- ===============================================================
-- UPDATES
-- ===============================================================

local function FillDebuffs(row, unit, cfg, size)
    local max = tonumber(cfg.auras_debuffs_max) or 4
    local showTimer = cfg.auras_timer ~= false
    local shown = 0
    for k in pairs(seen) do seen[k] = nil end
    -- Ones you can dispel come first, so a short row never drops them.
    for i = 1, MAX_SCAN do
        if shown >= max then break end
        local name, _, texture, count, debuffType, duration, expires = UnitDebuff(unit, i, "RAID")
        if not name then break end
        shown = shown + 1
        seen[name] = expires or 0
        ShowIcon(GetIcon(row, shown), unit, i, "RAID", true, texture, count, DebuffColor(debuffType),
            showTimer, duration, expires)
    end
    if cfg.auras_debuffs_filter ~= "dispellable" then
        for i = 1, MAX_SCAN do
            if shown >= max then break end
            local name, _, texture, count, debuffType, duration, expires = UnitDebuff(unit, i)
            if not name then break end
            if seen[name] ~= (expires or 0) then
                shown = shown + 1
                ShowIcon(GetIcon(row, shown), unit, i, nil, true, texture, count, DebuffColor(debuffType),
                    showTimer, duration, expires)
            end
        end
    end
    LayoutRow(row, size)
    HideFrom(row, shown + 1)
    return shown
end

local function IsMine(caster)
    return caster == "player" or caster == "pet" or caster == "vehicle"
end

-- Yours first, so your own buffs and HoTs are never pushed off a full row; then everyone else's.
local function FillBuffs(row, unit, cfg, size)
    local max = tonumber(cfg.auras_buffs_max) or 6
    local filter = BUFF_FILTERS[cfg.auras_buffs_filter or "all"]
    local markMine = cfg.auras_mark_mine ~= false
    local showTimer = cfg.auras_timer ~= false
    local shown = 0
    for pass = 1, (filter == "PLAYER") and 1 or 2 do
        for i = 1, MAX_SCAN do
            if shown >= max then break end
            local name, _, texture, count, _, duration, expires, caster = UnitBuff(unit, i, filter)
            if not name then break end
            local mine = IsMine(caster)
            if pass == 1 and (mine or filter == "PLAYER") or pass == 2 and not mine then
                shown = shown + 1
                ShowIcon(GetIcon(row, shown), unit, i, filter, false, texture, count,
                    (markMine and mine) and MINE_COLOR or nil, showTimer, duration, expires)
            end
        end
    end
    LayoutRow(row, size)
    HideFrom(row, shown + 1)
end

local function UpdateMember(index)
    local holder = holders[index]
    if not holder then return end
    local unit = "party" .. index
    local cfg = Cfg()
    if RowCount(cfg) == 0 or not UnitExists(unit) then
        holder:Hide()
        return
    end
    -- Hidden in raids; PARTY_MEMBERS_CHANGED refills the rows when the frames come back.
    if not holder.frame:IsShown() then return end
    local size = IconSize(cfg)
    local debuffs = 0
    if cfg.auras_debuffs then
        holder.debuffs:Show()
        debuffs = FillDebuffs(holder.debuffs, unit, cfg, size)
    else
        holder.debuffs:Hide()
    end
    if cfg.auras_buffs then
        PlaceBuffRow(holder, size, debuffs)
        holder.buffs:Show()
        FillBuffs(holder.buffs, unit, cfg, size)
    else
        holder.buffs:Hide()
    end
    holder:Show()
end

-- Sample icons on the editor's stand-in members, so spacing can be judged outside a group.
function PA.Preview(frame)
    local index = frame and frame.GetID and frame:GetID()
    local holder = index and GetHolder(index)
    if not holder then return end
    local cfg = Cfg()
    if RowCount(cfg) == 0 then
        holder:Hide()
        return
    end
    local size = IconSize(cfg)
    PlaceHolder(holder, cfg)
    local debuffs = 0
    if cfg.auras_debuffs then
        local max = math.min(tonumber(cfg.auras_debuffs_max) or 4, #PREVIEW_DEBUFFS)
        debuffs = max
        for i = 1, max do
            local art = PREVIEW_DEBUFFS[i]
            ShowIcon(GetIcon(holder.debuffs, i), nil, i, nil, true, art[1], nil, DebuffColor(art[2]), false)
        end
        LayoutRow(holder.debuffs, size)
        HideFrom(holder.debuffs, max + 1)
        holder.debuffs:Show()
    else
        holder.debuffs:Hide()
    end
    if cfg.auras_buffs then
        PlaceBuffRow(holder, size, debuffs)
        local max = math.min(tonumber(cfg.auras_buffs_max) or 6, #PREVIEW_BUFFS)
        for i = 1, max do
            local mine = i == 1 and cfg.auras_mark_mine ~= false
            ShowIcon(GetIcon(holder.buffs, i), nil, i, nil, false, PREVIEW_BUFFS[i], nil,
                mine and MINE_COLOR or nil, false)
        end
        LayoutRow(holder.buffs, size)
        HideFrom(holder.buffs, max + 1)
        holder.buffs:Show()
    else
        holder.buffs:Hide()
    end
    holder:Show()
end

local events = CreateFrame("Frame")

-- Settings changed: re-place every row, refill it, and only listen for auras while a row is on.
function PA.RefreshAll()
    local cfg = Cfg()
    local active = RowCount(cfg) > 0
    for index = 1, MAX_MEMBERS do
        local holder = GetHolder(index)
        if holder then
            SyncBlizzardDebuffs(index, active and cfg.auras_debuffs)
            PlaceHolder(holder, cfg)
            holder.debuffs.laidOut, holder.buffs.laidOut = nil, nil
            UpdateMember(index)
        end
    end
    if active then
        events:RegisterEvent("UNIT_AURA")
        events:RegisterEvent("PARTY_MEMBERS_CHANGED")
        events:RegisterEvent("PLAYER_ENTERING_WORLD")
    else
        events:UnregisterAllEvents()
    end
end

events:SetScript("OnEvent", function(_, event, unit)
    if event == "UNIT_AURA" then
        local index = UNIT_INDEX[unit]
        if index then UpdateMember(index) end
    else
        PA.RefreshAll()
    end
end)

-- The pet frame appearing or leaving moves the rows beside it or back under the bars.
if PartyMemberFrame_UpdatePet then
    hooksecurefunc("PartyMemberFrame_UpdatePet", function(self, id)
        local frame = id and _G["PartyMemberFrame" .. id] or self
        local index = frame and frame.GetID and frame:GetID()
        local holder = index and holders[index]
        if holder and RowCount(Cfg()) > 0 then
            PlaceHolder(holder, Cfg())
        end
    end)
end
