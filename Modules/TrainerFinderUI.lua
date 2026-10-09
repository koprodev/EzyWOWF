local _, ns = ...
local UI, Finder = ns.UI, ns.TrainerFinder
local M = ns.modules.TrainerFinder
local WIDTH, HEIGHT, HEADER = 320, 420, 34
local ICON = "Interface\\Icons\\INV_Misc_Book_06"
local button, panel, mapButton, mapPanel, mapFrame

local function Enabled()
	return M.db and M.db.enabled
end

local function PaintButton(control, open)
	if not control then return end
	if open then control:LockHighlight() else control:UnlockHighlight() end
end

local function RefreshPanels()
	for _, frame in pairs({ panel, mapPanel }) do
		if frame.builder then frame.builder:Refresh() end
	end
	PaintButton(button, panel and panel:IsShown())
	PaintButton(mapButton, mapPanel and mapPanel:IsShown())
end

local function ScreenHeight(frame)
	local height = UIParent:GetHeight()
	local parentScale, scale = UIParent:GetEffectiveScale(), frame:GetEffectiveScale()
	if height > 0 and scale > 0 then return height * parentScale / scale end
	return HEIGHT + 24
end

local function PanelHeight(frame)
	local available = ScreenHeight(frame) - 24
	if frame.mapPanel and mapFrame then
		local container = mapFrame.ScrollContainer or mapFrame
		local height = container:GetHeight()
		if height > 0 then available = math.min(available, height - 52) end
	end
	return math.max(HEADER + 48, math.min(HEIGHT, available))
end

local function SetExpanded(frame, expanded)
	frame.expanded = expanded
	local height = PanelHeight(frame)
	frame:SetHeight(expanded and height or HEADER)
	frame.collapseButton:SetText(expanded and "접기" or "펼치기")
	frame.area.scroll:SetSize(WIDTH - 16, height - HEADER - 44)
	frame.area.scroll:SetShown(expanded)
	frame.navigateRow:SetShown(expanded)
	frame.area:SetContentHeight(frame.builder:Height())
	if not expanded then frame.area.bar:Hide() end
end

local function BuildFilters(frame)
	local page = frame.page
	local b = UI.NewBuilder(page, M, WIDTH - 16)
	frame.builder = b
	b.y = -8
	local place = b.Place
	function b:Place(region, height, indent, gap)
		return place(self, region, height, indent, math.min(gap or 8, 3))
	end

	-- Filters commit through Finder while the settings window keeps its pending values.
	function b:Get(opts)
		if opts.get then return opts.get() end
		return Finder.IsKindChecked(opts.key:sub(6))
	end
	function b:Set(opts, value)
		if opts.set then return opts.set(value) end
		Finder.SetKindChecked(opts.key:sub(6), value)
	end
	function b:IsDisabled(opts)
		return not Enabled() or (opts.disabled and opts.disabled()) or false
	end

	frame.presetRow = b:Buttons{
		{ text = "내 직업", width = 82, onClick = function() Finder.SetKind("myclass") end },
		{ text = "전체", width = 70, onClick = function() Finder.SetKind("all") end },
		{ text = "모두 해제", width = 100, onClick = Finder.ClearKinds },
	}
	local items = {}
	for _, kind in ipairs(Finder.GetKinds()) do
		items[#items + 1] = {
			key = "kind_" .. kind[1], text = kind[2],
			title = kind[2] .. " 전문가", tooltip = "체크한 전문가를 세계 지도와 미니맵에 표시합니다.",
		}
	end
	frame.grid = b:CheckGrid{ items = items, columns = 3 }
	b:Text("지역")
	frame.regionDropdown = b:Dropdown{
		options = Finder.GetRegionOptions, get = Finder.GetRegion, set = Finder.SetRegion,
		width = 264, emptyText = "표시할 지역이 없습니다",
	}
	b:Text("전문가")
	frame.trainerDropdown = b:Dropdown{
		options = Finder.GetTrainerOptions, get = Finder.GetSelectionKey, set = Finder.SetSelection,
		width = 264, emptyText = "이 지역에는 등록된 전문가가 없습니다",
	}
	local contentY = b.y
	frame.navigateRow = b:Buttons{
		{ text = "지도에서 찾기", width = 132, onClick = function() Finder.Navigate(Finder.GetSelection()) end,
			disabled = function() return not Finder.GetSelection() end },
		{ text = "핀 지우기", width = 126, onClick = Finder.ClearWaypoint },
	}
	frame.navigateRow:SetParent(frame)
	frame.navigateRow:ClearAllPoints()
	frame.navigateRow:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 8)
	b.y = contentY
	page:SetHeight(b:Height())
	b:Refresh()
end

