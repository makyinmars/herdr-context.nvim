local config = require("herdr-context.config")
local util = require("herdr-context.providers.util")

local M = {
  id = "symbol",
  name = "Current symbol",
  priority = 20,
}

local function contains(range, cursor)
  if not range or not range.start or not range["end"] then
    return false
  end
  local row, col = cursor[1] - 1, cursor[2]
  local start, finish = range.start, range["end"]
  if row < start.line or row > finish.line then
    return false
  end
  if row == start.line and col < (start.character or 0) then
    return false
  end
  if row == finish.line and col >= (finish.character or 0) then
    return false
  end
  return true
end

local function range_size(range)
  return (range["end"].line - range.start.line) * 1000000 + (range["end"].character or 0) - (range.start.character or 0)
end

local function add_lsp_symbols(result, client, cursor, candidates)
  local function visit(symbols)
    for _, symbol in ipairs(symbols or {}) do
      local range = symbol.range or (symbol.location and symbol.location.range)
      if contains(range, cursor) then
        candidates[#candidates + 1] = {
          name = symbol.name or "symbol",
          kind = symbol.kind,
          range = range,
          client_id = client.id or 0,
          client_name = client.name or "",
        }
      end
      visit(symbol.children)
    end
  end
  visit(result)
end

local function end_line(range)
  if range["end"].line > range.start.line and (range["end"].character or 0) == 0 then
    return range["end"].line
  end
  return range["end"].line + 1
end

local function section_from_range(request, candidate, backend)
  local start_line = candidate.range.start.line + 1
  local finish_line = math.max(start_line, end_line(candidate.range))
  local content = util.range_content(request.bufnr, start_line, finish_line)
  return {
    id = "symbol",
    title = "Current symbol",
    summary = util.range_summary(candidate.name, start_line, finish_line),
    priority = 20,
    reference = util.reference(request, start_line, finish_line),
    language = request.filetype,
    content = content,
    format = "code",
    modified = request.modified,
    range = { start_line = start_line, end_line = finish_line },
    symbol_name = candidate.name,
    backend = backend,
    fingerprint = table.concat(
      { "symbol", request.path or "[unnamed]", start_line, finish_line, request.changedtick },
      ":"
    ),
  }
end

local function sort_candidates(candidates)
  table.sort(candidates, function(a, b)
    local a_size, b_size = range_size(a.range), range_size(b.range)
    if a_size ~= b_size then
      return a_size < b_size
    end
    if (a.client_name or "") ~= (b.client_name or "") then
      return (a.client_name or "") < (b.client_name or "")
    end
    if (a.client_id or 0) ~= (b.client_id or 0) then
      return (a.client_id or 0) < (b.client_id or 0)
    end
    return (a.name or "") < (b.name or "")
  end)
end

local symbol_node_patterns = {
  "function",
  "method",
  "class",
  "type_definition",
  "type_declaration",
  "interface",
  "struct",
  "enum",
  "trait",
  "impl_item",
}

