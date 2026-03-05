-- dwight/languages.lua
-- Unified language registry: detection, commands, syntax checks, agent hints.
-- Built-in support for 20 languages + user extension via setup().
--
-- Usage in other modules:
--   local lang = require("dwight.languages")
--   local detected = lang.detect()           -- "go", "python", etc.
--   local test = lang.test_cmd()             -- "go test ./... -count=1"
--   local ok, err = lang.syntax_check(code, ft, path)

local M = {}

--------------------------------------------------------------------
-- Registry: built-in language definitions
--------------------------------------------------------------------

-- Each entry is keyed by language id (lowercase).
-- Fields:
--   name          string   — Display name
--   detect        string[] — Marker files (first match wins)
--   comment       string   — Comment prefix for pragmas
--   test_cmd      string?  — Test runner command
--   build_cmd     string?  — Build/compile check command
--   lint          table[]? — { bin, cmd } candidates, first available wins
--   vet_cmd       string?  — Static analysis command
--   coverage      table?   — { cmd, parse_total(output?) -> number? }
--   syntax_check  function? — (code, filepath) -> ok, err_msg
--   hint          string?  — Best practices injected into agent prompts
--   smoke         function? — (cwd) -> { build, run, cleanup? } or nil

local BUILTIN = {}

--------------------------------------------------------------------
-- Go
--------------------------------------------------------------------
BUILTIN.go = {
	name = "Go",
	detect = { "go.mod" },
	comment = "//",
	test_cmd = "go test ./... -count=1",
	build_cmd = "go build ./...",
	lint = {
		{ bin = "golangci-lint", cmd = "golangci-lint run ./..." },
		{ bin = "go", cmd = "go vet ./..." },
	},
	vet_cmd = "go vet ./...",
	coverage = {
		cmd = "go test ./... -count=1 -coverprofile=/tmp/dwight_cover.out",
		parse_total = function()
			local out = vim.fn.system("go tool cover -func=/tmp/dwight_cover.out 2>/dev/null")
			if not out then
				return nil
			end
			local pct = out:match("total:%s+%(statements%)%s+(%d+%.?%d*)%%")
			return pct and tonumber(pct) or nil
		end,
	},
	syntax_check = function(code, filepath)
		local tmp = vim.fn.tempname() .. ".go"
		local f = io.open(tmp, "w")
		if not f then
			return true, nil
		end
		f:write(code .. "\n")
		f:close()
		local output = vim.fn.system("gofmt -e " .. vim.fn.shellescape(tmp) .. " 2>&1")
		os.remove(tmp)
		if vim.v.shell_error ~= 0 then
			output = (output or ""):gsub(vim.pesc(tmp), filepath or "file.go")
			return false, "Go syntax check failed:\n" .. output:sub(1, 500)
		end
		return true, nil
	end,
	hint = [=[
## Language: Go
- Compile check: `go build ./...`
- Test specific package: `go test ./package/... -v -count=1`
- Test all: `go test ./... -count=1`
- Templates: use `//go:embed templates/*.html` with `embed.FS` and `template.ParseFS`.
  NEVER use `template.Must(template.ParseGlob(...))` — it panics during tests because
  the working directory is the package dir, not the project root.
- Route registration: wire handlers in the same constructor where the mux is created.
- Mocks: read the interface file FIRST. Implement ALL methods including pointer receivers.
- Test working directory is the package dir, not project root — use embed for test assets.
- Read existing test files to match the project's testing patterns (table-driven, httptest, etc.)
- Interfaces: always check if a type satisfies an interface with a compile check before running tests.
- Error handling: always handle errors explicitly. Use `if err != nil { return ... }` patterns.
]=],
	smoke = function(cwd)
		local main_check =
			vim.fn.system("grep -rq 'func main()' " .. cwd .. "/*.go " .. cwd .. "/cmd/ 2>/dev/null; echo $?")
		if vim.trim(main_check) ~= "0" then
			return nil
		end
		local cmd_dirs = vim.fn.glob(cwd .. "/cmd/*/main.go", false, true)
		if #cmd_dirs > 0 then
			local cmd_name = cmd_dirs[1]:match("/cmd/([^/]+)/")
			return {
				build = "go build -o /tmp/dwight_smoke ./cmd/" .. (cmd_name or "..."),
				run = "/tmp/dwight_smoke --help 2>&1 || /tmp/dwight_smoke -h 2>&1; true",
				cleanup = "rm -f /tmp/dwight_smoke",
			}
		end
		return {
			build = "go build -o /tmp/dwight_smoke .",
			run = "/tmp/dwight_smoke --help 2>&1 || /tmp/dwight_smoke -h 2>&1; true",
			cleanup = "rm -f /tmp/dwight_smoke",
		}
	end,
}

