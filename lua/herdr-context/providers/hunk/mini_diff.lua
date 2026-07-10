local M = {}

local util = require("herdr-context.providers.util")

local function module()
  local mini = package.loaded["mini.diff"] or _G.MiniDiff
  if type(mini) == "table" and type(mini.get_buf_data) == "function" then
    return mini
  end
end

function M.available()
  return module() ~= nil
end

local function hunk_range(hunk)
  if hunk.buf_count > 0 then
    return hunk.buf_start, hunk.buf_start + hunk.buf_count - 1
  end
  local anchor = math.max(hunk.buf_start, 1)
  return anchor, anchor
end

function M.find_hunk(hunks, cursor_line)
  for _, hunk in ipairs(hunks or {}) do
    local first, last = hunk_range(hunk)
    if cursor_line >= first and cursor_line <= last then
      return hunk
    end
  end
end

local function split_reference(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if text and text:sub(-1) == "\n" and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

local function header_start(anchor, count, before, after)
  local total = before + count + after
  if total == 0 then
    return math.max(anchor, 0), total
  end
  if count == 0 then
    return math.max(anchor - before + 1, 1), total
  end
  return math.max(anchor - before, 1), total
end

function M.render(request, data, hunk, context_lines)
  local ref_lines = split_reference(data.ref_text)
  local buf_lines = vim.api.nvim_buf_get_lines(request.bufnr, 0, -1, false)
  local ref_before_end = hunk.ref_count == 0 and hunk.ref_start or hunk.ref_start - 1
  local buf_before_end = hunk.buf_count == 0 and hunk.buf_start or hunk.buf_start - 1
  local before = math.min(context_lines, ref_before_end, buf_before_end)
  local ref_after_start = hunk.ref_start + math.max(hunk.ref_count, 1)
  local buf_after_start = hunk.buf_start + math.max(hunk.buf_count, 1)
  local after = math.min(
    context_lines,
    math.max(#ref_lines - ref_after_start + 1, 0),
    math.max(#buf_lines - buf_after_start + 1, 0)
  )
  local old_start, old_count = header_start(hunk.ref_start, hunk.ref_count, before, after)
  local new_start, new_count = header_start(hunk.buf_start, hunk.buf_count, before, after)
  local lines = { ("@@ -%d,%d +%d,%d @@"):format(old_start, old_count, new_start, new_count) }

  for line = buf_before_end - before + 1, buf_before_end do
    lines[#lines + 1] = " " .. (buf_lines[line] or "")
  end
  for line = hunk.ref_start, hunk.ref_start + hunk.ref_count - 1 do
    lines[#lines + 1] = "-" .. (ref_lines[line] or "")
  end
  for line = hunk.buf_start, hunk.buf_start + hunk.buf_count - 1 do
    lines[#lines + 1] = "+" .. (buf_lines[line] or "")
  end
  for line = buf_after_start, buf_after_start + after - 1 do
    lines[#lines + 1] = " " .. (buf_lines[line] or "")
  end
  return table.concat(lines, "\n")
end

function M.collect(request, context_lines, callback)
  local mini = module()
  if not mini then
    callback(nil, { kind = "unavailable", message = "MiniDiff is not loaded" })
    return
  end
  local ok, data = pcall(mini.get_buf_data, request.bufnr)
  if not ok then
    callback(nil, "MiniDiff.get_buf_data() failed: " .. tostring(data))
    return
  end
  if not data or not data.ref_text then
    callback(nil, { kind = "unavailable", message = "MiniDiff has no reference text for this buffer" })
    return
  end
  local hunk = M.find_hunk(data.hunks, request.cursor[1])
  if not hunk then
    callback(nil, { kind = "unavailable", message = "No MiniDiff hunk at the cursor" })
    return
  end

  local first, last = hunk_range(hunk)
  callback({
    id = "hunk",
    title = "Current Git hunk",
    summary = ("%s +%d/-%d %s"):format(
      hunk.type or "change",
      hunk.buf_count,
      hunk.ref_count,
      util.range_summary(nil, first, last)
    ),
    priority = 25,
    reference = util.reference(request, first, last),
    content = M.render(request, data, hunk, context_lines),
    format = "diff",
    modified = request.modified,
    range = { start_line = first, end_line = last },
    backend = "mini_diff",
    fingerprint = table.concat({ "hunk", request.path or "[unnamed]", first, last, request.changedtick }, ":"),
  })
end

return M
