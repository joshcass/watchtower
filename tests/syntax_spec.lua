local syntax = require("watchtower.syntax")

describe("syntax.spans", function()
  local function groups_at(spans, line, col)
    local out = {}
    for _, span in ipairs(spans[line] or {}) do
      if span[1] <= col and col < span[2] then
        table.insert(out, span[3])
      end
    end
    return out
  end

  it("returns treesitter highlight groups by line, with multi-line nodes split per line", function()
    local spans = syntax.spans("/x/example.lua", 'local name = "hi"\n--[[ a\nb ]]\nreturn name\n')
    assert.truthy(vim.tbl_contains(groups_at(spans, 1, 0), "@keyword.lua"))
    assert.truthy(vim.tbl_contains(groups_at(spans, 1, 14), "@string.lua"))
    assert.truthy(vim.tbl_contains(groups_at(spans, 3, 0), "@comment.lua"), "second line of a block comment")
    assert.truthy(vim.tbl_contains(groups_at(spans, 4, 0), "@keyword.return.lua"))
  end)

  it("returns nil when there is no parser for the file type", function()
    assert.is_nil(syntax.spans("/x/notes.unknownext", "plain text"))
  end)
end)
