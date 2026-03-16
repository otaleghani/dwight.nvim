-- dwight/tracker.lua
-- Tracks usage: per-model breakdown with pricing, daily costs.
-- Data persists in .dwight/usage.json. :DwightUsage shows detailed stats.

local M = {}

local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- State
--------------------------------------------------------------------

M._session = {
	invocations = 0,
	chars_sent = 0,
	chars_received = 0,
	cost = 0,
	by_mode = {},
	by_model = {}, -- { model = { invocations, chars_sent, chars_received, cost } }
	model = nil,
	started = os.time(),
}

--------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------

local function tracker_path()
	return require("dwight.project").tracker_file()
end

local function default_lifetime()
	return { invocations = 0, chars_sent = 0, chars_received = 0, cost = 0, by_mode = {}, by_model = {}, by_status = {} }
end

local function read_data()
	local path = tracker_path()
	local f = io.open(path, "r")
	if not f then
		return { lifetime = default_lifetime() }
	end
	local raw = f:read("*a")
	f:close()
	local ok, data = pcall(vim.fn.json_decode, raw)
	if ok and data then
		local defaults = default_lifetime()
		data.lifetime = data.lifetime or {}
		for k, v in pairs(defaults) do
			if data.lifetime[k] == nil then
				data.lifetime[k] = v
			end
		end
		return data
	end
	return { lifetime = default_lifetime() }
end

local function write_data(data)
	local project = require("dwight.project")
	if not project.is_initialized() then
		return
	end
	local path = tracker_path()
	local f = io.open(path, "w")
	if not f then
		return
	end
	local ok, json = pcall(vim.fn.json_encode, data)
	if ok then
		f:write(json)
	end
	f:close()
end

--------------------------------------------------------------------
-- Pricing (per million tokens)
--------------------------------------------------------------------

M.PRICING = {
	-- Anthropic
	["claude-3-5-haiku"] = { input = 1.00, output = 5.00, name = "Claude 3.5 Haiku" },
	["claude-3-5-sonnet"] = { input = 3.00, output = 15.00, name = "Claude 3.5 Sonnet" },
	["claude-3-opus"] = { input = 15.00, output = 75.00, name = "Claude 3 Opus" },
	["claude-sonnet-4"] = { input = 3.00, output = 15.00, name = "Claude Sonnet 4" },
	["claude-opus-4"] = { input = 15.00, output = 75.00, name = "Claude Opus 4" },
	["claude-haiku"] = { input = 1.00, output = 5.00, name = "Claude Haiku" },
	-- Short aliases (for claude_code backend where model is just "sonnet"/"opus"/"haiku")
	["sonnet"] = { input = 3.00, output = 15.00, name = "Sonnet" },
	["opus"] = { input = 15.00, output = 75.00, name = "Opus" },
	["haiku"] = { input = 1.00, output = 5.00, name = "Haiku" },
	-- OpenAI
	["gpt-4o"] = { input = 2.50, output = 10.00, name = "GPT-4o" },
	["gpt-4o-mini"] = { input = 0.15, output = 0.60, name = "GPT-4o mini" },
	["gpt-4-turbo"] = { input = 10.00, output = 30.00, name = "GPT-4 Turbo" },
	["o1"] = { input = 15.00, output = 60.00, name = "o1" },
	["o1-mini"] = { input = 3.00, output = 12.00, name = "o1-mini" },
	["o3-mini"] = { input = 1.10, output = 4.40, name = "o3-mini" },
	-- Gemini
	["gemini-2.0-flash"] = { input = 0.10, output = 0.40, name = "Gemini 2.0 Flash" },
	["gemini-1.5-pro"] = { input = 1.25, output = 5.00, name = "Gemini 1.5 Pro" },
	["gemini-2.5-pro"] = { input = 1.25, output = 10.00, name = "Gemini 2.5 Pro" },
	-- DeepSeek
	["deepseek-chat"] = { input = 0.14, output = 0.28, name = "DeepSeek V3" },
	["deepseek-reasoner"] = { input = 0.55, output = 2.19, name = "DeepSeek R1" },
	-- Fallback
	default = { input = 3.00, output = 15.00, name = "Unknown" },
}

