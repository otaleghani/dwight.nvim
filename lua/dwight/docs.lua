-- dwight/docs.lua
-- Fetch documentation from URLs and generate skills. Logged.

local M = {}

local uv = vim.loop or vim.uv

local function get_config()
  return require("dwight").config
end

local function fetch_url(url, callback)
  local chunks = {}
  local stderr_chunks = {}
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local handle
  handle = uv.spawn("curl", {
    args = { "-sL", "--max-time", "30", url },
    stdio = { nil, stdout, stderr },
  }, function(code)
    if stdout then stdout:close() end
    if stderr then stderr:close() end
    if handle then handle:close() end
    vim.schedule(function()
      if code ~= 0 or #chunks == 0 then
        callback(nil, "Fetch failed (exit " .. code .. ")")
        return
      end
      local raw = table.concat(chunks, "")
      local text = raw
        :gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
        :gsub("<[^>]+>", " "):gsub("&nbsp;", " "):gsub("&amp;", "&")
        :gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
        :gsub("%s+", " "):gsub("\n%s*\n", "\n")
      if #text > 15000 then text = text:sub(1, 15000) .. "\n[truncated]" end
      callback(text, nil)
    end)
  end)
  if not handle then callback(nil, "Failed to spawn curl"); return end
  stdout:read_start(function(err, data) if not err and data then chunks[#chunks + 1] = data end end)
  stderr:read_start(function(err, data) if not err and data then stderr_chunks[#stderr_chunks + 1] = data end end)
end

function M.generate_from_url()
  local project = require("dwight.project")
  if not project.is_initialized() then
    vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Skill name: " }, function(name)
    if not name or name == "" then return end
    name = name:gsub("[^%w%-_]", "-"):lower()

    vim.ui.input({ prompt = "Documentation URL: " }, function(url)
      if not url or url == "" then return end

      vim.ui.input({ prompt = "Focus area? " }, function(focus)
        focus = focus or "general usage patterns"
        vim.notify("[dwight] Fetching " .. url .. "…", vim.log.levels.INFO)

        fetch_url(url, function(doc_text, err)
          if err then vim.notify("[dwight] " .. err, vim.log.levels.ERROR); return end
          vim.notify(string.format("[dwight] %d chars fetched. Generating…", #doc_text), vim.log.levels.INFO)
          M._generate_skill(name, doc_text, focus, url)
        end)
      end)
    end)
  end)
end

function M._generate_skill(name, doc_text, focus, source_url)
  local project = require("dwight.project")
  local log = require("dwight.log")
  local output_path = project.skills_dir() .. "/" .. name .. ".md"

  local prompt = string.format([[
Create a coding skill guide from docs at %s.
Focus: %s

Practical markdown with: overview, key API patterns with examples, gotchas, conventions.
Under 200 lines. Focus on what an AI coding assistant needs. Skip setup.
Reply with ONLY markdown inside a fenced code block.

Documentation:
%s
]], source_url, focus, doc_text)

  local job_id = log._next_id()
  log.start(job_id, "gen-docs:" .. name, vim.api.nvim_get_current_buf(), 0, 0, prompt)

  require("dwight.skills")._run_llm(prompt, function(raw, code)
    if code ~= 0 or vim.trim(raw) == "" then
      log.finish(job_id, "error", raw, nil, "Generation failed")
      vim.notify("[dwight] Generation failed. Creating template.", vim.log.levels.WARN)
      M._write_fallback(output_path, name, focus, source_url)
      return
    end

    local blocks = {}
    for block in raw:gmatch("```%w*\n(.-)\n```") do blocks[#blocks + 1] = block end
    local content
    if #blocks > 0 then
      content = blocks[1]
      for i = 2, #blocks do if #blocks[i] > #content then content = blocks[i] end end
    else
      content = raw:gsub("^[^\n]*[Hh]ere.-\n", "")
    end

    local header = string.format("<!-- Generated from %s -->\n\n", source_url)
    local out = io.open(output_path, "w")
    if out then
      out:write(header .. content); out:close()
      log.finish(job_id, "success", raw, content, nil)
      vim.notify("✅ [dwight] Skill '@" .. name .. "' created!", vim.log.levels.INFO)
      vim.cmd("edit " .. vim.fn.fnameescape(output_path))
    else
      log.finish(job_id, "error", raw, nil, "Write failed")
    end
  end)
end

function M._write_fallback(path, name, focus, source_url)
  local title = name:gsub("-", " "):gsub("(%a)([%w_']*)", function(a, b) return a:upper() .. b end)
  local f = io.open(path, "w")
  if f then
    f:write(string.format("<!-- From %s (template) -->\n\n# %s\n\n## Overview\nSkill for: %s\n\n## Patterns\n\n## Gotchas\n\n## Conventions\n",
      source_url, title, focus))
    f:close()
    vim.notify("[dwight] Template '@" .. name .. "' created.", vim.log.levels.INFO)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end
end

return M
