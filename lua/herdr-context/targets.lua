local M = {}

local context = require("herdr-context.context")
local herdr = require("herdr-context.herdr")
local state = require("herdr-context.state")

local selected

local function normalize(path)
  if not path or path == "" then
    return nil
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("/+$", "")
end

local function same_project(agent_cwd, current_root, current_cwd)
  agent_cwd = normalize(agent_cwd)
  current_root = normalize(current_root)
  current_cwd = normalize(current_cwd)
  if not agent_cwd then
    return false
  end
  if current_cwd and agent_cwd == current_cwd then
    return true
  end
  local agent_root = context.find_git_root(agent_cwd)
  return agent_root and current_root and normalize(agent_root) == current_root
end

local status_rank = {
  idle = 1,
  blocked = 2,
  working = 3,
  unknown = 4,
}

local function scope_allows(agent, scope, current)
  if scope == "tab" then
    return current.tab_id and agent.tab_id == current.tab_id
  elseif scope == "workspace" then
    return current.workspace_id and agent.workspace_id == current.workspace_id
  end
  return true
end

local function rank(agent, current)
  if current.tab_id and agent.tab_id == current.tab_id then
    return 1
  elseif current.workspace_id and agent.workspace_id == current.workspace_id then
    return 2
  elseif same_project(agent.foreground_cwd or agent.cwd, current.git_root, current.cwd) then
    return 3
  end
  return 4
end

local function labels_by_id(records, id_key)
  local labels = {}
  for _, item in ipairs(records or {}) do
    labels[item[id_key]] = item.label
  end
  return labels
end

function M.candidates(snapshot, opts)
  opts = opts or {}
  local current = {
    pane_id = opts.pane_id or vim.env.HERDR_PANE_ID,
    tab_id = opts.tab_id or vim.env.HERDR_TAB_ID or snapshot.focused_tab_id,
    workspace_id = opts.workspace_id or vim.env.HERDR_WORKSPACE_ID or snapshot.focused_workspace_id,
    cwd = opts.cwd or (vim.uv or vim.loop).cwd() or vim.fn.getcwd(),
  }
  current.git_root = opts.git_root or context.find_git_root(current.cwd)

  local workspace_labels = labels_by_id(snapshot.workspaces, "workspace_id")
  local tab_labels = labels_by_id(snapshot.tabs, "tab_id")
  local candidates = {}
  for _, source in ipairs(snapshot.agents or {}) do
    if
      source.pane_id
      and source.pane_id ~= current.pane_id
      and scope_allows(source, opts.scope or "workspace", current)
    then
      local agent = vim.deepcopy(source)
      agent.rank = rank(agent, current)
      agent.workspace_label = workspace_labels[agent.workspace_id] or agent.workspace_id or "?"
      agent.tab_label = tab_labels[agent.tab_id] or agent.tab_id or "?"
      candidates[#candidates + 1] = agent
    end
  end

  table.sort(candidates, function(a, b)
    if a.rank ~= b.rank then
      return a.rank < b.rank
    end
    local a_status = status_rank[a.agent_status] or 99
    local b_status = status_rank[b.agent_status] or 99
    if a_status ~= b_status then
      return a_status < b_status
    end
    if (a.agent or "") ~= (b.agent or "") then
      return (a.agent or "") < (b.agent or "")
    end
    return a.pane_id < b.pane_id
  end)

  return candidates
end

local function config_file()
  if vim.env.HERDR_CONTEXT_CONFIG and vim.env.HERDR_CONTEXT_CONFIG ~= "" then
    return vim.fs.normalize(vim.fn.expand(vim.env.HERDR_CONTEXT_CONFIG))
  end

  local config_root
  if vim.env.HERDR_CONFIG_PATH and vim.env.HERDR_CONFIG_PATH ~= "" then
    config_root = vim.fs.dirname(vim.fn.expand(vim.env.HERDR_CONFIG_PATH))
  else
    config_root = vim.fn.expand("~/.config/herdr")
  end
  return vim.fs.joinpath(config_root, "plugins", "config", "herdr-context", "targets")
end

local function read_pinned(workspace_id)
  if not workspace_id then
    return nil
  end
  local path = config_file()
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  for _, line in ipairs(vim.fn.readfile(path)) do
    local workspace, pane = line:match("^([^\t]+)\t([^\t]+)$")
    if workspace == workspace_id then
      return pane
    end
  end
end

local function write_pinned(workspace_id, pane_id)
  if not workspace_id then
    return nil, "HERDR_WORKSPACE_ID is unavailable; cannot remember a workspace target"
  end

  local path = config_file()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local lines = {}
  if vim.fn.filereadable(path) == 1 then
    for _, line in ipairs(vim.fn.readfile(path)) do
      local workspace = line:match("^([^\t]+)\t")
      if workspace and workspace ~= workspace_id then
        lines[#lines + 1] = line
      end
    end
  end
  lines[#lines + 1] = workspace_id .. "\t" .. pane_id
  local ok, err = pcall(vim.fn.writefile, lines, path)
  if not ok then
    return nil, "Could not save target: " .. tostring(err)
  end
  return true
end

local function find(candidates, pane_id)
  if not pane_id then
    return nil
  end
  for _, candidate in ipairs(candidates) do
    if candidate.pane_id == pane_id then
      return candidate
    end
  end
end

function M.selected()
  return selected
end

function M.clear()
  selected = nil
  state.set_target(nil)
end

function M.remember(config, target)
  if config.remember_target == "none" then
    selected = nil
  else
    selected = target
  end
  state.set_target(target.pane_id)
  if config.remember_target == "workspace" then
    return write_pinned(vim.env.HERDR_WORKSPACE_ID, target.pane_id)
  end
  return true
end

function M.refresh(config, callback)
  return herdr.snapshot(config, function(snapshot, err)
    if not snapshot then
      callback(nil, err)
      return
    end
    callback(M.candidates(snapshot, { scope = config.target_scope }), nil, snapshot)
  end)
end

function M.resolve(config, picker, opts, callback)
  opts = opts or {}
  return M.refresh(config, function(candidates, err)
    if not candidates then
      callback(nil, err)
      return
    end
    if #candidates == 0 then
      selected = nil
      state.set_target(nil)
      callback(nil, ("No live Herdr agents found in target scope %q"):format(config.target_scope))
      return
    end

    if not opts.force then
      local remembered = find(candidates, selected and selected.pane_id)
      if remembered then
        selected = remembered
        state.set_target(remembered.pane_id)
        callback(remembered)
        return
      elseif selected then
        selected = nil
        state.set_target(nil)
      end

      local pinned = find(candidates, read_pinned(vim.env.HERDR_WORKSPACE_ID))
      if pinned then
        selected = pinned
        state.set_target(pinned.pane_id)
        callback(pinned)
        return
      end

      if #candidates == 1 and config.auto_select then
        M.remember(config, candidates[1])
        callback(candidates[1])
        return
      end
    end

    picker.select(candidates, function(choice)
      if not choice then
        callback(nil, "Target selection cancelled")
        return
      end
      local ok, remember_err = M.remember(config, choice)
      if not ok then
        callback(nil, remember_err)
        return
      end
      callback(choice)
    end)
  end)
end

M.config_file = config_file

return M
