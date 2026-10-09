local _, ns = ...
local Clean = ns.Clean
local IsSecret = issecretvalue or function() return false end
local PROC = 16870
local QUESTION = "Interface\\Icons\\Spell_Shadow_ManaBurn"
local M = ns:NewModule("DruidAlerts", {
	title = "정신집중 발동 알림", category = "druid", icon = QUESTION, order = 25,
	defaults = { enabled = true, sound = true, combatOnly = false, scale = 1,
		point = "CENTER", relPoint = "CENTER", x = 220, y = -100 },
})

local db, isDruid, moving, lastActive, overlayActive
local frame = CreateFrame("Frame", "EzyWOWFDruidAlert", UIParent, "BackdropTemplate")
frame:SetSize(244, 64)
frame:SetFrameStrata("HIGH")
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:RegisterForDrag("LeftButton")
frame:EnableMouse(false)
frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
frame:SetBackdropColor(0.03, 0.08, 0.04, 0.9)
frame:SetBackdropBorderColor(0.5, 1, 0.35, 1)
frame:Hide()

local icon = frame:CreateTexture(nil, "ARTWORK")
icon:SetPoint("LEFT", 8, 0)
icon:SetSize(48, 48)
local cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
cooldown:SetAllPoints(icon)
cooldown:SetDrawEdge(false)
cooldown:SetHideCountdownNumbers(false)
local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 64, -14)
title:SetText("정신집중 발동")
title:SetTextColor(0.6, 1, 0.4)
local detail = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
detail:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
detail:SetText("청명의 전조")

local function Position()
	frame:ClearAllPoints()
	frame:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
	frame:SetScale(db.scale)
end

local function Validate()
	if type(db.scale) ~= "number" or db.scale ~= db.scale then db.scale = 1 end
	db.scale = math.max(0.7, math.min(1.8, db.scale))
	local points = { CENTER = true, TOP = true, BOTTOM = true, LEFT = true, RIGHT = true,
		TOPLEFT = true, TOPRIGHT = true, BOTTOMLEFT = true, BOTTOMRIGHT = true }
	if not points[db.point] or not points[db.relPoint] then db.point, db.relPoint = "CENTER", "CENTER" end
	for _, key in ipairs({ "x", "y" }) do
		if type(db[key]) ~= "number" or db[key] ~= db[key] or math.abs(db[key]) == math.huge then db[key] = M.defaults[key] end
	end
end

local function AurasRestricted()
	return C_Secrets and C_Secrets.ShouldAurasBeSecret and Clean(C_Secrets.ShouldAurasBeSecret()) == true
end

local function ReadProc()
	local overlay = C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed
	local active = overlay and Clean(overlay(PROC))
	if not AurasRestricted() and C_UnitAuras then
		local aura, readable = nil, false
		if C_UnitAuras.GetPlayerAuraBySpellID then
			local ok, value = pcall(C_UnitAuras.GetPlayerAuraBySpellID, PROC)
			if ok and not IsSecret(value) then aura, readable = value, true end
		elseif C_UnitAuras.GetAuraDataByIndex then
			readable = true
			for index = 1, 255 do
				local ok, value = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, "HELPFUL")
				if not ok or IsSecret(value) then readable = false break end
				if not value then break end
				local id = Clean(value.spellId)
				if not id then readable = false end
				if id == PROC then aura = value break end
			end
		end
		if aura then return true, aura end
		if active == true or (active == nil and overlayActive == true) then return true end
		if readable then return false end
	end
	if active == true then return true end
	if active == false then return false end
	return overlayActive
end

local function Timer(aura)
	cooldown:Clear()
	if not aura then return end
	local instance = Clean(aura.auraInstanceID)
	if instance and C_UnitAuras.GetAuraDuration and cooldown.SetCooldownFromDurationObject then
		local ok, duration = pcall(C_UnitAuras.GetAuraDuration, "player", instance)
		if ok and duration then cooldown:SetCooldownFromDurationObject(duration) return end
	end
	local expires, duration = Clean(aura.expirationTime), Clean(aura.duration)
	if type(expires) == "number" and type(duration) == "number" and duration > 0 and expires > GetTime() then
		cooldown:SetCooldown(expires - duration, duration)
	end
