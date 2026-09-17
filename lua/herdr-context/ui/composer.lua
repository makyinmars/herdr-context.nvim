local M = {}

local display = require("herdr-context.agent_display")
local float = require("herdr-context.ui.float")
local config = require("herdr-context.config")
local state = require("herdr-context.state")

local namespace = vim.api.nvim_create_namespace("herdr-context-composer")
local message_namespace = vim.api.nvim_create_namespace("herdr-context-message")
local active

local status_highlights = {
  ["✓"] = "DiagnosticOk",
  ["○"] = "Comment",
  ["◌"] = "DiagnosticInfo",
  ["–"] = "Comment",
  ["!"] = "DiagnosticError",
  ["↑"] = "DiagnosticWarn",
}

local LIST_TOGGLE_ID = "__lists__"

local function valid(ui)
  return ui
    and float.valid_buffer(ui.list_bufnr)
    and float.valid_window(ui.list_winid)
    and float.valid_buffer(ui.preview_bufnr)
    and float.valid_window(ui.preview_winid)
    and float.valid_buffer(ui.message_bufnr)
    and float.valid_window(ui.message_winid)
    and float.valid_buffer(ui.agent_bufnr)
    and float.valid_window(ui.agent_winid)
end

local function entry_status(session, entry)
  if entry.status == "collecting" then
    return "◌"
  elseif entry.status == "unavailable" then
    return "–"
  elseif entry.status == "failed" or entry.excluded then
    return "!"
  elseif entry.oversized then
    return "↑"
  elseif session.selected[entry.id] then
    return "✓"
  end
  return "○"
end

local function source_label(session)
  local captured = session.request.capture
  local path = captured.relative_path or "[unnamed buffer]"
  local range = captured.start_line == captured.end_line and ("L%d"):format(captured.start_line)
    or ("L%d–L%d"):format(captured.start_line, captured.end_line)
  local mode = session.request.selection and "visual" or "cursor"
  return ("%s  %s  %s"):format(path, range, mode)
end

local function reference_label(entry)
  local section = entry.safe_section or entry.section
  if section and section.reference and section.reference ~= "" then
    return section.reference
  end
  return entry.name
end

