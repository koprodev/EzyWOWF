-- 일반 설정 + 미니맵 버튼 + 미니맵 애드온 목록(컴파트먼트) 항목 + 성능 표시.

local ADDON_NAME, ns = ...

local M = ns:NewModule("General", {
	title = "일반",
	category = "general",
	icon = "Interface\\Icons\\Trade_Engineering",
	order = 0,
	bindings = { "EZYWOWF_TOGGLE" },
	defaults = {
		showMinimap = true,
		minimapAngle = 200,
		loginMessage = true,
	},
})

---------------------------------------------------------------------------
-- 툴팁 (미니맵 버튼과 애드온 목록이 같이 쓴다)
---------------------------------------------------------------------------
local function FillTooltip(tooltip)
	tooltip:SetText(ns.title, 1, 0.82, 0)
	for _, m in ipairs(ns.moduleOrder) do
		if m.GetTooltipLine then
			local left, right = m:GetTooltipLine()
			if left then tooltip:AddDoubleLine(left, right or "", 0.8, 0.8, 0.8, 1, 1, 1) end
		end
	end
	tooltip:AddLine(" ")
	tooltip:AddLine("클릭: 설정 창 열기/닫기", 0.6, 0.6, 0.6)
	tooltip:AddLine("드래그: 버튼 위치 이동", 0.6, 0.6, 0.6)
	tooltip:Show()
end

---------------------------------------------------------------------------
-- 미니맵 버튼
---------------------------------------------------------------------------
local RADIUS_PADDING = 5
local ROUND_QUADRANTS = { true, true, true, true }
local SQUARE_QUADRANTS = { false, false, false, false }

local button = CreateFrame("Button", "EzyWOWFMinimapButton", Minimap)
button:SetSize(31, 31)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(8)
button:RegisterForClicks("AnyUp")
button:RegisterForDrag("LeftButton")
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
button:Hide()

local border = button:CreateTexture(nil, "OVERLAY")
border:SetSize(50, 50)
border:SetPoint("TOPLEFT")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local background = button:CreateTexture(nil, "BACKGROUND")
background:SetSize(24, 24)
background:SetPoint("CENTER")
background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetSize(18, 18)
icon:SetPoint("CENTER")
icon:SetTexture(ns.GetIcon(ns.icon, ns.fallbackIcon))

local mask = button:CreateMaskTexture()
mask:SetAllPoints(icon)
mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
icon:AddMaskTexture(mask)

-- 둥근/네모 미니맵 모두에서 테두리를 따라 배치 (LibDBIcon과 같은 방식)
local function UpdatePosition()
	local angle = math.rad(M.db.minimapAngle or 200)
	local x, y = math.cos(angle), math.sin(angle)
	local q = 1
	if x < 0 then q = q + 1 end
	if y > 0 then q = q + 2 end

	local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
	local quadrants = (shape == "SQUARE") and SQUARE_QUADRANTS or ROUND_QUADRANTS
	local w = Minimap:GetWidth() / 2 + RADIUS_PADDING
	local h = Minimap:GetHeight() / 2 + RADIUS_PADDING
	if quadrants[q] then
		x, y = x * w, y * h
	else
		local dw = math.sqrt(2 * w * w) - 10
		local dh = math.sqrt(2 * h * h) - 10
		x = math.max(-w, math.min(x * dw, w))
		y = math.max(-h, math.min(y * dh, h))
	end
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function OnDragUpdate()
	local mx, my = Minimap:GetCenter()
	local px, py = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	px, py = px / scale, py / scale
	M.db.minimapAngle = math.deg(math.atan2(py - my, px - mx)) % 360
	UpdatePosition()
end

-- 미니맵 모양·크기가 바뀌면 가장자리 위치도 달라진다.
ns:On("MINIMAP_LAYOUT_CHANGED", function()
	if M.db then UpdatePosition() end
end)

button:SetScript("OnDragStart", function(self)
	self:LockHighlight()
	self:SetScript("OnUpdate", OnDragUpdate)
	GameTooltip:Hide()
end)

button:SetScript("OnDragStop", function(self)
	self:SetScript("OnUpdate", nil)
	self:UnlockHighlight()
end)

button:SetScript("OnMouseDown", function() icon:SetPoint("CENTER", 1, -1) end)
button:SetScript("OnMouseUp", function() icon:SetPoint("CENTER", 0, 0) end)

button:SetScript("OnClick", function()
	ns:ToggleWindow()
end)

button:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	FillTooltip(GameTooltip)
end)
button:SetScript("OnLeave", GameTooltip_Hide)

