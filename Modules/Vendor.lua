-- 잡템 자동 판매 + 자동 수리. 상인 창이 열리면 동작하고, Shift를 누르고 열면 건너뛴다.
-- 판매는 게임의 일괄 판매(C_MerchantFrame.SellAllJunkItems)를 쓰고, 없는 클라이언트에서만 한 칸씩 판다.

local _, ns = ...
local Print = ns.Print

local M = ns:NewModule("Vendor", {
	title = "잡템 판매·자동 수리",
	category = "auto",
	icon = "Interface\\Icons\\INV_Misc_Coin_01",
	order = 10,
	defaults = {
		enabled = true,
		sellJunk = true,
		repair = true,
		useGuildFunds = false,
		report = true,
	},
})

local POOR = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0
local EXCLUDE_JUNK_SELL = (Enum and Enum.BagSlotFlags and Enum.BagSlotFlags.ExcludeJunkSell) or 64
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
local SELL_INTERVAL = 0.1   -- 일괄 판매가 없을 때만: 한꺼번에 팔면 서버가 거부해서 조금씩 판다
local REPORT_WAIT = 1.5     -- 일괄 판매 뒤 가방이 비워질 때까지 기다렸다가 판 것을 센다

local db
local merchantOpen = false
local queue = {}
local selling = false
local soldCount, soldValue = 0, 0

---------------------------------------------------------------------------
-- 수리
---------------------------------------------------------------------------
local function RepairWithOwnMoney()
	local cost, canRepair = GetRepairAllCost()
	if not canRepair or cost <= 0 then return end
	if GetMoney() >= cost then
		RepairAllItems()
		if db.report then Print("수리했습니다: " .. ns.FormatMoney(cost)) end
	else
		Print("|cffff5555수리비가 모자랍니다:|r " .. ns.FormatMoney(cost))
	end
end

local function Repair()
	if not (CanMerchantRepair and CanMerchantRepair()) then return end
	local cost, canRepair = GetRepairAllCost()
	if not canRepair or cost <= 0 then return end

	if db.useGuildFunds and IsInGuild() and CanGuildBankRepair and CanGuildBankRepair() then
		RepairAllItems(true)
		-- 길드 한도가 모자라면 수리가 안 되므로 잠시 뒤 남은 수리비를 확인한다.
		C_Timer.After(0.5, function()
			if not merchantOpen then return end
			local left, stillNeeds = GetRepairAllCost()
			if stillNeeds and left > 0 then
				RepairWithOwnMoney()
			elseif db.report then
				Print("길드 자금으로 수리했습니다: " .. ns.FormatMoney(cost))
			end
		end)
		return
	end
	RepairWithOwnMoney()
end

---------------------------------------------------------------------------
-- 잡템 판매
---------------------------------------------------------------------------
local function SellPrice(itemID)
	local price = select(11, C_Item.GetItemInfo(itemID))
	return price or 0
end

-- 가방 설정 '이 가방 무시 > 잡동사니 판매'에 체크한 가방은 안 판다. 게임의 '모든 잡동사니 아이템 판매'와 같은 규칙
local function SellLocked(bag)
	if bag == 0 then
		return C_Container.GetBackpackSellJunkDisabled and ns.Clean(C_Container.GetBackpackSellJunkDisabled()) or false
	end
	return C_Container.GetBagSlotFlag and ns.Clean(C_Container.GetBagSlotFlag(bag, EXCLUDE_JUNK_SELL)) or false
end

local function CollectJunk()
	wipe(queue)
	for bag = 0, LAST_BAG do
		if not SellLocked(bag) then
			for slot = 1, C_Container.GetContainerNumSlots(bag) do
				local info = C_Container.GetContainerItemInfo(bag, slot)
				if info and info.quality == POOR and not info.hasNoValue then
					queue[#queue + 1] = {
						bag = bag, slot = slot, itemID = info.itemID,
						value = SellPrice(info.itemID) * (info.stackCount or 1),
					}
				end
			end
		end
	end
end

