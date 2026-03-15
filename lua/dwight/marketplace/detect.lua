-- dwight/marketplace/detect.lua
-- Project type detection from manifest files.

local M = {}

--- Map of manifest files → project type signals.
M.DETECTORS = {
	-- Go
	{ file = "go.mod", type = "go", lang = "Go" },
	{ file = "go.sum", type = "go", lang = "Go" },
	-- Rust
	{ file = "Cargo.toml", type = "rust", lang = "Rust" },
	-- Python
	{ file = "pyproject.toml", type = "python", lang = "Python" },
	{ file = "setup.py", type = "python", lang = "Python" },
	{ file = "requirements.txt", type = "python", lang = "Python" },
	{ file = "Pipfile", type = "python", lang = "Python" },
	-- JavaScript/TypeScript
	{ file = "package.json", type = "node", lang = "JS/TS" },
	{ file = "tsconfig.json", type = "typescript", lang = "TypeScript" },
	{ file = "deno.json", type = "deno", lang = "TypeScript" },
	-- React
	{ dir = "src/components", type = "react", lang = "React" },
	-- Next.js
	{ file = "next.config.js", type = "nextjs", lang = "Next.js" },
	{ file = "next.config.mjs", type = "nextjs", lang = "Next.js" },
	{ file = "next.config.ts", type = "nextjs", lang = "Next.js" },
	-- Vue
	{ file = "vue.config.js", type = "vue", lang = "Vue" },
	{ file = "nuxt.config.ts", type = "nuxt", lang = "Nuxt" },
	-- Elixir
	{ file = "mix.exs", type = "elixir", lang = "Elixir" },
	-- Ruby
	{ file = "Gemfile", type = "ruby", lang = "Ruby" },
	{ file = "Rakefile", type = "ruby", lang = "Ruby" },
	-- Java/Kotlin
	{ file = "pom.xml", type = "java", lang = "Java" },
	{ file = "build.gradle", type = "java", lang = "Java/Kotlin" },
	{ file = "build.gradle.kts", type = "kotlin", lang = "Kotlin" },
	-- C/C++
	{ file = "CMakeLists.txt", type = "cpp", lang = "C/C++" },
	{ file = "Makefile", type = "c", lang = "C" },
	-- Zig
	{ file = "build.zig", type = "zig", lang = "Zig" },
	-- PHP
	{ file = "composer.json", type = "php", lang = "PHP" },
	-- Dart/Flutter
	{ file = "pubspec.yaml", type = "dart", lang = "Dart" },
	-- Nix
	{ file = "flake.nix", type = "nix", lang = "Nix" },
	-- Lua/Neovim
	{ dir = "lua", type = "neovim-plugin", lang = "Lua" },
	-- Docker
	{ file = "Dockerfile", type = "docker", lang = "Docker" },
	{ file = "docker-compose.yml", type = "docker", lang = "Docker" },
	{ file = "docker-compose.yaml", type = "docker", lang = "Docker" },
	-- Terraform
	{ dir = "terraform", type = "terraform", lang = "Terraform" },
	-- ML/Data
	{ dir = "notebooks", type = "ml", lang = "Python ML" },
}

--- Detect the project type(s) from the current directory.
--- Returns { primary_type, types = { "go", "docker", ... }, langs = { "Go", "Docker", ... } }
function M.detect_project_type()
	local root = vim.fn.getcwd()
	local types = {}
	local langs = {}
	local type_set = {}

	for _, d in ipairs(M.DETECTORS) do
		local found = false
		if d.file then
			found = vim.fn.filereadable(root .. "/" .. d.file) == 1
		elseif d.dir then
			found = vim.fn.isdirectory(root .. "/" .. d.dir) == 1
		end
		if found and not type_set[d.type] then
			type_set[d.type] = true
			types[#types + 1] = d.type
			langs[#langs + 1] = d.lang
		end
	end

	-- Refine: check package.json for frameworks
	if type_set["node"] then
		local f = io.open(root .. "/package.json", "r")
		if f then
			local content = f:read("*a")
			f:close()
			if content:match('"react"') and not type_set["react"] then
				types[#types + 1] = "react"
				langs[#langs + 1] = "React"
				type_set["react"] = true
			end
			if content:match('"vue"') and not type_set["vue"] then
				types[#types + 1] = "vue"
				langs[#langs + 1] = "Vue"
				type_set["vue"] = true
			end
			if content:match('"next"') and not type_set["nextjs"] then
				types[#types + 1] = "nextjs"
				langs[#langs + 1] = "Next.js"
				type_set["nextjs"] = true
			end
			if content:match('"express"') then
				types[#types + 1] = "express"
				langs[#langs + 1] = "Express"
				type_set["express"] = true
			end
			if content:match('"fastify"') then
				types[#types + 1] = "fastify"
				langs[#langs + 1] = "Fastify"
				type_set["fastify"] = true
			end
		end
	end

	-- Check pyproject.toml for ML frameworks
	if type_set["python"] then
		local f = io.open(root .. "/pyproject.toml", "r") or io.open(root .. "/requirements.txt", "r")
		if f then
			local content = f:read("*a")
			f:close()
			if
				content:match("torch")
				or content:match("tensorflow")
				or content:match("sklearn")
				or content:match("transformers")
				or content:match("jax")
			then
				if not type_set["ml"] then
					types[#types + 1] = "ml"
					langs[#langs + 1] = "Python ML"
					type_set["ml"] = true
				end
			end
			if content:match("fastapi") or content:match("flask") or content:match("django") then
				types[#types + 1] = "python-web"
				langs[#langs + 1] = "Python Web"
				type_set["python-web"] = true
			end
		end
	end

	return {
		primary = types[1] or "generic",
		types = types,
		langs = langs,
	}
end

return M
