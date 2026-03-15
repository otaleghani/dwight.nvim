-- dwight/bootstrap/coverage.lua
-- Check pragma coverage across source files.

local M = {}

local SOURCE_EXT = {
	[".go"] = true,
	[".js"] = true,
	[".ts"] = true,
	[".jsx"] = true,
	[".tsx"] = true,
	[".py"] = true,
	[".lua"] = true,
	[".rb"] = true,
	[".rs"] = true,
	[".java"] = true,
	[".kt"] = true,
	[".cs"] = true,
	[".c"] = true,
	[".cpp"] = true,
	[".cc"] = true,
	[".h"] = true,
	[".hpp"] = true,
	[".swift"] = true,
	[".php"] = true,
	[".ex"] = true,
	[".exs"] = true,
	[".scala"] = true,
	[".hs"] = true,
	[".zig"] = true,
	[".ml"] = true,
	[".clj"] = true,
	[".r"] = true,
	[".R"] = true,
	[".sh"] = true,
	[".bash"] = true,
	[".dart"] = true,
	[".erl"] = true,
	[".vue"] = true,
	[".svelte"] = true,
}

M.SOURCE_EXT = SOURCE_EXT

--- Scan project and compute pragma coverage.
--- Returns { total_files, tagged_files, untagged_files, features, coverage_pct,
---           untagged = { "path/to/file.go", ... }, tagged = { "path/to/file.go", ... } }
function M.coverage()
	local cwd = vim.fn.getcwd()
	local uv = vim.loop or vim.uv
	local features = require("dwight.features")
	local scan_mod = require("dwight.bootstrap.scan")
	local SKIP_DIRS = scan_mod.SKIP_DIRS

	-- Collect all source files
	local all_source = {}
	local function walk_cov(dir, prefix)
		local handle = uv.fs_scandir(dir)
		if not handle then
			return
		end
		while true do
			local name, ftype = uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if name:sub(1, 1) ~= "." and not SKIP_DIRS[name] then
				local rel = prefix ~= "" and (prefix .. "/" .. name) or name
				local full = dir .. "/" .. name
				if ftype == "directory" then
					walk_cov(full, rel)
				elseif ftype == "file" then
					local ext = name:match("(%.[^.]+)$") or ""
					if SOURCE_EXT[ext] then
						-- Skip test files
						if
							not rel:match("_test%.")
							and not rel:match("%.test%.")
							and not rel:match("%.spec%.")
							and not rel:match("^test/")
							and not rel:match("^tests/")
							and not rel:match("__tests__/")
							and not rel:match("test_")
						then
							all_source[#all_source + 1] = rel
						end
					end
				end
			end
		end
	end
	walk_cov(cwd, "")
	table.sort(all_source)

	-- Check each file for pragma presence
	local tagged = {}
	local untagged = {}

	for _, rel in ipairs(all_source) do
		local f = io.open(cwd .. "/" .. rel, "r")
		local has_pragma = false
		if f then
			-- Only check first 5 lines (pragmas go at top)
			for _ = 1, 5 do
				local line = f:read("*l")
				if not line then
					break
				end
				if
					line:match("@feature:")
					or line:match("@project")
					or line:match("@stack")
					or line:match("@constraint")
					or line:match("@convention")
				then
					has_pragma = true
					break
				end
			end
			f:close()
		end

		if has_pragma then
			tagged[#tagged + 1] = rel
		else
			untagged[#untagged + 1] = rel
		end
	end

	local feature_names = features.names()
	local total = #all_source
	local pct = total > 0 and (#tagged / total * 100) or 0

	return {
		total_files = total,
		tagged_files = #tagged,
		untagged_files = #untagged,
		features = feature_names,
		coverage_pct = pct,
		tagged = tagged,
		untagged = untagged,
	}
end

--- Show coverage report.
function M.show_coverage()
	local cov = M.coverage()
	local lines = {
		string.format("Pragma Coverage: %d/%d files (%.0f%%)", cov.tagged_files, cov.total_files, cov.coverage_pct),
		string.format(
			"   Features: %d -- %s",
			#cov.features,
			#cov.features > 0 and table.concat(cov.features, ", ") or "(none)"
		),
	}

	if cov.untagged_files > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("   Untagged (%d):", cov.untagged_files)
		local max_show = math.min(cov.untagged_files, 20)
		for i = 1, max_show do
			lines[#lines + 1] = "     " .. cov.untagged[i]
		end
		if cov.untagged_files > max_show then
			lines[#lines + 1] = string.format("     ... and %d more", cov.untagged_files - max_show)
		end
		lines[#lines + 1] = ""
		lines[#lines + 1] = "   Run :DwightBootstrap --incremental to tag untagged files."
	else
		lines[#lines + 1] = "   Full coverage!"
	end

	vim.notify("[dwight]\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
