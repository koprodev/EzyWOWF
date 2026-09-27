-- 어그로 게이지: 적 이름표의 생명력 바 밑에 내 위협 수준(어그로)을 막대로 보여 준다.
--
-- 값은 UnitDetailedThreatSituation("player", 이름표 유닛)의 scaledPercentage. 100%가 되는 순간 어그로가 나에게 온다.
-- "나 + 이름표 유닛" 조합은 보통 비밀값이 아니지만, 혹시 비밀값이면 막대·글자에만 그대로 넘기고 색은 회색으로 둔다.
-- 자리 잡기(생명력 바 밑, 시전 바 비키기, 다른 줄과 쌓기)는 PlateStack이 맡는다. 게이지는 맨 윗줄.

local _, ns = ...

local M = ns:NewModule("Threat", {
	title = "어그로 게이지",
	category = "info",
	icon = "Interface\\Icons\\Spell_Nature_Reincarnation",
	order = 35,
	defaults = {
		enabled = true,
		mode = "target",   -- target = 대상만, all = 전투 중인 모든 적
		-- 두께·퍼센트 숫자는 모든 줄이 같이 쓴다: 이름표 모양(PlateStack.style)
	},
})

local ROW = "threat"
local POLL_INTERVAL = 0.5 -- 이벤트를 놓쳐도 전투 중에는 이 간격으로 다시 읽는다
local WARN_PERCENT = 80

local COLORS = {
	safe     = { 0.25, 0.8, 0.25 },
	warn     = { 1, 0.82, 0 },     -- 곧 어그로가 넘어옴
	insecure = { 1, 0.5, 0 },      -- 어그로는 내 것인데 2등이 바짝 붙음
	tanking  = { 1, 0.15, 0.15 },
	unknown  = { 0.7, 0.7, 0.7 },  -- 비밀값이라 상태를 못 읽음
}

local IsSecret = issecretvalue or function() return false end
local Stack = ns.PlateStack

local db
local units = {}      -- [이름표 유닛 토큰] = true
-- 게이지는 UpdateUnit 끝에서만 켜고 HidePlate(또는 PlateStack의 onLost)로만 끈다. 대상만 모드는 이 표만 보고 치우니 샛길 금지.
local shown = {}      -- [이름표] = true (게이지를 켜 둔 이름표)
local plateUnit = {}  -- [이름표] = 마지막으로 본 유닛 토큰. 이름표는 돌려 쓰니 꺼낼 때마다 확인한다

---------------------------------------------------------------------------
-- 게이지
---------------------------------------------------------------------------
local function PlateFor(unit)
	local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
	if not plate or (plate.IsForbidden and plate:IsForbidden()) then return nil end
	return plate
end

local function HidePlate(plate)
	Stack:Hide(plate, ROW)
	shown[plate] = nil
end

-- 생명력 바가 사라져서 PlateStack이 게이지를 치웠다
Stack:RegisterRow(ROW, 10, function(plate) shown[plate] = nil end)

local function CreateBar(container)
	local bar = Stack.CreateBar(container)
	bar:SetMinMaxValues(0, 100)
	return bar
end

local function ColorFor(status, pct)
	if status == 3 then return COLORS.tanking end
	if status == 2 then return COLORS.insecure end
	if status == 1 or pct >= WARN_PERCENT then return COLORS.warn end
	return COLORS.safe
end

-- targetPlate: 대상 이름표. 갱신 한 번 동안은 안 바뀌니 UpdateTarget이 한 번만 구해서 넘긴다.
local function IsWanted(unit, plate, targetPlate)
	if not UnitCanAttack("player", unit) then return false end
	if db.mode == "all" then return true end
	return targetPlate == plate
end