local function recognized_node(node)
  local node_type = node:type()
  for _, pattern in ipairs(symbol_node_patterns) do
    if node_type:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function treesitter_candidates(request)
  local ok, parser = pcall(vim.treesitter.get_parser, request.bufnr)
  if not ok or not parser then
    return {}
  end
  local trees = parser:parse()
  if not trees or not trees[1] then
    return {}
  end
  local root = trees[1]:root()
  local cursor_row, cursor_col = request.cursor[1] - 1, request.cursor[2]
  local candidates, seen = {}, {}

  local function add_node(node, name)
    if not node then
      return
    end
    local start_row, start_col, finish_row, finish_col = node:range()
    local range = {
      start = { line = start_row, character = start_col },
      ["end"] = { line = finish_row, character = finish_col },
    }
    local key = table.concat({ start_row, start_col, finish_row, finish_col }, ":")
    if not seen[key] and contains(range, request.cursor) then
      seen[key] = true
      candidates[#candidates + 1] = { name = name or node:type(), range = range }
    end
  end

  local language = parser:lang()
  local query_ok, query = pcall(vim.treesitter.query.get, language, "locals")
  if query_ok and query then
    for id, captured_node in query:iter_captures(root, request.bufnr, 0, -1) do
      local capture = query.captures[id]
      if capture and capture:find("definition", 1, true) then
        local definition = captured_node
        while definition and not recognized_node(definition) do
          definition = definition:parent()
        end
        if definition then
          add_node(definition, definition:type())
        end
      end
    end
  end

  local node = root:named_descendant_for_range(cursor_row, cursor_col, cursor_row, cursor_col)
  while node do
    if recognized_node(node) then
      add_node(node, node:type())
    end
    node = node:parent()
  end
  sort_candidates(candidates)
  return candidates
end

local function collect_treesitter(request, callback, prior_error)
  local cfg = config.get()
  if not cfg.providers.symbol.treesitter_fallback then
    callback(nil, prior_error or { kind = "unavailable", message = "Treesitter symbol fallback is disabled" })
    return
  end
  for _, candidate in ipairs(treesitter_candidates(request)) do
    local section = section_from_range(request, candidate, "treesitter")
    if #section.content <= cfg.max_payload_bytes then
      callback(section)
      return
    end
  end
  callback(nil, prior_error or { kind = "unavailable", message = "No containing LSP or Treesitter symbol" })
end

function M.available(request)
  local cfg = config.get().providers.symbol
  if not cfg.enabled then
    return false, "Disabled by providers.symbol.enabled"
  end
  if not vim.api.nvim_buf_is_valid(request.bufnr) then
    return false, "Source buffer is no longer valid"
  end
  if not cfg.lsp and not cfg.treesitter_fallback then
    return false, "Both symbol backends are disabled"
  end
  return true
end

function M.collect(request, callback)
  local cfg = config.get().providers.symbol
  local cancelled = false
  local pending = 0
  local requests = {}
  local candidates = {}
  local errors = {}

  local function finish_lsp()
    if cancelled or pending > 0 then
      return
    end
    if #candidates > 0 then
      sort_candidates(candidates)
      callback(section_from_range(request, candidates[1], "lsp"))
      return
    end
    collect_treesitter(request, callback, #errors > 0 and errors[1] or nil)
  end

  local clients = {}
  if cfg.lsp then
    if vim.lsp.get_clients then
      clients = vim.lsp.get_clients({ bufnr = request.bufnr })
    else
      clients = vim.lsp.get_active_clients({ bufnr = request.bufnr })
    end
  end
  local eligible = {}
  for _, client in ipairs(clients) do
    local ok, supported = pcall(client.supports_method, client, "textDocument/documentSymbol")
    if ok and supported then
      eligible[#eligible + 1] = client
    end
  end
  table.sort(eligible, function(a, b)
    if (a.name or "") ~= (b.name or "") then
      return (a.name or "") < (b.name or "")
    end
    return (a.id or 0) < (b.id or 0)
  end)

  pending = #eligible
  if pending == 0 then
    collect_treesitter(request, callback)
    return function()
      cancelled = true
    end
  end

  for _, client in ipairs(eligible) do
    local lsp_client = client
    local ok, success, request_id = pcall(lsp_client.request, lsp_client, "textDocument/documentSymbol", {
      textDocument = { uri = vim.uri_from_bufnr(request.bufnr) },
    }, function(err, result)
      if cancelled then
        return
      end
      if err then
        errors[#errors + 1] = tostring(err.message or err)
      else
        add_lsp_symbols(result, lsp_client, request.cursor, candidates)
      end
      pending = pending - 1
      finish_lsp()
    end, request.bufnr)
    if not ok or not success then
      errors[#errors + 1] = "Could not request document symbols from " .. (lsp_client.name or "LSP client")
      pending = pending - 1
    elseif request_id then
      requests[#requests + 1] = { client = lsp_client, id = request_id }
    end
  end
  finish_lsp()

  return function()
    cancelled = true
    for _, item in ipairs(requests) do
      pcall(item.client.cancel_request, item.client, item.id)
    end
  end
end

M._treesitter_candidates = treesitter_candidates

return M
