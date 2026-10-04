-- 행동·징표 단축바: 자주 쓰는 감정 표현(앉기, 인사 등)과 대상 징표(해골, 네모, 엑스 등)를 작은 단축바 두 개로 모은다.
--
-- 두 단축바 모두 보안 버튼에 채팅 명령을 넣는다. 채팅창에 직접 치는 것과 똑같이 동작하고 전투 중에도 된다.
--   감정 표현: C_ChatInfo.PerformEmote는 제약(HasRestrictions)이 있어서 쓰지 않고, "/앉기" 같은 명령을 쓴다.
--             명령은 게임의 감정 표현 목록(EMOTE숫자_TOKEN / _CMDn)에서 찾아 이 클라이언트 언어에 맞춘다.
--             분류마다 단축바 한 줄. 체크한 버튼이 없는 분류는 줄째로 빠진다.
--   징표: "/tm 번호" (0 = 지우기). 지금 대상에 붙이고, 같은 징표를 한 번 더 누르면 떼어진다.
-- 버튼마다 보이기 설정(emote_토큰 / marker_번호)이 있고, 보이는 버튼만 빈틈없이 붙여 놓는다.
-- 보안 버튼이 들어 있는 단축바는 전투 중에 옮기거나 숨길 수 없어서 전투가 끝난 뒤에 맞춘다.

local _, ns = ...
local Print = ns.Print

-- on = 처음부터 보이는 버튼 (예전부터 있던 8개). 글자와 같은 명령이 없으면 그 감정 표현의 첫 명령을 쓴다.
--   웃음 → /하하, 슬픔 → /낙심, 삐짐 → /삐죽, 도리 → /아니, 눕기 → /드러누워 (한국어판에 글자 그대로의 명령이 없음)
--   인사 = 손 흔들기(/손인사), 절 = 허리 숙이기(한국어판 /인사)
local EMOTE_GROUPS = {
	{ label = "기본", emotes = {
		{ token = "WAVE",      label = "인사", on = true },
		{ token = "HELLO",     label = "안녕" },
		{ token = "WELCOME",   label = "환영" },
		{ token = "BYE",       label = "작별" },
		{ token = "LAUGH",     label = "웃음" },
		{ token = "SMILE",     label = "미소" },
		{ token = "WINK",      label = "윙크" },
	} },
	{ label = "태도·반응", emotes = {
		{ token = "CHEER",     label = "환호", on = true },
		{ token = "APPLAUD",   label = "박수", on = true },
		{ token = "ANGRY",     label = "화남" },
		{ token = "SAD",       label = "슬픔" },
		{ token = "CRY",       label = "엉엉" },
		{ token = "POUT",      label = "삐짐" },
		{ token = "NOD",       label = "끄덕" },
		{ token = "NO",        label = "도리" },
	} },
	{ label = "상호작용", emotes = {
		{ token = "THANK",     label = "감사", on = true },
		{ token = "APOLOGIZE", label = "사과" },
		{ token = "HUG",       label = "포옹" },
		{ token = "COMFORT",   label = "위로" },
		{ token = "KISS",      label = "뽀뽀" },
	} },
	{ label = "동작", emotes = {
		{ token = "DANCE",     label = "춤", on = true },
		{ token = "BOW",       label = "절", on = true },
		{ token = "SIT",       label = "앉기", on = true },
		{ token = "STAND",     label = "서기", on = true },
		{ token = "LAYDOWN",   label = "눕기" },
		{ token = "YAWN",      label = "하품" },   -- 기지개 대신 (한국어판에 기지개가 없음)
	} },
}

local MARKERS = { 8, 7, 6, 5, 4, 3, 2, 1, 0 }   -- 해골, 엑스, 네모, 달, 세모, 다이아몬드, 동그라미, 별, 0 = 지우기
local MARKER_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_%d"
local CLEAR_ICON = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"

local function EmoteKey(token) return "emote_" .. token end
local function MarkerKey(index) return "marker_" .. index end

-- 행동 단축바는 여러 줄이라 늘 위 끝(TOP 계열)을 붙여 아래로 자란다. (기본 = 한 줄 시절 기본 자리의 위 끝, 징표 단축바 아래)
local defaults = {
	emoteShow = true,
	emoteScale = 0.9,
	emotePoint = "TOP", emoteRelPoint = "CENTER", emoteX = -260, emoteY = -170,
	markerShow = true,
	markerScale = 0.9,
	markerPoint = "CENTER", markerRelPoint = "CENTER", markerX = -260, markerY = -150,
}
for _, group in ipairs(EMOTE_GROUPS) do
	for _, e in ipairs(group.emotes) do defaults[EmoteKey(e.token)] = e.on or false end
