-- :checkhealth xyno_guard
local M = {}

function M.check()
  local h = vim.health
  local g = require("xyno_guard")
  h.start("xyno-guard")

  if vim.fn.has("nvim-0.12") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.12 or newer is required", { "Update Neovim." })
  end

  if pcall(vim.api.nvim_get_autocmds, { group = "xyno_guard" }) then
    h.ok("setup() has run (augroup xyno_guard exists)")
  else
    h.error("setup() has not run: nothing is guarded", { 'Call require("xyno_guard").setup() at startup.' })
    return
  end

  local c = g.config
  h.info(
    ("hash_max_bytes = %d, compare = size:%s inode:%s ctime:%s, reload_unmodified = %s, nowrite_restore_ms = %d"):format(
      c.hash_max_bytes,
      tostring(c.compare.size),
      tostring(c.compare.inode),
      tostring(c.compare.ctime),
      c.reload_unmodified,
      c.nowrite_restore_ms
    )
  )
  if c.hash_max_bytes == 0 then
    h.warn("the content hash is off: a touch, chmod or no-op rewrite of a file counts as a change on disk")
  end
  if pcall(vim.fn.sha256, "x") then
    h.ok("sha256() available (content hash of small files)")
  else
    h.warn("sha256() is not available in this Neovim: only stat data is compared")
  end

  -- is the guard wired into an auto-save plugin?
  if package.loaded["auto-save"] then
    local ok, conf = pcall(require, "auto-save.config")
    local cond = ok and conf.opts and conf.opts.condition
    if cond == g.can_save then
      h.ok("okuuva/auto-save.nvim uses xyno_guard.can_save as its condition")
    elseif type(cond) == "function" then
      h.warn(
        "auto-save.nvim is loaded with another `condition`: the guard is bypassed",
        { "Pass condition = require('xyno_guard').can_save (or call it from yours)." }
      )
    else
      h.warn("auto-save.nvim is loaded without a `condition`: the guard is not used", { "Pass condition = require('xyno_guard').can_save." })
    end
  else
    h.info("auto-save.nvim is not loaded (nothing to check; the dependency lock and save_all() still work)")
  end

  local roots = { "~/.cargo/registry", "~/.cargo/git", "~/.rustup" }
  for _, r in ipairs(c.dependency_roots) do
    roots[#roots + 1] = r
  end
  h.info("extra dependency roots: " .. (#c.dependency_roots > 0 and table.concat(c.dependency_roots, ", ") or "(none)"))

  local stuck = g.stuck_nowrite()
  if #stuck > 0 then
    h.error(
      ("%d buffer(s) are still 'buftype=nowrite' from a refused auto-save (a manual :w fails): %s"):format(#stuck, table.concat(stuck, ", ")),
      { "Run :lua require('xyno_guard').restore_nowrite()", "Report it: AutoSaveWritePost never fired and the fallback timer did not run." }
    )
  else
    h.ok("no buffer is stuck in buftype=nowrite")
  end

  local stale, gone = {}, {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local s = g.state(buf)
      local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
      if s == "stale" then
        stale[#stale + 1] = name
      elseif s == "gone" then
        gone[#gone + 1] = name
      end
    end
  end
  if #stale > 0 then
    h.warn("changed on disk, auto-save is paused for: " .. table.concat(stale, ", "), { ":e! takes the disk version, :w! keeps the buffer." })
  end
  if #gone > 0 then
    h.warn("deleted on disk: " .. table.concat(gone, ", "), { ":w recreates the file." })
  end
  if #stale == 0 and #gone == 0 then
    h.ok("no loaded buffer is stale or deleted on disk")
  end

  for _, grp in ipairs({ "XynoGuardDependency", "XynoGuardStale", "XynoGuardGone" }) do
    local hl = vim.api.nvim_get_hl(0, { name = grp, link = true })
    if next(hl) == nil then
      h.warn("highlight group " .. grp .. " is not defined")
    end
  end
  if not vim.o.autoread then
    h.info("'autoread' is off: a file changed on disk is not reloaded, the buffer is marked stale instead")
  end
end

return M
