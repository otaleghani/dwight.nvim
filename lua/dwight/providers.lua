-- dwight/providers.lua
-- Multi-provider API management. Anthropic, OpenAI, Gemini, OpenRouter, and custom.

local M = {}

--------------------------------------------------------------------
-- Built-in Provider Presets
--------------------------------------------------------------------

M.presets = {
	anthropic = {
		name = "Anthropic",
		api_key_env = "ANTHROPIC_API_KEY",
		base_url = "https://api.anthropic.com",
		endpoint = "/v1/messages",
		format = "anthropic",
		headers = { ["anthropic-version"] = "2023-06-01" },
		auth_header = "x-api-key",
		models = {
			["sonnet"] = "claude-sonnet-4-20250514",
			["haiku"] = "claude-haiku-4-5-20251001",
			["opus"] = "claude-opus-4-6",
		},
		default_model = "sonnet",
	},

	-- Anthropic Pro/Max subscription (OAuth, not API key)
	-- Uses same API endpoint but with Bearer token auth.
	-- Authenticate with :DwightAuthMax, bills against your subscription.
	anthropic_max = {
		name = "Anthropic Max",
		base_url = "https://api.anthropic.com",
		endpoint = "/v1/messages",
		format = "anthropic",
		headers = { ["anthropic-version"] = "2023-06-01" },
		auth_header = "Authorization",
		auth_prefix = "Bearer ",
		auth_type = "oauth", -- signals that get_api_key should check stored token
		models = {
			["sonnet"] = "claude-sonnet-4-20250514",
			["haiku"] = "claude-haiku-4-5-20251001",
			["opus"] = "claude-opus-4-6",
		},
		default_model = "sonnet",
	},

	openai = {
		name = "OpenAI",
		api_key_env = "OPENAI_API_KEY",
		base_url = "https://api.openai.com",
		endpoint = "/v1/chat/completions",
		format = "openai",
		headers = {},
		auth_header = "Authorization",
		auth_prefix = "Bearer ",
		models = {
			["gpt4o"] = "gpt-4o",
			["gpt4o-mini"] = "gpt-4o-mini",
			["o1"] = "o1",
			["o3"] = "o3",
			["o3-mini"] = "o3-mini",
			["o4-mini"] = "o4-mini",
			["gpt5"] = "gpt-5",
			["gpt5-mini"] = "gpt-5-mini",
			["gpt5-nano"] = "gpt-5-nano",
			["gpt5-codex"] = "gpt-5-codex",
			["gpt5.1"] = "gpt-5.1",
			["gpt5.1-mini"] = "gpt-5.1-mini",
			["gpt5.1-codex"] = "gpt-5.1-codex",
			["gpt5.1-codex-max"] = "gpt-5.1-codex-max",
			["gpt5.2"] = "gpt-5.2",
			["gpt5.3-codex"] = "gpt-5.3-codex",
			["gpt5.4"] = "gpt-5.4",
			["gpt4.1"] = "gpt-4.1",
			["gpt4.1-mini"] = "gpt-4.1-mini",
			["gpt4.1-nano"] = "gpt-4.1-nano",
			["codex-mini"] = "codex-mini-latest",
		},
		default_model = "gpt4o",
	},

	gemini = {
		name = "Gemini",
		api_key_env = "GEMINI_API_KEY",
		base_url = "https://generativelanguage.googleapis.com",
		endpoint = "/v1beta/models/{model}:generateContent",
		format = "gemini",
		headers = {},
		auth_header = nil,
		auth_query = "key",
		models = {
			["flash"] = "gemini-2.5-flash",
			["pro"] = "gemini-2.5-pro",
		},
		default_model = "flash",
	},

	openrouter = {
		name = "OpenRouter",
		api_key_env = "OPENROUTER_API_KEY",
		base_url = "https://openrouter.ai/api",
		endpoint = "/v1/chat/completions",
		format = "openai",
		headers = {},
		auth_header = "Authorization",
		auth_prefix = "Bearer ",
		models = {
			["sonnet"] = "anthropic/claude-sonnet-4-20250514",
			["haiku"] = "anthropic/claude-haiku-4-5-20251001",
			["opus"] = "anthropic/claude-opus-4-6",
			["gpt4o"] = "openai/gpt-4o",
			["flash"] = "google/gemini-2.5-flash",
		},
		default_model = "sonnet",
	},
}

