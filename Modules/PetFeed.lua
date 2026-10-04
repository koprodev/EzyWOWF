-- 펫 먹이 (사냥꾼): 등록한 음식을 순위대로 먹이는 단축키·화면 버튼, 먹이 부족 알림.
--
-- 음식은 1~3순위로 등록한다. 지금 펫이 못 먹거나 가방에 없는 순위는 건너뛰어서, 펫마다 식성이 달라도 목록 하나로 된다.
-- 등록한 음식이 다 떨어지면(또는 등록이 없으면) 알맞은 음식을 자동으로 고른다:
-- 행복도가 제대로 오르는 음식(펫 레벨 - 10 이상) 중 가장 낮은 것, 그런 게 없으면 가진 것 중 가장 높은 것.
-- 먹이기는 보안 버튼 매크로 "/cast 먹이 주기" + "/use 가방 칸"이고 버튼은 둘이다.
--   EzyWOWFPetFeedButton  단축키·"/click" 매크로용 숨은 버튼. 뗄 때 동작(useOnKeyDown=false)으로 고정한다.
--                         매크로의 /click은 뗄 때 누르는 것으로 처리돼서, 키 누를 때 발동 설정이 켜져 있으면 헛돈다.
--   EzyWOWFPetFeedIcon    화면 버튼. 펫 초상화 옆이나 옮긴 자리에 있고, 펫이 없거나 죽으면 상태 드라이버가 숨긴다(전투 중에도).
--                         이것도 뗄 때 동작으로 고정한다. 애드온 버튼은 마우스 클릭이어도 isKeyPress·isSecureAction을 못 받아서
--                         (SecureTemplates.xml), 안 주면 "키 누를 때 발동"(기본 켬)을 따라 누를 때만 동작한다.
-- 펫이 먹는 중(먹이 주기 효과)이면 화면 버튼에 원형 게이지와 남은 초를 띄우고, 막기가 켜져 있으면 두 버튼을 비워 둔다.

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local KEY_BUTTON   = "EzyWOWFPetFeedButton"
local ICON_BUTTON  = "EzyWOWFPetFeedIcon"
local FEED_BINDING = "CLICK " .. KEY_BUTTON .. ":LeftButton"
local FEED_MACRO   = "펫 먹이"

local FEED_PET    = 6991     -- 먹이 주기
local FEED_EFFECT = 1539     -- 먹이 주기 효과 (먹는 동안 펫에 붙는 버프)
local FEED_NAME_FALLBACK = "먹이 주기"
local FEED_ICON_FALLBACK = "Interface\\Icons\\Ability_Hunter_BeastTraining"

local RANKS = 3
local FOOD_LEVEL_GAP = 10    -- 펫보다 이만큼 낮은 음식까지는 행복도가 제대로 오른다
local CAST_WATCH = 2         -- 먹이 주기 성공 뒤 펫 버프가 붙기를 기다려 주는 시간
local EAT_POLL = 0.25        -- 먹는 중인지 다시 보는 간격
local VISIBILITY = "[nopet] hide; [@pet,dead] hide; show"

local ITEM_CONSUMABLE = Enum and Enum.ItemClass and Enum.ItemClass.Consumable or 0
local ITEM_FOODDRINK = Enum and Enum.ItemConsumableSubclass and Enum.ItemConsumableSubclass.Fooddrink or 5

_G["BINDING_NAME_" .. FEED_BINDING] = "펫 먹이 주기 (등록한 음식 먼저)"

local M = ns:NewModule("PetFeed", {
	title = "펫 먹이",
	category = "hunter",
	icon = "Interface\\Icons\\INV_Misc_Food_14",
	order = 12,
	bindings = { FEED_BINDING },
	defaults = {
		enabled = true,
		food1 = 0, food2 = 0, food3 = 0,   -- 아이템 번호, 0 = 없음
		autoFallback = true,
		skipEating = true,
		showButton = true,
		size = 30,
		glowAt = 2,          -- 행복도가 이 값 이하면 반짝 (2 = 만족부터, 1 = 불만만, 0 = 안 함)
		lowAlert = true,
		lowCount = 5,
		anchor = "pet",      -- pet = 펫 초상화 옆, free = 옮긴 자리
		point = "CENTER", relPoint = "CENTER", x = 0, y = -180,
	},
})

