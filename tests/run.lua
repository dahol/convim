#!/usr/bin/env lua

local lfs = require('lfs')

print("=== convim Test Suite ===\n")

-- Get test files
local tests_dir = "tests/"
local test_files = {}

for file in lfs.dir(tests_dir) do
  if file:match('^test_.*%.lua$') then
    table.insert(test_files, tests_dir .. file)
  end
end

table.sort(test_files)

-- Run each test file
local failed = 0
local passed = 0

for _, test_file in ipairs(test_files) do
  print("Running: " .. test_file)
  
  local chunk, err = loadfile(test_file)
  if not chunk then
    print("  ❌ Error loading: " .. (err or 'unknown'))
    failed = failed + 1
    goto continue
  end
  
  local status, result = pcall(chunk)
  if not status then
    print("  ❌ FAILED")
    io.stderr:write(result .. "\n")
    failed = failed + 1
  else
    print("  ✓ PASSED")
    passed = passed + 1
  end
  
  ::continue::
end

print("\n=== Results ===")
print(string.format("Passed: %d", passed))
print(string.format("Failed: %d", failed))
print(string.format("Total:  %d", passed + failed))

if failed > 0 then
  os.exit(1)
end
