-- dwight/inline/api.lua
-- Payload building and HTTP API calls via curl.

local M = {}

local uv = vim.loop or vim.uv

function M.build_payload(format, prompt_text, model_id, max_tokens)
	if format == "anthropic" then
		local body =
			{ model = model_id, max_tokens = max_tokens, messages = { { role = "user", content = prompt_text } } }
		return vim.json.encode(body)
	elseif format == "gemini" then
		return vim.json.encode({ contents = { { parts = { { text = prompt_text } } } } })
	else
		local body =
			{ model = model_id, max_tokens = max_tokens, messages = { { role = "user", content = prompt_text } } }
		return vim.json.encode(body)
	end
end

function M.extract_text(format, resp)
	local parts = {}
	if format == "anthropic" then
		if resp.content then
			for _, b in ipairs(resp.content) do
				if b.type == "text" then
					parts[#parts + 1] = b.text
				end
			end
		end
		if resp.usage then
			parts[#parts + 1] = string.format(
				"\n\n<!-- tokens: %d in, %d out -->",
				resp.usage.input_tokens or 0,
				resp.usage.output_tokens or 0
			)
		end
	elseif format == "gemini" then
		if resp.candidates then
			for _, c in ipairs(resp.candidates) do
				if c.content and c.content.parts then
					for _, p in ipairs(c.content.parts) do
						if p.text then
							parts[#parts + 1] = p.text
						end
					end
				end
			end
		end
	else
		if resp.choices then
			for _, c in ipairs(resp.choices) do
				if c.message and c.message.content then
					parts[#parts + 1] = c.message.content
				end
			end
		end
		if resp.usage then
			parts[#parts + 1] = string.format(
				"\n\n<!-- tokens: %d in, %d out -->",
				resp.usage.prompt_tokens or 0,
				resp.usage.completion_tokens or 0
			)
		end
	end
	return table.concat(parts, "\n")
end

function M.api_call(prompt_text, model_override, cfg, callback, opts)
	opts = opts or {}
	local providers = require("dwight.providers")
	local resolved = providers.resolve_model(model_override)
	local provider = resolved.provider
	local model_id = resolved.model_id

	if not provider then
		callback(nil, "No provider configured")
		return
	end

	local api_key = providers.get_api_key(provider)
	if not api_key then
		callback(nil, "No API key for " .. resolved.provider_name)
		return
	end

	local format = provider.format or "openai"
	local max_tokens = cfg.max_tokens or 4096
	local payload = M.build_payload(format, prompt_text, model_id, max_tokens)

	-- Track the model being used
	pcall(function()
		require("dwight.tracker").set_model(model_id)
	end)

	local payload_file = vim.fn.tempname() .. "_dwight_payload.json"
	local f = io.open(payload_file, "w")
	if not f then
		callback(nil, "Failed to write payload")
		return
	end
	f:write(payload)
	f:close()

	-- Build URL
	local endpoint = provider.endpoint or "/v1/messages"
	if format == "gemini" then
		endpoint = endpoint:gsub("{model}", model_id)
	end
	local url = (provider.base_url or "") .. endpoint

	-- curl args
	local curl_args = {
		"-sS",
		"--max-time",
		tostring(math.floor(cfg.timeout / 1000)),
		"-X",
		"POST",
		url,
		"-H",
		"Content-Type: application/json",
	}
	if provider.auth_header then
		table.insert(curl_args, "-H")
		table.insert(curl_args, provider.auth_header .. ": " .. (provider.auth_prefix or "") .. api_key)
	end
	if provider.auth_query then
		curl_args[6] = url .. "?key=" .. api_key
	end
	if provider.headers then
		for k, v in pairs(provider.headers) do
			table.insert(curl_args, "-H")
			table.insert(curl_args, k .. ": " .. v)
		end
	end
	table.insert(curl_args, "-d")
	table.insert(curl_args, "@" .. payload_file)

	local stdout_chunks = {}
	local stderr_chunks = {}
	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)

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
			local err_output = table.concat(stderr_chunks, "")

			if code ~= 0 then
				callback(nil, "curl failed: " .. err_output)
				return
			end

			-- Parse full JSON response
			local raw_json = table.concat(stdout_chunks, "")
			local ok, resp = pcall(vim.json.decode, raw_json)
			if not ok then
				callback(nil, "Invalid JSON")
				return
			end
			if resp.error then
				local msg = type(resp.error) == "table" and (resp.error.message or vim.inspect(resp.error))
					or tostring(resp.error)
				callback(nil, msg)
				return
			end

			callback(M.extract_text(format, resp), nil)
		end)
	end)

	if not handle then
		pcall(os.remove, payload_file)
		callback(nil, "Failed to spawn curl")
		return
	end

	stdout:read_start(function(err, data)
		if not err and data then
			stdout_chunks[#stdout_chunks + 1] = data
		end
	end)
	stderr:read_start(function(err, data)
		if not err and data then
			stderr_chunks[#stderr_chunks + 1] = data
		end
	end)

	return handle -- for cancellation
end

return M
