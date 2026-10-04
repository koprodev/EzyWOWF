-- 메모: 계정 공용 메모장 하나. 지도 밑 메모 버튼, /메모, 단축키로 연다.
--
-- 글은 계정 저장 표(EzyWOWFDB.memo)에 있어서 같은 와우 계정의 모든 캐릭터가 같은 메모를 본다.
-- 다른 와우 계정은 저장 파일이 따로라 못 본다. 고칠 때마다 표에 넣고, 파일에는 접속 종료·/reload 때 적힌다.
-- 설정 내보내기(EZY1:)에는 안 들어간다. 글이니까 [모두 선택] 뒤 복사·붙여 넣기로 옮기면 된다.
--
-- 메모 버튼은 지도 밑 추적 아이콘 줄의 왼쪽 모서리에 같은 크기로 붙는다(ns.MinimapRowIconSize).
-- 추적 아이콘은 그 모서리를 비우고(ns.MinimapMemoWidth), 정보 막대는 버튼 밑으로 비켜 선다(ns.MinimapMemoBelow).
-- 메모 창은 처음엔 지도 왼쪽에 붙어서 열리고, 제목 줄을 끌어 옮기면 지도에서 떨어진다.

local _, ns = ...
local UI = ns.UI
local Theme = UI.Theme
local Print = ns.Print

local BINDING = "EZYWOWF_MEMO"
BINDING_NAME_EZYWOWF_MEMO = "메모 창 열기/닫기"

local ICON = "Interface\\Icons\\INV_Misc_Note_04"
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_Note_01"

-- 지도 밑 줄 (추적 아이콘 줄과 맞춘 값)
local BUTTON_SIZE = 30                 -- 추적 아이콘이 없을 때 크기 (추적 아이콘 기본 크기)
local CORNER_WIDTH = BUTTON_SIZE + 4   -- 추적 아이콘이 비워 둘 왼쪽 모서리 폭
local BELOW_GAP = 2                    -- 네모 지도: 지도와 버튼 사이
local ROUND_ROW_Y = -42                -- 둥근 지도: 테두리·정보 막대 밑 추적 아이콘 줄

-- 메모 창
local TITLE_H, FOOTER_H = 26, 28
local WINDOW_GAP = 6                   -- 지도에 붙은 창과 지도 사이
local DEFAULT_W, DEFAULT_H = 320, 260
local MIN_W, MIN_H, MAX_W, MAX_H = 220, 140, 900, 800
local PREVIEW_LINES = 6                -- 버튼 툴팁에 미리 보일 줄 수
local PREVIEW_BYTES = 90               -- 미리 보기 한 줄 길이 (바이트, 한글 30자쯤)
local FOLLOW_TRIES = 10                -- 커서 따라 굴리기를 기다려 줄 프레임 수

local M = ns:NewModule("Memo", {
	title = "메모",
	category = "general",
	icon = ICON,
	order = 25,
	bindings = { BINDING },
	defaults = {
		showButton = true,
		attached = true,
		point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = 0, y = 0,
		width = DEFAULT_W, height = DEFAULT_H,
	},
})

local db
local note            -- EzyWOWFDB.memo: { text, time, by }
local playerName
local window, panel, area, edit, placeholder, footer, grip, follow
local cursorY, cursorH = 0, 0
local followTries = 0

---------------------------------------------------------------------------
-- 메모 글
---------------------------------------------------------------------------
local function NoteText()
	return note and type(note.text) == "string" and note.text or ""
end

-- 게임에 보이는 이름 그대로 (포에버: "이름 성")
local function PlayerName()
	if not playerName then
		if NameUtil and NameUtil.GetUnmodifiedUnitFullName then
			local ok, name = pcall(NameUtil.GetUnmodifiedUnitFullName, "player")
			name = ok and ns.Clean(name)
			if type(name) == "string" and name ~= "" then playerName = name end
		end
		if not playerName then
			local name = ns.Clean(UnitName("player"))
			if type(name) == "string" and name ~= "" then playerName = name end
		end
	end
	return playerName
end

local function SaveText(text)
	note.text = text
	note.time = time()
	note.by = PlayerName()
end

local function Letters(text)
	return strlenutf8 and strlenutf8(text) or #text
end

