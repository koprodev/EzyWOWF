-- 곰·표범일 때 기본 플레이어 프레임(초상화 오른쪽) 기력·분노 밑에 남은 마나를 3번째 막대로 붙인다.
-- 모양은 블리자드가 조화 드루이드·암흑 사제 마나에 쓰는 보조 자원 막대(AlternatePowerBar) 그대로.
-- 블리자드 변수·함수는 안 바꾼다(taint). 블리자드 영역에는 보호 함수가 아닌 SetAlpha·SetAtlas만 쓰고 자리는 안 옮긴다.

local _, ns = ...

local M = ns:NewModule("DruidManaBar", {
	title = "초상화 마나 막대", category = "druid", icon = "Interface\\Icons\\Ability_Druid_CatForm", order = 17,
	defaults = { enabled = true },
})

-- 값 출처: Blizzard_UnitFrame PlayerFrame.xml·AlternatePowerBarBase.xml·PlayerFrame_ToPlayerArt
local FRAME_ATLAS = "UI-HUD-UnitFrame-Player-PortraitOn-ClassResource"
local FLASH_ATLAS = { [true] = "UI-HUD-UnitFrame-Player-PortraitOn-ClassResource-InCombat", [false] = "UI-HUD-UnitFrame-Player-PortraitOn-InCombat" }
local MANA_MASK_ATLAS = { [true] = "Unit_BarMask", [false] = "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Mana-Mask" }
local BAR_ATLAS = "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Mana"
local BAR_MASK_ATLAS = "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Mana-Mask"
local BAR_X, BAR_Y, BAR_W, BAR_H = 85, -73, 124, 9

local IsSecret = issecretvalue or function() return false end
local PT = Enum and Enum.PowerType
local MANA = PT and PT.Mana
local SCALE = CurveConstants and CurveConstants.ScaleTo100

local db, isDruid
local parts            -- 블리자드 플레이어 프레임 조각. 하나라도 못 찾으면 nil이고 아무것도 안 그린다
local art, bar         -- 우리가 그리는 3단 테두리와 마나 막대
local applied = false  -- 블리자드 테두리·전투 빛·마나 마스크를 3단 모양으로 바꿔 둔 상태
local hovering = false

local function Method(object, name)
	if type(object) == "table" and type(object[name]) == "function" then return object end
end

local function FindParts()
	local frame = Method(PlayerFrame, "IsShown")
	local container = frame and Method(frame.PlayerFrameContainer, "CreateTexture")
	local main = frame and type(frame.PlayerFrameContent) == "table" and frame.PlayerFrameContent.PlayerFrameContentMain
	local manaBar = type(main) == "table" and type(main.ManaBarArea) == "table" and main.ManaBarArea.ManaBar
	local found = {
		frame = frame, container = container,
		frameTexture = container and Method(container.FrameTexture, "SetAlpha"),
		flash = container and Method(container.FrameFlash, "SetAtlas"),
		manaMask = type(manaBar) == "table" and Method(manaBar.ManaBarMask, "SetAtlas") or nil,
	}
	if found.container and found.frameTexture and found.flash and found.manaMask then return found end
end

---------------------------------------------------------------------------
-- 글자: 게임 설정의 상태 텍스트(statusText·statusTextDisplay)를 블리자드 막대와 똑같이 따른다
---------------------------------------------------------------------------
local function Abbreviate(value)
	if type(AbbreviateLargeNumbers) == "function" then return AbbreviateLargeNumbers(value) end
	return tostring(value)
end

local function SetNumeric(fs, value, maximum)
	if IsSecret(value) or IsSecret(maximum) then
		fs:SetFormattedText("%d / %d", value, maximum)   -- 비밀값은 글자 칸에 그대로 넘긴다
	else
		fs:SetFormattedText("%s / %s", Abbreviate(value or 0), Abbreviate(maximum or 0))
	end
end

