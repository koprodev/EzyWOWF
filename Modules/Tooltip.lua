-- 툴팁 정보: 툴팁에 보일 정보를 고른다.
--   덧붙이기: 아이템/주문 ID, 아이템 레벨(툴팁에 없을 때만), 유닛의 대상(대상의 대상), NPC ID.
--   숨기기: 게임이 넣는 레벨·종류·진영·PvP·퀘스트 진행 줄, 판매 가격, 체력 막대.
-- TooltipDataProcessor.AddTooltipPostCall은 툴팁 내용이 채워진 뒤 불리는, 애드온용으로 열린 훅이다.
-- 줄 숨기기는 AddLinePreCall에서 true를 돌려주는 공식 방법이라 그 줄은 아예 안 들어간다. 애드온 콜백은 블리자드가 격리해서 부른다.
-- 전투 중에는 유닛 정보가 비밀값일 수 있어서 ns.Clean으로 거른다.

local _, ns = ...
local Clean = ns.Clean

local M = ns:NewModule("Tooltip", {
	title = "툴팁 정보",
	category = "item",
	icon = "Interface\\Icons\\INV_Misc_Note_06",
	order = 50,
	defaults = {
		enabled = true,
		itemID = true,
		spellID = true,
		itemLevel = true,
		targetOfTarget = true,
		npcID = false,
		-- 게임이 넣는 줄 (끄면 숨김)
		unitLevel = true,
		unitType = true,
		unitFaction = true,
		unitPvP = true,
		unitQuest = true,
		healthBar = true,
		sellPrice = true,
	},
})

local ID_COLOR = { 0.55, 0.55, 0.55 }
local GetItemInfoAPI = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstantAPI = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetDetailedItemLevelInfoAPI = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo

-- 레벨이 의미 없는 장착 부위 (가방, 셔츠, 휘장, 탄약 등)
local NO_LEVEL_SLOTS = {
	INVTYPE_BAG = true, INVTYPE_QUIVER = true, INVTYPE_BODY = true, INVTYPE_TABARD = true,
	INVTYPE_AMMO = true, INVTYPE_NON_EQUIP_IGNORE = true, [""] = true,
}

-- 툴팁에 이미 "아이템 레벨 N"이 있는지
local ITEM_LEVEL_PATTERN = ITEM_LEVEL and ("^" .. ITEM_LEVEL:gsub("%%d", "%%d+"))

local function HasItemLevelLine(data)
	if not ITEM_LEVEL_PATTERN or type(data.lines) ~= "table" then return false end
	for _, line in ipairs(data.lines) do
		local text = Clean(line.leftText)
		if type(text) == "string" and text:find(ITEM_LEVEL_PATTERN) then return true end
	end
	return false
end

local function AddID(tooltip, label, id)
	tooltip:AddLine(("%s: %s"):format(label, tostring(id)), ID_COLOR[1], ID_COLOR[2], ID_COLOR[3])
end

-- 툴팁 데이터의 아이템 링크. 가방 아이템은 hyperlink 없이 guid만 온다.
-- GameTooltip:GetItem()은 12.x에서 없어졌다. 블리자드 TooltipUtil.GetDisplayedItem과 같은 순서로 찾는다.
local function ItemLink(data)
	local link = Clean(data.hyperlink)
	if link then return link end
	local guid = Clean(data.guid)
	if guid and C_Item and C_Item.GetItemLinkByGUID then return Clean(C_Item.GetItemLinkByGUID(guid)) end
end

local function OnItem(tooltip, data)
	local db = M.db
	if not (db and db.enabled) or not tooltip.AddLine then return end
	local itemID = Clean(data.id)
	if type(itemID) ~= "number" then return end

	if db.itemLevel and not HasItemLevelLine(data) then
		local link = ItemLink(data)
		local equipLoc = select(4, GetItemInfoInstantAPI(itemID))
		if link and equipLoc and not NO_LEVEL_SLOTS[equipLoc] then
			local level = GetDetailedItemLevelInfoAPI(link) or select(4, GetItemInfoAPI(link))
			if level and level > 1 then
				tooltip:AddLine(ITEM_LEVEL and ITEM_LEVEL:format(level) or ("아이템 레벨 " .. level), 1, 0.82, 0)
			end
		end
	end
	if db.itemID then AddID(tooltip, "아이템 ID", itemID) end
end

local function OnSpell(tooltip, data)
	local db = M.db
	if not (db and db.enabled and db.spellID) or not tooltip.AddLine then return end
	local spellID = Clean(data.id)
	if type(spellID) == "number" then AddID(tooltip, "주문 ID", spellID) end
end

local function ColoredName(unit)
	local name = Clean(UnitName(unit))
	if not name then return nil end
	if Clean(UnitIsPlayer(unit)) then
		local _, class = UnitClass(unit)
		class = Clean(class)
		local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
		if color then return ("|c%s%s|r"):format(color.colorStr, name) end
	end
	return name
end

local barHidden = false

