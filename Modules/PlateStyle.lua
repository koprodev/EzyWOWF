-- 이름표 모양: 블리자드 이름표를 납작하고 차분하게, 그리고 그 밑 줄(어그로·내 상태)의 두께·숫자를 한곳에서 정한다.
--
-- 블리자드 막대: 단색 + 회색 빈 트랙 + 딱 맞는 네모 테두리(대상만 밝은 회색). 형광 반응색은 채운 부분 위에 회색을 덮어 누그러뜨리고,
-- 레벨 상자·노란 대상 테두리는 투명하게, 이름은 작게, 시전 바는 체력 바와 같은 폭으로.
-- 이름표는 위치를 잴 수 없는 영역이다(GetWidth·GetBottom 등 측정 금지). 여기서는 붙이기만 하고 재지 않는다.
-- 블리자드는 이름표에 유닛이 붙을 때마다 UpdateAnchors로 모양을 새로 입힌다. 그 직후에 hooksecurefunc로 덧입힌다.
-- 블리자드 값(색·체력 같은 비밀값)은 읽지 않고, 체력 바의 위치(SetPoint)도 안 건드린다.
-- 끄면 블리자드가 모양을 다시 입히는 이름표부터 원래대로. 한 번에 되돌리려면 /reload.

local _, ns = ...

local M = ns:NewModule("PlateStyle", {
	title = "이름표 모양",
	category = "info",
	icon = "Interface\\Icons\\INV_Misc_Note_01",
	order = 34,
	defaults = {
		enabled = true,
		nameScale = 80,     -- 블리자드 이름 크기 대비 %
		barHeight = 4,      -- 어그로·체력·자원 막대
		comboHeight = 6,    -- 연계 점수 칸
		showPercent = false,
	},
})

local FLAT = "Interface\\Buttons\\WHITE8x8"
local MUTE = { 0.35, 0.35, 0.35, 0.55 }        -- 채운 부분 위에 덮는 회색. 빨강(1,0,0) → 약 (0.64, 0.19, 0.19)
local TARGET_BOX = { 0.85, 0.85, 0.85, 1 }     -- 대상 테두리 (무채색)

local Stack = ns.PlateStack
local db
local hooked = {}   -- [유닛 프레임] = true. 이름표 유닛 프레임은 돌려 쓰니 한 번만 건다
local faded = {}    -- [텍스처] = true. 우리가 투명하게 만든 것 (끌 때 되돌림)
local deco = {}     -- [체력 바] = { mute = 텍스처, lines = { 위, 아래, 왼, 오 } }
local boxed         -- 지금 밝은 테두리를 두른 체력 바

local function PlateFor(unit)
	local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
	if not plate or (plate.IsForbidden and plate:IsForbidden()) then return nil end
	return plate
end

local function HealthBarOf(plate)
	local uf = plate and plate.UnitFrame
	return uf and uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar
end

local function Fade(region)
	if region and not faded[region] then
		region:SetAlpha(0)
		faded[region] = true
	end
end

-- 막대 바깥 1px 네 변. 채운 부분과 안 겹치니 층은 상관없다.
local function Decorate(hb)
	local d = deco[hb]
	if d then return d end
	local function Line(p1, x1, y1, p2, x2, y2)
		local t = hb:CreateTexture(nil, "OVERLAY")
		t:SetPoint(p1, hb, p1, x1, y1)
		t:SetPoint(p2, hb, p2, x2, y2)
		return t
	end
	local top = Line("TOPLEFT", -1, 1, "TOPRIGHT", 1, 1)
	top:SetHeight(1)
	local bottom = Line("BOTTOMLEFT", -1, -1, "BOTTOMRIGHT", 1, -1)
	bottom:SetHeight(1)
	local left = Line("TOPLEFT", -1, 1, "BOTTOMLEFT", -1, -1)
	left:SetWidth(1)
	local right = Line("TOPRIGHT", 1, 1, "BOTTOMRIGHT", 1, -1)
	right:SetWidth(1)
	d = { lines = { top, bottom, left, right } }
	if hb.barTexture then
		d.mute = hb:CreateTexture(nil, "ARTWORK", nil, 7)
		d.mute:SetAllPoints(hb.barTexture)   -- 채운 부분만 따라 늘고 준다
		d.mute:SetColorTexture(MUTE[1], MUTE[2], MUTE[3], MUTE[4])
	end
	deco[hb] = d
	return d
