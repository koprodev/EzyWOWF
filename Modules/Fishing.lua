local _, ns = ...
local Clean, Print = ns.Clean, ns.Print
local CAST_BINDING = "CLICK EzyWOWFFishingCast:LeftButton"
local LURE_BINDING = "CLICK EzyWOWFFishingLure:LeftButton"
local FISHING_IDS = { 7620, 131474 }
local POLE_SUBCLASS = Enum and Enum.ItemWeaponSubclass and Enum.ItemWeaponSubclass.Fishingpole or 20
-- Classic lure IDs; names and remaining time come from the client.
local LURES = { [6529] = true, [6530] = true, [6532] = true, [6533] = true, [6811] = true, [7307] = true }
local CHANNEL_CVARS = { SoftTargetInteractRange = 30, SoftTargetInteractArc = 2 }
local CVAR_NAMES = {
	SoftTargetInteractRange = true, SoftTargetInteractArc = true, SoftTargetIconGameObject = true,
	Sound_EnableSFX = true, Sound_SFXVolume = true, Sound_MusicVolume = true, Sound_AmbienceVolume = true,
}

_G["BINDING_NAME_" .. CAST_BINDING] = "낚시 던지기"
_G["BINDING_NAME_" .. LURE_BINDING] = "낚시 미끼 바르기"

local M = ns:NewModule("Fishing", {
	title = "낚시", category = "professions", icon = "Interface\\Icons\\Trade_Fishing", order = 45,
	bindings = { CAST_BINDING, LURE_BINDING, "INTERACTTARGET" },
	defaults = {
		enabled = true, showPanel = true, size = 32, scale = 1,
		point = "CENTER", relPoint = "CENTER", x = 0, y = -200,
		pole = 0, lure1 = 0, lure2 = 0, lure3 = 0,
		rangeAssist = true, bobberIcon = false, soundFocus = false,
		effectVolume = 1, musicVolume = 0, ambienceVolume = 0.2,
		alerts = true, lowLureCount = 3, lowBagSlots = 3, lureWarnSeconds = 60,
		announceWarnings = true, warningSound = false,
		sessionStats = true, showSessionOnPanel = true,
	},
})

local db, record, channeling, session = nil, nil, false, false
local items, lure, freeSlots = {}, nil, nil
local enchanted, enchantEnd, enchantKnown = false, nil, false
local skill, skillMax, bonus, knownSpell
local queued, ticker, pending = false, nil, false
local manualPanel = false
local keyEvents = { cast = 0, lure = 0, equip = 0, restore = 0 }
local restoreRequested = false
local interactionStopped = false
local bagsKnown = false

local function Number(value)
	value = Clean(value)
	return type(value) == "number" and value or nil
end

local function PlayerKey()
	local guid = Clean(UnitGUID("player"))
	if type(guid) == "string" then return guid end
	return (GetRealmName() or "") .. ":" .. (UnitName("player") or "")
end

local function ItemName(id)
	local name = C_Item and C_Item.GetItemNameByID and Clean(C_Item.GetItemNameByID(id))
	return name or ("아이템 #%d"):format(id)
end

local function IsPole(id)
	if not id or not (C_Item and C_Item.GetItemInfoInstant) then return false end
	local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(id)
	return Clean(classID) == 2 and Clean(subclassID) == POLE_SUBCLASS
end

local function EquippedPole()
	return IsPole(Number(GetInventoryItemID("player", 16)))
end

local function Alive()
	return not (UnitIsDeadOrGhost and Clean(UnitIsDeadOrGhost("player")))
end

function M:IsActive() return db ~= nil and db.enabled end
function M:SetPanel(frame) self.panel = frame end

function M:ShouldShowPanel()
	return self:IsActive() and (manualPanel or EquippedPole() or channeling or (record and record.weapons ~= nil))
end

function M:ShowPanel()
	manualPanel = true
	self:Refresh(false)
end

