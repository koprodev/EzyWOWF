-- 퀘스트 자동 수락/완료. NPC와 대화할 때 Shift를 누르고 있으면 그때만 건너뛴다.
-- 보상을 골라야 하거나 돈을 내야 하는 퀘스트는 멈춰서 직접 처리하게 둔다.
-- 대화·퀘스트 이벤트는 동기 이벤트라 블리자드 창보다 우리가 먼저 받을 수 있다. 그래서 누르는 건 다음 프레임에, 창이 그대로일 때만.
-- 받을 퀘스트 고르기만 SELECT_DELAY만큼 더 기다린다.
-- 받기 요청에 서버 답이 없으면 한 번 더 보내고, 그래도 안 되면 채팅과 db.failures에 이벤트 기록을 남긴다.

local _, ns = ...

local M = ns:NewModule("QuestAuto", {
	title = "퀘스트 자동 수락/완료",
	category = "auto",
	icon = "Interface\\Icons\\INV_Scroll_03",
	order = 20,
	defaults = {
		enabled = true,
		accept = true,
		turnIn = true,
		skipTrivial = true,
	},
})

local SELECT_DELAY = 0.3 -- 창 뜨고 0.01초 만에 고르면 가끔 내용창 없이 대화가 닫혀서, 사람 손 속도로 고른다
local CONFIRM_SEC = 2    -- 서버 답을 기다리는 시간. 핑이 수백 ms여도 넉넉하다
local MAX_TRIES = 2      -- 처음 + 다시 한 번
local TRACE_MAX = 30
local TRACE_BACK = 3     -- 실패 기록에 요청 몇 초 전부터 담을지 (대화창이 뜬 순간까지 보이게)
local FAILURE_MAX = 5
local CALL_MAX = 6

local STAGE_TEXT = {
	select = "퀘스트 내용 창이 오지 않음",
	accept = "수락이 처리되지 않음",
}

local db
local gossipOpen, questOpen = false, false
local gossipSeq, questSeq = 0, 0   -- 창이 뜨거나 닫힐 때마다 오른다. 미뤄 둔 동작이 낡았는지 이걸로 가린다
local waiting                      -- 서버 답을 기다리는 받기 요청 하나
local trace = {}
local diagnosticsHooked = false

local function Active()
	return db and db.enabled and not IsShiftKeyDown()
end

