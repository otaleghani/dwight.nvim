-- dwight/libs.lua
-- Library API reference system. Structured XML for LLM consumption.
-- %lib-name in prompts injects the reference. :DwightAddLib creates from URLs or source.
-- Stored as .xml in .dwight/libs/. Legacy .md files still supported.

local M = {}

local uv = vim.loop or vim.uv

local function libs_dir()
  return require("dwight.project").dir() .. "/libs"
end

--------------------------------------------------------------------
-- List / Read / Resolve
--------------------------------------------------------------------

function M.list()
  local dir = libs_dir()
  if vim.fn.isdirectory(dir) ~= 1 then return {} end
  local items = {}
  local seen = {}
  local handle = uv.fs_scandir(dir)
  if not handle then return {} end
  while true do
    local name, ftype = uv.fs_scandir_next(handle)
    if not name then break end
    if ftype == "file" or ftype == "link" then
      local base = name:gsub("%.xml$", ""):gsub("%.md$", "")
      if not seen[base] then
        seen[base] = true
        items[#items + 1] = base
      end
    end
  end
  table.sort(items)
  return items
end

function M.names() return M.list() end

function M.read(name)
  -- Prefer .xml, fall back to .md
  local xml_path = libs_dir() .. "/" .. name .. ".xml"
  local md_path = libs_dir() .. "/" .. name .. ".md"
  local path = vim.fn.filereadable(xml_path) == 1 and xml_path or md_path
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a"); f:close()
  return content
end

function M.resolve_many(lib_names)
  local results = {}
  for _, name in ipairs(lib_names or {}) do
    local content = M.read(name)
    if content then results[#results + 1] = { name = name, content = content } end
  end
  return results
end

--------------------------------------------------------------------
-- URL Fetching
--------------------------------------------------------------------

local function fetch_url(url, callback)
  local chunks, stderr_chunks = {}, {}
  local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
  local handle
  handle = uv.spawn("curl", {
    args = { "-sL", "--max-time", "30", url },
    stdio = { nil, stdout, stderr },
  }, function(code)
    if stdout then stdout:close() end; if stderr then stderr:close() end
    if handle then handle:close() end
    vim.schedule(function()
      if code ~= 0 then callback(nil, "Fetch failed"); return end
      local raw = table.concat(chunks, "")
      local text = raw:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
        :gsub("<[^>]+>", " "):gsub("&nbsp;", " "):gsub("&amp;", "&")
        :gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
        :gsub("%s+", " "):gsub("\n%s*\n", "\n")
      if #text > 20000 then text = text:sub(1, 20000) .. "\n[truncated]" end
      callback(text, nil)
    end)
  end)
  if not handle then callback(nil, "spawn failed"); return end
  stdout:read_start(function(e, d) if not e and d then chunks[#chunks + 1] = d end end)
  stderr:read_start(function(e, d) if not e and d then stderr_chunks[#stderr_chunks + 1] = d end end)
end

local function fetch_multiple_urls(urls, callback)
  local results = {}
  local pending = #urls
  if pending == 0 then callback(results); return end
  for i, url in ipairs(urls) do
    fetch_url(url, function(text, err)
      results[i] = { url = url, text = text, err = err }
      pending = pending - 1
      if pending == 0 then callback(results) end
    end)
  end
end

--------------------------------------------------------------------
-- Source code extraction
--------------------------------------------------------------------

local function find_package_types(pkg_name)
  local cwd = vim.fn.getcwd()
  local candidates = {
    cwd .. "/node_modules/" .. pkg_name .. "/index.d.ts",
    cwd .. "/node_modules/@types/" .. pkg_name .. "/index.d.ts",
    cwd .. "/node_modules/" .. pkg_name .. "/dist/index.d.ts",
    cwd .. "/node_modules/" .. pkg_name .. "/lib/index.d.ts",
  }
  for _, path in ipairs(candidates) do
    if vim.fn.filereadable(path) == 1 then return path, "typescript" end
  end

  local py_paths = vim.fn.systemlist("python3 -c \"import " .. pkg_name .. "; print(" .. pkg_name .. ".__file__)\" 2>/dev/null")
  if #py_paths > 0 and py_paths[1] ~= "" then
    local pkg_dir = vim.fn.fnamemodify(py_paths[1], ":h")
    local pyi = pkg_dir .. "/__init__.pyi"
    if vim.fn.filereadable(pyi) == 1 then return pyi, "python" end
    return py_paths[1], "python"
  end
  return nil, nil
end

local function extract_signatures_from_file(path, lang)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a"); f:close()

  if lang == "typescript" or path:match("%.d%.ts$") then
    local lines = vim.split(content, "\n", { plain = true })
    if #lines > 3000 then
      local trimmed = {}
      for i = 1, 3000 do trimmed[i] = lines[i] end
      content = table.concat(trimmed, "\n")
    end
    return content
  end

  if lang == "python" then
    local sigs = {}
    for line in content:gmatch("[^\n]+") do
      if line:match("^%s*def ") or line:match("^%s*class ")
        or line:match("^%s*async def ") or line:match("^%s*@")
        or line:match('^%s*"""') or line:match("^%s*'''") then
        sigs[#sigs + 1] = line
      end
    end
    return table.concat(sigs, "\n")
  end

  return content:sub(1, 10000)
end

--------------------------------------------------------------------
-- XML generation prompt
--------------------------------------------------------------------

local XML_PROMPT = [[
Create a structured XML API reference for the library "%s".

Source: %s

%s

Generate XML in this EXACT format (no markdown, no fences, ONLY raw XML):

<library name="%s" source="%s">
  <description>One-line description of the library</description>
  <api>
    <function name="functionName" returns="ReturnType">
      <param name="paramName" type="ParamType" />
      <description>What it does</description>
    </function>
    <class name="ClassName">
      <method name="methodName" returns="ReturnType">
        <param name="paramName" type="ParamType" />
      </method>
      <property name="propName" type="PropType" />
    </class>
  </api>
  <types>
    <type name="TypeName">
      <field name="fieldName" type="FieldType" />
    </type>
  </types>
  <patterns>
    <pattern name="Pattern description">
      <code>concise usage example</code>
    </pattern>
  </patterns>
</library>

Focus on the MOST IMPORTANT public API. Be extremely compact.
Include only signatures and types — no prose explanations.
Respond with ONLY the raw XML. No fences, no preamble.
]]

--------------------------------------------------------------------
-- :DwightAddLib
--------------------------------------------------------------------

function M.add_lib()
  local project = require("dwight.project")
  if not project.is_initialized() then
    vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN); return
  end
  vim.fn.mkdir(libs_dir(), "p")

  vim.ui.input({ prompt = "Library name (e.g., 'express', 'prisma'): " }, function(name)
    if not name or name == "" then return end
    name = name:lower():gsub("[^%w_%-]", "-")

    vim.ui.input({ prompt = "Source: URLs (comma-sep) or 'source' for installed package: " }, function(source)
      if not source or source == "" then return end

      if source:lower() == "source" then
        M._from_source(name)
      else
        local urls = {}
        for url in source:gmatch("[^,]+") do
          url = vim.trim(url)
          if url ~= "" then urls[#urls + 1] = url end
        end
        if #urls > 0 then M._from_urls(name, urls) end
      end
    end)
  end)
end

function M._from_source(name)
  local path, lang = find_package_types(name)
  if not path then
    vim.notify("[dwight] Could not find type definitions for '" .. name .. "'.", vim.log.levels.WARN)
    return
  end

  vim.notify("[dwight] Extracting signatures from " .. path .. "…", vim.log.levels.INFO)
  local sigs = extract_signatures_from_file(path, lang)
  if not sigs then
    vim.notify("[dwight] Failed to read " .. path, vim.log.levels.ERROR); return
  end

  local log = require("dwight.log")
  local prompt = string.format(XML_PROMPT, name,
    "local package (" .. (lang or "unknown") .. ")",
    "```" .. (lang or "") .. "\n" .. sigs:sub(1, 12000) .. "\n```",
    name, "source:" .. path)

  local job_id = log._next_id()
  log.start(job_id, "lib-source:" .. name, vim.api.nvim_get_current_buf(), 0, 0, prompt)

  require("dwight.skills")._run_llm(prompt, function(raw, code)
    M._save_lib(name, raw, code, job_id, "source:" .. path)
  end)
end

function M._from_urls(name, urls)
  vim.notify(string.format("[dwight] Fetching %d URL(s) for '%s'…", #urls, name), vim.log.levels.INFO)

  fetch_multiple_urls(urls, function(results)
    local all_text = {}
    for _, r in ipairs(results) do
      if r.text then
        all_text[#all_text + 1] = "--- " .. r.url .. " ---\n" .. r.text
      end
    end
    if #all_text == 0 then
      vim.notify("[dwight] All URL fetches failed.", vim.log.levels.ERROR); return
    end

    local combined = table.concat(all_text, "\n\n")
    if #combined > 25000 then combined = combined:sub(1, 25000) end

    local log = require("dwight.log")
    local prompt = string.format(XML_PROMPT, name,
      "documentation URLs",
      "Documentation:\n" .. combined,
      name, table.concat(urls, ", "))

    local job_id = log._next_id()
    log.start(job_id, "lib-urls:" .. name, vim.api.nvim_get_current_buf(), 0, 0, prompt)

    require("dwight.skills")._run_llm(prompt, function(raw, code)
      M._save_lib(name, raw, code, job_id, table.concat(urls, ", "))
    end)
  end)
end

function M._save_lib(name, raw, exit_code, job_id, source)
  local log = require("dwight.log")
  local output = libs_dir() .. "/" .. name .. ".xml"

  if exit_code ~= 0 or vim.trim(raw or "") == "" then
    log.finish(job_id, "error", raw, nil, "Generation failed")
    vim.notify("[dwight] Library reference generation failed.", vim.log.levels.ERROR)
    return
  end

  -- Extract XML: strip any fences or preamble
  local content = raw
  -- Try extracting from code fences
  local fenced = raw:match("```%w*%s*\n(.-)```") or raw:match("~~~%w*%s*\n(.-)~~~")
  if fenced then content = fenced end
  -- Ensure it starts with <library
  local xml_start = content:find("<library")
  if xml_start then
    content = content:sub(xml_start)
    -- Trim anything after closing tag
    local xml_end = content:find("</library>")
    if xml_end then content = content:sub(1, xml_end + 9) end
  end

  content = vim.trim(content)

  local f = io.open(output, "w")
  if f then
    f:write(content); f:close()
    log.finish(job_id, "success", raw, content, nil)
    vim.notify("[dwight] ✅ Library reference '%" .. name .. "' created!", vim.log.levels.INFO)
    vim.cmd("edit " .. vim.fn.fnameescape(output))
  else
    log.finish(job_id, "error", raw, nil, "Write failed")
  end
end

--------------------------------------------------------------------
-- Browse
--------------------------------------------------------------------

function M.pick()
  local names = M.list()
  if #names == 0 then
    vim.notify("[dwight] No libs. Run :DwightAddLib.", vim.log.levels.INFO); return
  end
  local has_tel, pickers = pcall(require, "telescope.pickers")
  if has_tel then
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local previewers = require("telescope.previewers")

    pickers.new({}, {
      prompt_title = "📚 Dwight Libs  ⏎ open  ^D delete",
      finder = finders.new_table({ results = names }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        define_preview = function(self, entry)
          local content = M.read(entry[1]) or "(empty)"
          local lines = vim.split(content, "\n", { plain = true })
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
          vim.bo[self.state.bufnr].filetype = "xml"
        end,
      }),
      attach_mappings = function(pb, map)
        actions.select_default:replace(function()
          local sel = action_state.get_selected_entry()
          actions.close(pb)
          if sel then
            local xml = libs_dir() .. "/" .. sel[1] .. ".xml"
            local md = libs_dir() .. "/" .. sel[1] .. ".md"
            local path = vim.fn.filereadable(xml) == 1 and xml or md
            vim.cmd("edit " .. vim.fn.fnameescape(path))
          end
        end)
        map("i", "<C-d>", function()
          local sel = action_state.get_selected_entry()
          if sel then
            os.remove(libs_dir() .. "/" .. sel[1] .. ".xml")
            os.remove(libs_dir() .. "/" .. sel[1] .. ".md")
            vim.notify("[dwight] Deleted %" .. sel[1], vim.log.levels.INFO)
            actions.close(pb)
          end
        end)
        return true
      end,
    }):find()
  else
    local items = {}
    for i, n in ipairs(names) do items[i] = i .. ". %" .. n end
    vim.ui.input({ prompt = table.concat(items, " | ") .. " > " }, function(c)
      if not c then return end
      local idx = tonumber(c)
      if idx and names[idx] then
        local xml = libs_dir() .. "/" .. names[idx] .. ".xml"
        local md = libs_dir() .. "/" .. names[idx] .. ".md"
        local path = vim.fn.filereadable(xml) == 1 and xml or md
        vim.cmd("edit " .. vim.fn.fnameescape(path))
      end
    end)
  end
end

return M