local function SpellName()
	local id = knownSpell or FISHING_IDS[1]
	local name = C_Spell and C_Spell.GetSpellName and Clean(C_Spell.GetSpellName(id))
	return name or (GetLocale() == "koKR" and "낚시" or "Fishing")
end

local function IsFishing(id)
	id = Number(id)
	if not id then return false end
	for _, fishingID in ipairs(FISHING_IDS) do if id == fishingID then return true end end
	local name = C_Spell and C_Spell.GetSpellName and Clean(C_Spell.GetSpellName(id))
	return name ~= nil and name == SpellName()
end

local function ReadSkill()
	skill, skillMax, bonus, knownSpell = nil, nil, nil, nil
	for _, id in ipairs(FISHING_IDS) do
		if ns.IsSpellKnown(id) then knownSpell = id break end
	end
	if C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID then
		local ok, info = pcall(C_SkillInfo.GetSkillLineInfoByID, 356)
		if ok and type(info) == "table" and not Clean(info.isHeader) and Clean(info.name) == SpellName() then
			skill, skillMax = Number(info.rank), Number(info.maxRank)
			bonus = (Number(info.modifier) or 0) + (Number(info.tempPoints) or 0)
		end
	end
	if not skill and C_SkillInfo and C_SkillInfo.GetNumSkillLines and C_SkillInfo.GetSkillLineInfo then
		for index = 1, Number(C_SkillInfo.GetNumSkillLines()) or 0 do
			local info = C_SkillInfo.GetSkillLineInfo(index)
			if type(info) == "table" and not Clean(info.isHeader) and Clean(info.name) == SpellName() then
				skill, skillMax = Number(info.rank), Number(info.maxRank)
				bonus = (Number(info.modifier) or 0) + (Number(info.tempPoints) or 0)
				break
			end
		end
	end
	if not skill and GetNumSkillLines and GetSkillLineInfo then
		for index = 1, Number(GetNumSkillLines()) or 0 do
			local name, header, _, rank, temp, modifier, maxRank = GetSkillLineInfo(index)
			if not Clean(header) and Clean(name) == SpellName() then
				skill, skillMax = Number(rank), Number(maxRank)
				bonus = (Number(temp) or 0) + (Number(modifier) or 0)
				break
			end
		end
	end
end

local function ReadBags()
	items, lure, freeSlots = {}, nil, nil
	bagsKnown = false
	if not (C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerNumSlots) then return end
	bagsKnown = true
	local freeKnown = false
	for bag = 0, NUM_BAG_SLOTS or 4 do
		if C_Container.GetContainerNumFreeSlots then
			local free, family = C_Container.GetContainerNumFreeSlots(bag)
			free, family = Number(free), Number(family)
			if free and family == 0 then freeSlots = (freeSlots or 0) + free; freeKnown = true end
		end
		local slotCount = Number(C_Container.GetContainerNumSlots(bag))
		if not slotCount then bagsKnown = false end
		for slot = 1, slotCount or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local id = info and Number(info.itemID)
			if id then
				local entry = items[id] or { id = id, count = 0 }
				items[id] = entry
				entry.count = entry.count + (Number(info.stackCount) or 1)
				if not Clean(info.isLocked) and not entry.bag then entry.bag, entry.slot = bag, slot end
			end
		end
	end
	if not freeKnown then freeSlots = nil end
	for rank = 1, 3 do
		local id = Number(db["lure" .. rank])
		local entry = id and LURES[id] and items[id]
		if entry and entry.bag then lure = entry break end
	end
end

