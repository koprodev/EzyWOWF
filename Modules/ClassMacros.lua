-- 직업 매크로: 직업마다 쓸 만한 매크로를 골라 캐릭터 전용 매크로로 만든다.
--
-- 주문 이름은 게임에서 받아 넣는다. 한국어판은 띄어쓰기까지 맞아야 /cast가 먹히고(먹이주기·야수 소환해제처럼 붙여 쓰는 이름도 있다),
-- 이름에는 등급이 안 붙으니 새 등급을 배워도 매크로는 알아서 최고 등급을 쓴다.
-- 이름이 바뀌며 올라가는 주문(곰 변신 → 광포한 곰 변신, 하급 치유 → 치유)만 만들 때 배운 쪽 이름을 넣는다(Best).
-- 그걸 배우면 상태 줄이 "내용이 달라요"로 바뀌어 다시 만들라고 알려 준다.
-- 태세·변신을 바꾸는 줄 다음 줄은 같은 누름에서 바뀐 상태를 못 본다는 포에버 제보가 있어, 태세·변신 매크로는 두 번 누르게 짠다.
-- /castsequence는 안 쓴다. 블리자드 CastSequenceManager가 주문 번호를 접속 내내 기억했다가 그 번호로 다음 칸을 넘겨서,
-- 새 등급을 배우면 /reload 전까지 첫 칸에서 맴돌 수 있다.
-- @ 없는 [dead]·[harm]은 내 대상(target)을 본다. 펫 상태를 보려면 꼭 @pet을 붙인다.
-- 길이는 255바이트까지만. 매크로 창은 255"글자"를 받지만 저장 한도가 바이트라는 보고도 있어서, 한글(3바이트)이 많으면 위험하다.
-- 같은 이름의 캐릭터 전용 매크로가 있으면 내용만 고친다. 이름이 같은 계정 공용 매크로는 안 건드린다.

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print
local UI = ns.UI

local MACRO_ICON  = "INV_MISC_QUESTIONMARK"   -- 물음표 = #showtooltip 주문 그림을 따라간다
local BODY_LIMIT  = 255                       -- 바이트. 글자 수 한도(letters="255")보다 빡빡하게 잡았다
local FEED_BUTTON = "EzyWOWFPetFeedButton"    -- 펫 먹이 모듈의 먹이 버튼
local MUTED       = { 0.6, 0.6, 0.6 }

-- 게임에서 이름을 못 받을 때만 쓴다. 포에버 1.60.1 koKR 주문 이름 그대로.
local FALLBACK_NAMES = {
	-- 사냥꾼
	[75] = "자동 사격", [136] = "동물 치료", [883] = "야수 부르기", [982] = "야수 되살리기", [2641] = "야수 소환해제",
	[1002] = "야수의 눈", [1130] = "사냥꾼의 징표", [1978] = "독사 쐐기", [2973] = "랩터의 일격", [2974] = "날개 절단",
	[3044] = "신비한 사격", [5118] = "치타의 상", [13163] = "원숭이의 상", [13165] = "매의 상",
	[1499] = "얼음의 덫", [13795] = "제물의 덫", [13809] = "냉기의 덫", [13813] = "폭발의 덫",
	-- 전사
	[71] = "방어 태세", [72] = "방패 가격", [78] = "영웅의 일격", [100] = "돌진", [355] = "도발", [845] = "회전베기",
	[1160] = "사기의 외침", [2457] = "전투 태세", [2458] = "광폭 태세", [6552] = "자루 공격", [6673] = "전투의 외침",
	[7384] = "제압", [20252] = "봉쇄",
	-- 도적
	[1752] = "사악한 일격", [1766] = "발차기", [1784] = "은신", [1833] = "비열한 습격", [1856] = "소멸", [2094] = "실명",
	[2098] = "절개", [2983] = "전력 질주", [5171] = "난도질", [5277] = "회피", [6770] = "기절시키기", [703] = "목조르기",
	[8676] = "매복",
	-- 드루이드
	[339] = "휘감는 뿌리", [467] = "가시", [768] = "표범 변신", [774] = "회복", [783] = "치타 변신", [1066] = "바다표범 변신",
	[1082] = "할퀴기", [1126] = "야생의 징표", [2637] = "겨울잠", [5176] = "천벌", [5185] = "치유의 손길", [5215] = "숨기",
	[5487] = "곰 변신", [6795] = "포효", [6807] = "후려치기", [9634] = "광포한 곰 변신",
	[8946] = "해독", [2893] = "독 해제", [2782] = "저주 해제", [29166] = "정신 자극", [20484] = "환생",
	[22812] = "나무 껍질", [1850] = "질주",
	-- 마법사
	[118] = "변이", [168] = "냉기 갑옷", [587] = "음식 창조", [1459] = "신비한 지능", [1463] = "마나 보호막",
	[2139] = "마법 차단", [5504] = "음료 창조", [6117] = "마법사 갑옷", [7302] = "얼음 갑옷",
	-- 사제
	[17] = "신의 권능: 보호막", [139] = "소생", [527] = "마법 무효화", [528] = "질병 치료", [589] = "어둠의 권능: 고통",
	[1243] = "신의 권능: 인내", [2050] = "하급 치유", [2054] = "치유", [2061] = "순간 치유", [8092] = "정신 분열",
	-- 흑마법사
	[172] = "부패", [348] = "제물", [686] = "어둠의 화살", [689] = "생명력 흡수", [710] = "추방", [980] = "고통의 파멸",
	[1454] = "생명력 전환", [5782] = "공포", [19244] = "주문 잠금",
	-- 성기사
	[498] = "신의 가호", [635] = "성스러운 빛", [642] = "천상의 보호막", [679] = "신성한 일격", [853] = "심판의 망치",
	[1022] = "보호의 축복", [1152] = "순화", [4987] = "정화", [19740] = "힘의 축복", [19742] = "지혜의 축복",
	[19750] = "빛의 섬광", [20154] = "정의의 문장", [20217] = "왕의 축복", [20271] = "심판", [21082] = "성전사의 문장",
	-- 주술사
	[331] = "치유의 물결", [370] = "정화", [403] = "번개 화살", [526] = "해독", [8004] = "하급 치유의 물결",
	[8017] = "대지의 무기", [8024] = "불꽃의 무기", [8033] = "냉기의 무기", [8042] = "대지 충격", [8050] = "화염 충격",
	[8232] = "질풍의 무기", [36936] = "토템의 귀환", [66842] = "원소의 부름", [66843] = "선조의 부름", [66844] = "영혼의 부름",
}

-- 아이템 이름 (포에버 koKR, 생명석은 등급마다 이름이 다르고 특성으로 바뀐 것도 이름은 같다)
local HEALTHSTONES = { "최상급 생명석", "상급 생명석", "중급 생명석", "하급 생명석", "최하급 생명석" }

