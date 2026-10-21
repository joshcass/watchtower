local config = require("watchtower.config")
local state = require("watchtower.state")
local git = require("watchtower.git")
local tree = require("watchtower.tree")
local diff = require("watchtower.diff")
local bridge = require("watchtower.claudecode")

local M = {}

local uv = vim.uv or vim.loop
local augroup = vim.api.nvim_create_augroup("Watchtower", { clear = true })

local timer
local refreshing = false
local diff_generation = 0
-- Bumped on every open/teardown so callbacks from a previous view are ignored
local session = 0

local function set_win_opts(win, opts)
  for name, value in pairs(opts) do
    vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
  end
end

local function stat_sig(path)
  local st = uv.fs_stat(path)
  if not st then
    return "missing"
  end
  return st.mtime.sec .. ":" .. st.mtime.nsec .. ":" .. st.size
end

local function create_buf(name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = filetype
  return buf
end

---A tab is reusable when it holds nothing but an empty scratch buffer or a dashboard.
function M.tab_is_empty()
  local wins = vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative == ""
  end, vim.api.nvim_tabpage_list_wins(0))
  if #wins ~= 1 then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(wins[1])
  local ft = vim.bo[buf].filetype
  if ft == "snacks_dashboard" or ft == "dashboard" or ft == "alpha" or ft == "ministarter" then
    return true
  end
  return vim.api.nvim_buf_get_name(buf) == ""
    and not vim.bo[buf].modified
    and vim.api.nvim_buf_line_count(buf) == 1
    and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

local function contains_leaf(node, win)
  if node[1] == "leaf" then
    return node[2] == win
  end
  for _, child in ipairs(node[2]) do
    if contains_leaf(child, win) then
      return true
    end
  end
  return false
end

