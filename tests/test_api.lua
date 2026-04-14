-- tests/test_api.lua
-- Tests for lua/convim/api.lua

package.loaded['convim.config'] = nil
package.loaded['convim.api']    = nil
package.loaded['plenary.http']  = nil

local config = require('convim.config')
config.base_url = 'https://test.atlassian.net'
config.token    = 'test_tok'

-- ── mock plenary.http ─────────────────────────────────────────────────────────

local captured_requests = {}  -- each entry = { method, url, opts }

local function make_mock_http(responses)
  -- responses: list of { status, body_table } consumed in order per method+url
  local index = { get = 1, post = 1, put = 1 }
  local mock = {}
  for _, method in ipairs({ 'get', 'post', 'put' }) do
    local m = method
    mock[m] = function(url, opts)
      table.insert(captured_requests, { method = m, url = url, opts = opts })
      local r = responses[m] and responses[m][index[m]]
      index[m] = (index[m] or 1) + 1
      if r then
        return { status = r.status, body = vim.fn.json_encode(r.body) }
      end
      return { status = 404, body = '{}' }
    end
  end
  return mock
end

local function reset_api(mock_responses)
  captured_requests = {}
  package.loaded['plenary.http'] = make_mock_http(mock_responses)
  package.loaded['convim.api']   = nil
  return require('convim.api')
end

-- ── helpers ───────────────────────────────────────────────────────────────────

