-- 사거리 표시: 원거리 공격 사거리 밖에 있는 적의 이름표를 무채색이나 작게 바꾼다. 사거리 안으로 들어오면 원래대로.
--
-- 사거리는 C_Spell.IsSpellInRange(주문, 이름표 유닛)으로 0.2초마다 묻는다. 이름표용 사거리 이벤트는 없다(대상 전용뿐).
-- 주문 고르기: 마법으로 싸우는 직업은 기본 공격 주문(드루이드 천벌 등). 그 밖은 블리자드 포에버 게임패드 바
-- (HostileTargetingActionBar)와 같게 사냥꾼은 자동 사격, 나머지는 장착한 원거리 무기의 사격 주문. 쓸 게 없으면 쉰다.
-- false만 사거리 밖이다. nil(판정 불가)·비밀값이면 원래 모양 그대로 둔다(블리자드 규칙).
-- 무채색: 체력 막대 채운 부분 위에 회색 덮개 + 레벨 숫자 회색. 보호 함수를 안 써서 전투 중에도 된다.
-- 작게: 블리자드 유닛 프레임을 이름표 아래 가운데 기준으로 다시 붙여 줄이고, 우리 줄 묶음도 같은 배율로.
--   SetScale은 보호 함수라 유닛 프레임이 보호 상태면 전투 중엔 건드리지 않고 전투가 끝난 뒤 맞춘다.
-- 유닛 프레임은 이름표끼리 돌려 쓰는 물건이라 되돌릴 땐 우리가 적어 둔 프레임으로 한다(이름표가 떨어질 땐 plate.UnitFrame이 비었을 수 있다).
-- 블리자드 유닛 프레임 투명도는 블리자드가 늘 1로 되돌려서 쓰지 않는다.

local _, ns = ...
local Clean = ns.Clean

local M = ns:NewModule("PlateRange", {
	title = "사거리 표시",
	category = "info",
	icon = "Interface\\Icons\\Ability_Marksmanship",
	order = 37,
	defaults = {
		enabled = true,
		style = "color",      -- color = 무채색, size = 작게, both = 작게 + 무채색
		scale = 70,           -- 작게: 지금 크기에 대한 %
		closeIsFar = false,   -- 너무 가까워 못 쏘는 거리(약 8m 안)도 사거리 밖으로
	},
})

local Stack = ns.PlateStack

local AUTO_SHOT = 75
-- 마법으로 싸우는 직업의 기본 공격 주문(1등급 번호). 앞에서부터 배운 것을 쓴다. 주문이 없으면 마법봉 사격으로 넘어간다
local CLASS_SPELLS = {
	DRUID   = { 5176 },        -- 천벌 30m
	PRIEST  = { 585 },         -- 성스러운 일격 30m
	WARLOCK = { 686 },         -- 어둠의 화살 30m
	SHAMAN  = { 403 },         -- 번개 화살 30m
	MAGE    = { 133, 116 },    -- 화염구 35m, 서리 화살 30m
}
local WEAPON = Enum and Enum.ItemWeaponSubclass or {}
local SHOOT = {   -- 원거리 무기 종류 → 사격 주문 (블리자드 표 그대로)
	[WEAPON.Bows or 2] = 2480,
	[WEAPON.Guns or 3] = 7918,
	[WEAPON.Thrown or 16] = 2764,
	[WEAPON.Crossbow or 18] = 7919,
	[WEAPON.Wand or 19] = 5019,
}
local ITEM_WEAPON = Enum and Enum.ItemClass and Enum.ItemClass.Weapon or 2
local RANGED_SLOT = INVSLOT_RANGED or 18
local INTERVAL = 0.2
local CLOSE_INDEX = 3   -- CheckInteractDistance 3 = 결투 거리(약 8~10m). 원거리 공격 최소 거리(8m)를 덮는다
local COVER = { 0.45, 0.45, 0.45, 1 }
local LEVEL_GREY = { 0.6, 0.6, 0.6 }

local db
local spell             -- 지금 사거리를 묻는 주문. nil이면 쉰다
local units = {}        -- [이름표 유닛 토큰] = true
local plateOf = {}      -- [토큰] = 이름표 (떨어질 땐 API가 nil을 줄 수 있어서 적어 둔다)
local ufOf = {}         -- [이름표] = 마지막으로 칠한 유닛 프레임
local look = {}         -- [유닛 프레임] = { plate =, grey =, small =, anchored =, w =, h = } 우리가 바꿔 둔 모양
local covers = {}       -- [체력 바] = 회색 덮개
local shrunk = {}       -- [이름표] = 그 줄 묶음을 줄인 유닛 프레임
local blocked = {}      -- [유닛 프레임] = true 전투 중이라 크기를 못 되돌린 것. 전투가 끝나면 바로 되돌린다

