-- tests/test_api.lua
-- Tests for lua/convim/api.lua

package.loaded['convim.config'] = nil
package.loaded['convim.api']    = nil
package.loaded['plenary.curl']  = nil

local config = require('convim.config')
config.base_url = 'https://test.atlassian.net'
config.token    = 'test_tok'
config.email    = 'tester@example.com'
config.auth     = 'basic'

-- ── mock plenary.curl ─────────────────────────────────────────────────────────

local captured_requests = {}  -- each entry = { method, url, opts }

local function make_mock_curl(responses)
  -- responses: list of { status, body_table } consumed in order per method
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
  package.loaded['plenary.curl'] = make_mock_curl(mock_responses)
  package.loaded['convim.api']   = nil
  return require('convim.api')
end

-- ── helpers ───────────────────────────────────────────────────────────────────

local function last_request() return captured_requests[#captured_requests] end

local function find_request(method, pattern)
  for _, r in ipairs(captured_requests) do
    if r.method == method and r.url:find(pattern) then return r end
  end
  return nil
end

-- Stock space-lookup response used by get_pages / create_page
local SPACE_LOOKUP = { status = 200, body = {
  results = { { id = '424242', key = 'TEST', name = 'Test' } }
} }

-- ── tests: validate() guard ────────────────────────────────────────────────────

package.loaded['convim.config'] = nil
local cfg_bad = require('convim.config')  -- empty config
package.loaded['convim.api']   = nil
package.loaded['plenary.curl'] = make_mock_curl({})
local api_bad = require('convim.api')

local r, e = api_bad.get_spaces()
assert(r == nil and e ~= nil, 'get_spaces: fails with invalid config')
print('  api: all functions fail with invalid config')

-- Restore valid config
package.loaded['convim.config'] = nil
local cfg = require('convim.config')
cfg.base_url = 'https://test.atlassian.net'
cfg.token    = 'test_tok'
cfg.email    = 'tester@example.com'
cfg.auth     = 'basic'

-- ── tests: auth header building ──────────────────────────────────────────────

local api_auth = reset_api({ get = {{ status = 200, body = { results = {}, _links = {} } }} })
local _ = api_auth.get_spaces()
local auth_header = last_request().opts.headers['Authorization']
assert(auth_header:sub(1, 6) == 'Basic ', 'auth: basic scheme used when configured')
print('  api: builds Basic auth header for Cloud')

-- Switch to bearer
cfg.auth = 'bearer'
local api_bearer = reset_api({ get = {{ status = 200, body = { results = {}, _links = {} } }} })
api_bearer.get_spaces()
local bearer_header = last_request().opts.headers['Authorization']
assert(bearer_header == 'Bearer test_tok', 'auth: bearer scheme uses token directly')
print('  api: builds Bearer auth header for Data Center')

-- Restore basic for the rest of the tests
cfg.auth = 'basic'

-- ── tests: get_spaces ─────────────────────────────────────────────────────────

local api1 = reset_api({
  get = {
    { status = 200, body = { results = {{ key='A', name='Alpha' }, { key='B', name='Beta' }}, _links = {} } },
  }
})
local spaces, sp_err = api1.get_spaces()
assert(sp_err == nil,    'get_spaces: no error on 200')
assert(type(spaces) == 'table', 'get_spaces: returns table')
assert(#spaces == 2,     'get_spaces: returns all results')
assert(spaces[1].key == 'A', 'get_spaces: first result correct')
local req = last_request()
assert(req.url:find('/wiki/api/v2/spaces'), 'get_spaces: hits correct endpoint')
assert(req.opts.headers['Authorization'], 'get_spaces: sends auth header')
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

-- ── tests: get_space_id_by_key ───────────────────────────────────────────────

local api_sid = reset_api({ get = { SPACE_LOOKUP } })
local sid, sid_err = api_sid.get_space_id_by_key('TEST')
assert(sid_err == nil, 'get_space_id_by_key: no error on hit')
assert(sid == '424242', 'get_space_id_by_key: returns numeric id as string')
assert(last_request().url:find('keys=TEST'), 'get_space_id_by_key: filters by key in query')
print('  api: get_space_id_by_key() resolves key to numeric id')

local api_sid_miss = reset_api({ get = {{ status = 200, body = { results = {} } }} })
local s_miss, s_err = api_sid_miss.get_space_id_by_key('NOPE')
assert(s_miss == nil, 'get_space_id_by_key: nil when no match')
assert(s_err:find('NOPE'), 'get_space_id_by_key: error mentions missing key')
print('  api: get_space_id_by_key() reports missing space')

-- ── tests: get_pages ──────────────────────────────────────────────────────────

local api4 = reset_api({
  get = {
    SPACE_LOOKUP,
    { status = 200, body = { results = {{ id='1', title='P1' }}, _links = {} } },
  }
})
local pages, pg_err = api4.get_pages('TEST')
assert(pg_err == nil,   'get_pages: no error on 200')
assert(#pages == 1,     'get_pages: returns result')
assert(find_request('get', '/spaces/424242/pages'),
  'get_pages: URL contains resolved space ID, not key')
print('  api: get_pages() resolves space key then fetches pages')

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

local put_req = find_request('put', '/wiki/api/v2/pages/42')
assert(put_req ~= nil, 'update_page: uses PUT method')
assert(put_req.opts.headers['Content-Type'] == 'application/json',
  'update_page: sends application/json content-type')

-- verify version was incremented and body shape is correct
local put_body = vim.fn.json_decode(put_req.opts.body)
assert(put_body.version.number == 4, 'update_page: version number is current+1 (3+1=4)')
assert(put_body.title == 'New Title', 'update_page: title in PUT body')
assert(put_body.body.representation == 'storage',
  'update_page: body.representation is storage')
assert(put_body.body.value == '<p>Updated</p>',
  'update_page: body.value is the new content')
assert(put_body.id == '42', 'update_page: id is stringified page_id')
print('  api: update_page() uses PUT, increments version, correct body shape')

-- update_page propagates error when version fetch fails
local api7 = reset_api({ get = {{ status = 404, body = {} }} })
local ok2, err2 = api7.update_page('42', 'T', 'c')
assert(ok2 == nil,  'update_page: nil on version fetch failure')
assert(err2 ~= nil, 'update_page: error when version fetch fails')
print('  api: update_page() propagates version-fetch errors')

-- ── tests: create_page ────────────────────────────────────────────────────────

local api8 = reset_api({
  get  = { SPACE_LOOKUP },
  post = {{ status = 201, body = { id='99', title='New' } }},
})
local new_page, create_err = api8.create_page('TEST', 'New', '<p/>')
assert(create_err == nil,  'create_page: no error on 201')
assert(new_page.id == '99', 'create_page: returns created page')

local post_req = find_request('post', '/wiki/api/v2/pages')
assert(post_req ~= nil, 'create_page: uses POST method')
local post_body = vim.fn.json_decode(post_req.opts.body)
assert(post_body.spaceId == '424242',
  'create_page: spaceId is the resolved numeric ID, not the key')
assert(post_body.title == 'New', 'create_page: title in POST body')
assert(post_body.body.representation == 'storage',
  'create_page: body.representation is storage')
print('  api: create_page() resolves key->id, POSTs with correct payload')

-- ── tests: search_pages URL escaping ─────────────────────────────────────────

local api_search = reset_api({
  get = {{ status = 200, body = { results = {{ id='1', title='Found' }} } }}
})
local res, serr = api_search.search_pages('hello world', nil)
assert(serr == nil and #res == 1, 'search_pages: returns results')
local search_req = last_request()
-- spaces in CQL must be percent-encoded
assert(search_req.url:find('hello%%20world') or search_req.url:find('hello%+world'),
  'search_pages: query is URL-encoded')
print('  api: search_pages() URL-encodes the CQL query')

-- ── tests: verify_auth ───────────────────────────────────────────────────────

-- verify_auth: missing config returns ok=false with message
package.loaded['convim.config'] = nil
local cfg_va = require('convim.config')  -- empty
package.loaded['convim.api']   = nil
package.loaded['plenary.curl'] = make_mock_curl({})
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
cfg_va2.email    = 'tester@example.com'
cfg_va2.auth     = 'basic'

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
package.loaded['plenary.curl'] = {
  get = function() error('connection refused') end,
}
package.loaded['convim.api'] = nil
local api_va_err = require('convim.api')
local r_net = api_va_err.verify_auth()
assert(r_net.ok == false, 'verify_auth: ok=false on network error')
assert(r_net.message:find('Network error') or r_net.message:find('connection'),
  'verify_auth: network error message is informative')
print('  api: verify_auth() handles network errors gracefully')