local db
local isHunter = false
local food                 -- 지금 먹일 음식 { bag, slot, itemID, stack, total, level, link, icon, rank }
local regStatus            -- 등록 음식 형편 { edible = 이 펫이 먹는 등록 음식이 있음, total = 그 음식들 가방 속 개수 }
local eating = false
local eatEnd, eatDur       -- 먹이 주기 효과가 끝나는 시각·전체 길이 (모르면 nil)
local castWatchUntil = 0
local pendingFeed, pendingLayout = false, false
local moveMode = false
local eatTicker
local dropping = false

local GetItemInfoAPI = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function Active()
	return db ~= nil and db.enabled and isHunter
end

local function FeedName()
	local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(FEED_PET)
	return name or FEED_NAME_FALLBACK
end

local function FeedIcon()
	local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(FEED_PET)
	return icon or FEED_ICON_FALLBACK
end

local function PetAlive()
	return UnitExists("pet") and not Clean(UnitIsDead("pet"))
end

local function CanEat(itemID)
	local ok, edible = pcall(C_PetInfo.CanPetEatItem, itemID)
	return ok and Clean(edible) and true or false
end

local function IsFoodItem(itemID)
	if not (C_Item and C_Item.GetItemInfoInstant) then return false end
	local classID, subclassID = select(6, C_Item.GetItemInfoInstant(itemID))
	return classID == ITEM_CONSUMABLE and subclassID == ITEM_FOODDRINK
end

local function ItemName(itemID)
	local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
	return name or GetItemInfoAPI(itemID) or ("아이템 #" .. itemID)
end

local function ItemIcon(itemID)
	return C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID) or nil
end

-- 등록 순서대로, 겹치는 것 빼고
local function Registered(get)
	local list, seen = {}, {}
	for r = 1, RANKS do
		local id = get("food" .. r)
		if type(id) == "number" and id > 0 and not seen[id] then
			seen[id] = true
			list[#list + 1] = id
		end
	end
	return list
end

local function Saved(key) return db[key] end

---------------------------------------------------------------------------
-- 먹일 음식 고르기
---------------------------------------------------------------------------
-- 가방을 한 번 훑어 등록 음식(순위대로, 가장 작은 묶음부터 비운다)과 자동 후보를 같이 본다.
-- 등록 음식이 이 펫 입맛에 맞는지는 가방에 없어도 물어서 regStatus에 남긴다(먹이 부족 알림용).
local function ChooseFood()
	regStatus = nil
	if not (C_PetInfo and C_PetInfo.CanPetEatItem and C_Container) then return nil end
	if not PetAlive() then return nil end
	local petLevel = Clean(UnitLevel("pet")) or 1
	local reg = Registered(Saved)
	local isReg = {}
	for _, id in ipairs(reg) do isReg[id] = true end

	local edible, totals, regSlot = {}, {}, {}
	local good, fallback
	for bag = 0, NUM_BAG_SLOTS or 4 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local itemID = info and info.itemID
			if itemID and not info.isLocked then
				if edible[itemID] == nil then edible[itemID] = CanEat(itemID) end
				if edible[itemID] then
					local itemLevel = select(4, GetItemInfoAPI(itemID)) or 0
					local c = { bag = bag, slot = slot, itemID = itemID, level = itemLevel,
						stack = info.stackCount or 1, link = info.hyperlink, icon = info.iconFileID }
					totals[itemID] = (totals[itemID] or 0) + c.stack
					if isReg[itemID] then
						local best = regSlot[itemID]
						if not best or c.stack < best.stack then regSlot[itemID] = c end
					end
					if itemLevel >= petLevel - FOOD_LEVEL_GAP then
						if not good or c.level < good.level or (c.level == good.level and c.stack > good.stack) then
							good = c
						end
					elseif not fallback or c.level > fallback.level then
						fallback = c
					end
				end
			end
		end
	end

	local status = { edible = false, total = 0 }
	for _, id in ipairs(reg) do
		if edible[id] == nil then edible[id] = CanEat(id) end
		if edible[id] then
			status.edible = true
			status.total = status.total + (totals[id] or 0)
		end
	end
	regStatus = status

	for rank, id in ipairs(reg) do
		local c = edible[id] and regSlot[id]
		if c then
			c.rank, c.total = rank, totals[id]
			return c
		end
	end
	if #reg > 0 and not db.autoFallback then return nil end
	local pick = good or fallback
	if pick then pick.total = totals[pick.itemID] end
	return pick
end

-- 펫 몸에 먹이 주기 효과가 있으면 true, 끝나는 시각, 전체 길이. 버프를 못 읽는 때(감춤·API 없음)는 모른다 = 안 먹는 중.
local function EatingInfo()
	if not PetAlive() or not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return false end
	if C_Secrets and C_Secrets.ShouldAurasBeSecret and Clean(C_Secrets.ShouldAurasBeSecret()) then return false end
	local effectName = C_Spell and C_Spell.GetSpellName and Clean(C_Spell.GetSpellName(FEED_EFFECT))
	for i = 1, 40 do
		local a = C_UnitAuras.GetAuraDataByIndex("pet", i, "HELPFUL")
		if not a then break end
		local id, name = Clean(a.spellId), Clean(a.name)
		if id == FEED_EFFECT or (effectName ~= nil and name == effectName) then
			local exp, dur = Clean(a.expirationTime), Clean(a.duration)
			if type(exp) ~= "number" or exp <= 0 then exp = nil end
			if type(dur) ~= "number" or dur <= 0 then dur = nil end
			return true, exp, dur
		end
	end
	return false
end

local function Blocked()
	return eating and db.skipEating
end

-- 남은 초 (모르면 nil)
local function EatLeft()
	if not (eating and eatEnd) then return nil end
	local left = eatEnd - GetTime()
	return left > 0 and left or nil
end

---------------------------------------------------------------------------
-- 버튼
---------------------------------------------------------------------------
local keyButton = CreateFrame("Button", KEY_BUTTON, UIParent, "SecureActionButtonTemplate")
keyButton:SetSize(1, 1)
keyButton:SetPoint("CENTER")
keyButton:SetAlpha(0)
keyButton:EnableMouse(false)
keyButton:RegisterForClicks("AnyUp", "AnyDown")
keyButton:SetAttribute("useOnKeyDown", false)

local icon = CreateFrame("Button", ICON_BUTTON, UIParent, "SecureActionButtonTemplate")
icon:SetSize(30, 30)
icon:SetFrameStrata("MEDIUM")
icon:SetClampedToScreen(true)
icon:SetMovable(true)
icon:EnableMouse(true)
icon:RegisterForClicks("AnyUp")
icon:SetAttribute("useOnKeyDown", false)   -- 위 머리말: 안 주면 뗄 때 오는 클릭이 그냥 버려진다
icon:RegisterForDrag("LeftButton")
icon:Hide()

local iconTex = icon:CreateTexture(nil, "ARTWORK")
iconTex:SetAllPoints()
iconTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)

