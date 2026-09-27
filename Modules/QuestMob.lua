-- 퀘스트 몹: 아직 끝내지 않은 퀘스트의 몹을 단축키로 대상 지정하고, 적 이름표에 표시한다.
--
-- 대상 지정은 보호된 동작이라 자동으로는 못 한다. 보안 버튼(EzyWOWFQuestMobButton)에
-- "/targetexact 몹 이름" 매크로를 넣고 키로 누른다. 매크로는 전투 밖에서만 바꿀 수 있다.
-- 몹 이름은 두 군데서 모은다.
--   1) 퀘스트 목표 문구: "5/6 힘센 바위턱트로그 처치" -> "힘센 바위턱트로그"
--   2) 이름표·마우스오버·대상의 툴팁 퀘스트 정보 (아이템을 떨구는 몹도 잡힌다)

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local BUTTON_NAME    = "EzyWOWFQuestMobButton"
local TARGET_BINDING = "CLICK " .. BUTTON_NAME .. ":LeftButton"
local MAX_NAMES      = 8      -- 매크로 길이 제한(1023바이트) 안에 들어가도록
local MAX_MACRO_LEN  = 1000
local KILL_SUFFIXES  = { " 처치", " 처치함", " slain", " killed" }
local MARKER_ATLAS   = "QuestNormal"
local MARKER_TEXTURE = "Interface\\GossipFrame\\AvailableQuestIcon"

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
	},
})

local db
local targets = {}         -- 대상 키에 들어간 몹 (우선순위 순) { name =, title =, learned = }
local objectiveNames = {}  -- [이름] = true, 목표 문구에서 뽑은 이름
local learned = {}         -- [이름] = 퀘스트 제목, 툴팁에서 알아낸 몹
local openTitles = {}      -- [제목] = true, 아직 안 끝난 퀘스트
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

-- "5/6 힘센 바위턱트로그 처치", "힘센 바위턱트로그 처치: 5/6" -> "힘센 바위턱트로그"
local function MobNameFromObjective(text)
	if type(text) ~= "string" then return nil end
	text = text:gsub("^%s*%d+%s*/%s*%d+%s*", "")
	text = text:gsub("%s*[:%(]?%s*%d+%s*/%s*%d+%s*%)?%s*$", "")
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

local function IsWatched(questID)
	return C_QuestLog.GetQuestWatchType and C_QuestLog.GetQuestWatchType(questID) ~= nil or false
end

-- Clean과 같은데, 비밀값이라 버린 게 있으면 표시해 둔다.
local scanLossy = false
local function Keep(v)
	local c = Clean(v)
	if v ~= nil and c == nil then scanLossy = true end
	return c
end

