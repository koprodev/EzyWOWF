-- 퀘스트 아이템 단축키.
-- 목표 창에서 고른 퀘스트(옵션을 끄면 가장 가까운 퀘스트)의 아이템을 보안 버튼(EzyWOWFQuestItemButton)에 연결하고,
-- 그 버튼을 키 바인딩(CLICK)으로 누르는 방식이다.

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local BUTTON_NAME  = "EzyWOWFQuestItemButton"
local USE_BINDING  = "CLICK " .. BUTTON_NAME .. ":LeftButton"
local NEXT_BINDING = "EZYWOWF_QUESTITEM_NEXT"
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local DEFAULT_POS  = { point = "CENTER", relPoint = "CENTER", x = 0, y = -160 }

-- 예전 단독 애드온(QuestItemKey)에서 쓰던 단축키를 옮겨 온다.
local LEGACY_BINDINGS = {
	["CLICK QuestItemKeyButton:LeftButton"] = USE_BINDING,
	["QUESTITEMKEY_NEXT"] = NEXT_BINDING,
}

_G["BINDING_NAME_" .. USE_BINDING]  = "퀘스트 아이템 사용"
_G["BINDING_NAME_" .. NEXT_BINDING] = "다음 퀘스트 아이템으로 전환"

local M = ns:NewModule("QuestItem", {
	title = "퀘스트 아이템",
	category = "quest",
	icon = "Interface\\Icons\\INV_Misc_Rune_07",
	order = 10,
	bindings = { USE_BINDING, NEXT_BINDING },
	defaults = {
		enabled = true,
		showButton = true,
		scale = 1,
		selectedOnly = true,   -- 목표 창에서 고른(집중 추적) 퀘스트 하나만. 끄면 가까운 퀘스트 자동
		resetOnZone = true,
		point = DEFAULT_POS.point, relPoint = DEFAULT_POS.relPoint, x = DEFAULT_POS.x, y = DEFAULT_POS.y,
	},
})

local GetSpecialItemInfo   = GetQuestLogSpecialItemInfo or (C_QuestLog and C_QuestLog.GetQuestLogSpecialItemInfo)
local IsSpecialItemInRange = IsQuestLogSpecialItemInRange or (C_QuestLog and C_QuestLog.IsQuestLogSpecialItemInRange)
local GetItemCountAPI      = (C_Item and C_Item.GetItemCount) or GetItemCount
local GetItemCooldownAPI   = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
local GetItemIconAPI       = (C_Item and C_Item.GetItemIconByID) or GetItemIcon

local db
local current                 -- 지금 버튼에 연결된 후보
local manualItemID            -- 우클릭/전환 키로 직접 고른 아이템
local moveMode = false
local isMoving = false
local pendingAfterCombat = false
local applied = { valid = false }   -- 마지막으로 실제 반영한 레이아웃 입력(켜짐·표시·이동·아이템)
local stateHidden = false           -- 알파 0 버튼이라 개수·사거리 색은 어차피 안 보임

---------------------------------------------------------------------------
-- 후보 수집
---------------------------------------------------------------------------
local function SafeDistance(questID)
	local ok, distSq, onContinent = pcall(C_QuestLog.GetDistanceSqToQuest, questID)
	if not ok then return nil end
	distSq, onContinent = Clean(distSq), Clean(onContinent)
	if type(distSq) ~= "number" then return nil end
	return distSq, onContinent
end

local function IsTaskActive(questID)
	if not (C_TaskQuest and C_TaskQuest.IsActive) then return false end
	return Clean(C_TaskQuest.IsActive(questID)) and true or false
end

local function IsWatched(questID)
	return C_QuestLog.GetQuestWatchType and C_QuestLog.GetQuestWatchType(questID) ~= nil or false
end

-- 목표 창에서 고른(아이콘이 노란, 집중 추적) 퀘스트. 없거나 퀘스트가 아닌 것(지도 핀 등)을 쫓는 중이면 nil
local function FocusedQuestID()
	local id = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and Clean(C_SuperTrack.GetSuperTrackedQuestID())
	if type(id) == "number" and id > 0 then return id end