local function FinishSelling()
	selling = false
	if soldCount > 0 and db.report then
		Print(("잡템 %d개를 팔았습니다: %s"):format(soldCount, ns.FormatMoney(soldValue)))
	end
end

local function SellNext()
	if not merchantOpen then
		FinishSelling()
		return
	end
	local item = table.remove(queue, 1)
	if not item then
		FinishSelling()
		return
	end
	-- 그사이 가방이 바뀌었을 수 있으니 같은 아이템인지 다시 확인한다.
	local info = C_Container.GetContainerItemInfo(item.bag, item.slot)
	if info and info.itemID == item.itemID and info.quality == POOR and not info.isLocked then
		C_Container.UseContainerItem(item.bag, item.slot)
		soldCount = soldCount + 1
		soldValue = soldValue + item.value
	end
	C_Timer.After(SELL_INTERVAL, SellNext)
end

-- 게임의 '모든 잡동사니 아이템 판매'는 서버에 한 번만 요청한다. 한 칸씩 빨리 팔다 요청이 엇갈려
-- 아이템이 잠긴 채 남는 일이 없고, 판매 잠금 가방도 게임이 알아서 뺀다.
local function CanSellAll()
	local merchant = C_MerchantFrame
	if not (merchant and type(merchant.SellAllJunkItems) == "function") then return false end
	return type(merchant.IsSellAllJunkEnabled) ~= "function" or ns.Clean(merchant.IsSellAllJunkEnabled()) == true
end

-- 요청 전 목록과 비교해 실제로 가방에서 빠진 것만 판 것으로 센다
local function ReportSold(list)
	soldCount, soldValue = 0, 0
	for _, item in ipairs(list) do
		local info = C_Container.GetContainerItemInfo(item.bag, item.slot)
		if not (info and info.itemID == item.itemID) then
			soldCount, soldValue = soldCount + 1, soldValue + item.value
		end
	end
	FinishSelling()
end

local function SellJunk()
	if selling then return end
	CollectJunk()
	if #queue == 0 then return end
	selling = true
	soldCount, soldValue = 0, 0
	if CanSellAll() then
		local list = queue
		queue = {}
		C_MerchantFrame.SellAllJunkItems()
		C_Timer.After(REPORT_WAIT, function() ReportSold(list) end)
		return
	end
	SellNext()
end

---------------------------------------------------------------------------
-- 이벤트
---------------------------------------------------------------------------
ns:RegisterEvent("MERCHANT_SHOW", function()
	merchantOpen = true
	if not (db and db.enabled) or IsShiftKeyDown() then return end
	if db.repair then Repair() end
	if db.sellJunk then SellJunk() end
end)

ns:RegisterEvent("MERCHANT_CLOSED", function()
	merchantOpen = false
end)

function M:OnInitialize()
	db = self.db
end

function M:BuildOptions(b)
	b:Text("상인 창을 열면 회색(잡동사니) 아이템을 팔고 장비를 수리합니다. Shift를 누른 채 상인을 열면 그때만 건너뜁니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Check{ key = "sellJunk", label = "잡템 자동 판매", depends = "enabled", indent = 20 }
	b:Check{ key = "repair", label = "장비 자동 수리", depends = "enabled", indent = 20 }
	b:Check{
		key = "useGuildFunds",
		label = "길드 자금으로 먼저 수리",
		tooltip = "길드 수리 권한이 있으면 길드 자금을 쓰고, 한도가 모자라면 내 돈으로 수리합니다.",
		depends = { "enabled", "repair" },
		indent = 40,
	}
	b:Check{ key = "report", label = "판매·수리 금액을 채팅창에 표시", depends = "enabled", indent = 20 }
	b:Text("- 판매 잠금: 가방 창 왼쪽 위 아이콘을 누르고(합친 가방이면 가방 이름을 고른 뒤) '이 가방 무시'의 [잡동사니 판매]에 체크하면, "
		.. "그 가방의 회색 아이템은 팔지 않습니다. 같은 자리를 다시 눌러 체크를 풀면 다시 팝니다.",
		{ color = { 0.7, 0.7, 0.7 } })
end
