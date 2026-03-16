-- tests/test_marketplace.lua
-- Tests for marketplace detect, packs schema, and matching logic.

vim.opt.rtp:prepend(vim.fn.getcwd())

local T = _T

local packs = require("dwight.marketplace.packs")
local detect = require("dwight.marketplace.detect")

io.write("── marketplace: pack schema ──\n")

T.test("every pack has required fields", function()
	for _, pack in ipairs(packs.PACKS) do
		T.ok(pack.name, "pack missing name")
		T.ok(pack.display, pack.name .. " missing display")
		T.ok(pack.description, pack.name .. " missing description")
		T.ok(pack.project_types, pack.name .. " missing project_types")
		T.ok(pack.skills, pack.name .. " missing skills")
		for _, skill in ipairs(pack.skills) do
			T.ok(skill.name, pack.name .. " has skill missing name")
			T.ok(skill.content, skill.name .. " missing content")
		end
		-- MCP servers with env must have an array
		if pack.mcp_servers then
			for _, srv in ipairs(pack.mcp_servers) do
				if srv.env then
					T.eq("table", type(srv.env), srv.name .. " env must be a table")
				end
			end
		end
	end
end)

T.test("pack count is 14", function()
	T.eq(14, #packs.PACKS, "expected 14 packs")
end)

T.test("skill count is 28", function()
	local count = 0
	for _, pack in ipairs(packs.PACKS) do
		count = count + #pack.skills
	end
	T.eq(28, count, "expected 28 total skills")
end)

T.test("no duplicate pack names", function()
	local seen = {}
	for _, pack in ipairs(packs.PACKS) do
		T.is_nil(seen[pack.name], "duplicate pack name: " .. pack.name)
		seen[pack.name] = true
	end
end)

T.test("no duplicate skill names", function()
	local seen = {}
	for _, pack in ipairs(packs.PACKS) do
		for _, skill in ipairs(pack.skills) do
			T.is_nil(seen[skill.name], "duplicate skill name: " .. skill.name)
			seen[skill.name] = true
		end
	end
end)

io.write("── marketplace: detectors ──\n")

T.test("every detector has type, lang, and file or dir", function()
	for i, d in ipairs(detect.DETECTORS) do
		T.ok(d.type, "detector #" .. i .. " missing type")
		T.ok(d.lang, "detector #" .. i .. " missing lang")
		T.ok(d.file or d.dir, "detector #" .. i .. " missing file and dir")
	end
end)

T.test("terraform file detector exists", function()
	local found = false
	for _, d in ipairs(detect.DETECTORS) do
		if d.file == "main.tf" and d.type == "terraform" then
			found = true
			break
		end
	end
	T.ok(found, "main.tf terraform detector not found")
end)

io.write("── marketplace: matching ──\n")

T.test("suggest_packs returns matching packs sorted by score", function()
	-- Mock detect_project_type to return known types
	local orig = detect.detect_project_type
	detect.detect_project_type = function()
		return { primary = "go", types = { "go", "docker" }, langs = { "Go", "Docker" } }
	end

	local matching = require("dwight.marketplace.matching")
	local matches, detected = matching.suggest_packs()

	-- Restore
	detect.detect_project_type = orig

	T.ok(#matches > 0, "should have matching packs")
	T.eq("go", detected.primary)

	-- go-api pack should match (project_types = { "go" })
	local found_go_api = false
	for _, m in ipairs(matches) do
		if m.pack.name == "go-api" then
			found_go_api = true
			T.ok(m.score >= 1, "go-api should have score >= 1")
		end
	end
	T.ok(found_go_api, "go-api pack should be in matches")

	-- Verify sorted descending by score
	for i = 2, #matches do
		T.ok(matches[i - 1].score >= matches[i].score, "matches should be sorted by score descending")
	end
end)
