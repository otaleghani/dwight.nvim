-- dwight/bootstrap/init.lua
-- Re-exports the exact same public API as the original bootstrap.lua module.

local M = {}

--------------------------------------------------------------------
-- Re-exported from scan.lua
--------------------------------------------------------------------

function M.scan()
	local scan_mod = require("dwight.bootstrap.scan")
	return scan_mod.scan()
end

--------------------------------------------------------------------
-- Re-exported from coverage.lua
--------------------------------------------------------------------

function M.coverage()
	local coverage_mod = require("dwight.bootstrap.coverage")
	return coverage_mod.coverage()
end

function M.show_coverage()
	local coverage_mod = require("dwight.bootstrap.coverage")
	return coverage_mod.show_coverage()
end

--------------------------------------------------------------------
-- Re-exported from generate.lua
--------------------------------------------------------------------

function M.generate(callback)
	local generate_mod = require("dwight.bootstrap.generate")
	return generate_mod.generate(callback)
end

function M._run_bootstrap()
	local generate_mod = require("dwight.bootstrap.generate")
	return generate_mod._run_bootstrap()
end

--------------------------------------------------------------------
-- Re-exported from agentic.lua
--------------------------------------------------------------------

function M._run_bootstrap_agentic()
	local agentic_mod = require("dwight.bootstrap.agentic")
	return agentic_mod._run_bootstrap_agentic()
end

--------------------------------------------------------------------
-- Re-exported from incremental.lua
--------------------------------------------------------------------

function M._run_bootstrap_incremental()
	local incremental_mod = require("dwight.bootstrap.incremental")
	return incremental_mod._run_bootstrap_incremental()
end

function M._run_bootstrap_incremental_agentic()
	local incremental_mod = require("dwight.bootstrap.incremental")
	return incremental_mod._run_bootstrap_incremental_agentic()
end

--------------------------------------------------------------------
-- bootstrap + _pick_mode orchestrators (kept in init.lua)
--------------------------------------------------------------------

function M.bootstrap(opts)
	opts = opts or {}
	local project = require("dwight.project")
	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first to create .dwight/.", vim.log.levels.WARN)
		return
	end

	-- Incremental mode: skip the "already has pragmas" warning, it's the point
	if opts.incremental then
		local cov = M.coverage()
		if cov.untagged_files == 0 then
			vim.notify(
				string.format(
					"[dwight] Full coverage! All %d source files are tagged (%d features).",
					cov.total_files,
					#cov.features
				),
				vim.log.levels.INFO
			)
			return
		end
		vim.notify(
			string.format(
				"[dwight] Pragma coverage: %d/%d files (%.0f%%) -- %d untagged\n" .. "   Features: %s",
				cov.tagged_files,
				cov.total_files,
				cov.coverage_pct,
				cov.untagged_files,
				#cov.features > 0 and table.concat(cov.features, ", ") or "(none)"
			),
			vim.log.levels.INFO
		)
		M._pick_mode(opts)
		return
	end

	-- Check if project already has pragmas
	local features = require("dwight.features")
	local existing = features.names()
	if #existing > 0 and not opts.force then
		-- Suggest incremental instead
		local cov = M.coverage()
		require("dwight.select").pick({
			string.format("Incremental -- tag %d untagged files (keep existing)", cov.untagged_files),
			"Full re-bootstrap (may duplicate pragmas)",
			"Cancel",
		}, {
			prompt = string.format(
				"Project has %d feature(s) (%d/%d files tagged). What to do?",
				#existing,
				cov.tagged_files,
				cov.total_files
			),
		}, function(choice)
			if not choice or choice:match("Cancel") then
				return
			end
			if choice:match("Incremental") then
				opts.incremental = true
				M._pick_mode(opts)
			else
				opts.force = true
				M._pick_mode(opts)
			end
		end)
		return
	end

	M._pick_mode(opts)
end

--- Let user choose bootstrap mode.
function M._pick_mode(opts)
	if opts and opts.mode then
		if opts.mode == "agentic" then
			if opts.incremental then
				M._run_bootstrap_incremental_agentic()
			else
				M._run_bootstrap_agentic()
			end
		else
			if opts.incremental then
				M._run_bootstrap_incremental()
			else
				M._run_bootstrap()
			end
		end
		return
	end

	local choices = opts.incremental
			and {
				"Agentic incremental (reads code, comprehensive -- recommended)",
				"Quick incremental (directory scan only, faster but shallower)",
			}
		or {
			"Agentic (reads code, comprehensive -- recommended)",
			"Quick (directory scan only, faster but shallower)",
		}

	require("dwight.select").pick(choices, {
		prompt = "Bootstrap mode:",
	}, function(choice)
		if not choice then
			return
		end
		if choice:match("Agentic") then
			if opts.incremental then
				M._run_bootstrap_incremental_agentic()
			else
				M._run_bootstrap_agentic()
			end
		else
			if opts.incremental then
				M._run_bootstrap_incremental()
			else
				M._run_bootstrap()
			end
		end
	end)
end

return M
