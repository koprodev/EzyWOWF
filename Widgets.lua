-- 설정 페이지용 컨트롤 모음.
-- 모듈의 BuildOptions(b)에서 위에서 아래로 쌓아 나간다.
--   b:Header(text)
--   b:Text(text | function, { font=, color=, indent= })
--   b:Check{ key=, label=, tooltip=, depends= }   켜짐/꺼짐 스위치. [저장]을 눌러야 반영된다.
--   b:CheckGrid{ label=, items={ { key=, text=, icon=, title=, tooltip= }, ... }, columns=, depends= }
--     네모 체크박스를 한 줄에 columns개(기본: 전부)씩 늘어놓는다. 항목마다 설정 키 하나, [저장]을 눌러야 반영된다.
--   b:Slider{ key=, label=, min=, max=, step=, format=, depends= }
--   b:KeyBind{ command=, label=, depends= }
--   b:Buttons{ { text=, textFunc=, onClick=, disabled=, tooltip=, width= }, ... }
--   b:OnOff{ label=, tooltip=, isOn=function, onOn=function, onOff=function, disabled=function }
--     한 줄에 "이름 | 현재: 켜짐/꺼짐 | [켜기] [끄기]". 저장 없이 바로 실행된다.
--   b:Dropdown{ key= 또는 get=/set=, label=, options=function, emptyText=, width=, tooltip=, depends= }
--     options는 { { value=, text= }, ... }를 돌려주는 함수. 목록이 비면 emptyText를 보여 주고 막는다.
-- key 로 지정한 값은 바로 저장되지 않고 [저장]을 눌러야 반영된다.
-- depends 에 설정 키(또는 키 목록)를 주면 그 설정이 꺼져 있을 때 컨트롤이 비활성화된다.
-- 글 입력 창: UI.ShowTextDialog{ title=, help=, text=, readOnly=, button=, onAccept=function(text) return ok, msg end }
-- 스크롤 영역: UI.CreateScrollArea(parent) → area.scroll / area.bar / area:SetContentHeight(h) / area:ScrollTo(y)

local _, ns = ...

local UI = {}
ns.UI = UI

-- 색·테두리는 전부 여기서 고른다. 색은 {r, g, b[, a]}, 쓸 때는 UI.Color*로 풀어서 넘긴다.
local Theme = {
	accent    = { 1, 0.82, 0 },
	bg        = { 0.07, 0.08, 0.09, 0.96 },
	settingsBg    = { 0.07, 0.08, 0.09, 0.78 },
	settingsInset = { 0.045, 0.04, 0.025, 0.08 },
	settingsInput = { 0.045, 0.04, 0.025, 0.6 },
	titleBg   = { 0.10, 0.075, 0.035, 0.95 },
	border    = { 0.42, 0.32, 0.16, 1 },
	panel     = { 0.08, 0.06, 0.03, 0.28 },
	line      = { 0.72, 0.56, 0.25, 0.24 },
	hover     = { 1, 0.82, 0, 0.10 },
	selected  = { 1, 0.82, 0, 0.15 },
	header    = { 1, 1, 1 },
	pending   = { 1, 0.6, 0.2 },
	disabled  = { 0.5, 0.5, 0.5 },
	normal    = { 1, 0.82, 0 },
	muted     = { 0.65, 0.62, 0.55 },
	switchOff = { 0.30, 0.30, 0.34 },
	knob      = { 0.96, 0.96, 0.96 },
	track     = { 0.3, 0.24, 0.12, 0.3 },
	thumb     = { 0.72, 0.56, 0.25, 0.9 },
}
UI.Theme = Theme

local WHITE = "Interface\\Buttons\\WHITE8x8"

function UI.ColorTexture(tex, c, alpha)
	tex:SetColorTexture(c[1], c[2], c[3], alpha or c[4] or 1)
end

function UI.ColorText(fs, c)
	fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
end

-- 평면 패널: 1px 테두리 + 배경
function UI.ApplyPanelBackdrop(frame, bg, border)
	bg, border = bg or Theme.bg, border or Theme.border
	frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
	frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
	frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end

local atlasInfoCache = {}
local nativeErrors = {}

local function ReportNativeError(owner, field, err)
	local message = tostring(err)
	owner[field] = message
	if not nativeErrors[message] then
		nativeErrors[message] = true
		if type(ns.ErrorHandler) == "function" then ns.ErrorHandler(message) end
	end
end

function UI.SetAtlas(texture, atlas, fallbackPath)
	if type(atlas) ~= "string" or atlas == "" then
		texture:SetTexture(fallbackPath)
		return false
	end
	local info = atlasInfoCache[atlas]
	if info == nil then
		if C_Texture and type(C_Texture.GetAtlasInfo) == "function" then
			local ok, result = pcall(C_Texture.GetAtlasInfo, atlas)
			if ok then info = result else ReportNativeError(texture, "settingsAtlasError", result) end
		end
		info = type(info) == "table" and info or false
		atlasInfoCache[atlas] = info
	end
	if info and type(texture.SetAtlas) == "function" then
		local ok, err = pcall(texture.SetAtlas, texture, atlas)
		if ok then return true end
		ReportNativeError(texture, "settingsAtlasError", err)
		atlasInfoCache[atlas] = false
	end
	texture:SetTexture(fallbackPath)
	return false
end

local function ApplySettingsBorder(frame, layout)
	if not (NineSliceUtil and type(NineSliceUtil.ApplyLayoutByName) == "function") then return false end
	local nine = frame.NineSlice
	if not nine then
		if type(CreateFrame) ~= "function" then return false end
		local ok, created = pcall(CreateFrame, "Frame", nil, frame, "NineSlicePanelTemplate")
		if not ok then
			ReportNativeError(frame, "settingsBorderError", created)
			return false
		end
		if not created then return false end
		nine = created
		frame.NineSlice = nine
	end
	nine:SetAllPoints(frame)
	local level = frame:GetFrameLevel()
	if type(level) == "number" then nine:SetFrameLevel(level) end
	nine:EnableMouse(false)
	local ok, err = pcall(NineSliceUtil.ApplyLayoutByName, nine, layout)
	if not ok then
		nine:Hide()
		ReportNativeError(frame, "settingsBorderError", err)
		return false
	end
	frame:SetBackdropBorderColor(0, 0, 0, 0)
	nine:Show()
	return true
