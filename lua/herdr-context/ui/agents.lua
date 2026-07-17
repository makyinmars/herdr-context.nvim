local M = {}

local config = require("herdr-context.config")
local herdr = require("herdr-context.herdr")
local state = require("herdr-context.state")
local targets = require("herdr-context.targets")

local namespace = vim.api.nvim_create_namespace("herdr-context-agents")
local bufnr
local winid
local line_to_pane = {}
local line_to_group = {}
local subscriber
local filter_text = ""
local collapsed = {}

local status_icons = {
  idle = "●",
  working = "◉",
  blocked = "!",
  done = "●",
  unknown = "○",
}

local status_highlights = {
  idle = "HerdrContextIdle",
  working = "HerdrContextWorking",
  blocked = "HerdrContextBlocked",
  done = "HerdrContextIdle",
  unknown = "HerdrContextUnknown",
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "herdr-context.nvim" })
end

local function setup_highlights()
  for name, link in pairs({
    HerdrContextIdle = "DiagnosticOk",
    HerdrContextWorking = "DiagnosticInfo",
    HerdrContextBlocked = "DiagnosticError",
    HerdrContextUnknown = "Comment",
    HerdrContextTarget = "Special",
    HerdrContextDisconnected = "DiagnosticWarn",
  }) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
end

local function valid_buffer()
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_window()
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function pane_for_cursor()
  if not valid_window() then
    return nil
  end
  return line_to_pane[vim.api.nvim_win_get_cursor(winid)[1]]
end

local function selected_agent()
  local pane_id = pane_for_cursor()
  if not pane_id then
    return nil
  end
  return state.get().agents_by_pane[pane_id]
end

local function shorten(path)
  if not path or path == "" then
    return nil
  end
  return vim.fn.fnamemodify(path, ":~:t")
end

local function truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width <= 1 then
    return "…"
  end
  local result = ""
  for index = 0, vim.fn.strchars(text) - 1 do
    local next_result = result .. vim.fn.strcharpart(text, index, 1)
    if vim.fn.strdisplaywidth(next_result .. "…") > width then
      break
    end
    result = next_result
  end
  return result .. "…"
end