local function StatusText()
	local text = NoteText()
	if text == "" then return "비어 있음" end
	local out = ("%d자"):format(Letters(text))
	if type(note.time) == "number" then
		out = out .. " · " .. date("%m/%d %H:%M", note.time)
		if type(note.by) == "string" and note.by ~= "" then out = out .. " (" .. note.by .. ")" end
	end
	return out
end

-- 한글을 바이트 중간에서 자르지 않게, 다음 바이트가 글자 첫 바이트인 곳까지 물러나서 자른다.
local function CutBytes(s, n)
	if #s <= n then return s end
	local i = n
	while i > 0 do
		local b = s:byte(i + 1)
		if b < 0x80 or b >= 0xC0 then break end
		i = i - 1
	end
	-- 반쯤 잘린 | 확장 문자가 뒤 글자를 먹지 않게 끝의 |는 버린다
	return (s:sub(1, i):gsub("|+$", "")) .. "…"
end

local function AddPreview(tooltip)
	local shown = 0
	for line in (NoteText() .. "\n"):gmatch("(.-)\n") do
		if line:find("%S") then
			if shown == PREVIEW_LINES then
				tooltip:AddLine("…", 0.6, 0.6, 0.6)
				break
			end
			tooltip:AddLine(CutBytes(line, PREVIEW_BYTES), 1, 1, 1)
			shown = shown + 1
		end
	end
	if shown == 0 then tooltip:AddLine("(비어 있음)", 0.6, 0.6, 0.6) end
end

---------------------------------------------------------------------------
-- 지도 밑 메모 버튼 (추적 아이콘과 같은 모양: 검은 테두리, 창이 열려 있으면 금색 테두리)
---------------------------------------------------------------------------
local button = CreateFrame("Button", "EzyWOWFMemoButton", Minimap)
button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(8)
button:RegisterForClicks("AnyUp")
button:Hide()

local edge = button:CreateTexture(nil, "BACKGROUND", nil, 0)
edge:SetAllPoints()
edge:SetColorTexture(0, 0, 0, 0.9)

local openBorder = button:CreateTexture(nil, "BACKGROUND", nil, 1)
openBorder:SetPoint("TOPLEFT", 1, -1)
openBorder:SetPoint("BOTTOMRIGHT", -1, 1)
openBorder:SetColorTexture(0.85, 0.65, 0.13, 1)
openBorder:Hide()

local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetPoint("TOPLEFT", 2, -2)
icon:SetPoint("BOTTOMRIGHT", -2, 2)
icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

button:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
button:GetPushedTexture():SetAllPoints(icon)
button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
button:GetHighlightTexture():SetAllPoints(icon)

local function IsOpen()
	return window ~= nil and window:IsShown()
end

local belowPixels = 0

-- 지도 밑 줄 왼쪽 모서리에서 메모 버튼이 차지하는 폭 (지도 크기 단위). 추적 아이콘은 양쪽을 이만큼 비운다.
function ns.MinimapMemoWidth()
	return (db and db.showButton) and CORNER_WIDTH or 0
end

-- 네모 지도 밑으로 메모 버튼이 내려온 높이 (화면 픽셀). 정보 막대는 추적 아이콘 줄과 둘 중 큰 쪽만큼 내려선다.
function ns.MinimapMemoBelow()
	return belowPixels
end

local function PlaceButton()
	if not db then return end
	local shown = db.showButton and true or false
	local square = ns.IsMinimapSquare and ns.IsMinimapSquare()
	local size = ns.MinimapRowIconSize and ns.MinimapRowIconSize() or BUTTON_SIZE
	button:SetSize(size, size)
	button:ClearAllPoints()
	button:SetPoint("TOPLEFT", Minimap, "BOTTOMLEFT", 0, square and -BELOW_GAP or ROUND_ROW_Y)
	button:SetShown(shown)
	openBorder:SetShown(IsOpen())

	local below = (shown and square) and (size + BELOW_GAP) * Minimap:GetEffectiveScale() or 0
	if math.abs(below - belowPixels) > 0.5 then
		belowPixels = below
		ns:Fire("MINIMAP_BELOW_CHANGED")
	end
end

---------------------------------------------------------------------------
-- 메모 창 자리와 크기
---------------------------------------------------------------------------
local function ClampSize(w, h)
	w = math.max(MIN_W, math.min(MAX_W, tonumber(w) or DEFAULT_W))
	h = math.max(MIN_H, math.min(MAX_H, tonumber(h) or DEFAULT_H))
	return math.floor(w + 0.5), math.floor(h + 0.5)
