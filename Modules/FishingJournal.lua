local _, ns = ...
local M = ns.modules.Fishing
local Clean = ns.Clean
local record, journal, clockStart
local running, freshNext = false, true
local lootContext, castSerial, closedCastSerial = nil, 0, nil
local clearedSlots, castCaught, seenFishingLoot = {}, false, false
local itemNames = {}
local lastNamesSignature, lastSummary

local function Number(value)
	value = Clean(value)
	if type(value) == "number" and value == value and value >= 0 and value < math.huge then return value end
end

local function Integer(value)
	value = Number(value)
	if value and value == math.floor(value) then return value end
end

local function Now()
	if type(GetTime) ~= "function" then return end
	local ok, value = pcall(GetTime)
	if ok then return Number(value) end
end

local function Enabled(requirePreparation)
	if not (M.db and Clean(M.db.sessionStats) == true and type(M.GetFishingState) == "function") then return false end
	local ok, state = pcall(M.GetFishingState, M)
	state = ok and Clean(state) or nil
	if type(state) ~= "table" or Clean(state.active) ~= true then return false end
	return not requirePreparation or (Clean(state.preparing) == true
		and (Clean(state.pole) == true or Clean(state.channeling) == true))
end

local function Checkpoint()
	local now = Now()
	if running and journal and clockStart and now then
		journal.elapsed = journal.elapsed + math.max(0, now - clockStart)
		clockStart = now
	end
end

local function Elapsed()
	local elapsed = journal and journal.elapsed or 0
	local now = Now()
	if running and clockStart and now then elapsed = elapsed + math.max(0, now - clockStart) end
	return math.floor(elapsed)
end

local function ReadItemName(id)
	local getter = C_Item and C_Item.GetItemNameByID
	if type(getter) ~= "function" then getter = (C_Item and C_Item.GetItemInfo) or GetItemInfo end
	if type(getter) == "function" then
		local ok, name = pcall(getter, id)
		name = ok and Clean(name) or nil
		if type(name) == "string" and name ~= "" then return name end
	end
	return itemNames[id] or ("아이템 #%d"):format(id)
end

