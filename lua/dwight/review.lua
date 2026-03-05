-- dwight/review.lua (formerly audit.lua)
-- Peer review: takes AI-generated code and passes it through a second model
-- for review. Adds review comments inline before applying.
-- Triggered by ~review or ~audit in the prompt.

local M = {}

--------------------------------------------------------------------
-- Build audit prompt
--------------------------------------------------------------------

local function build_audit_prompt(original_code, proposed_code, language, user_instructions)
	return string.format(
		[[
You are reviewing code changes proposed by another AI. Be critical and constructive.

Original code:
```%s
%s
```

Proposed changes:
```%s
%s
```

The changes were requested with: "%s"

Review the proposed changes and add inline review comments.
For each issue, add a comment on the relevant line using this format:
  // [REVIEW] Description of the issue or suggestion

Categories to check:
- Correctness: Does the code do what was asked? Any bugs introduced?
- Edge cases: Are there unhandled scenarios?
- Security: Any new vulnerabilities?
- Performance: Any regressions?
- Style: Does it match the surrounding code?
- Scope: Did it change more than necessary?

If the code is good, still add 1-2 positive comments like:
  // [REVIEW:OK] Good use of guard clause here

Return the PROPOSED code with your review comments added inline.
Wrap in a fenced code block (```%s ... ```).
]],
		language,
		original_code,
		language,
		proposed_code,
		user_instructions or "",
		language
	)
end

--------------------------------------------------------------------
-- Run audit pass
--------------------------------------------------------------------

--- Run a peer review on proposed code before applying.
--- callback(reviewed_code, err)
function M.review(original_code, proposed_code, language, user_instructions, audit_model, callback)
	local prompt = build_audit_prompt(original_code, proposed_code, language, user_instructions)
	local cfg = require("dwight").config
	local providers = require("dwight.providers")

	-- Resolve the audit model
	local resolved = providers.resolve_model(audit_model)
	if not resolved or not resolved.provider then
		-- Fall back to current model
		resolved = providers.resolve_model(nil)
	end

	if not resolved or not resolved.provider then
		callback(nil, "No provider for audit model")
		return
	end

	local api_key = providers.get_api_key(resolved.provider)
	if not api_key then
		callback(nil, "No API key for audit provider")
		return
	end

	local format = resolved.provider.format or "openai"
	local payload
	if format == "anthropic" then
		payload = vim.json.encode({
			model = resolved.model_id,
			max_tokens = cfg.max_tokens or 4096,
			messages = { { role = "user", content = prompt } },
		})
	elseif format == "gemini" then
		payload = vim.json.encode({ contents = { { parts = { { text = prompt } } } } })
	else
		payload = vim.json.encode({
			model = resolved.model_id,
			max_tokens = cfg.max_tokens or 4096,
			messages = { { role = "user", content = prompt } },
		})
	end

	local payload_file = vim.fn.tempname() .. "_dwight_audit.json"
	local f = io.open(payload_file, "w")
	if not f then
		callback(nil, "Failed to write payload")
		return
	end
	f:write(payload)
	f:close()

	local endpoint = resolved.provider.endpoint or "/v1/messages"
	if format == "gemini" then
		endpoint = endpoint:gsub("{model}", resolved.model_id)
	end
	local url = (resolved.provider.base_url or "") .. endpoint

	local curl_args = {
		"-sS",
		"--max-time",
		tostring(math.floor((cfg.timeout or 120000) / 1000)),
		"-X",
		"POST",
		url,
		"-H",
		"Content-Type: application/json",
	}
	if resolved.provider.auth_header then
		table.insert(curl_args, "-H")
		table.insert(
			curl_args,
			resolved.provider.auth_header .. ": " .. (resolved.provider.auth_prefix or "") .. api_key
		)
	end
	if resolved.provider.auth_query then
		curl_args[6] = url .. "?key=" .. api_key
	end
	if resolved.provider.headers then
		for k, v in pairs(resolved.provider.headers) do
			table.insert(curl_args, "-H")
			table.insert(curl_args, k .. ": " .. v)
		end
	end
	table.insert(curl_args, "-d")
	table.insert(curl_args, "@" .. payload_file)

	local uv = vim.loop or vim.uv
	local chunks, err_chunks = {}, {}
	local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
	local handle
	handle = uv.spawn("curl", {
		args = curl_args,
		stdio = { nil, stdout, stderr },
	}, function(code)
		if stdout then
			stdout:close()
		end
		if stderr then
			stderr:close()
		end
		if handle then
			handle:close()
		end
		pcall(os.remove, payload_file)

		vim.schedule(function()
			if code ~= 0 then
				callback(nil, "Audit request failed")
				return
			end

			local raw = table.concat(chunks, "")
			local ok, resp = pcall(vim.json.decode, raw)
			if not ok then
				callback(nil, "Invalid JSON from audit")
				return
			end

			-- Extract text from response
			local text = ""
			if format == "anthropic" then
				if resp.content then
					for _, b in ipairs(resp.content) do
						if b.type == "text" then
							text = text .. b.text
						end
					end
				end
			elseif format == "gemini" then
				if resp.candidates then
					for _, c in ipairs(resp.candidates) do
						if c.content and c.content.parts then
							for _, p in ipairs(c.content.parts) do
								if p.text then
									text = text .. p.text
								end
							end
						end
					end
				end
			else
				if resp.choices then
					for _, c in ipairs(resp.choices) do
						if c.message and c.message.content then
							text = text .. c.message.content
						end
					end
				end
			end

			-- Extract code block from response (robust: handles varied formatting)
			local reviewed = nil

			-- Strategy 1: standard ```lang\n...\n```
			reviewed = text:match("```%w*%s*\n(.-)\n%s*```")

			-- Strategy 2: handle ``` with no trailing newline before close
			if not reviewed then
				reviewed = text:match("```%w*%s*\n(.-)```")
			end

			-- Strategy 3: find all code blocks, pick the largest
			if not reviewed then
				local blocks = {}
				local pos = 1
				while true do
					local s = text:find("```", pos, true)
					if not s then
						break
					end
					local line_end = text:find("\n", s)
					if not line_end then
						break
					end
					local block_end = text:find("```", line_end + 1, true)
					if not block_end then
						break
					end
					local block = text:sub(line_end + 1, block_end - 1):gsub("^%s+", ""):gsub("%s+$", "")
					if #block > 0 then
						blocks[#blocks + 1] = block
					end
					pos = block_end + 3
				end
				if #blocks > 0 then
					reviewed = blocks[1]
					for _, b in ipairs(blocks) do
						if #b > #reviewed then
							reviewed = b
						end
					end
				end
			end

			-- Strategy 4: no fences — if response has [REVIEW] comments, it IS the code
			if not reviewed and text:match("%[REVIEW") then
				local stripped = text:gsub("^%s*Here.-\n", ""):gsub("^%s*I.-\n", ""):gsub("^%s*The.-\n", "")
				stripped = vim.trim(stripped)
				if #stripped > 0 then
					reviewed = stripped
				end
			end

			if reviewed then
				reviewed = vim.trim(reviewed)
				callback(reviewed, nil)
			else
				callback(nil, "No code block in audit response")
			end
		end)
	end)
	if not handle then
		pcall(os.remove, payload_file)
		callback(nil, "spawn failed")
		return
	end
	stdout:read_start(function(e, d)
		if not e and d then
			chunks[#chunks + 1] = d
		end
	end)
	stderr:read_start(function(e, d)
		if not e and d then
			err_chunks[#err_chunks + 1] = d
		end
	end)
end

return M