local function NewPanel(name, parent, onMap)
	local frame = CreateFrame("Frame", name, parent, "BackdropTemplate")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata("DIALOG")
	frame:SetFrameLevel(parent:GetFrameLevel() + 20)
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame.mapPanel = onMap
	frame:Hide()
	UI.ApplySettingsFrame(frame)
	tinsert(UISpecialFrames, name)

	local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("TOPLEFT", 12, -11)
	title:SetWidth(180)
	title:SetJustifyH("LEFT")
	title:SetText("기술·직업 전문가 찾기")
	frame.title = title

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetSize(26, 26)
	close:SetPoint("TOPRIGHT", -3, -3)
	close:SetScript("OnClick", function() frame:Hide() end)
	frame.closeButton = close
	local collapse = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	collapse:SetSize(60, 22)
	collapse:SetPoint("RIGHT", close, "LEFT", -2, 0)
	collapse:SetScript("OnClick", function() SetExpanded(frame, not frame.expanded) end)
	frame.collapseButton = collapse

	local area = UI.CreateScrollArea(frame)
	area.scroll:SetPoint("TOPLEFT", 4, -HEADER)
	area.scroll:SetPoint("BOTTOMRIGHT", -12, 40)
	frame.area = area
	local page = CreateFrame("Frame", nil, area.scroll)
	page:SetWidth(WIDTH - 16)
	page:SetPoint("TOPLEFT", area.scroll, "TOPLEFT")
	area.scroll:SetScrollChild(page)
	frame.page = page
	BuildFilters(frame)
	SetExpanded(frame, true)
	frame:SetScript("OnShow", function()
		SetExpanded(frame, frame.expanded)
		RefreshPanels()
	end)
	frame:SetScript("OnHide", RefreshPanels)
	return frame
end

function Finder.TogglePanel(anchor)
	if not Enabled() then return end
	if panel and panel:IsShown() then panel:Hide() return end
	if not panel then panel = NewPanel("EzyWOWFTrainerPanel", UIParent, false) end
	panel:ClearAllPoints()
	anchor = anchor or button or Minimap
	if anchor then panel:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4)
	else panel:SetPoint("CENTER") end
	SetExpanded(panel, true)
	panel:Show()
end

function Finder.ToggleMapPanel()
	if not Enabled() or not mapFrame then return end
	if mapPanel and mapPanel:IsShown() then mapPanel:Hide() return end
	Finder.SetRegion(mapFrame:GetMapID())
	if not mapPanel then mapPanel = NewPanel("EzyWOWFTrainerMapPanel", mapFrame, true) end
	mapPanel:ClearAllPoints()
	mapPanel:SetPoint("TOPRIGHT", mapButton, "BOTTOMRIGHT", 0, -4)
	SetExpanded(mapPanel, true)
	mapPanel:Show()
end

function Finder.AttachMapUI(map)
	if mapButton or not map then return end
	mapFrame = map
	mapButton = CreateFrame("Button", "EzyWOWFTrainerMapButton", map, "UIPanelButtonTemplate")
	mapButton:SetSize(92, 24)
	mapButton:SetPoint("TOPRIGHT", map.ScrollContainer or map, "TOPRIGHT", -12, -12)
	mapButton:SetFrameLevel((map.ScrollContainer or map):GetFrameLevel() + 100)
	mapButton:SetText("전문가 찾기")
	mapButton:SetScript("OnClick", Finder.ToggleMapPanel)
	map:HookScript("OnHide", function() if mapPanel then mapPanel:Hide() end end)
	map:HookScript("OnSizeChanged", function()
		if mapPanel then SetExpanded(mapPanel, mapPanel.expanded) end
	end)
	if map.ScrollContainer then
		map.ScrollContainer:HookScript("OnSizeChanged", function()
			if mapPanel then SetExpanded(mapPanel, mapPanel.expanded) end
		end)
	end
	mapButton:SetShown(Enabled() and M.db.showMapButton)
end

function Finder.InitializeUI()
	if not button and Minimap then
		button = CreateFrame("Button", "EzyWOWFTrainerButton", Minimap)
		button:SetSize(31, 31)
		button:SetFrameStrata("MEDIUM")
		button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
		button:SetPoint("TOPRIGHT", Minimap, "TOPLEFT", -4, 0)
		button:RegisterForClicks("LeftButtonUp")
		button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
		local border = button:CreateTexture(nil, "OVERLAY")
		border:SetSize(50, 50)
		border:SetPoint("TOPLEFT")
		border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
		local background = button:CreateTexture(nil, "BACKGROUND")
		background:SetSize(24, 24)
		background:SetPoint("CENTER")
		background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
		local icon = button:CreateTexture(nil, "ARTWORK")
		icon:SetSize(18, 18)
		icon:SetPoint("CENTER")
		icon:SetTexture(ICON)
		button.icon = icon
		button:SetScript("OnClick", function() Finder.TogglePanel(button) end)
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:SetText("기술·직업 전문가 찾기", 1, 0.82, 0)
			GameTooltip:AddLine("클릭: 찾기 옵션 펼치기 / 닫기", 1, 1, 1)
			GameTooltip:AddLine("종류를 체크하고 지역·전문가를 골라 길 안내하세요.", 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", GameTooltip_Hide)
	end
	Finder.ApplyUI()
end

function Finder.ApplyUI()
	if button then
		local shown = Enabled() and M.db.showButton
		button:SetShown(shown)
		if not shown and panel then panel:Hide() end
	end
	if mapButton then
		local shown = Enabled() and M.db.showMapButton
		mapButton:SetShown(shown)
		if not shown and mapPanel then mapPanel:Hide() end
	end
	RefreshPanels()
end

ns:On("TRAINER_FINDER_CHANGED", RefreshPanels)
ns:On("REFRESH_UI", RefreshPanels)
ns:On("TRAINER_FINDER_MAP_CHANGED", function(id)
	if mapPanel and mapPanel:IsShown() then Finder.SetRegion(id) end
end)
ns:On("MINIMAP_LAYOUT_CHANGED", function()
	if button then
		button:ClearAllPoints()
		button:SetPoint("TOPRIGHT", Minimap, "TOPLEFT", -4, 0)
	end
end)
ns:RegisterEvent("DISPLAY_SIZE_CHANGED", function()
	for _, frame in pairs({ panel, mapPanel }) do SetExpanded(frame, frame.expanded) end
end)
