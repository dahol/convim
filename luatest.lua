-- Test runner for convim - uses Neovim's embedded LuaJIT, no external deps.
-- Invoked via: nvim --headless -c "luafile luatest.lua" +qa!
-- Or via: make test

-- Register the plugin lua directory so tests can require('convim.*')
package.path = package.path .. ';./lua/?.lua;./lua/?/init.lua'

local test_files = {
  'tests/test_config.lua',
  'tests/test_converter.lua',
  'tests/test_api.lua',
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