local function ReadEnchant()
	enchanted, enchantEnd, enchantKnown = false, nil, false
	if not EquippedPole() then return end
	if C_Item and C_Item.GetWeaponEnchantInfo then
		local ok, list = pcall(C_Item.GetWeaponEnchantInfo, 0)
		if ok and type(list) == "table" then
			enchantKnown = true
			for _, entry in pairs(list) do
				local has = type(entry) == "table" and Clean(entry.hasEnchant)
				if type(has) ~= "boolean" then enchantKnown = false end
				if has and Number(entry.enchantType) ~= 1 then
					enchanted = true
					local ms = Number(entry.timeLeft)
					if ms and ms > 0 then enchantEnd = GetTime() + ms / 1000 end
					break
				end
			end
		end
	elseif GetWeaponEnchantInfo then
		local ok, has, ms = pcall(GetWeaponEnchantInfo)
		if not ok then return end
		has = Clean(has)
		enchantKnown = type(has) == "boolean"
		enchanted = has and true or false
		ms = Number(ms)
		if enchanted and ms and ms > 0 then enchantEnd = GetTime() + ms / 1000 end
	end
end

local function EnchantLeft()
	return enchantEnd and math.max(0, enchantEnd - GetTime()) or nil
end

local function CVarGet(name)
	return C_CVar and C_CVar.GetCVar and Clean(C_CVar.GetCVar(name))
end

local function SameCVar(a, b)
	local x, y = tonumber(a), tonumber(b)
	if x and y then return math.abs(x - y) < 0.00001 end
	return tostring(a) == tostring(b)
end

local function CVarSet(name, value)
	if not (C_CVar and C_CVar.SetCVar) then return false end
	local ok = pcall(C_CVar.SetCVar, name, tostring(value))
	return ok and SameCVar(CVarGet(name), value)
end

local function Acquire(scope, values)
	if not record then return end
	record.cvars = record.cvars or {}
	record.cvars[scope] = record.cvars[scope] or {}
	for name, value in pairs(values) do
		local current = CVarGet(name)
		if current ~= nil and not SameCVar(current, value) and not record.cvars[scope][name] then
			local saved = { before = tostring(current), target = tostring(value) }
			record.cvars[scope][name] = saved
			if not CVarSet(name, value) then
				record.cvars[scope][name] = nil
				Print(("낚시 설정을 적용할 수 없어요: %s"):format(name))
			end
		end
	end
end

local function Release(scope)
	local saved = record and record.cvars and record.cvars[scope]
	if not saved then return end
	for name, entry in pairs(saved) do
		if CVAR_NAMES[name] and type(entry) == "table" then
			-- A later user change owns the setting and must not be overwritten.
			local current = CVarGet(name)
			if current ~= nil and (not SameCVar(current, entry.target) or CVarSet(name, entry.before)) then
				saved[name] = nil
			elseif not entry.failed then
				entry.failed = true
				Print(("낚시 설정을 복원하지 못했어요. [낚시 마치기]로 다시 시도해 주세요: %s"):format(name))
			end
		else saved[name] = nil end
	end
	if not next(saved) then record.cvars[scope] = nil end
end

local function StopTemporarySettings()
	Release("channel")
	Release("sound")
	session = false
end

function M:EndSession()
	manualPanel = false
	interactionStopped = true
	ns:Fire("FISHING_SESSION_FINISHED")
	StopTemporarySettings()
	self:Refresh(false)
end

local function StartChannelSettings()
	if db.rangeAssist then Acquire("channel", CHANNEL_CVARS) end
	if db.bobberIcon then Acquire("channel", { SoftTargetIconGameObject = 1 }) end
	if db.soundFocus and not session then
		Acquire("sound", {
			Sound_EnableSFX = 1, Sound_SFXVolume = db.effectVolume,
			Sound_MusicVolume = db.musicVolume, Sound_AmbienceVolume = db.ambienceVolume,
		})
	end
	session = true
end

local function SlotItem(slot)
	local id = Number(GetInventoryItemID("player", slot)) or 0
	local link = GetInventoryItemLink and Clean(GetInventoryItemLink("player", slot))
	local itemString = type(link) == "string" and link:match("|H(item:[^|\r\n]+)|h")
	return { id = id, item = itemString or ("item:" .. id) }
end

