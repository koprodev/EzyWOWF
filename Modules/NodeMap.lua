-- 채집·보물 기록: 내가 채광한 광맥, 채집한 약초, 연 보물상자의 위치를 기록해서 세계 지도와 미니맵에 아이콘으로 표시한다.
--
-- 기록 방법
--   1) UNIT_SPELLCAST_SENT: 채광/약초 채집/열기 주문을 쓸 때 대상 이름(예: "구리 광맥")을 받아 둔다.
--      주문은 이름으로 구분한다. (등급·버전마다 주문 번호가 달라도 이름은 같다)
--   2) UNIT_SPELLCAST_SUCCEEDED: 성공하면 그때 내 위치를 "지역 지도" 좌표로 적어 둔다.
--   3) LOOT_OPENED: 전리품 출처가 월드 오브젝트(GameObject)일 때만 기록한다.
--      "열기"는 가방 속 조개 같은 아이템을 열 때도 쓰여서, 이렇게 걸러야 가짜 보물상자가 안 생긴다.
--   같은 종류가 가까이(MERGE_YARDS) 있으면 한 곳으로 합치고 횟수를 센다.
--
-- 표시: 세계 지도의 데이터 제공자(MapCanvasDataProviderMixin) + 핀(EzyWOWFNodePinTemplate, NodeMap.xml).
--   블리자드 지도는 제공자들을 secureexecuterange로 따로 실행하므로 애드온 제공자가 다른 핀을 오염시키지 않는다.
--   핀 클릭: 그 자리에 지도 핀(길 안내) 설정 -> 퀘스트 방향 화살표가 그쪽을 가리킨다. Shift+클릭: 기록 지우기.
--   세계 지도 오른쪽 위 필터 메뉴(MENU_WORLD_MAP_TRACKING)에 종류별 표시 체크박스를 붙인다.
--   Menu.ModifyMenu는 애드온이 메뉴에 항목을 끼워 넣도록 블리자드가 열어 둔 방법이라 다른 항목을 오염시키지 않는다.
--
-- 기록은 EzyWOWFDB.nodes[지도ID] = { { x, y, t = 종류, n = { [이름] = 횟수 }, c = 합계, last = 시각 }, ... }
-- 포에버 베타는 저장 파일을 못 불러오는 버그가 있어서 기록 내보내기/가져오기(합치기)를 둔다.

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local M = ns:NewModule("NodeMap", {
	title = "채집·보물 기록",
	category = "map",
	icon = "Interface\\Icons\\Trade_Mining",
	order = 40,
	defaults = {
		enabled = true,
		ore = true,            -- 기록할 종류
		herb = true,
		chest = true,
		showOnMap = true,
		map_ore = true,        -- 지도에 보일 종류 (세계 지도 필터 메뉴에서도 바꾼다, 미니맵도 같이 따른다)
		map_herb = true,
		map_chest = true,
		showOnMinimap = true,
		minimapPinSize = 12,
		pinSize = 16,
		announce = true,
	},
})

local PIN_TEMPLATE = "EzyWOWFNodePinTemplate"
local EXPORT_PREFIX = "EZYN1:"
local LEGACY_EXPORT_PREFIX = "MTKN1:"   -- 옛 이름(MyToolkit) 시절 문자열
local MERGE_YARDS = 12        -- 이 거리 안의 같은 종류는 한 곳으로 본다
local PENDING_SECONDS = 5     -- 주문 성공 뒤 전리품 창을 기다리는 시간
local ZONE_MAP = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3

-- 종류: 아이콘은 추적 주문 아이콘(광물 찾기/약초 찾기/보물 찾기)을 쓴다.
local TYPES = {
	{ key = "ore",   label = "광물",     gather = { 2575 },  trackSpell = 2580,
	  fallback = "Interface\\Icons\\Spell_Nature_Earthquake", color = { 0.75, 0.8, 1 } },
	{ key = "herb",  label = "약초",     gather = { 2366 },  trackSpell = 2383,
	  fallback = "Interface\\Icons\\INV_Misc_Flower_02", color = { 0.35, 1, 0.35 } },
	{ key = "chest", label = "보물상자", gather = { 3365, 6247, 6477, 6478, 21651, 22810 }, trackSpell = 2481,
	  fallback = "Interface\\Icons\\Racial_Dwarf_FindTreasure", color = { 1, 0.82, 0.1 } },
}
local TYPE_BY_KEY = {}

local function SpellName(id)
	if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
	return GetSpellInfo and (GetSpellInfo(id))
end

local function SpellTexture(id)
	if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(id) end
	return GetSpellTexture and GetSpellTexture(id)