local function compute_layout(session)
  local options = config.get().composer
  local total_width = float.dimension(options.width, vim.o.columns, 58)
  local total_height = float.dimension(options.height, vim.o.lines - vim.o.cmdheight, 22)
  local col = math.max(0, math.floor((vim.o.columns - total_width) / 2))
  local row = math.max(0, math.floor((vim.o.lines - total_height) / 2) - 1)
  local gap = 1
  local agent_count = session.stage_handler and 1 or math.max(1, #(session.candidates or {}))
  local agent_h = math.min(7, math.max(3, agent_count + 1))
  local preview_h = 5
  local message_h = 6
  local gaps = gap * 3
  local refs_h = total_height - agent_h - message_h - preview_h - gaps
  if refs_h < 5 then
    message_h = math.max(4, message_h - (5 - refs_h))
    refs_h = total_height - agent_h - message_h - preview_h - gaps
  end
  refs_h = math.max(4, refs_h)
  return {
    width = total_width,
    col = col,
    agent = { row = row, height = agent_h },
    message = { row = row + agent_h + gap, height = message_h },
    refs = { row = row + agent_h + gap + message_h + gap, height = refs_h },
    preview = {
      row = row + agent_h + gap + message_h + gap + refs_h + gap,
      height = preview_h,
    },
  }
end

local function apply_layout(ui)
  local layout = compute_layout(ui.session)
  local function place(winid, spec, extra)
    extra = extra or {}
    float.reposition(winid, {
      relative = "editor",
      width = layout.width,
      height = spec.height,
      row = spec.row,
      col = layout.col,
      title = extra.title,
      title_pos = "center",
      footer = extra.footer,
      footer_pos = extra.footer_pos,
    })
  end
  place(ui.agent_winid, layout.agent, { title = " Agent " })
  place(ui.message_winid, layout.message, {
    title = " Message ",
    footer = " <C-s> keep · <C-Enter> send · q cancel ",
    footer_pos = "center",
  })
  place(ui.list_winid, layout.refs)
  local bytes = ui.session.bundle and ui.session.bundle.bytes or 0
  place(ui.preview_winid, layout.preview, {
    title = (" Send · %s "):format(float.format_bytes(bytes)),
  })
  ui.layout = layout
end

local function render_agents(ui)
  local session = ui.session
  local lines, marks = {}, {}
  ui.line_to_agent = {}

  if session.stage_handler then
    lines[1] = "  " .. (session.target_label or "new agent")
    marks[1] = {
      line = 0,
      start_col = 2,
      end_col = #lines[1],
      hl = "HerdrContextComposerInstruction",
    }
  elseif #(session.candidates or {}) == 0 then
    lines[1] = ("  No live agents in %s scope"):format(config.get().target_scope)
    lines[2] = "  Open an agent, then press r"
    marks[1] = { line = 0, start_col = 2, end_col = #lines[1], hl = "HerdrContextComposerStale" }
  else
    for index, agent in ipairs(session.candidates) do
      local selected = session.target and session.target.pane_id == agent.pane_id
      local line = display.compact(agent, { selected = selected })
      if index <= 9 then
        local marker = vim.fn.strcharpart(line, 0, 1)
        line = marker .. " " .. tostring(index) .. vim.fn.strcharpart(line, 1)
      end
      lines[#lines + 1] = line
      ui.line_to_agent[#lines] = agent
      local status = agent.agent_status or "unknown"
      local icon = display.status_icon(status)
      local icon_at = line:find(icon, 1, true)
      if icon_at then
        marks[#marks + 1] = {
          line = #lines - 1,
          start_col = icon_at - 1,
          end_col = icon_at - 1 + #icon,
          hl = display.highlights[status] or "HerdrContextUnknown",
        }
      end
      if selected then
        marks[#marks + 1] = {
          line = #lines - 1,
          start_col = 0,
          end_col = #vim.fn.strcharpart(line, 0, 1),
          hl = "HerdrContextTarget",
        }
      end
    end
  end

  float.set_lines(ui.agent_bufnr, lines, { namespace = namespace, marks = marks, modifiable = false })
end

local function update_message_placeholder(ui)
  if not float.valid_buffer(ui.message_bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(ui.message_bufnr, message_namespace, 0, -1)
  local text = table.concat(vim.api.nvim_buf_get_lines(ui.message_bufnr, 0, -1, false), "\n")
  if text:match("^%s*$") then
    vim.api.nvim_buf_set_extmark(ui.message_bufnr, message_namespace, 0, 0, {
      virt_text = { { "Tell the agent what you want to change, explain, or investigate…", "Comment" } },
      virt_text_pos = "overlay",
    })
  end
end

local function render_list(ui)
  local session = ui.session
  session:is_stale()
  local built = session.bundle
  local selected = 0
  for _, enabled in pairs(session.selected) do
    selected = selected + (enabled and 1 or 0)
  end

  local lines = { source_label(session) }
  local marks = {
    { line = 0, start_col = 0, end_col = #lines[1], hl = "HerdrContextComposerLabel" },
  }
  ui.line_to_id = {}

  if session.stale then
    lines[#lines + 1] = "! Source changed · press r to recapture"
    marks[#marks + 1] = {
      line = #lines - 1,
      start_col = 0,
      end_col = #lines[#lines],
      hl = "HerdrContextComposerStale",
    }
  elseif session.collecting then
    lines[#lines + 1] = "◌ Collecting context…"
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = ("References · %d attached"):format(selected)
  marks[#marks + 1] = {
    line = #lines - 1,
    start_col = 0,
    end_col = #lines[#lines],
    hl = "HerdrContextComposerHeader",
  }

  for _, entry in ipairs(session.entries) do
    if session:visible_entry(entry) then
      local status = entry_status(session, entry)
      local label = reference_label(entry)
      local size = entry.bytes and entry.bytes > 0 and float.format_bytes(entry.bytes) or ""
      local line = ("  %s  %s"):format(status, label)
      if size ~= "" then
        line = line .. "  ·  " .. size
      end
      if entry.embed and session.selected[entry.id] then
        line = line .. "  ·  embedded"
      end
      lines[#lines + 1] = line
      ui.line_to_id[#lines] = entry.id
      marks[#marks + 1] = {
        line = #lines - 1,
        start_col = 2,
        end_col = 2 + #status,
        hl = status_highlights[status],
      }
      local summary = entry.excluded or (entry.section and entry.section.summary) or entry.error or ""
      if entry.section and entry.section.modified and not entry.embed then
        summary = (summary ~= "" and (summary .. " · ") or "") .. "unsaved · press e to embed"
      end
      if summary ~= "" then
        lines[#lines + 1] = "     " .. summary
        marks[#marks + 1] = {
          line = #lines - 1,
          start_col = 5,
          end_col = #lines[#lines],
          hl = entry.excluded and "HerdrContextComposerError" or "Comment",
        }
      end
    end
  end

  local hidden = session:hidden_list_count()
  if hidden > 0 then
    local marker = session.lists_expanded and "▾" or "▸"
    lines[#lines + 1] = ("  %s  lists · %d hidden"):format(marker, hidden)
    ui.line_to_id[#lines] = LIST_TOGGLE_ID
    marks[#marks + 1] = {
      line = #lines - 1,
      start_col = 2,
      end_col = #lines[#lines],
      hl = "Comment",
    }
  end

  if built and built.oversized then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "! " .. built.error
    marks[#marks + 1] = {
      line = #lines - 1,
      start_col = 0,
      end_col = #lines[#lines],
      hl = "HerdrContextComposerError",
    }
  elseif session.bundle_error then
    lines[#lines + 1] = session.bundle_error
  end

  if session.unsaved_confirmed then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Unsaved reference: press e to embed, or s again to send the disk path"
    marks[#marks + 1] = {
      line = #lines - 1,
      start_col = 0,
      end_col = #lines[#lines],
      hl = "HerdrContextComposerStale",
    }
  end

  if #session.safety_warnings > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = session.safety_confirmed and "Sensitive-content warning confirmed"
      or "Sensitive-content warning"
    for _, warning in ipairs(session.safety_warnings) do
      lines[#lines + 1] = "! " .. warning
      marks[#marks + 1] = {
        line = #lines - 1,
        start_col = 0,
        end_col = #lines[#lines],
        hl = "HerdrContextComposerError",
      }
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Space attach · e embed · P preset"
  if session.stage_handler then
    lines[#lines + 1] = "s/S create agent + delegate context"
  else
    local action = config.get().submit and "stage + submit" or "stage"
    lines[#lines + 1] = ("s %s · S send now · t agent"):format(action)
  end
  lines[#lines + 1] = "r refresh · p preview · ? help · q close"
  for index = #lines - 2, #lines do
    marks[#marks + 1] = { line = index - 1, start_col = 0, end_col = #lines[index], hl = "HerdrContextComposerFooter" }
  end

  local cursor = vim.api.nvim_win_get_cursor(ui.list_winid)
  local cursor_id = ui.line_to_id[cursor[1]]
  float.set_lines(ui.list_bufnr, lines, { namespace = namespace, marks = marks, modifiable = false })
  if cursor_id then
    for line, id in pairs(ui.line_to_id) do
      if id == cursor_id then
        vim.api.nvim_win_set_cursor(ui.list_winid, { line, 0 })
        return
      end
    end
  end
  vim.api.nvim_win_set_cursor(ui.list_winid, { math.min(cursor[1], #lines), 0 })
end

local function render_preview(ui)
  local session = ui.session
  local lines
  if session.preview then
    local payload = session.bundle and session.bundle.payload or ""
    if payload == "" then
      lines = { "Nothing to send yet.", "", "Write a message or attach a reference." }
    else
      lines = vim.split(payload, "\n", { plain = true })
    end
  else
    lines = { "Payload preview hidden.", "", "Press p to show it." }
  end
  float.set_lines(ui.preview_bufnr, lines, { modifiable = false })
  local bytes = session.bundle and session.bundle.bytes or 0
  float.reposition(ui.preview_winid, { title = (" Send · %s "):format(float.format_bytes(bytes)) })
end

local function render(ui)
  if not valid(ui) then
    return
  end
  local agent_count = ui.session.stage_handler and 1 or math.max(1, #(ui.session.candidates or {}))
  if ui.agent_count ~= agent_count then
    ui.agent_count = agent_count
    apply_layout(ui)
  end
  render_agents(ui)
  render_list(ui)
  render_preview(ui)
  update_message_placeholder(ui)
end

local function cleanup(ui)
  if ui.cleaned then
    return
  end
  ui.cleaned = true
  if active == ui then
    active = nil
  end
  if ui.stale_autocmd then
    pcall(vim.api.nvim_del_autocmd, ui.stale_autocmd)
    ui.stale_autocmd = nil
  end
  if ui.resize_autocmd then
    pcall(vim.api.nvim_del_autocmd, ui.resize_autocmd)
    ui.resize_autocmd = nil
  end
  if ui.subscriber then
    state.unsubscribe(ui.subscriber)
    ui.subscriber = nil
  end
  ui.session.ui_close = nil
  ui.session.focus_agents = nil
  ui.session.focus_message = nil
  pcall(vim.cmd, "stopinsert")
  for _, winid in ipairs({ ui.preview_winid, ui.list_winid, ui.message_winid, ui.agent_winid }) do
    if float.valid_window(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end
  if not ui.session.closed then
    ui.session.closed = true
    if ui.session.cancel_collection then
      ui.session.cancel_collection()
      ui.session.cancel_collection = nil
    end
  end
end

local function panes(ui)
  return {
    ui.agent_winid,
    ui.message_winid,
    ui.list_winid,
    ui.preview_winid,
  }
end

local function win_coord(value)
  if type(value) == "table" then
    return value[1] or 0
  end
  return value or 0
end

local function focus_next(ui, reverse)
  local order = panes(ui)
  local current = vim.api.nvim_get_current_win()
  local index = 1
  for i, winid in ipairs(order) do
    if winid == current then
      index = i
      break
    end
  end
  local next_index = reverse and ((index - 2) % #order) + 1 or (index % #order) + 1
  if float.valid_window(order[next_index]) then
    vim.api.nvim_set_current_win(order[next_index])
  end
end

local function focus_direction(ui, direction)
  local current = vim.api.nvim_get_current_win()
  local origin
  local candidates = {}
  for _, winid in ipairs(panes(ui)) do
    if float.valid_window(winid) then
      local cfg = vim.api.nvim_win_get_config(winid)
      local item = {
        winid = winid,
        row = win_coord(cfg.row),
        col = win_coord(cfg.col),
      }
      candidates[#candidates + 1] = item
      if winid == current then
        origin = item
      end
    end
  end
  if not origin then
    return
  end

  local best, best_score
  for _, item in ipairs(candidates) do
    if item.winid ~= origin.winid then
      local score
      if direction == "j" and item.row > origin.row then
        score = (item.row - origin.row) * 1000 + math.abs(item.col - origin.col)
      elseif direction == "k" and item.row < origin.row then
        score = (origin.row - item.row) * 1000 + math.abs(item.col - origin.col)
      elseif direction == "l" and item.col > origin.col then
        score = (item.col - origin.col) * 1000 + math.abs(item.row - origin.row)
      elseif direction == "h" and item.col < origin.col then
        score = (origin.col - item.col) * 1000 + math.abs(item.row - origin.row)
      end
      if score and (not best_score or score < best_score) then
        best, best_score = item, score
      end
    end
  end
  if best then
    vim.api.nvim_set_current_win(best.winid)
    return
  end
  focus_next(ui, direction == "k" or direction == "h")
end

local function choose_preset(ui)
  local names = vim.tbl_keys(config.get().composer.presets)
  table.sort(names)
  vim.ui.select(names, { prompt = "Herdr context preset:" }, function(name)
    if name and not ui.session.closed then
      ui.session:apply_preset(name)
    end
  end)
end

local function show_help()
  vim.notify(
    table.concat({
      "Space    attach/detach a reference",
      "e        embed the snippet for that row",
      "i        focus the message",
      "1-9      pick that live agent",
      "t / CR   choose the agent under the cursor",
      "P        choose context preset",
      "r        recapture source",
      "s        stage (follows the submit setting)",
      "S        send with herdr agent prompt",
      "p        toggle payload preview",
      "h        open send history",
      "C-h/j/k/l  move between composer panes",
      "Tab      next composer pane",
      "q/Esc    cancel",
    }, "\n"),
    vim.log.levels.INFO,
    { title = "Herdr Context keys" }
  )
end

local function current_ref_id(ui)
  if not float.valid_window(ui.list_winid) then
    return nil
  end
  return ui.line_to_id[vim.api.nvim_win_get_cursor(ui.list_winid)[1]]
end

local function sync_message(ui)
  if not float.valid_buffer(ui.message_bufnr) or ui.session.closed then
    return
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(ui.message_bufnr, 0, -1, false), "\n")
  ui.session:set_instruction(text)
end

function M.edit_message(session)
  local ui = active
  if not ui or ui.session ~= session or not valid(ui) then
    return nil
  end
  vim.api.nvim_set_current_win(ui.message_winid)
  vim.cmd("startinsert")
  return ui.message_bufnr
end

function M.save_message(opts)
  opts = opts or {}
  local ui = active
  if not ui or not valid(ui) then
    return
  end
  sync_message(ui)
  vim.cmd("stopinsert")
  if opts.submit and not ui.session.closed then
    vim.schedule(function()
      if not ui.session.closed then
        ui.session:stage({ submit = true, wait = true })
      end
    end)
  end
end

function M.open(session)
  if active then
    active.session:close()
  end
  display.setup_highlights()
  local layout = compute_layout(session)
  local agent_bufnr, agent_winid = float.open({
    enter = false,
    width = layout.width,
    height = layout.agent.height,
    row = layout.agent.row,
    col = layout.col,
    title = " Agent ",
    filetype = "herdr-context-agents-picker",
    modifiable = false,
    cursorline = true,
  })
  local message_bufnr, message_winid = float.open({
    enter = false,
    width = layout.width,
    height = layout.message.height,
    row = layout.message.row,
    col = layout.col,
    title = " Message ",
    footer = " <C-s> keep · <C-Enter> send · q cancel ",
    footer_pos = "center",
    filetype = "markdown",
    modifiable = true,
    wrap = true,
    winhighlight = "Normal:NormalFloat,FloatBorder:DiagnosticInfo,FloatTitle:Title,FloatFooter:Comment",
  })
  local list_bufnr, list_winid = float.open({
    enter = true,
    width = layout.width,
    height = layout.refs.height,
    row = layout.refs.row,
    col = layout.col,
    title = " References ",
    filetype = "herdr-context-composer",
    modifiable = false,
    cursorline = true,
  })
  local preview_bufnr, preview_winid = float.open({
    enter = false,
    width = layout.width,
    height = layout.preview.height,
    row = layout.preview.row,
    col = layout.col,
    title = " Send · 0 B ",
    filetype = "herdr-context-preview",
    modifiable = false,
  })

  local ui = {
    session = session,
    agent_bufnr = agent_bufnr,
    agent_winid = agent_winid,
    message_bufnr = message_bufnr,
    message_winid = message_winid,
    list_bufnr = list_bufnr,
    list_winid = list_winid,
    preview_bufnr = preview_bufnr,
    preview_winid = preview_winid,
    line_to_id = {},
    line_to_agent = {},
    layout = layout,
  }
  active = ui
  session.on_update = function()
    vim.schedule(function()
      render(ui)
    end)
  end
  session.ui_close = function()
    cleanup(ui)
  end
  session.focus_agents = function()
    if float.valid_window(ui.agent_winid) then
      vim.api.nvim_set_current_win(ui.agent_winid)
    end
  end
  session.focus_message = function()
    M.edit_message(session)
  end

  local message_lines = session.instruction ~= "" and vim.split(session.instruction, "\n", { plain = true }) or { "" }
  vim.api.nvim_buf_set_lines(message_bufnr, 0, -1, false, message_lines)

  local function map(bufnr, lhs, callback, description, modes)
    vim.keymap.set(modes or "n", lhs, callback, {
      buffer = bufnr,
      silent = true,
      nowait = true,
      desc = description,
    })
  end

  local buffers = { agent_bufnr, message_bufnr, list_bufnr, preview_bufnr }
  for _, bufnr in ipairs(buffers) do
    map(bufnr, "q", function()
      session:close()
    end, "Cancel Herdr context composer")
    map(bufnr, "<Esc>", function()
      session:close()
    end, "Cancel Herdr context composer")
    map(bufnr, "s", function()
      sync_message(ui)
      session:stage()
    end, "Stage Herdr context bundle")
    map(bufnr, "S", function()
      sync_message(ui)
      session:stage({ submit = true })
    end, "Send Herdr context bundle now")
    map(bufnr, "t", function()
      session:change_target()
    end, "Change Herdr target")
    map(bufnr, "r", function()
      session:refresh()
      session:refresh_candidates()
      render(ui)
    end, "Refresh Herdr context")
    map(bufnr, "p", function()
      session:toggle_preview()
    end, "Toggle Herdr payload preview")
    map(bufnr, "i", function()
      M.edit_message(session)
    end, "Write Herdr message")
    map(bufnr, "P", function()
      choose_preset(ui)
    end, "Choose Herdr context preset")
    map(bufnr, "h", function()
      require("herdr-context.ui.history").open()
    end, "Open Herdr history")
    map(bufnr, "?", show_help, "Show Herdr composer help")
    map(bufnr, "<Tab>", function()
      focus_next(ui)
    end, "Next Herdr composer pane")
    map(bufnr, "<S-Tab>", function()
      focus_next(ui, true)
    end, "Previous Herdr composer pane")
    local function move(direction)
      return function()
        if vim.fn.mode():find("i", 1, true) then
          vim.cmd("stopinsert")
        end
        focus_direction(ui, direction)
      end
    end
    map(bufnr, "<C-h>", move("h"), "Focus left Herdr composer pane")
    map(bufnr, "<C-j>", move("j"), "Focus lower Herdr composer pane")
    map(bufnr, "<C-k>", move("k"), "Focus upper Herdr composer pane")
    map(bufnr, "<C-l>", move("l"), "Focus right Herdr composer pane")
  end
  map(message_bufnr, "<C-j>", function()
    vim.cmd("stopinsert")
    focus_direction(ui, "j")
  end, "Focus lower Herdr composer pane", { "i" })
  map(message_bufnr, "<C-k>", function()
    vim.cmd("stopinsert")
    focus_direction(ui, "k")
  end, "Focus upper Herdr composer pane", { "i" })
  map(message_bufnr, "<C-l>", function()
    vim.cmd("stopinsert")
    focus_direction(ui, "l")
  end, "Focus right Herdr composer pane", { "i" })

  map(list_bufnr, " ", function()
    local id = current_ref_id(ui)
    if id == LIST_TOGGLE_ID then
      session:toggle_lists()
    elseif id then
      session:toggle(id)
    end
  end, "Toggle Herdr context provider")
  map(list_bufnr, "e", function()
    local id = current_ref_id(ui)
    if id and id ~= LIST_TOGGLE_ID then
      session:toggle_embed(id)
    end
  end, "Embed Herdr context snippet")

  map(agent_bufnr, "<CR>", function()
    local agent = ui.line_to_agent[vim.api.nvim_win_get_cursor(agent_winid)[1]]
    if agent then
      session:set_target(agent)
    end
  end, "Select Herdr target")
  map(agent_bufnr, "t", function()
    local agent = ui.line_to_agent[vim.api.nvim_win_get_cursor(agent_winid)[1]]
    if agent then
      session:set_target(agent)
    else
      session:change_target()
    end
  end, "Select Herdr target")
  for digit = 1, 9 do
    map(agent_bufnr, tostring(digit), function()
      local agent = session.candidates[digit]
      if agent then
        session:set_target(agent)
      end
    end, "Select Herdr target " .. tostring(digit))
  end

  for _, key in ipairs({ "<C-s>" }) do
    map(message_bufnr, key, function()
      M.save_message()
    end, "Keep Herdr message", { "n", "i" })
  end
  for _, key in ipairs({ "<C-CR>", "<M-CR>" }) do
    map(message_bufnr, key, function()
      M.save_message({ submit = true })
    end, "Send Herdr message with context", { "n", "i" })
  end

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = message_bufnr,
    callback = function()
      if not ui.session.closed then
        sync_message(ui)
        update_message_placeholder(ui)
      end
    end,
  })

  for _, bufnr in ipairs(buffers) do
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      once = true,
      callback = function()
        cleanup(ui)
      end,
    })
  end
  ui.stale_autocmd = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = session.request.bufnr,
    callback = function()
      if not session.closed then
        session.stale = true
        render(ui)
      end
    end,
  })
  ui.resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
    callback = function()
      if valid(ui) then
        apply_layout(ui)
        render(ui)
      end
    end,
  })
  ui.subscriber = function()
    vim.schedule(function()
      if not session.closed then
        session:refresh_candidates()
        render(ui)
      end
    end)
  end
  state.subscribe(ui.subscriber)
  render(ui)
  return list_bufnr
end

function M._active()
  return active
end

M.format_bytes = float.format_bytes

return M
