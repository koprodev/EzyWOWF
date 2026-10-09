local _, ns = ...
local M = ns.modules.Fishing
local UI = ns.UI

local VISIBILITY = "[combat] hide; [dead] hide; show"
local CAST_BINDING = "CLICK EzyWOWFFishingCast:LeftButton"
local LURE_BINDING = "CLICK EzyWOWFFishingLure:LeftButton"
local moveMode, pendingLayout, pendingActions = false, false, false
local panelShownWanted
local statusHeight = 64
local sessionHeight = 0
local SESSION_GAP = 6

local panel = CreateFrame("Frame", "EzyWOWFFishingPanel", UIParent, "BackdropTemplate,SecureHandlerStateTemplate")
panel:SetFrameStrata("MEDIUM")
panel:SetMovable(true)
panel:SetClampedToScreen(true)
panel:EnableMouse(false)
UI.ApplyPanelBackdrop(panel)
panel:Hide()

local header = CreateFrame("Button", nil, panel)
header:SetPoint("TOPLEFT", 6, -4)
header:SetPoint("TOPRIGHT", -64, -4)
header:SetHeight(20)
header:RegisterForClicks("RightButtonUp")
header:RegisterForDrag("LeftButton")

local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("LEFT", 2, 0)
title:SetText("낚시 도우미")
UI.ColorText(title, UI.Theme.accent)

local help = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
help:SetPoint("RIGHT", -2, 0)
help:SetText("우클릭: 설정")
UI.ColorText(help, UI.Theme.muted)

local endButton = CreateFrame("Button", nil, panel)
endButton:SetSize(52, 20)
endButton:SetPoint("TOPRIGHT", -6, -4)
local endText = endButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
endText:SetPoint("CENTER")
endText:SetText("마치기")
endButton:SetScript("OnClick", function() M:EndSession() end)
endButton:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText("낚시 마치기", 1, 0.82, 0)
	GameTooltip:AddLine("낚시 중 바꾼 소리·상호작용 설정을 복원합니다. 무기는 [복원] 버튼으로 돌아갑니다.", 1, 1, 1, true)
	if M.db and M.db.sessionStats then
		GameTooltip:AddLine("이번 낚시 기록을 마치며 다음 낚시부터 새로 기록합니다.", 0.65, 0.85, 1, true)
	end
	GameTooltip:Show()
end)
endButton:SetScript("OnLeave", GameTooltip_Hide)

local status = panel:CreateFontString("EzyWOWFFishingPanelStatus", "OVERLAY", "GameFontHighlightSmall")
status:SetPoint("TOPLEFT", 8, -28)
status:SetJustifyH("LEFT")
status:SetJustifyV("TOP")
status:SetSpacing(2)
status:SetWordWrap(true)

local sessionInfo = panel:CreateFontString("EzyWOWFFishingPanelSessionSummary", "OVERLAY", "GameFontHighlightSmall")
sessionInfo:SetJustifyH("LEFT")
sessionInfo:SetJustifyV("TOP")
sessionInfo:SetSpacing(2)
sessionInfo:SetWordWrap(true)
sessionInfo:SetTextColor(0.6, 0.8, 1)
sessionInfo:Hide()

local moveLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
moveLabel:SetPoint("BOTTOM", panel, "TOP", 0, 5)
moveLabel:SetText("제목을 드래그해서 이동 · [이동 완료]로 고정")
moveLabel:Hide()

local actionDefs = {
	{ action = "cast", label = "낚시", icon = "Interface\\Icons\\Trade_Fishing",
		tip = "찌를 던집니다. 입질이 오면 게임 상호작용 키 또는 찌를 클릭해 건져 올리세요." },
	{ action = "lure", label = "미끼", icon = "Interface\\Icons\\INV_Misc_Orb_03",
		tip = "가방에 있는 등록 미끼를 1순위부터 골라 장착한 낚싯대에 바릅니다." },
	{ action = "equip", label = "장착", icon = "Interface\\Icons\\INV_Fishingpole_02",
		tip = "등록한 낚싯대를 장착하고 현재 주무기·보조무기를 기억합니다." },
	{ action = "restore", label = "복원", icon = "Interface\\Icons\\Ability_Warrior_WeaponMastery",
		tip = "낚싯대를 장착하기 전에 기억한 무기로 돌아갑니다. 기능을 끄기 전에 복원하세요." },
}
local buttons = {}
local interact, interactError
local interactHovered, interactArmed = false, false
local NATIVE_INTERACT_UNAVAILABLE = "이 게임에서는 마우스 상호작용을 지원하지 않아요. 지정한 상호작용 키를 사용하세요."
local interactOwner = CreateFrame("Frame", "EzyWOWFFishingInteractBindings", UIParent, "SecureHandlerStateTemplate")
interactOwner:SetSize(1, 1)
interactOwner:SetPoint("CENTER")
interactOwner:SetAlpha(0)
interactOwner:EnableMouse(false)
interactOwner.armed = false
interactOwner:SetAttribute("fishingReelCleanupReady", false)
interactOwner:SetAttribute("_onstate-combat", 'self:ClearBindings(); self:SetAttribute("fishingReelCleanupReady",true)')
if type(RegisterStateDriver) == "function" then
	RegisterStateDriver(interactOwner, "combat", "[combat] combat; normal")
