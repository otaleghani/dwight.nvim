-- dwight/marketplace/matching.lua
-- Match project types to recommended skill packs.

local M = {}

--- Find packs matching the detected project types.
--- Returns { { pack, match_score }, ... } sorted by relevance.
function M.suggest_packs()
	local detect = require("dwight.marketplace.detect")
	local packs = require("dwight.marketplace.packs")
	local detected = detect.detect_project_type()
	local type_set = {}
	for _, t in ipairs(detected.types) do
		type_set[t] = true
	end

	local matches = {}
	for _, pack in ipairs(packs.PACKS) do
		local score = 0
		for _, pt in ipairs(pack.project_types) do
			if type_set[pt] then
				score = score + 1
			end
		end
		if score > 0 then
			matches[#matches + 1] = { pack = pack, score = score }
		end
	end

	table.sort(matches, function(a, b)
		return a.score > b.score
	end)
	return matches, detected
end

--- Get skills already installed.
function M.installed_skills()
	local ok, skills = pcall(function()
		return require("dwight.skills").names()
	end)
	return ok and skills or {}
end

return M
