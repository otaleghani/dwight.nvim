-- dwight/split/apply.lua
-- Apply a split proposal: rewrite @feature pragmas in source files.

local M = {}

local api = vim.api

--- Apply a split proposal: replace @feature:parent with @feature:sub in each file.
--- Returns the number of files modified.
function M._apply_split(proposal)
	local cwd = vim.fn.getcwd()
	local modified = 0

	-- Build reverse lookup: file_path -> new sub-feature name
	local file_mapping = {}
	for _, sf in ipairs(proposal.sub_features) do
		for _, fp in ipairs(sf.files) do
			file_mapping[fp] = sf
		end
	end

	local parent_name = proposal.parent

	-- Process each file
	for file_path, sf in pairs(file_mapping) do
		local full_path = file_path
		if not full_path:match("^/") then
			full_path = cwd .. "/" .. full_path
		end

		local f = io.open(full_path, "r")
		if not f then
			goto continue
		end

		local content = f:read("*a")
		f:close()

		-- Replace @feature:parent_name with @feature:new_name
		-- Match the exact feature name to avoid partial matches
		-- (e.g., @feature:auth should not match @feature:auth-middleware)
		local new_content, count =
			content:gsub("(@feature:)" .. vim.pesc(parent_name) .. "(%s)", "%1" .. sf.name .. "%2")

		-- Also handle end-of-line case (no trailing space)
		if count == 0 then
			new_content, count = content:gsub("(@feature:)" .. vim.pesc(parent_name) .. "$", "%1" .. sf.name)
		end

		-- Handle case where pragma is at end of a comment line: // @feature:auth\n
		if count == 0 then
			new_content, count = content:gsub("(@feature:)" .. vim.pesc(parent_name) .. "(\n)", "%1" .. sf.name .. "%2")
		end

		-- Handle case where pragma is followed by other pragmas or punctuation
		if count == 0 then
			new_content, count =
				content:gsub("(@feature:)" .. vim.pesc(parent_name) .. "([^%w_%-%.%s])", "%1" .. sf.name .. "%2")
		end

		if count == 0 then
			goto continue
		end

		-- Add sub-feature description if the file doesn't already have one
		-- Only add if the sub-feature description differs from the parent
		if sf.description and sf.description ~= "" then
			-- Check if there's already a description on the pragma line
			local has_desc = false
			for line in new_content:gmatch("[^\n]+") do
				if line:match("@feature:" .. vim.pesc(sf.name)) then
					-- Check if there's text besides the pragma
					local stripped = line:gsub("@feature:" .. vim.pesc(sf.name), "")
					stripped = stripped:gsub("^[/%*#%-;%%%(]+%s*", ""):gsub("%s*[%*/)%-;%%]+$", "")
					if vim.trim(stripped) ~= "" then
						has_desc = true
					end
					break
				end
			end

			if not has_desc then
				-- Detect comment style from the pragma line
				local comment_prefix = "//"
				for line in new_content:gmatch("[^\n]+") do
					if line:match("@feature:" .. vim.pesc(sf.name)) then
						if line:match("^%s*#") then
							comment_prefix = "#"
						elseif line:match("^%s*%-%-") then
							comment_prefix = "--"
						elseif line:match("^%s*//") then
							comment_prefix = "//"
						end
						break
					end
				end

				-- Append description after the pragma tag on the same line
				new_content = new_content:gsub("(@feature:" .. vim.pesc(sf.name) .. ")", "%1 " .. sf.description)
			end
		end

		-- Write back
		local wf = io.open(full_path, "w")
		if wf then
			wf:write(new_content)
			wf:close()
			modified = modified + 1

			-- Refresh Neovim buffer if open
			vim.schedule(function()
				for _, bufnr in ipairs(api.nvim_list_bufs()) do
					if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_get_name(bufnr) == full_path then
						api.nvim_buf_call(bufnr, function()
							vim.cmd("edit!")
						end)
					end
				end
			end)
		end

		::continue::
	end

	return modified
end

return M