local border = icon:CreateTexture(nil, "BACKGROUND")
border:SetPoint("TOPLEFT", -1, 1)
border:SetPoint("BOTTOMRIGHT", 1, -1)
border:SetColorTexture(0, 0, 0, 1)

-- 먹는 동안 원형 게이지. 숫자는 우리 글자로 늘 띄우니 게임 숫자는 끈다.
local cooldown = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
cooldown:SetAllPoints()
cooldown:SetHideCountdownNumbers(true)
cooldown:SetDrawEdge(false)

-- 글자는 게이지 위에 와야 해서 한 층 위 프레임에 둔다
local textFrame = CreateFrame("Frame", nil, icon)
textFrame:SetAllPoints()
textFrame:SetFrameLevel(cooldown:GetFrameLevel() + 1)

local countText = textFrame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
countText:SetPoint("BOTTOMRIGHT", -1, 2)

local eatText = textFrame:CreateFontString(nil, "OVERLAY", "NumberFontNormalLarge")
eatText:SetPoint("CENTER", 0, 1)
eatText:SetTextColor(1, 0.85, 0.2)

local hover = icon:CreateTexture(nil, "HIGHLIGHT")
hover:SetAllPoints()
hover:SetColorTexture(1, 1, 1, 0.15)

local moveTint = icon:CreateTexture(nil, "OVERLAY")
moveTint:SetAllPoints()
moveTint:SetColorTexture(0, 1, 0, 0.35)
moveTint:Hide()

-- 반짝임은 보안 아닌 자식 프레임에서 글자·그림만 만진다. 전투 중에도 문제없다.
local glowFrame = CreateFrame("Frame", nil, icon)
glowFrame:SetAllPoints()
local glow = glowFrame:CreateTexture(nil, "OVERLAY")
glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
glow:SetBlendMode("ADD")
glow:SetPoint("CENTER")
glow:SetAlpha(0)
local glowing, glowPhase = nil, 0

local function GlowPulse(_, elapsed)
	glowPhase = glowPhase + elapsed * 4
	glow:SetAlpha(0.45 + 0.55 * math.abs(math.sin(glowPhase)))
end