---------------------------------------------------------------------------
-- 사거리
---------------------------------------------------------------------------
local KnownRank = ns.KnownSpellRank

-- 블리자드 HostileTargetingActionBar:RefreshShootButton과 같은 순서
local function WeaponSpell(class)
	local weapon = GetInventoryItemID("player", RANGED_SLOT)
	if not weapon then return nil end
	local id
	if class == "HUNTER" then
		id = AUTO_SHOT
	elseif C_Item and C_Item.GetItemInfoInstant then
		local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(weapon)
		id = classID == ITEM_WEAPON and SHOOT[subclassID] or nil
	end
	if id and ns.IsSpellKnown(id) then return id end
end

-- 바뀌었으면 true
local function PickSpell()
	local old = spell
	spell = nil
	if C_Spell and C_Spell.IsSpellInRange then
		local _, class = UnitClass("player")
		for _, id in ipairs(CLASS_SPELLS[class] or {}) do
			spell = KnownRank(id)
			if spell then break end
		end
		spell = spell or WeaponSpell(class)
	end
	return spell ~= old
end

-- 사거리 밖이면 true. 판정할 수 없으면(공격 못 하는 유닛, nil, 비밀값) 원래 모양으로 둔다.
local function IsFar(unit)
	if not Clean(UnitCanAttack("player", unit)) then return false end
	if Clean(C_Spell.IsSpellInRange(spell, unit)) ~= false then return false end
	-- 너무 가까워 못 쏘는 거리. 공격할 수 있는 유닛에만 물어야 전투 중에 막히지 않는다
	if not db.closeIsFar and CheckInteractDistance and Clean(CheckInteractDistance(unit, CLOSE_INDEX)) then return false end
	return true
end

---------------------------------------------------------------------------
-- 모양
---------------------------------------------------------------------------
local function HealthBar(uf)
	return uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar
end

local function SetGrey(uf, on)
	local hb = HealthBar(uf)
	if hb and hb.barTexture then
		local cover = covers[hb]
		if on and not cover then
			-- 채운 부분만 덮는다(얼마나 남았는지는 그대로 보이게). 이름표 모양의 누름 회색보다 위층
			cover = hb:CreateTexture(nil, "OVERLAY", nil, -8)
			cover:SetAllPoints(hb.barTexture)
			cover:SetColorTexture(COVER[1], COVER[2], COVER[3], COVER[4])
			covers[hb] = cover
		end
		if cover then cover:SetShown(on) end
	end
	local lv = uf.PlayerLevelDiffFrame
	local text = lv and lv.playerLevelDiffText
	if text and text.SetFixedColor then
		text:SetFixedColor(on)   -- 숫자에 박힌 난이도 색 코드를 무시하고 회색으로
		if on then text:SetTextColor(LEVEL_GREY[1], LEVEL_GREY[2], LEVEL_GREY[3]) end
	end
	if lv and lv.highLevelTexture then lv.highLevelTexture:SetDesaturated(on) end
	look[uf].grey = on
end

-- 보호 프레임이면 전투 중엔 못 바꾼다(막히면 pcall로도 못 잡는 오류). 그때는 그대로 두고 전투가 끝나면 다시 맞춘다.
local function CanResize(uf)
	return not InCombatLockdown() or Clean(uf:IsProtected()) == false
end

local function PlateSize()
	if not (C_NamePlate and C_NamePlate.GetNamePlateSize) then return nil end
	local w, h = C_NamePlate.GetNamePlateSize()
	if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then return w, h end
end

-- 줄 묶음 배율은 그 이름표를 줄인 프레임일 때만 되돌린다 (이름표도 돌려 쓰니 남의 것을 풀면 안 된다)
local function ReleaseStack(uf)
	for plate, owner in pairs(shrunk) do
		if owner == uf then
			Stack:SetPlateScale(plate, 1)
			shrunk[plate] = nil
		end
	end
end

-- 못 바꿨으면(전투 중 보호 프레임) false
local function SetSmall(uf, plate, on)
	if not CanResize(uf) then return false end
	local l = look[uf]
	if on then
		local s = math.max(tonumber(db.scale) or 70, 50) / 100
		-- 블리자드는 유닛 프레임을 이름표에 꽉 맞춰(SetAllPoints) 붙인다. 그대로 줄이면 폭은 안 줄어서 아래 가운데에 다시 붙인다
		local w, h = PlateSize()
		if w then
			uf:ClearAllPoints()
			uf:SetPoint("BOTTOM", plate, "BOTTOM")
			uf:SetSize(w, h)
			l.anchored, l.w, l.h = true, w, h
		end
		uf:SetScale(s)
		Stack:SetPlateScale(plate, s)
		shrunk[plate] = uf
	else
		uf:SetScale(1)
		-- 지금 붙어 있는 이름표 기준. 이미 블리자드에 돌려준 프레임은 다음에 쓸 때 블리자드가 다시 꽉 맞춰 붙인다
		local parent = uf:GetParent()
		if l.anchored and parent and parent.UnitFrame == uf then
			uf:ClearAllPoints()
			uf:SetAllPoints(parent)
		end
		l.anchored, l.w, l.h = nil, nil, nil
		ReleaseStack(uf)
	end
	l.small = on
	return true
