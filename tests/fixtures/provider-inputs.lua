return {
  lsp = {
    document_symbols = {
      {
        name = "outer",
        kind = 12,
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 5, character = 0 } },
        children = {
          {
            name = "inner-z",
            kind = 12,
            range = { start = { line = 1, character = 0 }, ["end"] = { line = 4, character = 0 } },
          },
        },
      },
    },
    symbol_information = {
      {
        name = "inner-a",
        kind = 12,
        location = {
          uri = "file:///project/src/symbol.lua",
          range = { start = { line = 1, character = 0 }, ["end"] = { line = 4, character = 0 } },
        },
      },
    },
  },
  mini_diff = {
    change = { ref_start = 2, ref_count = 1, buf_start = 2, buf_count = 1, type = "change" },
    add = { ref_start = 1, ref_count = 0, buf_start = 2, buf_count = 1, type = "add" },
    delete = { ref_start = 2, ref_count = 1, buf_start = 1, buf_count = 0, type = "delete" },
  },
  trouble = {
    {
      filename = "src/trouble.lua",
      pos = { 8, 3 },
      severity = vim.diagnostic.severity.ERROR,
      message = "Fixture failure",
      source = "diagnostics",
    },
  },
}