end

local function PaintBox(d, isTarget)
	local c = isTarget and TARGET_BOX or Stack.BORDER_COLOR
	for _, line in ipairs(d.lines) do line:SetColorTexture(c[1], c[2], c[3], c[4]) end
end

local function ShowDeco(d, shown)
	for _, line in ipairs(d.lines) do line:SetShown(shown) end
	if d.mute then d.mute:SetShown(shown) end
end

local function Restyle(uf)
	if not (db and db.enabled) or (uf.IsForbidden and uf:IsForbidden()) then return end
	local hb = uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar
	if not hb then return end

	if hb.barTexture then hb.barTexture:SetTexture(FLAT) end   -- 색은 블리자드가 SetStatusBarColor로 계속 칠한다
	local bg = hb.bgTexture
	if bg then
		-- 클래식 금속 테두리(최신 스타일은 바탕)를 막대와 같은 크기의 회색 빈 트랙으로
		bg:ClearAllPoints()
		bg:SetPoint("TOPLEFT", hb, "TOPLEFT", 0, 0)
		bg:SetPoint("BOTTOMRIGHT", hb, "BOTTOMRIGHT", 0, 0)
		bg:SetTexCoord(0, 1, 0, 1)
		bg:SetDrawLayer("BACKGROUND")
		local t = Stack.TRACK_COLOR
		bg:SetColorTexture(t[1], t[2], t[3], t[4])
	end
	Fade(hb.selectedBorder)   -- 노란 둥근 대상 테두리. 막대와 몇 px 어긋나서 네모 테두리로 바꾼다
	Fade(uf.selectionHighlight)   -- 클래식 대상 광택. 대상 표시는 네모 테두리가 맡는다

	local d = Decorate(hb)
	ShowDeco(d, true)
	PaintBox(d, hb == boxed)

	-- 시전 바: 블리자드는 시전 영역 전체 폭으로 그리는데 체력 바는 오른쪽 레벨 몫만큼 짧다. 체력 바 양 끝에 맞춘다.
	-- (체력 바가 시전 영역에 붙어 있고 시전 바에는 안 붙어 있어서 고리 없이 걸 수 있다. 클래식 테두리형은 테두리와 어긋나니 그대로)
	local setup = NamePlateSetupOptions
	local cast = uf.CastBarsContainer and uf.CastBarsContainer.castBar
	if cast and type(setup) == "table" and not setup.useClassicCastBar and type(setup.castBarHeight) == "number" then
		local spacing = type(setup.castBarToHealthBarSpacing) == "number" and setup.castBarToHealthBarSpacing or 0
		cast:ClearAllPoints()
		cast:SetPoint("TOPLEFT", hb, "BOTTOMLEFT", 0, -spacing)
		cast:SetPoint("TOPRIGHT", hb, "BOTTOMRIGHT", 0, -spacing)
		cast:SetHeight(setup.castBarHeight)
	end

	-- 레벨: 상자와 대상 테두리는 빼고 난이도 색 숫자만 (해골은 그대로)
	local lv = uf.PlayerLevelDiffFrame
	if lv then
		Fade(lv.playerLevelDiffIcon)
		Fade(lv.selectedBorder)
	end
	Fade(uf.LevelFrame)   -- 클래식 테두리 안쪽 레벨 칸. 테두리가 없어지니 같이 숨긴다

	local base = type(setup) == "table" and setup.healthBarFontHeight
	if uf.name and type(base) == "number" and base > 0 then
		uf.name:SetTextHeight(base * db.nameScale / 100)
		if uf.name.SetFontHeight and uf.name.GetLineHeight then
			uf.name:SetFontHeight(uf.name:GetLineHeight())   -- 블리자드가 UpdateAnchors 끝에 하는 것과 같게
		end
	end
end

-- 대상 이름표의 테두리만 밝게. 대상이 바뀌거나 이름표가 붙고 떨어질 때 다시 칠한다.
local function UpdateTargetBox()
	local hb = db and db.enabled and HealthBarOf(PlateFor("target")) or nil
	if boxed and boxed ~= hb and deco[boxed] then PaintBox(deco[boxed], false) end
	boxed = nil
	if hb and deco[hb] then
		PaintBox(deco[hb], true)
		boxed = hb
	end