--------------------------------------------------------------------
-- JavaScript / TypeScript (Node)
--------------------------------------------------------------------
BUILTIN.node = {
	name = "JavaScript/TypeScript",
	detect = { "package.json" },
	comment = "//",
	test_cmd = "npm test",
	build_cmd = "npx tsc --noEmit",
	lint = {
		{ bin = "npx", cmd = "npx eslint . --max-warnings 0 --no-error-on-unmatched-pattern" },
	},
	vet_cmd = "npx tsc --noEmit",
	coverage = {
		cmd = "npx jest --coverage --coverageReporters=text-summary 2>&1 || npx vitest run --coverage 2>&1",
		parse_total = function(output)
			local pct = (output or ""):match("Statements%s*:%s*(%d+%.?%d*)%%")
			return pct and tonumber(pct) or nil
		end,
	},
	-- syntax_check: nil — tsc --noEmit is too slow for pre-apply
	hint = [=[
## Language: JavaScript/TypeScript
- Compile check (TS): `npx tsc --noEmit`
- Test: `npm test` or `npx jest` or `npx vitest run`
- When adding dependencies, run `npm install <pkg>` (or yarn/pnpm based on lockfile).
- TypeScript: ensure strict mode compatibility. Avoid `any`.
- Imports: match the project's import style (ESM vs CommonJS).
- Testing: check if the project uses Jest, Vitest, or Mocha. Match existing test patterns.
- When editing package.json, ALWAYS read it first — never overwrite the full file.
]=],
	smoke = function(cwd)
		local pkg = vim.fn.system("cat " .. cwd .. "/package.json 2>/dev/null")
		if pkg and pkg:match('"start"') then
			return {
				build = "npm run build 2>/dev/null || npx tsc --noEmit",
				run = "timeout 5 npm start 2>&1; true",
			}
		end
		return nil
	end,
}

--------------------------------------------------------------------
-- Rust
--------------------------------------------------------------------
BUILTIN.rust = {
	name = "Rust",
	detect = { "Cargo.toml" },
	comment = "//",
	test_cmd = "cargo test",
	build_cmd = "cargo check",
	lint = {
		{ bin = "cargo", cmd = "cargo clippy -- -D warnings" },
	},
	vet_cmd = "cargo check",
	coverage = (function()
		if vim.fn.exepath("cargo-tarpaulin") ~= "" then
			return {
				cmd = "cargo tarpaulin --skip-clean -q",
				parse_total = function(output)
					local pct = (output or ""):match("(%d+%.?%d*)%%%s+coverage")
					return pct and tonumber(pct) or nil
				end,
			}
		end
		return nil
	end)(),
	hint = [=[
## Language: Rust
- Compile check: `cargo check`
- Test: `cargo test`
- Lint: `cargo clippy`
- Always handle Results and Options explicitly. Never use `.unwrap()` in library code.
- Read Cargo.toml for existing dependencies before adding new ones.
- Trait implementations: read the trait definition before implementing. Implement ALL required methods.
]=],
	smoke = function()
		return {
			build = "cargo build",
			run = "cargo run -- --help 2>&1; true",
		}
	end,
}

