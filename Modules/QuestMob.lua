-- 퀘스트 몹: 아직 끝내지 않은 퀘스트의 몹을 단축키로 대상 지정하고, 적 이름표에 표시한다.
--
-- 대상 지정은 보호된 동작이라 자동으로는 못 한다. 보안 버튼(EzyWOWFQuestMobButton)에
-- "/targetexact 몹 이름" 매크로를 넣고 키로 누른다. 매크로는 전투 밖에서만 바꿀 수 있다.
-- 몹 이름은 두 군데서 모은다.
--   1) 퀘스트 목표 문구: "5/6 힘센 바위턱트로그 처치" -> "힘센 바위턱트로그"
--   2) 이름표·마우스오버·대상의 툴팁 퀘스트 정보 (아이템을 떨구는 몹도 잡힌다)
-- Private markers use local nameplates; shared raid marks run inside the secure macro.

local _, ns = ...
local Print = ns.Print
local IsSecret = type(issecretvalue) == "function" and issecretvalue or function() return false end
local function Clean(value)
	if IsSecret(value) then return nil end
	return value
end

local BUTTON_NAME    = "EzyWOWFQuestMobButton"
local TARGET_BINDING = "CLICK " .. BUTTON_NAME .. ":LeftButton"
local SELECTED_CALLBACK = "EzyWOWFQuestMobTargetFound"
local MAX_NAMES      = 8      -- 매크로 길이 제한(1023바이트) 안에 들어가도록
local MAX_MACRO_LEN  = 1000
local KILL_SUFFIXES  = { " 처치", " 처치함", " slain", " killed" }
local MARKER_ATLAS   = "QuestNormal"
local MARKER_TEXTURE = "Interface\\GossipFrame\\AvailableQuestIcon"
local RAID_MARKS     = { 8, 7, 6, 5, 4, 3, 2, 1 }   -- 고르는 순서: 해골·가위표·네모·달·세모·다이아몬드·동그라미·별 (징표 단축바와 같음)
local RAID_MARK_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_%d"
local DEFAULT_MARK   = 7                            -- 가위표(X)

_G["BINDING_NAME_" .. TARGET_BINDING] = "가까운 퀘스트 몹 대상 잡기"

local M = ns:NewModule("QuestMob", {
	title = "퀘스트 몹",
	category = "quest",
	icon = "Interface\\Icons\\Ability_Hunter_SniperShot",
	order = 30,
	bindings = { TARGET_BINDING },
	defaults = {
		enabled = true,
		watchedOnly = false,
		showMarker = true,
		markerSize = 20,
		markTarget = false,
		shareTargetMark = false,
		markIcon = DEFAULT_MARK,
	},
})

local db
local targets = {}         -- 대상 키에 들어간 몹 (우선순위 순) { name =, title =, learned = }
local objectiveNames = {}  -- [name] = unfinished quest ID set from objective text.
local learned = {}         -- [name][questID] = objective key set learned from unit tooltips.
local openTitles = {}
local openQuestIDs, allowedQuestIDs, questIDsByTitle = {}, {}, {}
local selectedGUID
local pendingAfterCombat = false
local orderMatters = false  -- 후보 줄이 2개 이상이면 거리만 바뀌어도 결과가 달라진다
local collectLossy = false  -- 지난번 목록이 덜 읽힌 데이터로 만들어졌다

-- 단축키로만 누르는 버튼이라 화면에는 보이지 않게 둔다.
local button = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate")
button:SetSize(1, 1)
button:SetPoint("CENTER")
button:SetAlpha(0)
button:EnableMouse(false)
button:RegisterForClicks("AnyUp", "AnyDown")

---------------------------------------------------------------------------
-- 몹 이름 모으기
---------------------------------------------------------------------------
local function Trim(s)
	return (s:match("^%s*(.-)%s*$"))
end

