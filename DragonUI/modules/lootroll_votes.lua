-- Licensed under the MIT License; see LICENSE.

local addon = select(2, ...)
local L = addon.L

-- =============================================================================
-- LOOT ROLL TRACKER
-- Who chose what on each group loot roll, listed beside the roll windows and kept after your
-- own window closes (Blizzard hides it as soon as you choose), until the winner is known.
-- The 3.3.5 client reports other players' choices only as loot chat lines, so those are read
-- with Blizzard's own (localized) message formats. Rolling stays Blizzard's: the only
-- RollOnLoot calls here are on rolls Blizzard never gave a window (it has four), and a
-- bind-on-pickup item still asks for Blizzard's confirmation.
-- =============================================================================

local NEED, GREED, DISENCHANT, PASS = 1, 2, 3, 0
local ROW_WIDTH = 250
local ICON_SIZE = 26
local TEXT_INDENT = ICON_SIZE + 10
local BUTTON_SIZE = 22
local KEEP_FINISHED = 10      -- seconds a decided roll stays listed
local STALE_AFTER = 30        -- seconds past its timer a roll is dropped if no result arrived
local TICK = 0.5
local RAID_NAME_LIMIT = 6     -- names listed per choice in a raid before "+N"

local CHOICE_ICON = {
    [NEED] = "Interface\\Buttons\\UI-GroupLoot-Dice-Up",
    [GREED] = "Interface\\Buttons\\UI-GroupLoot-Coin-Up",
    [DISENCHANT] = "Interface\\Buttons\\UI-GroupLoot-DE-Up",
}
local CHOICE_COLOR = {
    [NEED] = "|cff40ff40",
    [GREED] = "|cffffd100",
    [DISENCHANT] = "|cffc080ff",
    [PASS] = "|cff999999",
}

local function ChoiceLabel(choice)
    if choice == NEED then return _G.NEED or "Need" end
    if choice == GREED then return _G.GREED or "Greed" end
    if choice == DISENCHANT then return _G.ROLL_DISENCHANT or "Disenchant" end
    return _G.PASS or "Pass"
end

local function GetConfig()
    return addon.db and addon.db.profile and addon.db.profile.lootroll
end

local function IsEnabled()
    local cfg = GetConfig()
    return not cfg or cfg.voteTracker ~= false
end

-- =============================================================================
-- CHAT PARSING
-- =============================================================================

local MAGIC = {
    ["^"] = true, ["$"] = true, ["("] = true, [")"] = true, ["%"] = true, ["."] = true,
    ["["] = true, ["]"] = true, ["*"] = true, ["+"] = true, ["-"] = true, ["?"] = true,
}

