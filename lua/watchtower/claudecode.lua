---Bridges the watchtower buffers into claudecode.nvim's selection tracking.
---
---claudecode.nvim reports `nvim_buf_get_name()` and buffer line numbers of the current buffer,
---which for the diff buffer would be "watchtower://diff" and diff line numbers. The selection
---functions are wrapped so that, while a watchtower buffer is current, Claude is told about the
---real file and the line in the working tree file that the diff line corresponds to.
local config = require("watchtower.config")
local state = require("watchtower.state")
local diff = require("watchtower.diff")
local tree = require("watchtower.tree")

local M = {}

local patched = false

---@return "diff"|"tree"|nil
local function current_view()
  if not state.is_open() then
    return nil
  end
  local buf = vim.api.nvim_get_current_buf()
  if buf == state.diff_buf then
    return "diff"
  elseif buf == state.tree_buf then
    return "tree"
  end
end

local function make_selection(path, text, start_line, start_char, end_line, end_char)
  return {
    text = text,
    filePath = path,
    fileUrl = "file://" .. path,
    selection = {
      start = { line = start_line, character = start_char },
      ["end"] = { line = end_line, character = end_char },
      isEmpty = text == "",
    },
  }
end

---Absolute path of the file whose diff is currently rendered.
local function diff_path()
  local rel = state.diff_buf and vim.b[state.diff_buf].watchtower_path
  return rel and (state.root .. "/" .. rel)
end

local function diff_cursor()
  local path = diff_path()
  if not path then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local info = diff.line_info(cursor[1])
  local line = info and info.new or 1
  local char = 0
  if info and cursor[1] > diff.HEADER_LINES and (info.kind == "add" or info.kind == "ctx") then
    char = math.max(cursor[2] - 1, 0)
  end
  return make_selection(path, "", line - 1, char, line - 1, char)
end

---Selection covering diff buffer lines l1..l2. The text is the selected diff lines (with their
---+/- markers); the range is the span of working tree lines they map to.
local function diff_range(l1, l2)
  local path = diff_path()
  if not path then
    return nil
  end
  if l1 > l2 then
    l1, l2 = l2, l1
  end
  local texts = vim.api.nvim_buf_get_lines(state.diff_buf, l1 - 1, l2, false)
  if #texts == 0 then
    return nil
  end
  local first, last
  for lnum = math.max(l1, diff.HEADER_LINES + 1), l2 do
    local info = diff.line_info(lnum)
    if info then
      first = first and math.min(first, info.new) or info.new
      last = last and math.max(last, info.new) or info.new
    end
  end
  if not first then
    local info = diff.line_info(1)
    first = info and info.new or 1
    last = first
  end
  return make_selection(path, table.concat(texts, "\n"), first - 1, 0, last - 1, #texts[#texts])
end

local function tree_entry_path(entry)
  local path = state.root .. "/" .. entry.path
  return entry.kind == "dir" and (path .. "/") or path
end

local function tree_cursor()
  local entry = tree.entry_at(vim.api.nvim_win_get_cursor(0)[1])
  if not entry then
    return nil
  end
  local line = 0
  if entry.file and vim.b[state.diff_buf].watchtower_path == entry.path then
    local info = diff.line_info(1)
    line = info and (info.new - 1) or 0
  end
  return make_selection(tree_entry_path(entry), "", line, 0, line, 0)
end

local function cursor_selection()
  local view = current_view()
  if view == "diff" then
    return diff_cursor()
  elseif view == "tree" then
    return tree_cursor()
  end
end

local function in_visual_mode()
  local mode = vim.api.nvim_get_mode().mode
  return mode == "v" or mode == "V" or mode == "\22"
end

---Lines of the active visual selection, or of the last one when not in visual mode.
local function visual_lines()
  if in_visual_mode() then
    return vim.fn.line("v"), vim.fn.line(".")
  end
  return vim.fn.line("'<"), vim.fn.line("'>")
end

local function send_mentions(l1, l2)
  local claudecode = require("claudecode")
  local view = current_view()
  if not l1 or not l2 or l1 == 0 then
    l1, l2 = visual_lines()
  end
  if l1 > l2 then
    l1, l2 = l2, l1
  end

  if view == "diff" then
    local sel = diff_range(l1, l2)
    if not sel then
      return false
    end
    return claudecode.send_at_mention(sel.filePath, sel.selection.start.line, sel.selection["end"].line, "ClaudeCodeSend")
  end

  local sent = false
  for lnum = l1, l2 do
    local entry = tree.entry_at(lnum)
    if entry then
      sent = claudecode.send_at_mention(tree_entry_path(entry), nil, nil, "ClaudeCodeSend") or sent
    end
  end
  return sent
end

---Wraps claudecode.nvim's selection functions. Runs once, and only after claudecode.nvim has
---loaded its selection module, so it never forces claudecode.nvim to load.
function M.attach()
  if patched or not config.options.claudecode then
    return
  end
  local sel = package.loaded["claudecode.selection"]
  if not sel then
    return
  end
  patched = true

  local get_cursor_position = sel.get_cursor_position
  sel.get_cursor_position = function(...)
    return cursor_selection() or get_cursor_position(...)
  end

  local get_visual_selection = sel.get_visual_selection
  sel.get_visual_selection = function(...)
    local view = current_view()
    if view == "diff" and in_visual_mode() then
      return diff_range(vim.fn.line("v"), vim.fn.line("."))
    elseif view == "tree" then
      return tree_cursor()
    end
    return get_visual_selection(...)
  end

  local get_visual_selection_from_marks = sel.get_visual_selection_from_marks
  sel.get_visual_selection_from_marks = function(...)
    local view = current_view()
    if view == "diff" then
      return diff_range(vim.fn.line("'<"), vim.fn.line("'>"))
    elseif view == "tree" then
      return tree_cursor()
    end
    return get_visual_selection_from_marks(...)
  end

  local get_range_selection = sel.get_range_selection
  sel.get_range_selection = function(line1, line2, ...)
    if current_view() == "diff" and line1 and line2 then
      return diff_range(line1, line2)
    end
    return get_range_selection(line1, line2, ...)
  end

  local send_at_mention_for_visual_selection = sel.send_at_mention_for_visual_selection
  sel.send_at_mention_for_visual_selection = function(line1, line2, ...)
    if current_view() then
      return send_mentions(line1, line2)
    end
    return send_at_mention_for_visual_selection(line1, line2, ...)
  end
end

---Asks claudecode.nvim to re-read the selection, e.g. after the diff under the cursor changed.
function M.notify()
  M.attach()
  local sel = package.loaded["claudecode.selection"]
  if patched and sel and sel.state and sel.state.tracking_enabled and current_view() then
    sel.debounce_update()
  end
end

return M