end

function UI.ApplySettingsFrame(frame)
	UI.ApplyPanelBackdrop(frame, Theme.settingsBg)
	return ApplySettingsBorder(frame, "ButtonFrameTemplateNoPortrait")
end

function UI.ApplySettingsInset(frame, bg)
	UI.ApplyPanelBackdrop(frame, bg or Theme.settingsInput, Theme.border)
	return ApplySettingsBorder(frame, "InsetFrameTemplate")
end

function UI.ApplyTabArt(button)
	if button.settingsTabArt then return end
	local left = button:CreateTexture(nil, "BACKGROUND")
	left:SetWidth(16)
	left:SetPoint("TOPLEFT")
	left:SetPoint("BOTTOMLEFT")
	local right = button:CreateTexture(nil, "BACKGROUND")
	right:SetWidth(16)
	right:SetPoint("TOPRIGHT")
	right:SetPoint("BOTTOMRIGHT")
	local middle = button:CreateTexture(nil, "BACKGROUND")
	middle:SetPoint("TOPLEFT", left, "TOPRIGHT")
	middle:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT")
	button.settingsTabArt = { left, middle, right }
	function button:PaintTab(selected)
		local prefix = selected and "uiframe-activetab-" or "uiframe-tab-"
		local center = selected and "_uiframe-activetab-center" or "_uiframe-tab-center"
		for i, atlas in ipairs({ prefix .. "left", center, prefix .. "right" }) do
			local texture = self.settingsTabArt[i]
			if not UI.SetAtlas(texture, atlas) then UI.ColorTexture(texture, selected and Theme.selected or Theme.panel) end
		end
	end
	button:PaintTab(false)
end

local PADDING = 16
local ROW_GAP = 8
local CONTROL_COLUMN = 264

local function ControlOffset(width, indent)
	return math.max(36, math.min(CONTROL_COLUMN - (indent or 0), width - 34))
end
local PENDING_COLOR = Theme.pending
local DISABLED_COLOR = Theme.disabled
local NORMAL_COLOR = Theme.normal

local SLIDER_BACKDROP = {
	bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
	edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
	tile = true, tileSize = 8, edgeSize = 8,
	insets = { left = 3, right = 3, top = 6, bottom = 6 },
}

