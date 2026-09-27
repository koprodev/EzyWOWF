-- 설정 내보내기/가져오기.
-- 포에버 베타는 재접속하면 저장 파일과 단축키를 불러오지 못하는 버그가 있어서,
-- 설정 전체를 글자 한 줄로 만들어 두었다가 붙여 넣어 되살릴 수 있게 한다.
-- 가져오기는 코드를 실행하지 않고 직접 해석하므로 아무 문자열을 넣어도 안전하다.

local _, ns = ...

local PREFIX = "EZY1:"
local LEGACY_PREFIX = "MTK1:"   -- 옛 이름(MyToolkit) 시절 문자열

---------------------------------------------------------------------------
-- 직렬화 (문자열은 길이를 앞에 붙여서 특수문자를 신경 쓰지 않는다)
--   T / F        불리언
--   N<숫자>;     숫자
--   S<길이>:<내용> 문자열
--   { 키 값 ... } 표
---------------------------------------------------------------------------
local SIMPLE_TYPES = { boolean = true, number = true, string = true, table = true }

local function Serialize(value, out)
	local t = type(value)
	if t == "boolean" then
		out[#out + 1] = value and "T" or "F"
	elseif t == "number" then
		out[#out + 1] = "N" .. tostring(value) .. ";"
	elseif t == "string" then
		out[#out + 1] = "S" .. #value .. ":" .. value
	elseif t == "table" then
		out[#out + 1] = "{"
		for k, v in pairs(value) do
			local kt = type(k)
			if (kt == "string" or kt == "number") and SIMPLE_TYPES[type(v)] then
				Serialize(k, out)
				Serialize(v, out)
			end
		end
		out[#out + 1] = "}"
	end
end

local function Deserialize(s)
	local pos = 1

	local function ReadValue()
		local c = s:sub(pos, pos)
		pos = pos + 1
		if c == "T" then
			return true
		elseif c == "F" then
			return false
		elseif c == "N" then
			local stop = s:find(";", pos, true)
			local n = stop and tonumber(s:sub(pos, stop - 1))
			if not n then error("숫자 오류") end
			pos = stop + 1
			return n
		elseif c == "S" then
			local colon = s:find(":", pos, true)
			local len = colon and tonumber(s:sub(pos, colon - 1))
			if not len then error("문자열 오류") end
			local str = s:sub(colon + 1, colon + len)
			if #str ~= len then error("문자열 오류") end
			pos = colon + len + 1
			return str
		elseif c == "{" then
			local t = {}
			while s:sub(pos, pos) ~= "}" do
				if pos > #s then error("표가 끝나지 않음") end
				local k = ReadValue()
				t[k] = ReadValue()
			end
			pos = pos + 1
			return t
		end
		error("알 수 없는 기호")
	end

	return ReadValue()
end

---------------------------------------------------------------------------
-- Base64 (복사/붙여넣기 중 글자가 깨지지 않도록)
---------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64 do B64_INDEX[B64:sub(i, i)] = i - 1 end

local function Base64Encode(s)
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = s:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1 = math.floor(n / 262144) % 64
		local c2 = math.floor(n / 4096) % 64
		local c3 = math.floor(n / 64) % 64
		local c4 = n % 64
		out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
			.. (b and B64:sub(c3 + 1, c3 + 1) or "=")
			.. (c and B64:sub(c4 + 1, c4 + 1) or "=")
	end
	return table.concat(out)
end

local function Base64Decode(s)
	s = s:gsub("[^%w%+/]", "")
	local out = {}
	for i = 1, #s, 4 do
		local chunk = s:sub(i, i + 3)
		local n, count = 0, 0
		for j = 1, 4 do
			local v = B64_INDEX[chunk:sub(j, j)]
			n = n * 64 + (v or 0)
			if v then count = count + 1 end
		end
		local a = math.floor(n / 65536) % 256
		local b = math.floor(n / 256) % 256
		local c = n % 256
		if count >= 2 then out[#out + 1] = string.char(a) end
		if count >= 3 then out[#out + 1] = string.char(b) end
		if count >= 4 then out[#out + 1] = string.char(c) end
	end
	return table.concat(out)
end

---------------------------------------------------------------------------
-- 옛 이름(MyToolkit) 호환: 개명했다고 예전 백업 문자열을 문전박대하진 않는다
---------------------------------------------------------------------------
-- 접두어를 떼어 낸 본문. 어느 접두어와도 안 맞으면 nil.
local function StripPrefix(text, prefix, legacyPrefix)
	if text:sub(1, #prefix) == prefix then return text:sub(#prefix + 1) end
	if legacyPrefix and text:sub(1, #legacyPrefix) == legacyPrefix then
		return text:sub(#legacyPrefix + 1)
	end
end

-- 옛 단축키 명령("CLICK MyToolkit…", "MYTOOLKIT_…")은 지금 이름으로. 나머지는 그대로 통과.
function ns.UpgradeLegacyCommand(command)
	if type(command) ~= "string" then return command end
	command = command:gsub("^CLICK MyToolkit", "CLICK EzyWOWF"):gsub("^MYTOOLKIT_", "EZYWOWF_")
	return command
end

---------------------------------------------------------------------------
-- 다른 모듈용: 표를 글자 한 줄로 (예: 채집 기록 내보내기)
---------------------------------------------------------------------------
function ns.EncodeData(prefix, data)
	local out = {}
	Serialize(data, out)
	return prefix .. Base64Encode(table.concat(out))
end

-- 성공하면 true, 표. 실패하면 false, 이유. legacyPrefix를 주면 옛 접두어도 받는다.
function ns.DecodeData(prefix, text, legacyPrefix)
	text = (text or ""):gsub("%s+", "")
	local body = StripPrefix(text, prefix, legacyPrefix)
	if not body then
		return false, ("'%s'로 시작하는 문자열이 아닙니다."):format(prefix)
	end
	local ok, data = pcall(function()
		return Deserialize(Base64Decode(body))
	end)
	if not ok or type(data) ~= "table" then
		return false, "문자열이 손상되었습니다. 처음부터 끝까지 전부 복사했는지 확인하세요."
	end
	return true, data
end

---------------------------------------------------------------------------
-- 내보내기 / 가져오기
---------------------------------------------------------------------------
function ns:ExportSettings()
	local data = { v = 1, modules = {}, bindings = {} }
	for _, m in ipairs(self.moduleOrder) do
		local copy = {}
		for k, v in pairs(m.db) do
			if type(v) ~= "table" then copy[k] = v end
		end
		data.modules[m.key] = copy
		for _, command in ipairs(m.bindings) do
			local keys = { GetBindingKey(command) }
			if #keys > 0 then data.bindings[command] = keys end
		end
	end
	local out = {}
	Serialize(data, out)
	return PREFIX .. Base64Encode(table.concat(out))
end

function ns:ImportSettings(text)
	if InCombatLockdown() then
		return false, "전투 중에는 가져올 수 없어요."
	end
	text = (text or ""):gsub("%s+", "")
	local body = StripPrefix(text, PREFIX, LEGACY_PREFIX)
	if not body then
		return false, ("EzyWOWF 설정 문자열이 아닙니다. '%s'로 시작해야 합니다."):format(PREFIX)
	end
	local ok, data = pcall(function()
		return Deserialize(Base64Decode(body))
	end)
	if not ok or type(data) ~= "table" or type(data.modules) ~= "table" then
		return false, "문자열이 손상되었습니다. 처음부터 끝까지 전부 복사했는지 확인하세요."
	end

	self:DiscardSettings()

	-- 이 버전에 있는 설정 중, 기본값과 형식이 같은 것만 받아들인다.
	local count = 0
	for _, m in ipairs(self.moduleOrder) do
		local saved = data.modules[m.key]
		if type(saved) == "table" and m.defaults then
			local changes = {}
			for k, v in pairs(saved) do
				local default = m.defaults[k]
				if default ~= nil and type(v) == type(default) then
					m.db[k] = v
					changes[k] = v
					count = count + 1
				end
			end
			if m.ApplySettings and next(changes) then m:ApplySettings(changes) end
		end
	end

	local bindingCount = 0
	if type(data.bindings) == "table" then
		local known = {}
		for _, m in ipairs(self.moduleOrder) do
			for _, command in ipairs(m.bindings) do known[command] = true end
		end
		for savedCommand, keys in pairs(data.bindings) do
			local command = ns.UpgradeLegacyCommand(savedCommand)
			if known[command] and type(keys) == "table" then
				for _, old in ipairs({ GetBindingKey(command) }) do SetBinding(old) end
				for _, key in ipairs(keys) do
					if type(key) == "string" and SetBinding(key, command) then
						bindingCount = bindingCount + 1
					end
				end
			end
		end
		SaveBindings(GetCurrentBindingSet())
	end

	self:Fire("REFRESH_UI")
	return true, ("설정 %d개와 단축키 %d개를 가져왔습니다."):format(count, bindingCount)
end