local function ObjectiveTextKey(text)
	if type(text) ~= "string" then return nil end
	text = text:gsub("^%s*%d+%s*/%s*%d+%s*", "")
	text = text:gsub("%s*[:%(]?%s*%d+%s*/%s*%d+%s*%)?%s*$", "")
	text = text:gsub("^%s*%d+%.?%d*%%%s*", "")
	text = text:gsub("%s*[:%(]?%s*%d+%.?%d*%%%s*%)?%s*$", "")
	return Trim(text)
end

local function MobNameFromObjective(text)
	text = ObjectiveTextKey(text)
	if not text then return nil end
	for _, suffix in ipairs(KILL_SUFFIXES) do
		if #text > #suffix and text:sub(-#suffix) == suffix then
			local name = Trim(text:sub(1, -#suffix - 1))
			return name ~= "" and name or nil
		end
	end
end

local function SafeDistance(questID)
	local ok, distSq = pcall(C_QuestLog.GetDistanceSqToQuest, questID)
	distSq = ok and Clean(distSq) or nil
	return type(distSq) == "number" and distSq or math.huge
end

local function FocusedQuestID()
	if C_SuperTrack and type(C_SuperTrack.IsSuperTrackingUserWaypoint) == "function"
		and Clean(C_SuperTrack.IsSuperTrackingUserWaypoint()) then return nil end
	local id = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and Clean(C_SuperTrack.GetSuperTrackedQuestID())
	return type(id) == "number" and id > 0 and id or nil
end

local function IsWatched(questID)
	return C_QuestLog.GetQuestWatchType and C_QuestLog.GetQuestWatchType(questID) ~= nil or false
end

-- Clean과 같은데, 비밀값이라 버린 게 있으면 표시해 둔다.
local scanLossy = false
local function Keep(v)
	local c = Clean(v)
	if IsSecret(v) then scanLossy = true end
	return c
end

local function CollectTargets()
	local quests, open, byID, titleIDs, allowed = {}, {}, {}, {}, {}
	local focusID = db.watchedOnly and FocusedQuestID() or nil
	scanLossy = false
	for index = 1, C_QuestLog.GetNumQuestLogEntries() do
		local info = C_QuestLog.GetInfo(index)
		local questID = info and not info.isHeader and Clean(info.questID)
		if info == nil or (not info.isHeader and not (type(questID) == "number" and questID > 0)) then scanLossy = true end
		if type(questID) == "number" and questID > 0 and not Keep(C_QuestLog.IsComplete(questID)) then
			local title = Clean(info.title)
			if type(title) == "string" then
				open[title] = true
				titleIDs[title] = titleIDs[title] or {}
				titleIDs[title][questID] = true
			end
			byID[questID] = true
			if not db.watchedOnly or questID == focusID then
				local q = { questID = questID, title = title, dist = SafeDistance(questID), watched = IsWatched(questID), names = {} }
				local objectives = C_QuestLog.GetQuestObjectives(questID)
				if objectives == nil or #objectives == 0 then scanLossy = true end
				q.goalKeys, q.goalsByText = {}, {}
				local identity = {}
				for _, obj in ipairs(objectives or {}) do
					local text = ObjectiveTextKey(Clean(obj.text))
					local key = tostring(Clean(obj.type)) .. "\n" .. tostring(text)
					identity[#identity + 1] = key
					if not Clean(obj.finished) then q.goalKeys[key] = true end
					if text then
						q.goalsByText[text] = q.goalsByText[text] or {}
						q.goalsByText[text][key] = true
					end
				end
				table.sort(identity)
				-- Unmatched tooltip labels retain quest-level membership.
				q.unknownKey = "[unknown]\n" .. table.concat(identity, "\n")
				q.goalKeys[q.unknownKey] = true
				for _, obj in ipairs(objectives or {}) do
					if obj.type == "monster" and not Keep(obj.finished) then
						local name = MobNameFromObjective(Keep(obj.text))
						if name then q.names[#q.names + 1] = { name = name, title = title, questID = questID }
						else scanLossy = true end
					end
				end
				quests[#quests + 1] = q
				allowed[questID] = q
			end
		end
	end
	for name, ids in pairs(learned) do
		for id, keys in pairs(ids) do
			if not byID[id] then ids[id] = nil
			elseif allowed[id] then
				local q = allowed[id]
				for key in pairs(keys) do
					if not q.goalKeys[key] then keys[key] = nil end
				end
				if next(keys) == nil then ids[id] = nil
				else q.names[#q.names + 1] = { name = name, title = q.title, questID = id, learned = true } end
			end
		end
		if next(ids) == nil then learned[name] = nil end
	end
	table.sort(quests, function(a, b)
		if a.dist ~= b.dist then return a.dist < b.dist end
		if a.watched ~= b.watched then return a.watched end
		return a.questID < b.questID
	end)
	local list, seen, fromObjectives, entries = {}, {}, {}, 0
	for _, q in ipairs(quests) do
		for _, t in ipairs(q.names) do
			entries = entries + 1
			if not t.learned then
				fromObjectives[t.name] = fromObjectives[t.name] or {}
				fromObjectives[t.name][q.questID] = true
			end
			if not seen[t.name] and #list < MAX_NAMES then seen[t.name] = true list[#list + 1] = t end
		end
	end
	openQuestIDs, allowedQuestIDs, questIDsByTitle = byID, allowed, titleIDs
	return list, fromObjectives, open, entries >= 2, scanLossy
end

local function RaidMarkIndex()
	local index = tonumber(db.markIcon)
	if index and index >= 1 and index <= 8 and index % 1 == 0 then return index end
	return DEFAULT_MARK
end

-- 찾은 몹에만 붙도록 원래 대상으로 돌아가기 전에 둔다. "~"는 이미 징표가 있는 몹이면 그냥 지나간다
-- (블리자드 /tm 규칙: 같은 징표를 다시 눌러 떼지도, 파티장이 붙인 해골을 덮지도 않는다).
-- 공격대에서는 권한이 없으면 오류만 나서 빼 둔다.
local function MarkLine()
	if not db.markTarget or not db.shareTargetMark then return nil end
	local command = type(SLASH_TARGET_MARKER1) == "string" and SLASH_TARGET_MARKER1 or "/tm"
	return ("%s [exists,nogroup:raid] ~%d"):format(command, RaidMarkIndex())
end

-- 앞에서부터 찾다가 살아 있는 몹을 잡으면 멈춘다. 아무도 없으면 원래 대상으로 돌아간다.
local function BuildMacro(list)
	if #list == 0 then return nil end
	local lines = { "/cleartarget" }
	local mark = MarkLine()
	local found = "/run " .. SELECTED_CALLBACK .. "()"
	local tail = "/targetlasttarget [noexists]\n/cleartarget [dead]"
	local length = #lines[1] + #found + #tail + 3 + (mark and #mark + 1 or 0)
	for _, t in ipairs(list) do
		local add = "/targetexact [noexists] " .. t.name .. "\n/cleartarget [dead]"
		if length + #add + 1 > MAX_MACRO_LEN then break end
		lines[#lines + 1] = add
		length = length + #add + 1
	end
	lines[#lines + 1] = found
	if mark then lines[#lines + 1] = mark end
	lines[#lines + 1] = tail
	return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- 툴팁 퀘스트 정보
---------------------------------------------------------------------------
local LineType = Enum and Enum.TooltipDataLineType
local LINE_OBJECTIVE = LineType and LineType.QuestObjective
local LINE_TITLE = LineType and LineType.QuestTitle

local function ObjectiveDone(line)
	-- Progress text takes priority when tooltip completion flags disagree.
	local text = Clean(line.leftText) or ""
	local have, need = text:match("(%d+)%s*/%s*(%d+)")
	if have then return tonumber(have) >= tonumber(need) end
	local pct = text:match("(%d+%.?%d*)%%")
	if pct then return tonumber(pct) >= 100 end
	local completed = Clean(line.completed)
	if completed ~= nil then return completed end
	return false
end

-- true/false: 아직 안 끝난 퀘스트의 대상인지, nil: 툴팁으로는 알 수 없음. 둘째 값은 퀘스트 제목.
local function QuestFromTooltip(unit)
	if not (C_TooltipInfo and C_TooltipInfo.GetUnit and LINE_OBJECTIVE) then return nil end
	local ok, data = pcall(C_TooltipInfo.GetUnit, unit)
	if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
	local ids, title, explicitID, sawObjective, hasIncomplete = {}, nil, nil, false, false
	for _, line in ipairs(data.lines) do
		local lineType = Clean(line.type)
		if lineType == LINE_TITLE then
			title, explicitID = Clean(line.leftText), Clean(line.questID)
		elseif lineType == LINE_OBJECTIVE then
			sawObjective = true
			if not ObjectiveDone(line) then hasIncomplete = true end
			local id = Clean(line.questID) or explicitID
			if type(id) ~= "number" or id <= 0 then
				id = nil
				local matches = type(title) == "string" and questIDsByTitle[title]
				if matches then
					for candidate in pairs(matches) do
						if id then id = nil break end
						id = candidate
					end
				end
			end
			local quest = id and allowedQuestIDs[id]
			if quest and quest.unknownKey and not ObjectiveDone(line) then
				local text = Clean(line.leftText)
				if type(text) == "string" then text = text:gsub("^%s*%-%s+", "") end
				text = ObjectiveTextKey(text)
				local keys = text and quest.goalsByText[text]
				if not keys then keys = { [quest.unknownKey] = true } end
				for key in pairs(keys) do
					if quest.goalKeys[key] then
						ids[id] = ids[id] or {}
						ids[id][key] = true
					end
				end
			end
		end
	end
	if not sawObjective then return nil end
	return next(ids) ~= nil or (not db.watchedOnly and hasIncomplete), ids
end

local RequestRefresh

local function CheckUnit(unit)
	if not UnitExists(unit) or Clean(UnitIsPlayer(unit)) or Clean(UnitIsDead(unit)) then return false end
	local name = Clean((UnitName(unit)))
	local isQuest, ids = QuestFromTooltip(unit)
	if isQuest == nil then
		local objectives = name and objectiveNames[name]
		if type(objectives) ~= "table" then return false end
		for id in pairs(objectives) do if allowedQuestIDs[id] then return true end end
		return false
	end
	if type(name) == "string" then
		local changed = false
		local known = learned[name]
		if known then
			for id in pairs(known) do
				if allowedQuestIDs[id] and not ids[id] then known[id], changed = nil, true end
			end
			if next(known) == nil then learned[name] = nil end
		end
		for id, keys in pairs(ids) do
			if not (objectiveNames[name] and objectiveNames[name][id]) then
				learned[name] = learned[name] or {}
				local knownKeys = learned[name][id]
				if not knownKeys then knownKeys = {} learned[name][id] = knownKeys end
				for key in pairs(knownKeys) do
					if not keys[key] then knownKeys[key], changed = nil, true end
				end
				for key in pairs(keys) do
					if not knownKeys[key] then knownKeys[key], changed = true, true end
				end
			end
		end
		if changed then RequestRefresh() end
	end
	return isQuest
end

---------------------------------------------------------------------------
-- 이름표 표시
---------------------------------------------------------------------------
local markers = {}
local privateMarkers, plateByUnit = {}, {}

local function CreateMarker(plate)
	local m = CreateFrame("Frame", nil, plate)
	m:SetPoint("RIGHT", plate, "LEFT", 0, 0)
	local tex = m:CreateTexture(nil, "OVERLAY")
	tex:SetAllPoints()
	if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(MARKER_ATLAS) then
		tex:SetAtlas(MARKER_ATLAS)
	else
		tex:SetTexture(MARKER_TEXTURE)
	end
	markers[plate] = m
	return m
end

local function PlateFor(unit)
	local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
	if not plate or (plate.IsForbidden and plate:IsForbidden()) then return nil end
	return plate
end

local function HidePlate(plate)
	if markers[plate] then markers[plate]:Hide() end
	if privateMarkers[plate] then privateMarkers[plate]:Hide() end
end

local function UpdatePrivateMarker(unit, plate, isQuest)
	local marker = privateMarkers[plate]
	local guid = Clean(UnitGUID(unit))
	local show = db.enabled and db.markTarget and not db.shareTargetMark
		and isQuest and selectedGUID and guid == selectedGUID
	if show then
		if not marker then
			marker = CreateFrame("Frame", nil, plate)
			marker:SetPoint("BOTTOM", plate, "TOP", 0, 8)
			marker.texture = marker:CreateTexture(nil, "OVERLAY")
			marker.texture:SetAllPoints()
			privateMarkers[plate] = marker
		end
		marker:SetSize(db.markerSize, db.markerSize)
		marker.texture:SetTexture(RAID_MARK_ICON:format(RaidMarkIndex()))
		marker:Show()
	elseif marker then marker:Hide() end
end

local function UpdatePlate(unit)
	local plate = PlateFor(unit)
	if not plate then return end
	local old = plateByUnit[unit]
	if old and old ~= plate then HidePlate(old) end
	plateByUnit[unit] = plate
	local isQuest = db.enabled and CheckUnit(unit)
	local marker = markers[plate]
	if isQuest and db.showMarker then
		marker = marker or CreateMarker(plate)
		marker:SetSize(db.markerSize, db.markerSize)
		marker:Show()
	elseif marker then marker:Hide() end
	UpdatePrivateMarker(unit, plate, isQuest)
end

local function UpdateAllPlates()
	if C_NamePlate and type(C_NamePlate.GetNamePlates) == "function" then
		for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
			if not (plate.IsForbidden and plate:IsForbidden()) and type(plate.GetUnit) == "function" then
				local unit = Clean(plate:GetUnit())
				if type(unit) == "string" and UnitExists(unit) then plateByUnit[unit] = plate end
			end
		end
	else
		for i = 1, 40 do
			local unit = "nameplate" .. i
			if UnitExists(unit) then
				local plate = PlateFor(unit)
				if plate then plateByUnit[unit] = plate end
			end
		end
	end
	for unit, plate in pairs(plateByUnit) do
		if UnitExists(unit) then UpdatePlate(unit)
		else HidePlate(plate) plateByUnit[unit] = nil end
	end
end

local function SetSelectedGUID(guid)
	if selectedGUID ~= guid then selectedGUID = guid ns:Fire("QUEST_MOB_TRACKED_CHANGED") end
	UpdateAllPlates()
end

-- Capture before the macro restores the previous target.
_G[SELECTED_CALLBACK] = function()
	local guid
	if db and db.enabled and CheckUnit("target") then guid = Clean(UnitGUID("target")) end
	SetSelectedGUID(type(guid) == "string" and guid or nil)
end

function ns.GetTrackedQuestMobGUID()
	return db and db.enabled and selectedGUID or nil
end

---------------------------------------------------------------------------
-- 갱신
---------------------------------------------------------------------------
local function ApplyMacro()
	if InCombatLockdown() then
		pendingAfterCombat = true
		return
	end
	pendingAfterCombat = false
	local macro = db.enabled and BuildMacro(targets) or nil
	if button:GetAttribute("*macrotext1") ~= macro then
		button:SetAttribute("*type1", macro and "macro" or nil)
		button:SetAttribute("*macrotext1", macro)
	end
end

local function TargetsSignature()
	local names = {}
	for _, t in ipairs(targets) do names[#names + 1] = t.name end
	return table.concat(names, "\n")
end

-- 대상 키 목록만 다시 정한다. (이동 중 우선순위 갱신용, 가볍다)
local function RefreshTargets()
	local before = TargetsSignature()
	if db.enabled then
		targets, objectiveNames, openTitles, orderMatters, collectLossy = CollectTargets()
	else
		targets, objectiveNames, openTitles, orderMatters, collectLossy = {}, {}, {}, false, false
	end
	ApplyMacro()
	if TargetsSignature() ~= before then ns:Fire("REFRESH_UI") end
end

local function Refresh()
	if not db then return end
	RefreshTargets()
	if selectedGUID and not CheckUnit("target") then SetSelectedGUID(nil) end
	UpdateAllPlates()
end

local refreshQueued = false
-- 꺼져 있으면 할 일이 없다. 켜고 끌 때는 ApplySettings가 바로 Refresh한다.
RequestRefresh = function()
	if refreshQueued or not db or not db.enabled then return end
	refreshQueued = true
	C_Timer.After(0.3, function()
		refreshQueued = false
		Refresh()
	end)
end

button:SetScript("PostClick", function(_, _, down)
	if down then return end
	if db.enabled and #targets == 0 then
		if db.watchedOnly and not FocusedQuestID() then
			Print("목표 창에서 선택한 퀘스트가 없어요.")
		elseif db.watchedOnly then
			Print("선택한 퀘스트에 남은 몹이 없어요.")
		else
			Print("지금 대상으로 잡을 퀘스트 몹이 없어요.")
		end
	end
end)

for _, event in ipairs({
	"PLAYER_ENTERING_WORLD", "QUEST_LOG_UPDATE", "QUEST_WATCH_LIST_CHANGED",
	"QUEST_ACCEPTED", "QUEST_REMOVED", "ZONE_CHANGED_NEW_AREA", "SUPER_TRACKING_CHANGED",
}) do
	ns:RegisterEvent(event, function(ev)
		if ev == "SUPER_TRACKING_CHANGED" and db then Refresh() else RequestRefresh() end
	end)
end

ns:RegisterUnitEvent("UNIT_QUEST_LOG_CHANGED", function(_, unit)
	if unit == "player" then RequestRefresh() end
end, "player")

ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit)
	if db then UpdatePlate(unit) end
end)

ns:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, unit)
	local plate = plateByUnit[unit] or PlateFor(unit)
	if plate then HidePlate(plate) end
	plateByUnit[unit] = nil
end)

-- 이름표를 꺼 둔 경우에도 마우스를 올리거나 대상으로 잡은 몹에서 이름을 배운다.
ns:RegisterEvent("UPDATE_MOUSEOVER_UNIT", function()
	if db and db.enabled then CheckUnit("mouseover") end
end)
ns:RegisterEvent("PLAYER_TARGET_CHANGED", function()
	if db and db.enabled then
		CheckUnit("target")
		local guid = Clean(UnitGUID("target"))
		if selectedGUID and guid ~= selectedGUID then SetSelectedGUID(nil) end
	end
end)

ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
	if pendingAfterCombat then ApplyMacro() end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
end

function M:OnLogin()
	Refresh()
	-- 이동하면 가까운 퀘스트가 바뀌니 다시 정하되, 후보 순서·덜 읽힌 데이터·미룬 매크로가 있을 때만.
	C_Timer.NewTicker(3, function()
		if db.enabled and not InCombatLockdown() and (orderMatters or collectLossy or pendingAfterCombat) then
			RefreshTargets()
		end
	end)
end

function M:ApplySettings()
	if not db.enabled then wipe(learned) SetSelectedGUID(nil) end
	Refresh()
end

local function PrintList()
	if #targets == 0 then
		Print("지금 대상 키로 잡을 퀘스트 몹이 없어요.")
		return
	end
	Print(("대상 키로 잡을 몹 %d마리 (위쪽이 우선):"):format(#targets))
	for i, t in ipairs(targets) do
		local how = t.learned and "툴팁에서 확인" or "퀘스트 목표"
		print(("  %d. %s |cff999999- %s (%s)|r"):format(i, t.name, t.title or "?", how))
	end
end

local function RaidMarkOptions()
	local list = {}
	for _, index in ipairs(RAID_MARKS) do
		local name = _G["RAID_TARGET_" .. index]
		if type(name) ~= "string" then name = "징표 " .. index end
		list[#list + 1] = { value = index, text = ("|T%s:14|t %s"):format(RAID_MARK_ICON:format(index), name) }
	end
	return list
end

local function TargetsText()
	if not db.enabled then return "대상 키에 들어간 몹:  |cff808080기능 꺼짐|r" end
	if #targets == 0 then return "대상 키에 들어간 몹:  |cff808080없음|r" end
	local list = {}
	for _, t in ipairs(targets) do list[#list + 1] = t.name end
	return "대상 키에 들어간 몹:  |cffffffff" .. table.concat(list, ", ") .. "|r"
end

function M:BuildOptions(b)
	b:Text("단축키를 누르면 아직 끝내지 않은 퀘스트의 몹을 대상으로 잡습니다. 가까운 퀘스트의 몹을 먼저 찾고, "
		.. "시체는 대상에서 제외하며, 적 이름표에는 퀘스트 몹 표시를 띄웁니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:KeyBind{ command = TARGET_BINDING, label = "퀘스트 몹 대상 잡기", depends = "enabled" }
	b:Check{
		key = "watchedOnly", label = "선택한 퀘스트의 몹만", depends = "enabled", indent = 20,
		tooltip = "목표 창에서 노란 아이콘으로 선택한 퀘스트의 몹만 잡습니다. 선택이 없으면 다른 퀘스트 몹을 잡지 않습니다.",
	}
	b:Check{
		key = "showMarker", label = "적 이름표에 퀘스트 몹 표시", depends = "enabled", indent = 20,
		tooltip = "퀘스트 몹의 이름표 왼쪽에 느낌표를 띄웁니다. 이름표가 켜져 있어야 보입니다(기본 단축키 V).",
	}
	b:Slider{ key = "markerSize", label = "표시 크기", min = 12, max = 40, step = 1, depends = { "enabled", "showMarker" } }
	b:Check{
		key = "markTarget", label = "찾은 몹에 징표 붙이기", depends = "enabled", indent = 20,
		tooltip = "대상 키로 찾은 몹에 고른 징표를 표시합니다. 기본은 내 화면의 적 이름표에만 보입니다.\n"
			.. "못 찾아서 원래 대상으로 돌아가면 붙이지 않습니다. 공유할 때는 이미 징표가 붙은 몹을 그대로 두며, 공격대에서는 새 공용 징표를 붙이지 않습니다.",
	}
	b:Check{
		key = "shareTargetMark", label = "파티원과 징표 공유", depends = { "enabled", "markTarget" }, indent = 20,
		tooltip = "켜면 파티원에게도 보이는 게임 징표를 붙입니다. 끄면 새 공용 징표를 붙이지 않습니다. 이전 게임 징표는 자동으로 지우지 않습니다.",
	}
	b:Dropdown{
		key = "markIcon", label = "붙일 징표", options = RaidMarkOptions, width = 160, indent = 20,
		depends = { "enabled", "markTarget" },
	}
	b:Buttons{
		{
			text = "몹 목록 보기", onClick = PrintList,
			disabled = function() return not db.enabled end,
			tooltip = "대상 키에 들어간 몹 이름을 채팅창에 출력합니다.",
		},
	}
	b:Text("- 몹 이름은 퀘스트 목표 문구(\"~ 처치\")에서 뽑고, 아이템을 떨구는 몹은 이름표에 뜨거나 "
		.. "마우스를 올렸을 때 툴팁의 퀘스트 정보로 알아냅니다.\n"
		.. "- 전투 중에는 목록이 바뀌어도 대상 키에 바로 반영되지 않고 전투가 끝난 뒤 반영됩니다.",
		{ color = { 0.7, 0.7, 0.7 } })
	b:Text(TargetsText)
end
