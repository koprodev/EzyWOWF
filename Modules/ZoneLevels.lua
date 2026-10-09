-- Empty map ranges use game activity suggestions, then Classic reference ranges.

local _, ns = ...
local Clean = ns.Clean

local M = ns:NewModule("ZoneLevels", {
	title = "지역 레벨",
	category = "map",
	icon = "Interface\\Icons\\INV_Misc_Book_11",
	order = 21,
	defaults = {
		enabled = true,
		showNames = false,
		colorByLevel = true,
		autoFont = true,
		fontSize = 12,
	},
})

local PIN_TEMPLATE = "EzyWOWFZoneLevelPinTemplate"
local CONTINENT, ZONE = 2, 3
local QUESTS_AND_ZONES = 116 -- Blizzard LFGVanilla_Constants.lua category.
local GOLD = { 1, 0.82, 0 }
local NAME_FONT_SCALE, RANGE_FONT_SCALE = 0.8, 0.7
local db, provider, attached, playerLevel, header
local reported = {}
local suggestedRanges, activitiesRequested, loggedIn
local IsSecret = issecretvalue or function() return false end

local function Number(value)
	value = Clean(value)
	if type(value) == "number" and value == value and math.abs(value) < math.huge then return value end
end

local function PositiveInteger(value)
	value = Number(value)
	if value and value > 0 and value % 1 == 0 then return value end
end

local function GameAPI(namespace, name, ...)
	local api = _G[namespace]
	local fn = api and api[name]
	if type(fn) ~= "function" then return end
	local ok, a, b, c, d = pcall(fn, ...)
	if ok then return a, b, c, d, true end
	local key = namespace .. "." .. name
	if not reported[key] then
		reported[key] = true
		ns.ErrorHandler("ZoneLevels: " .. key .. ": " .. tostring(a))
	end
	return nil, nil, nil, nil, false
end

local function RequestActivities()
	if activitiesRequested or not (loggedIn and db and db.enabled) then return end
	if not (C_LFGList and type(C_LFGList.RequestAvailableActivities) == "function") then return end
	activitiesRequested = true
	local _, _, _, _, ok = GameAPI("C_LFGList", "RequestAvailableActivities")
	if ok ~= true then activitiesRequested = nil end
end

local function SuggestedRanges()
	if suggestedRanges then return suggestedRanges end
	RequestActivities()
	local activities = Clean(GameAPI("C_LFGList", "GetAvailableActivities", QUESTS_AND_ZONES))
	if type(activities) ~= "table" then return end
	local ranges = {}
	for _, id in ipairs(activities) do
		id = PositiveInteger(id)
		local info = id and Clean(GameAPI("C_LFGList", "GetActivityInfoTable", id))
		if type(info) == "table" and Number(info.categoryID) == QUESTS_AND_ZONES then
			local minLevel, maxLevel = PositiveInteger(info.minLevelSuggestion), PositiveInteger(info.maxLevelSuggestion)
			if minLevel and maxLevel and maxLevel >= minLevel then
				local function AddName(name)
					name = Clean(name)
					if type(name) ~= "string" or name == "" then return end
					local old = ranges[name]
					if old == false then return end
					if old and (old[1] ~= minLevel or old[2] ~= maxLevel) then
						ranges[name] = false
					else
						ranges[name] = { minLevel, maxLevel }
					end
				end
				AddName(info.shortName)
				AddName(info.fullName)
			end
		end
	end
	if next(ranges) then suggestedRanges = ranges end
	return ranges
end

local function Levels(info)
	local mapID = PositiveInteger(info.mapID)
	if not mapID or Clean(GameAPI("C_Map", "IsCityMap", mapID)) == true then return end
	local minLevel, maxLevel, _, _, ok = GameAPI("C_Map", "GetMapLevels", mapID)
	if ok == false or IsSecret(minLevel) or IsSecret(maxLevel) then return end
	if (minLevel == nil and maxLevel == nil) or (minLevel == 0 and maxLevel == 0) then
		local name = Clean(info.name)
		local ranges = type(name) == "string" and SuggestedRanges()
		local range = ranges and ranges[name]
		if range == false then return end
		if range then return range[1], range[2] end
		local reference = ns.zoneLevelRanges and ns.zoneLevelRanges[mapID]
		if reference then return reference[1], reference[2] end
		return
	end
	minLevel, maxLevel = PositiveInteger(minLevel), PositiveInteger(maxLevel)
	if minLevel and maxLevel and maxLevel >= minLevel then return minLevel, maxLevel end
end

local function LevelColor(minLevel, maxLevel)
	if not (db.colorByLevel and playerLevel) then return unpack(GOLD) end
	if playerLevel < minLevel then return 1, 0.25, 0.25 end
	if playerLevel > maxLevel then return 0.65, 0.65, 0.65 end
	return 0.25, 1, 0.25
end

