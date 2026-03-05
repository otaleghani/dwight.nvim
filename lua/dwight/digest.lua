-- dwight/digest.lua
-- Codebase digest: pre-extracted summaries of project files.
-- Injected into agent context so the LLM already knows the codebase
-- structure without needing to read files via tool calls.
--
-- :DwightDigest          -- build/refresh digest
-- :DwightDigest --status -- show cache stats
-- :DwightDigest --clear  -- remove cached digest
--
-- Stored in .dwight/digest.json with per-file mtimes.
-- Incremental: only re-extracts files that changed since last build.

local M = {}

local uv = vim.loop or vim.uv

local function digest_path()
	return require("dwight.project").dir() .. "/digest.json"
end

local MAX_FILES = 200
local MAX_LINES_PER_FILE = 8
local MAX_DIGEST_SIZE = 12000

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
	coverage = true,
	[".cache"] = true,
	[".venv"] = true,
	venv = true,
	[".tox"] = true,
	[".mypy_cache"] = true,
	[".pytest_cache"] = true,
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
	[".sum"] = true,
	[".exe"] = true,
	[".dll"] = true,
	[".so"] = true,
	[".dylib"] = true,
	[".o"] = true,
	[".a"] = true,
	[".pdf"] = true,
	[".doc"] = true,
	[".docx"] = true,
}

local SOURCE_EXT = {
	[".lua"] = "lua",
	[".go"] = "go",
	[".ts"] = "typescript",
	[".tsx"] = "typescript",
	[".js"] = "javascript",
	[".jsx"] = "javascript",
	[".py"] = "python",
	[".rs"] = "rust",
	[".rb"] = "ruby",
	[".java"] = "java",
	[".kt"] = "kotlin",
	[".cs"] = "csharp",
	[".c"] = "c",
	[".cpp"] = "cpp",
	[".h"] = "c",
	[".hpp"] = "cpp",
	[".swift"] = "swift",
	[".zig"] = "zig",
	[".ex"] = "elixir",
	[".exs"] = "elixir",
	[".erl"] = "erlang",
	[".sh"] = "shell",
	[".bash"] = "shell",
	[".zsh"] = "shell",
	[".vue"] = "vue",
	[".svelte"] = "svelte",
}

--------------------------------------------------------------------
-- Per-language signature extraction (pure pattern matching, no LLM)
--------------------------------------------------------------------

