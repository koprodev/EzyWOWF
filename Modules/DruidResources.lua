local _, ns = ...

local ICON = "Interface\\Icons\\Spell_Nature_HealingTouch"
local TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local ROW_HEIGHT, ROW_GAP = 18, 3
local IsSecret = issecretvalue or function() return false end
local defaults = {
	enabled = false,
	showHealth = true, showPower = true, showMana = true, showCombo = true,
	combatOnly = false,
	width = 220, scale = 1,
	point = "CENTER", relPoint = "CENTER", x = -220, y = -120,
}

local M = ns:NewModule("DruidResources", {
	title = "자원·변신 패널", category = "druid", icon = ICON, order = 10,
	defaults = defaults,
})

local db, isDruid
local moveMode, inCombat = false, false
local rows = {}
local colors = {
	health = { 0.2, 0.8, 0.3 }, mana = { 0.15, 0.4, 1 },
	rage = { 0.85, 0.15, 0.1 }, energy = { 1, 0.8, 0.1 },
	power = { 0.55, 0.6, 0.8 }, combo = { 1, 0.7, 0.05 },
}

local frame = CreateFrame("Frame", "EzyWOWFDruidResources", UIParent, "BackdropTemplate")
frame:SetFrameStrata("MEDIUM")
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:EnableMouse(false)
frame:RegisterForDrag("LeftButton")
frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
frame:SetBackdropColor(0, 0, 0, 0.65)
frame:Hide()

local formIcon = frame:CreateTexture(nil, "ARTWORK")
formIcon:SetSize(18, 18)
formIcon:SetPoint("TOPLEFT", 6, -5)
formIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

local formText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
formText:SetPoint("TOPLEFT", formIcon, "TOPRIGHT", 5, -2)
formText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -7)
formText:SetJustifyH("LEFT")

local moveLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
moveLabel:SetPoint("BOTTOM", frame, "TOP", 0, 5)
moveLabel:SetText("드루이드 자원 패널 (드래그해서 이동)")
moveLabel:Hide()

local function Public(value)
	if IsSecret(value) then return nil end
	return value
end

local function Number(value)
	if IsSecret(value) or type(value) == "number" then return value end
	return 0
end

local function SafeMax(value)
	if IsSecret(value) then return value end
	if type(value) == "number" and value > 0 then return value end
	return 1
end

local function PowerType(key)
	return Enum and Enum.PowerType and Enum.PowerType[key]
end

local function CreateRow(key)
	local bar = CreateFrame("StatusBar", nil, frame)
	bar:SetStatusBarTexture(TEXTURE)
	bar:SetHeight(ROW_HEIGHT)
	local background = bar:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	background:SetColorTexture(0.08, 0.08, 0.08, 0.9)
	bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	bar.text:SetPoint("CENTER")
	bar.text:SetPoint("LEFT", 4, 0)
	bar.text:SetPoint("RIGHT", -4, 0)
	bar.text:SetJustifyH("CENTER")
	bar:Hide()
	rows[key] = bar
end

for _, key in ipairs({ "health", "power", "mana", "combo" }) do CreateRow(key) end

local function Fill(key, label, value, maximum, color, index)
	local bar = rows[key]
	bar:ClearAllPoints()
	bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -27 - index * (ROW_HEIGHT + ROW_GAP))
	bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -27 - index * (ROW_HEIGHT + ROW_GAP))
	bar:SetStatusBarColor(color[1], color[2], color[3])
	bar:SetMinMaxValues(0, SafeMax(maximum))
	bar:SetValue(Number(value))
	-- Native regions accept restricted resource numbers without Lua arithmetic.
	bar.text:SetFormattedText("%s %d / %d", label, Number(value), Number(maximum))
	bar:Show()
end

local function CurrentPower()
	local id, token
	if UnitPowerType then id, token = UnitPowerType("player") end
	id, token = Public(id), Public(token)
	if token == "MANA" then return id, "마나", colors.mana end
	if token == "RAGE" then return id, "분노", colors.rage end
	if token == "ENERGY" then return id, "기력", colors.energy end
	return id, "자원", colors.power
end

local function Update()
	if not db then return end
	if not isDruid or not db.enabled or (db.combatOnly and not inCombat and not moveMode) then
		frame:EnableMouse(false)
		moveLabel:Hide()
		frame:Hide()
		return
	end
	local form = ns.DruidForms and ns.DruidForms.GetCurrent and ns.DruidForms.GetCurrent()
	formText:SetText(form and form.name or "변신 정보 없음")
	formIcon:SetTexture(form and form.icon or ns.GetIcon(ICON))
	for _, row in pairs(rows) do row:Hide() end
	local count = 0
	if db.showHealth and UnitHealth and UnitHealthMax then
		Fill("health", "체력", UnitHealth("player"), UnitHealthMax("player"), colors.health, count)
		count = count + 1
	end
	if UnitPower and UnitPowerMax then
		local id, label, color = CurrentPower()
		if db.showPower then
			Fill("power", label, UnitPower("player", id), UnitPowerMax("player", id), color, count)
			count = count + 1
		end
		local mana = PowerType("Mana")
		if db.showMana and mana and form and (form.kind == "bear" or form.kind == "cat") and id ~= mana then
			Fill("mana", "변신 중 마나", UnitPower("player", mana), UnitPowerMax("player", mana), colors.mana, count)
			count = count + 1
		end
		local combo = PowerType("ComboPoints")
		if db.showCombo and combo and form and form.kind == "cat" then
			local maximum = UnitPowerMax("player", combo)
			if IsSecret(maximum) or (type(maximum) == "number" and maximum > 0) then
				local value
				if GetComboPoints then value = GetComboPoints("player", "target")
				else value = UnitPower("player", combo) end
				Fill("combo", "연계 점수", value, maximum, colors.combo, count)
				count = count + 1
			end
		end
	end
	frame:SetSize(db.width, 28 + count * (ROW_HEIGHT + ROW_GAP) + 3)
	frame:EnableMouse(moveMode)
	moveLabel:SetShown(moveMode)
	frame:Show()