end

-- 블리자드가 이름표를 다시 배치했다(유닛이 붙음, 이름표 크기·스타일 변경). 시전 영역 크기가 바뀌었을 수 있으니
-- 그 이름표 밑 줄 자리도 다시 계산하게 하고(훅을 건 뒤엔 모양 기능을 꺼도), 우리 모양을 덧입힌다.
local function OnAnchors(uf)
	Stack:Invalidate(uf:GetParent())
	Restyle(uf)
end

local function Hook(uf)
	if not uf or hooked[uf] or (uf.IsForbidden and uf:IsForbidden()) or type(uf.UpdateAnchors) ~= "function" then return end
	hooksecurefunc(uf, "UpdateAnchors", OnAnchors)
	hooked[uf] = true
end

local function Apply(plate)
	if not plate or (plate.IsForbidden and plate:IsForbidden()) then return end
	local uf = plate.UnitFrame
	if not uf then return end
	Hook(uf)
	-- 한 번 입힌 모양이 잘못돼도 다음 이름표는 살린다
	local ok, err = pcall(Restyle, uf)
	if not ok then ns.ErrorHandler(err) end
end

local function ApplyAll()
	if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
	for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do Apply(plate) end
	UpdateTargetBox()
end

ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit)
	if not (db and db.enabled) then return end
	Apply(PlateFor(unit))
	UpdateTargetBox()
end)

ns:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function()
	if boxed then UpdateTargetBox() end
end)

ns:RegisterEvent("PLAYER_TARGET_CHANGED", function()
	if db and (db.enabled or boxed) then UpdateTargetBox() end
end)

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
	if db and db.enabled then ApplyAll() end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
local function PushStyle()
	Stack:SetStyle{ barHeight = db.barHeight, comboHeight = db.comboHeight, showPercent = db.showPercent }
end

function M:OnInitialize()
	db = self.db
	PushStyle()
end

function M:ApplySettings(changes)
	PushStyle()
	ns:Fire("PLATE_STYLE_CHANGED")
	if db.enabled then
		ApplyAll()
		return
	end
	if changes.enabled == false then
		for region in pairs(faded) do region:SetAlpha(1) end
		wipe(faded)
		for _, d in pairs(deco) do ShowDeco(d, false) end
		boxed = nil
		ns.Print("이름표 모양을 껐습니다. 막대 모양까지 바로 되돌리려면 /reload 하세요.")
	end
end

function M:BuildOptions(b)
	b:Header("몬스터 이름표")
	b:Text("적 이름표를 납작하고 차분하게 바꿉니다. 형광색 체력은 누그러뜨리고, 금속 테두리와 노란 대상 테두리는 "
		.. "막대에 딱 맞는 네모 테두리(대상만 밝은 회색)로, 레벨 상자는 숫자만 남기고, 이름은 작게 씁니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Slider{ key = "nameScale", label = "몬스터 이름 크기", min = 50, max = 100, step = 5, format = "%d%%", depends = "enabled",
		tooltip = "블리자드 기본 이름 크기에 대한 비율입니다." }
	b:Header("이름표 밑 막대 (어그로 게이지 · 내 상태 막대)")
	b:Slider{ key = "barHeight", label = "막대 두께", min = 2, max = 12, step = 1,
		tooltip = "어그로·체력·마나(기력·분노)·펫 체력 막대의 두께입니다." }
	b:Slider{ key = "comboHeight", label = "연계 점수 칸 두께", min = 3, max = 12, step = 1 }
	b:Check{ key = "showPercent", label = "퍼센트 숫자 표시",
		tooltip = "막대 오른쪽에 85% 처럼 숫자를 띄웁니다. 켜면 숫자가 위아래로 붙지 않게 줄 간격이 조금 넓어집니다." }
	b:Text("- 몬스터 이름표 모양을 끄면 새로 뜨는 이름표부터 원래대로 돌아갑니다. 한 번에 되돌리려면 /reload 하세요.\n"
		.. "- 이름표 크기·스타일은 게임 설정(인터페이스 > 이름표)을 그대로 따릅니다.",
		{ color = { 0.7, 0.7, 0.7 } })
end