local function N(id)
	local name = C_Spell and C_Spell.GetSpellName and Clean(C_Spell.GetSpellName(id))
	return name or FALLBACK_NAMES[id]
end

local function Lines(...)
	return table.concat({ ... }, "\n")
end

-- 배운 것 중 앞쪽(높은 단계) 주문 번호. 하나도 못 배웠으면 마지막(첫 단계)을 쓴다.
local function Best(...)
	local count = select("#", ...)
	for i = 1, count do
		local id = select(i, ...)
		if ns.KnownSpellRank(id) then return id end
	end
	return (select(count, ...))
end

-- 조건 묶음. mod를 주면 그 조합키를 누를 때만.
--   Help: 마우스 올린 아군 → 대상 아군 → 나 / Harm: 마우스 올린 적 → 대상 적
local function Help(mod)
	local m = mod and ("mod:" .. mod .. ",") or ""
	return ("[%s@mouseover,help,nodead][%shelp,nodead][%s@player]"):format(m, m, m)
end

local function Harm(mod)
	local m = mod and ("mod:" .. mod .. ",") or ""
	return ("[%s@mouseover,harm,nodead][%sharm,nodead]"):format(m, m)
end

local function FormIndex(id)
	return ns.DruidForms and ns.DruidForms.GetIndex(id)
end

local function BearIndex()
	return FormIndex(9634) or FormIndex(5487)
end

---------------------------------------------------------------------------
-- 매크로 목록 (직업 영문 이름별)
--   key 목록 안 고유 이름, name 게임 매크로 이름(16자 이하), title 고르는 목록 글자, desc 설명 줄들,
--   spells 쓰는 주문(안 배운 것 안내용, 함수도 됨), icon 고정 그림(없으면 물음표), body() 매크로 내용
---------------------------------------------------------------------------
local MACROS = {}

-- 사냥꾼. 펫 대상 공격·징표 키는 사용자가 쓰던 매크로를 다듬은 것.
MACROS.HUNTER = {
	{
		key = "pet", name = "펫 관리", title = "펫 관리 (부르기·되살리기·치료·먹이)",
		spells = { 883, 982, 136, 2641 },
		desc = {
			"그냥: 펫이 죽었으면 되살리기, 없으면 부르기, 있으면 치료",
			"Shift: 먹이 주기(펫 먹이 기능이 고른 음식, 전투 중엔 치료) · Ctrl: 죽은 뒤 사라진 펫 되살리기",
			"Alt: 소환 해제(펫 행복도가 깎여요)",
		},
		body = function()
			return Lines(
				"#showtooltip",
				("/cast [@pet,dead][nopet,mod:ctrl] %s; [nopet] %s; [mod:alt] %s; [nomod:shift][combat] %s")
					:format(N(982), N(883), N(2641), N(136)),
				"/click [mod:shift,nocombat,@pet,exists,nodead] " .. FEED_BUTTON)
		end,
	},
	{
		key = "assist", name = "펫 대상 공격", title = "펫 대상 공격 (독사 쐐기·신비한 사격 + 자동 사격)",
		spells = { 1978, 3044, 75 },
		desc = {
			"펫이 공격 중인 적을 내 대상으로 잡고 독사 쐐기 + 자동 사격. 펫이 놀고 있으면 내 대상에게 보낸다",
			"Shift: 독사 쐐기 대신 신비한 사격 · 공격할 적이 없으면 아무것도 안 함",
		},
		-- 자동 사격을 먼저 건다. 전역 쿨 기술 다음 줄은 안 돈다는 포에버 제보(미확인)가 있어서.
		body = function()
			local shot = ("[mod:shift] %s; %s"):format(N(3044), N(1978))
			return Lines(
				"#showtooltip " .. shot,
				"/target [@pettarget,harm,nodead]",
				"/stopmacro [noharm][dead]",
				"/petattack",
				"/cast !" .. N(75),
				"/cast " .. shot)
		end,
	},
	{
		key = "mark", name = "징표 펫 공격", title = "사냥꾼의 징표 + 펫 공격",
		spells = { 1130 },
		desc = {
			"마우스를 올린 적(없으면 내 대상)에 사냥꾼의 징표를 걸고 펫을 보낸다. 적마다 처음 한 번만 누르면 된다",
			"Shift: 펫 불러들이기(따라오기)",
		},
		body = function()
			return Lines(
				"#showtooltip " .. N(1130),
				"/petfollow [mod:shift]",
				"/stopmacro [mod:shift]",
				"/petattack [@mouseover,harm,nodead][harm,nodead]",
				"/cast [@mouseover,harm,nodead][harm,nodead] " .. N(1130))
		end,
	},
	{
		key = "melee", name = "근접 공격", title = "근접 공격 (랩터의 일격·날개 절단)",
		spells = { 2973, 2974 },
		desc = {
			"근접 자동 공격을 켜고 다음 공격에 랩터의 일격",
			"Shift: 날개 절단(적 이동 속도 감소)",
		},
		body = function()
			return Lines(
				"#showtooltip",
				"/startattack",
				("/cast [mod:shift] %s; %s"):format(N(2974), N(2973)))
		end,
	},
	{
		key = "aspect", name = "상 바꾸기", title = "상 바꾸기 (전투 밖 치타·전투 중 매·원숭이)",
		spells = { 13165, 5118, 13163 },
		desc = {
			"그냥: 전투 밖 치타의 상, 전투 중 매의 상 · Shift: 반대로(전투 밖 매, 전투 중 치타) · Ctrl: 원숭이의 상",
			"안 배운 상은 건너뛰고 매의 상 → 원숭이의 상 순으로 대신 써요",
		},
		-- known은 주문 번호로 묻는다(IsPlayerSpell). 모르는 상을 고르면 /cast가 다음 절로 안 넘어가서 아무것도 안 나간다
		body = function()
			return Lines(
				"#showtooltip",
				("/cast [mod:ctrl] !%s; [combat,mod:shift,known:5118][nocombat,nomod,known:5118] !%s; [known:13165] !%s; !%s")
					:format(N(13163), N(5118), N(13165), N(13163)))
		end,
	},
	{
		key = "trap", name = "덫 놓기", title = "덫 놓기 (얼음·냉기·제물·폭발)",
		spells = { 1499, 13809, 13795, 13813 },
		desc = {
			"그냥: 얼음의 덫 · Shift: 냉기의 덫 · Ctrl: 제물의 덫 · Alt: 폭발의 덫",
			"포에버는 전투 중에도 덫을 놓을 수 있어요",
		},
		body = function()
			return Lines(
				"#showtooltip",
				("/cast [mod:shift] %s; [mod:ctrl] %s; [mod:alt] %s; %s"):format(N(13809), N(13795), N(13813), N(1499)))
		end,
	},
	{
		key = "focus", name = "주시 대상", title = "주시 대상 (펫·아군 지정, 지우기)",
		icon = 1002,   -- 야수의 눈 그림
		desc = {
			"그냥: 펫을 주시 대상으로 · Shift: 내 대상이 살아 있는 아군이면 그 아군을 주시 대상으로",
			"Ctrl: 주시 대상 지우기",
		},
		body = function()
			return Lines(
				"/focus [mod:shift,@target,help,nodead][nomod,@pet,exists,nodead]",
				"/clearfocus [mod:ctrl]")
		end,
	},
}

