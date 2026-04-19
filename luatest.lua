-- Test runner for convim - uses Neovim's embedded LuaJIT, no external deps.
-- Invoked via: nvim --headless -c "luafile luatest.lua" +qa!
-- Or via: make test

-- Register the plugin lua directory so tests can require('convim.*').
-- IMPORTANT: prepend (not append) so the local working copy wins over any
-- system-installed convim picked up via Neovim's runtimepath/lazy.nvim.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

-- Neovim 0.9+ has a fast Lua module loader that caches resolved paths from
-- &runtimepath *before* consulting package.path.  If a copy of convim is
-- installed via lazy/packer, that copy will shadow our local working tree
-- and cause stale-code test failures.  Disable the loader for this run.
if vim.loader and vim.loader.disable then
  pcall(vim.loader.disable)
end

-- Belt-and-braces: register every local convim/*.lua directly into
-- package.preload, which is the FIRST searcher consulted by require().
-- This guarantees `require('convim.foo')` returns OUR file regardless of
-- runtimepath ordering, lazy.nvim, or other installed copies.
do
  local lfs_ok, scandir = pcall(vim.fn.glob, 'lua/convim/**/*.lua', false, true)
  if lfs_ok then
    for _, path in ipairs(scandir) do
      -- lua/convim/foo/bar.lua -> convim.foo.bar  (strip lua/ and .lua)
      local mod = path:gsub('^lua/', ''):gsub('%.lua$', ''):gsub('/init$', ''):gsub('/', '.')
      package.preload[mod] = function()
        local chunk, err = loadfile(path)
        if not chunk then error(err) end
        return chunk()
      end
    end
  end
end

-- Also nuke any pre-cached convim modules that may have loaded from runtime
-- before this script ran.
for k in pairs(package.loaded) do
  if k:match('^convim') then package.loaded[k] = nil end
end

local test_files = {
  'tests/test_config.lua',
  'tests/test_format.lua',
  'tests/test_converter.lua',
  'tests/test_api.lua',
  'tests/test_picker.lua',
  'tests/test_ui.lua',
  'tests/test_main.lua',
}

local passed = 0
local failed = 0
local errors = {}

print('\n=== convim test suite ===\n')

for _, f in ipairs(test_files) do
  -- Each test file may accumulate multiple named results via the framework
  -- below; we reset between files via package.loaded cleanup in each file.
  local ok, result = pcall(dofile, f)
  if not ok then
    failed = failed + 1
    local msg = tostring(result):gsub('^.-:%d+: ', '')
    table.insert(errors, string.format('FAIL  %s\n      %s', f, msg))
    io.write(string.format('FAIL  %s\n', f))
    io.write(string.format('      %s\n', msg))
  else
    passed = passed + 1
    io.write(string.format('ok    %s\n', f))
  end
end

print(string.format('\n%d passed, %d failed', passed, failed))

if failed > 0 then
  print('')
  for _, e in ipairs(errors) do print(e) end
  os.exit(1)
end
