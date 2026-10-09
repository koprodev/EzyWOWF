-- 빠른 설정: 게임 설정 화면에 없는 유용한 콘솔 설정(CVar)을 클릭 한 번으로 켜고 끈다.
-- 항목마다 [켜기]/[끄기] 버튼과 현재 상태를 보여 주고, [저장] 없이 바로 적용된다. (게임 설정이라 EzyWOWF 설정 저장과 상관없다)
-- 게임이 막아 둔 설정은 바꿔도 값이 그대로라서, 바꾼 뒤 다시 읽어 보고 안 바뀌었으면 알린다.
-- 이 게임 버전에 없는 설정은 회색으로 막아 둔다.

local _, ns = ...
local Print = ns.Print

local M = ns:NewModule("Tweaks", {
	title = "빠른 설정",
	category = "interface",
	icon = "Interface\\Icons\\INV_Misc_Gear_08",
	order = 10,
	defaults = {},
})

-- on: 켤 때 값. off: 끌 때 값(없으면 게임 기본값).
local TOGGLES = {
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