end

-- 우선순위: 지역 과제 진행 중 > 같은 대륙에서 가까운 순 > 추적 중인 퀘스트 > 퀘스트 목록 순서
local function CompareCandidates(a, b)
	if a.active ~= b.active then return a.active end
	if a.near ~= b.near then return a.near end
	if a.dist ~= b.dist then return a.dist < b.dist end
	if a.watched ~= b.watched then return a.watched end
	return a.logIndex < b.logIndex
end

local function CollectCandidates()
	local list = {}
	if not GetSpecialItemInfo then return list end
	-- 포에버는 받은 퀘스트를 전부 추적기에 올리니(autoQuestWatch) "추적 중"은 집중 추적 하나로 본다
	local focusID = db.selectedOnly and FocusedQuestID()
	if db.selectedOnly and not focusID then return list end

	for index = 1, C_QuestLog.GetNumQuestLogEntries() do
		local info = C_QuestLog.GetInfo(index)
		local questID = info and not info.isHeader and info.questID
		if questID and questID > 0 then
			local link, texture, _, showWhenComplete = GetSpecialItemInfo(index)
			link = Clean(link)
			local itemID = link and tonumber(link:match("item:(%d+)"))
			if itemID and (not Clean(C_QuestLog.IsComplete(questID)) or showWhenComplete) then
				local active, watched = IsTaskActive(questID), IsWatched(questID)
				if not focusID or questID == focusID then
					local distSq, onContinent = SafeDistance(questID)
					list[#list + 1] = {
						questID  = questID,
						logIndex = index,
						itemID   = itemID,
						link     = link,
						texture  = Clean(texture),
						title    = info.title,
						active   = active,
						near     = (distSq and onContinent) and true or false,
						dist     = distSq or math.huge,
						watched  = watched,
					}
				end
			end
		end
	end

	table.sort(list, CompareCandidates)

	-- 같은 아이템을 쓰는 퀘스트가 여러 개면 하나만 남긴다.
	local seen, unique = {}, {}
	for _, c in ipairs(list) do
		if not seen[c.itemID] then
			seen[c.itemID] = true
			unique[#unique + 1] = c
		end
	end
	return unique
end

---------------------------------------------------------------------------
-- 화면 버튼
---------------------------------------------------------------------------
local button = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate")
button:SetSize(40, 40)
button:SetPoint(DEFAULT_POS.point, UIParent, DEFAULT_POS.relPoint, DEFAULT_POS.x, DEFAULT_POS.y)
button:SetFrameStrata("MEDIUM")
button:SetMovable(true)
button:SetClampedToScreen(true)
if button.SetDontSavePosition then button:SetDontSavePosition(true) end
button:RegisterForClicks("AnyUp", "AnyDown")
button:RegisterForDrag("LeftButton")
button:Hide()

local edge = button:CreateTexture(nil, "BACKGROUND", nil, 0)
edge:SetAllPoints()
edge:SetColorTexture(0, 0, 0, 0.9)

local gold = button:CreateTexture(nil, "BACKGROUND", nil, 1)
gold:SetPoint("TOPLEFT", 1, -1)
gold:SetPoint("BOTTOMRIGHT", -1, 1)
gold:SetColorTexture(0.85, 0.65, 0.13, 1)

local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetPoint("TOPLEFT", 2, -2)
icon:SetPoint("BOTTOMRIGHT", -2, 2)
icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
icon:SetTexture(DEFAULT_ICON)

button:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
button:GetPushedTexture():SetAllPoints(icon)
button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
button:GetHighlightTexture():SetAllPoints(icon)

local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
cooldown:SetAllPoints(icon)

-- 글자가 쿨다운 위에 보이도록 별도 프레임에 올린다.
local overlay = CreateFrame("Frame", nil, button)
overlay:SetAllPoints()
overlay:SetFrameLevel(cooldown:GetFrameLevel() + 2)

local hotkey = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
hotkey:SetPoint("TOPLEFT", 3, -4)
hotkey:SetPoint("TOPRIGHT", -3, -4)
hotkey:SetJustifyH("RIGHT")
hotkey:SetWordWrap(false)

local count = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
count:SetPoint("BOTTOMRIGHT", -3, 3)

local moveTint = overlay:CreateTexture(nil, "OVERLAY")
moveTint:SetAllPoints()
moveTint:SetColorTexture(0, 1, 0, 0.25)
moveTint:Hide()

local moveLabel = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
moveLabel:SetPoint("BOTTOM", button, "TOP", 0, 4)
moveLabel:SetText("퀘스트 아이템\n드래그해서 이동")
moveLabel:Hide()

---------------------------------------------------------------------------
-- 표시 갱신 (전투 중에도 안전한 것들)
---------------------------------------------------------------------------
local function UpdateHotkey()
	local key = GetBindingKey(USE_BINDING)
	hotkey:SetText(key and GetBindingText(key, true) or "")
end

local function ApplyCooldown(itemID)
	local start, duration, enable = GetItemCooldownAPI(itemID)
	if not start or enable == false or enable == 0 then
		cooldown:Clear()
	else
		cooldown:SetCooldown(start, duration)
	end
end

local function UpdateCooldown()
	if not current or not pcall(ApplyCooldown, current.itemID) then
		cooldown:Clear()
	end
end

local function CheckOutOfRange(logIndex)
	local r = IsSpecialItemInRange(logIndex)
	return r == 0 or r == false
end

local function UpdateState()
	if stateHidden then return end
	if not current then
		count:SetText("")
		icon:SetVertexColor(1, 1, 1)
		return
	end

	local ok, n = pcall(GetItemCountAPI, current.itemID, false, true)
	n = ok and Clean(n) or nil
	count:SetText((n and n > 1) and n or "")

	if n == 0 then
		icon:SetVertexColor(0.4, 0.4, 0.4)   -- 가방에 없음
		return
	end

	local outOfRange = false
	if IsSpecialItemInRange then
		local logIndex = C_QuestLog.GetLogIndexForQuestID(current.questID)
		if logIndex then
			local okRange, res = pcall(CheckOutOfRange, logIndex)
			outOfRange = okRange and Clean(res) or false
		end
	end
	if outOfRange then
		icon:SetVertexColor(0.9, 0.2, 0.2)
	else
		icon:SetVertexColor(1, 1, 1)
	end
end

local function UpdateDisplay()
	if current then
		icon:SetTexture(current.texture or GetItemIconAPI(current.itemID) or DEFAULT_ICON)
	else
		icon:SetTexture(DEFAULT_ICON)
	end
	UpdateHotkey()
	UpdateCooldown()
	UpdateState()
end

---------------------------------------------------------------------------
-- 보안 속성/위치 (전투 중에는 바꿀 수 없음)
---------------------------------------------------------------------------
local function SetAttr(key, value)
	if button:GetAttribute(key) ~= value then
		button:SetAttribute(key, value)
	end
end

local function UpdateLayout()
	if not db then return end
	if InCombatLockdown() then
		pendingAfterCombat = true
		return
	end

	local itemID = current and current.itemID
	if applied.valid and applied.enabled == db.enabled and applied.showButton == db.showButton
		and applied.moveMode == moveMode and applied.itemID == itemID then
		return   -- 입력이 그대로면 결과도 그대로
	end

	local usable = db.enabled and current and not moveMode
	-- "*type1": 단축키에 SHIFT 같은 조합키가 섞여도 동작하도록 와일드카드 사용
	SetAttr("*type1", usable and "item" or nil)
	SetAttr("item", (db.enabled and current) and ("item:" .. current.itemID) or nil)

	local invisible = not db.showButton and not moveMode
	button:SetAlpha(invisible and 0 or 1)
	button:EnableMouse(not invisible)
	moveTint:SetShown(moveMode)
	moveLabel:SetShown(moveMode)
	button:SetShown(db.enabled and (current ~= nil or moveMode))
	-- 위에서 읽는 입력이 늘어나면 여기와 조기 반환 조건에도 같이 넣을 것
	applied.valid, applied.enabled, applied.showButton, applied.moveMode, applied.itemID = true, db.enabled, db.showButton, moveMode, itemID
	stateHidden = invisible
end

local function ApplyPosition()
	if not db then return end
	if InCombatLockdown() then
		pendingAfterCombat = true
		return
	end
	button:ClearAllPoints()
	button:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
	button:SetScale(db.scale)
end

---------------------------------------------------------------------------
-- 선택
---------------------------------------------------------------------------
local function SetSelection(candidate)
	local changed = (current and current.itemID) ~= (candidate and candidate.itemID)
	current = candidate
	UpdateLayout()
	UpdateDisplay()
	if changed then ns:Fire("REFRESH_UI") end
end

local function Evaluate()
	if not db then return end
	if InCombatLockdown() then
		pendingAfterCombat = true
		return
	end
	pendingAfterCombat = false

	if not db.enabled then
		-- 꺼진 화면이 이미 반영됐으면 매초 다시 칠하지 않는다(버튼은 숨김 상태)
		if current ~= nil or not (applied.valid and applied.enabled == false) then
			SetSelection(nil)
		end
		return
	end

	local list = CollectCandidates()
	local chosen
	if manualItemID then
		for _, c in ipairs(list) do
			if c.itemID == manualItemID then
				chosen = c
				break
			end
		end
		if not chosen then manualItemID = nil end
	end
	SetSelection(chosen or list[1])
end

local updateQueued = false
local function RunQueuedUpdate()
	updateQueued = false
	Evaluate()
end

local function RequestUpdate()
	if updateQueued then return end
	updateQueued = true
	C_Timer.After(0.1, RunQueuedUpdate)
end

-- 후보가 없을 때 채팅 안내. 고른 퀘스트만 쓰는 모드면 무엇이 빠졌는지 알려 준다
local function NoItemText()
	if db.selectedOnly then
		if FocusedQuestID() then return "고른 퀘스트에는 쓸 아이템이 없습니다." end
		return "고른 퀘스트가 없습니다. 목표 창에서 퀘스트 아이콘을 클릭해 고르세요. (오른쪽 클릭 > 집중도 같음)"
	end
	return "사용할 수 있는 퀘스트 아이템이 없습니다."
end

local function Cycle()
	if not db.enabled then
		Print("퀘스트 아이템 기능이 꺼져 있어요. (/이지)")
		return
	end
	if InCombatLockdown() then
		Print("전투 중에는 아이템을 바꿀 수 없어요. 전투가 끝난 뒤 다시 눌러 주세요.")
		return
	end
	local list = CollectCandidates()
	if #list == 0 then
		Print(NoItemText())
		return
	end

	local pos = 0
	if current then
		for i, c in ipairs(list) do
			if c.itemID == current.itemID then
				pos = i
				break
			end
		end
	end
	local nextPos = pos % #list + 1
	local c = list[nextPos]
	manualItemID = c.itemID
	SetSelection(c)
	Print(("%s |cff999999- %s (%d/%d)|r"):format(c.link, c.title or "?", nextPos, #list))
end

function EzyWOWF_QuestItemNext()
	Cycle()
end

local function ResetToAuto()
	if InCombatLockdown() then
		Print("전투 중에는 바꿀 수 없어요.")
		return
	end
	manualItemID = nil
	Evaluate()
	Print(db.selectedOnly and "자동 선택(목표 창에서 고른 퀘스트)으로 돌아갑니다." or "자동 선택(가까운 퀘스트 우선)으로 돌아갑니다.")
end

local function PrintList()
	local list = CollectCandidates()
	if #list == 0 then
		Print(NoItemText())
		return
	end
	Print(("퀘스트 아이템 %d개 (위쪽이 우선):"):format(#list))
	for i, c in ipairs(list) do
		local where
		if c.active then
			where = "지역 과제 진행 중"
		elseif c.near then
			where = ("%d미터"):format(math.floor(math.sqrt(c.dist)))
		else
			where = "다른 지역"
		end
		local mark = (current and current.itemID == c.itemID) and " |cff00ff00<- 사용 중|r" or ""
		print(("  %d. %s |cff999999%s (%s)|r%s"):format(i, c.link, c.title or "?", where, mark))
	end
end

---------------------------------------------------------------------------
-- 위치 이동
---------------------------------------------------------------------------
local function SavePosition()
	local point, _, relPoint, x, y = button:GetPoint(1)
	db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

local function StopMoving()
	if isMoving then
		isMoving = false
		button:StopMovingOrSizing()
		SavePosition()
	end
end

local function SetMoveMode(on)
	if InCombatLockdown() then
		Print("전투 중에는 할 수 없어요.")
		return
	end
	if on and not db.enabled then
		Print("퀘스트 아이템 기능이 꺼져 있어요.")
		return
	end
	if not on then StopMoving() end
	moveMode = on
	UpdateLayout()
	UpdateDisplay()
	ns:Fire("REFRESH_UI")
	if on then Print("화면의 퀘스트 아이템 버튼을 드래그해서 옮기세요. 다 옮기면 [이동 완료]를 누르세요.") end
end

local function ResetPosition()
	if InCombatLockdown() then
		Print("전투 중에는 할 수 없어요.")
		return
	end
	db.point, db.relPoint, db.x, db.y = DEFAULT_POS.point, DEFAULT_POS.relPoint, DEFAULT_POS.x, DEFAULT_POS.y
	ApplyPosition()
	Print("버튼 위치를 초기화했습니다.")
end

---------------------------------------------------------------------------
-- 버튼 스크립트
---------------------------------------------------------------------------
button:SetScript("PostClick", function(_, mouseButton, down)
	if down or mouseButton ~= "RightButton" then return end
	if IsShiftKeyDown() then
		ResetToAuto()
	else
		Cycle()
	end
end)

button:SetScript("OnDragStart", function(self)
	if moveMode and not InCombatLockdown() then
		isMoving = true
		self:StartMoving()
	end
end)

button:SetScript("OnDragStop", StopMoving)

button:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if current then
		GameTooltip:SetHyperlink(current.link)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("퀘스트: " .. (current.title or "?"), 1, 0.82, 0)
		if manualItemID then
			GameTooltip:AddLine("직접 선택됨 (Shift+우클릭: 자동 선택으로)", 0.5, 0.8, 1)
		end
	else
		GameTooltip:AddLine("퀘스트 아이템", 1, 0.82, 0)
		GameTooltip:AddLine("지금 사용할 퀘스트 아이템이 없습니다.", 1, 1, 1)
	end
	local key = GetBindingKey(USE_BINDING)
	GameTooltip:AddLine("단축키: " .. (key and GetBindingText(key) or "없음 (/이지 에서 지정)"), 0.7, 0.7, 0.7)
	GameTooltip:AddLine("우클릭: 다음 퀘스트 아이템", 0.7, 0.7, 0.7)
	if moveMode then
		GameTooltip:AddLine("드래그해서 이동", 0.3, 1, 0.3)
	end
	GameTooltip:Show()
end)

button:SetScript("OnLeave", GameTooltip_Hide)

local sinceStateUpdate = 0
button:SetScript("OnUpdate", function(_, elapsed)
	sinceStateUpdate = sinceStateUpdate + elapsed
	if sinceStateUpdate >= 0.2 then
		sinceStateUpdate = 0
		UpdateState()
	end
end)

---------------------------------------------------------------------------
-- 이벤트
---------------------------------------------------------------------------
local function OnEvent(event)
	if not db then return end
	if event == "PLAYER_REGEN_ENABLED" then
		if pendingAfterCombat then
			ApplyPosition()
			Evaluate()
		end
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- 전투 시작 직전: 이동 모드면 끄고 단축키가 다시 동작하게 한다.
		if moveMode then
			StopMoving()
			moveMode = false
			UpdateLayout()
			ns:Fire("REFRESH_UI")
		end
	elseif event == "ZONE_CHANGED_NEW_AREA" then
		if db.resetOnZone then manualItemID = nil end
		RequestUpdate()
	elseif event == "BAG_UPDATE_COOLDOWN" then
		UpdateCooldown()
	elseif event == "UPDATE_BINDINGS" then
		UpdateHotkey()
	else
		RequestUpdate()
	end
end

for _, event in ipairs({
	"PLAYER_ENTERING_WORLD",
	"PLAYER_REGEN_ENABLED",
	"PLAYER_REGEN_DISABLED",
	"QUEST_LOG_UPDATE",
	"QUEST_WATCH_LIST_CHANGED",
	"SUPER_TRACKING_CHANGED",
	"QUEST_ACCEPTED",
	"QUEST_REMOVED",
	"ZONE_CHANGED",
	"ZONE_CHANGED_NEW_AREA",
	"BAG_UPDATE_DELAYED",
	"BAG_UPDATE_COOLDOWN",
	"UPDATE_BINDINGS",
}) do
	ns:RegisterEvent(event, OnEvent)
end

local function MigrateLegacyBindings()
	if InCombatLockdown() then return end
	local moved = false
	for old, new in pairs(LEGACY_BINDINGS) do
		local keys = { GetBindingKey(old) }
		if #keys > 0 and not GetBindingKey(new) then
			for _, key in ipairs(keys) do SetBinding(key, new) end
			moved = true
		end
	end
	if moved then
		SaveBindings(GetCurrentBindingSet())
		Print("예전 퀘템키 애드온의 단축키를 그대로 옮겨 왔습니다.")
	end
end

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	-- 옛 키는 "고른 퀘스트만"이 기본 꺼짐이던 시절 값이라 버리고 새 기본(켜짐)으로 출발
	db.watchedOnly, db.focusedOnly = nil, nil
	ApplyPosition()
	UpdateLayout()
end

function M:OnLogin()
	-- 이동하면서 가까운 퀘스트가 바뀌므로 주기적으로 다시 고른다.
	C_Timer.NewTicker(1, Evaluate)
	C_Timer.After(3, function()
		MigrateLegacyBindings()
		if not db.enabled then return end
		if not GetSpecialItemInfo then
			Print("|cffff5555이 게임 버전에서 퀘스트 아이템 API를 찾지 못했습니다.|r")
		elseif not GetBindingKey(USE_BINDING) then
			Print(("퀘스트 아이템 단축키가 아직 없어요. |cff00ff00/이지|r > %s에서 지정하세요."):format(ns:SettingsPath("QuestItem")))
		end
	end)
end

function M:ApplySettings(changes)
	if changes.enabled == false then
		manualItemID = nil
		if moveMode then SetMoveMode(false) end
	end
	if changes.resetOnZone ~= nil or changes.selectedOnly ~= nil then
		manualItemID = nil
	end
	ApplyPosition()
	Evaluate()
end

function M:GetTooltipLine()
	if not db.enabled then return "퀘스트 아이템", "|cff808080꺼짐|r" end
	local key = GetBindingKey(USE_BINDING)
	local item = current and current.link or "|cff808080없음|r"
	return "퀘스트 아이템" .. (key and (" [" .. GetBindingText(key) .. "]") or ""), item
end

local function CurrentItemText()
	if not db.enabled then return "현재 연결된 아이템:  |cff808080기능 꺼짐|r" end
	if not current then return "현재 연결된 아이템:  |cff808080없음|r" end
	local suffix = manualItemID and "  |cff80ccff(직접 선택)|r" or ""
	return ("현재 연결된 아이템:  %s  |cff999999%s|r%s"):format(current.link, current.title or "", suffix)
end

function M:BuildOptions(b)
	local function Disabled() return not db.enabled end

	b:Header("퀘스트 아이템 단축키")
	b:Text("퀘스트 추적기 옆에 뜨는 퀘스트 아이템을 단축키로 사용합니다. "
		.. "목표 창에서 고른 퀘스트의 아이템만 띄우고, 고른 퀘스트가 없으면 버튼을 숨깁니다. "
		.. "아래 [선택 방식]에서 끄면 가장 가까운 퀘스트의 것을 자동으로 고르고, 화면 버튼을 우클릭하거나 전환 키로 바꿀 수 있습니다.")
	b:Check{ key = "enabled", label = "기능 사용" }
	b:Text(CurrentItemText, { font = "GameFontHighlight" })

	b:Header("단축키")
	b:KeyBind{ command = USE_BINDING, label = "아이템 사용", depends = "enabled" }
	b:KeyBind{ command = NEXT_BINDING, label = "다음 아이템으로 전환", depends = "enabled" }
	b:Text("버튼을 클릭한 뒤 원하는 키를 누르세요. 우클릭: 해제 / ESC: 취소", { color = { 0.6, 0.6, 0.6 } })

	b:Header("화면 버튼")
	b:Check{
		key = "showButton",
		label = "화면에 아이템 버튼 표시",
		tooltip = "꺼도 단축키는 그대로 동작합니다.",
		depends = "enabled",
	}
	b:Slider{ key = "scale", label = "버튼 크기", min = 0.5, max = 2, step = 0.05, format = "%.2f", depends = "enabled" }
	b:Buttons{
		{
			text = "위치 이동",
			textFunc = function() return moveMode and "이동 완료" or "위치 이동" end,
			onClick = function() SetMoveMode(not moveMode) end,
			disabled = Disabled,
			tooltip = "화면의 버튼을 드래그해서 옮길 수 있게 합니다. 바로 적용됩니다.",
		},
		{ text = "위치 초기화", onClick = ResetPosition, disabled = Disabled },
	}

	b:Header("선택 방식")
	b:Check{
		key = "selectedOnly",
		label = "목표 창에서 고른 퀘스트의 아이템만 사용",
		tooltip = "목표 창에서 퀘스트 아이콘을 클릭해 노랗게 고른 퀘스트(오른쪽 클릭 > 집중과 같음, 퀘스트 방향 화살표가 가리키는 퀘스트) 하나의 아이템만 띄웁니다.\n"
			.. "고른 퀘스트가 없거나 그 퀘스트에 아이템이 없으면 버튼을 숨깁니다. 노란 아이콘을 다시 클릭하면 선택이 풀립니다.\n"
			.. "끄면 가장 가까운 퀘스트의 아이템을 자동으로 고릅니다.",
		depends = "enabled",
	}
	b:Check{
		key = "resetOnZone",
		label = "지역이 바뀌면 자동 선택으로 돌아가기",
		tooltip = "우클릭이나 전환 키로 직접 고른 아이템을 지역을 옮길 때 해제합니다.",
		depends = "enabled",
	}
	b:Buttons{
		{ text = "아이템 목록 보기", onClick = PrintList, disabled = Disabled, tooltip = "현재 후보를 채팅창에 출력합니다." },
		{ text = "자동 선택으로", onClick = ResetToAuto, disabled = Disabled },
	}
end

---------------------------------------------------------------------------
-- 슬래시 명령
---------------------------------------------------------------------------
SLASH_EZYWOWFQUESTITEM1 = "/퀘템"
SLASH_EZYWOWFQUESTITEM2 = "/qik"
SlashCmdList.EZYWOWFQUESTITEM = function(msg)
	local cmd = ((msg or ""):match("^%s*(%S*)") or ""):lower()
	if cmd == "list" then
		PrintList()
	elseif cmd == "next" then
		Cycle()
	elseif cmd == "auto" then
		ResetToAuto()
	elseif cmd == "move" then
		SetMoveMode(not moveMode)
	else
		ns:OpenWindow("QuestItem")
	end
end
