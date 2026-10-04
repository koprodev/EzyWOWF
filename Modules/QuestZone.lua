-- 지역 퀘스트만 표시: 퀘스트 목표 창(추적기)에 지금 있는 지역의 퀘스트만 남긴다.
--
-- 추적기 함수(ShouldDisplayQuest 등)를 바꾸면 그 갱신 전체가 오염돼서, 추적기의 퀘스트 아이템 버튼
-- (UseQuestLogSpecialItem, 보호 함수)이 막힌다. 그래서 블리자드 추적 목록 자체를 넣고 뺀다(C_QuestLog.Add/RemoveQuestWatch).
-- 같은 이유로 블리자드 표·프레임에 값을 쓰거나 추적기·QuestMapFrame 함수를 직접 부르지 않는다. 읽기만 한다.
--   - 지역이 바뀌면 다른 지역 퀘스트를 추적에서 빼고 캐릭터별로 적어 둔다. 그 지역에 다시 오면 적어 둔 것만 되돌린다.
--   - 같은 지역에 있는 동안 직접 추적하거나 새로 받은 퀘스트는 놔둔다. 다음에 지역을 옮길 때 다시 거른다.
--   - 사용자가 직접 추적 해제한 퀘스트는 적힌 적이 없으니 되돌리지 않는다.
--   - 끄면 적어 둔 퀘스트를 모두 되돌린다.
--   - 추적 목록이 바뀌면 추적기가 다시 그려진다(QUEST_WATCH_LIST_CHANGED는 동기 이벤트). 전투 중엔 미뤘다가 끝나면 한다.
-- 이 지역 퀘스트 = 퀘스트 목록에서 머리글(지역 이름)이 지금 지역 이름과 같은 퀘스트.
--   선택: 이 지역 지도에 목표가 찍힌 퀘스트(GetQuestsOnMap), 집중 추적 퀘스트, 직업·전문 기술 머리글 퀘스트도 남긴다.
-- quest.isOnMap은 SetMapForQuestPOIs 지도 기준(세계 지도가 열려 있으면 그 지도, 아니면 마지막 목록 갱신 때 내 지도)이라
--   지도를 딴 데 띄워 두거나 막 지역을 옮기면 어긋난다. 그래서 쓰지 않고 지도 번호를 직접 넘긴다.
-- 목표 창 제목 줄(MinimizeButton 왼쪽, 블리자드가 안 쓰는 FilterButton 자리)에 켜고 끄는 버튼을 두고,
-- '모든 목표' 글자 옆에는 이 지역 퀘스트 수(그중 완료) / 전체 퀘스트 수(그중 완료)를 보인다.

local _, ns = ...

local M = ns:NewModule("QuestZone", {
	title = "지역 퀘스트만 표시",
	category = "quest",
	icon = "Interface\\Icons\\INV_Scroll_02",
	order = 18,
	defaults = {
		enabled = true,
		onMap = true,
		keepFocused = true,
		keepClassProf = true,
		showButton = true,
		showCount = true,
		told = false,        -- 처음 퀘스트를 뺄 때 한 번만 알린다
	},
})

local Clean = ns.Clean
local ZONE_TYPE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3

local db
local rec            -- 이 캐릭터 기록: { zone = 마지막으로 거른 지역, hidden = { [questID] = true } 우리가 뺀 퀘스트 }
local queued         -- nil | "check"(지역이 바뀌었으면 거르고 아니면 되돌리기만) | "force"(사용자가 시킨 다시 거르기)
local timerOn = false
local retries = 0    -- 목록을 덜 읽은 채 끝난 지역 거르기를 다시 해 본 횟수
local fresh, freshZone = {}, nil   -- 이 지역에 와서 받은 퀘스트. 미뤄 둔 지역 거르기가 받자마자 빼지 않게 한다
local lastStatus
local button         -- 목표 창 제목 줄 버튼 (아래에서 만든다)
local countDirty = true   -- 제목 줄 퀘스트 수를 다시 셀 때
local UpdateHeader

-- 띄어쓰기만 다른 이름("붉은마루산맥")도 같은 곳으로 본다
local function Norm(s)
	s = Clean(s)
	if type(s) ~= "string" then return nil end
	s = s:gsub("%s+", "")
	return s ~= "" and s or nil
end

local function CurrentZone()
	return Norm(GetRealZoneText and GetRealZoneText())
end

local function CountHidden()
	local n = 0
	if rec then for _ in pairs(rec.hidden) do n = n + 1 end end
	return n
end

