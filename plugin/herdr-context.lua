if vim.g.loaded_herdr_context then
  return
end
vim.g.loaded_herdr_context = true

local function command_opts(args)
  if args.range and args.range > 0 then
    return { line1 = args.line1, line2 = args.line2 }
  end
end

vim.api.nvim_create_user_command("HerdrContextReference", function(args)
  require("herdr-context").reference(command_opts(args))
end, { desc = "Stage a code reference in a Herdr agent prompt", range = true })

vim.api.nvim_create_user_command("HerdrContextSend", function(args)
  require("herdr-context").send(command_opts(args))
end, { desc = "Stage a code reference and selected content in a Herdr agent prompt", range = true })

vim.api.nvim_create_user_command("HerdrContextDiagnostics", function(args)
  require("herdr-context").diagnostics(command_opts(args))
end, { desc = "Stage diagnostics for a line or range in a Herdr agent prompt", range = true })

vim.api.nvim_create_user_command("HerdrContextCompose", function(args)
  require("herdr-context").compose(command_opts(args))
end, { desc = "Compose and preview context for a Herdr agent", range = true })

vim.api.nvim_create_user_command("HerdrContextSymbol", function()
  require("herdr-context").symbol()
end, { desc = "Stage the current symbol in a Herdr agent prompt" })

vim.api.nvim_create_user_command("HerdrContextHunk", function()
  require("herdr-context").hunk()
end, { desc = "Stage the Git hunk under the cursor in a Herdr agent prompt" })

vim.api.nvim_create_user_command("HerdrContextQuickfix", function()
  require("herdr-context").quickfix()
end, { desc = "Stage the current quickfix list in a Herdr agent prompt" })

vim.api.nvim_create_user_command("HerdrContextTarget", function()
  require("herdr-context").select_target()
end, { desc = "Select the destination Herdr agent" })

vim.api.nvim_create_user_command("HerdrContextAgents", function()
  require("herdr-context").agents()
end, { desc = "Toggle the live Herdr agent drawer" })

vim.api.nvim_create_user_command("HerdrContextRefresh", function()
  require("herdr-context").refresh()
end, { desc = "Force a refresh of live Herdr state" })