end

-- 크기 손잡이는 고정된 모서리의 맞은편에 둔다. 지도에 붙어 있으면 오른쪽 위가 고정이라 왼쪽 아래.
local function PlaceGrip()
	local left = db.attached and true or false
	grip.corner = left and "BOTTOMLEFT" or "BOTTOMRIGHT"
	grip:ClearAllPoints()
	grip:SetPoint(grip.corner, left and 2 or -2, 2)
	local l, r = 0, 1
	if left then l, r = 1, 0 end   -- 손잡이 그림은 오른쪽 아래용이라 좌우를 뒤집는다
	grip:GetNormalTexture():SetTexCoord(l, r, 0, 1)
	grip:GetPushedTexture():SetTexCoord(l, r, 0, 1)
	grip:GetHighlightTexture():SetTexCoord(l, r, 0, 1)
end

local function ApplyGeometry()
	if not (window and db) then return end
	window:SetSize(ClampSize(db.width, db.height))
	window:ClearAllPoints()
	if db.attached then
		local square = ns.IsMinimapSquare and ns.IsMinimapSquare()
		window:SetPoint("TOPRIGHT", Minimap, "BOTTOMLEFT", -WINDOW_GAP, square and -BELOW_GAP or ROUND_ROW_Y)
	else
		window:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
	end
	PlaceGrip()
end

-- 끌어 놓은 자리를 화면 왼쪽 아래 기준 왼쪽 위 모서리로 저장한다. 이제부터 지도와 따로 논다.
local function Detach()
	local left, top = window:GetLeft(), window:GetTop()
	if left and top then
		db.attached = false
		db.point, db.relPoint = "TOPLEFT", "BOTTOMLEFT"
		db.x, db.y = math.floor(left + 0.5), math.floor(top + 0.5)
	end
	ApplyGeometry()
	ns:Fire("REFRESH_UI")
end

local function Reattach()
	db.attached = true
	ApplyGeometry()
	ns:Fire("REFRESH_UI")
	Print("메모 창을 지도 옆에 다시 붙였습니다.")
end

local function StopSizing()
	if not (grip and grip.sizing) then return end
	grip.sizing = false
	window:StopMovingOrSizing()
	db.width, db.height = ClampSize(window:GetSize())
	ApplyGeometry()   -- 크기를 바꾸는 동안 게임이 바꿔 둔 기준점을 우리 것으로 되돌린다
end

---------------------------------------------------------------------------
-- 메모 창
---------------------------------------------------------------------------
-- 커서 줄이 보이는 곳 밖으로 나가면 그만큼 굴린다 (블리자드 ScrollingEdit_OnUpdate와 같은 생각).
-- 갈 수 있는 끝까지는 바로 가고, 줄이 막 늘어 범위가 아직 모자라면 다음 프레임에 마저 간다.
-- (한글 글꼴은 줄 간격이 있어 커서 아래 끝이 범위를 살짝 넘기도 한다. 그때는 끝에서 멈춘다)
local function FollowCursor()
	local view = area.scroll:GetHeight() or 0
	if view <= 0 then return false end
	local range = area.scroll:GetVerticalScrollRange() or 0
	area:SetContentHeight(range + view)
	local top = -cursorY
	local bottom = top + cursorH
	local offset = area.bar:GetValue()
	if top < offset then
		area:ScrollTo(top)
	elseif bottom > offset + view then
		area:ScrollTo(math.min(bottom - view, range))
		return bottom - view <= range + 0.5
	end
	return true
end

local function FollowStep(self)
	followTries = followTries + 1
	if FollowCursor() or followTries >= FOLLOW_TRIES then self:SetScript("OnUpdate", nil) end
end