--------------------------------------------------------------------
-- State
--------------------------------------------------------------------

M._providers = {}
M._active_provider = nil
M._active_model = nil

--------------------------------------------------------------------
-- Config Storage
--------------------------------------------------------------------

local function global_config_dir()
	local xdg = os.getenv("XDG_CONFIG_HOME")
	if xdg and xdg ~= "" then
		return xdg .. "/dwight"
	end
	return os.getenv("HOME") .. "/.config/dwight"
end

local function global_config_path()
	return global_config_dir() .. "/providers.json"
end

local function project_config_path()
	local project = require("dwight.project")
	if project.is_initialized() then
		return project.dir() .. "/providers.json"
	end
	return nil
end

local function read_json(path)
	if not path or vim.fn.filereadable(path) ~= 1 then
		return nil
	end
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, content)
	return ok and data or nil
end

local function write_json(path, data)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local f = io.open(path, "w")
	if not f then
		return false
	end
	f:write(vim.json.encode(data))
	f:close()
	return true
end

--------------------------------------------------------------------
-- Load / Save
--------------------------------------------------------------------

function M.load()
	local cfg = require("dwight").config
	M._providers = vim.deepcopy(M.presets)

	local global = read_json(global_config_path())
	if global then
		if global.providers then
			for name, p in pairs(global.providers) do
				M._providers[name] = vim.tbl_deep_extend("force", M._providers[name] or {}, p)
			end
		end
		if global.active_provider then
			M._active_provider = global.active_provider
		end
		if global.active_model then
			M._active_model = global.active_model
		end
	end

	local project = read_json(project_config_path())
	if project then
		if project.providers then
			for name, p in pairs(project.providers) do
				M._providers[name] = vim.tbl_deep_extend("force", M._providers[name] or {}, p)
			end
		end
		if project.active_provider then
			M._active_provider = project.active_provider
		end
		if project.active_model then
			M._active_model = project.active_model
		end
	end

	-- Only apply config overrides when using the API backend.
	-- For claude_code/opencode, cfg.model is irrelevant to provider resolution.
	local backend = cfg.backend or "api"
	if backend == "api" then
		if cfg.provider then
			M._active_provider = cfg.provider
		end
		if cfg.model then
			M._active_model = cfg.model
		end
	end
	if not M._active_provider then
		M._active_provider = "anthropic"
	end
end

function M.save_global()
	local data = { active_provider = M._active_provider, active_model = M._active_model, providers = {} }
	for name, p in pairs(M._providers) do
		if not M.presets[name] then
			data.providers[name] = p
		end
	end
	write_json(global_config_path(), data)
end

--------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------

function M.get_provider(name)
	if not next(M._providers) then
		M.load()
	end
	name = name or M._active_provider or "anthropic"
	return M._providers[name], name
end

