-- dwight/config.lua
-- Config validation and migration. Called from setup() to catch typos and
-- invalid values early instead of surfacing them as mysterious failures later.

local M = {}

--- Valid backend names.
local VALID_BACKENDS = {
	claude_code = true,
	codex = true,
	gemini = true,
	opencode = true,
}

--- Valid on_partial_failure values.
local VALID_PARTIAL_FAILURE = {
	continue = true,
	stop = true,
}

--------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------

--- Validate config values. Returns a list of { level, msg } where level is "WARN" or "ERROR".
--- @param cfg table The merged config (M.defaults + user opts)
--- @return table messages List of { level = "WARN"|"ERROR", msg = string }
function M.validate(cfg)
	local msgs = {}

	-- Backend
	if cfg.backend and not VALID_BACKENDS[cfg.backend] then
		msgs[#msgs + 1] = {
			level = "ERROR",
			msg = string.format(
				"Unknown backend '%s'. Valid: %s",
				tostring(cfg.backend),
				table.concat(vim.tbl_keys(VALID_BACKENDS), ", ")
			),
		}
	end

	-- Timeouts: must be positive numbers
	if cfg.timeout and (type(cfg.timeout) ~= "number" or cfg.timeout <= 0) then
		msgs[#msgs + 1] = {
			level = "WARN",
			msg = string.format("timeout should be a positive number (ms), got: %s", tostring(cfg.timeout)),
		}
	end

	local ac = cfg.agentic_opts
	if ac then
		if ac.cli_timeout and (type(ac.cli_timeout) ~= "number" or ac.cli_timeout <= 0) then
			msgs[#msgs + 1] = {
				level = "WARN",
				msg = string.format(
					"agentic_opts.cli_timeout should be a positive number (seconds), got: %s",
					tostring(ac.cli_timeout)
				),
			}
		end
		if ac.max_output_tokens and (type(ac.max_output_tokens) ~= "number" or ac.max_output_tokens <= 0) then
			msgs[#msgs + 1] = {
				level = "WARN",
				msg = string.format(
					"agentic_opts.max_output_tokens should be a positive number, got: %s",
					tostring(ac.max_output_tokens)
				),
			}
		end
		if ac.reflection ~= nil and type(ac.reflection) ~= "boolean" then
			msgs[#msgs + 1] = {
				level = "WARN",
				msg = string.format("agentic_opts.reflection should be a boolean, got: %s", type(ac.reflection)),
			}
		end
	end

	-- Swarm opts
	local so = cfg.swarm_opts
	if so then
		if so.on_partial_failure and not VALID_PARTIAL_FAILURE[so.on_partial_failure] then
			msgs[#msgs + 1] = {
				level = "WARN",
				msg = string.format(
					"swarm_opts.on_partial_failure should be 'continue' or 'stop', got: '%s'",
					tostring(so.on_partial_failure)
				),
			}
		end
		if so.max_parallel and (type(so.max_parallel) ~= "number" or so.max_parallel <= 0) then
			msgs[#msgs + 1] = {
				level = "WARN",
				msg = string.format(
					"swarm_opts.max_parallel should be a positive number, got: %s",
					tostring(so.max_parallel)
				),
			}
		end
	end

	-- Cost limits
	local cl = cfg.cost_limits
	if cl then
		if cl.per_session ~= nil and (type(cl.per_session) ~= "number" or cl.per_session <= 0) then
			msgs[#msgs + 1] = {
				level = "WARN",
				msg = string.format(
					"cost_limits.per_session should be a positive number, got: %s",
					tostring(cl.per_session)
				),
			}
		end
		if cl.per_day ~= nil and (type(cl.per_day) ~= "number" or cl.per_day <= 0) then
			msgs[#msgs + 1] = {
				level = "WARN",
				msg = string.format("cost_limits.per_day should be a positive number, got: %s", tostring(cl.per_day)),
			}
		end
		if cl.warn_threshold ~= nil then
			if type(cl.warn_threshold) ~= "number" or cl.warn_threshold < 0 or cl.warn_threshold > 1 then
				msgs[#msgs + 1] = {
					level = "WARN",
					msg = string.format(
						"cost_limits.warn_threshold should be a number between 0.0 and 1.0, got: %s",
						tostring(cl.warn_threshold)
					),
				}
			end
		end
	end

	return msgs
end

--------------------------------------------------------------------
-- Deprecation migration
--------------------------------------------------------------------

--- Migrate deprecated config keys in-place.
--- Currently: agentic_opts.claude_code_timeout → cli_timeout
--- @param cfg table The merged config
--- @return table messages List of { level, msg } for any migrations performed
function M.migrate_deprecated(cfg)
	local msgs = {}
	local ac = cfg.agentic_opts
	if not ac then
		return msgs
	end

	if ac.claude_code_timeout and not ac.cli_timeout then
		-- Migrate: rename to cli_timeout
		ac.cli_timeout = ac.claude_code_timeout
		msgs[#msgs + 1] = {
			level = "WARN",
			msg = "agentic_opts.claude_code_timeout is deprecated, use agentic_opts.cli_timeout instead",
		}
	elseif ac.claude_code_timeout and ac.cli_timeout then
		-- Both set: cli_timeout wins, just warn
		msgs[#msgs + 1] = {
			level = "WARN",
			msg = "Both agentic_opts.cli_timeout and claude_code_timeout are set; cli_timeout takes precedence",
		}
	end

	return msgs
end

--------------------------------------------------------------------
-- Unknown key detection
--------------------------------------------------------------------

