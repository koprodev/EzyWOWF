-- 싼 아이템 정리: 가방에서 판매가 합계가 가장 싼 칸에 순위를 띄우고, 가방 정리 버튼을 누르면 그 아이템을 맨 아랫줄로 모은다.
-- 정리 버튼 옆 삭제 버튼은 누를 때마다 1위 한 칸을 지운다.
--
-- DeleteCursorItem은 마우스·키 입력 한 번에 한 칸만 지우는 제한 함수라 자동 삭제는 못 하고 클릭마다 한 칸이다.
-- 게임 정리(C_Container.SortBags)는 순서를 고를 수 없어서, 정리가 끝난 뒤 PickupContainerItem으로 자리를 바꾼다.
--   정리 끝 이벤트가 없으니 가방이 SETTLE초 조용하고 잠긴 칸이 없으면 끝난 걸로 본다.
-- 맨 아랫줄은 칸 번호 대신 화면 위치로 고른다. 합친 가방은 배낭 1~10칸, 따로 연 가방은 가방마다 끝 칸이라 모드마다 다르다.
-- 판매가 0(퀘스트 아이템·귀환석)은 싼 게 아니라 못 파는 거라 순위에 안 넣는다.

local _, ns = ...
local Clean = ns.Clean
local Print = ns.Print

local M = ns:NewModule("CheapItems", {
	title = "싼 아이템 정리",
	category = "item",
	icon = "Interface\\Icons\\INV_Misc_Coin_05",
	order = 57,
	defaults = {
		enabled = true,
		count = 4,             -- 순위를 띄우고 맨 아랫줄로 모을 칸 수
		maxQuality = 1,        -- 0 회색만, 1 흰색까지
		skipTradeGoods = true, -- 옷감·가죽·광물·약초·고기 같은 직업용품
		moveAfterSort = true,
		deleteButton = true,
		tooltip = true,
	},
})

local GetItemInfoAPI = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local ITEM_CLASS = Enum and Enum.ItemClass or {}
local CLASS_TRADEGOODS = ITEM_CLASS.Tradegoods or 7
local CLASS_QUEST = ITEM_CLASS.Questitem or 12
local CLASS_KEY = ITEM_CLASS.Key or 13
local DISABLE_AUTOSORT = Enum and Enum.BagSlotFlags and Enum.BagSlotFlags.DisableAutoSort or 1
local LAST_BAG = NUM_BAG_SLOTS or 4   -- 재료 가방은 재료만 받아서 뺀다
local MAX_COUNT = 10
local SORT_MIN_WAIT = 1.0   -- 서버가 정리를 시작하기 전에 끼어들지 않게
local SETTLE = 0.6          -- 가방이 이만큼 조용하면 정리가 끝난 걸로 본다
local SORT_TIMEOUT = 15     -- 정리+옮기기가 이보다 길면 손 뗀다
local STEP_TIMEOUT = 3      -- 바꾼 자리가 이만큼 안 풀리면 멈춘다
local BORDER_TEXTURE = "Interface\\Common\\WhiteIconFrame"
local DELETE_TEXTURE = "Interface\\Buttons\\UI-GroupLoot-Pass-"   -- Up·Down·Highlight

local QUALITIES = {
	{ value = 0, text = "회색만" },
	{ value = 1, text = "회색·흰색" },
}

local db
local ranked = {}          -- 싼 순서 { rank, bag, slot, itemID, count, quality, name, value }
local rankAt = {}          -- [가방 * 1000 + 칸] = ranked 항목
local dirty = true
local waitingItems = {}    -- [itemID] = true, 아이템 정보가 아직 안 온 것
local questTexts, questDirty = {}, true
local mover                -- 정리 뒤 옮기기 상태

local function Key(bag, slot) return bag * 1000 + slot end

local function Count()
	local n = math.floor(tonumber(db.count) or 4)
	return math.max(1, math.min(MAX_COUNT, n))
end

-- 가방 설정 '이 가방 무시 > 정리'에 체크한 가방은 건드리지 않는다
local function IsSortIgnored(bag)
	if bag == 0 then
		return C_Container.GetBackpackAutosortDisabled and Clean(C_Container.GetBackpackAutosortDisabled()) or false
	end
	return C_Container.GetBagSlotFlag and Clean(C_Container.GetBagSlotFlag(bag, DISABLE_AUTOSORT)) or false