function M.resolve_model(model_str)
	if not next(M._providers) then
		M.load()
	end

	if not model_str or model_str == "" then
		local p, pname = M.get_provider()
		local model_id = M._active_model
		if not model_id and p then
			model_id = p.models and p.models[p.default_model] or p.default_model
		end
		return { provider_name = pname, provider = p, model_id = model_id }
	end

	-- provider:model syntax
	local pname, mname = model_str:match("^(%w+):(.+)$")
	if pname and M._providers[pname] then
		local p = M._providers[pname]
		return { provider_name = pname, provider = p, model_id = (p.models and p.models[mname]) or mname }
	end

	-- alias on active provider
	local active_p, active_name = M.get_provider()
	if active_p and active_p.models and active_p.models[model_str] then
		return { provider_name = active_name, provider = active_p, model_id = active_p.models[model_str] }
	end

	-- search all providers
	for name, p in pairs(M._providers) do
		if p.models and p.models[model_str] then
			return { provider_name = name, provider = p, model_id = p.models[model_str] }
		end
	end

	-- literal model string — infer provider
	if model_str:match("^claude") or model_str:match("^anthropic") then
		return { provider_name = "anthropic", provider = M._providers.anthropic, model_id = model_str }
	elseif model_str:match("^gpt") or model_str:match("^o%d") or model_str:match("^codex%-") then
		return { provider_name = "openai", provider = M._providers.openai, model_id = model_str }
	elseif model_str:match("^gemini") then
		return { provider_name = "gemini", provider = M._providers.gemini, model_id = model_str }
	end

	return { provider_name = active_name, provider = active_p, model_id = model_str }
end

function M.get_api_key(provider)
	if not provider then
		return nil
	end
	if provider.api_key then
		return provider.api_key
	end

	-- OAuth providers: check stored token
	if provider.auth_type == "oauth" then
		local token = M._read_oauth_token()
		if token then
			return token
		end
		return nil
	end

	if provider.api_key_env then
		local key = os.getenv(provider.api_key_env)
		if key and key ~= "" then
			return key
		end
	end
	return nil
end

--------------------------------------------------------------------
-- OAuth Token Storage
--------------------------------------------------------------------

local function oauth_token_path()
	return global_config_dir() .. "/oauth_token.json"
end

function M._read_oauth_token()
	local data = read_json(oauth_token_path())
	if not data or not data.access_token then
		return nil
	end

	-- Check expiry
	if data.expires_at and os.time() >= data.expires_at then
		-- Try refresh if we have a refresh token
		if data.refresh_token then
			local refreshed = M._refresh_oauth_token(data)
			if refreshed then
				return refreshed.access_token
			end
		end
		return nil
	end

	return data.access_token
end

function M._write_oauth_token(data)
	if data.expires_in then
		data.expires_at = os.time() + data.expires_in - 30
	end
	write_json(oauth_token_path(), data)
	pcall(function()
		vim.fn.system("chmod 600 " .. vim.fn.shellescape(oauth_token_path()))
	end)
end

function M._refresh_oauth_token(token_data)
	-- Use Claude Code's refresh endpoint if we imported from Claude Code
	if not token_data.refresh_token then
		return nil
	end

	local body = vim.json.encode({
		grant_type = "refresh_token",
		refresh_token = token_data.refresh_token,
		client_id = token_data.client_id or "",
	})

	local endpoint = token_data.token_endpoint or "https://console.anthropic.com/v1/oauth/token"
	local result = vim.fn.system({
		"curl",
		"-sS",
		"--max-time",
		"10",
		"-X",
		"POST",
		endpoint,
		"-H",
		"Content-Type: application/json",
		"-d",
		body,
	})

	local ok, data = pcall(vim.json.decode, result)
	if ok and data and data.access_token then
		data.refresh_token = data.refresh_token or token_data.refresh_token
		data.client_id = token_data.client_id
		data.token_endpoint = token_data.token_endpoint
		M._write_oauth_token(data)
		return data
	end

	return nil
end

--------------------------------------------------------------------
-- Claude Code Token Import
--------------------------------------------------------------------