end

local gatherByName, gatherByID = {}, {}
for _, info in ipairs(TYPES) do
	TYPE_BY_KEY[info.key] = info
	info.mapKey = "map_" .. info.key
	info.icon = SpellTexture(info.trackSpell) or info.fallback
	for _, id in ipairs(info.gather) do
		gatherByID[id] = info.key
		local name = SpellName(id)
		if name then gatherByName[name] = info.key end
	end
end

local db
local nodes            -- EzyWOWFDB.nodes
local provider         -- 세계 지도 데이터 제공자
local ignored          -- EzyWOWFDB.nodeIgnore [이름] = true, 퀘스트 오브젝트 등 기록하지 않을 이름
local sent = {}        -- [castGUID] = { t =, name = }
local pending          -- 성공한 채집: 전리품 창을 기다리는 중

---------------------------------------------------------------------------
-- 위치
---------------------------------------------------------------------------
-- 동굴 같은 작은 지도에 있어도 지역 지도 좌표로 적는다. (세계 지도에서 지역을 볼 때 다 보이도록)
local zoneOfMap = {}   -- [지금 지도] = 지역 지도. 지도 족보는 안 바뀌니 한 번 걸은 길은 외워 둔다
local function ZoneMapID()
	local mapID = C_Map.GetBestMapForUnit("player")
	if not mapID then return nil end
	local cached = zoneOfMap[mapID]
	if cached then return cached end
	local zoneID, known = mapID, true
	while zoneID do
		local info = C_Map.GetMapInfo(zoneID)
		if not info then
			known = false
			break
		end
		if info.mapType == ZONE_MAP then break end
		if info.mapType < ZONE_MAP or not info.parentMapID or info.parentMapID == 0 then
			zoneID = mapID
			break
		end
		zoneID = info.parentMapID
	end
	if known then zoneOfMap[mapID] = zoneID end   -- 정보가 빈 지도는 외우지 않고 다음에 다시 묻는다
	return zoneID
end

-- 족보가 바뀐다는 문서는 없지만 혹시 몰라 로딩 화면마다 잊는다
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function() wipe(zoneOfMap) end)

local function PlayerPosOn(zoneID)
	local ok, pos = pcall(C_Map.GetPlayerMapPosition, zoneID, "player")
	if not ok or not pos then return nil end
	local x, y = Clean(pos.x), Clean(pos.y)
	if not x or not y or (x == 0 and y == 0) then return nil end
	return x, y
end

local function ZonePosition()
	local zoneID = ZoneMapID()
	if not zoneID then return nil end
	local x, y = PlayerPosOn(zoneID)
	if not x then return nil end
	return zoneID, x, y
end

local function Round4(v)
	return math.floor(v * 10000 + 0.5) / 10000
end

local function MergeWorldSize(mapID)
	local w, h = C_Map.GetMapWorldSize(mapID)
	w, h = Clean(w), Clean(h)
	if not w or w == 0 then w, h = 1000, 1000 end   -- 크기를 모르면 대충 지역 하나 크기로
	return w, h
end

local function DistanceYards(w, h, x1, y1, x2, y2)
	local dx, dy = (x1 - x2) * w, (y1 - y2) * h
	return math.sqrt(dx * dx + dy * dy)
end

---------------------------------------------------------------------------
-- 기록
---------------------------------------------------------------------------
-- 들어온 기록(incoming)을 가까운 같은 종류와 합친다. 새 자리면 true.
local function MergeNode(mapID, incoming)
	nodes[mapID] = nodes[mapID] or {}
	local list = nodes[mapID]
	local w, h   -- 같은 종류가 처음 나올 때 한 번만 묻는다
	for _, node in ipairs(list) do
		if node.t == incoming.t then
			if not w then w, h = MergeWorldSize(mapID) end
			if DistanceYards(w, h, node.x, node.y, incoming.x, incoming.y) <= MERGE_YARDS then
				local total = node.c + incoming.c
				node.x = Round4((node.x * node.c + incoming.x * incoming.c) / total)
				node.y = Round4((node.y * node.c + incoming.y * incoming.c) / total)
				node.c = total
				for name, count in pairs(incoming.n) do node.n[name] = (node.n[name] or 0) + count end
				node.last = math.max(node.last or 0, incoming.last or 0)
				return false
			end
		end
	end
	local names = {}
	for name, count in pairs(incoming.n) do names[name] = count end
	list[#list + 1] = {
		x = Round4(incoming.x), y = Round4(incoming.y), t = incoming.t,
		n = names, c = incoming.c, last = incoming.last,
	}
	return true