local function UpdateUnit(unit, targetPlate)
	local plate = PlateFor(unit)
	if not plate then return end
	if not (db.enabled and IsWanted(unit, plate, targetPlate)) then return HidePlate(plate) end

	-- 그 적의 위협 목록에 내가 없으면(전투 전, 펫만 싸우는 중 등) 아무것도 돌려주지 않는다.
	local _, status, pct = UnitDetailedThreatSituation("player", unit)
	local secret = IsSecret(pct)
	if not secret and pct == nil then return HidePlate(plate) end

	local bar = Stack:Acquire(plate, ROW, CreateBar)
	if not Stack:Show(plate, ROW, Stack.style.barHeight) then return HidePlate(plate) end

	local color = (secret or IsSecret(status)) and COLORS.unknown or ColorFor(status, pct)
	bar:SetValue(pct)
	bar:SetStatusBarColor(color[1], color[2], color[3])
	if Stack.style.showPercent then
		if secret then
			bar.text:SetFormattedText("%.0f%%", pct)
		else
			bar.text:SetFormattedText("%d%%", math.floor(pct))   -- 반올림하면 99.6%가 100%로 보여서 내림
		end
		bar.text:Show()
	else
		bar.text:Hide()
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

-- 대상만 모드: 대상 말고 켜진 게이지는 끄고 대상 하나만 다시 읽는다. 결과는 전부 도는 것과 같다.
local function UpdateTarget()
	local targetPlate = UnitExists("target") and PlateFor("target") or nil
	for plate in pairs(shown) do
		if plate ~= targetPlate then HidePlate(plate) end
	end
	local unit = targetPlate and TokenFor(targetPlate)
	if unit then UpdateUnit(unit, targetPlate) end
end

local function UpdateAll()
	dirty, sinceUpdate = false, 0
	if db and db.enabled and db.mode ~= "all" then
		UpdateTarget()
	else
		for unit in pairs(units) do UpdateUnit(unit) end
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
	"PLAYER_TARGET_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
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
	-- 두께가 바뀌었을 수 있다. 이번 갱신에서 안 건드리는 게이지도 새 두께로, 자리도 다시 잰다 (v0.4.0과 같게)
	for plate in pairs(shown) do Stack:SetHeight(plate, ROW, Stack.style.barHeight) end
	Stack:Invalidate()
	UpdateAll()
	driver:SetShown(db.enabled)
end

ns:On("PLATE_STYLE_CHANGED", function()
	if db then M:ApplySettings() end
end)

local MODES = {
	{ value = "target", text = "대상만" },
	{ value = "all",    text = "전투 중인 모든 적" },
}

local function Colored(color, text)
	local function Hex(v) return math.floor(v * 255 + 0.5) end
	return ("|cff%02x%02x%02x%s|r"):format(Hex(color[1]), Hex(color[2]), Hex(color[3]), text)
end

function M:BuildOptions(b)
	b:Text("적 이름표의 생명력 바 밑에 내 어그로(위협 수준) 게이지를 띄웁니다. 100%가 되면 그 적이 나를 노립니다. "
		.. "그 적과 전투를 시작해서 내가 위협 목록에 올라 있을 때만 보입니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Dropdown{
		key = "mode", label = "표시할 적", width = 200, depends = "enabled",
		options = function() return MODES end,
		tooltip = "대상만: 지금 대상으로 잡은 적에게만 띄웁니다.\n전투 중인 모든 적: 나와 싸우는 적마다 띄웁니다.",
	}
	b:Text("색:  " .. Colored(COLORS.safe, "초록 안전") .. "   " .. Colored(COLORS.warn, "노랑 곧 넘어옴")
		.. "   " .. Colored(COLORS.insecure, "주황 내 어그로(불안)") .. "   " .. Colored(COLORS.tanking, "빨강 내 어그로"))
	b:Text("- 이름표가 켜져 있어야 보입니다(기본 단축키 V).\n"
		.. "- 두께와 퍼센트 숫자는 화면 정보 > 이름표 모양에서 내 상태 막대와 같이 정합니다.\n"
		.. "- 사냥꾼: 펫이 몹을 잡고 있을 때 게이지가 100%에 가까워지면 어그로가 나에게 넘어오니 잠깐 쉬어 가세요.",
		{ color = { 0.7, 0.7, 0.7 } })
end
