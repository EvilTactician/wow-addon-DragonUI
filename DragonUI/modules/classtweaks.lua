-- Licensed under the MIT License; see LICENSE.

local addon = select(2, ...)

-- =============================================================================
-- CLASS TWEAKS (rogue poison auto-apply, talent reset)
-- Realms running mod-class-tweaks can put a rogue's weapon poisons back on when they wear off. The
-- realm keeps the choice per character; this file only asks for it and shows it (Enhancements tab).
-- Addon whispers to the player, protocol 1:
--
--   client -> server   HELLO 1              is the module there? (rogues only, once per session)
--                      SET AUTOAPPLY 0|1    dungeons and raids
--                      SET OUTSIDE 0|1      outside dungeons and raids
--   server -> client   STATE 1 <autoapply> <outside> <outsideAllowed>
--                      answer to HELLO and to every SET; outsideAllowed 0 = the realm turned that off
--
-- No STATE means the realm doesn't run the module: nothing shows. Nothing is stored here, and a
-- setting only changes on screen once a STATE confirms it. A later protocol (STATE 2 ...) is ignored.
--
-- Talent reset (any class): the realm unlearns the active spec's talents without a trainer, at the
-- trainer's cost. Used by the talent window's reset button (talents/live_view.lua).
--   client -> server   TALENTS HELLO 1 / TALENTS COST / TALENTS RESET <copper agreed to>
--   server -> client   TALENTS 1 (available) / TALENTS COST <copper> / TALENTS DONE
--                      TALENTS ERR <reason> / TALENTS ERR COST <copper> (went up since agreed)
-- No "TALENTS 1" means the realm doesn't offer it: the reset button keeps its stock behaviour.
-- =============================================================================

local PREFIX = "ClassTweaks"
local HELLO_DELAY = 2

local CT = {}
addon.ClassTweaks = CT

local state     -- nil until the realm answers: { autoApply, outside, outsideAllowed }
local listeners = {}

-- `fn` runs whenever a STATE changes what the settings show.
function CT.OnChange(fn)
    listeners[#listeners + 1] = fn
end

function CT.State()
    return state
end

local function Send(msg)
    local me = UnitName("player")
    if me then SendAddonMessage(PREFIX, msg, "WHISPER", me) end
end

function CT.SetAutoApply(on)
    if state then Send(on and "SET AUTOAPPLY 1" or "SET AUTOAPPLY 0") end
end

function CT.SetOutside(on)
    if state then Send(on and "SET OUTSIDE 1" or "SET OUTSIDE 0") end
end

-- Talent reset ---------------------------------------------------------------------------------------

local talentReset          -- true once the realm said it offers the reset
local costAsked            -- a click asked for the cost; only that answer opens the confirmation
local talentListeners = {}

-- `fn(what, value)` runs on AVAILABLE, COST <copper>, ERR <reason> and DONE.
function CT.OnTalentReset(fn)
    talentListeners[#talentListeners + 1] = fn
end

function CT.TalentResetAvailable()
    return talentReset == true
end

-- Asks for the current cost; the answer comes back as COST.
function CT.RequestTalentReset()
    if not talentReset then return end
    costAsked = true
    Send("TALENTS COST")
end

-- `cost` is what the player agreed to; the realm refuses if a reset now costs more.
function CT.ConfirmTalentReset(cost)
    if talentReset and cost then Send("TALENTS RESET " .. cost) end
end

local function NotifyTalents(what, value)
    for _, fn in ipairs(talentListeners) do fn(what, value) end
end

-- Text after "TALENTS ". Our own requests come back too (HELLO 1, COST, RESET n) and match nothing.
local function OnTalentMessage(text)
    if text == "1" then
        if not talentReset then
            talentReset = true
            NotifyTalents("AVAILABLE")
        end
        return
    end
    if not talentReset then return end

    local cost = text:match("^COST (%d+)$")
    if cost then
        if costAsked then
            costAsked = nil
            NotifyTalents("COST", tonumber(cost))
        end
        return
    end
    cost = text:match("^ERR COST (%d+)$")
    if cost then
        NotifyTalents("COST", tonumber(cost))
        return
    end
    local reason = text:match("^ERR (%u+)$")
    if reason then
        NotifyTalents("ERR", reason)
    elseif text == "DONE" then
        NotifyTalents("DONE")
    end
end

-- Messages ---------------------------------------------------------------------------------------------

local function OnMessage(msg)
    if msg:sub(1, 8) == "TALENTS " then
        OnTalentMessage(msg:sub(9))
        return
    end
    local autoApply, outside, allowed = msg:match("^STATE 1 ([01]) ([01]) ([01])")
    if not autoApply then return end
    autoApply, outside, allowed = autoApply == "1", outside == "1", allowed == "1"
    if state and state.autoApply == autoApply and state.outside == outside
        and state.outsideAllowed == allowed then
        return
    end
    state = { autoApply = autoApply, outside = outside, outsideAllowed = allowed }
    for _, fn in ipairs(listeners) do fn() end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
    if event == "PLAYER_ENTERING_WORLD" then
        -- Once per session (login or /reload). Every class asks about the talent reset; only
        -- rogues ask about poisons.
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        local rogue = select(2, UnitClass("player")) == "ROGUE"
        self:RegisterEvent("CHAT_MSG_ADDON")
        addon:After(HELLO_DELAY, function()
            if rogue then Send("HELLO 1") end
            Send("TALENTS HELLO 1")
        end)
    elseif prefix == PREFIX and channel == "WHISPER" and sender == UnitName("player") and type(msg) == "string" then
        -- Our own requests come back too (whispers to yourself); only the realm's answers are read.
        OnMessage(msg)
    end
end)
