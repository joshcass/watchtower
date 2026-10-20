local state = require("watchtower.state")
local diff = require("watchtower.diff")
local tree = require("watchtower.tree")

local function sh(cwd, cmd)
  local res = vim.system({ "sh", "-c", cmd }, { cwd = cwd, text = true }):wait()
  assert(res.code == 0, cmd .. "\n" .. (res.stderr or ""))
  return res.stdout
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function numbered(n, prefix)
  local out = {}
  for i = 1, n do
    out[i] = (prefix or "line ") .. i
  end
  return out
end

local function wait_for(cond, msg)
  assert(vim.wait(3000, cond, 20), "timed out waiting for " .. msg)
end

local function tree_lines()
  return vim.api.nvim_buf_get_lines(state.tree_buf, 0, -1, false)
end

local function diff_lines()
  return vim.api.nvim_buf_get_lines(state.diff_buf, 0, -1, false)
end

local function move_tree_to(path)
  local lnum = tree.line_of(path)
  assert(lnum, "no tree line for " .. path)
  vim.api.nvim_set_current_win(state.tree_win)
  vim.api.nvim_win_set_cursor(state.tree_win, { lnum, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.tree_buf })
  wait_for(function()
    return vim.b[state.diff_buf].watchtower_path == path
  end, "diff of " .. path)
end