local function SetPercent(fs, value, maximum)
	if not IsSecret(value) and not IsSecret(maximum) then
		if type(value) ~= "number" or type(maximum) ~= "number" or maximum <= 0 then return false end
		fs:SetFormattedText("%d%%", math.ceil(value / maximum * 100))   -- 블리자드 막대처럼 올림
		return true
	end
	local pct = UnitPowerPercent and SCALE and UnitPowerPercent("player", MANA, false, SCALE)
	if not IsSecret(pct) and pct == nil then return false end
	fs:SetFormattedText("%.0f%%", pct)
	return true
end

local function SetText(value, maximum)
	bar.text:Hide()
	bar.left:Hide()
	bar.right:Hide()
	if not (hovering or (GetCVar and GetCVar("statusText") == "1")) then return end
	local mode = GetCVar and GetCVar("statusTextDisplay")
	if mode == "BOTH" then
		if SetPercent(bar.left, value, maximum) then bar.left:Show() end
		if IsSecret(value) then bar.right:SetFormattedText("%d", value) else bar.right:SetText(Abbreviate(value or 0)) end
		bar.right:Show()
	elseif mode == "PERCENT" and SetPercent(bar.text, value, maximum) then
		bar.text:Show()
	else
		SetNumeric(bar.text, value, maximum)
		bar.text:Show()
	end
end

---------------------------------------------------------------------------
-- 표시
---------------------------------------------------------------------------
local function SafeMax(maximum)
	if IsSecret(maximum) then return maximum end
	if type(maximum) ~= "number" or maximum <= 0 then return 1 end
	return maximum
end

-- 마나가 지금 자원이 아닐 때(곰 분노·표범 기력)만 띄운다. 이동·바다표범·달빛야수는 원래 마나를 쓴다.
local function Want()
	if not (db and db.enabled and isDruid and MANA ~= nil) then return false end
	local frame = parts.frame
	if frame.state == "vehicle" or frame.activeAlternatePowerBar or UNIT_FRAME_SHOW_HEALTH_ONLY then return false end
	local powerType = UnitPowerType("player")
	if IsSecret(powerType) then powerType = nil end
	if powerType == nil then
		local form = ns.DruidForms and ns.DruidForms.GetCurrent()
		if not (form and (form.kind == "bear" or form.kind == "cat")) then return false end
	elseif powerType == MANA then
		return false
	end
	local maximum = UnitPowerMax("player", MANA)
	return IsSecret(maximum) or (type(maximum) == "number" and maximum > 0), maximum
end

local function SetBlizzardArt(threeRows)
	if applied == threeRows then return end
	parts.frameTexture:SetAlpha(threeRows and 0 or 1)
	parts.flash:SetAtlas(FLASH_ATLAS[threeRows], true)
	parts.manaMask:SetAtlas(MANA_MASK_ATLAS[threeRows], true)
	applied = threeRows
end

local function Update()
	if not parts then return end
	local show, maximum = Want()
	SetBlizzardArt(show)
	art:SetShown(show)
	if not show then
		bar:Hide()
		return
	end
	local value = UnitPower("player", MANA)
	bar:SetMinMaxValues(0, SafeMax(maximum))
	bar:SetValue(value)
	SetText(value, maximum)
	bar:Show()
end

-- 블리자드가 프레임을 새로 칠하면 전투 빛·마스크가 블리자드 값으로 돌아가 있다. 우리 몫만 다시 판단.
-- 탈것 모양일 때는 블리자드 것을 덮어쓰지 않게 테두리 투명도만 돌려놓는다.
local function OnBlizzardArt()
	if not parts then return end
	if applied then
		applied = false
		parts.frameTexture:SetAlpha(1)
	end
	Update()
end

