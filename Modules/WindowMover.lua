-- 기본 창 이동: 캐릭터·마법책·지도·상인·우편 같은 블리자드 창을 드래그해서 옮기고, 옮긴 자리를 기억한다.
--
-- 블리자드 창은 패널 관리자(FramePositionDelegate)가 열 때마다 기본 자리로 되돌린다.
-- 이 관리자는 지역 변수이고 접근 금지(Forbidden) 프레임이라 직접 훅을 걸 수 없어서,
-- 창이 열릴 때(OnShow)와 전역 UpdateUIPanelPositions가 불릴 때 "다음 프레임"에 기억한 자리로 다시 옮긴다.
-- (블리자드의 보안 처리가 끝난 뒤라 서로 충돌하지 않는다)
-- 보호된 창(안에 보안 버튼이 있는 마법책 등)은 전투 중에 옮길 수 없으므로 전투가 끝난 뒤에 맞춘다.
-- 드래그는 창의 빈 곳이나 제목 줄(TitleContainer)을 잡는다. 세계 지도는 지도 위를 끌면 지도가 움직이므로 제목 줄로 옮긴다.
-- StopMovingOrSizing은 창을 "사용자 배치"로 표시해 게임이 따로 위치를 저장하므로, 그 표시는 끈다(SetUserPlaced(false)).

local _, ns = ...
local Print = ns.Print

local M = ns:NewModule("WindowMover", {
	title = "기본 창 이동",
	category = "interface",
	icon = "Interface\\Icons\\Spell_Arcane_Blink",
	order = 50,
	defaults = {
		enabled = true,
		remember = true,
		positions = {},     -- [창 이름] = { point, relPoint, x, y }
	},
})

-- 옮길 수 있게 할 창. 아직 없는 창(필요할 때 로드되는 창)은 애드온이 로드될 때마다 다시 찾는다.
local FRAME_NAMES = {
	"CharacterFrame", "PlayerSpellsFrame", "SpellBookFrame", "WorldMapFrame", "FriendsFrame", "PVEFrame",
	"QuestFrame", "QuestLogPopupDetailFrame", "GossipFrame", "MerchantFrame", "MailFrame", "OpenMailFrame",
	"BankFrame", "TradeFrame", "LootFrame", "DressUpFrame", "TabardFrame", "PetitionFrame", "ItemTextFrame",
	"GuildRegistrarFrame", "TaxiFrame", "AddonList", "ChatConfigFrame", "HelpFrame", "SettingsPanel",
	"InspectFrame", "AuctionHouseFrame", "ProfessionsFrame", "ProfessionsBookFrame", "ClassTrainerFrame",
	"MacroFrame", "CollectionsJournal", "EncounterJournal", "AchievementFrame", "CommunitiesFrame",
	"TimeManagerFrame", "CalendarFrame", "FlightMapFrame", "ItemSocketingFrame", "GuildBankFrame",
	"TradeSkillFrame", "CraftFrame", "TalentFrame", "PlayerTalentFrame", "PetStableFrame", "StableFrame",
	"ItemUpgradeFrame", "BlackMarketFrame",
}

local db
local managed = {}          -- [창] = 이름
local pendingAfterCombat = false
local warnedCombat = false

local function Blocked(frame)
	return InCombatLockdown() and frame:IsProtected()
end

-- 세계 지도가 전체 화면으로 커져 있을 때는 그대로 둔다.
local function Skip(frame)
	return frame == WorldMapFrame and frame.IsMaximized and frame:IsMaximized()
end

local function Restore(frame)
	local name = managed[frame]
	local saved = name and db.enabled and db.remember and db.positions[name]
	if not saved or not frame:IsShown() or Skip(frame) then return end
	if Blocked(frame) then
		pendingAfterCombat = true
		return
	end
	frame:ClearAllPoints()
	frame:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
end

local function RestoreShown()
	for frame in pairs(managed) do Restore(frame) end
end

local function RestoreNextFrame(frame)
	C_Timer.After(0, function()
		if frame then Restore(frame) else RestoreShown() end
	end)
end