--- Search for Claude Code stored credentials.
--- Claude Code stores OAuth tokens that bill against Pro/Max subscription.
local function find_claude_code_credentials()
	local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
	local xdg_config = os.getenv("XDG_CONFIG_HOME") or (home .. "/.config")
	local candidates = {
		-- Claude Code standard locations (varies by version)
		home .. "/.claude.json",
		home .. "/.claude/credentials.json",
		home .. "/.claude/auth.json",
		home .. "/.claude/config.json",
		home .. "/.claude/oauth.json",
		xdg_config .. "/claude/credentials.json",
		xdg_config .. "/claude/auth.json",
		xdg_config .. "/claude-code/credentials.json",
		xdg_config .. "/claude-code/auth.json",
	}

	for _, path in ipairs(candidates) do
		local data = read_json(path)
		if data then
			-- Claude Code may store token directly or nested
			if data.oauthToken or data.oauth_token or data.access_token then
				return data, path
			end
			-- May be nested under a profile
			if data.default and type(data.default) == "table" then
				local d = data.default
				if d.oauthToken or d.oauth_token or d.access_token then
					return d, path
				end
			end
			-- May be nested under "auth" key
			if data.auth and type(data.auth) == "table" then
				local a = data.auth
				if a.oauthToken or a.oauth_token or a.access_token then
					return a, path
				end
			end
		end
	end

	-- Fallback: scan ~/.claude/ directory for any JSON file containing a token
	pcall(function()
		local claude_dir = home .. "/.claude"
		local uv = vim.loop or vim.uv
		local handle = uv.fs_scandir(claude_dir)
		if handle then
			while true do
				local name, ftype = uv.fs_scandir_next(handle)
				if not name then
					break
				end
				if ftype == "file" and name:match("%.json$") then
					local full = claude_dir .. "/" .. name
					local data = read_json(full)
					if data then
						if data.oauthToken or data.oauth_token or data.access_token then
							return data, full
						end
					end
				end
			end
		end
	end)

	return nil, nil
end

--- Extract usable token from Claude Code credential data.
local function extract_cc_token(data)
	if not data then
		return nil
	end
	return data.oauthToken or data.oauth_token or data.access_token
end

--- Silently try to import Claude Code credentials into anthropic_max provider.
--- Returns true if successful, false if no credentials found.
function M._try_auto_import_cc()
	-- Strategy 1: File-based search
	local cc_data, cc_path = find_claude_code_credentials()
	local cc_token = extract_cc_token(cc_data)

	-- Strategy 2: CLI-based extraction (if file search fails)
	-- Try to use `claude` CLI itself to retrieve the token
	if not cc_token then
		pcall(function()
			local cfg = require("dwight").config
			local claude_bin = cfg.claude_code_bin or "claude"

			-- claude auth status --json may print auth info
			-- claude config get oauth_token may work too
			-- Try a few approaches
			local cli_cmds = {
				claude_bin .. " auth status --json 2>/dev/null",
				claude_bin .. " config get oauthToken 2>/dev/null",
			}

			for _, cmd in ipairs(cli_cmds) do
				local handle = io.popen(cmd, "r")
				if handle then
					local output = handle:read("*a")
					handle:close()
					if output and output ~= "" then
						-- Try parsing as JSON
						local json_ok, json_data = pcall(vim.json.decode, output)
						if json_ok and json_data then
							local token = extract_cc_token(json_data)
							if token then
								cc_token = token
								cc_data = json_data
								break
							end
						else
							-- Maybe it's just a bare token string
							local trimmed = vim.trim(output)
							if #trimmed > 20 and not trimmed:match("%s") then
								cc_token = trimmed
								cc_data = { access_token = trimmed }
								break
							end
						end
					end
				end
			end
		end)
	end

	if not cc_token then
		return false
	end

	-- Auto-import: write the token and switch provider
	M._write_oauth_token({
		access_token = cc_token,
		refresh_token = cc_data.refreshToken or cc_data.refresh_token,
		client_id = cc_data.clientId or cc_data.client_id,
		token_endpoint = cc_data.tokenEndpoint or cc_data.token_endpoint,
		expires_in = cc_data.expiresIn or cc_data.expires_in or 3600,
	})
	M._active_provider = "anthropic_max"
	if not M._active_model then
		M._active_model = M._providers.anthropic_max.models[M._providers.anthropic_max.default_model]
	end
	M.save_global()
	return true
end

--------------------------------------------------------------------
-- Auth Max: Import token or manual entry
--------------------------------------------------------------------

