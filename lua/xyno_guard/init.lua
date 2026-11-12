-- What auto-save must never do: write into dependency/std sources, overwrite a
-- file that changed on disk behind the buffer's back (git checkout, an agent,
-- `sed -i`, cargo fmt in another pane), or leave the files a multi-file
-- rename touched unsaved.
--   * Dependency and std buffers (~/.cargo/registry, ~/.cargo/git, ~/.rustup)
--     are nomodifiable (`:set modifiable` to hack on one deliberately).
--   * auto-save's `condition` (can_save): the disk state recorded when the buffer was read/written
--     (mtime, size, inode, ctime, and a content hash for small files) must still match, else the save is skipped and
--     the user is warned once. nvim itself would stop at a blocking W12 "Do you
--     really want to write to it (y/n)?" that swallows keystrokes.
--   * FileChangedShell never prompts: an unmodified buffer is reloaded (when 'autoread' is on, or
--     `reload_unmodified = "always"`), otherwise it is left alone and marked stale; a modified
--     one (or a deleted file) is left alone with one warning. (Detecting the change is up to
--     nvim: `:checktime`, or a distribution's FocusGained autocmd.)
--   * Workspace edits touching other files (rename, file rename, code
--     actions) are followed by a write of every modified buffer that passes
--     can_save: undo/disk stay consistent without waiting for :wa.
local M = {}

local uv = vim.uv
local home = uv.os_homedir()

-- ------------------------------------------------------------------ options

M.defaults = {
  -- extra directories whose files are dependency sources (nomodifiable, never saved), on top of
  -- ~/.cargo/registry, ~/.cargo/git, ~/.rustup and $CARGO_HOME / $RUSTUP_HOME
  dependency_roots = {},
  -- open dependency buffers nomodifiable + readonly
  lock_dependencies = true,
  -- what counts as "changed on disk" besides the mtime
  compare = { size = true, inode = true, ctime = true },
  -- files up to this size also get a content hash: a changed stat with identical content (touch,
  -- chmod, a formatter that rewrote the same text) is then NOT stale. 0 turns the hash off.
  hash_max_bytes = 262144,
  -- take over FileChangedShell so nvim never prompts
  file_changed_shell = true,
  -- an unmodified buffer whose file changed: "autoread" reloads when 'autoread' is on (else the
  -- buffer is marked stale and left alone), "always" reloads, "never" only marks it stale
  reload_unmodified = "autoread",
  -- write the other modified buffers after an LSP edit that touched other files
  save_all_after_workspace_edit = true,
  -- a refused auto-save is made harmless by 'buftype' = nowrite for the duration of the write; it
  -- is restored on the next event-loop tick and, as a fallback, after this many ms
  nowrite_restore_ms = 1000,
  -- warnings: true (vim.notify), false (silent) or function(msg, level)
  notify = true,
  -- window-local highlight of the line numbers of guarded buffers (XynoGuard* groups)
  highlights = true,
  -- statusline texts (swap for glyphs if your font has them)
  icons = { dependency = "DEP RO", stale = "STALE", gone = "GONE" },
}

M.config = vim.deepcopy(M.defaults)

local function validate(opts)
  local clean, problems = {}, {}
  if opts == nil then
    return clean, problems
  end
  if type(opts) ~= "table" then
    return clean, { "setup() takes a table, got " .. type(opts) }
  end
  local function typed(key, ...)
    local v = opts[key]
    if v == nil then
      return false
    end
    for _, t in ipairs({ ... }) do
      if type(v) == t then
        return true
      end
    end
    problems[#problems + 1] = ("%s: expected %s, got %s"):format(key, table.concat({ ... }, " or "), type(v))
    return false
  end
  for _, k in ipairs({ "lock_dependencies", "file_changed_shell", "save_all_after_workspace_edit", "highlights" }) do
    if typed(k, "boolean") then
      clean[k] = opts[k]
    end
  end
  if typed("notify", "boolean", "function") then
    clean.notify = opts.notify
  end
  if typed("hash_max_bytes", "number") then
    if opts.hash_max_bytes >= 0 then
      clean.hash_max_bytes = math.floor(opts.hash_max_bytes)
    else
      problems[#problems + 1] = "hash_max_bytes: must be >= 0"
    end
  end
  if typed("nowrite_restore_ms", "number") then
    if opts.nowrite_restore_ms >= 0 then
      clean.nowrite_restore_ms = math.floor(opts.nowrite_restore_ms)
    else
      problems[#problems + 1] = "nowrite_restore_ms: must be >= 0"
    end
  end
  if typed("reload_unmodified", "string") then
    if vim.tbl_contains({ "autoread", "always", "never" }, opts.reload_unmodified) then
      clean.reload_unmodified = opts.reload_unmodified
    else
      problems[#problems + 1] = 'reload_unmodified: must be "autoread", "always" or "never"'
    end
  end
  if typed("dependency_roots", "table") then
    local roots = {}
    for _, r in ipairs(opts.dependency_roots) do
      if type(r) == "string" and r ~= "" then
        roots[#roots + 1] = r
      else
        problems[#problems + 1] = "dependency_roots: entries must be non-empty strings"
        break
      end
    end
    clean.dependency_roots = roots
  end
  if typed("compare", "table") then
    clean.compare = {}
    for _, k in ipairs({ "size", "inode", "ctime" }) do
      local v = opts.compare[k]
      if v == nil then
        clean.compare[k] = M.defaults.compare[k]
      elseif type(v) == "boolean" then
        clean.compare[k] = v
      else
        problems[#problems + 1] = "compare." .. k .. ": expected boolean"
        clean.compare[k] = M.defaults.compare[k]
      end
    end
  end
  if typed("icons", "table") then
    clean.icons = vim.deepcopy(M.defaults.icons)
    for k, v in pairs(opts.icons) do
      if M.defaults.icons[k] ~= nil and type(v) == "string" then
        clean.icons[k] = v
      else
        problems[#problems + 1] = ("icons.%s: unknown key or not a string"):format(tostring(k))
      end
    end
  end
  for k in pairs(opts) do
    if M.defaults[k] == nil then
      problems[#problems + 1] = "unknown option " .. tostring(k)
    end
  end
  return clean, problems
end

local function say(msg, level)
  local n = M.config.notify
  if n == false then
    return
  elseif type(n) == "function" then
    pcall(n, msg, level or vim.log.levels.WARN)
  else
    vim.notify(msg, level or vim.log.levels.WARN)
  end
end

-- -------------------------------------------------------------------- paths

-- Windows and macOS file systems are case-insensitive by default, and nvim
-- hands out backslash paths on Windows: compare normalized and lowercased.
local fold = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1
local function norm(p)
  local slash = p:sub(-1) == "/" or p:sub(-1) == "\\" -- normalize() drops a trailing slash, a root needs it
  p = vim.fs.normalize(p) .. (slash and "/" or "")
  return fold and p:lower() or p
end

local function dep_roots()
  local roots = { home .. "/.cargo/registry/", home .. "/.cargo/git/", home .. "/.rustup/" }
  for _, v in ipairs({ { "CARGO_HOME", "/registry/" }, { "CARGO_HOME", "/git/" }, { "RUSTUP_HOME", "/" } }) do
    local base = vim.env[v[1]]
    if base and base ~= "" then
      roots[#roots + 1] = vim.fs.normalize(base):gsub("/+$", "") .. v[2]
    end
  end
  for _, extra in ipairs(M.config.dependency_roots) do
    roots[#roots + 1] = vim.fs.normalize(extra):gsub("/+$", "") .. "/"
  end
  for i, r in ipairs(roots) do
    roots[i] = norm(r)
  end
  return roots
end

--- @param name string
--- @return boolean
function M.is_dependency(name)
  name = norm(name)
  for _, r in ipairs(dep_roots()) do
    if name:sub(1, #r) == r then
      return true
    end
  end
  return false
end

-- --------------------------------------------------------------- disk state

local function tstr(t)
  return ("%d.%09d"):format(t.sec, t.nsec)
end

--- sha256 of a small file's bytes (nil: too big, hash off, or unreadable). Reads at most
--- hash_max_bytes, one syscall; base64 first because a Lua string with NUL bytes does not survive
--- the trip into the vimscript function.
local function hash_file(name, size)
  local max = M.config.hash_max_bytes
  if max <= 0 or size > max then
    return nil
  end
  local fd = uv.fs_open(name, "r", 438)
  if not fd then
    return nil
  end
  local data = uv.fs_read(fd, size, 0)
  uv.fs_close(fd)
  if not data then
    return nil
  end
  return vim.fn.sha256(vim.base64.encode(data))
end

local function snapshot(name, st)
  return {
    size = st.size,
    ino = st.ino,
    ctime = tstr(st.ctime),
    hash = hash_file(name, st.size),
  }
end

local function is_file_buf(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

local refresh -- below

local function record(buf)
  if is_file_buf(buf) then
    local name = vim.api.nvim_buf_get_name(buf)
    local st = uv.fs_stat(name)
    vim.b[buf].xyno_guard_stamp = st and tstr(st.mtime) or nil
    vim.b[buf].xyno_guard_snap = st and snapshot(name, st) or nil
    vim.b[buf].xyno_guard_warned = nil
    refresh(buf)
  end
end

--- The disk state against what was recorded: nil (unchanged), "gone" or "stale".
--- `touch`-like changes (stat differs, bytes do not) count as unchanged and re-record the state.
local function disk_change(buf, name)
  local was = vim.b[buf].xyno_guard_stamp
  if was == nil then
    return nil, nil
  end
  local st = uv.fs_stat(name)
  if not st then
    return "gone", nil
  end
  local snap = vim.b[buf].xyno_guard_snap
  local differs = tstr(st.mtime) ~= was
  if snap and not differs then
    local cmp = M.config.compare
    differs = (cmp.size and st.size ~= snap.size) or (cmp.inode and st.ino ~= snap.ino) or (cmp.ctime and tstr(st.ctime) ~= snap.ctime)
  end
  if not differs then
    return nil, st
  end
  -- the stat differs: the bytes decide, when we have a hash for the recorded state
  if snap and snap.hash and st.size == snap.size then
    local now = hash_file(name, st.size)
    if now and now == snap.hash then
      vim.b[buf].xyno_guard_stamp = tstr(st.mtime)
      vim.b[buf].xyno_guard_snap = snapshot(name, st)
      return nil, st
    end
  end
  return "stale", st
end

-- ------------------------------------------------------------------- state

local HL = { dependency = "XynoGuardDependency", stale = "XynoGuardStale", gone = "XynoGuardGone" }

local function strip_winhl(s)
  local keep = {}
  for part in (s or ""):gmatch("[^,]+") do
    if not part:find(":XynoGuard", 1, true) then
      keep[#keep + 1] = part
    end
  end
  return table.concat(keep, ",")
end

local function apply_win(win, state)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local cur = vim.api.nvim_get_option_value("winhighlight", { win = win })
  local want = strip_winhl(cur)
  if state and M.config.highlights then
    local g = HL[state]
    want = (want ~= "" and want .. "," or "") .. ("LineNr:%s,CursorLineNr:%s"):format(g, g)
  end
  if want ~= cur then
    vim.api.nvim_set_option_value("winhighlight", want, { win = win })
  end
end

--- Compute (without warning) why `buf` is guarded: "dependency", "gone", "stale" or nil.
local function compute_state(buf)
  if not is_file_buf(buf) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if M.is_dependency(name) then
    return "dependency"
  end
  return (disk_change(buf, name))
end

refresh = function(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local state = compute_state(buf)
  local old = vim.b[buf].xyno_guard_state
  if state ~= old then
    vim.b[buf].xyno_guard_state = state
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "XynoGuardState", modeline = false, data = { buf = buf, state = state } })
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    apply_win(win, state)
  end
  return state
end

--- Why `buf` is guarded right now: "dependency", "stale" (changed on disk), "gone" (deleted on
--- disk) or nil. Re-reads the disk.
--- @param buf? integer
--- @return string?
function M.state(buf)
  return refresh(buf or vim.api.nvim_get_current_buf())
end

--- Short text for the statusline ("" when the buffer is not guarded). Uses the cached state (no
--- disk access): it is refreshed on BufEnter, FocusGained, CursorHold, writes and every can_save.
--- @param buf? integer
--- @return string
function M.statusline(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return ""
  end
  local state = vim.b[buf].xyno_guard_state
  return state and M.config.icons[state] or ""
end

--- The highlight group for |M.statusline()| (lualine: `color = function() ... end`), or nil.
--- @param buf? integer
--- @return { link: string }? | string?
function M.statusline_hl(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local state = vim.api.nvim_buf_is_valid(buf) and vim.b[buf].xyno_guard_state
  return state and HL[state] or nil
end

local function define_highlights()
  local links = {
    XynoGuardDependency = "DiagnosticInfo",
    XynoGuardStale = "DiagnosticWarn",
    XynoGuardGone = "DiagnosticError",
  }
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

-- ------------------------------------------------------------------- saving

local function change_key(st)
  return tstr(st.mtime) .. ":" .. st.size
end

local function warn_once(buf, key, msg)
  if vim.b[buf].xyno_guard_warned ~= key then
    vim.b[buf].xyno_guard_warned = key
    say(msg, vim.log.levels.WARN)
  end
end

--- auto-save's `condition`: may this buffer be written to disk now?
--- @param buf integer
--- @return boolean
function M.can_save(buf)
  -- Non-file buffers (the 99 prompt is an acwrite buffer) and readonly ones are
  -- never written: `:write` on them raised a blocking "'readonly' option is set" prompt.
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" or vim.bo[buf].readonly then
    return false
  end
  if not is_file_buf(buf) then
    return true
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if M.is_dependency(name) then
    refresh(buf)
    return false
  end
  if vim.b[buf].xyno_guard_stamp == nil then
    -- never read or written by this nvim (new file, or opened before the guard
    -- ran): nothing to compare against
    record(buf)
    return true
  end
  local change, st = disk_change(buf, name)
  refresh(buf)
  local short = vim.fn.fnamemodify(name, ":~:.")
  if change == "gone" then
    warn_once(buf, "gone", short .. " no longer exists on disk: auto-save is paused for this buffer (:w to recreate it)")
    return false
  elseif change == "stale" then
    warn_once(
      buf,
      st and change_key(st) or "stale",
      short .. " changed on disk while this buffer has unsaved edits: auto-save is paused for it (:w! keeps the buffer, :e! takes the disk version)"
    )
    return false
  end
  return true
end

--- Write every modified buffer that may be written. `write` (not noautocmd):
--- didSave, local history and neotest all hear about it.
function M.save_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(buf)
      and is_file_buf(buf)
      and vim.bo[buf].modified
      and vim.bo[buf].modifiable
      and M.can_save(buf)
    then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent! write")
      end)
    end
  end
end

--- Does a WorkspaceEdit touch anything but the current buffer?
local function touches_other_files(edit)
  local cur = vim.uri_from_bufnr(0)
  for uri in pairs(edit.changes or {}) do
    if uri ~= cur then
      return true
    end
  end
  for _, c in ipairs(edit.documentChanges or {}) do
    if c.kind or (c.textDocument and c.textDocument.uri ~= cur) then
      return true
    end
  end
  return false
end

local wrapped = false
local function wrap_workspace_edit()
  if wrapped then
    return
  end
  wrapped = true
  local orig = vim.lsp.util.apply_workspace_edit
  vim.lsp.util.apply_workspace_edit = function(edit, ...)
    local res = orig(edit, ...)
    if M.config.save_all_after_workspace_edit and type(edit) == "table" and touches_other_files(edit) then
      vim.schedule(M.save_all)
    end
    return res
  end
end

-- ------------------------------------------------------------ nowrite guard

--- Give back the 'buftype' of every buffer the guard switched to "nowrite" (a refused auto-save
--- whose AutoSaveWritePost never came). Returns how many were restored.
--- @return integer
function M.restore_nowrite()
  local n = 0
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local bt = vim.b[buf].xyno_guard_buftype
      if bt ~= nil then
        if vim.bo[buf].buftype == "nowrite" then
          vim.bo[buf].buftype = bt
        end
        vim.b[buf].xyno_guard_buftype = nil
        n = n + 1
      end
    end
  end
  return n
end

--- Buffers still switched to "nowrite" by the guard (for :checkhealth).
--- @return integer[]
function M.stuck_nowrite()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].xyno_guard_buftype ~= nil then
      out[#out + 1] = buf
    end
  end
  return out
end

-- -------------------------------------------------------------------- setup

--- Install the guard's autocmds; safe to call again. Options: see `M.defaults` and the help page.
--- Invalid values are reported once and ignored (the defaults stay).
--- @param opts? table
function M.setup(opts)
  local clean, problems = validate(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), clean)
  -- a list option is replaced, not merged
  if clean.dependency_roots then
    M.config.dependency_roots = clean.dependency_roots
  end
  if #problems > 0 then
    vim.notify("xyno-guard: ignored invalid options: " .. table.concat(problems, "; "), vim.log.levels.WARN)
  end

  local group = vim.api.nvim_create_augroup("xyno_guard", { clear = true })
  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_highlights })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "BufFilePost", "FileChangedShellPost" }, {
    group = group,
    callback = function(ev)
      record(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained", "CursorHold" }, {
    group = group,
    callback = function(ev)
      if ev.buf == vim.api.nvim_get_current_buf() then
        refresh(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      apply_win(win, vim.b[vim.api.nvim_win_get_buf(win)].xyno_guard_state)
    end,
  })
  -- auto-save checks `condition` when the event fires but writes up to a second
  -- later (debounce): the file may change in between. So check again right
  -- before the write, and turn a refused write into a harmless one: a "nowrite"
  -- buffer cannot be written (E382, silenced by auto-save's `silent!`).
  -- Whoever listens to AutoSaveWritePost can tell by `modified` still being set.
  -- The write follows AutoSaveWritePre synchronously, so 'buftype' is given back on the next
  -- tick even when AutoSaveWritePost never fires (the plugin errored, the write was aborted);
  -- nowrite_restore_ms is the second fallback. Never left on for a manual :w.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AutoSaveWritePre",
    callback = function(ev)
      local buf = ev.data and ev.data.saved_buffer
      if buf and vim.api.nvim_buf_is_valid(buf) and not M.can_save(buf) then
        if vim.b[buf].xyno_guard_buftype == nil then
          vim.b[buf].xyno_guard_buftype = vim.bo[buf].buftype
        end
        vim.bo[buf].buftype = "nowrite"
        local function back()
          if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].xyno_guard_buftype ~= nil then
            vim.bo[buf].buftype = vim.b[buf].xyno_guard_buftype
            vim.b[buf].xyno_guard_buftype = nil
          end
        end
        vim.schedule(back)
        if M.config.nowrite_restore_ms > 0 then
          vim.defer_fn(back, M.config.nowrite_restore_ms)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AutoSaveWritePost", -- auto-save writes with noautocmd: no BufWritePost
    callback = function(ev)
      local buf = ev.data and ev.data.saved_buffer
      if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
      end
      local bt = vim.b[buf].xyno_guard_buftype
      if bt ~= nil then
        vim.bo[buf].buftype = bt
        vim.b[buf].xyno_guard_buftype = nil
        refresh(buf)
      else
        record(buf)
      end
    end,
  })
  local function lock_dependency(buf)
    if M.config.lock_dependencies and M.is_dependency(vim.api.nvim_buf_get_name(buf)) then
      vim.bo[buf].modifiable = false
      vim.bo[buf].readonly = true
    end
  end
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      lock_dependency(ev.buf)
    end,
  })
  if M.config.file_changed_shell then
    vim.api.nvim_create_autocmd("FileChangedShell", {
      group = group,
      callback = function(ev)
        local reason = vim.v.fcs_reason
        local short = vim.fn.fnamemodify(ev.file, ":~:.")
        if reason == "conflict" or reason == "deleted" then
          vim.v.fcs_choice = ""
          local st = uv.fs_stat(ev.file)
          vim.b[ev.buf].xyno_guard_warned = st and change_key(st) or "gone" -- can_save need not repeat it
          say(
            reason == "deleted" and (short .. " was deleted on disk (the buffer is kept)")
              or (short .. " changed on disk and the buffer has unsaved edits (:e! takes the disk version, :w! keeps the buffer)"),
            vim.log.levels.WARN
          )
        elseif reason == "mode" then
          vim.v.fcs_choice = "" -- permissions only: nothing to reload, nothing to ask
        else
          -- "time" / "changed" on an unmodified buffer: never "ask" (that is a prompt)
          local mode = M.config.reload_unmodified
          local reload = mode == "always" or (mode == "autoread" and vim.bo[ev.buf].autoread)
          vim.v.fcs_choice = reload and "reload" or ""
          if not reload then
            vim.schedule(function()
              refresh(ev.buf)
              say(short .. " changed on disk and was not reloaded ('autoread' is off): :e reloads it", vim.log.levels.INFO)
            end)
          end
        end
      end,
    })
  end
  if M.config.save_all_after_workspace_edit then
    vim.api.nvim_create_autocmd("LspAttach", {
      group = group,
      once = true,
      callback = wrap_workspace_edit,
    })
  end
  -- buffers opened before this ran
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      record(buf)
      if is_file_buf(buf) then
        lock_dependency(buf)
        refresh(buf)
      end
    end
  end
end

return M