local function CopyWeapons(snapshot)
	if type(snapshot) ~= "table" then return nil end
	local copy = {}
	for _, slot in ipairs({ "16", "17" }) do
		local entry = snapshot[slot]
		if type(entry) ~= "table" or type(entry.id) ~= "number" or type(entry.item) ~= "string" then return nil end
		copy[slot] = { id = entry.id, item = entry.item }
	end
	return copy
end

local function CurrentWeapons()
	local main = SlotItem(16)
	if main.id > 0 then
		if not (C_Item and C_Item.GetItemInfoInstant) then return nil end
		local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(main.id)
		classID, subclassID = Number(classID), Number(subclassID)
		if not classID or (classID == 2 and (not subclassID or subclassID == POLE_SUBCLASS)) then return nil end
	end
	return { ["16"] = main, ["17"] = SlotItem(17) }
end

local function WeaponsRestored()
	local saved = record and record.weapons
	if not saved then return false end
	for _, slot in ipairs({ 16, 17 }) do
		local current = SlotItem(slot)
		if current.id ~= saved[tostring(slot)].id then return false end
		local original = saved[tostring(slot)].item
		if current.id > 0 and original:find(":", 6, true) and current.item ~= original then return false end
	end
	return true
end

local function ObserveWeapons()
	if not record or InCombatLockdown() then return end
	if EquippedPole() then
		if not record.weapons then record.weapons = CopyWeapons(record.lastWeapons) end
		if record.weapons then record.fishingSeen = true end
	elseif record.weapons then
		-- Matching the old slots before the equip request finishes is not a restoration.
		if (record.fishingSeen or restoreRequested) and WeaponsRestored() then
			record.weapons, record.fishingSeen, restoreRequested = nil, nil, false
			record.lastWeapons = CurrentWeapons()
		end
	else
		local snapshot = CurrentWeapons()
		if snapshot then record.lastWeapons = snapshot end
	end
end

function M:CanInteract()
	return self:IsActive() and channeling and not interactionStopped and Alive() and not InCombatLockdown()
end

function M:GetRestoreWeaponText()
	local saved = record and record.weapons
	if not saved then return "기억한 원래 무기 없음" end
	local main, off = saved["16"], saved["17"]
	local text = main.id > 0 and ItemName(main.id) or "빈 손"
	if off.id > 0 then text = text .. " + " .. ItemName(off.id) end
	return text
end

