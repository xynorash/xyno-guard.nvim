-- xyno-guard: the guard itself (lua/xyno_guard/init.lua) and its use with a real
-- auto-save plugin (okuuva/auto-save.nvim, see tests/run.lua for where it is
-- looked for; those tests skip when it is absent).
-- All files live in temp dirs; "dependency" paths are faked with CARGO_HOME /
-- RUSTUP_HOME pointing into one.
local H = require("xynotest.helpers")
local dg = require("xyno_guard")
dg.setup()

-- --------------------------------------------------------------- local utils

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local mtime_n = 0
--- Change a file on disk "behind the buffer's back": new content and an mtime
--- that differs from every earlier one (no reliance on clock granularity).
local function external_write(path, text)
  write(path, text)
  mtime_n = mtime_n + 7
  local t = os.time() + 100 + mtime_n
  assert(vim.uv.fs_utime(path, t, t))
end

local function stamp_of(path)
  local st = assert(vim.uv.fs_stat(path))
  return ("%d.%09d"):format(st.mtime.sec, st.mtime.nsec)
end

--- A temp file, opened in the current window. Returns path, bufnr.
local function open_file(text, name)
  local dir = H.tmpdir()
  local path = dir .. "/" .. (name or "f.txt")
  write(path, text or "one\ntwo\n")
  return path, H.open(path)
end