end

-- 아무 물건이나 들어가는 가방인지 (화살통·탄약 주머니·약초 가방은 아님)
local function IsPlainBag(bag)
	if not C_Container.GetContainerNumFreeSlots then return true end
	local _, family = C_Container.GetContainerNumFreeSlots(bag)
	return Clean(family) == 0
end

---------------------------------------------------------------------------
-- 순위
---------------------------------------------------------------------------
-- 다 모은 목표도 퀘스트를 넘기기 전까지는 아이템이 있어야 해서 끝난 목표 문구도 모은다.
local function ScanQuests()
	questDirty = false
	wipe(questTexts)
	for index = 1, C_QuestLog.GetNumQuestLogEntries() or 0 do
		local info = C_QuestLog.GetInfo(index)
		local questID = info and not info.isHeader and Clean(info.questID)
		if type(questID) == "number" and questID > 0 then
			for _, obj in ipairs(C_QuestLog.GetQuestObjectives(questID) or {}) do
				local text = Clean(obj.text)
				if Clean(obj.type) == "item" and type(text) == "string" then questTexts[#questTexts + 1] = text end
			end
		end
	end
end

local function NamedInQuest(name)
	for _, text in ipairs(questTexts) do
		if text:find(name, 1, true) then return true end
	end
	return false
end

-- 순위에 넣을 칸이면 항목, 아니면 nil
local function Candidate(bag, slot)
	local info = C_Container.GetContainerItemInfo(bag, slot)
	if not info then return nil end
	local itemID, quality = Clean(info.itemID), Clean(info.quality)
	if type(itemID) ~= "number" or type(quality) ~= "number" or quality > db.maxQuality then return nil end
	-- 아직 안 연 상자는 버릴 물건이 아니다
	if Clean(info.hasNoValue) or Clean(info.hasLoot) then return nil end
	local name, _, _, _, _, _, _, _, _, _, price, classID, _, _, _, _, isReagent = GetItemInfoAPI(itemID)
	if not name then
		waitingItems[itemID] = true
		return nil
	end
	name, price, classID = Clean(name), Clean(price), Clean(classID)
	if type(price) ~= "number" or price <= 0 then return nil end
	if classID == CLASS_QUEST or classID == CLASS_KEY then return nil end
	if db.skipTradeGoods and (classID == CLASS_TRADEGOODS or Clean(isReagent)) then return nil end
	local quest = C_Container.GetContainerItemQuestInfo and C_Container.GetContainerItemQuestInfo(bag, slot)
	if quest and (Clean(quest.isQuestItem) or Clean(quest.questID)) then return nil end
	if type(name) == "string" and NamedInQuest(name) then return nil end
	local count = Clean(info.stackCount) or 1
	return { bag = bag, slot = slot, itemID = itemID, count = count, quality = quality, name = name, value = price * count }
end

-- 같은 값이면 위치와 상관없는 기준으로 줄 세운다. 옮기는 중에 순위가 뒤집히면 끝없이 바꾸게 된다.
local function ByValue(a, b)
	if a.value ~= b.value then return a.value < b.value end
	if a.quality ~= b.quality then return a.quality < b.quality end
	if a.itemID ~= b.itemID then return a.itemID < b.itemID end
	if a.count ~= b.count then return a.count < b.count end
	if a.bag ~= b.bag then return a.bag < b.bag end
	return a.slot < b.slot
end

local function Recompute()
	dirty = false
	wipe(ranked)
	wipe(rankAt)
	if not (db and db.enabled) then return end
	if questDirty then ScanQuests() end
	local all = {}
	-- '이 가방 무시 > 정리'에 체크한 가방은 아끼는 물건을 둔 곳이라 순위·삭제에서 통째로 뺀다
	for bag = 0, LAST_BAG do
		local size = C_Container.GetContainerNumSlots(bag) or 0
		if size > 0 and IsPlainBag(bag) and not IsSortIgnored(bag) then
			for slot = 1, size do
				local entry = Candidate(bag, slot)
				if entry then all[#all + 1] = entry end
			end
		end
	end
	table.sort(all, ByValue)
	for i = 1, math.min(Count(), #all) do
		local entry = all[i]
		entry.rank = i
		ranked[i] = entry
		rankAt[Key(entry.bag, entry.slot)] = entry
	end
end

local function Ensure()
	if dirty then Recompute() end
end

---------------------------------------------------------------------------
-- 가방 칸 표시
---------------------------------------------------------------------------
-- 블리자드 버튼에 필드를 붙이지 않고 따로 든다. 버튼은 풀에서 재사용돼서 약한 키로 둔다.
local marks = setmetatable({}, { __mode = "k" })

local function Decorate(button)
	local entry = db and db.enabled and rankAt[Key(button:GetBagID(), button:GetID())]
	local mark = marks[button]
	if not entry then
		if mark then
			mark.border:Hide()
			mark.text:Hide()
		end
		return
	end
	if not mark then
		mark = {}
		mark.border = button:CreateTexture(nil, "OVERLAY", nil, 6)
		mark.border:SetAllPoints()
		mark.border:SetTexture(BORDER_TEXTURE)
		mark.border:SetVertexColor(1, 0.25, 0.2)
		mark.text = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
		mark.text:SetPoint("TOPRIGHT", -2, -2)
		mark.text:SetTextColor(1, 0.35, 0.3)
		marks[button] = mark
	end
	mark.text:SetText(entry.rank)
	mark.border:Show()
	mark.text:Show()
end

local function DecorateFrame(frame)
	if not frame.EnumerateValidItems then return end
	Ensure()
	for _, button in frame:EnumerateValidItems() do Decorate(button) end
end

local function RefreshShown()
	for _, frame in ipairs(ns.BagFrames()) do
		if frame:IsShown() then DecorateFrame(frame) end
	end
end

local refreshQueued = false
local function RequestRefresh()
	dirty = true
	if refreshQueued or not (db and db.enabled) then return end
	refreshQueued = true
	C_Timer.After(0.2, function()
		refreshQueued = false
		RefreshShown()
	end)
end

---------------------------------------------------------------------------
-- 정리 뒤 맨 아랫줄로 옮기기
---------------------------------------------------------------------------
local function StopMover()
	if mover and mover.ticker then mover.ticker:Cancel() end
	mover = nil
end

local function AnyLocked()
	for bag = 0, LAST_BAG do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and Clean(info.isLocked) then return true end
		end
	end
	return false
end

local function ItemAt(bag, slot)
	local info = C_Container.GetContainerItemInfo(bag, slot)
	return info and Clean(info.itemID) or nil
end

-- 지금 화면에서 가장 아래 줄의 칸들 (왼쪽부터). 같은 높이면 오른쪽 창(배낭 쪽)을 고른다.
local function BottomRow()
	local buttons, lowest = {}, nil
	for _, frame in ipairs(ns.BagFrames()) do
		if frame:IsShown() and frame.EnumerateValidItems then
			for _, button in frame:EnumerateValidItems() do
				local bottom, left = button:GetBottom(), button:GetLeft()
				if button:IsVisible() and bottom and left then
					local scale = button:GetEffectiveScale() or 1
					local b = { bag = button:GetBagID(), slot = button:GetID(), frame = frame,
						bottom = bottom * scale, left = left * scale, half = (button:GetHeight() or 0) * scale / 2 }
					buttons[#buttons + 1] = b
					if not lowest or b.bottom < lowest.bottom - 1
						or (math.abs(b.bottom - lowest.bottom) <= 1 and b.left > lowest.left) then
						lowest = b
					end
				end
			end
		end
	end
	if not lowest then return {} end
	local row = {}
	for _, b in ipairs(buttons) do
		if b.frame == lowest.frame and math.abs(b.bottom - lowest.bottom) <= math.max(lowest.half, 1)
			and b.bag >= 0 and b.bag <= LAST_BAG and IsPlainBag(b.bag) and not IsSortIgnored(b.bag) then
			row[#row + 1] = b
		end
	end
	table.sort(row, function(a, b) return a.left < b.left end)
	return row
end

-- 같은 아이템이 든 칸 중 이미 맞춘 자리가 아닌 곳. 순위 항목 자리를 먼저 본다.
local function SourceFor(entry, done)
	if not done[Key(entry.bag, entry.slot)] and ItemAt(entry.bag, entry.slot) == entry.itemID then return entry end
	for bag = 0, LAST_BAG do
		local size = C_Container.GetContainerNumSlots(bag) or 0
		if size > 0 and IsPlainBag(bag) and not IsSortIgnored(bag) then
			for slot = 1, size do
				if not done[Key(bag, slot)] and ItemAt(bag, slot) == entry.itemID then return { bag = bag, slot = slot } end
			end
		end
	end
end

local function Step()
	local now = GetTime()
	if not (mover and db and db.enabled and db.moveAfterSort) or now - mover.started > SORT_TIMEOUT then return StopMover() end
	if mover.phase == "settle" then
		if now - mover.started < SORT_MIN_WAIT or now - mover.lastChange < SETTLE or AnyLocked() then return end
		mover.targets = BottomRow()
		if #mover.targets == 0 then return StopMover() end
		mover.phase, mover.steps = "move", 0
	end
	-- 사용자가 뭔가 들고 있으면 끼어들지 않는다
	if CursorHasItem() then return StopMover() end
	if mover.waiting then
		if now - mover.lastChange < 0.15 or AnyLocked() then
			if now - mover.waiting > STEP_TIMEOUT then StopMover() end
			return
		end
		mover.waiting = nil
	end
	Recompute()
	local wanted, targets, done = ranked, mover.targets, {}
	for r = 1, math.min(#targets, #wanted) do
		local target, entry = targets[r], wanted[r]
		-- 아이템 종류만 맞으면 된다. 같은 아이템끼리 바꾸면 한 묶음으로 합쳐져 버린다.
		if ItemAt(target.bag, target.slot) ~= entry.itemID then
			local source = SourceFor(entry, done)
			if not source then return StopMover() end
			C_Container.PickupContainerItem(source.bag, source.slot)
			C_Container.PickupContainerItem(target.bag, target.slot)
			if CursorHasItem() then
				ClearCursor()
				return StopMover()
			end
			mover.steps = mover.steps + 1
			mover.waiting, mover.lastChange = now, now
			if mover.steps > MAX_COUNT * 3 then StopMover() end
			return
		end
		done[Key(target.bag, target.slot)] = true
	end
	StopMover()
	RequestRefresh()
end

local function OnSortBags()
	if not (db and db.enabled and db.moveAfterSort) then return end
	StopMover()
	local now = GetTime()
	mover = { phase = "settle", started = now, lastChange = now }
	mover.ticker = C_Timer.NewTicker(0.1, Step)
end

if C_Container and type(C_Container.SortBags) == "function" then
	hooksecurefunc(C_Container, "SortBags", OnSortBags)
end

---------------------------------------------------------------------------
-- 툴팁
---------------------------------------------------------------------------
local function OnItemTooltip(tooltip)
	if not (db and db.enabled and db.tooltip) or not (tooltip.GetOwner and tooltip.AddLine) then return end
	local owner = tooltip:GetOwner()
	if not owner or (owner.IsForbidden and owner:IsForbidden()) or not (owner.GetBagID and owner.GetID) then return end
	local bag, slot = owner:GetBagID(), owner:GetID()
	if type(bag) ~= "number" or type(slot) ~= "number" then return end
	Ensure()
	local entry = rankAt[Key(bag, slot)]
	if entry then
		tooltip:AddLine(("가방에서 %d번째로 싼 아이템 · 판매가 %s"):format(entry.rank, ns.FormatMoney(entry.value)), 1, 0.45, 0.35)
	end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
end

---------------------------------------------------------------------------
-- 1위 한 칸 지우기 (정리 버튼 옆 버튼)
---------------------------------------------------------------------------
local deleteButton

local function EntryText(entry)
	local info = C_Container.GetContainerItemInfo(entry.bag, entry.slot)
	local link = info and Clean(info.hyperlink)
	local count = entry.count > 1 and (" x" .. entry.count) or ""
	return (type(link) == "string" and link or entry.name or "?") .. count
end

local function ShowDeleteTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:SetText("싼 아이템 삭제", 1, 1, 1)
	Ensure()
	local entry = ranked[1]
	if entry then
		GameTooltip:AddLine("누르면 지울 아이템: " .. EntryText(entry), 1, 0.82, 0, true)
		GameTooltip:AddLine("판매가 " .. ns.FormatMoney(entry.value), 1, 1, 1)
		GameTooltip:AddLine("한 번에 한 칸씩 가장 싼 것부터 지웁니다. 되돌릴 수 없어요.", 1, 0.3, 0.3, true)
	else
		GameTooltip:AddLine("지울 싼 아이템이 없어요.", 0.7, 0.7, 0.7)
	end
	GameTooltip:Show()
end

local function DeleteCheapest()
	if not (db and db.enabled and db.deleteButton) then return end
	if mover then return Print("가방을 정리하는 중이에요. 끝난 뒤 다시 눌러 주세요.") end
	if CursorHasItem() then return Print("손에 든 아이템을 먼저 내려놓아 주세요.") end
	Recompute()
	local entry = ranked[1]
	if not entry then return Print("지울 싼 아이템이 없어요.") end
	local info = C_Container.GetContainerItemInfo(entry.bag, entry.slot)
	if not info or Clean(info.isLocked) then return Print("아이템이 잠겨 있어요. 잠시 뒤 다시 눌러 주세요.") end
	local text = EntryText(entry)
	C_Container.PickupContainerItem(entry.bag, entry.slot)
	-- 집은 게 1위 아이템이 아니면 내려놓고 그만둔다
	local kind, itemID = GetCursorInfo()
	if kind ~= "item" or Clean(itemID) ~= entry.itemID then
		ClearCursor()
		return
	end
	DeleteCursorItem()
	if CursorHasItem() then
		ClearCursor()
		return Print("게임이 삭제를 막았어요. 아이템은 그대로입니다.")
	end
	Print(("지웠습니다: %s (판매가 %s)"):format(text, ns.FormatMoney(entry.value)))
end

-- 검색창과 정리 버튼 사이가 3px뿐이라 가방 창 왼쪽 바깥, 정리 버튼 높이에 둔다
local function PlaceDeleteButton()
	local bag = deleteButton and BagItemAutoSortButton:GetParent()
	if not bag then return end
	deleteButton:ClearAllPoints()
	deleteButton:SetPoint("TOPRIGHT", bag, "TOPLEFT", -6, -34)
end

local function CreateDeleteButton()
	if deleteButton or type(BagItemAutoSortButton) ~= "table" or not BagItemAutoSortButton.GetParent then return end
	-- 정리 버튼의 자식이라 그 버튼이 보일 때(배낭·합친 가방이 열렸을 때)만 보인다
	deleteButton = CreateFrame("Button", nil, BagItemAutoSortButton)
	deleteButton:SetSize(26, 26)
	deleteButton:SetNormalTexture(ns.GetIcon(DELETE_TEXTURE .. "Up"))
	deleteButton:SetPushedTexture(ns.GetIcon(DELETE_TEXTURE .. "Down"))
	deleteButton:SetHighlightTexture(ns.GetIcon(DELETE_TEXTURE .. "Highlight"), "ADD")
	deleteButton:RegisterForClicks("LeftButtonUp")
	deleteButton:SetScript("OnClick", DeleteCheapest)
	deleteButton:SetScript("OnEnter", ShowDeleteTooltip)
	deleteButton:SetScript("OnLeave", GameTooltip_Hide)
	deleteButton:SetScript("OnShow", PlaceDeleteButton)
	PlaceDeleteButton()
end

local function UpdateDeleteButton()
	if deleteButton then deleteButton:SetShown(db.enabled and db.deleteButton) end
end

---------------------------------------------------------------------------
-- 이벤트
---------------------------------------------------------------------------
local function Touch()
	if mover then mover.lastChange = GetTime() end
end

ns:RegisterEvent("BAG_UPDATE", function()
	dirty = true
	Touch()
end)
ns:RegisterEvent("ITEM_LOCK_CHANGED", Touch)
ns:RegisterEvent("BAG_UPDATE_DELAYED", function()
	dirty = true
	if not (db and db.enabled) then return end
	RefreshShown()
	-- 지우고 나면 삭제 버튼 툴팁도 다음 1위로
	if deleteButton and GameTooltip:IsOwned(deleteButton) then ShowDeleteTooltip(deleteButton) end
end)
ns:RegisterEvent("QUEST_LOG_UPDATE", function()
	questDirty = true
	RequestRefresh()
end)
ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, itemID)
	if waitingItems[itemID] then
		waitingItems[itemID] = nil
		RequestRefresh()
	end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
end

local hooked = false
function M:OnLogin()
	if hooked then return end
	hooked = true
	for _, frame in ipairs(ns.BagFrames()) do
		if frame.UpdateItems then hooksecurefunc(frame, "UpdateItems", DecorateFrame) end
	end
	CreateDeleteButton()
	UpdateDeleteButton()
end

function M:ApplySettings()
	dirty = true
	if not (db.enabled and db.moveAfterSort) then StopMover() end
	RefreshShown()
	UpdateDeleteButton()
end

local function ListText()
	if not db.enabled then return "지금 싼 순서:  |cff808080기능 꺼짐|r" end
	Ensure()
	if #ranked == 0 then return "지금 싼 순서:  |cff808080없음|r" end
	local lines = { "지금 싼 순서:" }
	for _, entry in ipairs(ranked) do
		local count = entry.count > 1 and (" x" .. entry.count) or ""
		lines[#lines + 1] = ("  %d. %s%s  |cffffffff%s|r"):format(entry.rank, entry.name or "?", count, ns.FormatMoney(entry.value))
	end
	return table.concat(lines, "\n")
end

function M:BuildOptions(b)
	b:Text("가방에서 판매가 합계(개당 가격 × 개수)가 가장 싼 칸에 빨간 테두리와 순위를 띄웁니다. "
		.. "가방 창의 정리 버튼을 누르면 정리가 끝난 뒤 그 아이템을 맨 아랫줄 왼쪽부터 싼 순서로 모으고, "
		.. "옆의 빨간 X 버튼을 누를 때마다 가장 싼 것부터 한 칸씩 지웁니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Slider{ key = "count", label = "순위 칸 수", min = 1, max = MAX_COUNT, step = 1, depends = "enabled" }
	b:Dropdown{ key = "maxQuality", label = "순위에 넣을 등급", options = function() return QUALITIES end, width = 160, depends = "enabled" }
	b:Check{
		key = "skipTradeGoods", label = "전문 기술 재료 빼기 (옷감·가죽·광물·약초·고기 등)", depends = "enabled", indent = 20,
		tooltip = "아이템 분류가 직업용품이거나 게임이 제작 재료로 표시한 아이템은 순위에 넣지 않습니다.",
	}
	b:Check{
		key = "moveAfterSort", label = "가방 정리 버튼을 누르면 맨 아랫줄로 모으기", depends = "enabled", indent = 20,
		tooltip = "정리가 끝나고 가방이 잠잠해지면 한 칸씩 자리를 바꿉니다. 그동안 아이템을 집어 들면 멈춥니다.\n"
			.. "가방 설정의 '이 가방 무시 > 정리'에 체크한 가방은 건드리지 않습니다.",
	}
	b:Check{
		key = "deleteButton", label = "정리 버튼 옆에 싼 아이템 삭제 버튼", depends = "enabled", indent = 20,
		tooltip = "가방 창 왼쪽 바깥, 정리 버튼 높이에 빨간 X 버튼을 둡니다. 누를 때마다 1위 아이템 한 칸을 지웁니다.\n"
			.. "버튼에 마우스를 올리면 지울 아이템이 보입니다. 지운 아이템은 되돌릴 수 없습니다.",
	}
	b:Check{ key = "tooltip", label = "툴팁에 순위와 판매가 표시", depends = "enabled", indent = 20 }
	b:Text("- 판매가가 없거나 팔 수 없는 아이템, 퀘스트 아이템, 퀘스트 목표에 이름이 나오는 아이템, 아직 열지 않은 상자는 순위에 넣지 않습니다.\n"
		.. "- 잠금: 가방 창 왼쪽 위 아이콘을 누르고(합친 가방이면 가방 이름을 고른 뒤) '이 가방 무시'의 [정리]에 체크하면, "
		.. "그 가방의 아이템은 순위·삭제·맨 아랫줄 모으기에서 빠집니다. 같은 자리를 다시 눌러 체크를 풀면 다시 들어갑니다.\n"
		.. "- 삭제 버튼은 한 번 누를 때 한 칸만 지웁니다. 게임이 애드온의 아이템 삭제를 입력 한 번에 한 칸으로 제한합니다.\n"
		.. "- 화살통·탄약 주머니 같은 전용 가방과 재료 가방은 보지 않습니다.",
		{ color = { 0.7, 0.7, 0.7 } })
	b:Text(ListText)
end