local function DecorateLabel(self)
	self.nameText = self:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	self.nameText:SetPoint("TOP", self, "TOP")
	self.nameText:SetTextColor(unpack(GOLD))
	self.rangeText = self:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	self.nameText:SetShadowColor(0, 0, 0, 1)
	self.nameText:SetShadowOffset(1, -1)
	self.rangeText:SetShadowColor(0, 0, 0, 1)
	self.rangeText:SetShadowOffset(1, -1)
end

local function FontSize(map, viewportOnly)
	local size = math.max(8, math.min(24, Number(db.fontSize) or 12))
	if db.autoFont and map then
		local scale
		if viewportOnly then
			local canvas = map.GetCanvas and map:GetCanvas()
			local container = map.GetCanvasContainer and map:GetCanvasContainer()
			if canvas and container then
				local width, height = Number(canvas:GetWidth()), Number(canvas:GetHeight())
				local viewWidth, viewHeight = Number(container:GetWidth()), Number(container:GetHeight())
				if width and height and viewWidth and viewHeight
					and width > 0 and height > 0 and viewWidth > 0 and viewHeight > 0 then
					scale = math.min(viewWidth / width, viewHeight / height)
				end
			end
		elseif map.GetCanvasScale then
			scale = Number(map:GetCanvasScale())
		end
		if scale and scale > 0 then size = math.max(8, size * math.min(1, scale)) end
	end
	return math.floor(size + 0.5)
end

local function ResizeLabel(self, map, viewportOnly, force)
	local size = FontSize(map, viewportOnly)
	if not force and self.zoneFontSize == size then return end
	self.zoneFontSize = size
	local font = GameFontNormal:GetFont()
	local nameSize, rangeSize = size * NAME_FONT_SCALE, size * RANGE_FONT_SCALE
	self.nameText:SetFont(font, nameSize, "OUTLINE")
	self.rangeText:SetFont(font, rangeSize, "OUTLINE")
	self:SetSize(math.max(self.nameText:GetStringWidth(), self.rangeText:GetStringWidth()) + 8,
		self.zoneShowName and (nameSize + rangeSize + 6) or (rangeSize + 4))
end

local function StyleLabel(self, info, minLevel, maxLevel, map, viewportOnly)
	self.mapID = info.mapID
	local name = Clean(info.name)
	local showName = db.showNames and type(name) == "string" and name ~= ""
	self.zoneShowName = showName
	self.nameText:SetText(showName and name or "")
	self.nameText:SetShown(showName)
	self.rangeText:ClearAllPoints()
	if showName then
		self.rangeText:SetPoint("TOP", self.nameText, "BOTTOM", 0, -2)
	else
		self.rangeText:SetPoint("TOP", self, "TOP")
	end
	self.rangeText:SetText(minLevel == maxLevel and ("%d"):format(minLevel)
		or ("%d~%d"):format(minLevel, maxLevel))
	self.rangeText:SetTextColor(LevelColor(minLevel, maxLevel))
	ResizeLabel(self, map, viewportOnly, true)
end

-- XML can load before the map addon, so the template always has its mixin table.
EzyWOWFZoneLevelPinMixin = {}

function EzyWOWFZoneLevelPinMixin:OnLoad()
	self:UseFrameLevelType("PIN_FRAME_LEVEL_DIG_SITE")
	self:SetScalingLimits(1, 1, 1)
	self:SetIgnoreGlobalPinScale(true)
	self:EnableMouse(false)
	DecorateLabel(self)
end

function EzyWOWFZoneLevelPinMixin:OnAcquired(info, minLevel, maxLevel, x, y)
	StyleLabel(self, info, minLevel, maxLevel, self:GetMap())
	self:SetPosition(x, y)
	self:ApplyCurrentScale()
end

function EzyWOWFZoneLevelPinMixin:OnCanvasScaleChanged()
	MapCanvasPinMixin.OnCanvasScaleChanged(self)
	ResizeLabel(self, self:GetMap())
end

function EzyWOWFZoneLevelPinMixin:OnCanvasSizeChanged()
	ResizeLabel(self, self:GetMap())
end

local function AddZone(map, info, x, y)
	local mapID = PositiveInteger(info.mapID)
	if not mapID then return end
	local minLevel, maxLevel = Levels(info)
	if minLevel then map:AcquirePin(PIN_TEMPLATE, info, minLevel, maxLevel, x, y) end
end

local function Refresh()
	if attached and WorldMapFrame:IsShown() then provider:RefreshAllData() end
end

