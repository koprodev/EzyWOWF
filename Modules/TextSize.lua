-- 글자 크기: 창과 아이콘 크기는 그대로 두고 게임 화면의 글자만 키우거나 줄인다.
-- 게임 설정의 "UI 크기"는 창까지 통째로 커지고, 접근성의 "텍스트 크기"(Text Scale)는
-- 대화상자 등 일부 창에만 적용돼서 따로 만들었다.
--
-- 블리자드 UI 글자는 대부분 이름 있는 폰트 오브젝트(GameFontNormal 등)를 쓴다.
-- 각 폰트 오브젝트의 원래 크기를 기억해 두고 "원래 크기 × 배율"로 다시 지정한다.
-- 폰트 오브젝트 없이 크기를 직접 정하는 글자(채팅창 등)는 바뀌지 않는다.

local _, ns = ...

local M = ns:NewModule("TextSize", {
	title = "글자 크기",
	category = "interface",
	icon = "Interface\\Icons\\INV_Misc_Book_09",
	order = 5,
	defaults = {
		enabled = false,
		percent = 120,
	},
})

local MIN_PERCENT, MAX_PERCENT = 70, 150

local db
local originals = {}  -- [폰트 오브젝트] = { path =, height =, flags = }
local current = 1     -- 지금 적용된 배율 (1 = 원래 크기)

-- 이름 있는 폰트 오브젝트 전부
local function AllFonts()
	local list = {}
	if GetFonts then
		for _, name in ipairs(GetFonts()) do
			local font = _G[name]
			if type(font) == "table" and font.GetFont and font.SetFont then list[#list + 1] = font end
		end
	else
		for _, v in pairs(_G) do
			if type(v) == "table" then
				local ok, objectType = pcall(function() return v:GetObjectType() end)
				if ok and objectType == "Font" then list[#list + 1] = v end
			end
		end
	end
	return list
end

-- 처음 보는 폰트의 원래 크기를 기억한다.
-- 배율을 적용한 뒤에 생긴 폰트가 부모 폰트의 (이미 바뀐) 크기를 물려받았다면 부모의 원래 크기를 쓴다.
local function Remember(font)
	local path, height, flags = font:GetFont()
	if not path or not height or height <= 0 then return nil end
	if current ~= 1 then
		local parent = font.GetFontObject and font:GetFontObject()
		local base = parent and originals[parent]
		if base and math.abs(height - base.height * current) < 0.05 then
			height = base.height
		end
	end
	local info = { path = path, height = height, flags = flags }
	originals[font] = info
	return info
end

local function SetScale(font, info, scale)
	pcall(font.SetFont, font, info.path, info.height * scale, info.flags)
end

local function ScaleAll(scale)
	for _, font in ipairs(AllFonts()) do
		if not originals[font] then Remember(font) end
	end
	for font, info in pairs(originals) do
		SetScale(font, info, scale)
	end
	current = scale
	ns:Fire("FONTS_CHANGED")
end

local function Update()
	local scale = db.enabled and db.percent / 100 or 1
	if scale ~= current then ScaleAll(scale) end
end

-- 나중에 로드되는 블리자드 추가 UI(경매장, 전문기술 창 등)나 다른 애드온이 만든 폰트에도 지금 배율을 적용한다.
ns:RegisterEvent("ADDON_LOADED", function()
	if current == 1 then return end
	for _, font in ipairs(AllFonts()) do
		if not originals[font] then
			local info = Remember(font)
			if info then SetScale(font, info, current) end
		end
	end
end)

---------------------------------------------------------------------------
-- 모듈
---------------------------------------------------------------------------
function M:OnInitialize()
	db = self.db
end

-- 블리자드 UI가 접속 과정에서 폰트를 정리한 뒤에 적용한다.
function M:OnLogin()
	Update()
end

function M:ApplySettings()
	Update()
end

function M:BuildOptions(b)
	b:Text("창과 아이콘 크기는 그대로 두고 글자만 키우거나 줄입니다. "
		.. "퀘스트, 툴팁, 가방, 캐릭터 창, 행동 단축바 숫자 등 대부분의 글자에 적용됩니다.")
	b:Check{ key = "enabled", label = "사용" }
	b:Slider{
		key = "percent", label = "글자 크기",
		min = MIN_PERCENT, max = MAX_PERCENT, step = 5, format = "%d%%",
		depends = "enabled",
		tooltip = "100%가 원래 크기입니다. [저장]을 누르면 바로 바뀝니다.",
	}
	b:Text("- 너무 크게 하면 좁은 창이나 버튼에서 글자가 잘리거나 겹칠 수 있어요. 110~130%부터 맞춰 보세요.\n"
		.. "- 채팅창 글자는 채팅 탭을 우클릭해서 [글꼴 크기]로 따로 바꿉니다.\n"
		.. "- 창과 아이콘까지 통째로 키우려면 게임 설정 > 그래픽의 UI 크기(UI Scale)를 쓰세요.",
		{ color = { 0.7, 0.7, 0.7 } })
end