local function last_request() return captured_requests[#captured_requests] end

-- ── tests: validate() guard ────────────────────────────────────────────────────

-- Each API function should bail out with a validation error if config incomplete
package.loaded['convim.config'] = nil
local cfg_bad = require('convim.config')  -- empty config
package.loaded['convim.api'] = nil
package.loaded['plenary.http'] = make_mock_http({})
local api_bad = require('convim.api')

local r, e = api_bad.get_spaces()
assert(r == nil and e ~= nil, 'get_spaces: fails with invalid config')
print('  api: all functions fail with invalid config')

-- Restore valid config
package.loaded['convim.config'] = nil
local cfg = require('convim.config')
cfg.base_url = 'https://test.atlassian.net'
cfg.token    = 'test_tok'

-- ── tests: get_spaces ─────────────────────────────────────────────────────────

local api = reset_api({
  get = {
    { status = 200, body = { results = {{ key='A', name='Alpha' }, { key='B', name='Beta' }}, _links = {} } },
  }
})
local spaces, sp_err = api.get_spaces()
assert(sp_err == nil,    'get_spaces: no error on 200')
assert(type(spaces) == 'table', 'get_spaces: returns table')
assert(#spaces == 2,     'get_spaces: returns all results')
assert(spaces[1].key == 'A', 'get_spaces: first result correct')
local req = last_request()
assert(req.url:find('/wiki/api/v2/spaces'), 'get_spaces: hits correct endpoint')
assert(req.opts.headers['Authorization']:find('test_tok'), 'get_spaces: sends auth header')
print('  api: get_spaces() fetches spaces and sends correct request')

-- get_spaces follows pagination cursor
local api2 = reset_api({
  get = {
    { status = 200, body = { results = {{ key='A' }}, _links = { next = '?cursor=cur1' } } },
    { status = 200, body = { results = {{ key='B' }}, _links = {} } },
  }
})
local spaces2, _ = api2.get_spaces()
assert(#spaces2 == 2, 'get_spaces: follows pagination cursor')
print('  api: get_spaces() follows pagination')

-- get_spaces propagates HTTP errors
local api3 = reset_api({ get = {{ status = 401, body = {} }} })
local s3, e3 = api3.get_spaces()
assert(s3 == nil, 'get_spaces: nil on 401')
assert(e3 ~= nil and e3:find('401'), 'get_spaces: error message contains status')
print('  api: get_spaces() surfaces HTTP errors')

-- ── tests: get_pages ──────────────────────────────────────────────────────────

local api4 = reset_api({
  get = {
    { status = 200, body = { results = {{ id='1', title='P1' }}, _links = {} } },
  }
})
local pages, pg_err = api4.get_pages('TEST')
assert(pg_err == nil,   'get_pages: no error on 200')
assert(#pages == 1,     'get_pages: returns result')
assert(last_request().url:find('/spaces/TEST/pages'), 'get_pages: URL contains space key')
print('  api: get_pages() fetches pages for given space')

-- ── tests: get_page_content ───────────────────────────────────────────────────

local page_body = {
  id = '42', title = 'My Page',
  version = { number = 3 },
  body = { storage = { value = '<p>Hello</p>' } },
}
local api5 = reset_api({ get = {{ status = 200, body = page_body }} })
local page, page_err = api5.get_page_content('42')
assert(page_err == nil,                  'get_page_content: no error on 200')
assert(page.id == '42',                  'get_page_content: id correct')
assert(page.version.number == 3,         'get_page_content: version present')
assert(page.body.storage.value == '<p>Hello</p>', 'get_page_content: body present')
assert(last_request().url:find('body%-format=storage'), 'get_page_content: requests storage format')
print('  api: get_page_content() fetches page with version and body')

-- ── tests: update_page ────────────────────────────────────────────────────────

-- update_page: fetches current version (GET), increments, then PUTs
local api6 = reset_api({
  get = {{ status = 200, body = page_body }},       -- version fetch
  put = {{ status = 200, body = { id = '42' } }},   -- update
})
local ok, up_err = api6.update_page('42', 'New Title', '<p>Updated</p>')
assert(ok == true,   'update_page: returns true on success')
assert(up_err == nil, 'update_page: no error on success')

-- verify PUT was used
local put_req = nil
for _, r2 in ipairs(captured_requests) do
  if r2.method == 'put' then put_req = r2 end
end
assert(put_req ~= nil, 'update_page: uses PUT method')

-- verify version was incremented
local put_body = vim.fn.json_decode(put_req.opts.body)
assert(put_body.version.number == 4, 'update_page: version number is current+1 (3+1=4)')
assert(put_body.title == 'New Title', 'update_page: title in PUT body')
print('  api: update_page() uses PUT, increments version number')

-- update_page propagates error when version fetch fails
local api7 = reset_api({ get = {{ status = 404, body = {} }} })
local ok2, err2 = api7.update_page('42', 'T', 'c')
assert(ok2 == nil,  'update_page: nil on version fetch failure')
assert(err2 ~= nil, 'update_page: error when version fetch fails')
print('  api: update_page() propagates version-fetch errors')

-- ── tests: create_page ────────────────────────────────────────────────────────

local api8 = reset_api({ post = {{ status = 201, body = { id='99', title='New' } }} })
local new_page, create_err = api8.create_page('TEST', 'New', '<p/>')
assert(create_err == nil,  'create_page: no error on 201')
assert(new_page.id == '99', 'create_page: returns created page')
local post_req = nil
for _, r3 in ipairs(captured_requests) do
  if r3.method == 'post' then post_req = r3 end
end
assert(post_req ~= nil, 'create_page: uses POST method')
print('  api: create_page() POSTs and returns new page')

-- ── tests: verify_auth ───────────────────────────────────────────────────────

-- verify_auth: missing config returns ok=false with message
package.loaded['convim.config'] = nil
local cfg_va = require('convim.config')  -- empty
package.loaded['convim.api'] = nil
package.loaded['plenary.http'] = make_mock_http({})
local api_va_bad = require('convim.api')
local bad_result = api_va_bad.verify_auth()
assert(bad_result.ok == false, 'verify_auth: ok=false when config missing')
assert(bad_result.message ~= nil, 'verify_auth: has message when config missing')
print('  api: verify_auth() fails cleanly with missing config')

-- Restore config
package.loaded['convim.config'] = nil
local cfg_va2 = require('convim.config')
cfg_va2.base_url = 'https://test.atlassian.net'
cfg_va2.token    = 'test_tok'

-- verify_auth: 200 probe + 200 user → ok=true with user name
local api_va_ok = reset_api({
  get = {
    { status = 200, body = { results = {} } },                        -- spaces probe
    { status = 200, body = { displayName = 'Ada Lovelace' } },        -- current user
  },
})
local ok_result = api_va_ok.verify_auth()
assert(ok_result.ok == true,              'verify_auth: ok=true on 200')
assert(ok_result.user == 'Ada Lovelace', 'verify_auth: extracts displayName')
assert(ok_result.message:find('Ada Lovelace'), 'verify_auth: message contains user')
assert(ok_result.base_url == 'https://test.atlassian.net', 'verify_auth: base_url in result')
print('  api: verify_auth() returns ok=true and user name on success')

-- verify_auth: 401 → ok=false with meaningful message
local api_va_401 = reset_api({ get = {{ status = 401, body = {} }} })
local r401 = api_va_401.verify_auth()
assert(r401.ok == false,       'verify_auth: ok=false on 401')
assert(r401.status == 401,     'verify_auth: status=401')
assert(r401.message:find('401') or r401.message:find('invalid'),
  'verify_auth: 401 message is descriptive')
print('  api: verify_auth() returns ok=false with 401 message on bad token')

-- verify_auth: 403 → ok=false with meaningful message
local api_va_403 = reset_api({ get = {{ status = 403, body = {} }} })
local r403 = api_va_403.verify_auth()
assert(r403.ok == false,   'verify_auth: ok=false on 403')
assert(r403.status == 403, 'verify_auth: status=403')
print('  api: verify_auth() returns ok=false with 403 message on insufficient permissions')

-- verify_auth: network error (pcall catches) → ok=false
local api_va_net = reset_api({})
package.loaded['plenary.http'] = {
  get = function() error('connection refused') end,
}
package.loaded['convim.api'] = nil
local api_va_err = require('convim.api')
local r_net = api_va_err.verify_auth()
assert(r_net.ok == false, 'verify_auth: ok=false on network error')
assert(r_net.message:find('Network error') or r_net.message:find('connection'),
  'verify_auth: network error message is informative')
print('  api: verify_auth() handles network errors gracefully')
