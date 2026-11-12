# xyno-guard.nvim

Keeps auto-save away from files it must never write: dependency and standard-library sources, files changed on disk, and similar. Works with any auto-save plugin.

## Why

I use auto-save all day while writing Rust. Three things kept going wrong: a debounced save landing in `~/.cargo/registry` or the standard library sources I was only reading, a save overwriting a file that `git checkout` or a formatter had just changed on disk, and Neovim stopping at a blocking W12 "Do you really want to write to it" prompt that swallowed my keystrokes. This plugin is the guard I put in front of the writes.

## Requirements

- Neovim 0.12+
- An auto-save plugin that accepts a `condition` function (I use [okuuva/auto-save.nvim](https://github.com/okuuva/auto-save.nvim)). Optional: the dependency protection and `save_all()` work without one.

No external tools.

## Install (lazy.nvim)

```lua
{
  "okuuva/auto-save.nvim",
  event = { "InsertLeave", "TextChanged", "TextChangedI" },
  dependencies = { "xynorash/xyno-guard.nvim" },
  opts = function()
    require("xyno_guard").setup()
    return { condition = require("xyno_guard").can_save }
  end,
}
```

Without lazy.nvim, call `require("xyno_guard").setup()` and pass `require("xyno_guard").can_save` as the condition of whatever auto-save plugin you use.

## Setup options

```lua
require("xyno_guard").setup({
  dependency_roots = {},            -- extra directories treated like ~/.cargo/registry (locked, never saved)
  lock_dependencies = true,         -- open dependency buffers nomodifiable + readonly
  compare = { size = true, inode = true, ctime = true }, -- what counts as "changed" besides the mtime
  hash_max_bytes = 262144,          -- files up to this size also get a sha256; 0 = stat only
  file_changed_shell = true,        -- take over FileChangedShell so nvim never prompts
  reload_unmodified = "autoread",   -- "autoread" | "always" | "never": unmodified buffer, file changed
  save_all_after_workspace_edit = true,
  nowrite_restore_ms = 1000,        -- fallback timer for a stuck buftype=nowrite (0 = next tick only)
  notify = true,                    -- true | false | function(msg, level)
  highlights = true,                -- window-local LineNr highlight on guarded buffers
  icons = { dependency = "DEP RO", stale = "STALE", gone = "GONE" }, -- statusline texts
})
```

Bad values are reported once and ignored (the default stays); unknown keys are reported too. `setup()` can be called again and starts from the defaults each time. The plugin sets no keymaps and registers no commands.

## Statusline, highlights, health

- `require("xyno_guard").statusline()` returns `"DEP RO"`, `"STALE"`, `"GONE"` or `""` for the current buffer (cached, no disk access; refreshed on `BufEnter`, `FocusGained`, `CursorHold`, writes and every `can_save`). `statusline_hl()` returns the group name. lualine:

  ```lua
  { function() return require("xyno_guard").statusline() end,
    cond = function() return package.loaded["xyno_guard"] and require("xyno_guard").statusline() ~= "" end,
    color = function() return require("xyno_guard").statusline_hl() end }
  ```
- `state(buf)` re-reads the disk and returns `"dependency"`, `"stale"`, `"gone"` or `nil`. `User XynoGuardState` fires when it changes (`data = { buf, state }`).
- Highlight groups, linked by default so a colorscheme can override them: `XynoGuardDependency` (-> `DiagnosticInfo`), `XynoGuardStale` (-> `DiagnosticWarn`), `XynoGuardGone` (-> `DiagnosticError`). They colour the statusline component and the line numbers of guarded windows (`winhighlight`, your own entries are kept).
- `:checkhealth xyno_guard`: Neovim version, whether `setup()` ran, effective options, whether auto-save.nvim really uses `can_save`, stuck `nowrite` buffers, stale and deleted buffers, highlight groups.

## API

| Function | What it does |
| --- | --- |
| `setup(opts?)` | installs the autocmds (group `xyno_guard`) and records the buffers already loaded |
| `can_save(buf)` | may this buffer be written now? Use it as the auto-save `condition` |
| `is_dependency(name)` | is this file below `~/.cargo/registry`, `~/.cargo/git`, `~/.rustup`, `$CARGO_HOME/{registry,git}` or `$RUSTUP_HOME`? |
| `save_all()` | writes every modified file buffer that `can_save` allows |
| `state(buf?)` | `"dependency"`, `"stale"`, `"gone"` or `nil` (re-reads the disk) |
| `statusline(buf?)`, `statusline_hl(buf?)` | statusline text and its highlight group |
| `restore_nowrite()`, `stuck_nowrite()` | give back / list buffers stuck in `buftype=nowrite` |

## Keys

None by default. If you want one for `save_all`:

```lua
{ "<leader>W", function() require("xyno_guard").save_all() end, desc = "Write all (guarded)" }
```

## How it works

- When a buffer is read or written (`BufReadPost`, `BufWritePost`, `BufFilePost`, `FileChangedShellPost`, `AutoSaveWritePost`) the guard records the file's mtime, size, inode and ctime, plus a sha256 of the bytes for files up to `hash_max_bytes`. `can_save()` compares them with the disk (a `stat`, no read, when nothing changed). A mismatch skips the save and warns once per change (`:w!` keeps your buffer, `:e!` takes the disk version). A deleted file is not recreated.
- The mtime alone is not trusted: `rsync -t`, `touch -r`, a coarse-clock file system or a same-second rewrite can leave it unchanged, so size, inode and ctime (which user space cannot set) are compared too. For a small file whose stat changed but whose bytes did not (`touch`, `chmod`, a formatter that rewrote the same text) the hash says "not changed" and the save is allowed. Limits: above `hash_max_bytes` any stat change counts as a change (so a `chmod` makes a big file stale until you `:e!`/`:w!`); with `compare.ctime = false` a same-size, same-mtime, same-inode rewrite goes unseen; the hash is taken when the buffer is read or written, so a change between nvim's read and the guard's `stat` is not detected.
- Dependency and standard-library buffers are opened nomodifiable and readonly. Buffers that were already loaded when `setup()` runs are locked the same way, but a plugin that loads late (the install above loads it on the first auto-save event) cannot lock a file before that, so use `event = "VeryLazy"` if you open dependency sources right at startup. `:set modifiable` lets you edit one on purpose, and it is still never auto-saved.
- auto-save checks its condition when the event fires but writes up to a second later. With okuuva/auto-save.nvim the guard checks again on `User AutoSaveWritePre` and turns a refused write into a harmless one by setting `buftype=nowrite`; a listener of `AutoSaveWritePost` can tell by the buffer still being `modified`. auto-save writes right after `AutoSaveWritePre`, so the `buftype` is given back on the next event-loop tick whether or not `AutoSaveWritePost` ever fires (and again after `nowrite_restore_ms`). Between those two points a manual `:w` of that buffer would fail, which is the intent.
- `FileChangedShell` never prompts. A modified buffer or a deleted file is left alone with a warning. An unmodified buffer is reloaded when `'autoread'` is on (nvim does it itself) or `reload_unmodified = "always"`; otherwise it is left alone, marked `STALE`, and one info line says `:e` reloads it. A permissions-only change is ignored. (Earlier versions answered "ask" when autoread was off, which is a prompt; that contradicted this.)
- After an LSP edit that touches files other than the current one (rename, file rename, code actions) the other modified buffers are written, so disk and undo stay consistent.

## Platforms

- Linux: tested by the specs in this repository (`nvim --headless --clean -l tests/run.lua`, 63 tests, 70 with auto-save.nvim checked out).
- Windows and macOS: the original spec for this code in xynovim was not among the files its platforms workflow skipped there, and that workflow passed. The specs of this repository have not been run on either, so I treat both as unverified. The path handling is case-insensitive on both.
- The `~/.cargo` and `~/.rustup` roots are Rust-specific; other languages' dependency directories are not covered.

## Tests

```sh
git clone https://github.com/okuuva/auto-save.nvim tests/deps/auto-save.nvim   # optional, else those tests skip
nvim --headless --clean -l tests/run.lua
```

`XYNO_GUARD_AUTOSAVE_DIR` points at an existing checkout instead.

## Extracted from xynovim

This is a module of my Neovim configuration, [xynovim](https://github.com/xynorash/xynovim), published on its own. It is an independent project.

## License

MIT, see [LICENSE](LICENSE).