-- 전사. 태세가 맞아야 쓰는 기술은 첫 누름에 태세, 다음 누름에 기술.
MACROS.WARRIOR = {
	{
		key = "charge", name = "돌진 봉쇄", title = "돌진·봉쇄 (태세 자동)",
		spells = { 2457, 100, 2458, 20252 },
		desc = {
			"전투 밖: 전투 태세가 아니면 태세부터, 다시 누르면 돌진",
			"전투 중: 광폭 태세가 아니면 태세부터, 다시 누르면 봉쇄",
		},
		body = function()
			return Lines(
				"#showtooltip",
				("/cast [nocombat,nostance:1] %s; [nocombat] %s; [nostance:3] %s; %s")
					:format(N(2457), N(100), N(2458), N(20252)))
		end,
	},
	{
		key = "overpower", name = "제압", title = "제압 (전투 태세 자동)",
		spells = { 2457, 7384 },
		desc = { "전투 태세가 아니면 태세부터, 다시 누르면 제압(적이 공격을 피한 뒤에 쓸 수 있어요)" },
		body = function()
			return Lines("#showtooltip", ("/cast [nostance:1] %s; %s"):format(N(2457), N(7384)))
		end,
	},
	{
		key = "interrupt", name = "차단", title = "차단 (자루 공격·방패 가격)",
		spells = { 6552, 72 },
		desc = { "광폭 태세면 자루 공격, 아니면 방패 가격(방패를 들고 전투·방어 태세에서)" },
		body = function()
			return Lines("#showtooltip", ("/cast [stance:3] %s; %s"):format(N(6552), N(72)))
		end,
	},
	{
		key = "strike", name = "영웅의 일격", title = "영웅의 일격 + 자동 공격",
		spells = { 78, 845 },
		desc = { "자동 공격을 켜고 다음 공격에 영웅의 일격", "Shift: 회전베기(주변 적까지)" },
		body = function()
			return Lines("#showtooltip", "/startattack", ("/cast [mod:shift] %s; %s"):format(N(845), N(78)))
		end,
	},
	{
		key = "taunt", name = "도발", title = "도발 (방어 태세 자동, 마우스오버)",
		spells = { 71, 355 },
		desc = { "방어 태세가 아니면 태세부터, 다시 누르면 마우스를 올린 적(없으면 대상)을 도발" },
		body = function()
			return Lines("#showtooltip", ("/cast [nostance:2] %s; %s %s"):format(N(71), Harm(), N(355)))
		end,
	},
	{
		key = "shout", name = "외침", title = "외침 (전투의 외침·사기의 외침)",
		spells = { 6673, 1160 },
		desc = { "그냥: 전투의 외침 · Shift: 사기의 외침" },
		body = function()
			return Lines("#showtooltip", ("/cast [mod:shift] %s; %s"):format(N(1160), N(6673)))
		end,
	},
}

