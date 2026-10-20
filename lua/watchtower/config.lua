local M = {}

---@class WatchtowerOpenFileConfig
---@field mode "split"|"replace" "split" opens the file next to the diff window, "replace" opens it in the diff window
---@field direction "away"|"above"|"below" "away" splits vertically on the side of the diff away from the tree
---@field reuse_window boolean Reuse the window from the previous open instead of splitting again

---@class WatchtowerConfig
M.defaults = {
  -- Open the view when nvim starts with no file arguments inside a git repo
  open_on_startup = false,
  -- Open the view the first time a file from a git repo is opened after startup (e.g. picked
  -- from the dashboard, a project switch, or a restored session). Re-armed by :cd.
  open_on_file = false,
  -- Keep the diff window directly next to the tree, moving it back if other windows displace it
  pin_diff = true,
  -- Ref the working tree is compared against
  base = "HEAD",
  tree = {
    -- Screen edge the tree sits on; the diff window is kept next to it
    position = "left",
    width = 35,
    -- Directories start expanded
    expanded = true,
    icons = true,
  },
  ---@type WatchtowerOpenFileConfig
  open_file = {
    mode = "split",
    direction = "away",
    reuse_window = true,
  },
  watch = {
    enabled = true,
    -- How often git status is polled while the view is open
    interval_ms = 1000,
  },
  -- Report the tree/diff cursor to claudecode.nvim as the real file + line
  claudecode = true,
  keymaps = {
    tree = {
      select = "<CR>",
      open_file = "o",
      focus_diff = "l",
      collapse = "h",
      refresh = "R",
      close = "q",
    },
    diff = {
      open_file = "<CR>",
      next_hunk = "]c",
      prev_hunk = "[c",
      next_file = "]f",
      prev_file = "[f",
      focus_tree = "<BS>",
      close = "q",
    },
  },
}

---@type WatchtowerConfig
M.options = vim.deepcopy(M.defaults)

function M.tree_on_right()
  return M.options.tree.position == "right"
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
