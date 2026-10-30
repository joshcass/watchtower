local config = require("watchtower.config")
local state = require("watchtower.state")
local words = require("watchtower.words")
local syntax = require("watchtower.syntax")

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

local sign_hl = {
  add = "WatchtowerDiffAddSign",
  del = "WatchtowerDiffDeleteSign",
}

local word_hl = {
  add = "WatchtowerDiffAddWord",
  del = "WatchtowerDiffDeleteWord",
}

---Line number shown in the gutter: the old file's line for removals, the new file's otherwise.
local function gutter_number(info)
  if info.kind == "del" then
    return info.old
  elseif info.kind == "add" or info.kind == "ctx" then
    return info.new
  end
end

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
---@param sources? { path: string, new: string|nil } full new file contents for syntax highlighting
function M.render(file, lines, message, sources)
  local buf = state.diff_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local same_file = state.selected and file and vim.b[buf].watchtower_path == file.path

  state.diff_lines = lines or {}
  words.annotate(state.diff_lines)
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
  local gutter_width = 0
  for _, info in ipairs(state.diff_lines) do
    local n = gutter_number(info)
    gutter_width = math.max(gutter_width, n and #tostring(n) or 0)
  end

  local new_spans = sources and sources.new and syntax.spans(sources.path, sources.new)

  local first_row = M.HEADER_LINES + (message and 1 or 0)
  for i, info in ipairs(state.diff_lines) do
    local row = first_row + i - 1
    local hl = kind_hl[info.kind]
    if hl then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = hl })
    end
    if sign_hl[info.kind] then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = 1, hl_group = sign_hl[info.kind] })
    end

    -- Only added lines keep syntax colors. Removed lines are drawn in one flat color, and
    -- unchanged lines are faded unless diff.context = "syntax", so the additions stand out.
    local spans, text_hl
    if info.kind == "del" then
      text_hl = "WatchtowerDiffDeleteText"
    elseif info.kind == "ctx" and config.options.diff.context ~= "syntax" then
      text_hl = "WatchtowerDiffContext"
    elseif info.kind == "add" or info.kind == "ctx" then
      spans = new_spans and new_spans[info.new]
    end
    local text_len = #info.text
    if text_hl and text_len > 1 then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 1, { end_col = text_len, hl_group = text_hl })
    end
    for _, span in ipairs(spans or {}) do
      -- +1 skips the +/-/space marker; clamp in case the file changed after the diff was taken
      local s, e = span[1] + 1, math.min(span[2] + 1, text_len)
      if e > s then
        vim.api.nvim_buf_set_extmark(buf, ns, row, s, { end_col = e, hl_group = span[3], priority = span[4] })
      end
    end
    for _, range in ipairs(info.words or {}) do
      vim.api.nvim_buf_set_extmark(buf, ns, row, range[1], {
        end_col = range[2],
        hl_group = word_hl[info.kind],
        -- Above the line highlight so the stronger word background wins
        priority = 5000,
      })
    end
    if gutter_width > 0 then
      local n = gutter_number(info)
      local label = string.rep(" ", gutter_width - #tostring(n or "")) .. (n and tostring(n) or "") .. " "
      -- Inline virtual text keeps buffer columns unchanged, so cursor/selection mapping still works
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        -- Changed lines number in their sign color; unchanged lines get the dimmed gutter
        virt_text = { { label, { sign_hl[info.kind] or "WatchtowerDiffGutter", hl } } },
        virt_text_pos = "inline",
      })
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

---Whether `win` is an ordinary window in the view's tab outside the tree and diff.
function M.is_away(win)
  return state.win_valid(win)
    and win ~= state.diff_win
    and win ~= state.tree_win
    and vim.api.nvim_win_get_tabpage(win) == state.tab
    and vim.api.nvim_win_get_config(win).relative == ""
end

---Whether files can be opened in `win`: an away window showing an ordinary buffer. Terminals
---(e.g. the Claude Code window) and windows locked to their buffer are left alone. Checked when
---a file is opened, since a terminal window can start out holding a plain buffer.
function M.is_file_win(win)
  if not M.is_away(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == "" and not vim.wo[win].winfixbuf
end

---The usable away window whose buffer was used most recently, for when the remembered one
---cannot take files (e.g. it turned out to be a terminal).
---@return integer|nil
local function fallback_file_win()
  local best, best_used
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
    if M.is_file_win(win) then
      local used = vim.fn.getbufinfo(vim.api.nvim_win_get_buf(win))[1].lastused
      if not best or used > best_used then
        best, best_used = win, used
      end
    end
  end
  return best
end

---Shows `buf` outside the view and focuses it: in the most recently used away window when
---`reuse_window` is on, otherwise in a new split on the far side of the diff from the tree.
---With mode = "replace" it goes in the diff window instead.
---@return integer win
function M.show_away(buf)
  local opts = config.options.open_file
  local win
  local reuse = opts.reuse_window and (M.is_file_win(state.file_win) and state.file_win or fallback_file_win())
  if opts.mode == "replace" and state.win_valid(state.diff_win) then
    win = state.diff_win
    vim.api.nvim_win_set_buf(win, buf)
  elseif reuse then
    win = reuse
    vim.api.nvim_win_set_buf(win, buf)
  else
    local split = (opts.direction == "above" or opts.direction == "below") and opts.direction
      or (config.tree_on_right() and "left" or "right")
    local anchor = state.win_valid(state.diff_win) and state.diff_win or 0
    -- Created with the buffer already in it, so the window never shows a copy of the diff
    win = vim.api.nvim_open_win(buf, false, { split = split, win = anchor })
  end
  vim.api.nvim_set_current_win(win)
  if opts.mode ~= "replace" then
    state.file_win = win
  end
  return win
end

---@param path string absolute path
function M.open_file(path, lnum, col)
  local buf = vim.fn.bufadd(path)
  vim.bo[buf].buflisted = true
  local win = M.show_away(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  pcall(vim.api.nvim_win_set_cursor, win, { math.min(lnum, line_count), col })
  vim.cmd("normal! zz")
end

return M