local function ShowText(cursorAt)
	edit:SetText(NoteText())
	edit:SetCursorPosition(cursorAt == "end" and #NoteText() or 0)
end

-- 화면 글이 저장본과 다르면 저장한다. 한글 조합 확정처럼 userInput 표시 없이 바뀐 글도 놓치지 않게 글끼리 비교한다.
local function SaveFromEdit()
	local text = edit:GetText() or ""
	if text ~= NoteText() then SaveText(text) end
	return text
end

-- 쓰는 동안은 키보드가 메모에 묶여서 이동 키도 글자로 들어간다. 그동안은 빠져나가는 법을 보여 준다.
local function RefreshFooter()
	if edit:HasFocus() then
		footer:SetText(("%d자 · 쓰는 중 · Esc로 끝내기"):format(Letters(NoteText())))
	else
		footer:SetText(StatusText())
	end
end

local function CreateWindow()
	window = CreateFrame("Frame", "EzyWOWFMemoWindow", UIParent, "BackdropTemplate")
	window:SetFrameStrata("MEDIUM")
	window:SetToplevel(true)
	window:SetMovable(true)
	window:SetResizable(true)
	if window.SetResizeBounds then window:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H) end
	window:SetClampedToScreen(true)
	window:EnableMouse(true)
	if window.SetDontSavePosition then window:SetDontSavePosition(true) end
	UI.ApplyPanelBackdrop(window)
	window:Hide()
	tinsert(UISpecialFrames, "EzyWOWFMemoWindow")   -- Esc로 닫는다. 글 쓰는 중이면 첫 Esc는 입력만 끝낸다

	-- 제목 줄: 잡고 끌면 옮겨지고 지도에서 떨어진다
	local titleBar = CreateFrame("Frame", nil, window)
	titleBar:SetPoint("TOPLEFT", 1, -1)
	titleBar:SetPoint("TOPRIGHT", -1, -1)
	titleBar:SetHeight(TITLE_H)
	titleBar:EnableMouse(true)
	titleBar:RegisterForDrag("LeftButton")
	titleBar:SetScript("OnDragStart", function() window:StartMoving() end)
	titleBar:SetScript("OnDragStop", function()
		window:StopMovingOrSizing()
		Detach()
	end)

	local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
	titleBg:SetAllPoints()
	UI.ColorTexture(titleBg, Theme.titleBg)

	local titleLine = titleBar:CreateTexture(nil, "ARTWORK")
	titleLine:SetPoint("BOTTOMLEFT")
	titleLine:SetPoint("BOTTOMRIGHT")
	titleLine:SetHeight(1)
	UI.ColorTexture(titleLine, Theme.accent, 0.5)

	local titleIcon = titleBar:CreateTexture(nil, "ARTWORK")
	titleIcon:SetSize(16, 16)
	titleIcon:SetPoint("LEFT", 6, 0)
	titleIcon:SetTexture(ns.GetIcon(ICON, FALLBACK_ICON))
	titleIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local title = titleBar:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("LEFT", titleIcon, "RIGHT", 6, 0)
	title:SetText("메모")

	local shared = titleBar:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	shared:SetPoint("LEFT", title, "RIGHT", 8, 0)
	shared:SetText("모든 캐릭터 공유")

	local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
	close:SetSize(22, 22)
	close:SetPoint("TOPRIGHT", -2, -2)
	close:SetFrameLevel(titleBar:GetFrameLevel() + 2)

	-- 글 칸: 스크롤 + 여러 줄 입력
	panel = CreateFrame("Frame", nil, window, "BackdropTemplate")
	panel:SetPoint("TOPLEFT", 8, -(TITLE_H + 6))
	panel:SetPoint("BOTTOMRIGHT", -8, FOOTER_H)
	UI.ApplyPanelBackdrop(panel, { 0, 0, 0, 0.35 }, Theme.border)

	area = UI.CreateScrollArea(panel)
	area.scroll:SetPoint("TOPLEFT", 6, -6)
	area.scroll:SetPoint("BOTTOMRIGHT", -14, 6)   -- 오른쪽은 스크롤 막대 자리
	area.scroll:EnableMouse(true)

	edit = CreateFrame("EditBox", nil, area.scroll)
	edit:SetMultiLine(true)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(0)
	edit:EnableMouse(true)
	edit:SetFontObject(ChatFontNormal)
	edit:SetPoint("TOPLEFT")
	edit:SetSize(1, 1)   -- 폭은 스크롤 영역에 맞추고, 높이는 글 길이에 맞춰 게임이 늘린다
	area.scroll:SetScrollChild(edit)

	placeholder = panel:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	placeholder:SetPoint("TOPLEFT", area.scroll, "TOPLEFT", 0, 0)
	placeholder:SetPoint("RIGHT", area.scroll, "RIGHT", 0, 0)
	placeholder:SetJustifyH("LEFT")
	placeholder:SetText("여기에 적으세요. 같은 계정의 모든 캐릭터가 이 메모를 같이 봅니다.")

	follow = CreateFrame("Frame", nil, window)   -- 창이 보일 때만 돈다

	-- 줄이 늘거나 창 크기가 바뀌면 게임이 알려 주는 범위로 스크롤 막대를 맞춘다
	area.scroll:SetScript("OnScrollRangeChanged", function(self, _, yrange)
		area:SetContentHeight((yrange or 0) + (self:GetHeight() or 0))
	end)
	function area:OnSizeChanged()
		local w = self.scroll:GetWidth()
		if w and w > 0 then edit:SetWidth(w) end
	end
	-- 글 밑 빈 곳을 눌러도 맨 끝에서 이어 쓴다
	area.scroll:SetScript("OnMouseDown", function()
		edit:SetFocus()
		edit:SetCursorPosition(#(edit:GetText() or ""))
	end)

	local function PaintFocus(on)
		local c = on and Theme.accent or Theme.border
		panel:SetBackdropBorderColor(c[1], c[2], c[3], 1)
	end
	edit:SetScript("OnEditFocusGained", function()
		PaintFocus(true)
		RefreshFooter()
	end)
	edit:SetScript("OnEditFocusLost", function(self)
		self:HighlightText(0, 0)
		SaveFromEdit()
		PaintFocus(false)
		RefreshFooter()
	end)
	edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	edit:SetScript("OnTextChanged", function()
		local text = SaveFromEdit()
		placeholder:SetShown(text == "")
		RefreshFooter()
	end)
	edit:SetScript("OnCursorChanged", function(_, _, y, _, h)
		cursorY, cursorH = y or 0, h or 0
		followTries = 0
		follow:SetScript("OnUpdate", FollowStep)
	end)

	-- 아래 줄: 상태 + [모두 선택] + 크기 손잡이
	local selectAll = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	selectAll:SetSize(76, 20)
	selectAll:SetPoint("BOTTOMRIGHT", -22, 4)
	selectAll:SetText("모두 선택")
	selectAll:SetScript("OnClick", function()
		edit:SetFocus()
		edit:HighlightText()
	end)
	selectAll:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("모두 선택", 1, 0.82, 0)
		GameTooltip:AddLine("메모 글을 전부 고릅니다. Ctrl+C로 복사해서 다른 계정의 메모에 붙여 넣을 수 있어요.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	selectAll:SetScript("OnLeave", GameTooltip_Hide)

	footer = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	footer:SetPoint("BOTTOMLEFT", 22, 9)
	footer:SetPoint("RIGHT", selectAll, "LEFT", -6, 0)
	footer:SetJustifyH("LEFT")
	footer:SetWordWrap(false)

	grip = CreateFrame("Button", nil, window)
	grip:SetSize(16, 16)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetScript("OnEnter", function() if SetCursor then SetCursor("UI_RESIZE_CURSOR") end end)
	grip:SetScript("OnLeave", function() if SetCursor then SetCursor(nil) end end)
	grip:SetScript("OnMouseDown", function(self, mouseButton)
		if mouseButton ~= "LeftButton" then return end
		self.sizing = true
		window:StartSizing(self.corner, true)
	end)
	grip:SetScript("OnMouseUp", StopSizing)

	window:SetScript("OnShow", function()
		ApplyGeometry()
		area:OnSizeChanged()
		if edit:GetText() ~= NoteText() then ShowText() end   -- 닫혀 있는 동안 /메모 <글>로 덧붙였을 수 있다
		placeholder:SetShown(NoteText() == "")
		RefreshFooter()
		openBorder:SetShown(true)
		ns:Fire("REFRESH_UI")
	end)
	window:SetScript("OnHide", function()
		StopSizing()
		window:StopMovingOrSizing()   -- 끄는 도중에 닫혀도 마우스에 붙어 다니지 않게
		SaveFromEdit()
		edit:ClearFocus()
		openBorder:SetShown(false)
		ns:Fire("REFRESH_UI")
	end)
end

function M:Open()
	if not db then return end
	if not window then CreateWindow() end
	window:Show()
end

function M:Toggle()
	if IsOpen() then
		window:Hide()
	else
		self:Open()
	end
end

function EzyWOWF_ToggleMemo()
	M:Toggle()
end

local function ShowButtonTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:SetText("메모", 1, 0.82, 0)
	AddPreview(GameTooltip)
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine(IsOpen() and "클릭: 메모 창 닫기" or "클릭: 메모 창 열기", 0.7, 0.7, 0.7)
	local key = GetBindingKey(BINDING)
	GameTooltip:AddLine("단축키: " .. (key and GetBindingText(key) or "없음 (/이지 에서 지정)"), 0.7, 0.7, 0.7)
	GameTooltip:Show()
end

button:SetScript("OnClick", function(self)
	M:Toggle()
	if GameTooltip:IsOwned(self) then ShowButtonTooltip(self) end   -- 열기/닫기 안내를 바로 고친다
end)
button:SetScript("OnEnter", ShowButtonTooltip)
button:SetScript("OnLeave", GameTooltip_Hide)

-- /메모: 창 열기/닫기. /메모 <글>: 메모 맨 끝에 한 줄 덧붙인다.
SLASH_EZYWOWFMEMO1 = "/메모"
SLASH_EZYWOWFMEMO2 = "/memo"
SlashCmdList.EZYWOWFMEMO = function(msg)
	if not db then return end
	local line = strtrim(msg or "")
	if line == "" then
		M:Toggle()
		return
	end
	local text = NoteText()
	if text ~= "" and text:sub(-1) ~= "\n" then text = text .. "\n" end
	SaveText(text .. line)
	if edit then ShowText("end") end
	Print("메모에 적었어요: " .. line)
end

ns:On("MINIMAP_LAYOUT_CHANGED", function()
	PlaceButton()
	ApplyGeometry()
end)
ns:On("MINIMAP_ROW_CHANGED", PlaceButton)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	if type(ns.db.memo) ~= "table" then ns.db.memo = {} end
	note = ns.db.memo
	if type(note.text) ~= "string" then note.text = "" end
	icon:SetTexture(ns.GetIcon(ICON, FALLBACK_ICON))
	PlaceButton()
end

function M:OnLogin()
	PlaceButton()
end

function M:ApplySettings(changes)
	PlaceButton()
	ApplyGeometry()
	-- 버튼을 켜고 끄면 추적 아이콘이 왼쪽 모서리를 비우거나 다시 쓴다
	if changes.showButton ~= nil then ns:Fire("MINIMAP_LAYOUT_CHANGED") end
end

function M:BuildOptions(b)
	b:Text("이 계정의 모든 캐릭터가 같이 쓰는 메모장입니다. 메모 창은 하나이고, 적는 대로 바로 저장됩니다. "
		.. "글을 쓰는 동안에는 키보드가 메모에 묶이니 다 쓰면 Esc를 누르세요.\n"
		.. "다른 와우 계정과는 공유되지 않아요. 옮기려면 메모 창의 [모두 선택]을 누르고 Ctrl+C로 복사해서 붙여 넣으세요.")
	b:Buttons{
		{
			text = "메모 창 열기",
			textFunc = function() return IsOpen() and "메모 창 닫기" or "메모 창 열기" end,
			onClick = function() M:Toggle() end,
		},
	}
	b:KeyBind{ command = BINDING, label = "메모 창 열기/닫기" }
	b:Check{
		key = "showButton",
		label = "지도 밑에 메모 버튼 표시",
		tooltip = "미니맵 바로 밑, 추적 아이콘 줄의 왼쪽 끝에 메모 버튼을 둡니다. 꺼도 /메모 명령과 단축키로 열 수 있어요.",
	}

	b:Header("메모 창 위치")
	b:Text("처음에는 지도 왼쪽에 붙어서 열립니다. 제목 줄을 끌어 옮기면 지도에서 떨어지고, "
		.. "아래 모서리의 손잡이를 끌면 크기가 바뀝니다.")
	b:Buttons{
		{
			text = "지도 옆에 붙이기",
			onClick = Reattach,
			disabled = function() return db.attached end,
			tooltip = "옮겨 둔 메모 창을 다시 지도 왼쪽에 붙입니다. 크기는 그대로예요.",
		},
	}

	b:Header("명령어")
	b:Text("/메모 (또는 /memo) - 메모 창 열기/닫기\n"
		.. "/메모 <글> - 메모 맨 끝에 한 줄 덧붙이기 (예: /메모 내일 경매장 들르기)")
end
