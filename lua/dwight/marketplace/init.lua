-- dwight/marketplace/init.lua
-- Skill marketplace: project templates, community skill registry, auto-suggest.

local M = {}

local detect = require("dwight.marketplace.detect")
local packs = require("dwight.marketplace.packs")
local matching = require("dwight.marketplace.matching")
local install = require("dwight.marketplace.install")
local transfer = require("dwight.marketplace.transfer")
local suggest = require("dwight.marketplace.suggest")
local browse = require("dwight.marketplace.browse")

-- Re-export detect
M.DETECTORS = detect.DETECTORS
M.detect_project_type = detect.detect_project_type

-- Re-export packs
M.PACKS = packs.PACKS

-- Re-export matching
M.suggest_packs = matching.suggest_packs

-- Re-export install
M.install_pack = install.install_pack
M.install_interactive = install.install_interactive

-- Re-export transfer
M.export_skills = transfer.export_skills
M.import_skills = transfer.import_skills

-- Re-export suggest
M.auto_suggest = suggest.auto_suggest

-- Re-export browse
M.browse = browse.browse

function M.run(target)
	if target == "install" then
		M.install_interactive()
	elseif target == "suggest" then
		M.auto_suggest()
	elseif target == "export" then
		M.export_skills()
	elseif target == "import" then
		vim.ui.input({ prompt = "Path to skill bundle JSON: ", completion = "file" }, function(path)
			if path and path ~= "" then
				M.import_skills(path)
			end
		end)
	elseif target == "detect" then
		local detected = M.detect_project_type()
		vim.notify(
			string.format(
				"[dwight] Detected: %s\n  Types: %s\n  Langs: %s",
				detected.primary,
				table.concat(detected.types, ", "),
				table.concat(detected.langs, ", ")
			),
			vim.log.levels.INFO
		)
	else
		M.browse()
	end
end

return M