end
for _, index in ipairs(MARKERS) do defaults[MarkerKey(index)] = true end

local M = ns:NewModule("QuickBars", {
	title = "행동·징표 단축바",
	category = "interface",
	icon = "Interface\\Icons\\INV_Misc_Gem_Variety_01",
	order = 60,
	defaults = defaults,
})

local GAP = 2

local db
local moveMode = false
local pendingAfterCombat = false

-- [토큰] = 감정 표현 번호 (첫 명령이 있는 첫 번호). 600개 넘게 도니 한 번만 센다.
local emoteIndex
local function EmoteIndex(token)
	if not emoteIndex then
		emoteIndex = {}
		for i = 1, tonumber(MAXEMOTEINDEX) or 1000 do
			local t = _G["EMOTE" .. i .. "_TOKEN"]
			if type(t) == "string" and not emoteIndex[t] and type(_G["EMOTE" .. i .. "_CMD1"]) == "string" then
				emoteIndex[t] = i
			end
		end
	end
	return emoteIndex[token]
end

-- 감정 표현 명령: 버튼 글자와 같은 명령이 있으면 그것, 없으면 이 클라이언트 언어의 첫 명령, 그것도 없으면 영어 명령.
local function EmoteCommand(token, label)
	local i = EmoteIndex(token)
	if not i then return "/" .. token:lower() end
	local want = "/" .. label
	for k = 1, 10 do
		if _G["EMOTE" .. i .. "_CMD" .. k] == want then return want end
	end
	return _G["EMOTE" .. i .. "_CMD1"]
end

local function MarkerCommand()
	return type(SLASH_TARGET_MARKER1) == "string" and SLASH_TARGET_MARKER1 or "/tm"
end

local function MarkerName(index)
	if index == 0 then return "징표 지우기" end
	local name = _G["RAID_TARGET_" .. index]
	return type(name) == "string" and name or "징표 " .. index
end

local function MarkerIcon(index)
	return index == 0 and CLEAR_ICON or MARKER_ICON:format(index)
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

-- 보이기로 고른 버튼만 줄마다 왼쪽부터 빈틈없이 놓는다. 다 빠진 줄은 자리도 안 차지한다. 하나도 없으면 false.
local function Layout(bar, rows)
	local width, y = 0, 0
	for _, row in ipairs(rows) do
		local x, height = 0, 0
		for _, btn in ipairs(row) do
			local on = db[btn.settingKey] and true or false
			btn:SetShown(on)
			if on then
				btn:ClearAllPoints()
				btn:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -y)
				x = x + btn:GetWidth() + GAP
				height = math.max(height, btn:GetHeight())
			end
		end
		if x > 0 then
			width = math.max(width, x - GAP)
			y = y + height + GAP
		end
	end
	if y == 0 then return false end
	bar:SetSize(width, y - GAP)
	return true
end

