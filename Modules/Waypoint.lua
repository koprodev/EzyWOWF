-- /way: 좌표로 지도 핀(사용자 웨이포인트)을 꽂고 추적한다. 퀘스트 방향 화살표가 그쪽을 가리킨다.
--   /way 45.2 63.1               지금 있는 지역
--   /way 45.2, 63.1 광맥           좌표 뒤에 메모
--   /way 서부 몰락지대 45 63         지역 이름 (일부만 써도 된다)
--   /way #1436 45 63             지도 번호
--   /way 지우기 (또는 clear)        핀 지우기
-- 지역 이름은 처음 쓸 때 지도 정보를 한 번 훑어서 찾아 둔다.

local _, ns = ...
local Clean, Print = ns.Clean, ns.Print

local M = ns:NewModule("Waypoint", {
	title = "좌표 길 안내 (/way)",
	category = "map",
	icon = "Interface\\Icons\\INV_Misc_PocketWatch_02",
	order = 40,
	defaults = {
		enabled = true,
	},
})

local ZONE_MAP = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
local MAX_MAP_ID = 3000
local CLEAR_WORDS = { ["지우기"] = true, ["삭제"] = true, ["clear"] = true, ["reset"] = true }

local zoneNames   -- [이름] = 지도 번호 (지역 지도만)

local function BuildZoneNames()
	zoneNames = {}
	for mapID = 1, MAX_MAP_ID do
		local info = C_Map.GetMapInfo(mapID)
		if info and info.mapType == ZONE_MAP and info.name and not zoneNames[info.name] then
			zoneNames[info.name] = mapID
		end
	end
end

-- 정확히 같은 이름을 먼저, 없으면 이름에 들어 있는 것 중 가장 짧은 것
local function FindZone(query)
	if not zoneNames then BuildZoneNames() end
	if zoneNames[query] then return zoneNames[query] end
	local lowered = query:lower()
	local bestID, bestName
	for name, mapID in pairs(zoneNames) do
		if name:lower():find(lowered, 1, true) and (not bestName or #name < #bestName) then
			bestID, bestName = mapID, name
		end
	end
	return bestID
end

-- 동굴 같은 작은 지도에 있어도 지역 지도 좌표로 쓴다. (/way 좌표는 보통 지역 지도 기준)
local function CurrentZone()
	local mapID = C_Map.GetBestMapForUnit("player")
	local zoneID = mapID
	while zoneID do
		local info = C_Map.GetMapInfo(zoneID)
		if not info or info.mapType == ZONE_MAP then break end
		if info.mapType < ZONE_MAP or not info.parentMapID or info.parentMapID == 0 then
			return mapID
		end
		zoneID = info.parentMapID
	end
	return zoneID
end

local function MapName(mapID)
	local info = C_Map.GetMapInfo(mapID)
	return info and info.name or ("#" .. mapID)
end

-- "서부 몰락지대 45.2, 63.1 광맥" -> 지역 부분, x, y, 메모
local function Parse(msg)
	local tokens = {}
	for token in msg:gsub(",", " "):gmatch("%S+") do tokens[#tokens + 1] = token end
	for i = 1, #tokens - 1 do
		local x, y = tonumber(tokens[i]), tonumber(tokens[i + 1])
		if x and y then
			local zone = table.concat(tokens, " ", 1, i - 1)
			local note = table.concat(tokens, " ", i + 2)
			return zone, x, y, note
		end
	end
end

local function Usage()
	Print("사용법: |cff00ff00/way 45.2 63.1|r (지금 지역)  |cff00ff00/way 지역이름 45 63|r  |cff00ff00/way 지우기|r")
end

local function SetWay(mapID, x, y, note)
	if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapID) then
		Print(("'%s' 지도에는 핀을 꽂을 수 없어요."):format(MapName(mapID)))
		return
	end
	C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x / 100, y / 100))
	if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
		C_SuperTrack.SetSuperTrackedUserWaypoint(true)
	end
	local suffix = (note and note ~= "") and ("  |cffffd100" .. note .. "|r") or ""
	Print(("지도 핀: %s %.1f, %.1f%s"):format(MapName(mapID), x, y, suffix))
end

local function HandleSlash(msg)
	msg = (msg or ""):match("^%s*(.-)%s*$")
	if not M.db.enabled then
		Print(("좌표 길 안내가 꺼져 있어요. |cff00ff00/이지|r > %s에서 켜세요."):format(ns:SettingsPath("Waypoint")))
		return
	end
	if msg == "" then
		Usage()
		return
	end
	if CLEAR_WORDS[msg:lower()] then
		if C_Map.ClearUserWaypoint then C_Map.ClearUserWaypoint() end
		Print("지도 핀을 지웠습니다.")
		return
	end
	if not (C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates) then
		Print("이 게임 버전에서는 지도 핀을 꽂을 수 없어요.")
		return
	end

	local zone, x, y, note = Parse(msg)
	if not x or x < 0 or x > 100 or y < 0 or y > 100 then
		Usage()
		return
	end

	local mapID
	local number = zone:match("^#(%d+)$")
	if number then
		mapID = tonumber(number)
	elseif zone ~= "" then
		mapID = FindZone(zone)
		if not mapID then
			Print(("'%s' 지역을 찾지 못했어요."):format(zone))
			return
		end
	else
		mapID = CurrentZone()
		if not mapID then
			Print("지금 있는 지역을 알 수 없어요.")
			return
		end
	end
	SetWay(mapID, x, y, note)
end

SLASH_EZYWOWFWAY1 = "/way"
SLASH_EZYWOWFWAY2 = "/좌표"
SlashCmdList.EZYWOWFWAY = HandleSlash

function M:BuildOptions(b)
	b:Text("채팅창에 좌표를 입력하면 지도에 핀을 꽂고 추적합니다. 퀘스트 방향 화살표가 그쪽을 가리켜요.")
	b:Check{ key = "enabled", label = "사용" }
	b:Text("|cff00ff00/way 45.2 63.1|r  - 지금 있는 지역의 좌표\n"
		.. "|cff00ff00/way 45.2 63.1 광맥|r  - 좌표 뒤에 메모\n"
		.. "|cff00ff00/way 서부 몰락지대 45 63|r  - 다른 지역 (이름 일부만 써도 됨)\n"
		.. "|cff00ff00/way #1436 45 63|r  - 지도 번호\n"
		.. "|cff00ff00/way 지우기|r  - 핀 지우기\n"
		.. "(/좌표 도 같습니다)", { font = "GameFontHighlightSmall" })
end
