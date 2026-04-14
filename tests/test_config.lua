-- tests/test_config.lua
-- Tests for lua/convim/config.lua

-- Isolate: reload the module fresh for each test file
package.loaded['convim.config'] = nil
local config = require('convim.config')

-- ── helpers ──────────────────────────────────────────────────────────────────

local function reset()
  config.base_url  = nil
  config.token     = nil
  config.space_key = nil
end

-- ── tests ────────────────────────────────────────────────────────────────────

reset()
assert(config.base_url  == nil, 'default base_url should be nil')
assert(config.token     == nil, 'default token should be nil')
assert(config.space_key == nil, 'default space_key should be nil')
assert(type(config.setup)    == 'function', 'setup should be a function')
assert(type(config.validate) == 'function', 'validate should be a function')
print('  config: default fields are nil')

-- setup populates fields
reset()
config.setup({ base_url = 'https://x.atlassian.net', token = 'tok', space_key = 'PROJ' })
assert(config.base_url  == 'https://x.atlassian.net', 'setup: base_url')
assert(config.token     == 'tok',  'setup: token')
assert(config.space_key == 'PROJ', 'setup: space_key')
print('  config: setup() populates all fields')

-- partial setup leaves untouched fields unchanged
reset()
config.base_url = 'https://initial.atlassian.net'
config.token    = 'initial_token'
config.setup({ space_key = 'NEW' })
assert(config.base_url  == 'https://initial.atlassian.net', 'partial setup: base_url unchanged')
assert(config.token     == 'initial_token', 'partial setup: token unchanged')
assert(config.space_key == 'NEW', 'partial setup: space_key updated')
print('  config: partial setup() leaves other fields unchanged')

-- validate returns error when base_url missing
reset()
config.token = 'tok'
local err = config.validate()
assert(err ~= nil, 'validate: should fail without base_url')
assert(err:find('base_url'), 'validate: error should mention base_url')
print('  config: validate() fails without base_url')

-- validate returns error when token missing
reset()
config.base_url = 'https://x.atlassian.net'
local err2 = config.validate()
assert(err2 ~= nil, 'validate: should fail without token')
assert(err2:find('token'), 'validate: error should mention token')
print('  config: validate() fails without token')

-- validate returns nil when both present
reset()
config.base_url = 'https://x.atlassian.net'
config.token    = 'tok'
local err3 = config.validate()
assert(err3 == nil, 'validate: should pass when both base_url and token are set')
print('  config: validate() passes when both fields are set')
