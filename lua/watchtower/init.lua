local config = require("watchtower.config")

local M = {}

local function set_highlights()
  local links = {
    WatchtowerAdded = "Added",
    WatchtowerUntracked = "Added",
    WatchtowerChanged = "Changed",
    WatchtowerRemoved = "Removed",
    WatchtowerConflict = "DiagnosticError",
    WatchtowerDir = "Directory",
    WatchtowerHeader = "Title",
    WatchtowerDiffAdd = "DiffAdd",
    WatchtowerDiffDelete = "DiffDelete",
    WatchtowerDiffHunk = "Special",
  }
  for group, link in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

---@param opts? { current_tab?: boolean, root?: string, file_win?: integer }
function M.open(opts)
  require("watchtower.view").open(opts)
end

function M.close()
  require("watchtower.view").close()
end

function M.toggle()
  require("watchtower.view").toggle()
end

function M.refresh()
  require("watchtower.view").refresh()
end

local ignored_filetypes = { gitcommit = true, gitrebase = true, gitconfig = true, help = true }

---Returns the repo root when `win` shows a regular file inside a git work tree.
local function repo_file_root(win, buf)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
    return nil
  end
  if vim.api.nvim_win_get_config(win).relative ~= "" or vim.wo[win].diff then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= "" or name == "" or ignored_filetypes[vim.bo[buf].filetype] then
    return nil
  end
  if vim.fn.filereadable(name) == 0 or name:find("/.git/", 1, true) then
    return nil
  end
  return require("watchtower.git").find_root(vim.fs.dirname(name))
end

local function setup_open_on_file(group)
  local armed = true

  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      if not require("watchtower.state").is_open() then
        armed = true
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
      if require("watchtower.state").is_open() then
        -- However the view got opened, closing it later should not make the next file reopen it
        armed = false
        return
      end
      -- Files given on the command line (including `git commit`'s editor) open before VimEnter
      if not armed or vim.v.vim_did_enter ~= 1 then
        return
      end
      local win = vim.api.nvim_get_current_win()
      -- Scheduled so pickers have closed and a session restore has finished laying out windows
      vim.schedule(function()
        if not armed or require("watchtower.state").is_open() then
          return
        end
        local root = repo_file_root(win, ev.buf)
        if root then
          armed = false
          M.open({ root = root, file_win = win })
        end
      end)
    end,
  })
end

---@param opts? WatchtowerConfig
function M.setup(opts)
  config.setup(opts)
  set_highlights()

  local group = vim.api.nvim_create_augroup("WatchtowerSetup", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })

  if config.options.open_on_file then
    setup_open_on_file(group)
  end

  if config.options.open_on_startup then
    local function maybe_open()
      -- An empty tab (or a dashboard) also rules out text piped in on stdin. StdinReadPre
      -- can't be used for that: GUIs like Neovide start nvim with --embed, which fires it.
      if vim.fn.argc(-1) > 0 or not require("watchtower.view").tab_is_empty() then
        return
      end
      if require("watchtower.git").find_root(vim.fn.getcwd()) then
        M.open({ current_tab = true })
      end
    end

    -- GUIs attach their UI after VimEnter, and dashboards (snacks) open on UIEnter, so wait
    -- for the UI and schedule past the dashboard's own UIEnter handler.
    local function after_ui()
      if #vim.api.nvim_list_uis() > 0 then
        vim.schedule(maybe_open)
      else
        vim.api.nvim_create_autocmd("UIEnter", {
          group = group,
          once = true,
          callback = function()
            vim.schedule(maybe_open)
          end,
        })
      end
    end

    if vim.v.vim_did_enter == 1 then
      after_ui()
    else
      vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = after_ui })
    end
  end
end

return M
