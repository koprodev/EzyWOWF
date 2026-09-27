-- 설정 창: 왼쪽 메뉴(분류 > 기능) + 오른쪽 기능 페이지(위쪽 배너) + 아래쪽 [되돌리기]/[저장].
-- 메뉴 한 줄 = 기능 하나 = 페이지 하나. 분류 머리줄을 누르면 접히고, 접힘·마지막 선택은 저장된다.

local _, ns = ...
local UI = ns.UI
local Theme = UI.Theme

local WIDTH, HEIGHT = 820, 580
local TITLE_HEIGHT = 32
local FOOTER_HEIGHT = 44
local NAV_WIDTH = 200
local NAV_INNER = NAV_WIDTH - 16    -- 스크롤바 자리를 뺀 메뉴 줄 폭
local HEADER_H, ROW_H = 24, 22
local BANNER_H = 52
local PAGE_WIDTH = WIDTH - 8 - NAV_WIDTH - 8 - 8 - 12

local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local PLUS = "Interface\\Buttons\\UI-PlusButton-Up"
local MINUS = "Interface\\Buttons\\UI-MinusButton-Up"

local window, navArea, pageArea, navChild, saveBtn, revertBtn, statusText, banner
local pages = {}        -- [모듈 키] = { frame =, builder = }
local navCats = {}      -- { cat =, header =, modules = { m, ... } } 모듈이 있는 분류만
local moduleRows = {}   -- [모듈 키] = 메뉴 줄
local selectedKey       -- 지금 보고 있는 기능
local openTarget        -- 창이 열릴 때 보여 줄 기능 (OnShow가 한 번 쓰고 비운다)

local Refresh, ShowPage   -- 아래에서 서로 부른다

-- enabled 설정이 있는 기능만 켜짐/꺼짐을 보여 준다. 표시는 저장된 값 기준(바꾼 값은 주황 점으로).
local function HasEnabled(m)
	return type(m.defaults) == "table" and m.defaults.enabled ~= nil
end

local function IsOff(m)
	return HasEnabled(m) and not m.db.enabled
end

