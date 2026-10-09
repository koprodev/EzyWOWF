-- Settings: categories on the left, feature tabs above the options, and searchable option paths.

local _, ns = ...
local UI = ns.UI
local Theme = UI.Theme

local WIDTH, HEIGHT = 900, 620
local TITLE_HEIGHT, TOOLBAR_HEIGHT, FOOTER_HEIGHT = 32, 38, 44
local NAV_WIDTH, NAV_ROW_H = 156, 36
local TAB_H, TAB_GAP, BANNER_H = 28, 4, 52
local PAGE_WIDTH = WIDTH - 8 - NAV_WIDTH - 8 - 8 - 12
local RESULT_H = 78
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

local window, navArea, pageArea, navChild, saveBtn, revertBtn, statusText, banner, tabHost
local searchBox, searchHint, clearSearch, backToResults, searchChild, searchEmpty, optionFocus
local pages, navCats, categoryRows, moduleTabs, categorySelection, searchIndexes = {}, {}, {}, {}, {}, {}
local selectedKey, openTarget
local searchResults, resultRows = {}, {}
local showingResults = false
local Refresh, ShowPage, SelectModule, RunSearch, LayoutResultRows

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

local function PlainText(text)
	if type(text) ~= "string" then return "" end
	return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
		:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|H.-|h(.-)|h", "%1")
		:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function Query()
	return PlainText(searchBox:GetText())
end

local function RefreshSearchControls()
	local hasQuery = Query() ~= ""
	searchHint:SetShown(not hasQuery and not searchBox:HasFocus())
	clearSearch:SetShown(hasQuery)
	backToResults:SetShown(hasQuery and not showingResults)
end