end

local providerAttached   -- 아래 지도 핀 부분에서 정한다
local EvaluateMinimap    -- 아래 미니맵 핀 부분에서 정한다
local dataGen = 0        -- 기록·표시 설정이 바뀔 때마다 +1, 미니맵은 이걸 보고 다시 그린다

-- 기록(nodes)이나 표시 설정을 바꾸는 길은 전부 여기를 거쳐야 미니맵이 따라온다
local function RefreshMap()
	dataGen = dataGen + 1
	EvaluateMinimap()
	if providerAttached and WorldMapFrame:IsShown() then provider:RefreshAllData() end
	ns:Fire("REFRESH_UI")
end

local function Record(p)
	local isNew = MergeNode(p.mapID, {
		x = p.x, y = p.y, t = p.t, n = { [p.name] = 1 }, c = 1, last = time(),
	})
	if isNew and db.announce then
		Print(("새 위치 기록: %s |cffffd100%s|r"):format(TYPE_BY_KEY[p.t].label, p.name))
	end
	RefreshMap()
end

-- 이름을 "기록 안 함"으로 기억하고, 이미 들어간 같은 이름 기록을 모든 지역에서 뺀다. 고친 자리 수를 돌려준다.
local function ForgetName(name)
	ignored[name] = true
	local changed = 0
	for mapID, list in pairs(nodes) do
		for i = #list, 1, -1 do
			local node = list[i]
			local count = node.n[name]
			if count then
				changed = changed + 1
				node.n[name] = nil
				node.c = node.c - count
				if next(node.n) == nil or node.c <= 0 then table.remove(list, i) end
			end
		end
		if #list == 0 then nodes[mapID] = nil end
	end
	RefreshMap()
	ns:Fire("REBUILD_OPTIONS")   -- 설정 창의 이름 목록 줄 수가 바뀐다
	return changed
end

local function OnSpellcastSent(_, unit, target, castGUID, spellID)
	if unit ~= "player" or not db.enabled then return end
	spellID = Clean(spellID)
	local t = spellID and gatherByID[spellID]
	if not t then
		local name = spellID and SpellName(spellID)
		t = name and gatherByName[name]
	end
	target = Clean(target)
	castGUID = Clean(castGUID)
	if t and db[t] and castGUID and type(target) == "string" and target ~= "" and not ignored[target] then
		sent[castGUID] = { t = t, name = target }
	end
end

local function OnSpellcastSucceeded(_, unit, castGUID)
	if unit ~= "player" then return end
	castGUID = Clean(castGUID)
	local s = castGUID and sent[castGUID]
	if not s then return end
	sent[castGUID] = nil
	local mapID, x, y = ZonePosition()
	if not mapID then return end
	pending = { t = s.t, name = s.name, mapID = mapID, x = x, y = y, time = GetTime() }
end

local function OnSpellcastStopped(_, unit, castGUID)
	if unit ~= "player" then return end
	castGUID = Clean(castGUID)
	if castGUID then sent[castGUID] = nil end
end

-- 전리품이 모두 퀘스트 아이템이면 퀘스트 오브젝트(바구니, 보급품 상자 등)다.
-- 보물상자·광맥·약초는 돈이나 일반 아이템이 하나라도 나온다.
local LOOT_MONEY = Enum and Enum.LootSlotType and Enum.LootSlotType.Money or 2

local function IsQuestObjectLoot()
	if not (GetNumLootItems and GetLootSlotInfo) then return false end
	local questItems = 0
	for slot = 1, GetNumLootItems() do
		if GetLootSlotType and GetLootSlotType(slot) == LOOT_MONEY then return false end
		local texture, _, _, _, _, _, isQuestItem, questID = GetLootSlotInfo(slot)
		if texture then
			if Clean(isQuestItem) or Clean(questID) then
				questItems = questItems + 1
			else
				return false
			end
		end
	end
	return questItems > 0
end

-- 전리품 출처가 월드 오브젝트면 기록한다. 출처를 알 수 없으면(빈 상자 등) 그대로 기록한다.
-- 빠른 줍기가 LOOT_READY에서 곧바로 주워 가기 전에 봐야 하므로 다른 모듈보다 먼저 받고,
-- LOOT_READY와 LOOT_OPENED 중 먼저 오는 쪽에서 처리한다.
local function OnLootOpened()
	local p = pending
	pending = nil
	if not p or GetTime() - p.time > PENDING_SECONDS then return end
	if GetLootSourceInfo and GetNumLootItems and GetNumLootItems() > 0 then
		local guid = Clean(GetLootSourceInfo(1))
		if type(guid) == "string" and not guid:find("^GameObject") then return end
	end
	if IsQuestObjectLoot() then
		local changed = ForgetName(p.name)
		if db.announce then
			local fixed = changed > 0 and (" 잘못 들어간 %d곳도 지웠어요."):format(changed) or ""
			Print(("'%s'는 퀘스트 오브젝트라서 기록하지 않아요.%s"):format(p.name, fixed))
		end
		return
	end
	Record(p)
