local M = {}

-- `git hash-object -t tree /dev/null`; used as the base when the repo has no commits yet
M.EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

local function run(root, args, cb)
  local cmd = { "git", "-C", root, "-c", "core.quotepath=off" }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      cb(res)
    end)
  end)
end

---@param dir string
---@return string|nil
function M.find_root(dir)
  local res = vim.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, { text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  return vim.trim(res.stdout)
end

---Resolves `base` to something `git diff` accepts, falling back to the empty tree in a repo with no commits.
function M.resolve_base(root, base, cb)
  run(root, { "rev-parse", "--verify", "--quiet", base .. "^{commit}" }, function(res)
    cb(res.code == 0 and base or M.EMPTY_TREE)
  end)
end

local function split_z(out)
  local parts = vim.split(out or "", "\0", { plain = true })
  if parts[#parts] == "" then
    table.remove(parts)
  end
  return parts
end

---@class WatchtowerFile
---@field path string Path relative to the repo root
---@field old_path string|nil Previous path for renames/copies
---@field status string Single letter: M, A, D, R, C, T, U, or "?" for untracked

---Lists files that differ from `base` plus untracked files, sorted by path.
---@param cb fun(files: WatchtowerFile[]|nil, err: string|nil)
function M.changed_files(root, base, cb)
  local pending = 2
  local tracked, untracked, err

  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if err then
      return cb(nil, err)
    end
    local files = vim.list_extend(tracked, untracked)
    table.sort(files, function(a, b)
      return a.path < b.path
    end)
    cb(files)
  end

  run(root, { "diff", base, "--name-status", "-z", "-M", "--no-ext-diff" }, function(res)
    if res.code ~= 0 then
      err = vim.trim(res.stderr or "")
      return done()
    end
    tracked = {}
    local parts = split_z(res.stdout)
    local i = 1
    while i <= #parts do
      local status = parts[i]:sub(1, 1)
      if status == "R" or status == "C" then
        table.insert(tracked, { status = status, old_path = parts[i + 1], path = parts[i + 2] })
        i = i + 3
      else
        table.insert(tracked, { status = status, path = parts[i + 1] })
        i = i + 2
      end
    end
    done()
  end)

  run(root, { "ls-files", "--others", "--exclude-standard", "-z" }, function(res)
    untracked = {}
    if res.code ~= 0 then
      err = vim.trim(res.stderr or "")
      return done()
    end
    for _, path in ipairs(split_z(res.stdout)) do
      table.insert(untracked, { status = "?", path = path })
    end
    done()
  end)
end

---@class WatchtowerDiffLine
---@field text string
---@field kind "hunk"|"add"|"del"|"ctx"|"meta"
---@field new integer Line in the working tree file this diff line corresponds to
---@field old integer|nil
---@field words { [1]: integer, [2]: integer }[]|nil changed byte ranges, set by watchtower.words

---Parses unified diff output into display lines, each mapped to a line in the new file.
---File headers (diff --git, index, ---, +++) are dropped.
---@return WatchtowerDiffLine[]
function M.parse_diff(output)
  local result = {}
  local old_lnum, new_lnum
  local in_hunk = false

  for _, line in ipairs(vim.split(output or "", "\n", { plain = true })) do
    local os, ns = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    if os then
      in_hunk = true
      old_lnum, new_lnum = tonumber(os), tonumber(ns)
      table.insert(result, { text = line, kind = "hunk", new = math.max(new_lnum, 1) })
    elseif in_hunk then
      local c = line:sub(1, 1)
      if c == "+" then
        table.insert(result, { text = line, kind = "add", new = new_lnum })
        new_lnum = new_lnum + 1
      elseif c == "-" then
        -- A deleted line has no line in the new file; point at where it used to be
        table.insert(result, { text = line, kind = "del", new = math.max(new_lnum, 1), old = old_lnum })
        old_lnum = old_lnum + 1
      elseif c == " " then
        table.insert(result, { text = line, kind = "ctx", new = new_lnum, old = old_lnum })
        old_lnum, new_lnum = old_lnum + 1, new_lnum + 1
      elseif c == "\\" then
        table.insert(result, { text = line, kind = "meta", new = math.max(new_lnum - 1, 1) })
      elseif line:match("^diff ") then
        in_hunk = false
      end
    elseif line:match("^Binary files") then
      table.insert(result, { text = line, kind = "meta", new = 1 })
    end
  end

  -- Trailing "" from the final newline would otherwise show up as a context line
  local last = result[#result]
  if last and last.kind == "ctx" and last.text == "" then
    table.remove(result)
  end
  return result
end

---@param file WatchtowerFile
---@param cb fun(lines: WatchtowerDiffLine[]|nil, err: string|nil)
function M.diff(root, base, file, cb)
  local args
  if file.status == "?" then
    -- --no-index exits 1 when the files differ, so the exit code is not an error signal here
    args = { "diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", file.path }
  else
    args = { "diff", "--no-color", "--no-ext-diff", "-M", base, "--" }
    if file.old_path then
      table.insert(args, file.old_path)
    end
    table.insert(args, file.path)
  end

  run(root, args, function(res)
    if res.code > 1 then
      return cb(nil, vim.trim(res.stderr or ""))
    end
    cb(M.parse_diff(res.stdout))
  end)
end

return M
