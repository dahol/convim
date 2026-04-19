-- tests/test_main.lua
-- Tests for the top-level lua/convim.lua entry point.

package.loaded['convim']        = nil
package.loaded['convim.config'] = nil
-- plenary.curl is not installed in test env; mock it so converter can load
package.loaded['plenary.curl'] = {
  get  = function() return { status = 200, body = '{}' } end,
  post = function() return { status = 200, body = '{}' } end,
  put  = function() return { status = 200, body = '{}' } end,
}

-- ── tests: module shape ───────────────────────────────────────────────────────

local convim = require('convim')
assert(type(convim.setup) == 'function', 'convim: setup is a function')
print('  main: exposes setup()')

-- Submodules accessible via lazy __index
assert(type(convim.ui)        == 'table', 'convim: .ui is accessible')
assert(type(convim.api)       == 'table', 'convim: .api is accessible')
assert(type(convim.converter) == 'table', 'convim: .converter is accessible')
print('  main: submodules accessible as convim.ui / .api / .converter')

-- ── tests: setup() delegates to config ───────────────────────────────────────

local called_with = nil
package.loaded['convim.config'] = {
  base_url = nil, token = nil, space_key = nil,
  validate = function() return nil end,
  setup = function(opts) called_with = opts end,
}
package.loaded['convim'] = nil
local convim2 = require('convim')

convim2.setup({ base_url = 'https://demo.atlassian.net', token = 'tok' })
assert(called_with ~= nil, 'setup: delegates to config.setup')
assert(called_with.base_url == 'https://demo.atlassian.net', 'setup: passes base_url through')
assert(called_with.token    == 'tok', 'setup: passes token through')
print('  main: setup() delegates to config.setup with correct opts')

-- setup() with no args does not crash (passes empty table)
package.loaded['convim'] = nil
local convim3 = require('convim')
local ok = pcall(convim3.setup)
assert(ok, 'setup: calling with no args does not crash')
print('  main: setup() with no args is safe')
