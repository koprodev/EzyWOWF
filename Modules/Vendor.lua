-- 잡템 자동 판매 + 자동 수리. 상인 창이 열리면 동작하고, Shift를 누르고 열면 건너뛴다.

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
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
local SELL_INTERVAL = 0.1   -- 한꺼번에 팔면 서버가 거부해서 조금씩 판다

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

local function CollectJunk()
	wipe(queue)
	for bag = 0, LAST_BAG do
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

local function SellJunk()
	if selling then return end
	CollectJunk()
	if #queue == 0 then return end
	selling = true
	soldCount, soldValue = 0, 0
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
end