local function CreateMenuButton(parent, title, iconPath, category)
	local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
	row:SetHeight(category and NAV_ROW_H or TAB_H)
	row.selected = row:CreateTexture(nil, "BACKGROUND")
	row.selected:SetAllPoints()
	if not (category and UI.SetAtlas(row.selected, "Options_List_Active")) then
		UI.ColorTexture(row.selected, Theme.selected)
	end
	row.selected:Hide()
	row.bar = row:CreateTexture(nil, "ARTWORK")
	row.bar:SetPoint("BOTTOMLEFT")
	row.bar:SetPoint(category and "TOPLEFT" or "BOTTOMRIGHT")
	if category then row.bar:SetWidth(2) else row.bar:SetHeight(2) end
	UI.ColorTexture(row.bar, Theme.accent)
	row.bar:Hide()
	local hover = row:CreateTexture(nil, "HIGHLIGHT")
	hover:SetAllPoints()
	if not (category and UI.SetAtlas(hover, "Options_List_Hover")) then UI.ColorTexture(hover, Theme.hover) end
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", 8, 0)
	row.icon:SetTexture(ns.GetIcon(iconPath or QUESTION_MARK))
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
	row.text:SetText(title)
	row:SetWidth(category and (NAV_WIDTH - 16) or math.min(PAGE_WIDTH, row.text:GetStringWidth() + 50))
	if not category then UI.ApplyTabArt(row) end
	row:SetScript("OnEnter", function(self)
		if self.text:IsTruncated() then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(title, 1, 1, 1)
			GameTooltip:Show()
		end
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	return row
end

local function LayoutTabs()
	local m = selectedKey and ns.modules[selectedKey]
	local x, y = 0, 0
	for _, nc in ipairs(navCats) do
		for _, module in ipairs(nc.modules) do
			local tab = moduleTabs[module.key]
			if not showingResults and m and module.category == m.category then
				local width = tab:GetWidth()
				if x > 0 and x + width > PAGE_WIDTH then x, y = 0, y + TAB_H + TAB_GAP end
				tab:ClearAllPoints()
				tab:SetPoint("TOPLEFT", tabHost, "TOPLEFT", x, -y)
				tab:Show()
				x = x + width + TAB_GAP
			else
				tab:Hide()
			end
		end
	end
	tabHost:SetHeight(showingResults and 1 or y + TAB_H)
end

local function RefreshNav()
	local selected = selectedKey and ns.modules[selectedKey]
	for _, nc in ipairs(navCats) do
		local pending = false
		for _, m in ipairs(nc.modules) do
			local tab = moduleTabs[m.key]
			local changed = ns:ModuleHasPending(m)
			pending = pending or changed
			tab.dot:SetShown(changed)
			local active = not showingResults and m.key == selectedKey
			tab.selected:SetShown(active)
			tab.bar:SetShown(active)
			tab:PaintTab(active)
			UI.ColorText(tab.text, IsOff(m) and Theme.disabled or (active and Theme.header or Theme.normal))
			tab.icon:SetDesaturated(IsOff(m))
		end
		local row = categoryRows[nc.cat.key]
		local active = not showingResults and selected and selected.category == nc.cat.key
		row.selected:SetShown(active)
		row.bar:SetShown(active)
		row.dot:SetShown(pending)
		UI.ColorText(row.text, active and Theme.header or Theme.normal)
	end
end

local function RefreshBanner()
	if showingResults then
		banner.icon:SetTexture(ns.GetIcon("Interface\\Icons\\INV_Misc_Spyglass_02"))
		banner.icon:SetDesaturated(false)
		banner.title:SetText(("검색 결과 %d개"):format(#searchResults))
		banner.path:SetText("결과를 누르면 해당 옵션으로 이동합니다. 메뉴 경로도 누를 수 있습니다.")
		banner.badge:Hide()
		return
	end
	local m = selectedKey and ns.modules[selectedKey]
	if not m then return end
	banner.icon:SetTexture(ns.GetIcon(m.icon or QUESTION_MARK))
	banner.title:SetText(m.title)
	banner.path:SetText(ns:SettingsPath(m.key))
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
	b.title = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
	b.title:SetPoint("BOTTOMLEFT", b.icon, "RIGHT", 10, 1)
	b.path = b:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	b.path:SetPoint("TOPLEFT", b.icon, "RIGHT", 10, -1)
	b.path:SetWidth(PAGE_WIDTH - 64)
	b.path:SetJustifyH("LEFT")
	b.path:SetWordWrap(false)
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

Refresh = function()
	if not (window and window:IsShown()) then return end
	local hasPending = ns:HasPending()
	saveBtn:SetEnabled(hasPending)
	revertBtn:SetEnabled(hasPending)
	statusText:SetText(hasPending and "|cffff9933저장하지 않은 변경 사항이 있습니다.|r" or "|cff808080변경 사항 없음|r")
	RefreshNav()
	RefreshBanner()
	RefreshSearchControls()
	local page = not showingResults and selectedKey and pages[selectedKey]
	if page then page.builder:Refresh() end
end

local function BuildPage(key)
	local m = ns.modules[key]
	local frame = CreateFrame("Frame", nil, pageArea.scroll)
	frame:Hide()
	frame:SetSize(PAGE_WIDTH, 10)
	local builder = UI.NewBuilder(frame, m, PAGE_WIDTH)
	if m.BuildOptions then m:BuildOptions(builder) else builder:Text("설정할 항목이 없습니다.") end
	frame:SetHeight(builder:Height())
	pages[key] = { frame = frame, builder = builder }
	return pages[key]
end

local function HideContent()
	if optionFocus then optionFocus:Hide() end
	for _, page in pairs(pages) do page.frame:Hide() end
	searchChild:Hide()
end

ShowPage = function(key)
	HideContent()
	showingResults = false
	LayoutTabs()
	local page = pages[key] or BuildPage(key)
	page.frame:Show()
	pageArea.scroll:SetScrollChild(page.frame)
	pageArea:SetContentHeight(page.frame:GetHeight())
	pageArea:ScrollTo(0)
	Refresh()
end

local function ResolveTarget(key)
	if key and ns.modules[key] and moduleTabs[key] then return key end
	if key then
		for _, nc in ipairs(navCats) do
			if nc.cat.key == key then return categorySelection[key] or nc.modules[1].key end
		end
	end
	if type(selectedKey) == "string" and moduleTabs[selectedKey] then return selectedKey end
	local saved = ns.db.window.selected
	if type(saved) == "string" and moduleTabs[saved] then return saved end
	return navCats[1] and navCats[1].modules[1].key
end

local function IsDirectTarget(key)
	if ns.modules[key] and moduleTabs[key] then return true end
	for _, nc in ipairs(navCats) do if nc.cat.key == key then return true end end
	return false
end

SelectModule = function(key, entry, sectionOnly)
	key = ResolveTarget(key)
	if not key then return end
	selectedKey = key
	local m = ns.modules[key]
	categorySelection[m.category] = key
	ns.db.window.selected = key
	searchBox:ClearFocus()
	ShowPage(key)
	local page = pages[key]
	if entry and entry.indexOnly then entry = page.builder.searchEntries[entry.index] end
	if sectionOnly and entry then entry = page.builder.searchEntries[entry.sectionIndex] or entry end
	if entry then
		pageArea:ScrollTo(math.max(0, entry.y - 12))
		if not optionFocus then
			optionFocus = CreateFrame("Frame", nil, page.frame, "BackdropTemplate")
			UI.ApplyPanelBackdrop(optionFocus, { Theme.accent[1], Theme.accent[2], Theme.accent[3], 0.08 }, Theme.accent)
			optionFocus:EnableMouse(false)
		end
		optionFocus:SetParent(page.frame)
		optionFocus:ClearAllPoints()
		optionFocus:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 10, -entry.y + 2)
		optionFocus:SetSize(PAGE_WIDTH - 20, math.max(entry.height or 26, 26) + 4)
		optionFocus:Show()
	end
end

local function CreatePathButton(parent)
	local button = CreateFrame("Button", nil, parent)
	button:SetHeight(18)
	button.text = button:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	button.text:SetAllPoints()
	button.text:SetJustifyH("LEFT")
	button.text:SetWordWrap(false)
	UI.ColorText(button.text, Theme.accent)
	local hover = button:CreateTexture(nil, "HIGHLIGHT")
	hover:SetAllPoints()
	UI.ColorTexture(hover, Theme.hover)
	return button
end

local function CreateResultRow()
	local row = CreateFrame("Button", nil, searchChild)
	row:SetSize(PAGE_WIDTH - 24, RESULT_H - 4)
	local hover = row:CreateTexture(nil, "HIGHLIGHT")
	hover:SetAllPoints()
	UI.ColorTexture(hover, Theme.hover)
	row.title = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.title:SetPoint("TOPLEFT", 8, -6)
	row.title:SetPoint("TOPRIGHT", -8, -6)
	row.title:SetJustifyH("LEFT")
	row.title:SetWordWrap(false)
	row.category = CreatePathButton(row)
	row.category:SetPoint("TOPLEFT", 8, -28)
	row.module = CreatePathButton(row)
	row.section = CreatePathButton(row)
	row.detail = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	row.detail:SetPoint("TOPLEFT", 8, -51)
	row.detail:SetPoint("TOPRIGHT", -8, -51)
	row.detail:SetJustifyH("LEFT")
	row.detail:SetWordWrap(false)
	local line = row:CreateTexture(nil, "ARTWORK")
	line:SetPoint("BOTTOMLEFT", 8, 0)
	line:SetPoint("BOTTOMRIGHT", -8, 0)
	line:SetHeight(1)
	UI.ColorTexture(line, Theme.line)
	row:SetScript("OnClick", function(self)
		local result = self.result
		if result then SelectModule(result.module.key, result.entry) end
	end)
	row.category:SetScript("OnClick", function()
		if row.result then SelectModule(row.result.module.category) end
	end)
	row.module:SetScript("OnClick", function()
		if row.result then SelectModule(row.result.module.key) end
	end)
	row.section:SetScript("OnClick", function()
		if row.result then
			local entry = row.result.entry
			SelectModule(row.result.module.key, entry, true)
		end
	end)
	row:SetScript("OnEnter", function(self)
		if self.result then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(self.result.label, 1, 0.82, 0)
			GameTooltip:AddLine(self.result.path, Theme.accent[1], Theme.accent[2], Theme.accent[3], true)
			if self.result.detail ~= "" then GameTooltip:AddLine(self.result.detail, 1, 1, 1, true) end
			GameTooltip:Show()
		end
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	return row
end

LayoutResultRows = function()
	if not showingResults then return end
	local first = math.floor(pageArea.bar:GetValue() / RESULT_H) + 1
	local count = math.ceil(math.max(pageArea.scroll:GetHeight(), 1) / RESULT_H) + 1
	for i = 1, count do
		local index = first + i - 1
		local result = searchResults[index]
		local row = resultRows[i]
		if result then
			if not row then row = CreateResultRow() resultRows[i] = row end
			row.result = result
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", searchChild, "TOPLEFT", 12, -(index - 1) * RESULT_H)
			row.title:SetText(result.label)
			row.detail:SetText(result.detail)
			local category = ns:GetCategory(result.module.category)
			row.category.text:SetText(category.title .. "  >")
			row.category:SetWidth(row.category.text:GetStringWidth() + 8)
			row.module:ClearAllPoints()
			row.module:SetPoint("LEFT", row.category, "RIGHT", 4, 0)
			local section = result.entry and result.entry.section
			row.module.text:SetText(result.module.title .. (section and "  >" or ""))
			row.module:SetWidth(math.min(row.module.text:GetStringWidth() + 8, PAGE_WIDTH / 2))
			row.section:ClearAllPoints()
			row.section:SetPoint("LEFT", row.module, "RIGHT", 4, 0)
			row.section:SetWidth(math.max(1, PAGE_WIDTH - 60 - row.category:GetWidth() - row.module:GetWidth()))
			row.section.text:SetText(section or "")
			row.section:SetShown(section ~= nil)
			row:Show()
		elseif row then row:Hide() end
	end
	for i = count + 1, #resultRows do resultRows[i]:Hide() end
end

local function ShowSearchResults()
	HideContent()
	showingResults = true
	LayoutTabs()
	searchChild:SetHeight(math.max(#searchResults * RESULT_H, 72))
	searchEmpty:SetShown(#searchResults == 0)
	searchChild:Show()
	pageArea.scroll:SetScrollChild(searchChild)
	pageArea:SetContentHeight(searchChild:GetHeight())
	pageArea:ScrollTo(0)
	LayoutResultRows()
	Refresh()
end

RunSearch = function()
	local query = Query():lower()
	if query == "" then
		if selectedKey then ShowPage(selectedKey) end
		RefreshSearchControls()
		return
	end
	local tokens = {}
	for token in query:gmatch("%S+") do tokens[#tokens + 1] = token end
	local function Matches(text)
		text = text:lower()
		for _, token in ipairs(tokens) do if not text:find(token, 1, true) then return false end end
		return true
	end
	searchResults = {}
	for _, nc in ipairs(navCats) do
		for _, m in ipairs(nc.modules) do
			local index = searchIndexes[m.key]
			if not index then
				index = UI.NewSearchBuilder(m, PAGE_WIDTH)
				if m.BuildOptions then m:BuildOptions(index) end
				searchIndexes[m.key] = index
			end
			local path = ns:SettingsPath(m.key)
			local entries = index.searchEntries
			for _, entry in ipairs(entries) do
				local label = PlainText(entry.label)
				local detail = PlainText(entry.text)
				local keywords = entry.keywords and PlainText(entry.keywords()) or ""
				local entryPath = path .. (entry.section and " > " .. PlainText(entry.section) or "")
				if Matches(label .. " " .. detail .. " " .. keywords .. " " .. entryPath) then
					local priority = Matches(label) and 0 or (Matches(detail .. " " .. keywords) and 1 or 2)
					if entry.type == "description" then priority = priority + 3 end
					searchResults[#searchResults + 1] = { module = m, entry = entry, label = label,
						detail = detail ~= "" and detail or keywords, path = entryPath, priority = priority,
						order = #searchResults + 1 }
				end
			end
			if #entries == 0 and Matches(path) then
				searchResults[#searchResults + 1] = { module = m, label = m.title, detail = "기능 설정 열기",
					path = path, priority = 2, order = #searchResults + 1 }
			end
		end
	end
	table.sort(searchResults, function(a, b)
		if a.priority ~= b.priority then return a.priority < b.priority end
		return a.order < b.order
	end)
	ShowSearchResults()
end

local function CreateWindow()
	local w = ns.db.window
	window = CreateFrame("Frame", "EzyWOWFWindow", UIParent, "BackdropTemplate")
	window:SetSize(WIDTH, HEIGHT)
	window:SetFrameStrata("HIGH")
	window:SetToplevel(true)
	window:SetMovable(true)
	window:EnableMouse(true)
	window:SetClampedToScreen(true)
	UI.ApplySettingsFrame(window)
	window:Hide()
	tinsert(UISpecialFrames, "EzyWOWFWindow")
	if w.point then window:SetPoint(w.point, UIParent, w.relPoint, w.x, w.y) else window:SetPoint("CENTER") end

	local titleBar = CreateFrame("Frame", nil, window)
	titleBar:SetFrameLevel(window:GetFrameLevel() + 1)
	titleBar:SetPoint("TOPLEFT", 1, -1)
	titleBar:SetPoint("TOPRIGHT", -1, -1)
	titleBar:SetHeight(TITLE_HEIGHT)
	titleBar:EnableMouse(true)
	titleBar:RegisterForDrag("LeftButton")
	titleBar:SetScript("OnDragStart", function() window:StartMoving() end)
	titleBar:SetScript("OnDragStop", function() window:StopMovingOrSizing() SavePosition() end)
	-- Keep the title background below the border without lowering drag input.
	local titleBg = window:CreateTexture(nil, "BACKGROUND")
	titleBg:SetAllPoints(titleBar)
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
	title:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
	title:SetText(ns.title .. " 설정")
	UI.ColorText(title, Theme.accent)
	local version = titleBar:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	version:SetPoint("LEFT", titleIcon, "RIGHT", 7, 0)
	version:SetText("v" .. ns.version)
	local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
	close:SetFrameLevel(titleBar:GetFrameLevel() + 1)
	close:SetSize(26, 26)
	close:SetPoint("TOPRIGHT", -3, -3)

	searchBox = CreateFrame("EditBox", "EzyWOWFSettingsSearch", window, "BackdropTemplate")
	searchBox:SetSize(320, 26)
	searchBox:SetPoint("TOPRIGHT", -40, -(TITLE_HEIGHT + 6))
	UI.ApplySettingsInset(searchBox)
	searchBox:SetTextInsets(26, 26, 0, 0)
	local searchIcon = searchBox:CreateTexture(nil, "ARTWORK")
	searchIcon:SetSize(10, 10)
	searchIcon:SetPoint("LEFT", 8, 0)
	UI.SetAtlas(searchIcon, "common-search-magnifyingglass", "Interface\\Icons\\INV_Misc_Spyglass_02")
	searchBox:SetFontObject(ChatFontNormal)
	searchBox:SetAutoFocus(false)
	searchBox:SetMaxLetters(100)
	searchHint = searchBox:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	searchHint:SetPoint("LEFT", 26, 0)
	searchHint:SetText("옵션 검색 (이름·설명·메뉴)")
	clearSearch = CreateFrame("Button", nil, searchBox)
	clearSearch:SetSize(22, 22)
	clearSearch:SetPoint("RIGHT", -2, 0)
	clearSearch.text = clearSearch:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	clearSearch.text:SetPoint("CENTER")
	clearSearch.text:SetText("×")
	UI.ColorText(clearSearch.text, Theme.accent)
	local clearIcon = clearSearch:CreateTexture(nil, "ARTWORK")
	clearIcon:SetPoint("CENTER")
	clearIcon:SetSize(10, 10)
	if UI.SetAtlas(clearIcon, "common-search-clearbutton") then clearSearch.text:Hide() else clearIcon:Hide() end
	clearSearch:SetScript("OnClick", function() searchBox:SetText("") RunSearch() searchBox:SetFocus() end)
	backToResults = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	backToResults:SetSize(150, 24)
	backToResults:SetPoint("RIGHT", searchBox, "LEFT", -8, 0)
	backToResults:SetText("검색 결과로 돌아가기")
	backToResults:SetScript("OnClick", RunSearch)
	searchBox:SetScript("OnTextChanged", function(_, userInput) if userInput then RunSearch() end end)
	searchBox:SetScript("OnEditFocusGained", RefreshSearchControls)
	searchBox:SetScript("OnEditFocusLost", RefreshSearchControls)
	searchBox:SetScript("OnEscapePressed", function()
		if Query() ~= "" then searchBox:SetText("") RunSearch() else searchBox:ClearFocus() end
	end)
	searchBox:SetScript("OnEnterPressed", function()
		if Query() == "" then searchBox:ClearFocus() return end
		RunSearch()
		if searchResults[1] then SelectModule(searchResults[1].module.key, searchResults[1].entry) end
	end)

	local top = TITLE_HEIGHT + TOOLBAR_HEIGHT + 8
	local nav = CreateFrame("Frame", nil, window, "BackdropTemplate")
	nav:SetPoint("TOPLEFT", 8, -top)
	nav:SetPoint("BOTTOMLEFT", 8, FOOTER_HEIGHT)
	nav:SetWidth(NAV_WIDTH)
	UI.ApplySettingsInset(nav, Theme.settingsInset)
	local contentPanel = CreateFrame("Frame", nil, window, "BackdropTemplate")
	contentPanel:SetPoint("TOPLEFT", nav, "TOPRIGHT", 8, 0)
	contentPanel:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -8, FOOTER_HEIGHT)
	contentPanel:SetFrameLevel(window:GetFrameLevel())
	contentPanel:EnableMouse(false)
	UI.ApplySettingsInset(contentPanel, Theme.settingsInset)
	local navBg = nav:CreateTexture(nil, "BACKGROUND")
	navBg:SetAllPoints()
	UI.ColorTexture(navBg, Theme.panel)
	navArea = UI.CreateScrollArea(nav)
	navArea.scroll:SetPoint("TOPLEFT", 4, -4)
	navArea.scroll:SetPoint("BOTTOMRIGHT", -12, 4)
	navChild = CreateFrame("Frame", nil, navArea.scroll)
	navChild:SetSize(NAV_WIDTH - 16, 1)
	navArea.scroll:SetScrollChild(navChild)
	tabHost = CreateFrame("Frame", nil, window)
	tabHost:SetPoint("TOPLEFT", nav, "TOPRIGHT", 8, 0)
	tabHost:SetPoint("TOPRIGHT", window, "TOPRIGHT", -20, -top)

	for _, cat in ipairs(ns.categories) do
		local modules = ns:ModulesInCategory(cat.key)
		if #modules > 0 then
			local row = CreateMenuButton(navChild, cat.title, cat.icon, true)
			row:SetPoint("TOPLEFT", navChild, "TOPLEFT", 0, -#navCats * NAV_ROW_H)
			row:SetScript("OnClick", function() SelectModule(cat.key) end)
			categoryRows[cat.key] = row
			navCats[#navCats + 1] = { cat = cat, modules = modules }
			for _, m in ipairs(modules) do
				local tab = CreateMenuButton(tabHost, m.title, m.icon, false)
				tab:SetScript("OnClick", function() SelectModule(m.key) end)
				tab:Hide()
				moduleTabs[m.key] = tab
			end
		end
	end
	navChild:SetHeight(math.max(#navCats * NAV_ROW_H, 1))
	navArea:SetContentHeight(navChild:GetHeight())
	banner = CreateBanner(window)
	banner:SetPoint("TOPLEFT", tabHost, "BOTTOMLEFT", 0, -4)
	banner:SetPoint("TOPRIGHT", tabHost, "BOTTOMRIGHT", 0, -4)
	pageArea = UI.CreateScrollArea(window)
	pageArea.scroll:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 0, -4)
	pageArea.scroll:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -20, FOOTER_HEIGHT)
	searchChild = CreateFrame("Frame", nil, pageArea.scroll)
	searchChild:SetSize(PAGE_WIDTH, 72)
	searchChild:Hide()
	searchEmpty = searchChild:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	searchEmpty:SetPoint("TOPLEFT", 16, -20)
	searchEmpty:SetWidth(PAGE_WIDTH - 32)
	searchEmpty:SetJustifyH("LEFT")
	searchEmpty:SetText("일치하는 옵션이 없습니다. 다른 단어나 짧은 키워드로 검색해 보세요.")
	pageArea.bar:HookScript("OnValueChanged", LayoutResultRows)
	function pageArea:OnSizeChanged() LayoutResultRows() end

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
		if target then SelectModule(target)
		elseif showingResults then RunSearch()
		elseif not selectedKey then SelectModule(nil)
		elseif not pages[selectedKey] then ShowPage(selectedKey)
		else Refresh() end
	end)
	window:SetScript("OnHide", function()
		searchBox:ClearFocus()
		if ns:HasPending() then StaticPopup_Show("EZYWOWF_UNSAVED") end
	end)
end

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
	if window and window:IsShown() then window:Hide() else self:OpenWindow() end
end

function EzyWOWF_ToggleWindow() ns:ToggleWindow() end

local function RebuildPages()
	searchIndexes = {}
	if optionFocus then optionFocus:Hide() end
	for key, page in pairs(pages) do page.frame:Hide() pages[key] = nil end
	if not (window and window:IsShown()) then return end
	if showingResults then RunSearch() elseif selectedKey then ShowPage(selectedKey) end
end
ns:On("FONTS_CHANGED", function()
	for _, tab in pairs(moduleTabs) do tab:SetWidth(math.min(PAGE_WIDTH, tab.text:GetStringWidth() + 50)) end
	RebuildPages()
end)
ns:On("REBUILD_OPTIONS", RebuildPages)
ns:On("PENDING_CHANGED", Refresh)
ns:On("REFRESH_UI", Refresh)
ns:RegisterEvent("UPDATE_BINDINGS", Refresh)
