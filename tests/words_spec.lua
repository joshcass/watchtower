local words = require("watchtower.words")

describe("words.ranges", function()
  it("returns byte ranges of the changed words on each side", function()
    local old_ranges, new_ranges = words.ranges("local count = total + 1", "local count = total + 2")
    assert.are.same({ { 22, 23 } }, old_ranges)
    assert.are.same({ { 22, 23 } }, new_ranges)
  end)

  it("reports insertions only on the new side", function()
    local old_ranges, new_ranges = words.ranges("foo(a, b)", "foo(a, extra, b)")
    assert.are.same({}, old_ranges)
    assert.are.equal("extra, ", ("foo(a, extra, b)"):sub(new_ranges[1][1] + 1, new_ranges[1][2]))
  end)

  it("gives up when most of the line was rewritten", function()
    local old_ranges, new_ranges = words.ranges("return nil", "print(vim.inspect(result))")
    assert.is_nil(old_ranges)
    assert.is_nil(new_ranges)
  end)
end)

describe("words.annotate", function()
  local function line(kind, text)
    return { kind = kind, text = text, new = 1 }
  end

  it("pairs removed and added lines in order and offsets past the marker", function()
    local lines = {
      line("ctx", " keep"),
      line("del", "-alpha = 1"),
      line("del", "-beta = 2"),
      line("add", "+alpha = 10"),
      line("add", "+beta = 2 -- same value"),
      line("add", "+gamma = 3"),
    }
    words.annotate(lines)

    assert.is_nil(lines[1].words)
    -- "1" -> "10"
    assert.are.equal("1", lines[2].text:sub(lines[2].words[1][1] + 1, lines[2].words[1][2]))
    assert.are.equal("10", lines[4].text:sub(lines[4].words[1][1] + 1, lines[4].words[1][2]))
    -- beta line only gained a comment
    assert.are.same({}, lines[3].words)
    assert.are.equal(" -- same value", lines[5].text:sub(lines[5].words[1][1] + 1, lines[5].words[1][2]))
    -- unpaired added line keeps the plain line highlight
    assert.is_nil(lines[6].words)
  end)
end)