---Keeps the layout as tree | diff | anything else (mirrored when the tree is on the right).
---The diff column may be split horizontally.
function M.pin_layout()
  if not config.options.pin_diff or not state.is_open() or vim.api.nvim_get_current_tabpage() ~= state.tab then
    return
  end
  if not state.win_valid(state.tree_win) or not state.win_valid(state.diff_win) then
    return
  end
  if vim.api.nvim_win_get_tabpage(state.diff_win) ~= state.tab then
    return
  end
  local layout = vim.fn.winlayout()
  local children = layout[1] == "row" and layout[2] or {}
  local right = config.tree_on_right()
  local edge = right and children[#children] or children[1]
  local next_to = right and children[#children - 1] or children[2]
  if edge and edge[1] == "leaf" and edge[2] == state.tree_win and next_to and contains_leaf(next_to, state.diff_win) then
    return
  end

  -- `wincmd H` (or L) makes that window the full-height column at the edge, so moving the
  -- diff first and then the tree leaves tree | diff | rest
  local move = right and "wincmd L" or "wincmd H"
  vim.api.nvim_win_call(state.diff_win, function()
    vim.cmd(move)
  end)
  vim.api.nvim_win_call(state.tree_win, function()
    vim.cmd(move)
  end)
  vim.api.nvim_win_set_width(state.tree_win, config.options.tree.width)
end

---The listed file buffer used most recently, or nil when no file buffers are open.
---@return integer|nil
function M.recent_file_buf()
  local best
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    local buf = info.bufnr
    if info.name ~= "" and vim.bo[buf].buftype == "" and buf ~= state.diff_buf and buf ~= state.tree_buf then
      -- lastused has one-second resolution; on a tie prefer the newer buffer
      if not best or info.lastused > best.lastused or (info.lastused == best.lastused and buf > best.bufnr) then
        best = info
      end
    end
  end
  return best and best.bufnr
end

local function ensure_diff_win()
  if state.win_valid(state.diff_win) and vim.api.nvim_win_get_tabpage(state.diff_win) == state.tab then
    if vim.api.nvim_win_get_buf(state.diff_win) ~= state.diff_buf then
      vim.api.nvim_win_set_buf(state.diff_win, state.diff_buf)
    end
    return
  end
  local current = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(state.tree_win)
  vim.cmd(config.tree_on_right() and "leftabove vertical split" or "rightbelow vertical split")
  state.diff_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.diff_win, state.diff_buf)
  vim.api.nvim_win_set_width(state.tree_win, config.options.tree.width)
  set_win_opts(state.diff_win, { number = false, relativenumber = false, wrap = false, cursorline = true, foldenable = false })
  if vim.api.nvim_win_is_valid(current) then
    vim.api.nvim_set_current_win(current)
  end
end

---@param file WatchtowerFile|nil
function M.select(file)
  state.selected = file
  diff_generation = diff_generation + 1
  local generation = diff_generation
  local current_session = session

  if not state.is_open() then
    return
  end
  ensure_diff_win()

  if not file then
    state.diff_sig = nil
    diff.render(nil, nil, #state.files == 0 and "No changes" or nil)
    return
  end

  local sig = stat_sig(state.abs_path(file)) .. "|" .. stat_sig(state.git_dir .. "/index")
  git.diff(state.root, state.base, file, function(lines, err)
    if generation ~= diff_generation or current_session ~= session or not state.is_open() then
      return
    end
    state.diff_sig = sig
    if err then
      diff.render(file, nil, "git diff failed: " .. err)
    elseif #lines == 0 then
      diff.render(file, nil, "No differences from " .. config.options.base)
    else
      -- The whole file is parsed for syntax so partial hunks highlight like a normal buffer
      local new_text
      if file.status ~= "D" then
        local ok, contents = pcall(vim.fn.readfile, state.abs_path(file), "b")
        new_text = ok and table.concat(contents, "\n") or nil
      end
      diff.render(file, lines, nil, { path = state.abs_path(file), new = new_text })
    end
    bridge.notify()
  end)
end

local function select_from_tree_cursor()
  if not state.win_valid(state.tree_win) then
    return
  end
  local entry = tree.entry_at(vim.api.nvim_win_get_cursor(state.tree_win)[1])
  if entry and entry.file and (not state.selected or state.selected.path ~= entry.path) then
    M.select(entry.file)
  end
end

local function files_sig(files)
  local parts = {}
  for _, f in ipairs(files) do
    table.insert(parts, f.status .. (f.old_path or "") .. "\0" .. f.path)
  end
  return table.concat(parts, "\n")
end

function M.refresh()
  if refreshing or not state.is_open() then
    return
  end
  refreshing = true
  local current_session = session

  local function list(base)
    if current_session ~= session then
      return
    end
    state.base = base
    git.changed_files(state.root, base, function(files, err)
      if current_session ~= session then
        return
      end
      refreshing = false
      if not state.is_open() then
        return
      end
      if not files then
        vim.notify("watchtower: " .. (err or "git failed"), vim.log.levels.ERROR)
        return
      end

      local sig = files_sig(files)
      local list_changed = sig ~= state.files_sig
      if list_changed then
        state.files_sig = sig
        state.files = files
        tree.render()
      end

      local selected
      if state.selected then
        for _, f in ipairs(files) do
          if f.path == state.selected.path then
            selected = f
            break
          end
        end
      end

      if not selected then
        local entry = state.win_valid(state.tree_win) and tree.entry_at(vim.api.nvim_win_get_cursor(state.tree_win)[1])
        local focus = state.focus_path and tree.line_of(state.focus_path)
        state.focus_path = nil
        if focus then
          entry = tree.entry_at(focus)
          vim.api.nvim_win_set_cursor(state.tree_win, { focus, 0 })
        end
        selected = entry and entry.file or tree.ordered_files()[1]
        local lnum = selected and not (entry and entry.file) and tree.line_of(selected.path)
        if lnum and state.win_valid(state.tree_win) then
          vim.api.nvim_win_set_cursor(state.tree_win, { lnum, 0 })
        end
        if selected ~= state.selected or list_changed then
          return M.select(selected)
        end
        return
      end

      local file_sig = stat_sig(state.abs_path(selected)) .. "|" .. stat_sig(state.git_dir .. "/index")
      if selected.status ~= state.selected.status or file_sig ~= state.diff_sig then
        M.select(selected)
      else
        state.selected = selected
      end
    end)
  end

  if state.base and state.base ~= git.EMPTY_TREE then
    list(state.base)
  else
    git.resolve_base(state.root, config.options.base, list)
  end
end

local function start_watching()
  if not config.options.watch.enabled or timer then
    return
  end
  timer = uv.new_timer()
  local interval = config.options.watch.interval_ms
  timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      if not state.is_open() then
        return M.teardown()
      end
      if vim.api.nvim_get_current_tabpage() == state.tab then
        M.refresh()
      end
    end)
  )
end

local function stop_watching()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

