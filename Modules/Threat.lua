-- 어그로 표시: 적 이름표의 생명력 바 밑 왼쪽 네모 상자에 내 위협 수준(어그로)을 85%처럼 숫자로 보여 준다.
--
-- 값은 UnitDetailedThreatSituation("player", 유닛)의 scaledPercentage. 100%가 되는 순간 어그로가 나에게 온다.
-- 포에버는 nameplateN으로 물으면 status·퍼센트를 비밀값으로 주고 target·focus로 물으면 보통 그냥 준다.
-- 그래서 대상·주시 대상 이름표는 target·focus로 묻는다. 비밀값은 글자·색 함수에만 넘기고,
-- 색은 isTanking(비밀 불린)을 블리자드 함수에 맡겨 빨강/초록 중에 고른다. 그것도 안 되면 회색.
-- 상태 색은 글자나 상자 바탕 중 하나에 칠한다. 자리 잡기는 PlateStack의 옆 상자(다른 줄은 그 오른쪽으로).

local _, ns = ...

local M = ns:NewModule("Threat", {
	title = "어그로 표시",
	category = "info",
	icon = "Interface\\Icons\\Spell_Nature_Reincarnation",
	order = 35,
	defaults = {
		enabled = true,
		mode = "target",   -- target = 대상만, all = 전투 중인 모든 적
		colorBy = "text",  -- text = 글자 색, background = 바탕 색
	},
})

local ROW = "threat"
local POLL_INTERVAL = 0.5 -- 이벤트를 놓쳐도 전투 중에는 이 간격으로 다시 읽는다
local WARN_PERCENT = 80
local BOX_WIDTH = 30       -- "100%"가 들어가게 잡은 폭 (게임에서 글자 폭은 아직 안 재 봄)
local BOX_MIN_HEIGHT = 11  -- 기본 두께 두 줄(4+3+4)과 아래 끝이 맞는 높이. 오른쪽 줄이 없어도 이만큼
local TEXT_SIZE = 10
local BG_ALPHA = 0.9

local COLORS = {
	safe     = { 0.25, 0.8, 0.25 },
	warn     = { 1, 0.82, 0 },     -- 곧 어그로가 넘어옴
	insecure = { 1, 0.5, 0 },      -- 어그로는 내 것인데 2등이 바짝 붙음
	tanking  = { 1, 0.15, 0.15 },
	unknown  = { 0.7, 0.7, 0.7 },  -- 비밀값이라 상태를 못 읽음
}

local IsSecret = issecretvalue or function() return false end
-- 비밀 불린으로 색 성분 하나를 고른다. 비밀값을 참/거짓으로 따지면 오류라 엔진에 맡긴다
local PickByBool = C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean
-- 비밀 숫자를 내림한 글자로. Lua로는 비밀값을 내릴 수 없어서 엔진 함수를 쓴다 (없으면 반올림으로 물러섬)
local FloorText = C_StringUtil and C_StringUtil.FloorToNearestString
local Stack = ns.PlateStack

local db
local units = {}      -- [이름표 유닛 토큰] = true
-- 상자는 UpdateUnit 끝에서만 켜고 HidePlate(또는 PlateStack의 onLost)로만 끈다. 대상만 모드는 이 표만 보고 치우니 샛길 금지.
local shown = {}      -- [이름표] = true (상자를 켜 둔 이름표)
local plateUnit = {}  -- [이름표] = 마지막으로 본 유닛 토큰. 이름표는 돌려 쓰니 꺼낼 때마다 확인한다

---------------------------------------------------------------------------
-- 상자
---------------------------------------------------------------------------
local function PlateFor(unit)
	local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
	if not plate or (plate.IsForbidden and plate:IsForbidden()) then return nil end
	return plate
end

local function UnitPlate(unit)
	return UnitExists(unit) and PlateFor(unit) or nil
end

local function HidePlate(plate)
	Stack:Hide(plate, ROW)
	shown[plate] = nil
end

-- 생명력 바가 사라져서 PlateStack이 상자를 치웠다
Stack:RegisterRow(ROW, 10, function(plate) shown[plate] = nil end, BOX_WIDTH)

-- 1px 검은 테두리 + 바탕 + 가운데 숫자
local function CreateBox(container)
	local box = CreateFrame("Frame", nil, container)
	box.bg = Stack.AddBackground(box)
	local text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	local font = text:GetFont()
	if font then text:SetFont(font, TEXT_SIZE, "OUTLINE") end
	text:SetPoint("CENTER")
	box.text = text
	return box
end

local function ColorFor(status, pct)
	if status == 3 then return COLORS.tanking end
	if status == 2 then return COLORS.insecure end
	if status == 1 or pct >= WARN_PERCENT then return COLORS.warn end
	return COLORS.safe
end

