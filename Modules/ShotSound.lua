-- 사격 소리: 총·활·석궁 발사 소리를 소음기 저격총 같은 조용한 소리로 바꾸거나 끈다.
--
-- 애드온은 게임 소리 파일을 바꿔 끼울 수 없다(8.2부터). 원래 발사 소리 파일을 MuteSoundFile로 막고,
-- 내가 쏠 때 애드온 소리를 PlaySoundFile로 낸다. Sounds\의 rifle* = 직접 합성(tests\make_shot_sounds.py),
-- gunshots* = Sonilo 무료 효과음을 다듬은 것(tests\import_shot_wav.py, MIT 아님·따로 재배포 금지).
-- 막기는 파일 단위라 다른 사람·NPC가 쏘는 같은 무기 소리도 같이 조용해진다. 새 소리는 내 사격에만 난다.
-- 무기 소리는 무기 외형의 원거리 시전 효과에서 나온다(포에버 1.60.1.70235 ItemRangedDisplayInfo → SpellVisualKitEffect):
--   총 → 장전 소리 묶음 1147 + 발사 1148(gunfire01~03)
--   활·석궁 → 시위 1144 + 발사 1146(bowrelease 1~3) + 명중 4296
-- 발사만 막고 장전 철컥·시위 당김·명중 소리는 그대로 둔다.
-- 자동 사격은 PLAYER_SWING(원거리)과 UNIT_SPELLCAST_SUCCEEDED 둘 다 받아 먼저 온 쪽만 쓴다. 특수 사격은 SUCCEEDED.
-- 막은 파일은 /reload를 넘어 남고 게임을 끄면 풀린다. 그래서 막은 목록을 db.muted에 적어 두고 풀 때 그것만 푼다.

local ADDON_NAME, ns = ...
local Clean = ns.Clean

local SOUND_DIR = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Sounds\\"
local VARIANTS = 3          -- 파일마다 _1~_3, 게임처럼 쏠 때마다 골라 낸다
local AUTO_GAP = 0.4        -- 자동 사격 한 발에 두 이벤트가 이만큼 안에 오면 같은 발 (가장 빠른 연사도 0.9초쯤)
local SAME_MOMENT = 0.05    -- 같은 프레임에 온 사격은 한 번만

local GUN_FIRE = { 567721, 567718, 567722 }      -- sound/item/weapons/gun/gunfire01~03
local BOW_RELEASE = { 567674, 567673, 567682 }   -- sound/item/weapons/bow/bowrelease, 02, 03
local GUN_KIT, BOW_KIT = 1148, 1146              -- "게임 기본" 미리 듣기용 (원래 볼륨 그대로)

local SUBCLASS = Enum and Enum.ItemWeaponSubclass or {}
local WEAPON_KIND = {
	[SUBCLASS.Guns or 3] = "gun",
	[SUBCLASS.Bows or 2] = "bow",
	[SUBCLASS.Crossbow or 18] = "bow",   -- 석궁도 활 소리를 쓴다
}
local RANGED_SWING = Enum and Enum.PlayerSwingType and Enum.PlayerSwingType.Ranged or 2
local RANGED_SLOT = INVSLOT_RANGED or 18

-- 1등급 번호. 다른 등급은 이름으로 맞춘다. auto = 자동으로 되풀이되는 사격
local SHOTS = {
	{ 75, auto = true },     -- 자동 사격
	{ 2480, auto = true },   -- 활 발사 (사냥꾼이 아닌 직업)
	{ 7918, auto = true },   -- 총 발사
	{ 7919, auto = true },   -- 석궁 발사
	{ 3044 },     -- 신비한 사격
	{ 2643 },     -- 일제 사격
	{ 19434 },    -- 조준 사격
	{ 5116 },     -- 충격포
	{ 1978 },     -- 독사 쐐기
	{ 3043 },     -- 전갈 쐐기
	{ 3034 },     -- 살무사 쐐기
	{ 20736 },    -- 견제 사격
	{ 19503 },    -- 산탄 사격
	{ 19801 },    -- 평정의 사격
	{ 3674 },     -- 검은 화살
	{ 409433 },   -- 키메라 사격
	{ 1310687 },  -- 저격
}

-- sound = Sounds\<값>_<크기>_<1~3>.ogg 를 낸다
local CHOICES = {
	{ value = "game", text = "게임 기본 소리" },
	{ value = "rifle", text = "소음기 저격총 (피슝)", sound = true },
	{ value = "rifle_low", text = "소음기 저격총 (프슝, 낮게)", sound = true },
	{ value = "gunshots1", text = "총소리 1 (gunshots1, 짧게)", sound = true },
	{ value = "gunshots2", text = "총소리 2 (gunshots2)", sound = true },
	{ value = "gunshots3", text = "총소리 3 (gunshots3, 울림)", sound = true },
	{ value = "off", text = "소리 끄기" },
}
local IS_SOUND = {}
for _, o in ipairs(CHOICES) do
	if o.sound then IS_SOUND[o.value] = true end
