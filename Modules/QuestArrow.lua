-- 퀘스트 방향 화살표: 추적 중인 퀘스트(또는 지도 핀) 쪽을 가리키는 화살표와 거리를 캐릭터 근처에 띄운다.
-- 미니맵 가장자리에 뜨는 추적 화살표와 같은 목표를 가리킨다.
--
-- 포에버는 리테일의 "게임 내 길 안내"(Blizzard_QuestNavigation)를 설정 화면에서 빼 두어서, 목표 좌표를 직접 구한다.
--   1) C_Navigation.GetNextWaypointForMap(지도): 추적 중인 대상(퀘스트, 지도 핀 등)의 다음 목표
--   2) 추적 퀘스트: C_QuestLog.GetNextWaypointForMap / C_QuestLog.GetQuestsOnMap
--   3) 지도 핀: C_Map.GetUserWaypoint
-- 방향은 지도 좌표 차이를 지도의 실제 크기(GetMapWorldSize)로 바꿔 계산하고, 캐릭터가 보는 방향(GetPlayerFacing)을 뺀다.
-- 거리는 게임 단위를 그대로 쓴다. (한국어 클라이언트가 주문 사거리 등에 "미터"로 표시하는 값과 같다)
-- 화살표 그림(Navigation-Tracked-Arrow)은 위쪽을 가리키고, SetRotation은 시계 반대 방향으로 돌린다.

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local M = ns:NewModule("QuestArrow", {
	title = "퀘스트 방향 화살표",
	category = "quest",
	icon = "Interface\\Icons\\INV_Ammo_Arrow_01",
	order = 35,
	defaults = {
		enabled = true,
		showDistance = true,
		scale = 1,
		point = "CENTER", relPoint = "CENTER", x = 0, y = -120,
	},
})

local ARROW_ATLAS = "Navigation-Tracked-Arrow"
local FALLBACK_ARROW = "Interface\\Minimap\\MinimapArrow"
local ARROW_SIZE = 44
local DRAW_INTERVAL = 0.03     -- 화살표 방향 갱신 (돌 때 부드럽게)
local TARGET_INTERVAL = 0.5    -- 목표 좌표 다시 찾기
local ARRIVED = 10             -- 이 거리 안이면 초록색
local MAX_PARENT_LEVELS = 3    -- 동굴 같은 작은 지도에서 목표가 안 잡히면 상위 지도로 올라가 본다

local db
local moveMode = false
local target   -- { mapID =, x =, y =, w =, h = }

---------------------------------------------------------------------------
-- 화면
---------------------------------------------------------------------------
local frame = CreateFrame("Frame", "EzyWOWFQuestArrow", UIParent)
frame:SetSize(ARROW_SIZE + 12, ARROW_SIZE + 12)
frame:SetFrameStrata("LOW")
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:EnableMouse(false)
frame:RegisterForDrag("LeftButton")
frame:Hide()

local arrow = frame:CreateTexture(nil, "ARTWORK")
arrow:SetPoint("CENTER")
local atlasInfo = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(ARROW_ATLAS)
if atlasInfo and atlasInfo.width and atlasInfo.width > 0 then
	arrow:SetAtlas(ARROW_ATLAS)
	local k = ARROW_SIZE / math.max(atlasInfo.width, atlasInfo.height)
	arrow:SetSize(atlasInfo.width * k, atlasInfo.height * k)
else
	arrow:SetTexture(FALLBACK_ARROW)
	arrow:SetSize(ARROW_SIZE, ARROW_SIZE)
end

local distText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
distText:SetPoint("TOP", frame, "BOTTOM", 0, 4)

local moveTint = frame:CreateTexture(nil, "OVERLAY")
moveTint:SetAllPoints()
moveTint:SetColorTexture(0, 1, 0, 0.25)
moveTint:Hide()

local function FormatDistance(dist)
	if dist >= 1000 then return ("%.1fkm"):format(dist / 1000) end
	return ("%dm"):format(math.floor(dist + 0.5))
end

---------------------------------------------------------------------------
-- 목표 찾기
---------------------------------------------------------------------------
local function PlayerPos(mapID)
	local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
	if not ok or not pos then return nil end
	local x, y = Clean(pos.x), Clean(pos.y)
	if not x or not y or (x == 0 and y == 0) then return nil end
	return x, y
end

local function Point(x, y)
	x, y = Clean(x), Clean(y)
	if x and y and (x ~= 0 or y ~= 0) then return x, y end
end