describe("watchtower view", function()
  local repo

  before_each(function()
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    repo = vim.uv.fs_realpath(repo)
    sh(repo, "git init -q -b main && git config user.email t@example.com && git config user.name t")
    write(repo .. "/lib/deep/kept.lua", numbered(30))
    write(repo .. "/lib/deep/removed.lua", { "gone" })
    write(repo .. "/clean.lua", { "unchanged" })
    sh(repo, "git add -A && git commit -q -m init")

    local kept = numbered(30)
    kept[20] = "line 20 edited"
    write(repo .. "/lib/deep/kept.lua", kept)
    os.remove(repo .. "/lib/deep/removed.lua")
    write(repo .. "/new/fresh.txt", { "brand", "new" })

    require("watchtower").setup({ watch = { interval_ms = 50 } })
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    require("watchtower").open({ current_tab = true })
    wait_for(function()
      return #state.files == 3
    end, "changed files")
  end)

  after_each(function()
    require("watchtower").close()
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(repo, "rf")
  end)

  it("lists only modified, deleted and untracked files", function()
    local paths = vim.tbl_map(function(f)
      return f.status .. " " .. f.path
    end, state.files)
    assert.are.same({ "M lib/deep/kept.lua", "D lib/deep/removed.lua", "? new/fresh.txt" }, paths)

    local text = table.concat(tree_lines(), "\n")
    assert.truthy(text:find("lib/deep", 1, true), "single-child dirs are merged")
    assert.falsy(text:find("clean.lua", 1, true))
  end)

  it("shows the diff for the file under the tree cursor", function()
    move_tree_to("lib/deep/kept.lua")
    assert.truthy(vim.tbl_contains(diff_lines(), "+line 20 edited"), vim.inspect(diff_lines()))

    move_tree_to("new/fresh.txt")
    assert.truthy(vim.tbl_contains(diff_lines(), "+brand"))
    assert.falsy(vim.tbl_contains(diff_lines(), "+line 20 edited"))
  end)

  it("opens the file in a split right of the diff at the selected line", function()
    move_tree_to("lib/deep/kept.lua")
    vim.api.nvim_set_current_win(state.diff_win)
    local target = vim.fn.index(diff_lines(), "+line 20 edited") + 1
    vim.api.nvim_win_set_cursor(state.diff_win, { target, 3 })

    diff.open_at_cursor()

    local win = vim.api.nvim_get_current_win()
    assert.are_not.equal(state.diff_win, win)
    assert.are.equal(repo .. "/lib/deep/kept.lua", vim.api.nvim_buf_get_name(0))
    assert.are.same({ 20, 2 }, vim.api.nvim_win_get_cursor(win))
    -- tree | diff | file
    local col = vim.api.nvim_win_get_position(win)[2]
    assert.is_true(vim.api.nvim_win_get_position(state.tree_win)[2] < vim.api.nvim_win_get_position(state.diff_win)[2])
    assert.is_true(col > vim.api.nvim_win_get_position(state.diff_win)[2])

    -- A second open reuses the same window
    vim.api.nvim_set_current_win(state.diff_win)
    vim.api.nvim_win_set_cursor(state.diff_win, { 1, 0 })
    diff.open_at_cursor()
    assert.are.equal(win, vim.api.nvim_get_current_win())
  end)

  it("moves the diff back next to the tree when another window displaces it", function()
    move_tree_to("lib/deep/kept.lua")
    vim.api.nvim_set_current_win(state.diff_win)
    diff.open_at_cursor()
    local file_win = vim.api.nvim_get_current_win()

    -- Push the file window to the far left, ahead of the tree and diff
    vim.cmd("wincmd H")
    vim.api.nvim_exec_autocmds("WinResized", {})
    local function cols()
      return {
        tree = vim.api.nvim_win_get_position(state.tree_win)[2],
        diff = vim.api.nvim_win_get_position(state.diff_win)[2],
        file = vim.api.nvim_win_get_position(file_win)[2],
      }
    end
    wait_for(function()
      local c = cols()
      return c.tree == 0 and c.tree < c.diff and c.diff < c.file
    end, "tree | diff | file, got " .. vim.inspect(cols()))
    assert.are.equal(35, vim.api.nvim_win_get_width(state.tree_win))
  end)

  it("mirrors the layout when the tree is on the right", function()
    require("watchtower").close()
    require("watchtower").setup({ tree = { position = "right" }, watch = { interval_ms = 50 } })
    require("watchtower").open({ current_tab = true })
    wait_for(function()
      return #state.files == 3
    end, "changed files")

    move_tree_to("lib/deep/kept.lua")
    vim.api.nvim_set_current_win(state.diff_win)
    diff.open_at_cursor()
    local file_win = vim.api.nvim_get_current_win()
    local function cols()
      return {
        tree = vim.api.nvim_win_get_position(state.tree_win)[2],
        diff = vim.api.nvim_win_get_position(state.diff_win)[2],
        file = vim.api.nvim_win_get_position(file_win)[2],
      }
    end
    local function mirrored()
      local c = cols()
      return c.file == 0 and c.file < c.diff and c.diff < c.tree
    end
    assert.is_true(mirrored(), "file | diff | tree, got " .. vim.inspect(cols()))

    -- Push the file window to the far right, past the tree
    vim.cmd("wincmd L")
    vim.api.nvim_exec_autocmds("WinResized", {})
    wait_for(mirrored, "file | diff | tree after displacement, got " .. vim.inspect(cols()))
    assert.are.equal(35, vim.api.nvim_win_get_width(state.tree_win))
  end)

  it("opens in place when configured with mode = replace", function()
    require("watchtower.config").options.open_file.mode = "replace"
    move_tree_to("new/fresh.txt")
    vim.api.nvim_set_current_win(state.diff_win)
    vim.api.nvim_win_set_cursor(state.diff_win, { vim.fn.index(diff_lines(), "+new") + 1, 0 })

    diff.open_at_cursor()

    assert.are.equal(state.diff_win, vim.api.nvim_get_current_win())
    assert.are.equal(repo .. "/new/fresh.txt", vim.api.nvim_buf_get_name(0))
    assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("picks up files changed on disk while open", function()
    move_tree_to("lib/deep/kept.lua")

    write(repo .. "/clean.lua", { "now dirty" })
    wait_for(function()
      return tree.line_of("clean.lua") ~= nil
    end, "clean.lua to appear")

    local kept = numbered(30)
    kept[20] = "line 20 edited"
    kept[5] = "line 5 edited by the ai"
    write(repo .. "/lib/deep/kept.lua", kept)
    wait_for(function()
      return vim.tbl_contains(diff_lines(), "+line 5 edited by the ai")
    end, "selected diff to refresh")

    write(repo .. "/clean.lua", { "unchanged" })
    wait_for(function()
      return tree.line_of("clean.lua") == nil
    end, "clean.lua to disappear")
  end)

  it("reports the real file and line to claudecode.nvim", function()
    local broadcasts = {}
    local sel = {
      state = { tracking_enabled = true },
      get_cursor_position = function()
        return { filePath = vim.api.nvim_buf_get_name(0) }
      end,
      get_visual_selection = function() end,
      get_visual_selection_from_marks = function() end,
      get_range_selection = function() end,
      send_at_mention_for_visual_selection = function() end,
      debounce_update = function() end,
    }
    package.loaded["claudecode.selection"] = sel
    package.loaded["claudecode"] = {
      send_at_mention = function(path, s, e)
        table.insert(broadcasts, { path, s, e })
        return true
      end,
    }
    require("watchtower.claudecode").attach()

    move_tree_to("lib/deep/kept.lua")
    local tree_pos = sel.get_cursor_position()
    assert.are.equal(repo .. "/lib/deep/kept.lua", tree_pos.filePath)
    assert.are.equal(19, tree_pos.selection.start.line)

    vim.api.nvim_set_current_win(state.diff_win)
    local edited = vim.fn.index(diff_lines(), "+line 20 edited") + 1
    vim.api.nvim_win_set_cursor(state.diff_win, { edited, 0 })
    local pos = sel.get_cursor_position()
    assert.are.equal(repo .. "/lib/deep/kept.lua", pos.filePath)
    assert.are.equal(19, pos.selection.start.line)

    local range = sel.get_range_selection(edited - 1, edited)
    assert.are.equal("-line 20\n+line 20 edited", range.text)
    assert.are.same({ 19, 19 }, { range.selection.start.line, range.selection["end"].line })

    sel.send_at_mention_for_visual_selection(edited - 4, edited)
    assert.are.same({ { repo .. "/lib/deep/kept.lua", 16, 19 } }, broadcasts)

    -- Other buffers fall through to claudecode's own behaviour
    vim.cmd("enew")
    assert.are.equal("", sel.get_cursor_position().filePath)

    package.loaded["claudecode.selection"] = nil
    package.loaded["claudecode"] = nil
  end)
end)