end

-- 남(파티·이름표)의 시전은 게임이 미리 걸러 준다.
ns:RegisterUnitEvent("UNIT_SPELLCAST_SENT", OnSpellcastSent, "player")
ns:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", OnSpellcastSucceeded, "player")
ns:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", OnSpellcastStopped, "player")
ns:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", OnSpellcastStopped, "player")
ns:RegisterEvent("LOOT_READY", OnLootOpened, true)
ns:RegisterEvent("LOOT_OPENED", OnLootOpened, true)

---------------------------------------------------------------------------
-- 핀 모양과 툴팁 (세계 지도·미니맵 공용)
---------------------------------------------------------------------------
-- 종류별 색 테두리(동그라미) 위에 동그랗게 자른 아이콘
local function DecoratePin(pin)
	pin.Ring = pin:CreateTexture(nil, "BACKGROUND")
	pin.Ring:SetAllPoints()
	pin.Ring:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")

	pin.Icon = pin:CreateTexture(nil, "ARTWORK")
	pin.Icon:SetPoint("TOPLEFT", 2, -2)
	pin.Icon:SetPoint("BOTTOMRIGHT", -2, 2)
	local mask = pin:CreateMaskTexture()
	mask:SetAllPoints(pin.Icon)
	mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	pin.Icon:AddMaskTexture(mask)
end

local function StylePin(pin, node, size)
	local info = TYPE_BY_KEY[node.t]
	pin:SetSize(size, size)
	pin.Icon:SetTexture(info.icon)
	pin.Ring:SetVertexColor(info.color[1], info.color[2], info.color[3])
end

local function ShowNodeTooltip(owner, node, withClickHint)
	local info = TYPE_BY_KEY[node.t]
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:SetText(("%s  |cffffffff(%d번)|r"):format(info.label, node.c), info.color[1], info.color[2], info.color[3])
	local names = {}
	for name, count in pairs(node.n) do names[#names + 1] = { name = name, count = count } end
	table.sort(names, function(a, b) return a.count > b.count end)
	for _, e in ipairs(names) do
		GameTooltip:AddDoubleLine(e.name, e.count .. "번", 1, 1, 1, 0.7, 0.7, 0.7)
	end
	if node.last and node.last > 0 then
		GameTooltip:AddLine("마지막: " .. date("%m/%d %H:%M", node.last), 0.6, 0.6, 0.6)
	end
	if withClickHint then
		GameTooltip:AddLine("클릭: 여기로 길 안내   Shift+클릭: 이 자리 지우기", 0.5, 0.8, 1)
		GameTooltip:AddLine("Alt+클릭: 이 이름은 모두 지우고 앞으로 기록 안 함", 0.5, 0.8, 1)
	end
	GameTooltip:Show()
end

---------------------------------------------------------------------------
-- 세계 지도 핀
---------------------------------------------------------------------------
local function DeleteNode(mapID, node)
	local list = nodes[mapID]
	if not list then return end
	for i, n in ipairs(list) do
		if n == node then
			table.remove(list, i)
			break
		end
	end
	if #list == 0 then nodes[mapID] = nil end
	RefreshMap()
end

local function SetWaypoint(mapID, node)
	if not (C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates) then return end
	C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, node.x, node.y))
	if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
		C_SuperTrack.SetSuperTrackedUserWaypoint(true)
	end
end

