local M = {}

local config = require("herdr-context.config")
local herdr = require("herdr-context.herdr")

local active
local generation = 0

local function valid(view)
  return view and vim.api.nvim_buf_is_valid(view.bufnr) and vim.api.nvim_win_is_valid(view.winid)
end

local function render(view, lines)
  if not valid(view) then
    return
  end
  vim.bo[view.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(view.bufnr, 0, -1, false, lines)
  vim.bo[view.bufnr].modifiable = false
end

local function value(item)
  if item == nil or item == vim.NIL then
    return "—"
  elseif type(item) == "boolean" then
    return item and "yes" or "no"
  elseif type(item) == "table" then
    return #item == 0 and "—" or table.concat(item, ", ")
  end
  return tostring(item)
end

local function field(lines, label, item)
  lines[#lines + 1] = ("  %-24s %s"):format(label .. ":", value(item))
end

local function evidence_lines(lines, evidence)
  evidence = evidence or {}
  field(lines, "Contains", evidence.contains)
  field(lines, "Regex", evidence.regex)
  field(lines, "Line regex", evidence.line_regex)
  field(
    lines,
    "Logical gates",
    ("all=%s, any=%s, not=%s"):format(evidence.all_count or 0, evidence.any_count or 0, evidence.not_count or 0)
  )
  field(lines, "Region bytes", evidence.region_bytes)
  if evidence.region_preview and evidence.region_preview ~= "" then
    field(lines, "Region preview", tostring(evidence.region_preview):gsub("[\r\n]+", " ↵ "))
  end
end

function M.format(explanation, agent)
  local lines = { "Herdr Agent Detection Explanation", "" }
  field(lines, "Pane", agent and agent.pane_id)
  field(lines, "Agent", explanation.agent or (agent and (agent.display_agent or agent.agent)))
  field(lines, "Final state", explanation.state)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Detection source"
  field(
    lines,
    "Lifecycle authority",
    explanation.screen_detection_skip_reason
      or (explanation.screen_detection_skipped and "screen detection skipped" or nil)
  )
  field(lines, "Manifest source", explanation.manifest_source)
  field(lines, "Manifest version", explanation.manifest_version)
  field(lines, "Cached remote version", explanation.cached_remote_version)
  field(lines, "Remote update status", explanation.remote_update_status)
  field(lines, "Remote update error", explanation.remote_update_error)
  field(lines, "Override shadows remote", explanation.local_override_shadowing_remote)

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Matched rule"
  local matched = explanation.matched_rule
  if matched then
    field(lines, "Rule", matched.id)
    field(lines, "State", matched.state)
    field(lines, "Priority", matched.priority)
    field(lines, "Region", matched.region)
  else
    lines[#lines + 1] = "  No manifest rule matched."
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Visible evidence"
  field(lines, "Idle", explanation.visible_idle)
  field(lines, "Working", explanation.visible_working)
  field(lines, "Blocked", explanation.visible_blocker)
  field(lines, "Skip state update", explanation.skip_state_update)
  field(lines, "Skipped update reason", explanation.skipped_update_reason)
  field(lines, "Fallback reason", explanation.fallback_reason)
  field(lines, "Warning", explanation.warning)

  local evaluated = explanation.evaluated_rules or {}
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("Evaluated rules (%d)"):format(#evaluated)
  if #evaluated == 0 then
    lines[#lines + 1] = "  No screen rules were evaluated."
  end
  for index, rule in ipairs(evaluated) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("  %s %s → %s"):format(
      rule.matched and "✓" or "·",
      rule.id or ("rule " .. index),
      rule.state or "unknown"
    )
    field(lines, "Priority", rule.priority)
    field(lines, "Region", rule.region)
    evidence_lines(lines, rule.evidence)
  end
  return lines
end

local function cleanup(view)
  if active ~= view then
    return
  end
  active = nil
  generation = generation + 1
  if view.process and view.process.kill then
    pcall(view.process.kill, view.process, 15)
  end
end

function M.close()
  local view = active
  if not view then
    return
  end
  if vim.api.nvim_win_is_valid(view.winid) then
    vim.api.nvim_win_close(view.winid, true)
  elseif vim.api.nvim_buf_is_valid(view.bufnr) then
    vim.api.nvim_buf_delete(view.bufnr, { force = true })
  else
    cleanup(view)
  end
  if view.source_winid and vim.api.nvim_win_is_valid(view.source_winid) then
    vim.api.nvim_set_current_win(view.source_winid)
  end
end

local function load(view)
  generation = generation + 1
  local request_generation = generation
  if view.process and view.process.kill then
    pcall(view.process.kill, view.process, 15)
    view.process = nil
  end
  render(view, { "Loading agent detection explanation…" })
  local callback_called = false
  local process = herdr.explain_agent(config.get(), view.agent.pane_id, function(explanation, err)
    callback_called = true
    if active ~= view or generation ~= request_generation then
      return
    end
    if err then
      render(view, { "Could not explain agent detection:", "", tostring(err) })
      return
    end
    render(view, M.format(explanation, view.agent))
  end)
  if not callback_called then
    view.process = process
  end
end

function M.open(agent, opts)
  opts = opts or {}
  M.close()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local max_width = math.max(1, vim.o.columns - 4)
  local max_height = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
  local width = math.min(math.max(52, math.floor(vim.o.columns * 0.75)), max_width)
  local height = math.min(math.max(12, math.floor((vim.o.lines - vim.o.cmdheight) * 0.75)), max_height)
  local label = agent.display_agent or agent.agent or "agent"
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    title = (" %s · detection explanation "):format(label),
    title_pos = "center",
  })
  local view = { bufnr = bufnr, winid = winid, agent = agent, source_winid = opts.source_winid }
  active = view

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "herdr-context-explain"
  vim.bo[bufnr].modifiable = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].wrap = true

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, M.close, { buffer = bufnr, silent = true, nowait = true, desc = "Close explanation" })
  end
  vim.keymap.set("n", "r", function()
    load(view)
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Refresh agent explanation" })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      cleanup(view)
    end,
  })
  load(view)
  return bufnr
end

function M._active()
  return active
end

return M
