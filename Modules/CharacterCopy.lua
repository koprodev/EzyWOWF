-- 캐릭터 설정 복사: 다른 캐릭터(A)의 행동 단축바 배치, 단축키, 캐릭터 전용 매크로, 단축바 켜기/끄기,
-- 편집 모드 레이아웃을 이 캐릭터(B)로 가져온다.
--
-- 두 가지 방법:
--   캐릭터 목록: 캐릭터마다 접속할 때와 나갈 때(/reload 포함) 설정을 계정 공용 저장 파일(EzyWOWFDB.characterCopy)에
--               자동으로 기록해 두고, B에서 목록의 A를 골라 바로 가져온다.
--   글자 한 줄: 내보냈다가 붙여 넣는다. (MySlot과 같은 방식) 저장 파일을 거치지 않아 다른 계정으로도 옮길 수 있다.
--
-- 가져오는 순서가 중요하다: 매크로를 먼저 만들어야 단축바에 매크로를 놓을 수 있다.
-- 단축바 칸
--   주문은 번호로 집고, 그 등급을 아직 모르면 이름으로 집어서 배운 가장 높은 등급을 놓는다.
--   A에서 빈 칸은 B에서도 비운다(옵션). 탈것·애완동물·장비 구성처럼 옮기기 어려운 칸은 건드리지 않는다.
-- 단축키: A의 전체 단축키로 맞춘다. A에 없는 단축키는 지운다. 이 캐릭터가 쓰는 단축키 세트에 저장된다.
-- 편집 모드: 레이아웃 번호는 기본 제공 레이아웃(현대식 등)을 먼저 세고, 그 뒤에 저장된 레이아웃이 온다.
--   기본 제공·계정 공용 레이아웃은 이름으로 찾아 C_EditMode.SetActiveLayout만 부른다.
--   (편집 모드 관리자 함수를 애드온이 직접 부르면 행동 단축바 같은 보안 프레임이 오염될 수 있다)
--   A의 레이아웃이 캐릭터 전용이면 B에서 쓸 수 없으므로 편집 모드의 공유 기능을 안내한다.
-- 전투 중에는 가져올 수 없다.

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local M = ns:NewModule("CharacterCopy", {
	title = "캐릭터 설정 복사",
	category = "general",
	icon = "Interface\\Icons\\Ability_Rogue_Disguise",
	order = 20,
	defaults = {
		actions = true,
		clearEmpty = true,
		bindings = true,
		macros = true,
		bars = true,
		layout = true,
	},
})

local PREFIX = "EZYC1:"
local LEGACY_PREFIX = "MTKC1:"   -- 옛 이름(MyToolkit) 시절 문자열
local MAX_SLOT = 180
local MACRO_ICON = "INV_MISC_QUESTIONMARK"
local CHARACTER_LAYOUT = Enum and Enum.EditModeLayoutType and Enum.EditModeLayoutType.Character or 2

local function SpellName(id)
	return C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
end

local function Setting(key)
	return ns:GetSetting(M, key)
end

-- 캐릭터 목록의 키.
-- 포에버는 캐릭터 이름이 "이름 성" 두 단어이고 UnitName/UnitFullName의 두 번째 값이 서버가 아니라 성이다.
-- 그래서 키는 "아무-개"(이름-성)이 된다. 포에버 이름은 지역 전체에서 하나뿐이라 서버가 없어도 겹치지 않는다.
local function CharacterName()
	local name, realm = UnitFullName("player")
	if not realm or realm == "" then realm = GetNormalizedRealmName and GetNormalizedRealmName() end
	return realm and realm ~= "" and (name .. "-" .. realm) or name
end

-- 게임에 보이는 이름 그대로 (포에버: "아무 개")
local SURNAME_SEPARATOR = Constants and Constants.CharacterNameSeparatorConsts
	and Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR
if type(SURNAME_SEPARATOR) ~= "string" then SURNAME_SEPARATOR = " " end

