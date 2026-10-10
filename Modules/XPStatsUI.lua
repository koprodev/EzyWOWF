-- 경험치 통계 화면: 작은 패널(시간당·레벨업 예상·이번 접속 출처 비율)과 탭 4개 상세 창.
-- 숫자는 전부 XPStats.lua의 M.Stats()·저장 표에서 읽기만 한다.

local _, ns = ...
local M = ns.modules.XPStats
local UI = ns.UI
local Theme = UI.Theme
local Print = ns.Print

local PANEL_W = 250
local BAR_W = PANEL_W - 16
local WIN_W, WIN_H = 660, 480
local TITLE_H, TAB_H = 26, 24
local ROW_H = 16
local WINDOW_REFRESH = 5   -- 창이 열려 있으면 시간 글자만 이 간격으로 다시 그린다

local db
local moving = false

local function Hex(c)
	return ("|cff%02x%02x%02x"):format(math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
end

-- 같은 글자면 SetText를 건너뛴다 (패널은 1초마다 다시 그린다)
local function Set(fs, text)
	if fs.shownText ~= text then
		fs:SetText(text)
		fs.shownText = text
	end
end

---------------------------------------------------------------------------
-- 패널
---------------------------------------------------------------------------
local panel = CreateFrame("Button", "EzyWOWFXPPanel", UIParent, "BackdropTemplate")
panel:SetSize(PANEL_W, 102)
panel:SetFrameStrata("MEDIUM")
panel:SetMovable(true)
panel:SetClampedToScreen(true)
panel:RegisterForDrag("LeftButton")
panel:RegisterForClicks("LeftButtonUp")
UI.ApplyPanelBackdrop(panel, { 0.03, 0.03, 0.04, 0.72 }, Theme.border)
panel:Hide()

local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", 8, -6)
title:SetText("경험치")

local levelText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
levelText:SetPoint("TOPRIGHT", -8, -8)
levelText:SetJustifyH("RIGHT")

-- 레벨 진행 막대: 뒤에 휴식 경험치(파랑), 앞에 지금 경험치(보라)
local restBar = CreateFrame("StatusBar", nil, panel)
restBar:SetPoint("TOPLEFT", 8, -25)
restBar:SetSize(BAR_W, 5)
restBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
restBar:SetStatusBarColor(0.25, 0.45, 0.95, 0.55)
local restBg = restBar:CreateTexture(nil, "BACKGROUND")
restBg:SetAllPoints()
restBg:SetColorTexture(0, 0, 0, 0.5)
local xpBar = CreateFrame("StatusBar", nil, restBar)
xpBar:SetAllPoints()
xpBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
xpBar:SetStatusBarColor(0.62, 0.35, 0.95)

local function Line(y)
	local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("TOPLEFT", 8, y)
	fs:SetPoint("RIGHT", -8, 0)
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
	return fs
end
local rateText, etaText, sessionText = Line(-36), Line(-50), Line(-64)

-- 이번 접속 출처 비율 막대 (몹·퀘스트·탐험·기타 순서)
local sourceBg = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
sourceBg:SetPoint("TOPLEFT", 8, -81)
sourceBg:SetSize(BAR_W, 5)
sourceBg:SetColorTexture(0, 0, 0, 0.5)
local segments = {}
for i, src in ipairs(M.SOURCES) do
	local seg = panel:CreateTexture(nil, "ARTWORK")
	seg:SetHeight(5)
	local c = M.COLORS[src]
	seg:SetColorTexture(c[1], c[2], c[3], 0.95)
	seg:Hide()
	segments[i] = seg
end
local legend = Line(-89)

local moveTint = panel:CreateTexture(nil, "OVERLAY")
moveTint:SetAllPoints()
moveTint:SetColorTexture(0, 1, 0, 0.25)
moveTint:Hide()

local function PanelSources(b)
	local total = b.xp
	local x = 0
	for i, src in ipairs(M.SOURCES) do
		local w = total > 0 and BAR_W * b[src] / total or 0
		local seg = segments[i]
		seg:ClearAllPoints()
		seg:SetPoint("LEFT", sourceBg, "LEFT", x, 0)
		seg:SetWidth(math.max(w, 0.01))
		seg:SetShown(w > 0)
		x = x + w
	end
	if total <= 0 then
		Set(legend, "|cff808080이번 접속에 얻은 경험치 없음|r")
		return
	end
	local out = {}
	for _, src in ipairs(M.SOURCES) do
		if b[src] > 0 then
			out[#out + 1] = ("%s%s %.0f%%|r"):format(Hex(M.COLORS[src]), M.LABELS[src], M.Percent(b[src], total))
		end
	end
	Set(legend, table.concat(out, "  "))
end

local function RefreshPanel()
	if not db then return end
	local st = M.Stats()
	local want = db.enabled and db.showPanel and ((st and st.active) or moving) and true or false
	panel:SetShown(want)
	moveTint:SetShown(moving)
	panel:EnableMouse(want)
	if not want then return end
	if not st then
		Set(levelText, "")
		Set(rateText, "|cff808080접속하면 기록을 시작합니다|r")
		Set(etaText, "")
		Set(sessionText, "")
		Set(legend, "")
		return
	end
	Set(levelText, ("%d레벨 %.1f%%"):format(st.level, st.pct))
	restBar:SetMinMaxValues(0, math.max(1, st.max))
	restBar:SetValue(math.min(st.max, st.xp + st.rested))
	xpBar:SetMinMaxValues(0, math.max(1, st.max))
	xpBar:SetValue(st.xp)
	if st.rateSession or st.rateRecent then
		Set(rateText, ("시간당 |cffffffff%s|r · 최근 %d분 |cffffffff%s|r"):format(
			st.rateSession and M.Comma(st.rateSession) or "-", st.recentMinutes, st.rateRecent and M.Comma(st.rateRecent) or "-"))
	else
		Set(rateText, "시간당 |cff808080측정 중 (2분 뒤부터)|r")
	end
	local eta = { "레벨업까지 " .. (st.eta and ("|cffffffff" .. M.Duration(st.eta) .. "|r") or "|cff808080-|r") }
	if st.killsToLevel then eta[#eta + 1] = ("%s몹 %s|r"):format(Hex(M.COLORS.kill), M.Comma(st.killsToLevel)) end
	if st.questsToLevel then eta[#eta + 1] = ("%s퀘스트 %s|r"):format(Hex(M.COLORS.quest), M.Comma(st.questsToLevel)) end
	Set(etaText, table.concat(eta, " · "))
	Set(sessionText, ("이번 접속 |cffffffff+%s|r · %s"):format(M.Comma(st.session.xp), M.Duration(st.session.time)))
	PanelSources(st.session)
end

local function ApplyPosition()
	panel:SetScale(db.scale)
	panel:ClearAllPoints()
	panel:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
end

panel:SetScript("OnDragStart", function(self)
	if moving then self:StartMoving() end
end)
panel:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	if not (moving and db) then return end
	local x, y = self:GetCenter()
	if x and y then
		db.point, db.relPoint, db.x, db.y = "CENTER", "BOTTOMLEFT", x, y
		ApplyPosition()
	end
end)
panel:SetScript("OnClick", function()
	if not moving then M.ToggleWindow() end
end)
panel:SetScript("OnEnter", function(self)
	if moving then return end
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	M.FillTooltip(GameTooltip)
	GameTooltip:Show()
end)
panel:SetScript("OnLeave", GameTooltip_Hide)

function M.IsMoving() return moving end

function M.ToggleMove()
	if not (db and db.enabled and db.showPanel) then return end
	moving = not moving
	RefreshPanel()
	ns:Fire("REFRESH_UI")
	if moving then Print("경험치 패널을 드래그해서 옮기고 [이동 완료]를 누르세요.") end
end

function M.ResetPosition()
	db.point, db.relPoint, db.x, db.y = M.defaults.point, M.defaults.relPoint, M.defaults.x, M.defaults.y
	ApplyPosition()
end

---------------------------------------------------------------------------
-- 상세 창: 표 그리기
---------------------------------------------------------------------------
local window, area, content, tabs
local selectedTab = "summary"
local fsPool, fsUsed, texPool, texUsed = {}, 0, {}, 0
local cursorY = 0
local sinceRefresh = 0

local function FS(font)
	fsUsed = fsUsed + 1
	local fs = fsPool[fsUsed]
	if not fs then
		fs = content:CreateFontString(nil, "ARTWORK")
		fs:SetWordWrap(false)
		fsPool[fsUsed] = fs
	end
	fs:SetFontObject(font or GameFontHighlightSmall)
	fs:SetTextColor(1, 1, 1)
	fs:ClearAllPoints()
	fs:Show()
	return fs
end

local function Tex()
	texUsed = texUsed + 1
	local tex = texPool[texUsed]
	if not tex then
		tex = content:CreateTexture(nil, "BACKGROUND")
		texPool[texUsed] = tex
	end
	tex:ClearAllPoints()
	tex:Show()
	return tex
end

local function Cell(text, x, w, justify, color, font)
	local fs = FS(font)
	fs:SetPoint("TOPLEFT", content, "TOPLEFT", x, -cursorY)
	fs:SetWidth(w)
	fs:SetJustifyH(justify or "LEFT")
	if color then fs:SetTextColor(color[1], color[2], color[3]) end
	fs:SetText(text)
	return fs
end

local function Section(text)
	cursorY = cursorY + (cursorY > 0 and 10 or 4)
	Cell(text, 4, WIN_W - 60, "LEFT", Theme.accent, GameFontNormal)
	cursorY = cursorY + 18
	local line = Tex()
	line:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -cursorY)
	line:SetSize(WIN_W - 60, 1)
	UI.ColorTexture(line, Theme.accent, 0.35)
	cursorY = cursorY + 4
end

local function Note(text)
	Cell(text, 8, WIN_W - 64, "LEFT", Theme.muted)
	cursorY = cursorY + ROW_H
end

-- cols = { { w=, j= }, ... }. 첫 칸은 왼쪽, 나머지는 오른쪽 맞춤이 기본
local function Row(cols, cells, color, header)
	local x = 8
	for i, col in ipairs(cols) do
		local text = cells[i]
		if text ~= nil and text ~= "" then
			Cell(text, x, col.w, col.j or (i == 1 and "LEFT" or "RIGHT"), header and Theme.accent or (i == 1 and color or nil),
				header and GameFontNormalSmall or nil)
		end
		x = x + col.w + 6
	end
	cursorY = cursorY + ROW_H
end

local function MiniBar(x, w, frac, c)
	local tex = Tex()
	tex:SetPoint("TOPLEFT", content, "TOPLEFT", x, -(cursorY - ROW_H + 4))
	tex:SetSize(math.max(1, w * math.max(0, math.min(1, frac))), ROW_H - 8)
	tex:SetColorTexture(c[1], c[2], c[3], 0.8)
end

local function Pair(label, value)
	Cell(label, 12, 170, "LEFT", Theme.muted)
	Cell(value, 186, WIN_W - 250, "LEFT")
	cursorY = cursorY + ROW_H
end

local function N(v) return M.Comma(v) end
local function Rate(xp, sec) return (sec or 0) >= 120 and N(xp / sec * 3600) or "-" end
local function Pct(part, whole) return whole > 0 and ("%.0f%%"):format(M.Percent(part, whole)) or "-" end

---------------------------------------------------------------------------
-- 탭 내용
---------------------------------------------------------------------------
local function DrawSummary(c, st)
	Section(("%s · %d레벨 %.1f%%"):format(c.name or "?", st.level, st.pct))
	if not st.active then Note("경험치를 더 얻을 수 없는 상태(만렙·경험치 잠금)라 기록을 멈췄습니다. 지난 기록은 그대로 볼 수 있습니다.") end
	Pair("남은 경험치", ("%s / %s"):format(N(st.remaining), N(st.max)))
	if st.rested > 0 then Pair("휴식 경험치", N(st.rested)) end
	Pair("시간당 (이번 접속)", st.rateSession and N(st.rateSession) or "측정 중 (2분 뒤부터)")
	Pair(("시간당 (최근 %d분)"):format(st.recentMinutes), st.rateRecent and N(st.rateRecent) or "측정 중")
	Pair("레벨업까지", st.eta and M.Duration(st.eta) or "-")
	local need = {}
	if st.killsToLevel then need[#need + 1] = ("몹 %s마리 (평균 %s, 휴식 보너스 포함)"):format(N(st.killsToLevel), N(st.killAvg)) end
	if st.questsToLevel then need[#need + 1] = ("퀘스트 %s개 (최근 평균 %s)"):format(N(st.questsToLevel), N(st.questAvg)) end
	Pair("레벨업에 필요한 양", #need > 0 and table.concat(need, " 또는 ") or "기록이 더 쌓이면 보여 줍니다")

	Section("출처별 경험치")
	local cols = { { w = 140 }, { w = 108 }, { w = 108 }, { w = 108 }, { w = 108 } }
	local buckets = { st.session, st.today, st.levelRec.b, st.total }
	Row(cols, { "", "이번 접속", "오늘", "이번 레벨", "누적" }, nil, true)
	local function BucketRow(label, fn, color)
		local cells = { label }
		for i, b in ipairs(buckets) do cells[i + 1] = fn(b) end
		Row(cols, cells, color)
	end
	BucketRow("합계", function(b) return N(b.xp) end, Theme.header)
	for _, src in ipairs(M.SOURCES) do
		BucketRow(M.LABELS[src], function(b) return ("%s (%s)"):format(N(b[src]), Pct(b[src], b.xp)) end, M.COLORS[src])
		if src == "kill" then BucketRow("  휴식 보너스", function(b) return N(b.rested) end, { 0.4, 0.6, 1 }) end
	end
	BucketRow("처치 수", function(b) return N(b.kills) end)
	BucketRow("완료 퀘스트", function(b) return N(b.quests) end)
	BucketRow("활동 시간", function(b) return M.Duration(b.time) end)
	BucketRow("시간당", function(b) return Rate(b.xp, b.time) end)

	Section("최근 7일")
	local days = {}
	for key, b in pairs(c.days) do
		if type(b) == "table" and (b.xp or 0) > 0 then days[#days + 1] = { key = tostring(key), b = b } end
	end
	table.sort(days, function(a, b) return a.key > b.key end)
	if #days == 0 then Note("아직 기록이 없습니다.") return end
	local top = 0
	for i = 1, math.min(7, #days) do top = math.max(top, days[i].b.xp) end
	local dcols = { { w = 90 }, { w = 90 }, { w = 90 }, { w = 90 }, { w = 180, j = "LEFT" } }
	Row(dcols, { "날짜", "경험치", "활동 시간", "시간당", "" }, nil, true)
	for i = 1, math.min(7, #days) do
		local b = days[i].b
		Row(dcols, { days[i].key, N(b.xp), M.Duration(b.time or 0), Rate(b.xp, b.time), "" })
		MiniBar(8 + 90 * 4 + 24, 180, b.xp / top, { 0.62, 0.35, 0.95 })
	end
end

local function TopZone(zones)
	local best, amount
	for zone, xp in pairs(zones or {}) do
		if type(xp) == "number" and (not amount or xp > amount) then best, amount = zone, xp end
	end
	return best or "-"
end

local function DrawLevels(c, st)
	Section("레벨별 기록")
	local levels = {}
	for lv, rec in pairs(c.levels) do
		if type(lv) == "number" and type(rec) == "table" and type(rec.b) == "table" then levels[#levels + 1] = lv end
	end
	table.sort(levels, function(a, b) return a > b end)
	if #levels == 0 then Note("아직 기록이 없습니다.") return end
	local cols = { { w = 64 }, { w = 74 }, { w = 74 }, { w = 74 }, { w = 40 }, { w = 44 }, { w = 40 }, { w = 40 }, { w = 40 }, { w = 112, j = "LEFT" } }
	Row(cols, { "레벨", "활동 시간", "실제 플레이", "경험치", "몹", "퀘스트", "기타", "처치", "퀘스트", "주요 지역" }, nil, true)
	for _, lv in ipairs(levels) do
		local rec = c.levels[lv]
		local b = rec.b
		local mark = ""
		if lv == st.level and not rec.done then mark = " 진행" elseif rec.broken then mark = " 끊김" end
		if rec.partial then mark = mark .. "*" end
		local played = rec.playedTime or (not rec.done and M.PlayedFor(rec)) or nil
		Row(cols, {
			lv .. mark, M.Duration(b.time), played and M.Duration(played) or "-", N(b.xp),
			Pct(b.kill, b.xp), Pct(b.quest, b.xp), Pct(b.explore + b.other, b.xp), N(b.kills), N(b.quests), TopZone(rec.zones),
		}, lv == st.level and Theme.header or nil)
	end
	Note("* 설치하기 전에 시작한 레벨이라 그 뒤부터만 셌습니다. 끊김: 이 애드온 없이 레벨이 오른 구간.")
	Note("실제 플레이는 /played(게임 플레이 시간)를 받은 레벨만 나옵니다. 기타에는 탐험이 포함됩니다.")
end

local function DrawDetail(c, st)
	Section("지역별 (시간당 경험치 순)")
	local zones = {}
	for zone, b in pairs(c.zones) do
		if type(b) == "table" and ((b.xp or 0) > 0 or (b.time or 0) >= 60) then zones[#zones + 1] = { zone = zone, b = b } end
	end
	table.sort(zones, function(a, b)
		local ra = a.b.time >= 180 and a.b.xp / a.b.time or -1
		local rb = b.b.time >= 180 and b.b.xp / b.b.time or -1
		if ra ~= rb then return ra > rb end
		return a.b.xp > b.b.xp
	end)
	local zcols = { { w = 190 }, { w = 80 }, { w = 80 }, { w = 80 }, { w = 60 }, { w = 60 } }
	if #zones == 0 then Note("아직 기록이 없습니다.") else
		Row(zcols, { "지역", "활동 시간", "경험치", "시간당", "처치", "퀘스트" }, nil, true)
		for i = 1, math.min(25, #zones) do
			local z = zones[i]
			Row(zcols, { z.zone, M.Duration(z.b.time), N(z.b.xp), Rate(z.b.xp, z.b.time), N(z.b.kills), N(z.b.quests) })
		end
	end

	Section(("몹별 (내 레벨 %d~%d에서 잡은 몹, 평균 경험치 순)"):format(math.max(1, st.level - 2), st.level))
	local mobs = {}
	for name, mob in pairs(c.mobs) do
		if type(mob) == "table" and (tonumber(mob.kills) or 0) > 0 and (tonumber(mob.level) or 0) >= st.level - 2 then
			mobs[#mobs + 1] = { name = name, m = mob, avg = mob.xp / mob.kills }
		end
	end
	table.sort(mobs, function(a, b) return a.avg > b.avg end)
	local mcols = { { w = 190 }, { w = 60 }, { w = 80 }, { w = 80 }, { w = 80 }, { w = 60 } }
	if #mobs == 0 then Note("최근 레벨에서 잡은 몹이 없습니다.") else
		Row(mcols, { "몹", "처치", "평균", "합계", "휴식 보너스", "내 레벨" }, nil, true)
		for i = 1, math.min(25, #mobs) do
			local mob = mobs[i]
			Row(mcols, { mob.name, N(mob.m.kills), N(mob.avg), N(mob.m.xp), N(mob.m.rested or 0), tostring(mob.m.level or "-") })
		end
	end

	Section("최근 퀘스트")
	local qcols = { { w = 220 }, { w = 70 }, { w = 50 }, { w = 150, j = "LEFT" }, { w = 64 } }
	if #c.quests == 0 then Note("아직 기록이 없습니다.") return end
	Row(qcols, { "퀘스트", "경험치", "레벨", "지역", "날짜" }, nil, true)
	for i = 1, math.min(30, #c.quests) do
		local q = c.quests[i]
		if type(q) == "table" then
			local name = q.title or (q.id and ("퀘스트 #%s"):format(q.id)) or "이름 모름"
			Row(qcols, { name, N(q.xp), tostring(q.level or "-"), q.zone or "-", q.at and date("%m/%d", q.at) or "-" }, M.COLORS.quest)
		end
	end
end

local function ClassColor(class)
	local c = type(class) == "string" and C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(class)
	if type(c) == "table" and type(c.r) == "number" then return { c.r, c.g, c.b } end
	c = type(class) == "string" and type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS[class]
	if type(c) == "table" and type(c.r) == "number" then return { c.r, c.g, c.b } end
end

local function DrawChars()
	Section("이 계정 캐릭터 (이 PC 저장 파일 기준)")
	local list, current = {}, M.CurrentKey()
	for key, c in pairs(M.Chars()) do
		if type(c) == "table" and type(c.total) == "table" then list[#list + 1] = { key = key, c = c } end
	end
	table.sort(list, function(a, b) return (tonumber(a.c.seen) or 0) > (tonumber(b.c.seen) or 0) end)
	if #list == 0 then Note("아직 기록이 없습니다.") return end
	local cols = { { w = 120 }, { w = 36 }, { w = 50 }, { w = 84 }, { w = 80 }, { w = 64 }, { w = 84 }, { w = 64 } }
	Row(cols, { "캐릭터", "레벨", "진행", "누적 경험치", "활동 시간", "시간당", "플레이 시간", "마지막" }, nil, true)
	for _, item in ipairs(list) do
		local c = item.c
		local name = (item.key == current and "▶ " or "") .. (c.name or "?")
		local progress = (type(c.xp) == "number" and type(c.xpMax) == "number" and c.xpMax > 0) and ("%.0f%%"):format(M.Percent(c.xp, c.xpMax)) or "-"
		local played = M.PlayedTotal(c)
		Row(cols, {
			name, tostring(c.level or "-"), progress, N(c.total.xp), M.Duration(c.total.time), Rate(c.total.xp, c.total.time),
			played and M.Duration(played) or "-", c.seen and date("%m/%d", c.seen) or "-",
		}, ClassColor(c.class))
	end
	Note("다른 와우 계정 캐릭터는 저장 파일이 따로라 안 나옵니다. 플레이 시간은 /played를 받은 캐릭터만 나옵니다.")
end

local DRAW = { summary = DrawSummary, levels = DrawLevels, detail = DrawDetail }

local function RenderWindow()
	if not (window and window:IsShown()) then return end
	fsUsed, texUsed, cursorY = 0, 0, 0
	sinceRefresh = 0
	local c, st = M.GetChar(), M.Stats()
	if selectedTab == "chars" then
		DrawChars()
	elseif c and st then
		DRAW[selectedTab](c, st)
	else
		Section("경험치 통계")
		Note(db.enabled and "접속을 마치면 기록을 시작합니다." or "꺼져 있습니다. /이지 > 화면 정보 > 경험치 통계에서 켜세요.")
	end
	for i = fsUsed + 1, #fsPool do fsPool[i]:Hide() end
	for i = texUsed + 1, #texPool do texPool[i]:Hide() end
	content:SetHeight(math.max(1, cursorY + 8))
	area:SetContentHeight(cursorY + 8)
	for key, tab in pairs(tabs) do
		tab:PaintTab(key == selectedTab)
		UI.ColorText(tab.text, key == selectedTab and Theme.header or Theme.normal)
	end
end

---------------------------------------------------------------------------
-- 상세 창: 틀
---------------------------------------------------------------------------
local TAB_LIST = {
	{ key = "summary", text = "요약" }, { key = "levels", text = "레벨 기록" },
	{ key = "detail", text = "지역·몹·퀘스트" }, { key = "chars", text = "캐릭터 비교" },
}

local function SaveWindowPosition()
	local point, _, relPoint, x, y = window:GetPoint(1)
	if point and x and y then db.winPoint, db.winRelPoint, db.winX, db.winY = point, relPoint, x, y end
end

local function CreateWindow()
	window = CreateFrame("Frame", "EzyWOWFXPStatsWindow", UIParent, "BackdropTemplate")
	window:SetSize(WIN_W, WIN_H)
	window:SetFrameStrata("MEDIUM")
	window:SetToplevel(true)
	window:SetMovable(true)
	window:SetClampedToScreen(true)
	window:EnableMouse(true)
	if window.SetDontSavePosition then window:SetDontSavePosition(true) end
	UI.ApplyPanelBackdrop(window)
	window:SetPoint(db.winPoint, UIParent, db.winRelPoint, db.winX, db.winY)
	window:Hide()
	tinsert(UISpecialFrames, "EzyWOWFXPStatsWindow")   -- Esc로 닫는다

	local titleBar = CreateFrame("Frame", nil, window)
	titleBar:SetPoint("TOPLEFT", 1, -1)
	titleBar:SetPoint("TOPRIGHT", -1, -1)
	titleBar:SetHeight(TITLE_H)
	titleBar:EnableMouse(true)
	titleBar:RegisterForDrag("LeftButton")
	titleBar:SetScript("OnDragStart", function() window:StartMoving() end)
	titleBar:SetScript("OnDragStop", function()
		window:StopMovingOrSizing()
		SaveWindowPosition()
	end)
	local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
	titleBg:SetAllPoints()
	UI.ColorTexture(titleBg, Theme.titleBg)
	local titleLine = titleBar:CreateTexture(nil, "ARTWORK")
	titleLine:SetPoint("BOTTOMLEFT")
	titleLine:SetPoint("BOTTOMRIGHT")
	titleLine:SetHeight(1)
	UI.ColorTexture(titleLine, Theme.accent, 0.5)
	local icon = titleBar:CreateTexture(nil, "ARTWORK")
	icon:SetSize(16, 16)
	icon:SetPoint("LEFT", 6, 0)
	icon:SetTexture(ns.GetIcon(M.icon))
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	local titleText = titleBar:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	titleText:SetPoint("LEFT", icon, "RIGHT", 6, 0)
	titleText:SetText("경험치 통계")

	local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
	close:SetSize(22, 22)
	close:SetPoint("TOPRIGHT", -2, -2)
	close:SetFrameLevel(titleBar:GetFrameLevel() + 2)

	tabs = {}
	local x = 10
	for _, info in ipairs(TAB_LIST) do
		local tab = CreateFrame("Button", nil, window)
		tab:SetHeight(TAB_H)
		tab.text = tab:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		tab.text:SetPoint("CENTER", 0, -1)
		tab.text:SetText(info.text)
		tab:SetWidth(math.max(70, tab.text:GetStringWidth() + 30))
		tab:SetPoint("TOPLEFT", window, "TOPLEFT", x, -(TITLE_H + 6))
		UI.ApplyTabArt(tab)
		tab:SetScript("OnClick", function()
			selectedTab = info.key
			area:ScrollTo(0)
			RenderWindow()
		end)
		x = x + tab:GetWidth() + 4
		tabs[info.key] = tab
	end

	local inset = CreateFrame("Frame", nil, window, "BackdropTemplate")
	inset:SetPoint("TOPLEFT", 8, -(TITLE_H + 6 + TAB_H))
	inset:SetPoint("BOTTOMRIGHT", -8, 8)
	UI.ApplyPanelBackdrop(inset, { 0, 0, 0, 0.35 }, Theme.border)

	area = UI.CreateScrollArea(inset)
	area.scroll:SetPoint("TOPLEFT", 4, -4)
	area.scroll:SetPoint("BOTTOMRIGHT", -14, 4)
	content = CreateFrame("Frame", nil, area.scroll)
	content:SetSize(WIN_W - 40, 1)
	area.scroll:SetScrollChild(content)

	window:SetScript("OnShow", function()
		RenderWindow()
		ns:Fire("REFRESH_UI")
	end)
	window:SetScript("OnHide", function()
		window:StopMovingOrSizing()
		ns:Fire("REFRESH_UI")
	end)
end

function M.ToggleWindow()
	if not db then return end
	if not window then CreateWindow() end
	window:SetShown(not window:IsShown())
end

function M.IsWindowShown()
	return window ~= nil and window:IsShown()
end

function M.SelectTab(key)
	if not window then CreateWindow() end
	selectedTab = TAB_LIST[1].key
	for _, info in ipairs(TAB_LIST) do
		if info.key == key then selectedTab = key end
	end
	RenderWindow()
end

ns:On("XPSTATS_UPDATED", function(dataChanged)
	RefreshPanel()
	if window and window:IsShown() then
		sinceRefresh = sinceRefresh + 1
		if dataChanged or sinceRefresh >= WINDOW_REFRESH then RenderWindow() end
	end
end)

function M.InitUI(saved)
	db = saved
	ApplyPosition()
	RefreshPanel()
end

function M.ApplyUI()
	if not (db.enabled and db.showPanel) then moving = false end
	ApplyPosition()
	RefreshPanel()
	if window then
		window:ClearAllPoints()
		window:SetPoint(db.winPoint, UIParent, db.winRelPoint, db.winX, db.winY)
		if not db.enabled then window:Hide() end
		RenderWindow()
	end
end
