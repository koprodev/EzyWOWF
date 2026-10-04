-- 대화 시각: 대화창의 모든 줄 앞에 그 줄이 들어온 시각을 붙인다. 획득·기술 향상 같은 시스템 줄까지.
-- 게임 기본 '대화 시각'(설정 > 소셜)은 플레이어·NPC 대화 줄에만 붙어서 따로 만들었다.
-- 대화창 기록(historyBuffer)에 줄이 들어온 직후 PushFront 후크에서 그 줄 글자 앞에 시각을 끼운다.
--   AddMessage를 바꿔 끼우지 않으니 대화 이벤트 처리는 오염(taint)되지 않는다. 줄 글자는 우리가 쓴 값이라 화면 갱신은 우리 몫으로 남는다.
--   비밀값 줄(전투 제한 중 일부 대화)은 애드온이 읽을 수 없어서 그대로 둔다.
-- 시각은 숨은 링크(|Haddon:ezyts:초|h)에 원래 시각을 담는다. 형식을 바꾸거나 껐다 켜면 이미 있는 줄도 다시 그린다.

local _, ns = ...
local Print = ns.Print
local IsSecret = issecretvalue or function() return false end

local M = ns:NewModule("ChatTime", {
	title = "대화 시각",
	category = "interface",
	icon = "Interface\\Icons\\INV_Misc_PocketWatch_03",
	order = 15,
	defaults = {
		enabled = true,
		format = "hm",   -- hm | hms | ampm | ampms
		gray = true,     -- 시각만 회색으로
	},
})

local db
local GRAY = "|cff8c8c8c"
local LINK = "ezyts"

---------------------------------------------------------------------------
-- 시각 글자
---------------------------------------------------------------------------
-- d = date("*t") 표. 오전/오후는 게임 글자 대신 고정 (게임 안 문구는 한국어만)
local function ClockText(fmt, d)
	local h, m, s = d.hour, d.min, d.sec
	if fmt == "ampm" or fmt == "ampms" then
		local half = h < 12 and "오전" or "오후"
		local h12 = h % 12
		if h12 == 0 then h12 = 12 end
		if fmt == "ampms" then return ("%s %d:%02d:%02d"):format(half, h12, m, s) end
		return ("%s %d:%02d"):format(half, h12, m)
	end
	if fmt == "hms" then return ("%02d:%02d:%02d"):format(h, m, s) end
	return ("%02d:%02d"):format(h, m)
end

