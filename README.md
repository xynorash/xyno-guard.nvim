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
require("xyno_guard").setup({})
```

There are no options yet; the argument is accepted for later. The plugin sets no keymaps and registers no commands. It has no dependencies on other plugins. `setup()` can be called again safely.

## API

| Function | What it does |
| --- | --- |
| `setup(opts?)` | installs the autocmds (group `xyno_guard`) and records the buffers already loaded |
| `can_save(buf)` | may this buffer be written now? Use it as the auto-save `condition` |
| `is_dependency(name)` | is this file below `~/.cargo/registry`, `~/.cargo/git`, `~/.rustup`, `$CARGO_HOME/{registry,git}` or `$RUSTUP_HOME`? |
| `save_all()` | writes every modified file buffer that `can_save` allows |

## Keys

None by default. If you want one for `save_all`:

```lua
{ "<leader>W", function() require("xyno_guard").save_all() end, desc = "Write all (guarded)" }
```

## How it works

- The file's mtime is recorded when a buffer is read or written (`BufReadPost`, `BufWritePost`, `BufFilePost`, `FileChangedShellPost`). `can_save()` compares it with the disk; on a mismatch the save is skipped and you get one warning per change (`:w!` keeps your buffer, `:e!` takes the disk version). A deleted file is not recreated.
- Dependency and standard-library buffers are opened nomodifiable and readonly. Buffers that were already loaded when `setup()` runs are locked the same way, but a plugin that loads late (the install above loads it on the first auto-save event) cannot lock a file before that, so use `event = "VeryLazy"` if you open dependency sources right at startup. `:set modifiable` lets you edit one on purpose, and it is still never auto-saved.
- auto-save checks its condition when the event fires but writes up to a second later. With okuuva/auto-save.nvim the guard checks again on `User AutoSaveWritePre` and turns a refused write into a harmless one; a listener of `AutoSaveWritePost` can tell by the buffer still being `modified`.
- `FileChangedShell` never prompts: unmodified buffers are reloaded, modified or deleted ones are left alone with a warning.
- After an LSP edit that touches files other than the current one (rename, file rename, code actions) the other modified buffers are written, so disk and undo stay consistent.

## Platforms

- Linux: tested by the specs in this repository (`nvim --headless --clean -l tests/run.lua`, 39 tests).
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