end
local VOLUMES = {
	{ value = "quiet", text = "작게" },
	{ value = "normal", text = "보통 (활 소리 정도)" },
	{ value = "loud", text = "크게" },
}

local M = ns:NewModule("ShotSound", {
	title = "사격 소리",
	category = "hunter",
	icon = "Interface\\Icons\\INV_Weapon_Rifle_01",
	order = 14,
	defaults = {
		enabled = true,
		gun = "rifle",
		bow = "game",
		volume = "normal",
	},
})

local db
local weaponKind          -- "gun" / "bow" / nil (원거리 무기 없음, 마법봉·투척)
local shotByID, shotByName
local lastAuto, lastShot = -10, -10
local lastVariant = 0

local function TextOf(list, value)
	for _, o in ipairs(list) do
		if o.value == value then return o.text end
	end
	return value
end

local function IsReplacement(choice)
	return IS_SOUND[choice] == true
end

local function IsListed(list, value)
	for _, o in ipairs(list) do
		if o.value == value then return true end
	end
	return false
end

---------------------------------------------------------------------------
-- 원래 소리 막기
---------------------------------------------------------------------------
local function CanMute()
	return type(MuteSoundFile) == "function" and type(UnmuteSoundFile) == "function"
end

local function WantedMutes()
	local want = {}
	if db.enabled then
		if db.gun ~= "game" then for _, id in ipairs(GUN_FIRE) do want[id] = true end end
		if db.bow ~= "game" then for _, id in ipairs(BOW_RELEASE) do want[id] = true end end
	end
	return want
end

local function ApplyMutes()
	if not CanMute() then return end
	local want = WantedMutes()
	for id in pairs(db.muted) do
		if not want[id] then
			UnmuteSoundFile(id)
			db.muted[id] = nil
		end
	end
	-- 게임을 새로 켜면 다 풀려 있어서 적어 둔 것도 다시 막는다
	for id in pairs(want) do
		MuteSoundFile(id)
		db.muted[id] = true
	end
end

---------------------------------------------------------------------------
-- 새 소리
---------------------------------------------------------------------------
local function PlayReplacement(choice, volume)
	if not IsReplacement(choice) then return end
	-- 같은 파일이 두 번 연달아 나오면 기계 같아서 직전 것은 빼고 고른다
	local n = math.random(lastVariant > 0 and VARIANTS - 1 or VARIANTS)
	if lastVariant > 0 and n >= lastVariant then n = n + 1 end
	lastVariant = n
	PlaySoundFile(("%s%s_%s_%d.ogg"):format(SOUND_DIR, choice, volume, n), "SFX")
end

local function UpdateWeapon()
	weaponKind = nil
	local itemID = GetInventoryItemID("player", RANGED_SLOT)
	if not itemID then return end
	local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
	if classID == (Enum and Enum.ItemClass and Enum.ItemClass.Weapon or 2) then
		weaponKind = WEAPON_KIND[subclassID]
	end
end

local function OnShot(isAuto)
	if not (db and db.enabled and weaponKind and CanMute()) then return end
	local choice = db[weaponKind]
	if not IsReplacement(choice) then return end
	local now = GetTime()
	if now - math.max(lastAuto, lastShot) < SAME_MOMENT then return end
	if isAuto then
		if now - lastAuto < AUTO_GAP then return end
		lastAuto = now
	else
		lastShot = now
	end
	PlayReplacement(choice, db.volume)
end

local function BuildShotTables()
	shotByID, shotByName = {}, {}
	for _, s in ipairs(SHOTS) do
		local kind = s.auto and "auto" or "shot"
		shotByID[s[1]] = kind
		local name = C_Spell and C_Spell.GetSpellName and Clean(C_Spell.GetSpellName(s[1]))
		if name then shotByName[name] = kind end
	end
end

local function ShotKind(spellID)
	if not shotByID then BuildShotTables() end
	local kind = shotByID[spellID]
	if kind then return kind end
	local name = C_Spell and C_Spell.GetSpellName and Clean(C_Spell.GetSpellName(spellID))
	return name and shotByName[name]
end

ns:RegisterEvent("PLAYER_SWING", function(_, _, swingType)
	if Clean(swingType) == RANGED_SWING then OnShot(true) end
end)

ns:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, _, _, spellID)
	spellID = Clean(spellID)
	if not (db and db.enabled and spellID) then return end
	local kind = ShotKind(spellID)
	if kind then OnShot(kind == "auto") end
