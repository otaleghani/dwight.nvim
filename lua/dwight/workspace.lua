-- dwight/workspace.lua
-- Multi-repo workspace: register repos, cross-repo features, unified issues.
-- Stores workspace config in ~/.local/share/dwight/workspace.json (global)
-- or .dwight/workspace.json (per-project, for monorepos).
--
-- :DwightWorkspace          — show workspace status
-- :DwightWorkspaceAdd       — register a repo
-- :DwightWorkspaceRemove    — unregister a repo
-- :DwightWorkspaceIssues    — unified issue view across repos
-- :DwightWorkspaceFeatures  — cross-repo feature map

local M = {}

local api = vim.api
local uv = vim.loop or vim.uv
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Workspace file paths
--------------------------------------------------------------------

local function global_workspace_dir()
	return vim.fn.stdpath("data") .. "/dwight"
end

local function global_workspace_file()
	return global_workspace_dir() .. "/workspace.json"
end

local function local_workspace_file()
	return vim.fn.getcwd() .. "/.dwight/workspace.json"
end

--- Determine which workspace file to use.
--- Prefers local (.dwight/workspace.json) if it exists, else global.
local function workspace_file()
	local local_path = local_workspace_file()
	if vim.fn.filereadable(local_path) == 1 then
		return local_path
	end
	return global_workspace_file()
end

--------------------------------------------------------------------
-- Workspace CRUD
--------------------------------------------------------------------

--- Read the workspace config.
--- Returns { repos = { { path, name, remote, default_branch }, ... }, created }
function M.read()
	local path = workspace_file()
	local f = io.open(path, "r")
	if not f then
		return { repos = {} }
	end
	local raw = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, raw)
	if ok and type(data) == "table" then
		return data
	end
	return { repos = {} }
end

--- Write the workspace config.
function M.write(ws)
	local path = workspace_file()
	local dir = vim.fn.fnamemodify(path, ":h")
	vim.fn.mkdir(dir, "p")
	local f = io.open(path, "w")
	if f then
		f:write(vim.json.encode(ws) .. "\n")
		f:close()
	end
end

--- List registered repos.
--- Returns { { path, name, remote, default_branch }, ... }
function M.repos()
	local ws = M.read()
	return ws.repos or {}
end

--- Add a repo to the workspace.
--- Detects name and remote from git.
function M.add(repo_path, opts)
	opts = opts or {}
	repo_path = vim.fn.fnamemodify(repo_path, ":p"):gsub("/$", "")

	-- Validate it's a git repo
	local git_dir = repo_path .. "/.git"
	if vim.fn.isdirectory(git_dir) ~= 1 and vim.fn.filereadable(git_dir) ~= 1 then
		vim.notify("[dwight] Not a git repo: " .. repo_path, vim.log.levels.ERROR)
		return false
	end

	-- Detect name from directory
	local name = opts.name or repo_path:match("([^/]+)$") or "unknown"

	-- Detect remote
	local remote = nil
	local handle = io.popen("git -C " .. vim.fn.shellescape(repo_path) .. " remote get-url origin 2>/dev/null")
	if handle then
		remote = vim.trim(handle:read("*a") or "")
		handle:close()
		if remote == "" then
			remote = nil
		end
	end

	-- Detect default branch
	local default_branch = nil
	handle =
		io.popen("git -C " .. vim.fn.shellescape(repo_path) .. " symbolic-ref refs/remotes/origin/HEAD 2>/dev/null")
	if handle then
		local ref = vim.trim(handle:read("*a") or "")
		handle:close()
		default_branch = ref:match("refs/remotes/origin/(.+)")
	end
	if not default_branch then
		default_branch = "main"
	end

	-- Detect GitHub owner/repo
	local gh_repo = nil
	if remote then
		local owner, rname = remote:match("github%.com[:/]([%w%-%.]+)/([%w%-%.]+)")
		if owner and rname then
			gh_repo = owner .. "/" .. rname:gsub("%.git$", "")
		end
	end

	-- Check for dwight initialization
	local has_dwight = vim.fn.isdirectory(repo_path .. "/.dwight") == 1

	local ws = M.read()
	ws.repos = ws.repos or {}

	-- Check for duplicates
	for i, r in ipairs(ws.repos) do
		if r.path == repo_path then
			-- Update existing
			ws.repos[i] = {
				path = repo_path,
				name = name,
				remote = remote,
				gh_repo = gh_repo,
				default_branch = default_branch,
				has_dwight = has_dwight,
			}
			M.write(ws)
			vim.notify(string.format("[dwight] Updated repo: %s (%s)", name, repo_path), vim.log.levels.INFO)
			return true
		end
	end

	ws.repos[#ws.repos + 1] = {
		path = repo_path,
		name = name,
		remote = remote,
		gh_repo = gh_repo,
		default_branch = default_branch,
		has_dwight = has_dwight,
	}
	if not ws.created then
		ws.created = os.date("%Y-%m-%dT%H:%M:%S")
	end
	M.write(ws)

	vim.notify(
		string.format("[dwight] ✅ Added repo: %s (%s)%s", name, repo_path, gh_repo and " → " .. gh_repo or ""),
		vim.log.levels.INFO
	)
	return true
