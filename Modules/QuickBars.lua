-- 행동·징표 단축바: 자주 쓰는 감정 표현(앉기, 인사 등)과 대상 징표(해골, 네모, 엑스 등)를 작은 단축바 두 개로 모은다.
--
-- 두 단축바 모두 보안 버튼에 채팅 명령을 넣는다. 채팅창에 직접 치는 것과 똑같이 동작하고 전투 중에도 된다.
--   감정 표현: C_ChatInfo.PerformEmote는 제약(HasRestrictions)이 있어서 쓰지 않고, "/앉기" 같은 명령을 쓴다.
--             명령은 게임의 감정 표현 목록(EMOTE숫자_TOKEN / _CMD1)에서 찾아 이 클라이언트 언어에 맞춘다.
--   징표: "/tm 번호" (0 = 지우기). 지금 대상에 붙이고, 같은 징표를 한 번 더 누르면 떼어진다.
-- 보안 버튼이 들어 있는 단축바는 전투 중에 옮기거나 숨길 수 없어서 전투가 끝난 뒤에 맞춘다.

local _, ns = ...
local Print = ns.Print

local M = ns:NewModule("QuickBars", {
	title = "행동·징표 단축바",
	category = "interface",
	icon = "Interface\\Icons\\INV_Misc_Gem_Variety_01",
	order = 60,
	defaults = {
		emoteShow = true,
		emoteScale = 0.9,
		emotePoint = "CENTER", emoteRelPoint = "CENTER", emoteX = -260, emoteY = -180,
		markerShow = true,
		markerScale = 0.9,
		markerPoint = "CENTER", markerRelPoint = "CENTER", markerX = -260, markerY = -150,
	},
})

local GAP = 2

local EMOTES = {
	{ token = "SIT",     label = "앉기" },
	{ token = "STAND",   label = "서기" },
	{ token = "WAVE",    label = "인사" },
	{ token = "BOW",     label = "절" },
	{ token = "THANK",   label = "감사" },
	{ token = "CHEER",   label = "환호" },
	{ token = "APPLAUD", label = "박수" },
	{ token = "DANCE",   label = "춤" },
}

local MARKER_ORDER = { 8, 7, 6, 5, 4, 3, 2, 1 }   -- 해골, 엑스, 네모, 달, 세모, 다이아몬드, 동그라미, 별
local MARKER_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_%d"
local CLEAR_ICON = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"

local db
local moveMode = false
local pendingAfterCombat = false

-- 감정 표현 명령: 이 클라이언트 언어의 첫 번째 명령. 못 찾으면 영어 명령.
local function EmoteCommand(token)
	for i = 1, tonumber(MAXEMOTEINDEX) or 1000 do
		if _G["EMOTE" .. i .. "_TOKEN"] == token then
			local cmd = _G["EMOTE" .. i .. "_CMD1"]
			if type(cmd) == "string" then return cmd end
		end
	end
	return "/" .. token:lower()
end

local function MarkerCommand()
	return type(SLASH_TARGET_MARKER1) == "string" and SLASH_TARGET_MARKER1 or "/tm"
end

---------------------------------------------------------------------------
-- 단축바 만들기
---------------------------------------------------------------------------
local function ShowTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText(self.tipTitle, 1, 1, 1)
	if self.tipText then GameTooltip:AddLine(self.tipText, 0.7, 0.7, 0.7) end
	GameTooltip:Show()
end

local function NewButton(bar, width, height, macro, title, text)
	local btn = CreateFrame("Button", nil, bar, "SecureActionButtonTemplate")
	btn:SetSize(width, height)
	btn:RegisterForClicks("AnyUp", "AnyDown")
	btn:SetAttribute("*type1", "macro")
	btn:SetAttribute("*macrotext1", macro)

	local bg = btn:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.6)
	btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	btn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")

	btn.tipTitle, btn.tipText = title, text
	btn:SetScript("OnEnter", ShowTooltip)
	btn:SetScript("OnLeave", GameTooltip_Hide)
	return btn
end

local function NewBar(name, label)
	local bar = CreateFrame("Frame", name, UIParent)
	bar:SetFrameStrata("MEDIUM")
	bar:SetMovable(true)
	bar:SetClampedToScreen(true)
	if bar.SetDontSavePosition then bar:SetDontSavePosition(true) end

	-- 이동 모드에서 막대 위를 덮어 드래그를 받는다. (그동안 버튼은 눌리지 않음)
	local mover = CreateFrame("Frame", nil, bar)
	mover:SetAllPoints()
	mover:SetFrameLevel(bar:GetFrameLevel() + 20)
	mover:EnableMouse(true)
	mover:RegisterForDrag("LeftButton")
	mover:Hide()
	local tint = mover:CreateTexture(nil, "OVERLAY")
	tint:SetAllPoints()
	tint:SetColorTexture(0, 1, 0, 0.3)
	local text = mover:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	text:SetPoint("BOTTOM", mover, "TOP", 0, 2)
	text:SetText(label)
	bar.mover = mover
	return bar
end

local function Layout(bar, buttons)
	local x = 0
	for _, btn in ipairs(buttons) do
		btn:SetPoint("LEFT", bar, "LEFT", x, 0)
		x = x + btn:GetWidth() + GAP
	end
	bar:SetSize(math.max(x - GAP, 1), buttons[1]:GetHeight())
end

