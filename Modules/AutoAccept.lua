-- 파티 초대 / 소환 / 부활 요청 자동 수락.

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local M = ns:NewModule("AutoAccept", {
	title = "초대·소환·부활 자동 수락",
	category = "auto",
	icon = "Interface\\Icons\\Spell_Holy_Resurrection",
	order = 40,
	defaults = {
		enabled = true,
		invite = true,
		inviteAnyone = false,
		summon = true,
		resurrect = true,
		skipCombatRes = false,
	},
})

local db

-- 팝업을 그냥 닫으면 '거절'로 처리되는 창이 있어서, 수락했다고 표시한 뒤 닫는다.
local function HidePopup(which, acceptedFlag)
	if acceptedFlag and StaticPopup_FindVisible then
		local dialog = StaticPopup_FindVisible(which)
		if dialog then dialog[acceptedFlag] = 1 end
	end
	StaticPopup_Hide(which)
end

local function SafeCall(fn, ...)
	if not fn then return nil end
	local ok, result = pcall(fn, ...)
	return ok and Clean(result) or nil
end

local function IsTrusted(guid)
	guid = Clean(guid)
	if not guid then return false end
	if C_FriendList and SafeCall(C_FriendList.IsFriend, guid) then return true end
	if C_BattleNet and C_BattleNet.GetAccountInfoByGUID then
		local info = SafeCall(C_BattleNet.GetAccountInfoByGUID, guid)
		if info and info.isFriend then return true end
	end
	if SafeCall(IsGuildMember, guid) then return true end
	return false
end

ns:RegisterEvent("PARTY_INVITE_REQUEST", function(_, name, _, _, _, _, _, inviterGUID, questSessionActive)
	if not (db and db.enabled and db.invite) or questSessionActive then return end
	if not (db.inviteAnyone or IsTrusted(inviterGUID)) then return end
	AcceptGroup()
	HidePopup("PARTY_INVITE", "inviteAccepted")
	name = Clean(name)
	Print(("%s님의 파티 초대를 수락했습니다."):format(name or "?"))
end)

ns:RegisterEvent("CONFIRM_SUMMON", function()
	if not (db and db.enabled and db.summon) then return end
	if UnitAffectingCombat("player") or not C_SummonInfo then return end
	C_SummonInfo.ConfirmSummon()
	HidePopup("CONFIRM_SUMMON")
	Print("소환을 수락했습니다.")
end)

ns:RegisterEvent("RESURRECT_REQUEST", function(_, inviter)
	if not (db and db.enabled and db.resurrect) then return end
	inviter = Clean(inviter)
	if db.skipCombatRes and inviter and SafeCall(UnitAffectingCombat, inviter) then return end
	AcceptResurrect()
	HidePopup("RESURRECT")
	HidePopup("RESURRECT_NO_SICKNESS")
	HidePopup("RESURRECT_NO_TIMER")
	Print(("%s님의 부활을 수락했습니다."):format(inviter or "?"))
end)

function M:OnInitialize()
	db = self.db
end

function M:BuildOptions(b)
	b:Check{ key = "enabled", label = "사용" }
	b:Check{
		key = "invite",
		label = "파티 초대 자동 수락 (친구·길드원)",
		tooltip = "게임 친구, 배틀넷 친구, 같은 길드원의 초대만 수락합니다.",
		depends = "enabled",
		indent = 20,
	}
	b:Check{
		key = "inviteAnyone",
		label = "모르는 사람의 초대도 수락",
		tooltip = "주의: 아무나 초대해도 바로 파티에 들어갑니다.",
		depends = { "enabled", "invite" },
		indent = 40,
	}
	b:Check{ key = "summon", label = "소환 자동 수락 (전투 중 제외)", depends = "enabled", indent = 20 }
	b:Check{ key = "resurrect", label = "부활 자동 수락", depends = "enabled", indent = 20 }
	b:Check{
		key = "skipCombatRes",
		label = "전투 중 부활은 직접 수락",
		tooltip = "살려 준 사람이 전투 중이면(보스전 전투 부활 등) 자동으로 받지 않습니다.",
		depends = { "enabled", "resurrect" },
		indent = 40,
	}
end