end

--- Remove a repo from the workspace by name or path.
function M.remove(identifier)
	local ws = M.read()
	ws.repos = ws.repos or {}
	local removed = false

	for i = #ws.repos, 1, -1 do
		local r = ws.repos[i]
		if r.name == identifier or r.path == identifier or r.gh_repo == identifier then
			table.remove(ws.repos, i)
			removed = true
		end
	end

	if removed then
		M.write(ws)
		vim.notify("[dwight] Removed repo: " .. identifier, vim.log.levels.INFO)
	else
		vim.notify("[dwight] Repo not found: " .. identifier, vim.log.levels.WARN)
	end
	return removed
end

--- Ensure the current repo is in the workspace.
function M.ensure_current()
	local cwd = vim.fn.getcwd()
	local repos = M.repos()
	for _, r in ipairs(repos) do
		if r.path == cwd then
			return true
		end
	end
	-- Auto-add current if it's a git repo
	if vim.fn.isdirectory(cwd .. "/.git") == 1 then
		return M.add(cwd)
	end
	return false
end

--------------------------------------------------------------------
-- Cross-repo feature scanning
--------------------------------------------------------------------

--- Scan features across all workspace repos.
--- Returns { { repo_name, repo_path, features = { { name, file_count, description }, ... } }, ... }
function M.scan_features()
	local repos = M.repos()
	local results = {}

	for _, repo in ipairs(repos) do
		local repo_features = {}
		local dwight_exists = vim.fn.isdirectory(repo.path .. "/.dwight") == 1

		if dwight_exists then
			-- Scan pragma files in the repo
			local feature_map = {}
			local function scan_dir(dir, prefix)
				local handle = uv.fs_scandir(dir)
				if not handle then
					return
				end
				while true do
					local name, ftype = uv.fs_scandir_next(handle)
					if not name then
						break
					end
					if
						name:sub(1, 1) == "."
						or name == "node_modules"
						or name == "vendor"
						or name == ".git"
						or name == "dist"
						or name == "build"
					then
						goto continue
					end
					local rel = prefix ~= "" and (prefix .. "/" .. name) or name
					local full = dir .. "/" .. name
					if ftype == "directory" then
						scan_dir(full, rel)
					elseif ftype == "file" then
						local ext = name:match("(%.[^.]+)$") or ""
						if
							ext:match("^%.[a-z]+$")
							and not ext:match("%.json$")
							and not ext:match("%.ya?ml$")
							and not ext:match("%.toml$")
						then
							local f = io.open(full, "r")
							if f then
								for _ = 1, 5 do
									local line = f:read("*l")
									if not line then
										break
									end
									local feat_name = line:match("@feature:([%w_%-]+)")
									if feat_name then
										if not feature_map[feat_name] then
											-- Extract description
											local desc = line:gsub("@feature:[%w_%-]+", "")
											desc = desc:gsub("^[/%*#%-;%%%(]+%s*", ""):gsub("%s*[%*/)%-;%%]+$", "")
											desc = vim.trim(desc)
											feature_map[feat_name] =
												{ name = feat_name, files = {}, description = desc }
										end
										feature_map[feat_name].files[#feature_map[feat_name].files + 1] = rel
										break
									end
								end
								f:close()
							end
						end
					end
					::continue::
				end
			end
			scan_dir(repo.path, "")

			for _, feat in pairs(feature_map) do
				repo_features[#repo_features + 1] = {
					name = feat.name,
					file_count = #feat.files,
					description = feat.description,
					files = feat.files,
				}
			end
			table.sort(repo_features, function(a, b)
				return a.name < b.name
			end)
		end

		results[#results + 1] = {
			repo_name = repo.name,
			repo_path = repo.path,
			gh_repo = repo.gh_repo,
			has_dwight = dwight_exists,
			features = repo_features,
		}
	end

	return results
end

--- Find features with the same name across repos (shared/cross-cutting concerns).
--- Returns { { feature_name, repos = { { repo_name, file_count }, ... } }, ... }
function M.cross_repo_features()
	local scan = M.scan_features()
	local feature_repos = {} -- feature_name → { { repo_name, file_count }, ... }

	for _, repo_result in ipairs(scan) do
		for _, feat in ipairs(repo_result.features) do
			if not feature_repos[feat.name] then
				feature_repos[feat.name] = {}
			end
			feature_repos[feat.name][#feature_repos[feat.name] + 1] = {
				repo_name = repo_result.repo_name,
				repo_path = repo_result.repo_path,
				file_count = feat.file_count,
				description = feat.description,
			}
		end
	end

	-- Filter to features that appear in 2+ repos
	local cross = {}
	for name, repos in pairs(feature_repos) do
		if #repos >= 2 then
			cross[#cross + 1] = { feature_name = name, repos = repos }
		end
	end
	table.sort(cross, function(a, b)
		return #a.repos > #b.repos
	end)

	return cross
end

--------------------------------------------------------------------
-- Unified issue view across repos
--------------------------------------------------------------------

--- Fetch issues from all GitHub repos in the workspace.
--- callback(results) where results = { { repo_name, gh_repo, issues = {...} }, ... }
function M.fetch_all_issues(opts, callback)
	opts = opts or {}
	local repos = M.repos()
	local gh_repos = {}

	for _, r in ipairs(repos) do
		if r.gh_repo then
			gh_repos[#gh_repos + 1] = r
		end
	end

	if #gh_repos == 0 then
		callback({})
		return
	end

	local results = {}
	local pending = #gh_repos
	local gh = require("dwight.github")

	for _, repo in ipairs(gh_repos) do
		local list_opts = {
			repo = repo.gh_repo,
			label = opts.label,
			assignee = opts.assignee,
			milestone = opts.milestone,
			limit = opts.limit or 15, -- lower per-repo limit for unified view
			state = opts.state or "open",
		}

		gh.list_issues(list_opts, function(issues, err)
			if issues then
				results[#results + 1] = {
					repo_name = repo.name,
					gh_repo = repo.gh_repo,
					repo_path = repo.path,
					issues = issues,
				}
			elseif err then
				results[#results + 1] = {
					repo_name = repo.name,
					gh_repo = repo.gh_repo,
					repo_path = repo.path,
					issues = {},
					error = err,
				}
			end

			pending = pending - 1
			if pending == 0 then
				table.sort(results, function(a, b)
					return a.repo_name < b.repo_name
				end)
				callback(results)
			end
		end)
	end
end

--------------------------------------------------------------------
-- Interactive commands
--------------------------------------------------------------------

--- Show workspace status.
function M.status()
	local repos = M.repos()

	if #repos == 0 then
		vim.notify(
			"[dwight] No repos in workspace. Use :DwightWorkspaceAdd to register repos.\n"
				.. "Current directory will be auto-added if it's a git repo.",
			vim.log.levels.INFO
		)
		M.ensure_current()
		repos = M.repos()
		if #repos == 0 then
			return
		end
	end

	local lines = {
		"╔══════════════════════════════════════════════════════════════╗",
		"║  Dwight Workspace                                           ║",
		"╚══════════════════════════════════════════════════════════════╝",
		"",
		string.format("  Repos: %d", #repos),
		"",
	}

	for _, r in ipairs(repos) do
		local current = r.path == vim.fn.getcwd() and " ◀ current" or ""
		local gh = r.gh_repo and (" → " .. r.gh_repo) or ""
		local dwight = r.has_dwight and " ✓dwight" or ""
		lines[#lines + 1] = string.format("  📦 %s%s%s%s", r.name, gh, dwight, current)
		lines[#lines + 1] = string.format("     %s", r.path)
	end

	-- Cross-repo features
	local cross = M.cross_repo_features()
	if #cross > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "  ─── Cross-repo Features ───"
		for _, cf in ipairs(cross) do
			local repo_names = {}
			for _, r in ipairs(cf.repos) do
				repo_names[#repo_names + 1] = r.repo_name
			end
			lines[#lines + 1] = string.format("  🔗 $%s — %s", cf.feature_name, table.concat(repo_names, ", "))
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "  ─── Actions ───"
	lines[#lines + 1] = "  :DwightWorkspaceAdd <path>      Add a repo"
	lines[#lines + 1] = "  :DwightWorkspaceRemove <name>   Remove a repo"
	lines[#lines + 1] = "  :DwightWorkspaceIssues          Unified issue view"
	lines[#lines + 1] = "  :DwightWorkspaceFeatures        Cross-repo feature map"

	vim.notify("[dwight]\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Interactive add: browse for directory or accept argument.
function M.add_interactive(path)
	if path and path ~= "" then
		M.add(path)
		return
	end

	-- Offer common options
	local cwd = vim.fn.getcwd()
	local parent = vim.fn.fnamemodify(cwd, ":h")

	-- Scan sibling directories (common for microservice setups)
	local siblings = {}
	local handle = uv.fs_scandir(parent)
	if handle then
		while true do
			local name, ftype = uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if ftype == "directory" and name:sub(1, 1) ~= "." then
				local sib_path = parent .. "/" .. name
				if vim.fn.isdirectory(sib_path .. "/.git") == 1 then
					-- Check if already registered
					local already = false
					for _, r in ipairs(M.repos()) do
						if r.path == sib_path then
							already = true
							break
						end
					end
					if not already then
						siblings[#siblings + 1] = { name = name, path = sib_path }
					end
				end
			end
		end
	end

	if #siblings == 0 then
		vim.ui.input({ prompt = "📦 Repo path to add: ", default = cwd }, function(input)
			if input and input ~= "" then
				M.add(input)
			end
		end)
		return
	end

	local items = {}
	for _, s in ipairs(siblings) do
		items[#items + 1] = string.format("📦 %s — %s", s.name, s.path)
	end
	items[#items + 1] = "📂 Enter path manually…"

	require("dwight.select").pick(items, {
		prompt = "Add repo to workspace:",
	}, function(choice, idx)
		if not choice then
			return
		end
		if idx and idx <= #siblings then
			M.add(siblings[idx].path)
		else
			vim.ui.input({ prompt = "📦 Repo path: " }, function(input)
				if input and input ~= "" then
					M.add(input)
				end
			end)
		end
	end)
end

--- Interactive remove.
function M.remove_interactive(name)
	if name and name ~= "" then
		M.remove(name)
		return
	end

	local repos = M.repos()
	if #repos == 0 then
		vim.notify("[dwight] No repos in workspace.", vim.log.levels.INFO)
		return
	end

	local items = {}
	for _, r in ipairs(repos) do
		items[#items + 1] = string.format("📦 %s — %s", r.name, r.path)
	end

	require("dwight.select").pick(items, {
		prompt = "Remove which repo?",
	}, function(choice)
		if choice then
			local name_match = choice:match("^📦 (%S+)")
			if name_match then
				M.remove(name_match)
			end
		end
	end)
end

--- Show cross-repo feature map.
function M.show_features()
	M.ensure_current()
	local scan = M.scan_features()

	if #scan == 0 then
		vim.notify("[dwight] No repos in workspace.", vim.log.levels.INFO)
		return
	end

	local lines = {
		"╔══════════════════════════════════════════════════════════════╗",
		"║  Workspace Feature Map                                       ║",
		"╚══════════════════════════════════════════════════════════════╝",
		"",
	}

	local total_features = 0
	for _, repo_result in ipairs(scan) do
		local marker = repo_result.has_dwight and "" or " (no .dwight)"
		lines[#lines + 1] =
			string.format("  📦 %s%s — %d features", repo_result.repo_name, marker, #repo_result.features)

		if #repo_result.features > 0 then
			for _, feat in ipairs(repo_result.features) do
				local desc = feat.description ~= "" and (" — " .. feat.description) or ""
				lines[#lines + 1] = string.format("     $%-20s %d files%s", feat.name, feat.file_count, desc:sub(1, 40))
				total_features = total_features + 1
			end
		else
			lines[#lines + 1] = "     (no features — run :DwightBootstrap in this repo)"
		end
		lines[#lines + 1] = ""
	end

	-- Cross-repo features
	local cross = M.cross_repo_features()
	if #cross > 0 then
		lines[#lines + 1] = "  ─── Shared Features (appear in 2+ repos) ───"
		lines[#lines + 1] = ""
		for _, cf in ipairs(cross) do
			lines[#lines + 1] = string.format("  🔗 $%s", cf.feature_name)
			for _, r in ipairs(cf.repos) do
				lines[#lines + 1] = string.format(
					"     %s: %d files — %s",
					r.repo_name,
					r.file_count,
					r.description ~= "" and r.description or "(no description)"
				)
			end
		end
		lines[#lines + 1] = ""
	end

	lines[#lines + 1] = string.format("  Total: %d features across %d repos", total_features, #scan)

	-- Display in buffer
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "dwight_features"

	vim.cmd("botright split")
	local win = api.nvim_get_current_win()
	api.nvim_win_set_buf(win, buf)
	api.nvim_win_set_height(win, math.min(#lines + 2, math.floor(vim.o.lines * 0.5)))

	vim.keymap.set("n", "q", function()
		local wins = api.nvim_tabpage_list_wins(0)
		if #wins <= 1 then
			vim.cmd("enew")
		else
			api.nvim_win_close(win, true)
		end
	end, { buffer = buf, desc = "Close" })
end

--- Unified issue view across all workspace repos.
function M.show_issues(opts)
	opts = opts or {}
	M.ensure_current()

	local repos = M.repos()
	local gh_repos = vim.tbl_filter(function(r)
		return r.gh_repo ~= nil
	end, repos)

	if #gh_repos == 0 then
		vim.notify("[dwight] No GitHub repos in workspace. Add repos with :DwightWorkspaceAdd.", vim.log.levels.WARN)
		return
	end

	vim.notify(string.format("[dwight] 📋 Fetching issues from %d repo(s)…", #gh_repos), vim.log.levels.INFO)

	M.fetch_all_issues(opts, function(results)
		-- Flatten all issues with repo context
		local all_issues = {}
		local errors = {}
		for _, r in ipairs(results) do
			if r.error then
				errors[#errors + 1] = r.repo_name .. ": " .. r.error
			end
			for _, issue in ipairs(r.issues) do
				all_issues[#all_issues + 1] = {
					issue = issue,
					repo_name = r.repo_name,
					gh_repo = r.gh_repo,
					repo_path = r.repo_path,
				}
			end
		end

		if #errors > 0 then
			vim.notify("[dwight] ⚠️ Errors: " .. table.concat(errors, "; "), vim.log.levels.WARN)
		end

		if #all_issues == 0 then
			vim.notify("[dwight] No open issues across workspace repos.", vim.log.levels.INFO)
			return
		end

		-- Sort by creation date (newest first)
		table.sort(all_issues, function(a, b)
			return (a.issue.createdAt or "") > (b.issue.createdAt or "")
		end)

		-- Try Telescope, fallback to select
		local has_tel, pickers = pcall(require, "telescope.pickers")
		if has_tel then
			M._show_issues_telescope(all_issues, pickers)
		else
			M._show_issues_fallback(all_issues)
		end
	end)
end

--- Telescope picker for unified issues.
function M._show_issues_telescope(all_issues, pickers)
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")
	local gh = require("dwight.github")

	pickers
		.new({}, {
			prompt_title = string.format("📋 Workspace Issues (%d)", #all_issues),
			finder = finders.new_table({
				results = all_issues,
				entry_maker = function(item)
					local issue = item.issue
					local labels = ""
					if issue.labels and #issue.labels > 0 then
						local names = {}
						for _, l in ipairs(issue.labels) do
							names[#names + 1] = type(l) == "table" and l.name or tostring(l)
						end
						labels = " [" .. table.concat(names, ", ") .. "]"
					end
					local assignee = ""
					if issue.assignees and #issue.assignees > 0 then
						local a = issue.assignees[1]
						assignee = " →@" .. (type(a) == "table" and a.login or tostring(a))
					end
					local display = string.format(
						"%-12s #%-5d %s%s%s",
						item.repo_name:sub(1, 12),
						issue.number,
						issue.title,
						assignee,
						labels
					)
					return {
						value = item,
						display = display,
						ordinal = string.format("%s %d %s", item.repo_name, issue.number, issue.title),
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Issue Preview",
				define_preview = function(self, entry)
					local item = entry.value
					local issue = item.issue
					local lines = {
						"# " .. item.repo_name .. " #" .. issue.number .. ": " .. (issue.title or ""),
						"",
						"**Repo:** " .. item.gh_repo,
					}
					if issue.labels and #issue.labels > 0 then
						local names = {}
						for _, l in ipairs(issue.labels) do
							names[#names + 1] = type(l) == "table" and l.name or tostring(l)
						end
						lines[#lines + 1] = "**Labels:** " .. table.concat(names, ", ")
					end
					if issue.assignees and #issue.assignees > 0 then
						local names = {}
						for _, a in ipairs(issue.assignees) do
							names[#names + 1] = "@" .. (type(a) == "table" and a.login or tostring(a))
						end
						lines[#lines + 1] = "**Assignees:** " .. table.concat(names, ", ")
					end
					local author = issue.author
					if type(author) == "table" then
						author = author.login
					end
					if author then
						lines[#lines + 1] = "**Author:** " .. author
					end
					if issue.createdAt then
						lines[#lines + 1] = "**Created:** " .. issue.createdAt:sub(1, 10)
					end
					lines[#lines + 1] = ""
					lines[#lines + 1] = "---"
					lines[#lines + 1] = ""
					if issue.body and issue.body ~= "" then
						for line in issue.body:gmatch("[^\n]*") do
							lines[#lines + 1] = line
						end
					else
						lines[#lines + 1] = "(no description)"
					end
					api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, _flatten(lines))
					vim.bo[self.state.bufnr].filetype = "markdown"
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				-- Enter: action picker for the issue
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						local item = entry.value
						-- Stamp repo on issue for cross-repo solve
						item.issue._repo = item.gh_repo
						gh._action_picker(item.issue)
					end
				end)
				return true
			end,
		})
		:find()
end

--- Fallback picker for unified issues.
function M._show_issues_fallback(all_issues)
	local items = {}
	for _, item in ipairs(all_issues) do
		items[#items + 1] = string.format("[%s] #%d: %s", item.repo_name, item.issue.number, item.issue.title)
	end

	require("dwight.select").pick(items, {
		prompt = "Workspace issues:",
	}, function(_, idx)
		if idx then
			local item = all_issues[idx]
			item.issue._repo = item.gh_repo
			require("dwight.github")._action_picker(item.issue)
		end
	end)
end

--- Initialize workspace from a monorepo layout.
--- Scans for sub-directories with .git or go.mod/package.json.
function M.init_monorepo()
	local cwd = vim.fn.getcwd()
	local found = {}

	-- First, add the root itself if it's a git repo
	if vim.fn.isdirectory(cwd .. "/.git") == 1 then
		M.add(cwd)
	end

	-- Scan immediate subdirectories for service repos
	local handle = uv.fs_scandir(cwd)
	if not handle then
		return
	end

	while true do
		local name, ftype = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if ftype == "directory" and name:sub(1, 1) ~= "." and name ~= "node_modules" then
			local sub = cwd .. "/" .. name
			-- Check for independent repo or service markers
			local is_repo = vim.fn.isdirectory(sub .. "/.git") == 1
			local has_manifest = vim.fn.filereadable(sub .. "/go.mod") == 1
				or vim.fn.filereadable(sub .. "/package.json") == 1
				or vim.fn.filereadable(sub .. "/Cargo.toml") == 1
				or vim.fn.filereadable(sub .. "/pyproject.toml") == 1
			if is_repo or has_manifest then
				found[#found + 1] = { name = name, path = sub, is_repo = is_repo }
			end
		end
	end

	if #found == 0 then
		vim.notify("[dwight] No sub-repos or services found in this directory.", vim.log.levels.INFO)
		return
	end

	-- Show what we found and let user confirm
	local items = {}
	for _, f in ipairs(found) do
		local marker = f.is_repo and "📦" or "📂"
		items[#items + 1] = string.format("%s %s — %s", marker, f.name, f.path)
	end

	vim.notify(string.format("[dwight] Found %d potential repos/services:", #found), vim.log.levels.INFO)

	vim.ui.select({ "Add all " .. #found .. " repos", "Pick individually", "Cancel" }, {
		prompt = "Initialize monorepo workspace?",
	}, function(choice)
		if not choice or choice:match("Cancel") then
			return
		end

		if choice:match("Add all") then
			for _, f in ipairs(found) do
				M.add(f.path)
			end
			vim.notify(string.format("[dwight] ✅ Added %d repos to workspace.", #found), vim.log.levels.INFO)
		else
			-- Let user pick
			require("dwight.select").pick(items, {
				prompt = "Select repos to add (multi-select with Tab):",
			}, function(_, idx)
				if idx then
					M.add(found[idx].path)
				end
			end)
		end
	end)
end

return M
