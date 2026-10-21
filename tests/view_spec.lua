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

  it("highlights changed words, syntax and shows file line numbers", function()
    move_tree_to("lib/deep/kept.lua")
    local ns = vim.api.nvim_get_namespaces().watchtower_diff
    local marks = vim.api.nvim_buf_get_extmarks(state.diff_buf, ns, 0, -1, { details = true })
    local rows = diff_lines()
    local del_row = vim.fn.index(rows, "-line 20")
    local add_row = vim.fn.index(rows, "+line 20 edited")
    local ctx_row = vim.fn.index(rows, " line 19")

    local by_row = {}
    for _, m in ipairs(marks) do
      by_row[m[2]] = by_row[m[2]] or {}
      table.insert(by_row[m[2]], m)
    end
    local function find(row, pred)
      for _, m in ipairs(by_row[row] or {}) do
        if pred(m[4]) then
          return m
        end
      end
    end

    local word = find(add_row, function(d)
      return d.hl_group == "WatchtowerDiffAddWord"
    end)
    assert.truthy(word, "word highlight on the added line")
    assert.are.equal(" edited", rows[add_row + 1]:sub(word[3] + 1, word[4].end_col))
    assert.truthy(find(add_row, function(d)
      return d.line_hl_group == "WatchtowerDiffAdd"
    end))
    -- Context lines keep their code colors: no line highlight at all
    assert.is_nil(find(ctx_row, function(d)
      return d.line_hl_group ~= nil
    end))

    local function gutter(row)
      local m = find(row, function(d)
        return d.virt_text_pos == "inline"
      end)
      return m and vim.trim(m[4].virt_text[1][1])
    end
    assert.are.equal("19", gutter(ctx_row))
    assert.are.equal("20", gutter(del_row))
    assert.are.equal("20", gutter(add_row))

    local function gutter_hl(row)
      local hl = find(row, function(d)
        return d.virt_text_pos == "inline"
      end)[4].virt_text[1][2]
      -- A single group comes back as a string, a combined one as a list
      return type(hl) == "table" and hl[1] or hl
    end
    assert.are.equal("WatchtowerDiffGutter", gutter_hl(ctx_row))
    assert.are.equal("WatchtowerDiffDeleteSign", gutter_hl(del_row))
    assert.are.equal("WatchtowerDiffAddSign", gutter_hl(add_row))
  end)

  describe("code colors", function()
    local ns, rows

    local function groups(row, col)
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(state.diff_buf, ns, { row, 0 }, { row, -1 }, { details = true })) do
        local d = m[4]
        if d.hl_group and m[3] <= col and col < (d.end_col or 0) then
          table.insert(out, d.hl_group)
        end
      end
      return out
    end

    local function has_syntax(row, col)
      return vim.iter(groups(row, col)):any(function(g)
        return g:sub(1, 1) == "@"
      end)
    end

    local function show_code()
      write(repo .. "/code.lua", { "local before = 1", "local same = true", "return before" })
      sh(repo, "git add code.lua && git commit -q -m code")
      write(repo .. "/code.lua", { 'local after = "text"', "local same = true", "return after" })
      wait_for(function()
        return tree.line_of("code.lua") ~= nil
      end, "code.lua to appear")
      move_tree_to("code.lua")
      ns = vim.api.nvim_get_namespaces().watchtower_diff
      rows = diff_lines()
    end

    it("keeps syntax on added lines, flat text on removed lines and dims unchanged lines", function()
      show_code()
      local del_row = vim.fn.index(rows, "-local before = 1")
      local add_row = vim.fn.index(rows, '+local after = "text"')
      local ctx_row = vim.fn.index(rows, " local same = true")

      -- col 1 is the first character after the marker
      assert.truthy(vim.tbl_contains(groups(add_row, 15), "@string.lua"), vim.inspect(groups(add_row, 15)))
      assert.truthy(vim.tbl_contains(groups(add_row, 0), "WatchtowerDiffAddSign"))

      assert.truthy(vim.tbl_contains(groups(del_row, 1), "WatchtowerDiffDeleteText"))
      assert.is_false(has_syntax(del_row, 1), "keyword on the removed line has no syntax color")
      assert.truthy(vim.tbl_contains(groups(del_row, 0), "WatchtowerDiffDeleteSign"))

      assert.truthy(vim.tbl_contains(groups(ctx_row, 1), "WatchtowerDiffContext"))
      assert.is_false(has_syntax(ctx_row, 1), "keyword on the unchanged line has no syntax color")
    end)

    it("keeps syntax on unchanged lines with diff.context = syntax", function()
      require("watchtower.config").options.diff.context = "syntax"
      show_code()
      local ctx_row = vim.fn.index(rows, " local same = true")
      assert.truthy(vim.tbl_contains(groups(ctx_row, 1), "@keyword.lua"), vim.inspect(groups(ctx_row, 1)))
      assert.falsy(vim.tbl_contains(groups(ctx_row, 1), "WatchtowerDiffContext"))
    end)
  end)

  it("uses Claude Code's diff colors for the current background", function()
    -- OptionSet is not triggered during startup, which is when plenary runs specs, so fire it
    -- the way a real :set background= would
    local function set_background(value)
      vim.o.background = value
      vim.api.nvim_exec_autocmds("OptionSet", { pattern = "background" })
    end
    set_background("light")
    assert.are.equal(tonumber("dcffdc", 16), vim.api.nvim_get_hl(0, { name = "WatchtowerDiffAdd" }).bg)
    assert.are.equal(tonumber("ffc7c7", 16), vim.api.nvim_get_hl(0, { name = "WatchtowerDiffDeleteWord" }).bg)
    assert.are.equal(tonumber("333333", 16), vim.api.nvim_get_hl(0, { name = "WatchtowerDiffDeleteText" }).fg)
    set_background("dark")
    assert.are.equal(tonumber("022800", 16), vim.api.nvim_get_hl(0, { name = "WatchtowerDiffAdd" }).bg)
    assert.are.equal(tonumber("5c0200", 16), vim.api.nvim_get_hl(0, { name = "WatchtowerDiffDeleteWord" }).bg)
    assert.are.equal(tonumber("f8f8f2", 16), vim.api.nvim_get_hl(0, { name = "WatchtowerDiffDeleteText" }).fg)
    set_background("light")
  end)

  it("shows the most recently used file in a window split off the diff", function()
    move_tree_to("lib/deep/kept.lua")
    -- kept.lua is opened first so it has the lower buffer number; only recency can pick it
    diff.open_file(repo .. "/lib/deep/kept.lua", 1, 0)
    local kept = vim.api.nvim_get_current_buf()
    diff.open_file(repo .. "/new/fresh.txt", 1, 0)
    -- lastused has one-second resolution
    vim.wait(1100, function()
      return false
    end)
    vim.cmd("buffer " .. kept)

    vim.api.nvim_set_current_win(state.diff_win)
    vim.cmd("split")
    local win = vim.api.nvim_get_current_win()
    wait_for(function()
      return vim.api.nvim_win_get_buf(win) ~= state.diff_buf
    end, "split to get its own buffer")
    assert.are.equal(kept, vim.api.nvim_win_get_buf(win))
    assert.are.equal(state.diff_buf, vim.api.nvim_win_get_buf(state.diff_win))
  end)

  it("gives windows split off the diff or tree an empty buffer when no files are open", function()
    vim.api.nvim_set_current_win(state.diff_win)
    vim.cmd("split")
    local from_diff = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(state.tree_win)
    vim.cmd("vsplit")
    local from_tree = vim.api.nvim_get_current_win()

    for _, win in ipairs({ from_diff, from_tree }) do
      wait_for(function()
        local buf = vim.api.nvim_win_get_buf(win)
        return buf ~= state.diff_buf and buf ~= state.tree_buf
      end, "split to get its own buffer")
      local buf = vim.api.nvim_win_get_buf(win)
      assert.are.equal("", vim.api.nvim_buf_get_name(buf))
      assert.are.same({ "" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end
    assert.are.equal(state.diff_buf, vim.api.nvim_win_get_buf(state.diff_win))
    assert.are.equal(state.tree_buf, vim.api.nvim_win_get_buf(state.tree_win))
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