StaticPopupDialogs["EZYWOWF_UNSAVED"] = {
	text = ns.title .. "\n\n저장하지 않은 변경 사항이 있습니다.",
	button1 = "저장",
	button2 = "버리기",
	OnAccept = function() ns:SaveSettings() end,
	OnCancel = function(_, _, reason)
		if reason == "clicked" then ns:DiscardSettings() end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

local function SavePosition()
	local point, _, relPoint, x, y = window:GetPoint(1)
	local pos = ns.db.window
	pos.point, pos.relPoint, pos.x, pos.y = point, relPoint, x, y
end

---------------------------------------------------------------------------
-- 왼쪽 메뉴
---------------------------------------------------------------------------
local function CreateHeaderRow(parent, cat)
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(NAV_INNER, HEADER_H)

	local hover = row:CreateTexture(nil, "HIGHLIGHT")
	hover:SetAllPoints()
	UI.ColorTexture(hover, Theme.hover)

	row.arrow = row:CreateTexture(nil, "ARTWORK")
	row.arrow:SetSize(12, 12)
	row.arrow:SetPoint("LEFT", 2, 0)
	row.arrow:SetAlpha(0.7)

	local icon = row:CreateTexture(nil, "ARTWORK")
	icon:SetSize(14, 14)
	icon:SetPoint("LEFT", row.arrow, "RIGHT", 4, 0)
	icon:SetTexture(ns.GetIcon(cat.icon))
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local text = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	text:SetPoint("LEFT", icon, "RIGHT", 5, 0)
	text:SetText(cat.title)
	UI.ColorText(text, Theme.header)

	row.dot = row:CreateTexture(nil, "ARTWORK")
	row.dot:SetSize(6, 6)
	row.dot:SetPoint("RIGHT", -6, 0)
	UI.ColorTexture(row.dot, Theme.pending)
	row.dot:Hide()

	return row
end

local function CreateModuleRow(parent, m)
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(NAV_INNER, ROW_H)

	row.selected = row:CreateTexture(nil, "BACKGROUND")
	row.selected:SetAllPoints()
	UI.ColorTexture(row.selected, Theme.selected)
	row.selected:Hide()

	row.bar = row:CreateTexture(nil, "ARTWORK")
	row.bar:SetPoint("TOPLEFT")
	row.bar:SetPoint("BOTTOMLEFT")
	row.bar:SetWidth(2)
	UI.ColorTexture(row.bar, Theme.accent)
	row.bar:Hide()

	local hover = row:CreateTexture(nil, "HIGHLIGHT")
	hover:SetAllPoints()
	UI.ColorTexture(hover, Theme.hover)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", 12, 0)
	row.icon:SetTexture(ns.GetIcon(m.icon or QUESTION_MARK))
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	row.dot = row:CreateTexture(nil, "ARTWORK")
	row.dot:SetSize(6, 6)
	row.dot:SetPoint("RIGHT", -6, 0)
	UI.ColorTexture(row.dot, Theme.pending)
	row.dot:Hide()

	row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.text:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
	row.text:SetPoint("RIGHT", row.dot, "LEFT", -4, 0)
	row.text:SetJustifyH("LEFT")
	row.text:SetWordWrap(false)
	row.text:SetText(m.title)

	-- 이름이 잘렸을 때만 전체 이름을 보여 준다.
	row:SetScript("OnEnter", function(self)
		if self.text:IsTruncated() then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(m.title, 1, 1, 1)
			GameTooltip:Show()
		end
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	return row
end

local function LayoutNav()
	local collapsed = ns.db.window.collapsed
	local y = 0
	for _, nc in ipairs(navCats) do
		nc.header:ClearAllPoints()
		nc.header:SetPoint("TOPLEFT", navChild, "TOPLEFT", 0, -y)
		nc.header.arrow:SetTexture(collapsed[nc.cat.key] and PLUS or MINUS)
		y = y + HEADER_H
		for _, m in ipairs(nc.modules) do
			local row = moduleRows[m.key]
			if collapsed[nc.cat.key] then
				row:Hide()
			else
				row:ClearAllPoints()
				row:SetPoint("TOPLEFT", navChild, "TOPLEFT", 0, -y)
				row:Show()
				row.navY = y
				y = y + ROW_H
			end
		end
	end
	navChild:SetHeight(math.max(y, 1))
	navArea:SetContentHeight(y)
end

-- 고른 줄이 메뉴 밖에 있으면 보이는 곳까지 굴린다.
local function ScrollNavTo(key)
	local row = key and moduleRows[key]
	if not (row and row:IsShown() and row.navY) then return end
	local h = navArea.scroll:GetHeight()
	if not h or h <= 0 then return end   -- 창 크기가 아직 안 잡혔으면 크기가 잡힐 때 다시 부른다
	local top, v = row.navY, navArea.bar:GetValue()
	if top < v then
		navArea:ScrollTo(top)
	elseif top + ROW_H > v + h then
		navArea:ScrollTo(top + ROW_H - h)
	end
end

local function RefreshNav()
	for _, nc in ipairs(navCats) do
		local any = false
		for _, m in ipairs(nc.modules) do
			local row = moduleRows[m.key]
			local pending = ns:ModuleHasPending(m)
			any = any or pending
			row.dot:SetShown(pending)
			local isSelected = m.key == selectedKey
			row.selected:SetShown(isSelected)
			row.bar:SetShown(isSelected)
			local off = IsOff(m)
			UI.ColorText(row.text, off and Theme.disabled or Theme.normal)
			row.icon:SetDesaturated(off)
		end
		nc.header.dot:SetShown(any)
	end
end

---------------------------------------------------------------------------
-- 페이지 위쪽 배너 (아이콘 + 기능 이름 + 경로 + 켜짐 상태)
---------------------------------------------------------------------------
local function RefreshBanner()
	local m = selectedKey and ns.modules[selectedKey]
	if not m then return end
	if banner.key ~= m.key then
		banner.key = m.key
		banner.icon:SetTexture(ns.GetIcon(m.icon or QUESTION_MARK))
		banner.title:SetText(m.title)
		banner.path:SetText(ns:SettingsPath(m.key))
	end

	banner.badge:SetShown(HasEnabled(m))
	if HasEnabled(m) then
		local on = m.db.enabled and true or false
		local text = on and "사용 중" or "꺼짐"
		if ns:IsPending(m, "enabled") then text = text .. "  |cffff9933(저장 전)|r" end
		banner.badge.text:SetText(text)
		UI.ColorText(banner.badge.text, on and Theme.accent or Theme.muted)
		UI.ColorTexture(banner.badge.bg, on and Theme.accent or Theme.muted, 0.14)
		banner.badge:SetWidth(banner.badge.text:GetStringWidth() + 16)
		banner.icon:SetDesaturated(not on)
	else
		banner.icon:SetDesaturated(false)
	end
end

local function CreateBanner(parent)
	local b = CreateFrame("Frame", nil, parent)
	b:SetHeight(BANNER_H)

	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetSize(32, 32)
	b.icon:SetPoint("LEFT", 12, 0)
	b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	-- 아이콘 가운데를 기준으로 제목은 위로, 경로는 아래로 자란다. 글자를 키워도 안 겹친다.
	b.title = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
	b.title:SetPoint("BOTTOMLEFT", b.icon, "RIGHT", 10, 1)

	b.path = b:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	b.path:SetPoint("TOPLEFT", b.icon, "RIGHT", 10, -1)

	b.badge = CreateFrame("Frame", nil, b)
	b.badge:SetSize(60, 20)
	b.badge:SetPoint("RIGHT", -12, 0)
	b.badge.bg = b.badge:CreateTexture(nil, "BACKGROUND")
	b.badge.bg:SetAllPoints()
	b.badge.text = b.badge:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	b.badge.text:SetPoint("CENTER")

	local line = b:CreateTexture(nil, "ARTWORK")
	line:SetPoint("BOTTOMLEFT")
	line:SetPoint("BOTTOMRIGHT")
	line:SetHeight(1)
	UI.ColorTexture(line, Theme.line)
	return b
end

---------------------------------------------------------------------------
-- 페이지
---------------------------------------------------------------------------
Refresh = function()
	if not (window and window:IsShown()) then return end

	local hasPending = ns:HasPending()
	saveBtn:SetEnabled(hasPending)
	revertBtn:SetEnabled(hasPending)
	statusText:SetText(hasPending and "|cffff9933저장하지 않은 변경 사항이 있습니다.|r" or "|cff808080변경 사항 없음|r")

	RefreshNav()
	RefreshBanner()

	local page = selectedKey and pages[selectedKey]
	if page then page.builder:Refresh() end
end

local function BuildPage(key)
	local m = ns.modules[key]
	local frame = CreateFrame("Frame", nil, pageArea.scroll)
	frame:SetSize(PAGE_WIDTH, 10)
	local builder = UI.NewBuilder(frame, m, PAGE_WIDTH)
	if m.BuildOptions then
		m:BuildOptions(builder)
	else
		builder:Text("설정할 항목이 없습니다.")
	end
	frame:SetHeight(builder:Height())
	pages[key] = { frame = frame, builder = builder }
	return pages[key]
end

-- 페이지만 바꿔 끼운다. 메뉴 접힘·스크롤은 건드리지 않는다. (다시 그리기에서도 쓴다)
ShowPage = function(key)
	for _, p in pairs(pages) do p.frame:Hide() end   -- 지금 페이지도 숨겨야 단축키 입력 대기가 풀린다
	local page = pages[key] or BuildPage(key)
	page.frame:Show()
	pageArea.scroll:SetScrollChild(page.frame)
	pageArea.bar:SetValue(0)
	pageArea.scroll:SetVerticalScroll(0)
	pageArea:SetContentHeight(page.frame:GetHeight())
	Refresh()   -- 컨트롤은 만들 때 값을 안 채우므로 바로 칠한다
end

-- 모듈 키 > 분류 키(그 분류 첫 기능) > 지금 보던 기능 > 저장된 기능 > 맨 첫 기능
local function ResolveTarget(key)
	if key and ns.modules[key] and moduleRows[key] then return key end
	if key then
		for _, nc in ipairs(navCats) do
			if nc.cat.key == key then return nc.modules[1].key end
		end
	end
	if type(selectedKey) == "string" and moduleRows[selectedKey] then return selectedKey end
	local saved = ns.db.window.selected
	if type(saved) == "string" and moduleRows[saved] then return saved end
	return navCats[1].modules[1].key
end

local function IsDirectTarget(key)
	if ns.modules[key] and moduleRows[key] then return true end
	for _, nc in ipairs(navCats) do
		if nc.cat.key == key then return true end
	end
	return false
end

-- 메뉴에서 고르기: 접힌 분류는 펼치고, 고른 줄이 보이게 굴리고, 다음 접속을 위해 기억한다.
local function SelectModule(key)
	local explicit = key ~= nil   -- 첫 열기(nil)는 저장된 접힘을 그대로 둔다
	key = ResolveTarget(key)
	local m = ns.modules[key]
	local w = ns.db.window
	if explicit and w.collapsed[m.category] then
		w.collapsed[m.category] = nil
		LayoutNav()
	end
	selectedKey = key
	w.selected = key
	ShowPage(key)
	ScrollNavTo(key)
end

local function ToggleCategory(key)
	local c = ns.db.window.collapsed
	c[key] = (not c[key]) or nil
	LayoutNav()
	RefreshNav()
end

---------------------------------------------------------------------------
-- 창
---------------------------------------------------------------------------
local function CreateWindow()
	local w = ns.db.window
	if type(w.collapsed) ~= "table" then w.collapsed = {} end   -- 저장 파일이 깨졌어도 버틴다

	window = CreateFrame("Frame", "EzyWOWFWindow", UIParent, "BackdropTemplate")
	window:SetSize(WIDTH, HEIGHT)
	window:SetFrameStrata("HIGH")
	window:SetToplevel(true)
	window:SetMovable(true)
	window:EnableMouse(true)
	window:SetClampedToScreen(true)
	UI.ApplyPanelBackdrop(window)
	window:Hide()
	tinsert(UISpecialFrames, "EzyWOWFWindow")

	if w.point then
		window:SetPoint(w.point, UIParent, w.relPoint, w.x, w.y)
	else
		window:SetPoint("CENTER")
	end

	-- 제목 줄 (여기를 잡고 창을 옮긴다)
	local titleBar = CreateFrame("Frame", nil, window)
	titleBar:SetPoint("TOPLEFT", 1, -1)
	titleBar:SetPoint("TOPRIGHT", -1, -1)
	titleBar:SetHeight(TITLE_HEIGHT)
	titleBar:EnableMouse(true)
	titleBar:RegisterForDrag("LeftButton")
	titleBar:SetScript("OnDragStart", function() window:StartMoving() end)
	titleBar:SetScript("OnDragStop", function()
		window:StopMovingOrSizing()
		SavePosition()
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
	titleIcon:SetSize(20, 20)
	titleIcon:SetPoint("LEFT", 8, 0)
	titleIcon:SetTexture(ns.GetIcon(ns.icon, ns.fallbackIcon))
	titleIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local title = titleBar:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("LEFT", titleIcon, "RIGHT", 7, 0)
	title:SetText(ns.title .. "  |cff808080v" .. ns.version .. "|r")

	local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
	close:SetSize(26, 26)
	close:SetPoint("TOPRIGHT", -3, -3)

	-- 왼쪽: 분류 > 기능 메뉴
	local nav = CreateFrame("Frame", nil, window)
	nav:SetPoint("TOPLEFT", 8, -(TITLE_HEIGHT + 8))
	nav:SetPoint("BOTTOMLEFT", 8, FOOTER_HEIGHT)
	nav:SetWidth(NAV_WIDTH)
	local navBg = nav:CreateTexture(nil, "BACKGROUND")
	navBg:SetAllPoints()
	UI.ColorTexture(navBg, Theme.panel)

	navArea = UI.CreateScrollArea(nav)
	navArea.scroll:SetPoint("TOPLEFT", 4, -4)
	navArea.scroll:SetPoint("BOTTOMRIGHT", -12, 4)
	navChild = CreateFrame("Frame", nil, navArea.scroll)
	navChild:SetSize(NAV_INNER, 1)
	navArea.scroll:SetScrollChild(navChild)
	function navArea:OnSizeChanged() ScrollNavTo(selectedKey) end

	for _, cat in ipairs(ns.categories) do
		local modules = ns:ModulesInCategory(cat.key)
		if #modules > 0 then
			local nc = { cat = cat, modules = modules }
			nc.header = CreateHeaderRow(navChild, cat)
			nc.header:SetScript("OnClick", function() ToggleCategory(cat.key) end)
			for _, m in ipairs(modules) do
				local row = CreateModuleRow(navChild, m)
				row:SetScript("OnClick", function() SelectModule(m.key) end)
				moduleRows[m.key] = row
			end
			navCats[#navCats + 1] = nc
		end
	end
	LayoutNav()

	-- 오른쪽: 배너 + 기능 페이지 (마우스 휠로 스크롤)
	banner = CreateBanner(window)
	banner:SetPoint("TOPLEFT", nav, "TOPRIGHT", 8, 0)
	banner:SetPoint("TOPRIGHT", window, "TOPRIGHT", -8, -(TITLE_HEIGHT + 8))

	pageArea = UI.CreateScrollArea(window)
	pageArea.scroll:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 0, -4)
	pageArea.scroll:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -20, FOOTER_HEIGHT)

	-- 아래쪽: 상태 + 버튼
	local footerLine = window:CreateTexture(nil, "ARTWORK")
	UI.ColorTexture(footerLine, Theme.line)
	footerLine:SetPoint("BOTTOMLEFT", 8, FOOTER_HEIGHT - 4)
	footerLine:SetPoint("BOTTOMRIGHT", -8, FOOTER_HEIGHT - 4)
	footerLine:SetHeight(1)

	statusText = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	statusText:SetPoint("BOTTOMLEFT", 16, 16)

	saveBtn = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	saveBtn:SetSize(100, 24)
	saveBtn:SetPoint("BOTTOMRIGHT", -12, 10)
	saveBtn:SetText("저장")
	saveBtn:SetScript("OnClick", function() ns:SaveSettings() end)

	revertBtn = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	revertBtn:SetSize(100, 24)
	revertBtn:SetPoint("RIGHT", saveBtn, "LEFT", -6, 0)
	revertBtn:SetText("되돌리기")
	revertBtn:SetScript("OnClick", function() ns:DiscardSettings() end)

	window:SetScript("OnShow", function()
		local target = openTarget
		openTarget = nil
		if target then
			SelectModule(target)
		elseif not selectedKey then
			SelectModule(nil)          -- 이번 접속 첫 열기: 지난번에 보던 기능으로
		elseif not pages[selectedKey] then
			ShowPage(selectedKey)      -- 닫혀 있는 동안 페이지가 다시 만들어졌으면 새로 그린다
		else
			Refresh()
		end
	end)

	window:SetScript("OnHide", function()
		if ns:HasPending() then StaticPopup_Show("EZYWOWF_UNSAVED") end
	end)
end

-- key: 모듈 키(그 기능 페이지) 또는 분류 키(그 분류의 첫 기능). 없으면 지난번 페이지.
function ns:OpenWindow(key)
	if not ns.db then return end
	if not window then CreateWindow() end
	StaticPopup_Hide("EZYWOWF_UNSAVED")
	if window:IsShown() then
		if key and IsDirectTarget(key) then SelectModule(key) end
	else
		openTarget = (key and IsDirectTarget(key)) and key or nil
		window:Show()
	end
end

function ns:ToggleWindow()
	if window and window:IsShown() then
		window:Hide()
	else
		self:OpenWindow()
	end
end

function EzyWOWF_ToggleWindow()
	ns:ToggleWindow()
end

-- 이미 그린 페이지를 버리고 새로 그린다. 메뉴 접힘·스크롤은 그대로 둔다.
--   FONTS_CHANGED: 글자 크기가 바뀌어 줄 간격이 맞지 않을 때
--   REBUILD_OPTIONS: 모듈의 설정 항목 구성이 바뀌었을 때 (예: 새 추적 기술을 배움)
local function RebuildPages()
	for key, page in pairs(pages) do
		page.frame:Hide()
		pages[key] = nil
	end
	if window and window:IsShown() and selectedKey then ShowPage(selectedKey) end
end
ns:On("FONTS_CHANGED", RebuildPages)
ns:On("REBUILD_OPTIONS", RebuildPages)

ns:On("PENDING_CHANGED", Refresh)
ns:On("REFRESH_UI", Refresh)
ns:RegisterEvent("UPDATE_BINDINGS", Refresh)