end

local function Update()
	if not db then return end
	if not isDruid or not db.enabled then frame:Hide() lastActive = false return end
	if moving then
		title:SetText("알림 위치 이동") detail:SetText("드래그해서 이동")
		cooldown:Clear() frame:Show() return
	end
	local active, aura = ReadProc()
	if active == false then lastActive = false end
	local combat = InCombatLockdown() or Clean(UnitAffectingCombat("player")) == true
	if active ~= true or (db.combatOnly and not combat) or UnitIsDeadOrGhost("player") then
		frame:Hide() return
	end
	icon:SetTexture(aura and Clean(aura.icon) or (C_Spell and C_Spell.GetSpellTexture and Clean(C_Spell.GetSpellTexture(PROC))) or QUESTION)
	title:SetText("정신집중 발동") detail:SetText("청명의 전조")
	Timer(aura)
	frame:Show()
	if not lastActive and db.sound and SOUNDKIT and SOUNDKIT.MAP_PING then PlaySound(SOUNDKIT.MAP_PING) end
	lastActive = true
end

local function SetMoving(value)
	moving = value and isDruid and db.enabled or false
	frame:EnableMouse(moving)
	if not moving then frame:StopMovingOrSizing() end
	Update()
	ns:Fire("REFRESH_UI")
end

frame:SetScript("OnDragStart", function(self) if moving then self:StartMoving() end end)
frame:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	if not moving then return end
	local point, _, relPoint, x, y = self:GetPoint()
	db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end)

function M:OnLogin()
	db = self.db
	isDruid = select(2, UnitClass("player")) == "DRUID"
	Validate() Position() Update()
	if isDruid then C_Timer.NewTicker(0.2, Update) end
end

function M:ApplySettings()
	Validate() Position()
	if not db.enabled then SetMoving(false) else Update() end
end

ns:RegisterUnitEvent("UNIT_AURA", Update, "player")
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function() overlayActive = nil Update() end)
ns:RegisterEvent("PLAYER_REGEN_DISABLED", Update)
ns:RegisterEvent("PLAYER_REGEN_ENABLED", Update)
ns:RegisterEvent("SPELL_ACTIVATION_OVERLAY_SHOW", function(_, id)
	if Clean(id) == PROC then overlayActive = true Update() end
end)
ns:RegisterEvent("SPELL_ACTIVATION_OVERLAY_HIDE", function(_, id)
	if IsSecret(id) then return end
	if id == PROC or id == nil then overlayActive = false Update() end
end)

function M:BuildOptions(b)
	b:Text("청명의 전조가 정신집중을 발동하면 아이콘과 소리로 알립니다. 변신 중에도 표시합니다. 남은 시간은 게임의 버프 타이머를 사용합니다. "
		.. "게임이 버프를 감추는 동안에는 허용된 주문 발동 표시로 확인하며, 확인할 수 없으면 알림을 숨깁니다.")
	b:Check{ key = "enabled", label = "사용 (드루이드만)" }
	b:Check{ key = "sound", label = "발동할 때 소리", depends = "enabled" }
	b:Check{ key = "combatOnly", label = "전투 중에만 표시", depends = "enabled" }
	b:Slider{ key = "scale", label = "표시 크기", min = 0.7, max = 1.8, step = 0.1, format = "%.1f", depends = "enabled" }
	b:Buttons{
		{ text = "위치 이동", textFunc = function() return moving and "이동 완료" or "위치 이동" end,
			onClick = function() SetMoving(not moving) end, disabled = function() return not isDruid or not db.enabled end },
		{ text = "기본 위치로", onClick = function()
			for _, key in ipairs({ "point", "relPoint", "x", "y" }) do db[key] = M.defaults[key] end
			Position() Update()
		end, disabled = function() return not isDruid or not db.enabled end },
	}
end