--------------------------------------------------------------------
-- Python
--------------------------------------------------------------------
BUILTIN.python = {
	name = "Python",
	detect = { "pyproject.toml", "setup.py", "requirements.txt", "Pipfile" },
	comment = "#",
	test_cmd = "python -m pytest",
	build_cmd = "python -m py_compile",
	lint = {
		{ bin = "ruff", cmd = "ruff check ." },
		{ bin = "flake8", cmd = "flake8 ." },
		{ bin = "pylint", cmd = "pylint --errors-only ." },
	},
	coverage = {
		cmd = "python -m pytest --cov=. --cov-report=term-missing -q",
		parse_total = function(output)
			local pct = (output or ""):match("TOTAL%s+%d+%s+%d+%s+(%d+)%%")
			return pct and tonumber(pct) or nil
		end,
	},
	syntax_check = function(code, _filepath)
		local tmp = vim.fn.tempname() .. ".py"
		local f = io.open(tmp, "w")
		if not f then
			return true, nil
		end
		f:write(code .. "\n")
		f:close()
		local output = vim.fn.system("python3 -m py_compile " .. vim.fn.shellescape(tmp) .. " 2>&1")
		os.remove(tmp)
		if vim.v.shell_error ~= 0 then
			return false, "Python syntax check failed:\n" .. (output or ""):sub(1, 500)
		end
		return true, nil
	end,
	hint = [=[
## Language: Python
- Test: `python -m pytest` or `pytest`
- Type check: `mypy .` or `pyright`
- Lint: `ruff check .` or `flake8`
- Use type hints for function parameters and return values.
- Check for .venv/, venv/, or conda. Use the project's existing package manager.
- Testing: match existing test patterns (fixtures, parametrize, conftest.py).
]=],
	smoke = function(cwd)
		if vim.fn.filereadable(cwd .. "/manage.py") == 1 then
			return { build = "python manage.py check", run = "python manage.py check --deploy 2>&1; true" }
		elseif vim.fn.filereadable(cwd .. "/__main__.py") == 1 then
			return {
				build = "python -m py_compile __main__.py",
				run = "timeout 5 python -m " .. vim.fn.fnamemodify(cwd, ":t") .. " --help 2>&1; true",
			}
		end
		return nil
	end,
}

--------------------------------------------------------------------
-- Java
--------------------------------------------------------------------
BUILTIN.java = {
	name = "Java",
	detect = { "pom.xml", "build.gradle" },
	comment = "//",
	test_cmd = "mvn test -q 2>/dev/null || gradle test 2>/dev/null",
	build_cmd = "mvn compile -q 2>/dev/null || gradle build 2>/dev/null",
	lint = {
		{ bin = "mvn", cmd = "mvn checkstyle:check -q" },
		{ bin = "gradle", cmd = "gradle checkstyleMain" },
	},
	vet_cmd = "mvn compile -q 2>/dev/null || gradle compileJava 2>/dev/null",
	coverage = {
		cmd = "mvn test -Djacoco.skip=false -q 2>/dev/null || gradle test jacocoTestReport 2>/dev/null",
		parse_total = function(output)
			return (output or ""):match("Total.*?(%d+)%%") and tonumber((output or ""):match("(%d+)%%")) or nil
		end,
	},
	hint = [=[
## Language: Java
- Build: `mvn compile` or `gradle build`
- Test: `mvn test` or `gradle test`
- Read pom.xml or build.gradle for dependencies before adding new ones.
- Follow existing project conventions for package structure and naming.
- When using Maven, prefer `mvn -q` for cleaner output.
]=],
}

--------------------------------------------------------------------
-- Kotlin
--------------------------------------------------------------------
BUILTIN.kotlin = {
	name = "Kotlin",
	detect = { "build.gradle.kts", "settings.gradle.kts" },
	priority = 40, -- checked before Java (build.gradle.kts is more specific than build.gradle)
	comment = "//",
	test_cmd = "gradle test",
	build_cmd = "gradle build",
	lint = {
		{ bin = "ktlint", cmd = "ktlint" },
		{ bin = "gradle", cmd = "gradle detekt" },
	},
	hint = [=[
## Language: Kotlin
- Build: `gradle build`
- Test: `gradle test`
- Follow Kotlin conventions: data classes, sealed classes, coroutines.
- Use null safety — avoid `!!` operator.
]=],
}