local function set_lines(buf, lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

local env_undo = {}
local function env(name, value)
  local old = vim.env[name]
  vim.env[name] = value
  env_undo[#env_undo + 1] = function()
    vim.env[name] = old
  end
end

local have_autosave = vim.env.XYNO_GUARD_AUTOSAVE_FOUND == "1"
local as = function()
  return require("auto-save")
end
--- Skip the running test unless the auto-save plugin is on the runtimepath.
local function need_autosave()
  if not have_autosave then
    H.skip_file("okuuva/auto-save.nvim not found (set XYNO_GUARD_AUTOSAVE_DIR)")
  end
end

--- WARN messages captured so far, as plain strings.
local function warnings(cap)
  local out = {}
  for _, n in ipairs(cap.list) do
    if n.level == vim.log.levels.WARN then
      out[#out + 1] = n.msg
    end
  end
  return out
end

--- A language server that only records what it is sent. `save` is its
--- textDocumentSync.save capability. Returns the notification log.
local function fake_lsp(buf, name, save)
  local log = {}
  local cmd = function()
    local closing = false
    return {
      request = function(method, _, cb)
        if method == "initialize" then
          cb(nil, { capabilities = { textDocumentSync = { openClose = true, change = 1, save = save } } })
        elseif method == "shutdown" then
          cb(nil, nil)
        end
        return true, 1
      end,
      notify = function(method, params)
        log[#log + 1] = { method = method, params = params }
        return true
      end,
      is_closing = function()
        return closing
      end,
      terminate = function()
        closing = true
      end,
    }
  end
  local id = vim.lsp.start({ name = name, cmd = cmd, root_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(buf)) }, {
    bufnr = buf,
  })
  H.wait_for(function()
    local c = vim.lsp.get_client_by_id(id)
    return c and c.initialized
  end, 5000, "fake LSP " .. name)
  return log, vim.lsp.get_client_by_id(id)
end

local function count(log, method)
  local n = 0
  for _, e in ipairs(log) do
    if e.method == method then
      n = n + 1
    end
  end
  return n
end

--- Count BufWritePost events for `buf`; returns fn giving the count.
local function count_bufwritepost(buf)
  local n = 0
  local g = vim.api.nvim_create_augroup("spec_bwp_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = g,
    buffer = buf,
    callback = function()
      n = n + 1
    end,
  })
  return function()
    return n
  end
end


-- The plugin is set up once the way the README shows; every test starts with
-- auto-save off (tests that need it switch it on) so a debounce timer cannot
-- fire in the middle of a unit test.
if have_autosave then
  require("auto-save").setup({
    enabled = true,
    noautocmd = true,
    condition = dg.can_save,
    debounce_delay = 1000,
  })
end

describe("xyno-guard", function()
  before_each(function()
    if have_autosave then
      as().off()
    end
  end)
  after_each(function()
    if have_autosave then
      as().off()
    end
    for i = #env_undo, 1, -1 do
      env_undo[i]()
    end
    env_undo = {}
    pcall(function()
      for _, c in ipairs(vim.lsp.get_clients()) do
        c:stop(true)
      end
    end)
    vim.cmd("silent! %bwipeout!")
  end)

  describe("setup", function()
    it("exposes the documented API", function()
      H.eq("function", type(dg.setup))
      H.eq("function", type(dg.can_save))
      H.eq("function", type(dg.is_dependency))
      H.eq("function", type(dg.save_all))
    end)

    it("is safe to call again: one set of autocmds, in group xyno_guard", function()
      local function count()
        return #vim.api.nvim_get_autocmds({ group = "xyno_guard" })
      end
      local n = count()
      H.ok(n > 0, "autocmds registered")
      dg.setup()
      dg.setup({})
      H.eq(n, count())
    end)

    it("can_save is usable as auto-save's condition", function()
      need_autosave()
      H.ok(require("auto-save.config").opts.condition == dg.can_save)
    end)
  end)

  describe("autosave", function()
    it("3 writes about a second after a text change", function()
      need_autosave()
      local path, buf = open_file("one\n")
      as().on()
      set_lines(buf, { "changed" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      vim.wait(300)
      H.eq("one\n", read(path), "not saved before the debounce delay")
      H.wait_for(function()
        return read(path) == "changed\n"
      end, 4000, "autosave of the text change")
      H.not_ok(vim.bo[buf].modified)
    end)

    it("3 does not write when nothing changed and when auto-save is off", function()
      need_autosave()
      local path, buf = open_file("one\n")
      set_lines(buf, { "off" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      vim.wait(1500)
      H.eq("one\n", read(path))
      H.ok(vim.bo[buf].modified)
    end)

    it("21 never touches a dependency source, even when it was made modifiable and edited", function()
      need_autosave()
      local ch = H.tmpdir()
      env("CARGO_HOME", ch)
      local path = ch .. "/registry/src/index-1/crate-1.0.0/src/lib.rs"
      write(path, "pub fn a() {}\n")
      local buf = H.open(path)
      H.eq(false, vim.bo[buf].modifiable)
      vim.cmd("set modifiable")
      as().on()
      set_lines(buf, { "// edited" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      vim.api.nvim_exec_autocmds("BufLeave", { buffer = buf })
      vim.wait(2000)
      H.eq("pub fn a() {}\n", read(path))
      H.ok(vim.bo[buf].modified)
    end)
  end)

  -- ---------------------------------------------------------- 7, 8: dependency
  describe("is_dependency", function()
    it("7 recognises ~/.cargo/registry, ~/.cargo/git and ~/.rustup", function()
      local home = vim.uv.os_homedir()
      H.eq(true, dg.is_dependency(home .. "/.cargo/registry/src/index/x-1/src/lib.rs"))
      H.eq(true, dg.is_dependency(home .. "/.cargo/git/checkouts/x/abc/src/lib.rs"))
      H.eq(true, dg.is_dependency(home .. "/.rustup/toolchains/stable/lib/rustlib/src/rust/library/std/src/lib.rs"))
    end)

    it("7 does not match similar prefixes or project files", function()
      local home = vim.uv.os_homedir()
      H.eq(false, dg.is_dependency(home .. "/.cargo/registryx/a.rs"))
      H.eq(false, dg.is_dependency(home .. "/.cargo/gitx/a.rs"))
      H.eq(false, dg.is_dependency(home .. "/.rustupx/a.rs"))
      H.eq(false, dg.is_dependency(home .. "/.cargo/bin/a.rs"))
      H.eq(false, dg.is_dependency(home .. "/projects/foo/src/main.rs"))
      H.eq(false, dg.is_dependency("/tmp/.cargo/registry/a.rs"))
    end)

    it("7 honours $CARGO_HOME (registry, git) and $RUSTUP_HOME", function()
      local ch, rh = H.tmpdir(), H.tmpdir()
      H.eq(false, dg.is_dependency(ch .. "/registry/a.rs"))
      env("CARGO_HOME", ch .. "/") -- a trailing slash is tolerated
      env("RUSTUP_HOME", rh)
      H.eq(true, dg.is_dependency(ch .. "/registry/src/a.rs"))
      H.eq(true, dg.is_dependency(ch .. "/git/checkouts/a.rs"))
      H.eq(true, dg.is_dependency(rh .. "/toolchains/a.rs"))
      H.eq(false, dg.is_dependency(ch .. "/registryx/a.rs"))
      H.eq(false, dg.is_dependency(ch .. "/bin/a.rs"))
      H.eq(false, dg.is_dependency(rh .. "x/a.rs"))
    end)

    it("8 a dependency buffer is nomodifiable and readonly; :set modifiable allows editing; can_save stays false", function()
      local ch = H.tmpdir()
      env("CARGO_HOME", ch)
      local path = ch .. "/registry/src/index-1/c-1.0.0/src/lib.rs"
      write(path, "pub fn a() {}\n")
      local buf = H.open(path)
      H.eq(false, vim.bo[buf].modifiable)
      H.eq(true, vim.bo[buf].readonly)
      H.throws(function()
        set_lines(buf, { "nope" })
      end, "modifiable")
      vim.cmd("set modifiable")
      set_lines(buf, { "// hacked" })
      H.eq({ "// hacked" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      H.eq(false, dg.can_save(buf))
    end)

    it("8 setup() locks a dependency buffer that was loaded before it ran", function()
      local ch = H.tmpdir()
      env("CARGO_HOME", ch)
      local path = ch .. "/registry/src/index-1/c-1.0.0/src/lib.rs"
      write(path, "pub fn a() {}\n")
      pcall(vim.api.nvim_del_augroup_by_name, "xyno_guard") -- as if the guard was not loaded yet
      local buf = H.open(path)
      H.eq(true, vim.bo[buf].modifiable)
      H.eq(false, vim.bo[buf].readonly)
      dg.setup()
      H.eq(false, vim.bo[buf].modifiable)
      H.eq(true, vim.bo[buf].readonly)
    end)

    it("8 a buffer outside the dependency roots stays modifiable", function()
      local _, buf = open_file("x\n")
      H.eq(true, vim.bo[buf].modifiable)
      H.eq(false, vim.bo[buf].readonly)
    end)
  end)

  -- ------------------------------------------------------ 9, 10, 11, 12: stamps
  describe("can_save", function()
    it("9 is false for buffers with a buftype and true for a no-name one (the plugin handles that)", function()
      local scratch = vim.api.nvim_create_buf(false, true)
      H.eq(false, dg.can_save(scratch))
      local noname = vim.api.nvim_create_buf(true, false)
      H.eq(true, dg.can_save(noname))
      local named_nofile = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(named_nofile, H.tmpdir() .. "/virt")
      vim.bo[named_nofile].buftype = "nofile"
      H.eq(false, dg.can_save(named_nofile))
      H.is_nil(vim.b[named_nofile].xyno_guard_stamp)
    end)

    it("9 is false for an acwrite + readonly buffer like a plugin's prompt buffer (a :write raised a blocking confirm)", function()
      local b = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(b, "99-prompt")
      vim.bo[b].buftype = "acwrite"
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "x" })
      H.eq(false, dg.can_save(b))
      vim.bo[b].buftype = ""
      vim.bo[b].readonly = true
      H.eq(false, dg.can_save(b), "a readonly file buffer")
      vim.api.nvim_buf_delete(b, { force = true })
    end)

    it("9 records the mtime as sec.nsec on BufReadPost", function()
      local path, buf = open_file()
      local s = vim.b[buf].xyno_guard_stamp
      H.match(s, "^%d+%.%d%d%d%d%d%d%d%d%d$")
      H.eq(stamp_of(path), s)
    end)

    it("9 re-records on BufWritePost", function()
      local path, buf = open_file()
      external_write(path, "other\n")
      H.not_ok(vim.b[buf].xyno_guard_stamp == stamp_of(path))
      vim.cmd("silent write!")
      H.eq(stamp_of(path), vim.b[buf].xyno_guard_stamp)
    end)

    it("9 re-records on BufFilePost", function()
      local path, buf = open_file()
      local other = vim.fs.dirname(path) .. "/g.txt"
      write(other, "g\n")
      vim.b[buf].xyno_guard_stamp = nil
      vim.cmd("silent file " .. vim.fn.fnameescape(other))
      H.eq(stamp_of(other), vim.b[buf].xyno_guard_stamp)
    end)

    it("9 re-records on FileChangedShellPost", function()
      local path, buf = open_file()
      vim.b[buf].xyno_guard_stamp = nil
      vim.api.nvim_exec_autocmds("FileChangedShellPost", { buffer = buf })
      H.eq(stamp_of(path), vim.b[buf].xyno_guard_stamp)
    end)

    it("10 with no stamp yet records one and returns true", function()
      local path, buf = open_file()
      vim.b[buf].xyno_guard_stamp = nil
      H.eq(true, dg.can_save(buf))
      H.eq(stamp_of(path), vim.b[buf].xyno_guard_stamp)
    end)

    it("10 an unchanged mtime returns true, silently", function()
      local _, buf = open_file()
      local cap = H.capture_notify()
      H.eq(true, dg.can_save(buf))
      H.eq(true, dg.can_save(buf))
      H.eq({}, cap.list)
      cap.restore()
    end)

    it("11 a change on disk after the stamp: false and one warning per mtime", function()
      local path, buf = open_file()
      local cap = H.capture_notify()
      external_write(path, "changed\n")
      local short = vim.fn.fnamemodify(path, ":~:.")
      local msg = short
        .. " changed on disk while this buffer has unsaved edits: auto-save is paused for it (:w! keeps the buffer, :e! takes the disk version)"
      H.eq(false, dg.can_save(buf))
      H.eq({ msg }, warnings(cap))
      H.eq(false, dg.can_save(buf))
      H.eq(false, dg.can_save(buf))
      H.eq({ msg }, warnings(cap), "not repeated for the same mtime")
      external_write(path, "changed again\n")
      H.eq(false, dg.can_save(buf))
      H.eq({ msg, msg }, warnings(cap), "a newer change warns again")
      cap.restore()
    end)

    it("11 becomes true again once the buffer was written (:w! keeps the buffer)", function()
      local path, buf = open_file()
      external_write(path, "disk\n")
      H.eq(false, dg.can_save(buf))
      set_lines(buf, { "mine" })
      vim.cmd("silent write!")
      H.eq("mine\n", read(path))
      H.eq(true, dg.can_save(buf))
    end)

    it("12 a deleted file: false and one warning", function()
      local path, buf = open_file()
      local cap = H.capture_notify()
      os.remove(path)
      local msg = vim.fn.fnamemodify(path, ":~:.") .. " no longer exists on disk: auto-save is paused for this buffer (:w to recreate it)"
      H.eq(false, dg.can_save(buf))
      H.eq(false, dg.can_save(buf))
      H.eq({ msg }, warnings(cap))
      cap.restore()
    end)

    it("12 autosave does not recreate a deleted file", function()
      need_autosave()
      local path, buf = open_file()
      local cap = H.capture_notify()
      os.remove(path)
      as().on()
      set_lines(buf, { "edit" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      vim.wait(1800)
      H.eq(nil, vim.uv.fs_stat(path))
      H.ok(vim.bo[buf].modified)
      H.eq(1, #vim.tbl_filter(function(m)
        return m:find("no longer exists on disk", 1, true)
      end, warnings(cap)))
      cap.restore()
    end)
  end)

  -- ---------------------------------------------------- 13, 14: the write guard
  describe("AutoSaveWritePre / Post", function()
    local function fire(pattern, buf)
      vim.api.nvim_exec_autocmds("User", { pattern = pattern, data = { saved_buffer = buf } })
    end

    it("13 Pre with can_save false switches buftype to nowrite (saved), Post restores it", function()
      local path, buf = open_file()
      local cap = H.capture_notify()
      external_write(path, "disk\n")
      fire("AutoSaveWritePre", buf)
      H.eq("nowrite", vim.bo[buf].buftype)
      H.eq("", vim.b[buf].xyno_guard_buftype)
      set_lines(buf, { "mine" })
      vim.cmd("silent! write")
      H.eq("disk\n", read(path), "a nowrite buffer cannot be written")
      fire("AutoSaveWritePost", buf)
      H.eq("", vim.bo[buf].buftype)
      H.is_nil(vim.b[buf].xyno_guard_buftype)
      cap.restore()
    end)

    it("13 Pre with can_save true leaves the buftype alone, Post records the stamp", function()
      local path, buf = open_file()
      fire("AutoSaveWritePre", buf)
      H.eq("", vim.bo[buf].buftype)
      H.is_nil(vim.b[buf].xyno_guard_buftype)
      external_write(path, "now\n")
      fire("AutoSaveWritePost", buf)
      H.eq(stamp_of(path), vim.b[buf].xyno_guard_stamp)
    end)

    it("13/14 a file changed inside the debounce window is not overwritten, no W12 prompt, buffer stays modified", function()
      need_autosave()
      local path, buf = open_file("one\n")
      local cap = H.capture_notify()
      H.clear_messages()
      as().on()
      set_lines(buf, { "mine" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf }) -- condition passes: timer starts
      external_write(path, "theirs\n") -- ... then the file changes before the write
      vim.wait(2000)
      H.eq("theirs\n", read(path))
      H.eq(true, vim.bo[buf].modified, "a refused write leaves modified=true")
      H.eq("", vim.bo[buf].buftype)
      H.is_nil(vim.b[buf].xyno_guard_buftype)
      H.no_match(H.messages(), "Do you really want to write", true)
      H.eq({ "mine" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      cap.restore()
    end)

    it("14 a listener on AutoSaveWritePost tells a refused write by `modified` still being set", function()
      need_autosave()
      local path, buf = open_file("one\n")
      local cap = H.capture_notify()
      local seen = {}
      local g = vim.api.nvim_create_augroup("spec_post_listener", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = g,
        pattern = "AutoSaveWritePost",
        callback = function(ev)
          seen[#seen + 1] = vim.bo[ev.data.saved_buffer].modified
        end,
      })
      as().on()
      set_lines(buf, { "mine" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      external_write(path, "theirs\n")
      vim.wait(2000)
      H.eq({ true }, seen, "refused: still modified")
      -- take the buffer's side with :w!, then an autosave goes through
      vim.cmd("silent write!")
      set_lines(buf, { "mine again" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      H.wait_for(function()
        return read(path) == "mine again\n"
      end, 4000, "autosave after :w!")
      H.eq({ true, false }, seen, "written: no longer modified")
      pcall(vim.api.nvim_del_augroup_by_name, "spec_post_listener")
      cap.restore()
    end)
  end)

  -- ----------------------------------------------------- 15: FileChangedShell
  describe("FileChangedShell", function()
    -- Observes (and neutralises, so nothing can prompt) what the guard decided.
    -- Registered after the guard's autocmd, so it runs after it.
    local function spy()
      local seen = {}
      vim.api.nvim_create_autocmd("FileChangedShell", {
        group = vim.api.nvim_create_augroup("spec_fcs_spy", { clear = true }),
        callback = function()
          seen[#seen + 1] = { reason = vim.v.fcs_reason, choice = vim.v.fcs_choice }
          vim.v.fcs_choice = ""
        end,
      })
      return seen
    end
    after_each(function()
      pcall(vim.api.nvim_del_augroup_by_name, "spec_fcs_spy")
    end)

    it("15 conflict (modified buffer, file changed): no prompt, choice '', one warning, edits kept", function()
      local path, buf = open_file()
      local seen = spy()
      local cap = H.capture_notify()
      set_lines(buf, { "unsaved" })
      external_write(path, "disk\n")
      vim.cmd("checktime")
      H.eq({ { reason = "conflict", choice = "" } }, seen)
      H.eq({
        vim.fn.fnamemodify(path, ":~:.") .. " changed on disk and the buffer has unsaved edits (:e! takes the disk version, :w! keeps the buffer)",
      }, warnings(cap))
      H.eq({ "unsaved" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      H.eq(false, dg.can_save(buf))
      H.eq(1, #warnings(cap), "can_save does not repeat the warning")
      cap.restore()
    end)

    it("15 deleted: no prompt, choice '', warning, buffer kept", function()
      local path, buf = open_file()
      local seen = spy()
      local cap = H.capture_notify()
      os.remove(path)
      vim.cmd("checktime")
      H.eq({ { reason = "deleted", choice = "" } }, seen)
      H.eq({ vim.fn.fnamemodify(path, ":~:.") .. " was deleted on disk (the buffer is kept)" }, warnings(cap))
      H.eq(true, vim.api.nvim_buf_is_loaded(buf))
      H.eq({ "one", "two" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      cap.restore()
    end)

    it("15 other reasons: 'ask' without autoread (with autoread nvim reloads without the event)", function()
      local path, buf = open_file()
      local seen = spy()
      local old = vim.o.autoread
      H._restore[#H._restore + 1] = function()
        vim.o.autoread = old
      end
      vim.o.autoread = true
      external_write(path, "disk1\n")
      vim.cmd("checktime")
      H.eq({}, seen, "autoread: reloaded natively, no event")
      H.eq({ "disk1" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.o.autoread = false
      external_write(path, "disk2\n")
      vim.cmd("checktime")
      H.eq(1, #seen)
      H.eq("ask", seen[1].choice)
      H.ok(seen[1].reason ~= "conflict" and seen[1].reason ~= "deleted")
      vim.o.autoread = old
    end)

    it("15 an unmodified buffer reloads after an external change and :checktime", function()
      local path, buf = open_file()
      external_write(path, "from disk\n")
      vim.cmd("checktime")
      H.wait_for(function()
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "from disk"
      end, 3000, "reload")
      H.not_ok(vim.bo[buf].modified)
      H.eq(stamp_of(path), vim.b[buf].xyno_guard_stamp)
      H.eq(true, dg.can_save(buf))
    end)


  end)

  -- ------------------------------------------------------- 17, 18, 20: save_all
  describe("save_all", function()
    it("17 writes modified file buffers with events; skips unmodified, dependency and externally changed ones", function()
      local ch = H.tmpdir()
      env("CARGO_HOME", ch)
      local dir = H.tmpdir()
      local pa, pb, pc, pd, pe = dir .. "/a.txt", dir .. "/b.txt", dir .. "/c.txt", dir .. "/d.txt", ch .. "/registry/src/x/lib.rs"
      write(pa, "a\n")
      write(pb, "b\n")
      write(pc, "c\n")
      write(pd, "d\n")
      write(pe, "e\n")
      local ba, _, bc, _, be = H.open(pa), H.open(pb), H.open(pc), H.open(pd), H.open(pe)
      local logs = fake_lsp(ba, "fake-save", { includeText = false })
      local npost = count_bufwritepost(ba)
      set_lines(ba, { "A" }) -- modified: written
      set_lines(bc, { "C" }) -- modified but changed on disk: skipped
      external_write(pc, "C-disk\n")
      vim.cmd("set modifiable") -- dependency buffer made editable on purpose
      set_lines(be, { "E" }) -- modified dependency: skipped
      -- bb, bd unmodified: untouched
      local mt = stamp_of(pb)
      dg.save_all()
      H.eq("A\n", read(pa))
      H.eq("b\n", read(pb))
      H.eq("C-disk\n", read(pc))
      H.eq("d\n", read(pd))
      H.eq("e\n", read(pe))
      H.eq(mt, stamp_of(pb))
      H.not_ok(vim.bo[ba].modified)
      H.ok(vim.bo[bc].modified)
      H.ok(vim.bo[be].modified)
      H.eq(1, npost(), "BufWritePost fired (write, not noautocmd)")
      H.eq(1, count(logs, "textDocument/didSave"), "didSave was sent")
    end)

    it("17 skips unloaded, non-file and nomodifiable buffers", function()
      local path, buf = open_file("x\n")
      local scratch = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "s" })
      set_lines(buf, { "X" })
      vim.bo[buf].modifiable = true
      local path2 = vim.fs.dirname(path) .. "/n.txt"
      write(path2, "n\n")
      local nb = H.open(path2)
      set_lines(nb, { "N" })
      vim.bo[nb].modifiable = false
      dg.save_all()
      H.eq("X\n", read(path))
      H.eq("n\n", read(path2))
    end)

    describe("wrapping apply_workspace_edit (18)", function()
      local orig_save_all
      before_each(function()
        orig_save_all = dg.save_all
        local calls = 0
        dg.save_all = function()
          calls = calls + 1
        end
        dg._calls = function()
          return calls
        end
      end)
      after_each(function()
        dg.save_all = orig_save_all
        dg._calls = nil
      end)

      -- the wrapper's captured original, via its upvalue
      local function orig_of(wrapper)
        local i = 1
        while true do
          local n, v = debug.getupvalue(wrapper, i)
          if not n then
            return nil
          end
          if n == "orig" then
            return v, i
          end
          i = i + 1
        end
      end

      local function attach_fake(name)
        local path, buf = open_file("x\n")
        fake_lsp(buf, name, false)
        return path, buf
      end

      it("18 wraps once after the first LspAttach, and stays wrapped once however many attach", function()
        attach_fake("fake-1")
        local w = vim.lsp.util.apply_workspace_edit
        local orig = orig_of(w)
        H.ok(orig, "wrapper found")
        H.ok(debug.getinfo(orig, "S").source:find("xyno_guard/init.lua", 1, true) == nil, "original is not a wrapper")
        attach_fake("fake-2")
        vim.api.nvim_exec_autocmds("LspAttach", { buffer = vim.api.nvim_get_current_buf(), data = { client_id = 1 } })
        H.ok(vim.lsp.util.apply_workspace_edit == w, "not wrapped again")
        H.ok(debug.getinfo(orig_of(w), "S").source:find("xyno_guard/init.lua", 1, true) == nil)
      end)

      it("18 a changes edit on another file schedules save_all", function()
        local path, buf = attach_fake("fake-1")
        local other = vim.uri_from_fname(vim.fs.dirname(path) .. "/other.txt")
        vim.lsp.util.apply_workspace_edit({ changes = { [other] = {} } }, "utf-16")
        H.eq(0, dg._calls(), "scheduled, not synchronous")
        H.wait_for(function()
          return dg._calls() == 1
        end, 2000, "save_all")
        H.ok(buf)
      end)

      it("18 a documentChanges edit on another file, and create/rename/delete kinds, schedule save_all", function()
        local path = attach_fake("fake-1")
        local dir = vim.fs.dirname(path)
        local other = vim.uri_from_fname(dir .. "/other.txt")
        vim.lsp.util.apply_workspace_edit({
          documentChanges = { { textDocument = { uri = other, version = vim.NIL }, edits = {} } },
        }, "utf-16")
        H.wait_for(function()
          return dg._calls() == 1
        end, 2000, "save_all after documentChanges")
        local created = dir .. "/new.txt"
        vim.lsp.util.apply_workspace_edit({ documentChanges = { { kind = "create", uri = vim.uri_from_fname(created) } } }, "utf-16")
        H.wait_for(function()
          return dg._calls() == 2
        end, 2000, "save_all after create")
        H.ok(vim.uv.fs_stat(created), "the create was applied")
        local renamed = dir .. "/renamed.txt"
        vim.lsp.util.apply_workspace_edit({
          documentChanges = { { kind = "rename", oldUri = vim.uri_from_fname(created), newUri = vim.uri_from_fname(renamed) } },
        }, "utf-16")
        H.wait_for(function()
          return dg._calls() == 3
        end, 2000, "save_all after rename")
        vim.lsp.util.apply_workspace_edit({ documentChanges = { { kind = "delete", uri = vim.uri_from_fname(renamed) } } }, "utf-16")
        H.wait_for(function()
          return dg._calls() == 4
        end, 2000, "save_all after delete")
      end)

      it("18 an edit confined to the current buffer does not schedule save_all", function()
        local _, buf = attach_fake("fake-1")
        local cur = vim.uri_from_bufnr(buf)
        vim.lsp.util.apply_workspace_edit({ changes = { [cur] = {} } }, "utf-16")
        vim.lsp.util.apply_workspace_edit({
          documentChanges = { { textDocument = { uri = cur, version = vim.NIL }, edits = {} } },
        }, "utf-16")
        vim.wait(300)
        H.eq(0, dg._calls())
      end)

      it("18 preserves the original's return value", function()
        attach_fake("fake-1")
        local w = vim.lsp.util.apply_workspace_edit
        local orig, idx = orig_of(w)
        debug.setupvalue(w, idx, function()
          return "sentinel"
        end)
        local ok, res = pcall(w, { changes = {} }, "utf-16")
        debug.setupvalue(w, idx, orig)
        H.ok(ok, tostring(res))
        H.eq("sentinel", res)
      end)
    end)

    it("20 buffers loaded before setup() are recorded by setup()", function()
      local path, buf = open_file()
      vim.b[buf].xyno_guard_stamp = nil
      dg.setup()
      H.eq(stamp_of(path), vim.b[buf].xyno_guard_stamp)
      -- and the events still work afterwards
      external_write(path, "z\n")
      vim.cmd("silent write!")
      H.eq(stamp_of(path), vim.b[buf].xyno_guard_stamp)
    end)
  end)
end)
