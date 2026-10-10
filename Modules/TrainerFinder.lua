local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local M = ns:NewModule("TrainerFinder", {
	title = "기술·직업 전문가 찾기",
	category = "map",
	icon = "Interface\\Icons\\INV_Misc_Book_06",
	order = 22,
	defaults = { enabled = true, factionOnly = true, pinSize = 18, showButton = true, showMapButton = true,
		showOnMinimap = true, minimapDotSize = 6, kind = "myclass" },
})

local KINDS = {
	{ "WARRIOR", "전사", "Ability_Warrior_BattleShout", true },
	{ "PALADIN", "성기사", "Spell_Holy_DevotionAura", true },
	{ "HUNTER", "사냥꾼", "Ability_Hunter_AimedShot", true },
	{ "ROGUE", "도적", "Ability_Stealth", true },
	{ "PRIEST", "사제", "Spell_Holy_PowerWordShield", true },
	{ "SHAMAN", "주술사", "Spell_Nature_LightningShield", true },
	{ "MAGE", "마법사", "Spell_Frost_FrostBolt02", true },
	{ "WARLOCK", "흑마법사", "Spell_Shadow_ShadowBolt", true },
	{ "DRUID", "드루이드", "Spell_Nature_HealingTouch", true },
	{ "ALCHEMY", "연금술", "Trade_Alchemy" },
	{ "BLACKSMITHING", "대장기술", "Trade_BlackSmithing" },
	{ "ENCHANTING", "마법부여", "Trade_Engraving" },
	{ "ENGINEERING", "기계공학", "Trade_Engineering" },
	{ "HERBALISM", "약초채집", "Trade_Herbalism" },
	{ "LEATHERWORKING", "가죽세공", "Trade_LeatherWorking" },
	{ "MINING", "채광", "Trade_Mining" },
	{ "SKINNING", "무두질", "INV_Misc_Pelt_Wolf_01" },
	{ "TAILORING", "재봉술", "Trade_Tailoring" },
	{ "COOKING", "요리", "INV_Misc_Food_15" },
	{ "FIRSTAID", "응급치료", "Spell_Holy_SealOfSacrifice" },
	{ "FISHING", "낚시", "Trade_Fishing" },
	{ "PET", "야수 훈련", "Ability_Hunter_BeastTraining" },
	{ "WEAPON", "무기 기술", "INV_Sword_04" },
	-- 상인은 가르치는 게 없어서 [모든 전문 기술]에 안 끼고 '○○ 상인'으로 부른다
	{ "TRADE", "직업용품", "INV_Fabric_Linen_01", vendor = true },
	{ "GENERAL", "일용품", "INV_Misc_Bag_10", vendor = true },
	{ "REAGENT", "마법 재료", "INV_Misc_Rune_06", vendor = true },
}
local BY_KIND = {}
for _, kind in ipairs(KINDS) do
	BY_KIND[kind[1]] = kind
	M.defaults["kind_" .. kind[1]] = false
end

local TEMPLATE = "EzyWOWFTrainerPinTemplate"
local db, provider, attached, displayedMap
local viewKind, viewRegion, selected = "myclass"
local reported = {}

local function Number(value)
	value = Clean(value)
	if type(value) == "number" and value == value and math.abs(value) < math.huge then return value end
end

local function MapID(value)
	value = Number(value)
	if value and value > 0 and value % 1 == 0 then return value end
end

local function API(namespace, name, ...)
	local group = _G[namespace]
	local fn = group and group[name]
	if type(fn) ~= "function" then return end
	local ok, result = pcall(fn, ...)
	if ok then return Clean(result), true end
	local key = namespace .. "." .. name
	if not reported[key] then
		reported[key] = true
		ns.ErrorHandler("TrainerFinder: " .. key .. ": " .. tostring(result))
	end
	return nil, false
end

local function MapName(id)
	local info = API("C_Map", "GetMapInfo", id)
	local name = type(info) == "table" and Clean(info.name)
	return type(name) == "string" and name or ("#" .. tostring(id))
end

local function PlayerClass()
	local _, class = UnitClass("player")
	return Clean(class)
end

