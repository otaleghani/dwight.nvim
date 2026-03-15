-- dwight/github/issues.lua
-- Issue API: list, get, templates, create.

local M = {}

M.ISSUE_FIELDS = "number,title,body,state,labels,assignees,comments,createdAt,author,milestone,url"

--- List open issues. Returns parsed table or nil.
--- opts.label -- filter by label
--- opts.assignee -- filter by assignee ("@me" for self)
--- opts.milestone -- filter by milestone title
--- opts.limit -- max issues (default 30)
--- opts.state -- "open" (default), "closed", "all"
--- opts.repo -- "owner/repo" for cross-repo (optional)
function M.list_issues(opts, callback)
	local cli = require("dwight.github.cli")
	opts = opts or {}
	local args = cli.repo_flag(opts.repo)
	vim.list_extend(args, {
		"issue",
		"list",
		"--json",
		M.ISSUE_FIELDS,
		"--limit",
		tostring(opts.limit or 30),
		"--state",
		opts.state or "open",
	})

	if opts.label then
		args[#args + 1] = "--label"
		args[#args + 1] = opts.label
	end
	if opts.assignee then
		args[#args + 1] = "--assignee"
		args[#args + 1] = opts.assignee
	end
	if opts.milestone then
		args[#args + 1] = "--milestone"
		args[#args + 1] = opts.milestone
	end

	cli.run_gh(args, function(out, code)
		if code ~= 0 then
			callback(nil, "gh issue list failed: " .. (out or ""):sub(1, 200))
			return
		end
		local ok, data = pcall(vim.json.decode, out)
		if not ok or not data then
			callback(nil, "Failed to parse issue list")
			return
		end
		callback(data, nil)
	end)
end

--- Get a single issue with full detail.
--- opts.repo -- "owner/repo" for cross-repo (optional)
function M.get_issue(number, callback, opts)
	local cli = require("dwight.github.cli")
	opts = opts or {}
	local args = cli.repo_flag(opts.repo)
	vim.list_extend(args, {
		"issue",
		"view",
		tostring(number),
		"--json",
		M.ISSUE_FIELDS,
	})
	cli.run_gh(args, function(out, code)
		if code ~= 0 then
			callback(nil, "gh issue view failed: " .. (out or ""):sub(1, 200))
			return
		end
		local ok, data = pcall(vim.json.decode, out)
		if not ok or not data then
			callback(nil, "Failed to parse issue")
			return
		end
		-- Stamp repo if cross-repo
		if opts.repo then
			data._repo = opts.repo
		end
		callback(data, nil)
	end)
end

--- Fetch repo issue templates.
--- callback(templates) where templates = { { name, body, labels, about }, ... } or {}
function M.list_templates(callback, opts)
	local cli = require("dwight.github.cli")
	local preflight = require("dwight.github.preflight")
	opts = opts or {}
	-- gh api repos/{owner}/{repo}/contents/.github/ISSUE_TEMPLATE
	local repo = opts.repo or preflight.current_repo()
	if not repo then
		callback({})
		return
	end

	cli.run_gh({
		"api",
		"repos/" .. repo .. "/contents/.github/ISSUE_TEMPLATE",
		"--jq",
		'[.[] | select(.name | endswith(".md") or endswith(".yml") or endswith(".yaml")) | .download_url]',
	}, function(out, code)
		if code ~= 0 or not out or vim.trim(out) == "" then
			callback({})
			return
		end

		local ok, urls = pcall(vim.json.decode, out)
		if not ok or type(urls) ~= "table" then
			callback({})
			return
		end

		-- Fetch each template
		local templates = {}
		local pending = #urls
		if pending == 0 then
			callback({})
			return
		end

		for _, url in ipairs(urls) do
			cli.run_gh({ "api", url, "--jq", "." }, function(raw, c)
				if c == 0 and raw and raw ~= "" then
					-- Parse YAML frontmatter
					local name = raw:match("name:%s*[\"']?([^\n\"']+)")
					local about = raw:match("about:%s*[\"']?([^\n\"']+)")
					local labels_str = raw:match("labels:%s*%[([^%]]+)%]") or raw:match("labels:%s*([^\n]+)")
					local body_start = raw:find("---", 4, true)
					local body = body_start and raw:sub(body_start + 4) or raw

					templates[#templates + 1] = {
						name = name or url:match("/([^/]+)$") or "template",
						about = about or "",
						body = vim.trim(body),
						labels = labels_str,
					}
				end

				pending = pending - 1
				if pending == 0 then
					table.sort(templates, function(a, b)
						return a.name < b.name
					end)
					callback(templates)
				end
			end)
		end
	end)
end

--- Create a new issue, optionally using a repo template.
function M.create_issue(opts, callback)
	local cli = require("dwight.github.cli")
	opts = opts or {}

	-- If no template chosen yet, let user pick one
	if not opts.body and not opts._skip_template then
		M.list_templates(function(templates)
			if #templates == 0 then
				opts._skip_template = true
				M.create_issue(opts, callback)
				return
			end

			local items = { "Blank issue" }
			for _, t in ipairs(templates) do
				items[#items + 1] = string.format("%s — %s", t.name, t.about)
			end

			require("dwight.select").pick(items, {
				prompt = "Choose issue template:",
			}, function(choice, idx)
				if not choice then
					return
				end
				if idx == 1 then
					opts._skip_template = true
					M.create_issue(opts, callback)
				else
					local tmpl = templates[idx - 1]
					opts.body = tmpl.body
					if tmpl.labels and not opts.labels then
						opts.labels = tmpl.labels
					end
					M.create_issue(opts, callback)
				end
			end)
			return
		end, opts)
		return
	end

	-- Build gh issue create args
	local args = cli.repo_flag(opts.repo)
	vim.list_extend(args, { "issue", "create" })

	if opts.title then
		args[#args + 1] = "--title"
		args[#args + 1] = opts.title
	end
	if opts.body then
		args[#args + 1] = "--body"
		args[#args + 1] = opts.body
	end
	if opts.labels then
		args[#args + 1] = "--label"
		args[#args + 1] = opts.labels
	end
	if opts.milestone then
		args[#args + 1] = "--milestone"
		args[#args + 1] = opts.milestone
	end
	if opts.assignee then
		args[#args + 1] = "--assignee"
		args[#args + 1] = opts.assignee
	end

	-- If no title, open gh interactive mode (--web or editor)
	if not opts.title then
		args[#args + 1] = "--web"
	end

	cli.run_gh(args, function(out, code)
		if callback then
			callback(code == 0 and vim.trim(out) or nil, code ~= 0 and out or nil)
		end
		if code == 0 then
			vim.notify(string.format("[dwight] Issue created: %s", vim.trim(out or "")), vim.log.levels.INFO)
		end
	end)
end

return M
