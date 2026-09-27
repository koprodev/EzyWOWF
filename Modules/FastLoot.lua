-- 빠른 자동 루팅: 전리품 창이 그려지기 전에 바로 줍는다.

local _, ns = ...

local M = ns:NewModule("FastLoot", {
	title = "빠른 자동 루팅",
	category = "auto",
	icon = "Interface\\Icons\\INV_Misc_Bag_10",
	order = 30,
	defaults = {
		enabled = true,
		forceAutoLoot = true,
	},
})

local db
local lastLoot = 0

local function SetAutoLootCVar()
	if not (db.enabled and db.forceAutoLoot) or InCombatLockdown() then return end
	local setCVar = (C_CVar and C_CVar.SetCVar) or SetCVar
	setCVar("autoLootDefault", "1")
end

ns:RegisterEvent("LOOT_READY", function()
	if not (db and db.enabled) then return end
	-- 같은 시체에서 이벤트가 여러 번 오므로 잠깐 사이는 한 번만 처리한다.
	local now = GetTime()
	if now - lastLoot < 0.3 then return end
	-- 게임의 자동 루팅 상태와 자동 루팅 전환키(기본 Shift)를 함께 따른다.
	if GetCVarBool("autoLootDefault") == IsModifiedClick("AUTOLOOTTOGGLE") then return end
	lastLoot = now
	for slot = GetNumLootItems(), 1, -1 do
		LootSlot(slot)
	end
end)

function M:OnInitialize()
	db = self.db
end

function M:OnLogin()
	SetAutoLootCVar()
end

function M:ApplySettings()
	SetAutoLootCVar()
end

function M:BuildOptions(b)
	b:Text("자동 루팅할 때 전리품 창이 뜨기 전에 바로 줍습니다. 자동 루팅 전환키(기본 Shift)를 누른 채 열면 평소처럼 창이 뜹니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Check{
		key = "forceAutoLoot",
		label = "게임의 자동 루팅 설정도 켜기",
		tooltip = "접속할 때마다 게임 설정의 '자동 루팅'을 켭니다. 설정이 초기화되는 포에버 베타에서 유용합니다.",
		depends = "enabled",
		indent = 20,
	}
end
