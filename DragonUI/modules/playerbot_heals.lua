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
-- request at logout. Another addon's goodbye (Improved Raid Frames with its own option off) would
-- stop the heals for everyone, so while this option is on DragonUI asks again straight after it.
-- =============================================================================

local PREFIX = "IRFBH"
local HELLO = "HELLO:1"
local BYE = "BYE:1"
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

-- "Server module: mod-playerbot-heal-tracker detected (version 1.0.0)", worded and coloured
-- like Improved Raid Frames' own line.
local GREEN, YELLOW, RED, GREY = "|cff8cc152", "|cffffd100", "|cffff5050", "|cff9d9d9d"

function BH.GetStatusText()
    local state, status = BH.state
    if state == "detected" then
        local version = BH.version and BH.version ~= "" and BH.version or tostring(BH.protocol or 1)
        status = GREEN .. string.format(L["mod-playerbot-heal-tracker detected (version %s)"] or "mod-playerbot-heal-tracker detected (version %s)", version)
    elseif state == "tooNew" then
        status = RED .. string.format(L["mod-playerbot-heal-tracker is newer (protocol %d) than this DragonUI supports; update DragonUI"] or "mod-playerbot-heal-tracker is newer (protocol %d) than this DragonUI supports; update DragonUI", BH.protocol or 0)
    elseif not IsEnabled() then
        status = GREY .. (L["not checked (option off)"] or "not checked (option off)")
    elseif state == "waiting" then
        status = YELLOW .. (L["checking..."] or "checking...")
    elseif state == "missing" then
        status = RED .. (L["not detected on this server"] or "not detected on this server")
    else
        return ""
    end
    return "|cffffffff" .. (L["Server module:"] or "Server module:") .. "|r " .. status .. "|r"
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
    -- Whispers to yourself come back, so another addon's goodbye is seen here too.
    if message == BYE then
        if IsEnabled() then
            addon:After(0.2, function()
                local me = UnitName("player")
                if IsEnabled() and me then SendAddonMessage(PREFIX, HELLO, "WHISPER", me) end
            end)
        end
        return
    end
    -- "ACK:<protocol>:<version>"; also arrives for Improved Raid Frames' own HELLO.
    local protocolText, version = message:match("^ACK:(%d+):?(.*)$")
    local protocol = tonumber(protocolText)
    if not protocol then return end
    BH.protocol = protocol
    BH.version = version
    waitToken = waitToken + 1
    SetState(protocol > SUPPORTED_PROTOCOL and "tooNew" or "detected")
end)