if MapCanvasPinMixin and MapCanvasDataProviderMixin then
	EzyWOWFNodePinMixin = CreateFromMixins(MapCanvasPinMixin)

	function EzyWOWFNodePinMixin:OnLoad()
		self:UseFrameLevelType("PIN_FRAME_LEVEL_DIG_SITE")
		self:SetScalingLimits(1, 1.0, 1.4)
		DecoratePin(self)
	end

	function EzyWOWFNodePinMixin:OnAcquired(node, mapID)
		self.node, self.mapID = node, mapID
		StylePin(self, node, db.pinSize)
		self:SetPosition(node.x, node.y)
	end

	function EzyWOWFNodePinMixin:OnMouseEnter()
		ShowNodeTooltip(self, self.node, true)
	end

	function EzyWOWFNodePinMixin:OnMouseLeave()
		GameTooltip:Hide()
	end

	function EzyWOWFNodePinMixin:OnMouseClickAction(button)
		if button ~= "LeftButton" then return end
		if IsAltKeyDown() then
			GameTooltip:Hide()
			local names = {}
			for name in pairs(self.node.n) do names[#names + 1] = name end
			local changed = 0
			for _, name in ipairs(names) do changed = changed + ForgetName(name) end
			Print(("'%s'를 모두 지우고(%d곳) 앞으로 기록하지 않아요."):format(table.concat(names, "', '"), changed))
		elseif IsShiftKeyDown() then
			GameTooltip:Hide()
			DeleteNode(self.mapID, self.node)
		else
			SetWaypoint(self.mapID, self.node)
		end
	end

	provider = CreateFromMixins(MapCanvasDataProviderMixin)

	function provider:RemoveAllData()
		self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
	end

	function provider:RefreshAllData()
		self:RemoveAllData()
		if not (db and db.enabled and db.showOnMap) then return end
		local map = self:GetMap()
		local mapID = map:GetMapID()
		for _, node in ipairs(mapID and nodes[mapID] or {}) do
			if TYPE_BY_KEY[node.t] and db["map_" .. node.t] then
				map:AcquirePin(PIN_TEMPLATE, node, mapID)
			end
		end
	end

end

-- 세계 지도는 보통 먼저 로드되어 있지만, 늦게 로드되면 그때 붙인다.
providerAttached = false
local function AttachProvider()
	if provider and not providerAttached and WorldMapFrame and WorldMapFrame.AddDataProvider then
		WorldMapFrame:AddDataProvider(provider)
		providerAttached = true
	end
end
AttachProvider()
ns:RegisterEvent("ADDON_LOADED", function(_, name)
	if name == "Blizzard_WorldMap" then AttachProvider() end
end)

---------------------------------------------------------------------------
-- 미니맵 핀
-- 미니맵은 확대 단계마다 보여 주는 지름(야드)이 정해져 있다. (실내/실외 따로, HereBeDragons와 같은 표)
-- 내 위치와 기록 위치의 차이를 야드로 바꾸고, 미니맵 반지름에 대한 비율로 픽셀 위치를 구한다.
-- 미니맵 회전 설정이면 캐릭터가 보는 방향이 위로 가도록 돌린다. 지도 밖은 숨긴다(둥근 지도는 원, 네모는 사각형).
---------------------------------------------------------------------------
local MINIMAP_DIAMETER = {
	indoor  = { [0] = 300, 240, 180, 120, 80, 50 },
	outdoor = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 },
}
local MINIMAP_INTERVAL = 0.1

local minimapPins = {}
local shownPins = 0   -- 보이는 미니맵 핀은 늘 1..shownPins 안에 있다 (이 파일 말고는 아무도 안 건드림)
local last = {}       -- 마지막으로 다 그린 입력. 전부 같으면 그 틱은 쉰다

local function MinimapPin(i)
	local pin = minimapPins[i]
	if pin then return pin end
	pin = CreateFrame("Frame", nil, Minimap)
	pin:SetFrameLevel(Minimap:GetFrameLevel() + 5)
	DecoratePin(pin)
	pin:EnableMouse(true)
	pin:SetScript("OnEnter", function(self) ShowNodeTooltip(self, self.node, false) end)
	pin:SetScript("OnLeave", GameTooltip_Hide)
	minimapPins[i] = pin
	return pin
end

local function RotateMinimap()
	if C_CVar and C_CVar.GetCVarBool then return C_CVar.GetCVarBool("rotateMinimap") end
	return GetCVar and GetCVar("rotateMinimap") == "1"
end

local function ClearMinimapPins()
	for i = 1, shownPins do minimapPins[i]:Hide() end
	shownPins = 0
	last.valid = false
end

