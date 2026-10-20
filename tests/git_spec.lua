local git = require("watchtower.git")

describe("git.parse_diff", function()
  it("maps every diff line to a line in the new file", function()
    local output = table.concat({
      "diff --git a/f.lua b/f.lua",
      "index 1111111..2222222 100644",
      "--- a/f.lua",
      "+++ b/f.lua",
      "@@ -10,4 +10,5 @@ local x",
      " ten",
      "-eleven",
      "+eleven changed",
      "+inserted",
      " twelve",
      "@@ -40,2 +41,0 @@",
      "-forty",
      "-forty one",
      "",
    }, "\n")

    local lines = git.parse_diff(output)
    local got = vim.tbl_map(function(l)
      return { l.kind, l.new }
    end, lines)

    assert.are.same({
      { "hunk", 10 },
      { "ctx", 10 },
      { "del", 11 },
      { "add", 11 },
      { "add", 12 },
      { "ctx", 13 },
      { "hunk", 41 },
      { "del", 41 },
      { "del", 41 },
    }, got)
  end)

  it("keeps the no-newline marker attached to the previous line", function()
    local lines = git.parse_diff("@@ -0,0 +1,2 @@\n+a\n+b\n\\ No newline at end of file\n")
    assert.are.same({ "hunk", "add", "add", "meta" }, vim.tbl_map(function(l)
      return l.kind
    end, lines))
    assert.are.equal(2, lines[4].new)
  end)
end)
