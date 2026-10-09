-- 버프 알림: 직업 자기 버프가 없거나 곧 끝나면 화면에 알린다. 사냥꾼 탄약 알림(펫 도우미)과 같은 모양.
--
-- 포에버는 전투·전장 경기 같은 제한 중에 버프 정보를 비밀값으로 준다(C_UnitAuras: SecretWhenUnitAuraRestricted).
-- 전투 중에는 알림을 통째로 숨기고, 전투 밖인데 버프만 감춰질 때는 버프 줄만 쉬고 무기 줄은 그대로 띄운다.
-- UNIT_AURA도 제한 중엔 내용이 비밀값이라 받지 않고, 1초마다 버프 목록을 한 번 훑는다.
-- 버프는 이름으로 찾는다. 등급마다 주문 번호가 달라서다. 남이 걸어 준 같은 버프·무리 버전도 있는 것으로 치지만,
-- 내가 켜는 오라·상은 내 것만 센다(남의 오라가 몸에 있어도 내 오라는 꺼져 있을 수 있다).
-- 무기 독·숫돌·주술사 무기 주문은 C_Item.GetWeaponEnchantInfo로 읽는다(비밀 제한 없음). 전체 길이를 안 주므로
-- 처음 보였을(다시 발랐을) 때 남은 시간을 그 강화의 길이로 치고, 그게 기준보다 길 때만 "곧 끝남"을 알린다.
-- "없음"까지 알리는 무기는 독 기술을 배운 도적, 무기 주문을 배운 주술사(주 무기)뿐이다. 낚싯대는 안 본다.

local _, ns = ...
local Clean = ns.Clean

-- 직업마다 알릴 버프. spells = 시전하는 주문(1등급, 하나라도 배웠으면 알림), also = 남이 걸어 줘도 되는 무리 버전.
-- 여러 주문 중 하나면 되는 묶음은 label(설정·알림 이름)과 missing(없을 때 글)을 직접 적는다.
-- selfOnly = 내가 건 것만 셈, off = 기본으로 꺼 둠.
local BUFFS = {
	MAGE = {
		{ key = "MAGE_INTELLECT", spells = { 1459 }, also = { 23028 } },                          -- 신비한 지능 / 신비한 총명함
		{ key = "MAGE_ARMOR", label = "갑옷 주문", spells = { 6117, 7302, 168 } },                 -- 마법사·얼음·냉기 갑옷
	},
	PRIEST = {
		{ key = "PRIEST_FORTITUDE", spells = { 1243 }, also = { 21562 } },
		{ key = "PRIEST_INNER_FIRE", spells = { 588 } },
		{ key = "PRIEST_SPIRIT", spells = { 14752 }, also = { 27681 } },                          -- 특성
		{ key = "PRIEST_SHADOW", spells = { 976 }, also = { 27683 }, off = true },
	},
	DRUID = {
		{ key = "DRUID_MARK", spells = { 1126 }, also = { 21849 } },
		{ key = "DRUID_THORNS", spells = { 467 } },
	},
	WARLOCK = {
		{ key = "WARLOCK_ARMOR", label = "악마 갑옷 주문", spells = { 706, 687 } },               -- 악마의 갑옷·피부
	},
	PALADIN = {
		{ key = "PALADIN_BLESSING", label = "축복", missing = "축복이 없어요",
			spells = { 19740, 19742, 20217, 1038, 19977, 20911 },                                  -- 힘·지혜·왕·구원·빛·성역
			also = { 25782, 25894, 25898, 25895, 25890, 25899 } },                                 -- 상급 축복
		{ key = "PALADIN_AURA", label = "오라", missing = "오라를 켜지 않았어요", selfOnly = true,
			spells = { 465, 7294, 19746, 19876, 19888, 19891, 20218 } },
		{ key = "PALADIN_FURY", spells = { 25780 }, off = true },                                  -- 정의의 격노 (방어 전담만)
	},
	SHAMAN = {
		{ key = "SHAMAN_SHIELD", spells = { 324 } },
	},
	HUNTER = {
		{ key = "HUNTER_ASPECT", label = "상", missing = "상을 켜지 않았어요", selfOnly = true,
			spells = { 13165, 13163, 5118, 13159, 20043, 13161 } },                                -- 매·원숭이·치타·치타 무리·야생·야수
		{ key = "HUNTER_TRUESHOT", spells = { 19506 } },                                           -- 특성
	},
}
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local POISONS = 2842                          -- 도적 독 기술
local IMBUES = { 8017, 8024, 8033, 8232 }     -- 주술사 무기 주문 4종 (포에버는 60분)
-- index = Enum.WeaponSlot(MainHand 0, OffHand 1)
local WEAPONS = {
	{ slot = INVSLOT_MAINHAND or 16, index = 0, name = "주 무기" },
	{ slot = INVSLOT_OFFHAND or 17, index = 1, name = "보조 무기" },
}
local PERMANENT = 1                           -- Enum.ItemEnchantType.Permanent (마부 같은 영구 강화는 안 본다)
local ITEM_WEAPON = Enum and Enum.ItemClass and Enum.ItemClass.Weapon or 2
local FISHING_POLE = Enum and Enum.ItemWeaponSubclass and Enum.ItemWeaponSubclass.Fishingpole or 20
local REAPPLY_JUMP = 2                        -- 남은 시간이 이만큼 늘면 다시 바른 것
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local INTERVAL = 1
local LOGIN_GRACE = 5                         -- 접속·지역 이동 직후 버프 목록이 차기를 기다리는 시간