-- 행동 단축바
local emoteBar = NewBar("EzyWOWFEmoteBar", "행동 단축바")
local emoteButtons = {}
for _, e in ipairs(EMOTES) do
	local cmd = EmoteCommand(e.token)
	local btn = NewButton(emoteBar, 30, 20, cmd, e.label, cmd .. "  (대상이 있으면 대상에게)")
	local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("CENTER")
	fs:SetText(e.label)
	emoteButtons[#emoteButtons + 1] = btn
end
Layout(emoteBar, emoteButtons)

-- 징표 단축바
local markerBar = NewBar("EzyWOWFMarkerBar", "징표 단축바")
local markerButtons = {}
for _, index in ipairs(MARKER_ORDER) do
	local name = _G["RAID_TARGET_" .. index]
	if type(name) ~= "string" then name = "징표 " .. index end
	local btn = NewButton(markerBar, 20, 20, ("%s %d"):format(MarkerCommand(), index), name,
		"지금 대상에 붙입니다. 한 번 더 누르면 뗍니다.")
	local icon = btn:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("TOPLEFT", 2, -2)
	icon:SetPoint("BOTTOMRIGHT", -2, 2)
	icon:SetTexture(MARKER_ICON:format(index))
	markerButtons[#markerButtons + 1] = btn
end
do
	local btn = NewButton(markerBar, 20, 20, MarkerCommand() .. " 0", "징표 지우기", "지금 대상의 징표를 뗍니다.")
	local icon = btn:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("TOPLEFT", 2, -2)
	icon:SetPoint("BOTTOMRIGHT", -2, 2)
	icon:SetTexture(CLEAR_ICON)
	markerButtons[#markerButtons + 1] = btn
end
Layout(markerBar, markerButtons)

local BARS = {
	{ bar = emoteBar, prefix = "emote" },
	{ bar = markerBar, prefix = "marker" },
}

---------------------------------------------------------------------------
-- 위치·표시 (보안 버튼이 있어 전투 중에는 바꿀 수 없음)
---------------------------------------------------------------------------
local function Apply()
	if not db then return end
	if InCombatLockdown() then
		pendingAfterCombat = true
		return
	end
	pendingAfterCombat = false
	for _, info in ipairs(BARS) do
		local bar, p = info.bar, info.prefix
		bar:ClearAllPoints()
		bar:SetPoint(db[p .. "Point"], UIParent, db[p .. "RelPoint"], db[p .. "X"], db[p .. "Y"])
		bar:SetScale(db[p .. "Scale"])
		bar:SetShown(db[p .. "Show"])
		bar.mover:SetShown(moveMode)
	end
end

for _, info in ipairs(BARS) do
	local bar, p = info.bar, info.prefix
	bar.mover:SetScript("OnDragStart", function() bar:StartMoving() end)
	bar.mover:SetScript("OnDragStop", function()
		bar:StopMovingOrSizing()
		local point, _, relPoint, x, y = bar:GetPoint(1)
		db[p .. "Point"], db[p .. "RelPoint"], db[p .. "X"], db[p .. "Y"] = point, relPoint, x, y
	end)
end

local function SetMoveMode(on)
	if InCombatLockdown() then
		Print("전투 중에는 할 수 없어요.")
		return
	end
	moveMode = on
	Apply()
	ns:Fire("REFRESH_UI")
	if on then Print("초록색 단축바를 드래그해서 옮기세요. 다 옮기면 [이동 완료]를 누르세요.") end
end

local function ResetPositions()
	if InCombatLockdown() then
		Print("전투 중에는 할 수 없어요.")
		return
	end
	for _, info in ipairs(BARS) do
		local p = info.prefix
		for _, field in ipairs({ "Point", "RelPoint", "X", "Y" }) do
			db[p .. field] = M.defaults[p .. field]
		end
	end
	Apply()
end

ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
	if pendingAfterCombat then Apply() end
end)

-- 전투 시작 직전(아직 보안 프레임을 바꿀 수 있을 때) 이동 모드를 끈다.
ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
	if moveMode then
		moveMode = false
		Apply()
		ns:Fire("REFRESH_UI")
	end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	Apply()
end

function M:ApplySettings()
	Apply()
end

function M:BuildOptions(b)
	b:Header("행동 단축바")
	b:Text("앉기, 서기, 인사, 절, 감사, 환호, 박수, 춤을 한 번에 누를 수 있는 작은 단축바입니다. 대상이 있으면 대상에게 합니다.")
	b:Check{ key = "emoteShow", label = "행동 단축바 표시" }
	b:Slider{ key = "emoteScale", label = "크기", min = 0.5, max = 1.5, step = 0.05, format = "%.2f", depends = "emoteShow" }

	b:Header("징표 단축바")
	b:Text("해골, 엑스, 네모, 달, 세모, 다이아몬드, 동그라미, 별 징표를 지금 대상에 붙입니다. "
		.. "같은 징표를 한 번 더 누르면 떼고, 맨 끝 X는 징표를 지웁니다. (파티에서는 파티장·부파티장만 붙일 수 있어요)")
	b:Check{ key = "markerShow", label = "징표 단축바 표시" }
	b:Slider{ key = "markerScale", label = "크기", min = 0.5, max = 1.5, step = 0.05, format = "%.2f", depends = "markerShow" }

	b:Header("위치")
	b:Buttons{
		{
			text = "위치 이동",
			textFunc = function() return moveMode and "이동 완료" or "위치 이동" end,
			onClick = function() SetMoveMode(not moveMode) end,
			tooltip = "두 단축바를 드래그해서 옮길 수 있게 합니다. 바로 적용됩니다.",
		},
		{ text = "기본 위치로", onClick = ResetPositions },
	}
end
