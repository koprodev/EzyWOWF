-- 툴팁 위치: 화면 오른쪽 아래 기본 자리에 뜨던 툴팁을 커서 위나 직접 정한 자리로 옮긴다.
-- 블리자드 GameTooltip_SetDefaultAnchor 뒤에 붙는 훅이라, 가방 아이템처럼 자기 옆에 툴팁을 띄우는 곳은 건드리지 않는다.
--   커서 위: ANCHOR_CURSOR. 툴팁 아래쪽 가운데가 커서에 붙어 따라다닌다.
--   지정 위치: 저장한 "화면 모서리 + 거리". 툴팁도 같은 모서리로 붙어서 화면 안쪽으로 자란다.
-- 옮긴 GameTooltip은 작게 줄일 수 있다. 다른 코드가 툴팁을 가져가거나 닫히면 원래 크기로 돌려놓는다.

local _, ns = ...
local Print = ns.Print
local Clean = ns.Clean

local M = ns:NewModule("TooltipPosition", {
	title = "툴팁 위치",
	category = "item",
	icon = "Interface\\Icons\\INV_Misc_Note_02",
	order = 51,
	defaults = {
		enabled = true,
		mode = "cursor",                       -- cursor | fixed
		point = "BOTTOMRIGHT", x = -9, y = 85,  -- 지정 위치. 처음엔 게임 기본 자리와 같다
		scale = 80,                            -- 옮긴 툴팁 크기 (%)
	},
})

local MODES = {
	{ value = "cursor", text = "커서 위 (마우스를 따라감)" },
	{ value = "fixed",  text = "지정 위치 (직접 옮기기)" },
}

local db
local moveMode = false
local placed   -- GameTooltip을 우리가 옮긴 방식: "cursor" | "fixed" | nil

---------------------------------------------------------------------------
-- 크기
---------------------------------------------------------------------------
local scaled, baseScale = false, 1   -- 우리가 줄였는지, 줄이기 전 크기

local function PositiveScale(frame)
	local s = Clean(frame:GetScale())
	return (type(s) == "number" and s > 0) and s or 1
end

local function WantedScale()
	local pct = tonumber(db.scale) or 100
	if pct >= 100 then return 1 end
	return math.max(pct, 50) / 100
end

-- 남이 툴팁을 가져가거나 닫히면 원래대로. 안 그러면 가방 툴팁까지 쪼그라든 채 남는다
local function RestoreScale()
	if not scaled then return end
	scaled = false
	GameTooltip:SetScale(baseScale)
end

-- 0.2초마다 기본 자리를 다시 잡아도 0.8 × 0.8 × … 로 녹아내리지 않게 기준 크기는 처음 한 번만 잰다
local function ApplyScale()
	local s = WantedScale()
	if s == 1 then return RestoreScale() end
	if not scaled then
		baseScale = PositiveScale(GameTooltip)
		scaled = true
	end
	GameTooltip:SetScale(baseScale * s)
end

---------------------------------------------------------------------------
-- 기본 자리 훅
---------------------------------------------------------------------------
-- SetPoint 거리는 툴팁 자기 크기 단위라 나눠 줘야 상자 모서리에 딱 붙는다
local function PlaceFixed(tooltip)
	local s = PositiveScale(tooltip)
	tooltip:ClearAllPoints()
	tooltip:SetPoint(db.point, UIParent, db.point, db.x / s, db.y / s)
end

-- 블리자드가 ANCHOR_NONE으로 기본 자리를 막 잡은 툴팁만 옮긴다. 금지된(forbidden) 프레임은 건드리면 오류라 비켜 간다.
local function OnDefaultAnchor(tooltip, parent)
	if not (db and db.enabled) or tooltip:IsForbidden() then return end
	if tooltip.GetAnchorType and tooltip:GetAnchorType() ~= "ANCHOR_NONE" then return end
	local main = tooltip == GameTooltip   -- 다른 툴팁은 크기 그대로
	if db.mode == "fixed" then
		if main then ApplyScale() placed = "fixed" end
		PlaceFixed(tooltip)
	elseif parent and not parent:IsForbidden() then
		tooltip:SetOwner(parent, "ANCHOR_CURSOR")
		if main then ApplyScale() placed = "cursor" end   -- SetOwner 훅이 지우고 되돌리므로 반드시 이 뒤에
	end
