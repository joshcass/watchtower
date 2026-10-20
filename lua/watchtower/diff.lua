local config = require("watchtower.config")
local state = require("watchtower.state")

local M = {}

local ns = vim.api.nvim_create_namespace("watchtower_diff")

-- Number of buffer lines above the first diff line
M.HEADER_LINES = 1

local kind_hl = {
  add = "WatchtowerDiffAdd",
  del = "WatchtowerDiffDelete",
  hunk = "WatchtowerDiffHunk",
  meta = "Comment",
}

---@return WatchtowerDiffLine|nil
function M.line_info(lnum)
  if lnum <= M.HEADER_LINES then
    -- The header points at the first change
    for _, info in ipairs(state.diff_lines) do
      if info.kind ~= "hunk" and info.kind ~= "ctx" then
        return info
      end
    end
    return state.diff_lines[1]
  end
  return state.diff_lines[lnum - M.HEADER_LINES]
end

---@param file WatchtowerFile|nil
---@param lines WatchtowerDiffLine[]|nil
---@param message string|nil shown instead of the diff
function M.render(file, lines, message)
  local buf = state.diff_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local same_file = state.selected and file and vim.b[buf].watchtower_path == file.path

  state.diff_lines = lines or {}
  vim.b[buf].watchtower_path = file and file.path or nil

  local text = {}
  if file then
    local header = " " .. file.status .. "  " .. file.path
    if file.old_path then
      header = header .. "  (from " .. file.old_path .. ")"
    end
    table.insert(text, header)
  else
    table.insert(text, "")
  end
  if message then
    table.insert(text, "  " .. message)
  end
  for _, info in ipairs(state.diff_lines) do
    table.insert(text, info.text)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { line_hl_group = "WatchtowerHeader" })
  if message then
    vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { line_hl_group = "Comment" })
  end
  for i, info in ipairs(state.diff_lines) do
    local hl = kind_hl[info.kind]
    if hl then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1 + M.HEADER_LINES, 0, { line_hl_group = hl })
    end
  end

  if state.win_valid(state.diff_win) and vim.api.nvim_win_get_buf(state.diff_win) == buf then
    local lnum = 1
    if same_file then
      lnum = math.min(vim.api.nvim_win_get_cursor(state.diff_win)[1], #text)
    end
    vim.api.nvim_win_set_cursor(state.diff_win, { lnum, 0 })
  end
end

---Moves the cursor to the next (dir = 1) or previous (dir = -1) hunk.
function M.jump_hunk(dir)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local count = vim.api.nvim_buf_line_count(0)
  local i = lnum + dir
  while i >= 1 and i <= count do
    local info = M.line_info(i)
    if i > M.HEADER_LINES and info and info.kind == "hunk" then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      vim.cmd("normal! zt")
      return
    end
    i = i + dir
  end
end

local split_mods = {
  above = "leftabove",
  below = "rightbelow",
}

---Opens the file backing the diff line under the cursor.
function M.open_at_cursor()
  local file = state.selected
  if not file then
    return
  end
  if file.status == "D" then
    vim.notify("watchtower: " .. file.path .. " was deleted", vim.log.levels.WARN)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local info = M.line_info(cursor[1])
  local lnum = info and info.new or 1
  local col = 0
  if info and cursor[1] > M.HEADER_LINES and (info.kind == "add" or info.kind == "ctx") then
    -- Skip the +/space prefix so the cursor lands on the same character
    col = math.max(cursor[2] - 1, 0)
  end

  M.open_file(state.abs_path(file), lnum, col)
end

---@param path string absolute path
function M.open_file(path, lnum, col)
  local opts = config.options.open_file
  local target

  if opts.mode == "replace" then
    target = state.diff_win
  elseif opts.reuse_window and state.win_valid(state.file_win) and state.file_win ~= state.diff_win then
    target = state.file_win
  end

  local escaped = vim.fn.fnameescape(path)
  if target and state.win_valid(target) then
    vim.api.nvim_set_current_win(target)
    vim.cmd("edit " .. escaped)
  else
    local mods = split_mods[opts.direction]
      or (config.tree_on_right() and "leftabove vertical" or "rightbelow vertical")
    if state.win_valid(state.diff_win) then
      vim.api.nvim_set_current_win(state.diff_win)
    end
    vim.cmd(mods .. " split " .. escaped)
  end

  local win = vim.api.nvim_get_current_win()
  if opts.mode ~= "replace" then
    state.file_win = win
  end

  local line_count = vim.api.nvim_buf_line_count(0)
  pcall(vim.api.nvim_win_set_cursor, win, { math.min(lnum, line_count), col })
  vim.cmd("normal! zz")
end

return M