local function get_pricing(model)
	if not model then
		return M.PRICING.default
	end
	local m = model:lower()
	for pattern, price in pairs(M.PRICING) do
		if pattern ~= "default" and m:find(pattern, 1, true) then
			return price
		end
	end
	return M.PRICING.default
end

local function estimate_cost(model, chars_sent, chars_received)
	local price = get_pricing(model)
	local tokens_in = chars_sent / 4
	local tokens_out = chars_received / 4
	return (tokens_in * price.input / 1000000) + (tokens_out * price.output / 1000000)
end

--------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------

function M.record(mode_name, chars_sent, chars_received, extra)
	extra = extra or {}
	local model = M._session.model or "unknown"
	local cost = estimate_cost(model, chars_sent, chars_received)
	local cfg = require("dwight").config
	local current_backend = cfg.backend or "api"

	-- Session
	M._session.invocations = M._session.invocations + 1
	M._session.chars_sent = M._session.chars_sent + chars_sent
	M._session.chars_received = M._session.chars_received + chars_received
	M._session.by_mode[mode_name] = (M._session.by_mode[mode_name] or 0) + 1
	M._session.cost = (M._session.cost or 0) + cost

	-- Per-model session
	if not M._session.by_model[model] then
		M._session.by_model[model] = { invocations = 0, chars_sent = 0, chars_received = 0, cost = 0 }
	end
	local sm = M._session.by_model[model]
	sm.invocations = sm.invocations + 1
	sm.chars_sent = sm.chars_sent + chars_sent
	sm.chars_received = sm.chars_received + chars_received
	sm.cost = sm.cost + cost
	sm.backend = current_backend

	-- Per-feature session
	if extra.feature then
		M._session.by_feature = M._session.by_feature or {}
		if not M._session.by_feature[extra.feature] then
			M._session.by_feature[extra.feature] = { invocations = 0, cost = 0, success = 0, failure = 0, duration = 0 }
		end
		local sf = M._session.by_feature[extra.feature]
		sf.invocations = sf.invocations + 1
		sf.cost = sf.cost + cost
		if extra.status == "success" then
			sf.success = sf.success + 1
		elseif extra.status == "error" or extra.status == "parse_fail" then
			sf.failure = sf.failure + 1
		end
		if extra.duration then
			sf.duration = sf.duration + extra.duration
		end
	end

	-- Lifetime
	local data = read_data()
	local lt = data.lifetime
	lt.invocations = lt.invocations + 1
	lt.chars_sent = lt.chars_sent + chars_sent
	lt.chars_received = lt.chars_received + chars_received
	lt.by_mode[mode_name] = (lt.by_mode[mode_name] or 0) + 1
	lt.cost = (lt.cost or 0) + cost

	-- Per-model lifetime
	lt.by_model = lt.by_model or {}
	if not lt.by_model[model] then
		lt.by_model[model] = { invocations = 0, chars_sent = 0, chars_received = 0, cost = 0 }
	end
	local lm = lt.by_model[model]
	lm.invocations = lm.invocations + 1
	lm.chars_sent = lm.chars_sent + chars_sent
	lm.chars_received = lm.chars_received + chars_received
	lm.cost = lm.cost + cost
	lm.backend = current_backend

	-- Per-feature lifetime
	if extra.feature then
		lt.by_feature = lt.by_feature or {}
		if not lt.by_feature[extra.feature] then
			lt.by_feature[extra.feature] = {
				invocations = 0,
				cost = 0,
				success = 0,
				failure = 0,
				chars_sent = 0,
				chars_received = 0,
				duration = 0,
				first_seen = os.date("%Y-%m-%d"),
			}
		end
		local lf = lt.by_feature[extra.feature]
		lf.invocations = lf.invocations + 1
		lf.cost = lf.cost + cost
		lf.chars_sent = (lf.chars_sent or 0) + chars_sent
		lf.chars_received = (lf.chars_received or 0) + chars_received
		if extra.status == "success" then
			lf.success = (lf.success or 0) + 1
		elseif extra.status == "error" or extra.status == "parse_fail" then
			lf.failure = (lf.failure or 0) + 1
		end
		if extra.duration then
			lf.duration = (lf.duration or 0) + extra.duration
		end
		lf.last_used = os.date("%Y-%m-%d")
	end

	-- Success/failure tracking (global)
	if extra.status then
		lt.by_status = lt.by_status or {}
		lt.by_status[extra.status] = (lt.by_status[extra.status] or 0) + 1
	end

	-- Daily
	local today = os.date("%Y-%m-%d")
	data.daily_cost = data.daily_cost or {}
	data.daily_cost[today] = (data.daily_cost[today] or 0) + cost

	-- Daily invocations (for trend)
	data.daily_invocations = data.daily_invocations or {}
	data.daily_invocations[today] = (data.daily_invocations[today] or 0) + 1

	-- Daily success/failure
	if extra.status then
		data.daily_status = data.daily_status or {}
		if not data.daily_status[today] then
			data.daily_status[today] = { success = 0, failure = 0 }
		end
		if extra.status == "success" then
			data.daily_status[today].success = data.daily_status[today].success + 1
		elseif extra.status == "error" or extra.status == "parse_fail" then
			data.daily_status[today].failure = data.daily_status[today].failure + 1
		end
	end

	data.last_used = os.date("%Y-%m-%d %H:%M:%S")

	write_data(data)