end

local function NativeInteractAPIsAvailable()
	return interact and type(SetOverrideBinding) == "function"
		and type(ClearOverrideBindings) == "function" and type(RegisterStateDriver) == "function"
		and type(GetBindingAction) == "function"
		and type(interact.SetMouseClickEnabled) == "function" and type(interact.SetMouseMotionEnabled) == "function"
		and type(interact.IsMouseMotionFocus) == "function"
end

local function NativeInteractSupported()
	return NativeInteractAPIsAvailable() and not interactError and interactOwner:GetAttribute("fishingReelCleanupReady") == true
end

local function NativeInteractBindingActive()
	return type(GetBindingAction) == "function" and ns.Clean(GetBindingAction("BUTTON1", true)) == "INTERACTTARGET"
end

local function ReportInteractError(err)
	local message = tostring(err)
	if interactError ~= message and type(ns.ErrorHandler) == "function" then ns.ErrorHandler(message) end
	interactError = message
	if interact then
		interact.interactionError = message
		interact.icon:SetDesaturated(true)
		interact.icon:SetAlpha(0.45)
	end
end

local function ClearInteractBinding()
	if not interactArmed then return end
	if not InCombatLockdown() then
		if type(ClearOverrideBindings) ~= "function" then
			ReportInteractError("Fishing interaction binding cleanup API is unavailable.")
			return
		end
		local ok, err = pcall(ClearOverrideBindings, interactOwner)
		if not ok or err == false then
			ReportInteractError(ok and "Fishing interaction binding cleanup failed." or err)
			return
		end
	end
	-- The preinstalled secure state driver clears the owner bindings during combat.
	interactArmed = false
	interactOwner.armed = false
end

local function SyncInteract()
	if not interact then return end
	local supported = NativeInteractSupported()
	local focused = type(interact.IsMouseMotionFocus) == "function" and interact:IsMouseMotionFocus()
	-- Mouse focus may become visible after OnEnter; the watchdog confirms it before binding.
	local available = supported and not moveMode and interact:IsVisible()
		and M.db and M.db.showPanel and type(M.CanInteract) == "function" and M:CanInteract()
	if not available or not interactHovered or not focused then
		ClearInteractBinding()
	elseif not interactArmed and not InCombatLockdown() then
		local ok, result = pcall(SetOverrideBinding, interactOwner, true, "BUTTON1", "INTERACTTARGET")
		if not ok or result == false then
			ReportInteractError(ok and "Fishing interaction binding registration failed." or result)
			return
		end
		interactArmed = true
		interactOwner.armed = true
	end
	local ready = available and (not interactHovered or (focused and interactArmed and NativeInteractBindingActive()))
	interact.icon:SetDesaturated(not ready)
	interact.icon:SetAlpha(ready and 1 or 0.45)
end

local interactWatchElapsed = 0
interactOwner:SetScript("OnUpdate", function(_, elapsed)
	if not interactHovered and not interactArmed then interactWatchElapsed = 0 return end
	interactWatchElapsed = interactWatchElapsed + elapsed
	if interactWatchElapsed >= 0.1 then
		interactWatchElapsed = 0
		SyncInteract()
	end
end)