--------------------------------------------------------------------
-- C# / .NET
--------------------------------------------------------------------
BUILTIN.csharp = {
	name = "C#",
	detect = { "*.sln", "*.csproj", "Directory.Build.props" },
	comment = "//",
	test_cmd = "dotnet test",
	build_cmd = "dotnet build",
	lint = {
		{ bin = "dotnet", cmd = "dotnet format --verify-no-changes" },
	},
	vet_cmd = "dotnet build --warnaserror",
	hint = [=[
## Language: C# / .NET
- Build: `dotnet build`
- Test: `dotnet test`
- Lint: `dotnet format`
- Follow C# naming conventions (PascalCase for public, camelCase for private).
- Use async/await for I/O operations.
- Check .csproj for existing NuGet packages.
]=],
}

--------------------------------------------------------------------
-- C
--------------------------------------------------------------------
BUILTIN.c = {
	name = "C",
	detect = { "CMakeLists.txt", "Makefile", "configure.ac", "meson.build" },
	priority = 80, -- generic markers; checked after C++ and other languages
	comment = "//",
	test_cmd = "make test 2>/dev/null || ctest 2>/dev/null",
	build_cmd = "make 2>/dev/null || cmake --build build 2>/dev/null",
	lint = {
		{ bin = "cppcheck", cmd = "cppcheck --enable=warning,error --quiet ." },
		{ bin = "clang-tidy", cmd = "clang-tidy *.c -- 2>/dev/null" },
	},
	hint = [=[
## Language: C
- Build: `make` or `cmake --build build`
- Test: `make test` or `ctest`
- Always check return values and handle errors.
- Free allocated memory. Use Valgrind/ASan for memory debugging.
- Read existing Makefile/CMakeLists.txt before modifying build system.
]=],
}

--------------------------------------------------------------------
-- C++
--------------------------------------------------------------------
BUILTIN.cpp = {
	name = "C++",
	detect = { "*.cpp", "*.cc", "*.cxx", "*.hpp", "src/*.cpp", "src/*.cc" }, -- source files distinguish from C
	priority = 75, -- checked before C (which shares CMakeLists.txt/Makefile)
	comment = "//",
	test_cmd = "make test 2>/dev/null || ctest 2>/dev/null",
	build_cmd = "make 2>/dev/null || cmake --build build 2>/dev/null",
	lint = {
		{ bin = "clang-tidy", cmd = "clang-tidy src/*.cpp -- -std=c++17 2>/dev/null" },
		{ bin = "cppcheck", cmd = "cppcheck --enable=warning,error --quiet --language=c++ ." },
	},
	hint = [=[
## Language: C++
- Build: `make` or `cmake --build build`
- Test: `make test` or `ctest`
- Use RAII, smart pointers, and const references.
- Match the project's C++ standard (check CMakeLists.txt for CMAKE_CXX_STANDARD).
- Prefer range-based for loops and standard algorithms.
]=],
}

--------------------------------------------------------------------
-- Ruby
--------------------------------------------------------------------
BUILTIN.ruby = {
	name = "Ruby",
	detect = { "Gemfile", "Rakefile", "*.gemspec" },
	comment = "#",
	test_cmd = "bundle exec rspec 2>/dev/null || bundle exec rake test 2>/dev/null",
	build_cmd = "ruby -c . 2>/dev/null || bundle exec rake build 2>/dev/null",
	lint = {
		{ bin = "rubocop", cmd = "bundle exec rubocop" },
		{ bin = "standardrb", cmd = "bundle exec standardrb" },
	},
	coverage = {
		cmd = "COVERAGE=true bundle exec rspec 2>&1",
		parse_total = function(output)
			local pct = (output or ""):match("(%d+%.?%d*)%% covered")
			return pct and tonumber(pct) or nil
		end,
	},
	hint = [=[
## Language: Ruby
- Test: `bundle exec rspec` or `bundle exec rake test`
- Lint: `rubocop` or `standardrb`
- Read Gemfile for existing dependencies.
- Follow Ruby naming conventions (snake_case methods, CamelCase classes).
- For Rails: use `bin/rails test` and `bin/rails console` for verification.
]=],
}