---------------------------------------------------------------------------
-- 미니맵 애드온 목록(컴파트먼트) - TOC의 AddonCompartmentFunc에서 호출
---------------------------------------------------------------------------
function EzyWOWF_OnAddonCompartmentClick()
	ns:ToggleWindow()
end

function EzyWOWF_OnAddonCompartmentEnter(_, menuButton)
	GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
	FillTooltip(GameTooltip)
end

function EzyWOWF_OnAddonCompartmentLeave()
	GameTooltip:Hide()
end

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	UpdatePosition()
	button:SetShown(self.db.showMinimap)
end

function M:OnLogin()
	if self.db.loginMessage then
		ns.Print(("v%s 로드됨 - 미니맵 버튼이나 |cff00ff00/이지|r 로 설정 창을 엽니다."):format(ns.version))
	end
	if ns.freshStart then
		ns.Print("저장된 설정이 없어 기본값으로 시작합니다. 백업해 둔 설정 문자열이 있으면 "
			.. "|cff00ff00/이지|r > 일반 > [설정 가져오기]로 되살릴 수 있어요.")
	end
end

function M:ApplySettings()
	UpdatePosition()
	button:SetShown(self.db.showMinimap)
end

local function ShowExport()
	ns.UI.ShowTextDialog{
		title = "설정 내보내기",
		help = "아래 글자를 Ctrl+C로 복사해서 메모장 등에 보관하세요. (저장된 설정과 단축키가 들어 있습니다)",
		text = ns:ExportSettings(),
		readOnly = true,
	}
end

local function ShowImport()
	ns.UI.ShowTextDialog{
		title = "설정 가져오기",
		help = "내보내기로 복사해 둔 글자를 Ctrl+V로 붙여 넣고 [가져오기]를 누르세요.",
		text = "",
		button = "가져오기",
		onAccept = function(text) return ns:ImportSettings(text) end,
	}
end

---------------------------------------------------------------------------
-- 성능 표시: 게임에 들어 있는 애드온 측정값(C_AddOnProfiler)을 그대로 보여 준다
---------------------------------------------------------------------------
local PERF_INTERVAL = 1
local MEMORY_INTERVAL = 15   -- 블리자드 애드온 목록도 15초에 한 번만 잰다(무거운 호출)
local memoryMeasured, lastMemoryAt = false, nil

local function ProfilerState()
	local P = C_AddOnProfiler
	local metric = Enum and Enum.AddOnProfilerMetric
	if type(P) ~= "table" or type(P.GetAddOnMetric) ~= "function" or type(P.IsEnabled) ~= "function"
		or type(metric) ~= "table" or metric.RecentAverageTime == nil then
		return "unsupported"
	end
	if not P.IsEnabled() then return "disabled" end
	return "ok"
end

local function FormatMs(v)
	if v >= 10 then return ("%.1f ms"):format(v) end
	if v >= 1 then return ("%.2f ms"):format(v) end
	return ("%.3f ms"):format(v)
end

local function MetricLine(label, metricKey, note)
	return function()
		local state = ProfilerState()
		local value
		if state == "unsupported" then
			value = "|cff808080지원 안 됨|r"
		elseif state == "disabled" then
			value = "|cff808080측정 꺼짐|r"
		else
			local v = ns.Clean(C_AddOnProfiler.GetAddOnMetric(ADDON_NAME, Enum.AddOnProfilerMetric[metricKey]))
			value = type(v) == "number" and FormatMs(v) or "|cff808080알 수 없음|r"
		end
		return ("%s:  %s  |cff999999(%s)|r"):format(label, value, note)
	end
end

local function MemoryText()
	if not memoryMeasured then return "메모리:  |cff808080[메모리 재기]를 누르면 잽니다|r" end
	local kb = ns.Clean(GetAddOnMemoryUsage(ADDON_NAME))
	if type(kb) ~= "number" then return "메모리:  |cff808080알 수 없음|r" end
	if kb >= 1024 then return ("메모리:  %.0f KB  |cff999999(%.1f MB)|r"):format(kb, kb / 1024) end
	return ("메모리:  %.0f KB"):format(kb)
end

local function MeasureMemory()
	if InCombatLockdown() then
		ns.Print("전투 중에는 메모리를 재지 않아요. 전투가 끝난 뒤 눌러 주세요.")
		return
	end
	if type(UpdateAddOnMemoryUsage) ~= "function" or type(GetAddOnMemoryUsage) ~= "function" then return end
	local now = GetTime()
	if lastMemoryAt and now - lastMemoryAt < MEMORY_INTERVAL then
		ns.Print(("메모리는 %d초에 한 번만 잽니다. 조금 뒤에 다시 눌러 주세요."):format(MEMORY_INTERVAL))
		return
	end
	lastMemoryAt = now
	UpdateAddOnMemoryUsage()
	memoryMeasured = true
