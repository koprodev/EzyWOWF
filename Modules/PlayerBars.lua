-- Player resources follow the target nameplate; bear-form mana is the final row.
-- Pet health occupies the combo slot when combo points are unavailable.
--
-- 체력은 늘 비밀값이라 계산은 못 한다. 막대(SetValue)와 글자(SetFormattedText)는 비밀값을 받으니 그대로 넘기기만 한다.
-- 연계 점수는 칸마다 막대 하나(최소 i-1, 최대 i)에 같은 값을 넣는다. 비교 없이도 i점이 되면 i번째 칸이 찬다.
-- 대상 이름표 하나에만 그리니까 대상이 없으면 아무것도 안 읽고 쉰다. 자리 잡기는 PlateStack.

local _, ns = ...

local M = ns:NewModule("PlayerBars", {
	title = "내 상태 막대",
	category = "info",
	icon = "Interface\\Icons\\Spell_Holy_WordFortitude",
	order = 36,
	defaults = {
		enabled = true,
		showHealth = true,
		showPower = true,
		showDruidMana = true,
		showCombo = true,
		showPet = true,
		combatOnly = false,
		-- 두께·퍼센트 숫자는 이름표 모양(PlateStack.style)에서 정한다
	},
})

local RETRY_INTERVAL = 0.2   -- 대상 이름표는 있는데 생명력 바가 안 보일 때 다시 붙여 보는 간격
local MAX_SEGMENTS = 10
local SEGMENT_GAP = 3   -- 칸 사이. 테두리가 양쪽으로 1px씩 나오니 3이어야 1px 틈이 보인다

local COLORS = {
	health = { 0.2, 0.8, 0.3 },
	power  = { 0.15, 0.55, 1 },
	rage   = { 0.85, 0.15, 0.1 },
	energy = { 1, 0.85, 0.1 },
	combo  = { 1, 0.85, 0.1 },
	pet    = { 1, 0.85, 0.1 },
}

local IsSecret = issecretvalue or function() return false end
local Stack = ns.PlateStack
local SCALE = CurveConstants and CurveConstants.ScaleTo100
local PT = Enum and Enum.PowerType
local MANA = PT and PT.Mana

local db, isDruid
local activePlate    -- 지금 줄을 띄우는 대상 이름표 (띄울 줄이 없어도 대상이 유효하면 기억)
local activeToken    -- 그 이름표의 유닛 토큰. 제거 이벤트 때 API가 이미 nil을 줄 수 있어서 적어 둔다
local inCombat = false
local dirty, retry, sinceRetry = false, false, 0
local state = {}     -- 갱신 한 번 동안 쓰는 내 자원 정보 (표를 매번 새로 안 만들려고 돌려 씀)

local function PlateFor(unit)
	local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
	if not plate or (plate.IsForbidden and plate:IsForbidden()) then return nil end
	return plate
end

---------------------------------------------------------------------------
-- 막대 채우기
---------------------------------------------------------------------------
local function SetPercent(fs, pct)
	if not Stack.style.showPercent or (not IsSecret(pct) and pct == nil) then
		fs:Hide()
		return
	end
	if IsSecret(pct) then
		fs:SetFormattedText("%.0f%%", pct)
	else
		fs:SetFormattedText("%d%%", math.floor(pct))   -- 반올림하면 99.6%가 100%로 보여서 내림
	end
	fs:Show()
end

-- 일반값인데 비었거나 0 이하면 1로 (빈 막대). 비밀값은 건드리면 오류라서 그대로.
local function SafeMax(max)
	if IsSecret(max) then return max end
	if not max or max <= 0 then return 1 end
	return max
end

local function HealthPercent(unit)
	if UnitHealthPercent and SCALE then return UnitHealthPercent(unit, true, SCALE) end
end

local function PowerPercent(powerType)
	if UnitPowerPercent and SCALE then return UnitPowerPercent("player", powerType, false, SCALE) end
end

local function FillHealth(bar, unit, color)
	bar:SetMinMaxValues(0, SafeMax(UnitHealthMax(unit)))
	bar:SetValue(UnitHealth(unit))
	bar:SetStatusBarColor(color[1], color[2], color[3])
	SetPercent(bar.text, HealthPercent(unit))
end

