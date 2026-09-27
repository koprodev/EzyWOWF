-- 미니맵: 네모 모양, 크기, 네모에 맞춘 주변 버튼 배치.
--
-- 크기는 Minimap 프레임 자체의 크기를 바꾼다(ElvUI와 같은 방식). 편집 모드가 관리하는
-- MinimapCluster·MinimapContainer는 건드리지 않는다.
--   꽉 차게(기본): 편집 모드의 미니맵 상자(MinimapCluster)에서 지역 이름 줄을 뺀 영역을 지도가 채운다.
--     상자 크기는 편집 모드의 미니맵 "크기"로 바뀌고, 지도는 상자 크기가 바뀔 때마다 다시 맞춘다.
--     (상자는 직접 자식 프레임 크기로만 계산되고 Minimap은 손자 프레임이라, 지도를 키워도 상자가 따라 커지지 않는다)
--   직접 크기: 설정의 크기 값을 쓴다. 편집 모드 배율은 그 위에 곱해진다.
-- 모양이나 크기가 바뀌면 "MINIMAP_LAYOUT_CHANGED"를 보내서 미니맵 버튼·정보 막대·추적 아이콘이 자리를 다시 잡게 한다.
--
-- 와우 포에버(게임 타입 Camelot) UI 참고 (wow-ui-source의 forever 브랜치, Blizzard_Minimap\Camelot):
--   Skin.lua: 둥근 마스크(아틀라스)와 테두리 크기를 정한다. 미니맵 회전(rotateMinimap)이 바뀌면 다시 걸기 때문에
--             CVAR_UPDATE 때 우리 설정을 다시 적용한다.
--   Diel.lua: 낮/밤 아이콘(MinimapCluster.DielFrame). SetEditModeScale에서 CENTER 기준으로 자리를 다시 잡는다.
--   Minimap.xml: 좌표 표시(MinimapContainer.PlayerCoords)가 지도 밑에 붙어 있다.

local _, ns = ...

local M = ns:NewModule("Minimap", {
	title = "미니맵",
	category = "map",
	icon = "Interface\\Icons\\Ability_Hunter_Pathfinding",
	order = 5,
	defaults = {
		square = true,
		fill = true,
		size = 198,
		outsideParts = true,
		coordsInside = true,
	},
})

local DEFAULT_SIZE = 198
local FILL_PAD = 3       -- 꽉 차게: 상자 가장자리와 지도 사이 (화면 픽셀)
local OUTSIDE_GAP = 2    -- 바깥으로 옮긴 버튼과 지도 사이
local COORDS_INSET = 4   -- 지도 안쪽 위로 옮긴 좌표와 지도 윗변 사이
local SQUARE_MASK = "Interface\\BUTTONS\\WHITE8X8"
local FOREVER_ROUND_MASK = "ui-hud-minimap-frame-generic-mask"   -- 포에버 Skin.lua의 원형 마스크 (아틀라스)
local CLASSIC_ROUND_MASK = "Textures\\MinimapMask"
local HYBRID_ROUND_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local DIEL_X, DIEL_Y = 63, 72   -- 포에버 Diel.lua의 낮/밤 아이콘 기본 위치 (상자 가운데 기준)

local db
local squareApplied = false   -- 이번 접속에서 네모로 바꾼 적이 있으면 둥글게 되돌릴 때만 원형 마스크를 다시 건다
local partsMoved = false      -- 낮/밤 아이콘과 확대·축소 버튼을 옮겨 둔 상태인지
local coordsMoved = false     -- 좌표를 지도 안쪽 위로 옮겨 둔 상태인지
local appliedSize
local originalGetShape = GetMinimapShape
local function SquareShape() return "SQUARE" end

function ns.IsMinimapSquare()
	return db ~= nil and db.square
end

---------------------------------------------------------------------------
-- 블리자드가 정해 둔 크기·위치 (되돌릴 때 쓴다)
---------------------------------------------------------------------------
local compassW, compassH = 215, 226
if MinimapCompassTexture then
	local w, h = MinimapCompassTexture:GetSize()
	if w and w > 0 then compassW, compassH = w, h end
end

local function SaveAnchors(frame)
	local points = {}
	for i = 1, frame:GetNumPoints() do points[i] = { frame:GetPoint(i) } end
	return { points = points, w = frame:GetWidth(), h = frame:GetHeight() }
end

local function RestoreAnchors(frame, saved)
	frame:ClearAllPoints()
	for _, p in ipairs(saved.points) do frame:SetPoint(unpack(p)) end
	frame:SetSize(saved.w, saved.h)
end

