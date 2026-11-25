-- Licensed under the MIT License; see LICENSE.

local addon = select(2, ...)

-- =============================================================================
-- CLASS TWEAKS (rogue poison auto-apply)
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

local function OnMessage(msg)
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
        -- Once per session (login or /reload); other classes never ask and never listen.
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        if select(2, UnitClass("player")) ~= "ROGUE" then return end
        self:RegisterEvent("CHAT_MSG_ADDON")
        addon:After(HELLO_DELAY, function() Send("HELLO 1") end)
    elseif prefix == PREFIX and channel == "WHISPER" and sender == UnitName("player") and type(msg) == "string" then
        -- Our own HELLO and SET come back too (whispers to yourself); only STATE is read.
        OnMessage(msg)
    end
end)
