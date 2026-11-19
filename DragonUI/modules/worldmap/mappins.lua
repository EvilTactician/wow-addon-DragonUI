-- Copyright (c) 2026 NeticSoul. Licensed under the MIT License; see LICENSE.

local addon = select(2, ...)
local L = addon.L
local WM = addon.WorldMap

-- Dungeon, raid, graveyard, flight and inn pins from generated tables; no client API lists them.

local ENTRANCE_SIZE = 28
local FLIGHT_SIZE = 18
local GRAVEYARD_W, GRAVEYARD_H = 12, 16
local INN_SIZE, HOME_SIZE = 18, 24
local QUEST_SIZE = 18
-- Givers whose pins would land closer than this share one; zooming in pulls them apart again.
local GROUP_RADIUS = QUEST_SIZE * 2
-- A shared pin's tooltip names this many givers, then says how many more zooming in would show.
local GROUP_TOOLTIP_GIVERS = 8
local QUEST_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"
local DAILY_ICON = "Interface\\GossipFrame\\DailyQuestIcon"
local HEARTHSTONE = "|TInterface\\Icons\\INV_Misc_Rune_01:14:14|t "
-- inndata.lua ships each inn as a positional record to stay small; these name its slots.
local INN_X, INN_Y, INN_SIDE, INN_NPC, INN_AREA = 1, 2, 3, 4, 5
local INN_SIDES = { A = "Alliance", H = "Horde" }
local TAXI_ATLAS = { Alliance = "map-taxinode-alliance", Horde = "map-taxinode-horde" }
-- Pairs closer than this share of their sizes get nudged apart, the way retail does.
local NUDGE_GAP = 0.9
local NUDGE_PASSES = 8
local EMPTY = {}
-- No client API names a taxi node outside the taxi frame, so the generator ships each locale's own.
local FLIGHT_NAMES = WM.FlightPointName
    and (WM.FlightPointName[GetLocale()] or (GetLocale() == "esMX" and WM.FlightPointName.esES))
    or EMPTY
-- inndata ships each locale's names as a list in InnAreaIDs order, "" where enUS words it the same.
local function byAreaID(names)
    if not names then return EMPTY end
    local byID = {}
    for i, id in ipairs(WM.InnAreaIDs) do
        if names[i] and names[i] ~= "" then byID[id] = names[i] end
    end
    return byID
end
local AREA_NAMES = byAreaID(WM.InnAreaName[GetLocale()] or (GetLocale() == "esMX" and WM.InnAreaName.esES))
local AREA_NAMES_ENUS = byAreaID(WM.InnAreaName.enUS)
-- A locale with its own area names but no room names keeps the area name over an English room name.
local ROOM_NAMES = WM.InnRoomName[GetLocale()] or (GetLocale() == "esMX" and WM.InnRoomName.esES)
    or (AREA_NAMES == EMPTY and WM.InnRoomName.enUS) or EMPTY
-- Only this client's locale is ever read, so the other locales' names can be collected.
WM.InnAreaIDs, WM.InnAreaName, WM.InnRoomName = nil, nil, nil
local GLOW = "Interface\\WorldMap\\UI-QuestPoi-IconGlow"
local FLASH_SECONDS, FLASH_PULSES, FLASH_GROW = 2.5, 3, 0.7
-- A pin asked for before its map has drawn stays pending, but not for a later, unrelated visit.
local FLASH_PATIENCE = 5

local pool = {}
local pendingFlash, pendingUntil
local innByNpc, binder

local function addQuestLine(quest)
    local color = GetQuestDifficultyColor(quest.level)
    local icon = quest.repeatable and DAILY_ICON or QUEST_ICON
    GameTooltip:AddLine(format("|T%s:14:14|t [%d] %s", icon, quest.level, quest.title), color.r, color.g, color.b)
end

