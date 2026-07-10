local config = require("herdr-context.config")
local util = require("herdr-context.providers.util")

return {
  id = "selection",
  name = "Current selection",
  priority = 10,

  available = function(request)
    return request.capture ~= nil
  end,

  collect = function(request, callback)
    local captured = request.capture
    local visual = request.selection ~= nil
    local title = visual and "Visual selection" or "Current line"
    local section = {
      id = "selection",
      title = title,
      summary = util.range_summary(nil, captured.start_line, captured.end_line),
      priority = 10,
      reference = util.reference(request, captured.start_line, captured.end_line),
      language = captured.filetype,
      content = captured.text,
      format = "code",
      modified = captured.modified,
      range = { start_line = captured.start_line, end_line = captured.end_line },
      fingerprint = table.concat({
        "selection",
        request.path or "[unnamed]",
        captured.start_line,
        captured.end_line,
        request.changedtick,
      }, ":"),
    }
    if #section.content > config.get().max_payload_bytes then
      section.oversized = true
    end
    callback(section)
  end,
}
