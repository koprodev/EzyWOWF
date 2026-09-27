-- 빠른 설정: 게임 설정 화면에 없는 유용한 콘솔 설정(CVar)을 클릭 한 번으로 켜고 끈다.
-- 항목마다 [켜기]/[끄기] 버튼과 현재 상태를 보여 주고, [저장] 없이 바로 적용된다. (게임 설정이라 EzyWOWF 설정 저장과 상관없다)
-- 게임이 막아 둔 설정은 바꿔도 값이 그대로라서, 바꾼 뒤 다시 읽어 보고 안 바뀌었으면 알린다.
-- 이 게임 버전에 없는 설정은 회색으로 막아 둔다.
--
-- 낚시: 상호작용 키는 기본 10m 안만 잡아서 멀리 떨어진 찌를 못 잡는다.
--   거리(SoftTargetInteractRange)를 30m, 방향(SoftTargetInteractArc)을 전방향(2)으로 넓힌다.
--   "낚시할 때만"을 켜 두면 낚시 채널링이 시작될 때 넓혔다가 끝나면 원래 값으로 되돌린다.

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local M = ns:NewModule("Tweaks", {
	title = "빠른 설정",
	category = "interface",
	icon = "Interface\\Icons\\INV_Misc_Gear_08",
	order = 10,
	defaults = {
		fishingAuto = true,
	},
})

local FISHING_SPELLS = { 7620, 131474 }
local FISHING_RANGE = { SoftTargetInteractRange = 30, SoftTargetInteractArc = 2 }

-- on: 켤 때 값. off: 끌 때 값(없으면 게임 기본값).
local TOGGLES = {
	{
		group = "낚시", label = "상호작용 키로 먼 낚시찌 잡기 - 항상 (30m, 전방향)", on = FISHING_RANGE,
		tip = "상호작용 키가 30m 안, 모든 방향의 대상을 잡습니다. 평소에도 멀리 있는 NPC나 물건을 잡을 수 있으니 "
			.. "보통은 아래의 '낚시할 때만'을 추천해요.",
	},
	{
		group = "낚시", label = "상호작용 대상 위에 아이콘 표시 (낚시찌 포함)",
		on = { SoftTargetIconGameObject = 1 }, off = { SoftTargetIconGameObject = 0 },
		tip = "상호작용 키로 잡을 수 있는 물건(낚시찌, 채집물 등) 위에 손 모양 아이콘을 띄웁니다.",
	},
	{
		group = "카메라·화면", label = "카메라를 더 멀리 (최대 거리 2.6배)", on = { cameraDistanceMaxZoomFactor = 2.6 },
		tip = "마우스 휠로 카메라를 기본보다 더 멀리 뺄 수 있습니다.",
	},
	{
		group = "카메라·화면", label = "적 이름표를 더 멀리서 표시 (41m)", on = { nameplateMaxDistance = 41 },
		tip = "사냥꾼 사거리(35m) 밖의 적도 이름표가 보이게 합니다.",
	},
	{
		group = "카메라·화면", label = "화면 번짐(글로우) 효과 끄기",
		on = { ffxGlow = 0 }, off = { ffxGlow = 1 },
		tip = "화면 전체가 뿌옇게 빛나는 효과를 끕니다.",
	},
	{
		group = "카메라·화면", label = "죽었을 때 흑백 화면 끄기",
		on = { ffxDeath = 0 }, off = { ffxDeath = 1 },
	},
	{
		group = "스크린샷", label = "스크린샷을 고화질 PNG로 저장",
		on = { screenshotFormat = "png", screenshotQuality = 10 },
		tip = "Print Screen으로 찍는 스크린샷을 선명한 PNG로 저장합니다. (파일이 조금 커져요)",
	},
	{
		group = "문제 해결", label = "Lua 오류 창 표시 (애드온 문제 확인용)",
		on = { scriptErrors = 1 }, off = { scriptErrors = 0 },
		tip = "애드온에서 오류가 나면 창으로 보여 줍니다. 문제를 알려 주실 때 켜 두면 원인을 찾기 쉬워요.",
	},
}

local SLIDERS = {
	{
		group = "카메라·화면", label = "전투 글자(피해 숫자) 크기", cvar = "WorldTextScale",
		min = 0.5, max = 2.5, step = 0.1, format = "%.1f",
		tip = "몹 위에 뜨는 피해·치유 숫자의 크기입니다. 기본 1.0",
	},
}

---------------------------------------------------------------------------
-- CVar
---------------------------------------------------------------------------
local function Get(name)
	return C_CVar and C_CVar.GetCVar and C_CVar.GetCVar(name)
end

local function Exists(name)
	return Get(name) ~= nil
end

local function Same(a, b)
	local na, nb = tonumber(a), tonumber(b)
	if na and nb then return math.abs(na - nb) < 0.001 end
	return tostring(a) == tostring(b)