local function OnUnit(tooltip, data)
	local db = M.db
	if not (db and db.enabled) or tooltip ~= GameTooltip then return end
	if barHidden then tooltip.StatusBar:SetAlpha(0) end   -- 다른 누가 다시 켜 놨을 때 대비
	local _, unit = tooltip:GetUnit()
	unit = Clean(unit)
	if not unit then return end

	if db.targetOfTarget then
		local target = unit .. "target"
		if Clean(UnitExists(target)) then
			local name = Clean(UnitIsUnit(target, "player")) and "|cffff4040나|r" or ColoredName(target)
			if name then tooltip:AddLine("대상: " .. name, 1, 0.82, 0) end
		end
	end

	if db.npcID and not Clean(UnitIsPlayer(unit)) then
		local guid = Clean(UnitGUID(unit))
		local kind, _, _, _, _, npcID = strsplit("-", guid or "")
		if (kind == "Creature" or kind == "Vehicle") and npcID then AddID(tooltip, "NPC ID", npcID) end
	end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
	local types = Enum.TooltipDataType
	TooltipDataProcessor.AddTooltipPostCall(types.Item, OnItem)
	TooltipDataProcessor.AddTooltipPostCall(types.Spell, OnSpell)
	if types.UnitAura then TooltipDataProcessor.AddTooltipPostCall(types.UnitAura, OnSpell) end
	TooltipDataProcessor.AddTooltipPostCall(types.Unit, OnUnit)
end

---------------------------------------------------------------------------
-- 게임이 넣는 줄 숨기기
---------------------------------------------------------------------------
local LineType = Enum and Enum.TooltipDataLineType
local DataType = Enum and Enum.TooltipDataType

local function TextSet(...)
	local set = {}
	for i = 1, select("#", ...) do
		local s = select(i, ...)
		if type(s) == "string" then set[s] = true end
	end
	return set
end
local FACTION_TEXT = TextSet(FACTION_ALLIANCE, FACTION_HORDE)
local PVP_TEXT = TextSet(PVP, PVP_ENABLED)   -- koKR은 둘이 다르다 ("플레이어 간 전투" / "전쟁 참여 중")
-- "레벨 3", "레벨 ??", "레벨 3 정예". 시체("3 레벨 시체")는 어순이 달라 안 걸린다
local LEVEL_PATTERN = type(LEVEL) == "string" and ("^" .. LEVEL:gsub("%p", "%%%0") .. " [%d%?]") or nil

-- 지금 채우는 툴팁의 데이터
local function ProcessingData(tooltip)
	local info = tooltip.GetProcessingTooltipInfo and tooltip:GetProcessingTooltipInfo()
	return info and info.tooltipData
end

local function InWorldTooltip(tooltip)
	local data = ProcessingData(tooltip)
	local kind = data and Clean(data.type)
	return kind == DataType.Unit or kind == DataType.Object
end

-- 난이도 색이 붙어 와도 글자만 비교한다
local function Plain(text)
	return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- 툴팁 데이터의 GUID로 유닛 토큰을 찾는다. 비밀값이면 못 찾은 셈 치고 숨기지 않는다.
local function UnitOfData(data)
	local guid = Clean(data.guid)
	if type(guid) ~= "string" then return nil end
	local unit = UnitTokenFromGUID and Clean(UnitTokenFromGUID(guid))
	if unit then return unit end
	if Clean(UnitGUID("mouseover")) == guid then return "mouseover" end
end

-- 몹 종류 이름 ("악마"). 한 툴팁의 줄마다 다시 묻지 않게 데이터 하나에 한 번만 잰다.
local creatureData, creatureName
local function CreatureName(data)
	if data ~= creatureData then
		creatureData = data
		local unit = UnitOfData(data)
		creatureName = unit and not Clean(UnitIsPlayer(unit)) and Clean(UnitCreatureType(unit)) or nil
	end
	return creatureName
end

-- 유닛 툴팁에서 끈 줄인지. 포에버는 레벨·종류 줄에 전용 종류값을 안 붙이고 보내기도 해서 글자로도 알아본다.
local function IsHiddenUnitLine(db, data, line)
	local kind = Clean(line.type)
	if kind ~= nil then
		if kind == LineType.UnitName then return false end
		if not db.unitLevel and kind == LineType.UnitLevel then return true end
		if not db.unitType and kind == LineType.UnitType then return true end
	end
	local text = Clean(line.leftText)
	if type(text) ~= "string" then return false end
	text = Plain(text)
	if not db.unitFaction and FACTION_TEXT[text] then return true end
	if not db.unitPvP and PVP_TEXT[text] then return true end
	if not db.unitLevel and LEVEL_PATTERN and text:find(LEVEL_PATTERN) then return true end
	if not db.unitType and text == CreatureName(data) then return true end
	return false
end

local UNIT_LINE_KEYS = { "unitLevel", "unitType", "unitFaction", "unitPvP" }

