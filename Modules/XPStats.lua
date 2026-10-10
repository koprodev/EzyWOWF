-- 경험치 통계: 캐릭터마다 몹 처치·퀘스트·탐험·기타로 나눠 이번 접속·오늘·레벨별·누적을 센다.
--
-- 양은 경험치 바 차이(UnitXP, 레벨업 넘김 포함)가 기준이라 합계는 늘 바와 맞는다.
-- 출처는 바로 앞의 단서로 고른다: 퀘스트 완료(QUEST_TURNED_IN의 보상 경험치), 처치·탐험 문구.
-- 단서와 경험치 변화가 오는 순서는 들쭉날쭉이라 조용해진 뒤(SETTLE) 한꺼번에 나눈다. 남는 양은 기타.
-- 문구는 클라이언트 전역 문구(COMBATLOG_XPGAIN_* 등)로 패턴을 만든다. 한국어 조사 표시(|1이;가;)도 펼친다.
-- 휴식 보너스는 문구를 읽지 않고 휴식 경험치(GetXPExhaustion)가 줄어든 만큼으로 센다.
-- 기록은 이 모듈 db.chars[GUID]에 있다. 표라서 설정 내보내기(EZY1:)에는 안 실린다.

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local BINDING = "EZYWOWF_XPSTATS"
BINDING_NAME_EZYWOWF_XPSTATS = "경험치 통계 창 열기/닫기"

local M = ns:NewModule("XPStats", {
	title = "경험치 통계", category = "info", icon = "Interface\\Icons\\INV_Misc_Book_07", order = 11,
	bindings = { BINDING },
	defaults = {
		enabled = true, showPanel = true, showInfoBar = true,
		excludeAFK = true, autoPlayed = false, recentMinutes = 10,
		scale = 1, point = "CENTER", relPoint = "CENTER", x = 330, y = -140,
		winPoint = "CENTER", winRelPoint = "CENTER", winX = 0, winY = 40,
	},
})

local SETTLE = 0.3          -- 단서·경험치 변화가 이만큼 조용하면 나눈다
local CLAIM_TTL = 3         -- 경험치가 끝내 안 오르면 단서를 버리는 시간
local DEDUPE = 1            -- 같은 문구가 채팅·화면 안내 두 곳으로 와도 한 번만
local SAMPLE_EVERY = 15     -- 최근 속도용 표본 간격 (활동 초)
local SAMPLE_KEEP = 1800    -- 표본 보관 (활동 초)
local MIN_RATE_TIME = 120   -- 이보다 짧으면 시간당 값을 안 낸다 (첫 몹 한 마리로 시간당 50만 같은 소리 방지)
local DAY_LIMIT, MOB_LIMIT, QUEST_LIMIT = 31, 400, 100

M.SOURCES = { "kill", "quest", "explore", "other" }
M.LABELS = { kill = "몹 처치", quest = "퀘스트", explore = "탐험", other = "기타" }
M.COLORS = {
	kill = { 0.9, 0.35, 0.3 }, quest = { 1, 0.82, 0 }, explore = { 0.35, 0.8, 0.45 }, other = { 0.6, 0.6, 0.6 },
}
local FIELDS = { "xp", "kill", "quest", "explore", "other", "rested", "kills", "quests", "time" }
local POINTS = {
	TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
	RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}
local PRIORITY = { quest = 1, explore = 2, kill = 3 }

local db, char, last
local started, active = false, false
local claims = {}
local dirtyAt
local carryRested, carryAt = 0, 0   -- 경험치보다 먼저 줄어든 휴식 경험치 (잠깐 들고 있다가 다음 증가에 붙인다)
local seen = {}
local killPatterns, systemPatterns
local infoText

---------------------------------------------------------------------------
-- 글자
---------------------------------------------------------------------------
function M.Comma(n)
	n = math.floor((tonumber(n) or 0) + 0.5)
	local s = tostring(math.abs(n))
	while true do
		local k
		s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
		if k == 0 then break end
	end
	return (n < 0 and "-" or "") .. s
end

function M.Duration(sec)
	sec = math.max(0, math.floor((tonumber(sec) or 0) + 0.5))
	local d, h, m = math.floor(sec / 86400), math.floor(sec / 3600) % 24, math.floor(sec / 60) % 60
	if d > 0 then return ("%d일 %d시간"):format(d, h) end
	if h > 0 then return ("%d시간 %d분"):format(h, m) end
	if m > 0 then return ("%d분"):format(m) end
	return ("%d초"):format(sec)
end

function M.Percent(part, whole)
	if type(whole) ~= "number" or whole <= 0 then return 0 end
	return (part or 0) / whole * 100
end

---------------------------------------------------------------------------
-- 저장 표
---------------------------------------------------------------------------
local function NewBucket()
	local b = {}
	for _, k in ipairs(FIELDS) do b[k] = 0 end
	return b
end
M.NewBucket = NewBucket

local function Fix(b)
	if type(b) ~= "table" then return NewBucket() end
	for _, k in ipairs(FIELDS) do
		if type(b[k]) ~= "number" or b[k] ~= b[k] then b[k] = 0 end
	end
	return b
