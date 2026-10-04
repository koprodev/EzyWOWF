-- 비싼 보상 강조: 보상을 하나 골라야 하는 퀘스트에서 상점 판매가가 가장 높은 보상 아이콘에 금화를 붙인다.
--
-- 포에버는 Mainline QuestInfo.lua를 쓰고, 보상 칸은 QuestInfo_ShowRewards가 채운다. 불리는 길이 둘이라 둘 다 뒤에 붙는다.
--   QuestInfo_Display(템플릿 표에 든 원래 함수를 부름): NPC 퀘스트 창·퀘스트 목록·지도 옆 퀘스트 정보
--   전역 QuestInfo_ShowRewards(): QUEST_ITEM_UPDATE(아이템 정보 도착) 등에서 QuestFrame이 보상만 다시 그릴 때
-- 고를 보상 칸은 type "choice"·objectType "item"이고, GetID()는 블리자드 툴팁이 쓰는 바로 그 번호다.
-- 판매가는 아이템 정보가 캐시에 있어야 나온다. 하나라도 모르면 GET_ITEM_INFO_RECEIVED를 기다렸다가 다시 잰다.

local _, ns = ...

local M = ns:NewModule("QuestReward", {
	title = "비싼 보상 강조",
	category = "quest",
	icon = "Interface\\Icons\\INV_Misc_Coin_03",
	order = 45,
	defaults = {
		enabled = true,
		tooltip = true,
	},
})

local GetItemInfoAPI = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local RequestLoadItem = C_Item and C_Item.RequestLoadItemDataByID
local COIN_ATLAS = "coin-gold"
local COIN_FILE = "Interface\\MoneyFrame\\UI-GoldIcon"

local db
local coins = {}     -- [보상 버튼] = 금화 텍스처 (블리자드 버튼에 필드를 달지 않는다)
local marked = {}    -- [보상 버튼] = { value =, count = } 지금 금화가 붙은 칸 (툴팁 줄용)
local state = {}     -- [보상 틀] = { isLog =, questID =, waiting = { [itemID] = true } } 마지막으로 잰 내용
local broken = {}    -- [itemID] = true, 정보 받기에 실패한 아이템 (판매가 0으로 친다)

local function CurrentQuestID(isLog)
	if isLog then return C_QuestLog and C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest() end
	return GetQuestID and GetQuestID()
end

local function Coin(button)
	local coin = coins[button]
	if not coin then
		local icon = button.Icon or button
		local size = math.min(18, math.max(12, math.floor((icon:GetHeight() or 39) * 0.45 + 0.5)))
		coin = button:CreateTexture(nil, "OVERLAY", nil, 7)
		coin:SetSize(size, size)
		coin:SetPoint("TOPLEFT", icon, "TOPLEFT", -3, 3)   -- 모서리에서 살짝 삐져나와야 눈에 띈다
		if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(COIN_ATLAS) then
			coin:SetAtlas(COIN_ATLAS)
		else
			coin:SetTexture(COIN_FILE)
		end
		coins[button] = coin
	end
	return coin
end

local function ClearFrame(frame)
	for _, button in ipairs(frame.RewardButtons or {}) do
		if coins[button] then coins[button]:Hide() end
		marked[button] = nil
	end
end

-- 보상 칸 하나의 판매가 합계(개수만큼 곱함)와 개수. 아직 모르면 nil과 itemID.
local function ChoiceValue(button, isLog)
	local index = button:GetID()
	local link, count, itemID, _
	if isLog then
		link = GetQuestLogItemLink("choice", index)
		_, _, count, _, _, itemID = GetQuestLogChoiceInfo(index)
	else
		link = GetQuestItemLink("choice", index)
		_, _, count, _, _, itemID = GetQuestItemInfo("choice", index)
	end
	count = math.max(tonumber(count) or 1, 1)
	if itemID and broken[itemID] then return 0, count end
	local item = link or itemID
	local price = item and select(11, GetItemInfoAPI(item))
	if type(price) ~= "number" then return nil, itemID end
	return price * count, count
end

local function Evaluate(frame, isLog)
	ClearFrame(frame)
	state[frame] = nil
	if not frame:IsShown() then return end
	-- 꺼져 있어도 무엇이 떠 있는지는 적어 둔다. 창을 연 채로 켜도 바로 붙는다
	local s = { isLog = isLog, questID = CurrentQuestID(isLog), waiting = {} }
	state[frame] = s
	if not (db and db.enabled) then return end

	local values, choices, best = {}, 0, 0
	for _, button in ipairs(frame.RewardButtons or {}) do
		if button:IsShown() and button.type == "choice" and button.objectType == "item" then
			choices = choices + 1
			local value, extra = ChoiceValue(button, isLog)
			if value then
				values[button] = { value = value, count = extra }
				if value > best then best = value end
			elseif extra then
				s.waiting[extra] = true
				if RequestLoadItem then RequestLoadItem(extra) end
			end
		end
	end
	-- 하나라도 모르면 다 올 때까지 미룬다. 엉뚱한 칸에 붙였다가 옮기면 더 헷갈린다
	if next(s.waiting) or choices < 2 or best <= 0 then return end
	for button, v in pairs(values) do
		if v.value == best then   -- 값이 같으면 모두 붙인다
			Coin(button):Show()
			marked[button] = v
		end
	end
