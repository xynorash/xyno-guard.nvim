-- nvim --headless --clean -l scripts/bench.lua <file>: cost of recording a buffer's disk state and of can_save
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(here)))
local dg = require("xyno_guard")
local file = arg[1]
local function bench(label, opts)
  dg.setup(opts)
  vim.cmd("silent edit! " .. vim.fn.fnameescape(file))
  local buf = vim.api.nvim_get_current_buf()
  local n = 2000
  local t = vim.uv.hrtime()
  for _ = 1, n do
    dg.can_save(buf)
  end
  local per_check = (vim.uv.hrtime() - t) / n / 1e3
  t = vim.uv.hrtime()
  for _ = 1, 200 do
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
  end
  local per_record = (vim.uv.hrtime() - t) / 200 / 1e3
  print(("%-28s can_save %.1f us   record (BufWritePost) %.1f us"):format(label, per_check, per_record))
end
bench("stat only (hash off)", { hash_max_bytes = 0 })
bench("hash <= 256 KiB (default)", {})
vim.cmd("qa!")
