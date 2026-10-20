local config = require("watchtower.config")
local state = require("watchtower.state")

local M = {}

local ns = vim.api.nvim_create_namespace("watchtower_tree")

-- Number of buffer lines above the first entry
M.HEADER_LINES = 1

local status_hl = {
  M = "WatchtowerChanged",
  T = "WatchtowerChanged",
  R = "WatchtowerChanged",
  C = "WatchtowerChanged",
  A = "WatchtowerAdded",
  ["?"] = "WatchtowerUntracked",
  D = "WatchtowerRemoved",
  U = "WatchtowerConflict",
}

local function icon_for(kind, name, expanded)
  if not config.options.tree.icons then
    if kind == "directory" then
      return expanded and "-" or "+", "WatchtowerDir"
    end
    return " ", nil
  end
  local ok, icons = pcall(require, "mini.icons")
  if ok then
    if kind == "directory" then
      local icon, hl = icons.get("directory", name)
      return (expanded and "\u{f47c} " or "\u{f460} ") .. icon, hl
    end
    return icons.get("file", name)
  end
  local dev_ok, devicons = pcall(require, "nvim-web-devicons")
  if dev_ok then
    if kind == "directory" then
      return expanded and "\u{f47c} \u{f07c}" or "\u{f460} \u{f07b}", "WatchtowerDir"
    end
    local icon, hl = devicons.get_icon(name, nil, { default = true })
    return icon, hl
  end
  if kind == "directory" then
    return expanded and "\u{f07c}" or "\u{f07b}", "WatchtowerDir"
  end
  return " ", nil
end

local function build(files)
  local root = { dirs = {}, files = {} }
  for _, file in ipairs(files) do
    local node = root
    local parts = vim.split(file.path, "/", { plain = true })
    for i = 1, #parts - 1 do
      local name = parts[i]
      if not node.dirs[name] then
        node.dirs[name] = { name = name, path = node.path and (node.path .. "/" .. name) or name, dirs = {}, files = {} }
      end
      node = node.dirs[name]
    end
    table.insert(node.files, file)
  end
  return root
end

local function flatten(node, depth, out)
  local names = vim.tbl_keys(node.dirs)
  table.sort(names)
  for _, name in ipairs(names) do
    local dir = node.dirs[name]
    local label = dir.name
    -- Collapse chains of single-child directories into one row: "a/b/c"
    while #dir.files == 0 and vim.tbl_count(dir.dirs) == 1 do
      local _, child = next(dir.dirs)
      label = label .. "/" .. child.name
      dir = child
    end
    table.insert(out, { kind = "dir", path = dir.path, label = label, depth = depth })
    if not state.collapsed[dir.path] then
      flatten(dir, depth + 1, out)
    end
  end
  for _, file in ipairs(node.files) do
    table.insert(out, { kind = "file", path = file.path, label = vim.fs.basename(file.path), depth = depth, file = file })
  end
end

---@return table|nil
function M.entry_at(lnum)
  return state.tree_entries[lnum]
end

---@return integer|nil
function M.line_of(path)
  for lnum, entry in pairs(state.tree_entries) do
    if entry.path == path then
      return lnum
    end
  end
end

---@return WatchtowerFile[] files in display order, ignoring collapsed directories
function M.ordered_files()
  local out = {}
  local saved = state.collapsed
  state.collapsed = {}
  local entries = {}
  flatten(build(state.files), 0, entries)
  state.collapsed = saved
  for _, entry in ipairs(entries) do
    if entry.file then
      table.insert(out, entry.file)
    end
  end
  return out
end

function M.render()
  local buf = state.tree_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local cursor_path
  if state.win_valid(state.tree_win) then
    local entry = M.entry_at(vim.api.nvim_win_get_cursor(state.tree_win)[1])
    cursor_path = entry and entry.path
  end

  local entries = {}
  flatten(build(state.files), 0, entries)

  local lines = { " " .. vim.fs.basename(state.root) .. "  " .. config.options.base }
  local marks = { { row = 0, col = 0, end_col = #lines[1], hl = "WatchtowerHeader" } }
  local status_marks = {}
  state.tree_entries = {}

  if #entries == 0 then
    table.insert(lines, "  No changes")
    table.insert(marks, { row = 1, col = 0, end_col = #lines[2], hl = "Comment" })
  end

  for _, entry in ipairs(entries) do
    local indent = string.rep("  ", entry.depth + 1)
    local icon, icon_hl = icon_for(entry.kind == "dir" and "directory" or "file", entry.label, not state.collapsed[entry.path])
    local line = indent .. icon .. " " .. entry.label
    local row = #lines
    table.insert(lines, line)
    state.tree_entries[row + 1] = entry

    local icon_start = #indent
    if icon_hl then
      table.insert(marks, { row = row, col = icon_start, end_col = icon_start + #icon, hl = icon_hl })
    end
    local name_start = icon_start + #icon + 1
    if entry.kind == "dir" then
      table.insert(marks, { row = row, col = name_start, end_col = #line, hl = "WatchtowerDir" })
    else
      local hl = status_hl[entry.file.status] or "WatchtowerChanged"
      table.insert(marks, { row = row, col = name_start, end_col = #line, hl = hl })
      table.insert(status_marks, { row = row, text = entry.file.status, hl = hl })
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m.row, m.col, { end_col = m.end_col, hl_group = m.hl })
  end
  for _, m in ipairs(status_marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m.row, 0, { virt_text = { { m.text .. " ", m.hl } }, virt_text_pos = "right_align" })
  end

  if state.win_valid(state.tree_win) then
    local lnum = cursor_path and M.line_of(cursor_path)
    if not lnum then
      lnum = math.min(vim.api.nvim_win_get_cursor(state.tree_win)[1], #lines)
      lnum = math.max(lnum, M.HEADER_LINES + 1)
      lnum = math.min(lnum, #lines)
    end
    vim.api.nvim_win_set_cursor(state.tree_win, { lnum, 0 })
  end
end

return M
