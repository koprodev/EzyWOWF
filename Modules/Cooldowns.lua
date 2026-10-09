-- 쿨다운 표시: 내가 쓴 주문 중 재사용 대기시간(쿨다운)이 걸린 것만 고른 자리에 아이콘으로 띄우고, 끝나면 스르륵 지운다.
--
-- 포에버는 전투 중 쿨다운 시각·길이를 비밀값으로 준다(C_Spell.GetSpellCooldown: SecretWhenCooldownsRestricted).
-- 그래서 남은 시간은 직접 세지 않는다. 게임이 주는 길이 객체(GetSpellCooldownDuration, 전역 쿨다운 뺌)를
-- Cooldown 프레임에 그대로 넘기면 게임이 돌리고 숫자도 그린다. 끝은 그 프레임의 OnCooldownDone, 그리고 늘 읽히는 isActive로 안다.
-- 전역 쿨다운만 걸린 건지는 늘 읽히는 isOnGCD로 가린다. 효과가 끝나야 시작하는 쿨다운(isEnabled=false)은 시작할 때까지 기다린다.
-- 길이 범위는 쿨다운 전체 길이로 거른다: 숫자가 읽힐 때 잰 실제 길이 → 주문 기본 쿨다운 순. 끝내 모르면 거르지 않고 보여 준다.
-- 아이템(물약·장신구)과 펫 기술은 보지 않는다.

local _, ns = ...
local Clean = ns.Clean

local GCD_MAX = 1.5      -- 숫자가 읽힐 때 이보다 짧으면 전역 쿨다운으로 본다
local WAIT = 2           -- 시전 뒤 쿨다운이 걸리기를 기다리는 시간
local RECHECK = 0.25     -- 기다리는 시전·떠 있는 아이콘을 다시 보는 간격
local FADE_IN = 0.15
local GAP = 4
local SAMPLES = 3        -- 위치 이동 때 보여 줄 견본 아이콘 수
local ICON = "Interface\\Icons\\Spell_Nature_TimeStop"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

-- 평타·원거리 무기 사격은 공격 속도가 쿨다운처럼 잡혀서 뺀다
local IGNORE = {
	[6603] = true,                                -- 자동 공격
	[75] = true,                                  -- 자동 사격
	[2480] = true, [7918] = true, [7919] = true,  -- 활·총·석궁 사격
	[2764] = true, [3018] = true, [5019] = true,  -- 투척·사격·마법봉
}

local GROWS = {
	{ value = "center", text = "가운데에서 양옆으로" },
	{ value = "right", text = "오른쪽으로" },
	{ value = "left", text = "왼쪽으로" },
	{ value = "up", text = "위로" },
	{ value = "down", text = "아래로" },
}

local DRUID_PINS = {
	{ key = "pinnedInnervate", id = 29166, label = "정신 자극" },
	{ key = "pinnedRebirth", id = 20484, label = "환생" },
	{ key = "pinnedBarkskin", id = 22812, label = "나무 껍질" },
	{ key = "pinnedDash", id = 1850, label = "질주" },
}

local defaults = {
	enabled = true,
	pinnedInnervate = true,
	pinnedRebirth = true,
	pinnedBarkskin = true,
	pinnedDash = true,
	minSec = 2,          -- 쿨다운 전체 길이가 이 사이(초)인 것만
	maxSec = 3600,
	size = 36,
	grow = "center",
	numbers = true,
	fade = 0.8,          -- 사라지는 데 걸리는 초
	-- 캐릭터 발밑쯤. 버프 알림(가운데 위)과 안 겹치게 아래쪽
	point = "CENTER", relPoint = "CENTER", x = 0, y = -180,
}

local M = ns:NewModule("Cooldowns", {
	title = "쿨다운 표시",
	category = "info",
	icon = ICON,
	order = 32,
	defaults = defaults,
})

local db
local moveMode = false
local pending = {}      -- [주문] = { at = 시전 시각, hold = 효과가 끝나야 쿨다운 시작 }
local shown = {}        -- 화면 순서대로 { id =, icon =, fadeIn = 0~1, fading =, fadeT =, alpha0 = }
local byID = {}         -- [주문] = shown의 항목
local lengths = {}      -- [주문] = 숫자가 읽힐 때 잰 쿨다운 전체 길이. 특성으로 기본값과 다를 수 있다
local pool, samples = {}, {}
local recheckQueued = false
local feedFailed = false
local isDruid = false
local Layout, StartFade, QueueRecheck, UpdatePinned, RefreshPins

