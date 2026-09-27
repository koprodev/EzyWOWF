-- 툴팁 강화: 아이템/주문 ID, 아이템 레벨(툴팁에 없을 때만), 유닛의 대상(대상의 대상), NPC ID.
-- TooltipDataProcessor.AddTooltipPostCall은 툴팁 내용이 채워진 뒤 불리는, 애드온용으로 열린 훅이다.
-- 전투 중에는 유닛 정보가 비밀값일 수 있어서 ns.Clean으로 거른다.

local _, ns = ...
local Clean = ns.Clean

local M = ns:NewModule("Tooltip", {
	title = "툴팁 강화",
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

local function OnUnit(tooltip, data)
	local db = M.db
	if not (db and db.enabled) or tooltip ~= GameTooltip then return end
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

function M:BuildOptions(b)
	b:Text("아이템·주문·유닛 툴팁에 정보를 덧붙입니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Check{ key = "itemLevel", label = "아이템 레벨 (툴팁에 없을 때만)", depends = "enabled", indent = 20 }
	b:Check{ key = "targetOfTarget", label = "유닛이 노리는 대상 (대상의 대상)", depends = "enabled", indent = 20,
		tooltip = "몹이나 플레이어 툴팁에 그 유닛의 대상을 보여 줍니다. 나를 노리면 빨간 '나'로 표시됩니다." }
	b:Check{ key = "itemID", label = "아이템 ID", depends = "enabled", indent = 20 }
	b:Check{ key = "spellID", label = "주문·효과 ID", depends = "enabled", indent = 20 }
	b:Check{ key = "npcID", label = "NPC ID", depends = "enabled", indent = 20 }
end
