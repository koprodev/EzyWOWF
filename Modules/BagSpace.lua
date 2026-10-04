-- 가방 칸 수 표시: 가방 막대의 배낭·가방·재료 가방 칸마다 "찬 칸/전체 칸"(설정으로 "빈 칸/전체 칸")을 적는다.
--
-- 포에버 가방 막대(Blizzard_MainMenuBarBagButtons, Camelot):
--   MainMenuBarBackpackButton = 가방 0, CharacterBag0~3Slot = 가방 1~4, CharacterReagentBag0Slot = 재료 가방 5.
--   열쇠고리는 Camelot에 아직 없다는 블리자드 주석대로 뺀다.
-- 버튼 아래쪽은 블리자드 글자 차지다. 가운데 FreeSlots "(N)"(전체 빈칸), 오른쪽 Count(배낭은 탄약 수).
--   그래서 기본은 위쪽. 아래로 두면 "(N)" 자리에 쓰고 "(N)"은 SetAlpha(0)으로 가린다 (Hide는 블리자드가 접속마다 되살림).
--   아래는 Count와 겹친다. 빈자리가 없어서 선택지로만 둔다.
-- 블리자드 버튼의 함수·스크립트는 건드리지 않고 버튼마다 글자 하나만 얹는다.

local _, ns = ...
local Clean = ns.Clean

local M = ns:NewModule("BagSpace", {
	title = "가방 칸 수 표시",
	category = "item",
	icon = "Interface\\Icons\\INV_Misc_Bag_09",
	order = 56,
	defaults = {
		enabled = true,
		count = "used",     -- used(찬 칸) | free(빈 칸)
		position = "top",   -- top | bottom
		fullRed = true,
	},
})

local db

-- GetBagID는 인벤토리 칸 번호가 이어진다고 믿는 계산이라 가방 번호를 직접 적는다
local BAGS = {
	{ name = "MainMenuBarBackpackButton", bag = 0 },
	{ name = "CharacterBag0Slot", bag = 1 },
	{ name = "CharacterBag1Slot", bag = 2 },
	{ name = "CharacterBag2Slot", bag = 3 },
	{ name = "CharacterBag3Slot", bag = 4 },
	{ name = "CharacterReagentBag0Slot", bag = 5 },
}
local WATCHED = {}   -- [가방 번호] = true
for _, entry in ipairs(BAGS) do WATCHED[entry.bag] = true end

local COUNTS = {
	{ value = "used", text = "찬 칸/전체 (8칸에 1개면 1/8)" },
	{ value = "free", text = "빈 칸/전체 (8칸에 1개면 7/8)" },
}

local POSITIONS = {
	{ value = "top", text = "위" },
	{ value = "bottom", text = "아래 (배낭의 (N) 자리)" },
}

local labels = {}          -- [가방 번호] = FontString
local freeHidden = false   -- 블리자드 "(N)"을 우리가 가렸는지 (되돌릴 때 남의 알파는 안 건드리려고)

---------------------------------------------------------------------------
-- 글자
---------------------------------------------------------------------------
local function Place(fs)
	fs:ClearAllPoints()
	if db.position == "bottom" then
		fs:SetPoint("CENTER", 0, -10)   -- 블리자드 "(N)"과 같은 자리
	else
		fs:SetPoint("CENTER", 0, 10)
	end
end

local function Label(entry)
	local fs = labels[entry.bag]
	if fs then return fs end
	local button = _G[entry.name]
	if type(button) ~= "table" or type(button.CreateFontString) ~= "function" then return nil end
	fs = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	if not fs then return nil end
	fs:SetDrawLayer("OVERLAY", 7)   -- 열린 가방 강조(6)·검색 어둡게(5)보다 위
	Place(fs)
	labels[entry.bag] = fs
	return fs
end