local function agent_line(agent, current, options)
  local status = agent.agent_status or "unknown"
  local prefix = current.target_pane_id == agent.pane_id and "▶" or " "
  local parts = {
    prefix,
    status_icons[status] or status_icons.unknown,
    string.format("%-8s", agent.agent or "agent"),
    string.format("%-8s", status),
  }
  if options.show_tab then
    parts[#parts + 1] = agent.tab_label or agent.tab_id or "?"
  end
  if options.show_workspace then
    parts[#parts + 1] = agent.workspace_label or agent.workspace_id or "?"
  end
  parts[#parts + 1] = agent.pane_id
  if options.show_cwd then
    parts[#parts + 1] = shorten(agent.foreground_cwd or agent.cwd)
  end
  local message = agent.message or agent.status_message
  if message and message ~= "" then
    parts[#parts + 1] = "— " .. tostring(message):gsub("[%s\r\n]+", " ")
  end
  return truncate(
    table.concat(
      vim.tbl_filter(function(value)
        return value ~= nil
      end, parts),
      " "
    ),
    options.width - 1
  ),
    status,
    prefix
end

local function matches_filter(agent)
  if filter_text == "" then
    return true
  end
  local values = {
    agent.agent,
    agent.display_agent,
    agent.agent_status,
    agent.workspace_label,
    agent.workspace_id,
    agent.tab_label,
    agent.tab_id,
    agent.pane_id,
    agent.foreground_cwd,
    agent.cwd,
    agent.message,
    agent.status_message,
  }
  local text = table.concat(
    vim.tbl_map(
      function(value)
        return tostring(value)
      end,
      vim.tbl_filter(function(value)
        return value ~= nil
      end, values)
    ),
    " "
  )
  return text:lower():find(filter_text:lower(), 1, true) ~= nil
end

local function group_for(agent, mode)
  if mode == "none" then
    return nil, nil
  elseif mode == "tab" then
    local tab = agent.tab_label or agent.tab_id or "Unknown tab"
    return "tab:" .. (agent.tab_id or tab), tab
  end
  local workspace = agent.workspace_label or agent.workspace_id or "Unknown workspace"
  local tab = agent.tab_label or agent.tab_id or "Unknown tab"
  return ("workspace:%s:tab:%s"):format(agent.workspace_id or workspace, agent.tab_id or tab), workspace .. " / " .. tab
end

function M.render()
  if not valid_buffer() then
    return
  end
  local cfg = config.get()
  local current = state.get()
  local cursor_pane = pane_for_cursor()
  local candidates = targets.candidates(current, { scope = cfg.target_scope })
  local lines = { " Herdr Agents" }
  local marks = {}
  local pane_to_line = {}
  local first_agent_line
  line_to_pane = {}
  line_to_group = {}

  if not current.connected then
    lines[1] = lines[1] .. "  × disconnected"
  elseif current.mode == "polling" then
    lines[1] = lines[1] .. "  ○ polling"
  end
  lines[#lines + 1] = ""

  candidates = vim.tbl_filter(matches_filter, candidates)
  if filter_text ~= "" then
    lines[1] = lines[1] .. ("  /%s"):format(filter_text)
  end

  if #candidates == 0 then
    lines[#lines + 1] = " No target agents in " .. cfg.target_scope .. " scope"
  else
    local groups, group_by_id = {}, {}
    for _, agent in ipairs(candidates) do
      local group_id, group_label = group_for(agent, cfg.agents_view.group_by)
      group_id = group_id or "ungrouped"
      local group = group_by_id[group_id]
      if not group then
        group = { id = group_id, label = group_label, agents = {} }
        group_by_id[group_id] = group
        groups[#groups + 1] = group
      end
      group.agents[#group.agents + 1] = agent
    end
    for _, group in ipairs(groups) do
      if group.label then
        lines[#lines + 1] = (collapsed[group.id] and " ▸ " or " ▾ ") .. group.label
        line_to_group[#lines] = group.id
      end
      if not group.label or not collapsed[group.id] then
        for _, agent in ipairs(group.agents) do
          local line, status, prefix = agent_line(agent, current, cfg.agents_view)
          lines[#lines + 1] = line
          local line_number = #lines
          line_to_pane[line_number] = agent.pane_id
          pane_to_line[agent.pane_id] = line_number
          first_agent_line = first_agent_line or line_number
          marks[#marks + 1] = {
            line = line_number - 1,
            status = status,
            status_col = #prefix + 1,
            status_end = #prefix + 1 + #(status_icons[status] or status_icons.unknown),
            target_end = #prefix,
            target = current.target_pane_id == agent.pane_id,
          }
        end
      end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = " <CR>/t target   f focus   p output"
  lines[#lines + 1] = " / filter   Space fold   r refresh   q close"

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, namespace, 0, 1, {
    end_col = #lines[1],
    hl_group = current.connected and "Title" or "HerdrContextDisconnected",
  })
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(bufnr, namespace, mark.line, mark.status_col, {
      end_col = mark.status_end,
      hl_group = status_highlights[mark.status] or "HerdrContextUnknown",
    })
    if mark.target then
      vim.api.nvim_buf_set_extmark(bufnr, namespace, mark.line, 0, {
        end_col = mark.target_end,
        hl_group = "HerdrContextTarget",
      })
    end
  end
  vim.bo[bufnr].modifiable = false

  if valid_window() then
    local target_line = cursor_pane and pane_to_line[cursor_pane]
      or (current.target_pane_id and pane_to_line[current.target_pane_id])
      or first_agent_line
    local current_line = vim.api.nvim_win_get_cursor(winid)[1]
    vim.api.nvim_win_set_cursor(winid, { target_line or math.min(current_line, #lines), 0 })
  end
end

function M.select_target()
  local agent = selected_agent()
  if not agent then
    return
  end
  local ok, err = targets.remember(config.get(), agent)
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return
  end
  notify(("Herdr target: %s (%s)"):format(agent.agent or "agent", agent.pane_id))
end

function M.focus()
  local agent = selected_agent()
  if not agent then
    return
  end
  herdr.focus(config.get(), agent.pane_id, function(_, err)
    if err then
      notify("Could not focus Herdr pane: " .. err, vim.log.levels.ERROR)
    end
  end)
end

function M.preview()
  local agent = selected_agent()
  if not agent then
    return
  end
  local cfg = config.get()
  require("herdr-context.ui.preview").open(agent, {
    side = cfg.agents_view.side_preview,
    source_winid = winid,
    position = cfg.agents_view.position,
  })
end

function M.filter()
  vim.ui.input({ prompt = "Filter Herdr agents: ", default = filter_text }, function(value)
    if value ~= nil then
      filter_text = value:match("^%s*(.-)%s*$")
      M.render()
    end
  end)
end

function M.toggle_group()
  if not valid_window() then
    return
  end
  local group = line_to_group[vim.api.nvim_win_get_cursor(winid)[1]]
  if group then
    collapsed[group] = not collapsed[group]
    M.render()
  end
end

function M.refresh()
  state.refresh({ force = true }, function(_, err)
    if err then
      notify("Could not refresh Herdr state: " .. err, vim.log.levels.ERROR)
    end
  end)
end

local function cleanup()
  require("herdr-context.ui.preview").close()
  if subscriber then
    state.unsubscribe(subscriber)
    subscriber = nil
  end
  bufnr = nil
  winid = nil
  line_to_pane = {}
  line_to_group = {}
end

function M.close()
  if valid_window() then
    vim.api.nvim_win_close(winid, true)
  elseif valid_buffer() then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  else
    cleanup()
  end
end

function M.open()
  if valid_window() then
    vim.api.nvim_set_current_win(winid)
    return bufnr
  end

  setup_highlights()
  local cfg = config.get()
  vim.cmd(cfg.agents_view.position == "left" and "topleft vsplit" or "botright vsplit")
  winid = vim.api.nvim_get_current_win()
  bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.api.nvim_win_set_width(winid, cfg.agents_view.width)
  vim.wo[winid].winfixwidth = true
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].wrap = false
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "herdr-context-agents"
  vim.bo[bufnr].modifiable = false

  local function map(lhs, callback, description)
    vim.keymap.set("n", lhs, callback, { buffer = bufnr, silent = true, desc = description })
  end
  map("q", M.close, "Close Herdr agents")
  map("r", M.refresh, "Refresh Herdr agents")
  map("<CR>", M.select_target, "Select Herdr target")
  map("t", M.select_target, "Select Herdr target")
  map("f", M.focus, "Focus Herdr pane")
  map("p", M.preview, "Preview Herdr output")
  map("/", M.filter, "Filter Herdr agents")
  map(" ", M.toggle_group, "Toggle Herdr agent group")
  map("c", function()
    filter_text = ""
    M.render()
  end, "Clear Herdr agent filter")

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = cleanup,
  })
  subscriber = function()
    vim.schedule(function()
      if valid_buffer() then
        M.render()
      end
    end)
  end
  state.subscribe(subscriber)
  M.render()
  return bufnr
end

function M.toggle()
  if valid_window() then
    M.close()
  else
    M.open()
  end
end

function M._line_to_pane()
  return vim.deepcopy(line_to_pane)
end

function M._filter()
  return filter_text
end

return M
