-- EzyWOWF 코어: 모듈 등록, 저장 데이터, 이벤트, "저장 전 변경 사항" 관리.
--
-- 새 기능은 Modules\ 폴더에 파일을 추가하고 ns:NewModule()로 등록한다.
--   local M = ns:NewModule("Key", { title = "표시 이름", category = "auto", order = 20, icon = "Interface\\Icons\\...", defaults = {...}, bindings = {...} })
--   category uses ns.categories: left-side category, feature tab, then option page.
--   order 는 초기화·가져오기 순서까지 정하니 함부로 바꾸지 말 것. 메뉴는 (order, key) 순.
--   M.db                      저장된 설정 (로드 후)
--   M:OnInitialize()          저장 데이터 로드 직후
--   M:OnLogin()               접속 완료 후
--   M:BuildOptions(builder)   설정 창 페이지 구성 (Widgets.lua 참고)
--   M:ApplySettings(changes)  설정 창에서 [저장]을 눌렀을 때
--   M:GetTooltipLine()        미니맵 버튼 툴팁에 보일 한 줄 (왼쪽, 오른쪽)

local ADDON_NAME, ns = ...

ns.title = "EzyWOWF"
ns.icon = "Interface\\Icons\\Trade_Engineering"
ns.fallbackIcon = "Interface\\Icons\\INV_Misc_Gear_01"   -- ns.icon 파일이 없을 때 대신 쓸 아이콘
local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.version = GetMetadata and GetMetadata(ADDON_NAME, "Version") or "?"

---------------------------------------------------------------------------
-- 아이콘: 파일이 없으면 초록 네모 대신 대체 아이콘 → 물음표
---------------------------------------------------------------------------
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local QUESTION_MARK_ID = 134400
local iconCache = {}   -- [경로] = fileID | false(없음)
local iconLookupOK     -- nil = 아직 모름

local function LookUpFileID(path)
	local ok, id = pcall(GetFileIDFromPath, path)
	if not (ok and type(id) == "number" and id > 0) and not path:lower():find("%.blp$") then
		ok, id = pcall(GetFileIDFromPath, path .. ".blp")
	end
	if ok and type(id) == "number" and id > 0 then return id end
end

-- 있는 파일은 찾고 없는 파일은 못 찾는지 한 번 떠본다. 조회를 믿을 수 없으면 경로를 그대로 넘긴다.
function ns.GetIcon(path, fallback)
	if type(path) ~= "string" then return path or QUESTION_MARK_ID end
	if iconLookupOK == nil then
		iconLookupOK = type(GetFileIDFromPath) == "function"
			and LookUpFileID(QUESTION_MARK) ~= nil
			and LookUpFileID("Interface\\Icons\\EzyWOWF_NoSuchIcon_zz") == nil
	end
	if not iconLookupOK then return path end
	local id = iconCache[path]
	if id == nil then
		id = LookUpFileID(path) or false
		iconCache[path] = id
	end
	if id then return id end
	if fallback then return ns.GetIcon(fallback) end
	return QUESTION_MARK_ID
end

BINDING_HEADER_EZYWOWF = ns.title
BINDING_NAME_EZYWOWF_TOGGLE = "설정 창 열기/닫기"

local PREFIX = "|cff33ccff[EzyWOWF]|r "
function ns.Print(msg)
	print(PREFIX .. msg)
end

-- 전투 중 비밀값(secret value)은 비교 자체가 오류라서 nil로 취급한다.
local IsSecret = issecretvalue or function() return false end
function ns.Clean(v)
	if v ~= nil and IsSecret(v) then return nil end
	return v
end

---------------------------------------------------------------------------
-- 내부 콜백 (UI 갱신 등)
---------------------------------------------------------------------------
local callbacks = {}

function ns:On(name, fn)
	callbacks[name] = callbacks[name] or {}
	table.insert(callbacks[name], fn)
end

function ns:Fire(name, ...)
	local list = callbacks[name]
	if not list then return end
	for i = 1, #list do list[i](...) end
end