end, "player")

ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function(_, slot)
	if slot == RANGED_SLOT then UpdateWeapon() end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	if type(db.muted) ~= "table" then db.muted = {} end   -- 기본값이 아니라서 설정 내보내기에는 안 실린다
	-- 목록에 없는 값(지운 소리 등)이 저장돼 있으면 기본값으로
	for key, list in pairs({ gun = CHOICES, bow = CHOICES, volume = VOLUMES }) do
		if not IsListed(list, db[key]) then db[key] = M.defaults[key] end
	end
end

function M:OnLogin()
	UpdateWeapon()
	ApplyMutes()
end

function M:ApplySettings()
	ApplyMutes()
end

-- 설정 창의 아직 저장 안 한 값으로 들려준다. 게임 기본은 막아 둔 파일을 잠깐 풀었다가 다시 막는다.
local function Preview(kind)
	local choice, volume = ns:GetSetting(M, kind), ns:GetSetting(M, "volume")
	if IsReplacement(choice) then
		PlayReplacement(choice, volume)
	elseif choice == "game" then
		if CanMute() then
			for _, id in ipairs(kind == "gun" and GUN_FIRE or BOW_RELEASE) do UnmuteSoundFile(id) end
		end
		PlaySound(kind == "gun" and GUN_KIT or BOW_KIT, "SFX")
		C_Timer.After(2, ApplyMutes)
	end
end

local function StatusText()
	if not CanMute() then return "|cffff6060이 게임 버전에서는 소리를 막을 수 없어서 쓸 수 없어요.|r" end
	if not db.enabled then return "|cff808080꺼져 있어요.|r" end
	local weapon = weaponKind == "gun" and "총" or weaponKind == "bow" and "활·석궁" or nil
	if not weapon then return "지금 원거리 무기: |cff808080총·활·석궁이 아니에요|r" end
	local choice = db[weaponKind]
	local text = TextOf(CHOICES, choice)
	if IsReplacement(choice) then text = text .. " · " .. TextOf(VOLUMES, db.volume) end
	return ("지금 원거리 무기: %s → |cffffd100%s|r"):format(weapon, text)
end

function M:BuildOptions(b)
	b:Text("총·활·석궁을 쏠 때 나는 소리를 바꿉니다. 게임 소리 파일은 바꿔 끼울 수 없어서, 원래 발사 소리를 끄고 "
		.. "내가 쏠 때 새 소리를 냅니다. 원래 소리가 통째로 꺼지므로 다른 사람·NPC가 쏘는 같은 무기 소리도 조용해져요. "
		.. "장전 철컥, 시위 당기는 소리, 화살 맞는 소리는 그대로예요. 사냥꾼이 아닌 직업의 사격에도 똑같이 적용돼요.")
	b:Check{ key = "enabled", label = "사용" }

	local function Choices() return CHOICES end
	for _, row in ipairs({ { key = "gun", label = "총 소리" }, { key = "bow", label = "활·석궁 소리" } }) do
		b:Dropdown{
			key = row.key, label = row.label, options = Choices, depends = "enabled",
			tooltip = "고르면 바로 한 번 들려줍니다. [저장]을 눌러야 바뀝니다.",
			set = function(value)
				ns:SetSetting(M, row.key, value)
				Preview(row.key)
			end,
		}
	end
	b:Dropdown{
		key = "volume", label = "새 소리 크기", options = function() return VOLUMES end, depends = "enabled",
		tooltip = "소음기 소리의 크기예요. 게임 설정의 효과음 크기도 같이 따릅니다.",
		set = function(value)
			ns:SetSetting(M, "volume", value)
			-- 고른 새 소리로 들려주고, 둘 다 새 소리가 아니면 저격총으로 크기만 들려준다
			local choice = ns:GetSetting(M, "gun")
			if not IsReplacement(choice) then choice = ns:GetSetting(M, "bow") end
			PlayReplacement(IsReplacement(choice) and choice or "rifle", value)
		end,
	}
	b:Buttons{
		{ text = "총 소리 들어 보기", width = 140, onClick = function() Preview("gun") end, depends = "enabled" },
		{ text = "활 소리 들어 보기", width = 140, onClick = function() Preview("bow") end, depends = "enabled" },
	}
	b:Text(StatusText, { font = "GameFontHighlight" })
	b:Text("다른 사람이 쏘는 소리까지 듣고 싶으면 그 무기를 '게임 기본 소리'로 두세요. "
		.. "이 기능을 끄거나 '게임 기본 소리'로 바꾸고 [저장]하면 원래 소리가 바로 돌아와요.", { color = { 0.6, 0.6, 0.6 } })
end