function M:GetActionMacro(action)
	if not db or InCombatLockdown() or not Alive() then return nil end
	if action == "restore" then
		local saved = record and record.weapons
		if not saved then return nil end
		local lines = { "/stopmacro [combat]", "/run EzyWOWFFishingUnequipEmptySlots()" }
		for _, slot in ipairs({ 16, 17 }) do
			local entry = saved[tostring(slot)]
			if entry.id > 0 then lines[#lines + 1] = ("/equipslot %d %s"):format(slot, entry.item) end
		end
		return table.concat(lines, "\n")
	end
	if not self:IsActive() then return nil end
	if action == "cast" then
		-- Profession ranks can replace the fixed spell IDs while the skill remains learned.
		if (not knownSpell and not (skill and skill > 0)) or channeling then return nil end
		return "/cast [nocombat] " .. SpellName()
	elseif action == "lure" then
		if not EquippedPole() or not lure or not enchantKnown or enchanted or channeling then return nil end
		return ("/stopmacro [combat]\n/use %d %d\n/use 16"):format(lure.bag, lure.slot)
	elseif action == "equip" then
		local id = Number(db.pole)
		if id and id > 0 and IsPole(id) and items[id] and items[id].bag and Number(GetInventoryItemID("player", 16)) ~= id then
			return "/stopmacro [combat]\n/equipslot 16 item:" .. id
		end
	end
end

function M:GetActionBlockReason(action)
	if action == "interact" then
		if self:CanInteract() then return nil end
		return "찌를 던진 뒤 입질이 오면 [건지기]를 클릭하세요."
	end
	if self:GetActionMacro(action) then return nil end
	if not db then return "낚시 정보를 불러오는 중이에요." end
	if InCombatLockdown() then return "전투가 끝난 뒤 사용해 주세요." end
	if not Alive() then return "살아 있을 때 사용할 수 있어요." end
	if action == "restore" then return "기억한 원래 무기가 없어요. 원래 무기를 한 번 장착한 뒤 낚싯대로 바꿔 주세요." end
	if not self:IsActive() then return "낚시 도우미를 켜고 [저장]을 눌러 주세요." end
	if action == "cast" then
		if channeling then return "이미 낚시 중이에요. 입질 후 상호작용 키로 건져 올리세요." end
		return "낚시 시전 정보를 확인할 수 없어요. 낚시를 배웠는지 확인해 주세요."
	elseif action == "lure" then
		if not EquippedPole() then return "먼저 낚싯대를 장착해 주세요." end
		if channeling then return "낚시를 마친 뒤 미끼를 발라 주세요." end
		if not enchantKnown then return "낚싯대의 미끼 정보를 확인할 수 없어 덮어쓰지 않습니다." end
		if enchanted then return "낚싯대에 미끼가 남아 있어요. 만료 후 다시 발라 주세요." end
		return "가방에 있는 미끼를 등록하고 [저장]을 눌러 주세요. 잠긴 미끼는 사용할 수 없어요."
	elseif action == "equip" then
		local id = Number(db.pole)
		if not id or id <= 0 then return "사용할 낚싯대를 고른 뒤 [저장]을 눌러 주세요." end
		if Number(GetInventoryItemID("player", 16)) == id then return "선택한 낚싯대를 이미 장착했어요." end
		return "등록한 낚싯대가 가방에 없거나 잠겨 있어요."
	end
	return "현재 사용할 수 없는 동작이에요."
end

function M:BeforeAction(action)
	if InCombatLockdown() then return false end
	self:Refresh()
	if not self:GetActionMacro(action) then return false end
	if action == "equip" and record and not record.weapons and not EquippedPole() then
		-- Keep the snapshot until both slots are verified, including across reloads.
		record.weapons = CurrentWeapons()
		record.fishingSeen = false
	end
	return true
end

function M:AfterAction(action)
	if action == "restore" then
		restoreRequested, interactionStopped, manualPanel = true, true, false
		ns:Fire("FISHING_SESSION_FINISHED")
		StopTemporarySettings()
	end
	C_Timer.After(0.2, function() self:Refresh() end)
end

-- Empty original slots need an explicit hardware click and a free general-purpose bag slot.
function _G.EzyWOWFFishingUnequipEmptySlots()
	local saved = record and record.weapons
	if not saved or InCombatLockdown() or (GetCursorInfo and GetCursorInfo() ~= nil) then return end
	if not (C_Container and C_Container.PickupContainerItem and C_Container.GetContainerNumFreeSlots
		and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo and PickupInventoryItem) then return end
	for _, inventorySlot in ipairs({ 16, 17 }) do
		if saved[tostring(inventorySlot)].id == 0 and Number(GetInventoryItemID("player", inventorySlot)) then
			local done = false
			for bag = 0, NUM_BAG_SLOTS or 4 do
				local free, family = C_Container.GetContainerNumFreeSlots(bag)
				if Number(free) and free > 0 and Number(family) == 0 then
					for slot = 1, Number(C_Container.GetContainerNumSlots(bag)) or 0 do
						if not C_Container.GetContainerItemInfo(bag, slot) then
							PickupInventoryItem(inventorySlot)
							if not (GetCursorInfo and GetCursorInfo() == "item") then
								Print("장비를 옮길 수 없어요. 잠금이 풀린 뒤 다시 복원해 주세요.")
								return
							end
							C_Container.PickupContainerItem(bag, slot)
							if GetCursorInfo() ~= nil then
								if ClearCursor then ClearCursor() end
								Print("장비를 가방에 넣지 못했어요. 빈칸을 확인하고 다시 복원해 주세요.")
								return
							end
							done = true
							break
						end
					end
				end
				if done then break end
			end
			if not done then Print("무기를 복원하려면 일반 가방에 빈칸이 필요해요."); return end
		end
	end
end

local buttons = {}
for _, action in ipairs({ "cast", "lure", "equip", "restore" }) do
	local suffix = action:sub(1, 1):upper() .. action:sub(2)
	local button = CreateFrame("Button", "EzyWOWFFishing" .. suffix, UIParent, "SecureActionButtonTemplate")
	button:SetSize(1, 1)
	button:SetPoint("CENTER")
	button:SetAlpha(0)
	button:EnableMouse(false)
	button:RegisterForClicks("AnyUp", "AnyDown")
	button:SetAttribute("useOnKeyDown", false)
	button:SetScript("PreClick", function(self, mouseButton, down)
		if mouseButton ~= "LeftButton" then return end
		keyEvents[action] = keyEvents[action] + 1
		if down then return end
		self.actionReady, self.actionReason = false, nil
		if InCombatLockdown() then self.actionReason = M:GetActionBlockReason(action); return end
		self.actionReady = M:BeforeAction(action)
		self.actionReason = not self.actionReady and M:GetActionBlockReason(action) or nil
		local macro = self.actionReady and M:GetActionMacro(action) or nil
		self:SetAttribute("*type1", macro and "macro" or nil)
		self:SetAttribute("*macrotext1", macro)
	end)
	button:SetScript("PostClick", function(self, mouseButton, down)
		if down or mouseButton ~= "LeftButton" then return end
		if self.actionReason then Print(self.actionReason)
		elseif self.actionReady then M:AfterAction(action) end
		self.actionReady, self.actionReason = false, nil
	end)
	buttons[action] = button
end

function M:GetBagOptions(kind, current)
	local list = { { value = 0, text = kind == "pole" and "등록 안 함 (장착한 낚싯대 사용)" or "없음" } }
	local found = false
	local ids = {}
	for id in pairs(items) do
		if (kind == "pole" and IsPole(id)) or (kind == "lure" and LURES[id]) then ids[#ids + 1] = id end
	end
	local equipped = Number(GetInventoryItemID("player", 16))
	if kind == "pole" and equipped and IsPole(equipped) and not items[equipped] then ids[#ids + 1] = equipped end
	table.sort(ids)
	for _, id in ipairs(ids) do
		list[#list + 1] = { value = id, text = ("%s (%s)"):format(ItemName(id), items[id] and (items[id].count .. "개") or "장착 중") }
		found = found or id == current
	end
	if type(current) == "number" and current > 0 and not found then
		table.insert(list, 2, { value = current, text = ItemName(current) .. " (가방에 없음)" })
	end
	return list
end

function M:GetFishingState()
	local pole = EquippedPole()
	return {
		active = self:IsActive() and Alive() and not InCombatLockdown() and true or false,
		preparing = self:IsActive() and Alive() and not InCombatLockdown() and not interactionStopped
			and (manualPanel or pole or channeling) and not (self.IsMoveMode and self:IsMoveMode()) and true or false,
		channeling = channeling, pole = pole, skill = skill, skillMax = skillMax,
		freeSlots = freeSlots, lureRemaining = EnchantLeft(), bagsKnown = bagsKnown,
		enchantKnown = enchantKnown, enchanted = enchanted,
	}
end

function M:GetPreparationWarnings()
	local warnings = {}
	local function Add(key, text) warnings[#warnings + 1] = { key = key, text = text } end
	if db and db.alerts then
		if not EquippedPole() then Add("pole_missing", "낚싯대 미장착") end
		if freeSlots and freeSlots <= db.lowBagSlots then Add("bag_low", "가방 빈칸 부족") end
		if skill and skillMax and skillMax > 0 and skill >= skillMax then Add("skill_capped", "숙련 한도 도달") end
		local left = EnchantLeft()
		if left and left <= db.lureWarnSeconds then Add("lure_expiring", "미끼 곧 만료")
		elseif enchantKnown and not enchanted then Add("lure_missing", "미끼 미적용") end
		if bagsKnown then
			if not lure then Add("lure_unregistered", "등록 미끼 없음")
			elseif lure.count <= db.lowLureCount then Add("lure_low", "미끼 부족") end
		end
	end
	return warnings
end

function M:GetStatusText()
	local trained = skill and skillMax and ("숙련 %d/%d%s"):format(skill, skillMax,
		bonus and bonus > 0 and (" (+%d)"):format(bonus) or "") or (knownSpell and "숙련도 확인 불가" or "낚시를 배우지 않았어요")
	local space = freeSlots and ("가방 %d칸 여유"):format(freeSlots) or "가방 정보 확인 불가"
	local left = EnchantLeft()
	local bait = EquippedPole() and not enchantKnown and "미끼 정보 확인 불가"
		or enchanted and (left and ("미끼 %d:%02d"):format(math.floor(left / 60), math.floor(left % 60)) or "미끼 시간 확인 불가")
		or (lure and ("%s %d개"):format(ItemName(lure.id), lure.count) or "미끼 없음")
	local warnings = {}
	for _, warning in ipairs(self:GetPreparationWarnings()) do warnings[#warnings + 1] = warning.text end
	local state = channeling and "낚시 중 · 입질 후 건지기/상호작용 키" or "낚시 준비"
	if InCombatLockdown() then state = "전투 중 · 낚시 버튼 대기" end
	local poleID = Number(GetInventoryItemID("player", 16))
	local equipped = EquippedPole() and ("낚싯대: " .. ItemName(poleID)) or "낚싯대 미장착"
	return trained .. " · " .. space .. "\n" .. equipped .. " · " .. bait
		.. "\n" .. state .. (record and record.weapons and (" · 복원: " .. self:GetRestoreWeaponText()) or "")
		.. (#warnings > 0 and ("\n|cffffbb55" .. table.concat(warnings, " · ") .. "|r") or "")
end

function M:GetInteractKeyText()
	local key1, key2 = GetBindingKey("INTERACTTARGET")
	local labels = {}
	for _, key in ipairs({ key1 or "", key2 or "" }) do
		if key ~= "" then labels[#labels + 1] = GetBindingText(key) or key end
	end
	return #labels > 0 and table.concat(labels, " / ") or "미지정"
end

function M:PrintDiagnostics()
	self:Refresh()
	local key1, key2 = GetBindingKey(CAST_BINDING)
	for _, key in ipairs({ key1 or "", key2 or "" }) do
		if key ~= "" then
			Print(("찌 던지기 키 [%s]: %s"):format(key, GetBindingAction(key) or "미지정"))
		end
	end
	if not key1 and not key2 then Print("찌 던지기 단축키가 지정되지 않았어요. 지정 후 [저장]을 눌러 주세요.") end
	local interactKey1, interactKey2 = GetBindingKey("INTERACTTARGET")
	for _, key in ipairs({ interactKey1 or "", interactKey2 or "" }) do
		if key ~= "" then
			Print(("상호작용 키 [%s]: %s"):format(key, GetBindingAction(key, true) or "미지정"))
		end
	end
	if not interactKey1 and not interactKey2 then Print("상호작용 단축키가 지정되지 않았어요.") end
	Print(("낚시 시전: %s · 단축키 버튼 표시: %s · 입력 수신: %d회"):format(
		self:GetActionBlockReason("cast") or "준비됨", buttons.cast:IsShown() and "켜짐" or "꺼짐", keyEvents.cast))
	Print(("숙련도: %s/%s · 주무기: %s"):format(tostring(skill or "확인 불가"), tostring(skillMax or "확인 불가"),
		Number(GetInventoryItemID("player", 16)) and ItemName(Number(GetInventoryItemID("player", 16))) or "없음"))
	Print("복원할 무기: " .. self:GetRestoreWeaponText())
	if self.GetMouseInteractStatus then Print(self:GetMouseInteractStatus()) end
end

function M:OpenTrainer()
	local finder = ns.TrainerFinder
	if finder and finder.SetKindChecked then finder.SetKindChecked("FISHING", true) end
	ns:OpenWindow("TrainerFinder")
end

local function SyncTicker()
	local want = M:IsActive() and (channeling or session or EquippedPole())
	if want and not ticker then ticker = C_Timer.NewTicker(1, function() M:Refresh(false) end)
	elseif not want and ticker then ticker:Cancel(); ticker = nil end
end

function M:Refresh(scanBags)
	if not db then return end
	if scanBags ~= false then ReadBags(); ReadSkill() end
	ReadEnchant()
	ObserveWeapons()
	if session and not channeling and not EquippedPole() then StopTemporarySettings() end
	if InCombatLockdown() then pending = true
	else
		pending = false
		for action, button in pairs(buttons) do
			local macro = self:GetActionMacro(action)
			button:SetAttribute("*type1", macro and "macro" or nil)
			button:SetAttribute("*macrotext1", macro)
		end
	end
	SyncTicker()
	ns:Fire("FISHING_UPDATED")
end

local function RequestUpdate()
	if queued or not db then return end
	queued = true
	C_Timer.After(0.2, function() queued = false; M:Refresh() end)
end

function M:OnInitialize()
	db = self.db
	ns.db.fishingCharacters = ns.db.fishingCharacters or {}
end

function M:OnLogin()
	local key = PlayerKey()
	ns.db.fishingCharacters[key] = ns.db.fishingCharacters[key] or {}
	record = ns.db.fishingCharacters[key]
	ns:Fire("FISHING_RECORD_READY", record)
	StopTemporarySettings()
	if not db.migratedTweaks then
		local old = ns.modules.Tweaks
		if old and old.db and old.db.fishingAuto ~= nil then db.rangeAssist = old.db.fishingAuto end
		db.migratedTweaks = true
	end
	self:Refresh()
	if self.ApplyPanelLayout then self:ApplyPanelLayout() end
end

function M:ApplySettings()
	StopTemporarySettings()
	if not db.enabled then channeling = false; manualPanel = false end
	if self.ApplyPanelLayout then self:ApplyPanelLayout() end
	self:Refresh()
	if channeling and self:IsActive() then StartChannelSettings() end
end

ns:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", function(_, unit, _, id)
	if unit ~= "player" or not M:IsActive() or not IsFishing(id) then return end
	local newCast = not channeling or interactionStopped
	interactionStopped = false
	channeling = true
	StartChannelSettings()
	if newCast then ns:Fire("FISHING_CAST_STARTED") end
	M:Refresh(false)
end, "player")

ns:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", function(_, unit)
	if unit ~= "player" or not channeling then return end
	channeling = false
	Release("channel")
	M:Refresh(false)
end, "player")

for _, event in ipairs({ "BAG_UPDATE_DELAYED", "PLAYER_EQUIPMENT_CHANGED", "GET_ITEM_INFO_RECEIVED", "SKILL_LINES_CHANGED", "SPELLS_CHANGED" }) do
	ns:RegisterEvent(event, RequestUpdate)
end

for _, event in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_DEAD", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "PLAYER_LOGOUT" }) do
	ns:RegisterEvent(event, function()
		channeling = false
		ns:Fire("FISHING_SESSION_PAUSED")
		StopTemporarySettings()
		if event ~= "PLAYER_LOGOUT" then M:Refresh(false) end
	end)
end

ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() if pending or db then M:Refresh() end end)

SLASH_EZYWOWF_FISHING1 = "/낚시"
SLASH_EZYWOWF_FISHING2 = "/fishing"
SlashCmdList.EZYWOWF_FISHING = function(message)
	message = type(message) == "string" and message:match("^%s*(.-)%s*$"):lower() or ""
	if message == "진단" or message == "debug" then M:PrintDiagnostics()
	else ns:OpenWindow("Fishing") end
end