end

function M.set_model(model)
	M._session.model = model
end

--- Expose data accessors for stats module.
M._read_data = read_data
M._write_data = write_data
M._get_pricing = get_pricing
M._estimate_cost = estimate_cost

function M.get_model()
	local cfg = require("dwight").config
	local backend = cfg.backend or "api"
	-- Backend-specific model resolution
	if backend == "claude_code" then
		return M._session.model or cfg.claude_code_model or "sonnet"
	end
	if backend == "opencode" then
		return M._session.model or cfg.model or "(default)"
	end
	-- API backend: session model (set during execution) → active provider model → config
	if M._session.model then
		return M._session.model
	end
	-- Try to get from providers module (reflects DwightSwitch)
	local ok, providers = pcall(require, "dwight.providers")
	if ok and providers._active_model then
		return providers._active_model
	end
	return cfg.model or "(default)"
end

--------------------------------------------------------------------
-- Display Helpers
--------------------------------------------------------------------

local function tk(chars)
	return math.floor(chars / 4)
end

local function fmt_num(n)
	local s = tostring(math.floor(n))
	local result, len = "", #s
	for i = 1, len do
		if i > 1 and (len - i + 1) % 3 == 0 then
			result = result .. ","
		end
		result = result .. s:sub(i, i)
	end
	return result
end

local function fmt_cost(c)
	if c < 0.01 then
		return string.format("$%.4f", c)
	end
	return string.format("$%.2f", c)
end

local function fmt_tkn(chars)
	local t = tk(chars)
	if t >= 1000000 then
		return string.format("%.1fM", t / 1000000)
	end
	if t >= 1000 then
		return string.format("%.1fK", t / 1000)
	end
	return tostring(t)
end

-- Expose formatters for stats module (must be after definitions)
M._fmt_num = fmt_num
M._fmt_cost = fmt_cost
M._fmt_tkn = fmt_tkn

--------------------------------------------------------------------
-- :DwightUsage — detailed stats in floating window
--------------------------------------------------------------------