local function AttachTooltip(frame, title, text)
	if not text then return end
	frame:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title, 1, 0.82, 0)
		GameTooltip:AddLine(text, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	frame:HookScript("OnLeave", GameTooltip_Hide)
end

local function PlayClick(on)
	if SOUNDKIT then
		PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
	end
end

---------------------------------------------------------------------------
-- 빌더
---------------------------------------------------------------------------
local Builder = {}
Builder.__index = Builder

function UI.NewBuilder(page, module, width)
	return setmetatable({ page = page, module = module, width = width, y = -PADDING, controls = {}, searchEntries = {} }, Builder)
end

function Builder:Place(region, height, indent, gap)
	-- Keep page-relative offsets available while the page is hidden.
	region.settingsY = -self.y
	region.settingsHeight = height
	region:SetPoint("TOPLEFT", self.page, "TOPLEFT", PADDING + (indent or 0), self.y)
	self.y = self.y - height - (gap or ROW_GAP)
	return region
end

function Builder:SearchEntry(region, label, text, keywords, y, height)
	local entry = {
		label = label or self.section or self.module.title,
		text = text or "",
		section = self.section,
		sectionY = self.sectionY,
		index = #self.searchEntries + 1,
		sectionIndex = self.sectionIndex,
		indexOnly = self.searchOnly or nil,
		y = y or (region and region.settingsY) or 0,
		height = height or (region and region.settingsHeight) or 1,
		region = region,
		keywords = keywords,
	}
	self.searchEntries[#self.searchEntries + 1] = entry
	return entry
end

local function DropdownKeywords(opts)
	return function()
		local texts = {}
		for _, option in ipairs(opts.options() or {}) do texts[#texts + 1] = option.text or "" end
		return table.concat(texts, "\n")
	end
end

-- Reuse option declarations without creating frames or evaluating live status text.
local SearchBuilder = {}
SearchBuilder.__index = SearchBuilder
SearchBuilder.SearchEntry = Builder.SearchEntry

function UI.NewSearchBuilder(module, width)
	return setmetatable({ module = module, width = width, searchOnly = true, searchEntries = {} }, SearchBuilder)
end

function SearchBuilder:Header(text)
	self.section = text
	local entry = self:SearchEntry(nil, text)
	self.sectionIndex = entry.index
	entry.sectionIndex = entry.index
	entry.type = "section"
	return entry
end

function SearchBuilder:Text(text)
	if type(text) == "string" then
		local entry = self:SearchEntry(nil, self.section or self.module.title, text)
		entry.type = "description"
		return entry
	end
end

function SearchBuilder:Option(opts)
	return self:SearchEntry(nil, opts.label, opts.tooltip)
end
SearchBuilder.Check = SearchBuilder.Option
SearchBuilder.Slider = SearchBuilder.Option
SearchBuilder.OnOff = SearchBuilder.Option

function SearchBuilder:KeyBind(opts)
	return self:SearchEntry(nil, opts.label, opts.tooltip or "단축키")
end

function SearchBuilder:CheckGrid(opts)
	for _, item in ipairs(opts.items) do
		local text = table.concat({ opts.label or "", item.text or "", item.tooltip or "" }, "\n")
		self:SearchEntry(nil, item.title or item.text or opts.label, text)
	end
end

function SearchBuilder:Buttons(list)
	for _, def in ipairs(list) do self:SearchEntry(nil, def.text, def.tooltip, def.textFunc) end
end

function SearchBuilder:Dropdown(opts)
	return self:SearchEntry(nil, opts.label, opts.tooltip, DropdownKeywords(opts))
end

function Builder:Track(control)
	self.controls[#self.controls + 1] = control
	return control
end

function Builder:Height()
	return -self.y + PADDING
end

function Builder:Refresh()
	for _, control in ipairs(self.controls) do
		control:Refresh()
	end
end

function Builder:Get(opts)
	if opts.get then return opts.get() end
	return ns:GetSetting(self.module, opts.key)
end

function Builder:Set(opts, value)
	if opts.set then return opts.set(value) end
	ns:SetSetting(self.module, opts.key, value)
end

function Builder:IsDisabled(opts)
	local depends = opts.depends
	if type(depends) == "string" then depends = { depends } end
	if depends then
		for _, key in ipairs(depends) do
			if not ns:GetSetting(self.module, key) then return true end
		end
	end
	return opts.disabled ~= nil and opts.disabled() or false
end

function Builder:LabelColor(opts, pendingFlag)
	if self:IsDisabled(opts) then return DISABLED_COLOR end
	if pendingFlag then return PENDING_COLOR end
	return NORMAL_COLOR
end

---------------------------------------------------------------------------
-- 제목 / 글
---------------------------------------------------------------------------
-- 페이지 제목은 창 위쪽 배너가 맡고, 여기 제목은 페이지 안의 소제목이다.
function Builder:Header(text)
	self.section = text
	if self.y < -PADDING then self.y = self.y - 10 end
	local fs = self.page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	fs:SetText(text)
	UI.ColorText(fs, Theme.header)
	self:Place(fs, math.max(fs:GetStringHeight() or 0, 16), 0, 4)
	self.sectionY = fs.settingsY
	local entry = self:SearchEntry(fs, text)
	self.sectionIndex = entry.index
	entry.sectionIndex = entry.index
	entry.type = "section"

	local line = self.page:CreateTexture(nil, "ARTWORK")
	UI.ColorTexture(line, Theme.accent, 0.3)
	line:SetSize(self.width - PADDING * 2, 1)
	self:Place(line, 1, 0, 10)
	return fs
end

function Builder:Text(text, opts)
	opts = opts or {}
	local fs = self.page:CreateFontString(nil, "ARTWORK", opts.font or "GameFontHighlightSmall")
	fs:SetWidth(self.width - PADDING * 2 - (opts.indent or 0))
	fs:SetJustifyH("LEFT")
	fs:SetSpacing(2)
	if opts.color then fs:SetTextColor(unpack(opts.color)) end

	if type(text) == "function" then
		function fs:Refresh() self:SetText(text()) end
		fs:Refresh()
		self:Track(fs)
	else
		fs:SetText(text)
	end
	self:Place(fs, math.max(fs:GetStringHeight() or 0, 14), opts.indent)
	if type(text) == "string" then
		self:SearchEntry(fs, self.section or self.module.title, text).type = "description"
	end
	return fs
end

---------------------------------------------------------------------------
-- 켜짐/꺼짐 스위치 (CheckButton 기반. 값은 [저장]을 눌러야 반영)
---------------------------------------------------------------------------
local CHECKBOX_FILES = {
	normal = "Interface\\Buttons\\UI-CheckBox-Up",
	pushed = "Interface\\Buttons\\UI-CheckBox-Down",
	highlight = "Interface\\Buttons\\UI-CheckBox-Highlight",
	checked = "Interface\\Buttons\\UI-CheckBox-Check",
	disabled = "Interface\\Buttons\\UI-CheckBox-Check-Disabled",
}

local function SetCheckboxArt(texture, state)
	local atlas = state == "disabled" and "checkmark-minimal-disabled" or (state == "checked" and "checkmark-minimal" or "checkbox-minimal")
	UI.SetAtlas(texture, atlas, CHECKBOX_FILES[state])
end

function Builder:Check(opts)
	local b = self
	local width = b.width - PADDING * 2 - (opts.indent or 0)
	local column = ControlOffset(width, opts.indent)
	local sw = CreateFrame("CheckButton", nil, b.page)
	sw.settingsControlX = column
	sw:SetHitRectInsets(0, 0, 0, 0)

	local label = sw:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	label:SetPoint("LEFT", 4, 0)
	label:SetWidth(math.max(24, column - 16))
	label:SetJustifyH("LEFT")
	label:SetWordWrap(true)
	label:SetText(opts.label)
	sw.settingsLabel = label

	local normal = sw:CreateTexture(nil, "BACKGROUND")
	local pushed = sw:CreateTexture(nil, "BACKGROUND")
	local highlight = sw:CreateTexture(nil, "HIGHLIGHT")
	local checked = sw:CreateTexture(nil, "ARTWORK")
	local disabled = sw:CreateTexture(nil, "ARTWORK")
	SetCheckboxArt(normal, "normal")
	SetCheckboxArt(pushed, "pushed")
	SetCheckboxArt(highlight, "highlight")
	SetCheckboxArt(checked, "checked")
	SetCheckboxArt(disabled, "disabled")
	highlight:SetBlendMode("ADD")
	sw:SetNormalTexture(normal)
	sw:SetPushedTexture(pushed)
	sw:SetHighlightTexture(highlight)
	sw:SetCheckedTexture(checked)
	sw:SetDisabledCheckedTexture(disabled)
	for _, texture in ipairs({ normal, pushed, highlight, checked, disabled }) do
		texture:ClearAllPoints()
		texture:SetSize(30, 29)
		texture:SetPoint("LEFT", sw, "LEFT", column, 0)
	end
	sw.settingsNormal, sw.settingsChecked, sw.settingsDisabledChecked = normal, checked, disabled

	local function Paint(enabled, pending)
		for _, texture in ipairs({ normal, pushed, highlight, checked }) do
			texture:SetDesaturated(not enabled)
			texture:SetAlpha(enabled and 1 or 0.4)
		end
		normal:SetVertexColor(unpack(pending and enabled and PENDING_COLOR or { 1, 1, 1 }))
		label:SetTextColor(unpack(b:LabelColor(opts, pending)))
	end

	sw:SetScript("OnClick", function(self)
		local on = self:GetChecked() and true or false
		PlayClick(on)
		b:Set(opts, on)
		Paint(true, opts.key and ns:IsPending(b.module, opts.key))
	end)
	AttachTooltip(sw, opts.label, opts.tooltip)

	function sw:Refresh()
		self:SetChecked(b:Get(opts) and true or false)
		local enabled = not b:IsDisabled(opts)
		self:SetEnabled(enabled)
		Paint(enabled, opts.key and ns:IsPending(b.module, opts.key))
	end

	local height = math.max((label:GetStringHeight() or 0) + 4, 29)
	sw:SetSize(width, height)
	b:Place(sw, height, opts.indent, 4)
	b:SearchEntry(sw, opts.label, opts.tooltip)
	return b:Track(sw)
end

---------------------------------------------------------------------------
-- 체크박스 격자 (항목마다 켜짐/꺼짐 하나. 값은 [저장]을 눌러야 반영)
---------------------------------------------------------------------------
local BOX, ICON = 18, 16

local function ShowCellTooltip(cell)
	GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
	GameTooltip:SetText(cell.tipTitle, 1, 0.82, 0)
	if cell.tipText then GameTooltip:AddLine(cell.tipText, 1, 1, 1, true) end
	GameTooltip:Show()
end

function Builder:CheckGrid(opts)
	local b = self
	local width = b.width - PADDING * 2 - (opts.indent or 0)
	local columns = math.max(1, opts.columns or #opts.items)
	local cellW = math.floor(width / columns)

	local grid = CreateFrame("Frame", nil, b.page)
	local top = 0
	local title
	if opts.label then
		title = grid:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		title:SetPoint("TOPLEFT", 4, 0)
		title:SetText(opts.label)
		top = math.max(title:GetStringHeight() or 0, 14) + 6
	end

	local cells = {}
	local rowH = 22
	for i, item in ipairs(opts.items) do
		local cell = CreateFrame("CheckButton", nil, grid)

		local box = cell:CreateTexture(nil, "BACKGROUND")   -- 테두리 겸 바탕
		box:SetSize(BOX, BOX)
		box:SetPoint("LEFT", 4, 0)
		SetCheckboxArt(box, "normal")
		local fill = cell:CreateTexture(nil, "BORDER")
		fill:SetPoint("TOPLEFT", box, "TOPLEFT", 1, -1)
		fill:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -1, 1)
		fill:SetAlpha(0)
		local mark = cell:CreateTexture(nil, "ARTWORK")
		mark:SetSize(BOX + 6, BOX + 6)   -- 체크 그림은 가장자리가 비어 있어서 상자보다 살짝 크게
		mark:SetPoint("CENTER", box, "CENTER", 1, 0)
		SetCheckboxArt(mark, "checked")
		local hover = cell:CreateTexture(nil, "HIGHLIGHT")
		hover:SetAllPoints(box)
		UI.ColorTexture(hover, Theme.hover)

		-- 아이콘은 글자 속 |T|t가 아니라 따로 그린다. 글자색이 안 먹어서 막힘을 흐리게 못 보여 주니까.
		local icon
		if item.icon then
			icon = cell:CreateTexture(nil, "ARTWORK")
			icon:SetSize(ICON, ICON)
			icon:SetPoint("LEFT", box, "RIGHT", 6, 0)
			icon:SetTexture(item.icon)
		end

		local label = cell:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		label:SetPoint("LEFT", icon or box, "RIGHT", icon and 4 or 6, 0)
		label:SetPoint("RIGHT", cell, "RIGHT", -2, 0)
		label:SetJustifyH("LEFT")
		label:SetWordWrap(false)
		label:SetText(item.text or "")
		rowH = math.max(rowH, (label:GetStringHeight() or 0) + 6)
		-- 칸이 넓어도 상자·아이콘·글자 위에서만 눌린다
		local right = 4 + BOX + 6 + (icon and ICON or 0)
		if item.text then right = right + (icon and 4 or 0) + (label:GetStringWidth() or 0) end
		cell:SetHitRectInsets(0, math.max(0, cellW - right - 4), 0, 0)

		local itemOpts = { key = item.key, depends = opts.depends, disabled = opts.disabled }
		-- Tint the native border so icon-only cells also show pending changes.
		local function Paint(on, enabled, pending)
			local alpha = enabled and 1 or 0.35
			local ring = pending and enabled
			box:SetVertexColor(unpack(ring and PENDING_COLOR or { 1, 1, 1 }))
			box:SetDesaturated(not enabled)
			box:SetAlpha(alpha)
			SetCheckboxArt(mark, enabled and "checked" or "disabled")
			mark:SetVertexColor(1, 1, 1, alpha)
			mark:SetShown(on)
			if icon then
				icon:SetDesaturated(not enabled)
				icon:SetAlpha(alpha)
			end
		end

		cell:SetScript("OnClick", function(self)
			local on = self:GetChecked() and true or false
			PlayClick(on)
			b:Set(itemOpts, on)
			Paint(on, true, ns:IsPending(b.module, item.key))
		end)
		cell.tipTitle = item.title or item.text
		cell.tipText = item.tooltip
		if cell.tipTitle then
			cell:SetScript("OnEnter", ShowCellTooltip)
			cell:SetScript("OnLeave", GameTooltip_Hide)
		end

		function cell:Refresh(enabled)
			local on = b:Get(itemOpts) and true or false
			self:SetChecked(on)
			self:SetEnabled(enabled)
			local pending = ns:IsPending(b.module, item.key)
			Paint(on, enabled, pending)
			label:SetTextColor(unpack(b:LabelColor(itemOpts, pending)))
		end

		cells[i] = cell
	end

	for i, cell in ipairs(cells) do
		local col, row = (i - 1) % columns, math.floor((i - 1) / columns)
		cell:SetSize(cellW, rowH)
		cell:SetPoint("TOPLEFT", grid, "TOPLEFT", col * cellW, -(top + row * rowH))
	end

	function grid:Refresh()
		local enabled = not b:IsDisabled(opts)
		if title then title:SetTextColor(unpack(enabled and NORMAL_COLOR or DISABLED_COLOR)) end
		for _, cell in ipairs(cells) do cell:Refresh(enabled) end
	end

	local height = top + math.ceil(#cells / columns) * rowH
	grid:SetSize(width, height)
	b:Place(grid, height, opts.indent, ROW_GAP)
	for i, cell in ipairs(cells) do
		local item = opts.items[i]
		local y = grid.settingsY + top + math.floor((i - 1) / columns) * rowH
		local text = table.concat({ opts.label or "", item.text or "", item.tooltip or "" }, "\n")
		b:SearchEntry(cell, item.title or item.text or opts.label, text, nil, y, rowH)
	end
	return b:Track(grid)
end

---------------------------------------------------------------------------
-- 슬라이더
---------------------------------------------------------------------------
function Builder:Slider(opts)
	local b = self
	local fmt = opts.format or "%s"
	local step = opts.step or 1
	local width = b.width - PADDING * 2 - (opts.indent or 0)
	local column = ControlOffset(width, opts.indent)
	local holder = CreateFrame("Frame", nil, b.page)

	local label = holder:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	label:SetPoint("LEFT", 4, 0)
	label:SetWidth(math.max(24, column - 16))
	label:SetJustifyH("LEFT")
	label:SetWordWrap(true)
	label:SetText(opts.label)
	holder.settingsLabel = label

	local valueText = holder:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	valueText:SetPoint("RIGHT", -2, 5)
	valueText:SetWidth(64)
	valueText:SetJustifyH("RIGHT")

	local slider = CreateFrame("Slider", nil, holder, "BackdropTemplate")
	slider:SetOrientation("HORIZONTAL")
	slider:SetSize(math.max(80, math.min(240, width - column - 76)), 19)
	slider:SetPoint("LEFT", holder, "LEFT", column, 5)
	slider:SetHitRectInsets(0, 0, -6, -6)
	slider:SetBackdrop(SLIDER_BACKDROP)
	slider:SetMinMaxValues(opts.min, opts.max)
	slider:SetValueStep(step)
	slider:SetObeyStepOnDrag(true)
	holder.settingsSlider = slider

	local left = slider:CreateTexture(nil, "BACKGROUND")
	left:SetSize(12, 19)
	left:SetPoint("LEFT")
	local right = slider:CreateTexture(nil, "BACKGROUND")
	right:SetSize(12, 19)
	right:SetPoint("RIGHT")
	local middle = slider:CreateTexture(nil, "BACKGROUND")
	middle:SetPoint("TOPLEFT", left, "TOPRIGHT")
	middle:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT")
	local nativeLeft = UI.SetAtlas(left, "Minimal_SliderBar_Left")
	local nativeRight = UI.SetAtlas(right, "Minimal_SliderBar_Right")
	local nativeMiddle = UI.SetAtlas(middle, "_Minimal_SliderBar_Middle")
	if nativeLeft and nativeRight and nativeMiddle then slider:SetBackdrop(nil) end

	local thumb = slider:CreateTexture(nil, "ARTWORK")
	local nativeThumb = UI.SetAtlas(thumb, "Minimal_SliderBar_Button", "Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	local thumbInfo = nativeThumb and atlasInfoCache.Minimal_SliderBar_Button
	thumb:SetSize(thumbInfo and thumbInfo.width or 32, thumbInfo and thumbInfo.height or 32)
	slider:SetThumbTexture(thumb)
	slider.settingsThumb = thumb

	local low = holder:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	low:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 2, 0)
	low:SetText(fmt:format(opts.min))
	local high = holder:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	high:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", -2, 0)
	high:SetText(fmt:format(opts.max))

	local function Snap(value)
		return tonumber(("%.4g"):format(math.floor(value / step + 0.5) * step))
	end

	local refreshing = false
	slider:SetScript("OnValueChanged", function(_, value)
		value = Snap(value)
		valueText:SetText(fmt:format(value))
		if not refreshing then b:Set(opts, value) end
	end)
	AttachTooltip(slider, opts.label, opts.tooltip)

	function holder:Refresh()
		local value = b:Get(opts)
		refreshing = true
		slider:SetValue(value)
		refreshing = false
		valueText:SetText(fmt:format(value))
		local enabled = not b:IsDisabled(opts)
		slider:SetEnabled(enabled)
		for _, texture in ipairs({ left, middle, right, thumb }) do
			texture:SetDesaturated(not enabled)
			texture:SetAlpha(enabled and 1 or 0.4)
		end
		local color = b:LabelColor(opts, opts.key and ns:IsPending(b.module, opts.key))
		label:SetTextColor(unpack(color))
		valueText:SetTextColor(unpack(color))
	end

	local height = math.max((label:GetStringHeight() or 0) + 4, 44)
	holder:SetSize(width, height)
	b:Place(holder, height, opts.indent)
	b:SearchEntry(holder, opts.label, opts.tooltip)
	return b:Track(holder)
end

---------------------------------------------------------------------------
-- 단축키 지정 버튼
---------------------------------------------------------------------------
local MODIFIER_KEYS = {
	LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
	LALT = true, RALT = true, LMETA = true, RMETA = true, UNKNOWN = true,
}
local MOUSE_KEYS = { MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" }

local activeCapture

local function WithModifiers(key)
	local prefix = ""
	if IsAltKeyDown() then prefix = prefix .. "ALT-" end
	if IsControlKeyDown() then prefix = prefix .. "CTRL-" end
	if IsShiftKeyDown() then prefix = prefix .. "SHIFT-" end
	if IsMetaKeyDown and IsMetaKeyDown() then prefix = prefix .. "META-" end
	return prefix .. key
end

ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
	if activeCapture then activeCapture:StopCapture() end
end)

function Builder:KeyBind(opts)
	local b = self
	local command = opts.command
	local width = b.width - PADDING * 2 - (opts.indent or 0)
	local column = ControlOffset(width, opts.indent)

	local row = CreateFrame("Frame", nil, b.page)
	row:SetSize(width, 24)

	local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	label:SetPoint("LEFT", 4, 0)
	label:SetWidth(math.max(24, column - 16))
	label:SetWordWrap(true)
	label:SetJustifyH("LEFT")
	label:SetText(opts.label)
	row.settingsLabel = label

	local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	btn:SetSize(140, 22)
	btn:SetPoint("LEFT", row, "LEFT", column, 0)
	row.settingsBindingButton = btn
	btn:RegisterForClicks("AnyUp")

	local warn = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	warn:SetPoint("LEFT", btn, "RIGHT", 8, 0)
	warn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
	warn:SetJustifyH("LEFT")
	warn:SetWordWrap(false)
	warn:SetTextColor(1, 0.5, 0.25)

	-- 휠 처리기는 달기만 해도 휠이 켜진다. 그래서 키·휠 처리기는 클릭 후 입력 대기 중에만 단다. (스크롤하다 휠이 지정되는 사고 방지)
	local function StopCapture()
		if activeCapture == btn then activeCapture = nil end
		btn.capturing = false
		btn:SetScript("OnKeyDown", nil)
		btn:SetScript("OnMouseWheel", nil)
		btn:EnableKeyboard(false)
		btn:EnableMouseWheel(false)
		btn:UnlockHighlight()
		row:Refresh()
	end
	btn.StopCapture = StopCapture

	local function Assign(key)
		StopCapture()
		ns:SetPendingBinding(command, key)
	end

	local function OnKeyDown(_, key)
		if key == "ESCAPE" then
			StopCapture()
		elseif not MODIFIER_KEYS[key] then
			Assign(WithModifiers(key))
		end
	end

	local function OnMouseWheel(_, delta)
		Assign(WithModifiers(delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN"))
	end

	local function StartCapture()
		if InCombatLockdown() then
			ns.Print("전투 중에는 단축키를 바꿀 수 없어요.")
			return
		end
		if activeCapture and activeCapture ~= btn then activeCapture:StopCapture() end
		activeCapture = btn
		btn.capturing = true
		btn:SetScript("OnKeyDown", OnKeyDown)
		btn:SetScript("OnMouseWheel", OnMouseWheel)
		btn:SetPropagateKeyboardInput(false)
		btn:EnableKeyboard(true)
		btn:EnableMouseWheel(true)
		btn:LockHighlight()
		btn:SetText("|cffffff00키를 누르세요|r")
		warn:SetText("")
	end

	btn:SetScript("OnClick", function(_, mouseButton)
		if btn.capturing then
			if MOUSE_KEYS[mouseButton] then
				Assign(WithModifiers(MOUSE_KEYS[mouseButton]))
			elseif mouseButton == "RightButton" then
				StopCapture()
				ns:SetPendingBinding(command, false)
			else
				StopCapture()
			end
		elseif mouseButton == "RightButton" then
			ns:SetPendingBinding(command, false)
		elseif mouseButton == "LeftButton" then
			StartCapture()
		end
	end)

	btn:SetScript("OnHide", function()
		if btn.capturing then StopCapture() end
	end)

	AttachTooltip(btn, opts.label, "클릭한 뒤 원하는 키(조합키, 마우스 버튼, 휠 포함)를 누르세요.\n우클릭: 단축키 해제\nESC: 입력 취소\n\n[저장]을 눌러야 실제로 바뀝니다.")

	function row:Refresh()
		if btn.capturing then return end
		local key = ns:GetPendingBindingKey(command)
		btn:SetText(key and GetBindingText(key) or "|cff808080미지정|r")
		btn:SetEnabled(not b:IsDisabled(opts))
		label:SetTextColor(unpack(b:LabelColor(opts, ns:IsBindingPending(command))))

		local conflict = ""
		if key then
			local action = GetBindingAction(key)
			if action and action ~= "" and action ~= command then
				local name = GetBindingName and GetBindingName(action) or action
				conflict = "기존 키 대체: " .. name
			end
		end
		warn:SetText(conflict)
	end

	local height = math.max((label:GetStringHeight() or 0) + 4, 24)
	row:SetHeight(height)
	b:Place(row, height, opts.indent, 6)
	b:SearchEntry(row, opts.label, opts.tooltip or "단축키")
	return b:Track(row)
end

---------------------------------------------------------------------------
-- 즉시 실행 버튼 줄
---------------------------------------------------------------------------
function Builder:Buttons(list)
	local b = self
	local row = CreateFrame("Frame", nil, b.page)
	row:SetSize(b.width - PADDING * 2, 24)

	local items = {}
	local prev
	for _, def in ipairs(list) do
		local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		btn:SetSize(def.width or 130, 22)
		if prev then
			btn:SetPoint("LEFT", prev, "RIGHT", 6, 0)
		else
			btn:SetPoint("LEFT", 4, 0)
		end
		btn:SetText(def.text)
		btn:SetScript("OnClick", function()
			def.onClick()
			ns:Fire("REFRESH_UI")
		end)
		AttachTooltip(btn, def.text, def.tooltip)
		items[#items + 1] = { btn = btn, def = def }
		prev = btn
	end

	function row:Refresh()
		for _, item in ipairs(items) do
			if item.def.textFunc then item.btn:SetText(item.def.textFunc()) end
			item.btn:SetEnabled(not b:IsDisabled(item.def))
		end
	end

	b:Place(row, 24, nil, ROW_GAP)
	for _, item in ipairs(items) do
		b:SearchEntry(item.btn, item.def.text, item.def.tooltip, item.def.textFunc, row.settingsY, row.settingsHeight)
	end
	return b:Track(row)
end

---------------------------------------------------------------------------
-- 켜기/끄기 버튼 줄 (게임 설정처럼 바로 적용되는 항목)
---------------------------------------------------------------------------
local ON_OFF_BUTTON_WIDTH = 56
local ON_OFF_STATUS_WIDTH = 70

function Builder:OnOff(opts)
	local b = self
	local width = b.width - PADDING * 2 - (opts.indent or 0)
	local column = ControlOffset(width, opts.indent)

	local row = CreateFrame("Frame", nil, b.page)

	local offBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	offBtn:SetSize(ON_OFF_BUTTON_WIDTH, 22)
	offBtn:SetPoint("LEFT", row, "LEFT", column + ON_OFF_STATUS_WIDTH + 6 + ON_OFF_BUTTON_WIDTH + 4, 0)
	offBtn:SetText("끄기")

	local onBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	onBtn:SetSize(ON_OFF_BUTTON_WIDTH, 22)
	onBtn:SetPoint("LEFT", row, "LEFT", column + ON_OFF_STATUS_WIDTH + 6, 0)
	onBtn:SetText("켜기")

	local status = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	status:SetWidth(ON_OFF_STATUS_WIDTH)
	status:SetPoint("LEFT", row, "LEFT", column, 0)
	status:SetJustifyH("LEFT")

	local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	label:SetPoint("LEFT", row, "LEFT", 4, 0)
	label:SetWidth(math.max(24, column - 16))
	label:SetWordWrap(true)
	label:SetJustifyH("LEFT")
	label:SetText(opts.label)

	local height = math.max((label:GetStringHeight() or 0) + 4, 24)
	row:SetSize(width, height)

	local function Run(fn)
		PlayClick(fn == opts.onOn)
		fn()
		ns:Fire("REFRESH_UI")
	end
	onBtn:SetScript("OnClick", function() Run(opts.onOn) end)
	offBtn:SetScript("OnClick", function() Run(opts.onOff) end)
	AttachTooltip(row, opts.label, opts.tooltip)
	row:EnableMouse(opts.tooltip ~= nil)

	function row:Refresh()
		local disabled = opts.disabled and opts.disabled() or false
		local on = not disabled and opts.isOn() or false
		if disabled then
			status:SetText("|cff808080없음|r")
		elseif on then
			status:SetText("현재: |cff33ff33켜짐|r")
		else
			status:SetText("현재: |cff999999꺼짐|r")
		end
		-- 지금 상태와 같은 쪽 버튼은 흐리게
		onBtn:SetEnabled(not disabled and not on)
		offBtn:SetEnabled(not disabled and on)
		label:SetTextColor(unpack(disabled and DISABLED_COLOR or NORMAL_COLOR))
	end

	b:Place(row, height, opts.indent, 4)
	b:SearchEntry(row, opts.label, opts.tooltip)
	return b:Track(row)
end

---------------------------------------------------------------------------
-- 선택 상자 (게임 기본 드롭다운)
---------------------------------------------------------------------------
function Builder:Dropdown(opts)
	local b = self
	local width = b.width - PADDING * 2 - (opts.indent or 0)
	local column = opts.label and ControlOffset(width, opts.indent) or 4
	local dropdownWidth = math.min(opts.width or 240, math.max(80, width - column - 4))
	local row = CreateFrame("Frame", nil, b.page)

	local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	label:SetPoint("LEFT", 4, 0)
	label:SetWidth(opts.label and math.max(24, column - 16) or 1)
	label:SetWordWrap(true)
	label:SetJustifyH("LEFT")
	label:SetText(opts.label or "")
	row.settingsLabel = label

	local function Options()
		return opts.options() or {}
	end

	local function Pick(value)
		b:Set(opts, value)
		ns:Fire("REFRESH_UI")
	end

	local ok, dropdown = pcall(CreateFrame, "DropdownButton", nil, row, "WowStyle1DropdownTemplate")
	local simple = not (ok and dropdown and dropdown.SetupMenu)
	if not simple then
		dropdown:SetWidth(dropdownWidth)
		dropdown:SetDefaultText(opts.emptyText or "")
		dropdown:SetupMenu(function(_, root)
			for _, option in ipairs(Options()) do
				root:CreateRadio(option.text, function(value) return b:Get(opts) == value end, Pick, option.value)
			end
		end)
	else
		-- 드롭다운이 없는 게임 버전이면 누를 때마다 다음 항목으로 넘어가는 버튼
		dropdown = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		dropdown:SetSize(dropdownWidth, 22)
		dropdown:SetScript("OnClick", function()
			local list, current, index = Options(), b:Get(opts), 1
			for i, option in ipairs(list) do
				if option.value == current then index = i % #list + 1 end
			end
			if list[index] then Pick(list[index].value) end
		end)
	end
	dropdown:SetPoint("LEFT", row, "LEFT", column, 0)
	row.settingsDropdown = dropdown
	AttachTooltip(dropdown, opts.label, opts.tooltip)

	function row:Refresh()
		local list = Options()
		if simple then
			local text, current = opts.emptyText or "", b:Get(opts)
			for _, option in ipairs(list) do
				if option.value == current then text = option.text end
			end
			dropdown:SetText(text)
		elseif not dropdown:IsMenuOpen() then
			dropdown:GenerateMenu()   -- 고른 항목의 글자를 다시 맞춘다
		end
		dropdown:SetEnabled(#list > 0 and not b:IsDisabled(opts))
		label:SetTextColor(unpack(b:LabelColor(opts, opts.key and ns:IsPending(b.module, opts.key))))
	end

	local height = math.max((label:GetStringHeight() or 0) + 4, 28)
	row:SetSize(width, height)
	b:Place(row, height, opts.indent, 4)
	b:SearchEntry(row, opts.label, opts.tooltip, DropdownKeywords(opts))
	return b:Track(row)
end

---------------------------------------------------------------------------
-- 글 입력 창 (설정 내보내기/가져오기 등)
---------------------------------------------------------------------------
local dialog

local function CreateTextDialog()
	dialog = CreateFrame("Frame", "EzyWOWFTextDialog", UIParent, "BackdropTemplate")
	dialog:SetSize(480, 160)
	dialog:SetPoint("CENTER", 0, 140)
	dialog:SetFrameStrata("DIALOG")
	dialog:SetToplevel(true)
	dialog:EnableMouse(true)
	UI.ApplyPanelBackdrop(dialog)
	dialog:Hide()
	tinsert(UISpecialFrames, "EzyWOWFTextDialog")

	dialog.title = dialog:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	dialog.title:SetPoint("TOP", 0, -14)

	dialog.help = dialog:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	dialog.help:SetPoint("TOP", dialog.title, "BOTTOM", 0, -8)
	dialog.help:SetWidth(440)

	local edit = CreateFrame("EditBox", nil, dialog, "BackdropTemplate")
	edit:SetSize(440, 26)
	edit:SetPoint("TOP", dialog.help, "BOTTOM", 0, -10)
	UI.ApplyPanelBackdrop(edit, { 0, 0, 0, 0.6 })
	edit:SetTextInsets(6, 6, 0, 0)
	edit:SetFontObject(ChatFontNormal)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(0)
	dialog.edit = edit

	dialog.status = dialog:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	dialog.status:SetPoint("BOTTOMLEFT", 16, 18)
	dialog.status:SetPoint("RIGHT", dialog, "RIGHT", -230, 0)
	dialog.status:SetJustifyH("LEFT")

	local close = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
	close:SetSize(100, 24)
	close:SetPoint("BOTTOMRIGHT", -12, 12)
	close:SetText("닫기")
	close:SetScript("OnClick", function() dialog:Hide() end)

	local accept = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
	accept:SetSize(100, 24)
	accept:SetPoint("RIGHT", close, "LEFT", -6, 0)
	accept:SetScript("OnClick", function()
		local ok, msg = dialog.onAccept(edit:GetText())
		if ok then
			dialog:Hide()
			if msg then ns.Print(msg) end
		else
			dialog.status:SetText("|cffff5555" .. (msg or "실패했습니다.") .. "|r")
		end
	end)
	dialog.accept = accept

	edit:SetScript("OnEscapePressed", function() dialog:Hide() end)
	edit:SetScript("OnEnterPressed", function()
		if dialog.onAccept then accept:Click() end
	end)
	edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	edit:SetScript("OnTextChanged", function(self, userInput)
		-- 읽기 전용이면 실수로 지워도 원래 글로 되돌린다.
		if userInput and dialog.readOnly then
			self:SetText(dialog.fixedText)
			self:HighlightText()
		end
	end)
end

function UI.ShowTextDialog(opts)
	if not dialog then CreateTextDialog() end
	dialog.title:SetText(opts.title or "")
	dialog.help:SetText(opts.help or "")
	dialog.readOnly = opts.readOnly
	dialog.fixedText = opts.text or ""
	dialog.onAccept = opts.onAccept
	dialog.status:SetText("")
	dialog.accept:SetShown(opts.onAccept ~= nil)
	dialog.accept:SetText(opts.button or "확인")
	dialog.edit:SetText(opts.text or "")
	dialog:Show()
	dialog.edit:SetFocus()
	dialog.edit:HighlightText()
end

---------------------------------------------------------------------------
-- 스크롤 영역 (설정 창의 왼쪽 메뉴와 오른쪽 페이지가 같이 쓴다)
---------------------------------------------------------------------------
local SCROLL_STEP = 40
local SCROLLBAR_W = 6

function UI.CreateScrollArea(parent)
	local area = { content = 0, range = 0 }

	local scroll = CreateFrame("ScrollFrame", nil, parent)
	scroll:EnableMouseWheel(true)
	area.scroll = scroll

	local bar = CreateFrame("Slider", nil, parent)
	bar:SetOrientation("VERTICAL")
	bar:SetWidth(SCROLLBAR_W)
	bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 3, 0)
	bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 3, 0)
	bar:SetMinMaxValues(0, 0)
	bar:SetValueStep(1)
	bar:SetObeyStepOnDrag(true)
	bar:EnableMouse(true)   -- 손잡이를 잡고 끌어도 된다
	local track = bar:CreateTexture(nil, "BACKGROUND")
	track:SetAllPoints()
	UI.ColorTexture(track, Theme.track)
	local thumb = bar:CreateTexture(nil, "OVERLAY")
	UI.ColorTexture(thumb, Theme.thumb)
	thumb:SetSize(SCROLLBAR_W, 40)
	bar:SetThumbTexture(thumb)
	local top = bar:CreateTexture(nil, "OVERLAY")
	top:SetSize(SCROLLBAR_W, 8)
	top:SetPoint("TOP", thumb, "TOP")
	local bottom = bar:CreateTexture(nil, "OVERLAY")
	bottom:SetSize(SCROLLBAR_W, 8)
	bottom:SetPoint("BOTTOM", thumb, "BOTTOM")
	local middle = bar:CreateTexture(nil, "OVERLAY")
	middle:SetPoint("TOPLEFT", top, "BOTTOMLEFT")
	middle:SetPoint("BOTTOMRIGHT", bottom, "TOPRIGHT")
	local nativeTop = UI.SetAtlas(top, "minimal-scrollbar-small-thumb-top")
	local nativeMiddle = UI.SetAtlas(middle, "minimal-scrollbar-small-thumb-middle")
	local nativeBottom = UI.SetAtlas(bottom, "minimal-scrollbar-small-thumb-bottom")
	local native = nativeTop and nativeMiddle and nativeBottom
	top:SetShown(native)
	middle:SetShown(native)
	bottom:SetShown(native)
	if native then thumb:SetAlpha(0) end
	bar.settingsThumb = thumb
	bar.settingsThumbArt = { top, middle, bottom }
	bar:Hide()
	area.bar = bar

	bar:SetScript("OnValueChanged", function(_, value) scroll:SetVerticalScroll(value) end)
	scroll:SetScript("OnMouseWheel", function(_, delta)
		bar:SetValue(bar:GetValue() - delta * SCROLL_STEP)
	end)

	-- 내용 높이가 바뀌면 스크롤 범위와 손잡이 길이를 다시 맞춘다.
	function area:SetContentHeight(h)
		self.content = h
		local visible = scroll:GetHeight()
		local range = math.max(0, h - visible)
		self.range = range
		bar:SetMinMaxValues(0, range)
		bar:SetShown(range > 0)
		if bar:GetValue() > range then bar:SetValue(range) end
		if h > 0 and visible > 0 then
			thumb:SetHeight(math.max(24, bar:GetHeight() * visible / h))
		end
	end

	function area:ScrollTo(y)
		bar:SetValue(math.max(0, math.min(y, self.range)))
	end

	scroll:SetScript("OnSizeChanged", function()
		area:SetContentHeight(area.content)
		if area.OnSizeChanged then area:OnSizeChanged() end
	end)

	return area
end