-- 지금 있는 곳의 이름들과 지도 번호들. 굴·던전 지도면 바깥 지역 지도까지 올라간다(대륙은 너무 넓어 뺀다).
local function ZoneNames()
	local names, maps = {}, {}
	local function Add(s)
		s = Norm(s)
		if s then names[s] = true end
	end
	Add(GetRealZoneText and GetRealZoneText())
	Add(GetZoneText and GetZoneText())
	Add(GetSubZoneText and GetSubZoneText())
	local mapID = C_Map and C_Map.GetBestMapForUnit and Clean(C_Map.GetBestMapForUnit("player"))
	for _ = 1, 6 do
		local info = mapID and C_Map.GetMapInfo(mapID)
		local mapType = info and Clean(info.mapType)
		if not (info and mapType and mapType >= ZONE_TYPE) then break end
		maps[#maps + 1] = mapID
		Add(info.name)
		if mapType == ZONE_TYPE then break end
		mapID = Clean(info.parentMapID)
	end
	return names, maps
end

-- 직업·전문 기술 머리글 이름표. 직업 머리글은 직업 이름 그대로지만, 전문 기술 머리글은 퀘스트 분류(QuestSort) 이름이라
-- 어떤 API도 그 글자를 주지 않는 게 둘 있다(koKR 101 "낚시꾼", 121 "대장장이"; 1.60.1.70205 게임 데이터).
local PROF_GLOBALS = { "ALCHEMY", "BLACKSMITHING", "ENCHANTING", "ENGINEERING", "HERBALISM", "LEATHERWORKING",
	"MINING", "SKINNING", "TAILORING", "COOKING", "FIRST_AID", "FISHING" }
local PROF_SPELLS = { 2259, 2018, 7411, 4036, 2366, 2108, 2575, 8613, 3908, 2550, 3273, 7620 }   -- 위 기술들의 수습 주문
local SORT_ALIASES = { koKR = { "낚시꾼", "대장장이" } }

local categories     -- 처음 쓸 때 한 번 만든다
local function Categories()
	if categories then return categories end
	local set = {}
	local function Add(s)
		s = Norm(s)
		if s then set[s] = true end
	end
	for _, list in ipairs({ LOCALIZED_CLASS_NAMES_MALE, LOCALIZED_CLASS_NAMES_FEMALE }) do
		if type(list) == "table" then
			for _, name in pairs(list) do Add(name) end
		end
	end
	if C_CreatureInfo and C_CreatureInfo.GetClassInfo then
		for id = 1, 13 do   -- 포에버 직업 번호는 1~11 사이에 띄엄띄엄 있어서 개수만큼만 돌면 드루이드(11)가 빠진다
			local info = C_CreatureInfo.GetClassInfo(id)
			if type(info) == "table" then Add(info.className) end
		end
	end
	for _, key in ipairs(PROF_GLOBALS) do Add(_G[key]) end
	if C_Spell and C_Spell.GetSpellName then
		for _, id in ipairs(PROF_SPELLS) do Add(C_Spell.GetSpellName(id)) end
	end
	for _, name in ipairs(SORT_ALIASES[GetLocale and GetLocale() or ""] or {}) do Add(name) end
	categories = set
	return set
end

local function QuestsOnMap(maps)
	local set = {}
	if not C_QuestLog.GetQuestsOnMap then return set end
	for _, mapID in ipairs(maps) do
		for _, poi in ipairs(C_QuestLog.GetQuestsOnMap(mapID) or {}) do
			local id = Clean(poi.questID)
			if id then set[id] = true end
		end
	end
	return set
end

local function FocusedQuestID()
	local id = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and Clean(C_SuperTrack.GetSuperTrackedQuestID())
	if type(id) == "number" and id > 0 then return id end
end

local function IsWatched(questID)
	return C_QuestLog.GetQuestWatchType(questID) ~= nil
end

-- 추적 칸이 꽉 차면(최대 25) 실패한다. 그때는 적어 둔 채로 두고 다음에 다시 넣어 본다
local function Watch(questID)
	if IsWatched(questID) or C_QuestLog.AddQuestWatch(questID) or IsWatched(questID) then
		rec.hidden[questID] = nil
	end
end

-- 신규 플레이어 체험 중에는 블리자드도 추적 해제를 막는다(QuestUtil.CanRemoveQuestWatch)
local function CanUntrack()
	return not (C_PlayerInfo and C_PlayerInfo.IsPlayerNPERestricted and C_PlayerInfo.IsPlayerNPERestricted())
end

-- 퀘스트 목록을 훑어 퀘스트마다 fn(questID, 머리글, 이 지역 퀘스트인지)을 부른다. 이 지역 = 머리글이 지금 이름과 같거나
-- (옵션) 이 지역 지도에 목표가 찍힘. 머리글 줄을 못 읽었으면 다음 머리글까지 머리글이 false다.
-- 목록이 아직 비어 있으면 nil(접속 직후), 덜 읽힌 줄이 있었으면 false, 다 읽었으면 true
local function Scan(fn)
	local num = C_QuestLog.GetNumQuestLogEntries() or 0
	if num == 0 then return nil end
	local names, maps = ZoneNames()
	local onMap = db.onMap and QuestsOnMap(maps) or {}
	local whole, header = true, nil
	for i = 1, num do
		local info = C_QuestLog.GetInfo(i)
		local id = info and not info.isHeader and Clean(info.questID)
		if not info then
			whole, header = false, false   -- 덜 읽힌 줄. 어느 머리글 밑인지 모르니 다음 머리글까지는 판단하지 않는다
		elseif info.isHeader then
			header = Norm(info.title)
		elseif not (id and id > 0) then
			whole = false
		elseif not (info.isHidden or info.isTask or info.isBounty) then
			fn(id, header, header ~= false and ((header and names[header]) or onMap[id]) and true or false)
		end
	end
	return whole
end

-- removeOthers가 참이면 다른 지역 퀘스트를 뺀다. 아니면 이 지역 퀘스트 중 우리가 뺀 것만 되돌린다.
-- spare에 든 퀘스트(이 지역에서 막 받은 것)는 빼지 않는다.
-- 목록이 아직 비어 있으면 nil(접속 직후), 아니면 이번에 뺀 개수와 목록을 다 읽었는지
local function Filter(removeOthers, spare)
	local focus = db.keepFocused and FocusedQuestID()
	local kept = db.keepClassProf and Categories() or {}
	local seen, back, out = {}, {}, {}
	local whole = Scan(function(id, header, zoneHere)
		seen[id] = true
		if header == false then return end   -- 머리글을 못 읽은 구간은 손대지 않는다
		if zoneHere or (header and kept[header]) or id == focus then
			if rec.hidden[id] then back[#back + 1] = id end
		elseif removeOthers and IsWatched(id) and not (spare and spare[id]) then
			out[#out + 1] = id
		end
	end)
	if whole == nil then return nil end
	-- 빼기부터 해야 추적 칸(최대 25)이 비어서 되돌릴 자리가 난다
	for _, id in ipairs(out) do
		C_QuestLog.RemoveQuestWatch(id)
		rec.hidden[id] = true
	end
	for _, id in ipairs(back) do Watch(id) end
	-- 끝냈거나 포기한 퀘스트는 잊는다. 나중에 다시 받는 반복 퀘스트가 엉뚱하게 되돌아오면 곤란하다
	if whole then
		for id in pairs(rec.hidden) do
			if not seen[id] then rec.hidden[id] = nil end
		end
	end
	return #out, whole
end

-- 적어 둔 퀘스트를 모두 되돌린다. 목록이 비어 있으면(접속 직후) false
local function RestoreAll()
	if not next(rec.hidden) then return true end
	if (C_QuestLog.GetNumQuestLogEntries() or 0) == 0 then return false end
	for id in pairs(rec.hidden) do
		if C_QuestLog.GetLogIndexForQuestID(id) then
			Watch(id)
		else
			rec.hidden[id] = nil
		end
	end
	return true
end

-- 기본값이 켜짐이라, 처음 퀘스트가 사라질 때 왜 그런지 한 번 알려 준다
local function TellOnce(removed)
	if db.told then return end
	db.told = true
	local how = (button and db.showButton) and "목표 창 제목 줄의 필터 버튼이나 " or ""
	ns.Print(("다른 지역 퀘스트 %d개를 목표 창에서 뺐어요. 그 지역에 가면 다시 보여요. %s|cff00ff00/이지|r > %s에서 끌 수 있어요.")
		:format(removed, how, ns:SettingsPath(M.key)))
end

-- 설정 창 상태 줄(지역·뺀 개수)이 바뀌었을 때만 창을 다시 그린다. 거르기 뒤와 0.25초 틱에서 본다
local function RefreshStatus()
	local zone, hidden = M:GetStatus()
	local status = ("%s:%s:%d"):format(tostring(db.enabled), zone, hidden)
	if status ~= lastStatus then
		lastStatus = status
		ns:Fire("REFRESH_UI")
	end
end

local function Run()
	if not rec or InCombatLockdown() then return end   -- 전투 중이면 queued를 남겨 두고 PLAYER_REGEN_ENABLED에 마저 한다
	if not db.enabled then
		if RestoreAll() then
			rec.zone = nil
			queued = nil
		end
	elseif not CanUntrack() then
		queued = nil
	else
		local zone = CurrentZone()
		if not zone then return end   -- 로딩 중이라 지역 이름이 없다. 다음 이벤트에 다시
		local force = queued == "force"
		local full = force or zone ~= rec.zone
		local removed, whole = Filter(full, not force and freshZone == zone and fresh or nil)
		if removed then
			if full and not whole and retries < 3 then
				retries = retries + 1   -- 덜 읽힌 줄이 있었다. 다 읽히면(QUEST_LOG_UPDATE) 한 번 더 거른다
			else
				retries = 0
				if full then
					rec.zone = zone
					wipe(fresh)   -- 막 받은 퀘스트 봐주기는 이번 지역 거르기까지만
					freshZone = nil
				end
				queued = nil
			end
			if removed > 0 then TellOnce(removed) end
		end
	end
	RefreshStatus()
	UpdateHeader()
end

-- 지역 이벤트는 한꺼번에 몰려온다. 잠깐 모았다가 한 번만 돈다
local function Queue(kind)
	if not rec then return end
	if not db.enabled and not next(rec.hidden) then
		-- 꺼져 있고 되돌릴 것도 없다. 다음에 켜면(다른 캐릭터에서 켰어도) 처음부터 거르게 지역 기록을 지운다
		rec.zone, queued = nil, nil
		return
	end
	if kind == "force" or not queued then queued = kind end
	if timerOn then return end
	timerOn = true
	C_Timer.After(0.2, function()
		timerOn = false
		Run()
	end)
end

local function OnCheck()
	countDirty = true
	Queue("check")
end
ns:RegisterEvent("PLAYER_ENTERING_WORLD", OnCheck)
ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", OnCheck)
ns:RegisterEvent("ZONE_CHANGED", OnCheck)
ns:RegisterEvent("ZONE_CHANGED_INDOORS", OnCheck)
local function OnRetry()
	if queued then Queue(queued) end   -- 목록이 늦게 채워졌거나 전투가 끝났으면 그때 마저 한다
end
ns:RegisterEvent("QUEST_LOG_UPDATE", function()
	countDirty = true   -- 받거나 끝낸 퀘스트로 수가 바뀐다
	OnRetry()
end)
ns:RegisterEvent("PLAYER_REGEN_ENABLED", OnRetry)
ns:RegisterEvent("QUEST_POI_UPDATE", function()
	countDirty = true
	if db and db.onMap then Queue("check") end
end)
ns:RegisterEvent("SUPER_TRACKING_CHANGED", function()
	if db and db.keepFocused then Queue("check") end
end)
-- 누가 다시 추적에 넣었으면(직접, 블리자드 자동 추적, 우리) 더는 우리가 뺀 퀘스트가 아니다.
-- 지금도 추적 중인지 본다: 넣었다 바로 다시 뺀 퀘스트의 알림이 늦게 와도 기록을 지우지 않게
ns:RegisterEvent("QUEST_WATCH_LIST_CHANGED", function(_, questID, added)
	questID = Clean(questID)
	if added and rec and questID and IsWatched(questID) then rec.hidden[questID] = nil end
end)
-- 받은 지역을 같이 적는다. 다른 지역으로 가면 그 지역 거르기에서는 더 봐주지 않는다
ns:RegisterEvent("QUEST_ACCEPTED", function(_, questID)
	questID = Clean(questID)
	local zone = CurrentZone()
	if not (questID and zone) then return end
	if zone ~= freshZone then
		wipe(fresh)
		freshZone = zone
	end
	fresh[questID] = true
end)

---------------------------------------------------------------------------
-- 목표 창 제목 줄 버튼
-- 제목 줄의 자식으로 두면 목표 창이 비어 숨을 때(다 걸렀을 때) 같이 사라져 되돌릴 수 없고, 게임패드 탐색이
-- 우리 버튼을 블리자드 코드 안에서 누르게 된다. 그래서 UIParent 자식으로 같은 자리에 붙인다.
-- 블리자드 갱신 도중에 끼어들지 않으려고 훅 대신 0.25초마다 목표 창 상태를 읽어 맞춘다.
---------------------------------------------------------------------------
local ATLAS = "ui-questtrackerbutton-filter"
local ATLAS_PRESSED = "ui-questtrackerbutton-filter-pressed"
local ATLAS_HIGHLIGHT = "ui-questtrackerbutton-red-highlight"

local ticker, hasAtlas, tipShown

local function TrackerParts()
	local tracker = ObjectiveTrackerFrame
	local header = type(tracker) == "table" and tracker.Header
	local minimize = type(header) == "table" and header.MinimizeButton
	if type(minimize) == "table" and minimize.GetObjectType then return tracker, header, minimize end
end

-- 목표 창이 숨은 동안 오른쪽 관리 칸(내구도 인형 등)이 그 자리로 올라오면 버튼이 그 위에 겹친다
local function Overlapped(tracker)
	local parent = tracker:GetParent()
	if type(parent) ~= "table" or parent == UIParent or not parent.GetChildren then return false end
	local s = button:GetEffectiveScale()
	local l, r, t, b = button:GetLeft(), button:GetRight(), button:GetTop(), button:GetBottom()
	if not (type(s) == "number" and l and r and t and b) then return false end
	for _, child in ipairs({ parent:GetChildren() }) do
		if type(child) == "table" and child ~= tracker and child.IsShown and child:IsShown() then
			local cs = child:GetEffectiveScale()
			local cl, cr, ct, cb = child:GetLeft(), child:GetRight(), child:GetTop(), child:GetBottom()
			if type(cs) == "number" and cl and cr and ct and cb
				and cl * cs < r * s and cr * cs > l * s and cb * cs < t * s and ct * cs > b * s then
				return true
			end
		end
	end
	return false
end

-- 목표 창이 보이면(접혀도 제목 줄은 보인다) 보인다. 목표 창이 비어 스스로 숨었고 그게 우리가 뺀 퀘스트 때문이면
-- (끄고 되돌리는 중 포함) 마지막 자리에 버튼만 남겨 다시 끌 수 있게 한다(숨어도 기준점은 남는다).
-- 자리를 모르거나(한 번도 안 보임) 다른 칸이 그 자리에 올라왔거나 목록 자체가 비었으면 남기지 않는다.
local function ButtonWanted(tracker, header, minimize)
	if not (db and db.showButton and tracker) then return false end
	if not header:IsShown() then return false end   -- 게임 규칙으로 꺼졌거나 모듈이 없다
	if tracker.IsRolesetFiltered and tracker:IsRolesetFiltered() then return false end
	if tracker:IsVisible() then return true end
	return (db.enabled or queued ~= nil) and CountHidden() > 0
		and (C_QuestLog.GetNumQuestLogEntries() or 0) > 0
		and type(minimize:GetRight()) == "number" and not Overlapped(tracker)
end

-- 전투 때문에 밀린, 목표 창을 바꿀 일이 있는가: 사용자가 시킨 변경(클릭·다시 거르기)이거나 지역이 바뀌어 다시 거를 차례
-- (같은 지역 안 배경 확인은 보통 아무것도 안 바꾸니 넣지 않는다)
local function Deferred()
	if not (queued and InCombatLockdown()) then return false end
	return queued == "force" or (db.enabled and rec ~= nil and CurrentZone() ~= rec.zone) or false
end

-- 툴팁 내용이 바뀌는 상태. 틱마다 다시 그리면 깜빡이니 이게 바뀔 때만 다시 그린다
local function TipState()
	local zone, hidden = M:GetStatus()
	return ("%s:%s:%d:%s"):format(tostring(db.enabled), zone, hidden, tostring(Deferred()))
end

local function ShowTooltip(self)
	tipShown = TipState()
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:SetText(M.title, 1, 0.82, 0)
	local zone, hidden = M:GetStatus()
	if db.enabled then
		GameTooltip:AddLine(("켜짐 · %s · 추적에서 뺀 퀘스트 %d개"):format(zone, hidden), 0.3, 1, 0.3)
	elseif hidden > 0 then
		GameTooltip:AddLine(("꺼짐 · 뺀 퀘스트 %d개를 되돌리는 중"):format(hidden), 1, 0.82, 0)
	else
		GameTooltip:AddLine("꺼짐 · 추적 중인 퀘스트를 모두 보여 줘요", 0.6, 0.6, 0.6)
	end
	if Deferred() then GameTooltip:AddLine("전투가 끝나면 목표 창에 반영돼요", 1, 0.6, 0.2) end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine(db.enabled and "클릭: 끄기 (모든 퀘스트 보이기)" or "클릭: 켜기 (지역 퀘스트만)", 0.8, 0.8, 0.8)
	if db.enabled then GameTooltip:AddLine("Shift+클릭: 지금 다시 거르기", 0.8, 0.8, 0.8) end
	GameTooltip:AddLine("우클릭: 설정 열기", 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

-- 우리 프레임을 접기 버튼과 같은 층·높이·배율·투명도로 맞춘다.
-- 편집 모드로 옮기면 목표 창이 UIParent 밑으로 가며 층이 바뀐다(LOW→MEDIUM)
local function MatchTracker(frame, tracker, minimize)
	local strata = minimize:GetFrameStrata()
	if type(strata) == "string" and frame:GetFrameStrata() ~= strata then frame:SetFrameStrata(strata) end
	local level = minimize:GetFrameLevel()
	if type(level) == "number" then frame:SetFrameLevel(level) end   -- 제목 줄 배경 위, 블리자드 버튼과 같은 높이
	local scale, base = minimize:GetEffectiveScale(), UIParent:GetEffectiveScale()
	if type(scale) == "number" and type(base) == "number" and base > 0 then frame:SetScale(scale / base) end
	local alpha = tracker:IsVisible() and tracker:GetAlpha() or 1   -- 탈것 화면 등에서 블리자드가 목표 창만 투명하게 할 때
	frame:SetAlpha(type(alpha) == "number" and alpha or 1)
end

local function UpdateButton(tracker, header, minimize)
	if not button then return end
	if not (tracker and ButtonWanted(tracker, header, minimize)) then
		button:Hide()
		return
	end
	MatchTracker(button, tracker, minimize)
	button.icon:SetDesaturated(not db.enabled)
	button:Show()
	if GameTooltip:IsOwned(button) and TipState() ~= tipShown then ShowTooltip(button) end
end

---------------------------------------------------------------------------
-- 제목 줄 퀘스트 수: '모든 목표' 바로 옆에 "이 지역(그중 완료) / 전체(그중 완료)" (예: 11(3) / 33(7))
-- 이 지역은 거르기와 같은 판정(머리글 + 옵션이면 이 지역 지도 목표)이고, 늘 남기는 직업·집중 추적 퀘스트는 세지 않는다.
-- 완료 = 목표를 다 채워 반납만 남은 퀘스트(목표 창이 '?'를 띄우는 그 판정, C_QuestLog.IsComplete)
-- 글자 크기를 키워 버튼까지 닿으면 괄호를 뒤에서부터 뺀다. 그래도 닿으면 버튼 클릭을 가리느니 숨는다
---------------------------------------------------------------------------
local counter
local countHere, countDone, countTotal, countAllDone = 0, 0, 0, 0
local COUNT_COLOR = { 0.75, 0.61, 0 }   -- 목표 창 퀘스트 제목의 진한 골드(OBJECTIVE_TRACKER_BLOCK_HEADER_COLOR)가 없을 때

local function CountQuests()
	local here, done, total, allDone = 0, 0, 0, 0
	Scan(function(id, _, zoneHere)
		local complete = Clean(C_QuestLog.IsComplete(id)) and true or false
		total = total + 1
		if complete then allDone = allDone + 1 end
		if zoneHere then
			here = here + 1
			if complete then done = done + 1 end
		end
	end)
	return here, done, total, allDone
end

local function ShowCountTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:SetText(("이 지역 퀘스트 %d개 (완료 %d개) / 전체 %d개 (완료 %d개)"):format(countHere, countDone, countTotal, countAllDone),
		1, 0.82, 0)
	GameTooltip:AddLine(db.onMap and "이 지역 = 퀘스트 목록에서 지금 지역 이름 아래 묶인 퀘스트 + 이 지역 지도에 목표가 찍힌 퀘스트"
		or "이 지역 = 퀘스트 목록에서 지금 지역 이름 아래 묶인 퀘스트", 0.8, 0.8, 0.8, true)
	GameTooltip:AddLine("완료 = 목표를 다 채워 반납만 남은 퀘스트", 0.8, 0.8, 0.8, true)
	GameTooltip:Show()
end

-- 1 = 11(3) / 33(7), 2 = 11(3) / 33, 3 = 11 / 33. 자리가 모자랄수록 뒤 괄호부터 덜어 낸다
local function CountText(level)
	if level == 1 then return ("%d(%d) / %d(%d)"):format(countHere, countDone, countTotal, countAllDone) end
	if level == 2 then return ("%d(%d) / %d"):format(countHere, countDone, countTotal) end
	return ("%d / %d"):format(countHere, countTotal)
end

-- '모든 목표' 글자 끝 뒤부터 필터 버튼(꺼졌으면 접기 버튼) 앞까지 남는 폭. 둘 다 제목 줄 자식이라 같은 단위다
local function CountRoom(label, minimize, labelWidth)
	local left, right = label:GetLeft(), minimize:GetLeft()
	if type(left) ~= "number" or type(right) ~= "number" then return nil end   -- 자리를 모르면 재지 않는다
	if button and button:IsShown() then right = right - 20 end   -- 필터 버튼 18 + 틈 2
	return right - 4 - (left + labelWidth + 6)
end

local function UpdateCount(tracker, header, minimize)
	if not counter then return end
	local label = header and header.Text   -- '모든 목표' 글자
	if not (db.showCount and tracker and header:IsShown() and tracker:IsVisible() and type(label) == "table" and label.GetStringWidth) then
		counter:Hide()
		return
	end
	if countDirty then
		countDirty = false
		countHere, countDone, countTotal, countAllDone = CountQuests()
		counter.room = false   -- 수가 바뀌면 글자 폭도 바뀌니 다시 맞춘다
		if GameTooltip:IsOwned(counter) then ShowCountTooltip(counter) end
	end
	if countTotal == 0 then
		counter:Hide()
		return
	end
	-- 글자 끝 바로 뒤. 글자 크기 설정·긴 글자 자동 축소로 폭이 바뀌니 틱마다 본다
	local width = label:GetStringWidth()
	if type(width) == "number" and width ~= counter.labelWidth then
		counter.labelWidth = width
		counter:ClearAllPoints()
		counter:SetPoint("LEFT", label, "LEFT", width + 6, 0)
	end
	local room = type(width) == "number" and CountRoom(label, minimize, width) or nil
	if room ~= counter.room then
		counter.room = room
		counter.fits = false
		for level = 1, 3 do
			counter.text:SetText(CountText(level))
			local w = counter.text:GetStringWidth()
			if type(w) ~= "number" or not room or w <= room then
				counter.fits = true
				if type(w) == "number" then counter:SetWidth(w) end
				break
			end
		end
	end
	if not counter.fits then
		counter:Hide()
		return
	end
	MatchTracker(counter, tracker, minimize)
	counter:Show()
end

local function CreateCounter()
	if counter or not TrackerParts() then return end
	local f = CreateFrame("Frame", "EzyWOWFQuestZoneCount", UIParent)
	f:SetSize(30, 14)
	f:SetFrameStrata("LOW")
	f:Hide()
	local fs = f:CreateFontString(nil, "ARTWORK")
	local font = ObjectiveTrackerLineFont   -- 목표 창 글꼴: 편집 모드 글자 크기 설정을 따라간다
	fs:SetFontObject(type(font) == "table" and font or "GameFontHighlightSmall")
	-- '모든 목표'(NORMAL_FONT_COLOR)와 어울리는 조금 진한 골드: 블리자드가 목표 창 퀘스트 제목에 쓰는 색
	local r, g, b = unpack(COUNT_COLOR)
	local color = OBJECTIVE_TRACKER_BLOCK_HEADER_COLOR
	if type(color) == "table" and color.GetRGB then
		local cr, cg, cb = color:GetRGB()
		if type(cr) == "number" and type(cg) == "number" and type(cb) == "number" then r, g, b = cr, cg, cb end
	end
	fs:SetTextColor(r, g, b)
	fs:SetPoint("LEFT")
	f.text = fs
	f:EnableMouse(true)
	f:SetScript("OnEnter", ShowCountTooltip)
	f:SetScript("OnLeave", GameTooltip_Hide)
	counter = f
end

function UpdateHeader()
	local tracker, header, minimize = TrackerParts()
	UpdateButton(tracker, header, minimize)
	UpdateCount(tracker, header, minimize)
	if rec then RefreshStatus() end   -- 거르기 없이 바뀌는 것(목록이 빔 등)도 상태 줄에 바로
end

local function CreateButton()
	if button then return end
	local tracker, _, minimize = TrackerParts()
	if not tracker then return end
	local b = CreateFrame("Button", "EzyWOWFQuestZoneButton", UIParent)
	b:SetSize(18, 19)
	b:SetFrameStrata("LOW")   -- 기본 위치 목표 창의 층. 옮겨지면 MatchTracker가 따라간다
	b:SetPoint("RIGHT", minimize, "LEFT", -2, 0)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:Hide()

	hasAtlas = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(ATLAS) and true or false
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	if hasAtlas then
		icon:SetAtlas(ATLAS)
		b:SetHighlightAtlas(ATLAS_HIGHLIGHT, "ADD")
	else
		icon:SetTexture(ns.GetIcon(M.icon))
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	end
	b.icon = icon

	b:SetScript("OnMouseDown", function() if hasAtlas then icon:SetAtlas(ATLAS_PRESSED) end end)
	b:SetScript("OnMouseUp", function() if hasAtlas then icon:SetAtlas(ATLAS) end end)
	b:SetScript("OnClick", function(self, mouseButton)
		if mouseButton == "RightButton" then
			ns:OpenWindow(M.key)
		elseif IsShiftKeyDown() and db.enabled then
			M:Refilter()
		else
			M:SetEnabled(not db.enabled)
			if SOUNDKIT then
				PlaySound(db.enabled and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
			end
		end
		if GameTooltip:IsOwned(self) then ShowTooltip(self) end
	end)
	b:SetScript("OnEnter", ShowTooltip)
	b:SetScript("OnLeave", GameTooltip_Hide)
	button = b
end

-- 버튼이나 퀘스트 수가 보일 수 있을 때만 상태 읽기 틱을 돌린다
local function SyncHeader()
	CreateButton()
	CreateCounter()
	local want = (button ~= nil and db.showButton) or (counter ~= nil and db.showCount)
	if want and not ticker then
		ticker = C_Timer.NewTicker(0.25, UpdateHeader)
	elseif not want and ticker then
		ticker:Cancel()
		ticker = nil
	end
	UpdateHeader()
end

-- 목표 창 애드온은 보통 우리보다 먼저 뜬다. 혹시 늦으면 뜰 때 만든다
ns:RegisterEvent("ADDON_LOADED", function(_, name)
	if name == "Blizzard_ObjectiveTracker" and db then SyncHeader() end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	if type(db.chars) ~= "table" then db.chars = {} end   -- 표라서 설정 내보내기(EZY1)에는 안 들어간다
end

function M:OnLogin()
	local key = Clean(UnitGUID("player")) or UnitName("player")
	if not key then return end
	local r = db.chars[key]
	if type(r) ~= "table" then
		r = {}
		db.chars[key] = r
	end
	if type(r.hidden) ~= "table" then r.hidden = {} end
	rec = r   -- 첫 확인은 곧이어 오는 PLAYER_ENTERING_WORLD가 한다. 꺼져 있어도 남은 기록이 있으면 되돌린다
	SyncHeader()
	-- 저장 파일이 새로 시작됐으면(포에버 베타의 저장 파일 유실 등) 지난번에 뺀 기록도 없다.
	-- 거르기가 한 번 돈 뒤에도 기록 없이 추적이 빠진 퀘스트가 있으면 복구 버튼을 한 번 알린다
	if ns.freshStart and db.enabled then
		C_Timer.After(5, function()
			local orphan = false
			Scan(function(id)
				if not IsWatched(id) and not rec.hidden[id] then orphan = true end
			end)
			if orphan then
				ns.Print(("저장 파일이 새로 시작됐어요. 목표 창에서 빠진 채 돌아오지 않는 퀘스트가 있으면 |cff00ff00/이지|r > %s의 [모두 다시 추적]을 누르세요.")
					:format(ns:SettingsPath(M.key)))
			end
		end)
	end
end

-- [저장]·설정 가져오기·목표 창 버튼이 모두 여기로 온다. 페이지가 새 숫자를 보이도록 바로 돈다.
-- 목록이 비어 있거나 전투 중이면 queued가 남아 나중에 마저 한다
function M:ApplySettings(changes)
	if not rec then return end
	if changes.enabled ~= nil or changes.onMap ~= nil or changes.keepFocused ~= nil or changes.keepClassProf ~= nil then
		queued = "force"
		Run()
	end
	countDirty = true   -- 지도 목표 옵션이 바뀌면 이 지역 수도 바뀐다
	SyncHeader()
end

-- 설정 창 밖(목표 창 버튼)에서 바로 켜고 끈다. db를 먼저 써야 창에 걸려 있던 같은 칸 변경이 지워진다
function M:SetEnabled(on)
	if not db then return end
	db.enabled = on and true or false
	ns:SetSetting(M, "enabled", db.enabled)
	M:ApplySettings({ enabled = db.enabled })
	ns:Fire("REFRESH_UI")
end

-- 같은 지역에서 직접 추적한 다른 지역 퀘스트까지 지금 다시 거른다
function M:Refilter()
	if not (rec and db.enabled) then return end
	queued = "force"
	Run()
end

-- 뺀 기록을 잃었을 때(설정 초기화 등)의 복구. 추적 안 된 퀘스트를 모두 되살린다.
--   켜져 있으면: 추적 칸에 넣지 않고 뺀 기록에만 적은 뒤 다시 거른다. 거르기가 이 지역 것만 되돌리고(빼기 먼저라 칸이 남는다)
--     다른 지역 것은 기록으로 남아 그 지역에 가면 돌아온다. 넣었다 빼면 칸(25)이 모자라 기록에서 빠지는 퀘스트가 생긴다
--   꺼져 있으면: 바로 추적한다(넣은 것은 추적 알림으로 기록에서 빠지고, 칸이 꽉 차 못 넣은 것은 기록에 남아 나중에 되돌린다)
function M:TrackAll()
	if not rec then return end
	if InCombatLockdown() then
		ns.Print("전투 중에는 할 수 없어요. 전투가 끝난 뒤 다시 눌러 주세요.")
		return
	end
	local count, missed = 0, 0
	for i = 1, C_QuestLog.GetNumQuestLogEntries() or 0 do
		local info = C_QuestLog.GetInfo(i)
		local id = info and not info.isHeader and Clean(info.questID)
		if id and id > 0 and not (info.isHidden or info.isTask or info.isBounty) and not IsWatched(id) then
			if db.enabled then
				rec.hidden[id] = true
				count = count + 1
			elseif C_QuestLog.AddQuestWatch(id) or IsWatched(id) then
				count = count + 1
			else
				missed = missed + 1
			end
		end
	end
	if db.enabled then
		queued = "force"
		Run()
		ns.Print(("추적이 빠져 있던 퀘스트 %d개를 되살렸어요. 이 지역 퀘스트는 목표 창에 다시 보이고, 다른 지역 퀘스트는 그 지역에 가면 보여요.")
			:format(count))
	else
		local tail = missed > 0 and (" 추적 칸(최대 25개)이 꽉 차 %d개는 못 넣었어요. 자리가 나면 되돌려요."):format(missed) or ""
		ns.Print(("퀘스트 %d개를 다시 추적했어요.%s"):format(count, tail))
		ns:Fire("REFRESH_UI")
		UpdateHeader()
	end
end

-- 지금 지역 이름과 뺀 퀘스트 수. 퀘스트 목록이 비면 남은 기록은 끝낸 퀘스트뿐이라 0으로 본다(다음에 목록이 차면 정리된다)
function M:GetStatus()
	local zone = Clean(GetRealZoneText and GetRealZoneText())
	local hidden = (C_QuestLog.GetNumQuestLogEntries() or 0) > 0 and CountHidden() or 0
	return (zone and zone ~= "" and zone or "?"), hidden
end

function M:BuildOptions(b)
	b:Text("퀘스트 목표 창에 지금 있는 지역의 퀘스트만 남깁니다. 퀘스트 목록에서 지금 지역 이름 아래 묶인 퀘스트가 이 지역 퀘스트입니다.")
	b:Text("지역을 옮기면 다른 지역 퀘스트를 추적에서 빼고, 그 지역에 다시 가면 뺀 퀘스트를 되돌립니다. "
		.. "같은 지역에 있는 동안 직접 추적하거나 새로 받은 퀘스트는 그대로 두고, 다음에 지역을 옮길 때 다시 거릅니다. "
		.. "직접 추적 해제한 퀘스트는 되돌리지 않습니다. 전투 중에 지역을 옮기면 전투가 끝난 뒤 바꿉니다.", { color = { 0.7, 0.7, 0.7 } })
	b:Text("끄면 지금 캐릭터에서 뺀 퀘스트를 다시 추적합니다. 다른 캐릭터는 그 캐릭터로 접속할 때 되돌립니다. "
		.. "애드온을 지우려면 먼저 끄고, 이 기능을 쓴 캐릭터마다 한 번씩 접속한 뒤 지우세요. "
		.. "설정은 와우 계정마다 따로라서, 여러 계정에서 썼다면 계정마다 끄세요.", { color = { 1, 0.6, 0.2 } })
	b:Check{ key = "enabled", label = "사용" }
	b:Check{
		key = "onMap",
		label = "이 지역 지도에 목표가 찍힌 퀘스트도 보이기",
		tooltip = "다른 지역에서 받았어도 목표나 완료 지점이 이 지역 지도에 표시되는 퀘스트는 남깁니다.",
		depends = "enabled",
		indent = 20,
	}
	b:Check{
		key = "keepFocused",
		label = "집중 추적 퀘스트는 지역이 달라도 보이기",
		tooltip = "목표 창에서 우클릭해 집중 추적으로 고른 퀘스트는 어느 지역에서나 남깁니다. "
			.. "끄면 그 퀘스트도 빠지고, 블리자드가 집중 추적까지 풉니다.",
		depends = "enabled",
		indent = 20,
	}
	b:Check{
		key = "keepClassProf",
		label = "직업·전문 기술 퀘스트는 지역이 달라도 보이기",
		tooltip = "퀘스트 목록에서 직업(사냥꾼 등)이나 전문 기술(요리·낚시꾼·대장장이 등) 머리글 아래 묶인 퀘스트는 늘 남깁니다.",
		depends = "enabled",
		indent = 20,
	}
	b:Check{
		key = "showButton",
		label = "목표 창 제목 줄에 켜기/끄기 버튼 보이기",
		tooltip = "'모든 목표' 줄의 접기 버튼 왼쪽에 필터 버튼을 둡니다. 그 버튼은 [저장]을 누르지 않아도 누르는 즉시 켜고 끕니다. "
			.. "Shift+클릭: 지금 다시 거르기 · 우클릭: 이 설정 열기. 퀘스트를 다 걸러 목표 창이 사라지면 버튼만 그 자리에 남습니다.",
	}
	b:Check{
		key = "showCount",
		label = "목표 창 제목 줄에 지역/전체 퀘스트 수 보이기",
		tooltip = "'모든 목표' 바로 옆에 이 지역 퀘스트 수(그중 완료한 수) / 퀘스트 목록 전체 수(그중 완료한 수)를 보여 줍니다"
			.. "(예: 11(3) / 33(7)). 완료는 목표를 다 채워 반납만 남은 퀘스트입니다. "
			.. "늘 남기는 직업·전문 기술·집중 추적 퀘스트는 이 지역 수에 넣지 않습니다. 기능을 꺼도 보입니다. "
			.. "글자 크기를 키워 자리가 모자라면 뒤 괄호부터 줄여 보여 줍니다.",
	}
	b:Text(function()
		local zone, hidden = M:GetStatus()
		if not db.enabled then
			if hidden == 0 then return "|cff999999꺼져 있음|r" end
			return ("|cffffd100꺼짐 · 되돌릴 퀘스트 %d개 남음 (전투가 끝나거나 추적 칸이 비면 되돌려요)|r"):format(hidden)
		end
		return ("지금 지역: |cffffd100%s|r · 추적에서 뺀 퀘스트 %d개"):format(zone, hidden)
	end)
	b:Buttons{
		{
			text = "지금 다시 거르기",
			width = 140,
			tooltip = "같은 지역에서 직접 추적한 다른 지역 퀘스트까지 지금 다시 거릅니다. [저장]한 설정 기준입니다.",
			onClick = function() M:Refilter() end,
			disabled = function() return not db.enabled end,   -- 저장 전 값이 아니라 실제로 도는 값으로
		},
		{
			text = "모두 다시 추적",
			width = 120,
			tooltip = "설정이 초기화되는 등으로 뺀 기록을 잃어 돌아오지 않는 퀘스트가 있으면 누르세요. "
				.. "퀘스트 목록의 퀘스트를 모두 다시 추적하고, 켜져 있으면 지금 지역 기준으로 다시 거릅니다.",
			onClick = function() M:TrackAll() end,
		},
	}
end