---Moves the selection to the next/previous file without leaving the current window.
function M.step_file(dir)
  local files = tree.ordered_files()
  if #files == 0 then
    return
  end
  local index = 0
  for i, f in ipairs(files) do
    if state.selected and f.path == state.selected.path then
      index = i
      break
    end
  end
  local next_file = files[((index - 1 + dir) % #files) + 1]
  -- Expand collapsed parents so the tree cursor can land on the file
  local parent = vim.fs.dirname(next_file.path)
  while parent ~= "." and parent ~= "" do
    state.collapsed[parent] = nil
    parent = vim.fs.dirname(parent)
  end
  tree.render()
  local lnum = tree.line_of(next_file.path)
  if lnum and state.win_valid(state.tree_win) then
    vim.api.nvim_win_set_cursor(state.tree_win, { lnum, 0 })
  end
  M.select(next_file)
end

local function tree_entry()
  return tree.entry_at(vim.api.nvim_win_get_cursor(0)[1])
end

local function toggle_dir(entry, collapsed)
  if collapsed == nil then
    collapsed = not state.collapsed[entry.path]
  end
  state.collapsed[entry.path] = collapsed or nil
  tree.render()
end

local function focus_diff()
  ensure_diff_win()
  vim.api.nvim_set_current_win(state.diff_win)
end

local function set_keymaps()
  local km = config.options.keymaps
  local function map(buf, lhs, fn, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Watchtower: " .. desc })
    end
  end

  local tb = state.tree_buf
  map(tb, km.tree.select, function()
    local entry = tree_entry()
    if not entry then
      return
    end
    if entry.kind == "dir" then
      toggle_dir(entry)
    else
      focus_diff()
    end
  end, "toggle directory / focus diff")
  map(tb, km.tree.open_file, function()
    local entry = tree_entry()
    if entry and entry.file then
      if not state.selected or state.selected.path ~= entry.path then
        M.select(entry.file)
      end
      if entry.file.status == "D" then
        vim.notify("watchtower: " .. entry.path .. " was deleted", vim.log.levels.WARN)
        return
      end
      local info = vim.b[state.diff_buf].watchtower_path == entry.path and diff.line_info(1)
      diff.open_file(state.abs_path(entry.file), info and info.new or 1, 0)
    end
  end, "open file")
  map(tb, km.tree.focus_diff, function()
    local entry = tree_entry()
    if entry and entry.kind == "dir" then
      toggle_dir(entry, false)
    elseif entry then
      focus_diff()
    end
  end, "expand directory / focus diff")
  map(tb, km.tree.collapse, function()
    local entry = tree_entry()
    if not entry then
      return
    end
    if entry.kind == "dir" and not state.collapsed[entry.path] then
      return toggle_dir(entry, true)
    end
    -- Jump to the closest enclosing directory row
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    for i = lnum - 1, 1, -1 do
      local e = tree.entry_at(i)
      if e and e.kind == "dir" and e.depth < entry.depth then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end, "collapse directory")
  map(tb, km.tree.refresh, function()
    state.files_sig = nil
    state.diff_sig = nil
    M.refresh()
  end, "refresh")
  map(tb, km.tree.close, M.close, "close")

  local db = state.diff_buf
  map(db, km.diff.open_file, diff.open_at_cursor, "open file at line")
  map(db, km.diff.next_hunk, function()
    diff.jump_hunk(1)
  end, "next hunk")
  map(db, km.diff.prev_hunk, function()
    diff.jump_hunk(-1)
  end, "previous hunk")
  map(db, km.diff.next_file, function()
    M.step_file(1)
  end, "next file")
  map(db, km.diff.prev_file, function()
    M.step_file(-1)
  end, "previous file")
  map(db, km.diff.focus_tree, function()
    if state.win_valid(state.tree_win) then
      vim.api.nvim_set_current_win(state.tree_win)
    end
  end, "focus tree")
  map(db, km.diff.close, M.close, "close")
end

local function set_autocmds()
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = state.tree_buf,
    callback = function()
      bridge.attach()
      select_from_tree_cursor()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "CursorMoved" }, {
    group = augroup,
    buffer = state.diff_buf,
    callback = bridge.attach,
  })
  vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained", "TabEnter" }, {
    group = augroup,
    callback = function()
      if state.is_open() then
        M.refresh()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TabClosed", "WinClosed" }, {
    group = augroup,
    callback = function(ev)
      vim.schedule(function()
        if not state.is_open() or (ev.event == "WinClosed" and not state.win_valid(state.tree_win)) then
          M.teardown()
        else
          M.pin_layout()
        end
      end)
    end,
  })
  -- WinResized also fires for <C-w>H/J/K/L moves and splits, after the layout has settled
  vim.api.nvim_create_autocmd({ "WinNew", "WinResized" }, {
    group = augroup,
    callback = function()
      vim.schedule(M.pin_layout)
    end,
  })
  -- :split / <C-w>v from the tree or diff would show a second copy of that view buffer;
  -- show the most recently used file instead, or an empty buffer when there is none
  vim.api.nvim_create_autocmd("WinNew", {
    group = augroup,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      -- Scheduled: the view's own splits swap in their real buffer right after splitting
      vim.schedule(function()
        if not state.is_open() or not state.win_valid(win) or win == state.diff_win or win == state.tree_win then
          return
        end
        local buf = vim.api.nvim_win_get_buf(win)
        if buf == state.diff_buf or buf == state.tree_buf then
          local recent = M.recent_file_buf()
          if recent then
            vim.api.nvim_win_set_buf(win, recent)
          else
            vim.api.nvim_win_call(win, function()
              vim.cmd("enew")
            end)
          end
        end
      end)
    end,
  })