---------------------------------------------------------------------------
-- 게임 이벤트 (한 이벤트에 여러 모듈이 등록 가능)
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}     -- [이벤트] = { fn, ... } 부르는 순서대로
local unitFilter = {}   -- [이벤트] = false(모든 유닛) | { [유닛] = true }, 아직 등록 전이면 nil

-- 한 모듈이 터져도 같은 이벤트의 다음 모듈은 받는다. 오류 창·BugSack에는 그대로 보고된다.
local ErrorHandler = CallErrorHandler or function(err) return geterrorhandler()(err) end
ns.ErrorHandler = ErrorHandler

-- 구독자 유닛의 합집합으로 프레임 등록을 맞춘다. 전체 구독자가 있거나 유닛이 3개 이상이면 그냥 다 받는다.
local function Subscribe(event, units)
	local old = unitFilter[event]
	local new
	if units == nil or old == false then
		new = false
	else
		new = {}
		if old then for u in pairs(old) do new[u] = true end end
		for _, u in ipairs(units) do new[u] = true end
	end
	if old ~= nil then
		if new == false and old == false then return end
		if new and old then
			local same = true
			for u in pairs(new) do if not old[u] then same = false break end end
			if same then return end
		end
		pcall(eventFrame.UnregisterEvent, eventFrame, event)
	end
	unitFilter[event] = new
	if new then
		local list = {}
		for u in pairs(new) do list[#list + 1] = u end
		table.sort(list)
		if #list <= 2 then
			-- 반환값 의미가 문서에 없어서 실제로 등록됐는지로 판정한다.
			local ok = pcall(eventFrame.RegisterUnitEvent, eventFrame, event, list[1], list[2])
			if ok and eventFrame:IsEventRegistered(event) then return end
		end
	end
	pcall(eventFrame.RegisterEvent, eventFrame, event)
end

local function AddHandler(event, fn, first, units)
	local list = handlers[event]
	if not list then
		list = {}
		handlers[event] = list
	end
	if first then
		table.insert(list, 1, fn)
	else
		list[#list + 1] = fn
	end
	Subscribe(event, units)
end

-- first가 참이면 다른 모듈보다 먼저 받는다. (예: 빠른 줍기가 줍기 전에 전리품을 살펴봐야 할 때)
function ns:RegisterEvent(event, fn, first)
	AddHandler(event, fn, first, nil)
end

-- unit1(, unit2)의 이벤트만 받는다. 합집합으로 등록될 수 있어서 여기서 한 번 더 거른다.
function ns:RegisterUnitEvent(event, fn, unit1, unit2)
	assert(type(unit1) == "string", "RegisterUnitEvent: unit1 필요")
	AddHandler(event, function(ev, unit, ...)
		if unit == unit1 or (unit2 ~= nil and unit == unit2) then return fn(ev, unit, ...) end
	end, false, { unit1, unit2 })
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do xpcall(list[i], ErrorHandler, event, ...) end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
ns.categories = {
	{ key = "general",   title = "일반",        icon = "Interface\\Icons\\INV_Misc_Gear_01" },
	{ key = "auto",      title = "자동화",      icon = "Interface\\Icons\\INV_Gizmo_02" },
	{ key = "quest",     title = "퀘스트",      icon = "Interface\\Icons\\INV_Misc_Book_08" },
	{ key = "map",       title = "지도·길찾기", icon = "Interface\\Icons\\INV_Misc_Map_01" },
	{ key = "professions", title = "직업기술",   icon = "Interface\\Icons\\Trade_BlackSmithing" },
	{ key = "info",      title = "화면 정보",   icon = "Interface\\Icons\\INV_Misc_Spyglass_02" },
	{ key = "item",      title = "툴팁·아이템", icon = "Interface\\Icons\\INV_Misc_Bag_08" },
	{ key = "interface", title = "인터페이스",  icon = "Interface\\Icons\\INV_Misc_Wrench_01" },
	{ key = "hunter",    title = "사냥꾼",      icon = "Interface\\Icons\\ClassIcon_Hunter" },
	{ key = "druid",     title = "드루이드",    icon = "Interface\\Icons\\ClassIcon_Druid" },
	{ key = "etc",       title = "기타" },
}

ns.modules = {}
ns.moduleOrder = {}

function ns:NewModule(key, info)
	local m = info or {}
	m.key = key
	m.title = m.title or key
	m.category = m.category or "etc"
	m.order = m.order or 100
	m.bindings = m.bindings or {}
	self.modules[key] = m
	table.insert(self.moduleOrder, m)
	return m
end

-- 메뉴 순서용 복사본. moduleOrder 자체는 초기화 순서라 다시 정렬하지 않는다.
local function MenuOrder(a, b)
	if a.order ~= b.order then return a.order < b.order end
	return a.key < b.key
end

function ns:ModulesInCategory(categoryKey)
	local list = {}
	for _, m in ipairs(self.moduleOrder) do
		if m.category == categoryKey then list[#list + 1] = m end
	end
	table.sort(list, MenuOrder)
	return list
end

function ns:GetCategory(key)
	for _, c in ipairs(self.categories) do
		if c.key == key then return c end
	end
end

-- 채팅 안내용 설정 창 경로. 예: "퀘스트 > 퀘스트 아이템"
function ns:SettingsPath(moduleKey)
	local m = self.modules[moduleKey]
	local c = m and self:GetCategory(m.category)
	if not c then return "" end
	return c.title .. " > " .. m.title
end

---------------------------------------------------------------------------
-- 여러 모듈이 같이 쓰는 도우미
---------------------------------------------------------------------------
-- 착용 장비 중 가장 낮은 내구도(%)를 돌려준다. 내구도 있는 장비가 없으면 nil.
function ns.GetLowestDurability()
	local lowest
	for slot = INVSLOT_FIRST_EQUIPPED or 1, INVSLOT_LAST_EQUIPPED or 19 do
		local cur, max = GetInventoryItemDurability(slot)
		cur, max = ns.Clean(cur), ns.Clean(max)
		if cur and max and max > 0 then
			local pct = cur / max * 100
			if not lowest or pct < lowest then lowest = pct end
		end
	end
	return lowest
end

-- 이 캐릭터가 배운 주문인지.
-- IsPlayerSpell은 호환용 함수라 게임 설정(loadDeprecationFallbacks)이 꺼져 있으면 없다. 새 API를 먼저 쓴다.
function ns.IsSpellKnown(spellID)
	if C_SpellBook and C_SpellBook.IsSpellKnown then
		local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
		return C_SpellBook.IsSpellKnown(spellID, bank) and true or false
	end
	return IsPlayerSpell and IsPlayerSpell(spellID) and true or false
end

-- 배운 등급의 주문 번호. 등급마다 번호가 다르다(천벌 1등급 5176, 2등급 5177 …).
-- 그 번호를 모르면 같은 이름으로 물어 배운 최고 등급을 쓴다. 하나도 못 배웠으면 nil.
function ns.KnownSpellRank(spellID)
	if ns.IsSpellKnown(spellID) then return spellID end
	local name = C_Spell.GetSpellName and ns.Clean(C_Spell.GetSpellName(spellID))
	local info = name and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(name)
	local best = type(info) == "table" and ns.Clean(info.spellID) or nil
	if type(best) == "number" and ns.IsSpellKnown(best) then return best end
end

function ns.FormatMoney(copper)
	if GetMoneyString then return GetMoneyString(copper, true) end
	local gold = math.floor(copper / 10000)
	local silver = math.floor(copper / 100) % 100
	return ("%d골드 %d실버 %d코퍼"):format(gold, silver, copper % 100)
end

local function CopyDefaults(src, dst)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			CopyDefaults(v, dst[k])
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

---------------------------------------------------------------------------
-- 저장 전 변경 사항
-- 설정 창의 컨트롤은 여기에 값을 쌓아 두고, [저장]을 누를 때 실제로 반영한다.
---------------------------------------------------------------------------
local pending = {}          -- [모듈 키] = { [설정 키] = 값 }
local pendingBindings = {}  -- [바인딩 명령] = 키 문자열 | false(해제)

function ns:GetSetting(m, key)
	local p = pending[m.key]
	if p and p[key] ~= nil then return p[key] end
	return m.db[key]
end

function ns:SetSetting(m, key, value)
	if value == m.db[key] then
		local p = pending[m.key]
		if p then
			p[key] = nil
			if next(p) == nil then pending[m.key] = nil end
		end
	else
		pending[m.key] = pending[m.key] or {}
		pending[m.key][key] = value
	end
	self:Fire("PENDING_CHANGED")
end

function ns:IsPending(m, key)
	local p = pending[m.key]
	return p ~= nil and p[key] ~= nil
end

function ns:GetPendingBindingKey(command)
	local key = pendingBindings[command]
	if key ~= nil then return key or nil end
	return (GetBindingKey(command))
end

function ns:SetPendingBinding(command, key)
	if (key or nil) == GetBindingKey(command) then
		pendingBindings[command] = nil
	else
		pendingBindings[command] = key or false
	end
	self:Fire("PENDING_CHANGED")
end

function ns:IsBindingPending(command)
	return pendingBindings[command] ~= nil
end

function ns:ModuleHasPending(m)
	if pending[m.key] then return true end
	for _, command in ipairs(m.bindings) do
		if pendingBindings[command] ~= nil then return true end
	end
	return false
end

function ns:HasPending()
	return next(pending) ~= nil or next(pendingBindings) ~= nil
end

function ns:SaveSettings()
	if InCombatLockdown() then
		ns.Print("전투 중에는 저장할 수 없어요. 전투가 끝난 뒤 저장해 주세요.")
		return false
	end

	if next(pendingBindings) then
		for command in pairs(pendingBindings) do
			for _, key in ipairs({ GetBindingKey(command) }) do
				SetBinding(key)
			end
		end
		for command, key in pairs(pendingBindings) do
			if key then SetBinding(key, command) end
		end
		SaveBindings(GetCurrentBindingSet())
		wipe(pendingBindings)
	end

	local saved = pending
	pending = {}
	for moduleKey, changes in pairs(saved) do
		local m = self.modules[moduleKey]
		for k, v in pairs(changes) do
			m.db[k] = v
		end
		if m.ApplySettings then m:ApplySettings(changes) end
	end

	self:Fire("PENDING_CHANGED")
	ns.Print("설정을 저장했습니다.")
	return true
end

function ns:DiscardSettings()
	wipe(pending)
	wipe(pendingBindings)
	self:Fire("PENDING_CHANGED")
end

---------------------------------------------------------------------------
-- 로드
---------------------------------------------------------------------------
ns:RegisterEvent("ADDON_LOADED", function(_, name)
	if name ~= ADDON_NAME then return end

	-- 포에버 베타는 저장 파일을 못 불러오는 버그가 있어서, 새로 시작했는지 알려 줄 때 쓴다.
	ns.freshStart = (EzyWOWFDB == nil)
	EzyWOWFDB = EzyWOWFDB or {}
	ns.db = EzyWOWFDB
	ns.db.modules = ns.db.modules or {}
	ns.db.window = ns.db.window or {}

	table.sort(ns.moduleOrder, function(a, b) return a.order < b.order end)
	for _, m in ipairs(ns.moduleOrder) do
		ns.db.modules[m.key] = ns.db.modules[m.key] or {}
		m.db = ns.db.modules[m.key]
		if m.defaults then CopyDefaults(m.defaults, m.db) end
		-- 한 모듈 초기화가 터져도 뒤 모듈은 살린다.
		if m.OnInitialize then xpcall(m.OnInitialize, ErrorHandler, m) end
	end
end)

ns:RegisterEvent("PLAYER_LOGIN", function()
	for _, m in ipairs(ns.moduleOrder) do
		if m.OnLogin then xpcall(m.OnLogin, ErrorHandler, m) end
	end
end)

SLASH_EZYWOWF1 = "/ezy"
SLASH_EZYWOWF2 = "/이지"
SlashCmdList.EZYWOWF = function()
	ns:ToggleWindow()
end