local function CollectTargets()
	local quests, byTitle, open = {}, {}, {}
	scanLossy = false
	for index = 1, C_QuestLog.GetNumQuestLogEntries() do
		local info = C_QuestLog.GetInfo(index)
		local questID = info and not info.isHeader and info.questID
		-- 아직 덜 읽힌 줄은 이벤트 없이 채워질 수 있어서 틱이 다시 보게 한다.
		if info == nil or (not info.isHeader and not (questID and questID > 0)) then scanLossy = true end
		if questID and questID > 0 and not Keep(C_QuestLog.IsComplete(questID)) then
			if info.title then open[info.title] = true end
			local watched = IsWatched(questID)
			if not db.watchedOnly or watched then
				local q = { questID = questID, title = info.title, dist = SafeDistance(questID), watched = watched, names = {} }
				local objectives = C_QuestLog.GetQuestObjectives(questID)
				if objectives == nil or #objectives == 0 then scanLossy = true end   -- 빈 목록도 아직 안 읽힌 것일 수 있다
				for _, obj in ipairs(objectives or {}) do
					if obj.type == "monster" and not Keep(obj.finished) then
						local name = MobNameFromObjective(Keep(obj.text))
						if name then
							q.names[#q.names + 1] = { name = name, title = info.title }
						else
							scanLossy = true   -- 이름이 아직 안 온 " 처치: 0/8" 같은 문구일 수 있어서 다시 본다
						end
					end
				end
				quests[#quests + 1] = q
				if info.title then byTitle[info.title] = q end
			end
		end
	end

	-- 툴팁에서 알아낸 몹: 그 퀘스트가 끝났거나 목록에서 빠졌으면 잊는다.
	for name, title in pairs(learned) do
		if not open[title] then
			learned[name] = nil
		elseif byTitle[title] then
			local list = byTitle[title].names
			list[#list + 1] = { name = name, title = title, learned = true }
		end
	end

	table.sort(quests, function(a, b)
		if a.dist ~= b.dist then return a.dist < b.dist end
		if a.watched ~= b.watched then return a.watched end
		return a.questID < b.questID
	end)

	-- 중복 제거 전 줄 수를 센다. 같은 몹이 두 퀘스트에 있으면 거리에 따라 제목이 바뀐다.
	local list, seen, fromObjectives, entries = {}, {}, {}, 0
	for _, q in ipairs(quests) do
		for _, t in ipairs(q.names) do
			entries = entries + 1
			if not t.learned then fromObjectives[t.name] = true end
			if not seen[t.name] and #list < MAX_NAMES then
				seen[t.name] = true
				list[#list + 1] = t
			end
		end
	end
	return list, fromObjectives, open, entries >= 2, scanLossy
end

-- 앞에서부터 찾다가 살아 있는 몹을 잡으면 멈춘다. 아무도 없으면 원래 대상으로 돌아간다.
local function BuildMacro(list)
	if #list == 0 then return nil end
	local lines = { "/cleartarget" }
	local tail = "/targetlasttarget [noexists]"
	local length = #lines[1] + #tail + 2
	for _, t in ipairs(list) do
		local add = "/targetexact [noexists] " .. t.name .. "\n/cleartarget [dead]"
		if length + #add + 1 > MAX_MACRO_LEN then break end
		lines[#lines + 1] = add
		length = length + #add + 1
	end
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
	local completed = Clean(line.completed)
	if completed ~= nil then return completed end
	local text = Clean(line.leftText) or ""
	local have, need = text:match("(%d+)%s*/%s*(%d+)")
	if have then return tonumber(have) >= tonumber(need) end
	local pct = text:match("(%d+)%%")
	if pct then return tonumber(pct) >= 100 end
	return false
end

-- true/false: 아직 안 끝난 퀘스트의 대상인지, nil: 툴팁으로는 알 수 없음. 둘째 값은 퀘스트 제목.
local function QuestFromTooltip(unit)
	if not (C_TooltipInfo and C_TooltipInfo.GetUnit and LINE_OBJECTIVE) then return nil end
	local ok, data = pcall(C_TooltipInfo.GetUnit, unit)
	if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
	local title
	for _, line in ipairs(data.lines) do
		local lineType = Clean(line.type)
		if lineType == LINE_TITLE then
			title = Clean(line.leftText)
		elseif lineType == LINE_OBJECTIVE and not ObjectiveDone(line) then
			return true, title
		end
	end
	return false
end

local RequestRefresh   -- 아래에서 정의

-- 이 유닛이 퀘스트 몹인지 보고, 툴팁으로 확인된 이름은 대상 키용으로 기억한다.
local function CheckUnit(unit)
	if not UnitExists(unit) or Clean(UnitIsPlayer(unit)) then return false end
	local name = Clean((UnitName(unit)))
	local isQuest, title = QuestFromTooltip(unit)
	if isQuest == nil then
		return name ~= nil and objectiveNames[name] == true
	end
	-- 지금 열려 있는 퀘스트 제목과 맞을 때만 배운다. 제목이 안 맞는 것까지 배우면
	-- 목록 정리 때 잊었다가 이름표 확인 때 다시 배우기를 끝없이 되풀이한다.
	if name and not objectiveNames[name] then
		local want = (isQuest and title and openTitles[title]) and title or nil
		if learned[name] ~= want then
			learned[name] = want
			RequestRefresh()
		end
	end
	return isQuest
end

---------------------------------------------------------------------------
-- 이름표 표시
---------------------------------------------------------------------------
local markers = {}   -- [이름표 프레임] = 표시 프레임

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

local function UpdatePlate(unit)
	local plate = PlateFor(unit)
	if not plate then return end
	local show = db.enabled and CheckUnit(unit) and db.showMarker
	local m = markers[plate]
	if show then
		m = m or CreateMarker(plate)
		m:SetSize(db.markerSize, db.markerSize)
		m:Show()
	elseif m then
		m:Hide()
	end
end

local function UpdateAllPlates()
	for i = 1, 40 do
		local unit = "nameplate" .. i
		if UnitExists(unit) then UpdatePlate(unit) end
	end
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
	if db.enabled and #targets == 0 then Print("지금 대상으로 잡을 퀘스트 몹이 없어요.") end
end)

for _, event in ipairs({
	"PLAYER_ENTERING_WORLD", "QUEST_LOG_UPDATE", "QUEST_WATCH_LIST_CHANGED",
	"QUEST_ACCEPTED", "QUEST_REMOVED", "ZONE_CHANGED_NEW_AREA",
}) do
	ns:RegisterEvent(event, function() RequestRefresh() end)
end

ns:RegisterUnitEvent("UNIT_QUEST_LOG_CHANGED", function(_, unit)
	if unit == "player" then RequestRefresh() end
end, "player")

ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit)
	if db then UpdatePlate(unit) end
end)

ns:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, unit)
	local plate = PlateFor(unit)
	if plate and markers[plate] then markers[plate]:Hide() end
end)