end

-- 기록 개수는 각 모듈이 센다. 전부 훑는 일이라 1초 갱신에는 넣지 않는다.
local function RecordCount(key)
	local m = ns.modules[key]
	if m and m.db and m.CountRecords then return (m:CountRecords()) end
	return 0
end

local function RecordText()
	return ("저장 기록:  시세 %d개 · 채집·보물 %d곳 · 캐릭터 %d명"):format(
		RecordCount("AuctionPrice"), RecordCount("NodeMap"), RecordCount("CharacterCopy"))
end

local function BuildPerformance(b)
	b:Header("성능")
	b:Text("이 애드온이 화면을 한 번 그릴 때 쓰는 시간입니다. 게임에 들어 있는 애드온 측정값이고, "
		.. "이 페이지를 보는 동안 1초마다 바뀝니다. '지원 안 됨'이나 '측정 꺼짐'은 게임이 값을 주지 않는다는 뜻이에요.",
		{ color = ns.UI.Theme.muted })
	local lines = {
		b:Text(MetricLine("현재", "RecentAverageTime", "최근 평균"), { font = "GameFontHighlight" }),
		b:Text(MetricLine("최고", "PeakTime", "게임 시작 후"), { font = "GameFontHighlight" }),
		b:Text(MetricLine("평균", "SessionAverageTime", "게임 시작 후"), { font = "GameFontHighlight" }),
	}
	b:Text(MemoryText, { font = "GameFontHighlight" })
	b:Buttons{ { text = "메모리 재기", width = 120, onClick = MeasureMemory,
		tooltip = ("이 애드온이 쓰는 메모리를 지금 잽니다. 모든 애드온을 훑는 무거운 측정이라 누를 때만, %d초에 한 번 잽니다."):format(MEMORY_INTERVAL) } }
	b:Text(RecordText, { font = "GameFontHighlight" })

	-- 페이지가 보일 때만 돈다(숨은 프레임은 OnUpdate가 안 불린다).
	if ProfilerState() ~= "unsupported" then
		local ticker = CreateFrame("Frame", nil, b.page)
		local sum = 0
		ticker:SetScript("OnUpdate", function(_, elapsed)
			sum = sum + elapsed
			if sum < PERF_INTERVAL then return end
			sum = 0
			for _, fs in ipairs(lines) do fs:Refresh() end
		end)
	end
end

function M:BuildOptions(b)
	b:Check{
		key = "showMinimap",
		label = "미니맵 버튼 표시",
		tooltip = "꺼도 /이지 명령이나 미니맵의 애드온 목록 버튼에서 설정 창을 열 수 있습니다.",
	}
	b:Check{ key = "loginMessage", label = "접속할 때 채팅창에 안내 메시지 표시" }
	b:KeyBind{ command = "EZYWOWF_TOGGLE", label = "설정 창 열기/닫기" }

	b:Header("설정 백업")
	b:Text("설정과 단축키를 글자 한 줄로 내보내 두었다가 다시 가져올 수 있습니다. "
		.. "와우 포에버 베타는 게임을 다시 켜면 애드온 설정과 단축키가 초기화되는 버그가 있으니, 설정을 마치면 내보내 두세요.")
	b:Buttons{
		{ text = "설정 내보내기", onClick = ShowExport },
		{ text = "설정 가져오기", onClick = ShowImport },
	}

	BuildPerformance(b)

	b:Header("사용 방법")
	b:Text("왼쪽 목록에서 기능을 고르고 설정을 바꾼 뒤 아래쪽 [저장]을 누르면 적용됩니다. "
		.. "분류 이름을 누르면 그 분류를 접거나 펼 수 있습니다.\n"
		.. "저장 전에는 바뀐 항목과 메뉴에 주황색 표시가 붙고, [되돌리기]로 취소할 수 있습니다.\n"
		.. "상인·퀘스트 자동 처리는 Shift를 누른 채 대화하면 그때만 건너뜁니다.\n\n"
		.. "설정은 게임 종료나 /reload 때 WTF 폴더의 저장 파일(EzyWOWF.lua)에 기록됩니다.")

	b:Header("명령어")
	b:Text("/이지 (또는 /ezy) - 설정 창 열기/닫기\n"
		.. "/퀘템 - 퀘스트 아이템 설정 열기\n"
		.. "/퀘템 list | next | auto | move - 아이템 목록 / 다음 아이템 / 자동 선택 / 버튼 이동")
end