local zoomIn, zoomOut, zoomHit = Minimap.ZoomIn, Minimap.ZoomOut, Minimap.ZoomHitArea
local zoomSaved = (zoomIn and zoomOut and zoomHit) and {
	[zoomIn] = SaveAnchors(zoomIn),
	[zoomOut] = SaveAnchors(zoomOut),
	[zoomHit] = SaveAnchors(zoomHit),
}

-- 확대·축소 버튼이 지도 오른쪽 아래 모서리 밑에 나와 있는지 (추적 아이콘이 그 자리를 비워 둔다)
function ns.IsMinimapZoomOutside()
	return partsMoved and zoomSaved and true or false
end

-- 포에버의 좌표 표시 (지도 밑 -18). MinimapContainer의 자식이라 Minimap과 같은 층에 있다.
local coords = MinimapCluster and MinimapCluster.MinimapContainer and MinimapCluster.MinimapContainer.PlayerCoords
local coordsSaved = coords and SaveAnchors(coords)
local coordsLevel = coords and coords:GetFrameLevel()

local border = CreateFrame("Frame", nil, Minimap, "BackdropTemplate")
border:SetPoint("TOPLEFT", -1, 1)
border:SetPoint("BOTTOMRIGHT", 1, -1)
border:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
border:SetBackdropBorderColor(0, 0, 0, 1)
border:Hide()

-- 편집 모드의 "이름 줄을 아래에" 설정이면 컨테이너가 상자 아래쪽에 붙는다.
local function HeaderUnderneath()
	return Minimap:GetParent():GetPoint(1) == "BOTTOM"
end

---------------------------------------------------------------------------
-- 크기와 위치
---------------------------------------------------------------------------
-- 직접 크기: 커질 때 이름 줄을 덮지 않도록 이름 줄 쪽 가장자리를 고정하고 반대쪽으로 늘린다.
local function ApplyCustom()
	local container = Minimap:GetParent()
	local gap = math.max(0, (container:GetHeight() - DEFAULT_SIZE) / 2)
	Minimap:SetSize(db.size, db.size)
	Minimap:ClearAllPoints()
	if db.size == DEFAULT_SIZE then
		Minimap:SetPoint("CENTER", container, "CENTER")
	elseif HeaderUnderneath() then
		Minimap:SetPoint("BOTTOM", container, "BOTTOM", 0, gap)
	else
		Minimap:SetPoint("TOP", container, "TOP", 0, -gap)
	end
	return db.size
end

-- 꽉 차게: 상자와 이름 줄의 화면 위치로 지도 크기와 자리를 정한다. 아직 위치를 모르면 nil.
local function ApplyFill()
	local cluster = MinimapCluster
	if not (cluster and cluster.BorderTop) or Minimap:GetParent() ~= cluster.MinimapContainer then return nil end

	local cs = cluster:GetEffectiveScale()
	local left, right, top, bottom = cluster:GetLeft(), cluster:GetRight(), cluster:GetTop(), cluster:GetBottom()
	if not (left and right and top and bottom) then return nil end
	left, right, top, bottom = left * cs, right * cs, top * cs, bottom * cs
	local originX, originY = left, top   -- 상자 왼쪽 위 (지도를 여기에 대고 붙인다)

	local header = cluster.BorderTop
	local hs = header:GetEffectiveScale()
	local headerTop, headerBottom = header:GetTop(), header:GetBottom()
	if header:IsShown() and headerTop and headerBottom then
		if HeaderUnderneath() then
			bottom = headerTop * hs
		else
			top = headerBottom * hs
		end
	end

	local sizePx = math.min(right - left, top - bottom) - FILL_PAD * 2
	if sizePx < 50 then return nil end

	local ms = Minimap:GetEffectiveScale()
	local size = sizePx / ms
	local centerX, centerY = (left + right) / 2, (top + bottom) / 2
	Minimap:SetSize(size, size)
	Minimap:ClearAllPoints()
	Minimap:SetPoint("CENTER", cluster, "TOPLEFT", (centerX - originX) / ms, (centerY - originY) / ms)
	return size
end

---------------------------------------------------------------------------
-- 모양
---------------------------------------------------------------------------
local function RoundMask()
	if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(FOREVER_ROUND_MASK) then
		return FOREVER_ROUND_MASK
	end
	return CLASSIC_ROUND_MASK
end