local function MatchesKind(kind)
	local info = BY_KIND[kind]
	if not info then return false end
	if viewKind == "custom" then return db and db["kind_" .. kind] == true end
	if viewKind == "all" then return true end
	if viewKind == "myclass" then return kind == PlayerClass() end
	if viewKind == "classes" then return info[4] == true end
	if viewKind == "professions" then return not info[4] and not info.vendor and kind ~= "PET" and kind ~= "WEAPON" end
	return kind == viewKind
end

local function ValidRow(row)
	if type(row) ~= "table" or not BY_KIND[row.kind] or not MapID(row.id)
		or type(row.name) ~= "string" or row.name == "" then return false end
	local x, y = Number(row.x), Number(row.y)
	return x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1
		and (row.faction == nil or row.faction == "Alliance" or row.faction == "Horde")
end

local Finder = {}
ns.TrainerFinder = Finder

function Finder.GetKinds() return KINDS end
function Finder.GetKind() return viewKind end
function Finder.IsVendor(kind) return BY_KIND[kind] and BY_KIND[kind].vendor == true or false end
function Finder.KindTitle(kind)
	local info = BY_KIND[kind]
	return info and (info[2] .. (info.vendor and " 상인" or " 전문가")) or ""
end
-- 상인은 '파는 물건', 전문가는 '가르치는 기술'이 다를 수 있다
function Finder.DiffersNote(kind)
	return Finder.IsVendor(kind) and "파는 물건" or "가르치는 기술"
end
function Finder.IsKindChecked(kind) return MatchesKind(kind) and true or false end

local function ValidKind(kind)
	return type(kind) == "string" and (BY_KIND[kind] or kind == "all" or kind == "myclass"
		or kind == "classes" or kind == "professions" or kind == "custom")
end

-- localize 줄(위키 자료)은 영어 이름이라 NPC 번호로 게임에 물어 본 이름을 쓴다.
-- 처음 물을 땐 서버 응답 전이라 빈손일 수 있어서, 잠시 뒤 한 번만 다시 그린다. 끝내 못 받으면 영어 그대로.
local Rebuild
local localNames = {}
local namesRetried, retryQueued = {}, false
local CREATURE_LINK = "unit:Creature-0-0-0-0-%d-0000000000"

local function LocalName(row)
	if not row.localize then return row.name end
	local name = localNames[row.id]
	if name then return name end
	local lookup = C_TooltipInfo and C_TooltipInfo.GetHyperlink
	local ok, data = false, nil
	if type(lookup) == "function" then ok, data = pcall(lookup, CREATURE_LINK:format(row.id)) end
	local line = ok and type(data) == "table" and type(data.lines) == "table" and data.lines[1]
	name = type(line) == "table" and Clean(line.leftText)
	if type(name) == "string" and name ~= "" and name ~= RETRIEVING_DATA then
		localNames[row.id] = name
		return name
	end
	if not namesRetried[row.id] then
		namesRetried[row.id] = true
		if not retryQueued then
			retryQueued = true
			C_Timer.After(2, function()
				retryQueued = false
				Rebuild()
			end)
		end
	end
	return row.name
end