--- Known top-level keys in M.defaults.
local KNOWN_TOP = {
	"backend",
	"provider",
	"model",
	"api_key",
	"max_tokens",
	"test_model",
	"implement_model",
	"claude_code_bin",
	"claude_code_model",
	"codex_bin",
	"codex_model",
	"gemini_bin",
	"gemini_model",
	"opencode_bin",
	"opencode_flags",
	"default_skills",
	"lsp_context_lines",
	"include_diagnostics",
	"include_type_info",
	"include_references",
	"max_references",
	"indicator_style",
	"indicator_sign",
	"indicator_hl",
	"border",
	"comment_styles",
	"timeout",
	"git_context",
	"parallel_steps",
	"agentic_opts",
	"swarm_opts",
	"cost_limits",
	"mcp_servers",
	"languages",
	"modes",
	"agent_checkpoint",
	"agent_gates",
}

local KNOWN_AGENTIC = {
	"max_output_tokens",
	"cli_timeout",
	"claude_code_timeout",
	"reflection",
}

local KNOWN_SWARM = {
	"max_parallel",
	"on_partial_failure",
	"cleanup_worktrees",
	"auto_resolve",
}

local KNOWN_COST_LIMITS = {
	"per_session",
	"per_day",
	"warn_threshold",
}

--- Build a lookup set from a list.
local function to_set(list)
	local s = {}
	for _, k in ipairs(list) do
		s[k] = true
	end
	return s
end

--- Find unknown keys in user opts.
--- Skips extensible tables (languages, modes, mcp_servers).
--- @param opts table The raw user opts passed to setup()
--- @return table messages List of { level, msg }
function M.find_unknown_keys(opts)
	if not opts then
		return {}
	end

	local msgs = {}
	local top_set = to_set(KNOWN_TOP)

	for key, _ in pairs(opts) do
		if not top_set[key] then
			msgs[#msgs + 1] = {
				level = "WARN",
				msg = string.format("Unknown config key '%s' — possible typo?", key),
			}
		end
	end

	-- Check nested agentic_opts
	if opts.agentic_opts and type(opts.agentic_opts) == "table" then
		local ac_set = to_set(KNOWN_AGENTIC)
		for key, _ in pairs(opts.agentic_opts) do
			if not ac_set[key] then
				msgs[#msgs + 1] = {
					level = "WARN",
					msg = string.format("Unknown agentic_opts key '%s' — possible typo?", key),
				}
			end
		end
	end

	-- Check nested swarm_opts
	if opts.swarm_opts and type(opts.swarm_opts) == "table" then
		local sw_set = to_set(KNOWN_SWARM)
		for key, _ in pairs(opts.swarm_opts) do
			if not sw_set[key] then
				msgs[#msgs + 1] = {
					level = "WARN",
					msg = string.format("Unknown swarm_opts key '%s' — possible typo?", key),
				}
			end
		end
	end

	-- Check nested cost_limits
	if opts.cost_limits and type(opts.cost_limits) == "table" then
		local cl_set = to_set(KNOWN_COST_LIMITS)
		for key, _ in pairs(opts.cost_limits) do
			if not cl_set[key] then
				msgs[#msgs + 1] = {
					level = "WARN",
					msg = string.format("Unknown cost_limits key '%s' — possible typo?", key),
				}
			end
		end
	end

	return msgs
end

--------------------------------------------------------------------
-- Backend binary check
--------------------------------------------------------------------

--- Check if the configured backend binary exists in $PATH.
--- @param cfg table The merged config
--- @return table messages List of { level, msg }
function M.check_backend_binary(cfg)
	local msgs = {}
	local backend = cfg.backend or "claude_code"

	local bin_map = {
		claude_code = cfg.claude_code_bin or "claude",
		codex = cfg.codex_bin or "codex",
		gemini = cfg.gemini_bin or "gemini",
		opencode = cfg.opencode_bin or "opencode",
	}

	local hints = {
		claude_code = "npm i -g @anthropic-ai/claude-code",
		codex = "npm i -g @openai/codex",
		gemini = "npm i -g @google/gemini-cli",
		opencode = "go install github.com/opencode-ai/opencode@latest",
	}

	local bin = bin_map[backend]
	if not bin then
		return msgs
	end

	if vim.fn.exepath(bin) == "" then
		msgs[#msgs + 1] = {
			level = "WARN",
			msg = string.format("Backend binary '%s' not found in $PATH. Install: %s", bin, hints[backend] or "?"),
		}
	end

	return msgs
end

--------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------

--- Run all config checks and emit messages via vim.notify.
--- @param cfg table The merged config
--- @param user_opts table|nil The raw user opts passed to setup()
function M.check_all(cfg, user_opts)
	local all_msgs = {}

	-- 1. Migrate deprecated keys (modifies cfg in-place)
	local migrate_msgs = M.migrate_deprecated(cfg)
	for _, m in ipairs(migrate_msgs) do
		all_msgs[#all_msgs + 1] = m
	end

	-- 2. Validate values
	local validate_msgs = M.validate(cfg)
	for _, m in ipairs(validate_msgs) do
		all_msgs[#all_msgs + 1] = m
	end

	-- 3. Unknown key detection
	local unknown_msgs = M.find_unknown_keys(user_opts)
	for _, m in ipairs(unknown_msgs) do
		all_msgs[#all_msgs + 1] = m
	end

	-- 4. Backend binary check
	local bin_msgs = M.check_backend_binary(cfg)
	for _, m in ipairs(bin_msgs) do
		all_msgs[#all_msgs + 1] = m
	end

	-- Emit
	for _, m in ipairs(all_msgs) do
		local level = m.level == "ERROR" and vim.log.levels.ERROR or vim.log.levels.WARN
		vim.notify("[dwight] config: " .. m.msg, level)
	end
end

return M
