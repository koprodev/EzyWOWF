-- 펫 도우미 (사냥꾼): 펫 없음/죽음/불만 · 탄약 부족 화면 알림, 스마트 펫 매크로.
--
-- 행복도 표시는 포에버 펫 초상화에 이미 있어서(PetFrameHappiness) 따로 만들지 않고, 불만일 때 알림만 띄운다.
-- 스마트 펫 키는 매크로로 충분해서(소환 -> 부활 -> 치료) 게임에서 주문 이름을 가져와 매크로를 만들어 준다.
-- 먹이 키·화면 먹이 버튼은 펫 먹이(PetFeed.lua) 몫이고, 여기는 그쪽 먹이 부족 한 줄을 알림에 같이 띄운다.

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local FEED_BINDING = "CLICK EzyWOWFPetFeedButton:LeftButton"   -- 불만 알림에 먹이 키를 같이 알려 준다
local PET_MACRO    = "펫 관리"
local MACRO_ICON   = "INV_MISC_QUESTIONMARK"

-- 주문 번호 (이름은 게임에서 가져온다)
local CALL_PET, REVIVE_PET, MEND_PET, DISMISS_PET, FEED_PET = 883, 982, 136, 2641, 6991
local FALLBACK_NAMES = {
	[CALL_PET] = "야수 부르기", [REVIVE_PET] = "야수 되살리기", [MEND_PET] = "동물 치료",
	[DISMISS_PET] = "야수 소환 해제", [FEED_PET] = "먹이 주기",
}

local LOGIN_GRACE = 5         -- 접속·지역 이동 직후 펫이 다시 나타나기를 기다리는 시간

local M = ns:NewModule("HunterPet", {
	title = "펫 도우미",
	category = "hunter",
	icon = "Interface\\Icons\\Ability_Hunter_BeastTraining",
	order = 10,
	defaults = {
		enabled = true,
		alertDead = true,
		alertMissing = true,
		quietResting = true,
		alertUnhappy = true,
		alertAmmo = true,
		ammoThreshold = 200,
		sound = true,
		point = "CENTER", relPoint = "CENTER", x = 0, y = 160,
	},
})

local db
local isHunter = false
local moveMode = false
local petWasDead = false
local graceUntil = 0
local lastState = {}
local ticker              -- 알림 검사 타이머
local shownText, shownWidth, shownHeight   -- 지금 화면에 그려 둔 글자·크기

local function SpellName(id)
	local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
	return name or FALLBACK_NAMES[id]
end

local function SpellIcon(id)
	local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(id)
	return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function PlayAlert()
	if db.sound and SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
end

---------------------------------------------------------------------------
-- 상태
---------------------------------------------------------------------------
-- dead / missing / unhappy / ok. 죽은 펫이 사라진 뒤에도 되살릴 때까지 "dead"로 본다.
local function PetState()
	if UnitExists("pet") then
		if Clean(UnitIsDead("pet")) then
			petWasDead = true
			return "dead"
		end
		petWasDead = false
		local happiness = C_PetInfo and C_PetInfo.GetPetHappiness and Clean(C_PetInfo.GetPetHappiness())
		return happiness == 1 and "unhappy" or "ok"
	end
	return petWasDead and "dead" or "missing"
end

local AMMO_SLOT
do
	local ok, slot = pcall(GetInventorySlotInfo, "AmmoSlot")
	if ok then AMMO_SLOT = slot end
end

-- 탄약이 필요 없으면(마법봉 등) nil
local function AmmoCount()
	if not (AMMO_SLOT and C_PaperDollInfo and C_PaperDollInfo.AmmoNeeded and C_PaperDollInfo.AmmoNeeded()) then
		return nil
	end
	if not GetInventoryItemID("player", AMMO_SLOT) then return 0 end
	return GetInventoryItemCount("player", AMMO_SLOT) or 0
end

local function Suppressed()
	return UnitIsDeadOrGhost("player") or UnitOnTaxi("player") or (UnitInVehicle and UnitInVehicle("player"))
end

---------------------------------------------------------------------------
-- 알림 화면
---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "EzyWOWFPetAlert", UIParent)
frame:SetSize(360, 60)
frame:SetFrameStrata("HIGH")
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:EnableMouse(false)
frame:RegisterForDrag("LeftButton")
frame:Hide()

local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
text:SetPoint("CENTER")
text:SetJustifyH("CENTER")
text:SetSpacing(4)

local moveTint = frame:CreateTexture(nil, "BACKGROUND")
moveTint:SetAllPoints()
moveTint:SetColorTexture(0, 1, 0, 0.25)
moveTint:Hide()

-- 은은하게 깜빡인다.
local pulse = 0
frame:SetScript("OnUpdate", function(self, elapsed)
	if moveMode then self:SetAlpha(1) return end
	pulse = pulse + elapsed * 3
	self:SetAlpha(0.65 + 0.35 * math.abs(math.sin(pulse)))
end)

local function Line(spellID, color, message)
	return ("|T%s:22:22:0:0|t %s%s|r"):format(tostring(SpellIcon(spellID)), color, message)
