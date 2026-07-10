local context = require("herdr-context.context")

local M = {
  id = "diagnostics",
  name = "Diagnostics",
  priority = 30,
}

local function summary(items)
  local counts = { errors = 0, warnings = 0, infos = 0, hints = 0 }
  for _, item in ipairs(items) do
    if item.severity == vim.diagnostic.severity.ERROR then
      counts.errors = counts.errors + 1
    elseif item.severity == vim.diagnostic.severity.WARN then
      counts.warnings = counts.warnings + 1
    elseif item.severity == vim.diagnostic.severity.INFO then
      counts.infos = counts.infos + 1
    else
      counts.hints = counts.hints + 1
    end
  end

  local parts = {}
  for _, spec in ipairs({
    { "errors", "error" },
    { "warnings", "warning" },
    { "infos", "info" },
    { "hints", "hint" },
  }) do
    local count = counts[spec[1]]
    if count > 0 then
      parts[#parts + 1] = ("%d %s%s"):format(count, spec[2], count == 1 and "" or "s")
    end
  end
  return #parts > 0 and table.concat(parts, ", ") or "No diagnostics"
end

function M.section_for_range(request, range)
  range = range or { start_line = request.cursor[1], end_line = request.cursor[1] }
  local captured = {
    bufnr = request.bufnr,
    start_line = range.start_line,
    end_line = range.end_line,
  }
  local items = context.diagnostics(captured)
  return {
    id = "diagnostics",
    title = "Diagnostics",
    summary = summary(items),
    priority = 30,
    format = "diagnostics",
    content = "",
    items = items,
    range = vim.deepcopy(range),
    fingerprint = table.concat({
      "diagnostics",
      request.path or "[unnamed]",
      range.start_line,
      range.end_line,
      request.changedtick,
    }, ":"),
  }
end

function M.collect(request, callback)
  local range
  if request.selection then
    range = {
      start_line = request.capture.start_line,
      end_line = request.capture.end_line,
    }
  end
  callback(M.section_for_range(request, range))
end

return M