--------------------------------------------------------------------
-- PHP
--------------------------------------------------------------------
BUILTIN.php = {
	name = "PHP",
	detect = { "composer.json", "artisan" },
	comment = "//",
	test_cmd = "vendor/bin/phpunit 2>/dev/null || php artisan test 2>/dev/null",
	build_cmd = "php -l . 2>/dev/null",
	lint = {
		{ bin = "vendor/bin/phpstan", cmd = "vendor/bin/phpstan analyse" },
		{ bin = "vendor/bin/phpcs", cmd = "vendor/bin/phpcs" },
		{ bin = "php", cmd = "php -l ." },
	},
	syntax_check = function(code, _filepath)
		local tmp = vim.fn.tempname() .. ".php"
		local f = io.open(tmp, "w")
		if not f then
			return true, nil
		end
		f:write(code .. "\n")
		f:close()
		local output = vim.fn.system("php -l " .. vim.fn.shellescape(tmp) .. " 2>&1")
		os.remove(tmp)
		if vim.v.shell_error ~= 0 then
			return false, "PHP syntax check failed:\n" .. (output or ""):sub(1, 500)
		end
		return true, nil
	end,
	hint = [=[
## Language: PHP
- Test: `vendor/bin/phpunit` or `php artisan test`
- Lint: `phpstan analyse` or `phpcs`
- Read composer.json for dependencies. Use `composer require` to add.
- For Laravel: use `php artisan` commands, check routes with `php artisan route:list`.
]=],
}

--------------------------------------------------------------------
-- Swift
--------------------------------------------------------------------
BUILTIN.swift = {
	name = "Swift",
	detect = { "Package.swift", "*.xcodeproj", "*.xcworkspace" },
	comment = "//",
	test_cmd = "swift test 2>/dev/null || xcodebuild test 2>/dev/null",
	build_cmd = "swift build 2>/dev/null || xcodebuild build 2>/dev/null",
	lint = {
		{ bin = "swiftlint", cmd = "swiftlint" },
	},
	hint = [=[
## Language: Swift
- Build: `swift build` (SPM) or `xcodebuild build`
- Test: `swift test` or `xcodebuild test`
- Use optionals and guard statements. Avoid force-unwrapping.
- Follow Swift API design guidelines.
]=],
}

--------------------------------------------------------------------
-- Dart / Flutter
--------------------------------------------------------------------
BUILTIN.dart = {
	name = "Dart/Flutter",
	detect = { "pubspec.yaml" },
	comment = "//",
	test_cmd = "flutter test 2>/dev/null || dart test 2>/dev/null",
	build_cmd = "flutter analyze 2>/dev/null || dart analyze 2>/dev/null",
	lint = {
		{ bin = "dart", cmd = "dart analyze" },
		{ bin = "flutter", cmd = "flutter analyze" },
	},
	hint = [=[
## Language: Dart/Flutter
- Test: `flutter test` or `dart test`
- Analyze: `flutter analyze` or `dart analyze`
- Read pubspec.yaml for dependencies. Use `flutter pub add` or `dart pub add`.
- Follow Dart effective style guide. Use `final` where possible.
]=],
}

--------------------------------------------------------------------
-- Elixir
--------------------------------------------------------------------
BUILTIN.elixir = {
	name = "Elixir",
	detect = { "mix.exs" },
	comment = "#",
	test_cmd = "mix test",
	build_cmd = "mix compile --warnings-as-errors",
	lint = {
		{ bin = "mix", cmd = "mix credo" },
	},
	vet_cmd = "mix dialyzer 2>/dev/null",
	coverage = {
		cmd = "mix test --cover",
		parse_total = function(output)
			local pct = (output or ""):match("(%d+%.?%d*)%%")
			return pct and tonumber(pct) or nil
		end,
	},
	hint = [=[
## Language: Elixir
- Build: `mix compile`
- Test: `mix test`
- Lint: `mix credo`
- Type check: `mix dialyzer` (if configured)
- Use pattern matching and the pipe operator. Follow community conventions.
- Read mix.exs for existing dependencies.
]=],
}