local function Setup()
	if attached or not (db and WorldMapFrame and WorldMapFrame.AddDataProvider
		and WorldMapFrame.ScrollContainer and MapCanvasPinMixin and MapCanvasDataProviderMixin) then return end
	for name, method in pairs(MapCanvasPinMixin) do
		if EzyWOWFZoneLevelPinMixin[name] == nil then EzyWOWFZoneLevelPinMixin[name] = method end
	end
	local container = WorldMapFrame.ScrollContainer
	header = CreateFrame("Frame", "EzyWOWFZoneLevelHeader", WorldMapFrame)
	header:SetPoint("TOPLEFT", container, "TOPLEFT", 12, -12)
	header:SetFrameLevel(container:GetFrameLevel() + 100)
	header:EnableMouse(false)
	DecorateLabel(header)
	header:Hide()
	provider = CreateFromMixins(MapCanvasDataProviderMixin)

	function provider:RemoveAllData()
		self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
		header:Hide()
	end

	function provider:OnCanvasSizeChanged()
		if header:IsShown() then ResizeLabel(header, self:GetMap(), true) end
	end

	function provider:OnCanvasScaleChanged()
		if header:IsShown() then ResizeLabel(header, self:GetMap(), true) end
	end

	function provider:RefreshAllData()
		self:RemoveAllData()
		if not db.enabled then return end
		local map = self:GetMap()
		local mapID = PositiveInteger(map:GetMapID())
		local info = Clean(mapID and GameAPI("C_Map", "GetMapInfo", mapID))
		if type(info) ~= "table" then return end
		local mapType = Number(info.mapType)
		if mapType == ZONE then
			local minLevel, maxLevel = Levels(info)
			if minLevel then
				StyleLabel(header, info, minLevel, maxLevel, map, true)
				header:Show()
			end
		elseif mapType == CONTINENT then
			local children = Clean(GameAPI("C_Map", "GetMapChildrenInfo", mapID, ZONE, true))
			if type(children) ~= "table" then return end
			local seen = {}
			for _, child in ipairs(children) do
				child = Clean(child)
				local childID = type(child) == "table" and PositiveInteger(child.mapID)
				if childID and not seen[childID] and Number(child.mapType) == ZONE then
					seen[childID] = true
					local minX, maxX, minY, maxY = GameAPI("C_Map", "GetMapRectOnMap", childID, mapID)
					minX, maxX, minY, maxY = Number(minX), Number(maxX), Number(minY), Number(maxY)
					if minX and maxX and minY and maxY and maxX > minX and maxY > minY then
						local x, y = (minX + maxX) / 2, (minY + maxY) / 2
						if x >= 0 and x <= 1 and y >= 0 and y <= 1 then AddZone(map, child, x, y) end
					end
				end
			end
		end
	end

	WorldMapFrame:AddDataProvider(provider)
	attached = true
	Refresh()
end

ns:RegisterEvent("ADDON_LOADED", function(_, name)
	if name == "Blizzard_WorldMap" then Setup() end
end)

ns:RegisterEvent("PLAYER_LEVEL_UP", function(_, level)
	playerLevel = PositiveInteger(level) or PositiveInteger(UnitLevel("player"))
	suggestedRanges, activitiesRequested = nil, nil
	RequestActivities()
	Refresh()
end)

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
	playerLevel = PositiveInteger(UnitLevel("player"))
	Refresh()
end)

ns:RegisterEvent("LFG_LIST_AVAILABILITY_UPDATE", function()
	suggestedRanges = nil
	Refresh()
end)

function M:OnInitialize()
	db = self.db
	playerLevel = PositiveInteger(UnitLevel("player"))
	Setup()
end

function M:OnLogin()
	loggedIn = true
	Setup()
	RequestActivities()
	Refresh()
end

function M:ApplySettings()
	Setup()
	if not db.enabled then suggestedRanges, activitiesRequested = nil, nil end
	RequestActivities()
	if attached then provider:RefreshAllData() end
end

function M:BuildOptions(b)
	b:Text("세계 지도(M)에서 대륙을 선택하면 각 지역의 적정 레벨 범위를 보여 줍니다. 지역 지도에는 왼쪽 위에 그 지역의 범위를 표시합니다.")
	b:Text("게임 지도 정보 → 퀘스트·지역 파티 찾기의 추천 레벨 → 클래식 참고 범위 순으로 표시합니다. 대도시와 정보가 없는 지역은 생략합니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Check{ key = "showNames", label = "지역 이름도 표시", depends = "enabled", indent = 20 }
	b:Check{ key = "colorByLevel", label = "내 레벨에 따라 색상 표시", depends = "enabled", indent = 20,
		tooltip = "내 레벨이 범위보다 낮으면 빨강, 범위 안이면 초록, 범위보다 높으면 회색으로 표시합니다." }
	b:Check{ key = "autoFont", label = "지도 크기에 맞춰 글자 크기 자동 조절", depends = "enabled", indent = 20,
		tooltip = "작은 지도에서는 글자를 줄이고, 지도를 확대하면 설정한 기준 크기에 맞춥니다." }
	b:Slider{ key = "fontSize", label = "기준 글자 크기", min = 8, max = 24, step = 1, depends = "enabled", indent = 20,
		tooltip = "지역 이름은 기준 크기의 80%, 레벨 숫자는 70%로 표시합니다. 자동 조절을 켜면 지도 크기에 맞춰 함께 줄어듭니다." }
end
