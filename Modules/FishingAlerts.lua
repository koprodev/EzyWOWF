local _, ns = ...
local M = ns.modules.Fishing
local warned = {}

ns:On("FISHING_UPDATED", function()
	local db = M.db
	if not db or not db.alerts or not (db.announceWarnings or db.warningSound) then return end
	local state = M:GetFishingState()
	if not state.preparing then return end
	local known = {
		pole_missing = true, bag_low = state.freeSlots ~= nil,
		skill_capped = state.skill ~= nil and state.skillMax ~= nil,
		lure_expiring = not state.pole or (state.enchantKnown and (not state.enchanted or state.lureRemaining ~= nil)),
		lure_missing = not state.pole or state.enchantKnown,
		lure_unregistered = state.bagsKnown, lure_low = state.bagsKnown,
	}
	local current, fresh = {}, {}
	for _, warning in ipairs(M:GetPreparationWarnings()) do
		current[warning.key] = true
		if not warned[warning.key] then fresh[#fresh + 1] = warning.text; warned[warning.key] = true end
	end
	-- Unknown readings must not rearm a warning that has already been announced.
	for key in pairs(warned) do if known[key] and not current[key] then warned[key] = nil end end
	if #fresh == 0 then return end
	if db.announceWarnings then ns.Print("낚시 준비: " .. table.concat(fresh, " · ")) end
	if db.warningSound and type(PlaySound) == "function" and SOUNDKIT then
		local sound = SOUNDKIT.MAP_PING or SOUNDKIT.RAID_WARNING
		if sound then PlaySound(sound) end
	end
end)

ns:On("FISHING_RECORD_READY", function() warned = {} end)
