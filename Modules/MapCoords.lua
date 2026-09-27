-- 세계 지도 좌표: 지도 아래쪽에 내 위치와 마우스 커서 위치를 보여 준다.

local _, ns = ...
local Clean = ns.Clean

local M = ns:NewModule("MapCoords", {
	title = "지도 좌표",
	category = "map",
	icon = "Interface\\Icons\\INV_Misc_Map02",
	order = 20,
	defaults = {
		enabled = true,
		showPlayer = true,
		showCursor = true,
	},
})

local UPDATE_INTERVAL = 0.05

local db
local holder, text

local function PlayerCoords(mapID)
	local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
	if not ok or not pos then return nil end
	local x, y = Clean(pos.x), Clean(pos.y)
	if not x or not y or (x == 0 and y == 0) then return nil end
	return x * 100, y * 100
end

local function CursorCoords(container)
	if not (container.GetNormalizedCursorPosition and container:IsMouseOver()) then return nil end
	local x, y = container:GetNormalizedCursorPosition()
	if not x or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
	return x * 100, y * 100
end

local function Update()
	local parts = {}
	local mapID = WorldMapFrame:GetMapID()
	if db.showPlayer and mapID then
		local x, y = PlayerCoords(mapID)
		parts[#parts + 1] = "내 위치  " .. (x and ("|cffffffff%.1f, %.1f|r"):format(x, y) or "|cff808080--|r")
	end
	if db.showCursor then
		local x, y = CursorCoords(WorldMapFrame.ScrollContainer)
		parts[#parts + 1] = "커서  " .. (x and ("|cffffffff%.1f, %.1f|r"):format(x, y) or "|cff808080--|r")
	end
	text:SetText(table.concat(parts, "        "))
end

local function Setup()
	if holder or not (WorldMapFrame and WorldMapFrame.ScrollContainer) then return end

	local container = WorldMapFrame.ScrollContainer
	holder = CreateFrame("Frame", nil, WorldMapFrame)
	holder:SetPoint("BOTTOM", container, "BOTTOM", 0, 6)
	holder:SetSize(320, 22)
	holder:SetFrameLevel(container:GetFrameLevel() + 100)

	local bg = holder:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.5)

	text = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	text:SetPoint("CENTER")

	local elapsedSince = UPDATE_INTERVAL
	holder:SetScript("OnUpdate", function(_, elapsed)
		elapsedSince = elapsedSince + elapsed
		if elapsedSince < UPDATE_INTERVAL then return end
		elapsedSince = 0
		Update()
		holder:SetWidth(text:GetStringWidth() + 24)
	end)

	holder:SetShown(db.enabled)
end

-- 세계 지도는 필요할 때 따로 불러오는 경우가 있어서 불러온 뒤에 붙인다.
ns:RegisterEvent("ADDON_LOADED", function(_, name)
	if name == "Blizzard_WorldMap" and db then Setup() end
end)

function M:OnInitialize()
	db = self.db
	Setup()
end

function M:ApplySettings()
	Setup()
	if holder then holder:SetShown(db.enabled) end
end

function M:BuildOptions(b)
	b:Text("세계 지도(M) 아래쪽에 내 위치와 마우스 커서 위치의 좌표를 보여 줍니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Check{ key = "showPlayer", label = "내 위치 좌표", depends = "enabled", indent = 20 }
	b:Check{ key = "showCursor", label = "마우스 커서 좌표", depends = "enabled", indent = 20 }
end