-- 줄 종류와 상관없이 모든 줄에서 불린다. 유닛 툴팁이 아니면 바로 빠진다.
local function OnAnyLine(tooltip, line)
	local db = M.db
	if not (db and db.enabled) then return end
	local data = ProcessingData(tooltip)
	if not data or Clean(data.type) ~= DataType.Unit then return end
	if IsHiddenUnitLine(db, data, line) then return true end
end

-- key 설정이 꺼져 있으면 types 줄을 뺀다. when이 있으면 그 조건일 때만.
local LINE_RULES = {
	{ key = "unitQuest", types = { "QuestTitle", "QuestObjective", "QuestPlayer" }, when = InWorldTooltip },
	{ key = "sellPrice", types = { "SellPrice" } },
}

local function HideLine(rule)
	return function(tooltip, line)
		local db = M.db
		if not (db and db.enabled) or db[rule.key] then return end
		if rule.when and not rule.when(tooltip, line) then return end
		return true
	end
end

-- 애드온 줄 훅이 하나라도 걸리면 모든 툴팁 줄이 그 길을 거친다. 그래서 숨길 줄이 처음 생길 때 건다. (한 번 건 훅은 못 뗀다)
local hooked = {}

local function HookLines()
	local db = M.db
	if not (db.enabled and LineType and DataType and TooltipDataProcessor and TooltipDataProcessor.AddLinePreCall) then return end
	if not hooked.unit and TooltipDataProcessor.AllTypes then
		for _, key in ipairs(UNIT_LINE_KEYS) do
			if not db[key] then
				hooked.unit = true
				TooltipDataProcessor.AddLinePreCall(TooltipDataProcessor.AllTypes, OnAnyLine)
				break
			end
		end
	end
	for _, rule in ipairs(LINE_RULES) do
		if not db[rule.key] and not hooked[rule] then
			hooked[rule] = true
			local fn = HideLine(rule)
			for _, name in ipairs(rule.types) do
				if LineType[name] then TooltipDataProcessor.AddLinePreCall(LineType[name], fn) end
			end
		end
	end
end

-- 체력 막대는 블리자드 보안 코드가 띄우므로 숨기지 않고 투명하게만 만든다. 한 번도 안 숨겼으면 손대지 않는다.
local function ApplyHealthBar()
	local db = M.db
	local hide = db.enabled and not db.healthBar
	local bar = GameTooltip and GameTooltip.StatusBar
	if hide == barHidden or type(bar) ~= "table" then return end
	bar:SetAlpha(hide and 0 or 1)
	barHidden = hide
end

function M:OnInitialize()
	HookLines()
	ApplyHealthBar()
end

function M:ApplySettings()
	HookLines()
	ApplyHealthBar()
end

function M:BuildOptions(b)
	b:Text("툴팁에 보일 정보를 고릅니다. 켜면 보이고, 끄면 숨깁니다. 게임이 원래 넣는 줄도 숨길 수 있어요.")
	b:Check{ key = "enabled", label = "사용", tooltip = "끄면 아래 설정을 모두 무시하고 게임 기본 툴팁으로 돌아갑니다." }

	b:Header("몹·플레이어")
	b:Check{ key = "unitLevel", label = "레벨", depends = "enabled",
		tooltip = "'레벨 3'처럼 레벨로 시작하는 줄입니다. 같은 줄에 붙은 다른 글자도 함께 숨습니다." }
	b:Check{ key = "unitType", label = "종류 (야수, 인간형 등)", depends = "enabled",
		tooltip = "몹의 종류 이름만 있는 줄입니다. 플레이어의 직업 줄은 건드리지 않습니다." }
	b:Check{ key = "unitFaction", label = "진영 (얼라이언스, 호드)", depends = "enabled" }
	b:Check{ key = "unitPvP", label = "PvP 표시", depends = "enabled" }
	b:Check{ key = "unitQuest", label = "퀘스트 진행 (퀘스트 이름과 목표)", depends = "enabled",
		tooltip = "몹이나 채집물 같은 물체에 마우스를 올렸을 때 나오는 퀘스트 줄입니다." }
	b:Check{ key = "healthBar", label = "체력 막대", depends = "enabled", tooltip = "툴팁 아래에 붙는 초록색 체력 막대입니다." }
	b:Check{ key = "targetOfTarget", label = "유닛이 노리는 대상 (대상의 대상)", depends = "enabled",
		tooltip = "몹이나 플레이어 툴팁에 그 유닛의 대상을 보여 줍니다. 나를 노리면 빨간 '나'로 표시됩니다." }
	b:Check{ key = "npcID", label = "NPC ID", depends = "enabled" }

	b:Header("아이템")
	b:Check{ key = "itemLevel", label = "아이템 레벨 (툴팁에 없을 때 덧붙임)", depends = "enabled" }
	b:Check{ key = "sellPrice", label = "판매 가격", depends = "enabled" }
	b:Check{ key = "itemID", label = "아이템 ID", depends = "enabled" }

	b:Header("주문")
	b:Check{ key = "spellID", label = "주문·효과 ID", depends = "enabled" }
end