end

local function PlayerKey()
	local guid = Clean(UnitGUID("player"))
	if type(guid) == "string" and guid ~= "" then return guid end
	return (GetRealmName() or "") .. ":" .. (Clean(UnitName("player")) or "")
end

-- 게임에 보이는 이름 그대로 (포에버: "이름 성")
local function PlayerName()
	if NameUtil and NameUtil.GetUnmodifiedUnitFullName then
		local ok, name = pcall(NameUtil.GetUnmodifiedUnitFullName, "player")
		name = ok and Clean(name)
		if type(name) == "string" and name ~= "" then return name end
	end
	return Clean(UnitName("player")) or "?"
end

-- 저장 파일이 깨졌거나 옛 모양이어도 창·계산이 숫자만 만나게 한 번 다듬는다
local function Sanitize(c)
	c.total = Fix(c.total)
	for _, k in ipairs({ "days", "levels", "zones", "mobs", "quests" }) do
		if type(c[k]) ~= "table" then c[k] = {} end
	end
	for _, k in ipairs({ "days", "zones" }) do
		for key, b in pairs(c[k]) do
			if type(b) == "table" then Fix(b) else c[k][key] = nil end
		end
	end
	for lv, r in pairs(c.levels) do
		if type(lv) ~= "number" or type(r) ~= "table" then
			c.levels[lv] = nil
		else
			r.b = Fix(r.b)
			if type(r.zones) ~= "table" then r.zones = {} end
			if type(r.online) ~= "number" then r.online = 0 end
			if type(r.played) ~= "number" then r.played, r.playedAt = nil, nil end
			if type(r.playedTime) ~= "number" then r.playedTime = nil end
		end
	end
	for name, mob in pairs(c.mobs) do
		if type(name) ~= "string" or type(mob) ~= "table" then
			c.mobs[name] = nil
		else
			for _, f in ipairs({ "kills", "xp", "rested" }) do
				if type(mob[f]) ~= "number" then mob[f] = 0 end
			end
		end
	end
	for i = #c.quests, 1, -1 do
		local q = c.quests[i]
		if type(q) ~= "table" or type(q.xp) ~= "number" then table.remove(c.quests, i) end
	end
	if type(c.online) ~= "number" then c.online = 0 end
	if c.played ~= nil and (type(c.played) ~= "table" or type(c.played.total) ~= "number") then c.played = nil end
	return c
end

local function CharRecord(key)
	local c = db.chars[key]
	if type(c) ~= "table" then
		c = {}
		db.chars[key] = c
	end
	return Sanitize(c)
end

local function LevelRec(level, partial)
	local r = char.levels[level]
	if type(r) ~= "table" then
		r = { started = time(), partial = partial or nil }
		char.levels[level] = r
	end
	r.b = Fix(r.b)
	if type(r.zones) ~= "table" then r.zones = {} end
	if type(r.online) ~= "number" then r.online = 0 end
	return r
end

local function NewSession()
	char.session = { start = time(), b = NewBucket(), samples = { { t = 0, x = 0 } } }
end

local function Session()
	local s = char.session
	if type(s) ~= "table" then
		NewSession()
		s = char.session
	end
	s.b = Fix(s.b)
	if type(s.samples) ~= "table" or #s.samples == 0 then s.samples = { { t = s.b.time, x = s.b.xp } } end
	if type(s.start) ~= "number" then s.start = time() end
	return s
end