local function SortedItems()
	local entries = {}
	for id, count in pairs(journal and journal.itemcounts or {}) do
		entries[#entries + 1] = { id = id, count = count, name = ReadItemName(id) }
	end
	table.sort(entries, function(a, b)
		if a.name == b.name then return a.id < b.id end
		return a.name < b.name
	end)
	return entries
end

local function NamesSignature()
	local names = {}
	for _, entry in ipairs(SortedItems()) do names[#names + 1] = entry.id .. ":" .. entry.name end
	return table.concat(names, "\n")
end

local function ItemsText()
	local entries = SortedItems()
	if #entries == 0 then return "획득한 아이템이 아직 없어요." end
	local lines = {}
	for i = 1, math.min(5, #entries) do
		local entry = entries[i]
		lines[#lines + 1] = ("%s × %d"):format(entry.name, entry.count)
	end
	if #entries > 5 then lines[#lines + 1] = ("외 %d종"):format(#entries - 5) end
	return table.concat(lines, "\n")
end

local function RebuildItems()
	lastNamesSignature = NamesSignature()
	lastSummary = M:GetSessionSummary()
	ns:Fire("REBUILD_OPTIONS")
end

local function RefreshSummary()
	local summary = M:GetSessionSummary()
	if summary ~= lastSummary then lastSummary = summary; ns:Fire("REFRESH_UI") end
end

local function NewJournal(finished)
	journal = { elapsed = 0, casts = 0, catches = 0, itemcounts = {}, finished = finished == true }
	if record then record.fishingSession = journal end
	itemNames = {}
end

local function Pause()
	Checkpoint()
	running, clockStart, lootContext = false, nil, nil
end

function M:GetSessionSummary()
	local seconds = Elapsed()
	local duration
	if seconds >= 3600 then
		duration = ("%d:%02d:%02d"):format(math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
	else
		duration = ("%02d:%02d"):format(math.floor(seconds / 60), seconds % 60)
	end
	local count = 0
	for _, quantity in pairs(journal and journal.itemcounts or {}) do count = count + quantity end
	return ("이번 낚시 %s · 던지기 %d회 · 어획 %d회 · 획득 %d개"):format(
		duration, journal and journal.casts or 0, journal and journal.catches or 0, count)
end

function M:GetSessionItemsText()
	return ItemsText()
end

function M:ResetFishingSession()
	if not record then return false end
	local wasRunning = running and Enabled(true)
	local wasClosed = closedCastSerial == castSerial
	local pendingLoot = wasRunning and not wasClosed and lootContext
	if pendingLoot and pendingLoot.castSerial ~= castSerial then pendingLoot = nil end
	NewJournal(not wasRunning)
	running, clockStart = wasRunning, wasRunning and Now() or nil
	freshNext, lootContext = not wasRunning, pendingLoot or nil
	castSerial = castSerial + 1
	if lootContext then lootContext.castSerial = castSerial end
	closedCastSerial = wasClosed and castSerial or nil
	castCaught = false
	RebuildItems()
	return true
end

ns:On("FISHING_RECORD_READY", function(value)
	value = Clean(value)
	if type(value) ~= "table" then record, journal = nil, nil; Pause(); return end
	Pause()
	record = value
	local saved = Clean(record.fishingSession)
	if type(saved) ~= "table" then
		NewJournal(true)
	else
		local counts = {}
		local savedCounts = Clean(saved.itemcounts)
		if type(savedCounts) == "table" then
			for key, quantity in pairs(savedCounts) do
				key = Clean(key)
				local id = Integer(type(key) == "string" and tonumber(key) or key)
				quantity = Integer(quantity)
				if id and id > 0 and quantity and quantity > 0 then counts[id] = (counts[id] or 0) + quantity end
			end
		end
		journal = { elapsed = Number(saved.elapsed) or 0, casts = Integer(saved.casts) or 0,
			catches = Integer(saved.catches) or 0, itemcounts = counts, finished = Clean(saved.finished) == true }
		record.fishingSession = journal
		itemNames = {}
	end
	running, clockStart, lootContext = false, nil, nil
	freshNext = journal.finished
	castSerial = castSerial + 1
	closedCastSerial = nil
	clearedSlots, castCaught, seenFishingLoot = {}, false, false
	RebuildItems()
end)

ns:On("FISHING_CAST_STARTED", function()
	if not (journal and Enabled(true)) then return end
	if freshNext then NewJournal(false); RebuildItems() else Checkpoint() end
	journal.finished, freshNext = false, false
	journal.casts = journal.casts + 1
	if not running then clockStart = Now() end
	running = true
	castSerial, lootContext = castSerial + 1, nil
	closedCastSerial = nil
	clearedSlots, castCaught, seenFishingLoot = {}, false, false
	RefreshSummary()
end)

ns:On("FISHING_SESSION_FINISHED", function()
	Pause()
	if journal then journal.finished = true end
	freshNext = true
	RefreshSummary()
end)

ns:On("FISHING_SESSION_PAUSED", function() Pause(); RefreshSummary() end)
ns:On("FISHING_UPDATED", function()
	if not Enabled(true) then Pause() else Checkpoint() end
	RefreshSummary()
end)

local function ReadSlot(slot)
	local ok, link = pcall(GetLootSlotLink, slot)
	link = ok and Clean(link) or nil
	if type(link) ~= "string" then return end
	local id = Integer(tonumber(link:match("item:(%d+)")))
	if not id or id <= 0 then return end
	local read, texture, name, quantity, currencyID = pcall(GetLootSlotInfo, slot)
	if type(issecretvalue) == "function" and (issecretvalue(texture) or issecretvalue(name)
		or issecretvalue(quantity) or issecretvalue(currencyID)) then return end
	texture, name, quantity, currencyID = Clean(texture), Clean(name), Integer(quantity), Clean(currencyID)
	if not read or not texture or type(name) ~= "string" or name == "" or not quantity or quantity <= 0 then return end
	if currencyID ~= nil then
		local currency = Number(currencyID)
		if not currency or currency > 0 then return end
	end
	if type(GetLootSlotType) == "function" then
		local checked, slotType = pcall(GetLootSlotType, slot)
		local itemType = Enum and Enum.LootSlotType and Enum.LootSlotType.Item or 1
		if not checked or Clean(slotType) ~= itemType then return end
	end
	return { id = id, quantity = quantity, name = name }
end

local function Snapshot()
	if not (journal and running and Enabled(true)) then lootContext = nil; return end
	if closedCastSerial == castSerial then return end
	if not (type(IsFishingLoot) == "function" and type(GetNumLootItems) == "function"
		and type(GetLootSlotLink) == "function" and type(GetLootSlotInfo) == "function") then lootContext = nil; return end
	local ok, fishing = pcall(IsFishingLoot)
	if not ok or Clean(fishing) ~= true then lootContext = nil; return end
	seenFishingLoot = true
	local counted, count = pcall(GetNumLootItems)
	count = counted and Integer(count) or nil
	if not count then lootContext = nil; return end
	local context = lootContext
	if not context or context.castSerial ~= castSerial then
		context = { castSerial = castSerial, slots = {} }
		lootContext = context
	end
	for slot in pairs(context.slots) do if slot > count then context.slots[slot] = nil end end
	for slot = 1, count do
		local entry = ReadSlot(slot)
		if entry and not clearedSlots[slot] then
			context.slots[slot] = entry
		else
			context.slots[slot] = nil
		end
	end
end

ns:RegisterEvent("LOOT_READY", Snapshot, true)
ns:RegisterEvent("LOOT_OPENED", Snapshot, true)
ns:RegisterEvent("LOOT_CLOSED", function()
	if seenFishingLoot then closedCastSerial = castSerial end
	lootContext = nil
end)
ns:RegisterEvent("LOOT_SLOT_CLEARED", function(_, slot)
	slot = Integer(slot)
	local context = lootContext
	if not (slot and context and context.castSerial == castSerial and journal and running and Enabled(true)) then return end
	local entry = context.slots[slot]
	if not entry then return end
	-- Consume the candidate before callbacks can deliver another clear event.
	context.slots[slot] = nil
	clearedSlots[slot] = true
	local newItem = journal.itemcounts[entry.id] == nil
	journal.itemcounts[entry.id] = (journal.itemcounts[entry.id] or 0) + entry.quantity
	itemNames[entry.id] = entry.name
	if not castCaught then journal.catches = journal.catches + 1; castCaught = true end
	if newItem then RebuildItems() else RefreshSummary() end
end)

ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, id, success)
	id = Integer(id)
	if not (id and journal and journal.itemcounts[id] and Clean(success) == true) then return end
	local signature = NamesSignature()
	if signature ~= lastNamesSignature then lastNamesSignature = signature; ns:Fire("REBUILD_OPTIONS") end
end)
