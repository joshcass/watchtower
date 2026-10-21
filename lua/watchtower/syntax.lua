---Treesitter highlights for diff lines, taken from parsing the whole file so that partial
---hunks highlight the same way they do in a normal buffer.
local M = {}

---@alias WatchtowerSpan { [1]: integer, [2]: integer, [3]: string, [4]: integer } start col, end col, hl group, priority

---@param path string used to detect the filetype
---@param text string full file contents
---@return table<integer, WatchtowerSpan[]>|nil spans by 1-based line, columns 0-based end exclusive
function M.spans(path, text)
  local lines = vim.split(text, "\n", { plain = true })
  local ft = vim.filetype.match({ filename = path, contents = lines })
  local lang = ft and vim.treesitter.language.get_lang(ft)
  if not lang or not pcall(vim.treesitter.language.add, lang) then
    return nil
  end
  local query = vim.treesitter.query.get(lang, "highlights")
  if not query then
    return nil
  end

  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok then
    return nil
  end
  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local out = {}
  for id, node, metadata in query:iter_captures(tree:root(), text) do
    local name = query.captures[id]
    -- Captures starting with "_" are helpers for predicates, not highlights
    if name:sub(1, 1) ~= "_" then
      local hl = "@" .. name .. "." .. lang
      local priority = tonumber(metadata.priority or (metadata[id] and metadata[id].priority)) or 100
      local sr, sc, er, ec = node:range()
      for row = sr, er do
        local line = lines[row + 1]
        if line then
          local s = row == sr and sc or 0
          local e = row == er and ec or #line
          if e > s then
            out[row + 1] = out[row + 1] or {}
            table.insert(out[row + 1], { s, e, hl, priority })
          end
        end
      end
    end
  end
  return out
end

return M