end

-- 바꾼 뒤 다시 읽어서 정말 바뀌었는지 돌려준다.
local function Set(name, value)
	pcall(C_CVar.SetCVar, name, tostring(value))
	return Same(Get(name), value)
end

local function DefaultOf(name)
	return C_CVar.GetCVarDefault and C_CVar.GetCVarDefault(name)
end

local function AllExist(values)
	for name in pairs(values) do
		if not Exists(name) then return false end
	end
	return true
end

local function IsOn(item)
	for name, value in pairs(item.on) do
		if not Same(Get(name), value) then return false end
	end
	return true
end

local function Apply(item, on)
	local failed = {}
	for name, value in pairs(item.on) do
		local target = value
		if not on then target = (item.off and item.off[name]) or DefaultOf(name) end
		if target ~= nil and not Set(name, target) then failed[#failed + 1] = name end
	end
	if #failed > 0 then
		Print(("이 설정은 포에버에서 바꿀 수 없게 막혀 있어요: %s"):format(table.concat(failed, ", ")))
	end
	ns:Fire("REFRESH_UI")
end

---------------------------------------------------------------------------
-- 낚시할 때만 상호작용 범위 넓히기
---------------------------------------------------------------------------
local fishingNames = {}
for _, id in ipairs(FISHING_SPELLS) do
	local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
	if name then fishingNames[name] = true end
end

local function IsFishing(spellID)
	spellID = Clean(spellID)
	if not spellID then return false end
	for _, id in ipairs(FISHING_SPELLS) do
		if id == spellID then return true end
	end
	local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
	return name ~= nil and fishingNames[name] == true
end

local savedRange   -- 낚시하는 동안 넓혀 두었으면 원래 값

ns:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", function(_, unit, _, spellID)
	if unit ~= "player" or savedRange or not (M.db and M.db.fishingAuto) then return end
	if not IsFishing(spellID) or not AllExist(FISHING_RANGE) then return end
	local original, changed = {}, false
	for name, value in pairs(FISHING_RANGE) do
		original[name] = Get(name)
		if not Same(original[name], value) then
			Set(name, value)
			changed = true
		end
	end
	if changed then savedRange = original end
end, "player")

ns:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", function(_, unit)
	if unit ~= "player" or not savedRange then return end
	for name, value in pairs(savedRange) do Set(name, value) end
	savedRange = nil
end, "player")

---------------------------------------------------------------------------
-- 설정 창
---------------------------------------------------------------------------
function M:BuildOptions(b)
	b:Text("게임 설정 화면에 없는 유용한 설정을 버튼 한 번으로 바꿉니다. [저장]을 누르지 않아도 바로 적용되고, "
		.. "[끄기]를 누르면 게임 기본값으로 돌아갑니다. 게임에 저장되므로 모든 캐릭터에 적용돼요.")

	local lastGroup
	local function GroupHeader(group)
		if group ~= lastGroup then
			b:Header(group)
			lastGroup = group
		end
	end

	for _, item in ipairs(TOGGLES) do
		GroupHeader(item.group)
		local exists = AllExist(item.on)
		b:OnOff{
			label = item.label,
			tooltip = exists and item.tip or "이 게임 버전에는 없는 설정이에요.",
			isOn = function() return IsOn(item) end,
			onOn = function() Apply(item, true) end,
			onOff = function() Apply(item, false) end,
			disabled = function() return not exists end,
		}
		if item.on == FISHING_RANGE then
			b:OnOff{
				label = "낚시할 때만 자동으로 넓히기 (추천)",
				tooltip = "낚시를 시작하면 상호작용 범위를 30m·전방향으로 넓혔다가 낚시가 끝나면 원래대로 되돌립니다.",
				isOn = function() return M.db.fishingAuto end,
				onOn = function() M.db.fishingAuto = true end,
				onOff = function() M.db.fishingAuto = false end,
			}
		end
	end

	for _, item in ipairs(SLIDERS) do
		GroupHeader(item.group)
		local exists = Exists(item.cvar)
		b:Slider{
			label = item.label, min = item.min, max = item.max, step = item.step, format = item.format,
			tooltip = exists and item.tip or "이 게임 버전에는 없는 설정이에요.",
			get = function() return tonumber(Get(item.cvar)) or 1 end,
			set = function(value)
				if exists and not Same(Get(item.cvar), value) and not Set(item.cvar, value) then
					Print(("이 설정은 포에버에서 바꿀 수 없게 막혀 있어요: %s"):format(item.cvar))
				end
			end,
			disabled = function() return not exists end,
		}
		b:Buttons{
			{
				text = "기본값으로", width = 100,
				disabled = function() return not exists end,
				onClick = function() Set(item.cvar, DefaultOf(item.cvar)) end,
			},
		}
	end
end
