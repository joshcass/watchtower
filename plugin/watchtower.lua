if vim.g.loaded_watchtower then
  return
end
vim.g.loaded_watchtower = true

vim.api.nvim_create_user_command("Watchtower", function(args)
  local watchtower = require("watchtower")
  local action = args.fargs[1] or "toggle"
  if action == "open" then
    watchtower.open()
  elseif action == "close" then
    watchtower.close()
  elseif action == "refresh" then
    watchtower.refresh()
  else
    watchtower.toggle()
  end
end, {
  nargs = "?",
  complete = function()
    return { "open", "close", "toggle", "refresh" }
  end,
  desc = "Watchtower git diff view",
})
