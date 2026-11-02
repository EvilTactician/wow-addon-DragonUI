-- Copyright (c) 2026 NeticSoul. Licensed under the MIT License; see LICENSE.

local addon = select(2, ...)

-- UI Skin (style.skin): another skin's sheets keep the proportions and rects of the ones they stand
-- in for, so every atlas entry and texcoord still lands right and only the path changes. Modules capture
-- their paths at file load, before the saved settings exist, so the swap happens where the path is
-- set: the widgets' own setters, hooked only while a skin other than the default is on. That also
-- reaches the addons that borrow DragonUI's art by path. Changing skin needs a reload.
local Skins = {}
addon.Skins = Skins

Skins.DEFAULT = "forever"

-- tools/build_classic_skin.py bakes these; its --check holds them to their Forever sheets' sizes.
local SKINS = {
	classic = {
		dir = addon._dir .. "Skins\\Classic\\",
		-- The close button at stock size, in the socket the stock band has for it: the hole runs 1.5 to
		-- 20.5 in from the right and 2 to 20 down, and its left rim to 25.
		seat = { closeSize = 19, closeX = -1.5, closeY = -2, closeGap = 5.5 },
		sheets = {
			["ForeverUI\\chrome-frame"] = "chrome-frame",
			["ForeverUI\\chrome-buttons"] = "chrome-buttons",
			["ForeverUI\\chrome-dialog"] = "chrome-dialog",
			["ForeverUI\\chrome-options"] = "chrome-options",
			["ForeverUI\\controls-basic"] = "controls-basic",
			["ForeverUI\\controls-dropdown"] = "controls-dropdown",
			["Professions\\ProfessionsUI"] = "ProfessionsUI",
			["UI\\ui-background-rock"] = "ui-background-rock",
			["UI\\ui-background-marble"] = "ui-background-marble",
			["UI\\redbutton2x"] = "redbutton2x",
			["UI\\redbutton3slice"] = "redbutton3slice",
			["UI\\uiframetabs"] = "uiframetabs",
			["UI\\dropdownbutton"] = "dropdownbutton",
			["CharacterPanel\\scrollbararrows"] = "scrollbararrows",
			["CharacterPanel\\scrollbarthumb"] = "scrollbarthumb",
			-- The HUD. Unit frames always draw Forever's art under this skin (UF.GetFrameStyle).
			["UnitFrames\\Forever\\Player-BACKGROUND"] = "UnitFrames\\Player-BACKGROUND",
			["UnitFrames\\Forever\\Player-BORDER"] = "UnitFrames\\Player-BORDER",
			["UnitFrames\\Forever\\Player-Fat-BACKGROUND"] = "UnitFrames\\Player-Fat-BACKGROUND",
			["UnitFrames\\Forever\\Player-Fat-BORDER"] = "UnitFrames\\Player-Fat-BORDER",
			["UnitFrames\\Forever\\Target-BACKGROUND"] = "UnitFrames\\Target-BACKGROUND",
			["UnitFrames\\Forever\\Target-BORDER"] = "UnitFrames\\Target-BORDER",
			["UnitFrames\\Forever\\Target-Fat-BACKGROUND"] = "UnitFrames\\Target-Fat-BACKGROUND",
			["UnitFrames\\Forever\\Target-Fat-BORDER"] = "UnitFrames\\Target-Fat-BORDER",
			["UnitFrames\\Forever\\Party-BACKGROUND"] = "UnitFrames\\Party-BACKGROUND",
			["UnitFrames\\Forever\\Party-BORDER"] = "UnitFrames\\Party-BORDER",
			["UnitFrames\\Forever\\TargetofTarget-BACKGROUND"] = "UnitFrames\\TargetofTarget-BACKGROUND",
			["UnitFrames\\Forever\\TargetofTarget-BORDER"] = "UnitFrames\\TargetofTarget-BORDER",
			["UnitFrames\\Forever\\Level"] = "UnitFrames\\Level",
			["UnitFrames\\pvpforever"] = "UnitFrames\\pvpforever",
			["Minimap\\forever_circle"] = "Minimap\\forever_circle",
			["Minimap\\uiminimapborder"] = "Minimap\\uiminimapborder",
			["Minimap\\forever_pointer"] = "Minimap\\forever_pointer",
			["Minimap\\forever_square_frame"] = "Minimap\\forever_square_frame",
			["Minimap\\forever_square_frame_rounded"] = "Minimap\\forever_square_frame_rounded",
			["Minimap\\forever_square_pointer"] = "Minimap\\forever_square_pointer",
			["Minimap\\uiminimapsquareborder"] = "Minimap\\uiminimapsquareborder",
			["Castbar\\uicastingbar2x"] = "Castbar\\uicastingbar2x",
			["ActionBars\\uiactionbar2x_"] = "ActionBars\\uiactionbar2x_",
			["ActionBars\\uiactionbar2x_new"] = "ActionBars\\uiactionbar2x_new",
			["ActionBars\\uiactionbar2x_flying"] = "ActionBars\\uiactionbar2x_flying",
			["ActionBars\\uiactionbar2x_forever"] = "ActionBars\\uiactionbar2x_forever",
			["ActionBars\\uiactionbariconframe"] = "ActionBars\\uiactionbariconframe",
			["XP\\Background"] = "XP\\Background",
			["XP\\Background_r"] = "XP\\Background_r",
			["XP\\Overlay"] = "XP\\Overlay",
			["XP\\Overlay_r"] = "XP\\Overlay_r",
			["XP\\uiexperiencebar"] = "XP\\uiexperiencebar",
			["Micromenu\\uimicromenu2x"] = "Micromenu\\uimicromenu2x",
			["Micromenu\\micropvp"] = "Micromenu\\micropvp",
			["Professions\\MicroButton"] = "Micromenu\\MicroButton",
			-- The decorated windows.
			["Talents\\talents-sheet"] = "Talents\\talents-sheet",
			["Talents\\talentframeatlas"] = "Talents\\talentframeatlas",
			["Spellbook\\spellbook-background"] = "Spellbook\\spellbook-background",
			["Spellbook\\spellbook-background_r"] = "Spellbook\\spellbook-background_r",
			["Spellbook\\spellbook-ribbon"] = "Spellbook\\spellbook-ribbon",
			["Spellbook\\spellbookelements"] = "Spellbook\\spellbookelements",
			["Professions\\Backdrop1"] = "Professions\\Backdrop1",
			["Professions\\Backdrop2"] = "Professions\\Backdrop2",
			["Professions\\Banners"] = "Professions\\Banners",
			["Professions\\CardBase"] = "Professions\\CardBase",
			["Professions\\Fills"] = "Professions\\Fills",
			["Professions\\Drawings1"] = "Professions\\Drawings1",
			["Professions\\Drawings2"] = "Professions\\Drawings2",
			["Professions\\Drawings3"] = "Professions\\Drawings3",
			["Professions\\Drawings4"] = "Professions\\Drawings4",
			["Professions\\Drawings5"] = "Professions\\Drawings5",
			["Professions\\Drawings6"] = "Professions\\Drawings6",
			["Professions\\Drawings7"] = "Professions\\Drawings7",
			["Professions\\Drawings8"] = "Professions\\Drawings8",
			["Collections\\ListButtons"] = "Collections\\ListButtons",
			["Collections\\MountJournal-BG"] = "Collections\\MountJournal-BG",
			["Collections\\IconFrameGold"] = "Collections\\IconFrameGold",
		},
	},
}