local function UpdateMinimapPins()
	if not (db and db.enabled and db.showOnMinimap) then return ClearMinimapPins() end
	local mapID = ZoneMapID()
	local list = mapID and nodes[mapID]
	if not list or #list == 0 then return ClearMinimapPins() end   -- 빈 지역이면 내 위치는 물어볼 필요도 없다
	local px, py = PlayerPosOn(mapID)
	if not px then return ClearMinimapPins() end
	local w, h = C_Map.GetMapWorldSize(mapID)
	w, h = Clean(w), Clean(h)
	if not (w and w > 0) then return ClearMinimapPins() end

	local diameters = (IsIndoors and IsIndoors()) and MINIMAP_DIAMETER.indoor or MINIMAP_DIAMETER.outdoor
	local radiusYards = (diameters[Minimap:GetZoom()] or diameters[0]) / 2
	local half = Minimap:GetWidth() / 2
	local facing = RotateMinimap() and Clean(GetPlayerFacing()) or 0
	local square = ns.IsMinimapSquare and ns.IsMinimapSquare()
	local size = db.minimapPinSize

	-- 그림에 들어가는 입력이 전부 그대로면 지난번 그림도 그대로다
	if last.valid and last.gen == dataGen and last.mapID == mapID and last.px == px and last.py == py
		and last.w == w and last.h == h and last.radius == radiusYards and last.half == half
		and last.facing == facing and last.square == square and last.size == size then
		local same = true
		for _, info in ipairs(TYPES) do
			if last[info.mapKey] ~= db[info.mapKey] then
				same = false
				break
			end
		end
		if same then return end
	end
	last.valid = false   -- 그리다 터지면 다음 틱에 처음부터 다시

	local scale = half / radiusYards
	local cosF, sinF = math.cos(facing), math.sin(facing)
	local limit = half - size / 2
	local shown = 0
	for _, node in ipairs(list) do
		local info = TYPE_BY_KEY[node.t]
		if info and db[info.mapKey] then
			local dx = (node.x - px) * w       -- 동쪽이 +
			local dn = (py - node.y) * h       -- 북쪽이 +
			local sx = (dx * cosF + dn * sinF) * scale
			local sy = (-dx * sinF + dn * cosF) * scale
			local inside
			if square then
				inside = math.abs(sx) <= limit and math.abs(sy) <= limit
			else
				inside = sx * sx + sy * sy <= limit * limit
			end
			if inside then
				shown = shown + 1
				local pin = MinimapPin(shown)
				pin.node = node   -- 툴팁이 읽으니 모양이 같아도 매번 바꿔 끼운다
				if pin.styledType ~= node.t or pin.styledSize ~= size then   -- 모양은 종류와 크기로만 정해진다
					StylePin(pin, node, size)
					pin.styledType, pin.styledSize = node.t, size
				end
				pin:ClearAllPoints()
				pin:SetPoint("CENTER", Minimap, "CENTER", sx, sy)
				if shown > shownPins then
					shownPins = shown   -- 보이기 전에 먼저 장부에 적어야 도중에 터져도 나중에 숨길 수 있다
					pin:Show()
				end
			end
		end
	end
	for i = shown + 1, shownPins do minimapPins[i]:Hide() end
	shownPins = shown

	last.valid, last.gen, last.mapID, last.px, last.py = true, dataGen, mapID, px, py
	last.w, last.h, last.radius, last.half = w, h, radiusYards, half
	last.facing, last.square, last.size = facing, square, size
	for _, info in ipairs(TYPES) do last[info.mapKey] = db[info.mapKey] end
end

local minimapDriver = CreateFrame("Frame")
minimapDriver:Hide()   -- 기록 사용 + 미니맵 표시일 때만 돈다 (EvaluateMinimap)
local sinceMinimap = 0
minimapDriver:SetScript("OnUpdate", function(_, elapsed)
	sinceMinimap = sinceMinimap + elapsed
	if sinceMinimap < MINIMAP_INTERVAL then return end
	sinceMinimap = 0
	UpdateMinimapPins()
end)

EvaluateMinimap = function()
	if db and db.enabled and db.showOnMinimap then
		if not minimapDriver:IsShown() then
			sinceMinimap = MINIMAP_INTERVAL   -- 켜진 첫 프레임에 바로 그린다
			minimapDriver:Show()
		end
	else
		minimapDriver:Hide()
		ClearMinimapPins()
	end
end

-- 세계 지도 필터 메뉴: 지도에 표시 / 종류별 표시 (괄호 안은 지금 보는 지도의 개수)
local function CountsOnMap(mapID)
	local counts = {}
	for _, node in ipairs(mapID and nodes[mapID] or {}) do
		counts[node.t] = (counts[node.t] or 0) + 1
	end
	return counts
end

local function ToggleMapSetting(key)
	db[key] = not db[key]
	RefreshMap()
end

