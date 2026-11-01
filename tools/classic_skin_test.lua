-- Run from the repository root with Lua 5.1.
local DIR = [[Interface\AddOns\DragonUI\Textures\]]
local ROCK = DIR .. [[UI\ui-background-rock]]
local CLASSIC_ROCK = DIR .. [[Skins\Classic\ui-background-rock]]

local hooks, frames

local function newWorld()
    hooks, frames = 0, {}
    local textureMethods = {}
    function textureMethods:SetTexture(path) self.path = path end
    function textureMethods:GetTexture() return self.path end
    function textureMethods:GetObjectType() return "Texture" end
    local textureMeta = { __index = textureMethods }

    local function texture()
        return setmetatable({}, textureMeta)
    end

    local frameMethods = {}
    function frameMethods:CreateTexture() return texture() end
    function frameMethods:GetRegions() return unpack(self.regions or {}) end
    local frameMeta = { __index = frameMethods }

    local buttonMethods = {}
    function buttonMethods:SetNormalTexture(path)
        self.normal = self.normal or texture()
        self.normal.path = path
    end
    function buttonMethods:GetNormalTexture() return self.normal end
    for _, name in ipairs({ "Pushed", "Disabled", "Highlight" }) do
        buttonMethods["Set" .. name .. "Texture"] = function() end
        buttonMethods["Get" .. name .. "Texture"] = function() end
    end
    local buttonMeta = { __index = buttonMethods }
    local checkMethods = setmetatable({}, { __index = buttonMethods })
    for key, fn in pairs(buttonMethods) do checkMethods[key] = fn end
    local checkMeta = { __index = checkMethods }

    function CreateFrame(kind)
        local meta = kind == "Button" and buttonMeta or kind == "CheckButton" and checkMeta or frameMeta
        return setmetatable({}, meta)
    end

    function hooksecurefunc(owner, name, post)
        hooks = hooks + 1
        local original = owner[name]
        owner[name] = function(...)
            original(...)
            post(...)
        end
    end

    function EnumerateFrames(after)
        if not after then return frames[1] end
        for i, frame in ipairs(frames) do
            if frame == after then return frames[i + 1] end
        end
    end
end

local function loadSkins(skin)
    newWorld()
    local painted = setmetatable({}, { __index = { GetObjectType = function() return "Texture" end,
        GetTexture = function(self) return self.path end,
        SetTexture = function(self, path) self.path = path end } })
    painted.path = ROCK
    local other = setmetatable({ path = DIR .. [[UI\something-else]] }, getmetatable(painted))
    frames[1] = setmetatable({ regions = { painted, other } }, { __index = { GetRegions = function(self) return unpack(self.regions) end } })

    local addon = { _dir = DIR, db = { profile = { style = { skin = skin } } } }
    assert(loadfile("DragonUI/utils/skins.lua"))("DragonUI", addon)
    addon.Skins.Apply()
    return addon, painted, other
end

-- The default skin leaves every widget method alone.
do
    local addon, painted = loadSkins("forever")
    assert(hooks == 0, "default skin must install no hooks")
    assert(addon.Skins.Current() == "forever")
    assert(addon.Skins.Path(ROCK) == ROCK)
    assert(painted.path == ROCK, "default skin must not sweep")
end

-- An unknown or missing setting falls back the same way.
do
    local addon = loadSkins("nonsense")
    assert(hooks == 0 and addon.Skins.Current() == "forever")
    addon = loadSkins(nil)
    assert(hooks == 0 and addon.Skins.Current() == "forever")
end

