-- dwight/bootstrap/scan.lua
-- Scan project structure and build a snapshot for the LLM.

local M = {}

local SKIP_DIRS = {
	node_modules = true,
	[".git"] = true,
	dist = true,
	build = true,
	vendor = true,
	[".dwight"] = true,
	__pycache__ = true,
	[".next"] = true,
	[".nuxt"] = true,
	target = true,
	out = true,
	docs = true,
	coverage = true,
}

local SKIP_EXT = {
	[".png"] = true,
	[".jpg"] = true,
	[".jpeg"] = true,
	[".gif"] = true,
	[".svg"] = true,
	[".ico"] = true,
	[".woff"] = true,
	[".woff2"] = true,
	[".ttf"] = true,
	[".eot"] = true,
	[".mp3"] = true,
	[".mp4"] = true,
	[".zip"] = true,
	[".tar"] = true,
	[".gz"] = true,
	[".lock"] = true,
	[".min.js"] = true,
	[".min.css"] = true,
	[".map"] = true,
}

M.SKIP_DIRS = SKIP_DIRS
M.SKIP_EXT = SKIP_EXT

--- Scan project and build a snapshot for the LLM.
function M.scan()
	local cwd = vim.fn.getcwd()
	local uv = vim.loop or vim.uv
	local tree = {}
	local entry_files = {}
	local config_files = {}

	-- Entry point patterns
	local ENTRY_PATTERNS = {
		"^main%.",
		"^index%.",
		"^app%.",
		"^server%.",
		"^mod%.",
		"^lib%.",
		"^cmd/",
		"^src/main",
		"^src/index",
		"^src/app",
		"^src/lib",
		"^package%.json$",
		"^Cargo%.toml$",
		"^go%.mod$",
		"^pyproject%.toml$",
		"^setup%.py$",
		"^Makefile$",
		"^CMakeLists",
	}

	-- Config patterns
	local CONFIG_PATTERNS = {
		"%.config%.",
		"%.json$",
		"%.toml$",
		"%.yaml$",
		"%.yml$",
		"tsconfig",
		"webpack",
		"vite%.config",
		"next%.config",
		"Dockerfile",
		"docker%-compose",
	}

	local function is_entry(rel)
		for _, pat in ipairs(ENTRY_PATTERNS) do
			if rel:match(pat) then
				return true
			end
		end
		return false
	end

	local function is_config(rel)
		for _, pat in ipairs(CONFIG_PATTERNS) do
			if rel:match(pat) then
				return true
			end
		end
		return false
	end

	local function walk(dir, prefix)
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
					tree[#tree + 1] = rel .. "/"
					walk(full, rel)
				elseif ftype == "file" then
					local ext = name:match("(%.[^.]+)$") or ""
					if not SKIP_EXT[ext] then
						tree[#tree + 1] = rel
						if is_entry(rel) then
							entry_files[#entry_files + 1] = rel
						end
						if is_config(rel) then
							config_files[#config_files + 1] = rel
						end
					end
				end
			end
		end
	end

	walk(cwd, "")
	table.sort(tree)

	-- Read first 30 lines of entry files for context
	local entry_snippets = {}
	for _, rel in ipairs(entry_files) do
		local f = io.open(cwd .. "/" .. rel, "r")
		if f then
			local lines = {}
			for i = 1, 30 do
				local line = f:read("*l")
				if not line then
					break
				end
				lines[#lines + 1] = line
			end
			f:close()
			if #lines > 0 then
				entry_snippets[#entry_snippets + 1] = {
					path = rel,
					content = table.concat(lines, "\n"),
				}
			end
		end
	end

	return {
		tree = tree,
		entry_files = entry_files,
		config_files = config_files,
		entry_snippets = entry_snippets,
	}
end

return M