end

local POINTS = {
	TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
	RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local function Validate()
	for _, key in ipairs({ "enabled", "showHealth", "showPower", "showMana", "showCombo", "combatOnly" }) do
		if type(db[key]) ~= "boolean" then db[key] = defaults[key] end
	end
	for _, key in ipairs({ "width", "scale", "x", "y" }) do
		local value = db[key]
		if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
			db[key] = defaults[key]
		end
	end
	db.width = math.max(160, math.min(400, db.width))
	db.scale = math.max(0.6, math.min(2, db.scale))
	if type(db.point) ~= "string" or not POINTS[db.point] then db.point = defaults.point end
	if type(db.relPoint) ~= "string" or not POINTS[db.relPoint] then db.relPoint = defaults.relPoint end
end

local function ApplyPosition()
	frame:SetScale(db.scale)
	frame:ClearAllPoints()
	frame:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
end

local function SetMoveMode(on)
	if on and (not db.enabled or not isDruid) then return end
	moveMode = on
	Update()
	ns:Fire("REFRESH_UI")
	if on then ns.Print("드루이드 자원 패널을 드래그해서 옮기고 [이동 완료]를 누르세요.") end
end

frame:SetScript("OnDragStart", function(self)
	if moveMode then self:StartMoving() end
end)

frame:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	if not moveMode or not db then return end
	local x, y = self:GetCenter()
	if x and y then
		db.point, db.relPoint, db.x, db.y = "CENTER", "BOTTOMLEFT", x, y
		ApplyPosition()
	end
end)

local function ResetPosition()
	db.point, db.relPoint, db.x, db.y = defaults.point, defaults.relPoint, defaults.x, defaults.y
	ApplyPosition()
end

function M:OnInitialize()
	db = self.db
	-- Keep the one-time migration marker outside defaults so old enabled settings remain detectable.
	if db.integratedManaVersion ~= 1 then
		db.enabled = false
		db.integratedManaVersion = 1
	end
	local _, class = UnitClass("player")
	isDruid = Public(class) == "DRUID"
	inCombat = InCombatLockdown() and true or false
	Validate()
	ApplyPosition()
	Update()
end

function M:ApplySettings()
	Validate()
	if not db.enabled then moveMode = false end
	ApplyPosition()
	Update()
end

for _, event in ipairs({ "UPDATE_SHAPESHIFT_FORM", "UPDATE_SHAPESHIFT_FORMS", "PLAYER_TARGET_CHANGED" }) do
	ns:RegisterEvent(event, Update)
end
for _, event in ipairs({ "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_FREQUENT", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER" }) do
	ns:RegisterUnitEvent(event, Update, "player")
end
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
	inCombat = InCombatLockdown() and true or false
	Update()
end)
ns:RegisterEvent("PLAYER_REGEN_DISABLED", function() inCombat = true Update() end)
ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() inCombat = false Update() end)

function M:BuildOptions(b)
	local function Disabled() return not db.enabled or not isDruid end
	b:Text("기본 자원 표시는 기존 내 상태 막대를 사용합니다. 별도 패널도 원하는 경우에만 켜세요(기본 꺼짐). 드루이드의 현재 변신·체력·자원을 화면에 고정 표시하며, 곰·표범 마나와 표범 연계 점수도 확인할 수 있습니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Check{ key = "showHealth", label = "내 체력", depends = "enabled" }
	b:Check{ key = "showPower", label = "현재 마나·기력·분노", depends = "enabled" }
	b:Check{ key = "showMana", label = "곰·표범 변신 중 남은 마나", depends = "enabled" }
	b:Check{ key = "showCombo", label = "표범 연계 점수", depends = "enabled" }
	b:Check{ key = "combatOnly", label = "전투 중에만", depends = "enabled" }
	b:Slider{ key = "width", label = "패널 너비", min = 160, max = 400, step = 10, format = "%d", depends = "enabled" }
	b:Slider{ key = "scale", label = "패널 크기", min = 0.6, max = 2, step = 0.05, format = "%.2f", depends = "enabled" }
	b:Buttons{
		{ text = "위치 이동", textFunc = function() return moveMode and "이동 완료" or "위치 이동" end,
			onClick = function() SetMoveMode(not moveMode) end, disabled = Disabled },
		{ text = "기본 위치로", onClick = ResetPosition, disabled = Disabled },
	}
	b:Text("드루이드 캐릭터에서만 표시합니다. 연계 점수는 현재 대상 기준이며, 변신을 바꾸면 해당 자원 줄로 전환합니다.", { color = { 0.7, 0.7, 0.7 } })
end