-- Classic swaps setters, sweeps earlier paints and leaves everything else.
do
    local addon, painted, other = loadSkins("classic")
    assert(addon.Skins.Current() == "classic")
    assert(painted.path == CLASSIC_ROCK, "painted before the settings were readable")
    assert(other.path == DIR .. [[UI\something-else]], "unrelated path untouched")
    assert(addon.Skins.Path(ROCK) == CLASSIC_ROCK)

    local probe = CreateFrame("Frame")
    local texture = probe:CreateTexture()
    texture:SetTexture(ROCK)
    assert(texture:GetTexture() == CLASSIC_ROCK, "SetTexture swapped")
    texture:SetTexture(DIR .. [[UI\something-else]])
    assert(texture:GetTexture() == DIR .. [[UI\something-else]])
    texture:SetTexture(nil)
    assert(texture:GetTexture() == nil, "clearing a texture must not error or swap")
    texture:SetTexture(0, 0, 0, 0.5)
    assert(texture:GetTexture() == 0, "colour fill passes through")

    for _, kind in ipairs({ "Button", "CheckButton" }) do
        local button = CreateFrame(kind)
        button:SetNormalTexture(ROCK)
        assert(button:GetNormalTexture():GetTexture() == CLASSIC_ROCK, kind .. " setter swapped")
    end

    -- Read once per load: a later Apply must not stack hooks.
    local count = hooks
    addon.Skins.Apply()
    assert(hooks == count, "Apply must run once")
end

-- Every sheet the skin swaps to is on disk, and every sheet it swaps from still exists.
do
    local addon = loadSkins("classic")
    local function onDisk(path)
        local file = path:gsub("%.%a+$", ""):gsub("^Interface\\AddOns\\", ""):gsub("\\", "/")
        for _, extension in ipairs({ ".tga", ".blp" }) do
            local handle = io.open(file .. extension, "rb")
            if handle then
                handle:close()
                return true
            end
        end
    end
    local count = 0
    for forever, classic in pairs(addon.Skins.map) do
        assert(onDisk(forever), forever .. " is gone")
        assert(onDisk(classic), classic .. " is not baked")
        count = count + 1
    end
    -- Each sheet is mapped bare, .tga and .blp: 48 HUD and window sheets, 22 for the decorated windows, 86 talent halves.
    assert(count == 3 * (48 + 22 + 86), "expected the sheet list, got " .. count)
end

-- A class's spec sheets share its one three-tree sheet; the glyph page shares one ground.
do
    local addon = loadSkins("classic")
    local CLASSIC = DIR .. [[Skins\Classic\Talents\]]
    assert(addon.Skins.Path(DIR .. [[Talents\talents-bg-warrior]]) == CLASSIC .. "warrior")
    assert(addon.Skins.Path(DIR .. [[Talents\talents-bg-warrior-fury]]) == CLASSIC .. "warrior")
    assert(addon.Skins.Path(DIR .. [[Talents\talents-bg-rogue-outlaw_r]]) == CLASSIC .. "rogue_r")
    assert(addon.Skins.Path(DIR .. [[Talents\Artifact\DeathKnight_r]]) == CLASSIC .. "glyph-ground_r")
    assert(addon.Skins.Path(DIR .. [[Talents\Pet_Cunning]]) == CLASSIC .. "Pet_Cunning")
end

-- A spelled-out extension swaps too, and the frame art follows the skin over the saved setting.
do
    local addon = loadSkins("classic")
    assert(addon.Skins.Path(DIR .. [[ActionBars\uiactionbariconframe.tga]])
        == DIR .. [[Skins\Classic\ActionBars\uiactionbariconframe]])

    addon.compatibility, addon.UF = {}, {}
    addon.db.profile.unitframe = { frame_style = "dragonui" }
    assert(loadfile("DragonUI/modules/unitframes/uf_skins.lua"))("DragonUI", addon)
    assert(addon.UF.GetFrameStyle() == "forever", "Classic draws on Forever's geometry")

    addon = loadSkins("forever")
    addon.compatibility, addon.UF = {}, {}
    addon.db.profile.unitframe = { frame_style = "dragonui" }
    assert(loadfile("DragonUI/modules/unitframes/uf_skins.lua"))("DragonUI", addon)
    assert(addon.UF.GetFrameStyle() == "dragonui", "the saved art stands under the default skin")
end

print("classic skin: default untouched, setter swaps, early paints, unrelated paths and baked sheets passed")
