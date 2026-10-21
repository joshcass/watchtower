---Word-level diffs between removed and added lines that replace each other.
local M = {}

-- Above this share of changed characters the line was rewritten rather than edited, and
-- highlighting individual words only adds noise
M.MAX_CHANGED_RATIO = 0.5

---Splits text into words, whitespace runs, multibyte runs and single punctuation characters.
---@return string[]
function M.tokenize(text)
  local tokens = {}
  local i = 1
  while i <= #text do
    local token = text:match("^[%w_]+", i) or text:match("^%s+", i) or text:match("^[\128-\255]+", i) or text:sub(i, i)
    table.insert(tokens, token)
    i = i + #token
  end
  return tokens
end

---Byte ranges (0-based, end exclusive) of the changed parts of `old` and `new`, or nil when the
---lines share too little for word highlights to help.
---@return { [1]: integer, [2]: integer }[]|nil old_ranges
---@return { [1]: integer, [2]: integer }[]|nil new_ranges
function M.ranges(old, new)
  local a, b = M.tokenize(old), M.tokenize(new)
  if #a == 0 or #b == 0 then
    return nil, nil
  end

  -- vim.diff works on lines, so diff one token per line
  local hunks = vim.diff(table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n", { result_type = "indices" })
  if #hunks == 0 then
    return nil, nil
  end

  local function offsets(tokens)
    local out, pos = {}, 0
    for i, token in ipairs(tokens) do
      out[i] = pos
      pos = pos + #token
    end
    out[#tokens + 1] = pos
    return out
  end
  local a_off, b_off = offsets(a), offsets(b)

  local old_ranges, new_ranges = {}, {}
  local changed = 0
  for _, h in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
    if count_a > 0 then
      table.insert(old_ranges, { a_off[start_a], a_off[start_a + count_a] })
      changed = changed + a_off[start_a + count_a] - a_off[start_a]
    end
    if count_b > 0 then
      table.insert(new_ranges, { b_off[start_b], b_off[start_b + count_b] })
      changed = changed + b_off[start_b + count_b] - b_off[start_b]
    end
  end

  if changed / (#old + #new) > M.MAX_CHANGED_RATIO then
    return nil, nil
  end
  return old_ranges, new_ranges
end

---Pairs each run of removed lines with the added lines right after it (first with first, and
---so on) and stores the changed byte ranges on each line as `words`, offset past the +/- marker.
---@param lines WatchtowerDiffLine[]
function M.annotate(lines)
  local i = 1
  while i <= #lines do
    if lines[i].kind == "del" then
      local dels, adds = {}, {}
      while lines[i] and lines[i].kind == "del" do
        table.insert(dels, lines[i])
        i = i + 1
      end
      while lines[i] and lines[i].kind == "add" do
        table.insert(adds, lines[i])
        i = i + 1
      end
      for k = 1, math.min(#dels, #adds) do
        local old_ranges, new_ranges = M.ranges(dels[k].text:sub(2), adds[k].text:sub(2))
        if old_ranges then
          local function shift(ranges)
            return vim.tbl_map(function(r)
              return { r[1] + 1, r[2] + 1 }
            end, ranges)
          end
          dels[k].words = shift(old_ranges)
          adds[k].words = shift(new_ranges)
        end
      end
    else
      i = i + 1
    end
  end
end

return M
