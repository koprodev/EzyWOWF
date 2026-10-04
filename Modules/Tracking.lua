-- 추적: 배운 추적 기술(사냥꾼 추적, 약초/광물 찾기, 드워프 보물 찾기 등)만 아이콘으로 모아 보여 주고,
-- 아이콘 클릭이나 단축키로 켠다.
--
-- 추적 켜기는 주문 시전이라 애드온 코드가 직접 할 수 없다. 그래서 추적마다 보안 버튼을 두고
-- "/cast !주문이름" 매크로를 넣는다. (!: 이미 켜진 추적을 다시 눌러도 꺼지지 않게)
-- 단축키는 종류별 고정 버튼(EzyWOWFTrackBEASTS 등)을 CLICK 바인딩으로 누른다.
-- 쓸 수 있는 추적은 미니맵 추적 목록(C_Minimap)과 배운 주문(ns.IsSpellKnown)을 합쳐서 찾는다.
-- 우클릭으로 끄는 것은 C_Minimap.SetTracking(번호, false)로 한다. (보호된 함수가 아니라 애드온에서 불러도 된다)

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local ICON_SIZE = 30
local ICON_GAP = 3
local GROUP_GAP = 8
local BUTTON_PREFIX = "EzyWOWFTrack"
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- 단축키를 줄 수 있는 추적 종류. 막대에도 이 순서로 나온다. (group: 1 사냥꾼, 2 자원, 3 종족)
local KINDS = {
	{ key = "BEASTS",     spellID = 1494,  group = 1, name = "야수 추적" },
	{ key = "HUMANOIDS",  spellID = 19883, group = 1, name = "인간형 추적" },
	{ key = "UNDEAD",     spellID = 19884, group = 1, name = "언데드 추적" },
	{ key = "HIDDEN",     spellID = 19885, group = 1, name = "은신 추적" },
	{ key = "ELEMENTALS", spellID = 19880, group = 1, name = "정령 추적" },
	{ key = "DEMONS",     spellID = 19878, group = 1, name = "악마 추적" },
	{ key = "GIANTS",     spellID = 19882, group = 1, name = "거인 추적" },
	{ key = "DRAGONKIN",  spellID = 19879, group = 1, name = "용족 추적" },
	{ key = "HERBS",      spellID = 2383,  group = 2, name = "약초 찾기" },
	{ key = "MINERALS",   spellID = 2580,  group = 2, name = "광물 찾기" },
	{ key = "TREASURE",   spellID = 2481,  group = 3, name = "보물 찾기" },
}
local OTHER_GROUP = 4   -- 목록에 없는 추적 (성기사 언데드 감지 등). 아이콘만 있고 단축키는 없다.

local function SpellName(spellID)
	if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(spellID) end
	return GetSpellInfo and (GetSpellInfo(spellID))
end

local function SpellTexture(spellID)
	if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(spellID) end
	return GetSpellTexture and GetSpellTexture(spellID)
end