-- 고를 수 있는 알림 소리(SOUNDKIT 이름). 공격대 경보와 헷갈리지 않게 기본은 초시계가 다 됐을 때 소리.
-- 줄 끝 주석은 블리자드가 같은 소리를 쓰는 곳(포에버 Mainline SoundKitConstants·각 UI 소스 기준).
-- 퀘스트 완료(8초 넘는 축하 음악)처럼 길거나 "잘됐다"는 뜻의 소리는 경고로 헷갈려서 넣지 않았다.
local SOUNDS = {
	{ key = "ALARM_CLOCK_WARNING_3", text = "초시계 끝 (기본)" },          -- 초시계 다 됨
	{ key = "ALARM_CLOCK_WARNING_2", text = "알람 시계" },                 -- 시계 알람 울림
	{ key = "ALARM_CLOCK_WARNING_1", text = "알람 예고" },                 -- 시계 알람 직전
	{ key = "UI_EVENT_SCHEDULER_CHIME", text = "일정 알림 종" },           -- 일정 알림
	{ key = "MAP_PING", text = "미니맵 핑" },                              -- 미니맵 핑
	{ key = "UI_BNET_TOAST", text = "배틀넷 알림" },                       -- 친구 접속 알림
	{ key = "READY_CHECK", text = "전투 준비 확인" },                      -- 전투 준비·역할 확인
	{ key = "RAID_WARNING", text = "공격대 경보 (예전 소리)" },            -- 공격대 경보
}
local DEFAULT_SOUND = SOUNDS[1].key

local defaults = {
	enabled = true,
	threshold = 2,        -- 분. 이보다 적게 남으면 "곧 끝남"
	quietResting = true,
	sound = true,
	alertSound = DEFAULT_SOUND,
	-- 펫 알림(가운데 +160) 아래, 줄이 늘면 아래로 자란다. 위쪽 오류 글·공격대 경고 자리는 피한다
	point = "TOP", relPoint = "CENTER", x = 0, y = 100,
}
for _, list in pairs(BUFFS) do
	for _, e in ipairs(list) do defaults["buff_" .. e.key] = not e.off end
end
for _, c in ipairs(CLASSES) do defaults["weapon_" .. c] = true end   -- 직업마다 무기 알림 뜻이 달라서 따로 켠다

local M = ns:NewModule("BuffReminder", {
	title = "버프 알림",
	category = "info",
	icon = "Interface\\Icons\\Spell_Holy_MagicalSentry",
	order = 31,
	defaults = defaults,
})

local db
local class, className
local resolved = {}         -- 이 직업 버프 중 게임에 있는 것: { e =, names = {[이름]=true}, known =, label =, icon = }
local poisonKnown, imbueKnown = false, false
local enchantSeen = {}      -- [무기 칸] = { id = 강화 번호, max = 처음 본 남은 초, last = 지난번 남은 초 }
local moveMode = false
local graceUntil = 0
local lastKeys = {}         -- 지난번에 띄운 알림. 새 알림이 생길 때만 소리를 낸다
local ticker
local shownText, shownWidth, shownHeight