if Menu and Menu.ModifyMenu then
	Menu.ModifyMenu("MENU_WORLD_MAP_TRACKING", function(_, rootDescription)
		if not (db and db.enabled) then return end
		local counts = CountsOnMap(WorldMapFrame and WorldMapFrame:GetMapID())

		rootDescription:CreateDivider()
		rootDescription:CreateTitle(M.title)
		rootDescription:CreateCheckbox("지도에 표시",
			function() return db.showOnMap end,
			function() ToggleMapSetting("showOnMap") end)
		rootDescription:CreateCheckbox("미니맵에 표시",
			function() return db.showOnMinimap end,
			function() ToggleMapSetting("showOnMinimap") end)
		for _, info in ipairs(TYPES) do
			local key = "map_" .. info.key
			local label = ("|T%s:14:14|t %s (%d)"):format(tostring(info.icon), info.label, counts[info.key] or 0)
			rootDescription:CreateCheckbox(label,
				function() return db[key] end,
				function() ToggleMapSetting(key) end)
		end
	end)
end

---------------------------------------------------------------------------
-- 내보내기 / 가져오기 / 지우기
---------------------------------------------------------------------------
local function Counts()
	local counts, zones = {}, 0
	for _, list in pairs(nodes) do
		zones = zones + 1
		for _, node in ipairs(list) do counts[node.t] = (counts[node.t] or 0) + 1 end
	end
	return counts, zones
end

-- 기록된 곳 수 합계, 지역 수 (일반 > 성능 표시도 쓴다)
function M:CountRecords()
	if not nodes then return 0, 0 end
	local counts, zones = Counts()
	local total = 0
	for _, n in pairs(counts) do total = total + n end
	return total, zones
end

local function ValidNode(n)
	if type(n) ~= "table" or not TYPE_BY_KEY[n.t] or type(n.n) ~= "table" then return false end
	if type(n.x) ~= "number" or type(n.y) ~= "number" or n.x < 0 or n.x > 1 or n.y < 0 or n.y > 1 then return false end
	if type(n.c) ~= "number" or n.c < 1 then return false end
	for name, count in pairs(n.n) do
		if type(name) ~= "string" or type(count) ~= "number" then return false end
	end
	return true
end

local function ImportNodes(text)
	local ok, data = ns.DecodeData(EXPORT_PREFIX, text, LEGACY_EXPORT_PREFIX)
	if not ok then return false, data end
	if type(data.nodes) ~= "table" then return false, "채집 기록 문자열이 아닙니다." end
	if type(data.ignore) == "table" then
		for name, flag in pairs(data.ignore) do
			if type(name) == "string" and flag == true then ignored[name] = true end
		end
	end
	local added, merged = 0, 0
	for mapID, list in pairs(data.nodes) do
		if type(mapID) == "number" and type(list) == "table" then
			for _, n in ipairs(list) do
				if ValidNode(n) then
					if MergeNode(mapID, { x = n.x, y = n.y, t = n.t, n = n.n, c = n.c, last = tonumber(n.last) or 0 }) then
						added = added + 1
					else
						merged = merged + 1
					end
				end
			end
		end
	end
	RefreshMap()
	return true, ("채집 기록을 가져왔습니다. 새 위치 %d곳, 기존 위치와 합침 %d곳."):format(added, merged)
end