end

-- 남이 툴팁을 가져가거나(가방·버튼) 닫히면 우리 몫은 끝
local function Release()
	placed = nil
	RestoreScale()
end

-- 장비 비교 툴팁은 GameTooltip 크기를 모른 채 자리를 계산해서 어긋난다. 비교가 뜰 아이템이면 먼저 원래 크기로.
local function OnItemTooltip(tooltip)
	if tooltip ~= GameTooltip or not scaled then return end
	local info = tooltip.GetProcessingTooltipInfo and tooltip:GetProcessingTooltipInfo()
	local compare = (info and info.compareItem)
		or (TooltipUtil and TooltipUtil.ShouldDoItemComparison and TooltipUtil.ShouldDoItemComparison(tooltip))
	if not compare then return end
	RestoreScale()
	if placed == "fixed" then PlaceFixed(tooltip) end
end

-- 블리자드는 기본 자리 툴팁을 서서히 지우는데, 커서에 붙여 놓으면 지워지는 동안 커서를 따라다닌다. 블리자드 커서 툴팁처럼 바로 숨긴다.
local function OnFadeOut(tooltip)
	if placed == "cursor" then tooltip:Hide() end
end

if type(GameTooltip_SetDefaultAnchor) == "function" then
	hooksecurefunc("GameTooltip_SetDefaultAnchor", OnDefaultAnchor)
end
if GameTooltip then
	hooksecurefunc(GameTooltip, "SetOwner", Release)
	GameTooltip:HookScript("OnHide", Release)
	if GameTooltip.FadeOut then hooksecurefunc(GameTooltip, "FadeOut", OnFadeOut) end
end
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPreCall and Enum and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPreCall(Enum.TooltipDataType.Item, OnItemTooltip)
end

---------------------------------------------------------------------------
-- 지정 위치 상자 (위치 이동 중에만 보인다)
---------------------------------------------------------------------------
local box = CreateFrame("Frame", "EzyWOWFTooltipMover", UIParent)
box:SetSize(220, 80)
box:SetFrameStrata("DIALOG")
box:SetMovable(true)
box:SetClampedToScreen(true)
if box.SetDontSavePosition then box:SetDontSavePosition(true) end
box:EnableMouse(true)
box:RegisterForDrag("LeftButton")
box:Hide()

local tint = box:CreateTexture(nil, "BACKGROUND")
tint:SetAllPoints()
tint:SetColorTexture(0, 1, 0, 0.3)

local label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
label:SetPoint("CENTER")
label:SetText("툴팁 위치\n노란 모서리에 툴팁이 붙어요\n끌어서 옮기세요")

local mark = box:CreateTexture(nil, "OVERLAY")
mark:SetSize(12, 12)
mark:SetColorTexture(1, 0.82, 0, 1)

-- 상자가 화면의 어느 쪽 절반에 있느냐로 모서리를 고른다. 위쪽이면 툴팁이 아래로 자라서 화면 밖으로 안 나간다.
local function NearestCorner()
	local x, y = box:GetCenter()
	local w, h = UIParent:GetWidth(), UIParent:GetHeight()
	if not (x and y and w and h and w > 0 and h > 0) then return db.point end
	return (y > h / 2 and "TOP" or "BOTTOM") .. (x > w / 2 and "RIGHT" or "LEFT")
end

local function PlaceMark(corner)
	mark:ClearAllPoints()
	mark:SetPoint(corner, box, corner)
end

local function PlaceBox()
	box:ClearAllPoints()
	box:SetPoint(db.point, UIParent, db.point, db.x, db.y)
	PlaceMark(db.point)
end

-- 놓은 자리를 가까운 화면 모서리 기준 거리로 바꿔 저장한다. 해상도가 바뀌어도 그 모서리에 붙어 있게.
local function SaveBox()
	local left, right, top, bottom = box:GetLeft(), box:GetRight(), box:GetTop(), box:GetBottom()
	if not (left and right and top and bottom) then return end
	local corner = NearestCorner()
	local x = corner:find("LEFT") and left or right - UIParent:GetWidth()
	local y = corner:find("BOTTOM") and bottom or top - UIParent:GetHeight()
	db.point, db.x, db.y = corner, math.floor(x + 0.5), math.floor(y + 0.5)
	PlaceBox()