--------------------------------------------------------------------
-- Scala
--------------------------------------------------------------------
BUILTIN.scala = {
	name = "Scala",
	detect = { "build.sbt", "build.sc" },
	comment = "//",
	test_cmd = "sbt test 2>/dev/null || mill _.test 2>/dev/null",
	build_cmd = "sbt compile 2>/dev/null || mill _.compile 2>/dev/null",
	lint = {
		{ bin = "sbt", cmd = "sbt scalafmtCheck" },
	},
	hint = [=[
## Language: Scala
- Build: `sbt compile` or `mill _.compile`
- Test: `sbt test` or `mill _.test`
- Use immutable vals and case classes. Prefer pattern matching.
- Check build.sbt for existing libraryDependencies.
]=],
}

--------------------------------------------------------------------
-- Lua
--------------------------------------------------------------------
BUILTIN.lua = {
	name = "Lua",
	detect = {}, -- detected by filetype, not project marker
	comment = "--",
	test_cmd = "busted 2>/dev/null || lua test.lua 2>/dev/null",
	lint = {
		{ bin = "luacheck", cmd = "luacheck ." },
	},
	syntax_check = function(code, _filepath)
		local tmp = vim.fn.tempname() .. ".lua"
		local f = io.open(tmp, "w")
		if not f then
			return true, nil
		end
		f:write(code .. "\n")
		f:close()
		local output = vim.fn.system("luac -p " .. vim.fn.shellescape(tmp) .. " 2>&1")
		os.remove(tmp)
		if vim.v.shell_error ~= 0 then
			return false, "Lua syntax check failed:\n" .. (output or ""):sub(1, 500)
		end
		return true, nil
	end,
}

--------------------------------------------------------------------
-- Haskell
--------------------------------------------------------------------
BUILTIN.haskell = {
	name = "Haskell",
	detect = { "stack.yaml", "cabal.project", "*.cabal" },
	comment = "--",
	test_cmd = "stack test 2>/dev/null || cabal test 2>/dev/null",
	build_cmd = "stack build 2>/dev/null || cabal build 2>/dev/null",
	lint = {
		{ bin = "hlint", cmd = "hlint ." },
	},
	hint = [=[
## Language: Haskell
- Build: `stack build` or `cabal build`
- Test: `stack test` or `cabal test`
- Lint: `hlint`
- Use strong typing. Check existing imports before adding modules.
]=],
}

--------------------------------------------------------------------
-- Zig
--------------------------------------------------------------------
BUILTIN.zig = {
	name = "Zig",
	detect = { "build.zig", "build.zig.zon" },
	comment = "//",
	test_cmd = "zig build test",
	build_cmd = "zig build",
	hint = [=[
## Language: Zig
- Build: `zig build`
- Test: `zig build test`
- Comptime: use compile-time evaluation where possible.
- Error handling: use error unions. Never ignore errors.
]=],
}

--------------------------------------------------------------------
-- OCaml
--------------------------------------------------------------------
BUILTIN.ocaml = {
	name = "OCaml",
	detect = { "dune-project", "*.opam" },
	comment = "(*", -- (* ... *) but pragma just needs start
	test_cmd = "dune test 2>/dev/null || opam exec -- dune test 2>/dev/null",
	build_cmd = "dune build",
	lint = {
		{ bin = "ocamlformat", cmd = "dune fmt -- --check 2>/dev/null" },
	},
	hint = [=[
## Language: OCaml
- Build: `dune build`
- Test: `dune test`
- Use pattern matching and algebraic data types.
- Check dune-project and *.opam for dependencies.
]=],
}