local function SpellName(id)
	return C_Spell and C_Spell.GetSpellName and Clean(C_Spell.GetSpellName(id))
end

local function SpellIcon(id)
	return C_Spell and C_Spell.GetSpellTexture and Clean(C_Spell.GetSpellTexture(id)) or QUESTION
end

-- 받침이 있으면 withFinal(이·을), 없으면 withoutFinal(가·를). 한글이 아니면 "이(가)"
local function Josa(word, withFinal, withoutFinal)
	local b1, b2, b3 = word:byte(-3, -1)
	if b1 and b1 >= 0xEA and b1 <= 0xED then
		local code = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
		if code >= 0xAC00 and code <= 0xD7A3 then
			return (code - 0xAC00) % 28 ~= 0 and withFinal or withoutFinal
		end
	end
	return withFinal .. "(" .. withoutFinal .. ")"
end

-- 1분 넘게 남으면 올림한 분, 그 아래는 초
local function Left(sec)
	if sec >= 60 then return ("%d분"):format(math.ceil(sec / 60)) end
	return ("%d초"):format(math.max(0, math.floor(sec)))
end

-- 모르는 이름(옛 저장값·없어진 소리)이면 기본 소리, 그것도 없으면 공격대 경보
local function PlaySoundByKey(key)
	local id = SOUNDKIT and (SOUNDKIT[key] or SOUNDKIT[DEFAULT_SOUND] or SOUNDKIT.RAID_WARNING)
	if id then PlaySound(id) end
end

local function PlayAlert()
	if db.sound then PlaySoundByKey(db.alertSound) end
end