function M.show()
	local data = read_data()
	local lt = data.lifetime
	local s = M._session
	local current_model = M.get_model()
	local pricing = get_pricing(current_model)

	local cfg = require("dwight").config
	local backend = cfg.backend or "api"

	local lines = {
		"╔══════════════════════════════════════════════════╗",
		"║              Dwight Usage Stats                  ║",
		"╚══════════════════════════════════════════════════╝",
		"",
		"🔧 Backend: " .. backend,
		"🔧 Current model: " .. current_model,
		string.format("   Pricing: $%.2f/1M input, $%.2f/1M output", pricing.input, pricing.output),
	}

	-- Show model diversity if configured
	if cfg.test_model or cfg.implement_model then
		lines[#lines + 1] = "🔀 Model diversity:"
		if cfg.test_model then
			lines[#lines + 1] = "   Test model (/test, /stub): " .. cfg.test_model
		end
		if cfg.implement_model then
			lines[#lines + 1] = "   Impl model (/code, /fix): " .. cfg.implement_model
		end
	end
	lines[#lines + 1] = ""

	-- Per-model table (lifetime)
	local model_data = lt.by_model or {}
	local model_list = {}
	for model, stats in pairs(model_data) do
		model_list[#model_list + 1] = { model = model, stats = stats }
	end
	table.sort(model_list, function(a, b)
		return a.stats.cost > b.stats.cost
	end)

	if #model_list > 0 then
		lines[#lines + 1] = "── Model Breakdown (lifetime) ──────────────────"
		lines[#lines + 1] =
			string.format("  %-20s %-10s %5s %8s %8s %8s", "Model", "Backend", "Calls", "Tok In", "Tok Out", "Cost")
		lines[#lines + 1] = "  " .. string.rep("─", 65)
		for _, entry in ipairs(model_list) do
			local m = entry.model
			local st = entry.stats
			local display = m
			-- Try to find a friendly name
			local p = get_pricing(m)
			if p.name and p.name ~= "Unknown" then
				display = p.name
			end
			if #display > 20 then
				display = display:sub(1, 17) .. "…"
			end
			-- Determine backend for this model
			local model_backend = st.backend or backend
			lines[#lines + 1] = string.format(
				"  %-20s %-10s %5s %8s %8s %8s",
				display,
				model_backend,
				fmt_num(st.invocations),
				fmt_tkn(st.chars_sent),
				fmt_tkn(st.chars_received),
				fmt_cost(st.cost)
			)
		end
		lines[#lines + 1] = "  " .. string.rep("─", 65)
		lines[#lines + 1] = string.format(
			"  %-20s %-10s %5s %8s %8s %8s",
			"TOTAL",
			"",
			fmt_num(lt.invocations),
			fmt_tkn(lt.chars_sent),
			fmt_tkn(lt.chars_received),
			fmt_cost(lt.cost)
		)
		lines[#lines + 1] = ""
	end

	-- Session summary
	lines[#lines + 1] =
		"── This Session ────────────────────────────────"
	lines[#lines + 1] = string.format(
		"  Invocations: %s  |  Tokens: ~%s in, ~%s out  |  Cost: %s",
		fmt_num(s.invocations),
		fmt_tkn(s.chars_sent),
		fmt_tkn(s.chars_received),
		fmt_cost(s.cost or 0)
	)

	-- Session per-model if multiple
	local s_models = {}
	for model, stats in pairs(s.by_model) do
		s_models[#s_models + 1] = { model = model, stats = stats }
	end
	if #s_models > 1 then
		table.sort(s_models, function(a, b)
			return a.stats.cost > b.stats.cost
		end)
		for _, entry in ipairs(s_models) do
			local display = entry.model
			local p = get_pricing(entry.model)
			if p.name and p.name ~= "Unknown" then
				display = p.name
			end
			lines[#lines + 1] = string.format(
				"    %s: %s calls, %s",
				display,
				fmt_num(entry.stats.invocations),
				fmt_cost(entry.stats.cost)
			)
		end
	end
	lines[#lines + 1] = ""

	-- Daily cost (last 7 days)
	if data.daily_cost then
		local days = {}
		for day, cost in pairs(data.daily_cost) do
			days[#days + 1] = { day, cost }
		end
		table.sort(days, function(a, b)
			return a[1] > b[1]
		end)
		if #days > 0 then
			lines[#lines + 1] =
				"── Daily Cost ──────────────────────────────────"
			for i = 1, math.min(7, #days) do
				local bar_len = math.min(30, math.floor(days[i][2] * 100))
				local bar = string.rep("█", bar_len)
				lines[#lines + 1] = string.format("  %s  %8s  %s", days[i][1], fmt_cost(days[i][2]), bar)
			end
			lines[#lines + 1] = ""
		end
	end

	-- By mode
	if lt.by_mode and not vim.tbl_isempty(lt.by_mode) then
		lines[#lines + 1] =
			"── By Mode ─────────────────────────────────────"
		local sorted = {}
		for k, v in pairs(lt.by_mode) do
			sorted[#sorted + 1] = { k, v }
		end
		table.sort(sorted, function(a, b)
			return a[2] > b[2]
		end)
		local mode_strs = {}
		for _, pair in ipairs(sorted) do
			mode_strs[#mode_strs + 1] = string.format("%s(%s)", pair[1], fmt_num(pair[2]))
		end
		lines[#lines + 1] = "  " .. table.concat(mode_strs, "  ")
		lines[#lines + 1] = ""
	end

	-- Reference pricing table (deduplicated by name — short aliases share pricing with full names)
	lines[#lines + 1] = "── Pricing Reference (per 1M tokens) ───────────"
	lines[#lines + 1] = string.format("  %-24s %8s %8s", "Model", "Input", "Output")
	lines[#lines + 1] = "  " .. string.rep("─", 42)
	local price_list = {}
	local price_seen = {}
	for key, p in pairs(M.PRICING) do
		if key ~= "default" then
			local display = p.name or key
			-- Skip short aliases (sonnet/opus/haiku) — they duplicate full model names
			if not price_seen[display] then
				price_seen[display] = true
				price_list[#price_list + 1] = { name = display, input = p.input, output = p.output }
			end
		end
	end
	table.sort(price_list, function(a, b)
		return a.input < b.input
	end)
	for _, p in ipairs(price_list) do
		lines[#lines + 1] = string.format(
			"  %-24s %7s %8s",
			p.name,
			"$" .. string.format("%.2f", p.input),
			"$" .. string.format("%.2f", p.output)
		)
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "💡 Costs are estimates (1 token ≈ 4 chars)"

	-- Show in floating window
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "dwight_usage"

	-- Syntax highlighting
	pcall(function()
		vim.api.nvim_buf_call(buf, function()
			vim.cmd([[
        syntax match DwightUsageHeader /^[╔╚║].*$/
        syntax match DwightUsageSection /^──.*──$/
        syntax match DwightUsageSep /^  ─\+$/
        syntax match DwightUsageBar /█\+/
        syntax match DwightUsageCost /\$[0-9,.]\+/
        syntax match DwightUsageIcon /[🔧🔀💡📊💰]/
        syntax match DwightUsageLabel /^\s\+\%(Backend\|Current model\|Pricing\|Test model\|Impl model\|Invocations\|TOTAL\):/
      ]])
		end)
	end)

	-- Apply highlight colors
	local hl = vim.api.nvim_set_hl
	hl(0, "DwightUsageHeader", { fg = "#bb9af7", bold = true, default = true })
	hl(0, "DwightUsageSection", { fg = "#7aa2f7", bold = true, default = true })
	hl(0, "DwightUsageSep", { fg = "#565f89", default = true })
	hl(0, "DwightUsageBar", { fg = "#9ece6a", bold = true, default = true })
	hl(0, "DwightUsageCost", { fg = "#e0af68", default = true })
	hl(0, "DwightUsageLabel", { fg = "#7dcfff", default = true })

	local width = math.min(70, vim.o.columns - 4)
	local height = math.min(#lines, vim.o.lines - 4)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = require("dwight").config.border,
		title = " 📊 Usage ",
		title_pos = "center",
	})

	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })
	vim.keymap.set("n", "<Esc>", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf })
end

return M