local function SetGlow(level)
	if level == glowing then return end
	glowing = level
	if level then
		if level == 1 then glow:SetVertexColor(1, 0.3, 0.2) else glow:SetVertexColor(1, 0.85, 0.2) end
		glowFrame:SetScript("OnUpdate", GlowPulse)
	else
		glowFrame:SetScript("OnUpdate", nil)
		glow:SetAlpha(0)
	end
end

local function Low()
	return db.lowAlert and regStatus ~= nil and regStatus.edible and regStatus.total <= db.lowCount
end

-- 남은 초를 1초 단위로. 시각은 OnUpdate가 재고, 글자는 바뀔 때만 다시 넣는다.
local shownLeft
local function EatCountdown()
	local left = EatLeft()
	local whole = left and math.ceil(left) or nil
	if whole == shownLeft then return end
	shownLeft = whole
	eatText:SetText(whole and tostring(whole) or "")
	if not whole then textFrame:SetScript("OnUpdate", nil) end
end

local function RenderEating()
	local left = not moveMode and EatLeft()
	if left and eatDur then
		cooldown:SetCooldown(eatEnd - eatDur, eatDur)
	else
		cooldown:Clear()
	end
	shownLeft = nil
	if left then
		textFrame:SetScript("OnUpdate", EatCountdown)
		EatCountdown()
	else
		textFrame:SetScript("OnUpdate", nil)
		eatText:SetText("")
	end
end

-- 그림·숫자·반짝임만 바꾼다. 보안 속성은 안 건드리니 전투 중에도 부른다.
local function RenderIcon()
	if not db then return end
	local size = db.size
	glow:SetSize(size * 1.9, size * 1.9)
	RenderEating()
	if moveMode then
		iconTex:SetTexture(FeedIcon())
		iconTex:SetDesaturated(false)
		countText:SetText("")
		SetGlow(nil)
		return
	end
	iconTex:SetTexture(food and (food.icon or ItemIcon(food.itemID)) or FeedIcon())
	iconTex:SetDesaturated(food == nil or Blocked())
	if food then
		countText:SetText(tostring(food.total or food.stack))
		if Low() and food.rank then countText:SetTextColor(1, 0.3, 0.3) else countText:SetTextColor(1, 1, 1) end
	else
		countText:SetText("")
	end
	local happiness = Active() and PetAlive() and not eating and C_PetInfo and C_PetInfo.GetPetHappiness
		and Clean(C_PetInfo.GetPetHappiness()) or nil
	SetGlow(happiness and happiness <= (db.glowAt or 0) and happiness or nil)
end

local function SetMacro(button, macro)
	button:SetAttribute("*type1", macro and "macro" or nil)
	button:SetAttribute("*macrotext1", macro)
end

-- 고른 음식과 먹는 중 상태를 두 버튼에 싣는다.
local function ApplyButtons()
	if InCombatLockdown() then
		pendingFeed = true
		return
	end
	local macro = (food and not Blocked()) and ("/cast %s\n/use %d %d"):format(FeedName(), food.bag, food.slot) or nil
	SetMacro(keyButton, macro)
	SetMacro(icon, not moveMode and macro or nil)
	RenderIcon()
end

local function PetFrameAnchor()
	local f = _G.PetFrame
	return type(f) == "table" and f.GetObjectType and f or nil
end

-- 펫 초상화에 붙일 때는 초상화 크기(편집 모드 크기)를 따라간다. 그래야 행복도 아이콘과 안 겹친다.
local function PetFrameScale(petFrame)
	local ps, us = petFrame:GetEffectiveScale(), UIParent:GetEffectiveScale()
	if type(ps) == "number" and type(us) == "number" and ps > 0 and us > 0 then return ps / us end
	return 1
end

local function ApplyLayout()
	if not db then return end
	if InCombatLockdown() then
		pendingLayout = true
		return
	end
	pendingLayout = false
	icon:SetSize(db.size, db.size)
	icon:ClearAllPoints()
	local petFrame = db.anchor == "pet" and not moveMode and PetFrameAnchor()
	if petFrame then
		icon:SetScale(PetFrameScale(petFrame))
		icon:SetPoint("LEFT", petFrame, "RIGHT", 26, -4)   -- 행복도 아이콘(24px)은 초상화 오른쪽 끝에 붙어 있다
	else
		icon:SetScale(1)
		icon:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
	end
	moveTint:SetShown(moveMode)
	local show = Active() and db.showButton
	if (moveMode or not show) and UnregisterStateDriver then UnregisterStateDriver(icon, "visibility") end
	if moveMode then
		icon:Show()
	elseif show and RegisterStateDriver then
		RegisterStateDriver(icon, "visibility", VISIBILITY)
	else
		icon:Hide()
	end
	RenderIcon()