end

-- 마지막으로 잰 그 퀘스트가 아직 떠 있으면 다시 잰다. 아니면 금화만 뗀다.
local function Reevaluate(frame)
	local s = state[frame]
	if s and frame:IsShown() and CurrentQuestID(s.isLog) == s.questID then
		Evaluate(frame, s.isLog)
	else
		ClearFrame(frame)
		state[frame] = nil
	end
end

-- Reevaluate가 state 키를 지웠다 다시 넣으므로 pairs로 도는 중에 부르면 안 된다. 목록을 떠서 돈다
local function MeasuredFrames()
	local list = {}
	for frame in pairs(state) do list[#list + 1] = frame end
	return list
end

-- 이번 템플릿에 보상이 있었으면 보상 틀이 parentFrame 밑으로 옮겨져 있다. 보상 없는 템플릿(지도 설명 쪽)은 건너뛴다.
local function OnDisplay(_, parentFrame)
	local frame = QuestInfoFrame and QuestInfoFrame.rewardsFrame
	if frame and frame:GetParent() == parentFrame then Evaluate(frame, QuestInfoFrame.questLog) end
end

local function OnShowRewards()
	local frame = QuestInfoFrame and QuestInfoFrame.rewardsFrame
	if frame then Evaluate(frame, QuestInfoFrame.questLog) end
end

-- Blizzard_UIPanels_Game은 보통 우리보다 먼저 뜬다. 혹시 늦으면 뜰 때 붙는다
local hooked = false
local function Hook()
	if hooked or type(QuestInfo_Display) ~= "function" or type(QuestInfo_ShowRewards) ~= "function" then return end
	hooked = true
	hooksecurefunc("QuestInfo_Display", OnDisplay)
	hooksecurefunc("QuestInfo_ShowRewards", OnShowRewards)
end
Hook()
ns:RegisterEvent("ADDON_LOADED", function(_, name)
	if name == "Blizzard_UIPanels_Game" then Hook() end
end)

ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, itemID, success)
	for _, frame in ipairs(MeasuredFrames()) do
		local s = state[frame]
		if s and s.waiting[itemID] then
			s.waiting[itemID] = nil
			if success == false then broken[itemID] = true end
			if not next(s.waiting) then Reevaluate(frame) end
		end
	end
end)

local function OnItemTooltip(tooltip, data)
	if not (db and db.enabled and db.tooltip) or not (tooltip.GetOwner and tooltip.AddDoubleLine) then return end
	local v = marked[tooltip:GetOwner()]
	if not v then return end
	local label = v.count > 1 and ("가장 비싼 보상 |cff999999(%d개 판매가)|r"):format(v.count) or "가장 비싼 보상 |cff999999(판매가)|r"
	tooltip:AddDoubleLine(label, ns.FormatMoney(v.value), 1, 0.82, 0, 1, 1, 1)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
end

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
end

-- 금화는 잰 틀(state)에만 붙고, 꺼져 있을 때 뜬 틀도 state에 있으니 그 틀만 다시 재면 된다
function M:ApplySettings()
	for _, frame in ipairs(MeasuredFrames()) do Reevaluate(frame) end
end

function M:BuildOptions(b)
	b:Text("보상을 하나 골라야 하는 퀘스트에서, 상점에 팔 때 가장 비싼 보상 아이콘 왼쪽 위에 금화를 붙입니다. "
		.. "퀘스트를 받을 때·완료할 때·퀘스트 목록 어디서 봐도 같습니다.")
	b:Text("여러 개를 주는 보상은 개수만큼 곱해서 비교합니다. 값이 같으면 모두 붙이고, 모두 팔 수 없는 보상이면 붙이지 않습니다.",
		{ color = { 0.7, 0.7, 0.7 } })
	b:Check{ key = "enabled", label = "사용" }
	b:Check{
		key = "tooltip",
		label = "금화 붙은 보상 툴팁에 판매가 한 줄",
		tooltip = "보상 위에 마우스를 올리면 판매가 합계를 한 줄 더 보여 줍니다.",
		depends = "enabled",
		indent = 20,
	}
end