local function PowerColor(s)
	local c
	if s.powerToken == "RAGE" or (PT and PT.Rage ~= nil and s.powerType == PT.Rage) then c = COLORS.rage
	elseif s.powerToken == "ENERGY" or (PT and PT.Energy ~= nil and s.powerType == PT.Energy) then c = COLORS.energy
	elseif s.powerToken == "MANA" or (MANA ~= nil and s.powerType == MANA) then c = COLORS.power end
	if c then return c[1], c[2], c[3] end
	if GetPowerBarColor then
		local c = (s.powerToken and GetPowerBarColor(s.powerToken)) or (s.powerType and GetPowerBarColor(s.powerType))
		if type(c) == "table" and c.r then return c.r, c.g, c.b end
	end
	local c = COLORS.power
	return c[1], c[2], c[3]
end

local function FillPower(bar, s)
	bar:SetMinMaxValues(0, SafeMax(s.powerMax))
	bar:SetValue(UnitPower("player", s.powerType))
	bar:SetStatusBarColor(PowerColor(s))
	SetPercent(bar.text, PowerPercent(s.powerType))
end

local function FillDruidMana(bar, s)
	bar:SetMinMaxValues(0, SafeMax(s.manaMax))
	bar:SetValue(UnitPower("player", MANA))
	local c = COLORS.power
	bar:SetStatusBarColor(c[1], c[2], c[3])
	SetPercent(bar.text, PowerPercent(MANA))
end

-- 칸 경계는 너비를 재지 않고 앵커로 잡는다. 안 보이는 자 막대(0~N 중 k)의 채움 끝이 정확히 k/N 지점이라
-- 칸 i를 경계 i-1과 i 사이에 걸면 된다. 시전 바 불꽃과 같은 수법이라 너비가 비밀값이어도 엔진이 자리를 잡는다.
local function CreateComboRow(container)
	local row = CreateFrame("Frame", nil, container)
	row.segments, row.marks = {}, {}
	return row
end

-- k/N 지점의 윗점·아랫점을 줄 수 있는 영역 (k = 0이면 줄 왼쪽, N이면 줄 오른쪽)
local function Edge(row, k, n)
	if k == 0 then return row, "TOPLEFT", "BOTTOMLEFT" end
	if k == n then return row, "TOPRIGHT", "BOTTOMRIGHT" end
	return row.marks[k]:GetStatusBarTexture(), "TOPRIGHT", "BOTTOMRIGHT"
end

local function SetSegmentCount(row, n)
	if row.count == n then return end
	for k = 1, n - 1 do
		local mark = row.marks[k]
		if not mark then
			mark = CreateFrame("StatusBar", nil, row)
			mark:SetAllPoints()
			mark:SetStatusBarTexture(Stack.BAR_TEXTURE)
			mark:SetStatusBarColor(0, 0, 0, 0)
			row.marks[k] = mark
		end
		mark:SetMinMaxValues(0, n)
		mark:SetValue(k)
		mark:Show()
	end
	for k = n, #row.marks do row.marks[k]:Hide() end

	local c = COLORS.combo
	local leftInset, rightInset = math.ceil(SEGMENT_GAP / 2), math.floor(SEGMENT_GAP / 2)
	for i = 1, n do
		local seg = row.segments[i]
		if not seg then
			seg = CreateFrame("StatusBar", nil, row)
			seg:SetStatusBarTexture(Stack.BAR_TEXTURE)
			seg:SetStatusBarColor(c[1], c[2], c[3])
			Stack.AddBackground(seg)
			row.segments[i] = seg
		end
		seg:SetMinMaxValues(i - 1, i)
		local left, leftTop = Edge(row, i - 1, n)
		local right, _, rightBottom = Edge(row, i, n)
		seg:ClearAllPoints()
		seg:SetPoint("TOPLEFT", left, leftTop, i > 1 and leftInset or 0, 0)
		seg:SetPoint("BOTTOMRIGHT", right, rightBottom, i < n and -rightInset or 0, 0)
		seg:Show()
	end
	for i = n + 1, #row.segments do row.segments[i]:Hide() end
	row.count = n
end

local function FillCombo(row, s)
	SetSegmentCount(row, s.comboCount)
	local points = GetComboPoints("player", "target")
	for i = 1, s.comboCount do row.segments[i]:SetValue(points) end
end

