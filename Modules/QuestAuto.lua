-- 퀘스트 자동 수락/완료. NPC와 대화할 때 Shift를 누르고 있으면 그때만 건너뛴다.
-- 보상을 골라야 하거나 돈을 내야 하는 퀘스트는 멈춰서 직접 처리하게 둔다.

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

local db

local function Active()
	return db and db.enabled and not IsShiftKeyDown()
end

-- 대화 창(가십)에 퀘스트가 있으면 완료할 것부터, 그다음 받을 것을 고른다.
local function HandleGossip()
	if not Active() or not C_GossipInfo then return end
	if db.turnIn then
		for _, quest in ipairs(C_GossipInfo.GetActiveQuests() or {}) do
			if quest.isComplete then
				C_GossipInfo.SelectActiveQuest(quest.questID)
				return
			end
		end
	end
	if db.accept then
		for _, quest in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do
			if not (db.skipTrivial and quest.isTrivial) then
				C_GossipInfo.SelectAvailableQuest(quest.questID)
				return
			end
		end
	end
end

-- 예전 방식의 퀘스트 목록 창 (가십 없이 퀘스트만 있는 NPC)
local function HandleGreeting()
	if not Active() then return end
	if db.turnIn then
		for i = 1, GetNumActiveQuests() do
			local _, isComplete = GetActiveTitle(i)
			if isComplete then
				SelectActiveQuest(i)
				return
			end
		end
	end
	if db.accept then
		for i = 1, GetNumAvailableQuests() do
			local isTrivial = GetAvailableQuestInfo and GetAvailableQuestInfo(i)
			if not (db.skipTrivial and isTrivial) then
				SelectAvailableQuest(i)
				return
			end
		end
	end
end

local function HandleDetail()
	if not (Active() and db.accept) then return end
	if QuestGetAutoAccept and QuestGetAutoAccept() then
		if AcknowledgeAutoAcceptQuest then AcknowledgeAutoAcceptQuest() end
	else
		AcceptQuest()
	end
end

local function HandleProgress()
	if not (Active() and db.turnIn) then return end
	if IsQuestCompletable() and (GetQuestMoneyToGet() or 0) == 0 then
		CompleteQuest()
	end
end

local function HandleComplete()
	if not (Active() and db.turnIn) then return end
	local choices = GetNumQuestChoices()
	if choices <= 1 then
		GetQuestReward(choices)
	end
end

ns:RegisterEvent("GOSSIP_SHOW", HandleGossip)
ns:RegisterEvent("QUEST_GREETING", HandleGreeting)
ns:RegisterEvent("QUEST_DETAIL", HandleDetail)
ns:RegisterEvent("QUEST_PROGRESS", HandleProgress)
ns:RegisterEvent("QUEST_COMPLETE", HandleComplete)

function M:OnInitialize()
	db = self.db
end

function M:BuildOptions(b)
	b:Text("NPC와 대화하면 퀘스트를 자동으로 받고 완료합니다. 보상을 골라야 하거나 돈을 내야 하는 퀘스트에서는 멈춥니다. "
		.. "Shift를 누른 채 대화하면 그때만 건너뜁니다.")
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