-- A GlobalStrings format ("%s won: %s", "%1$s won: %3$s ...") as an anchored pattern, plus which
-- format argument each capture holds.
local function ToPattern(fmt)
    local out, order, nextArg, i = {}, {}, 0, 1
    while i <= #fmt do
        local c = fmt:sub(i, i)
        if c == "%" then
            local pos, kind, after = fmt:match("^(%d)%$([sd])()", i + 1)
            if not pos then
                kind = fmt:match("^([sd])", i + 1)
                if kind then
                    nextArg = nextArg + 1
                    pos, after = nextArg, i + 2
                end
            end
            if kind then
                order[#order + 1] = tonumber(pos)
                out[#out + 1] = kind == "d" and "(%d+)" or "(.+)"
                i = after
            else
                out[#out + 1] = "%%"
                i = i + 2
            end
        else
            out[#out + 1] = MAGIC[c] and ("%" .. c) or c
            i = i + 1
        end
    end
    return "^" .. table.concat(out) .. "$", order
end

-- Most specific first: "You won" before "%s won", "automatically passed" before "passed".
-- Fields name the format argument holding the player, item link and roll; no player = you.
local MESSAGE_FORMATS = {
    { "LOOT_ROLL_PASSED_SELF_AUTO", "vote", PASS, link = 1, auto = true },
    { "LOOT_ROLL_PASSED_AUTO", "vote", PASS, name = 1, link = 2, auto = true },
    { "LOOT_ROLL_PASSED_AUTO_FEMALE", "vote", PASS, name = 1, link = 2, auto = true },
    { "LOOT_ROLL_NEED_SELF", "vote", NEED, link = 1 },
    { "LOOT_ROLL_GREED_SELF", "vote", GREED, link = 1 },
    { "LOOT_ROLL_DISENCHANT_SELF", "vote", DISENCHANT, link = 1 },
    { "LOOT_ROLL_PASSED_SELF", "vote", PASS, link = 1 },
    { "LOOT_ROLL_YOU_WON_NO_SPAM_NEED", "won", NEED, roll = 1, link = 2 },
    { "LOOT_ROLL_YOU_WON_NO_SPAM_GREED", "won", GREED, roll = 1, link = 2 },
    { "LOOT_ROLL_YOU_WON_NO_SPAM_DE", "won", DISENCHANT, roll = 1, link = 2 },
    { "LOOT_ROLL_YOU_WON", "won", nil, link = 1 },
    { "LOOT_ROLL_WON_NO_SPAM_NEED", "won", NEED, name = 1, roll = 2, link = 3 },
    { "LOOT_ROLL_WON_NO_SPAM_GREED", "won", GREED, name = 1, roll = 2, link = 3 },
    { "LOOT_ROLL_WON_NO_SPAM_DE", "won", DISENCHANT, name = 1, roll = 2, link = 3 },
    { "LOOT_ROLL_WON", "won", nil, name = 1, link = 2 },
    { "LOOT_ROLL_ALL_PASSED", "allpassed", nil, link = 1 },
    { "LOOT_ROLL_ROLLED_NEED", "rolled", NEED, roll = 1, link = 2, name = 3 },
    { "LOOT_ROLL_ROLLED_GREED", "rolled", GREED, roll = 1, link = 2, name = 3 },
    { "LOOT_ROLL_ROLLED_DE", "rolled", DISENCHANT, roll = 1, link = 2, name = 3 },
    { "LOOT_ROLL_NEED", "vote", NEED, name = 1, link = 2 },
    { "LOOT_ROLL_GREED", "vote", GREED, name = 1, link = 2 },
    { "LOOT_ROLL_DISENCHANT", "vote", DISENCHANT, name = 1, link = 2 },
    { "LOOT_ROLL_PASSED", "vote", PASS, name = 1, link = 2 },
}

local parsers -- built on first use, once GlobalStrings are certainly loaded
local captured = {}

local function BuildParsers()
    parsers = {}
    for _, entry in ipairs(MESSAGE_FORMATS) do
        local fmt = _G[entry[1]]
        if type(fmt) == "string" then
            local pattern, order = ToPattern(fmt)
            parsers[#parsers + 1] = { pattern = pattern, order = order, entry = entry }
        end
    end
end

-- The message's kind, choice, player, item link and roll, or nil for other loot lines.
local function Parse(msg)
    if not parsers then BuildParsers() end
    for _, parser in ipairs(parsers) do
        local a, b, c = msg:match(parser.pattern)
        if a then
            captured[parser.order[1] or 0], captured[parser.order[2] or 0], captured[parser.order[3] or 0] = a, b, c
            local entry = parser.entry
            local name = entry.name and captured[entry.name]
            if not name or name == _G.YOU then name = UnitName("player") end
            local roll = entry.roll and tonumber(captured[entry.roll]) or nil
            local link = captured[entry.link]
            captured[1], captured[2], captured[3], captured[0] = nil, nil, nil, nil
            return entry[2], entry[3], name, link, roll, entry.auto
        end
    end
end

-- Item and random suffix: the same item from the same roll, however the link was written.
local function ItemKey(link)
    if not link then return nil end
    local id, suffix = link:match("item:(%-?%d+):%-?%d+:%-?%d+:%-?%d+:%-?%d+:%-?%d+:(%-?%d+)")
    if id then return id .. ":" .. suffix end
    return link:match("item:(%-?%d+)") or link
end

-- =============================================================================
-- ROLLS
-- =============================================================================

local rolls = {}   -- oldest first
local Render       -- forward

local function FindRoll(key, wantVoter, name)
    for _, roll in ipairs(rolls) do
        if roll.key == key and not roll.finished then
            local vote = roll.votes[name]
            if wantVoter == "new" and not vote then return roll end
            if wantVoter == "unrolled" and vote and not vote.roll then return roll end
            if wantVoter == nil then return roll end
        end
    end
end

local function OnStart(rollID, rollTime)
    local texture, name, count, quality, bindOnPickUp, canNeed, canGreed, canDisenchant = GetLootRollItemInfo(rollID)
    if not name then return end
    local link = GetLootRollItemLink(rollID)
    rolls[#rolls + 1] = {
        id = rollID, link = link, key = ItemKey(link), name = name, texture = texture,
        count = count, quality = quality or 1, bindOnPickUp = bindOnPickUp,
        canRoll = { [NEED] = canNeed, [GREED] = canGreed, [DISENCHANT] = canDisenchant, [PASS] = true },
        started = GetTime(), duration = (tonumber(rollTime) or 60000) / 1000,
        votes = {}, order = {},
    }
end

-- Two of the same item: everyone votes once per roll, so each vote goes to the oldest roll
-- for that item the player has not voted on yet.
local function OnLootMessage(msg)
    local kind, choice, name, link, number, auto = Parse(msg)
    if not kind then return false end
    local key = ItemKey(link)
    if kind == "vote" then
        local roll = FindRoll(key, "new", name)
        if not roll then return false end
        roll.votes[name] = { choice = choice, auto = auto }
        roll.order[#roll.order + 1] = name
    elseif kind == "rolled" then
        local roll = FindRoll(key, "unrolled", name)
        if not roll then return false end
        roll.votes[name].roll = number
    elseif kind == "won" or kind == "allpassed" then
        local roll = FindRoll(key, nil, name)
        if not roll then return false end
        roll.finished = GetTime()
        if kind == "won" then
            roll.winner = name
            local vote = roll.votes[name]
            roll.winnerChoice = choice or (vote and vote.choice)
            roll.winnerRoll = number or (vote and vote.roll)
        else
            roll.allPassed = true
        end
    end
    return true
end

local function HasBlizzardWindow(rollID)
    for i = 1, NUM_GROUP_LOOT_FRAMES or 4 do
        local frame = _G["GroupLootFrame" .. i]
        if frame and frame:IsShown() and frame.rollID == rollID then
            return true
        end
    end
    return false
end

-- =============================================================================
-- GROUP
-- =============================================================================

local roster, rosterSize = {}, 0   -- name -> class file

local function ReadRoster()
    for name in pairs(roster) do roster[name] = nil end
    rosterSize = 0
    local raid = GetNumRaidMembers()
    if raid > 0 then
        for i = 1, raid do
            local name, _, _, _, _, class = GetRaidRosterInfo(i)
            if name then roster[name] = class or true; rosterSize = rosterSize + 1 end
        end
    else
        local function add(unit)
            local name = UnitName(unit)
            if name then
                local _, class = UnitClass(unit)
                roster[name] = class or true
                rosterSize = rosterSize + 1
            end
        end
        add("player")
        for i = 1, GetNumPartyMembers() do add("party" .. i) end
    end
end

local function ColoredName(name)
    local me = UnitName("player")
    local class = roster[name]
    local color = type(class) == "string" and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    local label = name == me and (L["You"] or "You") or name
    if color then
        return string.format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, label)
    end
    return label
end

-- =============================================================================
-- TRACKER FRAME
-- =============================================================================

local tracker
local rows = {}
local scratch = {}

local function CreateRollButton(row, choice)
    local button = CreateFrame("Button", nil, row)
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    if choice == PASS then
        button:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
        button:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
        button:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
    else
        local art = CHOICE_ICON[choice]
        button:SetNormalTexture(art)
        button:SetPushedTexture((art:gsub("%-Up$", "-Down")))
        button:SetHighlightTexture((art:gsub("%-Up$", "-Highlight")), "ADD")
    end
    button.choice = choice
    button:SetScript("OnClick", function(self)
        local roll = self:GetParent().roll
        if roll and not roll.finished then
            RollOnLoot(roll.id, self.choice)
        end
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(ChoiceLabel(self.choice))
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return button
end

local function RowOnEnter(self)
    local roll = self.roll
    if not roll then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    if roll.link then
        GameTooltip:SetHyperlink(roll.link)
    else
        GameTooltip:SetText(roll.name)
    end
    GameTooltip:AddLine(" ")
    for _, name in ipairs(roll.order) do
        local vote = roll.votes[name]
        local right = CHOICE_COLOR[vote.choice] .. ChoiceLabel(vote.choice)
            .. (vote.roll and (" " .. vote.roll) or "") .. "|r"
        GameTooltip:AddDoubleLine(ColoredName(name), right)
    end
    GameTooltip:Show()
end

local function CreateRow()
    local row = CreateFrame("Frame", nil, tracker)
    row:SetWidth(ROW_WIDTH)
    row:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    row:SetBackdropColor(0, 0, 0, 0.8)
    row:EnableMouse(true)
    row:SetScript("OnEnter", RowOnEnter)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON_SIZE, ICON_SIZE)
    row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -6)

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.title:SetPoint("TOPLEFT", row, "TOPLEFT", TEXT_INDENT, -6)
    row.title:SetWidth(ROW_WIDTH - TEXT_INDENT - 6)
    row.title:SetJustifyH("LEFT")
    if row.title.SetWordWrap then row.title:SetWordWrap(false) end

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -3)
    row.text:SetWidth(ROW_WIDTH - TEXT_INDENT - 6)
    row.text:SetJustifyH("LEFT")
    row.text:SetSpacing(2)

    row.buttons = {}
    for i, choice in ipairs({ NEED, GREED, DISENCHANT, PASS }) do
        row.buttons[i] = CreateRollButton(row, choice)
    end
    return row
end

-- "Need: Thrall 87, You" and so on; in a raid only Need lists names, the rest are counted.
local function ChoiceLine(roll, choice, listNames)
    local count = 0
    for k in pairs(scratch) do scratch[k] = nil end
    for _, name in ipairs(roll.order) do
        local vote = roll.votes[name]
        if vote.choice == choice then
            count = count + 1
            if listNames and count <= RAID_NAME_LIMIT then
                scratch[#scratch + 1] = ColoredName(name) .. (vote.roll and (" |cffffffff" .. vote.roll .. "|r") or "")
            end
        end
    end
    if count == 0 then return nil end
    local icon = CHOICE_ICON[choice] and ("|T" .. CHOICE_ICON[choice] .. ":14:14|t ") or ""
    local label = icon .. CHOICE_COLOR[choice] .. ChoiceLabel(choice) .. "|r"
    if not listNames then
        return label .. ": " .. count
    end
    local extra = count - #scratch
    return label .. ": " .. table.concat(scratch, ", ") .. (extra > 0 and (" +" .. extra) or "")
end

local function WaitingLine(roll)
    local waiting = 0
    for k in pairs(scratch) do scratch[k] = nil end
    for name in pairs(roster) do
        if not roll.votes[name] then
            waiting = waiting + 1
            scratch[#scratch + 1] = ColoredName(name)
        end
    end
    if waiting == 0 then return nil end
    local label = "|cff808080" .. (L["Waiting"] or "Waiting") .. "|r: "
    if waiting > 5 then return label .. waiting end
    table.sort(scratch)
    return label .. table.concat(scratch, ", ")
end

local function NeedsButtons(roll, now)
    return not roll.finished and not roll.votes[UnitName("player")]
        and now < roll.started + roll.duration and not HasBlizzardWindow(roll.id)
end

local lines = {}

local function FillRow(row, roll, now)
    row.roll = roll
    row.icon:SetTexture(roll.texture)
    local r, g, b = GetItemQualityColor(roll.quality)
    row.title:SetText(roll.name .. ((roll.count or 1) > 1 and (" x" .. roll.count) or ""))
    row.title:SetTextColor(r, g, b)
    row:SetBackdropBorderColor(r, g, b, 0.9)

    for k in pairs(lines) do lines[k] = nil end
    if roll.finished then
        if roll.allPassed then
            lines[#lines + 1] = "|cff999999" .. (L["Everyone passed"] or "Everyone passed") .. "|r"
        elseif roll.winner then
            local how = roll.winnerChoice and (" (" .. ChoiceLabel(roll.winnerChoice)
                .. (roll.winnerRoll and (" " .. roll.winnerRoll) or "") .. ")") or ""
            lines[#lines + 1] = "|cffffd100" .. string.format(L["Won by %s"] or "Won by %s", ColoredName(roll.winner)) .. how .. "|r"
            row:SetBackdropBorderColor(1, 0.82, 0, 1)
        end
    end
    local listAll = rosterSize <= 5
    for _, choice in ipairs({ NEED, GREED, DISENCHANT, PASS }) do
        local line = ChoiceLine(roll, choice, listAll or choice == NEED)
        if line then lines[#lines + 1] = line end
    end
    if not roll.finished then
        local waiting = WaitingLine(roll)
        if waiting then lines[#lines + 1] = waiting end
    end

    local buttons = NeedsButtons(roll, now)
    if buttons then
        local left = math.max(0, math.floor(roll.started + roll.duration - now))
        lines[#lines + 1] = "|cffff4040" .. string.format(L["No roll window: choose here (%ds)"] or "No roll window: choose here (%ds)", left) .. "|r"
    end
    row.text:SetText(table.concat(lines, "\n"))

    local height = 6 + row.title:GetStringHeight() + 3 + row.text:GetStringHeight() + 6
    local x = TEXT_INDENT
    for _, button in ipairs(row.buttons) do
        if buttons and roll.canRoll[button.choice] then
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", row.text, "BOTTOMLEFT", x - TEXT_INDENT, -3)
            button:Show()
            x = x + BUTTON_SIZE + 4
        else
            button:Hide()
        end
    end
    if buttons then height = height + BUTTON_SIZE + 3 end
    row:SetHeight(math.max(ICON_SIZE + 12, height))
end

local function Prune(now)
    for i = #rolls, 1, -1 do
        local roll = rolls[i]
        if (roll.finished and now - roll.finished > KEEP_FINISHED)
            or (not roll.finished and now > roll.started + roll.duration + STALE_AFTER) then
            table.remove(rolls, i)
        end
    end
end

local function AnchorTracker()
    local anchor = _G.DragonUI_LootRollAnchor or _G.GroupLootFrame1
    tracker:ClearAllPoints()
    if anchor then
        tracker:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", 12, 0)
    else
        tracker:SetPoint("BOTTOM", UIParent, "BOTTOM", 280, 220)
    end
end

-- Oldest roll at the bottom, the stack growing upwards like Blizzard's roll windows.
Render = function()
    local now = GetTime()
    Prune(now)
    if #rolls == 0 or not IsEnabled() then
        tracker:Hide()
        return
    end
    ReadRoster()
    local previous
    for i, roll in ipairs(rolls) do
        local row = rows[i] or CreateRow()
        rows[i] = row
        FillRow(row, roll, now)
        row:ClearAllPoints()
        if previous then
            row:SetPoint("BOTTOMLEFT", previous, "TOPLEFT", 0, 4)
        else
            row:SetPoint("BOTTOMLEFT", tracker, "BOTTOMLEFT", 0, 0)
        end
        row:Show()
        previous = row
    end
    for i = #rolls + 1, #rows do
        rows[i].roll = nil
        rows[i]:Hide()
    end
    AnchorTracker()
    tracker:Show()
end

-- =============================================================================
-- EVENTS
-- =============================================================================

tracker = CreateFrame("Frame", "DragonUI_LootRollTracker", UIParent)
tracker:SetFrameStrata("DIALOG")
tracker:SetSize(ROW_WIDTH, 1)
tracker:Hide()

-- Only runs while rolls are listed: timers on window-less rolls, and dropping finished ones.
local sinceTick = 0
tracker:SetScript("OnUpdate", function(_, elapsed)
    sinceTick = sinceTick + elapsed
    if sinceTick < TICK then return end
    sinceTick = 0
    Render()
end)

tracker:RegisterEvent("START_LOOT_ROLL")
tracker:RegisterEvent("CANCEL_LOOT_ROLL")
tracker:RegisterEvent("CHAT_MSG_LOOT")
tracker:SetScript("OnEvent", function(_, event, arg1, arg2)
    if not IsEnabled() then
        for i = #rolls, 1, -1 do rolls[i] = nil end
        tracker:Hide()
        return
    end
    if event == "START_LOOT_ROLL" then
        OnStart(arg1, arg2)
    elseif event == "CHAT_MSG_LOOT" then
        if not OnLootMessage(arg1) then return end
    end
    Render()
end)

function addon.RefreshLootRollTracker()
    if tracker then Render() end
end
