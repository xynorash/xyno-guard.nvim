# Changelog

## Unreleased

- `setup()` options are real now: `dependency_roots`, `lock_dependencies`, `compare`, `hash_max_bytes`, `file_changed_shell`, `reload_unmodified`, `save_all_after_workspace_edit`, `nowrite_restore_ms`, `notify`, `highlights`, `icons`. Invalid values are reported once and ignored.
- Staleness no longer trusts the mtime alone: size, inode and ctime are compared, and a sha256 of small files (<= `hash_max_bytes`) lets a touch/chmod/no-op rewrite through. Measured: `can_save` ~70-120 us (a stat), recording a 262 kB file ~1.4 ms per write (20 kB: ~0.15 ms), see `scripts/bench.lua`.
- `FileChangedShell` no longer answers "ask" (a prompt, contradicting the "never prompts" contract): reload with autoread, else mark stale. Permission-only changes are ignored.
- A refused auto-save's `buftype=nowrite` is restored on the next tick even when `AutoSaveWritePost` never fires (plus a fallback timer), so a manual `:w` is not blocked; `restore_nowrite()` / `stuck_nowrite()`.
- New: `:checkhealth xyno_guard`, `statusline()` / `statusline_hl()`, `state()`, `User XynoGuardState`, highlight groups `XynoGuardDependency/Stale/Gone` (linked to Diagnostic* groups) and a window-local line-number highlight for guarded buffers.
- Tests: 63 (70 with okuuva/auto-save.nvim), was 33 (40).
