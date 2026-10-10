local _, ns = ...
local Finder, Clean = ns.TrainerFinder, ns.Clean
local M = ns.modules.TrainerFinder

local DIAMETERS = ns.MinimapProjection.Diameters
local pins, rows, rowsMap, reported = {}, {}, nil, {}
local shown, elapsed = 0, 0
local driver = CreateFrame("Frame", "EzyWOWFTrainerMinimapDriver", Minimap)
driver:Hide()

local function Number(value)
	value = Clean(value)
	if type(value) == "number" and value == value and math.abs(value) < math.huge then return value end
end

local function Call(owner, name, ...)
	local fn = owner and owner[name]
	if type(fn) ~= "function" then return end
	local ok, a, b = pcall(fn, ...)
	if ok then return Clean(a), Clean(b) end
	if not reported[name] then
		reported[name] = true
		ns.ErrorHandler("TrainerFinderMinimap: " .. name .. ": " .. tostring(a))
	end
end

local function MapID(value)
	value = Number(value)
	if value and value > 0 and value % 1 == 0 then return value end
end

local function Region(id)
	local visited = {}
	while id and not visited[id] do
		visited[id] = true
		if ns.trainerLocations and ns.trainerLocations[id] then return id end
		local info = Call(C_Map, "GetMapInfo", id)
		id = type(info) == "table" and MapID(info.parentMapID) or nil
	end
end

local function PlayerMap()
	return Region(MapID(Call(C_Minimap, "GetUiMapID")))
		or Region(MapID(Call(C_Map, "GetBestMapForUnit", "player")))
end

local function HideTooltip(pin)
	if GameTooltip.GetOwner and GameTooltip:GetOwner() == pin then GameTooltip:Hide() end
end

local function Clear()
	for i = 1, shown do
		HideTooltip(pins[i])
		pins[i].row = nil
		pins[i]:Hide()
	end
	shown = 0
end

local function Pin(index)
	if pins[index] then return pins[index] end
	local pin = CreateFrame("Frame", "EzyWOWFTrainerMinimapDot" .. index, Minimap)
	pin:SetFrameLevel((Number(Minimap:GetFrameLevel()) or 0) + 6)
	pin.Icon = pin:CreateTexture(nil, "OVERLAY")
	pin.Icon:SetAllPoints()
	pin.Icon:SetColorTexture(1, 0.12, 0.12, 1)
	pin.Mask = pin:CreateMaskTexture()
	pin.Mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	pin.Mask:SetAllPoints(pin.Icon)
	pin.Icon:AddMaskTexture(pin.Mask)
	pin:EnableMouse(true)
	pin:SetScript("OnEnter", function(self)
		if not self.row then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(self.row.name, 1, 0.82, 0)
		GameTooltip:AddLine(Finder.GetCaption(self.row), 1, 1, 1, true)
		GameTooltip:AddLine(("참고 위치입니다. 실제 위치·%s이 다를 수 있어요."):format(Finder.DiffersNote(self.row.kind)), 0.65, 0.65, 0.65, true)
		GameTooltip:Show()
	end)
	pin:SetScript("OnLeave", function(self) HideTooltip(self) end)
	pin:Hide()
	pins[index] = pin
	return pin
end

local function Radius()
	if C_Minimap and type(C_Minimap.GetViewRadius) == "function" then
		return Number(Call(C_Minimap, "GetViewRadius"))
	end
	local indoor = Call(_G, "IsIndoors") == true
	local zoom = Number(Call(Minimap, "GetZoom", Minimap))
	if not zoom or zoom % 1 ~= 0 then return end
	local diameter = DIAMETERS[indoor and "indoor" or "outdoor"][zoom]
	return diameter and diameter / 2
end

