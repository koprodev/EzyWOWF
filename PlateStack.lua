-- 이름표 줄 쌓기: 적 이름표의 생명력 바 밑에 여러 기능의 막대를 차례로 붙인다.
--
-- 줄마다 순서(order)를 정해 두면 보이는 줄만 위에서부터 쌓는다. 숨은 줄은 자리도 안 차지한다.
-- 이름표의 유닛 프레임은 여러 이름표가 돌려 쓰는 물건이라 컨테이너는 이름표 자체에 붙이고, 생명력 바는 매번 다시 찾는다.
-- 적이 시전하면 시전 바가 생명력 바 바로 밑을 차지하므로 그동안만 시전 바 밑으로 비켜 간다.
--   Stack:RegisterRow(key, order, onLost)  onLost(plate): 생명력 바가 사라져서 그 줄을 치웠을 때
--   Stack:Acquire(plate, key, create)      그 이름표의 줄 프레임. 처음이면 create(container)로 만든다
--   Stack:Show(plate, key, height)         붙일 생명력 바가 없으면 false (그 이름표의 줄은 전부 치워진다)
--   Stack:Hide(plate, key)                 onLost는 부르지 않는다
--   Stack:SetHeight(plate, key, height)    보이는 줄의 두께만 바꾼다
--   Stack:Invalidate([plate])              붙은 자리를 다음에 다시 계산한다 (이름표를 안 주면 전부)
--   Stack.CreateBar(parent)                줄에 쓰는 평면 막대 (테두리·빈 트랙 + 오른쪽 숫자 bar.text)
--   Stack.style / Stack:SetStyle(t)        모든 줄이 같이 쓰는 모양 (두께·숫자). 바뀌면 모듈은 PLATE_STYLE_CHANGED를 받는다

local _, ns = ...

local Stack = {}
ns.PlateStack = Stack

local GAP = 4        -- 생명력 바와의 간격 (대상 테두리가 2px 삐져나온다)
local ROW_GAP = 3    -- 줄 사이. 테두리가 위아래로 1px씩 삐져나와서 1px 틈이 남는다
local TEXT_SIZE = 9
local TEXT_PITCH = 10  -- 숫자를 켜면 줄과 줄 사이를 이만큼은 벌려서 위아래 숫자가 안 붙게
Stack.BAR_TEXTURE = "Interface\\Buttons\\WHITE8x8"   -- 광택 없는 단색
-- 이름표 모양 설정이 덮어쓴다. 여기 값은 그 전(또는 그 모듈 없이)에 쓰는 기본값
Stack.style = { barHeight = 4, comboHeight = 6, showPercent = false }
Stack.BORDER_COLOR = { 0, 0, 0, 0.9 }
Stack.TRACK_COLOR = { 0.16, 0.16, 0.16, 0.9 }         -- 빈 부분. 막대가 얼마나 찼는지 한눈에 보이게

-- 1px 검은 테두리 + 회색 빈 트랙. 막대(ARTWORK)가 그 위에 그려진다.
function Stack.AddBackground(bar)
	local b, t = Stack.BORDER_COLOR, Stack.TRACK_COLOR
	local border = bar:CreateTexture(nil, "BACKGROUND", nil, -1)
	border:SetPoint("TOPLEFT", -1, 1)
	border:SetPoint("BOTTOMRIGHT", 1, -1)
	border:SetColorTexture(b[1], b[2], b[3], b[4])
	local track = bar:CreateTexture(nil, "BACKGROUND", nil, 0)
	track:SetAllPoints()
	track:SetColorTexture(t[1], t[2], t[3], t[4])
end

function Stack.CreateBar(parent)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetStatusBarTexture(Stack.BAR_TEXTURE)
	Stack.AddBackground(bar)

	local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	local font = text:GetFont()
	if font then text:SetFont(font, TEXT_SIZE, "OUTLINE") end
	text:SetPoint("LEFT", bar, "RIGHT", 3, 0)
	bar.text = text
	return bar
end

local rows = {}        -- [key] = { order =, onLost = }
local rowKeys = {}     -- 쌓는 순서대로 key
local containers = {}  -- [이름표] = 컨테이너

function Stack:RegisterRow(key, order, onLost)
	assert(not rows[key], "PlateStack: 이미 등록된 줄 " .. tostring(key))
	rows[key] = { order = order, onLost = onLost }
	rowKeys[#rowKeys + 1] = key
	table.sort(rowKeys, function(a, b)
		if rows[a].order ~= rows[b].order then return rows[a].order < rows[b].order end
		return a < b
	end)
end

-- 보이는 줄만 차례로 쌓는다. c.visible[key] = 그 줄의 두께
local function Arrange(c)
	local y, bottom = 0, 0
	local minPitch = Stack.style.showPercent and TEXT_PITCH or 0
	for _, key in ipairs(rowKeys) do
		local h = c.visible[key]
		if h then
			local row = c.rows[key]
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -y)
			row:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, -y)
			row:SetHeight(h)
			bottom = y + h
			y = y + math.max(h + ROW_GAP, minPitch)
		end
	end
	c:SetHeight(math.max(bottom, 1))
end

