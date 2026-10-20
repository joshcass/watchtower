local state = require("watchtower.state")

local function sh(cwd, cmd)
  local res = vim.system({ "sh", "-c", cmd }, { cwd = cwd, text = true }):wait()
  assert(res.code == 0, cmd .. "\n" .. (res.stderr or ""))
end

local function wait_for(cond, msg)
  assert(vim.wait(3000, cond, 20), "timed out waiting for " .. msg)
end

local function settle()
  vim.wait(200, function()
    return false
  end)
end

describe("open_on_file", function()
  local repo, outside
  local real_v = vim.v

  before_each(function()
    -- plenary runs specs from a -c command, i.e. before VimEnter. The trigger deliberately
    -- ignores files opened during startup, so pretend startup has finished.
    vim.v = setmetatable({ vim_did_enter = 1 }, { __index = real_v, __newindex = real_v })

    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    repo = vim.uv.fs_realpath(repo)
    sh(repo, "git init -q -b main && git config user.email t@example.com && git config user.name t")
    vim.fn.writefile({ "one", "two" }, repo .. "/tracked.txt")
    vim.fn.writefile({ "same" }, repo .. "/clean.txt")
    sh(repo, "git add -A && git commit -q -m init")
    vim.fn.writefile({ "one", "two changed" }, repo .. "/tracked.txt")

    outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    vim.fn.writefile({ "not in a repo" }, outside .. "/plain.txt")

    vim.cmd("cd " .. vim.fn.fnameescape(outside))
    require("watchtower").setup({ open_on_file = true, watch = { interval_ms = 50 } })
  end)

  after_each(function()
    vim.v = real_v
    require("watchtower").close()
    vim.cmd("silent! only | silent! %bwipeout!")
    vim.fn.delete(repo, "rf")
    vim.fn.delete(outside, "rf")
  end)

  it("builds the view around the first repo file opened, diff between tree and file", function()
    vim.cmd("edit " .. vim.fn.fnameescape(outside .. "/plain.txt"))
    settle()
    assert.is_false(state.is_open())

    vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/tracked.txt"))
    wait_for(state.is_open, "view to open")
    wait_for(function()
      return vim.b[state.diff_buf].watchtower_path == "tracked.txt"
    end, "diff of tracked.txt")

    local file_win = vim.api.nvim_get_current_win()
    assert.are.equal(repo .. "/tracked.txt", vim.api.nvim_buf_get_name(0))
    assert.are.equal(state.file_win, file_win)
    local col = function(win)
      return vim.api.nvim_win_get_position(win)[2]
    end
    assert.is_true(col(state.tree_win) < col(state.diff_win))
    assert.is_true(col(state.diff_win) < col(file_win))
  end)

  it("selects the opened file in the tree when it has changes", function()
    vim.fn.writefile({ "new" }, repo .. "/another.txt")
    vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/tracked.txt"))
    wait_for(function()
      return state.is_open() and state.selected ~= nil
    end, "selection")
    -- another.txt sorts first, so this only passes if the opened file was focused
    assert.are.equal("tracked.txt", state.selected.path)
  end)

  it("does not reopen after the view is closed", function()
    vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/tracked.txt"))
    wait_for(state.is_open, "view to open")
    require("watchtower").close()

    vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/clean.txt"))
    settle()
    assert.is_false(state.is_open())
  end)

  it("ignores commit messages", function()
    vim.fn.writefile({ "" }, repo .. "/.git/COMMIT_EDITMSG")
    vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/.git/COMMIT_EDITMSG"))
    settle()
    assert.is_false(state.is_open())
  end)
end)