function Finder.GetResults(id)
	id = MapID(id)
	local results = {}
	local faction = Clean(UnitFactionGroup("player"))
	for _, row in ipairs((ns.trainerLocations or {})[id] or {}) do
		if ValidRow(row) and MatchesKind(row.kind)
			and (not db or not db.factionOnly or not row.faction or row.faction == faction) then
			local result = {}
			for key, value in pairs(row) do result[key] = value end
			result.name = LocalName(row)
			result.mapID = id
			results[#results + 1] = result
		end
	end
	table.sort(results, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		if a.kind ~= b.kind then return a.kind < b.kind end
		if a.id ~= b.id then return a.id < b.id end
		if a.x ~= b.x then return a.x < b.x end
		return a.y < b.y
	end)
	return results
end

local function Refresh()
	if attached and WorldMapFrame:IsShown() then provider:RefreshAllData() end
end

function Rebuild()
	Refresh()
	ns:Fire("TRAINER_FINDER_CHANGED")
	C_Timer.After(0, function() ns:Fire("REBUILD_OPTIONS") end)
end

function Finder.SetKind(kind)
	if not ValidKind(kind) then return end
	viewKind, selected = kind, nil
	if db then db.kind = kind end
	Rebuild()
end

function Finder.SetKindChecked(kind, on)
	if not db or not BY_KIND[kind] or type(on) ~= "boolean" then return end
	if viewKind ~= "custom" then
		for _, info in ipairs(KINDS) do db["kind_" .. info[1]] = Finder.IsKindChecked(info[1]) end
	end
	db["kind_" .. kind] = on
	db.kind, viewKind, selected = "custom", "custom", nil
	Rebuild()
end

function Finder.ClearKinds()
	if not db then return end
	for _, kind in ipairs(KINDS) do db["kind_" .. kind[1]] = false end
	db.kind, viewKind, selected = "custom", "custom", nil
	Rebuild()
end

function Finder.SetRegion(id)
	id = MapID(id)
	if not id or viewRegion == id then return end
	viewRegion, selected = id, nil
	Rebuild()
end

local function Region()
	if viewRegion then return viewRegion end
	local shown = WorldMapFrame and WorldMapFrame:IsShown() and MapID(WorldMapFrame:GetMapID())
	if shown and ns.trainerLocations and ns.trainerLocations[shown] then return shown end
	return MapID(API("C_Map", "GetBestMapForUnit", "player"))
end

Finder.GetRegion = Region

local function RowKey(row)
	return ("%d:%s:%.6f:%.6f"):format(row.id, row.kind, row.x, row.y)
end

local function Selection()
	local rows = Finder.GetResults(Region())
	for _, row in ipairs(rows) do if RowKey(row) == selected then return row end end
	return rows[1]
end

Finder.GetSelection = Selection
function Finder.GetSelectionKey()
	local row = Selection()
	return row and RowKey(row)
end
function Finder.SetSelection(key)
	if type(key) ~= "string" then return end
	selected = key
	ns:Fire("TRAINER_FINDER_CHANGED")
	ns:Fire("REFRESH_UI")
end

local function Caption(row)
	local location = row.location and (row.location .. " · ") or ""
	local role = type(row.role) == "string" and row.role ~= "" and row.role or BY_KIND[row.kind][2]
	return ("%s%s (%s) %.1f, %.1f"):format(location, row.name, role, row.x * 100, row.y * 100)
end

Finder.GetCaption = Caption

function Finder.ClearWaypoint() API("C_Map", "ClearUserWaypoint") end

function Finder.Navigate(row)
	if not (db and db.enabled) then Print("전문가 찾기가 꺼져 있어요. 설정에서 사용을 켜고 저장하세요.") return false end
	if not ValidRow(row) or not MapID(row.mapID) then return false end
	if not (C_Map and type(C_Map.SetUserWaypoint) == "function" and UiMapPoint
		and type(UiMapPoint.CreateFromCoordinates) == "function") then
		Print("이 게임 버전에서는 지도 핀을 꽂을 수 없어요.") return false
	end
	if C_Map.CanSetUserWaypointOnMap then
		local allowed = API("C_Map", "CanSetUserWaypointOnMap", row.mapID)
		if allowed ~= true then Print("이 지도에는 길 안내 핀을 꽂을 수 없어요.") return false end
	end
	local point = UiMapPoint.CreateFromCoordinates(row.mapID, row.x, row.y)
	local _, ok = API("C_Map", "SetUserWaypoint", point)
	if ok ~= true then return false end
	API("C_SuperTrack", "SetSuperTrackedUserWaypoint", true)
	if not WorldMapFrame and C_AddOns and C_AddOns.LoadAddOn then API("C_AddOns", "LoadAddOn", "Blizzard_WorldMap") end
	if WorldMapFrame and WorldMapFrame.SetMapID then
		if ShowUIPanel then ShowUIPanel(WorldMapFrame) else WorldMapFrame:Show() end
		WorldMapFrame:SetMapID(row.mapID)
	end
	Print("전문가 길 안내: " .. MapName(row.mapID) .. " · " .. Caption(row))
	return true
end

-- The template exists even when Blizzard_WorldMap loads after the addon.
EzyWOWFTrainerPinMixin = {}

function EzyWOWFTrainerPinMixin:OnLoad()
	self:UseFrameLevelType("PIN_FRAME_LEVEL_DIG_SITE")
	self:SetScalingLimits(1, 1, 1.3)
	self.Icon = self:CreateTexture(nil, "ARTWORK")
	self.Icon:SetAllPoints()
	self.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
end

function EzyWOWFTrainerPinMixin:OnAcquired(row)
	self.row = row
	local size = math.max(12, math.min(32, Number(db.pinSize) or 18))
	self:SetSize(size, size)
	self.Icon:SetTexture("Interface\\Icons\\" .. BY_KIND[row.kind][3])
	self:SetPosition(row.x, row.y)
end

function EzyWOWFTrainerPinMixin:OnMouseEnter()
	local row = self.row
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(row.name, 1, 0.82, 0)
	local title = Finder.KindTitle(row.kind)
	GameTooltip:AddLine(title, 1, 1, 1)
	-- 상인은 부제가 '직업용품 상인'처럼 윗줄과 같아서 한 번만
	if type(row.role) == "string" and row.role ~= "" and row.role ~= title then GameTooltip:AddLine(row.role, 0.9, 0.9, 0.9) end
	GameTooltip:AddLine(("%s%s · %.1f, %.1f"):format(MapName(row.mapID),
		row.location and (" / " .. row.location) or "", row.x * 100, row.y * 100), 0.8, 0.8, 0.8)
	GameTooltip:AddLine("클릭: 여기로 길 안내", 0.5, 0.8, 1)
	GameTooltip:AddLine(("참고 위치입니다. 포에버에서 위치·%s이 다를 수 있어요."):format(Finder.DiffersNote(row.kind)), 0.65, 0.65, 0.65, true)
	GameTooltip:Show()
end

function EzyWOWFTrainerPinMixin:OnMouseLeave() GameTooltip:Hide() end

function EzyWOWFTrainerPinMixin:OnMouseClickAction(button)
	if button == "LeftButton" then Finder.Navigate(self.row) end
end

function EzyWOWFTrainerPinMixin:OnReleased()
	if GameTooltip.GetOwner and GameTooltip:GetOwner() == self then GameTooltip:Hide() end
	self.row = nil
	if MapCanvasPinMixin.OnReleased then MapCanvasPinMixin.OnReleased(self) end
end

local function Setup()
	if attached or not (db and WorldMapFrame and WorldMapFrame.AddDataProvider
		and MapCanvasPinMixin and MapCanvasDataProviderMixin) then return end
	for name, method in pairs(MapCanvasPinMixin) do
		if EzyWOWFTrainerPinMixin[name] == nil then EzyWOWFTrainerPinMixin[name] = method end
	end
	provider = CreateFromMixins(MapCanvasDataProviderMixin)
	function provider:RemoveAllData() self:GetMap():RemoveAllPinsByTemplate(TEMPLATE) end
	function provider:RefreshAllData()
		self:RemoveAllData()
		local map = self:GetMap()
		local id = MapID(map:GetMapID())
		if db.enabled then
			for _, row in ipairs(Finder.GetResults(id)) do map:AcquirePin(TEMPLATE, row) end
		end
		if id ~= displayedMap then
			displayedMap = id
			ns:Fire("TRAINER_FINDER_MAP_CHANGED", id)
		end
	end
	WorldMapFrame:AddDataProvider(provider)
	attached = true
	if Finder.AttachMapUI then Finder.AttachMapUI(WorldMapFrame) end
	Refresh()
end

ns:RegisterEvent("ADDON_LOADED", function(_, name) if name == "Blizzard_WorldMap" then Setup() end end)
ns:RegisterEvent("PLAYER_ENTERING_WORLD", Refresh)

function M:OnInitialize()
	db = self.db
	viewKind = ValidKind(db.kind) and db.kind or "myclass"
	db.kind = viewKind
	if Finder.InitializeUI then Finder.InitializeUI() end
	Setup()
	if Finder.UpdateMinimap then Finder.UpdateMinimap() end
end
function M:OnLogin() Setup() Refresh() end
function M:ApplySettings()
	selected = nil
	viewKind = ValidKind(db.kind) and db.kind or "myclass"
	db.kind = viewKind
	Setup()
	Refresh()
	if Finder.ApplyUI then Finder.ApplyUI() end
	ns:Fire("TRAINER_FINDER_CHANGED")
end

function Finder.Show() ns:OpenWindow("TrainerFinder") end
SLASH_EZYWOWFTRAINER1 = "/전문가"
SLASH_EZYWOWFTRAINER2 = "/trainers"
SlashCmdList.EZYWOWFTRAINER = Finder.Show

local function KindOptions()
	local options = {
		{ value = "myclass", text = "내 직업" }, { value = "all", text = "모든 전문가" },
		{ value = "classes", text = "모든 직업" }, { value = "professions", text = "모든 전문 기술" },
		{ value = "custom", text = "체크한 전문가" },
	}
	for _, kind in ipairs(KINDS) do options[#options + 1] = { value = kind[1], text = kind[2] } end
	return options
end

local function RegionOptions()
	local options = {}
	for id in pairs(ns.trainerLocations or {}) do
		if #Finder.GetResults(id) > 0 then options[#options + 1] = { value = id, text = MapName(id) } end
	end
	table.sort(options, function(a, b) if a.text ~= b.text then return a.text < b.text end return a.value < b.value end)
	return options
end

Finder.GetRegionOptions = RegionOptions
function Finder.GetTrainerOptions()
	local options = {}
	for _, row in ipairs(Finder.GetResults(Region())) do options[#options + 1] = { value = RowKey(row), text = Caption(row) } end
	return options
end

function M:BuildOptions(b)
	b:Text("미니맵 옆 찾기 아이콘이나 세계 지도(M)의 [전문가] 버튼으로 작은 패널을 펼쳐 종류를 체크하세요. 여러 종류를 함께 표시할 수 있고 선택은 바로 저장됩니다. 지역과 전문가를 골라 [지도에서 찾기]를 누르거나 지도 아이콘을 클릭하세요.")
	b:Text("참고 위치이며, 포에버의 실제 위치와 가르치는 기술·등급, 상인이 파는 물건은 다를 수 있습니다. 찾는 곳이 목록에 없으면 다른 지역도 확인하세요.")
	b:Check{ key = "enabled", label = "사용" }
	b:Check{ key = "showButton", label = "미니맵 옆 찾기 아이콘 표시", depends = "enabled", indent = 20 }
	b:Check{ key = "showMapButton", label = "세계 지도에 전문가 찾기 버튼 표시", depends = "enabled", indent = 20 }
	b:Check{ key = "showOnMinimap", label = "미니맵에 작은 빨간 점 표시", depends = "enabled", indent = 20 }
	b:Slider{ key = "minimapDotSize", label = "미니맵 점 크기", min = 4, max = 10, step = 1, depends = { "enabled", "showOnMinimap" }, indent = 20 }
	b:Check{ key = "factionOnly", label = "내 진영과 중립 전문가만 표시", depends = "enabled", indent = 20 }
	b:Slider{ key = "pinSize", label = "지도 아이콘 크기", min = 12, max = 32, step = 1, depends = "enabled", indent = 20 }
	b:Header("전문가 찾기")
	b:Dropdown{ label = "전문가 종류", width = 300, options = KindOptions, get = function() return viewKind end,
		set = Finder.SetKind, depends = "enabled", tooltip = "종류 선택은 바로 지도에 반영됩니다. 내 직업·각 직업·연금술·요리·낚시·직업용품 상인 등으로 좁혀 찾으세요." }
	b:Dropdown{ label = "지역", width = 300, options = RegionOptions, get = Region, set = Finder.SetRegion,
		emptyText = "지역을 고르세요", depends = "enabled" }
	b:Dropdown{ label = "전문가", width = 300, options = Finder.GetTrainerOptions,
		get = function() local row = Selection() return row and RowKey(row) end,
		set = Finder.SetSelection, emptyText = "이 지역에는 등록된 전문가가 없어요", depends = "enabled" }
	b:Text(function()
		local row = Selection()
		return row and (MapName(row.mapID) .. " · " .. Caption(row)) or "종류와 지역을 바꿔서 찾아보세요."
	end)
	b:Buttons{
		{ text = "지도에서 찾기", width = 150, onClick = function() Finder.Navigate(Selection()) end,
			disabled = function() return not db.enabled or not Selection() end },
		{ text = "지도 핀 지우기", width = 150, onClick = Finder.ClearWaypoint },
	}
end