local function extract_signatures(content, lang, _path)
	local lines = {}
	local seen = {}

	local function add(line)
		line = vim.trim(line)
		if line == "" or seen[line] then
			return
		end
		if #lines >= MAX_LINES_PER_FILE then
			return
		end
		seen[line] = true
		lines[#lines + 1] = line
	end

	if lang == "go" then
		local pkg = content:match("^package%s+(%S+)")
		if pkg then
			add("package " .. pkg)
		end
		for decl in content:gmatch("\ntype%s+(%S+%s+%S+)") do
			add("type " .. decl)
		end
		for sig in content:gmatch("\nfunc%s+([^\n{]+)") do
			local name = sig:match("^%(.-%)%s+([A-Z]%w*)") or sig:match("^([A-Z]%w*)")
			if name then
				add("func " .. sig:gsub("%s*{%s*$", ""))
			end
		end
		for iface in content:gmatch("\ntype%s+(%S+)%s+interface%s*{") do
			add("interface " .. iface .. " { ... }")
		end
	elseif lang == "typescript" or lang == "javascript" then
		for line in content:gmatch("\nexport%s+([^\n]+)") do
			local decl = line:gsub("%s*{[^}]*$", ""):gsub("%s*=>.*$", "")
			if #decl < 120 then
				add("export " .. decl)
			end
		end
		for kind in content:gmatch("\n(interface%s+%S+)") do
			add(kind)
		end
		for kind in content:gmatch("\ntype%s+(%S+%s*=)") do
			add("type " .. kind .. " ...")
		end
	elseif lang == "lua" then
		for sig in content:gmatch("\nfunction%s+(M%.%S+%s*%([^)]*%))") do
			add(sig)
		end
		for sig in content:gmatch("\nlocal%s+function%s+(%S+%s*%([^)]*%))") do
			local name = sig:match("^(%S+)%(")
			if name and #name > 2 and not name:match("^_[a-z]") then
				add("local " .. sig)
			end
		end
	elseif lang == "python" then
		local import_count = 0
		for imp in content:gmatch("\nfrom%s+(%S+)%s+import") do
			if import_count < 2 then
				add("from " .. imp .. " import ...")
				import_count = import_count + 1
			end
		end
		for cls in content:gmatch("\nclass%s+([^:(\n]+)") do
			add("class " .. vim.trim(cls))
		end
		for sig in content:gmatch("\ndef%s+([^\n:]+)") do
			local name = sig:match("^(%S+)%(")
			if name and not name:match("^_[a-z]") then
				add("def " .. sig)
			end
		end
	elseif lang == "rust" then
		for sig in content:gmatch("\npub%s+fn%s+([^\n{]+)") do
			add("pub fn " .. sig:gsub("%s*{%s*$", ""))
		end
		for kind in content:gmatch("\npub%s+(struct%s+%S+)") do
			add("pub " .. kind)
		end
		for kind in content:gmatch("\npub%s+(enum%s+%S+)") do
			add("pub " .. kind)
		end
		for kind in content:gmatch("\npub%s+(trait%s+%S+)") do
			add("pub " .. kind)
		end
		for impl in content:gmatch("\nimpl%s+([^\n{]+)") do
			add("impl " .. impl:gsub("%s*{%s*$", ""))
		end
	elseif lang == "ruby" then
		for cls in content:gmatch("\nclass%s+([^\n<]+)") do
			add("class " .. vim.trim(cls))
		end
		for mod in content:gmatch("\nmodule%s+(%S+)") do
			add("module " .. mod)
		end
		for sig in content:gmatch("\ndef%s+([^\n]+)") do
			local name = sig:match("^(%S+)")
			if name and not name:match("^_") then
				add("def " .. sig)
			end
		end
	elseif lang == "java" or lang == "kotlin" or lang == "csharp" then
		for cls in content:gmatch("\npublic%s+class%s+(%S+)") do
			add("public class " .. cls)
		end
		for sig in content:gmatch("\npublic%s+[%w<>%[%]]+%s+(%S+%s*%([^)]*%))") do
			add(sig)
		end
	elseif lang == "swift" then
		for sig in content:gmatch("\nfunc%s+([^\n{]+)") do
			add("func " .. sig:gsub("%s*{%s*$", ""))
		end
		for cls in content:gmatch("\nclass%s+(%S+)") do
			add("class " .. cls)
		end
		for s in content:gmatch("\nstruct%s+(%S+)") do
			add("struct " .. s)
		end
		for p in content:gmatch("\nprotocol%s+(%S+)") do
			add("protocol " .. p)
		end
	else
		for sig in content:gmatch("\nfunction%s+([^\n{]+)") do
			add("function " .. sig:gsub("%s*{%s*$", ""))
		end
		for sig in content:gmatch("\ndef%s+([^\n:]+)") do
			add("def " .. sig)
		end
	end

	if #lines == 0 then
		local first_comment = content:match("^%s*(//[^\n]+)")
			or content:match("^%s*(#[^\n]+)")
			or content:match("^%s*(%-%-[^\n]+)")
			or content:match("^%s*/%*%*?%s*([^\n]+)")
		if first_comment then
			add(vim.trim(first_comment))
		end
	end

	return table.concat(lines, "\n")
end

--------------------------------------------------------------------
-- File scanning
--------------------------------------------------------------------

local function scan_source_files()
	local cwd = vim.fn.getcwd()
	local files = {}

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
			if name:sub(1, 1) == "." and name ~= ".." then
				goto continue
			end
			if SKIP_DIRS[name] then
				goto continue
			end

			local rel = prefix ~= "" and (prefix .. "/" .. name) or name
			local full = dir .. "/" .. name

			if ftype == "directory" then
				walk(full, rel)
			elseif ftype == "file" then
				local ext = name:match("(%.[^.]+)$") or ""
				if SKIP_EXT[ext] then
					goto continue
				end
				local lang = SOURCE_EXT[ext]
				if lang then
					local stat = uv.fs_stat(full)
					local mtime = stat and stat.mtime and stat.mtime.sec or 0
					local size = stat and stat.size or 0
					if size < 100000 then
						files[#files + 1] = {
							path = rel,
							full = full,
							mtime = mtime,
							ext = ext,
							lang = lang,
							size = size,
						}
					end
				end
			end
			::continue::
		end
	end

	walk(cwd, "")
	return files
end

local function prioritize_files(files)
	local tagged = {}
	pcall(function()
		local features = require("dwight.features")
		for _, name in ipairs(features.names()) do
			local feat = features.build_feature(name)
			if feat and feat.files then
				for _, ff in ipairs(feat.files) do
					tagged[ff.path or ff] = true
				end
			end
		end
	end)

	local function is_entry(rel)
		return rel:match("^main%.")
			or rel:match("^index%.")
			or rel:match("^app%.")
			or rel:match("^server%.")
			or rel:match("^src/main")
			or rel:match("^src/index")
			or rel:match("^src/app")
			or rel:match("^cmd/")
			or rel:match("^lib/")
	end

	table.sort(files, function(a, b)
		local a_t = tagged[a.path] and 1 or 0
		local b_t = tagged[b.path] and 1 or 0
		if a_t ~= b_t then
			return a_t > b_t
		end
		local a_e = is_entry(a.path) and 1 or 0
		local b_e = is_entry(b.path) and 1 or 0
		if a_e ~= b_e then
			return a_e > b_e
		end
		return a.size > b.size
	end)

	return files
end

--------------------------------------------------------------------
-- Build / load / save
--------------------------------------------------------------------

function M.load()
	local path = digest_path()
	if vim.fn.filereadable(path) ~= 1 then
		return nil
	end
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, content)
	if ok and type(data) == "table" and data.version == 1 then
		return data
	end
	return nil
