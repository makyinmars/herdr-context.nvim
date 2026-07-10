local M = {}

local util = require("herdr-context.providers.util")

function M.parse_hunks(output)
  local hunks, current = {}, nil
  for _, line in ipairs(vim.split(output or "", "\n", { plain = true })) do
    local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if old_start then
      current = {
        old_start = tonumber(old_start),
        old_count = old_count == "" and 1 or tonumber(old_count),
        new_start = tonumber(new_start),
        new_count = new_count == "" and 1 or tonumber(new_count),
        lines = { line },
      }
      hunks[#hunks + 1] = current
    elseif current and not line:match("^diff %-%-git ") and not line:match("^@@ ") then
      current.lines[#current.lines + 1] = line
    end
  end
  for _, hunk in ipairs(hunks) do
    while hunk.lines[#hunk.lines] == "" do
      table.remove(hunk.lines)
    end
  end
  return hunks
end

function M.find_hunk(hunks, cursor_line)
  for _, hunk in ipairs(hunks) do
    local first = math.max(hunk.new_start, 1)
    local last = hunk.new_count == 0 and first or hunk.new_start + hunk.new_count - 1
    if cursor_line >= first and cursor_line <= last then
      return hunk, first, last
    end
  end
end

function M.collect(request, context_lines, callback)
  if request.modified then
    callback(nil, {
      kind = "unavailable",
      message = "Unsaved changes require MiniDiff; save the buffer to use the Git fallback",
    })
    return
  end
  if not request.path or not request.git_root or not request.relative_path then
    callback(nil, { kind = "unavailable", message = "The Git fallback requires a named file in a Git repository" })
    return
  end
  if vim.fn.executable("git") ~= 1 then
    callback(nil, { kind = "unavailable", message = "Git is not executable" })
    return
  end

  local process
  local ok, process_or_err = pcall(vim.system, {
    "git",
    "-C",
    request.git_root,
    "diff",
    "--no-ext-diff",
    "--unified=" .. tostring(context_lines),
    "--",
    request.relative_path,
  }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local detail = result.stderr ~= "" and result.stderr or result.stdout
        callback(nil, "Git diff failed: " .. util.clean_message(detail))
        return
      end
      local hunk, first, last = M.find_hunk(M.parse_hunks(result.stdout), request.cursor[1])
      if not hunk then
        callback(nil, { kind = "unavailable", message = "No saved Git hunk at the cursor" })
        return
      end
      local additions, deletions = 0, 0
      for _, line in ipairs(hunk.lines) do
        additions = additions + (line:sub(1, 1) == "+" and 1 or 0)
        deletions = deletions + (line:sub(1, 1) == "-" and 1 or 0)
      end
      callback({
        id = "hunk",
        title = "Current Git hunk",
        summary = ("change +%d/-%d %s"):format(additions, deletions, util.range_summary(nil, first, last)),
        priority = 25,
        reference = util.reference(request, first, last),
        content = table.concat(hunk.lines, "\n"),
        format = "diff",
        range = { start_line = first, end_line = last },
        backend = "git",
        fingerprint = table.concat({ "hunk", request.path, first, last, request.changedtick }, ":"),
      })
    end)
  end)
  if not ok then
    callback(nil, "Could not start Git: " .. tostring(process_or_err))
    return
  end
  process = process_or_err
  return function()
    if process then
      pcall(process.kill, process, 15)
    end
  end
end

return M