local bindings = {}
local kindBySpell, kindByName = {}, {}
for _, kind in ipairs(KINDS) do
	kind.name = SpellName(kind.spellID) or kind.name
	kind.binding = "CLICK " .. BUTTON_PREFIX .. kind.key .. ":LeftButton"
	_G["BINDING_NAME_" .. kind.binding] = "추적: " .. kind.name
	bindings[#bindings + 1] = kind.binding
	kindBySpell[kind.spellID] = kind
	kindByName[kind.name] = kind
end

local M = ns:NewModule("Tracking", {
	title = "추적",
	category = "map",
	icon = "Interface\\Icons\\Ability_Tracking",
	order = 20,
	bindings = bindings,
	defaults = {
		enabled = true,
		showBar = true,
		scale = 1,
		underMinimap = true,
		point = "CENTER", relPoint = "CENTER", x = 0, y = 0,
	},
})

local db
local available = {}     -- 쓸 수 있는 추적 (막대 순서)
local signature = ""     -- available 구성이 바뀌었는지 비교용
local pendingAfterCombat = false
local moveMode = false

---------------------------------------------------------------------------
-- 쓸 수 있는 추적 찾기
---------------------------------------------------------------------------
local function TrackingCount()
	return C_Minimap and C_Minimap.GetNumTrackingTypes and C_Minimap.GetNumTrackingTypes() or 0
end

-- 11.0 이전 형식(여러 값 반환)도 받아 준다.
local function TrackingInfo(index)
	local a, b, c, d, e, f = C_Minimap.GetTrackingInfo(index)
	if type(a) == "table" then return a end
	if a then return { name = a, texture = b, active = c, type = d, subType = e, spellID = f } end
end

local IsKnown = ns.IsSpellKnown

local function Collect()
	local found, others = {}, {}

	local function Add(spellID, name, texture)
		local kind = (spellID and kindBySpell[spellID]) or (name and kindByName[name])
		local key = kind and kind.key or ("OTHER:" .. tostring(spellID or name))
		if found[key] then return end
		spellID = spellID or (kind and kind.spellID)
		local e = {
			key = key,
			kind = kind,
			spellID = spellID,
			name = name or (kind and kind.name),
			castName = (spellID and SpellName(spellID)) or name or (kind and kind.name),
			texture = texture or (spellID and SpellTexture(spellID)),
			group = kind and kind.group or OTHER_GROUP,
		}
		if not e.castName then return end
		found[key] = e
		if not kind then others[#others + 1] = e end
	end

	-- 미니맵 추적 목록 중 주문으로 켜는 것 (마을 시설 표시 같은 것은 뺀다)
	for i = 1, TrackingCount() do
		local info = TrackingInfo(i)
		local spellID = info and Clean(info.spellID)
		if info and (info.type == "spell" or spellID) then
			Add(spellID, Clean(info.name), Clean(info.texture))
		end
	end
	-- 추적 목록에 안 잡혀도 배운 주문이면 넣는다.
	for _, kind in ipairs(KINDS) do
		if IsKnown(kind.spellID) then Add(kind.spellID, kind.name) end
	end

	local list = {}
	for _, kind in ipairs(KINDS) do
		if found[kind.key] then list[#list + 1] = found[kind.key] end
	end
	for _, e in ipairs(others) do list[#list + 1] = e end
	return list
end

---------------------------------------------------------------------------
-- 막대와 버튼
---------------------------------------------------------------------------
local bar = CreateFrame("Frame", "EzyWOWFTrackingBar", UIParent)
bar:SetSize(ICON_SIZE, ICON_SIZE)
bar:SetFrameStrata("MEDIUM")
bar:SetMovable(true)
bar:SetClampedToScreen(true)
if bar.SetDontSavePosition then bar:SetDontSavePosition(true) end
bar:Hide()

-- 이동 모드일 때 막대 위를 덮어서 드래그를 받는다. (그동안 아이콘은 눌리지 않음)
local mover = CreateFrame("Frame", nil, bar)
mover:SetAllPoints()
mover:SetFrameLevel(bar:GetFrameLevel() + 20)
mover:EnableMouse(true)
mover:RegisterForDrag("LeftButton")
mover:Hide()

local moverTint = mover:CreateTexture(nil, "OVERLAY")
moverTint:SetAllPoints()
moverTint:SetColorTexture(0, 1, 0, 0.3)

local moverLabel = mover:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
moverLabel:SetPoint("BOTTOM", mover, "TOP", 0, 4)
moverLabel:SetText("추적 아이콘\n드래그해서 이동")

-- 추적 목록에서 이 항목의 번호를 찾는다. 목록 순서가 바뀔 수 있어서 누를 때마다 찾는다.
local function FindTracking(e)
	for i = 1, TrackingCount() do
		local info = TrackingInfo(i)
		if info then
			local spellID, name = Clean(info.spellID), Clean(info.name)
			if (e.spellID and spellID == e.spellID) or (name and name == e.name) then
				return i, Clean(info.active)
			end
		end
	end
end

local function TurnOff(e)
	local index, active = FindTracking(e)
	if not index then
		Print(("%s: 여기서는 끌 수 없어요. 미니맵의 추적 메뉴를 쓰세요."):format(e.name))
		return
	end
	if active then C_Minimap.SetTracking(index, false) end
end

-- 왼쪽 클릭은 보안 매크로(켜기)가 처리하고, 우클릭은 여기서 끈다.
local function OnPostClick(self, mouseButton, down)
	if down or mouseButton ~= "RightButton" or not self.entry then return end
	TurnOff(self.entry)
end

local function ShowTooltip(self)
	local e = self.entry
	if not e then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if e.spellID and GameTooltip.SetSpellByID then
		GameTooltip:SetSpellByID(e.spellID)
	else
		GameTooltip:SetText(e.name, 1, 1, 1)
	end
	GameTooltip:AddLine(" ")
	if self.isActive then
		GameTooltip:AddLine("추적 중 - 우클릭: 끄기", 0.3, 1, 0.3)
	else
		GameTooltip:AddLine("클릭: 추적 켜기", 0.7, 0.7, 0.7)
	end
	if e.kind then
		local key = GetBindingKey(e.kind.binding)
		GameTooltip:AddLine("단축키: " .. (key and GetBindingText(key) or "없음 (/이지 에서 지정)"), 0.7, 0.7, 0.7)
	end
	GameTooltip:Show()
end

local function CreateButton(name)
	local btn = CreateFrame("Button", name, bar, "SecureActionButtonTemplate")
	btn:SetSize(ICON_SIZE, ICON_SIZE)
	btn:RegisterForClicks("AnyUp", "AnyDown")
	btn:Hide()

	local edge = btn:CreateTexture(nil, "BACKGROUND", nil, 0)
	edge:SetAllPoints()
	edge:SetColorTexture(0, 0, 0, 0.9)

	btn.activeBorder = btn:CreateTexture(nil, "BACKGROUND", nil, 1)
	btn.activeBorder:SetPoint("TOPLEFT", 1, -1)
	btn.activeBorder:SetPoint("BOTTOMRIGHT", -1, 1)
	btn.activeBorder:SetColorTexture(0.85, 0.65, 0.13, 1)
	btn.activeBorder:Hide()

	btn.icon = btn:CreateTexture(nil, "ARTWORK")
	btn.icon:SetPoint("TOPLEFT", 2, -2)
	btn.icon:SetPoint("BOTTOMRIGHT", -2, 2)
	btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	btn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
	btn:GetPushedTexture():SetAllPoints(btn.icon)
	btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	btn:GetHighlightTexture():SetAllPoints(btn.icon)

	btn.hotkey = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
	btn.hotkey:SetPoint("TOPLEFT", 2, -3)
	btn.hotkey:SetPoint("TOPRIGHT", -2, -3)
	btn.hotkey:SetJustifyH("RIGHT")
	btn.hotkey:SetWordWrap(false)

	btn:SetScript("PostClick", OnPostClick)
	btn:SetScript("OnEnter", ShowTooltip)
	btn:SetScript("OnLeave", GameTooltip_Hide)
	return btn
end

-- 단축키가 붙는 종류별 버튼은 미리 만들어 둔다.
local buttons = {}
for _, kind in ipairs(KINDS) do
	buttons[kind.key] = CreateButton(BUTTON_PREFIX .. kind.key)
end
local extraButtons = {}

---------------------------------------------------------------------------
-- 표시 갱신 (전투 중에도 안전한 것들)
---------------------------------------------------------------------------
local function UpdateStates()
	local activeSpells, activeNames = {}, {}
	for i = 1, TrackingCount() do
		local info = TrackingInfo(i)
		if info and Clean(info.active) then
			local spellID, name = Clean(info.spellID), Clean(info.name)
			if spellID then activeSpells[spellID] = true end
			if name then activeNames[name] = true end
		end
	end
	for _, e in ipairs(available) do
		local btn = e.button
		if btn then
			local on = (e.spellID and activeSpells[e.spellID]) or activeNames[e.name] or false
			btn.isActive = on
			btn.activeBorder:SetShown(on)
			btn.icon:SetDesaturated(not on)
		end
	end
end

local function UpdateHotkeys()
	for _, e in ipairs(available) do
		if e.button then
			local key = e.kind and GetBindingKey(e.kind.binding)
			e.button.hotkey:SetText(key and GetBindingText(key, true) or "")
		end
	end
end

---------------------------------------------------------------------------
-- 배치 (보안 버튼이라 전투 중에는 바꿀 수 없음)
--   미니맵에 붙이기(기본, underMinimap): 네모 미니맵이면 지도 바로 아래, 둥근 미니맵이면 테두리 아래.
--     아이콘 크기와 줄 수는 미니맵 너비에 맞춘다. 네모일 때는 오른쪽 아래 모서리 밑의
--     확대·축소 버튼 자리를 양쪽에 똑같이 비워서 가운데를 맞춘다.
--   자유 위치: [위치 이동]으로 옮긴 자리. 한 줄로 늘어놓고 아이콘 크기 설정을 따른다.
---------------------------------------------------------------------------
local ATTACH_PAD = 4
local MIN_ATTACHED_ICON = 18
local BELOW_GAP = 2          -- 네모 미니맵: 지도와 아이콘 사이
local ZOOM_RESERVE = 44      -- 네모 미니맵: 확대·축소 버튼(-, +) 자리
local ROUND_ATTACH_Y = -38   -- 둥근 미니맵: 테두리와 좌표 아래

-- 네모 미니맵 밑 줄이 차지한 높이 (화면 픽셀). 정보 막대가 그 아래로 비켜 선다.
-- 같은 줄 왼쪽 모서리의 메모 버튼(ns.MinimapMemoBelow)과 둘 중 높은 쪽이다.
local belowPixels = 0
function ns.MinimapBelowPixels()
	local memo = ns.MinimapMemoBelow and ns.MinimapMemoBelow() or 0
	return math.max(belowPixels, memo)
end

-- 미니맵에 붙은 아이콘 크기 (지도 크기 단위). 메모 버튼이 이 크기를 따른다. 줄이 안 보이면 nil.
local attachedSize, rowIconSize
function ns.MinimapRowIconSize()
	return rowIconSize
end

-- 아이콘이 너무 작아지지 않을 만큼 줄 수를 늘린다.
local function AttachedGrid(count, width)
	local rows, cols, size = 1, count, ICON_SIZE
	for r = 1, count do
		rows, cols = r, math.ceil(count / r)
		size = math.floor((width - ATTACH_PAD * 2 - (cols - 1) * ICON_GAP) / cols)
		if size >= MIN_ATTACHED_ICON then break end
	end
	return rows, cols, math.max(math.min(size, ICON_SIZE), 12)
end

-- 붙어 있는 막대가 지도 밑으로 내려온 높이. 배치를 건너뛸 때도 지금 크기·배율로 다시 잰다.
local function AttachedBelow(count)
	local square = ns.IsMinimapSquare and ns.IsMinimapSquare()
	return square and count > 0
		and (bar:GetHeight() - ATTACH_PAD * 2 + BELOW_GAP) * bar:GetEffectiveScale() or 0
end

local function PlaceAttached(list)
	local square = ns.IsMinimapSquare and ns.IsMinimapSquare()
	local reserve = (square and ns.IsMinimapZoomOutside and ns.IsMinimapZoomOutside()) and ZOOM_RESERVE or 0
	-- 왼쪽 모서리의 메모 버튼 자리. 가운데 맞춤이라 양쪽을 똑같이 비운다.
	if ns.MinimapMemoWidth then reserve = math.max(reserve, ns.MinimapMemoWidth()) end
	local width = Minimap:GetWidth() - reserve * 2
	local rows, cols, size = AttachedGrid(#list, width)
	attachedSize = size
	for i, btn in ipairs(list) do
		local row, col = math.floor((i - 1) / cols), (i - 1) % cols   -- row 0 = 위쪽 줄
		local inRow = math.min(cols, #list - row * cols)
		local rowWidth = inRow * size + (inRow - 1) * ICON_GAP
		btn:SetSize(size, size)
		btn:ClearAllPoints()
		btn:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT",
			(width - rowWidth) / 2 + col * (size + ICON_GAP),
			ATTACH_PAD + (rows - 1 - row) * (size + ICON_GAP))
	end
	bar:SetSize(width, rows * (size + ICON_GAP) - ICON_GAP + ATTACH_PAD * 2)
	-- 막대는 UIParent 자식이라, 미니맵과 같은 크기 단위가 되도록 배율을 맞춘다. (편집 모드 배율 포함)
	bar:SetScale(Minimap:GetEffectiveScale() / UIParent:GetEffectiveScale())
	bar:ClearAllPoints()
	if square then
		-- 막대 안쪽 위 여백(ATTACH_PAD)을 빼고 지도와 BELOW_GAP만큼만 띄운다.
		bar:SetPoint("TOP", Minimap, "BOTTOM", 0, ATTACH_PAD - BELOW_GAP)
	else
		bar:SetPoint("TOP", Minimap, "BOTTOM", 0, ROUND_ATTACH_Y)
	end
	return AttachedBelow(#list)
end

local function PlaceFree(list)
	local x, lastGroup = 0, nil
	for _, btn in ipairs(list) do
		local group = btn.entry.group
		if lastGroup and lastGroup ~= group then x = x + GROUP_GAP end
		lastGroup = group
		btn:SetSize(ICON_SIZE, ICON_SIZE)
		btn:ClearAllPoints()
		btn:SetPoint("LEFT", bar, "LEFT", x, 0)
		x = x + ICON_SIZE + ICON_GAP
	end
	bar:SetSize(math.max(x - ICON_GAP, ICON_SIZE), ICON_SIZE)
	bar:SetScale(db.scale)
	bar:ClearAllPoints()
	bar:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
end

-- 버튼 설정과 배치에 들어가는 입력 전부. 이게 같으면 다시 세팅해 봐야 결과도 똑같다.
local function SetupSignature(list)
	local parts = {
		tostring(db.enabled), tostring(db.showBar), tostring(db.underMinimap), tostring(db.scale),
		tostring(db.point), tostring(db.relPoint), tostring(db.x), tostring(db.y),
	}
	if db.underMinimap then
		parts[#parts + 1] = tostring(ns.IsMinimapSquare and ns.IsMinimapSquare())
		parts[#parts + 1] = tostring(ns.IsMinimapZoomOutside and ns.IsMinimapZoomOutside())
		parts[#parts + 1] = tostring(Minimap:GetWidth())
		parts[#parts + 1] = tostring(Minimap:GetEffectiveScale() / UIParent:GetEffectiveScale())
		parts[#parts + 1] = tostring(ns.MinimapMemoWidth and ns.MinimapMemoWidth())
	end
	for _, e in ipairs(list) do
		parts[#parts + 1] = e.key .. "=" .. e.castName .. "=" .. tostring(e.texture)
	end
	return table.concat(parts, "\1")
end
local setupSignature   -- 끝까지 마친 마지막 전체 배치의 입력 (nil이면 다음은 무조건 전체 배치)

-- full: 입력이 같아도 버튼을 처음부터 다시 세팅한다 (설정·위치·미니맵·전투 끝 등)
local function Layout(full)
	if not db then return end
	if InCombatLockdown() then
		pendingAfterCombat = true
		return
	end
	pendingAfterCombat = false

	local fresh = Collect()
	local setup = SetupSignature(fresh)
	local list, extraCount, below = {}, 0, 0
	-- 이동 모드 중엔 드래그와 겹칠 수 있어서 늘 전체 배치로 막대 자리를 다시 잡는다.
	if not full and not moveMode and setup == setupSignature then
		-- 구성이 그대로면 보안 버튼은 건드리지 않고 새 항목만 같은 자리 버튼에 다시 건다.
		for i, e in ipairs(fresh) do
			local old = available[i]
			local btn = old and old.button
			if old then old.button = nil end
			if btn then
				btn.entry = e
				e.button = btn
				list[#list + 1] = btn
			end
		end
		available = fresh
		if db.underMinimap then below = AttachedBelow(#list) end
		-- 전체 배치가 하던 숨김→보임을 마우스 올린 버튼에만 해서 툴팁도 똑같이 새로 뜨게 한다.
		for _, btn in ipairs(list) do
			if btn:IsMouseMotionFocus() then
				btn:Hide()
				btn:Show()
			end
		end
	else
		setupSignature = nil   -- 중간에 터지면 다음 배치도 전체로
		for _, e in ipairs(available) do e.button = nil end
		available = fresh

		local function Reset(btn)
			btn:Hide()
			btn:SetAttribute("*type1", nil)
			btn:SetAttribute("*macrotext1", nil)
			btn.entry = nil
		end
		for _, btn in pairs(buttons) do Reset(btn) end
		for _, btn in ipairs(extraButtons) do Reset(btn) end

		if db.enabled then
			for _, e in ipairs(available) do
				local btn = e.kind and buttons[e.kind.key]
				if not btn then
					extraCount = extraCount + 1
					btn = extraButtons[extraCount] or CreateButton(nil)
					extraButtons[extraCount] = btn
				end
				btn:SetAttribute("*type1", "macro")
				btn:SetAttribute("*macrotext1", "/cast !" .. e.castName)
				btn.icon:SetTexture(e.texture or DEFAULT_ICON)
				btn:EnableMouse(db.showBar)
				btn.entry = e
				e.button = btn
				btn:Show()
				list[#list + 1] = btn
			end
		end

		if db.underMinimap then
			below = PlaceAttached(list)
		else
			PlaceFree(list)
		end
		setupSignature = setup
	end

	-- 아이콘을 숨겨도 단축키는 동작해야 하므로 막대는 숨기지 않고 투명하게만 한다.
	bar:SetAlpha((db.showBar or moveMode) and 1 or 0)
	bar:SetShown(db.enabled and (#list > 0 or moveMode))
	mover:SetShown(moveMode)

	-- 아이콘 크기가 바뀌면 같은 줄의 메모 버튼이 따라 맞춘다 (정보 막대를 옮기기 전에)
	local rowSize = (db.enabled and db.showBar and db.underMinimap and #list > 0) and attachedSize or nil
	if rowSize ~= rowIconSize then
		rowIconSize = rowSize
		ns:Fire("MINIMAP_ROW_CHANGED")
	end

	if not (db.enabled and db.showBar) then below = 0 end
	if math.abs(below - belowPixels) > 0.5 then
		belowPixels = below
		ns:Fire("MINIMAP_BELOW_CHANGED")
	end

	UpdateStates()
	UpdateHotkeys()

	local keys = {}
	for _, e in ipairs(available) do keys[#keys + 1] = e.key end
	local sig = table.concat(keys, ",")
	if sig ~= signature then
		signature = sig
		ns:Fire("REBUILD_OPTIONS")
	end
end

-- 0.2초 안에 몰린 요청은 한 번으로 합친다. 그중 하나라도 full이면 전체 배치.
local layoutQueued, queuedFull = false, false
local function RequestLayout(full)
	if full then queuedFull = true end
	if layoutQueued then return end
	layoutQueued = true
	C_Timer.After(0.2, function()
		layoutQueued = false
		local f = queuedFull
		queuedFull = false
		Layout(f)
	end)
end

---------------------------------------------------------------------------
-- 위치 이동
---------------------------------------------------------------------------
mover:SetScript("OnDragStart", function() bar:StartMoving() end)
mover:SetScript("OnDragStop", function()
	bar:StopMovingOrSizing()
	local point, _, relPoint, x, y = bar:GetPoint(1)
	db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
	db.underMinimap = false
end)

-- 미니맵에 붙어 있던 막대를 지금 화면 위치 그대로 자유 위치로 바꾼다.
local function Detach()
	local x, y = bar:GetCenter()
	if x and y and bar:IsShown() then
		local ratio = bar:GetEffectiveScale() / (UIParent:GetEffectiveScale() * db.scale)
		db.point, db.relPoint, db.x, db.y = "CENTER", "BOTTOMLEFT", x * ratio, y * ratio
	end
	db.underMinimap = false
end

local function SetMoveMode(on)
	if InCombatLockdown() then
		Print("전투 중에는 할 수 없어요.")
		return
	end
	if on and not db.enabled then
		Print("추적 기능이 꺼져 있어요.")
		return
	end
	if on and db.underMinimap then Detach() end
	moveMode = on
	Layout(true)
	ns:Fire("REFRESH_UI")
	if on then Print("추적 아이콘을 드래그해서 옮기세요. 다 옮기면 [이동 완료]를 누르세요.") end
end

local function AttachToMinimap()
	if InCombatLockdown() then
		Print("전투 중에는 할 수 없어요.")
		return
	end
	db.underMinimap = true
	moveMode = false
	Layout(true)
	ns:Fire("REFRESH_UI")
	Print("추적 아이콘을 미니맵에 붙였습니다.")
end

ns:On("MINIMAP_LAYOUT_CHANGED", function()
	if db and db.underMinimap then RequestLayout(true) end
end)

---------------------------------------------------------------------------
-- 이벤트
---------------------------------------------------------------------------
ns:RegisterEvent("MINIMAP_UPDATE_TRACKING", function()
	if not db then return end
	UpdateStates()
	RequestLayout()
end)

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
	if db then RequestLayout(true) end
end)

for _, event in ipairs({ "SPELLS_CHANGED", "SKILL_LINES_CHANGED" }) do
	ns:RegisterEvent(event, function()
		if db then RequestLayout() end
	end)
end

ns:RegisterEvent("UPDATE_BINDINGS", function()
	if db then UpdateHotkeys() end
end)

ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
	if pendingAfterCombat then Layout(true) end
end)

-- 전투 시작 직전(아직 보안 프레임을 바꿀 수 있을 때) 이동 모드를 끈다.
ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
	if moveMode then
		moveMode = false
		Layout(true)
		ns:Fire("REFRESH_UI")
	end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
end

function M:OnLogin()
	Layout(true)
end

function M:ApplySettings(changes)
	if changes.enabled == false then moveMode = false end
	Layout(true)
end

function M:BuildOptions(b)
	local function Disabled() return not db.enabled end

	b:Text("배운 추적 기술만 아이콘으로 모아 보여 줍니다. 아이콘을 클릭하거나 단축키를 누르면 그 추적을 켜고, "
		.. "우클릭하면 끕니다. 지금 켜져 있는 추적은 금색 테두리로 표시됩니다.")
	b:Check{ key = "enabled", label = "사용" }

	b:Header("단축키")
	local count = 0
	for _, e in ipairs(available) do
		if e.kind then
			b:KeyBind{ command = e.kind.binding, label = e.name, depends = "enabled" }
			count = count + 1
		end
	end
	if count == 0 then
		b:Text("아직 쓸 수 있는 추적 기술이 없어요. 사냥꾼 추적, 약초 채집·채광, 드워프의 보물 찾기를 배우면 여기에 나타납니다.",
			{ color = { 0.7, 0.7, 0.7 } })
	else
		b:Text("버튼을 클릭한 뒤 원하는 키를 누르세요. 우클릭: 해제 / ESC: 취소", { color = { 0.6, 0.6, 0.6 } })
	end

	b:Header("화면 아이콘")
	b:Check{
		key = "showBar",
		label = "화면에 추적 아이콘 표시",
		tooltip = "꺼도 단축키는 그대로 동작합니다.",
		depends = "enabled",
	}
	b:Slider{
		key = "scale", label = "아이콘 크기 (옮겼을 때)", min = 0.5, max = 2, step = 0.05, format = "%.2f", depends = "enabled",
		disabled = function() return db.underMinimap end,
		tooltip = "미니맵에 붙어 있을 때는 미니맵 너비에 맞춰 자동으로 정해집니다.",
	}
	b:Buttons{
		{
			text = "위치 이동",
			textFunc = function() return moveMode and "이동 완료" or "위치 이동" end,
			onClick = function() SetMoveMode(not moveMode) end,
			disabled = Disabled,
			tooltip = "화면의 추적 아이콘을 드래그해서 옮길 수 있게 합니다. 옮기면 미니맵에서 떨어집니다.",
		},
		{
			text = "미니맵에 붙이기", onClick = AttachToMinimap, disabled = Disabled,
			tooltip = "네모 미니맵이면 지도 바로 아래에, 둥근 미니맵이면 테두리 아래에 붙입니다.",
		},
	}
	b:Text("- 동시에 켤 수 있는 추적 수는 게임 규칙을 따릅니다. 하나만 켜지는 경우 다른 추적을 켜면 앞의 것이 꺼져요.",
		{ color = { 0.7, 0.7, 0.7 } })
end
