-- dwight/context.lua
-- Deep project context scanner.
-- Reads dependency manifests (go.mod, package.json, Cargo.toml, etc.) to provide
-- the LLM with project name, module path, dependencies, and dev tooling info.
-- Used by: prompt.lua (regular prompts), agent.lua (plan generation).

local M = {}

--------------------------------------------------------------------
-- Individual scanners
--------------------------------------------------------------------

--- Read a file fully. Returns content or nil.
local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

--- Scan go.mod
function M._scan_go(cwd)
	local content = read_file(cwd .. "/go.mod")
	if not content then
		return nil
	end

	local info = { type = "go" }
	info.module = content:match("module%s+(%S+)")
	info.go_version = content:match("go%s+(%S+)")

	-- Parse require block
	info.deps = {}
	local in_require = false
	for line in content:gmatch("[^\n]+") do
		if line:match("^require%s*%(") then
			in_require = true
		elseif in_require and line:match("^%)") then
			in_require = false
		elseif in_require then
			local dep, ver = line:match("^%s*(%S+)%s+(%S+)")
			if dep and not dep:match("^//") then
				info.deps[#info.deps + 1] = { name = dep, version = ver }
			end
		else
			-- Single-line require
			local dep, ver = line:match("^require%s+(%S+)%s+(%S+)")
			if dep then
				info.deps[#info.deps + 1] = { name = dep, version = ver }
			end
		end
	end

	return info
end

--- Scan package.json
function M._scan_node(cwd)
	local content = read_file(cwd .. "/package.json")
	if not content then
		return nil
	end

	local ok, pkg = pcall(vim.json.decode, content)
	if not ok or type(pkg) ~= "table" then
		return nil
	end

	local info = { type = "node" }
	info.name = pkg.name
	info.version = pkg.version
	info.description = pkg.description
	info.main = pkg.main
	info.scripts = {}
	info.deps = {}
	info.dev_deps = {}

	if type(pkg.scripts) == "table" then
		for k, v in pairs(pkg.scripts) do
			info.scripts[#info.scripts + 1] = { name = k, command = v }
		end
		table.sort(info.scripts, function(a, b)
			return a.name < b.name
		end)
	end

	if type(pkg.dependencies) == "table" then
		for k, v in pairs(pkg.dependencies) do
			info.deps[#info.deps + 1] = { name = k, version = v }
		end
		table.sort(info.deps, function(a, b)
			return a.name < b.name
		end)
	end

	if type(pkg.devDependencies) == "table" then
		for k, v in pairs(pkg.devDependencies) do
			info.dev_deps[#info.dev_deps + 1] = { name = k, version = v }
		end
		table.sort(info.dev_deps, function(a, b)
			return a.name < b.name
		end)
	end

	-- Detect package manager
	if vim.fn.filereadable(cwd .. "/pnpm-lock.yaml") == 1 then
		info.pkg_manager = "pnpm"
	elseif vim.fn.filereadable(cwd .. "/yarn.lock") == 1 then
		info.pkg_manager = "yarn"
	elseif vim.fn.filereadable(cwd .. "/bun.lockb") == 1 then
		info.pkg_manager = "bun"
	else
		info.pkg_manager = "npm"
	end

	return info
end

--- Scan Cargo.toml
function M._scan_rust(cwd)
	local content = read_file(cwd .. "/Cargo.toml")
	if not content then
		return nil
	end

	local info = { type = "rust" }
	info.name = content:match('%[package%].-name%s*=%s*"([^"]+)"')
	info.version = content:match('%[package%].-version%s*=%s*"([^"]+)"')
	info.edition = content:match('edition%s*=%s*"([^"]+)"')

	info.deps = {}
	local in_deps = false
	for line in content:gmatch("[^\n]+") do
		if line:match("^%[dependencies%]") then
			in_deps = true
		elseif line:match("^%[") then
			in_deps = false
		elseif in_deps then
			local dep, ver = line:match('^(%S+)%s*=%s*"([^"]+)"')
			if not dep then
				dep = line:match("^(%S+)%s*=")
			end
			if dep then
				info.deps[#info.deps + 1] = { name = dep, version = ver or "?" }
			end
		end
	end

	return info
end

--- Scan pyproject.toml / setup.py
function M._scan_python(cwd)
	local content = read_file(cwd .. "/pyproject.toml")
	if content then
		local info = { type = "python" }
		info.name = content:match('name%s*=%s*"([^"]+)"')
		info.version = content:match('version%s*=%s*"([^"]+)"')
		info.python_requires = content:match('requires%-python%s*=%s*"([^"]+)"')

		info.deps = {}
		local in_deps = false
		for line in content:gmatch("[^\n]+") do
			if line:match("^dependencies%s*=") or line:match("^%[project%.dependencies%]") then
				in_deps = true
			elseif in_deps and line:match("^%[") then
				in_deps = false
			elseif in_deps then
				local dep = line:match('^%s*"([^"]+)"')
				if dep then
					info.deps[#info.deps + 1] = { name = dep, version = "" }
				end
			end
		end

		-- Detect venv/tool
		if vim.fn.isdirectory(cwd .. "/.venv") == 1 then
			info.venv = ".venv"
		end
		if vim.fn.filereadable(cwd .. "/poetry.lock") == 1 then
			info.pkg_manager = "poetry"
		elseif vim.fn.filereadable(cwd .. "/uv.lock") == 1 then
			info.pkg_manager = "uv"
		else
			info.pkg_manager = "pip"
		end

		return info
	end

	-- Fallback: setup.py
	content = read_file(cwd .. "/setup.py")
	if content then
		local info = { type = "python" }
		info.name = content:match("name%s*=%s*[\"']([^\"']+)[\"']")
		info.pkg_manager = "pip"
		return info
	end

	return nil
end

--------------------------------------------------------------------
-- Unified scanner
--------------------------------------------------------------------

--- Scan the project and return structured context.
--- Returns { project_type, name, deps_xml, install_cmd, test_cmd, ... }
function M.scan()
	local cwd = vim.fn.getcwd()

	-- Try each scanner
	local info = M._scan_go(cwd) or M._scan_node(cwd) or M._scan_rust(cwd) or M._scan_python(cwd)

	if not info then
		return nil
	end
	return info
end

--- Build XML context string for prompt injection.
function M.build_xml()
	local info = M.scan()
	if not info then
		return nil
	end

	local parts = { "<project_manifest>" }

	if info.type == "go" then
		parts[#parts + 1] = string.format("  <language>Go</language>")
		if info.module then
			parts[#parts + 1] = string.format("  <module>%s</module>", info.module)
		end
		if info.go_version then
			parts[#parts + 1] = string.format("  <go_version>%s</go_version>", info.go_version)
		end
		parts[#parts + 1] = "  <install_cmd>go get {package}</install_cmd>"
		parts[#parts + 1] = "  <test_cmd>go test ./...</test_cmd>"
		if info.deps and #info.deps > 0 then
			parts[#parts + 1] = "  <dependencies>"
			for _, d in ipairs(info.deps) do
				parts[#parts + 1] = string.format("    <dep>%s@%s</dep>", d.name, d.version or "")
			end
			parts[#parts + 1] = "  </dependencies>"
		end
	end

	if info.type == "node" then
		parts[#parts + 1] = "  <language>JavaScript/TypeScript</language>"
		if info.name then
			parts[#parts + 1] = string.format("  <name>%s</name>", info.name)
		end
		if info.pkg_manager then
			parts[#parts + 1] = string.format("  <pkg_manager>%s</pkg_manager>", info.pkg_manager)
			local install = info.pkg_manager == "yarn" and "yarn add {package}"
				or info.pkg_manager == "pnpm" and "pnpm add {package}"
				or info.pkg_manager == "bun" and "bun add {package}"
				or "npm install {package}"
			parts[#parts + 1] = string.format("  <install_cmd>%s</install_cmd>", install)
		end
		if info.scripts then
			for _, s in ipairs(info.scripts) do
				if s.name == "test" then
					parts[#parts + 1] = string.format("  <test_cmd>%s run test</test_cmd>", info.pkg_manager or "npm")
				end
			end
			parts[#parts + 1] = "  <scripts>"
			for _, s in ipairs(info.scripts) do
				parts[#parts + 1] = string.format('    <script name="%s">%s</script>', s.name, s.command)
			end
			parts[#parts + 1] = "  </scripts>"
		end
		if info.deps and #info.deps > 0 then
			parts[#parts + 1] = "  <dependencies>"
			for _, d in ipairs(info.deps) do
				parts[#parts + 1] = string.format("    <dep>%s@%s</dep>", d.name, d.version or "")
			end
			parts[#parts + 1] = "  </dependencies>"
		end
		if info.dev_deps and #info.dev_deps > 0 then
			parts[#parts + 1] = "  <dev_dependencies>"
			for _, d in ipairs(info.dev_deps) do
				parts[#parts + 1] = string.format("    <dep>%s@%s</dep>", d.name, d.version or "")
			end
			parts[#parts + 1] = "  </dev_dependencies>"
		end
	end

	if info.type == "rust" then
		parts[#parts + 1] = "  <language>Rust</language>"
		if info.name then
			parts[#parts + 1] = string.format("  <name>%s</name>", info.name)
		end
		if info.edition then
			parts[#parts + 1] = string.format("  <edition>%s</edition>", info.edition)
		end
		parts[#parts + 1] = "  <install_cmd>cargo add {package}</install_cmd>"
		parts[#parts + 1] = "  <test_cmd>cargo test</test_cmd>"
		if info.deps and #info.deps > 0 then
			parts[#parts + 1] = "  <dependencies>"
			for _, d in ipairs(info.deps) do
				parts[#parts + 1] = string.format("    <dep>%s@%s</dep>", d.name, d.version or "")
			end
			parts[#parts + 1] = "  </dependencies>"
		end
	end

	if info.type == "python" then
		parts[#parts + 1] = "  <language>Python</language>"
		if info.name then
			parts[#parts + 1] = string.format("  <name>%s</name>", info.name)
		end
		if info.pkg_manager then
			parts[#parts + 1] = string.format("  <pkg_manager>%s</pkg_manager>", info.pkg_manager)
			local install = info.pkg_manager == "poetry" and "poetry add {package}"
				or info.pkg_manager == "uv" and "uv add {package}"
				or "pip install {package}"
			parts[#parts + 1] = string.format("  <install_cmd>%s</install_cmd>", install)
		end
		parts[#parts + 1] = "  <test_cmd>pytest</test_cmd>"
		if info.deps and #info.deps > 0 then
			parts[#parts + 1] = "  <dependencies>"
			for _, d in ipairs(info.deps) do
				parts[#parts + 1] = string.format("    <dep>%s</dep>", d.name)
			end
			parts[#parts + 1] = "  </dependencies>"
		end
	end

	parts[#parts + 1] = "</project_manifest>"
	return table.concat(parts, "\n")
end

--- Get the install command template for this project.
function M.install_cmd()
	local info = M.scan()
	if not info then
		return nil
	end
	if info.type == "go" then
		return "go get {package}"
	end
	if info.type == "rust" then
		return "cargo add {package}"
	end
	if info.type == "python" then
		if info.pkg_manager == "poetry" then
			return "poetry add {package}"
		end
		if info.pkg_manager == "uv" then
			return "uv add {package}"
		end
		return "pip install {package}"
	end
	if info.type == "node" then
		if info.pkg_manager == "yarn" then
			return "yarn add {package}"
		end
		if info.pkg_manager == "pnpm" then
			return "pnpm add {package}"
		end
		if info.pkg_manager == "bun" then
			return "bun add {package}"
		end
		return "npm install {package}"
	end
	return nil
end

--- Get the test command for this project.
function M.test_cmd()
	local info = M.scan()
	if not info then
		return nil
	end
	if info.type == "go" then
		return "go test ./..."
	end
	if info.type == "rust" then
		return "cargo test"
	end
	if info.type == "python" then
		return "pytest"
	end
	if info.type == "node" then
		return (info.pkg_manager or "npm") .. " test"
	end
	return nil
end

return M
