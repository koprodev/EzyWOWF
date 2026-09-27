-- 내구도 경고: 가장 낮은 장비 내구도가 기준 아래로 떨어지면 화면 가운데에 크게 알린다.
-- 전투 중이면 전투가 끝난 뒤에 알린다.

local _, ns = ...
local Print = ns.Print

local M = ns:NewModule("Durability", {
	title = "내구도 경고",
	category = "info",
	icon = "Interface\\Icons\\Trade_BlackSmithing",
	order = 30,
	defaults = {
		enabled = true,
		threshold = 25,
		sound = true,
	},
})

local WARN_COLOR = { r = 1, g = 0.45, b = 0.1 }

local db
local wasLow = false
local warnAfterCombat = false

local function ShowWarning(pct)
	local msg = ("장비 내구도가 %d%%입니다. 수리하세요!"):format(math.floor(pct))
	if RaidNotice_AddMessage and RaidWarningFrame then
		RaidNotice_AddMessage(RaidWarningFrame, msg, WARN_COLOR)
	else
		UIErrorsFrame:AddMessage(msg, WARN_COLOR.r, WARN_COLOR.g, WARN_COLOR.b)
	end
	Print("|cffff7733" .. msg .. "|r")
	if db.sound and SOUNDKIT then PlaySound(SOUNDKIT.RAID_WARNING) end
end

local function Warn(pct)
	if UnitAffectingCombat("player") then
		warnAfterCombat = true
	else
		ShowWarning(pct)
	end
end

-- 기준을 넘어 떨어지는 순간에만 한 번 알린다.
local function Check(force)
	if not (db and db.enabled) then return end
	local pct = ns.GetLowestDurability()
	local isLow = pct ~= nil and pct < db.threshold
	if isLow and (force or not wasLow) then Warn(pct) end
	wasLow = isLow
end

ns:RegisterEvent("UPDATE_INVENTORY_DURABILITY", function() Check(false) end)
ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function() Check(false) end)

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
	-- 접속했을 때나 던전을 드나들 때 이미 낮으면 한 번 더 알려 준다.
	C_Timer.After(5, function() Check(true) end)
end)

ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
	if not warnAfterCombat then return end
	warnAfterCombat = false
	local pct = ns.GetLowestDurability()
	if db.enabled and pct and pct < db.threshold then ShowWarning(pct) end
end)

function M:OnInitialize()
	db = self.db
end

function M:ApplySettings()
	wasLow = false
	Check(false)
end

function M:BuildOptions(b)
	b:Text("착용한 장비 중 가장 낮은 내구도가 기준보다 떨어지면 화면 가운데에 경고를 띄웁니다. 전투 중이면 전투가 끝난 뒤에 알립니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Slider{ key = "threshold", label = "경고 기준 (%)", min = 5, max = 60, step = 5, format = "%d", depends = "enabled" }
	b:Check{ key = "sound", label = "경고음 재생", depends = "enabled" }
	b:Text(function()
		local pct = ns.GetLowestDurability()
		return "현재 가장 낮은 내구도:  " .. (pct and ("%d%%"):format(math.floor(pct)) or "|cff808080내구도 있는 장비 없음|r")
	end, { font = "GameFontHighlight" })
	b:Buttons{
		{ text = "경고 미리 보기", onClick = function() ShowWarning(ns.GetLowestDurability() or 15) end },
	}
end