-- 행동 단축바: 분류 하나 = 한 줄. 설정 창 체크박스도 분류마다 따로.
local emoteBar = NewBar("EzyWOWFEmoteBar", "행동 단축바")
local emoteRows, emoteGrids = {}, {}
for _, group in ipairs(EMOTE_GROUPS) do
	local row, items = {}, {}
	for _, e in ipairs(group.emotes) do
		local cmd = EmoteCommand(e.token, e.label)
		local btn = NewButton(emoteBar, 30, 20, cmd, e.label, cmd .. "  (대상이 있으면 대상에게)")
		local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("CENTER")
		fs:SetText(e.label)
		btn.settingKey = EmoteKey(e.token)
		row[#row + 1] = btn
		items[#items + 1] = { key = btn.settingKey, text = e.label, tooltip = cmd }
	end
	emoteRows[#emoteRows + 1] = row
	emoteGrids[#emoteGrids + 1] = { label = group.label, items = items }
end

-- 징표 단축바
local markerBar = NewBar("EzyWOWFMarkerBar", "징표 단축바")
local markerButtons, markerItems = {}, {}
for _, index in ipairs(MARKERS) do
	local name = MarkerName(index)
	local tip = index == 0 and "지금 대상의 징표를 뗍니다." or "지금 대상에 붙입니다. 한 번 더 누르면 뗍니다."
	local btn = NewButton(markerBar, 20, 20, ("%s %d"):format(MarkerCommand(), index), name, tip)
	local icon = btn:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("TOPLEFT", 2, -2)
	icon:SetPoint("BOTTOMRIGHT", -2, 2)
	icon:SetTexture(MarkerIcon(index))
	btn.settingKey = MarkerKey(index)
	markerButtons[#markerButtons + 1] = btn
	markerItems[#markerItems + 1] = { key = btn.settingKey, icon = MarkerIcon(index), title = name }
end

local BARS = {
	{ bar = emoteBar, prefix = "emote", rows = emoteRows, anchorTop = true },
	{ bar = markerBar, prefix = "marker", rows = { markerButtons } },
}

---------------------------------------------------------------------------
-- 위치·표시 (보안 버튼이 있어 전투 중에는 바꿀 수 없음)
---------------------------------------------------------------------------
-- 한 줄(높이 20) 시절에 저장된 자리를 위 끝 기준으로 바꾼다. 아래나 가운데를 붙인 채 여러 줄이 되면 위로 자라 징표 단축바를 덮는다.
-- 옛 위 끝을 그대로 두니 화면에서는 안 움직인다. 새 코드는 늘 TOP 계열로 저장해서, 적용할 때마다 돌아도 옛 자리(옛 설정 글자 포함)만 바뀐다.
local OLD_ROW_HEIGHT = 20
local TOP_OF = { BOTTOMLEFT = "TOPLEFT", BOTTOM = "TOP", BOTTOMRIGHT = "TOPRIGHT", LEFT = "TOPLEFT", CENTER = "TOP", RIGHT = "TOPRIGHT" }

local function AnchorEmoteBarTop()
	local point = db.emotePoint
	local top = TOP_OF[point]
	if not top then return end
	db.emotePoint = top
	db.emoteY = (tonumber(db.emoteY) or 0) + (point:find("^BOTTOM") and OLD_ROW_HEIGHT or OLD_ROW_HEIGHT / 2)
end

local function Apply()
	if not db then return end
	AnchorEmoteBarTop()
	if InCombatLockdown() then
		pendingAfterCombat = true
		return
	end
	pendingAfterCombat = false
	for _, info in ipairs(BARS) do
		local bar, p = info.bar, info.prefix
		local any = Layout(bar, info.rows)
		bar:ClearAllPoints()
		bar:SetPoint(db[p .. "Point"], UIParent, db[p .. "RelPoint"], db[p .. "X"], db[p .. "Y"])
		bar:SetScale(db[p .. "Scale"])
		bar:SetShown(db[p .. "Show"] and any)
		bar.mover:SetShown(moveMode)
	end
end

for _, info in ipairs(BARS) do
	local bar, p = info.bar, info.prefix
	bar.mover:SetScript("OnDragStart", function() bar:StartMoving() end)
	bar.mover:SetScript("OnDragStop", function()
		bar:StopMovingOrSizing()
		-- StopMovingOrSizing은 가까운 화면 점에 붙인다. 아래쪽이면 BOTTOM이라 줄이 늘면 위로 자라니, 놓은 자리의 위쪽 가운데로 다시 붙인다.
		-- GetLeft/GetTop과 SetPoint 거리는 둘 다 단축바 배율 기준이라 화면에서는 그대로다.
		local left, top, width = bar:GetLeft(), bar:GetTop(), bar:GetWidth()
		if info.anchorTop and left and top and width then
			bar:ClearAllPoints()
			bar:SetPoint("TOP", UIParent, "BOTTOMLEFT", left + width / 2, top)
		end
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
	b:Text("감정 표현을 한 번에 누를 수 있는 작은 단축바입니다. 대상이 있으면 대상에게 합니다. "
		.. "체크한 버튼만 나오고, 아래 분류마다 단축바 한 줄을 씁니다.")
	b:Check{ key = "emoteShow", label = "행동 단축바 표시" }
	for _, grid in ipairs(emoteGrids) do
		-- 칸 수를 맞춰 분류끼리 세로줄이 맞게
		b:CheckGrid{ label = grid.label, items = grid.items, columns = 8, depends = "emoteShow" }
	end
	b:Slider{ key = "emoteScale", label = "크기", min = 0.5, max = 1.5, step = 0.05, format = "%.2f", depends = "emoteShow" }

	b:Header("징표 단축바")
	b:Text("해골, 엑스, 네모, 달, 세모, 다이아몬드, 동그라미, 별 징표를 지금 대상에 붙입니다. "
		.. "같은 징표를 한 번 더 누르면 떼고, 맨 끝 X는 징표를 지웁니다. (파티에서는 파티장·부파티장만 붙일 수 있어요)")
	b:Check{ key = "markerShow", label = "징표 단축바 표시" }
	b:CheckGrid{ label = "보일 버튼", items = markerItems, depends = "markerShow" }
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
