-- dwight/agent/lessons.lua
-- Session learning: extract, store, and manage lessons from past agent runs.

local M = {}

--------------------------------------------------------------------
-- Lesson extraction prompt
--------------------------------------------------------------------

local LESSON_PROMPT = [=[
Analyze this agent session and extract 1-3 SHORT lessons that would help future similar tasks.

Request: %s
Outcome: %s

Step journal:
%s

For EACH lesson, output ONE line in this exact format:
LESSON: <2-5 keywords> | <one sentence lesson>

Examples:
LESSON: database CRUD migration | Always call AutoMigrate for new models in the Open/Init function
LESSON: CLI interface mock | Mock structs must implement ALL interface methods with exact signatures
LESSON: Go test SQLite | SQLite creates files even for invalid paths; check parent directory exists

Output ONLY LESSON lines. No other text.
]=]

--- Extract lessons from a completed session.
--- Returns a list of { keywords = {...}, text = "..." }.
function M._extract_lessons(session, journal, callback)
	local outcome = session.had_error and "FAILED at step " .. (session.failed_step or "?") or "SUCCESS"

	local journal_text = journal and #journal > 0 and table.concat(journal, "\n") or "(no journal)"

	local prompt = string.format(LESSON_PROMPT, session.request, outcome, journal_text)

	require("dwight.skills")._run_llm(prompt, function(raw, code)
		if code ~= 0 or not raw then
			callback({})
			return
		end

		local lessons = {}
		for line in raw:gmatch("[^\n]+") do
			local kw_str, text = line:match("^LESSON:%s*(.-)%s*|%s*(.+)$")
			if kw_str and text then
				local keywords = {}
				for kw in kw_str:gmatch("%S+") do
					keywords[#keywords + 1] = kw:lower()
				end
				if #keywords > 0 then
					lessons[#lessons + 1] = {
						keywords = keywords,
						text = vim.trim(text),
						request = session.request,
						timestamp = session.timestamp or os.time(),
					}
				end
			end
		end

		callback(lessons)
	end)
end

--- Load lessons index from disk.
function M._load_lessons()
	local agent_dir = require("dwight.agent")._agent_dir
	local path = agent_dir() .. "/lessons.json"
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end

	local f = io.open(path, "r")
	if not f then
		return {}
	end
	local content = f:read("*a")
	f:close()

	local ok, data = pcall(vim.json.decode, content)
	if ok and type(data) == "table" then
		return data
	end
	return {}
end

--- Save lessons index to disk.
function M._save_lessons(lessons)
	pcall(function()
		local agent_dir = require("dwight.agent")._agent_dir
		local dir = agent_dir()
		vim.fn.mkdir(dir, "p")
		local path = dir .. "/lessons.json"
		local f = io.open(path, "w")
		if f then
			f:write(vim.json.encode(lessons))
			f:close()
		end
	end)
end

--- Find lessons relevant to a request.
--- Returns up to 5 lessons scored by keyword overlap, freshness, and reinforcement.
--- Increments use_count on returned lessons.
function M._find_relevant_lessons(request)
	local all_lessons = M._load_lessons()
	if #all_lessons == 0 then
		return {}
	end

	local now = os.time()

	-- Tokenize request
	local req_words = {}
	for word in request:lower():gmatch("%w+") do
		if #word > 2 then
			req_words[word] = true
		end
	end

	-- Score each lesson by keyword overlap + freshness + reinforcement
	local scored = {}
	for _, lesson in ipairs(all_lessons) do
		local keyword_score = 0
		local total_kw = #(lesson.keywords or {})
		for _, kw in ipairs(lesson.keywords or {}) do
			if req_words[kw] then
				keyword_score = keyword_score + 1
			end
		end
		if keyword_score > 0 then
			-- Normalize keyword match (0-1)
			local match_ratio = total_kw > 0 and keyword_score / total_kw or 0

			-- Freshness bonus: recent lessons score higher (decays over 30 days)
			local age_days = (now - (lesson.timestamp or 0)) / 86400
			local freshness = math.max(0.1, 1 - age_days / 60)

			-- Reinforcement bonus: lessons seen multiple times are stronger
			local reinforcement = math.min((lesson.reinforced or 1) / 3, 1.5)

			-- Combined score
			local final_score = keyword_score * 2 + match_ratio + freshness * 0.5 + reinforcement * 0.3

			scored[#scored + 1] = { lesson = lesson, score = final_score }
		end
	end

	-- Sort by score descending
	table.sort(scored, function(a, b)
		return a.score > b.score
	end)

	-- Return top 5 and track usage
	local results = {}
	local dirty = false
	for i = 1, math.min(5, #scored) do
		local lesson = scored[i].lesson
		lesson.use_count = (lesson.use_count or 0) + 1
		dirty = true
		results[#results + 1] = lesson
	end

	-- Persist updated use counts
	if dirty then
		pcall(function()
			M._save_lessons(all_lessons)
		end)
	end

	return results
end

--- Append new lessons to the index with similarity-based deduplication.
--- Similar lessons (high keyword overlap) are merged rather than duplicated.
function M._append_lessons(new_lessons)
	if #new_lessons == 0 then
		return
	end

	local all = M._load_lessons()

	--- Compute similarity between two lessons based on keyword overlap.
	--- Returns 0.0 to 1.0 (Jaccard index).
	local function similarity(a, b)
		local set_a, set_b = {}, {}
		for _, kw in ipairs(a.keywords or {}) do
			set_a[kw] = true
		end
		for _, kw in ipairs(b.keywords or {}) do
			set_b[kw] = true
		end
		local intersection, union = 0, 0
		for k in pairs(set_a) do
			union = union + 1
			if set_b[k] then
				intersection = intersection + 1
			end
		end
		for k in pairs(set_b) do
			if not set_a[k] then
				union = union + 1
			end
		end
		if union == 0 then
			return 0
		end
		return intersection / union
	end

	local added = 0
	for _, lesson in ipairs(new_lessons) do
		-- Find the most similar existing lesson
		local best_sim = 0
		local best_idx = nil
		for i, existing in ipairs(all) do
			local sim = similarity(lesson, existing)
			if sim > best_sim then
				best_sim = sim
				best_idx = i
			end
		end

		if best_sim >= 0.6 and best_idx then
			-- Merge: keep the newer text but combine keywords and boost reinforcement count
			local existing = all[best_idx]
			local merged_kw_set = {}
			for _, kw in ipairs(existing.keywords or {}) do
				merged_kw_set[kw] = true
			end
			for _, kw in ipairs(lesson.keywords or {}) do
				merged_kw_set[kw] = true
			end
			local merged_kw = {}
			for kw in pairs(merged_kw_set) do
				merged_kw[#merged_kw + 1] = kw
			end
			table.sort(merged_kw)

			existing.keywords = merged_kw
			existing.text = lesson.text -- newer text is likely better
			existing.timestamp = lesson.timestamp or os.time()
			existing.reinforced = (existing.reinforced or 1) + 1
		-- Don't count as "added" since it's a merge
		else
			-- Truly new lesson
			lesson.reinforced = 1
			lesson.use_count = 0
			all[#all + 1] = lesson
			added = added + 1
		end
	end

	-- Evict: keep max 80 lessons. Remove stale + low-use first.
	if #all > 80 then
		M._evict_lessons(all, 80)
	end

	if added > 0 or #new_lessons > 0 then
		M._save_lessons(all)
		if added > 0 then
			vim.notify(string.format("[dwight] Learned %d lesson(s) from this session.", added), vim.log.levels.INFO)
		end
		local merged = #new_lessons - added
		if merged > 0 then
			vim.notify(
				string.format("[dwight] Merged %d lesson(s) with existing knowledge.", merged),
				vim.log.levels.INFO
			)
		end
	end
end

--- Evict lessons down to max_count. Priority: stale + low-use + low-reinforcement go first.
function M._evict_lessons(lessons, max_count)
	local now = os.time()
	local thirty_days = 30 * 24 * 3600

	-- Score each lesson: higher = more valuable = keep
	for _, l in ipairs(lessons) do
		local age_days = (now - (l.timestamp or 0)) / 86400
		local freshness = math.max(0, 1 - age_days / 60) -- decays over 60 days
		local usage = math.min((l.use_count or 0) / 5, 1) -- caps at 5 uses
		local reinforcement = math.min((l.reinforced or 1) / 3, 1) -- caps at 3 reinforcements
		l._score = freshness * 0.3 + usage * 0.4 + reinforcement * 0.3
	end

	-- Sort by score ascending (worst first)
	table.sort(lessons, function(a, b)
		return a._score < b._score
	end)

	-- Remove excess from the front (lowest scored)
	while #lessons > max_count do
		table.remove(lessons, 1)
	end

	-- Clean up temp scores
	for _, l in ipairs(lessons) do
		l._score = nil
	end
end

--- Consolidate lessons: find groups of similar lessons and merge them via LLM.
--- This is the "lesson quality maintenance" operation -- call periodically or manually.
--- callback(stats) where stats = { before, after, merged_groups }
function M._consolidate_lessons(callback)
	local all = M._load_lessons()
	if #all < 5 then
		if callback then
			callback({ before = #all, after = #all, merged_groups = 0 })
		end
		return
	end

	--- Compute keyword Jaccard similarity.
	local function similarity(a, b)
		local set_a, set_b = {}, {}
		for _, kw in ipairs(a.keywords or {}) do
			set_a[kw] = true
		end
		for _, kw in ipairs(b.keywords or {}) do
			set_b[kw] = true
		end
		local intersection, union = 0, 0
		for k in pairs(set_a) do
			union = union + 1
			if set_b[k] then
				intersection = intersection + 1
			end
		end
		for k in pairs(set_b) do
			if not set_a[k] then
				union = union + 1
			end
		end
		if union == 0 then
			return 0
		end
		return intersection / union
	end

	-- Find clusters of similar lessons (greedy clustering)
	local used = {}
	local clusters = {}
	for i = 1, #all do
		if not used[i] then
			local cluster = { i }
			used[i] = true
			for j = i + 1, #all do
				if not used[j] and similarity(all[i], all[j]) >= 0.5 then
					cluster[#cluster + 1] = j
					used[j] = true
				end
			end
			if #cluster >= 2 then
				clusters[#clusters + 1] = cluster
			end
		end
	end

	if #clusters == 0 then
		if callback then
			callback({ before = #all, after = #all, merged_groups = 0 })
		end
		return
	end

	-- Build a prompt to merge each cluster
	local merge_parts = {}
	for ci, cluster in ipairs(clusters) do
		local group_parts = { string.format("Group %d:", ci) }
		for _, idx in ipairs(cluster) do
			local l = all[idx]
			group_parts[#group_parts + 1] = string.format(
				"  - [%s] %s (used %dx, reinforced %dx)",
				table.concat(l.keywords or {}, " "),
				l.text or "?",
				l.use_count or 0,
				l.reinforced or 1
			)
		end
		merge_parts[#merge_parts + 1] = table.concat(group_parts, "\n")
	end

	local prompt = string.format(
		[=[
You have %d groups of similar coding lessons that need to be consolidated.
For each group, produce ONE merged lesson that captures the best wisdom from all entries.

%s

For EACH group, output ONE line:
MERGED: <2-5 keywords> | <one sentence merged lesson>

Output ONLY MERGED lines. No other text.
]=],
		#clusters,
		table.concat(merge_parts, "\n\n")
	)

	require("dwight.skills")._run_llm(prompt, function(raw, code)
		if code ~= 0 or not raw then
			if callback then
				callback({ before = #all, after = #all, merged_groups = 0, error = "LLM call failed" })
			end
			return
		end

		-- Parse merged lessons
		local merged_lessons = {}
		for line in raw:gmatch("[^\n]+") do
			local kw_str, text = line:match("^MERGED:%s*(.-)%s*|%s*(.+)$")
			if kw_str and text then
				local keywords = {}
				for kw in kw_str:gmatch("%S+") do
					keywords[#keywords + 1] = kw:lower()
				end
				if #keywords > 0 then
					merged_lessons[#merged_lessons + 1] = {
						keywords = keywords,
						text = vim.trim(text),
						timestamp = os.time(),
						reinforced = 0, -- will sum up below
						use_count = 0,
					}
				end
			end
		end

		-- Replace clustered lessons with merged ones
		-- First: collect indices to remove (from clusters that got merged)
		local remove_set = {}
		for ci, cluster in ipairs(clusters) do
			if merged_lessons[ci] then
				-- Sum up reinforcement and use counts from the cluster
				local total_reinforced = 0
				local total_use = 0
				for _, idx in ipairs(cluster) do
					total_reinforced = total_reinforced + (all[idx].reinforced or 1)
					total_use = total_use + (all[idx].use_count or 0)
					remove_set[idx] = true
				end
				merged_lessons[ci].reinforced = total_reinforced
				merged_lessons[ci].use_count = total_use
			end
		end

		-- Build new list: keep non-clustered + add merged
		local new_all = {}
		for i, l in ipairs(all) do
			if not remove_set[i] then
				new_all[#new_all + 1] = l
			end
		end
		for _, ml in ipairs(merged_lessons) do
			new_all[#new_all + 1] = ml
		end

		local before = #all
		M._save_lessons(new_all)

		local stats = {
			before = before,
			after = #new_all,
			merged_groups = #clusters,
			removed = before - #new_all,
		}

		if callback then
			callback(stats)
		end
	end)
end

--- Get lesson statistics for health check / display.
function M._lesson_stats()
	local all = M._load_lessons()
	if #all == 0 then
		return { total = 0 }
	end

	local now = os.time()
	local thirty_days = 30 * 24 * 3600
	local stale = 0
	local never_used = 0
	local total_uses = 0
	local total_reinforced = 0

	for _, l in ipairs(all) do
		if l.timestamp and (now - l.timestamp) > thirty_days then
			stale = stale + 1
		end
		if (l.use_count or 0) == 0 then
			never_used = never_used + 1
		end
		total_uses = total_uses + (l.use_count or 0)
		total_reinforced = total_reinforced + (l.reinforced or 1)
	end

	return {
		total = #all,
		stale = stale,
		never_used = never_used,
		avg_uses = total_uses / #all,
		avg_reinforced = total_reinforced / #all,
	}
end

return M
