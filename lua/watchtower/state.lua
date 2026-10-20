---Shared mutable state for the single watchtower view.
local M = {}

function M.reset()
  M.root = nil
  M.git_dir = nil
  M.base = nil -- resolved base ref
  ---@type WatchtowerFile[]
  M.files = {}
  M.files_sig = nil
  M.tab = nil
  M.tree_win = nil
  M.tree_buf = nil
  M.diff_win = nil
  M.diff_buf = nil
  -- Window the last file was opened into, reused by open_file
  M.file_win = nil
  ---@type WatchtowerFile|nil
  M.selected = nil
  ---@type WatchtowerDiffLine[] indexed by diff buffer line
  M.diff_lines = {}
  -- Stat signature of the selected file when its diff was last loaded
  M.diff_sig = nil
  M.collapsed = {}
  -- Repo-relative path to select once the first file list arrives
  M.focus_path = nil
  ---@type table<integer, table> tree buffer line -> entry
  M.tree_entries = {}
end

M.reset()

function M.is_open()
  return M.tab ~= nil and vim.api.nvim_tabpage_is_valid(M.tab)
end

function M.win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

function M.abs_path(file)
  return M.root .. "/" .. file.path
end

return M