-- 도적. 은신 중엔 자동 공격을 켜지 않는다(켜는 순간 은신이 풀린다).
MACROS.ROGUE = {
	{
		key = "opener", name = "은신 선제", title = "은신·선제 공격 (전투 중엔 사악한 일격)",
		spells = { 1784, 1833, 8676, 703, 1752 },
		desc = {
			"전투 밖: 은신, 은신 중엔 비열한 습격 · Shift: 매복 · Ctrl: 목조르기",
			"전투 중(은신 아님): 사악한 일격",
		},
		body = function()
			return Lines(
				"#showtooltip",
				("/cast [combat,nostealth] %s; [nostealth] %s; [mod:shift] %s; [mod:ctrl] %s; %s")
					:format(N(1752), N(1784), N(8676), N(703), N(1833)))
		end,
	},
	{
		key = "attack", name = "기본 공격", title = "기본 공격 (사악한 일격·절개·난도질)",
		spells = { 1752, 2098, 5171 },
		desc = { "자동 공격 + 사악한 일격 · Shift: 절개 · Ctrl: 난도질" },
		body = function()
			return Lines("#showtooltip", "/startattack",
				("/cast [mod:shift] %s; [mod:ctrl] %s; %s"):format(N(2098), N(5171), N(1752)))
		end,
	},
	{
		key = "kick", name = "발차기", title = "발차기 (마우스오버 주문 끊기)",
		spells = { 1766 },
		desc = { "마우스를 올린 적(없으면 대상)의 주문을 끊는다" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s"):format(Harm(), N(1766)))
		end,
	},
	{
		key = "sap", name = "기절 실명", title = "기절시키기·실명 (마우스오버)",
		spells = { 6770, 2094 },
		desc = { "그냥: 기절시키기(은신 중, 전투 중이 아닌 인간형) · Shift: 실명(실명 가루 필요)" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s; %s %s"):format(Harm("shift"), N(2094), Harm(), N(6770)))
		end,
	},
	{
		key = "escape", name = "위기 탈출", title = "위기 탈출 (회피·소멸·전력 질주)",
		spells = { 5277, 1856, 2983 },
		desc = { "그냥: 회피 · Shift: 소멸(섬광 화약 필요) · Ctrl: 전력 질주" },
		body = function()
			return Lines("#showtooltip", ("/cast [mod:shift] %s; [mod:ctrl] %s; %s"):format(N(1856), N(2983), N(5277)))
		end,
	},
}

-- Form slots depend on the forms this character has learned.
MACROS.DRUID = {
	{
		key = "attack", name = "기본 공격", title = "기본 공격 (곰 후려치기·표범 할퀴기·Shift 천벌)",
		spells = function() return { 6807, 1082, 5176, Best(9634, 5487) } end,
		desc = {
			"그냥: 곰 후려치기 · 표범 할퀴기 · 변신 안 했으면 곰 변신(다시 누르면 후려치기)",
			"Shift: 변신을 풀고 천벌(안 풀렸으면 한 번 더) · 달빛야수는 그냥 눌러도 천벌",
			"곰·표범에서만 자동 공격, 이동·바다표범은 쉬어요. 변신을 새로 배우면 다시 만드세요",
		},
		body = function()
			local melee = {}
			local bear, cat, moonkin = BearIndex(), FormIndex(768), FormIndex(24858)
			-- 달빛야수는 변신한 채로 천벌이 나가니 풀지 않는다
			local shift = "[mod:shift,form" .. (moonkin and (",noform:" .. moonkin) or "") .. "]"
			local parts = { "[mod:shift]" .. (moonkin and ("[form:%d]"):format(moonkin) or "") .. " " .. N(5176) }
			if bear then
				parts[#parts + 1] = ("[form:%d] %s"):format(bear, N(6807))
				melee[#melee + 1] = bear
			end
			if cat then
				parts[#parts + 1] = ("[form:%d] %s"):format(cat, N(1082))
				melee[#melee + 1] = cat
			end
			-- 거리는 매크로가 못 재니, 인간형에서 그냥 누르면 곰부터 된다
			parts[#parts + 1] = "[noform] " .. (bear and N(Best(9634, 5487)) or N(5176))
			local lines = { "#showtooltip", "/cancelform " .. shift, "/stopmacro " .. shift }
			if #melee > 0 then lines[#lines + 1] = ("/startattack [nomod:shift,form:%s]"):format(table.concat(melee, "/")) end
			lines[#lines + 1] = "/cast " .. table.concat(parts, "; ")
			return table.concat(lines, "\n")
		end,
	},
	{
		key = "prowl", name = "표범 숨기", title = "표범 변신·숨기",
		spells = { 768, 5215 },
		desc = { "표범이 아니면 표범 변신, 다시 누르면 숨기(전투 밖)", "변신을 새로 배우면 다시 만드세요" },
		body = function()
			local cat = FormIndex(768)
			local cast = cat and ("[noform:%d] %s; [form:%d,nocombat,nostealth] %s"):format(cat, N(768), cat, N(5215)) or N(768)
			return Lines("#showtooltip", "/cast " .. cast)
		end,
	},
	{
		key = "heal", name = "치유", title = "치유의 손길·회복 (마우스오버, 변신 해제)",
		spells = { 5185, 774 },
		desc = {
			"마우스를 올린 아군 → 대상 아군 → 나 순서로 치유의 손길 · Shift: 회복",
			"변신 중이면 먼저 풀고, 다시 누르면 치유",
		},
		body = function()
			return Lines("#showtooltip", "/cancelform [form]", "/stopmacro [form]",
				("/cast %s %s; %s %s"):format(Help("shift"), N(774), Help(), N(5185)))
		end,
	},
	{
		key = "buff", name = "야생의 징표", title = "야생의 징표·가시 (마우스오버, 변신 해제)",
		spells = { 1126, 467 },
		desc = { "마우스를 올린 아군 → 대상 아군 → 나 · Shift: 가시", "변신 중이면 먼저 풀고, 다시 누르면 건다" },
		body = function()
			return Lines("#showtooltip", "/cancelform [form]", "/stopmacro [form]",
				("/cast %s %s; %s %s"):format(Help("shift"), N(467), Help(), N(1126)))
		end,
	},
	{
		key = "travel", name = "이동 변신", title = "이동 변신 (물속·야외·실내)",
		spells = { 1066, 783, 768 },
		desc = {
			"물속: 바다표범 변신 · 야외: 치타 변신 · 그 밖: 표범 변신",
			"배운 변신만 넣어요(안 배운 걸 넣으면 표범 대신 오류가 나서). 새로 배우면 다시 만드세요",
		},
		body = function()
			local parts = {}
			if ns.KnownSpellRank(1066) then parts[#parts + 1] = "[swimming] " .. N(1066) end
			if ns.KnownSpellRank(783) then parts[#parts + 1] = "[outdoors] " .. N(783) end
			parts[#parts + 1] = N(768)
			return Lines("#showtooltip", "/cast " .. table.concat(parts, "; "))
		end,
	},
	{
		key = "roots", name = "뿌리 겨울잠", title = "휘감는 뿌리·겨울잠 (마우스오버)",
		spells = { 339, 2637 },
		desc = { "그냥: 휘감는 뿌리 · Shift: 겨울잠(야수·용족)" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s; %s %s"):format(Harm("shift"), N(2637), Harm(), N(339)))
		end,
	},
	{
		key = "growl", name = "곰 도발", title = "곰 변신·포효 (마우스오버 도발)",
		spells = function() return { Best(9634, 5487), 6795 } end,
		desc = { "곰이 아니면 곰 변신, 다시 누르면 마우스를 올린 적(없으면 대상)에 포효", "변신을 새로 배우면 다시 만드세요" },
		body = function()
			local bear = BearIndex()
			local cast = bear and ("[noform:%d] %s; %s %s"):format(bear, N(Best(9634, 5487)), Harm(), N(6795)) or N(Best(9634, 5487))
			return Lines("#showtooltip", "/cast " .. cast)
		end,
	},
	{
		key = "cleanse", name = "독 저주 해제", title = "독·저주 해제 (마우스오버, 변신 해제)",
		spells = function() return { Best(2893, 8946), 2782 } end,
		desc = {
			"그냥: 독 해제(배우기 전에는 해독) · Shift: 저주 해제",
			"마우스를 올린 아군 → 대상 아군 → 나. 변신 중이면 먼저 풀고 다시 누르세요",
		},
		body = function()
			return Lines("#showtooltip", "/cancelform [form]", "/stopmacro [form]",
				("/cast %s %s; %s %s"):format(Help("shift"), N(2782), Help(), N(Best(2893, 8946))))
		end,
	},
	{
		key = "innervate", name = "정신 자극", title = "정신 자극 (마우스오버, Alt 나)",
		spells = { 29166 },
		desc = {
			"마우스를 올린 아군 → 대상 아군 → 나 · Alt: 항상 나에게",
			"변신 중이면 먼저 풀고 다시 누르세요. 누를 때만 시전합니다",
		},
		body = function()
			return Lines("#showtooltip " .. N(29166), "/cancelform [form]", "/stopmacro [form]",
				("/cast [mod:alt,@player]%s %s"):format(Help(), N(29166)))
		end,
	},
	{
		key = "rebirth", name = "환생", title = "환생 (죽은 아군 마우스오버)",
		spells = { 20484 },
		desc = {
			"마우스를 올린 죽은 아군 → 죽은 대상 아군에게 환생. 살아 있는 대상에게는 시전하지 않아요",
			"변신 중이면 먼저 풀고 다시 누르세요. 재료·마나·사거리·쿨다운은 게임에서 확인하세요",
		},
		body = function()
			return Lines("#showtooltip " .. N(20484), "/cancelform [form]", "/stopmacro [form]",
				"/cast [@mouseover,help,dead][help,dead] " .. N(20484))
		end,
	},
	{
		key = "escape", name = "나무껍질 질주", title = "나무 껍질·질주 (Shift 표범 변신)",
		spells = { 22812, 1850, 768 },
		desc = {
			"그냥: 나무 껍질 · Shift: 표범이 아니면 표범 변신, 다시 누르면 질주",
			"변신을 새로 배우면 다시 만드세요. 누를 때만 시전합니다",
		},
		body = function()
			local cat = FormIndex(768)
			local cast = cat and ("[mod:shift,noform:%d] %s; [mod:shift,form:%d] %s; %s"):format(cat, N(768), cat, N(1850), N(22812))
				or ("[mod:shift] %s; %s"):format(N(768), N(22812))
			return Lines("#showtooltip", "/cast " .. cast)
		end,
	},
}

-- 마법사. 변이에 /stopcasting을 안 넣는다(연타하면 하던 변이를 끊고 처음부터 다시 걸어서).
MACROS.MAGE = {
	{
		key = "poly", name = "변이", title = "변이 (마우스오버, Shift 주시 대상)",
		spells = { 118 },
		desc = { "마우스를 올린 적(없으면 대상)을 변이 · Shift: 주시 대상을 변이" },
		body = function()
			return Lines("#showtooltip", ("/cast [mod:shift,@focus,harm,nodead]%s %s"):format(Harm(), N(118)))
		end,
	},
	{
		key = "counter", name = "마법 차단", title = "마법 차단 (마우스오버, Shift 주시 대상)",
		spells = { 2139 },
		desc = { "하던 시전을 멈추고 마우스를 올린 적(없으면 대상)의 주문을 끊는다 · Shift: 주시 대상" },
		body = function()
			return Lines("#showtooltip", "/stopcasting", ("/cast [mod:shift,@focus,harm,nodead]%s %s"):format(Harm(), N(2139)))
		end,
	},
	{
		key = "conjure", name = "음료 음식", title = "음료·음식 창조",
		spells = { 5504, 587 },
		desc = { "그냥: 음료 창조 · Shift: 음식 창조" },
		body = function()
			return Lines("#showtooltip", ("/cast [mod:shift] %s; %s"):format(N(587), N(5504)))
		end,
	},
	{
		key = "intellect", name = "신비한 지능", title = "신비한 지능 (마우스오버)",
		spells = { 1459 },
		desc = { "마우스를 올린 아군 → 대상 아군 → 나" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s"):format(Help(), N(1459)))
		end,
	},
	{
		key = "armor", name = "갑옷", title = "갑옷·마나 보호막",
		spells = function() return { Best(7302, 168), 6117, 1463 } end,
		desc = { "그냥: 얼음 갑옷(배우기 전엔 냉기 갑옷) · Shift: 마법사 갑옷 · Ctrl: 마나 보호막" },
		body = function()
			return Lines("#showtooltip",
				("/cast [mod:shift] %s; [mod:ctrl] %s; %s"):format(N(6117), N(1463), N(Best(7302, 168))))
		end,
	},
}

-- 사제
MACROS.PRIEST = {
	{
		key = "shield", name = "보호막", title = "신의 권능: 보호막 (마우스오버)",
		spells = { 17 },
		desc = { "마우스를 올린 아군 → 대상 아군 → 나" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s"):format(Help(), N(17)))
		end,
	},
	{
		key = "renew", name = "소생", title = "소생 (마우스오버)",
		spells = { 139 },
		desc = { "마우스를 올린 아군 → 대상 아군 → 나" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s"):format(Help(), N(139)))
		end,
	},
	{
		key = "heal", name = "치유", title = "치유·순간 치유 (마우스오버)",
		spells = function() return { Best(2054, 2050), 2061 } end,
		desc = { "마우스를 올린 아군 → 대상 아군 → 나 순서로 치유(배우기 전엔 하급 치유) · Shift: 순간 치유" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s; %s %s"):format(Help("shift"), N(2061), Help(), N(Best(2054, 2050))))
		end,
	},
	{
		key = "fortitude", name = "인내", title = "신의 권능: 인내 (마우스오버)",
		spells = { 1243 },
		desc = { "마우스를 올린 아군 → 대상 아군 → 나" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s"):format(Help(), N(1243)))
		end,
	},
	{
		key = "pain", name = "고통", title = "어둠의 권능: 고통 (마우스오버)·정신 분열",
		spells = { 589, 8092 },
		desc = { "마우스를 올린 적(없으면 대상)에 어둠의 권능: 고통 · Shift: 대상에 정신 분열" },
		body = function()
			return Lines("#showtooltip", ("/cast [mod:shift] %s; %s %s"):format(N(8092), Harm(), N(589)))
		end,
	},
	{
		key = "dispel", name = "해제", title = "마법 무효화·질병 치료 (마우스오버)",
		spells = { 527, 528 },
		desc = { "마우스를 올린 아군 → 대상 아군 → 나 · 그냥: 마법 무효화 · Shift: 질병 치료" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s; %s %s"):format(Help("shift"), N(528), Help(), N(527)))
		end,
	},
}

-- 흑마법사. 포에버는 고통의 저주를 고통의 파멸로 바꿨다(이름이 다르면 /cast가 안 먹힌다).
MACROS.WARLOCK = {
	{
		key = "attack", name = "펫 공격 화살", title = "소환수 공격 + 어둠의 화살",
		spells = { 686, 348 },
		desc = { "대상에 소환수를 보내고 어둠의 화살 · Shift: 제물" },
		body = function()
			return Lines("#showtooltip", "/petattack [harm,nodead]", ("/cast [mod:shift] %s; %s"):format(N(348), N(686)))
		end,
	},
	{
		key = "dots", name = "부패 파멸", title = "부패·고통의 파멸 (마우스오버)",
		spells = { 172, 980 },
		desc = { "마우스를 올린 적(없으면 대상)에 부패 · Shift: 고통의 파멸" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s; %s %s"):format(Harm("shift"), N(980), Harm(), N(172)))
		end,
	},
	{
		key = "fear", name = "공포 추방", title = "공포·추방 (마우스오버)",
		spells = { 5782, 710 },
		desc = { "그냥: 공포 · Shift: 추방(악마·정령)" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s; %s %s"):format(Harm("shift"), N(710), Harm(), N(5782)))
		end,
	},
	{
		key = "spelllock", name = "주문 잠금", title = "주문 잠금 (지옥사냥개, 마우스오버)",
		-- 소환수 주문이라 내 주문책 검사로는 늘 "안 배움"으로 나와서 안내 목록에 안 넣는다
		desc = { "지옥사냥개가 마우스를 올린 적(없으면 대상)의 주문을 끊는다. 지옥사냥개를 불러 둔 때만 돼요" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s"):format(Harm(), N(19244)))
		end,
	},
	{
		key = "tap", name = "생명력 전환", title = "생명력 전환·흡수",
		spells = { 1454, 689 },
		desc = { "그냥: 생명력 전환(생명력 → 마나) · Shift: 대상의 생명력 흡수" },
		body = function()
			return Lines("#showtooltip", ("/cast [mod:shift] %s; %s"):format(N(689), N(1454)))
		end,
	},
	{
		key = "healthstone", name = "생명석", title = "생명석 먹기 (높은 등급부터)",
		icon = 6201,   -- 생명석 창조 그림
		desc = { "가방에 있는 생명석을 높은 등급부터 먹는다(최상급 → 최하급). 만들기는 마법책의 생명석 창조로" },
		body = function()
			local lines = {}
			for _, item in ipairs(HEALTHSTONES) do lines[#lines + 1] = "/use " .. item end
			return table.concat(lines, "\n")
		end,
	},
}

-- 성기사. 포에버 심판은 문장을 없애지 않아서 문장은 한 번 걸고 심판만 거듭 누르면 된다.
MACROS.PALADIN = {
	{
		key = "heal", name = "빛 치유", title = "성스러운 빛·빛의 섬광 (마우스오버)",
		spells = { 635, 19750 },
		desc = { "마우스를 올린 아군 → 대상 아군 → 나 · 그냥: 성스러운 빛 · Shift: 빛의 섬광" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s; %s %s"):format(Help("shift"), N(19750), Help(), N(635)))
		end,
	},
	{
		key = "blessing", name = "축복", title = "힘·지혜·왕의 축복 (마우스오버)",
		spells = { 19740, 19742, 20217 },
		desc = { "마우스를 올린 아군 → 대상 아군 → 나 · 그냥: 힘의 축복 · Shift: 지혜의 축복 · Ctrl: 왕의 축복" },
		-- #showtooltip까지 넣으면 263바이트. 물음표 그림은 빼도 첫 주문 그림을 따라간다.
		body = function()
			return ("/cast %s %s; %s %s; %s %s"):format(Help("shift"), N(19742), Help("ctrl"), N(20217), Help(), N(19740))
		end,
	},
	{
		key = "judge", name = "심판", title = "심판 + 자동 공격 (쿨이면 신성한 일격, 문장 고르기)",
		spells = { 20271, 679, 20154, 21082 },
		desc = {
			"자동 공격 + 심판, 심판이 쿨이면 신성한 일격(그때 '아직 사용할 수 없다'는 빨간 글이 뜰 수 있어요)",
			"Shift: 정의의 문장 · Ctrl: 성전사의 문장 (포에버는 심판해도 문장이 남아요)",
		},
		-- 심판이 쿨이면 그 줄은 전역 쿨 없이 실패해서 다음 줄의 신성한 일격이 나간다
		body = function()
			return Lines("#showtooltip", "/startattack",
				("/cast [mod:shift] %s; [mod:ctrl] %s; %s"):format(N(20154), N(21082), N(20271)),
				"/cast [nomod] " .. N(679))
		end,
	},
	{
		key = "cleanse", name = "정화", title = "정화·순화 (마우스오버)",
		spells = function() return { Best(4987, 1152) } end,
		desc = { "마우스를 올린 아군 → 대상 아군 → 나 (정화를 배우기 전엔 순화)" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s"):format(Help(), N(Best(4987, 1152))))
		end,
	},
	{
		key = "hammer", name = "심판의 망치", title = "심판의 망치 (마우스오버 기절)",
		spells = { 853 },
		desc = { "마우스를 올린 적(없으면 대상)을 기절시킨다(10미터 안)" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s"):format(Harm(), N(853)))
		end,
	},
	{
		key = "shield", name = "보호막", title = "천상의 보호막·보호의 축복",
		spells = function() return { Best(642, 498), 1022 } end,
		desc = { "그냥: 천상의 보호막(배우기 전엔 신의 가호) · Shift: 보호의 축복(마우스오버 → 대상 아군 → 나)" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s; %s"):format(Help("shift"), N(1022), N(Best(642, 498))))
		end,
	},
}

-- 주술사
MACROS.SHAMAN = {
	{
		key = "bolt", name = "번개 충격", title = "번개 화살·충격 (충격은 마우스오버)",
		spells = { 403, 8042, 8050 },
		desc = { "그냥: 번개 화살 · Shift: 대지 충격(주문 끊기) · Ctrl: 화염 충격", "충격은 마우스를 올린 적(없으면 대상)에" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s; %s %s; %s"):format(Harm("shift"), N(8042), Harm("ctrl"), N(8050), N(403)))
		end,
	},
	{
		key = "heal", name = "치유의 물결", title = "치유의 물결·하급 치유의 물결 (마우스오버)",
		spells = { 331, 8004 },
		desc = { "마우스를 올린 아군 → 대상 아군 → 나 · Shift: 하급 치유의 물결" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s; %s %s"):format(Help("shift"), N(8004), Help(), N(331)))
		end,
	},
	{
		key = "totem", name = "토템 부르기", title = "토템 부르기 (원소·선조·영혼의 부름, 귀환)",
		spells = { 66842, 66843, 66844, 36936 },
		desc = {
			"그냥: 원소의 부름(토템 바에 정한 토템을 한 번에) · Shift: 선조의 부름 · Ctrl: 영혼의 부름",
			"Alt: 토템의 귀환(토템 거두고 마나 일부 돌려받기)",
		},
		body = function()
			return Lines("#showtooltip",
				("/cast [mod:shift] %s; [mod:ctrl] %s; [mod:alt] %s; %s"):format(N(66843), N(66844), N(36936), N(66842)))
		end,
	},
	{
		key = "weapon", name = "무기 강화", title = "무기 강화 (대지·불꽃·냉기·질풍)",
		spells = { 8017, 8024, 8033, 8232 },
		desc = { "그냥: 대지의 무기 · Shift: 불꽃의 무기 · Ctrl: 냉기의 무기 · Alt: 질풍의 무기" },
		body = function()
			return Lines("#showtooltip",
				("/cast [mod:shift] %s; [mod:ctrl] %s; [mod:alt] %s; %s"):format(N(8024), N(8033), N(8232), N(8017)))
		end,
	},
	{
		key = "purge", name = "정화 해독", title = "정화(적)·해독(아군) (마우스오버)",
		spells = { 370, 526 },
		desc = { "그냥: 마우스를 올린 적(없으면 대상)의 마법 효과 정화 · Shift: 아군 해독(마우스오버 → 대상 → 나)" },
		body = function()
			return Lines("#showtooltip", ("/cast %s %s; %s %s"):format(Help("shift"), N(526), Harm(), N(370)))
		end,
	},
}

local class, className
local viewClass       -- 설정 창에서 보는 직업 (안 고르면 내 직업)
local selectedKey     -- 고르는 목록에서 고른 매크로 (이번 접속 동안만 기억)

-- 직업 고르기 순서. 이름은 게임에서 받고, 못 받을 때만 아래 글자.
local CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local CLASS_FALLBACK = {
	WARRIOR = "전사", PALADIN = "성기사", HUNTER = "사냥꾼", ROGUE = "도적", PRIEST = "사제",
	SHAMAN = "주술사", MAGE = "마법사", WARLOCK = "흑마법사", DRUID = "드루이드",
}

local function ClassTitle(file)
	local names = type(LOCALIZED_CLASS_NAMES_MALE) == "table" and LOCALIZED_CLASS_NAMES_MALE
	local name = names and names[file]
	return type(name) == "string" and name or CLASS_FALLBACK[file] or tostring(file)
end

-- 내 직업 매크로. 만들기와 펫 도우미 버튼은 늘 이쪽.
local function ClassList()
	return class and MACROS[class] or {}
end

local function ViewClass()
	return viewClass or class
end

-- 다른 직업 매크로는 보기만 한다. 캐릭터 전용 매크로라 이 캐릭터에 만들어 봐야 못 쓴다.
local function Mine()
	return ViewClass() == class
end

local function ViewList()
	local file = ViewClass()
	return file and MACROS[file] or {}
end

local function Find(key)
	for _, def in ipairs(ClassList()) do
		if def.key == key then return def end
	end
end

local function Selected()
	local list = ViewList()
	for _, def in ipairs(list) do
		if def.key == selectedKey then return def end
	end
	return list[1]
end

local function Icon(def)
	if type(def.icon) == "number" then
		local texture = C_Spell and C_Spell.GetSpellTexture and Clean(C_Spell.GetSpellTexture(def.icon))
		if texture then return texture end
	end
	return MACRO_ICON
end

---------------------------------------------------------------------------
-- 게임 매크로 다루기
---------------------------------------------------------------------------
-- 목 하네스처럼 상수가 숫자가 아닌 환경에서도 셈이 안 터지게 숫자만 받는다.
local function Number(v, default)
	return type(v) == "number" and v or default
end

local function MacroConsts()
	local c = type(Constants) == "table" and Constants.MacroConsts
	c = type(c) == "table" and c or {}
	return Number(c.MAX_ACCOUNT_MACROS, Number(MAX_ACCOUNT_MACROS, 120)),
		Number(c.MAX_CHARACTER_MACROS, Number(MAX_CHARACTER_MACROS, 30))
end

local function CharacterMacroCount()
	if not GetNumMacros then return 0 end
	local _, count = GetNumMacros()
	return Number(count, 0)
end

-- 캐릭터 전용 칸에서만 찾는다. GetMacroIndexByName은 계정 공용 매크로를 먼저 돌려줘서 그걸 고칠 뻔한다.
local function CharacterMacroIndex(name)
	if not GetMacroInfo then return nil end
	local base = MacroConsts()
	for index = base + 1, base + CharacterMacroCount() do
		if GetMacroInfo(index) == name then return index end
	end
end

local function SameBody(a, b)
	local function Trim(s) return (tostring(s or ""):gsub("\r\n", "\n"):gsub("%s+$", "")) end
	return Trim(a) == Trim(b)
end

-- 캐릭터 전용 매크로를 만들거나 같은 이름이면 고친다. 성공하면 매크로 번호. 펫 도우미·펫 먹이도 이걸 쓴다.
function ns.MakeCharacterMacro(name, body, icon)
	if InCombatLockdown() then
		Print("전투 중에는 매크로를 만들 수 없어요.")
		return
	end
	if not (CreateMacro and EditMacro) then
		Print("이 게임 버전에서는 애드온이 매크로를 만들 수 없어요.")
		return
	end
	if #body > BODY_LIMIT then
		Print(("매크로 '%s'가 너무 길어요 (%d/%d바이트)."):format(name, #body, BODY_LIMIT))
		return
	end
	local index = CharacterMacroIndex(name)
	local ok, err
	if index then
		ok, err = pcall(EditMacro, index, name, icon or MACRO_ICON, body)
	else
		local _, maxCharacter = MacroConsts()
		if CharacterMacroCount() >= maxCharacter then
			Print(("캐릭터 전용 매크로 칸(%d개)이 꽉 찼어요. 매크로 창(/macro)에서 안 쓰는 매크로를 지운 뒤 다시 눌러 주세요.")
				:format(maxCharacter))
			return
		end
		ok, err = pcall(CreateMacro, name, icon or MACRO_ICON, body, true)
	end
	local now = ok and CharacterMacroIndex(name)
	if not now then
		Print("매크로를 만들지 못했어요. 캐릭터 전용 매크로 칸이 꽉 찼는지 확인하세요. " .. tostring(err or ""))
		return
	end
	Print(("매크로 '%s'를 %s. 매크로 창(/macro)의 캐릭터 전용 탭에서 행동 단축바로 끌어다 놓으세요.")
		:format(name, index and "고쳤어요" or "만들었어요"))
	return now
end

local function Make(def)
	return ns.MakeCharacterMacro(def.name, def.body(), Icon(def))
end

-- 내 직업 매크로 페이지를 연다. 다른 직업을 보던 중이었어도 내 직업으로 돌려 놓는다.
function ns.OpenClassMacros()
	if viewClass and viewClass ~= class then
		viewClass, selectedKey = nil, nil
		ns:Fire("REBUILD_OPTIONS")
	end
	ns:OpenWindow("ClassMacros")
end

-- 지금 직업의 매크로 하나를 만든다. 펫 도우미의 [펫 매크로 만들기]가 부른다.
function ns.MakeClassMacro(key)
	local def = Find(key)
	if not def then
		Print("이 직업에는 그 매크로가 없어요.")
		return
	end
	return Make(def)
end

-- 없으면 만들고, 있으면 고치지 않은 채로 커서에 올린다. 행동 단축바 칸을 누르면 놓인다.
local function PickUp(def)
	if InCombatLockdown() then
		Print("전투 중에는 단축바에 놓을 수 없어요.")
		return
	end
	local index = CharacterMacroIndex(def.name) or Make(def)
	if not index then return end
	if ClearCursor then ClearCursor() end
	PickupMacro(index)
	Print(("'%s' 매크로를 집었어요. 놓을 행동 단축바 칸을 누르세요(그만두려면 오른쪽 클릭)."):format(def.name))
end

---------------------------------------------------------------------------
-- 설정 창 글
---------------------------------------------------------------------------
local function MissingSpells(def)
	local missing = {}
	local spells = def.spells
	if type(spells) == "function" then spells = spells() end
	for _, id in ipairs(spells or {}) do
		if not ns.KnownSpellRank(id) then missing[#missing + 1] = N(id) or ("#" .. id) end
	end
	return missing
end

local function DescText(def)
	local text = table.concat(def.desc, "\n")
	local missing = Mine() and MissingSpells(def) or {}
	if #missing > 0 then
		text = text .. "\n|cff999999아직 안 배운 주문: " .. table.concat(missing, ", ") .. " (배우면 그대로 써요)|r"
	end
	return text
end

-- longest가 참이면 상태와 상관없이 가장 긴 문구(내용 다름)를 돌려준다. 자리 높이를 잴 때 쓴다.
local function StatusText(def, longest)
	if not Mine() then
		return ("|cff999999다른 직업 매크로는 보기만 돼요. 캐릭터 전용 매크로라서 %s 캐릭터로 접속해 만드세요.|r")
			:format(ClassTitle(ViewClass()))
	end
	local _, maxCharacter = MacroConsts()
	local slots = ("캐릭터 전용 매크로 %d/%d칸"):format(CharacterMacroCount(), maxCharacter)
	local index = not longest and CharacterMacroIndex(def.name)
	if not index and not longest then
		return ("'%s': 아직 없음 · %s"):format(def.name, slots)
	end
	if index and SameBody(select(3, GetMacroInfo(index)), def.body()) then
		return ("'%s': |cff33ff33만들어 둠 (아래 내용과 같음)|r · %s"):format(def.name, slots)
	end
	return ("'%s': |cffff9933이름이 같은 매크로가 있는데 내용이 달라요. [매크로 만들기]를 누르면 아래 내용으로 고쳐요.|r · %s")
		:format(def.name, slots)
end

local function BodyText(def)
	local body = def.body()
	return ("%s\n|cff808080(%d/%d바이트)|r"):format(body:gsub("|", "||"), #body, BODY_LIMIT)
end

-- 고른 매크로마다 줄 수가 달라도 아래 컨트롤이 밀리지 않게, 이 직업에서 가장 긴 글에 맞춘 높이로 자리를 잡는다.
local function FixedText(parent, width, textFunc, defs, font, measureFunc)
	local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlightSmall")
	fs:SetWidth(width)
	fs:SetJustifyH("LEFT")
	fs:SetJustifyV("TOP")
	fs:SetSpacing(2)
	local height = 14
	for _, def in ipairs(defs) do
		fs:SetText((measureFunc or textFunc)(def))
		height = math.max(height, fs:GetStringHeight() or 0)
	end
	function fs:Refresh()
		local def = Selected()
		self:SetText(def and textFunc(def) or "")
	end
	return fs, height
end

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
local M = ns:NewModule("ClassMacros", {
	title = "직업 매크로",
	category = "general",
	icon = "Interface\\Icons\\INV_Scroll_05",
	order = 27,
})

function M:OnLogin()
	className, class = UnitClass("player")
end

local function RefreshDruidMacros()
	if class == "DRUID" then ns:Fire("REFRESH_UI") end
end
ns:RegisterEvent("UPDATE_SHAPESHIFT_FORMS", RefreshDruidMacros)
ns:RegisterEvent("SPELLS_CHANGED", RefreshDruidMacros)

function M:BuildOptions(b)
	local width = b.width - 32
	local view = ViewClass()
	local defs = ViewList()

	b:Text("직업마다 쓸 만한 매크로를 골라 캐릭터 전용 매크로로 만들어 줍니다. 주문 이름은 게임에서 가져오고 등급은 적지 않아서 "
		.. "새 등급을 배워도 다시 만들 필요가 없어요. 이름이 같은 캐릭터 전용 매크로가 있으면 내용을 고칩니다. "
		.. "다른 직업 매크로도 골라서 볼 수 있고, 만들기는 그 직업 캐릭터에서 해요.")
	b:Dropdown{
		label = "직업", width = 220, emptyText = className or "",
		options = function()
			local list = {}
			for _, file in ipairs(CLASS_ORDER) do
				if MACROS[file] then
					list[#list + 1] = { value = file, text = ClassTitle(file) .. (file == class and " (지금 캐릭터)" or "") }
				end
			end
			return list
		end,
		get = ViewClass,
		set = function(file)
			if file == ViewClass() then return end
			viewClass, selectedKey = file, nil
			-- 직업마다 목록·글 높이가 달라서 페이지를 다시 그린다. 고르기 메뉴가 닫힌 다음 프레임에.
			C_Timer.After(0, function() ns:Fire("REBUILD_OPTIONS") end)
		end,
	}
	b:Header(("%s 매크로"):format((view == class and className) or ClassTitle(view)))
	if #defs == 0 then
		b:Text("이 직업 매크로는 아직 없어요.", { color = MUTED })
		return
	end

	b:Dropdown{
		label = "매크로", width = 320,
		options = function()
			local list = {}
			for _, def in ipairs(defs) do list[#list + 1] = { value = def.key, text = def.title } end
			return list
		end,
		get = function() local def = Selected() return def and def.key end,
		set = function(key) selectedKey = key end,
	}

	if not b.searchOnly then
		local desc, descHeight = FixedText(b.page, width, DescText, defs, "GameFontHighlight")
		b:Place(desc, descHeight)
		b:Track(desc)

		local status, statusHeight = FixedText(b.page, width, StatusText, defs, nil, function(def) return StatusText(def, true) end)
		b:Place(status, statusHeight)
		b:Track(status)

		-- 매크로 내용 미리 보기 (매크로 창에 들어갈 글 그대로)
		local box = CreateFrame("Frame", nil, b.page, "BackdropTemplate")
		UI.ApplyPanelBackdrop(box, { 0, 0, 0, 0.35 }, UI.Theme.border)
		local preview, previewHeight = FixedText(box, width - 16, BodyText, defs, "ChatFontNormal")
		preview:SetPoint("TOPLEFT", 8, -8)
		box:SetSize(width, previewHeight + 16)
		function box:Refresh() preview:Refresh() end
		b:Place(box, previewHeight + 16)
		b:Track(box)

	end

	local function NotMine() return not Mine() end
	b:Buttons{
		{
			text = "매크로 만들기", width = 140, disabled = NotMine,
			onClick = function() local def = Selected() if def and Mine() then Make(def) end end,
			tooltip = "이 내용으로 캐릭터 전용 매크로를 만듭니다. 이름이 같은 캐릭터 전용 매크로가 있으면 내용을 이걸로 고칩니다.",
		},
		{
			text = "단축바에 놓기", width = 140, disabled = NotMine,
			onClick = function() local def = Selected() if def and Mine() then PickUp(def) end end,
			tooltip = "매크로를 커서에 올립니다(없으면 먼저 만듭니다). 놓을 행동 단축바 칸을 누르세요. 이미 있는 매크로는 고치지 않아요.",
		},
	}
	local tip = "기본 단축키가 붙은 행동 단축바 칸에 두면 단축키가 초기화돼도 그대로 쓸 수 있어요."
	if view == "HUNTER" then
		tip = tip .. " 먹이만 따로 누르는 매크로는 " .. ns:SettingsPath("PetFeed") .. "에 있어요."
	end
	b:Text(tip, { color = MUTED })
end
