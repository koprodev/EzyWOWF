-- 정보 막대: 좌표 / FPS / 지연시간 / 내구도를 작은 막대 하나에 보여 준다.
-- 기본 위치는 미니맵 아래이고, [위치 이동]으로 옮길 수 있다.

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local M = ns:NewModule("InfoBar", {
	title = "정보 막대",
	category = "info",
	icon = "Interface\\Icons\\INV_Misc_PocketWatch_01",
	order = 10,
	defaults = {
		enabled = true,
		showCoords = true,
		showFPS = true,
		showLatency = true,
		showDurability = true,
		showMoney = true,
		scale = 1,
		underMinimap = true,
		point = "CENTER", relPoint = "CENTER", x = 0, y = 0,
	},
})

local UPDATE_INTERVAL = 0.25

local db
local moveMode = false

local bar = CreateFrame("Frame", "EzyWOWFInfoBar", UIParent, "BackdropTemplate")
bar:SetSize(120, 20)
bar:SetFrameStrata("MEDIUM")
bar:SetClampedToScreen(true)
bar:SetMovable(true)
bar:EnableMouse(false)
bar:RegisterForDrag("LeftButton")
bar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
bar:SetBackdropColor(0, 0, 0, 0.45)
bar:Hide()

local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
text:SetPoint("CENTER")

local moveTint = bar:CreateTexture(nil, "OVERLAY")
moveTint:SetAllPoints()
moveTint:SetColorTexture(0, 1, 0, 0.3)
moveTint:Hide()

---------------------------------------------------------------------------
-- 내용
---------------------------------------------------------------------------
local function Colored(value, good, okay, lowerIsBetter)
	local isGood, isOkay
	if lowerIsBetter then
		isGood, isOkay = value < good, value < okay
	else
		isGood, isOkay = value >= good, value >= okay
	end
	if isGood then return "|cff33ff33" end
	if isOkay then return "|cffffff33" end
	return "|cffff4444"
end

local function PlayerCoords()
	local mapID = C_Map.GetBestMapForUnit("player")
	if not mapID then return nil end
	local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
	if not ok or not pos then return nil end
	local x, y = Clean(pos.x), Clean(pos.y)
	if not x or not y or (x == 0 and y == 0) then return nil end
	return x * 100, y * 100
end