local function Build()
	parts = FindParts()
	if not parts then return end
	-- 원래 테두리와 같은 층이라 초상화 위, 체력·자원 막대 밑에 깔린다
	art = parts.container:CreateTexture(nil, "BACKGROUND", nil, 2)
	art:SetAtlas(FRAME_ATLAS, true)
	art:SetTexelSnappingBias(0)   -- 1.5px 어긋난 자리라 픽셀 맞춤을 끄지 않으면 번진다
	art:SetSnapToPixelGrid(false)
	art:SetPoint("CENTER", parts.container, "CENTER", 0, -1.5)
	art:Hide()

	bar = CreateFrame("StatusBar", "EzyWOWFDruidManaBar", parts.container)
	bar:SetSize(BAR_W, BAR_H)
	bar:SetPoint("TOPLEFT", parts.frame, "TOPLEFT", BAR_X, BAR_Y)
	bar:SetStatusBarTexture(BAR_ATLAS)
	bar:GetStatusBarTexture():SetTexelSnappingBias(0)
	bar:GetStatusBarTexture():SetSnapToPixelGrid(false)
	local mask = bar:CreateMaskTexture()
	mask:SetAtlas(BAR_MASK_ATLAS, true)
	mask:SetPoint("TOPLEFT", bar, "TOPLEFT", -2, 3)
	bar:GetStatusBarTexture():AddMaskTexture(mask)
	bar.text = bar:CreateFontString(nil, "OVERLAY", "TextStatusBarText")
	bar.text:SetPoint("CENTER")
	bar.left = bar:CreateFontString(nil, "OVERLAY", "TextStatusBarText")
	bar.left:SetPoint("LEFT", 2, 0)
	bar.right = bar:CreateFontString(nil, "OVERLAY", "TextStatusBarText")
	bar.right:SetPoint("RIGHT", -2, 0)
	-- 클릭은 밑의 플레이어 프레임(나 대상 지정·메뉴)으로 흘려보내고, 올려 두기만 받는다
	bar:SetMouseClickEnabled(false)
	bar:SetMouseMotionEnabled(true)
	bar:SetScript("OnEnter", function() hovering = true Update() end)
	bar:SetScript("OnLeave", function() hovering = false Update() end)
	bar:Hide()

	if type(PlayerFrame_ToPlayerArt) == "function" then hooksecurefunc("PlayerFrame_ToPlayerArt", OnBlizzardArt) end
	if type(PlayerFrame_ToVehicleArt) == "function" then hooksecurefunc("PlayerFrame_ToVehicleArt", OnBlizzardArt) end
end

local function UpdateIfReady()
	if parts then Update() end
end

ns:RegisterEvent("PLAYER_ENTERING_WORLD", UpdateIfReady)
ns:RegisterEvent("UPDATE_SHAPESHIFT_FORM", UpdateIfReady)
ns:RegisterUnitEvent("UNIT_DISPLAYPOWER", UpdateIfReady, "player")
ns:RegisterUnitEvent("UNIT_MAXPOWER", UpdateIfReady, "player")
-- 표범 기력 틱이 쉴 새 없이 오니 마나 변화만 받는다
ns:RegisterUnitEvent("UNIT_POWER_FREQUENT", function(_, _, token)
	if not (bar and bar:IsShown()) then return end
	if not IsSecret(token) and token ~= "MANA" then return end
	Update()
end, "player")
ns:RegisterEvent("CVAR_UPDATE", function()
	if bar and bar:IsShown() then Update() end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	if type(db.enabled) ~= "boolean" then db.enabled = M.defaults.enabled end
	local _, class = UnitClass("player")
	isDruid = not IsSecret(class) and class == "DRUID"
	if isDruid then Build() end
	UpdateIfReady()
end

function M:ApplySettings()
	if type(db.enabled) ~= "boolean" then db.enabled = M.defaults.enabled end
	UpdateIfReady()
end

function M:BuildOptions(b)
	b:Text("곰·표범으로 변신하면 기본 플레이어 프레임(초상화 오른쪽)의 체력·분노/기력 아래에 남은 마나를 파란 막대로 붙입니다. "
		.. "블리자드가 보조 자원에 쓰는 3단 프레임 모양 그대로 그리고, 인간형·이동·바다표범·달빛야수처럼 마나를 쓰는 모습에서는 원래 프레임으로 돌아갑니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Text("- 드루이드 캐릭터에서만 표시합니다.\n"
		.. "- 막대 글자는 게임 설정의 상태 텍스트(숫자·백분율·둘 다)를 따르고, 꺼져 있으면 마우스를 올렸을 때 보입니다.\n"
		.. "- 대상 이름표 밑 곰 마나 줄(화면 정보 > 내 상태 막대)과는 따로 켜고 끕니다.",
		{ color = { 0.7, 0.7, 0.7 } })
end
