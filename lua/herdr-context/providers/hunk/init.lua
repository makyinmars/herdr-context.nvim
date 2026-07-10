local config = require("herdr-context.config")
local git = require("herdr-context.providers.hunk.git")
local mini_diff = require("herdr-context.providers.hunk.mini_diff")

local M = {
  id = "hunk",
  name = "Current Git hunk",
  priority = 25,
}

function M.available(request)
  local cfg = config.get().providers.hunk
  if not cfg.enabled then
    return false, "Disabled by providers.hunk.enabled"
  end
  if not vim.api.nvim_buf_is_valid(request.bufnr) then
    return false, "Source buffer is no longer valid"
  end
  if request.modified and not mini_diff.available() then
    return false, "Unsaved changes require MiniDiff; save the buffer to use the Git fallback"
  end
  if not request.path and not mini_diff.available() then
    return false, "A named Git buffer or active MiniDiff source is required"
  end
  return true
end

function M.collect(request, callback)
  local options = config.get()
  local backends = options.providers.hunk.backends
  local index = 0
  local active_cancel
  local errors = {}
  local cancelled = false

  local function next_backend()
    if cancelled then
      return
    end
    index = index + 1
    local backend = backends[index]
    if not backend then
      callback(nil, errors[#errors] or { kind = "unavailable", message = "No hunk backend is configured" })
      return
    end
    local implementation = backend == "mini_diff" and mini_diff or git
    active_cancel = implementation.collect(request, options.composer.hunk_context_lines, function(section, err)
      if cancelled then
        return
      end
      if section then
        callback(section)
        return
      end
      errors[#errors + 1] = err
      next_backend()
    end)
  end

  next_backend()
  return function()
    cancelled = true
    if active_cancel then
      active_cancel()
    end
  end
end

return M
