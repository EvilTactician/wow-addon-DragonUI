-- Licensed under the MIT License; see LICENSE.

local addon = select(2, ...)
local L = addon.L

-- =============================================================================
-- PLAYERBOT HEALS
-- Servers running mod-playerbot-heal-tracker send playerbot heals as ordinary LibHealComm-4.0
-- messages, but only to players who ask for them. This asks (a whisper to yourself the module
-- answers), so DragonUI's heal prediction on unit frames and nameplates includes bot heals without
-- Improved Raid Frames. LibHealComm reads the heal messages themselves; nothing else is needed.
-- Never says goodbye: Improved Raid Frames may still want the heals, and the server forgets the
-- request at logout.
-- =============================================================================

local PREFIX = "IRFBH"
local HELLO = "HELLO:1"
local SUPPORTED_PROTOCOL = 1
local ACK_WAIT = 10

local BH = { state = "off" } -- off | waiting | detected | missing | tooNew
addon.BotHeals = BH

local function IsEnabled()
    local modules = addon.db and addon.db.profile and addon.db.profile.modules
    local cfg = modules and modules.playerbot_heals
    return cfg and cfg.enabled == true
end

local function SetState(state)
    BH.state = state
    if BH.onStatusChanged then BH.onStatusChanged() end
end

local waitToken = 0

function BH.SendHello()
    if not IsEnabled() then return end
    local me = UnitName("player")
    if not me then return end
    SendAddonMessage(PREFIX, HELLO, "WHISPER", me)
    -- Once the module has answered there is no need to report "checking" again.
    if BH.state == "detected" or BH.state == "tooNew" then return end
    SetState("waiting")
    waitToken = waitToken + 1
    local token = waitToken
    addon:After(ACK_WAIT, function()
        if token == waitToken and BH.state == "waiting" then
            SetState("missing")
        end
    end)
end

-- Option switched on or off. Off only stops asking: the heals already requested keep coming
-- until logout, which is harmless.
function BH.Refresh()
    if IsEnabled() then
        BH.SendHello()
    elseif BH.state == "waiting" or BH.state == "missing" then
        waitToken = waitToken + 1
        SetState("off")
    elseif BH.onStatusChanged then
        BH.onStatusChanged()
    end
end

function BH.GetStatusText()
    local enabled = IsEnabled()
    local state = BH.state
    if state == "detected" then
        local text = string.format(L["Server module detected (protocol %d)."] or "Server module detected (protocol %d).", BH.protocol or 1)
        return enabled and text or ((L["Off."] or "Off.") .. " " .. text)
    elseif state == "tooNew" then
        return string.format(L["The server module uses a newer protocol (%d) than this DragonUI understands; update DragonUI."] or "The server module uses a newer protocol (%d) than this DragonUI understands; update DragonUI.", BH.protocol or 0)
    elseif not enabled then
        return L["Off."] or "Off."
    elseif state == "waiting" then
        return L["Checking for the server module..."] or "Checking for the server module..."
    elseif state == "missing" then
        return L["Server module not detected on this server."] or "Server module not detected on this server."
    end
    return ""
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("CHAT_MSG_ADDON")
events:SetScript("OnEvent", function(_, event, prefix, message, _, sender)
    if event == "PLAYER_ENTERING_WORLD" then
        -- Every time, not just the first: a reload keeps the request, a reconnect does not.
        BH.SendHello()
        return
    end
    if prefix ~= PREFIX or sender ~= UnitName("player") or type(message) ~= "string" then return end
    -- "ACK:<protocol>:<version>"; also arrives for Improved Raid Frames' own HELLO.
    local protocol = tonumber(message:match("^ACK:(%d+)"))
    if not protocol then return end
    BH.protocol = protocol
    waitToken = waitToken + 1
    SetState(protocol > SUPPORTED_PROTOCOL and "tooNew" or "detected")
end)