--- Authenticate with Anthropic Pro/Max subscription.
--- Strategy:
---   1. Check for Claude Code stored credentials (automatic)
---   2. Fall back to manual token/API key entry
function M.auth_max()
	vim.notify("[dwight] 🔐 Setting up Anthropic Pro/Max authentication…", vim.log.levels.INFO)

	-- Strategy 1: Import from Claude Code
	local cc_data, cc_path = find_claude_code_credentials()
	local cc_token = extract_cc_token(cc_data)

	if cc_token then
		require("dwight.select").pick(
			{ "Import from Claude Code", "Enter token manually", "Cancel" },
			{ prompt = "Found Claude Code credentials at " .. cc_path .. ". Import?" },
			function(choice)
				if not choice then
					return
				end

				if choice == "Import from Claude Code" then
					M._write_oauth_token({
						access_token = cc_token,
						refresh_token = cc_data.refreshToken or cc_data.refresh_token,
						client_id = cc_data.clientId or cc_data.client_id,
						token_endpoint = cc_data.tokenEndpoint or cc_data.token_endpoint,
						expires_in = cc_data.expiresIn or cc_data.expires_in or 3600,
					})
					M._active_provider = "anthropic_max"
					M._active_model = M._providers.anthropic_max.models[M._providers.anthropic_max.default_model]
					M.save_global()
					vim.notify(
						"[dwight] ✅ Imported Claude Code token! Switched to anthropic_max provider.",
						vim.log.levels.INFO
					)
					vim.notify(
						"[dwight] 💡 Your API calls now bill against your Pro/Max subscription.",
						vim.log.levels.INFO
					)
				elseif choice == "Enter token manually" then
					M._prompt_manual_token()
				end
			end
		)
		return
	end

	-- Strategy 2: Manual entry
	vim.notify("[dwight] Claude Code credentials not found. You can:", vim.log.levels.INFO)
	vim.notify(
		"[dwight]   1. Install Claude Code (npm i -g @anthropic-ai/claude-code) and run 'claude' to authenticate",
		vim.log.levels.INFO
	)
	vim.notify("[dwight]   2. Enter an API key manually", vim.log.levels.INFO)

	M._prompt_manual_token()
end

function M._prompt_manual_token()
	require("dwight.select").pick({
		"Paste OAuth token (from Claude Code / browser)",
		"Enter API key (from console.anthropic.com)",
		"Cancel",
	}, { prompt = "Authentication method:" }, function(choice)
		if not choice or choice == "Cancel" then
			return
		end

		if choice:match("^Paste OAuth") then
			vim.ui.input({ prompt = "OAuth token: " }, function(token)
				if not token or token == "" then
					return
				end

				M._write_oauth_token({
					access_token = vim.trim(token),
					expires_in = 3600,
				})
				M._active_provider = "anthropic_max"
				M._active_model = M._providers.anthropic_max.models[M._providers.anthropic_max.default_model]
				M.save_global()
				vim.notify("[dwight] ✅ Token stored! Switched to anthropic_max.", vim.log.levels.INFO)
			end)
		elseif choice:match("^Enter API key") then
			vim.ui.input({ prompt = "API key (sk-ant-...): " }, function(key)
				if not key or key == "" then
					return
				end

				-- Store as regular API key on the anthropic_max provider
				M._providers.anthropic_max.api_key = vim.trim(key)
				-- Override auth to use x-api-key style for API keys
				M._providers.anthropic_max.auth_header = "x-api-key"
				M._providers.anthropic_max.auth_prefix = nil
				M._active_provider = "anthropic_max"
				M._active_model = M._providers.anthropic_max.models[M._providers.anthropic_max.default_model]
				M.save_global()
				vim.notify("[dwight] ✅ API key stored! Switched to anthropic_max.", vim.log.levels.INFO)
			end)
		end
	end)
end

--------------------------------------------------------------------
-- List all model names (for completion)
--------------------------------------------------------------------