end

local function Paint(uf, plate, far)
	local style = db.style
	local wantGrey = far and (style == "color" or style == "both")
	local wantSmall = far and (style == "size" or style == "both")
	local l = look[uf]
	if not l then
		if not (wantGrey or wantSmall) then return end
		l = { plate = plate, grey = false, small = false }
		look[uf] = l
	end
	if l.grey ~= wantGrey then SetGrey(uf, wantGrey) end
	if l.small ~= wantSmall then SetSmall(uf, plate, wantSmall) end
	if not (l.grey or l.small) then look[uf] = nil end
end

-- 그 유닛 프레임을 원래대로
local function Restore(uf)
	local l = look[uf]
	if not l then return end
	if l.plate and ufOf[l.plate] == uf then ufOf[l.plate] = nil end
	if l.grey then SetGrey(uf, false) end
	if l.small and not SetSmall(uf, l.plate, false) then
		-- 전투 중이라 크기를 못 되돌렸다. 이제 어느 이름표 것도 아니니, 다시 쓰이면 크기부터 되돌린 뒤 처음부터 칠한다
		l.plate = nil
		blocked[uf] = true
		return
	end
	blocked[uf] = nil
	look[uf] = nil
end

local function RestoreAll()
	for uf in pairs(look) do Restore(uf) end
end

---------------------------------------------------------------------------
-- 갱신
---------------------------------------------------------------------------
local function PlateFor(unit)
	local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
	if not plate or (plate.IsForbidden and plate:IsForbidden()) then return nil end
	return plate
end

local function Update(unit)
	local plate = PlateFor(unit)
	if not plate then return end
	plateOf[unit] = plate
	local uf = plate.UnitFrame
	local old = ufOf[plate]
	if old and old ~= uf then Restore(old) end   -- 이 이름표에 전에 칠한 프레임이 바뀌었다
	if not uf or (uf.IsForbidden and uf:IsForbidden()) then return end
	local l = look[uf]
	if l and l.plate ~= plate then
		Restore(uf)   -- 돌려 쓰는 프레임이 다른 이름표에서 넘어왔다
		if look[uf] then return end   -- 전투 중이라 아직 못 되돌렸다. 전투가 끝나면 다시
	end
	ufOf[plate] = uf
	Paint(uf, plate, IsFar(unit))
end

local driver = CreateFrame("Frame")
driver:Hide()
local since, dirty = 0, false
driver:SetScript("OnUpdate", function(_, elapsed)
	since = since + elapsed
	if not dirty and since < INTERVAL then return end
	dirty, since = false, 0
	for unit in pairs(units) do Update(unit) end
end)

-- 꺼져 있거나 쓸 주문이 없거나 이름표가 하나도 없으면 아예 안 돈다
local function UpdateDriver()
	driver:SetShown((db and db.enabled and spell ~= nil and next(units) ~= nil) and true or false)
end

local function Refresh()
	dirty = true
	UpdateDriver()
end

-- 추가 이벤트 순간에는 블리자드가 아직 유닛 프레임을 안 붙였을 수 있어서 다음 화면에서 칠한다
ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit)
	units[unit] = true
	plateOf[unit] = PlateFor(unit)
	Refresh()
end)

ns:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, unit)
	units[unit] = nil
	local plate = plateOf[unit] or PlateFor(unit)
	plateOf[unit] = nil
	local uf = plate and ufOf[plate]
	if uf then Restore(uf) end
	if plate then ufOf[plate] = nil end
	if plate and shrunk[plate] then   -- 이름표도 돌려 쓰니 줄 묶음은 꼭 원래 크기로 (우리 프레임이라 전투 중에도 된다)
		Stack:SetPlateScale(plate, 1)
		shrunk[plate] = nil
	end
	UpdateDriver()
end)

-- UI를 다시 불러오면 이미 떠 있는 이름표를 다시 모은다
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
	RestoreAll()
	wipe(units)
	wipe(plateOf)
	for i = 1, 40 do
		local unit = "nameplate" .. i
		if UnitExists(unit) then units[unit] = true end
	end
	PickSpell()
	Refresh()
end)