local function PlayerDisplayName()
	if NameUtil and NameUtil.GetUnmodifiedUnitFullName then
		local ok, name = pcall(NameUtil.GetUnmodifiedUnitFullName, "player")
		name = ok and Clean(name)
		if type(name) == "string" and name ~= "" then return name end
	end
	return UnitName("player")
end

local function RealmName()
	return GetRealmName and Clean(GetRealmName())
end

local saved   -- EzyWOWFDB.characterCopy: 키 -> { name, realm, class, classFile, level, time, data }

---------------------------------------------------------------------------
-- 편집 모드
---------------------------------------------------------------------------
local function Presets()
	if EditModePresetLayoutManager and EditModePresetLayoutManager.GetCopyOfPresetLayouts then
		local ok, presets = pcall(EditModePresetLayoutManager.GetCopyOfPresetLayouts, EditModePresetLayoutManager)
		if ok and type(presets) == "table" then return presets end
	end
	return {}
end

local function CurrentLayout()
	if not (C_EditMode and C_EditMode.GetLayouts) then return nil end
	local info = C_EditMode.GetLayouts()
	local presets = Presets()
	local active = info and info.activeLayout
	if not active then return nil end
	if active <= #presets then
		return { kind = "preset", index = active, name = presets[active].layoutName }
	end
	local layout = info.layouts[active - #presets]
	if not layout then return nil end
	return { kind = layout.layoutType == CHARACTER_LAYOUT and "character" or "account", name = layout.layoutName }
end

local function ApplyLayout(layout)
	if not (C_EditMode and C_EditMode.GetLayouts and C_EditMode.SetActiveLayout) then return nil end
	local info = C_EditMode.GetLayouts()
	local presets = Presets()
	local target
	if layout.kind == "preset" and type(layout.index) == "number" and layout.index <= #presets then
		target = layout.index
	elseif layout.kind == "account" then
		for i, l in ipairs(info.layouts) do
			if l.layoutName == layout.name and l.layoutType ~= CHARACTER_LAYOUT then
				target = #presets + i
				break
			end
		end
	end
	if not target then
		if layout.kind == "character" then
			return ("편집 모드 레이아웃 '%s'는 A 캐릭터 전용이라 옮기지 못했어요. A의 편집 모드에서 레이아웃을 공유(복사)해 이 캐릭터에서 가져오세요.")
				:format(tostring(layout.name))
		end
		return ("편집 모드 레이아웃 '%s'를 찾지 못했어요."):format(tostring(layout.name))
	end
	if target ~= info.activeLayout then C_EditMode.SetActiveLayout(target) end
	return ("편집 모드 레이아웃: %s"):format(tostring(layout.name))
end

---------------------------------------------------------------------------
-- 내보내기
---------------------------------------------------------------------------
-- 매크로 칸의 매크로 이름.
-- 매크로가 주문·아이템을 보여 주는 중이면(#showtooltip 등) GetActionInfo의 번호는 매크로 번호가 아니라
-- 그 주문·아이템 번호다. 그래서 칸에 붙은 매크로 이름(GetActionText)으로 찾는다.
local function MacroNameAt(slot, id, subType)
	local getText = (C_ActionBar and C_ActionBar.GetActionText) or GetActionText
	local name = getText and Clean(getText(slot))
	if type(name) == "string" and name ~= "" and (GetMacroIndexByName(name) or 0) > 0 then return name end
	if id and (subType == nil or subType == "") then
		name = GetMacroInfo(id)   -- 아무것도 보여 주지 않는 매크로는 번호가 매크로 번호
		if type(name) == "string" then return name end
	end
end

local function ExportActions()
	local actions = {}
	for slot = 1, MAX_SLOT do
		local kind, id, subType = GetActionInfo(slot)
		kind, id = Clean(kind), Clean(id)
		if kind == "spell" and id and (subType == nil or subType == "" or subType == "spell") then
			actions[slot] = { t = "spell", id = id, name = SpellName(id) }
		elseif kind == "item" and id then
			actions[slot] = { t = "item", id = id }
		elseif kind == "macro" then
			local name = MacroNameAt(slot, id, Clean(subType))
			actions[slot] = name and { t = "macro", name = name } or { t = "other" }
		elseif kind then
			actions[slot] = { t = "other" }
		end
	end
	return actions
end

local function ExportBindings()
	local bindings = {}
	for i = 1, GetNumBindings() do
		local command, _, key1, key2 = GetBinding(i)
		if command and (key1 or key2) then
			local keys = {}
			if key1 then keys[#keys + 1] = key1 end
			if key2 then keys[#keys + 1] = key2 end
			bindings[command] = keys
		end
	end
	return bindings
end

-- 캐릭터 전용 매크로만 (계정 공용 매크로는 모든 캐릭터가 이미 같이 쓴다)
local function ExportMacros()
	local macros = {}
	local _, numCharacter = GetNumMacros()
	local base = MAX_ACCOUNT_MACROS or 120
	for i = base + 1, base + (numCharacter or 0) do
		local name, icon, body = GetMacroInfo(i)
		if name then macros[#macros + 1] = { name = name, icon = icon, body = body or "" } end
	end
	return macros
end

local function Collect()
	return {
		v = 1,
		from = CharacterName(),
		fromName = PlayerDisplayName(),
		actions = ExportActions(),
		bindings = ExportBindings(),
		macros = ExportMacros(),
		bars = GetActionBarToggles and { GetActionBarToggles() } or nil,
		layout = CurrentLayout(),
	}
end

local function Export()
	return ns.EncodeData(PREFIX, Collect())
end

-- 지금 캐릭터의 설정을 캐릭터 목록에 기록한다.
local function Snapshot()
	local name = saved and CharacterName()
	if not name then return end
	local className, classFile = UnitClass("player")
	saved[name] = {
		name = PlayerDisplayName(),
		realm = RealmName(),
		class = className,
		classFile = classFile,
		level = UnitLevel("player"),
		time = time(),
		data = Collect(),
	}
end

-- 접속 직후에는 단축바가 아직 비어 있을 수 있어서 조금 기다렸다가 기록한다.
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function(_, isLogin, isReload)
	if isLogin or isReload then
		C_Timer.After(5, function() pcall(Snapshot) end)
	end
end)

-- 나갈 때(/reload 포함)는 저장 파일을 쓰기 직전이라 이때 기록한 것이 남는다.
ns:RegisterEvent("PLAYER_LOGOUT", function()
	pcall(Snapshot)
end)

---------------------------------------------------------------------------
-- 가져오기
---------------------------------------------------------------------------
local function CreateMissingMacros(macros)
	local created = 0
	for _, m in ipairs(macros) do
		if type(m) == "table" and type(m.name) == "string" and type(m.body) == "string" then
			if (GetMacroIndexByName(m.name) or 0) == 0 then
				local ok = pcall(CreateMacro, m.name, m.icon or MACRO_ICON, m.body, true)
				if ok then created = created + 1 end
			end
		end
	end
	return created
end

local function Pickup(action)
	if action.t == "spell" and type(action.id) == "number" then
		if ns.IsSpellKnown(action.id) then
			C_Spell.PickupSpell(action.id)
		elseif type(action.name) == "string" then
			pcall(C_Spell.PickupSpell, action.name)   -- 아직 그 등급을 모르면 배운 등급으로
		end
	elseif action.t == "item" and type(action.id) == "number" then
		C_Item.PickupItem(action.id)
	elseif action.t == "macro" and type(action.name) == "string" then
		PickupMacro(action.name)
	end
	return GetCursorInfo() ~= nil
end

-- HasAction은 호환용 함수라 게임 설정에 따라 없을 수 있다.
local function SlotHasAction(slot)
	if C_ActionBar and C_ActionBar.HasAction then return C_ActionBar.HasAction(slot) end
	return HasAction and HasAction(slot)
end

local function PlaceActions(actions, clearEmpty)
	local placed, missing = 0, 0
	for slot = 1, MAX_SLOT do
		local action = actions[slot]
		ClearCursor()
		if type(action) == "table" then
			if action.t ~= "other" then
				if Pickup(action) then
					PlaceAction(slot)
					placed = placed + 1
				else
					missing = missing + 1
				end
			end
		elseif clearEmpty and SlotHasAction(slot) then
			PickupAction(slot)
		end
		ClearCursor()
	end
	return placed, missing
end

local function ApplyBindings(saved)
	-- 옛 이름(MyToolkit) 시절 기록이면 명령 이름부터 지금 것으로 바꿔 둔다.
	local bindings = {}
	for command, keys in pairs(saved) do
		if type(command) == "string" then bindings[ns.UpgradeLegacyCommand(command)] = keys end
	end
	local count = 0
	for command, keys in pairs(bindings) do
		if type(keys) == "table" then
			for _, old in ipairs({ GetBindingKey(command) }) do SetBinding(old) end
			for _, key in ipairs(keys) do
				if type(key) == "string" and SetBinding(key, command) then count = count + 1 end
			end
		end
	end
	-- A에 없는 단축키는 지운다.
	for i = 1, GetNumBindings() do
		local command, _, key1, key2 = GetBinding(i)
		if command and not bindings[command] then
			if key1 then SetBinding(key1) end
			if key2 then SetBinding(key2) end
		end
	end
	SaveBindings(GetCurrentBindingSet())
	return count
end

local function ApplyData(data)
	if InCombatLockdown() then return false, "전투 중에는 가져올 수 없어요." end
	if type(data) ~= "table" or data.v ~= 1 then return false, "이 버전에서 읽을 수 없는 설정입니다." end

	local report = {}
	if Setting("macros") and type(data.macros) == "table" then
		report[#report + 1] = ("매크로 %d개 만듦"):format(CreateMissingMacros(data.macros))
	end
	if Setting("actions") and type(data.actions) == "table" then
		local placed, missing = PlaceActions(data.actions, Setting("clearEmpty"))
		local note = missing > 0 and (" (아직 없는 %d개는 비움)"):format(missing) or ""
		report[#report + 1] = ("단축바 %d칸 배치%s"):format(placed, note)
	end
	if Setting("bindings") and type(data.bindings) == "table" then
		report[#report + 1] = ("단축키 %d개"):format(ApplyBindings(data.bindings))
	end
	if Setting("bars") and type(data.bars) == "table" and SetActionBarToggles then
		SetActionBarToggles(unpack(data.bars))
		report[#report + 1] = "단축바 켜기/끄기"
	end
	if Setting("layout") and type(data.layout) == "table" then
		local message = ApplyLayout(data.layout)
		if message then report[#report + 1] = message end
	end

	pcall(Snapshot)   -- 목록의 이 캐릭터 기록도 바로 새것으로
	return true, ("'%s'의 설정을 가져왔습니다: %s. /reload 하면 모두 제자리를 잡습니다.")
		:format(tostring(data.fromName or data.from or "?"), table.concat(report, ", "))
end

local function Import(text)
	if InCombatLockdown() then return false, "전투 중에는 가져올 수 없어요." end
	local ok, data = ns.DecodeData(PREFIX, text, LEGACY_PREFIX)
	if not ok then return false, data end
	return ApplyData(data)
end

---------------------------------------------------------------------------
-- 캐릭터 목록
---------------------------------------------------------------------------
StaticPopupDialogs["EZYWOWF_CHARCOPY_IMPORT"] = {
	text = "%s",
	button1 = "가져오기",
	button2 = "취소",
	OnAccept = function(_, onAccept) onAccept() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

local function Age(seconds)
	if seconds < 60 then return "방금" end
	if seconds < 3600 then return ("%d분 전"):format(math.floor(seconds / 60)) end
	if seconds < 86400 then return ("%d시간 전"):format(math.floor(seconds / 3600)) end
	return ("%d일 전"):format(math.floor(seconds / 86400))
end

-- 이 캐릭터를 뺀 기록, 최근 것부터
local function OtherCharacters()
	local me, list = CharacterName(), {}
	for name, record in pairs(saved or {}) do
		if name ~= me and type(record) == "table" and type(record.data) == "table" then
			list[#list + 1] = { name = name, record = record }
		end
	end
	table.sort(list, function(a, b) return (a.record.time or 0) > (b.record.time or 0) end)
	return list
end

-- 직업 색 이름. 이름을 기록하기 전(0.3.5)의 기록은 키 "아무-개"를 "아무 개"로 바꿔 보여 준다.
-- 다른 서버 캐릭터는 뒤에 서버 이름을 붙인다.
local function DisplayName(key, record)
	local text = type(record.name) == "string" and record.name or key:gsub("%-", SURNAME_SEPARATOR, 1)
	local color = record.classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[record.classFile]
	if color then text = ("|c%s%s|r"):format(color.colorStr, text) end
	local myRealm = RealmName()
	if type(record.realm) == "string" and myRealm and record.realm ~= myRealm then
		text = text .. (" |cff999999(%s)|r"):format(record.realm)
	end
	return text
end

local function OptionText(name, record)
	return ("%s  |cffccccccLv %s %s|r"):format(DisplayName(name, record), tostring(record.level or "?"), record.class or "")
end

-- 선택 상자에서 고른 캐릭터. 고른 적이 없거나 기록이 없어졌으면 가장 최근 캐릭터.
local selected

local function Selected()
	if selected and selected ~= CharacterName() and saved and type(saved[selected]) == "table"
		and type(saved[selected].data) == "table" then
		return selected
	end
	local first = OtherCharacters()[1]
	return first and first.name
end

local function CharacterOptions()
	local options = {}
	for _, entry in ipairs(OtherCharacters()) do
		options[#options + 1] = { value = entry.name, text = OptionText(entry.name, entry.record) }
	end
	return options
end

local function Count(t)
	local n = 0
	for _ in pairs(type(t) == "table" and t or {}) do n = n + 1 end
	return n
end

-- 기록된 캐릭터 수, 지금 캐릭터 포함 (일반 > 성능 표시도 쓴다)
function M:CountRecords()
	return Count(saved)
end

-- 고른 캐릭터에 무엇이 기록되어 있는지 한 줄로
local function SelectedSummary()
	local name = Selected()
	local record = name and saved[name]
	if not record then
		return "|cff808080다른 캐릭터로 한 번 접속했다가 나오면 여기에 생겨요.|r"
	end
	local data = record.data
	local slots = 0
	for _, action in pairs(type(data.actions) == "table" and data.actions or {}) do
		if type(action) == "table" and action.t ~= "other" then slots = slots + 1 end
	end
	return ("|cffcccccc%s 기록 · 단축바 %d칸 · 단축키 %d개 · 매크로 %d개|r"):format(
		Age(time() - (record.time or 0)), slots, Count(data.bindings), Count(data.macros))
end

local function ImportFrom(name)
	if InCombatLockdown() then
		Print("전투 중에는 가져올 수 없어요.")
		return
	end
	local record = saved and saved[name]
	if not record then return end
	local message = ("%s\n\n이 캐릭터의 설정을 가져올까요?\n지금 캐릭터의 단축바·단축키를 덮어씁니다."):format(DisplayName(name, record))
	local _, myClass = UnitClass("player")
	if record.classFile and record.classFile ~= myClass then
		message = message .. "\n\n|cffff8800직업이 달라서 이 캐릭터가 모르는 기술 칸은 비워집니다.|r"
	end
	StaticPopup_Show("EZYWOWF_CHARCOPY_IMPORT", message, nil, function()
		local _, result = ApplyData(record.data)
		Print(result)
	end)
end

---------------------------------------------------------------------------
-- 설정 창
---------------------------------------------------------------------------
function M:OnInitialize()
	ns.db.characterCopy = ns.db.characterCopy or {}
	saved = ns.db.characterCopy
end

function M:BuildOptions(b)
	b:Text("다른 캐릭터(A)의 행동 단축바 배치, 단축키, 캐릭터 전용 매크로, 단축바 켜기/끄기, 편집 모드 레이아웃을 "
		.. "이 캐릭터로 복사합니다. 가져온 뒤 /reload 하세요.")

	b:Header("캐릭터 골라서 가져오기")
	b:Text("캐릭터마다 접속할 때와 나갈 때 설정을 자동으로 기록해 둡니다. "
		.. "목록에는 이 기능이 생긴 뒤로 한 번이라도 접속한 캐릭터가 나와요.", { color = { 0.7, 0.7, 0.7 } })
	b:Dropdown{
		label = "가져올 캐릭터",
		width = 260,
		options = CharacterOptions,
		emptyText = "기록된 다른 캐릭터 없음",
		get = Selected,
		set = function(name) selected = name end,
	}
	b:Text(SelectedSummary, { indent = 120 })
	b:Buttons{
		{
			text = "가져오기", width = 110,
			disabled = function() return Selected() == nil end,
			onClick = function()
				local name = Selected()
				if name then ImportFrom(name) end
			end,
		},
	}

	b:Header("글자로 옮기기")
	b:Text("다른 계정으로 옮기거나 따로 보관할 때 씁니다.\n"
		.. "1) A로 접속해서 [이 캐릭터 내보내기]를 누르고 글자를 복사해 둡니다.\n"
		.. "2) 이 캐릭터로 접속해서 [가져오기]에 붙여 넣습니다.")
	b:Buttons{
		{
			text = "이 캐릭터 내보내기", width = 150,
			onClick = function()
				ns.UI.ShowTextDialog{
					title = "캐릭터 설정 내보내기",
					help = "Ctrl+C로 복사해서 메모장 등에 보관한 뒤, 다른 캐릭터에서 [가져오기]에 붙여 넣으세요.",
					text = Export(),
					readOnly = true,
				}
			end,
		},
		{
			text = "가져오기", width = 110,
			onClick = function()
				ns.UI.ShowTextDialog{
					title = "캐릭터 설정 가져오기",
					help = "다른 캐릭터에서 내보낸 글자를 Ctrl+V로 붙여 넣고 [가져오기]를 누르세요. 지금 캐릭터의 설정을 덮어씁니다.",
					text = "",
					button = "가져오기",
					onAccept = Import,
				}
			end,
		},
	}

	b:Header("가져올 것")
	b:Check{ key = "actions", label = "행동 단축바 배치" }
	b:Check{ key = "clearEmpty", label = "A에서 빈 칸은 이 캐릭터도 비우기", depends = "actions", indent = 20 }
	b:Check{
		key = "bindings", label = "단축키 전체",
		tooltip = "이 캐릭터가 쓰는 단축키 세트(계정 공용 또는 캐릭터 전용)에 저장됩니다. "
			.. "계정 공용 세트를 쓰면 다른 캐릭터에도 같이 적용돼요.",
	}
	b:Check{ key = "macros", label = "캐릭터 전용 매크로 (없는 것만 새로 만듦)" }
	b:Check{ key = "bars", label = "단축바 켜기/끄기 (2~8번 단축바)" }
	b:Check{ key = "layout", label = "편집 모드 레이아웃" }
	b:Text("- 아직 배우지 않은 기술은 비워 둡니다. 배운 뒤 다시 가져오면 그 자리에 놓여요. "
		.. "낮은 등급만 배웠으면 배운 등급을 놓습니다.\n"
		.. "- 계정 공용 매크로와 EzyWOWF 설정은 모든 캐릭터가 이미 같이 씁니다.\n"
		.. "- 전투 중에는 가져올 수 없어요.",
		{ color = { 0.7, 0.7, 0.7 } })
end