local EXAMPLE = { hour = 15, min = 27, sec = 32 }
local FORMATS = {}
for _, fmt in ipairs({ "hm", "hms", "ampm", "ampms" }) do
	FORMATS[#FORMATS + 1] = { value = fmt, text = "[" .. ClockText(fmt, EXAMPLE) .. "]" }
end

local function MakeStamp(t)
	local stamp = ("|Haddon:%s:%d|h[%s]|h"):format(LINK, t, ClockText(db.format, date("*t", t)))
	if db.gray then stamp = GRAY .. stamp .. "|r" end
	return stamp .. " "
end

-- 줄 맨 앞의 우리 시각을 떼어 낸다 → 원래 시각(초), 나머지 글자. 없으면 nil
local function SplitStamp(msg)
	local t, rest = msg:match("^|c%x%x%x%x%x%x%x%x|Haddon:ezyts:(%d+)|h[^|]*|h|r (.*)$")
	if not t then t, rest = msg:match("^|Haddon:ezyts:(%d+)|h[^|]*|h (.*)$") end
	if t then return tonumber(t), rest end
end

-- 시각을 붙일 수 있는 줄 글자만. 비밀값은 비교만 해도 오류라 맨 먼저 거른다
local function Readable(msg)
	return not IsSecret(msg) and type(msg) == "string" and msg ~= ""
end

---------------------------------------------------------------------------
-- 대화창 후크
---------------------------------------------------------------------------
local frames = {}   -- [historyBuffer] = 대화창
-- [eventArgs 표] = 받은 시각. 검열 줄을 펼치면 블리자드가 줄을 새로 만들지만 이 표는 그대로 넘겨준다
local arrived = setmetatable({}, { __mode = "k" })

-- 블리자드 대화 줄의 추가 정보 5번째가 eventArgs 표 (info.id, accessID, typeID, event, eventArgs, formatter)
local function EventArgs(entry)
	local extra = entry.extraData
	local args = type(extra) == "table" and extra[5]
	if not IsSecret(args) and type(args) == "table" then return args end
end

-- 전투 기록 창은 블리자드 전투 기록 설정에 따로 시각 옵션이 있다
local function Skip(frame)
	return type(IsCombatLog) == "function" and IsCombatLog(frame) and true or false
end

-- 방금 들어온 줄(1번 = 가장 새 줄)에 지금 시각을 붙인다
local function OnPush(buffer)
	if not (db and db.enabled) then return end
	local frame = frames[buffer]
	if not frame or Skip(frame) then return end
	local entry = buffer:GetEntryAtIndex(1)
	if not entry then return end
	local now = time()
	local args = EventArgs(entry)
	if args and not arrived[args] then arrived[args] = now end
	local msg = entry.message
	if not Readable(msg) or SplitStamp(msg) then return end   -- 시각 달린 줄을 옮겨 온 것(귓속말 창 분리 등)은 그대로
	entry.message = MakeStamp(now) .. msg
end

-- 줄이 들어온 시각: 기억해 둔 받은 시각, 없으면 지금 - (지금 GetTime - 줄을 담을 때 GetTime)
local function EntryTime(entry, now, clock)
	local args = EventArgs(entry)
	if args and arrived[args] then return arrived[args] end
	local ts = entry.timestamp
	if not IsSecret(ts) and type(ts) == "number" then return math.floor(now - (clock - ts) + 0.5) end
	return now
end

-- 이미 있는 줄을 지금 설정대로 다시 그린다. 원래 시각은 링크에 남아 있어서 바뀌지 않는다
local function Restamp(buffer, frame)
	local add = db.enabled and not Skip(frame)
	local now, clock = time(), GetTime()
	local changed = false
	for i = 1, buffer:GetNumElements() do
		local entry = buffer:GetEntryAtIndex(i)
		local msg = entry and entry.message
		if Readable(msg) then
			local t, rest = SplitStamp(msg)
			local new = rest or msg
			if add then new = MakeStamp(t or EntryTime(entry, now, clock)) .. new end
			if new ~= msg then
				entry.message = new
				changed = true
			end
		end
	end
	if changed and frame.MarkDisplayDirty then frame:MarkDisplayDirty() end
end

local function RestampAll()
	for buffer, frame in pairs(frames) do Restamp(buffer, frame) end
end

local function Hook(frame)
	local buffer = type(frame) == "table" and frame.historyBuffer
	if type(buffer) ~= "table" or frames[buffer] or type(buffer.PushFront) ~= "function" then return end
	frames[buffer] = frame
	hooksecurefunc(buffer, "PushFront", OnPush)
	-- 검열 줄을 펼치면 블리자드가 줄을 새로 만들어 끼운다. 시각이 빠진 그 줄을 채운다
	if type(frame.TransformMessages) == "function" then
		hooksecurefunc(frame, "TransformMessages", function() Restamp(buffer, frame) end)
	end
	if db.enabled then Restamp(buffer, frame) end   -- 후크 전에 들어온 줄
end

-- 귓속말 창처럼 나중에 생기는 대화창도 CHAT_FRAMES에 이름이 들어간다
local function HookAll()
	if type(CHAT_FRAMES) ~= "table" then return end
	for _, name in ipairs(CHAT_FRAMES) do Hook(_G[name]) end
end

---------------------------------------------------------------------------
-- 시각에 마우스를 올리면 날짜까지
---------------------------------------------------------------------------
local WEEKDAYS = { "일", "월", "화", "수", "목", "금", "토" }
local tipOwner

local function Ago(sec)
	if sec < 60 then return "방금 전" end
	local min = math.floor(sec / 60)
	if min < 60 then return min .. "분 전" end
	return ("%d시간 %d분 전"):format(math.floor(min / 60), min % 60)
end

local function OnLinkEnter(_, frame, link)
	if IsSecret(link) or type(link) ~= "string" or not GameTooltip then return end
	local t = tonumber(link:match("^addon:ezyts:(%d+)") or "")
	if not t then return end
	local d = date("*t", t)
	GameTooltip:SetOwner(frame, "ANCHOR_CURSOR")
	GameTooltip:SetText(("%d년 %d월 %d일 (%s) %s"):format(d.year, d.month, d.day, WEEKDAYS[d.wday] or "?", ClockText("ampms", d)), 1, 1, 1)
	GameTooltip:AddLine(Ago(math.max(time() - t, 0)), 0.7, 0.7, 0.7)
	GameTooltip:Show()
	tipOwner = frame
end

local function OnLinkLeave(_, frame)
	if tipOwner and tipOwner == frame then
		tipOwner = nil
		GameTooltip:Hide()
	end
end

---------------------------------------------------------------------------
-- 게임 기본 '대화 시각'과 겹침
---------------------------------------------------------------------------
-- 게임 형식은 "%H:%M " 같은 글자, 꺼짐은 "none"
local function GameStampOn()
	local v = GetCVar("showTimestamps")
	return type(v) == "string" and v:find("%", 1, true) ~= nil
end

local function TurnOffGameStamp()
	SetCVar("showTimestamps", "none")
	Print("게임 설정의 '대화 시각'을 껐습니다. 이제 대화 줄에도 시각이 한 번만 붙어요.")
end

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
	HookAll()
	if type(FCF_OpenTemporaryWindow) == "function" then hooksecurefunc("FCF_OpenTemporaryWindow", HookAll) end
	if EventRegistry and EventRegistry.RegisterCallback then
		EventRegistry:RegisterCallback("ChatFrame.OnHyperlinkEnter", OnLinkEnter, M)
		EventRegistry:RegisterCallback("ChatFrame.OnHyperlinkLeave", OnLinkLeave, M)
	end
end

function M:OnLogin()
	HookAll()
	if db.enabled and GameStampOn() then
		Print("게임 설정의 '대화 시각'도 켜져 있어서 대화 줄에 시각이 두 번 붙어요. /이지 > " .. ns:SettingsPath("ChatTime") .. "에서 끌 수 있어요.")
	end
end

function M:ApplySettings()
	RestampAll()
end

function M:BuildOptions(b)
	b:Text("대화창의 모든 줄 앞에 그 줄이 들어온 시각을 붙입니다. 아이템 획득, 기술 향상 같은 시스템 메시지도 포함합니다. "
		.. "시각에 마우스를 올리면 날짜와 몇 분 전인지 보여 줍니다.")
	b:Check{ key = "enabled", label = "사용",
		tooltip = "끄면 이미 붙은 시각도 지웁니다. 전투 기록 창은 건드리지 않습니다." }
	b:Dropdown{ key = "format", label = "시각 형식", depends = "enabled", width = 180,
		options = function() return FORMATS end }
	b:Check{ key = "gray", label = "시각을 회색으로", depends = "enabled",
		tooltip = "끄면 시각이 그 줄과 같은 색으로 보입니다." }

	b:Header("게임 기본 '대화 시각'")
	b:Text(function()
		if GameStampOn() then
			return "|cffff8040게임 설정(설정 > 소셜 > 대화 시각)도 켜져 있어서, 플레이어·NPC 대화 줄에는 시각이 두 번 붙습니다.|r"
		end
		return "게임 설정(설정 > 소셜 > 대화 시각)은 꺼져 있어서 겹치지 않습니다."
	end)
	b:Buttons{
		{ text = "게임 대화 시각 끄기", width = 160, onClick = TurnOffGameStamp,
			disabled = function() return not GameStampOn() end,
			tooltip = "게임 기본 '대화 시각'을 '없음'으로 바꿉니다. 이 기능은 플레이어·NPC 대화 줄에만 시각을 붙입니다." },
	}

	b:Text("- 형식·색을 바꾸거나 껐다 켜면 이미 있는 줄도 원래 시각 그대로 다시 그립니다.\n"
		.. "- 던전·전투 제한 중 애드온이 읽을 수 없게 막힌 대화 줄에는 시각이 붙지 않습니다.\n"
		.. "- [사용], [시각 형식], [시각을 회색으로]는 [저장]을 눌러야 적용됩니다.",
		{ color = { 0.7, 0.7, 0.7 } })
end