-- 무기를 바꾸거나 주문을 배우면 쓸 주문이 바뀔 수 있다
local function OnGearOrSpells()
	if not db then return end
	if PickSpell() then
		RestoreAll()
		ns:Fire("REFRESH_UI")   -- 설정 창의 기준 주문 글자
	end
	Refresh()
end
ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", OnGearOrSpells)
ns:RegisterEvent("SPELLS_CHANGED", OnGearOrSpells)

-- 적이 아군이 되는 등 공격 가능 여부가 바뀜 / 전투가 끝나 미뤄 둔 크기를 맞출 수 있음
ns:RegisterEvent("UNIT_FACTION", function(_, unit)
	if units[unit] then dirty = true end
end)
-- 게임 설정에서 이름표 크기·스타일을 바꾸면 블리자드는 이름표만 새 크기로 바꾼다. 줄여 둔 프레임도 새 크기로
local function ResyncSize()
	local w, h = PlateSize()
	if not w then return end
	for uf, l in pairs(look) do
		if l.small and l.anchored and l.plate and (l.w ~= w or l.h ~= h) and CanResize(uf) then
			uf:SetSize(w, h)
			l.w, l.h = w, h
		end
	end
end
if NamePlateDriverFrame and type(NamePlateDriverFrame.UpdateNamePlateSize) == "function" then
	hooksecurefunc(NamePlateDriverFrame, "UpdateNamePlateSize", ResyncSize)
end

ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
	for uf in pairs(blocked) do Restore(uf) end
	ResyncSize()
	if next(look) then dirty = true end
	UpdateDriver()
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
end

function M:OnLogin()
	PickSpell()
	UpdateDriver()
end

function M:ApplySettings()
	RestoreAll()   -- 모양·크기가 바뀌었을 수 있으니 지우고 새로 칠한다
	PickSpell()
	Refresh()
end

local STYLES = {
	{ value = "color", text = "무채색으로" },
	{ value = "size",  text = "작게" },
	{ value = "both",  text = "작게 + 무채색" },
}

local function SpellLabel()
	if not spell then return "지금은 쉬는 중: 사거리를 잴 주문이 없습니다(공격 주문·원거리 무기 없음)." end
	local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spell)
	local name = type(info) == "table" and Clean(info.name) or ("주문 " .. spell)
	local range = type(info) == "table" and tonumber(Clean(info.maxRange))
	return "기준 주문: " .. name .. ((range and range > 0) and (" (최대 %dm)"):format(range) or "")
end

function M:BuildOptions(b)
	b:Text("원거리 공격 사거리 밖에 있는 적의 이름표를 무채색이나 작게 바꿉니다. 사거리 안으로 들어오면 원래 색·크기로 돌아옵니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Dropdown{ key = "style", label = "사거리 밖 표시", width = 200, depends = "enabled",
		options = function() return STYLES end }
	b:Slider{ key = "scale", label = "사거리 밖 크기", min = 50, max = 90, step = 5, format = "%d%%", depends = "enabled",
		disabled = function() return ns:GetSetting(M, "style") == "color" end,
		tooltip = "지금 이름표 크기에 대한 비율입니다. 사거리 안에서는 지금 크기 그대로입니다." }
	b:Check{ key = "closeIsFar", label = "너무 가까워 못 쏘는 거리도 사거리 밖으로", depends = "enabled",
		tooltip = "자동 사격·투척 같은 원거리 공격은 약 8m 안에서 쓸 수 없습니다. 끄면 이 거리의 적은 원래 모양으로 둡니다(붙어서 싸우는 적이 회색으로 바뀌지 않게)." }
	b:Text(SpellLabel, { color = { 0.7, 0.7, 0.7 } })
	b:Text("- 드루이드·사제·흑마법사·주술사·마법사는 기본 공격 주문(천벌·성스러운 일격·어둠의 화살·번개 화살·화염구), "
		.. "사냥꾼은 자동 사격, 도적·전사는 장착한 원거리 무기(활·총·석궁·투척)의 사격 사거리로 판단합니다. 쓸 게 없으면 쉽니다.\n"
		.. "- 곰·표범처럼 변신해서 그 주문을 못 쓸 때 게임이 사거리를 알려 주지 않으면 원래 모양으로 둡니다.\n"
		.. "- 무채색: 체력 막대와 레벨 숫자를 회색으로 바꿉니다. 이름과 그 밑 어그로 상자·내 상태 막대는 색을 그대로 둡니다.\n"
		.. "- 작게: 이름표 아래 가운데를 기준으로 줄이고, 그 밑 어그로 상자·막대도 같이 줄입니다. 줄어든 만큼 누르기도 어려워집니다.\n"
		.. "- 이름표가 켜져 있어야 보입니다(기본 단축키 V).",
		{ color = { 0.7, 0.7, 0.7 } })
end
