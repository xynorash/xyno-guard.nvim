-- xyno-guard: options, stat-based staleness beyond mtime, nowrite recovery, FileChangedShell contract,
-- statusline / highlights, :checkhealth.
local H = require("xynotest.helpers")
local dg = require("xyno_guard")

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end
local function open_file(text, name)
  local path = H.tmpdir() .. "/" .. (name or "f.txt")
  write(path, text or "one\ntwo\n")
  local whole = os.time() - 100 -- whole seconds: utime can put exactly this mtime back
  assert(vim.uv.fs_utime(path, whole, whole))
  return path, H.open(path)
end
local function mtime(path)
  return assert(vim.uv.fs_stat(path)).mtime
end
--- rewrite `text` keeping the old mtime (what rsync -t / touch -r / a coarse-clock fs does)
local function sneaky_write(path, text)
  local t = mtime(path)
  write(path, text)
  assert(vim.uv.fs_utime(path, t.sec + t.nsec / 1e9, t.sec + t.nsec / 1e9))
end
local function warns(cap)
  local out = {}
  for _, n in ipairs(cap.list) do
    if n.level == vim.log.levels.WARN then
      out[#out + 1] = n.msg
    end
  end
  return out
end
local function dirty(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "mine" })
end

describe("xyno-guard options", function()
  before_each(function()
    dg.setup()
  end)
  after_each(function()
    dg.setup()
  end)

  it("bad values are reported once and ignored, defaults stay", function()
    local cap = H.capture_notify()
    dg.setup({ hash_max_bytes = "lots", reload_unmodified = "sometimes", bogus = 1, dependency_roots = { 3 } })
    local w = warns(cap)
    cap.restore()
    H.eq(1, #w)
    H.match(w[1], "hash_max_bytes")
    H.match(w[1], "reload_unmodified")
    H.match(w[1], "unknown option bogus")
    H.match(w[1], "dependency_roots")
    H.eq(dg.defaults.hash_max_bytes, dg.config.hash_max_bytes)
    H.eq("autoread", dg.config.reload_unmodified)
  end)

  it("setup() without options resets earlier options", function()
    dg.setup({ hash_max_bytes = 0 })
    H.eq(0, dg.config.hash_max_bytes)
    dg.setup()
    H.eq(dg.defaults.hash_max_bytes, dg.config.hash_max_bytes)
  end)

  it("dependency_roots: extra directories are dependency sources and get locked", function()
    local dir = H.tmpdir() .. "/vendor"
    write(dir .. "/a.rs", "x\n")
    dg.setup({ dependency_roots = { dir } })
    H.eq(true, dg.is_dependency(dir .. "/a.rs"))
    H.eq(false, dg.is_dependency(dir .. "x/a.rs"), "prefix of a name is not the directory")
    local buf = H.open(dir .. "/a.rs")
    H.eq(false, vim.bo[buf].modifiable)
    H.eq(false, dg.can_save(buf))
  end)

  it("lock_dependencies = false leaves the buffer editable, can_save still refuses", function()
    local dir = H.tmpdir() .. "/vendor"
    write(dir .. "/a.rs", "x\n")
    dg.setup({ dependency_roots = { dir }, lock_dependencies = false })
    local buf = H.open(dir .. "/a.rs")
    H.eq(true, vim.bo[buf].modifiable)
    H.eq(false, dg.can_save(buf))
  end)

  it("notify = false is silent, notify = function receives the message", function()
    local path, buf = open_file()
    dg.setup({ notify = false })
    local cap = H.capture_notify()
    dirty(buf)
    os.remove(path)
    H.eq(false, dg.can_save(buf))
    H.eq({}, warns(cap))
    cap.restore()

    local got = {}
    dg.setup({
      notify = function(msg, level)
        got[#got + 1] = { msg, level }
      end,
    })
    local path2, buf2 = open_file(nil, "g.txt")
    dirty(buf2)
    os.remove(path2)
    H.eq(false, dg.can_save(buf2))
    H.eq(1, #got)
    H.match(got[1][1], "no longer exists")
    H.eq(vim.log.levels.WARN, got[1][2])
  end)

  it("icons override the statusline text", function()
    dg.setup({ icons = { stale = "CHANGED" } })
    local path, buf = open_file()
    dirty(buf)
    sneaky_write(path, "other, longer content\n")
    H.eq("stale", dg.state(buf))
    H.eq("CHANGED", dg.statusline(buf))
    H.eq("DEP RO", dg.config.icons.dependency)
  end)
end)

describe("xyno-guard staleness beyond the mtime", function()
  before_each(function()
    dg.setup()
  end)

  it("same mtime, different size: stale", function()
    local path, buf = open_file()
    dirty(buf)
    local cap = H.capture_notify()
    sneaky_write(path, "a much longer line than before\n")
    H.eq(false, dg.can_save(buf))
    H.eq(1, #warns(cap))
    cap.restore()
  end)

  it("same mtime and size, different bytes: the ctime catches it", function()
    local path, buf = open_file("aaaa\n")
    dirty(buf)
    local cap = H.capture_notify()
    sneaky_write(path, "bbbb\n")
    H.eq(false, dg.can_save(buf))
    cap.restore()
  end)

  it("compare.ctime = false: a same-size same-mtime rewrite is not seen (documented limit)", function()
    dg.setup({ compare = { ctime = false, inode = false } })
    local path, buf = open_file("aaaa\n")
    dirty(buf)
    sneaky_write(path, "bbbb\n")
    H.eq(true, dg.can_save(buf))
  end)

  it("same mtime, size and bytes, new inode (atomic replace): stale only through the inode", function()
    dg.setup({ compare = { ctime = false }, hash_max_bytes = 0 })
    local path, buf = open_file("aaaa\n")
    dirty(buf)
    local t = mtime(path)
    local tmp = path .. ".new"
    write(tmp, "bbbb\n")
    assert(vim.uv.fs_utime(tmp, t.sec + t.nsec / 1e9, t.sec + t.nsec / 1e9))
    assert(os.rename(tmp, path))
    local cap = H.capture_notify()
    H.eq(false, dg.can_save(buf))
    cap.restore()
  end)

  it("a touch (new mtime, identical bytes) is not a change: allowed, no warning, stamp refreshed", function()
    local path, buf = open_file()
    dirty(buf)
    local t = os.time() + 500
    assert(vim.uv.fs_utime(path, t, t))
    local cap = H.capture_notify()
    H.eq(true, dg.can_save(buf))
    H.eq({}, warns(cap))
    cap.restore()
    H.eq(string.format("%d.%09d", t, 0), vim.b[buf].xyno_guard_stamp)
  end)

  it("hash_max_bytes = 0: the same touch is stale (stat only)", function()
    dg.setup({ hash_max_bytes = 0 })
    local path, buf = open_file()
    dirty(buf)
    local t = os.time() + 600
    assert(vim.uv.fs_utime(path, t, t))
    local cap = H.capture_notify()
    H.eq(false, dg.can_save(buf))
    cap.restore()
  end)

  it("a file above hash_max_bytes gets no hash and a touch is stale", function()
    dg.setup({ hash_max_bytes = 4 })
    local path, buf = open_file("0123456789\n")
    H.is_nil(vim.b[buf].xyno_guard_snap.hash)
    dirty(buf)
    local t = os.time() + 700
    assert(vim.uv.fs_utime(path, t, t))
    local cap = H.capture_notify()
    H.eq(false, dg.can_save(buf))
    cap.restore()
  end)

  it("files with NUL bytes hash fine and differ when a byte differs", function()
    local path, buf = open_file("a\0b\n")
    H.ok(vim.b[buf].xyno_guard_snap.hash, "hash recorded")
    dirty(buf)
    sneaky_write(path, "a\0c\n")
    local cap = H.capture_notify()
    H.eq(false, dg.can_save(buf))
    cap.restore()
  end)

  it("a stale change that is reverted to the recorded bytes is allowed again", function()
    local path, buf = open_file("same\n")
    dirty(buf)
    local t = os.time() + 800
    write(path, "different\n")
    assert(vim.uv.fs_utime(path, t, t))
    local cap = H.capture_notify()
    H.eq(false, dg.can_save(buf))
    write(path, "same\n")
    H.eq(true, dg.can_save(buf))
    cap.restore()
  end)
end)

describe("xyno-guard nowrite recovery", function()
  before_each(function()
    dg.setup()
  end)
  local function fire(pattern, buf)
    vim.api.nvim_exec_autocmds("User", { pattern = pattern, data = { saved_buffer = buf } })
  end

  it("Pre without Post: buftype is back on the next tick and a manual :w works", function()
    local path, buf = open_file()
    local cap = H.capture_notify()
    dirty(buf)
    write(path, "changed on disk, longer\n")
    fire("AutoSaveWritePre", buf)
    H.eq("nowrite", vim.bo[buf].buftype)
    H.eq(1, #dg.stuck_nowrite())
    H.wait_for(function()
      return vim.bo[buf].buftype == ""
    end, 1000, "buftype restored without AutoSaveWritePost")
    H.eq(0, #dg.stuck_nowrite())
    H.is_nil(vim.b[buf].xyno_guard_buftype)
    vim.cmd("silent write!")
    H.eq("mine\n", assert(io.open(path)):read("*a"))
    cap.restore()
  end)

  it("restore_nowrite() gives every stuck buffer its buftype back", function()
    local path, buf = open_file()
    local cap = H.capture_notify()
    dirty(buf)
    write(path, "changed on disk, longer\n")
    fire("AutoSaveWritePre", buf)
    H.eq(1, dg.restore_nowrite())
    H.eq("", vim.bo[buf].buftype)
    H.eq(0, dg.restore_nowrite())
    cap.restore()
  end)

  it("two Pre events in a row keep the original buftype", function()
    local path, buf = open_file()
    local cap = H.capture_notify()
    dirty(buf)
    write(path, "changed on disk, longer\n")
    fire("AutoSaveWritePre", buf)
    fire("AutoSaveWritePre", buf)
    fire("AutoSaveWritePost", buf)
    H.eq("", vim.bo[buf].buftype)
    cap.restore()
  end)
end)

describe("xyno-guard FileChangedShell", function()
  local function spy()
    local seen = {}
    vim.api.nvim_create_autocmd("FileChangedShell", {
      group = vim.api.nvim_create_augroup("spec_fcs_spy2", { clear = true }),
      callback = function()
        seen[#seen + 1] = vim.v.fcs_choice
        vim.v.fcs_choice = vim.v.fcs_choice == "ask" and "" or vim.v.fcs_choice -- an "ask" would block
      end,
    })
    return seen
  end
  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "spec_fcs_spy2")
    dg.setup()
  end)

  local function ext(path, text)
    write(path, text)
    local t = os.time() + 900
    assert(vim.uv.fs_utime(path, t, t))
  end

  it("never answers 'ask', whatever the reason", function()
    dg.setup()
    local path = open_file()
    local seen = spy()
    local old = vim.o.autoread
    H._restore[#H._restore + 1] = function()
      vim.o.autoread = old
    end
    vim.o.autoread = false
    ext(path, "x\n")
    vim.cmd("checktime")
    H.eq({ "" }, seen)
    H.ok(not vim.tbl_contains(seen, "ask"))
  end)

  it('reload_unmodified = "always" reloads even without autoread', function()
    dg.setup({ reload_unmodified = "always" })
    local path, buf = open_file()
    local old = vim.o.autoread
    H._restore[#H._restore + 1] = function()
      vim.o.autoread = old
    end
    vim.o.autoread = false
    ext(path, "from disk\n")
    vim.cmd("checktime")
    H.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "from disk"
    end, 3000, "reload")
    H.is_nil(vim.b[buf].xyno_guard_state)
  end)

  it("file_changed_shell = false installs no handler", function()
    dg.setup({ file_changed_shell = false })
    local n = #vim.api.nvim_get_autocmds({ group = "xyno_guard", event = "FileChangedShell" })
    H.eq(0, n)
  end)
end)

describe("xyno-guard statusline and highlights", function()
  before_each(function()
    vim.wo.winhighlight = ""
    dg.setup()
  end)

  it("groups exist, link to theme groups by default, and survive :hi clear", function()
    local want = { XynoGuardDependency = "DiagnosticInfo", XynoGuardStale = "DiagnosticWarn", XynoGuardGone = "DiagnosticError" }
    for g, link in pairs(want) do
      H.eq(link, vim.api.nvim_get_hl(0, { name = g, link = true }).link)
    end
    vim.cmd("hi clear")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    for g, link in pairs(want) do
      H.eq(link, vim.api.nvim_get_hl(0, { name = g, link = true }).link)
    end
  end)

  it("a user colour for a group is kept (default link)", function()
    vim.api.nvim_set_hl(0, "XynoGuardStale", { fg = "#123456" })
    dg.setup()
    H.eq(0x123456, vim.api.nvim_get_hl(0, { name = "XynoGuardStale" }).fg)
    vim.api.nvim_set_hl(0, "XynoGuardStale", { link = "DiagnosticWarn" })
  end)

  it("a dependency buffer: statusline text, highlight, window highlight", function()
    local dir = H.tmpdir() .. "/reg"
    write(dir .. "/a.rs", "x\n")
    dg.setup({ dependency_roots = { dir } })
    local buf = H.open(dir .. "/a.rs")
    H.eq("DEP RO", dg.statusline(buf))
    H.eq("XynoGuardDependency", dg.statusline_hl(buf))
    H.match(vim.wo.winhighlight, "LineNr:XynoGuardDependency")
    H.match(vim.wo.winhighlight, "CursorLineNr:XynoGuardDependency")
    local plain = H.open(H.tmpdir() .. "/p.txt")
    H.eq("", dg.statusline(plain))
    H.is_nil(dg.statusline_hl(plain))
    H.eq("", vim.wo.winhighlight, "the window highlight is gone on a normal buffer")
  end)

  it("stale then fixed: state, event and winhighlight follow; user winhighlight entries are kept", function()
    local path, buf = open_file()
    vim.wo.winhighlight = "Normal:NormalFloat"
    dg.state(buf)
    local events = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "XynoGuardState",
      callback = function(ev)
        events[#events + 1] = ev.data.state or "nil"
      end,
    })
    dirty(buf)
    write(path, "something else entirely\n")
    H.eq("stale", dg.state(buf))
    H.eq("STALE", dg.statusline(buf))
    H.match(vim.wo.winhighlight, "Normal:NormalFloat")
    H.match(vim.wo.winhighlight, "LineNr:XynoGuardStale")
    vim.cmd("silent write!")
    H.is_nil(vim.b[buf].xyno_guard_state)
    H.eq("Normal:NormalFloat", vim.wo.winhighlight)
    H.eq({ "stale", "nil" }, events)
    vim.api.nvim_del_autocmd(id)
  end)

  it("deleted file: state gone, statusline GONE", function()
    local path, buf = open_file()
    os.remove(path)
    H.eq("gone", dg.state(buf))
    H.eq("GONE", dg.statusline(buf))
    H.eq("XynoGuardGone", dg.statusline_hl(buf))
  end)

  it("highlights = false sets no window highlight", function()
    local dir = H.tmpdir() .. "/reg"
    write(dir .. "/a.rs", "x\n")
    dg.setup({ dependency_roots = { dir }, highlights = false })
    H.open(dir .. "/a.rs")
    H.eq("", vim.wo.winhighlight)
  end)

  it("state/statusline of non-file and invalid buffers are nil/empty", function()
    local b = vim.api.nvim_create_buf(false, true)
    H.is_nil(dg.state(b))
    H.eq("", dg.statusline(b))
    H.eq("", dg.statusline(99999))
  end)
end)

describe("xyno-guard :checkhealth", function()
  local function report()
    vim.cmd("silent checkhealth xyno_guard")
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    vim.cmd("bwipeout!")
    return table.concat(lines, "\n")
  end

  it("reports a healthy setup", function()
    dg.setup()
    local out = report()
    H.match(out, "xyno%-guard")
    H.match(out, "setup%(%) has run")
    H.match(out, "no buffer is stuck in buftype=nowrite")
    H.no_match(out, "ERROR", true)
  end)

  it("reports a stuck nowrite buffer and a stale buffer", function()
    dg.setup({ nowrite_restore_ms = 0 })
    local path, buf = open_file()
    dirty(buf)
    write(path, "changed on disk, longer\n")
    vim.b[buf].xyno_guard_buftype = ""
    local out = report()
    H.match(out, "still 'buftype=nowrite'")
    H.match(out, "changed on disk, auto%-save is paused")
    vim.b[buf].xyno_guard_buftype = nil
    dg.setup()
  end)
end)