--------------------------------------------------------------------
-- Clojure
--------------------------------------------------------------------
BUILTIN.clojure = {
	name = "Clojure",
	detect = { "project.clj", "deps.edn" },
	comment = ";;",
	test_cmd = "lein test 2>/dev/null || clojure -M:test 2>/dev/null",
	build_cmd = "lein compile 2>/dev/null || clojure -M -e '(compile (quote core))' 2>/dev/null",
	lint = {
		{ bin = "clj-kondo", cmd = "clj-kondo --lint src" },
	},
	hint = [=[
## Language: Clojure
- Test: `lein test` or `clojure -M:test`
- Lint: `clj-kondo --lint src`
- Use immutable data structures and pure functions.
- Check project.clj or deps.edn for dependencies.
]=],
}

--------------------------------------------------------------------
-- R
--------------------------------------------------------------------
BUILTIN.r = {
	name = "R",
	detect = { "DESCRIPTION", "*.Rproj" },
	comment = "#",
	test_cmd = "Rscript -e 'devtools::test()'",
	build_cmd = "Rscript -e 'devtools::check()'",
	lint = {
		{ bin = "Rscript", cmd = "Rscript -e 'lintr::lint_package()'" },
	},
}

--------------------------------------------------------------------
-- Shell / Bash
--------------------------------------------------------------------
BUILTIN.shell = {
	name = "Shell",
	detect = {}, -- detected by filetype
	comment = "#",
	lint = {
		{ bin = "shellcheck", cmd = "shellcheck *.sh" },
	},
	syntax_check = function(code, _filepath)
		local tmp = vim.fn.tempname() .. ".sh"
		local f = io.open(tmp, "w")
		if not f then
			return true, nil
		end
		f:write(code .. "\n")
		f:close()
		local output = vim.fn.system("bash -n " .. vim.fn.shellescape(tmp) .. " 2>&1")
		os.remove(tmp)
		if vim.v.shell_error ~= 0 then
			return false, "Shell syntax check failed:\n" .. (output or ""):sub(1, 500)
		end
		return true, nil
	end,
}

--------------------------------------------------------------------
-- Fallback
--------------------------------------------------------------------
BUILTIN.unknown = {
	name = "Unknown",
	detect = {},
	comment = "//",
	hint = [=[
## Language Detection
Could not detect the project language. Before starting:
1. Explore the project structure with list_directory
2. Look for build files (Makefile, CMakeLists.txt, build.gradle, etc.)
3. Read source files to understand the language and conventions
]=],
}

--------------------------------------------------------------------
-- Registry state (built-in + user overrides)
--------------------------------------------------------------------

local _registry = nil -- lazy-initialized

--- Build the full registry by merging built-ins with user config.
local function get_registry()
	if _registry then
		return _registry
	end

	_registry = {}
	-- Copy built-ins
	for id, def in pairs(BUILTIN) do
		_registry[id] = vim.deepcopy(def)
	end

	-- Merge user languages from config
	pcall(function()
		local cfg = require("dwight").config
		if cfg.languages then
			for id, user_def in pairs(cfg.languages) do
				if _registry[id] then
					-- Merge into existing: user fields override built-in
					for k, v in pairs(user_def) do
						_registry[id][k] = v
					end
				else
					-- New language
					_registry[id] = user_def
					if not _registry[id].name then
						_registry[id].name = id
					end
					if not _registry[id].comment then
						_registry[id].comment = "//"
					end
				end
			end
		end
	end)

	return _registry
end

--- Reset registry (call when config changes).
function M.reset()
	_registry = nil
end

--- Get a language definition by id.
function M.get(lang_id)
	return get_registry()[lang_id or "unknown"] or get_registry().unknown
end

--- Get all registered language ids.
function M.ids()
	local ids = {}
	for id in pairs(get_registry()) do
		if id ~= "unknown" then
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	return ids
end

--------------------------------------------------------------------
-- Detection: which language is this project?
--------------------------------------------------------------------

