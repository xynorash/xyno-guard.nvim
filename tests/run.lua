-- Runs the spec files (tests/*_spec.lua, or the paths given) in this one nvim:
--   nvim --headless -l tests/run.lua [spec files...]
-- One line per test (ok / FAIL / SKIP) and a final
--   RESULT passed=N failed=N skipped=N
-- line. Exit code is 0 only without failures.
-- The specs that drive a real auto-save plugin look for okuuva/auto-save.nvim in
-- $XYNO_GUARD_AUTOSAVE_DIR, else tests/deps/auto-save.nvim (see the CI workflow);
-- without it those tests are skipped.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local repo = vim.fs.dirname(vim.fs.dirname(here))
vim.opt.runtimepath:prepend(repo)

local deps = vim.env.XYNO_GUARD_AUTOSAVE_DIR
if not deps or deps == "" then
  deps = repo .. "/tests/deps/auto-save.nvim"
end
if vim.uv.fs_stat(deps) then
  vim.opt.runtimepath:append(deps)
  vim.env.XYNO_GUARD_AUTOSAVE_FOUND = "1"
end

-- private names: "tests.*" could clash with another plugin's lua/tests/
for _, name in ipairs({ "helpers", "harness" }) do
  package.preload["xynotest." .. name] = function()
    return dofile(repo .. "/tests/" .. name .. ".lua")
  end
end

local specs = {}
for _, a in ipairs(arg) do
  specs[#specs + 1] = vim.fn.fnamemodify(a, ":p")
end
if #specs == 0 then
  specs = vim.fn.glob(repo .. "/tests/*_spec.lua", true, true)
  table.sort(specs)
end

local harness = require("xynotest.harness")
local total = { passed = 0, failed = 0, skipped = 0 }
local function add(n)
  for k in pairs(total) do
    total[k] = total[k] + n[k]
  end
end

for _, spec in ipairs(specs) do
  harness.install()
  local ok, err = xpcall(dofile, debug.traceback, spec)
  if ok then
    add(harness.run())
  elseif harness.is_skip(err) then
    io.stdout:write(("SKIP %s (%s)\n"):format(vim.fs.basename(spec), err.reason))
    add({ passed = 0, failed = 0, skipped = 1 })
  else
    io.stdout:write("FAIL loading " .. spec .. "\n")
    for l in tostring(err):gmatch("[^\n]+") do
      io.stdout:write("       " .. l .. "\n")
    end
    add({ passed = 0, failed = 1, skipped = 0 })
  end
  pcall(require("xynotest.helpers").cleanup)
end

io.stdout:write(("RESULT passed=%d failed=%d skipped=%d\n"):format(total.passed, total.failed, total.skipped))
io.stdout:flush()
vim.cmd(total.failed > 0 and "cquit 1" or "qa!")