local function Facing()
	if C_Minimap and type(C_Minimap.IsRotateMinimapIgnored) == "function" then
		local ignored = Call(C_Minimap, "IsRotateMinimapIgnored")
		if ignored == true then return 0 end
		if ignored ~= false then return end
	end
	local rotate
	if C_CVar and type(C_CVar.GetCVarBool) == "function" then
		rotate = Call(C_CVar, "GetCVarBool", "rotateMinimap")
	else
		local value = Call(_G, "GetCVar", "rotateMinimap")
		if value == "1" then rotate = true elseif value == "0" then rotate = false end
	end
	if rotate == false then return 0 end
	if rotate == true then return Number(Call(_G, "GetPlayerFacing")) end
end

local function Enabled()
	return M.db and M.db.enabled and M.db.showOnMinimap
end

local function Update()
	if not Enabled() or Call(Minimap, "IsVisible", Minimap) ~= true then return Clear() end
	local mapID = PlayerMap()
	if not mapID then return Clear() end
	if rowsMap ~= mapID then
		rows, rowsMap = Finder.GetResults(mapID), mapID
	end
	if #rows == 0 then return Clear() end
	local position = Call(C_Map, "GetPlayerMapPosition", mapID, "player")
	local px = type(position) == "table" and Number(position.x)
	local py = type(position) == "table" and Number(position.y)
	if not px or not py or px < 0 or px > 1 or py < 0 or py > 1 or (px == 0 and py == 0) then return Clear() end
	local w, h = Call(C_Map, "GetMapWorldSize", mapID)
	w, h = Number(w), Number(h)
	local width = Number(Call(Minimap, "GetWidth", Minimap))
	local height = Number(Call(Minimap, "GetHeight", Minimap))
	local radius, facing = Radius(), Facing()
	if not w or not h or w <= 0 or h <= 0 or not width or not height or width <= 0 or height <= 0
		or not radius or radius <= 0 or not facing then return Clear() end
	local half = math.min(width, height) / 2
	local size = math.max(4, math.min(10, Number(M.db.minimapDotSize) or 6))
	local limit = half - size / 2
	if limit <= 0 then return Clear() end
	local square = ns.IsMinimapSquare and Clean(ns.IsMinimapSquare()) == true
	local scale, cosF, sinF = half / radius, math.cos(facing), math.sin(facing)
	local count, seen = 0, {}
	for _, row in ipairs(rows) do
		local sx, sy = ns.MinimapProjection.Project((row.x - px) * w, (py - row.y) * h,
			cosF, sinF, scale, limit, square)
		local key = ("%d:%.6f:%.6f"):format(row.id, row.x, row.y)
		if sx and not seen[key] then
			seen[key] = true
			count = count + 1
			local pin = Pin(count)
			if pin.row ~= row then HideTooltip(pin) end
			pin.row = row
			pin:SetSize(size, size)
			pin:ClearAllPoints()
			pin:SetPoint("CENTER", Minimap, "CENTER", sx, sy)
			shown = math.max(shown, count)
			pin:Show()
		end
	end
	for i = count + 1, shown do
		HideTooltip(pins[i])
		pins[i].row = nil
		pins[i]:Hide()
	end
	shown = count
end

function Finder.UpdateMinimap()
	rowsMap = nil
	if Enabled() then
		driver:Show()
		Update()
	else
		driver:Hide()
		Clear()
	end
end

driver:SetScript("OnUpdate", function(_, delta)
	elapsed = elapsed + delta
	if elapsed < 0.1 then return end
	elapsed = 0
	Update()
end)
ns:On("TRAINER_FINDER_CHANGED", Finder.UpdateMinimap)
ns:On("MINIMAP_LAYOUT_CHANGED", Finder.UpdateMinimap)
for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "UNIT_FACTION" }) do
	ns:RegisterEvent(event, function(_, unit)
		if event ~= "UNIT_FACTION" or unit == "player" then Finder.UpdateMinimap() end
	end)
end
Minimap:HookScript("OnHide", Clear)
Minimap:HookScript("OnShow", Finder.UpdateMinimap)
