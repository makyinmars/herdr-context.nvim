local M = {}

local active
local namespace = vim.api.nvim_create_namespace("herdr-context-message")

local function valid(editor)
  return editor and vim.api.nvim_buf_is_valid(editor.bufnr) and vim.api.nvim_win_is_valid(editor.winid)
end

function M.close(session)
  local editor = active
  if not editor or (session and editor.session ~= session) then
    return
  end
  active = nil
  if vim.api.nvim_win_is_valid(editor.winid) then
    vim.api.nvim_win_close(editor.winid, true)
  elseif vim.api.nvim_buf_is_valid(editor.bufnr) then
    vim.api.nvim_buf_delete(editor.bufnr, { force = true })
  end
  if editor.return_winid and vim.api.nvim_win_is_valid(editor.return_winid) then
    vim.api.nvim_set_current_win(editor.return_winid)
  end
end

function M.save(opts)
  opts = opts or {}
  local editor = active
  if not valid(editor) then
    return
  end
  local session = editor.session
  local text = table.concat(vim.api.nvim_buf_get_lines(editor.bufnr, 0, -1, false), "\n")
  if not session.closed then
    session:set_instruction(text)
  end
  M.close()
  if opts.submit and not session.closed then
    vim.schedule(function()
      if not session.closed then
        session:stage({ submit = true, wait = true })
      end
    end)
  end
end

local function update_placeholder(editor)
  if not valid(editor) then
    return
  end
  vim.api.nvim_buf_clear_namespace(editor.bufnr, namespace, 0, -1)
  local text = table.concat(vim.api.nvim_buf_get_lines(editor.bufnr, 0, -1, false), "\n")
  if text:match("^%s*$") then
    vim.api.nvim_buf_set_extmark(editor.bufnr, namespace, 0, 0, {
      virt_text = { { "Tell the agent what you want to change, explain, or investigate…", "Comment" } },
      virt_text_pos = "overlay",
    })
  end
end

function M.open(session)
  M.close()
  local width = math.min(math.max(50, math.floor(vim.o.columns * 0.6)), math.max(1, vim.o.columns - 6))
  local height = math.min(10, math.max(3, vim.o.lines - 6))
  local bufnr = vim.api.nvim_create_buf(false, true)
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    title = " Message to agent ",
    title_pos = "center",
    footer = " <C-s> keep · <C-Enter> send · q cancel ",
    footer_pos = "center",
  })
  local editor = {
    session = session,
    bufnr = bufnr,
    winid = winid,
    return_winid = vim.fn.win_getid(vim.fn.winnr("#")),
  }
  active = editor
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  local lines = session.instruction ~= "" and vim.split(session.instruction, "\n", { plain = true }) or { "" }
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].winhighlight = "Normal:NormalFloat,FloatBorder:DiagnosticInfo,FloatTitle:Title,FloatFooter:Comment"

  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.cmd("stopinsert")
    M.save()
  end, { buffer = bufnr, silent = true, desc = "Keep Herdr message" })
  for _, key in ipairs({ "<C-CR>", "<M-CR>" }) do
    vim.keymap.set({ "n", "i" }, key, function()
      vim.cmd("stopinsert")
      M.save({ submit = true })
    end, { buffer = bufnr, silent = true, desc = "Send Herdr message with context" })
  end
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Cancel Herdr message" })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = bufnr,
    callback = function()
      update_placeholder(editor)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      if active == editor then
        active = nil
      end
    end,
  })
  update_placeholder(editor)
  vim.cmd("startinsert")
  return bufnr
end

function M._active()
  return active
end

return M