end

-- Where the diff window goes relative to a file window, so that later opens of
-- `open_file.direction` land back on the file's side
local diff_side = {
  above = "rightbelow",
  below = "leftabove",
}

---@param opts? { current_tab?: boolean, root?: string, file_win?: integer }
---`file_win` builds the view around a window already showing a repo file instead of replacing the tab.
function M.open(opts)
  opts = opts or {}
  if state.is_open() then
    vim.api.nvim_set_current_tabpage(state.tab)
    if state.win_valid(state.tree_win) then
      vim.api.nvim_set_current_win(state.tree_win)
    end
    return
  end

  local root = opts.root or git.find_root(vim.fn.getcwd())
  if not root then
    vim.notify("watchtower: not inside a git repository", vim.log.levels.ERROR)
    return
  end

  session = session + 1
  state.reset()
  state.root = root
  state.git_dir = vim.trim(vim.system({ "git", "-C", root, "rev-parse", "--absolute-git-dir" }, { text = true }):wait().stdout)

  local file_win = opts.file_win and state.win_valid(opts.file_win) and opts.file_win
  local replaced_buf
  if file_win then
    vim.api.nvim_set_current_win(file_win)
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(file_win))
    if vim.startswith(name, root .. "/") then
      state.focus_path = name:sub(#root + 2)
    end
  elseif opts.current_tab or M.tab_is_empty() then
    replaced_buf = vim.api.nvim_get_current_buf()
    vim.cmd("silent! only")
  else
    vim.cmd("tabnew")
    replaced_buf = vim.api.nvim_get_current_buf()
  end
  state.tab = vim.api.nvim_get_current_tabpage()

  state.tree_buf = create_buf("watchtower://tree", "watchtower_tree")
  state.diff_buf = create_buf("watchtower://diff", "watchtower_diff")

  local open_opts = config.options.open_file
  if file_win and open_opts.mode ~= "replace" then
    state.file_win = file_win
    local side = diff_side[open_opts.direction]
      or (config.tree_on_right() and "rightbelow vertical" or "leftabove vertical")
    vim.cmd(side .. " split")
  end
  state.diff_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.diff_win, state.diff_buf)
  set_win_opts(state.diff_win, { number = false, relativenumber = false, wrap = false, cursorline = true, foldenable = false })

  vim.cmd((config.tree_on_right() and "botright" or "topleft") .. " vertical " .. config.options.tree.width .. "split")
  state.tree_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.tree_win, state.tree_buf)
  set_win_opts(state.tree_win, {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    wrap = false,
    cursorline = true,
    winfixwidth = true,
    spell = false,
    list = false,
  })

  -- Drop the [No Name] buffer the view replaced so it does not linger in the buffer list
  if
    replaced_buf
    and replaced_buf ~= state.diff_buf
    and vim.api.nvim_buf_is_valid(replaced_buf)
    and vim.api.nvim_buf_get_name(replaced_buf) == ""
    and not vim.bo[replaced_buf].modified
    and #vim.fn.win_findbuf(replaced_buf) == 0
  then
    pcall(vim.api.nvim_buf_delete, replaced_buf, {})
  end

  set_keymaps()
  set_autocmds()
  tree.render()
  diff.render(nil, nil, "Loading…")
  M.refresh()
  start_watching()
  M.pin_layout()

  -- Opened around a file the user just picked: leave them in it
  if state.win_valid(state.file_win) then
    vim.api.nvim_set_current_win(state.file_win)
  end
end

---Stops watching and forgets the view. Safe to call repeatedly.
function M.teardown()
  session = session + 1
  stop_watching()
  vim.api.nvim_clear_autocmds({ group = augroup })
  for _, buf in ipairs({ state.tree_buf, state.diff_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  state.reset()
  refreshing = false
end

function M.close()
  if not state.is_open() then
    return
  end
  local tab = state.tab
  M.teardown()
  if #vim.api.nvim_list_tabpages() > 1 and vim.api.nvim_tabpage_is_valid(tab) then
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
  end
end

function M.toggle()
  if state.is_open() then
    M.close()
  else
    M.open()
  end
end

return M