end

local function FollowCorner() PlaceMark(NearestCorner()) end

box:SetScript("OnDragStart", function(self)
	self:StartMoving()
	self:SetScript("OnUpdate", FollowCorner)   -- 끄는 동안만 모서리 표시를 따라 옮긴다
end)

box:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	self:SetScript("OnUpdate", nil)
	SaveBox()
end)

local function SetMoveMode(on)
	moveMode = on
	if on then PlaceBox() end
	box:SetShown(on)
	ns:Fire("REFRESH_UI")
	if on then Print("초록 상자를 끌어서 툴팁 자리를 정하세요. 다 옮기면 [이동 완료]를 누르세요.") end
end

local function ResetPosition()
	local d = M.defaults
	db.point, db.x, db.y = d.point, d.x, d.y
	PlaceBox()
	Print("툴팁 자리를 게임 기본 자리(화면 오른쪽 아래)로 되돌렸습니다.")
end

-- 저장 전 값 기준이라 드롭다운에서 지정 위치를 고르면 바로 옮길 수 있다
local function CanMove()
	return ns:GetSetting(M, "enabled") and ns:GetSetting(M, "mode") == "fixed"
end

-- [되돌리기]·[버리기]로 지정 위치가 취소되면 초록 상자도 치운다 (안 그러면 화면에 남아 클릭을 막는다)
ns:On("PENDING_CHANGED", function()
	if moveMode and not CanMove() then SetMoveMode(false) end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
end

function M:ApplySettings()
	if moveMode and not CanMove() then SetMoveMode(false) end
	if not db.enabled or WantedScale() == 1 then RestoreScale() end   -- 새 크기는 다음에 뜰 때부터
end

function M:BuildOptions(b)
	b:Text("마우스를 올렸을 때 화면 오른쪽 아래 기본 자리에 뜨는 툴팁(몹, 플레이어, 물체 등)의 위치를 바꿉니다. "
		.. "가방 아이템처럼 자기 바로 옆에 툴팁을 띄우는 곳은 그대로입니다.")
	b:Check{ key = "enabled", label = "사용",
		tooltip = "끄면 게임 기본 자리로 돌아갑니다. 기본 자리는 편집 모드의 'HUD 툴팁'으로 옮길 수 있어요." }
	b:Dropdown{ key = "mode", label = "툴팁 위치", depends = "enabled", width = 220,
		options = function() return MODES end }
	b:Slider{ key = "scale", label = "툴팁 크기", min = 50, max = 100, step = 5, format = "%d%%", depends = "enabled",
		tooltip = "커서 위·지정 위치로 옮긴 툴팁만 작아집니다. 가방 아이템처럼 자기 옆에 뜨는 툴팁은 원래 크기이고, "
			.. "장비 비교 툴팁이 함께 뜰 때는(Shift 등) 자리가 어긋나지 않게 원래 크기로 돌아갑니다." }
	b:Buttons{
		{
			text = "위치 이동",
			textFunc = function() return moveMode and "이동 완료" or "위치 이동" end,
			onClick = function() SetMoveMode(not moveMode) end,
			disabled = function() return not moveMode and not CanMove() end,
			tooltip = "초록 상자를 끌어서 툴팁 자리를 정합니다. 상자 위치는 옮기는 즉시 저장됩니다.",
		},
		{ text = "기본 위치로", onClick = ResetPosition, disabled = function() return not CanMove() end },
	}
	b:Text("- 커서 위: 툴팁 아래쪽 가운데가 마우스 커서에 붙어서 따라다니고, 대상에서 마우스를 떼면 바로 사라집니다.\n"
		.. "- 지정 위치: 상자의 노란 모서리에 툴팁이 붙습니다. 상자를 화면 위쪽에 두면 툴팁이 아래로, 아래쪽에 두면 위로 자랍니다.\n"
		.. "- 툴팁 크기: 100%면 원래 크기입니다. 바꾼 크기는 다음에 뜨는 툴팁부터 적용됩니다.\n"
		.. "- [사용], [툴팁 위치], [툴팁 크기]는 [저장]을 눌러야 적용됩니다.",
		{ color = { 0.7, 0.7, 0.7 } })
end