StaticPopupDialogs["EZYWOWF_NODES_CLEAR"] = {
	text = "%s",
	button1 = "지우기",
	button2 = "취소",
	OnAccept = function(_, onAccept) onAccept() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

local function ConfirmClear(message, onAccept)
	StaticPopup_Show("EZYWOWF_NODES_CLEAR", message, nil, onAccept)
end

local function ClearCurrentZone()
	local mapID = ZonePosition()
	if not mapID then
		Print("지금 있는 지역을 알 수 없어요.")
		return
	end
	local info = C_Map.GetMapInfo(mapID)
	local name = info and info.name or tostring(mapID)
	ConfirmClear(("%s\n\n'%s'의 채집·보물 기록을 모두 지울까요?"):format(ns.title, name), function()
		nodes[mapID] = nil
		RefreshMap()
		Print(("'%s'의 기록을 지웠습니다."):format(name))
	end)
end

local function ClearAll()
	ConfirmClear(ns.title .. "\n\n모든 지역의 채집·보물 기록을 지울까요?", function()
		wipe(nodes)
		RefreshMap()
		Print("모든 채집·보물 기록을 지웠습니다.")
	end)
end

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	ns.db.nodes = ns.db.nodes or {}
	nodes = ns.db.nodes
	ns.db.nodeIgnore = ns.db.nodeIgnore or {}
	ignored = ns.db.nodeIgnore
	EvaluateMinimap()
end

function M:ApplySettings()
	RefreshMap()
end

local function SummaryText()
	local counts, zones = Counts()
	if zones == 0 then return "기록:  |cff808080아직 없음|r" end
	local parts = {}
	for _, info in ipairs(TYPES) do
		parts[#parts + 1] = ("%s %d곳"):format(info.label, counts[info.key] or 0)
	end
	return ("기록:  |cffffffff%s|r  |cff999999(%d개 지역)|r"):format(table.concat(parts, ", "), zones)
end

function M:BuildOptions(b)
	local function Disabled() return not db.enabled end

	b:Text("채광한 광맥, 채집한 약초, 연 보물상자의 위치를 기록해서 세계 지도와 미니맵에 아이콘으로 보여 줍니다. "
		.. "같은 자리에서 다시 캐면 횟수가 늘어납니다. 지도 아이콘을 클릭하면 그 자리로 길 안내(퀘스트 방향 화살표)를 켭니다.")
	b:Check{ key = "enabled", label = "기록 사용" }
	for _, info in ipairs(TYPES) do
		b:Check{ key = info.key, label = info.label .. " 기록", depends = "enabled", indent = 20 }
	end
	b:Check{
		key = "showOnMap", label = "세계 지도에 표시", depends = "enabled",
		tooltip = "세계 지도 오른쪽 위의 필터 메뉴에서도 종류별로 바로 켜고 끌 수 있습니다.",
	}
	for _, info in ipairs(TYPES) do
		b:Check{ key = "map_" .. info.key, label = info.label .. " 표시", depends = { "enabled", "showOnMap" }, indent = 20 }
	end
	b:Slider{ key = "pinSize", label = "지도 아이콘 크기", min = 10, max = 28, step = 1, depends = { "enabled", "showOnMap" } }
	b:Check{
		key = "showOnMinimap", label = "미니맵에 표시", depends = "enabled",
		tooltip = "미니맵에도 기록한 위치를 보여 줍니다. 위의 종류별 표시 설정을 똑같이 따릅니다.",
	}
	b:Slider{
		key = "minimapPinSize", label = "미니맵 아이콘 크기", min = 8, max = 20, step = 1,
		depends = { "enabled", "showOnMinimap" },
	}
	b:Check{ key = "announce", label = "새 위치를 기록하면 채팅창에 알림", depends = "enabled" }
	b:Text(SummaryText, { font = "GameFontHighlight" })

	b:Header("기록 백업")
	b:Text("와우 포에버 베타는 게임을 다시 켜면 애드온 기록이 사라지는 버그가 있어요. 기록을 모으면 내보내 두었다가 "
		.. "다시 가져오세요. 가져오면 지금 기록에 합쳐집니다.")
	b:Buttons{
		{
			text = "기록 내보내기",
			onClick = function()
				ns.UI.ShowTextDialog{
					title = "채집 기록 내보내기",
					help = "아래 글자를 Ctrl+C로 복사해서 메모장 등에 보관하세요.",
					text = ns.EncodeData(EXPORT_PREFIX, { v = 1, nodes = nodes, ignore = ignored }),
					readOnly = true,
				}
			end,
		},
		{
			text = "기록 가져오기",
			onClick = function()
				ns.UI.ShowTextDialog{
					title = "채집 기록 가져오기",
					help = "내보내기로 복사해 둔 글자를 Ctrl+V로 붙여 넣고 [가져오기]를 누르세요.",
					text = "",
					button = "가져오기",
					onAccept = ImportNodes,
				}
			end,
		},
	}
	b:Buttons{
		{ text = "현재 지역 기록 지우기", width = 160, onClick = ClearCurrentZone },
		{ text = "모든 기록 지우기", onClick = ClearAll },
	}
	b:Text("지도에서 아이콘을 Shift+클릭하면 그 자리 기록만, Alt+클릭하면 같은 이름 기록을 모두 지우고 앞으로 기록하지 않습니다. "
		.. "퀘스트 아이템만 나오는 오브젝트(바구니, 보급품 상자 등)는 자동으로 기록하지 않아요.", { color = { 0.7, 0.7, 0.7 } })

	b:Header("기록하지 않는 이름")
	b:Buttons{
		{
			text = "목록 비우기", onClick = function()
				wipe(ignored)
				ns:Fire("REBUILD_OPTIONS")
				Print("기록하지 않는 이름 목록을 비웠습니다.")
			end,
			tooltip = "잘못 넣은 이름이 있으면 비우세요. 다음에 캐거나 열 때 다시 판단합니다.",
		},
	}
	b:Text(function()
		local names = {}
		for name in pairs(ignored or {}) do names[#names + 1] = name end
		table.sort(names)
		if #names == 0 then return "|cff808080없음|r" end
		return table.concat(names, ", ")
	end, { color = { 0.8, 0.8, 0.8 } })
end