end

local function FeedKeyHint()
	local key = GetBindingKey(FEED_BINDING)
	return key and (" (먹이 키: %s)"):format(GetBindingText(key)) or ""
end

-- 같은 글자면 다시 넣지 않는다. 글꼴 크기는 이벤트 없이도 바뀌니 크기는 매번 잰다.
local function Render(message, minWidth)
	if message ~= shownText then
		text:SetText(message)
		shownText = message
	end
	local width = text:GetStringWidth() + 24
	if minWidth then width = math.max(width, minWidth) end
	local height = text:GetStringHeight() + 16
	if width ~= shownWidth or height ~= shownHeight then
		frame:SetSize(width, height)
		shownWidth, shownHeight = width, height
	end
	frame:Show()
end

-- 숨길 때 기억도 비워서 다시 뜰 때는 처음부터 그린다.
local function HideAlert()
	frame:Hide()
	shownText, shownWidth, shownHeight = nil, nil, nil
end

local function Update()
	if not db then return end
	if moveMode then
		Render(Line(REVIVE_PET, "|cffff4040", "펫 알림 위치 (드래그해서 이동)"))
		return
	end
	if not (db.enabled and isHunter) or Suppressed() then
		HideAlert()
		return
	end

	local lines = {}
	local state = PetState()
	local hasPetSpell = ns.IsSpellKnown(CALL_PET)
	local inGrace = GetTime() < graceUntil

	if state == "dead" and db.alertDead then
		lines[#lines + 1] = Line(REVIVE_PET, "|cffff4040", "펫이 죽었어요 - 되살려 주세요")
	elseif state == "missing" and db.alertMissing and hasPetSpell and not inGrace
		and not (db.quietResting and IsResting()) then
		lines[#lines + 1] = Line(CALL_PET, "|cffffd100", "펫이 없어요")
	elseif state == "unhappy" and db.alertUnhappy then
		lines[#lines + 1] = Line(FEED_PET, "|cffff9933", "펫이 불만스러워요 - 먹이를 주세요" .. FeedKeyHint())
	end

	local ammo = db.alertAmmo and AmmoCount()
	local ammoLow = ammo and ammo < db.ammoThreshold
	if ammoLow then
		local message = ammo == 0 and "탄약이 없어요" or ("탄약이 %d개 남았어요"):format(ammo)
		lines[#lines + 1] = ("|TInterface\\Icons\\INV_Ammo_Arrow_02:22:22:0:0|t |cffff9933%s|r"):format(message)
	end

	local foodLine = ns.PetFeedAlertLine and ns.PetFeedAlertLine()
	if foodLine then lines[#lines + 1] = Line(FEED_PET, "|cffff9933", foodLine) end

	-- 상태가 새로 나빠질 때만 소리를 낸다.
	if (state == "dead" and lastState.pet ~= "dead") or (ammoLow and not lastState.ammoLow) then
		if #lines > 0 then PlayAlert() end
	end
	lastState.pet, lastState.ammoLow = state, ammoLow

	if #lines == 0 then
		HideAlert()
		return
	end
	Render(table.concat(lines, "\n"), 120)
end

-- 켜진 사냥꾼이거나 위치 이동 중일 때만 돈다. enabled는 ApplySettings를 거쳐 바뀌어야 여기에 반영된다.
local function SyncTicker()
	local want = db ~= nil and ((db.enabled and isHunter) or moveMode)
	if want and not ticker then
		ticker = C_Timer.NewTicker(0.5, Update)
	elseif not want and ticker then
		ticker:Cancel()
		ticker = nil
	end
end

local function ApplyPosition()
	frame:ClearAllPoints()
	frame:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
end

frame:SetScript("OnDragStart", function(self)
	if moveMode then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, relPoint, x, y = self:GetPoint(1)
	db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end)

local function SetMoveMode(on)
	moveMode = on
	frame:EnableMouse(on)
	moveTint:SetShown(on)
	SyncTicker()
	Update()
	ns:Fire("REFRESH_UI")
	if on then Print("펫 알림을 드래그해서 옮기세요. 다 옮기면 [이동 완료]를 누르세요.") end
end

local function ResetPosition()
	local d = M.defaults
	db.point, db.relPoint, db.x, db.y = d.point, d.relPoint, d.x, d.y
	ApplyPosition()
end

---------------------------------------------------------------------------
-- 매크로 만들기
---------------------------------------------------------------------------
local function PetMacroBody()
	return ("#showtooltip\n/cast [@pet,dead][nopet,mod:ctrl] %s; [nopet] %s; [mod:shift] %s; %s"):format(
		SpellName(REVIVE_PET), SpellName(CALL_PET), SpellName(DISMISS_PET), SpellName(MEND_PET))
end

-- 캐릭터 전용 매크로를 만들거나 같은 이름이면 고친다. 펫 먹이 모듈도 쓴다.
function ns.MakeCharacterMacro(name, body)
	if InCombatLockdown() then
		Print("전투 중에는 매크로를 만들 수 없어요.")
		return
	end
	if not CreateMacro then
		Print("이 게임 버전에서는 애드온이 매크로를 만들 수 없어요.")
		return
	end
	local index = GetMacroIndexByName and GetMacroIndexByName(name) or 0
	local ok, err
	if index and index > 0 then
		ok, err = pcall(EditMacro, index, name, MACRO_ICON, body)
	else
		ok, err = pcall(CreateMacro, name, MACRO_ICON, body, true)
	end
	if ok then
		Print(("매크로 '%s'를 %s. 매크로 창(/macro)의 캐릭터 전용 탭에서 행동 단축바로 끌어다 놓으세요.")
			:format(name, (index and index > 0) and "고쳤어요" or "만들었어요"))
	else
		Print("매크로를 만들지 못했어요. 캐릭터 전용 매크로 칸이 꽉 찼는지 확인하세요. " .. tostring(err or ""))
	end
end

---------------------------------------------------------------------------
-- 이벤트
---------------------------------------------------------------------------
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
	graceUntil = GetTime() + LOGIN_GRACE
end)

local function OnPetUnitEvent(_, unit)
	if unit == "player" or unit == "pet" then Update() end
end

-- 레벨·펫 변화는 player·pet 것만 받는다. UNIT_HAPPINESS는 유닛 필터 선례가 없고 원래 펫에만 와서 그냥 받는다.
ns:RegisterUnitEvent("UNIT_PET", OnPetUnitEvent, "player", "pet")
ns:RegisterUnitEvent("UNIT_LEVEL", OnPetUnitEvent, "player", "pet")
ns:RegisterEvent("UNIT_HAPPINESS", OnPetUnitEvent)

-- 펫 없이(또는 죽은 채로) 전투에 들어가면 소리로 한 번 더 알린다.
ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
	if not (db and db.enabled and isHunter) or not ns.IsSpellKnown(CALL_PET) then return end
	local state = PetState()
	if (state == "dead" and db.alertDead) or (state == "missing" and db.alertMissing) then PlayAlert() end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	ApplyPosition()
end

function M:OnLogin()
	isHunter = select(2, UnitClass("player")) == "HUNTER"
	SyncTicker()
end

function M:ApplySettings(changes)
	if changes.enabled == false and moveMode then SetMoveMode(false) end
	SyncTicker()
	Update()
end

function M:BuildOptions(b)
	local function Disabled() return not db.enabled end

	b:Text("펫이 죽었거나 없을 때, 불만스러울 때, 탄약이 떨어져 갈 때 화면에 알려 줍니다. "
		.. "행복도는 펫 초상화 옆의 기본 표시를 보세요.")
	b:Check{ key = "enabled", label = "사용" }
	b:Check{ key = "alertDead", label = "펫이 죽으면 알림", depends = "enabled", indent = 20 }
	b:Check{ key = "alertMissing", label = "펫이 없으면 알림", depends = "enabled", indent = 20 }
	b:Check{
		key = "quietResting", label = "도시·여관에서는 펫 없음 알림 끄기", depends = { "enabled", "alertMissing" }, indent = 40,
	}
	b:Check{ key = "alertUnhappy", label = "펫이 불만스러우면 알림", depends = "enabled", indent = 20 }
	b:Check{ key = "alertAmmo", label = "탄약이 적으면 알림", depends = "enabled", indent = 20 }
	b:Slider{
		key = "ammoThreshold", label = "탄약 경고 기준", min = 50, max = 1000, step = 50, format = "%d개",
		depends = { "enabled", "alertAmmo" },
	}
	b:Check{
		key = "sound", label = "소리로도 알림", depends = "enabled", indent = 20,
		tooltip = "펫이 죽었을 때, 탄약이 기준 아래로 떨어졌을 때, 펫 없이 전투에 들어갈 때 경고음을 냅니다.",
	}
	b:Buttons{
		{
			text = "위치 이동",
			textFunc = function() return moveMode and "이동 완료" or "위치 이동" end,
			onClick = function() SetMoveMode(not moveMode) end,
			disabled = Disabled,
		},
		{ text = "기본 위치로", onClick = ResetPosition, disabled = Disabled },
	}

	b:Header("스마트 펫 매크로")
	b:Text("한 키로 펫이 없으면 부르기, 죽었으면 되살리기, 살아 있으면 치료를 합니다. "
		.. "Shift: 소환 해제 / Ctrl: 죽은 펫이 사라져서 부르기가 안 될 때 되살리기.\n"
		.. "매크로는 게임에 저장되고 기본 단축키가 붙은 행동 단축바 칸에 두면 단축키 초기화 버그도 피할 수 있어요.")
	b:Buttons{
		{ text = "펫 매크로 만들기", width = 150, onClick = function() ns.MakeCharacterMacro(PET_MACRO, PetMacroBody()) end },
	}
	b:Text("먹이 키·화면 먹이 버튼·먹일 음식 등록은 " .. ns:SettingsPath("PetFeed") .. "에 있어요.", { color = { 0.6, 0.6, 0.6 } })
end
