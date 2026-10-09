local _, ns = ...
local Clean = ns.Clean

local FORMS = {
	[5487] = { kind = "bear", name = "곰 변신" },
	[9634] = { kind = "bear", name = "광포한 곰 변신" },
	[768] = { kind = "cat", name = "표범 변신" },
	[783] = { kind = "travel", name = "여행 변신" },
	[1066] = { kind = "aquatic", name = "바다표범 변신" },
	[24858] = { kind = "moonkin", name = "달빛야수 변신" },
}

local function FormCount()
	local count = GetNumShapeshiftForms and Clean(GetNumShapeshiftForms())
	return type(count) == "number" and count >= 0 and count <= 100 and count == math.floor(count) and count or 0
end

local function Read(index)
	if not GetShapeshiftFormInfo then return end
	local icon, _, _, spellID = GetShapeshiftFormInfo(index)
	spellID, icon = Clean(spellID), Clean(icon)
	local form = FORMS[spellID]
	local name = spellID and C_Spell and C_Spell.GetSpellName and Clean(C_Spell.GetSpellName(spellID))
	return {
		index = index, spellID = spellID, icon = icon,
		kind = form and form.kind or "other",
		name = name or (form and form.name) or "기타 변신",
	}
end

ns.DruidForms = {}

function ns.DruidForms.GetIndex(spellID)
	if type(spellID) ~= "number" then return end
	local wanted = FORMS[spellID]
	for index = 1, FormCount() do
		local form = Read(index)
		if form and (form.spellID == spellID or (wanted and wanted.kind == "bear" and form.kind == "bear")) then
			return index
		end
	end
end

function ns.DruidForms.GetCurrent()
	local index = GetShapeshiftForm and Clean(GetShapeshiftForm())
	if index == 0 then return { index = 0, kind = "humanoid", name = "인간형" } end
	if type(index) == "number" and index >= 1 and index <= FormCount() and index == math.floor(index) then
		return Read(index) or { index = index, kind = "other", name = "기타 변신" }
	end
	return { kind = "other", name = "변신 확인 불가" }
end