local function SpellName(id)
	return C_Spell and C_Spell.GetSpellName and Clean(C_Spell.GetSpellName(id))
end

local function SpellIcon(id)
	return C_Spell and C_Spell.GetSpellTexture and Clean(C_Spell.GetSpellTexture(id)) or QUESTION
end

local function CanRead()
	return C_Spell ~= nil and C_Spell.GetSpellCooldown ~= nil
end

-- 90 → "1분 30초"
local function Seconds(sec)
	sec = math.floor(sec + 0.5)
	if sec < 60 then return sec .. "초" end
	local m, s = math.floor(sec / 60), sec % 60
	if s == 0 then return m .. "분" end
	return ("%d분 %d초"):format(m, s)
end

local function IsListed(list, value)
	for _, o in ipairs(list) do
		if o.value == value then return true end
	end
	return false
end

-- 가져온 설정·옛 저장값이 이상하면 기본값으로
local function Validate()
	for _, key in ipairs({ "minSec", "maxSec", "size", "fade" }) do
		if type(db[key]) ~= "number" then db[key] = defaults[key] end
	end
	if not IsListed(GROWS, db.grow) then db.grow = defaults.grow end
	for _, pin in ipairs(DRUID_PINS) do
		if type(db[pin.key]) ~= "boolean" then db[pin.key] = defaults[pin.key] end
	end
end

---------------------------------------------------------------------------
-- 쿨다운 읽기
---------------------------------------------------------------------------
-- 쿨다운 전체 길이(초). 읽힐 때 잰 값 → 주문 기본 쿨다운. 모르면 nil
local function SpellLength(id)
	if lengths[id] then return lengths[id] end
	if GetSpellBaseCooldown then
		local ok, ms = pcall(GetSpellBaseCooldown, id)
		ms = ok and Clean(ms) or nil
		if type(ms) == "number" and ms > 0 then return ms / 1000 end
	end
end

local function Range()
	local lo, hi = db.minSec, db.maxSec
	if lo > hi then lo, hi = hi, lo end
	return lo, hi
end

local function InRange(id)
	local length = SpellLength(id)
	if not length then return true end
	local lo, hi = Range()
	return length >= lo - 0.05 and length <= hi + 0.05
end

-- 쿨다운이 도는 중인지. isActive가 없는 게임이면 읽히는 길이로, 그것도 비밀이면 nil
local function IsActive(info)
	local active = Clean(info.isActive)
	if active ~= nil then return active end
	local length = Clean(info.duration)
	if length then return length > 0 end
end

-- 시전한 주문의 지금 상태: "real" 진짜 쿨다운이 돎 / "hold" 효과가 끝나야 시작 / "wait" 아직 모름 / "gone" 없는 주문
local function Judge(id)
	local info = C_Spell.GetSpellCooldown(id)
	if type(info) ~= "table" then return "gone" end
	if Clean(info.isEnabled) == false then return "hold" end
	if IsActive(info) ~= true then return "wait" end
	local length, onGCD = Clean(info.duration), Clean(info.isOnGCD)
	local real
	if onGCD ~= nil then
		real = not onGCD
	elseif length then
		real = length > GCD_MAX
	else
		real = (SpellLength(id) or 0) > GCD_MAX
	end
	if not real then return "wait" end
	if length and length > GCD_MAX then lengths[id] = length end
	return "real"
end

---------------------------------------------------------------------------
-- 아이콘
---------------------------------------------------------------------------
local anchor = CreateFrame("Frame", "EzyWOWFCooldowns", UIParent)
anchor:SetFrameStrata("MEDIUM")
anchor:SetMovable(true)
anchor:SetClampedToScreen(true)
anchor:EnableMouse(false)
anchor:RegisterForDrag("LeftButton")
anchor:Hide()

local moveLabel = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
moveLabel:SetText("쿨다운 표시 위치 (드래그해서 이동)")
moveLabel:Hide()

local function OnDragStart()
	if moveMode then anchor:StartMoving() end
end

-- 가운데 점으로 다시 붙인다. 아이콘 크기를 바꿔도 제자리에서 자라게
local function OnDragStop()
	anchor:StopMovingOrSizing()
	local x, y = anchor:GetCenter()
	if x and y then
		anchor:ClearAllPoints()
		anchor:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
		db.point, db.relPoint, db.x, db.y = "CENTER", "BOTTOMLEFT", x, y
	end