local function ActionBlockReason(action)
	if moveMode then return "위치 이동을 마친 뒤 사용하세요." end
	if action == "interact" and not NativeInteractSupported() then
		if NativeInteractAPIsAvailable() and not interactError then
			return "상호작용 버튼 준비 중. 켜지지 않으면 지정한 상호작용 키를 사용하세요."
		end
		return NATIVE_INTERACT_UNAVAILABLE
	end
	if action == "interact" and interactHovered and interactArmed and not NativeInteractBindingActive() then
		return "마우스 상호작용 연결을 확인할 수 없어요. 지정한 상호작용 키를 사용하세요."
	end
	if type(M.GetActionBlockReason) == "function" then return M:GetActionBlockReason(action) end
	if action == "interact" then
		if type(M.CanInteract) ~= "function" or not M:CanInteract() then return "낚시 중에 사용할 수 있어요." end
		return
	end
	if not M:GetActionMacro(action) then return "현재 이 동작을 사용할 수 없어요." end
end

local function SetActionMacro(button, macro)
	button:SetAttribute("*type1", macro and "macro" or nil)
	button:SetAttribute("*macrotext1", macro)
	button.actionMacro = macro
	button.icon:SetDesaturated(macro == nil)
	button.icon:SetAlpha(macro and 1 or 0.45)
end

local function ApplyActions()
	SyncInteract()
	if InCombatLockdown() then
		pendingActions = true
		return
	end
	pendingActions = false
	for _, button in ipairs(buttons) do
		if button.action ~= "interact" then SetActionMacro(button, not moveMode and M:GetActionMacro(button.action) or nil) end
	end
end

local function DecorateAction(button, def)
	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetAllPoints()
	button.icon:SetTexture(def.icon)
	button.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	local border = button:CreateTexture(nil, "BACKGROUND")
	border:SetPoint("TOPLEFT", -1, 1)
	border:SetPoint("BOTTOMRIGHT", 1, -1)
	UI.ColorTexture(border, UI.Theme.border)
	local hover = button:CreateTexture(nil, "HIGHLIGHT")
	hover:SetAllPoints()
	UI.ColorTexture(hover, UI.Theme.hover)
	button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	button.label:SetPoint("TOP", button, "BOTTOM", 0, -4)
	button.label:SetText(def.label)
end

for i, def in ipairs(actionDefs) do
	local button = CreateFrame("Button", "EzyWOWFFishingPanel" .. def.action, panel, "SecureActionButtonTemplate")
	button.action = def.action
	button:RegisterForClicks("AnyUp")
	button:SetAttribute("useOnKeyDown", false)
	DecorateAction(button, def)

	button:SetScript("PreClick", function(self, mouseButton, down)
		self.actionReady = false
		self.actionBlockReason = nil
		if down or mouseButton ~= "LeftButton" or InCombatLockdown() then return end
		if moveMode then
			SetActionMacro(self, nil)
			self.actionBlockReason = ActionBlockReason(self.action)
			return
		end
		local ready = M:BeforeAction(self.action)
		self.actionReady = ready ~= false
		SetActionMacro(self, self.actionReady and M:GetActionMacro(self.action) or nil)
		if not self.actionMacro then self.actionBlockReason = ActionBlockReason(self.action) end
	end)
	button:SetScript("PostClick", function(self, mouseButton, down)
		if down then return end
		if mouseButton == "RightButton" then
			ns:OpenWindow("Fishing")
		elseif mouseButton == "LeftButton" then
			if self.actionReady and self.actionMacro and not InCombatLockdown() then
				M:AfterAction(self.action)
			else
				local reason = self.actionBlockReason or ActionBlockReason(self.action)
				if reason then ns.Print(def.label .. ": " .. reason) end
			end
		end
		self.actionReady = false
		self.actionBlockReason = nil
		ApplyActions()
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(def.label, 1, 0.82, 0)
		GameTooltip:AddLine(def.tip, 1, 1, 1, true)
		local reason = ActionBlockReason(self.action)
		if reason then GameTooltip:AddLine(reason, 1, 0.65, 0.2, true) end
		GameTooltip:AddLine("우클릭: 낚시 설정", 0.65, 0.62, 0.55)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)
	buttons[i] = button
end

interact = CreateFrame("Frame", "EzyWOWFFishingPanelinteract", panel)
interact.action = "interact"
DecorateAction(interact, { label = "건지기", icon = "Interface\\Icons\\INV_Misc_Fish_02" })
if type(interact.SetMouseClickEnabled) == "function" and type(interact.SetMouseMotionEnabled) == "function" then
	interact:SetMouseClickEnabled(false)
	interact:SetMouseMotionEnabled(true)
