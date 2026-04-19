-- tests/test_converter.lua
-- Tests for lua/convim/converter.lua

-- Reset modules so mocks take effect cleanly
package.loaded['convim.config']    = nil
package.loaded['convim.converter'] = nil
package.loaded['plenary.curl']     = nil

local config = require('convim.config')
config.base_url = 'https://test.atlassian.net'
config.token    = 'test_tok'
config.email    = 'tester@example.com'
config.auth     = 'basic'

-- ── helpers ──────────────────────────────────────────────────────────────────

local last_post = nil

local function mock_curl(status, body_table)
  last_post = nil
  package.loaded['plenary.curl'] = {
    post = function(url, opts)
      last_post = { url = url, opts = opts }
      return { status = status, body = vim.fn.json_encode(body_table) }
    end,
  }
  package.loaded['convim.converter'] = nil
end

-- ── tests ────────────────────────────────────────────────────────────────────

-- API surface
mock_curl(200, { value = '<p>ok</p>' })
local converter = require('convim.converter')
assert(type(converter.to_storage)  == 'function', 'to_storage should be a function')
assert(type(converter.strip_html)  == 'function', 'strip_html should be a function')
print('  converter: module exposes expected functions')

-- to_storage returns converted value on 200 and hits the right endpoint
mock_curl(200, { value = '<h1>Hello</h1>' })
local converter2 = require('convim.converter')
local result, err = converter2.to_storage('h1. Hello')
assert(err == nil,              'to_storage: no error on success')
assert(result == '<h1>Hello</h1>', 'to_storage: returns value from response')
assert(last_post.url:find('/wiki/rest/api/contentbody/convert/storage'),
  'to_storage: hits /contentbody/convert/storage (not the made-up /pages/render)')
local req_body = vim.fn.json_decode(last_post.opts.body)
assert(req_body.representation == 'wiki',
  'to_storage: defaults to "wiki" representation (markdown is not supported by the converter)')
print('  converter: to_storage() POSTs to correct convert endpoint with wiki representation')

-- to_storage returns nil + error on non-200
mock_curl(500, {})
local converter3 = require('convim.converter')
local result2, err2 = converter3.to_storage('h1. Hello')
assert(result2 == nil,  'to_storage: nil result on 500')
assert(err2 ~= nil,     'to_storage: error message on 500')
assert(err2:find('500'), 'to_storage: error mentions status code')
print('  converter: to_storage() returns error on 500')

-- to_storage returns error when config is invalid
package.loaded['convim.config']    = nil
package.loaded['convim.converter'] = nil
local cfg_empty = require('convim.config')
cfg_empty.base_url = nil
cfg_empty.token    = nil
local conv_invalid = require('convim.converter')
local r, e = conv_invalid.to_storage('# Test')
assert(r == nil,  'to_storage: nil when config invalid')
assert(e ~= nil,  'to_storage: error when config invalid')
print('  converter: to_storage() fails when config is incomplete')

-- Restore valid config for remaining tests
package.loaded['convim.config'] = nil
local cfg2 = require('convim.config')
cfg2.base_url = 'https://test.atlassian.net'
cfg2.token    = 'test_tok'
cfg2.email    = 'tester@example.com'
cfg2.auth     = 'basic'

-- strip_html removes tags
mock_curl(200, { value = '' })
local conv = require('convim.converter')
local plain = conv.strip_html('<h1>Title</h1><p>Body text</p>')
assert(plain:find('Title'),     'strip_html: keeps heading text')
assert(plain:find('Body text'), 'strip_html: keeps paragraph text')
assert(not plain:find('<'),     'strip_html: removes all tags')
print('  converter: strip_html() removes tags and preserves text')

-- strip_html handles nil gracefully
local empty = conv.strip_html(nil)
assert(empty == '', 'strip_html: nil returns empty string')
print('  converter: strip_html() handles nil input')
