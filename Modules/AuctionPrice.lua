-- 경매장 시세 기록: 경매장에서 검색할 때 보이는 최저가를 품목별로 기억해 두고, 아이템 툴팁에 보여 준다.
-- 경매장에 가지 않아도 전리품을 팔지(상인) 올릴지(경매장) 가늠할 수 있게 하려는 것.
-- 판매 가격 자동 입력은 경매장 판매 창에 이미 있어서 만들지 않는다.
--
-- 포에버 경매장은 리테일 방식(C_AuctionHouse)이다.
--   AUCTION_HOUSE_BROWSE_RESULTS_UPDATED: 검색 목록의 품목별 최저가(minPrice)
--   COMMODITY_SEARCH_RESULTS_UPDATED(itemID): 소모품(묶음) 품목, 첫 결과가 가장 싼 개당 가격(unitPrice)
--   ITEM_SEARCH_RESULTS_UPDATED(itemKey): 장비 같은 개별 품목, 즉시 구매가(buyoutAmount) / 수량 중 최저
-- 시세는 계속 바뀌므로 역대 최저가가 아니라 "마지막으로 본 최저가"를 저장한다.
-- 기록은 EzyWOWFDB.prices[itemID] = { p = 가격(동), t = 본 시각 }

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local M = ns:NewModule("AuctionPrice", {
	title = "경매장 시세 기록",
	category = "item",
	icon = "Interface\\Icons\\INV_Misc_Coin_02",
	order = 60,
	defaults = {
		enabled = true,
		tooltip = true,
	},
})

local prices
local lowestByItem = {}   -- 검색 결과 한 번을 훑는 동안만 쓰는 임시 표 (itemID -> 최저가)

local function Save(itemID, price)
	itemID, price = Clean(itemID), Clean(price)
	if not (M.db and M.db.enabled and prices) then return end
	if type(itemID) ~= "number" or type(price) ~= "number" or price <= 0 then return end
	-- 있던 기록 표는 재활용. 가격이 같아도 본 시각은 매번 새로 적어야 툴팁이 "방금"이라고 한다.
	local record = prices[itemID]
	if type(record) == "table" then
		record.p = math.floor(price)
		record.t = time()
	else
		prices[itemID] = { p = math.floor(price), t = time() }
	end
end

-- 기록이 꺼져 있으면 Save가 어차피 버리니 결과 목록부터 안 훑는다.
local function OnBrowseResults()
	if not (M.db and M.db.enabled and prices) then return end
	if not (C_AuctionHouse and C_AuctionHouse.GetBrowseResults) then return end
	wipe(lowestByItem)
	for _, result in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
		local itemID = result.itemKey and Clean(result.itemKey.itemID)
		local price = Clean(result.minPrice)
		-- 레벨이 다른 같은 아이템은 품목이 여러 개로 나오므로 그중 가장 싼 것
		if itemID and price and price > 0 and (not lowestByItem[itemID] or price < lowestByItem[itemID]) then
			lowestByItem[itemID] = price
		end
	end
	for itemID, price in pairs(lowestByItem) do Save(itemID, price) end
	wipe(lowestByItem)
end

local function OnCommodityResults(_, itemID)
	if not (M.db and M.db.enabled and prices) then return end
	if not (C_AuctionHouse and C_AuctionHouse.GetNumCommoditySearchResults) then return end
	itemID = Clean(itemID)
	if not itemID or C_AuctionHouse.GetNumCommoditySearchResults(itemID) == 0 then return end
	local first = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
	if first then Save(itemID, first.unitPrice) end
end

local function OnItemResults(_, itemKey)
	if not (M.db and M.db.enabled and prices) then return end
	if not (C_AuctionHouse and C_AuctionHouse.GetNumItemSearchResults) or type(itemKey) ~= "table" then return end
	local lowest
	for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) do
		local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
		local buyout = info and Clean(info.buyoutAmount)
		local quantity = info and Clean(info.quantity) or 1
		if buyout and buyout > 0 then
			local unit = buyout / math.max(quantity, 1)
			if not lowest or unit < lowest then lowest = unit end
		end
	end
	if lowest then Save(itemKey.itemID, lowest) end
end

ns:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", OnBrowseResults)
ns:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED", OnCommodityResults)
ns:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED", OnItemResults)

---------------------------------------------------------------------------
-- 툴팁
---------------------------------------------------------------------------
local function Age(seconds)
	if seconds < 3600 then return "방금" end
	if seconds < 86400 then return ("%d시간 전"):format(math.floor(seconds / 3600)) end
	return ("%d일 전"):format(math.floor(seconds / 86400))
end

local function OnItemTooltip(tooltip, data)
	if not (M.db and M.db.enabled and M.db.tooltip and prices) or not tooltip.AddDoubleLine then return end
	local itemID = Clean(data.id)
	local record = type(itemID) == "number" and prices[itemID]
	if not record then return end
	tooltip:AddDoubleLine("경매장 최저가 " .. "|cff999999(" .. Age(time() - record.t) .. ")|r",
		ns.FormatMoney(record.p), 1, 0.82, 0, 1, 1, 1)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
end

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
StaticPopupDialogs["EZYWOWF_PRICES_CLEAR"] = {
	text = ns.title .. "\n\n기록한 경매장 시세를 모두 지울까요?",
	button1 = "지우기",
	button2 = "취소",
	OnAccept = function()
		wipe(prices)
		ns:Fire("REFRESH_UI")
		Print("경매장 시세 기록을 지웠습니다.")
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

function M:OnInitialize()
	ns.db.prices = ns.db.prices or {}
	prices = ns.db.prices
end

-- 기록된 품목 수 (일반 > 성능 표시도 쓴다)
function M:CountRecords()
	local count = 0
	for _ in pairs(prices or {}) do count = count + 1 end
	return count
end

local function SummaryText()
	local count = M:CountRecords()
	if count == 0 then return "기록:  |cff808080아직 없음 (경매장에서 검색하면 쌓여요)|r" end
	return ("기록:  |cffffffff%d개 품목|r"):format(count)
end

function M:BuildOptions(b)
	b:Text("경매장에서 검색할 때 보이는 최저가를 품목별로 기억해서 아이템 툴팁에 보여 줍니다. "
		.. "경매장 밖에서도 팔지 올릴지 가늠할 수 있어요. 가격은 개당 가격이고, 마지막으로 본 시점을 함께 적습니다.")
	b:Check{ key = "enabled", label = "시세 기록" }
	b:Check{ key = "tooltip", label = "아이템 툴팁에 경매장 최저가 표시", depends = "enabled", indent = 20 }
	b:Text(SummaryText, { font = "GameFontHighlight" })
	b:Buttons{
		{ text = "시세 기록 지우기", width = 140, onClick = function() StaticPopup_Show("EZYWOWF_PRICES_CLEAR") end },
	}
end
