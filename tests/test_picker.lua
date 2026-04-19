-- tests/test_picker.lua
-- Tests for lua/convim/picker.lua
--
-- We verify the module surface and the graceful-fallback contract:
-- when telescope.nvim is not on the runtimepath, `available()` and the
-- picker entry points return false so callers can fall back to vim.ui.select.
--
-- We do NOT exercise the live telescope picker here — driving an interactive
-- floating window from a headless test would be flaky and require simulating
-- key events.  Instead we stub `require` so telescope appears unavailable
-- and confirm the contract.

package.loaded['convim.picker'] = nil

-- ── module surface ────────────────────────────────────────────────────────────

local picker = require('convim.picker')
assert(type(picker.available)    == 'function', 'picker: available is function')
assert(type(picker.search_pages) == 'function', 'picker: search_pages is function')
assert(type(picker.list_pages)   == 'function', 'picker: list_pages is function')
print('  picker: module exposes expected functions')

-- ── fallback contract: returns false when telescope is missing ───────────────

local orig_require = require
_G.require = function(mod)
  if mod == 'telescope' then error("module 'telescope' not found") end
  return orig_require(mod)
end
-- Force re-evaluation of available() — picker.available calls pcall(require)
-- on each invocation, so the stub takes effect immediately.
assert(picker.available() == false, 'picker: available() is false when telescope missing')

local sp_ok = picker.search_pages({ search_pages = function() return {} end }, nil, '', function() end)
assert(sp_ok == false, 'picker: search_pages returns false when telescope missing')

local lp_ok = picker.list_pages({ { id = '1', title = 'x' } }, 'title', function() end)
assert(lp_ok == false, 'picker: list_pages returns false when telescope missing')
_G.require = orig_require
print('  picker: returns false when telescope.nvim is not available')

-- ── available() returns true when telescope IS loadable ──────────────────────
-- Only assert this if telescope happens to be on the runtimepath in this env.
-- We don't want the test to fail for users without telescope installed.
if pcall(orig_require, 'telescope') then
  assert(picker.available() == true, 'picker: available() is true when telescope present')
  print('  picker: available() is true when telescope is installed')
else
  print('  picker: telescope not installed in test env, skipping positive check')
end
