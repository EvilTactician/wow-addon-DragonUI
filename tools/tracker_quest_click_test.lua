-- Run from the repository root with Lua 5.1.
-- A tracked quest's click opens the map's quest log on that quest's page, the stock log only
-- when the map cannot take it.

local combat = false
function InCombatLockdown() return combat end
function hooksecurefunc() end
function CreateFrame()
    local frame = {}
    function frame:RegisterEvent() end
    function frame:SetScript() end
    function frame:Hide() end
    return frame
end
function IsModifiedClick() return false end
function ExpandQuestHeader() end
function GetQuestSortIndex(index) return index end
function GetQuestIndexForWatch(watch) return watch + 1 end
local questIDs = { [2] = 176, [3] = 0 }
function GetQuestLogTitle(index)
    return "Quest", 10, nil, nil, nil, nil, nil, nil, questIDs[index]
end

local stock
function SelectQuestLogEntry(index) stock = index end
function QuestLog_Update() end
function ShowUIPanel(frame) frame.shown = true end
QuestLogFrame = { IsShown = function(self) return self.shown end }

local focus
local QP = { SIZE = 16 }
function QP.RegisterFocusListener() end
function QP.SetFocus(questID) focus = questID end

local map
local function newMap(applied)
    map = { applied = applied, panel = true, shown = false, opened = nil, detail = nil, flashed = nil }
    return {
        IsApplied = function() return map.applied end,
        PanelShown = function() return map.panel end,
        SetPanelShown = function(shown) map.panel = shown end,
        OpenToQuest = function(questID)
            if combat and not map.shown then return false end
            map.shown, map.opened = true, questID
            return true
        end,
        ShowQuestDetail = function(index) map.detail = index end,
        FlashQuestPOI = function(questID) map.flashed = questID end,
    }
end

local addon = { QuestPOI = QP }
assert(loadfile('DragonUI/modules/objectivetracker.lua'))('DragonUI', addon)
local click = addon.ObjectiveTracker.ClickBlock

local function reset(applied)
    addon.WorldMap = newMap(applied)
    stock, focus, combat, QuestLogFrame.shown = nil, nil, false, nil
end

-- The map's quest log takes the click: map open on the quest, its page showing, the pick focused.
reset(true)
click({ kind = "quest", watchIndex = 1 }, "LeftButton")
assert(map.opened == 176 and map.detail == 2 and focus == 176 and map.flashed == 176, "map quest page did not open")
assert(stock == nil and not QuestLogFrame.shown, "the stock quest log opened too")

-- A hidden panel is shown for it.
reset(true)
map.panel = false
click({ kind = "quest", watchIndex = 1 }, "LeftButton")
assert(map.panel and map.detail == 2, "hidden quest panel was not shown")

-- The menu's View in Quest Log and a quest timer go the same way.
reset(true)
click({ kind = "timer", questLogIndex = 2 }, "LeftButton")
assert(map.detail == 2 and stock == nil, "timer did not open the map quest page")

-- Fallbacks to the stock log: map module off, closed map in combat, hidden panel in combat, no ID.
reset(false)
click({ kind = "quest", watchIndex = 1 }, "LeftButton")
assert(stock == 2 and QuestLogFrame.shown and map.opened == nil, "map module off: stock log did not open")

reset(true)
combat = true
click({ kind = "quest", watchIndex = 1 }, "LeftButton")
assert(stock == 2 and QuestLogFrame.shown and map.detail == nil, "closed map in combat: stock log did not open")

reset(true)
combat, map.shown, map.panel = true, true, false
click({ kind = "quest", watchIndex = 1 }, "LeftButton")
assert(stock == 2 and not map.panel and map.opened == nil, "hidden panel in combat: stock log did not open")

reset(true)
combat, map.shown = true, true
click({ kind = "quest", watchIndex = 1 }, "LeftButton")
assert(map.detail == 2 and stock == nil, "open map in combat: quest page did not open")

reset(true)
click({ kind = "quest", watchIndex = 2 }, "LeftButton")
assert(stock == 3 and map.opened == nil, "quest without an ID: stock log did not open")

print("tracker quest click: ok")