-- 다른 모듈이 막대 끝에 붙이는 조각: { text = fn() → 글자|nil, tooltip = fn(GameTooltip), click = fn() }
-- text는 0.25초마다 불리니 미리 만들어 둔 글자를 돌려줄 것. 툴팁·클릭이 있는 조각이 보일 때만 막대가 마우스를 받는다.
local extras = {}
local hoverPart, mouseOn = nil, false
function ns.AddInfoBarPart(part)
	extras[#extras + 1] = part
end

-- 0.25초마다 도는 곳이라 조각 표 하나를 계속 돌려 쓴다.
local parts, partCount = {}, 0
local function Add(s)
	partCount = partCount + 1
	parts[partCount] = s
end

-- 골드 글자는 동전 수가 바뀔 때만 새로 만든다. 색맹 모드(CVar)도 모양을 바꾸니 CVar·로딩 때 잊는다.
local moneyCopper, moneyText
local function ForgetMoneyText() moneyText = nil end
for _, event in ipairs({ "CVAR_UPDATE", "PLAYER_ENTERING_WORLD", "VARIABLES_LOADED" }) do
	ns:RegisterEvent(event, ForgetMoneyText)
end

local function BuildText()
	local previous = partCount
	partCount = 0
	if db.showCoords then
		local x, y = PlayerCoords()
		Add(x and ("%.1f, %.1f"):format(x, y) or "|cff808080좌표 없음|r")
	end
	if db.showFPS then
		local fps = math.floor(GetFramerate() + 0.5)
		Add(Colored(fps, 50, 25) .. fps .. "|r fps")
	end
	if db.showLatency then
		local _, _, home, world = GetNetStats()
		local ms = math.max(home or 0, world or 0)
		Add(Colored(ms, 100, 250, true) .. ms .. "|r ms")
	end
	if db.showDurability then
		local pct = ns.GetLowestDurability()
		if pct then
			Add("내구도 " .. Colored(pct, 50, 25) .. math.floor(pct) .. "%|r")
		end
	end
	if db.showMoney then
		local money = Clean(GetMoney())
		-- GetMoneyString: 금·은·동 아이콘이 붙은 형태 (천 단위 쉼표)
		if money then
			if money ~= moneyCopper or not moneyText then
				moneyCopper, moneyText = money, "|cffffffff" .. ns.FormatMoney(money) .. "|r"
			end
			Add(moneyText)
		end
	end
	hoverPart = nil
	for i = 1, #extras do
		local part = extras[i]
		local s = part.text()
		if s then
			Add(s)
			if not hoverPart and (part.tooltip or part.click) then hoverPart = part end
		end
	end
	for i = partCount + 1, previous do parts[i] = nil end
	return table.concat(parts, "   ", 1, partCount)
end

-- 마지막으로 넣은 글자와 폭. text:SetText·bar:SetWidth를 다른 데서 부르면 이 둘도 같이 비울 것.
local shownText, shownWidth
local elapsedSince = UPDATE_INTERVAL
bar:SetScript("OnUpdate", function(_, elapsed)
	elapsedSince = elapsedSince + elapsed
	if elapsedSince < UPDATE_INTERVAL then return end
	elapsedSince = 0
	local content = BuildText()
	if content == "" then content = "|cff808080정보 막대|r" end
	if content ~= shownText then
		text:SetText(content)
		shownText = content
	end
	-- 글자가 그대로여도 글꼴 크기가 바뀌면 폭이 달라지니 폭은 매번 잰다.
	local width = text:GetStringWidth() + 16
	if width ~= shownWidth then
		bar:SetWidth(width)
		shownWidth = width
	end
	local wantMouse = moveMode or hoverPart ~= nil
	if wantMouse ~= mouseOn then
		mouseOn = wantMouse
		bar:EnableMouse(wantMouse)
		if not wantMouse and GameTooltip:IsOwned(bar) then GameTooltip:Hide() end
	end
end)

bar:SetScript("OnEnter", function(self)
	if moveMode or not (hoverPart and hoverPart.tooltip) then return end
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
	hoverPart.tooltip(GameTooltip)
	GameTooltip:Show()
end)
bar:SetScript("OnLeave", GameTooltip_Hide)
bar:SetScript("OnMouseUp", function(_, button)
	if moveMode or button ~= "LeftButton" or not (hoverPart and hoverPart.click) then return end
	hoverPart.click()
end)

---------------------------------------------------------------------------
-- 위치
---------------------------------------------------------------------------
local function ApplyPosition()
	bar:SetScale(db.scale)
	bar:ClearAllPoints()
	if db.underMinimap then
		-- 둥근 미니맵은 테두리가 지도보다 14픽셀쯤 아래로 나와 있다.
		-- 네모 미니맵 밑에 추적 아이콘이 붙어 있으면 그 아래로 비켜 선다.
		local square = ns.IsMinimapSquare and ns.IsMinimapSquare()
		local y = square and -3 or -14
		if square and ns.MinimapBelowPixels then
			y = y - ns.MinimapBelowPixels() / bar:GetEffectiveScale()
		end
		bar:SetPoint("TOP", Minimap, "BOTTOM", 0, y)
	else
		bar:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
	end
end

local function UpdateVisibility()
	bar:SetShown(db.enabled)
	-- 숨어 있는 동안 글꼴이 바뀌었을 수도 있으니, 다시 켜지면 글자·폭을 처음부터 넣는다.
	if not db.enabled then shownText, shownWidth = nil, nil end
	bar:EnableMouse(moveMode)
	mouseOn = moveMode
	moveTint:SetShown(moveMode)
end

local function SetMoveMode(on)
	if on and not db.enabled then
		Print("정보 막대가 꺼져 있어요.")
		return
	end
	moveMode = on
	UpdateVisibility()
	if on then Print("정보 막대를 드래그해서 옮기세요. 다 옮기면 [이동 완료]를 누르세요.") end
end

bar:SetScript("OnDragStart", function(self)
	if moveMode then self:StartMoving() end
end)

bar:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, relPoint, x, y = self:GetPoint(1)
	db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
	db.underMinimap = false
end)

ns:On("MINIMAP_LAYOUT_CHANGED", function()
	if db then ApplyPosition() end
end)
ns:On("MINIMAP_BELOW_CHANGED", function()
	if db then ApplyPosition() end
end)

local function ResetPosition()
	db.underMinimap = true
	ApplyPosition()
	Print("정보 막대를 미니맵 아래로 되돌렸습니다.")
end

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	ApplyPosition()
	UpdateVisibility()
end

function M:ApplySettings(changes)
	if changes.enabled == false then moveMode = false end
	ApplyPosition()
	UpdateVisibility()
end

function M:BuildOptions(b)
	local function Disabled() return not db.enabled end

	b:Text("미니맵 아래에 내 좌표, FPS, 지연시간, 장비 내구도, 소지 골드를 작게 보여 줍니다. "
		.. "시간당 경험치는 화면 정보 > 경험치 통계에서 켜고 끕니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Check{ key = "showCoords", label = "좌표", depends = "enabled", indent = 20 }
	b:Check{ key = "showFPS", label = "FPS (초당 프레임)", depends = "enabled", indent = 20 }
	b:Check{ key = "showLatency", label = "지연시간 (ms)", depends = "enabled", indent = 20 }
	b:Check{ key = "showDurability", label = "가장 낮은 장비 내구도", depends = "enabled", indent = 20 }
	b:Check{ key = "showMoney", label = "소지 골드", depends = "enabled", indent = 20 }
	b:Slider{ key = "scale", label = "크기", min = 0.6, max = 2, step = 0.05, format = "%.2f", depends = "enabled" }
	b:Buttons{
		{
			text = "위치 이동",
			textFunc = function() return moveMode and "이동 완료" or "위치 이동" end,
			onClick = function() SetMoveMode(not moveMode) end,
			disabled = Disabled,
		},
		{ text = "미니맵 아래로", onClick = ResetPosition, disabled = Disabled },
	}
end