else
	interact:EnableMouse(false)
end
interact:SetScript("OnEnter", function(self)
	interactHovered = true
	SyncInteract()
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText("건지기", 1, 0.82, 0)
	GameTooltip:AddLine("현재 상호작용 키: " .. M:GetInteractKeyText(), 0.65, 0.85, 1, true)
	GameTooltip:AddLine("낚시 중 입질이 오면 왼쪽 클릭으로 게임 상호작용을 실행합니다. 찌가 선택되지 않으면 찌를 향해 시야를 맞추세요.", 1, 1, 1, true)
	local reason = ActionBlockReason("interact")
	if reason then GameTooltip:AddLine(reason, 1, 0.65, 0.2, true) end
	GameTooltip:Show()
end)
interact:SetScript("OnLeave", function()
	interactHovered = false
	ClearInteractBinding()
	GameTooltip_Hide()
end)
interact:SetScript("OnHide", function()
	interactHovered = false
	ClearInteractBinding()
end)
buttons[#buttons + 1] = interact

function M:IsMoveMode()
	return moveMode
end

function M:GetMouseInteractStatus()
	if not NativeInteractAPIsAvailable() then return "건지기: 지원 안 됨" end
	if interactError then return "건지기: 마우스 입력 경로 오류" end
	if interactOwner:GetAttribute("fishingReelCleanupReady") ~= true then return "건지기: 보안 정리 실행 확인 불가" end
	local mouseAction = ns.Clean(GetBindingAction("BUTTON1", true))
	local details = (" · 마우스 진입: %s · 포커스: %s · 현재 클릭 명령: %s"):format(
		interactHovered and "예" or "아니오", interact:IsMouseMotionFocus() and "예" or "아니오",
		type(mouseAction) == "string" and mouseAction ~= "" and mouseAction or "미지정")
	if interactArmed then
		return (NativeInteractBindingActive() and "건지기: BUTTON1 → INTERACTTARGET 연결 확인" or "건지기: 마우스 상호작용 미연결") .. details
	end
	return "건지기: " .. (ActionBlockReason("interact") or "아이콘 위에 마우스를 올리세요.") .. details
end

local function SessionText(method, fallback)
	if type(M[method]) == "function" then
		local value = M[method](M)
		if type(value) == "string" then return value end
	end
	return fallback
end

function M:UpdatePanel()
	if not self.db then return end
	local statusText = self:GetStatusText()
	local sessionText = ""
	if self.db.sessionStats and self.db.showSessionOnPanel and type(self.GetSessionSummary) == "function" then
		local summary = self:GetSessionSummary()
		if type(summary) == "string" then sessionText = summary end
	end
	if InCombatLockdown() then
		status:SetText(statusText)
		sessionInfo:SetText(sessionText)
		pendingLayout = true
		ApplyActions()
		return
	end
	local width = math.max(240, (self.db.size + 20) * #buttons + 16) - 16
	-- Measure wrapped text without the previous frame's height constraint.
	status:SetWidth(width)
	status:SetHeight(0)
	status:SetText(statusText)
	sessionInfo:SetWidth(width)
	sessionInfo:SetHeight(0)
	sessionInfo:SetText(sessionText)
	local height = math.max(64, math.ceil(math.max(status:GetStringHeight() or 0, status:GetHeight() or 0)))
	local summaryHeight = sessionText ~= "" and math.max(14,
		math.ceil(math.max(sessionInfo:GetStringHeight() or 0, sessionInfo:GetHeight() or 0))) or 0
	local resized = height ~= statusHeight or summaryHeight ~= sessionHeight
	statusHeight, sessionHeight = height, summaryHeight
	status:SetHeight(statusHeight)
	sessionInfo:SetHeight(sessionHeight)
	local show = self:IsActive() and self.db.showPanel and (moveMode or self:ShouldShowPanel()) and true or false
	if resized or show ~= panelShownWanted then self:ApplyPanelLayout() end
	ApplyActions()
end

function M:ApplyPanelLayout()
	local db = self.db
	if not db then return end
	if InCombatLockdown() then
		pendingLayout = true
		return
	end
	pendingLayout = false
	if not db.enabled or not db.showPanel then moveMode = false end
	local size = db.size
	local width = math.max(240, (size + 20) * #buttons + 16)
	local sessionSpace = sessionHeight > 0 and (SESSION_GAP + sessionHeight) or 0
	local actionTop = 40 + statusHeight + sessionSpace
	panel:SetSize(width, actionTop + size + 22)
	panel:SetScale(db.scale)
	panel:ClearAllPoints()
	panel:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
	status:SetWidth(width - 16)
	status:SetHeight(statusHeight)
	sessionInfo:ClearAllPoints()
	sessionInfo:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -(28 + statusHeight + SESSION_GAP))
	sessionInfo:SetWidth(width - 16)
	sessionInfo:SetHeight(sessionHeight)
	sessionInfo:SetShown(sessionHeight > 0)
	local cellWidth = (width - 16) / #buttons
	for i, button in ipairs(buttons) do
		button:SetSize(size, size)
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", panel, "TOPLEFT", 8 + (i - 1) * cellWidth + (cellWidth - size) / 2, -actionTop)
	end
	help:SetText(moveMode and "이동 중" or "우클릭: 설정")
	moveLabel:SetShown(moveMode)
	local show = self:IsActive() and db.showPanel and (moveMode or self:ShouldShowPanel()) and true or false
	panelShownWanted = show
	if RegisterStateDriver and show then
		RegisterStateDriver(panel, "visibility", VISIBILITY)
	else
		if UnregisterStateDriver then UnregisterStateDriver(panel, "visibility") end
		panel:SetShown(show)
	end
	self:UpdatePanel()
end

function M:SetMoveMode(on)
	local db = self.db
	if on and (not db or not db.enabled or not db.showPanel or not self:IsActive()) then return end
	if on and InCombatLockdown() then return end
	moveMode = on and true or false
	self:ApplyPanelLayout()
	ns:Fire("REFRESH_UI")
	if moveMode then ns.Print("낚시 패널 제목을 드래그해서 옮기고 [이동 완료]를 누르세요.") end
end

header:SetScript("OnClick", function(_, mouseButton)
	if mouseButton == "RightButton" then ns:OpenWindow("Fishing") end
end)
header:SetScript("OnDragStart", function()
	if moveMode and not InCombatLockdown() then panel:StartMoving() end
end)
header:SetScript("OnDragStop", function()
	if InCombatLockdown() then pendingLayout = true return end
	panel:StopMovingOrSizing()
	if not moveMode or not M.db then return end
	local point, _, relPoint, x, y = panel:GetPoint(1)
	M.db.point, M.db.relPoint, M.db.x, M.db.y = point, relPoint, x, y
end)

local function ResetPosition()
	if InCombatLockdown() then return end
	local db = M.db
	if not db then return end
	for _, key in ipairs({ "point", "relPoint", "x", "y" }) do db[key] = M.defaults[key] end
	M:ApplyPanelLayout()
end

ns:On("FISHING_UPDATED", function() M:UpdatePanel() end)
ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
	interactHovered = false
	ClearInteractBinding()
	SyncInteract()
	if moveMode then
		moveMode = false
		pendingLayout, pendingActions = true, true
	end
end)
ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
	if pendingLayout then
		panel:StopMovingOrSizing()
		M:ApplyPanelLayout()
	elseif pendingActions then
		M:UpdatePanel()
	end
end)
ns:RegisterEvent("PLAYER_LOGOUT", function()
	interactHovered = false
	ClearInteractBinding()
end)
M:SetPanel(panel)