local function PruneDays()
	local keys = {}
	for k in pairs(char.days) do keys[#keys + 1] = tostring(k) end
	if #keys <= DAY_LIMIT then return end
	table.sort(keys, function(a, b) return a > b end)
	for i = DAY_LIMIT + 1, #keys do char.days[keys[i]] = nil end
end

local function DayBucket()
	local key = date("%Y-%m-%d")
	local b = char.days[key]
	if type(b) ~= "table" then
		b = NewBucket()
		char.days[key] = b
		PruneDays()
	end
	return b
end

local function Zone()
	local zone = Clean(GetRealZoneText and GetRealZoneText())
	if type(zone) ~= "string" or zone == "" then zone = Clean(GetZoneText and GetZoneText()) end
	if type(zone) ~= "string" or zone == "" then return "알 수 없는 지역" end
	return zone
end

local function ZoneBucket(zone)
	local b = char.zones[zone]
	if type(b) ~= "table" then
		b = NewBucket()
		char.zones[zone] = b
	end
	return b
end

local function PruneMobs()
	local list = {}
	for name, mob in pairs(char.mobs) do list[#list + 1] = { name, type(mob) == "table" and tonumber(mob.seen) or 0 } end
	if #list <= MOB_LIMIT then return end
	table.sort(list, function(a, b) return a[2] < b[2] end)
	for i = 1, #list - MOB_LIMIT do char.mobs[list[i][1]] = nil end
end

---------------------------------------------------------------------------
-- 경험치 자리
---------------------------------------------------------------------------
local function ReadXP()
	local level, xp, max = Clean(UnitLevel("player")), Clean(UnitXP("player")), Clean(UnitXPMax("player"))
	if type(level) ~= "number" or type(xp) ~= "number" or type(max) ~= "number" then return nil end
	local rested = Clean(GetXPExhaustion and GetXPExhaustion())
	return level, xp, max, type(rested) == "number" and rested or 0
end

local function CanGainXP(level, max)
	if not (db and db.enabled) or type(max) ~= "number" or max <= 0 then return false end
	if IsXPUserDisabled and Clean(IsXPUserDisabled()) then return false end
	local cap = GetMaxPlayerLevel and Clean(GetMaxPlayerLevel())
	return not (type(cap) == "number" and cap > 0 and level >= cap)
end

-- /played로 받은 이 레벨 플레이 시간 + 그 뒤 접속해 있던 시간
local function PlayedFor(rec)
	if type(rec.played) ~= "number" then return nil end
	return rec.played + math.max(0, rec.online - (tonumber(rec.playedAt) or 0))
end
M.PlayedFor = PlayedFor

function M.PlayedTotal(c)
	local p = type(c) == "table" and c.played
	if type(p) ~= "table" or type(p.total) ~= "number" then return nil end
	return p.total + math.max(0, (c.online or 0) - (tonumber(p.at) or 0))
end

---------------------------------------------------------------------------
-- 문구 읽기
---------------------------------------------------------------------------
-- "|1이;가;"(조사 고르기)는 클라이언트가 한쪽으로 바꿔 보내니 경우마다 패턴을 따로 만든다
local function Variants(fmt)
	local s, e, a, b = fmt:find("|1([^;]*);([^;]*);")
	if not s then return { fmt } end
	local out = {}
	for _, pick in ipairs({ a, b }) do
		for _, rest in ipairs(Variants(fmt:sub(1, s - 1) .. pick .. fmt:sub(e + 1))) do out[#out + 1] = rest end
	end
	return out
end

-- 서식 문자열 → Lua 패턴. args[n] = n번째 서식 인자가 몇 번째 캡처인지 (%2$d 같은 자리 번호 지원)
local function ToPattern(fmt)
	local out, args, i, seq, capture = { "^" }, {}, 1, 0, 0
	while i <= #fmt do
		local c = fmt:sub(i, i)
		if c == "%" then
			local num, kind, stop = fmt:match("^%%(%d+)%$([sd])()", i)
			if not kind then kind, stop = fmt:match("^%%([sd])()", i) end
			if kind then
				seq, capture = seq + 1, capture + 1
				args[num and tonumber(num) or seq] = capture
				out[#out + 1] = kind == "d" and "(%d+)" or "(.-)"
				i = stop
			else
				out[#out + 1] = "%%"
				i = i + (fmt:sub(i + 1, i + 1) == "%" and 2 or 1)
			end
		else
			out[#out + 1] = c:find("[%^%$%(%)%.%[%]%*%+%-%?]") and ("%" .. c) or c
			i = i + 1
		end
	end
	out[#out + 1] = "$"
	return table.concat(out), args
end

local function Compile(names, fields)
	local list = {}
	for _, name in ipairs(names) do
		local fmt = rawget(_G, name)
		if type(fmt) == "string" and fmt ~= "" then
			for _, variant in ipairs(Variants(fmt)) do
				local pattern, args = ToPattern(variant)
				local entry = { pattern = pattern }
				for field, argIndex in pairs(fields) do entry[field] = args[argIndex] end
				list[#list + 1] = entry
			end
		end
	end
	return list
end

local function BuildPatterns()
	local kill = {}
	for _, base in ipairs({ "FIRSTPERSON", "EXHAUSTION1", "EXHAUSTION2", "EXHAUSTION4", "EXHAUSTION5" }) do
		for _, suffix in ipairs({ "", "_GROUP", "_RAID" }) do kill[#kill + 1] = "COMBATLOG_XPGAIN_" .. base .. suffix end
	end
	killPatterns = Compile(kill, { mob = 1, amount = 2 })
	systemPatterns = {}
	for _, p in ipairs(Compile({ "ERR_ZONE_EXPLORED_XP" }, { place = 1, amount = 2 })) do
		p.src = "explore"
		systemPatterns[#systemPatterns + 1] = p
	end
	for _, p in ipairs(Compile({ "ERR_QUEST_REWARD_EXP_I" }, { amount = 1 })) do
		p.src = "quest"
		systemPatterns[#systemPatterns + 1] = p
	end
end

local function Match(list, text)
	for _, p in ipairs(list) do
		local caps = { text:match(p.pattern) }
		if caps[1] ~= nil then return p, caps end
	end
end

---------------------------------------------------------------------------
-- 단서 → 나누기
---------------------------------------------------------------------------
local function Touch()
	dirtyAt = GetTime()
end

local function AddClaim(claim)
	claim.at = GetTime()
	claim.zone = Zone()
	claims[#claims + 1] = claim
	Touch()
end

local function Duplicate(key)
	local now = GetTime()
	if seen[key] and now - seen[key] < DEDUPE then return true end
	seen[key] = now
	return false
end

local function AddTo(b, src, amount, first, rested)
	b.xp = b.xp + amount
	b[src] = b[src] + amount
	if rested and rested > 0 then b.rested = b.rested + rested end
	if first then
		if src == "kill" then b.kills = b.kills + 1 elseif src == "quest" then b.quests = b.quests + 1 end
	end
end

local function Record(src, parts, claim, rested)
	local total = 0
	for _, part in ipairs(parts) do total = total + part[2] end
	if total <= 0 then return end
	local zone = claim and claim.zone or Zone()
	for _, b in ipairs({ Session().b, DayBucket(), char.total, ZoneBucket(zone) }) do AddTo(b, src, total, true, rested) end
	for i, part in ipairs(parts) do
		local rec = LevelRec(part[1])
		AddTo(rec.b, src, part[2], i == 1, rested * part[2] / total)
		rec.zones[zone] = (rec.zones[zone] or 0) + part[2]
	end
	if src == "kill" and claim and claim.mob then
		local mob = char.mobs[claim.mob]
		if type(mob) ~= "table" then
			mob = { kills = 0, xp = 0, rested = 0 }
			char.mobs[claim.mob] = mob
			PruneMobs()
		end
		mob.kills = (tonumber(mob.kills) or 0) + 1
		mob.xp = (tonumber(mob.xp) or 0) + total
		mob.rested = (tonumber(mob.rested) or 0) + rested
		mob.seen, mob.level = time(), parts[1][1]
	elseif src == "quest" and claim then
		table.insert(char.quests, 1, {
			id = claim.questID, title = claim.title, xp = total, level = parts[1][1], zone = zone, at = time(),
		})
		for i = #char.quests, QUEST_LIMIT + 1, -1 do char.quests[i] = nil end
	end
end

local function AddSample(s, force)
	local list = s.samples
	local lastSample = list[#list]
	if force or s.b.time - lastSample.t >= SAMPLE_EVERY then
		list[#list + 1] = { t = s.b.time, x = s.b.xp }
	end
	while #list > 2 and list[2].t < s.b.time - SAMPLE_KEEP do table.remove(list, 1) end
end

-- 경험치 증가분을 레벨 조각 순서대로 단서에 나눠 준다. 정확한 양(퀘스트·탐험·처치) 먼저, 모르는 양은 남은 걸 나눈다.
local function Allocate(segments, gained, restedUsed)
	local seg, segLeft = 1, segments[1].amount
	local function Take(amount)
		local parts = {}
		while amount > 0 and seg <= #segments do
			local take = math.min(amount, segLeft)
			if take > 0 then parts[#parts + 1] = { segments[seg].level, take } end
			amount, segLeft = amount - take, segLeft - take
			if segLeft <= 0 then
				seg = seg + 1
				segLeft = segments[seg] and segments[seg].amount or 0
			end
		end
		return parts
	end

	local exact, unknown = {}, {}
	for i, c in ipairs(claims) do
		c.order = i
		if c.amount then exact[#exact + 1] = c else unknown[#unknown + 1] = c end
	end
	table.sort(exact, function(a, b)
		if PRIORITY[a.src] ~= PRIORITY[b.src] then return PRIORITY[a.src] < PRIORITY[b.src] end
		return a.order < b.order
	end)
	table.sort(unknown, function(a, b)
		if PRIORITY[a.src] ~= PRIORITY[b.src] then return PRIORITY[a.src] < PRIORITY[b.src] end
		return a.order < b.order
	end)

	local remaining = gained
	local done = {}
	for _, c in ipairs(exact) do
		local want = math.min(c.amount, remaining)
		c.parts = Take(want)
		remaining = remaining - want
		done[#done + 1] = c
	end
	for i, c in ipairs(unknown) do
		local want = math.floor(remaining / (#unknown - i + 1) + 0.5)
		c.parts = Take(want)
		remaining = remaining - want
		done[#done + 1] = c
	end

	local killXP = 0
	for _, c in ipairs(done) do
		c.got = 0
		for _, part in ipairs(c.parts) do c.got = c.got + part[2] end
		if c.src == "kill" then killXP = killXP + c.got end
	end
	local restedTotal = math.min(restedUsed, killXP)
	for _, c in ipairs(done) do
		local share = (c.src == "kill" and killXP > 0) and restedTotal * c.got / killXP or 0
		Record(c.src, c.parts, c, share)
	end
	if remaining > 0 then Record("other", Take(remaining), nil, 0) end
end

local function Settle()
	dirtyAt = nil
	if not (char and last) then return end
	local level, xp, max, rested = ReadXP()
	if not level then return end
	local segments, gained = {}, 0
	if level > last.level then
		-- 레벨업: 남은 칸 + 새 레벨에서 쌓인 만큼. 한 번에 두 레벨 이상 넘으면 중간 레벨 크기는 모르니 뺀다
		local rest = math.max(0, last.max - last.xp)
		if rest > 0 then segments[#segments + 1] = { level = last.level, amount = rest } end
		if xp > 0 then segments[#segments + 1] = { level = level, amount = xp } end
		for lv = last.level, level - 1 do
			local rec = char.levels[lv]
			if type(rec) == "table" and not rec.done then
				rec.done = time()
				rec.playedTime = PlayedFor(LevelRec(lv))
			end
		end
		LevelRec(level)
	elseif level == last.level and xp > last.xp then
		segments[1] = { level = level, amount = xp - last.xp }
	end
	for _, s in ipairs(segments) do gained = gained + s.amount end
	local restedUsed = math.max(0, last.rested - rested)
	if carryRested > 0 and GetTime() - carryAt <= CLAIM_TTL then restedUsed = restedUsed + carryRested end
	carryRested = 0
	if gained == 0 and restedUsed > 0 then carryRested, carryAt = restedUsed, GetTime() end
	last = { level = level, xp = xp, max = max, rested = rested }
	char.level, char.xp, char.xpMax, char.seen = level, xp, max, time()
	active = CanGainXP(level, max)
	if gained > 0 then
		Allocate(segments, gained, restedUsed)
		AddSample(Session(), true)
		wipe(claims)
	end
	M.RefreshInfoText()
	ns:Fire("XPSTATS_UPDATED", gained > 0)
end

---------------------------------------------------------------------------
-- 시간
---------------------------------------------------------------------------
local function AddTime(sec)
	if not (char and last) then return end
	char.online = char.online + sec
	if not active then return end
	local rec = LevelRec(last.level)
	rec.online = rec.online + sec
	if db.excludeAFK and Clean(UnitIsAFK("player")) then return end
	local s = Session()
	for _, b in ipairs({ s.b, DayBucket(), char.total, rec.b, ZoneBucket(Zone()) }) do b.time = b.time + sec end
	AddSample(s)
end

local driver = CreateFrame("Frame")
driver:Hide()
local tickAcc = 0
driver:SetScript("OnUpdate", function(_, elapsed)
	if dirtyAt and GetTime() - dirtyAt >= SETTLE then Settle() end
	if #claims > 0 and not dirtyAt and GetTime() - claims[#claims].at > CLAIM_TTL then wipe(claims) end
	tickAcc = tickAcc + elapsed
	if tickAcc >= 1 then
		AddTime(tickAcc)
		tickAcc = 0
		M.RefreshInfoText()
		ns:Fire("XPSTATS_UPDATED", false)
	end
end)

---------------------------------------------------------------------------
-- 보여 줄 숫자
---------------------------------------------------------------------------
local function Average(b, src, countKey)
	if b and b[countKey] >= 3 then return b[src] / b[countKey] end
end

function M.GetChar() return char end
function M.IsActive() return active end
function M.Chars() return db and db.chars or {} end
function M.CurrentKey() return started and PlayerKey() or nil end

-- 패널·툴팁·창이 같이 쓰는 지금 상태. 기록 전이면 nil.
function M.Stats()
	if not (char and last) then return nil end
	local s = Session()
	local rec = LevelRec(last.level)
	local st = {
		active = active, level = last.level, xp = last.xp, max = last.max, rested = last.rested,
		remaining = math.max(0, last.max - last.xp), session = s.b, sessionStart = s.start,
		today = DayBucket(), levelRec = rec, total = char.total,
	}
	st.pct = M.Percent(last.xp, last.max)
	if s.b.time >= MIN_RATE_TIME then st.rateSession = s.b.xp / s.b.time * 3600 end
	local window = (tonumber(db.recentMinutes) or 10) * 60
	local base = s.samples[1]
	for _, sample in ipairs(s.samples) do
		if sample.t <= s.b.time - window then base = sample else break end
	end
	local span = s.b.time - base.t
	if span >= MIN_RATE_TIME then st.rateRecent = (s.b.xp - base.x) / span * 3600 end
	st.recentMinutes = window / 60
	st.rate = st.rateRecent or st.rateSession
	if st.rate and st.rate > 0 then st.eta = st.remaining / st.rate * 3600 end
	local killAvg = Average(rec.b, "kill", "kills") or Average(s.b, "kill", "kills") or Average(char.total, "kill", "kills")
	if killAvg and killAvg > 0 then st.killAvg, st.killsToLevel = killAvg, math.ceil(st.remaining / killAvg) end
	local questSum, questCount = 0, 0
	for _, q in ipairs(char.quests) do
		if questCount >= 10 then break end
		if type(q) == "table" and type(q.xp) == "number" and (tonumber(q.level) or 0) >= last.level - 1 then
			questSum, questCount = questSum + q.xp, questCount + 1
		end
	end
	if questCount >= 2 then st.questAvg = questSum / questCount end
	if st.questAvg and st.questAvg > 0 then st.questsToLevel = math.ceil(st.remaining / st.questAvg) end
	return st
end

function M.RefreshInfoText()
	infoText = nil
	if not (db and db.enabled and db.showInfoBar and active) then return end
	local st = M.Stats()
	if not st then return end
	if st.rate then
		infoText = ("|cffb48cff경험치|r %s/시"):format(M.Comma(st.rate))
	else
		infoText = "|cffb48cff경험치|r |cff808080측정 중|r"
	end
end

function M.InfoText() return infoText end

-- 정보 막대·패널 툴팁 공용
function M.FillTooltip(tooltip)
	local st = M.Stats()
	tooltip:SetText("경험치 통계", 1, 0.82, 0)
	if not st then
		tooltip:AddLine("아직 기록이 없습니다.", 0.7, 0.7, 0.7)
		return
	end
	if not st.active then
		tooltip:AddLine("경험치를 더 얻을 수 없는 상태라 기록을 멈췄습니다.", 0.7, 0.7, 0.7)
	else
		tooltip:AddDoubleLine(("%d레벨 %.1f%%"):format(st.level, st.pct), ("남은 경험치 %s"):format(M.Comma(st.remaining)), 1, 1, 1, 1, 1, 1)
		if st.rested > 0 then tooltip:AddLine(("휴식 경험치 %s"):format(M.Comma(st.rested)), 0.4, 0.6, 1) end
		tooltip:AddDoubleLine("시간당 (이번 접속)", st.rateSession and M.Comma(st.rateSession) or "측정 중", 0.8, 0.8, 0.8, 1, 1, 1)
		tooltip:AddDoubleLine(("시간당 (최근 %d분)"):format(st.recentMinutes), st.rateRecent and M.Comma(st.rateRecent) or "측정 중", 0.8, 0.8, 0.8, 1, 1, 1)
		if st.eta then
			local more = {}
			if st.killsToLevel then more[#more + 1] = ("몹 %s마리"):format(M.Comma(st.killsToLevel)) end
			if st.questsToLevel then more[#more + 1] = ("퀘스트 %s개"):format(M.Comma(st.questsToLevel)) end
			tooltip:AddDoubleLine("레벨업까지", M.Duration(st.eta) .. (#more > 0 and (" (" .. table.concat(more, " · ") .. ")") or ""), 0.8, 0.8, 0.8, 1, 1, 1)
		end
	end
	tooltip:AddLine(" ")
	tooltip:AddDoubleLine("이번 접속", ("+%s · %s"):format(M.Comma(st.session.xp), M.Duration(st.session.time)), 1, 0.82, 0, 1, 1, 1)
	for _, src in ipairs(M.SOURCES) do
		local amount = st.session[src]
		if amount > 0 then
			local c = M.COLORS[src]
			local extra = src == "kill" and (" · %s마리"):format(M.Comma(st.session.kills))
				or src == "quest" and (" · %s개"):format(M.Comma(st.session.quests)) or ""
			tooltip:AddDoubleLine("  " .. M.LABELS[src], ("%s (%.0f%%)%s"):format(M.Comma(amount), M.Percent(amount, st.session.xp), extra),
				c[1], c[2], c[3], 1, 1, 1)
		end
	end
	tooltip:AddDoubleLine("오늘", "+" .. M.Comma(st.today.xp), 1, 0.82, 0, 1, 1, 1)
	tooltip:AddLine(" ")
	tooltip:AddLine("클릭: 상세 통계 창", 0.6, 0.6, 0.6)
end

---------------------------------------------------------------------------
-- 시작 / 이벤트
---------------------------------------------------------------------------
local function Start(isInitialLogin)
	local key = PlayerKey()
	char = CharRecord(key)
	char.name = PlayerName()
	local _, class = UnitClass("player")
	char.class = Clean(class)
	local level, xp, max, rested = ReadXP()
	if not level then
		char, last = nil, nil
		return
	end
	started = true
	if isInitialLogin or type(char.session) ~= "table" then NewSession() end
	Session()
	-- 이 애드온 없이 레벨이 오른 동안은 기록이 끊겼다고 적어 둔다
	for lv, rec in pairs(char.levels) do
		if type(lv) == "number" and lv < level and type(rec) == "table" and not rec.done then
			rec.done, rec.broken = tonumber(char.seen) or time(), true
		end
	end
	if type(char.levels[level]) ~= "table" then LevelRec(level, true) end
	char.level, char.xp, char.xpMax, char.seen = level, xp, max, time()
	last = { level = level, xp = xp, max = max, rested = rested }
	active = CanGainXP(level, max)
	wipe(claims)
	M.RefreshInfoText()
	ns:Fire("XPSTATS_UPDATED", true)
end

local function Enabled()
	return db and db.enabled and started
end

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function(_, isInitialLogin)
	if not (db and db.enabled) then return end
	if not started then
		Start(isInitialLogin)
		if started and isInitialLogin and db.autoPlayed and RequestTimePlayed then
			C_Timer.After(5, function() RequestTimePlayed() end)
		end
	else
		Touch()
	end
end)

ns:RegisterUnitEvent("PLAYER_XP_UPDATE", function()
	if Enabled() then Touch() end
end, "player")

ns:RegisterEvent("PLAYER_LEVEL_UP", function()
	if Enabled() then Touch() end
end)

ns:RegisterEvent("UPDATE_EXHAUSTION", function()
	if Enabled() then Touch() end
end)

ns:RegisterEvent("QUEST_TURNED_IN", function(_, questID, xpReward)
	if not Enabled() then return end
	questID, xpReward = Clean(questID), Clean(xpReward)
	local title = type(questID) == "number" and C_QuestLog and C_QuestLog.GetTitleForQuestID and Clean(C_QuestLog.GetTitleForQuestID(questID))
	AddClaim({
		src = "quest", questID = questID, title = type(title) == "string" and title or nil,
		amount = (type(xpReward) == "number" and xpReward > 0) and xpReward or nil,
	})
end)

ns:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN", function(_, text)
	if not Enabled() then return end
	if not killPatterns then BuildPatterns() end
	if ns.Clean(text) == nil then
		AddClaim({ src = "kill" })   -- 글자가 비밀이어도 처치였다는 건 안다
		return
	end
	local p, caps = Match(killPatterns, text)
	if not p then return end   -- 이름 없는 경험치 문구는 기타로 둔다
	AddClaim({ src = "kill", mob = p.mob and caps[p.mob] or nil, amount = tonumber(p.amount and caps[p.amount]) })
end)

local function OnSystemText(text)
	if not Enabled() or type(Clean(text)) ~= "string" then return end
	if not systemPatterns then BuildPatterns() end
	local p, caps = Match(systemPatterns, text)
	if not p or Duplicate(p.src .. ":" .. text) then return end
	local amount = tonumber(p.amount and caps[p.amount])
	if p.src == "quest" then
		-- 퀘스트 완료 이벤트가 이미 양을 줬으면 그쪽을 믿고, 양을 못 줬으면 채워 준다
		for _, c in ipairs(claims) do
			if c.src == "quest" then
				c.amount = c.amount or amount
				Touch()
				return
			end
		end
	end
	AddClaim({ src = p.src, amount = amount, place = p.place and caps[p.place] or nil })
end

ns:RegisterEvent("CHAT_MSG_SYSTEM", function(_, text) OnSystemText(text) end)
ns:RegisterEvent("UI_INFO_MESSAGE", function(_, _, text) OnSystemText(text) end)

ns:RegisterEvent("TIME_PLAYED_MSG", function(_, total, levelTime)
	if not (Enabled() and char and last) then return end
	total, levelTime = Clean(total), Clean(levelTime)
	if type(total) == "number" then char.played = { total = total, at = char.online } end
	if type(levelTime) == "number" then
		local rec = LevelRec(last.level)
		rec.played, rec.playedAt = levelTime, rec.online
	end
	ns:Fire("XPSTATS_UPDATED", true)
end)

ns:RegisterEvent("PLAYER_LOGOUT", function()
	if Enabled() and dirtyAt then Settle() end
end)

---------------------------------------------------------------------------
-- 정리
---------------------------------------------------------------------------
function M.ResetSession()
	if not char then return end
	NewSession()
	M.RefreshInfoText()
	ns:Fire("XPSTATS_UPDATED", true)
	Print("이번 접속 경험치 통계를 새로 시작했습니다.")
end

function M.ResetCharacter()
	if not (db and started) then return end
	db.chars[PlayerKey()] = nil
	char, last, started = nil, nil, false
	Start(true)
	Print("이 캐릭터의 경험치 기록을 모두 지웠습니다.")
end

StaticPopupDialogs["EZYWOWF_XPSTATS_RESET"] = {
	text = "이 캐릭터의 경험치 기록(레벨별·지역·몹·퀘스트·날짜별)을 모두 지울까요?\n되돌릴 수 없습니다.",
	button1 = YES or "예", button2 = NO or "아니요",
	OnAccept = function() M.ResetCharacter() end,
	timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- 끄면 기준점을 버린다. 꺼져 있던 동안 오른 경험치를 켤 때 '기타'로 세면 안 되니 다시 켜면 새로 잡는다.
local function ApplyRunning()
	driver:SetShown(db.enabled and true or false)
	if db.enabled then
		if not started and IsLoggedIn and IsLoggedIn() then Start(true) end
		active = last ~= nil and CanGainXP(last.level, last.max)
	else
		if started and dirtyAt then Settle() end
		started, char, last, active, dirtyAt = false, nil, nil, false, nil
		wipe(claims)
	end
	M.RefreshInfoText()
	ns:Fire("XPSTATS_UPDATED", true)
end

local function Validate()
	for _, key in ipairs({ "enabled", "showPanel", "showInfoBar", "excludeAFK", "autoPlayed" }) do
		if type(db[key]) ~= "boolean" then db[key] = M.defaults[key] end
	end
	for _, key in ipairs({ "recentMinutes", "scale", "x", "y", "winX", "winY" }) do
		local v = db[key]
		if type(v) ~= "number" or v ~= v or math.abs(v) == math.huge then db[key] = M.defaults[key] end
	end
	for _, key in ipairs({ "point", "relPoint", "winPoint", "winRelPoint" }) do
		if not POINTS[db[key]] then db[key] = M.defaults[key] end
	end
	db.recentMinutes = math.max(5, math.min(30, math.floor(db.recentMinutes + 0.5)))
	db.scale = math.max(0.6, math.min(2, db.scale))
	if type(db.chars) ~= "table" then db.chars = {} end
	for key, c in pairs(db.chars) do
		if type(c) == "table" then Sanitize(c) else db.chars[key] = nil end
	end
end

function M:OnInitialize()
	db = self.db
	Validate()
	driver:SetShown(db.enabled)
	if M.InitUI then M.InitUI(db) end
end

function M:ApplySettings()
	Validate()
	ApplyRunning()
	if M.ApplyUI then M.ApplyUI() end
end

if ns.AddInfoBarPart then
	ns.AddInfoBarPart({
		text = M.InfoText,
		tooltip = M.FillTooltip,
		click = function() if M.ToggleWindow then M.ToggleWindow() end end,
	})
end

function EzyWOWF_ToggleXPStats()
	if M.ToggleWindow then M.ToggleWindow() end
end

SLASH_EZYWOWFXPSTATS1 = "/경험치"
SLASH_EZYWOWFXPSTATS2 = "/xpstats"
SlashCmdList.EZYWOWFXPSTATS = function()
	if not (db and db.enabled) then
		Print("경험치 통계가 꺼져 있어요. /이지 > 화면 정보 > 경험치 통계에서 켜세요.")
		return
	end
	EzyWOWF_ToggleXPStats()
end

-- 테스트·창에서 쓰는 안쪽 손잡이
M._Settle, M._BuildPatterns = Settle, BuildPatterns
M._ToPattern, M._Variants = ToPattern, Variants

function M:BuildOptions(b)
	local function Off() return not db.enabled end
	b:Text("캐릭터마다 얻은 경험치를 몹 처치·퀘스트·탐험·기타로 나눠 이번 접속·오늘·레벨별·누적으로 셉니다. "
		.. "시간당 경험치, 레벨업까지 남은 시간과 몹·퀘스트 수, 레벨마다 걸린 시간, 지역·몹·퀘스트별 경험치, "
		.. "같은 계정 캐릭터 비교를 보여 줍니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Buttons{
		{ text = "상세 통계 창", textFunc = function() return (M.IsWindowShown and M.IsWindowShown()) and "창 닫기" or "상세 통계 창" end,
			onClick = function() EzyWOWF_ToggleXPStats() end, disabled = Off },
	}
	b:KeyBind{ command = BINDING, label = "상세 통계 창 열기/닫기" }

	b:Header("화면 표시")
	b:Check{ key = "showPanel", label = "경험치 패널", depends = "enabled",
		tooltip = "시간당 경험치·레벨업 예상·이번 접속 출처 비율을 작은 패널로 띄웁니다. 클릭하면 상세 통계 창이 열립니다. 만렙이면 숨깁니다." }
	b:Slider{ key = "scale", label = "패널 크기", min = 0.6, max = 2, step = 0.05, format = "%.2f", depends = { "enabled", "showPanel" } }
	b:Buttons{
		{ text = "위치 이동", textFunc = function() return (M.IsMoving and M.IsMoving()) and "이동 완료" or "위치 이동" end,
			onClick = function() if M.ToggleMove then M.ToggleMove() end end,
			disabled = function() return Off() or not db.showPanel end },
		{ text = "기본 위치로", onClick = function() if M.ResetPosition then M.ResetPosition() end end,
			disabled = function() return Off() or not db.showPanel end },
	}
	b:Check{ key = "showInfoBar", label = "정보 막대에 시간당 경험치", depends = "enabled",
		tooltip = "미니맵 밑 정보 막대 끝에 시간당 경험치를 붙입니다. 마우스를 올리면 요약, 클릭하면 상세 통계 창입니다. 정보 막대가 켜져 있어야 보입니다." }

	b:Header("기록")
	b:Check{ key = "excludeAFK", label = "자리 비움 시간은 빼기", depends = "enabled",
		tooltip = "자리 비움(AFK) 상태인 동안은 시간을 세지 않아 시간당 경험치가 덜 깎입니다. 자리 비움은 몇 분 가만히 있어야 켜지니 그 몇 분은 들어갑니다." }
	b:Slider{ key = "recentMinutes", label = "최근 속도 기준(분)", min = 5, max = 30, step = 5, format = "%d", depends = "enabled" }
	b:Check{ key = "autoPlayed", label = "접속할 때 플레이 시간 받아 오기", depends = "enabled",
		tooltip = "접속 5초 뒤 /played를 대신 요청해 레벨별 실제 플레이 시간을 맞춥니다. 채팅창에 플레이 시간 메시지가 한 번 찍힙니다. 꺼 두면 직접 /played를 입력했을 때만 받습니다." }
	b:Buttons{
		{ text = "이번 접속 새로 시작", onClick = function() M.ResetSession() end, disabled = Off },
		{ text = "이 캐릭터 기록 지우기", onClick = function() StaticPopup_Show("EZYWOWF_XPSTATS_RESET") end, disabled = Off },
	}
	b:Text("- 설치한 뒤부터 셉니다. 그 전에 시작한 레벨은 '설치 후부터'로 표시합니다.\n"
		.. "- 휴식 보너스는 휴식 경험치가 줄어든 만큼으로 셉니다. 몹 처치 경험치에 포함됩니다.\n"
		.. "- 다른 와우 계정 캐릭터는 저장 파일이 따로라 비교에 안 나옵니다.\n"
		.. "- 명령어: /경험치 (또는 /xpstats) - 상세 통계 창 열기/닫기",
		{ color = { 0.7, 0.7, 0.7 } })
end