---------------------------------------------------------------------------
-- 줄 정의 (위에서 아래 순서)
---------------------------------------------------------------------------
local ROWS = {
	{
		key = "health", order = 20, create = Stack.CreateBar,
		want = function() return db.showHealth end,
		fill = function(bar) FillHealth(bar, "player", COLORS.health) end,
	},
	{
		key = "power", order = 30, create = Stack.CreateBar,
		want = function(s) return db.showPower and s.hasPower end,
		fill = FillPower,
	},
	{
		key = "combo", order = 40, create = CreateComboRow, tall = true,   -- 칸이라 막대보다 두껍게 (연계 칸 두께)
		want = function(s) return db.showCombo and s.comboCount ~= nil end,
		fill = FillCombo,
	},
	{
		key = "pet", order = 45, create = Stack.CreateBar,
		want = function(s) return db.showPet and s.comboCount == nil and UnitExists("pet") end,
		fill = function(bar) FillHealth(bar, "pet", COLORS.pet) end,
	},
	{
		key = "druidMana", order = 50, create = Stack.CreateBar,
		want = function(s) return s.hasDruidMana end,
		fill = FillDruidMana,
	},
}

-- 연계 점수 칸 수. 연계 점수를 안 쓰는 상태(사냥꾼, 곰·인간 드루이드)이거나 최대치를 모르면 nil
local function ComboCount(powerType)
	local PT = Enum and Enum.PowerType
	if not (PT and PT.ComboPoints and PT.Energy) or powerType == nil or powerType ~= PT.Energy then return nil end
	local max = UnitPowerMax("player", PT.ComboPoints)
	if IsSecret(max) or not max or max <= 0 then return nil end
	return math.min(max, MAX_SEGMENTS)
end

local function ReadState(s)
	local powerType, powerToken = UnitPowerType("player")
	if IsSecret(powerType) then powerType, powerToken = nil, nil end
	if IsSecret(powerToken) then powerToken = nil end
	s.powerType, s.powerToken = powerType, powerToken
	s.powerMax = UnitPowerMax("player", powerType)
	s.hasPower = IsSecret(s.powerMax) or (s.powerMax ~= nil and s.powerMax > 0)
	s.comboCount = ComboCount(powerType)
	s.hasDruidMana, s.manaMax = false, nil
	if isDruid and db.showDruidMana and MANA ~= nil and ns.DruidForms then
		local form = ns.DruidForms.GetCurrent()
		if form.kind == "bear" then
			s.manaMax = UnitPowerMax("player", MANA)
			s.hasDruidMana = IsSecret(s.manaMax) or (s.manaMax ~= nil and s.manaMax > 0)
		end
	end
end

---------------------------------------------------------------------------
-- 갱신
---------------------------------------------------------------------------
local driver = CreateFrame("Frame")
driver:Hide()

local function HideRows(plate)
	for _, row in ipairs(ROWS) do Stack:Hide(plate, row.key) end
end

local function TargetPlate()
	if not (db and db.enabled) then return nil end
	if db.combatOnly and not inCombat then return nil end
	if not UnitCanAttack("player", "target") then return nil end
	return PlateFor("target")
end

local function Update()
	dirty, sinceRetry = false, 0
	local plate = TargetPlate()
	-- 이전 대상 것부터 치운다 (새 대상이 없어도)
	if activePlate and activePlate ~= plate then HideRows(activePlate) end
	activePlate, activeToken, retry = nil, nil, false
	if not plate then return end

	ReadState(state)
	for _, row in ipairs(ROWS) do
		if row.want(state) then
			row.fill(Stack:Acquire(plate, row.key, row.create), state)
			local height = row.tall and Stack.style.comboHeight or Stack.style.barHeight
			if not Stack:Show(plate, row.key, height) then
				-- 생명력 바가 아직(또는 잠깐) 안 보인다. PlateStack이 이 이름표 줄을 다 치웠으니 잠시 뒤 다시.
				retry = true
				driver:Show()
				return
			end
		else
			Stack:Hide(plate, row.key)
		end
	end
	activePlate = plate
	activeToken = plate.GetUnit and plate:GetUnit() or nil
end

-- 이벤트가 몰려도 한 화면에 한 번만 다시 그린다. 할 일이 없으면 쉰다.
driver:SetScript("OnUpdate", function(self, elapsed)
	if not dirty then
		sinceRetry = sinceRetry + elapsed
		if sinceRetry < RETRY_INTERVAL then return end
	end
	Update()
	if not retry then self:Hide() end
end)

local function RequestUpdate()
	dirty = true
	driver:Show()
end

-- 생명력 바가 사라져서 PlateStack이 줄을 치웠다. 줄마다 불리니 여러 번 와도 괜찮게.
local function OnLost(plate)
	if plate ~= activePlate then return end
	activePlate, activeToken = nil, nil
	RequestUpdate()
end

for _, row in ipairs(ROWS) do Stack:RegisterRow(row.key, row.order, OnLost) end