local function StartMoving(frame)
	if not (db and db.enabled) or Skip(frame) then return end
	if Blocked(frame) then
		if not warnedCombat then
			Print("전투 중에는 이 창을 옮길 수 없어요.")
			warnedCombat = true
		end
		return
	end
	frame.EzyWOWFMoving = true
	frame:StartMoving()
end

local function StopMoving(frame)
	if not frame.EzyWOWFMoving then return end
	frame.EzyWOWFMoving = nil
	frame:StopMovingOrSizing()
	if frame.SetUserPlaced then frame:SetUserPlaced(false) end
	local point, _, relPoint, x, y = frame:GetPoint(1)
	if point then db.positions[managed[frame]] = { point, relPoint, x, y } end
end

-- 드래그를 받을 곳: 창 자체와 제목 줄
local function IsFrame(v)
	return type(v) == "table" and type(v.RegisterForDrag) == "function"
end

local function Handles(frame)
	local list = { frame }
	if IsFrame(frame.TitleContainer) then list[#list + 1] = frame.TitleContainer end
	local border = frame.BorderFrame
	if IsFrame(border) and IsFrame(border.TitleContainer) then list[#list + 1] = border.TitleContainer end
	return list
end

local function Setup(frame, name)
	if managed[frame] then return true end
	if InCombatLockdown() and frame:IsProtected() then return false end
	managed[frame] = name
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	for _, handle in ipairs(Handles(frame)) do
		handle:EnableMouse(true)
		handle:RegisterForDrag("LeftButton")
		handle:HookScript("OnDragStart", function() StartMoving(frame) end)
		handle:HookScript("OnDragStop", function() StopMoving(frame) end)
	end
	frame:HookScript("OnShow", function() RestoreNextFrame(frame) end)
	-- 옮기는 중에 창이 닫히면 거기서 멈춘다.
	frame:HookScript("OnHide", function() StopMoving(frame) end)
	return true
end

local function SetupAll()
	local allDone = true
	for _, name in ipairs(FRAME_NAMES) do
		local frame = _G[name]
		if type(frame) == "table" and frame.SetMovable and not managed[frame] then
			if not Setup(frame, name) then allDone = false end
		end
	end
	if not allDone then pendingAfterCombat = true end
end

if UpdateUIPanelPositions then
	hooksecurefunc("UpdateUIPanelPositions", function() RestoreNextFrame() end)
end

ns:RegisterEvent("ADDON_LOADED", function()
	if db and db.enabled then SetupAll() end
end)

ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
	warnedCombat = false
	if pendingAfterCombat and db then
		pendingAfterCombat = false
		if db.enabled then
			SetupAll()
			RestoreShown()
		end
	end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
end

function M:OnLogin()
	if db.enabled then SetupAll() end
end

function M:ApplySettings()
	if db.enabled then SetupAll() end
end

function M:BuildOptions(b)
	b:Text("캐릭터, 마법책, 지도, 친구, 상인, 우편, 퀘스트, 경매장 같은 기본 창을 드래그해서 옮길 수 있게 합니다. "
		.. "창의 빈 곳이나 제목 줄을 잡고 끄세요. 지도는 제목 줄을 잡아야 합니다.")
	b:Check{
		key = "enabled", label = "사용",
		tooltip = "끄면 드래그로 옮기지 않지만, 이미 열려 있는 창은 /reload 전까지 옮길 수 있는 상태로 남습니다.",
	}
	b:Check{
		key = "remember", label = "옮긴 위치 기억", depends = "enabled", indent = 20,
		tooltip = "끄면 창을 다시 열 때 원래 자리로 돌아갑니다.",
	}
	b:Buttons{
		{
			text = "모든 창 위치 초기화", width = 160,
			onClick = function()
				wipe(db.positions)
				Print("창 위치를 초기화했습니다. 창을 다시 열면 원래 자리로 나옵니다.")
			end,
		},
	}
	b:Text("- 마법책처럼 보호된 창은 전투 중에는 옮길 수 없어요.\n"
		.. "- 전체 화면으로 키운 지도는 옮기지 않습니다.",
		{ color = { 0.7, 0.7, 0.7 } })
end