-- 이름표를 꺼 둔 경우에도 마우스를 올리거나 대상으로 잡은 몹에서 이름을 배운다.
ns:RegisterEvent("UPDATE_MOUSEOVER_UNIT", function()
	if db and db.enabled then CheckUnit("mouseover") end
end)
ns:RegisterEvent("PLAYER_TARGET_CHANGED", function()
	if db and db.enabled then CheckUnit("target") end
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
	if not db.enabled then wipe(learned) end
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

local function TargetsText()
	if not db.enabled then return "대상 키에 들어간 몹:  |cff808080기능 꺼짐|r" end
	if #targets == 0 then return "대상 키에 들어간 몹:  |cff808080없음|r" end
	local list = {}
	for _, t in ipairs(targets) do list[#list + 1] = t.name end
	return "대상 키에 들어간 몹:  |cffffffff" .. table.concat(list, ", ") .. "|r"
end

function M:BuildOptions(b)
	b:Text("단축키를 누르면 아직 끝내지 않은 퀘스트의 몹을 대상으로 잡습니다. 가까운 퀘스트의 몹을 먼저 찾고, "
		.. "근처에 없으면 원래 대상으로 돌아갑니다. 적 이름표에는 퀘스트 몹 표시를 띄웁니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:KeyBind{ command = TARGET_BINDING, label = "퀘스트 몹 대상 잡기", depends = "enabled" }
	b:Check{
		key = "watchedOnly", label = "추적 중인 퀘스트의 몹만", depends = "enabled", indent = 20,
		tooltip = "퀘스트 추적기에 표시된 퀘스트의 몹만 대상으로 잡습니다.",
	}
	b:Check{
		key = "showMarker", label = "적 이름표에 퀘스트 몹 표시", depends = "enabled", indent = 20,
		tooltip = "퀘스트 몹의 이름표 왼쪽에 느낌표를 띄웁니다. 이름표가 켜져 있어야 보입니다(기본 단축키 V).",
	}
	b:Slider{ key = "markerSize", label = "표시 크기", min = 12, max = 40, step = 1, depends = { "enabled", "showMarker" } }
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