-- 생명력 바에서 시전 영역(시전 바 + 밑의 주문 아이콘·이름 줄) 바닥까지의 거리.
-- 이름표는 위치를 잴 수 없는 영역이라(GetBottom 등은 "Can't measure restricted regions" 오류)
-- 블리자드가 그 영역을 만들 때 쓰는 설정값으로 계산한다. 값이 없으면 nil.
local function CastAreaHeight()
	local o = NamePlateSetupOptions
	local bar = type(o) == "table" and o.castBarHeight
	if type(bar) ~= "number" then return nil end
	local icon = (not o.spellNameInsideCastBar and type(o.castIconHeight) == "number") and o.castIconHeight or 0
	local spacing = type(o.castBarToHealthBarSpacing) == "number" and o.castBarToHealthBarSpacing or 0
	return spacing + bar + icon
end
Stack.CastAreaHeight = CastAreaHeight

-- 생명력 바 밑(시전 중이면 시전 영역 밑)에 맞춘다. 붙일 생명력 바가 없으면 false.
local function Attach(c)
	local uf = c.plate.UnitFrame
	local health = uf and uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar
	if not health or not health:IsVisible() then return false end
	local casts = uf.CastBarsContainer
	local casting = casts and casts.castBar and casts.castBar:IsShown() or false
	if c.anchor == health and c.casting == casting then return true end

	local dy = GAP
	if casting then dy = (CastAreaHeight() or 0) + GAP end
	c:ClearAllPoints()
	c:SetPoint("TOPLEFT", health, "BOTTOMLEFT", 0, -dy)
	c:SetPoint("TOPRIGHT", health, "BOTTOMRIGHT", 0, -dy)
	local level = health:GetFrameLevel()
	c:SetFrameLevel(level + 1)
	c.rowLevel = level + 2
	for _, row in pairs(c.rows) do row:SetFrameLevel(c.rowLevel) end
	c.anchor = health
	c.casting = casting
	return true
end

-- 생명력 바를 잃었다. 보이던 줄을 적어 두고 목록부터 비운 뒤 숨기고, 그다음 주인들에게 알린다.
-- 숨기는 도중(OnHide)이나 콜백에서 다시 Show·Hide해도 알림이 겹치거나 빠지지 않는 순서다.
local function Lose(c)
	local lost = {}
	for _, key in ipairs(rowKeys) do
		if c.visible[key] then lost[#lost + 1] = key end
	end
	wipe(c.visible)
	c.anchor = nil
	for _, key in ipairs(lost) do c.rows[key]:Hide() end
	c:Hide()
	for _, key in ipairs(lost) do
		local onLost = rows[key].onLost
		if onLost then onLost(c.plate) end
	end
end

-- 시전 바가 나타나고 사라지는 걸 따라가야 해서 보이는 동안은 매 화면 위치를 확인한다. (바뀐 게 없으면 바로 끝)
local function OnUpdate(self)
	if not Attach(self) then Lose(self) end
end

local function ContainerFor(plate)
	local c = containers[plate]
	if not c then
		c = CreateFrame("Frame", nil, plate)
		c.plate, c.rows, c.visible = plate, {}, {}
		c:SetScript("OnUpdate", OnUpdate)
		c:Hide()
		containers[plate] = c
	end
	return c
end

function Stack:Acquire(plate, key, create)
	assert(rows[key], "PlateStack: 등록 안 된 줄 " .. tostring(key))
	local c = ContainerFor(plate)
	local row = c.rows[key]
	if not row then
		row = create(c)
		row:Hide()
		if c.rowLevel then row:SetFrameLevel(c.rowLevel) end
		c.rows[key] = row
	end
	return row
end

function Stack:Show(plate, key, height)
	local c = containers[plate]
	local row = c and c.rows[key]
	assert(row, "PlateStack: Show 전에 Acquire " .. tostring(key))
	if not Attach(c) then
		Lose(c)
		return false
	end
	if c.visible[key] ~= height then
		c.visible[key] = height
		Arrange(c)
	end
	row:Show()
	c:Show()
	return true
end

function Stack:Hide(plate, key)
	local c = containers[plate]
	local row = c and c.rows[key]
	if not row then return end
	row:Hide()
	if c.visible[key] then
		c.visible[key] = nil
		if next(c.visible) then Arrange(c) else c:Hide() end
	end
end

function Stack:SetHeight(plate, key, height)
	local c = containers[plate]
	if c and c.visible[key] and c.visible[key] ~= height then
		c.visible[key] = height
		Arrange(c)
	end
end

-- 붙은 자리를 다음 Show·화면에서 다시 계산하게 한다. 같은 생명력 바·같은 시전 상태면 평소엔 다시 안 붙이니,
-- 그사이 시전 영역 크기나 레벨이 바뀌었을 수 있는 때(설정 저장, 블리자드가 이름표를 다시 배치할 때) 부른다.
function Stack:Invalidate(plate)
	if plate then
		if containers[plate] then containers[plate].anchor = nil end
		return
	end
	for _, c in pairs(containers) do c.anchor = nil end
end

-- 두께·숫자 설정을 바꾸고 떠 있는 묶음을 다시 쌓는다. 줄 두께 자체는 각 모듈이 PLATE_STYLE_CHANGED를 받아 다시 준다.
function Stack:SetStyle(style)
	for k, v in pairs(style) do Stack.style[k] = v end
	for _, c in pairs(containers) do
		if next(c.visible) then Arrange(c) end
	end
end