-- 일부 지역에서 쓰는 보조 미니맵(HybridMinimap)은 자기 마스크를 따로 가진다.
local function ApplyMask()
	Minimap:SetMaskTexture(db.square and SQUARE_MASK or RoundMask())
	if HybridMinimap and HybridMinimap.CircleMask then
		HybridMinimap.CircleMask:SetTexture(db.square and SQUARE_MASK or HYBRID_ROUND_MASK,
			"CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	end
end

local function RotateMinimap()
	return C_CVar and C_CVar.GetCVarBool and C_CVar.GetCVarBool("rotateMinimap") or false
end

local function ApplyShape(size)
	if db.square or squareApplied then
		ApplyMask()
		border:SetShown(db.square)
		GetMinimapShape = db.square and SquareShape or originalGetShape
		squareApplied = db.square
	end
	-- 둥근 테두리는 크기가 고정이라 지도 크기에 맞춰 늘린다.
	local k = size / DEFAULT_SIZE
	if MinimapCompassTexture then
		MinimapCompassTexture:SetShown(not db.square)
		MinimapCompassTexture:SetSize(compassW * k, compassH * k)
	end
	-- 포에버의 회전 미니맵용 원형 받침
	if MinimapCompassTextureUnderlay then
		MinimapCompassTextureUnderlay:SetShown(not db.square and RotateMinimap())
		MinimapCompassTextureUnderlay:SetSize(compassW * k, compassH * k)
	end
end

---------------------------------------------------------------------------
-- 낮/밤 아이콘과 확대·축소 버튼
-- 둥근 테두리에 맞춰 놓여 있어서 네모 지도에서는 지도 안쪽을 가린다.
--   낮/밤 아이콘: 지도 왼쪽 바깥, 아래쪽 (왼쪽 위는 버프 아이콘, 지도 바로 밑은 퀘스트 목표 창과 겹치기 쉽다)
--   확대·축소: 오른쪽 아래 모서리 바로 밑에 [-][+]. 지도에 마우스를 올렸을 때만 보이는 건 그대로.
---------------------------------------------------------------------------
local function PlaceParts(outside)
	local diel = MinimapCluster and MinimapCluster.DielFrame
	if diel then
		if outside then
			-- CENTER로 잡아야 블리자드가 CENTER로 자리를 다시 잡을 때 기준점이 둘로 겹치지 않는다.
			local w, h = diel:GetSize()
			diel:ClearAllPoints()
			diel:SetPoint("CENTER", Minimap, "BOTTOMLEFT", -(w / 2 + OUTSIDE_GAP), h / 2)
		elseif partsMoved then
			local k = math.min(1, MinimapCluster.MinimapContainer:GetScale())
			diel:ClearAllPoints()
			diel:SetPoint("CENTER", DIEL_X * k, DIEL_Y * k)
		end
	end

	if zoomSaved then
		if outside then
			zoomIn:ClearAllPoints()
			zoomIn:SetPoint("TOPRIGHT", Minimap, "BOTTOMRIGHT", 0, -OUTSIDE_GAP)
			zoomOut:ClearAllPoints()
			zoomOut:SetPoint("RIGHT", zoomIn, "LEFT", -4, 0)
			-- 지도에서 버튼으로 마우스를 옮기는 동안 버튼이 사라지지 않게 사이를 메운다.
			zoomHit:ClearAllPoints()
			zoomHit:SetPoint("TOPRIGHT", Minimap, "BOTTOMRIGHT", 0, 2)
			zoomHit:SetSize(zoomIn:GetWidth() + zoomOut:GetWidth() + 12, zoomIn:GetHeight() + OUTSIDE_GAP + 4)
		elseif partsMoved then
			for frame, saved in pairs(zoomSaved) do RestoreAnchors(frame, saved) end
		end
	end

	partsMoved = outside
end

-- 좌표: 지도 안쪽 위 가운데. 지도 그림에 가리지 않게 층을 올린다.
local function PlaceCoords(inside)
	if not coordsSaved then return end
	if inside then
		coords:ClearAllPoints()
		coords:SetPoint("TOP", Minimap, "TOP", 0, -COORDS_INSET)
		coords:SetFrameLevel(Minimap:GetFrameLevel() + 5)
	elseif coordsMoved then
		RestoreAnchors(coords, coordsSaved)
		coords:SetFrameLevel(coordsLevel)
	end
	coordsMoved = inside
end

-- 블리자드는 지도에서 마우스가 나갈 때만 버튼을 숨긴다. 버튼이 지도 밖에 있으면
-- 버튼에서 바로 다른 곳으로 나갈 수 있으니 그때도 숨긴다.
local function HideZoomIfAway()
	if not partsMoved then return end
	if Minimap:IsMouseOver() or zoomIn:IsMouseOver() or zoomOut:IsMouseOver() or zoomHit:IsMouseOver() then return end
	zoomIn:Hide()
	zoomOut:Hide()
end

if zoomSaved then
	zoomIn:HookScript("OnLeave", HideZoomIfAway)
	zoomOut:HookScript("OnLeave", HideZoomIfAway)
	zoomHit:HookScript("OnLeave", HideZoomIfAway)
end

---------------------------------------------------------------------------
-- 적용
---------------------------------------------------------------------------
local function Apply()
	if not db then return end
	local size = (db.fill and ApplyFill()) or ApplyCustom()
	ApplyShape(size)
	PlaceParts(db.square and db.outsideParts)
	PlaceCoords(db.square and db.coordsInside)

	-- 크기를 바꾼 뒤 지도가 바로 다시 그려지도록 확대 단계를 한 번 흔든다.
	if appliedSize and math.abs(appliedSize - size) > 0.5 then
		local zoom = Minimap:GetZoom()
		Minimap:SetZoom(zoom > 0 and zoom - 1 or zoom + 1)
		Minimap:SetZoom(zoom)
	end
	appliedSize = size

	ns:Fire("MINIMAP_LAYOUT_CHANGED")
end

-- 편집 모드가 상자를 다시 계산하는 도중(크기를 잠깐 1x1로 줄였다 늘림)에는 건너뛰고 다음 프레임에 맞춘다.
local applyQueued = false
local function RequestApply()
	if applyQueued or not db then return end
	applyQueued = true
	C_Timer.After(0, function()
		applyQueued = false
		Apply()
	end)
end

if MinimapCluster then
	if MinimapCluster.SetHeaderUnderneath then
		hooksecurefunc(MinimapCluster, "SetHeaderUnderneath", RequestApply)
	end
	-- 포에버는 이 함수에서 낮/밤 아이콘 자리도 다시 잡는다.
	if MinimapCluster.SetEditModeScale then
		hooksecurefunc(MinimapCluster, "SetEditModeScale", RequestApply)
	end
	MinimapCluster:HookScript("OnSizeChanged", function()
		if db and db.fill then RequestApply() end
	end)
end

ns:RegisterEvent("PLAYER_ENTERING_WORLD", RequestApply)

-- 미니맵 회전을 켜고 끄면 포에버가 둥근 마스크와 테두리를 다시 건다.
ns:RegisterEvent("CVAR_UPDATE", function(_, name)
	if type(name) == "string" and name:lower() == "rotateminimap" then RequestApply() end
end)

ns:RegisterEvent("ADDON_LOADED", function(_, name)
	if name == "Blizzard_HybridMinimap" and db and (db.square or squareApplied) then ApplyMask() end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	Apply()
end

function M:OnLogin()
	Apply()
end

function M:ApplySettings()
	Apply()
end

function M:BuildOptions(b)
	b:Check{ key = "square", label = "네모난 미니맵", tooltip = "둥근 테두리를 없애고 지도를 네모로 보여 줍니다." }
	b:Check{
		key = "outsideParts", label = "낮/밤 아이콘과 확대·축소 버튼을 지도 바깥으로", depends = "square", indent = 20,
		tooltip = "낮/밤 아이콘은 지도 왼쪽 바깥 아래에, 확대·축소 버튼(-, +)은 오른쪽 아래 모서리 밑에 둡니다. "
			.. "확대·축소 버튼은 지금처럼 지도에 마우스를 올렸을 때만 보입니다.",
	}
	b:Check{
		key = "coordsInside", label = "좌표를 지도 안쪽 위 가운데로", depends = "square", indent = 20,
		tooltip = "지도 밑에 있는 게임 기본 좌표를 지도 안쪽 위로 옮깁니다. 지도 밑에는 추적 아이콘이 붙습니다.",
	}
	b:Check{
		key = "fill", label = "기본 UI 상자에 꽉 차게",
		tooltip = "편집 모드의 미니맵 상자에서 지역 이름 줄을 뺀 자리를 지도가 가득 채웁니다. "
			.. "크기는 편집 모드(Esc > 편집 모드 > 미니맵 > 크기)로 조절하세요.",
	}
	b:Slider{
		key = "size", label = "직접 크기 (꽉 차게를 껐을 때)", min = 120, max = 320, step = 2, format = "%d",
		disabled = function() return ns:GetSetting(M, "fill") end,
		tooltip = "기본 198입니다. 편집 모드의 미니맵 크기(배율)는 이 위에 곱해집니다.",
	}
	b:Text("- 미니맵을 크게 하면 아래의 퀘스트 목표 창과 겹칠 수 있어요. 겹치면 편집 모드에서 목표 창을 옮기세요.\n"
		.. ("- 추적 아이콘은 %s에서 미니맵에 붙이거나 떼어 낼 수 있어요.\n"):format(ns:SettingsPath("Tracking"))
		.. "- 네모에서 둥근 모양으로 되돌렸을 때 테두리가 어색하면 /reload 하세요.",
		{ color = { 0.7, 0.7, 0.7 } })
end
