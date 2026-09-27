-- UI 다시 불러오기 버튼: 화면 구석의 작은 버튼으로 /reload 한다.
--
-- 포에버에서는 ReloadUI()가 보호된 함수라 애드온 코드로는 부를 수 없다.
-- 보안 버튼(EzyWOWFReloadButton)에 "/reload" 매크로를 넣어, 사용자가 누를 때 블리자드 명령이 실행되게 한다.
-- 실수로 누르지 않게 기본은 Shift+클릭에만 동작한다.

local _, ns = ...
local Print = ns.Print

local BUTTON_SIZE = 20
local CORNER_INSET = 2
local ICON = "Interface\\Buttons\\UI-RefreshButton"
local CORNERS = {
	{ text = "왼쪽 위",     point = "TOPLEFT",     x = CORNER_INSET,  y = -CORNER_INSET },
	{ text = "오른쪽 위",   point = "TOPRIGHT",    x = -CORNER_INSET, y = -CORNER_INSET },
	{ text = "왼쪽 아래",   point = "BOTTOMLEFT",  x = CORNER_INSET,  y = CORNER_INSET },
	{ text = "오른쪽 아래", point = "BOTTOMRIGHT", x = -CORNER_INSET, y = CORNER_INSET },
}

local M = ns:NewModule("ReloadButton", {
	title = "UI 다시 불러오기 버튼",
	category = "general",
	icon = "Interface\\Icons\\INV_Misc_Rune_01",
	order = 10,
	defaults = {
		enabled = true,
		requireShift = true,
		point = CORNERS[1].point, relPoint = CORNERS[1].point, x = CORNERS[1].x, y = CORNERS[1].y,
	},
})

local db
local moveMode = false
local pendingAfterCombat = false

local button = CreateFrame("Button", "EzyWOWFReloadButton", UIParent, "SecureActionButtonTemplate")
button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
button:SetFrameStrata("MEDIUM")
button:SetMovable(true)
button:SetClampedToScreen(true)
if button.SetDontSavePosition then button:SetDontSavePosition(true) end
button:RegisterForClicks("AnyUp", "AnyDown")
button:RegisterForDrag("LeftButton")
button:Hide()

local bg = button:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetColorTexture(0, 0, 0, 0.6)

local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetPoint("TOPLEFT", 2, -2)
icon:SetPoint("BOTTOMRIGHT", -2, 2)
icon:SetTexture(ICON)

button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

local moveTint = button:CreateTexture(nil, "OVERLAY")
moveTint:SetAllPoints()
moveTint:SetColorTexture(0, 1, 0, 0.4)
moveTint:Hide()

---------------------------------------------------------------------------
-- 적용 (보안 버튼이라 전투 중에는 바꿀 수 없음)
---------------------------------------------------------------------------
local function Update()
	if not db then return end
	if InCombatLockdown() then
		pendingAfterCombat = true
		return
	end
	pendingAfterCombat = false

	-- 이동 모드에서는 눌러도 아무 일도 없게 한다.
	local active = db.enabled and not moveMode
	local plain = active and not db.requireShift
	button:SetAttribute("*type1", plain and "macro" or nil)
	button:SetAttribute("*macrotext1", plain and "/reload" or nil)
	button:SetAttribute("shift-type1", active and "macro" or nil)
	button:SetAttribute("shift-macrotext1", active and "/reload" or nil)

	button:ClearAllPoints()
	button:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
	button:SetShown(db.enabled)
	moveTint:SetShown(moveMode)
end

local function SetMoveMode(on)
	if InCombatLockdown() then
		Print("전투 중에는 할 수 없어요.")
		return
	end
	if on and not db.enabled then
		Print("UI 다시 불러오기 버튼이 꺼져 있어요.")
		return
	end
	moveMode = on
	Update()
	ns:Fire("REFRESH_UI")
	if on then Print("UI 다시 불러오기 버튼을 드래그해서 옮기세요. 다 옮기면 [이동 완료]를 누르세요.") end
end

local function MoveToCorner(corner)
	if InCombatLockdown() then
		Print("전투 중에는 할 수 없어요.")
		return
	end
	db.point, db.relPoint, db.x, db.y = corner.point, corner.point, corner.x, corner.y
	Update()
end

---------------------------------------------------------------------------
-- 버튼 스크립트
---------------------------------------------------------------------------
button:SetScript("PostClick", function(_, mouseButton, down)
	if down or moveMode or mouseButton ~= "LeftButton" then return end
	if db.requireShift and not IsShiftKeyDown() then
		Print("실수 방지: Shift를 누른 채 클릭해야 UI를 다시 불러옵니다.")
	end
end)

button:SetScript("OnDragStart", function(self)
	if moveMode and not InCombatLockdown() then self:StartMoving() end
end)

button:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, relPoint, x, y = self:GetPoint(1)
	db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end)

button:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
	GameTooltip:SetText("UI 다시 불러오기", 1, 0.82, 0)
	GameTooltip:AddLine((db.requireShift and "Shift+클릭" or "클릭") .. ": /reload", 1, 1, 1)
	if moveMode then GameTooltip:AddLine("드래그해서 이동", 0.3, 1, 0.3) end
	GameTooltip:Show()
end)

button:SetScript("OnLeave", GameTooltip_Hide)

ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
	if pendingAfterCombat then Update() end
end)

-- 전투 시작 직전(아직 보안 프레임을 바꿀 수 있을 때) 이동 모드를 끈다.
ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
	if moveMode then
		button:StopMovingOrSizing()
		moveMode = false
		Update()
		ns:Fire("REFRESH_UI")
	end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	Update()
end

function M:ApplySettings(changes)
	if changes.enabled == false then moveMode = false end
	Update()
end

function M:BuildOptions(b)
	local function Disabled() return not db.enabled end

	b:Text("화면 구석에 작은 UI 다시 불러오기(/reload) 버튼을 둡니다. "
		.. "실수로 누르지 않게 기본은 Shift를 누른 채 클릭해야 동작합니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Check{ key = "requireShift", label = "Shift를 누른 채 클릭해야 동작", depends = "enabled", indent = 20 }

	local corners = {}
	for _, corner in ipairs(CORNERS) do
		corners[#corners + 1] = {
			text = corner.text, width = 100, disabled = Disabled,
			onClick = function() MoveToCorner(corner) end,
		}
	end
	b:Buttons(corners)
	b:Buttons{
		{
			text = "위치 이동",
			textFunc = function() return moveMode and "이동 완료" or "위치 이동" end,
			onClick = function() SetMoveMode(not moveMode) end,
			disabled = Disabled,
			tooltip = "구석이 아닌 곳에 두고 싶을 때 드래그해서 옮깁니다. 바로 적용됩니다.",
		},
	}
end