--- Detect project language from marker files in cwd.
--- Returns language id string ("go", "python", etc.) or "unknown".
function M.detect()
	-- First try context.lua if available (it may have cached a scan)
	local ok, ctx = pcall(function()
		return require("dwight.context").scan()
	end)
	if ok and ctx and ctx.type then
		return ctx.type
	end

	-- Scan marker files
	local cwd = vim.fn.getcwd()
	local reg = get_registry()

	-- Build detection candidates, sorted by priority (lower = checked first).
	-- Default priority 50. Languages with unique markers get lower numbers.
	-- Shared markers (CMakeLists.txt) get higher numbers to avoid shadowing.
	local candidates = {}
	for id, def in pairs(reg) do
		if def.detect and #def.detect > 0 then
			candidates[#candidates + 1] = {
				id = id,
				detect = def.detect,
				priority = def.priority or 50,
			}
		end
	end
	table.sort(candidates, function(a, b)
		if a.priority ~= b.priority then
			return a.priority < b.priority
		end
		return a.id < b.id -- deterministic tiebreak
	end)

	for _, c in ipairs(candidates) do
		for _, marker in ipairs(c.detect) do
			if marker:find("%*") then
				-- Glob pattern (e.g. "*.sln", "src/*.cpp") — use glob
				local matches = vim.fn.glob(cwd .. "/" .. marker, false, true)
				if #matches > 0 then
					return c.id
				end
			else
				if vim.fn.filereadable(cwd .. "/" .. marker) == 1 then
					return c.id
				end
			end
		end
	end

	return "unknown"
end

--------------------------------------------------------------------
-- Command helpers (used by agentic.lua)
--------------------------------------------------------------------

function M.test_cmd(lang)
	local def = M.get(lang or M.detect())
	return def.test_cmd
end

function M.build_cmd(lang)
	local def = M.get(lang or M.detect())
	return def.build_cmd
end

--- Returns (command, binary) or (nil, nil).
function M.lint_cmd(lang)
	local def = M.get(lang or M.detect())
	if not def.lint then
		return nil, nil
	end

	for _, c in ipairs(def.lint) do
		if vim.fn.exepath(c.bin) ~= "" then
			return c.cmd, c.bin
		end
	end
	return nil, nil
end

function M.vet_cmd(lang)
	local def = M.get(lang or M.detect())
	return def.vet_cmd
end

--- Returns { cmd, parse_total } or nil.
function M.coverage_cmd(lang)
	local def = M.get(lang or M.detect())
	return def.coverage
end

--- Returns { build, run, cleanup? } or nil.
function M.smoke_cmd(lang)
	local def = M.get(lang or M.detect())
	if not def.smoke then
		return nil
	end
	local cwd = vim.fn.getcwd()
	return def.smoke(cwd)
end

--- Returns the agent prompt hint for the language.
function M.hint(lang)
	local def = M.get(lang or M.detect())
	return def.hint or get_registry().unknown.hint
end

--- Returns the comment prefix for pragmas.
function M.comment_prefix(lang)
	local def = M.get(lang or M.detect())
	return def.comment or "//"
end

--------------------------------------------------------------------
-- Syntax check (used by inline.lua)
--------------------------------------------------------------------

--- Run the language's pre-apply syntax check.
--- @param code string — full file content after replacement
--- @param filetype string — Neovim filetype
--- @param filepath string — file path (for error messages)
--- @return boolean ok, string? error_message
function M.syntax_check(code, filetype, filepath)
	if not code or code == "" then
		return true, nil
	end

	local ext = filepath and filepath:match("%.([^%.]+)$") or ""
	ext = ext:lower()

	-- Map filetype/extension to language id
	local lang_map = {
		go = "go",
		python = "python",
		py = "python",
		lua = "lua",
		php = "php",
		sh = "shell",
		bash = "shell",
		ruby = "ruby",
		rb = "ruby",
	}
	local lang_id = lang_map[filetype] or lang_map[ext]
	if not lang_id then
		return true, nil
	end

	local def = M.get(lang_id)
	if not def or not def.syntax_check then
		return true, nil
	end
	return def.syntax_check(code, filepath)
end

return M