end

local SyncEatWatch

-- 먹는 중인지 다시 읽는다. 바뀌었으면 true.
local function ReadEating()
	local now, exp, dur = false, nil, nil
	if Active() then now, exp, dur = EatingInfo() end
	local changed = now ~= eating or exp ~= eatEnd or dur ~= eatDur
	eating, eatEnd, eatDur = now, exp, dur
	return changed
end

local function OnEatTick()
	if InCombatLockdown() then return end   -- 전투 중엔 어차피 못 먹인다. 틱은 그대로 돌다가 전투가 끝나면 다시 본다
	if ReadEating() then
		ApplyButtons()
		ns:Fire("REFRESH_UI")
	end
	SyncEatWatch()
end

-- 먹는 중이거나 막 먹였을 때만 돈다.
function SyncEatWatch()
	local want = Active() and (eating or GetTime() < castWatchUntil)
	if want and not eatTicker then
		eatTicker = C_Timer.NewTicker(EAT_POLL, OnEatTick)
	elseif not want and eatTicker then
		eatTicker:Cancel()
		eatTicker = nil
	end
end

local function UpdateFeed()
	if not db then return end
	if InCombatLockdown() then
		pendingFeed = true
		return
	end
	pendingFeed = false
	local before = food and food.itemID
	local beforeTotal = food and food.total
	local active = Active()
	food = active and ChooseFood() or nil
	if not active then regStatus = nil end
	ReadEating()   -- 마지막 음식을 먹이는 중이면 고를 음식이 없어도 게이지는 보여야 한다
	ApplyButtons()
	SyncEatWatch()
	if (food and food.itemID) ~= before or (food and food.total) ~= beforeTotal then ns:Fire("REFRESH_UI") end
end

local feedQueued = false
-- 꺼져 있으면 고를 음식도 없다. 끌 때 버튼을 비우는 건 ApplySettings의 UpdateFeed 몫.
local function RequestFeedUpdate()
	if feedQueued or not Active() then return end
	feedQueued = true
	C_Timer.After(0.3, function()
		feedQueued = false
		UpdateFeed()
	end)
end

---------------------------------------------------------------------------
-- 끌어다 놓아 등록
---------------------------------------------------------------------------
local function CursorItem()
	if not GetCursorInfo then return nil end
	local kind, itemID = GetCursorInfo()
	if kind == "item" and type(itemID) == "number" then return itemID end
end

-- 놓은 음식을 1순위로, 원래 순위들은 한 칸씩 밀린다.
local function RegisterFromCursor()
	local itemID = CursorItem()
	if not itemID then return false end
	ClearCursor()
	if not Active() then return true end
	local ok
	if PetAlive() then ok = CanEat(itemID) else ok = IsFoodItem(itemID) end
	if not ok then
		Print(PetAlive() and "이 펫은 그 음식을 먹지 않아요." or "음식만 등록할 수 있어요.")
		return true
	end
	local list = { itemID }
	for _, id in ipairs(Registered(Saved)) do
		if id ~= itemID and #list < RANKS then list[#list + 1] = id end
	end
	for r = 1, RANKS do
		db["food" .. r] = list[r] or 0
		ns:SetSetting(M, "food" .. r, db["food" .. r])   -- 설정 창에 걸려 있던 같은 칸 변경은 버린다
	end
	Print(("%s 을(를) 먹이 1순위로 등록했어요."):format(ItemName(itemID)))
	UpdateFeed()
	ns:Fire("REFRESH_UI")
	return true
end

---------------------------------------------------------------------------
-- 화면 버튼 동작
---------------------------------------------------------------------------
local function ExplainNoFeed()
	if Blocked() then
		local left = EatLeft()
		Print(left and ("펫이 아직 먹는 중이에요. (%d초 남음)"):format(math.ceil(left)) or "펫이 아직 먹는 중이에요.")
	elseif not UnitExists("pet") or Clean(UnitIsDead("pet")) then
		Print("먹이를 줄 펫이 없어요.")
	else
		Print("가방에 펫이 먹을 수 있는 음식이 없어요.")
	end
end

keyButton:SetScript("PostClick", function(_, _, down)
	if down or (food and not Blocked()) then return end
	ExplainNoFeed()
end)

-- 음식을 든 채 누르면 먹이지 말고 등록만 한다.
icon:SetScript("PreClick", function(self, button)
	dropping = button == "LeftButton" and CursorItem() ~= nil
	if dropping and not InCombatLockdown() then self:SetAttribute("*type1", nil) end
end)