-- 이 게임에 있는 소리만 고르게 한다
local function SoundOptions()
	local list = {}
	for _, s in ipairs(SOUNDS) do
		if SOUNDKIT and SOUNDKIT[s.key] then list[#list + 1] = { value = s.key, text = s.text } end
	end
	return list
end

local function WeaponKey()
	return "weapon_" .. (class or "WARRIOR")
end

---------------------------------------------------------------------------
-- 상태 읽기
---------------------------------------------------------------------------
-- 주문 이름은 게임에서 가져오고, 게임에 없는 주문은 뺀다. 배웠는지는 주문 목록이 바뀔 때만 다시 본다.
local function Resolve()
	wipe(resolved)
	for _, e in ipairs(BUFFS[class] or {}) do
		local names, known = {}, nil
		for _, id in ipairs(e.spells) do
			local name = SpellName(id)
			if name then
				names[name] = true
				known = known or ns.KnownSpellRank(id)
			end
		end
		for _, id in ipairs(e.also or {}) do
			local name = SpellName(id)
			if name then names[name] = true end
		end
		local label = e.label or SpellName(e.spells[1])
		if label and next(names) then
			resolved[#resolved + 1] = { e = e, names = names, known = known, label = label, icon = SpellIcon(known or e.spells[1]) }
		end
	end
	poisonKnown = class == "ROGUE" and ns.KnownSpellRank(POISONS) ~= nil
	imbueKnown = false
	if class == "SHAMAN" then
		for _, id in ipairs(IMBUES) do
			if ns.KnownSpellRank(id) then imbueKnown = true break end
		end
	end
end

local function InCombat()
	return InCombatLockdown() or Clean(UnitAffectingCombat("player")) and true or false
end

-- 게임이 버프 정보를 감추는 중(전투 밖이어도 전장 경기 같은 제한)
local function AurasSecret()
	return C_Secrets and C_Secrets.ShouldAurasBeSecret and Clean(C_Secrets.ShouldAurasBeSecret()) and true or false
end

local function Keep(t, info)
	local old = t[info.name]
	if not old or info.left > old.left then t[info.name] = info end
end

-- 이름마다 가장 오래 남은 버프: any = 누가 걸었든, own = 내가 건 것. secret = 이름을 못 읽은 버프가 있었음.
-- 읽을 수 없는 때(감춤·API 없음)는 nil
local function ReadAuras(now)
	if AurasSecret() or not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return nil end
	local auras = { any = {}, own = {}, secret = false }
	for i = 1, 255 do
		local a = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
		if not a then break end
		local name = Clean(a.name)
		if name then
			local exp, dur = Clean(a.expirationTime) or 0, Clean(a.duration) or 0
			local info = { name = name, left = (exp > 0 and dur > 0) and (exp - now) or math.huge, dur = dur, icon = Clean(a.icon) }
			Keep(auras.any, info)
			-- 내가 건 것인지는 블리자드 AuraUtil처럼 sourceUnit으로 본다(isFromPlayerOrPlayerPet은 남의 것도 참)
			local src = Clean(a.sourceUnit)
			if src and Clean(UnitIsUnit("player", src)) then Keep(auras.own, info) end
		else
			auras.secret = true
		end
	end
	return auras
end

-- 묶음 중 가장 오래 남은 것
local function BestAura(r, auras, anyone)
	local t = (r.e.selfOnly and not anyone) and auras.own or auras.any
	local best
	for name in pairs(r.names) do
		local a = t[name]
		if a and (not best or a.left > best.left) then best = a end
	end
	return best
end

-- 임시 강화(독·숫돌·주술사 무기 주문)의 남은 초와 강화 번호. 없으면 nil, 남은 시간을 모르면 math.huge
local function EnchantLeft(index)
	local function Seconds(ms)
		ms = Clean(ms)
		return (type(ms) == "number" and ms > 0) and ms / 1000 or math.huge
	end
	if C_Item and C_Item.GetWeaponEnchantInfo then
		local ok, list = pcall(C_Item.GetWeaponEnchantInfo, index)
		if not (ok and type(list) == "table") then return nil end
		local left, id
		for _, en in pairs(list) do
			if type(en) == "table" and Clean(en.hasEnchant) and Clean(en.enchantType) ~= PERMANENT then
				local s = Seconds(en.timeLeft)
				if not left or s < left then left, id = s, Clean(en.enchantID) end
			end
		end
		return left, id
	end
	if GetWeaponEnchantInfo then
		local hasMain, mainMs, _, mainID, hasOff, offMs, _, offID = GetWeaponEnchantInfo()
		if index == 0 then
			if Clean(hasMain) then return Seconds(mainMs), Clean(mainID) end
		elseif Clean(hasOff) then
			return Seconds(offMs), Clean(offID)
		end
	end
end

-- 강화를 볼 무기의 아이템 번호. 빈 칸·낚싯대·보조 손의 방패나 보조 장비는 nil
local function WeaponItem(w)
	local id = GetInventoryItemID("player", w.slot)
	if not id then return nil end
	local classID, subclassID
	if C_Item and C_Item.GetItemInfoInstant then
		classID, subclassID = select(6, C_Item.GetItemInfoInstant(id))
	end
	if subclassID == FISHING_POLE then return nil end
	if w.index == 1 and classID ~= ITEM_WEAPON then return nil end
	return id
end

-- 강화가 처음 보였을 때(다른 강화로 바뀌었거나 다시 발랐을 때)의 남은 시간을 그 강화의 길이로 기억한다.
-- 같은 강화가 묻은 무기로 바꾼 건 같은 강화로 친다(길이를 잊으면 곧 끝남을 못 알린다).
local function TrackEnchant(w, left, id)
	if not left then
		enchantSeen[w.slot] = nil
		return nil
	end
	local rec = enchantSeen[w.slot]
	if not rec or rec.id ~= id or left > rec.last + REAPPLY_JUMP then
		rec = { id = id, max = left }
		enchantSeen[w.slot] = rec
	end
	rec.last = left
	return rec
end

-- 강화가 없을 때 "없음"까지 알릴 무기. 그 밖에는 붙어 있던 강화가 곧 끝날 때만 알린다.
local function WantsEnchant(w)
	if class == "ROGUE" then return poisonKnown end
	if class == "SHAMAN" then return imbueKnown and w.index == 0 end
	return false
end

local function EnchantWord()
	return (class == "ROGUE" and poisonKnown) and "독" or "강화"
end

-- 알림을 쉬는 까닭. 없으면 nil
local function PauseReason()
	if UnitIsDeadOrGhost("player") then return "죽은 동안" end
	if UnitOnTaxi("player") then return "비행 중" end
	if UnitInVehicle and UnitInVehicle("player") then return "탈것에 탄 동안" end
	if db.quietResting and IsResting() then return "도시·여관" end
end

---------------------------------------------------------------------------
-- 알림 화면
---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "EzyWOWFBuffAlert", UIParent)
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

local pulse = 0
frame:SetScript("OnUpdate", function(self, elapsed)
	if moveMode then self:SetAlpha(1) return end
	pulse = pulse + elapsed * 3
	self:SetAlpha(0.65 + 0.35 * math.abs(math.sin(pulse)))
end)

local function Line(icon, color, message)
	return ("|T%s:22:22:0:0|t %s%s|r"):format(tostring(icon or QUESTION), color, message)
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

local function HideAlert()
	frame:Hide()
	shownText, shownWidth, shownHeight = nil, nil, nil
end

local function Update()
	if not db then return end
	if moveMode then
		Render(Line(SpellIcon(1459), "|cffffd100", "버프 알림 위치 (드래그해서 이동)"))
		return
	end
	if not db.enabled or PauseReason() then
		lastKeys = {}
		HideAlert()
		return
	end
	-- 전투 중엔 숨기기만 한다. 전에 울린 알림은 기억해 둬서 전투 뒤에 같은 걸로 또 울리지 않는다.
	local now = GetTime()
	if now < graceUntil or InCombat() then
		HideAlert()
		return
	end

	local threshold = db.threshold * 60
	local lines, keys, fresh = {}, {}, false
	local function Add(key, icon, color, message)
		lines[#lines + 1] = Line(icon, color, message)
		keys[key] = true
		if not lastKeys[key] then fresh = true end
	end
	-- 판단을 못 한 버프는 띄우지 않고 지난 상태만 이어 간다(읽히게 되면 같은 알림으로 또 울리지 않게)
	local function Carry(key)
		if lastKeys[key] then keys[key] = true end
		if lastKeys[key .. ":soon"] then keys[key .. ":soon"] = true end
	end

	local auras
	for _, r in ipairs(resolved) do
		if r.known and db["buff_" .. r.e.key] then
			if auras == nil then auras = ReadAuras(now) or false end
			local best = auras and BestAura(r, auras)
			if not auras or (not best and auras.secret) then   -- 감춰진 버프가 그것일 수도 있다
				Carry(r.e.key)
			elseif not best then
				Add(r.e.key, r.icon, "|cffff4040", r.e.missing or (r.label .. Josa(r.label, "이", "가") .. " 없어요"))
			elseif best.left < threshold and best.dur > threshold then
				Add(r.e.key .. ":soon", best.icon or r.icon, "|cffff9933", ("%s %s 남았어요"):format(best.name, Left(best.left)))
			end
		end
	end

	if db[WeaponKey()] ~= false then
		local word = EnchantWord()
		for _, w in ipairs(WEAPONS) do
			local item = WeaponItem(w)
			local left, id
			if item then left, id = EnchantLeft(w.index) end
			local rec = TrackEnchant(w, left, id)
			local icon = item and GetInventoryItemTexture("player", w.slot)
			if rec then
				if left < threshold and rec.max > threshold then
					Add("weapon" .. w.slot .. ":soon", icon, "|cffff9933", ("%s %s %s 남았어요"):format(w.name, word, Left(left)))
				end
			elseif item and WantsEnchant(w) then
				Add("weapon" .. w.slot, icon, "|cffff4040", ("%s에 %s%s 없어요"):format(w.name, word, Josa(word, "이", "가")))
			end
		end
	end

	if fresh then PlayAlert() end
	lastKeys = keys
	if #lines == 0 then
		HideAlert()
		return
	end
	Render(table.concat(lines, "\n"), 120)
end

-- 켜져 있거나 위치 이동 중일 때만 돈다.
local function SyncTicker()
	local want = db ~= nil and (db.enabled or moveMode)
	if want and not ticker then
		ticker = C_Timer.NewTicker(INTERVAL, Update)
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
-- StopMovingOrSizing은 가까운 화면 점에 붙인다. 줄이 늘면 늘 아래로 자라게 놓은 자리의 위쪽 가운데로 다시 붙인다.
frame:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local left, top, width = self:GetLeft(), self:GetTop(), self:GetWidth()
	if left and top and width then
		self:ClearAllPoints()
		self:SetPoint("TOP", UIParent, "BOTTOMLEFT", left + width / 2, top)
	end
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
	if on then ns.Print("버프 알림을 드래그해서 옮기세요. 다 옮기면 [이동 완료]를 누르세요.") end
end

local function ResetPosition()
	db.point, db.relPoint, db.x, db.y = defaults.point, defaults.relPoint, defaults.x, defaults.y
	ApplyPosition()
end

---------------------------------------------------------------------------
-- 이벤트
---------------------------------------------------------------------------
local resolveQueued = false
-- 주문 목록 이벤트는 몰려서 오니 한 번으로 모은다.
local function RequestResolve()
	if resolveQueued or not class then return end
	resolveQueued = true
	C_Timer.After(0.5, function()
		resolveQueued = false
		Resolve()
		ns:Fire("REFRESH_UI")
	end)
end

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
	graceUntil = GetTime() + LOGIN_GRACE
	RequestResolve()
end)
ns:RegisterEvent("SPELLS_CHANGED", RequestResolve)
ns:RegisterEvent("PLAYER_REGEN_DISABLED", Update)
ns:RegisterEvent("PLAYER_REGEN_ENABLED", Update)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	ApplyPosition()
end

function M:OnLogin()
	className, class = UnitClass("player")
	graceUntil = GetTime() + LOGIN_GRACE
	Resolve()
	SyncTicker()
end

function M:ApplySettings(changes)
	if changes.enabled == false and moveMode then SetMoveMode(false) end
	ApplyPosition()   -- 설정 가져오기로 위치가 바뀌었을 수도 있다
	SyncTicker()
	Update()
end

local GREY, RED, GREEN, GOLD = "|cff808080", "|cffff4040", "|cff40ff40", "|cffffd100"

local function Present(left)
	return GREEN .. "있음|r" .. (left < math.huge and (" (" .. Left(left) .. ")") or "")
end

local function StatusText()
	if not class then return "" end
	local rows = {}
	local reason = db.enabled and (PauseReason() or (InCombat() and "전투 중")) or nil
	if reason then rows[#rows + 1] = ("%s지금은 알림을 쉬어요: %s|r"):format(GOLD, reason) end

	local now = GetTime()
	local auras = not InCombat() and ReadAuras(now) or nil
	for _, r in ipairs(resolved) do
		local state
		if not r.known then
			state = GREY .. "배우지 않음|r"
		elseif not db["buff_" .. r.e.key] then
			state = GREY .. "알리지 않음|r"
		elseif not auras then
			state = GREY .. "지금은 게임이 감춤|r"
		else
			local best = BestAura(r, auras)
			if best then
				state = Present(best.left)
			elseif r.e.selfOnly and BestAura(r, auras, true) then
				state = RED .. "내 것 없음|r (남의 것만 있음)"
			elseif auras.secret then
				state = GREY .. "못 읽음 (감춰진 버프가 있음)|r"
			else
				state = RED .. "없음|r"
			end
		end
		rows[#rows + 1] = ("|T%s:16:16:0:0|t %s:  %s"):format(tostring(r.icon), r.label, state)
	end

	local word = EnchantWord()
	for _, w in ipairs(WEAPONS) do
		local item = WeaponItem(w)
		if item then
			local left = EnchantLeft(w.index)
			local state
			if db[WeaponKey()] == false then
				state = GREY .. "알리지 않음|r"
			elseif left then
				state = Present(left)
			else
				state = WantsEnchant(w) and (RED .. "없음|r") or (GREY .. "없음 (곧 끝날 때만 알림)|r")
			end
			rows[#rows + 1] = ("|T%s:16:16:0:0|t %s %s:  %s"):format(
				tostring(GetInventoryItemTexture("player", w.slot) or QUESTION), w.name, word, state)
		end
	end
	if class == "ROGUE" then
		rows[#rows + 1] = "독 기술:  " .. (poisonKnown and (GREEN .. "찾음|r")
			or (GREY .. "못 찾음|r (독이 없을 때는 못 알리고, 곧 끝날 때만 알려요)"))
	end
	if #rows == 0 then return GREY .. "이 캐릭터는 알릴 버프가 없어요.|r" end
	return table.concat(rows, "\n")
end

local function WeaponLabel()
	if class == "ROGUE" then return "무기 독이 없거나 곧 끝나면 알림" end
	if class == "SHAMAN" then return "무기 강화 주문이 없거나 곧 끝나면 알림" end
	return "숫돌·오일 같은 무기 강화가 곧 끝나면 알림"
end

function M:BuildOptions(b)
	local function Disabled() return not db.enabled end

	b:Text("직업 버프가 없거나 곧 끝날 때 화면에 알려 줍니다(사냥꾼 탄약 알림처럼). "
		.. "전투 중에는 게임이 버프 정보를 감춰서 알림을 숨기고 전투가 끝나면 다시 확인합니다. "
		.. "전장 경기처럼 전투 밖에서도 버프를 감추는 곳에서는 무기 알림만 띄웁니다.")
	b:Check{ key = "enabled", label = "사용" }

	if #resolved > 0 then
		local items = {}
		for _, r in ipairs(resolved) do
			local names = {}
			for name in pairs(r.names) do names[#names + 1] = name end
			table.sort(names)
			local tip = #names > 1 and ("이 중 하나만 있으면 돼요: " .. table.concat(names, ", ")) or nil
			if r.e.selfOnly then tip = (tip and tip .. "\n" or "") .. "다른 사람이 켠 것은 세지 않아요." end
			items[#items + 1] = { key = "buff_" .. r.e.key, text = r.label, icon = r.icon, tooltip = tip }
		end
		b:CheckGrid{ label = ("알릴 버프 (%s)"):format(className or ""), items = items, columns = 2, depends = "enabled" }
	else
		b:Text("이 직업은 오래가는 자기 버프가 없어서 아래 무기 알림만 씁니다.", { color = { 0.6, 0.6, 0.6 } })
	end
	b:Check{
		key = WeaponKey(), label = WeaponLabel(), depends = "enabled",
		tooltip = (class == "ROGUE" and "독 기술을 배운 것으로 확인되면 무기에 독이 없을 때도 알려요. " or "")
			.. "이 직업 캐릭터에만 적용돼요. 낚싯대는 보지 않아요.",
	}
	b:Slider{
		key = "threshold", label = "곧 끝남 기준", min = 1, max = 10, step = 1, format = "%d분", depends = "enabled",
		tooltip = "남은 시간이 이보다 적으면 알려요. 전체 길이가 이 기준보다 짧은 버프·무기 강화는 '곧 끝남'을 알리지 않아요.",
	}
	b:Check{ key = "quietResting", label = "도시·여관에서는 알리지 않기", depends = "enabled" }
	b:Check{ key = "sound", label = "소리로도 알림", depends = "enabled", tooltip = "새 알림이 뜰 때 아래에서 고른 소리를 냅니다." }
	b:Dropdown{
		key = "alertSound", label = "알림 소리", options = SoundOptions, depends = { "enabled", "sound" },
		tooltip = "고르면 바로 한 번 들려줍니다. [저장]을 눌러야 알림 소리가 바뀝니다.",
		set = function(value)
			ns:SetSetting(M, "alertSound", value)
			PlaySoundByKey(value)
		end,
	}
	b:Buttons{
		{
			text = "소리 들어 보기", width = 130,
			onClick = function() PlaySoundByKey(ns:GetSetting(M, "alertSound")) end,
			depends = { "enabled", "sound" },
		},
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

	b:Header("지금 상태")
	local status = b:Text(StatusText, { font = "GameFontHighlight" })
	if b.searchOnly then return end
	-- 페이지가 보일 때만 돈다(숨은 프레임은 OnUpdate가 안 불린다).
	local live = CreateFrame("Frame", nil, b.page)
	local sum = 0
	live:SetScript("OnUpdate", function(_, elapsed)
		sum = sum + elapsed
		if sum < INTERVAL then return end
		sum = 0
		status:Refresh()
	end)
end