local function acquire(index)
    local pin = pool[index]
    if pin then return pin end

    pin = CreateFrame("Button", nil, WorldMapButton)
    pin:SetFrameLevel(WorldMapButton:GetFrameLevel() + 2)
    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetAllPoints(pin)
    pin.glow = pin:CreateTexture(nil, "OVERLAY")
    pin.glow:SetTexture(GLOW)
    pin.glow:SetBlendMode("ADD")
    pin.glow:SetPoint("CENTER", pin, "CENTER", 0, 0)
    pin.glow:Hide()
    pin.count = pin:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    pin.count:SetPoint("BOTTOMRIGHT", pin, "BOTTOMRIGHT", 4, -2)
    pin.count:Hide()
    pin:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.name, 1, 1, 1)
        if self.kind then GameTooltip:AddLine(self.kind, 0.8, 0.8, 0.8) end
        if self.note then GameTooltip:AddLine(self.note, 0.1, 1, 0.1) end
        for _, quest in ipairs(self.quests or EMPTY) do addQuestLine(quest) end
        local givers = self.givers or EMPTY
        for i = 1, math.min(#givers, GROUP_TOOLTIP_GIVERS) do
            GameTooltip:AddLine(givers[i].name, 1, 0.82, 0)
            for _, quest in ipairs(givers[i].shown) do addQuestLine(quest) end
        end
        if #givers > GROUP_TOOLTIP_GIVERS then
            GameTooltip:AddLine(format(L["%d more, zoom in to see them"], #givers - GROUP_TOOLTIP_GIVERS), 0.8, 0.8, 0.8)
        end
        GameTooltip:Show()
    end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pool[index] = pin
    return pin
end

local function styleEntrance(pin, entry)
    -- The client localizes the LFG dungeon; the generated name covers instances outside that list.
    pin.name = (entry.lfg and GetLFGDungeonInfo(entry.lfg)) or entry.name
    local kind = entry.raid and RAID or LFG_TYPE_DUNGEON
    local levels = WM.DungeonLevelText(entry.lfg, entry.raid)
    pin.kind = levels and (kind .. " " .. levels) or kind
    pin.icon:SetAtlasTexture(entry.raid and "map-entrance-raid" or "map-entrance-dungeon")
    pin:SetSize(ENTRANCE_SIZE, ENTRANCE_SIZE)
end

local function styleGraveyard(pin)
    pin.name, pin.kind = L["Graveyard"], nil
    pin.icon:SetAtlasTexture("map-graveyard")
    pin:SetSize(GRAVEYARD_W, GRAVEYARD_H)
end

local function styleFlightPoint(pin, entry)
    pin.name, pin.kind = FLIGHT_NAMES[entry.name] or entry.name, L["Flight Master"]
    pin.icon:SetAtlasTexture(TAXI_ATLAS[entry.faction] or "map-taxinode-neutral")
    pin:SetSize(FLIGHT_SIZE, FLIGHT_SIZE)
end

-- Blue when every quest it lists is a daily or repeatable, grey when every one is far below you.
-- A pin several givers share is named for how many, with the count on it and each in its tooltip.
local function styleQuestGiver(pin, entry)
    pin.kind = nil
    if entry.givers then
        pin.name, pin.givers = format(L["%d Quest Givers"], #entry.givers), entry.givers
        pin.count:SetText(#entry.givers)
        pin.count:Show()
    else
        pin.name, pin.quests = entry.name, entry.shown
    end
    local repeatable, trivial = true, true
    for _, quest in ipairs(entry.shown) do
        repeatable = repeatable and quest.repeatable
        trivial = trivial and quest.trivial
    end
    pin.icon:SetTexture(repeatable and DAILY_ICON or QUEST_ICON)
    pin.icon:SetTexCoord(0, 1, 0, 1)
    pin.icon:SetDesaturated(trivial)
    pin:SetSize(QUEST_SIZE, QUEST_SIZE)
end

local function questsShown(giver, trivial, repeatable)
    local shown = {}
    for _, quest in ipairs(giver.quests) do
        if (trivial or not quest.trivial) and (repeatable or not quest.repeatable) then shown[#shown + 1] = quest end
    end
    return shown
end

-- The same giver twice (an event spawn beside its standing one) is one name in the list.
local function joinGiver(group, giver)
    for _, other in ipairs(group.givers) do
        if other.name == giver.name then
            local known = {}
            for _, quest in ipairs(other.shown) do known[quest.id] = true end
            for _, quest in ipairs(giver.shown) do
                if not known[quest.id] then other.shown[#other.shown + 1] = quest end
            end
            return
        end
    end
    group.givers[#group.givers + 1] = giver
end

-- Each giver joins the first pin within reach, which then sits at the middle of its givers.
local function groupGivers(givers)
    local groups = {}
    for _, giver in ipairs(givers) do
        local home
        for _, group in ipairs(groups) do
            local dx, dy = group.px - giver.px, group.py - giver.py
            if dx * dx + dy * dy < GROUP_RADIUS * GROUP_RADIUS then
                home = group
                break
            end
        end
        if home then
            local n = home.spawns
            home.px, home.py = (home.px * n + giver.px) / (n + 1), (home.py * n + giver.py) / (n + 1)
            home.spawns = n + 1
            joinGiver(home, giver)
        else
            groups[#groups + 1] = { px = giver.px, py = giver.py, spawns = 1, givers = { giver } }
        end
    end
    local merged = {}
    for _, group in ipairs(groups) do
        local entry = group.givers[1]
        if #group.givers > 1 then
            local shown = {}
            for _, giver in ipairs(group.givers) do
                for _, quest in ipairs(giver.shown) do shown[#shown + 1] = quest end
            end
            entry = { givers = group.givers, shown = shown }
        end
        merged[#merged + 1] = { px = group.px, py = group.py, entry = entry }
    end
    return merged
end

local function areaName(id)
    return AREA_NAMES[id] or AREA_NAMES_ENUS[id]
end

local function styleInn(pin, inn)
    pin.name = (inn.room and ROOM_NAMES[inn.room]) or areaName(inn[INN_AREA]) or MINIMAP_TRACKING_INNKEEPER
    pin.kind = MINIMAP_TRACKING_INNKEEPER
    pin.icon:SetAtlasTexture("map-innkeeper")
    pin:SetSize(INN_SIZE, INN_SIZE)
end

local function styleHome(pin, inn)
    styleInn(pin, inn)
    pin.note = HEARTHSTONE .. L["Hearthstone"]
    pin:SetSize(HOME_SIZE, HOME_SIZE)
end

local function indexInns()
    if innByNpc then return innByNpc end
    innByNpc = {}
    for _, inns in pairs(WM.Inns) do
        for _, inn in ipairs(inns) do
            local npcs = inn[INN_NPC]
            if type(npcs) == "table" then
                for _, npc in ipairs(npcs) do innByNpc[npc] = inn end
            else
                innByNpc[npcs] = inn
            end
        end
    end
    return innByNpc
end

local function usable(inn, faction)
    local side = INN_SIDES[inn[INN_SIDE]]
    return not side or side == faction
end

local function named(inn, bind, deep)
    for i = INN_AREA, deep and #inn or INN_AREA do
        if areaName(inn[i]) == bind then return true end
    end
end

-- Matched in the client's own words; a name two usable inns share (Dalaran) picks neither.
local function innNamed(bind)
    local faction = UnitFactionGroup("player")
    for _, deep in ipairs({ false, true }) do
        local found
        for _, inns in pairs(WM.Inns) do
            for _, inn in ipairs(inns) do
                if usable(inn, faction) and named(inn, bind, deep) then
                    if found then return nil end
                    found = inn
                end
            end
        end
        if found then return found end
    end
end

-- GetBindLocation() is only a name; the innkeeper seen binding it wins while that name holds.
local function homeInn()
    local bind = GetBindLocation()
    if not bind or bind == "" then return nil end
    local saved = addon.db and addon.db.char and addon.db.char.worldmapHome
    if saved and saved.bind == bind and indexInns()[saved.npc] then return innByNpc[saved.npc] end
    return innNamed(bind)
end

-- A creature GUID string holds its entry at characters 7-12: 0xF130|000127|004A2B.
local function innkeeperOf(unit)
    local guid = UnitGUID(unit)
    local id = guid and tonumber(guid:sub(7, 12), 16)
    return id and indexInns()[id] and id
end

local function rememberBinder(_, event)
    local id = innkeeperOf("npc")
    if id or event == "GOSSIP_SHOW" then binder = id end
end

-- The bind renames a moment after the accept, or never when the new inn shares the old name.
local function onConfirmBinder()
    local npc, before, tries = binder, GetBindLocation(), 0
    if not npc then return end
    local function settle()
        tries = tries + 1
        local now = GetBindLocation()
        if now == before and tries < 5 then
            addon:After(1, settle)
            return
        end
        if addon.db and addon.db.char then
            addon.db.char.worldmapHome = { npc = npc, bind = now }
        end
        WM.RefreshMapPins()
    end
    addon:After(1, settle)
end

-- Overlapping pins slide apart; pins on the exact same point (an instance's wings) fan out.
local function spread(items, width, height)
    for _ = 1, NUDGE_PASSES do
        local moved = false
        for i = 1, #items - 1 do
            local a = items[i]
            for j = i + 1, #items do
                local b = items[j]
                local minDist = (a.size + b.size) * 0.5 * NUDGE_GAP
                local dx, dy = b.px - a.px, b.py - a.py
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist < minDist then
                    if dist < 0.5 then
                        local angle = (i + j) * 2.399
                        dx, dy, dist = math.cos(angle), math.sin(angle), 1
                    end
                    local push = (minDist - dist) / dist * 0.5
                    a.px, a.py = a.px - dx * push, a.py - dy * push
                    b.px, b.py = b.px + dx * push, b.py + dy * push
                    moved = true
                end
            end
        end
        if not moved then break end
    end
    for _, item in ipairs(items) do
        local half = item.size * 0.5
        item.px = math.max(half, math.min(width - half, item.px))
        item.py = math.max(half, math.min(height - half, item.py))
    end
end

-- The pool outlives the map, so a pin handed to something else has to drop the pulse it was
-- running; hidden, its OnUpdate only freezes, and resumes on whatever the pin becomes next.
local function stopFlash(pin)
    if not pin.flashTime then return end
    pin:SetScript("OnUpdate", nil)
    pin.flashTime = nil
    pin.glow:Hide()
    pin.icon:ClearAllPoints()
    pin.icon:SetAllPoints(pin)
end

-- Grows and glows on the beat, fading out as it goes, then hands the icon back to the pin's size.
local function flashUpdate(pin, elapsed)
    local time = (pin.flashTime or 0) + elapsed
    pin.flashTime = time
    if time >= FLASH_SECONDS then
        stopFlash(pin)
        return
    end
    local beat = math.sin(time / FLASH_SECONDS * FLASH_PULSES * math.pi * 2) * 0.5 + 0.5
    local fade = 1 - time / FLASH_SECONDS
    local size = pin:GetWidth() * (1 + FLASH_GROW * beat * fade)
    pin.icon:ClearAllPoints()
    pin.icon:SetPoint("CENTER", pin, "CENTER", 0, 0)
    pin.icon:SetSize(size, size)
    pin.glow:SetSize(size * 2, size * 2)
    pin.glow:SetAlpha(beat * fade)
end

-- One name or a list of them, when the way in is a complex and any of its doors could be it.
local function asked(name)
    if type(pendingFlash) == "table" then
        for _, wanted in ipairs(pendingFlash) do
            if wanted == name then return true end
        end
        return false
    end
    return pendingFlash == name
end

-- Kept until the pin turns up: SetMapByID only draws the new map a frame later.
function WM.FlashEntrance(name)
    pendingFlash, pendingUntil = name, GetTime() + FLASH_PATIENCE
    WM.RefreshMapPins()
end

function WM.RefreshMapPins()
    if pendingFlash and GetTime() > pendingUntil then pendingFlash = nil end
    local flashed = false
    local count = 0
    local scale = WM.canvasScale
    if scale then
        local mapFile = GetMapInfo() or ""
        -- Floors key by level (Dalaran1), so the terrain's pins never land on a floor's own coordinates.
        if not WM.OnTerrainFloor() then mapFile = mapFile .. GetCurrentMapDungeonLevel() end
        local config = WM:Config()
        -- Pins keep one screen size; positions are worked in those units, not the canvas's.
        local width, height = WorldMapButton:GetWidth() * scale, WorldMapButton:GetHeight() * scale
        local items = {}
        local function addAt(px, py, size, style, entry)
            items[#items + 1] = { px = px, py = py, size = size, style = style, entry = entry }
        end
        local function add(x, y, size, style, entry)
            addAt(x * width, y * height, size, style, entry)
        end
        if config.entrances ~= false then
            for _, entry in ipairs(WM.Entrances[mapFile] or EMPTY) do add(entry.x, entry.y, ENTRANCE_SIZE, styleEntrance, entry) end
        end
        if config.flightPoints ~= false then
            local faction = UnitFactionGroup("player")
            for _, entry in ipairs(WM.FlightPoints[mapFile] or EMPTY) do
                if not entry.faction or entry.faction == faction then add(entry.x, entry.y, FLIGHT_SIZE, styleFlightPoint, entry) end
            end
        end
        if config.inns ~= false then
            local home, faction = homeInn(), UnitFactionGroup("player")
            for _, inn in ipairs(WM.Inns[mapFile] or EMPTY) do
                if inn == home then
                    add(inn[INN_X], inn[INN_Y], HOME_SIZE, styleHome, inn)
                elseif usable(inn, faction) then
                    add(inn[INN_X], inn[INN_Y], INN_SIZE, styleInn, inn)
                end
            end
        end
        if config.graveyards ~= false then
            for _, point in ipairs(WM.Graveyards[mapFile] or EMPTY) do add(point[1], point[2], GRAVEYARD_H, styleGraveyard) end
        end
        -- The server places givers on the zone's terrain map; a floor has coordinates of its own.
        local area = (GetCurrentMapAreaID() or 0) - 1
        if config.questGivers ~= false and area > 0 and WM.OnTerrainFloor() then
            local trivial, repeatable = config.trivialQuests == true, config.repeatableQuests ~= false
            local givers = {}
            for _, giver in ipairs(WM.QuestGivers(area) or EMPTY) do
                local shown = questsShown(giver, trivial, repeatable)
                if #shown > 0 then
                    givers[#givers + 1] = { px = giver.x * width, py = giver.y * height, name = giver.name, shown = shown }
                end
            end
            if config.groupQuestGivers ~= false then
                for _, group in ipairs(groupGivers(givers)) do addAt(group.px, group.py, QUEST_SIZE, styleQuestGiver, group.entry) end
            else
                for _, giver in ipairs(givers) do addAt(giver.px, giver.py, QUEST_SIZE, styleQuestGiver, giver) end
            end
        end
        spread(items, width, height)

        -- Placed last to first so entrances, added first, draw on top of what they overlap.
        local pinScale = 1 / scale
        for index = #items, 1, -1 do
            local item = items[index]
            count = count + 1
            local pin = acquire(count)
            local previous = pin.name
            pin.note, pin.quests, pin.givers = nil, nil, nil
            pin.icon:SetDesaturated(false)
            pin.count:Hide()
            item.style(pin, item.entry)
            if pin.name ~= previous then stopFlash(pin) end
            pin:SetScale(pinScale)
            pin:ClearAllPoints()
            pin:SetPoint("CENTER", WorldMapButton, "TOPLEFT", item.px, -item.py)
            pin:Show()
            if pendingFlash and asked(pin.name) then
                flashed = true
                pin.flashTime = 0
                pin.glow:Show()
                pin:SetScript("OnUpdate", flashUpdate)
            end
        end
    end
    for index = count + 1, #pool do
        stopFlash(pool[index])
        pool[index]:Hide()
    end
    -- Cleared only once the pass is done, so every door of a complex gets lit, not just the first.
    if flashed then pendingFlash = nil end
end

function WM.BuildMapPins()
    hooksecurefunc("WorldMapFrame_Update", WM.RefreshMapPins)
    hooksecurefunc("ConfirmBinder", onConfirmBinder)
    local events = CreateFrame("Frame")
    events:RegisterEvent("GOSSIP_SHOW")
    events:RegisterEvent("CONFIRM_BINDER")
    events:SetScript("OnEvent", rememberBinder)
end