-- 대상·이름표·전투처럼 띄울 곳이 바뀌는 이벤트
local function Wake()
	if db and (db.enabled or activePlate) then RequestUpdate() end
end

-- 값만 바뀌는 이벤트: 띄운 대상이 없으면 바로 끝
local function OnValueEvent()
	if activePlate then RequestUpdate() end
end

ns:RegisterEvent("PLAYER_TARGET_CHANGED", Wake)
ns:RegisterUnitEvent("UNIT_FACTION", Wake, "player", "target")

ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", function()
	if not activePlate then Wake() end   -- 대상 이름표가 늦게 나타난 경우
end)

ns:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, unit)
	if not activePlate then return end
	local plate = PlateFor(unit)
	if unit == activeToken or plate == activePlate or (plate == nil and activeToken == nil) then
		HideRows(activePlate)
		activePlate, activeToken = nil, nil
		Wake()
	end
end)

ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
	inCombat = true
	Wake()
end)

ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
	inCombat = false
	Wake()
end)

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
	inCombat = InCombatLockdown() and true or false
	Wake()
end)

ns:RegisterUnitEvent("UNIT_HEALTH", OnValueEvent, "player", "pet")
ns:RegisterUnitEvent("UNIT_MAXHEALTH", OnValueEvent, "player", "pet")
ns:RegisterUnitEvent("UNIT_POWER_FREQUENT", OnValueEvent, "player")
ns:RegisterUnitEvent("UNIT_MAXPOWER", OnValueEvent, "player")
ns:RegisterUnitEvent("UNIT_DISPLAYPOWER", OnValueEvent, "player")
ns:RegisterUnitEvent("UNIT_PET", OnValueEvent, "player")
ns:RegisterEvent("UPDATE_SHAPESHIFT_FORM", OnValueEvent)
ns:RegisterEvent("UPDATE_SHAPESHIFT_FORMS", OnValueEvent)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	db.height, db.showText = nil, nil   -- 0.4.1부터 이름표 모양으로 옮겨 간 설정
	db.powerColor = nil
	local _, class = UnitClass("player")
	isDruid = not IsSecret(class) and class == "DRUID"
	inCombat = InCombatLockdown() and true or false
end

function M:ApplySettings()
	Update()
end

ns:On("PLATE_STYLE_CHANGED", function()
	if db then Update() end
end)

function M:BuildOptions(b)
	b:Text("적을 대상으로 잡으면 그 적의 이름표 밑에 내 체력 · 마나·기력·분노 · 연계 점수를 막대로 띄웁니다. "
		.. "자원 막대 색은 분노 빨강·기력 노랑·마나 파랑입니다. 연계 점수를 안 쓰는 캐릭터(사냥꾼 등)는 펫 체력을 띄웁니다. "
		.. "드루이드 곰 변신에서는 맨 아래에 남은 마나를 파란 막대로 추가합니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Check{ key = "showHealth", label = "내 체력", depends = "enabled" }
	b:Check{ key = "showPower", label = "내 마나·기력·분노", depends = "enabled" }
	b:Check{
		key = "showDruidMana", label = "곰 변신 중 남은 마나", depends = "enabled",
		tooltip = "드루이드가 곰·광포한 곰으로 변신하면 맨 아래에 파란 마나 막대를 추가합니다. 인간형·표범·이동 변신에서는 숨깁니다.",
	}
	b:Check{
		key = "showCombo", label = "연계 점수", depends = "enabled",
		tooltip = "도적, 표범 변신 드루이드의 연계 점수를 칸으로 보여 줍니다. 0점이어도 빈 칸은 그대로 있습니다.",
	}
	b:Check{
		key = "showPet", label = "펫 체력", depends = "enabled",
		tooltip = "연계 점수를 안 쓰는 캐릭터가 펫을 데리고 있으면 마지막 줄에 펫 체력을 띄웁니다.",
	}
	b:Check{ key = "combatOnly", label = "전투 중에만", depends = "enabled", tooltip = "전투가 아닐 때는 막대를 숨깁니다." }
	b:Text("- 이름표가 켜져 있어야 보입니다(기본 단축키 V).\n"
		.. "- 어그로 상자가 떠 있으면 그 오른쪽에, 없으면 생명력 바 바로 밑에 붙습니다.\n"
		.. "- 두께와 퍼센트 숫자는 화면 정보 > 이름표 모양에서 정합니다.",
		{ color = { 0.7, 0.7, 0.7 } })
end