icon:SetScript("PostClick", function(_, button)
	if dropping then
		dropping = false
		RegisterFromCursor()
		ApplyButtons()
		return
	end
	if moveMode then return end
	if button == "RightButton" then
		ns:OpenWindow("PetFeed")
	elseif button == "LeftButton" and not (food and not Blocked()) then
		ExplainNoFeed()
	end
end)

icon:SetScript("OnReceiveDrag", function() RegisterFromCursor() end)

icon:SetScript("OnDragStart", function(self)
	if moveMode then self:StartMoving() end
end)
icon:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	if not moveMode then return end
	local point, _, relPoint, x, y = self:GetPoint(1)
	db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end)

icon:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText("펫 먹이", 1, 0.82, 0)
	if moveMode then
		GameTooltip:AddLine("끌어서 옮기세요. 다 옮기면 설정 창에서 [이동 완료].", 1, 1, 1, true)
	else
		if food then
			GameTooltip:AddLine(("%s  %d개 (%s)"):format(food.link or ItemName(food.itemID), food.total or food.stack,
				food.rank and (food.rank .. "순위") or "자동"), 1, 1, 1)
		else
			GameTooltip:AddLine("먹일 음식이 없어요.", 0.6, 0.6, 0.6)
		end
		if eating then
			local left = EatLeft()
			GameTooltip:AddLine(left and ("펫이 먹는 중 (%d초 남음)"):format(math.ceil(left)) or "펫이 먹는 중", 1, 0.6, 0.2)
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("클릭: 먹이 주기", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("가방의 음식을 끌어다 놓기: 1순위로 등록", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("우클릭: 설정 열기", 0.8, 0.8, 0.8)
	end
	GameTooltip:Show()
end)
icon:SetScript("OnLeave", GameTooltip_Hide)

local function SetMoveMode(on)
	if on and InCombatLockdown() then
		Print("전투 중에는 옮길 수 없어요.")
		return
	end
	if on and db.anchor == "pet" then
		-- 지금 보이는 자리에서 떼어 낸다
		local cx, cy = icon:GetCenter()
		local ux, uy = UIParent:GetCenter()
		if cx and ux and icon:IsVisible() then
			local s = icon:GetScale()   -- 초상화 크기를 따라 커져 있던 좌표를 UIParent 좌표로
			db.point, db.relPoint, db.x, db.y = "CENTER", "CENTER", cx * s - ux, cy * s - uy
		end
		db.anchor = "free"
	end
	moveMode = on
	ApplyLayout()
	ApplyButtons()
	ns:Fire("REFRESH_UI")
	if on then Print("먹이 버튼을 끌어서 옮기세요. 다 옮기면 [이동 완료]를 누르세요.") end
end

local function Attach()
	db.anchor = "pet"
	if moveMode then SetMoveMode(false) else ApplyLayout() end
end

---------------------------------------------------------------------------
-- 다른 모듈이 쓰는 것
---------------------------------------------------------------------------
-- 펫 도우미 알림 창에 띄울 먹이 부족 한 줄. 없으면 nil.
function ns.PetFeedAlertLine()
	if not (Active() and regStatus and Low()) or InCombatLockdown() then return nil end
	if regStatus.total == 0 then return "등록한 먹이가 다 떨어졌어요" end
	return ("등록한 먹이가 %d개 남았어요"):format(regStatus.total)
end

---------------------------------------------------------------------------
-- 이벤트
---------------------------------------------------------------------------
local layoutQueued = false
-- 편집 모드 배치는 접속 뒤에 입혀진다. 초상화 크기를 그때 다시 읽는다.
local function RequestLayout()
	if layoutQueued or not db then return end
	layoutQueued = true
	C_Timer.After(0, function()
		layoutQueued = false
		ApplyLayout()
	end)
end

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
	RequestLayout()
	RequestFeedUpdate()
end)
ns:RegisterEvent("EDIT_MODE_LAYOUTS_UPDATED", RequestLayout)

-- 행복도(반짝임)도 먹이 갱신 때 같이 그린다. 전투 중 변화는 전투가 끝나고 반영돼도 늦지 않다(어차피 못 먹인다).
local function OnPetUnitEvent(_, unit)
	if unit == "player" or unit == "pet" then RequestFeedUpdate() end
end
ns:RegisterUnitEvent("UNIT_PET", OnPetUnitEvent, "player", "pet")
ns:RegisterUnitEvent("UNIT_LEVEL", OnPetUnitEvent, "player", "pet")
ns:RegisterEvent("UNIT_HAPPINESS", OnPetUnitEvent)
ns:RegisterEvent("BAG_UPDATE_DELAYED", RequestFeedUpdate)