local function Trace(text)
	trace[#trace + 1] = { t = GetTime(), text = text }
	if #trace > TRACE_MAX then table.remove(trace, 1) end
end

local function TraceSince(since)
	local parts, base = {}, nil
	for _, e in ipairs(trace) do
		if e.t >= since then
			base = base or e.t
			parts[#parts + 1] = ("+%.2f %s"):format(e.t - base, e.text)
		end
	end
	return table.concat(parts, " | ")
end

local function IsOnQuest(questID)
	return questID and C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(questID)
end

local function Shown(name)
	local frame = rawget(_G, name)
	if frame and type(frame.IsShown) == "function" then return frame:IsShown() end
end

local function Context(questID)
	return {
		npcGUID = UnitGUID and ns.Clean(UnitGUID("npc")),
		npcName = UnitName and ns.Clean(UnitName("npc")),
		moving = IsPlayerMoving and ns.Clean(IsPlayerMoving()),
		combat = UnitAffectingCombat and ns.Clean(UnitAffectingCombat("player")),
		gossipShown = Shown("GossipFrame"),
		questShown = Shown("QuestFrame"),
		questID = GetQuestID and ns.Clean(GetQuestID()),
		onQuest = IsOnQuest(questID) and true or false,
	}
end

local function RecordClose(name)
	local w = waiting
	if not w then return end
	w.calls = w.calls or {}
	if #w.calls >= CALL_MAX then return end
	local stack = type(debugstack) == "function" and debugstack(2, 6, 0) or nil
	w.calls[#w.calls + 1] = { name = name, stack = stack, context = Context(w.questID) }
	Trace("닫힘 호출: " .. name)
end

local function HookDiagnostics()
	if diagnosticsHooked or type(hooksecurefunc) ~= "function" then return end
	diagnosticsHooked = true
	-- Post-hooks observe the caller without replacing Blizzard's close functions.
	if C_GossipInfo and type(C_GossipInfo.CloseGossip) == "function" then
		hooksecurefunc(C_GossipInfo, "CloseGossip", function() RecordClose("CloseGossip") end)
	end
	if type(CloseQuest) == "function" then
		hooksecurefunc("CloseQuest", function() RecordClose("CloseQuest") end)
	end
	if type(HideUIPanel) == "function" then
		hooksecurefunc("HideUIPanel", function(frame)
			if frame and frame == rawget(_G, "GossipFrame") then RecordClose("HideUIPanel(GossipFrame)") end
			if frame and frame == rawget(_G, "QuestFrame") then RecordClose("HideUIPanel(QuestFrame)") end
		end)
	end
end

local function Report(w)
	local log = TraceSince(w.since - TRACE_BACK)
	ns.Print(("퀘스트 자동 수락이 안 됐어요: %s (%s)"):format(w.title or "?", STAGE_TEXT[w.stage]))
	ns.Print("기록: " .. log)
	if type(db.failures) ~= "table" then db.failures = {} end
	local version, build
	if type(GetBuildInfo) == "function" then version, build = GetBuildInfo() end
	table.insert(db.failures, 1, { when = time(), questID = w.questID, title = w.title, stage = w.stage, trace = log,
		client = { version = version, build = build }, requestContext = w.context,
		context = Context(w.questID), calls = w.calls })
	for i = #db.failures, FAILURE_MAX + 1, -1 do db.failures[i] = nil end
end

local Check

local function Attempt(w)
	w.tries = w.tries + 1
	if w.tries > 1 then Trace("다시 시도") end
	w.send()
	C_Timer.After(CONFIRM_SEC, function() Check(w) end)
end

function Check(w)
	if waiting ~= w then return end   -- 그사이 답이 왔거나 새 요청으로 바뀌었다
	if IsOnQuest(w.questID) then   -- Accepted quests can skip QUEST_DETAIL and QUEST_ACCEPTED.
		waiting = nil
		return
	end
	if w.tries < MAX_TRIES and w.stillOpen() then
		Attempt(w)
		return
	end
	waiting = nil
	Report(w)
end

-- stillOpen: 다시 보내도 되는 창이 아직 떠 있는지. send: 서버에 보내는 요청
local function Watch(stage, questID, title, stillOpen, send)
	waiting = { stage = stage, questID = questID, title = title, tries = 0, since = GetTime(),
		stillOpen = stillOpen, send = send, context = Context(questID) }
	return waiting
end

local function Resolve(stage, questID)
	if waiting and waiting.stage == stage and (questID == nil or waiting.questID == questID) then
		waiting = nil
	end
end

-- 이벤트를 받은 그 프레임엔 블리자드 창이 아직 덜 떴을 수 있다
local function Later(isCurrent, fn, onSkip, delay)
	C_Timer.After(delay or 0, function()
		if isCurrent() then return fn() end
		Trace("건너뜀: 창이 바뀜")
		if onSkip then onSkip() end
	end)
end

-- 기다리는 사이 창이 닫히거나 새로 떴으면 안 보낸다. 보낸 것도 없으니 실패 기록도 없다
local function SelectLater(questID, title, stillOpen, send)
	Later(stillOpen, function() Attempt(Watch("select", questID, title, stillOpen, send)) end, nil, SELECT_DELAY)
end

-- 대화 창(가십)에 퀘스트가 있으면 완료할 것부터, 그다음 받을 것을 고른다.
local function AutoGossip()
	if db.turnIn then
		for _, quest in ipairs(C_GossipInfo.GetActiveQuests() or {}) do
			if quest.isComplete then
				Trace("→완료 선택 " .. quest.questID)
				C_GossipInfo.SelectActiveQuest(quest.questID)
				return
			end
		end
	end
	if db.accept then
		for _, quest in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do
			if not (db.skipTrivial and quest.isTrivial) then
				local seq = gossipSeq
				SelectLater(quest.questID, quest.title,
					function() return gossipOpen and gossipSeq == seq end,
					function()
						Trace("→선택 " .. quest.questID)
						C_GossipInfo.SelectAvailableQuest(quest.questID)
					end)
				return
			end
		end
	end
end

local function AvailableInfo(i)
	if not GetAvailableQuestInfo then return false end
	local isTrivial, _, _, _, questID = GetAvailableQuestInfo(i)
	return isTrivial, questID
end

-- 예전 방식의 퀘스트 목록 창 (가십 없이 퀘스트만 있는 NPC)
local function AutoGreeting()
	if db.turnIn then
		for i = 1, GetNumActiveQuests() do
			local _, isComplete = GetActiveTitle(i)
			if isComplete then
				Trace("→완료 선택 " .. i)
				SelectActiveQuest(i)
				return
			end
		end
	end
	if db.accept then
		for i = 1, GetNumAvailableQuests() do
			local isTrivial, questID = AvailableInfo(i)
			if not (db.skipTrivial and isTrivial) then
				local seq = questSeq
				SelectLater(questID, GetAvailableTitle and GetAvailableTitle(i),
					function() return questOpen and questSeq == seq end,
					function()
						Trace("→선택 " .. tostring(questID or i))
						SelectAvailableQuest(i)
					end)
				return
			end
		end
	end
end

local function QuestWindowShown(label)
	questOpen = true
	questSeq = questSeq + 1
	Trace(label)
end

ns:RegisterEvent("GOSSIP_SHOW", function()
	gossipOpen = true
	gossipSeq = gossipSeq + 1
	Trace("GOSSIP_SHOW")
	if not Active() or not C_GossipInfo then return end
	local seq = gossipSeq
	Later(function() return gossipOpen and gossipSeq == seq end, AutoGossip)
end)

ns:RegisterEvent("GOSSIP_CLOSED", function(_, interactionIsContinuing)
	gossipOpen = false
	gossipSeq = gossipSeq + 1
	Trace(("GOSSIP_CLOSED(%s)"):format(tostring(interactionIsContinuing)))
end)

ns:RegisterEvent("QUEST_GREETING", function()
	QuestWindowShown("QUEST_GREETING")
	if not Active() then return end
	local seq = questSeq
	Later(function() return questOpen and questSeq == seq end, AutoGreeting)
end)

ns:RegisterEvent("QUEST_DETAIL", function(_, questStartItemID)
	local questID = GetQuestID()
	QuestWindowShown("QUEST_DETAIL " .. tostring(questID))
	Resolve("select")
	if not (Active() and db.accept) or not questID or questID == 0 then return end
	-- 아이템으로 시작하는 퀘스트와 지역에서 저절로 받는 퀘스트는 블리자드가 목표 창 알림으로 돌리고 창을 닫는다
	local auto = QuestGetAutoAccept and QuestGetAutoAccept()
	if (questStartItemID and questStartItemID ~= 0) or (auto and QuestIsFromAreaTrigger and QuestIsFromAreaTrigger()) then
		return
	end
	local w = Watch("accept", questID, GetTitleText and GetTitleText() or nil,
		function() return questOpen and GetQuestID() == questID end,
		function()
			-- 게임이 이미 받아 둔 퀘스트는 확인만 누른다
			if auto then
				Trace("→수락 확인 " .. questID)
				if AcknowledgeAutoAcceptQuest then AcknowledgeAutoAcceptQuest() end
			else
				Trace("→수락 " .. questID)
				AcceptQuest()
			end
		end)
	local seq = questSeq
	Later(function() return questOpen and questSeq == seq and GetQuestID() == questID end,
		function() Attempt(w) end,
		function() C_Timer.After(CONFIRM_SEC, function() Check(w) end) end)   -- 못 보냈어도 받아졌는지는 본다
end)

ns:RegisterEvent("QUEST_PROGRESS", function()
	QuestWindowShown("QUEST_PROGRESS")
	if not (Active() and db.turnIn) then return end
	local seq = questSeq
	Later(function() return questOpen and questSeq == seq end, function()
		if IsQuestCompletable() and (GetQuestMoneyToGet() or 0) == 0 then
			Trace("→완료")
			CompleteQuest()
		end
	end)
end)

ns:RegisterEvent("QUEST_COMPLETE", function()
	QuestWindowShown("QUEST_COMPLETE")
	if not (Active() and db.turnIn) then return end
	local seq = questSeq
	Later(function() return questOpen and questSeq == seq end, function()
		local choices = GetNumQuestChoices()
		if choices <= 1 then
			Trace("→보상 받기")
			GetQuestReward(choices)
		end
	end)
end)

ns:RegisterEvent("QUEST_FINISHED", function()
	questOpen = false
	questSeq = questSeq + 1
	Trace("QUEST_FINISHED")
end)

ns:RegisterEvent("QUEST_ACCEPTED", function(_, questID)
	Trace("QUEST_ACCEPTED " .. tostring(questID))
	Resolve("accept", questID)
	Resolve("select", questID)
end)

-- 서버가 거절하면 보통 화면 위 빨간 글씨로 온다. NPC와 얘기 중일 때 것만 담는다
ns:RegisterEvent("UI_ERROR_MESSAGE", function(_, _, message)
	if gossipOpen or questOpen or waiting then Trace("오류: " .. tostring(ns.Clean(message))) end
end)

function M:OnInitialize()
	db = self.db
	HookDiagnostics()
end

function M:BuildOptions(b)
	b:Text("NPC와 대화하면 퀘스트를 자동으로 받고 완료합니다. 보상을 골라야 하거나 돈을 내야 하는 퀘스트에서는 멈춥니다. "
		.. "Shift를 누른 채 대화하면 그때만 건너뜁니다. "
		.. "퀘스트가 받아지지 않고 창이 열려 있으면 한 번 더 시도합니다. 그래도 안 되면 채팅 창에 이벤트 기록을 보여 주고, "
		.. "저장 파일에 창을 닫은 호출 출처와 NPC·창 상태를 남깁니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Check{ key = "accept", label = "퀘스트 자동 수락", depends = "enabled", indent = 20 }
	b:Check{ key = "turnIn", label = "퀘스트 자동 완료", depends = "enabled", indent = 20 }
	b:Check{
		key = "skipTrivial",
		label = "회색(낮은 레벨) 퀘스트는 자동으로 받지 않기",
		depends = { "enabled", "accept" },
		indent = 40,
	}
end