-- Talent art comes in NAME and NAME_r halves. Stock paints one picture per tree, so a class's three
-- spec sheets all swap to one sheet holding its three trees side by side.
do
	local sheets = SKINS.classic.sheets
	local function halves(forever, classic)
		sheets["Talents\\" .. forever] = "Talents\\" .. classic
		sheets["Talents\\" .. forever .. "_r"] = "Talents\\" .. classic .. "_r"
	end
	local CLASS_TREES = {
		warrior = { "-fury", "-protection" }, paladin = { "-protection", "-retribution" },
		hunter = { "-marksmanship", "-survival" }, rogue = { "-outlaw", "-subtlety" },
		priest = { "-holy", "-shadow" }, shaman = { "-enhancement", "-restoration" },
		mage = { "-fire", "-frost" }, warlock = { "-demonology", "-destruction" },
		druid = { "-feral", "-restoration" }, deathknight = { "-frost", "-unholy" },
	}
	for class, trees in pairs(CLASS_TREES) do
		halves("talents-bg-" .. class, class)
		for _, tree in ipairs(trees) do
			halves("talents-bg-" .. class .. tree, class)
		end
	end
	for _, kind in ipairs({ "Cunning", "Ferocity", "Tenacity" }) do
		halves("Pet_" .. kind, "Pet_" .. kind)
	end
	for _, class in ipairs({ "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Shaman", "Mage", "Warlock", "Druid", "DeathKnight" }) do
		halves("Artifact\\" .. class, "glyph-ground")
	end
end

local BUTTON_SETTERS = {
	SetNormalTexture = "GetNormalTexture",
	SetPushedTexture = "GetPushedTexture",
	SetDisabledTexture = "GetDisabledTexture",
	SetHighlightTexture = "GetHighlightTexture",
}

local active

function Skins.Current()
	return active or Skins.DEFAULT
end

function Skins.Path(path)
	return Skins.map and Skins.map[path] or path
end

local function buildMap(skin)
	local map = {}
	for sheet, file in pairs(skin.sheets) do
		local path = addon._dir .. sheet
		map[path] = skin.dir .. file
		-- Some constants spell the extension out.
		map[path .. ".tga"] = skin.dir .. file
		map[path .. ".blp"] = skin.dir .. file
	end
	return map
end

local function installHooks(map)
	local probe = CreateFrame("Frame")
	hooksecurefunc(getmetatable(probe:CreateTexture()).__index, "SetTexture", function(texture, path)
		local swapped = map[path]
		if swapped then texture:SetTexture(swapped) end
	end)

	for _, widget in ipairs({ "Button", "CheckButton" }) do
		local methods = getmetatable(CreateFrame(widget)).__index
		for setter, getter in pairs(BUTTON_SETTERS) do
			hooksecurefunc(methods, setter, function(button, path)
				local swapped = map[path]
				if swapped then
					local texture = button[getter](button)
					if texture then texture:SetTexture(swapped) end
				end
			end)
		end
	end
end

-- Whatever painted before the saved settings were readable, in Lua or XML.
local function sweep(map)
	local frame = EnumerateFrames()
	while frame do
		for _, region in ipairs({ frame:GetRegions() }) do
			if region:GetObjectType() == "Texture" then
				local swapped = map[region:GetTexture()]
				if swapped then region:SetTexture(swapped) end
			end
		end
		frame = EnumerateFrames(frame)
	end
end

-- Once per load, from OnInitialize: the first point the profile is readable, and before the UI is built.
function Skins.Apply()
	if active then return end
	local style = addon.db and addon.db.profile and addon.db.profile.style
	local name = style and style.skin
	local skin = SKINS[name]
	if not skin then
		active = Skins.DEFAULT
		return
	end
	active = name
	for field, value in pairs(skin.seat or {}) do
		addon.WindowSeat[field] = value
	end
	Skins.map = buildMap(skin)
	installHooks(Skins.map)
	sweep(Skins.map)
end