-- 상태 색 r, g, b. 비밀값이 섞이면 돌려주는 값도 비밀일 수 있으니 받는 쪽은 넘기기만 한다
local function StateColor(isTanking, status, pct)
	local c
	if not (IsSecret(pct) or IsSecret(status)) then
		c = ColorFor(status, pct)
	elseif PickByBool and type(isTanking) == "boolean" then
		-- type()은 비밀값에도 써도 되고 원래 타입을 알려 준다. 불린이면 빨강/초록 중에 고른다
		local t, s = COLORS.tanking, COLORS.safe
		return PickByBool(isTanking, t[1], s[1]), PickByBool(isTanking, t[2], s[2]), PickByBool(isTanking, t[3], s[3])
	else
		c = COLORS.unknown
	end
	return c[1], c[2], c[3]
end

local function Paint(box, r, g, b)
	if db.colorBy == "background" then
		box.bg:SetColorTexture(r, g, b, BG_ALPHA)
		box.text:SetTextColor(1, 1, 1)
	else
		local t = Stack.TRACK_COLOR
		box.bg:SetColorTexture(t[1], t[2], t[3], t[4])
		box.text:SetTextColor(r, g, b)
	end
end

local function IsWanted(unit, plate, targetPlate)
	if not UnitCanAttack("player", unit) then return false end
	if db.mode == "all" then return true end
	return targetPlate == plate
end

-- 같은 적이라도 nameplateN으로 물으면 비밀값이 오고 target·focus로 물으면 읽힌다
local function QueryToken(unit, plate, targetPlate, focusPlate)
	if plate == targetPlate then return "target" end
	if plate == focusPlate then return "focus" end
	return unit
end

-- targetPlate·focusPlate: 대상·주시 대상 이름표. 갱신 한 번 동안은 안 바뀌니 한 번만 구해서 넘긴다.
local function UpdateUnit(unit, targetPlate, focusPlate)
	local plate = PlateFor(unit)
	if not plate then return end
	if not (db.enabled and IsWanted(unit, plate, targetPlate)) then return HidePlate(plate) end

	-- 그 적의 위협 목록에 내가 없으면(전투 전, 펫만 싸우는 중 등) 아무것도 돌려주지 않는다.
	local isTanking, status, pct = UnitDetailedThreatSituation("player", QueryToken(unit, plate, targetPlate, focusPlate))
	local secret = IsSecret(pct)
	if not secret and pct == nil then return HidePlate(plate) end

	local box = Stack:Acquire(plate, ROW, CreateBox)
	if not Stack:Show(plate, ROW, BOX_MIN_HEIGHT) then return HidePlate(plate) end

	Paint(box, StateColor(isTanking, status, pct))
	if secret and FloorText then
		box.text:SetFormattedText("%s%%", FloorText(pct))
	elseif secret then
		box.text:SetFormattedText("%.0f%%", pct)
	else
		box.text:SetFormattedText("%d%%", math.floor(pct))   -- 반올림하면 99.6%가 100%로 보여서 내림
	end
	shown[plate] = true
end

---------------------------------------------------------------------------
-- 갱신
---------------------------------------------------------------------------
local dirty = false
local sinceUpdate = 0

-- 이름표 → units에 있는 유닛 토큰. 캐시가 맞으면 바로, 틀리면 전부 뒤져서 다시 적는다.
local function TokenFor(plate)
	local unit = plateUnit[plate]
	if unit and units[unit] and PlateFor(unit) == plate then return unit end
	for u in pairs(units) do
		if PlateFor(u) == plate then
			plateUnit[plate] = u
			return u
		end
	end
	plateUnit[plate] = nil
end

-- 대상만 모드: 대상 말고 켜진 상자는 끄고 대상 하나만 다시 읽는다. 결과는 전부 도는 것과 같다.
local function UpdateTarget()
	local targetPlate = UnitPlate("target")
	for plate in pairs(shown) do
		if plate ~= targetPlate then HidePlate(plate) end
	end
	local unit = targetPlate and TokenFor(targetPlate)
	if unit then UpdateUnit(unit, targetPlate) end
end

local function UpdateAll()
	dirty, sinceUpdate = false, 0
	if not (db and db.enabled) then
		for unit in pairs(units) do UpdateUnit(unit) end   -- 꺼졌으면 UpdateUnit이 치우기만 한다
	elseif db.mode ~= "all" then
		UpdateTarget()
	else
		local targetPlate, focusPlate = UnitPlate("target"), UnitPlate("focus")
		for unit in pairs(units) do UpdateUnit(unit, targetPlate, focusPlate) end
	end
end

local function RequestUpdate()
	dirty = true
end

