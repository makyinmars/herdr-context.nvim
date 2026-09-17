local util = require("herdr-context.providers.util")

local function named_relative(bufnr, request)
  if not bufnr or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return util.relative_path(name, request)
end

local function section_for(id, title, priority, request, bufnr)
  local relative = named_relative(bufnr, request)
  if not relative then
    return nil
  end
  return {
    id = id,
    title = title,
    summary = relative,
    priority = priority,
    reference = util.reference(request, nil, nil, relative),
    language = vim.bo[bufnr].filetype,
    content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"),
    format = "code",
    modified = vim.bo[bufnr].modified,
    fingerprint = table.concat({ id, relative, vim.api.nvim_buf_get_changedtick(bufnr) }, ":"),
  }
end

local function listed_named_bufs()
  local result = {}
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    if info.bufnr and vim.api.nvim_buf_is_valid(info.bufnr) and vim.api.nvim_buf_get_name(info.bufnr) ~= "" then
      result[#result + 1] = info.bufnr
    end
  end
  return result
end

return {
  providers = {
    {
      id = "file",
      name = "Current file",
      priority = 12,
      available = function(request)
        return named_relative(request.bufnr, request) ~= nil
      end,
      collect = function(request, callback)
        local section = section_for("file", "Current file", 12, request, request.bufnr)
        if not section then
          callback(nil, { kind = "unavailable", message = "Current buffer has no stable path" })
          return
        end
        callback(section)
      end,
    },
    {
      id = "alternate",
      name = "Alternate file",
      priority = 13,
      available = function(request)
        local alt = vim.fn.bufnr("#")
        return alt > 0 and alt ~= request.bufnr and named_relative(alt, request) ~= nil
      end,
      collect = function(request, callback)
        local alt = vim.fn.bufnr("#")
        if alt < 1 or alt == request.bufnr then
          callback(nil, { kind = "unavailable", message = "No alternate file" })
          return
        end
        local section = section_for("alternate", "Alternate file", 13, request, alt)
        if not section then
          callback(nil, { kind = "unavailable", message = "Alternate buffer has no stable path" })
          return
        end
        callback(section)
      end,
    },
    {
      id = "buffers",
      name = "Listed buffers",
      priority = 85,
      collect = function(request, callback)
        local alt = vim.fn.bufnr("#")
        local sections = {}
        for _, bufnr in ipairs(listed_named_bufs()) do
          if bufnr ~= request.bufnr and bufnr ~= alt then
            local section = section_for("buffer:" .. tostring(bufnr), "Listed buffer", 85, request, bufnr)
            if section then
              sections[#sections + 1] = section
            end
          end
        end
        if #sections == 0 then
          callback(nil, { kind = "unavailable", message = "No other listed buffers" })
          return
        end
        callback(#sections == 1 and sections[1] or sections)
      end,
    },
  },
}
