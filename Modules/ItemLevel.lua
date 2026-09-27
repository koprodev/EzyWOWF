-- 아이템 레벨 표시: 캐릭터 창 · 살펴보기 창 · 가방 칸에 아이템 레벨을 등급 색으로 작게 적는다.
--
-- 블리자드가 칸을 갱신하는 함수 뒤에 붙는다(hooksecurefunc, 포에버 소스에서 확인한 이름).
--   캐릭터 창: PaperDollItemSlotButton_Update(button)
--   살펴보기: InspectPaperDollItemSlotButton_Update(button)   (Blizzard_InspectUI가 로드될 때)
--   가방: ContainerFrame1~13, ContainerFrameCombinedBags 각각의 UpdateItems()
-- 셔츠·휘장·가방·탄약처럼 레벨이 의미 없는 것은 적지 않는다.

local _, ns = ...
local Clean = ns.Clean

local M = ns:NewModule("ItemLevel", {
	title = "아이템 레벨 표시",
	category = "item",
	icon = "Interface\\Icons\\INV_Chest_Chain_05",
	order = 55,
	defaults = {
		enabled = true,
		character = true,
		inspect = true,
		bags = true,
	},
})

local GetItemInfoInstantAPI = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetItemInfoAPI = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetDetailedItemLevelInfoAPI = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo

local NO_LEVEL_SLOTS = {
	INVTYPE_BAG = true, INVTYPE_QUIVER = true, INVTYPE_BODY = true, INVTYPE_TABARD = true,
	INVTYPE_AMMO = true, INVTYPE_NON_EQUIP_IGNORE = true, [""] = true,
}

local CHARACTER_SLOTS = {
	"Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet",
	"Finger0", "Finger1", "Trinket0", "Trinket1", "MainHand", "SecondaryHand", "Ranged",
}

local inspectButtons = {}   -- [버튼] = true, 살펴보기 창 칸 (끌 때 지운다)

local function Label(button)
	local fs = button.EzyWOWFItemLevel
	if not fs then
		fs = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		fs:SetPoint("BOTTOMLEFT", 2, 2)
		button.EzyWOWFItemLevel = fs
	end
	return fs
end

local function Clear(button)
	if button.EzyWOWFItemLevel then button.EzyWOWFItemLevel:SetText("") end
end

-- 링크로 레벨과 등급을 구한다. 레벨을 적지 않을 아이템이면 nil.
local function LevelFromLink(link)
	if type(link) ~= "string" then return nil end
	local equipLoc = select(4, GetItemInfoInstantAPI(link))
	if not equipLoc or NO_LEVEL_SLOTS[equipLoc] then return nil end
	local level = GetDetailedItemLevelInfoAPI(link)
	local quality = select(3, GetItemInfoAPI(link))
	if not level or level <= 1 then return nil end
	return level, quality
end

local function Show(button, level, quality)
	local fs = Label(button)
	if not level then
		fs:SetText("")
		return
	end
	local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	fs:SetText(level)
	if color then fs:SetTextColor(color.r, color.g, color.b) else fs:SetTextColor(1, 1, 1) end
end

---------------------------------------------------------------------------
-- 캐릭터 창 / 살펴보기
---------------------------------------------------------------------------
local function UpdateCharacterSlot(button)
	if not (M.db and M.db.enabled and M.db.character) then return Clear(button) end
	local slot = button:GetID()
	Show(button, LevelFromLink(GetInventoryItemLink("player", slot)))
end

local function UpdateInspectSlot(button)
	inspectButtons[button] = true
	if not (M.db and M.db.enabled and M.db.inspect) then return Clear(button) end
	local unit = InspectFrame and InspectFrame.unit
	Show(button, LevelFromLink(unit and GetInventoryItemLink(unit, button:GetID())))
end

local function RefreshCharacter()
	for _, name in ipairs(CHARACTER_SLOTS) do
		local button = _G["Character" .. name .. "Slot"]
		if button then UpdateCharacterSlot(button) end
	end
end

if PaperDollItemSlotButton_Update then
	hooksecurefunc("PaperDollItemSlotButton_Update", UpdateCharacterSlot)
end

local inspectHooked = false
local function HookInspect()
	if inspectHooked or not InspectPaperDollItemSlotButton_Update then return end
	inspectHooked = true
	hooksecurefunc("InspectPaperDollItemSlotButton_Update", UpdateInspectSlot)
end
HookInspect()
ns:RegisterEvent("ADDON_LOADED", function(_, name)
	if name == "Blizzard_InspectUI" then HookInspect() end
end)

---------------------------------------------------------------------------
-- 가방
---------------------------------------------------------------------------
local function UpdateBagFrame(frame)
	if not frame.EnumerateValidItems then return end
	local on = M.db and M.db.enabled and M.db.bags
	for _, button in frame:EnumerateValidItems() do
		if on then
			local info = C_Container.GetContainerItemInfo(button:GetBagID(), button:GetID())
			Show(button, LevelFromLink(info and Clean(info.hyperlink)))
		else
			Clear(button)
		end
	end
end

local function BagFrames()
	local frames = {}
	for i = 1, NUM_CONTAINER_FRAMES or 13 do
		local frame = _G["ContainerFrame" .. i]
		if frame then frames[#frames + 1] = frame end
	end
	if ContainerFrameCombinedBags then frames[#frames + 1] = ContainerFrameCombinedBags end
	return frames
end

local bagsHooked = false
local function HookBags()
	if bagsHooked then return end
	bagsHooked = true
	for _, frame in ipairs(BagFrames()) do
		if frame.UpdateItems then hooksecurefunc(frame, "UpdateItems", UpdateBagFrame) end
	end
end

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnLogin()
	HookBags()
end

function M:ApplySettings()
	RefreshCharacter()
	for _, frame in ipairs(BagFrames()) do
		if frame:IsShown() then UpdateBagFrame(frame) end
	end
	if not (self.db.enabled and self.db.inspect) then
		for button in pairs(inspectButtons) do Clear(button) end
	end
end

function M:BuildOptions(b)
	b:Text("장비 칸 왼쪽 아래에 아이템 레벨을 등급 색으로 적습니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Check{ key = "character", label = "캐릭터 창", depends = "enabled", indent = 20 }
	b:Check{ key = "inspect", label = "살펴보기 창 (다른 플레이어)", depends = "enabled", indent = 20 }
	b:Check{ key = "bags", label = "가방 (장비만)", depends = "enabled", indent = 20 }
end
