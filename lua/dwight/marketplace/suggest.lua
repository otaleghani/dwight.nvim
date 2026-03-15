-- dwight/marketplace/suggest.lua
-- Auto-suggest skill packs based on project type.

local M = {}

--- Suggest and optionally install packs for the current project.
--- Called after :DwightInit to recommend relevant skills.
function M.auto_suggest()
	local matching = require("dwight.marketplace.matching")
	local install = require("dwight.marketplace.install")
	local matches, detected = matching.suggest_packs()
	if #matches == 0 then
		return
	end

	local already = matching.installed_skills()
	local already_set = {}
	for _, n in ipairs(already) do
		already_set[n] = true
	end

	-- Filter to packs that have at least one new skill
	local new_matches = {}
	for _, m in ipairs(matches) do
		local has_new = false
		for _, skill in ipairs(m.pack.skills) do
			if not already_set[skill.name] then
				has_new = true
				break
			end
		end
		if has_new then
			new_matches[#new_matches + 1] = m
		end
	end

	if #new_matches == 0 then
		return
	end

	-- Build suggestion
	local parts = { string.format("[dwight] 💡 Detected: %s", table.concat(detected.langs, ", ")) }
	parts[#parts + 1] = "  Recommended skill packs:"
	local items = {}
	for _, m in ipairs(new_matches) do
		local skill_names = {}
		for _, s in ipairs(m.pack.skills) do
			local tag = already_set[s.name] and " (installed)" or ""
			skill_names[#skill_names + 1] = "@" .. s.name .. tag
		end
		parts[#parts + 1] = string.format("    📦 %s — %s", m.pack.display, table.concat(skill_names, ", "))
		items[#items + 1] = string.format("📦 %s — %s", m.pack.display, m.pack.description)
	end

	vim.notify(table.concat(parts, "\n"), vim.log.levels.INFO)

	-- Offer to install
	items[#items + 1] = "Install all recommended"
	items[#items + 1] = "Skip"

	vim.defer_fn(function()
		require("dwight.select").pick(items, {
			prompt = "Install recommended skill packs?",
		}, function(choice, idx)
			if not choice or choice == "Skip" then
				return
			end
			if choice == "Install all recommended" then
				for _, m in ipairs(new_matches) do
					install.install_pack(m.pack.name)
				end
			elseif idx and idx <= #new_matches then
				install.install_pack(new_matches[idx].pack.name)
			end
		end)
	end, 500)
end

return M
