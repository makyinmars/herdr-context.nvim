local M = {}

M.icons = {
  idle = "●",
  working = "◉",
  blocked = "!",
  done = "✓",
  unknown = "○",
}

M.highlights = {
  idle = "HerdrContextIdle",
  working = "HerdrContextWorking",
  blocked = "HerdrContextBlocked",
  done = "HerdrContextDone",
  unknown = "HerdrContextUnknown",
}

function M.setup_highlights()
  for name, link in pairs({
    HerdrContextIdle = "DiagnosticOk",
    HerdrContextDone = "DiagnosticOk",
    HerdrContextWorking = "DiagnosticInfo",
    HerdrContextBlocked = "DiagnosticError",
    HerdrContextUnknown = "Comment",
    HerdrContextTarget = "Special",
    HerdrContextDisconnected = "DiagnosticWarn",
    HerdrContextComposerHeader = "Title",
    HerdrContextComposerStale = "DiagnosticWarn",
    HerdrContextComposerError = "DiagnosticError",
    HerdrContextComposerSize = "Comment",
    HerdrContextComposerFooter = "Comment",
    HerdrContextComposerLabel = "Comment",
    HerdrContextComposerInstruction = "Special",
  }) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
end

function M.status_icon(status)
  return M.icons[status or "unknown"] or M.icons.unknown
end

function M.status_label(agent)
  local status = agent.agent_status or "unknown"
  local labels = type(agent.state_labels) == "table" and agent.state_labels or nil
  return (labels and labels[status]) or status
end

function M.kind(agent)
  return agent.display_agent or agent.agent or "agent"
end

function M.compact(agent, opts)
  opts = opts or {}
  local status = agent.agent_status or "unknown"
  local name = agent.name or agent.workspace_label or agent.pane_id or "?"
  return table.concat({
    opts.selected and "▶" or " ",
    M.status_icon(status),
    M.kind(agent),
    M.status_label(agent),
    name,
  }, " ")
end

function M.picker_item(agent)
  local cwd = agent.foreground_cwd or agent.cwd
  if not cwd or cwd == "" then
    cwd = "?"
  else
    cwd = vim.fn.fnamemodify(cwd, ":~")
  end
  return ("%s %-8s %-8s %s / %s   %s   %s"):format(
    M.status_icon(agent.agent_status),
    M.status_label(agent),
    M.kind(agent),
    agent.workspace_label or agent.workspace_id or "?",
    agent.tab_label or agent.tab_id or "?",
    cwd,
    agent.pane_id
  )
end

return M