local function WaypointOnMap(mapID)
	if C_Navigation and C_Navigation.GetNextWaypointForMap then
		local ok, x, y = pcall(C_Navigation.GetNextWaypointForMap, mapID)
		if ok then
			x, y = Point(x, y)
			if x then return x, y end
		end
	end

	local questID = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and Clean(C_SuperTrack.GetSuperTrackedQuestID())
	if questID and questID > 0 then
		local ok, x, y = pcall(C_QuestLog.GetNextWaypointForMap, questID, mapID)
		if ok then
			x, y = Point(x, y)
			if x then return x, y end
		end
		local okList, quests = pcall(C_QuestLog.GetQuestsOnMap, mapID)
		if okList and type(quests) == "table" then
			for _, info in ipairs(quests) do
				if info.questID == questID then
					x, y = Point(info.x, info.y)
					if x then return x, y end
				end
			end
		end
	end

	if C_SuperTrack and C_SuperTrack.IsSuperTrackingUserWaypoint and C_SuperTrack.IsSuperTrackingUserWaypoint() then
		local point = C_Map.GetUserWaypoint and C_Map.GetUserWaypoint()
		if point and point.uiMapID == mapID and point.position then
			return Point(point.position.x, point.position.y)
		end
	end
end

local function FindTarget()
	local mapID = C_Map.GetBestMapForUnit("player")
	for _ = 1, MAX_PARENT_LEVELS do
		if not mapID or mapID == 0 then return nil end
		local x, y = WaypointOnMap(mapID)
		if x and PlayerPos(mapID) then
			local w, h = C_Map.GetMapWorldSize(mapID)
			w, h = Clean(w), Clean(h)
			if w and h and w > 0 and h > 0 then
				return { mapID = mapID, x = x, y = y, w = w, h = h }
			end
		end
		local info = C_Map.GetMapInfo(mapID)
		mapID = info and info.parentMapID
	end
end

---------------------------------------------------------------------------
-- 그리기
---------------------------------------------------------------------------
-- 마지막으로 넣은 값. 화살표와 거리 글자는 Draw만 건드리니 같은 값이면 다시 안 넣는다.
local shownRot, shownGreen, shownText

local function SetArrow(rot, green)
	if rot ~= shownRot then
		shownRot = rot
		arrow:SetRotation(rot)
	end
	if green ~= shownGreen then
		shownGreen = green
		if green then
			arrow:SetVertexColor(0.3, 1, 0.3)
		else
			arrow:SetVertexColor(1, 1, 1)
		end
	end
end

local function SetDistText(text)
	if text ~= shownText then
		shownText = text
		distText:SetText(text)
	end
end

local function Draw()
	if moveMode then
		SetArrow(0, false)
		SetDistText(db.showDistance and "123m" or "")
		frame:Show()
		return
	end

	local facing = Clean(GetPlayerFacing())
	local px, py
	if target then px, py = PlayerPos(target.mapID) end
	if not (facing and px) then
		frame:Hide()
		return
	end

	local dx = (target.x - px) * target.w   -- 동쪽이 +
	local dy = (target.y - py) * target.h   -- 남쪽이 +
	local dist = math.sqrt(dx * dx + dy * dy)
	local bearing = math.atan2(-dx, -dy)    -- 북쪽이 0, 시계 반대 방향이 + (GetPlayerFacing과 같은 기준)

	SetArrow(bearing - facing, dist <= ARRIVED)
	SetDistText(db.showDistance and FormatDistance(dist) or "")
	frame:Show()
end

-- 목표가 있거나 이동 모드일 때만 매 프레임 돈다. 목표가 없으면 잠들고 타이머가 0.5초마다 찾아본다.
local driver = CreateFrame("Frame")
local sinceTarget, sinceDraw = TARGET_INTERVAL, 0
local awake = false   -- driver에 OnUpdate가 걸려 있는지
local ticker          -- 잠든 동안 목표를 찾는 타이머. 켜져 있을 때만 있다
local OnUpdate

local function Sleep()
	awake = false
	driver:SetScript("OnUpdate", nil)
end

-- 목표는 다음 프레임에 찾는다. 이벤트 순간엔 길 안내 정보가 아직 안 바뀌었을 수 있다.
local function Wake()
	sinceTarget = TARGET_INTERVAL
	if not awake then
		awake = true
		sinceDraw = DRAW_INTERVAL   -- 찾은 그 프레임에 바로 그린다
		driver:SetScript("OnUpdate", OnUpdate)
	end