-- 이벤트가 몰려도 한 화면에 한 번만 다시 그린다.
local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, elapsed)
	sinceUpdate = sinceUpdate + elapsed
	if dirty then
		UpdateAll()
	elseif sinceUpdate >= POLL_INTERVAL then
		-- 전투 밖에선 0.5초에 한 번만 묻는다. 전투 시작은 PLAYER_REGEN_DISABLED가 dirty로 알려 준다.
		if InCombatLockdown() then UpdateAll() else sinceUpdate = 0 end
	end
end)

-- 추가 이벤트 순간에는 블리자드가 아직 유닛 프레임을 안 붙였을 수 있어서 다음 화면에서 그린다.
ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit)
	units[unit] = true
	-- 대상만 모드가 대상 토큰을 찾느라 전부 뒤지지 않게 미리 적어 둔다
	if db and db.mode ~= "all" then
		local plate = PlateFor(unit)
		if plate then plateUnit[plate] = unit end
	end
	RequestUpdate()
end)

ns:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, unit)
	units[unit] = nil
	local plate = PlateFor(unit)
	if plate then
		HidePlate(plate)
		if plateUnit[plate] == unit then plateUnit[plate] = nil end
	end
end)

-- UI를 다시 불러오면 이미 떠 있는 이름표를 다시 모은다.
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
	wipe(units)
	wipe(plateUnit)
	for i = 1, 40 do
		local unit = "nameplate" .. i
		if UnitExists(unit) then units[unit] = true end
	end
	RequestUpdate()
end)

for _, event in ipairs({
	"UNIT_THREAT_LIST_UPDATE", "UNIT_THREAT_SITUATION_UPDATE",
	"PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
}) do
	ns:RegisterEvent(event, RequestUpdate)
end

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	db.height, db.showText = nil, nil   -- 0.4.1부터 이름표 모양으로 옮겨 간 설정
	driver:SetShown(db.enabled)
end

function M:ApplySettings()
	Stack:Invalidate()   -- 그사이 시전 영역 크기가 바뀌었을 수 있으니 자리도 다시 잡는다
	UpdateAll()
	driver:SetShown(db.enabled)
end

local MODES = {
	{ value = "target", text = "대상만" },
	{ value = "all",    text = "전투 중인 모든 적" },
}

local COLOR_BY = {
	{ value = "text",       text = "글자 색" },
	{ value = "background", text = "바탕 색" },
}

local function Colored(color, text)
	local function Hex(v) return math.floor(v * 255 + 0.5) end
	return ("|cff%02x%02x%02x%s|r"):format(Hex(color[1]), Hex(color[2]), Hex(color[3]), text)
end

function M:BuildOptions(b)
	b:Text("적 이름표의 생명력 바 밑 왼쪽 네모 상자에 내 어그로(위협 수준)를 85%처럼 숫자로 띄웁니다. "
		.. "100%가 되면 그 적이 나를 노립니다. 그 적과 전투를 시작해서 내가 위협 목록에 올라 있을 때만 보입니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Dropdown{
		key = "mode", label = "표시할 적", width = 200, depends = "enabled",
		options = function() return MODES end,
		tooltip = "대상만: 지금 대상으로 잡은 적에게만 띄웁니다.\n전투 중인 모든 적: 나와 싸우는 적마다 띄웁니다.",
	}
	b:Dropdown{
		key = "colorBy", label = "색 표시", width = 200, depends = "enabled",
		options = function() return COLOR_BY end,
		tooltip = "글자 색: 숫자 색이 어그로 상태에 따라 바뀝니다.\n바탕 색: 상자 바탕 색이 바뀌고 숫자는 흰색입니다.",
	}
	b:Text("색:  " .. Colored(COLORS.safe, "초록 안전") .. "   " .. Colored(COLORS.warn, "노랑 곧 넘어옴")
		.. "   " .. Colored(COLORS.insecure, "주황 내 어그로(불안)") .. "   " .. Colored(COLORS.tanking, "빨강 내 어그로"))
	b:Text("- 이름표가 켜져 있어야 보입니다(기본 단축키 V).\n"
		.. "- 내 상태 막대(체력·자원)가 함께 뜨면 상자 오른쪽에 쌓입니다.\n"
		.. "- 전투 중인 모든 적: 대상·주시 대상이 아닌 적은 게임이 애드온에 어그로 단계를 알려 주지 않아 "
		.. "빨강(내 어그로)과 초록(아직 아님) 두 색만 씁니다. 80%를 넘어도 노랑이 되지 않으니 숫자를 보세요. "
		.. "우두머리처럼 게임이 감추면 대상도 이렇게 보일 수 있고, 회색은 그마저 읽지 못했다는 뜻입니다.\n"
		.. "- 사냥꾼: 펫이 몹을 잡고 있을 때 숫자가 100%에 가까워지면 어그로가 나에게 넘어오니 잠깐 쉬어 가세요.",
		{ color = { 0.7, 0.7, 0.7 } })
end
