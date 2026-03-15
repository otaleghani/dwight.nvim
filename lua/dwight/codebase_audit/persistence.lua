-- dwight/codebase_audit/persistence.lua
-- Save/load audit results to .dwight/audits/.

local M = {}

M.AUDIT_VERSION = 3

--- Save audit result to .dwight/audits/feature-name.json
function M._save_audit(feature_name, result)
	local project = require("dwight.project")
	if not project.is_initialized() then
		return
	end

	local dir = project.dir() .. "/audits"
	vim.fn.mkdir(dir, "p")

	-- Serialize findings (convert severity refs to strings)
	local serializable = {
		version = M.AUDIT_VERSION,
		timestamp = os.time(),
		stats = result.stats,
		agent_review = result.agent_review,
		findings = {},
	}
	for _, f in ipairs(result.findings) do
		serializable.findings[#serializable.findings + 1] = {
			severity = f.severity.label,
			category = f.category,
			file = f.file,
			line = f.line,
			message = f.message,
			snippet = f.snippet or "",
			fix = f.fix,
			agent_verified = f.agent_verified or false,
			llm_reviewed = f.llm_reviewed or false,
		}
	end

	local path = dir .. "/" .. feature_name .. ".json"
	local file = io.open(path, "w")
	if file then
		file:write(vim.json.encode(serializable))
		file:close()
	end
end

--- Load saved audit result.
--- Returns nil if not found, wrong version, or too old (>7 days).
function M._load_audit(feature_name)
	local constants = require("dwight.codebase_audit.constants")
	local SEV = constants.SEV

	local project = require("dwight.project")
	if not project.is_initialized() then
		return nil
	end

	local path = project.dir() .. "/audits/" .. feature_name .. ".json"
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local raw = file:read("*a")
	file:close()

	local ok, data = pcall(vim.json.decode, raw)
	if not ok then
		return nil
	end

	-- Version check: discard audits from old format
	if (data.version or 0) < M.AUDIT_VERSION then
		vim.notify(
			string.format(
				"[dwight] ⚠️ Cached audit for $%s is from an older version — re-run :DwightAudit",
				feature_name
			),
			vim.log.levels.WARN
		)
		return nil
	end

	-- Staleness check: warn if older than 7 days
	if data.timestamp and (os.time() - data.timestamp) > 7 * 86400 then
		vim.notify(
			string.format(
				"[dwight] ⚠️ Cached audit for $%s is %d days old — consider re-running :DwightAudit",
				feature_name,
				math.floor((os.time() - data.timestamp) / 86400)
			),
			vim.log.levels.WARN
		)
	end

	-- Reconstitute severity references
	local sev_map = { CRITICAL = SEV.CRITICAL, WARN = SEV.WARN, INFO = SEV.INFO }
	for _, f in ipairs(data.findings or {}) do
		f.severity = sev_map[f.severity] or SEV.WARN
	end

	-- Carry over agent_review if present
	data.agent_review = data.agent_review or nil

	return data
end

return M