function M:BuildOptions(b)
	local function Disabled() return not self.db or not self.db.enabled or InCombatLockdown() end
	local function PanelDisabled() return Disabled() or not self.db.showPanel or not self:IsActive() end
	local function LureOptions(key)
		local current = ns:GetSetting(self, key)
		local others = {}
		for rank = 1, 3 do
			local otherKey = "lure" .. rank
			local value = ns:GetSetting(self, otherKey)
			if otherKey ~= key and type(value) == "number" and value > 0 then others[value] = true end
		end
		local options = {}
		for _, option in ipairs(self:GetBagOptions("lure", current)) do
			if not others[option.value] or option.value == current then options[#options + 1] = option end
		end
		return options
	end

	b:Text("낚시·건지기·미끼·낚싯대 장착·무기 복원을 화면 버튼으로 사용합니다. 찌 던지기와 미끼 바르기는 직접 눌러 실행하며, 입질이 오면 [건지기] 버튼·게임 상호작용 키 또는 찌 클릭으로 건져 올리세요. 전투 중에는 패널을 숨깁니다.")
	b:Check{ key = "enabled", label = "사용", tooltip = "끄기 전에 [복원]을 눌러 원래 무기로 돌아가세요." }
	b:Text(function() return self:GetStatusText() end, { font = "GameFontHighlight" })

	b:Header("조작·단축키")
	b:KeyBind{ command = CAST_BINDING, label = "찌 던지기", depends = "enabled" }
	b:KeyBind{ command = "INTERACTTARGET", label = "찌 건져 올리기 (게임 상호작용 키)", depends = "enabled",
		tooltip = "게임의 일반 상호작용 단축키와 공유합니다." }
	b:KeyBind{ command = LURE_BINDING, label = "미끼 바르기", depends = "enabled" }
	b:Text("건져 올리기 키는 게임의 다른 상호작용에도 쓰입니다. 찌가 선택되지 않으면 찌를 향해 시야를 맞추거나 마우스로 클릭하세요.", { color = UI.Theme.muted })
	b:Text(function()
		return NativeInteractSupported() and "[건지기]는 낚시 중에만 켜집니다. 입질이 오면 왼쪽 클릭으로 건져 올리세요."
			or NATIVE_INTERACT_UNAVAILABLE
	end, { color = UI.Theme.muted })

	b:Header("낚싯대·미끼")
	b:Dropdown{ key = "pole", label = "사용할 낚싯대", width = 280, depends = "enabled",
		options = function() return self:GetBagOptions("pole", ns:GetSetting(self, "pole")) end,
		tooltip = "가방의 낚싯대를 등록한 뒤 패널의 [장착]을 누르세요. 현재 무기는 [복원]으로 되돌립니다." }
	for rank = 1, 3 do
		local key = "lure" .. rank
		b:Dropdown{ key = key, label = "미끼 " .. rank .. "순위", width = 280, depends = "enabled",
			options = function() return LureOptions(key) end }
	end
	b:Text("가방에 있는 등록 미끼를 순서대로 사용합니다. 미끼는 장착한 낚싯대에 바르며, 낚싯대·미끼 선택은 [저장]을 눌러 적용합니다.", { color = UI.Theme.muted })

	b:Header("낚시 패널")
	b:Check{ key = "showPanel", label = "화면에 낚시 패널 보이기", depends = "enabled" }
	b:Slider{ key = "size", label = "버튼 크기", min = 22, max = 48, step = 2, format = "%d", depends = { "enabled", "showPanel" } }
	b:Slider{ key = "scale", label = "패널 크기", min = 0.6, max = 2, step = 0.05, format = "%.2f", depends = { "enabled", "showPanel" } }
	b:Buttons{
		{ text = "패널 열기", onClick = function() self:ShowPanel() end, disabled = PanelDisabled },
		{ text = "위치 이동", textFunc = function() return moveMode and "이동 완료" or "위치 이동" end,
			onClick = function() self:SetMoveMode(not moveMode) end, disabled = PanelDisabled },
		{ text = "기본 위치로", onClick = ResetPosition, disabled = PanelDisabled },
	}
	b:Text("낚싯대를 장착하거나 낚시 중일 때 보입니다. 처음 시작할 때는 [패널 열기]를 누른 뒤 [장착]으로 낚싯대를 전환하세요. [위치 이동]은 자리 미리보기이며, 이동 중에는 조작 버튼이 실행되지 않습니다. 제목을 우클릭하면 이 설정을 엽니다.", { color = UI.Theme.muted })

	b:Header("찌 상호작용")
	b:Check{ key = "rangeAssist", label = "낚시 중 찌 상호작용 범위 넓히기", depends = "enabled",
		tooltip = "낚시 중에만 범위를 넓히고 종료하면 원래 게임 설정으로 되돌립니다." }
	b:Check{ key = "bobberIcon", label = "낚시 중 상호작용 아이콘 보이기", depends = "enabled",
		tooltip = "낚시 중 찌 상호작용 아이콘을 표시하고 종료하면 원래 게임 설정으로 되돌립니다." }

	b:Header("입질 소리")
	b:Check{ key = "soundFocus", label = "낚시 중 소리 크기 바꾸기", depends = "enabled",
		tooltip = "낚시 시전부터 [낚시 마치기] 또는 [복원]을 누를 때까지 효과음·음악·환경음 크기를 바꿉니다." }
	for _, def in ipairs({ { key = "effectVolume", label = "효과음 크기 (0~1)" },
		{ key = "musicVolume", label = "음악 크기 (0~1)" }, { key = "ambienceVolume", label = "환경음 크기 (0~1)" } }) do
		b:Slider{ key = def.key, label = def.label, min = 0, max = 1, step = 0.05, format = "%.2f", depends = { "enabled", "soundFocus" } }
	end
	b:Text("소리 강조는 낚시 시전부터 [낚시 마치기] 또는 무기 복원까지 적용되며, 전투·죽음·지역 이동 때도 복원됩니다. 0은 소리 없음, 1은 최대이며, 효과음 크기는 입질 소리와 함께 다른 효과음에도 적용됩니다.", { color = UI.Theme.muted })

	b:Header("준비 상태 알림")
	b:Check{ key = "alerts", label = "낚싯대·미끼·가방·숙련도 알림", depends = "enabled" }
	b:Check{ key = "announceWarnings", label = "새 준비 상태 경고를 채팅에 표시", depends = { "enabled", "alerts" },
		tooltip = "낚시 준비 중 새로 생긴 경고를 채팅에 표시합니다." }
	b:Check{ key = "warningSound", label = "새 준비 상태 경고에 알림 소리", depends = { "enabled", "alerts" },
		tooltip = "새 경고가 생기면 알림 소리를 냅니다. 채팅 표시와 따로 켜고 끌 수 있습니다." }
	b:Slider{ key = "lowLureCount", label = "미끼 부족 기준 (개 이하)", min = 0, max = 20, step = 1, format = "%d", depends = { "enabled", "alerts" } }
	b:Slider{ key = "lowBagSlots", label = "가방 부족 기준 (빈칸 이하)", min = 0, max = 20, step = 1, format = "%d", depends = { "enabled", "alerts" } }
	b:Slider{ key = "lureWarnSeconds", label = "미끼 만료 알림 (남은 초)", min = 0, max = 180, step = 10, format = "%d", depends = { "enabled", "alerts" } }

	b:Header("이번 낚시 기록")
	b:Text("첫 찌를 던질 때 기록을 시작해 시간·시전 횟수·실제로 획득한 낚시 전리품을 기록합니다. 물고기와 잡동사니를 함께 셉니다.")
	b:Check{ key = "sessionStats", label = "이번 낚시 기록 사용", depends = "enabled" }
	b:Check{ key = "showSessionOnPanel", label = "낚시 패널에 이번 기록 요약 표시", depends = { "enabled", "sessionStats", "showPanel" } }
	b:Text("전투·죽음·지역 이동 등으로 중단하면 다음 낚시부터 이어서 기록합니다. [마치기] 또는 [복원] 뒤 다시 낚시하면 새 기록을 시작합니다.", { color = UI.Theme.muted })
	b:Text(function() return SessionText("GetSessionSummary", "이번 낚시 기록을 준비하고 있어요.") end, { font = "GameFontHighlight" })
	b:Text(function() return SessionText("GetSessionItemsText", "아직 획득 기록이 없어요.") end, { color = UI.Theme.muted })
	b:Buttons{
		{ text = "이번 기록 초기화", width = 150,
			onClick = function() if type(self.ResetFishingSession) == "function" then self:ResetFishingSession() end end,
			disabled = function() return not self.db or not self.db.enabled or not self.db.sessionStats or type(self.ResetFishingSession) ~= "function" end,
			tooltip = "이번 낚시의 시간·시전 횟수·획득 목록을 초기화합니다." },
	}

	b:Header("관련 기능")
	b:Buttons{
		{ text = "낚시 마치기", width = 150, onClick = function() self:EndSession() end,
			tooltip = "소리·상호작용 설정을 복원합니다. 무기는 패널의 [복원]으로 되돌립니다." },
		{ text = "상태 진단", width = 130,
			onClick = function() if type(self.PrintDiagnostics) == "function" then self:PrintDiagnostics() end end,
			disabled = function() return type(self.PrintDiagnostics) ~= "function" end,
			tooltip = "현재 낚시 버튼·단축키·장비·숙련도 상태를 채팅에 표시합니다." },
	}
	b:Buttons{
		{ text = "낚시 전문가 찾기", width = 150, onClick = function() self:OpenTrainer() end },
		{ text = "빠른 자동 루팅 설정", width = 170, onClick = function() ns:OpenWindow("FastLoot") end },
	}
end