-- 남은 칸, 전체 칸. 가방이 없거나 값을 못 읽으면 nil
local function Counts(bag)
	local C = C_Container
	if type(C) ~= "table" or type(C.GetContainerNumSlots) ~= "function" or type(C.GetContainerNumFreeSlots) ~= "function" then
		return nil
	end
	local total = Clean(C.GetContainerNumSlots(bag))
	local free = Clean((C.GetContainerNumFreeSlots(bag)))
	if type(total) ~= "number" or type(free) ~= "number" or total <= 0 then return nil end
	return free, total
end

local function SetFreeSlotsHidden(hide)
	if hide == freeHidden then return end
	local button = MainMenuBarBackpackButton
	local fs = type(button) == "table" and button.FreeSlots
	if type(fs) ~= "table" or type(fs.SetAlpha) ~= "function" then return end
	fs:SetAlpha(hide and 0 or 1)
	freeHidden = hide
end

local function Refresh()
	if not db then return end
	local on = db.enabled
	for _, entry in ipairs(BAGS) do
		local fs
		if on then fs = Label(entry) else fs = labels[entry.bag] end
		if fs then
			local free, total
			if on then free, total = Counts(entry.bag) end
			if free then
				fs:SetText(("%d/%d"):format(db.count == "free" and free or total - free, total))
				if free == 0 and db.fullRed then fs:SetTextColor(1, 0.25, 0.25) else fs:SetTextColor(1, 1, 1) end
				fs:Show()
			else
				fs:SetText("")
				fs:Hide()
			end
		end
	end
	SetFreeSlotsHidden(on and db.position == "bottom")
end

-- 가방을 옮길 땐 이벤트가 몰려 와서 다음 프레임에 한 번만 센다 (블리자드 배낭 "(N)"도 같은 이유로 한 프레임 늦춤)
local queued = false
local function Flush()
	queued = false
	Refresh()
end

local function Queue()
	if queued or not (db and db.enabled) then return end
	queued = true
	C_Timer.After(0, Flush)
end

ns:RegisterEvent("BAG_UPDATE", function(_, bag)
	if WATCHED[bag] then Queue() end
end)
for _, event in ipairs({ "BAG_UPDATE_DELAYED", "BAG_CONTAINER_UPDATE", "PLAYER_EQUIPMENT_CHANGED", "PLAYER_ENTERING_WORLD" }) do
	ns:RegisterEvent(event, Queue)
end

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
end

function M:OnLogin()
	Refresh()
end

function M:ApplySettings()
	for _, fs in pairs(labels) do Place(fs) end
	Refresh()
end

function M:BuildOptions(b)
	b:Text("가방 막대의 배낭·가방 칸마다 칸 수를 적습니다. 기본은 찬 칸/전체라서, 8칸 가방에 1개가 들어 있으면 1/8입니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Dropdown{ key = "count", label = "숫자", depends = "enabled", width = 240,
		options = function() return COUNTS end }
	b:Dropdown{ key = "position", label = "글자 위치", depends = "enabled", width = 240,
		options = function() return POSITIONS end,
		tooltip = "아래로 두면 배낭의 전체 빈칸 (N) 자리에 적고 그 (N)은 가립니다. 전체 빈칸은 배낭에 마우스를 올리면 툴팁에 나옵니다. "
			.. "배낭의 탄약 수처럼 오른쪽 아래에 숫자가 있으면 글자가 겹칩니다." }
	b:Check{ key = "fullRed", label = "가득 차면 빨간색", depends = "enabled" }

	b:Text("- 가방이 없는 칸에는 적지 않습니다. 열쇠고리는 표시하지 않습니다.\n"
		.. "- 화살통·탄약 주머니도 그 가방의 칸 수를 그대로 셉니다. 그래서 빈칸을 더한 값이 배낭의 전체 빈칸 (N)과 다를 수 있습니다.\n"
		.. "- 아래에 두면 배낭의 탄약 수처럼 오른쪽 아래에 숫자가 있는 칸에서는 글자가 겹칩니다. 그래서 기본은 위입니다.\n"
		.. "- [사용], [숫자], [글자 위치], [가득 차면 빨간색]은 [저장]을 눌러야 적용됩니다.",
		{ color = { 0.7, 0.7, 0.7 } })
end