-- 주문 번호는 클래식 값이라 포에버에서 다를 수도 있다. 이름이 같아도 먹이 주기로 친다.
local function IsFeedSpell(spellID)
	if spellID == FEED_PET then return true end
	local name = spellID and C_Spell and C_Spell.GetSpellName and Clean(C_Spell.GetSpellName(spellID))
	return name ~= nil and name == FeedName()
end

ns:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, _, _, spellID)
	if not Active() or not IsFeedSpell(Clean(spellID)) then return end
	castWatchUntil = GetTime() + CAST_WATCH
	SyncEatWatch()
end, "player")

ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
	if pendingLayout then ApplyLayout() end
	if pendingFeed then UpdateFeed() end
end)

ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
	if moveMode then SetMoveMode(false) end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
end

function M:OnLogin()
	isHunter = select(2, UnitClass("player")) == "HUNTER"
	ApplyLayout()
	UpdateFeed()
end

function M:ApplySettings(changes)
	if changes.enabled == false and moveMode then SetMoveMode(false) end
	ApplyLayout()
	UpdateFeed()
end

local function MacroBody()
	return ("#showtooltip %s\n/click %s"):format(FeedName(), KEY_BUTTON)
end

-- 펫이 있으면 그 펫이 먹는 음식, 없으면 음식 종류인 것. 아이템마다 한 줄.
local function BagFoods()
	local list, byID = {}, {}
	if not (C_Container and C_PetInfo and C_PetInfo.CanPetEatItem) then return list, byID end
	local pet = PetAlive()
	for bag = 0, NUM_BAG_SLOTS or 4 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local id = info and info.itemID
			if id then
				local e = byID[id]
				if not e then
					e = { itemID = id, count = 0, icon = info.iconFileID, level = select(4, GetItemInfoAPI(id)) or 0 }
					if pet then e.ok = CanEat(id) else e.ok = IsFoodItem(id) end
					byID[id] = e
					if e.ok then list[#list + 1] = e end
				end
				e.count = e.count + (info.stackCount or 1)
			end
		end
	end
	table.sort(list, function(a, b)
		if a.level ~= b.level then return a.level < b.level end
		return a.itemID < b.itemID
	end)
	return list, byID
end

local function IconText(itemID, tex)
	tex = tex or ItemIcon(itemID)
	return tex and ("|T%s:16:16:0:0|t "):format(tostring(tex)) or ""
end

function M:BuildOptions(b)
	local function Disabled() return not db.enabled end
	local function Pending(key) return ns:GetSetting(M, key) end

	local function FoodOptions(key)
		local current = Pending(key)
		local others = {}
		for r = 1, RANKS do
			local k = "food" .. r
			local v = Pending(k)
			if k ~= key and type(v) == "number" and v > 0 then others[v] = true end
		end
		local list, byID = BagFoods()
		local options = { { value = 0, text = "없음" } }
		local listed = false
		for _, e in ipairs(list) do
			if not others[e.itemID] then
				options[#options + 1] = { value = e.itemID,
					text = ("%s%s |cff999999(%d개)|r"):format(IconText(e.itemID, e.icon), ItemName(e.itemID), e.count) }
				listed = listed or e.itemID == current
			end
		end
		if type(current) == "number" and current > 0 and not listed then
			local note = byID[current] and "이 펫은 못 먹어요" or "가방에 없음"
			table.insert(options, 2, { value = current,
				text = ("%s%s |cff808080(%s)|r"):format(IconText(current), ItemName(current), note) })
		end
		return options
	end

	local function FoodText()
		if not isHunter then return "먹일 음식:  |cff808080사냥꾼만 쓸 수 있어요|r" end
		if not db.enabled then return "먹일 음식:  |cff808080꺼져 있어요|r" end
		if not food then return "먹일 음식:  |cff808080없음 (펫이 없거나 먹을 음식이 없어요)|r" end
		local how = food.rank and (food.rank .. "순위") or "자동 선택"
		local state = eating and "  |cffff9933먹는 중|r" or ""
		return ("먹일 음식:  %s  |cff999999(%d개, %s)|r%s"):format(food.link or ItemName(food.itemID),
			food.total or food.stack, how, state)
	end

	local function ListHint()
		if PetAlive() then return "목록에는 지금 펫이 먹을 수 있는 가방 속 음식만 나옵니다." end
		return "펫이 없어서 가방 속 음식을 모두 보여 줍니다. 펫을 불러 두면 먹을 수 있는 것만 나와요."
	end

	local function PlaceText()
		if moveMode then return "버튼 자리:  |cff33ff33옮기는 중|r" end
		return "버튼 자리:  " .. (db.anchor == "pet" and "펫 초상화 옆" or "옮긴 자리")
	end

	b:Text("등록한 음식을 1순위부터 먹입니다. 지금 펫이 못 먹거나 가방에 없는 순위는 건너뛰어서, "
		.. "펫마다 먹는 게 달라도 목록 하나로 됩니다. 등록이 없으면 펫 레벨에 맞는 음식을 알아서 고릅니다. "
		.. "(전투 중에는 먹이를 줄 수 없어요)")
	b:Check{ key = "enabled", label = "사용" }

	b:Header("먹일 음식")
	for r = 1, RANKS do
		local key = "food" .. r
		b:Dropdown{ key = key, label = r .. "순위", width = 280, depends = "enabled",
			options = function() return FoodOptions(key) end }
	end
	b:Text(ListHint, { color = { 0.6, 0.6, 0.6 } })
	b:Check{
		key = "autoFallback", label = "등록한 음식이 다 떨어지면 알맞은 음식을 자동으로 고르기", depends = "enabled", indent = 20,
		tooltip = "펫 레벨에 맞는 음식 중 가장 낮은 것을 씁니다. 끄면 등록한 음식이 없을 때 먹이지 않습니다.",
	}
	b:Check{
		key = "skipEating", label = "펫이 먹는 중이면 다시 먹이지 않기", depends = "enabled", indent = 20,
		tooltip = "먹이 주기 효과가 끝날 때까지 버튼과 단축키가 쉽니다. 연타해도 음식이 낭비되지 않아요.",
	}
	b:Text(FoodText, { font = "GameFontHighlight" })

	b:Header("화면 버튼")
	b:Text("클릭: 먹이 주기 · 가방의 음식을 버튼에 끌어다 놓기: 1순위로 등록 · 우클릭: 이 설정 열기. "
		.. "펫이 먹는 동안은 원형 게이지와 남은 초가 뜨고, 펫이 없거나 죽으면 버튼도 숨습니다.")
	b:Check{ key = "showButton", label = "화면에 먹이 버튼 보이기", depends = "enabled" }
	b:Slider{ key = "size", label = "버튼 크기", min = 20, max = 48, step = 2, format = "%d", depends = { "enabled", "showButton" } }
	b:Dropdown{
		key = "glowAt", label = "반짝임", width = 200, depends = { "enabled", "showButton" },
		options = function()
			return { { value = 2, text = "만족(노랑)부터" }, { value = 1, text = "불만(빨강)일 때만" }, { value = 0, text = "반짝이지 않음" } }
		end,
		tooltip = "펫 기분이 이만큼 내려가면 버튼 테두리가 반짝입니다.",
	}
	b:Text(PlaceText, { font = "GameFontHighlight" })
	b:Buttons{
		{
			text = "버튼 옮기기", width = 130,
			textFunc = function() return moveMode and "이동 완료" or "버튼 옮기기" end,
			onClick = function() SetMoveMode(not moveMode) end,
			disabled = function() return not (db.enabled and db.showButton and isHunter) end,
		},
		{
			text = "펫 초상화 옆에 붙이기", width = 170, onClick = Attach,
			disabled = function() return not (db.enabled and db.showButton) or (db.anchor == "pet" and not moveMode) end,
		},
	}

	b:Header("먹이 부족 알림")
	b:Check{
		key = "lowAlert", label = "등록한 먹이가 적으면 펫 알림에 띄우기", depends = "enabled",
		tooltip = "지금 펫이 먹을 수 있는 등록 음식의 가방 속 개수를 셉니다. 펫 도우미의 알림 자리에 뜨니 펫 도우미도 켜져 있어야 해요.",
	}
	b:Slider{ key = "lowCount", label = "알림 기준 (개 이하)", min = 1, max = 40, step = 1, format = "%d", depends = { "enabled", "lowAlert" } }

	b:Header("단축키·매크로")
	b:KeyBind{ command = FEED_BINDING, label = "먹이 주기", depends = "enabled" }
	b:Buttons{
		{
			text = "먹이 매크로 만들기", width = 150,
			onClick = function() ns.MakeCharacterMacro(FEED_MACRO, MacroBody()) end,
			tooltip = "단축키 대신 행동 단축바에 올려 쓰는 매크로를 만듭니다. 누르면 먹이 키와 똑같이 동작합니다.",
			disabled = Disabled,
		},
	}
end
