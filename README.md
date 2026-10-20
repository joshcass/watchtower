# watchtower.nvim

A git-diff-centric view for watching an AI agent edit your repo.

```
┌ tree ──────────────┬ diff ─────────────────────────────┐
│  repo  HEAD        │  M  lib/deep/kept.lua             │
│   lib/deep         │ @@ -17,7 +17,7 @@                 │
│    kept.lua      M │  line 17                          │
│    removed.lua   D │ -line 20                          │
│   new              │ +line 20 edited                   │
│    fresh.txt     ? │  line 21                          │
└────────────────────┴───────────────────────────────────┘
```

- The tree lists only files that differ from `HEAD` plus untracked files.
- The diff pane follows the tree cursor.
- `<CR>` in the diff opens the file at that line, in a split on the side away from the tree.
- The diff window stays pinned next to the tree (`pin_diff`); other windows go beyond it.
- Both panes refresh while files change on disk.
- With [claudecode.nvim](https://github.com/coder/claudecode.nvim), Claude sees the real file and line under your cursor or visual selection in the diff, not the diff buffer.

Requires Neovim >= 0.10 and git.

## Install (lazy.nvim)

```lua
{
  dir = "~/Documents/watchtower-mode", -- or "<user>/<repo>" once published
  lazy = false,
  opts = {
    open_on_startup = true, -- open right away when nvim starts (no file args) inside a git repo
    open_on_file = true, -- otherwise keep the dashboard and open with the first repo file you open
  },
  keys = {
    { "<leader>gw", "<cmd>Watchtower<cr>", desc = "Watchtower (diff view)" },
  },
}
```

`:Watchtower [toggle|open|close|refresh]`

## Configuration

Defaults:

```lua
{
  open_on_startup = false,
  open_on_file = false,
  pin_diff = true,       -- keep the diff window directly next to the tree
  base = "HEAD",
  tree = {
    position = "left",    -- "left" | "right": screen edge the tree sits on
    width = 35,
    icons = true,
  },
  open_file = {
    mode = "split",       -- "split" | "replace" (open in the diff window)
    direction = "away",   -- "away" (vertical split on the far side of the diff from the tree) | "above" | "below"
    reuse_window = true,  -- later opens reuse the window from the first one
  },
  watch = { enabled = true, interval_ms = 1000 },
  claudecode = true,
  keymaps = {
    tree = { select = "<CR>", open_file = "o", focus_diff = "l", collapse = "h", refresh = "R", close = "q" },
    diff = {
      open_file = "<CR>",
      next_hunk = "]c", prev_hunk = "[c",
      next_file = "]f", prev_file = "[f",
      focus_tree = "<BS>",
      close = "q",
    },
  },
}
```

Set any keymap to `false` to disable it.

### Opening automatically

- `open_on_startup` opens the view in place of the dashboard when nvim starts in a git repo with no file arguments. It waits for the UI, so it works with GUIs like Neovide.
- `open_on_file` opens the view the first time a regular file from a git repo appears in a window after startup. Examples are a file picked from the dashboard, a project switch, or a restored session. The view is built around that window: tree | diff | file (mirrored with `tree.position = "right"`), and the file is selected in the tree if it has changes. It stays off after you close the view until the next `:cd`. Files passed on the command line (including `git commit`'s editor) and files under `.git/` never trigger it.

## How updates work

While the view's tab is current, `git diff <base> --name-status` and `git ls-files --others --exclude-standard` are polled every `watch.interval_ms`. The tree re-renders only when that list changes. The selected file's diff reloads when its mtime/size or the git index changes. A refresh also runs on `BufWritePost`, `FocusGained` and `TabEnter`.

## claudecode.nvim

claudecode.nvim reports the current buffer's name and line numbers to Claude. Watchtower wraps its selection functions so that while a watchtower buffer is focused:

| Where | What Claude receives |
| --- | --- |
| diff, cursor | real file path, line in the working tree file (deleted lines map to where they were) |
| diff, visual selection | real file path, the line range the selected diff lines map to, and the selected diff text (with `+`/`-`) as the selection text |
| tree | file under the cursor, positioned at its first change |
| `:ClaudeCodeSend` in diff / tree | at-mention for the mapped line range / the files in range |

The wrap is applied lazily the first time a watchtower buffer is used after claudecode.nvim loads, so it never forces claudecode.nvim to load.

## Tests

```sh
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests {minimal_init='tests/minimal_init.lua', sequential=true}"
```

Uses plenary.nvim from `stdpath("data")/lazy` or `$PLENARY_DIR`.