end

function OnUpdate(_, elapsed)
	sinceTarget = sinceTarget + elapsed
	if sinceTarget >= TARGET_INTERVAL then
		sinceTarget = 0
		target = FindTarget()
		if not target and not moveMode then
			frame:Hide()   -- 목표가 없으면 Draw를 불러 봐야 숨기기만 한다
			Sleep()
			return
		end
	end
	sinceDraw = sinceDraw + elapsed
	if sinceDraw >= DRAW_INTERVAL then
		sinceDraw = 0
		Draw()
	end
end

-- 잠든 동안 타이머가 부른다. 찾으면 깨어나서 그 자리에서 그린다.
local function Poll()
	if awake then return end
	target = FindTarget()
	if target then
		awake = true
		sinceTarget, sinceDraw = 0, 0
		driver:SetScript("OnUpdate", OnUpdate)
		Draw()
	end
end

local function ApplyPosition()
	frame:ClearAllPoints()
	frame:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
	frame:SetScale(db.scale)
end

local function Update()
	ApplyPosition()
	frame:EnableMouse(moveMode)
	moveTint:SetShown(moveMode)
	if db.enabled then
		if not ticker then
			-- 콜백이 한 번 터졌다고 타이머째 죽으면 곤란하다. 오류는 그대로 보고된다.
			ticker = C_Timer.NewTicker(TARGET_INTERVAL, function() xpcall(Poll, ns.ErrorHandler) end)
		end
		Wake()
	else
		if ticker then
			ticker:Cancel()
			ticker = nil
		end
		Sleep()
		frame:Hide()
	end
end

-- 추적 대상이 바뀌면 바로 다시 찾는다. 로드 전(db 없음)이나 꺼져 있을 땐 무시.
for _, event in ipairs({
	"SUPER_TRACKING_CHANGED", "QUEST_LOG_UPDATE", "USER_WAYPOINT_UPDATED",
	"ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD",
}) do
	ns:RegisterEvent(event, function()
		if db and db.enabled then Wake() end
	end)
end

---------------------------------------------------------------------------
-- 위치 이동
---------------------------------------------------------------------------
frame:SetScript("OnDragStart", function(self)
	if moveMode then self:StartMoving() end
end)

frame:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, relPoint, x, y = self:GetPoint(1)
	db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end)

local function SetMoveMode(on)
	if on and not db.enabled then
		Print("퀘스트 방향 화살표가 꺼져 있어요.")
		return
	end
	moveMode = on
	Update()
	ns:Fire("REFRESH_UI")
	if on then Print("화살표를 드래그해서 옮기세요. 다 옮기면 [이동 완료]를 누르세요.") end
end

local function ResetPosition()
	local d = M.defaults
	db.point, db.relPoint, db.x, db.y = d.point, d.relPoint, d.x, d.y
	ApplyPosition()
	Print("화살표를 캐릭터 아래 기본 위치로 되돌렸습니다.")
end

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	Update()
end

function M:ApplySettings(changes)
	if changes.enabled == false then moveMode = false end
	Update()
end

function M:BuildOptions(b)
	local function Disabled() return not db.enabled end

	b:Text("추적 중인 퀘스트(미니맵 가장자리에 화살표가 뜨는 목표)나 지도 핀 쪽을 가리키는 화살표를 캐릭터 근처에 띄웁니다. "
		.. "화살표는 캐릭터가 보는 방향 기준이라, 화살표가 위를 가리키면 앞으로 가면 됩니다. 가까워지면 초록색이 됩니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Check{ key = "showDistance", label = "거리 표시 (m)", depends = "enabled", indent = 20 }
	b:Slider{ key = "scale", label = "크기", min = 0.5, max = 2, step = 0.05, format = "%.2f", depends = "enabled" }
	b:Buttons{
		{
			text = "위치 이동",
			textFunc = function() return moveMode and "이동 완료" or "위치 이동" end,
			onClick = function() SetMoveMode(not moveMode) end,
			disabled = Disabled,
		},
		{ text = "기본 위치로", onClick = ResetPosition, disabled = Disabled },
	}
	b:Text("- 기본 위치는 화면 가운데 조금 아래(캐릭터 발밑 근처)입니다. 카메라 거리에 따라 [위치 이동]으로 맞추세요.\n"
		.. "- 던전 안처럼 내 위치를 알 수 없는 곳에서는 보이지 않습니다.",
		{ color = { 0.7, 0.7, 0.7 } })
end