function M.all_model_names()
	if not next(M._providers) then
		M.load()
	end
	local names = {}
	local seen = {}

	for pname, p in pairs(M._providers) do
		if p.models then
			for alias, _ in pairs(p.models) do
				if not seen[alias] then
					names[#names + 1] = alias
					seen[alias] = true
				end
				names[#names + 1] = pname .. ":" .. alias
			end
		end
	end
	table.sort(names)
	return names
end

--- List models available for the current backend.
--- For "api": only providers with a valid API key.
--- For "claude_code": Anthropic models (no API key needed, claude CLI handles auth).
--- For "opencode": all configured models (opencode manages its own keys).
function M.available_models_for_backend(arglead)
	local cfg = require("dwight").config
	local backend = cfg.backend or "api"

	if backend == "claude_code" then
		-- Claude Code supports these models via --model flag.
		-- No API key or provider lookup needed — claude CLI handles auth.
		local models = { "haiku", "opus", "sonnet" }
		if arglead and arglead ~= "" then
			return vim.tbl_filter(function(n)
				return vim.startswith(n, arglead)
			end, models)
		end
		return models
	end

	-- For api/opencode, we need providers loaded
	if not next(M._providers) then
		M.load()
	end

	local names = {}
	local seen = {}

	if backend == "opencode" then
		-- opencode manages its own auth — show all configured models
		for pname, p in pairs(M._providers) do
			if p.models then
				for alias, _ in pairs(p.models) do
					if not seen[alias] then
						names[#names + 1] = alias
						seen[alias] = true
					end
					local full = pname .. ":" .. alias
					if not seen[full] then
						names[#names + 1] = full
						seen[full] = true
					end
				end
			end
		end
	else -- "api"
		-- Only show providers that have a valid API key
		for pname, p in pairs(M._providers) do
			local key = M.get_api_key(p)
			if key then
				if p.models then
					for alias, _ in pairs(p.models) do
						if not seen[alias] then
							names[#names + 1] = alias
							seen[alias] = true
						end
						local full = pname .. ":" .. alias
						if not seen[full] then
							names[#names + 1] = full
							seen[full] = true
						end
					end
				end
			end
		end
	end

	table.sort(names)
	if arglead and arglead ~= "" then
		return vim.tbl_filter(function(n)
			return vim.startswith(n, arglead)
		end, names)
	end
	return names
end

--------------------------------------------------------------------
-- Interactive Setup Wizard (all vim.ui.input — no select)
--------------------------------------------------------------------

local VALID_FORMATS = { openai = true, anthropic = true, gemini = true, custom = true }

function M.add_provider_wizard()
	vim.ui.input({ prompt = "Provider name (e.g., 'myapi'): " }, function(name)
		if not name or name == "" then
			return
		end
		name = name:lower():gsub("[^%w_%-]", "")

		vim.ui.input({ prompt = "API format (openai/anthropic/gemini/custom): " }, function(format)
			if not format or format == "" then
				return
			end
			format = vim.trim(format):lower()
			if not VALID_FORMATS[format] then
				-- Treat unknown as openai-compatible
				vim.notify("[dwight] Unknown format '" .. format .. "', using openai-compatible.", vim.log.levels.INFO)
				format = "openai"
			end

			vim.ui.input({ prompt = "Base URL (e.g., https://api.example.com): " }, function(base_url)
				if not base_url or base_url == "" then
					return
				end

				local default_ep = "/v1/chat/completions"
				if format == "anthropic" then
					default_ep = "/v1/messages"
				elseif format == "gemini" then
					default_ep = "/v1beta/models/{model}:generateContent"
				end

				vim.ui.input({ prompt = "API endpoint [" .. default_ep .. "]: ", default = default_ep }, function(ep)
					ep = (ep and ep ~= "") and ep or default_ep

					vim.ui.input({ prompt = "API key env var (e.g., MY_API_KEY): " }, function(env_var)
						if not env_var or env_var == "" then
							return
						end

						vim.ui.input({ prompt = "Default model ID: " }, function(default_model)
							if not default_model or default_model == "" then
								return
							end

							vim.ui.input(
								{ prompt = "Model aliases (alias=id,alias=id or Enter to skip): " },
								function(aliases_str)
									local models = {}
									if aliases_str and aliases_str ~= "" then
										for pair in aliases_str:gmatch("[^,]+") do
											local a, id = pair:match("^%s*(%w+)%s*=%s*(.+)%s*$")
											if a and id then
												models[a] = id
											end
										end
									end
									models["default"] = default_model

									local provider = {
										name = name,
										api_key_env = env_var,
										base_url = base_url,
										endpoint = ep,
										format = format,
										headers = {},
										auth_header = format == "anthropic" and "x-api-key" or "Authorization",
										auth_prefix = format ~= "anthropic" and "Bearer " or nil,
										models = models,
										default_model = "default",
									}

									if format == "anthropic" then
										provider.headers["anthropic-version"] = "2023-06-01"
									end

									M._providers[name] = provider
									M.save_global()

									vim.notify(
										string.format(
											"[dwight] Provider '%s' added! Use !%s:default or :DwightSwitch %s",
											name,
											name,
											name
										),
										vim.log.levels.INFO
									)
								end
							)
						end)
					end)
				end)
			end)
		end)
	end)
end

--------------------------------------------------------------------
-- Switch / Status
--------------------------------------------------------------------

function M.switch(model_str)
	local cfg = require("dwight").config
	local backend = cfg.backend or "api"

	if backend == "claude_code" then
		-- ONLY set claude_code_model. Do NOT set cfg.model — that would poison
		-- the provider system (providers.load reads cfg.model and sets _active_model).
		cfg.claude_code_model = model_str
		pcall(function()
			require("dwight.tracker").set_model(model_str)
		end)
		vim.notify(string.format("[dwight] Switched to %s (claude_code)", model_str), vim.log.levels.INFO)
		return
	end

	local resolved = M.resolve_model(model_str)
	if not resolved.provider then
		vim.notify("[dwight] Unknown model/provider: " .. model_str, vim.log.levels.ERROR)
		return
	end

	if backend == "api" then
		local key = M.get_api_key(resolved.provider)
		if not key then
			vim.notify(
				string.format(
					"[dwight] No API key for %s. Set %s env var.",
					resolved.provider_name,
					resolved.provider.api_key_env or "?"
				),
				vim.log.levels.WARN
			)
		end
	end

	M._active_provider = resolved.provider_name
	M._active_model = resolved.model_id
	M.save_global()

	-- Update tracker to reflect the switch
	pcall(function()
		require("dwight.tracker").set_model(resolved.model_id)
	end)

	vim.notify(
		string.format("[dwight] Switched to %s / %s (%s backend)", resolved.provider_name, resolved.model_id, backend),
		vim.log.levels.INFO
	)
end

function M.show_current()
	if not next(M._providers) then
		M.load()
	end
	local cfg = require("dwight").config
	local backend = cfg.backend or "api"
	local resolved = M.resolve_model(nil)
	local key_status

	if backend == "claude_code" then
		local model = cfg.claude_code_model or "sonnet"
		key_status = "✅ using claude CLI auth"
		vim.notify(
			string.format("[dwight] Backend: claude_code | Model: %s | %s", model, key_status),
			vim.log.levels.INFO
		)
		return
	end

	if backend == "opencode" then
		key_status = "✅ managed by opencode"
		vim.notify(
			string.format("[dwight] Backend: opencode | Model: %s | %s", resolved.model_id, key_status),
			vim.log.levels.INFO
		)
		return
	end

	local key = M.get_api_key(resolved.provider)
	if resolved.provider and resolved.provider.auth_type == "oauth" then
		key_status = key and "✅ OAuth token active" or "❌ no token (run :DwightAuthMax)"
	else
		key_status = key and "✅ key set" or "❌ no key"
	end

	vim.notify(
		string.format(
			"[dwight] Backend: api | Provider: %s | Model: %s | %s",
			resolved.provider_name,
			resolved.model_id,
			key_status
		),
		vim.log.levels.INFO
	)
end

return M