end

local function save(digest)
	local dir = require("dwight.project").dir()
	vim.fn.mkdir(dir, "p")
	local f = io.open(digest_path(), "w")
	if not f then
		return false
	end
	f:write(vim.json.encode(digest))
	f:close()
	return true
end

function M.build(opts)
	opts = opts or {}

	local project = require("dwight.project")
	if not project.is_initialized() then
		if not opts.silent then
			vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		end
		return nil
	end

	local cached = not opts.force and M.load() or nil
	local cached_files = cached and cached.files or {}

	local source_files = scan_source_files()
	source_files = prioritize_files(source_files)

	local file_count = math.min(#source_files, MAX_FILES)
	local reused, extracted = 0, 0

	local new_files = {}
	for i = 1, file_count do
		local sf = source_files[i]
		local cached_entry = cached_files[sf.path]
		if cached_entry and cached_entry.mtime == sf.mtime then
			new_files[sf.path] = cached_entry
			reused = reused + 1
		else
			local f = io.open(sf.full, "r")
			if f then
				local content = f:read("*a")
				f:close()
				local summary = extract_signatures(content, sf.lang, sf.path)
				if summary and summary ~= "" then
					new_files[sf.path] = { mtime = sf.mtime, lang = sf.lang, summary = summary }
					extracted = extracted + 1
				end
			end
		end
	end

	local git_head = nil
	pcall(function()
		local out = vim.fn.system("git rev-parse --short HEAD 2>/dev/null")
		if vim.v.shell_error == 0 then
			git_head = vim.trim(out)
		end
	end)

	local digest = {
		version = 1,
		built_at = os.time(),
		git_head = git_head,
		file_count = file_count,
		total_source_files = #source_files,
		files = new_files,
	}

	save(digest)

	if not opts.silent then
		vim.notify(
			string.format(
				"[dwight] Digest built: %d files (%d extracted, %d cached) from %d total",
				file_count,
				extracted,
				reused,
				#source_files
			),
			vim.log.levels.INFO
		)
	end

	return digest
end

--------------------------------------------------------------------
-- Staleness detection
--------------------------------------------------------------------

function M.is_stale()
	local cached = M.load()
	if not cached then
		return nil
	end

	local current_head = nil
	pcall(function()
		local out = vim.fn.system("git rev-parse --short HEAD 2>/dev/null")
		if vim.v.shell_error == 0 then
			current_head = vim.trim(out)
		end
	end)

	if current_head and cached.git_head and current_head ~= cached.git_head then
		return true
	end

	if cached.built_at and (os.time() - cached.built_at) > 3600 then
		return true
	end

	return false
end

function M.get(opts)
	opts = opts or {}

	local cached = M.load()
	if cached and not opts.force then
		local stale = M.is_stale()
		if not stale then
			return cached
		end
		return M.build({ silent = true })
	end

	if not cached then
		local project = require("dwight.project")
		if project.is_initialized() then
			return M.build({ silent = true })
		end
		return nil
	end

	return cached
end

--------------------------------------------------------------------
-- Format for prompt injection
--------------------------------------------------------------------

function M.format_for_prompt()
	local digest = M.get()
	if not digest or not digest.files then
		return nil
	end

	local parts = {}
	parts[#parts + 1] = "<codebase_digest>"
	parts[#parts + 1] = "Pre-extracted signatures of project files."
	parts[#parts + 1] = "Use these to understand the codebase WITHOUT reading files via tools."
	parts[#parts + 1] = "Only read a file when you need FULL implementation details."
	parts[#parts + 1] = ""

	local sorted = {}
	for path, entry in pairs(digest.files) do
		if entry.summary and entry.summary ~= "" then
			sorted[#sorted + 1] = { path = path, entry = entry }
		end
	end
	table.sort(sorted, function(a, b)
		return a.path < b.path
	end)

	local total_size = 0
	local included = 0
	for _, item in ipairs(sorted) do
		local block = string.format("### %s [%s]\n%s", item.path, item.entry.lang, item.entry.summary)
		if total_size + #block > MAX_DIGEST_SIZE then
			parts[#parts + 1] = string.format("... (%d more files omitted)", #sorted - included)
			break
		end
		parts[#parts + 1] = block
		total_size = total_size + #block
		included = included + 1
	end

	parts[#parts + 1] = "</codebase_digest>"

	if total_size == 0 then
		return nil
	end
	return table.concat(parts, "\n")
end

--------------------------------------------------------------------
-- Status / Clear
--------------------------------------------------------------------

function M.status()
	local cached = M.load()
	if not cached then
		vim.notify("[dwight] No digest cached. Run :DwightDigest to build one.", vim.log.levels.INFO)
		return
	end

	local stale = M.is_stale()
	local age_mins = cached.built_at and math.floor((os.time() - cached.built_at) / 60) or 0

	local file_count = 0
	local total_summary_lines = 0
	for _, entry in pairs(cached.files or {}) do
		file_count = file_count + 1
		if entry.summary then
			for _ in entry.summary:gmatch("\n") do
				total_summary_lines = total_summary_lines + 1
			end
			total_summary_lines = total_summary_lines + 1
		end
	end

	local prompt_text = M.format_for_prompt()
	local prompt_size = prompt_text and #prompt_text or 0

	vim.notify(
		string.format(
			"[dwight] Digest: %d/%d files | %d summary lines | %d chars | %s | %dm ago%s",
			file_count,
			cached.total_source_files or 0,
			total_summary_lines,
			prompt_size,
			cached.git_head or "no git",
			age_mins,
			stale and " (STALE)" or " (fresh)"
		),
		vim.log.levels.INFO
	)
end

function M.clear()
	local path = digest_path()
	if vim.fn.filereadable(path) == 1 then
		os.remove(path)
		vim.notify("[dwight] Digest cleared.", vim.log.levels.INFO)
	else
		vim.notify("[dwight] No digest to clear.", vim.log.levels.INFO)
	end
end

return M