end
anchor:SetScript("OnDragStart", OnDragStart)
anchor:SetScript("OnDragStop", OnDragStop)

-- 게임이 끝났다고 알려 준 쿨다운. 반납한 아이콘(entry 없음)이 Clear로 받는 알림은 무시한다
local function OnCooldownDone(cd)
	local e = cd.owner and cd.owner.entry
	if e and e.pinned then
		if not e.updating then UpdatePinned(e, false, true) end
		return
	end
	if e and not e.fading then StartFade(e) end
end

local function NewIcon()
	local f = CreateFrame("Frame", nil, anchor)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", OnDragStart)
	f:SetScript("OnDragStop", OnDragStop)
	local edge = f:CreateTexture(nil, "BACKGROUND")
	edge:SetPoint("TOPLEFT", -1, 1)
	edge:SetPoint("BOTTOMRIGHT", 1, -1)
	edge:SetColorTexture(0, 0, 0, 0.85)
	f.tex = f:CreateTexture(nil, "ARTWORK")
	f.tex:SetAllPoints()
	f.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- 아이콘 그림 가장자리의 테두리는 잘라 낸다
	f.tint = f:CreateTexture(nil, "OVERLAY")
	f.tint:SetAllPoints()
	f.tint:SetColorTexture(0, 1, 0, 0.25)
	f.tint:Hide()
	local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
	cd:SetAllPoints()
	cd:SetDrawEdge(false)
	cd:SetDrawBling(false)   -- 끝날 때 반짝이는 대신 스르륵 사라진다
	cd:SetScript("OnCooldownDone", OnCooldownDone)
	cd.owner = f
	f.cd = cd
	f.readyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.readyLabel:SetPoint("BOTTOM", f, "BOTTOM", 0, 2)
	f.readyLabel:Hide()
	f:SetScript("OnEnter", function(self)
		local e = self.entry
		if not (e and e.pinned) or moveMode then return end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetSpellByID(e.id)
		GameTooltip:AddLine(e.hint or "상태 확인 중", 1, 0.82, 0, true)
		GameTooltip:AddLine("대상·거리·재료·전역 재사용 대기시간은 직접 확인하세요.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	f:SetScript("OnLeave", function(self)
		if self.entry and self.entry.pinned then GameTooltip:Hide() end
	end)
	return f
end

local function Style(f)
	f:SetSize(db.size, db.size)
	f.cd:SetHideCountdownNumbers(not db.numbers)
	local fs = f.cd.GetCountdownFontString and f.cd:GetCountdownFontString()
	local font = fs and fs.GetFont and fs:GetFont()
	if font then fs:SetFont(font, math.max(10, math.floor(db.size * 0.42)), "OUTLINE") end
end

-- 게임이 주는 길이 객체를 그대로 넘긴다. 전투 중 비밀값이 든 것도 받는다. 0이면 지워진다(끝 알림이 안 와도 CheckShown이 잡는다)
local function Feed(e)
	local cd = e.icon.cd
	local GetDuration = C_Spell.GetSpellCooldownDuration
	if GetDuration and cd.SetCooldownFromDurationObject then
		local duration = GetDuration(e.id, true)
		if duration then
			cd:SetCooldownFromDurationObject(duration)
			return
		end
	end
	-- 길이 객체가 없는 게임: 숫자가 읽힐 때만 그린다. 끝은 isActive로 안다
	local info = C_Spell.GetSpellCooldown(e.id)
	local start, length = info and Clean(info.startTime), info and Clean(info.duration)
	if start and length and length > 0 then cd:SetCooldown(start, length, Clean(info.modRate) or 1) end
end

-- 못 그려도 아이콘은 남기고(끝은 isActive로 안다) 오류는 한 번만 알린다
local function SafeFeed(e)
	local ok, err = pcall(Feed, e)
	if not ok and not feedFailed then
		feedFailed = true
		ns.ErrorHandler(err)
	end
end

local function ClearTimer(e)
	e.updating = true
	e.icon.cd:Clear()
	e.updating = nil
end

-- A readable cooldown flag or native completion is required before claiming readiness.
UpdatePinned = function(e, trustGCD, nativeDone)
	local info = CanRead() and C_Spell.GetSpellCooldown(e.id)
	local state = "unknown"
	if trustGCD then e.nativeReady = nil end
	if nativeDone then e.nativeReady = true end
	if type(info) == "table" then
		local active, length = IsActive(info), Clean(info.duration)
		local onGCD
		if trustGCD then
			onGCD = Clean(info.isOnGCD)
			e.onGCD = onGCD
		end
		if Clean(info.isEnabled) == false then
			state = "hold"
		elseif e.nativeReady or active == false then
			state = "ready"
		elseif active == true then
			if onGCD == true or (not trustGCD and e.onGCD == true) then
				state = "ready"
			elseif onGCD == false or (type(length) == "number" and length > GCD_MAX) then
				state = "cooldown"
			elseif type(length) == "number" then
				state = "ready"
			elseif e.state == "cooldown" then
				state = "cooldown"
			end
		end
		if active == false then e.onGCD = nil end
	end
	e.state = state
	local label, r, g, b = "확인", 0.65, 0.65, 0.65
	e.hint = "게임이 상태를 제공하지 않아 준비 여부를 확인할 수 없습니다."
	if state == "cooldown" then
		label, r, g, b = nil, 0.72, 0.72, 0.72
		e.hint = "재사용 대기시간이 진행 중입니다."
	elseif state == "hold" then
		label = "대기"
		e.hint = "효과가 끝나야 재사용 대기시간이 시작됩니다."
	elseif state == "ready" then
		local usable, power
		if C_Spell and C_Spell.IsSpellUsable then
			local ok, u, p = pcall(C_Spell.IsSpellUsable, e.id)
			if ok then usable, power = Clean(u), Clean(p) end
		end
		if usable == true then
			label, r, g, b = "준비", 1, 1, 1
			e.hint = "쿨다운이 없고 변신·자원 사용 조건을 만족합니다."
		elseif power == true then
			label, r, g, b = "자원", 1, 0.65, 0.25
			e.hint = "쿨다운은 없지만 자원이 부족합니다."
		elseif usable == false then
			label = "불가"
			e.hint = "쿨다운은 없지만 현재 변신 등 사용 조건을 만족하지 않습니다."
		else
			label = "쿨 없음"
			e.hint = "쿨다운은 없습니다. 변신·자원 사용 조건은 확인할 수 없습니다."
		end
	end
	e.icon.tex:SetVertexColor(r, g, b)
	e.icon.readyLabel:SetText(label or "")
	e.icon.readyLabel:SetShown(label ~= nil)
	if state == "cooldown" or state == "unknown" then
		e.updating = true
		if CanRead() then SafeFeed(e) end
		e.updating = nil
	else
		ClearTimer(e)
	end
end

local function Release(e)
	for i, x in ipairs(shown) do
		if x == e then table.remove(shown, i) break end
	end
	if byID[e.id] == e then byID[e.id] = nil end
	local f = e.icon
	if GameTooltip:IsOwned(f) then GameTooltip:Hide() end
	f.entry = nil
	f.cd:Clear()
	f.readyLabel:Hide()
	f.tex:SetVertexColor(1, 1, 1)
	f:Hide()
	pool[#pool + 1] = f
end

StartFade = function(e)
	e.fading, e.fadeT, e.alpha0 = true, 0, e.icon:GetAlpha()
end

local function Show(id, pinned)
	local e = byID[id]
	if not e and not pinned then
		local name = SpellName(id)
		if name then
			for _, x in ipairs(shown) do
				if x.pinned and SpellName(x.id) == name then e = x break end
			end
		end
	end
	if e then   -- 사라지던 중에 다시 걸렸으면 되살린다
		if e.fading then e.fading, e.fadeIn = false, e.icon:GetAlpha() end
		if pinned then
			e.pinned, e.fadeIn = true, 1
			e.icon:SetAlpha(1)
		end
		if CanRead() then SafeFeed(e) end
		return e
	end
	local f = table.remove(pool) or NewIcon()
	e = { id = id, icon = f, fadeIn = pinned and 1 or 0, pinned = pinned }
	f.entry = e
	f.tex:SetTexture(SpellIcon(id))
	Style(f)
	f:SetAlpha(pinned and 1 or 0)
	f:Show()
	shown[#shown + 1] = e
	byID[id] = e
	if CanRead() then SafeFeed(e) end
	Layout()
	return e
end

local function PinSpellID(baseID)
	local name = SpellName(baseID)
	local info = name and C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(name)
	local best = type(info) == "table" and Clean(info.spellID)
	if type(best) == "number" and ns.IsSpellKnown(best) then return best end
	return ns.KnownSpellRank(baseID)
end

RefreshPins = function(trustGCD)
	if not db then return end
	local wanted, order = {}, {}
	if db.enabled and isDruid then
		for _, pin in ipairs(DRUID_PINS) do
			local id = db[pin.key] and PinSpellID(pin.id)
			if id then wanted[id] = true order[#order + 1] = id end
		end
	end
	for i = #shown, 1, -1 do
		local e = shown[i]
		if e.pinned and not wanted[e.id] then
			local replaced, name = false, SpellName(e.id)
			for _, id in ipairs(order) do
				if name and SpellName(id) == name then replaced = true break end
			end
			e.pinned, e.state = nil, nil
			e.icon.readyLabel:Hide()
			e.icon.tex:SetVertexColor(1, 1, 1)
			if not replaced and CanRead() and Judge(e.id) == "real" and InRange(e.id) then
				e.fading, e.fadeIn = false, 1
			else
				Release(e)
			end
		end
	end
	for _, id in ipairs(order) do
		local e = byID[id]
		if not e or not e.pinned then e = Show(id, true) end
		UpdatePinned(e, trustGCD)
	end
	Layout()
end

local function ClearAll()
	wipe(pending)
	for i = #shown, 1, -1 do Release(shown[i]) end
	Layout()
end

Layout = function()
	local list = {}
	for _, e in ipairs(shown) do list[#list + 1] = e.icon end
	if moveMode then
		for _, f in ipairs(samples) do list[#list + 1] = f end
	end
	local size, n = db.size, #list
	local step = size + GAP
	anchor:SetSize(size, size)
	for i, f in ipairs(list) do
		local k = i - 1
		f:ClearAllPoints()
		if db.grow == "right" then
			f:SetPoint("LEFT", anchor, "LEFT", k * step, 0)
		elseif db.grow == "left" then
			f:SetPoint("RIGHT", anchor, "RIGHT", -k * step, 0)
		elseif db.grow == "up" then
			f:SetPoint("BOTTOM", anchor, "BOTTOM", 0, k * step)
		elseif db.grow == "down" then
			f:SetPoint("TOP", anchor, "TOP", 0, -k * step)
		else
			f:SetPoint("CENTER", anchor, "CENTER", (k - (n - 1) / 2) * step, 0)
		end
		f:EnableMouse(moveMode or (f.entry and f.entry.pinned) or false)
	end
	moveLabel:ClearAllPoints()
	if db.grow == "up" then
		moveLabel:SetPoint("TOP", anchor, "BOTTOM", 0, -6)
	else
		moveLabel:SetPoint("BOTTOM", anchor, "TOP", 0, 6)
	end
	anchor:SetShown(n > 0)
end

-- 떠 있는 아이콘 중 쿨다운이 끝난 것. 초기화(재설정)로 끝나 OnCooldownDone이 안 와도 여기서 잡는다
local function CheckShown()
	if not CanRead() then return end
	for _, e in ipairs(shown) do
		if e.pinned then
			UpdatePinned(e)
		elseif not e.fading then
			local info = C_Spell.GetSpellCooldown(e.id)
			if type(info) ~= "table" or (IsActive(info) == false and Clean(info.isEnabled) ~= false) then StartFade(e) end
		end
	end
end

local since = 0
anchor:SetScript("OnUpdate", function(_, elapsed)
	local done
	for _, e in ipairs(shown) do
		if e.fading then
			e.fadeT = e.fadeT + elapsed
			local t = db.fade > 0 and e.fadeT / db.fade or 1
			if t >= 1 then
				done = done or {}
				done[#done + 1] = e
			else
				e.icon:SetAlpha(e.alpha0 * (1 - t))
			end
		elseif e.fadeIn < 1 then
			e.fadeIn = math.min(1, e.fadeIn + elapsed / FADE_IN)
			e.icon:SetAlpha(e.fadeIn)
		end
	end
	if done then
		for _, e in ipairs(done) do Release(e) end
		Layout()
	end
	since = since + elapsed
	if since >= RECHECK then
		since = 0
		CheckShown()
	end
end)

---------------------------------------------------------------------------
-- 시전 → 쿨다운
---------------------------------------------------------------------------
-- 기다리는 시전을 판정한다. 아직 모르는 게 남으면 참
local function CheckPending()
	local now, again = GetTime(), false
	for id, p in pairs(pending) do
		local state = Judge(id)
		if state == "real" then
			pending[id] = nil
			if InRange(id) then Show(id) end
		elseif state == "hold" then
			p.hold = true
		elseif state == "gone" or now - p.at >= WAIT then
			pending[id] = nil   -- 전역 쿨다운만 걸렸거나, 기다리던 쿨다운이 시작 없이 풀림
		else
			again = true
		end
	end
	return again
end

local function Recheck()
	recheckQueued = false
	if CheckPending() then QueueRecheck() end
end

QueueRecheck = function()
	if recheckQueued then return end
	recheckQueued = true
	C_Timer.After(RECHECK, Recheck)
end

local function Enabled()
	return db ~= nil and db.enabled and CanRead()
end

ns:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, _, _, spellID)
	spellID = Clean(spellID)
	if not Enabled() or type(spellID) ~= "number" or IGNORE[spellID] then return end
	pending[spellID] = { at = GetTime() }
	if CheckPending() then QueueRecheck() end
end, "player")

-- 시전 뒤 쿨다운이 걸렸는지 판정하고, 떠 있는 아이콘에 바뀐 길이(줄어듦·초기화)를 다시 넘긴다
ns:RegisterEvent("SPELL_UPDATE_COOLDOWN", function()
	if not Enabled() then return end
	if next(pending) and CheckPending() then QueueRecheck() end
	RefreshPins(true)
	for _, e in ipairs(shown) do
		if not e.fading then SafeFeed(e) end
	end
end)

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
	wipe(pending)
	if not Enabled() then return end
	RefreshPins()
	for _, e in ipairs(shown) do
		if not e.fading then SafeFeed(e) end
	end
end)

ns:RegisterEvent("SPELLS_CHANGED", function() RefreshPins() end)
ns:RegisterEvent("UPDATE_SHAPESHIFT_FORM", function() RefreshPins() end)
ns:RegisterEvent("SPELL_UPDATE_USABLE", function() RefreshPins() end)

---------------------------------------------------------------------------
-- 위치 이동
---------------------------------------------------------------------------
local function ApplyPosition()
	anchor:ClearAllPoints()
	anchor:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
end

local function SetMoveMode(on)
	moveMode = on
	if on then
		for i = #samples + 1, SAMPLES do
			local f = NewIcon()
			f.tex:SetTexture(ICON)
			f.tint:Show()
			samples[i] = f
		end
		for _, f in ipairs(samples) do
			Style(f)
			f:SetAlpha(1)
			f:Show()
			f.cd:SetCooldown(GetTime(), 60)   -- 숫자·크기 미리 보기
		end
	else
		for _, f in ipairs(samples) do
			f.cd:Clear()
			f:Hide()
		end
	end
	anchor:EnableMouse(on)
	moveLabel:SetShown(on)
	Layout()
	ns:Fire("REFRESH_UI")
	if on then ns.Print("쿨다운 아이콘을 드래그해서 옮기세요. 다 옮기면 [이동 완료]를 누르세요.") end
end

local function ResetPosition()
	db.point, db.relPoint, db.x, db.y = defaults.point, defaults.relPoint, defaults.x, defaults.y
	ApplyPosition()
end

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	isDruid = select(2, UnitClass("player")) == "DRUID"
	Validate()
	ApplyPosition()
	RefreshPins()
end

function M:ApplySettings(changes)
	Validate()
	if changes.enabled == false then
		if moveMode then SetMoveMode(false) end
		ClearAll()
	end
	ApplyPosition()   -- 설정 가져오기로 위치가 바뀌었을 수도 있다
	for _, e in ipairs(shown) do Style(e.icon) end
	for _, f in ipairs(samples) do Style(f) end
	RefreshPins()
end

local function RangeText()
	local lo, hi = ns:GetSetting(M, "minSec"), ns:GetSetting(M, "maxSec")
	local swapped = lo > hi
	if swapped then lo, hi = hi, lo end
	return ("보일 쿨다운: 전체 길이 %s ~ %s%s"):format(Seconds(lo), Seconds(hi),
		swapped and " |cffff9933(최소가 최대보다 커서 둘을 바꿔 씁니다)|r" or "")
end

local function StatusText()
	if #shown == 0 then return "|cff808080지금 떠 있는 쿨다운이 없어요.|r" end
	local rows = {}
	for _, e in ipairs(shown) do
		local length = SpellLength(e.id)
		local suffix = e.pinned and (" : " .. (e.state == "cooldown" and "쿨다운 중" or e.icon.readyLabel:GetText()))
			or (length and (" (" .. Seconds(length) .. ")") or "")
		rows[#rows + 1] = ("|T%s:16:16:0:0|t %s%s"):format(tostring(SpellIcon(e.id)), SpellName(e.id) or ("주문 " .. e.id),
			suffix)
	end
	return table.concat(rows, "\n")
end

function M:BuildOptions(b)
	local function Disabled() return not db.enabled end

	b:Text("내가 쓴 주문 중 재사용 대기시간(쿨다운)이 걸린 것만 원하는 자리에 아이콘으로 보여 주고, 쿨다운이 끝나면 스르륵 사라집니다. 전투 중에도 됩니다. "
		.. "전역 재사용 대기시간만 걸리는 주문과 자동 사격·평타는 보이지 않습니다. 아이템(물약·장신구)과 펫 기술은 보지 않습니다.")
	b:Check{ key = "enabled", label = "사용" }

	b:Header("드루이드 고정 아이콘")
	b:Text("드루이드는 배운 기술을 쿨다운이 없을 때도 표시합니다. 밝은 [준비]는 쿨다운·변신·자원 조건을 뜻하며, 대상·거리·재료·전역 재사용 대기시간은 별도 확인하세요. "
		.. "[자원]은 자원 부족, [불가]는 현재 변신 등 사용 조건 제한입니다. 고정 아이콘은 아래 쿨다운 길이 필터를 적용하지 않습니다.")
	for _, pin in ipairs(DRUID_PINS) do
		b:Check{ key = pin.key, label = pin.label .. " 항상 표시 (드루이드)", depends = "enabled",
			tooltip = "배우지 않은 기술과 다른 직업에서는 표시하지 않습니다. 끄면 쿨다운 중에만 기존 방식으로 표시합니다." }
	end

	b:Header("쿨다운 길이")
	b:Text("쿨다운의 전체 길이로 거릅니다(남은 시간이 아님). 전투 중에는 게임이 길이를 감춰서 전투 밖에서 잰 길이나 주문의 기본 쿨다운으로 거르고, "
		.. "둘 다 모르면 일단 보여 줍니다.", { color = { 0.6, 0.6, 0.6 } })
	b:Slider{
		key = "minSec", label = "최소", min = 0, max = 120, step = 1, format = "%d초", depends = "enabled",
		tooltip = "쿨다운 전체 길이가 이보다 짧은 주문은 보이지 않습니다.",
	}
	b:Slider{
		key = "maxSec", label = "최대", min = 10, max = 3600, step = 10, format = "%d초", depends = "enabled",
		tooltip = "쿨다운 전체 길이가 이보다 긴 주문은 보이지 않습니다. 3600초 = 1시간.",
	}
	b:Text(RangeText, { font = "GameFontHighlight" })

	b:Header("모양")
	b:Slider{ key = "size", label = "아이콘 크기", min = 20, max = 64, step = 2, format = "%d", depends = "enabled" }
	b:Dropdown{ key = "grow", label = "늘어나는 방향", options = function() return GROWS end, depends = "enabled" }
	b:Check{
		key = "numbers", label = "남은 시간 숫자 표시", depends = "enabled",
		tooltip = "아이콘 위에 남은 시간을 게임의 쿨다운 숫자로 보여 줍니다.",
	}
	b:Slider{
		key = "fade", label = "사라지는 시간", min = 0.2, max = 2, step = 0.1, format = "%.1f초", depends = "enabled",
		tooltip = "쿨다운이 끝난 아이콘이 흐려지며 사라지는 데 걸리는 시간입니다.",
	}
	b:Buttons{
		{
			text = "위치 이동",
			textFunc = function() return moveMode and "이동 완료" or "위치 이동" end,
			onClick = function() SetMoveMode(not moveMode) end,
			disabled = Disabled,
			tooltip = "견본 아이콘 3개가 나옵니다. 끌어서 옮긴 뒤 [이동 완료]를 누르세요. 크기·방향·숫자도 견본으로 미리 볼 수 있습니다.",
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
		if sum < 0.5 then return end
		sum = 0
		status:Refresh()
	end)
end
